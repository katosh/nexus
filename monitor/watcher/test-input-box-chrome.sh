#!/usr/bin/env bash
# test-input-box-chrome.sh — the coverage boundary of the ghost-vs-chrome
# discriminator, enforced as DATA (your-org/nexus-code#801).
#
# `monitor/pane-state.sh:_detect_dim_run` answers "is this faint run an
# autosuggest ghost?". It used to answer YES for any visible character after
# the chevron, and a dim closing box border is a visible character — so an
# EMPTY input box drawn with one classified `autosuggest-only input=ghost`,
# and `state=idle` became unreachable for that renderer. `#798` measured it:
# 28 s of deterministic polling against the integration stub, not a race.
#
# The classifier now erases dim runs whose whole visible content is box
# chrome. WHICH GLYPHS COUNT is monitor/watcher/input-box-chrome.manifest,
# and this file executes every row of it against the REAL helper through a
# synthesized pane, so the boundary is a checked fact rather than a claim in
# a comment. The axis is the one the MECHANISM varies on — which glyph a
# renderer draws the box with — not the one a search varied on.
#
# What each test establishes:
#   1. every `chrome` row: a dim run of ONLY that glyph reads idle/blank
#   2. every `content` row: a dim run containing it reads
#      autosuggest-only/ghost — this is what stops "fix by never detecting
#      a ghost again" from passing, and it is where `|`, `+`, `■` and `⓿`
#      pin the declared gaps and the two range edges
#   3. the population is non-degenerate and carries BOTH dispositions — a
#      manifest that silently emptied, or that lost all its negatives,
#      would otherwise pass tests 1 and 2 vacuously
#   4. the manifest's own claim about the byte ranges is true of the source:
#      the ranges named in the comment are the ranges the code implements
#
# Run: bash monitor/watcher/test-input-box-chrome.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
_monitor_dir=$(cd "$_test_dir/.." && pwd)
MANIFEST="$_test_dir/input-box-chrome.manifest"
HELPER="$_monitor_dir/pane-state.sh"

for f in "$MANIFEST" "$HELPER"; do
    [[ -r "$f" ]] || th_abort "test-input-box-chrome: missing $f"
done
[[ -x "$HELPER" ]] || th_abort "test-input-box-chrome: $HELPER is not executable"

WORK=$(mktemp -d -t nexus-chrome-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

ESC=$'\x1b'
NBSP=$'\xc2\xa0'

# Synthesize a pane whose input box is EMPTY and whose only dim run after the
# chevron holds `$1`. Same shape as the checked-in `#801` fixtures, so a pass
# here and a pass there are about the same rendering.
#
# The reverse-video cursor cell is present (`\x1b[7m \x1b[0m`) precisely so
# the empty-box arm CAN fire: without it the pane would read `empty` for
# every row and both dispositions would look alike, which is the shape of
# vacuous green this suite exists to avoid.
_synth_pane() {
    local glyph="$1" out="$2"
    {
        printf '%s\n\n' "${ESC}[39m● Holding for the skeptic delta.${ESC}[0m"
        printf '%s\n\n' "${ESC}[38;5;246m✻ Brewed for 12s${ESC}[0m"
        printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
        printf '%s\n' "${ESC}[38;5;246m❯${NBSP}${ESC}[7m ${ESC}[0m${ESC}[39m${ESC}[49m        ${ESC}[2m${glyph}${ESC}[0m"
        printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
        printf '%s\n' "  ${ESC}[38;5;246m◉ Opus 5 │ █▎░░░░░░░▓ 124K/1.0M${ESC}[0m"
        printf '%s\n' "  ${ESC}[38;5;246m-- INSERT -- ⏵⏵ bypass permissions on${ESC}[0m"
    } > "$out"
}

# ---- read the manifest --------------------------------------------------
# Under `bash` explicitly. This suite's interactive caller is zsh on this
# host, where `mapfile` does not exist and fails as an EMPTY ARRAY (rc 127,
# unnoticed) — a zero population would read as "every row passed".
rows=$(grep -v '^[[:space:]]*#' "$MANIFEST" | grep -v '^[[:space:]]*$')
n_rows=$(printf '%s\n' "$rows" | grep -c . || true)
n_chrome=$(printf '%s\n' "$rows" | awk -F'\t' '$3=="chrome"' | grep -c . || true)
n_content=$(printf '%s\n' "$rows" | awk -F'\t' '$3=="content"' | grep -c . || true)

echo "=== Test 3 (first): the population is non-degenerate ==="
# Asserted BEFORE the row loops. A silently-empty enumeration makes loops 1
# and 2 iterate zero times and report nothing, which every other assertion
# in this file would then be consistent with.
if (( n_rows >= 12 )); then
    _th_pass; printf '  PASS: manifest carries %d rows (floor 12)\n' "$n_rows"
else
    _th_fail; printf '  FAIL: only %d manifest rows read — enumeration is suspect, refusing to draw conclusions\n' "$n_rows" >&2
fi
if (( n_chrome >= 6 )) && (( n_content >= 4 )); then
    _th_pass; printf '  PASS: both dispositions present (%d chrome / %d content)\n' "$n_chrome" "$n_content"
else
    _th_fail; printf '  FAIL: dispositions lopsided (%d chrome / %d content) — a one-sided manifest cannot catch a one-sided bug\n' \
        "$n_chrome" "$n_content" >&2
fi
assert_eq "every row is chrome or content (no unruled row)" "$(( n_chrome + n_content ))" "$n_rows"

echo
echo "=== Tests 1+2: every manifest row, against the real classifier ==="
while IFS=$'\t' read -r glyph codepoint disposition why; do
    [[ -n "${glyph:-}" ]] || continue
    case "$disposition" in
        chrome)  want_state=idle;             want_input=blank ;;
        content) want_state=autosuggest-only; want_input=ghost ;;
        *) _th_fail
           printf '  FAIL: %s (%s) — unknown disposition %q; only chrome|content are rulings\n' \
               "$glyph" "$codepoint" "$disposition" >&2
           continue ;;
    esac
    fx="$WORK/pane.ansi"
    _synth_pane "$glyph" "$fx"
    out=$("$HELPER" --fixture "$fx" --window 9 --name chromewin --active 0 2>&1)
    got_state=$(awk -F'[ =]' '{print $2}' <<<"$out")
    if [[ "$got_state" == "$want_state" ]] && grep -qE "(^| )input=$want_input( |\$)" <<<"$out"; then
        _th_pass
        printf '  PASS: %-3s %-8s %-8s → state=%s input=%s\n' \
            "$glyph" "$codepoint" "$disposition" "$want_state" "$want_input"
    else
        _th_fail
        printf '  FAIL: %s %s ruled %s — want state=%s input=%s, got: %s\n' \
            "$glyph" "$codepoint" "$disposition" "$want_state" "$want_input" "$out" >&2
    fi
done <<< "$rows"

echo
echo "=== Test 4: the manifest's stated ranges are the ranges the code implements ==="
# The manifest header names U+2500–U+257F and U+2580–U+259F. Those are the
# byte ranges below. If someone widens the code without moving the `■` / `⓿`
# edge rows, tests 1+2 catch it; if someone widens BOTH consistently but
# leaves the header prose behind, only this catches it. Prose that describes
# code that no longer behaves that way is how a manifest rots into decoration.
#
# Matched as the literal `$'…'` ESCAPE TEXT the source carries, not as the
# bytes it denotes: `_CHROME_BYTES` is written `$'(\xe2\x94[\x80-\xbf]|…)'`,
# so the file holds the eight characters `\`,`x`,`e`,`2`,… A first draft
# grepped for the decoded bytes and reported the ranges MISSING from the very
# file that implements them — a probe measuring something adjacent to its
# claim, which is the defect class this whole change is about.
for spec in '\xe2\x94[\x80-\xbf]:U+2500' '\xe2\x95[\x80-\xbf]:U+2540' '\xe2\x96[\x80-\x9f]:U+2580'; do
    pat="${spec%:*}"; label="${spec##*:}"
    if LC_ALL=C grep -qF -- "$pat" "$HELPER"; then
        _th_pass; printf '  PASS: pane-state.sh carries the %s byte range\n' "$label"
    else
        _th_fail; printf '  FAIL: pane-state.sh no longer carries the %s byte range the manifest describes\n' "$label" >&2
    fi
done

# EXPECTED-COUNT GUARD (your-org/nexus-code#807; required by
# test-summary-honesty-manifest.sh at the `ledger=yes` protection level).
# DERIVED from the manifest, not pinned to a literal: the row loop runs once
# per manifest row, so a literal would drift the moment a glyph is added and
# the guard would then be measuring its own staleness rather than this suite.
#   3  non-degenerate population assertions (Test 3, run first)
# + n  one per manifest row (Tests 1+2)
# + 3  byte-range assertions (Test 4)
EXPECTED=$(( 3 + n_rows + 3 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
