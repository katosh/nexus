#!/usr/bin/env bash
# test-changelog-merge-union.sh — the root .gitattributes merges CHANGELOG.md
# by UNION, so two branches that each append an entry merge without a
# conflict (your-org/nexus-code#1264 R1). Driven on a fixture repo carrying the
# shipped .gitattributes, with a control repo carrying none.
# Run: bash monitor/watcher/test-changelog-merge-union.sh
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
WORK=$(mktemp -d -t nxunion-XXXXXX); trap 'rm -rf "$WORK"' EXIT
assert_eq "the root .gitattributes declares CHANGELOG.md merge=union" \
    "$(grep -cE '^CHANGELOG\.md[[:space:]]+merge=union' "$REPO_ROOT/.gitattributes" 2>/dev/null || true)" "1"
_mk() {   # <dir> <with-attributes: 1|0> -> merge rc
    local d="$1" attr="$2"
    mkdir -p "$d"; git -C "$d" init -q; git -C "$d" config user.email t@t; git -C "$d" config user.name t
    printf '# Changelog\n\n## Unreleased\n\n- base entry\n' > "$d/CHANGELOG.md"
    (( attr )) && cp "$REPO_ROOT/.gitattributes" "$d/.gitattributes"
    git -C "$d" add -A; git -C "$d" commit -qm base
    git -C "$d" checkout -qb a; printf -- '- entry from PR A\n' >> "$d/CHANGELOG.md"; git -C "$d" commit -qam a
    git -C "$d" checkout -q master 2>/dev/null || git -C "$d" checkout -q main
    git -C "$d" checkout -qb b; printf -- '- entry from PR B\n' >> "$d/CHANGELOG.md"; git -C "$d" commit -qam b
    git -C "$d" merge -q --no-edit a >/dev/null 2>&1
}
_mk "$WORK/with" 1; rc_with=$?
_mk "$WORK/without" 0; rc_without=$?
assert_eq "#1264 R1 with the attribute: two appended entries MERGE (rc 0)" "$rc_with" "0"
assert_eq "#1264 R1 …and BOTH entries survive" "$(grep -c 'entry from PR' "$WORK/with/CHANGELOG.md")" "2"
assert_eq "#1264 R1 …with no conflict markers" "$(grep -c '^<<<<<<<\|^>>>>>>>' "$WORK/with/CHANGELOG.md" || true)" "0"
assert_eq "CONTROL without the attribute: the same merge CONFLICTS (rc 1)" "$rc_without" "1"
echo
EXPECTED=5
if (( PASS + FAIL != EXPECTED )); then printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$(( PASS + FAIL ))" "$EXPECTED" >&2; _th_fail; fi
th_summary_and_exit
