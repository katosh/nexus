#!/usr/bin/env bash
# test-claude-md-dash-pattern-option.sh — execute CLAUDE.md's DASH-PATTERN-OPTION block.
#
# Run: bash monitor/watcher/test-claude-md-dash-pattern-option.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS. your-org/nexus-code#1186. Its host entry — the
# GREP-BRE-DIALECT bullet, pinned by test-claude-md-grep-bre-dialect.sh —
# prescribes `grep -cF '+++' DIFF` as the form that "says what it means", and
# that form is right. The IDENTICAL shape aimed at the OTHER unified-diff
# marker never runs: `grep -vF '---' FIX` is parsed as an OPTION, because `+`
# introduces no option and `-` does. So the idiom the host entry teaches is
# correct on one half of a symmetric-looking pair and inert on the other, and
# TESTING THE SAFE HALF AND GENERALISING is exactly how it arrives. That is the
# same asymmetry the host entry names in its own closing paragraph ("`-E '^\+'`
# on the SELECTING stage is correct") wearing different clothes — which is why
# this suite pins BOTH markers against ONE fixture rather than only the broken
# one. It is the ENTRY's link to its host, not a decoration.
#
# It is OPTION PARSING, not a dialect. `-F`, `-E`, `-P` change how the PATTERN
# is interpreted; none of them change whether the argument reaches the pattern
# slot at all. That distinction is what makes `-e` and `--` the remedies rather
# than a different pattern flag, and it is what Control E below pins.
#
# WHAT IS ACTUALLY PINNED, and the second item is the entry:
#
#   MODE 1 — the leading-dash string is NOT a valid option. grep exits 2,
#            prints NOTHING, and writes a diagnostic. LOUD — but only if
#            anyone is looking, and the documented shape
#            `n=$(… 2>/dev/null | wc -l)` is looking at neither the rc nor
#            stderr. Pinned: rc, zero output, NON-ZERO stderr bytes, and the
#            silent `0` the pipeline yields.
#   MODE 2 — the leading-dash string IS a valid option. STDERR IS EXACTLY 0
#            BYTES. This is the dangerous one and the reason `--` is not
#            optional: `-i` is consumed as the ignore-case FLAG, the FILE
#            argument slides into the PATTERN slot, and grep reads STDIN.
#            Pinned as MECHANISM, not just symptom: the same call fed a stdin
#            that CONTAINS the fixture's path counts those lines, which is only
#            possible if the path became the pattern.
#
#   The STDERR BYTE COUNT is asserted on BOTH modes — non-zero for mode 1,
#   EXACTLY zero for mode 2 — because that difference IS the entry. A suite
#   that pinned only the output counts would report both modes as "0 lines"
#   and miss the whole point.
#
#   BOTH REMEDIES — `-e` and `--` — measured working, and measured EQUAL to a
#   positive control derived with awk, so the expected value never comes from
#   the mechanism under test.
#
# SCOPE, STATED SO THE GREEN IS NOT OVER-READ. This is the axis the boundary
# must be drawn on, and drawing it on the wrong axis would be honest, tested
# and false:
#
#   * The subject is the POSIX OPTION PARSER, which is portable. It is NOT a
#     grep dialect and NOT an implementation quirk.
#   * Every assertion here is made against a grep this suite resolves
#     EXPLICITLY (`command -v grep`, falling back to `/bin/grep`) and
#     substitutes into the extracted form in place of the bare `grep` token, in
#     the manner of test-claude-md-grep-bre-dialect.sh. Measured here: GNU grep
#     3.1 at /bin/grep.
#   * NOTHING is asserted about what a BARE `grep` resolves to. On this host
#     `command -v ugrep` finds nothing, YET an agent's bare `grep` is a shell
#     FUNCTION installed by Claude Code's shell snapshot that runs ugrep
#     (7.8.4 here) embedded in the `claude` executable — so "ugrep is not
#     installed" and "the agent's grep is ugrep" are both true, of different
#     things. Which grep a bare call reaches is a property of the HARNESS
#     BUILD, not of this repo, and would make this suite red for another
#     operator for a reason that has nothing to do with #1186. Recorded here as
#     a measured HOST FACT with its version; asserted nowhere.
#   * NOT pinned: any second implementation's message text or exit code, and
#     ugrep's option surface.
#
# EVERY grep INVOCATION IN THIS SUITE HAS A BOUNDED STDIN — a real hazard of
# this specific subject matter, not boilerplate. Mode 2's whole mechanism is
# that grep starts reading stdin; with stdin INHERITED it BLOCKS, and #1186 was
# found by it costing an agent's Bash tool call its full 120s timeout. So every
# arm redirects stdin from a file or /dev/null, and the ONE arm that measures
# the block deliberately does so through a fifo THIS suite owns, under
# `timeout 2`. No arm of this file can hang a CI runner. (`/dev/tty` is
# deliberately not used: it does not exist here.)
#
# CONTROLS:
#   A — the extracted form count is PINNED at 4, and a malformed extraction
#       ABORTS rather than passing vacuously by having nothing to assert
#       (#618's own shape). A2 additionally pins that the two WRONG forms carry
#       NO option terminator — otherwise a block edit that quietly added `--`
#       to them would leave every arm below green while the defect vanished.
#   B — POSITIVE CONTROL, derived with awk and `index()`, so neither the
#       expected value nor the line counting comes from grep. The fixture is
#       shaped so the `---` answer (4) and the `+++` answer (5) are DIFFERENT
#       numbers: a fixture where the two halves of the asymmetry agree would
#       prove nothing.
#   C — the SILENT-ZERO shape. `2>/dev/null | wc -l` yields `0`, and that `0`
#       is pinned as DIFFERENT from the honest count, so the assertion cannot
#       be satisfied by a fixture that really has nothing to keep.
#   D — the BLOCKING arm is not measuring the fifo. The CORRECT form, run
#       against the SAME fifo stdin, returns instantly with the right answer.
#       Without this, `rc=124` would be evidence of a slow harness.
#   E — OPTION PARSING, not dialect: `-F` (fixed-string) and `-E` (ERE) both
#       fail identically on `'---'`, so no pattern flag rescues it — only an
#       option terminator does.
#
# NOT COVERED: whether the block ARM ORDER in CLAUDE.md is stable, and the
# stdin-INHERITED case as an agent actually experiences it (unbounded by
# construction; the fifo arm is a bounded stand-in for it and is labelled as
# one, not as a reproduction).

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
th_claude_md_block_coverage DASH-PATTERN-OPTION   # the entry's UNCHECKED share, in this suite's own output (#1239)

# The grep this suite MEASURES WITH and MEASURES. Resolved explicitly so no
# assertion here depends on what a bare `grep` reaches in any given shell.
REAL_GREP=$(command -v grep 2>/dev/null || true)
[[ -x "$REAL_GREP" ]] || REAL_GREP=/bin/grep
GREPV=$("$REAL_GREP" --version 2>&1 | sed -n 1p)

TIMEOUT_BIN=$(command -v timeout 2>/dev/null || true)
MKFIFO_BIN=$(command -v mkfifo 2>/dev/null || true)

WORK=$(mktemp -d) || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# ---- fixture -------------------------------------------------------------
# A unified-diff shape carrying TWO `---` lines and ONE `+++` line, so the
# honest `---` answer (4 kept) and the honest `+++` answer (5 kept) are
# different numbers. Control B derives both without grep.
FIX="$WORK/fix.diff"
printf '%s\n' '--- a/f' '+++ b/f' '--- a/g' '-old line' '+new line' ' ctx' > "$FIX"

# A stdin fixture whose lines NAME the fixture's own path. Mode 2's mechanism
# claim is that $FIX slides into the PATTERN slot; if it does, grep counts
# these.
STDIN_NAMING="$WORK/names-the-path.txt"
printf '%s\n' "a line naming $FIX here" "unrelated" "$FIX again" > "$STDIN_NAMING"

# How many of those lines a grep-free instrument says contain the path.
naming_hits=$(awk -v p="$FIX" 'index($0, p) > 0 { n++ } END { print n + 0 }' "$STDIN_NAMING")

# Blocking arm cost, in assertions: 5 when measurable, 0 when SKIPped. Kept as
# a variable so the count guard stays EXACT on a host without coreutils
# `timeout`/`mkfifo` instead of going red for an unrelated reason.
BLOCK_ARM_ASSERTIONS=0

# ---- assertion-count guard (your-org/nexus-code#946 F6) ------------------
# A missing assert_* helper (a typo -> rc 127) is counted by NOTHING: the suite
# would still print ALL TESTS PASSED with a quietly smaller total. Every exit
# path routes through this helper.
_th_count_guard() {
    # `=` is ASSIGNMENT, not comparison — do not "normalise" it to `==`; the
    # summary-honesty classifier reads this line's PHYSICAL text.
    local EXPECTED_ASSERTIONS=$(( 37 + BLOCK_ARM_ASSERTIONS ))
    local TOTAL_ASSERTIONS=$(( PASS + FAIL ))
    assert_eq "assertion TOTAL matches the EXPECTED total" "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"
    th_summary_and_exit
}

echo "=== Host: $GREPV (resolved explicitly at $REAL_GREP) ==="

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b='<!-- BEGIN DASH-PATTERN-OPTION -->' -v e='<!-- END DASH-PATTERN-OPTION -->' '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | awk '/^grep /')

FORM_COUNT=$(printf '%s\n' "$FORMS" | awk '/^grep /' | awk 'END { print NR + 0 }')
assert_eq "Control A: extracted exactly 4 documented forms" "$FORM_COUNT" "4"
if [[ "$FORM_COUNT" != "4" ]]; then
    th_abort "block malformed — refusing to draw conclusions from it"
fi

F_MODE1=$(printf '%s\n' "$FORMS" | sed -n '1p')
F_MODE2=$(printf '%s\n' "$FORMS" | sed -n '2p')
F_DASH_E=$(printf '%s\n' "$FORMS" | sed -n '3p')
F_DASHDASH=$(printf '%s\n' "$FORMS" | sed -n '4p')

assert_contains "form 1 is MODE 1 — the excluding form on '---'" "$F_MODE1"    "-vF '---'"
assert_contains "form 2 is MODE 2 — the counting form on '-i'"   "$F_MODE2"    "-cF '-i'"
assert_contains "form 3 declares the pattern with -e"            "$F_DASH_E"   "-e '---'"
assert_contains "form 4 ends option parsing with --"             "$F_DASHDASH" "-- '---'"

# Control A2. If a block edit slipped an option terminator into the WRONG
# forms, they would stop being wrong and every arm below would still be green.
assert_not_contains "Control A2: MODE 1 carries no -e"  "$F_MODE1" " -e "
assert_not_contains "Control A2: MODE 1 carries no --"  "$F_MODE1" " -- "
assert_not_contains "Control A2: MODE 2 carries no -e"  "$F_MODE2" " -e "
assert_not_contains "Control A2: MODE 2 carries no --"  "$F_MODE2" " -- "

# ---- runners -------------------------------------------------------------
# Every one redirects stdin. See the header: an unbounded stdin is how #1186
# was found, and it is not reproducible safely inside a test.
_sub() {  # _sub <form> → form with FIX resolved and `grep` pinned to $REAL_GREP
    local _f="${1//FIX/$FIX}"
    printf '%s' "${_f/#grep /$REAL_GREP }"
}

_run() {  # _run <form> <stdin-path> → "<rc>|<stdout lines>|<stderr bytes>|<stdout line1>"
    local _cmd _rc _out="$WORK/out.run" _e="$WORK/err.run"
    _cmd=$(_sub "$1")
    eval "$_cmd" < "$2" > "$_out" 2> "$_e"; _rc=$?
    # awk counts the lines, not wc and never grep: the instrument must not be
    # the mechanism under test.
    printf '%s|%s|%s|%s\n' "$_rc" \
        "$(awk 'END { print NR + 0 }' "$_out")" \
        "$(wc -c < "$_e" | tr -d ' ')" \
        "$(sed -n 1p "$_out")"
}

_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

echo
echo '=== Control B: a POSITIVE CONTROL derived WITHOUT grep ==='
# awk `index()`, not a regex and not grep: fixed-string containment, which is
# what -F means, expressed by an instrument that shares no code with it.
kept_dashes=$(awk 'index($0, "---") == 0 { n++ } END { print n + 0 }' "$FIX")
hit_dashes=$(awk  'index($0, "---") >  0 { n++ } END { print n + 0 }' "$FIX")
kept_pluses=$(awk 'index($0, "+++") == 0 { n++ } END { print n + 0 }' "$FIX")
assert_eq "the fixture holds exactly 2 lines containing ---"     "$hit_dashes"  "2"
assert_eq "…so an honest exclusion of --- KEEPS 4 of 6"          "$kept_dashes" "4"
assert_eq "…and an honest exclusion of +++ KEEPS 5 of 6"         "$kept_pluses" "5"
if [[ "$kept_dashes" != "$kept_pluses" ]]; then
    printf '  PASS: %s\n' "Control B: the two honest answers DIFFER (4 vs 5) — the fixture discriminates"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — both %s; a fixture where the asymmetry agrees proves nothing\n' \
        "Control B: the two honest answers must DIFFER" "$kept_dashes" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo '=== MODE 1: the pattern is NOT a valid option — LOUD, if anyone looks ==='
r=$(_run "$F_MODE1" /dev/null)
m1_rc=$(_field "$r" 1); m1_lines=$(_field "$r" 2); m1_err=$(_field "$r" 3)
assert_eq "MODE 1 exits 2 — the pattern was parsed as an unrecognised OPTION" "$m1_rc"    "2"
assert_eq "…and printed NOTHING, so it filtered nothing"                      "$m1_lines" "0"
if (( m1_err > 0 )); then
    printf '  PASS: %s\n' "…and wrote a diagnostic to stderr ($m1_err bytes) — this is the LOUD mode"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — got 0 bytes under %s. If this grep stopped rejecting a leading-dash pattern, UPDATE the DASH-PATTERN-OPTION block; do not relax this file.\n' \
        "MODE 1 must write a diagnostic to stderr" "$GREPV" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo '=== Control C: the SILENT-ZERO shape that hides MODE 1 ==='
# The documented shape, verbatim from the entry's prose: `n=$(… 2>/dev/null |
# wc -l)`. It looks at neither the rc nor stderr, which is the whole hazard.
silent_n=$(eval "$(_sub "$F_MODE1")" < /dev/null 2>/dev/null | wc -l | tr -d ' ')
assert_eq "Control C: under 2>/dev/null | wc -l the answer is a bare 0" "$silent_n" "0"
if [[ "$silent_n" != "$kept_dashes" ]]; then
    printf '  PASS: %s\n' "…and that 0 is NOT the honest count ($kept_dashes) — a zero shaped like a true negative"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — silent %s equals honest %s; the fixture cannot distinguish them\n' \
        "the silent zero must differ from the honest count" "$silent_n" "$kept_dashes" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo
echo '=== MODE 2: the pattern IS a valid option — NO stderr at all ==='
r=$(_run "$F_MODE2" /dev/null)
m2_rc=$(_field "$r" 1); m2_err=$(_field "$r" 3); m2_first=$(_field "$r" 4)
assert_eq "MODE 2 exits 1 — a clean NO MATCH, not an error"       "$m2_rc"    "1"
assert_eq "…and prints the count 0"                                "$m2_first" "0"
assert_eq "…and stderr is EXACTLY 0 bytes — the entire signal is gone" "$m2_err" "0"

echo
echo '--- MODE 2 MECHANISM, not just its symptom ---'
# `-i` was eaten as the ignore-case FLAG, so the FILE argument slid into the
# PATTERN slot and grep read STDIN. Feed it a stdin whose lines NAME the
# fixture's path: a count > 0 is only possible if the path became the pattern.
assert_eq "the stdin fixture holds 2 lines naming the fixture path (awk)" "$naming_hits" "2"
r=$(_run "$F_MODE2" "$STDIN_NAMING")
mech_rc=$(_field "$r" 1); mech_first=$(_field "$r" 4)
assert_eq "MODE 2 fed that stdin exits 0 — it MATCHED"                  "$mech_rc"    "0"
assert_eq "…counting the lines that name the FILE argument: it became the PATTERN" \
          "$mech_first" "$naming_hits"

echo
echo '=== The remedies: both documented forms, against the awk control ==='
r=$(_run "$F_DASH_E" /dev/null)
e_rc=$(_field "$r" 1); e_lines=$(_field "$r" 2)
assert_eq "-e form exits 0"                                  "$e_rc"    "0"
assert_eq "-e form keeps the honest count from Control B"     "$e_lines" "$kept_dashes"

r=$(_run "$F_DASHDASH" /dev/null)
d_rc=$(_field "$r" 1); d_lines=$(_field "$r" 2)
assert_eq "-- form exits 0"                                  "$d_rc"    "0"
assert_eq "-- form keeps the honest count from Control B"     "$d_lines" "$kept_dashes"
assert_eq "the two remedies agree with each other"           "$e_lines" "$d_lines"

echo
echo '=== THE ASYMMETRY THAT TRAINS THE EYE WRONG: +++ is safe, --- is not ==='
# Derived from MODE 1 by textual substitution, so this IS the identical shape
# aimed at the other unified-diff marker — the host entry's prescribed
# `grep -cF '+++'` idiom, on the same fixture.
F_PLUS="${F_MODE1//---/+++}"
assert_contains "the +++ variant is MODE 1's shape with the marker swapped" "$F_PLUS" "-vF '+++'"
r=$(_run "$F_PLUS" /dev/null)
p_rc=$(_field "$r" 1); p_lines=$(_field "$r" 2); p_err=$(_field "$r" 3)
assert_eq "the +++ form exits 0 — + introduces no option"        "$p_rc"    "0"
assert_eq "…and keeps the honest +++ count (5), so it really ran" "$p_lines" "$kept_pluses"
assert_eq "…with 0 bytes of stderr, because nothing was wrong"    "$p_err"   "0"
asym=$([[ "$m1_rc" != "$p_rc" ]] && echo differ || echo same)
assert_eq "SAME SHAPE, one marker apart: rc 2 vs rc 0 — the halves DIFFER" "$asym" "differ"

echo
echo '=== Control E: OPTION PARSING, not a pattern DIALECT ==='
# If this were a dialect problem, a different pattern flag would fix it. `-E`
# on the same leading-dash string fails identically to `-F`; only an option
# terminator helps. This is what pins the boundary on the right axis.
F_ERE="${F_MODE1/-vF/-vE}"
r=$(_run "$F_ERE" /dev/null)
ere_rc=$(_field "$r" 1); ere_lines=$(_field "$r" 2)
assert_eq "-E fails IDENTICALLY to -F on the same leading-dash string" "$ere_rc"    "$m1_rc"
assert_eq "…printing nothing, so no pattern flag rescues it"           "$ere_lines" "0"

echo
echo '=== The BLOCKING consequence, BOUNDED (never reproduced unbounded) ==='
if [[ -n "$TIMEOUT_BIN" && -n "$MKFIFO_BIN" ]]; then
    FIFO="$WORK/blocker.fifo"
    if mkfifo "$FIFO" 2>/dev/null; then
        BLOCK_ARM_ASSERTIONS=5
        _run_fifo() {  # <form> → "<rc>|<lines>|<errbytes>"
            local _cmd _rc _out="$WORK/out.fifo" _e="$WORK/err.fifo"
            _cmd=$(_sub "$1")
            # Opening a fifo READ-WRITE keeps a writer attached without a
            # background job, so the read blocks and nothing is ever written.
            exec 9<>"$FIFO"
            eval "timeout 2 $_cmd" <&9 > "$_out" 2> "$_e"; _rc=$?
            exec 9>&-
            printf '%s|%s|%s\n' "$_rc" "$(awk 'END { print NR + 0 }' "$_out")" \
                                "$(wc -c < "$_e" | tr -d ' ')"
        }
        r=$(_run_fifo "$F_MODE2")
        b_rc=$(_field "$r" 1); b_lines=$(_field "$r" 2); b_err=$(_field "$r" 3)
        assert_eq "MODE 2 with a live-but-silent stdin is KILLED BY timeout (rc 124)" "$b_rc" "124"
        assert_eq "…having printed nothing"                                          "$b_lines" "0"
        assert_eq "…and with 0 bytes of stderr: it is waiting, not complaining"       "$b_err"   "0"

        # Control D — the block is the option slide, not the fifo.
        r=$(_run_fifo "$F_DASHDASH")
        c_rc=$(_field "$r" 1); c_lines=$(_field "$r" 2)
        assert_eq "Control D: the -- form on the SAME fifo stdin exits 0, not 124"  "$c_rc"    "0"
        assert_eq "…with the honest count — it read the FILE and never touched stdin" "$c_lines" "$kept_dashes"
    else
        th_skip "the bounded blocking arm" "mkfifo failed inside $WORK — rc 124 vs 0 UNMEASURED by this run"
    fi
else
    th_skip "the bounded blocking arm" \
            "coreutils timeout=${TIMEOUT_BIN:-<absent>} mkfifo=${MKFIFO_BIN:-<absent>}; an unbounded reproduction would hang the runner, so this property is UNMEASURED here"
fi

_th_count_guard
