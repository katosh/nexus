#!/usr/bin/env bash
# Unit tests for jupyter-up.sh's first-run health-wait timeout policy
# (your-org/nexus-code#313 item 3).
#
# The bug: `monitor/jupyter-up.sh --root` is the idempotent "bring it up"
# command, but its health-wait `die`s with exit 1 when UP_TIMEOUT elapses
# — even though the supervisor keeps retrying and the server converges to
# healthy moments later (common on a first-ever start on hpc-mount where
# the labsh venv build outlasts the 180s budget). The exit code then
# contradicts the eventual (correct) state.
#
# The fix factors the wait policy into `_await_health_or_converge`, which
# on timeout re-probes once and then SOFT-SUCCEEDS (rc 10) when the
# supervisor is alive, reserving a hard `die` for a genuinely dead
# supervisor. This test sources jupyter-up.sh (its dispatch is guarded by
# a BASH_SOURCE check) and drives that function directly with stubbed
# health + supervisor-liveness, so no labsh/uv/venvs are needed.
#
# Run: bash monitor/watcher/test-jupyter-up-timeout.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

MON_DIR=$(cd "$_test_dir/.." && pwd)
UP="$MON_DIR/jupyter-up.sh"

WORK=$(mktemp -d -t nexus-jup-timeout-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

export NEXUS_STATE_DIR="$WORK/state"
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
mkdir -p "$WORK/state/services" "$WORK/proj"

# Health stub controlled by a marker file: present + content "ok" ⇒
# exit 0 (healthy), otherwise exit 1. A "fail-then-ok" mode flips the
# marker to ok on its second invocation (to exercise the timeout
# re-probe-saves path).
HEALTH_STUB="$WORK/health-stub.sh"
cat > "$HEALTH_STUB" <<'SH'
#!/usr/bin/env bash
ctl="$HEALTH_CTL"
mode=$(cat "$ctl" 2>/dev/null || echo fail)
case "$mode" in
    ok)            exit 0 ;;
    fail)          exit 1 ;;
    fail-then-ok)  echo ok > "$ctl"; exit 1 ;;   # fail now, ok next call
    *)             exit 1 ;;
esac
SH
chmod +x "$HEALTH_STUB"
export HEALTH_CTL="$WORK/health.ctl"

# Source jupyter-up.sh: the BASH_SOURCE-guarded dispatch means sourcing
# defines its functions (and bootstrap-recover's primitives) without
# running a verb. Then override the two seams the wait policy depends on:
# HEALTH_BIN (the probe) and _recover_service_running (supervisor live?).
# shellcheck source=../jupyter-up.sh
source "$UP"

HEALTH_BIN="$HEALTH_STUB"
PROJECT_DIR="$WORK/proj"
ROOT_MODE=1
UP_TIMEOUT=0            # time out on the first loop pass — no real waiting
LAUNCH_BIN="$WORK/labsh-supervised.sh"   # value only matters as an arg

# Supervisor-liveness is overridden per-case via this flag.
SUPERVISOR_ALIVE=1
_recover_service_running() { (( SUPERVISOR_ALIVE )); }
# Pidfile read in the soft-success branch — make it resolve to a value.
mkdir -p "$WORK/state/services"
echo 4242 > "$WORK/state/services/jupyterlab.pid"

# --- Case 1: timeout + supervisor alive ⇒ soft success (rc 10) ----------

echo '=== Case 1: timeout with a live supervisor soft-succeeds (rc 10) ==='
echo fail > "$HEALTH_CTL"
SUPERVISOR_ALIVE=1
out=$(_await_health_or_converge jupyterlab 2>&1); rc=$?
assert_eq "rc is 10 (soft success, not failure)" "$rc" "10"
assert_contains "explains the supervisor is still converging" "$out" "still converging"

# --- Case 2: timeout + supervisor DEAD ⇒ hard failure (die, exit 1) -----

echo '=== Case 2: timeout with a dead supervisor is a hard failure ==='
echo fail > "$HEALTH_CTL"
SUPERVISOR_ALIVE=0
# die() exits the shell, so run in a subshell to capture the exit code.
out=$( SUPERVISOR_ALIVE=0; _await_health_or_converge jupyterlab 2>&1 ); rc=$?
assert_eq "rc is 1 (die on dead supervisor)" "$rc" "1"
assert_contains "names the dead-supervisor failure" "$out" "supervisor is not running"

# --- Case 3: already healthy ⇒ success (rc 0) ---------------------------

echo '=== Case 3: healthy immediately returns rc 0 ==='
echo ok > "$HEALTH_CTL"
SUPERVISOR_ALIVE=1
out=$(_await_health_or_converge jupyterlab 2>&1); rc=$?
assert_eq "rc is 0 (healthy)" "$rc" "0"

# --- Case 4: unhealthy in-loop but the timeout re-probe catches it -------

echo '=== Case 4: re-probe at timeout catches a just-converged server (rc 0) ==='
echo fail-then-ok > "$HEALTH_CTL"   # loop check fails; timeout re-probe passes
SUPERVISOR_ALIVE=1
out=$(_await_health_or_converge jupyterlab 2>&1); rc=$?
assert_eq "rc is 0 (re-probe saw it converge)" "$rc" "0"

th_summary_and_exit
