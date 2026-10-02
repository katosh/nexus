#!/usr/bin/env bash
# Tests for the permission-dialog assertion in
# monitor/cc-harness/_lib.sh: cch_has_permission_dialog and
# cch_assert_permission_dialog (jacob-greene/nexus#158, Part B).
#
# Run: bash monitor/test-cch-permission-dialog.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Terms, defined on first use:
#
#   Harness     monitor/cc-harness, the scenario runner that drives the
#               real `claude` binary against an auth-free mock backend.
#   Scenario    one harness test case.
#   Probe       a script that drives an agent pane and reads its state.
#   Frame       one `tmux capture-pane` of a worker window, plain text.
#   Vacuous     a control arm that passes without exercising the
#   control    mechanism it controls for.
#
# WHY THIS SUITE EXISTS. The assertion's job is to FAIL when a probe
# expected a permission dialog and captured a frame without one. An
# assertion that only ever runs against frames that do carry the dialog
# is itself a vacuous control. So the bulk of this suite is negative:
# frames that look dialog-adjacent and must NOT match.
#
# The positive fixtures are VERBATIM captures from the real binary,
# recorded 2026-09-10 against Claude Code 2.1.220 through
# monitor/watcher/test-integration/test-realmodel-permission-dialog.sh.
# The negative fixtures are the frames most likely to produce a false
# pass: an idle REPL, the folder-trust dialog, an AskUserQuestion chip
# bar, prose describing the dialog, and a dialog frame with the chevron
# removed.
#
# Hermetic: no tmux, no claude binary, no mock backend, no tmpdir.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$_test_dir/cc-harness/_lib.sh"
# shellcheck source=cc-harness/_lib.sh
. "$LIB"

PASS=0
FAIL=0
should_match() {
    local label="$1" frame="$2"
    if cch_has_permission_dialog "$frame"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — expected a match, got none\n' "$label" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
should_not_match() {
    local label="$1" frame="$2"
    if cch_has_permission_dialog "$frame"; then
        printf '  FAIL: %s — matched, but this frame carries no dialog\n' "$label" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

# ---- fixtures ------------------------------------------------------------

# Verbatim capture: the `Write` permission dialog. Question literal
# "Do you want to create <file>?".
read -r -d '' FRAME_WRITE <<'EOF'
 ▐▛███▜▌   Claude Code v2.1.220
▝▜█████▛▘  Opus 5 (1M context) · API Usage Billing
  ▘▘ ▝▝    /tmp/cc-harness-opA6ZL/proj

❯ Please Write the file.

● Write(probe-new.txt)

────────────────────────────────────────────────────────────────────────
 Create file
 probe-new.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
  1 hello from the mock
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to create probe-new.txt?
 ❯ 1. Yes
   2. Yes, allow all edits during this session (shift+tab)
   3. No

 Esc to cancel · Tab to amend
EOF

# Verbatim capture: the `Edit` permission dialog. Different question
# literal — "Do you want to make this edit to <file>?" — same shape.
read -r -d '' FRAME_EDIT <<'EOF'
● Update(probe-existing.txt)
  ⎿  User rejected write to probe-new.txt

❯ Please Edit the file.

────────────────────────────────────────────────────────────────────────
 Edit file
 probe-existing.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 1 -original
 1 +edited
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to make this edit to probe-existing.txt?
 ❯ 1. Yes
   2. Yes, allow all edits during this session (shift+tab)
   3. No

 Esc to cancel · Tab to amend
EOF

# A two-option dialog: the decline row is `2. No`, not `3. No`. The
# assertion must not hard-code the number 3.
FRAME_TWO_OPTION=${FRAME_WRITE/   2. Yes, allow all edits during this session (shift+tab)
   3. No/   2. No}

# Verbatim capture: an idle REPL, the frame a probe gets when it forgot
# to drive a tool at all. THE negative control this whole mechanism
# exists for.
read -r -d '' FRAME_IDLE <<'EOF'
 ▐▛███▜▌   Claude Code v2.1.220
▝▜█████▛▘  Opus 5 (1M context) · API Usage Billing
  ▘▘ ▝▝    /tmp/cc-harness-6Z8Rod/proj

────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
EOF

# The folder-trust dialog. Numbered `1. Yes` / `2. No` rows, a chevron,
# and `Esc to cancel` — everything but `Tab to amend`. It is a DIFFERENT
# overlay with a different recovery path (pane-state's _has_trust_overlay,
# _unstick.sh case T), so a permission-dialog probe that accepted it
# would be asserting on the wrong thing.
read -r -d '' FRAME_TRUST <<'EOF'
 Accessing workspace:
 /tmp/cc-harness-opA6ZL/parent/work/child
 Quick safety check: Is this a project you created or one you trust?
 ❯ 1. Yes, I trust this folder
   2. No, exit

 Enter to confirm · Esc to cancel
EOF

# The AskUserQuestion chip bar. Numbered options and a chevron, no
# permission footer.
read -r -d '' FRAME_ASKUQ <<'EOF'
 Which color should the demo use?
 ❯ 1. Blue
   2. Green
   3. No
   Type something.
   Chat about this
EOF

# Prose describing the dialog — an agent transcript quoting the shape,
# or this very source file scrolling past in a pane. Carries every
# phrase, never a chevron-selected numbered row.
read -r -d '' FRAME_PROSE <<'EOF'
● Read(monitor/cc-harness/_lib.sh)
  ⎿  The permission dialog renders as:
       Do you want to create <file>?
       1. Yes
       2. Yes, allow all edits during this session (shift+tab)
       3. No
       Esc to cancel · Tab to amend
     pane-state classifies it `empty` today.
EOF

# The dialog with the chevron stripped. Stands in for a stale or
# half-drawn frame: the words are there, the selection is not.
FRAME_NO_CHEVRON=${FRAME_WRITE/ ❯ 1. Yes/   1. Yes}

# The nexus-158 skeptic's request 001. The prose fixture satisfies the
# option rows and both footer phrases on its own; only the chevron leg
# rejected it. So appending ANY unrelated live chevron row to the same
# 25-row capture completed the match, with no dialog present. Two shapes,
# both reachable in one frame:
#
#   a) an AskUserQuestion menu drawn under the transcript;
#   b) a bare chevron row whose number is not even `1.`.
#
# The fix is co-location: the legs must sit in a window around the LAST
# `Esc to cancel` row. These two fixtures put their menu three or more
# rows below the quoted footer, so the window's `anchor + 2` lower bound
# drops it before any other rule is consulted. They do NOT test the
# above-the-anchor split: removing that split leaves both green (depth-1
# skeptic on jacob-greene/nexus#159, finding 2). The split has its own fixture, in the
# "-- the Tab-to-amend, above-the-anchor and two-row rules are gated --"
# section below.
read -r -d '' FRAME_PROSE_PLUS_MENU <<EOF
$FRAME_PROSE
 Which color should the demo use?
 ❯ 1. Blue
   2. Green
EOF

read -r -d '' FRAME_PROSE_PLUS_CHEVRON <<EOF
$FRAME_PROSE
 ❯ 2. something unrelated
EOF

# The mirror of the same hole, skeptic request 002. Constraining every
# leg to the rows above the footer was not enough on its own: a live menu
# drawn ABOVE a quoted dialog lends its chevron to option rows it has
# nothing to do with, and both land in the same window. The chevron must
# therefore sit at or below the `1. Yes` row. A real selection only ever
# moves DOWN the option list, so that costs nothing legitimate.
read -r -d '' FRAME_MENU_ABOVE_PROSE <<'EOF'
 ❯ 1. Blue
   2. Green
  ⎿ docs quote the dialog:
       1. Yes
       3. No
       Esc to cancel · Tab to amend
EOF

# Skeptic request 004, shape A. A live menu row interleaved BETWEEN two
# quoted option rows. Contiguous with them, and it satisfies the ordering
# rule, so only column alignment rejects it: the menu row's `N.` token
# starts in a different column, so those rows are not one option list.
read -r -d '' FRAME_INTERLEAVED_MENU <<'EOF'
  ⎿ docs quote the dialog:
       1. Yes
 ❯ 2. Blue
       3. No
       Esc to cancel · Tab to amend
EOF

# Skeptic request 004, shape B. A folder-trust dialog with a bare decline
# row, plus `Tab to amend` borrowed from an adjacent line. Rejected
# because the permission dialog's first option row is the bare word
# `Yes`, and the trust dialog's is `Yes, I trust this folder`.
read -r -d '' FRAME_TRUST_BARE_NO <<'EOF'
 Quick safety check: Is this a project you created or one you trust?
 ❯ 1. Yes, I trust this folder
   2. No
 Enter to confirm · Esc to cancel
  ⎿ note: permission dialogs end with Tab to amend
EOF

# The decline row with trailing text. Claude Code renders a decline row
# with text after `No` in the trust dialog (`2. No, exit`), and the
# permission dialog's option 3 has read `No, and tell Claude what to do
# differently (esc)`. The detector first required the bare word `No`, so
# this frame was rejected (depth-1 skeptic on jacob-greene/nexus#159, finding 3, probe P4).
# The `no` leg now accepts `No` followed by end-of-row OR a comma.
FRAME_NO_WITH_TEXT=${FRAME_WRITE/   3. No/   3. No, and tell Claude what to do differently (esc)}

# The guard on that loosening: a word that merely STARTS with `No` is
# not a decline row. Everything else is a valid Write dialog.
FRAME_NO_PREFIX_ONLY=${FRAME_WRITE/   3. No/   3. Notes}

# All three selection positions of a real dialog must still match.
FRAME_CHEVRON_ON_2=${FRAME_WRITE/ ❯ 1. Yes
   2. Yes, allow all edits during this session (shift+tab)/   1. Yes
 ❯ 2. Yes, allow all edits during this session (shift+tab)}
FRAME_CHEVRON_ON_3=${FRAME_WRITE/ ❯ 1. Yes
   2. Yes, allow all edits during this session (shift+tab)
   3. No/   1. Yes
   2. Yes, allow all edits during this session (shift+tab)
 ❯ 3. No}

# ---- positive: real frames must match ------------------------------------
echo "=== frames that DO carry a permission dialog ==="
should_match "Write dialog (\"Do you want to create …?\")"          "$FRAME_WRITE"
should_match "Edit dialog (\"Do you want to make this edit …?\")"   "$FRAME_EDIT"
should_match "two-option dialog (decline row is \`2. No\`)"          "$FRAME_TWO_OPTION"
should_match "decline row with trailing text (\`3. No, and tell …\`)" "$FRAME_NO_WITH_TEXT"
should_match "chevron arrowed down to option 2"                      "$FRAME_CHEVRON_ON_2"
should_match "chevron arrowed down to option 3"                      "$FRAME_CHEVRON_ON_3"

# ---- negative controls: the point of the exercise ------------------------
echo
echo "=== frames that DO NOT — the assertion must fail loud on these ==="
should_not_match "idle REPL (the probe drove no tool at all)"        "$FRAME_IDLE"
should_not_match "folder-trust dialog (no \`Tab to amend\` footer)"   "$FRAME_TRUST"
should_not_match "AskUserQuestion chip bar"                          "$FRAME_ASKUQ"
should_not_match "prose describing the dialog (no live chevron)"     "$FRAME_PROSE"
should_not_match "dialog frame with the chevron stripped"            "$FRAME_NO_CHEVRON"
should_not_match "empty frame"                                       ""
should_not_match "prose + an AskUserQuestion menu below it"          "$FRAME_PROSE_PLUS_MENU"
should_not_match "prose + a bare unrelated chevron row below it"     "$FRAME_PROSE_PLUS_CHEVRON"
should_not_match "a live menu ABOVE quoted dialog rows"              "$FRAME_MENU_ABOVE_PROSE"
should_not_match "a live menu INTERLEAVED with quoted dialog rows"   "$FRAME_INTERLEAVED_MENU"
should_not_match "trust dialog, bare \`2. No\`, borrowed footer"      "$FRAME_TRUST_BARE_NO"
should_not_match "decline row is only a \`No\` prefix (\`3. Notes\`)"   "$FRAME_NO_PREFIX_ONLY"

# Co-location, stated directly: the same real dialog still matches when
# unrelated content sits below it, and stops matching when its option
# rows are pushed far above the footer.
read -r -d '' FRAME_DIALOG_PLUS_NOISE <<EOF
$FRAME_WRITE
 ⎿  some later transcript line
 ❯ 9. an unrelated menu row
EOF
should_match "real dialog still matches with noise below it"         "$FRAME_DIALOG_PLUS_NOISE"

read -r -d '' FRAME_OPTIONS_FAR_ABOVE <<EOF
$FRAME_WRITE
 filler 1
 filler 2
 filler 3
 filler 4
 filler 5
 filler 6
 filler 7
 filler 8
 Esc to cancel · Tab to amend
EOF
should_not_match "options pushed out of the window above the footer"  "$FRAME_OPTIONS_FAR_ABOVE"

# ---- the assertion wrapper is loud --------------------------------------
echo
echo "=== cch_assert_permission_dialog is loud on a frame without one ==="

# Non-zero return. A scenario that ignores this is ignoring an explicit
# failure, not being silently misled.
cch_assert_permission_dialog "$FRAME_IDLE" "a Write permission dialog" >/dev/null 2>&1
rc=$?
if (( rc == 1 )); then
    printf '  PASS: returns 1 on a frame with no dialog\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: returned %d on a frame with no dialog — expected 1\n' "$rc" >&2
    FAIL=$(( FAIL + 1 ))
fi

cch_assert_permission_dialog "$FRAME_WRITE" "a Write permission dialog" >/dev/null 2>&1
rc=$?
if (( rc == 0 )); then
    printf '  PASS: returns 0 on a frame with the dialog\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: returned %d on a real dialog frame — expected 0\n' "$rc" >&2
    FAIL=$(( FAIL + 1 ))
fi

# The diagnostic goes to stderr, names the missing legs, and quotes the
# frame. A CI log that only keeps stderr must still carry the evidence.
DIAG=$(cch_assert_permission_dialog "$FRAME_IDLE" "a Write permission dialog" 2>&1 >/dev/null)
# An idle frame has no `Esc to cancel` anchor at all, so there is no
# window to test the other legs in. The diagnostic says exactly that
# rather than listing four legs it never looked for.
for needle in \
    'NO PERMISSION DIALOG IN FRAME' \
    'expected: a Write permission dialog' \
    'no anchor row, so no window' \
    'bypass permissions on'
do
    if grep -qF -- "$needle" <<<"$DIAG"; then
        printf '  PASS: diagnostic carries %q\n' "$needle"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: diagnostic missing %q\n    in: <<%s>>\n' "$needle" "$DIAG" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done

# A frame that HAS the anchor but not the option rows gets the per-leg
# report, tested against the region the predicate actually uses.
DIAG2=$(cch_assert_permission_dialog "$FRAME_OPTIONS_FAR_ABOVE" "a Write permission dialog" 2>&1 >/dev/null)
for needle in \
    'one contiguous, column-aligned run of numbered option' \
    'at or below the `1. Yes` row' \
    'present somewhere in that region:'
do
    if grep -qF -- "$needle" <<<"$DIAG2"; then
        printf '  PASS: per-leg diagnostic carries %q\n' "$needle"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: per-leg diagnostic missing %q\n    in: <<%s>>\n' "$needle" "$DIAG2" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done

# Silence on success: a passing assertion must not spam a scenario log.
QUIET=$(cch_assert_permission_dialog "$FRAME_WRITE" "x" 2>&1)
if [[ -z "$QUIET" ]]; then
    printf '  PASS: silent when the dialog is present\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: printed on success: <<%s>>\n' "$QUIET" >&2
    FAIL=$(( FAIL + 1 ))
fi


# ---- regression: narrow terminal, real captured frames -------------------
#
# BYTE-EXACT captures from Claude Code 2.1.220, recorded 2026-09-10 by
# booting the real binary through cch_boot_prompting_worker in a tmux
# session created at the stated width. Trailing whitespace is part of
# the capture. Do NOT reflow or strip these fixtures: the wrap position
# is the whole point, and a reflowed fixture stops testing it.
#
# Below about 58 columns the renderer soft-wraps option 2 and emits the
# tail as its own line. Before jacob-greene/nexus#158 finding 2 that split
# the option run in two, and a REAL dialog was rejected. Both of these
# fixtures FAIL against a run rule that requires every line of the run
# to be a numbered option row.

read -r -d '' FRAME_WRITE_W46 <<'EOF'
 Do you want to create probe-new-46.txt?      
 ❯ 1. Yes  
   2. Yes, allow all edits during this session
      (shift+tab)      
   3. No   

 Esc to cancel · Tab to amend                 
EOF

read -r -d '' FRAME_WRITE_W54 <<'EOF'
 Do you want to create probe-new-54.txt?              
 ❯ 1. Yes    
   2. Yes, allow all edits during this session        
      (shift+tab)          
   3. No     

 Esc to cancel · Tab to amend                         
EOF

echo
echo "-- narrow terminals: the real dialog still matches --"
should_match "real 2.1.220 Write dialog captured at width 46 (option 2 wraps)" \
    "$FRAME_WRITE_W46"
should_match "real 2.1.220 Write dialog captured at width 54 (option 2 wraps)" \
    "$FRAME_WRITE_W54"

# The loosening is bounded: a non-option line is folded into the run
# ONLY if it is indented PAST the option column. These two fixtures put
# a non-option line between the option rows at or LEFT of that column,
# so it must still break the run.
echo
echo "-- the loosening is bounded: an un-indented interloper still breaks the run --"
should_not_match "prose at the option column between the option rows" \
" Do you want to create probe.txt?
 ❯ 1. Yes
   2. Yes, allow all edits during this session
   see the docs for what option 2 does
   3. No

 Esc to cancel · Tab to amend"
should_not_match "prose left of the option column between the option rows" \
" Do you want to create probe.txt?
 ❯ 1. Yes
   2. Yes, allow all edits during this session
 see the docs for what option 2 does
   3. No

 Esc to cancel · Tab to amend"

# The two shapes the contiguity rule was added to close. They are gated
# here so the finding-2 loosening can never silently reopen them.
# Reported by the depth-1 skeptic on jacob-greene/nexus#158.
echo
echo "-- the shapes contiguity closed must stay closed --"
should_not_match "live menu row interleaved between quoted option rows" \
"  ⎿ docs quote the dialog:
       1. Yes
 ❯ 2. Blue
       3. No
       Esc to cancel · Tab to amend"
should_not_match "folder-trust dialog borrowing a quoted Tab-to-amend footer" \
" Quick safety check: Is this a project you created or one you trust?
 ❯ 1. Yes, I trust this folder
   2. No
 Enter to confirm · Esc to cancel
  ⎿ note: permission dialogs end with Tab to amend"

# ---- regression: the chevron leg is anchored ----------------------------
#
# `chev` used to match a ❯ ANYWHERE inside a row, unlike `opt`, `yes`
# and `no`, which are all anchored to the row start. So a numbered list
# in prose could lend the chevron leg from the middle of one of its own
# rows. No real dialog draws its chevron anywhere but the row start.
# Reported by the depth-2 skeptic on jacob-greene/nexus#158, finding 3.
echo
echo "-- the chevron leg is anchored to the row start --"
should_not_match "prose list with a mid-row chevron inside one of its rows" \
" The docs describe the permission dialog. Its options are:
   1. Yes
   3. No
   2. See ❯ 4. below for the retry path
 Esc to cancel · Tab to amend"

# ---- coverage: the two rules no other fixture gates ----------------------
#
# Found by mutation, not by inspection. The skeptic reviewing this fix
# (`jacob-greene/nexus#159`, finding T1) broke one rule at a time in
# `_cch_option_run_ok` and re-ran this suite. Six of eight mutants were
# killed. Two survived, which means no fixture below tested the rule
# they broke:
#
#   M1  drops `cidx >= yidx`, the chevron-ordering rule
#   M8  makes a blank line transparent inside a run
#
# Both rules are load-bearing and both are stated in the code, so both
# read as covered. `cidx >= yidx` was added to close skeptic request
# 002; its original fixture, FRAME_MENU_ABOVE_PROSE, is now rejected by
# ALIGNMENT instead, so it no longer reaches the ordering rule. The
# blank-line rule is asserted in a comment at cc-harness/_lib.sh — "A
# blank line still breaks the run, so the footer can never be folded
# in" — and nothing checked it.
#
# Each fixture below is built to fail on exactly one of those rules and
# on nothing else. Every other leg is satisfied: the option rows are
# contiguous, their `N.` tokens are all in column 4, and the footer
# carries both phrases. So each one matches if and only if its rule is
# gone, which is what makes it a test of that rule rather than of the
# predicate in general.
echo
echo "-- the chevron-ordering and blank-line rules are gated --"
# Chevron ABOVE the `1. Yes` row. A real selection only ever moves DOWN
# the option list, so this is an unrelated live menu lending its chevron
# to option rows below it. Matches under M1.
should_not_match "chevron row sits ABOVE the \`1. Yes\` row" \
" ❯ 9. Blue
   1. Yes
   3. No
 Esc to cancel · Tab to amend"
# A blank line between the option rows. The continuation-row loosening
# folds an indented non-option line into the run; a blank line is not
# indented past the option column and must still break it, or the
# footer itself could be folded in. Matches under M8.
should_not_match "a blank line between the option rows still breaks the run" \
"   1. Yes

 ❯ 2. Blue
   3. No
 Esc to cancel · Tab to amend"

# Three more rules with no fixture, found by the depth-1 skeptic on jacob-greene/nexus#159
# (finding 2, mutants M07, M12 and M15). The author's own mutation pass
# covered _cch_option_run_ok only; these three rules live in
# cch_has_permission_dialog and _cch_dialog_window. Each fixture below
# fails on exactly one rule, so it matches if and only if that rule is
# removed.
echo
echo "-- the Tab-to-amend, above-the-anchor and two-row rules are gated --"
# M07: the `Tab to amend` conjunct. A live `1. Yes` / `2. No` overlay
# with a chevron and `Esc to cancel`, but no `Tab to amend` anywhere.
# Every other leg holds. Matches if the conjunct is dropped.
should_not_match "live 1. Yes / 2. No overlay with no \`Tab to amend\`" \
" Should the demo ship today?
 ❯ 1. Yes
   2. No
 Esc to cancel"
# M12: the above-the-anchor split. A live menu ONE row below a quoted
# footer, so it sits inside the `anchor + 2` window. Only the rule that
# option rows must sit ABOVE the anchor rejects it. Matches if every
# window row is treated as above.
should_not_match "live 1. Yes / 2. No menu one row below a quoted footer" \
"  ⎿  transcript quoting a footer: Esc to cancel · Tab to amend
 ❯ 1. Yes
   2. No"
# M15: the two-row bound below the anchor. A valid option run above the
# anchor, but `Tab to amend` only in a transcript line five rows below.
# Matches if the window runs to the end of the frame.
should_not_match "\`Tab to amend\` five rows below the anchor" \
" Should the demo ship today?
 ❯ 1. Yes
   2. No
 Esc to cancel
 filler 1
 filler 2
 filler 3
 filler 4
  ⎿  docs: the permission dialog footer reads Tab to amend"

# ---- regression: no locale or awk precondition ---------------------------
#
# The option column is compared in TERMINAL COLUMNS. The awk match()
# function returns a BYTE offset unless the implementation is multibyte-
# aware in the current locale: mawk never is, and gawk is not under a C
# locale. The chevron ❯ is one column and three bytes, so a byte-offset
# implementation reported the chevron row misaligned against every row
# below it and rejected EVERY real dialog.
#
# That is a false negative, which turns a fail-loud assertion silent. It
# was invisible to this suite because the suite varied fixtures but never
# the environment. These arms vary the environment instead: they re-run
# the positive fixtures with the column arithmetic forced byte-wise.
# Reported by the depth-2 skeptic on jacob-greene/nexus#158, finding 1.
#
# On the code this replaced, every one of these arms failed.

# Run the predicate in a subshell with a modified environment, so the
# suite's own environment is never disturbed.
should_match_in_env() {
    local label="$1" frame="$2"; shift 2
    if ( export "$@"; cch_has_permission_dialog "$frame" ); then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — expected a match, got none\n' "$label" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

echo
echo "-- the column arithmetic does not depend on the locale --"
for _lc in C POSIX; do
    should_match_in_env "Write dialog under LC_ALL=$_lc" \
        "$FRAME_WRITE" "LC_ALL=$_lc"
    should_match_in_env "width-46 dialog under LC_ALL=$_lc" \
        "$FRAME_WRITE_W46" "LC_ALL=$_lc"
done

# The same check against a genuinely byte-only awk. mawk is the default
# awk on Debian and Ubuntu, so this is the implementation CI is most
# likely to get. If mawk is absent the arm SKIPS LOUDLY rather than
# passing quietly: a silent skip here would be the vacuous control this
# suite exists to prevent.
echo
echo "-- the column arithmetic does not depend on the awk implementation --"
_mawk=$(command -v mawk 2>/dev/null)
if [[ -n "$_mawk" ]]; then
    _shim=$(mktemp -d)
    printf '#!/bin/sh\nexec %s "$@"\n' "$_mawk" > "$_shim/awk"
    chmod +x "$_shim/awk"
    should_match_in_env "Write dialog with awk shadowed to mawk" \
        "$FRAME_WRITE" "PATH=$_shim:$PATH"
    should_match_in_env "Edit dialog with awk shadowed to mawk" \
        "$FRAME_EDIT" "PATH=$_shim:$PATH"
    should_match_in_env "width-46 dialog with awk shadowed to mawk" \
        "$FRAME_WRITE_W46" "PATH=$_shim:$PATH"
    rm -rf "$_shim"
else
    printf '  SKIP: mawk is not installed, so the mawk arm did not run\n' >&2
    printf '        Install mawk to exercise it. The LC_ALL arms above\n' >&2
    printf '        cover the same defect through a different route.\n' >&2
fi

# ---- summary -------------------------------------------------------------
echo
printf 'cch-permission-dialog: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
