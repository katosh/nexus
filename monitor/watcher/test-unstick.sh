#!/usr/bin/env bash
# Mock-tmux unit tests for monitor/watcher/_unstick.sh.
#
# Source the library, override `tmux` and `curl` with bash functions
# that record calls to a side-channel, drive the public functions
# (`detect_and_unstick`, `_act_ratelimit`, `_check_orchestrator_ack`,
# `_probe_ratelimit_reset`), and assert on the recorded calls + the
# watcher-unstick.log lines that get appended.
#
# Run: bash monitor/watcher/test-unstick.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Why a hand-rolled harness rather than bats / shunit2: the existing
# repo doesn't carry a test framework, this file is self-contained and
# zero-dep. If we ever standardise on a framework, port these
# scenarios over wholesale.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0

assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if ! grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         did NOT expect: %s\n' "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
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

# ---- mock harness --------------------------------------------------------

# Per-test scratch dirs are created in setup_test().
WORK=""
PANES_DIR=""        # one file per window: "$PANES_DIR/<win>" holds capture-pane stdout
ACTIONS=""          # newline-separated record of tmux invocations
WINDOWS_LIST=""     # newline-separated mocked window list

# Mock `tmux`: implements just the verbs _unstick.sh calls.
tmux() {
    local sub="$1"; shift
    case "$sub" in
        capture-pane)
            local target=""
            while (( $# > 0 )); do
                case "$1" in
                    -t) target="$2"; shift 2 ;;
                    *)  shift ;;
                esac
            done
            if [[ -n "$target" && -f "$PANES_DIR/$target" ]]; then
                cat "$PANES_DIR/$target"
                return 0
            fi
            return 1
            ;;
        list-windows)
            printf '%s\n' "$WINDOWS_LIST"
            return 0
            ;;
        send-keys)
            local target="" rest=""
            while (( $# > 0 )); do
                case "$1" in
                    -t) target="$2"; shift 2 ;;
                    *)  rest+=" $1"; shift ;;
                esac
            done
            printf 'send-keys win=%s args=%s\n' "$target" "${rest# }" >> "$ACTIONS"
            return 0
            ;;
        load-buffer)
            local buf="" path=""
            while (( $# > 0 )); do
                case "$1" in
                    -b) buf="$2"; shift 2 ;;
                    *)  path="$1"; shift ;;
                esac
            done
            local content=""
            [[ -f "$path" ]] && content=$(<"$path")
            printf 'load-buffer buf=%s content=%s\n' "$buf" "$content" >> "$ACTIONS"
            return 0
            ;;
        paste-buffer)
            local buf="" target=""
            while (( $# > 0 )); do
                case "$1" in
                    -b) buf="$2"; shift 2 ;;
                    -t) target="$2"; shift 2 ;;
                    *)  shift ;;
                esac
            done
            printf 'paste-buffer buf=%s target=%s\n' "$buf" "$target" >> "$ACTIONS"
            return 0
            ;;
        delete-buffer)
            local buf=""
            while (( $# > 0 )); do
                case "$1" in
                    -b) buf="$2"; shift 2 ;;
                    *)  shift ;;
                esac
            done
            printf 'delete-buffer buf=%s\n' "$buf" >> "$ACTIONS"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux

# Mock `command -v tmux`: must succeed so detect_and_unstick proceeds.
# The bash builtin `command` defers to PATH; functions don't satisfy
# `command -v`, so we install a real-looking tmux shim on PATH.
install_tmux_shim() {
    local shim_dir="$1"
    mkdir -p "$shim_dir"
    cat > "$shim_dir/tmux" <<'SHIM'
#!/bin/bash
# placeholder; real tmux is the bash function that already shadows it.
exit 0
SHIM
    chmod +x "$shim_dir/tmux"
    PATH="$shim_dir:$PATH"
    export PATH
}

setup_test() {
    WORK=$(mktemp -d)
    PANES_DIR="$WORK/panes"
    mkdir -p "$PANES_DIR"
    ACTIONS="$WORK/actions.log"
    : > "$ACTIONS"
    WINDOWS_LIST=""
    UNSTICK_DIR="$WORK/unstick"
    UNSTICK_LOG="$WORK/watcher-unstick.log"
    mkdir -p "$UNSTICK_DIR"
    : > "$UNSTICK_LOG"
    AUTO_UNSTICK="true"
    WATCHER_WINDOW="watcher"
    TARGET="orchestrator"
    ACTION_LOG="$WORK/action-log.jsonl"
    : > "$ACTION_LOG"
    RATELIMIT_PROBE="false"
    RATELIMIT_HEURISTIC_MIN="30"
    RATELIMIT_ACK_TIMEOUT_S="60"
    PROBE_MODEL="claude-haiku-4-5-20251001"
    API_ERROR_BACKOFF_MIN="30"
    ON_DIALOG="auto-dismiss"
    # Case W (worker-blocked-question relay) state. STATE_DIR roots the
    # decisions dir exactly as in production (where
    # UNSTICK_DIR=$STATE_DIR/unstick); the grace default matches
    # production so pre-grace tests are honest.
    STATE_DIR="$WORK"
    MONITOR_WORKER_ASKUQ_GRACE_SECONDS="300"
    export AUTO_UNSTICK WATCHER_WINDOW TARGET UNSTICK_DIR UNSTICK_LOG \
           ACTION_LOG RATELIMIT_PROBE RATELIMIT_HEURISTIC_MIN \
           RATELIMIT_ACK_TIMEOUT_S PROBE_MODEL API_ERROR_BACKOFF_MIN \
           ON_DIALOG STATE_DIR MONITOR_WORKER_ASKUQ_GRACE_SECONDS
}

teardown_test() {
    [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
}

# Permission-prompt fixture (case A).
permission_pane() {
    cat <<'EOF'
Some output...

Do you want to proceed?
❯ 1. Yes
  2. Yes, and allow access to ...
  3. No
EOF
}

# Rate-limit-prompt fixture (case B).
ratelimit_pane() {
    cat <<'EOF'
You've hit the limit.

What do you want to do?
❯ 1. Stop and wait for limit to reset
  2. Upgrade plan
  3. Add extra usage
EOF
}

quiet_pane() {
    cat <<'EOF'
$ ls
foo bar baz
$
EOF
}

# API-error wedge fixture (case C). The chip lives directly under the
# command line. Distinct request_ids → distinct fingerprints across
# re-emits.
api_error_pane() {
    local rid="${1:-req_011XYZ}"
    cat <<EOF
⏺ Do something.
  ⎿  API Error: {"type":"error","error":{"details":null,"type":"api_error","message":"Internal server error"},"request_id":"${rid}"}
EOF
}

# Pane that mentions "API Error" in passing but is NOT the wedge —
# verifies the AND-grep with `"Internal server error"` keeps benign
# prose from triggering case C.
api_error_prose_pane() {
    cat <<'EOF'
⏺ Tell me about API Error handling.
  ⎿  Sure — when an API Error comes back you should…
EOF
}

# AskUserQuestion chip-bar fixture (case D — dialog-guard). The three
# load-bearing literals `Type something.`, `Chat about this`, and the
# live-overlay navigation footer (`Esc to cancel`) together form the
# detection signature. `$1` lets a caller vary the question text to
# produce distinct fingerprints across repeated calls (Case D backoff
# test).
askuq_pane() {
    local q="${1:-How should we proceed with the migration?}"
    cat <<EOF
←  ☐ option 1  ☐ option 2  ✔ Submit  →

$q

❯ 1. Run the backfill in batches
  2. Run the backfill in one pass
  3. Defer the migration to next sprint
  4. Type something.
─────────────────────────────────────────────────────────────
  5. Chat about this
Enter to select · ↑/↓ to navigate · Esc to cancel
EOF
}

# Pane that mentions "Chat about this" in passing but is NOT a
# dialog — verifies the AND-grep with `Type something.` keeps
# benign prose from triggering case D.
askuq_prose_pane() {
    cat <<'EOF'
⏺ Let's chat about this design decision.
  ⎿  Sure — what aspect did you want to drill into?
EOF
}

# The field false-positive shape: a SINGLE line of quoted prose that
# enumerates both AskUQ option literals (`Type something.` +
# `Chat about this`) with NO live-overlay footer — e.g. the
# orchestrator quoting a worker's inventory of the Claude-Code
# TUI-state-detection surface. The two-literal AND alone matched this;
# requiring `Esc to cancel` must keep it from triggering Case D.
askuq_fp_prose_pane() {
    cat <<'EOF'
⏺ Inventory of fragile TUI literals in pane-state.sh:
  ⎿  …chevron ❯<NBSP>, You've hit your limit · resets, Type something.+Chat about this, N monitor still running, spinner token-counter regex…
EOF
}

# The harder false-positive: a FULL overlay block (all literals,
# footer included) quoted into the orchestrator's scrollback — e.g.
# the orchestrator displaying a captured overlay while discussing this
# very feature — followed by the normal Claude Code REPL chrome (input
# box + `◉ model` status line) at the bottom. The footer is present but
# NOT bottom-anchored, so the live-ness gate must reject it. This is
# the exact shape of the field orchestrator false-positive.
askuq_quoted_overlay_then_repl_pane() {
    cat <<'EOF'
● Here's the overlay capture I was asking about:

  Which response mode should we test next?
  ❯ 1. Plain text
    2. Tool use
    4. Type something.
    5. Chat about this
  Enter to select · ↑/↓ to navigate · Esc to cancel

● That's the chip-bar the dialog-guard keys off of. Continuing.

───────────────────────────────────────────────────────────────
❯
───────────────────────────────────────────────────────────────
  ◉ claude-opus-4-8[1m] │ █▉░░░░░░░▓ 285K/1.0M │ ⚡100% │ $345.89
  -- INSERT -- ⏵⏵ bypass permissions on (shift+tab to cycle)
EOF
}

# Permission-prompt fixture that happens to embed `Chat about this`
# in prior turn text — the more dangerous of the two false-positive
# shapes because Case A's `❯ N.` chevron matches the AskUQ overlay
# too. Audits that Case A still fires (not Case D) when only one
# of the two load-bearing AskUQ literals is present.
permission_with_chat_prose_pane() {
    cat <<'EOF'
● Bash(rm -rf /tmp/foo)
  Earlier: "let's chat about this command".
  Do you want to proceed?
❯ 1. Yes
  2. Yes, and allow access to /tmp/foo
  3. No
EOF
}

# Source the library under test (after the harness has set globals).
# _lib.sh first: it defines `_machine_input_stamp`, the shared
# ledger-write chokepoint that _unstick_stamp_machine_input delegates
# to (#293). main.sh sources _lib.sh before _unstick.sh in production;
# the standalone test mirrors that order.
. "$_test_dir/_lib.sh"
. "$_test_dir/_unstick.sh"

# Force command -v tmux to succeed for detect_and_unstick.
SHIM_DIR=$(mktemp -d)
install_tmux_shim "$SHIM_DIR"
trap 'rm -rf "$SHIM_DIR"' EXIT

# ---- Case A regression test ---------------------------------------------

echo '=== Case A: permission prompt regression ==='
setup_test
permission_pane > "$PANES_DIR/perm-win"
quiet_pane      > "$PANES_DIR/quiet-win"
quiet_pane      > "$PANES_DIR/watcher"
WINDOWS_LIST=$'perm-win\nquiet-win\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "case A logs sent-Enter for perm-win" "$log_content" "window=perm-win case=A action=sent-Enter"
assert_not_contains "watcher window untouched"        "$log_content" "window=watcher"
assert_not_contains "quiet window untouched"          "$log_content" "window=quiet-win"
send_count=$(grep -cE '^send-keys win=perm-win' <<<"$actions_content" || true)
assert_eq "perm-win received exactly one send-keys" "$send_count" "1"
# Issue #201: the Enter nudge is a MACHINE input — it must land in
# the machine-input ledger so the idle-probe's attribution rule
# doesn't read the resulting busy transition as operator input.
assert_contains "case A stamps machine-input ledger" \
    "$(cat "$WORK/machine-input.tsv" 2>/dev/null)" $'perm-win\t'
teardown_test

# ---- Case B: cascade post-reset ----------------------------------------

echo '=== Case B: cascade fires after reset epoch elapses ==='
setup_test
ratelimit_pane > "$PANES_DIR/agent-1"
ratelimit_pane > "$PANES_DIR/agent-2"
quiet_pane     > "$PANES_DIR/orchestrator"
quiet_pane     > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-1\nagent-2\norchestrator\nwatcher'
# Pre-seed an already-elapsed reset epoch so the cascade fires now.
echo $(( $(date +%s) - 5 )) > "$UNSTICK_DIR/ratelimit.reset.epoch"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "agent-1 cascaded" "$log_content" "window=agent-1 case=B action=cascade-resumed"
assert_contains "agent-2 cascaded" "$log_content" "window=agent-2 case=B action=cascade-resumed"
assert_contains "heads-up to orchestrator" "$log_content" "case=B action=heads-up target=orchestrator n=2"
assert_contains "cascade-complete tally" "$log_content" "case=B action=cascade-complete unstuck=2"
# Each cascaded agent gets: Enter, i+BSpace (one send-keys), paste-buffer, Enter.
agent1_sk=$(grep -cE '^send-keys win=agent-1' <<<"$actions_content" || true)
agent2_sk=$(grep -cE '^send-keys win=agent-2' <<<"$actions_content" || true)
agent1_paste=$(grep -cE '^paste-buffer buf=.* target=agent-1' <<<"$actions_content" || true)
agent2_paste=$(grep -cE '^paste-buffer buf=.* target=agent-2' <<<"$actions_content" || true)
orch_paste=$(grep -cE '^paste-buffer buf=.* target=orchestrator'  <<<"$actions_content" || true)
assert_eq "agent-1 paste count" "$agent1_paste" "1"
assert_eq "agent-2 paste count" "$agent2_paste" "1"
assert_eq "orchestrator heads-up paste count" "$orch_paste" "1"
# Verify the follow-up text is the agent-resume one for agent-1, not the heads-up.
follow_up_line=$(grep -E "^load-buffer .*content=Please continue with your task" "$ACTIONS" | head -1)
assert_contains "agent follow-up wording" "$follow_up_line" "Please continue with your task. The API rate limit has reset."
heads_up_line=$(grep -E "^load-buffer .*content=Heads-up from watcher" "$ACTIONS" | head -1)
assert_contains "heads-up wording" "$heads_up_line" "Heads-up from watcher: rate limit reset"
assert_contains "heads-up names ratelimit-resume-ack" "$heads_up_line" "ratelimit-resume-ack"
# Cascade marker present, reset cleared.
[[ -f "$UNSTICK_DIR/ratelimit.cascade.epoch" ]] \
    && { echo "  PASS: cascade marker written"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: cascade marker missing" >&2; FAIL=$((FAIL+1)); }
[[ -f "$UNSTICK_DIR/ratelimit.reset.epoch" ]] \
    && { echo "  FAIL: reset marker should be cleared" >&2; FAIL=$((FAIL+1)); } \
    || { echo "  PASS: reset marker cleared"; PASS=$((PASS+1)); }
# Issue #293, gap row 7: the cascade paste into a worker pane must
# stamp the machine-input ledger BEFORE pasting, so the worker's
# resulting UserPromptSubmit is attributed to the MACHINE, not the
# operator. Before this fix the cascade wrote only its own ratelimit
# .fp/.tries files → machine_epoch stayed stale → false operator
# engagement → retire-preflight held at safe=0 until staleness.
mi_content=$(cat "$WORK/machine-input.tsv" 2>/dev/null)
assert_contains "cascade stamps machine-input ledger (agent-1)" \
    "$mi_content" $'agent-1\t'
assert_contains "cascade stamps machine-input ledger (agent-2)" \
    "$mi_content" $'agent-2\t'
assert_eq "cascade stamp names its source (agent-1)" \
    "$(awk -F'\t' '$1=="agent-1" {print $3}' "$WORK/machine-input.tsv" 2>/dev/null)" \
    "unstick-ratelimit"
# The orchestrator heads-up rides _cascade_heads_up_orchestrator, NOT
# the worker-cascade path, so it must NOT stamp (orchestrator window is
# not retire-gated; inventory rows 8/9).
if grep -q $'orchestrator\t' "$WORK/machine-input.tsv" 2>/dev/null; then
    printf '  FAIL: orchestrator heads-up stamped machine-input.tsv (should not)\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: orchestrator heads-up does not stamp machine-input.tsv\n'
    PASS=$(( PASS + 1 ))
fi
# Consumer check (the retire-preflight rule: up_epoch <= machine_epoch
# + slack(120)). A worker submit at cascade time reads as MACHINE.
cascade_machine_epoch=$(awk -F'\t' '$1=="agent-1" && $2 ~ /^[0-9]+$/ && ($2+0)>m {m=$2+0} END {print m+0}' \
    "$WORK/machine-input.tsv" 2>/dev/null)
cascade_up_epoch=$(date +%s)
if (( cascade_machine_epoch > 0 )) && (( cascade_up_epoch <= cascade_machine_epoch + 120 )); then
    printf '  PASS: post-cascade submit attributed machine (up=%s machine=%s)\n' \
        "$cascade_up_epoch" "$cascade_machine_epoch"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: post-cascade submit NOT attributed machine (up=%s machine=%s)\n' \
        "$cascade_up_epoch" "$cascade_machine_epoch" >&2
    FAIL=$(( FAIL + 1 ))
fi
teardown_test

# ---- Case B: orchestrator ack closes the cascade ---------------------------

echo '=== Case B: orchestrator ack clears the cascade marker ==='
setup_test
# Seed a cascade-epoch from 5s ago.
cascade_ts=$(( $(date +%s) - 5 ))
echo "$cascade_ts" > "$UNSTICK_DIR/ratelimit.cascade.epoch"
# Action-log line with ts > cascade_ts.
ack_iso=$(date -Is)
printf '{"ts":"%s","agent":"monitor","event":"ratelimit-resume-ack","note":"saw heads-up"}\n' "$ack_iso" \
    > "$ACTION_LOG"
_check_orchestrator_ack
log_content=$(<"$UNSTICK_LOG")
assert_contains "orchestrator ack logged" "$log_content" "case=B action=orchestrator-ack"
[[ ! -f "$UNSTICK_DIR/ratelimit.cascade.epoch" ]] \
    && { echo "  PASS: cascade marker cleared after ack"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: cascade marker not cleared after ack" >&2; FAIL=$((FAIL+1)); }
teardown_test

# ---- Case B: orchestrator ack timeout fires ----------------------------

echo '=== Case B: orchestrator timeout fires when no ack lands ==='
setup_test
RATELIMIT_ACK_TIMEOUT_S=1
export RATELIMIT_ACK_TIMEOUT_S
echo $(( $(date +%s) - 30 )) > "$UNSTICK_DIR/ratelimit.cascade.epoch"
# action-log empty -> no ack
_check_orchestrator_ack
log_content=$(<"$UNSTICK_LOG")
assert_contains "unresponsive logged" "$log_content" "case=B action=orchestrator-unresponsive"
[[ ! -f "$UNSTICK_DIR/ratelimit.cascade.epoch" ]] \
    && { echo "  PASS: cascade marker cleared after timeout"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: cascade marker not cleared after timeout" >&2; FAIL=$((FAIL+1)); }
teardown_test

# ---- Case B: waiting cycle (reset still in future) ---------------------

echo '=== Case B: waiting (reset still in future) does not cascade ==='
setup_test
ratelimit_pane > "$PANES_DIR/agent-1"
quiet_pane     > "$PANES_DIR/orchestrator"
quiet_pane     > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-1\norchestrator\nwatcher'
# Reset 1 hour from now — far in the future.
echo $(( $(date +%s) + 3600 )) > "$UNSTICK_DIR/ratelimit.reset.epoch"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "detection logged for agent-1" "$log_content" "window=agent-1 case=B action=detected"
assert_contains "waiting line emitted"         "$log_content" "case=B action=waiting"
assert_not_contains "no cascade-resumed yet"   "$log_content" "cascade-resumed"
agent_sk=$(grep -cE '^send-keys win=agent-1' <<<"$actions_content" || true)
assert_eq "agent-1 received zero send-keys (still waiting)" "$agent_sk" "0"
[[ -f "$UNSTICK_DIR/ratelimit.reset.epoch" ]] \
    && { echo "  PASS: reset marker preserved while waiting"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: reset marker should still exist while waiting" >&2; FAIL=$((FAIL+1)); }
teardown_test

# ---- Case C: api-error wedge -------------------------------------------

echo '=== Case C: api-error wedge → Enter sent + fingerprint recorded ==='
setup_test
api_error_pane "req_aaaa1111" > "$PANES_DIR/agent-1"
quiet_pane                    > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-1\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "case C logs sent-Enter for agent-1" "$log_content" "window=agent-1 case=C action=sent-Enter"
send_count=$(grep -cE '^send-keys win=agent-1' <<<"$actions_content" || true)
assert_eq "agent-1 received exactly one send-keys" "$send_count" "1"
[[ -f "$UNSTICK_DIR/agent-1.api-error.fp" ]] \
    && { echo "  PASS: fingerprint file written"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: fingerprint file missing" >&2; FAIL=$((FAIL+1)); }
[[ -f "$UNSTICK_DIR/agent-1.api-error.epoch" ]] \
    && { echo "  PASS: epoch file written"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: epoch file missing" >&2; FAIL=$((FAIL+1)); }
assert_not_contains "watcher window untouched" "$log_content" "window=watcher"
# Issue #201: api-error Enter nudges hit an IDLE-classified prompt —
# without a machine-input stamp the busy retry would falsely mark
# the window operator-engaged.
assert_contains "case C stamps machine-input ledger" \
    "$(cat "$WORK/machine-input.tsv" 2>/dev/null)" $'agent-1\t'
assert_contains "case C stamp names its source" \
    "$(awk -F'\t' '$1=="agent-1" {print $3}' "$WORK/machine-input.tsv" 2>/dev/null)" 'unstick-api-error'
teardown_test

echo '=== Case C: same fingerprint within backoff → skip ==='
setup_test
api_error_pane "req_bbbb2222" > "$PANES_DIR/agent-1"
quiet_pane                    > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-1\nwatcher'
# First detection acts.
detect_and_unstick
# Second detection on the same wedge should be backoff-suppressed.
: > "$ACTIONS"
: > "$UNSTICK_LOG"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "second pass logs skip-backoff" "$log_content" "window=agent-1 case=C action=skip-backoff"
assert_not_contains "no second sent-Enter" "$log_content" "case=C action=sent-Enter"
send_count=$(grep -cE '^send-keys win=agent-1' <<<"$actions_content" || true)
assert_eq "agent-1 received zero send-keys on second pass" "$send_count" "0"
teardown_test

echo '=== Case C: distinct fingerprint (new request_id) re-fires Enter ==='
setup_test
api_error_pane "req_cccc3333" > "$PANES_DIR/agent-1"
quiet_pane                    > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-1\nwatcher'
detect_and_unstick
# Swap to a different request_id → different fp → must re-fire even
# though the previous fp was just recorded.
api_error_pane "req_dddd4444" > "$PANES_DIR/agent-1"
: > "$ACTIONS"
: > "$UNSTICK_LOG"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "distinct fp re-fires" "$log_content" "window=agent-1 case=C action=sent-Enter"
send_count=$(grep -cE '^send-keys win=agent-1' <<<"$actions_content" || true)
assert_eq "agent-1 received one send-keys for the new fp" "$send_count" "1"
teardown_test

echo '=== Case C: post-backoff re-detection re-fires Enter ==='
setup_test
api_error_pane "req_eeee5555" > "$PANES_DIR/agent-1"
quiet_pane                    > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-1\nwatcher'
detect_and_unstick
# Force the recorded epoch to be older than the backoff window
# (default 30 min → 1800 s).
echo $(( $(date +%s) - 2000 )) > "$UNSTICK_DIR/agent-1.api-error.epoch"
: > "$ACTIONS"
: > "$UNSTICK_LOG"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "post-backoff re-fire" "$log_content" "window=agent-1 case=C action=sent-Enter"
send_count=$(grep -cE '^send-keys win=agent-1' <<<"$actions_content" || true)
assert_eq "agent-1 received one send-keys after backoff" "$send_count" "1"
teardown_test

echo '=== Case C: configurable backoff via API_ERROR_BACKOFF_MIN ==='
setup_test
API_ERROR_BACKOFF_MIN=0
export API_ERROR_BACKOFF_MIN
api_error_pane "req_ffff6666" > "$PANES_DIR/agent-1"
quiet_pane                    > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-1\nwatcher'
detect_and_unstick
: > "$ACTIONS"
: > "$UNSTICK_LOG"
# Backoff=0 → same fp on second pass should also fire (age >= 0 fails
# the `< backoff_s` test).
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "backoff=0 re-fires same fp" "$log_content" "window=agent-1 case=C action=sent-Enter"
send_count=$(grep -cE '^send-keys win=agent-1' <<<"$actions_content" || true)
assert_eq "agent-1 received one send-keys with backoff=0" "$send_count" "1"
teardown_test

echo '=== Case C: benign prose mentioning "API Error" does NOT trigger ==='
setup_test
api_error_prose_pane > "$PANES_DIR/agent-1"
quiet_pane           > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-1\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_not_contains "no false-positive on prose" "$log_content" "case=C"
send_count=$(grep -cE '^send-keys win=agent-1' <<<"$actions_content" || true)
assert_eq "agent-1 received zero send-keys on prose" "$send_count" "0"
teardown_test

# ---- _probe_ratelimit_reset: unified header parsing --------------------

echo '=== Probe: parses anthropic-ratelimit-unified-reset header ==='
setup_test
RATELIMIT_PROBE=true
ANTHROPIC_API_KEY="sk-mock"
export RATELIMIT_PROBE ANTHROPIC_API_KEY
# Mock curl to print a fixture set of headers.
curl() {
    cat <<'EOF'
HTTP/2 200
content-type: application/json
anthropic-ratelimit-tokens-limit: 80000
anthropic-ratelimit-tokens-remaining: 79999
anthropic-ratelimit-tokens-reset: 2026-04-29T01:23:45Z
anthropic-ratelimit-unified-reset: 2026-04-29T03:00:00Z

EOF
}
export -f curl
got=$(_probe_ratelimit_reset)
assert_eq "unified-reset wins over tokens-reset" "$got" "2026-04-29T03:00:00Z"
unset -f curl
teardown_test

echo '=== Probe: falls back to tokens-reset when unified absent ==='
setup_test
RATELIMIT_PROBE=true
ANTHROPIC_API_KEY="sk-mock"
export RATELIMIT_PROBE ANTHROPIC_API_KEY
curl() {
    cat <<'EOF'
HTTP/2 200
content-type: application/json
anthropic-ratelimit-tokens-limit: 80000
anthropic-ratelimit-tokens-reset: 2026-04-29T05:00:00Z

EOF
}
export -f curl
got=$(_probe_ratelimit_reset)
assert_eq "tokens-reset fallback" "$got" "2026-04-29T05:00:00Z"
unset -f curl
teardown_test

echo '=== Probe: disabled returns empty ==='
setup_test
RATELIMIT_PROBE=false
export RATELIMIT_PROBE
got=$(_probe_ratelimit_reset)
assert_eq "probe disabled -> empty" "$got" ""
teardown_test

echo '=== Probe: missing key returns empty ==='
setup_test
RATELIMIT_PROBE=true
unset ANTHROPIC_API_KEY
export RATELIMIT_PROBE
got=$(_probe_ratelimit_reset)
assert_eq "probe with no key -> empty" "$got" ""
teardown_test

# ---- Case D: AskUserQuestion chip-bar dialog-guard ---------------------

echo '=== Case D: AskUQ chip-bar → Escape + meta-paste ==='
setup_test
askuq_pane > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'orchestrator\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "case D logs dismissed-and-pasted for orchestrator" "$log_content" "window=orchestrator case=D action=dismissed-and-pasted"
# Escape keypress is the dismissal action. `_paste_line_to_window`
# additionally issues `i BSpace` + `Enter` around the paste, so we
# expect at least 3 send-keys calls and one of them to be `Escape`.
assert_contains "Escape was sent to orchestrator" "$actions_content" "send-keys win=orchestrator args=Escape"
paste_count=$(grep -cE '^paste-buffer buf=.* target=orchestrator' <<<"$actions_content" || true)
assert_eq "orchestrator received exactly one paste-buffer" "$paste_count" "1"
meta_line=$(grep -E '^load-buffer .*content=\[nexus watcher\] An AskUserQuestion dialog' "$ACTIONS" | head -1)
assert_contains "meta-message paste content" "$meta_line" "Nexus orchestrators must never call AskUserQuestion"
assert_contains "meta-message cites agent-prompt.md" "$meta_line" "monitor/agent-prompt.md"
assert_not_contains "watcher window untouched" "$log_content" "window=watcher"
[[ -f "$UNSTICK_DIR/orchestrator.askuq.fp" ]] \
    && { echo "  PASS: askuq fingerprint file written"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: askuq fingerprint file missing" >&2; FAIL=$((FAIL+1)); }
[[ -f "$UNSTICK_DIR/orchestrator.askuq.fired" ]] \
    && { echo "  PASS: askuq fired marker written"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: askuq fired marker missing" >&2; FAIL=$((FAIL+1)); }
audit_count=$(find "$UNSTICK_DIR" -maxdepth 1 -name 'orchestrator.askuq.*.audit' | wc -l)
assert_eq "askuq audit capture written" "$audit_count" "1"
teardown_test

echo '=== Case D: same fingerprint → skip-fired (no second paste) ==='
setup_test
askuq_pane > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'orchestrator\nwatcher'
detect_and_unstick
: > "$ACTIONS"
: > "$UNSTICK_LOG"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "second pass logs skip-fired" "$log_content" "window=orchestrator case=D action=skip-fired"
assert_not_contains "no second dismissed-and-pasted" "$log_content" "action=dismissed-and-pasted"
escape_count=$(grep -cE '^send-keys win=orchestrator args=Escape' <<<"$actions_content" || true)
assert_eq "no second Escape" "$escape_count" "0"
teardown_test

echo '=== Case D: distinct fingerprint (new question) re-fires dismissal ==='
setup_test
askuq_pane "Q1?" > "$PANES_DIR/orchestrator"
quiet_pane       > "$PANES_DIR/watcher"
WINDOWS_LIST=$'orchestrator\nwatcher'
detect_and_unstick
askuq_pane "A completely different question?" > "$PANES_DIR/orchestrator"
: > "$ACTIONS"
: > "$UNSTICK_LOG"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "distinct fp re-fires Case D" "$log_content" "action=dismissed-and-pasted"
escape_count=$(grep -cE '^send-keys win=orchestrator args=Escape' <<<"$actions_content" || true)
assert_eq "Escape re-fires on new fp" "$escape_count" "1"
teardown_test

echo '=== Case D: ON_DIALOG=skip logs detection only ==='
setup_test
ON_DIALOG=skip
export ON_DIALOG
askuq_pane > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'orchestrator\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "skip mode logs detection" "$log_content" "case=D action=skip-detected"
assert_not_contains "skip mode does not dismiss" "$log_content" "action=dismissed-and-pasted"
escape_count=$(grep -cE '^send-keys win=orchestrator args=Escape' <<<"$actions_content" || true)
assert_eq "no Escape sent in skip mode" "$escape_count" "0"
teardown_test

echo '=== Case D: ON_DIALOG=error logs WARN line, no act ==='
setup_test
ON_DIALOG=error
export ON_DIALOG
askuq_pane > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'orchestrator\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "error mode logs WARN line" "$log_content" "WARN window=orchestrator case=D action=detected-no-act"
assert_not_contains "error mode does not dismiss" "$log_content" "action=dismissed-and-pasted"
escape_count=$(grep -cE '^send-keys win=orchestrator args=Escape' <<<"$actions_content" || true)
assert_eq "no Escape sent in error mode" "$escape_count" "0"
teardown_test

echo '=== Case D: benign prose mentioning "Chat about this" does NOT trigger ==='
setup_test
askuq_prose_pane > "$PANES_DIR/orchestrator"
quiet_pane       > "$PANES_DIR/watcher"
WINDOWS_LIST=$'orchestrator\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_not_contains "no false-positive on AskUQ prose" "$log_content" "case=D"
escape_count=$(grep -cE '^send-keys win=orchestrator args=Escape' <<<"$actions_content" || true)
assert_eq "orchestrator received zero Escape on prose" "$escape_count" "0"
teardown_test

echo '=== Case D scope: live overlay on a NON-orchestrator window is left untouched ==='
# The over-broad-scope regression: a real AskUQ overlay (all three
# detection literals present) on an operator-owned or worker window
# must NOT be dismissed — only the orchestrator's paste channel is at
# risk. The guard must short-circuit on the window-name gate.
setup_test
askuq_pane > "$PANES_DIR/cc-mock-lab"   # operator-owned interactive window
askuq_pane > "$PANES_DIR/some-worker"   # worker pane w/ sub-agent dialog
quiet_pane > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'cc-mock-lab\nsome-worker\norchestrator\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_not_contains "no Case D action on operator window" "$log_content" "window=cc-mock-lab case=D"
assert_not_contains "no Case D action on worker window"   "$log_content" "window=some-worker case=D"
mock_escape=$(grep -cE '^send-keys win=cc-mock-lab args=Escape' <<<"$actions_content" || true)
worker_escape=$(grep -cE '^send-keys win=some-worker args=Escape' <<<"$actions_content" || true)
assert_eq "operator window received zero Escape" "$mock_escape" "0"
assert_eq "worker window received zero Escape"   "$worker_escape" "0"
mock_paste=$(grep -cE '^paste-buffer buf=.* target=cc-mock-lab' <<<"$actions_content" || true)
assert_eq "operator window received zero paste-buffer" "$mock_paste" "0"
# No fingerprint/fired state should be written for exempt windows.
[[ ! -f "$UNSTICK_DIR/cc-mock-lab.askuq.fired" ]] \
    && { echo "  PASS: no askuq state for operator window"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: askuq state written for exempt window" >&2; FAIL=$((FAIL+1)); }
teardown_test

echo '=== Case D FP: two option literals WITHOUT the live-overlay footer do NOT trigger ==='
# Field false positive: the orchestrator quoted a worker's TUI-surface
# inventory, a single line carrying both `Type something.` and `Chat
# about this`. With no `Esc to cancel` footer it is quoted prose, not a
# live overlay — the guard must not fire even on the orchestrator.
setup_test
askuq_fp_prose_pane > "$PANES_DIR/orchestrator"
quiet_pane          > "$PANES_DIR/watcher"
WINDOWS_LIST=$'orchestrator\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_not_contains "no Case D on footerless two-literal prose" "$log_content" "case=D"
escape_count=$(grep -cE '^send-keys win=orchestrator args=Escape' <<<"$actions_content" || true)
assert_eq "orchestrator received zero Escape on footerless prose" "$escape_count" "0"
teardown_test

echo '=== Case D liveness: full overlay QUOTED in scrollback (footer not bottom-anchored) does NOT trigger ==='
# All literals present including the footer, but the live REPL chrome
# sits at the bottom — the orchestrator is discussing/echoing an
# overlay, not blocked on one. The bottom-anchored-footer gate must
# reject it. This is the field orchestrator false-positive shape.
setup_test
askuq_quoted_overlay_then_repl_pane > "$PANES_DIR/orchestrator"
quiet_pane                          > "$PANES_DIR/watcher"
WINDOWS_LIST=$'orchestrator\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_not_contains "no Case D on quoted overlay above REPL chrome" "$log_content" "case=D"
escape_count=$(grep -cE '^send-keys win=orchestrator args=Escape' <<<"$actions_content" || true)
assert_eq "orchestrator received zero Escape on quoted overlay" "$escape_count" "0"
teardown_test

echo '=== Case D ordering: permission prompt embedding "Chat about this" still fires Case A ==='
# Audit the original concern: Case A's chevron pattern overlaps with
# AskUQ overlays. On the in-scope (orchestrator) window the Case-D-
# before-A ordering must NOT regress Case A on a permission prompt that
# happens to contain one (but only one) of the AskUQ literals —
# `Chat about this` alone shouldn't promote a Case A prompt into Case D.
setup_test
permission_with_chat_prose_pane > "$PANES_DIR/orchestrator"
quiet_pane                      > "$PANES_DIR/watcher"
WINDOWS_LIST=$'orchestrator\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "Case A still fires for permission + 'chat about this' prose" "$log_content" "window=orchestrator case=A action=sent-Enter"
assert_not_contains "Case D does NOT fire (only one literal present)" "$log_content" "case=D"
enter_count=$(grep -cE '^send-keys win=orchestrator args=Enter' <<<"$actions_content" || true)
assert_eq "orchestrator received one Enter (Case A acted)" "$enter_count" "1"
escape_count=$(grep -cE '^send-keys win=orchestrator args=Escape' <<<"$actions_content" || true)
assert_eq "orchestrator received zero Escape" "$escape_count" "0"
teardown_test

# ---- Case W: worker-blocked-question relay ------------------------------
#
# A live AskUQ overlay on a NON-target window routes to the relay:
# never any keys to the pane; first-seen marker on first sighting; a
# synthesized pending-decision record (kind blocked_question) once the
# grace has elapsed with the overlay continuously observed. See the
# Case W narrative in _unstick.sh.

# Compute the fp the same way the implementation does, for state-file
# manipulation in the grace/backdating scenarios below.
_test_w_fp() { askuq_pane "${1:-How should we proceed with the migration?}" | _unstick_fingerprint_askuq; }

echo '=== Case W: first sighting records first-seen, no record, no keys ==='
setup_test
askuq_pane > "$PANES_DIR/some-worker"
quiet_pane > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'some-worker\norchestrator\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
W_FP=$(_test_w_fp)
assert_contains "first sighting logged" "$log_content" "window=some-worker case=W action=first-seen fp=$W_FP"
[[ -f "$UNSTICK_DIR/some-worker.worker-askuq.$W_FP.first-seen" ]] \
    && { echo "  PASS: first-seen marker written"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: first-seen marker missing" >&2; FAIL=$((FAIL+1)); }
assert_not_contains "no relay before grace" "$log_content" "action=relayed"
[[ ! -f "$WORK/decisions/some-worker.$W_FP.json" ]] \
    && { echo "  PASS: no decision record before grace"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: decision record written before grace" >&2; FAIL=$((FAIL+1)); }
worker_keys=$(grep -cE '^send-keys win=some-worker' <<<"$actions_content" || true)
assert_eq "worker received zero keys" "$worker_keys" "0"
teardown_test

echo '=== Case W: grace elapsed → decision record synthesized, still no keys ==='
setup_test
askuq_pane > "$PANES_DIR/some-worker"
quiet_pane > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'some-worker\norchestrator\nwatcher'
W_FP=$(_test_w_fp)
# Simulate a continuously-observed overlay whose episode began past the
# grace: content (first-seen anchor) is 400s old, mtime (last sighting)
# is fresh — the continuity probe must NOT re-arm.
printf '%s' "$(( $(date +%s) - 400 ))" > "$UNSTICK_DIR/some-worker.worker-askuq.$W_FP.first-seen"
touch "$UNSTICK_DIR/some-worker.worker-askuq.$W_FP.first-seen"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "relay logged" "$log_content" "window=some-worker case=W action=relayed fp=$W_FP"
DECISION="$WORK/decisions/some-worker.$W_FP.json"
[[ -f "$DECISION" ]] \
    && { echo "  PASS: decision record exists"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: decision record missing at $DECISION" >&2; FAIL=$((FAIL+1)); }
assert_eq "record kind"    "$(jq -r '.kind' "$DECISION" 2>/dev/null)"   "blocked_question"
assert_eq "record window"  "$(jq -r '.window' "$DECISION" 2>/dev/null)" "some-worker"
assert_eq "record fp"      "$(jq -r '.fingerprint' "$DECISION" 2>/dev/null)" "$W_FP"
assert_contains "excerpt carries the question" \
    "$(jq -r '.prompt_excerpt' "$DECISION" 2>/dev/null)" \
    "How should we proceed with the migration?"
assert_contains "excerpt carries the option list" \
    "$(jq -r '.prompt_excerpt' "$DECISION" 2>/dev/null)" \
    "1. Run the backfill in batches"
assert_contains "tool_context carries the pane tail" \
    "$(jq -r '.tool_context' "$DECISION" 2>/dev/null)" \
    "Esc to cancel"
worker_keys=$(grep -cE '^send-keys win=some-worker' <<<"$actions_content" || true)
assert_eq "worker received zero keys on relay" "$worker_keys" "0"

# Single-shot: a second scan with the record present must not duplicate.
detect_and_unstick
relay_count=$(grep -c 'case=W action=relayed' "$UNSTICK_LOG" || true)
assert_eq "relay is single-shot per (window, fp)" "$relay_count" "1"

# Ack-and-suppress: tombstone blocks re-relay even after rm.
mv "$DECISION" "$WORK/decisions/some-worker.$W_FP.handled.json"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_contains "tombstone honoured" "$log_content" "window=some-worker case=W action=skip-tombstone fp=$W_FP"
[[ ! -f "$DECISION" ]] \
    && { echo "  PASS: no re-write past tombstone"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: record re-written despite tombstone" >&2; FAIL=$((FAIL+1)); }
teardown_test

echo '=== Case W: sighting gap > 90s re-arms the episode (no relay) ==='
setup_test
askuq_pane > "$PANES_DIR/some-worker"
quiet_pane > "$PANES_DIR/orchestrator"
WINDOWS_LIST=$'some-worker\norchestrator'
W_FP=$(_test_w_fp)
# Episode began 400s ago BUT the last sighting was 200s ago — the
# overlay vanished (human answered) and a same-fp question reappeared.
marker="$UNSTICK_DIR/some-worker.worker-askuq.$W_FP.first-seen"
printf '%s' "$(( $(date +%s) - 400 ))" > "$marker"
touch -d "@$(( $(date +%s) - 200 ))" "$marker"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_contains "episode re-armed on sighting gap" "$log_content" "window=some-worker case=W action=re-armed fp=$W_FP"
assert_not_contains "no relay on re-arm" "$log_content" "action=relayed"
[[ ! -f "$WORK/decisions/some-worker.$W_FP.json" ]] \
    && { echo "  PASS: no decision record on re-arm"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: decision record written on re-arm" >&2; FAIL=$((FAIL+1)); }
teardown_test

echo '=== Case W: grace=0 disables the relay entirely ==='
setup_test
MONITOR_WORKER_ASKUQ_GRACE_SECONDS=0
export MONITOR_WORKER_ASKUQ_GRACE_SECONDS
askuq_pane > "$PANES_DIR/some-worker"
quiet_pane > "$PANES_DIR/orchestrator"
WINDOWS_LIST=$'some-worker\norchestrator'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_not_contains "no Case W activity when disabled" "$log_content" "case=W"
W_FP=$(_test_w_fp)
[[ ! -f "$UNSTICK_DIR/some-worker.worker-askuq.$W_FP.first-seen" ]] \
    && { echo "  PASS: no first-seen marker when disabled"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: marker written despite grace=0" >&2; FAIL=$((FAIL+1)); }
teardown_test

echo '=== Case W FP: quoted overlay on a worker window does NOT trigger ==='
# Same live-vs-quoted discrimination as Case D: a full overlay block
# quoted in a worker's scrollback with REPL chrome at the bottom is not
# a live dialog and must not start a relay episode.
setup_test
askuq_quoted_overlay_then_repl_pane > "$PANES_DIR/some-worker"
quiet_pane                          > "$PANES_DIR/orchestrator"
WINDOWS_LIST=$'some-worker\norchestrator'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_not_contains "no Case W on quoted overlay" "$log_content" "case=W"
teardown_test

echo '=== Case W scope: TARGET window still takes Case D, never the relay ==='
setup_test
askuq_pane > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'orchestrator\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_contains "orchestrator routed to Case D" "$log_content" "window=orchestrator case=D action=dismissed-and-pasted"
assert_not_contains "orchestrator never relayed" "$log_content" "case=W"
W_FP=$(_test_w_fp)
[[ ! -f "$WORK/decisions/orchestrator.$W_FP.json" ]] \
    && { echo "  PASS: no decision record for orchestrator"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: relay record written for orchestrator" >&2; FAIL=$((FAIL+1)); }
teardown_test

# ---- Summary -----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
