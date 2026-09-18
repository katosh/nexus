#!/usr/bin/env bash
# Regression guard for your-org/nexus-code#739 — the SLOW band's verdict step
# must be REACHABLE.
#
# The defect this pins: GitHub runs `run:` bodies under `/usr/bin/bash -e {0}`.
# The band step opened with `set -uo pipefail` (which does NOT clear `-e`) and
# then invoked run-tests.sh UNGUARDED, so the first red test aborted the step
# mid-body. Neither the `ledger=` output nor the trailing echo ran, the
# `verdict` step was `skipped`, and monitor/slow-band-known-red.tsv +
# slow-band-drift.sh were never consulted. The #737 tolerance mechanism was
# inert on exactly the runs it exists for — the ones with a red SLOW test.
# Observed on run 31133525540 (`success` / `failure` / `skipped`, and the
# verdict was the skipped one).
#
# This is NOT a grep over the YAML. It EXTRACTS the band step's actual `run:`
# body from .github/workflows/tests-slow-integration.yml and EXECUTES it under
# `bash -e` against a stub run-tests.sh whose exit code it controls — the same
# ambient shell option the runner uses. A grep would pass on a body that still
# aborts; only running it can tell.
#
# Three mutants of the workflow body, each stripping one clause of the contract,
# must redden a NAMED assertion (a guard never observed failing is not
# evidence).
#
# Run directly: bash monitor/test-slow-band-step-contract.sh

set -uo pipefail

_here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REPO=$(cd "$_here/.." && pwd)
WF="$REPO/.github/workflows/tests-slow-integration.yml"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1" >&2; fail=$((fail+1)); }

# Dependencies are ASSERTED, never skipped over. A `SKIP` is not a failure —
# `run-tests.sh` is explicit that it must not turn the suite red — so exiting 77
# here would let this guard silently stop guarding the moment a runner image
# dropped PyYAML, while the fast gate stayed green. That is a
# verdict-that-cannot-run living inside the remedy for a
# verdict-that-could-not-run, i.e. this PR's own defect reproduced in its own
# fix. `monitor/test-lint-workflows.sh` sets the precedent: it assumes python3 +
# PyYAML and fails outright if they are absent. Raised by the #739 skeptic (F2).
command -v python3 >/dev/null 2>&1 || {
    echo "FAIL: python3 unavailable — this guard cannot run, and a guard that cannot run must not read as green" >&2
    exit 1; }
python3 -c 'import yaml' 2>/dev/null || {
    echo "FAIL: PyYAML unavailable — this guard parses the real workflow and cannot run without it" >&2
    exit 1; }
[ -f "$WF" ] || { echo "FAIL: workflow not found at $WF" >&2; exit 1; }

TMP=$(mktemp -d -t slow-band-contract-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# ---- extract the band step's run: body, and the verdict step's if: ----------
# Addressed by step `id: band` / by the drift-script invocation, never by index:
# a step inserted above must not silently retarget this test at another body.
python3 - "$WF" "$TMP" <<'PY' || { echo "FAIL: could not extract steps from the workflow" >&2; exit 1; }
import sys, yaml, pathlib
wf, out = sys.argv[1], pathlib.Path(sys.argv[2])
doc = yaml.safe_load(open(wf))
steps = doc["jobs"]["slow-band"]["steps"]
band = [s for s in steps if s.get("id") == "band"]
assert len(band) == 1, f"expected exactly one step with id: band, got {len(band)}"
out.joinpath("band.sh").write_text(band[0]["run"])
# The verdict step is the one that INVOKES the drift check on a real ledger.
# Substring matching alone is not enough: the band step's own comments name
# slow-band-drift.sh, and the selftest step invokes it too — hence the id and
# --selftest exclusions.
#
# MATCHED PER-LINE, NOT BY `startswith` ON THE WHOLE BODY
# (your-org/nexus-code#1283). The old form required the invocation to be the
# FIRST thing in the body, which silently encoded "the body is exactly one
# command" into a selector whose stated job is to FIND the step. The moment the
# step grew an exit-code `case` — needed so drift rc 4 (ENV-UNPROVEN) does not
# hard-fail the band — the selector matched NOTHING and the guard failed on its
# `len(verdict) == 1` assertion, i.e. it reported the step as ABSENT rather than
# as changed. A selector that answers "gone" when it means "different" is the
# false-zero shape this repo names as its dominant defect class.
#
# Fail-closed is preserved: the `len(verdict) == 1` assertion below still
# refuses zero matches AND refuses two, so a second real verdict step is still
# a red rather than a silent pick.
def _invokes_drift(body):
    return any(line.strip().startswith("bash monitor/slow-band-drift.sh")
               for line in str(body).splitlines())
verdict = [s for s in steps
           if s.get("id") != "band"
           and _invokes_drift(s.get("run", ""))
           and "--selftest" not in str(s.get("run", ""))]
assert len(verdict) == 1, f"expected exactly one real verdict step, got {len(verdict)}"
# `if:` may be absent -> empty string, which is what the assertion below rejects.
out.joinpath("verdict_if.txt").write_text(str(verdict[0].get("if", "")))
# THE BODY TOO (your-org/nexus-code#1283). Until now this suite extracted the
# verdict step's `if:` and never its `run:`, so the step's exit-code handling
# was PRESENT IN THE WORKFLOW AND EXECUTED BY NOTHING. That distinction is the
# whole point of the rc-4 arm: an arm that is merely present is indistinguishable
# from one that is unreachable, and both read identically in a diff.
out.joinpath("verdict.sh").write_text(str(verdict[0].get("run", "")))
# Positional fact: the verdict must come AFTER the band step it consumes.
out.joinpath("order.txt").write_text(
    "ok" if steps.index(verdict[0]) > steps.index(band[0]) else "bad")
PY

BAND_SRC="$TMP/band.sh"
VERDICT_SRC="$TMP/verdict.sh"

# run_verdict <ledger-file> -> "<rc>|<stdout+stderr>"
# Executes the REAL extracted step body under `bash -e`, exactly as the runner
# does, against a REAL ledger. The `${{ }}` expression the step uses for the
# ledger path is substituted the way Actions would, and nothing else is altered.
run_verdict() {
    local ledger="$1" d rc=0 out
    d=$(mktemp -d -t slow-band-verdict-XXXXXX)
    sed 's|\${{ steps.band.outputs.ledger }}|'"$ledger"'|g' "$VERDICT_SRC" > "$d/v.sh"
    out=$( cd "$REPO" && bash -e "$d/v.sh" 2>&1 ) || rc=$?
    printf '%s|%s\n' "$rc" "$out"
    rm -rf "$d"
}

# ---- fixture: a fake repo the band body can run against ---------------------
mk_fixture() {
    local d="$1"
    mkdir -p "$d/monitor/watcher"
    # One SLOW_TESTS-gated scenario so the body's discovery finds a non-empty
    # band (its own anti-vacuous-pass check is not what we are testing here).
    printf '#!/usr/bin/env bash\n# SLOW_TESTS gated fake\n' \
        > "$d/monitor/watcher/test-slowfake-1.sh"
    # Stub run-tests.sh: writes a ledger to --state, exits STUB_RC.
    cat > "$d/monitor/watcher/run-tests.sh" <<'STUB'
#!/usr/bin/env bash
state=""
while [ $# -gt 0 ]; do
    case "$1" in --state) state="$2"; shift 2 ;; *) shift ;; esac
done
if [ -n "$state" ] && [ "${STUB_LEDGER:-1}" = "1" ]; then
    printf '1\tmonitor/watcher/test-slowfake-1.sh\tFAIL\t1.00\t0\t?\n' > "$state"
fi
exit "${STUB_RC:-0}"
STUB
    chmod +x "$d/monitor/watcher/run-tests.sh"
}

# run_band <script> <stub_rc> <stub_writes_ledger> -> prints "<rc>|<ledger-out>"
# Executes the body exactly as the runner does: `bash -e <file>`.
run_band() {
    local script="$1" stub_rc="$2" stub_ledger="$3"
    local d; d=$(mktemp -d -t slow-band-fx-XXXXXX)
    mk_fixture "$d"
    local rt="$d/rt"; mkdir -p "$rt"
    local gho="$d/github_output"; : > "$gho"
    local rc=0
    ( cd "$d" && RUNNER_TEMP="$rt" GITHUB_OUTPUT="$gho" \
        STUB_RC="$stub_rc" STUB_LEDGER="$stub_ledger" \
        bash -e "$script" ) >"$d/stdout" 2>&1 || rc=$?
    local led; led=$(sed -n 's/^ledger=//p' "$gho" | tail -1)
    printf '%s|%s\n' "$rc" "$led"
    rm -rf "$d"
}

# mutate <name> <sed-expr...> -> path to a mutated copy of the band body
mutate() {
    local name="$1"; shift
    local m="$TMP/mutant-$name.sh"
    cp "$BAND_SRC" "$m"
    local e
    for e in "$@"; do
        python3 - "$m" "$e" <<'PY'
import sys, re, pathlib
p, expr = pathlib.Path(sys.argv[1]), sys.argv[2]
kind, _, rest = expr.partition(":")
t = p.read_text()
if kind == "drop":          # delete every line containing rest
    t = "".join(l for l in t.splitlines(True) if rest not in l)
elif kind == "strip":       # remove the literal substring rest
    t = t.replace(rest, "")
elif kind == "movelast":    # move the line containing rest to end of file
    lines = t.splitlines(True)
    keep = [l for l in lines if rest not in l]
    moved = [l for l in lines if rest in l]
    t = "".join(keep) + "".join(moved)
elif kind == "dropif":      # delete the `if` block whose head contains rest
    # Whole block, not just the predicate line: deleting the head alone leaves
    # a dangling `exit 1` + `fi`, which fails for the wrong reason and would
    # let the mutant "redden" without pinning anything.
    lines = t.splitlines(True)
    head = next(i for i, l in enumerate(lines) if rest in l and l.lstrip().startswith("if "))
    indent = len(lines[head]) - len(lines[head].lstrip())
    end = next(j for j in range(head + 1, len(lines))
               if lines[j].strip() == "fi"
               and len(lines[j]) - len(lines[j].lstrip()) == indent)
    t = "".join(lines[:head] + lines[end + 1:])
else:
    raise SystemExit(f"unknown mutation kind {kind!r}")
p.write_text(t)
PY
    done
    printf '%s\n' "$m"
}

echo "== the contract, on the real workflow body =="

# A1 — the whole point. A merely-RED band must NOT fail this step, and must
#      still publish the ledger the verdict step consumes.
r=$(run_band "$BAND_SRC" 1 1)
[ "${r%%|*}" = "0" ] && ok "A1a red band (run-tests rc=1) -> band step exits 0" \
                     || bad "A1a red band failed the band step (rc=${r%%|*}) — verdict would be SKIPPED again"
[ -n "${r#*|}" ] && ok "A1b red band still publishes ledger= output" \
                 || bad "A1b ledger= output unset on a red band — verdict would run with an empty path"

# A2 — a green band is unremarkable, but must behave the same way.
r=$(run_band "$BAND_SRC" 0 1)
[ "${r%%|*}" = "0" ] && ok "A2  green band -> band step exits 0, ledger published" \
                     || bad "A2  green band failed the band step (rc=${r%%|*})"

# A3 — rc=3 is a PARTIAL ledger. Adjudicating it would read missing rows as
#      UNACCOUNTED, so it must fail here instead (this is why the fix is not
#      a blanket `|| true`).
r=$(run_band "$BAND_SRC" 3 1)
[ "${r%%|*}" != "0" ] && ok "A3  rc=3 (partial ledger) -> band step FAILS" \
                      || bad "A3  rc=3 was swallowed — a truncated ledger would reach the tolerance diff"

# A4 — rc=2 is a harness refusal, not a test result.
r=$(run_band "$BAND_SRC" 2 1)
[ "${r%%|*}" != "0" ] && ok "A4  rc=2 (harness refusal) -> band step FAILS" \
                      || bad "A4  rc=2 was swallowed"

# A5 — an empty ledger cannot be adjudicated green.
r=$(run_band "$BAND_SRC" 0 0)
[ "${r%%|*}" != "0" ] && ok "A5  empty ledger -> band step FAILS" \
                      || bad "A5  empty ledger accepted — a vacuous green"

# A6 — the verdict step must be structurally unskippable, and must sit after
#      the step whose output it reads.
vif=$(cat "$TMP/verdict_if.txt")
case "$vif" in
    *cancelled*|*always*) ok "A6a verdict step carries a failure-surviving if: ($vif)" ;;
    "")                   bad "A6a verdict step has NO if: — a failing predecessor skips it (this is the #739 defect)" ;;
    *)                    bad "A6a verdict step if: does not survive a failure: $vif" ;;
esac
[ "$(cat "$TMP/order.txt")" = "ok" ] && ok "A6b verdict step is ordered after the band step" \
                                     || bad "A6b verdict step precedes the band step it consumes"

# ---------------------------------------------------------------------------
# A7 — THE VERDICT STEP'S EXIT-CODE HANDLING IS REACHABLE, NOT MERELY PRESENT
# (your-org/nexus-code#1283).
#
# WHY THIS EXISTS. Until now this suite extracted the verdict step's `if:` and
# never its `run:`, so the body was PRESENT IN THE WORKFLOW AND EXECUTED BY
# NOTHING. `#1283` added an exit-code `case` to that body — rc 4 (ENV-UNPROVEN)
# must NOT hard-fail the band, or the whole fix is inert and an honest
# environment decline still reds the blocking band. A `case` arm that is merely
# present is indistinguishable from one that is unreachable, and both read
# identically in a diff. So the arms are DRIVEN, against REAL ledgers, through
# the REAL extracted body.
#
# The four drift verdicts, and what the step must do with each:
#   rc 0  clean            -> step SUCCEEDS, no warning
#   rc 4  ENV-UNPROVEN     -> step SUCCEEDS **and says so**: not a clearance
#   rc 1  NEW-RED          -> step FAILS. The fix must not have widened the gate.
#   rc 2  REFUSED          -> step FAILS. An unreadable/empty ledger is not a pass.
echo "=== A7: the verdict step's exit-code arms, EXECUTED ==="
VTMP=$(mktemp -d -t slow-band-vfx-XXXXXX)
printf '# empty tolerated set, as shipped\n' > "$VTMP/known.tsv"

# Positive control FIRST: the executor can produce a PASS at all. Without this,
# every "step failed" assertion below could be an artefact of a broken harness.
printf 'a.sh\tPASS\t1\t0\t2\n' > "$VTMP/clean.tsv"
v=$(run_verdict "$VTMP/clean.tsv"); rc="${v%%|*}"
[ "$rc" = "0" ] && ok "A7a CONTROL: a clean ledger -> the step SUCCEEDS (harness works)" \
                || bad "A7a CONTROL FAILED: a clean ledger did not succeed (rc=$rc) — every assertion below is uninterpretable"

# rc 4 — the arm the whole #1283 fix depends on.
printf 'a.sh\tENVSKIP\t1\t0\t?\n' > "$VTMP/env.tsv"
v=$(run_verdict "$VTMP/env.tsv"); rc="${v%%|*}"; out="${v#*|}"
[ "$rc" = "0" ] && ok "A7b rc4 ENV-UNPROVEN does NOT fail the step (the fix is not inert)" \
                || bad "A7b rc4 FAILED the step (rc=$rc) — an honest ENV decline still reds the blocking band; #1283 is inert"
case "$out" in
    *"::warning::"*) ok "A7c …and it is NOT laundered into a silent pass: a ::warning:: is emitted" ;;
    *)               bad "A7c rc4 passed SILENTLY — a caveat nobody is told is not a caveat" ;;
esac

# rc 1 — the gate must not have been widened.
printf 'a.sh\tFAIL\t1\t0\t2\n' > "$VTMP/red.tsv"
v=$(run_verdict "$VTMP/red.tsv"); rc="${v%%|*}"
[ "$rc" != "0" ] && ok "A7d a NEW-RED still FAILS the step (rc=$rc) — the gate was not widened" \
                 || bad "A7d a NEW-RED PASSED — the rc-4 arm swallowed a real regression"

# rc 1 again, but MIXED: the case that matters most. An ENVSKIP sharing a
# ledger with a real red must not launder it.
printf 'a.sh\tFAIL\t1\t0\t2\nb.sh\tENVSKIP\t1\t0\t?\n' > "$VTMP/mixed.tsv"
v=$(run_verdict "$VTMP/mixed.tsv"); rc="${v%%|*}"
[ "$rc" != "0" ] && ok "A7e FAIL + ENVSKIP still FAILS (rc=$rc) — an ENVSKIP cannot launder a red" \
                 || bad "A7e FAIL + ENVSKIP PASSED — a regression laundered by an environment decline"

# rc 2 — REFUSED. An unreadable/empty ledger is not a clearance.
: > "$VTMP/empty.tsv"
v=$(run_verdict "$VTMP/empty.tsv"); rc="${v%%|*}"
[ "$rc" != "0" ] && ok "A7f an EMPTY ledger still REFUSES and fails the step (rc=$rc)" \
                 || bad "A7f an empty ledger PASSED — a vacuous green"
rm -rf "$VTMP"

echo "== mutants: each must redden a NAMED assertion above =="

# M1 — the ORIGINAL shape: unguarded invocation + ledger= published last.
#      Must break A1a AND A1b, i.e. reproduce the #739 defect exactly.
m=$(mutate orig "strip: || rc=\$?" "movelast:ledger=\$LEDGER")
r=$(run_band "$m" 1 1)
[ "${r%%|*}" != "0" ] && ok "M1a pre-fix shape: red band aborts the step (A1a would redden)" \
                      || bad "M1a pre-fix shape did NOT abort — A1a is not pinning anything"
[ -z "${r#*|}" ] && ok "M1b pre-fix shape: ledger= never published (A1b would redden)" \
                 || bad "M1b pre-fix shape still published ledger= — A1b is not pinning anything"

# M2 — the blanket-swallow remedy (#730's weaker-remedy mistake): every rc
#      accepted. Must break A3 and A4.
m=$(mutate swallow "drop:exit 1 ;;" "drop:::error::run-tests.sh")
r=$(run_band "$m" 3 1)
[ "${r%%|*}" = "0" ] && ok "M2  blanket swallow: rc=3 passes (A3 would redden)" \
                     || bad "M2  blanket-swallow mutant still failed on rc=3 — A3 is not pinning anything"

# M3 — drop the empty-ledger check. Must break A5.
m=$(mutate emptyok "dropif:! -s \"\$LEDGER\"")
r=$(run_band "$m" 0 0)
[ "${r%%|*}" = "0" ] && ok "M3  no empty-ledger check: empty ledger passes (A5 would redden)" \
                     || bad "M3  empty-ledger mutant still failed — A5 is not pinning anything"

echo
# Canonical accounting footer — the shape run-tests.sh's _rt_declared_assertions
# reads. Without one this suite's ledger row is `assertions: ?`, and a count
# that cannot be read cannot be watched for a fall.
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] && exit 0
exit 1
