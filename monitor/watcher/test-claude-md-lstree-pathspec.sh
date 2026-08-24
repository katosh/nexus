#!/usr/bin/env bash
# Executes the `git ls-tree` confident-zero pair CLAUDE.md documents
# (your-org/nexus-code#770), against this repo's own HEAD.
#
# Run: bash monitor/watcher/test-claude-md-lstree-pathspec.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS. `git ls-tree` pathspecs are PATH PREFIXES rooted at
# the given tree; `git ls-files` pathspecs are GLOBS. Hand both the same
# `'*.sh'` and ls-tree answers `0` at rc 0 while ls-files answers with every
# tracked `.sh`. Nothing errors, nothing warns — the caller gets a confident
# zero and reads it as "the population is empty". That is this workspace's
# dominant defect class, and #770 is where it fired INSIDE a probe written to
# attack an emptiness claim: a skeptic enumerating the #720 population this way
# got `0` and was saved only by sanity-checking against a known total.
#
# CLAUDE.md now carries the pair in a delimited fenced block. This suite
# extracts that block VERBATIM and runs it, on the same contract as the #618
# remedies block: a documented form that stops behaving as documented turns the
# suite red rather than quietly misinforming the next reader.
#
# NON-VACUITY. "Both forms ran" proves nothing on its own — a botched
# extraction yielding zero commands would pass every assertion by having none
# to make (#618's own shape). So:
#   Control A — the extracted command count is PINNED at 2.
#   Control B — the CORRECT form's answer is checked against an INDEPENDENT
#               known total (`find` + `git ls-files` intersection), not merely
#               against "greater than zero". A guard whose expectation comes
#               from the thing under test is measuring itself.
#   Control C — the WRONG form's exit status is asserted to be 0. The defect is
#               not that it fails; it is that it SUCCEEDS while lying, and a
#               remedy that only checked hit counts would miss the day git
#               starts erroring instead (which would be a fix worth noticing).
#
# COVERAGE BOUNDARY, on the axis the mechanism varies on: this pins GIT's
# pathspec semantics, and those are a property of the git BINARY. Measured
# identical on git 2.17.1 and 2.33.0 (16 releases apart), and the assertion is
# written so that a future git which taught ls-tree to glob would RED here —
# that is the intended signal, and the remedy then is to update CLAUDE.md, not
# to relax this file. The running git version is printed on failure for exactly
# that diagnosis. NOT covered: pathspec magic (`:(glob)`, `:(icase)`), which
# would make ls-tree work and is precisely what the doc tells you not to need.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "got [$2] want [$3]"; }

GITV=$(git --version 2>&1)

# ---- extract the documented pair from CLAUDE.md ---------------------------
echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
BEGIN_MARK='<!-- BEGIN LSTREE-PATHSPEC -->'
END_MARK='<!-- END LSTREE-PATHSPEC -->'

if [[ -r "$CLAUDE_MD" ]]; then
    ok "CLAUDE.md is readable at $CLAUDE_MD"
else
    bad "CLAUDE.md not readable at $CLAUDE_MD" "cannot extract"
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi

# Strip the block's leading indentation and the ```zsh fences, keep the two
# commands, drop the trailing `# comment` so the line is runnable as written.
FORMS=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]+#.*$//' \
    | grep -E '^git ')

n_forms=$(printf '%s\n' "$FORMS" | grep -c '^git ' || true)
# Control A — a botched extraction must not pass by having nothing to run.
assert_eq "Control A: exactly 2 git forms extracted from CLAUDE.md" "$n_forms" "2"

# NO `| head -1` here, deliberately. `head` closes the pipe early, `grep` takes
# SIGPIPE, and this file runs under `set -o pipefail` — which is the #622 class
# and would put two new rows into `test-early-exit-reader-manifest.sh`'s pinned
# population. (It did, on the first push; the manifest guard caught it, and its
# own message is right that regenerating is not the fix.) The `head` was
# redundant anyway: Control A above pins the extracted form count at exactly 2,
# so a second `ls-tree` line reds there first — the guard is upstream of the
# defensive slice, which is the better place for it.
wrong_form=$(printf '%s\n' "$FORMS" | grep '^git ls-tree')
right_form=$(printf '%s\n' "$FORMS" | grep '^git ls-files')
[[ -n "$wrong_form" ]] && ok "the ls-tree (WRONG) form was extracted" \
    || bad "the ls-tree (WRONG) form was extracted" "block shape changed"
[[ -n "$right_form" ]] && ok "the ls-files (CORRECT) form was extracted" \
    || bad "the ls-files (CORRECT) form was extracted" "block shape changed"

if (( FAIL > 0 )); then
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi

# ---- Control B: an INDEPENDENT known total --------------------------------
echo '=== Control B: the CORRECT form matches an independently derived total ==='
# Derived without either form under test: every TRACKED path ending in .sh.
# `git ls-files` with no pathspec is not the thing being tested (the pathspec
# is), so filtering its full output in the shell is a genuine second opinion.
known_total=$(cd "$REPO_ROOT" && git ls-files | grep -c '\.sh$' || true)
right_n=$(cd "$REPO_ROOT" && eval "$right_form" | grep -c . || true)
assert_eq "Control B: ls-files '*.sh' == the shell-filtered tracked total" \
    "$right_n" "$known_total"
[[ "$known_total" -gt 0 ]] && ok "the known total is non-empty ($known_total)" \
    || bad "the known total is non-empty" "no tracked .sh files — harness is blind"

# ---- the documented contrast ----------------------------------------------
echo '=== The documented pair: same repo, same ref, same pathspec ==='
wrong_out=$(cd "$REPO_ROOT" && eval "$wrong_form" 2>/dev/null); wrong_rc=$?
wrong_n=$(printf '%s' "$wrong_out" | grep -c . || true)

# Control C — the defect is that it SUCCEEDS while lying.
assert_eq "Control C: the ls-tree form exits 0 (it is SILENT, not broken)" \
    "$wrong_rc" "0"

if [[ "$wrong_n" == "0" ]]; then
    ok "ls-tree with a glob pathspec returns a CONFIDENT ZERO, as documented"
else
    bad "ls-tree with a glob pathspec returns a CONFIDENT ZERO, as documented" \
        "got $wrong_n hits under $GITV — if this git taught ls-tree to glob, UPDATE CLAUDE.md's LSTREE-PATHSPEC block; do not relax this file"
fi

if (( wrong_n != right_n )); then
    ok "the two documented forms DISAGREE ($wrong_n vs $right_n) — the whole point"
else
    bad "the two documented forms DISAGREE" \
        "both returned $right_n under $GITV; the trap this bullet warns about no longer reproduces"
fi

# The second trap in the same bullet: no `-r` prints the ONE tree object.
echo '=== The second trap: ls-tree without -r prints a TREE, not the files ==='
norec=$(cd "$REPO_ROOT" && git ls-tree HEAD monitor | grep -c . || true)
rec=$(cd "$REPO_ROOT" && git ls-tree -r HEAD monitor | grep -c . || true)
assert_eq "a non-recursive ls-tree of a directory yields exactly 1 entry" "$norec" "1"
[[ "$rec" -gt "$norec" ]] && ok "…while -r yields the $rec files actually under it" \
    || bad "…while -r yields the files actually under it" "got rec=$rec norec=$norec"

echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d assertions, %s)\n' "$PASS" "$GITV"
    exit 0
else
    printf '%d PASSED, %d FAILED (%s)\n' "$PASS" "$FAIL" "$GITV" >&2
    exit 1
fi
