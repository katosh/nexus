#!/usr/bin/env bash
# monitor/harness/codex.sh — harness adapter for OpenAI Codex CLI workers
# (your-org/nexus-code#1640). Contract: skills/nexus.agent-delivery/SKILL.md §2.
#
# The FIRST second harness this contract has been built against, so what is
# declared here is also the contract's first external test.
#
# TRANSPORTS. One, `tmux-paste`, delegated verbatim to generic-tmux.sh, which
# runs paste-followup.sh (it stamps the ledger itself: stamps=self). Its
# receipt is `submit-stamp` whenever the window has a heartbeat, and a Codex
# worker spawned by spawn-worker.sh --harness codex has one: its hooks run
# monitor/codex-hook.sh → worker-heartbeat.sh, which writes both
# heartbeat/<window>.json and the user-prompt/<window> submit-stamp on
# UserPromptSubmit (measured on codex-cli 0.156.1, real TUI).
#
# MEASURED, AND IT MATTERS FOR THE RECEIPT: a paste steered into a BUSY Codex
# fires UserPromptSubmit when Codex consumes it, so the submit-stamp arrives
# on the queued path too — the path your-org/nexus-code#1099 found
# receipt-less for Claude Code. Codex's paste is therefore confirmable on BOTH
# the idle and the busy path; Claude's only on the idle one.
#
# NOT DECLARED, deliberately:
#   * `codex queue --thread <id> --message <t>` — a real SHELL-invocable
#     subcommand ("Queue a message for an existing session"), but it talks to
#     the shared app-server daemon, which this nexus does not run (the
#     feature `daemon_auto_start` is off, and workers are plain TUIs).
#     Unmeasured here, so undeclared: a transport nobody has watched deliver
#     would be exactly the "declared without a receipt" hole §2 exists to
#     close.
#   * a `harness-ledger` receipt from Codex's rollout JSONL. Possible (the
#     rollout records every user message) but it would be a second reader of a
#     private format; the submit-stamp already answers message-scoped enough
#     for the exclusivity rule.
#
# THIS ADAPTER NEVER READS ~/.codex, for the same reason claude-code.sh is the
# only file allowed to read ~/.claude (SKILL §6).

set -uo pipefail

_hdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_generic="$_hdir/generic-tmux.sh"

verb="${1:-}"; shift || true
case "$verb" in
    transports|liveness|send)
        exec "$_generic" "$verb" "$@"
        ;;
    *)
        echo "codex: unknown verb: ${verb:-<none>} (transports|liveness|send)" >&2
        exit 2
        ;;
esac
