#!/usr/bin/env bash
# Both-direction test of the group-based watcher singleton guarantee
# (nexus-code#491, decapitation + fd-leak evidence of 2026-07-09 17:45):
#
#   Case A — DECAPITATION: killing the group LEADER leaves the forked
#     subshell chain running the loop (this is the bug, reproduced in a
#     fixture); the launcher's recovery path (--replace) then reaps the
#     decapitated group — verified EMPTY — before spawning, leaving
#     exactly one live group. FAILS on pre-#491 dev (dev sees a stale
#     pidfile, removes it, and spawns NEXT TO the orphan loop).
#   Case B — two CONCURRENT --replace launchers converge to exactly
#     one live watcher group (raced deliberately).
#   Case C — svc.sh status REPORTS a duplicate (two live groups) and
#     exits non-zero. FAILS on pre-#491 dev (dev names whichever pid
#     the heartbeat holds and exits 0).
#   Case D — the instance-lock fd is NOT inherited by scheduler async
#     children (asserted via /proc/<child>/fd), while the parent still
#     holds it — the #451/#468/#471 fd-leak class, closed at the fork
#     chokepoint.
#   Case E — the single-flight restart lock FAILS CLOSED: a launcher
#     that cannot acquire it within the wait refuses (exit 5) instead
#     of proceeding to a possible duplicate spawn.
#
# Isolated mktemp trees; fixture processes are reaped by recorded
# pid/pgid (never pkill -f); no live watcher or live state is touched.
#
# Run: env -u NEXUS_ROOT -u NEXUS_LOCALS bash monitor/watcher/test-watcher-singleton-groups.sh

set -uo pipefail
_real_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_test_helpers.sh
. "$_real_dir/_test_helpers.sh"

# Identity-verified fixture group reap (skeptic finding 6 on PR#503:
# a raw `kill -- -<recorded pgid>` at EXIT is a recycled-pid hazard —
# the same class the launcher fix guards). Each entry records the pgid
# WITH the fixture tree it belongs to; the group is signalled only if
# a member's argv still references that tree.
declare -a REAP_ENTRIES=()   # "pgid<TAB>tree"
reap_later() { REAP_ENTRIES+=("$1"$'\t'"$2"); }
fixture_group_reap() {
    local pgid="$1" tree="$2" d stat rest g ok=0
    [[ "$pgid" =~ ^[0-9]+$ && -n "$tree" ]] || return 0
    for d in /proc/[0-9]*; do
        stat=$(cat "$d/stat" 2>/dev/null) || continue
        rest="${stat##*) }"
        read -r _ _ g _ <<<"$rest"
        [[ "$g" == "$pgid" ]] || continue
        if tr '\0' '\n' < "$d/cmdline" 2>/dev/null | grep -qF "$tree"; then
            ok=1; break
        fi
    done
    (( ok )) && kill -KILL -- "-$pgid" 2>/dev/null
    return 0
}
WORK=''
cleanup() {
    local e
    for e in "${REAP_ENTRIES[@]}"; do
        fixture_group_reap "${e%%$'\t'*}" "${e#*$'\t'}"
    done
    [[ -n "$WORK" ]] && rm -rf "$WORK"
}
trap cleanup EXIT

# Build an isolated launcher fixture root. Sets ROOT, MON, WD, STATE,
# LAUNCHER, PIDFILE, BIN. The stub main.sh mirrors the real contract —
# publish pidfile, fork a subshell CHAIN (the decapitation substrate),
# then idle; argv stays `bash .../monitor/watcher/main.sh` for the
# identity checks.
build_root() {
    ROOT="$WORK/nexus"
    MON="$ROOT/monitor"
    WD="$MON/watcher"
    STATE="$MON/.state"
    BIN="$WORK/bin"
    mkdir -p "$WD" "$STATE" "$ROOT/config" "$BIN"
    cp "$_real_dir/launcher.sh"       "$WD/launcher.sh"
    cp "$_real_dir/_lib.sh"           "$WD/_lib.sh"
    cp "$_real_dir/_respawn_async.sh" "$WD/_respawn_async.sh"
    chmod +x "$WD/launcher.sh"
    LAUNCHER="$WD/launcher.sh"
    PIDFILE="$STATE/watcher.pid"
    cat > "$WD/main.sh" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$STATE/watcher.pid"
# Forked subshell chain, like the real scheduler's async fires — the
# decapitation substrate: these survive a leader-only kill.
( ( while sleep 1; do :; done ) & wait ) &
sleep 300
EOF
    chmod +x "$WD/main.sh"
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
    # Pre-provision the local-claude marker path so the launcher skips
    # its installer branch.
    mkdir -p "$ROOT/node_modules/.bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT/node_modules/.bin/claude"
    chmod +x "$ROOT/node_modules/.bin/claude"
}

run_launcher() { # args...
    PATH="$BIN:$PATH" "$LAUNCHER" "$@" >"$WORK/out" 2>"$WORK/err"
    RC=$?
}

live_groups() { # -> lines pgid\tleader\tn
    ( source "$WD/_lib.sh"; _watcher_list_live_groups "$ROOT" )
}

# shellcheck source=_lib.sh
source "$_real_dir/_lib.sh"

# === Case A: decapitation is reproduced, then fully reaped ==============
echo '=== case A: leader-killed orphan chain is reaped, spawn leaves ONE group (fails on dev) ==='
WORK=$(mktemp -d -t nexus-singleton-A-XXXXXX)
build_root
setsid bash "$WD/main.sh" </dev/null >/dev/null 2>&1 &
LEADER=$!
reap_later "$LEADER" "$WORK"
sleep 1
# Decapitate: kill ONLY the leader (models the observed leader death).
kill -KILL "$LEADER" 2>/dev/null
sleep 0.5
if _watcher_group_alive "$LEADER"; then
    PASS=$((PASS+1)); echo "ok:   A: orphan chain survives the leader (the bug, reproduced: group $LEADER still alive)"
else
    FAIL=$((FAIL+1)); echo "FAIL: A: fixture did not reproduce decapitation" >&2
fi
groups_before=$(live_groups)
assert_contains "A: scan sees the decapitated group (leader=dead)" "$groups_before" "dead"

run_launcher --replace
assert_eq "A: launcher --replace succeeds" "$RC" "0"
if _watcher_group_alive "$LEADER"; then
    FAIL=$((FAIL+1)); echo "FAIL: A: decapitated group $LEADER still has members after --replace (dev behaviour: spawned next to the orphans)" >&2
else
    PASS=$((PASS+1)); echo "ok:   A: decapitated group fully reaped — ZERO surviving members"
fi
groups_after=$(live_groups)
n_after=$(grep -c . <<<"$groups_after" || true)
assert_eq "A: exactly one live watcher group after recovery" "$n_after" "1"
assert_contains "A: the surviving group's leader is live" "$groups_after" "live"
assert_contains "A: the reap was attributed in the spawn audit log" \
    "$(cat "$STATE/watcher-spawns.log" 2>/dev/null)" "reap-decapitated"
new_leader=$(cat "$PIDFILE" 2>/dev/null || true)
[[ "$new_leader" =~ ^[0-9]+$ ]] && { reap_later "$new_leader" "$WORK"; fixture_group_reap "$new_leader" "$WORK"; }
rm -rf "$WORK"; WORK=''

# === Case B: two concurrent --replace launchers -> exactly one group ====
echo '=== case B: concurrent revives converge to exactly one watcher group ==='
WORK=$(mktemp -d -t nexus-singleton-B-XXXXXX)
build_root
PATH="$BIN:$PATH" "$LAUNCHER" --replace >"$WORK/out1" 2>"$WORK/err1" &
L1=$!
PATH="$BIN:$PATH" "$LAUNCHER" --replace >"$WORK/out2" 2>"$WORK/err2" &
L2=$!
wait "$L1"; rc1=$?
wait "$L2"; rc2=$?
sleep 0.5
groups=$(live_groups)
n=$(grep -c . <<<"$groups" || true)
assert_eq "B: exactly one live watcher group after racing replaces" "$n" "1"
if (( rc1 == 0 || rc2 == 0 )); then
    PASS=$((PASS+1)); echo "ok:   B: at least one launcher reported success (rc1=$rc1 rc2=$rc2)"
else
    FAIL=$((FAIL+1)); echo "FAIL: B: both racing launchers failed (rc1=$rc1 rc2=$rc2)" >&2
fi
b_leader=$(awk -F'\t' 'NR==1{print $1}' <<<"$groups")
[[ "$b_leader" =~ ^[0-9]+$ ]] && { reap_later "$b_leader" "$WORK"; fixture_group_reap "$b_leader" "$WORK"; }
rm -rf "$WORK"; WORK=''

# === Case C: svc.sh status reports duplicates and exits non-zero ========
echo '=== case C: duplicate watcher groups -> svc.sh status DUP row + exit 6 (fails on dev) ==='
WORK=$(mktemp -d -t nexus-singleton-C-XXXXXX)
build_root
# svc.sh needs the full sourcing chain; give it the real files.
cp "$_real_dir/../svc.sh"               "$MON/svc.sh"
cp "$_real_dir/../bootstrap-recover.sh" "$MON/bootstrap-recover.sh"
cp "$_real_dir/../boot-recover.sh"      "$MON/boot-recover.sh" 2>/dev/null || true
chmod +x "$MON/svc.sh" "$MON/bootstrap-recover.sh"
# Two live leaders (duplicate state, as observed 17:13-17:15).
setsid bash "$WD/main.sh" </dev/null >/dev/null 2>&1 & W1=$!
sleep 0.3
setsid bash "$WD/main.sh" </dev/null >/dev/null 2>&1 & W2=$!
sleep 0.5
reap_later "$W1" "$WORK"; reap_later "$W2" "$WORK"
printf 'pid=%s\nts=x\ntarget=orchestrator\n' "$W1" > "$STATE/watcher-heartbeat"
status_out=$(PATH="$BIN:$PATH" NEXUS_ROOT="$ROOT" bash "$MON/svc.sh" status 2>&1); status_rc=$?
assert_contains "C: status reports the duplicate (DUP row)" "$status_out" "DUP"
assert_contains "C: status names both pgids" "$status_out" "$W2"
assert_eq "C: status exits non-zero (6) on a duplicate" "$status_rc" "6"
fixture_group_reap "$W1" "$WORK"; fixture_group_reap "$W2" "$WORK"
sleep 0.3
status_out=$(PATH="$BIN:$PATH" NEXUS_ROOT="$ROOT" bash "$MON/svc.sh" status 2>&1); status_rc=$?
assert_eq "C: status exits 0 once the duplicate is gone" "$status_rc" "0"
assert_not_contains "C: no DUP row for a single (dead) watcher" "$status_out" "watcher-dup"
rm -rf "$WORK"; WORK=''

# === Case D: instance-lock fd is not inherited across the fork chokepoint ===
echo '=== case D: scheduler async children do not inherit the lock fd ==='
WORK=$(mktemp -d -t nexus-singleton-D-XXXXXX)
mkdir -p "$WORK/stage"
LOCKF="$WORK/instance.lock"
fd_probe_out="$WORK/child-fds"
(
    set -u
    # Model main.sh: hold an flock on a dynamic fd, register the
    # chokepoint hook, fire an async task, and have the CHILD list its
    # own open fds. _close_inherited_locks is the PRODUCTION function
    # sourced from _lib.sh — never a fixture re-definition, so
    # neutering the shipped function fails this case (skeptic M4 on
    # PR#503: a test that redefines the symbol it asserts cannot fail
    # for the reason it advertises).
    source "$_real_dir/_scheduler.sh"
    source "$_real_dir/_lib.sh"
    declare -F _close_inherited_locks >/dev/null || exit 92
    exec {INSTANCE_LOCK_FD}<>"$LOCKF"
    flock -n "$INSTANCE_LOCK_FD" || exit 90
    _scheduler_subshell_init() { _close_inherited_locks; }
    _task_list_fds() { ls /proc/self/fd; }
    MONITOR_SCHEDULER_STAGE_DIR="$WORK/stage"
    _schedule_task fdprobe 60 _task_list_fds --async
    _scheduler_fire_async fdprobe
    for _ in $(seq 1 50); do [[ -f "$WORK/stage/fdprobe.rc" ]] && break; sleep 0.1; done
    cp "$WORK/stage/fdprobe.out" "$fd_probe_out" 2>/dev/null || true
    # Parent must STILL hold the lock: a second flock attempt fails.
    if ( exec {probe}<>"$LOCKF"; flock -n "$probe" ); then
        exit 91   # lock was NOT held anymore — hygiene broke the lock itself
    fi
    echo "$INSTANCE_LOCK_FD" > "$WORK/parent-fd"
    exit 0
)
d_rc=$?
assert_eq "D: fixture harness ran clean (lock held throughout)" "$d_rc" "0"
parent_fd=$(cat "$WORK/parent-fd" 2>/dev/null || echo '?')
child_fds=$(cat "$fd_probe_out" 2>/dev/null || echo '')
assert_not_contains "D: child fd table lacks the lock fd ($parent_fd)" \
    "$(printf '%s\n' "$child_fds" | grep -x "$parent_fd" || true)" "$parent_fd"
if [[ -n "$child_fds" ]]; then
    PASS=$((PASS+1)); echo "ok:   D: child fd probe produced output (fds: $(tr '\n' ' ' <<<"$child_fds"))"
else
    FAIL=$((FAIL+1)); echo "FAIL: D: child fd probe produced no output" >&2
fi
rm -rf "$WORK"; WORK=''

# === Case F: fixture isolation — the detector must NOT trip on the test suite ===
# Faux watchers under OTHER roots (exactly the /tmp fixture shape the
# launcher/svc suites spawn, argv suffix `monitor/watcher/main.sh`)
# must be invisible to this root's scan and to svc.sh status: a
# duplicate detector that goes red whenever anyone runs the test
# suite is worse than none (operator constraint, 2026-07-09: two
# false firings in twenty minutes, both fixture-matched). The match
# is absolute-path EQUALITY against $NEXUS_ROOT, never a suffix.
echo '=== case F: foreign-root fixtures do not count as watchers here ==='
WORK=$(mktemp -d -t nexus-singleton-F-XXXXXX)
build_root
cp "$_real_dir/../svc.sh"               "$MON/svc.sh"
cp "$_real_dir/../bootstrap-recover.sh" "$MON/bootstrap-recover.sh"
chmod +x "$MON/svc.sh" "$MON/bootstrap-recover.sh"
# One REAL watcher for this root...
setsid bash "$WD/main.sh" </dev/null >/dev/null 2>&1 & REAL=$!
sleep 0.3
reap_later "$REAL" "$WORK"
printf 'pid=%s\nts=x\ntarget=orchestrator\n' "$REAL" > "$STATE/watcher-heartbeat"
# ...and two foreign-root fixtures with the exact suffix shape the
# test suites use (one styled like the svc suite, one like fs-guard's).
FOREIGN1="$WORK/faux/monitor/watcher"
FOREIGN2="$WORK/other/monitor/watcher"
mkdir -p "$FOREIGN1" "$FOREIGN2"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$FOREIGN1/main.sh"; chmod +x "$FOREIGN1/main.sh"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$FOREIGN2/main.sh"; chmod +x "$FOREIGN2/main.sh"
setsid bash "$FOREIGN1/main.sh" </dev/null >/dev/null 2>&1 & F1=$!
setsid bash "$FOREIGN2/main.sh" --target orchestrator </dev/null >/dev/null 2>&1 & F2=$!
sleep 0.5
reap_later "$F1" "$WORK"; reap_later "$F2" "$WORK"
groups=$(live_groups); n=$(grep -c . <<<"$groups" || true)
assert_eq "F: scan pinned to this root sees exactly one group" "$n" "1"
assert_contains "F: and it is the real one" "$groups" "$REAL"
status_out=$(PATH="$BIN:$PATH" NEXUS_ROOT="$ROOT" bash "$MON/svc.sh" status 2>&1); status_rc=$?
assert_eq "F: svc.sh status exits 0 with fixtures running elsewhere" "$status_rc" "0"
assert_not_contains "F: no DUP row from foreign-root fixtures" "$status_out" "watcher-dup"
fixture_group_reap "$REAL" "$WORK"; fixture_group_reap "$F1" "$WORK"; fixture_group_reap "$F2" "$WORK"
rm -rf "$WORK"; WORK=''

# === Case G: recycled pid — an INNOCENT group must SURVIVE the stale-pidfile path ===
# The skeptic's blocking finding on PR#503: a stale watcher.pid whose
# pid has been recycled to an unrelated setsid leader (a worker pane, a
# registry service, another agent's job) must NOT get its group killed.
# Identity before signal: the reap refuses any group with no
# argv-verified watcher member for this root. Direction pair: case A
# proves a REAL decapitated watcher group still dies.
echo '=== case G: recycled stale pidfile -> innocent setsid group survives (skeptic repro) ==='
WORK=$(mktemp -d -t nexus-singleton-G-XXXXXX)
build_root
# The innocent victim: a setsid group with NO watcher argv anywhere.
setsid bash -c 'exec sleep 120' </dev/null >/dev/null 2>&1 & VICTIM=$!
sleep 0.3
reap_later "$VICTIM" "sleep 120"   # cleanup key: matches the victim argv only
# Stale pidfile naming the victim: the recorded watcher died, the pid
# was recycled to the victim (modeled directly).
echo "$VICTIM" > "$PIDFILE"
run_launcher --replace
assert_eq "G: launcher --replace still succeeds (spawns a fresh watcher)" "$RC" "0"
if kill -0 "$VICTIM" 2>/dev/null; then
    PASS=$((PASS+1)); echo "ok:   G: innocent group $VICTIM SURVIVED the stale-pidfile path"
else
    FAIL=$((FAIL+1)); echo "FAIL: G: innocent group $VICTIM was KILLED (the skeptic's sk-recycle defect)" >&2
fi
assert_contains "G: the refusal was attributed in the spawn audit log" \
    "$(cat "$STATE/watcher-spawns.log" 2>/dev/null)" "refuse-unverified-group"
g_leader=$(cat "$PIDFILE" 2>/dev/null || true)
[[ "$g_leader" =~ ^[0-9]+$ ]] && { reap_later "$g_leader" "$WORK"; fixture_group_reap "$g_leader" "$WORK"; }
kill -KILL "$VICTIM" 2>/dev/null || true
rm -rf "$WORK"; WORK=''

# === Case E: restart lock fails closed =================================
echo '=== case E: restart-lock contention refuses (exit 5), never proceeds ==='
WORK=$(mktemp -d -t nexus-singleton-E-XXXXXX)
build_root
RESTART_LOCK="$STATE/watcher-restart.lock"
# Hold the restart lock from a fixture process for a few seconds.
(
    exec {hold}<>"$RESTART_LOCK"
    flock "$hold"
    sleep 6
) &
HOLDER=$!
sleep 0.5
WATCHER_RESTART_LOCK_WAIT=1 run_launcher --replace
assert_eq "E: launcher refuses on lock timeout (exit 5, fail closed)" "$RC" "5"
assert_contains "E: refusal names the in-flight restart" "$(cat "$WORK/err")" "single-flight restart lock"
groups=$(live_groups); n=$(grep -c . <<<"$groups" || true)
assert_eq "E: no watcher was spawned while the lock was held" "$n" "0"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

th_summary_and_exit
