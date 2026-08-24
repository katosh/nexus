#!/usr/bin/env bash
# test-ci-head-attempts.sh — `ng ci-attempts` (your-org/nexus-code#740).
#
# THE CASE THIS SUITE EXISTS FOR. During the 2026-08-06 Actions outage a head
# with ZERO check-runs presented as `mergeable=true mergeable_state=clean`.
# Every verdict guard this repo has is itself an Actions workflow, so the
# outage defeated all of them at once and the residue read as success.
#
# The zero case was already loud in this verb. The case that was NOT is the
# PARTIAL one: some bands ran, every one of them green, the missing ones
# invisible — "every completed run is a first-pass success" is TRUE and reads
# as approval. T1 is that case, and it is the reason for exit code 4.
#
# Every case drives the REAL script against a stubbed `gh`, and the audit half
# is the REAL ci-trigger-audit.py over REAL workflow files — not a
# reimplementation, so a drift in trigger semantics reddens here too.
#
# Run: bash monitor/test-ci-head-attempts.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$_test_dir/ci-head-attempts.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || {
    echo "SKIP: PyYAML absent — ci-trigger-audit.py cannot run, so the audit"
    echo "half of this suite would pass while checking nothing. Refusing."
    exit 1
}

# Deliberately NOT all-digits: the ref resolver tries `^[0-9]+$` (a PR number)
# before `^[0-9a-fA-F]{40}$`, so an all-numeric fixture sha is read as a PR and
# the bare-sha cases silently test the PR path instead.
SHA=1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b

# ---- fixture workflows ----------------------------------------------------
# Two gating bands over monitor/**, one docs band that must stay silent. Kept
# minimal so the expected set is unambiguous and stated here, not inferred.
WF="$TMP/wf"; mkdir -p "$WF"
cat > "$WF/tests.yml" <<'EOF'
name: tests
on:
  pull_request:
    branches: [main, dev]
    paths: ['monitor/**']
jobs:
  unit: { runs-on: ubuntu-latest, steps: [{run: 'true'}] }
EOF
cat > "$WF/tests-slow-integration.yml" <<'EOF'
name: slow
on:
  pull_request:
    branches: [main, dev]
    paths: ['monitor/**']
jobs:
  slow: { runs-on: ubuntu-latest, steps: [{run: 'true'}] }
EOF
cat > "$WF/docs.yml" <<'EOF'
name: docs
on:
  pull_request:
    branches: [main, dev]
    paths: ['docs/**']
jobs:
  docs: { runs-on: ubuntu-latest, steps: [{run: 'true'}] }
EOF

# ---- gh stub --------------------------------------------------------------
# Serves exactly the calls the script makes. RUNS_JSON / CHANGED / BASE are
# per-case inputs; everything else is fixed.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
WF="$WF"; SHA="$SHA"
args="\$*"
case "\$args" in
  "repo view"*)                 echo "your-org/nexus-code"; exit 0 ;;
  *"--json headRefOid"*)        echo "\$SHA"; exit 0 ;;
  *"--json baseRefName"*)       cat "\$STUB_BASE"; exit 0 ;;
  *"--json changedFiles"*)
        # Served INDEPENDENTLY of the file list (STUB_NFILES), not derived
        # from it. Deriving one from the other made the changed-file
        # enumeration guard unable to fire under test — "both guards" was
        # one tested and one asserted.
        if [[ -n "\${STUB_NFILES:-}" ]]; then echo "\$STUB_NFILES"
        else awk 'NF { n++ } END { print n+0 }' "\$STUB_CHANGED"; fi
        exit 0 ;;
  *"--json files"*)             cat "\$STUB_CHANGED"; exit 0 ;;
esac
case "\$args" in
  # your-org/nexus-code#823 reads the SAME endpoint with a different \`--jq\`
  # (successful pull_request run ids). Discriminated on that expression's
  # \`.[0:8]\` slice — quote-free, so it survives this heredoc intact, and
  # unique to that call. Empty by default, which lands the check on \`unread\`
  # and leaves every pre-existing case meaning exactly what it did.
  *"/actions/runs?head_sha="*0:8*)
        printf '%s\n' "\${STUB_MRB_RUN:-}"; exit 0 ;;
  *"/actions/runs?head_sha="*)  cat "\$STUB_RUNS"; exit 0 ;;
  *"contents/.github/workflows?ref="*)
        for f in "\$WF"/*.yml; do basename "\$f"; done; exit 0 ;;
  *"contents/.github/workflows/"*)
        n=\$(sed 's#.*workflows/##; s#?.*##' <<<"\$args" | awk '{print \$1}')
        cat "\$WF/\$n"; exit 0 ;;
  *"/commits/"*)                echo "\$SHA"; exit 0 ;;
  # THE #846 x #823 SEAM, and it has to be resolved HERE because both branches
  # fetch the SAME endpoint (\`/actions/runs/<id>/jobs\`). #823's arm was written
  # below, correct against its own base; #846's generic \`*"/jobs"*\` arm then
  # rebased in ABOVE it and SHADOWED it completely, so \$STUB_MRB_JOB was never
  # served and the merge-ref check could never read a job — it landed on
  # \`unread\` unconditionally and T6b's rc-9 STALE case went rc 0. Neither branch
  # is wrong alone; the defect exists only where they meet, and it is invisible
  # at file granularity because both sides only ever ADDED a case arm.
  #
  # Discriminated on #823's own \`--jq\` slice \`.[0:6]\`, quote-free so it survives
  # this unquoted heredoc intact — exactly the trick the \`.[0:8]\` runs arm above
  # already uses for the very same collision one endpoint over. #846's call is
  # the one carrying \`filter=latest\`, so the two are separable with no overlap.
  # BOTH #823 arms move up, not just the first. The logs endpoint is
  # \`/actions/JOBS/<id>/logs\` — it contains the literal \`/jobs\` too, so the
  # generic arm below swallowed it as well. Fixing only the runs/jobs arm left
  # the check reading a run and a job and then failing at the log, which still
  # lands on \`unread\` and still reports rc 0 where rc 9 is owed: the same
  # symptom, one endpoint further along. Two arms shadowed, one root cause.
  *"/actions/runs/"*"/jobs"*0:6*) printf '%s\n' "\${STUB_MRB_JOB:-}"; exit 0 ;;
  *"/actions/jobs/"*"/logs"*)     printf '%s\n' "\${STUB_MRB_LOG:-}"; exit 0 ;;
  # your-org/nexus-code#846. Matched AFTER the head_sha arm, which it cannot
  # collide with (\`/actions/runs/<id>/jobs\` carries no \`?head_sha=\`).
  # Defaults to FAILING when STUB_JOBS is unset, so every case written before
  # #846 keeps its exact meaning: an unreadable jobs payload yields the
  # \`unknown\` token, which keeps a \`failure\` RED — the pre-#846 verdict.
  # A stub that invented a payload by omission would have silently converted
  # them all into execution-measured variants.
  *"/jobs"*)
        # Per-run first (\`\$STUB_JOBS_DIR/<run-id>.json\`), then the shared
        # payload. The per-run form is what makes a MIXED head expressible:
        # one run that executed nothing beside one that executed and failed.
        rid=\$(sed 's#.*/actions/runs/##; s#/jobs.*##' <<<"\$args" | awk '{print \$1}')
        if [[ -n "\${STUB_JOBS_DIR:-}" && -r "\$STUB_JOBS_DIR/\$rid.json" ]]; then
            cat "\$STUB_JOBS_DIR/\$rid.json"; exit 0
        fi
        [[ -n "\${STUB_JOBS:-}" ]] || exit 1
        cat "\$STUB_JOBS"; exit 0 ;;
  *"/annotations"*)
        printf '[{"message":"The job was not started because recent account payments have failed"}]\n'
        exit 0 ;;
  # your-org/nexus-code#773. Matched AFTER /actions/runs so the runs endpoint
  # keeps its arm. Defaults to \`clean\` so every pre-existing case keeps the
  # meaning it was written with — a stub that answered \`unknown\` by omission
  # would have silently turned all of them into caveat-carrying variants.
  # your-org/nexus-code#823 — the merge-ref base check reads three more
  # endpoints. Every arm DEFAULTS TO EMPTY when its STUB_MRB_* var is unset, so
  # the check lands on \`unread\` and every pre-existing case keeps exactly the
  # meaning it was written with: \`unread\` reports itself and withholds nothing.
  # (#823's \`/actions/runs/<id>/jobs\` and \`/actions/jobs/<id>/logs\` arms USED to
  # sit here. Both now live above the #846 \`*"/jobs"*\` arm, which shadowed them
  # — see the seam note there. Left as a signpost rather than silently
  # relocated: a reader looking for the MRB arms should be told where they went.)
  # your-org/nexus-code#823: the base BRANCH NAME comes from the PR object, the
  # live TIP from the ref. Reading \`.base.sha\` — a frozen snapshot — is the
  # defect that made the check unable to fire; the shipped code refuses to fall
  # back to it, and this stub does not serve it.
  *"/pulls/"*".base.ref"*)      printf '%s\n' "\${STUB_MRB_BASEREF:-dev}"; exit 0 ;;
  *"/git/ref/heads/"*)          printf '%s\n' "\${STUB_MRB_BASE:-}"; exit 0 ;;
  *"/pulls/"*)
        # Counted, so the "one extra API call" cost claim is CHECKED rather
        # than asserted in a comment (your-org/nexus-code#773).
        [[ -n "\${STUB_CALLS:-}" ]] && printf '%s\n' "\$args" >> "\$STUB_CALLS"
        printf '%s\n' "\${STUB_MERGEABLE:-clean}"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$TMP/bin/gh"

export STUB_BASE="$TMP/base.txt"; echo dev > "$STUB_BASE"
export STUB_CHANGED="$TMP/changed.txt"
printf 'monitor/ng\n' > "$STUB_CHANGED"
export STUB_RUNS="$TMP/runs.json"
export STUB_MERGEABLE="clean"

# runs_json <total> <path:conclusion[:status]> ... — build an actions/runs
# payload. The optional third field defaults to `completed`, so every call
# written before your-org/nexus-code#762 keeps its exact meaning; supplying
# `in_progress` (with an empty conclusion) is what builds a head that has not
# concluded, which is the shape #762 is about.
runs_json() {
    local total="$1"; shift
    local first=1 out="{\"total_count\":$total,\"workflow_runs\":["
    local spec p rest c s nrun=0
    for spec in "$@"; do
        p="${spec%%:*}"; rest="${spec#*:}"
        c="${rest%%:*}"; s="${rest#*:}"
        [[ "$s" == "$rest" ]] && s=completed
        (( first )) || out+=","
        first=0
        out+="{\"path\":\".github/workflows/$p\",\"status\":\"$s\",\"conclusion\":"
        if [[ -z "$c" ]]; then out+="null"; else out+="\"$c\""; fi
        # DISTINCT ids, one per run. They used to be all `1`, which was
        # harmless while nothing fetched per-run detail — but #846 does
        # (`/actions/runs/<id>/jobs`), and a shared id makes every run in a
        # fixture answer with the same payload, so a head that MIXES an
        # aborted run with a real red is unconstructible. A fixture that
        # cannot express the mixed case would have let its claim go untested.
        out+=",\"run_attempt\":1,\"id\":$(( 100 + nrun ))}"
        nrun=$(( nrun + 1 ))
    done
    printf '%s]}' "$out"
}

run_it() {  # run_it <ref> [extra args...] → sets OUT, RC
    OUT=$(PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$@" --repo your-org/nexus-code 2>&1)
    RC=$?
}

echo "== ng ci-attempts: expected-band coverage (#740) =="

# T1. THE PARTIAL SET — the case a prose disclaimer never caught. `tests.yml`
#     ran and is a clean first-pass green; `tests-slow-integration.yml` never
#     ran at all. Before this change the verdict was "every completed run at
#     this head is a FIRST-PASS success" with exit 0 — true, and read as
#     approval by anyone on the merge path.
runs_json 1 "tests.yml:success" > "$STUB_RUNS"
run_it 739
if (( RC == 4 )) && grep -q 'did NOT come back clean' <<<"$OUT" \
   && grep -q 'absence of a verdict is RED' <<<"$OUT"; then
    ok "partial band set → rc 4, NOT a green (the #740 merge-path case)"
else
    # `grep -im2`, NOT `grep … | head -2`: the pipe form is a new early-exit
    # reader and moves the checked population in early-exit-readers.manifest
    # (#622/#682). Benign here — the status is consumed by nothing and this
    # runs only on an already-failed assertion — but not worth a permanent
    # row on a checked boundary to truncate a diagnostic.
    bad "partial band set" "rc=$RC; $(grep -im2 verdict <<<"$OUT")"
fi
# The specific missing band must be NAMED — "something is missing" is not
# actionable, and a count would be a claim about the tally, not the members.
if grep -q 'tests-slow-integration' <<<"$OUT"; then
    ok "the missing band is named, not merely counted"
else
    bad "missing band not named" "$(tail -6 <<<"$OUT")"
fi

# T2. EMPTY, WITH BANDS EXPECTED — the outage shape. Distinct from T3 by
#     CAUSE, which is the whole point: collapsing them would be the defect
#     this verb is being hardened against, reproduced in its own remedy.
runs_json 0 > "$STUB_RUNS"
run_it 739
if (( RC == 4 )) && grep -q 'bands WERE expected and none of them ran' <<<"$OUT" \
   && grep -q 'not a pass' <<<"$OUT"; then
    ok "zero runs + bands expected → outage-shaped refusal (rc 4)"
else
    bad "zero runs with expectations" "rc=$RC; $(tail -5 <<<"$OUT")"
fi

# T3. EMPTY, EXPECTATIONS UNKNOWABLE — a bare sha carries no base ref and no
#     changed files, so "no runs" CANNOT be separated from "no runs were
#     expected". That is a third state, and it must not borrow either
#     neighbour's verdict.
runs_json 0 > "$STUB_RUNS"
run_it "$SHA"
if (( RC == 2 )) && grep -q 'UNDETERMINED' <<<"$OUT" \
   && grep -q 'cannot be separated from' <<<"$OUT"; then
    ok "zero runs + no PR context → UNDETERMINED (rc 2), distinct from both"
else
    bad "zero runs without expectations" "rc=$RC; $(tail -5 <<<"$OUT")"
fi

# T4. COVERAGE BOUNDARY DECLARED WHERE THE BELIEF FORMS. A bare sha with a
#     clean run set is still only half an answer; the verdict must say so
#     inline rather than leaving it to a docstring.
runs_json 2 "tests.yml:success" "tests-slow-integration.yml:success" > "$STUB_RUNS"
run_it "$SHA"
if (( RC == 0 )) && grep -q 'expected-band audit did NOT run' <<<"$OUT" \
   && grep -q 'would be INVISIBLE above' <<<"$OUT"; then
    ok "bare sha: clean runs, boundary declared in the verdict itself"
else
    bad "bare-sha boundary" "rc=$RC; $(tail -6 <<<"$OUT")"
fi

# T5. THE TALLY IS NOT THE ENUMERATION. The API says 7 runs exist; this page
#     returned 2. Any "band X is missing" finding would be an artefact of the
#     truncation, so the verb refuses rather than reporting a subset.
runs_json 7 "tests.yml:success" "tests-slow-integration.yml:success" > "$STUB_RUNS"
run_it 739
if (( RC == 2 )) && grep -q 'enumeration is INCOMPLETE' <<<"$OUT"; then
    ok "truncated run page → refusal, never a confident subset"
else
    bad "truncation guard" "rc=$RC; $(tail -4 <<<"$OUT")"
fi

# T6. THE CLEAN CASE IS STILL CLEAN — a suite that only proves things go red
#     proves nothing about the green. Both gating bands present and green,
#     docs.yml correctly silent (its paths do not match).
runs_json 2 "tests.yml:success" "tests-slow-integration.yml:success" > "$STUB_RUNS"
run_it 739
if (( RC == 0 )) && grep -q 'This head is cleared' <<<"$OUT" \
   && grep -q 'audit ALSO ran and is clean' <<<"$OUT"; then
    ok "all expected bands green → cleared (rc 0), both questions answered"
else
    bad "clean case" "rc=$RC; $(tail -6 <<<"$OUT")"
fi

# T6b. THE MERGE-REF BASE (your-org/nexus-code#823), wired end-to-end through
#      the verb rather than only through its library. `#823` merged on a green
#      computed against a merge ref built at RUN CREATION, describing a tree
#      that no longer existed — and the enumeration that cleared it was correct
#      about every other thing it checked. The three states are asserted on the
#      SAME clean fixture as T6, so the only thing varying is the base.
MRB_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MRB_OLD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
MRB_NEW=cccccccccccccccccccccccccccccccccccccccc
runs_json 2 "tests.yml:success" "tests-slow-integration.yml:success" > "$STUB_RUNS"

# STALE: the run tested $MRB_OLD; the base is $MRB_NEW now.
STUB_MRB_RUN=9001 STUB_MRB_JOB=8001 STUB_MRB_BASE="$MRB_NEW" \
STUB_MRB_LOG="HEAD is now at ec3412f Merge $MRB_HEAD into $MRB_OLD" \
    run_it 739
if (( RC == 9 )) && grep -q 'NOT CLEARED — the green describes a tree that' <<<"$OUT" \
   && grep -q 'REMEDY: rebase' <<<"$OUT"; then
    ok "a stale merge ref withholds the clearance at its own exit code 9 (#823)"
else
    bad "stale merge ref" "rc=$RC (want 9); $(tail -8 <<<"$OUT")"
fi

# THE COLLISION THIS NUMBER SURVIVED, asserted rather than trusted: `8` is
# UNGATED (your-org/nexus-code#856/#868, already on dev) and `9` is STALE MERGE
# REF (#823, this branch). Both were independently written as `8`; the rebase
# collided them. They sit in different arms of one if/elif chain and cannot both
# fire, so this pins the ALLOCATION — the thing a future rebase can silently
# break — not the control flow.
if grep -qE '^#   8  UNGATED' "$SCRIPT" && grep -qE '^#   9  STALE MERGE REF' "$SCRIPT"; then
    ok "the rc table allocates 8=UNGATED and 9=STALE MERGE REF, distinctly"
else
    bad "rc allocation" "the 8/9 split is not both present in $SCRIPT's rc table"
fi

# CURRENT: same everything, base unchanged. The control that makes the case
# above attributable to the base and not to the fixture.
STUB_MRB_RUN=9001 STUB_MRB_JOB=8001 STUB_MRB_BASE="$MRB_OLD" \
STUB_MRB_LOG="HEAD is now at ec3412f Merge $MRB_HEAD into $MRB_OLD" \
    run_it 739
if (( RC == 0 )) && grep -q 'Merge-ref base: VERIFIED' <<<"$OUT" \
   && grep -q 'This head is cleared' <<<"$OUT"; then
    ok "the same head with an unmoved base clears, and SAYS the base was verified"
else
    bad "current merge ref" "rc=$RC (want 0); $(tail -8 <<<"$OUT")"
fi

# UNREAD: no stub answers at all. Must not block (GitHub expires logs) and must
# not read as verified — 'not looked at' is not 'looked at and current'.
run_it 739
if (( RC == 0 )) && grep -q 'Merge-ref base: NOT CHECKED' <<<"$OUT" \
   && grep -q 'NOT `looked at and current`' <<<"$OUT" \
   && ! grep -q 'Merge-ref base: VERIFIED' <<<"$OUT"; then
    ok "an unreadable merge ref is stated as NOT CHECKED and withholds nothing"
else
    bad "unread merge ref" "rc=$RC (want 0); $(tail -8 <<<"$OUT")"
fi

# T6d. THE rc-9 ARM DOES NOT ASSERT A GREEN IT CANNOT SEE (#846 x #823).
#
#      THE THIRD MERGE-ORDER SEAM ON THIS BRANCH, and the same geometry as the
#      first two: #823's STALE arm landed INSIDE the clearance `else`, above
#      every #846 statement in it, exactly as #868's rc-8 arm landed above the
#      #846 arms one level out. Neither PR is wrong alone.
#
#      WORSE THAN THE rc-8 GAP, and the distinction is the point. rc 8 OMITTED
#      a disclosure; this arm made a FALSE ASSERTION — "Every run at this head
#      is a first-pass success" — while a run at that head had concluded
#      `failure` having executed zero steps. It contradicted its own output:
#      the row table four lines above prints `NOT-STARTED ... concluded failure
#      having executed ZERO steps`. That is the rc-6 defect this branch already
#      fixed once, re-manufactured at a different arm by a different merge.
#
#      REACHABLE, and by the argument the final `else` already records: audit
#      rc 0 shuts arms 3-5, `pending_n > 0` shuts the `unexecuted` arm, and what
#      is left falls into the clearance `else` — where the stale check now sits
#      in front. The fixture below is that state, and it is the ONLY arm in the
#      chain that leaves by `exit` rather than by falling through, so a
#      disclosure appended at the end of the chain can never reach it.
export STUB_JOBS_DIR="$TMP/jobs.d"; mkdir -p "$STUB_JOBS_DIR"
printf 'monitor/ng\n' > "$STUB_CHANGED"
runs_json 4 "tests.yml:success" "tests-slow-integration.yml:success" \
            "docs.yml::in_progress" "cc-harness.yml:failure" > "$STUB_RUNS"
# ids are 100 + position, so cc-harness.yml — the aborted, NON-GATING run — is 103.
cat > "$STUB_JOBS_DIR/103.json" <<'JOBS'
{"total_count":1,"jobs":[{"name":"a","conclusion":"failure","steps":[],"runner_id":0,"runner_name":"","check_run_url":"https://api.github.com/repos/o/r/check-runs/931"}]}
JOBS
STUB_MRB_RUN=9001 STUB_MRB_JOB=8001 STUB_MRB_BASE="$MRB_NEW" \
STUB_MRB_LOG="HEAD is now at ec3412f Merge $MRB_HEAD into $MRB_OLD" \
    run_it 739
T6D_OUT="$OUT"; T6D_RC="$RC"
if (( RC == 9 )) && grep -q 'NOT CLEARED — the green describes a tree that' <<<"$OUT" \
   && grep -q 'that EXECUTED is a first-pass success' <<<"$OUT" \
   && ! grep -q 'Every run at this head is a first-pass success' <<<"$OUT" \
   && grep -q 'ALSO AT THIS HEAD' <<<"$OUT"; then
    ok "T6d rc 9 qualifies its green over EXECUTED runs and discloses the aborted one — the stale arm no longer asserts a green contradicted by its own row table"
else
    bad "823/846 T6d" "expected rc 9 with a qualified green + the unexecuted disclosure, got rc=$RC:
$OUT"
fi

# T6e. VACUITY CONTROL for T6d, and it is not optional: T6d asserts the ABSENCE
#      of a sentence, and an absence passes for free against any build where
#      the arm never ran at all — a mis-stubbed endpoint, a fixture that lands
#      on a different arm, a `die` before the chain. Restore the pre-fix arm
#      verbatim on the same fixture and confirm T6d's assertion FAILS.
SHADOW9="$TMP/shadow9"; mkdir -p "$SHADOW9"
for _f in ci-head-attempts.sh ci-observed-runs.jq ci-attempt-history.sh ci-trigger-audit.py ci-run-execution.sh _merge_ref_base.sh; do
    ln -sf "$_test_dir/$_f" "$SHADOW9/$_f"
done
rm -f "$SHADOW9/ci-head-attempts.sh"
python3 - "$_test_dir/ci-head-attempts.sh" "$SHADOW9/ci-head-attempts.sh" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
# Revert BOTH halves of the fix as one unit — the qualified sentence and the
# disclosure call. Reverting only one would leave a mutant that still carries
# half the fix, and T6d would pass against it for the surviving half.
old_q = """        if (( unexecuted )); then
            printf 'Every run at this head that EXECUTED is a first-pass success (%d ran\\n' "$unexecuted"
            printf 'nothing at all — see below), AND the merge ref they were computed\\n'
            printf 'against is stale: %s.\\n' "$_MRB_DETAIL"
        else
            printf 'Every run at this head is a first-pass success, AND the merge ref they\\n'
            printf 'were computed against is stale: %s.\\n' "$_MRB_DETAIL"
        fi
"""
new_q = """        printf 'Every run at this head is a first-pass success, AND the merge ref they\\n'
        printf 'were computed against is stale: %s.\\n' "$_MRB_DETAIL"
"""
old_n = "        _unexecuted_note\n        exit 9\n"
new_n = "        : # NEGATIVE-CONTROL MUTANT (rc-9 disclosure)\n        exit 9\n"
assert s.count(old_q) == 1, "rc-9 qualified-green anchor changed (%d)" % s.count(old_q)
assert s.count(old_n) == 1, "rc-9 _unexecuted_note anchor changed (%d)" % s.count(old_n)
open(dst, "w").write(s.replace(old_q, new_q).replace(old_n, new_n))
PY
if ! grep -q 'NEGATIVE-CONTROL MUTANT (rc-9 disclosure)' "$SHADOW9/ci-head-attempts.sh"; then
    bad "mutation apply rc9" "the rc-9 anchors changed; T6e no longer reverts the fix it is controlling for"
else
    OUT=$(PATH="$TMP/bin:$PATH" \
          STUB_MRB_RUN=9001 STUB_MRB_JOB=8001 STUB_MRB_BASE="$MRB_NEW" \
          STUB_MRB_LOG="HEAD is now at ec3412f Merge $MRB_HEAD into $MRB_OLD" \
          bash "$SHADOW9/ci-head-attempts.sh" 739 --repo your-org/nexus-code 2>&1); RC=$?
    if (( RC == 9 )) && grep -q 'Every run at this head is a first-pass success' <<<"$OUT" \
       && grep -q 'NOT-STARTED' <<<"$OUT" \
       && ! grep -q 'ALSO AT THIS HEAD' <<<"$OUT"; then
        ok "T6e mutant reproduces the seam — rc 9 asserting every run is a first-pass success while its OWN row table prints NOT-STARTED, which is what T6d would have passed against"
    else
        bad "823/846 T6e" "mutant did not reproduce the false assertion (rc=$RC); T6d proves nothing:
$OUT"
    fi
fi
unset STUB_JOBS_DIR
# Restore the fixture the cases below were written against.
printf 'monitor/ng\n' > "$STUB_CHANGED"

# T7. A RED IS STILL A RED, and outranks the coverage verdict — a failing band
#     must not be downgraded to "coverage incomplete".
runs_json 2 "tests.yml:failure" "tests-slow-integration.yml:success" > "$STUB_RUNS"
run_it 739
if (( RC == 5 )) && grep -q 'This head is RED' <<<"$OUT"; then
    ok "a live failure still reports RED (rc 5), not a coverage finding"
else
    bad "live red" "rc=$RC; $(tail -4 <<<"$OUT")"
fi

# T8. THE CHANGED-FILE ENUMERATION GUARD FIRES (skeptic F4). The PR reports
#     9 changed files; only 1 is listed. A short list silently SHRINKS the
#     expected set, turning a missing band into one that was never expected.
runs_json 2 "tests.yml:success" "tests-slow-integration.yml:success" > "$STUB_RUNS"
STUB_NFILES=9 run_it 739
if grep -q 'enumeration is INCOMPLETE' <<<"$OUT" \
   && grep -q 'expected-band audit did NOT run' <<<"$OUT"; then
    ok "changed-file enumeration guard fires on a short list"
else
    bad "changed-file guard" "rc=$RC; $(tail -5 <<<"$OUT")"
fi

# T9. AN UNREADABLE TALLY DISABLES NOTHING SILENTLY (skeptic F5). A
#     non-numeric `changedFiles` used to make the regex false, SKIP the
#     comparison, and let the audit proceed on an unvouched list — "could
#     not read the tally" collapsing into "the enumeration is fine". This
#     host runs gh 1.13.0 (#755), so it is not a hypothetical client.
STUB_NFILES=null run_it 739
if grep -q 'tally is UNREADABLE' <<<"$OUT" \
   && ! grep -q 'audit ALSO ran and is clean' <<<"$OUT"; then
    ok "unreadable changedFiles tally → audit skipped LOUDLY, never proceeded"
else
    bad "unreadable tally" "rc=$RC; $(tail -5 <<<"$OUT")"
fi

# T10. `--audit` MEANS "AUDITED OR REFUSED" (skeptic F3). Every skip cause
#      must honour the flag, not just the no-PR-context one. A caller
#      scripting `--audit && merge` merged on an audit that never ran.
for _spec in "9::short changed-file list" "null::unreadable tally"; do
    _n="${_spec%%::*}"; _why="${_spec##*::}"
    STUB_NFILES="$_n" run_it 739 --audit
    if (( RC == 2 )) && grep -q 'could not run' <<<"$OUT"; then
        ok "--audit refuses (rc 2) on: $_why"
    else
        bad "--audit on $_why" "rc=$RC; $(tail -3 <<<"$OUT")"
    fi
done
# …and a bare sha, the cause that was already honoured — kept so a
# regression there is caught too.
run_it "$SHA" --audit
if (( RC == 2 )) && grep -q 'could not run' <<<"$OUT"; then
    ok "--audit refuses (rc 2) on: no PR context"
else
    bad "--audit on bare sha" "rc=$RC; $(tail -3 <<<"$OUT")"
fi
# NEGATIVE CONTROL: --audit must still SUCCEED when the audit genuinely runs,
# or the three cases above would pass against a flag that always dies.
run_it 739 --audit
if (( RC == 0 )) && grep -q 'This head is cleared' <<<"$OUT"; then
    ok "--audit still clears a head whose audit actually ran (not always-die)"
else
    bad "--audit negative control" "rc=$RC; $(tail -4 <<<"$OUT")"
fi

# ===========================================================================
# T11–T13. A HEAD THAT HAS NOT CONCLUDED IS NOT A CLEARED HEAD
#          (your-org/nexus-code#762).
#
# The per-row output has always printed `.... still in_progress — no verdict
# yet`, so the information was never missing; the SUMMARY contradicted it,
# because "every completed run at this head is a FIRST-PASS success" is
# quantified over the concluded subset and is vacuously true when that subset
# is empty. Observed live on PR #758's own head with all three bands running.
# ===========================================================================
echo
echo "== ng ci-attempts: a head that has not concluded (#762) =="

# T11. NO run has concluded. The vacuous-green shape, exactly.
runs_json 2 "tests.yml::in_progress" "tests-slow-integration.yml::in_progress" > "$STUB_RUNS"
run_it 739
if (( RC == 3 )) && grep -q 'NOT CLEARED' <<<"$OUT" \
   && grep -q 'EMPTY SET' <<<"$OUT" \
   && ! grep -q 'This head is cleared' <<<"$OUT" \
   && ! grep -q 'every completed run at this head is a FIRST-PASS success' <<<"$OUT"; then
    ok "all bands in_progress → rc 3 NOT CLEARED, never 'cleared' over an empty concluded set"
else
    bad "all-pending head" "expected rc 3 + NOT CLEARED + empty-set language, got rc=$RC; $(tail -8 <<<"$OUT")"
fi

# T12. SOME concluded, some not — partial and provisional, and the pending
#      band is NAMED. A count would leave the reader unable to act.
runs_json 2 "tests.yml:success" "tests-slow-integration.yml::in_progress" > "$STUB_RUNS"
run_it 739
if (( RC == 3 )) && grep -q 'PARTIAL and PROVISIONAL' <<<"$OUT" \
   && grep -q 'tests-slow-integration.yml' <<<"$OUT" \
   && ! grep -q 'This head is cleared' <<<"$OUT"; then
    ok "1 of 2 concluded → rc 3, partial and provisional, the pending band named"
else
    bad "partial head" "expected rc 3 + PARTIAL and PROVISIONAL, got rc=$RC; $(tail -8 <<<"$OUT")"
fi

# T13. THE CONTROL. Same two bands, both CONCLUDED green → the clearance is
#      still given. Without this, T11/T12 could be passing because the verb
#      stopped clearing anything at all.
runs_json 2 "tests.yml:success" "tests-slow-integration.yml:success" > "$STUB_RUNS"
run_it 739
if (( RC == 0 )) && grep -q 'This head is cleared' <<<"$OUT"; then
    ok "both bands concluded green → rc 0, still cleared — T11/T12 red on PENDING, not on everything"
else
    bad "pending control" "expected rc 0 + cleared, got rc=$RC; $(tail -6 <<<"$OUT")"
fi

# ===========================================================================
# T14–T16. A CONFLICTED PR GETS ZERO CHECK-RUNS BY CONSTRUCTION
#          (your-org/nexus-code#773).
#
# The empty observed set had three named causes and this is a fourth. It used
# to land in the outage arm and point the reader at GitHub — which on PR #744
# produced the diagnosis "Actions stopped creating runs repo-wide" while
# another PR had 13 runs at the same moment.
# ===========================================================================
echo
echo "== ng ci-attempts: a conflicted PR (#773) =="

# T14. dirty + zero runs → the conflict arm, its own exit code, and a remedy
#      that names the rebase rather than the provider.
runs_json 0 > "$STUB_RUNS"
STUB_MERGEABLE=dirty run_it 739
if (( RC == 7 )) && grep -q 'CONFLICTED' <<<"$OUT" \
   && grep -q 'refs/pull/739/merge' <<<"$OUT" \
   && grep -qi 'rebase' <<<"$OUT" \
   && ! grep -q 'CAUSE: bands WERE expected' <<<"$OUT"; then
    # The negative half matches the outage ARM's own opening line, not the
    # word "outage" — this arm says "This is NOT an outage" on purpose, and an
    # assertion that forbids the word would forbid the disambiguation too.
    ok "dirty + zero runs → rc 7 CONFLICTED, naming the merge ref and the rebase, NOT the outage arm"
else
    bad "dirty PR" "expected rc 7 + conflict arm without outage language, got rc=$RC; $(tail -10 <<<"$OUT")"
fi

# T15. THE DISCRIMINATION IS REAL, not a relabelling. The SAME zero-run input
#      with a NON-dirty PR must still reach the outage-shaped arm. If both
#      inputs produced the conflict verdict, T14 would be measuring nothing —
#      and if both produced the outage verdict, the arm would be dead code.
runs_json 0 > "$STUB_RUNS"
STUB_MERGEABLE=clean run_it 739
if (( RC == 4 )) && grep -q 'outage' <<<"$OUT" \
   && ! grep -q 'CONFLICTED' <<<"$OUT"; then
    ok "same zero-run input, clean PR → still rc 4 outage-shaped — the arm discriminates, not relabels"
else
    bad "clean-PR control" "expected rc 4 outage arm, got rc=$RC; $(tail -8 <<<"$OUT")"
fi

# T16. `unknown` IS NOT `not dirty`. GitHub computes mergeability in a
#      background job and answers `unknown` until it lands, so reading that as
#      "not conflicted" is the could-not-look/nothing-was-wrong substitution
#      this whole file exists to refuse. It must be SAID, not assumed away.
runs_json 0 > "$STUB_RUNS"
STUB_MERGEABLE=unknown run_it 739
if grep -q 'could NOT be read' <<<"$OUT" \
   && grep -q 'ZERO Actions runs by construction' <<<"$OUT" \
   && (( RC != 7 )); then
    ok "mergeable_state=unknown → the caveat is stated and the conflict is neither claimed nor ruled out"
else
    bad "unknown mergeable_state" "expected a stated caveat and no conflict claim, got rc=$RC; $(tail -8 <<<"$OUT")"
fi

# T17. THE COST CLAIM IS CHECKED, NOT ASSERTED. `#773` supposed
#      `mergeable_state` was already fetched on this path; it was not, so this
#      discrimination costs a real API call and the PR says "one, lazily, and
#      cached". A claim about cost that nothing measures is the same species as
#      a claim about coverage that nothing measures.
#
#      WHAT THIS DOES NOT PIN, said plainly. It does NOT exercise the cache.
#      The two call sites are mutually exclusive by construction (the empty-set
#      arm exits; the missing-band arm is only reached when runs exist), so no
#      current path consults twice and a call count of 1 is what BOTH a working
#      cache and a broken one produce. The cache is correct and latent — it
#      guards a future second call site, not a present cost — and saying so is
#      the point: a test named after a mechanism it cannot distinguish would be
#      exactly the substitution this suite is about.
export STUB_CALLS="$TMP/pulls-calls.txt"
: > "$STUB_CALLS"
runs_json 0 > "$STUB_RUNS"
STUB_MERGEABLE=dirty run_it 739
_ncalls=$(awk 'NF { n++ } END { print n+0 }' "$STUB_CALLS")
if (( RC == 7 )) && (( _ncalls == 1 )); then
    ok "the conflict lookup costs exactly ONE API call on the path that uses it"
else
    bad "mergeable_state call count" "expected rc 7 and exactly 1 /pulls/ call, got rc=$RC ncalls=$_ncalls"
fi

# T18. …and ZERO on the cleared path, which is the "lazily" half. A lookup
#      spent on every invocation would be a cost this PR did not disclose.
: > "$STUB_CALLS"
runs_json 2 "tests.yml:success" "tests-slow-integration.yml:success" > "$STUB_RUNS"
run_it 739
_ncalls=$(awk 'NF { n++ } END { print n+0 }' "$STUB_CALLS")
if (( RC == 0 )) && (( _ncalls == 0 )); then
    ok "a cleared head spends NO conflict lookup — the call is lazy, not ambient"
else
    bad "lazy lookup" "expected rc 0 and 0 /pulls/ calls, got rc=$RC ncalls=$_ncalls"
fi
unset STUB_CALLS

# ===========================================================================
# T19-T20. UNGATED IS A REFUSAL ON THE MERGE PATH (your-org/nexus-code#856).
#
# The same audit state that ci-signal.yml maps to a green warning must be a
# REFUSAL here, because the two readers want opposite things from it: ci-signal
# is a peer check that must not redden a legitimate docs-only PR, and this verb
# is the merge-path reader whose entire job is to withhold a clearance nobody
# earned. That split already exists for rc 3 and is the reason it is a split.
#
# The fixture workflows are all `paths:`-filtered, so a README-only diff selects
# NONE of them and the real audit returns 8. `docs.yml` supplies a run so the
# empty-observed arm above does not claim the case first.
# ===========================================================================
echo
echo "== ng ci-attempts: a diff nothing examined (#856) =="
printf 'README.md\n' > "$STUB_CHANGED"
runs_json 1 "docs.yml:success" > "$STUB_RUNS"
run_it 739
if (( RC == 8 )) && grep -q 'NOT CLEARED — nothing examined your change' <<<"$OUT" \
   && grep -q 'satisfied VACUOUSLY' <<<"$OUT" \
   && ! grep -q 'every completed run at this head is a FIRST-PASS success' <<<"$OUT"; then
    ok "an unexamined diff is rc 8 REFUSED here — the merge-path reader withholds what ci-signal only warns about"
else
    bad "856 T19" "expected rc 8 + a refusal naming the vacuous quantifier, got rc=$RC:
$OUT"
fi

# T19b. THE rc-8 ARM DISCLOSES UNEXECUTED RUNS LIKE EVERY SIBLING ARM.
#
#       A MERGE-QUEUE INTERACTION, not a defect of either PR. This arm arrived
#       from #856/#868 and, on rebase, landed ABOVE every #846 arm in the same
#       verdict chain — where its siblings all call `_unexecuted_note` and it
#       did not. Neither PR was wrong in isolation; the gap exists only where
#       they meet, and only surfaced because this branch rebased onto the other
#       AFTER it merged.
#
#       REACHABLE, not theorised: `unexecuted` is counted over EVERY run at the
#       head, including non-gating ones, while rc 8 is a statement about the
#       GATING set. So a non-gating band can have concluded `failure` with zero
#       steps while the gating set is UNGATED — which is this fixture.
#
#       Severity is bounded and the assertion says so by what it does NOT
#       claim: rc 8 already withholds clearance, so this could never open a
#       merge. It is a disclosure gap, and a chain where one arm omits what its
#       siblings disclose is what makes a reader distrust all of them.
export STUB_JOBS_DIR="$TMP/jobs.d"; mkdir -p "$STUB_JOBS_DIR"
printf 'README.md\n' > "$STUB_CHANGED"
runs_json 2 "docs.yml:success" "cc-harness.yml:failure" > "$STUB_RUNS"
cat > "$STUB_JOBS_DIR/101.json" <<'JOBS'
{"total_count":1,"jobs":[{"name":"a","conclusion":"failure","steps":[],"runner_id":0,"runner_name":"","check_run_url":"https://api.github.com/repos/o/r/check-runs/931"}]}
JOBS
run_it 739
T19B_OUT="$OUT"; T19B_RC="$RC"
if (( RC == 8 )) && grep -q 'NOT CLEARED — nothing examined your change' <<<"$OUT" \
   && grep -q 'ALSO AT THIS HEAD' <<<"$OUT" \
   && grep -q 'executed ZERO' <<<"$OUT"; then
    ok "T19b rc 8 discloses the unexecuted run like every sibling arm — the rebase-introduced gap is closed"
else
    bad "856/846 T19b" "expected rc 8 WITH the unexecuted disclosure, got rc=$RC:
$OUT"
fi

# T19c. VACUITY CONTROL for T19b. Delete the one call that carries the
#       disclosure into this arm — exactly the post-rebase state — and confirm
#       T19b's assertion FAILS. Without this, T19b would pass against a build
#       where some OTHER arm happened to print the note.
SHADOW8="$TMP/shadow8"; mkdir -p "$SHADOW8"
# `_merge_ref_base.sh` is in this list because of the SAME #846 x #823 seam as
# the stub arm above: #823 made it a HARD, fail-closed dependency of
# ci-head-attempts.sh (`die` if unreadable), and these shadow trees predate it,
# so every mutation control silently degraded into "the verb refused to start"
# — rc 2, not the rc the control is about. A vacuity control that dies before
# reaching its subject proves nothing, which is exactly what it exists to
# prevent.
for _f in ci-head-attempts.sh ci-observed-runs.jq ci-attempt-history.sh ci-trigger-audit.py ci-run-execution.sh _merge_ref_base.sh; do
    ln -sf "$_test_dir/$_f" "$SHADOW8/$_f"
done
rm -f "$SHADOW8/ci-head-attempts.sh"
# Target the `_unexecuted_note` IMMEDIATELY PRECEDING `rc=8`, as a pair. A
# first attempt keyed on "the first note after seeing rc=8", but the call comes
# BEFORE the assignment, so the flag tripped too late and it mutated a sibling
# arm — leaving the arm under test intact and the control passing vacuously.
# Anchoring on the adjacent pair is what makes the mutation hit this arm only.
python3 - "$_test_dir/ci-head-attempts.sh" "$SHADOW8/ci-head-attempts.sh" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = "    _unexecuted_note\n    rc=8\n"
new = "    : # NEGATIVE-CONTROL MUTANT (rc-8 disclosure)\n    rc=8\n"
assert s.count(old) == 1, "expected exactly one `_unexecuted_note` + `rc=8` pair, got %d" % s.count(old)
open(dst, "w").write(s.replace(old, new))
PY
if ! grep -q 'NEGATIVE-CONTROL MUTANT (rc-8 disclosure)' "$SHADOW8/ci-head-attempts.sh"; then
    bad "mutation apply rc8" "the rc-8 _unexecuted_note anchor changed; the vacuity control no longer applies"
else
    OUT=$(PATH="$TMP/bin:$PATH" bash "$SHADOW8/ci-head-attempts.sh" 739 --repo your-org/nexus-code 2>&1); RC=$?
    if (( RC == 8 )) && ! grep -q 'ALSO AT THIS HEAD' <<<"$OUT"; then
        ok "T19c mutant reproduces the post-rebase gap — rc 8 without the disclosure, which is what T19b would have passed against"
    else
        bad "856/846 T19c" "mutant did not reproduce the disclosure gap (rc=$RC); T19b proves nothing:
$OUT"
    fi
fi
unset STUB_JOBS_DIR

# T20. THE CONTROL: restore a covered diff and the same verb clears at rc 0.
# Without it, T19 could be passing because the verb refuses everything.
printf 'monitor/ng\n' > "$STUB_CHANGED"
runs_json 2 "tests.yml:success" "tests-slow-integration.yml:success" > "$STUB_RUNS"
run_it 739
if (( RC == 0 )) && ! grep -q 'nothing examined your change' <<<"$OUT"; then
    ok "…and a covered diff still clears at rc 0 — T19 keys on content-selection, not on everything"
else
    bad "856 T20" "expected rc 0 on a covered diff, got rc=$RC:
$OUT"
fi

# T21. THE GH STUB'S HEREDOC IS UNQUOTED (`<<EOF`), so a backtick inside it is a
# COMMAND SUBSTITUTION performed while the stub is being written — it runs the
# quoted word, prints `command not found` to stderr, and silently DELETES the
# word from the generated stub. This branch shipped three such comments; they
# were harmless only because the text sat in comments the stub never reads.
#
# It is asserted rather than left to review because of HOW it survived: the
# suite still printed ALL TESTS PASSED (25), and the diagnostics went to stderr
# where a `tail` of stdout never showed them. A green with errors underneath it
# is this repo's own dominant defect shape, and it was sitting inside the suite
# for the PR about CI verdict honesty (your-org/nexus-code#823).
#
# THE READER DRAINS, and this line is its own cautionary tale. It was first
# written `awk … | grep -qE …` — an EARLY-EXIT READER: `grep -q` closes the pipe
# on its first match and SIGPIPEs `awk`, which under `pipefail` is a FALSE
# FAILURE. That is the exact defect class `_merge_ref_base.sh` discusses at
# length two files away, committed while adding a guard against a different
# footgun, and `test-sigpipe-assertion-lint.sh` caught it — six of six unit-suite
# bands red. The here-string form below drains the producer fully.
if ! grep -qE '[^\\]`' <<<"$(awk '/^cat > "\$TMP\/bin\/gh" <<EOF$/,/^EOF$/' "${BASH_SOURCE[0]}")"; then
    ok "the gh-stub heredoc escapes every backtick — nothing is command-substituted while writing the stub"
else
    bad "stub heredoc" "an unescaped backtick inside the unquoted <<EOF will be command-substituted at stub-write time"
fi

# ===========================================================================
# T19-T22. A `failure` THAT EXECUTED NOTHING IS NOT A LIVE RED
#          (your-org/nexus-code#846).
#
# THE DEFECT AT THIS SURFACE. This verb has its own per-row loop, and it set
# `live_red=1` on `conclusion == failure` alone — so `ng ci-attempts 837`
# returned exit 5 and told the reader "this head is RED", for a run GitHub
# aborted before starting a single job. That is the exact invocation named in
# the issue. Fixing only ci-trigger-audit.py would have left this verb — the
# one an AGENT actually runs on the merge path — still saying 5.
#
# The three cases vary ONE thing: the jobs payload behind an identical
# `failure` run. Everything else is held constant, so the exit code moves
# because of the execution evidence and nothing else.
# ===========================================================================
echo
echo "== ng ci-attempts: a failure that never started (#846) =="
runs_json 2 "tests.yml:failure" "tests-slow-integration.yml:success" > "$STUB_RUNS"

# T19. The live shape, transcribed from run 31281274254 on this repo
#      (2026-08-08, the account-billing block).
export STUB_JOBS="$TMP/jobs.json"
cat > "$STUB_JOBS" <<'JOBS'
{"total_count":2,"jobs":[
  {"name":"a","conclusion":"failure","steps":[],"runner_id":0,"runner_name":"","check_run_url":"https://api.github.com/repos/o/r/check-runs/931"},
  {"name":"b","conclusion":"failure","steps":[],"runner_id":0,"runner_name":""}]}
JOBS
run_it 739
if (( RC == 4 )) && grep -q 'NOT-STARTED' <<<"$OUT" \
   && grep -q 'executed ZERO steps' <<<"$OUT" \
   && grep -q 'account payments have failed' <<<"$OUT" \
   && ! grep -q 'This head is RED' <<<"$OUT"; then
    ok "a failure whose jobs ran zero steps → rc 4 NOT-STARTED, naming the account cause, never 'this head is RED'"
else
    bad "846 T19" "expected rc 4 + NOT-STARTED, got rc=$RC:
$OUT"
fi

# T20. THE CONTROL, and the one that matters. Same run, same conclusion, a jobs
#      payload showing steps having run: back to a live red at rc 5. Without
#      this, T19 could be passing because the verb reds nothing any more.
cat > "$STUB_JOBS" <<'JOBS'
{"total_count":1,"jobs":[
  {"name":"a","conclusion":"failure","steps":[{"number":1},{"number":2}],"runner_id":7,"runner_name":"GitHub Actions 7"}]}
JOBS
run_it 739
if (( RC == 5 )) && grep -q 'This head is RED' <<<"$OUT" \
   && ! grep -q 'NOT-STARTED' <<<"$OUT"; then
    ok "the SAME failure with steps executed → rc 5 RED — T19's downgrade is the evidence, not a blanket amnesty"
else
    bad "846 T20" "expected rc 5 + live red, got rc=$RC:
$OUT"
fi

# T21. THE UNDECIDABLE CASE, which is the whole hazard of this change: a
#      plumbing gap misread as a code red costs a misrouted reader, while a
#      code red misread as a plumbing gap merges broken code. So a payload
#      that cannot be read must stay at rc 5.
cat > "$STUB_JOBS" <<'JOBS'
{"total_count":1,"jobs":[{"name":"a","conclusion":"failure","runner_id":0,"runner_name":""}]}
JOBS
run_it 739
if (( RC == 5 )) && grep -q 'This head is RED' <<<"$OUT" \
   && ! grep -q 'NOT-STARTED' <<<"$OUT"; then
    ok "a jobs payload with no \`steps\` array stays rc 5 RED — 'no steps data' is not 'zero steps executed'"
else
    bad "846 T21" "expected rc 5 on an unreadable jobs payload, got rc=$RC:
$OUT"
fi

# T22. And with the jobs endpoint unreadable (the stub refuses /jobs), the verb
#      must degrade to the PRE-#846 verdict — rc 5 — not to a softer one.
#
#      SCOPE, narrowed after the PR #854 delta review (G1). This drives the
#      enricher SUCCEEDING with `unknown` evidence — it exits 0, having been
#      unable to read the jobs API. It does NOT drive the `else` fallback in
#      ci-head-attempts.sh, where the enricher itself fails to run; that is
#      T28. The two are adjacent and were briefly conflated: this case's own
#      comment used to claim it covered "the ci-signal.yml and
#      ci-head-attempts.sh fallbacks both", which was a quantifier over two
#      branches with evidence for neither of them.
unset STUB_JOBS
run_it 739
if (( RC == 5 )) && grep -q 'This head is RED' <<<"$OUT" \
   && ! grep -q 'NOT-STARTED' <<<"$OUT"; then
    ok "with execution evidence UNAVAILABLE the verb degrades to rc 5 — the fallback direction is RED, as claimed"
else
    bad "846 T22" "expected rc 5 when the jobs endpoint is unreachable, got rc=$RC:
$OUT"
fi

# T23. THE MIXED HEAD — the case this verb's own comment makes a claim about
#      and T19-T22 structurally cannot see, because each of them varies a
#      SINGLE failing run. ci-head-attempts.sh asserts the NOT-STARTED arm is
#      "reached only when EVERY failing run at this head is positively known to
#      have executed nothing — one run whose evidence merely could not be read
#      sets `live_red` above instead". Here two bands fail, one aborted before
#      starting and one genuinely red, and the head must be RED: an aborted run
#      cannot excuse a real red standing beside it.
export STUB_JOBS_DIR="$TMP/jobs.d"; mkdir -p "$STUB_JOBS_DIR"
runs_json 3 "tests.yml:failure" "tests-slow-integration.yml:failure" "conflict-markers.yml:success" > "$STUB_RUNS"
# run 100 = tests.yml: never started.       run 101 = slow band: a real red.
cat > "$STUB_JOBS_DIR/100.json" <<'JOBS'
{"total_count":1,"jobs":[{"name":"a","conclusion":"failure","steps":[],"runner_id":0,"runner_name":""}]}
JOBS
cat > "$STUB_JOBS_DIR/101.json" <<'JOBS'
{"total_count":1,"jobs":[{"name":"a","conclusion":"failure","steps":[{"number":1}],"runner_id":9,"runner_name":"GitHub Actions 9"}]}
JOBS
run_it 739
if (( RC == 5 )) && grep -q 'This head is RED' <<<"$OUT" \
   && grep -q 'NOT-STARTED' <<<"$OUT" \
   && grep -q 'AND SEPARATELY' <<<"$OUT"; then
    ok "a MIXED head (one run aborted, one genuinely red) is rc 5 RED — and BOTH facts are reported, so fixing one does not hide the other"
else
    bad "846 T23" "expected rc 5 reporting both the red and the aborted run, got rc=$RC:
$OUT"
fi

# T24. THE AMBIGUOUS RUN, the other half of "could not tell stays RED": zero
#      steps but a runner WAS assigned. The two signals disagree, so the
#      evidence is `unknown` and the head stays at rc 5 rather than reaching
#      the NOT-STARTED arm on the strength of the steps count alone.
runs_json 2 "tests.yml:failure" "conflict-markers.yml:success" > "$STUB_RUNS"
cat > "$STUB_JOBS_DIR/100.json" <<'JOBS'
{"total_count":1,"jobs":[{"name":"a","conclusion":"failure","steps":[],"runner_id":9,"runner_name":"GitHub Actions 9"}]}
JOBS
run_it 739
if (( RC == 5 )) && grep -q 'This head is RED' <<<"$OUT" \
   && ! grep -q 'NOT-STARTED' <<<"$OUT"; then
    ok "zero steps but a runner WAS assigned → still rc 5 RED — the downgrade needs both signals, not just the step count"
else
    bad "846 T24" "expected rc 5 on ambiguous evidence, got rc=$RC:
$OUT"
fi
# T25. AN ABORTED RUN BESIDE AN IN-FLIGHT ONE IS PENDING, NOT A PLUMBING
#      VERDICT (PR `#854` skeptic, F1).
#
#      THE DEFECT THIS PINS. `classify_runs()` in ci-trigger-audit.py ranks
#      UNEXECUTED below PENDING and fixture 17g tests it — but THIS file, the
#      surface a human actually reads, had its `unexecuted` arm ABOVE every
#      pending arm. For one aborted run beside one still executing it printed
#      "it will NOT clear by waiting" and "no diff can address it" two lines
#      below its own "still in_progress — no verdict yet". Both false while a
#      run is running.
#
#      The PR body asserted the precedence of BOTH implementations on the
#      strength of having verified the PYTHON one. `in_progress` appeared in
#      this suite only in all-pending and all-success cases, never beside an
#      unexecuted run — so nothing here could have caught the drift. That gap
#      is what this case closes, and it is the your-org/nexus-code#836 shape:
#      a property verified on one implementation and asserted of both.
#      The OTHER gating band is given a `success` deliberately. The first draft
#      of this fixture left `tests-slow-integration.yml` with no run at all, so
#      the audit red at rc 4 for a MISSING BAND and the case measured that
#      instead — it would have passed against a build that still carried the
#      defect, for a reason unrelated to the property. Isolate the variable.
export STUB_JOBS_DIR="$TMP/jobs.d"; mkdir -p "$STUB_JOBS_DIR"
runs_json 3 "tests.yml:failure" "tests.yml::in_progress" "tests-slow-integration.yml:success" > "$STUB_RUNS"
cat > "$STUB_JOBS_DIR/100.json" <<'JOBS'
{"total_count":1,"jobs":[{"name":"a","conclusion":"failure","steps":[],"runner_id":0,"runner_name":""}]}
JOBS
run_it 739
if (( RC == 3 )) && grep -q 'NOT CLEARED' <<<"$OUT" \
   && ! grep -q 'no diff can address' <<<"$OUT" \
   && ! grep -q 'NOT because of your code' <<<"$OUT"; then
    ok "an aborted run beside an in-flight one is rc 3 PENDING — the verb no longer tells a reader to stop waiting while a run is executing"
else
    bad "846 T25" "expected rc 3 with no stop-waiting advice, got rc=$RC:
$OUT"
fi

# T26. …and losing the precedence must not lose the FACT. A reader told only
#      "still in progress" would fix the wait and be ambushed by the billing
#      block. The winning arm names the aborted run without letting it drive
#      the verdict.
if grep -q 'ALSO AT THIS HEAD' <<<"$OUT" \
   && grep -q 'does NOT drive the verdict above' <<<"$OUT" \
   && grep -q 'NOT-STARTED' <<<"$OUT"; then
    ok "…and the aborted run is still REPORTED under the pending verdict — precedence lost, disclosure kept"
else
    bad "846 T26" "the pending verdict hid the aborted run entirely:
$OUT"
fi

# T27. THE COMPOSITE that defeated the first TWO fixes: an aborted run, an
#      in-flight run, AND a genuinely missing third band. The audit reds at
#      rc 4 for the missing band, so neither "reorder below the pending arms"
#      nor "guard the audit arm on `unexecuted == 0`" was sufficient — each let
#      the `unexecuted` arm catch this and tell the reader to stop waiting while
#      a run was still executing. The verdict here is the audit's (rc 4, a band
#      really is missing); what must NOT appear is the stop-waiting advice.
runs_json 2 "tests.yml:failure" "tests.yml::in_progress" > "$STUB_RUNS"
run_it 739
if (( RC == 4 )) && ! grep -q 'no diff can address' <<<"$OUT" \
   && ! grep -q 'NOT because of your code' <<<"$OUT" \
   && grep -q 'ALSO AT THIS HEAD' <<<"$OUT"; then
    ok "aborted + in-flight + a missing band → rc 4 on the AUDIT's finding, aborted run disclosed, and still no stop-waiting advice while a run executes"
else
    bad "846 T27" "expected rc 4 with disclosure and no stop-waiting advice, got rc=$RC:
$OUT"
fi
unset STUB_JOBS_DIR

# T28. THE `else` FALLBACK ITSELF: the enricher FAILS TO RUN (PR `#854` delta
#      review, G1).
#
#      WHY THIS EXISTS. The PR asserted the degradation direction of BOTH call
#      sites — ci-signal.yml's and this file's — and cited T22, which drives
#      neither `else` branch: it drives the enricher SUCCEEDING with `unknown`
#      evidence. A quantifier over two branches with evidence for a third,
#      adjacent one. That is the same shape as F1 (a property true of
#      ci-trigger-audit.py asserted of both implementations), reproduced inside
#      the fix aimed at it — which is what this defect class does, and why it
#      gets a fixture rather than a sentence.
#
#      "UNTESTABLE HERE" WAS A PROPERTY OF THE HARNESS, NOT OF THE CODE.
#      ci-head-attempts.sh calls `bash "$_here/ci-run-execution.sh"`, and
#      `_here` is the dirname of the script AS INVOKED — bash does not resolve
#      symlinks in BASH_SOURCE. So running a shadow directory of symlinks, with
#      one failing stub in place of the enricher, drives the branch against the
#      REAL script. No production code was made testable-only.
SHADOW="$TMP/shadow"; mkdir -p "$SHADOW"
# `_merge_ref_base.sh`: the #846 x #823 seam again — see SHADOW8 above.
for _f in ci-head-attempts.sh ci-observed-runs.jq ci-attempt-history.sh ci-trigger-audit.py _merge_ref_base.sh; do
    ln -sf "$_test_dir/$_f" "$SHADOW/$_f"
done
printf '#!/usr/bin/env bash\nexit 2\n' > "$SHADOW/ci-run-execution.sh"
chmod +x "$SHADOW/ci-run-execution.sh"

runs_json 2 "tests.yml:failure" "tests-slow-integration.yml:success" > "$STUB_RUNS"
OUT=$(PATH="$TMP/bin:$PATH" bash "$SHADOW/ci-head-attempts.sh" 739 --repo your-org/nexus-code 2>&1); RC=$?
if (( RC == 5 )) && grep -q 'could not read execution evidence' <<<"$OUT" \
   && grep -q 'unmeasured, not' <<<"$OUT" \
   && ! grep -q 'NOT-STARTED' <<<"$OUT"; then
    ok "the enricher FAILING to run degrades to the pre-#846 verdict (rc 5) and says so — a worse MESSAGE, never a softer VERDICT"
else
    bad "846 T28" "expected rc 5 + the fallback NOTE, got rc=$RC:
$OUT"
fi

# T28b. THE VACUITY CONTROL for T28. A fallback arm is only evidence if the
#       SUCCEEDING arm produces a different answer on the same input — otherwise
#       T28 would pass against a build where the enricher is never consulted at
#       all. Same shadow tree, same runs, enricher restored to the real one.
ln -sf "$_test_dir/ci-run-execution.sh" "$SHADOW/ci-run-execution.sh"
export STUB_JOBS="$TMP/jobs.json"
cat > "$STUB_JOBS" <<'JOBS'
{"total_count":1,"jobs":[{"name":"a","conclusion":"failure","steps":[],"runner_id":0,"runner_name":"","check_run_url":"https://api.github.com/repos/o/r/check-runs/931"}]}
JOBS
OUT=$(PATH="$TMP/bin:$PATH" bash "$SHADOW/ci-head-attempts.sh" 739 --repo your-org/nexus-code 2>&1); RC=$?
if (( RC == 4 )) && grep -q 'NOT-STARTED' <<<"$OUT" \
   && ! grep -q 'could not read execution evidence' <<<"$OUT"; then
    ok "…and with the REAL enricher on the same input the answer is rc 4 NOT-STARTED — T28's rc 5 is the fallback firing, not the shadow tree being inert"
else
    bad "846 T28b" "expected rc 4 NOT-STARTED with the real enricher, got rc=$RC:
$OUT"
fi
unset STUB_JOBS

echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d)\n' "$PASS"
else
    printf '%d passed, %d FAILED\n' "$PASS" "$FAIL"
fi
(( FAIL == 0 ))
