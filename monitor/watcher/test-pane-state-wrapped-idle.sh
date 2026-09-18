#!/usr/bin/env bash
# A wrapped worker's idle pane must be DECIDABLE — your-org/nexus-code#657.
#
# The defect: Claude Code 2.1.220 renders the idle input box of a pane
# nobody is looking at as a BARE CHEVRON — the row ends at `❯<NBSP>` with
# no reverse-video cursor cell. Both arms of `_detect_empty_input`
# required that cell, so every detector returned false, `input=` fell to
# `?`, and the pane emitted `empty`. `retire-preflight.sh` then refused
# it as INDETERMINATE — correctly, given what it was told. Ten wrapped
# workers parked there simultaneously for up to 68 h and the board could
# not drain.
#
# The fix is in CLASSIFICATION, not authorisation, and these tests are
# built to hold that line. Four of the seven cases below exist only to
# prove what did NOT change:
#
#   * `empty` is still reachable and still means "don't know yet"
#     (case 5) — the fix must not have achieved its result by making
#     the ambiguous state disappear.
#   * the kill allowlist is byte-for-byte untouched (case 6), and
#     `empty` is still refused by it (case 7).
#   * genuine operator input still wins, and still refuses the kill
#     for the RIGHT reason (case 2).
#
# KNOWN LIMITATION OF THE CORPUS THESE CASES RUN AGAINST (#662 skeptic).
# 17 of the 19 chevron-bearing fixtures under fixtures/ carry the
# reverse-video cursor `\x1b[7m`, which appears on 0 of 16 live panes
# measured on 2026-08-02. They are pre-2.1.220 chrome. So cases 2, 3 and 4
# below — the typed / ghost / empty-box controls — validate against
# renderings the board no longer produces, and would not catch a renderer
# change that broke those paths TODAY.
#
# The two #657 fixtures are currently the only captures of the live
# renderer. That is a corpus problem, not a problem with these
# assertions, and re-capturing the controls against 2.1.220 is tracked
# separately — but read a green run here with that caveat attached.
#
# Run: bash monitor/watcher/test-pane-state-wrapped-idle.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HELPER="$_repo_root/monitor/pane-state.sh"
BK="$_repo_root/monitor/_bookkeeping.sh"
FIX_DIR="$_test_dir/fixtures"
NBSP=$' '

# Shared harness, for the durable LEDGER and `th_summary_and_exit`
# (your-org/nexus-code#1232 / #1214 D2). This suite was `ledger=no count=none`,
# which is why eight assertions could vanish in silence.
# shellcheck disable=SC1091
. "$_test_dir/_test_helpers.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }
ck()   { if [[ "$2" == "$3" ]]; then pass "$1 ($2)"; else fail "$1 — got '$2' want '$3'"; fi; }

[[ -x "$HELPER" ]] || { echo "helper not executable: $HELPER" >&2; exit 1; }
[[ -r "$BK"     ]] || { echo "bookkeeping not readable: $BK" >&2; exit 1; }

WORK=$(mktemp -d -t nexus-657-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# field <output> <key>  → value of key= in a pane-state emit
field() { sed -E "s/.*(^| )$2=([^ ]*).*/\2/;t;d" <<<"$1"; }
run()   { "$HELPER" --fixture "$1" --window 9 --name testwin --active 0 2>&1; }

# ---------------------------------------------------------------------------
echo "=== case 1: the real captured bytes — a wrapped worker's idle pane ==="
# Rows 3-9 of this fixture are a byte-for-byte capture of a live wrapped
# worker (window kompot-272F-merge) taken while it was parked in the
# defect. Only the transcript line was neutralised. This is the whole
# bug: if it classifies, the board drains.
F657="$FIX_DIR/idle-wrapped-bare-chevron-657.ansi"
if [[ ! -r "$F657" ]]; then
    fail "fixture missing: $F657"
else
    out=$(run "$F657")
    ck "wrapped idle pane is idle, not empty" "$(field "$out" state)" idle
    ck "…and its input row is decidable"      "$(field "$out" input)" blank

    # The bare chevron is the POINT — assert the fixture really carries
    # it, so this case cannot silently start testing something else.
    row=$(grep -F "❯${NBSP}" "$F657" | tail -1)
    if grep -qP '\x1b\[7m' <<<"$row"; then
        fail "fixture no longer exhibits the defect (it has a reverse-video cursor)"
    else
        pass "fixture genuinely has NO reverse-video cursor cell (the #657 rendering)"
    fi
    if grep -qE -- '--[[:space:]]*INSERT[[:space:]]*--' "$F657"; then
        pass "fixture carries '-- INSERT --' — the vim refinement must NOT promote it"
    else
        fail "fixture lost its '-- INSERT --' footer; the vim-refinement control is gone"
    fi
fi

# ---------------------------------------------------------------------------
echo "=== case 2: NEGATIVE CONTROL — genuine typed input still wins ==="
# If this regresses, the orchestrator pastes over an operator's draft.
for f in user-typing-synthetic user-typing-with-autosuggest-tail-synthetic; do
    if [[ -r "$FIX_DIR/$f.ansi" ]]; then
        out=$(run "$FIX_DIR/$f.ansi")
        ck "$f stays user-typing" "$(field "$out" state)" user-typing
        ck "$f stays input=typed" "$(field "$out" input)" typed
    else
        fail "missing control fixture: $f.ansi"
    fi
done

# ---------------------------------------------------------------------------
echo "=== case 3: autosuggest ghosts unchanged ==="
# THE POPULATION COMES FROM THE MANIFEST, NOT FROM A FILENAME GLOB
# (your-org/nexus-code#1232). This read `for f in "$FIX_DIR"/autosuggest-*.ansi`,
# which is BOTH halves of the defect this branch has been chasing:
#
#   * the expectation was derived from the FILENAME PREFIX — the scheme `#1176`
#     removes, and whose promise ("a fixture's name is now free to DESCRIBE the
#     capture") this made false in a file `#1176` never touched;
#   * and the failure was SILENT. Renaming the four fixtures WITH their manifest
#     rows took this suite from 31 passed to 23 passed, 0 failed, ALL TESTS
#     PASSED, rc 0. EIGHT ASSERTIONS VANISHED and the suite still announced a
#     clean sweep. That is strictly worse than a loud red: nothing to
#     investigate, and the count is the only witness.
#
# Both halves are closed here. The manifest names the fixtures and carries the
# expectation, and the EXPECTED-count guard at the foot makes a vanished loop
# body RED — because selecting the right population is not enough if iterating
# zero times still passes.
_wi_auto=0
while IFS=$'\t' read -r _mf _mw _me _ma _mr; do
    [[ "$_mw" == "autosuggest-only" && "$_me" == "-" && "$_ma" == "-" ]] || continue
    [[ -r "$FIX_DIR/$_mf" ]] || continue
    _wi_auto=$(( _wi_auto + 1 ))
    out=$(run "$FIX_DIR/$_mf")
    ck "$_mf stays autosuggest-only" "$(field "$out" state)" autosuggest-only
    ck "$_mf stays input=ghost"      "$(field "$out" input)" ghost
done < <(grep -vE '^[[:space:]]*(#|$)' "$_test_dir/pane-state-fixtures.manifest")
if (( _wi_auto == 0 )); then
    fail "no manifest fixture expects autosuggest-only — case 3 asserted NOTHING"
fi

# ---------------------------------------------------------------------------
echo "=== case 4: the pre-existing empty-box renderings still classify ==="
for f in idle-empty-synthetic idle-empty-post-turn-realmodel; do
    if [[ -r "$FIX_DIR/$f.ansi" ]]; then
        out=$(run "$FIX_DIR/$f.ansi")
        ck "$f stays idle" "$(field "$out" state)" idle
    else
        fail "missing regression fixture: $f.ansi"
    fi
done

# ---------------------------------------------------------------------------
echo "=== case 5: THE LOAD-BEARING CONTROL — 'empty' is still reachable ==="
# The cheap way to make ten panes stop reading `empty` is to stop `empty`
# from happening. That would trade a stuck board for a silently
# authorising one, and it would pass every other case in this file.
#
# So: a row with REAL, non-whitespace content after the chevron that
# carries neither marker (no bright-white, no dim run, no reverse-video
# cursor) must STILL be `?`/`empty`. This is the honest residue #626
# describes — an operator draft in a rendering we cannot attribute — and
# refusing to guess about it is the whole reason the gate is trusted.
UNCL="$WORK/unclassifiable.ansi"
{
    printf '  some transcript line\n'
    printf '\n'
    printf '\x1b[38;5;244m────────────────────\x1b[39m\n'
    printf '\x1b[39m❯%sdeploy to prod\n' "$NBSP"
    printf '\x1b[38;5;244m────────────────────\x1b[39m\n'
    printf '  \x1b[38;5;246m◉ Opus 5 │ v2.1.220\x1b[39m\n'
} > "$UNCL"
out=$(run "$UNCL")
ck "unattributable non-blank row stays input=?" "$(field "$out" input)" '?'
ck "…and the pane stays empty (\"don't know yet\")" "$(field "$out" state)" empty

# And the discrimination is real, not an artifact of the fixture shape:
# the SAME fixture with the text removed must flip to idle/blank.
BARE="$WORK/bare.ansi"
sed "s/❯${NBSP}deploy to prod/❯${NBSP}/" "$UNCL" > "$BARE"
out=$(run "$BARE")
ck "same fixture, text removed → idle" "$(field "$out" state)" idle
ck "same fixture, text removed → blank" "$(field "$out" input)" blank

# ---------------------------------------------------------------------------
echo "=== case 6: the kill allowlist was NOT widened ==="
# #657's non-negotiable constraint. Assert the allowlist CONTENTS, not
# just that the file parses — a fix that quietly appended `empty` here
# would satisfy every classification test above.
# shellcheck source=monitor/_bookkeeping.sh
if source "$BK" 2>/dev/null && declare -p _BK_KILL_OK_STATES >/dev/null 2>&1; then
    got=$(printf '%s\n' "${_BK_KILL_OK_STATES[@]}" | sort | tr '\n' ' ')
    want=$(printf '%s\n' absent autosuggest-only idle idle-orphan-async | sort | tr '\n' ' ')
    ck "allowlist is exactly the four documented states" "$got" "$want"
else
    fail "could not source _bookkeeping.sh / read _BK_KILL_OK_STATES"
fi

# ---------------------------------------------------------------------------
echo "=== case 7: 'empty' is still REFUSED by the authoriser ==="
if declare -F bk_pane_kill_authorized >/dev/null 2>&1; then
    if bk_pane_kill_authorized empty; then
        fail "bk_pane_kill_authorized now AUTHORISES 'empty' — the gate has been relaxed"
    else
        ck "empty refused, and as indeterminate" "${BK_REFUSE_KIND:-}" indeterminate
    fi
    if bk_pane_kill_authorized idle; then
        pass "idle is authorised (so a decidable wrapped pane can now retire)"
    else
        fail "idle is NOT authorised — the fix cannot drain the board"
    fi
    if bk_pane_kill_authorized user-typing; then
        fail "user-typing is AUTHORISED — an operator draft could be killed"
    else
        pass "user-typing still refused"
    fi
else
    fail "bk_pane_kill_authorized not defined after sourcing"
fi

# ---------------------------------------------------------------------------
echo "=== case 8: the bare chevron was MASKING live background work (#662 review) ==="
# Found by the #662 skeptic, and it is the one respect in which the fix is
# BETTER than the PR claimed rather than worse.
#
# Before #662, a pane with live background shells AND the bare-chevron
# rendering fell into the `else` arm and reported `empty` — so
# `_finalize_idle_verdict` never ran and `working-background` was
# swallowed whole. The pane was not merely undecidable, it was actively
# misreported: a worker holding a running build looked the same as a
# worker holding nothing.
#
# That matters beyond tidiness. `working-background` is the state the
# #455/#590 work exists to surface, and it is the difference between
# "this window has finished" and "this window is running a build you are
# about to kill". The fix restores it, and this asserts it HEAD-ON rather
# than inferring it from the shared branch.
FBG="$FIX_DIR/working-background-bare-chevron-657.ansi"
if [[ ! -r "$FBG" ]]; then
    fail "fixture missing: $FBG"
else
    out=$(run "$FBG")
    ck "bare chevron + live bg shell → working-background, not idle" \
        "$(field "$out" state)" working-background
    ck "…and its input row is still decidable" "$(field "$out" input)" blank

    # The fixture must genuinely combine BOTH properties, or this case
    # silently degrades into a re-test of the ordinary bg path.
    row=$(grep -F "❯${NBSP}" "$FBG" | tail -1)
    if grep -qP '\x1b\[7m' <<<"$row"; then
        fail "fixture has a reverse-video cursor — it is not the #657 rendering"
    else
        pass "fixture is genuinely bare-chevron (no reverse-video cursor)"
    fi
    if grep -qE 'shell(s)?(,| ·|$)' "$FBG"; then
        pass "fixture genuinely carries a background-shell footer"
    else
        fail "fixture lost its background-shell footer; the case is vacuous"
    fi

    # working-background must NOT be kill-authorised — the whole point of
    # un-masking it is that it protects a window `empty` would have left
    # indeterminate and `idle` would have retired.
    if declare -F bk_pane_kill_authorized >/dev/null 2>&1; then
        if bk_pane_kill_authorized working-background; then
            fail "working-background is kill-AUTHORISED — un-masking it would be worse than masking it"
        else
            pass "working-background refused by the authoriser (active, not finished)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# EXPECTED-COUNT GUARD (your-org/nexus-code#807, applied here by #1232). The
# fixed cases contribute 23; case 3 contributes 2 per manifest-selected
# autosuggest fixture. DERIVED, so adding or removing a fixture moves the
# expectation with it — and a loop that iterates zero times can no longer pass.
EXPECTED=$(( 23 + 2 * _wi_auto ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
