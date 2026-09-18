#!/usr/bin/env bash
# Tests for the STALE OVER-LIMIT STAMP defect (your-org/nexus-code#1141).
#
# THE DEFECT, measured on the production board 2026-08-28, window `devred`:
#
#     stamp written (StopFailure, rate_limit)   12:42:52   reset_at 1:40pm
#     watcher observed alive (state=busy)       12:56:05
#     watcher pasted a resume brief             12:56:07
#     heartbeat: event=PostToolUse              13:06:00   (still that turn)
#     pane-state STILL emitting over-limit      13:02+
#
# `pane-state.sh` 1b short-circuits to `over-limit` on the hook-written stamp
# and exits BEFORE any liveness inspection. The stamp's only clear is the Stop
# hook on the next SUCCESSFUL turn — which had not arrived, and was not
# supposed to have: the pane was ten-plus minutes into ONE turn. The watcher
# then re-stamped the window and pasted a SECOND resume brief 62 s after the
# first; five windows looped that way and 63 emits were held in an hour.
#
# The Stop hook is NOT broken. Independently established at the time: 120 of
# 1838 heartbeat files carry `last_turn_end`, written by a sibling command in
# the same Stop block; and monitor/.state/decisions/devred.031312e9c5c4.json,
# written 12:43:52, carries neither `unresolved` nor `resolved`, which dates
# the last Stop to before that. The clear CONTRACT is the defect.
#
# Coverage, by layer:
#
#   A. pane-state.sh 1b — THE OWNER. Post-stamp model activity invalidates the
#      stamp. Two RECORDED epochs compared; no clock, no TTL, no reset_at,
#      because the operator lifted this limit an hour early by signing into a
#      different account and no wall-clock rule can see that.
#
#   B. monitor/watcher/_over_limit.sh — DEFENCE IN DEPTH. pane-state is not the
#      only thing that can hand the watcher a wrong answer; in particular the
#      1c RENDERER SCRAPE carries no `ts` for layer A to compare against, so a
#      banner sitting above live output in the bottom-15 rows is still able to
#      produce a stale read. The watcher's liveness gate is what covers that.
#
#   C. The measured loop itself, end to end: one banner instance must produce
#      exactly ONE resume brief.
#
# TWO negative controls carry this file, not one. A3/A4 cover the door that
# was REASONED about (`UserPromptSubmit`); A5/A5b cover the one that had to be
# COUNTED (`Notification`, 6766 of 6791 payloads being idle_prompt). The second
# escaped review precisely because it was inside the allowlist rather than
# outside it, and because its name suggests model activity. Reasoning about
# what an event sounds like is what produced the hole; counting the population
# is what closed it.
#
# NEGATIVE CONTROLS ARE THE POINT OF THIS FILE. A gate that never fires is
# this corpus's most common defect, and here the sharpest failure mode is a
# rule that certifies its own intervention: `UserPromptSubmit` writes the
# heartbeat, so the watcher's OWN resume paste advances `last_activity`. If
# that counted as evidence, the gate would clear the stamp of a genuinely
# frozen pane using a record of itself. A3/A4 are that test.
#
# Run: bash monitor/watcher/test-over-limit-stale-stamp.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
PS="$_repo_root/monitor/pane-state.sh"
HELPER="$_repo_root/monitor/watcher/_over_limit.sh"
IDLE="$_repo_root/monitor/watcher/_idle_probe.sh"
LIB="$_repo_root/monitor/watcher/_lib.sh"
FIX_DIR="$_test_dir/fixtures"
for f in "$PS" "$HELPER" "$IDLE" "$LIB"; do
    [[ -f "$f" ]] || { echo "not found: $f" >&2; exit 1; }
done

. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ============================================================================
# A. pane-state.sh 1b — post-stamp model activity invalidates the stamp
# ============================================================================
#
# NOTE ON CLOCK CHOICE, because it is what makes these tests exercise 1b at
# all. The heartbeat is deliberately STALE for CLASSIFICATION (older than the
# 30 s `_HEARTBEAT_STALENESS_DEFAULT`) while being NEWER THAN THE STAMP. A
# fresh heartbeat would be answered by step 0 and exit before 1b is reached,
# so a naively-written "busy heartbeat" test would pass on the broken tree
# without ever touching the code under test. That gap between the two horizons
# — 30 s to classify, 27 h to believe a stamp — IS the defect.

echo '=== A. pane-state 1b: post-stamp model activity invalidates the stamp ==='

A_NOW=1800000000
A_FIX="$FIX_DIR/busy-orchestrator-win1.ansi"
[[ -f "$A_FIX" ]] || { echo "needs $A_FIX" >&2; exit 1; }
a_stamp="$WORK/a-stamp.json"
a_hb="$WORK/a-hb.json"

a_write_stamp() {   # $1 = ts. reset_at is deliberately a FUTURE wall-clock time.
    printf '{"ts":%s,"session_id":"sess","error_type":"rate_limit","error_message":"monthly spend limit","reset_at":"1:40pm_America/Los_Angeles","window":"olwin","hook_event_name":"StopFailure"}\n' \
        "$1" > "$a_stamp"
}
a_write_hb() {      # $1 = last_activity, $2 = event ("" ⇒ omit the field), $3 = state
    if [[ -z "$2" ]]; then
        printf '{"state":"%s","last_activity":%s,"window":"olwin"}\n' "$3" "$1" > "$a_hb"
    else
        printf '{"state":"%s","last_activity":%s,"event":"%s","window":"olwin"}\n' "$3" "$1" "$2" > "$a_hb"
    fi
}
a_run() {
    "$PS" --fixture "$A_FIX" --window 9 --name olwin --active 0 --now "$A_NOW" \
          --over-limit-file "$a_stamp" --heartbeat-file "$a_hb" 2>&1
}
a_state() { awk -F'[ =]' '{print $2}' <<<"$1"; }

# --- A1/A2: THE EXACT devred STATE. Stamp an hour old, reset_at still in the
#     future, heartbeat two minutes old (stale to classify, 3480 s newer than
#     the stamp) recording a tool call that RAN — so the model answered.
a_write_stamp $(( A_NOW - 3600 ))
a_write_hb    $(( A_NOW - 120 )) "PostToolUse" "busy"
out=$(a_run)
assert_eq "A1 PostToolUse after the stamp ⇒ NOT over-limit (falls through to the live pane)" \
    "$(a_state "$out")" "busy"
assert_no_file "A2 contradicted stamp is deleted, so the question is not re-posed every 60s" \
    "$a_stamp"

# --- A3/A4: THE LOAD-BEARING NEGATIVE CONTROL. Identical timings; the only
#     variable is WHICH event advanced the heartbeat. `UserPromptSubmit` is
#     what the watcher's own resume paste into a still-frozen pane produces.
#     If this clears the stamp, the rule is certifying its own intervention.
a_write_stamp $(( A_NOW - 3600 ))
a_write_hb    $(( A_NOW - 120 )) "UserPromptSubmit" "user_prompt"
out=$(a_run)
assert_eq "A3 UserPromptSubmit after the stamp ⇒ STILL over-limit (our own paste is not evidence)" \
    "$(a_state "$out")" "over-limit"
assert_file_exists "A4 …and the stamp SURVIVES a paste into a frozen pane" "$a_stamp"

# --- A5: THE SECOND NEGATIVE CONTROL, and the one that got away first time.
#     `Notification`/`idle_prompt` is Claude Code's "Claude is waiting for your
#     input" and fires from IDLENESS ~60 s after a pane goes quiet. A SUSPENDED
#     pane is quiet, so it emits one WHILE SUSPENDED. Measured on this board:
#     6791 captured Notification payloads, 6766 idle_prompt vs 25
#     permission_prompt; and `devred`'s own stamp (ts 1787946172) is followed
#     by one at +60 s, thirteen minutes before the watcher first observed that
#     pane alive.
#
#     This assertion previously asserted the OPPOSITE, on the reasoning that a
#     Notification "follows a model turn". It does not. Admitting it destroyed
#     the structured stamp ~60 s into every genuine suspension. A3/A4 could not
#     catch it: they vary `UserPromptSubmit`, the door that was reasoned about,
#     while the escape was through a member of the allowlist. Hence this arm —
#     the rule must exclude an event whose NAME suggests model activity and
#     whose measured population is idleness.
a_write_stamp $(( A_NOW - 3600 ))
a_write_hb    $(( A_NOW - 120 )) "Notification" "idle_prompt"
out=$(a_run)
assert_eq "A5 Notification/idle_prompt ⇒ STILL over-limit (it fires FROM idleness, not from a model turn)" \
    "$(a_state "$out")" "over-limit"
assert_file_exists "A5b …and a suspended pane's stamp survives its own idle notification" "$a_stamp"

# --- A5c: …but the arm is not DEAD. The permission variant of the same event
#     does invalidate: a permission modal presupposes a tool call the model
#     emitted. Without this, gating Notification would be indistinguishable
#     from deleting it, and a never-firing arm is the defect this repo has
#     most of.
a_write_stamp $(( A_NOW - 3600 ))
a_write_hb    $(( A_NOW - 120 )) "Notification" "permission_prompt"
out=$(a_run)
assert_eq "A5c Notification/permission_prompt DOES invalidate (a modal follows a model tool call)" \
    "$(a_state "$out")" "busy"

# --- A6: FAIL CLOSED on a heartbeat with no `event`. worker-heartbeat.sh's
#     jq-less fallback writer omits the field; treating its absence as
#     evidence would silently retire live suspensions on degraded workers.
a_write_stamp $(( A_NOW - 3600 ))
a_write_hb    $(( A_NOW - 120 )) "" "busy"
out=$(a_run)
assert_eq "A6 heartbeat with no event field ⇒ fail CLOSED, stamp honoured" \
    "$(a_state "$out")" "over-limit"

# --- A7: FAIL CLOSED on unparseable heartbeat JSON.
a_write_stamp $(( A_NOW - 3600 ))
printf 'not json at all\n' > "$a_hb"
out=$(a_run)
assert_eq "A7 corrupt heartbeat ⇒ fail CLOSED, stamp honoured" \
    "$(a_state "$out")" "over-limit"

# --- A8: GENUINE SUSPENSION, the non-negotiable control. The session's last
#     activity PRE-dates the stamp: nothing has run since the limit landed.
a_write_stamp $(( A_NOW - 3600 ))
a_write_hb    $(( A_NOW - 7200 )) "PostToolUse" "busy"
out=$(a_run)
assert_eq "A8 genuine suspension (activity predates the stamp) ⇒ over-limit stands" \
    "$(a_state "$out")" "over-limit"

# --- A9: GENUINE SUSPENSION with no heartbeat at all.
a_write_stamp $(( A_NOW - 3600 ))
rm -f "$a_hb"
out=$(a_run)
assert_eq "A9 genuine suspension (no heartbeat) ⇒ over-limit stands" \
    "$(a_state "$out")" "over-limit"
assert_file_exists "A10 …and that stamp is NOT deleted" "$a_stamp"

# ============================================================================
# B/C. The watcher's liveness gate
# ============================================================================

STATE_DIR="$WORK/.state"; mkdir -p "$STATE_DIR"; export STATE_DIR
STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "list-windows" ]]; then
    fmt=""
    for a in "$@"; do [[ "$a" == '#'* ]] && fmt="$a"; done
    while IFS='|' read -r nm ix; do
        [[ -n "$nm" ]] || continue
        case "$fmt" in
            *window_activity*) printf '%s|%s|%s\n' "$nm" "${MOCK_TMUX_ACTIVITY_EPOCH:-$(date +%s)}" "$ix" ;;
            *)                 printf '%s|%s\n' "$nm" "$ix" ;;
        esac
    done <<<"${MOCK_TMUX_WINDOWS:-}"
    exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

cat > "$STUB_DIR/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
# The scan enumerates workers as (name, activity, index) and probes BY INDEX,
# so a mock keyed only on the window NAME is never consulted and every probe
# silently returns the default. That is not hypothetical: it made this file's
# loop test pass without ever reading `over-limit`, and only the assertion
# count and the re-stamp control caught it. Resolve an index back to its name
# so the fixture can be written the way it reads.
while [[ "${1:-}" == --* ]]; do shift 2 2>/dev/null || break; done
win="${1:-}"
if [[ "$win" =~ ^[0-9]+$ ]]; then
    while IFS='|' read -r _nm _ix; do
        [[ "$_ix" == "$win" ]] && { win="$_nm"; break; }
    done <<<"${MOCK_TMUX_WINDOWS:-}"
fi
key="MOCK_PANE_STATE_${win//[^a-zA-Z0-9_]/_}"
state="${!key:-busy}"
printf 'state=%s active=0 window=%s name=stub reset_at=1:40pm_America/Los_Angeles\n' "$state" "$win"
exit 0
STUB
chmod +x "$STUB_DIR/pane-state.sh"
mkdir -p "$WORK/monitor"
cp "$STUB_DIR/pane-state.sh" "$WORK/monitor/pane-state.sh"
chmod +x "$WORK/monitor/pane-state.sh"
NEXUS_ROOT="$WORK"; export NEXUS_ROOT
PATH="$STUB_DIR:$PATH"; export PATH

PASTE_LOG="$WORK/paste.log"; LOG_LOG="$WORK/log.log"
: > "$PASTE_LOG"; : > "$LOG_LOG"
test_log()   { printf '%s\n' "$*" >> "$LOG_LOG"; }
test_paste() { printf '%s\n' "$1" >> "$PASTE_LOG"; return "${PASTE_RC:-0}"; }

# shellcheck source=monitor/watcher/_lib.sh
source "$LIB"
# shellcheck source=monitor/watcher/_idle_probe.sh
source "$IDLE"
# shellcheck source=monitor/watcher/_over_limit.sh
source "$HELPER"
_OVER_LIMIT_LOG_FN=test_log
_OVER_LIMIT_PASTE_FN=test_paste

b_reset() {
    rm -f "$STATE_DIR/over-limit-state.tsv" \
          "$STATE_DIR/over-limit-observed.tsv" \
          "$STATE_DIR/over-limit-liveness.tsv"
    : > "$PASTE_LOG"; : > "$LOG_LOG"
}
b_has_row() { [[ -f "$STATE_DIR/over-limit-state.tsv" ]] && grep -q "^$1"$'\t' "$STATE_DIR/over-limit-state.tsv"; }

echo
echo '=== B. watcher liveness gate: a pane servicing turns is not stamped ==='

# --- B1: THE NEGATIVE CONTROL FOR THIS LAYER. No liveness note ⇒ a genuine
#     suspension is stamped exactly as before. If this ever fails, the gate
#     has stopped the watcher holding anything at all.
b_reset
_over_limit_record "w1" "w1" "worker" "1:40pm_America/Los_Angeles"
b_has_row w1 \
    && { printf '  PASS: B1 genuine suspension is still stamped (gate absent ⇒ unchanged)\n'; _th_pass; } \
    || { printf '  FAIL: B1 gate suppressed a genuine suspension\n' >&2; _th_fail; }

# --- B2/B3: a window we ALREADY resumed is not re-stamped, and says why.
b_reset
_over_limit_liveness_set "w1" "$(date +%s)" "resumed"
_over_limit_record "w1" "w1" "worker" "1:40pm_America/Los_Angeles"
b_has_row w1 \
    && { printf '  FAIL: B2 row re-created on the same banner instance we already resumed\n' >&2; _th_fail; } \
    || { printf '  PASS: B2 an already-resumed window is NOT re-stamped\n'; _th_pass; }
assert_contains "B3 the refusal is logged, not silent" "$(cat "$LOG_LOG")" "NOT stamping"

# --- B4: THE NARROWING, asserted. A note of any reason OTHER than `resumed`
#     must not suppress. The first version of this gate also armed on any pane
#     the scan saw alive, and because the scan sees panes alive every 60 s that
#     note is present at the moment of nearly every genuine suspension — so
#     every hold would have started a full grace period late. This pins the
#     narrowing so it cannot be widened back without a red.
b_reset
_over_limit_liveness_set "w2" "$(date +%s)" "alive"
_over_limit_record "w2" "w2" "worker" "1:40pm_America/Los_Angeles"
b_has_row w2 \
    && { printf '  PASS: B4 a merely-alive note does NOT suppress (only an actioned resume does)\n'; _th_pass; } \
    || { printf '  FAIL: B4 the broad arm is back — every genuine hold now starts late\n' >&2; _th_fail; }

# --- B5: THE HOLD IS NOT WEAKENED. A REFRESH of an existing row is never
#     gated, so the observation sidecar keeps advancing through a genuine
#     multi-hour hold and the emit gate stays shut. Gating refreshes would
#     open the operator's channel mid-suspension — the exact failure the hold
#     exists to prevent.
b_reset
_over_limit_record "w3" "w3" "worker" "1:40pm_America/Los_Angeles"
_over_limit_liveness_set "w3" "$(date +%s)" "resumed"
obs_before=$(_over_limit_observation_get w3)
_over_limit_observation_set "w3" $(( obs_before - 500 ))
_over_limit_record "w3" "w3" "worker" "1:40pm_America/Los_Angeles"
obs_after=$(_over_limit_observation_get w3)
(( obs_after > obs_before - 500 )) \
    && { printf '  PASS: B5 refresh of an EXISTING row is never gated (hold intact)\n'; _th_pass; } \
    || { printf '  FAIL: B5 gate blocked a refresh — the emit gate would open mid-hold\n' >&2; _th_fail; }

# --- B6: the suppression is BOUNDED. An aged note stops suppressing.
b_reset
printf 'w4\t%s\tresumed\n' "$(( $(date +%s) - 100000 ))" > "$STATE_DIR/over-limit-liveness.tsv"
_over_limit_record "w4" "w4" "worker" "1:40pm_America/Los_Angeles"
b_has_row w4 \
    && { printf '  PASS: B6 an aged resume note stops suppressing\n'; _th_pass; } \
    || { printf '  FAIL: B6 stale resume note suppressed forever — the gate latched\n' >&2; _th_fail; }

# --- B7: the FAIL-OPEN paste must NOT arm the gate. It happens while the pane
#     still reads over-limit, so nothing was observed alive and re-stamping on
#     the next scan is how the hold re-closes.
b_reset
_over_limit_failopen "w5" "w5" "worker" "1:40pm" "$(( $(date +%s) - 60 ))" "$(date +%s)"
_over_limit_record "w5" "w5" "worker" "1:40pm_America/Los_Angeles"
b_has_row w5 \
    && { printf '  PASS: B7 fail-open paste does not arm the gate (hold re-closes)\n'; _th_pass; } \
    || { printf '  FAIL: B7 fail-open armed the gate — a still-frozen pane would go unheld\n' >&2; _th_fail; }

echo
echo '=== C. the measured loop: one banner instance ⇒ exactly ONE resume brief ==='

# Replays the devred sequence against the module: scan stamps the window; the
# wake loop observes it alive and pastes a brief; the NEXT scan reads the same
# stale `over-limit` (the stamp's clear is still pending) and must not
# re-stamp — so no second brief is ever composed.
b_reset
export MOCK_TMUX_WINDOWS='wloop|3'
now=$(date +%s)

# --- C0: THE CONTROL THAT MAKES C3 MEAN ANYTHING. With no liveness note, the
#     scan must reach _over_limit_record and create the row. Without this, a
#     harness that never delivers `over-limit` to the scan at all produces a
#     green C3 — which is exactly what happened on the first run of this file.
MOCK_PANE_STATE_wloop=over-limit; export MOCK_PANE_STATE_wloop
_over_limit_scan_panes "orchestrator"
b_has_row wloop \
    && { printf '  PASS: C0 the scan DOES stamp an over-limit read (the path under test is live)\n'; _th_pass; } \
    || { printf '  FAIL: C0 the scan never stamped — every later assertion here is vacuous\n' >&2; _th_fail; }

b_reset
printf 'wloop\twloop\tworker\t1:40pm_America/Los_Angeles\t%s\t%s\t%s\t0\n' \
    "$(( now - 3600 ))" "$(( now - 3600 ))" "$(( now - 10 ))" \
    > "$STATE_DIR/over-limit-state.tsv"
_over_limit_observation_set "wloop" "$(( now - 60 ))"

MOCK_PANE_STATE_wloop=busy; export MOCK_PANE_STATE_wloop
_over_limit_process_wakes "orchestrator"
briefs_1=$(grep -c '^wloop$' "$PASTE_LOG" || true)
assert_eq "C1 the wake loop pastes ONE resume brief when the pane reads alive" "$briefs_1" "1"
b_has_row wloop \
    && { printf '  FAIL: C2 row survived the resume\n' >&2; _th_fail; } \
    || { printf '  PASS: C2 the row is dropped on resume\n'; _th_pass; }

# The stale read returns — the underlying stamp has not been cleared, because
# the turn the brief started has not ended. This is the 62-second re-stamp.
MOCK_PANE_STATE_wloop=over-limit; export MOCK_PANE_STATE_wloop
_over_limit_scan_panes "orchestrator"
b_has_row wloop \
    && { printf '  FAIL: C3 RE-STAMPED on the same banner instance — the loop is live\n' >&2; _th_fail; } \
    || { printf '  PASS: C3 the same banner instance does NOT re-stamp\n'; _th_pass; }

# C4 must replay the FLAP, not just re-run the wake loop. A re-stamped row is
# not immediately due, so simply calling _over_limit_process_wakes again pastes
# nothing even on the broken tree — that version of this assertion passed on
# baseline and proved nothing. The second brief was produced by the pane
# reading alive AGAIN after the re-stamp (heartbeat fresh once more, 62 s
# later), which expedites the row and resumes it a second time. That is the
# sequence, so that is what is replayed.
MOCK_PANE_STATE_wloop=busy; export MOCK_PANE_STATE_wloop
_over_limit_scan_panes "orchestrator"
_over_limit_process_wakes "orchestrator"
briefs_2=$(grep -c '^wloop$' "$PASTE_LOG" || true)
assert_eq "C4 no SECOND resume brief for one banner instance (the 62s flap replayed)" "$briefs_2" "1"

# --- C5: and the loop still ENDS. Once the suppression expires with the pane
#     genuinely still suspended, the window is stamped again and the hold
#     resumes. A gate that made re-stamping impossible would be worse than the
#     spam it replaced.
printf 'wloop\t%s\tresumed\n' "$(( now - 100000 ))" > "$STATE_DIR/over-limit-liveness.tsv"
MOCK_PANE_STATE_wloop=over-limit; export MOCK_PANE_STATE_wloop
_over_limit_scan_panes "orchestrator"
b_has_row wloop \
    && { printf '  PASS: C5 a genuinely-still-suspended pane is re-stamped once the window expires\n'; _th_pass; } \
    || { printf '  FAIL: C5 the gate latched — the window can never be held again\n' >&2; _th_fail; }

# ============================================================================
# D. pane-state.sh 1c — a banner CONTRADICTED by live activity in the same
#    capture (your-org/nexus-code#1155 residual 1)
# ============================================================================
#
# 1b (section A) keys on the stamp's `ts`. The 1c TEXT SCRAPE has no `ts`, so
# `#1147`'s rule could not reach it and a stale banner sitting above live
# output still classified a working pane as suspended.
#
# The asymmetry that was the bug: 1c emitted and EXITED, while the very next
# branch — reached only because 1c did not fire — asks two questions of the
# SAME `$pane_plain` and treats either as proof the pane is alive. So the same
# bytes read `over-limit` at 1c and `busy` ten lines later, and the verdict was
# decided by evaluation order alone. 1c now consults those same two detectors
# before emitting.
#
# D2 IS THE ASSERTION THAT MATTERS. D1 alone would pass on a tree where 1c had
# simply been deleted, so it is a green from an instrument nobody has seen
# fire. D2 holds the fixture constant and removes ONLY the token-counter row,
# which must restore `over-limit` — isolating the counter as the cause rather
# than the banner having stopped matching for some unrelated reason.

echo '=== D. pane-state 1c: live activity in the same capture contradicts the banner ==='

# NAMED `busy-*`, NOT `over-limit-*`, and that is load-bearing rather than
# cosmetic (your-org/nexus-code#1171 skeptic blocker). `test-pane-state.sh`
# derives each fixture's EXPECTED state from its filename PREFIX and globs this
# whole directory, so a fixture joins that population the moment it lands. Named
# `over-limit-live-spinner-*` it asserted `want=over-limit` — the exact opposite
# of what it was built to demonstrate — and turned that suite red at
# `199 pass / 1 fail` while every guard `guards-for-diff` could select stayed
# green. The `busy-` prefix is the honest one: this IS a busy pane; the point is
# that it LOOKS over-limit.
D_FIX="$FIX_DIR/busy-overlimit-banner-live-spinner-synthetic.ansi"
D_CANON="$FIX_DIR/over-limit-canonical-synthetic.ansi"
[[ -f "$D_FIX"   ]] || { echo "needs $D_FIX" >&2; exit 1; }
[[ -f "$D_CANON" ]] || { echo "needs $D_CANON" >&2; exit 1; }

d_run() { "$PS" --fixture "$1" --window 9 --name dwin --active 0 --now 1800000000 2>&1; }
d_state() { awk -F'[ =]' '{print $2}' <<<"$1"; }

out=$(d_run "$D_FIX")
assert_eq "D1 banner + an ACTIVE token counter ⇒ busy, not over-limit"     "$(d_state "$out")" "busy"

# THE ONE-VARIABLE CONTROL. Same fixture, token-counter row deleted, nothing
# else touched.
d_stripped="$WORK/d-no-counter.ansi"
grep -v 'tokens)' "$D_FIX" > "$d_stripped"
out=$(d_run "$d_stripped")
assert_eq "D2 POTENCY: delete ONLY the counter row from that same fixture ⇒ over-limit returns"     "$(d_state "$out")" "over-limit"

# THE REGRESSION CONTROL. 1c is the fallback for panes with no StopFailure
# hook; gating it must not stop it catching a genuine, quiet suspension.
out=$(d_run "$D_CANON")
assert_eq "D3 a quiet suspended pane (no live chrome) STILL reads over-limit"     "$(d_state "$out")" "over-limit"

# THE REGRESSION CONTROL FOR THE DISCRIMINATOR ITSELF (#1171 skeptic finding
# 3, reproduced before being accepted: dev read `over-limit`, the first version
# of this branch read `busy`). A STALE token counter ABOVE the banner is the
# dying turn's own spinner, not proof of life. Releasing on it strands a genuinely
# suspended pane outside the resume path entirely — the subsystem's own failure,
# reached from the opposite direction. Its `over-limit-` prefix is honest: this
# one MUST classify over-limit, so `test-pane-state.sh` asserts the same thing.
out=$(d_run "$FIX_DIR/over-limit-stale-counter-above-banner-synthetic.ansi")
assert_eq "D5 a STALE counter ABOVE the banner does NOT release it (position, not presence)" \
    "$(d_state "$out")" "over-limit"

# The second admissible contradiction: a queued message entails a turn in
# flight, so the banner above it is scrollback.
d_queued="$WORK/d-queued.ansi"
{ cat "$D_CANON"; printf '\xe2\x9d\xaf Press up to edit queued messages\n'; } > "$d_queued" 2>/dev/null \
    || { cat "$D_CANON"; printf 'Press up to edit queued messages\n'; } > "$d_queued"
out=$(d_run "$d_queued")
assert_eq "D4 banner + a QUEUED-MESSAGE placeholder ⇒ busy (a turn is in flight)"     "$(d_state "$out")" "busy"

# ============================================================================
# E. the WATCHER actually tells pane-state which window is the orchestrator
# ============================================================================
# your-org/nexus-code#1155 residual 2 gives `pane-state.sh` an
# `--orchestrator-window` flag and consults the orchestrator activity marker
# for that pane only. A flag nothing passes is a mechanism that does not exist:
# before this, every production call site built a FIXED argv (this array had one
# append site; retire-preflight / cc-auto-update / ng pass a bare positional),
# and the env fallbacks were dead too — the running watcher had BOTH
# `MONITOR_TARGET` and `NEXUS_ORCHESTRATOR_WINDOW` unset. The rule therefore
# resolved via `pane-state.sh`'s literal default `orchestrator`, which matched
# the real window only because `_config.sh`'s `monitor.target_window` default is
# the same word in a different file — two literals that agree until one moves,
# i.e. the #1143 defect living inside the fix for it (#1171 skeptic finding 2).
#
# ASSERTED BEHAVIOURALLY, NOT BY GREP. A grep for the flag spelling is the same
# method that produced the original claim, and this board has had three false
# absences in one night. So the stub RECORDS THE ARGV it was actually invoked
# with, and E1 reads that recording.

echo '=== E. the watcher passes --orchestrator-window to pane-state ==='

E_ARGV="$WORK/e-argv.txt"
cat > "$WORK/monitor/pane-state.sh" <<'ESTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$E_ARGV_OUT"
printf 'state=busy active=0 window=9 name=stub\n'
exit 0
ESTUB
chmod +x "$WORK/monitor/pane-state.sh"
export E_ARGV_OUT="$E_ARGV"

: > "$E_ARGV"
TARGET=e-orch-window _idle_pane_state_line 91 >/dev/null 2>&1
assert_contains "E1 the watcher's argv carries --orchestrator-window with the RESOLVED target" \
    "$(cat "$E_ARGV" 2>/dev/null)" "--orchestrator-window e-orch-window"

# POTENCY. A different index so the pane cache cannot answer from E1. With no
# resolved TARGET the flag must be ABSENT — otherwise E1 would pass on a build
# that appends the flag unconditionally, which is a different (and wrong) thing.
: > "$E_ARGV"
TARGET="" _idle_pane_state_line 92 >/dev/null 2>&1
assert_not_contains "E2 POTENCY: with no resolved TARGET the flag is omitted, not passed empty" \
    "$(cat "$E_ARGV" 2>/dev/null)" "--orchestrator-window"

# THE WEEKLY BANNER ARM (#1171 R2-A). The banner has two shipped forms and the
# discriminator must behave identically on both. It did not: the positional gate
# first carried its OWN copy of the banner regex inside an `awk` program, and
# under `mawk` — the default `awk` on Debian/Ubuntu, which any operator cloning
# this repo may have — the WEEKLY form did not match, so a real suspension read
# `busy` and would never have been stamped or resumed.
#
# The PLAIN form matched under both awks, because `{0,2}` is satisfied at ZERO
# repetitions on the bare word `limit`. So the single fixture then exercising
# this path could not see it: green under both awks, correct under one. These two
# fixtures are what make the arms distinguishable.
out=$(d_run "$FIX_DIR/over-limit-weekly-stale-counter-above-banner-synthetic.ansi")
assert_eq "D6 WEEKLY banner + stale counter ABOVE ⇒ over-limit (the arm mawk got wrong)" \
    "$(d_state "$out")" "over-limit"
out=$(d_run "$FIX_DIR/busy-overlimit-weekly-banner-live-spinner-synthetic.ansi")
assert_eq "D7 WEEKLY banner + live spinner BELOW ⇒ busy (still discriminating, not reverted)" \
    "$(d_state "$out")" "busy"

# STRUCTURAL: ONE banner definition, and it is not matched by awk.
# The remedy for R2-A was not a relaxed second regex, it was NO second regex —
# `_detect_over_limit` and `_over_limit_after_banner` share
# `$_OVER_LIMIT_BANNER_RE` and both match it with `grep -E`, so they cannot
# disagree about what a banner is even when a different engine is installed.
# D8 USED TO BE A TEXT CHECK AND WAS TOO WEAK. It grepped for an `awk` line
# literally containing `hit|reached`, which would MISS
# `awk -v re="$_OVER_LIMIT_BANNER_RE"` — precisely the shape a reviewer used to
# probe this (#1171 round 3). A guard that cannot see the most natural way to
# reintroduce the defect is not guarding against it.
#
# Asserted as a PROPERTY instead: every consumer of the banner pattern is a
# `grep`. Derived from the file, so a consumer added by any route is caught.
_d8_defs=$(LC_ALL=C grep -cE "^_OVER_LIMIT_BANNER_RE=" "$_repo_root/monitor/pane-state.sh")
_d8_nongrep=$(LC_ALL=C grep -nE '_OVER_LIMIT_BANNER_RE' "$_repo_root/monitor/pane-state.sh" \
    | LC_ALL=C grep -vE ':[[:space:]]*#' \
    | LC_ALL=C grep -vE '^[0-9]+:_OVER_LIMIT_BANNER_RE=' \
    | LC_ALL=C grep -vcE 'grep' || true)
assert_eq "D8 exactly ONE banner definition, and EVERY consumer of it is a grep" \
    "defs=$_d8_defs non_grep_consumers=$_d8_nongrep" "defs=1 non_grep_consumers=0"

# THE OTHER FIVE CALLERS (#1171 R2-C). `_idle_probe.sh` passing the flag covers
# ONE call site. There are SIX under `monitor/watcher/` — `_over_limit.sh`'s own
# `_over_limit_probe_pane` among them — and a per-site fix has a permissive
# default arm for every site its author failed to enumerate. That is not
# hypothetical: the first enumeration found one, because it was piped through
# `| head`.
#
# So `_config.sh` EXPORTS the resolved target and the whole watcher process tree
# inherits it. Asserted BEHAVIOURALLY — a real child of a shell that sourced
# `_config.sh` is asked what it sees — rather than by grepping for the word
# `export`.
_e3_child=$(env MONITOR_TARGET=e3-orch NEXUS_ROOT="$_repo_root" bash -c \
    '. "$NEXUS_ROOT/monitor/watcher/_config.sh" >/dev/null 2>&1; bash -c "printf %s \"\$MONITOR_TARGET\""' 2>/dev/null)
assert_eq "E3 a GRANDCHILD of a shell that sourced _config.sh inherits the resolved target" \
    "$_e3_child" "e3-orch"

# POTENCY, and the reason the export is guarded: an EMPTY export is not the same
# as no export. It would satisfy any future `${MONITOR_TARGET-…}` reader (no
# colon) while carrying no information.
_e4_empty=$(env -u MONITOR_TARGET NEXUS_ROOT=/nonexistent-e4 bash -c \
    '. "'"$_repo_root"'/monitor/watcher/_config.sh" >/dev/null 2>&1; export -p | grep -c "MONITOR_TARGET" || true' 2>/dev/null)
assert_eq "E4 POTENCY: an unresolvable target exports NOTHING rather than an empty string" \
    "${_e4_empty:-0}" "0"

# D9 — DIALECT INDEPENDENCE, ASSERTED AS BEHAVIOUR (#1171 R2-A / round 3).
# D8 pins the source shape; this pins the thing that actually matters, by running
# the real classifier under a SECOND awk implementation and requiring the verdict
# to be identical. `mawk` is the default `awk` on Debian/Ubuntu, and the original
# defect was invisible to every source-level check that did not know which engine
# would evaluate the pattern.
#
# Skipped, with the assertion budget adjusted, when no second awk exists — a
# guard that cannot run must not silently inflate the ledger, and must not be
# faked with a vacuous pass either.
_d9_alt=$(command -v mawk 2>/dev/null || true)
if [[ -n "$_d9_alt" ]]; then
    _d9_dir="$WORK/altawk"; mkdir -p "$_d9_dir"; ln -sf "$_d9_alt" "$_d9_dir/awk"
    _d9_bad=""
    for _d9_f in "$FIX_DIR/over-limit-weekly-synthetic.ansi" \
                 "$FIX_DIR/over-limit-weekly-stale-counter-above-banner-synthetic.ansi" \
                 "$FIX_DIR/busy-overlimit-weekly-banner-live-spinner-synthetic.ansi" \
                 "$FIX_DIR/over-limit-stale-counter-above-banner-synthetic.ansi"; do
        [[ -f "$_d9_f" ]] || continue
        _d9_a=$(d_state "$("$PS" --fixture "$_d9_f" --window 9 --name dwin --active 0 --now 1800000000 2>&1)")
        _d9_b=$(d_state "$(PATH="$_d9_dir:$PATH" "$PS" --fixture "$_d9_f" --window 9 --name dwin --active 0 --now 1800000000 2>&1)")
        [[ "$_d9_a" == "$_d9_b" ]] || _d9_bad="$_d9_bad $(basename "$_d9_f"):$_d9_a/$_d9_b"
    done
    assert_empty "D9 the over-limit verdict is identical under a second awk ($(basename "$_d9_alt"))" \
        "$_d9_bad"
    _D9_RAN=1
else
    printf '  SKIP: D9 no second awk implementation available to cross-check\n'
    _D9_RAN=0
fi

# ---- assertion-count guard ------------------------------------------------
# A:  A1,A2,A3,A4,A5,A5b,A5c,A6,A7,A8,A9,A10    = 12
# B:  B1,B2,B3,B4,B5,B6,B7                      =  7
# C:  C0,C1,C2,C3,C4,C5                         =  6
# D:  D1,D2,D3,D4,D5,D6,D7,D8                   =  8
# E:  E1,E2,E3,E4                               =  4
# D9 runs only where a second awk exists; the budget follows it.
EXPECTED=$(( 12 + 7 + 6 + 8 + 4 + _D9_RAN ))
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
