#!/usr/bin/env bash
# test-v2-task-rc-propagation.sh — the v2 task wrappers return their tick's
# status, so a tick's rc-79 refusal (#1266) reaches the scheduler's telemetry
# instead of being recorded as a healthy tick (your-org/nexus-code#1430).
#
# Run: bash monitor/watcher/test-v2-task-rc-propagation.sh
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
MAIN="$_test_dir/main.sh"

# Extract the two wrappers BY NAME from main.sh (the robustness suite's idiom),
# so this asserts the shipped text rather than a copy of it.
_extract() { sed -n "/^$1() {/,/^}/p" "$MAIN"; }
_w1=$(_extract _v2_task_version_check); _w2=$(_extract _v2_task_service_health)
assert_eq "both wrappers were found in main.sh" "$([[ -n "$_w1" && -n "$_w2" ]] && echo yes || echo no)" "yes"
eval "$_w1"; eval "$_w2"

echo '=== a refusing tick is a refusing task ==='
_version_check_tick()        { return 79; }
_service_health_check_tick() { return 79; }
_v2_task_version_check;  assert_eq "#1430 version_check: tick rc 79 -> task rc 79 (was 0)"  "$?" "79"
_v2_task_service_health; assert_eq "#1430 service_health: tick rc 79 -> task rc 79 (was 0)" "$?" "79"

echo '=== a healthy tick is still a healthy task ==='
_version_check_tick()        { return 0; }
_service_health_check_tick() { return 0; }
_v2_task_version_check;  assert_eq "CONTROL version_check: tick rc 0 -> task rc 0"  "$?" "0"
_v2_task_service_health; assert_eq "CONTROL service_health: tick rc 0 -> task rc 0" "$?" "0"

echo '=== the text carries no unconditional return 0 in either wrapper ==='
assert_eq "no 'return 0' inside the wrappers" "$(printf '%s\n%s\n' "$_w1" "$_w2" | grep -c 'return 0' || true)" "0"

echo
EXPECTED=6
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
