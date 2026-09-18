#!/usr/bin/env bash
# Differential manifest for lint-workflows.py rule family EB
# (your-org/nexus-code#784).
#
# Run: bash monitor/test-lint-errexit-branch.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHAT MAKES THIS DIFFERENT FROM A FIXTURE LIST. EB's coverage boundary is a
# claim about BASH: "these are the syntactic positions in which a failing
# command does not abort the step, and the lint agrees with every one of them."
# A prose boundary cannot be made to fail, and a fixture list whose expected
# verdicts were typed by the same person who wrote the rule only pins the
# rule against itself. So the boundary is pinned as DATA — the SHAPES table
# below — and each row is adjudicated by a REAL BASH rather than by an
# expectation:
#
#   ground truth   run the shape under `bash -e` with a FAILING producer and
#                  observe whether execution reaches past the status read.
#   lint verdict   put the same bytes through lint-workflows.py --scan-body.
#   the assertion  they must AGREE. A shape the lint calls safe that bash
#                  aborts is a missed defect; a shape the lint flags that bash
#                  runs through is a false alarm. Either is red here.
#
# So nobody has to be trusted about what errexit does. Adding a row to SHAPES
# extends the boundary and is immediately adjudicated; the boundary cannot
# drift away from the shell without this test going red.
#
# Layer 3 mutates the LINT and requires the manifest to notice. A manifest that
# agrees with bash no matter what the lint says is not evidence.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$HERE/lint-workflows.py"
PY="${PYTHON:-python3}"
TMP="$(mktemp -d -t eb-manifest-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }

# --- layer 0: preconditions ------------------------------------------------
# Dependencies are ASSERTED, never skipped over: a guard that silently stops
# guarding is the defect class this whole family exists inside.
[ -f "$LINT" ] || { echo "FAIL: lint not found at $LINT" >&2; exit 1; }
command -v "$PY" >/dev/null 2>&1 || {
  echo "FAIL: $PY unavailable — this guard cannot run, and a guard that cannot" >&2
  echo "      run must not read as green" >&2; exit 1; }
BASH_BIN="${BASH_FOR_MANIFEST:-$(command -v bash)}"
[ -x "$BASH_BIN" ] || { echo "FAIL: no bash to adjudicate against" >&2; exit 1; }
bash_ver="$("$BASH_BIN" -c 'echo "$BASH_VERSION"')"
echo "adjudicating against: $BASH_BIN ($bash_ver)"
ok "preconditions: lint present, python3 present, bash present"

# --------------------------------------------------------------------------
# THE MANIFEST. One row per PROTECTION SHAPE — the axis the mechanism varies
# on. Not one row per file searched, and not one row per spelling of the read:
# `$?`, `${PIPESTATUS[0]}` and a `$?` buried in an `echo` are the same shape
# and are deliberately NOT separate rows, while `cmd; read` and `cmd || read`
# ARE separate rows because bash treats them differently.
#
# Every snippet:
#   * has a producer that FAILS (`exit 7`, `false`, …), because the whole
#     defect is invisible on the passing path;
#   * reads the status;
#   * then echoes REACHED. Whether REACHED appears is the ground truth.
# --------------------------------------------------------------------------
mkdir -p "$TMP/shapes"
SHAPE_NAMES=()
shape() {
  local name="$1"
  SHAPE_NAMES+=("$name")
  cat > "$TMP/shapes/$name.sh"
}

# ---- shapes bash ABORTS on: the read is dead code -------------------------
shape bare-sequential <<'EOF'
set -uo pipefail
false
rc=$?
echo "REACHED rc=$rc"
EOF

shape assignment-cmdsub <<'EOF'
set -uo pipefail
out=$(echo captured; exit 7); rc=$?
printf '%s\n' "$out"
echo "REACHED rc=$rc"
EOF

shape pipeline-with-pipefail <<'EOF'
set -uo pipefail
(exit 3) | tee /dev/null
rc=${PIPESTATUS[0]}
echo "REACHED rc=$rc"
EOF

shape status-inside-echo <<'EOF'
set -uo pipefail
false
echo "band exit=$? (the verdict is below, not this)"
echo "REACHED"
EOF

shape and-list-final-element <<'EOF'
set -uo pipefail
true && false
rc=$?
echo "REACHED rc=$rc"
EOF

shape or-list-failing-final <<'EOF'
set -uo pipefail
false || false
rc=$?
echo "REACHED rc=$rc"
EOF

# The shape that caught a real hole in the lint: an ENV-PREFIXED COMMAND looks
# like a plain assignment at its left edge. Reading it as one silently
# un-detected two of the five known #784 instances — both SLOW-band
# invocations of the form `VAR=1 VAR2=1 env -u … bash run-tests.sh …`. Row
# added the moment the historical replay disagreed, so the hole cannot reopen
# unnoticed.
#
# (The env-var names are deliberately NOT spelled out above, because
# run-tests.sh LABELS a file `slow` by grepping its CONTENTS for the gate
# variable, so a mere MENTION in a comment makes `--list` mis-report this test
# as gated. That is cosmetic and nothing more: the grep lives inside
# run-tests.sh's `list_only` branch, which prints and exits, and the fast band
# is built by an explicit `find` in tests.yml that passes every file. An
# earlier revision of this comment claimed the mention "demotes this test out
# of the fast PR band"; that consequence was asserted without being measured
# and is FALSE — both tests added here run in the fast band regardless.
# Corrected after the #809 skeptic reproduced the actual behaviour. Recorded
# rather than deleted: this file's entire argument is that a stated
# consequence nobody executed is not evidence, and the comment was an instance
# of exactly that.)
shape env-prefixed-command <<'EOF'
set -uo pipefail
FOO=1 BAR=2 env -u NOPE sh -c 'exit 7'
rc=$?
echo "REACHED rc=$rc"
EOF

shape genuine-assignment-then-read <<'EOF'
set -uo pipefail
FOO="a b c"
rc=$?
echo "REACHED rc=$rc"
EOF

shape errexit-re-enabled <<'EOF'
set +e -uo pipefail
set -e
false
rc=$?
echo "REACHED rc=$rc"
EOF

shape subshell-producer <<'EOF'
set -uo pipefail
( exit 5 )
rc=$?
echo "REACHED rc=$rc"
EOF

shape brace-group-producer <<'EOF'
set -uo pipefail
{ echo a; false; } > /dev/null
rc=$?
echo "REACHED rc=$rc"
EOF

# The two CLOSER rows. A failing command inside a `then` block or a loop body
# aborts the step just as it would anywhere else, so a read after `fi`/`done`
# cannot observe it. The lint used to exempt closers as if they were openers —
# a MISSED detection, i.e. the dangerous direction — and these rows are what
# would have caught it.
shape after-fi-failing-body <<'EOF'
set -uo pipefail
if true; then
  false
fi
rc=$?
echo "REACHED rc=$rc"
EOF

shape after-done-failing-body <<'EOF'
set -uo pipefail
for i in 1; do
  false
done
rc=$?
echo "REACHED rc=$rc"
EOF

# ---- shapes bash RUNS THROUGH: the read is reachable ----------------------
shape or-rc-remedy <<'EOF'
set -uo pipefail
rc=0
false || rc=$?
echo "REACHED rc=$rc"
EOF

shape or-true-then-read <<'EOF'
set -uo pipefail
false || true
rc=$?
echo "REACHED rc=$rc"
EOF

shape errexit-cleared <<'EOF'
set +e -uo pipefail
(exit 3) | tee /dev/null
rc=${PIPESTATUS[0]}
echo "REACHED rc=$rc"
EOF

shape if-condition <<'EOF'
set -uo pipefail
if false; then
  echo "green"
else
  echo "red rc=$?"
fi
echo "REACHED"
EOF

shape while-condition <<'EOF'
set -uo pipefail
while false; do
  echo "body rc=$?"
done
echo "REACHED"
EOF

shape test-then-break-in-loop <<'EOF'
set -uo pipefail
rc=3
for i in 1 2; do
  [ "$rc" -ne 3 ] && break
  rc=0
done
echo "REACHED rc=$rc"
EOF

shape pipeline-no-pipefail <<'EOF'
set -u
(exit 3) | cat
rc=${PIPESTATUS[0]}
echo "REACHED rc=$rc"
EOF

shape heredoc-body-is-data <<'EOF'
set -uo pipefail
cat > /dev/null <<'SCRIPT'
some-command-that-fails
rc=$?
echo "this is another interpreter's problem"
SCRIPT
echo "REACHED"
EOF

shape read-before-any-command <<'EOF'
set -uo pipefail
rc=$?
echo "REACHED rc=$rc"
EOF

# A `case` word expansion cannot fail, so a `$?` inside a branch observes
# whatever ran BEFORE the case. The lint flagged this until the row was added.
shape case-branch-reads-status <<'EOF'
set -uo pipefail
false || true
case "x" in
  a) echo "no" ;;
  x) echo "REACHED rc=$?" ;;
esac
EOF

# --- layer 1: the differential ---------------------------------------------
# `pipeline-no-pipefail` is the one row whose snippet must NOT be scanned with
# pipefail pre-set; every other row sets its own options in its first line.
echo "-- layer 1: bash ground truth vs lint verdict, one row per shape --"
n_abort=0
n_reach=0
for name in "${SHAPE_NAMES[@]}"; do
  f="$TMP/shapes/$name.sh"
  # ground truth: does execution get past the status read?
  out="$("$BASH_BIN" -e "$f" 2>&1)" || true
  if grep -q REACHED <<<"$out"; then
    truth=reachable
    n_reach=$((n_reach + 1))
  else
    truth=aborted
    n_abort=$((n_abort + 1))
  fi
  # lint verdict on the same bytes
  if "$PY" "$LINT" --scan-body "$f" > "$TMP/scan.out" 2>&1; then
    verdict=clean
  else
    verdict=flagged
  fi
  # agreement: bash aborted <=> the lint flagged it
  if { [ "$truth" = aborted ] && [ "$verdict" = flagged ]; } \
  || { [ "$truth" = reachable ] && [ "$verdict" = clean ]; }; then
    ok "$(printf '%-26s bash=%-9s lint=%s' "$name" "$truth" "$verdict")"
  else
    bad "$(printf '%-26s bash=%-9s lint=%s  — DISAGREEMENT' \
              "$name" "$truth" "$verdict")"
    sed 's/^/         /' "$TMP/scan.out" >&2
  fi
done

# --- layer 2: non-vacuity of the manifest itself ---------------------------
# A manifest that is all-clean or all-flagged would pass layer 1 while pinning
# nothing. Both verdicts must be REPRESENTED, and by more than one row each, or
# a single deleted row silently collapses the boundary.
echo "-- layer 2: the manifest exercises BOTH verdicts --"
if [ "$n_abort" -ge 4 ]; then
  ok "manifest carries $n_abort shapes bash ABORTS on (>= 4)"
else
  bad "manifest carries only $n_abort aborting shape(s) — the rule is barely watched"
fi
if [ "$n_reach" -ge 4 ]; then
  ok "manifest carries $n_reach shapes bash RUNS THROUGH (>= 4)"
else
  bad "manifest carries only $n_reach reachable shape(s) — false alarms are barely watched"
fi
if [ "${#SHAPE_NAMES[@]}" -ge 21 ]; then
  ok "manifest has ${#SHAPE_NAMES[@]} shapes (>= 21)"
else
  bad "manifest shrank to ${#SHAPE_NAMES[@]} shapes — a boundary that quietly narrowed"
fi

# --- layer 2b: the CORPUS boundary, also as data ---------------------------
# The manifest above pins WHICH SHAPES the rule decides correctly. It says
# nothing about WHICH FILES the rule is ever pointed at, and that is the other
# half of the coverage claim: `lint_dir` walks one directory, so a `run:` body
# living anywhere else is not merely undecided — it is unvisited, and a clean
# EB result would not know it existed.
#
# GitHub executes `run:` steps from composite actions (`.github/actions/*/
# action.yml`) exactly as it does from workflows, under the same `-e`. This
# repo has none today; the moment one appears, this assertion reddens and
# somebody makes a decision instead of inheriting a silent gap.
echo "-- layer 2b: every run:-bearing YAML in the repo is inside the scanned dir --"
if command -v git >/dev/null 2>&1 && git -C "$HERE/.." rev-parse --git-dir >/dev/null 2>&1; then
    # `git ls-files` (glob pathspecs), NOT `git ls-tree` (path PREFIXES) — the
    # latter returns a confident zero on a glob, which is the exact shape of
    # bug that would make this guard report "no strays" over nothing.
    strays=$(git -C "$HERE/.." ls-files -- '.github/**/*.yml' '.github/**/*.yaml' \
             | grep -v '^\.github/workflows/[^/]*$' || true)
    tracked=$(git -C "$HERE/.." ls-files -- '.github/workflows/*.yml' | wc -l)
    if [ "$tracked" -lt 3 ]; then
        bad "corpus: only $tracked workflow file(s) tracked — the enumeration is broken, not the corpus small"
    elif [ -z "$strays" ]; then
        ok "corpus: all $tracked run:-bearing YAML file(s) live in .github/workflows/, which is what EB scans"
    else
        bad "corpus: run:-bearing YAML OUTSIDE the scanned dir — EB never sees these, and a clean EB does not cover them:
$(printf '%s\n' "$strays" | sed 's/^/         /')"
    fi
else
    bad "corpus: not a git checkout — cannot enumerate the corpus, and 'could not look' is not 'looked and found none'"
fi

# --- layer 3: MUTANTS OF THE LINT ------------------------------------------
# Layer 1 green is a claim about the lint. Only this layer makes it a claim
# about the TEST. Each mutant removes one exemption or one detection and MUST
# produce a disagreement — if a mutant passes, layer 1 has stopped watching.
echo "-- layer 3: mutants of the lint must break the manifest --"
# The lint loads monitor/ci-trigger-audit.py relative to its OWN directory, so
# a mutant dropped in a bare temp dir dies at import — and a dying lint exits
# non-zero, which reads as "flagged" and would let every mutant pass for the
# wrong reason. Give the mutants a directory where that sibling resolves.
mkdir -p "$TMP/mutants"
ln -sf "$HERE/ci-trigger-audit.py" "$TMP/mutants/ci-trigger-audit.py"

mutant_check() {
  local label="$1" sedexpr="$2"
  local mut="$TMP/mutants/mutant-lint.py"
  if ! sed "$sedexpr" "$LINT" > "$mut" 2>"$TMP/sed.err"; then
    bad "mutant '$label' — sed itself failed: $(cat "$TMP/sed.err")"
    return
  fi
  if cmp -s "$mut" "$LINT"; then
    bad "mutant '$label' changed NOTHING — the sed no longer matches the lint"
    return
  fi
  # A mutant that CRASHES flags every shape and would sail through the
  # disagreement check below for entirely the wrong reason — the lint was
  # destroyed, not mutated. Observed on the first draft of this file, where a
  # malformed sed produced an empty file and the mutant "passed". So the
  # mutant must still be a working lint: exit 0 or 1 on a control body, never
  # a traceback.
  # rc alone cannot tell a crash from a finding — both are non-zero — so the
  # check is that STDERR is empty. A traceback is the signature of a destroyed
  # lint, and `--scan-body` writes findings to stdout only.
  printf 'set -uo pipefail\ntrue\necho ok\n' > "$TMP/mutant-control.sh"
  # `|| ctl=$?`, the very remedy this file exists to pin. This script runs
  # without errexit today, so the bare form would work — but writing the
  # defect back into the test that names it is exactly the slip this repo
  # keeps making, and the form should not depend on an ambient option.
  local ctl=0
  "$PY" "$mut" --scan-body "$TMP/mutant-control.sh" \
      >/dev/null 2>"$TMP/mutant-control.err" || ctl=$?
  if [ -s "$TMP/mutant-control.err" ] || [ "$ctl" -gt 1 ]; then
    bad "mutant '$label' does not RUN (exit $ctl, stderr: $(head -1 "$TMP/mutant-control.err")) — destroyed, not mutated"
    return
  fi
  local broke=0
  for name in "${SHAPE_NAMES[@]}"; do
    local f="$TMP/shapes/$name.sh" truth verdict out
    out="$("$BASH_BIN" -e "$f" 2>&1)" || true
    if grep -q REACHED <<<"$out"; then truth=reachable; else truth=aborted; fi
    if "$PY" "$mut" --scan-body "$f" >/dev/null 2>&1; then verdict=clean; else verdict=flagged; fi
    if { [ "$truth" = aborted ] && [ "$verdict" = clean ]; } \
    || { [ "$truth" = reachable ] && [ "$verdict" = flagged ]; }; then
      broke=$((broke + 1))
    fi
  done
  if [ "$broke" -gt 0 ]; then
    ok "mutant '$label' -> $broke shape(s) disagree, as required"
  else
    bad "mutant '$label' -> the manifest did NOT notice; layer 1 is not watching this"
  fi
}

# M1: stop exempting `cmd || rc=$?`. The remedy shape must start reading as a
#     violation, i.e. a false alarm on a body bash runs straight through.
mutant_check "no-||-exemption" 's#^    if op in ("||", "&&"):$#    if False:#'
# M2: stop skipping heredoc bodies. The generated-script shape must go flagged.
mutant_check "heredocs-not-skipped" 's|^        if pending:$|        if False:|'
# M3: stop tracking `set +e`. The two errexit-cleared shapes must go flagged.
mutant_check "set-+e-ignored" 's|^    m = _EB_SET_RE.match(stmt)$|    m = None|'
# M4: stop recognising PIPESTATUS while still recognising `$?`. The pipefail
#     pipeline shape must go clean while bash still aborts — a MISSED defect,
#     the dangerous direction, and the one a spelling-keyed rule would have.
mutant_check "PIPESTATUS-unrecognised" \
  's#^_EB_STATUS_RE = .*#_EB_STATUS_RE = re.compile(r"[$][?]")#'
# M5: stop exempting an `if`/`while` condition.
mutant_check "compound-head-ignored" \
  's|^    if _EB_COMPOUND_HEAD.match(prev_stmt) or prev_stmt.strip() in _EB_CONTROL_ONLY:$|    if False:|'

# --- verdict ---------------------------------------------------------------
# The assertion COUNT is checked, not just the failure count: a helper that
# vanished (rc 127, counted by nothing) would otherwise leave this file exiting
# 0 having asserted almost nothing.
echo
min_expected=$(( ${#SHAPE_NAMES[@]} + 5 + 5 ))
if [ "$pass" -lt "$min_expected" ]; then
  bad "only $pass assertions ran; expected at least $min_expected (${#SHAPE_NAMES[@]} shapes + 5 preconditions/non-vacuity/corpus + 5 mutants). Something stopped asserting."
fi
echo "passed: $pass   failed: $fail"
if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
fi
echo "SOME TESTS FAILED"
exit 1
