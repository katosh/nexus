#!/usr/bin/env bash
# ci-band-coverage.sh — did this CI band's red COST COVERAGE, or is it cosmetic?
# (your-org/nexus-code#1474, finding 1.)
#
# A unit band killed at `timeout-minutes` reports `conclusion=cancelled`, which
# `gh pr checks` renders as `fail`. Two different things hide behind that one
# word, measured on this repo's own PRs (2026-09-07):
#
#   MID-RUN kill      #1479 zsh band: 434 verdicts against 447 discovered —
#                     13 suites never reached. Real coverage gap; the missing
#                     members are exactly what has to be shown covered elsewhere.
#   TEARDOWN kill     #1480 bash band: 447 of 447 verdicted, the kill landed in
#                     the runner's post-job cleanup. Zero coverage lost.
#
# The discriminator is SET MEMBERSHIP, never a count: on #1479 the two bands'
# verdict totals could have matched while differing by members each way. So
# this tool compares the SET of suites carrying a verdict line in the job log
# against the POPULATION the runner discovered at that head, and names the
# difference.
#
# AND THE LOG TAIL PROVES NOTHING. The first thing a reader reaches for is the
# last lines — credential cleanup, "Cleaning up orphan processes" — and reads
# them as "the kill landed in teardown". Measured on #1482's own cancelled
# band (2026-09-07): a byte-identical teardown tail on a MID-RUN kill missing
# 22 of 452 suites. The runner runs its cleanup after a cancellation whichever
# way it was killed, so both classes end the same way; only the verdict set
# discriminates, and this tool says so in its output.
#
# Usage:
#   monitor/ci-band-coverage.sh <job-id> [--repo OWNER/NAME]
#                     REFUSES (exit 2) a job from a SHADOW RUN — one whose
#                     name still carries an unexpanded `${{ matrix.… }}`,
#                     meaning the run dispatched nothing (#1485).
#   monitor/ci-band-coverage.sh <job-id> --print-repo     # the derived OWNER/NAME, no network
#   monitor/ci-band-coverage.sh --log-file F --population-file F [--conclusion C] [--job-name N]   (offline / test seam)
#
# Output (one machine-readable line on stdout, detail after it):
#   job=<id> conclusion=<c> discovered=<n> population=<m> reported=<r> missing=<k> verdict=<v>
#     verdict  complete        every discovered suite carries a verdict. With
#                              conclusion=cancelled that is a TEARDOWN kill —
#                              a cosmetic red, nothing to cover elsewhere.
#              mid-run-kill    conclusion=cancelled and suites are missing:
#                              the coverage gap, members listed.
#              incomplete      suites are missing and the job was NOT
#                              cancelled (a crash, a runner fault) — also a gap.
#
# Exit codes:
#   0  complete (coverage intact)
#   1  coverage LOST (mid-run-kill or incomplete) — the missing members are printed
#   2  REFUSED — could not determine: empty log (the stale-`gh`-client trap: a
#      zero-line log at rc 0, your-org/nexus-code#755); a log that never reaches
#      GitHub's `Post job cleanup.` line (TRUNCATED fetch or still STREAMING —
#      both end without verdict lines exactly as a teardown kill does, and only
#      the kill is safe); a job with no conclusion yet; all verdicts present but
#      the runner's `=== suite total:` footer absent (truncation between the
#      last verdict and the total); population unresolvable; or the population
#      sources DISAGREE (the log's `Discovered N tests`, the runner footer's
#      `across N tests`, the tree's suite set at the head sha). "Could not look"
#      is never "complete".
#   3  usage
#
# WHY THE POPULATION IS RESOLVED TWO WAYS. The log says `Discovered N tests`
# (a COUNT); the tree at the head sha gives the SET, using the runner's own
# predicate (`find monitor monitor/watcher -maxdepth 1 -name 'test-*.sh'`,
# tests.yml). A set is needed to NAME the missing members; the count is the
# independent total the set is checked against, so a truncated or mis-scoped
# enumeration cannot pass as the population. Disagreement is a refusal.
#
# Reads only. Never `| head`: the log is read once into a file and every
# extraction is a full pass (the early-exit-reader manifest tracks the
# alternative, and its status would be consumed here).

set -uo pipefail

_usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 3; }

JOB="" REPO="" LOG_FILE="" POP_FILE="" CONCLUSION="" PRINT_REPO=0 JOB_NAME=""
# OWNER/NAME from a remote URL, https or ssh, with or without `.git`. The first
# cut used `[^/]+?` — ERE has no lazy quantifier, so the group swallowed `.git`
# and every job read 404 on `your-org/nexus-code.git` (found on #1481's own
# run, 2026-09-07). Strip the suffix in its own step; a `--print-repo` mode
# makes the derivation observable without a network call.
_cbc_repo_from_url() {
    printf '%s' "$1" | sed -nE 's#.*[:/]([^/]+/[^/]+)$#\1#p' | sed -E 's/\.git$//'
}
while (( $# > 0 )); do
    case "$1" in
        --repo)            REPO="${2:-}"; shift 2 ;;
        --print-repo)      PRINT_REPO=1; shift ;;
        --log-file)        LOG_FILE="${2:-}"; shift 2 ;;
        --population-file) POP_FILE="${2:-}"; shift 2 ;;
        --conclusion)      CONCLUSION="${2:-}"; shift 2 ;;
        --job-name)        JOB_NAME="${2:-}"; shift 2 ;;
        -h|--help)         _usage ;;
        -*)                printf 'ci-band-coverage: unknown option %q\n' "$1" >&2; exit 3 ;;
        *)                 [[ -z "$JOB" ]] || { printf 'ci-band-coverage: one job id only\n' >&2; exit 3; }; JOB="$1"; shift ;;
    esac
done
if [[ -z "$LOG_FILE" && -z "$JOB" ]]; then _usage; fi
if [[ -n "$JOB" && ! "$JOB" =~ ^[0-9]+$ ]]; then printf 'ci-band-coverage: job id must be numeric, got %q\n' "$JOB" >&2; exit 3; fi

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_self_dir/.." && pwd)
# _cbc_refuse_if_shadow_run <job-name> — exits 2 when the name still carries an
# unexpanded matrix template. Reached from BOTH the network path and the
# --job-name seam, so the tested code is the running code.
_cbc_refuse_if_shadow_run() {
    local n="${1:-}"
    [[ "$n" == *'${{'* ]] || return 0
    printf 'ci-band-coverage: REFUSED — job %s belongs to a SHADOW RUN: its name still carries an unexpanded matrix template (%s), so the run expanded no matrix and dispatched nothing (your-org/nexus-code#1485).\n' "${JOB:-offline}" "$n" >&2
    printf '  A PR body/title edit spawns a fully-skipped run that is the NEWEST at the sha, so it wins every latest-first view including `gh pr checks` — which then reports `skipping` for every check while a full battery runs unseen.\n' >&2
    printf '  Select the run by ID, or filter actions/runs by event AND status, and re-run against a job from the run that actually dispatched.\n' >&2
    exit 2
}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# The offline seam applies the SAME predicate before anything else is read.
_cbc_refuse_if_shadow_run "$JOB_NAME"

# ---- 1. the log ---------------------------------------------------------
if [[ -z "$LOG_FILE" ]]; then
    if [[ -z "$REPO" ]]; then
        REPO=$(_cbc_repo_from_url "${CI_BAND_COVERAGE_REMOTE_URL:-$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)}")
    fi
    [[ -n "$REPO" ]] || { printf 'ci-band-coverage: REFUSED — cannot resolve the repo; pass --repo OWNER/NAME\n' >&2; exit 2; }
    if [[ "$PRINT_REPO" == 1 ]]; then printf '%s\n' "$REPO"; exit 0; fi
    # Job → conclusion + run → head sha. `gh api`, never `gh run view --job --log`,
    # which serves the run's LATEST attempt regardless of the job id (#755).
    if ! gh api "repos/${REPO}/actions/jobs/${JOB}" > "$WORK/job.json" 2>"$WORK/job.err"; then
        printf 'ci-band-coverage: REFUSED — could not read job %s on %s: %s\n' "$JOB" "$REPO" "$(tr '\n' ' ' < "$WORK/job.err")" >&2; exit 2
    fi
    CONCLUSION=$(jq -r '.conclusion // "in-progress"' "$WORK/job.json")
    RUN_ID=$(jq -r '.run_id // empty' "$WORK/job.json")
    # ---- SELECTING THE RIGHT RUN IS THE STEP BEFORE CLASSIFYING IT
    # (your-org/nexus-code#1485), and it had no guard.
    #
    # `tests.yml` includes `edited` in its `types:` for a load-bearing reason
    # (#604: retargeting a PR's base emits ONLY `edited`, so without it a
    # rebased PR keeps a verdict from the old base). Every job is then gated on
    # `edited => the base changed`, so a title/body edit costs no runner
    # minutes — and produces a fully-SKIPPED run that is nonetheless THE NEWEST
    # RUN AT THAT SHA. It therefore wins every latest-first view, including
    # `gh pr checks`, which is *the* command for "is this PR ready".
    #
    # MEASURED on #1481 @ 3ecc3e35:
    #   34100027613  pull_request  08:19:55Z  completed    skipped   <- a body edit
    #   34099961873  pull_request  08:19:08Z  in_progress  -         <- the actual push
    # `gh pr checks 1481` reported EVERY check as `skipping`, each linking to
    # the shadow run. The real battery — five unit bands mid-flight — did not
    # appear at all. `skipping` is not red, so nothing alarms; it reads as "CI
    # didn't need to run here", which is a sentence with a plausible meaning in
    # a repo whose other workflows do carry `paths:` filters. A merge taken
    # from that view is taken with NO VERDICT AT ALL.
    #
    # THE DISCRIMINATOR IS FREE: a skipped run never expands its matrix, so its
    # check names keep the LITERAL template.
    #     unit suite (${{ matrix.login_shell }}, jobs ${{ matrix.jobs }})   <- shadow
    #     unit suite (zsh, jobs 4)                                          <- dispatched
    # An unexpanded `${{` in a job name means you are looking at a run that
    # dispatched nothing, and no coverage verdict can be read off it.
    JOB_NAME=$(jq -r '.name // empty' "$WORK/job.json")
    _cbc_refuse_if_shadow_run "$JOB_NAME"
    HEAD_SHA=$(gh api "repos/${REPO}/actions/runs/${RUN_ID}" --jq '.head_sha // empty' 2>/dev/null)
    LOG_FILE="$WORK/job.log"
    gh api "repos/${REPO}/actions/jobs/${JOB}/logs" > "$LOG_FILE" 2>"$WORK/log.err" || true
fi
[[ -r "$LOG_FILE" ]] || { printf 'ci-band-coverage: REFUSED — log file %q unreadable\n' "$LOG_FILE" >&2; exit 2; }
if [[ ! -s "$LOG_FILE" ]]; then
    printf 'ci-band-coverage: REFUSED — the job log is EMPTY (0 bytes). A stale gh client returns a zero-line log at rc 0 (your-org/nexus-code#755); an empty log is not a band with no verdicts.\n' >&2
    exit 2
fi

# ---- 1b. is this the WHOLE log? -------------------------------------------
# A TRUNCATED fetch and a job still STREAMING both end without verdict lines,
# exactly as a teardown kill does — and only the teardown kill is safe to read
# as complete. Two independent end markers, both required before any verdict:
#   * GitHub's post-job line (`Post job cleanup.`) — the log reached the end of
#     the job, whatever the job did;
#   * the runner's own footer (`=== suite total: … across N tests; … ===`),
#     which run-tests.sh prints only after its last suite — present on a
#     teardown kill, absent on a mid-run one. Its N is a THIRD population
#     source, checked against the other two below.
if ! grep -qF 'Post job cleanup.' "$LOG_FILE"; then
    printf 'ci-band-coverage: REFUSED — the log never reaches GitHub'"'"'s post-job cleanup line: it is TRUNCATED or the job is still STREAMING. A log without its end cannot be read as complete (and its missing members cannot be trusted either).\n' >&2
    exit 2
fi
FOOTER_N=$(grep -oE '=== suite total: .* across [0-9]+ tests' "$LOG_FILE" | sed -nE 's/.* across ([0-9]+) tests$/\1/p' | sort -u)
case "$(printf '%s\n' "$FOOTER_N" | grep -c .)" in
    0) FOOTER_N="" ;;
    1) : ;;
    *) printf 'ci-band-coverage: REFUSED — several distinct runner footers in one log (%s)\n' "$(printf '%s' "$FOOTER_N" | tr '\n' ' ')" >&2; exit 2 ;;
esac
if [[ "${CONCLUSION:-}" == "" || "$CONCLUSION" == in-progress || "$CONCLUSION" == null ]]; then
    printf 'ci-band-coverage: REFUSED — the job has no conclusion yet (%s); a band still running has nothing to adjudicate\n' "${CONCLUSION:-none}" >&2
    exit 2
fi

# ---- 2. what the band REPORTED: the verdict set --------------------------
# The runner prints `  PASS  test-x.sh   1.71s   16 assertions` (also FAIL,
# SKIP, TIMEOUT); the log prefixes a timestamp. Basenames, one per line.
grep -oE '(PASS|FAIL|SKIP|TIMEOUT|ENVSKIP)[[:space:]]+test-[A-Za-z0-9_.-]+\.sh[[:space:]]+[0-9.]+s' "$LOG_FILE" \
    | awk '{print $2}' | sort -u > "$WORK/reported"
N_REPORTED=$(grep -c . "$WORK/reported")
DISCOVERED=$(grep -oE 'Discovered [0-9]+ tests' "$LOG_FILE" | awk '{print $2}' | sort -u)
case "$(printf '%s\n' "$DISCOVERED" | grep -c .)" in
    0) DISCOVERED="" ;;
    1) : ;;
    *) printf 'ci-band-coverage: REFUSED — the log carries several distinct "Discovered N tests" lines (%s); which band is this?\n' "$(printf '%s' "$DISCOVERED" | tr '\n' ' ')" >&2; exit 2 ;;
esac

# ---- 3. the POPULATION: the set the runner would have dispatched ---------
if [[ -n "$POP_FILE" ]]; then
    [[ -r "$POP_FILE" ]] || { printf 'ci-band-coverage: REFUSED — population file %q unreadable\n' "$POP_FILE" >&2; exit 2; }
    sed 's#.*/##' "$POP_FILE" | grep -E '^test-[A-Za-z0-9_.-]+\.sh$' | sort -u > "$WORK/population"
else
    [[ -n "${HEAD_SHA:-}" ]] || { printf 'ci-band-coverage: REFUSED — no head sha for the job'"'"'s run; cannot enumerate the population\n' >&2; exit 2; }
    if ! git -C "$REPO_ROOT" cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null; then
        git -C "$REPO_ROOT" fetch -q origin "$HEAD_SHA" 2>/dev/null || true
    fi
    if ! git -C "$REPO_ROOT" cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null; then
        printf 'ci-band-coverage: REFUSED — head %s is not in this clone and could not be fetched; the population cannot be enumerated (pass --population-file)\n' "$HEAD_SHA" >&2; exit 2
    fi
    # The runner's predicate: depth-1 test-*.sh under monitor/ and monitor/watcher/.
    git -C "$REPO_ROOT" ls-tree -r --name-only "$HEAD_SHA" \
        | grep -E '^monitor/(watcher/)?test-[^/]+\.sh$' | sed 's#.*/##' | sort -u > "$WORK/population"
fi
N_POP=$(grep -c . "$WORK/population")
(( N_POP > 0 )) || { printf 'ci-band-coverage: REFUSED — the population enumerated EMPTY; a clean sweep over nothing is not a verdict\n' >&2; exit 2; }
if [[ -n "$DISCOVERED" && "$DISCOVERED" != "$N_POP" ]]; then
    printf 'ci-band-coverage: REFUSED — the log says "Discovered %s tests" but the tree at the head enumerates %s; two population sources disagree, so neither is trusted\n' "$DISCOVERED" "$N_POP" >&2
    exit 2
fi
if [[ -n "$FOOTER_N" && "$FOOTER_N" != "$N_POP" ]]; then
    printf 'ci-band-coverage: REFUSED — the runner footer says "across %s tests" but the population is %s; the footer describes a different run\n' "$FOOTER_N" "$N_POP" >&2
    exit 2
fi

# ---- 4. set membership, both directions ------------------------------------
comm -23 "$WORK/population" "$WORK/reported" > "$WORK/missing"
comm -13 "$WORK/population" "$WORK/reported" > "$WORK/extra"
N_MISSING=$(grep -c . "$WORK/missing"); N_EXTRA=$(grep -c . "$WORK/extra")
if (( N_EXTRA > 0 )); then
    printf 'ci-band-coverage: REFUSED — %d reported suite(s) are NOT in the population (%s); the log and the tree describe different bands\n' "$N_EXTRA" "$(tr '\n' ' ' < "$WORK/extra")" >&2
    exit 2
fi

if (( N_MISSING == 0 )) && [[ -z "$FOOTER_N" ]]; then
    # Every suite has a verdict but the runner never printed its footer: the
    # log stops between the last verdict and the total. That is a truncation
    # shape, not a teardown kill — the teardown kill lands AFTER the footer.
    printf 'ci-band-coverage: REFUSED — all %d suites carry a verdict but the runner'"'"'s own footer (=== suite total: …) is absent; the log ends between the last verdict and the total, which is truncation, not a teardown kill\n' "$N_REPORTED" >&2
    exit 2
fi
if (( N_MISSING == 0 )); then
    VERDICT=complete
elif [[ "$CONCLUSION" == cancelled ]]; then
    VERDICT=mid-run-kill
else
    VERDICT=incomplete
fi
printf 'job=%s conclusion=%s discovered=%s population=%s reported=%s missing=%s verdict=%s\n' \
    "${JOB:-offline}" "$CONCLUSION" "${DISCOVERED:-unrecorded}" "$N_POP" "$N_REPORTED" "$N_MISSING" "$VERDICT"
case "$VERDICT" in
    complete)
        if [[ "$CONCLUSION" == cancelled ]]; then
            printf '  TEARDOWN kill: every discovered suite carries a verdict; the cancel landed after the last one. A cosmetic red — nothing to cover elsewhere. (Decided by the verdict SET, not the log tail: a mid-run kill ends with the same cleanup lines.)\n'
        else
            printf '  every discovered suite carries a verdict.\n'
        fi
        exit 0 ;;
    mid-run-kill)
        printf '  MID-RUN kill: %d suite(s) never reached — this is the coverage gap. Show each has a verdict in another band of the same run, or re-run:\n' "$N_MISSING"
        sed 's/^/    /' "$WORK/missing"
        exit 1 ;;
    incomplete)
        printf '  %d suite(s) carry no verdict and the job was NOT cancelled (conclusion=%s) — a crash or runner fault, not a ceiling:\n' "$N_MISSING" "$CONCLUSION"
        sed 's/^/    /' "$WORK/missing"
        exit 1 ;;
esac
