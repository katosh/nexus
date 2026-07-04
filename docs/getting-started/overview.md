# Overview

Nexus turns a private GitHub repository into the control surface for a long-running multi-agent coding session on a Linux host. The agents run inside a tmux session under [agent-sandbox](https://github.com/katosh/agent_sandbox); the operator drives them from anywhere there's a GitHub-mobile push notification.

## The problem nexus is built for

Modern AI coding agents have become capable enough to do real, multi-hour work — but their interaction model assumes the operator is sitting in front of a terminal the whole time. That's a poor fit for:

- **Multi-day research codebases** where a single experiment, refactor, or paper-figure rebuild spans many hours of agent thinking, intermittently needs a human nudge ("skip the slow preprocessing", "use the cached embeddings"), and must survive SSH drops, browser tab closes, and operator sleep.
- **Lab- and group-scale workflows** where one person coordinates several parallel agent tasks across a shared codebase, often from a phone in between meetings.
- **Hosts with already-established constraints** — Slurm clusters, lab GPUs, paid compute — where the agent has to run where the code, data, and credentials already live.

Nexus solves the coordination layer: agents run as long-lived tmux windows on the operator's own host; a watcher loop turns local state and GitHub comments into a paste-driven event stream; a GitHub App is the bot identity that posts the dashboard, reactions, and worker hand-offs back to GitHub so the operator's phone wakes them when the agents need a decision.

## Who it's for

You're a likely fit if all of these are true:

- You're already running AI coding agents (Claude Code today; the architecture is agent-agnostic) on real, multi-step engineering work.
- You have a Linux host you can leave running indefinitely — a lab workstation, an HPC interactive node, a personal server. Nexus assumes a long-lived tmux session; ephemeral CI containers are the wrong shape.
- You have GitHub admin on a private repo and can install a GitHub App you create.
- You're comfortable editing a YAML config, generating an RSA key for a GitHub App, and running shell scripts.

You're probably not a fit if:

- You want a turnkey hosted product — nexus is code you run on your own Linux host; there is no service to sign up for.
- You want multi-user access to one bot — the eligibility filter authorizes exactly one GitHub login as the directive source; siblings ignored.
- Your security model can't tolerate `--dangerously-skip-permissions` on Claude Code, even inside agent-sandbox's bubblewrap boundary. The orchestrator is launched with that flag; the filesystem blast radius is bounded by the sandbox but network and compute side effects are not.

## Scope boundaries

A few things nexus deliberately is not, so expectations stay calibrated:

- **One operator per instance.** `github.user_login` configures the single authorized operator. The eligibility filter in [`monitor/watcher/main.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/main.sh) rejects every other author by construction, so the bot cannot be hijacked by repo collaborators leaving instructions.
- **Not a CI replacement.** Nexus is for human-supervised research and refactoring work where the agent's judgment is the point. CI is for deterministic, scripted checks; nexus is the layer above.
- **Not a security product.** agent-sandbox provides filesystem isolation, not network or compute isolation — see [Admin → Security](../admin/security.md). The bot's authorization scope is `github.user_login` only; sub-tier policies for external public repos live in [`CLAUDE.md`](https://github.com/<your-org>/nexus-code/blob/main/CLAUDE.md)'s "GitHub writes — identity and authorization" section.

## Architecture in three sentences

A **watcher** bash loop polls local state and GitHub once per cycle (default 60s, [`monitor.interval_seconds`](../reference/config.md)) and pastes a state-change report into the orchestrator's tmux pane. An **orchestrator** Claude Code session reads each report, posts 👀 / 🚀 reactions through a GitHub App **bot**, updates the pinned dashboard issue's body, and either replies in-thread or spawns a **worker** in a fresh tmux window. **Workers** do the actual code work and hand off via `monitor/ng wrap-up`, which uploads a structured report to the asset+issue repo, comments on the issue, and rockets the trigger comment.

For the full architecture diagram and the watcher's emit classifier semantics, see [Reference → Architecture](../reference/architecture.md). For the day-to-day operator playbook, see [Operating → Overview](../operating/overview.md).

## Prerequisites

You'll need the following before the [Install](install.md) walkthrough. None are unusual; most are already on a typical research host.

- **A Linux host you can leave a tmux session running on.** Persistent SSH-able machine — workstation, HPC interactive node, dev server. Walltime-limited compute (most batch queues) is the wrong shape; the orchestrator must survive hours-to-days idle.
- **[`agent-sandbox`](https://github.com/katosh/agent_sandbox).** Kernel-enforced filesystem sandbox. Installed per-user with `brew install agent-sandbox` after `brew tap katosh/tools`. Required.
- **A GitHub account with admin on a private repo.** You'll create a private repo to host issues and assets, and a GitHub App to act as the bot. Both belong to you (or your org).
- **Claude Code.** Today's reference orchestrator. The architecture is agent-agnostic but the launch prompt assumes Claude Code; other harnesses need a re-port.
- **The `gh` CLI authenticated as your GitHub user.** Used for smoke tests and the one-time asset-repo creation. The bot identity uses its own GitHub App tokens, not your `gh` auth.
- **A handful of standard shell tools** — `bash`, `tmux`, `git`, `jq`, `openssl`, `python3` with `pyyaml`, `curl`. Listed in `monitor/README.md` "Tech stack".

Optional but recommended:

- **A phone-push channel** — Pushover (preferred), ntfy (fallback), or email (emergency tier). Configured under `notifications.*` in `config/nexus.yml`. See [Operating → Notifications](../operating/notifications.md).
- **[`labsh`](https://github.com/katosh/labsh)** — project-local JupyterLab with persistent kernels. Worth installing if any of your projects load slow-to-build state (large DataFrames, fitted models) that agents would otherwise rebuild every turn.

!!! note "<your-lab> operators"
    See the [<your-lab> addendum](../admin/site-addendum.md) for
    the lab-specific persistent-host pattern (`<login-node>` → `<shared-node-tool>` →
    shared HPC node), the `<hpc-mount>` filesystem path, and the
    `<hpc-skills>` add-on.

## Where to next

- Working install: [Install](install.md) — the recommended path is a Claude-Code-driven bootstrap (`agent-sandbox tmux new-session ./monitor/bootstrap-install.sh`); a fully manual fallback is preserved on the same page.
- Want to see the first session end-to-end first: [First run](first-run.md).
- Just looking up a term: [Concepts](concepts.md).
