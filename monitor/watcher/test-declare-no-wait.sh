#!/usr/bin/env bash
# Tests for monitor/declare-no-wait.sh — the LIFT-a-hold verb — on the one
# axis where it must differ from its companion `declare-wait.sh`: what it does
# when the heartbeat EXISTS but cannot be read (your-org/nexus-code#1390).
#
# `declare-wait.sh` (ADDS a wait) falls back to a fresh object over a corrupt
# heartbeat, deliberately: a worker unable to declare a wait is the worse
# outcome. `declare-no-wait.sh` inherited that fallback without the reasoning,
# and for a verb that LIFTS a hold it is the manufactured-success direction:
# three real waits + a truncated heartbeat + one well-formed dismissal -> the
# skeleton is seeded, the rename lands it, `external_waits = []`, and the
# rc-4 text says "no outstanding wait was lifted". The fix is to REFUSE (rc
# 5) and name the file. This suite pins both halves of the asymmetry — the
# refusal here AND the intact fallback in declare-wait.sh — because "fix both
# verbs the same way" is the natural wrong move.
#
# Run: bash monitor/watcher/test-declare-no-wait.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
DECLARE_WAIT="$_repo_root/monitor/declare-wait.sh"
DECLARE_NO_WAIT="$_repo_root/monitor/declare-no-wait.sh"

. "$_test_dir/_test_helpers.sh"

[[ -x "$DECLARE_WAIT"    ]] || th_abort "missing: $DECLARE_WAIT"
[[ -x "$DECLARE_NO_WAIT" ]] || th_abort "missing: $DECLARE_NO_WAIT"
command -v jq >/dev/null 2>&1 || th_abort "jq required"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dnw-XXXXXX") || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/.state"
HB="$STATE/heartbeat/w1390.json"

run_no_wait() { NEXUS_STATE_DIR="$STATE" NEXUS_WORKER_WINDOW=w1390 bash "$DECLARE_NO_WAIT" "$@"; }
run_wait()    { NEXUS_STATE_DIR="$STATE" NEXUS_WORKER_WINDOW=w1390 bash "$DECLARE_WAIT"    "$@"; }

# Three REAL waits, one of each kind the watcher resolves — the population
# a wipe would destroy.
plant_good() {
    rm -rf "$STATE"; mkdir -p "$STATE/heartbeat"
    jq -nc '{window:"w1390", last_activity:1,
             external_waits:[{kind:"slurm",id:"2219913"},
                             {kind:"nohup",id:"syn-3b2c13e3930e"},
                             {kind:"asyncrun",id:"ar-cc40075aa77b"}],
             dismissed_waits:[]}' > "$HB"
}
plant_truncated() { plant_good; head -c 60 "$HB" > "$HB.t" && mv "$HB.t" "$HB"; }
plant_empty()     { plant_good; : > "$HB"; }
sha() { sha256sum < "$HB" | cut -d' ' -f1; }
waits() { jq -c '.external_waits // []' "$HB" 2>/dev/null || printf '(unparseable)'; }

# ---------------------------------------------------------------------------
echo "=== POSITIVE CONTROL: a well-formed heartbeat still has ONE wait lifted, the rest kept ==="
# Establishes the refusal below is not over-refusing: the same command on the
# same waits, the only variable being whether the file parses.
plant_good
run_no_wait nohup syn-3b2c13e3930e >/dev/null 2>&1; rc=$?
assert_rc "well-formed heartbeat: dismiss is rc 0 (a real wait WAS lifted)" "$rc" "0"
assert_eq "…exactly the named wait is gone, the other two remain" \
    "$(waits)" '[{"kind":"slurm","id":"2219913"},{"kind":"asyncrun","id":"ar-cc40075aa77b"}]'

# ---------------------------------------------------------------------------
echo "=== a TRUNCATED heartbeat is REFUSED (rc 5), named, and left byte-identical ==="
plant_truncated
jq empty "$HB" >/dev/null 2>&1 && th_abort "fixture error: the truncated heartbeat still parses"
h0=$(sha)
err=$(run_no_wait nohup syn-3b2c13e3930e 2>&1 >/dev/null); rc=$?
assert_rc "truncated heartbeat + well-formed id: REFUSED at rc 5 (your-org/nexus-code#1390)" "$rc" "5"
assert_eq "…and the file is byte-identical afterwards (nothing was seeded over it)" "$(sha)" "$h0"
assert_contains "…the diagnostic NAMES the file" "$err" "$HB"
assert_contains "…and says the file does not parse" "$err" "does not parse"
assert_contains "…and says nothing was written" "$err" "Nothing was written"
assert_not_contains "…and does NOT tell the rc-4 story (no wait was lifted / pre-arm)" "$err" "RECORDED (pre-arm)"

# ---------------------------------------------------------------------------
echo "=== an EMPTY (0-byte) heartbeat is REFUSED the same way ==="
# The pre-fix measurement on #1390 at e87bb39b: 2 real waits, a 0-byte
# heartbeat, one dismissal -> rc 0 and `[]`. Empty is not "no heartbeat".
plant_empty
err=$(run_no_wait nohup syn-3b2c13e3930e 2>&1 >/dev/null); rc=$?
assert_rc "0-byte heartbeat: REFUSED at rc 5" "$rc" "5"
assert_eq "…and it is still 0 bytes" "$(stat -c %s "$HB")" "0"
assert_contains "…the diagnostic says EMPTY" "$err" "EMPTY"

# ---------------------------------------------------------------------------
echo "=== the refusal covers EVERY write path of this verb, and the read path does not lie ==="
plant_truncated; h0=$(sha)
run_no_wait --un-dismiss nohup syn-3b2c13e3930e >/dev/null 2>&1; rc=$?
assert_rc "--un-dismiss over a truncated heartbeat: REFUSED at rc 5" "$rc" "5"
assert_eq "…file untouched" "$(sha)" "$h0"
out=$(run_no_wait --list 2>/dev/null); rc=$?
assert_rc "--list over a truncated heartbeat: rc 5, not a confident \`[]\`" "$rc" "5"
assert_eq "…and prints no ledger it cannot vouch for" "$out" ""

# ---------------------------------------------------------------------------
echo "=== an ABSENT heartbeat is still seeded — the pre-arm path is legitimate ==="
# The refusal must key on "exists and unreadable", never on "absent": a
# worker may dismiss BEFORE any hook has written a heartbeat (rc 4, sticky).
rm -rf "$STATE"
run_no_wait nohup syn-3b2c13e3930e >/dev/null 2>&1; rc=$?
assert_rc "absent heartbeat: pre-arm dismissal is recorded at rc 4 (unchanged behaviour)" "$rc" "4"
assert_eq "…and the seeded file carries the dismissal" \
    "$(jq -c '.dismissed_waits' "$HB")" '[{"kind":"nohup","id":"syn-3b2c13e3930e"}]'

# ---------------------------------------------------------------------------
echo "=== NEGATIVE CONTROL: declare-wait.sh (ADDS) keeps its reseed fallback ==="
# The verb asymmetry IS the design (#1390): do not fix both the same way. If
# this goes red, someone hardened the ADD verb too and stranded workers who
# need to declare a wait over a damaged heartbeat.
plant_truncated
run_wait slurm 777 "control wait" >/dev/null 2>&1; rc=$?
assert_rc "declare-wait.sh over the same truncated heartbeat: rc 0 (fallback intact)" "$rc" "0"
assert_eq "…and the reseeded file now parses and holds the new wait" \
    "$(waits)" '[{"kind":"slurm","id":"777","desc":"control wait"}]'

# ---- assertion-count guard ------------------------------------------------
EXPECTED_ASSERTIONS=19
_ran=$(( ${PASS:-0} + ${FAIL:-0} ))
if (( _ran == EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
