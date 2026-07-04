#!/usr/bin/env bash
# State-dir-scoped singleton guard tests (issue: multi-instance-guard).
#
# Two agent-sandbox cockpits pointed at the same NEXUS_ROOT share one
# monitor/.state/ (rw bind mount) but run under `bwrap --unshare-pid`,
# so each has its OWN pid namespace + /proc. Every pid-based guard we
# already have (_watcher_pid_is_live_watcher, acquire_lock, the launcher
# pidfile check) reads a live PEER watcher as dead across that boundary
# and would clobber the shared state — double GitHub writes, emit races.
#
# The fix is an flock keyed on the inode (not a pid): it crosses the
# pid-namespace boundary on one host, and — on the NFSv3 state mount
# with local_lock=none — the host boundary too, via the server's NLM.
# These tests pin the primitive (_nexus_instance_lock_live) and the two
# refusal surfaces (launcher fast-fail probe; the held lock's
# mutual-exclusion). We cannot spin a real second sandbox in a unit
# test, but a plain background `flock` holder models the peer exactly:
# the kernel arbitrates the lock the same way regardless of which pid
# namespace the contender lives in.
#
# Cases:
#   1.  helper: absent lock file        → free (rc 1), no file littered
#   2.  helper: live flock holder        → held (rc 0) + metadata echoed
#   3.  helper: two acquirers contend    → second flock -n refuses
#   4.  helper: holder dies              → lock auto-released → free (succession)
#   5.  launcher: free lock              → spawns (rc 0, pidfile published)
#   6.  launcher: live holder            → REFUSES (rc 4), metadata-rich msg
#   7.  launcher: holder released first  → spawns (rc 0) — succession unaffected
#   8.  helper: field parser            → colon-bearing values survive
#   9.  helper: assess                  → live-local / stale-reboot / live-remote / unknown
#   10. helper: refusal message         → situation-aware + actionable (normal + false-positive)
#   11. helper: stale text, no holder   → free (auto-reclaim, no stale class)
#   12. launcher: --instance-status held → reports holder + assessment, no spawn
#   13. launcher: --instance-status free → reports free, no spawn
#   14. launcher: false-positive `rm`   → stale lock cleared → spawns (rc 0)
#
# operator asked on PR #281: "could flocks also be stale?" The honest
# answer the assess/refusal helpers encode: a same-host flock is never
# stale (kernel releases on death); the only stale class is a CROSS-HOST
# NFS lock whose holding client died without the server's lock manager
# reclaiming it, or a same-host lock whose machine REBOOTED since (boot
# id changed). Cases 9–10 pin that classification + the resolve guidance.
#
# Hermetic: own tmpdir, stub tmux/config/main.sh/claude. Shares nothing
# with the real monitor/.state/, so the running watcher is untouched.
#
# Run: bash monitor/watcher/test-instance-lock.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_real_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }
pass() { echo "ok:   $*"; PASS=$(( PASS + 1 )); }

# shellcheck source=_test_helpers.sh
. "$_real_test_dir/_test_helpers.sh"
# shellcheck source=_lib.sh
. "$_real_test_dir/_lib.sh"

# Hold an exclusive flock on <lockfile> in the background until its
# sentinel <relfile> is removed, then exit (releasing the lock). Writes
# a metadata line so the probe has something to echo. Sets HOLDER_PID.
# Models a live peer watcher holding the instance lock.
start_holder() {
    local lockfile="$1" release_sentinel="$2"
    (
        exec {fd}<>"$lockfile" || exit 1
        flock -n "$fd" || exit 1
        printf 'pid: %s\nhost: peerhost\nsandbox: /peer/root\n' "$BASHPID" >&"$fd"
        # Hold until told to release.
        while [[ -e "$release_sentinel" ]]; do sleep 0.1; done
    ) &
    HOLDER_PID=$!
    sleep 0.4   # let the kernel commit the lock
}

# --- helper unit tests --------------------------------------------------

echo '=== case 1: helper — absent lock file → free, no file created ==='
T1=$(mktemp -d -t nexus-instlock-1-XXXXXX)
L1="$T1/nexus-instance.lock"
if _nexus_instance_lock_live "$L1"; then
    fail "reported held for an absent lock file"
else
    pass "absent lock file reads as free (rc 1)"
fi
if [[ -e "$L1" ]]; then
    fail "probe littered a lock file where none existed"
else
    pass "probe did not create the lock file"
fi
rm -rf "$T1"

echo '=== case 2: helper — live holder → held (rc 0) + metadata echoed ==='
T2=$(mktemp -d -t nexus-instlock-2-XXXXXX)
L2="$T2/nexus-instance.lock"
SENT2="$T2/hold"
: > "$SENT2"
start_holder "$L2" "$SENT2"
OUT2=$(_nexus_instance_lock_live "$L2"); RC2=$?
if (( RC2 == 0 )); then
    pass "live holder reads as held (rc 0)"
else
    fail "live holder NOT detected (rc $RC2)"
fi
if grep -q "peerhost" <<<"$OUT2"; then
    pass "holder metadata echoed for the refusal message"
else
    fail "holder metadata not echoed: [$OUT2]"
fi
rm -f "$SENT2"; wait "$HOLDER_PID" 2>/dev/null || true
rm -rf "$T2"

echo '=== case 3: helper — two acquirers contend → second refuses ==='
T3=$(mktemp -d -t nexus-instlock-3-XXXXXX)
L3="$T3/nexus-instance.lock"
SENT3="$T3/hold"
: > "$SENT3"
start_holder "$L3" "$SENT3"
# A genuine second exclusive acquire (what a real peer main.sh attempts)
# must fail while the holder is alive.
if ( exec {fd}<>"$L3"; flock -n "$fd" ); then
    fail "second exclusive acquire succeeded while holder alive (LEAK)"
else
    pass "second exclusive acquire refused while holder alive"
fi
rm -f "$SENT3"; wait "$HOLDER_PID" 2>/dev/null || true
rm -rf "$T3"

echo '=== case 4: helper — holder dies → auto-released → free (succession) ==='
T4=$(mktemp -d -t nexus-instlock-4-XXXXXX)
L4="$T4/nexus-instance.lock"
SENT4="$T4/hold"
: > "$SENT4"
start_holder "$L4" "$SENT4"
rm -f "$SENT4"; wait "$HOLDER_PID" 2>/dev/null || true
# Kernel releases the flock when the holder's fds close on exit — even
# on SIGKILL — so no stale-lock reclaim logic is needed.
if _nexus_instance_lock_live "$L4"; then
    fail "lock still read as held after holder exited (stale-lock leak)"
else
    pass "lock auto-released on holder death → free (succession path open)"
fi
rm -rf "$T4"

# --- launcher integration -----------------------------------------------
#
# Mirror test-launcher-replace.sh's synthetic layout so launcher.sh's
# BASH_SOURCE-relative resolution lands inside an isolated tree.

REAL_LAUNCHER="$_real_test_dir/launcher.sh"

build_launcher_case() {
    local label="$1"
    WORK=$(mktemp -d -t "nexus-instlock-launch-${label}-XXXXXX")
    mkdir -p "$WORK/monitor/watcher" "$WORK/monitor/.state" "$WORK/bin" \
             "$WORK/config" "$WORK/node_modules/.bin"
    cp "$REAL_LAUNCHER" "$WORK/monitor/watcher/launcher.sh"
    cp "$_real_test_dir/_lib.sh" "$WORK/monitor/watcher/_lib.sh"
    cp "$_real_test_dir/_respawn_async.sh" "$WORK/monitor/watcher/_respawn_async.sh"
    chmod +x "$WORK/monitor/watcher/launcher.sh"
    LAUNCHER="$WORK/monitor/watcher/launcher.sh"
    PIDFILE="$WORK/monitor/.state/watcher.pid"
    INSTLOCK="$WORK/monitor/.state/nexus-instance.lock"
    BIN="$WORK/bin"

    # Stub main.sh: publish pid then idle. No exec — argv must stay
    # `bash .../monitor/watcher/main.sh` for the launcher's identity
    # check + spawn-verify poll.
    cat > "$WORK/monitor/watcher/main.sh" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$WORK/monitor/.state/watcher.pid"
sleep 60
EOF
    chmod +x "$WORK/monitor/watcher/main.sh"

    # Pre-stage a local claude so launcher skips the install block.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/node_modules/.bin/claude"
    chmod +x "$WORK/node_modules/.bin/claude"

    printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/tmux"
    chmod +x "$BIN/tmux"
    printf '#!/usr/bin/env bash\necho "${2:-}"\n' > "$WORK/config/load.sh"
    chmod +x "$WORK/config/load.sh"
}

cleanup_launcher_case() {
    local _p=''
    [[ -f "$PIDFILE" ]] && read -r _p < "$PIDFILE" 2>/dev/null
    [[ "$_p" =~ ^[0-9]+$ ]] && th_kill_fixture_pid "$_p" "$WORK"
    rm -rf "$WORK"
    unset WORK LAUNCHER PIDFILE INSTLOCK BIN
}

run_launcher() {
    PATH="$BIN:$PATH" "$LAUNCHER" "$@" >"$WORK/out" 2>"$WORK/err"
    RC=$?
}

echo '=== case 5: launcher — free lock → spawns (rc 0) ==='
build_launcher_case 5
run_launcher
if (( RC == 0 )); then
    pass "launcher spawned with a free instance lock (rc 0)"
else
    fail "launcher rc=$RC with a free lock; stderr: $(cat "$WORK/err")"
fi
_p5=''; [[ -f "$PIDFILE" ]] && read -r _p5 < "$PIDFILE" 2>/dev/null
if [[ "$_p5" =~ ^[0-9]+$ ]] && kill -0 "$_p5" 2>/dev/null; then
    pass "fresh headless watcher published a live pidfile"
else
    fail "no live pidfile after spawn (content: ${_p5:-absent})"
fi
cleanup_launcher_case

echo '=== case 6: launcher — live holder → REFUSES (rc 4), no spawn ==='
build_launcher_case 6
SENT6="$WORK/hold"; : > "$SENT6"
start_holder "$INSTLOCK" "$SENT6"
run_launcher
if (( RC == 4 )); then
    pass "launcher refused with rc 4 against a live instance-lock holder"
else
    fail "launcher rc=$RC (expected 4); stderr: $(cat "$WORK/err")"
fi
if grep -q "REFUSING to spawn" "$WORK/err"; then
    pass "launcher emitted the actionable refusal message"
else
    fail "no refusal message; stderr: $(cat "$WORK/err")"
fi
if grep -q "DIFFERENT NEXUS_ROOT" "$WORK/err"; then
    pass "refusal points at the supported one-root-per-cockpit topology"
else
    fail "refusal lacked the topology guidance; stderr: $(cat "$WORK/err")"
fi
# Crucial: it must NOT have spawned a second watcher.
if [[ -f "$PIDFILE" ]]; then
    fail "launcher spawned a watcher despite a live holder (pidfile present)"
else
    pass "launcher did not spawn a second watcher"
fi
rm -f "$SENT6"; wait "$HOLDER_PID" 2>/dev/null || true
cleanup_launcher_case

echo '=== case 7: launcher — holder released first → spawns (succession) ==='
build_launcher_case 7
SENT7="$WORK/hold"; : > "$SENT7"
start_holder "$INSTLOCK" "$SENT7"
# Release the peer BEFORE launching — models the blessed succession
# where the prior watcher is terminated before the successor starts.
rm -f "$SENT7"; wait "$HOLDER_PID" 2>/dev/null || true
run_launcher
if (( RC == 0 )); then
    pass "launcher spawned once the prior holder released (succession)"
else
    fail "launcher rc=$RC after holder released; stderr: $(cat "$WORK/err")"
fi
cleanup_launcher_case

# --- stale-lock reasoning helpers (operator's PR #281 question) ------------

echo '=== case 8: helper — field parser survives colon-bearing values ==='
META8=$'pid: 4242\nhost: nodeA\nboot_id: abc-123\npid_ns: pid:[4026531836]\nstarted_at: 2026-06-15T17:33:30-07:00\ntmux: /tmp/tmux-1000/default,3,0\n'
if [[ "$(_nexus_instance_lock_field "$META8" pid_ns)" == "pid:[4026531836]" ]]; then
    pass "pid_ns value (contains a colon) parsed whole"
else
    fail "pid_ns mis-parsed: [$(_nexus_instance_lock_field "$META8" pid_ns)]"
fi
if [[ "$(_nexus_instance_lock_field "$META8" started_at)" == "2026-06-15T17:33:30-07:00" ]]; then
    pass "ISO started_at (contains colons) parsed whole"
else
    fail "started_at mis-parsed: [$(_nexus_instance_lock_field "$META8" started_at)]"
fi
if [[ "$(_nexus_instance_lock_field "$META8" tmux)" == "/tmp/tmux-1000/default,3,0" ]]; then
    pass "tmux socket value parsed whole"
else
    fail "tmux mis-parsed: [$(_nexus_instance_lock_field "$META8" tmux)]"
fi

echo '=== case 9: helper — assess classifies the four stale-vs-live cases ==='
SAMEHOST=$'host: nodeA\nboot_id: boot-1\n'
if [[ "$(_nexus_instance_lock_assess "$SAMEHOST" nodeA boot-1)" == "live-local" ]]; then
    pass "same host + same boot id → live-local (genuine live peer, never stale)"
else
    fail "expected live-local, got [$(_nexus_instance_lock_assess "$SAMEHOST" nodeA boot-1)]"
fi
if [[ "$(_nexus_instance_lock_assess "$SAMEHOST" nodeA boot-2)" == "stale-reboot" ]]; then
    pass "same host + DIFFERENT boot id → stale-reboot (machine rebooted; holder dead)"
else
    fail "expected stale-reboot, got [$(_nexus_instance_lock_assess "$SAMEHOST" nodeA boot-2)]"
fi
if [[ "$(_nexus_instance_lock_assess "$SAMEHOST" nodeB boot-9)" == "live-remote" ]]; then
    pass "different host → live-remote (live if that host is up, else maybe stale)"
else
    fail "expected live-remote, got [$(_nexus_instance_lock_assess "$SAMEHOST" nodeB boot-9)]"
fi
NOHOST=$'pid: 5\n'
if [[ "$(_nexus_instance_lock_assess "$NOHOST" nodeA boot-1)" == "unknown" ]]; then
    pass "metadata without host → unknown (older lock; treat as live)"
else
    fail "expected unknown, got [$(_nexus_instance_lock_assess "$NOHOST" nodeA boot-1)]"
fi

echo '=== case 10: helper — refusal message is situation-aware + actionable ==='
RMETA=$'host: farhost\nboot_id: zzz\npid: 9001\nsandbox: /peer/root\nstarted_at: 2026-06-15T01:02:03Z\ntmux: none\n'
MSG=$(_nexus_instance_lock_refusal "$RMETA" /tmp/x.lock /some/root)
check_msg() { if grep -q "$1" <<<"$MSG"; then pass "refusal: $2"; else fail "refusal missing $2: [$MSG]"; fi; }
check_msg "Suspected holder"           "states the suspected situation from metadata"
check_msg "farhost"                    "surfaces the recorded host so the user can find the peer"
check_msg "Normal resolution"          "gives the use/close/--replace normal path"
check_msg "DIFFERENT NEXUS_ROOT"       "offers the different-NEXUS_ROOT escape"
check_msg "False-positive resolution"  "gives the stale-lock false-positive path"
check_msg "rm /tmp/x.lock"             "names the exact clear-stale command + path"
check_msg "only rm when you are SURE"  "warns rm is unsafe while a live peer exists"
check_msg "is actually down"           "remote case tells the user to verify the host is down"

echo '=== case 11: helper — stale text, no live holder → free (auto-reclaim) ==='
T11=$(mktemp -d -t nexus-instlock-11-XXXXXX)
L11="$T11/nexus-instance.lock"
printf 'pid: 99999\nhost: deadhost\nboot_id: gone\n' > "$L11"   # text, but nobody holds the flock
if _nexus_instance_lock_live "$L11"; then
    fail "lockfile with stale text but no live holder read as HELD (false stale class)"
else
    pass "stale-text lockfile with no live holder reads free → next start reclaims"
fi
rm -rf "$T11"

# --- launcher --instance-status + false-positive removal ----------------

echo '=== case 12: launcher --instance-status — live holder reported, no spawn ==='
build_launcher_case 12
SENT12="$WORK/hold"; : > "$SENT12"
start_holder "$INSTLOCK" "$SENT12"
PATH="$BIN:$PATH" "$LAUNCHER" --instance-status >"$WORK/out" 2>"$WORK/err"; RC=$?
if (( RC == 0 )) && grep -q "instance-lock: HELD" "$WORK/out"; then
    pass "--instance-status reports HELD for a live holder (rc 0)"
else
    fail "--instance-status rc=$RC out: $(cat "$WORK/out")"
fi
if grep -q "assessment=" "$WORK/out" && grep -q "peerhost" "$WORK/out"; then
    pass "--instance-status prints the assessment + holder metadata"
else
    fail "--instance-status missing assessment/metadata: $(cat "$WORK/out")"
fi
if [[ ! -f "$PIDFILE" ]]; then
    pass "--instance-status did not spawn a watcher"
else
    fail "--instance-status spawned a watcher (pidfile present)"
fi
rm -f "$SENT12"; wait "$HOLDER_PID" 2>/dev/null || true
cleanup_launcher_case

echo '=== case 13: launcher --instance-status — free reported, no spawn ==='
build_launcher_case 13
PATH="$BIN:$PATH" "$LAUNCHER" --instance-status >"$WORK/out" 2>"$WORK/err"; RC=$?
if (( RC == 0 )) && grep -q "instance-lock: free\|instance-lock: absent" "$WORK/out"; then
    pass "--instance-status reports free/absent with no holder (rc 0)"
else
    fail "--instance-status rc=$RC out: $(cat "$WORK/out")"
fi
if [[ ! -f "$PIDFILE" ]]; then
    pass "--instance-status (free) did not spawn a watcher"
else
    fail "--instance-status (free) spawned a watcher"
fi
cleanup_launcher_case

echo '=== case 14: launcher — false-positive rm of a stale lock → spawns ==='
build_launcher_case 14
SENT14="$WORK/hold"; : > "$SENT14"
start_holder "$INSTLOCK" "$SENT14"
# Model the false positive: the holder is actually gone, but its lock
# FILE persists. The operator confirms (via --instance-status) that no
# live peer owns it, then runs the documented clear-stale command.
rm -f "$SENT14"; wait "$HOLDER_PID" 2>/dev/null || true
[[ -e "$INSTLOCK" ]] && pass "stale lock file persists after holder exit (the false-positive shape)" \
                      || fail "lock file vanished on holder exit (test premise broken)"
rm -f "$INSTLOCK"   # the documented clear-stale command
run_launcher
if (( RC == 0 )); then
    pass "launcher spawned after the stale lock was rm'd (false-positive path)"
else
    fail "launcher rc=$RC after clearing the stale lock; stderr: $(cat "$WORK/err")"
fi
cleanup_launcher_case

# --- enriched case 6 assertions (metadata-rich refusal) -----------------

echo '=== case 6b: launcher live-holder refusal carries the rich metadata block ==='
build_launcher_case 6b
SENT6B="$WORK/hold"; : > "$SENT6B"
start_holder "$INSTLOCK" "$SENT6B"
run_launcher
if grep -q "Suspected holder" "$WORK/err" && grep -q "peerhost" "$WORK/err"; then
    pass "refusal names the suspected holder + its recorded host"
else
    fail "refusal lacked holder metadata; stderr: $(cat "$WORK/err")"
fi
if grep -q "False-positive resolution" "$WORK/err" && grep -q "only rm when you are SURE" "$WORK/err"; then
    pass "refusal includes the false-positive (clear-stale) path + caveat"
else
    fail "refusal lacked the false-positive guidance; stderr: $(cat "$WORK/err")"
fi
rm -f "$SENT6B"; wait "$HOLDER_PID" 2>/dev/null || true
cleanup_launcher_case

# --- summary ------------------------------------------------------------

echo
echo "passed=$PASS failed=$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
else
    exit 1
fi
