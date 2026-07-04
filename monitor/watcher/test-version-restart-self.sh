#!/usr/bin/env bash
# Integration test for the watcher SELF-restart path of the
# version-aware component restart (your-org/your-nexus#186):
# a confirmed source-set drift in `_version_check_tick` must drive the
# REAL `launcher.sh --replace` and end with exactly ONE live watcher
# running the new on-disk code — no dead supervisor, no duplicate.
#
# Fixture (mirrors test-launcher-replace.sh): an isolated tree whose
# monitor/watcher holds the REAL launcher.sh + _lib.sh +
# _version_restart.sh and a STUB main.sh that honours the pidfile
# contract (publish pid, idle in 1 s sleep slices). tmux is a PATH
# stub; nothing touches the live `monitor/.state/`.
#
# Cases:
#   1. drift observed once        → pending only; predecessor untouched.
#   2. drift stable (2nd tick)    → real launcher --replace fires
#                                   DETACHED: predecessor dies, a fresh
#                                   pid publishes the pidfile, exactly
#                                   one fixture watcher process remains.
#   3. immediate next tick        → cooldown holds; the successor is
#                                   NOT replaced again (no thrash).
#
# Run: bash monitor/watcher/test-version-restart-self.sh

set -uo pipefail

_real_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=_test_helpers.sh
. "$_real_dir/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-version-self-XXXXXX)
cleanup() {
    local p=''
    [[ -f "$WORK/nexus/monitor/.state/watcher.pid" ]] \
        && read -r p < "$WORK/nexus/monitor/.state/watcher.pid" 2>/dev/null
    [[ "$p" =~ ^[0-9]+$ && -e "/proc/$p" ]] && th_kill_fixture_pid "$p" "$WORK" KILL
    [[ "${FAUX_PID:-}" =~ ^[0-9]+$ && -e "/proc/${FAUX_PID:-x}" ]] \
        && th_kill_fixture_pid "$FAUX_PID" "$WORK" KILL
    rm -rf "$WORK"
}
trap cleanup EXIT

ROOT="$WORK/nexus"
WD="$ROOT/monitor/watcher"
STATE="$ROOT/monitor/.state"
VDIR="$STATE/version"
BIN="$WORK/bin"
mkdir -p "$WD" "$STATE" "$VDIR" "$ROOT/config" "$BIN"

cp "$_real_dir/launcher.sh"         "$WD/launcher.sh"
cp "$_real_dir/_lib.sh"             "$WD/_lib.sh"
cp "$_real_dir/_version_restart.sh" "$WD/_version_restart.sh"
chmod +x "$WD/launcher.sh"

# Stub main.sh v1 — honours the real pidfile contract (publish before
# anything heavy; argv stays `bash …/monitor/watcher/main.sh` for the
# launcher's `_watcher_pid_is_live_watcher` identity check). 1 s sleep
# slices so killed wrappers shed their orphans fast.
write_main() {
    local version="$1"
    cat > "$WD/main.sh" <<EOF
#!/usr/bin/env bash
# fixture watcher $version
echo \$\$ > "$STATE/watcher.pid"
while :; do sleep 1; done
EOF
    chmod +x "$WD/main.sh"
}
write_main v1

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
# Keep the launcher's local-claude self-install path a clean no-op.
cat > "$ROOT/monitor/install-claude-local.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ROOT/monitor/install-claude-local.sh"

# The "running" predecessor: spawn the v1 stub directly (its argv
# carries the fixture main.sh path) and publish its pid — exactly the
# state a live watcher leaves on disk.
bash "$WD/main.sh" </dev/null >/dev/null 2>&1 &
FAUX_PID=$!
disown "$FAUX_PID" 2>/dev/null || true   # mute the job-control obituary
sleep 0.3
OLD_PID=$(cat "$STATE/watcher.pid" 2>/dev/null || echo "")
[[ "$OLD_PID" =~ ^[0-9]+$ ]] || { echo "FAIL: fixture watcher did not publish a pid" >&2; exit 1; }

# Source the fixture module and pin the tick's inputs at it. The
# fixture main.sh has no `source` lines, so the watcher source set is
# main.sh alone. Record v1 as the running version (what the real
# main.sh does at startup), then change main.sh on disk.
# shellcheck source=_version_restart.sh
source "$WD/_version_restart.sh"
_version_window_exists() { return 1; }   # no cockpit window in play

hash_v1=$(_version_startup_record "$VDIR" "$WD/main.sh") \
    || { echo "FAIL: startup record failed" >&2; exit 1; }
write_main v2

run_tick() {
    VERSION_STATE_DIR="$VDIR" \
    NEXUS_ROOT="$ROOT" \
    TARGET=orch-test \
    LOGFILE="$WORK/launcher.log" \
    MONITOR_VERSION_SETTLE_SECONDS=0 \
    MONITOR_VERSION_RESTART_COOLDOWN_SECONDS=600 \
    MONITOR_VERSION_SELF_RESTART=true \
    MONITOR_VERSION_SERVICE_RESTART=true \
    MONITOR_VERSION_SELF_LOOP_LIMIT=3 \
    MONITOR_VERSION_SELF_LOOP_WINDOW_SECONDS=3600 \
    MONITOR_COCKPIT_WINDOW=services \
    NEXUS_SERVICES_REGISTRY="$ROOT/monitor/services.registry" \
    _VERSION_MAIN_SH="$WD/main.sh" \
    _VERSION_LAUNCHER_BIN="$WD/launcher.sh" \
    PATH="$BIN:$PATH" \
        _version_check_tick 2>>"$WORK/tick.log"
}

# Count live processes whose cmdline carries the fixture main.sh path.
count_watchers() {
    local n=0 pid cmdline
    for pid in $(pgrep -f "$WD/main.sh" 2>/dev/null); do
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
        [[ "$cmdline" == *"$WD/main.sh"* ]] && n=$(( n + 1 ))
    done
    printf '%d' "$n"
}

echo '=== case 1: first observation => pending only, predecessor untouched ==='
run_tick
if kill -0 "$OLD_PID" 2>/dev/null; then
    printf '  PASS: predecessor still alive after first observation\n'; PASS=$((PASS+1))
else
    printf '  FAIL: predecessor died on first observation (no stability window?)\n' >&2; FAIL=$((FAIL+1))
fi
assert_file_exists "pending state created" "$VDIR/watcher.pending"
assert_no_file "no premature self-restart history" "$VDIR/self-restart-history.txt"

echo '=== case 2: stable drift => real launcher --replace, one fresh watcher ==='
run_tick
# The launcher runs detached; give it up to 20 s (TERM grace ≤5 s +
# spawn-verify poll ≤15 s) to finish the replace.
NEW_PID=""
for _i in $(seq 1 80); do
    NEW_PID=$(cat "$STATE/watcher.pid" 2>/dev/null || echo "")
    if [[ "$NEW_PID" =~ ^[0-9]+$ && "$NEW_PID" != "$OLD_PID" ]] \
       && kill -0 "$NEW_PID" 2>/dev/null; then
        break
    fi
    NEW_PID=""
    sleep 0.25
done
if [[ -n "$NEW_PID" ]]; then
    printf '  PASS: successor published a live pidfile (pid=%s)\n' "$NEW_PID"; PASS=$((PASS+1))
else
    printf '  FAIL: no live successor pid within 20s; launcher log:\n' >&2
    sed 's/^/    /' "$WORK/launcher.log" >&2 2>/dev/null
    FAIL=$((FAIL+1))
fi
if kill -0 "$OLD_PID" 2>/dev/null; then
    printf '  FAIL: predecessor %s survived the replace (double watcher)\n' "$OLD_PID" >&2; FAIL=$((FAIL+1))
else
    printf '  PASS: predecessor %s terminated\n' "$OLD_PID"; PASS=$((PASS+1))
fi
sleep 0.5
assert_eq "exactly one fixture watcher process remains" "$(count_watchers)" "1"
assert_file_exists "self-restart history appended" "$VDIR/self-restart-history.txt"
assert_file_exists "cooldown stamped" "$VDIR/watcher.restart.last"
# The successor runs the NEW code (its argv'd main.sh is v2 on disk).
if [[ -n "$NEW_PID" ]]; then
    assert_contains "successor main.sh is the new version on disk" \
        "$(cat "$WD/main.sh")" "fixture watcher v2"
fi

echo '=== case 3: immediate next tick => cooldown holds, successor kept ==='
run_tick
sleep 1
PID_AFTER=$(cat "$STATE/watcher.pid" 2>/dev/null || echo "")
assert_eq "successor not replaced inside cooldown" "$PID_AFTER" "$NEW_PID"
assert_eq "history still records exactly one self-restart" \
    "$(grep -c '^[0-9]' "$VDIR/self-restart-history.txt" 2>/dev/null)" "1"
assert_eq "still exactly one fixture watcher process" "$(count_watchers)" "1"

th_summary_and_exit
