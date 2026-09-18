#!/usr/bin/env bash
# test-claude-md-shell-wrapped-coreutil.sh — execute CLAUDE.md's
# SHELL-WRAPPED-COREUTIL block.
#
# WHY THIS SUITE EXISTS. your-org/nexus-code#849: a shell FUNCTION shadowing a
# coreutil routes a command to a different implementation with different
# argument semantics, and the rejected argument comes back as a CLEAN ZERO, not
# an error. On the reporting host `find` is a function routing to `bfs`, which
# rejects the relative timestamps GNU findutils accepts; `find reports -name
# '*.md' -newermt '12 hours ago'` returned 0 across the whole corpus, one step
# from filing "five skeptics delivered verdicts and none wrote a report". The
# rejection goes to stderr, agents append `2>/dev/null`, and the answer is
# shaped exactly like a true negative.
#
# WHAT THIS SUITE ASSERTS, AND — MORE IMPORTANTLY — WHAT IT REFUSES TO:
#
#   IT ASSERTS THE REMEDIES RETURN A PLANTED COUNT. That is portable: a remedy
#   that works only where the defect exists is not a remedy.
#
#   IT DOES **NOT** ASSERT THE BROKEN FORM RETURNS ZERO, and this is the whole
#   design constraint (#849's own closing paragraph). The exposure is a
#   property of the OPERATOR'S SHELL CONFIG and of which implementation is
#   installed — not of this repository. On a host whose `find` is GNU
#   findutils, `-newermt '12 hours ago'` is CORRECT and returns the planted
#   count, so a suite asserting zero would go red for the right reason and the
#   wrong cause. That is the issue's own defect reproduced inside its
#   regression test, and it is why the wrapper-dependent arm below SKIPS with
#   its reason named rather than asserting.
#
#   IT ASSERTS THE SECOND TRAP UNCONDITIONALLY, because that one IS universal:
#   `cmd 2>&1 | wc -l` counts DIAGNOSTICS AS DATA. The first probe in #849
#   returned 10 — a plausible file count that was ten lines of error text — and
#   what exposed it was four different expressions all returning exactly 10.
#   No wrapper is needed to demonstrate it and none is used.
#
# Run: bash monitor/watcher/test-claude-md-shell-wrapped-coreutil.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

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
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"
th_claude_md_block_coverage SHELL-WRAPPED-COREUTIL   # the entry's UNCHECKED share, in this suite's own output (#1239)

WORK=$(mktemp -d) || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# ---- assertion-count guard (your-org/nexus-code#946 F6) ------------------
# A missing assert_* helper (a typo -> rc 127) is counted by NOTHING: the suite
# still prints ALL TESTS PASSED with a quietly smaller total.
#   1 readable + 1 Control A + 5 form shapes + 3 remedies + 1 decoy
#   + 1 detection + 2 merged-stream + 3 planted-wrapper mechanism = 17
_th_count_guard() {
    local EXPECTED_ASSERTIONS=17
    local TOTAL_ASSERTIONS=$(( PASS + FAIL ))
    assert_eq "assertion TOTAL matches the EXPECTED total" \
              "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"
    th_summary_and_exit
}

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b='<!-- BEGIN SHELL-WRAPPED-COREUTIL -->' -v e='<!-- END SHELL-WRAPPED-COREUTIL -->' '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | grep -E '^(whence|type|bash|command|find) ')

FORM_COUNT=$(printf '%s\n' "$FORMS" | grep -cE '^(whence|type|bash|command|find) ')
assert_eq "Control A: extracted exactly 5 documented forms" "$FORM_COUNT" "5"
if [[ "$FORM_COUNT" != "5" ]]; then
    th_abort "block malformed — refusing to draw conclusions from it"
fi

# SELECT BY CONTENT, not by position.
F_WHENCE=$(printf '%s\n' "$FORMS" | grep -F 'whence -w'  | sed -n '1p')
F_TYPE=$(printf   '%s\n' "$FORMS" | grep -F 'type -t'    | sed -n '1p')
F_BASHC=$(printf  '%s\n' "$FORMS" | grep -F 'bash -c'    | sed -n '1p')
F_CMD=$(printf    '%s\n' "$FORMS" | grep -F 'command find' | sed -n '1p')
F_MMIN=$(printf   '%s\n' "$FORMS" | grep -F -- '-mmin'   | sed -n '1p')

assert_contains "detection form 1 is zsh's whence -w"      "$F_WHENCE" "whence -w"
assert_contains "detection form 2 is bash's type -t"       "$F_TYPE"   "type -t"
assert_contains "remedy 1 re-enters a non-interactive bash" "$F_BASHC" "bash -c"
assert_contains "remedy 2 bypasses the function"            "$F_CMD"   "command find"
assert_contains "remedy 3 uses a dialect-free argument"     "$F_MMIN"  "-mmin"

# ---- the plant --------------------------------------------------------
# Five matching files and ONE decoy, so every count below measures the
# PREDICATE rather than the size of the directory.
FIX="$WORK/plant"
mkdir -p "$FIX" || th_abort "fixture mkdir failed"
for i in 1 2 3 4 5; do printf 'planted\n' > "$FIX/f$i.md"; done
printf 'decoy\n' > "$FIX/decoy.txt"
n_all=$(ls -1 "$FIX" | wc -l | tr -d ' ')
assert_eq "fixture: 6 files planted, of which 5 match — the decoy proves the predicate" \
          "$n_all" "6"

_sub() { printf '%s' "${1//DIR/$FIX}"; }

echo
echo '=== THE REMEDIES return the planted count — the portable half ==='
# Run through `bash -c` so the assertions describe the DOCUMENTED forms rather
# than whatever this runner's interactive shell happens to alias. Each form is
# executed verbatim from the block with only DIR substituted.
_run() { FORM=$(_sub "$1") bash -c 'eval "$FORM"' 2>/dev/null | tr -d '[:space:]'; }

assert_eq "remedy 1 (bash -c) finds all 5 planted files"      "$(_run "$F_BASHC")" "5"
assert_eq "remedy 2 (command find) finds all 5 planted files" "$(_run "$F_CMD")"   "5"
assert_eq "remedy 3 (-mmin -720) finds all 5 planted files"   "$(_run "$F_MMIN")"  "5"

echo
echo '=== THE DETECTION form actually classifies something ==='
# `type -t` is bash's and is the one this runner can execute. A form that
# printed nothing would make "you are not exposed" indistinguishable from
# "I did not look" — the entry's own failure mode.
det=$(FORM=$(_sub "$F_TYPE") bash -c 'eval "$FORM"' 2>/dev/null | grep -c . || true)
assert_eq "the bash detection form classifies all four names" "$det" "4"

echo
echo '=== THE SECOND TRAP: 2>&1 | wc -l counts DIAGNOSTICS AS DATA ==='
# Universal — needs no wrapper, and is asserted unconditionally for that
# reason. Two missing paths produce two lines of stderr and zero lines of data.
clean=$(bash -c "find '$WORK/nope-a' '$WORK/nope-b' -name '*.md' 2>/dev/null | wc -l" | tr -d '[:space:]')
merged=$(bash -c "find '$WORK/nope-a' '$WORK/nope-b' -name '*.md' 2>&1 | wc -l" | tr -d '[:space:]')
assert_eq "with stderr DROPPED the count is the truth: 0"        "$clean"  "0"
assert_eq "with stderr MERGED it is 2 — a plausible, wrong count" "$merged" "2"

echo
echo '=== THE MECHANISM, demonstrated with a PLANTED wrapper ==='
# THE CONDITIONAL, SOLVED BY PLANTING RATHER THAN BY DETECTING. The first
# draft of this arm probed `zsh -c 'whence -w find'` and duly reported "no
# wrapper" on a host whose interactive shell DOES wrap `find` — because a
# NON-interactive zsh does not load the operator's config, which is #849's own
# "per-SHELL, not per-host" point arriving inside the test written for it. A
# suite run from bash cannot see the harness's zsh snapshot, so detection is
# the wrong instrument.
#
# Planting one is the right instrument, and it is strictly better: it asserts
# nothing whatever about THIS host's configuration — so it is correct on a
# clone whose `find` is plain GNU findutils — while still exercising the
# mechanism and both remedies against a known-good count. The `0` below is a
# property of the PLANT, not a claim about anyone's shell.
mech=$(FIX="$FIX" bash -c '
    find() { return 1; }                     # a wrapper that REJECTS, silently
    printf "wrapped:%s\n" "$(find "$FIX" -name "*.md" 2>/dev/null | wc -l | tr -d " ")"
    printf "command:%s\n" "$(command find "$FIX" -name "*.md" 2>/dev/null | wc -l | tr -d " ")"
    printf "bashc:%s\n"   "$(bash -c "find \"$FIX\" -name \"*.md\"" 2>/dev/null | wc -l | tr -d " ")"
' 2>/dev/null)
_m() { printf '%s\n' "$mech" | sed -n "s/^$1://p"; }

assert_eq "through the PLANTED wrapper the count is a silent 0 — the defect's shape" \
          "$(_m wrapped)" "0"
assert_eq "…\`command find\` bypasses the function and recovers all 5" \
          "$(_m command)" "5"
assert_eq "…and a nested \`bash -c\` never loaded it, so it recovers all 5 too" \
          "$(_m bashc)" "5"

# INFORMATIONAL ONLY, never asserted: what THIS host's interactive shell does
# is a property of the operator's config, and #849 is explicit that a shared
# file must not turn one operator's configuration into everyone's red test.
printf '  (info: bash -c resolves find to %s)\n' "$(bash -c 'command -v find' 2>/dev/null || echo unknown)"

_th_count_guard
