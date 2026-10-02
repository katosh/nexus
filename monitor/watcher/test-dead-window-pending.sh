#!/usr/bin/env bash
# Unit tests for the dead-window skeptic-pending sweep (#202).
#
# The defect: a skeptic-pending marker whose tmux window has closed can
# never be reported. Both of the marker's consumers are keyed on a live
# window — `retire-preflight.sh` needs a window to retire, and
# `orphaned-skeptic-pending` is enumerated from `_idle_list_worker_windows`
# (a `tmux list-windows` filter). Five real markers stayed silent for 19 to
# 22 days.
#
# The sweep walks the marker DIRECTORY instead of the window list, and is
# REPORT-ONLY: it must never remove, clear or modify a marker.
#
# Every arm carries its own positive control. A "zero dead rows" assertion
# is worthless beside an arm that cannot produce a non-zero, so each arm
# that asserts an absence runs against a fixture that also asserts a
# presence.
#
# Strategy: shadow `tmux` on PATH so both enumeration formats are
# scriptable, seed markers plus an action-log under a per-test STATE_DIR,
# source `_idle_probe.sh`, and drive the two producers directly.
#
# Run: bash monitor/watcher/test-dead-window-pending.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$_test_dir/_idle_probe.sh"

# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR/skeptic/pending"
export STATE_DIR
# No config/load.sh reachable → helpers fall back to their defaults (hang
# 600 s, orphan grace 600 s). Keep NEXUS_ROOT unset so the config probe is
# skipped, and pin the idle threshold so every seeded window is eligible.
unset NEXUS_ROOT MONITOR_SKEPTIC_AWAIT_HANG_SECONDS \
      MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS 2>/dev/null || true
export MONITOR_IDLE_THRESHOLD_SECONDS=0

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
# Stub tmux. `list-windows` answers BOTH formats the probe asks for:
#   -F '#{window_name}'                               → $MOCK_TMUX_WINDOWS
#   -F '#{window_name}|#{window_activity}|#{window_index}' → $MOCK_TMUX_ROWS
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "list-windows" ]]; then
    if [[ "${3:-}" == *window_activity* ]]; then
        printf '%s\n' "${MOCK_TMUX_ROWS:-}"
    else
        printf '%s\n' "${MOCK_TMUX_WINDOWS:-}"
    fi
fi
exit 0
STUB
chmod +x "$STUB_DIR/tmux"
export PATH="$STUB_DIR:$PATH"

# shellcheck source=_idle_probe.sh
source "$PROBE"

# Pane probe: the real one shells out to monitor/pane-state.sh against a
# real tmux. Every seeded live window reads `idle` so it reaches the
# skeptic branches of the classifier.
_idle_pane_state_line() { printf 'state=idle active=0\n'; }

ACTION_LOG="$STATE_DIR/action-log.jsonl"
NOW=$(date +%s)

iso() { date -d "@$1" -Is 2>/dev/null || date -Is; }
safe_name() { printf '%s' "${1//[^a-zA-Z0-9_-]/_}"; }
mk_marker() {   # <window> <mtime-epoch>
    local p="$STATE_DIR/skeptic/pending/$(safe_name "$1")"
    printf '1' > "$p"
    touch -d "@$2" "$p"
}
log_request() { # <window> <ts-epoch>
    printf '{"ts":"%s","agent":"monitor","event":"skeptic-request","target-window":"%s","depth":"1"}\n' \
        "$(iso "$2")" "$1" >> "$ACTION_LOG"
}
log_spawn() {   # <target-window> <skeptic-window> <ts-epoch>
    printf '{"ts":"%s","agent":"monitor","event":"skeptic-spawn","window":"%s","target-window":"%s","orig-window":"%s","depth":"1"}\n' \
        "$(iso "$3")" "$2" "$1" "$1" >> "$ACTION_LOG"
}

# ---- Fixture ------------------------------------------------------------
# Two markers, one state directory, one sweep:
#   ghost-w  — window CLOSED 22 days ago, skeptic required, never spawned.
#              The defect case. MUST surface.
#   live-w   — window ALIVE with a live skeptic. The positive control.
#              MUST NOT surface.
mk_marker ghost-w "$(( NOW - 1900800 ))"        # 22 days old
log_request ghost-w "$(( NOW - 1900800 ))"
mk_marker live-w "$NOW"                          # fresh, worker is parked
log_request live-w "$(( NOW - 30 ))"
log_spawn   live-w live-w-skeptic "$(( NOW - 20 ))"

LIVE=$'live-w\nlive-w-skeptic\norchestrator'
export MOCK_TMUX_WINDOWS="$LIVE"
export MOCK_TMUX_ROWS="live-w|$(( NOW - 3600 ))|4"

echo "=== 1. the predicate: dead window surfaces, live window does not ==="
rows=$(_idle_dead_window_pending_rows "$NOW" "$LIVE")
assert_contains "dead window ghost-w is surfaced" "$rows" \
    $'ghost-w\tdead-window-skeptic-pending'
assert_not_contains "live window live-w is NOT surfaced (positive control)" \
    "$rows" "live-w"
assert_eq "exactly one row for the two-marker fixture" \
    "$(printf '%s\n' "$rows" | awk 'NF>0' | wc -l)" "1"
assert_eq "the row carries the MARKER age in column 3, not an idle age" \
    "$(printf '%s\n' "$rows" | awk -F'\t' '{print ($3 >= 1900800) ? "yes" : "no"}')" \
    "yes"
assert_contains "the row names the marker path" "$rows" \
    "$STATE_DIR/skeptic/pending/ghost-w"
assert_contains "the row states how long the skeptic has been owed" "$rows" \
    "skeptic required 1900800s ago"

echo "=== 2. the count helper agrees with the row producer ==="
assert_eq "count helper returns 1" \
    "$(_idle_dead_window_pending_count "$NOW" "$LIVE")" "1"
# Control. Only an unrelated window is live, so both markers count. (An
# EMPTY list is "tmux unknown" and counts 0 — see section 12.)
assert_eq "count helper returns 2 when no MARKED window is live (control)" \
    "$(_idle_dead_window_pending_count "$NOW" "orchestrator")" "2"

echo "=== 3. liveness is tested on the SANITIZED name (fails closed) ==="
# The marker filename is the sanitized window name, so a live window whose
# name sanitizes onto an existing marker must suppress the row. Accusing a
# LIVE window of dropping its review is the `#112` direction of wrong.
mk_marker 'odd.win:1' "$(( NOW - 1000000 ))"
assert_eq "marker filename is the sanitized name" \
    "$(ls "$STATE_DIR/skeptic/pending/" | grep -c '^odd_win_1$')" "1"
rows_raw=$(_idle_dead_window_pending_rows "$NOW" $'live-w\nodd.win:1')
assert_not_contains "live 'odd.win:1' suppresses its sanitized marker" \
    "$rows_raw" "odd_win_1"
rows_gone=$(_idle_dead_window_pending_rows "$NOW" $'live-w')
assert_contains "the same marker DOES surface once that window is gone" \
    "$rows_gone" "odd_win_1"
rm -f "$STATE_DIR/skeptic/pending/odd_win_1"

echo "=== 4. list_really_idle_workers emits the row ==="
out=$(list_really_idle_workers)
assert_contains "classifier emits the dead-window row" "$out" \
    $'ghost-w\tdead-window-skeptic-pending'
assert_contains "the live parked worker keeps its own class (control)" "$out" \
    $'live-w\tparked-awaiting-skeptic'
assert_not_contains "the live parked worker is not also called dead" "$out" \
    $'live-w\tdead-window-skeptic-pending'

echo "=== 5. render_idle_section renders the operator line ==="
rm -f "$STATE_DIR/idle-state.tsv"
section=$(render_idle_section)
assert_contains "the human line names the class" "$section" \
    "- ghost-w dead-window-skeptic-pending"
assert_contains "the line says the window is gone" "$section" "window GONE"
assert_contains "the line says the marker is not auto-cleared" "$section" \
    "NOT auto-cleared"
assert_contains "the line points at the skeptic protocol" "$section" \
    "skills/nexus.skeptic"
assert_contains "the live parked row still renders (control)" "$section" \
    "- live-w parked-awaiting-skeptic"

echo "=== 6. the row informs ONCE — generic (window,class) dedupe ==="
second=$(render_idle_section)
assert_not_contains "second cycle does not re-emit the dead-window row" \
    "$second" "dead-window-skeptic-pending"

echo "=== 7. render_full_state_snapshot re-shows it at the heartbeat ==="
snap=$(render_full_state_snapshot)
assert_contains "snapshot lists the dead-window marker" "$snap" \
    "- ghost-w dead-window-skeptic-pending"
assert_contains "snapshot still lists the live worker (control)" "$snap" \
    "- live-w "
# Zero live worker windows is exactly when these markers matter most: they
# are the state that outlives every window. In this fixture BOTH windows
# are gone, so both markers must surface — and `live-w` must lose its park
# row, which is the control proving the fixture really changed.
snap_empty=$(MOCK_TMUX_ROWS="" MOCK_TMUX_WINDOWS="orchestrator" \
             render_full_state_snapshot)
assert_contains "snapshot lists it even with NO live worker window" \
    "$snap_empty" "- ghost-w dead-window-skeptic-pending"
assert_contains "live-w, now also window-less, surfaces as dead too" \
    "$snap_empty" "- live-w dead-window-skeptic-pending"
assert_not_contains "live-w no longer renders as parked (fixture control)" \
    "$snap_empty" "- live-w parked"

echo "=== 8. REPORT-ONLY: no marker is deleted, cleared or modified ==="
# Fingerprint every marker before and after driving both producers plus the
# renderer. Size, mtime and content are all compared — a truncation to zero
# bytes would keep the path alive and still destroy the record.
fingerprint() {
    local m
    for m in "$STATE_DIR"/skeptic/pending/*; do
        [[ -f "$m" ]] || continue
        printf '%s\t%s\t%s\t%s\n' "${m##*/}" \
            "$(stat -c '%s' "$m")" "$(stat -c '%Y' "$m")" "$(cat "$m")"
    done
}
before=$(fingerprint)
export MOCK_TMUX_WINDOWS="$LIVE"
export MOCK_TMUX_ROWS="live-w|$(( NOW - 3600 ))|4"
_idle_dead_window_pending_rows "$NOW" "$LIVE" >/dev/null
_idle_dead_window_pending_count "$NOW" "$LIVE" >/dev/null
list_really_idle_workers >/dev/null
render_idle_section >/dev/null
render_full_state_snapshot >/dev/null
after=$(fingerprint)
assert_eq "every marker survives byte-identical (size, mtime, content)" \
    "$after" "$before"
assert_file_exists "the dead window's marker is still on disk" \
    "$STATE_DIR/skeptic/pending/ghost-w"
assert_eq "the marker still holds its depth byte" \
    "$(cat "$STATE_DIR/skeptic/pending/ghost-w")" "1"
assert_eq "both markers are still present" \
    "$(ls "$STATE_DIR/skeptic/pending/" | wc -l)" "2"

echo "=== 9. degenerate state directories produce nothing, quietly ==="
EMPTY_STATE="$WORK/empty-state"
mkdir -p "$EMPTY_STATE/skeptic/pending"
assert_empty "an empty pending directory yields no rows" \
    "$(STATE_DIR="$EMPTY_STATE" _idle_dead_window_pending_rows "$NOW" "$LIVE")"
NODIR_STATE="$WORK/nodir-state"
mkdir -p "$NODIR_STATE"
assert_empty "a missing pending directory yields no rows" \
    "$(STATE_DIR="$NODIR_STATE" _idle_dead_window_pending_rows "$NOW" "$LIVE")"
STATE_DIR="$NODIR_STATE" _idle_dead_window_pending_rows "$NOW" "$LIVE" >/dev/null
assert_eq "a missing pending directory exits 0" "$?" "0"
assert_eq "count helper on a missing directory returns 0" \
    "$(STATE_DIR="$NODIR_STATE" _idle_dead_window_pending_count "$NOW" "$LIVE")" "0"
assert_empty "an unset STATE_DIR yields no rows" \
    "$(STATE_DIR="" _idle_dead_window_pending_rows "$NOW" "$LIVE")"
# A subdirectory under pending/ is not a marker.
mkdir -p "$STATE_DIR/skeptic/pending/a-subdir"
assert_not_contains "a subdirectory is never reported as a marker" \
    "$(_idle_dead_window_pending_rows "$NOW" "$LIVE")" "a-subdir"
rmdir "$STATE_DIR/skeptic/pending/a-subdir"

echo "=== 10. a marker with no skeptic-request event still surfaces ==="
# Four of the five real orphans logged a request; a marker written by
# `spawn-worker.sh` need not have one. Falling back to the marker mtime
# keeps the row honest instead of dropping it.
mk_marker no-req-w "$(( NOW - 500000 ))"
rows_nr=$(_idle_dead_window_pending_rows "$NOW" "$LIVE")
assert_contains "a marker with no request event is still reported" \
    "$rows_nr" $'no-req-w\tdead-window-skeptic-pending'
assert_contains "its owed-time falls back to the marker mtime" \
    "$rows_nr" "skeptic required 500000s ago"

echo "=== 11. the REAL row is stable under the emit strip (depth-3 finding 1) ==="
# Built from the real renderer, not a hand-typed row: the row carries TWO
# wall-clock tokens (`marker Ns old` and `skeptic required Ns ago`), and a
# hand-typed fixture only sees the tokens its author remembered. `date`
# is shadowed only for `+%s`, so `now` moves while marker mtimes do not.
source "$_test_dir/_emit_dedup.sh"
snap_at() {   # <fake-now> -> stripped full-state snapshot
    FAKE_NOW="$1" bash -c '
        date() { if [[ "$*" == "+%s" ]]; then printf "%s\n" "$FAKE_NOW"; else command date "$@"; fi; }
        source "'"$PROBE"'"
        _idle_pane_state_line() { printf "state=idle active=0\n"; }
        source "'"$_test_dir/_emit_dedup.sh"'"
        render_full_state_snapshot | _emit_volatile_strip'
}
s1=$(snap_at "$NOW")
s2=$(snap_at "$(( NOW + 7 ))")
s3=$(snap_at "$(( NOW + 7200 ))")
assert_contains "fixture control: the real row is in the snapshot" "$s1" \
    "- ghost-w dead-window-skeptic-pending"
assert_eq "7 s later, the stripped snapshot is byte-identical" "$s1" "$s2"
# Two hours on, live-w's own class legitimately changes (a real state
# transition), so compare only the dead-window rows there.
dw() { grep 'dead-window-skeptic-pending' <<<"$1"; }
assert_eq "2 h later, the stripped dead-window rows are byte-identical" \
    "$(dw "$s1")" "$(dw "$s3")"
# The strip removes the two ages and NOTHING else: the marker path, which
# names the window, must survive. An over-broad rule such as
# `s/marker [^;]*;/marker;/g` passes both equalities above and fails here.
assert_contains "the strip keeps the marker path" "$s1" \
    "(marker old; skeptic required ago; marker $STATE_DIR/skeptic/pending/ghost-w; window GONE"
# Control: unstripped, the two renders DO differ, so the equalities above
# are not vacuous.
raw1=$(FAKE_NOW="$NOW" bash -c 'date() { [[ "$*" == "+%s" ]] && { echo "$FAKE_NOW"; return; }; command date "$@"; }; source "'"$PROBE"'"; _idle_pane_state_line() { echo "state=idle active=0"; }; render_full_state_snapshot')
raw2=$(FAKE_NOW="$(( NOW + 7 ))" bash -c 'date() { [[ "$*" == "+%s" ]] && { echo "$FAKE_NOW"; return; }; command date "$@"; }; source "'"$PROBE"'"; _idle_pane_state_line() { echo "state=idle active=0"; }; render_full_state_snapshot')
if [[ "$raw1" != "$raw2" ]]; then assert_eq "control: unstripped renders differ" x x
else assert_eq "control: unstripped renders differ" same differ; fi

echo "=== 12. an EMPTY live list is unknown, not all-dead (depth-3 finding 3) ==="
# `tmux list-windows ... || true` yields "" when tmux cannot answer. Read
# as "no window is live", that would accuse live-w, a parked worker.
assert_empty "an empty live list yields no rows" \
    "$(_idle_dead_window_pending_rows "$NOW" "")"
assert_empty "a whitespace-only live list yields no rows" \
    "$(_idle_dead_window_pending_rows "$NOW" $'\n')"
assert_eq "the count helper agrees: 0" \
    "$(_idle_dead_window_pending_count "$NOW" "")" "0"
assert_not_contains "render with tmux silent does not accuse live-w" \
    "$(MOCK_TMUX_ROWS="" MOCK_TMUX_WINDOWS="" render_full_state_snapshot)" \
    "live-w dead-window-skeptic-pending"
# Control: one unrelated live window is enough to run the sweep.
assert_contains "control: a non-empty list still reports ghost-w" \
    "$(_idle_dead_window_pending_rows "$NOW" "orchestrator")" \
    $'ghost-w\tdead-window-skeptic-pending'

th_summary_and_exit
