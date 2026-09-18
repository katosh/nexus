#!/usr/bin/env bash
# test-claude-md-zsh-path-tie.sh — execute CLAUDE.md's ZSH-PATH-TIE block.
#
# WHY THIS SUITE EXISTS. your-org/nexus-code#945: in zsh, `path` is a tied
# array bound to `$PATH`. Assigning to it — the most natural variable name
# there is — replaces PATH for the rest of the shell, with no error and rc 0.
# It bit a reviewer on this board.
#
# CONTAINMENT, stated first because it is the risk this suite itself carries:
# EVERY assignment below runs inside a CHILD `zsh -c`. Nothing here may touch
# the runner's own PATH, and the final assertion witnesses that it did not.
# A suite that demonstrated this defect by suffering it would take the whole
# test run with it — `monitor/ghwrap` is on PATH, so a leak here would also
# unwrap `gh` for everything downstream.
#
# WHAT IS ACTUALLY PINNED:
#   the TIE          — zsh: `path=X` ⇒ `$PATH` becomes X.
#   the ASYMMETRY    — bash does NOT do this, which is why the defect survives
#                      testing and reaches the zsh-default agent path.
#   the REMEDY       — `local -h path` hides the tie; bare `local path=` only
#                      SCOPES the damage (destroyed inside, restored on return),
#                      which is worse than it looks because the function body is
#                      where the commands run.
#
# CONTROLS:
#   A — extracted form count PINNED at 3 (#618's shape: an empty extraction
#       satisfies every assertion by having none to make).
#   B — POSITIVE control: a DIFFERENTLY-NAMED variable must leave PATH intact
#       under the same zsh, so the assertions measure the TIE and not "zsh
#       mangles PATH".
#   C — the destroying form EXITS 0. The defect is that it succeeds.

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
th_claude_md_block_coverage ZSH-PATH-TIE   # the entry's UNCHECKED share, in this suite's own output (#1239)

# ZSH ABSENCE IS A SKIP, NOT AN ABORT (your-org/nexus-code#946 F7). This used to
# `th_abort` — a COUNTED FAILURE — where the two pre-existing zsh-dependent
# suites (test-claude-md-618-remedies.sh, test-claude-md-ancestor-timeline.sh)
# both degrade instead. That is F2's shape one axis over: a suite that goes RED
# on a host it was simply never able to test, in a corpus every operator clones.
# CI installs zsh (tests.yml), so it was dormant here — dormant is not correct.
# The extraction assertions and the bash-contrast arm need no zsh and still run;
# only the zsh-dependent arms skip, loudly and with a reason.
HAVE_ZSH=no
if command -v zsh >/dev/null 2>&1; then
    HAVE_ZSH=yes
else
    th_skip "every zsh-dependent arm" \
            "zsh is not on PATH — the tie itself, the local -h remedy, the bare-local distinction, control B and the containment check could NOT be exercised on this host; only the block extraction and the bash contrast ran"
fi

# Snapshot the runner's PATH up front; the last assertion compares against it.
PATH_BEFORE="$PATH"

# ---- assertion-count guard (your-org/nexus-code#946 F6) -------------------
# A missing assert_* helper (a typo → rc 127) is counted by NOTHING: the suite
# still prints ALL TESTS PASSED with a quietly smaller total. This suite has TWO
# exit points (the zsh-absent early return and the end), so the guard lives in a
# helper called from both — a guard on only the happy path is exactly the
# "placed where it cannot fail" shape. Pinned against the configuration ACTUALLY
# DETECTED: an unconditional pin would go red wherever zsh is absent, which is
# the false RED F7 just removed, re-introduced one layer up.
#   extraction + bash-contrast arm (need no zsh)                 =  7
#   + tie, remedy, bare-local distinction, control B, containment = 12
_th_count_guard() {
    local EXPECTED_ASSERTIONS=7
    [[ "$HAVE_ZSH" == "yes" ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 12 ))
    local TOTAL_ASSERTIONS=$(( PASS + FAIL ))
    assert_eq "assertion TOTAL matches the EXPECTED total for this host (zsh=$HAVE_ZSH)" \
              "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"
    th_summary_and_exit
}

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b='<!-- BEGIN ZSH-PATH-TIE -->' -v e='<!-- END ZSH-PATH-TIE -->' '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | grep -E '^(zsh|bash) ')

FORM_COUNT=$(printf '%s\n' "$FORMS" | grep -cE '^(zsh|bash) ')
assert_eq "extracted exactly 3 documented forms" "$FORM_COUNT" "3"
if [[ "$FORM_COUNT" != "3" ]]; then
    th_abort "block malformed — refusing to draw conclusions from it"
fi

FORM_ZSH=$(printf  '%s\n' "$FORMS" | sed -n '1p')
FORM_BASH=$(printf '%s\n' "$FORMS" | sed -n '2p')
FORM_LOCAL=$(printf '%s\n' "$FORMS" | sed -n '3p')

assert_contains "form 1 is the zsh demonstration"  "$FORM_ZSH"   'zsh'
assert_contains "form 2 is the bash comparison"    "$FORM_BASH"  'bash'
assert_contains "form 3 is the local -h remedy"    "$FORM_LOCAL" 'local -h'

echo
echo '=== THE ASYMMETRY: bash leaves PATH alone (no zsh required) ==='
out_bash=$(eval "$FORM_BASH" 2>&1); rc_bash=$?
assert_eq           "the bash form exits 0"                    "$rc_bash" "0"
assert_not_contains "bash does NOT collapse PATH to the value" "$out_bash" "PATH=/tmp/nowhere"

if [[ "$HAVE_ZSH" != "yes" ]]; then
    echo
    echo '  (every arm below needs zsh — skipped above with a reason)'
    _th_count_guard
fi

echo
echo '=== THE TIE: zsh path=X replaces $PATH, and exits 0 ==='
out_zsh=$(eval "$FORM_ZSH" 2>&1); rc_zsh=$?
assert_eq       "the destroying form EXITS 0 (control C)"    "$rc_zsh" "0"
assert_contains "…PATH is replaced wholesale"                "$out_zsh" "PATH=/tmp/nowhere"
assert_contains "…and a core tool is no longer resolvable"   "$out_zsh" "git NOT FOUND"

echo
echo '=== THE REMEDY: local -h hides the tie ==='
out_local=$(eval "$FORM_LOCAL" 2>&1); rc_local=$?
assert_eq       "the remedy form exits 0"                 "$rc_local" "0"
assert_contains "…and reports PATH INTACT after the call" "$out_local" "INTACT"

echo
echo '=== The remedy is NOT interchangeable with a bare `local path=` ==='
# Measured distinction, and the reason the entry spells it out: bare `local`
# destroys PATH for the whole function BODY — where the commands run — and
# merely restores it on return. Asserting only the "after" would call that safe.
bare=$(zsh -c '
g() { local path=/tmp/nowhere; print -r -- "inside=$PATH"; }
before=$PATH; g; print -r -- "after=$( [[ $PATH == $before ]] && echo INTACT || echo LOST )"' 2>&1)
assert_contains "bare local: PATH IS destroyed inside the body"  "$bare" "inside=/tmp/nowhere"
assert_contains "bare local: …and merely restored on return"     "$bare" "after=INTACT"

hidden=$(zsh -c '
f() { local -h path; path=/tmp/nowhere; print -r -- "inside=$PATH"; }
before=$PATH; f; print -r -- "after=$( [[ $PATH == $before ]] && echo INTACT || echo LOST )"' 2>&1)
assert_not_contains "local -h: PATH is intact even INSIDE the body" "$hidden" "inside=/tmp/nowhere"
assert_contains     "local -h: …and after it"                       "$hidden" "after=INTACT"

echo
echo '=== CONTROL B: a differently-named variable leaves PATH alone in the SAME zsh ==='
# Without this, every assertion above would also pass against a zsh that simply
# mangled PATH on any assignment. Only the NAME differs here.
other=$(zsh -c 'notpath=/tmp/nowhere; print -r -- "PATH_HEAD=${PATH%%:*}"' 2>&1)
assert_not_contains "a non-tied name does NOT touch PATH" "$other" "PATH_HEAD=/tmp/nowhere"

echo
echo '=== CONTAINMENT: this suite did not damage its own PATH ==='
assert_eq "the runner's PATH is byte-identical to the snapshot" \
          "$( [[ "$PATH" == "$PATH_BEFORE" ]] && echo same || echo CHANGED )" "same"
assert_eq "…and the bot gh wrapper is still reachable" \
          "$( command -v gh >/dev/null 2>&1 && echo yes || echo no )" "yes"

_th_count_guard
