#!/usr/bin/env bash
# Tests for the cc-harness gate's POPULATION rules —
# monitor/cc-harness/gate-coverage.sh + the refusal block in
# monitor/cc-harness/gate.sh (your-org/nexus-code#1268, #1261).
#
# TWO PROPERTIES, one defect class: a gate must never render a CLEARANCE over a
# population it did not establish.
#
#   #1268 — A VACUOUS POPULATION IS A REFUSAL. With zero scenarios the gate
#   printed `0 passed / 0 failed / 0 skipped (of 0)` and `GATE GREEN (0/0
#   passed) — candidate is safe to promote`, exit 0. That is the same
#   green-via-nothing-ran failure the gate was written against — its own header
#   cites a prior gate that "printed GREEN with every scenario skipped for lack
#   of node" — closed for `skipped` and left open for `empty`. The rule is
#   asserted at EVERY population this file computes, not only at the filed one:
#   a class fix that only covers the demonstrated repro is a fourth unguarded
#   site waiting to be found.
#
#   #1261 — A RATIO MUST CARRY ITS DENOMINATOR. `GATE GREEN (7/7)` is a tally
#   over a hardcoded list and it drives an automatic bump of the binary every
#   agent on the board runs. Measured on this tree it is 7 of 12 pane-state
#   states and 0 of 2 delivery transports, and `paste-followup.sh` — the
#   production delivery path — is driven by no scenario at all. The fix derives
#   both vocabularies (never hand-enumerates them), declares per-scenario
#   coverage, and RATCHETS: a scenario file that exists and is in neither the
#   gated nor the exempt set is a refusal.
#
# WHY THE ASSERTIONS ARE ON VALUES, NOT SHAPES. A `pane-state N/M covered` line
# that merely EXISTS satisfies a shape check while naming the wrong denominator,
# which is the defect rather than a fix for it. So M is re-derived here from
# `monitor/pane-state.sh --states`, the UNCOVERED set is re-derived from the
# manifest, and the two are required to partition the vocabulary exactly.
#
# MOSTLY HERMETIC. The unit bands drive gate-coverage.sh against planted
# fixtures through its documented injection points (GCOV_PANE_STATE_BIN,
# GCOV_HARNESS_DIR, GCOV_MANIFEST, GCOV_SCENARIO_DIR) — no claude binary, no
# node, no tmux, no network. The four end-to-end bands run the real gate.sh
# with /bin/bash standing in for the candidate (as test-cc-gate.sh does), which
# costs the two safety-lint selftests per invocation; they are kept to four for
# that reason and each one asserts something no unit call can.
#
# Run: bash monitor/watcher/test-cc-harness-gate-population.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
GCOV_LIB="$REPO_ROOT/monitor/cc-harness/gate-coverage.sh"
GATE="$REPO_ROOT/monitor/cc-harness/gate.sh"

# THE SHARED LEDGER, NOT A PRIVATE TALLY (your-org/nexus-code summary-honesty).
# A hand-rolled PASS/FAIL pair prints a green this repo's honesty manifest
# cannot see, so a suite that stopped running would announce success to a
# reader and nothing to the guard. `ok`/`bad` keep their call sites and their
# wording; they now record through `_th_pass`/`_th_fail` as well.
. "$_test_dir/_test_helpers.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; _th_pass; }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; _th_fail; }

[[ -r "$GCOV_LIB" ]] || { echo "missing: $GCOV_LIB" >&2; exit 1; }
[[ -r "$GATE"     ]] || { echo "missing: $GATE" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=../cc-harness/gate-coverage.sh
. "$GCOV_LIB"

CLAUDE_STUB=$(command -v bash)

# _first_line / _last_line — no `| head -n1`, no `| sed …q`. Both are
# EARLY-CLOSING readers: under `set -o pipefail` the writer's EPIPE can invert
# a pipeline's status, and monitor/watcher/early-exit-readers.sh enrols any
# file that contains one. Parameter expansion answers the same question with no
# pipe and no second process.
_first_line() { local v="$1"; printf '%s' "${v%%$'\n'*}"; }
_last_line()  { local v="$1"; printf '%s' "${v##*$'\n'}"; }


# ---------------------------------------------------------------------------
# Fixture world. Every population gate-coverage.sh computes is plantable, so
# each refusal arm can be driven WITHOUT breaking the real tree.
# ---------------------------------------------------------------------------
FX="$WORK/fx"
mkdir -p "$FX/harness" "$FX/scen" "$FX/empty-harness" "$FX/empty-scen"

# A pane-state stand-in whose vocabulary is chosen by the caller.
cat > "$FX/pane-states.sh" <<'EOS'
#!/usr/bin/env bash
[[ "${1:-}" == "--states" ]] || exit 2
printf '%s\n' ${FX_STATES:-idle busy blocked}
EOS
chmod +x "$FX/pane-states.sh"

# A vocabulary-EMPTY stand-in that still exits 0. This is the shape that
# matters: a tool that FAILS is loud, a tool that succeeds and says nothing is
# the silent zero, and "0/0 covered" would read as full coverage.
printf '#!/usr/bin/env bash\n[[ "${1:-}" == "--states" ]] || exit 2\nexit 0\n' > "$FX/pane-states-empty.sh"
chmod +x "$FX/pane-states-empty.sh"

# Delivery adapters, in the adapters' own TSV shape (name<TAB>kind<TAB>receipt<TAB>stamps).
printf '#!/usr/bin/env bash\n[[ "${1:-}" == "transports" ]] || exit 2\nprintf "wire-a\\tshell\\tnone\\tself\\n"\n' > "$FX/harness/a.sh"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == "transports" ]] || exit 2\nprintf "wire-b\\tagent\\tnone\\tcaller\\n"\n' > "$FX/harness/b.sh"
chmod +x "$FX/harness/a.sh" "$FX/harness/b.sh"

mk_scen() {  # $1 = basename, remaining = tokens to embed
    local p="$FX/scen/$1"; shift
    { printf '#!/usr/bin/env bash\n'; local t; for t in "$@"; do printf '# mentions %s\n' "$t"; done; } > "$p"
    chmod +x "$p"
}
mk_scen test-realmodel-alpha.sh idle busy wire-a
mk_scen test-realmodel-beta.sh  blocked

mk_manifest() {  # stdin = rows
    local p="$WORK/manifest-$RANDOM.tsv"
    { printf '# fixture manifest\n'; cat; } > "$p"
    printf '%s' "$p"
}

# run_gcov <manifest> <states> <harness-dir> <scen-dir> [prod-scenario-basenames...]
#   Sets GCOV_OUT and GCOV_RC in THIS shell.
#
# NOT `out=$(run_gcov ...)`. A command substitution is a SUBSHELL, so a
# `GCOV_RC=$?` inside the callee is written to a copy of the shell and
# discarded — the caller then reads the initialised 0 and every refusal arm
# below "passes" while asserting nothing about the return code. That is exactly
# the inert-control failure this suite exists to guard against, and it happened
# here on the first run: eleven cases reported rc=0 while the refusal text they
# were checking for was sitting in the very output they printed.
GCOV_RC=0
GCOV_OUT=""
run_gcov() {
    local mf="$1" states="$2" hdir="$3" sdir="$4"; shift 4
    local -a prod=()
    local b; for b in "$@"; do prod+=( "$sdir/$b" ); done
    GCOV_MANIFEST="$mf" GCOV_PANE_STATE_BIN="$states" \
        GCOV_HARNESS_DIR="$hdir" GCOV_SCENARIO_DIR="$sdir" \
        gcov_report ${prod[@]+"${prod[@]}"} > "$WORK/gcov.out" 2>&1
    GCOV_RC=$?
    GCOV_OUT=$(cat "$WORK/gcov.out")
}

# The healthy fixture manifest: both planted scenarios declared, claims true.
MF_OK=$(mk_manifest <<'EOM'
gated	test-realmodel-alpha.sh	idle,busy	wire-a	the base fixture
gated	test-realmodel-beta.sh	blocked	-	the second fixture
EOM
)

echo "=== band A: the vacuous-population rule (your-org/nexus-code#1268) ==="

# A1 (unit) — zero members is a refusal.
( gate_refuse_if_vacuous "probe" 0 >/dev/null 2>&1 ); rc=$?
if (( rc == 3 )); then ok "gate_refuse_if_vacuous: count=0 → REFUSED (rc 3)"
else bad "vacuous count=0" "rc=$rc, want 3"; fi

# A2 (POTENCY for A1) — the same call with a real population must NOT refuse,
# or A1 would pass for a rule that refuses everything.
( gate_refuse_if_vacuous "probe" 3 >/dev/null 2>&1 ); rc=$?
if (( rc == 0 )); then ok "POTENCY: count=3 → accepted (rc 0), so the refusal above is caused by emptiness"
else bad "vacuous potency" "rc=$rc on a non-empty population, want 0"; fi

# A3 — a count that is not a NUMBER is refused too, and is DISTINGUISHED from
# zero. This is the mutant the finding did not use: a VALUE change, not a
# deletion. "I could not count it" must not render as "it is fine" — the same
# distinction the gate already draws for lint=unknown.
out=$( gate_refuse_if_vacuous "probe" "unknown" 2>&1 ); rc=$?
if (( rc == 3 )) && grep -qF 'count=NOT-ESTABLISHED' <<<"$out" && ! grep -qF 'count=0' <<<"$out"; then
    ok "a non-numeric count → REFUSED and reported as NOT-ESTABLISHED, not as 0"
else bad "non-numeric count" "rc=$rc out=$out"; fi
out=$( gate_refuse_if_vacuous "probe" "" 2>&1 ); rc=$?
if (( rc == 3 )) && grep -qF 'count=NOT-ESTABLISHED' <<<"$out"; then
    ok "an EMPTY count → REFUSED as NOT-ESTABLISHED (an emptiness check is not a validity check)"
else bad "empty count" "rc=$rc out=$out"; fi

# A4 — THE CLASS, site 2: an empty pane-state vocabulary refuses rather than
# reporting 0/0 covered.
run_gcov "$MF_OK" "$FX/pane-states-empty.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qF 'pane_state_vocabulary_empty' <<<"$out" \
   && ! grep -qE 'pane-state 0/0 covered' <<<"$out"; then
    ok "CLASS site 2: an empty pane-state vocabulary → REFUSED, never '0/0 covered'"
else bad "empty pane-state vocabulary" "rc=$GCOV_RC out=$out"; fi

# A5 — THE CLASS, site 3: an empty delivery-transport vocabulary refuses.
run_gcov "$MF_OK" "$FX/pane-states.sh" "$FX/empty-harness" "$FX/scen" test-realmodel-alpha.sh; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qE 'delivery_vocabulary' <<<"$out"; then
    ok "CLASS site 3: no delivery adapter → REFUSED, never '0/0 covered'"
else bad "empty delivery vocabulary" "rc=$GCOV_RC out=$out"; fi

# A6 — THE CLASS, site 4: an empty on-disk scenario population refuses. The
# ratchet with nothing to ratchet is not the same as a ratchet with nothing to
# say, and it is the arm that would silently accept a mis-pointed directory.
run_gcov "$MF_OK" "$FX/pane-states.sh" "$FX/harness" "$FX/empty-scen"; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qF 'on-disk realmodel scenarios' <<<"$out"; then
    ok "CLASS site 4: no on-disk scenario file → REFUSED"
else bad "empty on-disk population" "rc=$GCOV_RC out=$out"; fi

# A7 (POTENCY for A4-A6) — the SAME call with every population healthy returns
# 0 and prints a report. Without this, A4-A6 would be satisfied by a gcov_report
# that refuses unconditionally.
run_gcov "$MF_OK" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 0 )) && grep -qE 'gate-coverage: pane-state [0-9]+/3 covered' <<<"$out"; then
    ok "POTENCY: all four populations healthy → rc 0 and a report (the refusals above are caused by emptiness)"
else bad "healthy-fixture potency" "rc=$GCOV_RC out=$out"; fi

echo
echo "=== band B: the coverage boundary is DERIVED and PARTITIONS its vocabulary ==="

# B1 — the denominator is the TOOL's vocabulary, re-derived here. A stale or
# hand-copied list would satisfy a shape check and fail this.
# FX_STATES must be EXPORTED: the stub is a separate process, and a bare
# `FX_STATES=... out=$(...)` is two ASSIGNMENTS rather than an env prefix, so
# the child never sees it and the stub falls back to its 3-state default —
# which looks exactly like a correct answer.
out=$( FX_STATES="idle busy blocked absent empty" \
       GCOV_MANIFEST="$MF_OK" GCOV_PANE_STATE_BIN="$FX/pane-states.sh" \
       GCOV_HARNESS_DIR="$FX/harness" GCOV_SCENARIO_DIR="$FX/scen" \
       gcov_report "$FX/scen/test-realmodel-alpha.sh" "$FX/scen/test-realmodel-beta.sh" 2>&1 )
denom=$(_last_line "$(sed -n 's/^=== gate-coverage: pane-state [0-9]*\/\([0-9]*\) covered ===$/\1/p' <<<"$out")")
if [[ "$denom" == "5" ]]; then
    ok "the pane-state denominator tracks the TOOL's vocabulary (5 states → /5, not the earlier /3)"
else bad "derived denominator" "got '$denom' want 5; out=$out"; fi

# B2 — covered and UNCOVERED PARTITION the vocabulary exactly. The declared set
# is {idle,busy,blocked}; the vocabulary adds {absent,empty}.
unc=$(_first_line "$(sed -n 's/^    UNCOVERED:  \(.*\)$/\1/p' <<<"$out")")
numer=$(_last_line "$(sed -n 's/^=== gate-coverage: pane-state \([0-9]*\)\/[0-9]* covered ===$/\1/p' <<<"$out")")
if [[ "$unc" == "absent empty" && "$numer" == "3" ]]; then
    ok "covered(3) + UNCOVERED(absent empty) partition the vocabulary exactly"
else bad "partition" "numer='$numer' uncovered='$unc'; out=$out"; fi

# B3 — the delivery vocabulary is asked of the ADAPTERS, and an undeclared
# transport shows up as a gap rather than vanishing from the denominator. The
# fixture declares wire-a only; the adapters declare wire-a and wire-b.
dl=$(_last_line "$(sed -n 's/^=== gate-coverage: delivery \([0-9]*\/[0-9]*\) covered ===$/\1/p' <<<"$out")")
dunc=$(_first_line "$(sed -n '/delivery .* covered/,$p' <<<"$out" | sed -n 's/^    UNCOVERED:  \(.*\)$/\1/p')")
if [[ "$dl" == "1/2" && "$dunc" == "wire-b" ]]; then
    ok "the delivery denominator comes from the adapters; the undriven transport is a NAMED gap (1/2, wire-b)"
else bad "delivery derivation" "dl='$dl' uncovered='$dunc'; out=$out"; fi

echo
echo "=== band C: the manifest may not out-run the tree (the ratchet) ==="

# C1 — THE RATCHET. A scenario file that exists and is neither gated nor exempt
# is a REFUSAL. gate.sh's own comment has warned about this since #724 —
# "adding the file without adding this line would have reproduced #724 one
# level down" — and until #1261 nothing enforced it.
mk_scen test-realmodel-gamma.sh idle
run_gcov "$MF_OK" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qF 'reason=undeclared_scenario_file scenario=test-realmodel-gamma.sh' <<<"$out"; then
    ok "RATCHET: a scenario file on disk that is neither gated nor exempt → REFUSED"
else bad "ratchet" "rc=$GCOV_RC out=$out"; fi

# C2 (POTENCY for C1) — declaring it EXEMPT with a reason clears the refusal,
# and the file is then reported as a NAMED gap rather than disappearing.
MF_EXEMPT=$(mk_manifest <<'EOM'
gated	test-realmodel-alpha.sh	idle,busy	wire-a	the base fixture
gated	test-realmodel-beta.sh	blocked	-	the second fixture
exempt	test-realmodel-gamma.sh	-	-	planted third scenario, deliberately not gated; OWNER your-org/nexus-code#1486
EOM
)
run_gcov "$MF_EXEMPT" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 0 )) && grep -qF 'EXEMPT (exist, not gated): test-realmodel-gamma.sh' <<<"$out"; then
    ok "POTENCY: the SAME tree with gamma declared exempt → rc 0, and gamma is a NAMED gap"
else bad "ratchet potency" "rc=$GCOV_RC out=$out"; fi

# C3 — an EXEMPTION WITH NO REASON is refused. An exemption nobody had to
# justify is an omission with a row in front of it.
MF_NOREASON=$(mk_manifest <<'EOM'
gated	test-realmodel-alpha.sh	idle,busy	wire-a	the base fixture
gated	test-realmodel-beta.sh	blocked	-	the second fixture
exempt	test-realmodel-gamma.sh	-	-	
EOM
)
run_gcov "$MF_NOREASON" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qF 'reason=exempt_without_reason' <<<"$out"; then
    ok "an exemption with an EMPTY reason → REFUSED"
else bad "reasonless exemption" "rc=$GCOV_RC out=$out"; fi

# C3b — AN EXEMPTION MUST BE OWNED, not merely explained
# (your-org/nexus-code#1486). #1482 landed this rule for a `none`
# positive-control row; `gate-coverage.tsv` has the same shape and lacked it,
# and the live `apispoof` row demonstrated why prose is not enough: its note
# stated IN ITS OWN WORDS that no rationale was on record — a sentence that
# passes "has a reason" while conceding there is none.
MF_UNOWNED=$(mk_manifest <<'EOM'
gated	test-realmodel-alpha.sh	idle,busy	wire-a	the base fixture
gated	test-realmodel-beta.sh	blocked	-	the second fixture
exempt	test-realmodel-gamma.sh	-	-	a prose reason with nowhere to be re-argued
EOM
)
run_gcov "$MF_UNOWNED" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qF 'reason=exempt_without_owner' <<<"$out"; then
    ok "an exemption with prose but NO OWNER → REFUSED (#1486)"
else bad "unowned exemption" "rc=$GCOV_RC out=$out"; fi

# CONTROL 1 — a tracker ref satisfies ownership.
MF_TRACKER=$(mk_manifest <<'EOM'
gated	test-realmodel-alpha.sh	idle,busy	wire-a	the base fixture
gated	test-realmodel-beta.sh	blocked	-	the second fixture
exempt	test-realmodel-gamma.sh	-	-	deliberately not gated; tracked at your-org/nexus-code#1486
EOM
)
run_gcov "$MF_TRACKER" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 0 )); then
    ok "CONTROL: a tracker ref satisfies the ownership rule"
else bad "tracker-owned exemption" "rc=$GCOV_RC out=$out"; fi

# CONTROL 2 — an until: expiry satisfies it too, same predicate as #1482's.
MF_UNTIL=$(mk_manifest <<'EOM'
gated	test-realmodel-alpha.sh	idle,busy	wire-a	the base fixture
gated	test-realmodel-beta.sh	blocked	-	the second fixture
exempt	test-realmodel-gamma.sh	-	-	deferred, re-justify by until:2026-12-31
EOM
)
run_gcov "$MF_UNTIL" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 0 )); then
    ok "CONTROL: an until:YYYY-MM-DD expiry satisfies the ownership rule"
else bad "date-owned exemption" "rc=$GCOV_RC out=$out"; fi

rm -f "$FX/scen/test-realmodel-gamma.sh"

# C4 — a GATED scenario with no declaration row is refused: the coverage
# figure would then not describe the run.
run_gcov "$MF_OK" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-zeta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qF 'reason=gated_but_undeclared scenario=test-realmodel-zeta.sh' <<<"$out"; then
    ok "a scenario in the gate list with no declaration → REFUSED"
else bad "gated-but-undeclared" "rc=$GCOV_RC out=$out"; fi

# C5 — DRIFT, the other direction: the manifest may not name a member the
# derived vocabulary does not have. A manifest that claims coverage of a state
# the tool does not have has drifted, and its other claims are then unbacked.
MF_DRIFT=$(mk_manifest <<'EOM'
gated	test-realmodel-alpha.sh	idle,no-such-state	-	claims a state the tool does not have
gated	test-realmodel-beta.sh	blocked	-	the second fixture
EOM
)
run_gcov "$MF_DRIFT" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qF 'reason=undeclared_state' <<<"$out" && grep -qF 'member=no-such-state' <<<"$out"; then
    ok "a declared pane-state outside the derived vocabulary → REFUSED"
else bad "manifest drift" "rc=$GCOV_RC out=$out"; fi

# C6 — the OVER-CLAIM FALSIFIER: a member declared for a scenario whose file
# never mentions it. Deliberately permissive (a token in a comment passes) —
# it catches an invented claim, it does not verify a true one.
MF_OVER=$(mk_manifest <<'EOM'
gated	test-realmodel-alpha.sh	idle,blocked	-	alpha does not mention blocked at all
gated	test-realmodel-beta.sh	blocked	-	the second fixture
EOM
)
run_gcov "$MF_OVER" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qF 'reason=overclaimed_member' <<<"$out" && grep -qF 'member=blocked' <<<"$out"; then
    ok "a coverage claim whose token is absent from the scenario file → REFUSED"
else bad "over-claim falsifier" "rc=$GCOV_RC out=$out"; fi

# C7 — an unreadable declaration is a refusal, not an empty coverage report.
run_gcov "$WORK/no-such-manifest.tsv" "$FX/pane-states.sh" "$FX/harness" "$FX/scen"; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qF 'reason=no_manifest' <<<"$out"; then
    ok "a missing coverage declaration → REFUSED"
else bad "missing manifest" "rc=$GCOV_RC out=$out"; fi

echo
echo "=== band D: the REAL tree — the declaration matches what is on disk ==="

# D1 — every rule above, run with NO overrides against the real repository:
# the real pane-state vocabulary, the real adapters, the real manifest and the
# real test-integration directory. This is the assertion that goes red the day
# somebody adds a test-realmodel-*.sh without declaring it.
out=$( gcov_report 2>&1 ); rc=$?
if (( rc == 0 )); then
    ok "the shipped gate-coverage.tsv is consistent with the real tree (no drift, no undeclared scenario file)"
else bad "real-tree consistency" "rc=$rc out=$out"; fi

# D2 — the real report's numbers are re-derived here and must agree. The
# denominator is counted from the tool, not read back from the line under test.
want_states=$(bash "$REPO_ROOT/monitor/pane-state.sh" --states 2>/dev/null | sed '/^$/d' | sort -u | wc -l)
got_denom=$(_last_line "$(sed -n 's/^=== gate-coverage: pane-state [0-9]*\/\([0-9]*\) covered ===$/\1/p' <<<"$out")")
if [[ -n "$want_states" ]] && (( want_states > 0 )) && [[ "$got_denom" == "$want_states" ]]; then
    ok "the real pane-state denominator equals \`pane-state.sh --states\` ($want_states)"
else bad "real denominator" "reported '$got_denom' vs tool '$want_states'"; fi

# D3 — the boundary is STATED, and the gap is non-empty on this tree. #1261's
# minimum ask is that 7/7 say what it does not cover; a report with an UNCOVERED
# section that never prints would satisfy the shape and not the ask.
if grep -qF 'UNCOVERED:' <<<"$out" && grep -qF 'boundary — a GREEN below is a claim about the COVERED members only' <<<"$out"; then
    ok "the real report NAMES its uncovered members and states the boundary"
else bad "boundary stated" "out=$out"; fi

echo
echo "=== band F: the SURFACE axis is declared on both sides and refuses its own stale forms (your-org/nexus-code#1344) ==="
mkdir -p "$FX/surf/monitor/hooks"
printf 'x\n' > "$FX/surf/monitor/pane-state.sh"
printf 'x\n' > "$FX/surf/monitor/hooks/bash-footgun-guard.sh"
mk_scen test-realmodel-alpha.sh idle busy wire-a pane-state.sh
MF_SURF=$(mk_manifest <<'EOM'
gated	test-realmodel-alpha.sh	idle,busy	wire-a	the base fixture	monitor/pane-state.sh
gated	test-realmodel-beta.sh	blocked	-	the second fixture	-
surface	monitor/pane-state.sh	gated	-	driven by alpha
surface	monitor/hooks/bash-footgun-guard.sh	known-gap	-	nothing drives the hook through the real binary
EOM
)
GCOV_SURFACE_ROOT="$FX/surf" run_gcov "$MF_SURF" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 0 )) && grep -qF 'surfaces 1/2 covered' <<<"$out" && grep -qF 'KNOWN GAPS: monitor/hooks/bash-footgun-guard.sh (nothing drives the hook' <<<"$out"; then
    ok "F1: surfaces k/n is printed and the known gap is NAMED with its reason"
else bad "F1 surfaces line" "rc=$GCOV_RC out=$out"; fi
# F2 — a scenario driving a surface no row declares → REFUSED
MF_UNDECL=$(mk_manifest <<'EOM'
gated	test-realmodel-alpha.sh	idle,busy	wire-a	the base fixture	monitor/pane-state.sh
gated	test-realmodel-beta.sh	blocked	-	the second fixture	-
EOM
)
GCOV_SURFACE_ROOT="$FX/surf" run_gcov "$MF_UNDECL" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qF 'reason=undeclared_surface scenario=test-realmodel-alpha.sh surface=monitor/pane-state.sh' <<<"$out"; then
    ok "F2: a driven surface with no surface row → REFUSED (the denominator is never implicit)"
else bad "F2 undeclared surface" "rc=$GCOV_RC out=$out"; fi
# F3 — a declared surface that does not exist on disk → REFUSED
MF_MISSING=$(mk_manifest <<'EOM'
gated	test-realmodel-alpha.sh	idle,busy	wire-a	the base fixture	-
gated	test-realmodel-beta.sh	blocked	-	the second fixture	-
surface	monitor/does-not-exist.sh	known-gap	-	a typo
EOM
)
GCOV_SURFACE_ROOT="$FX/surf" run_gcov "$MF_MISSING" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qF 'reason=surface_missing surface=monitor/does-not-exist.sh' <<<"$out"; then
    ok "F3: a surface path absent from the tree → REFUSED"
else bad "F3 missing surface" "rc=$GCOV_RC out=$out"; fi
# F4 — a surface declared gated that nothing drives → REFUSED
MF_UNDRIVEN=$(mk_manifest <<'EOM'
gated	test-realmodel-alpha.sh	idle,busy	wire-a	the base fixture	-
gated	test-realmodel-beta.sh	blocked	-	the second fixture	-
surface	monitor/pane-state.sh	gated	-	claimed, driven by nobody
EOM
)
GCOV_SURFACE_ROOT="$FX/surf" run_gcov "$MF_UNDRIVEN" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qF 'reason=surface_gated_undriven surface=monitor/pane-state.sh' <<<"$out"; then
    ok "F4: a gated surface no scenario drives → REFUSED (a covered surface with nothing behind it)"
else bad "F4 gated undriven" "rc=$GCOV_RC out=$out"; fi
# F5 — a known-gap that IS driven → REFUSED (stale declaration)
MF_STALE=$(mk_manifest <<'EOM'
gated	test-realmodel-alpha.sh	idle,busy	wire-a	the base fixture	monitor/pane-state.sh
gated	test-realmodel-beta.sh	blocked	-	the second fixture	-
surface	monitor/pane-state.sh	known-gap	-	stale: alpha drives it now
EOM
)
GCOV_SURFACE_ROOT="$FX/surf" run_gcov "$MF_STALE" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qF 'reason=surface_gap_is_driven surface=monitor/pane-state.sh' <<<"$out"; then
    ok "F5: a known-gap that a scenario drives → REFUSED (the declaration is stale)"
else bad "F5 stale gap" "rc=$GCOV_RC out=$out"; fi
# F6 — an over-claimed driver: the basename never appears in the scenario → REFUSED
MF_OVER=$(mk_manifest <<'EOM'
gated	test-realmodel-alpha.sh	idle,busy	wire-a	the base fixture	-
gated	test-realmodel-beta.sh	blocked	-	the second fixture	monitor/hooks/bash-footgun-guard.sh
surface	monitor/hooks/bash-footgun-guard.sh	gated	-	claimed by beta, which never names it
EOM
)
GCOV_SURFACE_ROOT="$FX/surf" run_gcov "$MF_OVER" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 3 )) && grep -qF 'reason=overclaimed_surface scenario=test-realmodel-beta.sh surface=monitor/hooks/bash-footgun-guard.sh' <<<"$out"; then
    ok "F6: a driver whose basename the scenario never mentions → REFUSED (permissive falsifier, same as the pane-state axis)"
else bad "F6 overclaimed" "rc=$GCOV_RC out=$out"; fi
# F7 — a pre-#1344 manifest (no surface rows) is not refused, and is printed as NOT DECLARED
run_gcov "$MF_OK" "$FX/pane-states.sh" "$FX/harness" "$FX/scen" test-realmodel-alpha.sh test-realmodel-beta.sh; out="$GCOV_OUT"
if (( GCOV_RC == 0 )) && grep -qF 'surfaces NOT DECLARED (0 surface rows)' <<<"$out" && ! grep -qE 'surfaces [0-9]+/[0-9]+ covered' <<<"$out"; then
    ok "F7: zero surface rows → printed as NOT DECLARED / UNMEASURED, never as covered, and not refused"
else bad "F7 undeclared axis" "rc=$GCOV_RC out=$out"; fi
# F8 — the REAL manifest declares the axis: at least one surface row, and the real report prints the line
_tsv_real="$(cd "$(dirname "${BASH_SOURCE[0]}")/../cc-harness" && pwd)/gate-coverage.tsv"
n_surf_rows=$(grep -cE $'^surface\t' "$_tsv_real")
out=$( gcov_report 2>&1 ); rc=$?
if (( n_surf_rows >= 1 )) && (( rc == 0 )) && grep -qE 'surfaces [0-9]+/[0-9]+ covered' <<<"$out"; then
    ok "F8: the shipped manifest declares the surface axis ($n_surf_rows rows) and the real report prints it"
else bad "F8 real surface axis" "rows=$n_surf_rows rc=$rc"; fi
# restore the shared fixture scenario for band E
mk_scen test-realmodel-alpha.sh idle busy wire-a

echo "=== band E: end-to-end through gate.sh ==="

# E1 — THE FILED DEFECT. An empty scenario list must not print GREEN.
out=$(CCH_GATE_SCENARIOS=" " bash "$GATE" --claude-bin "$CLAUDE_STUB" 2>&1); rc=$?
if (( rc == 2 )) && ! grep -qF 'GATE GREEN' <<<"$out" \
   && grep -qF 'GATE REFUSED (reason=no_scenarios)' <<<"$out" \
   && grep -qF 'gate-population: REFUSED label=executed scenarios count=0' <<<"$out"; then
    ok "an EMPTY scenario list → GATE REFUSED (exit 2), never GATE GREEN (your-org/nexus-code#1268)"
else bad "empty scenario list refused" "rc=$rc out=$(grep -E 'GATE |gate-population' <<<"$out")"; fi

# E2 — …and the tally is still printed. A refusal must destroy the VERDICT, not
# the evidence: #1259 makes exactly this argument for the disowned verdict, and
# a refusal that swallows the artefact is the same information loss.
if grep -qF 'tally: 0 passed / 0 failed / 0 skipped (of 0)' <<<"$out" \
   && grep -qE '^=== gate-assertions: ' <<<"$out"; then
    ok "the refusal preserves the tally and the assertion split (evidence kept, verdict withheld)"
else bad "refusal preserves evidence" "out=$(grep -E 'tally|gate-assertions' <<<"$out")"; fi

# E3 (POTENCY for E1) — one passing scenario through the SAME path is GREEN, so
# E1's refusal is caused by the empty population and not by a gate that now
# refuses everything.
S_PASS="$WORK/pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$S_PASS"; chmod +x "$S_PASS"
out=$(CCH_GATE_SCENARIOS="$S_PASS" bash "$GATE" --claude-bin "$CLAUDE_STUB" 2>&1); rc=$?
if (( rc == 0 )) && grep -qF 'GATE GREEN' <<<"$out"; then
    ok "POTENCY: one passing scenario through the same path → GATE GREEN (exit 0)"
else bad "non-empty potency" "rc=$rc out=$(grep -E 'GATE ' <<<"$out")"; fi

# E4 — #1261's minimum: the GREEN LINE ITSELF carries its boundary, and the
# coverage block is printed above it. `monitor/cc-auto-update-apply.sh:725`
# bumps on `grep -q 'GATE GREEN'` with no human in the loop, so the boundary
# has to travel in the artefact that consumer reads.
if grep -qF 'WITHIN the coverage boundary printed above' <<<"$out" \
   && grep -qE '^=== gate-coverage: pane-state [0-9]+/[0-9]+ covered ===$' <<<"$out" \
   && grep -qE '^=== gate-coverage: delivery [0-9]+/[0-9]+ covered ===$' <<<"$out"; then
    ok "the GREEN verdict states its boundary and is preceded by the coverage block"
else bad "green carries boundary" "out=$(grep -E 'GATE GREEN|gate-coverage' <<<"$out")"; fi

# E5 — THE OVERRIDE MAY NOT SWITCH THE CHECKS OFF. The coverage block above was
# produced while CCH_GATE_SCENARIOS pointed at a single stub, and it describes
# the PRODUCTION list. If coverage were computed over the executed list, the
# knob would be a way to reach this fix's success path without the work
# happening — which is the recursion this whole class is made of.
gated_n=$(_last_line "$(sed -n 's/^=== gate-coverage: scenarios gated=\([0-9]*\) .*$/\1/p' <<<"$out")")
if [[ "$gated_n" =~ ^[0-9]+$ ]] && (( gated_n > 1 )) \
   && grep -qF 'EXECUTED list OVERRIDDEN by CCH_GATE_SCENARIOS' <<<"$out"; then
    ok "under CCH_GATE_SCENARIOS the coverage block still describes the PRODUCTION list (gated=$gated_n), and says so"
else bad "override cannot disable coverage" "gated='$gated_n' out=$(grep -E 'gate-coverage: scenarios|OVERRIDDEN' <<<"$out")"; fi

# --- assertion-count guard -------------------------------------------------
#
# This suite exists because a gate rendered a verdict over a population it had
# not measured. A suite that silently stopped running arms would do the same
# thing one level up, so the total is pinned rather than merely printed.
EXPECTED_ASSERTIONS=38   # +3: your-org/nexus-code#1486 — an exempt row must be OWNED
                         # (refusal + the tracker-ref and until:-date controls)
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} + 1 ))
if (( TOTAL_ASSERTIONS == EXPECTED_ASSERTIONS )); then
    ok "assertion total is exactly $EXPECTED_ASSERTIONS — no band was silently skipped"
else
    bad "assertion total" "$TOTAL_ASSERTIONS != expected $EXPECTED_ASSERTIONS — a band ran short or was skipped"
fi

th_summary_and_exit
