#!/usr/bin/env bash
# Integration tests for the watcher's emit gate (monitor/watcher/main.sh).
#
# Regression test for the bug where a operator comment fired exactly one
# emit per snapshot-diff cycle: if the orchestrator missed the first
# emit (paste-buffer race, inattention), the comment stayed eligible
# but the watcher never re-emitted until something else perturbed the
# snapshot. Behavior under test: every poll where one or more eligible
# comments are present must emit, and emits driven solely by still-
# eligible comments must NOT overwrite last-snapshot.txt (no-dirty-
# write — overwriting would absorb a fresh real diff into "no change
# since last write" and silently mask it).
#
# Strategy: run main.sh --once three times against a temp NEXUS_ROOT,
# with a mock `gh` on PATH that returns a fixed eligible-comment
# response. Each --once invocation runs the startup sweep + one loop
# iteration (= two emits when the comment is eligible: one untagged
# from the startup-sweep path, one *_resurface from the loop path).
# The test compares archive counts and the BASELINE file's content +
# mtime across invocations.
#
# Run: bash monitor/watcher/test-emit-gate.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_main_sh="$_test_dir/main.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" got="$2" expected="$3"
    if [[ "$got" == "$expected" ]]; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected: %s\n' "$expected" >&2
        printf '         got:      %s\n' "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness setup -------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

NEXUS_ROOT="$WORK/nexus"
mkdir -p "$NEXUS_ROOT/reports" "$NEXUS_ROOT/work" "$NEXUS_ROOT/monitor/.state"
STATE_DIR="$NEXUS_ROOT/monitor/.state"
DIFF_DIR="$STATE_DIR/diffs"
BASELINE="$STATE_DIR/last-snapshot.txt"

# Mock `gh` on PATH. Returns canned graphql responses based on the
# `q=` arg of the search query so all three sources (issue comments /
# PR comments / new issues) get a deterministic answer. The fixture
# files are pointed at via env vars so individual tests can swap them
# without rewriting the shim.
#
# Two companion shims live alongside `gh`:
#   - `mint-token.sh`: production's `snapshot_github` calls this and
#     short-circuits with `return 0` on failure (see _github.sh). The
#     real script needs a configured App + bot creds; in tests we stub
#     it to print a fake token so the snapshot proceeds against the
#     mocked `gh`.
#   - `tmux`: the watcher's idle probe and bell/snapshot helpers all
#     consult tmux. Without a stub they leak real worker state from
#     the host tmux session into emit bodies, corrupting fixture-based
#     assertions. The stub returns rc=1 for every subcommand, which
#     makes `paste_to_target` rc=2 (target missing) and the idle/bell
#     probes return empty — the deliberate "tmux-absent" posture the
#     test header references.
mock_bin="$WORK/mock-bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/gh" <<'GH'
#!/bin/bash
# minimal mock: handles `gh api graphql -f query=... -f q=... [...]`
# (the watcher's snapshot helpers) and `gh api /rate_limit` (the
# `_graphql_polling_gate` probe). Other gh subcommands exit 1.
if [[ "$1" == "api" && "$2" == "/rate_limit" ]]; then
    cat <<'JSON'
{"resources":{"core":{"limit":5000,"remaining":4990,"used":10},
              "graphql":{"limit":5000,"remaining":4500,"used":500},
              "search":{"limit":30,"remaining":30,"used":0}}}
JSON
    exit 0
fi
[[ "$1" == "api" && "$2" == "graphql" ]] || exit 1
shift 2
q=""
while (( $# > 0 )); do
    case "$1" in
        -f) [[ "$2" == q=* ]] && q="${2#q=}"; shift 2 ;;
        *)  shift ;;
    esac
done
if [[ "$q" == *"is:issue"* && "$q" == *"author:"* ]]; then
    cat "${MOCK_NEW_ISSUES_FIXTURE:-/dev/null}" 2>/dev/null
elif [[ "$q" == *"is:issue"* ]]; then
    cat "${MOCK_ISSUE_FIXTURE:-/dev/null}" 2>/dev/null
elif [[ "$q" == *"is:pr"* ]]; then
    cat "${MOCK_PR_FIXTURE:-/dev/null}" 2>/dev/null
else
    echo "{}"
fi
exit 0
GH
chmod +x "$mock_bin/gh"

# Stub mint-token.sh — prints a deterministic fake token so
# `snapshot_github` proceeds past its `|| return 0` guard. The mocked
# `gh` above ignores GH_TOKEN, so the value just needs to be non-empty.
cat > "$mock_bin/mint-token.sh" <<'MINT'
#!/bin/bash
printf 'fake-test-token\n'
MINT
chmod +x "$mock_bin/mint-token.sh"

# Stub tmux — every subcommand exits 1. Quiet `command -v tmux`
# succeeds (the binary is on PATH), but `tmux list-windows`,
# `tmux send-keys`, etc. all fail, which is what the test wants:
# paste_to_target returns rc=2 (target missing), idle/bell probes
# return empty, snapshot_local's `--- tmux ---` section is empty.
cat > "$mock_bin/tmux" <<'TMUX'
#!/bin/bash
exit 1
TMUX
chmod +x "$mock_bin/tmux"

# Fixtures. Comment 4001 on issue 42 — eligible (no reactions). Empty
# fixture is a search response with zero nodes, used for sources that
# should not emit and to simulate the eyes-reacted state.
ELIGIBLE_FIXTURE="$WORK/eligible.json"
EMPTY_FIXTURE="$WORK/empty.json"
cat > "$ELIGIBLE_FIXTURE" <<'JSON'
{"data":{"search":{"nodes":[
  {"number":42,"comments":{"nodes":[
    {"databaseId":4001,"author":{"login":"operator"},"body":"resurface me","reactions":{"nodes":[]}}
  ]}}
]}}}
JSON
cat > "$EMPTY_FIXTURE" <<'JSON'
{"data":{"search":{"nodes":[]}}}
JSON

# Drop tmux + jq are required (jq is normal-system; we keep). Drop
# tmux so paste_with_retry returns rc=1 quickly. Keep jq, find, awk,
# coreutils available.
PATH_NO_TMUX="$mock_bin"
for d in /usr/local/bin /usr/bin /bin; do
    [[ -d "$d" ]] && PATH_NO_TMUX="${PATH_NO_TMUX}:${d}"
done

# Common env for every main.sh --once invocation. AGENT_MISSING_RESPAWN_DELAY
# is large so the no-tmux poll-level "target absent" check (rc=1) doesn't
# trigger respawn anyway, but extra defense in depth.
# WATCHER_WINDOW=headless mimics the launcher's headless marker — without
# it every --once run counts as legacy-hosted and the startup sweep
# emits the one-shot hosting-migration notice (issue 182), breaking the
# no-emit assertions.
run_once() {
    PATH="$PATH_NO_TMUX" \
    WATCHER_WINDOW=headless \
    MINT_TOKEN_BIN="$mock_bin/mint-token.sh" \
    MINT_JWT_BIN="$mock_bin/mint-token.sh" \
    NEXUS_ROOT="$NEXUS_ROOT" \
    MONITOR_INTERVAL=0 \
    MONITOR_REPO=test/repo \
    MONITOR_USER_LOGIN=operator \
    MONITOR_TARGET=nonexistent-test-target \
    MONITOR_AUTO_UNSTICK=false \
    MONITOR_DELIVERIES_ASSET_ENABLED=false \
    MONITOR_DELIVERIES_BOT_MENTION_ENABLED=false \
    MONITOR_MENTIONS_ENABLED=false \
    MONITOR_RATELIMIT_PROBE=false \
    MONITOR_GRAPHQL_THRESHOLD=0 \
    MONITOR_BOT_LOGIN= \
    DIFF_RETENTION_DAYS=7 \
    AGENT_DEAD_THRESHOLD=999 \
    AGENT_MISSING_RESPAWN_DELAY=999 \
    MONITOR_RATELIMIT_HEURISTIC_MIN=30 \
    MONITOR_RATELIMIT_ACK_TIMEOUT_S=60 \
    MONITOR_PROBE_MODEL=test-model \
    MONITOR_EMIT_COOLDOWN_SECONDS=0 \
    bash "$_main_sh" --once >>"$WORK/run.log" 2>&1
}
# `MONITOR_EMIT_COOLDOWN_SECONDS=0` opts out of the per-comment
# rate limiter introduced alongside `_filter_processed_comments`.
# This suite was written before that filter and asserts the
# unrate-limited "every-poll-while-eligible emits" gate — the
# cooldown's own behaviour is covered by `test-eligibility-staleness.sh`.

count_archives() {
    find "$DIFF_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' '
}

count_resurface_archives() {
    find "$DIFF_DIR" -maxdepth 1 -type f -name '*_resurface.md' 2>/dev/null | wc -l | tr -d ' '
}

# Stable fingerprint for a file: sha256 of content + nanosecond mtime.
# Both must match across invocations to prove the file was not touched
# (the no-dirty-write contract).
fingerprint_baseline() {
    [[ -f "$BASELINE" ]] || { echo "MISSING"; return; }
    local sum mtime
    sum=$(sha256sum "$BASELINE" | awk '{print $1}')
    mtime=$(stat -c '%Y.%N' "$BASELINE" 2>/dev/null || stat -f '%m' "$BASELINE" 2>/dev/null)
    printf '%s_%s' "$sum" "$mtime"
}

# ---- invocation 1: comment is eligible -----------------------------------

echo '=== invocation 1: eligible comment fires emit ==='
export MOCK_ISSUE_FIXTURE="$ELIGIBLE_FIXTURE"
export MOCK_PR_FIXTURE="$EMPTY_FIXTURE"
export MOCK_NEW_ISSUES_FIXTURE="$EMPTY_FIXTURE"

run_once
sleep 0.05  # let mtimes settle
fp_after_1=$(fingerprint_baseline)
total_1=$(count_archives)
resurface_1=$(count_resurface_archives)

assert_eq "invocation 1 produced startup-sweep + loop emits (2 archives)" "$total_1" "2"
assert_eq "invocation 1 produced exactly 1 _resurface (loop body emit)"   "$resurface_1" "1"

# Inspect the resurface archive: must carry the resurface reason and
# the eligible-comments section, must NOT carry a local-diff section.
resurface_path=$(find "$DIFF_DIR" -maxdepth 1 -type f -name '*_resurface.md' | head -1)
resurface_body=$(cat "$resurface_path" 2>/dev/null)
assert_contains "resurface body has reason=poll-resurface"   "$resurface_body" "(poll-resurface)"
assert_contains "resurface body has eligible-comments section" "$resurface_body" "--- eligible github comments ---"
assert_contains "resurface body cites the eligible comment id" "$resurface_body" "id=4001"

# ---- invocation 2: same eligible comment, regression test ---------------

echo '=== invocation 2: same comment still eligible -> emits again, baseline untouched ==='
run_once
sleep 0.05
fp_after_2=$(fingerprint_baseline)
total_2=$(count_archives)
resurface_2=$(count_resurface_archives)

assert_eq "invocation 2 added 2 more archives (4 total)"      "$total_2" "4"
assert_eq "invocation 2 added 1 more _resurface (2 total)"    "$resurface_2" "2"
assert_eq "BASELINE content+mtime unchanged across inv 1->2"  "$fp_after_2" "$fp_after_1"

# ---- invocation 3: comment now ineligible (eyes-reacted) ----------------

echo '=== invocation 3: comment ineligible -> no emit ==='
export MOCK_ISSUE_FIXTURE="$EMPTY_FIXTURE"

run_once
sleep 0.05
fp_after_3=$(fingerprint_baseline)
total_3=$(count_archives)
resurface_3=$(count_resurface_archives)

assert_eq "invocation 3 produced no new archives (still 4)"      "$total_3" "4"
assert_eq "invocation 3 produced no new _resurface (still 2)"    "$resurface_3" "2"
assert_eq "BASELINE content+mtime unchanged across inv 2->3"     "$fp_after_3" "$fp_after_2"

# ---- summary --------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "FAILED"
    [[ -f "$WORK/run.log" ]] && { echo "--- run log:"; cat "$WORK/run.log"; }
    exit 1
fi
