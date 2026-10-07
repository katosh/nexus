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
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
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
            # Record the RAW target before normalising: the pane file is keyed by
            # the bare name, so the lookup alone cannot tell `:=<name>` (tmux's
            # EXACT-window spelling, #1524) from the bare name tmux resolves by
            # unique PREFIX. The `capture-pane target=` rows assert on this.
            [[ -n "$WORK" && -d "$WORK" ]] && printf 'capture-pane target=%s\n' "$target" >> "$WORK/captures.log"
            target="${target#:=}"
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
            # A LIVE rate-limit menu takes the Enter (your-org/nexus-code#1739:
            # the cascade now VERIFIES the dismissal before it pastes). Unless
            # the test planted `<win>.sticky` (a menu that ignores the Enter),
            # the pane becomes `<win>.after` if planted, else a quiet REPL; a
            # planted `$PSTATE_DIR/<win>.after` replaces the fake pane-state row.
            local _w="${target#:=}"
            if [[ " ${rest} " == *" Enter "* && -n "$PANES_DIR" && -f "$PANES_DIR/$_w" && ! -e "$PANES_DIR/$_w.sticky" ]] \
                && grep -qF 'Stop and wait for limit' "$PANES_DIR/$_w" \
                && [[ "$(_unstick_ratelimit_menu_verdict < "$PANES_DIR/$_w")" == *-highlighted ]]; then
                if [[ -f "$PANES_DIR/$_w.after" ]]; then mv "$PANES_DIR/$_w.after" "$PANES_DIR/$_w"
                else printf '%s\n' '● Stopped.' '' '───' "❯ " '───' > "$PANES_DIR/$_w"; fi
                if [[ -n "${PSTATE_DIR:-}" && -f "$PSTATE_DIR/$_w.after" ]]; then
                    mv "$PSTATE_DIR/$_w.after" "$PSTATE_DIR/$_w"
                fi
            fi
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
    ON_DIALOG="auto-dismiss"
    # Case W (worker-blocked-question relay) state. STATE_DIR roots the
    # decisions dir exactly as in production (where
    # UNSTICK_DIR=$STATE_DIR/unstick); the grace default matches
    # production so pre-grace tests are honest.
    STATE_DIR="$WORK"
    # The credential sensor (#1739) reads Claude Code's config + credential
    # store; aim it at per-test paths so no row ever reads the operator's.
    UNSTICK_CRED_ACCOUNT_FILE="$WORK/cred/claude.json"
    UNSTICK_CRED_STORE_FILE="$WORK/cred/credentials.json"
    UNSTICK_DISMISS_VERIFY_S="1"
    PSTATE_DIR=""
    MONITOR_WORKER_ASKUQ_GRACE_SECONDS="300"
    export AUTO_UNSTICK WATCHER_WINDOW TARGET UNSTICK_DIR UNSTICK_LOG \
           ACTION_LOG RATELIMIT_PROBE RATELIMIT_HEURISTIC_MIN \
           RATELIMIT_ACK_TIMEOUT_S PROBE_MODEL \
           ON_DIALOG STATE_DIR MONITOR_WORKER_ASKUQ_GRACE_SECONDS \
           UNSTICK_CRED_ACCOUNT_FILE UNSTICK_CRED_STORE_FILE UNSTICK_DISMISS_VERIFY_S
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

# The PRE-2.1.280 synthetic API-error chip the retired Case C keyed on
# (your-org/nexus-code#1670). No real-binary capture of it exists in the repo.
api_error_pane() {
    local rid="${1:-req_011XYZ}"
    cat <<EOF
⏺ Do something.
  ⎿  API Error: {"type":"error","error":{"details":null,"type":"api_error","message":"Internal server error"},"request_id":"${rid}"}
EOF
}

# Pane that mentions "API Error" in passing — conversation prose.
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
assert_contains "case A detects perm-win (refused, not answered)" "$log_content" "window=perm-win case=A action=refused"
assert_not_contains "watcher window untouched"        "$log_content" "window=watcher"
assert_not_contains "quiet window untouched"          "$log_content" "window=quiet-win"
teardown_test

# ---- Case A (#1599): detected, NEVER answered ----------------------------
#
# The shape that was confirmed in window `rtev` on 2026-09-19 (Claude Code
# 2.1.273): the danger line, title, a TWO-option menu with Yes highlighted, and
# the footer. Every visible row of the modal is as the audit captured it; the
# tool-call rows above are generic.
dangerous_rm_pane() {
    local var="${1:-\"\$M/\$tag-work\"}"
    cat <<EOF
  │ run E3c "\$W/wt-base"
  │ cat "\$M/E3-chain2.log"
  Re-run potency experiments E3b and E3c at the verified line

 Dangerous rm operation on possibly-empty variable path: $var

 Do you want to proceed?
 ❯ 1. Yes
   2. No

 Esc to cancel · Tab to amend
EOF
}
_a_rec() { # <window> → the one case-A decision record for it, or empty
    local f
    for f in "$WORK/decisions/$1".*.json; do
        [[ -f "$f" && "$f" != *.handled.json ]] || continue
        printf '%s' "$f"; return 0
    done
}

echo '=== Case A (#1599): a DANGER-marked prompt gets no key, one log line, one decision record ==='
setup_test
dangerous_rm_pane > "$PANES_DIR/rtev"
quiet_pane        > "$PANES_DIR/watcher"
WINDOWS_LIST=$'rtev\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_eq "A1599-danger.nokeys: zero send-keys into a danger-marked prompt" \
    "$(grep -cE '^send-keys win=(:=)?rtev ' "$ACTIONS" || true)" "0"
assert_contains "A1599-danger.verdict: refusal names the verdict" "$log_content" "window=rtev case=A action=refused verdict=danger"
assert_contains "A1599-danger.marker: refusal names the marker" "$log_content" 'marker="Dangerous rm operation on possibly-empty variable path'
rec=$(_a_rec rtev)
assert_eq "A1599-danger.record.kind: surfaced as a permission_prompt decision" \
    "$(jq -r '.kind' "$rec" 2>/dev/null)" "permission_prompt"
assert_eq "A1599-danger.record.verdict: the record carries the verdict" \
    "$(jq -r '.verdict + "/" + .source' "$rec" 2>/dev/null)" "danger/watcher-unstick-case-A"
assert_contains "A1599-danger.record.excerpt: row line 1 leads with the REFUSAL" \
    "$(jq -r '.prompt_excerpt' "$rec" 2>/dev/null | sed -n 1p)" "Watcher REFUSED to answer a permission prompt (danger marker: Dangerous rm operation"
# Second cycle on the byte-identical prompt: still no key, no second log line,
# no second record.
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_eq "A1599-danger.repeat.nokeys: zero send-keys after a second cycle" \
    "$(grep -cE '^send-keys win=(:=)?rtev ' "$ACTIONS" || true)" "0"
assert_eq "A1599-danger.repeat.onelog: ONE refused line per prompt instance" \
    "$(grep -cF 'window=rtev case=A action=refused' <<<"$log_content" || true)" "1"
assert_eq "A1599-danger.repeat.onerecord: ONE record per prompt instance" \
    "$(bash -c 'n=0; for f in "$1"/decisions/rtev.*.json; do [[ -f "$f" ]] && n=$((n+1)); done; echo $n' _ "$WORK")" "1"
teardown_test

echo '=== Case A (#1599): an UNMARKED legacy prompt is refused too — the allowlist is EMPTY ==='
setup_test
permission_pane > "$PANES_DIR/perm-win"
quiet_pane      > "$PANES_DIR/watcher"
WINDOWS_LIST=$'perm-win\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_eq "A1599-unlisted.nokeys: zero send-keys into an unmarked prompt" \
    "$(grep -cE '^send-keys win=(:=)?perm-win ' "$ACTIONS" || true)" "0"
assert_contains "A1599-unlisted.verdict: refused as unlisted" "$log_content" "window=perm-win case=A action=refused verdict=unlisted"
assert_eq "A1599-unlisted.record: surfaced as a decision" \
    "$(jq -r '.kind + "/" + .verdict' "$(_a_rec perm-win)" 2>/dev/null)" "permission_prompt/unlisted"
teardown_test

echo '=== Case A (#1599): two DIFFERENT prompts in one window are two decisions, not one fp ==='
# The old fingerprint hashed only the title + option rows, identical across every
# two-option prompt (ca80bcd97f11 in 30+ audits) — as a record key, acking one
# prompt would mute every later one in the window.
setup_test
dangerous_rm_pane '"$A/$b"' > "$PANES_DIR/w2"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'w2\nwatcher'
detect_and_unstick
dangerous_rm_pane '"$C/$d"' > "$PANES_DIR/w2"
detect_and_unstick
assert_eq "A1599-fp.distinct: two prompts → two decision records" \
    "$(bash -c 'n=0; for f in "$1"/decisions/w2.*.json; do [[ -f "$f" ]] && n=$((n+1)); done; echo $n' _ "$WORK")" "2"
teardown_test

echo '=== Case A (#1599): a tombstoned prompt is not re-surfaced; a RESOLVED one is (must NOT flip) ==='
setup_test
dangerous_rm_pane > "$PANES_DIR/rtev"
quiet_pane        > "$PANES_DIR/watcher"
WINDOWS_LIST=$'rtev\nwatcher'
detect_and_unstick
rec=$(_a_rec rtev)
[[ -n "$rec" ]] && mv "$rec" "${rec%.json}.handled.json"
detect_and_unstick
assert_eq "A1599-tomb.muted: a tombstone suppresses the record" "$(_a_rec rtev)" ""
rm -f "$WORK"/decisions/rtev.*
detect_and_unstick
rec=$(_a_rec rtev)
# Guarded: with no record (the pre-fix arm) an unguarded `> "$rec.t"` writes a
# stray `.t` into the CWD — the tree under test.
[[ -n "$rec" ]] && jq -c '. + {resolved: true}' "$rec" > "$rec.t" && mv "$rec.t" "$rec"
detect_and_unstick
assert_eq "A1599-resolved.rewritten: the same prompt on screen again is pending again" \
    "$(jq -r 'if .resolved == true then "resolved" else "pending" end' "$(_a_rec rtev)" 2>/dev/null)" "pending"
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
# The paste targets the EXACT name `:=<window>` (your-org/nexus-code#1524): this
# stub's `list-windows` answers bare names whatever format is asked, so
# `resolve_window_id` cannot produce an @id and the primitive's caller falls
# back to `:=`, never to the bare name tmux would resolve by unique PREFIX.
agent1_sk=$(grep -cE '^send-keys win=(:=)?agent-1' <<<"$actions_content" || true)
agent2_sk=$(grep -cE '^send-keys win=(:=)?agent-2' <<<"$actions_content" || true)
agent1_paste=$(grep -cE '^paste-buffer buf=.* target=:=agent-1' <<<"$actions_content" || true)
agent2_paste=$(grep -cE '^paste-buffer buf=.* target=:=agent-2' <<<"$actions_content" || true)
orch_paste=$(grep -cE '^paste-buffer buf=.* target=:=orchestrator'  <<<"$actions_content" || true)
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
agent_sk=$(grep -cE '^send-keys win=(:=)?agent-1' <<<"$actions_content" || true)
assert_eq "agent-1 received zero send-keys (still waiting)" "$agent_sk" "0"
[[ -f "$UNSTICK_DIR/ratelimit.reset.epoch" ]] \
    && { echo "  PASS: reset marker preserved while waiting"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: reset marker should still exist while waiting" >&2; FAIL=$((FAIL+1)); }
teardown_test

# ---- Case B: the Enter is an EQUALITY (your-org/nexus-code#1598) ----------
#
# Row ids (B98-*) are the ones the prediction file named BEFORE these rows or
# the fix existed; the base verdict of each is recorded on the PR.
#
# WHAT THE MENU'S ENTER SELECTS IS UPSTREAM'S TO DECIDE. Read out of the 2.1.273
# bundle, the option list is
#     Vo ? [...billing, stop, ...rest] : [stop, ...rest, ...billing]
# with `Vo = P("tengu_jade_anvil_4", !1)` — a server-side flag, client default
# false. With it on, the HIGHLIGHTED row is `Upgrade your plan` or a
# usage-credits action, and an Enter selects THAT.
#
# FIDELITY, stated: the option ORDER is cited from the bundle. The RENDERED
# shape of the live menu is a MODEL (the synthetic fixture plus the real
# permission-prompt captures of the same Select component); nobody can produce
# a rate-limited account on demand. A wrong model fails toward NO ENTER.

# Live menu with the 2.1.273 flag-on order: a billing action is highlighted.
ratelimit_flag_on_pane() {
    cat <<'EOF'
You've hit the limit.

What do you want to do?
❯ 1. Upgrade your plan
  2. Stop and wait for limit to reset
  3. Add funds to continue with usage credits
EOF
}

# A per-window pane-state stand-in, named EXPLICITLY through PD_PANE_STATE_BIN —
# which is what pd_pane_verdict requires of a rig whose `tmux` is a function.
install_fake_pane_state() {
    PSTATE_DIR="$WORK/pstate"; mkdir -p "$PSTATE_DIR"
    cat > "$WORK/fake-pane-state.sh" <<FPS
#!/bin/bash
f="$PSTATE_DIR/\${1#:=}"
[[ -f "\$f" ]] && cat "\$f" || echo "state=idle active=0 input=blank"
FPS
    chmod +x "$WORK/fake-pane-state.sh"
    export PD_PANE_STATE_BIN="$WORK/fake-pane-state.sh"
    # CHOSEN for suite speed, not measured: one short window, no retries. These
    # rows assert WHICH keys are sent, not how long a confirm window lasts.
    export PD_CONFIRM_WINDOWS="0.5" PD_POLL_SECONDS="0.1" PD_HELD_CHECK_SECONDS="0.2"
}
uninstall_fake_pane_state() { unset PD_PANE_STATE_BIN PD_CONFIRM_WINDOWS PD_POLL_SECONDS PD_HELD_CHECK_SECONDS; }

# Count send-keys lines into <window>, under EITHER spelling of the target.
sk_count() { # <window> [<args-regex>]
    local n
    n=$(grep -cE "^send-keys win=(:=)?$1 args=${2:-.*}\$" "$ACTIONS" || true)
    printf '%s' "${n:-0}"
}

echo '=== Case B (#1598): live menu, Stop highlighted — dismissed, on the EXACT target ==='
setup_test; install_fake_pane_state
ratelimit_pane > "$PANES_DIR/agent-1"
quiet_pane     > "$PANES_DIR/orchestrator"
quiet_pane     > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-1\norchestrator\nwatcher'
echo $(( $(date +%s) - 5 )) > "$UNSTICK_DIR/ratelimit.reset.epoch"
detect_and_unstick
assert_eq "B98-live.count: agent-1 got exactly 2 Enters (dismiss + submit)" "$(sk_count agent-1 Enter)" "2"
bare_enter=$(grep -cE '^send-keys win=agent-1 args=Enter$' "$ACTIONS" || true)
assert_eq "B98-live.exact: no Enter went to the BARE name (#1524)" "$bare_enter" "0"
assert_eq "B98-orchquiet.noenter: a quiet orchestrator gets exactly 1 Enter (the submit), no pre-Enter" \
    "$(sk_count orchestrator Enter)" "1"
teardown_test; uninstall_fake_pane_state

echo '=== Case B (#1598): a pane QUOTING the menu is not a rate-limited pane (real capture) ==='
# monitor/watcher/fixtures/ratelimit-quoted-realpane-273.txt is the watcher's own
# pre-action audit capture of window `pastefu`, 2026-09-19 15:36:43 PDT, Claude
# Code 2.1.273: a BUSY agent whose tool call quoted both literals, idle REPL row
# beneath. The live watcher pressed Enter into it and into the orchestrator.
# Only the operator's path prefix is redacted; every other byte is as captured.
setup_test; install_fake_pane_state
cat "$_test_dir/fixtures/ratelimit-quoted-realpane-273.txt" > "$PANES_DIR/agent-q"
quiet_pane > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-q\norchestrator\nwatcher'
echo $(( $(date +%s) - 5 )) > "$UNSTICK_DIR/ratelimit.reset.epoch"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_not_contains "B98-quoted.nodetect: no case-B detection" "$log_content" "window=agent-q case=B action=detected"
assert_eq "B98-quoted.nokeys: zero send-keys into the quoting pane" "$(sk_count agent-q)" "0"
orch_paste=$(grep -cE '^paste-buffer buf=.* target=:=orchestrator' "$ACTIONS" || true)
assert_eq "B98-quoted.noheadsup: no heads-up pasted" "$orch_paste" "0"
teardown_test; uninstall_fake_pane_state

echo '=== Case B (#1598): a FULL menu quoted into scrollback, REPL chrome beneath — not live ==='
# The harder shape, and the one the real capture above does NOT exercise (it has
# no highlighted row at all): an agent displaying this very suite's fixture. The
# highlighted Stop row is there; what says "not live" is the input row below it.
setup_test; install_fake_pane_state
{
    printf '%s\n' '● Here is the fixture the cascade keys on:' ''
    ratelimit_pane | sed 's/^/  /'
    printf '%s\n' '' '● Continuing.' '' '──────────────────────────────'
    printf '\342\235\257\302\240\n'
    printf '%s\n' '──────────────────────────────' '  ◉ model │ 285K/1.0M' '  -- INSERT -- ⏵⏵ bypass permissions on'
} > "$PANES_DIR/agent-qf"
quiet_pane > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-qf\norchestrator\nwatcher'
echo $(( $(date +%s) - 5 )) > "$UNSTICK_DIR/ratelimit.reset.epoch"
detect_and_unstick
assert_eq "B98-quotedfull.nokeys: zero send-keys into a pane quoting the WHOLE menu" "$(sk_count agent-qf)" "0"
teardown_test; uninstall_fake_pane_state

echo '=== Case B (#1598 / skeptic F3): a quoted menu whose REPL row is INDENTED is still quoted ==='
# THE SAFE-SIDE ARM MUST NOT BE WIDER THAN THE HAZARD-SIDE ARM (#1121). The
# option-row arm tolerates leading whitespace; the REPL-row arm demanded the
# glyph at COLUMN 1, so a REPL input row indented by even one space matched
# NEITHER, the scan ran past it, and a quoted menu read `stop-highlighted` — a
# wrong Enter, which is precisely what this verdict promises never to produce.
setup_test; install_fake_pane_state
{
    printf '%s\n' '● Here is the fixture the cascade keys on:' ''
    ratelimit_pane | sed 's/^/  /'
    printf '%s\n' '' '● Continuing.' '' ' ──────────────────────────────'
    printf ' \342\235\257\302\240\n'
    printf '%s\n' ' ──────────────────────────────' '  ◉ model │ 285K/1.0M'
} > "$PANES_DIR/agent-qi"
quiet_pane > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-qi\norchestrator\nwatcher'
echo $(( $(date +%s) - 5 )) > "$UNSTICK_DIR/ratelimit.reset.epoch"
detect_and_unstick
assert_eq "B98-quotedindent.nokeys: an INDENTED REPL row still marks the menu quoted" "$(sk_count agent-qi)" "0"
teardown_test; uninstall_fake_pane_state

echo '=== Case B (#1598): live menu, a BILLING action highlighted — detected, never Entered ==='
setup_test; install_fake_pane_state
ratelimit_flag_on_pane > "$PANES_DIR/agent-f"
quiet_pane > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-f\norchestrator\nwatcher'
echo $(( $(date +%s) - 5 )) > "$UNSTICK_DIR/ratelimit.reset.epoch"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_eq "B98-flag.noenter: zero Enter into a menu whose default is not Stop" "$(sk_count agent-f Enter)" "0"
assert_contains "B98-flag.logged: the refusal is recorded" "$log_content" "window=agent-f case=B action=cascade-refused reason=other-highlighted"
assert_contains "B98-flag.detected: it IS still a rate-limited pane" "$log_content" "window=agent-f case=B action=detected"
teardown_test; uninstall_fake_pane_state

echo '=== Case B (#1598): an operator draft in the orchestrator box — no key, no paste, retried later ==='
setup_test; install_fake_pane_state
ratelimit_pane > "$PANES_DIR/agent-1"
quiet_pane     > "$PANES_DIR/orchestrator"
quiet_pane     > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-1\norchestrator\nwatcher'
echo 'state=user-typing active=0 input=typed' > "$PSTATE_DIR/orchestrator"
echo $(( $(date +%s) - 5 )) > "$UNSTICK_DIR/ratelimit.reset.epoch"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_eq "B98-orchdraft.nokeys: zero send-keys into the drafting orchestrator" "$(sk_count orchestrator)" "0"
orch_paste=$(grep -cE '^paste-buffer buf=.* target=:=orchestrator' "$ACTIONS" || true)
assert_eq "B98-orchdraft.nopaste: zero paste into the drafting orchestrator" "$orch_paste" "0"
if [[ -f "$UNSTICK_DIR/ratelimit.headsup.pending" ]] && grep -qF 'case=B action=heads-up-deferred' <<<"$log_content"; then
    echo "  PASS: B98-orchdraft.pending: heads-up deferred and recorded"; PASS=$((PASS+1))
else
    echo "  FAIL: B98-orchdraft.pending: no pending marker / no heads-up-deferred line" >&2; FAIL=$((FAIL+1))
fi
# Next cycle: the operator has submitted; agent-1 is past its menu.
rm -f "$PSTATE_DIR/orchestrator"
quiet_pane > "$PANES_DIR/agent-1"
: > "$ACTIONS"
detect_and_unstick
orch_paste=$(grep -cE '^paste-buffer buf=.* target=:=orchestrator' "$ACTIONS" || true)
if [[ "$orch_paste" == 1 && ! -f "$UNSTICK_DIR/ratelimit.headsup.pending" && -f "$UNSTICK_DIR/ratelimit.cascade.epoch" ]]; then
    echo "  PASS: B98-orchdraft.retry: delivered once, pending cleared, cascade marker written"; PASS=$((PASS+1))
else
    echo "  FAIL: B98-orchdraft.retry: paste=$orch_paste pending=$([[ -f "$UNSTICK_DIR/ratelimit.headsup.pending" ]] && echo yes || echo no) marker=$([[ -f "$UNSTICK_DIR/ratelimit.cascade.epoch" ]] && echo yes || echo no)" >&2; FAIL=$((FAIL+1))
fi
teardown_test; uninstall_fake_pane_state

echo '=== Case B (#1598): the orchestrator itself on the live menu — dismissed on the EXACT target ==='
setup_test; install_fake_pane_state
ratelimit_pane > "$PANES_DIR/orchestrator"
quiet_pane     > "$PANES_DIR/watcher"
WINDOWS_LIST=$'orchestrator\nwatcher'
echo $(( $(date +%s) - 5 )) > "$UNSTICK_DIR/ratelimit.reset.epoch"
detect_and_unstick
exact_enter=$(grep -cE '^send-keys win=:=orchestrator args=Enter$' "$ACTIONS" || true)
bare_enter=$(grep -cE '^send-keys win=orchestrator args=Enter$' "$ACTIONS" || true)
assert_eq "B98-orchmenu.exact: dismiss+submit Enters on :=orchestrator, none on the bare name" "$exact_enter/$bare_enter" "2/0"
teardown_test; uninstall_fake_pane_state

echo '=== Case B (#1598): an ELAPSED reset epoch with nobody stuck is a finished episode ==='
setup_test; install_fake_pane_state
quiet_pane > "$PANES_DIR/agent-1"
quiet_pane > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-1\norchestrator\nwatcher'
echo $(( $(date +%s) - 3600 )) > "$UNSTICK_DIR/ratelimit.reset.epoch"
detect_and_unstick
[[ ! -f "$UNSTICK_DIR/ratelimit.reset.epoch" ]] \
    && { echo "  PASS: B98-stale.cleared: elapsed epoch removed"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: B98-stale.cleared: elapsed epoch still on disk" >&2; FAIL=$((FAIL+1)); }
ratelimit_pane > "$PANES_DIR/agent-1"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
if grep -qF 'case=B action=schedule-cascade' <<<"$log_content" && ! grep -qF 'cascade-resumed' <<<"$log_content"; then
    echo "  PASS: B98-stale.nocascade: a NEW episode is scheduled, not cascaded on a stale clock"; PASS=$((PASS+1))
else
    echo "  FAIL: B98-stale.nocascade: new episode cascaded immediately" >&2; FAIL=$((FAIL+1))
fi
teardown_test; uninstall_fake_pane_state

echo '=== Case B (#1598): a FUTURE reset epoch survives a cycle with nobody stuck (must NOT flip) ==='
setup_test; install_fake_pane_state
quiet_pane > "$PANES_DIR/agent-1"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-1\nwatcher'
echo $(( $(date +%s) + 3600 )) > "$UNSTICK_DIR/ratelimit.reset.epoch"
detect_and_unstick
[[ -f "$UNSTICK_DIR/ratelimit.reset.epoch" ]] \
    && { echo "  PASS: B98-future.kept: a future epoch is kept"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: B98-future.kept: a future epoch was removed" >&2; FAIL=$((FAIL+1)); }
teardown_test; uninstall_fake_pane_state

# ---- Case B heads-up ABANDON branches (your-org/nexus-code#1621) ----------
#
# `_retry_pending_heads_up` has two abandon exits, and BOTH deliberately do NOT
# write `ratelimit.cascade.epoch`: that marker starts the ACK clock, and on an
# abandoned heads-up the orchestrator was never told anything, so
# `orchestrator-unresponsive` would be a false attribution (see the function's
# header). These rows pin that, with the ack timeout at 0 so an ack clock, had
# one been started, would expire in the very next cycle.
b21_pend() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$UNSTICK_DIR/ratelimit.headsup.pending"; }
b21_n() { local n; n=$(grep -cE -- "$1" "$2" 2>/dev/null || true); printf '%s' "${n:-0}"; }
b21_board() { # agent-1 <pane-fn>, the rest quiet
    "$1"       > "$PANES_DIR/agent-1"
    quiet_pane > "$PANES_DIR/agent-2"
    quiet_pane > "$PANES_DIR/orchestrator"
    quiet_pane > "$PANES_DIR/watcher"
    WINDOWS_LIST=$'agent-1\nagent-2\norchestrator\nwatcher'
}

echo '=== Case B (#1621): malformed pending → abandoned, NO ack clock, NO orchestrator-unresponsive ==='
setup_test; install_fake_pane_state; b21_board quiet_pane
RATELIMIT_ACK_TIMEOUT_S=0
# Malformed in the COUNT field, with a valid fresh epoch: a mutant that falls
# through the malformed exit then runs on to a delivery (and is caught by the
# rows below) instead of dying on `set -u` arithmetic over a non-numeric epoch,
# which reads as an unattributable crash rather than a named flip.
printf '%s\tx\tagent-1\n' "$(date +%s)" > "$UNSTICK_DIR/ratelimit.headsup.pending"
detect_and_unstick
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_contains "B1621-malformed.logged: abandoned with its reason" "$log_content" "case=B action=heads-up-abandoned reason=malformed-pending"
assert_eq "B1621-malformed.state: pending removed, NO cascade marker" \
    "$([[ -f "$UNSTICK_DIR/ratelimit.headsup.pending" ]] && echo P || echo -)$([[ -f "$UNSTICK_DIR/ratelimit.cascade.epoch" ]] && echo M || echo -)" "--"
assert_not_contains "B1621-malformed.nounresponsive: the orchestrator is not blamed" "$log_content" "case=B action=orchestrator-unresponsive"
assert_eq "B1621-malformed.nopaste: nothing pasted into the orchestrator" \
    "$(b21_n '^paste-buffer .*target=:=orchestrator$' "$ACTIONS")" "0"
RATELIMIT_ACK_TIMEOUT_S=60
teardown_test; uninstall_fake_pane_state

echo '=== Case B (#1621): pending older than RATELIMIT_HEADSUP_DEFER_MAX_S → abandoned, NO ack clock ==='
setup_test; install_fake_pane_state; b21_board quiet_pane
RATELIMIT_ACK_TIMEOUT_S=0 RATELIMIT_HEADSUP_DEFER_MAX_S=60
b21_pend "$(( $(date +%s) - 61 ))" 2 "agent-1 agent-2"
detect_and_unstick
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_contains "B1621-toolong.logged: abandoned with age and ceiling" "$log_content" "case=B action=heads-up-abandoned reason=deferred-too-long"
assert_contains "B1621-toolong.ceiling: the configured ceiling is honoured" "$log_content" "max_s=60 n=2 windows=agent-1 agent-2"
assert_eq "B1621-toolong.state: pending removed, NO cascade marker" \
    "$([[ -f "$UNSTICK_DIR/ratelimit.headsup.pending" ]] && echo P || echo -)$([[ -f "$UNSTICK_DIR/ratelimit.cascade.epoch" ]] && echo M || echo -)" "--"
assert_not_contains "B1621-toolong.nounresponsive: the orchestrator is not blamed" "$log_content" "case=B action=orchestrator-unresponsive"
assert_eq "B1621-toolong.nopaste: nothing pasted into the orchestrator" \
    "$(b21_n '^paste-buffer .*target=:=orchestrator$' "$ACTIONS")" "0"
unset RATELIMIT_HEADSUP_DEFER_MAX_S; RATELIMIT_ACK_TIMEOUT_S=60
teardown_test; uninstall_fake_pane_state

echo '=== Case B (#1621): a YOUNG pending behind a draft stays parked (must NOT flip) ==='
setup_test; install_fake_pane_state; b21_board quiet_pane
echo 'state=user-typing active=0 input=typed' > "$PSTATE_DIR/orchestrator"
b21_pend "$(( $(date +%s) - 30 ))" 1 "agent-1"
detect_and_unstick
assert_not_contains "B1621-young.noabandon: no abandon under the ceiling" "$(<"$UNSTICK_LOG")" "heads-up-abandoned"
assert_eq "B1621-young.parked: still pending, no marker" \
    "$([[ -f "$UNSTICK_DIR/ratelimit.headsup.pending" ]] && echo P || echo -)$([[ -f "$UNSTICK_DIR/ratelimit.cascade.epoch" ]] && echo M || echo -)" "P-"
teardown_test; uninstall_fake_pane_state

# THE DOUBLE-FIRE WINDOW, MEASURED (#1621 §2). The abandon branches leave the
# `cascade.epoch` gate open, and so does the whole deferral. What that gate
# guards against is a SECOND cascade re-pasting "the rate limit has reset" into
# panes that already got it, or a second heads-up. Three arms, per-window paste
# counts. The finding they pin: the open gate does NOT double-fire, because two
# OTHER conditions hold independently of the marker —
#   (1) `cascade-complete` deletes the reset epoch, so a second episode must
#       schedule a fresh one (heuristic ≥ RATELIMIT_HEURISTIC_MIN) and cannot
#       cascade in the cycle that follows an abandon;
#   (2) every per-window paste is gated on a LIVE, Stop-highlighted menu read at
#       that moment (#1598), so a pane already resumed gets nothing whatever the
#       gate says; a pane that is on the menu AGAIN is a new stuck episode, and
#       one paste to it is correct;
# and `_retry_pending_heads_up` runs BEFORE the scan, so a heads-up delivered in
# a cycle writes the marker before any second cascade in that cycle can fire.

echo '=== Case B (#1621) double-fire arm 1: abandon + a second episode in the SAME cycle, production state ==='
setup_test; install_fake_pane_state; b21_board ratelimit_pane
b21_pend "$(( $(date +%s) - 901 ))" 2 "agent-1 agent-2"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_contains "B1621-df1.abandoned: the parked heads-up is abandoned" "$log_content" "reason=deferred-too-long"
assert_eq "B1621-df1.nocascade: no cascade in the abandon cycle — a fresh reset is SCHEDULED" \
    "$(b21_n 'case=B action=cascade-resumed' "$UNSTICK_LOG")/$(b21_n 'case=B action=schedule-cascade' "$UNSTICK_LOG")" "0/1"
assert_eq "B1621-df1.nopaste: zero pastes to any window" "$(b21_n '^paste-buffer ' "$ACTIONS")" "0"
teardown_test; uninstall_fake_pane_state

echo '=== Case B (#1621) double-fire arm 2: abandon + a second episode whose reset has ALREADY elapsed ==='
setup_test; install_fake_pane_state; b21_board ratelimit_pane
b21_pend "$(( $(date +%s) - 901 ))" 2 "agent-1 agent-2"
echo $(( $(date +%s) - 5 )) > "$UNSTICK_DIR/ratelimit.reset.epoch"
detect_and_unstick
detect_and_unstick
assert_eq "B1621-df2.onecascade: exactly ONE cascade across two cycles" "$(b21_n 'case=B action=cascade-complete' "$UNSTICK_LOG")" "1"
assert_eq "B1621-df2.pastes: agent-1 (on the menu) 1, agent-2 (already resumed) 0, orchestrator 1" \
    "$(b21_n '^paste-buffer .*target=:=agent-1$' "$ACTIONS")/$(b21_n '^paste-buffer .*target=:=agent-2$' "$ACTIONS")/$(b21_n '^paste-buffer .*target=:=orchestrator$' "$ACTIONS")" "1/0/1"
teardown_test; uninstall_fake_pane_state

echo '=== Case B (#1621) double-fire arm 3: a second episode DURING the deferral, then the draft clears ==='
setup_test; install_fake_pane_state; b21_board ratelimit_pane
echo 'state=user-typing active=0 input=typed' > "$PSTATE_DIR/orchestrator"
b21_pend "$(( $(date +%s) - 100 ))" 2 "agent-1 agent-2"
echo $(( $(date +%s) - 5 )) > "$UNSTICK_DIR/ratelimit.reset.epoch"
detect_and_unstick
rm -f "$PSTATE_DIR/orchestrator"; quiet_pane > "$PANES_DIR/agent-1"
detect_and_unstick
detect_and_unstick
assert_eq "B1621-df3.pastes: agent-1 1, agent-2 0, orchestrator heads-up exactly 1 over three cycles" \
    "$(b21_n '^paste-buffer .*target=:=agent-1$' "$ACTIONS")/$(b21_n '^paste-buffer .*target=:=agent-2$' "$ACTIONS")/$(b21_n '^paste-buffer .*target=:=orchestrator$' "$ACTIONS")" "1/0/1"
teardown_test; uninstall_fake_pane_state

# ---- Case A FIRST: no key-sending arm may claim a live permission prompt ----
#
# Skeptic pass on your-org/nexus-code#1626, finding 1: the arms test PRESENCE in
# a 25-line capture, so any arm checked before Case A claimed a pane whose LIVE
# prompt sat below text that also matched it — C pressed Enter (= `❯ 1. Yes`), B's
# cascade pressed Enter, D sent Escape + a paste. Every row below is built on a
# REAL case-A danger audit, `.state/unstick/rtev.permission.ca80bcd97f11.audit`
# (window `rtev`, 2026-09-19 16:00, Claude Code 2.1.273 — the prompt #1599 names),
# rows 22..49 byte-for-byte except two operator path prefixes, redacted.
# Row ids are the ones the prediction file named BEFORE the fix existed.
rtev_audit_capture() {
    cat <<'CAP'
 Bash command

   │ S="/tmp/REDACTED";
   │ W=/REDACTED/work; M="$S/m1570"; L=$(cat "$M/E3-trline.txt")
   │ echo "RE-RUN of E3b/E3c at line $L (first attempt REFUSED: wrong line 2270, my error). Predictions UNCHANGED from the registered E3b/E3c files.
   │ $(date -Is)" >> "$M/E3-prediction.README"
   │ run() { local tag="$1" wt="$2" rc
   │   cd "$wt" || { echo "$tag: cd failed" >> "$M/E3-chain2.log"; return; }
   │   rm -rf "$M/$tag-work"
   │   bash monitor/mutation-gate.sh --suite monitor/watcher/test-cc-auto-update.sh --subject monitor/cc-auto-update-apply.sh --line "$L" --mode subst
   │ --from "tr -dc '0-9'" --to "tr -c '0-9' 0" --predict "$M/$tag-prediction.txt" --record "$M/$tag-record.tsv" --timeout 900 --workdir "$M/$tag-work"
   │ > "$M/$tag.out" 2> "$M/$tag.err"
   │   rc=$?
   │   printf '%s rc=%s tree=%s at %s\n' "$tag" "$rc" "$(git rev-parse --short HEAD)" "$(date -Is)" >> "$M/E3-chain2.log"
   │ }
   │ : > "$M/E3-chain2.log"
   │ run E3b "$W/nexus-code-rtev.wt-fix"
   │ run E3c "$W/nexus-code-rtev.wt-base"
   │ cat "$M/E3-chain2.log"
   Re-run potency experiments E3b and E3c at the verified line

 Dangerous rm operation on possibly-empty variable path: "$M/$tag-work"

 Do you want to proceed?
 ❯ 1. Yes
   2. No

 Esc to cancel · Tab to amend
CAP
}
# A rate-limit menu QUOTED into scrollback, Stop highlighted: above a live
# permission prompt `_unstick_ratelimit_menu_verdict` reads it stop-highlighted,
# because the prompt's own rows follow the quoted title with no REPL row.
quoted_ratelimit_menu() {
    cat <<'CAP'
● The menu the cascade keys off of looks like this:
  What do you want to do?
  ❯ 1. Stop and wait for limit to reset
    2. Upgrade plan
CAP
}
# AskUQ chip-bar literals QUOTED into scrollback. A live permission prompt's own
# bottom row (`Esc to cancel · Tab to amend`, 58 of 61 audits) passes Case D's
# bottom-anchored live-ness gate.
quoted_askuq_block() {
    cat <<'CAP'
● For reference, the overlay rendered:
    4. Type something.
    5. Chat about this
CAP
}
_a_nrec() { # <window> → number of ACTIVE (non-tombstone) records for it
    bash -c 'n=0; for f in "$1"/decisions/"$2".*.json; do [[ -f "$f" && "$f" != *.handled.json ]] && n=$((n+1)); done; echo $n' _ "$WORK" "$1"
}

echo '=== Case A first (#1626 F1): an api-error chip above a LIVE danger prompt gets NO Enter ==='
setup_test
{ api_error_pane "req_chip1626"; rtev_audit_capture; } > "$PANES_DIR/rtev"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'rtev\nwatcher'
assert_eq "A1626-chip.arm: the pane is handled as a permission prompt" "$(_handle_unstick_window rtev)" "permission"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_eq "A1626-chip.nokeys: zero send-keys into a live danger prompt under a chip" "$(sk_count rtev)" "0"
assert_contains "A1626-chip.refused: Case A refused it, naming the danger" "$log_content" "window=rtev case=A action=refused verdict=danger"
assert_not_contains "A1626-chip.noC: no case=C line (the arm is retired, #1670)" "$log_content" "case=C"
teardown_test

echo '=== Case A first (#1626 F1): a QUOTED rate-limit menu above a live prompt — no cascade Enter ==='
setup_test; install_fake_pane_state
{ quoted_ratelimit_menu; rtev_audit_capture; } > "$PANES_DIR/rtev"
quiet_pane > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'rtev\norchestrator\nwatcher'
echo $(( $(date +%s) - 5 )) > "$UNSTICK_DIR/ratelimit.reset.epoch"
assert_eq "A1626-rlquoted.arm: the pane is handled as a permission prompt" "$(_handle_unstick_window rtev)" "permission"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_eq "A1626-rlquoted.nokeys: zero send-keys into the live prompt with a reset elapsed" "$(sk_count rtev)" "0"
assert_contains "A1626-rlquoted.refused: Case A refused it" "$log_content" "window=rtev case=A action=refused verdict=danger"
assert_not_contains "A1626-rlquoted.noB: Case B never claimed it" "$log_content" "window=rtev case=B"
teardown_test; uninstall_fake_pane_state

# The two functions that RE-READ the pane after detection (#1626 residual): the
# cycle's detection routes a prompt pane to Case A, so each is reached here only
# by the race the verdict names — the prompt appearing between detection and the
# re-read. So each is called DIRECTLY on the quoted-menu-above-prompt capture,
# which `_unstick_ratelimit_menu_verdict` reads as stop-highlighted.
echo '=== #1626 residual: _cascade_unstick_to_window re-reads a live prompt — NO Enter, NO paste ==='
setup_test; install_fake_pane_state
{ quoted_ratelimit_menu; rtev_audit_capture; } > "$PANES_DIR/rtev"
WINDOWS_LIST=$'rtev\nwatcher'
assert_eq "A1626r-cascade.pre: the re-read pane reads stop-highlighted (the Enter this guards)" \
    "$(cat "$PANES_DIR/rtev" | _unstick_ratelimit_menu_verdict)" "stop-highlighted"
_cascade_unstick_to_window rtev; rc=$?
actions_content=$(<"$ACTIONS"); log_content=$(<"$UNSTICK_LOG")
assert_eq "A1626r-cascade.rc: refused (rc 1)" "$rc" "1"
assert_eq "A1626r-cascade.nokeys: zero send-keys into the live prompt" "$(sk_count rtev)" "0"
assert_not_contains "A1626r-cascade.nopaste: no continue-paste into the live prompt" "$actions_content" "target=:=rtev"
assert_contains "A1626r-cascade.logged: the refusal names the permission prompt" "$log_content" "window=rtev case=B action=cascade-refused reason=permission-prompt"
teardown_test; uninstall_fake_pane_state

echo '=== #1626 residual: _cascade_heads_up_orchestrator pre-Enter re-reads a live prompt — DEFERRED, no key, no paste ==='
setup_test; install_fake_pane_state
{ quoted_ratelimit_menu; rtev_audit_capture; } > "$PANES_DIR/orchestrator"
WINDOWS_LIST=$'orchestrator\nwatcher'
assert_eq "A1626r-headsup.pre: the orchestrator pane reads stop-highlighted (the pre-Enter this guards)" \
    "$(cat "$PANES_DIR/orchestrator" | _unstick_ratelimit_menu_verdict)" "stop-highlighted"
TARGET=orchestrator _cascade_heads_up_orchestrator 1 rtev; rc=$?
actions_content=$(<"$ACTIONS"); log_content=$(<"$UNSTICK_LOG")
assert_eq "A1626r-headsup.rc: deferred (rc 2), not failed and not sent" "$rc" "2"
assert_eq "A1626r-headsup.nokeys: zero send-keys into the orchestrator's live prompt" "$(sk_count orchestrator)" "0"
assert_not_contains "A1626r-headsup.nopaste: no heads-up pasted into the live prompt" "$actions_content" "target=:=orchestrator"
assert_contains "A1626r-headsup.logged: the deferral names the permission prompt" "$log_content" "case=B action=heads-up-deferred target=orchestrator reason=permission-prompt"
teardown_test; uninstall_fake_pane_state

echo '=== Case A first (#1626 F1): QUOTED AskUQ literals above a live prompt — no Escape on the orchestrator ==='
setup_test; install_fake_pane_state
{ quoted_askuq_block; rtev_audit_capture; } > "$PANES_DIR/orchestrator"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'orchestrator\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_eq "A1626-askuq.orch.nokeys: zero send-keys into the orchestrator's live prompt" "$(sk_count orchestrator)" "0"
assert_contains "A1626-askuq.orch.refused: Case A refused it" "$log_content" "window=orchestrator case=A action=refused verdict=danger"
assert_not_contains "A1626-askuq.orch.noD: Case D never claimed it" "$log_content" "case=D"
teardown_test; uninstall_fake_pane_state

echo '=== Case A first (#1626 F1): the same on a WORKER — a permission_prompt row, not a blocked_question ==='
setup_test
{ quoted_askuq_block; rtev_audit_capture; } > "$PANES_DIR/rtev"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'rtev\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_contains "A1626-askuq.worker.refused: Case A refused it" "$log_content" "window=rtev case=A action=refused verdict=danger"
assert_not_contains "A1626-askuq.worker.noW: Case W never claimed it" "$log_content" "case=W"
teardown_test

# CONTROLS (must NOT flip under the reordering mutant): with no permission prompt
# on the pane every other arm still claims what it claimed.
echo '=== Case A first (#1626 F1) controls: no permission prompt ⇒ B and W unchanged, a chip gets nothing ==='
setup_test
api_error_pane "req_ctl1626" > "$PANES_DIR/agent-1"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-1\nwatcher'
detect_and_unstick
assert_eq "A1626-ctl.chip: a chip with no permission prompt gets NO key (Case C retired, #1670)" "$(sk_count agent-1)" "0"
ratelimit_pane > "$PANES_DIR/agent-2"
assert_eq "A1626-ctl.ratelimit: a live rate-limit menu with no permission prompt still reaches case B" \
    "$(_handle_unstick_window agent-2)" "ratelimit"
askuq_pane > "$PANES_DIR/agent-3"
assert_eq "A1626-ctl.askuq: a live AskUQ overlay on a worker still reaches case W" \
    "$(_handle_unstick_window agent-3)" "worker-askuq"
teardown_test

# ---- Case A fingerprint: the blinking tool-header bullet (#1626 item 5) --------
#
# `.state/unstick/ncbundle.permission.ca80bcd97f11.audit` rows 59..76 (2026-09-22,
# Claude Code 2.1.280), operator path prefixes redacted. Row 3 is the PENDING
# tool call's header; its leading `●` blinks, and bullet-on/bullet-off hashed to
# two fingerprints (skeptic: 2fdedef677d9 vs 2ad2cfce387a on the unredacted rows).
ncbundle_audit_capture() { # [<bullet glyph or two spaces>] [<command>]
    local b="${1:-  }" cmd="${2:-mkdir -p \$S && cp -r /issues \$S/ && rm -rf /issues; ls \$S/issues | wc -l}"
    cat <<CAP
● Plan settled. Writing the ranked plan into the report, then fanning out to partitioned subagents.

${b}Running S=/tmp/REDACTED…
  ⎿  \$ S=/tmp/REDACTED; ${cmd}

───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Bash command

   │ S=/tmp/REDACTED; ${cmd}
   Run shell command

 This command requires approval

 Do you want to proceed?
 ❯ 1. Yes
   2. No

 Esc to cancel · Tab to amend
CAP
}

echo '=== Case A fp (#1626 item 5): bullet-on and bullet-off renders of ONE prompt are ONE fingerprint ==='
setup_test
fp_off=$(ncbundle_audit_capture '  ' | _unstick_fingerprint_permission)
fp_on=$(ncbundle_audit_capture '● ' | _unstick_fingerprint_permission)
fp_mac=$(ncbundle_audit_capture '⏺ ' | _unstick_fingerprint_permission)
assert_eq "A1626-bullet.onefp: ● blink does not change the fingerprint" "$fp_on" "$fp_off"
assert_eq "A1626-bullet.onefp.mac: ⏺ blink does not change it either" "$fp_mac" "$fp_off"
ncbundle_audit_capture '● ' > "$PANES_DIR/ncb"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'ncb\nwatcher'
detect_and_unstick
ncbundle_audit_capture '  ' > "$PANES_DIR/ncb"
detect_and_unstick
assert_eq "A1626-bullet.onerecord: one prompt, blinking, is ONE decision record" "$(_a_nrec ncb)" "1"
# Control (must NOT flip): a DIFFERENT command under the same blinking header is
# a different prompt, whatever the bullet shows.
fp_other=$(ncbundle_audit_capture '● ' 'rm -rf "$S/other"' | _unstick_fingerprint_permission)
assert_eq "A1626-bullet.ctl.distinct: a different command is a different fingerprint" \
    "$([[ -n "$fp_other" && "$fp_other" != "$fp_off" ]] && echo distinct || echo SAME)" "distinct"
teardown_test

# ---- Case A fingerprint: the 2.1.281 auto-deny countdown (#1632) ---------------
#
# The real 2.1.281 binary under cc-harness, ONE dangerous-rm prompt captured at
# t+0 (`2:00`, bullet on) and t+30 s (`1:29`, bullet off); harness paths
# redacted. Pre-fix these hashed to two fps (d6614f1c4b36 / b3b9533f55be on the
# redacted rows), so each watcher poll made a new decision record.
echo '=== Case A fp (#1632): the ticking auto-deny countdown is ONE fingerprint ==='
setup_test
cd_fix="$_test_dir/fixtures/permission-dangerous-rm-countdown-realmodel-281"
fp_t0=$(_unstick_fingerprint_permission < "$cd_fix-t0.txt")
fp_t30=$(_unstick_fingerprint_permission < "$cd_fix-t30.txt")
assert_eq "A1632-countdown.nonempty: the fixture is a detected permission prompt" \
    "$(_unstick_pane_has_permission_prompt "$(<"$cd_fix-t0.txt")" && echo yes || echo no)" "yes"
assert_eq "A1632-countdown.onefp: 2:00 and 1:29 renders of one prompt are one fingerprint" "$fp_t30" "$fp_t0"
cat "$cd_fix-t0.txt" > "$PANES_DIR/rmcd"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'rmcd\nwatcher'
detect_and_unstick
cat "$cd_fix-t30.txt" > "$PANES_DIR/rmcd"
detect_and_unstick
assert_eq "A1632-countdown.onerecord: one ticking prompt is ONE decision record" "$(_a_nrec rmcd)" "1"
assert_eq "A1632-countdown.verdict: it is still classified danger (never answered by Case A)" \
    "$(_unstick_permission_verdict < "$cd_fix-t0.txt" | sed -n 1p)" "danger"
# Controls (must NOT flip): the normalisation touches only the M:SS token.
cd_other=$(sed 's#/REDACTED/tgt)#/REDACTED/other)#g' "$cd_fix-t0.txt")
assert_eq "A1632-countdown.ctl.cmd.potent: the control really rewrote the target rows" \
    "$(grep -c '/REDACTED/other)' <<<"$cd_other")" "2"
fp_cmd=$(_unstick_fingerprint_permission <<<"$cd_other")
assert_eq "A1632-countdown.ctl.cmd: a different rm target is a different fingerprint" \
    "$([[ -n "$fp_cmd" && "$fp_cmd" != "$fp_t0" ]] && echo distinct || echo SAME)" "distinct"
fp_norow=$(grep -v 'automatically deny this request' "$cd_fix-t0.txt" | _unstick_fingerprint_permission)
assert_eq "A1632-countdown.ctl.row: a prompt WITHOUT the countdown row is a different fingerprint" \
    "$([[ -n "$fp_norow" && "$fp_norow" != "$fp_t0" ]] && echo distinct || echo SAME)" "distinct"
teardown_test

# ---- Case A episodes: a prompt that RECURS after its ack surfaces again (#1626 item 5)
echo '=== Case A episodes (#1626 item 5): an acked prompt that comes BACK is surfaced again ==='
setup_test
rtev_audit_capture > "$PANES_DIR/rtev"
quiet_pane > "$PANES_DIR/watcher"
WINDOWS_LIST=$'rtev\nwatcher'
detect_and_unstick
rec=$(_a_rec rtev)
[[ -n "$rec" ]] && mv "$rec" "${rec%.json}.handled.json"
# Continuous sighting (the ack landed while the prompt is still up): stays muted.
detect_and_unstick
assert_eq "A1626-recur.ctl.continuous: a tombstone still mutes a prompt seen continuously" "$(_a_nrec rtev)" "0"
# The prompt went away (> 90 s without a sighting) and came back, same fp.
for f in "$UNSTICK_DIR"/rtev.permission.*.refused; do
    [[ -f "$f" ]] && touch -d "@$(( $(date +%s) - 200 ))" "$f"
done
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_eq "A1626-recur.surfaced: the recurring prompt is an ACTIVE decision again" "$(_a_nrec rtev)" "1"
assert_eq "A1626-recur.tombgone: the previous instance's tombstone is retired" \
    "$(bash -c 'n=0; for f in "$1"/decisions/rtev.*.handled.json; do [[ -f "$f" ]] && n=$((n+1)); done; echo $n' _ "$WORK")" "0"
assert_eq "A1626-recur.relogged: a second refused line, one per instance" \
    "$(grep -cF 'window=rtev case=A action=refused' <<<"$log_content" || true)" "2"
assert_contains "A1626-recur.named: the line says it recurred" "$log_content" "episode=recurred"
assert_eq "A1626-recur.nokeys: still zero send-keys" "$(sk_count rtev)" "0"
teardown_test

# ---- Case C: RETIRED (your-org/nexus-code#1670) -------------------------
#
# Case C used to press ONE bare Enter on an API-error chip. It was retired:
# its literals matched no current render, and its remedy was measured INERT on
# 2.1.284 (mock requests 1 -> 1 after the bare Enter, twice; `continue` + Enter
# 1 -> 2). API-error recovery belongs to the StopFailure marker ->
# `interrupted` -> orchestrator path. These cases pin the retirement: an
# API-error pane, in EITHER render, gets NO key, NO case=C line, NO
# api-error state and NO machine-input stamp. The old synthetic render is
# the base-RED case (the pre-#1670 arm fired on it); the real render is the
# one a re-keyed arm would fire on (the mutation-gate subject).
#
# The real 2.1.284 render, captured with `capture-pane -p` (plain text, the
# form `_handle_unstick_window` reads) from the cc-harness mock returning
# 500/api_error. Scrubbed: the banner rows, the blank padding rows, and the
# harness port (127.0.0.1:33015 -> 127.0.0.1:PORT). The divider rows are
# shortened; nothing in _unstick.sh keys on their width.
api_error_pane_2_1_284() {
    cat <<'EOF'
❯ say pong

● API Error: 500 Internal server error. This is a server-side issue, usually temporary — try again in a moment.
  If it persists, check your inference gateway (127.0.0.1:PORT).

✻ Churned for 0s · done 10:39 AM

────────────────────────────────────────
❯ 
────────────────────────────────────────
  -- INSERT -- ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
EOF
}

# C1670 <label> <pane-fn> [args…]: the one no-action contract, per fixture.
_c1670_assert_no_action() {
    local label="$1"; shift
    setup_test
    "$@" > "$PANES_DIR/agent-1"
    quiet_pane > "$PANES_DIR/watcher"
    WINDOWS_LIST=$'agent-1\nwatcher'
    # The production loop FIRST, on fresh state: calling the arm selector
    # first would itself act and arm the old backoff, masking the key count.
    detect_and_unstick
    assert_eq "C1670.$label.nokeys: zero send-keys into agent-1" "$(sk_count agent-1)" "0"
    assert_eq "C1670.$label.noaction: no tmux action of ANY kind aimed at agent-1" \
        "$(grep -cE "(win|target)=(:=)?agent-1( |\$)" "$ACTIONS" || true)" "0"
    assert_not_contains "C1670.$label.nolog: no case=C line" "$(<"$UNSTICK_LOG")" "case=C"
    assert_eq "C1670.$label.nostate: no api-error fp/epoch/audit files" \
        "$(bash -c 'n=0; for f in "$1"/agent-1.api-error.*; do [[ -e "$f" ]] && n=$((n+1)); done; echo $n' _ "$UNSTICK_DIR")" "0"
    assert_not_contains "C1670.$label.nostamp: no machine-input stamp for agent-1" \
        "$(cat "$WORK/machine-input.tsv" 2>/dev/null)" $'agent-1\t'
    assert_eq "C1670.$label.arm: _handle_unstick_window claims no arm" \
        "$(_handle_unstick_window agent-1)" ""
    teardown_test
}

echo '=== Case C retired (#1670): the REAL 2.1.284 500 render gets no key ==='
_c1670_assert_no_action real284 api_error_pane_2_1_284
echo '=== Case C retired (#1670): the OLD synthetic JSON-chip render gets no key (base: Enter) ==='
_c1670_assert_no_action oldjson api_error_pane "req_aaaa1111"
echo '=== Case C retired (#1670): prose quoting "API Error" gets no key ==='
_c1670_assert_no_action prose api_error_prose_pane
echo '=== Case C retired (#1670): an idle pane gets no key ==='
_c1670_assert_no_action idle quiet_pane

# your-org/nexus-code#1524, kept from the Case C section it used to live in:
# the READ that selects an arm (_handle_unstick_window) is exact-targeted.
# Recorded raw by the stub, since its pane lookup strips `:=` either way.
echo '=== C1524: the arm-selecting capture-pane read uses the EXACT target ==='
setup_test
api_error_pane_2_1_284 > "$PANES_DIR/agent-1"
quiet_pane             > "$PANES_DIR/watcher"
WINDOWS_LIST=$'agent-1\nwatcher'
detect_and_unstick
captures=$(cat "$WORK/captures.log" 2>/dev/null)
assert_eq "C1524.read-exact: the arm-selecting capture-pane read :=agent-1" \
    "$(grep -cxF 'capture-pane target=:=agent-1' <<<"$captures" || true)" "1"
assert_eq "C1524.read-bare: no capture-pane read the BARE name agent-1" \
    "$(grep -cxF 'capture-pane target=agent-1' <<<"$captures" || true)" "0"
assert_not_contains "watcher window untouched" "$(<"$UNSTICK_LOG")" "window=watcher"
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
assert_contains "Escape was sent to orchestrator on the EXACT target" "$actions_content" "send-keys win=:=orchestrator args=Escape"
# your-org/nexus-code#1524: the same pair for case D's Escape (a bare-name Escape
# into a live prefix sibling aborts that agent's in-flight turn).
assert_eq "D1524.exact: case D Escape went to :=orchestrator exactly once" \
    "$(grep -cE '^send-keys win=:=orchestrator args=Escape$' <<<"$actions_content" || true)" "1"
assert_eq "D1524.bare: no case D Escape went to the BARE name orchestrator" \
    "$(grep -cE '^send-keys win=orchestrator args=Escape$' <<<"$actions_content" || true)" "0"
paste_count=$(grep -cE '^paste-buffer buf=.* target=:=orchestrator' <<<"$actions_content" || true)
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
escape_count=$(grep -cE '^send-keys win=(:=)?orchestrator args=Escape' <<<"$actions_content" || true)
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
escape_count=$(grep -cE '^send-keys win=(:=)?orchestrator args=Escape' <<<"$actions_content" || true)
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
escape_count=$(grep -cE '^send-keys win=(:=)?orchestrator args=Escape' <<<"$actions_content" || true)
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
escape_count=$(grep -cE '^send-keys win=(:=)?orchestrator args=Escape' <<<"$actions_content" || true)
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
escape_count=$(grep -cE '^send-keys win=(:=)?orchestrator args=Escape' <<<"$actions_content" || true)
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
mock_escape=$(grep -cE '^send-keys win=(:=)?cc-mock-lab args=Escape' <<<"$actions_content" || true)
worker_escape=$(grep -cE '^send-keys win=(:=)?some-worker args=Escape' <<<"$actions_content" || true)
assert_eq "operator window received zero Escape" "$mock_escape" "0"
assert_eq "worker window received zero Escape"   "$worker_escape" "0"
# A ZERO assertion must not depend on guessing the target's spelling: match the
# window under EITHER form (`cc-mock-lab` or the exact-name `:=cc-mock-lab`), or
# a paste that did happen could hide behind the spelling this pattern missed.
mock_paste=$(grep -cE '^paste-buffer buf=.* target=(:=)?cc-mock-lab' <<<"$actions_content" || true)
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
escape_count=$(grep -cE '^send-keys win=(:=)?orchestrator args=Escape' <<<"$actions_content" || true)
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
escape_count=$(grep -cE '^send-keys win=(:=)?orchestrator args=Escape' <<<"$actions_content" || true)
assert_eq "orchestrator received zero Escape on quoted overlay" "$escape_count" "0"
teardown_test

echo '=== Case D ordering: permission prompt embedding "Chat about this" still fires Case A ==='
# Audit the original concern: Case A's chevron pattern overlaps with
# AskUQ overlays. Case A now runs FIRST (skeptic pass on #1626), so this
# row is a regression guard for the old D-before-A ordering: a permission
# prompt that happens to contain one (but only one) of the AskUQ literals
# must still be Case A — and the A1626-askuq.* rows cover BOTH literals.
setup_test
permission_with_chat_prose_pane > "$PANES_DIR/orchestrator"
quiet_pane                      > "$PANES_DIR/watcher"
WINDOWS_LIST=$'orchestrator\nwatcher'
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
actions_content=$(<"$ACTIONS")
assert_contains "Case A still fires for permission + 'chat about this' prose" "$log_content" "window=orchestrator case=A action=refused"
assert_not_contains "Case D does NOT fire (only one literal present)" "$log_content" "case=D"
enter_count=$(grep -cE '^send-keys win=(:=)?orchestrator args=Enter' <<<"$actions_content" || true)
assert_eq "orchestrator received zero Enter (Case A refuses, #1599)" "$enter_count" "0"
escape_count=$(grep -cE '^send-keys win=(:=)?orchestrator args=Escape' <<<"$actions_content" || true)
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
worker_keys=$(grep -cE '^send-keys win=(:=)?some-worker' <<<"$actions_content" || true)
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
worker_keys=$(grep -cE '^send-keys win=(:=)?some-worker' <<<"$actions_content" || true)
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

echo '=== Case W (#1626 residual): a question that RECURS after its ack is surfaced again ==='
# Case A's recurrence rule, applied to W. The previous instance was relayed and
# ACKED (tombstone), the overlay went away (> 90 s since the last sighting) and
# the same question came back. It used to re-arm, wait out the grace and then
# `skip-tombstone` forever — on a hookless worker, a live question nobody is
# told about. The continuously-seen control is "tombstone honoured" above.
setup_test
askuq_pane > "$PANES_DIR/some-worker"
quiet_pane > "$PANES_DIR/orchestrator"
WINDOWS_LIST=$'some-worker\norchestrator'
W_FP=$(_test_w_fp)
mkdir -p "$WORK/decisions"
printf '{"kind":"blocked_question","fingerprint":"%s"}\n' "$W_FP" > "$WORK/decisions/some-worker.$W_FP.handled.json"
marker="$UNSTICK_DIR/some-worker.worker-askuq.$W_FP.first-seen"
printf '%s' "$(( $(date +%s) - 4000 ))" > "$marker"
touch -d "@$(( $(date +%s) - 200 ))" "$marker"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_contains "W1626-recur.rearmed: the recurrence re-arms the episode" "$log_content" "window=some-worker case=W action=re-armed fp=$W_FP"
assert_eq "W1626-recur.tombgone: the previous instance's tombstone is retired" \
    "$([[ -e "$WORK/decisions/some-worker.$W_FP.handled.json" ]] && echo present || echo gone)" "gone"
assert_contains "W1626-recur.named: the retirement is logged" "$log_content" "window=some-worker case=W action=tombstone-retired fp=$W_FP"
# The new instance then waits out its OWN grace, continuously seen, and relays.
printf '%s' "$(( $(date +%s) - 400 ))" > "$marker"
touch "$marker"
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_contains "W1626-recur.relayed: the recurring question is relayed again" "$log_content" "window=some-worker case=W action=relayed fp=$W_FP"
assert_not_contains "W1626-recur.noskip: no skip-tombstone for the new instance" "$log_content" "case=W action=skip-tombstone"
assert_eq "W1626-recur.nokeys: still zero keys to the worker" \
    "$(grep -cE '^send-keys win=(:=)?some-worker' "$ACTIONS" || true)" "0"
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

# ---- Case B: a RESET EVENT expedites the cascade (your-org/nexus-code#1739) ----
#
# Row ids R39-* were named in the prediction BEFORE the fix existed. Red on base:
# base has no sensor, so the event rows cascade nothing until the epoch.

# Write an identity into the per-test credential files (identity-level fields
# ONLY, plus a token field the sensor must never copy out).
r39_cred() { # <account-uuid> <tier>
    mkdir -p "$WORK/cred"
    printf '{"oauthAccount":{"accountUuid":"%s","organizationUuid":"org-1","emailAddress":"x@y"}}\n' "$1" > "$UNSTICK_CRED_ACCOUNT_FILE"
    printf '{"claudeAiOauth":{"accessToken":"SECRET-TOKEN-%s","expiresAt":%s,"subscriptionType":"max","rateLimitTier":"%s"}}\n' "$1" "$RANDOM" "$2" > "$UNSTICK_CRED_STORE_FILE"
    touch -d "@$(( $(date +%s) + RANDOM % 1000 ))" "$UNSTICK_CRED_STORE_FILE" "$UNSTICK_CRED_ACCOUNT_FILE"
}
r39_board() {
    ratelimit_pane > "$PANES_DIR/agent-1"
    ratelimit_pane > "$PANES_DIR/agent-2"
    quiet_pane     > "$PANES_DIR/orchestrator"
    quiet_pane     > "$PANES_DIR/watcher"
    WINDOWS_LIST=$'agent-1\nagent-2\norchestrator\nwatcher'
}
paste_count() { local n; n=$(grep -cE "^paste-buffer buf=.* target=:=$1\$" "$ACTIONS" || true); printf '%s' "${n:-0}"; }

echo '=== Case B (#1739): two windows at the menu + a credential change → both resumed within ONE poll ==='
setup_test; r39_board; r39_cred acct-A tier-1
detect_and_unstick                       # poll 1: baseline + episode scheduled 30 min out
assert_eq "R39-change.precondition: nothing pasted before the change" "$(paste_count agent-1)$(paste_count agent-2)" "00"
r39_cred acct-B tier-1                   # the operator switches account
detect_and_unstick                       # poll 2
log_content=$(<"$UNSTICK_LOG")
assert_contains "R39-change.event: credential change logged" "$log_content" "case=B action=credential-change"
assert_contains "R39-change.expedited: epoch pulled to now" "$log_content" "case=B action=reset-epoch-expedited source=credential-change"
assert_contains "R39-change.a1: agent-1 resumed" "$log_content" "window=agent-1 case=B action=cascade-resumed"
assert_contains "R39-change.a2: agent-2 resumed" "$log_content" "window=agent-2 case=B action=cascade-resumed"
assert_eq "R39-change.paste: one continuation per window" "$(paste_count agent-1)$(paste_count agent-2)" "11"
assert_contains "R39-change.brief: the brief names the event and asks for a re-check" \
    "$(grep -m1 -E '^load-buffer .*content=Please continue' "$ACTIONS")" "Re-check any jobs, watches and messages"
assert_contains "R39-change.headsup: orchestrator told" "$log_content" "case=B action=heads-up target=orchestrator n=2"
assert_not_contains "R39-change.secret: no token value in the log" "$log_content" "SECRET-TOKEN"
assert_not_contains "R39-change.secret: no account uuid in the stored baseline" "$(cat "$UNSTICK_DIR"/credential.* 2>/dev/null)" "acct-B"
teardown_test

echo '=== Case B (#1739): NO credential change → unchanged behaviour (still waits for the epoch) ==='
setup_test; r39_board; r39_cred acct-A tier-1
detect_and_unstick
touch -d "@$(( $(date +%s) + 5 ))" "$UNSTICK_CRED_ACCOUNT_FILE"   # rewritten, same identity
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_not_contains "R39-same.noevent: no reset event" "$log_content" "reset-event"
assert_not_contains "R39-same.nocascade: no window resumed" "$log_content" "cascade-resumed"
assert_eq "R39-same.nokeys: zero keys into either menu" "$(sk_count agent-1)$(sk_count agent-2)" "00"
teardown_test

echo '=== Case B (#1739): the FIRST sighting and an UNREADABLE store are not changes ==='
setup_test; r39_board
detect_and_unstick                       # no files at all
r39_cred acct-A tier-1
detect_and_unstick                       # first identity ever seen: baseline only
rm -f "$UNSTICK_CRED_ACCOUNT_FILE" "$UNSTICK_CRED_STORE_FILE"
detect_and_unstick                       # vanished: could not look, not changed
log_content=$(<"$UNSTICK_LOG")
assert_not_contains "R39-first.noevent: no credential-change raised" "$log_content" "credential-change"
assert_not_contains "R39-first.nocascade: no window resumed" "$log_content" "cascade-resumed"
teardown_test

echo '=== Case B (#1739): a TYPED operator draft is refused, its sibling is still resumed ==='
setup_test; install_fake_pane_state; r39_board; r39_cred acct-A tier-1
echo 'state=blocked active=1 overlay=rate-limit input=typed' > "$PSTATE_DIR/agent-2"
echo 'state=blocked active=1 overlay=rate-limit input=?'     > "$PSTATE_DIR/agent-1"
echo 'state=idle active=0 input=blank'                        > "$PSTATE_DIR/agent-1.after"
detect_and_unstick
r39_cred acct-B tier-1
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_contains "R39-draft.refused: agent-2 refused as an operator draft" "$log_content" "window=agent-2 case=B action=cascade-refused reason=operator-draft stage=before-dismiss"
assert_eq "R39-draft.nokeys: ZERO keys into the drafting pane" "$(sk_count agent-2)" "0"
assert_eq "R39-draft.nopaste: nothing pasted into it" "$(paste_count agent-2)" "0"
assert_contains "R39-draft.sibling: input=? under a live menu is not a refusal — agent-1 resumed" "$log_content" "window=agent-1 case=B action=cascade-resumed"
teardown_test; uninstall_fake_pane_state

echo '=== Case B (#1739): a draft the menu was HIDING is refused after the dismissal ==='
setup_test; install_fake_pane_state; r39_board; r39_cred acct-A tier-1
WINDOWS_LIST=$'agent-1\norchestrator\nwatcher'
echo 'state=blocked active=1 overlay=rate-limit input=?' > "$PSTATE_DIR/agent-1"
echo 'state=user-typing active=1 input=typed'            > "$PSTATE_DIR/agent-1.after"
detect_and_unstick
r39_cred acct-B tier-1
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_contains "R39-hidden.refused: refused after the dismiss" "$log_content" "window=agent-1 case=B action=cascade-refused reason=operator-draft stage=after-dismiss"
assert_eq "R39-hidden.onekey: exactly the ONE dismiss Enter, no submit" "$(sk_count agent-1 Enter)" "1"
assert_eq "R39-hidden.nopaste: nothing pasted" "$(paste_count agent-1)" "0"
teardown_test; uninstall_fake_pane_state

echo '=== Case B (#1739): a menu that does NOT leave on Enter gets no paste ==='
setup_test; r39_board; r39_cred acct-A tier-1
WINDOWS_LIST=$'agent-1\norchestrator\nwatcher'
touch "$PANES_DIR/agent-1.sticky"
detect_and_unstick
r39_cred acct-B tier-1
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_contains "R39-sticky.refused: dismissal unverified" "$log_content" "window=agent-1 case=B action=cascade-refused reason=dismiss-unverified"
assert_eq "R39-sticky.onekey: exactly the ONE dismiss Enter" "$(sk_count agent-1 Enter)" "1"
assert_eq "R39-sticky.nopaste: nothing pasted into the menu" "$(paste_count agent-1)" "0"
teardown_test

echo '=== Case B (#1739): a signalled event (over-limit resumed) cascades even with a cascade pending its ack ==='
setup_test; r39_board
detect_and_unstick                                     # episode scheduled
echo "$(date +%s)" > "$UNSTICK_DIR/ratelimit.cascade.epoch"   # an earlier cascade awaiting its ack
_unstick_reset_event_signal "over-limit-resumed:orchestrator"
_unstick_reset_event_signal "credential-change"        # second source: first writer wins
detect_and_unstick
log_content=$(<"$UNSTICK_LOG")
assert_contains "R39-signal.source: the first source is the one consumed" "$log_content" "case=B action=reset-event source=over-limit-resumed:orchestrator"
assert_contains "R39-signal.a1: agent-1 resumed" "$log_content" "window=agent-1 case=B action=cascade-resumed fp="
assert_eq "R39-signal.consumed: the event file is gone" "$([[ -e "$UNSTICK_DIR/ratelimit.reset-event" ]] && echo present || echo gone)" "gone"
teardown_test

echo '=== Case B (#1741 S1): ONE-SIDED reads are "could not look", never a change ==='
s1_events() { grep -c 'action=credential-change' "$UNSTICK_LOG" || true; }
setup_test; r39_board; r39_cred acct-A tier-1
detect_and_unstick                                           # baseline A
# logout: the store loses its identity while the config keeps oauthAccount
printf '{}\n' > "$UNSTICK_CRED_STORE_FILE"; touch -d "@$(( $(date +%s) + 7 ))" "$UNSTICK_CRED_STORE_FILE"
detect_and_unstick
assert_eq "S1-logout.store: a store with no identity raises nothing" "$(s1_events)" "0"
printf '{"other":1}\n' > "$UNSTICK_CRED_ACCOUNT_FILE"; touch -d "@$(( $(date +%s) + 9 ))" "$UNSTICK_CRED_ACCOUNT_FILE"
detect_and_unstick
assert_eq "S1-logout.both: both halves empty raises nothing" "$(s1_events)" "0"
r39_cred acct-A tier-1                                       # log back in, SAME account
detect_and_unstick
assert_eq "S1-relogin.same: same-account login raises nothing" "$(s1_events)" "0"
chmod 000 "$UNSTICK_CRED_STORE_FILE"; touch -d "@$(( $(date +%s) + 11 ))" "$UNSTICK_CRED_STORE_FILE"
detect_and_unstick
chmod 600 "$UNSTICK_CRED_STORE_FILE"; touch -d "@$(( $(date +%s) + 13 ))" "$UNSTICK_CRED_STORE_FILE"
detect_and_unstick
assert_eq "S1-chmod: an unreadable store, then readable again, raises nothing" "$(s1_events)" "0"
good=$(<"$UNSTICK_CRED_ACCOUNT_FILE")
printf '%s' "${good:0:30}" > "$UNSTICK_CRED_ACCOUNT_FILE"; touch -d "@$(( $(date +%s) + 15 ))" "$UNSTICK_CRED_ACCOUNT_FILE"
detect_and_unstick
printf '%s\n' "$good" > "$UNSTICK_CRED_ACCOUNT_FILE"; touch -d "@$(( $(date +%s) + 17 ))" "$UNSTICK_CRED_ACCOUNT_FILE"
detect_and_unstick
assert_eq "S1-torn: a torn (mid-write) config, then whole again, raises nothing" "$(s1_events)" "0"
assert_not_contains "S1-nocascade: no window resumed across all of it" "$(<"$UNSTICK_LOG")" "cascade-resumed"
r39_cred acct-B tier-1                                       # control: a REAL switch still fires
detect_and_unstick
assert_eq "S1-control: a real account switch still raises exactly one event" "$(s1_events)" "1"
teardown_test

echo '=== Case B (#1741 S1 follow-up): a login with NO subscription/tier fields still senses a switch ==='
s1t_cred() { # <account-uuid>: a login shape carrying no subscriptionType / rateLimitTier
    mkdir -p "$WORK/cred"
    printf '{"oauthAccount":{"accountUuid":"%s","organizationUuid":"org-1"}}\n' "$1" > "$UNSTICK_CRED_ACCOUNT_FILE"
    printf '{"claudeAiOauth":{"accessToken":"SECRET-TOKEN-%s","expiresAt":%s}}\n' "$1" "$RANDOM" > "$UNSTICK_CRED_STORE_FILE"
    touch -d "@$(( $(date +%s) + RANDOM % 1000 + 20 ))" "$UNSTICK_CRED_STORE_FILE" "$UNSTICK_CRED_ACCOUNT_FILE"
}
setup_test; r39_board; s1t_cred acct-A
detect_and_unstick
assert_eq "S1t-baseline: a tier-less login yields a KNOWN baseline (not unknown)" \
    "$([[ -s "$UNSTICK_DIR/credential.sig" ]] && echo known || echo unknown)" "known"
s1t_cred acct-B
detect_and_unstick
assert_eq "S1t-switch: an account switch on a tier-less login raises one event" "$(s1_events)" "1"
assert_contains "S1t-cascade: and the menus are cascaded" "$(<"$UNSTICK_LOG")" "window=agent-1 case=B action=cascade-resumed"
teardown_test

echo '=== Case B (#1741 S1 follow-up): a tier change on the SAME account is not an identity change ==='
setup_test; r39_board; r39_cred acct-A tier-1
detect_and_unstick
r39_cred acct-A tier-2
detect_and_unstick
assert_eq "S1t-tier: same account, new tier raises nothing" "$(s1_events)" "0"
teardown_test

# ---- Summary -----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
