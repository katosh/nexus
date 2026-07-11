#!/usr/bin/env bash
# Tests for monitor/worker-health.sh — the worker-side helper that
# answers a watcher clarification about a live background child by writing
# $STATE_DIR/worker-health/<window>.json (your-org/nexus-code#455 refine).
#
# Run: bash monitor/watcher/test-worker-health.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
WH="$_repo_root/monitor/worker-health.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

[[ -x "$WH" ]] || { echo "missing: $WH" >&2; exit 1; }

hf="$WORK/.state/worker-health/testw.json"
run() {
    NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
        bash "$WH" "$@"
}
reset() { rm -rf "$WORK/.state/worker-health"; }

echo "=== worker-health.sh basics ==="

# (1) --health running with runtime → well-formed file.
reset
if run --health running --kind slurm --job-id 52527284 --runtime 7200 \
       --note "DE sweep" >/dev/null 2>&1; then
    ok "running write exits 0"
else
    bad "running write" "nonzero exit"
fi
if [[ -f "$hf" ]] && jq empty "$hf" >/dev/null 2>&1; then
    ok "file is valid JSON"
else
    bad "file JSON" "missing or unparseable"
fi
h=$(jq -r '.health' "$hf" 2>/dev/null)
[[ "$h" == "running" ]] && ok "health=running recorded" || bad "health field" "got '$h'"
r=$(jq -r '.expected_runtime_s' "$hf" 2>/dev/null)
[[ "$r" == "7200" ]] && ok "expected_runtime_s recorded" || bad "runtime field" "got '$r'"
k=$(jq -r '.job_kind' "$hf" 2>/dev/null)
[[ "$k" == "slurm" ]] && ok "job_kind recorded" || bad "job_kind" "got '$k'"
w=$(jq -r '.written_at' "$hf" 2>/dev/null)
[[ "$w" =~ ^[0-9]+$ ]] && (( w > 0 )) && ok "written_at is an epoch" || bad "written_at" "got '$w'"

# (2) --health done / stuck.
reset
run --health done >/dev/null 2>&1
[[ "$(jq -r '.health' "$hf" 2>/dev/null)" == "done" ]] && ok "health=done" || bad "done" "not recorded"
reset
run --health stuck --note "sbatch --wait wedged" >/dev/null 2>&1
[[ "$(jq -r '.health' "$hf" 2>/dev/null)" == "stuck" ]] && ok "health=stuck" || bad "stuck" "not recorded"

# (3) Invalid --health → usage error, exit 2, no file written.
reset
if run --health bogus >/dev/null 2>&1; then
    bad "invalid health" "should have failed"
else
    rc=$?
    (( rc == 2 )) && ok "invalid health exits 2" || bad "invalid health rc" "got $rc"
    [[ ! -f "$hf" ]] && ok "invalid health writes no file" || bad "invalid health" "wrote a file"
fi

# (4) Missing --health (and not --show/--clear) → usage error.
reset
if run --kind slurm >/dev/null 2>&1; then
    bad "missing health" "should have failed"
else
    ok "missing --health fails"
fi

# (5) --show prints the current file; --clear removes it.
reset
run --health running --runtime 100 >/dev/null 2>&1
shown=$(run --show 2>/dev/null)
grep -qF '"health"' <<<"$shown" && ok "--show prints the file" || bad "--show" "no JSON: $shown"
run --clear >/dev/null 2>&1
[[ ! -f "$hf" ]] && ok "--clear removes the file" || bad "--clear" "file remains"

# (6) Missing NEXUS_WORKER_WINDOW → exit 2. (env -u so a worker-context
#     NEXUS_WORKER_WINDOW inherited from the test runner doesn't leak in.)
if env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" bash "$WH" --health running >/dev/null 2>&1; then
    bad "no window env" "should have failed"
else
    rc=$?
    (( rc == 2 )) && ok "missing NEXUS_WORKER_WINDOW exits 2" || bad "no window rc" "got $rc"
fi

# (7) The file round-trips through the probe's _worker_health_read helper.
reset
run --health running --kind slurm --job-id 999 --runtime 3600 >/dev/null 2>&1
readout=$(STATE_DIR="$WORK/.state" bash -c "
    source '$_repo_root/monitor/watcher/_idle_probe.sh'
    _worker_health_read testw
" 2>/dev/null)
# Fields: health<TAB>expected<TAB>written<TAB>kind<TAB>id
IFS=$'\t' read -r rh re rw rk ri <<<"$readout"
[[ "$rh" == "running" ]] && ok "probe reads health" || bad "probe health" "got '$rh'"
[[ "$re" == "3600" ]]    && ok "probe reads runtime" || bad "probe runtime" "got '$re'"
[[ "$rk" == "slurm" ]]   && ok "probe reads kind"    || bad "probe kind" "got '$rk'"
[[ "$ri" == "999" ]]     && ok "probe reads job_id"  || bad "probe id" "got '$ri'"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
