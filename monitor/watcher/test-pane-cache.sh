#!/usr/bin/env bash
# Unit tests for the shared pane-state recording cache
# (your-org/nexus-code#562: record each window once per sweep loop and
# reuse the recording for all assessments).
#
# Covers the load-bearing claims:
#   1.  a cache HIT serves EXACTLY the line a fresh fork would produce
#       (verdict equivalence), without forking pane-state.sh again
#   2.  a stale entry refreshes (fork) and REPAIRS the cache
#   3.  a corrupt entry (no `state=` token) is a miss → fork
#   4.  the expected-name guard rejects a reused window index's recording
#   5.  TTL=0 disables the cache wholesale (always fork, never write)
#   6.  `record` mode always forks fresh and writes the recording
#   7.  cross-module reuse: `_over_limit_probe_pane` consumes a
#       recording written via `_idle_pane_state_line`
#   8.  fail-open: unwritable cache dir → probe still returns the fork
#       result (behaviour identical to pre-#562)
#   9.  no orphaned tmp files after writes (atomicity hygiene)
#
# Run: bash monitor/watcher/test-pane-cache.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() {
    printf '  FAIL: %s\n' "$1" >&2
    [[ $# -ge 2 ]] && printf '         %s\n' "$2" >&2
    FAIL=$(( FAIL + 1 ))
}
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then pass "$label"; else fail "$label" "got $(printf %q "$got"), want $(printf %q "$want")"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- fixture: a fake NEXUS_ROOT with a counting pane-state.sh stub ------
# The stub's emit line varies with an on-disk "scenario" file so tests
# can change what a FRESH fork would return, and counts invocations so
# cache hits are distinguishable from forks.
export NEXUS_ROOT="$WORK/nexus"
mkdir -p "$NEXUS_ROOT/monitor"
STUB_COUNT="$WORK/fork-count"
STUB_SCENARIO="$WORK/scenario"
printf '0\n' > "$STUB_COUNT"
printf 'state=busy active=1 window=7 name=worker-a content_hash=aaa\n' > "$STUB_SCENARIO"
cat > "$NEXUS_ROOT/monitor/pane-state.sh" <<STUB
#!/usr/bin/env bash
c=\$(cat "$STUB_COUNT"); echo \$(( c + 1 )) > "$STUB_COUNT"
cat "$STUB_SCENARIO"
STUB
chmod +x "$NEXUS_ROOT/monitor/pane-state.sh"

fork_count() { cat "$STUB_COUNT"; }

export STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR"
export MONITOR_PANE_CACHE_TTL_SECONDS=90
unset MONITOR_PANE_CACHE_MODE MONITOR_PANE_CACHE_DIR 2>/dev/null || true

# Source the module under test + the two probe chokepoints.
# shellcheck source=_pane_cache.sh
source "$_test_dir/_pane_cache.sh"
# shellcheck source=_idle_probe.sh
source "$_test_dir/_idle_probe.sh"
# shellcheck source=_over_limit.sh
source "$_test_dir/_over_limit.sh"

# ============================================================
echo '=== (1) fresh fork populates the cache; hit serves identical line, no re-fork ==='
line1=$(_idle_pane_state_line 7 worker-a)
assert_eq "fork result served" "$line1" "state=busy active=1 window=7 name=worker-a content_hash=aaa"
assert_eq "one fork" "$(fork_count)" "1"
# Change what a fresh fork WOULD return; a cache hit must still serve
# the recording (that is the whole point: one recording per loop).
printf 'state=idle active=0 window=7 name=worker-a content_hash=bbb\n' > "$STUB_SCENARIO"
line2=$(_idle_pane_state_line 7 worker-a)
assert_eq "hit serves the recording verbatim" "$line2" "$line1"
assert_eq "no second fork on hit" "$(fork_count)" "1"

echo '=== (2) stale entry → fork + cache repaired ==='
touch -d '5 minutes ago' "$STATE_DIR/pane-cache/7.line"
line3=$(_idle_pane_state_line 7 worker-a)
assert_eq "stale entry refreshed via fork" "$line3" "state=idle active=0 window=7 name=worker-a content_hash=bbb"
assert_eq "fork happened" "$(fork_count)" "2"
# repaired: the NEXT read hits again
line4=$(_idle_pane_state_line 7 worker-a)
assert_eq "repair wrote the fresh recording back" "$line4" "$line3"
assert_eq "no fork after repair" "$(fork_count)" "2"

echo '=== (3) corrupt entry (no state= token) → miss → fork ==='
printf 'garbage line\n' > "$STATE_DIR/pane-cache/7.line"
line5=$(_idle_pane_state_line 7 worker-a)
assert_eq "corrupt entry bypassed" "$line5" "state=idle active=0 window=7 name=worker-a content_hash=bbb"
assert_eq "fork on corrupt entry" "$(fork_count)" "3"

echo '=== (4) reused-index guard: name mismatch → miss → fork ==='
# Cache holds worker-a's recording under index 7; a caller asking about
# worker-B at index 7 (window closed, index reused) must NOT be served it.
line6=$(_idle_pane_state_line 7 worker-b)
assert_eq "name mismatch forked fresh" "$(fork_count)" "4"
[[ -n "$line6" ]] && pass "mismatch path still returned a line" || fail "mismatch path returned empty"
# ...and a caller with no expected name accepts the entry (back-compat).
line7=$(_idle_pane_state_line 7)
assert_eq "no-name caller hits" "$(fork_count)" "4"

echo '=== (5) TTL=0 disables the cache wholesale ==='
rm -rf "$STATE_DIR/pane-cache"
old_count=$(fork_count)
MONITOR_PANE_CACHE_TTL_SECONDS=0 _idle_pane_state_line 7 worker-a >/dev/null
MONITOR_PANE_CACHE_TTL_SECONDS=0 _idle_pane_state_line 7 worker-a >/dev/null
assert_eq "both calls forked" "$(fork_count)" "$(( old_count + 2 ))"
if [[ -e "$STATE_DIR/pane-cache" ]] && [[ -n "$(ls -A "$STATE_DIR/pane-cache" 2>/dev/null)" ]]; then
    fail "TTL=0 wrote cache entries"
else
    pass "TTL=0 wrote nothing"
fi

echo '=== (6) record mode: always fork, always write ==='
old_count=$(fork_count)
MONITOR_PANE_CACHE_MODE=record _idle_pane_state_line 7 worker-a >/dev/null
MONITOR_PANE_CACHE_MODE=record _idle_pane_state_line 7 worker-a >/dev/null
assert_eq "record mode never reads the cache" "$(fork_count)" "$(( old_count + 2 ))"
[[ -f "$STATE_DIR/pane-cache/7.line" ]] && pass "record mode wrote the recording" \
    || fail "record mode did not write"

echo '=== (7) cross-module reuse: over-limit probe consumes the recording ==='
printf 'state=over-limit active=0 window=7 name=worker-a reset_at=6pm\n' > "$STUB_SCENARIO"
MONITOR_PANE_CACHE_MODE=record _idle_pane_state_line 7 worker-a >/dev/null   # the sweep records
old_count=$(fork_count)
probe=$(_over_limit_probe_pane 7 worker-a)
# THREE fields since your-org/nexus-code#1488: state, reset_at, and WHICH limit.
# A recording that predates the field degrades to `unknown`, which renders as
# "usage" — never as a model tier nobody measured, which is the whole defect.
assert_eq "over-limit verdict from the recording (limit absent ⇒ unknown)" "$probe" "over-limit 6pm unknown"
assert_eq "over-limit probe did not fork" "$(fork_count)" "$old_count"

# …and a recording that HAS the field carries it through, so the assertion
# above is a degradation control rather than the only case covered.
printf 'state=over-limit active=0 window=7 name=worker-a reset_at=6pm limit=weekly_Fable\n' > "$STUB_SCENARIO"
MONITOR_PANE_CACHE_MODE=record _idle_pane_state_line 7 worker-a >/dev/null
probe=$(_over_limit_probe_pane 7 worker-a)
assert_eq "…and a recording carrying limit= propagates the REAL limit, not Opus" "$probe" "over-limit 6pm weekly_Fable"
printf 'state=over-limit active=0 window=7 name=worker-a reset_at=6pm\n' > "$STUB_SCENARIO"

echo '=== (8) fail-open: unwritable cache dir → probe unaffected ==='
rm -rf "$STATE_DIR/pane-cache"
mkdir -p "$STATE_DIR/pane-cache"
chmod 555 "$STATE_DIR/pane-cache"
printf 'state=busy active=1 window=9 name=worker-c content_hash=ccc\n' > "$STUB_SCENARIO"
line8=$(_idle_pane_state_line 9 worker-c)
assert_eq "probe result intact with unwritable cache" "$line8" "state=busy active=1 window=9 name=worker-c content_hash=ccc"
chmod 755 "$STATE_DIR/pane-cache"

echo '=== (9) atomicity hygiene: no orphaned tmp files after writes ==='
rm -rf "$STATE_DIR/pane-cache"
for i in 1 2 3 4 5; do
    _pane_cache_write "w$i" "state=idle active=0 window=$i name=n$i"
done
tmp_left=$(ls "$STATE_DIR/pane-cache"/*.tmp.* 2>/dev/null | wc -l)
assert_eq "no tmp leftovers" "$tmp_left" "0"
entries=$(ls "$STATE_DIR/pane-cache"/*.line 2>/dev/null | wc -l)
assert_eq "five entries written" "$entries" "5"

# ============================================================
echo
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED ($PASS)"
    exit 0
else
    echo "$FAIL TEST(S) FAILED ($PASS passed)" >&2
    exit 1
fi
