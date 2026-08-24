#!/usr/bin/env bash
# ci-attempt-history.sh — resolve what the EARLIER attempts of a re-run
# concluded, so a green that replaced a red is distinguishable from a green that
# replaced nothing (your-org/nexus-code#748).
#
# THE DEFECT. `GET /actions/runs?head_sha=` returns one entry per run — the
# LATEST attempt. `gh run list` and the check-runs API do the same. So a
# workflow that concluded `failure` and was then re-run to `success` at the SAME
# sha is byte-identical to one that passed first time, to every tool in this
# repo. At head d4df844f the SLOW band did exactly that, and it read as a clean
# first-pass green. monitor/ci-observed-runs.jq now carries `run_attempt`, which
# costs nothing and says a retry HAPPENED. This script answers the next
# question, which `run_attempt` cannot: what did the attempt that got replaced
# actually SAY?
#
# That distinction is the whole point, and it is the one the repo's existing
# enumeration discipline cannot make. "Every expected band named and `success`"
# defeats a MISSING verdict. It is silent about a REPLACED one — the band IS
# named and IS `success`. Different failure modes, different remedies:
#
#   REPLACED   an earlier attempt concluded `failure` and a later one
#              `success`. Two contradicting verdicts at one sha, and nothing
#              has adjudicated between them. Someone must decide whether the
#              red was a flake or a real defect; no tool can decide it for them.
#
#   RETRIED    an earlier attempt concluded `cancelled`/`skipped`/… and a later
#              one `success`. A retry happened but NO verdict was replaced —
#              nothing contradicts the green. Worth stating, not worth blocking.
#
# Usage:
#   ci-attempt-history.sh --repo OWNER/NAME [--observed FILE]
#     reads the 5-field TSV from monitor/ci-observed-runs.jq (FILE or stdin) and
#     writes a 6-field TSV, appending `prior_conclusions`.
#
# Input  : path<TAB>status<TAB>conclusion<TAB>run_attempt<TAB>run_id
# Output : path<TAB>status<TAB>conclusion<TAB>run_attempt<TAB>run_id<TAB>priors
#
# `priors` is a comma-joined list of the conclusions of attempts 1..attempt-1,
# in order. It is EMPTY when run_attempt is 1 (there are no earlier attempts —
# a positive statement, not an unknown).
#
# FAIL-CLOSED (the #745 lesson, one level up). When an attempt cannot be
# fetched, `priors` carries the literal `?` for that attempt — never an empty
# string and never a silent omission. A failed lookup is "could not determine",
# which is NOT "determined that nothing failed"; collapsing those two is how an
# ancestry check against an unfetched object got read as a negative answer
# earlier in this same PR family. monitor/ci-trigger-audit.py treats a `?` as
# UNDETERMINED and reports it rather than passing over it.
#
# API cost: ZERO calls for the common case. A run at attempt 1 — every run, on
# every head that was never re-run — is passed through untouched. Only a
# retried run is fetched, once per superseded attempt.
set -uo pipefail

REPO=""
OBSERVED=""

die() { printf 'ci-attempt-history: %s\n' "$*" >&2; exit 2; }

while (( $# )); do
    case "$1" in
        --repo)     REPO="${2:-}"; shift 2 ;;
        --observed) OBSERVED="${2:-}"; shift 2 ;;
        -h|--help)  sed -n '2,50p' "$0"; exit 0 ;;
        *)          die "unknown argument: $1" ;;
    esac
done

[[ -n "$REPO" ]] || REPO="${GITHUB_REPOSITORY:-}"
[[ -n "$REPO" ]] || die "--repo OWNER/NAME is required (or set GITHUB_REPOSITORY)"

# Refuse rather than degrade: with no `gh` we cannot resolve ANY prior attempt,
# and emitting rows whose `priors` are all empty would assert "no earlier
# attempt failed" on the strength of not having looked. Exit 2 is the audit's
# own fail-closed code.
command -v gh >/dev/null 2>&1 \
    || die "gh is not on PATH; refusing to report attempt history it could not read"

# _priors <run-id> <attempt-count>
# Echo the comma-joined conclusions of attempts 1..(attempt-count - 1).
_priors() {
    local id="$1" attempt="$2" n out="" conc
    for (( n = 1; n < attempt; n++ )); do
        # `.conclusion` is null while an attempt is in flight, but a SUPERSEDED
        # attempt is always terminal, so null here means the field was absent —
        # unknown, not "none". Both the fetch failure and the null map to `?`.
        conc=$(gh api "/repos/${REPO}/actions/runs/${id}/attempts/${n}" \
                   --jq '.conclusion // empty' 2>/dev/null) || conc=""
        [[ -n "$conc" ]] || conc="?"
        out="${out:+$out,}$conc"
    done
    printf '%s' "$out"
}

_stream() {
    if [[ -n "$OBSERVED" ]]; then
        [[ -r "$OBSERVED" ]] || die "cannot read --observed $OBSERVED"
        cat -- "$OBSERVED"
    else
        cat
    fi
}

# _field <n> <line> — 1-indexed TSV field, empty when the row is too short.
#
# NOT `IFS=$'\t' read -r a b c ...`. TAB is an IFS WHITESPACE character, so
# bash collapses runs of it and DROPS empty fields — and an in-flight run has
# an EMPTY conclusion, so every column after it shifts left. Measured:
#   printf 'a\tcompleted\t\t2\t99\tfailure\n' | while IFS=$'\t' read -r p s c a i r
#   → concl=[2] attempt=[99] id=[failure] priors=[]
# i.e. a pending run reads back as a 99th attempt. Nor is chained prefix-
# stripping (`x=${rest%%<TAB>*}; rest=${rest#*<TAB>}`) safe on its own: on a
# row with FEWER fields than expected, `${rest#*<TAB>}` finds no tab and
# returns the string UNCHANGED, so the last two variables silently receive the
# same value. Counting the strips is what makes a short row read as empty
# rather than as a duplicate.
_field() {
    local n="$1" line="$2" i=1
    while (( i < n )); do
        [[ "$line" == *$'\t'* ]] || { printf ''; return 0; }
        line=${line#*$'\t'}
        i=$(( i + 1 ))
    done
    printf '%s' "${line%%$'\t'*}"
}

# IFS='' + -r so a field is never word-split or de-escaped; the TSV is split
# explicitly, field by field, above.
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    path=$(_field 1 "$line")
    status=$(_field 2 "$line")
    conclusion=$(_field 3 "$line")
    attempt=$(_field 4 "$line")
    run_id=$(_field 5 "$line")
    [[ -n "$path" ]] || continue
    # Tolerate a short row the way read_observed_runs() does: an unparsable
    # attempt is treated as 1 (no history to report), never as a licence to
    # guess.
    [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=1
    [[ "$run_id"  =~ ^[0-9]+$ ]] || run_id=""

    priors=""
    if (( attempt > 1 )); then
        if [[ -n "$run_id" ]]; then
            priors=$(_priors "$run_id" "$attempt")
        else
            # We know a retry happened (attempt > 1) and cannot say what it
            # replaced. That is precisely the UNDETERMINED case.
            priors=$(printf '?%.0s,' $(seq 2 "$attempt")); priors=${priors%,}
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$path" "$status" "$conclusion" "$attempt" "$run_id" "$priors"
done < <(_stream)
