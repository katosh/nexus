#!/usr/bin/env bash
# The report schema's `disposition:` annotation agrees with `ng wrap-up`
# (your-org/nexus-code#1512).
#
# THE DEFECT. skills/nexus.report/SKILL.md's frontmatter schema said the field
# was "skeptic reports only" and that "an ordinary worker DELETES the line".
# `ng wrap-up` (the #1095 refusal) refuses a wrap-up that resolves to a
# REQUIRED skeptic — spawned `require`, or `--skeptic-decision require` under
# `auto`/`deny` — when the report states no readable disposition, whoever the
# author is. A worker that followed the schema was refused by the tool (w233,
# your-org/your-nexus#374); one round-trip, failed safe.
#
# WHAT IS CHECKED. (1) The tool still carries the refusal this doc describes —
# a positive control on the claim, so the doc cannot outlive the behaviour.
# (2) The `disposition:` annotation in the schema block no longer says the
# pre-#1095 thing and does say when the field is required and that the
# author's role does not matter. (3) A planted copy carrying the old text is
# caught, so the green is falsifiable.
#
# Run: bash monitor/watcher/test-report-schema-disposition-doc.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
SKILL="skills/nexus.report/SKILL.md"
NG="monitor/ng"

# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$SKILL" "$NG"; }
gp_handle "$@"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# disposition_annotation <skill-file> -> the `disposition:` schema line plus its
# continuation comment lines (indented `#`), up to the next field line.
disposition_annotation() {
    awk '
        /^disposition:/ { f=1; print; next }
        f && /^[[:space:]]+#/ { print; next }
        f { exit }
    ' "$1"
}

echo "=== positive control: the tool still refuses an absent disposition on the require path ==="
assert_contains "ng carries the #1095 refusal this doc describes" \
    "$(grep -F 'YOUR REPORT STATES NO DISPOSITION' "$_repo_root/$NG")" \
    "YOUR REPORT STATES NO DISPOSITION, AND THIS WRAP-UP REQUIRES A SKEPTIC"
assert_contains "…and it sits on the required path (required|required-escalated)" \
    "$(grep -cE '^\s+required\|required-escalated\)' "$_repo_root/$NG")" "1"

echo "=== the schema annotation says what the tool does ==="
ann=$(disposition_annotation "$_repo_root/$SKILL")
assert_contains "the annotation was extracted (positive control)" "$ann" "disposition:"
assert_not_contains "it no longer says 'skeptic reports only'" "$ann" "skeptic reports only"
assert_not_contains "it no longer tells an ordinary worker to DELETE the line unconditionally" "$ann" "an ordinary worker DELETES the line"
assert_contains "it names the require path" "$ann" "--skeptic-decision require"
assert_contains "it says the author's role does not matter" "$ann" "WHETHER OR NOT you are a"
assert_contains "it says the tool REFUSES without it" "$ann" "REFUSES"
assert_contains "it says when deleting the line is right" "$ann" "only when no skeptic is required"
assert_contains "it cites the issue" "$ann" "#1512"

echo "=== potency: a planted copy carrying the pre-#1512 text is caught ==="
mkdir -p "$WORK/mut/$(dirname "$SKILL")"
# Rebuild the old annotation in the copy: same field line, old comment.
awk '
    /^disposition:/ { print "disposition: no-further-pass | second-pass   # skeptic reports only. report-init"; print "                         # seeds it as `TODO`; an ordinary worker DELETES the line."; skip=1; next }
    skip && /^[[:space:]]+#/ { next }
    { skip=0; print }
' "$_repo_root/$SKILL" > "$WORK/mut/$SKILL"
mann=$(disposition_annotation "$WORK/mut/$SKILL")
assert_contains "the mutant carries the old text" "$mann" "an ordinary worker DELETES the line"
assert_not_contains "…and would FAIL the require-path pin" "$mann" "--skeptic-decision require"
# The extractor refuses silently-empty input: no `disposition:` line -> empty.
: > "$WORK/empty.md"
assert_eq "no disposition line at all extracts EMPTY (so every contains-pin above would fail, never pass vacuously)" "$(disposition_annotation "$WORK/empty.md")" ""

_EXPECTED_ASSERTIONS=13   # count=exact (summary-honesty): every assertion above, once
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2; _th_fail
fi
th_summary_and_exit
