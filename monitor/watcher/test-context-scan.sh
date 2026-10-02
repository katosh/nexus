#!/usr/bin/env bash
# Tests for monitor/watcher/_context_scan.sh — the worker context-budget
# scan + its emit section (issue #2).
#
# Coverage:
#   _context_scan_workers
#     - writes one TSV row per measurable worker window, with the
#       over-flag set from context-usage.sh's exit code
#     - OMITS windows whose context can't be resolved (an unmeasurable
#       worker is unknown, never "healthy")
#     - no-op when disabled / threshold 0 / helper missing
#     - atomic replace: a rescan does not leave stale rows behind
#   _context_over_emit_section
#     - empty when no worker is over, populated when one is
#     - rows are BUCKETED (no live per-row token figure — a drifting
#       number would defeat emit-dedup and cost the wakes this feature
#       exists to remove)
#     - ignores a stale TSV
#     - names the wrap-up path and the long-session exception
#
# Run: bash monitor/watcher/test-context-scan.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HELPER="$_repo_root/monitor/watcher/_context_scan.sh"
USAGE_BIN="$_repo_root/monitor/context-usage.sh"
[[ -f "$HELPER" ]]    || { echo "helper not found: $HELPER" >&2; exit 1; }
[[ -x "$USAGE_BIN" ]] || { echo "not executable: $USAGE_BIN" >&2; exit 1; }

. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_CONFIG_DIR="$WORK/ccconfig"
PROJECTS="$CLAUDE_CONFIG_DIR/projects/-fake"
mkdir -p "$PROJECTS"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR 2>/dev/null || true

NEXUS="$WORK/nexus"
STATE="$NEXUS/monitor/.state"
mkdir -p "$STATE/windows" "$NEXUS/monitor"
cp "$USAGE_BIN" "$NEXUS/monitor/context-usage.sh"
chmod +x "$NEXUS/monitor/context-usage.sh"
export NEXUS_STATE_DIR="$STATE"

_assistant_line() {
    jq -nc --argjson i "$1" --argjson cc "$2" --argjson cr "$3" \
        '{type: "assistant", isSidechain: false,
          message: {usage: {input_tokens: $i,
                            cache_creation_input_tokens: $cc,
                            cache_read_input_tokens: $cr,
                            output_tokens: 10}}}'
}

# Three workers: one small, one large, one whose session is unresolvable.
_mk_worker() {   # name, sid, total-tokens
    printf '%s\n' "$(jq -nc --arg w "$1" --arg s "$2" '{window: $w, session_id: $s}')" \
        > "$STATE/windows/$1.json"
    [[ -n "${3:-}" ]] && _assistant_line 0 0 "$3" > "$PROJECTS/$2.jsonl"
}
_mk_worker w-small "11111111-1111-1111-1111-111111111111" 90000
_mk_worker w-big   "22222222-2222-2222-2222-222222222222" 640000
_mk_worker w-ghost "33333333-3333-3333-3333-333333333333" ""   # no transcript

# Stub the window lister the scan depends on.
_idle_list_worker_windows() {
    printf 'w-small\t0\t1\nw-big\t0\t2\nw-ghost\t0\t3\n'
}

# shellcheck disable=SC1090
. "$HELPER"

export MONITOR_CONTEXT_ROTATION_ENABLED=true
export MONITOR_CONTEXT_ROTATION_WORKER_TOKENS=250000
export MONITOR_CONTEXT_SCAN_STALE_SECONDS=1800

TSV="$STATE/worker-context.tsv"

# ---------------------------------------------------------------- 1
_context_scan_workers "$STATE" "$NEXUS"
assert_file_exists "scan writes the TSV" "$TSV"
assert_eq "one row per MEASURABLE worker (ghost omitted)" \
    "$(wc -l < "$TSV" | tr -d ' ')" "2"
assert_contains "small worker recorded, not over"  "$(cat "$TSV")" $'w-small\t90000\t0'
assert_contains "big worker recorded, flagged over" "$(cat "$TSV")" $'w-big\t640000\t1'
assert_not_contains "unresolvable worker omitted entirely" "$(cat "$TSV")" "w-ghost"

# ---------------------------------------------------------------- 2
# Atomic replace: rows from a previous scan must not survive.
_idle_list_worker_windows() { printf 'w-small\t0\t1\n'; }
_context_scan_workers "$STATE" "$NEXUS"
assert_eq "rescan replaces rather than appends" \
    "$(wc -l < "$TSV" | tr -d ' ')" "1"
assert_not_contains "stale row dropped on rescan" "$(cat "$TSV")" "w-big"
_idle_list_worker_windows() { printf 'w-small\t0\t1\nw-big\t0\t2\nw-ghost\t0\t3\n'; }
_context_scan_workers "$STATE" "$NEXUS"

# ---------------------------------------------------------------- 3
# Disabled / zero-threshold / missing-helper are silent no-ops.
cp "$TSV" "$WORK/tsv.keep"
MONITOR_CONTEXT_ROTATION_ENABLED=false _context_scan_workers "$STATE" "$NEXUS"
assert_eq "disabled scan leaves the TSV untouched" \
    "$(cmp -s "$TSV" "$WORK/tsv.keep" && echo same)" "same"
MONITOR_CONTEXT_ROTATION_WORKER_TOKENS=0 _context_scan_workers "$STATE" "$NEXUS"
assert_eq "threshold 0 leaves the TSV untouched" \
    "$(cmp -s "$TSV" "$WORK/tsv.keep" && echo same)" "same"
_context_scan_workers "$STATE" "$WORK/no-such-root"
assert_eq "missing helper leaves the TSV untouched" \
    "$(cmp -s "$TSV" "$WORK/tsv.keep" && echo same)" "same"

# ---------------------------------------------------------------- 4
# The emit section.
body=$(_context_over_emit_section "$STATE")
assert_contains "flags the over-threshold worker"  "$body" "w-big"
assert_not_contains "does not flag the small one"  "$body" "w-small"
assert_contains "names the threshold"              "$body" "250000"
assert_contains "points at wrap-up"                "$body" "wrap-up-check"
assert_contains "forbids a bare kill"              "$body" "bare kill loses the work"
assert_contains "carries the long-session carve-out" "$body" "stateful kernel"

# The live per-row figure must NOT appear: a number that drifts on every
# scan would make each emit body unique, defeat the content-hash dedup
# gate and the full-state canonical check, and generate the very wakes
# this feature exists to remove.
assert_not_contains "row carries no drifting live token figure" "$body" "640000"

# ---------------------------------------------------------------- 5
# Nothing over threshold → nothing rendered.
printf 'w-small\t90000\t0\t%s\n' "$(date +%s)" > "$TSV"
body=$(_context_over_emit_section "$STATE")
assert_empty "no over-threshold worker renders nothing" "$body"

# Disabled renders nothing even with an over row present.
printf 'w-big\t640000\t1\t%s\n' "$(date +%s)" > "$TSV"
body=$(MONITOR_CONTEXT_ROTATION_ENABLED=false _context_over_emit_section "$STATE")
assert_empty "disabled renders nothing" "$body"
body=$(MONITOR_CONTEXT_ROTATION_WORKER_TOKENS=0 _context_over_emit_section "$STATE")
assert_empty "threshold 0 renders nothing" "$body"

# ---------------------------------------------------------------- 6
# Stale TSV is ignored rather than nagged on.
touch -d '2 hours ago' "$TSV"
body=$(_context_over_emit_section "$STATE")
assert_empty "stale TSV renders nothing" "$body"
body=$(MONITOR_CONTEXT_SCAN_STALE_SECONDS=0 _context_over_emit_section "$STATE")
assert_contains "stale check disabled → renders again" "$body" "w-big"

body=$(_context_over_emit_section "$WORK/no-such-state")
assert_empty "missing TSV renders nothing" "$body"

th_summary_and_exit
