#!/usr/bin/env bash
# Integration test for the crash-loop guard wired through main.sh.
#
# Sets up a fake nexus root, brings up a dedicated tmux server on a
# fixture-private socket (so it can't pollute the live nexus tmux),
# and runs main.sh against a stub `claude` that exits 1 immediately.
# After the configured limit of respawns within the window, the
# guard should trip — verified by the presence of the
# `respawn-guard-tripped` sentinel, the entries in
# `respawn-history.txt`, and the watcher log.
#
# This test is timing-dependent (15-30 s wall-clock) and requires
# tmux on PATH. It is NOT picked up by name-pattern test runners
# that match `test-*.sh` automatically — invoke it manually from
# the watcher dir, or wire it into a CI job that has tmux available.
#
# Gated behind SLOW_TESTS=1 (issue #40) so the default fast suite
# stays under 10 s. CI / pre-push should opt in by exporting
# `SLOW_TESTS=1`; the fast iteration loop runs without it.
#
# Run directly: SLOW_TESTS=1 ./monitor/watcher/test-respawn-loop-integration.sh

set -euo pipefail

if [ "${SLOW_TESTS:-0}" != "1" ]; then
    echo "skipped: $(basename "$0") (set SLOW_TESTS=1 to enable; ~13s wall-clock)"
    exit 77   # SKIP, not PASS (your-org/nexus-code#568 A6)
fi

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
SRC=$(cd "$_test_dir/../.." && pwd)
# shellcheck source=/dev/null
. "$_test_dir/_test_helpers.sh"

F=$(mktemp -d -t nexus-respawn-integ-XXXXXX)
echo "FIXTURE=$F"
echo "SRC=$SRC"

mkdir -p "$F/config" "$F/monitor/watcher" "$F/.bin" "$F/reports" "$F/work"

# Copy the real watcher tree into the fixture so main.sh resolves its
# own helper sources cleanly. Glob the WHOLE `_*.sh` helper set rather
# than enumerating it: main.sh has accreted ~16 `source` lines over
# time (_scheduler.sh, _over_limit.sh, _orchestrator_liveness.sh,
# _cc_update.sh, …), and an enumerated copy list silently drifts —
# every uncopied source becomes a `command not found` no-op that
# guts a code path (e.g. the rc=2 respawn branch via _target_absent.sh,
# issue #174; the scheduler loop via _scheduler.sh). Globbing is
# drift-proof: a new `source` line is covered automatically.
cp "$SRC/monitor/watcher/main.sh"   "$F/monitor/watcher/main.sh"
cp "$SRC"/monitor/watcher/_*.sh     "$F/monitor/watcher/"
# The SAME glob, one level up. main.sh and its modules source `../_*.sh` too —
# _cc-version.sh, _log-mode.sh (#509), _claude-bin.sh (#555), _tmux-window.sh,
# _channel_lib.sh — and until your-org/nexus-code#737 this side of the tree was
# ENUMERATED while the comment above explained, correctly, why enumeration
# drifts. It drifted three times: #555 (_claude-bin.sh), #589 (guard-block.sh.in)
# and then _tmux-window.sh + _channel_lib.sh, which main.sh:271 and _requests.sh
# source and which no copy line ever mentioned. The third one broke the test
# outright — the fixture watcher spawned a respawn window whose command was a
# `No such file or directory`, the window died, the last window closing took the
# private tmux server with it, the watcher took a SIGHUP five seconds in, and the
# guard could not trip. Deterministic; 4/4 runs.
#
# The drift-proofing was written and then applied only to the directory its
# author was looking at (your-org/nexus-code#735 F5). Both sibling dirs glob now.
cp "$SRC"/monitor/_*.sh             "$F/monitor/"
# ...and ../guard-block.sh.in, the shim-precondition TEMPLATE _respawn.sh
# reads (not sources) when composing a launcher. EXACTLY the drift this
# file's own header warns about, and the second instance of it after `#555`:
# without the template _respawn refuses (rather than emitting a launcher
# with an empty guard block), so the helper aborted before spawning the stub
# and the guard tripped on repeated helper failures instead of on the crash
# loop this test claims to exercise. Note the glob above covers
# monitor/watcher/_*.sh only — a one-level-up, non-.sh file is invisible to
# it. your-org/nexus-code#589.
cp "$SRC/monitor/guard-block.sh.in"  "$F/monitor/guard-block.sh.in"
# ...and the assert helper the emitted guard looks for. Without it the guard
# finds NO helper under either root and REFUSES (exit 78) — correct
# production behaviour, wrong for a fixture, and the same reason the template
# above is needed. The real helper is copied, not a stub: this fake tree has
# no monitor/ghwrap, so it returns its `exit 79` (NOT CHECKED) immediately
# without probing a shell, and the launcher proceeds.
cp "$SRC/monitor/assert-gh-wrapped.sh" "$F/monitor/assert-gh-wrapped.sh"
chmod +x "$F/monitor/assert-gh-wrapped.sh"
chmod +x "$F/monitor/watcher/main.sh"

# Tiny config loader. Returns deterministic values for keys we
# care about; defaults for everything else.
cat > "$F/config/load.sh" <<'CFG'
#!/usr/bin/env bash
key="$1"; default="${2:-}"
case "$key" in
    nexus.root)                              echo "$NEXUS_ROOT_OVERRIDE" ;;
    monitor.interval_seconds)                echo "2" ;;
    monitor.target_window)                   echo "orchestrator" ;;
    monitor.diff_retention_days)             echo "7" ;;
    monitor.agent_dead_threshold)            echo "999" ;;
    monitor.agent_missing_respawn_delay)     echo "0" ;;
    monitor.respawn_loop_window_seconds)     echo "120" ;;
    monitor.respawn_loop_limit)              echo "3" ;;
    monitor.watcher.auto_unstick)            echo "false" ;;
    monitor.watcher.ratelimit_probe)         echo "false" ;;
    github.repo)                             echo "your-org/test-fixture" ;;
    github.user_login)                       echo "test-user" ;;
    *)                                       echo "$default" ;;
esac
CFG
chmod +x "$F/config/load.sh"
export NEXUS_ROOT_OVERRIDE="$F"

# Stub claude that exits non-zero immediately. Without remain-on-exit
# the tmux window dies on exit → next watcher cycle sees it absent
# → respawn fires → stub crashes again → loop. After 3 within 120 s,
# the guard should trip.
cat > "$F/.bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo "[stub-claude crashed at $(date -Is)]" >> "$NEXUS_ROOT_OVERRIDE/claude-crashes.log"
exit 1
CLAUDE
chmod +x "$F/.bin/claude"
echo "(stub claude exits 1 immediately)"

# ── The stub must be the binary the watcher ACTUALLY resolves ────────────────
# your-org/nexus-code#746. Putting `$F/.bin` first on PATH does NOT make the
# stub win. `monitor/locals-env.sh` RE-FRONTS `$NEXUS_LOCALS/bin` ahead of
# whatever the caller prepended, and on an operator box it is reached by every
# non-interactive bash via `BASH_ENV=<nexus>/monitor/shellenv/bash_env.sh` — so
# `command -v claude` inside the watcher returns the REAL binary and this test
# spawns a live Claude Code session into its own fixture, which then sits there
# receiving pasted orchestrator prompts. MEASURED on this repo's own host:
# with the primary's NEXUS_LOCALS exported, a stub first on PATH still loses.
#
# CI is immune only because tests-slow-integration.yml invokes the band under
# `env -u NEXUS_ROOT -u NEXUS_LOCALS`; the documented local invocation
# (`SLOW_TESTS=1 ./monitor/watcher/test-respawn-loop-integration.sh`) is not.
# Three #741 baselines were taken this way and had to be discarded.
#
# Assert the PROPERTY (what does CLAUDE_BIN resolve to?) rather than any one
# cause of drift. A preset `CLAUDE_BIN` in the operator's environment short-
# circuits monitor/_claude-bin.sh entirely and never touches PATH at all; a
# PATH-shaped check would sail past it. Probing through `bash -c` is deliberate
# — that is what re-triggers BASH_ENV, so the probe sees the same environment
# the watcher will.
# Shared, so the next fixture that stubs `claude` gets this in one line rather
# than re-deriving it — a rule applied only at the site that reported it is not
# applied. Full rationale and coverage boundary live on the helper.
th_require_stub_claude "$F" "$F/.bin"
echo "(CLAUDE_BIN resolves to the fixture stub — verified, #746)"

SESSION="nexus-respawn-test-$$"
# Use a dedicated tmux server to fully isolate from the live nexus
# tmux AND from concurrent runs of this test. `-L <name>` sockets
# always live under /tmp/tmux-$UID/ regardless of cwd, so the name
# itself must be unique per run: a fixed name ("tmux-sock") meant two
# gates running on the same box shared ONE server, and the first
# test's `kill-server` cleanup killed the other's in-flight session
# ("can't find session nexus-respawn-test-NNN" / "no server running").
SOCK_NAME="nexus-respawn-integ-$$"
TMUX_BIN_WRAPPER="$F/.bin/tmux"
mkdir -p "$F/.bin"
# Hermetic fixture config. Without it tmux builds every pane from the
# invoking user's LOGIN shell: on the sandbox hosts that rc chain (Lmod/lua,
# conda, linuxbrew) both delays the pane ~6 s under load AND reliably
# segfaults tmux 2.6 — the server died between `list-windows` and the very
# next `send-keys`, and `set -e` turned that into a bare "lost server" with
# no diagnosis (your-org/nexus-code#555). See th_tmux_fixture_conf.
th_tmux_fixture_conf "$F/tmux.conf"
cat > "$TMUX_BIN_WRAPPER" <<TMUXWRAP
#!/usr/bin/env bash
exec $(command -v tmux) -L "$SOCK_NAME" -f "$F/tmux.conf" "\$@"
TMUXWRAP
chmod +x "$TMUX_BIN_WRAPPER"

# The fixture server dying is an ENVIRONMENT failure, not a product failure —
# say so, loudly and by name, instead of letting `set -e` abort on a client's
# "lost server".
require_server() {
    "$TMUX_BIN_WRAPPER" list-sessions >/dev/null 2>&1 && return 0
    echo "ENV-FAIL: fixture tmux server died before '$1'" >&2
    echo "  socket: $SOCK_NAME  (tmux $(tmux -V 2>/dev/null))" >&2
    echo "  check 'dmesg | grep tmux' for a server segfault." >&2
    exit 1
}
# The fixture watcher keeps running inside the private server if this
# test dies mid-flight (set -e, runner timeout); EXIT-trap the server
# teardown so no orphan main.sh loop outlives the test.
# Pin -L "$SOCK_NAME" DIRECTLY rather than going through $TMUX_BIN_WRAPPER.
# The wrapper is a file this test wrote; if it is missing, unwritable, or the
# variable is empty when the trap fires, a wrapper-routed teardown degrades to
# an unscoped call — and `$TMUX` (set for every agent, which runs in a pane)
# beats TMUX_TMPDIR, so the kill lands on the live nexus server and tears down
# the whole sandbox (your-org/nexus-code#644). -L needs no file to exist and
# is provable from this line alone.
trap 'tmux -L "$SOCK_NAME" kill-server 2>/dev/null || true' EXIT
# Bring up the dedicated server. -L isolates its socket from the
# live nexus tmux. Set PATH and NEXUS_ROOT globally on this private
# server so every new window picks them up. Safe because -g here
# scopes to OUR socket only — the live nexus server is unaffected.
"$TMUX_BIN_WRAPPER" new-session -d -s "$SESSION" -c "$F"
require_server "setenv"
"$TMUX_BIN_WRAPPER" setenv -g PATH "$F/.bin:$PATH"
"$TMUX_BIN_WRAPPER" setenv -g NEXUS_ROOT "$F"

# Run main.sh in a fresh window of the test session. Use a wrapper
# that sets fast interval + the override path and tees stderr.
cat > "$F/run-watcher.sh" <<RUN
#!/usr/bin/env bash
# Stub claude is FIRST on PATH; our tmux wrapper too so main.sh's
# tmux invocations route to the dedicated socket.
export PATH="$F/.bin:\$PATH"
export NEXUS_ROOT_OVERRIDE="$F"
export NEXUS_ROOT="$F"
export MONITOR_INTERVAL=2
export AGENT_MISSING_RESPAWN_DELAY=0
cd "$F"
bash "$F/monitor/watcher/main.sh" --target orchestrator > "$F/watcher-stderr.log" 2>&1
RUN
chmod +x "$F/run-watcher.sh"

# Wrap tmux so the watcher inside also sees the dedicated socket.
# The wrapper is FIRST on PATH so `tmux ...` from main.sh routes here.
require_server "list-windows"
first_win=$("$TMUX_BIN_WRAPPER" list-windows -t "$SESSION" -F '#{window_index}' | head -1)
"$TMUX_BIN_WRAPPER" send-keys -t "${SESSION}:${first_win}" "$F/run-watcher.sh" Enter
require_server "send-keys"

# Wait for the guard to trip — at 2 s interval, 3 respawns + cooldown
# should happen within ~15-20 s. Poll up to 60 s.
# 60 s base, SCALED via th_deadline. Until your-org/nexus-code#752 this was a
# bare `+ 60`, which means the band-wide `NEXUS_TEST_DEADLINE_SCALE=2` that #749
# introduced had NO EFFECT ON THIS TEST — the helper it scales was never called
# here. #752 hypothesised that #749's scaling "may well cover this too"; it
# cannot, and that is measurable from this line rather than arguable.
#
# Note this is a DIFFERENT inertness from the one #751 lints for. #751 catches a
# WORKFLOW invoking run-tests.sh with jobs=1, so the scale computes to 1. This
# was a TEST that never consulted the scale at all — invisible to that lint, and
# to the `deadline-scale=` line #749 added to run-tests.sh's header, since both
# report the scale rather than who honours it.
deadline_window=$(th_deadline 60)
deadline=$(( $(date +%s) + deadline_window ))
state="$F/monitor/.state"
tripped=""
while (( $(date +%s) < deadline )); do
    if [[ -f "$state/respawn-guard-tripped" ]]; then
        tripped=$(cat "$state/respawn-guard-tripped")
        break
    fi
    sleep 1
done

echo "===== nexus-respawn-test session windows ====="
"$TMUX_BIN_WRAPPER" list-windows -t "$SESSION" -F '#{window_index}: #{window_name}'

echo "===== state dir ====="
ls -la "$state" 2>/dev/null || echo "(state dir missing)"

echo "===== respawn-history.txt ====="
cat "$state/respawn-history.txt" 2>/dev/null || echo "(no history)"

echo "===== respawn-guard-tripped ====="
cat "$state/respawn-guard-tripped" 2>/dev/null || echo "(NOT tripped — test FAILED)"

echo "===== watcher-stderr.log (tail 40) ====="
tail -40 "$F/watcher-stderr.log" 2>/dev/null || echo "(no log)"

echo "===== claude-crashes.log ====="
cat "$F/claude-crashes.log" 2>/dev/null || echo "(no crash log)"

# Cleanup. The private tmux server dies via the EXIT trap. Never
# glob-delete /tmp/nexus-orch-* here: this test never created those
# files (pre-#248 entry.sh did), so the old `rm -f
# /tmp/nexus-orch-launch-*` was deleting a concurrently-running
# test-entry.sh's fixtures — or, worse, a LIVE orchestrator launch
# file mid-respawn.

if [[ -n "$tripped" ]]; then
    echo
    # Regression guard for the vacuous-green class: the guard must trip
    # because the STUB CRASHED, not because the respawn helper failed to
    # start it.
    #
    # This message used to assert a CAUSE — "check that every file _respawn.sh
    # sources is copied into the fixture" — from evidence that only ever
    # established a SYMPTOM. Fixture copy-list drift is one cause, and a real
    # one this file has had three times (#555, #589, #737), which is exactly
    # what made the wrong attribution so costly: a reader who trusts it goes
    # and audits the copy list, i.e. the one place the problem is not. That
    # happened on #746, where the true cause was CLAUDE_BIN resolving to the
    # operator's real binary. State what was OBSERVED, then rank the causes as
    # candidates, and let the reader adjudicate.
    if [[ ! -s "$F/claude-crashes.log" ]]; then
        echo "FAIL: the crash-loop guard tripped, but the stub claude never ran." >&2
        echo >&2
        echo "  OBSERVED: respawn-guard-tripped exists; $F/claude-crashes.log is empty." >&2
        echo "  MEANS:    the guard tripped on repeated helper FAILURES, not on the" >&2
        echo "            crash loop this test claims to exercise. The green is vacuous." >&2
        echo "  NOT YET ESTABLISHED: which of these caused it. In rough order of" >&2
        echo "  historical frequency in this file:" >&2
        echo "    1. Fixture copy-list drift — a file _respawn.sh sources or reads is" >&2
        echo "       missing from the fixture, so the helper aborts before spawning." >&2
        echo "       (#555 _claude-bin.sh, #589 guard-block.sh.in, #737 _tmux-window.sh" >&2
        echo "       + _channel_lib.sh.) Compare the copy block at the top of this file" >&2
        echo "       against _respawn.sh's sources and reads." >&2
        echo "    2. The emitted launcher fails its own shim precondition and refuses." >&2
        echo "    3. The spawned window dies before the stub is reached." >&2
        echo "  RULED OUT by fixture setup: CLAUDE_BIN pointing at a non-stub binary" >&2
        echo "  (#746) — that is asserted before the watcher starts." >&2
        echo "  Read $F/watcher-stderr.log; the helper's own refusal is logged there." >&2
        exit 1
    fi
    echo "PASS: guard tripped at $tripped (stub claude crashed $(wc -l < "$F/claude-crashes.log")x)"
    exit 0
fi
echo
# `>&2`, matching every other failure announcement in this file. This is the
# line that produced your-org/nexus-code#752's bare `rc=1`: run-tests.sh tailed
# `.err` to build the band summary, this suite's `.err` was 0 bytes, and a
# blocking-band red named no assertion for a day. run-tests.sh now falls back to
# stdout so no suite can be silent that way again (#752) — this redirect is
# belt-and-braces, not the fix.
echo "FAIL: guard did not trip within deadline (${deadline_window}s)" >&2
exit 1
