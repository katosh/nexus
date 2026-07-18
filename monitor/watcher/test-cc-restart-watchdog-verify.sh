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
    if (( n == 1 )); then
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
run_verify() {
    local root="$1" script="$2" jsonl="$3" append="$4"; shift 4  # rest: env
    local bindir="$root/stubbin" state="$root/monitor/.state"
    make_tmux_stub "$bindir"
    rm -f "$state/restart-watchdog-armed" "$state/restart-watchdog-failed"
    : > "$root/tmux-cnt"
    env -i PATH="$bindir:/usr/bin:/bin" HOME="$root" \
        TMUX_STUB_CNT="$root/tmux-cnt" TMUX_STUB_TARGET="$TARGET" \
        TMUX_STUB_ORCH_PID="$(dead_pid)" TMUX_STUB_NEW_PID="$$" \
        TMUX_STUB_JSONL="$jsonl" STUB_APPEND="$append" \
        NEXUS_ROOT="$root" NEXUS_STATE_DIR="$state" \
        CC_AUTO_PROJECTS_DIR="$root/projects" \
        "$@" \
        bash "$script" >/dev/null 2>&1
    RC=$?
}

armed_removed() { [[ ! -f "$1/monitor/.state/restart-watchdog-armed" ]]; }
failed_marker() { [[ -f "$1/monitor/.state/restart-watchdog-failed" ]]; }
logfile()       { printf '%s' "$1/monitor/.state/restart-watchdog.log"; }

if ! /usr/bin/python3 -c 'import yaml' 2>/dev/null; then
    echo "skipped: /usr/bin/python3 lacks pyyaml (config/load.sh cannot resolve keys)"
    exit 0
fi

BASE='{"version":"2.1.202"}
'
VER_RECORD='{"type":"assistant","version":"'"$CANDIDATE"'"}'
NONVER_RECORD='{"type":"assistant","version":"2.1.202"}'

# ===== S. deterministic success ============================================
echo "== S: fresh candidate-version record past baseline → SUCCESS =="
RS="$WORK/success"; J=$(make_root "$RS" "$BASE")
run_verify "$RS" "$LOOP" "$J" "$VER_RECORD" WATCHDOG_DEADLINE_SECONDS=10 WATCHDOG_GRACE_SECONDS=5
(( RC == 0 )) && pass "exit 0 on visible candidate version" || fail "exit $RC, want 0"
armed_removed "$RS" && pass "armed marker removed on success" || fail "armed marker not removed"
! failed_marker "$RS" && pass "no failure marker on success" || fail "failure marker written on success"
grep -q "SUCCESS: sid=$SID resumed on $CANDIDATE" "$(logfile "$RS")" \
    && pass "logs SUCCESS with the candidate version" || fail "no SUCCESS log line"

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
PREFIX_LOOP="$WORK/loop-prefix.sh"
if git -C "$NEXUS_SRC" show dev:monitor/cc-restart-watchdog-loop.sh > "$PREFIX_LOOP" 2>/dev/null \
    && ! grep -q 'WATCHDOG_GRACE_SECONDS' "$PREFIX_LOOP"; then
    pass "extracted the pre-fix loop from dev (no grace window)"
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
    # dev already carries the grace window (this change merged) — the pre-fix
    # control is no longer extractable. Skip loudly rather than silently drop it.
    pass "SKIP pre-fix control: dev's loop already has the grace window (change merged)"
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

# ===== F-never. never grew → never-resumed FAIL =============================
echo "== F-never: no growth past baseline → FAIL (never resumed) =="
RN="$WORK/never"; J=$(make_root "$RN" "$BASE")
run_verify "$RN" "$LOOP" "$J" "" WATCHDOG_DEADLINE_SECONDS=1 WATCHDOG_GRACE_SECONDS=1
(( RC != 0 )) && pass "exit non-zero when file never grew" || fail "exit $RC, want non-zero"
failed_marker "$RN" && pass "failure marker written" || fail "no failure marker"
grep -qi "never resumed" "$(logfile "$RN")" \
    && pass "verdict names the never-resumed case (growth-aware)" \
    || fail "verdict did not distinguish the never-grew case"

# ---- summary --------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
