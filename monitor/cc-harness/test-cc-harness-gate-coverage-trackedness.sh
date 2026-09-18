#!/usr/bin/env bash
# test-cc-harness-gate-coverage-trackedness.sh — gate-coverage.sh's two
# filesystem-glob populations are refused when a member is UNTRACKED, because an
# untracked file SATISFIES every vacuity/vocabulary refusal they feed while HEAD
# does not identify it (your-org/nexus-code#1412, #1320).
# Run: bash monitor/cc-harness/test-cc-harness-gate-coverage-trackedness.sh
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/../watcher/_test_helpers.sh"
GC="$_test_dir/gate-coverage.sh"
WORK=$(mktemp -d -t nxgcovtr-XXXXXX); trap 'rm -rf "$WORK"' EXIT
# Source ONLY the function under test, by name, from the shipped file.
eval "$(sed -n '/^gcov_refuse_if_untracked() {/,/^}/p' "$GC")"
assert_eq "gcov_refuse_if_untracked was extracted from gate-coverage.sh" "$(declare -F gcov_refuse_if_untracked >/dev/null && echo yes || echo no)" "yes"

repo="$WORK/repo"; mkdir -p "$repo/scen"; git -C "$repo" init -q
printf 'tracked\n' > "$repo/scen/test-realmodel-a.sh"; git -C "$repo" add -A; git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init
printf 'plant\n'   > "$repo/scen/test-realmodel-plant.sh"      # UNTRACKED

echo '=== all members tracked -> rc 0 ==='
gcov_refuse_if_untracked scenarios "$repo" "$repo/scen/test-realmodel-a.sh" >/dev/null 2>&1
assert_eq "tracked-only population passes" "$?" "0"

echo '=== one UNTRACKED member -> REFUSED ==='
out=$(gcov_refuse_if_untracked scenarios "$repo" "$repo/scen/test-realmodel-a.sh" "$repo/scen/test-realmodel-plant.sh" 2>"$WORK/err"); rc=$?
assert_eq "#1412 an untracked member refuses (rc 3)" "$rc" "3"
assert_contains "#1412 …naming the member" "$out" "member=scen/test-realmodel-plant.sh"
assert_contains "#1412 …and the reason" "$out" "reason=untracked_population_member"
assert_contains "#1412 …with the population label" "$out" "label=scenarios"

echo '=== members OUTSIDE the repo are not a trackedness question (fixture trees) ==='
mkdir -p "$WORK/fixtures"; printf 'x\n' > "$WORK/fixtures/test-realmodel-fx.sh"
gcov_refuse_if_untracked scenarios "$repo" "$WORK/fixtures/test-realmodel-fx.sh" >/dev/null 2>&1
assert_eq "an out-of-repo member is skipped, not refused" "$?" "0"

echo '=== could not ask git -> not silently clean ==='
nr="$WORK/notrepo"; mkdir -p "$nr"; printf 'x\n' > "$nr/f.sh"
gcov_refuse_if_untracked scenarios "$nr" "$nr/f.sh" >/dev/null 2>&1
assert_eq "a population under a NON-repo is refused (undecidable), not passed" "$([[ $? -ne 0 ]] && echo refused || echo passed)" "refused"

echo
EXPECTED=8
if (( PASS + FAIL != EXPECTED )); then printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$(( PASS + FAIL ))" "$EXPECTED" >&2; _th_fail; fi
th_summary_and_exit
