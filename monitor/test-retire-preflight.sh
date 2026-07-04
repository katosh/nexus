#!/usr/bin/env bash
# Tests for monitor/retire-preflight.sh — the synchronous pre-kill
# go/no-go gate that closes the 2026-06-15 retire-the-just-re-engaged-
# window race (see the script header).
#
# Run: bash monitor/test-retire-preflight.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# The contract under test:
#   GO   (safe=1, exit 0): the window is genuinely wrapped/quiet — no
#        fresh operator submit, no valid engagement mark, pane idle.
#   NO-GO (safe=0, exit 1): ANY of —
#        (a) the pane shows the operator typing right now (user-typing),
#            or work in flight (busy / working-*), or an overlay
#            (blocked), or pane-state could not be read (unknown);
#        (b) a fresh operator-attributed UserPromptSubmit stamp newer
#            than any machine input — read DIRECTLY off the raw stamp so
#            it counts before the watcher poll attributes it (THE
#            incident fix);
#        (c) a valid operator-engaged mark in operator-engaged.tsv.
#   Exit 2 on bad usage; exit 3 on a window absent from tmux.
#
# pane-state is injected via --pane-state so the suite is hermetic (no
# tmux, no real Claude pane). The state-file checks run against the REAL
# monitor/watcher/_idle_probe.sh helpers the script sources, so the test
# exercises the production attribution + mark-validity logic.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFLIGHT="$_test_dir/retire-preflight.sh"

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
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing %q\n  in: <<%s>>\n' "$label" "$needle" "$hay" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness -------------------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"

NOW=$(date +%s)

# Run the preflight; capture stdout + rc into named vars.
run_preflight() {
    local _out_var="$1" _rc_var="$2"; shift 2
    local _out _rc
    _out=$(bash "$PREFLIGHT" "$@" --state-dir "$STATE_DIR" --now "$NOW" 2>/dev/null)
    _rc=$?
    printf -v "$_out_var" '%s' "$_out"
    printf -v "$_rc_var" '%s' "$_rc"
}

# Stamp a raw UserPromptSubmit (what worker-heartbeat.sh writes from the
# UserPromptSubmit hook). `epoch<TAB>session-id`.
stamp_user_prompt() {
    local window="$1" epoch="$2"
    printf '%s\ttest-session\n' "$epoch" > "$STATE_DIR/user-prompt/$window"
}
# Stamp a machine input (what paste-followup.sh writes BEFORE pasting).
stamp_machine_input() {
    local window="$1" epoch="$2" src="${3:-paste-followup}"
    printf '%s\t%s\t%s\n' "$window" "$epoch" "$src" >> "$STATE_DIR/machine-input.tsv"
}
# Seed a valid operator-engaged mark: tsv row + a recent pane-change stamp
# (so _openg_marked's self-expiry corroboration holds).
seed_engaged_mark() {
    local window="$1" since="$2" last="$3" change_epoch="$4"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$window" "$since" "$last" "$last" "submit" "0" \
        >> "$STATE_DIR/operator-engaged.tsv"
    printf 'deadbeef\t%s\n' "$change_epoch" > "$STATE_DIR/pane-change/$window"
}
reset_state() {
    rm -rf "$STATE_DIR"
    mkdir -p "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"
}

OUT=""; RC=""

# ── 1. GO: genuinely wrapped + quiet ──────────────────────────────────────
echo "## 1. wrapped + quiet → GO"
reset_state
run_preflight OUT RC quiet-win --pane-state idle
assert_eq      "exit 0 (go)"        "$RC"  "0"
assert_contains "safe=1"            "$OUT" "safe=1"

# ── 2. NO-GO: operator typing in the box right now ────────────────────────
echo "## 2. pane user-typing → NO-GO"
reset_state
run_preflight OUT RC type-win --pane-state user-typing
assert_eq      "exit 1 (no-go)"     "$RC"  "1"
assert_contains "safe=0"            "$OUT" "safe=0"
assert_contains "reason cites typing" "$OUT" "typing"

# ── 3. NO-GO: THE incident — fresh operator submit, no machine paste ──────
#     Mirrors 2026-06-15: wrap logged, then an operator UserPromptSubmit
#     9 s before the kill, no covering paste-followup. The raw stamp is
#     read directly, so it fires even though no poll attributed it.
echo "## 3. fresh operator submit, no machine input → NO-GO (incident)"
reset_state
stamp_user_prompt incident-win "$(( NOW - 9 ))"
run_preflight OUT RC incident-win --pane-state idle
assert_eq      "exit 1 (no-go)"     "$RC"  "1"
assert_contains "safe=0"            "$OUT" "safe=0"
assert_contains "reason cites fresh submit" "$OUT" "fresh operator submit"

# ── 4. GO: submit covered by a recent machine paste (orchestrator nudge) ──
echo "## 4. submit attributable to machine paste → GO"
reset_state
stamp_user_prompt nudge-win   "$(( NOW - 9 ))"
stamp_machine_input nudge-win "$(( NOW - 10 ))" paste-followup
run_preflight OUT RC nudge-win --pane-state idle
assert_eq      "exit 0 (go)"        "$RC"  "0"
assert_contains "safe=1"            "$OUT" "safe=1"

# ── 5. GO: stale operator submit beyond the freshness window ──────────────
#     A 2 h-old, already-handled submit must not pin the window open.
echo "## 5. stale operator submit (beyond freshness) → GO"
reset_state
stamp_user_prompt stale-win "$(( NOW - 7200 ))"
run_preflight OUT RC stale-win --pane-state idle
assert_eq      "exit 0 (go)"        "$RC"  "0"
assert_contains "safe=1"            "$OUT" "safe=1"

# ── 5b. NO-GO: same stale submit but a wider freshness window covers it ───
echo "## 5b. stale submit + --fresh-seconds widened → NO-GO"
reset_state
stamp_user_prompt stale-win "$(( NOW - 7200 ))"
OUT=$(bash "$PREFLIGHT" stale-win --state-dir "$STATE_DIR" --now "$NOW" \
        --pane-state idle --fresh-seconds 99999 2>/dev/null); RC=$?
assert_eq      "exit 1 (no-go)"     "$RC"  "1"
assert_contains "safe=0"            "$OUT" "safe=0"

# ── 6. NO-GO: a valid operator-engaged mark (poll already attributed) ─────
echo "## 6. valid operator-engaged mark → NO-GO"
reset_state
seed_engaged_mark engaged-win "$(( NOW - 300 ))" "$(( NOW - 120 ))" "$(( NOW - 30 ))"
run_preflight OUT RC engaged-win --pane-state idle
assert_eq      "exit 1 (no-go)"     "$RC"  "1"
assert_contains "safe=0"            "$OUT" "safe=0"
assert_contains "reason cites engaged mark" "$OUT" "operator-engaged mark"

# ── 6b. GO: engaged row present but mark self-expired (pane static) ───────
#     change stamp older than the change-TTL (600 s) → mark lapsed →
#     the window is retire-eligible again.
echo "## 6b. engaged row but mark self-expired → GO"
reset_state
seed_engaged_mark expired-win "$(( NOW - 5000 ))" "$(( NOW - 4000 ))" "$(( NOW - 3000 ))"
run_preflight OUT RC expired-win --pane-state idle
assert_eq      "exit 0 (go)"        "$RC"  "0"
assert_contains "safe=1"            "$OUT" "safe=1"

# ── 7. NO-GO: busy / working / blocked / unknown pane states ──────────────
echo "## 7. active / unverifiable pane states → NO-GO"
reset_state
for st in busy working-background working-self-paced blocked unknown; do
    run_preflight OUT RC act-win --pane-state "$st"
    assert_eq      "exit 1 for pane=$st" "$RC" "1"
    assert_contains "safe=0 for pane=$st" "$OUT" "safe=0"
done

# ── 8. GO: harmless idle-family pane states with no operator signal ───────
echo "## 8. idle-family pane states → GO"
reset_state
for st in idle autosuggest-only empty absent; do
    run_preflight OUT RC idle-win --pane-state "$st"
    assert_eq      "exit 0 for pane=$st" "$RC" "0"
    assert_contains "safe=1 for pane=$st" "$OUT" "safe=1"
done

# ── 9. usage / arg handling ───────────────────────────────────────────────
echo "## 9. bad usage → exit 2"
bash "$PREFLIGHT" --state-dir "$STATE_DIR" >/dev/null 2>&1; RC=$?
assert_eq "no window arg → exit 2" "$RC" "2"

# ── 9b. NO-GO: a live required-skeptic pending marker (F2 enforcement) ────
#     skills/nexus.skeptic writes $STATE_DIR/skeptic/pending/<window> when
#     a wrap-up requires an independent skeptic pass. While it persists,
#     the task is NOT done → the kill must be refused even on an otherwise
#     idle, operator-quiet pane. This is what makes `require` a hard gate.
echo "## 9b. live skeptic-pending marker → NO-GO"
reset_state
mkdir -p "$STATE_DIR/skeptic/pending"
echo 1 > "$STATE_DIR/skeptic/pending/pending-skeptic-win"
run_preflight OUT RC pending-skeptic-win --pane-state idle
assert_eq      "exit 1 (no-go)"     "$RC"  "1"
assert_contains "safe=0"            "$OUT" "safe=0"
assert_contains "reason cites pending skeptic" "$OUT" "skeptic-pending marker live"
# Once the skeptic returns a verdict (marker cleared) the same window is
# retire-eligible again.
rm -f "$STATE_DIR/skeptic/pending/pending-skeptic-win"
run_preflight OUT RC pending-skeptic-win --pane-state idle
assert_eq      "marker cleared -> exit 0 (go)" "$RC"  "0"
assert_contains "marker cleared -> safe=1"     "$OUT" "safe=1"

# ── 10. machine-attributed submit within slack (clock-skew absorption) ────
echo "## 10. submit within attribution slack of machine input → GO"
reset_state
# machine paste 100 s OLDER than the submit, still inside the 120 s slack.
stamp_user_prompt skew-win   "$(( NOW - 9 ))"
stamp_machine_input skew-win "$(( NOW - 109 ))" paste-followup
run_preflight OUT RC skew-win --pane-state idle
assert_eq      "exit 0 (go)"        "$RC"  "0"
assert_contains "safe=1"            "$OUT" "safe=1"

# ── 11. skeptic-channel answer is machine/protocol input, NOT operator ────
#     Bug 1: a worker answering a skeptic question (skeptic-channel.sh
#     stamps machine-input src `skeptic-answer`/`skeptic-await-ack`) must
#     NOT be misread as a fresh operator submit. The submit around the
#     answer is covered by the channel stamp → GO. This is the recurring
#     false `operator-engaged` blocker the fix removes.
echo "## 11. submit covered by a skeptic-channel answer stamp → GO"
reset_state
stamp_user_prompt chan-win   "$(( NOW - 9 ))"
stamp_machine_input chan-win "$(( NOW - 10 ))" skeptic-answer
run_preflight OUT RC chan-win --pane-state idle
assert_eq      "exit 0 (go)"        "$RC"  "0"
assert_contains "safe=1"            "$OUT" "safe=1"
# Same for the await-ack stamp.
reset_state
stamp_user_prompt ack-win   "$(( NOW - 9 ))"
stamp_machine_input ack-win "$(( NOW - 10 ))" skeptic-await-ack
run_preflight OUT RC ack-win --pane-state idle
assert_eq      "ack stamp -> exit 0 (go)" "$RC"  "0"
assert_contains "ack stamp -> safe=1"     "$OUT" "safe=1"

# ── 11b. NO false NEGATIVE: a REAL operator submit during a skeptic ───────
#     exchange (no channel stamp covering THIS submit) STILL registers as
#     engaged. The skeptic mandate: never retire a window the operator is
#     driving. A stale channel stamp (200 s old, beyond the 120 s slack)
#     does NOT explain a fresh operator submit.
echo "## 11b. fresh operator submit beyond a stale channel stamp → NO-GO"
reset_state
stamp_user_prompt opdrive-win   "$(( NOW - 9 ))"
stamp_machine_input opdrive-win "$(( NOW - 200 ))" skeptic-answer
run_preflight OUT RC opdrive-win --pane-state idle
assert_eq      "exit 1 (no-go)"     "$RC"  "1"
assert_contains "safe=0"            "$OUT" "safe=0"
assert_contains "reason cites fresh submit" "$OUT" "fresh operator submit"

# ---- summary -------------------------------------------------------------
echo
printf 'retire-preflight: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
