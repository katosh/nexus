#!/usr/bin/env bash
# Tests for the watcher's wrong-launch self-close guards in main.sh
# (issue #203 revision, operator direction on PR #266: "the watcher
# should not run twice and close instead after making sure its window
# is not called orchestrator").
#
# Covers:
#   1.  Live peer watcher (identity-verified pidfile) → main.sh refuses
#       (rc=1) BEFORE the early pidfile publish, so the peer's pidfile
#       is never clobbered.
#   1b. STALE pidfile (dead pid) → no false refusal; main.sh publishes
#       its own pid (conservative-guard regression case).
#   2.  main.sh hosted inside the window named $TARGET → renames the
#       window off the target name ('watcher-misplaced') and refuses
#       (rc=1) with an informative message.
#   2b. Inherited TMUX_PANE WITHOUT pane ancestry (the legitimate
#       headless watcher spawned from an orchestrator's Bash tool
#       carries the orchestrator's TMUX_PANE through env) → guard
#       inert; the watcher starts normally.
#
# Strategy: isolated fake nexus tree (fast config shim — the guards
# run right after _config.sh), stub tmux/gh on PATH. Fixture watchers
# are killed with SIGKILL: a TERM'd main.sh defers its trap until the
# current interval sleep returns (up to 60 s) and fixture state needs
# no graceful cleanup.
#
# Run: bash monitor/watcher/test-wrong-launch-guard.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_src_root=$(cd "$_test_dir/../.." && pwd)

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d -t nexus-wrong-launch-XXXXXX)
cleanup() {
    [[ -n "${FAKE_WATCHER_PID:-}" ]] && kill -9 "$FAKE_WATCHER_PID" 2>/dev/null
    [[ -n "${MAIN2_PID:-}" ]] && kill -9 "$MAIN2_PID" 2>/dev/null
    [[ -n "${MAIN3_PID:-}" ]] && kill -9 "$MAIN3_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

ROOT="$WORK/nexus"
mkdir -p "$ROOT/monitor/watcher" "$ROOT/config" "$ROOT/monitor/.state" "$WORK/bin"
cp "$_test_dir"/*.sh "$ROOT/monitor/watcher/"
cp "$_src_root/monitor/_cc-version.sh" "$ROOT/monitor/" 2>/dev/null || true
# FAST config shim: every key echoes its default (the guards run after
# _config.sh; a slow shim would add ~15 s per case).
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${2:-}"\n' > "$ROOT/config/load.sh"
chmod +x "$ROOT/config/load.sh" "$ROOT/monitor/watcher/main.sh"
PIDFILE="$ROOT/monitor/.state/watcher.pid"

# Stub bin: inert tmux (case 2 swaps in a recording one), benign gh.
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/tmux"
printf '#!/bin/bash\necho "{}"\n' > "$WORK/bin/gh"
chmod +x "$WORK/bin/tmux" "$WORK/bin/gh"

echo '=== (1) live peer watcher → refuse before the pidfile clobber ==='

# A real long-running process whose argv program slot matches
# */monitor/watcher/main.sh — what _watcher_pid_is_live_watcher
# positively identifies.
mkdir -p "$WORK/fakewatcher/monitor/watcher"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$WORK/fakewatcher/monitor/watcher/main.sh"
bash "$WORK/fakewatcher/monitor/watcher/main.sh" &
FAKE_WATCHER_PID=$!
sleep 0.2
printf '%s\n' "$FAKE_WATCHER_PID" > "$PIDFILE"
PATH="$WORK/bin:$PATH" NEXUS_ROOT="$ROOT" MONITOR_TARGET=nonexistent \
    bash "$ROOT/monitor/watcher/main.sh" >/dev/null 2>"$WORK/dup-stderr.txt"
DUP_RC=$?
if (( DUP_RC == 1 )) && grep -q "another live watcher" "$WORK/dup-stderr.txt"; then
    pass "live peer watcher → duplicate refused (rc=1) with informative message"
else
    fail "duplicate refusal: rc=$DUP_RC err=$(head -2 "$WORK/dup-stderr.txt")"
fi
if [[ "$(cat "$PIDFILE")" == "$FAKE_WATCHER_PID" ]]; then
    pass "peer's pidfile NOT clobbered by the refused duplicate"
else
    fail "pidfile clobbered: holds '$(cat "$PIDFILE")', want $FAKE_WATCHER_PID"
fi
kill -9 "$FAKE_WATCHER_PID" 2>/dev/null
wait "$FAKE_WATCHER_PID" 2>/dev/null
FAKE_WATCHER_PID=""

echo
echo '=== (1b) stale pidfile → no false refusal ==='

sleep 60 &
STALE_PID=$!
kill -9 "$STALE_PID" 2>/dev/null
wait "$STALE_PID" 2>/dev/null
printf '%s\n' "$STALE_PID" > "$PIDFILE"
PATH="$WORK/bin:$PATH" NEXUS_ROOT="$ROOT" MONITOR_TARGET=nonexistent \
    bash "$ROOT/monitor/watcher/main.sh" >/dev/null 2>&1 &
MAIN2_PID=$!
published=0
for _i in $(seq 1 100); do
    [[ "$(cat "$PIDFILE" 2>/dev/null)" == "$MAIN2_PID" ]] && { published=1; break; }
    kill -0 "$MAIN2_PID" 2>/dev/null || break
    sleep 0.05
done
if (( published )); then
    pass "stale pidfile → no false refusal; own pid published"
else
    fail "stale pidfile blocked a legitimate start (alive=$(kill -0 "$MAIN2_PID" 2>/dev/null && echo yes || echo no))"
fi
kill -9 "$MAIN2_PID" 2>/dev/null
wait "$MAIN2_PID" 2>/dev/null
MAIN2_PID=""

echo
echo '=== (2) hosted inside the target-named window → rename off + refuse ==='

GUARD_TMUX_LOG="$WORK/guard-tmux.log"
cat > "$WORK/bin/tmux" <<T
#!/bin/bash
echo "tmux \$*" >> "$GUARD_TMUX_LOG"
case "\$1" in
  display|display-message)
      fmt=""; shift
      while (( \$# > 0 )); do
          case "\$1" in -p) shift ;; -t) shift 2 ;; *) fmt="\$1"; shift ;; esac
      done
      case "\$fmt" in
          '#{pane_pid}') cat "$WORK/guard-pane-pid" 2>/dev/null ;;
          *)             printf '@3\torchwin\n' ;;
      esac
      ;;
  list-panes) : ;;   # no orchestrator process in the window
  *) : ;;
esac
exit 0
T
chmod +x "$WORK/bin/tmux"
printf '%s\n' "$$" > "$WORK/guard-pane-pid"   # pane hosts us (we are main.sh's ancestor)
rm -f "$PIDFILE"
: > "$GUARD_TMUX_LOG"
TMUX=/tmp/fake,1,1 TMUX_PANE=%0 \
PATH="$WORK/bin:$PATH" NEXUS_ROOT="$ROOT" MONITOR_TARGET=orchwin \
    bash "$ROOT/monitor/watcher/main.sh" >/dev/null 2>"$WORK/win-stderr.txt"
WIN_RC=$?
if (( WIN_RC == 1 )) && grep -q "REFUSING to run inside the 'orchwin' window" "$WORK/win-stderr.txt" \
   && grep -q "rename-window -t @3 watcher-misplaced" "$GUARD_TMUX_LOG"; then
    pass "watcher inside target window → renamed off + refused (rc=1)"
else
    fail "window guard: rc=$WIN_RC err=$(head -2 "$WORK/win-stderr.txt") renames=$(grep rename "$GUARD_TMUX_LOG" || true)"
fi

echo
echo '=== (2b) inherited TMUX_PANE without ancestry → guard inert ==='

printf '1\n' > "$WORK/guard-pane-pid"   # pid 1 is never our ancestor
rm -f "$PIDFILE"
TMUX=/tmp/fake,1,1 TMUX_PANE=%0 \
PATH="$WORK/bin:$PATH" NEXUS_ROOT="$ROOT" MONITOR_TARGET=orchwin \
    bash "$ROOT/monitor/watcher/main.sh" >/dev/null 2>&1 &
MAIN3_PID=$!
published=0
for _i in $(seq 1 100); do
    [[ "$(cat "$PIDFILE" 2>/dev/null)" == "$MAIN3_PID" ]] && { published=1; break; }
    kill -0 "$MAIN3_PID" 2>/dev/null || break
    sleep 0.05
done
if (( published )); then
    pass "inherited TMUX_PANE without ancestry → guard inert (headless watcher unharmed)"
else
    fail "ancestry check failed open: a headless-style watcher was refused"
fi
kill -9 "$MAIN3_PID" 2>/dev/null
wait "$MAIN3_PID" 2>/dev/null
MAIN3_PID=""

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
