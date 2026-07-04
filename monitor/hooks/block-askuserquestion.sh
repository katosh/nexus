#!/usr/bin/env bash
# Wired as a Claude Code `PreToolUse` matcher (`AskUserQuestion`) in
# `monitor/orchestrator-settings.json`. Layer A1 of the dialog-guard
# safety net (see PR #TODO).
#
# Why: the nexus orchestrator is paste-driven. The watcher pastes
# events into its tmux pane as user messages; any blocking dialog
# (`AskUserQuestion`, modal chip-bar, ...) intercepts the paste and
# either corrupts dialog state or stalls the channel until manual
# intervention. The operator's verbatim constraint: "we cannot risk
# the orchestrator not being receptive for watcher prompt injections".
#
# A `PreToolUse` hook that exits 2 BLOCKS the tool call at the API
# level — the agent literally cannot invoke `AskUserQuestion`. The
# stderr message is surfaced as the tool-error result so the agent
# sees the rationale and routes the question via GitHub instead.
#
# Layer A2 (the rule in `monitor/agent-prompt.md`) documents this
# message verbatim so the two surfaces stay in sync; Layer B (watcher
# `_unstick.sh` Case D + `pane-state.sh` blocked classification) is
# the safety-net for any future tool name or modal shape that slips
# past this matcher.
#
# Exception: the install bootstrap (`monitor/bootstrap-install.sh` →
# `monitor/install-prompt.md`) is an explicitly interactive agent
# that doesn't load these settings — the rule applies to the running
# orchestrator only.

cat >&2 <<'MSG'
BLOCKED: Nexus orchestrators must not use AskUserQuestion. It opens a blocking modal that intercepts the watcher's paste channel — the surface the watcher uses to relay GitHub events (and any other queued operator input) into this session while the operator is away. The channel must stay open at all times. Ask the question as plain text in your reply and idle: if the operator is at the keyboard they answer directly in this pane, otherwise they comment on the relevant tracking issue (NOT the routing-only overview issue) and the watcher pastes the reply back. For genuinely urgent attention, use `sandbox-notify "<message>"` to wake the operator's tmux.
MSG
exit 2
