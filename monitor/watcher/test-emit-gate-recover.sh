#!/usr/bin/env bash
# Regression contract for the recovered change-or-timeout emit gating
# (emit-gate-recover, 2026-07-06). The live watcher had regressed to
# re-pasting a full-state snapshot every ~600s on an UNCHANGED
# workspace and re-surfacing a static parked worker every ~60s. Four
# root causes, each pinned here so it cannot silently reopen:
#
#   R1  The full-state canonical strip only knew `idle Ns`; renderers
#       later grew `operator away Ns` / `interrupted NhNNm` tokens
#       that made every render unique and defeated the issue-#104
#       identity check. → shared `_emit_volatile_strip`.
#   R2  Single-slot emit-dedup cannot converge on an ALTERNATING pair
#       of body shapes (parked-transition row ↔ pending-decision
#       re-nag). → recent-hash ring.
#   R3  A skeptic-parked worker's (window, class) transition row left
#       idle-state.tsv on every busy flap of its await loop, so each
#       idle re-entry re-emitted "parked-awaiting-skeptic". → carry
#       parked rows across busy episodes (same mechanism as
#       operator-engaged, issue #196).
#   R4  A parked worker's standing `idle_prompt` decision re-nagged
#       every DECISION_REEMIT_COOLDOWN_SECONDS forever. → suppress
#       idle_prompt rows for skeptic-parked windows (same idiom as
#       the operator-engaged suppression, issues #196/#201).
#
# Contract asserted (task spec):
#   (a) unchanged canonical state across consecutive polls emits
#       NOTHING until the timeout;
#   (b) the safety-floor timeout HEARTBEAT does fire once the floor
#       expires, and full-state cadence emits bypass the (longer)
#       dedup quiet window so the heartbeat cannot be swallowed;
#   (c) a genuine state change emits promptly;
#   (d) a static parked worker does not re-surface every loop.
#
# Sections 1, 3, 4 and 5 FAIL against the pre-recovery gate — they
# are the proof the regression was real.
#
# Run: bash monitor/watcher/test-emit-gate-recover.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         got:  %q\n' "$got" >&2
        printf '         want: %q\n' "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_ne() {
    local label="$1" a="$2" b="$3"
    if [[ "$a" != "$b" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — values unexpectedly equal: %q\n' "$label" "$a" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_rc() {
    local label="$1" want_rc="$2" got_rc="$3"
    if [[ "$got_rc" == "$want_rc" ]]; then
        printf '  PASS: %s (rc=%s)\n' "$label" "$got_rc"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got rc=%s want rc=%s\n' "$label" "$got_rc" "$want_rc" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_empty() {
    local label="$1" got="$2"
    if [[ -z "$got" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — expected empty, got:\n%s\n' "$label" "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_nonempty() {
    local label="$1" got="$2"
    if [[ -n "$got" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — expected output, got nothing\n' "$label" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR"
export STATE_DIR

LOGFILE="$WORK/watcher.log"
export LOGFILE
log() {
    printf '[%s] %s\n' "$(date -Is)" "$*" >> "$LOGFILE" 2>/dev/null || true
}
export -f log

EMIT_DEDUP_HASH_FILE="$STATE_DIR/last-emit-stable-hash"
EMIT_DEDUP_TS_FILE="$STATE_DIR/last-emit-stable-ts"
EMIT_DEDUP_RING_FILE="$STATE_DIR/last-emit-stable-hash.ring"
export EMIT_DEDUP_HASH_FILE EMIT_DEDUP_TS_FILE EMIT_DEDUP_RING_FILE

# shellcheck source=_emit_dedup.sh
. "$_test_dir/_emit_dedup.sh"

# ---- 1. (a) volatile age tokens must not defeat the canonical --------------
#
# Reconstructed from the two consecutive live `poll-full-state`
# archives of 2026-07-06 (17:27:44 / 17:38:23): the ONLY content
# delta was `operator away 162491s; idle 162491s` growing — yet both
# pasted. The canonical (and stable hash) must collapse them.
echo '=== 1. canonical stability under operator-away / interrupted ages ==='

render_snapshot() {
    # $1 = away/idle seconds for the engaged row, $2 = interrupted age
    cat <<EOF
2 busy | 0 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | 1 interrupted | 0 parked-skeptic | 1 awaiting-input
---snapshot---
  - pr-refactor operator-engaged (operator away ${1}s; idle ${1}s, state=empty)
  - crashy interrupted (idle ${2}s; turn crashed, recovery=paste)
  - steady idle 42s (state=idle)
EOF
}

c1=$(render_snapshot 162491 300 | _emit_volatile_strip)
c2=$(render_snapshot 163091 900 | _emit_volatile_strip)
assert_eq "away/idle/interrupted counters collapse to one canonical" "$c1" "$c2"

# The pure suppression conditional from main.sh: canonical unchanged
# AND cache-mtime age < safety floor → suppress.
CANON_CACHE="$STATE_DIR/last-full-state-canonical.txt"
FLOOR=900
printf '%s' "$c1" > "$CANON_CACHE"
touch -d "5 minutes ago" "$CANON_CACHE"
now_ts=$(date +%s)
mtime=$(date +%s -r "$CANON_CACHE")
suppress=no
if [[ "$c2" == "$(cat "$CANON_CACHE")" ]] && (( now_ts - mtime < FLOOR )); then
    suppress=yes
fi
assert_eq "(a) unchanged canonical within floor → full-state suppressed" "$suppress" "yes"

# ---- 2. (b) the timeout heartbeat fires once the floor expires --------------
echo '=== 2. safety-floor heartbeat fires at the bounded interval ==='
touch -d "16 minutes ago" "$CANON_CACHE"    # floor is 900s = 15 min
mtime=$(date +%s -r "$CANON_CACHE")
suppress=no
if [[ "$c2" == "$(cat "$CANON_CACHE")" ]] && (( now_ts - mtime < FLOOR )); then
    suppress=yes
fi
assert_eq "(b) unchanged canonical past floor → heartbeat emits" "$suppress" "no"

# The heartbeat must not be swallowed downstream: main.sh's dedup
# call site is guarded so full_state_due bodies skip the (default
# 24h) quiet window. Asserted against the source because the guard
# lives at the call site, by design next to the canonical gate that
# adjudicates those bodies.
if grep -q 'full_state_due != 1' "$_test_dir/main.sh" \
   && grep -A1 'full_state_due != 1' "$_test_dir/main.sh" \
        | grep -q '_compose_emit_should_suppress'; then
    printf '  PASS: %s\n' "(b) dedup call site skips full_state_due bodies"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: main.sh dedup call is not full_state_due-guarded — the safety-floor heartbeat can be swallowed by the 24h dedup quiet window\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- 3. (c) a genuine state change emits promptly ---------------------------
echo '=== 3. genuine canonical change emits promptly ==='
c3=$(render_snapshot 163091 900 | sed 's/steady idle/steady-NEW idle/' | _emit_volatile_strip)
assert_ne "changed worker set → distinct canonical" "$c3" "$c2"
touch -d "5 minutes ago" "$CANON_CACHE"
mtime=$(date +%s -r "$CANON_CACHE")
suppress=no
if [[ "$c3" == "$(cat "$CANON_CACHE")" ]] && (( now_ts - mtime < FLOOR )); then
    suppress=yes
fi
assert_eq "(c) changed canonical → emit even within floor" "$suppress" "no"

# ---- 4. (d) A/B body alternation converges under the dedup ring -------------
#
# The live resurface flood alternated two shapes: (A) a
# parked-awaiting-skeptic transition row, (B) a pending idle_prompt
# decision re-nag. Single-slot dedup compares only against the
# immediately-previous body, so an alternation never suppresses.
echo '=== 4. alternating body shapes suppress via the hash ring ==='
rm -f "$EMIT_DEDUP_HASH_FILE" "$EMIT_DEDUP_TS_FILE" "$EMIT_DEDUP_RING_FILE"
unset MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS

body_A="$WORK/body-A.txt"
body_B="$WORK/body-B.txt"
write_shape() {
    # $1=path $2=ts $3=nonce $4=shape
    {
        printf '=== nexus state changed at %s (poll-resurface) ===\n' "$2"
        if [[ "$4" == A ]]; then
            cat <<'EOF'
workspace: 1 busy | 0 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | 0 interrupted | 1 parked-skeptic | 1 awaiting-input
--- idle workers ---
  - sweeper parked-awaiting-skeptic (idle 62s; skeptic reviewing — exempt from idle/close until verdict; see skills/nexus.skeptic)
(emitted on transitions only; see skills/nexus.window-cleanup)
EOF
        else
            cat <<'EOF'
workspace: 2 busy | 0 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | 0 interrupted | 0 parked-skeptic | 0 awaiting-input
--- pending decisions ---
window=sweeper fp=dc87da1b7e4d kind=idle_prompt unresolved=false
    prompt-excerpt=Claude is waiting for your input
    file=/x/monitor/.state/decisions/sweeper.dc87da1b7e4d.json(read the cited file for full JSON; ack by removing it once answered)
EOF
        fi
        printf -- '--- nexus-emit-sig %s %s ---\n' "$2" "$3"
    } > "$1"
}

apply() {
    if _compose_emit_should_suppress "$1" "poll-resurface"; then
        return 1
    fi
    _compose_emit_record_emit "$1"
    return 0
}

write_shape "$body_A" "2026-07-06T10:00:00-07:00" "aa0001" A
apply "$body_A"; rc1=$?
write_shape "$body_B" "2026-07-06T10:01:00-07:00" "bb0001" B
apply "$body_B"; rc2=$?
write_shape "$body_A" "2026-07-06T10:02:00-07:00" "aa0002" A
apply "$body_A"; rc3=$?
write_shape "$body_B" "2026-07-06T10:03:00-07:00" "bb0002" B
apply "$body_B"; rc4=$?
assert_rc "shape A first sighting emits" 0 "$rc1"
assert_rc "shape B first sighting emits" 0 "$rc2"
assert_rc "(d) shape A repeat suppresses despite intervening B" 1 "$rc3"
assert_rc "(d) shape B repeat suppresses despite intervening A" 1 "$rc4"

# Ring depth 1 must reproduce the legacy single-slot behavior
# (knob-driven degradation stays available).
rm -f "$EMIT_DEDUP_HASH_FILE" "$EMIT_DEDUP_TS_FILE" "$EMIT_DEDUP_RING_FILE"
export MONITOR_EMIT_DEDUP_RING_SIZE=1
apply "$body_A" >/dev/null; :
apply "$body_B" >/dev/null; :
write_shape "$body_A" "2026-07-06T10:04:00-07:00" "aa0003" A
apply "$body_A"; rc5=$?
assert_rc "ring depth 1 degrades to single-slot (alternation re-emits)" 0 "$rc5"
unset MONITOR_EMIT_DEDUP_RING_SIZE

# ---- 5. (d) a static parked worker does not re-surface every loop -----------
#
# Drive list_idle_transitions through a park → busy-flap → re-park
# cycle. The parked row must surface exactly ONCE per park episode;
# the busy flap of the await loop must not reset the dedupe.
echo '=== 5. parked-awaiting-skeptic row surfaces once per park episode ==='

NEXUS_ROOT="$WORK"
export NEXUS_ROOT
export MONITOR_SKEPTIC_AWAIT_HANG_SECONDS=600

# shellcheck source=_idle_probe.sh
. "$_test_dir/_idle_probe.sh"

# Override the classifier: the test scripts each cycle's idle set.
MOCK_IDLE_SET=""
list_really_idle_workers() { printf '%s\n' "$MOCK_IDLE_SET"; }

mkdir -p "$STATE_DIR/skeptic/pending"
touch "$STATE_DIR/skeptic/pending/sweeper"
rm -f "$STATE_DIR/idle-state.tsv"

parked_row=$'sweeper\tparked-awaiting-skeptic\t62\tskeptic reviewing; exempt from idle/close'

# Cycle 1: worker idles into the park → transition row emits.
MOCK_IDLE_SET="$parked_row"
out1=$(list_idle_transitions)
assert_nonempty "cycle 1 (park entry) emits the parked row" "$out1"

# Cycle 2: await-loop poll turns the pane busy → worker leaves the
# idle set entirely (empty set).
MOCK_IDLE_SET=""
out2=$(list_idle_transitions)
assert_empty "cycle 2 (busy flap) emits nothing" "$out2"
if grep -q $'sweeper\tparked-awaiting-skeptic' "$STATE_DIR/idle-state.tsv" 2>/dev/null; then
    printf '  PASS: %s\n' "parked row carried across the busy flap"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: parked row dropped from idle-state.tsv on the busy flap — next idle re-entry re-emits (per-minute resurface flood)\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# Cycle 3: pane idles again, worker still parked → NO re-emit.
MOCK_IDLE_SET="$parked_row"
out3=$(list_idle_transitions)
assert_empty "(d) cycle 3 (re-park, unchanged) emits nothing" "$out3"

# Park ends (marker removed → verdict returned): the next idle
# observation reclassifies (class change) and MUST emit — wake on
# genuine change preserved.
rm -f "$STATE_DIR/skeptic/pending/sweeper"
MOCK_IDLE_SET=""
list_idle_transitions >/dev/null      # busy cycle drops the stale carry
MOCK_IDLE_SET=$'sweeper\tno-wrap-up\t900\t'
out4=$(list_idle_transitions)
assert_nonempty "park end + reclassification emits promptly" "$out4"

# ---- 6. (d) parked worker's idle_prompt decision does not re-nag ------------
echo '=== 6. idle_prompt decisions of a parked window are suppressed ==='
if ! command -v jq >/dev/null 2>&1; then
    printf '  FAIL: jq unavailable — cannot exercise render_pending_decisions (refusing to silently pass)\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    mkdir -p "$STATE_DIR/decisions" "$STATE_DIR/skeptic/pending"
    touch "$STATE_DIR/skeptic/pending/sweeper"
    rm -f "$STATE_DIR/pending-decisions-emit-state.tsv"
    cat > "$STATE_DIR/decisions/sweeper.dc87da1b7e4d.json" <<'EOF'
{"window":"sweeper","fingerprint":"dc87da1b7e4d","kind":"idle_prompt","prompt_excerpt":"Claude is waiting for your input"}
EOF
    cat > "$STATE_DIR/decisions/other.aaaaaaaaaaaa.json" <<'EOF'
{"window":"other","fingerprint":"aaaaaaaaaaaa","kind":"idle_prompt","prompt_excerpt":"Claude is waiting for your input"}
EOF
    out=$(render_pending_decisions)
    case "$out" in
        *sweeper*)
            printf '  FAIL: parked window idle_prompt decision surfaced:\n%s\n' "$out" >&2
            FAIL=$(( FAIL + 1 )) ;;
        *)
            printf '  PASS: %s\n' "(d) parked window idle_prompt suppressed"; PASS=$(( PASS + 1 )) ;;
    esac
    case "$out" in
        *other*)
            printf '  PASS: %s\n' "non-parked window idle_prompt still surfaces"; PASS=$(( PASS + 1 )) ;;
        *)
            printf '  FAIL: non-parked idle_prompt was wrongly suppressed:\n%s\n' "$out" >&2
            FAIL=$(( FAIL + 1 )) ;;
    esac
    # A permission_prompt on the PARKED window is a real decision and
    # must surface regardless of the park.
    rm -f "$STATE_DIR/pending-decisions-emit-state.tsv"
    cat > "$STATE_DIR/decisions/sweeper.bbbbbbbbbbbb.json" <<'EOF'
{"window":"sweeper","fingerprint":"bbbbbbbbbbbb","kind":"permission_prompt","prompt_excerpt":"Allow Bash to run rm -rf?"}
EOF
    out=$(render_pending_decisions)
    case "$out" in
        *bbbbbbbbbbbb*)
            printf '  PASS: %s\n' "permission_prompt on parked window still surfaces"; PASS=$(( PASS + 1 )) ;;
        *)
            printf '  FAIL: permission_prompt on parked window suppressed:\n%s\n' "$out" >&2
            FAIL=$(( FAIL + 1 )) ;;
    esac
fi

# ---- summary ---------------------------------------------------------------
echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d/%d)\n' "$PASS" "$(( PASS + FAIL ))"
    exit 0
else
    printf 'TESTS FAILED: %d passed, %d failed\n' "$PASS" "$FAIL" >&2
    exit 1
fi
