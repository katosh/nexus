#!/usr/bin/env bash
# Both-direction test of the watcher↔supervisor MUTUAL-LIVENESS contract
# (your-org/your-nexus watcher-supervision, PR #292). The existing
# test-watcher-supervise.sh covers the supervision machinery broadly;
# THIS test is the focused, end-to-end proof that BOTH liveness
# directions react correctly, with the load-bearing Direction-B
# invariants (exactly-one-watcher, single-root, idempotency/no-storm)
# asserted explicitly.
#
#   Direction A — watcher UP, supervisor NOT armed → the watcher emits
#     the `--- arm watcher supervisor ---` reminder, and the body carries
#     the ACTIONABLE command (the `Monitor({command: ...})` line). A tick
#     (which arms the supervisor by touching the heartbeat) then SILENCES
#     the reminder — the coupling that makes the contract self-clearing.
#
#   Direction B — supervisor armed, watcher DOWN → the tick reports DOWN
#     via non-zero exit with a self-descriptive recovery message, and
#     revive-watcher.sh converges to EXACTLY ONE live watcher (never zero,
#     never a duplicate; single-root verified), idempotently (reviving an
#     already-alive OR already-dead watcher both yield exactly one).
#
# Everything runs against an ISOLATED state dir under a mktemp tree; no
# live watcher / live Monitor / live state is touched. Watchers spawned
# here live ONLY under $WORK and are reaped by recorded process-group in
# the EXIT trap; teardown asserts zero leftover.
#
# Mutation hook (for the skeptic / regression confidence): export
#   SUP_LIVENESS_MUTATE=double-spawn
# and the svc restart stub spawns TWO watchers instead of one — the
# Direction-B "exactly one" assertions MUST then fail. This makes the
# single-instance guard's load-bearing-ness reproducible in one command.
#
# Run: bash monitor/watcher/test-supervisor-liveness.sh

set -uo pipefail
_real_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_test_helpers.sh
. "$_real_dir/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-suplive-XXXXXX)
cleanup() {
    local p
    # Reap by process-group of any surviving fixture watcher. The path is
    # unique to $WORK, so this can never match the live watcher or self.
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

# Stub main.sh — faithful single-instance contract: refuse if a live
# peer holds the pidfile, take the instance flock, publish the early
# heartbeat STRICTLY BEFORE the pidfile, then heartbeat-loop. (Mirrors
# the contract the real main.sh honours; same stub as
# test-watcher-supervise.sh.)
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
printf 'pid=%d\nts=%s\ntarget=t\n' "\$\$" "\$(date -Is)" > "\$HB" 2>/dev/null || true
echo \$\$ > "\$PIDFILE"
trap 'rm -f "\$PIDFILE" 2>/dev/null || true' EXIT
while :; do printf 'pid=%d\nts=%s\ntarget=t\n' "\$\$" "\$(date -Is)" > "\$HB" 2>/dev/null || true; sleep 1; done
EOF
chmod +x "$WD/main.sh"

# svc.sh stub for revive-watcher: records the call + does the real
# launcher --replace so revive genuinely converges to one watcher.
# Mutation hook: SUP_LIVENESS_MUTATE=double-spawn spawns a SECOND,
# guard-bypassing watcher (its own pidfile/flock) so "exactly one"
# breaks — proving those assertions are load-bearing.
cat > "$MON/svc.sh" <<EOF
#!/usr/bin/env bash
echo "svc restart \$*" >> "$WORK/svc-calls.log"
if [[ "\$1 \$2" == "restart watcher" ]]; then
    if [[ "\${SUP_LIVENESS_MUTATE:-}" == "double-spawn" ]]; then
        # Bypass the single-instance guard: launch a raw second main.sh
        # under its OWN pidfile/lock so two live watchers coexist.
        ( ILOCK2="$STATE/nexus-instance.lock.mutant"
          exec {f}<>"\$ILOCK2"; flock -n "\$f"
          exec bash "$WD/main.sh" ) >/dev/null 2>&1 &
    fi
    exec "$WD/launcher.sh" --replace --target t
fi
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

# Count + identify live fixture watchers (path is unique to $WORK).
count_watchers() {
    local n=0 pid cl
    for pid in $(pgrep -f "$WD/main.sh" 2>/dev/null); do
        cl=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
        [[ "$cl" == *"$WD/main.sh"* ]] && n=$(( n + 1 ))
    done
    printf '%d' "$n"
}
live_watcher_pids() {
    local pid cl
    for pid in $(pgrep -f "$WD/main.sh" 2>/dev/null); do
        cl=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
        [[ "$cl" == *"$WD/main.sh"* ]] && printf '%s\n' "$pid"
    done
}
wait_watchers() { local w="$1" s="${2:-20}" i; for (( i=0; i<s*4; i++ )); do [[ "$(count_watchers)" == "$w" ]] && return 0; sleep 0.25; done; return 1; }

# Assert EXACTLY ONE live watcher AND single-root: the pidfile names the
# sole live main.sh — never zero, never a duplicate. This is the #1
# invariant of the revive path.
assert_exactly_one_watcher() {
    local label="$1"
    local n pids pidfile
    n=$(count_watchers)
    pids=$(live_watcher_pids | tr '\n' ' ')
    pidfile=$(cat "$STATE/watcher.pid" 2>/dev/null || echo '')
    if [[ "$n" == "1" ]] && [[ -n "$pidfile" ]] && kill -0 "$pidfile" 2>/dev/null \
       && [[ " $pids " == *" $pidfile "* ]]; then
        printf '  PASS: %s (1 live watcher pid=%s, pidfile agrees — single-root)\n' "$label" "$pidfile"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — count=%s live_pids=[%s] pidfile=%q\n' "$label" "$n" "$pids" "$pidfile" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

echo "############ DIRECTION A — watcher UP, supervisor NOT armed → arm reminder ############"
echo '=== A0: bring up an isolated watcher (precondition: watcher genuinely UP) ==='
"$WD/launcher.sh" --ensure --target t >>"$WORK/launcher.log" 2>&1
wait_watchers 1 || true
assert_exactly_one_watcher "isolated watcher up before Direction-A check"

echo '=== A1: NO supervisor heartbeat → watcher emit pipeline surfaces the arm reminder ==='
rm -f "$STATE/watcher-supervisor-heartbeat"
# Reproduce main.sh's emit logic verbatim (main.sh:860-866 + 1703): compute
# the arm-emit body, and iff non-empty print the `--- arm watcher
# supervisor ---` header before it.
armout=$(
  source "$WD/_lib.sh"
  body=$(_supervisor_arm_emit_section "$STATE/watcher-supervisor-heartbeat" 90 "$ROOT" 2>/dev/null || true)
  if [[ -n "$body" ]]; then echo '--- arm watcher supervisor ---'; printf '%s\n' "$body"; fi
)
assert_contains "watcher emits the arm-supervisor section header"        "$armout" "--- arm watcher supervisor ---"
assert_contains "arm reminder names the supervisor is NOT armed"         "$armout" "NOT armed"
assert_contains "arm reminder carries the ACTIONABLE Monitor command"    "$armout" 'Monitor({command: "until !'
assert_contains "arm reminder names the supervise-tick script"           "$armout" "monitor/watcher-supervise-tick.sh"
assert_contains "arm reminder names the revive script"                   "$armout" "monitor/revive-watcher.sh"
assert_contains "arm reminder points at the service-recovery skill"      "$armout" "skills/nexus.service-recovery"

echo '=== A2: a supervise tick ARMS the supervisor → the reminder self-clears ==='
NEXUS_STATE_DIR="$STATE" MONITOR_INTERVAL=60 "$MON/watcher-supervise-tick.sh"; trc=$?
assert_eq "tick exits 0 while watcher alive" "$trc" "0"
assert_file_exists "tick touched (armed) the supervisor heartbeat" "$STATE/watcher-supervisor-heartbeat"
armout2=$(
  source "$WD/_lib.sh"
  _supervisor_arm_emit_section "$STATE/watcher-supervisor-heartbeat" 90 "$ROOT" 2>/dev/null || true
)
assert_empty "fresh supervisor heartbeat (armed) suppresses the reminder" "$armout2"

echo "############ DIRECTION B — supervisor armed, watcher DOWN → revive → exactly one ############"
echo '=== B1: alive watcher → tick reports ALIVE (exit 0) + touches heartbeat ==='
rm -f "$STATE/watcher-supervisor-heartbeat"
NEXUS_STATE_DIR="$STATE" MONITOR_INTERVAL=60 "$MON/watcher-supervise-tick.sh"; trc=$?
assert_eq "tick exit 0 (watcher alive)" "$trc" "0"
assert_file_exists "tick touched the supervisor heartbeat" "$STATE/watcher-supervisor-heartbeat"

echo '=== B2: KILL the watcher → tick reports DOWN (exit non-zero) + self-descriptive recovery ==='
P1=$(cat "$STATE/watcher.pid" 2>/dev/null)
kill -KILL -- "-$P1" 2>/dev/null || kill -KILL "$P1" 2>/dev/null || true
wait_watchers 0 10 || true
rm -f "$STATE/watcher.pid"        # heartbeat left stale on purpose (crash evidence)
assert_eq "watcher dead before revive" "$(count_watchers)" "0"
NEXUS_STATE_DIR="$STATE" MONITOR_INTERVAL=60 "$MON/watcher-supervise-tick.sh" 2>"$WORK/tick-down.err"; trc=$?
[[ "$trc" != "0" ]] && { printf '  PASS: tick reports DOWN (rc=%s)\n' "$trc"; PASS=$((PASS+1)); } \
                    || { printf '  FAIL: tick did not report DOWN\n' >&2; FAIL=$((FAIL+1)); }
downmsg=$(cat "$WORK/tick-down.err")
assert_contains "down message names the reason (DEAD/stale)"           "$downmsg" "watcher DOWN:"
assert_contains "down message gives the exact revive command"          "$downmsg" "monitor/revive-watcher.sh"
assert_contains "down message gives the exact re-arm Monitor command"  "$downmsg" 'Monitor({command: "until !'
assert_contains "down message points at the service-recovery skill"    "$downmsg" "skills/nexus.service-recovery"

echo '=== B3: revive → EXACTLY ONE live watcher (single-root); tick reads ALIVE again ==='
: > "$WORK/svc-calls.log"
NEXUS_ROOT="$ROOT" NEXUS_STATE_DIR="$STATE" REVIVE_SVC_BIN="$MON/svc.sh" MONITOR_INTERVAL=60 \
  "$MON/revive-watcher.sh" >>"$WORK/revive.log" 2>&1
wait_watchers 1 || true
assert_exactly_one_watcher "revive converged to exactly one watcher"
assert_contains "revive called the proper restart command" "$(cat "$WORK/svc-calls.log")" "restart watcher"
assert_contains "revive output states the exactly-one outcome" "$(cat "$WORK/revive.log")" "exactly ONE live watcher"
assert_contains "revive output gives the re-arm Monitor command" "$(cat "$WORK/revive.log")" 'Monitor({command: "until !'
NEXUS_STATE_DIR="$STATE" MONITOR_INTERVAL=60 "$MON/watcher-supervise-tick.sh"; trc=$?
assert_eq "tick exit 0 after revive (alive again)" "$trc" "0"

echo '=== B4: idempotency / no-storm — revive while ALREADY ALIVE does NOT spawn a second ==='
PBEFORE=$(cat "$STATE/watcher.pid" 2>/dev/null)
: > "$WORK/svc-calls.log"
NEXUS_ROOT="$ROOT" NEXUS_STATE_DIR="$STATE" REVIVE_SVC_BIN="$MON/svc.sh" MONITOR_INTERVAL=60 \
  "$MON/revive-watcher.sh" >>"$WORK/revive.log" 2>&1; rrc=$?
sleep 0.5
assert_eq "revive-while-alive no-ops (rc 0)" "$rrc" "0"
assert_exactly_one_watcher "still exactly one watcher after revive-while-alive"
PAFTER=$(cat "$STATE/watcher.pid" 2>/dev/null)
assert_eq "revive-while-alive did NOT restart (same pid)" "$PAFTER" "$PBEFORE"
if [[ -s "$WORK/svc-calls.log" ]]; then printf '  FAIL: revive made a restart call while watcher alive\n' >&2; FAIL=$((FAIL+1)); else printf '  PASS: revive made NO restart call while watcher alive\n'; PASS=$((PASS+1)); fi

echo '=== B5: revive while ALREADY DEAD → exactly one again ==='
P2=$(cat "$STATE/watcher.pid" 2>/dev/null)
kill -KILL -- "-$P2" 2>/dev/null || kill -KILL "$P2" 2>/dev/null || true
wait_watchers 0 10 || true
rm -f "$STATE/watcher.pid"
assert_eq "watcher dead before second revive" "$(count_watchers)" "0"
NEXUS_ROOT="$ROOT" NEXUS_STATE_DIR="$STATE" REVIVE_SVC_BIN="$MON/svc.sh" MONITOR_INTERVAL=60 \
  "$MON/revive-watcher.sh" >>"$WORK/revive.log" 2>&1
wait_watchers 1 || true
assert_exactly_one_watcher "revive-while-dead converged to exactly one watcher"

echo '=== B6: teardown — reap the fixture watcher; assert zero leftover ==='
PEND=$(cat "$STATE/watcher.pid" 2>/dev/null)
kill -KILL -- "-$PEND" 2>/dev/null || kill -KILL "$PEND" 2>/dev/null || true
wait_watchers 0 10 || true
assert_eq "zero fixture watchers left at teardown" "$(count_watchers)" "0"

th_summary_and_exit
