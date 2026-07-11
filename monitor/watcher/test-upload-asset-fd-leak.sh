#!/usr/bin/env bash
# Tests for the upload-asset flock FD-inheritance leak (your-org/nexus-code#468).
#
# The bug: monitor/upload-asset.sh elects a batch manager by taking an
# exclusive flock on a numbered fd (`exec 9>assets.lock` / `flock 9`).
# flock(2) attaches to the OPEN FILE DESCRIPTION, not to the process, and
# numbered fds >= 3 are inherited across fork+exec unless FD_CLOEXEC is set —
# which bash does not set. `git push` authenticates, which forks
# `git-credential-cache--daemon`; the daemon inherits the lock fd, setsid()s,
# reparents to init, and holds the GLOBAL asset lock for its whole lifetime
# (default 900s, refreshed by every subsequent credential use → effectively
# forever on a busy nexus).
#
# Observed: the lock held >= 2h37m by a daemon whose parent had long exited.
# Every `ng wrap-up` in that window blocked 180s and bailed, silently skipping
# its asset upload and link comment. The diagnostic trap: the two pids one
# would naturally blame (the upload-asset.sh manager and its git) were ALREADY
# DEAD. There was no hung holder — only a leaked descriptor.
#
# A secondary defect compounded it: the installation token expired mid-batch,
# so `git push` fell through to an interactive credential prompt with no stdin
# and blocked at 0% CPU *while holding the lock*.
#
# The fix routes every git invocation through `_git_hardened`, which applies
# three independent guards:
#   1. `-c credential.helper=`   → no credential daemon is ever forked, and no
#                                  EXPIRED token is cached and re-served.
#   2. `GIT_TERMINAL_PROMPT=0`   → an expired token fails LOUD and immediately
#                                  instead of blocking forever on a prompt.
#   3. `{_LOCK_FD}>&-`          → the lock fd is closed in the child, so no
#                                  descendant can inherit it. bash 4.x cannot
#                                  mark an already-exec'd fd O_CLOEXEC, so
#                                  close-at-spawn is the mechanism (same as the
#                                  #451 instance-lock fix).
#
# This suite drives the REAL `_git_assets`, extracted verbatim from the script
# under test, against a fake `git` on PATH that forks a detached "credential
# daemon" exactly as the real one does. No network, no GitHub, no tokens.
# `_git_assets` is chosen because it exists in BOTH the pre-fix and post-fix
# source, so the same suite runs against either -- pre-fix it expands to a bare
# `git`, post-fix it delegates to `_git_hardened`. That is what makes the
# both-directions verification meaningful rather than a "symbol missing" abort.
#
# Assertions (each falsifiable, and each with its pre-fix counterpart):
#   A  After the manager subshell exits, the lock is FREE even though the
#      daemon it spawned is still alive.  [the issue's headline assertion]
#   B  LEAK DEMO — the same daemon spawned WITHOUT the fd close inherits the
#      lock fd and the lock is STILL HELD after the manager exits. This is the
#      pre-fix behaviour, and it proves A is load-bearing rather than a
#      property the daemon would have had anyway.
#   C  No descendant of the manager holds any fd on the lock file (checked
#      directly via /proc/<pid>/fd, not inferred from flock).
#   D  An expired/garbage token produces a NON-ZERO exit within seconds.
#   E  LEAK DEMO — without GIT_TERMINAL_PROMPT=0 the same git invocation HANGS
#      (bounded here by `timeout`), proving D is load-bearing.
#   F  Contract: every git invocation in upload-asset.sh routes through the
#      hardened helper, and the helper carries all three guards. This is the
#      "prevents a third occurrence" guard — #451 was the first, #468 the
#      second, both the same class.
#
# Processes are killed by RECORDED PID only, never `pkill -f` (which would
# reap sibling workers and the test's own shell).
#
# Run: bash monitor/watcher/test-upload-asset-fd-leak.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
UPLOAD="$_repo_root/monitor/upload-asset.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "got [$2] want [$3]"; }
assert_ne() { [[ "$2" != "$3" ]] && ok "$1" || bad "$1" "got [$2], wanted anything else"; }
assert_contains() { grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1" "missing [$3] in <<$2>>"; }

[[ -f "$UPLOAD" ]] || { echo "missing $UPLOAD" >&2; exit 1; }
command -v setsid >/dev/null || { echo "SKIP: setsid unavailable" >&2; exit 0; }
[[ -d /proc/self/fd ]]       || { echo "SKIP: /proc unavailable" >&2; exit 0; }

WORK=$(mktemp -d)
DAEMON_PIDS=()
cleanup() {
    # By recorded pid, one at a time. Never pkill.
    local p
    for p in "${DAEMON_PIDS[@]:-}"; do
        [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

# One lock file PER SECTION. Sharing one is a trap: run against pre-fix source,
# section A's daemon leaks the fd and wedges the lock, so section B can no
# longer even acquire it and fails with a misleading "manager exit 9" instead
# of its own assertion. Isolation keeps each section's verdict its own.
LOCK_A="$WORK/assets-a.lock"; : > "$LOCK_A"
LOCK_B="$WORK/assets-b.lock"; : > "$LOCK_B"

# ---- extract the REAL helpers from the script under test -------------------
# upload-asset.sh is a `set -e` top-level flow (it stages, elects, drains and
# exits), so it cannot be sourced. Lift the functions under test verbatim.
#
# Everything below drives `_git_assets`, deliberately: it is the symbol that
# exists in BOTH the pre-fix and post-fix source, so this suite runs against
# either. Pre-fix it expands to a bare `git`; post-fix it delegates to
# `_git_hardened`. That is what makes the both-directions check meaningful
# rather than a "the function is missing" degenerate failure.
#
#   git stash push monitor/upload-asset.sh \
#     && bash monitor/watcher/test-upload-asset-fd-leak.sh ; git stash pop
#
# `_git_hardened` is optional at extraction time for exactly that reason.
_assets_src=$(sed -n '/^_git_assets() {/,/^}/p' "$UPLOAD")
[[ -n "$_assets_src" ]] || { echo "could not extract _git_assets from $UPLOAD" >&2; exit 1; }
_hardened_src=$(sed -n '/^_git_hardened() {/,/^}/p' "$UPLOAD")   # absent pre-fix
[[ -n "$_hardened_src" ]] && eval "$_hardened_src"
eval "$_assets_src"
declare -F _git_assets >/dev/null || { echo "_git_assets did not define" >&2; exit 1; }

# _git_assets' free variables. ASSETS_DIR only reaches the fake git as `-C`.
ASSETS_DIR="$WORK/assets"; mkdir -p "$ASSETS_DIR"
BOT_NAME="test-bot[bot]"
BOT_EMAIL="test-bot[bot]@users.noreply.github.com"

# ---- fake git -------------------------------------------------------------
# Mimics the two behaviours that matter: it forks a detached, long-lived
# credential daemon (inheriting whatever fds it was given), and it honours
# GIT_TERMINAL_PROMPT by either failing fast or blocking on a "prompt".
mkdir -p "$WORK/bin"
cat > "$WORK/bin/git" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GIT_ARGV"
printf 'GIT_TERMINAL_PROMPT=%s\n' "${GIT_TERMINAL_PROMPT-<unset>}" >> "$FAKE_GIT_ENV"

if [[ -n "${FAKE_GIT_SPAWN_DAEMON:-}" ]]; then
    # git-credential-cache--daemon: setsid, reparent to init, outlive everyone,
    # holding every fd it inherited.
    setsid bash -c 'echo $$ > "'"$FAKE_DAEMON_PID"'.tmp"; mv -f "'"$FAKE_DAEMON_PID"'.tmp" "'"$FAKE_DAEMON_PID"'"; exec sleep 60' </dev/null >/dev/null 2>&1 &
    # Wait for the pid file so the caller never races us.
    for _ in $(seq 1 100); do [[ -s "$FAKE_DAEMON_PID" ]] && break; sleep 0.05; done
fi

if [[ -n "${FAKE_GIT_EXPIRED_TOKEN:-}" ]]; then
    if [[ "${GIT_TERMINAL_PROMPT:-1}" == "0" ]]; then
        echo "fatal: Authentication failed for 'https://github.com/x/y.git/'" >&2
        exit 128
    fi
    # No prompt suppression → git blocks forever on an unanswerable prompt.
    exec sleep 60
fi
exit 0
EOS
chmod +x "$WORK/bin/git"
export PATH="$WORK/bin:$PATH"
export FAKE_GIT_ARGV="$WORK/argv.txt" FAKE_GIT_ENV="$WORK/env.txt"
: > "$FAKE_GIT_ARGV"; : > "$FAKE_GIT_ENV"

# Count fds in <pid> that point at <lockfile>.
fds_on_lock() { # pid lockfile
    local n=0 l target
    target=$(readlink -f "$2")
    for l in /proc/"$1"/fd/*; do
        [[ -e "$l" ]] || continue
        [[ "$(readlink -f "$l" 2>/dev/null)" == "$target" ]] && n=$(( n + 1 ))
    done
    printf '%s' "$n"
}

wait_for_daemon() { # pidfile → echoes pid
    local pf="$1" i
    for i in $(seq 1 100); do [[ -s "$pf" ]] && { cat "$pf"; return 0; }; sleep 0.05; done
    return 1
}

# ============================================================
echo '=== A/C: manager exits, daemon lives, lock is FREE and daemon holds no fd ==='
# ============================================================
# The manager subshell takes the lock exactly as upload-asset.sh's ELECT does,
# then invokes git through the hardened helper. On exit, only the daemon is
# left. Post-fix, it inherited nothing.
FIX_PID="$WORK/fixed.pid"; rm -f "$FIX_PID"
(
    exec {LFD}>"$LOCK_A"
    flock -w 5 "$LFD" || exit 9
    _LOCK_FD=$LFD
    export FAKE_GIT_SPAWN_DAEMON=1 FAKE_DAEMON_PID="$FIX_PID"
    _git_assets push origin main
) ; mgr_rc=$?
assert_eq "manager (via _git_assets) exits 0" "$mgr_rc" "0"

fixed_daemon=$(wait_for_daemon "$FIX_PID") || { echo "fixed daemon never started" >&2; exit 1; }
DAEMON_PIDS+=("$fixed_daemon")
kill -0 "$fixed_daemon" 2>/dev/null && ok "daemon still alive after manager exit (as in production)" \
                                     || bad "daemon still alive after manager exit" "it died; test is vacuous"

assert_eq "C: daemon holds NO fd on the lock file" "$(fds_on_lock "$fixed_daemon" "$LOCK_A")" "0"

flock -n "$LOCK_A" -c true 2>/dev/null; free_rc=$?
assert_eq "A: lock is FREE once the manager exits (daemon cannot hold it)" "$free_rc" "0"

# ============================================================
echo '=== B/leak-demo: WITHOUT the fd close the daemon wedges the lock ==='
# ============================================================
# Byte-for-byte the same flow, minus `{_LOCK_FD}>&-`. If this does NOT wedge,
# assertion A above proved nothing — the close would be a no-op.
LEAK_PID="$WORK/leaked.pid"; rm -f "$LEAK_PID"
(
    exec {LFD}>"$LOCK_B"
    flock -w 5 "$LFD" || exit 9
    export FAKE_GIT_SPAWN_DAEMON=1 FAKE_DAEMON_PID="$LEAK_PID"
    GIT_TERMINAL_PROMPT=0 git -c credential.helper= push origin main   # NO fd close
) ; leak_mgr_rc=$?
assert_eq "leak-demo manager exits 0" "$leak_mgr_rc" "0"

leaked_daemon=$(wait_for_daemon "$LEAK_PID") || { echo "leak daemon never started" >&2; exit 1; }
DAEMON_PIDS+=("$leaked_daemon")

assert_ne "B: leaked daemon DOES hold an fd on the lock" "$(fds_on_lock "$leaked_daemon" "$LOCK_B")" "0"

flock -n "$LOCK_B" -c true 2>/dev/null; wedged_rc=$?
assert_eq "B: lock is WEDGED after the manager exits (pre-fix behaviour)" "$wedged_rc" "1"

# Releasing it requires killing the daemon by its exact pid — the production
# recovery. Confirms nothing else was holding the lock.
kill "$leaked_daemon" 2>/dev/null || true
for _ in $(seq 1 100); do kill -0 "$leaked_daemon" 2>/dev/null || break; sleep 0.05; done
flock -n "$LOCK_B" -c true 2>/dev/null; released_rc=$?
assert_eq "B: killing the leaked daemon by exact pid releases the lock" "$released_rc" "0"

# ============================================================
echo '=== D/E: an expired token fails LOUD and fast, never hangs on a prompt ==='
# ============================================================
: > "$FAKE_GIT_ENV"
export FAKE_GIT_EXPIRED_TOKEN=1
unset FAKE_GIT_SPAWN_DAEMON

# `timeout` must wrap a PROCESS, and _git_assets is a shell function, so drive
# it from a generated script that re-evals the same extracted source. The bound
# is what keeps this suite terminating when run against PRE-FIX source, where
# the fake git blocks on its unanswerable prompt exactly as the real one did.
cat > "$WORK/drive.sh" <<EOS
set -uo pipefail
_LOCK_FD=9          # not open here; closing a non-open fd is a harmless no-op
ASSETS_DIR="$ASSETS_DIR"
BOT_NAME="$BOT_NAME"
BOT_EMAIL="$BOT_EMAIL"
$_hardened_src
$_assets_src
_git_assets "\$@"
EOS

start=$(date +%s)
out=$(timeout 10 bash "$WORK/drive.sh" push origin main 2>&1); rc=$?
elapsed=$(( $(date +%s) - start ))

# rc=124 (timeout) would also satisfy a bare "non-zero exit", and that is
# precisely the pre-fix hang. Assert git's OWN failure code instead.
assert_eq "D: expired token -> git's own non-zero exit (128), not a timeout (124)" "$rc" "128"
assert_contains "D: expired token -> loud, attributable error" "$out" "Authentication failed"
[[ "$elapsed" -lt 10 ]] && ok "D: fails within seconds (${elapsed}s), does not hang" \
                        || bad "D: fails within seconds" "took ${elapsed}s"
assert_contains "D: helper sets GIT_TERMINAL_PROMPT=0" "$(cat "$FAKE_GIT_ENV")" "GIT_TERMINAL_PROMPT=0"

# Leak-demo: the identical invocation WITHOUT the env var blocks forever.
timeout 3 env -u GIT_TERMINAL_PROMPT git -c credential.helper= push origin main >/dev/null 2>&1
hang_rc=$?
assert_eq "E: without GIT_TERMINAL_PROMPT=0 the same push HANGS (timeout 124)" "$hang_rc" "124"

unset FAKE_GIT_EXPIRED_TOKEN

# ============================================================
echo '=== F: contract — no bare git in upload-asset.sh; helper keeps all 3 guards ==='
# ============================================================
# #451 (instance lock) and #468 (asset lock) are the same defect class: a
# long-lived child inheriting a lock fd. The structural guard against a third
# is that this script has exactly ONE way to invoke git, and it is hardened.
# Scan the script with the helper's OWN body elided — it is the one place a
# literal `git` may appear — and with comments stripped.
bare_git=$(sed '/^_git_hardened() {/,/^}/d' "$UPLOAD" \
           | grep -vE '^[[:space:]]*#' \
           | grep -nE '(^|[;&|(]|[[:space:]])git[[:space:]]' \
           | grep -vE '_git_hardened|_git_assets' \
           | grep -vE 'git identity|github\.bot' || true)
assert_eq "F: no bare 'git' invocation outside the hardened helper" "$bare_git" ""

helper_body=$(sed -n '/^_git_hardened() {/,/^}/p' "$UPLOAD")
assert_contains "F: helper disables the credential helper (no daemon)" "$helper_body" "credential.helper="
assert_contains "F: helper sets GIT_TERMINAL_PROMPT=0 (fail loud)"     "$helper_body" "GIT_TERMINAL_PROMPT=0"
assert_contains "F: helper closes the lock fd in the child"            "$helper_body" '{_LOCK_FD}>&-'

# The fd number must never be hardcoded apart from the placeholder: ELECT and
# the flock calls must all read $_LOCK_FD, or the close can drift off the fd
# actually holding the lock.
assert_contains "F: ELECT opens the lock on \$_LOCK_FD"   "$(grep -F 'exec {_LOCK_FD}>' "$UPLOAD")" 'exec {_LOCK_FD}>'
stale_fd=$(grep -nE '^[[:space:]]*(flock .* 9$|exec 9>)' "$UPLOAD" || true)
assert_eq "F: no hardcoded fd 9 left in the lock path" "$stale_fd" ""

# ============================================================
echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
