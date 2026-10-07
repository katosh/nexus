#!/usr/bin/env bash
# The full-state idle backoff must CLIMB on a board where only worker
# ACTIVITY changes — your-org/nexus-code#1736.
#
# The defect: main.sh compared the whole full-state canonical, which carries
# each worker's busy / working-background / idle state and the busy/idle
# counts. A worker woken by its own longjob watch flips that axis twice in a
# minute, so with a handful of self-waking workers every flip (a) emitted at
# once and (b) reset the idle-streak anchor. The backoff never left its base
# rung: 11 non-actionable `poll-full-state` emits in 4 h 11 m, 2026-10-04.
#
# WHY THE EXISTING SUITES MISSED IT: test-full-state-idle-backoff.sh tests
# the floor helper against a GIVEN idle duration, and
# test-full-state-clock-only-change.sh moves only the clock. Neither moves
# activity, and neither runs the gate long enough to see the ladder.
#
# Driven END TO END: the REAL `_v2_task_compose_emit` from main.sh, with the
# REAL `_emit_dedup.sh` (volatile strip, effective floor, actionable
# projection). Only the board renderers, the paste and the clock are stubbed.
# The clock is a `date` function returning FAKE_NOW, and the canonical
# cache's mtime is pinned to FAKE_NOW whenever compose rewrites it, so 60
# simulated hours run in seconds.
#
# PREDICTED before running, against base (78e59f60, no projection, default
# max 7200):
#   FLIP  case 1 "climbs to the 86400 cap" and "<= 12 heartbeats in 60 h"
#         (base: the anchor resets on every flip, ~one emit per due tick)
#   FLIP  case 3 "activity flip at deep idle: no paste / anchor unchanged"
#   FLIP  case 4 "a delivered request / decision snaps the anchor back"
#         (run with the full-state check NOT due; the first draft let a due
#         check reset the anchor and the request row passed on base)
#   FLIP  case 5 "_config.sh default max is 86400" and the helper default
#   HOLD  case 2 "a new window emits within one due tick" (base emits too)
#   HOLD  case 3 control "nothing changes: no paste"
#   HOLD  case 6 "projection missing: an activity flip still EMITS"
#         (base compares full canonicals, so it emits as well)
#
# #1738 F2, PREDICTED before running against base 6f1f99d5 (READ FAILED
# folded into `live`, no streak, no knob):
#   FLIP  case 5 "_config.sh default READ FAILED persistence is 3 polls"
#   FLIP  case 7 both streak preconditions (no streak file on base)
#   FLIP  case 7 "persisting N polls EMITS" and "crossing: the anchor snaps back"
#   FLIP  case 7 "a persistent READ FAILED recovering emits once"
#   HOLD  case 7 flicker (no paste, anchor unchanged), below-N, "no second
#         paste" — base never emits for READ FAILED at all, so these pass
#         there too; they guard the HEAD against over-firing.
#
# #1738 F1, case 8: HOLD on base and head (both projections keep row classes
# and the pane-absent counter). What it adds is POTENCY: each axis moves
# ALONE, so a subject mutant that projects every row to `live`, or drops the
# pane-absent counter, is killed — case 3 moves both at once and let both
# survive (mutation-gate.sh --subject _emit_dedup.sh, recorded in #1738).
#
# #1738 F3, case 9, PREDICTED against base 6f1f99d5 (every delivery snaps):
#   FLIP  "an UNCHANGED request re-paste keeps the anchor"
#   FLIP  "an UNCHANGED decision re-paste keeps the anchor"
#   HOLD  both "re-pasted" rows, "a CHANGED decision snaps", "a NEW request
#         beside a standing one snaps" (base snaps on everything)
#
# Run: bash monitor/watcher/test-full-state-actionable-backoff.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo=$(cd "$_test_dir/../.." && pwd)
# The subjects, repo-relative. The body resolves every path it drives from
# this list, and gp_population CALLS it rather than restating it.
_subjects() {
    printf '%s\n' monitor/watcher/main.sh monitor/watcher/_emit_dedup.sh \
        monitor/watcher/_config.sh config/load.sh
}
# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() { _subjects; }
gp_handle "$@"
# Readers here consume ALL their input (awk, no exit): an early-closing reader
# is an early-exit site the census tracks (test-early-exit-reader-manifest.sh).
_subject() { _subjects | awk -v k="$1" '!f && index($0, k) { print; f = 1 }'; }
MAIN_SH="$_repo/$(_subject watcher/main.sh)"
EMIT_DEDUP_SH="$_repo/$(_subject _emit_dedup.sh)"
CONFIG_SH="$_repo/$(_subject _config.sh)"
LOAD_SH="$_repo/$(_subject config/load.sh)"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() { [[ "$2" == "$3" ]] && pass "$1 (=$2)" || fail "$1: got '$2' want '$3'"; }
assert_le() { (( $2 <= $3 )) && pass "$1 ($2 <= $3)" || fail "$1: $2 > $3"; }
assert_ge() { (( $2 >= $3 )) && pass "$1 ($2 >= $3)" || fail "$1: $2 < $3"; }
_extract_fn() { sed -n "/^$2() {/,/^}/p" "$1"; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# ---- fixture ---------------------------------------------------------------
export STATE_DIR="$W/state" TARGET="orchestrator"
mkdir -p "$STATE_DIR" "$W/stage" "$W/tmp"
V2_STAGE_DIR="$W/stage"; tmp_dir="$W/tmp"; emit_body="$W/tmp/emit.md"
BASELINE="$STATE_DIR/last-snapshot.txt"; LAST_CHANGE="$STATE_DIR/last-change.txt"
FULL_STATE_STAMP="$STATE_DIR/last-full-state-emit.ts"
FULL_STATE_CANONICAL_CACHE="$STATE_DIR/last-full-state-canonical.txt"
FULL_STATE_IDLE_ANCHOR="$STATE_DIR/last-full-state-change.ts"
RESPAWN_HISTORY="$W/rh" RESPAWN_TRIPPED="$W/rt" RESPAWN_CONSEC_COUNTER="$W/rc" RESPAWN_SLOW_GRIND_TRIPPED="$W/rs"
SERVICE_HEALTH_STATE_DIR="$W" VERSION_STATE_DIR="$W" REPORTS_ROLL_NOTICE_FILE="$W/roll" WATCHER_SUPERVISOR_HEARTBEAT="$W/hb"
NEXUS_ROOT="$W"
# The production defaults, stated: 600 s due cadence, 900 s base floor.
MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS=600
MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS=900
MONITOR_FULL_STATE_IDLE_BACKOFF_ENABLED=true
MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=86400
MONITOR_FULL_STATE_READ_FAILED_PERSIST_POLLS=3   # the _config.sh default, stated
export MONITOR_FULL_STATE_READ_FAILED_PERSIST_POLLS
MONITOR_FULL_STATE_RESTAT_WINDOWS=false MONITOR_IDLE_RESTAT_WINDOWS=false
export MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS MONITOR_FULL_STATE_IDLE_BACKOFF_ENABLED MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS

# The REAL change-detection contract.
# shellcheck source=_emit_dedup.sh
source "$EMIT_DEDUP_SH"

# ---- the clock ---------------------------------------------------------------
FAKE_NOW=1800000000
date() {
    if [[ $# -eq 1 && "$1" == "+%s" ]]; then printf '%s\n' "$FAKE_NOW"; return 0; fi
    if [[ $# -eq 3 && "$1" == "+%s" && "$2" == "-r" ]]; then stat -c %Y "$3" 2>/dev/null; return; fi
    command date "$@"
}

# ---- the board ---------------------------------------------------------------
# WORKERS[name]=busy|working-background|idle ; ABSENT[name]=1 for pane-absent;
# RFAIL[name]=1 for a pane-state READ FAILED row (the production wording);
# CLASS[name]=<class> renders a non-activity row class WITHOUT moving any
# prelude counter, and EXTRA_ABSENT moves the pane-absent counter WITHOUT a
# row (#1738 F1: each axis alone).
declare -A WORKERS=() ABSENT=() NEXT_FLIP=() RFAIL=() CLASS=()
EXTRA_ABSENT=0
WORDER=()
add_worker() { WORKERS[$1]="$2"; WORDER+=("$1"); NEXT_FLIP[$1]=$(( FAKE_NOW + 300 + ${#WORDER[@]} * 37 )); }
render_idle_prelude() {
    local w busy=0 idle=0 absent=0
    for w in "${WORDER[@]}"; do
        if [[ -n "${ABSENT[$w]:-}" ]]; then absent=$(( absent + 1 ))
        elif [[ "${WORKERS[$w]}" == idle ]]; then idle=$(( idle + 1 ))
        else busy=$(( busy + 1 )); fi
    done
    printf '%d busy | %d idle | 0 retained | 0 idle-too-long | %d pane-absent | 0 over-limit | 0 orphan-async | 0 interrupted | 0 parked-skeptic | 0 idle-children | 0 awaiting-input\n' \
        "$busy" "$idle" $(( absent + EXTRA_ABSENT ))
}
render_full_state_snapshot() {
    local w
    for w in "${WORDER[@]}"; do
        if [[ -n "${ABSENT[$w]:-}" ]]; then printf '  - %s pane-absent (state=absent)\n' "$w"
        elif [[ -n "${CLASS[$w]:-}" ]]; then
            printf '  - %s %s (1 live child(ren) after wrap-up — inconsistency; clarify or close)\n' "$w" "${CLASS[$w]}"
        elif [[ -n "${RFAIL[$w]:-}" ]]; then
            printf '  - %s idle %ds (state=unknown; pane-state.sh READ FAILED (rc=124, stderr: timed out) — an INSTRUMENT failure, not a pane classification; a direct `monitor/pane-state.sh %s` may well classify it)\n' \
                "$w" $(( FAKE_NOW % 7000 )) "$w"
        elif [[ "${WORKERS[$w]}" == idle ]]; then printf '  - %s idle %ds (state=idle)\n' "$w" $(( FAKE_NOW % 7000 ))
        else printf '  - %s (active, state=%s)\n' "$w" "${WORKERS[$w]}"; fi
    done
}
# Deterministic 5–10 min flips: busy → working-background → idle → busy.
FLIPS=0
flip_due_workers() {
    local w k=0
    for w in "${WORDER[@]}"; do
        k=$(( k + 1 ))
        (( FAKE_NOW >= NEXT_FLIP[$w] )) || continue
        case "${WORKERS[$w]}" in
            busy) WORKERS[$w]=working-background ;;
            working-background) WORKERS[$w]=idle ;;
            *) WORKERS[$w]=busy ;;
        esac
        FLIPS=$(( FLIPS + 1 ))
        NEXT_FLIP[$w]=$(( FAKE_NOW + 300 + (FAKE_NOW / 60 * 7 + k * 53) % 301 ))
    done
}

# ---- collaborators (stubbed) -----------------------------------------------
PASTES="$W/pastes"; : > "$PASTES"; LOGCAP="$W/log"; : > "$LOGCAP"
log() { printf '%s\n' "$*" >> "$LOGCAP"; }
_ensure_watcher_tmp_dir() { mkdir -p "$tmp_dir"; }
_progress_bump() { :; }; _cycle_bump() { :; }; bump_heartbeat() { :; }
_compose_gh_now() { :; }; _render_budget_seconds() { printf 5; }; _bounded_failure_log() { :; }
_run_bounded() { local o="$2"; shift 2; "$@" > "$o"; }
_classify_diff() { return 0; }
_oneshot_reset() { :; }; _oneshot_defer() { :; }; _oneshot_commit() { :; }
_cc_update_emit_section() { :; }; _version_emit_section() { :; }; _service_health_emit_section() { :; }
_reports_roll_emit_section() { :; }; _supervisor_arm_emit_section() { :; }
compose_report() { printf 'reason=%s\n' "$1"; }
archive_emit() { printf '%s/archive.md' "$W"; }
_compose_emit_should_suppress() { return 1; }   # the hash-ring gate is not under test
_over_limit_orchestrator_paused() { return 1; }; _auth_hold_active() { return 1; }
paste_with_retry() { printf '%s %s\n' "$FAKE_NOW" "$(head -n1 "$2")" >> "$PASTES"; return 0; }
_emit_delivery_ok() { :; }; _compose_emit_record_emit() { :; }; requests_commit_emitted() { :; }
_respawn_loop_reset() { :; }; _respawn_consec_reset() { :; }
eval "$(_extract_fn "$MAIN_SH" _v2_task_compose_emit)"
declare -F _v2_task_compose_emit >/dev/null || { echo "FATAL: could not extract _v2_task_compose_emit from main.sh" >&2; exit 1; }

# A quiet local diff: snapshot == baseline, so only the full-state path speaks.
printf 'fmt v1\nquiet\n' > "$V2_STAGE_DIR/snapshot_local.out"
cp "$V2_STAGE_DIR/snapshot_local.out" "$BASELINE"

# One compose tick at FAKE_NOW. Pins the cache's mtime to the fake clock
# whenever compose REWROTE it (a new inode: compose writes tmp + mv).
tick() {
    local ino_before ino_after
    ino_before=$(stat -c %i "$FULL_STATE_CANONICAL_CACHE" 2>/dev/null || echo none)
    _v2_task_compose_emit 2>>"$W/stderr"
    ino_after=$(stat -c %i "$FULL_STATE_CANONICAL_CACHE" 2>/dev/null || echo none)
    [[ "$ino_after" != none && "$ino_after" != "$ino_before" ]] && touch -d "@$FAKE_NOW" "$FULL_STATE_CANONICAL_CACHE"
    return 0
}
TICK=300   # CHOSEN: 60 h in 720 compose ticks; flips are 300-600 s apart, so most ticks see a change
run_until() {   # <end_epoch> — flip workers and compose every TICK seconds
    while (( FAKE_NOW < $1 )); do
        FAKE_NOW=$(( FAKE_NOW + TICK ))
        flip_due_workers
        tick
    done
}
paste_count() { wc -l < "$PASTES"; }
full_state_times() { awk '$2=="reason=poll-full-state" {print $1}' "$PASTES"; }
anchor() { cat "$FULL_STATE_IDLE_ANCHOR" 2>/dev/null || echo none; }

for w in w1 w2 w3 w4 w5 w6; do add_worker "$w" working-background; done

# ---------------------------------------------------------------------------
echo "=== case 1: a board that only flips activity climbs the ladder to 86400 ==="
T0=$FAKE_NOW
tick                                   # cold start: the first full-state emit
run_until $(( T0 + 60 * 3600 ))
mapfile -t EMITS < <(full_state_times)
gaps=(); for (( i = 1; i < ${#EMITS[@]}; i++ )); do gaps+=( $(( EMITS[i] - EMITS[i-1] )) ); done
echo "    full-state emits: ${#EMITS[@]}   gaps (s): ${gaps[*]}"
# Potency: the board really did churn. Without this, a climb is vacuous.
assert_ge "precondition: workers flipped activity many times" "$FLIPS" 300
assert_le "<= 12 heartbeats in 60 h of activity-only churn" "${#EMITS[@]}" 12
nondecreasing=1; for (( i = 1; i < ${#gaps[@]}; i++ )); do (( gaps[i] >= gaps[i-1] )) || nondecreasing=0; done
assert_eq "the gaps never shrink (no anchor reset)" "$nondecreasing" 1
last_gap=${gaps[${#gaps[@]}-1]:-0}
assert_ge "the last gap reached the 86400 cap" "$last_gap" 86400
assert_le "…and the cap is a cap (<= 86400 + one due tick + one compose tick)" "$last_gap" $(( 86400 + 600 + TICK ))
if grep -q '/86400s (base 900s' "$LOGCAP"; then pass "the suppression log names the 86400 floor"
else fail "the suppression log never names the 86400 floor"; fi
if [[ -s "$W/stderr" ]]; then fail "compose wrote to stderr: $(head -3 "$W/stderr")"; else pass "compose ran clean (no stderr)"; fi

# ---------------------------------------------------------------------------
echo "=== case 2: a NEW WINDOW emits within one due tick and snaps the anchor back ==="
: > "$PASTES"
add_worker w7 busy
T2=$FAKE_NOW
TICK=60; run_until $(( T2 + 660 ))
first=$(full_state_times | awk 'NR == 1')
assert_le "the new window emitted within one due tick" $(( ${first:-999999999} - T2 )) 660
assert_eq "the anchor snapped back to that emit" "$(anchor)" "${first:-none}"
TICK=300; run_until $(( FAKE_NOW + 3000 ))
second=$(full_state_times | awk 'NR == 2')
assert_le "the next heartbeat is back at the base rung" $(( ${second:-999999999} - ${first:-0} )) $(( 900 + 600 + TICK ))

# ---------------------------------------------------------------------------
# Deep idle without re-climbing: the anchor is 40 h old, the last emit 10 h.
deep_idle() {
    printf '%s' $(( FAKE_NOW - 144000 )) > "$FULL_STATE_IDLE_ANCHOR"
    touch -d "@$(( FAKE_NOW - 36000 ))" "$FULL_STATE_CANONICAL_CACHE"
    # The full-state check is DUE, unless `notdue`: then only another
    # trigger can paste or move the anchor this tick. Case 4 needs that,
    # or a due full-state compare could reset the anchor itself and the
    # assertion would pass for the wrong reason (it did, on base).
    if [[ "${1:-}" == notdue ]]; then printf '%s\n' "$FAKE_NOW" > "$FULL_STATE_STAMP"
    else printf '%s\n' $(( FAKE_NOW - 600 )) > "$FULL_STATE_STAMP"; fi
    : > "$PASTES"
}

echo "=== case 3: at deep idle an activity flip neither emits nor resets ==="
deep_idle; a0=$(anchor)
FAKE_NOW=$(( FAKE_NOW + 1 )); tick
assert_eq "control: nothing changes → no paste" "$(paste_count)" 0
deep_idle; a0=$(anchor)
for w in "${WORDER[@]}"; do [[ "${WORKERS[$w]}" == idle ]] && WORKERS[$w]=busy || WORKERS[$w]=idle; done
FAKE_NOW=$(( FAKE_NOW + 1 )); tick
assert_eq "activity flip at deep idle: no paste" "$(paste_count)" 0
assert_eq "activity flip at deep idle: anchor unchanged" "$(anchor)" "$a0"
deep_idle
ABSENT[w2]=1
FAKE_NOW=$(( FAKE_NOW + 1 )); tick
assert_eq "a pane going ABSENT at deep idle emits at once" "$(awk '{print $2}' "$PASTES")" "reason=poll-full-state"
assert_eq "…and snaps the anchor back" "$(anchor)" "$FAKE_NOW"
unset 'ABSENT[w2]'

# ---------------------------------------------------------------------------
echo "=== case 4: a delivered request or decision snaps the anchor back ==="
deep_idle notdue
printf 'request=r1 origin=w1 kind=question priority=normal\n' > "$V2_STAGE_DIR/requests_poll.out"
FAKE_NOW=$(( FAKE_NOW + 1 )); tick
assert_eq "the request pasted" "$(paste_count)" 1
assert_eq "a delivered request snaps the anchor back" "$(anchor)" "$FAKE_NOW"
: > "$V2_STAGE_DIR/requests_poll.out"
deep_idle notdue
printf 'window=w3 fp=abc kind=permission_prompt unresolved=true\n' > "$V2_STAGE_DIR/pending_decisions.out"
FAKE_NOW=$(( FAKE_NOW + 1 )); tick
assert_eq "the decision pasted" "$(paste_count)" 1
assert_eq "a delivered decision snaps the anchor back" "$(anchor)" "$FAKE_NOW"
: > "$V2_STAGE_DIR/pending_decisions.out"

# ---------------------------------------------------------------------------
echo "=== case 5: the ceiling default is 86400 and it is a cap ==="
cfg=$(mktemp -d "$W/cfg.XXXX"); mkdir -p "$cfg/config"; cp "$LOAD_SH" "$cfg/config/"
got=$(env -u MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS bash -c \
    "NEXUS_ROOT='$cfg' STATE_DIR='$cfg/s'; source '$CONFIG_SH' >/dev/null 2>&1; printf '%s' \"\$MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS\"")
assert_eq "_config.sh default max (no nexus.yml) is 86400" "$got" 86400
dflt() { env -u MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS bash -c "source '$EMIT_DEDUP_SH'; _full_state_effective_floor $1"; }
assert_eq "helper default: idle 115199 → 57600" "$(dflt 115199)" 57600
assert_eq "helper default: idle 115200 → 86400" "$(dflt 115200)" 86400
assert_eq "helper default: idle 10^7 → 86400 (capped)" "$(dflt 10000000)" 86400
got=$(env -u MONITOR_FULL_STATE_READ_FAILED_PERSIST_POLLS bash -c \
    "NEXUS_ROOT='$cfg' STATE_DIR='$cfg/s'; source '$CONFIG_SH' >/dev/null 2>&1; printf '%s' \"\$MONITOR_FULL_STATE_READ_FAILED_PERSIST_POLLS\"")
assert_eq "_config.sh default READ FAILED persistence is 3 polls" "$got" 3

# ---------------------------------------------------------------------------
echo "=== case 7: a pane-state READ FAILED that PERSISTS N polls is actionable (#1738 F2) ==="
# One DUE full-state poll, 600 s on: the unit the persistence threshold counts.
due_poll() { FAKE_NOW=$(( FAKE_NOW + 600 )); printf '%s\n' $(( FAKE_NOW - 600 )) > "$FULL_STATE_STAMP"; tick; }
streak_of() { awk -F'\t' -v w="$1" '$1 == w { s = $2 } END { print s + 0 }' "$STATE_DIR/full-state-read-failed-streak.tsv" 2>/dev/null || echo 0; }
N=$MONITOR_FULL_STATE_READ_FAILED_PERSIST_POLLS
# Settle: case 3 left the cache holding w2 pane-absent; one due poll re-syncs
# it, so the first flicker poll is not compared against a stale board.
due_poll
# Flicker: failing every OTHER poll for 2N polls never reaches N.
deep_idle; rm -f "$STATE_DIR/full-state-read-failed-streak.tsv"; a0=$(anchor); peak=0
for (( i = 1; i <= 2 * N; i++ )); do
    if (( i % 2 )); then RFAIL[w4]=1; else unset 'RFAIL[w4]'; fi
    due_poll
    (( $(streak_of w4) > peak )) && peak=$(streak_of w4)
done
unset 'RFAIL[w4]'
assert_eq "precondition: the flickering row WAS counted (peak streak)" "$peak" 1
assert_eq "READ FAILED flickering for 2N polls: no paste" "$(paste_count)" 0
assert_eq "READ FAILED flickering for 2N polls: anchor unchanged (backoff not reset)" "$(anchor)" "$a0"
# Below N: N-1 consecutive failing polls.
deep_idle; a0=$(anchor); RFAIL[w4]=1
for (( i = 1; i < N; i++ )); do due_poll; done
assert_eq "precondition: the streak counted N-1 consecutive polls" "$(streak_of w4)" $(( N - 1 ))
assert_eq "READ FAILED for N-1 polls: no paste" "$(paste_count)" 0
assert_eq "READ FAILED for N-1 polls: anchor unchanged" "$(anchor)" "$a0"
# The N-th consecutive poll crosses: actionable, at deep idle.
due_poll
assert_eq "READ FAILED persisting N polls EMITS at deep idle" "$(awk '{print $2}' "$PASTES")" "reason=poll-full-state"
assert_eq "READ FAILED crossing: the anchor snaps back" "$(anchor)" "$FAKE_NOW"
# Once: still failing, back at deep idle, nothing new.
deep_idle; due_poll
assert_eq "still READ FAILED after the emit: no second paste" "$(paste_count)" 0
# Recovery of a persistent failure differs from what was last emitted: one emit.
deep_idle; unset 'RFAIL[w4]'; due_poll
assert_eq "a persistent READ FAILED recovering emits once" "$(paste_count)" 1

# ---------------------------------------------------------------------------
echo "=== case 8: a row class ALONE, and a counter ALONE, each emit (#1738 F1) ==="
# Case 3's pane-absent moves a row class AND the pane-absent counter at once,
# so a projection that dropped every row class, or dropped the pane-absent
# counter, still emitted there on the other axis. Each axis alone here.
canon() { printf '%s\n---snapshot---\n%s' "$(render_idle_prelude)" "$(render_full_state_snapshot)" | _emit_volatile_strip; }
prelude_now() { canon | awk '$0 == "---snapshot---" { f = 1 } !f { print }'; }
rows_now() { canon | awk 'f { print } $0 == "---snapshot---" { f = 1 }'; }
due_poll                                # settle: case 7 left a recovery to sync
deep_idle; p0=$(prelude_now); r0=$(rows_now)
CLASS[w5]=wrapped-with-children
assert_eq "precondition: the row class moved" "$( [[ "$(rows_now)" != "$r0" ]] && echo moved )" moved
assert_eq "precondition: no prelude counter moved" "$(prelude_now)" "$p0"
FAKE_NOW=$(( FAKE_NOW + 1 )); tick
assert_eq "a row class change ALONE emits at deep idle" "$(awk '{print $2}' "$PASTES")" "reason=poll-full-state"
assert_eq "row class alone: the anchor snaps back" "$(anchor)" "$FAKE_NOW"
unset 'CLASS[w5]'; due_poll             # settle
deep_idle; p0=$(prelude_now); r0=$(rows_now)
EXTRA_ABSENT=1
assert_eq "precondition: the pane-absent counter moved" "$( [[ "$(prelude_now)" != "$p0" ]] && echo moved )" moved
assert_eq "precondition: no row moved" "$(rows_now)" "$r0"
FAKE_NOW=$(( FAKE_NOW + 1 )); tick
assert_eq "the pane-absent counter ALONE emits at deep idle" "$(awk '{print $2}' "$PASTES")" "reason=poll-full-state"
assert_eq "counter alone: the anchor snaps back" "$(anchor)" "$FAKE_NOW"
EXTRA_ABSENT=0; due_poll                # settle

# ---------------------------------------------------------------------------
echo "=== case 9: a re-paste of an UNCHANGED standing item keeps the backoff (#1738 F3) ==="
# Case 4 delivered request r1 and decision w3/abc once. Their re-nag re-pastes
# them unchanged: the paste still goes out, the anchor must not move.
deep_idle notdue; a0=$(anchor)
printf 'request=r1 origin=w1 kind=question priority=normal\n' > "$V2_STAGE_DIR/requests_poll.out"
FAKE_NOW=$(( FAKE_NOW + 1 )); tick
assert_eq "the unchanged request re-pasted" "$(paste_count)" 1
assert_eq "an UNCHANGED request re-paste keeps the anchor" "$(anchor)" "$a0"
: > "$V2_STAGE_DIR/requests_poll.out"
deep_idle notdue; a0=$(anchor)
printf 'window=w3 fp=abc kind=permission_prompt unresolved=true\n' > "$V2_STAGE_DIR/pending_decisions.out"
FAKE_NOW=$(( FAKE_NOW + 1 )); tick
assert_eq "the unchanged decision re-pasted" "$(paste_count)" 1
assert_eq "an UNCHANGED decision re-paste keeps the anchor" "$(anchor)" "$a0"
: > "$V2_STAGE_DIR/pending_decisions.out"
# A CHANGED item (the same decision now resolved) and a NEW one both snap.
deep_idle notdue
printf 'window=w3 fp=abc kind=permission_prompt unresolved=false\n' > "$V2_STAGE_DIR/pending_decisions.out"
FAKE_NOW=$(( FAKE_NOW + 1 )); tick
assert_eq "a CHANGED decision snaps the anchor back" "$(anchor)" "$FAKE_NOW"
: > "$V2_STAGE_DIR/pending_decisions.out"
deep_idle notdue
printf 'request=r1 origin=w1 kind=question priority=normal\nrequest=r2 origin=w2 kind=question priority=normal\n' > "$V2_STAGE_DIR/requests_poll.out"
FAKE_NOW=$(( FAKE_NOW + 1 )); tick
assert_eq "a NEW request beside a standing one snaps the anchor back" "$(anchor)" "$FAKE_NOW"
: > "$V2_STAGE_DIR/requests_poll.out"

# ---------------------------------------------------------------------------
echo "=== case 6: without the projection the gate fails toward EMITTING ==="
deep_idle
unset -f _full_state_actionable_projection
for w in "${WORDER[@]}"; do [[ "${WORKERS[$w]}" == idle ]] && WORKERS[$w]=busy || WORKERS[$w]=idle; done
FAKE_NOW=$(( FAKE_NOW + 1 )); tick
assert_eq "projection missing: an activity flip still EMITS" "$(paste_count)" 1

echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
