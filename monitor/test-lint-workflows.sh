#!/usr/bin/env bash
# Tests for monitor/lint-workflows.py — the guard that keeps a
# PR meta-edit's skip-run from evicting the code run that carries its head's
# verdict (your-org/nexus-code#628, gap re-found as #736).
#
# Run: bash monitor/test-lint-workflows.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Three layers, because each answers a different question:
#
#   1. the lint's own --selftest      does each RULE fire on its shape?
#   2. the REAL .github/workflows/    does the repo satisfy the property today?
#   3. MUTANTS of the REAL files      would a regression in the repo be CAUGHT?
#
# Layer 3 is the one that matters and the one usually skipped. A green from
# layer 2 is a claim about the corpus; only layer 3 makes it a claim about the
# TEST. Each mutant below strips the remedy back out of a real workflow and
# names the rule that must redden — if a mutant goes green, the lint has stopped
# watching that file and layer 2's green means nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LINT="$HERE/lint-workflows.py"
WF="$ROOT/.github/workflows"
PY="${PYTHON:-python3}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail + 1)); }

# --- layer 0: preconditions. A test that silently runs over nothing is the
#     defect this whole file exists to prevent, so assert the inputs exist
#     before asserting anything about them.
if [ ! -f "$LINT" ]; then
  echo "FAIL: lint not found at $LINT"; exit 1
fi
if [ ! -d "$WF" ]; then
  echo "FAIL: workflows dir not found at $WF"; exit 1
fi
wf_count=$(find "$WF" -maxdepth 1 -name '*.yml' -type f | wc -l)
if [ "$wf_count" -lt 3 ]; then
  echo "FAIL: only $wf_count workflow file(s) under $WF — refusing to report a"
  echo "      pass over a corpus that small; the enumeration is broken."
  exit 1
fi
ok "preconditions: lint present, $wf_count workflow file(s) to lint"

# --- layer 1: the lint's own negative control ------------------------------
echo "-- layer 1: the lint's --selftest (each rule watched to fire) --"
if "$PY" "$LINT" --selftest > "$TMP/selftest.out" 2>&1; then
  ok "--selftest exits 0"
else
  bad "--selftest exits $? (output below)"
  sed 's/^/       /' "$TMP/selftest.out"
fi
# The selftest must actually have exercised EVERY rule; a selftest that
# silently stopped covering one of them would still exit 0.
for rule in MC001 MC002 SR001 TD001 PF001; do
  if grep -q "$rule" "$TMP/selftest.out"; then
    ok "--selftest exercises $rule"
  else
    bad "--selftest never mentions $rule — a rule with no negative control"
  fi
done

# --- layer 2: the real corpus ----------------------------------------------
echo "-- layer 2: the repo's own workflows satisfy the property --"
if "$PY" "$LINT" "$WF" > "$TMP/real.out" 2>&1; then
  ok "real .github/workflows/ is clean"
else
  bad "real .github/workflows/ VIOLATES the property (output below)"
  sed 's/^/       /' "$TMP/real.out"
fi

# A clean lint over a corpus it declared entirely exempt is not evidence. Pin
# the workflows the property actually APPLIES to, so an edit that exempts one
# (dropping `edited`, dropping the concurrency block, dropping the job `if:`)
# shows up here as a failure rather than as a quieter green.
for wf in cc-harness.yml docs.yml tests.yml tests-slow-integration.yml; do
  if grep -q "checked (the property applies):.*$wf" "$TMP/real.out"; then
    ok "$wf is CHECKED, not exempted away"
  else
    bad "$wf is no longer in the lint's checked set — it became exempt silently"
  fi
done

# --- layer 3: mutants of the REAL workflow files ---------------------------
# Each mutant copies the whole real directory, strips the remedy out of ONE
# file, and asserts the named rule reddens. `sed` rewrites only the `group:`
# line of the target file, so every other file stays exactly as shipped.
echo "-- layer 3: mutants of the real files (each must redden a named rule) --"

# mutate <label> <file> <sed-expr> <expected-rule> [<sentinel-that-must-survive>]
# The sentinel is a shape the mutated file must STILL contain, proving the sed
# rewrote the line rather than deleting the construct wholesale. It defaults to
# the MC family's `group:` key; the TD mutants pass their own, since a workflow
# under a TD mutant need not have a concurrency block at all.
mutate() {
  local label="$1" file="$2" expr="$3" want="$4" sentinel="${5:-^  group:}"
  local dir="$TMP/mut-$label"
  rm -rf "$dir"; mkdir -p "$dir"
  cp "$WF"/*.yml "$dir/"
  sed -i "$expr" "$dir/$file"
  if ! grep -q "$sentinel" "$dir/$file"; then
    bad "$label: mutation left no \`$sentinel\` — the sed did not apply"
    return
  fi
  if cmp -s "$WF/$file" "$dir/$file"; then
    bad "$label: mutation changed nothing — a no-op mutant proves nothing"
    return
  fi
  local out="$TMP/mut-$label.out"
  "$PY" "$LINT" "$dir" > "$out" 2>&1
  local rc=$?
  if [ "$rc" -ne 1 ]; then
    bad "$label: lint exited $rc, wanted 1 (a violation) — MUTANT SURVIVED"
    sed 's/^/       /' "$out"
    return
  fi
  if grep -q "^$want: $file" "$out"; then
    ok "$label -> $want on $file"
  else
    bad "$label: lint went red but not with $want on $file"
    sed 's/^/       /' "$out"
  fi
}

# M1 — #736 itself: strip the event-class split back out of cc-harness.yml.
mutate "unsplit-cc-harness" "cc-harness.yml" \
  's|^  group: cc-harness-.*$|  group: cc-harness-${{ github.ref }}|' MC001

# M2 — the docs.yml site the sweep found: same strip, cancel-in-progress FALSE.
#      This is the mutant that pins the rule as NOT conditioned on cancel mode.
mutate "unsplit-docs" "docs.yml" \
  's|^  group: docs-.*$|  group: docs-${{ github.ref }}|' MC001

# M3 — the remediated flagship: strip tests.yml's split. If this survives, the
#      lint is not watching the file the whole pattern was copied from.
mutate "unsplit-tests" "tests.yml" \
  's|^  group: tests-.*$|  group: tests-${{ github.ref }}|' MC001

# M4 — the #628-skeptic near-miss, planted in a real file: key `-meta` on the
#      edited action ALONE, so a job-executing base retarget is filed beside
#      title-edit skip-runs. Reddens MC002, NOT MC001 — the rules are distinct.
mutate "action-only-split-cc-harness" "cc-harness.yml" \
  "s|^  group: cc-harness-.*\$|  group: cc-harness-\${{ github.ref }}-\${{ github.event.action == 'edited' \&\& 'meta' \|\| 'code' }}|" \
  MC002

# M5 — your-org/nexus-code#751/#749, planted in the file it actually happened
#      in: drop the SLOW band's explicit NEXUS_TEST_DEADLINE_SCALE. That is
#      the pre-#749 configuration verbatim — no --jobs, no scale, so
#      th_deadline's ceil(1/2) collapses to 1 and every deadline in a
#      blocking band of multi-minute tmux scenarios is its bare literal.
#      If this mutant survives, TD001 is not watching the band it was written
#      for. The sentinel is the invocation itself: the rule has nothing to say
#      about a file with no run-tests.sh in it.
mutate "unscaled-slow-band" "tests-slow-integration.yml" \
  '/NEXUS_TEST_DEADLINE_SCALE/d' TD001 'run-tests\.sh'

# M6 — the same strip in tests.yml, where the exposure is subtler: the matrix
#      still passes `--jobs`, but the `jobs: 2` cell is ceil(2/2) = 1. A rule
#      that accepted "some --jobs was passed" would survive this mutant, which
#      is exactly why it is here and not merely a duplicate of M5.
mutate "unscaled-unit-matrix" "tests.yml" \
  '/NEXUS_TEST_DEADLINE_SCALE/d' TD001 'jobs \${{ matrix.jobs }}'

# --- layer 3b: PF mutants, which need a REPO and not a flat dir ------------
#
# PF001 asks whether a filter covers the files the workflow REACHES ON DISK, so
# `mutate` above cannot serve it: that helper copies only the .yml files into a
# flat directory, where the repo root resolves to somewhere with no `monitor/`
# and every workflow exempts itself as "nothing reachable". A PF mutant has to
# stand inside a tree that looks like this repo. `monitor/` is SYMLINKED rather
# than copied — it is hundreds of files, and the lint only ever reads them.
echo "-- layer 3b: PF mutants (the filter-vs-closure property, in a real tree) --"

# mutate_pf <label> <file> <sed-expr> <expected-rule> <path-that-must-be-named>
mutate_pf() {
  local label="$1" file="$2" expr="$3" want="$4" named="$5"
  local dir="$TMP/pf-$label"
  rm -rf "$dir"; mkdir -p "$dir/.github/workflows"
  cp "$WF"/*.yml "$dir/.github/workflows/"
  ln -s "$ROOT/monitor" "$dir/monitor"
  sed -i "$expr" "$dir/.github/workflows/$file"
  if cmp -s "$WF/$file" "$dir/.github/workflows/$file"; then
    bad "$label: mutation changed nothing — a no-op mutant proves nothing"
    return
  fi
  local out="$TMP/pf-$label.out"
  "$PY" "$LINT" "$dir/.github/workflows" > "$out" 2>&1
  local rc=$?
  if [ "$rc" -ne 1 ]; then
    bad "$label: lint exited $rc, wanted 1 (a violation) — MUTANT SURVIVED"
    sed 's/^/       /' "$out"
    return
  fi
  if grep -q "^$want: $file" "$out" && grep -q "$named" "$out"; then
    ok "$label -> $want on $file, naming $named"
  else
    bad "$label: went red but not with $want on $file naming $named"
    sed 's/^/       /' "$out"
  fi
}

# CONTROL FIRST. The unmutated tree must be CLEAN through this same path, or a
# red below would be an artefact of the symlinked-tree rig rather than of the
# mutation. Without this, every PF mutant assertion is unfalsifiable.
pfctl="$TMP/pf-control"; rm -rf "$pfctl"; mkdir -p "$pfctl/.github/workflows"
cp "$WF"/*.yml "$pfctl/.github/workflows/"
ln -s "$ROOT/monitor" "$pfctl/monitor"
if "$PY" "$LINT" "$pfctl/.github/workflows" > "$TMP/pf-control.out" 2>&1; then
  ok "control: the real filters are clean when linted inside a repo-shaped tree"
else
  bad "control: the UNMUTATED tree is already red — PF mutants below prove nothing"
  sed 's/^/       /' "$TMP/pf-control.out"
fi

# P1 — your-org/nexus-code#765 ITSELF, restored. Strip the runner and the
#      helper module back out of cc-harness.yml's filter and the lint must name
#      them. This mutant IS the state of the repo before this fix, so its
#      reddening is the measurement that the fix is load-bearing rather than
#      cosmetic — and a future hand-edit that drops them again cannot pass.
mutate_pf "765-runner-and-helpers" "cc-harness.yml" \
  "\|monitor/watcher/run-tests.sh'|d; \|monitor/watcher/_test_helpers.sh'|d" \
  PF001 'monitor/watcher/run-tests.sh'

# P2 — the THREE-HOP edge, which no reader found by eye and which only the
#      derivation reaches (pane-state.sh -> _idle_probe.sh -> ../_submit_
#      evidence.sh, via an inline `$(dirname "${BASH_SOURCE[0]}")`). If the
#      resolver ever stops following that idiom, this mutant survives and says
#      so — whereas P1 alone would still pass on a resolver that had quietly
#      degraded to one hop.
mutate_pf "765-transitive-edge" "cc-harness.yml" \
  "\|monitor/_submit_evidence.sh'|d" \
  PF001 'monitor/_submit_evidence.sh'

# --- layer 4: fail-closed over a corpus it cannot read ---------------------
echo "-- layer 4: refusals (exit 2), never a quiet pass --"
badyaml="$TMP/badyaml"; mkdir -p "$badyaml"
cp "$WF"/*.yml "$badyaml/"
printf 'this: [is\n  not: valid yaml\n' > "$badyaml/broken.yml"
"$PY" "$LINT" "$badyaml" > "$TMP/broken.out" 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "an unparseable workflow file is REFUSED (exit 2)"
else
  bad "an unparseable workflow file gave exit $rc, wanted 2"
  sed 's/^/       /' "$TMP/broken.out"
fi

empty="$TMP/emptydir"; mkdir -p "$empty"
"$PY" "$LINT" "$empty" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "an empty workflows dir is REFUSED (exit 2), not reported clean"
else
  bad "an empty workflows dir gave exit $rc, wanted 2"
fi

echo
echo "passed: $pass   failed: $fail"
if [ "$fail" -ne 0 ]; then
  echo "TESTS FAILED"
  exit 1
fi
echo "ALL TESTS PASSED"
