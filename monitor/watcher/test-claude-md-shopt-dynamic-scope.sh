#!/usr/bin/env bash
# CLAUDE.md's SHOPT-DYNAMIC-SCOPE block must be EXECUTABLE and true.
# your-org/nexus-code#1214.
#
# THE CLAIM THE BLOCK MAKES. `shopt` state is DYNAMIC, so every STATIC predicate
# for "which code runs with this option set" under-counts — and in a DIFFERENT
# DIRECTION per predicate. Scoping by FILE misses a SOURCED library. Scoping by
# LINE POSITION misses a function DEFINED before the set and CALLED after it.
# Two reviewers picked the two different wrong rules on the same class in the
# same week and both rules looked correct from the inside.
#
# WHY THE BLOCK IS EXECUTED RATHER THAN READ. A gotchas entry is prose, and
# prose cannot disagree with the tree. This branch spent four review rounds on
# exactly that failure — an enumeration written into a commit message, a fixture
# whose expectation came from its own filename, a comment left false by its own
# fix. So the four lines in the block are run here and their documented answers
# asserted, and the two wrong RULES are additionally demonstrated against
# planted fixtures, so a reader can see the under-count rather than take it.
#
# Run: bash monitor/watcher/test-claude-md-shopt-dynamic-scope.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
DOC="$_repo_root/CLAUDE.md"

# shellcheck disable=SC1091
. "$_test_dir/_test_helpers.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }
ck()   { if [[ "$2" == "$3" ]]; then pass "$1 ($2)"; else fail "$1 — got '$2' want '$3'"; fi; }

[[ -r "$DOC" ]] || { echo "CLAUDE.md not readable: $DOC" >&2; exit 1; }

# DECLARE EVERY FILE THIS GUARD READS, not just the obvious one. The first cut
# declared `CLAUDE.md` alone -- and this suite also GREPS
# `nullglob-bare-form.sh`, to assert that the rule the block prescribes is the
# one actually in force. A guard that reads a file it does not declare is the
# exact failure `_guard_population.sh` exists to prevent: the index then tells
# every worker "this guard does not read your diff" in the case where it does,
# and that sentence is indistinguishable from a correct exclusion.
GEN="$_test_dir/nullglob-bare-form.sh"
# shellcheck disable=SC1091
. "$_repo_root/monitor/_guard_population.sh"
gp_population() {
    printf '%s\n' "$DOC"
    printf '%s\n' "$GEN"
    # The sourced assertion library: its bytes decide what `ck` means here
    # (your-org/nexus-code#1219).
    printf '%s\n' monitor/watcher/_test_helpers.sh
}
gp_handle "$@"
th_claude_md_block_coverage SHOPT-DYNAMIC-SCOPE   # the entry's UNCHECKED share, in this suite's own output (#1239)

WORK=$(mktemp -d -t nexus-sds-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
echo "=== the block is present and non-vacuous ==="
# An empty extraction would make every execution below pass by running nothing —
# the #618 silent-zero shape, inside the probe.
BLK=$(awk '/BEGIN SHOPT-DYNAMIC-SCOPE/{f=1;next} /END SHOPT-DYNAMIC-SCOPE/{f=0} f' "$DOC" \
        | command grep -E "^[[:space:]]*bash -c " || true)
n=$(printf '%s\n' "$BLK" | command grep -c . || true)
ck "the block yields its command lines" "$n" "5"

# ---------------------------------------------------------------------------
echo "=== each documented line RUNS and answers what the block says ==="
# Run the extracted text verbatim, so the assertion is against the DOCUMENT and
# not against a paraphrase of it.
# Eval the line VERBATIM. Do NOT strip the trailing `# …` comment by regex: the
# commands contain `#` inside `"${#a[@]}"`, so a `s/#.*$//` truncates them
# mid-quote and the eval dies on an unterminated string — which is what the
# first draft of this helper did, and it reported the DOCUMENT as wrong when the
# instrument was. The trailing text is already a shell comment at that position,
# so there is nothing to strip.
_runline() { eval "$(printf '%s\n' "$BLK" | sed -n "$1p")" 2>&1; }
ck "line 1: a function DEFINED BEFORE the set is still affected" "$(_runline 1)" "0"
ck "line 2: the same function with the option OFF — glob stays LITERAL" "$(_runline 2)" "1"
case "$(_runline 3)" in
    *off*) pass "line 3: a child PROCESS does not inherit nullglob" ;;
    *)     fail "line 3: expected 'off', got '$(_runline 3)'" ;;
esac
case "$(_runline 4)" in
    *on*)  pass "line 4: …UNLESS BASHOPTS is EXPORTED — then it does" ;;
    *)     fail "line 4: expected 'on', got '$(_runline 4)'" ;;
esac
case "$(_runline 5)" in
    *on*)  pass "line 5: BASH_ENV is a carrier too — the one a nexus worker MEETS" ;;
    *)     fail "line 5: expected 'on', got '$(_runline 5)'" ;;
esac

# ---------------------------------------------------------------------------
echo "=== NARROWING THE PROSE GAP: every carrier the BLOCK demonstrates must be"
echo "    NAMED in the entry's prose ==="
# your-org/nexus-code#1214 sk2's closing observation, and it is the sharpest
# thing in that review: THIS SUITE EXECUTES COMMANDS AND GREPS FILES, SO IT
# CANNOT CHECK PROSE -- and sk2's F3 was precisely a prose defect that passed a
# green run. The entry's one ACTIONABLE sentence named BASHOPTS and SHELLOPTS
# and stopped, while the block below it demonstrated a third carrier. An
# executable block proves the commands do what they say; it proves nothing
# about the paragraph around them.
#
# This does not close that gap -- no assertion can check whether an argument is
# SOUND -- but it closes the specific hole that bit: a carrier the block
# DEMONSTRATES can no longer be missing from the prose that tells a reader what
# to check. It is a NAMING parity check, not a correctness check, and the
# distinction is stated here so a green is not overread.
# THE PROSE REGION MUST EXCLUDE THE BLOCK. The first cut stopped the leading
# slice at the END marker instead of the BEGIN marker, so `$_prose` CONTAINED
# the block -- and the parity check then compared the block against itself and
# could never fail. Measured: stripping BASH_ENV from the prose while leaving
# the block intact still gave 16/0. Caught by the potency test, which is the
# only reason to run one.
_prose=$(awk '/shopt` STATE IS DYNAMIC/{f=1} /BEGIN SHOPT-DYNAMIC-SCOPE/{exit} f' "$DOC"; awk '/END SHOPT-DYNAMIC-SCOPE/{f=1;next} f&&/^- \*\*/{exit} f' "$DOC")
# GUARD the extraction: an empty or block-contaminated region makes the parity
# check vacuous, which is exactly how it was broken.
if [[ -z "${_prose//[[:space:]]/}" ]]; then
    fail "the prose region extracted EMPTY — the parity check below would be vacuous"
elif [[ "$_prose" == *"BEGIN SHOPT-DYNAMIC-SCOPE"* || "$_prose" == *'bash -c '* ]]; then
    fail "the prose region CONTAINS the block — the parity check would compare it against itself"
else
    pass "the prose region is non-empty and excludes the block"
fi
_missing=""
for _c in BASHOPTS SHELLOPTS BASH_ENV; do
    case "$BLK" in
        *"$_c"*) case "$_prose" in *"$_c"*) : ;; *) _missing="$_missing $_c" ;; esac ;;
    esac
done
if [[ -z "${_missing// /}" ]]; then
    pass "every carrier demonstrated in the block is NAMED in the entry's prose"
else
    fail "the block demonstrates carrier(s) the prose never names:${_missing} — a reader who runs the named check and stops has been sent looking for the wrong thing"
fi
# POSITIVE CONTROL: the parity check must fire for a carrier absent from the
# prose, or the green above is equally consistent with a check that cannot fail.
if case "$_prose" in *NO_SUCH_CARRIER_TOKEN*) false ;; *) true ;; esac; then
    pass "…and the parity check FIRES for a token the prose does not name"
else
    fail "the parity control is inert"
fi

# ---------------------------------------------------------------------------
echo "=== WRONG RULE 1, demonstrated: scoping by FILE misses a SOURCED library ==="
cat > "$WORK/lib.sh" <<'LIB'
lib_count() { local -a a=( ./nope-glob-* ); printf '%s' "${#a[@]}"; }
LIB
if command grep -q 'shopt' "$WORK/lib.sh"; then
    fail "the library fixture mentions shopt — the demonstration proves nothing"
else
    pass "the library fixture provably contains NO \`shopt\` (the control is honest)"
fi
got=$(bash -c "shopt -s nullglob; . '$WORK/lib.sh'; lib_count")
ck "a shopt-FREE sourced library IS affected by its caller's option" "$got" "0"
got=$(bash -c ". '$WORK/lib.sh'; lib_count")
ck "…and unaffected when the caller has it off" "$got" "1"

# ---------------------------------------------------------------------------
echo "=== WRONG RULE 2, demonstrated: scoping by LINE POSITION misses a function ==="
# The function is defined at the TOP of the file and the `shopt` far BELOW it,
# which is the shape that fooled a line-position scanner: it skipped every site
# above the option and the function's BODY runs after it.
{ printf 'early_fn() { local -a a=( ./nope-glob-* ); printf "%%s" "${#a[@]}"; }\n'
  for _ in $(seq 1 20); do printf ': filler\n'; done
  printf 'shopt -s nullglob\n'
  printf 'early_fn\n'
} > "$WORK/late.sh"
_fn_line=$(command grep -n '^early_fn()' "$WORK/late.sh" | cut -d: -f1)
_sh_line=$(command grep -n '^shopt -s nullglob' "$WORK/late.sh" | cut -d: -f1)
if (( _fn_line < _sh_line )); then
    pass "the fixture really defines the function BEFORE the shopt (line $_fn_line < $_sh_line)"
else
    fail "fixture is not the shape under test: fn@$_fn_line shopt@$_sh_line"
fi
ck "a function defined ABOVE the shopt is affected when CALLED below it" \
   "$(bash "$WORK/late.sh")" "0"

# ---------------------------------------------------------------------------
echo "=== WRONG RULE 3, demonstrated: a CALL GRAPH has no root when the option"
echo "    is set OUTSIDE the corpus — and then it enumerates ZERO ==="
# The direction that matters most, because rules 1 and 2 both assume the setting
# site is IN the corpus. Here it is not: nullglob arrives via an exported
# BASHOPTS, the corpus contains no `shopt` at all, and a rule rooted at setting
# sites therefore has nothing to start from. A confident `none` that means
# `none I can see` — the silent-zero shape, in the most sophisticated of the
# three rules.
mkdir -p "$WORK/c3"
cat > "$WORK/c3/lib.sh" <<'L3'
consume() { local -a a=( ./nope-glob-* ); printf '%s' "${#a[@]}"; }
L3
cat > "$WORK/c3/main.sh" <<'M3'
. ./lib.sh
consume
M3
_n_shopt=$(command grep -lF 'shopt' "$WORK/c3/lib.sh" "$WORK/c3/main.sh" 2>/dev/null | command grep -c . || true)
ck "the corpus contains NO setting site to root a call graph at" "$_n_shopt" "0"
got=$(cd "$WORK/c3" && bash -c 'shopt -s nullglob; export BASHOPTS; bash ./main.sh')
ck "…and the code is affected ANYWAY, from outside the corpus" "$got" "0"

# ---------------------------------------------------------------------------
echo "=== the rule the block prescribes is the one this repo uses ==="
if [[ -r "$GEN" ]] && command grep -q 'shf_is_shell' "$GEN"; then
    pass "the enumerator keys on shf_is_shell (every shell file), not on a filename glob"
else
    fail "the enumerator does not use shf_is_shell — the prescribed rule is not the one in force"
fi

# ---------------------------------------------------------------------------
# EXPECTED-COUNT GUARD (your-org/nexus-code#807): 1 non-vacuity + 5 block lines
# + 3 sourced-library + 2 line-position + 2 call-graph + 3 prose-parity
# (region guard + parity + control) + 1 prescription.
EXPECTED=$(( 1 + 5 + 3 + 2 + 2 + 3 + 1 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
