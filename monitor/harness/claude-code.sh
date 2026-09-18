#!/usr/bin/env bash
# monitor/harness/claude-code.sh — harness adapter for Claude Code sessions.
#
# Contract: skills/nexus.agent-delivery/SKILL.md §2.
#
# THIS IS THE ONLY FILE IN THE CONTRACT THAT MAY READ ~/.claude. Session
# registry, socket paths, peerFeatures, transcript layout — all of it is one
# harness's implementation of a contract point, never the contract (SKILL §6).
# A reader should be able to grep the nexus for `.claude` and find it here.
#
# THE CENTRAL FACT, MEASURED (Claude Code 2.1.246, dev @ a2cefa2):
# `SendMessage` is an IN-PROCESS TOOL. `claude --help` lists agents, auth,
# auto-mode, doctor, gateway, import, install, mcp, plugin, project,
# setup-token, ultrareview, update — there is NO `send`/`message` subcommand.
# So `cc-sendmessage` is declared `invoke: agent`: `ng send` can stamp for it
# but can NEVER perform it, and it cannot participate in an automatic chain
# (the watcher is a bash process with no tools). `ng send --stamp-only` is the
# supported path — the agent stamps, then calls the tool itself.
#
# The private unix socket is deliberately NOT used as a transport: it waits
# for the client to speak first, publishes no frame format, and its constants
# are not recoverable from the 248 MB native binary. Carrying production
# instructions over a reverse-engineered private IPC would be a
# cc-version-sensitive surface of exactly the kind skills/nexus.cc-update
# polices. We use it for ONE thing only, where being wrong is safe: liveness.

set -uo pipefail

_hdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_mon=$(cd "$_hdir/.." && pwd)
_generic="$_hdir/generic-tmux.sh"

_cc_home() { printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }

# Session-registry record for a window, keyed by the session NAME, which
# #1047/#1048 pinned to the tmux WINDOW name (merged at 2d32449). That is why
# the window name is a usable address for this harness at all.
_cc_registry_for_window() {
    local window="$1" f
    for f in "$(_cc_home)"/sessions/*.json; do
        [[ -f "$f" ]] || continue          # no nullglob: unmatched glob is the literal
        NEXUS_CC_REG="$f" python3 - "$window" <<'PY' 2>/dev/null && { printf '%s' "$f"; return 0; }
import json,os,sys
try:
    d=json.load(open(os.environ["NEXUS_CC_REG"]))
except Exception:
    sys.exit(1)
sys.exit(0 if d.get("name")==sys.argv[1] else 1)
PY
    done
    return 1
}

verb="${1:-}"; shift || true

case "$verb" in
transports)
    window="${1:-}"
    [[ -n "$window" ]] || { echo "claude-code: transports needs a window" >&2; exit 2; }
    # PREFERENCE ORDER. cc-sendmessage first (it does not steal the pane's
    # input box and survives a busy peer), tmux-paste last — the terminal
    # element of every chain (SKILL §7).
    #
    # Receipt for cc-sendmessage is `submit-stamp` and NOT `harness-ledger`:
    # measured, a cross-session message carries promptSource=system and
    # isMeta=true, which paste-followup.sh:597-601 rejects twice over, so the
    # surface that file calls authoritative is unavailable to it (#1049
    # constraint 2). Declared here rather than discovered later.
    if [[ -f "${NEXUS_STATE_DIR:-${NEXUS_ROOT:+$NEXUS_ROOT/monitor/.state}}/heartbeat/$window.json" ]] \
       || [[ -f "$_mon/.state/heartbeat/$window.json" ]]; then
        # stamps=caller: nothing else will stamp for an invoke=agent transport,
        # and an unstamped agent-to-agent send is exactly #1049's hole.
        printf 'cc-sendmessage\tagent\tsubmit-stamp\tcaller\n'
    else
        printf 'cc-sendmessage\tagent\tnone\tcaller\n'
    fi
    "$_generic" transports "$window"
    ;;
liveness)
    window="${1:-}"; transport="${2:-}"
    [[ -n "$window" && -n "$transport" ]] || { echo "claude-code: liveness needs <window> <transport>" >&2; exit 2; }
    if [[ "$transport" != "cc-sendmessage" ]]; then
        "$_generic" liveness "$window" "$transport"; exit $?
    fi
    # THE ZERO-BYTE CONNECT PROBE. This is what converts `#1049`'s
    # success:true-from-a-SIGKILLed-peer from `unknown` into an ESTABLISHED
    # negative, which is the only thing that may license a fallback (SKILL §4).
    # Measured on this host: dead sessions 18555 and 35683 both give
    # ECONNREFUSED; the live session accepts. We never WRITE — a byte here
    # would be an unstamped injection into a peer, the very hole this closes.
    reg=$(_cc_registry_for_window "$window") || exit 2
    NEXUS_CC_REG="$reg" python3 - <<'PY'
import json,os,socket,sys
try:
    d=json.load(open(os.environ["NEXUS_CC_REG"]))
except Exception:
    sys.exit(2)
p=d.get("messagingSocketPath")
if not p:
    sys.exit(2)                      # no socket declared → cannot answer
pid=d.get("pid")
if isinstance(pid,int):
    try:
        os.kill(pid,0)
    except ProcessLookupError:
        sys.exit(1)                  # process gone → PROVEN unreachable
    except PermissionError:
        pass
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(3)
try:
    s.connect(p); s.close(); sys.exit(0)          # reachable
except (ConnectionRefusedError,FileNotFoundError):
    sys.exit(1)                                   # PROVEN unreachable
except Exception:
    sys.exit(2)                                   # transient → never chains
PY
    exit $?
    ;;
send)
    window="${1:-}"; transport="${2:-}"
    if [[ "$transport" == "cc-sendmessage" ]]; then
        # invoke:agent — structurally not ours to perform. Refusing LOUDLY is
        # the whole point: a silent no-op here would report a delivery that
        # never happened, which is #1049's failure mode exactly.
        echo "claude-code: cc-sendmessage is invoke=agent — no shell caller can perform it; Claude Code exposes SendMessage as an IN-PROCESS TOOL and has no send/message subcommand." >&2
        echo "claude-code: use \`ng send $window --stamp-only --transport cc-sendmessage\`, then call the SendMessage tool yourself." >&2
        exit 2
    fi
    "$_generic" send "$@"
    ;;
*)
    echo "claude-code: unknown verb: ${verb:-<none>} (transports|liveness|send)" >&2
    exit 2
    ;;
esac
