# Orchestrator guide — the machine's command surface

This page is for the **orchestrator agent** (and contributors editing
its behaviour). It collects the command surface the orchestrator
drives: worker spawning, stamped follow-up injection, pane reading,
window cleanup, the bot CLI, and the watcher interplay.

**Human operators need none of this.** The operator's interface is
GitHub (issues, PRs, comments — see
[`docs/operating/overview.md`](../../docs/operating/overview.md)),
and when an operator wants to talk to a worker directly they simply
switch to its tmux pane and type in the Claude Code TUI like a normal
chat. No helper script is involved: the watcher attributes unstamped
prompt submits to the operator and marks the window
`operator-engaged`, suppressing idle nags and cleanup while the
operator drives. The tooling below exists precisely because the
orchestrator is *not* a human: its inputs must be machine-stamped,
its pane reads must be render-proof, and its actions must land in the
audit log.

## The loop

The orchestrator is paste-driven. The watcher (headless service; see
[`monitor/README.md`](../README.md)) pastes a state-change emit into
the orchestrator's pane; the orchestrator's first action on every
turn is `monitor/watcher/bootstrap.sh` (heartbeat check + missed-diff
catch-up), then it processes the emit — react, reply, delegate,
clean up — and records meaningful actions via
`monitor/ng log-action`. Launch behaviour and the initial pass:
[`monitor/agent-prompt.md`](../agent-prompt.md).

## Command surface

| Tool | What it's for | Deeper doc |
|---|---|---|
| `monitor/spawn-worker.sh -n <window> -c <workdir> -p <prompt-file>` | Spawn a worker in a fresh tmux window. Injects the worker floor, logs an authoritative `spawn` event, pins the window name (`automatic-rename off`). `--resume <window>` is the canonical post-restart worker revival. | [`skills/nexus.tmux-spawn/SKILL.md`](../../skills/nexus.tmux-spawn/SKILL.md) |
| `monitor/paste-followup.sh <window> --file <path>` | **The only sanctioned way to inject a follow-up into a worker pane.** Stamps the machine-input ledger *before* pasting, then performs the VI-safe paste sequence, then appends a `paste-followup` action-log event. | Header of [`monitor/paste-followup.sh`](../paste-followup.sh); "Sending follow-up messages" in [`skills/nexus.tmux-spawn/SKILL.md`](../../skills/nexus.tmux-spawn/SKILL.md) |
| `monitor/pane-state.sh <window-index>` | Render-proof pane classification (`idle\|busy\|user-typing\|autosuggest-only\|empty\|blocked\|absent\|over-limit`). Never eyeball `tmux capture-pane` — autosuggest ghost-text is indistinguishable from typed input in plain text. | [`docs/reference/worker-states.md`](../../docs/reference/worker-states.md) |
| `monitor/ng <verb>` | Every GitHub write (bot identity), `report-init`, `report-check`, `wrap-up`, `log-action`, `watcher-status`, `dashboard put`, `engaged-done`, … | [`skills/nexus.bot/SKILL.md`](../../skills/nexus.bot/SKILL.md); [`docs/reference/ng-cli.md`](../../docs/reference/ng-cli.md) |
| Window cleanup (close / retain decisions) | Orchestrator-exclusive policy: triggers, retention overrides, pre-close checks, kill mechanism. | [`skills/nexus.window-cleanup/SKILL.md`](../../skills/nexus.window-cleanup/SKILL.md) |
| `monitor/svc.sh status\|up\|start\|stop\|restart\|logs` | Stack supervision (watcher + registry services); `bootstrap-recover.sh` for idempotent full-stack recovery. | [`monitor/README.md`](../README.md) "Starting the stack" |

## Why `paste-followup.sh`, not raw tmux

Every prompt submitted to a worker fires its `UserPromptSubmit` hook.
The watcher attributes each submit to either the **operator** (no
machine stamp → window becomes `operator-engaged`, nags and cleanup
suppressed) or the **machine** (a covering `paste-followup` stamp →
busy-regression, wrap-up supersession). An orchestrator paste sent
with raw `tmux send-keys`/`paste-buffer` carries no stamp, so it
*impersonates the operator*: the window is falsely marked
`operator-engaged` and its stall-nag is muted for up to a day.
`paste-followup.sh` stamps first (a paste can never outrun its
stamp), pastes VI-safely, and logs the event. The injection↔hook
pairing is also validated in the other direction: a stamped paste
that never fires the hook surfaces as `paste-unconfirmed` — re-paste
via `paste-followup.sh`.

A human typing in the pane needs none of this — unstamped input
attributed to the operator is exactly the intended signal.

## The lifecycle: one source of truth

Worker window states (`busy`, `no-wrap-up`, `wrapped`,
`operator-engaged`, `paste-unconfirmed`, `idle-too-long`,
`pane-absent`, `over-limit`, `idle-orphan-async`), every transition
condition with its exact threshold, and the orchestrator reaction per
state are diagrammed in
[`monitor/docs/agent-state-machine.md`](agent-state-machine.md) —
link there rather than restating thresholds. The close/retain policy
keyed off those states is
[`skills/nexus.window-cleanup/SKILL.md`](../../skills/nexus.window-cleanup/SKILL.md).

## Delegation discipline

The orchestrator coordinates; it does not do worker-shaped work. If
the action would land in a worker's "What Was Done" section, it runs
in a worker's window via `spawn-worker.sh`. Read-only orchestration
(`tmux list-windows`, `head -7 reports/*.md`, dashboard pushes,
bootstrap) stays in-orchestrator. Rationale and the full rule:
"Monitor agent scope" in [`monitor/README.md`](../README.md).
