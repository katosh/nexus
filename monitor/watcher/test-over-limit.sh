#!/usr/bin/env bash
# Tests for monitor/watcher/_over_limit.sh — the watcher-side wake
# scheduler for panes that hit the weekly Opus limit (issue #87).
#
# Coverage:
#   - reset_at token parsing (canonical / terse / unknown / bare)
#   - stamp insert/refresh (first_seen + attempts preserved)
#   - stamp drop (file deleted when empty)
#   - orchestrator_paused predicate
#   - scan_panes: orchestrator + workers via stubbed pane-state.sh
#   - process_wakes state machine:
#       still over-limit → exponential backoff, attempt cap
#       resumed → paste brief + drop stamp
#       pane-absent / blocked → drop stamp
#       paste failure → retry next cycle without consuming attempt
#   - compose_resume_brief includes duration + workers summary
#
# Run: bash monitor/watcher/test-over-limit.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HELPER="$_repo_root/monitor/watcher/_over_limit.sh"
IDLE="$_repo_root/monitor/watcher/_idle_probe.sh"
[[ -f "$HELPER" ]] || { echo "helper not found: $HELPER" >&2; exit 1; }

. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR"
export STATE_DIR

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

# Stubbed tmux. MOCK_TMUX_WINDOWS is `<name>|<idx>` newline-separated.
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
# MOCK_TMUX_WINDOWS is `<name>|<idx>` rows. The two `list-windows`
# format strings the watcher uses both want three fields though, so
# synthesize the activity epoch from MOCK_TMUX_ACTIVITY_EPOCH or
# default to "now".
fmt_three() {
    local act_default
    act_default="${MOCK_TMUX_ACTIVITY_EPOCH:-$(date +%s)}"
    printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" \
        | awk -F'|' -v act="$act_default" \
            'NF>=2 && $1 != "" { printf "%s|%s|%s\n", $1, act, $2 }'
}
case "${1:-}" in
    list-windows)
        # If `-F` was passed, parse it and emit the requested shape.
        F=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -F) F="$2"; shift 2 ;;
                *)  shift ;;
            esac
        done
        if [[ "$F" == *'#{window_activity}'* && "$F" == *'#{window_index}'* ]]; then
            fmt_three
        elif [[ "$F" == *'#{window_index}'* ]]; then
            printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" \
                | awk -F'|' 'NF>=2 && $1 != "" { printf "%s|%s\n", $1, $2 }'
        else
            # Default: window-name only.
            printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" \
                | awk -F'|' 'NF>=1 && $1 != "" { print $1 }'
        fi
        ;;
    *) :;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

# Stubbed pane-state.sh. Reads MOCK_PANE_STATE_<idx-or-name> and
# optional MOCK_PANE_RESET_AT_<key> for the over-limit branch.
cat > "$STUB_DIR/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
# Drop leading optional flags.
while [[ "${1:-}" == --* ]]; do
    shift 2 2>/dev/null || break
done
win="${1:-}"
key="MOCK_PANE_STATE_${win//[^a-zA-Z0-9_]/_}"
reset_key="MOCK_PANE_RESET_AT_${win//[^a-zA-Z0-9_]/_}"
state="${!key:-busy}"
reset_at="${!reset_key:-}"
if [[ -n "$reset_at" ]]; then
    printf 'state=%s active=0 window=%s name=stub reset_at=%s\n' \
        "$state" "$win" "$reset_at"
else
    printf 'state=%s active=0 window=%s name=stub\n' "$state" "$win"
fi
exit 0
STUB
chmod +x "$STUB_DIR/pane-state.sh"

# Mirror the layout _over_limit_probe_pane / _over_limit_scan_panes
# expect: NEXUS_ROOT/monitor/pane-state.sh.
mkdir -p "$WORK/monitor"
cp "$STUB_DIR/pane-state.sh" "$WORK/monitor/pane-state.sh"
chmod +x "$WORK/monitor/pane-state.sh"
NEXUS_ROOT="$WORK"
export NEXUS_ROOT

# Inject capturing log + paste functions.
PASTE_LOG="$WORK/paste.log"
LOG_LOG="$WORK/log.log"
: > "$PASTE_LOG"
: > "$LOG_LOG"
test_log() {
    printf '%s\n' "$*" >> "$LOG_LOG"
}
test_paste() {
    local win="$1" body="$2"
    printf '%s\t%s\n' "$win" "$(cat "$body" 2>/dev/null | tr '\n' ' ' | head -c 2000)" \
        >> "$PASTE_LOG"
    # Caller may override: PASTE_RC=1 to simulate a failed paste.
    return "${PASTE_RC:-0}"
}
export -f test_log test_paste

# Source the helpers under test in a way that picks up the stubs. We
# rely on `path=$(_over_limit_state_path)` reading the current
# $STATE_DIR each call, so a single source covers all tests.
PATH="$STUB_DIR:$PATH"
export PATH

# Source order matters: _idle_probe.sh first so _over_limit_scan_panes
# can find _idle_list_worker_windows. _lib.sh provides
# `_machine_input_stamp`, the shared ledger-write chokepoint the
# worker-wake path stamps through (#293); main.sh sources it in
# production, so the standalone test pulls it in too.
LIB="$_repo_root/monitor/watcher/_lib.sh"
# shellcheck disable=SC1090
source "$LIB"
# shellcheck disable=SC1090
source "$IDLE"
# shellcheck disable=SC1090
source "$HELPER"
_OVER_LIMIT_LOG_FN=test_log
_OVER_LIMIT_PASTE_FN=test_paste

reset_state() {
    : > "$PASTE_LOG"
    : > "$LOG_LOG"
    rm -f "$STATE_DIR/over-limit-state.tsv"
    unset PASTE_RC
}

# Helper: synthesize a stamp row directly (bypass _over_limit_record
# so we can pin specific timestamps for the wake-loop tests).
synth_row() {
    local key="$1" window="$2" role="$3" token="$4"
    local reset_epoch="$5" first_seen="$6" next_attempt="$7" attempts="$8"
    local path
    path=$(_over_limit_state_path)
    mkdir -p "$(dirname "$path")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$key" "$window" "$role" "$token" \
        "$reset_epoch" "$first_seen" "$next_attempt" "$attempts" \
        >> "$path"
}

NOW=$(date +%s)

# ---- reset_at parsing -----------------------------------------------------

echo '=== reset_at_to_epoch ==='

# Canonical token: 3am in LA. Today's 3am LA = a specific epoch; the
# helper bumps by 24h if already past. We don't pin to a specific
# wall-clock; just assert the result is a valid future epoch within
# the next 26h (24h reset + 2h slack for tz boundaries).
epoch=$(_over_limit_reset_at_to_epoch "3am_America/Los_Angeles" "$NOW")
if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch >= NOW )) && (( epoch <= NOW + 26*3600 )); then
    printf '  PASS: canonical token resolves to future epoch within 26h\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: canonical token resolution (got %s)\n' "$epoch" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Terse token: just "11pm". Same bounds.
epoch=$(_over_limit_reset_at_to_epoch "11pm" "$NOW")
if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch >= NOW )) && (( epoch <= NOW + 26*3600 )); then
    printf '  PASS: terse token resolves to future epoch\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: terse token resolution (got %s)\n' "$epoch" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Unknown / empty token → safety fallback (now + 6h).
epoch=$(_over_limit_reset_at_to_epoch "unknown" "$NOW")
expected=$(( NOW + 21600 ))
assert_eq "unknown → +6h fallback" "$epoch" "$expected"

epoch=$(_over_limit_reset_at_to_epoch "" "$NOW")
assert_eq "empty → +6h fallback" "$epoch" "$expected"

# Garbage token → fallback.
epoch=$(_over_limit_reset_at_to_epoch "not_a_time" "$NOW")
assert_eq "unparseable → +6h fallback" "$epoch" "$expected"

# ---- stamp lifecycle ------------------------------------------------------

echo '=== stamp insert + load ==='
reset_state
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am_America/Los_Angeles"
row=$(_over_limit_load "_orchestrator")
assert_contains "row stored under _orchestrator key" "$row" "orchestrator"
assert_contains "role field stored"                  "$row" "orchestrator"
assert_contains "token preserved"                    "$row" "3am_America/Los_Angeles"

echo '=== stamp refresh preserves first_seen + attempts ==='
reset_state
synth_row "worker-a" "worker-a" "worker" "3am_America/Los_Angeles" \
    $(( NOW + 1800 )) $(( NOW - 100 )) $(( NOW + 60 )) 3
_over_limit_record "worker-a" "worker-a" "worker" "3am_America/Los_Angeles"
row=$(_over_limit_load "worker-a")
fs=$(awk -F'\t' '{print $6}' <<<"$row")
attempts=$(awk -F'\t' '{print $8}' <<<"$row")
assert_eq "first_seen preserved on refresh" "$fs"       "$(( NOW - 100 ))"
assert_eq "attempts preserved on refresh"   "$attempts" "3"

echo '=== stamp drop removes file when last row ==='
reset_state
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am"
[[ -f "$(_over_limit_state_path)" ]] && \
    { printf '  PASS: state file exists after record\n'; PASS=$(( PASS + 1 )); } || \
    { printf '  FAIL: state file missing after record\n' >&2; FAIL=$(( FAIL + 1 )); }
_over_limit_drop "_orchestrator"
if [[ -f "$(_over_limit_state_path)" ]]; then
    printf '  FAIL: state file lingered after last-row drop\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: state file removed after last-row drop\n'
    PASS=$(( PASS + 1 ))
fi

echo '=== stamp drop leaves siblings intact ==='
reset_state
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am"
_over_limit_record "worker-a" "worker-a" "worker" "11pm"
_over_limit_drop "_orchestrator"
row=$(_over_limit_load "worker-a")
assert_contains "sibling row survives sibling drop" "$row" "worker-a"
if _over_limit_load "_orchestrator" >/dev/null; then
    printf '  FAIL: dropped row still loadable\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: dropped row truly removed\n'
    PASS=$(( PASS + 1 ))
fi

# ---- orchestrator_paused --------------------------------------------------

echo '=== orchestrator_paused predicate ==='
reset_state
_over_limit_orchestrator_paused && { printf '  FAIL: paused with empty state\n' >&2; FAIL=$(( FAIL + 1 )); } \
                                || { printf '  PASS: not paused when state empty\n'; PASS=$(( PASS + 1 )); }
_over_limit_record "worker-a" "worker-a" "worker" "3am"
_over_limit_orchestrator_paused && { printf '  FAIL: paused on worker-only state\n' >&2; FAIL=$(( FAIL + 1 )); } \
                                || { printf '  PASS: not paused on worker-only state\n'; PASS=$(( PASS + 1 )); }
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am"
_over_limit_orchestrator_paused && { printf '  PASS: paused when _orchestrator row present\n'; PASS=$(( PASS + 1 )); } \
                                || { printf '  FAIL: not paused with _orchestrator row\n' >&2; FAIL=$(( FAIL + 1 )); }

# ---- scan_panes -----------------------------------------------------------

echo '=== scan_panes: orchestrator detection ==='
reset_state
export MOCK_TMUX_WINDOWS="orchestrator|2"
export MOCK_PANE_STATE_2=over-limit
export MOCK_PANE_RESET_AT_2='3am_America/Los_Angeles'
_over_limit_scan_panes "orchestrator"
row=$(_over_limit_load "_orchestrator")
assert_contains "orchestrator stamped on over-limit scan" "$row" "orchestrator"
assert_contains "reset_at flowed through scan"            "$row" "3am_America/Los_Angeles"
unset MOCK_PANE_STATE_2 MOCK_PANE_RESET_AT_2

echo '=== scan_panes: worker detection ==='
reset_state
export MOCK_TMUX_WINDOWS="$(printf 'orchestrator|2\nworker-a|3\nworker-b|4')"
export MOCK_PANE_STATE_2=busy
export MOCK_PANE_STATE_3=over-limit
export MOCK_PANE_RESET_AT_3='11pm'
export MOCK_PANE_STATE_4=idle
_over_limit_scan_panes "orchestrator"
row_a=$(_over_limit_load "worker-a")
assert_contains "worker-a stamped"      "$row_a" "worker"
assert_contains "worker-a token stored" "$row_a" "11pm"
_over_limit_load "worker-b" >/dev/null \
    && { printf '  FAIL: worker-b (idle) wrongly stamped\n' >&2; FAIL=$(( FAIL + 1 )); } \
    || { printf '  PASS: idle worker not stamped\n'; PASS=$(( PASS + 1 )); }
_over_limit_load "_orchestrator" >/dev/null \
    && { printf '  FAIL: busy orchestrator wrongly stamped\n' >&2; FAIL=$(( FAIL + 1 )); } \
    || { printf '  PASS: busy orchestrator not stamped\n'; PASS=$(( PASS + 1 )); }
unset MOCK_PANE_STATE_2 MOCK_PANE_STATE_3 MOCK_PANE_STATE_4 MOCK_PANE_RESET_AT_3

# ---- process_wakes state machine ------------------------------------------

echo '=== wake: not-yet-due row left alone ==='
reset_state
export MOCK_TMUX_WINDOWS="orchestrator|2"
export MOCK_PANE_STATE_2=over-limit
export MOCK_PANE_RESET_AT_2='3am'
# Stamp with next_attempt FAR in the future.
synth_row "_orchestrator" "orchestrator" "orchestrator" "3am" \
    $(( NOW + 3600 )) $(( NOW - 60 )) $(( NOW + 3600 )) 0
_over_limit_process_wakes "orchestrator"
row=$(_over_limit_load "_orchestrator")
attempts=$(awk -F'\t' '{print $8}' <<<"$row")
assert_eq "not-yet-due row: attempts unchanged" "$attempts" "0"
[[ -s "$PASTE_LOG" ]] && { printf '  FAIL: paste fired before wake due\n' >&2; FAIL=$(( FAIL + 1 )); } \
                     || { printf '  PASS: no paste before wake due\n'; PASS=$(( PASS + 1 )); }

echo '=== wake: still-over-limit applies backoff + bumps attempts ==='
reset_state
export MOCK_TMUX_WINDOWS="orchestrator|2"
export MOCK_PANE_STATE_2=over-limit
export MOCK_PANE_RESET_AT_2='3am'
# Due-now row at attempts=0.
synth_row "_orchestrator" "orchestrator" "orchestrator" "3am" \
    $(( NOW - 60 )) $(( NOW - 600 )) $(( NOW - 1 )) 0
NOW_FROZEN=$(date +%s)
_over_limit_process_wakes "orchestrator"
row=$(_over_limit_load "_orchestrator")
attempts=$(awk -F'\t' '{print $8}' <<<"$row")
next_at=$(awk -F'\t' '{print $7}' <<<"$row")
assert_eq "attempts bumped to 1" "$attempts" "1"
if (( next_at >= NOW_FROZEN + 55 )) && (( next_at <= NOW_FROZEN + 65 )); then
    printf '  PASS: next_attempt = now + initial backoff (~60s)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: next_attempt = %s (want ≈ %s..%s)\n' "$next_at" "$(( NOW_FROZEN + 55 ))" "$(( NOW_FROZEN + 65 ))" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo '=== wake: backoff doubles up to cap ==='
reset_state
export MOCK_TMUX_WINDOWS="orchestrator|2"
export MOCK_PANE_STATE_2=over-limit
export MOCK_PANE_RESET_AT_2='3am'
synth_row "_orchestrator" "orchestrator" "orchestrator" "3am" \
    $(( NOW - 60 )) $(( NOW - 600 )) $(( NOW - 1 )) 4
NOW_FROZEN=$(date +%s)
# Pin the attempt cap above this test's attempt count — the default
# cap is 4 (fail-open), which would terminate the row before the
# backoff arithmetic under test here gets exercised.
MONITOR_OVER_LIMIT_MAX_ATTEMPTS=10 _over_limit_process_wakes "orchestrator"
row=$(_over_limit_load "_orchestrator")
attempts=$(awk -F'\t' '{print $8}' <<<"$row")
next_at=$(awk -F'\t' '{print $7}' <<<"$row")
assert_eq "attempts bumped to 5" "$attempts" "5"
# attempts=5 → shift_n = 4 → 60 * 16 = 960s, capped at 300s.
if (( next_at >= NOW_FROZEN + 295 )) && (( next_at <= NOW_FROZEN + 305 )); then
    printf '  PASS: backoff capped at 300s\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: backoff cap (got %s, want ~%s)\n' \
        "$(( next_at - NOW_FROZEN ))" "300" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo '=== wake: max attempts → FAIL OPEN (paste wake brief + drop stamp) ==='
# A suspended pane never repaints on its own and the hook stamp only
# clears on a successful turn, so post-reset the probe keeps reading
# over-limit; the terminal action MUST be a paste (the probe that
# breaks the cycle), never a silent drop — a silent drop lets the
# next scan_panes re-stamp with a fresh reset horizon and the
# suppression latches forever (2026-07-14 incident class).
reset_state
rm -f "$STATE_DIR/machine-input.tsv"
export MOCK_TMUX_WINDOWS="worker-a|3"
export MOCK_PANE_STATE_3=over-limit
export MOCK_PANE_RESET_AT_3='3am'
# attempts=9 → next bump → 10 → exceeds cap.
synth_row "worker-a" "worker-a" "worker" "3am" \
    $(( NOW - 60 )) $(( NOW - 600 )) $(( NOW - 1 )) 9
MONITOR_OVER_LIMIT_MAX_ATTEMPTS=10 _over_limit_process_wakes "orchestrator"
_over_limit_load "worker-a" >/dev/null \
    && { printf '  FAIL: row still present after max attempts\n' >&2; FAIL=$(( FAIL + 1 )); } \
    || { printf '  PASS: row dropped at max attempts\n'; PASS=$(( PASS + 1 )); }
grep -q "max wake attempts" "$LOG_LOG" && \
    { printf '  PASS: max-attempts log emitted\n'; PASS=$(( PASS + 1 )); } || \
    { printf '  FAIL: max-attempts log missing (log: %s)\n' "$(cat "$LOG_LOG")" >&2; FAIL=$(( FAIL + 1 )); }
grep -q "failing OPEN" "$LOG_LOG" && \
    { printf '  PASS: fail-open logged\n'; PASS=$(( PASS + 1 )); } || \
    { printf '  FAIL: fail-open log missing (log: %s)\n' "$(cat "$LOG_LOG")" >&2; FAIL=$(( FAIL + 1 )); }
grep -q "worker-a" "$PASTE_LOG" && \
    { printf '  PASS: wake brief pasted at max attempts (fail open)\n'; PASS=$(( PASS + 1 )); } || \
    { printf '  FAIL: no paste at max attempts — silent drop is a latch (paste log: %s)\n' "$(cat "$PASTE_LOG")" >&2; FAIL=$(( FAIL + 1 )); }

echo '=== wake: max attempts fail-open is bounded — orchestrator paused gate reopens ==='
# After the fail-open drop the paused predicate must be FALSE (the
# emit gate reopens even though the pane still reads over-limit).
reset_state
rm -f "$STATE_DIR/machine-input.tsv"
export MOCK_TMUX_WINDOWS="orchestrator|2"
export MOCK_PANE_STATE_2=over-limit
export MOCK_PANE_RESET_AT_2='3am'
synth_row "_orchestrator" "orchestrator" "orchestrator" "3am" \
    $(( NOW - 60 )) $(( NOW - 600 )) $(( NOW - 1 )) 9
_over_limit_orchestrator_paused || { printf '  FAIL: precondition — gate not paused\n' >&2; FAIL=$(( FAIL + 1 )); }
MONITOR_OVER_LIMIT_MAX_ATTEMPTS=10 _over_limit_process_wakes "orchestrator"
if _over_limit_orchestrator_paused; then
    printf '  FAIL: gate still paused after fail-open — emits would stay suppressed\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: gate reopened after fail-open\n'
    PASS=$(( PASS + 1 ))
fi
grep -q "orchestrator" "$PASTE_LOG" && \
    { printf '  PASS: orchestrator wake brief pasted on fail-open\n'; PASS=$(( PASS + 1 )); } || \
    { printf '  FAIL: orchestrator fail-open paste missing\n' >&2; FAIL=$(( FAIL + 1 )); }

echo '=== wake: resumed orchestrator → paste brief + drop ==='
reset_state
rm -f "$STATE_DIR/machine-input.tsv"
export MOCK_TMUX_WINDOWS="orchestrator|2"
export MOCK_PANE_STATE_2=idle
export MOCK_PANE_RESET_AT_2=''
synth_row "_orchestrator" "orchestrator" "orchestrator" "3am_America/Los_Angeles" \
    $(( NOW - 60 )) $(( NOW - 1800 )) $(( NOW - 1 )) 1
_over_limit_process_wakes "orchestrator"
_over_limit_load "_orchestrator" >/dev/null \
    && { printf '  FAIL: row not dropped on resume\n' >&2; FAIL=$(( FAIL + 1 )); } \
    || { printf '  PASS: row dropped on resume\n'; PASS=$(( PASS + 1 )); }
assert_contains "paste lands on TARGET window" "$(cat "$PASTE_LOG")" "orchestrator"
assert_contains "brief explains what happened" "$(cat "$PASTE_LOG")" "WHAT HAPPENED"
assert_contains "brief flags usage-limit recovery" "$(cat "$PASTE_LOG")" "USAGE-LIMIT RECOVERY"
# Orchestrator wakes must NOT stamp machine-input.tsv: the orchestrator
# window is not retire-gated (#293, inventory rows 8/9). A stamp here
# would be harmless but is deliberately omitted to match the existing
# unstamped orchestrator-pane paths.
if [[ -f "$STATE_DIR/machine-input.tsv" ]] && \
   grep -q $'orchestrator\t' "$STATE_DIR/machine-input.tsv"; then
    printf '  FAIL: orchestrator wake stamped machine-input.tsv (should not)\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: orchestrator wake does not stamp machine-input.tsv\n'
    PASS=$(( PASS + 1 ))
fi

echo '=== wake: resumed WORKER stamps machine-input ledger (src=over-limit-wake) ==='
# Issue #293, gap row 6: the watcher-initiated worker-wake paste must
# stamp the machine-input ledger BEFORE pasting, so the worker's
# resulting UserPromptSubmit is attributed to the MACHINE, not the
# operator. Before this fix the wake left machine_epoch stale → false
# operator-engaged mark → retire-preflight held at safe=0.
reset_state
rm -f "$STATE_DIR/machine-input.tsv"
export MOCK_TMUX_WINDOWS="worker-a|3"
export MOCK_PANE_STATE_3=idle
export MOCK_PANE_RESET_AT_3=''
synth_row "worker-a" "worker-a" "worker" "3am" \
    $(( NOW - 60 )) $(( NOW - 1800 )) $(( NOW - 1 )) 1
WAKE_NOW=$(date +%s)
_over_limit_process_wakes "orchestrator"
assert_contains "worker wake stamped machine-input.tsv" \
    "$(cat "$STATE_DIR/machine-input.tsv" 2>/dev/null)" $'worker-a\t'
assert_eq "worker wake stamp names its source" \
    "$(awk -F'\t' '$1=="worker-a" {print $3}' "$STATE_DIR/machine-input.tsv" 2>/dev/null)" \
    "over-limit-wake"
# Consumer check: a UserPromptSubmit at wake time is attributed MACHINE
# (the retire-preflight rule: up_epoch <= machine_epoch + slack(120)).
machine_epoch=$(_openg_machine_input_epoch "worker-a")
up_epoch=$WAKE_NOW
if [[ "$machine_epoch" =~ ^[0-9]+$ ]] && (( machine_epoch > 0 )) \
   && (( up_epoch <= machine_epoch + 120 )); then
    printf '  PASS: post-wake submit attributed machine (up=%s machine=%s)\n' \
        "$up_epoch" "$machine_epoch"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: post-wake submit NOT attributed machine (up=%s machine=%s)\n' \
        "$up_epoch" "$machine_epoch" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo '=== wake: orchestrator resume names queued workers ==='
reset_state
export MOCK_TMUX_WINDOWS="$(printf 'orchestrator|2\nworker-a|3\nworker-b|4')"
export MOCK_PANE_STATE_2=idle
export MOCK_PANE_STATE_3=over-limit
export MOCK_PANE_RESET_AT_3='3am'
export MOCK_PANE_STATE_4=over-limit
export MOCK_PANE_RESET_AT_4='3am'
# Existing stamps for workers (still suspended).
synth_row "worker-a" "worker-a" "worker" "3am" \
    $(( NOW + 1800 )) $(( NOW - 600 )) $(( NOW + 1800 )) 0
synth_row "worker-b" "worker-b" "worker" "3am" \
    $(( NOW + 1800 )) $(( NOW - 600 )) $(( NOW + 1800 )) 0
synth_row "_orchestrator" "orchestrator" "orchestrator" "3am" \
    $(( NOW - 60 )) $(( NOW - 1800 )) $(( NOW - 1 )) 1
_over_limit_process_wakes "orchestrator"
brief=$(cat "$PASTE_LOG")
assert_contains "brief lists worker-a in queue" "$brief" "worker-a"
assert_contains "brief lists worker-b in queue" "$brief" "worker-b"
# Workers should still be stamped (they're still over-limit).
_over_limit_load "worker-a" >/dev/null \
    && { printf '  PASS: worker-a stamp survives orchestrator resume\n'; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: worker-a stamp lost\n' >&2; FAIL=$(( FAIL + 1 )); }

echo '=== wake: pane-absent → drop stamp ==='
reset_state
export MOCK_TMUX_WINDOWS="worker-a|3"
export MOCK_PANE_STATE_3=absent
synth_row "worker-a" "worker-a" "worker" "3am" \
    $(( NOW - 60 )) $(( NOW - 600 )) $(( NOW - 1 )) 2
_over_limit_process_wakes "orchestrator"
_over_limit_load "worker-a" >/dev/null \
    && { printf '  FAIL: row survived pane-absent wake\n' >&2; FAIL=$(( FAIL + 1 )); } \
    || { printf '  PASS: row dropped on pane-absent\n'; PASS=$(( PASS + 1 )); }
[[ -s "$PASTE_LOG" ]] && { printf '  FAIL: paste fired on pane-absent\n' >&2; FAIL=$(( FAIL + 1 )); } \
                     || { printf '  PASS: no paste on pane-absent\n'; PASS=$(( PASS + 1 )); }

echo '=== wake: window missing from tmux → drop stamp ==='
reset_state
export MOCK_TMUX_WINDOWS=""
synth_row "worker-ghost" "worker-ghost" "worker" "3am" \
    $(( NOW - 60 )) $(( NOW - 600 )) $(( NOW - 1 )) 2
_over_limit_process_wakes "orchestrator"
_over_limit_load "worker-ghost" >/dev/null \
    && { printf '  FAIL: row survived missing window\n' >&2; FAIL=$(( FAIL + 1 )); } \
    || { printf '  PASS: row dropped on window-absent\n'; PASS=$(( PASS + 1 )); }

echo '=== wake: paste failure → retry next cycle without consuming attempt ==='
reset_state
export MOCK_TMUX_WINDOWS="worker-a|3"
export MOCK_PANE_STATE_3=idle
synth_row "worker-a" "worker-a" "worker" "3am" \
    $(( NOW - 60 )) $(( NOW - 1800 )) $(( NOW - 1 )) 2
PASTE_RC=1 _over_limit_process_wakes "orchestrator"
row=$(_over_limit_load "worker-a")
[[ -n "$row" ]] && { printf '  PASS: row retained on paste failure\n'; PASS=$(( PASS + 1 )); } \
                || { printf '  FAIL: row dropped on paste failure\n' >&2; FAIL=$(( FAIL + 1 )); }
attempts=$(awk -F'\t' '{print $8}' <<<"$row")
assert_eq "attempts unchanged on paste failure" "$attempts" "2"
grep -q "paste failed; will retry" "$LOG_LOG" && \
    { printf '  PASS: paste-failure log emitted\n'; PASS=$(( PASS + 1 )); } || \
    { printf '  FAIL: paste-failure log missing\n' >&2; FAIL=$(( FAIL + 1 )); }

# ---- ANTI-LATCH: refined-idle + unknown states must terminate the hold ---
# Skeptic finding (PR #526 round 1): the three refined-idle states
# (#183) and any unrecognised state fell into the old `*)` branch, which
# backed off FOREVER with no max-attempts check — the emit gate could
# latch closed indefinitely on a recovered orchestrator holding a Monitor
# handle. These cases prove no state can suppress emits forever.
echo '=== ANTI-LATCH: refined-idle states resolve the hold (resumption) ==='
for st in working-background working-self-paced idle-orphan-async; do
    reset_state
    rm -f "$STATE_DIR/machine-input.tsv"
    export MOCK_TMUX_WINDOWS="orchestrator|2"
    export MOCK_PANE_STATE_2="$st"
    export MOCK_PANE_RESET_AT_2=''
    # A row that has ALREADY exhausted attempts (attempts=9): under the
    # old code this would keep backing off; now it must resolve on the
    # FIRST wake because the state is treated as resumption.
    synth_row "_orchestrator" "orchestrator" "orchestrator" "3am_America/Los_Angeles" \
        $(( NOW - 60 )) $(( NOW - 1800 )) $(( NOW - 1 )) 9
    _over_limit_process_wakes "orchestrator"
    if _over_limit_orchestrator_paused; then
        printf '  FAIL: state=%s still holds the gate closed (LATCH)\n' "$st" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: state=%s resolves the hold (gate reopened)\n' "$st"
        PASS=$(( PASS + 1 ))
    fi
    grep -q "orchestrator" "$PASTE_LOG" \
        && { printf '  PASS: state=%s pasted the resume brief\n' "$st"; PASS=$(( PASS + 1 )); } \
        || { printf '  FAIL: state=%s did not paste a resume brief\n' "$st" >&2; FAIL=$(( FAIL + 1 )); }
done

echo '=== ANTI-LATCH: unknown state is bounded (fail-open at MAX_ATTEMPTS) ==='
reset_state
rm -f "$STATE_DIR/machine-input.tsv"
export MOCK_TMUX_WINDOWS="orchestrator|2"
export MOCK_PANE_STATE_2="some-future-state"
export MOCK_PANE_RESET_AT_2='3am'
# attempts=9 → next bump ≥ MAX_ATTEMPTS(4) → must fail OPEN, not back off.
synth_row "_orchestrator" "orchestrator" "orchestrator" "3am" \
    $(( NOW - 60 )) $(( NOW - 600 )) $(( NOW - 1 )) 9
MONITOR_OVER_LIMIT_MAX_ATTEMPTS=10 _over_limit_process_wakes "orchestrator"
# With the cap pinned above the attempt count, one wake should NOT
# terminate — but it MUST have bumped attempts (bounded progress), not
# sat still. Then drive it past the cap and require fail-open.
reset_state
export MOCK_TMUX_WINDOWS="orchestrator|2"
export MOCK_PANE_STATE_2="some-future-state"
export MOCK_PANE_RESET_AT_2='3am'
synth_row "_orchestrator" "orchestrator" "orchestrator" "3am" \
    $(( NOW - 60 )) $(( NOW - 600 )) $(( NOW - 1 )) 9
_over_limit_process_wakes "orchestrator"   # default cap 4; 9→10 ≥ 4 → fail open
if _over_limit_orchestrator_paused; then
    printf '  FAIL: unknown state latched the gate closed (no fail-open)\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: unknown state fails open at the attempt cap (gate reopened)\n'
    PASS=$(( PASS + 1 ))
fi
grep -q "failing OPEN" "$LOG_LOG" \
    && { printf '  PASS: unknown-state fail-open logged\n'; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: unknown-state fail-open not logged\n' >&2; FAIL=$(( FAIL + 1 )); }

echo '=== ANTI-LATCH: absolute hold ceiling bounds a persistently-failing probe ==='
# Skeptic round-2 residual: a pane-state probe that returns EMPTY (a
# BROKEN pane-state.sh — not any pane state) hits the probe-failure
# branch, which backs off without consuming an attempt → retries every
# 60s forever with the gate closed. The absolute ceiling
# (MONITOR_OVER_LIMIT_MAX_HOLD_SECONDS) must fail this open regardless.
# Swap in a pane-state.sh that emits NOTHING (the broken-resolver shape)
# so _over_limit_probe_pane genuinely returns empty; restore after.
cat > "$WORK/monitor/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$WORK/monitor/pane-state.sh"
reset_state
rm -f "$STATE_DIR/machine-input.tsv"
export MOCK_TMUX_WINDOWS="orchestrator|2"
# Row whose first_seen is WAY past the ceiling (26h ago > 25h default).
synth_row "_orchestrator" "orchestrator" "orchestrator" "3am_America/Los_Angeles" \
    $(( NOW - 60 )) $(( NOW - 26*3600 )) $(( NOW - 1 )) 3
_over_limit_process_wakes "orchestrator"
if _over_limit_orchestrator_paused; then
    printf '  FAIL: probe-failure past ceiling still holds the gate (LATCH)\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: hold past absolute ceiling fails open (gate reopened)\n'
    PASS=$(( PASS + 1 ))
fi
grep -q "absolute ceiling" "$LOG_LOG" \
    && { printf '  PASS: ceiling fail-open logged\n'; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: ceiling fail-open not logged\n' >&2; FAIL=$(( FAIL + 1 )); }
# A row INSIDE the ceiling with a failing probe must NOT fail open yet
# (it retries — the ceiling must not prematurely eat a live hold).
reset_state
export MOCK_TMUX_WINDOWS="orchestrator|2"
synth_row "_orchestrator" "orchestrator" "orchestrator" "3am_America/Los_Angeles" \
    $(( NOW - 60 )) $(( NOW - 3600 )) $(( NOW - 1 )) 1
_over_limit_process_wakes "orchestrator"
if _over_limit_orchestrator_paused; then
    printf '  PASS: probe-failure inside ceiling still holds (retry, no premature fail-open)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: hold inside ceiling dropped prematurely\n' >&2
    FAIL=$(( FAIL + 1 ))
fi
# Restore the normal reading stub for subsequent tests.
cp "$STUB_DIR/pane-state.sh" "$WORK/monitor/pane-state.sh"
chmod +x "$WORK/monitor/pane-state.sh"

# ---- off-time log (operator ask, your-nexus#275) ------------------------
echo '=== off-time log: fresh orchestrator hold starts it; record appends ==='
reset_state
rm -f "$(_over_limit_held_log_path)"
# A fresh _orchestrator record (no prior row) must start the log.
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am_America/Los_Angeles"
held=$(_over_limit_held_log_path)
[[ -f "$held" ]] \
    && { printf '  PASS: fresh orchestrator hold starts the off-time log\n'; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: off-time log not started\n' >&2; FAIL=$(( FAIL + 1 )); }
grep -q "hold began" "$held" 2>/dev/null \
    && { printf '  PASS: off-time log carries a hold-start header\n'; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: off-time log header missing\n' >&2; FAIL=$(( FAIL + 1 )); }
_over_limit_record_held "2026-07-15_11-00-00_abc123.md" "poll-resurface"
_over_limit_record_held "2026-07-15_11-01-00_def456.md" "poll-full-state"
n=$(grep -c $'\theld\t' "$held" 2>/dev/null || echo 0)
[[ "$n" == "2" ]] \
    && { printf '  PASS: two held emits recorded (n=%s)\n' "$n"; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: expected 2 held records, got %s\n' "$n" >&2; FAIL=$(( FAIL + 1 )); }
# A REFRESH of the same hold must NOT truncate the log (progress preserved).
_over_limit_record "_orchestrator" "orchestrator" "orchestrator" "3am_America/Los_Angeles"
n2=$(grep -c $'\theld\t' "$held" 2>/dev/null || echo 0)
[[ "$n2" == "2" ]] \
    && { printf '  PASS: hold refresh preserves the off-time log\n'; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: hold refresh clobbered the log (n=%s)\n' "$n2" >&2; FAIL=$(( FAIL + 1 )); }

echo '=== off-time log: resume brief points at it + explains what happened ==='
brief=$(_over_limit_compose_resume_brief "3am_America/Los_Angeles" 3661 "worker-a" "$(( NOW - 3661 ))")
assert_contains "brief names the off-time log path" "$brief" "over-limit-held.log"
assert_contains "brief has WHAT HAPPENED section"   "$brief" "WHAT HAPPENED"
assert_contains "brief has STATE NOW section"       "$brief" "STATE NOW"
assert_contains "brief has LOG OF THE OFF-TIME"     "$brief" "LOG OF THE OFF-TIME"
assert_contains "brief prints explicit T0 window"   "$brief" "The hold ran from"

# ---- compose_resume_brief shape ------------------------------------------

echo '=== compose_resume_brief formatting ==='
brief=$(_over_limit_compose_resume_brief "3am_America/Los_Angeles" 3661 "worker-a,worker-b")
assert_contains "brief pretty-prints reset_at"     "$brief" "3am (America/Los_Angeles)"
assert_contains "brief includes duration h:m:s"    "$brief" "1h 01m 01s"
assert_contains "brief names queued workers"       "$brief" "worker-a,worker-b"
assert_contains "brief points at snapshot path"    "$brief" "monitor/.state"

brief=$(_over_limit_compose_resume_brief "3am" 120 "")
assert_contains "no-workers brief omits queue line" "$brief" "No workers were suspended"

th_summary_and_exit
