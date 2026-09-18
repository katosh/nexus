#!/usr/bin/env bash
# ci-diag-budget.sh — the diagnostics budget is DERIVED from the job's
# REMAINING time, never a constant (your-org/nexus-code#1442).
#
# THE STRUCTURAL POINT. In tests.yml the diagnostics step runs INSIDE the same
# job as the suite, so it spends the same `timeout-minutes` — and its budget
# used to be a constant (`DIAG_BUDGET_S=420`) evaluated against `$SECONDS`,
# which RESTARTS AT ZERO FOR EVERY STEP. So the budget had no knowledge of how
# much wall clock the suite had already spent: a sound constant when the suite
# ran ~1800 s of a 2400 s ceiling, and silently insufficient once the suite
# grew — measured at 384-407 s of room on the three 40-minute bands against a
# 420 s permission, with a worst case of ~660 s because both checks are
# PRE-checks and a 240 s per-suite cap is granted twice. The failure that
# follows is the expensive one: a ceiling kill reports `cancelled`, ships no
# verdict, no diagnostics and no artifact, and is indistinguishable from a
# concurrency cancel (#992) — so a red the suite had ALREADY ESTABLISHED is
# converted into a non-verdict, hardest exactly when the tree is most broken.
#
# THE BUDGET IS A PROPERTY OF THE JOB'S CLOCK, so it is computed from the
# job's own start epoch (recorded into $GITHUB_ENV by the job's first step)
# and the job's own ceiling (its `timeout-minutes`, passed in seconds so the
# two cannot drift apart unnoticed — test-ci-diag-budget.sh pins that they
# agree in tests.yml). An upload reserve is held back so the artifact that
# carries the partial dump is itself never the thing the ceiling kills.
#
# Usage:
#   ci-diag-budget.sh <ceiling-seconds> <job-start-epoch> [<upload-reserve-seconds>]
#       prints two `KEY=VALUE` lines for `$GITHUB_ENV`/eval:
#         DIAG_BUDGET_S    = max(0, min(420, ceiling - (now - start) - reserve))
#         DIAG_PER_SUITE_S = min(240, DIAG_BUDGET_S)
#       Without the per-suite clamp a 240 s suite started with 100 s of budget
#       left still overruns — that is the pre-check overshoot, closed here.
#       The reserve defaults to 120 s.
#   ci-diag-budget.sh --elapsed <ceiling-seconds> <job-start-epoch>
#       prints `elapsed XmYYs of Zm ceiling (P% used)` — the line a band prints
#       before it can be killed, so a ceiling kill is legible from the log
#       rather than only from the jobs API (#1443 remedy 1).
#
# Exit: 0 on a computed answer (a ZERO budget is a computed answer — it is the
#       arm that turns a real verdict into a non-verdict, and it must print
#       rather than fall back to a constant); 2 on a non-numeric argument,
#       printing NOTHING on stdout — a refusal must never be `eval`-able as a
#       budget.
#
# NEXUS_DIAG_NOW overrides the clock (tests only).
set -uo pipefail

_cdb_num() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
_cdb_die() { printf 'ci-diag-budget: %s\n' "$*" >&2; exit 2; }

mode=budget
if [ "${1:-}" = "--elapsed" ]; then mode=elapsed; shift; fi
ceiling="${1:-}"; start="${2:-}"; reserve="${3:-120}"
_cdb_num "$ceiling" || _cdb_die "ceiling-seconds must be a non-negative integer (got '${ceiling}')"
_cdb_num "$start"   || _cdb_die "job-start-epoch must be a non-negative integer (got '${start}')"
_cdb_num "$reserve" || _cdb_die "upload-reserve-seconds must be a non-negative integer (got '${reserve}')"
now="${NEXUS_DIAG_NOW:-$(date +%s)}"
_cdb_num "$now" || _cdb_die "clock unreadable (got '${now}')"

elapsed=$(( now - start )); (( elapsed < 0 )) && elapsed=0

if [ "$mode" = elapsed ]; then
    pct=0; (( ceiling > 0 )) && pct=$(( elapsed * 100 / ceiling ))
    printf 'elapsed %dm%02ds of %dm ceiling (%d%% used)\n' \
        $(( elapsed / 60 )) $(( elapsed % 60 )) $(( ceiling / 60 )) "$pct"
    exit 0
fi

remaining=$(( ceiling - elapsed - reserve ))
(( remaining < 0 )) && remaining=0
budget=$remaining
(( budget > 420 )) && budget=420
per_suite=$budget
(( per_suite > 240 )) && per_suite=240
printf 'DIAG_BUDGET_S=%d\nDIAG_PER_SUITE_S=%d\n' "$budget" "$per_suite"
exit 0
