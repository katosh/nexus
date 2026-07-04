#!/usr/bin/env bash
# Unit tests for the `--- tmux ---` section of `snapshot_local`
# (monitor/watcher/main.sh).
#
# Phantom-•bell regression: dead worker panes (kept around by
# `remain-on-exit on`) used to get retitled by tmux's
# automatic-rename / OSC paths to a bullet-prefixed name (`•bell`)
# that landed in the watcher's snapshot diff, consumed ~13 lines
# of orchestrator context per emit, and carried zero signal. The
# layer-2 defense is a snapshot-level filter that drops any
# window whose name begins with `•`.
#
# Strategy: extract the `snapshot_local` function body out of
# main.sh via sed (so the test exercises the real code, not a
# copy), redefine `tmux` as a bash function that emits a fixture
# list-windows output, and assert the emitted `--- tmux ---`
# section contains real workers + drops the `•`-prefixed row.
#
# Run: bash monitor/watcher/test-snapshot-tmux-filter.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_main_sh="$_test_dir/main.sh"

PASS=0
FAIL=0

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
    if ! grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         did NOT expect: %s\n' "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

NEXUS_ROOT="$WORK/nexus"
mkdir -p "$NEXUS_ROOT/reports" "$NEXUS_ROOT/work"
export NEXUS_ROOT

# Extract just the snapshot_local function body from main.sh and
# eval it. This keeps the test pinned to the real code without
# triggering main.sh's top-level init (which expects a full
# nexus state tree, a working ng, etc.).
fn_body=$(sed -n '/^snapshot_local() {/,/^}/p' "$_main_sh")
if [[ -z "$fn_body" ]]; then
    echo "FAIL: could not extract snapshot_local() from $_main_sh" >&2
    exit 1
fi
eval "$fn_body"

# ---- Test 1: •-prefixed window names get filtered out ------------------

echo '=== •-prefixed window names dropped from --- tmux --- section ==='

# Redefine tmux as a bash function that returns a fixture
# list-windows body. The fixture mixes (a) a phantom •bell row
# from a dead worker pane, (b) real workers with various legit
# name shapes, and (c) the orchestrator / watcher windows.
tmux() {
    if [[ "$1" == "list-windows" ]]; then
        cat <<'EOF'
orchestrator bell=0
watcher bell=0
worker-A bell=0
worker-B bell=0
agent-sandbox-v0-12-0 bell=0
•bell bell=0
EOF
        return 0
    fi
    return 0
}
export -f tmux

out=$(snapshot_local 2>/dev/null)
assert_contains    "section header present"              "$out" "--- tmux ---"
assert_contains    "orchestrator passes through"         "$out" "orchestrator bell=0"
assert_contains    "watcher passes through"              "$out" "watcher bell=0"
assert_contains    "worker-A passes through"             "$out" "worker-A bell=0"
assert_contains    "worker-B passes through"             "$out" "worker-B bell=0"
assert_contains    "dotted legit name passes through"    "$out" "agent-sandbox-v0-12-0 bell=0"
assert_not_contains "•bell phantom row dropped"          "$out" "•bell"

# ---- Test 2: multiple •-prefixed rows all get filtered ----------------

echo '=== multiple •-prefixed rows all drop ==='

tmux() {
    if [[ "$1" == "list-windows" ]]; then
        cat <<'EOF'
•bell bell=0
•foo bell=0
worker-C bell=1
•bar bell=0
EOF
        return 0
    fi
    return 0
}
export -f tmux

out=$(snapshot_local 2>/dev/null)
assert_contains    "real worker survives"               "$out" "worker-C bell=1"
assert_not_contains "•bell row dropped"                 "$out" "•bell"
assert_not_contains "•foo row dropped"                  "$out" "•foo"
assert_not_contains "•bar row dropped"                  "$out" "•bar"

# ---- Test 3: filter is anchored at the START of the name only ---------
#
# A legitimate name that happens to contain `•` mid-string should NOT
# be dropped. Anchoring on `^•` keeps the filter narrow.

echo '=== • only filters at start of name; mid-string • survives ==='

tmux() {
    if [[ "$1" == "list-windows" ]]; then
        cat <<'EOF'
•bell bell=0
weird•mid bell=0
EOF
        return 0
    fi
    return 0
}
export -f tmux

out=$(snapshot_local 2>/dev/null)
assert_not_contains "leading-• row dropped"             "$out" "•bell"
assert_contains    "mid-string • survives"              "$out" "weird•mid bell=0"

# ---- Test 4: empty list-windows output produces just the header -------

echo '=== empty tmux list-windows → bare --- tmux --- header ==='

tmux() {
    if [[ "$1" == "list-windows" ]]; then
        return 0
    fi
    return 0
}
export -f tmux

out=$(snapshot_local 2>/dev/null)
# Whittle out to just the tmux section to make the assertion crisp.
tmux_section=$(awk '/^--- tmux ---$/{flag=1;next} /^--- /{flag=0} flag' <<<"$out")
if [[ -z "$tmux_section" ]]; then
    printf '  PASS: empty tmux section under header\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: tmux section non-empty when list-windows is empty\n' >&2
    printf '         got:\n%s\n' "$tmux_section" | sed 's/^/           /' >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- summary ----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
