#!/usr/bin/env bash
# Regression test for the bracketed-paste fix in monitor/paste-followup.sh
# (your-org/nexus-code#521).
#
# Run: bash monitor/watcher/test-paste-bracketed.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Skips loudly if tmux absent.
#
# Background: `paste-followup.sh` pasted multi-line follow-ups WITHOUT `-p`,
# so tmux replaced each embedded linefeed with its separator (CR) and the
# newline reached the Claude REPL as an Enter — the first line submitted
# alone, the rest stranded. The fix is `tmux paste-buffer -p …`: `-p` wraps
# the buffer in bracketed-paste control codes (`ESC[200~ … ESC[201~`) IFF the
# receiving application has requested bracketed-paste mode (mode ?2004), so
# the whole message arrives as one literal paste and the newline is text.
#
# These tests drive a REAL isolated tmux server (`tmux -L`, never the
# operator's) and capture what a pane actually receives, proving:
#   1. app requested mode ?2004 + `-p` → bytes ARE wrapped (the fix works,
#      verified on the deployed tmux 2.6);
#   2. same pane, NO `-p` (the pre-fix call) → NOT wrapped (the bug);
#   3. app did NOT request mode ?2004 + `-p` → NOT wrapped (safe-by-
#      construction: `-p` is inert unless the app opted in, so it can never
#      regress a non-bracketed consumer);
#   4. source guard: paste-followup.sh's paste-buffer call carries `-p`.
#
# The ?2004h must be parsed by tmux BEFORE the paste — a settle delay avoids
# the race (without it the capture is flaky; see the issue thread). The wrap
# capture is retried a few times to stay robust under a loaded CI runner.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MONITOR_DIR=$(cd "$_script_dir/.." && pwd)
PASTE="$MONITOR_DIR/paste-followup.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

command -v tmux >/dev/null 2>&1 || { echo "skipped: tmux not on PATH"; exit 0; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ESC[200~ = 1b 5b 32 30 30 7e ; ESC[201~ = 1b 5b 32 30 31 7e
OPEN_HEX='1b5b3230307e'
CLOSE_HEX='1b5b3230317e'

# Capture the bytes a pane receives from a paste.
#   $1 = "on"|"off"  — whether the pane requests bracketed-paste mode ?2004
#   $2 = extra paste-buffer flags (e.g. "-p")
# Echoes the hex of the received bytes.
capture() {
    local mode="$1" flags="$2"
    local sock="pb-$$-${RANDOM}" out="$WORK/out-${RANDOM}"; : > "$out"
    local enable=""
    [[ "$mode" == "on" ]] && enable='printf "\033[?2004h"; '
    local p
    p=$(tmux -L "$sock" new-session -d -P -F '#{pane_id}' -x 80 -y 24 \
        "bash -c 'stty raw -echo; ${enable}dd of=$out bs=1 2>/dev/null'") || { echo ""; return; }
    sleep 1.2   # let tmux parse the pane's ?2004h before pasting
    tmux -L "$sock" set-buffer -b B -- "$(printf 'lineA\nlineB')" 2>/dev/null
    # shellcheck disable=SC2086
    tmux -L "$sock" paste-buffer $flags -d -b B -t "$p" 2>/dev/null
    sleep 0.8
    tmux -L "$sock" send-keys -t "$p" C-d 2>/dev/null; sleep 0.3
    tmux -L "$sock" kill-server 2>/dev/null
    od -An -tx1 "$out" 2>/dev/null | tr -d ' \n'
}

# Retry the wrap capture: deterministic WITH settle, but stay robust on a
# loaded runner. Succeeds as soon as one attempt shows the wrapper.
wrapped_within() {
    local mode="$1" flags="$2" tries="$3" hex
    for _ in $(seq 1 "$tries"); do
        hex=$(capture "$mode" "$flags")
        [[ "$hex" == *"$OPEN_HEX"* && "$hex" == *"$CLOSE_HEX"* ]] && return 0
    done
    return 1
}

echo "== tmux $(tmux -V) =="

# 1. app requested ?2004 + -p → wrapped (the fix works)
if wrapped_within on "-p" 4; then
    pass "app requested mode ?2004 + '-p' → paste is bracketed (ESC[200~ … ESC[201~)"
else
    fail "'-p' did NOT wrap even with a settle — the fix's mechanism is not delivered on this tmux"
fi

# 2. same pane, NO -p (the pre-fix call) → not wrapped (the bug)
hex=$(capture on "")
if [[ "$hex" != *"$OPEN_HEX"* ]]; then
    pass "no '-p' → paste is NOT bracketed (reproduces the pre-fix bug)"
else
    fail "paste-buffer without '-p' unexpectedly wrapped — test cannot distinguish the fix"
fi

# 3. app did NOT request ?2004 + -p → not wrapped (safe-by-construction)
hex=$(capture off "-p")
if [[ "$hex" != *"$OPEN_HEX"* ]]; then
    pass "'-p' on a pane that did NOT request mode ?2004 → inert (no regression risk)"
else
    fail "'-p' wrapped a pane that never requested bracketed paste — unexpected"
fi

# 4. source guard: the fix is present in paste-followup.sh
if grep -Eq 'tmux paste-buffer[^|]*-p' "$PASTE"; then
    pass "paste-followup.sh calls paste-buffer with '-p'"
else
    fail "paste-followup.sh paste-buffer call lost its '-p' flag (regression)"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
