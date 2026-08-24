#!/usr/bin/env bash
# Regression guard for your-org/nexus-code#784 instances 4 and 5 — the two
# paste-probe steps in .github/workflows/tests.yml must keep their DIAGNOSTIC
# reachable.
#
# Run: bash monitor/test-paste-probe-step-contract.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE DEFECT. Both steps captured the probe's stdout AND stderr into `$out` and
# then read `rc=$?` on the same line:
#
#     out=$(bash monitor/watcher/test-paste-bracketed.sh 2>&1); rc=$?
#     printf '%s\n' "$out"
#
# GitHub runs `run:` bodies under `/usr/bin/bash -e {0}`, and `set -uo
# pipefail` does not clear `-e`. An assignment whose command substitution exits
# non-zero IS a failing command, so on a red probe the step died AT THE
# ASSIGNMENT — before `printf` echoed the captured output, and before the
# enumerated `::error::` that names ran/skipped/rc. The step still went red;
# what it lost was every word explaining why. Measured under bash 5.2 against
# the real body: the whole log was one `tmux …: paste-buffer -p supported=1`
# line and nothing else.
#
# Neither step was in #784's own enumeration — the issue listed three
# instances and these are the fourth and fifth, found by running the PROPERTY
# over every `run:` body instead of the filenames the issue named. That is the
# argument for lint-workflows.py's EB family; this file is the executable
# complement, in the same relationship monitor/test-slow-band-step-contract.sh
# has to its own step.
#
# THIS IS NOT A GREP OVER THE YAML. It EXTRACTS both real step bodies from
# .github/workflows/tests.yml and EXECUTES them under `bash -e` against a stub
# probe whose exit code and output it controls. A grep would pass on a body
# that still aborts; only running it can tell. Layer 2 then MUTATES the
# extracted body back to the pre-fix form and requires this guard to notice —
# a guard never observed failing is not evidence.
#
# tmux is STUBBED rather than driven. This host runs a live tmux server whose
# windows are parked on operator decisions, and a fixture has no business
# starting or touching one.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WF="$REPO/.github/workflows/tests.yml"
PY="${PYTHON:-python3}"
BASH_BIN="${BASH_FOR_CONTRACT:-$(command -v bash)}"

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }

# --- layer 0: preconditions, ASSERTED not skipped --------------------------
# A `SKIP` here would let this guard stop guarding the moment a runner image
# dropped PyYAML while the fast gate stayed green — a verdict-that-cannot-run
# living inside the remedy for a verdict-that-could-not-run.
command -v "$PY" >/dev/null 2>&1 || {
  echo "FAIL: $PY unavailable — a guard that cannot run must not read as green" >&2
  exit 1; }
"$PY" -c 'import yaml' 2>/dev/null || {
  echo "FAIL: PyYAML unavailable — this guard parses the real workflow" >&2
  exit 1; }
[ -f "$WF" ] || { echo "FAIL: workflow not found at $WF" >&2; exit 1; }
[ -x "$BASH_BIN" ] || { echo "FAIL: no bash to execute the bodies with" >&2; exit 1; }
echo "executing bodies with: $BASH_BIN ($("$BASH_BIN" -c 'echo $BASH_VERSION'))"

TMP="$(mktemp -d -t paste-probe-contract-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- extract both step bodies by NAME, never by index ----------------------
# Addressed by the step's `name:` so a step inserted above cannot silently
# retarget this test at another body.
"$PY" - "$WF" "$TMP" <<'PY' || { echo "FAIL: could not extract the step bodies" >&2; exit 1; }
import sys, yaml, os
wf, out = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(wf))
WANT = {
    "probe": "probe RUNS iff tmux supports paste-buffer -p (self-discovering)",
    "skip":  "SKIP branch — deterministic proof via a -p-stripping tmux shim",
}
found = {}
for job in (doc.get("jobs") or {}).values():
    for step in (job.get("steps") or []):
        if not isinstance(step, dict):
            continue
        for key, name in WANT.items():
            if step.get("name") == name and isinstance(step.get("run"), str):
                found[key] = step["run"]
missing = sorted(set(WANT) - set(found))
if missing:
    sys.stderr.write("step(s) not found by name: %s\n" % ", ".join(missing))
    sys.exit(1)
for key, body in found.items():
    open(os.path.join(out, "%s.sh" % key), "w").write(body)
PY
ok "extracted both paste-probe step bodies from the real tests.yml"

# --- the stubs -------------------------------------------------------------
mkdir -p "$TMP/repo/monitor/watcher" "$TMP/shim"
FAILMARK='FAIL: assertion 3 — the detail a reader needs to skip "is this flake?"'
{
  echo 'echo "app requested mode ?2004"'
  echo "echo '$FAILMARK' >&2"
  echo 'exit 1'
} > "$TMP/repo/monitor/watcher/test-paste-bracketed.sh"

# A tmux that reports `-p` as SUPPORTED, so the probe body takes its
# `supported=1` arm. No server is started, on purpose.
cat > "$TMP/shim/tmux" <<'SHIM'
#!/usr/bin/env bash
[ "$1" = "-V" ] && { echo "tmux 3.4"; exit 0; }
case " $* " in *" paste-buffer "*) echo "no buffer"; exit 1 ;; esac
exit 0
SHIM
chmod +x "$TMP/shim/tmux"

run_body() {
  # $1 = body file. Runs it exactly as GitHub does: `bash -e <file>`.
  ( cd "$TMP/repo" && PATH="$TMP/shim:$PATH" "$BASH_BIN" -e "$1" 2>&1 )
}

# --- layer 1: the CONTRACT, on the shipped bodies --------------------------
# Three properties, each named, because "the step went red" is not the
# contract — the contract is that a reader learns WHY.
echo "-- layer 1: the shipped bodies keep their diagnostic on a red probe --"
for key in probe skip; do
  body="$TMP/$key.sh"
  out="$(run_body "$body")"
  rc=0
  ( cd "$TMP/repo" && PATH="$TMP/shim:$PATH" "$BASH_BIN" -e "$body" >/dev/null 2>&1 ) || rc=$?

  if [ "$rc" -ne 0 ]; then
    ok "$key: still exits non-zero on a red probe (the step is a gate)"
  else
    bad "$key: exited 0 on a red probe — the step stopped gating"
  fi
  if grep -qF "$FAILMARK" <<<"$out"; then
    ok "$key: the probe's own failing-assertion output REACHES the log"
  else
    bad "$key: the probe's output was swallowed — this is #784 instances 4/5"
  fi
  if grep -q '::error::' <<<"$out"; then
    ok "$key: the enumerated ::error:: explanation is emitted"
  else
    bad "$key: no ::error:: — the branch that names ran/skipped/rc is dead code"
  fi
done

# --- layer 2: MUTANTS — revert the remedy, require this guard to notice ----
# Layer 1 green is a claim about the workflow. Only this layer makes it a claim
# about the TEST. Each mutant rewrites the extracted body back to the pre-fix
# shape; the diagnostic MUST vanish. If a mutant still shows the diagnostic,
# layer 1 is not watching the property it claims to.
echo "-- layer 2: the pre-fix shape must lose the diagnostic --"
for key in probe skip; do
  mut="$TMP/$key.mutant.sh"
  # `cmd || rc=$?`  ->  `cmd; rc=$?`, i.e. exactly instances 4 and 5 as they
  # stood on dev.
  sed 's#^\(\s*out=\$(.*\)) || rc=\$?#\1); rc=$?#' "$TMP/$key.sh" > "$mut"
  if cmp -s "$mut" "$TMP/$key.sh"; then
    bad "$key mutant: the rewrite matched nothing — the body no longer has the remedy shape this test knows"
    continue
  fi
  out="$(run_body "$mut")"
  if grep -qF "$FAILMARK" <<<"$out"; then
    bad "$key mutant: the diagnostic SURVIVED the pre-fix shape — this guard is not watching"
  else
    ok "$key mutant: reverting to \`; rc=\$?\` swallows the diagnostic, as #784 describes"
  fi
done

# --- layer 3: the lint agrees, on the same real file -----------------------
# The static rule and the executable contract are complements, and they must
# not disagree about the file they both look at.
echo "-- layer 3: EB is clean on the real tests.yml --"
lint_rc=0
"$PY" "$REPO/monitor/lint-workflows.py" --scan-body "$TMP/probe.sh" >/dev/null 2>&1 || lint_rc=$?
if [ "$lint_rc" -eq 0 ]; then
  ok "lint-workflows.py EB reports the shipped probe body clean"
else
  bad "lint-workflows.py EB flags the shipped probe body while layer 1 says it is fine — the two guards disagree"
fi

# --- verdict ---------------------------------------------------------------
# The assertion COUNT is checked: a helper that vanished (rc 127, counted by
# nothing) would otherwise leave this file exiting 0 having asserted little.
echo
if [ "$pass" -lt 10 ]; then
  bad "only $pass assertions ran; expected at least 10 (1 extraction + 6 contract + 2 mutants + 1 lint-agreement). Something stopped asserting."
fi
echo "passed: $pass   failed: $fail"
if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED"
  exit 0
fi
echo "SOME TESTS FAILED"
exit 1
