#!/usr/bin/env bash
# Tests for the mutual-liveness watcher supervision (your-org/your-nexus
# watcher-supervision): the orchestrator-armed Monitor tick
# (watcher-supervise-tick.sh), the crash-revive (revive-watcher.sh), the
# watcher's arm-reminder emit section (_supervisor_arm_emit_section), and
# the single-flight + group-reaping idempotent restart in launcher.sh.
# Load-bearing invariants:
#
#   A. single-live-instance — a restart converges to EXACTLY ONE live
#      watcher (0 or 1 running), and a duplicate cannot coexist.
#   B. tick = liveness signal — the tick TOUCHES the supervisor heartbeat
#      every run and exits 0 (watcher alive) / non-zero (down) so the
#      orchestrator's `until ! tick` loop wakes only on death.
#   C. revive — revive-watcher.sh revives a dead watcher (idempotent restart),
#      writes the self-report marker, respects an intentional-stop sentinel,
#      and is loop-guarded against thrashing a crash-looping watcher.
#   D. reminder — the watcher emits `--- arm watcher supervisor ---` when the
#      supervisor heartbeat is stale/absent, and suppresses it when fresh.
#   E. no double-restart race — concurrent restart attempts leave one watcher.
#
# Fixture: an isolated tree with the REAL launcher.sh + _lib.sh +
# _respawn_async.sh + watcher-supervise-tick.sh + revive-watcher.sh +
# svc.sh closure and a STUB main.sh that honours the single-instance
# contract (pid + heartbeat + instance flock + duplicate self-close).
#
# Run: bash monitor/watcher/test-watcher-supervise.sh

set -uo pipefail
_real_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_test_helpers.sh
. "$_real_dir/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-wsup2-XXXXXX)
cleanup() {
    local p
    for p in $(pgrep -f "$WORK/nexus/monitor/watcher/main.sh" 2>/dev/null); do
        kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

ROOT="$WORK/nexus"
MON="$ROOT/monitor"
WD="$MON/watcher"
STATE="$MON/.state"
BIN="$WORK/bin"
mkdir -p "$WD" "$STATE" "$ROOT/config" "$BIN"

cp "$_real_dir/launcher.sh"        "$WD/launcher.sh"
cp "$_real_dir/_lib.sh"            "$WD/_lib.sh"
cp "$_real_dir/_respawn_async.sh"  "$WD/_respawn_async.sh"
cp "$_real_dir/../watcher-supervise-tick.sh" "$MON/watcher-supervise-tick.sh"
cp "$_real_dir/../revive-watcher.sh"         "$MON/revive-watcher.sh"
chmod +x "$WD/launcher.sh" "$MON/watcher-supervise-tick.sh" "$MON/revive-watcher.sh"

# Stub main.sh — faithful single-instance contract (see test-version-restart-self).
cat > "$WD/main.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
STATE="$STATE"
PIDFILE="\$STATE/watcher.pid"; HB="\$STATE/watcher-heartbeat"; ILOCK="\$STATE/nexus-instance.lock"
peer=\$(cat "\$PIDFILE" 2>/dev/null || true)
if [[ "\$peer" =~ ^[0-9]+\$ ]] && (( peer != \$\$ )) && kill -0 "\$peer" 2>/dev/null; then
    cl="/proc/\$peer/cmdline"
    if [[ ! -r "\$cl" ]] || tr '\0' ' ' < "\$cl" 2>/dev/null | grep -q main.sh; then exit 1; fi
fi
exec {ILFD}<>"\$ILOCK" || exit 5
flock -n "\$ILFD" || exit 4
# Early heartbeat STRICTLY BEFORE the pidfile (mirrors main.sh skeptic
# #001 fix): an observer that sees a live pidfile is then guaranteed to
# see a fresh heartbeat naming our live pid — no startup false-DOWN.
printf 'pid=%d\nts=%s\ntarget=t\n' "\$\$" "\$(date -Is)" > "\$HB" 2>/dev/null || true
echo \$\$ > "\$PIDFILE"
trap 'rm -f "\$PIDFILE" 2>/dev/null || true' EXIT
while :; do printf 'pid=%d\nts=%s\ntarget=t\n' "\$\$" "\$(date -Is)" > "\$HB" 2>/dev/null || true; sleep 1; done
EOF
chmod +x "$WD/main.sh"

# A minimal svc.sh stub for revive-watcher: records the call + does the real
# launcher --replace (so revive genuinely converges to one watcher).
cat > "$MON/svc.sh" <<EOF
#!/usr/bin/env bash
echo "svc restart \$*" >> "$WORK/svc-calls.log"
[[ "\$1 \$2" == "restart watcher" ]] && exec "$WD/launcher.sh" --replace --target t
exit 0
EOF
chmod +x "$MON/svc.sh"

cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN/tmux"
cat > "$ROOT/config/load.sh" <<'EOF'
#!/usr/bin/env bash
echo "${2:-}"
EOF
chmod +x "$ROOT/config/load.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MON/install-claude-local.sh"; chmod +x "$MON/install-claude-local.sh"
mkdir -p "$ROOT/node_modules/.bin"; : > "$ROOT/node_modules/.bin/claude"; chmod +x "$ROOT/node_modules/.bin/claude"
export PATH="$BIN:$PATH"

count_watchers() {
    local n=0 pid cl
    for pid in $(pgrep -f "$WD/main.sh" 2>/dev/null); do
        cl=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
        [[ "$cl" == *"$WD/main.sh"* ]] && n=$(( n + 1 ))
    done
    printf '%d' "$n"
}
wait_watchers() { local w="$1" s="${2:-20}" i; for (( i=0; i<s*4; i++ )); do [[ "$(count_watchers)" == "$w" ]] && return 0; sleep 0.25; done; return 1; }

echo '=== A1: cold start (0 trees) — launcher --ensure spawns exactly one ==='
"$WD/launcher.sh" --ensure --target t >>"$WORK/launcher.log" 2>&1
wait_watchers 1 || true
assert_eq "exactly one watcher after cold --ensure" "$(count_watchers)" "1"
P1=$(cat "$STATE/watcher.pid" 2>/dev/null)

echo '=== B: tick touches the supervisor heartbeat + reports liveness ==='
rm -f "$STATE/watcher-supervisor-heartbeat"
NEXUS_STATE_DIR="$STATE" MONITOR_INTERVAL=60 "$MON/watcher-supervise-tick.sh"; trc=$?
assert_eq "tick exits 0 while watcher alive" "$trc" "0"
assert_file_exists "tick touched the supervisor heartbeat" "$STATE/watcher-supervisor-heartbeat"

echo '=== D: arm-reminder emit — fresh hb suppresses, stale/absent nags ==='
( NEXUS_STATE_DIR="$STATE"; source "$WD/_lib.sh"
  # fresh hb (just touched) → armed → empty
  if out=$(_supervisor_arm_emit_section "$STATE/watcher-supervisor-heartbeat" 90); then echo "FAIL-fresh-nonempty"; else echo "PASS-fresh-suppressed"; fi
  # absent hb → not armed → reminder
  if out=$(_supervisor_arm_emit_section "$STATE/nope-absent" 90); then
      [[ "$out" == *"arm"* || "$out" == *"NOT armed"* ]] && echo "PASS-absent-nags" || echo "FAIL-absent-text"
  else echo "FAIL-absent-empty"; fi
  # disabled → empty even when stale
  if MONITOR_WATCHER_SUPERVISOR_ENABLED=false _supervisor_arm_emit_section "$STATE/nope-absent" 90 >/dev/null; then echo "FAIL-disabled-nonempty"; else echo "PASS-disabled-suppressed"; fi
) > "$WORK/reminder.log" 2>&1
assert_contains "fresh heartbeat suppresses reminder" "$(cat "$WORK/reminder.log")" "PASS-fresh-suppressed"
assert_contains "absent heartbeat emits reminder"    "$(cat "$WORK/reminder.log")" "PASS-absent-nags"
assert_contains "disabled suppresses reminder"       "$(cat "$WORK/reminder.log")" "PASS-disabled-suppressed"

echo '=== B2 + C: kill watcher → tick reports DOWN → revive brings exactly one back ==='
kill -KILL -- "-$P1" 2>/dev/null || kill -KILL "$P1" 2>/dev/null || true
sleep 0.5
rm -f "$STATE/watcher.pid"   # heartbeat left stale on purpose (crash evidence)
assert_eq "watcher dead before revive" "$(count_watchers)" "0"
NEXUS_STATE_DIR="$STATE" MONITOR_INTERVAL=60 "$MON/watcher-supervise-tick.sh"; trc=$?
[[ "$trc" != "0" ]] && { printf '  PASS: tick reports DOWN (rc=%s)\n' "$trc"; PASS=$((PASS+1)); } || { printf '  FAIL: tick did not report DOWN\n' >&2; FAIL=$((FAIL+1)); }
: > "$WORK/svc-calls.log"
NEXUS_ROOT="$ROOT" NEXUS_STATE_DIR="$STATE" REVIVE_SVC_BIN="$MON/svc.sh" MONITOR_INTERVAL=60 \
  "$MON/revive-watcher.sh" >>"$WORK/revive.log" 2>&1
wait_watchers 1 || true
assert_eq "revive brought back exactly one watcher" "$(count_watchers)" "1"
assert_contains "revive called the proper restart command" "$(cat "$WORK/svc-calls.log")" "restart watcher"
assert_file_exists "revive wrote the self-failure marker" "$STATE/watcher-revived"
assert_contains "marker attributes the revival to the orchestrator Monitor" "$(cat "$STATE/watcher-revived" 2>/dev/null)" "restarted_by=orchestrator-monitor"

echo '=== C2: intentional-stop sentinel — revive refuses (no fight) ==='
P2=$(cat "$STATE/watcher.pid" 2>/dev/null)
kill -KILL -- "-$P2" 2>/dev/null || kill -KILL "$P2" 2>/dev/null || true
sleep 0.5; rm -f "$STATE/watcher.pid"
: > "$STATE/watcher-stop-requested"; : > "$WORK/svc-calls.log"
NEXUS_ROOT="$ROOT" NEXUS_STATE_DIR="$STATE" REVIVE_SVC_BIN="$MON/svc.sh" MONITOR_INTERVAL=60 \
  "$MON/revive-watcher.sh" >>"$WORK/revive.log" 2>&1; rrc=$?
assert_eq "revive no-ops on intentional stop (rc 0)" "$rrc" "0"
assert_eq "revive did NOT restart under stop sentinel" "$(count_watchers)" "0"
if [[ -s "$WORK/svc-calls.log" ]]; then printf '  FAIL: revive called svc under stop sentinel\n' >&2; FAIL=$((FAIL+1)); else printf '  PASS: revive made no restart call under stop sentinel\n'; PASS=$((PASS+1)); fi
rm -f "$STATE/watcher-stop-requested"

echo '=== C3: revive loop guard trips after the limit (no thrash) ==='
GS="$(mktemp -d "$WORK/guard-XXXX")/state"; mkdir -p "$GS"
: > "$WORK/guard-svc.log"
cat > "$WORK/guard-svc.sh" <<EOF
#!/usr/bin/env bash
echo call >> "$WORK/guard-svc.log"
exit 0
EOF
chmod +x "$WORK/guard-svc.sh"
# Permanently-dead watcher: stale heartbeat + dead pid so revive always acts.
printf 'pid=999999\nts=old\n' > "$GS/watcher-heartbeat"; touch -d '1 hour ago' "$GS/watcher-heartbeat" 2>/dev/null || true
for _i in 1 2 3 4 5 6; do
  NEXUS_ROOT="$ROOT" NEXUS_STATE_DIR="$GS" REVIVE_SVC_BIN="$WORK/guard-svc.sh" MONITOR_INTERVAL=60 \
    MONITOR_WATCHER_SUPERVISOR_LOOP_LIMIT=3 MONITOR_WATCHER_SUPERVISOR_LOOP_WINDOW_SECONDS=3600 \
    "$MON/revive-watcher.sh" >>"$WORK/revive.log" 2>&1 || true
done
GCALLS=$(grep -c '^call' "$WORK/guard-svc.log" 2>/dev/null || echo 0)
if (( GCALLS >= 1 && GCALLS <= 3 )); then printf '  PASS: revive guard capped restart calls at %d (limit 3)\n' "$GCALLS"; PASS=$((PASS+1)); else printf '  FAIL: guard did not cap (got %s, want 1..3)\n' "$GCALLS" >&2; FAIL=$((FAIL+1)); fi

echo '=== E: double-restart race — concurrent --replace + --ensure leave one ==='
"$WD/launcher.sh" --ensure --target t >>"$WORK/launcher.log" 2>&1   # ensure one is up
wait_watchers 1 || true
"$WD/launcher.sh" --replace --target t >>"$WORK/launcher.log" 2>&1 & R1=$!
"$WD/launcher.sh" --ensure  --target t >>"$WORK/launcher.log" 2>&1 & R2=$!
wait "$R1" 2>/dev/null || true; wait "$R2" 2>/dev/null || true
wait_watchers 1 || true; sleep 0.5
assert_eq "exactly one watcher after concurrent restart attempts" "$(count_watchers)" "1"

echo '=== G: early heartbeat eliminates the startup false-DOWN (skeptic #001) ==='
# G1 structural: the REAL main.sh must publish the early heartbeat BEFORE
# the slow `source _config.sh` — else a starting watcher reads DOWN (its
# heartbeat still names the old dead pid) for the whole config window.
hb_ln=$(grep -n 'watcher-heartbeat\.tmp' "$_real_dir/main.sh" | head -1 | cut -d: -f1)
cfg_ln=$(grep -n 'source "\$_script_dir/_config\.sh"' "$_real_dir/main.sh" | head -1 | cut -d: -f1)
if [[ "$hb_ln" =~ ^[0-9]+$ && "$cfg_ln" =~ ^[0-9]+$ ]] && (( hb_ln < cfg_ln )); then
    printf '  PASS: main.sh publishes early heartbeat (line %s) before sourcing _config.sh (line %s)\n' "$hb_ln" "$cfg_ln"; PASS=$((PASS+1))
else
    printf '  FAIL: main.sh early-heartbeat must precede _config.sh source (hb=%s cfg=%s)\n' "$hb_ln" "$cfg_ln" >&2; FAIL=$((FAIL+1))
fi
# G2 behavioral: a stale OLD-pid heartbeat must NOT survive a spawn. Seed
# one (dead pid, old mtime), spawn the watcher, and assert _watcher_alive
# reads ALIVE immediately after the launcher returns — i.e. the new
# watcher's early heartbeat overwrote the stale one with its live pid,
# so `restart watcher`'s post-check (and the supervise tick) never see a
# false DOWN on a healthy-but-slow-starting watcher.
"$WD/launcher.sh" --replace --target t >>"$WORK/launcher.log" 2>&1   # ensure a live watcher
wait_watchers 1 || true
PG=$(cat "$STATE/watcher.pid" 2>/dev/null)
kill -KILL -- "-$PG" 2>/dev/null || kill -KILL "$PG" 2>/dev/null || true
# Wait for the SIGKILL'd holder to be fully gone AND its instance flock
# released by the kernel before respawning — a hard-kill-then-immediate-
# respawn races the flock release (a TEST artifact; production's
# --replace releases gracefully via SIGTERM first). Otherwise the new
# launcher --ensure would refuse on the not-yet-released flock.
wait_watchers 0 10 || true
for _i in $(seq 1 40); do
    ( source "$WD/_lib.sh"; _nexus_instance_lock_live "$STATE/nexus-instance.lock" >/dev/null ) || break
    sleep 0.25
done
printf 'pid=999999\nts=stale\ntarget=t\n' > "$STATE/watcher-heartbeat"   # stale: names a dead pid
touch -d '1 hour ago' "$STATE/watcher-heartbeat" 2>/dev/null || true
rm -f "$STATE/watcher.pid"
"$WD/launcher.sh" --ensure --target t >>"$WORK/launcher.log" 2>&1        # spawn → writes pid + early hb
wait_watchers 1 || true                                                  # let the spawn publish
( NEXUS_STATE_DIR="$STATE"; source "$WD/_lib.sh"
  _watcher_alive "$STATE" 60; echo "alive_rc=$?" ) > "$WORK/alive.log" 2>&1
assert_contains "stale old-pid heartbeat overwritten → _watcher_alive reads ALIVE post-spawn" "$(cat "$WORK/alive.log")" "alive_rc=0"

th_summary_and_exit
