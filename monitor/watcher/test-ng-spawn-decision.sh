#!/usr/bin/env bash
# Unit tests for `ng spawn-decision` and `ng wrap-up-check`.
#
# Run: bash monitor/watcher/test-ng-spawn-decision.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: shadow `tmux` and `pane-state.sh` on PATH so the decision
# helper sees scripted windows and pane states. Seed a synthetic
# action-log.jsonl under a per-test STATE_DIR. Invoke `ng` against
# that state dir.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG="$_test_dir/../ng"

PASS=0
FAIL=0
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n         expected: %s\n         in: %s\n' \
            "$label" "$needle" "$hay" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Build a fake nexus root so config/load.sh and pane-state.sh resolve.
# COPY (not symlink) ng into the fake root. ng resolves its own dir with
# `readlink -f "${BASH_SOURCE[0]}"` (your-org/nexus-code#522) — a symlink
# here would be dereferenced back to the REAL repo, so `_script_dir` would
# land on the real monitor/ and ng would use the real pane-state.sh instead
# of the fake stub dropped below, defeating the whole harness. A regular-file
# copy makes `_script_dir` == FAKE_ROOT/monitor, so the stub is picked up.
FAKE_ROOT="$WORK/nexus"
mkdir -p "$FAKE_ROOT/monitor/.state" "$FAKE_ROOT/config" "$FAKE_ROOT/reports"
cp "$_test_dir/../ng" "$FAKE_ROOT/monitor/ng"
chmod +x "$FAKE_ROOT/monitor/ng"
# Minimal config so config/load.sh returns defaults instead of dying.
cat > "$FAKE_ROOT/config/load.sh" <<'EOF'
#!/usr/bin/env bash
# Stub: always echo the supplied default for any key.
echo "${2:-}"
EOF
chmod +x "$FAKE_ROOT/config/load.sh"

STATE_DIR="$FAKE_ROOT/monitor/.state"
export STATE_DIR
NEXUS_ROOT="$FAKE_ROOT"
export NEXUS_ROOT

# Stub PATH for tmux + pane-state.sh.
STUB="$WORK/bin"
mkdir -p "$STUB"
cat > "$STUB/tmux" <<'TS'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows)
        printf '%s\n' "${MOCK_TMUX_WINDOWS:-}"
        ;;
    *) exit 0 ;;
esac
TS
chmod +x "$STUB/tmux"

# Override pane-state.sh that ng uses — when invoked with --all,
# emit one line per window from MOCK_PANES.
cat > "$STUB/pane-state.sh" <<'PS'
#!/usr/bin/env bash
# Args: --all
printf '%s\n' "${MOCK_PANES:-}"
PS
chmod +x "$STUB/pane-state.sh"

# Drop the stub pane-state.sh into FAKE_ROOT too so cmd_spawn_decision
# (which uses $_script_dir/pane-state.sh) picks it up. Write a fresh
# regular file — never `cp` over a path that might already exist as
# a symlink to the real repo's helper.
rm -f "$FAKE_ROOT/monitor/pane-state.sh"
cat > "$FAKE_ROOT/monitor/pane-state.sh" <<'PS2'
#!/usr/bin/env bash
# Args: --all
printf '%s\n' "${MOCK_PANES:-}"
PS2
chmod +x "$FAKE_ROOT/monitor/pane-state.sh"

LOG="$STATE_DIR/action-log.jsonl"
NOW=$(date +%s)

run_ng() {
    PATH="$STUB:$PATH" \
        STATE_DIR="$STATE_DIR" \
        NEXUS_ROOT="$NEXUS_ROOT" \
        REPO="your-org/test-asset-repo" \
        bash "$FAKE_ROOT/monitor/ng" "$@"
}

# --- spawn-decision tests --------------------------------------------------

echo '=== spawn-decision: window absent → spawn ==='
export MOCK_TMUX_WINDOWS=""
export MOCK_PANES=""
out=$(run_ng spawn-decision missing-window 2>&1)
assert_contains "absent window → decision=spawn" "$out" "decision=spawn"
assert_contains "absent window → reason=window-absent" "$out" "reason=window-absent"

echo '=== spawn-decision: idle retained worker → continue ==='
export MOCK_TMUX_WINDOWS="my-worker"
export MOCK_PANES="state=idle active=0 window=4 name=my-worker"
RETAIN_TS=$(date -Is -d "@$(( NOW - 300 ))")
cat > "$LOG" <<EOF
{"ts":"$RETAIN_TS","agent":"monitor","event":"window-retain","window":"my-worker","reason":"wrap-up-checkpoint"}
EOF
out=$(run_ng spawn-decision my-worker 2>&1)
assert_contains "retained idle → decision=continue" "$out" "decision=continue"
assert_contains "retained idle → reason=retained-and-idle" "$out" "reason=retained-and-idle"

echo '=== spawn-decision: pane busy → ambiguous ==='
export MOCK_PANES="state=busy active=0 window=4 name=my-worker"
out=$(run_ng spawn-decision my-worker 2>&1)
assert_contains "busy pane → ambiguous" "$out" "decision=ambiguous"
assert_contains "busy pane → reason mentions mid-flight" "$out" "pane-mid-flight"

echo '=== spawn-decision: idle but no retain → spawn ==='
export MOCK_PANES="state=idle active=0 window=4 name=my-worker"
: > "$LOG"
out=$(run_ng spawn-decision my-worker 2>&1)
assert_contains "no retain → decision=spawn" "$out" "decision=spawn"
assert_contains "no retain → reason=no-retain-on-record" "$out" "reason=no-retain-on-record"

# --- wrap-up-check tests ---------------------------------------------------

echo '=== wrap-up-check: no wrap-up event → incomplete ==='
: > "$LOG"
out=$(run_ng wrap-up-check missing-worker 2>&1)
rc=$?
assert_eq "no wrap-up → exit 1" "$rc" "1"
assert_contains "no wrap-up → wrap_up=missing" "$out" "wrap_up=missing"
assert_contains "no wrap-up → status=incomplete" "$out" "status=incomplete"

echo '=== wrap-up-check: wrap-up present, report passes report-check, rocket ok ==='
# Lay down a substantive report so report-check passes.
mkdir -p "$FAKE_ROOT/reports"
REPORT_NAME="myworker_2026-05-12_120000_test.md"
cat > "$FAKE_ROOT/reports/$REPORT_NAME" <<'EOF'
---
project: myworker
date: 2026-05-12
session-id: 11111111-1111-1111-1111-111111111111
window: myworker
trigger: 0
status: completed
---

# Test report

## Summary

A substantive summary for the test. This needs to be long enough to
pass the report_min_chars check (default 500), so this paragraph
intentionally rambles for a few sentences to clear that bar. It is
not a stub; the wrap-up-check verifier should accept it.

## What Was Done

Wrote a test report under monitor/watcher/test-ng-spawn-decision.sh
exercising the wrap-up-check verifier's happy path. The verifier
inspects the action-log for a wrap-up event matching the window
and then runs ng report-check on the cited report. We seed both
artifacts and expect status=ok with exit code 0.

## Current State

Test under construction. No other artifacts.

## What Remains

None — the test is self-contained.

## How to Resume

Re-run `bash monitor/watcher/test-ng-spawn-decision.sh`.
EOF
SPAWN_TS=$(date -Is -d "@$(( NOW - 600 ))")
WRAP_TS=$(date -Is -d "@$(( NOW - 300 ))")
cat > "$LOG" <<EOF
{"ts":"$SPAWN_TS","agent":"monitor","event":"spawn","window":"myworker","workdir":"/tmp/myworker"}
{"ts":"$WRAP_TS","agent":"monitor","event":"wrap-up","window":"myworker","report":"$REPORT_NAME","upload":"ok","comment":"ok","rocket":"ok"}
EOF
out=$(run_ng wrap-up-check myworker 2>&1)
rc=$?
assert_eq "complete → exit 0" "$rc" "0"
assert_contains "complete → status=ok" "$out" "status=ok"
assert_contains "complete → wrap_up=present" "$out" "wrap_up=present"
assert_contains "complete → report_check=ok" "$out" "report_check=ok"
assert_contains "complete → rocket=ok" "$out" "rocket=ok"

echo '=== wrap-up-check: stale (pre-spawn) wrap-up ignored ==='
# A wrap-up entry BEFORE the spawn must be ignored — that wrap-up
# belongs to a prior life of the window-name.
OLD_WRAP_TS=$(date -Is -d "@$(( NOW - 7200 ))")
SPAWN_TS=$(date -Is -d "@$(( NOW - 600 ))")
cat > "$LOG" <<EOF
{"ts":"$OLD_WRAP_TS","agent":"monitor","event":"wrap-up","window":"recycled","report":"recycled_2026-05-10_120000_old.md","upload":"ok","comment":"ok","rocket":"ok"}
{"ts":"$SPAWN_TS","agent":"monitor","event":"spawn","window":"recycled","workdir":"/tmp/recycled"}
EOF
out=$(run_ng wrap-up-check recycled 2>&1)
rc=$?
assert_eq "stale-only → exit 1" "$rc" "1"
assert_contains "stale-only → wrap_up=missing" "$out" "wrap_up=missing"

# --- summary ---------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
