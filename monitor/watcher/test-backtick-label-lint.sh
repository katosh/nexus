#!/usr/bin/env bash
# test-backtick-label-lint.sh — no assertion LABEL in a double-quoted first
# argument may carry an unescaped backtick (your-org/nexus-code#1427, the
# #1157 BACKTICK-SUBSTITUTION class reaching assertion labels). The
# identifier is command-substituted before the helper sees it: an unknown word
# yields `command not found` on stderr and an EMPTY splice, a word that IS a
# command splices its stdout — and the assertion's VALUE arguments are
# untouched, so it still PASSES with a label one word short. Four live sites in
# three suites shipped that way; none of them reddened.
#
# Population: every tracked test-*.sh (a construct lint — an edit anywhere can
# join it), declared for `ng guards-for-diff`.
# Run: bash monitor/watcher/test-backtick-label-lint.sh
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

_bt_population() { ( cd "$REPO_ROOT" && git ls-files -- ':(glob)**/test-*.sh' ':(glob)test-*.sh' ); }
# The lint over ONE file: assertion-word + optional whitespace + a double-quoted
# first argument containing a backtick that is not preceded by a backslash.
# A label that OPENS with `"$(` is a command substitution whose inner quoting
# governs its backticks (`fail "$(printf '%s — `grep -qF ""` …')"` is safe,
# measured), so that shape is out of this lint's scope and said so here.
_bt_lint() {   # <file> -> offending lines (file:line: text) on stdout
    grep -nE '^[[:space:]]*(assert_[a-z_]+|ok|bad|pass|fail|th_expect_fail)[[:space:]]+"[^"]*`' "$1" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*(assert_[a-z_]+|ok|bad|pass|fail|th_expect_fail)[[:space:]]+"([^"`]|\\`)*"' \
        | grep -vE '^[0-9]+:[[:space:]]*(assert_[a-z_]+|ok|bad|pass|fail|th_expect_fail)[[:space:]]+"\$\(' \
        | sed "s#^#$1:#"
}
# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() { _bt_population; printf '%s\n' monitor/watcher/_test_helpers.sh; }
gp_handle "$@"

WORK=$(mktemp -d -t nxbtlabel-XXXXXX); trap 'rm -rf "$WORK"' EXIT
echo '=== positive control: the lint SEES a planted label ==='
cat > "$WORK/test-planted.sh" <<'FIX'
assert_eq "a label with `word` in it" "x" "x"
assert_contains "an escaped \`word\` is fine" "x" "x"
assert_eq 'single quotes are fine `word`' "x" "x"
ok "bare ok with `thing`"
FIX
hits=$(_bt_lint "$WORK/test-planted.sh")
assert_eq "planted: exactly the two unescaped double-quoted labels are flagged" "$(printf '%s\n' "$hits" | sed '/^$/d' | wc -l)" "2"   # one offender per LINE, so lines are the unit
assert_contains "planted: the assert_eq site" "$hits" 'test-planted.sh:1:'
assert_contains "planted: the bare ok site"   "$hits" 'test-planted.sh:4:'
assert_not_contains "planted: the escaped backtick is NOT flagged" "$hits" 'test-planted.sh:2:'

echo '=== the corpus ==='
n=0; all=""
while IFS= read -r f; do
    [[ -n "$f" && -f "$REPO_ROOT/$f" ]] || continue
    # This suite's own planted fixture (a heredoc below) is the positive
    # control and is excluded from the corpus for the same reason
    # test-claude-md-block-coverage.sh excludes its own source.
    [[ "$f" == monitor/watcher/test-backtick-label-lint.sh ]] && continue
    n=$((n+1))
    h=$(cd "$REPO_ROOT" && _bt_lint "$f"); [[ -n "$h" ]] && all+="$h"$'\n'
done < <(_bt_population)
assert_eq "population is non-vacuous (>= 200 suites)" "$(( n >= 200 ))" "1"
assert_eq "#1427 no tracked suite carries an unescaped backtick in a double-quoted label${all:+ — offenders:
$all}" "$(printf '%s' "$all" | grep -c . || true)" "0"
echo
EXPECTED=6
if (( PASS + FAIL != EXPECTED )); then printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$(( PASS + FAIL ))" "$EXPECTED" >&2; _th_fail; fi
th_summary_and_exit
