#!/usr/bin/env bash
# Unit tests for `ng watcher-status` (cmd_watcher_status in monitor/ng).
#
# Run: bash monitor/watcher/test-ng-watcher-status.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: cmd_watcher_status reads STATE_DIR/{watcher-heartbeat,
# watcher.lock, watcher-target,diffs/} and sources monitor/watcher/_lib.sh
# for the liveness probe. We build a fake STATE_DIR for each case,
# wire up a fake tmux that returns a controllable window list, and
# assert on the printed lines AND the exit code (the four-bucket
# return value from _watcher_alive: 0=fresh / 1=stale / 2=very-stale
# or dead / 3=no heartbeat).
#
# Coverage map (from your-org/nexus-code#60):
#   - heartbeat absent       → exit 3, "heartbeat: missing"
#   - heartbeat live + fresh → exit 0, "(alive)", "watcher: present"
#   - heartbeat dead pid     → exit 2, "(DEAD)"
#   - heartbeat stale age    → exit 1
#   - heartbeat very stale   → exit 2
#   - no tmux window         → exit 0 (headless is the norm); a
#     leftover 'watcher' window is surfaced as legacy
#   - lock parsing: present + valid / absent / malformed
#   - heartbeat malformed (no pid= line) → "pid: unknown"
#   - archived_diffs count from $STATE_DIR/diffs/*.md

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-ng-watcher-status-XXXXXX)

# A long-lived process whose argv identifies it as a watcher
# (`bash …/monitor/watcher/main.sh`). The `live` heartbeat fixtures
# point at this pid because _watcher_alive now validates the pid's
# IDENTITY (it must be a watcher), not merely that `kill -0` succeeds
# — a recycled non-watcher pid must read as dead (incident
# 2026-06-07). /proc keeps the argv even after we delete the script
# file, so cleanup of $WORK at EXIT is safe.
mkdir -p "$WORK/faux/monitor/watcher"
printf '#!/usr/bin/env bash\nsleep 300\n' > "$WORK/faux/monitor/watcher/main.sh"
chmod +x "$WORK/faux/monitor/watcher/main.sh"
bash "$WORK/faux/monitor/watcher/main.sh" &
LIVE_WATCHER_PID=$!
sleep 0.2   # let the kernel commit the cmdline
# th_kill_own_child: refuse the kill if the sleep-300 faux watcher
# already exited and its PID was recycled (PID-space wrap hazard, see
# _test_helpers.sh).
trap 'th_kill_own_child "$LIVE_WATCHER_PID"; rm -rf "$WORK"' EXIT

setup_fake_nexus "$WORK/nexus" --allow-default
NG="$FAKE_NEXUS/monitor/ng"

# cmd_watcher_status sources $_script_dir/watcher/_lib.sh. setup_fake_nexus
# only copies monitor/ng — we need _lib.sh next to it, mirroring the real
# tree. The function definitions in _lib.sh are pure (no top-level config
# lookups, no side effects), so the real file plugs in unmodified.
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$FAKE_NEXUS/monitor/watcher"
cp "$_test_dir/_lib.sh" "$FAKE_NEXUS/monitor/watcher/_lib.sh"

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

# tmux stub: reads $MOCK_WINDOWS env var (space-separated list of
# window names) for `list-windows -F '#{window_name}'`. Default
# includes "watcher" so the happy-path tests don't need to opt in.
# Any other tmux subcommand is a no-op (exit 0). _watcher_alive also
# probes `command -v tmux`; a real `tmux` on PATH would resolve to
# whatever the operator has installed, so we shadow it here.
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "list-windows" ]]; then
    for w in ${MOCK_WINDOWS:-watcher}; do
        printf '%s\n' "$w"
    done
    exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

STATE_DIR_BASE="$WORK/state"
NEUTRAL_CWD="$WORK/neutral"
mkdir -p "$NEUTRAL_CWD"

# Per-case fixture builder. The first arg is the case label (also used
# for the per-case state dir under $STATE_DIR_BASE so cases don't
# clobber each other). Remaining args control:
#   --heartbeat live|dead|missing|malformed  default missing
#   --age <seconds>                          default 0 (now)
#   --lock present|absent|malformed          default absent
#   --diffs <n>                              default 0
setup_state() {
    local label="$1"; shift
    local hb_mode="missing" age=0 lock_mode="absent" diffs=0
    while (( $# > 0 )); do
        case "$1" in
            --heartbeat) hb_mode="$2"; shift 2 ;;
            --age)       age="$2"; shift 2 ;;
            --lock)      lock_mode="$2"; shift 2 ;;
            --diffs)     diffs="$2"; shift 2 ;;
            *) echo "setup_state: unknown $1" >&2; return 2 ;;
        esac
    done
    local sd="$STATE_DIR_BASE/$label"
    rm -rf "$sd"
    mkdir -p "$sd/diffs"

    local now hb pid_for_hb
    now=$(date +%s)
    hb="$sd/watcher-heartbeat"
    case "$hb_mode" in
        missing) ;;
        live)
            # The shared faux-watcher pid: alive AND argv-identified as
            # a watcher, so _watcher_pid_is_live_watcher accepts it.
            # (A bare `$$` no longer works — the test shell isn't a
            # watcher.)
            pid_for_hb=$LIVE_WATCHER_PID
            printf 'pid=%d\nts=%s\ntarget=worker-1\n' \
                "$pid_for_hb" "$(date -Is -d "@$now")" > "$hb"
            ;;
        dead)
            # Spawn a tiny background subshell, wait for it; its pid
            # is then known-dead. _watcher_alive will hit ESRCH.
            ( true ) &
            pid_for_hb=$!
            wait "$pid_for_hb" 2>/dev/null || true
            printf 'pid=%d\nts=%s\ntarget=worker-1\n' \
                "$pid_for_hb" "$(date -Is -d "@$now")" > "$hb"
            ;;
        malformed)
            # Garbage that lacks pid=, ts=, target= lines. The field
            # extractor returns empty for each key; the age check then
            # uses the file mtime.
            printf 'this is not a heartbeat\n' > "$hb"
            ;;
        *) echo "setup_state: unknown heartbeat mode $hb_mode" >&2; return 2 ;;
    esac

    if [[ -f "$hb" && "$age" -gt 0 ]]; then
        # touch -t supports historical mtimes; convert epoch to the
        # CCYYMMDDhhmm.SS form. -d works on coreutils' touch but not
        # on the minimal touch on some BSDs — bash inside the sandbox
        # is GNU.
        touch -d "@$(( now - age ))" "$hb"
    fi

    local lock="$sd/watcher.lock"
    case "$lock_mode" in
        absent) ;;
        present)
            cat > "$lock" <<EOF
pid: 4242
started_at: 2026-05-12T14:30:00-07:00
target_window: worker-1
tmux_window: watcher
interval_seconds: 60
EOF
            ;;
        malformed)
            printf 'this is not a watcher.lock\n' > "$lock"
            ;;
        *) echo "setup_state: unknown lock mode $lock_mode" >&2; return 2 ;;
    esac

    # Populate $diffs fake archived diff files.
    local i
    for (( i = 0; i < diffs; i++ )); do
        : > "$sd/diffs/diff-$i.md"
    done

    printf '%s' "$sd"
}

run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3" _state_dir="$4"; shift 4
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    ( cd "$NEUTRAL_CWD" && run_hermetic \
        NEXUS_STATE_DIR="$_state_dir" \
        PATH="$STUB_DIR:$PATH" \
        MOCK_WINDOWS="${MOCK_WINDOWS:-watcher}" \
        -- "$NG" "$@" ) >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

# ---- Test 1: usage / --help short-circuit --------------------------------

echo '=== ng watcher-status --help → exit 0, prints usage ==='
sd=$(setup_state help-case)
run_ng out err rc "$sd" watcher-status --help
assert_eq        "exit 0 on --help"               "$rc" "0"
assert_contains  "usage block printed"            "$out" "usage: ng watcher-status"

# ---- Test 2: no heartbeat → exit 3, missing line --------------------------

echo '=== no heartbeat file → exit 3, "heartbeat: missing" ==='
sd=$(setup_state no-hb)
run_ng out err rc "$sd" watcher-status
assert_eq        "exit 3 when heartbeat absent"   "$rc" "3"
assert_contains  "heartbeat: missing"             "$out" "heartbeat: missing"
# No `pid:` or `target:` lines when heartbeat is absent — the function
# skips those branches outright.
assert_not_contains "no pid line when no heartbeat" "$out" "pid:"
# Lock is absent too; assertion makes the format explicit.
assert_contains  "lock: absent"                   "$out" "lock: absent"

# ---- Test 3: heartbeat live + fresh + tmux window present → exit 0 ------

echo '=== live heartbeat + fresh age + watcher window → exit 0 ==='
sd=$(setup_state live-fresh --heartbeat live --lock present --diffs 3)
run_ng out err rc "$sd" watcher-status
assert_eq        "exit 0 on fresh+alive"          "$rc" "0"
assert_contains  "heartbeat age=0s"               "$out" "heartbeat:"
assert_contains  "pid <faux-watcher> (alive)"     "$out" "pid: $LIVE_WATCHER_PID (alive)"
assert_contains  "target rendered"                "$out" "target: worker-1"
assert_contains  "lock present rendered"          "$out" "lock: pid=4242 started=2026-05-12T14:30:00-07:00"
assert_contains  "legacy window surfaced"          "$out" "legacy tmux window 'watcher' present"
assert_contains  "archived_diffs counted"         "$out" "archived_diffs: 3"

# ---- Test 4: heartbeat with dead pid → exit 2, DEAD --------------------

echo '=== heartbeat with dead pid → exit 2, "(DEAD)" ==='
sd=$(setup_state dead-pid --heartbeat dead)
run_ng out err rc "$sd" watcher-status
assert_eq        "exit 2 on dead pid"             "$rc" "2"
assert_contains  "pid renders (DEAD)"             "$out" "(DEAD)"
assert_not_contains "no (alive) when pid is dead" "$out" "(alive)"

# ---- Test 5: heartbeat fresh, NO watcher window → exit 0 (headless) ----
#
# Pre-migration this was the "window missing => unhealthy (rc 2)"
# case. The watcher is headless now: window absence is the NORM and
# must not degrade the liveness bucket.

echo '=== heartbeat fresh + no watcher window → exit 0, hosting: headless ==='
sd=$(setup_state no-window --heartbeat live)
MOCK_WINDOWS="some-other-window" run_ng out err rc "$sd" watcher-status
assert_eq        "exit 0: headless watcher needs no window" "$rc" "0"
assert_contains  "hosting reported headless"      "$out" "hosting: headless"

# ---- Test 6: heartbeat stale (≤ 5*interval) → exit 1 -------------------
#
# config default monitor.interval_seconds = 60.
# fresh cutoff:    2*60 + 15 = 135s.
# very-stale cut:  5*60      = 300s.
# Pick 200s → above fresh, below very-stale → bucket 1.

echo '=== heartbeat aged 200s → exit 1 (stale) ==='
sd=$(setup_state stale --heartbeat live --age 200)
run_ng out err rc "$sd" watcher-status
assert_eq        "exit 1 on stale heartbeat"      "$rc" "1"
# Heartbeat line carries an explicit age field — sanity-check the
# range. (Cannot pin exact value: the test takes a few ms to run.)
hb_line=$(awk '/^heartbeat:/' <<<"$out")
if [[ "$hb_line" =~ age=([0-9]+)s ]]; then
    age="${BASH_REMATCH[1]}"
    if (( age >= 200 && age <= 220 )); then
        printf '  PASS: heartbeat age in expected range (200-220s); got %ss\n' "$age"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: heartbeat age out of range: %ss\n' "$age" >&2
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  FAIL: heartbeat line lacks age=Ns: %q\n' "$hb_line" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 7: heartbeat very stale (> 5*interval) → exit 2 --------------

echo '=== heartbeat aged 600s → exit 2 (very stale) ==='
sd=$(setup_state very-stale --heartbeat live --age 600)
run_ng out err rc "$sd" watcher-status
assert_eq        "exit 2 on very-stale heartbeat" "$rc" "2"

# ---- Test 8: lock absent (no .lock file) → "lock: absent" --------------

echo '=== lock file absent → "lock: absent" line ==='
sd=$(setup_state lock-absent --heartbeat live)
run_ng out err rc "$sd" watcher-status
assert_contains  "lock: absent"                   "$out" "lock: absent"

# ---- Test 9: malformed lock → printed defaults ("?") -------------------

echo '=== lock malformed → "lock: pid=? started=?" ==='
sd=$(setup_state lock-bad --heartbeat live --lock malformed)
run_ng out err rc "$sd" watcher-status
# The current parser falls back to "?" placeholders when neither
# `pid:` nor `started_at:` is recognized. Pin this behavior so a future
# refactor doesn't silently change the format the orchestrator parses.
assert_contains  "lock: pid=? started=?"          "$out" "lock: pid=? started=?"

# ---- Test 10: malformed heartbeat (no pid= line) → "pid: unknown" -----

echo '=== heartbeat malformed (no pid= line) → "pid: unknown" ==='
sd=$(setup_state hb-bad --heartbeat malformed)
run_ng out err rc "$sd" watcher-status
assert_contains  "pid: unknown"                   "$out" "pid: unknown"

# ---- Test 11: archived_diffs counts only *.md under diffs/ -------------

echo '=== archived_diffs counts $STATE_DIR/diffs/*.md ==='
sd=$(setup_state diff-count --heartbeat live --diffs 7)
# Add a non-.md file to confirm only *.md is counted.
: > "$sd/diffs/ignore.txt"
run_ng out err rc "$sd" watcher-status
assert_contains  "archived_diffs: 7"              "$out" "archived_diffs: 7"

# ---- Test 12: diffs dir absent → archived_diffs: 0 ---------------------

echo '=== diffs dir absent → archived_diffs: 0 ==='
sd=$(setup_state no-diffs --heartbeat live)
rm -rf "$sd/diffs"
run_ng out err rc "$sd" watcher-status
assert_contains  "archived_diffs: 0"              "$out" "archived_diffs: 0"

# ---- Test 13: --scheduler flag, no telemetry → "scheduler: telemetry absent" --
echo '=== --scheduler with no JSONL → "scheduler: telemetry absent" ==='
sd=$(setup_state sched-empty --heartbeat live)
run_ng out err rc "$sd" watcher-status --scheduler
assert_eq        "exit 0 on --scheduler with no log" "$rc" "0"
assert_contains  "scheduler: telemetry absent"       "$out" "scheduler: telemetry absent"
# Without --scheduler the section must NOT appear (back-compat).
run_ng out2 err2 rc2 "$sd" watcher-status
assert_not_contains "no scheduler section without flag" "$out2" "scheduler:"

# ---- Test 14: --scheduler with telemetry → per-task lines (issue #172) -----
echo '=== --scheduler with JSONL → per-task last-fire summary ==='
sd=$(setup_state sched-live --heartbeat live)
# Seed a watcher-scheduler.jsonl that simulates a tick's worth of
# fires. Two ticks: the second tick is the one that "last" wins for
# each task. Includes both sync and async-done phases to verify the
# extractor sees both shapes.
cat > "$sd/watcher-scheduler.jsonl" <<'JSONL'
{"ts":"2026-05-22T07:00:00-07:00","task":"heartbeat","rc":0,"elapsed_ms":12,"next_fire":1779462005,"phase":"sync"}
{"ts":"2026-05-22T07:00:00-07:00","task":"target_window","rc":0,"elapsed_ms":50,"next_fire":1779462002,"phase":"sync"}
{"ts":"2026-05-22T07:00:00-07:00","task":"snapshot_local","rc":0,"elapsed_ms":0,"next_fire":1779462030,"phase":"async-start"}
{"ts":"2026-05-22T07:00:01-07:00","task":"snapshot_local","rc":0,"elapsed_ms":1000,"next_fire":1779462030,"phase":"async-done"}
{"ts":"2026-05-22T07:00:01-07:00","task":"compose_emit","rc":0,"elapsed_ms":0,"next_fire":1779462060,"phase":"async-start"}
{"ts":"2026-05-22T07:00:02-07:00","task":"compose_emit","rc":0,"elapsed_ms":2000,"next_fire":1779462060,"phase":"async-done"}
JSONL
run_ng out err rc "$sd" watcher-status --scheduler
assert_eq        "exit 0 on --scheduler with telemetry"  "$rc" "0"
assert_contains  "scheduler header (telemetry path)"     "$out" "scheduler: telemetry"
assert_contains  "compose_emit listed"                   "$out" "compose_emit"
assert_contains  "compose_emit shows last-fire phase"    "$out" "phase=async-done"
assert_contains  "snapshot_local listed"                 "$out" "snapshot_local"
assert_contains  "target_window listed"                  "$out" "target_window"
assert_contains  "heartbeat listed"                      "$out" "heartbeat"
# Issue #172: main_cycle must NOT be in the task table.
assert_not_contains "main_cycle absent"                  "$out" "main_cycle"

# ---- Test 15: --scheduler rejects unknown flag ---------------------------
echo '=== watcher-status unknown flag → exit non-zero ==='
sd=$(setup_state sched-bad --heartbeat live)
run_ng out err rc "$sd" watcher-status --no-such-flag
if [[ "$rc" != "0" ]]; then
    printf '  PASS: exit non-zero on unknown flag (rc=%s)\n' "$rc"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: should reject --no-such-flag (rc=%s)\n' "$rc" >&2
    printf '         stderr: %s\n' "$err" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- summary ------------------------------------------------------------

th_summary_and_exit
