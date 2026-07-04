#!/usr/bin/env bash
# Long-exchange simulation for the operator-engaged mark
# (your-org/your-nexus#205, PR your-org/nexus-code#270).
#
# Run: SLOW_TESTS=1 bash monitor/watcher/test-engage-long-exchange.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
# Gated behind SLOW_TESTS=1 (~36 probe cycles × sourced-probe subshells
# + two TTL sleeps ≈ 1 min wall) so the default fast loop stays quick.
#
# The operator's concern: Claude Code occasionally produces rendering
# artifacts (TUI redraws that garble `tmux capture-pane` output), and a
# LONG operator<->CC exchange must keep the engagement-mark lifecycle
# correct even when those artifacts land mid-conversation. This test
# drives a many-turn exchange — think-gaps, prompt submits, busy
# streaming, idle pauses — with distorted frames injected on a fixed
# schedule, and asserts:
#
#   - a mark is created ONLY on a genuine operator submit corroborated
#     by real pane-content change;
#   - injected distortion FAILS CLOSED: garbled / half-redrawn / noisy
#     captures may withhold a mark, but never fabricate one (the
#     `bystander` window suffers every distortion and never marks), and
#     never drop a genuinely-active session on the next clean frame;
#   - the mark SELF-EXPIRES once the pane goes static past the change
#     TTL, and a returning operator re-engages cleanly;
#   - input-row-only churn (autosuggest ghost, cursor, timer digits) is
#     INVISIBLE to the content hash — the exact CC idle animation that
#     must never pin a window open.
#
# Fidelity: frames are byte-faithful synthetic captures (same escape
# sequences monitor/watcher/fixtures/synthesize.sh replicates from real
# CC output). Each frame's `state=` and `content_hash=` come from the
# REAL monitor/pane-state.sh (--fixture mode), and the per-cycle
# bookkeeping runs through the REAL _idle_probe.sh classifier
# (list_really_idle_workers -> _openg_observe -> _openg_marked) via the
# same stub-tmux/stub-pane-state harness test-idle-probe.sh uses. The
# only simulated layer is the tmux window list and the pane bytes
# themselves; every hash, predicate, and classification is production
# code. (A true real-binary long exchange lives in
# test-integration/test-realmodel-long-exchange.sh, RUN_CC_HARNESS=1.)

set -uo pipefail

if [ "${SLOW_TESTS:-0}" != "1" ]; then
    echo "skipped: $(basename "$0") (set SLOW_TESTS=1 to enable; ~60s wall-clock)"
    exit 0
fi

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
PROBE="$_test_dir/_idle_probe.sh"
PANE_STATE="$_repo_root/monitor/pane-state.sh"

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
assert_ne() {
    local label="$1" got="$2" notwant="$3"
    if [[ "$got" != "$notwant" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — both sides %q\n' "$label" "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
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
assert_empty() {
    local label="$1" got="$2"
    if [[ -z "$got" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — expected empty, got: %q\n' "$label" "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness (stub tmux + stub pane-state; mirrors test-idle-probe.sh) ----

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR"
export STATE_DIR

STUB_DIR="$WORK/bin"
FRAME_DIR="$WORK/frames"
mkdir -p "$STUB_DIR" "$FRAME_DIR"

cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows) printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    display)      printf '' ;;
    *)            : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

# Stub pane-state: replays the (state, content_hash) the REAL
# pane-state.sh computed for the window's current frame (see
# set_window_frame below) — exactly the line shape production emits.
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

stamp_user_prompt() {
    local window="$1" epoch="${2:-$(date +%s)}"
    mkdir -p "$STATE_DIR/user-prompt"
    printf '%s\t%s\n' "$epoch" "test-session" > "$STATE_DIR/user-prompt/$window"
}

# Engagement-row field readers (operator-engaged.tsv:
# window\tsince\tlast\tprompt_seen\tsrc\treminded).
oe_since() {
    awk -F'\t' -v w="$1" '$1 == w { print $2; exit }' \
        "$STATE_DIR/operator-engaged.tsv" 2>/dev/null
}
oe_marked_windows() {
    awk -F'\t' '$2 != 0 && $2 != "" { print $1 }' \
        "$STATE_DIR/operator-engaged.tsv" 2>/dev/null
}

# ---- frame builder ---------------------------------------------------------
# Byte-faithful synthetic captures, same sequences as
# fixtures/synthesize.sh. A frame = transcript lines, an optional
# spinner row, the `❯<NBSP>` input row, and the status bar.

ESC=$'\x1b'
NBSP=$'\xc2\xa0'

# build_frame <out> idle|busy <timer> <input-row-mode> <transcript-line>...
#   input-row-mode: empty | ghost (dim autosuggest tail on the row)
build_frame() {
    local out="$1" kind="$2" timer="$3" input_mode="$4"; shift 4
    {
        local ln
        for ln in "$@"; do
            printf '%s\n' "${ESC}[39m● ${ln}${ESC}[0m"
        done
        printf '\n'
        if [[ "$kind" == busy ]]; then
            printf '%s\n' "${ESC}[38;5;246m✶ Cooking… (esc to interrupt · ↓ ${timer} tokens)${ESC}[0m"
        else
            printf '%s\n' "${ESC}[38;5;246m✻ Brewed for ${timer}s${ESC}[0m"
        fi
        printf '\n%s\n' "${ESC}[38;5;244m─${ESC}[0m"
        if [[ "$input_mode" == ghost ]]; then
            # Dim-autosuggest input row: reverse-video first char of the
            # suggestion, faint tail — the CC idle animation.
            printf '%s\n' "${ESC}[39m❯${NBSP}${ESC}[7mr${ESC}[0;2meview the failing test${ESC}[0m${ESC}[39m${ESC}[49m"
        else
            printf '%s\n' "${ESC}[38;5;246m❯${NBSP}${ESC}[7m ${ESC}[0m${ESC}[39m${ESC}[49m"
        fi
        printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
        printf '  %s\n' "${ESC}[38;5;246m◉ Opus 4.7 (1M context) │ ${timer}K/1.0M${ESC}[0m"
        printf '  %s\n' "${ESC}[38;5;246m-- INSERT -- ⏵⏵ bypass permissions on${ESC}[0m"
    } > "$out"
}

# Distortion A — transcript garble: a redraw scrambles transcript rows
# into ANSI soup. The hash legitimately moves (the transcript region
# changed), so this distortion can only EXTEND a mark's validity or
# withhold an expiry by one TTL — it must never seed a mark (no submit)
# nor drop one.
build_garble_frame() {
    local out="$1"; shift
    {
        local ln
        for ln in "$@"; do
            printf '%s\n' "${ESC}[39m● ${ln}${ESC}[0m"
        done
        printf '%s\n' "${ESC}[38;5;82m▓▒░≣≣⌧⌧▚▞${ESC}[48;5;201m⌑⌑GLITCHGLITCH${ESC}[0m${ESC}[38;5;196m▌▐▌▐qpzw${ESC}[0m"
        printf '%s\n' "${ESC}[7m▒▒▒▒${ESC}[0m${ESC}[38;5;226m⌫⌦⌫⌦ mangled-redraw-row${ESC}[0m"
        printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
        printf '%s\n' "${ESC}[38;5;246m❯${NBSP}${ESC}[7m ${ESC}[0m${ESC}[39m${ESC}[49m"
        printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
        printf '  %s\n' "${ESC}[38;5;246m-- INSERT -- ⏵⏵ bypass permissions on${ESC}[0m"
    } > "$out"
}

# Distortion B — half-redraw: capture caught the pane mid-repaint;
# transcript truncated, NO input row, NO status bar. pane-state digests
# the whole capture (no chevron anchor).
build_halfredraw_frame() {
    local out="$1"; shift
    {
        local ln
        for ln in "$@"; do
            printf '%s\n' "${ESC}[39m● ${ln}${ESC}[0m"
        done
        printf '%s' "${ESC}[38;5;246m✶ Cook"   # spinner row cut mid-word
    } > "$out"
}

# Run the REAL pane-state.sh on a frame; export the stub's MOCK_* vars
# for `window` so the next probe cycle sees exactly what production
# pane-state would have emitted for that capture.
set_window_frame() {
    local window="$1" frame="$2" line state hash
    line=$("$PANE_STATE" --fixture "$frame" --window 9 --name "$window" --active 0 2>/dev/null)
    state=$(sed -n 's/.*state=\([^ ]*\).*/\1/p' <<<"$line")
    hash=$(sed -n 's/.*content_hash=\([0-9]*\).*/\1/p' <<<"$line")
    export "MOCK_PANE_STATE_${window}=${state}"
    export "MOCK_CONTENT_HASH_${window}=${hash}"
}

frame_hash() {  # just the content_hash the real pane-state computes
    "$PANE_STATE" --fixture "$1" --window 9 --name probe --active 0 2>/dev/null \
        | sed -n 's/.*content_hash=\([0-9]*\).*/\1/p'
}
frame_state() {
    "$PANE_STATE" --fixture "$1" --window 9 --name probe --active 0 2>/dev/null \
        | sed -n 's/.*state=\([^ ]*\).*/\1/p'
}

# ---- frame-level distortion properties (real pane-state.sh) ---------------

echo '=== frame properties: what the real content hash sees ==='

TRANSCRIPT=("Turn 1 prompt: please review the failing test")
build_frame "$FRAME_DIR/idle-base.ansi"  idle 12 empty "${TRANSCRIPT[@]}"
build_frame "$FRAME_DIR/idle-noise.ansi" idle 47 ghost "${TRANSCRIPT[@]}"
build_frame "$FRAME_DIR/busy-base.ansi"  busy 1.2k empty "${TRANSCRIPT[@]}"
build_garble_frame    "$FRAME_DIR/garble.ansi"     "${TRANSCRIPT[@]}"
build_halfredraw_frame "$FRAME_DIR/halfredraw.ansi" "${TRANSCRIPT[@]}"

assert_eq "clean idle frame classifies idle"            "$(frame_state "$FRAME_DIR/idle-base.ansi")" idle
assert_eq "ghost+timer-churn frame classifies autosuggest-only" \
    "$(frame_state "$FRAME_DIR/idle-noise.ansi")" autosuggest-only
assert_eq "busy frame classifies busy"                  "$(frame_state "$FRAME_DIR/busy-base.ansi")" busy

H_CLEAN=$(frame_hash "$FRAME_DIR/idle-base.ansi")
H_NOISE=$(frame_hash "$FRAME_DIR/idle-noise.ansi")
H_GARBLE=$(frame_hash "$FRAME_DIR/garble.ansi")
H_HALF=$(frame_hash "$FRAME_DIR/halfredraw.ansi")
assert_ne "frames carry a hash" "$H_CLEAN" ""
# THE invisibility property: autosuggest ghost + cursor + every digit
# (timer, token meter) churn WITHOUT moving the hash — CC's idle
# animation reads as a static pane and lets a stale mark expire.
assert_eq "input-row ghost + digit churn is hash-invisible" "$H_NOISE" "$H_CLEAN"
# Transcript garble and half-redraws DO move the hash (the region
# really changed) — tolerated as transient change, never as a seed.
assert_ne "transcript garble moves the hash"   "$H_GARBLE" "$H_CLEAN"
assert_ne "half-redraw moves the hash"         "$H_HALF"   "$H_CLEAN"

# ---- the long exchange -----------------------------------------------------
#
# Three windows, observed every cycle like production:
#   convo     — the operator's chat; submits + answers turn after turn,
#               with garble / half-redraw frames injected on a schedule.
#   bystander — an ordinary idle worker that SUFFERS every distortion
#               but never receives a submit. Must never mark.
#   (phantom is exercised in a separate phase below.)

echo '=== long exchange: 12 turns, distortion every 3rd cycle-group ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv" \
      "$STATE_DIR/machine-input.tsv"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"
LOG="$STATE_DIR/action-log.jsonl"
: > "$LOG"

NOW=$(date +%s)
OLD_TS=$(( NOW - 7200 ))
export MOCK_TMUX_WINDOWS="$(printf 'convo|%s\nbystander|%s' "$OLD_TS" "$OLD_TS")"
printf 'convo\t%s\nbystander\t%s\n' "$OLD_TS" "$OLD_TS" > "$STATE_DIR/engagement-log.tsv"

CONVO_LINES=()
BYST_LINES=("bystander finished its task long ago")
build_frame "$FRAME_DIR/byst-idle.ansi" idle 9 empty "${BYST_LINES[@]}"
set_window_frame bystander "$FRAME_DIR/byst-idle.ansi"

cycle() {  # one watcher cycle over the mocked window set
    run_probe_capture CYCLE_OUT CYCLE_RC 'MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers'
}

# Pre-conversation cycle: both windows idle, no submits anywhere.
build_frame "$FRAME_DIR/convo-t0.ansi" idle 5 empty "fresh worker, empty transcript"
set_window_frame convo "$FRAME_DIR/convo-t0.ansi"
cycle
assert_contains "t0: convo nags no-wrap-up (no mark)"      "$CYCLE_OUT" $'convo\tno-wrap-up'
assert_contains "t0: bystander nags no-wrap-up"            "$CYCLE_OUT" $'bystander\tno-wrap-up'
assert_empty    "t0: no marks anywhere"                    "$(oe_marked_windows)"

for turn in 1 2 3 4 5 6 7 8 9 10 11 12; do
    # Think-gap, then the operator submits prompt N.
    stamp_user_prompt convo "$(date +%s)"

    # The agent streams: busy frame with the new prompt echoed into the
    # transcript (real content growth -> real hash movement).
    CONVO_LINES+=("Turn ${turn} prompt: operator asks about subsystem ${turn}")
    build_frame "$FRAME_DIR/convo-busy-$turn.ansi" busy 2.4k empty "${CONVO_LINES[@]}"
    set_window_frame convo "$FRAME_DIR/convo-busy-$turn.ansi"

    # Distortion schedule: every 3rd turn the BYSTANDER's capture is
    # garbled this cycle; every 4th turn CONVO's own busy capture is a
    # half-redraw (mid-repaint, no chevron).
    if (( turn % 3 == 0 )); then
        build_garble_frame "$FRAME_DIR/byst-garble-$turn.ansi" "${BYST_LINES[@]}"
        set_window_frame bystander "$FRAME_DIR/byst-garble-$turn.ansi"
    fi
    if (( turn % 4 == 0 )); then
        build_halfredraw_frame "$FRAME_DIR/convo-half-$turn.ansi" "${CONVO_LINES[@]}"
        set_window_frame convo "$FRAME_DIR/convo-half-$turn.ansi"
    fi
    cycle

    # Answer rendered; pane idles with the grown transcript.
    CONVO_LINES+=("Turn ${turn} answer: agent explains subsystem ${turn} in detail")
    build_frame "$FRAME_DIR/convo-idle-$turn.ansi" idle 30 empty "${CONVO_LINES[@]}"
    set_window_frame convo "$FRAME_DIR/convo-idle-$turn.ansi"
    # Bystander back to its clean (unchanged) idle frame.
    set_window_frame bystander "$FRAME_DIR/byst-idle.ansi"
    cycle

    assert_contains "turn $turn: convo engaged on idle cycle" "$CYCLE_OUT" $'convo\toperator-engaged'
    assert_not_contains "turn $turn: convo nag suppressed"    "$CYCLE_OUT" $'convo\tno-wrap-up'
    assert_eq "turn $turn: bystander still unmarked" \
        "$(oe_marked_windows | grep -c bystander)" 0
done

assert_contains "after 12 turns: bystander still nags normally" \
    "$CYCLE_OUT" $'bystander\tno-wrap-up'
assert_eq "after 12 turns: exactly one window ever marked" \
    "$(oe_marked_windows | sort -u | tr '\n' ' ' | xargs)" "convo"
CONVO_SINCE_MAIN=$(oe_since convo)

# A genuinely-active session must survive a distorted frame followed by
# a clean one (the "next clean frame" requirement): convo hits a garble
# cycle with NO submit in flight, then a clean cycle — both must keep
# the engaged classification (change-TTL still satisfied).
echo '=== distortion mid-conversation: no drop on the next clean frame ==='
build_garble_frame "$FRAME_DIR/convo-garble.ansi" "${CONVO_LINES[@]}"
set_window_frame convo "$FRAME_DIR/convo-garble.ansi"
cycle
set_window_frame convo "$FRAME_DIR/convo-idle-12.ansi"
cycle
assert_contains "post-garble clean frame: still engaged" "$CYCLE_OUT" $'convo\toperator-engaged'
assert_eq "post-garble: same episode (since unchanged)" "$(oe_since convo)" "$CONVO_SINCE_MAIN"

# ---- self-expiry + re-engage under a short TTL -----------------------------
#
# The operator walks away; the pane goes static (same idle frame, only
# input-row noise churning). With the change TTL shrunk to 3 s the mark
# must lapse, every suppression surface dropping at once, and a fresh
# corroborated submit must re-engage.

echo '=== self-expiry: static pane past the TTL releases the window ==='
TTL=3
# Static stretch: only the hash-invisible noise frame cycles.
build_frame "$FRAME_DIR/convo-static-noise.ansi" idle 55 ghost "${CONVO_LINES[@]}"
assert_eq "noise variant of final transcript is hash-identical" \
    "$(frame_hash "$FRAME_DIR/convo-static-noise.ansi")" \
    "$(frame_hash "$FRAME_DIR/convo-idle-12.ansi")"
set_window_frame convo "$FRAME_DIR/convo-static-noise.ansi"
run_probe_capture CYCLE_OUT CYCLE_RC \
    "MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS=$TTL MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers"
assert_contains "static cycle 1 (within TTL): still engaged" "$CYCLE_OUT" $'convo\toperator-engaged'
sleep $(( TTL + 2 ))
run_probe_capture CYCLE_OUT CYCLE_RC \
    "MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS=$TTL MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers"
assert_not_contains "static past TTL: mark lapsed"          "$CYCLE_OUT" $'convo\toperator-engaged'
assert_contains     "static past TTL: nag resumes"          "$CYCLE_OUT" $'convo\tno-wrap-up'

echo '=== re-engage: returning operator re-marks in one corroborated cycle ==='
stamp_user_prompt convo "$(date +%s)"
CONVO_LINES+=("Turn 13 answer: agent resumes after the operator returns")
build_frame "$FRAME_DIR/convo-idle-13.ansi" idle 8 empty "${CONVO_LINES[@]}"
set_window_frame convo "$FRAME_DIR/convo-idle-13.ansi"
run_probe_capture CYCLE_OUT CYCLE_RC \
    "MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS=$TTL MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers"
assert_contains "fresh submit + change: engaged again" "$CYCLE_OUT" $'convo\toperator-engaged'

# ---- phantom submit under frozen-hash distortion ---------------------------
#
# The fail-closed core: a submit stamp arrives for a window whose pane
# shows ONLY input-row noise (ghost/cursor/digit churn — hash frozen).
# No real content change ever lands, so after the await TTL the submit
# must be consumed WITHOUT a mark and the window must keep nagging.

echo '=== phantom submit + noise-only distortion: withheld, never marked ==='
rm -f "$STATE_DIR/idle-state.tsv" "$STATE_DIR/engagement-log.tsv" \
      "$STATE_DIR/idle-probe-previous-windows.txt" "$STATE_DIR/operator-engaged.tsv"
rm -rf "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"
: > "$LOG"
unset MOCK_PANE_STATE_convo MOCK_CONTENT_HASH_convo \
      MOCK_PANE_STATE_bystander MOCK_CONTENT_HASH_bystander
NOW=$(date +%s)
export MOCK_TMUX_WINDOWS="$(printf 'phantom|%s' "$(( NOW - 7200 ))")"
printf 'phantom\t%s\n' "$(( NOW - 7200 ))" > "$STATE_DIR/engagement-log.tsv"

build_frame "$FRAME_DIR/ph-clean.ansi" idle 3 empty "phantom transcript line"
build_frame "$FRAME_DIR/ph-noise.ansi" idle 59 ghost "phantom transcript line"
set_window_frame phantom "$FRAME_DIR/ph-clean.ansi"
# First sight counts as change, so let the first-sight corroboration
# age out past the TTL before the phantom submit lands.
run_probe_capture CYCLE_OUT CYCLE_RC \
    "MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS=$TTL MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers"
sleep $(( TTL + 2 ))
stamp_user_prompt phantom "$(date +%s)"
set_window_frame phantom "$FRAME_DIR/ph-noise.ansi"   # hash-frozen churn
run_probe_capture CYCLE_OUT CYCLE_RC \
    "MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS=$TTL MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers"
assert_not_contains "await: no premature mark"        "$CYCLE_OUT" $'phantom\toperator-engaged'
assert_contains     "await: still nags"               "$CYCLE_OUT" $'phantom\tno-wrap-up'
sleep $(( TTL + 2 ))
set_window_frame phantom "$FRAME_DIR/ph-clean.ansi"   # noise settles; hash still frozen
run_probe_capture CYCLE_OUT CYCLE_RC \
    "MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS=$TTL MONITOR_IDLE_THRESHOLD_SECONDS=0 list_really_idle_workers"
assert_not_contains "post-await: never marked"        "$CYCLE_OUT" $'phantom\toperator-engaged'
assert_contains     "post-await: keeps nagging"       "$CYCLE_OUT" $'phantom\tno-wrap-up'
assert_eq "post-await: submit consumed without a mark (since=0)" "$(oe_since phantom)" 0

# ---- summary ----------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
