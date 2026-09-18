#!/usr/bin/env bash
# test-claude-md-python-backref-escape.sh — execute CLAUDE.md's
# PYTHON-BACKREF-ESCAPE block.
#
# WHY THIS SUITE EXISTS. your-org/nexus-code#1203: a `sed`/`awk` backreference
# written inside a NON-RAW Python string literal is silently destroyed. `"\1"`
# is a valid Python OCTAL escape and becomes the byte `0x01`; `\(`, `\)`, `\+`,
# `\.`, `\d`, `\w`, `\s` are not Python escapes and survive verbatim. So in a
# regex dense with escaped punctuation, exactly the one character carrying the
# RESULT is replaced by a control byte and everything around it passes through
# untouched. It is the AUTHORING-path twin of the BACKTICK-SUBSTITUTION entry
# above it: there a shell layer eats your text on the way OUT, here a Python
# literal eats it on the way IN, and both arrive as a plausible artefact at
# rc 0. In the instance the `0x01` reached a `[[ -z "$n" ]]` guard, which read
# it as a pin successfully found, and a test runner aborted before dispatching
# a single suite — a suite that ran zero tests and did not say so.
#
# WHAT IS ACTUALLY PINNED, and the first two are the entry:
#
#   (i)  THE INVERSE ESCAPE SET. The two probes a reader reaches for — a
#        high-numbered backreference (`\9`) and `\d` — both come back INTACT,
#        so generalising from them walks you into `\1`. This is pinned twice
#        and deliberately: once as the ASYMMETRY IN ONE MEASUREMENT (`\1`
#        corrupted while `\8`/`\9` survive, same literal, same call, so no
#        reader can attribute the difference to the probe), and once as the
#        whole documented CONSUMED/SURVIVE table driven as DATA — including the
#        four punctuation escapes the entry names, which are the ones that make
#        a corrupted regex look intact.
#
#   (ii) THE TOOLING IS BLIND TO THE DESTRUCTIVE HALF. `-W error` (and flake8
#        W605, and every linter of that family) flag the INVALID escape `\d`
#        and are SILENT on the VALID escape `\1`. Both rcs are asserted. This
#        is the property that makes the defect undetectable by the tooling
#        built for exactly this class, and it is why the entry exists at all
#        rather than being a footnote to "use r-strings".
#
#   (iii) THE CORRUPTED REGEX STILL WORKS AS A MATCHER. The capture group is
#        intact, `sed` exits 0 and still emits one line per input, and only the
#        REPLACEMENT is wrong. No stage is ever empty, so nothing downstream
#        has anything to disagree with — this repo's dominant defect class
#        (silence used as a proxy for absence) arriving as a control byte
#        rather than as a missing row.
#
# SCOPE, STATED SO THE GREEN IS NOT OVER-READ. The two halves have DIFFERENT
# scopes and conflating them would be the dishonest reading:
#
#   * THE CORRUPTION is a LANGUAGE fact. Octal escapes are in the Python
#     language spec, so `"\1"` is the byte `0x01` on every interpreter and
#     `r""` is the fix on every interpreter. Arms 1-3, the escape-set table and
#     the sed-matcher arms pin that.
#   * THE WARNING BEHAVIOUR IS VERSION-SCOPED and this suite pins only what it
#     measured. On the interpreter recorded by Control E (3.6.9 as written)
#     `-W error` turns the invalid escape into a SyntaxError at rc 1. Later
#     versions moved the warning's CATEGORY (DeprecationWarning ->
#     SyntaxWarning in 3.12), so the rc-1 arm is a measurement on THIS
#     interpreter and is NOT asserted as universal. What IS
#     version-independent, and is the load-bearing half, is the SILENCE on the
#     valid escape: a valid escape produces no warning to convert, so form 4's
#     rc 0 with EMPTY stderr holds wherever the language spec does. If the
#     rc-1 arm reddens on a newer interpreter, the fix is to widen the
#     PYTHON-BACKREF-ESCAPE block's scope sentence — not to relax this file.
#
# CONTROLS:
#   A — the extracted form count is PINNED at 5. An empty or malformed
#       extraction satisfies every assertion by having none to make, which is
#       #618's own shape and the reason this family aborts instead of passing.
#   B — POSITIVE CONTROLS, both derived by mechanisms with NO Python in them,
#       so the suite cannot agree with itself:
#         B1 the SHELL's own `printf '\1'` supplies the expected byte value,
#            independently of what Python does with the same spelling;
#         B2 AWK (not python, not sed) supplies the fixture's captured digits,
#            so the raw-string arm's expected output is not built by the
#            machinery under test.
#   C — the WRONG forms EXIT 0. The defect is not that they fail; it is that
#       they SUCCEED while lying. Asserted for the non-raw literal, for the
#       `-W error` valid escape, and for `sed` fed the corrupted expression. If
#       any of them ever starts erroring instead, that is worth noticing and
#       should turn this suite RED.
#   D — the SURVIVE half of the escape table is asserted to be backslash+char
#       and not merely "length 2", so a probe that mangled both halves equally
#       could not satisfy it.
#   E — the interpreter version is measured and asserted to have a version
#       SHAPE, so the scope paragraph above is grounded in a value this run
#       actually read rather than in a number somebody typed.
#
# PYTHON ABSENCE IS A SKIP, NOT AN ABORT (your-org/nexus-code#946 F7), matching
# the zsh-dependent suites in this family. Block extraction and both positive
# controls need no Python and still run.
#
# A NOTE ON THE IRONY, because the next editor will hit it. This file is a
# fixture that CONTAINS the very idioms the source-text lints in this directory
# grep for, and it must contain them or it pins nothing. Every Python probe is
# written into $WORK through a QUOTED heredoc (`<<'EOF'`), so the shell never
# expands it and the escapes reach the interpreter as typed; the escape-set
# table builds its backslash with `chr(92)` rather than writing one, so the
# TABLE arm carries no literal escape sequence at all. No filename-based
# exemption is used or needed.

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
th_claude_md_block_coverage PYTHON-BACKREF-ESCAPE   # the entry's UNCHECKED share, in this suite's own output (#1239)

HAVE_PY=no
PYV=unknown
if command -v python3 >/dev/null 2>&1; then
    HAVE_PY=yes
    PYV=$(python3 -c 'import sys; print(sys.version.split()[0])' 2>/dev/null || echo unknown)
else
    th_skip "every python-dependent arm" \
            "python3 is not on PATH — the corruption, the escape-set table, the -W error pair, the r-string remedy and both sed-matcher arms could NOT be exercised on this host; only the block extraction and the two non-Python positive controls ran"
fi

WORK=$(mktemp -d) || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# ---- assertion-count guard (your-org/nexus-code#946 F6) ------------------
# A missing assert_* helper (a typo -> rc 127) is counted by NOTHING: the suite
# still prints ALL TESTS PASSED with a quietly smaller total. Every exit path
# goes through this helper.
#
# COUNT EACH ARM SEPARATELY, NEVER THE SUM (#1165 skeptic F1): a pair of errors
# that cancel is green wherever python3 exists, which is every host anyone runs.
#   no-python arm : 1 readable + 1 Control A + 5 form shapes
#                   + 1 Control B1 + 2 Control B2                        = 10
#   python arms   : 1 Control E + 4 corruption + 2 survive-probe
#                   + 1 asymmetry + 2 escape table + 5 derived-completeness
#                   (#1249: 2 controls + the derived set + nothing missing
#                   + this file's literal) + 4 -W error valid
#                   + 3 -W error invalid + 2 r-string + 4 wrong-sed
#                   + 1 raw-sed                                          = 29
_th_count_guard() {
    local EXPECTED_ASSERTIONS=10
    # `=`, NOT `==`, AND THAT IS LOAD-BEARING — do not "normalise" it. This line
    # carries both `EXPECTED` and `ASSERTION`, so summary-honesty's `_count_axis`
    # reads it; written with `==` it satisfies that classifier's exact-guard test
    # ALL BY ITSELF and the suite would read `count=exact` whether or not the
    # real guard below still existed. Documented classifier hole; see
    # test-claude-md-backtick-substitution.sh for the measured mutant.
    [[ "$HAVE_PY" = yes ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 29 ))
    local TOTAL_ASSERTIONS=$(( PASS + FAIL ))
    assert_eq "assertion TOTAL matches the EXPECTED total for this host (python=$HAVE_PY)" "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"
    th_summary_and_exit
}

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b='<!-- BEGIN PYTHON-BACKREF-ESCAPE -->' -v e='<!-- END PYTHON-BACKREF-ESCAPE -->' '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | grep -E '^python3 ')

FORM_COUNT=$(printf '%s\n' "$FORMS" | grep -cE '^python3 ')
assert_eq "Control A: extracted exactly 5 documented forms" "$FORM_COUNT" "5"
if [[ "$FORM_COUNT" != "5" ]]; then
    th_abort "block malformed — refusing to draw conclusions from it"
fi

F_WRONG=$(printf   '%s\n' "$FORMS" | sed -n '1p')
F_SURVIVE=$(printf '%s\n' "$FORMS" | sed -n '2p')
F_RAW=$(printf     '%s\n' "$FORMS" | sed -n '3p')
F_SILENT=$(printf  '%s\n' "$FORMS" | sed -n '4p')
F_LOUD=$(printf    '%s\n' "$FORMS" | sed -n '5p')

# The needles are the LITERAL byte sequences, not their renderings: `\\1` here
# is backslash-backslash-one, which is how CLAUDE.md's source spells the
# backreference inside a shell single-quoted python -c argument.
assert_contains "form 1 is the NON-RAW literal carrying the backreference" "$F_WRONG"   'repr("s/'
assert_contains "form 2 is the SURVIVE probe"                             "$F_SURVIVE" '\8 \9 \d'
assert_contains "form 3 is the r-string remedy"                           "$F_RAW"     'repr(r"s/'
assert_contains "form 4 is the -W error VALID-escape form"                "$F_SILENT"  '-W error'
assert_contains "form 5 is the -W error INVALID-escape form"              "$F_LOUD"    'print("\d")'

echo
echo '=== Control B1: the expected byte, derived by the SHELL (no Python) ==='
# The shell's own octal escape supplies the number that Python's `\1` must
# equal. Deriving it here means the corruption arm below is not measured with
# the mechanism it is testing.
SHELL_OCTAL_BYTE=$(printf '\1' | od -An -tu1 | tr -d ' \n')
assert_eq "the SHELL renders its own octal escape \\1 as the single byte 1" \
          "$SHELL_OCTAL_BYTE" "1"
SOH=$(printf '\1')

echo
echo '=== Control B2: the fixture digits, derived by AWK (no Python, no sed) ==='
FIX="$WORK/rows.txt"
printf '%s\n' 'total (733) rows' 'none here' 'count (42) end' > "$FIX"
FIX_LINES=$(wc -l < "$FIX" | tr -d ' ')

# Bracket expressions, not `\(`: an awk ERE escape of a non-special character is
# UNDEFINED by POSIX, and this control must not itself depend on a dialect.
KNOWN_DIGITS=$(awk '{ if (match($0, /[(][0-9]+[)]/)) print substr($0, RSTART + 1, RLENGTH - 2) }' "$FIX")
KNOWN_N=$(printf '%s\n' "$KNOWN_DIGITS" | grep -c '^[0-9]' || true)
assert_eq "awk finds exactly 2 parenthesised digit runs in the fixture" "$KNOWN_N" "2"
assert_eq "…and they are 733 and 42"  "$(printf '%s\n' "$KNOWN_DIGITS" | tr '\n' ' ' | sed -E 's/ $//')" "733 42"
D1=$(printf '%s\n' "$KNOWN_DIGITS" | sed -n '1p')
D2=$(printf '%s\n' "$KNOWN_DIGITS" | sed -n '2p')

if [[ "$HAVE_PY" != "yes" ]]; then
    echo
    echo '  (every arm below needs python3 — skipped above with a reason)'
    _th_count_guard
fi

echo
echo "=== Control E: the interpreter this run measured ==="
echo "  python3 == $PYV"
if [[ "$PYV" =~ ^[0-9]+\.[0-9]+\.[0-9] ]]; then
    printf '  PASS: %s\n' "the interpreter reports a version SHAPE ($PYV), so the scope paragraph is grounded"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — got [%s]\n' "the interpreter reports a version SHAPE" "$PYV" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Expected repr outputs, held in QUOTED heredocs so no shell layer can touch a
# backslash on the way in. These are the bytes `repr()` prints, surrounding
# quotes included.
EXP_WRONG=$(cat <<'EOF'
's/(\\([0-9]*\\))/\x01/'
EOF
)
EXP_SURVIVE=$(cat <<'EOF'
'\\8 \\9 \\d'
EOF
)
EXP_RAW=$(cat <<'EOF'
's/(\\([0-9]*\\))/\\1/'
EOF
)
EXP_ASYM=$(cat <<'EOF'
'\x01 \\8 \\9'
EOF
)

echo
echo '=== THE CORRUPTION: the punctuation survives, the RESULT does not ==='
err_w="$WORK/e.wrong"
out_w=$(eval "$F_WRONG" 2>"$err_w"); rc_w=$?
assert_eq           "Control C: the non-raw form EXITS 0 (it is SILENT, not broken)" "$rc_w" "0"
assert_eq           "the repr shows the backreference replaced by a control byte"    "$out_w" "$EXP_WRONG"
assert_contains     "…the escaped PUNCTUATION survived verbatim"                     "$out_w" '\\('
assert_not_contains "…while the backreference itself is GONE"                        "$out_w" '\\1'

echo
echo '=== …and the two probes a reader reaches for come back INTACT ==='
err_s="$WORK/e.survive"
out_s=$(eval "$F_SURVIVE" 2>"$err_s"); rc_s=$?
assert_eq "the SURVIVE probe exits 0"                                  "$rc_s"  "0"
assert_eq "\\8, \\9 and \\d are all returned with their backslashes"    "$out_s" "$EXP_SURVIVE"

echo
echo '=== (i) THE ASYMMETRY, IN ONE MEASUREMENT ==='
# Forms 1 and 2 are separate calls, so a reader could attribute the difference
# to the probe. One literal, one call, one interpreter: `\1` is destroyed and
# `\8`/`\9` are not. This is what makes generalising from a high-numbered
# backreference a trap rather than a curiosity.
cat > "$WORK/asym.py" <<'EOF'
print(repr("\1 \8 \9"))
EOF
out_a=$(python3 "$WORK/asym.py" 2>/dev/null)
assert_eq "one literal: \\1 became \\x01 while \\8 and \\9 kept their backslashes" \
          "$out_a" "$EXP_ASYM"

echo
echo '=== (i) THE WHOLE DOCUMENTED TABLE, DRIVEN AS DATA ==='
# CLAUDE.md's claim is a SET claim, so assert the set. The backslash is built
# with chr(92) rather than written, which keeps this arm free of any literal
# escape sequence — the file is otherwise a fixture full of the constructs the
# source-text lints in this directory look for.
CONSUMED_LITERAL="01234567abfnrtv"
cat > "$WORK/escset.py" <<'EOF'
import warnings
warnings.simplefilter("ignore")
BS = chr(92)
CONSUMED = "01234567abfnrtv"
SURVIVE = "89dwsDWSBAZ()+."
bad = []
for ch in CONSUMED:
    if len(eval('"' + BS + ch + '"')) != 1:
        bad.append(ch)
print("CONSUMED_NOT_1:" + "".join(bad))
bad = []
for ch in SURVIVE:
    v = eval('"' + BS + ch + '"')
    if len(v) != 2 or v[0] != BS or v[1] != ch:
        bad.append(ch)
print("SURVIVE_NOT_BS:" + "".join(bad))
EOF
tbl=$(python3 "$WORK/escset.py" 2>/dev/null)
assert_eq "every documented CONSUMED escape collapses to ONE byte" \
          "$(printf '%s\n' "$tbl" | sed -n 's/^CONSUMED_NOT_1://p')" ""
# Control D: backslash+char, not merely "length 2" — a probe that mangled both
# halves equally could satisfy a length test and not this one.
assert_eq "Control D: every documented SURVIVE escape is BACKSLASH + the char" \
          "$(printf '%s\n' "$tbl" | sed -n 's/^SURVIVE_NOT_BS://p')" ""

echo
echo '=== (i-b) IS THE DOCUMENTED SET COMPLETE? — derived from the INTERPRETER ==='
# your-org/nexus-code#1249. The arm above is careful and still could not have
# caught this: it drives the DOCUMENTED table as data, so it asserts every
# member of that table and can never notice a NON-member. `\r` was consumed by
# Python and absent from BOTH CLAUDE.md and this file's CONSUMED literal, and
# every assertion above was green throughout. A guard cannot see an omission
# from its own reference set.
#
# So this arm takes its reference from somewhere the documentation cannot
# reach: it asks the INTERPRETER which escapes collapse, over a fixed
# alphabet, and then requires the prose to name every one of them. The
# direction is what matters — above asserts documented ⊆ true, here asserts
# true ⊆ documented, and only the pair is a set equality.
if [[ "$HAVE_PY" = yes ]]; then
cat > "$WORK/derive.py" <<'EOF'
import re, string, sys, warnings
warnings.simplefilter("ignore")
BS = chr(92)
derived = []
for ch in string.ascii_letters + string.digits:
    try:
        v = eval('"' + BS + ch + '"')
    except SyntaxError:
        continue                      # \x \u \U \N are LOUD; tracked as prose
    if len(v) == 1:
        derived.append(ch)
derived = "".join(sorted(derived))
print("DERIVED:" + derived)

doc = open(sys.argv[1], encoding="utf-8").read().splitlines()
start = next((i for i, ln in enumerate(doc)
              if "The last two lines are the entry." in ln), None)
win = ""
if start is not None:
    acc = []
    for ln in doc[start:start + 8]:
        acc.append(ln)
        if "are CONSUMED" in ln:
            break
    win = "\n".join(acc)
print("WINDOW_OK:" + ("yes" if "are CONSUMED" in win else "no"))

head = win.split("are CONSUMED")[0]
named = set()
# a documented RANGE, e.g. the octal one written as an en-dash pair
for a, b in re.findall("`" + BS + BS + "(.)`[–—-]`" + BS + BS + "(.)`", head):
    if a.isdigit() and b.isdigit():
        named.update(str(d) for d in range(int(a), int(b) + 1))
named.update(re.findall("`" + BS + BS + "(.)`", head))
print("DOC_NAMED:" + "".join(sorted(named)))
print("DOC_MISSING:" + "".join(sorted(set(derived) - named)))
EOF
der_out=$(python3 "$WORK/derive.py" "$CLAUDE_MD" 2>/dev/null)
_der()  { printf '%s\n' "$der_out" | sed -n "s/^$1://p"; }

# POSITIVE CONTROL FIRST, and it ABORTS rather than passing: an extraction
# that found nothing satisfies "no member is missing" by having no members —
# #618's own shape, and the exact failure this arm exists to prevent.
win_ok=$(_der WINDOW_OK)
assert_eq "Control F: the CONSUMED sentence was located in CLAUDE.md" "$win_ok" "yes"
[[ "$win_ok" = yes ]] || th_abort "could not locate the CONSUMED sentence; refusing to conclude the set is complete"
doc_named=$(_der DOC_NAMED)
assert_eq "Control F2: the extraction named a plausible number of escapes (>=8)" \
          "$( (( ${#doc_named} >= 8 )) && echo yes || echo no )" "yes"

# THE LANGUAGE FACT, derived rather than transcribed.
assert_eq "the interpreter's own consumed set over [A-Za-z0-9]" \
          "$(_der DERIVED)" "01234567abfnrtv"
# THE CLASS ASSERTION: nothing the interpreter consumes may be missing here.
assert_eq "CLAUDE.md names EVERY escape the interpreter consumes (none missing)" \
          "$(_der DOC_MISSING)" ""
# …and this file's own literal is held to the same set, so the two tables
# cannot drift apart in silence the way they already did once.
assert_eq "this suite's CONSUMED literal IS the derived set" \
          "$(printf '%s' "$CONSUMED_LITERAL" | fold -w1 | LC_ALL=C sort | tr -d '\n')" \
          "$(_der DERIVED)"
fi

echo
echo '=== (ii) THE TOOLING SEES THE WRONG HALF ==='
err_v="$WORK/e.valid"
out_v=$(eval "$F_SILENT" 2>"$err_v"); rc_v=$?
assert_eq "Control C: under -W error the VALID escape exits 0"          "$rc_v" "0"
assert_eq "…with stderr EMPTY — a valid escape warns NOWHERE"           "$(wc -c <"$err_v" | tr -d ' ')" "0"
assert_eq "…and its output is exactly ONE byte"                         "$(printf '%s' "$out_v" | wc -c | tr -d ' ')" "1"
assert_eq "…that byte is the one Control B1 derived without Python"     \
          "$(printf '%s' "$out_v" | od -An -tu1 | tr -d ' \n')" "$SHELL_OCTAL_BYTE"

err_i="$WORK/e.invalid"
out_i=$(eval "$F_LOUD" 2>"$err_i"); rc_i=$?
# VERSION-SCOPED, and the FAIL text says so: the warning's CATEGORY moved in
# 3.12. The measurement, not a universal claim.
if (( rc_i != 0 )); then
    printf '  PASS: %s\n' "under -W error the INVALID escape is LOUD: rc $rc_i on python3 $PYV"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — got rc 0 on python3 %s. The warning CATEGORY for an invalid escape changed in 3.12; if this interpreter no longer errors, widen the PYTHON-BACKREF-ESCAPE scope sentence rather than relaxing this file.\n' \
        "under -W error the INVALID escape is LOUD" "$PYV" >&2
    FAIL=$(( FAIL + 1 ))
fi
assert_eq       "…and it wrote a diagnostic to stderr"             "$( [[ -s "$err_i" ]] && echo yes || echo no )" "yes"
assert_contains "…naming the escape it can see (python3 $PYV)"     "$(cat "$err_i")" "invalid escape"

echo
echo '=== THE REMEDY: r"" keeps every backslash a backslash ==='
err_r="$WORK/e.raw"
out_r=$(eval "$F_RAW" 2>"$err_r"); rc_r=$?
assert_eq "the r-string form exits 0"                                  "$rc_r"  "0"
assert_eq "…and the backreference reaches the regex intact"            "$out_r" "$EXP_RAW"

echo
echo '=== (iii) THE CORRUPTED REGEX STILL WORKS AS A MATCHER ==='
# This is why nothing downstream ever disagrees: the capture group is intact,
# every line is emitted, and only the REPLACEMENT is a control byte.
cat > "$WORK/exprs.py" <<'EOF'
import io, sys
w = "s/(\([0-9]*\))/\1/"
r = r"s/(\([0-9]*\))/\1/"
open(sys.argv[1], "w").write(w)
open(sys.argv[2], "w").write(r)
EOF
python3 "$WORK/exprs.py" "$WORK/expr.wrong" "$WORK/expr.raw" || th_abort "could not write the sed expressions"
EXPR_W=$(cat "$WORK/expr.wrong")
EXPR_R=$(cat "$WORK/expr.raw")

sed_out_w="$WORK/sed.wrong.out"
sed "$EXPR_W" "$FIX" > "$sed_out_w" 2>"$WORK/e.sedw"; rc_sw=$?
assert_eq           "Control C: sed fed the CORRUPTED expression exits 0"        "$rc_sw" "0"
assert_eq           "…and emits one line per input line — no stage is empty"     "$(wc -l < "$sed_out_w" | tr -d ' ')" "$FIX_LINES"
assert_not_contains "…the match FIRED: the parenthesised run is gone"            "$(cat "$sed_out_w")" "($D1)"
assert_eq           "…but the replacement is the control byte, not the digits"    \
                    "$(sed -n '1p' "$sed_out_w")" "total ${SOH} rows"

sed_out_r="$WORK/sed.raw.out"
sed "$EXPR_R" "$FIX" > "$sed_out_r" 2>"$WORK/e.sedr"
# Expected built from AWK's digits (Control B2), not from anything Python or
# sed produced.
EXPECTED_SED=$(printf '%s\n' "total ${D1} rows" 'none here' "count ${D2} end")
assert_eq "the r-string expression emits the CAPTURED DIGITS awk independently found" \
          "$(cat "$sed_out_r")" "$EXPECTED_SED"

_th_count_guard
