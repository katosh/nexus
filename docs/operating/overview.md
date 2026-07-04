# Operating overview

Day-to-day life with a running nexus. The control surface is GitHub; the compute is the host you started the watcher on. Most of an operator's time is spent on the phone or in a browser tab, not at the terminal.

## The mental model

Three actors, mutually aware:

- **You** post on the [Nexus overview issue](dashboard.md) (or any other open issue) using your normal GitHub account.
- **The bot** — a per-operator GitHub App installed on your asset+issue repo — reads your comment, reacts 👀, performs the work, and reacts 🚀.
- **The host process** is a tmux session pinned somewhere durable (a workstation under your desk, a cluster login node, a small VM). It runs the [watcher](watcher.md) and the orchestrator. The watcher polls GitHub and pastes new comments into the orchestrator's pane; the orchestrator decides what to do.

GitHub's mobile push channel fires when the bot reacts to or replies to your comments. The phone becomes the remote control.

## A typical session

A representative arc, lightly fictionalised, on a host that's been running for weeks.

**Morning — phone, before standup.** Open the overview issue from a push notification, glance at the dashboard body. The *Active Agents* table shows three windows still open from yesterday: one wrapped (waiting for cleanup), one in a long-running Slurm job, one idle on a stale draft PR. *Decisions Needed* is empty. Tap into the stale draft PR's tracking issue, read the worker's last report (the link comment was posted automatically on wrap-up), comment `@worker-foo: this looks ready, please open the PR`. Lock the phone.

**Five minutes later.** Push notification: the bot rocketed the comment and posted "routed to `worker-foo`". The orchestrator pasted your directive into the worker's tmux pane via [`monitor/paste-followup.sh`](spawning-workers.md#follow-up-messages). Another push a minute later — the bot says the worker is wrapping up. A third push: `worker-foo` filed its final report and the orchestrator closed the window.

**Afternoon — laptop, between meetings.** Open a fresh question on the overview issue: *"Can you start a new run of the eligibility-filter benchmark on Slurm?"* The orchestrator spawns a `bench-eligibility` worker (you see this in the dashboard's *Active Agents* on the next refresh, ~30 seconds), the worker writes the sbatch script and submits it, posts a comment with the job ID, and goes idle. Squeue notifications would normally page you when the job finishes, but the worker has already committed a `## Infrastructure Issues` note saying the squeue→complete transition isn't wired into [push notifications](notifications.md) yet — you'll see the completion on the next dashboard refresh.

**Evening — only if needed.** If something is wedged (rate-limit cascade, watcher crash-loop, bot token revoked), an emergency-tier push fires with a click-through URL to the relevant issue. Most days no such push arrives.

## When to look at tmux, when not to

The terminal is the *implementation*, not the *interface*. Operate from GitHub by default — it works from anywhere, every exchange leaves a trail on the issue, and the bot's reactions keep your phone in the loop.

That said, the tmux panes are always there, and **talking to a worker in its pane requires no tooling at all**: switch to the window and type in the Claude Code TUI like a normal chat. The watcher notices your input, marks the window [`operator-engaged`](https://github.com/<your-org>/nexus-code/blob/main/monitor/docs/agent-state-machine.md), and holds off idle nags and window cleanup while you drive. You do **not** need `paste-followup.sh`, `pane-state.sh`, or any monitor command to converse with an agent — those are the *orchestrator's* tools (it's a machine, so its pastes must be machine-stamped and its pane reads render-proof; see the [orchestrator guide](https://github.com/<your-org>/nexus-code/blob/main/monitor/docs/orchestrator-guide.md)). A human just types.

Open tmux when:

- You want a direct back-and-forth with a worker — tight iterations on work it already owns, where GitHub round-trips would be ceremony. Jump into its pane and type.
- You need to inspect a worker's pane state without waiting a cycle for the watcher (`monitor/pane-state.sh <window-index>` gives a render-proof answer; eyeballing the pane can't distinguish autosuggest ghost-text from typed input).
- A push notification told you the watcher crash-loop guard tripped and the orchestrator needs an in-person nudge.

One caution: don't type into the **orchestrator's** pane mid-cycle — the watcher's pastes land there and can interleave with your keystrokes. Worker panes are fair game.

Don't open tmux for routine status. The dashboard, the action log, and the per-issue threads carry everything a phone-driven operator needs.

## Rhythms by tier

| Cadence | What you do | Where |
|---|---|---|
| Per-comment | Read bot reactions, follow link comments, post follow-ups | Phone, issue thread |
| Per-session start | Skim the dashboard, check the *Decisions Needed* and *Active Agents* sections | Overview issue |
| Per-day | Glance at *Recently Completed* to catch up on overnight work; spot-check the action log if something looks off | Overview issue, `monitor/.state/action-log.jsonl` |
| Per-week | [Run a periodic infra-review](reports.md#the-infrastructure-issues-feedback-loop) over the `## Infrastructure Issues` sections in recent reports | Orchestrator window |
| Per-incident | Reach into tmux only when push pages | Host terminal |

## Where the rest of this section goes

- **[Dashboard](dashboard.md)** — what the overview-issue body contains and how the bot maintains it.
- **[Spawning workers](spawning-workers.md)** — how `@<window>:` directives become tmux work and how workers report back.
- **[Watcher](watcher.md)** — what the watcher polls and when it pages you.
- **[Notifications](notifications.md)** — Pushover, ntfy, email, and the trigger policy.
- **[Reports](reports.md)** — the `reports/` log, why it's append-only, and the wrap-up flow.
- **[Troubleshooting](troubleshooting.md)** — common failure modes and their fixes.
