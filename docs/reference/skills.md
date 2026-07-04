# Skills

A **skill** in nexus is a Markdown file under `skills/nexus.*/SKILL.md`
that codifies one operational rule or pattern. Skills are runtime
artifacts: Claude Code's skill-discovery scans their YAML frontmatter,
matches the user's intent against each `description`, and surfaces
the matching skill's body into the agent's context. The agent then
follows the rules verbatim.

This page is the **catalog** — one entry per skill with its purpose,
trigger conditions, and audience. Each entry links to the full
`SKILL.md` body in the repo; the body is the source of truth and
this page deliberately does **not** duplicate it.

For the convention to write a new skill — frontmatter, TRIGGER
section, when to choose orchestrator-exclusive vs worker-readable —
see [`contributing/adding-a-skill.md`](../contributing/adding-a-skill.md).

## Audience

Three audiences pull from the catalog, each with different concerns:

- **Orchestrator** — the monitor agent in the `orchestrator` tmux window.
  Reads skills covering spawning, window cleanup, the bot, reports,
  infrastructure review, nexus self-fix, the skeptic protocol, service
  recovery, the jupyter service, durable crons, and the cc-update guide.
- **Workers** — per-task agents. Reads the bot skill, the report
  skill, the private-package-install recipe, and the always-applies
  worker floor (auto-injected by the launcher).
- **Skeptics** — adversarial validators the orchestrator spawns to
  re-check a worker's result. Read the skeptic protocol.
- **Maintainers** — humans editing the nexus itself. Reads the
  self-fix skill alongside the catalog.

A skill's audience is the second column in the table below.

## Catalog

| Skill | Audience | Purpose |
|---|---|---|
| [`nexus.tmux-spawn`](#nexustmux-spawn) | orchestrator | Delegate work via the prompt-file + launcher pattern; never the in-process `Agent` tool |
| [`nexus.window-cleanup`](#nexuswindow-cleanup) | orchestrator | When and how to close idle worker windows |
| [`nexus.worker-defaults`](#nexusworker-defaults) | injected | The always-applies safety floor for every spawned worker |
| [`nexus.bot`](#nexusbot) | worker + orchestrator | Bot identity for all GitHub writes; the `ng` / `mint-token.sh` channels |
| [`nexus.report`](#nexusreport) | worker + orchestrator | Report schema, filename convention, the Infrastructure Issues feedback loop |
| [`nexus.lit`](#nexuslit) | worker | Literature research for scientific work: `ng lit` content-relevance discovery (S2 + ASTA) deduped against the reference library, library growth, and citing references in scientific reports |
| [`nexus.infra-review`](#nexusinfra-review) | orchestrator | Periodic meta-review of `## Infrastructure Issues` across the report corpus |
| [`nexus.self-fix`](#nexusself-fix) | orchestrator + maintainers | Editing the nexus itself — watcher, monitor scripts, skills, CLAUDE.md |
| [`nexus.dashboard`](#nexusdashboard) | orchestrator | Overview-issue identity block (`ng nexus-identity`) + formalized dashboard schema (`ng dashboard scaffold`/`validate`) |
| [`nexus.skeptic`](#nexusskeptic) | orchestrator + skeptic | Independent adversarial validation of a worker's result; three spawn modes (`require`/`auto`/`deny`), wrap-up enforcement, worker↔skeptic channel + nudge, bounded recursion |
| [`nexus.service-recovery`](#nexusservice-recovery) | orchestrator | Response protocol for a watcher `--- service health ---` emit: restore first, dispatch a reversible root-cause fix, open an incident via `ng service-incident`, close the loop |
| [`nexus.jupyter`](#nexusjupyter) | orchestrator | JupyterLab-as-a-service: one-command activation (`monitor/jupyter-up.sh`), work-root session with all project kernels, supervised auto-revival via `services.registry` |
| [`nexus.private-package-install`](#nexusprivate-package-install) | worker | Installing private GitHub packages (R `remotes::install_github`, `uv`/`pip` `git+`) via the user's `gh auth token`, not the bot's installation token |
| [`nexus.cron-state-tsv`](#nexuscron-state-tsv) | orchestrator | Durable session-state for `CronCreate`-driven recurring agents: TSV state file + recovery-marker so a respawned orchestrator keeps the fire count |
| [`nexus.cc-update`](#nexuscc-update) | orchestrator | Evaluating a candidate Claude Code release before bumping the pin. Ships as `GUIDE.md` (not an auto-loaded `SKILL.md`) — referenced by path so it never distracts workers |

## `nexus.tmux-spawn`

→ [`skills/nexus.tmux-spawn/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.tmux-spawn/SKILL.md)

**Audience:** orchestrator (workers never spawn workers).

**Trigger:** the orchestrator considers delegating non-trivial work
for a project; reaches for the in-process `Agent` tool to drive a
`work/<project>` task; needs to send a follow-up message to a
running tmux agent; or briefs a fresh worker on a project with
prior reports.

**What it covers:** the prompt-file + launcher pattern
(`monitor/spawn-worker.sh`), per-spawn context curation, the
three-tier taxonomy for external repos, when to use a fresh clone
vs a worktree vs the main tree, follow-up messaging to a running
worker, and the "fix at source" decision (edit the launcher floor
vs the worker prompt vs the skill).

**Why not the in-process `Agent` tool:** sub-agents are blocking
(consume the orchestrator's turn until they return), distracting
(pull attention from monitoring), and invisible (no tmux window,
no report). Tmux delegations stay visible in `tmux list-windows`,
write their own reports, and run in parallel with the orchestrator.

## `nexus.window-cleanup`

→ [`skills/nexus.window-cleanup/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.window-cleanup/SKILL.md)

**Audience:** orchestrator-exclusive. Workers never close themselves
or sibling windows.

**Trigger:** orchestrator surveys the running-agents table at the
start of a wake; notices the dashboard is crowded with idle
workers; considers tearing down a worker that has filed its final
report; or decides whether a long-idle worker should be retained.

**What it covers:** the close/retain decision matrix tied to the
watcher's six [idle classifier classes](watcher-protocol.md#idle-classifier)
(`wrapped`, `wrapped-but-stub`, `no-wrap-up`, `idle-too-long`,
`pane-absent`, `retained`); the retention overrides that keep a worker
alive despite idle (loaded kernel, partial training run, in-progress
branch); the pre-close report check (`monitor/ng report-check`); the
**MANDATORY synchronous pre-kill preflight** — `monitor/retire-preflight.sh
<window>` must be run and return `safe=1` before any `tmux kill-window`,
because it reads *live* pane state and closes the snapshot-staleness gap
(it also independently blocks a kill while a `skeptic-pending` marker is
live); the kill mechanism (`tmux kill-window -t <name>`, gated on the
preflight); and the cadence (once per wake at most).

**Why this policy:** spawning is half the worker lifecycle; closing
is the other half. Without a policy, idle windows accumulate until
`tmux list-windows` becomes unscannable; closing too eagerly loses
expensive in-memory context the user might re-engage.

## `nexus.worker-defaults`

→ [`skills/nexus.worker-defaults/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.worker-defaults/SKILL.md)

**Audience:** injected. Workers never read this skill directly —
its `## Worker floor` section is prepended verbatim by
`monitor/spawn-worker.sh` to every spawn prompt at launch time.

**What it covers:** the executable rules every worker must follow
regardless of task: bot identity for GitHub writes, no
`--no-verify`, no force-push, `sandbox-notify` for blockers, the
`ng fetch-asset` recipe for `user-attachments` URLs, the
report + `ng wrap-up` hand-off.

**How injection works:** `spawn-worker.sh` reads the `## Worker
floor` H2 section out of this skill and stitches it into the
top of the worker's prompt file before invoking `claude`. Editing
the section propagates to every subsequent spawn through the
launcher — no per-spawn boilerplate to update.

**Why a floor and not a skill the worker reads:** worker cwds live
under `work/<project>/...`, which can't always resolve a relative
`skills/` path; the launcher's working tree is the nexus root, so
it has reliable access. Keeping the floor tight (~5 bullets) and
**executable** means the worker can act on every line without
consulting another skill.

## `nexus.bot`

→ [`skills/nexus.bot/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.bot/SKILL.md)

**Audience:** every agent making a GitHub write — workers and
orchestrator. Worker prompts that touch GitHub reference this skill
by path.

**Trigger:** agent considers any GitHub write (PR open / edit /
merge, issue create / comment / close, reaction, dashboard edit,
asset upload); reaches for `gh pr create`, `gh issue create`,
`gh issue comment`, or `gh pr review`; embeds a local file in a
comment or PR body.

**What it covers:** the verb table for `monitor/ng`, the cross-repo
escape hatch via `GH_TOKEN=$(monitor/mint-token.sh) gh ...`, the
install-scope check (`ng preflight`), the fail-loud token guard, the
push-author verify (`gh api .../pulls/<n> --jq
'{author,headRepositoryOwner,maintainerCanModify}'`), the
asset-upload defaults via `ng upload`, and the `ng fetch-asset` flow
for `user-attachments` URLs.

**Why bot, never user:** GitHub mutes mobile push notifications for
actions taken by the recipient's own account. A PR opened, issue
created, or comment posted as the configured user silently fails to
notify them — defeating the control surface. The bot is the only
write identity that can wake the user; `git commit` and `git push`
stay user-authored for commit graph continuity.

## `nexus.report`

→ [`skills/nexus.report/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.report/SKILL.md)

**Audience:** every agent that completes work — workers and the
orchestrator when winding down. Workers consult this for the
schema; the orchestrator consults it when re-dispatching after a
crash.

**Trigger:** agent is completing a delegated task; going idle with
partial work and waiting for input; context window is filling up
and state should be captured before it's lost; spawning a follow-up
worker that needs a brief; handing off to a sibling.

**What it covers:** the filename convention
(`<project>_<YYYY-MM-DD>_<HHMMSS>_<slug>.md`), the YAML frontmatter
schema (project, date, session-id, window, trigger, status), the
five required sections (`## Summary`, `## What Was Done`,
`## Current State`, `## What Remains`, `## How to Resume`), the
optional `## Infrastructure Issues` section + feedback loop, the
append-only convention (write a new file rather than overwrite),
and the `monitor/ng report-init` / `report-check` / `wrap-up` verb
trio that enforces the schema.

**The Infrastructure Issues feedback loop:** any tooling friction
encountered during the task — broken script, missing capability,
ambiguous skill, unexpected sandbox limitation — gets recorded in
the optional section. `nexus.infra-review` aggregates these across
the corpus into a ranked backlog.

## `nexus.lit`

→ [`skills/nexus.lit/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.lit/SKILL.md)

**Audience:** any worker doing scientific work.

**Trigger:** a task should be grounded in prior art — an analysis,
method write-up, experiment, manuscript, or a quantitative/mechanistic
claim that the literature might confirm, contradict, or contextualize;
deciding what to cite in a scientific report.

**What it covers:** the `ng lit` tool — content-relevance paper
discovery over Semantic Scholar (S2) and ASTA, deduplicated against the
nexus reference library (`ng lit search`); pulling papers into the
library (`ng lit add`); readiness/setup (`ng lit status` / `setup`).
Both backends are optional and skip-with-note when unkeyed. It also
codifies the convention that scientific reports **may cite the
references found and the statements they support**, unless irrelevant.
Full reference: [`reference/literature.md`](literature.md).

## `nexus.infra-review`

→ [`skills/nexus.infra-review/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.infra-review/SKILL.md)

**Audience:** orchestrator, manually triggered or on a cadence
(roughly every ~50 new reports).

**Trigger:** user asks for an "infrastructure meta-review", "audit
infra issues across reports", "scan the report corpus for recurring
friction", or "build a backlog of tooling fixes from reports/"; or
the orchestrator notices the report corpus has grown ~50+ entries
since the last meta-review.

**What it covers:** the workflow for reading every
`## Infrastructure Issues` section across `reports/`, clustering by
theme, cross-referencing against `git log` and
`monitor/infra-resolved.md` to drop already-fixed themes, producing
a single ranked report under
`reports/nexus_<YYYY-MM-DD>_<HHMMSS>_infrastructure-meta-review.md`,
and posting the URL on the overview issue.

**Why "always read resolved.md first":** `monitor/infra-resolved.md`
is the closed-issue log — themes that have already shipped fixes.
Re-surfacing them in a meta-review is noise; the skill makes the
pre-flight check load-bearing.

## `nexus.self-fix`

→ [`skills/nexus.self-fix/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.self-fix/SKILL.md)

**Audience:** orchestrator and human maintainers editing nexus
itself. Project agents (data analysis, model training) doing
GitHub writes against their own work stay on `nexus.bot`.

**Trigger:** agent is editing files under `monitor/`, `skills/`, or
the workspace `CLAUDE.md`; investigating a nexus-infra bug (watcher
silently dropping deliveries, eligibility filter misclassifying,
`ng` verb misbehaving); needs to propagate a nexus-internals fix to
sibling fork repos.

**What it covers:** clone isolation for watcher-touching work
(separate clone or worktree, never the live tree); the post-merge
pull into the live clone (the version-aware watcher then
self-restarts — `monitor/svc.sh restart watcher` is only the
fallback; see [Operating → Upgrading](../operating/upgrading.md));
the cross-fork ping discovery mechanism (legacy,
mostly obsolete after the asset-repo cutover); and the
post-asset-repo-cutover convention where most fix-propagation
collapses to a single PR on the canonical code repo.

**Why nexus-self-only:** project agents have project-scoped writes
(their own repos, their own issues); cross-fork discovery and
nexus-internals propagation are nexus-bug-fix concerns, not
general write concerns.

## `nexus.dashboard`

→ [`skills/nexus.dashboard/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.dashboard/SKILL.md)

**Audience:** orchestrator, when seeding or maintaining the overview
issue (`#1`).

**Trigger:** setting up a new operator nexus; the working
directory / host / repo provenance of a nexus needs recording
somewhere notable; the dashboard's content has drifted between runs;
reviewing what `ng dashboard put` pushes; an operator asks "where does
this nexus live / how do I orient."

**What it covers:** the two standing blocks in the overview issue
body, both auto-generated and idempotently upserted. (1) The **Nexus
identity** block (`ng nexus-identity`) — working directory headline
plus host, repos, watcher paths, all DERIVED so it's correct for every
operator with zero edits; identity, not status. (2) The **formalized
dashboard schema** — six required sections (`## Identity` · `## Infra`
· `## Services` · `## In-flight` · `## Awaiting operator` ·
`## Recent landings`) scaffolded by `ng dashboard scaffold`, checked
strictly by `ng dashboard validate`, and warn-checked (never blocked)
by `ng dashboard put`. Both are standard across all operator nexuses;
the section set lives once in `DASH_REQUIRED_SECTIONS` in `monitor/ng`.

**Consistency:** the identity block is metadata, not content, so it
does not violate the overview "routing-only" rule; the schema-check
pattern mirrors `nexus.report`'s `ng report-check`.

## `nexus.skeptic`

→ [`skills/nexus.skeptic/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.skeptic/SKILL.md)

**Audience:** orchestrator (deciding whether to spawn a skeptic) and
the spawned skeptic itself (acting as one). Workers never self-validate.

**Trigger:** the orchestrator spawns a worker whose result warrants an
independent check; a worker reaches wrap-up in `require` or auto-`require`
mode and parks awaiting review; an agent is dispatched AS a skeptic; or
the worker↔skeptic comms channel needs nudging.

**What it covers:** the universal protocol for independently and
adversarially validating a worker's result to the highest scientific
standards — the three spawn modes (`require` / `auto` / `deny`), the
responsible-default heuristic for which mode fits, wrap-up enforcement,
the worker↔skeptic comms channel (`monitor/skeptic-channel.sh`) plus its
nudge, and bounded recursion so a skeptic-of-a-skeptic chain terminates.

**Why a separate validation pass:** a worker that grades its own work
inherits its own blind spots. An adversarial second agent, briefed to
disprove rather than confirm, catches the errors the author cannot see.

## `nexus.service-recovery`

→ [`skills/nexus.service-recovery/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.service-recovery/SKILL.md)

**Audience:** orchestrator-exclusive, fired by a watcher emit.

**Trigger:** the watcher surfaces a `--- service health ---` section —
a registered infrastructure service (jupyter, a long-running daemon)
failed its healthcheck.

**What it covers:** the response protocol — **restore first** (minimal
downtime, accept a degraded-but-up state), then dispatch a worker to
land a *reversible, non-degrading* root-cause fix, open an operator
incident issue via `ng service-incident`, and close the loop once the
fix verifies. The availability-and-trust contract for everything in
`services.registry`.

**Why restore-before-diagnose:** a registered service is something an
operator or project agent depends on being up; the root-cause
investigation is important but secondary to getting the surface back.

## `nexus.jupyter`

→ [`skills/nexus.jupyter/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.jupyter/SKILL.md)

**Audience:** orchestrator, when an operator asks for a jupyter(lab)
session or a project needs a persistent kernel that survives reboots.

**Trigger:** a user asks for "a jupyter session", a notebook, or a
persistent kernel; a project's data is slow to load and wants a
stateful kernel across turns.

**What it covers:** one-command activation (`monitor/jupyter-up.sh`);
the foolproof default — a single work-root session exposing every
project's kernels (`--root` + `monitor/jupyter-kernel-crawl.sh`); the
per-project isolation mode; project-agent access via
`monitor/labsh-root.sh`; and supervised auto-revival by registering the
server in `services.registry`. Builds on the `<yourlab>.labsh` primitives.

**Why a service, not an ad-hoc launch:** a kernel that vanishes on
reboot or watcher restart defeats the point of a persistent session;
registry supervision keeps it revived.

## `nexus.private-package-install`

→ [`skills/nexus.private-package-install/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.private-package-install/SKILL.md)

**Audience:** workers installing dependencies that live in private
GitHub repos.

**Trigger:** a worker runs `remotes::install_github`, `uv pip install
git+…`, `pip install git+…`, or any installer that clones a private
GitHub repo.

**What it covers:** use the **user's** `gh auth token` (exported as
`GITHUB_PAT` / `GITHUB_TOKEN`) for the clone — **not** the bot's
installation token, which 404s silently on private-repo Git access —
and fail loudly when the PAT is unset rather than falling through to an
opaque auth error.

**Why not the bot token:** the bot's installation token is scoped for
the App's GitHub API surface, not arbitrary private-repo `git clone`;
handing it to `pip`/`remotes` yields a confusing silent 404.

## `nexus.cron-state-tsv`

→ [`skills/nexus.cron-state-tsv/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.cron-state-tsv/SKILL.md)

**Audience:** orchestrator, scheduling a multi-fire recurring agent
whose state must survive a respawn.

**Trigger:** the orchestrator schedules a multi-fire `CronCreate` and
needs its fire count / bookkeeping to survive an orchestrator respawn.

**What it covers:** the TSV state-file + recovery-marker pattern — a
workaround for the silently-ignored `durable: true` flag — so a
respawned orchestrator can re-instantiate the cron without losing the
fire count or double-firing.

**Why a TSV and not the flag:** the harness's `durable: true` is
accepted but silently dropped; persisting the schedule's identity and
fire count to a file the respawned orchestrator re-reads is the
reliable substitute.

## `nexus.cc-update`

→ [`skills/nexus.cc-update/GUIDE.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.cc-update/GUIDE.md)

**Audience:** orchestrator-only — specifically the evaluator agent it
spawns when an update is detected.

**Ships as `GUIDE.md`, not `SKILL.md`, deliberately.** It is consulted
by exactly one agent (the cc-update evaluator) and is referenced by
**path** — so it is kept out of every agent's auto-loaded skill index,
where it would be pure distraction for workers that never do update
work. The orchestrator reaches it via the watcher emit line, the
`CLAUDE.md` skill table, and the evaluator's spawn prompt.

**Trigger:** the watcher emit carries a `--- claude code update
available ---` section; an operator asks to evaluate or bump the Claude
Code version; or `monitor/.state/cc-update-available` is present.

**What it covers:** the **EVALUATE → DECIDE → APPLY** half of the gated
Claude Code self-update loop — changelog review, collision analysis
against the cc-version-sensitive surfaces catalogued in
[`dependency-surface.md`](dependency-surface.md), the cc-harness gate
(`monitor/cc-harness/gate.sh`), the safe / review / block decision, and
the bump procedure (advancing the operator-local pin
`monitor/.state/cc-version-local`, never the `package.json` floor).

**Why path-referenced and gated:** an unvetted Claude Code release can
silently break the load-bearing TUI parser; the gate forces a
deliberate, harness-checked promotion rather than a blind auto-update.

## Discovery and load behaviour

Claude Code scans each `skills/*/SKILL.md` at session start, reads
the YAML frontmatter (`description`, optionally `model`), and adds
the skill to the discovery index. When the user's request matches a
skill's description (or the agent calls `Skill(name)`), the body of
that one file is loaded into context.

Two caveats worth knowing when delegating:

- **Worker cwds under `work/<project>/...` may not auto-discover
  skills under the nexus root.** Reference skills by path in the
  worker prompt (`see /<absolute>/skills/nexus.report/SKILL.md`) or
  rely on the injected [Worker floor](#nexusworker-defaults).
- **The orchestrator's CLAUDE.md is the re-anchor index.** When the
  orchestrator doesn't know which skill applies, it consults
  CLAUDE.md's skill table first. New skills should be added to that
  table at the same time the SKILL.md lands.

## See also

- [`contributing/adding-a-skill.md`](../contributing/adding-a-skill.md)
  — the convention for writing a new `nexus.*` skill.
- [Architecture](architecture.md) — where skills sit in the
  orchestrator/worker/bot picture.
- [`monitor/agent-prompt.md`](https://github.com/<your-org>/nexus-code/blob/main/monitor/agent-prompt.md)
  — the orchestrator's launch prompt; references several skills by
  name.
