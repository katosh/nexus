#!/usr/bin/env bash
# test-claude-md-grep-bre-dialect.sh — execute CLAUDE.md's GREP-BRE-DIALECT block.
#
# WHY THIS SUITE EXISTS. your-org/nexus-code#1158: in BRE, GNU's `\+` is the
# ONE-OR-MORE OPERATOR, so `^\+\+\+` — the standard idiom for "the `+++` diff
# header" — matches EVERY line beginning with any run of `+`. Under `-v` it
# deletes precisely the lines the pipeline exists to keep. It fired inside this
# repo's own leak screen, where `0 added lines examined` reads as "no
# identifiers found" about material whose exposure would be permanent.
#
# WHAT IS ACTUALLY PINNED, and the second item is the entry:
#
#   the DIALECT     — against one planted fixture, the four documented forms
#                     answer 3 / 1-kept / 1 / 1. A grep that stopped behaving
#                     this way turns this suite RED, which is the intended
#                     signal; the remedy then is to update CLAUDE.md, not to
#                     relax this file.
#   the INVERSION   — `command grep` bypasses a shell FUNCTION by construction,
#                     so a wrapper that would have refused the pattern cannot.
#                     The loud call becomes a quiet wrong answer. This is the
#                     half that makes the neighbouring #618 remedy actively
#                     harmful here, and it is the reason the entry exists.
#   the REVERSAL    — the block's lower half (added 2026-09-05, recorded on
#                     your-org/nexus-code#1461): the SAME wrapper, the OTHER
#                     punctuation character, the OPPOSITE polarity. ugrep -G
#                     reads a MID-PATTERN `$` as an end-of-line anchor where GNU
#                     BRE reads a literal, so `grep -c 'x=$(cmd'` is 1 under GNU
#                     and 0 at rc 1 with EMPTY stderr through the wrapper — a
#                     silent zero on the `$(` of a command substitution. Here
#                     GNU is right and the wrapper is the silent one, so
#                     `command grep` is the REMEDY on this half and the
#                     anti-remedy on the half above; `-F` is the one remedy both
#                     halves share, and `\$` the escape. Measured on a two-line
#                     fixture (ugrep 7.8.4 vs GNU grep 3.1) before it was written
#                     down. What is pinned, as for the half above, is the
#                     STRUCTURE: through a stand-in that anchors a mid-pattern
#                     `$` the call is a silent zero; through `command`, `-F` or
#                     `\$` the same call answers 1; an END-anchored `$` passes
#                     through the stand-in untouched (Control E), so the
#                     stand-in is specific to the MID-pattern case exactly as
#                     the wrapper was measured to be.
#
# SCOPE, STATED SO THE GREEN IS NOT OVER-READ. This suite does NOT pin ugrep's
# message or its exit code — and NOT because ugrep is absent, which is what
# this comment used to say. Measured on this host: `command -v ugrep` finds
# NOTHING (rc 1), while `grep --version` reports `ugrep 7.8.4`, because Claude
# Code's shell snapshot defines `grep` as a FUNCTION running ugrep EMBEDDED in
# the `claude` executable — so an agent's bare `grep` IS the `--ignore-files`
# wrapper. A bare absence check cannot see the second fact, which is exactly
# how the "not installed" caveat got written (`#1233`, `#1273`); CLAUDE.md
# carries the same measured pair. The reason to leave ugrep unpinned is the
# OTHER one: WHICH implementation a bare `grep` resolves to is a property of
# the HARNESS BUILD, not of this repo, so an assertion about it would be green
# here and red for another operator. The ugrep behaviour itself stays #1158's
# field observation, not this block's claim. What this suite pins instead is the
# STRUCTURAL fact that survives every host: a shell function is reachable by a
# bare call and unreachable through `command`. The wrapper here is a declared
# STAND-IN, in the manner of test-claude-md-618-remedies.sh, and it emulates
# ONLY the two behaviours observed — it refuses a BRE `\+` pattern, and it
# anchors a mid-pattern `$` — a blanket refuser would make the inversion arm
# pass for the wrong reason, which Controls D and E below are what rule out.
#
# CONTROLS:
#   A — the extracted form count is PINNED at 4. An empty extraction satisfies
#       every assertion by having none to make (#618's own shape).
#   B — POSITIVE CONTROL. The fixture's `+++three` line is known present and is
#       located by a form that uses NO grep at all (awk), so the expected value
#       does not come from the mechanism under test.
#   C — the WRONG form EXITS 0. The defect is not that it fails; it is that it
#       SUCCEEDS while lying. A remedy that only checked counts would miss the
#       day grep started erroring instead — which would be worth noticing.
#   D — the STAND-IN is not a blanket refuser: the ERE form passes THROUGH it
#       to the real binary and answers correctly. Without this, the inversion
#       arm would pass against a wrapper that refuses everything.
#   E — the stand-in's ANCHORING is MID-pattern-specific: a pattern whose `$`
#       is at the END (`x=$`) passes through and answers 1 under both, as the
#       real wrapper does. Without this, the silent-zero arm would pass against
#       a stand-in that zeroes every pattern containing `$`.
#   F — POSITIVE CONTROL for the second fixture, again WITHOUT grep (awk
#       `index`): the shell-source fixture holds exactly 1 line carrying the
#       literal `x=$(cmd`, and exactly 1 line ending in `x=`.

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
th_claude_md_block_coverage GREP-BRE-DIALECT   # the entry's UNCHECKED share, in this suite's own output (#1239)

# The real binary, resolved without any wrapper — used by the harness itself so
# the harness never measures with the thing it is testing.
REAL_GREP=$(command -v grep 2>/dev/null || true)
[[ -x "$REAL_GREP" ]] || REAL_GREP=/bin/grep

GREPV=$("$REAL_GREP" --version 2>&1 | sed -n 1p)

WORK=$(mktemp -d) || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# ---- fixture -------------------------------------------------------------
# Four lines, chosen so the three documented answers are DIFFERENT numbers: a
# fixture where the right and wrong forms agree proves nothing.
FIX="$WORK/diff.txt"
printf '%s\n' '+one' '++two' '+++three' 'plain' > "$FIX"
# The shell-source fixture for the block's lower half. `x=cmd` is a decoy: a
# stand-in (or a grep) that merely DROPPED the `$` would count 2, not 1, so the
# expected 1 cannot be reached by deleting the character instead of anchoring
# on it. `x=` is the END-anchor control's target (Control E).
SRC="$WORK/src.sh"
printf '%s\n' 'x=$(cmd)' 'x=cmd' 'x=' 'plain' > "$SRC"

# ---- assertion-count guard (your-org/nexus-code#946 F6) ------------------
# A missing assert_* helper (a typo -> rc 127) is counted by NOTHING: the suite
# still prints ALL TESTS PASSED with a quietly smaller total. Every exit path
# goes through this helper, so a guard on the happy path only cannot be the
# shape here.
_th_count_guard() {
    local EXPECTED_ASSERTIONS=41
    local TOTAL_ASSERTIONS=$(( PASS + FAIL ))
    assert_eq "assertion TOTAL matches the EXPECTED total" \
              "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"
    th_summary_and_exit
}

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b='<!-- BEGIN GREP-BRE-DIALECT -->' -v e='<!-- END GREP-BRE-DIALECT -->' '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | "$REAL_GREP" -vE '^```' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | "$REAL_GREP" -E '^(grep|command grep) ')

FORM_COUNT=$(printf '%s\n' "$FORMS" | "$REAL_GREP" -cE '^(grep|command grep) ')
assert_eq "Control A: extracted exactly 8 documented forms" "$FORM_COUNT" "8"
if [[ "$FORM_COUNT" != "8" ]]; then
    th_abort "block malformed — refusing to draw conclusions from it"
fi

F_BRE=$(printf   '%s\n' "$FORMS" | sed -n '1p')
F_CMDV=$(printf  '%s\n' "$FORMS" | sed -n '2p')
F_ERE=$(printf   '%s\n' "$FORMS" | sed -n '3p')
F_FIXED=$(printf '%s\n' "$FORMS" | sed -n '4p')
F_DOLLAR=$(printf     '%s\n' "$FORMS" | sed -n '5p')
F_DOLLAR_CMD=$(printf '%s\n' "$FORMS" | sed -n '6p')
F_DOLLAR_ESC=$(printf '%s\n' "$FORMS" | sed -n '7p')
F_DOLLAR_F=$(printf   '%s\n' "$FORMS" | sed -n '8p')

assert_contains "form 1 is the BRE counting form"          "$F_BRE"   "grep -c "
assert_contains "form 2 is the command-grep excluding form" "$F_CMDV"  "command grep -v"
assert_contains "form 3 is the ERE form"                    "$F_ERE"   "-cE"
assert_contains "form 4 is the fixed-string form"           "$F_FIXED" "-cF"
assert_contains "form 5 is the bare mid-pattern-\$ BRE form"  "$F_DOLLAR"     "grep -c  'x=\$(cmd'"
assert_contains "form 6 is the same pattern through command"  "$F_DOLLAR_CMD" "command grep -c 'x=\$(cmd' SRC"
assert_contains "form 7 escapes the \$"                       "$F_DOLLAR_ESC" "'x=\\\$(cmd'"
assert_contains "form 8 is the fixed-string form of it"       "$F_DOLLAR_F"   "-cF 'x=\$(cmd'"

# _subst FORM → the form with the placeholder TOKENS `DIFF` and `SRC` replaced
# by the fixture paths. Token-wise on purpose: a `${1//DIFF/$FIX}` followed by
# `${_f//SRC/$SRC}` would re-scan the first fixture's mktemp-random PATH for the
# second token, and a random path can contain `SRC`. Only whole whitespace-
# delimited tokens are replaced, and each token exactly once.
_subst() {
    local _t _out=""
    for _t in $1; do
        case "$_t" in
            DIFF) _t=$FIX ;;
            SRC)  _t=$SRC ;;
        esac
        _out="${_out:+$_out }$_t"
    done
    printf '%s' "$_out"
}

# run_form FORM -> prints stdout on line 1..n; rc captured separately.
_run() {  # _run <form>  → echoes "<rc>|<first line of stdout>"
    local _f _o _rc
    _f=$(_subst "$1")
    _o=$(eval "$_f" 2>/dev/null); _rc=$?
    printf '%s|%s\n' "$_rc" "$(printf '%s' "$_o" | sed -n 1p)"
}

echo
echo '=== Control B: a POSITIVE CONTROL derived WITHOUT grep ==='
# awk, not grep: the expected value must not come from the mechanism under test.
# BRACKET EXPRESSIONS, not `\+`. This control is what every other assertion is
# measured against, so it must not itself depend on a dialect: `\+` inside an
# awk ERE is a non-special-character escape, which POSIX leaves UNDEFINED.
# `[+]` means one literal plus in every awk. (Measured identical under GNU Awk
# 4.1.4 here — the change removes a dependency, it does not fix a wrong number.)
known_triple=$(awk '/^[+][+][+]/ { n++ } END { print n + 0 }' "$FIX")
known_anyplus=$(awk '/^[+]/ { n++ } END { print n + 0 }' "$FIX")
assert_eq "the fixture holds exactly 1 line starting with three +" "$known_triple"  "1"
assert_eq "…and exactly 3 lines starting with ANY run of +"        "$known_anyplus" "3"

echo
echo '=== The documented answers: same fixture, four forms, three answers ==='
r=$(_run "$F_BRE");   bre_rc=${r%%|*};   bre_out=${r#*|}
assert_eq "Control C: the BRE form EXITS 0 (it is SILENT, not broken)" "$bre_rc" "0"
if [[ "$bre_out" == "$known_anyplus" ]]; then
    printf '  PASS: %s\n' "the BRE form counts EVERY +-prefixed line ($bre_out), not the header"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — got [%s] want [%s] under %s. If this grep stopped treating BRE \\+ as one-or-more, UPDATE the GREP-BRE-DIALECT block; do not relax this file.\n' \
        "the BRE form counts EVERY +-prefixed line" "$bre_out" "$known_anyplus" "$GREPV" >&2
    FAIL=$(( FAIL + 1 ))
fi

r=$(_run "$F_ERE");   assert_eq "the ERE form counts only the real header"        "${r#*|}" "$known_triple"
r=$(_run "$F_FIXED"); assert_eq "the fixed-string form agrees with the ERE form"  "${r#*|}" "$known_triple"

# The excluding form is the one whose failure direction is "delete everything".
kept=$(eval "$(_subst "$F_CMDV")" 2>/dev/null | "$REAL_GREP" -c . || true)
assert_eq "the -v form KEEPS 1 of 4 lines — it deleted the added lines, not the header" \
          "$kept" "1"

echo
echo '=== THE INVERSION: `command` makes a LOUD wrapper unreachable ==='
# A declared STAND-IN for the operator's `grep` shell function. It emulates the
# two behaviours observed — #1158's: a BRE pattern carrying `\+` is refused,
# LOUDLY; and the 2026-09-05 measurement's: a BRE pattern carrying an unescaped
# `$` that is NOT the last character is anchored there, so it matches NOTHING,
# SILENTLY (`-c` prints 0, rc 1, nothing on stderr — byte-for-byte what ugrep
# 7.8.4 did). Nothing else: `-E`/`-F` calls, an escaped `\$`, and an END `$`
# all pass through to the real binary. Written in the POSIX subset so it is
# legal in both shells.
read -r -d '' STANDIN <<'PREAMBLE' || true
grep() {
    _ere=0; _count=0; _pat=
    for _a in "$@"; do
        case "$_a" in -*E*|-*F*) _ere=1 ;; esac
        case "$_a" in -*c*) _count=1 ;; esac
    done
    for _a in "$@"; do
        case "$_a" in -*) ;; *) _pat=$_a; break ;; esac
    done
    if [ "$_ere" -eq 0 ]; then
        for _a in "$@"; do
            case "$_a" in
                *'\+'*) echo "grep-standin: bad repetition operator in BRE pattern" >&2; return 2 ;;
            esac
        done
        _bare=$(printf '%s\n' "$_pat" | sed 's/\\\$//g')
        case "$_bare" in
            *'$'?*) [ "$_count" -eq 1 ] && echo 0; return 1 ;;
        esac
    fi
    command grep "$@"
}
PREAMBLE

_via_standin() {  # _via_standin <command-line> → "<rc>|<stdout1>|<stderr-bytes>"
    local _cmd _o _rc _e
    _cmd=$(_subst "$1")
    _e="$WORK/err.$$"
    _o=$(bash -c "$STANDIN
$_cmd" 2>"$_e"); _rc=$?
    printf '%s|%s|%s\n' "$_rc" "$(printf '%s' "$_o" | sed -n 1p)" "$(wc -c <"$_e" | tr -d ' ')"
}

loud=$(_via_standin "$F_BRE")
loud_rc=${loud%%|*}; loud_rest=${loud#*|}; loud_out=${loud_rest%%|*}; loud_err=${loud_rest#*|}
assert_eq  "through the FUNCTION the BRE form is LOUD: non-zero rc"   "$loud_rc" "2"
assert_eq  "…and produced no count at all"                            "$loud_out" ""
if (( loud_err > 0 )); then
    printf '  PASS: %s\n' "…and wrote a diagnostic to stderr ($loud_err bytes)"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "…and wrote a diagnostic to stderr — got 0 bytes" >&2; FAIL=$(( FAIL + 1 ))
fi

quiet=$(_via_standin "command $F_BRE")
quiet_rc=${quiet%%|*}; quiet_rest=${quiet#*|}; quiet_out=${quiet_rest%%|*}; quiet_err=${quiet_rest#*|}
assert_eq 'through the `command` builtin the SAME call exits 0'        "$quiet_rc"  "0"
assert_eq "…returns the WRONG answer instead of the diagnostic"        "$quiet_out" "$known_anyplus"
assert_eq "…and stderr is EMPTY — the only signal has been removed"    "$quiet_err" "0"

echo
echo '=== Control D: the stand-in is NOT a blanket refuser ==='
# Without this, every assertion above would also pass against a wrapper that
# refused every call, and the inversion arm would be measuring nothing.
passthru=$(_via_standin "$F_ERE")
pt_rc=${passthru%%|*}; pt_rest=${passthru#*|}; pt_out=${pt_rest%%|*}
assert_eq "the ERE form passes THROUGH the stand-in to the real binary" "$pt_rc"  "0"
assert_eq "…and answers correctly, so the refusal is pattern-specific"  "$pt_out" "$known_triple"

echo
echo '=== Control F: the shell-source fixture, POSITIVE CONTROL WITHOUT grep ==='
# awk index(), not a regex: the expected value must not depend on ANY dialect's
# reading of `$` or `(`.
known_subst=$(awk 'index($0, "x=$(cmd") > 0 { n++ } END { print n + 0 }' "$SRC")
known_endx=$(awk 'substr($0, length($0) - 1) == "x=" { n++ } END { print n + 0 }' "$SRC")
assert_eq "the source fixture holds exactly 1 line carrying the literal x=\$(cmd" "$known_subst" "1"
assert_eq "…and exactly 1 line ENDING in x= (the END-anchor control's target)"  "$known_endx"  "1"

echo
echo '=== THE REVERSAL, GNU side: a mid-pattern $ is a LITERAL in GNU BRE ==='
r=$(_run "$F_DOLLAR"); dol_rc=${r%%|*}; dol_out=${r#*|}
assert_eq "the bare BRE form EXITS 0 under the real binary" "$dol_rc" "0"
if [[ "$dol_out" == "$known_subst" ]]; then
    printf '  PASS: %s\n' "…and finds the line ($dol_out): GNU BRE reads the mid-pattern \$ as a literal"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — got [%s] want [%s] under %s. If this grep stopped treating a mid-pattern \$ as a literal, UPDATE the GREP-BRE-DIALECT block; do not relax this file.\n' \
        "the bare BRE form finds the line" "$dol_out" "$known_subst" "$GREPV" >&2
    FAIL=$(( FAIL + 1 ))
fi
r=$(_run "$F_DOLLAR_CMD"); assert_eq "the command-grep form agrees (no wrapper in this harness to bypass)" "${r#*|}" "$known_subst"
r=$(_run "$F_DOLLAR_ESC"); assert_eq "the escaped form agrees"                                          "${r#*|}" "$known_subst"
r=$(_run "$F_DOLLAR_F");   assert_eq "the fixed-string form agrees"                                     "${r#*|}" "$known_subst"

echo
echo '=== THE REVERSAL, wrapper side: through the FUNCTION the same call is a SILENT ZERO ==='
sz=$(_via_standin "$F_DOLLAR")
sz_rc=${sz%%|*}; sz_rest=${sz#*|}; sz_out=${sz_rest%%|*}; sz_err=${sz_rest#*|}
assert_eq "through the FUNCTION the bare BRE form exits 1 — a no-match, not an error" "$sz_rc"  "1"
assert_eq "…and prints a count of 0"                                                  "$sz_out" "0"
assert_eq "…and stderr is EMPTY — nothing distinguishes it from a true negative"      "$sz_err" "0"

cmd_via=$(_via_standin "$F_DOLLAR_CMD")
cv_rc=${cmd_via%%|*}; cv_rest=${cmd_via#*|}; cv_out=${cv_rest%%|*}
assert_eq 'through the `command` builtin the SAME call exits 0'                    "$cv_rc"  "0"
assert_eq "…and finds the line: HERE bypassing the wrapper is the REMEDY"           "$cv_out" "$known_subst"

esc_via=$(_via_standin "$F_DOLLAR_ESC")
ev_rest=${esc_via#*|}
assert_eq "the escaped \\\$ form passes THROUGH the stand-in and finds the line"     "${ev_rest%%|*}" "$known_subst"
f_via=$(_via_standin "$F_DOLLAR_F")
fv_rest=${f_via#*|}
assert_eq "the -F form passes THROUGH the stand-in and finds the line"              "${fv_rest%%|*}" "$known_subst"

echo
echo '=== Control E: the stand-in anchors MID-pattern only — an END $ passes through ==='
END_FORM="grep -c 'x=\$' SRC"
r=$(_run "$END_FORM");          assert_eq "an END-anchored \$ under the real binary finds the x= line" "${r#*|}" "$known_endx"
e_via=$(_via_standin "$END_FORM"); e_rest=${e_via#*|}
assert_eq "…and the SAME call through the stand-in agrees, so the zero above is specific to a MID-pattern \$" "${e_rest%%|*}" "$known_endx"

_th_count_guard
