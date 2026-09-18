#!/usr/bin/env bash
# monitor/harness/generic-tmux.sh — the TERMINAL harness adapter.
#
# Contract: skills/nexus.agent-delivery/SKILL.md §2.
#
# This adapter makes no assumption about what software runs in the pane. It
# reaches anything with a tmux pane, which is why it is the last element of
# every chain and why a chain always has a last resort. A harness that
# declares nothing at all still gets addressed through here.
#
# It does NOT read ~/.claude and must not learn to: that is the claude-code
# adapter's business (SKILL §6). The one thing it consults is the nexus's own
# heartbeat file, and only to answer "do this agent's hooks demonstrably
# work" — i.e. whether a submit-stamp receipt is available or not.
#
# Verbs:
#   transports <window>            → <name>\t<invoke>\t<receipt>\t<stamps>
#   liveness   <window> <transport> → rc 0 live | 1 PROVABLY dead | 2 unknown
#   send <window> <transport> <payload-file> <nonce> [passthrough…]

set -uo pipefail

_hdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_mon=$(cd "$_hdir/.." && pwd)

# The PRIMARY's state dir (your-org/nexus-code#1428): NEXUS_ROOT and the
# script-relative arm both go through monitor/_nexus-root.sh, which de-nests a
# secondary clone out of `<primary>/work/`. Fail-closed on a missing resolver.
_state_dir() {
    if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then printf '%s' "$NEXUS_STATE_DIR"; return 0; fi
    [[ -r "$_mon/_nexus-root.sh" ]] || { echo "generic-tmux: cannot read $_mon/_nexus-root.sh — refusing to guess a state dir (your-org/nexus-code#1428)" >&2; return 1; }
    # shellcheck source=monitor/_nexus-root.sh
    . "$_mon/_nexus-root.sh" || return 1
    local root; root=$(nexus_primary_root "${NEXUS_ROOT:-$_mon/..}") || return 1
    printf '%s/monitor/.state' "$root"
}

verb="${1:-}"; shift || true

case "$verb" in
transports)
    window="${1:-}"
    [[ -n "$window" ]] || { echo "generic-tmux: transports needs a window" >&2; exit 2; }
    # The receipt is DECLARED from what is actually available, never assumed.
    # The heartbeat is written by the same nexus-installed hook set that writes
    # the user-prompt submit-stamp (spawn-worker.sh:21), so its absence means
    # "this agent cannot produce a receipt" — which is a legal declaration, not
    # a failure (SKILL §7). Reporting `submit-stamp` here without the hooks
    # would be the exact lie this contract exists to prevent.
    if [[ -f "$(_state_dir)/heartbeat/$window.json" ]]; then
        # stamps=self: paste-followup.sh writes the ledger row itself, BEFORE
        # a byte goes out, and dies if that fails (#665). send.sh must not
        # stamp again — one send, one row.
        printf 'tmux-paste\tshell\tsubmit-stamp\tself\n'
    else
        printf 'tmux-paste\tshell\tnone\tself\n'
    fi
    ;;
liveness)
    window="${1:-}"
    [[ -n "$window" ]] || { echo "generic-tmux: liveness needs a window" >&2; exit 2; }
    # Delegate to the repo's own pane predicate rather than re-deriving it.
    # `#1017` already worked out that the risky act is PASTING, so liveness
    # must be PROVEN, and it publishes the four-way verdict this contract
    # needs. Re-implementing it here would be a second opinion that drifts.
    if [[ -r "$_mon/_pane-live.sh" ]]; then
        # shellcheck source=/dev/null
        . "$_mon/_pane-live.sh"
        _tmux_pane_is_dead "$window" >/dev/null 2>&1
        case "${NEXUS_PANE_LIVE_VERDICT:-unknown}" in
            live)          exit 0 ;;   # observed pane_dead=0
            dead|absent)   exit 1 ;;   # PROVEN unreachable — licenses a fallback
            *)             exit 2 ;;   # transient (failed fork, busy socket)
        esac
    fi
    exit 2
    ;;
send)
    window="${1:-}"; transport="${2:-}"; payload="${3:-}"; nonce="${4:-}"
    shift 4 2>/dev/null || { echo "generic-tmux: send needs <window> <transport> <payload-file> <nonce>" >&2; exit 2; }
    [[ "$transport" == "tmux-paste" ]] || { echo "generic-tmux: no such transport: $transport" >&2; exit 2; }
    [[ -r "$payload" ]] || { echo "generic-tmux: cannot read payload: $payload" >&2; exit 2; }
    # paste-followup.sh stamps the ledger ITSELF, before a byte goes out, and
    # dies if the stamp fails (#665 / SKILL §3). send.sh therefore must NOT
    # stamp for this path — two writers would put two rows in an append-only
    # ledger for one send. The nonce/transport ride into the epoch-keyed
    # sidecar through paste-followup's single sidecar writer.
    #
    # Its rc vocabulary already IS this contract's verdict vocabulary
    # (0 delivered / 3 unknown / 4 established-negative), so no remapping.
    exec "${NEXUS_PASTE_BIN:-$_mon/paste-followup.sh}" "$window" \
        --file "$payload" --nonce "$nonce" --transport "$transport" "$@"
    ;;
*)
    echo "generic-tmux: unknown verb: ${verb:-<none>} (transports|liveness|send)" >&2
    exit 2
    ;;
esac
