#!/usr/bin/env bash
# Hermetic unit tests for the per-section emit guard (_cap_emit_sections).
#
# Operator design ask: "prevent emitting too-long messages WITHOUT risking
# dropping important signals." The guard caps each emit section at
# MONITOR_EMIT_SECTION_MAX_LINES content lines (default 50) with a single
# `[+N more lines omitted]` marker, EXCEPT for an explicit allowlist of
# SIGNAL sections that must NEVER be truncated.
#
# Covers:
#   1. A non-exempt bulk section (`--- local state changes ---`) over the
#      cap IS truncated, with an accurate `[+N more lines omitted]` count.
#   2. EVERY signal section on the allowlist is exempt — even when far over
#      the cap, ALL its lines survive and NO omitted-marker is attributed.
#   3. The preamble (banner + CLAUDE.md hint + `workspace:` line) is kept.
#   4. The `--- nexus-emit-sig … ---` trailer survives as the LAST line even
#      when a preceding section is truncated (paste_to_target reads tail -1).
#   5. Deterministic: same input → byte-identical output (no flap).
#   6. A section exactly AT the cap is not marked; one line over IS.
#
# Run: bash monitor/watcher/test-emit-section-cap.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAIN_SH="$_test_dir/main.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq()           { [[ "$2" == "$3" ]] && pass "$1" || fail "$1: got '${2:0:200}' want '${3:0:200}'"; }
assert_contains()     { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1: missing '$3'"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && pass "$1" || fail "$1: should NOT contain '$3'"; }

_extract_fn() { sed -n "/^$2() {/,/^}/p" "$1"; }

eval "$(_extract_fn "$MAIN_SH" _cap_emit_sections)"

# ---------------------------------------------------------------------------
echo '=== per-section emit guard: cap + signal exemption ==='

# Build a synthetic emit body: a 20-line BULK section, a 20-line SIGNAL
# section, a 12-line SIGNAL section, all over a small cap, plus the trailer.
build_body() {
    printf '=== nexus state changed at 2026-06-22T00:00:00-07:00 (test) ===\n'
    printf '*If unsure how to proceed: see CLAUDE.md.*\n'
    printf 'workspace: 3 windows, 1 idle\n'
    printf -- '--- local state changes ---\n'
    for i in $(seq 1 20); do printf 'diff-%02d\n' "$i"; done
    printf -- '--- eligible github comments ---\n'
    for i in $(seq 1 20); do printf 'gh-%02d\n' "$i"; done
    printf -- '--- service health ---\n'
    for i in $(seq 1 12); do printf 'svc-%02d\n' "$i"; done
    printf -- '--- nexus-emit-sig 2026-06-22T00:00:00-07:00 abc123 ---\n'
}

body=$(build_body)
out=$(MONITOR_EMIT_SECTION_MAX_LINES=5 _cap_emit_sections <<<"$body")

# 1. Bulk section truncated at the cap, with an accurate omitted count.
assert_contains     "bulk: kept line at cap"          "$out" "diff-05"
assert_not_contains "bulk: dropped line past cap"     "$out" "diff-06"
assert_not_contains "bulk: dropped last line"         "$out" "diff-20"
assert_contains     "bulk: omitted-marker present"    "$out" "[+15 more lines omitted]"

# 2. Signal sections exempt — ALL lines survive, NO omitted-marker.
for i in $(seq 1 20); do
    assert_contains "exempt github: line gh-$(printf '%02d' "$i") kept" "$out" "gh-$(printf '%02d' "$i")"
done
for i in $(seq 1 12); do
    assert_contains "exempt service-health: line svc-$(printf '%02d' "$i") kept" "$out" "svc-$(printf '%02d' "$i")"
done
# Exactly one omitted-marker in the whole output (the bulk section only).
nmarkers=$(printf '%s\n' "$out" | grep -c 'more lines omitted')
assert_eq "exactly one omitted-marker (bulk only, no signal truncation)" "$nmarkers" "1"

# 3. Preamble preserved.
assert_contains "preamble: banner kept"        "$out" "=== nexus state changed"
assert_contains "preamble: CLAUDE.md hint kept" "$out" "see CLAUDE.md"
assert_contains "preamble: workspace line kept" "$out" "workspace: 3 windows"

# 4. emit-sig trailer survives as the LAST line.
last=$(printf '%s\n' "$out" | tail -1)
assert_contains "trailer is last line" "$last" "nexus-emit-sig 2026-06-22T00:00:00-07:00 abc123"

# 5. Determinism — same input → byte-identical output.
out2=$(MONITOR_EMIT_SECTION_MAX_LINES=5 _cap_emit_sections <<<"$body")
assert_eq "deterministic (same input -> identical bytes)" "$out" "$out2"

# 6. Boundary: a section exactly AT the cap is unmarked; one over IS marked.
exact=$(printf -- '--- local state changes ---\nx1\nx2\nx3\n' | MONITOR_EMIT_SECTION_MAX_LINES=3 _cap_emit_sections)
assert_not_contains "section exactly at cap: no marker" "$exact" "omitted"
over=$(printf -- '--- local state changes ---\nx1\nx2\nx3\nx4\n' | MONITOR_EMIT_SECTION_MAX_LINES=3 _cap_emit_sections)
assert_contains "section one over cap: marked" "$over" "[+1 more line omitted]"
assert_contains "one-over: singular 'line' (not 'lines')" "$over" "1 more line omitted"

# 7. Default cap is sane (50) when the env var is unset/garbage.
manylines=$(printf -- '--- local state changes ---\n'; for i in $(seq 1 80); do printf 'd%02d\n' "$i"; done)
defout=$(MONITOR_EMIT_SECTION_MAX_LINES=notanumber _cap_emit_sections <<<"$manylines")
assert_contains "garbage cap falls back to default 50" "$defout" "[+30 more lines omitted]"

# ---- Summary --------------------------------------------------------------
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
