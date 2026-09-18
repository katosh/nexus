#!/usr/bin/env bash
# A SUITE MAY NOT ANNOUNCE A PASS OVER WORK IT DID NOT DO.
# (your-org/nexus-code#805)
#
# THE DEFECT. `th_summary_and_exit` printed from the in-memory counters and
# exited 0 whenever `FAIL == 0`. It never asked whether anything had been
# COUNTED AT ALL:
#
#     $ bash -c '. _test_helpers.sh; th_summary_and_exit'
#     === summary: 0 passed, 0 failed ===
#     ALL TESTS PASSED                                   # rc 0
#
# Zero assertions, unqualified banner, exit 0 — indistinguishable from a suite
# that ran 105 assertions and passed them all, to a human, to run-tests.sh, and
# to `grep -c 'ALL TESTS PASSED'`. It was live: `test-fs-guard.sh`'s
# running-as-root path reached the summary with all three counters at zero.
#
# THREE VARIANTS, and this file exists because a `(( PASS+FAIL+SKIP == 0 ))`
# guard would only have closed the first. In the other two the counters are
# LYING rather than empty, so a guard that reads the counters cannot see them:
#
#   1. NOTHING RAN            — all three counters at zero.
#   2. LOST IN A SUBSHELL     — `assert_*` mutates globals, so a FAIL inside
#                               `( … )` or `$( … )` dies with the child and the
#                               suite still exits 0. `#783`'s uncounted abort,
#                               reached by a different road.
#   3. MISSING HELPER (`#609`)— a call to an undefined `assert_*` is rc 127 and
#                               nothing counts it.
#
# EVERY CASE BELOW IS A NEGATIVE CONTROL RUN AS A CHILD PROCESS. The child's
# rc and output ARE the evidence; running them in-process would corrupt this
# suite's own counters and, worse, would let a broken helper mark its own
# homework. Each case asserts the rc AND the banner text, because "exits 1" and
# "does not claim a pass" are different promises and this repo has shipped
# each without the other.
#
# Run: bash monitor/watcher/test-assertion-ledger.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
HELPERS="$_test_dir/_test_helpers.sh"

# run_case <shell-body> — sets the globals $OUT (combined output) and $RC.
#
# IT MUST NOT BE CALLED IN A COMMAND SUBSTITUTION, and the first draft of this
# file did exactly that (`rc=$(run_case …)`). `$( … )` is a subshell, so every
# `OUT=` it performed died with the child and the parent compared against an
# empty string. The `assert_contains` cases failed loudly — but the
# `assert_not_contains` cases PASSED, vacuously, because the empty string
# contains nothing.
#
# That is this file's own subject reproduced inside the test written to pin it:
# an assertion that cannot fail for the right reason, reading as a pass. It is
# recorded here rather than quietly fixed because the shape is the point — the
# repo keeps re-learning that `assert_*` and its globals do not survive a
# subshell, which is precisely why #805 made the LEDGER durable.
OUT=""
RC=""
run_case() {
    OUT=$(bash -c "set -uo pipefail; . '$HELPERS'; $1" 2>&1)
    RC=$?
}

# ── VARIANT 1: NOTHING ASSERTED ─────────────────────────────────────────
run_case 'th_summary_and_exit'
assert_eq "V1 zero assertions: rc is NOT 0" \
    "$([[ "$RC" == 0 ]] && echo zero || echo nonzero)" "nonzero"
assert_not_contains "V1 zero assertions: refuses the ALL TESTS PASSED banner" \
    "$OUT" "ALL TESTS PASSED"
assert_contains "V1 zero assertions: says outright that nothing was asserted" \
    "$OUT" "NOTHING ASSERTED"
# The remedy must be NAMED, not merely implied. A guard that reds without
# telling the author the sanctioned alternative gets worked around, not obeyed.
assert_contains "V1 zero assertions: names th_skip as the honest alternative" \
    "$OUT" "th_skip"

# ── VARIANT 2: A FAIL COUNTED IN A SUBSHELL ─────────────────────────────
# Pre-#805 this printed `1 passed, 0 failed` / ALL TESTS PASSED / rc 0.
run_case '( assert_eq "inside a subshell" 1 2 ); assert_eq "outer" 1 1; th_summary_and_exit'
assert_eq "V2 subshell FAIL: the suite goes RED" "$RC" "1"
assert_not_contains "V2 subshell FAIL: no pass banner" "$OUT" "ALL TESTS PASSED"
assert_contains "V2 subshell FAIL: the loss is named as a subshell loss" \
    "$OUT" "counted in a SUBSHELL"
assert_contains "V2 subshell FAIL: the recovered failure appears in the count" \
    "$OUT" "1 failed"

# A FAIL inside a COMMAND SUBSTITUTION is the same class by a different
# spelling, and it is the one that actually appears in the corpus
# (`x=$(helper_that_asserts)`), so it gets its own case rather than being
# assumed to follow.
run_case 'x=$(assert_eq "inside cmdsubst" 1 2); th_summary_and_exit'
assert_eq "V2b cmdsubst FAIL: also goes RED" "$RC" "1"

# ── VARIANT 3: A MISSING ASSERTION HELPER (#609) ────────────────────────
run_case 'assert_definitely_not_defined "x" 1 1; th_summary_and_exit'
assert_eq "V3 missing helper: the suite goes RED" "$RC" "1"
assert_contains "V3 missing helper: says WHICH helper was missing" \
    "$OUT" "MISSING TEST HELPER"
# ONE explanation, not two. bash forks before `command_not_found_handle`, so the
# missing-helper failure is ALWAYS lost to the parent and the generic
# subshell-loss paragraph would fire on top of the specific one. The `M` ledger
# letter exists solely to attribute it correctly; this asserts that.
assert_not_contains "V3 missing helper: NOT also blamed on a generic subshell" \
    "$OUT" "counted in a SUBSHELL"

# ── THE GREEN PATHS MUST BE UNCHANGED ───────────────────────────────────
# The whole risk of this change is reddening suites that were honest. These are
# the negative controls for the fix itself.
run_case 'assert_eq "a" 1 1; assert_eq "b" 2 2; th_summary_and_exit'
assert_eq "an ordinary passing suite still exits 0" "$RC" "0"
assert_contains "…and still prints the unqualified banner" "$OUT" "ALL TESTS PASSED"
assert_contains "…with its real count" "$OUT" "2 passed, 0 failed"

run_case 'th_skip "a case" "precondition absent on this host"; th_summary_and_exit'
assert_eq "a suite whose only outcome is a th_skip stays GREEN" "$RC" "0"
assert_contains "…under the qualified SKIP banner, never the bare one" \
    "$OUT" "SKIPPED — NOT covered"

# A PASS lost in a subshell is a COUNT problem, not a failure: the work was done
# and it passed. Reddening it would punish the legitimate
# `x=$(fn_that_asserts)` idiom, so it must stay green — but the printed count
# must be corrected, or an EXPECTED=<n> guard downstream is pinned to a lie.
run_case 'x=$(assert_eq "passing, in a subshell" 1 1); th_summary_and_exit'
assert_eq "a PASS lost in a subshell stays GREEN" "$RC" "0"
assert_contains "…but the count is corrected from the ledger" "$OUT" "1 passed"
assert_contains "…and the correction is stated, not silent" "$OUT" "NOTE:"

# ── LEDGER HYGIENE ──────────────────────────────────────────────────────
# A ledger left behind would be read by the next process that recycles the pid,
# manufacturing assertions nobody made — which would be a fresh instance of
# this file's own subject.
# COUNTED IN A PRIVATE TMPDIR, NOT THE SHARED ONE (your-org/nexus-code#1317).
# This sampled `${TMPDIR:-/tmp}` before and after its own case. That directory is
# SHARED and globally mutating: under `run-tests.sh --jobs N` the other N-1
# suites create and remove THEIR ledgers between the two `find` calls, so
# `after > before` for reasons having nothing to do with this suite. Measured on
# a quiet box (0 sibling bands, loadavg 37) at `--jobs 4`: this suite is
# **35 passed / 0 failed SOLO** and FAILS in-band at 2.22s on exactly this
# assertion — a false red that is green in isolation, which is `#1317`'s claim,
# measured with a mechanism rather than assumed.
#
# The window is not narrow: /tmp held **63,642** `.th-ledger.*` files at the time
# of measurement (all one uid, oldest 2026-08-27), and the `find` above takes
# **260 ms** over that population — 260 ms of sibling writes, every run.
#
# Giving the case its own TMPDIR preserves the assertion's PURPOSE exactly — does
# `th_summary_and_exit` remove the ledger it created — while removing the shared
# -directory confound. `_TH_LEDGER` is `"${TMPDIR:-/tmp}/.th-ledger.$_TH_KEY"`,
# so the child writes where we point it.
#
# NOTE the 63,642 is a SECOND finding and is NOT fixed here: ledgers are leaking
# corpus-wide. `th_summary_and_exit` removes its own, so the leak is every suite
# that dies, times out, or never reaches summary. That wants its own issue.
_lh_tmp=$(mktemp -d) || _lh_tmp=''
if [[ -n "$_lh_tmp" ]]; then
    before=$(find "$_lh_tmp" -maxdepth 1 -name '.th-ledger.*' 2>/dev/null | wc -l)
    OUT=$(TMPDIR="$_lh_tmp" bash -c "set -uo pipefail; . '$HELPERS'; assert_eq \"x\" 1 1; th_summary_and_exit" 2>&1); RC=$?
    after=$(find "$_lh_tmp" -maxdepth 1 -name '.th-ledger.*' 2>/dev/null | wc -l)
    rm -rf "$_lh_tmp"
else
    before=0; after=1   # mktemp failed: fail the assertion rather than pass vacuously
fi
assert_eq "the ledger is removed at summary time (no growth in stale files)" \
    "$([[ "$after" -le "$before" ]] && echo clean || echo leaked)" "clean"

# A SEPARATE child process must not contaminate its parent's count. Several
# suites run fixtures that themselves source these helpers; if those shared a
# ledger, a fixture's assertions would be attributed to the suite that ran it.
KID=$(mktemp) || { echo "FAIL: mktemp for the child fixture"; exit 1; }
cat >"$KID" <<KIDEOF
. "$HELPERS"
assert_eq "child one" 1 1
assert_eq "child two" 2 2
th_summary_and_exit
KIDEOF
run_case "assert_eq 'parent' 1 1; bash '$KID' >/dev/null 2>&1; th_summary_and_exit"
assert_eq "a separate child process keeps its own ledger" "$RC" "0"
assert_contains "…so the parent counts only its OWN assertion" "$OUT" "1 passed, 0 failed"

# ── th_expect_fail: A DELIBERATE FAILURE, DECLARED (your-org/nexus-code#821) ──
#
# THESE TESTS EXIST BECAUSE THE PR THAT ADDED `th_expect_fail` DID NOT WRITE
# THEM. The `#830` skeptic found the helper had no test and no call site
# anywhere in the tree — which is `#822`'s defect class ("a helper with no
# dedicated suite") reproduced inside the change that closes it. The helper was
# CORRECT; it was simply unobservable, so a regression would have reddened
# nothing. These four cases are the skeptic's, folded in.
#
# WHY THE HELPER EXISTS. The ledger cannot distinguish a failure LOST in a
# subshell from one PROVOKED there on purpose — both are an `F` appended by a
# child. `th_expect_fail` lets a suite declare the provocation and asserts how
# many occurred, so it nets out without becoming a blanket mute.
#
# The last case is the load-bearing one: a mute would swallow a real regression
# alongside the intended failure, which is the exemption-shaped hole this repo
# keeps closing.
_tef() {   # _tef <body> -> sets OUT/RC via run_case
    run_case "provoke() { $1; }; th_expect_fail 'declared' 1 -- provoke; \
              assert_eq 'a real assertion still counts' 1 1; th_summary_and_exit"
}

_tef 'x=$(assert_eq "deliberate" 1 2)'
assert_eq "provokes 1, declares 1 → GREEN" "$RC" "0"
assert_contains "…the provoked failure is netted out of the count" "$OUT" "0 failed"
assert_contains "…and real assertions are still counted" "$OUT" "2 passed"

_tef 'x=$(assert_eq "d1" 1 2); y=$(assert_eq "d2" 1 2)'
assert_eq "provokes 2, declares 1 → RED (not a blanket mute)" "$RC" "1"
assert_contains "…and says how many it actually provoked" "$OUT" "provoked 2"

_tef 'x=$(assert_eq "now passes" 1 1)'
assert_eq "provokes 0, declares 1 → RED (the block stopped provoking)" "$RC" "1"

run_case "provoke() { x=\$(assert_eq 'deliberate' 1 2); }; \
          th_expect_fail 'declared' 1 -- provoke; \
          ( assert_eq 'REAL regression' 1 2 ); th_summary_and_exit"
assert_eq "a REAL subshell failure alongside a declared one → still RED" "$RC" "1"
assert_contains "…and the real one is reported as a subshell loss" \
    "$OUT" "counted in a SUBSHELL"

# ── THE SOURCE INVARIANT ────────────────────────────────────────────────
# Every counted outcome must go through _th_pass/_th_fail/_th_skip, because a
# ledger that twenty call sites have to remember to update is a ledger that will
# be wrong. Twenty raw increments were replaced to establish this; this asserts
# none has come back.
#
# TWO THINGS ARE EXCLUDED, and both had to be learned:
#
#   COMMENTS — the first draft flagged the ledger's OWN doc comment, which
#   quotes the banned spelling while explaining why it is banned. A lint tripped
#   by prose describing its own rule is the #806 self-trip class again.
#
#   HEREDOC BODIES — fixture text a file WRITES is not code it RUNS.
#
# THE CONTROLS BELOW ARE WHY THIS SECTION IS NOT DECORATION (#822). With the
# stripper disabled outright, this whole suite used to stay green: the comment
# filter alone was enough to keep the real check clean, so the file consumed
# `th_strip_heredocs` without ever depending on it. Its green was not evidence
# about the stripper. Now a positive control proves the detector fires at all,
# and a heredoc control fails the moment stripping stops.
_raw_increment_hits() {   # _raw_increment_hits <file> -> count
    th_strip_heredocs "$1" 2>/dev/null \
        | grep -nE '(PASS|FAIL|SKIP)=\$\(\( *(\$\{)?(PASS|FAIL|SKIP)' \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        | grep -vc '_th_note' || true
}

CTL=$(mktemp -d) || { echo "FAIL: mktemp for the controls"; exit 1; }
trap 'rm -f "$KID"; rm -rf "$CTL"' EXIT

# POSITIVE CONTROL — a detector that cannot fire certifies nothing.
printf '%s\n' '#!/usr/bin/env bash' 'PASS=$(( PASS + 1 ))' > "$CTL/real.sh"
assert_eq "POSITIVE CONTROL: a real raw increment IS detected" \
    "$(_raw_increment_hits "$CTL/real.sh")" "1"

# HEREDOC CONTROL — the same literal, written as fixture text. This is the
# assertion that binds this suite to th_strip_heredocs: disable stripping and it
# fails, which is exactly what #822 found was missing.
cat >"$CTL/heredoc.sh" <<'HCTL'
#!/usr/bin/env bash
cat > /tmp/fixture <<'INNER'
PASS=$(( PASS + 1 ))
INNER
HCTL
assert_eq "HEREDOC CONTROL: the same literal as fixture text is NOT detected" \
    "$(_raw_increment_hits "$CTL/heredoc.sh")" "0"

# COMMENT CONTROL — prose describing the rule is not a call site.
printf '%s\n' '#!/usr/bin/env bash' '# never write PASS=$(( PASS + 1 )) here' > "$CTL/comment.sh"
assert_eq "COMMENT CONTROL: the literal in a comment is NOT detected" \
    "$(_raw_increment_hits "$CTL/comment.sh")" "0"

# THE ACTUAL INVARIANT, now that the detector is known to work in both directions.
n_raw=$(_raw_increment_hits "$HELPERS")
if [[ "$n_raw" == "0" ]]; then
    _th_pass
    echo "  PASS: no raw counter increment outside _th_pass/_th_fail/_th_skip"
else
    _th_fail
    printf '  FAIL: %s raw counter increment(s) bypassing the ledger in %s\n' \
        "$n_raw" "${HELPERS##*/}" >&2
    printf '        Use _th_pass / _th_fail / _th_skip — a raw increment is invisible to the\n' >&2
    printf '        durable ledger, which is what recovers a count lost in a subshell.\n' >&2
fi

# EXPECTED-COUNT GUARD (your-org/nexus-code#807). Every assertion above is
# unconditional, so this is a constant.
EXPECTED=35
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
