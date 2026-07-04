# Concepts

Every load-bearing term in nexus, defined once. Skim now, refer back as you read the rest of the docs.

## Three-piece system

### Orchestrator

The long-running Claude Code session in the `orchestrator` tmux window. The orchestrator is paste-driven: it reads watcher-emit reports pasted into its pane, posts reactions and replies to GitHub through the bot, maintains the dashboard issue body, and delegates real work to workers. It does **not** run code, scripts, or data analysis itself — that's a worker's job. See [Operating → Overview](../operating/overview.md).

### Watcher

The continuous bash loop, hosted as a **headless service** — setsid-detached, no tmux window; self-published pidfile at `monitor/.state/watcher.pid`, log at `monitor/.state/watcher.log`. Every `monitor.interval_seconds` (default 60) it snapshots local state (`reports/` mtimes, `tmux list-windows`, `work/*` git HEAD + dirty flag, idle worker probes) and eligible GitHub comments, then pastes a state-change report into the orchestrator's pane. It also owns spawning and reviving the orchestrator. Supervise it via the `monitor/svc.sh` cockpit or `monitor/svc.sh status|logs watcher`. Source: [`monitor/watcher/main.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/main.sh). Deep dive: [Reference → Watcher protocol](../reference/watcher-protocol.md).

### Worker

A short-lived Claude Code session in its own tmux window, spawned by the orchestrator to do one task. Workers are named for their task (e.g. `fig3-phase8`, `readme-polish`). They write structured reports to `reports/` and hand off via `monitor/ng wrap-up`. The orchestrator never does worker-shaped work in-band. See [Operating → Spawning workers](../operating/spawning-workers.md).

### Bot

The GitHub App identity. Posts the dashboard, reactions, comment replies, and uploaded-asset commits. Authenticates via `monitor/mint-token.sh`, which signs a short-lived JWT with the App's RSA key and exchanges it for a ~1-hour installation access token. The bot's account is distinct from the operator's: GitHub mutes notifications for actions taken by the recipient's own account, so the bot's writes are what wake the operator on mobile. See [Admin → GitHub App](../admin/github-app.md).

## Two repos

### Code repo

`<your-org>/nexus-code` — the canonical implementation. Watcher, orchestrator launch prompt, `ng` CLI, skills, this docs site. Shared across all operators; every adopter clones the same upstream and `git pull` for updates. No per-operator state lives here.

### Asset+issue repo (or just "asset repo")

The operator's private repo (e.g. `<your-org>/<you>-nexus-assets`). One per operator. Hosts:

- The pinned `Nexus` overview issue (the dashboard surface).
- Per-thread issues for active work, decisions, blocked items.
- The `assets/` tree on `main` — uploaded reports and embedded images pushed by `monitor/upload-asset.sh`.

The GitHub App is installed here, not on the code repo. The monitor reads and writes this repo's issues and pushes asset commits to its `main` branch. See [Admin → Repos](../admin/repos.md).

## What the watcher sees

### Emit

A single watcher report — one block of text pasted into the orchestrator's pane on one poll cycle. Archived at `monitor/.state/diffs/<ts>_<shortid>.md` for 7 days (`monitor.diff_retention_days`). Contains a state-change header, optionally a local diff (reports / tmux / git), optionally an `--- eligible github comments ---` block, optionally a `--- standing bells ---` block, and a `--- dashboard ---` last-updated reminder. See [Reference → Watcher protocol](../reference/watcher-protocol.md).

### Eligible comment

A GitHub comment surfaced by the watcher's eligibility filter — the **security boundary** of the nexus. A comment is eligible only if all three hold:

1. `author.login == github.user_login` — only the configured operator can drive the bot.
2. No `eyes` (👀) reaction from any login other than the operator — that signal means "the bot is already processing this".
3. No `rocket` (🚀) reaction from any login — that signal means "done" (bot-posted) or "skip this" (user-posted, one-tap mobile opt-out).

Implemented in `snapshot_github` (`monitor/watcher/main.sh` → `_github.sh`). Comments from any other author are silently ignored even with repo write access. See [Admin → Security](../admin/security.md).

### Idle probe

The watcher's check on every non-orchestrator tmux window for "really idle" state. A window qualifies when its **engagement-anchored** idle age (now minus the last observed `busy`/`user-typing` epoch in `monitor/.state/engagement-log.tsv` — *not* the noisy `tmux #{window_activity}`) exceeds `monitor.idle_threshold_seconds` (default 60) **and** [`monitor/pane-state.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/pane-state.sh) reports an idle-shaped state (`idle | autosuggest-only`; `absent | blocked` short-circuit to `pane-absent`). The bell flag alone isn't enough — bell clears on view, so "no bell" doesn't mean "idle". Wired in `monitor/watcher/_idle_probe.sh`. Details: [Reference → Worker states](../reference/worker-states.md).

### Classifier

The state classifier that runs on every idle-probe positive. Each idle worker is mapped to a class, and the orchestrator's response depends on the class. The most common four:

| Class | Meaning | Default orchestrator action |
|---|---|---|
| `wrapped` | A `wrap-up logged` action-log entry exists; the worker finished cleanly. | Close per [`nexus.window-cleanup`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.window-cleanup/SKILL.md) retention rules. |
| `wrapped-but-stub` | `ng report-check` rejected the report (missing sections, too short, placeholders). | Paste "finish-and-expand" template into the worker; re-check next cycle. |
| `no-wrap-up` | Idle past threshold with no wrap-up entry. | Paste "wrap-up-missing" template; re-check next cycle. |
| `idle-too-long` | Idle for ≥ `monitor.idle_close_hours` (default 24h). | Strong default-to-close; retention overrides (recent user engagement, loaded kernel cost) still apply. |

Further classes cover crashed panes (`pane-absent`), the weekly Opus limit (`over-limit`), operator-driven windows (`operator-engaged` — *you* typed into the pane, so nags and cleanup are suppressed), failed orchestrator pastes (`paste-unconfirmed`), and orphaned async work (`idle-orphan-async`). Deduped against the prior cycle's `(window, class)` set so stable workers don't re-emit. The full vocabulary is [Reference → Worker states](../reference/worker-states.md); the authoritative lifecycle diagram is [`monitor/docs/agent-state-machine.md`](https://github.com/<your-org>/nexus-code/blob/main/monitor/docs/agent-state-machine.md).

## What the orchestrator writes

### Dashboard

The bot-maintained section of the overview issue body, between the two HTML-comment markers:

```markdown
<!-- NEXUS_DASHBOARD_START -->
...rendered sections...
<!-- NEXUS_DASHBOARD_END -->
```

Sections, when populated: Decisions Needed, Active Agents, Blocked / Waiting, Recently Completed, Project Status, Next Actions. Updated via `monitor/ng dashboard put`, which re-fetches the body, splices a new middle, and PATCHes — preserving any static prose outside the markers. The overview issue itself is **routing-only**; content threads belong on dedicated per-task issues. See [Operating → Dashboard](../operating/dashboard.md).

### Wrap-up

The universal worker hand-off. `monitor/ng wrap-up <issue> <report-path>` is one verb that:

1. Uploads the report to the asset repo (`monitor/upload-asset.sh` under `assets/<issue>/`).
2. Posts a link comment on `<issue>` (templated by default; bespoke when `--comment-body-file` is supplied).
3. Rocket-reacts the trigger comment if `--trigger-comment <id>` is set.
4. Appends an action-log entry the watcher reads to close the window cleanly.

Refuses stub reports (the `report-check` pre-flight enforces a schema and a minimum `monitor.report_min_chars`, default 500). See [`skills/nexus.report/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.report/SKILL.md).

## Behaviour libraries

### Skill

A file under `skills/nexus.*/SKILL.md` carrying a piece of behaviour every agent inherits. Skills are auto-discovered by Claude Code via a `.claude/skills` symlink; worker spawn prompts also reference them by absolute path so the contract survives a `cwd` change. The skills cover the bot identity rules, the worker-spawn pattern, the report convention, the orchestrator-exclusive cleanup policy, and a handful of narrower playbooks (jupyter-as-a-service, durable cron state, private package installs, …). Catalogued in [Reference → Skills](../reference/skills.md).

## More vocabulary

A few terms that surface in deeper docs:

- **Target window** — the tmux window the watcher pastes into. Default `orchestrator` (`monitor.target_window`). Set per-launcher-invocation via `./watcher/launcher.sh --target <name>`.
- **Trigger comment** — the eligible GitHub comment that initiated a piece of work. Workers `--trigger-comment <id>` it in their `ng wrap-up` so the bot rockets the right comment at hand-off.
- **Heartbeat** — `monitor/.state/watcher-heartbeat` is touched (PID + ISO timestamp) every watcher poll. Agents read its mtime to detect a dead watcher.
- **Mutual liveness** — the contract that the orchestrator and watcher each check the other is alive. Orchestrator → watcher: `monitor/watcher/bootstrap.sh` every turn. Watcher → orchestrator: respawn after `monitor.agent_missing_respawn_delay` confirming polls of a *missing* window (plus a pre-launch re-verification), and a hook-driven liveness state machine for the window-present-but-inert case. External tie-breaker: the operator on GitHub. Full contract: [`monitor/README.md` § Mutual-liveness contract](https://github.com/<your-org>/nexus-code/blob/main/monitor/README.md#mutual-liveness-contract).
- **Operator-engaged** — the watcher's mark on a worker window the operator is driving by typing directly in its pane. While valid (it self-expires when the pane goes static), idle nags, follow-up pastes, and cleanup are suppressed — the window belongs to the human. Lifecycle: [`monitor/docs/agent-state-machine.md`](https://github.com/<your-org>/nexus-code/blob/main/monitor/docs/agent-state-machine.md).
- **Rate-limit cascade** — when the GraphQL bucket exhausts, the watcher writes a `watcher_alert=rate-limit` sentinel and the auto-unstick path (case B in `_unstick.sh`) cascades an Enter + "please continue" follow-up to every stuck agent window once the reset epoch elapses. See [Reference → Watcher protocol](../reference/watcher-protocol.md).
- **Deliveries path** — event source (gated by `monitor.deliveries.asset_enabled` / `monitor.deliveries.bot_mention_enabled`, both default on) that reads from the App's `/app/hook/deliveries` log. Complementary to the default GraphQL-search path; surfaces in-repo asset comments in ~15 s and @bot-mentions on App-installed repos.
- **Mentions path** — opt-in fallback (`monitor.mentions_enabled`) that searches for @-mentions of `github.user_login` in repos the App isn't installed on. Surfaces as read-only context (the bot can't comment back without an install).
