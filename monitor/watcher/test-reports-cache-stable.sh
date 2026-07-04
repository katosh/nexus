#!/usr/bin/env bash
# Hermetic unit tests for the reports-section last-known-good cache
# (nexus-code reportscan follow-up).
#
# The bounded count+recent-N reports block still runs an NFS `find` over the
# reports dir, which intermittently exceeds the short scan budget. Without a
# cache the section flapped ~24 lines/poll between the live block and a bail
# sentinel. The fix: on a budget-bail, re-emit the LAST SUCCESSFUL block
# verbatim from a STATE_DIR cache, so the section is byte-stable across a
# transient slow stat; a cold-start bail (no warm cache) still degrades to
# the bounded sentinel.
#
# Covers:
#   1. Success populates the cache and emits the live count+recent-N block.
#   2. A budget-bail WITH a warm cache re-emits the cached block verbatim —
#      byte-identical to the prior success, NOT the sentinel.
#   3. success → bail → success leaves the reports section byte-stable across
#      all three (the actual no-flap guarantee).
#   4. Cold-start bail (no cache) degrades LOUD to the bounded sentinel.
#
# Bail is forced deterministically by shadowing `find` with a sleep stub and
# setting a 1s budget (timeout -> rc 124), with no reliance on real NFS
# latency.
#
# Run: bash monitor/watcher/test-reports-cache-stable.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAIN_SH="$_test_dir/main.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq()           { [[ "$2" == "$3" ]] && pass "$1" || fail "$1: got '${2:0:200}' want '${3:0:200}'"; }
assert_contains()     { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1: missing '$3'"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && pass "$1" || fail "$1: should NOT contain '$3'"; }

_extract_fn() { sed -n "/^$2() {/,/^}/p" "$1"; }

# Extract the reports section (between `--- reports ---` and the next marker
# or EOF) from a full snapshot_local emission.
reports_section() { printf '%s\n' "$1" | awk '/^--- reports ---$/{f=1;next} /^--- /{if(f)exit} f'; }

# ---- fixture -------------------------------------------------------------
ROOT=$(mktemp -d)
mkdir -p "$ROOT/reports" "$ROOT/monitor/.state"
for i in 01 02 03 04 05; do : > "$ROOT/reports/proj_2026-01-01_00-00-${i}_final.md"; done

export NEXUS_ROOT="$ROOT"
export STATE_DIR="$ROOT/monitor/.state"
unset MONITOR_SNAPSHOT_GIT_ENABLED

# Mock tmux: a fixed window list (so the rest of snapshot_local is stable).
tmux() {
    case "$1 $2" in
        "list-windows -F") printf 'orchestrator bell=0\n' ;;
        *) return 0 ;;
    esac
}
export -f tmux 2>/dev/null || true

eval "$(_extract_fn "$MAIN_SH" snapshot_local)"
SNAPSHOT_LOCAL_FORMAT_TAG='# snapshot-format=v2 test'

# A `find` stub that sleeps past any sane budget -> forces a timeout bail.
STUB=$(mktemp -d)
cat > "$STUB/find" <<'EOF'
#!/usr/bin/env bash
sleep 3
EOF
chmod +x "$STUB/find"
_real_path="$PATH"

echo '=== reports-section last-known-good cache ==='

# 1. Success: live block emitted + cache populated.
snap_ok=$(snapshot_local)
rs_ok=$(reports_section "$snap_ok")
assert_contains "success: total count emitted"     "$rs_ok" "reports-total: 5"
assert_contains "success: a recent basename listed" "$rs_ok" "proj_2026-01-01_00-00-05_final.md"
assert_not_contains "success: no bail sentinel"     "$rs_ok" "scan exceeded budget"
[[ -s "$STATE_DIR/snapshot-reports.cache" ]] && pass "success: cache file populated" \
    || fail "success: cache file NOT populated"

# 2. Budget-bail WITH a warm cache: re-emit cached block, byte-identical.
# Bump the reports-dir mtime so the dir-mtime fast path (below) MISSES and
# the scan — and thus the forced timeout bail — actually runs. Without this
# the fast path would re-emit the cache before ever calling the find stub
# (still byte-stable, but not the code path this case means to exercise).
touch "$ROOT/reports"
snap_bail=$(PATH="$STUB:$_real_path" MONITOR_SNAPSHOT_REPORTS_TIMEOUT_SECONDS=1 snapshot_local 2>/dev/null)
rs_bail=$(reports_section "$snap_bail")
assert_not_contains "bail+cache: NO sentinel"          "$rs_bail" "scan exceeded budget"
assert_contains     "bail+cache: count preserved"      "$rs_bail" "reports-total: 5"
assert_eq "bail+cache: reports section byte-identical to last success" "$rs_bail" "$rs_ok"

# 3. success -> bail -> success: byte-stable across all three (no flap).
snap_ok2=$(snapshot_local)
rs_ok2=$(reports_section "$snap_ok2")
assert_eq "no-flap: success#2 == success#1" "$rs_ok2" "$rs_ok"
assert_eq "no-flap: bail == success (all three identical)" "$rs_bail" "$rs_ok2"

# 4. Cold start: no warm cache + bail -> bounded sentinel (degrade loud).
rm -f "$STATE_DIR/snapshot-reports.cache"
snap_cold=$(PATH="$STUB:$_real_path" MONITOR_SNAPSHOT_REPORTS_TIMEOUT_SECONDS=1 snapshot_local 2>/dev/null)
rs_cold=$(reports_section "$snap_cold")
assert_contains "cold-start bail: bounded sentinel emitted" "$rs_cold" "reports-total: (scan exceeded budget)"
# Bounded: the cold sentinel is a single content line, never a dump.
ncold=$(printf '%s\n' "$rs_cold" | grep -c .)
[[ "$ncold" -le 2 ]] && pass "cold-start sentinel bounded (${ncold} lines)" \
    || fail "cold-start sentinel NOT bounded: ${ncold} lines"

echo '=== reports-section dir-mtime fast path (budget-blowout fix) ==='
# The every-cycle O(N) NFS scan was the budget blowout. The fix: when the
# reports DIR mtime is unchanged since the last successful scan AND the cache
# is warm, re-emit the cache WITHOUT re-enumerating — the common no-new-report
# case becomes a single stat + cat. Prove it by putting a would-bail find stub
# on PATH while the dir is UNCHANGED: the section must still be the good block
# (NOT the sentinel), because find is never called.
# Warm the cache + dir-mtime stamp with a clean success first.
snap_seed=$(snapshot_local)
[[ -s "$STATE_DIR/snapshot-reports.cache" && -s "$STATE_DIR/snapshot-reports.dirmtime" ]] \
    && pass "fast-path: cache + dirmtime stamp written on success" \
    || fail "fast-path: cache/dirmtime stamp NOT written"
# Dir unchanged → even a find that WOULD blow the budget is never invoked.
snap_fast=$(PATH="$STUB:$_real_path" MONITOR_SNAPSHOT_REPORTS_TIMEOUT_SECONDS=1 snapshot_local 2>/dev/null)
rs_fast=$(reports_section "$snap_fast")
assert_not_contains "fast-path: no sentinel (find never called)" "$rs_fast" "scan exceeded budget"
assert_contains     "fast-path: count served from cache"         "$rs_fast" "reports-total: 5"
assert_eq "fast-path: section byte-identical to seed"            "$rs_fast" "$(reports_section "$snap_seed")"
# A new report bumps the dir mtime → fast path MISSES → a real scan reflects
# the add on the next cycle.
: > "$ROOT/reports/proj_2026-01-01_00-00-06_final.md"
snap_after=$(snapshot_local)
rs_after=$(reports_section "$snap_after")
assert_contains "fast-path: dir change forces rescan (count updates)" "$rs_after" "reports-total: 6"

# ---- cleanup + summary ---------------------------------------------------
rm -rf "$ROOT" "$STUB"
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
