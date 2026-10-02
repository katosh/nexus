#!/usr/bin/env bash
# Regression tests for the `--- workspace snapshot ---` staging freshness
# gate (jacob-greene/nexus#14).
#
# THE BUG: compose_emit renders the `workspace:` counts line INLINE (always
# fresh) but read the snapshot BODY verbatim from the async
# `scheduler-staging/full_state_snap.out` at any age. A window closing
# between the async render and the emit put two contradictory views in one
# message — `0 busy` in the preamble and a `state=busy` window in the
# snapshot body, naming a window that no longer existed.
#
# Strategy — same shape as test-full-state-suppression.sh: shadow `tmux` and
# `pane-state.sh` on PATH so per-window state is scriptable without a real
# tmux server, and use `touch -d` for synthetic staging mtimes. The emit
# composition is the PRODUCTION code: `_full_state_stage_age_seconds`,
# `_run_bounded`, `compose_report`, `_compose_report_body` and
# `_cap_emit_sections` are extracted verbatim from main.sh, and the
# full-state consume block is lifted verbatim out of `_v2_task_compose_emit`
# (only `local ` stripped, since it runs here at top level). Nothing about
# the gate is reimplemented in this file — a test that reimplemented it
# could not prove main.sh carries it.
#
# Run: bash monitor/watcher/test-full-state-staging-freshness.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAIN_SH="$_test_dir/main.sh"
CONFIG_SH="$_test_dir/_config.sh"
DEDUP_SH="$_test_dir/_emit_dedup.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then pass "$label"
    else
        fail "$label"
        printf '         got:  %q\n' "$got" >&2
        printf '         want: %q\n' "$want" >&2
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    # An empty needle matches everything, so it could only pass vacuously.
    if [[ -n "$needle" && "$hay" == *"$needle"* ]]; then pass "$label"
    else
        fail "$label"
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
    fi
}
assert_ne() {
    local label="$1" a="$2" b="$3"
    if [[ "$a" != "$b" ]]; then pass "$label"
    else fail "$label — values unexpectedly equal: $a"; fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if [[ "$hay" != *"$needle"* ]]; then pass "$label"
    else
        fail "$label"
        printf '         should NOT contain: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
    fi
}

_extract_fn() { sed -n "/^$2() {/,/^}/p" "$1"; }

# ---- harness -------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/.state"
STAGE_DIR="$STATE_DIR/scheduler-staging"
STAGE_FILE="$STAGE_DIR/full_state_snap.out"
mkdir -p "$STAGE_DIR" "$WORK/tmp" "$WORK/monitor"
NEXUS_ROOT="$WORK"
export STATE_DIR NEXUS_ROOT

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

# tmux stub: `list-windows` echoes MOCK_TMUX_WINDOWS (name|activity|index,
# which _idle_list_worker_windows parses). A bare `-F '#{window_name}'`
# query gets the NAME column only, as real tmux would: the compose path's
# live-window re-stat (_full_state_restat_live_windows) membership-tests
# names, and a whole row would never match, dropping every snapshot row.
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows)
        if [[ " $* " == *" #{window_name} "* ]]; then
            printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" | cut -d'|' -f1
        else
            printf '%s\n' "${MOCK_TMUX_WINDOWS:-}"
        fi ;;
    *)  : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

# pane-state.sh stub.
#   MOCK_PANE_SLEEP > 0        every probe hangs (render emits nothing).
#   + MOCK_PANE_HANG_MARKER    hang only AFTER the first probe has answered,
#                              so the render deterministically emits one row
#                              and then deterministically blows its budget.
#                              That makes the non-empty PARTIAL case a real
#                              assertion instead of one that self-SKIPs on a
#                              fast host — which is the exact path the empty
#                              PARTIAL defect hid behind.
cat > "$STUB_DIR/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
win="${1:-}"
while [[ "$win" == --* ]]; do shift 2 2>/dev/null || break; win="${1:-}"; done
if [[ -n "${MOCK_PANE_SLEEP:-}" ]] && (( MOCK_PANE_SLEEP > 0 )); then
    if [[ -n "${MOCK_PANE_HANG_MARKER:-}" ]]; then
        if [[ -e "$MOCK_PANE_HANG_MARKER" ]]; then
            sleep "$MOCK_PANE_SLEEP"
        else
            : > "$MOCK_PANE_HANG_MARKER"
        fi
    else
        sleep "$MOCK_PANE_SLEEP"
    fi
fi
key="MOCK_PANE_STATE_${win//[^a-zA-Z0-9_]/_}"
printf 'state=%s\n' "${!key:-busy}"
exit 0
STUB
chmod +x "$STUB_DIR/pane-state.sh"
cp "$STUB_DIR/pane-state.sh" "$WORK/monitor/pane-state.sh"

# Run one full-state compose cycle through the PRODUCTION composition path.
#   $1 windows        MOCK_TMUX_WINDOWS value (tmux ground truth)
#   $2 stage_age      seconds to backdate the staging file (empty ⇒ no file)
#   $3 stage_body     staging file content (empty ⇒ empty staging file)
#   $4 render_budget  _run_bounded budget for the inline re-render
#   $5 pane_sleep     per-pane probe delay (drives the timeout case)
# stdout: the emit body. stderr: the watcher log lines, prefixed `LOG `.
#   $6 hang_after_first  non-empty ⇒ probes answer once, then hang
compose_cycle() {
    local windows="$1" stage_age="${2:-}" stage_body="${3:-}"
    local budget="${4:-20}" pane_sleep="${5:-0}" hang_after_first="${6:-}"

    rm -f "$STAGE_FILE" "$WORK/hang-marker"
    if [[ -n "$stage_age" ]]; then
        printf '%s' "$stage_body" > "$STAGE_FILE"
        touch -d "@$(( $(date +%s) - stage_age ))" "$STAGE_FILE"
    fi
    local marker=''
    [[ -n "$hang_after_first" ]] && marker="$WORK/hang-marker"

    PATH="$STUB_DIR:$PATH" MOCK_TMUX_WINDOWS="$windows" MOCK_PANE_SLEEP="$pane_sleep" \
    MOCK_PANE_HANG_MARKER="$marker" \
    bash <<EOSH
set -uo pipefail
export STATE_DIR='$STATE_DIR' NEXUS_ROOT='$NEXUS_ROOT'
source '$DEDUP_SH'
source '$_test_dir/_idle_probe.sh'

$(_extract_fn "$MAIN_SH" _full_state_stage_age_seconds)
$(_extract_fn "$MAIN_SH" _run_bounded)
$(_extract_fn "$MAIN_SH" _render_budget_seconds)
$(_extract_fn "$MAIN_SH" _bounded_failure_log)
$(_extract_fn "$MAIN_SH" _cap_emit_sections)
$(_extract_fn "$MAIN_SH" compose_report)
$(_extract_fn "$MAIN_SH" _compose_report_body)
_close_inherited_locks() { :; }
_ensure_watcher_tmp_dir() { :; }
log() { printf 'LOG %s\n' "\$*" >&2; }

stage_dir='$STAGE_DIR'
tmp_dir='$WORK/tmp'
now_ts=\$(date +%s)
full_state_lines=""
TARGET=orchestrator
EMIT_SIG_NONCE=test
MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS=$budget
MONITOR_RENDER_SECONDS_PER_WINDOW=0
MONITOR_FULL_STATE_STAGE_MAX_AGE_SECONDS=300

# --- verbatim from _v2_task_compose_emit ----------------------------------
# Only \`local\` → \`declare\` (we run at top level, not inside a function;
# \`declare\` keeps multi-variable declarations working). Nothing else altered.
$(awk '/full_state_snap\.out"/ {on=1} /MONITOR_PRELUDE_DRY_RUN=1 _run_bounded/ {on=0} on' "$MAIN_SH" \
    | sed 's/^\( *\)local /\1declare /')
# --- end verbatim ---------------------------------------------------------

compose_report "poll-full-state" "" "" "" "" "\$full_state_lines" "" "" "" "" "" "" "" "" "" ""
EOSH
}

RESERVED_ONLY='services|0|1
orchestrator|0|2'
ONE_WORKER='services|0|1
orchestrator|0|2
worker-a|0|3'
OTHER_WORKER='services|0|1
orchestrator|0|2
bench-worker|0|4'

STALE_BODY='  - worker-a (active, state=busy)'

# ===========================================================================
echo '=== _full_state_stage_age_seconds (unit) ==='

eval "$(_extract_fn "$MAIN_SH" _full_state_stage_age_seconds)"

assert_eq "missing file → -1" \
    "$(_full_state_stage_age_seconds "$WORK/nope.out")" "-1"

probe="$WORK/age-probe"
: > "$probe"
now=$(date +%s)
touch -d "@$(( now - 320 ))" "$probe"
assert_eq "backdated 320s → 320" \
    "$(_full_state_stage_age_seconds "$probe" "$now")" "320"
touch -d "@$now" "$probe"
assert_eq "just written → 0" \
    "$(_full_state_stage_age_seconds "$probe" "$now")" "0"
# NFS clock skew: a future mtime must clamp to 0 (fresh), never go negative.
# Reporting a negative age would make the gate's `age > max` comparison
# nonsense; reporting it as stale would fire the inline re-render on EVERY
# emit under sustained skew — the nexus-code#236 regression.
touch -d "@$(( now + 120 ))" "$probe"
assert_eq "future mtime (clock skew) → clamped to 0, not negative" \
    "$(_full_state_stage_age_seconds "$probe" "$now")" "0"

# ===========================================================================
echo '=== #14 repro: stale staging must not contradict the counts line ==='

# The exact production scenario from #14: the async render captured a worker
# window; the window closed 1.8s later; the emit fired 320s after that.
out=$(compose_cycle "$RESERVED_ONLY" 320 "$STALE_BODY" 2>"$WORK/err.1")
counts=$(printf '%s\n' "$out" | grep '^workspace:')
assert_contains "counts line reports zero workers (ground truth)" "$counts" "0 busy"
assert_not_contains "stale window is NOT served in the snapshot body" \
    "$out" "worker-a"
# Zero live workers ⇒ render_full_state_snapshot yields nothing ⇒ the section
# is correctly absent. Agreeing with `0 busy` is the whole point.
assert_not_contains "snapshot section absent when there are no workers" \
    "$out" "--- workspace snapshot ---"
# Age is compared loosely: the child re-reads the clock, so a `touch -d`
# 320s in the past can read back as 321s across a second boundary.
assert_contains "re-render is logged with its reason" \
    "$(cat "$WORK/err.1")" "re-rendered inline (staging 32"
assert_contains "re-render reason names the threshold it crossed" \
    "$(cat "$WORK/err.1")" "> 300s max"

# Stale staging + a DIFFERENT live worker: the served body must be the LIVE
# one, not merely "not the stale one".
out=$(compose_cycle "$OTHER_WORKER" 320 "$STALE_BODY" 2>/dev/null)
assert_contains "stale body replaced by the live worker" "$out" "bench-worker"
assert_not_contains "stale worker gone from the replacement" "$out" "worker-a"

# ===========================================================================
echo '=== heartbeat guard: FRESH staging is served as-is, no inline render ==='

# This is the constraint that keeps the async path the fast path. A gate that
# re-rendered on every emit would reintroduce exactly the O(workers) inline
# stall nexus-code#236 fixed.
#
# The discriminator is a SENTINEL in the staged bytes that a live render
# could never produce. Wall-clock timing cannot be used here:
# `_compose_report_body` renders the `workspace:` prelude inline on every
# emit (by design — that is the always-fresh half), so the cycle pays a
# pane-probe pass either way.
SENTINEL='  - worker-a (active, state=busy) [staged-sentinel]'
out=$(compose_cycle "$ONE_WORKER" 10 "$SENTINEL" 2>"$WORK/err.2")
assert_contains "fresh staged body served byte-for-byte" "$out" "[staged-sentinel]"
assert_not_contains "no inline re-render on the fresh path" \
    "$(cat "$WORK/err.2")" "re-rendered inline"

# ...and the same sentinel IS discarded once the body goes stale.
out=$(compose_cycle "$ONE_WORKER" 320 "$SENTINEL" 2>/dev/null)
assert_not_contains "stale staged bytes are discarded, not served" \
    "$out" "[staged-sentinel]"
assert_contains "replaced by a live render of the same window" "$out" "worker-a"

# Boundary. The end-to-end checks carry a few seconds of slack on purpose:
# compose_cycle backdates with `touch -d` and the child then re-reads the
# clock, so an age staged as exactly 300 can read back as 301 across a second
# tick. Exactness is pinned separately, deterministically, below.
out=$(compose_cycle "$ONE_WORKER" 295 "$STALE_BODY" 2>"$WORK/err.3")
assert_not_contains "comfortably under max → fresh (no re-render)" \
    "$(cat "$WORK/err.3")" "re-rendered inline"
out=$(compose_cycle "$ONE_WORKER" 310 "$STALE_BODY" 2>"$WORK/err.4")
assert_contains "comfortably over max → stale (re-renders)" \
    "$(cat "$WORK/err.4")" "re-rendered inline"

# Exact boundary, no clock race: pin `now` and assert (a) the age function is
# exact at the threshold and (b) the gate compares with strict `>`, i.e. an
# age of exactly max is fresh. Together these fix the boundary without a
# timing-dependent assertion.
now=$(date +%s)
touch -d "@$(( now - 300 ))" "$probe"
assert_eq "age at exactly the threshold is 300 (pinned clock)" \
    "$(_full_state_stage_age_seconds "$probe" "$now")" "300"
if grep -qE '\(\( *_fs_age > MONITOR_FULL_STATE_STAGE_MAX_AGE_SECONDS *\)\)' "$MAIN_SH"; then
    pass "gate uses strict > (age == max is fresh, not stale)"
else
    fail "gate must compare _fs_age with strict > against MONITOR_FULL_STATE_STAGE_MAX_AGE_SECONDS"
fi

# Empty staging still re-renders (the pre-#14 behaviour must survive).
out=$(compose_cycle "$ONE_WORKER" 0 "" 2>"$WORK/err.5")
assert_contains "empty staging still re-renders" \
    "$(cat "$WORK/err.5")" "re-rendered inline (staging empty)"
# Absent staging file: mtime unreadable ⇒ fail toward freshness.
out=$(compose_cycle "$ONE_WORKER" "" "" 2>"$WORK/err.6")
assert_contains "absent staging file re-renders" \
    "$(cat "$WORK/err.6")" "re-rendered inline"

# ===========================================================================
echo '=== row-count consistency (threshold-INDEPENDENT) ==='

# The age gate alone is not enough, and this is the evidence for why: with the
# producer at emit_interval/4, essentially all real staleness lands in
# [0, 150] — below the 300s threshold. Replaying the ORIGINAL #14 scenario at
# ages the gate does not catch reproduced the contradiction verbatim on the
# age-gate-only revision. The row count fixes that at any age.
for age in 100 290; do
    out=$(compose_cycle "$RESERVED_ONLY" "$age" "$STALE_BODY" 2>"$WORK/err.rc.$age")
    assert_not_contains "#14 at ${age}s (under the gate): killed window not served" \
        "$out" "worker-a"
    assert_contains "#14 at ${age}s: caught by the row count, not the age gate" \
        "$(cat "$WORK/err.rc.$age")" "snapshot lists 1 window(s), 0 live"
done

# --- second production capture (issue #14 comment 5160492993) --------------
# The stale-ABSENCE direction, which is the one that fails silently. Captured
# live at 14:46:38: staged body 531s old listing one window; ground truth had
# TWO workers — `nexus-fullstate-14-skeptic` spawned after the render (omitted
# entirely) and `nexus-fullstate-14` had wrapped up, its pane reading `empty`
# while the staged row still claimed `state=busy`. Three defects in one
# fixture: omission, wrong state, and the counts/rows mismatch.
CAPTURE2_WINDOWS='services|0|1
orchestrator|0|2
nexus-fullstate-14|0|3
nexus-fullstate-14-skeptic|0|4'
CAPTURE2_STAGED='  - nexus-fullstate-14 (active, state=busy)'
export MOCK_PANE_STATE_3=empty MOCK_PANE_STATE_4=busy

# At 531s (the age it actually had) the age gate catches it...
out=$(compose_cycle "$CAPTURE2_WINDOWS" 531 "$CAPTURE2_STAGED" 2>/dev/null)
assert_contains "capture2 @531s: omitted skeptic window now present" \
    "$out" "nexus-fullstate-14-skeptic"
assert_contains "capture2 @531s: wrapped worker's state corrected to empty" \
    "$out" "state=empty"
assert_not_contains "capture2 @531s: stale state=busy claim gone" \
    "$out" "nexus-fullstate-14 (active, state=busy)"

# ...and at 120s — the regime the 150s producer actually creates, and the one
# the age gate does NOT catch — the row count still catches it. This is the
# case that reproduced silently on the age-gate-only revision.
out=$(compose_cycle "$CAPTURE2_WINDOWS" 120 "$CAPTURE2_STAGED" 2>"$WORK/err.c2")
assert_contains "capture2 @120s (under the gate): skeptic window present" \
    "$out" "nexus-fullstate-14-skeptic"
assert_contains "capture2 @120s: state corrected" "$out" "state=empty"
assert_contains "capture2 @120s: row count is what fired, not the age gate" \
    "$(cat "$WORK/err.c2")" "snapshot lists 1 window(s), 2 live"
assert_not_contains "capture2 @120s: age gate did not fire" \
    "$(cat "$WORK/err.c2")" "old > 300s max"

# Both rows present ⇒ counts line and body agree.
rows=$(printf '%s\n' "$out" | grep -c '^  - ')
assert_eq "capture2 @120s: body row count matches the 2 live workers" "$rows" "2"

unset MOCK_PANE_STATE_3 MOCK_PANE_STATE_4

# Fail-safe: rows == 0 with live workers must NOT trip the row-count branch
# (a future row-suppressing class would otherwise re-render every emit — the
# nexus-code#236 regression). That case is already covered by staging-empty.
out=$(compose_cycle "$ONE_WORKER" 10 "" 2>"$WORK/err.rc0")
assert_contains "empty body routes through staging-empty, not the row count" \
    "$(cat "$WORK/err.rc0")" "staging empty"
assert_not_contains "empty body does not trip the row-count branch" \
    "$(cat "$WORK/err.rc0")" "snapshot lists"

# Matching counts are left alone even for row classes the harness rarely sees
# (the skeptic found this shape in the live staging file).
PARKED_BODY='  - worker-a parked-awaiting-skeptic (state=empty; skeptic reviewing — exempt from idle/close)'
out=$(compose_cycle "$ONE_WORKER" 10 "$PARKED_BODY" 2>"$WORK/err.parked")
assert_contains "parked-awaiting-skeptic row counts as a row (1==1, served)" \
    "$out" "parked-awaiting-skeptic"
assert_not_contains "...and does not trigger a re-render" \
    "$(cat "$WORK/err.parked")" "re-rendered inline"

# ===========================================================================
echo '=== dead-window skeptic-pending rows count as rows (#202) ==='

# `dead-window-skeptic-pending` is the one snapshot row class whose window is
# NOT in the enumerator — the window is gone, the marker is not. So the
# invariant this gate checks is `rows == live + dead-window markers`. Read as
# `rows == live` it would see every emit as stale and re-render inline on each
# one (the nexus-code#236 cost the fail-safe above exists to avoid).
mkdir -p "$STATE_DIR/skeptic/pending"
printf '1' > "$STATE_DIR/skeptic/pending/ghost-w"
touch -d "@$(( $(date +%s) - 1900800 ))" "$STATE_DIR/skeptic/pending/ghost-w"
DEAD_ROW='  - ghost-w dead-window-skeptic-pending (marker 1900800s old; skeptic required 1900800s ago; window GONE)'
WORKER_ROW='  - worker-a (active, state=busy)'

# 2 rows, 1 live window + 1 dead-window marker ⇒ consistent ⇒ served as-is.
out=$(compose_cycle "$ONE_WORKER" 10 "$DEAD_ROW"$'\n'"$WORKER_ROW" 2>"$WORK/err.dw1")
assert_contains "the dead-window row is served from staging" "$out" \
    "ghost-w dead-window-skeptic-pending"
assert_not_contains "rows == live + dead ⇒ no row-count mismatch" \
    "$(cat "$WORK/err.dw1")" "snapshot lists"
assert_not_contains "rows == live + dead ⇒ no inline re-render" \
    "$(cat "$WORK/err.dw1")" "re-rendered inline"

# Control: drop the dead-window row from the SAME fixture. Now 1 row against
# 1 live + 1 dead ⇒ the gate must fire, and must name the dead addend.
out=$(compose_cycle "$ONE_WORKER" 10 "$WORKER_ROW" 2>"$WORK/err.dw2")
assert_contains "a MISSING dead-window row is caught by the row count" \
    "$(cat "$WORK/err.dw2")" "snapshot lists 1 window(s), 1 live + 1 dead-window marker(s)"
assert_contains "the re-render recovers the omitted dead-window row" \
    "$out" "ghost-w dead-window-skeptic-pending"

# Control in the other direction: with the marker gone, the same 2-row body is
# one row too many again — the original #14 capture direction.
rm -f "$STATE_DIR/skeptic/pending/ghost-w"
out=$(compose_cycle "$ONE_WORKER" 10 "$DEAD_ROW"$'\n'"$WORKER_ROW" 2>"$WORK/err.dw3")
assert_contains "with no marker on disk, 2 rows vs 1 live still mismatches" \
    "$(cat "$WORK/err.dw3")" "snapshot lists 2 window(s), 1 live"
assert_not_contains "…and the reason carries no dead addend" \
    "$(cat "$WORK/err.dw3")" "dead-window marker(s)"
assert_not_contains "…and the re-rendered body drops the stale dead-window row" \
    "$out" "ghost-w"

# ===========================================================================
echo '=== the cancelling case: a marker-holding window that CLOSED (#202) ==='

# Found by the depth-1 skeptic on #202 (req-001). A total-only invariant
# (`rows == live + dead`) MASKS this case, which is the exact population #202
# is about: a worker window closes while holding a pending marker, so `live`
# falls by one and `dead` rises by one in the same cycle. The total is
# unchanged, and a staged body still carrying that window's OLD
# `(active, state=…)` row reads as consistent. The emit then asserts a window
# is active after it is gone AND hides the dead-window row that replaced it.
# At the parent commit `rows > live` always caught this, so a total-only form
# is a REGRESSION of the #14 guarantee, not merely a gap. The name-aware test
# (`dead rows in body == dead markers on disk`) is what closes it.
mkdir -p "$STATE_DIR/skeptic/pending"
printf '1' > "$STATE_DIR/skeptic/pending/worker-a"

out=$(compose_cycle "$RESERVED_ONLY" 10 "$STALE_BODY" 2>"$WORK/err.mask")
assert_contains "the cancelling case is CAUGHT, not masked" \
    "$(cat "$WORK/err.mask")" "snapshot lists 1 window(s), 0 live + 1 dead-window marker(s), body carries 0"
assert_not_contains "the closed window is no longer served as active" \
    "$out" "worker-a (active, state=busy)"
assert_contains "the dead-window row that replaced it IS served" \
    "$out" "worker-a dead-window-skeptic-pending"

# Control, the other direction: a staged dead-window row whose marker has since
# been resolved must also re-render, or the emit keeps claiming an unvalidated
# result that is now validated.
rm -f "$STATE_DIR/skeptic/pending/worker-a"
DEAD_ONLY='  - worker-a dead-window-skeptic-pending (marker 900s old; window GONE)'
out=$(compose_cycle "$RESERVED_ONLY" 10 "$DEAD_ONLY" 2>"$WORK/err.mask2")
assert_contains "a resolved marker with a stale dead row re-renders" \
    "$(cat "$WORK/err.mask2")" "body carries 1"
assert_not_contains "the stale dead-window row is dropped" \
    "$out" "worker-a"

# Control, the silent case: body and disk agree on BOTH counts ⇒ no re-render.
# Without this arm the two assertions above could pass on a gate that fires
# unconditionally.
printf '1' > "$STATE_DIR/skeptic/pending/ghost-w"
AGREE_BODY='  - ghost-w dead-window-skeptic-pending (marker 900s old; window GONE)
  - worker-a (active, state=busy)'
out=$(compose_cycle "$ONE_WORKER" 10 "$AGREE_BODY" 2>"$WORK/err.mask3")
assert_not_contains "1 live + 1 dead, body carries both ⇒ gate silent" \
    "$(cat "$WORK/err.mask3")" "snapshot lists"
assert_contains "…and the agreeing body is served unchanged" \
    "$out" "ghost-w dead-window-skeptic-pending"
rm -f "$STATE_DIR/skeptic/pending/ghost-w"

# ===========================================================================
echo '=== provenance footer ==='

# Age slack again (staged 120s can read back as 121s); the shape is what is
# asserted exactly, the digits loosely.
out=$(compose_cycle "$ONE_WORKER" 120 "$STALE_BODY" 2>/dev/null)
footer=$(printf '%s\n' "$out" | grep '^(full snapshot')
if [[ "$footer" =~ ^\(full\ snapshot,\ rendered\ 12[0-9]s\ ago\;\ transitions\ only\ between\ snapshots\)$ ]]; then
    pass "staged body carries its render age"
else
    fail "staged body footer wrong: got '$footer'"
fi

out=$(compose_cycle "$OTHER_WORKER" 320 "$STALE_BODY" 2>/dev/null)
assert_contains "freshly re-rendered body reports 0s" \
    "$out" "(full snapshot, rendered 0s ago; transitions only between snapshots)"

# Bounded re-render times out before emitting a single row. Taking its empty
# output would DELETE the section — and an absent section legitimately means
# "no workers", so that would swap one silent falsehood for another. The
# staged body is kept, labelled STALE with its true age. "Fail toward
# freshness, not toward silence."
out=$(compose_cycle "$ONE_WORKER" 320 "$STALE_BODY" 1 30 2>"$WORK/err.7")
assert_contains "timed-out empty re-render keeps the section" \
    "$out" "--- workspace snapshot ---"
assert_contains "...serving the staged body" "$out" "worker-a"
assert_contains "...labelled STALE" "$out" "STALE"
assert_contains "...with its true age, not 0s" "$out" "rendered 32"
assert_contains "...and a verify-with-tmux instruction" "$out" "verify with tmux before acting"
assert_contains "timeout logs the empty-render fallback" \
    "$(cat "$WORK/err.7")" "produced nothing; serving the"

# A timed-out render that DID emit rows is served as a labelled PARTIAL.
# DETERMINISTIC: the stub answers the first probe and hangs on every later
# one, so the render always emits exactly one row and always blows its budget.
# (An earlier revision used a plain sleep and self-SKIPped on a fast host —
# and that skip is precisely where the empty-PARTIAL defect below hid.)
TWO_WORKERS="$ONE_WORKER
bench-worker|0|5"
out=$(compose_cycle "$TWO_WORKERS" 320 "$STALE_BODY" 2 30 hang-after-first 2>"$WORK/err.8")
assert_contains "partial (non-empty) timed-out render is labelled PARTIAL" \
    "$out" "PARTIAL"
assert_contains "PARTIAL names the budget it blew" "$out" "2s budget"
assert_not_contains "a PARTIAL is not also labelled STALE" "$out" "STALE"
rows=$(printf '%s\n' "$out" | grep -c '^  - ')
assert_eq "the partial carries the one row it managed to render" "$rows" "1"

# THE EMPTY-STAGING + TIMEOUT HOLE (skeptic finding on PR #15).
#
# Nothing staged AND the bounded re-render killed before emitting a row.
# Previously this set FULL_STATE_RENDER_PARTIAL=1, logged it, assigned an
# empty body — and `_compose_report_body` then suppressed the entire section
# INCLUDING the footer that carried the label. The operator saw a non-zero
# counts line beside an absent section, which this change defines as "no
# workers": the PR's own `absent must keep meaning absent` invariant, broken
# in the same harm class as #14 itself. There is no body to label here, so
# the label has to BE the body.
out=$(compose_cycle "$ONE_WORKER" 0 "" 1 30 2>"$WORK/err.9")
assert_contains "empty staging + timeout still emits the section" \
    "$out" "--- workspace snapshot ---"
assert_contains "...with an explicit UNKNOWN row" "$out" "workspace contents UNKNOWN, not empty"
assert_contains "...labelled PARTIAL" "$out" "PARTIAL"
assert_contains "...and the log says why" \
    "$(cat "$WORK/err.9")" "nothing staged to fall back to"
counts=$(printf '%s\n' "$out" | grep '^workspace:')
# The counts line renders under the SAME budget, so with every probe hung it
# may itself time out. Upstream then labels it `UNAVAILABLE (TIMED OUT)`
# (your-org/nexus-code#1406) rather than printing counts. Either reading is
# honest; what must never appear is a counts line claiming ZERO workers.
if [[ "$counts" == *"1 busy"* || "$counts" == *"UNAVAILABLE"* ]]; then
    pass "counts line reports the live worker, or says it is UNAVAILABLE"
else
    fail "counts line neither reports the live worker nor says UNAVAILABLE: $counts"
fi

# The UNKNOWN row must not be mistaken for a window row by the row counter.
rows=$(printf '%s\n' "$out" | grep -c '^  - ')
assert_eq "UNKNOWN row is not counted as a window row" "$rows" "0"

# A genuinely empty workspace still yields an ABSENT section — that is what
# makes `absent` a usable signal, and it is why the case above could not just
# be left to vanish.
out=$(compose_cycle "$RESERVED_ONLY" 0 "" 2>"$WORK/err.10")
assert_not_contains "clean render of an empty workspace: section absent" \
    "$out" "--- workspace snapshot ---"
assert_not_contains "...and no UNKNOWN row" "$out" "UNKNOWN"

# ===========================================================================
echo '=== section-cap allowlist invariant ==='

# The provenance annotation MUST stay in the footer. `_cap_emit_sections`
# matches `--- workspace snapshot ---` as an exact string in its exempt
# allowlist; annotating the HEADER (as #14 suggested) would silently drop the
# section off that allowlist and make it truncatable at 50 lines.
grep -q "exempt\[\"--- workspace snapshot ---\"\]" "$MAIN_SH" \
    && pass "allowlist still keys on the bare header string" \
    || fail "exempt allowlist no longer contains '--- workspace snapshot ---'"

eval "$(_extract_fn "$MAIN_SH" _cap_emit_sections)"
big=$( { printf -- '--- workspace snapshot ---\n'
         for i in $(seq 1 80); do printf '  - w%02d (active, state=busy)\n' "$i"; done
         printf '(full snapshot, rendered 12s ago; transitions only between snapshots)\n'
       } | MONITOR_EMIT_SECTION_MAX_LINES=50 _cap_emit_sections )
assert_not_contains "annotated snapshot section is still never truncated" \
    "$big" "more lines omitted"
assert_eq "all 80 rows survive the cap" \
    "$(printf '%s\n' "$big" | grep -c '^  - w')" "80"

# ===========================================================================
echo '=== volatile strip normalises the age token ==='

# The footer now varies emit-to-emit. `_emit_volatile_strip` feeds the
# emit-dedup hash and the full-state canonical comparison, so an un-normalised
# age would make two byte-identical workspaces hash differently.
source "$DEDUP_SH"
a=$(printf '(full snapshot, rendered 12s ago; transitions only between snapshots)\n' | _emit_volatile_strip)
b=$(printf '(full snapshot, rendered 287s ago; transitions only between snapshots)\n' | _emit_volatile_strip)
assert_eq "differing ages normalise identically" "$a" "$b"
assert_eq "normalised form is the legacy footer" \
    "$a" "(full snapshot; transitions only between snapshots)"
# PARTIAL / STALE are genuinely different content and must NOT normalise away
# — a degraded render must never dedup against a clean one.
#
# (The earlier form of this check, `assert_not_contains "$c" "$a"`, was
# near-vacuous: it passes on the unpatched commit too, because the annotated
# footer trivially does not contain the legacy footer as a substring. These
# assert the two properties that actually matter.)
clean=$(printf '(full snapshot, rendered 0s ago; transitions only between snapshots)\n' | _emit_volatile_strip)
c=$(printf '(full snapshot, rendered 0s ago, PARTIAL (render hit its 20s budget; windows may be missing); transitions only between snapshots)\n' | _emit_volatile_strip)
s=$(printf '(full snapshot, rendered 400s ago, STALE (re-render hit its 20s budget and yielded nothing; windows listed here may have closed — verify with tmux before acting); transitions only between snapshots)\n' | _emit_volatile_strip)
assert_contains "PARTIAL text survives normalisation intact" \
    "$c" "PARTIAL (render hit its 20s budget; windows may be missing)"
assert_contains "STALE text survives normalisation intact" \
    "$s" "STALE (re-render hit its 20s budget and yielded nothing"
assert_ne "a PARTIAL footer does not normalise onto a clean one" "$c" "$clean"
assert_ne "a STALE footer does not normalise onto a clean one" "$s" "$clean"
assert_ne "PARTIAL and STALE stay distinct from each other" "$c" "$s"

# ===========================================================================
echo '=== config derivation ==='

# Derived defaults must satisfy stage_max_age >= 2 * snap_interval, so the
# gate fires only after the async producer has missed two beats — that
# margin is what keeps the inline re-render the exception, not the rule.
# `_cfg` stub: the real one reads config.yaml; here every lookup misses, so
# it echoes the caller-supplied default (its 2nd arg) — which is what forces
# the derived-default branch we want to test.
cat > "$WORK/cfgstub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${2:-}"
STUB
chmod +x "$WORK/cfgstub"

read -r snap_i stage_a < <(
    env -u MONITOR_FULL_STATE_SNAP_INTERVAL_SECONDS \
        -u MONITOR_FULL_STATE_STAGE_MAX_AGE_SECONDS \
        bash -c "
            _cfg='$WORK/cfgstub'
            MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS=600
            $(awk '/^MONITOR_FULL_STATE_SNAP_INTERVAL_SECONDS=/ {on=1}
                   on {print}
                   on && /^fi$/ {n++; if (n==2) exit}' "$CONFIG_SH")
            printf '%s %s\n' \"\$MONITOR_FULL_STATE_SNAP_INTERVAL_SECONDS\" \"\$MONITOR_FULL_STATE_STAGE_MAX_AGE_SECONDS\"
        ")
assert_eq "snap interval defaults to emit_interval/4" "$snap_i" "150"
assert_eq "stage max age defaults to emit_interval/2" "$stage_a" "300"
if (( stage_a >= 2 * snap_i )); then
    pass "stage_max_age >= 2 x snap_interval (gate stays cold in normal operation)"
else
    fail "stage_max_age ($stage_a) < 2 x snap_interval ($snap_i) — inline render would be the rule"
fi

# The producer cadence must be wired to the knob, not hard-coded back to 600.
grep -q '_schedule_task full_state_snap *"\$MONITOR_FULL_STATE_SNAP_INTERVAL_SECONDS"' "$MAIN_SH" \
    && pass "full_state_snap cadence reads the config knob" \
    || fail "full_state_snap cadence is not wired to MONITOR_FULL_STATE_SNAP_INTERVAL_SECONDS"

# ===========================================================================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo 'ALL TESTS PASSED'
    exit 0
fi
exit 1
