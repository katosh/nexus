#!/usr/bin/env bash
# Tests for the instance-lock FD-inheritance fix (your-org/nexus-code#<this>,
# Bug 2 of the 2026-07-07 outage).
#
# The bug: acquire_instance_lock opens the flock via `exec {INSTANCE_LOCK_FD}<>`
# — a bash fd that is NOT close-on-exec, so it is INHERITED by every child the
# watcher spawns. When a version-restart or service-health restart relaunched a
# supervised service (svc.sh → _recover_launch_service → `setsid bash` →
# uvx → jupyter-lab), that long-lived service inherited the lock fd and held
# the flock open FOR ITS OWN LIFETIME. After the watcher wedged and died, the
# service kept the lock; `launcher.sh --instance-status` read
# `assessment=live-local` (recorded holder pid dead, flock still held via the
# leaked fd) and every `revive-watcher` / `svc.sh restart watcher` REFUSED —
# an unrecoverable outage until the operator manually rm'd the lock.
# (Incident evidence: `lsof nexus-instance.lock` showed FD 10u/11u held by the
# jupyter pids long after the watcher pid was gone.)
#
# The fix closes the lock fd IN the svc.sh child (`… {INSTANCE_LOCK_FD}>&-`,
# guarded on the fd being held) at both watcher→svc.sh restart sites
# (_service_health.sh `_sh_restart_service`, _version_restart.sh), mirroring
# launcher.sh's `{_RESTART_LOCK_FD}>&-`. bash 4.x cannot mark an existing
# `exec`-opened fd O_CLOEXEC, so close-at-spawn is the mechanism.
#
# This test drives the REAL `_sh_restart_service` (the service-health site);
# _version_restart.sh uses the byte-identical guarded-literal-close idiom.
#
# Assertions (each falsifiable):
#   A  With the fix + a held lock fd, the svc.sh child inherits NO fd pointing
#      at the lock file.
#   B  Leak-demo (the pre-fix behaviour): a plain `bash svc-stub` with NO close
#      DOES inherit the lock fd — proving the close in A is load-bearing, not a
#      no-op the child would pass anyway.
#   C  The PARENT still holds the lock after the fixed restart (the close denies
#      only the child; the watcher keeps its singleton guard).
#
# Run: bash monitor/watcher/test-instance-lock-fd-leak.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_real_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=_test_helpers.sh
. "$_real_dir/_test_helpers.sh"
# shellcheck source=_service_health.sh
. "$_real_dir/_service_health.sh"

WORK=$(mktemp -d -t nexus-ilock-fdleak-XXXXXX)
trap 'rm -rf "$WORK"; [[ -n "${ILF:-}" ]] && exec {ILF}>&- 2>/dev/null || true' EXIT

# The instance lock file + a leak report the svc stub appends to.
export LEAK_LOCKFILE="$WORK/nexus-instance.lock"
export LEAK_REPORT="$WORK/leak-report.txt"
: > "$LEAK_LOCKFILE"
: > "$LEAK_REPORT"

# svc.sh capture stub: on every invocation, scan its OWN open fds for any
# symlink pointing at the lock file (== the incident's `lsof` check) and record
# matches. Present iff the fd leaked into this child.
SVC_STUB="$WORK/svc-stub.sh"
cat > "$SVC_STUB" <<'STUB'
#!/usr/bin/env bash
for _f in /proc/$$/fd/*; do
    _t=$(readlink "$_f" 2>/dev/null) || continue
    if [[ "$_t" == "$LEAK_LOCKFILE" ]]; then
        printf 'child-fd %s -> %s\n' "${_f##*/}" "$_t" >> "$LEAK_REPORT"
    fi
done
exit 0
STUB
chmod +x "$SVC_STUB"
export SERVICE_HEALTH_SVC_BIN="$SVC_STUB"

# Acquire the instance lock exactly as acquire_instance_lock does: a
# non-cloexec fd via `exec {var}<>`, held for the rest of this shell.
exec {ILF}<>"$LEAK_LOCKFILE"
if ! flock -n "$ILF"; then
    echo "FAIL: could not acquire the test instance lock" >&2
    exit 1
fi
INSTANCE_LOCK_FD="$ILF"     # what main.sh sets; the fix's guard reads it

# ---- A: the fix — svc.sh child does NOT inherit the lock fd ------------
echo '=== fd-leak: fixed restart does not leak the instance-lock fd ==='
: > "$LEAK_REPORT"
_sh_restart_service myservice >/dev/null 2>&1
assert_empty "fixed _sh_restart_service: svc.sh child inherits NO lock fd" \
    "$(cat "$LEAK_REPORT")"

# ---- B: leak-demo — without the close, the fd DOES leak ----------------
echo '=== fd-leak: pre-fix behaviour leaks the fd (close is load-bearing) ==='
: > "$LEAK_REPORT"
# The exact pre-fix call shape: no `{INSTANCE_LOCK_FD}>&-` close.
bash "$SVC_STUB" restart myservice >/dev/null 2>&1
assert_contains "un-closed child inherits the lock fd (proves the leak the fix prevents)" \
    "$(cat "$LEAK_REPORT")" "$LEAK_LOCKFILE"

# ---- C: the parent keeps the lock after the fixed restart -------------
echo '=== fd-leak: parent retains the singleton lock after the fixed restart ==='
lock_still_held=held
flock -n "$LEAK_LOCKFILE" -c true 2>/dev/null && lock_still_held=free
assert_eq "parent still holds the instance lock (child close does not release it)" \
    "$lock_still_held" "held"

th_summary_and_exit
