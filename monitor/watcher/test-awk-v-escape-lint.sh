#!/usr/bin/env bash
# test-awk-v-escape-lint.sh — the `awk -v NAME=<shell expansion>` construct
# lint is potent, discriminating, and walks the population it claims
# (your-org/nexus-code#1420).
#
# WHY A SUITE FOR AN ADVISORY LINT. The lint exits 0 today whatever it finds,
# so nothing in the ordinary run would notice if its predicate stopped
# matching, its population enumerator returned an empty set, or its
# comment-stripping started swallowing code. Each of those is a silent zero,
# and an advisory lint that has gone blind reads EXACTLY like a corpus that
# has been cleaned. So: a positive control (a planted site IS flagged), the
# three negative controls the issue names (a literal value, `ENVIRON[]`, and
# the `( export x; awk … )` shape `#1378` used), the population sanity checks
# (the extensionless main CLI is in; a shebang-only file with no `.sh` is
# in), and the count reconciled against a declared total.
#
# Run: bash monitor/watcher/test-awk-v-escape-lint.sh
# Expected: ALL TESTS PASSED, exit 0.
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$_test_dir/../.." && pwd)
LINT="$REPO/monitor/watcher/awk-v-escape-lint.sh"

# The `--population` protocol (your-org/nexus-code#803): this suite forwards
# to the lint's own enumerator, never a copy of it. Above the first scan.
# shellcheck disable=SC1091
. "$REPO/monitor/_guard_population.sh"
gp_population() {
    bash "$LINT" --population
    printf '%s\n' monitor/watcher/test-awk-v-escape-lint.sh
}
gp_handle "$@"

# shellcheck disable=SC1091
. "$_test_dir/_test_helpers.sh"
# count=exact (summary-honesty): 8 positive + 6 negative + 4 marker + 2 polarity
# + 6 population + 2 empty-refusal + 2 self-declaration = 30.
EXPECTED_ASSERTIONS=30
[[ -x "$LINT" ]] || th_abort "missing or non-executable $LINT"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/avl-test-XXXXXX") || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. POSITIVE CONTROLS: a caller-supplied -v value is flagged, in every spelling"
P="$WORK/positive.sh"
cat > "$P" <<'EOF'
#!/usr/bin/env bash
v="$1"
awk -v x="$v" '{ print x }' file
awk -v y=$v '{ print y }' file
awk -v z="${v}suffix" '{ print z }' file
awk -F'\t' -v w="$(basename "$v")" '$1 == w' file
awk -v a="$v" \
    -v b="$v" '{ print a b }' file
printf '%s' "$v" | awk -v k="$v" '{ print k }'
EOF
out=$(bash "$LINT" --scan "$P" 2>&1)
assert_contains "double-quoted \$v is flagged" "$out" "positive.sh:3:"
assert_contains "bare \$v is flagged" "$out" "positive.sh:4:"
assert_contains "\${v} inside quotes is flagged" "$out" "positive.sh:5:"
assert_contains "a \$(…) substitution is flagged" "$out" "positive.sh:6:"
assert_contains "the first -v on a multi-line awk is flagged" "$out" "positive.sh:7:"
assert_contains "a -v on a CONTINUATION line is flagged (the site #1420 names in ng:3885 is this shape)" "$out" "positive.sh:8:"
assert_contains "an awk on the right of a pipe is flagged" "$out" "positive.sh:9:"
assert_contains "the count reconciles: 7 sites in the positive fixture" "$out" "sites: 7 flagged"

echo "== 2. NEGATIVE CONTROLS: literal values and the prescribed substitutes are NOT flagged"
N="$WORK/negative.sh"
cat > "$N" <<'EOF'
#!/usr/bin/env bash
v="$1"
awk -v x=1 '{ print x }' file
awk -v sep=, -v fenced=yes '{ print sep fenced }' file
awk -v lit='$notexpanded' '{ print lit }' file
( export _W="$v"; awk 'BEGIN { w = ENVIRON["_W"] } $1 == w' file )
awk 'BEGIN { w = ENVIRON["_W"] } $1 == w' file
grep -v "$v" file        # a -v that is not awk's
# awk -v x="$v" in a COMMENT is not a site
EOF
out=$(bash "$LINT" --scan "$N" 2>&1)
assert_contains "the negative fixture yields ZERO flagged sites" "$out" "sites: 0 flagged"
assert_not_contains "…a literal -v value is not a site" "$out" "negative.sh:3:"
assert_not_contains "…a single-quoted \$ is literal to the shell and not a site" "$out" "negative.sh:5:"
assert_not_contains "…the ( export …; awk ENVIRON[] ) shape is not a site" "$out" "negative.sh:6:"
assert_not_contains "…grep -v is not awk -v" "$out" "negative.sh:8:"
assert_not_contains "…a COMMENT is stripped before matching" "$out" "negative.sh:9:"

echo "== 3. the EXEMPTION marker needs a reason, and an exempted site is still PRINTED"
E="$WORK/exempt.sh"
cat > "$E" <<'EOF'
#!/usr/bin/env bash
awk -v n="$line_no" 'NR == n' file   # awk-v-escape-lint: literal-only — a line number, digits only
awk -v m="$line_no" 'NR == m' file   # awk-v-escape-lint: literal-only
EOF
out=$(bash "$LINT" --scan "$E" 2>&1)
assert_contains "a marker WITH a reason exempts (counted, printed)" "$out" "1 exempted by a reason-bearing marker"
assert_contains "…and the exempted site is still listed" "$out" "exempt.sh:2:EXEMPT:"
assert_contains "…under its own (exempt) label" "$out" "(exempt) "
assert_contains "a BARE marker does not exempt — the site stays flagged" "$out" "exempt.sh:3:"
assert_contains "…so the flagged count is 1" "$out" "sites: 1 flagged"

echo "== 4. POLARITY: advisory exits 0 on a flagged corpus; --strict exits 1; strict is 0 when clean"
bash "$LINT" --scan "$P" >/dev/null 2>&1; rc=$?
assert_eq "advisory (--scan) exits 0 even with 7 sites" "$rc" "0"
# --strict scans the REAL population, which is not clean today; the polarity
# claim is asserted on the exit code alone and the count is not pinned.
bash "$LINT" --strict >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 || "$rc" == 1 ]] && assert_eq "--strict exits 0 or 1 (never an unhandled status)" "0" "0" \
                             || assert_eq "--strict exits 0 or 1 (never an unhandled status)" "$rc" "0-or-1"

echo "== 5. POPULATION SANITY: the shared predicate, over the whole tracked tree"
pop=$(bash "$LINT" --files 2>/dev/null)
n_pop=$(printf '%s\n' "$pop" | command grep -c . || true)
assert_contains "the extensionless main CLI (monitor/ng) is IN the population — a *.sh glob would miss it" "$pop" "monitor/ng"
assert_contains "a shebang-only file with no .sh suffix is in (monitor/notifywrap/sandbox-notify)" "$pop" "monitor/notifywrap/sandbox-notify"
# The DECLARED population (`--population`) names the lint's own source and the
# shared predicate explicitly; `--files` is tracked-only (`git ls-files`), so
# a not-yet-staged lint would be absent from it — the #1054 trackedness axis.
decl=$(bash "$LINT" --population 2>/dev/null)
assert_contains "the lint DECLARES its own source in its population" "$decl" "monitor/watcher/awk-v-escape-lint.sh"
assert_contains "…and the shared shell predicate it derives the corpus from" "$decl" "monitor/shell-files.sh"
if (( n_pop >= 400 )); then _th_pass; printf '  PASS: the population is plausibly sized (%d shell files; floor 400)\n' "$n_pop"
else _th_fail; printf '  FAIL: population is %d files — below the 400 floor, the enumerator is broken (#792)\n' "$n_pop" >&2; fi
# The count printed by a report run must equal the enumerator's own count —
# the two are computed by the same function, so a disagreement means the
# report is describing a different corpus than it walked.
rep=$(bash "$LINT" 2>/dev/null | sed -n '1p')
assert_contains "the report header names the same population size the enumerator returns" "$rep" "population $n_pop shell files"
assert_contains "the report header carries the ref it was measured at" "$rep" "ref "

echo "== 6. an EMPTY population is REFUSED (rc 3), never reported as a clean sweep"
# Drive the lint from a directory that is not a git repository: `git ls-files`
# yields nothing, and the refusal must be loud rather than `0 flagged`.
EMPTY="$WORK/notrepo"; mkdir -p "$EMPTY/monitor/watcher"
cp "$LINT" "$EMPTY/monitor/watcher/"; cp "$REPO/monitor/shell-files.sh" "$REPO/monitor/_guard_population.sh" "$EMPTY/monitor/"
out=$(cd "$EMPTY" && bash monitor/watcher/awk-v-escape-lint.sh 2>&1); rc=$?
assert_eq "no population -> exit 3" "$rc" "3"
assert_contains "…and it says why" "$out" "population is EMPTY"

# EXPECTED-COUNT GUARD (your-org/nexus-code#807): an assertion that did not
# execute must not read as a pass.
if (( PASS + FAIL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi
th_summary_and_exit
