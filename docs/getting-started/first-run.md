# First run

What the first nexus session looks like end-to-end. Pick this up after [Install](install.md) reports that the bootstrap is complete and you've launched `agent-sandbox tmux new-session ./watcher` (Install § Step 3).

## What you should see in tmux

Two windows appear inside the inner agent-sandbox tmux session — and notably, **no `watcher` window**: the watcher runs headless as a service, with its log at `monitor/.state/watcher.log`.

- **`services`** — the window you launched from, now running the read-only service cockpit (`monitor/svc.sh`). It shows the watcher and orchestrator rows plus any registered services; key `0` tails the watcher log in a split.
- **`orchestrator`** — the orchestrator. A Claude Code instance spawned by the watcher with the canonical "you are the nexus monitor" launch prompt.

`tmux list-windows` from inside the inner session prints something like:

```
0: services*
2: orchestrator
```

The `*` marks the active window. Exact indices can vary — stack
recovery pins the orchestrator to the canonical slot
(`monitor.target_window_index`, default 2) when that slot is free.
Worker windows appear at other indices when the orchestrator spawns
them.

## The first watcher heartbeat

Within the configured interval (default 60s, `monitor.interval_seconds`), `monitor/ng watcher-status` from another shell should report a live heartbeat and headless hosting:

```text
heartbeat: 2026-06-09T08:46:26-07:00 (age=12s)
pid: 12345 (alive)
target: orchestrator
lock: pid=12345 started=2026-06-09T08:45:14-07:00
hosting: headless
archived_diffs: 1
```

A `heartbeat: missing` line means the watcher hasn't completed its first cycle yet. Wait one `monitor.interval_seconds` and re-check. If it stays missing, see [Operating → Troubleshooting](../operating/troubleshooting.md).

## The orchestrator's initial pass

The orchestrator's first turn — its "initial pass", documented in `monitor/agent-prompt.md` — walks through:

1. Reading `monitor/README.md` and the workspace's `CLAUDE.md`.
2. `ls reports/*.md` to survey existing reports (will be empty on a fresh install).
3. `tmux list-windows` to inventory tmux state.
4. `gh issue list --repo <your-asset-repo> --state open` via the bot identity to find your overview issue.
5. If the `nexus:overview`-labelled issue doesn't exist yet, **stops and asks you to create it** (the install bootstrap walks you through this in Phase 5; the manual fallback is [Install § M8](install.md#m8-seed-the-overview-issue)). Otherwise, splices a real dashboard into its body via `monitor/ng dashboard put`.
6. Verifies the watcher is alive via `monitor/ng watcher-status`. The watcher is already running because `./watcher` started it.
7. Ends the turn. Subsequent activity is paste-driven.

The dashboard rendered into the overview issue body sits between two markers:

```markdown
<!-- NEXUS_DASHBOARD_START -->
...sections rendered by the orchestrator...
<!-- NEXUS_DASHBOARD_END -->
```

Default sections, when there's anything to show: **Decisions Needed**, **Active Agents**, **Blocked / Waiting**, **Recently Completed**, **Project Status**, **Next Actions**. On a brand-new nexus the body looks sparse; that's expected.

## Your first comment

Open the overview issue in a browser (logged in as `github.user_login` — the only authorized directive author). Post a comment. Anything works for a first test:

```
hello nexus — please confirm you're receiving comments
```

What happens, in order:

1. Within `monitor.interval_seconds` the watcher's snapshot picks up the comment because it satisfies the eligibility filter (your login, no `eyes` from a non-you account, no `rocket` from anyone). The watcher pastes a state-change report into the `orchestrator` pane.
2. The orchestrator wakes on the paste. Its first action is `monitor/watcher/bootstrap.sh` (heartbeat sanity check + diff catch-up).
3. It calls `monitor/ng process <comment-id>` — eligibility-checked POST of an `eyes` (👀) reaction, plus a fetch of the comment body. You see the 👀 appear on your comment in the browser within seconds.
4. It decides the action — for a plain comment, post a reply via `monitor/ng reply <issue>`. For a routed directive starting with `@<window-name>:`, paste the instruction into that window.
5. It calls `monitor/ng react <comment-id> rocket` (🚀) to mark fully processed. You see the 🚀 appear.

The 👀-then-🚀 reaction sequence is your wake signal on mobile — GitHub fires a push notification for the bot's reactions, and on your phone you can tap the reply comment without ever opening the terminal.

## What the watcher actually emits

A poll-cycle report in `monitor/.state/diffs/` looks like this (real capture from the workspace, with a routine local-state diff):

```text
=== nexus state changed at 2026-05-11T08:47:38-07:00 (poll) ===
*If unsure how to proceed: see CLAUDE.md.*
--- /path/to/last-snapshot.txt   2026-05-11 08:46:26 ...
+++ /tmp/current                 2026-05-11 08:47:30 ...
@@ ...
 nexus_2026-05-11_010516_docs-coordinator.md 1778487240.275
 nexus_2026-05-11_012706_docs-scaffold.md 1778488077.704
-nexus_2026-05-11_084549_readme-polish.md 1778514349.350
+nexus_2026-05-11_084549_readme-polish.md 1778514399.588
--- dashboard ---
last updated: 2026-05-11T00:20:35-07:00
(> 2h old; refresh via `monitor/ng dashboard put`)
--- nexus-emit-sig 2026-05-11T08:47:38-07:00 91324f ---
```

When there's an eligible GitHub comment, an extra block appears:

```text
--- eligible github comments ---
issue=54 id=4366687453 author=<your-login>
  body: open an issue to demonstrate the capabilities of the metrics ...
```

Every line shape — `issue=`, `pr=`, `pr_review=`, `issue_new=` — and what the orchestrator does with each is detailed in [Reference → Watcher protocol](../reference/watcher-protocol.md).

## When to look at tmux vs GitHub

After the first session you mostly stop looking at tmux. The orchestrator's job is to coordinate; everything visible to the operator surfaces on GitHub.

**Open tmux when:**

- A worker is wedged on a permission prompt (the auto-unstick logic doesn't catch every case).
- You want to interact directly with a worker — switch to its window and **type in the Claude Code TUI like a normal chat**. No tmux or monitor commands are needed; the watcher detects your engagement and holds off idle nags and cleanup while you drive (see [Operating → Spawning workers § Follow-up messages](../operating/spawning-workers.md#follow-up-messages)). **Never** type into the `orchestrator` pane mid-cycle, though — the watcher's paste can interleave with your keystrokes.
- You're debugging the watcher itself.

**Open GitHub when:**

- Posting a directive — comment on the overview issue, a per-thread issue, or any PR.
- Reading the dashboard.
- Reviewing a bot-opened PR.

## Where to next

- [Concepts](concepts.md) — every term used elsewhere on the site, defined once.
- [Operating → Overview](../operating/overview.md) — the day-to-day playbook.
- [Operating → Spawning workers](../operating/spawning-workers.md) — how directives become work in fresh tmux windows.
- [Reference → Watcher protocol](../reference/watcher-protocol.md) — the eligibility filter, emit classes, and rate-limit cascade.
