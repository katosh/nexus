#!/usr/bin/env bash
# monitor/cc-harness/demo.sh — human-facing live demo of the real-binary
# + mock-backend harness. Boots the REAL `claude` against the auth-free
# mock (mock-backend.py) in a tmux session you can attach to and
# interact with: a real text round-trip, then an AskUserQuestion
# selection overlay you can actually pick from with the arrow keys.
#
# Two placement modes:
#
#   (default) Isolated on its OWN tmux socket (`-L ccdemo`) so the live
#   nexus watcher never sees the window. Good for CI/automation. Reaching
#   it from an attached default-socket client means nesting tmux, though —
#   which is why a human watching from their own session wants --here.
#
#   --here    Runs on the DEFAULT tmux socket in a SEPARATE SESSION
#   (default `cc-demo`). This is ALSO watcher-safe — and that is the
#   load-bearing fact a future reader must not "fix" away: the watcher
#   enumerates windows SESSION-SCOPED, never with `-a`
#   (see monitor/watcher/main.sh:599 and :989, `tmux list-windows -F …`
#   with no `-a`; same in _lib.sh). The watcher lives in session `0`, so
#   it only ever sees session `0`'s windows. A demo in a DIFFERENT session
#   on the same socket is therefore as invisible to the watcher as a
#   separate socket is — AND the operator can reach it with
#   `tmux switch-client` (no nesting, no detach). So: do NOT move --here
#   back onto a dedicated socket out of caution; that would only re-break
#   reachability without improving watcher isolation.
#
# Usage:
#   monitor/cc-harness/demo.sh            # boot on -L ccdemo (separate socket)
#   monitor/cc-harness/demo.sh --here     # boot in a separate session on the default socket
#   monitor/cc-harness/demo.sh --stop     # tear the -L ccdemo demo down
#   monitor/cc-harness/demo.sh --here --stop  # tear the default-socket session down
#
# Env:
#   DEMO_SOCKET   tmux -L socket name (default ccdemo; ignored under --here)
#   DEMO_SESSION  tmux session name   (default cc-demo)
#   CLAUDE_BIN    override the claude binary (else project-local install)

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_self_dir/../.." && pwd)
DEMO_SOCKET="${DEMO_SOCKET:-ccdemo}"
DEMO_SESSION="${DEMO_SESSION:-cc-demo}"
STATE_ROOT="${TMPDIR:-/tmp}/cc-harness-demo"
MOCK_PY="$_self_dir/mock-backend.py"

# trash_path: rename-aside instead of unlink when resetting demo state, so a
# still-releasing claude over NFS can't make the reset fail with `.nfs`.
# shellcheck source=../_trash.sh
. "$REPO_ROOT/monitor/_trash.sh"
reset_state_root() {
    [[ -e "$STATE_ROOT" ]] || return 0
    trash_path "$STATE_ROOT" >/dev/null 2>&1 || rm -rf "$STATE_ROOT" 2>/dev/null || true
}

# Parse flags (order-independent): --here picks the default-socket /
# separate-session placement; --stop tears down whichever mode is selected.
HERE=""; STOP=""
for arg in "$@"; do
    case "$arg" in
        --here) HERE=1 ;;
        --stop) STOP=1 ;;
        *) echo "demo.sh: unknown arg '$arg'" >&2; exit 2 ;;
    esac
done

_real_tmux() { type -P tmux 2>/dev/null || echo /usr/bin/tmux; }
# Socket args: empty under --here (default socket), -L ccdemo otherwise.
if [[ -n "$HERE" ]]; then SOCKET_ARGS=(); else SOCKET_ARGS=(-L "$DEMO_SOCKET"); fi
dtmux() { "$(_real_tmux)" "${SOCKET_ARGS[@]}" "$@"; }
_python() { command -v python3 2>/dev/null || command -v python; }
WIN=0  # re-resolved from the live session after new-session (see below)

resolve_claude() {
    if [[ -n "${CLAUDE_BIN:-}" && -x "${CLAUDE_BIN:-}" ]]; then printf '%s' "$CLAUDE_BIN"; return; fi
    local b="$REPO_ROOT/node_modules/.bin/claude"
    [[ -x "$b" ]] && { printf '%s' "$b"; return; }
    echo "demo.sh: no claude binary (run monitor/install-claude-local.sh or set CLAUDE_BIN)" >&2
    return 1
}

stop_demo() {
    if [[ -n "$HERE" ]]; then
        # DEFAULT socket: kill ONLY our session — never kill-server, which
        # would take down the operator's whole tmux (session 0 included).
        dtmux kill-session -t "$DEMO_SESSION" 2>/dev/null \
            && echo "killed session $DEMO_SESSION (default socket)" \
            || echo "no session $DEMO_SESSION on default socket"
    else
        dtmux kill-server 2>/dev/null && echo "killed tmux server (-L $DEMO_SOCKET)" || echo "no tmux server on -L $DEMO_SOCKET"
    fi
    if [[ -f "$STATE_ROOT/mock.pid" ]]; then
        kill "$(cat "$STATE_ROOT/mock.pid")" 2>/dev/null && echo "stopped mock backend"
    fi
    reset_state_root
    echo "demo torn down."
}

control() { printf '%s\n' "$1" > "$STATE_ROOT/control.json"; }

state_of() {
    PATH="$STATE_ROOT/.bin:$PATH" "$REPO_ROOT/monitor/pane-state.sh" "$DEMO_SESSION:$WIN" 2>/dev/null \
        | sed -n 's/.*state=\([^ ]*\).*/\1/p'
}

wait_state() {
    local want="$1" max="${2:-40}" i
    for ((i=0; i<max*2; i++)); do
        [[ "$(state_of)" == "$want" ]] && return 0
        sleep 0.5
    done
    return 1
}

if [[ -n "$STOP" ]]; then stop_demo; exit 0; fi

CLAUDE_BIN=$(resolve_claude) || exit 1
PY=$(_python) || { echo "no python3" >&2; exit 1; }

# Fresh state. Under --here, replace just our session (NOT kill-server,
# which would nuke the operator's whole default-socket tmux).
if [[ -n "$HERE" ]]; then
    dtmux kill-session -t "$DEMO_SESSION" 2>/dev/null
else
    dtmux kill-server 2>/dev/null
fi
[[ -f "$STATE_ROOT/mock.pid" ]] && kill "$(cat "$STATE_ROOT/mock.pid")" 2>/dev/null
reset_state_root
CFG="$STATE_ROOT/cfg"; WORKDIR="$STATE_ROOT/proj"
mkdir -p "$CFG" "$WORKDIR" "$STATE_ROOT/.bin"

# Pre-seed config: skip theme picker + per-project trust dialog.
jq -n --arg wd "$WORKDIR" '{
    theme:"dark", hasCompletedOnboarding:true, bypassPermissionsModeAccepted:true,
    projects: { ($wd): {hasTrustDialogAccepted:true, hasCompletedProjectOnboarding:true, allowedTools:[]} }
}' > "$CFG/.claude.json"

# Default first-turn response.
control '{"mode":"text","drip_ms":120,"text":"Hi! I am the mock model running locally with no auth or network. This whole conversation is canned. Ask me anything."}'

# Start mock on an ephemeral port.
MOCK_DIR="$STATE_ROOT" MOCK_LOG="$STATE_ROOT/requests.log" \
  MOCK_CONTROL="$STATE_ROOT/control.json" MOCK_PORT_FILE="$STATE_ROOT/mock.port" \
  "$PY" "$MOCK_PY" 0 >"$STATE_ROOT/mock.stderr" 2>&1 &
echo $! > "$STATE_ROOT/mock.pid"
for ((i=0;i<50;i++)); do [[ -s "$STATE_ROOT/mock.port" ]] && break; sleep 0.1; done
PORT=$(cat "$STATE_ROOT/mock.port" 2>/dev/null)
[[ -n "$PORT" ]] || { echo "mock failed to start" >&2; cat "$STATE_ROOT/mock.stderr"; exit 1; }
echo "mock backend up on 127.0.0.1:$PORT (no auth, no egress)"

# PATH-shadow tmux so pane-state.sh hits our socket. Under --here the demo
# lives on the default socket, so the shadow forwards verbatim (no -L).
if [[ -n "$HERE" ]]; then
    printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$(_real_tmux)" > "$STATE_ROOT/.bin/tmux"
else
    printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$(_real_tmux)" "$DEMO_SOCKET" > "$STATE_ROOT/.bin/tmux"
fi
chmod +x "$STATE_ROOT/.bin/tmux"

# Boot the real claude TUI against the mock.
printf -v LAUNCH 'env -i HOME=%q PATH=%q CLAUDE_CONFIG_DIR=%q \
ANTHROPIC_BASE_URL=%q ANTHROPIC_AUTH_TOKEN=mock-token \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 \
DISABLE_ERROR_REPORTING=1 DISABLE_BUG_COMMAND=1 TERM=%q %q --dangerously-skip-permissions' \
    "$CFG" "$PATH" "$CFG" "http://127.0.0.1:$PORT" "${TERM:-xterm-256color}" "$CLAUDE_BIN"

dtmux -f /dev/null new-session -d -s "$DEMO_SESSION" -x 150 -y 45 -c "$WORKDIR" "$LAUNCH"
# Resolve the real window index. The -f /dev/null base-index-0 trick only
# applies when *starting* a server; under --here the operator's default
# server is already up, so query the live session instead of assuming 0.
WIN=$(dtmux list-windows -t "$DEMO_SESSION" -F '#{window_index}' 2>/dev/null | head -1)
WIN="${WIN:-0}"
echo -n "booting real claude TUI ($("$CLAUDE_BIN" --version 2>/dev/null))... "
if wait_state idle 40; then echo "idle, ready."; else echo "did not reach idle (state=$(state_of))"; fi

# --- Turn 1: a real text round-trip ---
echo "driving turn 1 (text round-trip)..."
dtmux send-keys -t "$DEMO_SESSION:$WIN" "What are you?"; sleep 0.4
dtmux send-keys -t "$DEMO_SESSION:$WIN" Enter
wait_state idle 30 || true

# --- Turn 2: leave it at an AskUserQuestion selection overlay ---
echo "driving turn 2 (AskUserQuestion selection overlay)..."
control '{"mode":"tool_use","tool":{"name":"AskUserQuestion","input":{"questions":[{"question":"Which color should the demo use?","header":"Color","multiSelect":false,"options":[{"label":"Blue","description":"Calm and classic"},{"label":"Green","description":"Fresh and natural"},{"label":"Red","description":"Bold and energetic"}]}]}}}'
dtmux send-keys -t "$DEMO_SESSION:$WIN" "Ask me which color to use."; sleep 0.4
dtmux send-keys -t "$DEMO_SESSION:$WIN" Enter
sleep 4
echo "pane-state now: $(PATH="$STATE_ROOT/.bin:$PATH" "$REPO_ROOT/monitor/pane-state.sh" "$DEMO_SESSION:$WIN" 2>/dev/null)"

if [[ -n "$HERE" ]]; then
cat <<EOF

============================================================
  Live demo ready in a separate session on YOUR tmux socket.
  View it without detaching your current session:

      tmux switch-client -t $DEMO_SESSION

  (or prefix+s, then pick "$DEMO_SESSION" from the session list)

  You should see a "Which color should the demo use?" menu —
  use ↑/↓ and Enter to pick.

  Return to your work:
      tmux switch-client -t 0          (or prefix+s)

  This is the REAL claude binary; the "model" is the local
  mock (127.0.0.1:$PORT) — no Anthropic auth, no network.

  Tear down when done:
      monitor/cc-harness/demo.sh --here --stop
============================================================
EOF
else
cat <<EOF

============================================================
  Live demo ready. Attach and interact:

      tmux -L $DEMO_SOCKET attach -t $DEMO_SESSION

  You should see a "Which color should the demo use?" menu —
  use ↑/↓ and Enter to pick. (Detach with Ctrl-b d.)

  This is the REAL claude binary; the "model" is the local
  mock (127.0.0.1:$PORT) — no Anthropic auth, no network.

  Tear down when done:
      monitor/cc-harness/demo.sh --stop
============================================================
EOF
fi
