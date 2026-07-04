#!/usr/bin/env bash
# Fixtures for the post-wrap-up engagement state machine
# (your-org/your-nexus#205, PR your-org/nexus-code#270 — the
# operator's state-machine spec).
#
# Run: bash monitor/watcher/test-engage-statemachine.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# The spec under test:
#   (1) A UserPromptSubmit paired with an orchestrator injection
#       (paste-followup / machine-input / spawn stamp) is MACHINE-
#       driven → the window regresses to BUSY: engagement-log is
#       re-anchored at the submit, any standing retain is consumed,
#       and a wrap-up OLDER than the follow-up is superseded (the
#       worker owes a fresh wrap-up — no stale "wrapped" row).
#   (2) A UserPromptSubmit with NO covering injection is the
#       OPERATOR → the window is INTERACTIVE (operator-engaged)
#       with the typical idle timeouts — after a wrap-up too
#       (src=submit-after-wrap).
#   (3) An orchestrator injection that never fired a UserPromptSubmit
#       on a hook-live window is a FAILED nudge → `paste-unconfirmed`
#       surfaces after the confirm grace; confirmed / no-enter /
#       hook-less / too-recent pastes never flag.
#   A machine-only (never-engaged) wrap-up keeps today's behavior
#   (retain footer → retire eligibility), asserted as the control.
#
# The interactive-wrap clarification + `ng engaged-done` finished-
# signal lives in test-ng-wrap-up.sh (ng side) and the
# "NEWER wrap-up does NOT invalidate; engaged-done DOES" block of
# test-idle-probe.sh (watcher side).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$_test_dir/_idle_probe.sh"

PASS=0
FAIL=0
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness (mirrors test-idle-probe.sh) --------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR"
export STATE_DIR

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows) printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    *) : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

cat > "$STUB_DIR/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
win="${1:-}"
while [[ "$win" == --* ]]; do
    shift 2 2>/dev/null || break
    win="${1:-}"
done
key="MOCK_PANE_STATE_${win//[^a-zA-Z0-9_]/_}"
hash_key="MOCK_CONTENT_HASH_${win//[^a-zA-Z0-9_]/_}"
state="${!key:-busy}"
content_hash="${!hash_key:-}"
extras=""
[[ -n "$content_hash" ]] && extras+=" content_hash=$content_hash"
printf 'state=%s%s\n' "$state" "$extras"
exit 0
STUB
chmod +x "$STUB_DIR/pane-state.sh"

mkdir -p "$WORK/monitor"
cp "$STUB_DIR/pane-state.sh" "$WORK/monitor/pane-state.sh"
chmod +x "$WORK/monitor/pane-state.sh"
NEXUS_ROOT="$WORK"
export NEXUS_ROOT

run_probe_capture() {
    local _out_var="$1" _rc_var="$2"; shift 2
    local _stdout _rc _tmp
    _tmp=$(mktemp)
    PATH="$STUB_DIR:$PATH" bash -c "
        set -uo pipefail
        STATE_DIR='$STATE_DIR'
        NEXUS_ROOT='$NEXUS_ROOT'
        source '$PROBE'
        $*
    " >"$_tmp" 2>/dev/null
    _rc=$?
    _stdout=$(<"$_tmp"); rm -f "$_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_rc_var" '%s' "$_rc"
}

LOG="$STATE_DIR/action-log.jsonl"
NOW=$(date +%s)
OLD_TS=$(( NOW - 700 ))

stamp_user_prompt() {
    local window="$1" epoch="${2:-$(date +%s)}"
    mkdir -p "$STATE_DIR/user-prompt"
    printf '%s\t%s\n' "$epoch" "test-session" > "$STATE_DIR/user-prompt/$window"
}
stamp_pane_change() {
    local window="$1" epoch="${2:-$(date +%s)}" hash="${3:-h$RANDOM}"
    mkdir -p "$STATE_DIR/pane-change"
    printf '%s\t%s\n' "$hash" "$epoch" > "$STATE_DIR/pane-change/$window"
}
stamp_heartbeat() {
    local window="$1"
    mkdir -p "$STATE_DIR/heartbeat"
    printf '{"state":"idle_prompt","window":"%s"}\n' "$window" \
        > "$STATE_DIR/heartbeat/$window.json"
}
iso() { date -Is -d "@$1"; }

# ---- (1) post-wrap ORCHESTRATOR follow-up → busy regression --------------

echo '=== post-wrap orchestrator follow-up regresses the window to busy ==='
# Both windows wrapped (and were auto-retained) 600 s ago, idle since
# 700 s ago. The orchestrator then pastes a stamped follow-up which
# fires the UserPromptSubmit hook:
#   - freshfollow: follow-up 10 s ago  → re-anchored age < threshold,
#     the window LEAVES the idle pool entirely (busy semantics, even
#     though pane-state shows idle this cycle).
#   - oldfollow:   follow-up 120 s ago → back in the pool, but the
#     wrap-up is SUPERSEDED and the retain consumed → no-wrap-up nag,
#     not a stale wrapped/retained row.
: > "$LOG"
WRAP_TS=$(iso $(( NOW - 600 )))
cat > "$LOG" <<EOF
{"ts":"$WRAP_TS","agent":"monitor","event":"wrap-up","window":"freshfollow","report":"freshfollow_2026-06-12_000000_done.md","upload":"ok","comment":"ok","rocket":"ok"}
{"ts":"$WRAP_TS","agent":"monitor","event":"window-retain","window":"freshfollow","reason":"wrap-up-2026-06-12"}
{"ts":"$WRAP_TS","agent":"monitor","event":"wrap-up","window":"oldfollow","report":"oldfollow_2026-06-12_000000_done.md","upload":"ok","comment":"ok","rocket":"ok"}
{"ts":"$WRAP_TS","agent":"monitor","event":"window-retain","window":"oldfollow","reason":"wrap-up-2026-06-12"}
EOF
printf 'freshfollow\t%s\noldfollow\t%s\n' "$OLD_TS" "$OLD_TS" \
    > "$STATE_DIR/engagement-log.tsv"
printf 'freshfollow\t%s\tpaste-followup\noldfollow\t%s\tpaste-followup\n' \
    "$(( NOW - 10 ))" "$(( NOW - 120 ))" > "$STATE_DIR/machine-input.tsv"
stamp_user_prompt freshfollow "$(( NOW - 10 ))"
stamp_user_prompt oldfollow   "$(( NOW - 120 ))"
export MOCK_TMUX_WINDOWS="$(printf 'freshfollow|%s\noldfollow|%s' "$OLD_TS" "$OLD_TS")"
export MOCK_PANE_STATE_freshfollow=idle
export MOCK_PANE_STATE_oldfollow=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_not_contains "fresh follow-up: window left the idle pool (busy)" "$out" 'freshfollow'
assert_contains     "aged follow-up: wrap superseded → no-wrap-up nag"  "$out" $'oldfollow\tno-wrap-up'
assert_not_contains "aged follow-up: no stale wrapped row"              "$out" $'oldfollow\twrapped'
assert_not_contains "aged follow-up: retain consumed (not suppressed)"  "$out" $'oldfollow\tretained'
assert_not_contains "machine follow-ups never mark"                     "$out" 'operator-engaged'
# The busy regression is durable state, not a per-cycle accident:
# engagement-log re-anchored at the submit, machine-submit recorded.
assert_contains "engagement-log re-anchored at the follow-up" \
    "$(awk -F'\t' -v e="$(( NOW - 10 ))" '$1=="freshfollow" && $2 == e' "$STATE_DIR/engagement-log.tsv")" 'freshfollow'
assert_contains "machine-submit stamp recorded" \
    "$(cat "$STATE_DIR/machine-submit/oldfollow" 2>/dev/null)" "$(( NOW - 120 ))"
unset MOCK_PANE_STATE_freshfollow MOCK_PANE_STATE_oldfollow

# ---- (1b) machine submit REGRESSES a PRE-EXISTING operator mark (bug B) ---
# Live incident 2026-06-18 (watcher-robustness): a correctly
# paste-followup-stamped orchestrator relay landed on a window that
# ALREADY carried an operator-engaged mark (mis-seeded 3.5 min earlier).
# The REFRESH path bumped prompt_seen but left since/src intact, so the
# stamped paste could NOT tear the stale mark down — the window stayed
# `operator-engaged` indefinitely. The fix re-runs machine-attribution on
# every newer submit and REGRESSES (zeroes) the mark when the submit is
# machine-claimed, so a stamped relay self-heals a stale mark.
echo '=== machine submit regresses a pre-existing operator-engaged mark (bug B) ==='
rm -f "$STATE_DIR/operator-engaged.tsv" "$STATE_DIR/machine-input.tsv" \
      "$STATE_DIR/user-prompt/regwin"
rm -rf "$STATE_DIR/machine-submit"
# Pre-existing VALID operator mark, seeded 300 s ago, last 200 s ago.
printf 'regwin\t%s\t%s\t%s\tsubmit\t0\n' \
    "$(( NOW - 300 ))" "$(( NOW - 200 ))" "$(( NOW - 200 ))" \
    > "$STATE_DIR/operator-engaged.tsv"
stamp_pane_change regwin "$(( NOW - 5 ))"      # change-fresh → mark was VALID
# A newer machine-stamped submit (orchestrator paste-followup) 10 s ago.
printf 'regwin\t%s\tpaste-followup\n' "$(( NOW - 10 ))" \
    > "$STATE_DIR/machine-input.tsv"
stamp_user_prompt regwin "$(( NOW - 9 ))"
# Sanity: the mark is VALID before the machine submit is processed.
run_probe_capture pre_rc_out pre_rc '_openg_marked regwin'
assert_eq "pre: mark is VALID before the machine submit" "$pre_rc" "0"
# Process the machine-attributed submit.
run_probe_capture out rc "_openg_observe regwin idle '' $NOW \$(_openg_grace_seconds)"
# The mark is REGRESSED: since zeroed → _openg_marked now false.
since_after=$(awk -F'\t' '$1=="regwin" {print $2}' "$STATE_DIR/operator-engaged.tsv")
assert_eq "regress: operator-engaged row since zeroed" "$since_after" "0"
run_probe_capture post_rc_out post_rc '_openg_marked regwin'
assert_eq "regress: mark no longer VALID after machine submit" "$post_rc" "1"
# Durable busy regression: the machine-submit stamp is recorded and the
# user-prompt stamp is consumed (prompt_seen advanced).
assert_contains "regress: machine-submit stamp recorded" \
    "$(cat "$STATE_DIR/machine-submit/regwin" 2>/dev/null)" "$(( NOW - 9 ))"
prompt_seen_after=$(awk -F'\t' '$1=="regwin" {print $4}' "$STATE_DIR/operator-engaged.tsv")
assert_eq "regress: prompt stamp consumed (prompt_seen advanced)" \
    "$prompt_seen_after" "$(( NOW - 9 ))"
rm -f "$STATE_DIR/operator-engaged.tsv" "$STATE_DIR/machine-input.tsv" \
      "$STATE_DIR/user-prompt/regwin"
rm -rf "$STATE_DIR/machine-submit"

# ---- (2) post-wrap OPERATOR prompt → interactive --------------------------

echo '=== post-wrap operator prompt makes the window interactive ==='
# Wrapped 600 s ago; the OPERATOR submits 60 s ago (no machine stamp
# anywhere near it) and the agent answers (pane change 30 s ago) →
# operator-engaged with src=submit-after-wrap, typical idle timeouts.
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/operator-engaged.tsv" \
      "$STATE_DIR/machine-input.tsv"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change" \
       "$STATE_DIR/machine-submit"
cat > "$LOG" <<EOF
{"ts":"$WRAP_TS","agent":"monitor","event":"wrap-up","window":"chatback","report":"chatback_2026-06-12_000000_done.md","upload":"ok","comment":"ok","rocket":"ok"}
{"ts":"$WRAP_TS","agent":"monitor","event":"window-retain","window":"chatback","reason":"wrap-up-2026-06-12"}
EOF
printf 'chatback\t%s\n' "$OLD_TS" > "$STATE_DIR/engagement-log.tsv"
stamp_user_prompt chatback "$(( NOW - 60 ))"
stamp_pane_change chatback "$(( NOW - 30 ))"
export MOCK_TMUX_WINDOWS="$(printf 'chatback|%s' "$OLD_TS")"
export MOCK_PANE_STATE_chatback=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains "post-wrap operator prompt → operator-engaged" "$out" $'chatback\toperator-engaged'
assert_contains "seed records the post-wrap source" \
    "$(awk -F'\t' '$1=="chatback" && $2 != 0 { print $5 }' "$STATE_DIR/operator-engaged.tsv" 2>/dev/null)" \
    'submit-after-wrap'
assert_not_contains "no wrapped row while interactive"  "$out" $'chatback\twrapped'
assert_not_contains "no retained row while interactive" "$out" $'chatback\tretained'
unset MOCK_PANE_STATE_chatback

# ---- control: machine-only wrap-up keeps today's behavior -----------------

echo '=== machine-only wrap-up unchanged: retained suppression holds ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/operator-engaged.tsv"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change" \
       "$STATE_DIR/machine-submit"
cat > "$LOG" <<EOF
{"ts":"$WRAP_TS","agent":"monitor","event":"wrap-up","window":"donequiet","report":"donequiet_2026-06-12_000000_done.md","upload":"ok","comment":"ok","rocket":"ok"}
{"ts":"$WRAP_TS","agent":"monitor","event":"window-retain","window":"donequiet","reason":"wrap-up-2026-06-12"}
EOF
printf 'donequiet\t%s\n' "$OLD_TS" > "$STATE_DIR/engagement-log.tsv"
export MOCK_TMUX_WINDOWS="$(printf 'donequiet|%s' "$OLD_TS")"
export MOCK_PANE_STATE_donequiet=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains     "never-engaged wrapped window stays retained" "$out" $'donequiet\tretained'
assert_not_contains "no spurious supersede without a follow-up"   "$out" $'donequiet\tno-wrap-up'
unset MOCK_PANE_STATE_donequiet

# ---- (3) injection ↔ hook pairing: paste-unconfirmed ----------------------

echo '=== unpaired injection: paste with no UserPromptSubmit → paste-unconfirmed ==='
# Five windows, one paste each ~300 s ago (default confirm grace 180):
#   lostpaste  — hooks live, NO submit ever        → paste-unconfirmed
#   okpaste    — hooks live, submit covered it      → normal class
#   nohooks    — no heartbeat (hooks not installed) → normal class
#   queued     — --no-enter paste (never submits)   → normal class
#   justpasted — paste 30 s ago (< grace)           → normal class
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/operator-engaged.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change" \
       "$STATE_DIR/machine-submit" "$STATE_DIR/heartbeat"
: > "$LOG"
{
    printf 'lostpaste\t%s\tpaste-followup\n'           "$(( NOW - 300 ))"
    printf 'okpaste\t%s\tpaste-followup\n'             "$(( NOW - 300 ))"
    printf 'nohooks\t%s\tpaste-followup\n'             "$(( NOW - 300 ))"
    printf 'queued\t%s\tpaste-followup-no-enter\n'     "$(( NOW - 300 ))"
    printf 'justpasted\t%s\tpaste-followup\n'          "$(( NOW - 30 ))"
} > "$STATE_DIR/machine-input.tsv"
{
    printf 'lostpaste\t%s\n'  "$OLD_TS"
    printf 'okpaste\t%s\n'    "$OLD_TS"
    printf 'nohooks\t%s\n'    "$OLD_TS"
    printf 'queued\t%s\n'     "$OLD_TS"
    printf 'justpasted\t%s\n' "$OLD_TS"
} > "$STATE_DIR/engagement-log.tsv"
stamp_heartbeat lostpaste
stamp_heartbeat okpaste
stamp_heartbeat queued
stamp_heartbeat justpasted
stamp_user_prompt okpaste "$(( NOW - 295 ))"
export MOCK_TMUX_WINDOWS="$(printf 'lostpaste|%s\nokpaste|%s\nnohooks|%s\nqueued|%s\njustpasted|%s' \
    "$OLD_TS" "$OLD_TS" "$OLD_TS" "$OLD_TS" "$OLD_TS")"
export MOCK_PANE_STATE_lostpaste=idle
export MOCK_PANE_STATE_okpaste=idle
export MOCK_PANE_STATE_nohooks=idle
export MOCK_PANE_STATE_queued=idle
export MOCK_PANE_STATE_justpasted=idle
run_probe_capture out rc 'list_really_idle_workers'
assert_contains     "unpaired paste flags paste-unconfirmed"     "$out" $'lostpaste\tpaste-unconfirmed'
assert_contains     "confirmed paste stays on the normal class"  "$out" $'okpaste\tno-wrap-up'
assert_not_contains "confirmed paste not flagged"                "$out" $'okpaste\tpaste-unconfirmed'
assert_contains     "hook-less window cannot confirm → no flag"  "$out" $'nohooks\tno-wrap-up'
assert_not_contains "hook-less window not flagged"               "$out" $'nohooks\tpaste-unconfirmed'
assert_contains     "no-enter paste never expects a submit"      "$out" $'queued\tno-wrap-up'
assert_not_contains "no-enter paste not flagged"                 "$out" $'queued\tpaste-unconfirmed'
assert_contains     "paste younger than the grace not yet judged" "$out" $'justpasted\tno-wrap-up'
assert_not_contains "young paste not flagged"                    "$out" $'justpasted\tpaste-unconfirmed'

echo '=== paste-unconfirmed: render + recovery on a successful re-paste ==='
rm -f "$STATE_DIR/idle-state.tsv"
run_probe_capture out rc 'render_idle_section'
assert_contains "render names the failure and the fix" "$out" \
    'lostpaste paste-unconfirmed (paste '
assert_contains "render points at the canonical paste path" "$out" \
    're-paste via monitor/paste-followup.sh'
# The orchestrator re-pastes; this time the hook fires → the stamp
# covers the paste and the window returns to the normal class.
printf 'lostpaste\t%s\tpaste-followup\n' "$(( NOW - 5 ))" >> "$STATE_DIR/machine-input.tsv"
stamp_user_prompt lostpaste "$(( NOW - 5 ))"
run_probe_capture out rc 'MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers'
assert_not_contains "confirmed re-paste clears the flag" "$out" $'lostpaste\tpaste-unconfirmed'
unset MOCK_PANE_STATE_lostpaste MOCK_PANE_STATE_okpaste MOCK_PANE_STATE_nohooks \
      MOCK_PANE_STATE_queued MOCK_PANE_STATE_justpasted

# ---- summary --------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
