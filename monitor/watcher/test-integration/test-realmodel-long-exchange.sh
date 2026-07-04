#!/usr/bin/env bash
# test-realmodel-long-exchange.sh — long operator<->CC exchange against
# the REAL `claude` binary, with injected rendering distortion
# (your-org/your-nexus#205, PR your-org/nexus-code#270).
#
# Boots the real binary on the auth-free mock backend and drives a
# multi-turn conversation: per turn a user-prompt stamp (the hook
# contract event the watcher's engagement trigger consumes), a
# send-keys prompt, the mock's canned answer, then a "watcher cycle"
# that feeds the REAL pane-state.sh output (state + transcript-region
# content_hash of the real TUI) through the REAL _idle_probe.sh
# engagement bookkeeping (_openg_observe / _openg_marked).
#
# The operator's concern under test: CC occasionally garbles its own
# rendering, and the engagement mark must stay correct across a LONG
# exchange anyway. Distortion is injected by writing ANSI soup straight
# to the pane's tty — bytes land in the terminal exactly as a TUI
# repaint artifact would, on top of whatever CC last drew:
#
#   - the operator-driven window (corroborated submits) seeds and HOLDS
#     its mark through every turn, including cycles whose capture is
#     distorted and the clean frames after them (no drop);
#   - a bystander window that receives the same distortion but NO
#     submit never marks (distortion may withhold, never fabricate);
#   - the real binary's idle pane hashes STABLE across seconds (the
#     timer/spinner churn must be invisible, else stale marks would
#     never expire) — and once the pane sits static past a short change
#     TTL the mark lapses, then a returning submit re-engages.
#
# Identity note: the harness boots WITHOUT the worker heartbeat hooks,
# so the test writes the UserPromptSubmit stamp itself, simulating the
# OPERATOR typing (no machine-input stamp accompanies it — production
# orchestrator pastes go through monitor/paste-followup.sh, which is
# what distinguishes them). The stamp is deterministic contract data;
# what this scenario adds over the unit suites is the REAL rendering
# surface feeding the corroboration hash.
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary);
# self-skips otherwise. See monitor/cc-harness/README.md.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

cch_skip_if_disabled
cch_setup

PROBE="$_self_dir/../_idle_probe.sh"
ENG_STATE="$CCH_DIR/eng-state"
mkdir -p "$ENG_STATE/user-prompt"
: > "$ENG_STATE/action-log.jsonl"

echo "=== real-binary harness: long exchange with injected rendering distortion ==="
echo "    claude:  $CLAUDE_BIN"
echo "    mock:    127.0.0.1:$CCH_MOCK_PORT"

# ---- engagement-probe plumbing ---------------------------------------------

# One watcher cycle for one window: real pane-state line -> real
# _openg_observe. $1 = tmux window index, $2 = bookkeeping name.
eng_observe() {
    local idx="$1" name="$2" line state hash now
    line=$(cch_pane_state "$idx")
    state=$(sed -n 's/.*state=\([^ ]*\).*/\1/p' <<<"$line")
    hash=$(sed -n 's/.*content_hash=\([0-9]*\).*/\1/p' <<<"$line")
    now=$(date +%s)
    PATH="$CCH_DIR/.bin:$PATH" bash -c "
        set -uo pipefail
        STATE_DIR='$ENG_STATE'
        export STATE_DIR
        source '$PROBE'
        _openg_observe '$name' '$state' '$hash' '$now' 1800
    " >/dev/null 2>&1
}

# Is `name` carrying a VALID mark right now? rc 0/1 from the real
# predicate. Optional $2 overrides the change TTL.
eng_marked() {
    local name="$1" ttl="${2:-}"
    PATH="$CCH_DIR/.bin:$PATH" bash -c "
        set -uo pipefail
        STATE_DIR='$ENG_STATE'
        export STATE_DIR
        source '$PROBE'
        ${ttl:+MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS=$ttl} _openg_marked '$name'
    " >/dev/null 2>&1
}

eng_stamp_submit() {  # the UserPromptSubmit hook contract event
    printf '%s\t%s\n' "$(date +%s)" "realmodel-session" \
        > "$ENG_STATE/user-prompt/$1"
}

eng_row() {
    awk -F'\t' -v w="$1" '$1 == w { print; exit }' \
        "$ENG_STATE/operator-engaged.tsv" 2>/dev/null
}

# Write rendering garbage straight onto the window's terminal — the
# distortion injection. Same visual effect as a CC repaint artifact:
# ANSI soup lands in the scrollback above the input row.
inject_distortion() {
    local idx="$1" tag="$2" tty
    tty=$(cch_tmux display-message -p -t "$CCH_SESSION:$idx" '#{pane_tty}' 2>/dev/null)
    [[ -n "$tty" && -w "$tty" ]] || return 1
    printf '\033[38;5;196m\342\226\223\342\226\222\342\226\221GLITCH-%s-REDRAW\033[7m\342\214\247\342\214\247\033[0m\342\226\221\342\226\222\342\226\223qpzw\033[0m\r\n' \
        "$tag" > "$tty" 2>/dev/null
}

# ---- boot two workers -------------------------------------------------------

W1=$(cch_boot_worker convo)
[[ -n "$W1" ]] || { echo "FAIL: convo window never appeared" >&2; exit 1; }
W2=$(cch_boot_worker bystander)
[[ -n "$W2" ]] || { echo "FAIL: bystander window never appeared" >&2; exit 1; }

wait_for "convo boots to idle"     45 -- cch_state_is "$W1" idle
wait_for "bystander boots to idle" 45 -- cch_state_is "$W2" idle

# Baseline observation cycle (first sight) for both windows.
eng_observe "$W1" convo
eng_observe "$W2" bystander

# ---- the long exchange ------------------------------------------------------

# Predicate: the canned marker for a turn has rendered in the pane.
pane_has() {
    local idx="$1" marker="$2"
    cch_capture "$idx" | grep -qF "$marker"
}

TURNS=5
for turn in $(seq 1 "$TURNS"); do
    marker="TURN_${turn}_COMPLETE"
    cch_control "{\"mode\":\"text\",\"text\":\"$marker answer body for round $turn: distinct prose so the transcript grows.\"}"

    # The operator submits: hook stamp + real keystrokes into the TUI.
    eng_stamp_submit convo
    cch_send "$W1" "question $turn: please elaborate on topic $turn"

    wait_for "turn $turn: answer rendered"   30 -- pane_has "$W1" "$marker"
    wait_for "turn $turn: back to idle"      30 -- cch_state_is "$W1" idle

    # Distortion schedule: every 2nd turn, garble BOTH windows' panes
    # right before the watcher cycle that follows the answer.
    if (( turn % 2 == 0 )); then
        inject_distortion "$W1" "c$turn" || true
        inject_distortion "$W2" "b$turn" || true
        sleep 0.3
    fi

    eng_observe "$W1" convo
    eng_observe "$W2" bystander

    if eng_marked convo; then
        echo "  PASS: turn $turn: convo mark held"; PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: turn $turn: convo mark missing (row: $(eng_row convo))" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    if eng_marked bystander; then
        echo "  FAIL: turn $turn: bystander fabricated a mark (row: $(eng_row bystander))" >&2
        FAIL=$(( FAIL + 1 ))
    else
        echo "  PASS: turn $turn: bystander unmarked"; PASS=$(( PASS + 1 ))
    fi
done

assert_contains "convo row is hook-seeded (src=submit)" "$(eng_row convo)" submit
assert_empty    "bystander never got a row"             "$(eng_row bystander)"

# A clean frame right after the last distortion cycle must not drop the
# genuinely-active session: observe again with no new interaction.
eng_observe "$W1" convo
if eng_marked convo; then
    echo "  PASS: clean frame after distortion: mark still held"; PASS=$(( PASS + 1 ))
else
    echo "  FAIL: clean frame after distortion dropped the mark" >&2; FAIL=$(( FAIL + 1 ))
fi

# ---- real-TUI idle stability + self-expiry ----------------------------------

# The transcript-region hash of the REAL idle pane must be stable while
# nothing happens — CC's timer digits / spinner / input-row churn have
# to be invisible, otherwise a stale mark would never expire in
# production. This is the property no synthetic fixture can prove.
h1=$(cch_pane_state "$W1" | sed -n 's/.*content_hash=\([0-9]*\).*/\1/p')
sleep 2
h2=$(cch_pane_state "$W1" | sed -n 's/.*content_hash=\([0-9]*\).*/\1/p')
assert_eq "real idle pane hashes stable across 2s" "$h2" "$h1"

# Static past a 4 s TTL -> the mark lapses (self-expiry on the real
# rendering surface).
TTL=4
sleep $(( TTL + 2 ))
eng_observe "$W1" convo
if eng_marked convo "$TTL"; then
    echo "  FAIL: static pane past TTL still marked (pinned-window risk)" >&2
    FAIL=$(( FAIL + 1 ))
else
    echo "  PASS: static pane past TTL: mark lapsed"; PASS=$(( PASS + 1 ))
fi

# The operator returns: one more corroborated turn re-engages.
cch_control '{"mode":"text","text":"FINAL_TURN_COMPLETE wrap-up prose after the operator returns."}'
eng_stamp_submit convo
cch_send "$W1" "one more question after stepping away"
wait_for "return turn: answer rendered" 30 -- pane_has "$W1" FINAL_TURN_COMPLETE
wait_for "return turn: back to idle"    30 -- cch_state_is "$W1" idle
eng_observe "$W1" convo
if eng_marked convo "$TTL"; then
    echo "  PASS: returning submit re-engages"; PASS=$(( PASS + 1 ))
else
    echo "  FAIL: returning submit failed to re-engage (row: $(eng_row convo))" >&2
    FAIL=$(( FAIL + 1 ))
fi

th_summary_and_exit
