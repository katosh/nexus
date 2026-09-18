#!/usr/bin/env bash
# Unit tests for monitor/cc-restart-watchdog-loop.sh — the VERSION-POLL
# verify phase (your-org/nexus-code#532).
#
# The sibling test (test-cc-restart-watchdog-loop.sh) stops at ARMING; the
# stub pid never dies, so the loop never reaches phase 4. These tests drive
# the loop ALL THE WAY THROUGH the verify phase by handing it a baseline
# orchestrator pid that is already dead and a fresh (live) pane pid on the
# next query, then controlling the pinned session jsonl to reproduce each
# outcome the #532 hardening must get right:
#
#   S.  a fresh candidate-version record that appears past the baseline
#       offset ⇒ SUCCESS (armed marker removed, exit 0).
#   FLIP (the #532 false-negative). The candidate record lands a few
#       seconds AFTER the soft deadline (flush-visibility lag on a large
#       jsonl). With the GRACE window it still counts ⇒ SUCCESS; run the
#       PRE-FIX loop (from `git show dev:…`) against the SAME timing and it
#       false-negatives ⇒ FAIL. That contrast is the regression.
#   F-grew.   file grows past baseline but no candidate stamp within grace
#       ⇒ growth-aware FAIL naming "OLD binary / wedged resume".
#   F-never.  file never grows past baseline ⇒ FAIL naming "never resumed".
#
# Hermetic: no real tmux, no real claude, no notification escapes (PATH is
# restricted so `command -v sandbox-notify` finds nothing).
#
# Run: bash monitor/watcher/test-cc-restart-watchdog-verify.sh

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MONITOR_DIR=$(cd "$_script_dir/.." && pwd)
NEXUS_SRC=$(cd "$MONITOR_DIR/.." && pwd)
LOOP="$MONITOR_DIR/cc-restart-watchdog-loop.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

CANDIDATE="2.1.212"
SID="0f9c1a2b-3d4e-5f60-8712-9a3b4c5d6e7f"
TARGET="claude"

# ---- fixtures -------------------------------------------------------------

# tmux stub that lets the loop PROGRESS to the verify phase. It counts its
# list-panes calls: the 1st (loop baseline) returns the already-dead
# ORCH_PID so phase 3's kill-wait falls through immediately; the 2nd+ (phase
# 3b) return the live NEW_PID so a "new" pane is detected. list-windows
# returns exactly the TARGET name (single-window + no-standdown checks pass).
# As a side effect on the 2nd list-panes call it optionally appends a record
# to the jsonl (STUB_APPEND) — this is how the deterministic cases inject
# growth / a version stamp strictly AFTER base_size was captured.
make_tmux_stub() {
    local bindir="$1"
    mkdir -p "$bindir"
    cat > "$bindir/tmux" <<'STUB'
#!/usr/bin/env bash
CNT_FILE="$TMUX_STUB_CNT"
if [[ "${1:-}" == "list-panes" ]]; then
    n=$(( $(cat "$CNT_FILE" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$CNT_FILE"
    # TMUX_STUB_POSTKILL: the kill ALREADY happened, so the live pane is the
    # replacement from the very first query — what a re-run of the loop sees.
    if (( n == 1 )) && [[ -z "${TMUX_STUB_POSTKILL:-}" ]]; then
        printf '%s\n' "$TMUX_STUB_ORCH_PID"
    else
        if (( n == 2 )) && [[ -n "${STUB_APPEND:-}" ]]; then
            printf '%s\n' "$STUB_APPEND" >> "$TMUX_STUB_JSONL"
        fi
        printf '%s\n' "$TMUX_STUB_NEW_PID"
    fi
    exit 0
fi
if [[ "${1:-}" == "list-windows" ]]; then
    printf '%s\n' "$TMUX_STUB_TARGET"
    exit 0
fi
exit 0
STUB
    chmod +x "$bindir/tmux"
}

# Miniature nexus root (mirrors the sibling test's make_root).
make_root() {
    local root="$1" baseline_jsonl="$2"
    mkdir -p "$root/config" "$root/monitor/.state" "$root/node_modules/.bin"
    cp "$NEXUS_SRC/config/load.sh" "$root/config/load.sh"
    printf 'monitor:\n  target_window: %s\n' "$TARGET" > "$root/config/nexus.yml"
    cat > "$root/node_modules/.bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s (Claude Code)\n' "$CANDIDATE"
EOF
    chmod +x "$root/node_modules/.bin/claude"
    printf '%s\n' "$SID" > "$root/monitor/.state/orchestrator-session-id"
    local slug projects
    slug=$(printf '%s' "$root" | sed 's|[^a-zA-Z0-9]|-|g')
    projects="$root/projects/$slug"
    mkdir -p "$projects"
    printf '%s' "$baseline_jsonl" > "$projects/$SID.jsonl"
    printf '%s' "$projects/$SID.jsonl"          # echo the jsonl path
}

# A pid guaranteed never to name a live process: the max allocatable pid is
# pid_max-1, so `kill -0 pid_max` is always ESRCH. A reaped child pid would
# work too but risks reuse by the concurrent FLIP writer, which would stall
# phase-3's kill-wait to the deadline — a real race that flaked this test.
dead_pid() {
    local pm; pm=$(cat /proc/sys/kernel/pid_max 2>/dev/null) || pm=""
    [[ -n "$pm" ]] && printf '%s' "$pm" || printf '2147483647'
}

# Run the loop to completion. Sets RC, and leaves markers/log under the root.
RC=0
# LOOP_ARGS: arguments for the loop itself (e.g. --verify-only). KEEP_MARKERS=1
# leaves a pre-planted armed marker in place (the foreign-watchdog case).
LOOP_ARGS=()
run_verify() {
    local root="$1" script="$2" jsonl="$3" append="$4"; shift 4  # rest: env
    local bindir="$root/stubbin" state="$root/monitor/.state"
    make_tmux_stub "$bindir"
    [[ -n "${KEEP_MARKERS:-}" ]] || rm -f "$state/restart-watchdog-armed" "$state/restart-watchdog-failed"
    : > "$root/tmux-cnt"
    env -i PATH="$bindir:/usr/bin:/bin" HOME="$root" \
        TMUX_STUB_CNT="$root/tmux-cnt" TMUX_STUB_TARGET="$TARGET" \
        TMUX_STUB_ORCH_PID="$(dead_pid)" TMUX_STUB_NEW_PID="$$" \
        TMUX_STUB_JSONL="$jsonl" STUB_APPEND="$append" \
        NEXUS_ROOT="$root" NEXUS_STATE_DIR="$state" \
        CC_AUTO_PROJECTS_DIR="$root/projects" \
        "$@" \
        bash "$script" ${LOOP_ARGS[@]+"${LOOP_ARGS[@]}"} >/dev/null 2>&1
    RC=$?
}

armed_removed() { [[ ! -f "$1/monitor/.state/restart-watchdog-armed" ]]; }
failed_marker() { [[ -f "$1/monitor/.state/restart-watchdog-failed" ]]; }
logfile()       { printf '%s' "$1/monitor/.state/restart-watchdog.log"; }

if ! /usr/bin/python3 -c 'import yaml' 2>/dev/null; then
    echo "skipped: /usr/bin/python3 lacks pyyaml (config/load.sh cannot resolve keys)"
    exit 77   # SKIP, not PASS (your-org/nexus-code#568 A6)
fi

BASE='{"version":"2.1.202"}
'
VER_RECORD='{"type":"assistant","version":"'"$CANDIDATE"'"}'
NONVER_RECORD='{"type":"assistant","version":"2.1.202"}'
# The attempt nonce every hand-planted --verify-only baseline carries, and every
# --verify-only run below names (w234sk F1: identity binds the verification).
PK_ATTEMPT="1789000000-4242-777"

# ===== S. deterministic success ============================================
echo "== S: fresh candidate-version record past baseline → SUCCESS =="
RS="$WORK/success"; J=$(make_root "$RS" "$BASE")
run_verify "$RS" "$LOOP" "$J" "$VER_RECORD" WATCHDOG_DEADLINE_SECONDS=10 WATCHDOG_GRACE_SECONDS=5
(( RC == 0 )) && pass "exit 0 on visible candidate version" || fail "exit $RC, want 0"
armed_removed "$RS" && pass "armed marker removed on success" || fail "armed marker not removed"
! failed_marker "$RS" && pass "no failure marker on success" || fail "failure marker written on success"
grep -q "SUCCESS: sid=$SID resumed on $CANDIDATE" "$(logfile "$RS")" \
    && pass "logs SUCCESS with the candidate version" || fail "no SUCCESS log line"
[[ ! -f "$RS/monitor/.state/restart-watchdog-baseline" ]] \
    && pass "SUCCESS removes the baseline (left behind, it is the stale baseline w234sk F1 measured a false SUCCESS against)" \
    || fail "SUCCESS left the baseline file behind"

# ===== FLIP. the #532 false-negative: grace flips it ========================
echo "== FLIP: candidate record lands AFTER the soft deadline (flush lag) =="
# A background writer appends the candidate record ~6 s in — after the 3 s
# soft deadline but well inside a 25 s grace. It MUST run concurrently with
# the loop (its stdout redirected so it doesn't block), so the loop captures
# base_size BEFORE the append and the record is a genuinely FRESH one past
# the baseline. Same fixture, two loops.

# FIXED loop: grace absorbs the lag → SUCCESS.
RF="$WORK/flip-fixed"; J=$(make_root "$RF" "$BASE")
( sleep 6; printf '%s\n' "$VER_RECORD" >> "$J" ) >/dev/null 2>&1 &
w=$!
run_verify "$RF" "$LOOP" "$J" "" WATCHDOG_DEADLINE_SECONDS=3 WATCHDOG_GRACE_SECONDS=25
wait "$w" 2>/dev/null
(( RC == 0 )) && pass "fixed loop + late flush within grace → SUCCESS" \
    || fail "fixed loop false-negatived a late-but-valid flush (exit $RC)"

# PRE-FIX loop (exact code on dev before this change): no grace → FAIL at
# the deadline, before the writer appends. This is the regression control.
# ── WHERE THE PRE-FIX LOOP COMES FROM (your-org/nexus-code#1094 F4) ─────────
# This lifted its pre-fix copy from `git show dev:…` and, when that failed,
# scored `pass "SKIP pre-fix control …"`. Three problems, and the third is why
# this is the most dangerous member of the moving-ref class rather than the
# mildest:
#
#   1. `dev` is a MOVING ref, so once the grace window merged the "pre-fix"
#      loop was the fixed loop — the same expiry that reddened
#      test-pane-state-claude-identity.sh (#1035) and
#      test-session-name-from-window.sh.
#   2. The expired branch asserted `pass`, not a skip. This suite has no skip
#      counter, so an unobtainable control was scored as a control that RAN.
#      Three assertions — extracted the pre-fix loop, it false-negatives the
#      late flush (the #532 bug), it writes the failure marker — were silently
#      replaced by one unconditional PASS. **It is GREEN today.** The two
#      suites that went RED got an issue written about them; this one got
#      nothing, which makes a passing expiry strictly worse than a failing one.
#   3. The condition conflated TWO causes and asserted one of them: measured at
#      `52185e8`, `git rev-parse dev` is `fatal: Needed a single revision` (no
#      such ref in this clone) while `origin/dev`'s blob DOES carry the grace
#      window. The message said "change merged" when the truth was "the ref did
#      not resolve". That is the #828 shape — naming one axis when the other
#      moved — inside the diagnostic a reader would trust.
#
# Repaired the same way PR A repairs the other two: a chain of candidate refs,
# each GATED on genuinely being pre-fix, then a SYNTHESIZED fallback, because
# the git lookup expires and CI checks out at fetch-depth 1. The two causes are
# now distinguished, and an unobtainable control is a FAIL — never a pass.
#
# THE GATE STRIPS COMMENTS, for the third time in this class: the loop's own
# explanatory block names `WATCHDOG_GRACE_SECONDS` at line 127, so a bare
# presence test rejects the correct synthesis. HERESTRING rather than
# `producer | grep -q`: this file runs under pipefail, and `grep -q` SIGPIPEs
# its producer, whose 141 the negation would flip to "this is pre-fix" —
# fail-OPEN, straight back to a control that cannot discriminate.
_wd_is_prefix_loop() {   # <loop-src> -> 0 if it has NO grace window in CODE
    ! grep -q 'WATCHDOG_GRACE_SECONDS' <<<"$(grep -v '^[[:space:]]*#' "$1")"
}
PREFIX_LOOP="$WORK/loop-prefix.sh"
_wd_prov=""
_wd_git_saw_a_ref=0
for _wd_ref in "$(git -C "$NEXUS_SRC" merge-base origin/dev HEAD 2>/dev/null)" \
               origin/dev dev HEAD~1; do
    [ -n "$_wd_ref" ] || continue
    git -C "$NEXUS_SRC" rev-parse --verify --quiet "$_wd_ref" >/dev/null 2>&1 || continue
    _wd_git_saw_a_ref=1
    git -C "$NEXUS_SRC" show "${_wd_ref}:monitor/cc-restart-watchdog-loop.sh" \
        > "$PREFIX_LOOP" 2>/dev/null || continue
    [ -s "$PREFIX_LOOP" ] || continue
    if _wd_is_prefix_loop "$PREFIX_LOOP"; then _wd_prov="git:${_wd_ref}"; break; fi
done
if [ -z "$_wd_prov" ]; then
    # SYNTHESIZE. The whole of the change, as far as this control is concerned,
    # is the grace window; pinning it to 0 restores the old fixed deadline
    # exactly, and does so at any checkout depth.
    sed 's/^GRACE_SECONDS=.*/GRACE_SECONDS=0/' \
        "$NEXUS_SRC/monitor/cc-restart-watchdog-loop.sh" > "$PREFIX_LOOP" 2>/dev/null
    # A MUTANT MUST PROVE IT APPLIED: something changed, it still parses, and
    # the result passes the same gate. A drifted sed would otherwise hand the
    # FIXED loop to the control below, which is the vacuity this block exists
    # to remove.
    if [ -s "$PREFIX_LOOP" ] \
       && ! cmp -s "$PREFIX_LOOP" "$NEXUS_SRC/monitor/cc-restart-watchdog-loop.sh" \
       && bash -n "$PREFIX_LOOP" 2>/dev/null && _wd_is_prefix_loop "$PREFIX_LOOP"; then
        _wd_prov="synthesized"
    fi
fi
if [ -n "$_wd_prov" ]; then
    pass "extracted the pre-fix loop [$_wd_prov] (no grace window)"
    RP="$WORK/flip-prefix"; J=$(make_root "$RP" "$BASE")
    ( sleep 6; printf '%s\n' "$VER_RECORD" >> "$J" ) >/dev/null 2>&1 &
    w=$!
    run_verify "$RP" "$PREFIX_LOOP" "$J" "" WATCHDOG_DEADLINE_SECONDS=3
    wait "$w" 2>/dev/null
    (( RC != 0 )) && pass "pre-fix loop false-negatives the same late flush (the #532 bug)" \
        || fail "pre-fix loop did NOT fail — fixture does not reproduce #532, so FLIP proves nothing"
    failed_marker "$RP" && pass "pre-fix loop writes the failure marker" \
        || fail "pre-fix loop left no failure marker"
else
    # FAIL, not `pass` and not skip — the ONE disposition rule for every control
    # of this shape (your-org/nexus-code#1094, #1100; reasoning written out once
    # at test-pane-state-claude-identity.sh's matching branch). SKIP is for an
    # ENVIRONMENTAL precondition; the synthesis needs no history, refs or
    # network, so the only route here is a drifted sed — a defect in this suite,
    # and a defect must be red. `#1100` poses skip-vs-bad as an open choice for
    # THIS file specifically; this is the answer, applied identically at all
    # three sites. It also names WHICH of the two causes applies instead of
    # asserting one of them, which is the #828 half of `#1100`.
    if (( _wd_git_saw_a_ref )); then
        fail "pre-fix control unavailable: every resolvable ref already carries the grace window AND the synthesis did not apply (its sed has probably drifted from GRACE_SECONDS= in monitor/cc-restart-watchdog-loop.sh)"
    else
        fail "pre-fix control unavailable: NO candidate ref resolved in this clone (not 'the change merged' — a different cause) AND the synthesis did not apply"
    fi
    fail "pre-fix loop false-negatives the same late flush (the #532 bug) — control unavailable"
    fail "pre-fix loop writes the failure marker — control unavailable"
fi

# ===== F-grew. grew but no candidate stamp → OLD-binary/wedged FAIL =========
echo "== F-grew: growth past baseline, no candidate version → FAIL (old binary) =="
RG="$WORK/grew"; J=$(make_root "$RG" "$BASE")
run_verify "$RG" "$LOOP" "$J" "$NONVER_RECORD" WATCHDOG_DEADLINE_SECONDS=1 WATCHDOG_GRACE_SECONDS=1
(( RC != 0 )) && pass "exit non-zero when file grew but no candidate stamp" || fail "exit $RC, want non-zero"
failed_marker "$RG" && pass "failure marker written" || fail "no failure marker"
grep -qi "OLD binary" "$(logfile "$RG")" \
    && pass "verdict names the OLD-binary/wedged case (growth-aware)" \
    || fail "verdict did not distinguish the grew-but-no-version case"
# A post-arm failure RELEASES the armed marker this run wrote. Left behind, it
# made the playbook's re-run exit 9 and held the reconcile single-flight shut
# (measured 2026-09-11: removed by hand after a watchdog FAIL).
armed_removed "$RG" && pass "fail() released the armed marker this run wrote" \
    || fail "fail() left its own armed marker behind"
grep -q "released the armed marker this run wrote" "$(logfile "$RG")" \
    && pass "…and says so, pointing at --verify-only" || fail "no release note in the log"

# ===== F-never. never grew → never-resumed FAIL =============================
echo "== F-never: no growth past baseline → FAIL (never resumed) =="
RN="$WORK/never"; J=$(make_root "$RN" "$BASE")
run_verify "$RN" "$LOOP" "$J" "" WATCHDOG_DEADLINE_SECONDS=1 WATCHDOG_GRACE_SECONDS=1
(( RC != 0 )) && pass "exit non-zero when file never grew" || fail "exit $RC, want non-zero"
failed_marker "$RN" && pass "failure marker written" || fail "no failure marker"
grep -qi "never resumed" "$(logfile "$RN")" \
    && pass "verdict names the never-resumed case (growth-aware)" \
    || fail "verdict did not distinguish the never-grew case"
armed_removed "$RN" && pass "F-never: fail() released the armed marker this run wrote" \
    || fail "F-never: fail() left its own armed marker behind"
BFN="$RN/monitor/.state/restart-watchdog-baseline"
if [[ -f "$BFN" ]] && grep -qx "base_size=${#BASE}" "$BFN" && grep -qx "orch_pid=$(dead_pid)" "$BFN" \
   && grep -qx "sid=$SID" "$BFN" && grep -qx "candidate=$CANDIDATE" "$BFN" \
   && grep -qE '^armed_epoch=[0-9]+$' "$BFN" && grep -qE '^attempt=[0-9]+-[0-9]+-[0-9]+$' "$BFN"; then
    pass "a FAILED armed run keeps its baseline (offset, pid, sid, candidate, armed_epoch, attempt) for a post-kill --verify-only"
else
    fail "failed run's baseline missing or wrong: $(cat "$BFN" 2>/dev/null | tr '\n' ' ')"
fi

# ===== X9. a FOREIGN armed marker is never touched ==========================
echo "== X9: another watchdog's armed marker → exit 9, marker and baseline untouched =="
RX="$WORK/foreign"; J=$(make_root "$RX" "$BASE")
printf 'FOREIGN-WATCHDOG\n' > "$RX/monitor/.state/restart-watchdog-armed"
KEEP_MARKERS=1 run_verify "$RX" "$LOOP" "$J" "$VER_RECORD" WATCHDOG_DEADLINE_SECONDS=3 WATCHDOG_GRACE_SECONDS=1
(( RC == 9 )) && pass "exit 9 on a foreign marker" || fail "exit $RC, want 9"
[[ "$(cat "$RX/monitor/.state/restart-watchdog-armed" 2>/dev/null)" == FOREIGN-WATCHDOG ]] \
    && pass "the foreign marker is untouched" || fail "the foreign marker was modified or removed"
[[ ! -f "$RX/monitor/.state/restart-watchdog-baseline" ]] \
    && pass "a late watchdog does not overwrite the armed one's baseline" \
    || fail "a refused watchdog wrote a baseline file"

# ===== PK. post-kill --verify-only ==========================================
# The fixture is the 2026-09-11 state: the kill has happened, the live pane is
# the REPLACEMENT from the first query, and the new binary has ALREADY written
# its version record past the first run's offset.
postkill_root() {   # postkill_root <dir> <baseline-orch-pid> [<sid>] → echoes the jsonl
    local d="$1" op="$2" s="${3:-$SID}" j base
    j=$(make_root "$d" "$BASE")
    base=$(stat -c%s "$j")
    printf '%s\n' "$VER_RECORD" >> "$j"
    printf 'attempt=%s\ncandidate=%s\norch_pid=%s\nwatcher_pid=\nsid=%s\nbase_size=%s\narmed_epoch=%s\n' \
        "$PK_ATTEMPT" "$CANDIDATE" "$op" "$s" "$base" "$(date +%s)" > "$d/monitor/.state/restart-watchdog-baseline"
    printf '%s' "$j"
}
echo "== PKc (control): a PLAIN re-run after the kill false-negatives =="
RKc="$WORK/postkill-plain"; J=$(postkill_root "$RKc" "$(dead_pid)")
run_verify "$RKc" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=2 WATCHDOG_GRACE_SECONDS=1
(( RC != 0 )) && grep -q "orchestrator was never killed" "$(logfile "$RKc")" \
    && pass "control: the plain re-run reports 'never killed' about a healthy respawn (the fixture reproduces the defect)" \
    || fail "control did not reproduce the false negative (exit $RC) — PK below would prove nothing"

echo "== PK: --verify-only against the FIRST run's baseline → SUCCESS =="
RK="$WORK/postkill"; J=$(postkill_root "$RK" "$(dead_pid)")
LOOP_ARGS=(--verify-only --attempt "$PK_ATTEMPT")
run_verify "$RK" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=5 WATCHDOG_GRACE_SECONDS=2
LOOP_ARGS=()
(( RC == 0 )) && pass "verify-only exit 0 on the same post-kill fixture" || fail "verify-only exit $RC, want 0"
grep -q "SUCCESS: sid=$SID resumed on $CANDIDATE.*(verify-only)" "$(logfile "$RK")" \
    && pass "logs SUCCESS (verify-only)" || fail "no verify-only SUCCESS line"
! grep -q "armed: candidate=" "$(logfile "$RK")" && [[ ! -f "$RK/monitor/.state/restart-watchdog-armed" ]] \
    && pass "verify-only arms nothing" || fail "verify-only armed"
! failed_marker "$RK" && pass "no failure marker" || fail "failure marker written"

echo "== V4: --verify-only while the baseline orchestrator is ALIVE → refused (10) =="
RA="$WORK/alive"; J=$(postkill_root "$RA" "$$")
LOOP_ARGS=(--verify-only --attempt "$PK_ATTEMPT")
run_verify "$RA" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=2 WATCHDOG_GRACE_SECONDS=1
LOOP_ARGS=()
(( RC == 10 )) && pass "exit 10 — nothing was killed, nothing to verify" || fail "exit $RC, want 10"
! failed_marker "$RA" && pass "a refusal is not a verify failure (no failure marker)" || fail "refusal wrote a failure marker"

echo "== V5: --verify-only with no baseline and no --base-size → exit 2 =="
RB="$WORK/nobaseline"; J=$(postkill_root "$RB" "$(dead_pid)")
base_b=$(sed -n 's/^base_size=//p' "$RB/monitor/.state/restart-watchdog-baseline")
rm -f "$RB/monitor/.state/restart-watchdog-baseline"
LOOP_ARGS=(--verify-only --attempt "$PK_ATTEMPT")
run_verify "$RB" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=2 WATCHDOG_GRACE_SECONDS=1
(( RC == 2 )) && pass "exit 2 without an offset to verify against" || fail "exit $RC, want 2"
echo "== V5b: …the same, with --base-size from the first run's log → SUCCESS =="
LOOP_ARGS=(--verify-only --base-size "$base_b")
run_verify "$RB" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=5 WATCHDOG_GRACE_SECONDS=2
LOOP_ARGS=()
(( RC == 0 )) && pass "--base-size supplies the offset (exit 0)" || fail "exit $RC, want 0"

echo "== V7: --verify-only keeps step 4's verdicts — no record past the offset → FAIL =="
RV="$WORK/verify-never"; J=$(make_root "$RV" "$BASE")
printf "attempt=${PK_ATTEMPT}\n"'candidate=%s\norch_pid=%s\nwatcher_pid=\nsid=%s\nbase_size=%s\narmed_epoch=%s\n' \
"$CANDIDATE" "$(dead_pid)" "$SID" "$(stat -c%s "$J")" "$(date +%s)" > "$RV/monitor/.state/restart-watchdog-baseline"
LOOP_ARGS=(--verify-only --attempt "$PK_ATTEMPT")
run_verify "$RV" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=1 WATCHDOG_GRACE_SECONDS=1
LOOP_ARGS=()
(( RC == 1 )) && grep -qi "never resumed" "$(logfile "$RV")" \
    && pass "exit 1 naming never-resumed" || fail "exit $RC / verdict wrong"

echo "== V8: --verify-only when the pin moved since the baseline → FAIL (cold spawn) =="
RP8="$WORK/verify-pin"; J=$(postkill_root "$RP8" "$(dead_pid)" "11111111-2222-3333-4444-555555555555")
LOOP_ARGS=(--verify-only --attempt "$PK_ATTEMPT")
run_verify "$RP8" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=2 WATCHDOG_GRACE_SECONDS=1
LOOP_ARGS=()
(( RC == 1 )) && grep -q "session pin changed since the baseline" "$(logfile "$RP8")" \
    && pass "exit 1 naming the moved pin" || fail "exit $RC / verdict wrong"

echo "== V9: an unknown flag is a usage error, never silently a plain run =="
RU="$WORK/badflag"; J=$(make_root "$RU" "$BASE")
LOOP_ARGS=(--verfy-only)
run_verify "$RU" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=2 WATCHDOG_GRACE_SECONDS=1
LOOP_ARGS=()
(( RC == 2 )) && pass "exit 2 on --verfy-only" || fail "exit $RC, want 2"

# ===== ST. a STALE baseline is refused, never verified (w234sk F1) ==========
# Measured by the skeptic before this guard: a baseline left by an EARLIER bump
# returned SUCCESS about a restart that did not happen. A stale baseline's
# orchestrator pid is always dead, so exit 10 can never catch it.
echo "== ST1: --verify-only on a baseline armed 2 h ago → refused (13), no SUCCESS =="
RST="$WORK/stale-age"; J=$(make_root "$RST" "$BASE")
printf '%s\n' "$VER_RECORD" >> "$J"
printf "attempt=${PK_ATTEMPT}\n"'candidate=%s\norch_pid=%s\nwatcher_pid=\nsid=%s\nbase_size=%s\narmed_epoch=%s\n' \
"$CANDIDATE" "$(dead_pid)" "$SID" 0 "$(( $(date +%s) - 7200 ))" > "$RST/monitor/.state/restart-watchdog-baseline"
LOOP_ARGS=(--verify-only --attempt "$PK_ATTEMPT")
run_verify "$RST" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=2 WATCHDOG_GRACE_SECONDS=1
LOOP_ARGS=()
(( RC == 13 )) && pass "exit 13 on a baseline armed past WATCHDOG_VERIFY_MAX_AGE_SECONDS" || fail "exit $RC, want 13"
! grep -q "SUCCESS: sid=" "$(logfile "$RST")" && pass "…and no SUCCESS about a restart that did not happen" \
    || fail "a stale baseline produced SUCCESS"
! failed_marker "$RST" && pass "…and a refusal writes no failure marker" || fail "refusal wrote a failure marker"

echo "== ST2: a FRESH baseline naming a candidate the installed binary does not report → refused (13) =="
RSC="$WORK/stale-cand"; J=$(make_root "$RSC" "$BASE")
printf '{"type":"assistant","version":"2.1.211"}\n' >> "$J"
printf "attempt=${PK_ATTEMPT}\n"'candidate=%s\norch_pid=%s\nwatcher_pid=\nsid=%s\nbase_size=%s\narmed_epoch=%s\n' \
"2.1.211" "$(dead_pid)" "$SID" 0 "$(date +%s)" > "$RSC/monitor/.state/restart-watchdog-baseline"
LOOP_ARGS=(--verify-only --attempt "$PK_ATTEMPT")
run_verify "$RSC" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=2 WATCHDOG_GRACE_SECONDS=1
LOOP_ARGS=()
(( RC == 13 )) && pass "exit 13 when the baseline names another bump's candidate" || fail "exit $RC, want 13"
! grep -q "SUCCESS: sid=" "$(logfile "$RSC")" && pass "…and no SUCCESS on another bump's version record" \
    || fail "a mismatched baseline produced SUCCESS"

echo "== ST3: a baseline with NO armed_epoch → refused (13) =="
RSE="$WORK/stale-noepoch"; J=$(postkill_root "$RSE" "$(dead_pid)")
sed -i '/^armed_epoch=/d' "$RSE/monitor/.state/restart-watchdog-baseline"
LOOP_ARGS=(--verify-only --attempt "$PK_ATTEMPT")
run_verify "$RSE" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=2 WATCHDOG_GRACE_SECONDS=1
LOOP_ARGS=()
(( RC == 13 )) && pass "exit 13 on a baseline with no armed_epoch" || fail "exit $RC, want 13"

echo "== ST4: a stale baseline PLUS an explicit --base-size → the file is ignored, the offset verifies =="
RSB="$WORK/stale-override"; J=$(postkill_root "$RSB" "$(dead_pid)")
base_sb=$(sed -n 's/^base_size=//p' "$RSB/monitor/.state/restart-watchdog-baseline")
sed -i "s/^armed_epoch=.*/armed_epoch=$(( $(date +%s) - 7200 ))/" "$RSB/monitor/.state/restart-watchdog-baseline"
LOOP_ARGS=(--verify-only --base-size "$base_sb")
run_verify "$RSB" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=5 WATCHDOG_GRACE_SECONDS=2
LOOP_ARGS=()
(( RC == 0 )) && grep -q "IGNORING" "$(logfile "$RSB")" \
    && pass "--base-size overrides a stale baseline, and says it ignored the file" \
    || fail "exit $RC, or no IGNORING note"

# ===== SIG. a signalled watchdog releases the marker it wrote (w234sk F6) ===
echo "== SIG: SIGTERM while waiting for the kill → rc 143, armed marker released =="
RSG="$WORK/sigterm"; J=$(make_root "$RSG" "$BASE")
make_tmux_stub "$RSG/stubbin"; : > "$RSG/tmux-cnt"
# The baseline orchestrator pid is THIS suite's own (alive), so the loop parks
# in its kill-wait; the signal goes to the loop, a child this suite launched.
env -i PATH="$RSG/stubbin:/usr/bin:/bin" HOME="$RSG" \
    TMUX_STUB_CNT="$RSG/tmux-cnt" TMUX_STUB_TARGET="$TARGET" \
    TMUX_STUB_ORCH_PID="$$" TMUX_STUB_NEW_PID="$$" \
    TMUX_STUB_JSONL="$J" STUB_APPEND="" \
    NEXUS_ROOT="$RSG" NEXUS_STATE_DIR="$RSG/monitor/.state" \
    CC_AUTO_PROJECTS_DIR="$RSG/projects" WATCHDOG_DEADLINE_SECONDS=60 \
    bash "$LOOP" >/dev/null 2>&1 &
sig_pid=$!
armed_seen=0
for _i in $(seq 1 150); do
    [[ -f "$RSG/monitor/.state/restart-watchdog-armed" ]] && { armed_seen=1; break; }
    sleep 0.1
done
(( armed_seen )) && pass "control: the loop armed before the signal (the release below is not vacuous)" \
    || fail "the loop never armed within 15 s, so the SIG case proves nothing"
kill -TERM "$sig_pid" 2>/dev/null
wait "$sig_pid"; sig_rc=$?
(( sig_rc == 143 )) && pass "exit 143 on SIGTERM" || fail "exit $sig_rc, want 143"
[[ ! -f "$RSG/monitor/.state/restart-watchdog-armed" ]] \
    && pass "SIGTERM released the armed marker this run wrote" \
    || fail "SIGTERM left the armed marker behind (the reconcile single-flight stays shut)"
grep -q "SIGNAL TERM" "$(logfile "$RSG")" && pass "…and logs the signal" || fail "no SIGNAL line in the log"

# ===== SIGF. release is by IDENTITY: a foreign claimant's marker survives ===
# The marker holds the reconcile single-flight. A release keyed on a FLAG
# ("I wrote it") deletes whatever marker is at the path, including a live
# claimant's, silently reopening the gate to a concurrent restart. Here our
# run arms, then another claimant's marker takes the path, then TERM arrives.
# The foreign marker must be left intact.
echo "== SIGF: TERM with a FOREIGN claimant's marker at the path → the foreign marker survives =="
RSF="$WORK/sig-foreign"; J=$(make_root "$RSF" "$BASE")
make_tmux_stub "$RSF/stubbin"; : > "$RSF/tmux-cnt"
env -i PATH="$RSF/stubbin:/usr/bin:/bin" HOME="$RSF" \
    TMUX_STUB_CNT="$RSF/tmux-cnt" TMUX_STUB_TARGET="$TARGET" \
    TMUX_STUB_ORCH_PID="$$" TMUX_STUB_NEW_PID="$$" \
    TMUX_STUB_JSONL="$J" STUB_APPEND="" \
    NEXUS_ROOT="$RSF" NEXUS_STATE_DIR="$RSF/monitor/.state" \
    CC_AUTO_PROJECTS_DIR="$RSF/projects" WATCHDOG_DEADLINE_SECONDS=60 \
    WATCHDOG_ATTEMPT=ours-sigf-1 \
    bash "$LOOP" >/dev/null 2>&1 &
sf_pid=$!
sf_armed=0
for _i in $(seq 1 150); do
    [[ -f "$RSF/monitor/.state/restart-watchdog-baseline" ]] && { sf_armed=1; break; }
    sleep 0.1
done
(( sf_armed )) && pass "control: our run armed fully (baseline written) before the swap" \
    || fail "our run never armed within 15 s, so SIGF proves nothing"
printf 'attempt=foreign-claimant-9\narmed_at=now\n' > "$RSF/monitor/.state/restart-watchdog-armed"
kill -TERM "$sf_pid" 2>/dev/null
wait "$sf_pid"; sf_rc=$?
(( sf_rc == 143 )) && pass "exit 143 on SIGTERM" || fail "exit $sf_rc, want 143"
grep -qx "attempt=foreign-claimant-9" "$RSF/monitor/.state/restart-watchdog-armed" 2>/dev/null \
    && pass "the foreign claimant's marker is intact (the single-flight is still held)" \
    || fail "the signal handler deleted another claimant's marker"
! grep -q "released the armed marker" "$(logfile "$RSF")" \
    && pass "…and no release is claimed" || fail "the log claims a release of a marker that was not ours"

# ===== ATT. identity binds the verification (w234sk F1) =====================
# Age and candidate cannot tell two armings of the SAME bump apart: on
# 2026-07-21 one candidate was re-attempted about every 35 minutes, 16 times.
# So attempt B, verifying against attempt A's baseline (fresh, right candidate,
# a matching version record past its offset), must be REFUSED.
echo "== ATT1: --verify-only --attempt B against attempt A's fresh, same-candidate baseline → refused (13) =="
RAT="$WORK/attempt-other"; J=$(postkill_root "$RAT" "$(dead_pid)")
LOOP_ARGS=(--verify-only --attempt "1789000999-5151-888")
run_verify "$RAT" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=2 WATCHDOG_GRACE_SECONDS=1
LOOP_ARGS=()
(( RC == 13 )) && pass "exit 13 when the baseline belongs to another attempt" || fail "exit $RC, want 13"
! grep -q "SUCCESS: sid=" "$(logfile "$RAT")" && pass "…and no SUCCESS certified from another attempt's baseline" \
    || fail "another attempt's baseline produced SUCCESS"
grep -q "belongs to attempt $PK_ATTEMPT" "$(logfile "$RAT")" && pass "…and the refusal names both attempts" \
    || fail "refusal does not name the recorded attempt"

echo "== ATT2: --verify-only with a baseline present but NO --attempt → usage refusal (2) =="
RAN="$WORK/attempt-missing"; J=$(postkill_root "$RAN" "$(dead_pid)")
LOOP_ARGS=(--verify-only)
run_verify "$RAN" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=2 WATCHDOG_GRACE_SECONDS=1
LOOP_ARGS=()
(( RC == 2 )) && pass "exit 2 when nothing binds the baseline to this run" || fail "exit $RC, want 2"
! grep -q "SUCCESS: sid=" "$(logfile "$RAN")" && pass "…and no SUCCESS" || fail "an unbound baseline produced SUCCESS"

# ===== WA. the nonce is handed in, not found in the log (w234sk F1) =========
# cc-auto-update-apply.sh mints the attempt and passes it as WATCHDOG_ATTEMPT,
# writing the same literal into the prompt's --verify-only command. The loop
# must use it verbatim, so the verifier holds it by construction.
echo "== WA: a handed-in WATCHDOG_ATTEMPT is the attempt the armed run records =="
RWA="$WORK/attempt-env"; J=$(make_root "$RWA" "$BASE")
run_verify "$RWA" "$LOOP" "$J" "" WATCHDOG_ATTEMPT=handed-in-nonce.7 WATCHDOG_DEADLINE_SECONDS=1 WATCHDOG_GRACE_SECONDS=1
grep -qx "attempt=handed-in-nonce.7" "$RWA/monitor/.state/restart-watchdog-baseline" \
    && pass "the baseline records the handed-in attempt verbatim" \
    || fail "baseline attempt is not the handed-in nonce: $(grep '^attempt=' "$RWA/monitor/.state/restart-watchdog-baseline" 2>/dev/null)"
grep -q "armed: .* attempt=handed-in-nonce.7" "$(logfile "$RWA")" \
    && pass "…and the armed line prints it" || fail "armed line does not print the handed-in attempt"

# ===== BS. --base-size is not F1 by another door =============================
# With no usable baseline the candidate is the INSTALLED binary's version, and
# SUCCESS still needs a record stamped with it past the offset.
echo "== BS1: --base-size, no baseline, and NO restart onto the candidate (old-version records only) → FAIL =="
RB1="$WORK/basesize-norestart"; J=$(make_root "$RB1" "$BASE")
b1=$(stat -c%s "$J")
printf '%s\n' "$NONVER_RECORD" >> "$J"
LOOP_ARGS=(--verify-only --base-size "$b1")
run_verify "$RB1" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=1 WATCHDOG_GRACE_SECONDS=1
LOOP_ARGS=()
(( RC == 1 )) && pass "exit 1: no record of the installed candidate past the offset" || fail "exit $RC, want 1"
! grep -q "SUCCESS: sid=" "$(logfile "$RB1")" && pass "…and no SUCCESS without a restart onto the candidate" \
    || fail "--base-size certified a restart that did not happen"

echo "== BS2: --base-size with an IGNORED baseline naming another candidate that HAS a record → still FAIL =="
RB2="$WORK/basesize-othercand"; J=$(make_root "$RB2" "$BASE")
b2=$(stat -c%s "$J")
printf '{"type":"assistant","version":"2.1.211"}\n' >> "$J"
printf 'attempt=%s\ncandidate=%s\norch_pid=%s\nwatcher_pid=\nsid=%s\nbase_size=%s\narmed_epoch=%s\n' \
    "$PK_ATTEMPT" "2.1.211" "$(dead_pid)" "$SID" "$b2" "$(date +%s)" > "$RB2/monitor/.state/restart-watchdog-baseline"
LOOP_ARGS=(--verify-only --attempt "$PK_ATTEMPT" --base-size "$b2")
run_verify "$RB2" "$LOOP" "$J" "" TMUX_STUB_POSTKILL=1 WATCHDOG_DEADLINE_SECONDS=1 WATCHDOG_GRACE_SECONDS=1
LOOP_ARGS=()
(( RC == 1 )) && pass "exit 1: the candidate is the installed binary's (2.1.212), not the ignored file's (2.1.211)" \
    || fail "exit $RC, want 1"
grep -q "IGNORING" "$(logfile "$RB2")" && pass "…and the file was ignored, not trusted" || fail "no IGNORING note"
! grep -q "SUCCESS: sid=" "$(logfile "$RB2")" && pass "…and no SUCCESS on the ignored file's candidate" \
    || fail "an ignored baseline's candidate produced SUCCESS"

# ---- summary --------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
