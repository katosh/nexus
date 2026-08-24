#!/usr/bin/env bash
# Regression guard for your-org/nexus-code#762 — ci-signal's exit-code dispatch
# must be REACHABLE.
#
# This is your-org/nexus-code#739 recurring in a second workflow, and it is the
# sibling of test-slow-band-step-contract.sh (same defect, same method, other
# file). GitHub runs `run:` bodies under `/usr/bin/bash -e {0}`. The audit step
# opened with `set -uo pipefail`, which does NOT clear `-e`, and then ran the
# audit as `python3 … | tee`. So under errexit+pipefail a non-zero audit ABORTED
# THE STEP AT THE PIPELINE — before `rc=${PIPESTATUS[0]}` and therefore before
# the entire `case "$rc"` dispatch beneath it.
#
# Consequence: that dispatch was DEAD CODE for every non-zero rc. The step went
# red with the audit's status and not one of its `::error::ci-signal: …`
# sentences was ever emitted. The verdict was right; the explanation telling a
# reader WHY was silently dropped — which is this repo's own defect class (an
# absence that looks like nothing is missing) living inside the guard written
# against it. Found when #762's own PR went red on `NOT CONCLUDED`: the new
# rc 3 -> 0 remap could not run either, so a state deliberately defined as
# not-a-failure failed the check anyway.
#
# This is NOT a grep over the YAML. It EXTRACTS the audit step's actual `run:`
# body and EXECUTES it under `bash -e` — the same ambient shell option the
# runner uses — against stubs whose exit codes it controls. A grep for `set +e`
# would pass on a body that still aborts for some other reason; only running it
# can tell.
#
# The one edit made to the extracted body is textual path rewriting: the body
# hardcodes `/tmp/...` scratch paths, which would collide between concurrent
# runs of this suite on a shared host. Only the PATHS are rewritten; no control
# flow, no shell options, and in particular not the `set` line under test.
#
# Run directly: bash monitor/test-ci-signal-step-contract.sh

set -uo pipefail

_here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REPO=$(cd "$_here/.." && pwd)
WF="$REPO/.github/workflows/ci-signal.yml"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1" >&2; fail=$((fail+1)); }

# Dependencies are ASSERTED, never skipped over: a suite that quietly declines
# to run is indistinguishable from one that ran and found nothing, which is the
# substitution this whole file is about.
if [ ! -f "$WF" ]; then
    echo "FAIL: $WF not found" >&2; exit 1
fi
if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "FAIL: PyYAML is required to extract the step body and is not importable." >&2
    echo "      Refusing to report a pass over a body this suite could not read." >&2
    exit 1
fi

TMP=$(mktemp -d) || { echo "FAIL: mktemp" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ---- extract the audit step's run: body ------------------------------------
# Addressed by step NAME, never by index: a step inserted above must not
# silently retarget this test at some other body.
python3 - "$WF" "$TMP" <<'PY' || { echo "FAIL: could not extract the audit step" >&2; exit 1; }
import sys, yaml, pathlib
wf, out = sys.argv[1], pathlib.Path(sys.argv[2])
doc = yaml.safe_load(open(wf))
steps = doc["jobs"]["ci-signal"]["steps"]
hits = [s for s in steps
        if "audit the trigger set" in str(s.get("name", ""))]
assert len(hits) == 1, "expected exactly one audit step, got %d" % len(hits)
out.joinpath("audit.sh").write_text(hits[0]["run"])
PY

AUDIT_SRC="$TMP/audit-step.sh"
sed "s#/tmp/#$TMP/scratch/#g" "$TMP/audit.sh" > "$AUDIT_SRC"
mkdir -p "$TMP/scratch"

# The extraction must have captured the real thing. A body that silently came
# back empty (or without the pipeline this test is about) would let every
# assertion below pass vacuously.
for sentinel in 'ci-trigger-audit.py' 'PIPESTATUS' 'case "$rc"'; do
    if ! grep -qF "$sentinel" "$AUDIT_SRC"; then
        bad "extraction: the body lacks \`$sentinel\` — this suite is not testing what it claims"
        printf 'passed: %d   failed: %d\nTESTS FAILED\n' "$pass" "$fail"; exit 1
    fi
done
ok "extracted the real audit step body (pipeline + PIPESTATUS + dispatch present)"

# ---- fixture: stubs whose exit codes this test controls ---------------------
mk_fixture() {
    local d="$1"
    mkdir -p "$d/monitor" "$d/bin"
    # The audit itself — a valid python file, since the body invokes it as
    # `python3 monitor/ci-trigger-audit.py`.
    cat > "$d/monitor/ci-trigger-audit.py" <<'STUB'
import os, sys
print("STUB AUDIT OUTPUT")
# your-org/nexus-code#846: the poll exemption keys on the FINDING, not on the
# exit code, so the stub must be able to emit the finding line.
if os.environ.get("STUB_UNEXEC") == "1":
    print("UNEXECUTED-RUN: tests.yml")
sys.exit(int(os.environ.get("STUB_RC", "0")))
STUB
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/monitor/ci-attempt-history.sh"
    chmod +x "$d/monitor/ci-attempt-history.sh"
    # Exit code controllable, so the step's `else` FALLBACK arm is drivable
    # (PR #854 delta review, G1). A stub hardcoded to `exit 0` made that branch
    # structurally unreachable — and "unreachable" was a property of THIS
    # fixture, not of the workflow.
    printf '#!/usr/bin/env bash\nexit %s\n' "${STUB_EXEC_RC:-0}" > "$d/monitor/ci-run-execution.sh"
    chmod +x "$d/monitor/ci-run-execution.sh"
    : > "$d/monitor/ci-observed-runs.jq"
    printf '#!/usr/bin/env bash\nprintf "{\\"workflow_runs\\":[]}\\n"\nexit 0\n' > "$d/bin/gh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/jq"
    chmod +x "$d/bin/gh" "$d/bin/jq"
}

# run_step <script> <audit_rc> [unexec] -> prints "<rc>|<stdout, newlines as ¶>"
# Executes the body exactly as the runner does: `bash -e <file>`. A third
# argument of `1` makes the stub audit emit an UNEXECUTED-RUN finding (#846).
run_step() {
    local script="$1" audit_rc="$2" unexec="${3:-0}"
    local d; d=$(mktemp -d -t ci-signal-fx-XXXXXX)
    mk_fixture "$d"
    mkdir -p "$TMP/scratch"
    printf 'monitor/ng\n' > "$TMP/scratch/changed-files.txt"
    local rc=0
    ( cd "$d" && PATH="$d/bin:$PATH" \
        GITHUB_REPOSITORY=your-org/nexus-code \
        HEAD_SHA=deadbeef BASE_REF=dev GH_TOKEN=x \
        STUB_RC="$audit_rc" STUB_UNEXEC="$unexec" \
        bash -e "$script" ) >"$d/out" 2>&1 || rc=$?
    printf '%s|%s\n' "$rc" "$(tr '\n' '\266' < "$d/out")"
    rm -rf "$d"
}

echo "== the contract, on the real ci-signal audit body =="

# A1 — your-org/nexus-code#762. A head that has not CONCLUDED is not a failure
#      of this check: ci-signal is a peer racing its siblings and finishes
#      minutes before them, so rc 3 must map to success AND say so. Before the
#      `set +e` fix the step died at the pipeline and exited 3.
r=$(run_step "$AUDIT_SRC" 3)
if [ "${r%%|*}" = "0" ]; then
    ok "A1a audit rc 3 (NOT CONCLUDED) -> step exits 0"
else
    bad "A1a audit rc 3 -> step exited ${r%%|*}, wanted 0 — a pending sibling reddens ci-signal on every PR"
fi
case "${r#*|}" in
    *"not a merge clearance"*) ok "A1b …and the notice explaining the boundary is emitted" ;;
    *) bad "A1b rc 3 produced no boundary notice — the reader is told nothing" ;;
esac
# A1c — the rc 3 arm must RETURN, not fall through into the case. Rewriting rc
#       to 0 and dropping through would ALSO print the rc-0 arm's "every gating
#       workflow has CONCLUDED and carries a success verdict" — the vacuous
#       quantifier #762 exists to delete, printed directly beneath the honest
#       notice that contradicts it. Caught by the skeptic pass on this PR.
case "${r#*|}" in
    *"carries a success verdict"*)
        bad "A1c rc 3 ALSO printed the rc-0 arm — the vacuous claim is back, under its own refutation" ;;
    *)  ok "A1c …and the rc-0 arm does NOT also fire (no fall-through into the case)" ;;
esac

# A2 — THE DEAD-CODE PROPERTY ITSELF. A real red must still exit 5, but it must
#      ALSO reach the dispatch and emit the sentence explaining what 5 means.
#      rc 5 is chosen deliberately: it is terminal, so the body's bounded
#      re-audit poll (which only fires on rc 4) does not run and this assertion
#      costs no wall-clock.
r=$(run_step "$AUDIT_SRC" 5)
if [ "${r%%|*}" = "5" ]; then
    ok "A2a audit rc 5 (FAILED) -> step still exits 5 — the red is preserved"
else
    bad "A2a audit rc 5 -> step exited ${r%%|*}, wanted 5 — the fix must not swallow a real red"
fi
case "${r#*|}" in
    *"::error::ci-signal:"*"FAILED"*) ok "A2b …and the dispatch is REACHED (the ::error:: explanation is emitted)" ;;
    *) bad "A2b rc 5 emitted no ::error::ci-signal: line — the dispatch is dead code again (#739 shape)" ;;
esac

# A3 — the control. A clean audit must stay clean, or A1/A2 could be passing
#      against a body that mangles every outcome.
r=$(run_step "$AUDIT_SRC" 0)
if [ "${r%%|*}" = "0" ]; then
    ok "A3 audit rc 0 -> step exits 0 (control: A1/A2 red on the mapping, not on everything)"
else
    bad "A3 audit rc 0 -> step exited ${r%%|*}, wanted 0"
fi

echo "== mutants (a guard never observed failing is not evidence) =="

# M1 — strip the fix: restore `set -uo pipefail` without `+e`. This IS the
#      pre-fix body, so both A1 and A2 must break — A1 because the step dies at
#      the pipeline with 3, A2 because the dispatch is never reached. If this
#      mutant survives, `set +e` is not what makes the dispatch reachable and
#      every assertion above is measuring something else.
MUT="$TMP/mutant-errexit.sh"
sed 's/^\([[:space:]]*\)set +e -uo pipefail/\1set -uo pipefail/' "$AUDIT_SRC" > "$MUT"
if cmp -s "$AUDIT_SRC" "$MUT"; then
    bad "M1 mutation changed nothing — the \`set +e\` line moved; update this test"
else
    r=$(run_step "$MUT" 3)
    if [ "${r%%|*}" = "3" ]; then
        ok "M1a mutant: rc 3 leaks out as exit 3 — errexit is what the fix disarms"
    else
        bad "M1a mutant still exits ${r%%|*} on rc 3 — A1a is not pinned by \`set +e\`"
    fi
    r=$(run_step "$MUT" 5)
    case "${r#*|}" in
        *"::error::ci-signal:"*)
            bad "M1b mutant STILL emitted the dispatch — A2b proves nothing" ;;
        *)  ok "M1b mutant: no ::error:: line — the dispatch really was unreachable pre-fix" ;;
    esac
fi

# D1-D2 — UNGATED (your-org/nexus-code#856). Every workflow that fired is green
#         and none was selected by the diff. This check is a PEER, and a
#         docs-only PR legitimately needs no suite, so reddening it would train
#         readers to ignore the check — the same proportionality argument that
#         keeps rc 3 green. It must therefore exit 0, and it must NOT be silent:
#         the warning is what puts "nothing examined this change" on the PR page
#         instead of leaving it to be inferred from a green tick.
r=$(run_step "$AUDIT_SRC" 8)
if [ "${r%%|*}" = "0" ]; then
    case "${r#*|}" in
        *"::warning::ci-signal: UNGATED"*)
            case "${r#*|}" in
                *"every gating workflow has CONCLUDED and carries a success verdict"*)
                    bad "D1b the rc-0 clearance notice ALSO printed — the vacuous sentence rc 8 exists to suppress" ;;
                *)  ok "D1 audit rc 8 -> step exits 0 with an UNGATED warning, and the rc-0 clearance notice is NOT printed" ;;
            esac ;;
        *)  bad "D1 audit rc 8 emitted no UNGATED warning — the state is silent, which is the defect" ;;
    esac
else
    bad "D1 audit rc 8 -> step exited ${r%%|*}, wanted 0 — a docs-only PR must not redden the peer check"
fi

# D2 — the control: rc 0 must NOT emit the UNGATED warning, or D1 proves nothing.
r=$(run_step "$AUDIT_SRC" 0)
case "${r#*|}" in
    *"UNGATED"*) bad "D2 the UNGATED warning fired on a rc-0 clearance — D1 proves nothing" ;;
    *)           ok "D2 …and a genuine clearance emits no UNGATED warning — D1's warning is attributable to rc 8" ;;
esac

# B1 — your-org/nexus-code#846. Exit 4 is POLLED, because "a run has not
#      REGISTERED yet" resolves in seconds. An UNEXECUTED-RUN is exit 4 and has
#      already resolved: GitHub created the run, labelled it `failure` and never
#      started a job, for a reason outside this repo. Polling it burns 180s and
#      a dozen API calls re-reading a settled fact, during an incident that is
#      already costing everyone time. The exemption keys on the FINDING LINE,
#      not on the exit code, so this asserts the emitted text.
#
#      COVERAGE BOUNDARY, stated rather than implied: the complementary case —
#      a plain rc 4 that SHOULD poll — is deliberately NOT exercised here,
#      because asserting it means waiting out the real 180-second deadline this
#      body owns. So B1 shows the exemption FIRES on the finding; it does not
#      show the poll still works without it. B2 below is the closest available
#      substitute: the same rc with the finding absent takes the other branch.
r=$(run_step "$AUDIT_SRC" 4 1)
case "${r#*|}" in
    *"NOT polling"*)
        case "${r#*|}" in
            *"re-auditing in 15s"*)
                bad "B1 the exemption printed but the poll ran anyway — the break is not taken" ;;
            *)  ok "B1 audit rc 4 WITH an UNEXECUTED-RUN finding -> the poll is skipped, not waited out" ;;
        esac ;;
    *)  bad "B1 rc 4 + UNEXECUTED-RUN did not take the no-poll branch — it will burn the full 180s deadline on a settled fact" ;;
esac

# B2 — the discriminator, and the reason B1 is not vacuous: the exemption must
#      key on the FINDING and not on the exit code alone. Same rc 4, finding
#      absent — and the body must NOT announce the exemption. (It then enters
#      the poll, which is why this case is read for the ABSENCE of the
#      exemption line rather than run to completion; `run_step` returns after
#      the deadline, which is what the timing note in B1 is about.)
r=$(run_step "$AUDIT_SRC" 5)
case "${r#*|}" in
    *"NOT polling"*)
        bad "B2 the no-poll exemption fired without an UNEXECUTED-RUN finding — it keys on the wrong thing" ;;
    *)  ok "B2 …and it does NOT fire when the finding is absent — the exemption reads the finding, not the code" ;;
esac

# C1-C3 — THE ENRICHER'S FAILURE FALLBACK (PR #854 delta review, G1).
#
#      The PR asserted the degradation direction of BOTH call sites and cited a
#      fixture in the OTHER suite that drives neither `else` arm. This is the
#      ci-signal.yml half, and it is now drivable because the stub's exit code
#      is a variable — "unreachable" was a property of the fixture.
#
#      The claim under test: a failing enricher costs a worse MESSAGE and never
#      a softer VERDICT. The structural risk is not subtle — GH Actions wraps
#      every step in `bash -e`, so without the `if` guard the failing enricher
#      would abort the step before the audit ever ran, and a step that never
#      audits is not a softer verdict, it is NO verdict.
r=$(STUB_EXEC_RC=2 run_step "$AUDIT_SRC" 5)
case "${r#*|}" in
    *"::warning::ci-run-execution failed"*)
        if [ "${r%%|*}" = "5" ]; then
            ok "C1 enricher fails -> warning emitted AND the audit's rc 5 still governs (worse message, same verdict)"
        else
            bad "C1 enricher fails -> step exited ${r%%|*}, wanted 5 — the fallback changed the verdict"
        fi ;;
    *)  bad "C1 enricher fails -> no ::warning:: emitted; the degradation is silent" ;;
esac

# C2 — the control. Same audit rc, enricher SUCCEEDING: no warning. Without it,
#      C1 could be passing against a build that warns unconditionally.
r=$(STUB_EXEC_RC=0 run_step "$AUDIT_SRC" 5)
case "${r#*|}" in
    *"::warning::ci-run-execution failed"*)
        bad "C2 the warning fired with a SUCCEEDING enricher — C1 proves nothing" ;;
    *)  ok "C2 …and no warning when the enricher succeeds — C1's warning is attributable to its exit code" ;;
esac

# C3 — and the step must still REACH the audit. rc 0 out of a failing enricher
#      proves `bash -e` did not abort at the enricher: the audit ran and its
#      own rc came through.
r=$(STUB_EXEC_RC=2 run_step "$AUDIT_SRC" 0)
if [ "${r%%|*}" = "0" ]; then
    ok "C3 a failing enricher does not abort the step under \`bash -e\` — the audit still runs and still governs"
else
    bad "C3 step exited ${r%%|*} with a failing enricher and a clean audit — the step aborted before auditing"
fi

echo
echo "assertions: $((pass + fail))"
echo "passed: $pass   failed: $fail"
if [ "$fail" -ne 0 ]; then
    echo "TESTS FAILED"
    exit 1
fi
echo "ALL TESTS PASSED"
