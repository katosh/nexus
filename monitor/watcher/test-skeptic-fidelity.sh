#!/usr/bin/env bash
# Unit tests for the skeptic-exemption FIDELITY fix (emit/exemption
# fidelity, Defect B): the parked-awaiting-skeptic exemption must require an
# ACTUAL live skeptic, not merely a fresh skeptic-pending marker (which the
# worker's own await loop keeps fresh forever). A fresh marker with no live
# skeptic past the grace window is ORPHANED — it stops conferring the
# exemption and surfaces as an actionable class.
#
# Strategy: shadow `tmux` on PATH so `_idle_skeptic_live_window` sees a
# scriptable window set; seed a fake action-log.jsonl and skeptic-pending
# markers under a per-test STATE_DIR; source _idle_probe.sh and call the
# predicates directly.
#
# Run: bash monitor/watcher/test-skeptic-fidelity.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$_test_dir/_idle_probe.sh"

PASS=0
FAIL=0
ok()   { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad()  { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
assert_parked()   { if _idle_skeptic_parked   "$1" "$NOW" "$LIVE"; then ok "$2"; else bad "$2 (expected parked/exempt)"; fi; }
assert_unparked() { if _idle_skeptic_parked   "$1" "$NOW" "$LIVE"; then bad "$2 (expected NOT parked)"; else ok "$2"; fi; }
assert_orphan()   { if _idle_skeptic_orphaned "$1" "$NOW" "$LIVE"; then ok "$2"; else bad "$2 (expected orphaned)"; fi; }
assert_notorphan(){ if _idle_skeptic_orphaned "$1" "$NOW" "$LIVE"; then bad "$2 (expected NOT orphaned)"; else ok "$2"; fi; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR/skeptic/pending"
export STATE_DIR
# No config/load.sh reachable → helpers fall back to defaults (hang 600,
# orphan grace 600). Keep NEXUS_ROOT unset so the config probe is skipped.
unset NEXUS_ROOT MONITOR_SKEPTIC_AWAIT_HANG_SECONDS MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS 2>/dev/null || true

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
# Stub tmux: list-windows emits $MOCK_TMUX_WINDOWS (newline-separated names).
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows) printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    *) : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"
export PATH="$STUB_DIR:$PATH"

# shellcheck source=_idle_probe.sh
source "$PROBE"

ACTION_LOG="$STATE_DIR/action-log.jsonl"
NOW=$(date +%s)
LIVE=""   # set per-scenario from MOCK_TMUX_WINDOWS

# Helpers to build fixtures.
iso() { date -d "@$1" -Is 2>/dev/null || date -Is; }        # epoch -> ISO
mk_marker() { : > "$STATE_DIR/skeptic/pending/${1//[^a-zA-Z0-9_-]/_}"; touch -d "@$2" "$STATE_DIR/skeptic/pending/${1//[^a-zA-Z0-9_-]/_}"; }
log_request() { printf '{"ts":"%s","agent":"monitor","event":"skeptic-request","target-window":"%s","depth":"1"}\n' "$(iso "$2")" "$1" >> "$ACTION_LOG"; }
log_spawn()   { printf '{"ts":"%s","agent":"monitor","event":"skeptic-spawn","window":"%s","target-window":"%s","orig-window":"%s","depth":"1"}\n' "$(iso "$3")" "$2" "$1" "$1" >> "$ACTION_LOG"; }

# ---- Scenario 1: fresh marker + LIVE skeptic window → parked (exempt) ----
echo "=== 1. fresh marker + live skeptic → exempt ==="
mk_marker worker-a "$NOW"                        # marker fresh (worker parked)
log_request worker-a "$(( NOW - 30 ))"           # skeptic required 30s ago
log_spawn   worker-a worker-a-skeptic "$(( NOW - 20 ))"  # a real skeptic spawned
LIVE=$'worker-a\nworker-a-skeptic\norchestrator' # skeptic window is ALIVE
export MOCK_TMUX_WINDOWS="$LIVE"
assert_parked    worker-a "live skeptic window present → parked/exempt"
assert_notorphan worker-a "live skeptic → not orphaned"

# ---- Scenario 2: fresh marker, no skeptic, WITHIN grace → exempt --------
echo "=== 2. fresh marker, no skeptic yet, within grace → exempt ==="
mk_marker worker-b "$NOW"
log_request worker-b "$(( NOW - 60 ))"           # required only 60s ago (< 600 grace)
LIVE=$'worker-b\norchestrator'                   # NO skeptic window
export MOCK_TMUX_WINDOWS="$LIVE"
assert_parked    worker-b "no skeptic but within grace → still exempt"
assert_notorphan worker-b "within grace → not yet orphaned"

# ---- Scenario 3: fresh marker, no skeptic, PAST grace → ORPHANED --------
# THE bug: the worker's await keeps the marker fresh forever, but no skeptic
# was ever spawned. Past the grace window the exemption must lapse.
echo "=== 3. fresh marker, no skeptic, past grace → orphaned (NOT exempt) ==="
mk_marker worker-c "$NOW"                         # marker STILL fresh (await re-touches)
log_request worker-c "$(( NOW - 1200 ))"          # required 20 min ago, never spawned
LIVE=$'worker-c\norchestrator'                    # NO skeptic window
export MOCK_TMUX_WINDOWS="$LIVE"
assert_unparked worker-c "fresh marker, no skeptic, past grace → NOT exempt"
assert_orphan   worker-c "fresh marker, no skeptic, past grace → orphaned"

# ---- Scenario 4: skeptic was spawned but its window DIED → not exempt ---
echo "=== 4. skeptic spawned then died, past grace → orphaned ==="
mk_marker worker-d "$NOW"
log_request worker-d "$(( NOW - 1300 ))"
log_spawn   worker-d worker-d-skeptic "$(( NOW - 1200 ))"  # spawned...
LIVE=$'worker-d\norchestrator'                    # ...but skeptic window is GONE
export MOCK_TMUX_WINDOWS="$LIVE"
assert_unparked worker-d "spawn recorded but skeptic window dead → NOT exempt"
assert_orphan   worker-d "dead skeptic past grace → orphaned"

# ---- Scenario 5: STALE marker (await died) → neither parked nor orphaned -
# A marker older than the hang window is the genuine-hang path — it must
# fall through to normal idle classification, NOT the orphan class.
echo "=== 5. stale marker → genuine-hang path (not parked, not orphaned) ==="
mk_marker worker-e "$(( NOW - 900 ))"             # marker mtime 15 min old (> 600 hang)
log_request worker-e "$(( NOW - 2000 ))"
LIVE=$'worker-e\norchestrator'
export MOCK_TMUX_WINDOWS="$LIVE"
assert_unparked  worker-e "stale marker → NOT parked"
assert_notorphan worker-e "stale marker → NOT orphaned (genuine-hang path)"

# ---- Scenario 6: template-named skeptic window covers action-log gap ----
echo "=== 6. no spawn event, but <win>-skeptic window alive → exempt ==="
mk_marker worker-f "$NOW"
log_request worker-f "$(( NOW - 1200 ))"          # past grace...
LIVE=$'worker-f\nworker-f-skeptic\norchestrator'  # ...but template skeptic is ALIVE
export MOCK_TMUX_WINDOWS="$LIVE"
assert_parked    worker-f "template-named live skeptic → exempt despite no spawn log"
assert_notorphan worker-f "template-named live skeptic → not orphaned"

# ---- Scenario 8: STALE marker + LIVE skeptic → parked (your-org/nexus-code#1039)
# THE #1039 case, and the combination no scenario above covered: the worker's
# own await loop has stopped re-touching the marker (its own timeout, not an
# error), so the marker ages past `hang` — while the skeptic is still reviewing
# in a live window. The age gate used to `return 1` here BEFORE the liveness
# question was put, so a protected window was presented as an ordinary idle
# worker, inviting exactly the nudge-or-retire path the exemption prevents.
#
# Note this is scenario 5 with ONE variable changed — the skeptic window's
# liveness — which is what makes the pair a control rather than two anecdotes.
echo "=== 8. stale marker + LIVE skeptic → exempt (#1039) ==="
mk_marker worker-h "$(( NOW - 2401 ))"            # await loop exited ~40 min ago
log_request worker-h "$(( NOW - 3000 ))"
log_spawn   worker-h sk-worker-h "$(( NOW - 2900 ))"
LIVE=$'worker-h\nsk-worker-h\norchestrator'      # skeptic window is ALIVE
export MOCK_TMUX_WINDOWS="$LIVE"
assert_parked    worker-h "stale marker but live skeptic → parked/exempt"
assert_notorphan worker-h "stale marker + live skeptic → not orphaned"

# ...and the LABEL, not merely the gate. The two disagreed in the field and
# only the gate was tested, so assert the basis the row will carry.
if [[ "${_IDLE_SKEPTIC_PARK_BASIS:-}" == "skeptic-live" ]]; then
    ok "stale marker + live skeptic → basis is 'skeptic-live' (label qualifies the exemption)"
else
    bad "stale marker + live skeptic → basis was '${_IDLE_SKEPTIC_PARK_BASIS:-<unset>}', expected 'skeptic-live'"
fi

# MUST-NOT-FIRE control: the ORDINARY park (fresh marker + live skeptic) must
# keep the plain basis, or the qualification becomes noise on every row.
_idle_skeptic_parked worker-a "$NOW" $'worker-a\nworker-a-skeptic\norchestrator' >/dev/null 2>&1
if [[ "${_IDLE_SKEPTIC_PARK_BASIS:-}" == "await" ]]; then
    ok "fresh marker + live skeptic → basis is 'await' (qualification does NOT fire)"
else
    bad "fresh marker + live skeptic → basis was '${_IDLE_SKEPTIC_PARK_BASIS:-<unset>}', expected 'await'"
fi

# And the basis must be CLEARED on a non-park verdict, so a stale value from a
# previous window can never decorate a later row.
_idle_skeptic_parked worker-g "$NOW" $'worker-g\norchestrator' >/dev/null 2>&1
if [[ -z "${_IDLE_SKEPTIC_PARK_BASIS:-}" ]]; then
    ok "non-park verdict clears the basis (no carry-over onto another window)"
else
    bad "non-park verdict left basis='${_IDLE_SKEPTIC_PARK_BASIS}' — would decorate an unrelated row"
fi

# ---- Scenario 9: the RENDERED label, not just the predicate --------------
# `render_idle_section`'s awk is what the orchestrator actually reads. Feed it
# the transition row shape and assert the basis reaches the emitted text.
echo "=== 9. rendered label carries the basis (#1039) ==="
_stale_detail="skeptic reviewing (live skeptic window); worker await marker STALE — exempt on the skeptic, not on an active await loop"
list_idle_transitions() { printf 'worker-h\tparked-awaiting-skeptic\t2401\t%s\n' "$_stale_detail"; }
row=$(render_idle_section)
case "$row" in
    *"parked-awaiting-skeptic"*"await marker STALE"*)
        ok "emitted row names the stale-await basis" ;;
    *) bad "emitted row did not carry the basis: [$row]" ;;
esac
# NOTE the emptiness guard: without it this arm PASSES on an empty row, i.e. it
# would be a check that cannot fail — the defect this whole branch is about.
if [[ -z "$row" ]]; then
    bad "emitted row was EMPTY — the negative assertion below would pass vacuously"
else
    case "$row" in
        *"idle 2254s"*|*"WITHOUT wrap-up"*)
            bad "emitted row still reads as an ordinary idle worker: [$row]" ;;
        *) ok "emitted row is NOT presented as an ordinary idle worker" ;;
    esac
fi
# Must-not-fire: an ordinary park with no detail keeps the plain wording.
list_idle_transitions() { printf 'worker-a\tparked-awaiting-skeptic\t120\t\n'; }
row=$(render_idle_section)
case "$row" in
    *"await marker STALE"*) bad "ordinary park wrongly rendered with the stale-await qualifier: [$row]" ;;
    *"parked-awaiting-skeptic"*) ok "ordinary park renders with the plain wording" ;;
    *) bad "ordinary park did not render at all: [$row]" ;;
esac
unset -f list_idle_transitions

# ---- Scenario 8: CHANNEL evidence (your-org/nexus-code#1153) ------------
#
# `_idle_skeptic_live_window` answers from a SPAWN LINKAGE RECORD, written only
# by `spawn-worker.sh --skeptic-role`. A skeptic spawned with a bare -n/-c/-p
# works end to end and writes none — so the detector called a LIVE reviewer an
# orphan and advised the operator to clear a live obligation.
echo "=== 8. #1153 channel traffic THIS round → not orphaned ==="
mk_marker worker-i "$NOW"
log_request worker-i "$(( NOW - 1200 ))"          # round opened 20 min ago
LIVE=$'worker-i
orchestrator'                    # NO linkage, NO -skeptic window
export MOCK_TMUX_WINDOWS="$LIVE"
# CONTROL FIRST: with no channel at all this fixture IS an orphan. Without this
# the assertion below could pass because the fixture never qualified.
assert_orphan    worker-i "#1153 CONTROL: no channel dir → still orphaned"
mkdir -p "$STATE_DIR/skeptic/worker-i"
: > "$STATE_DIR/skeptic/worker-i/req-001-probe.ack.md"
touch -d "@$(( NOW - 600 ))" "$STATE_DIR/skeptic/worker-i/req-001-probe.ack.md"
assert_notorphan worker-i "#1153 live channel traffic this round → NOT orphaned"

# ---- Scenario 8b: the PARK half of #1153 (residual 1) --------------------
#
# The orphan arm above reads channel traffic; the park EXEMPTION did not, so a
# skeptic spawned without `--skeptic-role` kept its target parked only until
# the orphan grace lapsed — then the target proceeded toward retirement while
# its skeptic was mid-pass. Same fixture shape, past grace, no linkage.
echo "=== 8b. #1153 channel traffic THIS round, PAST grace → still PARKED ==="
mk_marker worker-i2 "$NOW"
log_request worker-i2 "$(( NOW - 1200 ))"         # round opened 20 min ago (> 600 grace)
LIVE=$'worker-i2\norchestrator'
export MOCK_TMUX_WINDOWS="$LIVE"
# CONTROL FIRST: no channel, past grace, no linkage → NOT parked (the pre-fix
# reading; without this the assertion below could pass on the grace arm).
assert_unparked worker-i2 "#1153 CONTROL: past grace, no channel → not parked"
mkdir -p "$STATE_DIR/skeptic/worker-i2"
: > "$STATE_DIR/skeptic/worker-i2/req-001-probe.ack.md"
touch -d "@$(( NOW - 600 ))" "$STATE_DIR/skeptic/worker-i2/req-001-probe.ack.md"
assert_parked worker-i2 "#1153 channel traffic this round, past grace → PARKED (exempt)"
if [[ "${_IDLE_SKEPTIC_PARK_BASIS:-}" == "channel" ]]; then ok "#1153 …and the basis names the evidence: channel"; else bad "#1153 basis is [${_IDLE_SKEPTIC_PARK_BASIS:-}], want channel"; fi
# CONTROL 2: traffic OLDER than this round's request (a prior-round leftover,
# #975's shape) does NOT grant the park — the arm is scoped to the round.
mk_marker worker-i3 "$NOW"
log_request worker-i3 "$(( NOW - 1200 ))"
LIVE=$'worker-i3\norchestrator'
export MOCK_TMUX_WINDOWS="$LIVE"
mkdir -p "$STATE_DIR/skeptic/worker-i3"
: > "$STATE_DIR/skeptic/worker-i3/req-001-old.answered.md"
touch -d "@$(( NOW - 4000 ))" "$STATE_DIR/skeptic/worker-i3/req-001-old.answered.md"
assert_unparked worker-i3 "#1153 CONTROL: prior-round leftover traffic → NOT parked (#975 scope kept)"
# CONTROL 3: a STALE marker (the worker's own await died) still lapses even
# with fresh channel traffic — the genuine-hang path is untouched.
mk_marker worker-i4 "$(( NOW - 100000 ))"
log_request worker-i4 "$(( NOW - 1200 ))"
LIVE=$'worker-i4\norchestrator'
export MOCK_TMUX_WINDOWS="$LIVE"
mkdir -p "$STATE_DIR/skeptic/worker-i4"
: > "$STATE_DIR/skeptic/worker-i4/req-001-probe.ack.md"
touch -d "@$(( NOW - 600 ))" "$STATE_DIR/skeptic/worker-i4/req-001-probe.ack.md"
assert_unparked worker-i4 "#1153 CONTROL: stale marker + fresh channel → NOT parked (hang path kept)"

# ---- Scenario 9: STALE channel leftovers must NOT exempt (#975) ----------
#
# `close` does NOT remove `req-*.md`, so an unscoped "any request file exists"
# predicate — which is what #1153 itself proposes — is satisfied forever after
# round one. This is the non-vacuity control that separates the shipped fix
# from that proposal: a leftover from a PRIOR round must still read orphaned,
# or the re-armed never-spawned park becomes unreachable and retire-preflight
# can never release.
echo "=== 9. #975 stale channel leftovers do NOT exempt ==="
mk_marker worker-j "$NOW"
log_request worker-j "$(( NOW - 1200 ))"          # THIS round opened 20 min ago
LIVE=$'worker-j
orchestrator'
export MOCK_TMUX_WINDOWS="$LIVE"
mkdir -p "$STATE_DIR/skeptic/worker-j"
: > "$STATE_DIR/skeptic/worker-j/req-001-old.open.md"
touch -d "@$(( NOW - 10800 ))" "$STATE_DIR/skeptic/worker-j/req-001-old.open.md"
assert_orphan    worker-j "#975 a PRIOR round's leftover does NOT exempt"

# ---- Scenario 7: no marker at all → not parked, not orphaned ------------
echo "=== 7. no marker → not parked, not orphaned ==="
LIVE=$'worker-g\norchestrator'
export MOCK_TMUX_WINDOWS="$LIVE"
assert_unparked  worker-g "no marker → not parked"
assert_notorphan worker-g "no marker → not orphaned"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; else echo "TESTS FAILED"; exit 1; fi
