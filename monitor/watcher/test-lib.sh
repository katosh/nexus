#!/usr/bin/env bash
# Mock-tmux unit tests for monitor/watcher/_lib.sh helpers that don't
# need full-loop integration. Currently covers:
#
#   - _target_window_present (window-present / absent / no-tmux)
#   - _classify_diff (git-section blanket suppression, mixed signal)
#
# Same hand-rolled harness shape as test-unstick.sh: mock tmux as a
# bash function, install a real-looking shim on PATH so `command -v
# tmux` succeeds, exercise the function, assert on its exit code.
#
# Run: bash monitor/watcher/test-lib.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s (got %q)\n' "$label" "$got"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s: got %q, want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

WINDOWS_LIST=""

# When non-zero, the mock `tmux list-windows` simulates a COMMAND
# FAILURE (no server running, or a client/server protocol-version
# mismatch): it emits the error text to stderr — which the function's
# `2>/dev/null` swallows, exactly as in production — and exits with
# this code, producing empty stdout. Reset to 0 for the normal path.
TMUX_LIST_RC=0

# Mock tmux: implements only `list-windows -F '#{window_name}'`, the
# one verb _target_window_present cares about.
tmux() {
    local sub="$1"; shift
    case "$sub" in
        list-windows)
            if (( TMUX_LIST_RC != 0 )); then
                echo 'protocol version mismatch (client 8, server 7)' >&2
                return "$TMUX_LIST_RC"
            fi
            printf '%s\n' "$WINDOWS_LIST"
            return 0
            ;;
        *) return 0 ;;
    esac
}
export -f tmux

# Real-looking tmux shim so `command -v tmux` succeeds. The bash
# function shadows the binary at call-time, but `command -v` walks
# PATH (and aliases / functions); a shim guarantees a positive answer
# regardless of the shell's view of the function table.
SHIM_DIR=$(mktemp -d)
trap 'rm -rf "$SHIM_DIR"' EXIT
install_tmux_shim() {
    cat > "$SHIM_DIR/tmux" <<'SHIM'
#!/bin/bash
exit 0
SHIM
    chmod +x "$SHIM_DIR/tmux"
    PATH="$SHIM_DIR:$PATH"
    export PATH
}
install_tmux_shim

# Source the library under test.
. "$_test_dir/_lib.sh"

# ---- _target_window_present: window present (rc=0) ----------------

echo '=== _target_window_present: target present ==='
WINDOWS_LIST=$'orchestrator\nwatcher\nworker-1'
_target_window_present "orchestrator"; rc=$?
assert_eq "orchestrator window present -> rc=0" "$rc" "0"
_target_window_present "watcher"; rc=$?
assert_eq "watcher window present -> rc=0" "$rc" "0"
_target_window_present "worker-1"; rc=$?
assert_eq "worker-1 window present -> rc=0" "$rc" "0"

# ---- _target_window_present: window absent (rc=2) -----------------

echo '=== _target_window_present: target absent ==='
WINDOWS_LIST=$'watcher\nworker-1'
_target_window_present "orchestrator"; rc=$?
assert_eq "orchestrator absent in non-empty list -> rc=2" "$rc" "2"

WINDOWS_LIST=""
_target_window_present "orchestrator"; rc=$?
assert_eq "orchestrator absent in empty list -> rc=2" "$rc" "2"

# Match must be exact (the underlying grep uses -x). Substring matches
# against existing windows must NOT count as present.
WINDOWS_LIST=$'orchestrator-extra\norchestrato\norchestratord'
_target_window_present "orchestrator"; rc=$?
assert_eq "no exact match -> rc=2" "$rc" "2"

# ---- _target_window_present: no tmux on PATH (rc=1) ---------------

echo '=== _target_window_present: tmux not installed ==='
# Drop the function and replace PATH with a directory that holds no
# `tmux` binary so `command -v tmux` returns nonzero. Restore at the
# end so any future tests start clean.
saved_path="$PATH"
empty_dir=$(mktemp -d)
PATH="$empty_dir"
unset -f tmux
_target_window_present "orchestrator"; rc=$?
assert_eq "no tmux available -> rc=1" "$rc" "1"
PATH="$saved_path"
rm -rf "$empty_dir"

# ---- _target_window_present: tmux query FAILS (rc=1, fail-closed) -
# Regression for the U1 respawn-storm: a `tmux list-windows` that
# FAILS (dead server, or a stale-client/newer-server protocol-version
# mismatch whose stderr is swallowed) must classify as "can't
# classify" (rc=1) — NEVER "absent" (rc=2), which main.sh would count
# toward the fast-respawn streak. Restore the mock tmux first (the
# no-tmux block above unset it), then make its query fail.
eval "$(declare -f tmux 2>/dev/null)" 2>/dev/null || true
tmux() {
    local sub="$1"; shift
    case "$sub" in
        list-windows)
            if (( TMUX_LIST_RC != 0 )); then
                echo 'protocol version mismatch (client 8, server 7)' >&2
                return "$TMUX_LIST_RC"
            fi
            printf '%s\n' "$WINDOWS_LIST"
            return 0
            ;;
        *) return 0 ;;
    esac
}
echo '=== _target_window_present: tmux query fails (version mismatch) ==='
TMUX_LIST_RC=1
WINDOWS_LIST=$'orchestrator\nwatcher'   # target WOULD be present if queryable
_target_window_present "orchestrator"; rc=$?
assert_eq "tmux query failure -> rc=1 (not absent)" "$rc" "1"
# Even with an empty would-be list, a failed query is still rc=1.
WINDOWS_LIST=""
_target_window_present "orchestrator"; rc=$?
assert_eq "tmux query failure, empty list -> rc=1 (not absent)" "$rc" "1"
TMUX_LIST_RC=0

# ---- _classify_diff: helpers --------------------------------------

# classify_stdin
# Reads a synthetic diff body from stdin into a temp file, runs
# _classify_diff against it, and captures stdout into CD_OUT and
# the exit code into CD_RC. Removes the temp file before returning.
CD_OUT=""
CD_RC=0
classify_stdin() {
    local diff_file
    diff_file=$(mktemp)
    cat > "$diff_file"
    CD_OUT=$(_classify_diff "$diff_file")
    CD_RC=$?
    rm -f "$diff_file"
}

# assert_git_noise <label> <rc> <out>
# Combined assertion for the four "git-only diff is noise" cases:
# rc must be 1 (suppress), and stdout must mention `git-section update`.
assert_git_noise() {
    local label="$1" rc="$2" out="$3"
    assert_eq "$label: rc=1 (suppress)" "$rc" "1"
    if [[ -n "$out" && "$out" == *"git-section update"* ]]; then
        printf '  PASS: %s: summary mentions git updates (%q)\n' "$label" "$out"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s: expected non-empty git-section update summary, got %q\n' \
            "$label" "$out" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- _classify_diff: clean -> dirty flip (rc=1) -------------------

echo '=== _classify_diff: clean -> dirty flip ==='
classify_stdin <<'DIFF'
 --- git ---
-myproj abc123 clean
+myproj abc123 dirty
DIFF
assert_git_noise "clean -> dirty single project" "$CD_RC" "$CD_OUT"

# ---- _classify_diff: dirty -> clean flip (rc=1) -------------------

echo '=== _classify_diff: dirty -> clean flip ==='
classify_stdin <<'DIFF'
 --- git ---
-myproj abc123 dirty
+myproj def456 clean
DIFF
assert_git_noise "dirty -> clean (post-commit)" "$CD_RC" "$CD_OUT"

# ---- _classify_diff: SHA change on clean-clean (rc=1) -------------

echo '=== _classify_diff: SHA change on clean-clean ==='
classify_stdin <<'DIFF'
 --- git ---
-myproj abc123 clean
+myproj def456 clean
DIFF
assert_git_noise "SHA change clean-clean (post-push)" "$CD_RC" "$CD_OUT"

# ---- _classify_diff: new project line added (rc=1) ----------------

echo '=== _classify_diff: new project added ==='
classify_stdin <<'DIFF'
 --- git ---
+newproj abc123 clean
DIFF
assert_git_noise "new project line (worker cloned)" "$CD_RC" "$CD_OUT"

# ---- _classify_diff: mixed signal regression (rc=0) ---------------
# Git noise alongside a final report addition must still emit — the
# classifier suppresses ONLY when the diff is entirely noise.

echo '=== _classify_diff: mixed signal (git + new report) ==='
classify_stdin <<'DIFF'
 --- reports ---
+nexus_2026-05-06_120000_test.md 1714986000.0
 --- git ---
-myproj abc123 clean
+myproj abc123 dirty
DIFF
assert_eq "mixed (git+new report) -> rc=0 (signal)" "$CD_RC" "0"

# ---- Summary ------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
