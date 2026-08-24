#!/usr/bin/env bash
# test-merge-ref-base.sh — the merge-ref base check (your-org/nexus-code#823).
#
# WHAT IS BEING GUARDED. A `pull_request` run does not test your branch: it
# tests `refs/pull/N/merge`, a merge commit GitHub computes AT RUN CREATION. If
# the base branch moves afterwards, every green stays green while describing a
# tree that no longer exists. `#823` merged on exactly that, and the enumeration
# that cleared it was correct about everything it checked — which is the point:
# the recipe checked WHICH runs and WHAT conclusions, and never AGAINST WHAT
# BASE.
#
# WHY THIS SUITE EXISTS SEPARATELY FROM test-ci-head-attempts.sh. The arm that
# matters is STALE, and no live PR can be made to demonstrate it on demand — a
# base moves when it moves. So the answer has to be reachable from a fixture,
# which is why `_merge_ref_base` is a sourced library rather than an inline
# function. Every case below drives the REAL function; nothing is reimplemented.
#
# EVERY ASSERTION MATCHES THE STATE AND THE SENTENCE, not merely one of them. A
# state with a wrong detail line is a check that fired for a reason the reader
# cannot verify.
#
# Run: bash monitor/watcher/test-merge-ref-base.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
LIB="$REPO_ROOT/monitor/_merge_ref_base.sh"

. "$_test_dir/_test_helpers.sh"

[[ -r "$LIB" ]] || { echo "FAIL: missing $LIB" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

BASE_A=1111111111111111111111111111111111111111
BASE_B=2222222222222222222222222222222222222222
HEAD_S=3333333333333333333333333333333333333333

# ---- the gh stub ----------------------------------------------------------
# Serves exactly the four calls the library makes, keyed on the endpoint AND on
# the `--jq` expression where one endpoint serves two questions. Per-case inputs
# arrive as files so a case cannot silently reuse the previous case's answers.
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
args="$*"
case "$args" in
  # The PR object serves only the base BRANCH NAME. The tip comes from the ref.
  *"/pulls/"*)             printf 'dev\n' ;;
  *"/git/ref/heads/"*)     cat "$STUB_BASE_SHA" ;;
  *"/actions/runs?head_sha="*) cat "$STUB_RUN_IDS" ;;
  *"/actions/runs/"*"/jobs"*)  cat "$STUB_JOB_IDS" ;;
  *"/actions/jobs/"*"/logs"*)  cat "$STUB_LOG" ;;
  *) exit 1 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/gh"

# `probe <base-sha-file-content> <run-ids> <job-ids> <log-body>` — runs the REAL
# library in a subshell with the stub on PATH, and echoes `<state>|<detail>`.
probe() {
    printf '%s' "$1" > "$WORK/base"; printf '%s' "$2" > "$WORK/runs"
    printf '%s' "$3" > "$WORK/jobs"; printf '%s' "$4" > "$WORK/log"
    PATH="$WORK/bin:$PATH" \
    STUB_BASE_SHA="$WORK/base" STUB_RUN_IDS="$WORK/runs" \
    STUB_JOB_IDS="$WORK/jobs" STUB_LOG="$WORK/log" \
    bash -c '
        set -uo pipefail
        REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
        . "'"$LIB"'"
        _merge_ref_base
        printf "%s|%s\n" "$_MRB_STATE" "$_MRB_DETAIL"
    '
}

CHECKOUT_A="2026-08-08T12:31:26.9Z HEAD is now at ec3412f Merge $HEAD_S into $BASE_A"

echo "=== 1. CURRENT — the run tested the base that is the tip now ==="
got=$(probe "$BASE_A" "9001" "8001" "$CHECKOUT_A")
assert_eq "a run whose merge ref names the current base is 'current'" \
    "${got%%|*}" "current"
assert_contains "…and the detail names the run, the base it tested, and that the tip was READ" \
    "$got" "run 9001 tested against ${BASE_A:0:12}, which EQUALS the live tip"

echo "=== 2. STALE — the base moved after the run was created ==="
# The arm the whole check exists for, and the one no live PR demonstrates on
# demand: same run, same log, base tip now something else.
got=$(probe "$BASE_B" "9001" "8001" "$CHECKOUT_A")
assert_eq "a run whose merge ref names an OLD base is 'stale'" \
    "${got%%|*}" "stale"
assert_contains "…and the detail names BOTH shas, so the reader can see the gap" \
    "$got" "tested against ${BASE_A:0:12}; the live tip of dev is now ${BASE_B:0:12}"

echo "=== 3. UNREAD is its own state, never folded into either answer ==="
# GitHub expires logs, so 'could not read it' is an ordinary state. It must not
# read as 'current' (a base nobody verified is not a verified base) and must not
# block (that would break the verb on every older head).
got=$(probe "$BASE_A" "9001" "8001" "a log with no checkout line at all")
assert_eq "a log carrying no merge line is 'unread', not 'current'" \
    "${got%%|*}" "unread"
assert_contains "…and says what was looked at" "$got" "logs expired"

got=$(probe "$BASE_A" "" "8001" "$CHECKOUT_A")
assert_eq "no successful pull_request run at this head → 'unread'" \
    "${got%%|*}" "unread"
assert_contains "…and says so in those terms" "$got" "no successful pull_request run"

got=$(probe "" "9001" "8001" "$CHECKOUT_A")
assert_eq "an unreadable base sha → 'unread', never a comparison against nothing" \
    "${got%%|*}" "unread"
# THE DEFECT THIS CHECK SHIPPED WITH, pinned so it cannot come back. The first
# cut read the PR object's `.base.sha` — a FROZEN SNAPSHOT that GitHub does not
# advance as the base moves. Run against `#823`, the incident this check is
# named after, it returned `current`.
# The GROUNDS stated here originally were wrong in the direction that
# understates the hazard, and are corrected with the rest (#837 logic review):
# `.base.sha` and `refs/pull/N/merge` do NOT "move together" — they are
# INDEPENDENT freezes on distinct triggers. Measured: `#670` they agree
# (f0c9510/f0c9510); `#811` they diverge (1973ffc vs a91f82b, after one
# `GET /pulls/811` refreshed the ref and left `.base.sha` behind). So the
# snapshot is UNCORRELATED with the question and errs BOTH ways — false-current
# on the `#670` shape (the unsafe direction, the `#823` failure) and false-stale
# on the `#811` shape.
# So the live-tip read must never fall back to the snapshot. Not because such a
# comparison cannot fail, but because it can fail WRONGLY IN EITHER DIRECTION —
# a verdict over something unmeasured, which is worse than no verdict.
assert_contains "…and says it REFUSED to fall back to the frozen .base.sha" \
    "$got" "refusing to fall back"

echo "=== 4. N/A — a bare sha has no merge ref, and that is not 'unread' ==="
got=$(PATH="$WORK/bin:$PATH" bash -c '
    set -uo pipefail
    REPO=owner/repo; PR_NUM=""; SHA='"$HEAD_S"'
    . "'"$LIB"'"
    _merge_ref_base
    printf "%s|%s\n" "$_MRB_STATE" "$_MRB_DETAIL"')
assert_eq "no PR context is 'n/a' — a distinct answer, not a failure to look" \
    "${got%%|*}" "n/a"

echo "=== 5. THE SCAN REACHES PAST A RUN THAT CHECKED OUT NO MERGE REF ==="
# Measured on `#823`: three of its successful runs check out
# `refs/remotes/origin/dev` directly and print no merge line, while the round
# that actually ran the tests prints it. A scan that reads only the first run
# reports 'unread' on the very head this check exists for — an "I looked in the
# wrong place" dressed as "it cannot be known".
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
args="$*"
case "$args" in
  *"/pulls/"*)                 printf 'dev\n' ;;
  *"/git/ref/heads/"*)         cat "$STUB_BASE_SHA" ;;
  *"/actions/runs?head_sha="*) cat "$STUB_RUN_IDS" ;;
  *"/actions/runs/9001/jobs"*) echo 8001 ;;
  *"/actions/runs/9002/jobs"*) echo 8002 ;;
  # 8001 checked out a branch, not the merge ref — no merge line.
  *"/actions/jobs/8001/logs"*) echo "HEAD is now at abc1234 dev branch checkout" ;;
  *"/actions/jobs/8002/logs"*) cat "$STUB_LOG" ;;
  *) exit 1 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/gh"
printf '%s' "$BASE_A" > "$WORK/base"
printf '9001\n9002\n' > "$WORK/runs"
printf '%s' "$CHECKOUT_A" > "$WORK/log"
got=$(PATH="$WORK/bin:$PATH" STUB_BASE_SHA="$WORK/base" STUB_RUN_IDS="$WORK/runs" \
      STUB_LOG="$WORK/log" bash -c '
    set -uo pipefail
    REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
    . "'"$LIB"'"
    _merge_ref_base
    printf "%s|%s\n" "$_MRB_STATE" "$_MRB_DETAIL"')
assert_eq "a first run with no merge line does not stop the scan" \
    "${got%%|*}" "current"
assert_contains "…and the answer names the run it actually came from" \
    "$got" "run 9002"

echo "=== 6. NEGATIVE CONTROL: without the comparison, STALE reads as CURRENT ==="
# The library, mutated on a copy so the equality test always holds. If case 2
# still passed against this, it would be asserting a wording rather than the
# comparison.
sed 's/if \[\[ "\$tested" == "\$base_sha" \]\]; then/if true; then  # NEGATIVE-CONTROL MUTANT (#823)/' \
    "$LIB" > "$WORK/mutant.sh"
if ! grep -q 'NEGATIVE-CONTROL MUTANT (#823)' "$WORK/mutant.sh"; then
    printf '  FAIL: %s\n' "the #823 comparison anchor changed; the negative-control sed no longer applies — update it" >&2
    FAIL=$(( FAIL + 1 ))
else
    cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
args="$*"
case "$args" in
  *"/pulls/"*)                 printf 'dev\n' ;;
  *"/git/ref/heads/"*)         cat "$STUB_BASE_SHA" ;;
  *"/actions/runs?head_sha="*) cat "$STUB_RUN_IDS" ;;
  *"/actions/runs/"*"/jobs"*)  cat "$STUB_JOB_IDS" ;;
  *"/actions/jobs/"*"/logs"*)  cat "$STUB_LOG" ;;
  *) exit 1 ;;
esac
exit 0
STUB
    chmod +x "$WORK/bin/gh"
    printf '%s' "$BASE_B" > "$WORK/base"; printf '9001' > "$WORK/runs"
    printf '8001' > "$WORK/jobs"; printf '%s' "$CHECKOUT_A" > "$WORK/log"
    mgot=$(PATH="$WORK/bin:$PATH" STUB_BASE_SHA="$WORK/base" STUB_RUN_IDS="$WORK/runs" \
           STUB_JOB_IDS="$WORK/jobs" STUB_LOG="$WORK/log" bash -c '
        set -uo pipefail
        REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
        . "'"$WORK"'/mutant.sh"
        _merge_ref_base
        printf "%s\n" "$_MRB_STATE"')
    assert_eq "the mutant calls a STALE base 'current' — so case 2 is the comparison, not a wording" \
        "$mgot" "current"
fi


# ---- assertion-count guard (your-org/nexus-code#805) ----------------------
# An exact expected total, not just the shared ledger. The ledger stops a
# ZERO-assertion run announcing a pass; it cannot see an assertion silently
# dropped from the middle of a suite — which for this file would mean the STALE
# arm quietly disappearing while the summary still says ALL TESTS PASSED.
EXPECTED_ASSERTIONS=14
TOTAL=$(( PASS + FAIL ))
if (( TOTAL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi

th_summary_and_exit
