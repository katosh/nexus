#!/usr/bin/env bash
# Regression test for the early pidfile publish (your-org/your-nexus
# #180 R5). main.sh must write monitor/.state/watcher.pid before the
# bulk of its config/load.sh lookups, so launcher.sh's 15 s
# headless-spawn verify never false-fails on a loaded NFS root where
# the ~50 lookups can take >15 s.
#
# Strategy: build an isolated nexus tree whose config/load.sh is a
# SLOW shim — it sleeps on every key EXCEPT `nexus.root` (which must
# stay fast, since the early publish depends on it). Launch main.sh
# and poll for watcher.pid: it must appear in well under the time the
# full config block would take, and hold this process's child pid.
#
# We don't let main.sh run a real cycle — `tmux`/`gh`/`mint-token` are
# stubbed and the process is killed once the pidfile assertion is made.
#
# Run: bash monitor/watcher/test-pidfile-early-publish.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_src_root=$(cd "$_test_dir/../.." && pwd)

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d -t nexus-pidfile-early-XXXXXX)
cleanup() {
    [[ -n "${MAIN_PID:-}" ]] && kill "$MAIN_PID" 2>/dev/null
    [[ -n "${MAIN_PID:-}" ]] && wait "$MAIN_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

ROOT="$WORK/nexus"
mkdir -p "$ROOT/monitor/watcher" "$ROOT/config" "$ROOT/monitor/.state" "$WORK/bin"

# Mirror the watcher tree (main.sh + every helper it sources) into the
# isolated root so main.sh resolves its `source` lines and its
# `$_cfg` = `$_monitor_dir/../config/load.sh` path within the fixture.
cp "$_test_dir"/*.sh "$ROOT/monitor/watcher/"
# _cc-version.sh lives one level up (monitor/), sourced by main.sh.
cp "$_src_root/monitor/_cc-version.sh" "$ROOT/monitor/" 2>/dev/null || true
chmod +x "$ROOT/monitor/watcher/main.sh"

# SLOW config/load.sh shim. Fast for nexus.root (the early publish
# needs it); 0.3 s per other key — with the ~50 lookups in main.sh
# that is ~15 s, the exact budget the launcher verify allows. The
# early publish must beat it by a wide margin.
SLEEP_PER_KEY=0.3
cat > "$ROOT/config/load.sh" <<EOF
#!/usr/bin/env bash
key="\${1:-}"
default="\${2:-}"
if [[ "\$key" == "nexus.root" ]]; then
    printf '%s\n' "$ROOT"
    exit 0
fi
sleep $SLEEP_PER_KEY
printf '%s\n' "\$default"
exit 0
EOF
chmod +x "$ROOT/config/load.sh"

# Stub bin: tmux (no-op so window work is inert), gh + mint-token so
# any snapshot path that runs before we kill main is harmless.
cat > "$WORK/bin/tmux" <<'T'
#!/bin/bash
exit 0
T
cat > "$WORK/bin/gh" <<'G'
#!/bin/bash
echo '{"data":{"search":{"nodes":[]}}}'
G
cat > "$WORK/bin/mint-token.sh" <<'M'
#!/bin/bash
printf 'fake-token\n'
M
chmod +x "$WORK/bin/tmux" "$WORK/bin/gh" "$WORK/bin/mint-token.sh"

PIDFILE="$ROOT/monitor/.state/watcher.pid"
rm -f "$PIDFILE"

echo '=== pidfile appears before the slow config block completes ==='

start_ns=$(date +%s%N)
PATH="$WORK/bin:$PATH" \
NEXUS_ROOT="$ROOT" \
MINT_TOKEN_BIN="$WORK/bin/mint-token.sh" \
MINT_JWT_BIN="$WORK/bin/mint-token.sh" \
MONITOR_TARGET=nonexistent \
  bash "$ROOT/monitor/watcher/main.sh" >/dev/null 2>&1 &
MAIN_PID=$!

# Poll for the pidfile. The early publish should land within a few
# hundred ms (one fast nexus.root lookup + a couple of source loads),
# FAR under the ~15 s the full config block takes. Cap the poll at 5 s
# — comfortably below 15 s, but generous for a slow CI box doing the
# source loads.
deadline_ns=$(( start_ns + 5000000000 ))
appeared_ns=0
while (( $(date +%s%N) < deadline_ns )); do
    if [[ -s "$PIDFILE" ]]; then
        appeared_ns=$(date +%s%N)
        break
    fi
    sleep 0.05
done

if (( appeared_ns == 0 )); then
    fail "watcher.pid did not appear within 5 s (early publish regressed — it now waits on the full config block)"
else
    elapsed_ms=$(( (appeared_ns - start_ns) / 1000000 ))
    # The first 8 non-root lookups alone would be ~2.4 s; appearing
    # under 2 s proves the publish precedes the bulk of the block.
    if (( elapsed_ms < 2000 )); then
        pass "watcher.pid published in ${elapsed_ms}ms (well before the ~15 s config block)"
    else
        fail "watcher.pid took ${elapsed_ms}ms — slower than the early-publish budget (regression?)"
    fi
    content=$(<"$PIDFILE")
    if [[ "$content" == "$MAIN_PID" ]]; then
        pass "pidfile holds main.sh's pid ($content)"
    else
        fail "pidfile content '$content' != main.sh pid '$MAIN_PID'"
    fi
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
