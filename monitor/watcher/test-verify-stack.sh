#!/usr/bin/env bash
# Unit tests for monitor/watcher/verify-stack.sh — the bootstrap-finish
# convergence check (your-org/nexus-code#313 item 4).
#
# The install (and `./watcher`) must END by starting the watcher AND
# observing the whole stack is running before declaring success, instead
# of stopping at "svc.sh up returned". verify-stack.sh polls the three
# components — watcher heartbeat fresh, orchestrator tmux window present,
# registry services healthy — and exits 0 only when all converge.
#
# Hermetic: the watcher heartbeat is a fixture file (freshness set via
# mtime), services are registry rows whose healthcheck is `test -f
# <marker>`, and tmux is a PATH-shadow stub whose `list-windows` prints a
# controlled window list. No real watcher, services, or tmux server.
#
# Run: bash monitor/watcher/test-verify-stack.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

VERIFY="$_test_dir/verify-stack.sh"

WORK=$(mktemp -d -t nexus-verify-stack-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/state" "$WORK/stub-bin"

# tmux stub: `list-windows -F …` prints the names in $WORK/windows (one
# per line); every other tmux call is a harmless no-op success. This lets
# _recover_window_exists resolve against a controlled window set with no
# tmux server.
cat > "$WORK/stub-bin/tmux" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
    if [[ "\$a" == "list-windows" ]]; then
        cat "$WORK/windows" 2>/dev/null
        exit 0
    fi
done
exit 0
SH
chmod +x "$WORK/stub-bin/tmux"

# Fresh, pid-less heartbeat: with no `pid=` field, _watcher_alive skips
# the live-watcher cmdline check and decides purely on mtime age.
HB="$WORK/state/watcher-heartbeat"
fresh_watcher() { printf 'ts=now\ntarget=orchestrator\n' > "$HB"; touch "$HB"; }
stale_watcher() { printf 'ts=old\ntarget=orchestrator\n' > "$HB"; touch -d '2 hours ago' "$HB"; }

orch_present() { printf 'services\norchestrator\n' > "$WORK/windows"; }
orch_absent()  { printf 'services\n'              > "$WORK/windows"; }

# Registry helpers. healthcheck = `test -f $WORK/svc-ok`; toggle the
# marker to make the single service healthy / unhealthy.
write_registry() {  # $1 = number of service rows (0 or 1)
    : > "$WORK/services.registry"
    if (( $1 >= 1 )); then
        printf 'demo\t%s\t%s\ttest -f %s/svc-ok\t%s/demo.log\n' \
            "$WORK" "$WORK/launch.sh" "$WORK" "$WORK" >> "$WORK/services.registry"
    fi
}
svc_healthy()   { : > "$WORK/svc-ok"; }
svc_unhealthy() { rm -f "$WORK/svc-ok"; }

run_verify() {  # extra args forwarded; short timeout so failures are fast
    PATH="$WORK/stub-bin:$PATH" \
    NEXUS_STATE_DIR="$WORK/state" \
    NEXUS_SERVICES_REGISTRY="$WORK/services.registry" \
    RECOVER_TARGET_WINDOW=orchestrator \
        bash "$VERIFY" --timeout 1 --poll 1 "$@" 2>&1
}

# --- Case 1: all three converged ⇒ rc 0 --------------------------------

echo '=== Case 1: watcher fresh + orchestrator up + service healthy ⇒ rc 0 ==='
fresh_watcher; orch_present; write_registry 1; svc_healthy
out=$(run_verify); rc=$?
assert_eq "rc 0 (converged)" "$rc" "0"
assert_contains "reports convergence" "$out" "converged"

# --- Case 2: watcher stale ⇒ rc 1 --------------------------------------

echo '=== Case 2: stale watcher heartbeat ⇒ rc 1 ==='
stale_watcher; orch_present; write_registry 1; svc_healthy
out=$(run_verify); rc=$?
assert_eq "rc 1 (watcher down)" "$rc" "1"
assert_contains "names the watcher as down" "$out" "watcher"

# --- Case 3: orchestrator window absent ⇒ rc 1 -------------------------

echo '=== Case 3: orchestrator window missing ⇒ rc 1 ==='
fresh_watcher; orch_absent; write_registry 1; svc_healthy
out=$(run_verify); rc=$?
assert_eq "rc 1 (orchestrator absent)" "$rc" "1"
assert_contains "names the orchestrator as down" "$out" "orchestrator"

# --- Case 4: a service unhealthy ⇒ rc 1 --------------------------------

echo '=== Case 4: registry service unhealthy ⇒ rc 1 ==='
fresh_watcher; orch_present; write_registry 1; svc_unhealthy
out=$(run_verify); rc=$?
assert_eq "rc 1 (service down)" "$rc" "1"
assert_contains "names the unhealthy service" "$out" "demo"

# --- Case 5: --no-orchestrator skips the window check ⇒ rc 0 -----------

echo '=== Case 5: --no-orchestrator ignores a missing window ⇒ rc 0 ==='
fresh_watcher; orch_absent; write_registry 1; svc_healthy
out=$(run_verify --no-orchestrator); rc=$?
assert_eq "rc 0 (orchestrator check skipped)" "$rc" "0"

# --- Case 6: empty registry is trivially satisfied ⇒ rc 0 --------------

echo '=== Case 6: no registry services + watcher + orchestrator ⇒ rc 0 ==='
fresh_watcher; orch_present; write_registry 0
out=$(run_verify); rc=$?
assert_eq "rc 0 (watcher-only deployment converges)" "$rc" "0"

th_summary_and_exit
