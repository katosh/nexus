#!/usr/bin/env bash
# Tests for monitor/declare-wait.sh and monitor/declare-no-wait.sh —
# the worker-side helpers that manipulate `external_waits` and
# `dismissed_waits` in the per-window heartbeat. Together they
# implement the worker side of the async-signal contract surface
# from issue #183.
#
# Run: bash monitor/watcher/test-declare-wait.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
DECLARE_WAIT="$_repo_root/monitor/declare-wait.sh"
DECLARE_NO_WAIT="$_repo_root/monitor/declare-no-wait.sh"

PASS=0
FAIL=0

ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

[[ -x "$DECLARE_WAIT"    ]] || { echo "missing: $DECLARE_WAIT"    >&2; exit 1; }
[[ -x "$DECLARE_NO_WAIT" ]] || { echo "missing: $DECLARE_NO_WAIT" >&2; exit 1; }

# Helper to run declare-wait or declare-no-wait in a hermetic env.
run() {
    local helper="$1"; shift
    NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
        bash "$helper" "$@"
}

hb_file="$WORK/.state/heartbeat/testw.json"

# Reset the heartbeat between tests so each assertion is isolated.
reset_hb() {
    rm -f "$hb_file"
    rm -rf "$WORK/.state/heartbeat"
}

read_waits() {
    jq -c '.external_waits // []' "$hb_file" 2>/dev/null
}
read_dismissed() {
    jq -c '.dismissed_waits // []' "$hb_file" 2>/dev/null
}

echo "=== declare-wait.sh basics ==="

# (1) Basic add.
reset_hb
run "$DECLARE_WAIT" slurm 42 "first job"
got=$(read_waits)
if [[ "$got" == '[{"kind":"slurm","id":"42","desc":"first job"}]' ]]; then
    ok "add slurm 42 → single entry"
else
    bad "add slurm 42" "got=$got"
fi

# (2) Second add appends.
run "$DECLARE_WAIT" ci abc/runs/1 "ci run"
got=$(read_waits)
if [[ "$got" == '[{"kind":"slurm","id":"42","desc":"first job"},{"kind":"ci","id":"abc/runs/1","desc":"ci run"}]' ]]; then
    ok "second add → two entries"
else
    bad "second add" "got=$got"
fi

# (3) Re-add same (kind, id) updates desc rather than dup.
run "$DECLARE_WAIT" slurm 42 "updated desc"
got=$(read_waits)
expected_count=$(jq 'length' <<<"$got")
if [[ "$expected_count" == "2" ]]; then
    desc=$(jq -r '.[] | select(.kind=="slurm" and .id=="42") | .desc' <<<"$got")
    if [[ "$desc" == "updated desc" ]]; then
        ok "re-add same (kind,id) → updates desc, no dup"
    else
        bad "re-add desc" "got desc=$desc"
    fi
else
    bad "re-add count" "got count=$expected_count"
fi

# (4) --remove drops by (kind, id).
run "$DECLARE_WAIT" --remove slurm 42
got=$(read_waits)
if [[ "$got" == '[{"kind":"ci","id":"abc/runs/1","desc":"ci run"}]' ]]; then
    ok "--remove slurm 42 → drops only that entry"
else
    bad "--remove" "got=$got"
fi

# (5) --remove of non-existent entry is silent no-op.
run "$DECLARE_WAIT" --remove slurm 999
got=$(read_waits)
if [[ "$got" == '[{"kind":"ci","id":"abc/runs/1","desc":"ci run"}]' ]]; then
    ok "--remove non-existent → silent no-op"
else
    bad "--remove non-existent" "got=$got"
fi

# (6) --clear empties the array.
run "$DECLARE_WAIT" --clear
got=$(read_waits)
if [[ "$got" == "[]" ]]; then
    ok "--clear → empty array"
else
    bad "--clear" "got=$got"
fi

# (7) --list reads from disk.
reset_hb
run "$DECLARE_WAIT" slurm 5 "x"
run "$DECLARE_WAIT" http "https://api/y" "y"
listed=$(run "$DECLARE_WAIT" --list)
listed_count=$(jq 'length' <<<"$listed")
if [[ "$listed_count" == "2" ]]; then
    ok "--list returns current entries"
else
    bad "--list count" "got=$listed_count"
fi

echo
echo "=== declare-wait.sh error handling ==="

# (8) Missing NEXUS_WORKER_WINDOW fails loud (exit 2). `env -u`
# explicitly unsets the inherited var; tests that share a shell
# with the smoke-test scaffolding might otherwise carry it
# through.
out_err=$(env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" \
    bash "$DECLARE_WAIT" slurm 1 "x" 2>&1)
rc=$?
if (( rc == 2 )) && grep -qF "NEXUS_WORKER_WINDOW unset" <<<"$out_err"; then
    ok "missing NEXUS_WORKER_WINDOW → exit 2 with stderr message"
else
    bad "missing window guard" "rc=$rc out=$out_err"
fi

# (9) Bad usage exits 2.
out_err=$(NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
            bash "$DECLARE_WAIT" 2>&1)
rc=$?
if (( rc == 2 )); then
    ok "no-args → exit 2"
else
    bad "no-args usage" "rc=$rc"
fi

echo
echo "=== declare-no-wait.sh basics ==="

reset_hb
run "$DECLARE_WAIT"    slurm 100 "to-dismiss"
run "$DECLARE_WAIT"    slurm 200 "keep"

# (10) Dismiss moves entry from external_waits to dismissed_waits.
run "$DECLARE_NO_WAIT" slurm 100
waits=$(read_waits)
dismissed=$(read_dismissed)
if [[ "$waits" == '[{"kind":"slurm","id":"200","desc":"keep"}]' ]] \
   && [[ "$dismissed" == '[{"kind":"slurm","id":"100"}]' ]]; then
    ok "dismiss → moves from external_waits to dismissed_waits"
else
    bad "dismiss move" "waits=$waits dismissed=$dismissed"
fi

# (11) Dismiss without prior external_waits row still records.
reset_hb
run "$DECLARE_NO_WAIT" slurm 555
dismissed=$(read_dismissed)
if [[ "$dismissed" == '[{"kind":"slurm","id":"555"}]' ]]; then
    ok "dismiss before declare → record in dismissed_waits"
else
    bad "dismiss-before-declare" "got=$dismissed"
fi

# (12) Dismiss is idempotent (no dup entries).
run "$DECLARE_NO_WAIT" slurm 555
dismissed=$(read_dismissed)
count=$(jq 'length' <<<"$dismissed")
if [[ "$count" == "1" ]]; then
    ok "dismiss twice → single entry (idempotent)"
else
    bad "dismiss idempotent" "count=$count"
fi

# (13) --un-dismiss removes from dismissed_waits.
run "$DECLARE_NO_WAIT" --un-dismiss slurm 555
dismissed=$(read_dismissed)
if [[ "$dismissed" == "[]" ]]; then
    ok "--un-dismiss → dismissed_waits empty"
else
    bad "--un-dismiss" "got=$dismissed"
fi

# (14) --list shows dismissed_waits only (not external_waits).
reset_hb
run "$DECLARE_WAIT"    slurm 1 "x"
run "$DECLARE_NO_WAIT" slurm 2
listed=$(run "$DECLARE_NO_WAIT" --list)
if [[ "$listed" == '[{"kind":"slurm","id":"2"}]' ]]; then
    ok "--list dismissed only"
else
    bad "--list dismissed" "got=$listed"
fi

echo
echo "=== cross-helper preservation ==="

# (15) declare-wait preserves dismissed_waits.
reset_hb
run "$DECLARE_NO_WAIT" slurm 10
run "$DECLARE_WAIT"    slurm 20 "new"
dismissed=$(read_dismissed)
if [[ "$dismissed" == '[{"kind":"slurm","id":"10"}]' ]]; then
    ok "declare-wait preserves prior dismissed_waits"
else
    bad "declare-wait preserve" "got=$dismissed"
fi

# (16) declare-no-wait preserves other external_waits.
reset_hb
run "$DECLARE_WAIT"    slurm 1 "keep"
run "$DECLARE_WAIT"    ci 9 "keep ci"
run "$DECLARE_NO_WAIT" slurm 1
waits=$(read_waits)
if [[ "$waits" == '[{"kind":"ci","id":"9","desc":"keep ci"}]' ]]; then
    ok "declare-no-wait preserves other external_waits"
else
    bad "declare-no-wait preserve" "got=$waits"
fi

echo
echo "=== summary ==="
printf '  %d pass / %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    echo "FAIL"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
