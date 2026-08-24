#!/usr/bin/env bash
# A refusal must NAME what it refused — your-org/nexus-code#660.
#
# `jupyter-up.sh:115` was a verbatim instance of the #642 rule:
#
#     PROJECT_DIR=$(cd "$PROJECT_DIR" ... ) || die "... $PROJECT_DIR"
#
# A failed command substitution assigns the EMPTY STRING and only THEN
# runs the `||` arm, so the arm read a variable the failed assignment had
# already clobbered:
#
#     $ jupyter-up.sh /definitely/not/here
#     jupyter-up: project dir not found:
#
# Nothing after the colon. And PROJECT_DIR defaults to $PWD (or
# $NEXUS_ROOT/work under --root), so in the common case there is no
# argument on the command line to reconstruct it from either.
#
# THE ASSERTION THAT MATTERS is the third one: a test checking only
# "non-zero exit plus a 'project dir not found' substring" passes against
# the BROKEN code. That is why this class keeps landing — the obvious
# test is satisfied by construction.
#
# Run: bash monitor/watcher/test-jupyter-up-refusal.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
JU="${JU_BIN:-$_repo_root/monitor/jupyter-up.sh}"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

[[ -r "$JU" ]] || { echo "not readable: $JU" >&2; exit 1; }

WORK=$(mktemp -d -t nexus-660-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "=== a missing project dir is refused, and NAMED ==="
MISSING="$WORK/definitely/not/here"
out=$(NEXUS_ROOT="${NEXUS_ROOT:-$_repo_root}" bash "$JU" "$MISSING" 2>&1); rc=$?

if (( rc != 0 )); then pass "refuses (rc=$rc)"; else fail "did NOT refuse (rc=0)"; fi

if [[ "$out" == *"$MISSING"* ]]; then
    pass "refusal names the path"
else
    fail "refusal does not name the path — got: $out"
fi

# The load-bearing one. `project dir not found:` with nothing after it is
# the exact broken output, and it satisfies both assertions above only
# because they are too weak — hence this explicit shape check.
if grep -qE 'project dir not found:[[:space:]]*$' <<<"$out"; then
    fail "refusal ends at the colon — the clobbered-variable bug is back: $out"
else
    pass "refusal does not end at the colon (empty path)"
fi

echo "=== CDPATH cannot make check and use disagree ==="
# The same defect one level down: with CDPATH set, `cd <relative>`
# resolves against a search path the caller never consulted, so the
# directory entered is not the one that was checked.
mkdir -p "$WORK/searchpath/decoy" "$WORK/cwd"
out=$(cd "$WORK/cwd" && CDPATH="$WORK/searchpath" \
      NEXUS_ROOT="${NEXUS_ROOT:-$_repo_root}" bash "$JU" decoy 2>&1); rc=$?
if (( rc != 0 )) && [[ "$out" != *"$WORK/searchpath/decoy"* ]]; then
    pass "a CDPATH-only match is not silently entered"
elif (( rc == 0 )); then
    fail "CDPATH match was ENTERED — check and use disagree again"
else
    pass "refused without resolving through CDPATH"
fi

echo "=== the --venv site was already correct and must stay that way ==="
# It reports \$OPT_VENV — a DIFFERENT variable the assignment does not
# touch. The correct and the broken form sat twelve lines apart in one
# file, which is why this survived review; pin the correct one so a
# future tidy-up does not "make them consistent" in the wrong direction.
if grep -qE 'venv_abs=\$\(.*\).*\|\|.*die.*\$OPT_VENV' "$JU"; then
    pass "--venv refusal still reports OPT_VENV (unclobbered)"
else
    fail "--venv refusal no longer reports \$OPT_VENV — check it did not inherit the #660 shape"
fi

printf '\n=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
exit 1
