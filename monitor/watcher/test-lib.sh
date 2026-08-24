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

# Pane table the mock serves, one `<window_name>|<pane_dead>` row
# per line — the exact shape `_target_window_present` asks tmux for.
# `set_live_windows` is the convenience for the common case (every
# named window holds one live pane); tests that care about
# `#{pane_dead}` set PANES_LIST directly.
PANES_LIST=""
set_live_windows() {
    local n out=''
    for n in "$@"; do out+="${out:+$'\n'}${n}|0"; done
    PANES_LIST="$out"
}

# When non-zero, the mock `tmux list-panes` simulates a COMMAND
# FAILURE (no server running, or a client/server protocol-version
# mismatch): it emits the error text to stderr — which the function's
# `2>/dev/null` swallows, exactly as in production — and exits with
# this code, producing empty stdout. Reset to 0 for the normal path.
TMUX_LIST_RC=0

# Mock tmux: implements only `list-panes -s -F '<name>|<pane_dead>'`,
# the one verb _target_window_present cares about.
#
# THE DEFAULT ARM REFUSES, LOUDLY (your-org/nexus-code#741). It used to
# be `*) return 0 ;;` — a permissive arm that answered every
# unimplemented verb with "success, no output". When #741 moved the
# probe from `list-windows` to `list-panes`, that arm did not report an
# unmocked verb; it fed the function an EMPTY pane table, which is a
# perfectly well-formed answer meaning "absent". Three present-cases
# flipped to rc=2 and two fail-closed cases flipped from rc=1 to rc=2 —
# a mock silently manufacturing the exact false-ABSENT verdict this
# suite exists to prevent. Here that was loud, because the assertions
# were watching. In a suite where they were not, it is a green.
#
# Defined ONCE, via an installer, because the "tmux query fails" block
# below needs to reinstate it after a no-tmux test unsets it. That
# block used to carry its own verbatim copy of the body, and the copy
# is what made the #741 verb change land as two DIFFERENT failures in
# one file. A mock with two definitions has two contracts.
install_mock_tmux() {
    tmux() {
        local sub="$1"; shift
        case "$sub" in
            list-panes)
                if (( TMUX_LIST_RC != 0 )); then
                    echo 'protocol version mismatch (client 8, server 7)' >&2
                    return "$TMUX_LIST_RC"
                fi
                printf '%s\n' "$PANES_LIST"
                return 0
                ;;
            *)
                printf 'mock tmux: unimplemented verb %q — refusing rather than answering "success, no output" (see #741)\n' \
                    "$sub" >&2
                return 3
                ;;
        esac
    }
    export -f tmux
}
install_mock_tmux

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
set_live_windows orchestrator watcher worker-1
_target_window_present "orchestrator"; rc=$?
assert_eq "orchestrator window present -> rc=0" "$rc" "0"
_target_window_present "watcher"; rc=$?
assert_eq "watcher window present -> rc=0" "$rc" "0"
_target_window_present "worker-1"; rc=$?
assert_eq "worker-1 window present -> rc=0" "$rc" "0"

# ---- _target_window_present: window absent (rc=2) -----------------

echo '=== _target_window_present: target absent ==='
set_live_windows watcher worker-1
_target_window_present "orchestrator"; rc=$?
assert_eq "orchestrator absent in non-empty list -> rc=2" "$rc" "2"

PANES_LIST=""
_target_window_present "orchestrator"; rc=$?
assert_eq "orchestrator absent in empty list -> rc=2" "$rc" "2"

# Match must be exact. Substring matches against existing windows must
# NOT count as present.
set_live_windows orchestrator-extra orchestrato orchestratord
_target_window_present "orchestrator"; rc=$?
assert_eq "no exact match -> rc=2" "$rc" "2"

# ---- _target_window_present: remain-on-exit corpse (rc=2) ---------
# your-org/nexus-code#741. THE regression: `_respawn.sh` sets
# `remain-on-exit on` on the window it spawns, so a crashed agent
# leaves the window LISTED with a dead pane. Answering PRESENT there
# is what stopped the absent branch from ever firing a second time —
# one respawn, one crash, and a crash-loop guard that needs three.
# The window is still in the table in every case below; only
# `#{pane_dead}` distinguishes them.

echo '=== _target_window_present: dead pane (remain-on-exit corpse) ==='
PANES_LIST='orchestrator|1'
_target_window_present "orchestrator"; rc=$?
assert_eq "listed window, sole pane dead -> rc=2 (corpse, not present)" "$rc" "2"

PANES_LIST=$'watcher|0\norchestrator|1\nworker-1|0'
_target_window_present "orchestrator"; rc=$?
assert_eq "corpse among live siblings -> rc=2" "$rc" "2"
# ...and the siblings are unaffected: one window's corpse must not
# condemn another's live pane.
_target_window_present "watcher"; rc=$?
assert_eq "live sibling of a corpse -> rc=0" "$rc" "0"

# A window with several panes is present if ANY pane is live —
# `remain-on-exit` kills panes one at a time, and a split window whose
# second pane still runs the agent is not a corpse.
PANES_LIST=$'orchestrator|1\norchestrator|0'
_target_window_present "orchestrator"; rc=$?
assert_eq "multi-pane, one dead one live -> rc=0 (present)" "$rc" "0"
PANES_LIST=$'orchestrator|1\norchestrator|1'
_target_window_present "orchestrator"; rc=$?
assert_eq "multi-pane, ALL dead -> rc=2 (corpse)" "$rc" "2"

# ---- _target_window_present: pane_dead allowlist ------------------
# ONLY the literal `1` is dead. Every other reading — a tmux too old
# to know the format (empty expansion), a garbled row, an unexpected
# value — must fall back to PRESENT, i.e. to the pre-#741 verdict.
# The asymmetry is deliberate and is the whole safety argument: a
# false ABSENT respawns a live orchestrator (decapitation-duplicate,
# expensive), a false PRESENT misses a respawn (recoverable). Evidence
# short of proof must never buy the expensive one.

echo '=== _target_window_present: pane_dead allowlist (default-deny on "dead") ==='
PANES_LIST='orchestrator|'
_target_window_present "orchestrator"; rc=$?
assert_eq "pane_dead unsupported (empty field) -> rc=0, NOT a respawn" "$rc" "0"
PANES_LIST='orchestrator'
_target_window_present "orchestrator"; rc=$?
assert_eq "row with no delimiter at all -> rc=0, NOT a respawn" "$rc" "0"
PANES_LIST='orchestrator|yes'
_target_window_present "orchestrator"; rc=$?
assert_eq "pane_dead garbage 'yes' -> rc=0, NOT a respawn" "$rc" "0"
PANES_LIST='orchestrator|11'
_target_window_present "orchestrator"; rc=$?
assert_eq "pane_dead '11' is not '1' -> rc=0, NOT a respawn" "$rc" "0"
PANES_LIST='orchestrator|0'
_target_window_present "orchestrator"; rc=$?
assert_eq "pane_dead 0 -> rc=0 (present)" "$rc" "0"

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
# Regression for the U1 respawn-storm: a tmux window/pane query that
# FAILS (dead server, or a stale-client/newer-server protocol-version
# mismatch whose stderr is swallowed) must classify as "can't
# classify" (rc=1) — NEVER "absent" (rc=2), which main.sh would count
# toward the fast-respawn streak. Restore the mock tmux first (the
# no-tmux block above unset it), then make its query fail.
install_mock_tmux
echo '=== _target_window_present: tmux query fails (version mismatch) ==='
TMUX_LIST_RC=1
set_live_windows orchestrator watcher   # target WOULD be present if queryable
_target_window_present "orchestrator"; rc=$?
assert_eq "tmux query failure -> rc=1 (not absent)" "$rc" "1"
# Even with an empty would-be list, a failed query is still rc=1.
PANES_LIST=""
_target_window_present "orchestrator"; rc=$?
assert_eq "tmux query failure, empty list -> rc=1 (not absent)" "$rc" "1"
# ...and a failed query on a window whose panes ARE all dead is still
# rc=1, not the new corpse verdict: the corpse arm must be reachable
# only by positively OBSERVING `pane_dead`, never by failing to look.
PANES_LIST='orchestrator|1'
_target_window_present "orchestrator"; rc=$?
assert_eq "tmux query failure over a would-be corpse -> rc=1 (not 2)" "$rc" "1"
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
