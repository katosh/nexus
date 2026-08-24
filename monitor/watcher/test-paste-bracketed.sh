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
# The ?2004h must be parsed by tmux BEFORE the paste. The original fixture
# guessed at that with `sleep 1.2`, which is not a synchronisation primitive:
# the pane shell was the operator's LOGIN shell, and on a loaded sandbox host
# its rc chain (Lmod/lua, conda, linuxbrew) took ~6 s to reach the first
# instruction — so every attempt, retries included, pasted into a pane that
# had not yet emitted ?2004h, `-p` correctly declined to wrap, and assertion 1
# failed 100% of the time while 2 and 3 passed VACUOUSLY on an empty capture.
# Two changes make it deterministic (your-org/nexus-code#555):
#   * a hermetic fixture shell (th_tmux_fixture_conf) — a bare `sh`, no rc
#     files, ready in ~0.2 s;
#   * a real happens-before edge — the pane prints a RDY sentinel immediately
#     AFTER the ?2004h and we poll capture-pane for it. tmux parses a pane's
#     byte stream in order, so seeing RDY proves ?2004h is already parsed.
# The negative assertions now also require the payload to have ARRIVED, so an
# empty capture reads as a failure instead of a pass.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MONITOR_DIR=$(cd "$_script_dir/.." && pwd)
PASTE="$MONITOR_DIR/paste-followup.sh"
# shellcheck source=/dev/null
. "$_script_dir/_test_helpers.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

command -v tmux >/dev/null 2>&1 || { echo "skipped: tmux not on PATH"; exit 77; }   # SKIP (#568 A6)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
TCONF="$WORK/tmux.conf"
th_tmux_fixture_conf "$TCONF"

# ESC[200~ = 1b 5b 32 30 30 7e ; ESC[201~ = 1b 5b 32 30 31 7e
OPEN_HEX='1b5b3230307e'
CLOSE_HEX='1b5b3230317e'
# 'lineB' — the payload's LAST line. Present iff the whole paste landed.
PAYLOAD_HEX='6c696e6542'

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
    # RDY is printed AFTER the ?2004h, so tmux having rendered RDY proves it
    # already parsed the mode-set. `stty raw -echo` keeps the pasted bytes off
    # the screen, so RDY can only come from the pane's own printf.
    p=$(tmux -L "$sock" -f "$TCONF" new-session -d -P -F '#{pane_id}' -x 80 -y 24 \
        "sh -c 'stty raw -echo; ${enable}printf \"RDY\r\n\"; dd of=$out bs=1 2>/dev/null'") \
        || { echo ""; return; }
    if ! th_tmux_wait_pane tmux -L "$sock" -- "$p" RDY 30; then
        tmux -L "$sock" kill-server 2>/dev/null
        echo ""; return
    fi
    tmux -L "$sock" set-buffer -b B -- "$(printf 'lineA\nlineB')" 2>/dev/null
    # shellcheck disable=SC2086
    tmux -L "$sock" paste-buffer $flags -d -b B -t "$p" 2>/dev/null
    # dd is byte-at-a-time; wait for the payload to land rather than guessing.
    local deadline=$(( SECONDS + 15 ))
    while (( SECONDS < deadline )); do
        grep -q 'lineB' "$out" 2>/dev/null && break
        sleep 0.1
    done
    tmux -L "$sock" send-keys -t "$p" C-d 2>/dev/null; sleep 0.3
    tmux -L "$sock" kill-server 2>/dev/null
    od -An -tx1 "$out" 2>/dev/null | tr -d ' \n'
}

echo "== tmux $(tmux -V) =="

# ---- capability gate (deliberately NOT a version gate) ---------------------
#
# Assertions 1-3 exercise `paste-buffer -p`, the bracketed-paste flag. On a
# tmux that does not HAVE that flag, the mechanism under test does not exist
# and a hard failure would be noise, not signal. Detect the capability
# directly instead of pinning a version number: tmux rejects an unknown flag
# with `unknown option` + a `usage:` line, whereas a supported flag reaches
# the buffer lookup and reports `no buffer`.
#
# Capability detection is strictly safer than a version threshold — a
# threshold is a guess that can silently skip a tmux which does support `-p`,
# hiding a real regression. This probe skips ONLY when the flag is genuinely
# absent.
#
# On the deployed tmux 2.6 `-p` IS supported and all four assertions pass, so
# this gate is inert here (your-org/nexus-code#555). It exists so the suite
# degrades honestly on some other tmux, not to paper over anything on ours.
paste_p_supported() {
    local sock="pbcap-$$-${RANDOM}" out
    tmux -L "$sock" -f "$TCONF" new-session -d -x 80 -y 24 'sleep 30' 2>/dev/null || return 0
    out=$(tmux -L "$sock" paste-buffer -p -b __nexus_probe__ 2>&1)
    tmux -L "$sock" kill-server 2>/dev/null
    [[ "$out" == *"unknown option"* || "$out" == *"usage:"* ]] && return 1
    return 0
}

if paste_p_supported; then

# Every case below asserts on a capture that MUST contain the payload. An
# empty capture (pane never started, server died) used to satisfy all three
# "is NOT wrapped" assertions vacuously; now it is a loud failure with the
# hex printed, so a broken fixture can never masquerade as a green test.
assert_paste() {
    local label="$1" mode="$2" flags="$3" want="$4"   # want = wrapped|plain
    local hex; hex=$(capture "$mode" "$flags")
    if [[ "$hex" != *"$PAYLOAD_HEX"* ]]; then
        fail "$label — payload never reached the pane (fixture broken, hex='$hex')"
        return
    fi
    if [[ "$want" == wrapped ]]; then
        if [[ "$hex" == *"$OPEN_HEX"* && "$hex" == *"$CLOSE_HEX"* ]]; then
            pass "$label"
        else
            fail "$label — payload arrived UNWRAPPED (hex='$hex')"
        fi
    else
        if [[ "$hex" != *"$OPEN_HEX"* && "$hex" != *"$CLOSE_HEX"* ]]; then
            pass "$label"
        else
            fail "$label — payload arrived WRAPPED (hex='$hex')"
        fi
    fi
}

    # 1. app requested ?2004 + -p → wrapped (the fix works)
    assert_paste "app requested mode ?2004 + '-p' → paste is bracketed (ESC[200~ … ESC[201~)" \
                 on "-p" wrapped

    # 2. same pane, NO -p (the pre-fix call) → not wrapped (the bug)
    assert_paste "no '-p' → paste is NOT bracketed (reproduces the pre-fix bug)" \
                 on "" plain

    # 3. app did NOT request ?2004 + -p → not wrapped (safe-by-construction)
    assert_paste "'-p' on a pane that did NOT request mode ?2004 → inert (no regression risk)" \
                 off "-p" plain
else
    printf '  SKIP: tmux %s has no `paste-buffer -p` — the bracketed-paste\n' "$(tmux -V)"
    printf '        mechanism does not exist on it; assertions 1-3 are unrunnable.\n'
    printf '        The source guard below still runs (version-independent).\n'
fi

# 4. source guard: the fix is present in paste-followup.sh. Deliberately
#    OUTSIDE the capability gate — it is a pure source grep, so it holds the
#    regression line on every tmux, including one that cannot run 1-3.
if grep -Eq 'tmux paste-buffer[^|]*-p' "$PASTE"; then
    pass "paste-followup.sh calls paste-buffer with '-p'"
else
    fail "paste-followup.sh paste-buffer call lost its '-p' flag (regression)"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
