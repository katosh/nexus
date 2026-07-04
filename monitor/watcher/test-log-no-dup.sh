#!/usr/bin/env bash
# Regression test for the headless-launch log double-write (issue
# your-org/your-nexus#180, item R1).
#
# The headless launcher runs `setsid main.sh >>"$LOGFILE" 2>&1`, so the
# watcher process's stderr is appended to the SAME file that `log()`'s
# `printf` targets. Before the fix, `log()` unconditionally echoed each
# message to stderr AND printf'd it to the logfile, so every line landed
# in watcher.log twice (byte-identical, same timestamp) — doubling the
# file and halving the effective rotation horizon.
#
# This test reproduces that exact redirect: run `main.sh --once` with
# stdout+stderr merged into the logfile path, then assert no `[ts] msg`
# line appears more than once. The fix gates the stderr echo on
# `[[ -t 2 ]]` (terminal only), so the headless/redirected path writes
# each line exactly once.
#
# Run: bash monitor/watcher/test-log-no-dup.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_main_sh="$_test_dir/main.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d -t nexus-log-no-dup-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

NEXUS_ROOT="$WORK/nexus"
STATE_DIR="$NEXUS_ROOT/monitor/.state"
mkdir -p "$STATE_DIR" "$NEXUS_ROOT/reports" "$NEXUS_ROOT/work"
LOGFILE="$STATE_DIR/watcher.log"

# Minimal stub bin: a tmux that fails every subcommand (so paste/probe
# paths short-circuit cleanly) and a mint-token stub so snapshot_github
# proceeds past its `|| return 0` guard without real network.
mock_bin="$WORK/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/tmux" <<'TMUX'
#!/bin/bash
exit 1
TMUX
cat > "$mock_bin/gh" <<'GH'
#!/bin/bash
# Minimal gh: emit an empty GraphQL search result, succeed otherwise.
echo '{"data":{"search":{"nodes":[]}}}'
exit 0
GH
cat > "$mock_bin/mint-token.sh" <<'MINT'
#!/bin/bash
printf 'fake-test-token\n'
MINT
chmod +x "$mock_bin/tmux" "$mock_bin/gh" "$mock_bin/mint-token.sh"

PATH_STUB="$mock_bin"
for d in /usr/local/bin /usr/bin /bin; do
    [[ -d "$d" ]] && PATH_STUB="${PATH_STUB}:${d}"
done

# Reproduce the launcher's exact redirect: process stdout+stderr append
# to the logfile, which is also log()'s printf sink. `< /dev/null` and
# no controlling terminal mean `[[ -t 2 ]]` is false, matching headless.
PATH="$PATH_STUB" \
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
MONITOR_CC_UPDATE_INTERVAL_SECONDS=0 \
AGENT_DEAD_THRESHOLD=999 \
AGENT_MISSING_RESPAWN_DELAY=999 \
bash "$_main_sh" --once >>"$LOGFILE" 2>&1 </dev/null

if [[ ! -s "$LOGFILE" ]]; then
    fail "watcher.log is empty after --once (main.sh did not log)"
else
    pass "watcher.log populated after --once"

    # The `watcher up:` startup line is emitted exactly once per run and
    # is the cleanest single-emission marker. With the bug it appears
    # twice (identical bytes); after the fix, once.
    up_count=$(grep -cF 'watcher up:' "$LOGFILE")
    if (( up_count == 1 )); then
        pass "'watcher up:' line appears exactly once (got $up_count)"
    else
        fail "'watcher up:' line appears $up_count times (expected 1 — log double-write?)"
    fi

    # Duplicate-line guard, scoped to `log()` output. Every `log()` line
    # carries an `[<ISO-8601>] ` prefix (`date -Is`, e.g.
    # `[2026-06-09T15:43:29-07:00] `); unrelated stderr from sourced
    # helpers (e.g. load.sh's "no config found" warning) lacks it. A
    # byte-identical repeat of a timestamped line can only happen when
    # the SAME log() invocation wrote it twice — the double-write bug.
    dup=$(grep -E '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$LOGFILE" | sort | uniq -d | head -5)
    if [[ -z "$dup" ]]; then
        pass "no byte-identical duplicate log() lines"
    else
        fail "byte-identical duplicate log() line(s) present:"
        printf '%s\n' "$dup" | sed 's/^/         /' >&2
    fi
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
