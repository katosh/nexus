#!/usr/bin/env bash
# test-claude-md-printf-status-clobber.sh — execute CLAUDE.md's
# PRINTF-STATUS-CLOBBER block.
#
# WHY THIS SUITE EXISTS. your-org/nexus-code#1202. Its host entry is the #928
# pipeline entry — "a pipeline's exit status is its LAST command's" — and what
# this block ADDS to that entry is that the defect NEEDS NO PIPE. `"$(cmd)"
# "$?"` in ONE argument list destroys the status just as thoroughly: arguments
# are evaluated LEFT TO RIGHT, so the command substitution RUNS — and writes
# `$?` — before the later `"$?"` is ever expanded. The status is destroyed by
# the act of building the line that reports it, which is the worst possible
# moment, because the artefact under construction IS a status report.
#
# WHAT IS ACTUALLY PINNED. Not "bash evaluates arguments". The three claims the
# entry makes, pinned SEPARATELY because conflating them is how a reader draws
# the wrong lesson:
#
#   (i)   THE CLOBBER — the wrong form reports `rc=0` for a command that
#         exited 1. The reported value is measured against the TRUE status,
#         obtained by a mechanism that involves no argument list at all
#         (Control B). And the wrong form EXITS 0 (Control C): the defect is
#         not that it fails, it is that it SUCCEEDS while lying.
#
#   (ii)  ORDER IS THE WHOLE MECHANISM — the BOUNDARY, drawn on the axis the
#         mechanism actually varies on. The SAME argument list with `"$?"`
#         moved LEFT of the substitution reports correctly. Pinned twice, and
#         deliberately: STATICALLY, by comparing the two forms' byte offsets of
#         `$(` and `"$?"`, and BEHAVIOURALLY, by running both. This is the half
#         that stops a reader concluding "avoid printf" — and Control D closes
#         the other two escape routes by measuring that an argument list with
#         NO substitution preserves the status, and that a bare `echo` with one
#         clobbers it. It is not about `basename` either: a second substitution
#         that exits 3 is reported as `3`, so `$?` names the SUBSTITUTION's
#         status, never the earlier command's.
#
#   (iii) `printf` IS ONLY THE AMPLIFIER — it RECYCLES its format string over
#         surplus arguments, so a format carrying ONE `%s` and TWO arguments
#         prints TWICE, and the second line is a plausible `rc=0` sitting in
#         the right column for a reader scanning a table. Pinned APART from the
#         clobber: the recycling is exercised with no substitution anywhere, so
#         the two facts cannot be read as one.
#
# SCOPE, STATED SO THE GREEN IS NOT OVER-READ. This is POSIX argument
# evaluation order, and the suite pins it on the shells actually installed
# here: GNU bash 4.4.20 and zsh 5.4.2. Both arms are MEASURED — the zsh arm is
# GATED on zsh being present and its assertions are added to the expected total
# only when it ran, so a silent skip cannot report the same number as a run.
# It is NOT a zsh-only trap, which matters because the neighbouring
# zsh-is-not-bash reflex is the wrong one to reach for: a bash-tested remedy
# does not exonerate it.
#
# What this suite does NOT pin, declared rather than implied: the #928 ad-hoc
# command-line caveat. BOTH known instances were typed into an agent Bash tool
# call, where no `set -o` from any file is in scope — that is a claim about the
# tool-call surface, not about a shell, and no in-repo fixture can witness it.
# `pipefail` could not help in any case: there is no pipe. Nor does this suite
# pin the version STRINGS; they are captured and printed into failure
# diagnostics, because a host whose shell evaluates arguments differently should
# turn this file RED and the remedy then is to update CLAUDE.md, not relax this
# file.
#
# CONTROLS:
#   A — the extracted form count is PINNED at 3, and a malformed extraction
#       ABORTS. An empty extraction satisfies every assertion below by having
#       none to make, which is #618's own shape: a suite that asserts nothing
#       announces a clean sweep.
#   B — POSITIVE CONTROL, derived by a DIFFERENT mechanism from the one under
#       test: the true status of the failing command is read as `$?` on the line
#       after it ran, with no argument list involved, and cross-checked against
#       a capture-first read inside a subshell. Every reported value below is
#       measured against that, not against the literal `1`.
#   C — the WRONG form EXITS 0, and so does every other form. None of these is
#       a failing command; they are succeeding commands that misdescribe.
#   D — the clobber requires a SUBSTITUTION. An argument list with none keeps
#       the status; `echo` with one loses it. Without D, every assertion above
#       would also pass against the theory "printf resets `$?`", which is the
#       wrong lesson and the one a reader is most likely to take.
#
# THE SUITE IS INSIDE ITS OWN SUBJECT MATTER, so note `_run` below: it captures
# `$?` on the very same line as the command, into a variable, before anything
# else executes. A harness that measured this defect with the defective form
# would report whatever it was built to expect.

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
th_claude_md_block_coverage PRINTF-STATUS-CLOBBER TIMEOUT-STATUS-INJECTION   # the entry's UNCHECKED share, in this suite's own output (#1239)

BASHV=$(bash --version 2>/dev/null | sed -n 1p)
ZSH_BIN=$(command -v zsh 2>/dev/null || true)
HAVE_ZSH=no
ZSHV='(zsh not installed)'
if [[ -n "$ZSH_BIN" && -x "$ZSH_BIN" ]]; then
    HAVE_ZSH=yes
    ZSHV=$("$ZSH_BIN" --version 2>/dev/null | sed -n 1p)
fi

WORK=$(mktemp -d) || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
OUTF="$WORK/out.txt"

# _run <command-line> → sets R_RC, R_NL, R_L1, R_L2.
# `$?` is read on the SAME line as the command it describes, into a variable,
# with nothing between. Output goes to a FILE so the line count is exact rather
# than inferred from a stripped command substitution.
_run() {
    local _form="$1"
    : > "$OUTF"
    eval "$_form" >"$OUTF" 2>/dev/null; R_RC=$?
    R_NL=$(wc -l <"$OUTF" | tr -d ' ')
    R_L1=$(sed -n '1p' "$OUTF")
    R_L2=$(sed -n '2p' "$OUTF")
}

# _rcfield <line> → the value of the line's `rc=` field, wherever it sits.
_rcfield() { printf '%s\n' "$1" | sed -E 's/.*rc=([^ ]*).*/\1/'; }

# _pos <haystack> <needle> → 1-based byte offset, or 0 when absent. Pure shell:
# `awk -v` would interpret the `\n` these forms carry as an escape.
_pos() {
    local _h="$1" _n="$2" _pre
    if [[ "$_h" != *"$_n"* ]]; then printf '0\n'; return; fi
    _pre="${_h%%"$_n"*}"
    printf '%s\n' "$(( ${#_pre} + 1 ))"
}

echo "shells under test: $BASHV / $ZSHV"
echo

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b='<!-- BEGIN PRINTF-STATUS-CLOBBER -->' -v e='<!-- END PRINTF-STATUS-CLOBBER -->' '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | grep -E '^bash ')

# CONTROL A — pin the count. Run through `grep -c` rather than an array: this
# file is read and edited under zsh, where `mapfile` does not exist and fails
# to an EMPTY array at rc 127, which is the very defect class this family
# documents.
FORM_COUNT=$(printf '%s\n' "$FORMS" | grep -c '^bash ')
assert_eq "Control A: extracted exactly 3 documented forms" "$FORM_COUNT" "3"
if [[ "$FORM_COUNT" != "3" ]]; then
    th_abort "block malformed — refusing to draw conclusions from it"
fi

F_WRONG=$(printf '%s\n' "$FORMS" | sed -n '1p')
F_ORDER=$(printf '%s\n' "$FORMS" | sed -n '2p')
F_CAPTURE=$(printf '%s\n' "$FORMS" | sed -n '3p')

assert_contains "form 1 is the WRONG form (substitution then \"\$?\")" "$F_WRONG"   'basename'
assert_contains "form 2 is the ORDER boundary (two %s fields)"        "$F_ORDER"   'name=%s'
assert_contains "form 3 is the capture-first remedy"                  "$F_CAPTURE" 'rc=$?'

# Property (iii) begins in the extracted TEXT: one %s against two arguments is
# what makes the wrong form print twice.
PCT_WRONG=$(printf '%s' "$F_WRONG" | grep -o '%s' | grep -c '%s')
PCT_ORDER=$(printf '%s' "$F_ORDER" | grep -o '%s' | grep -c '%s')
assert_eq "form 1's format carries exactly ONE %s — against TWO arguments" "$PCT_WRONG" "1"
assert_eq "form 2's format carries TWO, so it consumes both arguments"     "$PCT_ORDER" "2"

echo
echo '=== Property (ii), STATICALLY: the two forms differ only in ORDER ==='
# The boundary drawn on the axis the mechanism varies on, read off the text
# before anything is executed. If these offsets ever invert, the behavioural
# assertions below are measuring something other than order.
w_sub=$(_pos "$F_WRONG" '$('); w_st=$(_pos "$F_WRONG" '"$?"')
o_sub=$(_pos "$F_ORDER" '$('); o_st=$(_pos "$F_ORDER" '"$?"')
if (( w_sub > 0 && w_st > w_sub )); then
    printf '  PASS: %s\n' "form 1 puts the substitution ($w_sub) LEFT of \"\$?\" ($w_st)"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — sub@%s status@%s\n' "form 1 must put the substitution LEFT of \"\$?\"" "$w_sub" "$w_st" >&2; FAIL=$(( FAIL + 1 ))
fi
if (( o_st > 0 && o_sub > o_st )); then
    printf '  PASS: %s\n' "form 2 puts \"\$?\" ($o_st) LEFT of the substitution ($o_sub)"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — status@%s sub@%s\n' "form 2 must put \"\$?\" LEFT of the substitution" "$o_st" "$o_sub" >&2; FAIL=$(( FAIL + 1 ))
fi

echo
echo '=== CONTROL B: the TRUE status, by a mechanism with no argument list ==='
# Read as `$?` on the line after the command ran. Nothing about printf,
# substitutions or argument lists participates in producing this number, so it
# is a legitimate yardstick for every reported value below.
bash -c 'false'; TRUE_RC=$?
assert_eq "the failing command genuinely exits 1 (read directly from \$?)" "$TRUE_RC" "1"
# Cross-check by the documented capture-first idiom inside a subshell — a
# second derivation, still with no substitution in the reporting argument list.
CAPTURED_RC=$(bash -c 'false; rc=$?; printf "%s" "$rc"')
assert_eq "…and a capture-first read inside a subshell agrees"            "$CAPTURED_RC" "$TRUE_RC"

echo
echo '=== Property (i): THE CLOBBER — reported 0 for a command that exited 1 ==='
_run "$F_WRONG"; w_rc=$R_RC; w_nl=$R_NL; w_l1=$R_L1; w_l2=$R_L2
w_rep=$(_rcfield "$w_l2")
assert_eq "Control C: the WRONG form EXITS 0 — it succeeds while lying" "$w_rc" "0"
assert_eq "its first line is the substitution's OUTPUT, not a status"   "$w_l1" "rc=y"
assert_eq "its second line is a plausible status report"                "$w_l2" "rc=0"
assert_eq "…and the status it reports is 0"                            "$w_rep" "0"
if [[ "$w_rep" != "$TRUE_RC" ]]; then
    printf '  PASS: %s\n' "the reported status ($w_rep) DISAGREES with the true status ($TRUE_RC)"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — reported [%s] true [%s] under %s. If this shell stopped clobbering \$?, UPDATE the PRINTF-STATUS-CLOBBER block; do not relax this file.\n' \
        "the reported status must DISAGREE with the true status" "$w_rep" "$TRUE_RC" "$BASHV" >&2; FAIL=$(( FAIL + 1 ))
fi

echo
echo '=== Property (iii): printf RECYCLES — pinned apart from the clobber ==='
assert_eq "the WRONG form emits exactly TWO lines" "$w_nl" "2"
# No substitution anywhere: the recycling is a printf property on its own, and
# must not be inferred from the clobber demo.
: > "$OUTF"; bash -c 'printf "rc=%s\n" A B' >"$OUTF" 2>/dev/null; rec_rc=$?
rec_nl=$(wc -l <"$OUTF" | tr -d ' ')
rec_join=$(sed -n '1p;2p' "$OUTF" | tr '\n' '/')
assert_eq "one %s with two plain arguments also prints TWICE" "$rec_nl"   "2"
assert_eq "…recycling the format verbatim over the surplus"   "$rec_join" "rc=A/rc=B/"
assert_eq "…and that recycling itself exits 0"                "$rec_rc"   "0"

echo
echo '=== Property (ii), BEHAVIOURALLY: move "$?" LEFT and it reads right ==='
_run "$F_ORDER"; o_rc=$R_RC; o_nl=$R_NL; o_l1=$R_L1
o_rep=$(_rcfield "$o_l1")
assert_eq "the ORDER form exits 0"                                        "$o_rc"  "0"
assert_eq "…and reports the TRUE status — same list, \"\$?\" moved LEFT"   "$o_rep" "$TRUE_RC"
assert_eq "…on exactly ONE line: two %s consume both arguments"           "$o_nl"  "1"

_run "$F_CAPTURE"; c_rc=$R_RC; c_nl=$R_NL; c_l1=$R_L1
c_rep=$(_rcfield "$c_l1")
assert_eq "the capture-first remedy exits 0"          "$c_rc"  "0"
assert_eq "…and reports the TRUE status"              "$c_rep" "$TRUE_RC"
assert_eq "…on exactly ONE line"                      "$c_nl"  "1"

echo
echo '=== CONTROL D: it is the SUBSTITUTION, not printf and not an arg list ==='
# Escape route 1: "printf resets $?" / "an argument list resets $?". Same
# printf, same argument list, no substitution — the status survives.
: > "$OUTF"; bash -c 'false; printf "rc=%s\n" "$?"' >"$OUTF" 2>/dev/null
d_rep=$(_rcfield "$(sed -n '1p' "$OUTF")")
assert_eq "an argument list with NO substitution preserves the status" "$d_rep" "$TRUE_RC"

# Escape route 2: "it is a printf problem". Same clobber with no printf at all.
: > "$OUTF"; bash -c 'false; echo "$(basename /x/y)" "$?"' >"$OUTF" 2>/dev/null
e_l1=$(sed -n '1p' "$OUTF"); e_nl=$(wc -l <"$OUTF" | tr -d ' ')
assert_eq "a bare \`echo\` clobbers it identically — no printf involved" "$e_l1" "y 0"
assert_eq "…on ONE line, so the clobber is NOT the recycling"            "$e_nl" "1"

echo
echo '=== Corollary: `$?` names the SUBSTITUTION, not the earlier command ==='
# Not about `basename` either. A substitution that exits 3 is reported as 3 —
# so the value is a fresh write by the substitution, not a reset to zero and
# not the earlier command's status.
bash -c 'echo OUT; exit 3' >/dev/null 2>&1; SUB_RC=$?
assert_eq "the second substitution genuinely exits 3 (measured on its own)" "$SUB_RC" "3"
: > "$OUTF"; bash -c 'false; printf "rc=%s\n" "$(bash -c "echo OUT; exit 3")" "$?"' >"$OUTF" 2>/dev/null
s_rep=$(_rcfield "$(sed -n '2p' "$OUTF")")
assert_eq "…and the wrong form reports THAT, not 0 and not the earlier 1" "$s_rep" "$SUB_RC"
assert_eq "the reported value TRACKS the substitution, it is not a constant" "$w_rep/$s_rep" "0/$SUB_RC"

echo
echo "=== The SECOND shell: not a zsh-only trap (arm gated, $ZSHV) ==="
if [[ "$HAVE_ZSH" = "yes" ]]; then
    Z_WRONG="${F_WRONG/#bash /zsh }"
    Z_ORDER="${F_ORDER/#bash /zsh }"
    Z_CAPTURE="${F_CAPTURE/#bash /zsh }"
    _run "$Z_WRONG"; zw_rc=$R_RC; zw_nl=$R_NL; zw_l1=$R_L1; zw_l2=$R_L2
    assert_eq "zsh: the WRONG form EXITS 0 too"                  "$zw_rc" "0"
    assert_eq "zsh: line 1 is the substitution's output"         "$zw_l1" "rc=y"
    assert_eq "zsh: line 2 is the same plausible rc=0"           "$zw_l2" "rc=0"
    assert_eq "zsh: and it also RECYCLES into exactly TWO lines" "$zw_nl" "2"
    _run "$Z_ORDER";   zo_rep=$(_rcfield "$R_L1")
    _run "$Z_CAPTURE"; zc_rep=$(_rcfield "$R_L1")
    assert_eq "zsh: the ORDER form reports the TRUE status"      "$zo_rep" "$TRUE_RC"
    assert_eq "zsh: the capture-first remedy reports it too"     "$zc_rep" "$TRUE_RC"
else
    th_skip "second-shell arm (zsh)" "no zsh on PATH: the entry's \"identical in bash and zsh\" claim is UNMEASURED on this host, and 6 assertions did not run"
fi

echo
echo "=== TIMEOUT-STATUS-INJECTION: a wrapper INJECTS a status the callee cannot emit (#1248) ==="
# THE THIRD FAMILY MEMBER, and deliberately hosted here rather than in a new
# file. Its mechanism is the OPPOSITE of the clobber above: nothing executes
# between the command and the read of `$?`. The status is not DESTROYED by a
# later expansion — it is MANUFACTURED by a wrapper, and it is a value the
# callee can never produce, so every arm written against the tool's own
# vocabulary falls through to its DEFAULT.
#
# WHAT IS PINNED, and the third item is the one that matters most:
#   (i)   the INJECTION — the documented 124, and that one `echo` hides it as 0.
#   (ii)  PASSTHROUGH — an in-time callee's own status survives untouched, so
#         the injection is INTERMITTENT. This is also the POSITIVE CONTROL that
#         `timeout` is not simply overwriting every status: without it, every
#         assertion here would also pass against the theory "timeout always
#         returns 124", which is false and is the wrong lesson.
#   (iii) THE REMEDY'S OWN BLIND SPOT — `timeout -s KILL` injects 137 and
#         `--preserve-status` injects 143, so the obvious fix ("test for 124
#         first") is correct for the default and SILENTLY WRONG for the two
#         flags a careful author reaches for next. The documented form tests
#         the SET; a hand-written 124-only test is measured MISSING the 137.
#
# GATED on timeout(1) being present, and the gated assertions are added to the
# expected total only when the arm ran — a silent skip must not report the same
# number as a run.
TIMEOUT_BIN=$(command -v timeout 2>/dev/null || true)
HAVE_TIMEOUT=no
[[ -n "$TIMEOUT_BIN" && -x "$TIMEOUT_BIN" ]] && HAVE_TIMEOUT=yes

if [[ "$HAVE_TIMEOUT" = "yes" ]]; then
    TFORMS=$(awk -v b='<!-- BEGIN TIMEOUT-STATUS-INJECTION -->' -v e='<!-- END TIMEOUT-STATUS-INJECTION -->' '
        index($0, b) { inb = 1; next }
        index($0, e) { inb = 0 }
        inb' "$CLAUDE_MD" \
        | sed -E 's/^[[:space:]]+//' \
        | grep -vE '^```' \
        | sed -E 's/[[:space:]]{2,}#.*$//' \
        | grep -E '^bash ')

    # Same shape as Control A above: an empty extraction satisfies every
    # assertion below by having none to make (#618).
    TFORM_COUNT=$(printf '%s\n' "$TFORMS" | grep -c '^bash ')
    assert_eq "Control A2: extracted exactly 6 documented timeout forms" "$TFORM_COUNT" "6"
    if [[ "$TFORM_COUNT" != "6" ]]; then
        th_abort "TIMEOUT-STATUS-INJECTION block malformed — refusing to draw conclusions from it"
    fi

    T_BARE=$(printf '%s\n'   "$TFORMS" | sed -n '1p')
    T_HIDDEN=$(printf '%s\n' "$TFORMS" | sed -n '2p')
    T_KILL=$(printf '%s\n'   "$TFORMS" | sed -n '3p')
    T_PRES=$(printf '%s\n'   "$TFORMS" | sed -n '4p')
    T_PASS=$(printf '%s\n'   "$TFORMS" | sed -n '5p')
    T_FIX=$(printf '%s\n'    "$TFORMS" | sed -n '6p')

    assert_contains "form 3 is the -s KILL hardening"          "$T_KILL" '-s KILL'
    assert_contains "form 4 is the --preserve-status form"     "$T_PRES" '--preserve-status'
    assert_contains "form 6 tests the SET, not just 124"       "$T_FIX"  '137'

    # (i) THE INJECTION.
    _run "$T_BARE";   t_bare=$(_rcfield "$R_L1")
    assert_eq "form 1: the wrapper injects 124"                       "$t_bare"    "124"
    # CONTROL B2 — the same value derived by a DIFFERENT mechanism, with no
    # argument list and no `echo` in the way. Note WHY this control is not
    # optional: the form's OWN exit status is the trailing `echo`'s, i.e. 0 —
    # this bullet's host defect, met inside the suite that documents it. The
    # 124 is what `$?` READ, never what the form returned.
    : > "$OUTF"; bash -c 'timeout 1 sleep 5' >"$OUTF" 2>/dev/null; t_direct_rc=$?
    assert_eq "…and the TRUE status, read with no echo in the way, is that same 124" \
              "$t_direct_rc" "$t_bare"

    _run "$T_HIDDEN"; t_hidden=$(_rcfield "$R_L2")
    assert_eq "form 2: ONE echo hides the injected status as rc=0"    "$t_hidden" "0"
    if [[ "$t_hidden" != "$t_bare" ]]; then
        printf '  PASS: %s\n' "the hidden form ($t_hidden) DISAGREES with the injected status ($t_bare)"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — hidden [%s] injected [%s]\n' "the hidden form must disagree with the injected status" "$t_hidden" "$t_bare" >&2; FAIL=$(( FAIL + 1 ))
    fi

    # (ii) PASSTHROUGH — the positive control. `timeout` is NOT a constant.
    _run "$T_PASS"; t_pass=$(_rcfield "$R_L1")
    assert_eq "form 5: an IN-TIME callee's own status passes through untouched" "$t_pass" "11"
    if [[ "$t_pass" != "$t_bare" ]]; then
        printf '  PASS: %s\n' "the injection is INTERMITTENT: passthrough ($t_pass) != injected ($t_bare)"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — passthrough [%s] injected [%s]. If timeout stopped passing the callee status through, UPDATE the block.\n' \
            "passthrough must differ from the injected value" "$t_pass" "$t_bare" >&2; FAIL=$(( FAIL + 1 ))
    fi

    # (iii) THE REMEDY'S BLIND SPOT — three DISTINCT manufactured values.
    _run "$T_KILL"; t_kill=$(_rcfield "$R_L1")
    _run "$T_PRES"; t_pres=$(_rcfield "$R_L1")
    assert_eq "form 3: -s KILL injects 137, NOT 124"                      "$t_kill" "137"
    assert_eq "form 4: --preserve-status injects 143 — the name misleads" "$t_pres" "143"
    assert_eq "three DISTINCT manufactured values, none of them equal"    \
              "$( [[ "$t_bare" != "$t_kill" && "$t_kill" != "$t_pres" && "$t_bare" != "$t_pres" ]] && echo distinct || echo collided )" "distinct"

    # The documented remedy catches the DEFAULT and the HARDENED form alike.
    _run "$T_FIX"; t_fix_out=$R_L1
    assert_eq "form 6: the documented remedy names the wrapper" "$t_fix_out" "WRAPPER, not a tool verdict"
    T_FIX_KILL=${T_FIX/timeout 1 sleep 5/timeout -s KILL 1 sleep 5}
    if [[ "$T_FIX_KILL" = "$T_FIX" ]]; then
        th_abort "substitution into form 6 did not apply — the -s KILL arm would test nothing"
    fi
    _run "$T_FIX_KILL"
    assert_eq "…and it ALSO catches the 137 that -s KILL injects" "$R_L1" "WRAPPER, not a tool verdict"

    # THE NEGATIVE CONTROL THAT IS THE ENTRY: the natural, narrower remedy.
    _run 'bash -c '"'"'timeout -s KILL 1 sleep 5; rc=$?; case $rc in 124) echo "CAUGHT";; esac'"'"''
    assert_eq "a 124-ONLY test is SILENT on the same 137 — the obvious remedy under-covers" "$R_L1" ""
    assert_eq "…and exits 0 while saying nothing, which is why it reads as clean" "$R_RC" "0"

    # The class, stated as a set relation rather than as a list of numbers:
    # every manufactured value lies OUTSIDE a real callee's documented
    # vocabulary. `skeptic-channel.sh await` documents 0|1|2|4|10|11|12.
    CALLEE_VOCAB=" 0 1 2 4 10 11 12 "
    _overlap=0
    for _v in "$t_bare" "$t_kill" "$t_pres"; do
        case "$CALLEE_VOCAB" in *" $_v "*) _overlap=$(( _overlap + 1 )) ;; esac
    done
    assert_eq "every manufactured value is OUTSIDE the callee's documented vocabulary" "$_overlap" "0"
else
    th_skip "TIMEOUT-STATUS-INJECTION arm" \
            "timeout(1) not on PATH: the block's measured statuses are UNMEASURED on this host, and 18 assertions did not run"
fi

# ---- assertion-count guard (your-org/nexus-code#946 F6) -------------------
# A missing assert_* helper (a typo → rc 127) is counted by NOTHING: the suite
# still prints ALL TESTS PASSED with a quietly smaller total. The zsh arm is
# conditional, so the expectation is bumped only when it actually ran — a
# silent skip must not report the same total as a run.
EXPECTED_ASSERTIONS=32
# ARITHMETIC BUMP, not a comparison of a total to an expectation. Written with
# a single `=` on purpose: `test-summary-honesty-manifest.sh`'s `_count_axis`
# reads any line carrying EXPECTED/ASSERTION plus `==` as the count guard, and
# a `==` here would hand it a line that guards nothing (the documented
# classifier hole; the backtick-substitution suite hit exactly this). Do not
# normalise it back.
[[ "$HAVE_ZSH" = "yes" ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 6 ))
[[ "$HAVE_TIMEOUT" = "yes" ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 18 ))
TOTAL_ASSERTIONS=$(( PASS + FAIL ))
assert_eq "assertion TOTAL matches the EXPECTED total — no assertion silently dropped or added" "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
