#!/usr/bin/env bash
# Tests for the context-budget rotation feature (issue #1):
#   monitor/context-usage.sh          — the measurement
#   monitor/watcher/_context_rotate.sh — the emit-section renderer
#
# Coverage:
#   context-usage.sh
#     - sums input + cache_creation + cache_read of the LAST assistant
#       message (not the max, so /compact is respected)
#     - EXCLUDES isSidechain (subagent) entries
#     - skips entries with no usage (summary lines, user turns)
#     - exit 0 under threshold / 10 at-or-over / 1 unresolved
#     - --format json shape
#     - threshold 0 disables the over-signal
#     - falls back to a full scan when the tail window misses
#     - --window resolves via the orchestrator pin and via a
#       windows/<name>.json provenance record
#   _context_rotate_emit_section
#     - empty below threshold, populated at/over
#     - empty when disabled, when threshold is 0, when the helper is
#       missing, and when the session can't be resolved
#     - body names the live figure and the rotation command
#
# Run: bash monitor/watcher/test-context-rotate.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
USAGE_BIN="$_repo_root/monitor/context-usage.sh"
HELPER="$_repo_root/monitor/watcher/_context_rotate.sh"
[[ -x "$USAGE_BIN" ]] || { echo "not executable: $USAGE_BIN" >&2; exit 1; }
[[ -f "$HELPER" ]]    || { echo "helper not found: $HELPER" >&2; exit 1; }

. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Hermetic: the helper must never reach the operator's real transcripts
# or the real nexus config. A fake CLAUDE_CONFIG_DIR gives us a projects
# root we fully control.
export CLAUDE_CONFIG_DIR="$WORK/ccconfig"
PROJECTS="$CLAUDE_CONFIG_DIR/projects/-fake-project"
mkdir -p "$PROJECTS"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR 2>/dev/null || true

NEXUS_ROOT_FAKE="$WORK/nexus"
mkdir -p "$NEXUS_ROOT_FAKE/monitor/.state/windows"
export NEXUS_STATE_DIR="$NEXUS_ROOT_FAKE/monitor/.state"

# Emit one assistant transcript line with the given usage numbers.
# $1 in, $2 cache_creation, $3 cache_read, $4 sidechain(0|1)
_assistant_line() {
    jq -nc --argjson i "$1" --argjson cc "$2" --argjson cr "$3" --argjson sc "$4" \
        '{type: "assistant",
          isSidechain: ($sc == 1),
          message: {usage: {input_tokens: $i,
                            cache_creation_input_tokens: $cc,
                            cache_read_input_tokens: $cr,
                            output_tokens: 100}}}'
}

# ---------------------------------------------------------------- 1
# Basic sum, last-message semantics, and the exit-code contract.
T1="$PROJECTS/aaaaaaaa-1111-2222-3333-444444444444.jsonl"
{
    _assistant_line 5 1000 900000 0        # an EARLIER, larger message
    printf '{"type":"user","message":{"content":"hi"}}\n'
    _assistant_line 2 2998 97000 0         # the LAST one: 100000 total
} > "$T1"

out=$("$USAGE_BIN" --transcript "$T1" --threshold 250000 --limit 1000000); rc=$?
assert_eq "sums the LAST assistant message, not the max" \
    "$(sed -n 's/.*tokens=\([0-9]*\).*/\1/p' <<<"$out")" "100000"
assert_eq "under threshold → exit 0" "$rc" "0"
assert_contains "renders pct" "$out" "pct=10"
assert_contains "renders over=0" "$out" "over=0"

out=$("$USAGE_BIN" --transcript "$T1" --threshold 100000); rc=$?
assert_eq "at threshold (>=) → exit 10" "$rc" "10"
assert_contains "over=1 at threshold" "$out" "over=1"

out=$("$USAGE_BIN" --transcript "$T1" --threshold 0); rc=$?
assert_eq "threshold 0 disables the over-signal" "$rc" "0"

# ---------------------------------------------------------------- 2
# Sidechain (subagent) entries must not be counted. This is the case
# that silently defeats rotation: a long session spawning helpers would
# otherwise report the helper's small fresh context as its own.
T2="$PROJECTS/bbbbbbbb-1111-2222-3333-444444444444.jsonl"
{
    _assistant_line 2 2998 597000 0        # main chain: 600000
    _assistant_line 1 100 19899 1          # subagent: 20000, LAST line
} > "$T2"
out=$("$USAGE_BIN" --transcript "$T2" --threshold 250000); rc=$?
assert_eq "ignores isSidechain entries" \
    "$(sed -n 's/.*tokens=\([0-9]*\).*/\1/p' <<<"$out")" "600000"
assert_eq "sidechain-masked session still trips the threshold" "$rc" "10"

# ---------------------------------------------------------------- 3
# Non-usage lines must not break the read.
T3="$PROJECTS/cccccccc-1111-2222-3333-444444444444.jsonl"
{
    printf '{"type":"summary","summary":"a compacted summary"}\n'
    printf '{"type":"file-history-snapshot","messageId":"x"}\n'
    _assistant_line 1 0 249999 0
} > "$T3"
out=$("$USAGE_BIN" --transcript "$T3" --threshold 250000); rc=$?
assert_eq "tolerates summary / snapshot lines" \
    "$(sed -n 's/.*tokens=\([0-9]*\).*/\1/p' <<<"$out")" "250000"
assert_eq "250000 >= 250000 trips" "$rc" "10"

# ---------------------------------------------------------------- 4
# Full-scan fallback: the assistant message sits far outside the tail
# window, so the bounded read misses and the full scan must recover it.
T4="$PROJECTS/dddddddd-1111-2222-3333-444444444444.jsonl"
_assistant_line 2 2998 297000 0 > "$T4"
for _ in $(seq 1 50); do
    printf '{"type":"user","message":{"content":"filler"}}\n'
done >> "$T4"
out=$(NEXUS_CONTEXT_SCAN_LINES=10 "$USAGE_BIN" --transcript "$T4" --threshold 250000); rc=$?
assert_eq "falls back to a full scan when the tail window misses" \
    "$(sed -n 's/.*tokens=\([0-9]*\).*/\1/p' <<<"$out")" "300000"
assert_eq "full-scan path preserves the exit contract" "$rc" "10"

# ---------------------------------------------------------------- 5
# Unresolvable inputs return 1 — never 0. A read failure must not be
# mistaken for "under budget".
"$USAGE_BIN" --transcript "$WORK/does-not-exist.jsonl" --quiet; rc=$?
assert_eq "missing transcript → exit 1" "$rc" "1"
"$USAGE_BIN" --session "eeeeeeee-1111-2222-3333-444444444444" --quiet; rc=$?
assert_eq "unknown session → exit 1" "$rc" "1"
out=$("$USAGE_BIN" --session "eeeeeeee-1111-2222-3333-444444444444" 2>/dev/null); rc=$?
assert_contains "unresolved read reports an error token" "$out" "error=no-transcript"

T5="$PROJECTS/ffffffff-1111-2222-3333-444444444444.jsonl"
printf '{"type":"user","message":{"content":"only user turns"}}\n' > "$T5"
"$USAGE_BIN" --transcript "$T5" --quiet; rc=$?
assert_eq "transcript with no usage record → exit 1" "$rc" "1"

# ---------------------------------------------------------------- 6
# --format json.
out=$("$USAGE_BIN" --transcript "$T1" --threshold 250000 --format json)
assert_eq "json ok"     "$(jq -r '.ok'     <<<"$out")" "true"
assert_eq "json tokens" "$(jq -r '.tokens' <<<"$out")" "100000"
assert_eq "json over"   "$(jq -r '.over'   <<<"$out")" "false"

# ---------------------------------------------------------------- 7
# --window resolution: orchestrator pin, then provenance record.
printf 'aaaaaaaa-1111-2222-3333-444444444444\n' > "$NEXUS_STATE_DIR/orchestrator-session-id"
out=$(NEXUS_ROOT="$NEXUS_ROOT_FAKE" MONITOR_TARGET=orchestrator \
      "$USAGE_BIN" --window orchestrator --threshold 250000)
assert_contains "--window orchestrator resolves via the session pin" "$out" "tokens=100000"

jq -nc '{window: "w-worker", session_id: "bbbbbbbb-1111-2222-3333-444444444444"}' \
    > "$NEXUS_STATE_DIR/windows/w-worker.json"
out=$(NEXUS_ROOT="$NEXUS_ROOT_FAKE" MONITOR_TARGET=orchestrator \
      "$USAGE_BIN" --window w-worker --threshold 250000)
assert_contains "--window <worker> resolves via the provenance record" "$out" "tokens=600000"

NEXUS_ROOT="$NEXUS_ROOT_FAKE" "$USAGE_BIN" --window nope --quiet; rc=$?
assert_eq "unknown window → exit 1" "$rc" "1"

# ---------------------------------------------------------------- 8
# _context_rotate_emit_section.
# shellcheck disable=SC1090
. "$HELPER"

# A fake nexus root whose monitor/context-usage.sh is the real script,
# so the section exercises the real measurement path.
mkdir -p "$NEXUS_ROOT_FAKE/monitor"
cp "$USAGE_BIN" "$NEXUS_ROOT_FAKE/monitor/context-usage.sh"
chmod +x "$NEXUS_ROOT_FAKE/monitor/context-usage.sh"

export MONITOR_CONTEXT_ROTATION_ENABLED=true
export MONITOR_CONTEXT_ROTATION_ORCHESTRATOR_TOKENS=250000
export MONITOR_CONTEXT_ROTATION_LIMIT_TOKENS=1000000
export MONITOR_CONTEXT_PROBE_STALE_SECONDS=600

# Measurement and rendering are SEPARATE (skeptic req-002 finding 4):
# the probe is an async scheduler task, the renderer is compose-path
# safe and only reads the probe's state file. Drive both.
_probe_then_render() {
    _context_rotate_probe        "$NEXUS_STATE_DIR" "$NEXUS_ROOT_FAKE" "${1:-orchestrator}"
    _context_rotate_emit_section "$NEXUS_STATE_DIR" "$NEXUS_ROOT_FAKE" "${1:-orchestrator}"
}

# orchestrator pin currently points at the 100000-token session.
rm -f "$NEXUS_STATE_DIR/orchestrator-context"
body=$(_probe_then_render orchestrator)
assert_empty "below threshold renders nothing" "$body"

# Repoint the pin at the 600000-token session.
printf 'bbbbbbbb-1111-2222-3333-444444444444\n' > "$NEXUS_STATE_DIR/orchestrator-session-id"
rm -f "$NEXUS_STATE_DIR/orchestrator-context"
body=$(_probe_then_render orchestrator)
assert_contains "at/over threshold renders a directive" "$body" "600000 tokens"
assert_contains "directive names the threshold"         "$body" "250000"
assert_contains "directive names the percentage"        "$body" "60%"
assert_contains "directive points at report-init"       "$body" "report-init"
assert_contains "directive points at the rotate verb"   "$body" "--rotation"
assert_contains "directive warns off ng respawn"        "$body" "NOT `ng respawn`"
assert_contains "directive forbids a bare kill"         "$body" "bare kill is not a rotation"

# NB: written as a plain command substitution with an inline env
# prefix. `VAR=x \` on its own line ahead of `body=$(...)` would be an
# assignments-ONLY command, which persists for the rest of the script
# rather than scoping to the call — it silently disabled every
# subsequent assertion in this file until caught.
body=$(MONITOR_CONTEXT_ROTATION_ENABLED=false _probe_then_render orchestrator)
assert_empty "disabled renders nothing" "$body"
assert_eq "the disabled probe did not leak into the shell" \
    "${MONITOR_CONTEXT_ROTATION_ENABLED}" "true"

body=$(MONITOR_CONTEXT_ROTATION_ORCHESTRATOR_TOKENS=0 _probe_then_render orchestrator)
assert_empty "threshold 0 renders nothing" "$body"

body=$(MONITOR_CONTEXT_ROTATION_ORCHESTRATOR_TOKENS=notanumber _probe_then_render orchestrator)
assert_empty "non-numeric threshold renders nothing" "$body"

rm -f "$NEXUS_STATE_DIR/orchestrator-context"
body=$(_context_rotate_probe "$NEXUS_STATE_DIR" "$WORK/no-such-root" orchestrator; _context_rotate_emit_section "$NEXUS_STATE_DIR" "$WORK/no-such-root" orchestrator)
assert_empty "missing helper renders nothing" "$body"

# ---------------------------------------------------------------- 9
# REGRESSION (skeptic req-001 finding 3): the rendered body must be
# STABLE as the live figure drifts. This body is hashed by
# `_compose_emit_stable_hash` for the emit-dedup gate and the
# full-state canonical check — an exact token count here would make
# every emit unique while the orchestrator sits over threshold, so the
# gate could never collapse a repeat and a feature meant to CUT wakes
# would manufacture them. It would also disarm issue #3's fix, whose
# all-repeats bodies fall through to that same gate expecting a match.
_ctx_body_for() {   # $1 = total tokens
    local sid="$2"
    _assistant_line 0 0 "$1" 0 > "$PROJECTS/$sid.jsonl"
    printf '%s\n' "$sid" > "$NEXUS_STATE_DIR/orchestrator-session-id"
    _probe_then_render orchestrator
}
SID_D="dddd0000-1111-2222-3333-444444444444"
b1=$(_ctx_body_for 601000 "$SID_D")
b2=$(_ctx_body_for 602300 "$SID_D")
b3=$(_ctx_body_for 604900 "$SID_D")
assert_eq "body stable across small drift (601k vs 602.3k)" "$b1" "$b2"
assert_eq "body stable across small drift (601k vs 604.9k)" "$b1" "$b3"
assert_not_contains "no raw token figure in the body" "$b1" "601000"
assert_contains "renders the bucketed figure instead" "$b1" "~600000"

# A material move DOES change the body — the bucket is a stabiliser,
# not a mute button.
b4=$(_ctx_body_for 660000 "$SID_D")
[[ "$b1" != "$b4" ]] && r=changed || r=same
assert_eq "a material move (600k→660k) still changes the body" "$r" "changed"

# And the percentage must be derived from the bucket, so the two can
# never drift independently.
assert_contains "pct derived from the bucket" "$b1" "~60%"

rm -f "$NEXUS_STATE_DIR/orchestrator-context"
body=$(_probe_then_render no-such-window)
assert_empty "unresolvable session renders nothing (never nags on a guess)" "$body"

# ---------------------------------------------------------------- 10
# REGRESSION (skeptic req-002 finding 4): the RENDERER must do no
# measurement. It runs from `_compose_report_body` on every compose
# cycle — a path with a ~100 ms synchronous budget — while measuring
# the orchestrator transcript (the largest in the workspace) costs
# 0.63 s bounded and 1.69 s on the full-scan fallback.
#
# Proved structurally rather than by timing: make the measurement
# helper unusable, then assert the renderer still works off the probe's
# state file. If the renderer measured, this would render nothing.
printf 'bbbbbbbb-1111-2222-3333-444444444444\n' > "$NEXUS_STATE_DIR/orchestrator-session-id"
rm -f "$NEXUS_STATE_DIR/orchestrator-context"
_context_rotate_probe "$NEXUS_STATE_DIR" "$NEXUS_ROOT_FAKE" orchestrator
assert_file_exists "probe writes its state file" "$NEXUS_STATE_DIR/orchestrator-context"

chmod -x "$NEXUS_ROOT_FAKE/monitor/context-usage.sh"
body=$(_context_rotate_emit_section "$NEXUS_STATE_DIR" "$NEXUS_ROOT_FAKE" orchestrator)
chmod +x "$NEXUS_ROOT_FAKE/monitor/context-usage.sh"
assert_contains "renderer works with the measurement helper unusable" "$body" "tokens"

# ...and the probe, conversely, is the ONLY thing that measures: with
# the helper unusable it must not write or refresh state.
rm -f "$NEXUS_STATE_DIR/orchestrator-context"
chmod -x "$NEXUS_ROOT_FAKE/monitor/context-usage.sh"
_context_rotate_probe "$NEXUS_STATE_DIR" "$NEXUS_ROOT_FAKE" orchestrator
chmod +x "$NEXUS_ROOT_FAKE/monitor/context-usage.sh"
assert_no_file "probe writes nothing when it cannot measure" "$NEXUS_STATE_DIR/orchestrator-context"

# A probe reading that is UNDER threshold must render nothing even
# though the file exists.
printf 'aaaaaaaa-1111-2222-3333-444444444444\n' > "$NEXUS_STATE_DIR/orchestrator-session-id"
_context_rotate_probe "$NEXUS_STATE_DIR" "$NEXUS_ROOT_FAKE" orchestrator
body=$(_context_rotate_emit_section "$NEXUS_STATE_DIR" "$NEXUS_ROOT_FAKE" orchestrator)
assert_empty "under-threshold probe reading renders nothing" "$body"

# STALENESS: a reading from before a rotation that already happened
# must not nag the fresh session into rotating again.
printf '900000\t1\t1000\n' > "$NEXUS_STATE_DIR/orchestrator-context"
body=$(_context_rotate_emit_section "$NEXUS_STATE_DIR" "$NEXUS_ROOT_FAKE" orchestrator)
assert_empty "stale probe reading renders nothing" "$body"
body=$(MONITOR_CONTEXT_PROBE_STALE_SECONDS=0 _context_rotate_emit_section \
       "$NEXUS_STATE_DIR" "$NEXUS_ROOT_FAKE" orchestrator)
assert_contains "staleness check disabled → renders again" "$body" "~900000"

# A malformed probe file must render nothing, never a partial nag.
printf 'garbage\n' > "$NEXUS_STATE_DIR/orchestrator-context"
body=$(_context_rotate_emit_section "$NEXUS_STATE_DIR" "$NEXUS_ROOT_FAKE" orchestrator)
assert_empty "malformed probe file renders nothing" "$body"
rm -f "$NEXUS_STATE_DIR/orchestrator-context"

th_summary_and_exit
