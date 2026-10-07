#!/usr/bin/env bash
# test-lint-suites-declare-population.sh — every lint suite must implement the
# `--population` protocol, so no lint can start out INVISIBLE to
# `guards-for-diff` (your-org/nexus-code#1747).
#
# WHY. A guard that does not declare a population is invisible to the reverse
# index: it is never SELECTED, and it does not appear under CONSIDERED AND
# EXCLUDED either — only in an anonymous blind-spot count. Lint suites are the
# sharpest case, because their last case runs the lint over the REAL tree, so
# their population is the whole corpus and almost any edit can redden them.
# Five did not declare. One of them, test-textguard-lint.sh, shipped a CI red on
# PR #1745 that the pre-push gate could not have flagged. This file is the
# ratchet: the next `test-*lint*.sh` lands red until it declares.
#
# THE POPULATION OF THIS RATCHET is every `test-*lint*.sh` under monitor/, at
# any depth, tracked or untracked-not-ignored:
#
#     git ls-files -c -o --exclude-standard -- ':(glob)monitor/**/test-*lint*.sh'
#
# `:(glob)` is the form, not a workaround: without it git's pathspec `*` crosses
# `/` (CLAUDE.md, PATHSPEC-GLOB-DEPTH). Here the bare form would happen to give
# the same answer, because `**/` is what is wanted — but the prefix is what makes
# `**/` mean "any depth, including zero" rather than a literal. Untracked files
# are included on purpose: the moment a new lint suite is most likely to be
# invisible is before its first `git add` (#1054).
#
# THE PREDICATE is "the file CALLS the protocol": a line whose code (not a
# comment) begins with the `gp_handle` call on `"$@"`, AND a `gp_population()`
# definition. Applicability is the file NAME, conformance is the assertion —
# never the reverse (`_guard_population.sh`'s second rule): keying the
# population on "already declares" would delete exactly the files this exists
# to flag.
#
# COVERAGE BOUNDARY, stated: this checks the protocol is WIRED, not that the
# declared population is RIGHT. Whether a probe succeeds, is non-empty and names
# only existing paths is test-guards-for-diff.sh's job (every manifest row is
# probed there). Lint suites not named `test-*lint*.sh` are outside this
# ratchet; the generic residual is counted by guards-for-diff.sh itself.
#
# Run: bash monitor/watcher/test-lint-suites-declare-population.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

# THE ENUMERATOR — one function, called by `gp_population` and by the live check
# below, so the two cannot disagree.
_lsdp_lint_suites() {
    git -C "$REPO_ROOT" ls-files -c -o --exclude-standard -- ':(glob)monitor/**/test-*lint*.sh'
}

# --- this ratchet is itself a declaring guard (and its own name matches) -----
# PLACED HERE, above the first thing this suite prints: `gp_handle` EXITS when
# it handles the flag. Its verdict reads the bytes of every enumerated suite.
. "$REPO_ROOT/monitor/_guard_population.sh"
gp_population() { _lsdp_lint_suites; }
gp_handle "$@"

. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# _lsdp_declares <file> — rc 0 iff the file wires the protocol. The call token
# is ASSEMBLED rather than written whole, so the regex below says exactly what
# it matches; `-F` is not usable because the match must be anchored to code at
# the start of a line (a comment that MENTIONS the call is not a call).
_GPH='gp_handle'
_lsdp_declares() {
    local f="$1"
    command grep -qE "^[[:space:]]*${_GPH}[[:space:]]+\"\\\$@\"" "$f" || return 1
    command grep -qE '^[[:space:]]*gp_population[[:space:]]*\(\)' "$f" || return 1
    return 0
}

# _lsdp_offenders — read paths on stdin, print the ones that do not declare.
# A path that does not exist is printed too, tagged: an unreadable file must
# never pass as "declares" by default.
_lsdp_offenders() {
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        if [[ ! -r "$f" ]]; then printf '%s (unreadable)\n' "$f"; continue; fi
        _lsdp_declares "$f" || printf '%s\n' "$f"
    done
}

echo '=== positive and negative controls on planted suites ==='
_mk() {   # _mk <name> <line…>
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "${@:2}"; } > "$WORK/$1"
}
_mk test-planted-declares-lint.sh \
    '. "$d/_guard_population.sh"' \
    'gp_population() { printf "%s\n" x; }' \
    "${_GPH} \"\$@\""
_mk test-planted-silent-lint.sh \
    'echo "runs the lint over the real tree and declares nothing"'
_mk test-planted-comment-only-lint.sh \
    'gp_population() { printf "%s\n" x; }' \
    "# ${_GPH} \"\$@\" — mentioned in a comment, never called"
_mk test-planted-no-impl-lint.sh \
    "${_GPH} \"\$@\""

_fix_out=$(printf '%s\n' \
    "$WORK/test-planted-declares-lint.sh" \
    "$WORK/test-planted-silent-lint.sh" \
    "$WORK/test-planted-comment-only-lint.sh" \
    "$WORK/test-planted-no-impl-lint.sh" \
    "$WORK/test-planted-absent-lint.sh" | _lsdp_offenders)
_flagged() { command grep -qF -- "$1" <<<"$_fix_out"; }

_flagged test-planted-silent-lint.sh && r=flagged || r=missed
assert_eq "POSITIVE: a lint suite that declares nothing is flagged" "$r" flagged
_flagged test-planted-comment-only-lint.sh && r=flagged || r=missed
assert_eq "POSITIVE: a call that exists only in a comment is flagged" "$r" flagged
_flagged test-planted-no-impl-lint.sh && r=flagged || r=missed
assert_eq "POSITIVE: a call with no gp_population() implementation is flagged" "$r" flagged
_flagged 'test-planted-absent-lint.sh (unreadable)' && r=flagged || r=missed
assert_eq "POSITIVE: a path that cannot be read is flagged, not passed" "$r" flagged
_flagged test-planted-declares-lint.sh && r=flagged || r=clean
assert_eq "NEGATIVE: a suite that wires the protocol is NOT flagged" "$r" clean

echo '=== the live tree: every test-*lint*.sh declares a population ==='
_suites=$(_lsdp_lint_suites)
_n=$(printf '%s\n' "$_suites" | command grep -c . || true)
# NON-VACUITY: an enumeration that went blind would make the check below a
# confident clean bill over nothing. Measured 18 at this file's birth (17 lint
# suites plus this one); the floor sits under it so ordinary pruning does not
# trip it, while a broken pathspec (0) or a depth-1-only one (2) does.
assert_eq "the enumeration is non-vacuous (found $_n, floor 12)" \
    "$(( _n >= 12 ? 1 : 0 ))" 1
# An INDEPENDENT instrument for the same set: `find` does not share git's
# pathspec semantics, so a pathspec mistake makes the two disagree. Ignored
# files are dropped from the find side, because ls-files excludes them.
_find_set=$(cd "$REPO_ROOT" && find monitor -type f -name 'test-*lint*.sh' -print \
    | while IFS= read -r f; do git check-ignore -q -- "$f" || printf '%s\n' "$f"; done | LC_ALL=C sort)
_git_set=$(printf '%s\n' "$_suites" | LC_ALL=C sort)
assert_eq "git's enumeration equals find's (pathspec sanity)" "$_git_set" "$_find_set"

_live_out=$(cd "$REPO_ROOT" && printf '%s\n' "$_suites" | _lsdp_offenders)
if [[ -n "$_live_out" ]]; then
    printf '  lint suites that are INVISIBLE to guards-for-diff:\n' >&2
    printf '%s\n' "$_live_out" | sed 's/^/    /' >&2
    printf '  Fix: source monitor/_guard_population.sh, define gp_population() calling\n' >&2
    printf '  the lint'"'"'s OWN enumerator (e.g. its --files mode), call gp_handle on "$@"\n' >&2
    printf '  before any output, and add a row to guard-populations.manifest.\n' >&2
fi
assert_eq "no test-*lint*.sh is invisible to guards-for-diff" "${_live_out:-none}" none

EXPECTED=8
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
