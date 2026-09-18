#!/usr/bin/env bash
# test-slow-band-envskip.sh — the ENV-decline / gate-did-not-take seam
# (your-org/nexus-code#1283), driven END TO END rather than in the checker's
# own --selftest.
#
# WHY A SECOND SUITE WHEN slow-band-drift.sh ALREADY SELF-TESTS. The selftest
# feeds HAND-WRITTEN ledgers to `check`, so it proves the CLASSIFIER and nothing
# about the LEDGER. The whole of #1283 is a claim about what the runner actually
# WRITES — that a suite whose gate did not take and a suite that ran, asserted
# and then declined produce the SAME row — and a hand-written fixture can
# neither confirm nor refute that. So this suite builds real fixture suites,
# runs the REAL monitor/watcher/run-tests.sh over them, and adjudicates the REAL
# ledger with the REAL monitor/slow-band-drift.sh.
#
# THIS SUITE'S OWN HISTORY IS THE POINT OF SECTION 2. An earlier draft asserted
# the fix by REWRITING the ledger with `sed` — turning a SKIP row into an
# ENVSKIP row by hand — because at that time nothing could produce one. That
# proves the consumer against a FORGED artefact and says nothing about the
# producer, which is the half #1283 actually needs. Every ENVSKIP row below is
# now written by the real runner from a fixture that really exits 69. The only
# hand-built ledgers left are in section 3, whose job is to record what the
# tree did BEFORE the fix.
#
# WHY THIS FILE NEVER SPELLS THE BAND'S GATE VARIABLE — INCLUDING IN PROSE.
# The rule binds the COMMENTS too, and this file broke it once: a comment added
# to explain the hermeticity fix below quoted the variable literally, and that
# one mention enrolled this fast hermetic suite into the BLOCKING slow band.
# Caught by the negative control in the band-membership check, not by review.
# Say "the SLOW env" in prose; build the token at runtime in code. The SLOW band's
# membership is `grep -l '<gate>' monitor/watcher/test-*.sh` — a predicate over
# the FILE'S TEXT, not over its behaviour — so a suite joins the blocking band
# by MENTIONING the variable in a comment. This file is fast and hermetic and
# does not belong there, so it builds the token at runtime instead of
# containing it.
#
# Run: bash monitor/watcher/test-slow-band-envskip.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
REPO_ROOT=$(cd "$MON_DIR/.." && pwd)
DRIFT="$MON_DIR/slow-band-drift.sh"
RUNNER="$MON_DIR/watcher/run-tests.sh"
# Built, never written literally — see the header. `grep -l` over this file must
# NOT match, or this suite silently joins the blocking SLOW band.
GATE="SLOW""_TESTS"

for f in "$DRIFT" "$RUNNER"; do
    [[ -r "$f" ]] || th_abort "missing prerequisite: $f"
done

WORK=$(mktemp -d -t nexus-slowband-envskip-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
FX="$WORK/fx"; mkdir -p "$FX"

# ── fixtures ──────────────────────────────────────────────────────────
# (1) GATE-DID-NOT-TAKE: the band's variable is not 1, so the suite leaves the
#     band having run NOTHING. #1283 is emphatic that this must stay loud.
cat > "$FX/test-fx-gate-skip.sh" <<EOF
#!/usr/bin/env bash
if [[ "\${$GATE:-0}" != "1" ]]; then
  echo "skipped: this scenario needs the band gate (set $GATE=1 to run)"
  exit 77
fi
echo "  PASS: the gated work"
echo "ALL TESTS PASSED (1 assertions)"
EOF
# (2) ENV DECLINE: the suite RAN, banked assertions, then measured the machine
#     unable to build the rest of its fixture. Opposite situation; under the
#     fix, a DIFFERENT exit code and therefore a different row.
cat > "$FX/test-fx-env-decline.sh" <<'EOF'
#!/usr/bin/env bash
echo "  PASS: preconditions readable"
echo "  PASS: fixture registry built"
echo "=== summary: 2 passed, 0 failed ==="
echo "ENV-INCONCLUSIVE: no loopback high port available on this machine — declining" >&2
exit 69
EOF
# (2b) The SAME suite as it behaved BEFORE the fix, for section 3's
#      before/after. Identical but for the exit code, so the row difference
#      section 4 measures is attributable to the code and to nothing else.
sed 's/^exit 69$/exit 77/' "$FX/test-fx-env-decline.sh" > "$FX/test-fx-env-decline-old.sh"
cat > "$FX/test-fx-plain-pass.sh" <<'EOF'
#!/usr/bin/env bash
echo "  PASS: a"
echo "ALL TESTS PASSED (1 assertions)"
EOF
cat > "$FX/test-fx-plain-fail.sh" <<'EOF'
#!/usr/bin/env bash
echo "  FAIL: a"
echo "=== summary: 0 passed, 1 failed ==="
exit 1
EOF
chmod +x "$FX"/*.sh

# `env -u NEXUS_ROOT -u NEXUS_LOCALS` exactly as tests-slow-integration.yml
# invokes it: an inherited NEXUS_ROOT re-roots the runner's state onto the
# operator's live tree.
_run_band() {  # _run_band <ledger> <runner> <fixture>...
    local _ledger="$1" _runner="$2"; shift 2
    # `</dev/null` is NOT decoration: a runner inheriting this suite's stdin
    # can block indefinitely, and the failure arrives as a hang rather than an
    # error. The band's own CI invocation closes stdin for the same reason.
    #
    # `-u "$GATE"` IS THE HERMETICITY FIX, AND IT WAS A MEASURED RED, not a
    # precaution. The gate fixture models "the band gate did not take" by
    # reading the REAL band variable — so with that variable set in the ambient
    # environment the fixture RUNS instead of declining, exits 0, and is
    # recorded PASS. This suite scored 37/0 bare and 31/6 under
    # the SLOW env for exactly that reason: a fixture
    # inheriting its own premise from whoever happened to invoke it. Six
    # assertions went red, including the CONTROL that is supposed to establish
    # the probe can see a difference — which is the tell, because a control
    # failing means the instrument is wrong, not the subject.
    #
    # Unsetting it makes the fixture's branch a property of THIS SUITE rather
    # than of the operator's shell. Note the direction: without this the suite
    # is red in the SLOW environment, i.e. LOUD. Had the ambient dependency
    # pushed the other way it would have been a silent green, and nothing here
    # would have found it.
    env -u NEXUS_ROOT -u NEXUS_LOCALS -u "$GATE" bash "$_runner" --state "$_ledger" "$@" \
        </dev/null >"$_ledger.out" 2>&1
}
_row() {  # _row <ledger> <fixture-basename> -> status|caseskips|assertions
    awk -F'\t' -v p="$FX/$2" '$1==p{print $2"|"$4"|"$5}' "$1"
}

LEDGER="$WORK/ledger.tsv"
_run_band "$LEDGER" "$RUNNER" \
    "$FX/test-fx-gate-skip.sh" "$FX/test-fx-env-decline.sh" "$FX/test-fx-plain-pass.sh"
_runner_rc=$?

echo "== 1. the runner produced a ledger at all (else every absence below is a false zero) =="
assert_file_exists "run-tests.sh wrote the --state ledger" "$LEDGER"
_rows=$(command grep -c . "$LEDGER" 2>/dev/null; true)
assert_eq "ledger has one row per selected fixture" "$_rows" "3"
if (( _rows != 3 )); then
    printf '  runner rc=%s; output follows:\n' "$_runner_rc" >&2
    sed 's/^/    | /' "$LEDGER.out" >&2
fi

echo "== 2. WHY A DECLARED CODE: the assertion-count discriminator is INERT =="
# #1283 proposes telling the two apart by assertion count: "a self-skip never
# runs an assertion, whereas an ENV decline has a non-zero assertion count".
# Field 5 of the ledger IS that count — and it is `?` on EVERY non-PASS row,
# because run_one computes it only for PASS/FAIL and then forces it to `?`
# afterwards, in two independent places. So the discriminator is not merely
# absent from the checker; it is absent from the ARTEFACT, and no change
# confined to slow-band-drift.sh could recover it. This is the measurement that
# justifies a DECLARED exit code over an inference — and it is asserted here so
# that anyone later tempted by the inference finds it already disproved.
_env_row=$(_row "$LEDGER" test-fx-env-decline.sh)
assert_eq "the ENV decline DID assert (2 passes in its own footer)" \
    "$(command grep -c 'summary: 2 passed' "$FX/test-fx-env-decline.sh"; true)" "1"
assert_eq "…yet the ledger's assertion column is '?' — the inference has no input" \
    "${_env_row##*|}" "?"

echo "== 3. THE DEFECT, REPRODUCED: two exit-77 suites are ONE row shape =="
# THE COLLISION IS MEASURED ON THE CURRENT RUNNER, NOT ON AN ARCHIVED ONE.
# An earlier draft `git show`-ed the base runner into a temp file and ran that.
# It does not work and the failure is instructive: run-tests.sh resolves its
# helpers relative to its OWN path, so a copy outside monitor/watcher/ writes
# no ledger at all — and "no ledger" is a false zero shaped exactly like "the
# old runner behaved differently". A worktree would fix it and would make this
# hermetic suite depend on git history and on a sha that ages.
#
# It is also unnecessary, because the defect is not historical. #1283 is the
# claim that GATE-DID-NOT-TAKE and an HONEST ENV DECLINE are indistinguishable
# WHEN BOTH USE EXIT 77 — and that is still true today, for any suite that has
# not adopted 69. `test-fx-env-decline-old.sh` is byte-identical to the fixed
# fixture but for its exit code, so the difference section 4 finds is
# attributable to the code and to nothing else.
_ledger_old="$WORK/ledger-old.tsv"
_run_band "$_ledger_old" "$RUNNER" \
    "$FX/test-fx-gate-skip.sh" "$FX/test-fx-env-decline-old.sh" "$FX/test-fx-plain-pass.sh"
assert_eq "the two fixtures differ ONLY in their exit code" \
    "$(diff "$FX/test-fx-env-decline.sh" "$FX/test-fx-env-decline-old.sh" | command grep -c '^[<>]'; true)" "2"
_o_gate=$(_row "$_ledger_old" test-fx-gate-skip.sh)
_o_env=$(_row "$_ledger_old" test-fx-env-decline-old.sh)
_o_pass=$(_row "$_ledger_old" test-fx-plain-pass.sh)
# POSITIVE CONTROL FIRST: a row we know differs must be SEEN to differ, or
# "these two are identical" is a claim the probe cannot support.
assert_eq "CONTROL: the probe CAN see a difference (the PASS row differs)" \
    "$([ "$_o_pass" != "$_o_gate" ] && echo differs || echo same)" "differs"
assert_eq "…and with that control passing, the two exit-77 rows are IDENTICAL" \
    "$_o_gate" "$_o_env"
# And that identical shape is what the band then reds, both rows alike.
printf '# empty tolerated set, as shipped\n' > "$WORK/known-empty.tsv"
_out0=$(bash "$DRIFT" "$_ledger_old" "$WORK/known-empty.tsv" 2>&1); _rc0=$?
assert_eq "…so a ledger of two 77s reds the band" "$_rc0" "1"
assert_contains "…naming the honest ENV decline as a NEW-RED" "$_out0" "test-fx-env-decline-old.sh"

echo "== 4. THE FIX: the runner itself now writes two different rows =="
_gate_row=$(_row "$LEDGER" test-fx-gate-skip.sh)
assert_eq "gate-did-not-take is STILL recorded SKIP"  "${_gate_row%%|*}" "SKIP"
assert_eq "an honest ENV decline is recorded ENVSKIP" "${_env_row%%|*}"  "ENVSKIP"
assert_eq "…and the two rows now differ" \
    "$([ "$_gate_row" != "$_env_row" ] && echo differs || echo same)" "differs"
# The runner must NOT go red for a machine's shortcoming — if it did, the band
# would red before the drift check ever ran and the token would buy nothing.
# THIS ASSERTION IS A LINK IN A CHAIN, and the chain is why rc 4 is reachable
# at all (raised by w215esk). The band step accepts ONLY `rc 0|1` from
# run-tests.sh — `case "$rc" in 0|1) ;; *) … exit 1` in
# tests-slow-integration.yml — so anything else fails the band step outright and
# the ledger is never handed to the verdict step. rc 4 therefore depends on an
# ENVSKIP keeping the RUNNER at 0: had it redded the runner, or produced some
# third code, the drift check would never run and #1283's fix would be inert for
# a SECOND, different reason. Do not relax this to "does not matter, the drift
# check decides" — the drift check only decides if this holds.
assert_eq "an ENVSKIP does not red the RUNNER" "$_runner_rc" "0"
assert_contains "…and the run SAYS how much produced no verdict" \
    "$(cat "$LEDGER.out")" "RAN AND DECLINED ON ENVIRONMENT GROUNDS"
assert_contains "…with the ENVSKIP counted SEPARATELY from SKIP in the ledger line" \
    "$(cat "$LEDGER.out")" "1 SKIP, 1 ENVSKIP"

echo "== 5. an ENVSKIP row cannot be accused by the false-pass family =="
# The `.vacuous`/`.falsepass`/`.zerocount` sidecars are written inside the PASS
# arm only, so a declining suite cannot be told it "printed a success banner
# having asserted nothing" (#1277) or declared "0 ASSERTIONS" (#1145). Worth
# pinning: a declining suite prints a lot on its way out, and these three gates
# are reds.
_o=$(cat "$LEDGER.out")
assert_not_contains "no #1277 false-pass accusation" "$_o" "false pass:"
assert_not_contains "no #1145 zero-assertion accusation" "$_o" "0 ASSERTIONS"

echo "== 6. the band's verdict: the gate SKIP stays NEW-RED, the ENV decline does not =="
_out2=$(bash "$DRIFT" "$LEDGER" "$WORK/known-empty.tsv" 2>&1); _rc2=$?
assert_eq "a gate-did-not-take SKIP is STILL rc1 alongside an ENVSKIP" "$_rc2" "1"
assert_contains "…still NEW-RED by name" "$_out2" "test-fx-gate-skip.sh"
assert_contains "and the ENV decline is reported as ENV-UNPROVEN" "$_out2" "ENV-UNPROVEN"
assert_not_contains "…and is NOT called a NEW-RED" \
    "$(printf '%s\n' "$_out2" | sed -n '/NEW-RED/,/^$/p')" "test-fx-env-decline.sh"

echo "== 7. an ENV decline ALONE is rc4 — not a clearance, not a regression =="
_ledger_env="$WORK/ledger-envonly.tsv"
_run_band "$_ledger_env" "$RUNNER" "$FX/test-fx-env-decline.sh" "$FX/test-fx-plain-pass.sh"
assert_eq "the env-only ledger has rows (else rc4 would be a refusal)" \
    "$(command grep -c . "$_ledger_env" 2>/dev/null; true)" "2"
_out3=$(bash "$DRIFT" "$_ledger_env" "$WORK/known-empty.tsv" 2>&1); _rc3=$?
assert_eq "ENVSKIP alone → rc 4" "$_rc3" "4"
assert_contains "…reported as ENV-UNPROVEN" "$_out3" "ENV-UNPROVEN"
assert_not_contains "…and NOT as a clean OK" "$_out3" "OK: every not-pass is tolerated"

echo "== 8. a REAL red still outranks it — an ENVSKIP cannot launder a FAIL =="
_ledger2="$WORK/ledger2.tsv"
_run_band "$_ledger2" "$RUNNER" "$FX/test-fx-plain-fail.sh" "$FX/test-fx-env-decline.sh"
assert_eq "second ledger written" "$(command grep -c . "$_ledger2" 2>/dev/null; true)" "2"
assert_eq "…and it really does carry an ENVSKIP (else this proves nothing)" \
    "$(awk -F'\t' '$2=="ENVSKIP"' "$_ledger2" | command grep -c . ; true)" "1"
_out4=$(bash "$DRIFT" "$_ledger2" "$WORK/known-empty.tsv" 2>&1); _rc4=$?
assert_eq "FAIL + ENVSKIP → rc 1, not rc 4" "$_rc4" "1"
assert_contains "the FAIL is still NEW-RED" "$_out4" "test-fx-plain-fail.sh"

echo "== 9. an ENVSKIP never CLEARS a toleration (it is not evidence of a pass) =="
printf '%s\t#1283\tenv-dependent scenario\n' "$FX/test-fx-env-decline.sh" > "$WORK/known-tol.tsv"
# REUSES section 7's ledger against a DIFFERENT tolerated set — the variable
# under test here is the toleration, not the ledger, and each `_run_band` costs
# ~30s of runner startup on this filesystem. The plain-PASS row it also carries
# is untolerated and green, so it cannot influence the verdict.
_out5=$(bash "$DRIFT" "$_ledger_env" "$WORK/known-tol.tsv" 2>&1); _rc5=$?
assert_eq "a TOLERATED test that ENVSKIPs → rc 4, not 0 and not 1" "$_rc5" "4"
assert_not_contains "…not STALE-TOLERATION (nothing was shown to pass)" "$_out5" "STALE-TOLERATION"
assert_not_contains "…and not UNACCOUNTED (it WAS run)"                 "$_out5" "UNACCOUNTED"
assert_contains "…it is reported, with the toleration named"            "$_out5" "#1283"

echo "== 10. MERGE ORDER IS FAIL-CLOSED: an UNLEARNED exit code is a FAIL =="
# The property that lets a consuming SUITE adopt `exit 69` before this runner
# change lands, without opening a hole. Stated GENERALLY and measured on the
# CURRENT runner rather than on an archived one: any exit code the runner has
# not been taught falls to the `rc != 0` range arm and becomes FAIL — red and
# attributable, never green. `exit 69` against a runner predating this change
# is one instance of that rule, which is why the rule is the thing worth
# pinning: it does not rot when the base sha does, and it also covers the next
# code somebody invents.
cat > "$FX/test-fx-unlearned.sh" <<'EOF'
#!/usr/bin/env bash
echo "  PASS: a"
echo "=== summary: 1 passed, 0 failed ==="
exit 70
EOF
chmod +x "$FX/test-fx-unlearned.sh"
_ledger4="$WORK/ledger4.tsv"
_run_band "$_ledger4" "$RUNNER" "$FX/test-fx-unlearned.sh"
_unlearned=$(_row "$_ledger4" test-fx-unlearned.sh)
assert_eq "an exit code the runner has NOT learned is FAIL — red, never green" \
    "${_unlearned%%|*}" "FAIL"
# CONTROL: the same runner, same shape of fixture, with the code it HAS learned.
# Without this, the assertion above would also pass if the runner failed
# everything indiscriminately.
assert_eq "CONTROL: the code it HAS learned is ENVSKIP, so 'FAIL' above is discriminating" \
    "$(_row "$_ledger_env" test-fx-env-decline.sh | cut -d'|' -f1)" "ENVSKIP"

echo "== 11. HERMETIC: the gate fixture declines whatever the ambient gate says =="
# Asserted rather than assumed, because the failure direction is environment-
# dependent and this suite is run in both. Sets the real band variable to 1 for
# the duration of one run: the gate fixture must STILL be recorded SKIP.
_ledger5="$WORK/ledger5.tsv"
# Exported in a SUBSHELL and routed through the real `_run_band`, so this
# exercises the actual code path rather than a hand-rolled imitation of it.
( export "$GATE=1"; _run_band "$_ledger5" "$RUNNER" "$FX/test-fx-gate-skip.sh" )
assert_eq "gate fixture is SKIP even with the band gate set in the environment" \
    "$(_row "$_ledger5" test-fx-gate-skip.sh | cut -d'|' -f1)" "SKIP"

echo "== 12. the checker's own selftest still passes (the classifier's controls) =="
bash "$DRIFT" --selftest >"$WORK/selftest.out" 2>&1
assert_rc "slow-band-drift.sh --selftest" "$?" "0"
assert_contains "…and it is not vacuous — the SKIP arm is still exercised" \
    "$(cat "$WORK/selftest.out")" "SKIP is not a pass"

# ── assertion-count guard ─────────────────────────────────────────────
# A suite whose assertions can vanish without the total moving is a green that
# means nothing — the class this whole change is about, pointed at itself. The
# dangerous direction is not zero (a zero is suspicious) but a SHORT count: an
# early `exit` or a `return` in a helper removes a section, every remaining
# assertion still passes, and the footer reads clean. Pinning the total makes
# that a red. Bump it deliberately when you add an assertion.
EXPECTED_ASSERTIONS=38
TOTAL_ASSERTIONS=$(( PASS + FAIL ))
if (( TOTAL_ASSERTIONS != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi

th_summary_and_exit
