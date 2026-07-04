#!/usr/bin/env bash
# Respawn recovery prompts — the two turn-1 prompt bodies
# `respawn_agent` (main.sh) pastes into a freshly respawned
# orchestrator window. Extracted from the two inline heredocs in
# main.sh (your-org/your-nexus#180 seam S4); the heredoc bodies are
# verbatim, now wrapped in render functions so the prompt text is
# editable without touching respawn_agent's control flow.
#
# your-org/your-nexus#238: both prompts now carry an explicit
# "(re-)arm the watcher-supervisor Monitor as your FIRST post-validation
# action" step, with the exact Monitor command passed in by respawn_agent
# (computed via _supervisor_monitor_command). The in-process supervisor
# Monitor dies with the old orchestrator process, so a respawn is exactly
# the moment it must be re-armed; injecting it into the turn-1 prompt
# closes the post-respawn gap DETERMINISTICALLY (no waiting on a
# heartbeat-staleness threshold or a signal-driven emit). Placed in the
# "watcher was right" branch — never before the false-positive stand-down,
# so a duplicate orchestrator never arms a SECOND supervisor before
# standing down (mutual-liveness invariant: exactly one supervisor).
#
# Two flavours, keyed on respawn_agent's $resume_mode:
#   _respawn_render_prompt_resume — the agent already has its prior
#       context (claude --resume <pinned-sid>); the prompt explains
#       the respawn and asks it to validate the call before resuming.
#   _respawn_render_prompt_fresh  — the agent has NO prior context
#       (pin missing/stale -> deliberate cold spawn, issue #200); the
#       prompt says so plainly and points at CLAUDE.md /
#       agent-prompt.md for re-onboarding.
#
# Both print to stdout; the caller redirects into its prompt tempfile.
# Side-effect-free: only function definitions, no top-level state.

# Args: $1 target window name, $2 watcher-recorded reason,
#       $3 resume command label (e.g. "claude --resume <sid>"),
#       $4 supervisor-arm Monitor command (from _supervisor_monitor_command;
#          issue #238 — re-arm step injected into the "watcher was right" branch)
_respawn_render_prompt_resume() {
    local target="$1" reason="$2" resume_cmd_label="$3" sup_cmd="${4:-}"
    cat <<PROMPT
The nexus watcher respawned your orchestrator window. It detected no
live monitoring agent in this tmux window for several consecutive
poll cycles, then created a new window and resumed your prior session
via \`${resume_cmd_label}\`.

Reason recorded by the watcher: ${reason}

Before resuming routine work:

1. Validate that the watcher was right to respawn you. Cross-check with
   \`tmux list-windows\`, the workspace CLAUDE.md, and \`monitor/.state/last-ack.txt\` mtime.
   If a separate live monitoring agent exists elsewhere that the watcher
   missed, this respawn was a FALSE POSITIVE and YOU are the duplicate.
   Stand down using EXACTLY this protocol:
   - NEVER kill the watcher, the tmux session, or any window other than
     your own. The watcher is the workspace's only autonomous recovery
     mechanism; killing it leaves the workspace unmonitored (this exact
     mistake caused the 2026-06-02 watcher-death incident).
   - Make sure the original agent owns the watcher's target window name:
     find its window id via \`tmux list-panes -a -F '#{window_id} #{window_name} #{pane_pid}'\`,
     then \`tmux rename-window -t <its-window-id> '${target}'\`.
   - Record the false positive so it is auditable:
     \`monitor/ng log-action watcher --event respawn-false-positive --note "<what you found>"\`
     and post a short comment on the Nexus overview issue.
   - Then remove ONLY your own window: rename it first
     (\`tmux rename-window -t <your-own-window-id> duplicate-standdown\`),
     then \`tmux kill-window -t <your-own-window-id>\`. Use window IDs
     (\`@N\`), never names — names are ambiguous while two windows exist.

2. If the watcher was right, your FIRST action is to (re-)arm the
   watcher-supervisor Monitor. It was an in-process \`Monitor\` loop that
   died with your predecessor's process — until you re-arm it, a watcher
   CRASH has NO turn-independent revival (mutual-liveness contract). Arm it
   now, before routine work:
     ${sup_cmd}
   On its exit (watcher reported DOWN) run \`monitor/revive-watcher.sh\`,
   then re-arm; see skills/nexus.service-recovery.

3. Then continue per monitor/agent-prompt.md — your prior conversation is
   intact via \`${resume_cmd_label}\`.

Canonical invariant: exactly ONE monitoring agent tied to ONE watcher,
plus zero or more working agents in other windows. The user configured
in \`config/nexus.yml\` (\`github.user_login\`) is the external tie-breaker
on GitHub if you and the watcher disagree on the call.
PROMPT
}

# Args: $1 target window name, $2 watcher-recorded reason,
#       $3 supervisor-arm Monitor command (from _supervisor_monitor_command;
#          issue #238 — re-arm step injected into the "watcher was right" branch)
_respawn_render_prompt_fresh() {
    local target="$1" reason="$2" sup_cmd="${3:-}"
    cat <<PROMPT
The nexus watcher respawned your orchestrator window. It detected no
live monitoring agent in this tmux window for several consecutive
poll cycles, then created a new window.

This is a **fresh** spawn — you have **no resumed conversation
context**. The watcher could not positively identify your prior
session (the orchestrator session-id pin at
\`monitor/.state/orchestrator-session-id\` was missing or stale), so it
deliberately started you cold rather than resuming an unidentified
session via \`claude --continue\`. (Resuming an arbitrary
most-recent-jsonl is what resurrected a transient recovery session and
caused the 2026-05-29 crash-loop; a cold start is the safe path.)

Reason recorded by the watcher: ${reason}

Before resuming routine work:

1. Validate that the watcher was right to respawn you. Cross-check with
   \`tmux list-windows\`, the workspace CLAUDE.md, and \`monitor/.state/last-ack.txt\` mtime.
   If a separate live monitoring agent exists elsewhere that the watcher
   missed, this respawn was a FALSE POSITIVE and YOU are the duplicate.
   Stand down using EXACTLY this protocol:
   - NEVER kill the watcher, the tmux session, or any window other than
     your own. The watcher is the workspace's only autonomous recovery
     mechanism; killing it leaves the workspace unmonitored (this exact
     mistake caused the 2026-06-02 watcher-death incident).
   - Make sure the original agent owns the watcher's target window name:
     find its window id via \`tmux list-panes -a -F '#{window_id} #{window_name} #{pane_pid}'\`,
     then \`tmux rename-window -t <its-window-id> '${target}'\`.
   - Record the false positive so it is auditable:
     \`monitor/ng log-action watcher --event respawn-false-positive --note "<what you found>"\`
     and post a short comment on the Nexus overview issue.
   - Then remove ONLY your own window: rename it first
     (\`tmux rename-window -t <your-own-window-id> duplicate-standdown\`),
     then \`tmux kill-window -t <your-own-window-id>\`. Use window IDs
     (\`@N\`), never names — names are ambiguous while two windows exist.

2. If the watcher was right, your FIRST action is to (re-)arm the
   watcher-supervisor Monitor. It was an in-process \`Monitor\` loop that
   died with your predecessor's process — until you re-arm it, a watcher
   CRASH has NO turn-independent revival (mutual-liveness contract). Arm it
   now, before routine work:
     ${sup_cmd}
   On its exit (watcher reported DOWN) run \`monitor/revive-watcher.sh\`,
   then re-arm; see skills/nexus.service-recovery.

3. Re-onboard from scratch: read CLAUDE.md and \`skills/nexus.*\` for your
   role, \`monitor/agent-prompt.md\` for the wake protocol, then
   \`monitor/ng dashboard get\` for current operator-visible state. Do NOT
   assume any prior in-flight work — rediscover it from \`tmux
   list-windows\` and the most recent \`reports/\`.

Canonical invariant: exactly ONE monitoring agent tied to ONE watcher,
plus zero or more working agents in other windows. The user configured
in \`config/nexus.yml\` (\`github.user_login\`) is the external tie-breaker
on GitHub if you and the watcher disagree on the call.
PROMPT
}
