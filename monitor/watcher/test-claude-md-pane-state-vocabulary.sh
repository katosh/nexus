#!/usr/bin/env bash
# CLAUDE.md's pane-state vocabulary must equal `pane-state.sh --states`, in
# BOTH directions — your-org/nexus-code#1214.
#
# THE DEFECT THIS PINS. CLAUDE.md hand-enumerated the emitted states and, one
# sentence later, hand-stated their count. The list held ELEVEN; the prose said
# twelve; and the member the list omitted was `unknown` — the state that means
# "could not look at all".
#
# That is the worst available omission, for a reason nine lines further down the
# same file: "Never make a kill decision from a state you enumerated by hand",
# whose stated rationale is that any denylist with a permissive default arm
# retires whatever its author did not think of. A reader matching the short list
# found no arm for "couldn't look" and fell to the else branch — the permissive
# default that very bullet exists to forbid. `empty` already has an incident of
# exactly that shape (`#603`, a pane 4m38s into a verification pass with a
# queued message), and `unknown` is STRICTLY WORSE, because `empty` at least
# means the pane was READ.
#
# AND IT WAS SELF-CONFIRMING. The prose supplied a count, so a skimming reader
# took the number from the prose rather than recounting the list. The document's
# own number is what stopped the check. So this suite asserts the SET in both
# directions and, separately, that no hand-maintained count has come back: a
# list beside a count is two things to keep in sync, and keeping them in sync by
# care is what failed.
#
# WHY A SUITE RATHER THAN A CAREFUL EDIT. The edit was one line. The defect was
# not the line, it was that nothing could disagree with it — the same shape as
# `#1176`, where a fixture's expectation came from its own filename. A
# correction that leaves the next drift undetectable has fixed the instance and
# not the mechanism.
#
# Run: bash monitor/watcher/test-claude-md-pane-state-vocabulary.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HELPER="$_repo_root/monitor/pane-state.sh"
DOC="$_repo_root/CLAUDE.md"

# ── this suite DECLARES its own population (the --population protocol) ──────
# your-org/nexus-code#1219. CLAUDE.md is the document this suite EXECUTES, so
# an edit to the fenced block it pins is exactly the edit that can change its
# verdict — and until #1219 no such edit could SELECT it: a suite that declares
# no population is INVISIBLE to `guards-for-diff` rather than excluded by it
# (#1078), appearing in neither SELECTED nor CONSIDERED AND EXCLUDED, so its
# absence reads as a considered exclusion. `gp_handle` adds this suite's own
# path and `monitor/_guard_population.sh` for free; everything else is declared
# because this suite READS ITS BYTES to reach a verdict.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        CLAUDE.md \
        monitor/pane-state.sh \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"

# shellcheck disable=SC1091
. "$_test_dir/_test_helpers.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

[[ -x "$HELPER" ]] || { echo "helper not executable: $HELPER" >&2; exit 1; }
[[ -r "$DOC"    ]] || { echo "CLAUDE.md not readable: $DOC" >&2; exit 1; }

# Extract the `state=<a|b|c>` alternation from an arbitrary TEXT, one state per
# line. Taking text rather than reading the file is what lets the positive
# controls below feed it a PLANTED list — a comparison never seen to fail is not
# evidence that it can.
extract_states() {
    printf '%s' "$1" \
      | tr -d '\n' \
      | sed -E 's/.*`state=<//; s/>[[:space:]]*active=<0\|1>.*//' \
      | tr -d ' ' \
      | tr '|' '\n' \
      | sed -E '/^$/d'
}

DOC_TEXT=$(cat "$DOC")
doc_states=$(extract_states "$DOC_TEXT")
live_states=$("$HELPER" --states 2>/dev/null)

# ---------------------------------------------------------------------------
echo "=== the instrument itself is not vacuous ==="
# A silently-empty extraction would make every set comparison below pass by
# having nothing to compare — the #618 silent-zero shape, inside the probe.
n_doc=$(printf '%s\n' "$doc_states" | sed -E '/^$/d' | wc -l)
n_live=$(printf '%s\n' "$live_states" | sed -E '/^$/d' | wc -l)
if (( n_doc >= 5 )); then
    pass "the CLAUDE.md block yields a plausible list ($n_doc states)"
else
    fail "extraction from CLAUDE.md yielded $n_doc states — the parse broke, so every comparison below is vacuous"
fi
if (( n_live >= 5 )); then
    pass "\`--states\` yields a plausible list ($n_live states)"
else
    fail "\`pane-state.sh --states\` yielded $n_live states"
fi

# ---------------------------------------------------------------------------
echo "=== the two agree, in BOTH directions ==="
missing=$(comm -23 <(printf '%s\n' "$live_states" | sort -u) <(printf '%s\n' "$doc_states" | sort -u) | tr '\n' ' ')
extra=$(comm -13 <(printf '%s\n' "$live_states" | sort -u) <(printf '%s\n' "$doc_states" | sort -u) | tr '\n' ' ')
if [[ -z "${missing// /}" ]]; then
    pass "every emitted state appears in CLAUDE.md (no OMISSION — the #1214 defect)"
else
    fail "CLAUDE.md OMITS emitted state(s): ${missing}— a reader matching this list falls to a permissive else branch"
fi
if [[ -z "${extra// /}" ]]; then
    pass "CLAUDE.md invents no state the helper cannot emit"
else
    fail "CLAUDE.md lists state(s) the helper never emits: ${extra}"
fi

# ---------------------------------------------------------------------------
echo "=== positive controls — the comparison is load-bearing ==="
# Exactly the historical defect: drop `unknown` from a copy of the real block
# and the check must object. Without this, a green above is equally consistent
# with a comparison that cannot fail.
# FLATTEN BEFORE PLANTING. The real block WRAPS, so `unknown` sits on a
# different line from the `|` that precedes it and a line-oriented sed cannot
# match across the break. The first cut of this control did not flatten, so it
# planted NOTHING and reported the defect as undetectable -- a positive control
# failing for its own reason, which is exactly what it is there to expose.
planted_missing=$(printf '%s' "$DOC_TEXT" | tr -d '\n' | sed -E 's/\|[[:space:]]*unknown>/>/')
pm=$(extract_states "$planted_missing")
if [[ -n "$(comm -23 <(printf '%s\n' "$live_states" | sort -u) <(printf '%s\n' "$pm" | sort -u))" ]]; then
    pass "a planted list with \`unknown\` REMOVED is detected (the #1214 defect reproduced)"
else
    fail "a planted list missing \`unknown\` was NOT detected — this suite cannot see the defect it exists for"
fi
planted_extra=$(printf '%s' "$DOC_TEXT" | sed -E 's/`state=<idle\|/`state=<notastate|idle|/')
pe=$(extract_states "$planted_extra")
if [[ -n "$(comm -13 <(printf '%s\n' "$live_states" | sort -u) <(printf '%s\n' "$pe" | sort -u))" ]]; then
    pass "a planted INVENTED state is detected"
else
    fail "a planted invented state was NOT detected"
fi

# ---------------------------------------------------------------------------
echo "=== no hand-maintained COUNT has come back ==="
# The count is what made the original defect self-confirming: the prose supplied
# a number, so a reader took it instead of recounting. A list and a count are two
# things to keep in sync; this suite keeps the list honest and the count must not
# return to be kept honest by care.
# HERESTRING, NOT A PIPE (your-org/nexus-code#1214). Under this file's
# `set -uo pipefail`, `printf … | grep -q` is a COIN FLIP on a document this
# size: `grep -q` exits the instant it matches, `printf` takes SIGPIPE on the
# remaining ~29 KB of a 93 KB CLAUDE.md, and pipefail hands the `if` a 141.
# Measured over 200 runs of exactly this pattern with a count PLANTED EARLY in
# the real CLAUDE.md: rc 141 in 97, and the `if` took the ELSE arm — printing
# `PASS: no hand-maintained state count` while one was RIGHT THERE — in 75.
# The herestring form: 0 of 200. It is nondeterministic AND position-dependent
# (a match near the END of the document never trips it, because grep must read
# to the end before exiting), so the guard's correctness depended on WHERE in
# the document the offending text sat — precisely what it must be agnostic to.
if grep -qE 'There are \*\*(five|six|seven|eight|nine|ten|eleven|twelve|thirteen|[0-9]+)\*\* states' <<<"$DOC_TEXT"; then
    fail "a hand-maintained state COUNT is back in CLAUDE.md — that is the half that made the omission self-confirming"
else
    pass "no hand-maintained state count in CLAUDE.md"
fi

# ---------------------------------------------------------------------------
# EXPECTED-COUNT GUARD (your-org/nexus-code#807): 2 non-vacuity + 2 set
# directions + 2 positive controls + 1 count check.
EXPECTED=$(( 2 + 2 + 2 + 1 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
