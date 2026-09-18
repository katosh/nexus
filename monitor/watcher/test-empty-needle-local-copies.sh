#!/usr/bin/env bash
# EVERY LOCALLY-DEFINED `assert_contains` MUST REFUSE AN EMPTY NEEDLE.
# (your-org/nexus-code#1092, the half `#1038` structurally could not reach.)
#
# ── WHAT `#1038` FIXED, AND WHY IT WAS HALF ─────────────────────────────
#
# `grep -qF ""` matches every line of any haystack, and `*""*` matches any
# string, so `assert_contains "label" "$out" "$expected"` with an EMPTY
# `$expected` passed VACUOUSLY — certifying a value it never saw. `#1038`
# guarded the SHARED helper in `_test_helpers.sh`. But most suites do not
# source it: they carry their OWN copy of the function, and a fix to the
# shared definer cannot reach a single one of them.
#
# Measured at `d8534d3` (the `#1038` merge), commands beside the numbers so a
# reader can re-run them:
#
#     git grep -lE '\bassert_contains\b' d8534d3 -- '*.sh' | wc -l   -> 204 files
#     git grep -nE '\bassert_contains\b' d8534d3 -- '*.sh' | wc -l   -> 3733 lines
#
#     local definers (their own copy)      87  ->  1867 lines
#     sourcers of _test_helpers.sh        115  ->  1859 lines
#     neither (cc-harness lint)             1  ->     1 line
#     _test_helpers.sh (the shared definer) 1  ->     6 lines
#                                         ---      ----
#                                         204      3733   (= the total; it reconciles)
#
# and all 87 local copies were measured — by EXECUTION, not by reading — to
# return their PASS arm on an empty needle before this suite landed.
#
# ── WHY THIS GUARD IS BEHAVIOURAL, NOT TEXTUAL ──────────────────────────
#
# A lint keyed on the literal token `grep -qF` would have silently missed FIVE
# of the 87 (`#1092`'s own correction): those reach grep through `$REAL_GREP`,
# the `#618` silent-zero remedy, so the vacuity sat INSIDE the suites written
# to guard a related silent-zero class. Keying on a spelling is keying on the
# axis your SEARCH varies on rather than the axis the MECHANISM varies on.
#
# So this guard EXTRACTS each definition and RUNS it. Three spellings exist
# today (72 `grep -qF`, 10 `[[ == *…* ]]`, 5 `$REAL_GREP`); a fourth written
# tomorrow — `case`, `awk`, `expr`, a python one-liner — is covered with no
# edit here, because nothing in the probe knows what a spelling is.
#
# ── WHY THIS CLOSES A CLASS AND NOT A LIST ──────────────────────────────
#
# The population is DERIVED, never listed: any file that defines its own
# `assert_contains` is in it, tracked or not (untracked included on purpose —
# a suite written today and not yet committed is exactly the one that would
# otherwise be added unguarded, and it is also how `#1054`'s UNVERIFIED green
# is avoided). There is no manifest to regenerate and no ratchet to raise. A
# new local copy joins by existing.
#
# "Tracked AND untracked" is not the same as ALL, and the gap is stated rather
# than left to read as completeness: the untracked half comes from `git ls-files
# --others --exclude-standard`, so a GITIGNORED file is outside the population.
# That is the right call — CI would never run it — but it is a boundary, not an
# absence.
#
# THE VERDICT IS DEFAULT-DENY. A member whose definition cannot be extracted,
# or whose arms cannot be told apart, is a FAIL — never a skip. "I could not
# look" and "I looked and it was fine" are the two answers this repo's
# dominant defect class depends on being confused, so they are kept apart.
#
# ── WHAT A GREEN HERE DOES NOT CERTIFY ──────────────────────────────────
#
#  * Only the names `assert_contains` / `assert_not_contains` are in scope, and
#    the residual is BIGGER than an earlier draft of this comment claimed. That
#    draft said "`assert_matches` (1 definition) is the only other
#    containment-shaped name" — wrong, and wrong by the very axis error this
#    header uses to justify probing rather than pattern-matching: it classified
#    by NAME while the vacuity lives in the BODY (skeptic F4).
#
#    Re-derived by EXECUTING every other local `assert_*` definition at
#    `50fcf36`: 375 total, 154 of them `assert_contains`/`assert_not_contains`,
#    leaving 221 (file, name) pairs — which reconciles. Probing all 221 with an
#    empty third argument and then a present one gives 181 `F/F`, 30 `P/P`,
#    9 `U/U`, 1 `F/P`. Most of the 30 are NEGATIVE assertions for which passing
#    on an empty needle is correct. Reading each body, THREE are containment
#    assertions vacuous on an empty needle:
#
#      test-tmux-window-resolver.sh   assert_matches  [[ "$got" =~ $re ]]        6 calls
#      test-proc-exists-authorized.sh assert_out      [[ "$OUT" == *"$2"* ]]    23 calls
#      test-bash-footgun-guard.sh     assert_ctx      [[ … == *"$2"* ]]        114 calls
#
#    None is exposed today — all 143 call sites pass a string literal — which is
#    the same standing as `slow-band-drift.sh` below. They are OUT OF SCOPE here
#    because no shared NAME keys them, so this guard's population cannot reach
#    them; enumerating containment assertions by BODY is a different mechanism
#    and a separate change. Tracked at `your-org/nexus-code#1110`.
#  * PRODUCTION empty-needle sites are a different population with no shared
#    name to key on — `#1093`, guarded by test-empty-needle-production.sh.
#  * It says nothing about whether a caller's needle IS empty today; it says
#    that if one ever is, the assertion goes red instead of green.
#
# Run: bash monitor/watcher/test-empty-needle-local-copies.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

SHARED_DEFINER="monitor/watcher/_test_helpers.sh"

# THE CANDIDATE SCAN IS GRAMMAR-COMPLETE, NOT SPELLING-ENUMERATED, AND THE
# PARSER HAS THE FINAL SAY (your-org/nexus-code#1108 skeptic F1).
#
# The first version of this file was behavioural everywhere EXCEPT here, and a
# regex that decides MEMBERSHIP is a textual guard no matter how behavioural the
# probe behind it is. It read `(function[[:space:]]+)?NAME[[:space:]]*\(\)` —
# the keyword optional, the PARENTHESES mandatory — so `function NAME {`, the
# canonical ksh-style spelling and valid bash, was invisible. A vacuous copy in
# that spelling left this suite at 23/0. Measured on this host, bash 4.4.20:
#
#   f() { :; }             -> declare -F f: f     old DEF_RE saw it
#   function f() { :; }    -> declare -F f: f     old DEF_RE saw it
#   function f () { :; }   -> declare -F f: f     old DEF_RE saw it
#   function f { :; }      -> declare -F f: f     old DEF_RE saw it NOT   <-- the hole
#
# That is the whole list. bash's grammar has exactly three function-definition
# productions (`WORD () body`, `FUNCTION word () body`, `FUNCTION word body`),
# so covering them is a CLOSED claim about the grammar rather than an open list
# of spellings someone thought of — which is what the old regex was.
#
# WHY NOT ASK THE PARSER DIRECTLY, which is the obviously better answer:
# measured, and it fails two independent ways.
#   * `bash -c 'set -n; . file'` parses without executing — and defines nothing,
#     so `declare -F` returns empty. Parse-only yields no names.
#   * Sourcing for real EXECUTES the suite (mktemp trees, subprocesses, tmux),
#     which this guard must never do to 88 files; and it is unreliable anyway,
#     because a suite ending in `exit` terminates the SOURCING shell before
#     `declare -F` can be reached — measured empty for exactly that reason.
# So the parser cannot supply the candidate set. It CAN adjudicate one, and
# `enc_defines` below does exactly that: a candidate counts only if evaluating
# its extraction really defines a function of that name. Membership is therefore
# regex-PROPOSED and parser-CONFIRMED, and the regex can only over-propose.
#
# RESIDUAL, declared rather than left implicit: both patterns anchor at
# `^[[:space:]]*`, so a definition that does not START a line — after a `;`, or
# nested inside a compound — is not proposed. Section A measures that case
# rather than asserting it.
_enc_def_re() {   # _enc_def_re <name> -> the grammar-complete recognizer for it
    printf '^[[:space:]]*(function[[:space:]]+%s([[:space:]]|\{|\(|$)|%s[[:space:]]*\([[:space:]]*\))' "$1" "$1"
}
DEF_RE=$(_enc_def_re assert_contains)
NDEF_RE=$(_enc_def_re assert_not_contains)

# ── the enumerator ──────────────────────────────────────────────────────
# Tracked AND untracked, because a population computed from the index cannot
# see the file you just wrote (#1054). Excludes the shared definer, which is
# not a local copy — counting it there is the arithmetic error `#1092`'s own
# body made.
_enc_files() {   # _enc_files <regex> [root]
    local re="$1" root="${2:-$REPO_ROOT}"
    {
        git -C "$root" grep -lE "$re" -- . 2>/dev/null
        # The untracked half, via the SHARED helper (your-org/nexus-code#1197).
        # This used to be a hand-rolled per-file `grep -qE` loop — one process
        # per untracked file, reading every byte — duplicated verbatim in
        # test-empty-needle-vacuous-helpers.sh. On the operator nexus that read
        # 42 GB, blew guards-for-diff's 180 s probe budget, and took the WHOLE
        # index down to exit 2 REFUSED. Shared rather than fixed twice: a cost
        # fix applied to one copy and not the other leaves the gate down, and
        # the two copies were byte-identical for exactly that reason.
        gp_untracked_matching "$root" "$re"
    } | grep -vFx "$SHARED_DEFINER" | sort -u
}
_enc_population() { _enc_files "$DEF_RE"; _enc_files "$NDEF_RE"; printf '%s\n' "$SHARED_DEFINER"; }

. "$_test_dir/../_guard_population.sh"
gp_population() { ( cd "$REPO_ROOT" && _enc_population | sort -u ); }
gp_handle "$@"

# ── the extractor ───────────────────────────────────────────────────────
# A one-line body (`f() { …; }`) is returned as that line. Otherwise the body
# runs to the first line that is exactly `}` — measured true for all 87 local
# definers at `d8534d3`. Anything else returns non-zero, which the caller
# turns into a FAIL rather than a skip.
# How many definitions of <name> the file proposes. More than one is a REFUSAL
# upstream, not a choice to be made here (skeptic F2): bash keeps the LAST
# definition, this extractor used to take the FIRST, and a guarded definition
# followed by an unguarded override was therefore a silent SKIP — the one
# outcome a default-deny guard may never produce.
enc_ndefs() {   # enc_ndefs <file> <name> ; prints a count, or `?` if it could not count
    # NO `|| printf 0` (your-org/nexus-code#725, caught by
    # test-count-fallback-lint.sh in this PR's own band). `grep -c` exits 1 on a
    # ZERO count and 2 on an ERROR, so an `||` fallback both appends a second
    # zero to grep's own "0" AND turns "I could not read the file" into "there
    # are none" — a manufactured count, in the helper whose whole job is to keep
    # a count from being manufactured. Read the rc instead and say `?` when the
    # answer is unknown; every caller treats anything but `1` as a refusal.
    local n rc
    n=$(grep -cE "$(_enc_def_re "$2")" "$1" 2>/dev/null); rc=$?
    if   [ "$rc" = 0 ]; then printf '%s' "$n"
    elif [ "$rc" = 1 ]; then printf '0'
    else                     printf '?'
    fi
}

enc_extract() {   # enc_extract <file> <name> ; prints the definition, rc 1 if it cannot
    local f="$1" name="$2" ln line cl
    # No `| head -1` / `| tail -1`: those close the pipe early, the writer takes
    # SIGPIPE, and under `pipefail` that becomes the pipeline's status
    # (your-org/nexus-code#622, early-exit-readers.manifest). Take the LAST line
    # with a parameter expansion instead — nothing quits early, and LAST is the
    # definition bash would actually keep.
    ln=$(grep -nE "$(_enc_def_re "$name")" "$f" | cut -d: -f1)
    ln=${ln##*$'\n'}
    [ -n "$ln" ] || return 1
    line=$(sed -n "${ln}p" "$f")
    case "$line" in *'}'*) printf '%s\n' "$line"; return 0 ;; esac
    cl=$(awk -v s="$ln" 'NR>s && /^\}[[:space:]]*$/{print NR; exit}' "$f")
    [ -n "$cl" ] || return 1
    sed -n "${ln},${cl}p" "$f"
}

# Ask the PARSER whether the extraction really is a definition of that name.
# This is what keeps a regex from having the last word on membership: it can
# over-propose freely, and anything it proposes that bash does not read as a
# function definition is caught here rather than silently probed.
enc_defines() {   # enc_defines <definition> <name> -> prints the name, or nothing
    bash --noprofile --norc -c '
        eval "$1" 2>/dev/null || exit 0
        declare -F "$2" >/dev/null 2>&1 && printf %s "$2"
    ' _ "$1" "$2" 2>/dev/null
}

# ── the prober ──────────────────────────────────────────────────────────
# Runs the extracted definition in a clean `bash --noprofile --norc` with the
# arm-reporting primitives every local copy is known to use, and reports which
# arm ran: P, F, or U (undecidable — both moved, or neither).
enc_arm() {   # enc_arm <definition> <fn-name> <haystack> <needle>
    bash --noprofile --norc -c '
        body="$1"; fn="$2"; hay="$3"; needle="$4"
        PASS=0; FAIL=0; SKIP=0; ARM=""
        REAL_GREP=grep
        pass(){ ARM="${ARM}P"; }; ok(){ ARM="${ARM}P"; }; _th_pass(){ ARM="${ARM}P"; }
        fail(){ ARM="${ARM}F"; }; bad(){ ARM="${ARM}F"; }; _th_fail(){ ARM="${ARM}F"; }
        eval "$body" 2>/dev/null || { printf U; exit 0; }
        "$fn" "probe" "$hay" "$needle" >/dev/null 2>&1
        p=0; f=0
        [ "${PASS:-0}" -gt 0 ] 2>/dev/null && p=1
        [ "${FAIL:-0}" -gt 0 ] 2>/dev/null && f=1
        case "$ARM" in *P*) p=1 ;; esac
        case "$ARM" in *F*) f=1 ;; esac
        if   [ "$p" = 1 ] && [ "$f" = 0 ]; then printf P
        elif [ "$f" = 1 ] && [ "$p" = 0 ]; then printf F
        else printf U; fi
    ' _ "$1" "$2" "$3" "$4" 2>/dev/null
}

HAY='alpha beta gamma'

# ═══════════════════════════════════════════════════════════════════════
echo '=== A: the prober itself discriminates (positive + negative controls) ==='
# ═══════════════════════════════════════════════════════════════════════
# A guard never seen to FAIL is not evidence. These are the mutants: an
# UNGUARDED copy in each of the three live spellings must read P on an empty
# needle, or every verdict below is worthless.
_ctl=$(mktemp -d); trap 'rm -rf "$_ctl"' EXIT

cat > "$_ctl/unguarded-grep.sh" <<'EOF'
probe_target() {
    # vacuity-fixture: deliberately unguarded
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then PASS=$(( PASS + 1 )); else FAIL=$(( FAIL + 1 )); fi
}
EOF
cat > "$_ctl/unguarded-glob.sh" <<'EOF'
probe_target() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1"; }  # vacuity-fixture: deliberately unguarded
EOF
cat > "$_ctl/unguarded-realgrep.sh" <<'EOF'
probe_target() {
    # vacuity-fixture: deliberately unguarded
    local label="$1" hay="$2" needle="$3"
    if "$REAL_GREP" -qF -- "$needle" <<<"$hay"; then ok "$1"; else bad "$1"; fi
}
EOF
# A FOURTH spelling, in NO local copy today — the whole point of probing by
# execution rather than by token. A textual lint would pass it silently.
cat > "$_ctl/unguarded-case.sh" <<'EOF'
probe_target() {
    # vacuity-fixture: deliberately unguarded
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" ;; esac
}
EOF
cat > "$_ctl/guarded.sh" <<'EOF'
probe_target() {
    local label="$1" hay="$2" needle="$3"
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then PASS=$(( PASS + 1 )); else FAIL=$(( FAIL + 1 )); fi
}
EOF
# Arms indistinguishable: neither counter moves, no primitive is called.
cat > "$_ctl/undecidable.sh" <<'EOF'
probe_target() { grep -qF -- "$3" <<<"$2"; }  # vacuity-fixture: deliberately unguarded
EOF

for _m in grep glob realgrep case; do
    _d=$(enc_extract "$_ctl/unguarded-$_m.sh" probe_target)
    assert_eq "A: UNGUARDED $_m copy PASSES on an empty needle (the defect, reproduced)" \
        "$(enc_arm "$_d" probe_target "$HAY" '')" "P"
    assert_eq "A: UNGUARDED $_m copy still PASSES on a present needle" \
        "$(enc_arm "$_d" probe_target "$HAY" 'beta')" "P"
done
_d=$(enc_extract "$_ctl/guarded.sh" probe_target)
assert_eq "A: a GUARDED copy FAILS on an empty needle"        "$(enc_arm "$_d" probe_target "$HAY" '')"      "F"
assert_eq "A: a GUARDED copy PASSES on a present needle"      "$(enc_arm "$_d" probe_target "$HAY" 'beta')"  "P"
assert_eq "A: a GUARDED copy FAILS on an absent needle"       "$(enc_arm "$_d" probe_target "$HAY" 'delta')" "F"
_d=$(enc_extract "$_ctl/undecidable.sh" probe_target)
assert_eq "A: indistinguishable arms report U, never a silent pass" \
    "$(enc_arm "$_d" probe_target "$HAY" '')" "U"
enc_extract "$_ctl/unguarded-grep.sh" no_such_fn >/dev/null 2>&1
assert_eq "A: a definition that is not there is rc 1, not an empty success" "$?" "1"

# ═══════════════════════════════════════════════════════════════════════
echo '=== A2: MEMBERSHIP — every grammar form reaches the ENUMERATOR ==='
# ═══════════════════════════════════════════════════════════════════════
# A's controls above hand a definition straight to enc_extract, so they cannot
# see a hole in what the enumerator FINDS — which is exactly where the first
# version of this suite leaked (skeptic F1): `function NAME {` was vacuous,
# present, and never named, at 23/0. These plants therefore go through
# `_enc_files` against a throwaway git repo, one form per row, and the last row
# is the DECLARED residual rather than a claim of completeness.
_fx="$_ctl/fixture"; mkdir -p "$_fx"
git -C "$_fx" init -q 2>/dev/null
git -C "$_fx" config user.email t@t; git -C "$_fx" config user.name t

# THE GRAMMAR MATRIX IS THE GUARANTEE, AND IT IS DATA (your-org/nexus-code#1108
# skeptic round 2). Membership is regex-PROPOSED and parser-CONFIRMED, and those
# two stages are not equal partners: a form stage one never proposes is
# invisible to stage two BY CONSTRUCTION, so no green anywhere else in this file
# can see it. Stage one's completeness IS the guarantee, and it is therefore
# enumerated here rather than argued for in a comment.
#
# Two rounds of review each closed the forms someone had thought to try — the
# `function` keyword, then lexer-permitted whitespace inside production 1's
# parens — and each fix was correct and left the class open one notch further
# out. A third patched pattern would have the same shape. So the pattern is no
# longer the artefact: this table is. Every row is checked on BOTH axes, and the
# first axis is bash's own answer, not mine:
#
#   defines=  source the file in a clean shell, ask `declare -F`  (the SHELL decides)
#   propose=  does the recognizer put the file in the population   (we decide)
#
# A row where those two disagree in the unsafe direction — bash defines it, we
# do not propose it — is an escape. Escapes are permitted only when they fall
# under the DECLARED RESIDUAL, and the residual is a MECHANISM, not a list:
#
#     THE DEFINITION DOES NOT BEGIN A LINE, or is not present as text at all.
#
# Both patterns anchor at `^[[:space:]]*`, so anything preceded on its line by
# other syntax is unreachable to them, and anything constructed at runtime is
# unreachable to any static pattern. That sentence is the boundary. The rows
# marked `residual` below are EXAMPLES OF IT, not its membership — a backslash
# continuation, a mid-line `;`, an `eval`, a one-line `{ … }` group, a `case`
# arm, a `!` prefix, an `&&` prefix. There are more; the mechanism is what
# tells you so.
#
# THAT DISTINCTION IS THE WHOLE LESSON OF THIS FILE'S REVIEW HISTORY, and it is
# stated here because an earlier draft got it wrong in exactly the way the
# recogniser did twice. It said "the only ones permitted are the four marked
# `residual`", which reads as a closed count and invites a reader to check four
# things and conclude they are done. Four more instances of the identical
# mechanism were then found immediately (`{ f() { :; }; }`, a `case` arm,
# `! f()`, `true && f()` — all `defines=1 propose=0`, live exposure 0). The
# sentence was right and the enumeration behind it was not, which is precisely
# how `grammar-complete` was wrong twice. So: name the mechanism, offer
# examples, and never imply the examples exhaust it.
#
# The PROPOSED half is different in kind and IS enumerable, because bash's
# grammar closes it: three productions, and the rows above cover them. That
# asymmetry is the design — an enumerable proposal set, an unenumerable
# residual named by mechanism.
#
# IF YOU FIND A FORM THAT BEGINS A LINE AND IS NOT PROPOSED, ADD A ROW. That is
# a genuine hole and should arrive as a failing assertion. If you find another
# way to hide a definition mid-line, it is already covered by the sentence
# above; add it as an example only if it teaches something new.
#
# id | defines | propose | description | printf payload
_ENC_FORMS='
1|1|1|f() { … }|assert_contains() { :; }\n
2|1|1|function f() { … }|function assert_contains() { :; }\n
3|1|1|function f { … } — the round-1 hole|function assert_contains { :; }\n
4|1|1|function f () { … }|function assert_contains () { :; }\n
5|1|1|f () { … }|assert_contains () { :; }\n
6|1|1|f ( ) { … } — round-2 hole, space INSIDE the parens|assert_contains ( ) { :; }\n
7|1|1|f(  ) { … } — round-2 hole, spaces inside only|assert_contains(  ) { :; }\n
8|1|1|function f ( ) { … } — the asymmetric twin of 6|function assert_contains ( ) { :; }\n
9|1|1|f() then brace on the next line|assert_contains()\n{ :; }\n
10|1|1|function f then brace on the next line|function assert_contains\n{ :; }\n
11|1|1|tab-indented f() { … }|\tassert_contains() { :; }\n
12|1|1|subshell body f() ( … )|assert_contains() ( : )\n
16|1|1|nested inside a { … } group|{\nassert_contains() { :; }\n}\n
17|0|1|nested inside a ( … ) subshell — over-proposed, and safe|(\nassert_contains() { :; }\n)\n
20|1|1|body is [[ … ]] with no braces|assert_contains() [[ -n "$3" ]]\n
21|1|1|function f<TAB>{ … }|function assert_contains\t{ :; }\n
22|1|1|function f() then brace on the next line|function assert_contains()\n{ :; }\n
13|1|0|residual: backslash continuation after `function`|function \\\nassert_contains { :; }\n
14|1|0|residual: backslash continuation before the parens|assert_contains \\\n() { :; }\n
15|1|0|residual: definition after a mid-line `;`|: ; assert_contains() { :; }\n
18|1|0|residual: produced by eval — statically out of reach|eval "assert_contains() { :; }"\n
23|1|0|residual: one-line { … } group|{ assert_contains() { :; }; }\n
24|1|0|residual: inside a case arm|case x in x) assert_contains() { :; };; esac\n
25|1|0|residual: after a `!` prefix|! assert_contains() { :; }\n
26|1|0|residual: after `true &&`|true && assert_contains() { :; }\n
19|0|0|not valid bash: bare name, parens on the next line|assert_contains\n() { :; }\n
NM|0|0|control: a file defining no such function|nope_contains() { :; }\n
'
_enc_defines_from_file() {   # does bash itself define assert_contains from this file?
    bash --noprofile --norc -c '. "$1" >/dev/null 2>&1; declare -F assert_contains >/dev/null 2>&1 && printf 1 || printf 0' _ "$1" 2>/dev/null
}
_enc_rows=0
while IFS='|' read -r _id _def _prop _desc _payload; do
    [ -n "${_id:-}" ] || continue
    _enc_rows=$(( _enc_rows + 1 ))
    printf "$_payload" > "$_fx/form$_id.sh"
    assert_eq "A2[$_id] bash defines it? ($_desc)" "$(_enc_defines_from_file "$_fx/form$_id.sh")" "$_def"
    _got=0; grep -qE "$DEF_RE" "$_fx/form$_id.sh" && _got=1
    assert_eq "A2[$_id] the recognizer proposes it? ($_desc)" "$_got" "$_prop"
done <<EOF
$_ENC_FORMS
EOF
# A table that silently shrank would make every row above vacuous.
assert_eq "A2: the grammar matrix still carries every row" "$_enc_rows" "27"

# The rows above test the RECOGNIZER. This tests the ENUMERATOR — the gap round 1
# found, where A's controls call enc_extract directly and so cannot see a
# membership hole. Both trackedness halves, since a population that drops
# untracked files is #1054 wearing a different hat.
git -C "$_fx" add form1.sh formNM.sh >/dev/null 2>&1
git -C "$_fx" commit -qm f >/dev/null 2>&1
_found=$(_enc_files "$DEF_RE" "$_fx")
_in=0; grep -qFx "form1.sh" <<<"$_found" && _in=1
assert_eq "A2: the enumerator finds a TRACKED member"   "$_in" "1"
_in=0; grep -qFx "form6.sh" <<<"$_found" && _in=1
assert_eq "A2: …and an UNTRACKED one (the round-2 hole, end to end)" "$_in" "1"
_in=0; grep -qFx "formNM.sh" <<<"$_found" && _in=1
assert_eq "A2: …and does not claim a file that defines no such function" "$_in" "0"

# The parser, not the pattern, has the last word on what a candidate IS.
assert_eq "A2: the parser confirms a proposed candidate is really a definition" \
    "$(enc_defines "$(enc_extract "$_fx/form3.sh" assert_contains)" assert_contains)" "assert_contains"
assert_eq "A2: …and refuses text that merely looks like one" \
    "$(enc_defines 'assert_contains() { unbalanced' assert_contains)" ""

# F2: bash keeps the LAST definition, so a file with two is REFUSED, not sampled.
printf 'assert_contains() { [[ -n "$3" ]] && grep -qF -- "$3" <<<"$2" && pass "$1" || fail "$1"; }\nassert_contains() { grep -qF -- "$3" <<<"$2" && pass "$1" || fail "$1"; }\n' > "$_fx/twodefs.sh"
assert_eq "A2: a file carrying TWO definitions is counted as two, not silently sampled" \
    "$(enc_ndefs "$_fx/twodefs.sh" assert_contains)" "2"
assert_eq "A2: …and extraction takes the LAST one, which is the one bash keeps" \
    "$(enc_arm "$(enc_extract "$_fx/twodefs.sh" assert_contains)" assert_contains "$HAY" '')" "P"
assert_eq "A2: …where taking the FIRST would have wrongly reported it guarded" \
    "$(enc_arm "$(sed -n 1p "$_fx/twodefs.sh")" assert_contains "$HAY" '')" "F"
# And a count that cannot be taken says so, rather than reporting zero (#725).
assert_eq "A2: an uncountable file yields '?', never a manufactured 0" \
    "$(enc_ndefs "$_fx/no-such-file.sh" assert_contains)" "?"

# ═══════════════════════════════════════════════════════════════════════
echo '=== B: the population is non-trivial and excludes the shared definer ==='
# ═══════════════════════════════════════════════════════════════════════
_pos=(); _npos=()
while IFS= read -r _f; do [ -n "$_f" ] && _pos+=("$_f"); done < <(cd "$REPO_ROOT" && _enc_files "$DEF_RE")
while IFS= read -r _f; do [ -n "$_f" ] && _npos+=("$_f"); done < <(cd "$REPO_ROOT" && _enc_files "$NDEF_RE")

# A zero here would make every per-member assertion below vacuous in exactly
# the way this suite exists to forbid — the enumerator's own silent zero.
_enough=0; (( ${#_pos[@]} >= 50 )) && _enough=1
assert_eq "B: local assert_contains definers found (>= 50; 87 at d8534d3)" "$_enough" "1"
_enough=0; (( ${#_npos[@]} >= 30 )) && _enough=1
assert_eq "B: local assert_not_contains definers found (>= 30; 65 at d8534d3)" "$_enough" "1"
_shared_in=0
for _f in "${_pos[@]}"; do [ "$_f" = "$SHARED_DEFINER" ] && _shared_in=1; done
assert_eq "B: the SHARED definer is not counted as a local copy" "$_shared_in" "0"
assert_eq "B: the shared definer itself refuses an empty needle (#1038 still in place)" \
    "$(enc_arm "$(enc_extract "$REPO_ROOT/$SHARED_DEFINER" assert_contains)" assert_contains "$HAY" '')" "F"

# ═══════════════════════════════════════════════════════════════════════
echo '=== C: EVERY local assert_contains refuses an empty needle ==='
# ═══════════════════════════════════════════════════════════════════════
_bad_empty=(); _bad_present=(); _bad_absent=(); _unreadable=(); _multidef=(); _unconfirmed=()
for _f in "${_pos[@]}"; do
    if [ "$(enc_ndefs "$REPO_ROOT/$_f" assert_contains)" != 1 ]; then _multidef+=("$_f"); continue; fi
    _d=$(enc_extract "$REPO_ROOT/$_f" assert_contains) || { _unreadable+=("$_f"); continue; }
    [ "$(enc_defines "$_d" assert_contains)" = assert_contains ] || { _unconfirmed+=("$_f"); continue; }
    [ "$(enc_arm "$_d" assert_contains "$HAY" '')"      = F ] || _bad_empty+=("$_f")
    [ "$(enc_arm "$_d" assert_contains "$HAY" 'beta')"  = P ] || _bad_present+=("$_f")
    [ "$(enc_arm "$_d" assert_contains "$HAY" 'delta')" = F ] || _bad_absent+=("$_f")
done
printf '%s\n' "${_bad_empty[@]:-}"   | sed '/^$/d;s/^/    still vacuous: /' >&2
printf '%s\n' "${_bad_present[@]:-}" | sed '/^$/d;s/^/    broken (present needle no longer passes): /' >&2
printf '%s\n' "${_bad_absent[@]:-}"  | sed '/^$/d;s/^/    inverted (absent needle passes): /' >&2
printf '%s\n' "${_unreadable[@]:-}"  | sed '/^$/d;s/^/    UNREADABLE definition (default-deny): /' >&2
printf '%s\n' "${_multidef[@]:-}"    | sed '/^$/d;s/^/    MORE THAN ONE definition of assert_contains (bash keeps the LAST): /' >&2
printf '%s\n' "${_unconfirmed[@]:-}" | sed '/^$/d;s/^/    proposed but NOT confirmed a function definition by the parser: /' >&2
assert_eq "C: local assert_contains copies vacuous on an empty needle" "${#_bad_empty[@]}"    "0"
assert_eq "C: local assert_contains copies broken on a present needle" "${#_bad_present[@]}"  "0"
assert_eq "C: local assert_contains copies inverted on an absent needle" "${#_bad_absent[@]}" "0"
assert_eq "C: local assert_contains definitions this suite could not read"  "${#_unreadable[@]}" "0"
assert_eq "C: files carrying MORE THAN ONE assert_contains definition"      "${#_multidef[@]}"   "0"
assert_eq "C: candidates the parser would not confirm as a definition"      "${#_unconfirmed[@]}" "0"

# ═══════════════════════════════════════════════════════════════════════
echo '=== D: EVERY local assert_not_contains also refuses an empty needle ==='
# ═══════════════════════════════════════════════════════════════════════
# The mirror is a MEASURED boundary, not an assumption. `#1038` established
# that `assert_not_contains` already fails CLOSED on an empty needle — the
# vacuous match takes its FAIL arm — which is the correct DIRECTION and is why
# nothing drew attention to its sibling. That is asserted here rather than
# believed, because "it is already correct" is exactly the reasoning that let
# the positive half survive 4,337 call sites.
_bad_n=(); _unreadable_n=()
for _f in "${_npos[@]}"; do
    if [ "$(enc_ndefs "$REPO_ROOT/$_f" assert_not_contains)" != 1 ]; then _unreadable_n+=("$_f"); continue; fi
    _d=$(enc_extract "$REPO_ROOT/$_f" assert_not_contains) || { _unreadable_n+=("$_f"); continue; }
    [ "$(enc_defines "$_d" assert_not_contains)" = assert_not_contains ] || { _unreadable_n+=("$_f"); continue; }
    [ "$(enc_arm "$_d" assert_not_contains "$HAY" '')" = F ] || _bad_n+=("$_f")
done
printf '%s\n' "${_bad_n[@]:-}"        | sed '/^$/d;s/^/    not_contains vacuous: /' >&2
printf '%s\n' "${_unreadable_n[@]:-}" | sed '/^$/d;s/^/    UNREADABLE, multiply-defined or parser-unconfirmed not_contains (default-deny): /' >&2
assert_eq "D: local assert_not_contains copies that accept an empty needle" "${#_bad_n[@]}" "0"
assert_eq "D: local assert_not_contains definitions this suite could not vouch for" "${#_unreadable_n[@]}" "0"

# ═══════════════════════════════════════════════════════════════════════
# The count is DERIVED from the population, because the population grows. A
# literal here would have to be edited on every added suite, which is how a
# count guard becomes noise and then gets deleted.
EXPECTED=$(( 13 + (27 * 2) + 1 + 3 + 2 + 4 + 4 + 6 + 2 ))
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
