# nexus

**A utility for running multiple Claude Code instances in parallel and managing them as a team** — spawning new workers for specific tasks, observing their state through tmux and GitHub, routing follow-ups, and cleaning up when each one finishes.

![Nexus organigram — watcher, orchestrator, and workers cooperating in one tmux session; the operator reads and replies through GitHub issues](assets/organigram-v5.jpg)

Three things nexus is designed to give you:

- **Minimal distraction for workers.** A worker sees its task, the safety floor, and a brief project preamble — nothing about the broader orchestration. Failures stay contained to a single tmux window and don't propagate to siblings.
- **Long, complex, multi-step tasks.** Workers can do research, download data, write code, run tests, execute long-running analyses, and produce reports, notebooks, plots, or PDFs — over hours or days. The orchestrator-watcher loop keeps them on track without micromanaging.
- **GitHub as the communications hub.** Workers and the orchestrator post on GitHub issues and PRs; the operator reads and replies there. No bespoke UI to learn; mobile push notifications fire on every state change.

!!! warning "Containment required"
    Nexus launches each worker as `claude --dangerously-skip-permissions`,
    so workers can run shell commands without per-action confirmation.
    Run nexus **only** inside [agent-sandbox](https://github.com/katosh/agent_sandbox)
    (recommended), a VM, or another containment layer that constrains
    what the worker can read, write, and execute. Do not run on a
    development laptop without containment.

!!! warning "Pre-release"
    nexus-code is under active development. Public surfaces (the `ng`
    CLI, `config/nexus.yml` schema, watcher emit shapes) are still
    settling and may change between versions until the first tagged
    release. Treat this site as the source of truth; older `README`s
    and inline comments may lag.

## Public/private split

- **`<your-org>/nexus-code`** — this repo, soon public. The code: watcher, orchestrator launch prompt, `ng` CLI, skills, this docs site.
- **Your asset+issue repo** — private, one per operator. The live state: issue threads, dashboard, uploaded reports, embedded images.

The code is shared. The state is yours. Nexus instances are designed for a single operator; team collaboration is informal — operators run their own nexuses and coordinate through GitHub or shared write directories. See [Admin → Repos § Collaboration patterns](admin/repos.md#collaboration-patterns).

## Quick start

The recommended install is Claude-Code-driven: launch the bootstrap in agent-sandbox and answer its questions.

```bash
git clone https://github.com/<your-org>/nexus-code.git && cd nexus-code
agent-sandbox tmux new-session ./monitor/bootstrap-install.sh
# Claude Code walks you through asset-repo creation, the GitHub App,
# the webhook, config/nexus.yml, and the smoke tests. When done:
agent-sandbox tmux new-session ./watcher
```

The detailed path — including a fully manual fallback — is [Install](getting-started/install.md). The first session, what you see in tmux, what appears on GitHub, is [First run](getting-started/first-run.md).

## Where to go from here

- **[Getting started](getting-started/overview.md)** — what nexus is, who it's for, the prerequisites, install, your first session, the vocabulary.
- **[Operating](operating/overview.md)** — day-to-day operator playbook: dashboard, workers, watcher, notifications, reports, troubleshooting.
- **[Admin](admin/github-app.md)** — GitHub App creation, repo topology, security tiers, runtime monitoring.
- **[Reference](reference/architecture.md)** — architecture, every config key, every `ng` verb, the watcher protocol, skills catalog, file layout.
- **[Contributing](contributing/development.md)** — local dev, the test suite, adding a skill, release flow.
- **[GitHub](https://github.com/<your-org>/nexus-code)** — source, issues, releases.
