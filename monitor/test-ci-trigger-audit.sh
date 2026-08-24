#!/usr/bin/env bash
# test-ci-trigger-audit.sh — the #604 guard, exercised against the exact PR
# shape that was silently CI-exempt (your-org/nexus-code#604).
#
# WHAT IS BEING GUARDED. `on: pull_request: branches: [main, dev]` filters the
# BASE branch. #593's base was `operator/fix-581-overlimit-reset-ratchet`, a
# feature branch, so every gating workflow stayed silent, the PR collected zero
# checks, and `gh pr view` reported MERGEABLE with an empty statusCheckRollup —
# indistinguishable, at the point of decision, from all-green.
#
# EVERY ASSERTION BELOW MATCHES THE MESSAGE, NOT MERELY THE EXIT CODE. An exit
# code says a guard fired; only the message says it fired for the reason
# claimed. (A guard that exits 1 because PyYAML is missing "passes" an
# exit-code test while checking nothing at all.)
#
# Run: bash monitor/test-ci-trigger-audit.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/.." && pwd)
AUDIT="$_test_dir/ci-trigger-audit.py"
REAL_WF="$REPO_ROOT/.github/workflows"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 unavailable — the audit cannot be exercised here."
    echo "(This is a declined run, not a pass: nothing below was asserted.)"
    exit 0
fi
if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "SKIP: PyYAML unavailable — the audit cannot be exercised here."
    echo "(This is a declined run, not a pass: nothing below was asserted.)"
    exit 0
fi

# run_audit <workdir> <base-ref> <changed-file> [<observed-file>] [<self>]
# Sets OUT and RC.
run_audit() {
    local wf="$1" base="$2" changed="$3" observed="${4:-}" self="${5:-ci-signal.yml}"
    local args=(--workflows-dir "$wf" --base-ref "$base"
                --changed-files "$changed" --self-workflow "$self")
    [[ -n "$observed" ]] && args+=(--observed "$observed")
    OUT=$(python3 "$AUDIT" "${args[@]}" 2>&1); RC=$?
}

# ===========================================================================
# 0. PREMISE. The parser's least obvious hazard, proven executably rather than
#    asserted in a comment: YAML 1.1 resolves the bare key `on` to the BOOLEAN
#    True, so every workflow parses with True — not "on" — as its trigger key.
#    Code that reads doc["on"] finds nothing and concludes, wrongly and
#    silently, that no workflow gates anything.
# ===========================================================================
echo "--- 0. premise: YAML resolves \`on:\` to a boolean ---"
premise=$(python3 - <<'PY'
import yaml
d = yaml.safe_load("on:\n  pull_request:\n    branches: [main]\n")
print("string_key=%s bool_key=%s" % ("on" in d, True in d))
PY
)
if [[ "$premise" == "string_key=False bool_key=True" ]]; then
    ok "the \`on:\`→True trap is real ($premise) — the audit handles both keys"
elif [[ "$premise" == "string_key=True bool_key=False" ]]; then
    ok "this PyYAML keeps \`on\` as a string ($premise) — audit accepts both, still correct"
else
    bad "premise" "unexpected PyYAML key resolution: $premise"
fi

# ===========================================================================
# 1. THE #593 NEGATIVE CONTROL, against the REAL workflow files.
#
#    Reconstructed from the issue: base = the feature branch it was stacked
#    on, changed files = its four monitor/watcher/*.sh, observed runs = none.
#    This is the shape that read as MERGEABLE-and-green.
#
#    The assertion is deliberately written as an INVARIANT rather than a
#    hard-coded verdict: whichever way the real tests.yml is configured, this
#    shape must NOT come back clean. If tests.yml keeps `branches:` the
#    verdict is TRIGGER-GAP; if a future change drops it, the verdict becomes
#    MISSING-RUN. Both are loud, and pinning either one would make this test
#    fail for a *fix*. Case 2 pins the exact TRIGGER-GAP wording on a fixture,
#    where it cannot rot.
# ===========================================================================
echo "--- 1. the #593 shape must never audit clean (real workflows) ---"
cat > "$TMP/changed-593.txt" <<'EOF'
monitor/watcher/main.sh
monitor/watcher/_lib.sh
monitor/watcher/_unstick.sh
monitor/watcher/_github.sh
EOF
: > "$TMP/observed-none.txt"
run_audit "$REAL_WF" "operator/fix-581-overlimit-reset-ratchet" \
          "$TMP/changed-593.txt" "$TMP/observed-none.txt"
if (( RC == 0 )); then
    bad "#593 shape" "audit returned CLEAN (rc 0) on the exact shape that was silently unchecked:
$OUT"
elif grep -q 'TRIGGER-GAP\|MISSING-RUN' <<<"$OUT"; then
    verdict=$(grep -o 'TRIGGER-GAP\|MISSING-RUN' <<<"$OUT" | head -1)
    ok "#593 shape is caught as $verdict (rc=$RC), not reported clean"
else
    bad "#593 shape" "rc=$RC but no TRIGGER-GAP/MISSING-RUN finding in output:
$OUT"
fi

# The control's own validity: the SAME changed files on a listed base, with
# the run observed, must audit clean. Without this, case 1 could be passing
# because the audit fails on everything.
echo "--- 1b. positive control: same files, base dev, run observed ---"
# Observed format is `path<TAB>status<TAB>conclusion<TAB>run_attempt<TAB>run_id`
# (monitor/ci-observed-runs.jq), optionally enriched with a sixth `priors`
# column. The 3-field rows here are the pre-#748 prefix, kept deliberately:
# they must still audit clean while the first-pass claim is WITHHELD, which is
# what case 12e pins.
# A genuine completed/success is the verdict that must audit clean.
#
# THREE workflows, not one, and each addition was the gating set genuinely
# growing rather than the audit breaking:
#
#   #737  tests-slow-integration.yml grew a `pull_request` trigger with
#         `paths: monitor/**`, so a PR touching monitor/watcher/*.sh is gated
#         by it as well as by tests.yml.
#   #774  conflict-markers.yml gates EVERY pull request — it declares no
#         `paths:` and no `branches:` filter on purpose, because a
#         merge-conflict marker can land in any tracked byte and the one that
#         reached dev landed in CHANGELOG.md, which no other workflow's filter
#         matches. An unfiltered workflow is gating for every PR by
#         construction, so it belongs in every positive control.
#
# In both cases supplying the shorter list made this control fail with rc=4
# NO-VERDICT — correctly. The fixture is what was stale, not the audit; adding
# the observed run is the fix, and weakening the assertion would have been the
# bug.
{
  printf '.github/workflows/tests.yml\tcompleted\tsuccess\n'
  printf '.github/workflows/tests-slow-integration.yml\tcompleted\tsuccess\n'
  printf '.github/workflows/conflict-markers.yml\tcompleted\tsuccess\n'
} > "$TMP/observed-tests.txt"
run_audit "$REAL_WF" "dev" "$TMP/changed-593.txt" "$TMP/observed-tests.txt"
if (( RC == 0 )) && grep -q 'OK: every workflow that should have gated' <<<"$OUT"; then
    ok "same files on base dev with tests.yml observed → clean (rc 0)"
else
    bad "positive control" "expected rc 0 + 'OK: every workflow…', got rc=$RC:
$OUT"
fi

# ===========================================================================
# 2. FIXTURE: the TRIGGER-GAP wording, pinned where it cannot rot.
# ===========================================================================
echo "--- 2. TRIGGER-GAP diagnosis names the workflow, the filter and the base ---"
FIX="$TMP/wf-gap"; mkdir -p "$FIX"
cat > "$FIX/ci-signal.yml" <<'EOF'
name: ci-signal
on:
  pull_request:
    types: [opened, synchronize, reopened, edited]
jobs:
  guard:
    runs-on: ubuntu-latest
    steps: [{run: 'true'}]
EOF
cat > "$FIX/tests.yml" <<'EOF'
name: tests
on:
  pull_request:
    branches: [main, dev]
    paths:
      - 'monitor/**'
jobs:
  unit:
    runs-on: ubuntu-latest
    steps: [{run: 'true'}]
EOF
run_audit "$FIX" "operator/some-feature" "$TMP/changed-593.txt" "$TMP/observed-none.txt"
if (( RC == 1 )) \
   && grep -q 'TRIGGER-GAP: tests.yml' <<<"$OUT" \
   && grep -q "excludes this PR's base 'operator/some-feature'" <<<"$OUT" \
   && grep -q 'LESS CI than it appears to have' <<<"$OUT"; then
    ok "TRIGGER-GAP names tests.yml, the base, and says the PR has less CI than it appears to"
else
    bad "TRIGGER-GAP wording" "rc=$RC (want 1) and/or message missing its parts:
$OUT"
fi

echo "--- 2c. a trigger-gapped PR must NOT be summarised as 'NONE' ---"
# Observed live on the your-org/nexus-code#617 negative control: with every
# other workflow's paths filter also missing, the gating list was empty AND
# tests.yml was trigger-gapped, so the summary printed a bare "NONE — no
# workflow's paths filter matches", which reads as "nothing was supposed to
# gate this PR". That is the exact misreading the check exists to prevent.
if grep -q 'NONE ARE RUNNING' <<<"$OUT" \
   && grep -q 'tests.yml would have gated it on a listed base' <<<"$OUT" \
   && ! grep -q "no workflow's paths filter matches" <<<"$OUT"; then
    ok "summary distinguishes 'gapped out of CI' from 'legitimately ungated'"
else
    bad "gapped summary" "expected the NONE-ARE-RUNNING wording naming tests.yml:
$OUT"
fi

echo "--- 2b. …and the remedy text warns that a retarget alone does not re-trigger ---"
if grep -q 'changing a base emits only the' <<<"$OUT" \
   && grep -q 'gh workflow run' <<<"$OUT"; then
    ok "remedy documents the \`edited\`-only base-change trap and the dispatch escape hatch"
else
    bad "remedy text" "the compounding trap or the dispatch remedy is missing:
$OUT"
fi

# ===========================================================================
# 3. MISSING-RUN is a DISTINCT, RETRYABLE verdict (exit 4, not 1).
# ===========================================================================
echo "--- 3. base matches, paths match, no run → MISSING-RUN, exit 4 ---"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$TMP/observed-none.txt"
if (( RC == 4 )) && grep -q 'MISSING-RUN: tests.yml' <<<"$OUT" \
   && ! grep -q 'TRIGGER-GAP' <<<"$OUT"; then
    ok "expected-on-every-axis-but-absent is MISSING-RUN with exit 4 (retryable)"
else
    bad "MISSING-RUN" "expected rc 4 + MISSING-RUN and no TRIGGER-GAP, got rc=$RC:
$OUT"
fi

# ===========================================================================
# 4. "Nothing gates this PR" must be a SENTENCE, never an empty screen.
# ===========================================================================
#    THE EXIT CODE MOVED IN #856, and the fixture is why it had to. This case's
#    changed file is `skills/nexus.report/SKILL.md` — a member of the very class
#    #853 reported. It used to assert rc **0**: "nothing gates this PR" was a
#    sentence, and then a CLEARANCE. That is the permissive reading of the merge
#    rule, encoded: a PR touching only uncovered files satisfied the strictest
#    gate in this workspace by running nothing that could read it. The SENTENCE
#    requirement was right and still holds; the rc 0 beside it was the defect.
echo "--- 4. a PR no workflow gates says so explicitly, and is NOT cleared ---"
printf 'skills/nexus.report/SKILL.md\n' > "$TMP/changed-skills.txt"
run_audit "$FIX" "dev" "$TMP/changed-skills.txt" "$TMP/observed-none.txt"
if (( RC == 8 )) && grep -q 'gating workflows for this PR: NONE' <<<"$OUT" \
   && grep -q 'explicit finding, not an absence of information' <<<"$OUT" \
   && grep -q '^UNGATED: ' <<<"$OUT" \
   && grep -q 'skills/nexus.report/SKILL.md' <<<"$OUT" \
   && ! grep -q '^OK: ' <<<"$OUT"; then
    ok "no-gating-workflow case is stated out loud, NAMES the unexamined file, and exits 8 — a sentence, not a clearance"
else
    bad "NONE case" "expected rc 8 + an explicit NONE sentence + UNGATED naming the file, got rc=$RC:
$OUT"
fi

# ===========================================================================
# 5. SELF-INTEGRITY. The guard is only load-bearing while it is itself
#    unfilterable. Both filter keys must be caught — and this is a real
#    negative control: the same fixture without the filter passes case 2/3
#    above, so a firing here is attributable to the injected key alone.
# ===========================================================================
echo "--- 5. a ci-signal.yml that acquires a branches:/paths: filter is SELF-BROKEN ---"
for key in branches paths; do
    SFIX="$TMP/wf-self-$key"; mkdir -p "$SFIX"
    cp "$FIX/tests.yml" "$SFIX/tests.yml"
    if [[ "$key" == branches ]]; then
        filter="    branches: [main, dev]"
    else
        filter="    paths: ['monitor/**']"
    fi
    cat > "$SFIX/ci-signal.yml" <<EOF
name: ci-signal
on:
  pull_request:
    types: [opened, synchronize]
$filter
jobs:
  guard:
    runs-on: ubuntu-latest
    steps: [{run: 'true'}]
EOF
    run_audit "$SFIX" "dev" "$TMP/changed-593.txt" "$TMP/observed-tests.txt"
    if (( RC == 1 )) && grep -q 'SELF-BROKEN: ci-signal.yml' <<<"$OUT" \
       && grep -q "declares \`$key:" <<<"$OUT"; then
        ok "ci-signal with a \`$key:\` filter is caught as SELF-BROKEN"
    else
        bad "SELF-BROKEN/$key" "expected rc 1 + SELF-BROKEN naming \`$key:\`, got rc=$RC:
$OUT"
    fi
done

echo "--- 5b. the REAL ci-signal.yml is not self-broken ---"
run_audit "$REAL_WF" "dev" "$TMP/changed-593.txt" "$TMP/observed-tests.txt"
if grep -q 'SELF-BROKEN' <<<"$OUT"; then
    bad "real ci-signal" "the checked-in ci-signal.yml has acquired a filter:
$OUT"
else
    ok "the checked-in ci-signal.yml declares neither branches: nor paths:"
fi

# ===========================================================================
# 6. FAIL-CLOSED REFUSALS. A parser that shrugs at an unfamiliar shape
#    manufactures exactly the silent green this guard exists to prevent.
# ===========================================================================
echo "--- 6. unparsed input is REFUSED (exit 2), never defaulted ---"
refuse_case() {
    local label="$1" body="$2" want="$3"
    local RFIX="$TMP/wf-refuse-$label"; mkdir -p "$RFIX"
    cp "$FIX/ci-signal.yml" "$RFIX/ci-signal.yml"
    printf '%s\n' "$body" > "$RFIX/tests.yml"
    run_audit "$RFIX" "dev" "$TMP/changed-593.txt" "$TMP/observed-none.txt"
    if (( RC == 2 )) && grep -q 'REFUSED' <<<"$OUT" && grep -q "$want" <<<"$OUT"; then
        ok "refuses $label (exit 2, names the cause)"
    else
        bad "refuse/$label" "expected rc 2 + REFUSED mentioning '$want', got rc=$RC:
$OUT"
    fi
}
refuse_case "branches-ignore" \
"name: tests
on:
  pull_request:
    branches-ignore: [gh-pages]
jobs: {u: {runs-on: ubuntu-latest, steps: [{run: 'true'}]}}" \
    'branches-ignore'
refuse_case "paths-ignore" \
"name: tests
on:
  pull_request:
    paths-ignore: ['docs/**']
jobs: {u: {runs-on: ubuntu-latest, steps: [{run: 'true'}]}}" \
    'paths-ignore'
refuse_case "negated-path" \
"name: tests
on:
  pull_request:
    paths: ['monitor/**', '!monitor/docs/**']
jobs: {u: {runs-on: ubuntu-latest, steps: [{run: 'true'}]}}" \
    'negated path pattern'
refuse_case "unparseable" \
"name: tests
on:
  pull_request:
   branches: [main
jobs: broken" \
    'unparseable'

# ===========================================================================
# 7. GLOB DIALECT. GitHub's `*` stops at `/` and `**` crosses it. Python's
#    fnmatch gets this wrong in the widening direction, which would silently
#    inflate the expectation set (every workflow "applies", so a real gap
#    hides among false ones).
# ===========================================================================
echo "--- 7. GitHub glob semantics: * stops at /, ** crosses it ---"
GFIX="$TMP/wf-glob"; mkdir -p "$GFIX"
cp "$FIX/ci-signal.yml" "$GFIX/ci-signal.yml"
cat > "$GFIX/tests.yml" <<'EOF'
name: tests
on:
  pull_request:
    paths: ['monitor/*']
jobs:
  u:
    runs-on: ubuntu-latest
    steps: [{run: 'true'}]
EOF
printf 'monitor/watcher/main.sh\n' > "$TMP/changed-nested.txt"
run_audit "$GFIX" "dev" "$TMP/changed-nested.txt" "$TMP/observed-none.txt"
# rc 8, not rc 0, since #856: "no workflow's paths matched" is UNGATED, not a
# clearance. What this case is actually about — the glob dialect — is unchanged,
# and it is asserted on the NONE sentence rather than on the exit code, so a
# future move of that code cannot silently turn this into a vacuous pass.
if (( RC == 8 )) && grep -q 'gating workflows for this PR: NONE' <<<"$OUT"; then
    ok "'monitor/*' does NOT match monitor/watcher/main.sh (fnmatch would have)"
else
    bad "glob single-star" "expected NONE (rc 8), got rc=$RC:
$OUT"
fi
printf 'monitor/ng\n' > "$TMP/changed-flat.txt"
run_audit "$GFIX" "dev" "$TMP/changed-flat.txt" "$TMP/observed-none.txt"
if (( RC == 4 )) && grep -q 'MISSING-RUN: tests.yml' <<<"$OUT"; then
    ok "'monitor/*' DOES match monitor/ng — the filter still discriminates"
else
    bad "glob single-star positive" "expected MISSING-RUN (rc 4), got rc=$RC:
$OUT"
fi

# ===========================================================================
# 8. The observed-runs EXTRACTOR, exercised as the REAL expression (not a copy).
#    Since #628 the jq is a faithful extractor — it emits EVERY run as
#    `path<TAB>status<TAB>conclusion<TAB>run_attempt<TAB>run_id`,
#    skipped/cancelled included, because
#    dropping them here would collapse NO-VERDICT into MISSING-RUN. The verdict
#    semantics moved to the audit (classify_runs); case 8b feeds this exact
#    extractor output through the audit end-to-end so the two are never a copy.
#
#    Since #748 it also carries `run_attempt` and `id` (fields 4 and 5). Those
#    are asserted HERE, on the extractor, because the whole finding was that
#    `run_attempt` sat unread in a payload the workflow already fetched: a test
#    that only exercised the audit's classification would pass against an
#    extractor that had quietly stopped emitting the column. The fixture below
#    deliberately includes a run with NO `run_attempt` key (cc-harness), since
#    that is what GitHub returns for some run shapes and the `// 1` default is
#    the thing that keeps it from becoming an empty column.
# ===========================================================================
echo "--- 8. the jq extractor emits path/status/conclusion/attempt/id for EVERY run ---"
JQF="$_test_dir/ci-observed-runs.jq"
JQ_OK=0
if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP: jq unavailable — the observed-runs extractor was NOT exercised."
elif [[ ! -f "$JQF" ]]; then
    bad "observed extractor" "monitor/ci-observed-runs.jq is missing; the workflow reads it"
else
    cat > "$TMP/runs.json" <<'EOF'
{"workflow_runs":[
  {"path":".github/workflows/tests.yml","status":"completed","conclusion":"skipped","run_attempt":1,"id":11},
  {"path":".github/workflows/docs.yml","status":"completed","conclusion":"cancelled","run_attempt":3,"id":12},
  {"path":".github/workflows/cc-harness.yml","status":"completed","conclusion":"success","id":13},
  {"path":".github/workflows/ci-signal.yml","status":"in_progress","conclusion":null,"run_attempt":1,"id":14}
]}
EOF
    got=$(jq -r -f "$JQF" < "$TMP/runs.json" | sort | tr '\t' '|' | tr '\n' ' ')
    want=".github/workflows/cc-harness.yml|completed|success|1|13 .github/workflows/ci-signal.yml|in_progress||1|14 .github/workflows/docs.yml|completed|cancelled|3|12 .github/workflows/tests.yml|completed|skipped|1|11 "
    if [[ "$got" == "$want" ]]; then
        ok "extractor keeps ALL runs with status+conclusion+attempt+id, null conclusion → empty ($got)"
        JQ_OK=1
    else
        bad "observed extractor" "want '$want', got '$got'"
    fi

    # The #748 column, asserted on its own so a regression names itself rather
    # than arriving as an opaque whole-line diff. docs.yml is at attempt 3 and
    # cc-harness carries no run_attempt key at all: if the `// 1` default ever
    # became `// ""` the second of these would silently blank the column, and
    # every downstream row would read as provenance-UNSUPPLIED — a fail-closed
    # direction, but one that would disable the check without anything saying so.
    att=$(jq -r -f "$JQF" < "$TMP/runs.json" | sort | cut -f4 | tr '\n' ' ')
    if [[ "$att" == "1 1 3 1 " ]]; then
        ok "run_attempt is extracted per run (3 for the re-run; absent key defaults to 1, never empty)"
    else
        bad "run_attempt column" "want '1 1 3 1 ', got '$att'"
    fi
fi

echo "--- 8b. extractor→audit end-to-end: a skipped tests run is NO-VERDICT ---"
if (( JQ_OK == 1 )); then
    # The SAME runs.json, but with tests.yml the sole gating workflow: pipe the
    # real jq output into the real audit and confirm the skipped run reads as
    # NO-VERDICT (rc 4), not as evidence. Proves the extractor and the verdict
    # classifier compose as ci-signal.yml wires them, with no copy in between.
    jq -r -f "$JQF" < "$TMP/runs.json" > "$TMP/observed-e2e.txt"
    run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$TMP/observed-e2e.txt"
    if (( RC == 4 )) && grep -q 'NO-VERDICT: tests.yml' <<<"$OUT" \
       && grep -q 'Conclusions seen: skipped' <<<"$OUT"; then
        ok "real jq output → audit classifies the skipped tests run as NO-VERDICT (rc 4)"
    else
        bad "extractor→audit" "expected rc 4 + NO-VERDICT naming skipped, got rc=$RC:
$OUT"
    fi
else
    echo "  SKIP: jq unavailable or extractor test failed — end-to-end not run."
fi

# ===========================================================================
# 9. MANIFEST. Every checked-in workflow must be parseable by the audit —
#    otherwise the guard degrades to a refusal on every PR.
# ===========================================================================
echo "--- 9. every checked-in workflow parses (no standing refusal) ---"
run_audit "$REAL_WF" "dev" "$TMP/changed-593.txt" "$TMP/observed-tests.txt"
if (( RC == 2 )); then
    bad "manifest" "the audit REFUSES on this repo's own workflows:
$OUT"
else
    n=$(find "$REAL_WF" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) | wc -l)
    ok "all $n checked-in workflows parsed (rc=$RC, not a refusal)"
fi

# ===========================================================================
# 10. THE #628 INVARIANT: for every gating workflow, the head must carry a run
#     whose conclusion is `success` or `failure`. Anything else — skipped,
#     cancelled, timed_out, action_required, or ABSENT — is not a verdict, and
#     the absence of a verdict is RED. All three observed forms are exercised
#     against the SAME gating shape ($FIX gates tests.yml on the #593 files, base
#     dev), so the ONLY thing varying between GREEN and RED is the conclusion.
#     Every assertion matches the emitted finding text, not merely the exit code.
#
#     Coverage boundary (the axis this varies on — WHICH absence-of-verdict
#     states): skipped, cancelled, timed_out, action_required, absent, and their
#     #627 cancelled+skipped composition; plus in-progress as the not-a-finding
#     PENDING case. A run cancelled AFTER the audit sampled it in-progress is a
#     timing race ci-signal cannot see and is closed at source in tests.yml, not
#     here.
# ===========================================================================
# obs <line...> — write an observed-runs file ($OBS) from TAB-joined run rows.
# Each argument is "status conclusion"; all rows are for tests.yml (the sole
# gating workflow in $FIX). An empty conclusion models an in-flight run.
obs() {
    : > "$TMP/obs.txt"
    local row
    for row in "$@"; do
        local st="${row%% *}" cc="${row#* }"
        [[ "$cc" == "$row" ]] && cc=""      # no space ⇒ empty conclusion
        printf '.github/workflows/tests.yml\t%s\t%s\n' "$st" "$cc" >> "$TMP/obs.txt"
    done
    OBS="$TMP/obs.txt"
}

echo "--- 10a. a skipped tests run is NO-VERDICT (RED, rc 4) ---"
obs "completed skipped"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"
if (( RC == 4 )) && grep -q 'NO-VERDICT: tests.yml' <<<"$OUT" \
   && grep -q 'Conclusions seen: skipped' <<<"$OUT" && ! grep -q 'FAILED' <<<"$OUT"; then
    ok "skipped → NO-VERDICT (rc 4), named as skipped, not confused with a failure"
else
    bad "skipped" "expected rc 4 + NO-VERDICT(skipped), got rc=$RC:
$OUT"
fi

echo "--- 10b. a cancelled tests run is NO-VERDICT (RED, rc 4) ---"
obs "completed cancelled"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"
if (( RC == 4 )) && grep -q 'NO-VERDICT: tests.yml' <<<"$OUT" \
   && grep -q 'Conclusions seen: cancelled' <<<"$OUT"; then
    ok "cancelled → NO-VERDICT (rc 4), named as cancelled"
else
    bad "cancelled" "expected rc 4 + NO-VERDICT(cancelled), got rc=$RC:
$OUT"
fi

echo "--- 10c. the EXACT #627 head: cancelled + skipped, same workflow → RED ---"
obs "completed cancelled" "completed skipped"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"
if (( RC == 4 )) && grep -q 'NO-VERDICT: tests.yml' <<<"$OUT" \
   && grep -q 'cancelled, skipped' <<<"$OUT"; then
    ok "cancelled+skipped (the #627 head, zero assertions run) → NO-VERDICT naming both"
else
    bad "#627 head" "expected rc 4 + NO-VERDICT naming cancelled+skipped, got rc=$RC:
$OUT"
fi

echo "--- 10d. the #619 form: NO run at all → MISSING-RUN, distinct from NO-VERDICT ---"
: > "$TMP/obs-empty.txt"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$TMP/obs-empty.txt"
if (( RC == 4 )) && grep -q 'MISSING-RUN: tests.yml' <<<"$OUT" \
   && grep -q 'NO run at all' <<<"$OUT" && ! grep -q 'NO-VERDICT' <<<"$OUT"; then
    ok "no run at all → MISSING-RUN (the #619 form), reported distinctly from NO-VERDICT"
else
    bad "#619 form" "expected rc 4 + MISSING-RUN (not NO-VERDICT), got rc=$RC:
$OUT"
fi

echo "--- 10e. timed_out is NO-VERDICT too — the ALLOWLIST proof (denylist would miss it) ---"
# A denylist that only knew skipped+cancelled (the pre-#628 shape) would count
# timed_out as evidence and go GREEN. This is the case that proves the invariant
# is an allowlist over {success,failure}, not an enumeration of known-bad states.
obs "completed timed_out"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"
if (( RC == 4 )) && grep -q 'NO-VERDICT: tests.yml' <<<"$OUT" \
   && grep -q 'Conclusions seen: timed_out' <<<"$OUT"; then
    ok "timed_out → NO-VERDICT (rc 4) — a conclusion no denylist enumerated still fails closed"
else
    bad "timed_out" "expected rc 4 + NO-VERDICT(timed_out), got rc=$RC:
$OUT"
fi

echo "--- 10f. action_required is NO-VERDICT too (second allowlist witness) ---"
obs "completed action_required"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"
if (( RC == 4 )) && grep -q 'NO-VERDICT: tests.yml' <<<"$OUT" \
   && grep -q 'Conclusions seen: action_required' <<<"$OUT"; then
    ok "action_required → NO-VERDICT (rc 4)"
else
    bad "action_required" "expected rc 4 + NO-VERDICT(action_required), got rc=$RC:
$OUT"
fi

echo "--- 10g. THE CONTROL: a genuine completed/success → GREEN (rc 0) ---"
# Without this, 10a–f could all be passing because the audit reds on everything.
obs "completed success"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"
if (( RC == 0 )) && grep -q 'carries a `success` verdict' <<<"$OUT" \
   && ! grep -q 'NO-VERDICT\|MISSING-RUN\|FAILED' <<<"$OUT"; then
    ok "success → clean (rc 0) — proves 10a–f red on the conclusion, not on everything"
else
    bad "success control" "expected rc 0 + success-verdict wording, got rc=$RC:
$OUT"
fi

echo "--- 10h. a genuine completed/failure → RED for the FAILURE (rc 5), not for absence ---"
obs "completed failure"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"
FAIL_OUT="$OUT"; FAIL_RC="$RC"
if (( RC == 5 )) && grep -q 'FAILED: tests.yml' <<<"$OUT" \
   && grep -q 'concluded `failure`' <<<"$OUT" \
   && ! grep -q '^NO-VERDICT: \|^MISSING-RUN: ' <<<"$OUT"; then
    ok "failure → FAILED (rc 5, its own code) — a real verdict, never misfiled as absence"
else
    bad "failure" "expected rc 5 + FAILED(failure) and NO absence findings, got rc=$RC:
$OUT"
fi

echo "--- 10i. FAILED, NO-VERDICT and MISSING-RUN say DIFFERENT things (different human responses) ---"
# The whole point of separating them: a failure means 'the code said no'; an
# absence means 'the suite did not run'. If the messages were interchangeable
# the distinction would be cosmetic. Assert the failure message is about the
# verdict and the absence messages are about the run not producing one.
#
# THIS ASSERTION MOVED IN #846, AND THE MOVE IS THE POINT. It used to grep
# $FAIL_OUT for "read the run's logs and fix" — but 10h's fixture is a
# three-field row with NO execution column, so execution is UNMEASURED there,
# and that sentence is exactly the claim #846 found this file making on the one
# axis it had not looked at. The strong wording is now conditional and is
# asserted where it is licensed (17a, on measured-executed evidence); here the
# unmeasured path is asserted to say so instead. Restoring the old grep would
# have restored the over-claim — a test pinning a sentence is only as good as
# the sentence's warrant.
obs "completed skipped"; run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"; NOVERD_OUT="$OUT"
: > "$TMP/obs-empty.txt"; run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$TMP/obs-empty.txt"; MISSING_OUT="$OUT"
if grep -q 'This IS a verdict — a real, red one' <<<"$FAIL_OUT" \
   && grep -q 'NOT measured' <<<"$FAIL_OUT" \
   && grep -q 'did not execute to a pass or a fail' <<<"$NOVERD_OUT" \
   && grep -q 'NO run at all' <<<"$MISSING_OUT" \
   && ! grep -q 'This IS a verdict' <<<"$NOVERD_OUT" \
   && ! grep -q 'This IS a verdict' <<<"$MISSING_OUT"; then
    ok "the three verdict-absence/failure messages are distinct and actionable, and the unmeasured FAILED declares itself unmeasured"
else
    bad "message distinctness" "FAILED/NO-VERDICT/MISSING-RUN messages are not clearly distinct:
--- FAILED ---
$FAIL_OUT
--- NO-VERDICT ---
$NOVERD_OUT
--- MISSING-RUN ---
$MISSING_OUT"
fi

echo "--- 10j. a success is not un-tested by a later skip (success + skipped → GREEN) ---"
obs "completed success" "completed skipped"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"
if (( RC == 0 )) && ! grep -q 'NO-VERDICT\|MISSING-RUN\|FAILED' <<<"$OUT"; then
    ok "success + skipped → GREEN (a head a real run passed stays passed)"
else
    bad "success+skipped" "expected rc 0 (success wins), got rc=$RC:
$OUT"
fi

# ===========================================================================
# 10k–10n. PENDING IS NEITHER A FINDING NOR A CLEARANCE (your-org/nexus-code
#          #762).
#
# 10k used to assert `rc 0` for a head whose only gating run was in_progress,
# with the PENDING note as the consolation. That assertion PINNED THE DEFECT:
# "every workflow that should have gated this PR carries a `success` verdict"
# is quantified over the CONCLUDED subset, so on an all-in_progress head it is
# quantified over the EMPTY SET — vacuously true, printed as OK, returned as 0.
# Observed live on PR #758's own head.
#
# The state is still not a FINDING (nothing is wrong; reddening a peer check
# because a sibling is still running would mute ci-signal on every PR), so the
# fix is not "make it red" — it is to stop conflating "no finding stands" with
# "this head is cleared". Hence exit 3, its own sentence, and the positive
# claim quantified over `gating` rather than over the concluded subset.
# ===========================================================================
echo "--- 10k. ALL gating bands in_progress → NOT CONCLUDED (rc 3), never a vacuous OK ---"
obs "in_progress"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"
if (( RC == 3 )) && grep -q 'NOT CONCLUDED' <<<"$OUT" \
   && grep -q 'NO gating workflow has reached a verdict' <<<"$OUT" \
   && grep -q 'EMPTY SET' <<<"$OUT" \
   && grep -q 'note: tests.yml: a run for this head sha is still in progress' <<<"$OUT" \
   && ! grep -q '^OK: ' <<<"$OUT" \
   && ! grep -q 'NO-VERDICT\|MISSING-RUN\|FAILED' <<<"$OUT"; then
    ok "all-in_progress → rc 3 NOT CONCLUDED, naming the empty-set vacuity; not OK, not a finding"
else
    bad "in_progress" "expected rc 3 + NOT CONCLUDED + empty-set language and NO 'OK:' line, got rc=$RC:
$OUT"
fi

# Two gating workflows are needed to exercise the PARTIAL arm at all — with one
# band there is no state between "none concluded" and "all concluded", which is
# precisely why a single-band fixture could never have caught this.
PFIX="$TMP/wf-pending"; mkdir -p "$PFIX"
cp "$FIX/ci-signal.yml" "$FIX/tests.yml" "$PFIX/"
sed 's/^name: tests$/name: docs/' "$FIX/tests.yml" > "$PFIX/docs.yml"
obs2() {
    : > "$TMP/obs2.txt"
    local wf row st cc
    for wf in tests docs; do
        row="$1"; shift
        st="${row%% *}"; cc="${row#* }"
        [[ "$cc" == "$row" ]] && cc=""
        printf '.github/workflows/%s.yml\t%s\t%s\n' "$wf" "$st" "$cc" >> "$TMP/obs2.txt"
    done
    OBS2="$TMP/obs2.txt"
}

echo "--- 10l. SOME concluded, some pending → PARTIAL and PROVISIONAL (rc 3) ---"
obs2 "completed success" "in_progress"
run_audit "$PFIX" "dev" "$TMP/changed-593.txt" "$OBS2"
PARTIAL_OUT="$OUT"
if (( RC == 3 )) && grep -q 'PARTIAL and PROVISIONAL' <<<"$OUT" \
   && grep -q 'tests.yml' <<<"$OUT" && grep -q 'docs.yml' <<<"$OUT" \
   && ! grep -q '^OK: ' <<<"$OUT"; then
    ok "1-of-2 concluded → rc 3, stated as partial and provisional, both bands named"
else
    bad "partial pending" "expected rc 3 + PARTIAL and PROVISIONAL naming both bands, got rc=$RC:
$OUT"
fi

echo "--- 10m. THE CONTROL: every gating band CONCLUDED green → rc 0 and it says so ---"
obs2 "completed success" "completed success"
run_audit "$PFIX" "dev" "$TMP/changed-593.txt" "$OBS2"
if (( RC == 0 )) && grep -q 'has CONCLUDED and carries a `success` verdict' <<<"$OUT" \
   && ! grep -q 'NOT CONCLUDED' <<<"$OUT"; then
    ok "both bands concluded green → rc 0 — 10k/10l red on the PENDING state, not on everything"
else
    bad "pending control" "expected rc 0 + an explicit CONCLUDED claim, got rc=$RC:
$OUT"
fi

echo "--- 10n. 'none concluded' and 'partially concluded' say DIFFERENT things ---"
# Same discipline as 10i. Both are rc 3 because the ACTION is identical (wait,
# re-audit) — one number per action. But the BELIEF a reader forms differs: in
# one case there is no evidence at all, in the other there is real evidence
# that simply does not cover the head. If the two rendered alike, the split
# would be cosmetic and the empty-set case would still be readable as a green.
obs "in_progress"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"
if grep -q 'EMPTY SET' <<<"$OUT" \
   && ! grep -q 'EMPTY SET' <<<"$PARTIAL_OUT" \
   && grep -q 'PARTIAL and PROVISIONAL' <<<"$PARTIAL_OUT" \
   && ! grep -q 'PARTIAL and PROVISIONAL' <<<"$OUT" \
   && grep -q 'can still turn it red' <<<"$PARTIAL_OUT"; then
    ok "the no-evidence and partial-evidence states are described distinctly under one exit code"
else
    bad "pending distinctness" "the two NOT-CONCLUDED sub-states are not clearly distinct:
--- none concluded ---
$OUT
--- partially concluded ---
$PARTIAL_OUT"
fi

echo "--- 10o. negative control: without the pending branch, 10k AND 10l go GREEN ---"
# The #762 defect, re-created by mutation on a COPY of the REAL audit. Disabling
# the pending branch drops both cases straight through to the OK line — which is
# exactly what the pre-fix file did, so this mutant IS the pre-fix behaviour and
# its green is the measurement that 10k/10l are red on the fix rather than on
# something incidental. Without this control, 10k/10l assert a wording.
#
# The anchor lives in `clearance_report()` since #812 moved the three terminal
# states out of `main()`; it used to be indented 8 spaces inside `main`. The
# apply-check below is what caught the move rather than letting the control go
# vacuously green, which is the whole reason it is asserted.
PMUT="$TMP/mutant-pending.py"
sed 's/^    if pending:$/    if False:  # NEGATIVE-CONTROL MUTANT (#762)/' \
    "$AUDIT" > "$PMUT"
if ! grep -q 'NEGATIVE-CONTROL MUTANT (#762)' "$PMUT"; then
    bad "pending mutation apply" "the \`if pending:\` anchor changed; the #762 negative-control sed no longer applies — update it"
else
    run_pmut() { OUT=$(python3 "$PMUT" --workflows-dir "$1" --base-ref dev \
        --changed-files "$TMP/changed-593.txt" --observed "$2" --self-workflow ci-signal.yml 2>&1); RC=$?; }
    obs "in_progress";                          run_pmut "$FIX"  "$OBS"
    m_none_rc="$RC"; m_none_out="$OUT"
    obs2 "completed success" "in_progress";     run_pmut "$PFIX" "$OBS2"
    m_part_rc="$RC"; m_part_out="$OUT"
    if (( m_none_rc == 0 )) && grep -q '^OK: ' <<<"$m_none_out" \
       && (( m_part_rc == 0 )) && grep -q '^OK: ' <<<"$m_part_out"; then
        ok "mutant reports OK/rc 0 on BOTH pending shapes — the #762 defect exactly, so the fix is what reds them"
    else
        bad "pending mutant" "mutant should reproduce the vacuous green (rc 0 + OK) on both shapes, got none_rc=$m_none_rc part_rc=$m_part_rc:
--- none ---
$m_none_out
--- partial ---
$m_part_out"
    fi
    # And the mutant must still be a working audit, or its green above would be
    # breakage rather than the removed check.
    obs "completed skipped"; run_pmut "$FIX" "$OBS"
    if (( RC == 4 )); then
        ok "mutant still audits (reds a skipped run) — its pending-greening is the removed branch, not damage"
    else
        bad "pending mutant sanity" "mutant no longer reds a skipped run (rc=$RC); its green above proves nothing:
$OUT"
    fi
fi

# ===========================================================================
# 11. NEGATIVE CONTROL BY MUTATION. "A guard never observed to fail is not
#     evidence." Delete the #628 verdict check — neuter classify_runs so any
#     non-empty run set is PASS, exactly the pre-#628 'a run exists ⇒ evidence'
#     behaviour — and confirm 10a/10b/10e go GREEN again. That the mutant
#     greens them is what proves classify_runs is what reds them. The mutation
#     is applied to a COPY of the REAL audit (not a reimplementation), and its
#     application is asserted, so a sed that silently stopped matching fails
#     loudly here rather than passing a vacuous control.
# ===========================================================================
echo "--- 11. negative control: with the verdict check removed, 10a/10b/10e go GREEN ---"
MUTANT="$TMP/mutant-audit.py"
sed 's/^    conclusions = {r.conclusion for r in runs}$/    return "PASS"  # NEGATIVE-CONTROL MUTANT (#628)/' \
    "$AUDIT" > "$MUTANT"
if ! grep -q 'NEGATIVE-CONTROL MUTANT' "$MUTANT"; then
    bad "mutation apply" "the classify_runs anchor line changed; the negative-control sed no longer applies — update it"
else
    run_mutant() { OUT=$(python3 "$MUTANT" --workflows-dir "$FIX" --base-ref dev \
        --changed-files "$TMP/changed-593.txt" --observed "$1" --self-workflow ci-signal.yml 2>&1); RC=$?; }
    mut_green=1
    for cc in skipped cancelled timed_out; do
        obs "completed $cc"; run_mutant "$OBS"
        if (( RC != 0 )) || grep -q 'NO-VERDICT\|MISSING-RUN\|FAILED' <<<"$OUT"; then
            mut_green=0
            bad "mutant/$cc" "mutant should GREEN $cc (proving the real check reds it), got rc=$RC:
$OUT"
        fi
    done
    if (( mut_green == 1 )); then
        ok "mutant (verdict check removed) greens skipped/cancelled/timed_out — the real classifier is load-bearing"
    fi
    # And the mutant must still be a real, running audit (not broken some other
    # way): on a genuine success it also greens, so its greening above is
    # attributable to the removed check, not to the audit being inert.
    obs "completed success"; run_mutant "$OBS"
    if (( RC == 0 )); then
        ok "mutant still audits (greens a real success too) — its 10a/b/e greening is the removed check, not breakage"
    else
        bad "mutant liveness" "mutant failed even on a real success (rc=$RC) — it is broken, not merely neutered:
$OUT"
    fi
fi

# ===========================================================================
# 12. THE REPLACED VERDICT (your-org/nexus-code#748). Everything above tests
#     absence: no run, or a run that reached no verdict. This block tests the
#     opposite shape — a run that reached a verdict, had it OVERWRITTEN by a
#     re-run, and now presents as clean. `GET /actions/runs` returns only the
#     latest attempt, so head d4df844f (SLOW band `failure` → re-run `success`
#     at the same sha) was indistinguishable from a first-pass green to every
#     tool in this repo.
#
#     The cases are chosen to separate MISSING from REPLACED and, within
#     REPLACED, to separate "a verdict was overwritten" from "a retry happened
#     but overwrote no verdict" and from "we could not find out" — three
#     different remedies that a single boolean `was_retried` would blur.
# ===========================================================================
# obs_att <row...> — like obs(), but each row is "status conclusion attempt priors"
# so the #748 columns can be driven directly. All rows are for tests.yml.
obs_att() {
    : > "$TMP/obs-att.txt"
    local row
    for row in "$@"; do
        # shellcheck disable=SC2086
        set -- $row
        printf '.github/workflows/tests.yml\t%s\t%s\t%s\t99\t%s\n' \
            "$1" "$2" "$3" "${4:-}" >> "$TMP/obs-att.txt"
    done
    OBS="$TMP/obs-att.txt"
}
runa() { run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$1"; }

echo "--- 12a. THE d4df844f HEAD: success on attempt 2 over a failure → REPLACED-VERDICT (rc 6) ---"
obs_att "completed success 2 failure"; runa "$OBS"
if (( RC == 6 )) && grep -q 'REPLACED-VERDICT: tests.yml' <<<"$OUT"; then
    ok "success@2 over a failure → REPLACED-VERDICT (rc 6) — the retried green is no longer readable as clean"
else
    bad "12a replaced" "want rc 6 + REPLACED-VERDICT, got rc=$RC:
$OUT"
fi

echo "--- 12b. a retry that replaced NO verdict (cancelled) is a NOTE, not a finding (rc 0) ---"
obs_att "completed success 2 cancelled"; runa "$OBS"
if (( RC == 0 )) && ! grep -q 'REPLACED-VERDICT' <<<"$OUT" \
   && grep -q 're-run at this head sha' <<<"$OUT"; then
    ok "success@2 over a cancelled → rc 0 with a stated note: a retry is not by itself a replaced verdict"
else
    bad "12b retried-benign" "want rc 0, no REPLACED-VERDICT, and a note, got rc=$RC:
$OUT"
fi

echo "--- 12c. an UNREADABLE superseded attempt is reported, not assumed benign (rc 6) ---"
# The #745 lesson one level up: an ancestry check run against an unfetched
# object exited non-zero and was read as a NEGATIVE ANSWER instead of "could
# not determine". If `?` folded into 12b's benign branch, an Actions API blip
# would silently downgrade every replaced verdict to a note.
obs_att "completed success 2 ?"; runa "$OBS"
if (( RC == 6 )) && grep -q 'ATTEMPTS-UNKNOWN: tests.yml' <<<"$OUT"; then
    ok "success@2 over an UNREADABLE attempt → ATTEMPTS-UNKNOWN (rc 6), never folded into the benign note"
else
    bad "12c undetermined" "want rc 6 + ATTEMPTS-UNKNOWN, got rc=$RC:
$OUT"
fi

echo "--- 12d. THE CONTROL: attempt 1 → clean, and the audit SAYS first-pass (rc 0) ---"
obs_att "completed success 1"; runa "$OBS"
if (( RC == 0 )) && grep -q 'FIRST-PASS green' <<<"$OUT" \
   && ! grep -q 'REPLACED-VERDICT\|ATTEMPTS-UNKNOWN' <<<"$OUT"; then
    ok "success@1 → rc 0 and an explicit FIRST-PASS statement — 12a–c red on the attempt, not on everything"
else
    bad "12d control" "want rc 0 + a FIRST-PASS claim, got rc=$RC:
$OUT"
fi

echo "--- 12e. NO attempt column ⇒ 'not checked', never 'checked and clean' (rc 0) ---"
# The pre-#748 wire format. It must stay green (the audit is usable without the
# enrichment step) while REFUSING to make the first-pass claim. Asserting the
# absence of the claim is the point: a default of attempt=1 would have printed
# "each of those greens is a FIRST-PASS green" having looked at nothing.
printf '.github/workflows/tests.yml\tcompleted\tsuccess\n' > "$TMP/obs-bare.txt"
runa "$TMP/obs-bare.txt"
if (( RC == 0 )) && grep -q 'UNKNOWN — not verified-absent' <<<"$OUT" \
   && ! grep -q 'FIRST-PASS green' <<<"$OUT"; then
    ok "3-field rows → rc 0 but the first-pass claim is WITHHELD and named as unknown"
else
    bad "12e unsupplied" "want rc 0, no FIRST-PASS claim, an explicit unknown, got rc=$RC:
$OUT"
fi

echo "--- 12f. a LIVE failure outranks a replaced one (rc 5, not 6) ---"
# Exit 6 is ranked last so it carries the narrow meaning "otherwise clean, and
# the problem is the retry". A head that is still red must report the red.
obs_att "completed failure 2 failure"; runa "$OBS"
if (( RC == 5 )) && grep -q 'FAILED: tests.yml' <<<"$OUT"; then
    ok "failure@2 → rc 5 (FAILED), not rc 6 — a live red is never masked by the provenance finding"
else
    bad "12f precedence" "want rc 5 + FAILED, got rc=$RC:
$OUT"
fi

echo "--- 12g. REPLACED and NO-VERDICT say DIFFERENT things (different remedies) ---"
obs_att "completed success 2 failure"; runa "$OBS"; rep_out="$OUT"
obs "completed skipped"; runa "$OBS"; nov_out="$OUT"
if grep -q 'was not fixed, it was RE-RUN' <<<"$rep_out" \
   && grep -q 'did not execute to a pass or a fail' <<<"$nov_out" \
   && ! grep -q 'RE-RUN' <<<"$nov_out"; then
    ok "a replaced verdict and an absent verdict are described distinctly — the enumeration blind spot is named"
else
    bad "12g distinctness" "the REPLACED and NO-VERDICT messages are not distinct:
--- replaced ---
$rep_out
--- no-verdict ---
$nov_out"
fi

# ===========================================================================
# 13. NEGATIVE CONTROL for #748, same discipline as case 11. Neuter
#     classify_attempts so every run set reads CLEAN — the pre-#748 behaviour,
#     in which a retried green is invisible — and confirm 12a and 12c go GREEN.
#     That the mutant greens them is what proves classify_attempts is what reds
#     them, rather than some incidental property of the fixtures.
# ===========================================================================
echo "--- 13. negative control: with attempt classification removed, 12a/12c go GREEN ---"
MUTANT2="$TMP/mutant-attempts.py"
sed 's/^    priors = \[p for r in runs for p in r.priors\]$/    return "CLEAN"  # NEGATIVE-CONTROL MUTANT (#748)/' \
    "$AUDIT" > "$MUTANT2"
if ! grep -q 'NEGATIVE-CONTROL MUTANT (#748)' "$MUTANT2"; then
    bad "mutation apply 749" "the classify_attempts anchor line changed; the negative-control sed no longer applies — update it"
else
    run_mut2() { OUT=$(python3 "$MUTANT2" --workflows-dir "$FIX" --base-ref dev \
        --changed-files "$TMP/changed-593.txt" --observed "$1" --self-workflow ci-signal.yml 2>&1); RC=$?; }
    mut2_green=1
    for pri in failure '?'; do
        obs_att "completed success 2 $pri"; run_mut2 "$OBS"
        if (( RC != 0 )) || grep -q 'REPLACED-VERDICT\|ATTEMPTS-UNKNOWN' <<<"$OUT"; then
            mut2_green=0
            bad "mutant749/$pri" "mutant should GREEN a success@2 over '$pri', got rc=$RC:
$OUT"
        fi
    done
    (( mut2_green == 1 )) && ok "mutant (attempt classification removed) greens both replaced and undetermined — the real classifier is load-bearing"
    # Liveness: the mutant must still red a genuine NO-VERDICT, proving its
    # greening above is the removed attempt check and not a dead audit.
    obs "completed skipped"; run_mut2 "$OBS"
    if (( RC == 4 )); then
        ok "mutant still audits (reds a skipped run) — its 12a/12c greening is the removed check, not breakage"
    else
        bad "mutant749 liveness" "mutant failed to red a skipped run (rc=$RC) — it is broken, not merely neutered:
$OUT"
    fi
fi

# ===========================================================================
# 14. ci-attempt-history.sh, exercised against a STUB gh. The script is the
#     only place that spends API calls, and its contract has two halves that a
#     happy-path test would not separate: it must pass an attempt-1 run through
#     WITHOUT calling gh at all (the cost argument), and it must emit `?`
#     rather than an empty field when a lookup fails (the fail-closed argument).
#     The stub records every call, so "did not call gh" is asserted from the
#     call log rather than inferred from the output looking right.
# ===========================================================================
echo '--- 14. ci-attempt-history.sh: zero calls on attempt 1, "?" on a failed lookup ---'
HIST="$_test_dir/ci-attempt-history.sh"
if [[ ! -x "$HIST" ]]; then
    bad "attempt history" "monitor/ci-attempt-history.sh is missing or not executable; ci-signal.yml runs it"
else
    STUBD="$TMP/stub-bin"; mkdir -p "$STUBD"
    CALLLOG="$TMP/gh-calls.txt"; : > "$CALLLOG"
    cat > "$STUBD/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLLOG"
# attempts/1 of run 77 is the one that cannot be read (models an API blip).
case "\$*" in
  *runs/77/attempts/1*) exit 1 ;;
  *runs/88/attempts/1*) echo failure ;;
  *runs/88/attempts/2*) echo cancelled ;;
  *) echo success ;;
esac
EOF
    chmod +x "$STUBD/gh"

    {
      printf '.github/workflows/tests.yml\tcompleted\tsuccess\t1\t55\n'
      printf '.github/workflows/docs.yml\tcompleted\tsuccess\t2\t77\n'
      printf '.github/workflows/cc-harness.yml\tcompleted\tsuccess\t3\t88\n'
    } > "$TMP/hist-in.txt"
    HOUT=$(PATH="$STUBD:$PATH" bash "$HIST" --repo o/n --observed "$TMP/hist-in.txt" 2>&1)

    got_t=$(grep -F 'tests.yml' <<<"$HOUT" | cut -f6)
    got_d=$(grep -F 'docs.yml'  <<<"$HOUT" | cut -f6)
    got_c=$(grep -F 'cc-harness.yml' <<<"$HOUT" | cut -f6)

    if [[ -z "$got_t" ]] && ! grep -q 'runs/55' "$CALLLOG"; then
        ok "attempt-1 run passes through with empty priors and gh is NOT called for it (zero-cost common case)"
    else
        bad "hist attempt-1" "want empty priors and no gh call for run 55; priors='$got_t', calls:
$(cat "$CALLLOG")"
    fi
    if [[ "$got_d" == "?" ]]; then
        ok "an unreadable superseded attempt yields '?' — could-not-determine, never a silent empty"
    else
        bad "hist unreadable" "want '?', got '$got_d'"
    fi
    if [[ "$got_c" == "failure,cancelled" ]]; then
        ok "attempt 3 resolves BOTH superseded attempts, in order (failure,cancelled)"
    else
        bad "hist multi" "want 'failure,cancelled', got '$got_c'"
    fi

    # AN IN-FLIGHT RUN HAS AN EMPTY CONCLUSION, AND THAT EMPTY FIELD IS A TRAP.
    # Found in this PR's own new code, which is the point: TAB is an IFS
    # WHITESPACE character, so `IFS=$'\t' read -r a b c ...` COLLAPSES runs of
    # tabs and drops the empty column, shifting every later field left. The
    # first draft of ci-head-attempts.sh read a pending run's row back as
    # attempt=<run-id> and reported RETRY-UNKNOWN for it — a false alarm on
    # exactly the rows that are still fine. Measured, not reasoned:
    #   printf 'a\tcompleted\t\t2\t99\tfailure\n' | while IFS=$'\t' read -r p s c a i r
    #   → concl=[2] attempt=[99] id=[failure] priors=[]
    # This case pins the parse: a run with an EMPTY conclusion must survive
    # enrichment with its attempt intact and no priors invented.
    printf '.github/workflows/tests.yml\tin_progress\t\t1\t55\n' > "$TMP/hist-inflight.txt"
    IOUT=$(PATH="$STUBD:$PATH" bash "$HIST" --repo o/n --observed "$TMP/hist-inflight.txt" 2>&1)
    i_status=$(cut -f2 <<<"$IOUT"); i_conc=$(cut -f3 <<<"$IOUT")
    i_att=$(cut -f4 <<<"$IOUT");   i_pri=$(cut -f6 <<<"$IOUT")
    if [[ "$i_status" == "in_progress" && -z "$i_conc" \
          && "$i_att" == "1" && -z "$i_pri" ]]; then
        ok "an in-flight run's EMPTY conclusion does not shift the attempt column (the IFS-tab-collapse trap)"
    else
        bad "hist empty field" "want in_progress/<empty>/1/<empty>, got '$i_status'/'$i_conc'/'$i_att'/'$i_pri'"
    fi

    # End-to-end: the enriched rows must drive the audit to the #748 finding,
    # so the script and the classifier are never a copy of one another.
    grep -F 'docs.yml' <<<"$HOUT" | sed 's|docs.yml|tests.yml|' > "$TMP/hist-e2e.txt"
    runa "$TMP/hist-e2e.txt"
    if (( RC == 6 )) && grep -q 'ATTEMPTS-UNKNOWN' <<<"$OUT"; then
        ok "ci-attempt-history output drives the real audit to rc 6 — the two compose as ci-signal.yml wires them"
    else
        bad "hist e2e" "want rc 6 + ATTEMPTS-UNKNOWN from real enrichment output, got rc=$RC:
$OUT"
    fi
fi

# ===========================================================================
# 15. BAND MULTIPLICITY IS SURFACED (your-org/nexus-code#787).
#
# The narrow claim, and it matters that it is narrow: multiplicity was ALREADY
# adjudicated correctly — 10c (cancelled+skipped → NO-VERDICT/RED) and 10j
# (success+skipped → GREEN) above are the two shapes and they still pass
# untouched. #787 is a REPORTING gap, so every assertion here is about what a
# reader is told, and 15e pins that the VERDICTS did not move. A test that let
# a verdict change would be evidence this PR built the guard that already
# existed, which is exactly the waste #787 was filed to prevent.
#
# Rows carry a run_id column here (the 5-field wire format) because naming
# WHICH run supplied the verdict is the payload — `obs` writes 3-field rows, so
# these fixtures are written out directly.
# ===========================================================================
mobs() {
    # each arg: "<status> <conclusion> <attempt> <run_id>", conclusion `-` for
    # an in-flight run's EMPTY conclusion. A literal empty field would collapse
    # under word splitting and leave $4 unbound — the same shape as the
    # IFS-tab-collapse trap section 14 pins, so it gets a sentinel instead.
    : > "$TMP/mobs.txt"
    local row st cc at rid
    for row in "$@"; do
        # shellcheck disable=SC2086
        set -- $row
        st="$1"; cc="$2"; at="$3"; rid="$4"
        [[ "$cc" == "-" ]] && cc=""
        printf '.github/workflows/tests.yml\t%s\t%s\t%s\t%s\n' \
               "$st" "$cc" "$at" "$rid" >> "$TMP/mobs.txt"
    done
    OBS="$TMP/mobs.txt"
}

echo "--- 15a. #778's exact shape: the GREEN names the second run and its cause ---"
mobs "completed success 1 111" "completed skipped 1 222"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"
if (( RC == 0 )) \
   && grep -q 'band multiplicity: 1 of 1 gating band(s) with runs ran MORE THAN ONCE' <<<"$OUT" \
   && grep -q 'runs=2  PASS from run 111 (success, attempt 1)' <<<"$OUT" \
   && grep -q 'alongside run 222 (skipped, attempt 1)' <<<"$OUT" \
   && grep -q '#628 signature' <<<"$OUT" \
   && grep -q '::notice::band multiplicity' <<<"$OUT"; then
    ok "success+skipped → still GREEN, and the reader is told runs=2, WHICH run passed, and that a body edit is the usual cause"
else
    bad "787 15a" "expected rc 0 + runs=2 + the verdict run named + the #628 hint + a ::notice::, got rc=$RC:
$OUT"
fi

echo "--- 15b. the RED direction: NO-VERDICT names the multiplicity that IS the mechanism ---"
mobs "completed cancelled 1 111" "completed skipped 1 222"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"
if (( RC == 4 )) \
   && grep -q 'produced 2 run(s) for this head sha' <<<"$OUT" \
   && grep -q 'run 111 (cancelled, attempt 1); run 222 (skipped, attempt 1)' <<<"$OUT" \
   && grep -q 'TWO OR MORE RUNS AT ONE HEAD SHA IS THE MECHANISM' <<<"$OUT" \
   && grep -q 'NO run supplied a verdict' <<<"$OUT"; then
    ok "cancelled+skipped → still RED, and the finding says TWO runs and names both — the eviction is diagnosable"
else
    bad "787 15b" "expected rc 4 + a plural, id-naming NO-VERDICT, got rc=$RC:
$OUT"
fi

echo "--- 15c. the POSITIVE sentence: one run per band is STATED, never left silent ---"
mobs "completed success 1 111"
run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"
if (( RC == 0 )) \
   && grep -q 'produced EXACTLY ONE run at this head sha' <<<"$OUT" \
   && ! grep -q '::notice::band multiplicity' <<<"$OUT"; then
    ok "single-run head SAYS so — 'checked and clean' is distinguishable from 'never looked', and no notice is raised"
else
    bad "787 15c" "expected rc 0 + the EXACTLY ONE sentence + no notice, got rc=$RC:
$OUT"
fi

echo "--- 15d. expectations-only audit reports NOT CHECKED, never a clean multiplicity ---"
run_audit "$FIX" "dev" "$TMP/changed-593.txt"
if grep -q 'band multiplicity: NOT CHECKED' <<<"$OUT" \
   && ! grep -q 'EXACTLY ONE run' <<<"$OUT"; then
    ok "no observed-runs data → 'not looked at', never 'looked at and clean' (the house rule, applied to the new report)"
else
    bad "787 15d" "expected a NOT CHECKED multiplicity line with no clean claim, got:
$OUT"
fi

# The multiplicity report, excised. Used by BOTH 15e and 15f, and built once
# so the two cannot disagree about what "without #787" means.
sed 's/^    mult_lines, mult_notices = multiplicity_lines(gating, observed)$/    mult_lines, mult_notices = ([], [])  # NEGATIVE-CONTROL MUTANT (#787)/' \
    "$AUDIT" > "$TMP/audit-nomult.py"
nomult_ok=1
if cmp -s "$TMP/audit-nomult.py" "$AUDIT"; then
    nomult_ok=0
    bad "787 15ef apply" "the multiplicity_lines call site changed; the negative-control sed no longer applies — update it"
fi

echo "--- 15e. NO NEW ADJUDICATION: every verdict is identical with the report removed ---"
# The load-bearing assertion of this section, and it is DIFFERENTIAL rather
# than a list of hand-typed exit codes: for each multi-run shape, run the
# shipped audit and the report-excised audit and require the exit codes to be
# EQUAL. Hand-typed codes would pin whatever the author believed, and the
# author believing the wrong thing is how a second adjudicator gets in.
# #787 is explicit that classify_runs already decides these correctly and must
# not be given a second opinion; this is that sentence, executable.
if (( nomult_ok )); then
    adj_fail=0
    adj_detail=""
    for shape in \
        "completed success 1 111|completed skipped 1 222" \
        "completed cancelled 1 111|completed skipped 1 222" \
        "completed failure 1 111|completed skipped 1 222" \
        "completed success 1 111|completed failure 1 222" \
        "in_progress - 1 111|completed skipped 1 222" \
        "completed skipped 1 111|completed skipped 1 222"
    do
        IFS='|' read -r r1 r2 <<<"$shape"
        mobs "$r1" "$r2"
        run_audit "$FIX" "dev" "$TMP/changed-593.txt" "$OBS"
        shipped=$RC
        python3 "$TMP/audit-nomult.py" --workflows-dir "$FIX" --base-ref dev \
            --changed-files "$TMP/changed-593.txt" --observed "$OBS" \
            --self-workflow ci-signal.yml >/dev/null 2>&1
        before=$?
        if (( shipped != before )); then
            adj_fail=1
            adj_detail="$adj_detail
    $shape : with report rc=$shipped, without rc=$before"
        fi
    done
    if (( adj_fail == 0 )); then
        ok "six multi-run shapes exit IDENTICALLY with and without the report — #787 adjudicates NOTHING"
    else
        bad "787 15e" "a multi-run shape's verdict depends on the multiplicity report — a second adjudicator got in:$adj_detail"
    fi
fi

echo "--- 15f. NEGATIVE CONTROL: with the multiplicity report removed, 15a goes silent ---"
# A guard never observed failing is not evidence. 15a's assertions must stop
# holding on the excised build — while the VERDICT stays 0, which is 15e's
# point from the other side.
if (( nomult_ok )); then
    mobs "completed success 1 111" "completed skipped 1 222"
    MOUT=$(python3 "$TMP/audit-nomult.py" --workflows-dir "$FIX" --base-ref dev \
             --changed-files "$TMP/changed-593.txt" --observed "$OBS" \
             --self-workflow ci-signal.yml 2>&1); MRC=$?
    if (( MRC == 0 )) && ! grep -q 'band multiplicity' <<<"$MOUT"; then
        ok "mutant hides the duplication while still reporting GREEN — the #778 reading exactly, so the report is what fixes it"
    else
        bad "787 15f" "mutant did not go silent (rc=$MRC); 15a is not watching what it claims:
$MOUT"
    fi
fi

# ===========================================================================
# 16. THE NO-DATA PATH IS NOT A VERDICT PATH (your-org/nexus-code#812).
#
#     THE DEFECT. With `--observed` omitted the audit printed, two lines apart,
#     "band multiplicity: NOT CHECKED — … 'not looked at', not 'looked at and
#     clean'" and "OK: every workflow that should have gated this PR has
#     CONCLUDED and carries a `success` verdict", at rc 0 — a positive claim
#     about runs it was never shown, one screen below its own statement that it
#     had not looked. The #748 qualifier that would have softened it was guarded
#     by `elif observed is not None`, so the one path most in need of a
#     qualifier received none.
#
#     WHAT IS ASSERTED HERE, AND WHY IT IS THE SENTENCE. A summary line is an
#     unasserted surface unless a fixture matches the sentence itself: every
#     case below greps the emitted text, and the two ABSENCE greps (`^OK: `,
#     "carries a `success` verdict") are the load-bearing half — an exit-code
#     test alone would pass against a build that exits 7 and still prints the
#     verdict.
#
#     COVERAGE BOUNDARY, on the axis the mechanism varies on — WHICH QUESTION
#     THE RUN WAS IN A POSITION TO ANSWER. There are three such states
#     (no run data / runs pending / all concluded green) and all three are
#     exercised: 16a-16b here, 10k-10o for pending, 1b and 15c for concluded.
#     What is NOT on this axis and is not claimed: whether the audit's
#     expectations half is CORRECT under no-data (cases 1-9 own that), and
#     whether any CALLER maps exit 7 sensibly — ci-signal.yml and
#     ci-head-attempts.sh both pass `--observed` unconditionally, so 7 is
#     unreachable from production and its callers' `*)`/default arms are what
#     make it fail closed there. That is a structural argument, not a
#     measurement, and it is stated as one.
# ===========================================================================
echo "--- 16a. no observed-runs data → EXPECTATIONS ONLY (rc 7), never a verdict ---"
run_audit "$FIX" "dev" "$TMP/changed-593.txt"
if (( RC == 7 )) \
   && grep -q '^EXPECTATIONS ONLY: no observed-runs data was supplied' <<<"$OUT" \
   && grep -q 'NOT CHECKED, and therefore NOT CLEAN' <<<"$OUT" \
   && ! grep -q '^OK: ' <<<"$OUT" \
   && ! grep -q 'carries a `success` verdict' <<<"$OUT"; then
    ok "expectations-only run states what it read and exits 7 — no OK line, no \`success\` verdict claimed"
else
    bad "812 16a" "expected rc 7 + EXPECTATIONS ONLY and NO verdict sentence, got rc=$RC:
$OUT"
fi

echo "--- 16b. …and when nothing gates the PR either, that is still not a verdict ---"
run_audit "$FIX" "dev" "$TMP/changed-skills.txt"
if (( RC == 7 )) \
   && grep -q 'no band whose run could have been examined' <<<"$OUT" \
   && ! grep -q '^OK: ' <<<"$OUT"; then
    ok "ungated + unmeasured says 'no verdict was ever expected' rather than borrowing the vocabulary of one"
else
    bad "812 16b" "expected rc 7 + the no-band sentence and no OK line, got rc=$RC:
$OUT"
fi

echo "--- 16c. the no-data arm does NOT swallow a real finding: a gap is still rc 1 ---"
# The arm is selected on "was I shown run data", so it must sit UNDER the
# findings check, not over it. A TRIGGER-GAP is computed from the workflow
# sources alone and is fully determined without any run data — reporting it as
# "expectations only" would be the fix suppressing the audit's own strongest
# finding on exactly the path it was meant to harden.
run_audit "$FIX" "operator/some-feature" "$TMP/changed-593.txt"
if (( RC == 1 )) && grep -q 'TRIGGER-GAP: tests.yml' <<<"$OUT" \
   && ! grep -q 'EXPECTATIONS ONLY' <<<"$OUT"; then
    ok "a source-determined finding still reds at rc 1 with no run data — the new arm is under findings, not over them"
else
    bad "812 16c" "expected rc 1 + TRIGGER-GAP with no EXPECTATIONS-ONLY block, got rc=$RC:
$OUT"
fi

echo "--- 16d. STRUCTURAL: the verdict sentence refuses to be built without data ---"
# Asserted at the FUNCTION boundary, not through the CLI. #812's remedy is not
# "the branch in main() was reworded" — it is that the sentence lives in one
# function which cannot produce it without the evidence. That property is
# invisible to any end-to-end test: an end-to-end test can only observe the
# branch that is currently taken, and the whole risk is a future edit taking a
# different one.
cl_probe=$(python3 - "$AUDIT" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cta", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    lines = mod.cleared_lines(["tests.yml"], None)
except mod.UnmeasuredClaim as exc:
    print("RAISED" if "#812" in str(exc) else "RAISED-UNEXPLAINED")
else:
    print("RETURNED %r" % (lines,))
# The control: with data, the same call DOES produce the verdict sentence, so
# the refusal above is the precondition and not a function that never works.
ok = mod.cleared_lines(["tests.yml"], {"tests.yml": [mod.Run("completed", "success", 1, (), "1")]})
print("WITHDATA-OK" if any(l.startswith("OK: ") for l in ok) else "WITHDATA-BROKEN")
PY
)
if [[ "$cl_probe" == "RAISED"$'\n'"WITHDATA-OK" ]]; then
    ok "cleared_lines(gating, None) raises UnmeasuredClaim naming #812, and still builds the OK line WITH data"
else
    bad "812 16d" "expected 'RAISED' then 'WITHDATA-OK', got:
$cl_probe"
fi

# The two mutants, built from the REAL audit and each with its application
# asserted, so a sed that silently stops matching fails loudly here instead of
# passing a vacuous control.
MUT_ARM="$TMP/mutant-812-arm.py"
sed 's/^        return expectations_only_lines(gating), 7$/        pass  # NEGATIVE-CONTROL MUTANT (#812 arm)/' \
    "$AUDIT" > "$MUT_ARM"
MUT_BOTH="$TMP/mutant-812-both.py"
sed 's/^    _require_measured(observed)$/    pass  # NEGATIVE-CONTROL MUTANT (#812 precondition)/' \
    "$MUT_ARM" > "$MUT_BOTH"
mut812_ok=1
if ! grep -q 'NEGATIVE-CONTROL MUTANT (#812 arm)' "$MUT_ARM"; then
    mut812_ok=0
    bad "812 mutation apply" "the expectations-only return line changed; the #812 arm sed no longer applies — update it"
elif ! grep -q 'NEGATIVE-CONTROL MUTANT (#812 precondition)' "$MUT_BOTH"; then
    mut812_ok=0
    bad "812 mutation apply" "the _require_measured call site changed; the #812 precondition sed no longer applies — update it"
fi
run_mut812() { OUT=$(python3 "$1" --workflows-dir "$FIX" --base-ref dev \
    --changed-files "$TMP/changed-593.txt" --self-workflow ci-signal.yml 2>&1); RC=$?; }

echo "--- 16e. NEGATIVE CONTROL: delete the arm alone → the precondition FIRES ---"
# Route the no-data case back at the verdict and the interpreter stops it: rc 2,
# a refusal, no OK line. This is what distinguishes #812's remedy from a
# reworded branch — remove the branch and the sentence still cannot be printed.
if (( mut812_ok )); then
    run_mut812 "$MUT_ARM"
    if (( RC == 2 )) && grep -q 'REFUSED: a clearance sentence was reached with no observed-runs data' <<<"$OUT" \
       && ! grep -q '^OK: ' <<<"$OUT"; then
        ok "arm-only mutant is caught by _require_measured and fails CLOSED at rc 2 — the guard is load-bearing, not decorative"
    else
        bad "812 16e" "expected rc 2 + the UnmeasuredClaim refusal, got rc=$RC:
$OUT"
    fi
fi

echo "--- 16f. NEGATIVE CONTROL: delete BOTH → #812 reproduces exactly (rc 0 + OK) ---"
# With the arm and the precondition removed, the no-data run prints the verdict
# sentence at rc 0 over runs it was never shown. That IS the filed defect, so
# its appearance here is the measurement that the two changes above are what
# red it — and not that the case reds for some incidental reason.
#
# One deliberate difference from the pre-#812 build: this mutant also prints the
# #748 "provenance was NOT supplied" qualifier, because #812 turned that
# `elif observed is not None` into an unconditional else. The reproduced defect
# is the OK line at rc 0; the qualifier's absence was the aggravation, not the
# claim.
if (( mut812_ok )); then
    run_mut812 "$MUT_BOTH"
    if (( RC == 0 )) && grep -q '^OK: every workflow that should have gated' <<<"$OUT" \
       && grep -q 'band multiplicity: NOT CHECKED' <<<"$OUT"; then
        ok "both-mutant reproduces #812 verbatim: 'NOT CHECKED' and a \`success\` verdict at rc 0, two lines apart"
    else
        bad "812 16f" "mutant did not reproduce the filed defect (rc=$RC); 16a proves nothing:
$OUT"
    fi

    # And the mutant must still be a working audit, or its green above would be
    # breakage rather than the removed check.
    obs "completed skipped"
    OUT=$(python3 "$MUT_BOTH" --workflows-dir "$FIX" --base-ref dev \
        --changed-files "$TMP/changed-593.txt" --observed "$OBS" \
        --self-workflow ci-signal.yml 2>&1); RC=$?
    if (( RC == 4 )); then
        ok "both-mutant still audits (reds a skipped run at rc 4) — its rc-0 green is the removed guard, not damage"
    else
        bad "812 16f sanity" "mutant no longer reds a skipped run (rc=$RC); its green above proves nothing:
$OUT"
    fi
fi

# ===========================================================================
# 19. UNGATED: A GREEN FROM BANDS THAT CANNOT READ YOUR DIFF IS NOT A CLEARANCE
#     (your-org/nexus-code#856, generalising #853).
#
#     THE DEFECT. `cleared_lines()` is quantified over `gating` — every workflow
#     that FIRES. A workflow with no `paths:` filter fires on EVERY PR, so on a
#     repo that has one (here: conflict-markers.yml) `gating` is never empty and
#     the clearance never looked vacuous. It was vacuous anyway: for a diff that
#     matches no `paths:` filter, every member of `gating` is a workflow that
#     cannot read the files that changed, and "every workflow that should have
#     gated this PR carries a `success` verdict" is TRUE and means nothing.
#
#     Measured on this repo at `a91f82b`: **76 of 634 tracked files** match no
#     `tests.yml` `paths:` entry. A PR touching only those got rc 0 and the full
#     clearance sentence on the strength of a merge-conflict-marker check.
#
#     WHY AN EXIT CODE AND NOT A WARNING. The merge rule this workspace applies
#     is "each expected band exactly once, every band `success`". It cannot
#     distinguish a band that correctly did not apply from a band suppressed by
#     a `paths:` filter — both are ABSENT — so it has two readings and both are
#     wrong: strictly, a CLAUDE.md-only PR can never merge; permissively, an
#     uncovered PR clears by running nothing. Deriving the expected set FROM THE
#     DIFF is what makes `absent` checkable against `should not have run`.
#
#     COVERAGE BOUNDARY, on the axis the mechanism varies on — WHETHER ANY BAND
#     WAS SELECTED BY THE DIFF'S CONTENT. Both sides are exercised, plus the
#     mixed case (one file covered, one not) and the unconditional-band case
#     that is the whole reason `gating` was the wrong quantifier.
# ===========================================================================
# A workflow set that mirrors THIS repo's shape: one unconditional band (no
# `paths:`, fires always) beside one path-filtered band. That pairing is the
# mechanism; a fixture with only path-filtered workflows cannot show it.
UFIX="$TMP/wf-ungated"; mkdir -p "$UFIX"
cat > "$UFIX/conflict-markers.yml" <<'EOF'
name: conflict-markers
on:
  pull_request:
    branches: [main, dev]
jobs:
  m: { runs-on: ubuntu-latest, steps: [{run: 'true'}] }
EOF
cat > "$UFIX/tests.yml" <<'EOF'
name: tests
on:
  pull_request:
    branches: [main, dev]
    paths: ['monitor/**']
jobs:
  u: { runs-on: ubuntu-latest, steps: [{run: 'true'}] }
EOF
printf '.github/workflows/conflict-markers.yml\tcompleted\tsuccess\t1\t10\t\n' > "$TMP/obs-cm.txt"
printf '.github/workflows/conflict-markers.yml\tcompleted\tsuccess\t1\t10\t\n.github/workflows/tests.yml\tcompleted\tsuccess\t1\t11\t\n' > "$TMP/obs-cm-tests.txt"

echo "--- 19a. an uncovered diff + a green unconditional band → UNGATED (rc 8), NOT cleared ---"
printf 'README.md\nskills/nexus.bot/SKILL.md\n' > "$TMP/changed-uncov.txt"
run_audit "$UFIX" "dev" "$TMP/changed-uncov.txt" "$TMP/obs-cm.txt"
UNGATED_OUT="$OUT"
if (( RC == 8 )) && grep -q '^UNGATED: ' <<<"$OUT" \
   && grep -q 'README.md' <<<"$OUT" && grep -q 'skills/nexus.bot/SKILL.md' <<<"$OUT" \
   && ! grep -q '^OK: ' <<<"$OUT" \
   && ! grep -q 'carries a `success` verdict for this head sha' <<<"$OUT"; then
    ok "19a uncovered diff → UNGATED (rc 8) naming both unexamined files, and the clearance sentence is NOT printed"
else
    bad "856 19a" "expected rc 8 + UNGATED naming the files and no OK line, got rc=$RC:
$OUT"
fi

echo "--- 19b. THE CONTROL: one covered file makes the same head a real clearance (rc 0) ---"
# Without this, 19a could be passing because the audit reds on everything. The
# ONLY thing varying is whether a path-filtered band was selected.
printf 'monitor/ng\n' > "$TMP/changed-cov.txt"
run_audit "$UFIX" "dev" "$TMP/changed-cov.txt" "$TMP/obs-cm-tests.txt"
if (( RC == 0 )) && grep -q '^OK: ' <<<"$OUT" && ! grep -q 'UNGATED' <<<"$OUT"; then
    ok "19b a covered diff still clears at rc 0 — 19a keys on content-selection, not on everything"
else
    bad "856 19b" "expected rc 0 + OK, got rc=$RC:
$OUT"
fi

echo "--- 19c. MIXED diff: it clears at rc 0, AND the uncovered files are NAMED in the clearance ---"
# THE COMMON CASE, not an edge. Real PRs mix files: a `monitor/` change beside a
# README tweak. Content-selection is a property of the DIFF (did any band get
# selected?), so a mixed diff IS cleared — a suite ran and read part of the
# change. But the files nothing read must survive onto the exit-0 path.
#
# THIS FIXTURE PREVIOUSLY ASSERTED ONLY `rc == 0` WHILE ITS OWN COMMENT CLAIMED
# THE FILE WAS "still NAMED", AND IT PASSED — against a build that computed the
# list and then discarded it on the clearance path. Prose claiming what the
# assertion does not check, inside the test for a fix about unexamined things
# being reported as fine. The list is the property; the exit code was never the
# property, so the exit code is no longer what is asserted alone.
printf 'monitor/ng\nREADME.md\nskills/nexus.bot/SKILL.md\n' > "$TMP/changed-mixed.txt"
run_audit "$UFIX" "dev" "$TMP/changed-mixed.txt" "$TMP/obs-cm-tests.txt"
MIXED_OUT="$OUT"
if (( RC == 0 )) && grep -q '^OK: ' <<<"$OUT" \
   && grep -q 'PARTIALLY EXAMINED: 2 of the 3 changed file(s)' <<<"$OUT" \
   && grep -q '^      README.md$' <<<"$OUT" \
   && grep -q '^      skills/nexus.bot/SKILL.md$' <<<"$OUT" \
   && ! grep -q '^      monitor/ng$' <<<"$OUT"; then
    ok "19c a mixed diff clears at rc 0 AND names both unexamined files — and does NOT list the covered one"
else
    bad "856 19c" "expected rc 0 + a PARTIALLY EXAMINED block naming README.md and the skills file, got rc=$RC:
$OUT"
fi

echo "--- 19h. a FULLY covered diff carries no such block (the control for 19c) ---"
# Without this, 19c could pass against a build that prints the block always,
# which would train readers to ignore it.
run_audit "$UFIX" "dev" "$TMP/changed-cov.txt" "$TMP/obs-cm-tests.txt"
if (( RC == 0 )) && grep -q '^OK: ' <<<"$OUT" \
   && ! grep -q 'PARTIALLY EXAMINED' <<<"$OUT"; then
    ok "19h a fully covered diff clears with NO unexamined block — 19c's block is attributable to the uncovered files"
else
    bad "856 19h" "expected a clean clearance with no PARTIALLY EXAMINED block, got rc=$RC:
$OUT"
fi

# ===========================================================================
# 19i. VACUITY CONTROL for 19c specifically. 19g already proves the UNGATED
#      ARM is load-bearing; it says nothing about the CLEARANCE path, which is
#      where the list was being dropped. Delete the one line that carries the
#      list onto that path — exactly the shipped-and-reviewed behaviour — and
#      confirm 19c's assertion FAILS. An assertion never observed failing is
#      not evidence, and this one had already been observed PASSING against the
#      defect.
# ===========================================================================
echo "--- 19i. vacuity control: drop the list from the clearance path → 19c's block disappears ---"
MUT868="$TMP/mutant-868.py"
sed 's/^    lines.extend(_unexamined_block(list(unexamined), total_changed))$/    pass  # NEGATIVE-CONTROL MUTANT (#868 clearance path)/' \
    "$AUDIT" > "$MUT868"
if ! grep -q 'NEGATIVE-CONTROL MUTANT (#868 clearance path)' "$MUT868"; then
    bad "mutation apply 868" "the clearance-path anchor changed; the vacuity-control sed no longer applies — update it"
else
    OUT=$(python3 "$MUT868" --workflows-dir "$UFIX" --base-ref dev \
        --changed-files "$TMP/changed-mixed.txt" --observed "$TMP/obs-cm-tests.txt" \
        --self-workflow ci-signal.yml 2>&1); RC=$?
    if (( RC == 0 )) && grep -q '^OK: ' <<<"$OUT" \
       && ! grep -q 'PARTIALLY EXAMINED' <<<"$OUT"; then
        ok "mutant reproduces the shipped defect — a mixed diff clears at rc 0 naming nothing, which is what 19c used to pass against"
    else
        bad "856 19i" "mutant did not reproduce the dropped-list defect (rc=$RC); 19c proves nothing:
$OUT"
    fi
    # And the mutant must still emit the UNGATED block, or its silence above
    # would be a broken audit rather than the removed line.
    OUT=$(python3 "$MUT868" --workflows-dir "$UFIX" --base-ref dev \
        --changed-files "$TMP/changed-uncov.txt" --observed "$TMP/obs-cm.txt" \
        --self-workflow ci-signal.yml 2>&1); RC=$?
    if (( RC == 8 )) && grep -q 'NOT EXAMINED BY ANY WORKFLOW' <<<"$OUT"; then
        ok "mutant still audits (UNGATED still names its files) — 19c's failure is the clearance path alone"
    else
        bad "856 19i sanity" "mutant broke beyond the removed line (rc=$RC):
$OUT"
    fi
fi

echo "--- 19d. UNGATED is reported ONLY when nothing failed — a red still wins ---"
# Precedence: this is a clearance-arm state, so it must never mask a finding.
printf '.github/workflows/conflict-markers.yml\tcompleted\tfailure\t1\t10\t\texecuted\tall 1 job(s) ran\n' > "$TMP/obs-cm-red.txt"
run_audit "$UFIX" "dev" "$TMP/changed-uncov.txt" "$TMP/obs-cm-red.txt"
if (( RC == 5 )) && grep -q '^FAILED: ' <<<"$OUT" && ! grep -q 'UNGATED' <<<"$OUT"; then
    ok "19d a real red on the unconditional band still exits 5 — UNGATED lives in the clearance arm and masks nothing"
else
    bad "856 19d" "expected rc 5 FAILED, got rc=$RC:
$OUT"
fi

echo "--- 19e. …and PENDING still wins over UNGATED (nothing has finished yet) ---"
printf '.github/workflows/conflict-markers.yml\tin_progress\t\t1\t10\t\n' > "$TMP/obs-cm-pending.txt"
run_audit "$UFIX" "dev" "$TMP/changed-uncov.txt" "$TMP/obs-cm-pending.txt"
if (( RC == 3 )) && ! grep -q 'UNGATED' <<<"$OUT"; then
    ok "19e an unfinished head is rc 3, not rc 8 — 'not gated' is only decidable once the bands that DID fire have concluded"
else
    bad "856 19e" "expected rc 3, got rc=$RC:
$OUT"
fi

echo "--- 19f. the message must be actionable in BOTH directions, not just alarming ---"
if grep -q 'NOT automatically wrong' <<<"$UNGATED_OUT" \
   && grep -q 'docs-only change legitimately needs no suite' <<<"$UNGATED_OUT" \
   && grep -q 'paths' <<<"$UNGATED_OUT" \
   && grep -q 'satisfied VACUOUSLY' <<<"$UNGATED_OUT"; then
    ok "19f UNGATED says both what it is NOT (a defect) and what it is NOT (a clearance), and names the vacuous quantifier"
else
    bad "856 19f" "the UNGATED text does not carry both readings:
$UNGATED_OUT"
fi

# ===========================================================================
# 19g. VACUITY CONTROL for #856, same discipline as 11/13/17i. Neuter the
#      content-selection filter — make every gating workflow count as
#      content-selected, i.e. exactly the pre-#856 behaviour — and confirm 19a
#      goes back to rc 0 with the clearance sentence. That the mutant clears it
#      is what proves the new arm is what withholds it.
# ===========================================================================
echo "--- 19g. vacuity control: with content-selection removed, 19a reverts to a CLEARANCE (rc 0) ---"
#      The mutation targets the ARM, not the collection of `content_gating`.
#      Neutering the collector instead put `None` into `path_selectors` and the
#      mutant died with a TypeError at rc 1 — broken, not neutered, and a broken
#      mutant proves nothing in either direction. Deleting exactly the branch
#      under test is the mutation that reproduces the pre-#856 behaviour.
MUT856="$TMP/mutant-856.py"
sed 's/^    if not content_gating:$/    if False:  # NEGATIVE-CONTROL MUTANT (#856)/' \
    "$AUDIT" > "$MUT856"
if ! grep -q 'NEGATIVE-CONTROL MUTANT (#856)' "$MUT856"; then
    bad "mutation apply 856" "the content-selection anchor changed; the vacuity-control sed no longer applies — update it"
else
    OUT=$(python3 "$MUT856" --workflows-dir "$UFIX" --base-ref dev \
        --changed-files "$TMP/changed-uncov.txt" --observed "$TMP/obs-cm.txt" \
        --self-workflow ci-signal.yml 2>&1); RC=$?
    if (( RC == 0 )) && grep -q '^OK: ' <<<"$OUT" && ! grep -q 'UNGATED' <<<"$OUT"; then
        ok "mutant (content-selection removed) reproduces the filed defect — an unexamined diff reads as CLEARED at rc 0"
    else
        bad "856 19g" "mutant did not reproduce #856 (rc=$RC); 19a proves nothing:
$OUT"
    fi
    OUT=$(python3 "$MUT856" --workflows-dir "$UFIX" --base-ref dev \
        --changed-files "$TMP/changed-cov.txt" --observed "$TMP/obs-cm-tests.txt" \
        --self-workflow ci-signal.yml 2>&1); RC=$?
    if (( RC == 0 )); then
        ok "mutant still audits (clears a genuinely covered diff too) — its 19a clearance is the removed check, not breakage"
    else
        bad "856 19g sanity" "mutant broke outright (rc=$RC):
$OUT"
    fi
fi

# ===========================================================================
# 20. monitor/ci-uncovered-paths.py — the measurement any operator can run in
#     their OWN clone, so the number in #856 is reproducible rather than
#     inherited. Exercised against FIXTURE workflow dirs, never against this
#     repo's real count: an assertion pinned to "74" would fail the next time
#     somebody adds a file, which teaches readers to edit the expectation
#     rather than read it.
#
#     What is asserted is the BEHAVIOUR at the boundaries: total coverage, zero
#     coverage, and the three refusals. Each refusal exists because its silent
#     version would report a confident wrong answer — "0 uncovered" from an
#     unreadable population reads exactly like a clean repo.
# ===========================================================================
echo "--- 20. ci-uncovered-paths.py: covered / uncovered / fail-closed ---"
COV="$_test_dir/ci-uncovered-paths.py"
if [[ ! -f "$COV" ]]; then
    bad "coverage cmd" "monitor/ci-uncovered-paths.py is missing"
else
    # A fixture dir whose one suite workflow covers EVERYTHING.
    CFIX="$TMP/wf-cov-all"; mkdir -p "$CFIX"
    cat > "$CFIX/tests.yml" <<'EOF'
name: tests
on:
  pull_request:
    branches: [main, dev]
    paths: ['**']
jobs:
  u: { runs-on: ubuntu-latest, steps: [{run: 'true'}] }
EOF
    OUT=$(python3 "$COV" --workflows-dir "$CFIX" --quiet 2>&1); RC=$?
    if (( RC == 0 )) && grep -q 'uncovered                : 0' <<<"$OUT"; then
        # NOT backticks: inside a double-quoted bash string they are COMMAND
        # SUBSTITUTION, so `**` was executed (as an empty command) and the
        # message rendered as "a  filter". Harmless here and not harmless in
        # general — a message is a surface too.
        ok "20a a '**' filter covers every tracked file → rc 0"
    else
        bad "20a" "expected rc 0 / 0 uncovered, got rc=$RC:
$OUT"
    fi

    # …and one that covers nothing, which must NOT be silent.
    CNONE="$TMP/wf-cov-none"; mkdir -p "$CNONE"
    sed "s#paths: \['\*\*'\]#paths: ['no-such-dir/**']#" "$CFIX/tests.yml" > "$CNONE/tests.yml"
    OUT=$(python3 "$COV" --workflows-dir "$CNONE" --quiet 2>&1); RC=$?
    if (( RC == 1 )) && grep -qE 'uncovered                : [0-9]+' <<<"$OUT" \
       && grep -q 'UNCOVERED, by top-level path' <<<"$OUT" \
       && ! grep -q 'uncovered                : 0' <<<"$OUT"; then
        ok "20b a filter matching nothing → rc 1 with a grouped list, never a silent 0"
    else
        bad "20b" "expected rc 1 + a non-zero grouped list, got rc=$RC:
$OUT"
    fi

    # THE REFUSALS. Each of these would otherwise print a confident "0
    # uncovered", which is indistinguishable from a clean repo.
    EMPTYWF="$TMP/wf-cov-empty"; mkdir -p "$EMPTYWF"
    OUT=$(python3 "$COV" --workflows-dir "$EMPTYWF" 2>&1); RC=$?
    if (( RC == 2 )) && grep -q 'REFUSED' <<<"$OUT"; then
        ok "20c an EMPTY workflows dir REFUSES (rc 2) — it does not report every file uncovered, nor none"
    else
        bad "20c" "expected rc 2 refusal on an empty workflows dir, got rc=$RC:
$OUT"
    fi
    OUT=$(python3 "$COV" --workflows-dir "$TMP/does-not-exist" 2>&1); RC=$?
    if (( RC == 2 )); then
        ok "20d a missing workflows dir REFUSES (rc 2)"
    else
        bad "20d" "expected rc 2 on a missing dir, got rc=$RC:
$OUT"
    fi
    # No workflow qualifies as EXAMINING: every file would read as uncovered,
    # which is a fact about the inputs, not about the repo.
    ONLYCM="$TMP/wf-cov-uncond"; mkdir -p "$ONLYCM"
    cat > "$ONLYCM/conflict-markers.yml" <<'EOF'
name: conflict-markers
on:
  pull_request:
    branches: [main, dev]
jobs:
  m: { runs-on: ubuntu-latest, steps: [{run: 'true'}] }
EOF
    OUT=$(python3 "$COV" --workflows-dir "$ONLYCM" 2>&1); RC=$?
    if (( RC == 2 )) && grep -q 'statement about this command.s inputs' <<<"$OUT"; then
        ok "20e a dir with ONLY unconditional workflows REFUSES — '100% uncovered' would be a claim about the inputs"
    else
        bad "20e" "expected rc 2 refusal when nothing can examine, got rc=$RC:
$OUT"
    fi

    # And it must agree with the AUDIT, since both read the same glob engine.
    # If these ever disagree the difference would look like a finding.
    OUT=$(python3 "$COV" --workflows-dir "$UFIX" --suite tests.yml --quiet 2>&1); RC=$?
    if (( RC == 1 )) && grep -q 'unconditional workflows  : conflict-markers.yml' <<<"$OUT"; then
        ok "20f the unconditional band is NAMED — the reason an uncovered PR still shows green checks"
    else
        bad "20f" "expected the unconditional band to be named, got rc=$RC:
$OUT"
    fi
fi

# ===========================================================================
# 17. A `failure` WITH ZERO STEPS EXECUTED IS NOT A VERDICT
#     (your-org/nexus-code#846).
#
#     THE DEFECT. VERDICT_CONCLUSIONS is a correct allowlist and classifies on
#     the CONCLUSION STRING alone; it never asked whether the run executed
#     anything. So a run GitHub aborted before assigning a runner — an account
#     billing block, a quota refusal — concluded `failure`, and the audit told
#     the reader "this IS a verdict — a real, red one … read the run's logs and
#     fix the code, this is not a CI-plumbing gap". Every clause of that was
#     false for #837's head: no logs (BlobNotFound), no code to fix, and
#     precisely a CI-plumbing gap.
#
#     WHAT IS ACTUALLY BEING GUARDED HERE IS THE ASYMMETRY, NOT THE DOWNGRADE.
#     The naive fix INVERTS the danger and the inverted version is much worse:
#     today a plumbing gap is misread as a code red (cost: a misrouted reader),
#     whereas after a careless fix a real code red is misread as a plumbing gap
#     (cost: broken code merged because the gate said "not your fault"). So the
#     load-bearing case below is 17c/17d/17e — the UNDECIDABLE ones, which must
#     stay RED. 17b, the downgrade everybody would think to test, is the easy
#     half.
#
#     COVERAGE BOUNDARY, on the axis the mechanism varies on — WHAT THE
#     EXECUTION EVIDENCE SAYS. Six values are exercised: positive-executed,
#     positive-unexecuted, explicit `unknown`, an ABSENT column (the pre-#846
#     wire format), a token this code has never heard of, and `not-checked`.
#     Two run-set compositions are exercised on top of that: MIXED (one aborted
#     run and one that executed, same band) and aborted-plus-in-flight. What is
#     NOT claimed here: that monitor/ci-run-execution.sh derives those tokens
#     correctly from a jobs payload — case 18 owns that, against a stub gh.
# ===========================================================================
# obs_exec <row...> — an observed-runs file with the #846 execution columns.
# Each row is "status conclusion execution [detail words…]". Two literals:
# a conclusion of `_` writes an EMPTY conclusion (an in-flight run), and an
# execution of `-` writes a SIX-field row — the pre-#846 wire format, with the
# column absent entirely rather than present-and-empty.
obs_exec() {
    : > "$TMP/obs-exec.txt"
    local row st cc ex detail
    for row in "$@"; do
        # shellcheck disable=SC2086
        set -- $row
        st="$1"; cc="$2"; ex="$3"; detail="${*:4}"
        [[ "$cc" == "_" ]] && cc=""
        if [[ "$ex" == "-" ]]; then
            printf '.github/workflows/tests.yml\t%s\t%s\t1\t99\t\n' \
                "$st" "$cc" >> "$TMP/obs-exec.txt"
        else
            printf '.github/workflows/tests.yml\t%s\t%s\t1\t99\t\t%s\t%s\n' \
                "$st" "$cc" "$ex" "${detail:-fixture detail}" >> "$TMP/obs-exec.txt"
        fi
    done
    OBS="$TMP/obs-exec.txt"
}

echo "--- 17a. executed-and-failed → RED (rc 5), FAILED, and the strong sentence is LICENSED ---"
obs_exec "completed failure executed"
runa "$OBS"
if (( RC == 5 )) && grep -q '^FAILED: tests.yml' <<<"$OUT" \
   && grep -q 'Execution was MEASURED' <<<"$OUT" \
   && grep -q 'read the run.s logs and fix the code' <<<"$OUT" \
   && ! grep -q 'UNEXECUTED-RUN' <<<"$OUT"; then
    ok "a failure that executed steps stays FAILED (rc 5) and keeps the 'read the logs' advice"
else
    bad "846 17a" "expected rc 5 + FAILED with MEASURED execution, got rc=$RC:
$OUT"
fi

echo "--- 17b. zero-steps failure → UNEXECUTED-RUN (rc 4), named as a PLUMBING gap ---"
obs_exec "completed failure unexecuted The job was not started because recent account payments have failed"
runa "$OBS"
UNEXEC_OUT="$OUT"
if (( RC == 4 )) && grep -q '^UNEXECUTED-RUN: tests.yml' <<<"$OUT" \
   && grep -q 'EXECUTED NOTHING' <<<"$OUT" \
   && grep -q 'CI-PLUMBING GAP' <<<"$OUT" \
   && grep -q 'recent account payments have failed' <<<"$OUT" \
   && ! grep -q '^FAILED: ' <<<"$OUT"; then
    ok "a failure that executed zero steps → UNEXECUTED-RUN (rc 4), routed to the plumbing, not to the diff"
else
    bad "846 17b" "expected rc 4 + UNEXECUTED-RUN naming the plumbing gap, got rc=$RC:
$OUT"
fi

echo "--- 17c. UNDECIDABLE (explicit \`unknown\`) → stays RED (rc 5). THE LOAD-BEARING CASE ---"
obs_exec "completed failure unknown the jobs API call failed"
runa "$OBS"
UNKNOWN_OUT="$OUT"
if (( RC == 5 )) && grep -q '^FAILED: tests.yml' <<<"$OUT" \
   && grep -q 'NOT measured' <<<"$OUT" \
   && grep -q 'unmeasured is not exonerated' <<<"$OUT" \
   && ! grep -q 'UNEXECUTED-RUN' <<<"$OUT"; then
    ok "'could not tell whether it executed' stays RED — no steps DATA is not zero steps EXECUTED"
else
    bad "846 17c" "expected rc 5 + FAILED with an unmeasured caveat, got rc=$RC:
$OUT"
fi

echo "--- 17d. UNDECIDABLE (column ABSENT — the pre-#846 wire format) → stays RED (rc 5) ---"
# The upgrade path is where a default gets chosen carelessly. A caller that
# never runs the enricher must NOT collect the downgrade for free.
obs_exec "completed failure -"
runa "$OBS"
if (( RC == 5 )) && grep -q '^FAILED: tests.yml' <<<"$OUT" \
   && grep -q 'NOT measured' <<<"$OUT" \
   && ! grep -q 'UNEXECUTED-RUN' <<<"$OUT"; then
    ok "an absent execution column reads as unknown and stays RED — the old wire format cannot buy a downgrade"
else
    bad "846 17d" "expected rc 5 + FAILED on a 6-field row, got rc=$RC:
$OUT"
fi

echo "--- 17e. a token this code has NEVER HEARD OF → stays RED (rc 5); the allowlist proof ---"
# The #628 argument one level in: a denylist ('anything that is not unknown
# licenses the downgrade') would green this. Only the single-token allowlist
# fails it closed.
obs_exec "completed failure probably-didnt-run-honest"
runa "$OBS"
if (( RC == 5 )) && grep -q '^FAILED: tests.yml' <<<"$OUT" \
   && ! grep -q 'UNEXECUTED-RUN' <<<"$OUT"; then
    ok "an unrecognised execution token fails toward RED — UNEXECUTED_EVIDENCE is an allowlist, not a denylist"
else
    bad "846 17e" "expected rc 5 on an unknown token, got rc=$RC:
$OUT"
fi

echo "--- 17f. MIXED run set (one aborted + one that executed, same band) → RED (rc 5) ---"
# The decision recorded in classify_runs(): between a false RED and a false
# 'not your fault', this file always takes the false RED.
obs_exec "completed failure unexecuted" "completed failure executed"
runa "$OBS"
if (( RC == 5 )) && grep -q '^FAILED: tests.yml' <<<"$OUT" \
   && ! grep -q 'UNEXECUTED-RUN' <<<"$OUT"; then
    ok "a mixed band (one run executed, one did not) is RED — one aborted run cannot excuse a red beside it"
else
    bad "846 17f" "expected rc 5 on a mixed band, got rc=$RC:
$OUT"
fi

echo "--- 17g. aborted run + a run still IN FLIGHT → PENDING (rc 3), not a plumbing verdict ---"
# UNEXECUTED sits BELOW pending in the precedence: a real run may yet speak, and
# announcing 'plumbing gap' while one is executing is the same over-claim in a
# new place.
obs_exec "completed failure unexecuted" "in_progress _ not-checked"
runa "$OBS"
if (( RC == 3 )) && ! grep -q 'UNEXECUTED-RUN\|^FAILED: ' <<<"$OUT"; then
    ok "an aborted run beside an in-flight one is PENDING (rc 3) — the live run may still speak"
else
    bad "846 17g" "expected rc 3 with no verdict finding, got rc=$RC:
$OUT"
fi

echo "--- 17j. A SKIPPED CELL STAYS RED even if the evidence says it executed nothing ---"
# THE DISCRIMINATOR IS `failure` WITH ZERO STEPS, NOT ZERO STEPS ALONE
# (your-org/nexus-code#846, and the report that filed it:
# reports/civerdict2_2026-08-08_152622_837-844-banked-local-evidence.md).
# A legitimately SKIPPED matrix cell also reports zero steps. Keying the
# downgrade on the steps count by itself would reclassify skipped runs — which
# #628 already rules RED as an absence of verdict — and that would re-open a
# hole this repo closed, INSIDE the fix that closes its sibling.
#
# So this fixture is deliberately CONTRADICTORY: a `skipped` conclusion carrying
# the `unexecuted` token, i.e. an enricher that has malfunctioned in the exact
# direction that would be dangerous. The audit must still report NO-VERDICT,
# because classify_runs() consults execution evidence ONLY for runs whose
# conclusion is `failure`. Asserting it against a well-behaved input would prove
# nothing: the conclusion gate is invisible unless the two inputs disagree.
obs_exec "completed skipped unexecuted every job ran zero steps"
runa "$OBS"
if (( RC == 4 )) && grep -q '^NO-VERDICT: tests.yml' <<<"$OUT" \
   && grep -q 'Conclusions seen: skipped' <<<"$OUT" \
   && ! grep -q 'UNEXECUTED-RUN' <<<"$OUT"; then
    ok "a skipped run + an 'unexecuted' token is still NO-VERDICT (rc 4) — the gate is the CONCLUSION, not the step count"
else
    bad "846 17j" "expected rc 4 + NO-VERDICT(skipped), got rc=$RC:
$OUT"
fi

echo "--- 17k. …and a cancelled cell likewise (second witness for the conclusion gate) ---"
obs_exec "completed cancelled unexecuted zero steps here too"
runa "$OBS"
if (( RC == 4 )) && grep -q '^NO-VERDICT: tests.yml' <<<"$OUT" \
   && grep -q 'Conclusions seen: cancelled' <<<"$OUT" \
   && ! grep -q 'UNEXECUTED-RUN' <<<"$OUT"; then
    ok "cancelled + 'unexecuted' is still NO-VERDICT — one witness could be an accident of the skipped path"
else
    bad "846 17k" "expected rc 4 + NO-VERDICT(cancelled), got rc=$RC:
$OUT"
fi

echo "--- 17h. the two messages send readers to DIFFERENT places ---"
# Separating the exit codes is cosmetic if the prose is interchangeable. The
# corrected FAILED wording is asserted here too: #846 required the sentence and
# the logic to move together, since a corrected sentence beside unchanged logic
# would be its own defect.
if grep -q 'Fix the ACCOUNT or the RUNNER' <<<"$UNEXEC_OUT" \
   && grep -q 'no logs to read' <<<"$UNEXEC_OUT" \
   && ! grep -q 'read the run.s logs and fix the code' <<<"$UNEXEC_OUT" \
   && grep -q 'check the run.s jobs' <<<"$UNKNOWN_OUT" \
   && ! grep -q 'this is not a CI-plumbing gap' <<<"$UNKNOWN_OUT"; then
    ok "UNEXECUTED-RUN points at the account, the unmeasured FAILED withholds the 'not a plumbing gap' claim"
else
    bad "846 17h" "the messages are not distinct, or the unmeasured FAILED still over-claims:
--- UNEXECUTED ---
$UNEXEC_OUT
--- UNMEASURED FAILED ---
$UNKNOWN_OUT"
fi

# ===========================================================================
# 17i. VACUITY CONTROL for #846, the same discipline as cases 11 and 13.
#      Neuter the execution check — make `spoke` keep every failing run, i.e.
#      exactly the pre-#846 behaviour — and confirm 17b goes back to rc 5
#      FAILED. That the mutant reds it is what proves the new classifier is
#      what downgrades it, rather than some incidental property of the fixture.
#      An assertion never observed failing is not evidence.
# ===========================================================================
echo "--- 17i. vacuity control: with the execution check neutered, 17b reverts to FAILED (rc 5) ---"
MUTANT846="$TMP/mutant-exec.py"
sed 's/^    spoke = \[r for r in red if r.executed not in UNEXECUTED_EVIDENCE\]$/    spoke = red  # NEGATIVE-CONTROL MUTANT (#846)/' \
    "$AUDIT" > "$MUTANT846"
if ! grep -q 'NEGATIVE-CONTROL MUTANT (#846)' "$MUTANT846"; then
    bad "mutation apply 846" "the classify_runs execution-filter anchor changed; the vacuity-control sed no longer applies — update it"
else
    run_mut846() { OUT=$(python3 "$MUTANT846" --workflows-dir "$FIX" --base-ref dev \
        --changed-files "$TMP/changed-593.txt" --observed "$1" --self-workflow ci-signal.yml 2>&1); RC=$?; }
    obs_exec "completed failure unexecuted"; run_mut846 "$OBS"
    if (( RC == 5 )) && grep -q '^FAILED: tests.yml' <<<"$OUT" \
       && ! grep -q 'UNEXECUTED-RUN' <<<"$OUT"; then
        ok "mutant (execution check removed) reproduces the filed defect — a zero-step failure reads as a real red at rc 5"
    else
        bad "846 17i" "mutant did not reproduce #846 (rc=$RC); 17b proves nothing:
$OUT"
    fi
    # Liveness: the mutant must still be a working audit, or its rc-5 above
    # would be breakage rather than the removed check.
    obs_exec "completed success not-checked"; run_mut846 "$OBS"
    if (( RC == 0 )); then
        ok "mutant still audits (greens a real success) — its 17b red is the removed check, not damage"
    else
        bad "846 17i sanity" "mutant failed even on a success (rc=$RC) — it is broken, not merely neutered:
$OUT"
    fi
fi

# ===========================================================================
# 18. monitor/ci-run-execution.sh, exercised against a STUB gh — the script that
#     DERIVES the tokens case 17 consumes. Two halves that a happy-path test
#     would not separate, and the second is the one that matters:
#
#       * the COST argument: a row whose conclusion is not `failure` must spend
#         ZERO API calls. Asserted from the stub's call log, not inferred from
#         the output looking right.
#       * the ASYMMETRY argument: every shape that is merely UNREADABLE must
#         emit `unknown`, never `unexecuted`. `null | length` is 0 in jq, so a
#         job with NO steps field would count as an empty steps array unless the
#         type is checked — "no data" wearing "zero" as a costume, which is the
#         one substitution this feature may not make.
# ===========================================================================
echo "--- 18. ci-run-execution.sh: zero calls off the failure path, \`unknown\` on every unreadable shape ---"
EXECSH="$_test_dir/ci-run-execution.sh"
if [[ ! -x "$EXECSH" ]]; then
    bad "run execution" "monitor/ci-run-execution.sh is missing or not executable; ci-signal.yml runs it"
elif ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP: jq unavailable — the enricher cannot be exercised here (declined, not passed)."
else
    STUB="$TMP/stubbin"
    mkdir -p "$STUB"
    # The stub answers /jobs from a payload file the case under test writes, and
    # logs every invocation so "did not call gh" is read from the log.
    #
    # IT HONOURS `--jq`, by shelling out to the real jq. A stub that ignored the
    # flag and returned raw JSON would let 18b's `grep account payments` pass
    # against a payload the production path never produces — the assertion would
    # be testing the stub's laziness rather than the script's extraction. (This
    # is not hypothetical: the first draft did exactly that, and the emitted
    # detail was a raw `[{"message":…}]` array where live output is a bare
    # sentence.)
    #
    # It also answers `--version`, because this workspace force-fronts a
    # capability-probing `gh` wrapper (`monitor/ghwrap/gh`) ahead of any stub on
    # PATH: the wrapper probes `gh --version`, then execs the first candidate
    # meeting its floor — this stub. See the call-counting note in exec_tok.
    cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
jqexpr=""; prev=""
for a in "$@"; do
    [[ "$prev" == "--jq" ]] && jqexpr="$a"
    prev="$a"
done
emit() { if [[ -n "$jqexpr" ]]; then jq -r "$jqexpr"; else cat; fi; }
case "$*" in
    *--version*)      printf 'gh version 2.99.0 (test stub)\nhttps://example.invalid\n' ;;
    *"/jobs"*)        emit < "$JOBS_PAYLOAD" ;;
    *"/annotations"*) printf '[{"message":"The job was not started because recent account payments have failed"}]\n' | emit ;;
    *)                printf '{}\n' | emit ;;
esac
STUBEOF
    chmod +x "$STUB/gh"

    # exec_tok <conclusion> <jobs-json> — run the enricher on one row; sets
    # TOK, DET and CALLS (the number of gh invocations).
    exec_tok() {
        local concl="$1" payload="$2" out
        printf '%s' "$payload" > "$TMP/jobs.json"
        : > "$TMP/gh-calls.log"
        out=$(PATH="$STUB:$PATH" GH_CALL_LOG="$TMP/gh-calls.log" \
              JOBS_PAYLOAD="$TMP/jobs.json" \
              bash "$EXECSH" --repo o/r \
              <<<".github/workflows/tests.yml	completed	${concl}	1	4242	")
        TOK=$(cut -f7 <<<"$out"); DET=$(cut -f8 <<<"$out")
        # API calls, counted as `api` invocations rather than as stub
        # invocations. This workspace force-fronts a capability-probing `gh`
        # wrapper ahead of anything on PATH, so every real call arrives at the
        # stub preceded by a `gh --version` probe. Counting raw invocations
        # would measure the WRAPPER and make this assertion pass or fail on
        # which machine ran it — 4 here, 2 on a bare CI runner, for identical
        # behaviour. `api` lines are what "an API call was spent" means, in
        # both environments. NOT `grep -c`, which exits 1 on zero matches and
        # would manufacture a count from a failure.
        CALLS=$(awk '/^api /{ n++ } END { print n+0 }' "$TMP/gh-calls.log")
    }

    # The REAL shape, transcribed from run 31281274254 on this repo
    # (2026-08-08, the account-billing block): steps present as an EMPTY ARRAY,
    # runner never assigned.
    BILLING='{"total_count":2,"jobs":[
      {"name":"a","conclusion":"failure","steps":[],"runner_id":0,"runner_name":"","check_run_url":"https://api.github.com/repos/o/r/check-runs/931"},
      {"name":"b","conclusion":"failure","steps":[],"runner_id":0,"runner_name":""}]}'
    # And the contrast, from run 31273255314 the same afternoon: a real red.
    REALRED='{"total_count":2,"jobs":[
      {"name":"a","conclusion":"failure","steps":[{"number":1},{"number":2}],"runner_id":1000007946,"runner_name":"GitHub Actions 1000007946"},
      {"name":"b","conclusion":"success","steps":[{"number":1}],"runner_id":1000007946,"runner_name":"GitHub Actions 1000007946"}]}'

    exec_tok success "$BILLING"
    if [[ "$TOK" == "not-checked" ]] && (( CALLS == 0 )); then
        ok "18a a non-failure row is 'not-checked' and costs ZERO gh calls (the cost argument, read from the call log)"
    else
        bad "18a" "want not-checked with 0 calls, got token='$TOK' calls=$CALLS"
    fi

    exec_tok failure "$BILLING"
    # The call count is ASSERTED, not left in a header comment: the script
    # claims "one jobs call per failing run, and one further annotations call
    # ONLY on a run already classified `unexecuted`". Two is that claim.
    if [[ "$TOK" == "unexecuted" ]] && grep -q 'account payments have failed' <<<"$DET" \
       && (( CALLS == 2 )); then
        ok "18b the real billing-block payload → 'unexecuted', carrying GitHub's own annotation, for exactly 2 calls (jobs + annotations)"
    else
        bad "18b" "want unexecuted + the annotation in 2 calls, got token='$TOK' calls=$CALLS detail='$DET'"
    fi

    # THE MIXED RUN (PR #854 skeptic, F2). One job ran, one never started. The
    # docstring predicted `unknown` and the code returned `executed`; both were
    # wrong, and `executed` is the dangerous one, because the token selects
    # which MESSAGE prints and `executed` licenses "this is not a CI-plumbing
    # gap" — false of a run that is partly one.
    exec_tok failure '{"total_count":2,"jobs":[
      {"name":"a","conclusion":"failure","steps":[{"number":1}],"runner_id":9,"runner_name":"GitHub Actions 9"},
      {"name":"b","conclusion":"failure","steps":[],"runner_id":0,"runner_name":""}]}'
    if [[ "$TOK" == "mixed" ]] && grep -q 'part of this run never started' <<<"$DET"; then
        ok "18j a MIXED run → 'mixed', not 'executed' — the token that would have licensed the strong sentence is withheld"
    else
        bad "18j" "want mixed, got token='$TOK' detail='$DET'"
    fi
    # …and `mixed` must still be RED end-to-end, with the softened tail. The
    # token is a message selector, never a gate: the verdict is unchanged.
    printf '%s\n' ".github/workflows/tests.yml	completed	failure	1	4242		mixed	1 of 2 job(s) ran at least one step; the other 1 ran none — the red is real, but part of this run never started" > "$TMP/obs-mixed.txt"
    runa "$TMP/obs-mixed.txt"
    if (( RC == 5 )) && grep -q '^FAILED: tests.yml' <<<"$OUT" \
       && grep -q 'MEASURED and is MIXED' <<<"$OUT" \
       && ! grep -q 'this is not a CI-plumbing gap' <<<"$OUT" \
       && ! grep -q 'UNEXECUTED-RUN' <<<"$OUT"; then
        ok "18k …and 'mixed' still reds at rc 5 while WITHHOLDING 'this is not a CI-plumbing gap' — a message selector, never a gate"
    else
        bad "18k" "expected rc 5 + FAILED with the mixed tail and no plumbing-gap claim, got rc=$RC:
$OUT"
    fi

    # An enumeration that cannot be vouched complete does not license "every
    # job ran" either, even when a step is positively known to have run.
    exec_tok failure '{"total_count":9,"jobs":[{"name":"a","conclusion":"failure","steps":[{"number":1}],"runner_id":9,"runner_name":"x"}]}'
    if [[ "$TOK" == "mixed" ]] && grep -q 'INCOMPLETE' <<<"$DET"; then
        ok "18l a TRUNCATED page with a step known to have run → 'mixed' — something ran, and 'everything ran' is unestablished"
    else
        bad "18l" "want mixed on a truncated page with positive execution, got token='$TOK' detail='$DET'"
    fi

    # THE CORROBORATOR'S OWN RIGOR (PR #854 skeptic, F3). `(.runner_id // 0)`
    # coerced an ABSENT field to the exculpatory 0 — the identical coercion this
    # script refuses for `.steps`. Absence is not an observation that no runner
    # was assigned.
    exec_tok failure '{"total_count":1,"jobs":[{"name":"a","conclusion":"failure","steps":[]}]}'
    if [[ "$TOK" == "unknown" ]] && grep -q 'no runner fields at all' <<<"$DET"; then
        ok "18m zero steps with the runner fields ABSENT → 'unknown' — the rule the primary signal follows now binds the corroborator too"
    else
        bad "18m" "want unknown when runner fields are absent, got token='$TOK' detail='$DET'"
    fi

    exec_tok failure "$REALRED"
    # One call, not two: the annotations lookup is on the `unexecuted` path
    # only, so the common case — a genuine red — does not pay for it.
    if [[ "$TOK" == "executed" ]] && (( CALLS == 1 )); then
        ok "18c the real red payload → 'executed' in ONE call — proves 18b keys on the steps/runner evidence, and that annotations are not fetched off that path"
    else
        bad "18c" "want executed in 1 call, got token='$TOK' calls=$CALLS detail='$DET'"
    fi

    # THE COSTUME CASE. `steps` absent entirely: jq's `null | length` is 0, so
    # an unguarded count reads this as "zero steps executed" and downgrades a
    # red on the strength of a field that was never there.
    exec_tok failure '{"total_count":1,"jobs":[{"name":"a","conclusion":"failure","runner_id":0,"runner_name":""}]}'
    if [[ "$TOK" == "unknown" ]] && grep -q 'absent field is not an empty one' <<<"$DET"; then
        ok "18d a job with NO steps field → 'unknown', not 'unexecuted' — null|length==0 does not become evidence"
    else
        bad "18d" "want unknown (absent steps array), got token='$TOK' detail='$DET'"
    fi

    exec_tok failure '{"total_count":9,"jobs":[{"name":"a","conclusion":"failure","steps":[],"runner_id":0,"runner_name":""}]}'
    if [[ "$TOK" == "unknown" ]] && grep -q 'INCOMPLETE' <<<"$DET"; then
        ok "18e a TRUNCATED jobs page → 'unknown' — a hidden job may have executed"
    else
        bad "18e" "want unknown (incomplete enumeration), got token='$TOK' detail='$DET'"
    fi

    exec_tok failure '{"total_count":0,"jobs":[]}'
    if [[ "$TOK" == "unknown" ]] && grep -q 'EMPTY' <<<"$DET"; then
        ok "18f an EMPTY jobs list → 'unknown' — zero jobs returned is not zero steps executed"
    else
        bad "18f" "want unknown (empty jobs list), got token='$TOK' detail='$DET'"
    fi

    exec_tok failure '{"total_count":1,"jobs":[{"name":"a","conclusion":"failure","steps":[],"runner_id":77,"runner_name":"GitHub Actions 77"}]}'
    if [[ "$TOK" == "unknown" ]] && grep -q 'ambiguous, not exculpatory' <<<"$DET"; then
        ok "18g zero steps but a runner WAS assigned → 'unknown' — the two signals must agree"
    else
        bad "18g" "want unknown (runner assigned), got token='$TOK' detail='$DET'"
    fi

    # A row the enricher emits must survive the round trip into the audit with
    # its columns intact — the wire format is the seam where a positional TSV
    # silently shifts, which is the family of defect the audit exists to report.
    # THE CONCLUSION GATE, at the producer end. A `skipped` matrix cell reports
    # zero steps too, so if this script measured every row it would hand the
    # audit an `unexecuted` token for a run #628 already rules RED. It is fed
    # the SAME all-zero-steps payload that produced `unexecuted` in 18b — the
    # only thing varying is the conclusion — and it must not even look.
    exec_tok skipped "$BILLING"
    if [[ "$TOK" == "not-checked" ]] && (( CALLS == 0 )); then
        ok "18i a SKIPPED row is never measured, on the very payload that reads 'unexecuted' for a failure — zero steps alone is not the discriminator"
    else
        bad "18i" "want not-checked with 0 calls for a skipped row, got token='$TOK' calls=$CALLS"
    fi

    exec_tok failure "$BILLING"
    printf '%s\n' ".github/workflows/tests.yml	completed	failure	1	4242		${TOK}	${DET}" > "$TMP/obs-roundtrip.txt"
    runa "$TMP/obs-roundtrip.txt"
    if (( RC == 4 )) && grep -q '^UNEXECUTED-RUN: tests.yml' <<<"$OUT"; then
        ok "18h the enricher's own output round-trips into the audit as UNEXECUTED-RUN (rc 4) — the wire format holds"
    else
        bad "18h" "the enricher's row did not classify as UNEXECUTED-RUN (rc=$RC):
$OUT"
    fi
fi

# ===========================================================================
echo
if (( FAIL > 0 )); then
    printf '%d passed, %d FAILED\n' "$PASS" "$FAIL"
    exit 1
fi
printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
exit 0
