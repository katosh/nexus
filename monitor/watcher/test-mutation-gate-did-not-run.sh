#!/usr/bin/env bash
# `did-not-run` is NOT a verdict — pinned in BOTH directions.
# (your-org/nexus-code#1280)
#
# Run: bash monitor/watcher/test-mutation-gate-did-not-run.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS FILE EXISTS. `monitor/mutation-gate.sh` reported
#
#     VERDICT: killed-unattributable (rc 77, no witness)
#     The suite reddened and the harness cannot name WHICH assertion did it.
#
# for a suite in which ZERO assertions ran in EITHER arm. The tool invokes the
# suite as a bare `exec bash "$@"` and sets no gating variable, so every
# `SLOW_TESTS`/`RUN_INTEGRATION`-gated suite self-skips at rc 77 in both arms —
# routine, not exotic. The two arms then disagreed about 77: the baseline
# admitted it as green (`-ne 0 && -ne 77`), the mutant granted `survived` only
# on rc 0, so the identical 77 matched neither and fell through to a KILL.
#
# The direction is what makes it expensive. `killed-unattributable` is a KILL,
# and CLAUDE.md's worker floor tells every agent to prefer this tool over a
# hand-rolled mutant — so the false signal lands in the one place a worker is
# told to trust INSTEAD of their own judgement, and reads as "my guard has
# teeth" about a suite that never executed a line.
#
# THE CLASS IS `did-not-run RENDERED AS A VERDICT`, and it has TWO directions.
# The reported one is the kill. The other is worse: `survived` is read as
# "nothing asserts this line" and sends a worker to write coverage that already
# exists. Both are pinned here, because a fix that only closed the reported
# direction would leave the class open in the direction nobody looked at.
#
# NON-VACUITY — every refusal below is measured against a POSITIVE CONTROL that
# builds a real experiment and requires the tool to reach a real verdict (§4).
# A gate that refused everything would satisfy §1–§3 for free, and that is the
# exact failure this repo keeps finding: a guard whose green never required the
# work to happen.
#
# COVERAGE BOUNDARY, on the axis the mechanism varies on. This pins the
# DECISION LOGIC of `monitor/mutation-gate.sh` — which outcomes are refusals
# and which are verdicts — by driving the real tool against purpose-built
# fixture suites. It does NOT pin the eligibility predicate or the structural
# bound; those are `test-mutation-gate-bounds.sh`, and this file deliberately
# does not restate them. It also does not claim the SKIP status list is
# complete: `MG_SKIP_RCS` exists precisely because it cannot be, and §3 is the
# status-agnostic condition that stands when the list is short.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
GATE="$REPO_ROOT/monitor/mutation-gate.sh"

. "$_test_dir/_test_helpers.sh"
EXPECTED_ASSERTIONS=97   # counted BEFORE the census assertion itself
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s (got %q)\n' "$label" "$got"; _th_pass
    else printf '  FAIL: %s — got %q, want %q\n' "$label" "$got" "$want" >&2; _th_fail; fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    # An EMPTY needle matches every haystack, so this assertion could only pass
    # VACUOUSLY — the shape `monitor/watcher/test-empty-needle-local-copies.sh`
    # enrols every local copy against (your-org/nexus-code#1092). Fail CLOSED
    # and blame the CALLER, whose expected value came back empty.
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" && "$hay" == *"$needle"* ]]; then printf '  PASS: %s\n' "$label"; _th_pass
    else printf '  FAIL: %s — %q not found in output\n' "$label" "$needle" >&2; _th_fail; fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if [[ "$hay" != *"$needle"* ]]; then printf '  PASS: %s\n' "$label"; _th_pass
    else printf '  FAIL: %s — %q WAS found in output\n' "$label" "$needle" >&2; _th_fail; fi
}

[[ -r "$GATE" ]] || { echo "missing: $GATE" >&2; exit 2; }

WORK=$(mktemp -d "/tmp/mgdnr-$$-XXXXXX") || { echo "cannot mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# run <gate-path> <args...> -> prints "<rc>|<combined output>"
#
# The rc is captured on the line that produces it, before anything else runs.
# `"$(cmd)" "$?"` in one argument list destroys the status (your-org/nexus-code#1202),
# and a pipe would report the LAST command's status (`#928`) — the two shapes
# this repo keeps paying for, and both would silently turn every assertion
# below into a claim about `printf`.
run() {
    local g="$1"; shift
    local o rc
    o=$("$g" "$@" </dev/null 2>&1); rc=$?
    printf '%s|%s' "$rc" "$o"
}

# ── §0  FIXTURES ────────────────────────────────────────────────────────
#
# Four suites, each built to reach one outcome. Every one is EXECUTED bare
# below and its own rc asserted, so a fixture that stops having the property
# it was built for reddens here instead of silently changing what §1–§4 test.
echo '=== §0 fixtures: each is what it claims to be, asserted rather than assumed ==='

# A — gated: self-skips at rc 77 in every arm. The reported repro.
#
# HERMETIC BY CONSTRUCTION, and this is load-bearing (it was not, and CI caught
# it). This fixture exists to BE a suite that self-skips, so its skip must not
# depend on the ambient environment. It first gated on the real `SLOW_TESTS`,
# which is exactly what a genuinely-gated suite does — and the SLOW band
# EXPORTS `SLOW_TESTS=1`. There the fixture RAN instead of skipping, so
# mutation-gate saw a green baseline and a green mutant and returned
# `survived` (exit 4). One inverted fixture premise produced a UNIFORM 4 across
# every assertion expecting 3 or 5 — a single upstream fact wearing four
# independent-looking failures.
#
# The gate is therefore a variable this fixture OWNS and nothing exports,
# mirroring fixture B's `HAVE_TOOL` below. The skip MESSAGE still names
# `SLOW_TESTS=1`, because that string is what a real gated suite prints and
# what §1 asserts mutation-gate echoes back as the remedy — the message is the
# thing under test, the gate is not.
cat > "$WORK/a-skip.sh" <<'FIXA'
#!/usr/bin/env bash
set -uo pipefail
FIXTURE_GATE=0
if [ "$FIXTURE_GATE" != 1 ]; then
    echo "skipped: a-skip (set SLOW_TESTS=1 to enable)"
    exit 77
fi
P=0
assert_eq() { if [ "$2" = "$3" ]; then P=$((P+1)); echo "  PASS: $1"; else echo "  FAIL: $1"; exit 1; fi; }
assert_eq "alpha" a a
assert_eq "beta" b b
echo "=== summary: $P passed, 0 failed ==="
FIXA

# B — runs green unmutated; commenting line 3 sends it down its OWN skip path.
# This is the direction the report did NOT have: baseline ran, mutant did not.
cat > "$WORK/b-mutskip.sh" <<'FIXB'
#!/usr/bin/env bash
set -uo pipefail
HAVE_TOOL=1
[ "${HAVE_TOOL:-0}" = 1 ] || { echo "skipped: b-mutskip (no tool)"; exit 77; }
P=0
assert_eq() { if [ "$2" = "$3" ]; then P=$((P+1)); echo "  PASS: $1"; else echo "  FAIL: $1"; exit 1; fi; }
assert_eq "gamma" c c
echo "=== summary: $P passed, 0 failed ==="
FIXB

# C — green in both arms and declares NO assertion total, so the tool cannot
# tell "ran and passed" from "did nothing and exited 0". The SURVIVED
# direction of the class, and the one the finding never looked at.
cat > "$WORK/c-indist.sh" <<'FIXC'
#!/usr/bin/env bash
set -uo pipefail
echo "  PASS: delta"
echo "  PASS: epsilon"
FIXC

# D — a real, count-guarded experiment. The positive control: the tool must
# still reach `killed-by-assertion` here, or §1–§3 are satisfied by a gate
# that refuses everything.
cat > "$WORK/d-guarded.sh" <<'FIXD'
#!/usr/bin/env bash
set -uo pipefail
P=0; F=0
assert_eq() { if [ "$2" = "$3" ]; then P=$((P+1)); echo "  PASS: $1"; else F=$((F+1)); echo "  FAIL: $1"; fi; }
assert_eq "one" a a
assert_eq "two" b b
[ $((P+F)) -eq 2 ] || { echo "  FAIL: ASSERTION COUNT MISMATCH — $((P+F)) ran, 2 expected"; F=$((F+1)); }
echo "=== summary: $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
FIXD

# E — the OTHER real verdict: counts declared, no count guard, so the same
# mutation must still be reported `survived`. Without this, a fix that
# refused every rc-0/rc-0 pair would pass §4a and look correct.
sed '/ASSERTION COUNT MISMATCH/d' "$WORK/d-guarded.sh" > "$WORK/e-unguarded.sh"

# F — a genuinely RED baseline. Used ONLY as the mutants' run-proof: the
# pre-fix baseline arm has its own message for this case, so seeing that
# message is proof the mutated region executed.
cat > "$WORK/f-red.sh" <<'FIXF'
#!/usr/bin/env bash
set -uo pipefail
P=0
assert_eq() { if [ "$2" = "$3" ]; then P=$((P+1)); echo "  PASS: $1"; else echo "  FAIL: $1"; fi; }
assert_eq "zeta" x y
echo "=== summary: $P passed, 1 failed ==="
exit 1
FIXF

chmod +x "$WORK"/*.sh

bash "$WORK/a-skip.sh" </dev/null >/dev/null 2>&1; assert_eq "fixture A skips bare (rc 77)" "$?" "77"
bash "$WORK/b-mutskip.sh" </dev/null >/dev/null 2>&1; assert_eq "fixture B is green bare (rc 0)" "$?" "0"
bash "$WORK/c-indist.sh" </dev/null >/dev/null 2>&1; assert_eq "fixture C is green bare (rc 0)" "$?" "0"
bash "$WORK/d-guarded.sh" </dev/null >/dev/null 2>&1; assert_eq "fixture D is green bare (rc 0)" "$?" "0"
bash "$WORK/e-unguarded.sh" </dev/null >/dev/null 2>&1; assert_eq "fixture E is green bare (rc 0)" "$?" "0"
bash "$WORK/f-red.sh" </dev/null >/dev/null 2>&1; assert_eq "fixture F is RED bare (rc 1)" "$?" "1"
# Fixture C must genuinely be uncountable, or §3 tests nothing. Asserted by
# the SAME reader the gate uses, not by inspection.
_c_out=$(bash "$WORK/c-indist.sh" </dev/null 2>&1)
assert_not_contains "fixture C declares no parseable assertion total" "$_c_out" "=== summary:"

# ── §1  A SKIPPED BASELINE IS REFUSED, NOT KILLED ───────────────────────
echo '=== §1 the reported repro: a gated suite self-skips in both arms ==='
r=$(run "$GATE" --suite "$WORK/a-skip.sh" --line 10)
assert_eq       "§1 a skipped baseline is REFUSED (exit 3), not a verdict" "${r%%|*}" "3"
assert_contains "§1 …and the refusal says it DID NOT RUN"                  "${r#*|}"  "SKIPPED (rc 77). It did not run"
assert_contains "§1 …naming the remedy the suite itself asks for"          "${r#*|}"  "SLOW_TESTS=1"
# The two strings the pre-fix tool emitted. Their ABSENCE is the finding.
assert_not_contains "§1 …and it is NOT reported as a kill"                 "${r#*|}"  "killed-unattributable"
assert_not_contains "§1 …nor as a survival"                                "${r#*|}"  "VERDICT: survived"

# ── §2  A SKIPPED MUTANT IS REFUSED TOO ─────────────────────────────────
echo '=== §2 the direction the report did not have: baseline ran, mutant did not ==='
r=$(run "$GATE" --suite "$WORK/b-mutskip.sh" --line 3)
assert_eq       "§2 a skipped MUTANT is REFUSED (exit 3)"          "${r%%|*}" "3"
assert_contains "§2 …stating the mutant declined to run"           "${r#*|}"  "MUTANT SKIPPED (rc 77). It did not run"
assert_contains "§2 …and reporting the baseline that DID run"      "${r#*|}"  "The baseline ran (rc 0, 1 assertions)"
assert_not_contains "§2 …never as a kill: a mutation that DISABLED the suite is not one it detected" \
                                                                   "${r#*|}"  "killed-unattributable"

# ── §2b  ENVSKIP (rc 69) IS REFUSED WITH ITS OWN DIAGNOSIS, AT BOTH ARMS ──
#
# your-org/nexus-code#1337 / #1283. `MG_SKIP_RCS` learned `69`; MUTANT 4 below
# proves only that the DEFAULT LINE is where the test says it is (its failure
# shape when un-taught is "m4 anchor missing", a harness fault, never "a 69
# was misclassified"). This section drives a suite that really exits 69 through
# the REAL tool, at each of the two consulting arms, and asserts the DIAGNOSIS.
#
# The reddening control is the un-taught tool itself, reached WITHOUT editing
# the file: `MG_SKIP_RCS=77` is the pre-#1337 default, and under it the same
# two drives produce exactly the strings the taught assertions forbid — the
# baseline is MISDIAGNOSED as "not green" (a red it should fix, when it should
# run elsewhere) and the mutant is scored `killed-unattributable`, i.e. a
# mutation that DISABLED the suite counted as one the suite DETECTED (#1280's
# defect, reproduced for the newer status).
echo '=== §2b rc 69 (ENVSKIP) is refused as ENVSKIP at both arms, never as red or as a kill ==='
# G — declines at rc 69 unmutated: the suite RAN and found the machine unable
# to build its fixture. Hermetic: the variable is one this fixture owns.
cat > "$WORK/g-envskip.sh" <<'FIXG'
#!/usr/bin/env bash
set -uo pipefail
HAVE_FIXTURE=0
[ "${HAVE_FIXTURE:-0}" = 1 ] || { echo "ENV-FAIL: g-envskip — the fixture could not be built on this machine"; exit 69; }
P=0
assert_eq() { if [ "$2" = "$3" ]; then P=$((P+1)); echo "  PASS: $1"; else echo "  FAIL: $1"; exit 1; fi; }
assert_eq "eta" e e
echo "=== summary: $P passed, 0 failed ==="
FIXG
# H — green unmutated; deleting line 3 steers it onto its OWN rc-69 path.
# `${HAVE_FIXTURE:-0}` rather than `$HAVE_FIXTURE`: under `set -u` a deleted
# assignment would otherwise be an unbound-variable rc 1, which is a RED, not
# the decline this fixture exists to produce.
sed 's/^HAVE_FIXTURE=0$/HAVE_FIXTURE=1/; s/g-envskip/h-mutenv/' "$WORK/g-envskip.sh" > "$WORK/h-mutenv.sh"
chmod +x "$WORK/g-envskip.sh" "$WORK/h-mutenv.sh"
bash "$WORK/g-envskip.sh" </dev/null >/dev/null 2>&1; assert_eq "fixture G declines bare (rc 69)" "$?" "69"
bash "$WORK/h-mutenv.sh"  </dev/null >/dev/null 2>&1; assert_eq "fixture H is green bare (rc 0)"  "$?" "0"

r=$(run "$GATE" --suite "$WORK/g-envskip.sh" --line 7)
assert_eq           "§2b baseline rc 69 is REFUSED (exit 3)"                      "${r%%|*}" "3"
assert_contains     "§2b …as a SKIP that did not run"                             "${r#*|}"  "SKIPPED (rc 69). It did not run"
assert_contains     "§2b …named ENVSKIP, distinct from the gate"                  "${r#*|}"  "rc 69 is ENVSKIP"
assert_not_contains "§2b …and NOT misdiagnosed as a red baseline"                 "${r#*|}"  "is not green"
assert_not_contains "§2b …and NOT handed the gate remedy, which cannot apply"     "${r#*|}"  "SLOW_TESTS=1"

r=$(run "$GATE" --suite "$WORK/h-mutenv.sh" --line 3)
assert_eq           "§2b mutant rc 69 is REFUSED (exit 3)"                        "${r%%|*}" "3"
assert_contains     "§2b …as a MUTANT that did not run"                           "${r#*|}"  "MUTANT SKIPPED (rc 69)"
assert_contains     "§2b …named ENVSKIP at the mutant arm too"                    "${r#*|}"  "rc 69 is ENVSKIP"
assert_not_contains "§2b …never as a kill: a mutation that DISABLED the suite is not one it detected" \
                                                                                  "${r#*|}"  "killed-unattributable"
assert_not_contains "§2b …and NOT handed the gate-precondition advice"            "${r#*|}"  "feeds a precondition the suite gates itself on"

# REDDENING CONTROL — the un-taught tool, by its own variable, no file edit.
r=$(MG_SKIP_RCS=77 run "$GATE" --suite "$WORK/g-envskip.sh" --line 7)
assert_contains     "§2b CONTROL un-taught (MG_SKIP_RCS=77): the 69 baseline IS misdiagnosed as not green" \
                                                                                  "${r#*|}"  "is not green (rc 69)"
r=$(MG_SKIP_RCS=77 run "$GATE" --suite "$WORK/h-mutenv.sh" --line 3)
assert_eq           "§2b CONTROL un-taught: the 69 mutant IS rendered a verdict (exit 5)" "${r%%|*}" "5"
assert_contains     "§2b CONTROL un-taught: …killed-unattributable — coverage manufactured from an absence" \
                                                                                  "${r#*|}"  "killed-unattributable (rc 69"

# ── §3  INDISTINGUISHABLE ARMS — THE STATUS-AGNOSTIC CONDITION ──────────
echo '=== §3 same rc, no declared total on either side: no verdict is supportable ==='
r=$(run "$GATE" --suite "$WORK/c-indist.sh" --line 3)
assert_eq       "§3 indistinguishable arms are REFUSED (exit 3)"   "${r%%|*}" "3"
assert_contains "§3 …naming what makes them indistinguishable"     "${r#*|}"  "INDISTINGUISHABLE"
assert_not_contains "§3 …and NOT reported as survived, which is what the pre-fix tool said" \
                                                                   "${r#*|}"  "VERDICT: survived"
# The condition names no status. Proven by driving it at rc 0/rc 0, where 77
# is nowhere in play: a reader could otherwise take §3 for a second spelling
# of §1.
assert_not_contains "§3 …and the refusal is not about rc 77 at all"  "${r#*|}"  "rc 77"

# ── §4  POSITIVE CONTROLS — the gate still reaches BOTH real verdicts ───
#
# Each of these BUILDS the input, RUNS the gate, and observes it REACT. A
# control that merely inspected the source for the new arms would pass against
# a tool in which they were unreachable — three inert controls of exactly that
# shape were found on this board, one in a test named `is_POTENT`.
echo '=== §4 the fix is not "refuse everything": both verdicts are still reachable ==='
r=$(run "$GATE" --suite "$WORK/d-guarded.sh" --line 5 --timeout 30 --cap-kb 1024)
assert_eq       "§4a a count-guarded suite still yields a KILL (exit 0)" "${r%%|*}" "0"
assert_contains "§4a …attributed, not bare"                              "${r#*|}"  "killed-by-assertion"
r=$(run "$GATE" --suite "$WORK/e-unguarded.sh" --line 5 --timeout 30 --cap-kb 1024)
assert_eq       "§4b the same mutation still SURVIVES an unguarded suite (exit 4)" "${r%%|*}" "4"
assert_contains "§4b …reported as survived"                                        "${r#*|}"  "VERDICT: survived"
# §4c THE BOUNDARY BETWEEN §3 AND §4b, which is the only thing stopping §3
# from having eaten a legitimate verdict. E and C differ in ONE property —
# whether the suite declares a total — and they must land on opposite sides.
assert_contains "§4c fixture E declares a total (the property that separates it from C)" \
    "$(bash "$WORK/e-unguarded.sh" </dev/null 2>&1)" "=== summary:"

# ── §5  MUTANTS — EACH ARM MUST BE ABLE TO FAIL ─────────────────────────
#
# STANDING FORM: APPLIED-TO-THE-REGION + PARSES + REACHED, then the assertion
# must FLIP. `monitor/mutation-gate.sh` sources nothing, so a copy in $WORK is
# the whole program and runs unmodified.
#
# APPLIED-TO-THE-REGION, not merely to the file: an inert mutant and a real
# surviving one produce byte-identical output, and "the bytes differ" is
# satisfied by a mutation that landed somewhere harmless. Each mutant below
# proves a diff hunk COVERS the original line of its own anchor.
echo '=== §5 mutants: revert each arm in situ and require the assertion to flip ==='

_anchor_line() { grep -n -m1 -F -- "$1" "$GATE" | cut -d: -f1; }

# _diff_covers <mutant> <original-line> -> yes|no
# Reads unified-diff hunk headers. `@@ -12,5 +12,0 @@` -> old range starts at
# 12 and spans 5; a span of 0 means an insertion BETWEEN 12 and 13.
_diff_covers() {
    diff --unified=0 -- "$GATE" "$1" | awk -v L="$2" '
        /^@@ / { split($2, a, ","); s = -a[1]; n = (a[2] == "" ? 1 : a[2])
                 if (n == 0) { if (L == s || L == s + 1) hit = 1 }
                 else if (L >= s && L < s + n) hit = 1 }
        END { print (hit ? "yes" : "no") }'
}

_mutate() {   # <mode> <dst>
    python3 - "$GATE" "$2" "$1" <<'PYMUT'
import sys
src, dst, mode = sys.argv[1], sys.argv[2], sys.argv[3]
# EXPLICIT ENCODING, BOTH WAYS. This suite exports `LC_ALL=C`, which makes
# Python 3.6 pick ASCII as the default file encoding — and `mutation-gate.sh`
# is UTF-8. Without these the read dies with a UnicodeDecodeError, which is at
# least LOUD; a silent transcoding on the WRITE side would be a mutant that
# differs from the original in bytes nobody intended, i.e. an APPLIED proof
# passing for the wrong reason.
s = open(src, encoding="utf-8").read()

BASE_SKIP  = 'if mg_is_skip "$base_rc"; then'
BASE_GREEN = 'if [ "$base_rc" -ne 0 ]; then'
PREFIX_OLD = 'if [ "$base_rc" -ne 0 ] && [ "$base_rc" -ne 77 ]; then'
MUT_SKIP   = 'if mg_is_skip "$mut_rc"; then'
INDIST     = "if [ \"$mut_rc\" -eq \"$base_rc\" ] && [ \"$base_assert\" = '?' ] && [ \"$mut_assert\" = '?' ]; then"
SURVIVED   = 'if [ "$mut_rc" -eq 0 ]; then'
END        = "\nfi\n"

def block(text, start):
    i = text.index(start)
    return i, text.index(END, i) + len(END)

if mode == "m1":            # restore the pre-#1280 baseline arm verbatim
    i = s.index(BASE_SKIP)
    j = s.index(BASE_GREEN) + len(BASE_GREEN)
    s = s[:i] + PREFIX_OLD + s[j:]
elif mode == "m2":          # delete the mutant-skip arm
    i, j = block(s, MUT_SKIP); s = s[:i] + s[j:]
elif mode == "m3":          # delete the indistinguishable-arms condition
    i, j = block(s, INDIST); s = s[:i] + s[j:]
elif mode == "m6":          # the FULL pre-#1280 state: all three arms gone
    i = s.index(BASE_SKIP); j = s.index(BASE_GREEN) + len(BASE_GREEN)
    s = s[:i] + PREFIX_OLD + s[j:]
    i, j = block(s, MUT_SKIP); s = s[:i] + s[j:]
    i, j = block(s, INDIST);  s = s[:i] + s[j:]
elif mode == "m4":          # CHANGE A VALUE rather than deleting anything
    old = 'MG_SKIP_RCS="${MG_SKIP_RCS:-77 69}"'
    assert old in s, "m4 anchor missing"
    s = s.replace(old, 'MG_SKIP_RCS="${MG_SKIP_RCS:-78}"', 1)
elif mode == "m5":          # MOVE the condition below the verdict it guards
    i, j = block(s, INDIST); blk = s[i:j]; s = s[:i] + s[j:]
    k = s.index(SURVIVED); k = s.index(END, k) + len(END)
    s = s[:k] + blk + s[k:]
else:
    sys.exit(2)
open(dst, "w", encoding="utf-8").write(s)
PYMUT
}

# _check_mutant <mode> <label> <anchor-text> -> sets $M to the mutant path
M=""
_check_mutant() {
    local mode="$1" label="$2" anchor="$3" ln differs parses
    M="$WORK/gate-$mode.sh"
    _mutate "$mode" "$M"; assert_eq "$label: the patch program succeeded" "$?" "0"
    chmod +x "$M"
    differs=no; cmp -s "$GATE" "$M" || differs=yes
    assert_eq "$label: content differs (APPLIED)" "$differs" "yes"
    ln=$(_anchor_line "$anchor")
    assert_eq "$label: a diff hunk covers the anchor line $ln (APPLIED TO THE REGION)" \
        "$(_diff_covers "$M" "${ln:-0}")" "yes"
    bash -n "$M" 2>/dev/null; parses=$?
    assert_eq "$label: the mutant PARSES" "$parses" "0"
}

# --- MUTANT 1: the pre-#1280 baseline arm, restored verbatim -------------
_check_mutant m1 "MUTANT 1" 'if mg_is_skip "$base_rc"; then'
assert_contains "MUTANT 1: the pre-fix condition is really in it" \
    "$(cat "$M")" '[ "$base_rc" -ne 77 ]'
# RUN-PROOF: the replaced region must SPEAK. A red baseline reaches the very
# line the mutation rewrote, and its message is the pre-fix one.
r=$(run "$M" --suite "$WORK/f-red.sh" --line 5)
assert_contains "MUTANT 1 RUN-PROOF: the mutated line executes and speaks" \
    "${r#*|}" "the UNMUTATED suite is not green"
# …and only now is the flip evidence rather than an absence.
#
# THE FLIP IS A CHANGE OF ARM, NOT A CHANGE OF EXIT CODE — measured, and the
# first draft of this assertion asserted rc 5 and was WRONG. Reverting the
# baseline arm alone does not reopen `#1280`, because the MUTANT arm catches
# the same 77 one layer down. That is the layered design doing its job, and
# recording it as a rc-5 flip would have been a claim the run refuses.
# What must change is WHICH arm speaks, and it does.
r=$(run "$M" --suite "$WORK/a-skip.sh" --line 10)
assert_eq       "MUTANT 1 FLIP: the BASELINE arm no longer speaks"       "${r%%|*}" "3"
assert_contains "MUTANT 1 FLIP: …the refusal falls through to the MUTANT arm" \
                "${r#*|}" "MUTANT SKIPPED (rc 77)"
assert_not_contains "MUTANT 1 FLIP: …and the baseline diagnostic is GONE" \
                "${r#*|}" "UNMUTATED suite SKIPPED"

# --- MUTANT 2: delete the mutant-skip arm -------------------------------
_check_mutant m2 "MUTANT 2" 'if mg_is_skip "$mut_rc"; then'
# RUN-PROOF for a DELETION: the removed code cannot speak, so prove control
# flow reaches PAST where it stood — a full verdict at the arm below it.
r=$(run "$M" --suite "$WORK/d-guarded.sh" --line 5 --timeout 30 --cap-kb 1024)
assert_eq "MUTANT 2 RUN-PROOF: control reaches the verdict arms below the deletion" "${r%%|*}" "0"
r=$(run "$M" --suite "$WORK/b-mutskip.sh" --line 3)
assert_eq       "MUTANT 2 FLIP: §2's refusal becomes a KILL (exit 5)" "${r%%|*}" "5"
assert_contains "MUTANT 2 FLIP: …a disabled suite scored as a detection" \
                                                                      "${r#*|}"  "killed-unattributable (rc 77"

# --- MUTANT 3: delete the indistinguishable-arms condition --------------
_check_mutant m3 "MUTANT 3" "if [ \"\$mut_rc\" -eq \"\$base_rc\" ] && [ \"\$base_assert\" = '?' ]"
r=$(run "$M" --suite "$WORK/d-guarded.sh" --line 5 --timeout 30 --cap-kb 1024)
assert_eq "MUTANT 3 RUN-PROOF: control reaches the verdict arms below the deletion" "${r%%|*}" "0"
r=$(run "$M" --suite "$WORK/c-indist.sh" --line 3)
assert_eq       "MUTANT 3 FLIP: §3's refusal becomes SURVIVED (exit 4)" "${r%%|*}" "4"
assert_contains "MUTANT 3 FLIP: …coverage manufactured from an absence"  "${r#*|}"  "VERDICT: survived"

# --- MUTANT 4: CHANGE A VALUE (the MG_SKIP_RCS default -> 78) -----------
# ANCHOR RE-PINNED (your-org/nexus-code#1283). The default widened from `77` to
# `77 69` when the tool learned the ENVSKIP code, and this mutant anchors on the
# LITERAL default line — so the anchor moved with it. The mutation's PURPOSE is
# unchanged: change the value, prove the tool notices. Worth a line because a
# mutant whose anchor no longer matches does not fail as "the tool missed it" —
# it fails as "the patch program succeeded: got 1, want 0", which reads like a
# harness fault rather than a stale anchor.
# An attack the finding did not use. Deleting an arm is the obvious mutation;
# a wrong CONSTANT leaves every arm present, every comment true, and the guard
# inert — and it is what a careless edit to the status list would produce.
_check_mutant m4 "MUTANT 4" 'MG_SKIP_RCS="${MG_SKIP_RCS:-77 69}"'
assert_contains "MUTANT 4: the value really changed" "$(cat "$M")" 'MG_SKIP_RCS:-78'
r=$(run "$M" --suite "$WORK/f-red.sh" --line 5)
assert_contains "MUTANT 4 RUN-PROOF: the gate still runs end to end" \
    "${r#*|}" "the UNMUTATED suite is not green"
#
# THE RESULT IS THE POINT, AND IT IS NOT THE ONE PREDICTED — TWICE. Blanking
# the status list disables BOTH skip arms at once, so `#1280` looks certain to
# reopen at rc 5. It does not, and the layer that catches it is not the one
# predicted either: the first draft of this assertion said the STATUS-AGNOSTIC
# condition (2) would, and measured, it is the plain NOT-GREEN baseline arm —
# reachable only because removing the `-ne 77` exception is itself part of the
# fix. Recorded as measured. Two wrong predictions in one mutant is the reason
# a mutant is RUN rather than reasoned about, and the reason this assertion
# reads the DIAGNOSTIC and not just the rc: three different arms all exit 3,
# so an rc-only assertion could not tell which one spoke.
r=$(run "$M" --suite "$WORK/a-skip.sh" --line 10)
assert_eq       "MUTANT 4 FLIP: a wrong status list disables both skip arms (still refused)" "${r%%|*}" "3"
assert_contains "MUTANT 4 FLIP: …and the plain NOT-GREEN baseline arm catches it" \
                "${r#*|}" "the UNMUTATED suite is not green (rc 77)"
assert_not_contains "MUTANT 4 FLIP: …no skip arm fires at all" \
                "${r#*|}" "SKIPPED (rc 77)"

# …and the arm MUTANT 4 lands on must actually SHOW the lines it promises.
# `tail -5 a b` is REJECTED outright when more than one file is named, so this
# refusal printed a "Last lines:" header and nothing under it, every time it
# fired. A guard on the HEADER alone would still pass; this asserts CONTENT
# from the capture. Found by driving this arm from MUTANT 4.
r=$(run "$M" --suite "$WORK/f-red.sh" --line 5)
assert_contains "MUTANT 4: the not-green refusal really prints its Last lines" \
                "${r#*|}" "FAIL: zeta"
assert_not_contains "MUTANT 4: …and tail does not reject its own arguments" \
                "${r#*|}" "option used in invalid context"

# --- MUTANT 5: MOVE the condition below the verdict it guards -----------
# The second attack the finding did not use, and the one this repo has a name
# for: `#1121`, a sound arm made unreachable by a permissive arm above it.
# Every line of the fix is still present and still correct in isolation.
_check_mutant m5 "MUTANT 5" "if [ \"\$mut_rc\" -eq \"\$base_rc\" ] && [ \"\$base_assert\" = '?' ]"
assert_contains "MUTANT 5: the moved block is still present in the file" \
    "$(cat "$M")" "INDISTINGUISHABLE"
r=$(run "$M" --suite "$WORK/d-guarded.sh" --line 5 --timeout 30 --cap-kb 1024)
assert_eq "MUTANT 5 RUN-PROOF: the gate still reaches a real verdict" "${r%%|*}" "0"
r=$(run "$M" --suite "$WORK/c-indist.sh" --line 3)
assert_eq       "MUTANT 5 FLIP: shadowed by the survived arm above it (exit 4)" "${r%%|*}" "4"
assert_contains "MUTANT 5 FLIP: …present, correct, and unreachable"             "${r#*|}"  "VERDICT: survived"

# --- MUTANT 6: the FULL pre-#1280 state --------------------------------
# MUTANTS 1-5 each disable ONE layer, and each is caught by another — which is
# the design working and is NOT proof that the fix closes the reported defect.
# Only removing all three arms at once can reproduce `#1280`, and if that did
# not restore the exact reported string, this whole file would be guarding
# something other than the thing that was filed.
_check_mutant m6 "MUTANT 6" 'if mg_is_skip "$base_rc"; then'
assert_not_contains "MUTANT 6: the mutant-skip arm is gone too" "$(cat "$M")" 'mg_is_skip "$mut_rc"'
assert_not_contains "MUTANT 6: …and so is the indistinguishable condition" "$(cat "$M")" "INDISTINGUISHABLE"
r=$(run "$M" --suite "$WORK/f-red.sh" --line 5)
assert_contains "MUTANT 6 RUN-PROOF: the mutated baseline arm executes and speaks"     "${r#*|}" "the UNMUTATED suite is not green"
r=$(run "$M" --suite "$WORK/a-skip.sh" --line 10)
assert_eq       "MUTANT 6 FLIP: #1280 reopens — a KILL for a suite that never ran (exit 5)"                                                                     "${r%%|*}" "5"
assert_contains "MUTANT 6 FLIP: …reproducing the filed string verbatim"                                                                          "${r#*|}"  "killed-unattributable (rc 77, no witness)"
assert_contains "MUTANT 6 FLIP: …and the tell the tool printed and did not act on"                                                                     "${r#*|}"  "declared assertions=? (baseline ?)"
# The OTHER direction reopens too, and it is the one the finding never had.
r=$(run "$M" --suite "$WORK/c-indist.sh" --line 3)
assert_eq       "MUTANT 6 FLIP: …and the SURVIVED direction reopens (exit 4)" "${r%%|*}" "4"

# POTENCY CONTROL FOR THE MEASURING INSTRUMENT ITSELF. `_diff_covers` decides
# every APPLIED-TO-THE-REGION assertion above; a version that answered `yes`
# unconditionally would certify all five mutants without reading anything.
# Driven against a line no mutant touches.
assert_eq "POTENCY: _diff_covers says NO for a line no mutant touches" \
    "$(_diff_covers "$WORK/gate-m4.sh" 1)" "no"
assert_eq "POTENCY: …and YES for the line MUTANT 4 changed" \
    "$(_diff_covers "$WORK/gate-m4.sh" "$(_anchor_line 'MG_SKIP_RCS="${MG_SKIP_RCS:-77 69}"')")" "yes"

# ── §6  THE TOOL DOCUMENTS ITS OWN REFUSALS ─────────────────────────────
# A refusal a caller cannot recognise from `--help` is a refusal they will
# read as a failure of their suite. Cheap, and it is how the exit-code
# contract stops drifting from the code.
echo '=== §6 the refusal is in the documented exit-code contract ==='
_help=$("$GATE" --help 2>&1 || true)
assert_contains "§6 --help names the skip refusal"            "$_help" "SKIPPED"
assert_contains "§6 --help names the indistinguishable case"  "$_help" "indistinguishable"

# ASSERTION CENSUS — the exact-count guard. A vanished assertion reddens here
# rather than shrinking the total in silence (your-org/nexus-code#807), which
# is this file's own subject applied to this file.
_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
if [[ "$_total" == "$EXPECTED_ASSERTIONS" ]]; then
    printf '  PASS: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS" >&2; _th_fail
fi

th_summary_and_exit
