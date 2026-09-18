#!/usr/bin/env bash
# test-th-require-fixture-repo.sh — th_require_fixture_repo refuses the three
# shapes that aim git at the enclosing repository (your-org/nexus-code#1429).
# Run: bash monitor/watcher/test-th-require-fixture-repo.sh
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
# DECLARE WHAT THIS GUARD READS (your-org/nexus-code#1219): it asserts on
# CLAUDE.md, drives repo-root.sh and sources the assertion library. `gp_handle`
# EXITS when it handles the flag, so it stands above the first line of output.
# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' CLAUDE.md monitor/repo-root.sh monitor/watcher/_test_helpers.sh; }
gp_handle "$@"

WORK=$(mktemp -d -t nxfixrepo-XXXXXX); trap 'rm -rf "$WORK"' EXIT
_try() {   # runs the helper in a child so its exit can be read
    ( . "$_test_dir/_test_helpers.sh"; th_require_fixture_repo "$@" ) >/dev/null 2>"$WORK/err"; echo "$?"
}
echo '=== the mechanism: git -C "" is a no-op against the CURRENT repo ==='
assert_eq "git -C '' answers about the repository you are standing in" \
    "$(cd "$_test_dir" && git -C "" rev-parse --show-toplevel 2>/dev/null)" "$(cd "$_test_dir" && git rev-parse --show-toplevel)"
echo '=== refusals ==='
assert_eq "#1429 an EMPTY path is refused at 97" "$(_try '')" "97"
assert_contains "#1429 …naming the no-op" "$(cat "$WORK/err")" 'git -C ""'
assert_eq "#1429 a non-directory is refused at 97" "$(_try "$WORK/nope")" "97"
assert_eq "#1429 a SUBDIRECTORY of the nexus (walks up) is refused at 97" "$(_try "$_test_dir")" "97"
assert_contains "#1429 …citing repo-root.sh's verdict" "$(cat "$WORK/err")" "repo-root.sh says"
mkdir -p "$WORK/plain"; assert_eq "#1429 a plain non-repo directory is refused at 97" "$(_try "$WORK/plain")" "97"
echo '=== the positive control: a fixture that IS its own repo passes ==='
git -C "$WORK" init -q "$WORK/fx" 2>/dev/null || git init -q "$WORK/fx"
assert_eq "CONTROL: an initialised fixture repo passes (rc 0)" "$(_try "$WORK/fx")" "0"
echo '=== CLAUDE.md names it ==='
assert_eq "CLAUDE.md carries the #1429 entry" "$(grep -c 'th_require_fixture_repo' "$_test_dir/../../CLAUDE.md" || true)" "1"
echo
EXPECTED=9
if (( PASS + FAIL != EXPECTED )); then printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$(( PASS + FAIL ))" "$EXPECTED" >&2; _th_fail; fi
th_summary_and_exit
