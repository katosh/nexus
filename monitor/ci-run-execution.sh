#!/usr/bin/env bash
# ci-run-execution.sh — did a `failure` run EXECUTE ANYTHING, or was it aborted
# before a single step ran? (your-org/nexus-code#846)
#
# THE DEFECT. monitor/ci-trigger-audit.py classifies on the CONCLUSION STRING
# alone. `VERDICT_CONCLUSIONS = {success, failure}` is a correct allowlist
# (#628) and says nothing about whether the suite ran. So a run that GitHub
# aborted before assigning a runner — an account-billing block, a startup
# failure, a quota refusal — concludes `failure`, and `ng ci-attempts` tells the
# reader "this IS a verdict — a real, red one … read the run's logs and fix the
# code, this is not a CI-plumbing gap". Observed live on #837 (head 0b45293a)
# and again all evening on 2026-08-08: ten of ten jobs, `steps: []`, 2-4s
# durations, `runner_id: 0`, and a `BlobNotFound` on every log fetch. There were
# no logs to read and no code to fix; it was precisely a CI-plumbing gap.
#
# THE DIRECTION OF THE FIX IS THE WHOLE DESIGN. Today a plumbing gap is misread
# as a code red: the cost is a misrouted reader. A careless fix INVERTS that —
# a real code red misread as a plumbing gap — and the cost becomes broken code
# merged because the gate said "not your fault". So this script emits POSITIVE
# EVIDENCE or it emits `unknown`, and `unknown` keeps the run RED. It never
# infers "nothing executed" from anything it could not read.
#
#   "no steps data" and "zero steps executed" are DIFFERENT PROPOSITIONS,
#   and only the second one may downgrade a red.
#
# That sentence is the contract. Every arm below exists to keep the first
# proposition out of the second's token.
#
# Usage:
#   ci-run-execution.sh --repo OWNER/NAME [--observed FILE]
#     reads the 6-field TSV from monitor/ci-attempt-history.sh (FILE or stdin)
#     and writes an 8-field TSV, appending `execution` and `execution_detail`.
#
# Input  : path<TAB>status<TAB>conclusion<TAB>run_attempt<TAB>run_id<TAB>priors
# Output : …<TAB>priors<TAB>execution<TAB>execution_detail
#
# `execution` is one of FOUR tokens, and only the second one is a licence:
#
#   executed     a COMPLETE, non-empty jobs enumeration in which EVERY job ran at
#                least one step. The run SPOKE, wholly; its `failure` is a real
#                red and nothing about it was infrastructure.
#   mixed        at least one job ran a step and NOT every job did (or the
#                enumeration could not be vouched complete, so "every job" is
#                unestablished). The run still SPOKE — this classifies RED
#                exactly like `executed` — but the strong sentence "this is not
#                a CI-plumbing gap" is FALSE of it, because part of it was.
#                Held distinct for that reason alone (PR #854 skeptic, F2): the
#                token selects which message prints, and collapsing `mixed` into
#                `executed` makes the audit assert, on the one sentence #846
#                exists to discipline, more than it measured.
#   unexecuted   the ONLY token that downgrades. Every condition below held:
#                the jobs enumeration was complete (`total_count` equals the
#                number returned) and non-empty; EVERY job carried a `steps`
#                field that is genuinely an ARRAY and that array is EMPTY; and
#                NO job was ever assigned a runner (`runner_id == 0` and
#                `runner_name == ""`). Two independent signals — nothing to run
#                and nobody to run it — because one of them alone can be an
#                artefact of the API rather than an observation about CI.
#   unknown      could not tell. A failed call, a truncated page, a `steps`
#                field that is absent or null rather than an empty array, an
#                empty jobs list, or a job that HAD a runner and still reports
#                zero steps. All of these read as RED downstream, which is the
#                point: this is the arm that must absorb every case nobody
#                enumerated, and it defaults into it.
#   not-checked  this row's conclusion is not `failure`, so execution evidence
#                cannot change how it classifies. Zero API calls spent. Held
#                distinct from `unknown` because they are different facts —
#                "the answer cannot matter here" vs "the answer matters and I
#                could not get it" — and because collapsing them would make the
#                cost argument unauditable.
#
# `execution_detail` is FREE TEXT for a human and is consulted by NO
# classifier. When the token is `unexecuted` it carries GitHub's own
# annotation for the first job where one exists (that is where the string
# "The job was not started because recent account payments have failed…"
# comes from), which is the sentence that actually tells an operator what to
# do. It is sanitised of TABs and newlines so it cannot shift a column.
#
# WHY `runner_id` AND NOT DURATION. The issue suggested corroborating with
# `completed_at - started_at`. Duration is a proxy: a real red that dies in its
# first step is also seconds long, so a duration threshold would have to be
# guessed and would fail in the dangerous direction the day somebody's test
# failed fast. `runner_id == 0` is not a proxy — it is the assertion that no
# machine was ever assigned, which is the mechanism itself. Measured on this
# repo, 2026-08-08:
#
#   run 31281274254 (billing-blocked) job[0]: steps=[] runner_id=0   runner_name=""
#   run 31273255314 (a real red)      job[0]: steps=6  runner_id=1000007946
#
# API COST. ZERO calls for a row whose conclusion is not `failure` — which is
# every row of a green head, the overwhelmingly common case. One jobs call per
# failing run, and one further annotations call ONLY on a run already
# classified `unexecuted` (i.e. only when CI is already broken), spent purely
# to improve the message.
set -uo pipefail

REPO=""
OBSERVED=""

die() { printf 'ci-run-execution: %s\n' "$*" >&2; exit 2; }

while (( $# )); do
    case "$1" in
        --repo)     REPO="${2:-}"; shift 2 ;;
        --observed) OBSERVED="${2:-}"; shift 2 ;;
        # DERIVED, not a line range — the same reasoning as ci-head-attempts.sh:
        # a hardcoded `sed -n '2,80p'` truncates the moment the header grows,
        # and a doc that quietly stops is the shape this file is about.
        -h|--help)  awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
        *)          die "unknown argument: $1" ;;
    esac
done

[[ -n "$REPO" ]] || REPO="${GITHUB_REPOSITORY:-}"
[[ -n "$REPO" ]] || die "--repo OWNER/NAME is required (or set GITHUB_REPOSITORY)"

# Refuse rather than degrade. Emitting rows whose `execution` is a bare
# `unexecuted` on the strength of not having looked is the inverted failure this
# whole file exists to prevent. Refusing is safe because the caller's documented
# fallback is the UNENRICHED rows, which read as `unknown`, which stays RED.
command -v gh >/dev/null 2>&1 \
    || die "gh is not on PATH; refusing to report execution evidence it could not read"
command -v jq >/dev/null 2>&1 \
    || die "jq is not on PATH; refusing to report execution evidence it could not read"

# One TAB-free, newline-free line. Truncated so a pathological annotation cannot
# turn one row into a screenful. The default budget is for a COMPOSED detail
# (this script's own sentence plus GitHub's); `_sanitize <text> <max>` takes a
# tighter one for the annotation alone, so the two caps compose instead of the
# outer one cutting the inner text off mid-word — which it did, losing the
# operative word "settings" from the billing message on first run.
_sanitize() {
    printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-"${2:-420}"
}

# _annotation <check-run-id> — GitHub's own explanation, or "".
_annotation() {
    local id="$1" msg
    [[ "$id" =~ ^[0-9]+$ ]] || return 0
    msg=$(gh api "/repos/${REPO}/check-runs/${id}/annotations" \
              --jq '[.[] | .message] | join(" / ")' 2>/dev/null) || msg=""
    printf '%s' "$msg"
}

# _classify <run-id> — echo `<token><TAB><detail>`.
#
# The jq below type-checks `.steps` EXPLICITLY. `null | length` is 0 in jq, so
# a job whose `steps` field is absent would otherwise count as "an empty steps
# array" — "no data" wearing "zero" as a costume, which is the one substitution
# this script may not make.
_classify() {
    local id="$1" body counts total returned executed arrayed runnered chk ann v

    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
        printf 'unknown\tno run id in the observed-runs row, so its jobs could not be fetched'
        return 0
    fi

    # `filter=latest` is the default and is stated anyway: the conclusion being
    # classified is the LATEST attempt's, so the jobs consulted must be the
    # latest attempt's too. Silently classifying attempt 1's jobs against
    # attempt 3's conclusion would be a mismatched pair that reads as evidence.
    body=$(gh api "/repos/${REPO}/actions/runs/${id}/jobs?per_page=100&filter=latest" 2>/dev/null) \
        || { printf 'unknown\tthe jobs API call for run %s failed — could not look, which is NOT looked-and-found-nothing' "$id"; return 0; }

    counts=$(jq -r '
        def isarr: (.steps | type) == "array";
        (.jobs // []) as $j
        | [ (.total_count // -1),
            ($j | length),
            ([$j[] | select(isarr and ((.steps | length) > 0))] | length),
            ([$j[] | select(isarr and ((.steps | length) == 0))] | length),
            ([$j[] | select(((.runner_id // 0) != 0)
                            or ((.runner_name // "") != ""))] | length),
            ([$j[] | select(has("runner_id") and has("runner_name"))] | length),
            (($j[0].check_run_url // "") | split("/") | last // "")
          ] | @tsv' <<<"$body" 2>/dev/null) \
        || { printf 'unknown\tthe jobs payload for run %s did not parse' "$id"; return 0; }

    IFS=$'\t' read -r total returned executed arrayed runnered runnerknown chk <<<"$counts"
    # Belt and braces: a field that is not a number means the payload was not
    # the shape this arm claims to understand.
    for v in "$total" "$returned" "$executed" "$arrayed" "$runnered" "$runnerknown"; do
        [[ "$v" =~ ^-?[0-9]+$ ]] || {
            printf 'unknown\tthe jobs payload for run %s did not yield countable fields' "$id"
            return 0
        }
    done

    # POSITIVE EVIDENCE OF EXECUTION WINS OUTRIGHT, before any completeness
    # question. A truncated page that already shows a step having run is still
    # proof something ran, and every ordering doubt here is resolved toward RED.
    #
    # `executed` is reserved for the case where that evidence covers the WHOLE
    # run: a complete enumeration in which every job ran. Anything weaker —
    # some jobs ran and some did not, or the page could not be vouched complete
    # so "every job" is unestablished — is `mixed`. Both classify RED; only
    # `executed` licenses "this is not a CI-plumbing gap".
    if (( executed > 0 )); then
        if (( total == returned && executed == returned )); then
            printf 'executed\tall %d job(s) ran at least one step' "$returned"
        elif (( total != returned )); then
            printf 'mixed\t%d of the %d job(s) on this page ran at least one step, but the enumeration is INCOMPLETE (API reports %s) — something ran, and "everything ran" is not established' \
                "$executed" "$returned" "$total"
        else
            printf 'mixed\t%d of %d job(s) ran at least one step; the other %d ran none — the red is real, but part of this run never started' \
                "$executed" "$returned" "$(( returned - executed ))"
        fi
        return 0
    fi
    if (( total != returned )); then
        printf 'unknown\tjobs enumeration is INCOMPLETE for run %s (API reports %s, this page returned %s) — a hidden job may have executed' "$id" "$total" "$returned"
        return 0
    fi
    if (( returned == 0 )); then
        printf 'unknown\tthe jobs list for run %s is EMPTY — zero jobs returned is not the same observation as zero steps executed' "$id"
        return 0
    fi
    if (( arrayed != returned )); then
        printf 'unknown\t%d of %d job(s) of run %s carry no `steps` ARRAY at all — an absent field is not an empty one' \
            "$(( returned - arrayed ))" "$returned" "$id"
        return 0
    fi
    if (( runnered != 0 )); then
        printf 'unknown\t%d of %d job(s) of run %s WERE assigned a runner and still report zero steps — that is ambiguous, not exculpatory' \
            "$runnered" "$returned" "$id"
        return 0
    fi
    # PRESENCE, not just value (PR #854 skeptic, F3). `(.runner_id // 0)` above
    # coerces an ABSENT field to the exculpatory 0 — the identical coercion this
    # file refuses for `.steps`, where the jq type-check exists precisely because
    # `null | length` is 0. Applying the rule to the primary signal and not to
    # the corroborating one would make the "two independent signals" claim in
    # the header false by its own argument: an omitted field is not an
    # observation that no runner was assigned.
    if (( runnerknown != returned )); then
        printf 'unknown\t%d of %d job(s) of run %s carry no runner fields at all — an absent field is not an observation that no runner was assigned' \
            "$(( returned - runnerknown ))" "$returned" "$id"
        return 0
    fi

    ann=$(_annotation "$chk")
    if [[ -n "$ann" ]]; then
        printf 'unexecuted\tall %d job(s) ran zero steps and none was ever assigned a runner. GitHub says: %s' \
            "$returned" "$(_sanitize "$ann" 260)"
    else
        printf 'unexecuted\tall %d job(s) ran zero steps and none was ever assigned a runner; GitHub supplied no annotation explaining why' \
            "$returned"
    fi
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
# NOT `IFS=$'\t' read -r …`: TAB is an IFS WHITESPACE character, so bash
# collapses runs of it and DROPS empty fields, and an in-flight run has an EMPTY
# conclusion — every column after it would shift left. Same function, same
# reason, as monitor/ci-attempt-history.sh and monitor/ci-head-attempts.sh.
_field() {
    local n="$1" line="$2" i=1
    while (( i < n )); do
        [[ "$line" == *$'\t'* ]] || { printf ''; return 0; }
        line=${line#*$'\t'}
        i=$(( i + 1 ))
    done
    printf '%s' "${line%%$'\t'*}"
}

while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    path=$(_field 1 "$line")
    status=$(_field 2 "$line")
    conclusion=$(_field 3 "$line")
    attempt=$(_field 4 "$line")
    run_id=$(_field 5 "$line")
    priors=$(_field 6 "$line")
    [[ -n "$path" ]] || continue

    if [[ "$conclusion" == "failure" ]]; then
        verdict=$(_classify "$run_id")
    else
        verdict=$(printf 'not-checked\tconclusion is %s, not `failure` — execution evidence cannot change how this row classifies, so no API call was spent' \
                         "${conclusion:-<in flight>}")
    fi
    execution=${verdict%%$'\t'*}
    detail=${verdict#*$'\t'}

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$path" "$status" "$conclusion" "$attempt" "$run_id" "$priors" \
        "$execution" "$(_sanitize "$detail")"
done < <(_stream)
