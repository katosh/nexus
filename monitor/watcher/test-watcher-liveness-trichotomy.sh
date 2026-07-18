#!/usr/bin/env bash
# Both-direction test of the liveness/progress split (nexus-code#491):
# a workload signal must never be read as a liveness signal, and DOWN
# is reserved for established facts.
#
#   Case A — BUSY, not DOWN (the 2026-07-09 false positive; FAILS on
#     pre-#491 dev): a watcher whose heartbeat is stale past every
#     constant threshold (age 444s — the exact live observation) but
#     whose PROCESS is alive and ADVANCING (log fresh) is
#       * verdict BUSY (rc 1), never DOWN,
#       * NOT fired on by watcher-supervise-tick (exit 0),
#       * REFUSED by revive-watcher.sh (exit 5, loud, faux watcher
#         still alive afterwards — nothing was killed).
#   Case B — genuinely dead watcher is still DOWN and still revived
#     (the false positive must not be fixed by a false negative):
#     verdict DOWN, tick exits non-zero, revive-watcher proceeds and
#     invokes the restart command.
#   Case C — wedged-but-alive is detected DISTINCTLY from both: fresh
#     heartbeat (ticker semantics) + live pid + NO progress past the
#     cutoff => _watcher_alive bucket 4, verdict WEDGED, tick fires
#     with a WEDGED (not DOWN) report, revive-watcher proceeds.
#   Case D — the liveness heartbeat stays fresh across a deliberately
#     slow loop iteration: the ticker beats on a fixed cadence while
#     the "loop" (a plain sleep) does no work at all, and stops within
#     one tick of the watched pid dying.
#   Case E — pre-#491 compat: with no progress/cycle/log signal at all
#     the historical heartbeat-age buckets are unchanged.
#
# Everything runs against an isolated mktemp tree; no live watcher or
# live state is touched. Faux watchers are killed by recorded pid.
#
# Run: env -u NEXUS_ROOT -u NEXUS_LOCALS bash monitor/watcher/test-watcher-liveness-trichotomy.sh

set -uo pipefail
_real_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_test_helpers.sh
. "$_real_dir/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-liveness-tri-XXXXXX)
FAUX_PID=''

# Identity-verified fixture group reap (skeptic finding 6 on PR#503:
# a raw `kill -- -<recorded pid>` in a test harness is the same
# recycled-pid hazard as the launcher bug it tests around). Signal the
# group ONLY if at least one member's argv references this fixture's
# $WORK tree.
faux_group_reap() {
    local pgid="$1" d stat rest g ok=0
    [[ "$pgid" =~ ^[0-9]+$ ]] || return 0
    for d in /proc/[0-9]*; do
        stat=$(cat "$d/stat" 2>/dev/null) || continue
        rest="${stat##*) }"
        read -r _ _ g _ <<<"$rest"
        [[ "$g" == "$pgid" ]] || continue
        if tr '\0' '\n' < "$d/cmdline" 2>/dev/null | grep -qF "$WORK"; then
            ok=1; break
        fi
    done
    (( ok )) && kill -KILL -- "-$pgid" 2>/dev/null
    return 0
}

cleanup() {
    [[ -n "$FAUX_PID" ]] && th_kill_fixture_pid "$FAUX_PID" "$WORK"
    # Reap faux group survivors by recorded pgid, identity-verified.
    [[ -n "$FAUX_PID" ]] && faux_group_reap "$FAUX_PID"
    rm -rf "$WORK"
}
trap cleanup EXIT

ROOT="$WORK/nexus"
MON="$ROOT/monitor"
WD="$MON/watcher"
STATE="$MON/.state"
mkdir -p "$WD" "$STATE" "$ROOT/config"

# Pin NEXUS_ROOT/NEXUS_LOCALS to THIS fixture so the test is hermetic to
# the operator's ambient nexus, not merely when the caller remembers the
# header's `env -u NEXUS_ROOT -u NEXUS_LOCALS`. revive-watcher.sh's
# live-watcher refusal guard (nexus-code#491) scans the process table for
# `$NEXUS_ROOT/monitor/watcher/main.sh`. Inheriting the operator's real
# NEXUS_ROOT points that scan at the REAL, actively-forking watcher: case B
# (a genuinely dead FIXTURE watcher that MUST be revived) then finds a live
# host watcher, folds its fork-freshness in as "progress", and wrongly hits
# the exit-5 refusal (22/3 under a bare `run-tests.sh`). Pinning both vars
# is equivalent to unsetting them — revive-watcher.sh defaults its own root
# to this copied-in location ($ROOT) — but makes the isolation the header
# promises ("no live watcher or live state is touched") unconditional.
export NEXUS_ROOT="$ROOT"
export NEXUS_LOCALS="$ROOT/locals"

cp "$_real_dir/_lib.sh" "$WD/_lib.sh"
cp "$_real_dir/../revive-watcher.sh" "$MON/revive-watcher.sh"
cp "$_real_dir/../watcher-supervise-tick.sh" "$MON/watcher-supervise-tick.sh"
chmod +x "$MON/revive-watcher.sh" "$MON/watcher-supervise-tick.sh"
cat > "$ROOT/config/load.sh" <<'EOF'
#!/usr/bin/env bash
echo "${2:-}"
EOF
chmod +x "$ROOT/config/load.sh"

# svc.sh stub for revive-watcher: records the restart invocation and,
# to model a real restart, kills the faux watcher group if one exists.
SVC_STUB="$MON/svc-stub.sh"
SVC_CALLS="$STATE/svc-calls.log"
cat > "$SVC_STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SVC_CALLS"
if [[ -f "$STATE/faux.pid" ]]; then
    p=\$(cat "$STATE/faux.pid")
    kill -KILL -- "-\$p" 2>/dev/null || kill -KILL "\$p" 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$SVC_STUB"

# Faux watcher: a setsid group leader whose argv program slot is this
# root's main.sh — exactly what _watcher_pid_is_live_watcher and the
# group scan validate. Plain sleep: alive, but forking nothing.
cat > "$WD/main.sh" <<'EOF'
#!/usr/bin/env bash
sleep 300
EOF
chmod +x "$WD/main.sh"

spawn_faux() {
    setsid bash "$WD/main.sh" </dev/null >/dev/null 2>&1 &
    FAUX_PID=$!
    echo "$FAUX_PID" > "$STATE/faux.pid"
    sleep 0.3
}

kill_faux() {
    [[ -n "$FAUX_PID" ]] || return 0
    th_kill_fixture_pid "$FAUX_PID" "$WORK"
    faux_group_reap "$FAUX_PID"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$FAUX_PID" 2>/dev/null || break
        sleep 0.2
    done
    FAUX_PID=''
}

write_heartbeat() { # <pid> <age_seconds>
    printf 'pid=%s\nts=fixture\ntarget=orchestrator\n' "$1" > "$STATE/watcher-heartbeat"
    touch -d "@$(( $(date +%s) - $2 ))" "$STATE/watcher-heartbeat"
}

reset_state() {
    rm -f "$STATE/watcher-heartbeat" "$STATE/watcher-progress" \
          "$STATE/watcher-cycle" "$STATE/watcher.log" \
          "$STATE/watcher-scheduler.jsonl" "$STATE/watcher.pid" \
          "$STATE/watcher-revive-history.txt" "$SVC_CALLS" 2>/dev/null || true
}

# shellcheck source=_lib.sh
source "$WD/_lib.sh"

INTERVAL=60

# === Case A: stale heartbeat + alive + advancing => BUSY, no tick fire, revive REFUSES ===
echo '=== case A: slow-but-advancing is BUSY, not DOWN (fails on pre-#491 dev) ==='
reset_state
spawn_faux
write_heartbeat "$FAUX_PID" 444          # the exact live false-DOWN observation
touch "$STATE/watcher.log"               # log advancing = forward progress
echo "$FAUX_PID" > "$STATE/watcher.pid"

verdict=$(_watcher_liveness_verdict "$STATE" "$INTERVAL"); vrc=$?
assert_eq "A: verdict state is BUSY"      "$(_watcher_verdict_field "$verdict" state)" "BUSY"
assert_eq "A: verdict rc is 1 (BUSY)"     "$vrc" "1"

NEXUS_STATE_DIR="$STATE" MONITOR_INTERVAL=$INTERVAL bash "$MON/watcher-supervise-tick.sh" \
    >"$WORK/tick.out" 2>"$WORK/tick.err"; tick_rc=$?
assert_eq "A: supervise-tick does NOT fire (exit 0)" "$tick_rc" "0"

NEXUS_STATE_DIR="$STATE" MONITOR_INTERVAL=$INTERVAL REVIVE_SVC_BIN="$SVC_STUB" \
    bash "$MON/revive-watcher.sh" >"$WORK/revive.out" 2>"$WORK/revive.err"; rev_rc=$?
assert_eq "A: revive-watcher REFUSES with exit 5"    "$rev_rc" "5"
assert_contains "A: refusal is loud and names the cause" "$(cat "$WORK/revive.err")" "REFUSING to revive"
assert_no_file  "A: no restart was invoked"          "$SVC_CALLS"
if kill -0 "$FAUX_PID" 2>/dev/null; then
    PASS=$((PASS+1)); echo "ok:   A: faux watcher still alive after refusal (nothing was killed)"
else
    FAIL=$((FAIL+1)); echo "FAIL: A: faux watcher was killed despite the refusal" >&2
fi
kill_faux

# === Case B: genuinely dead => DOWN, tick fires, revive restarts ===
echo '=== case B: dead watcher is still DOWN and still revived ==='
reset_state
# A pid that is certainly dead: spawn-and-reap.
bash -c ':' & dead_pid=$!; wait "$dead_pid" 2>/dev/null
write_heartbeat "$dead_pid" 700
touch -d '-700 seconds' "$STATE/watcher.log"   # nothing advancing either

verdict=$(_watcher_liveness_verdict "$STATE" "$INTERVAL"); vrc=$?
assert_eq "B: verdict state is DOWN"  "$(_watcher_verdict_field "$verdict" state)" "DOWN"
assert_eq "B: verdict rc is 2 (DOWN)" "$vrc" "2"

NEXUS_STATE_DIR="$STATE" MONITOR_INTERVAL=$INTERVAL bash "$MON/watcher-supervise-tick.sh" \
    >"$WORK/tick.out" 2>"$WORK/tick.err"; tick_rc=$?
assert_eq "B: supervise-tick FIRES (non-zero)" "$tick_rc" "1"

rm -f "$STATE/faux.pid"
NEXUS_STATE_DIR="$STATE" MONITOR_INTERVAL=$INTERVAL REVIVE_SVC_BIN="$SVC_STUB" \
    bash "$MON/revive-watcher.sh" >"$WORK/revive.out" 2>"$WORK/revive.err"; rev_rc=$?
assert_eq "B: revive-watcher proceeds (exit 0)" "$rev_rc" "0"
assert_file_exists "B: restart WAS invoked"     "$SVC_CALLS"
assert_contains "B: restart used svc restart watcher" "$(cat "$SVC_CALLS")" "restart watcher"

# === Case C: wedged-but-alive is distinct from BUSY and DOWN ===
echo '=== case C: wedged (alive, fresh heartbeat, no progress) is WEDGED ==='
# The faux group's own members were just forked, and fork-freshness
# counts as progress by design — so this case compresses the timescale
# instead of backdating processes: interval 1s, wedge cutoff 2s, then
# let the faux sit for 4s doing (and forking) nothing.
reset_state
spawn_faux
echo "$FAUX_PID" > "$STATE/watcher.pid"
touch -d '-1200 seconds' "$STATE/watcher-progress"
touch -d '-1200 seconds' "$STATE/watcher.log"
sleep 4
write_heartbeat "$FAUX_PID" 0            # ticker semantics: heartbeat FRESH
WEDGE_ENV=(MONITOR_WATCHER_WEDGE_MULTIPLIER=1 MONITOR_WATCHER_WEDGE_FLOOR_SECONDS=2)

arc=0; env "${WEDGE_ENV[@]}" bash -c '
    source "'"$WD"'/_lib.sh"
    _watcher_alive "'"$STATE"'" 1' || arc=$?
assert_eq "C: _watcher_alive bucket 4 (WEDGED)" "$arc" "4"
verdict=$(env "${WEDGE_ENV[@]}" bash -c '
    source "'"$WD"'/_lib.sh"
    _watcher_liveness_verdict "'"$STATE"'" 1'); vrc=$?
assert_eq "C: verdict state is WEDGED"  "$(_watcher_verdict_field "$verdict" state)" "WEDGED"
assert_eq "C: verdict rc is 4"          "$vrc" "4"

env "${WEDGE_ENV[@]}" NEXUS_STATE_DIR="$STATE" MONITOR_INTERVAL=1 \
    bash "$MON/watcher-supervise-tick.sh" >"$WORK/tick.out" 2>"$WORK/tick.err"; tick_rc=$?
assert_eq "C: supervise-tick FIRES on wedged" "$tick_rc" "1"
assert_contains "C: tick reports WEDGED, not a bare DOWN" "$(cat "$WORK/tick.err")" "WEDGED"

env "${WEDGE_ENV[@]}" NEXUS_STATE_DIR="$STATE" MONITOR_INTERVAL=1 REVIVE_SVC_BIN="$SVC_STUB" \
    bash "$MON/revive-watcher.sh" >"$WORK/revive.out" 2>"$WORK/revive.err"; rev_rc=$?
assert_eq "C: revive-watcher proceeds on wedged (exit 0)" "$rev_rc" "0"
assert_file_exists "C: restart WAS invoked for the wedge"  "$SVC_CALLS"
FAUX_PID=''   # svc stub killed it

# === Case D: ticker keeps the heartbeat fresh through a slow loop ===
echo '=== case D: liveness ticker beats on a fixed cadence, dies with its pid ==='
reset_state
sleep 30 & SLOW_LOOP_PID=$!   # models a watcher stuck in a long sweep: does NO work
HB="$STATE/watcher-heartbeat"
_watcher_heartbeat_ticker_loop "$HB" "$SLOW_LOOP_PID" 1 orchestrator &
TICKER_PID=$!
sleep 2.5
age1=$(_watcher_heartbeat_age "$HB")
if (( age1 <= 1 )); then
    PASS=$((PASS+1)); echo "ok:   D: heartbeat fresh (age ${age1}s) while the 'loop' does no work"
else
    FAIL=$((FAIL+1)); echo "FAIL: D: heartbeat age ${age1}s despite a live ticker" >&2
fi
assert_eq "D: heartbeat names the watched pid" \
    "$(_watcher_heartbeat_field "$HB" pid)" "$SLOW_LOOP_PID"
kill "$SLOW_LOOP_PID" 2>/dev/null; wait "$SLOW_LOOP_PID" 2>/dev/null
sleep 2.5
if kill -0 "$TICKER_PID" 2>/dev/null; then
    FAIL=$((FAIL+1)); echo "FAIL: D: ticker outlived its watched pid" >&2
    kill "$TICKER_PID" 2>/dev/null
else
    PASS=$((PASS+1)); echo "ok:   D: ticker exited within one tick of the watched pid dying"
fi

# === Case E: pre-#491 compat — no progress signal, historical buckets ===
echo '=== case E: no progress signal at all -> historical heartbeat buckets ==='
reset_state
bash -c ':' & dead_pid=$!; wait "$dead_pid" 2>/dev/null
write_heartbeat "$dead_pid" 400
_watcher_alive "$STATE" "$INTERVAL"; arc=$?
assert_eq "E: dead pid + stale hb is bucket 2 (unchanged)" "$arc" "2"
reset_state
spawn_faux
write_heartbeat "$FAUX_PID" 5
_watcher_alive "$STATE" "$INTERVAL"; arc=$?
assert_eq "E: live pid + fresh hb is bucket 0 (unchanged)" "$arc" "0"
kill_faux

th_summary_and_exit
