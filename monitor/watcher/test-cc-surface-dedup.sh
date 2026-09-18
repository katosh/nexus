#!/usr/bin/env bash
# monitor/cc-surface-dedup.sh — "is this verdict news?" for the cc-update
# evaluator's issue comments (your-org/nexus-code#1529).
#
# WHAT IS CHECKED. `check` answers NEW (rc 0) with no record and after any of
# the four inputs changes — verdict, candidate, the live clone's HEAD, the
# rendered body — and UNCHANGED (rc 12) only when all four match the last
# `record`. Whitespace-only edits to the body file are NOT a change. A
# missing or EMPTY body file and an unreadable HEAD REFUSE (rc 3) rather
# than fingerprinting nothing: a dedup keyed on nothing would silence every
# later post for that candidate. `record` prints what it wrote.
#
# Unit test over its own fixture repository; declares no population.
#
# Run: bash monitor/watcher/test-cc-surface-dedup.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
DEDUP="$_repo_root/monitor/cc-surface-dedup.sh"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# A fixture repository standing in for the live clone: HEAD is an input.
REPO="$WORK/clone"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
th_require_fixture_repo "$REPO"
STATE="$WORK/state"
IN="$WORK/body.md"; printf '**BLOCKED.** reason: vimode arm 3 red\n\n<details>\ntest-realmodel-vimode RED\ntest-pane-state-markers GREEN\n</details>\n' > "$IN"

run() { out=$(bash "$DEDUP" "$@" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err"); }
chk() { run check --state-dir "$STATE" --nexus-root "$REPO" "$@"; }
rec() { run record --state-dir "$STATE" --nexus-root "$REPO" "$@"; }

echo "=== usage and refusals ==="
run; assert_eq "no verb: usage (2)" "$rc" "2"
run check --candidate 2.1.260 --verdict block --body-file "$IN"
assert_eq "check without --state-dir: usage (2)" "$rc" "2"
chk --candidate 2.1.260 --verdict block
assert_eq "check without --body-file: usage (2)" "$rc" "2"
chk --candidate 2.1.260 --verdict block --body-file "$WORK/nope.txt"
assert_eq "missing body file: REFUSED (3), not fingerprinted" "$rc" "3"
assert_contains "…and the refusal says to post" "$err" "post"
: > "$WORK/empty.txt"
chk --candidate 2.1.260 --verdict block --body-file "$WORK/empty.txt"
assert_eq "EMPTY body file: REFUSED (3)" "$rc" "3"
printf '  \n\n' > "$WORK/blank.txt"
chk --candidate 2.1.260 --verdict block --body-file "$WORK/blank.txt"
assert_eq "whitespace-only body file: REFUSED (3)" "$rc" "3"
run check --state-dir "$STATE" --nexus-root "$WORK/not-a-repo" --candidate 2.1.260 --verdict block --body-file "$IN"
assert_eq "unreadable live HEAD: REFUSED (3)" "$rc" "3"
run show --state-dir "$STATE"
assert_eq "show with no record: rc 1" "$rc" "1"

echo "=== first verdict is NEW; recorded; the same verdict is UNCHANGED ==="
chk --candidate 2.1.260 --verdict block --body-file "$IN"
assert_eq "no record yet: NEW (0)" "$rc" "0"
assert_contains "…says so" "$out" "no prior record"
rec --candidate 2.1.260 --verdict block --body-file "$IN" --posted https://x/1
assert_eq "record: rc 0" "$rc" "0"
assert_contains "record prints the fingerprint it wrote" "$out" "fingerprint="
assert_contains "record prints where it was posted" "$out" "posted=https://x/1"
assert_file_exists "the record file exists" "$STATE/cc-auto-update/last-surface"
chk --candidate 2.1.260 --verdict block --body-file "$IN"
assert_eq "same verdict/candidate/HEAD/inputs: UNCHANGED (12)" "$rc" "12"
assert_contains "…names the prior post" "$out" "posted https://x/1"
printf '**BLOCKED.** reason: vimode arm 3 red   \n\n\n<details>\ntest-realmodel-vimode RED\ntest-pane-state-markers GREEN\n</details>\n\n' > "$WORK/ws.txt"
chk --candidate 2.1.260 --verdict block --body-file "$WORK/ws.txt"
assert_eq "whitespace-only differences in the body are not a change (12)" "$rc" "12"
run show --state-dir "$STATE"
assert_eq "show: rc 0" "$rc" "0"
assert_contains "show: the record names the candidate" "$out" "candidate=2.1.260"

echo "=== each input, varied alone, makes it NEW again (potency, one axis at a time) ==="
chk --candidate 2.1.261 --verdict block --body-file "$IN"
assert_eq "new candidate: NEW (0)" "$rc" "0"
chk --candidate 2.1.260 --verdict needs-review --body-file "$IN"
assert_eq "new verdict: NEW (0)" "$rc" "0"
printf '**BLOCKED.** reason: hook payload changed\n\n<details>\ntest-realmodel-vimode RED\ntest-pane-state-markers GREEN\n</details>\n' > "$WORK/in2.txt"
chk --candidate 2.1.260 --verdict block --body-file "$WORK/in2.txt"
assert_eq "a changed REASON sentence with identical evidence: NEW (0) — w241sk F4" "$rc" "0"
assert_contains "…and the NEW line names the record it differs from" "$out" "last record: verdict=block candidate=2.1.260"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "pulled"
chk --candidate 2.1.260 --verdict block --body-file "$IN"
assert_eq "the live clone moved (a pull happened): NEW (0)" "$rc" "0"
# CONTROL for the axis above: the record re-made at the new HEAD is UNCHANGED again.
rec --candidate 2.1.260 --verdict block --body-file "$IN"
chk --candidate 2.1.260 --verdict block --body-file "$IN"
assert_eq "control: re-recorded at the new HEAD → UNCHANGED (12)" "$rc" "12"
assert_contains "record without --posted writes a placeholder" "$(cat "$STATE/cc-auto-update/last-surface")" "posted=-"

echo "=== the behind-count is not news (w241sk D5); a scenario tally is ==="
printf '**BLOCKED.** 3 commits behind origin/dev; reason: vimode arm 3 red\n\n<details>\nbehind_integration=3 integration_branch=dev\n8/8 scenarios\n</details>\n' > "$WORK/b3.md"
rec --candidate 2.1.260 --verdict block --body-file "$WORK/b3.md"
printf '**BLOCKED.** 5 commits behind origin/dev; reason: vimode arm 3 red\n\n<details>\nbehind_integration=5 integration_branch=dev\n8/8 scenarios\n</details>\n' > "$WORK/b5.md"
chk --candidate 2.1.260 --verdict block --body-file "$WORK/b5.md"
assert_eq "3 → 5 commits behind, everything else identical: UNCHANGED (12)" "$rc" "12"
printf '**BLOCKED.** 5 commits behind origin/dev; reason: vimode arm 3 red\n\n<details>\nbehind_integration=5 integration_branch=dev\n7/8 scenarios\n</details>\n' > "$WORK/b5b.md"
chk --candidate 2.1.260 --verdict block --body-file "$WORK/b5b.md"
assert_eq "control: a changed scenario tally (8/8 → 7/8) is NEW (0)" "$rc" "0"

echo "=== read-only on the repository ==="
assert_eq "the fixture repository is clean after every call" "$(git -C "$REPO" status --porcelain)" ""
assert_eq "only rev-parse is used: no ref but HEAD/master exists" \
    "$(git -C "$REPO" for-each-ref --format='%(refname)' | grep -vcE '^refs/heads/(master|main)$')" "0"

_EXPECTED_ASSERTIONS=31   # count=exact (summary-honesty): every assertion above, once
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2; _th_fail
fi
th_summary_and_exit
