#!/usr/bin/env bash
# Unit tests for monitor/boot-recover.sh — the cold-boot trigger guard.
#
# Run: bash monitor/watcher/test-boot-recover.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: stub bootstrap-recover.sh via BOOT_RECOVER_BIN. The stub
# reports health on `--dry-run` (driven by STUB_HEALTH) and records
# each REAL (non-dry) invocation by appending to STUB_COUNTER, so we
# can assert exactly when recovery fires. STATE_DIR is a per-run
# tmpdir so the debounce stamp is isolated.
#
# Tests cover:
#   - No-op when the stack is healthy (dry-run shows nothing to do):
#     recovery is NOT invoked.
#   - Recovery fires when the dry-run reports work to do.
#   - Idempotence / debounce: a second call within the window does
#     not re-fire recovery.
#   - --force bypasses the debounce.
#   - A stale stamp (older than the window) lets recovery fire again.
#   - Non-blocking: the guard returns promptly even when the real
#     recovery run is slow (it is backgrounded).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD="$_test_dir/../boot-recover.sh"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_le() {
    local label="$1" got="$2" max="$3"
    if (( got <= max )); then
        printf '  PASS: %s (%s <= %s)\n' "$label" "$got" "$max"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — %s > %s\n' "$label" "$got" "$max" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR"
STAMP="$STATE_DIR/boot-recover.stamp"
COUNTER="$WORK/invocations.txt"
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

# Test double for bootstrap-recover.sh.
cat > "$STUB_DIR/bootstrap-recover.sh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--dry-run" ]]; then
    if [[ "${STUB_HEALTH:-healthy}" == "unhealthy" ]]; then
        echo "[recover] watcher: would run /path/to/launcher.sh" >&2
        echo "[recover] service 'svc': would relaunch (cwd=/x): ./serve.sh" >&2
    elif [[ "${STUB_HEALTH:-healthy}" == "workers-only" ]]; then
        # Watcher + services healthy; only a snapshot worker is missing.
        echo "[recover] watcher: healthy" >&2
        echo "[recover] service 'svc': healthy" >&2
        echo "[recover] worker 'w-active': would resume via spawn-worker.sh --resume" >&2
    else
        echo "[recover] watcher: healthy" >&2
        echo "[recover] service 'svc': healthy" >&2
    fi
    exit 0
fi
# Real (non-dry) run: optionally slow, and record the invocation.
[[ -n "${STUB_REAL_SLEEP:-}" ]] && sleep "$STUB_REAL_SLEEP"
[[ -n "${STUB_COUNTER:-}" ]] && echo "ran" >> "$STUB_COUNTER"
exit 0
STUB
chmod +x "$STUB_DIR/bootstrap-recover.sh"

# Run the guard with the stub wired in. Extra env (STUB_HEALTH,
# STUB_REAL_SLEEP) is passed through the caller's environment.
run_guard() {
    NEXUS_STATE_DIR="$STATE_DIR" \
    BOOT_RECOVER_BIN="$STUB_DIR/bootstrap-recover.sh" \
    STUB_COUNTER="$COUNTER" \
    bash "$GUARD" "$@" >/dev/null 2>&1
}

# Count recorded real invocations. Polls briefly because the real run
# is backgrounded (nohup &) and may land a few ms after the guard
# returns.
invocation_count() {
    local want="${1:-}" iters="${2:-40}" i n   # iters*0.05s poll window
    for i in $(seq 1 "$iters"); do
        n=$( [[ -f "$COUNTER" ]] && wc -l < "$COUNTER" || echo 0 )
        n=$(( n + 0 ))
        if [[ -n "$want" ]] && (( n >= want )); then break; fi
        sleep 0.05
    done
    echo "$n"
}

reset() { rm -f "$STAMP" "$COUNTER"; }

# ---- Test 1: healthy stack → no recovery -------------------------------
echo '=== healthy stack → guard no-ops (no recovery launched) ==='
reset
STUB_HEALTH=healthy run_guard
assert_eq "exit 0 (healthy)"            "$?"                  "0"
sleep 0.2
assert_eq "no recovery invoked"         "$(invocation_count)" "0"
assert_eq "stamp written on healthy run" "$([[ -f "$STAMP" ]] && echo yes || echo no)" "yes"

# ---- Test 2: unhealthy stack → recovery fires --------------------------
echo '=== unhealthy stack → recovery launched once ==='
reset
STUB_HEALTH=unhealthy run_guard
assert_eq "exit 0 (unhealthy)"          "$?"                   "0"
assert_eq "recovery invoked once"       "$(invocation_count 1)" "1"

# ---- Test 2b: workers-only need → recovery fires ------------------------
echo '=== workers-only need (would resume marker) → recovery launched ==='
reset
STUB_HEALTH=workers-only run_guard
assert_eq "exit 0 (workers-only)"       "$?"                   "0"
assert_eq "recovery invoked on would-resume" "$(invocation_count 1)" "1"

# ---- Test 3: debounce → second call within window does not re-fire -----
echo '=== debounce: second call within window does not re-fire ==='
reset
STUB_HEALTH=unhealthy run_guard
first=$(invocation_count 1)
STUB_HEALTH=unhealthy run_guard          # stamp now fresh → should skip
sleep 0.3
assert_eq "first call fired"            "$first"               "1"
assert_eq "second call debounced"      "$(invocation_count)"  "1"

# ---- Test 4: --force bypasses the debounce -----------------------------
echo '=== --force re-fires despite a fresh stamp ==='
# Stamp is fresh from Test 3; do NOT reset it.
rm -f "$COUNTER"
STUB_HEALTH=unhealthy run_guard --force
assert_eq "forced run fired"           "$(invocation_count 1)" "1"

# ---- Test 5: stale stamp → recovery fires again ------------------------
echo '=== stale stamp (older than window) → fires again ==='
rm -f "$COUNTER"
: > "$STAMP"
touch -d '2000-01-01 00:00:00' "$STAMP" 2>/dev/null || touch -t 200001010000 "$STAMP"
STUB_HEALTH=unhealthy run_guard
assert_eq "stale stamp → fired"        "$(invocation_count 1)" "1"

# ---- Test 6: non-blocking even when recovery is slow -------------------
echo '=== guard returns promptly while recovery runs in background ==='
reset
start_ns=$(date +%s%N)
STUB_HEALTH=unhealthy STUB_REAL_SLEEP=3 run_guard
end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
# The guard must not wait on the 3s recovery; allow generous slack for
# bash startup + the synchronous dry-run probe.
assert_le "guard returned without blocking on 3s recovery" "$elapsed_ms" "2000"
# And the backgrounded recovery still completes (poll past the 3s sleep).
assert_eq "backgrounded recovery completed" "$(invocation_count 1 120)" "1"

# ---- summary -----------------------------------------------------------
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    echo "SOME TESTS FAILED" >&2
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
