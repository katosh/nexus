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

!!! warning "This catalog is a claim of SET EQUALITY, not a sample"

    **Every skill directory that ships MUST have exactly one row in the
    table below, and every row MUST name a directory that exists.** An
    enumeration that is merely *illustrative* cannot be wrong, which is
    why nobody notices when it stops being complete — this catalog
    listed 16 rows against 19 shipped skill directories for an unknown
    period, silently omitting `nexus.agent-delivery`,
    `nexus.remote-access` and `nexus.tool-ecosystem`
    (<your-org>/nexus-code#1264 R5).

    Check it, in both directions, before trusting it:

    ```bash
    ondisk=$(mktemp)          # unique per caller — never a fixed path
    git ls-tree -r --name-only <ref> \
      | grep -E '^skills/[^/]+/(SKILL|GUIDE)\.md$' \
      | sed 's#skills/##;s#/\(SKILL\|GUIDE\).md##' | sort -u > "$ondisk"
    # …and the catalog rows from the table below; then `comm -3` the two.
    ```

    Measured at `a3177ef6`: **21** shipped skill directories — 20 with a
    `SKILL.md`, plus `nexus.cc-update`, which ships a `GUIDE.md` by
    design — and **21** rows below, `comm -3` empty in both directions.
    `monitor/watcher/test-skills-catalog.sh` asserts exactly this set
    equality, in both directions, over rows *and* over `## ` sections,
    on every run — so a row added without its section is caught too.

For the convention to write a new skill — frontmatter, TRIGGER
section, when to choose orchestrator-exclusive vs worker-readable —
see [`contributing/adding-a-skill.md`](../contributing/adding-a-skill.md).

## Audience

Three audiences pull from the catalog, each with different concerns:

- **Orchestrator** — the monitor agent in the `orchestrator` tmux window.
  Reads skills covering spawning, window cleanup, the bot, reports,
  infrastructure review, nexus self-fix, the skeptic protocol, service
  recovery, the watcher, the dashboard, the jupyter service, durable
  crons, agent delivery, the remote access channel, and the cc-update
  guide.
- **Workers** — per-task agents. Reads the bot skill, the report
  skill, the literature skill, the private-package-install recipe, the
  lab-tool bug-routing protocol, CI triage, the checkable-claims
  discipline, and the always-applies worker floor (auto-injected by
  the launcher).
- **Skeptics** — adversarial validators the orchestrator spawns to
  re-check a worker's result. Read the skeptic protocol and the
  checkable-claims discipline.
- **Maintainers** — humans editing the nexus itself. Reads the
  self-fix skill and the agent-delivery contract alongside the catalog.

The audience column below is the authority for any single skill; this
list is a reading aid and is not asserted by a guard.

A skill's audience is the second column in the table below.

## Catalog

| Skill | Audience | Purpose |
|---|---|---|
| [`nexus.tmux-spawn`](#nexustmux-spawn) | orchestrator | Delegate work via the prompt-file + launcher pattern; never the in-process `Agent` tool |
| [`nexus.window-cleanup`](#nexuswindow-cleanup) | orchestrator | When and how to close idle worker windows |
| [`nexus.worker-defaults`](#nexusworker-defaults) | injected | The always-applies safety floor for every spawned worker |
| [`nexus.bot`](#nexusbot) | worker + orchestrator | Bot identity for all GitHub writes; the `ng` / `mint-token.sh` channels |
| [`nexus.report`](#nexusreport) | worker + orchestrator | Report schema, filename convention, the Infrastructure Issues feedback loop |
| [`nexus.lit`](#nexuslit) | worker | Literature research for scientific work: `ng lit` content-relevance discovery (S2 + ASTA + OpenAlex) deduped against the reference library, library growth, and citing references in scientific reports |
| [`nexus.infra-review`](#nexusinfra-review) | orchestrator | Periodic meta-review of `## Infrastructure Issues` across the report corpus |
| [`nexus.self-fix`](#nexusself-fix) | orchestrator + maintainers | Editing the nexus itself — watcher, monitor scripts, skills, CLAUDE.md |
| [`nexus.dashboard`](#nexusdashboard) | orchestrator | Overview-issue identity block (`ng nexus-identity`) + formalized dashboard schema (`ng dashboard scaffold`/`validate`) |
| [`nexus.skeptic`](#nexusskeptic) | orchestrator + skeptic | Independent adversarial validation of a worker's result; three spawn modes (`require`/`auto`/`deny`), wrap-up enforcement, worker↔skeptic channel + nudge, bounded recursion |
| [`nexus.service-recovery`](#nexusservice-recovery) | orchestrator | Response protocol for a watcher `--- service health ---` emit: restore first, dispatch a reversible root-cause fix, open an incident via `ng service-incident`, close the loop |
| [`nexus.watcher`](#nexuswatcher) | orchestrator | Operating & diagnosing the watcher: liveness by the UP/BUSY/WEDGED/DOWN verdict over the heartbeat/progress/cycle triple (not `watcher.log` mtime, and **not** the heartbeat alone), the supervisor's silent self-heal, recovery recipes by failure signature (wedge / stale-lock / decapitation-duplicate), phantom-window auto-resurrection, eligible-comment eyes-ack + stale-eyes re-emit, CC-banner vs gated cc-update |
| [`nexus.jupyter`](#nexusjupyter) | orchestrator | JupyterLab-as-a-service: one-command activation (`monitor/jupyter-up.sh`), work-root session with all project kernels, supervised auto-revival via `services.registry` |
| [`nexus.private-package-install`](#nexusprivate-package-install) | worker | Installing private GitHub packages (R `remotes::install_github`, `uv`/`pip` `git+`) via the user's `gh auth token`, not the bot's installation token |
| [`nexus.cron-state-tsv`](#nexuscron-state-tsv) | orchestrator | Durable session-state for `CronCreate`-driven recurring agents: TSV state file + recovery-marker so a respawned orchestrator keeps the fire count |
| [`nexus.agent-delivery`](#nexusagent-delivery) | orchestrator + maintainers | The harness-neutral contract for delivering an instruction to an agent and knowing whether it ARRIVED: window-name identity, per-agent transport + receipt declaration, the one common ledger, and the exclusivity rule that makes a fallback chain safe against double delivery |
| [`nexus.tool-ecosystem`](#nexustool-ecosystem) | worker + orchestrator | Routing a bug in a **lab-authored** tool (kompot, Mellon, Palantir, …) to its code owner instead of silently working around it: the first-line-tester rationale and the tool → owner → repo table |
| [`nexus.remote-access`](#nexusremote-access) | orchestrator | Enabling and operating the OFF-BY-DEFAULT confined remote agent channel (`monitor/remote-up.sh`): bind postures, the fail-closed `from_cidr` pin, the out-of-band secret flow, token-gated pubkey self-enrollment, rotate/revoke |
| [`nexus.ci-triage`](#nexusci-triage) | worker + orchestrator | A PR's CI has gone RED and you do not yet know whether the base or your diff caused it: check `dev` in isolation first (a unique per-caller worktree), what a worktree's missing gitignored/untracked files hide, why `ci-signal` green is not merge clearance |
| [`nexus.claims`](#nexusclaims) | worker + orchestrator + skeptic | You are about to PUBLISH A CHECKABLE CLAIM — a count, a `path:line`, a timeline across refs, a set membership — and the enumeration behind it has to be able to say which direction it errs in |
| [`nexus.longjob`](#nexuslongjob) | worker + orchestrator | A computation will OUTLIVE the 30-minute `Monitor` cap and you need to be WOKEN when it ends, fails, or hits a custom event — `ng longjob run -- <cmd>`, auto-watched `sbatch`, `add slurm:\|asyncrun:\|pid:\|file:\|cmd:`, and what happens when the watch does NOT fire |
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
watcher's [idle classifier classes](watcher-protocol.md#idle-classifier)
— the wrap-up-derived core (`wrapped`, `wrapped-but-stub`,
`no-wrap-up`, `idle-too-long`) plus `pane-absent`, `over-limit`,
`operator-engaged`, `engaged-close-reminder`, `paste-unconfirmed`,
`idle-orphan-async` and the `retained` footer; do not treat that
list as the vocabulary — [Worker states](worker-states.md) is;
the retention overrides that keep a worker
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
`--no-verify`, no force-push to a shared branch (rebasing your own
PR branch onto the current base and force-pushing it is expected —
the merge gate requires it), `sandbox-notify` for blockers, the
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

## `nexus.watcher`

→ [`skills/nexus.watcher/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.watcher/SKILL.md)

**Audience:** orchestrator-only. A worker never operates the watcher; to
*change* watcher code, use `nexus.self-fix` (and the separate-clone
rule). This skill is about *operating* the running loop.

**Trigger:** judging whether the watcher is alive; a supervisor
`Monitor` exited or a "watcher DOWN" signal arrived; a fresh
`watcher/main.sh` pid or `startup-sweep` emit appears; an eligible
GitHub comment keeps re-emitting; a phantom `claude` window spawns and
vanishes; or you're about to conflate the CC TUI update banner with the
gated cc-update emit.

**What it covers:** (1) liveness = the **UP/BUSY/WEDGED/DOWN verdict**
over the heartbeat/progress/cycle triple — never `watcher.log` mtime (a
fresh log can hide a wedged loop) and never the heartbeat alone (a
beating heartbeat over a loop that stopped advancing *is* WEDGED); a
BUSY watcher is healthy under load and must not be restarted; (2) the
supervisor **self-heals silently** — a new pid / `startup-sweep` is
usually normal, and you only get an exit-notification when a revive
*fails*; (3) diagnose by process **GROUP** not pid (`ppid==1` is a false
top-level test — orphaned subshells reparent to init); (4) recovery
recipes keyed to failure signature — `compose_emit` wedge, decapitation
**duplicate** (two racing watchers, `flock` fd inherited by every fork),
and **stale-lock** blocking auto-revival (silent no-op, same dead pid);
(5) phantom-window auto-resurrection after 3 missed pastes; (6) the
eligible-comment **eyes-ack** (`ng react … eyes`, bot 👀 only) and the
**stale-eyes re-emit** papercut; (7) the CC update **banner** ≠ the
gated cc-update **emit**.

**Why a dedicated skill:** watcher liveness is counter-intuitive (the
obvious signal — the log — lies), and the recovery paths differ by
signature in ways that a wrong guess makes worse (reviving a decapitation
duplicate manufactures a third watcher). Too detailed for `CLAUDE.md`,
fired by a sharp set of conditions.

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

## `nexus.agent-delivery`

→ [`skills/nexus.agent-delivery/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.agent-delivery/SKILL.md)

**Audience:** orchestrator delivering an instruction from a script;
maintainers adding a transport or a second harness.

**Trigger:** you are adding a transport or a harness, sending to an
agent from a script, or reasoning about whether a delivery actually
*arrived* rather than was merely attempted.

**What it covers:** the harness-neutral delivery contract behind
`ng send` — **harness-neutral identity** (the tmux window name, never
a session id or a `~/.claude` path); **per-agent capability
declaration** (which transports reach this agent and what receipt each
provides, `none` included); **the one common ledger**, whose guard key
no transport may choose; and **registration/discovery that never reads
`~/.claude`**. Carries the EXCLUSIVITY RULE that makes a fallback
chain safe against double delivery.

**The sharp edge:** an `invoke: agent` transport — Claude Code's
in-process `SendMessage` is one — **escapes the ledger entirely**: it
writes no row at all, so "no row" means *unknown*, never *not
delivered*. That is why `SendMessage` cannot be chained from a shell
script and why the guarantee is stated where it is made rather than
in a summary.

**Status caveat:** the contract is implemented against exactly one
harness. Everything the SKILL marks *UNVALIDATED* is a proposal, kept
explicitly labelled because a spec nobody has built against is the
same failure as a delivery claim believed without a receipt.

## `nexus.tool-ecosystem`

→ [`skills/nexus.tool-ecosystem/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.tool-ecosystem/SKILL.md)

**Audience:** any lab agent, plus the orchestrator routing the report.

**Trigger:** an agent hits a bug, crash, wrong result, or rough edge
in a **lab-authored** software tool (kompot, Mellon, Crowding,
Palantir, SEACells, …) and is deciding whether to work around it
silently; or somebody asks who owns tool X.

**What it covers:** the first-line-tester contract — lab agents are
the highest-volume users of these tools, so a bug they route in
minutes is worth more than a workaround nobody sees — plus the
tool → owner → repo table and the filing protocol (open on the
owner's nexus asset repo, `@`-ping the owner), with the
external-upstream nuance for repos the lab does not own, where the
default is **draft and stop for review**.

**Explicitly not for** third-party tools the lab merely uses (scanpy,
anndata, ArchR); those go upstream in the ordinary way.

## `nexus.remote-access`

→ [`skills/nexus.remote-access/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.remote-access/SKILL.md)

**Audience:** orchestrator. Operator-facing quick-start:
[Operating → Remote access](../operating/remote-access-quickstart.md).

**Trigger:** the operator wants another machine on the LAN to talk to
this orchestrator; you must enable, operate, or disable the remote
endpoint; or a `--- service health ---` emit names
`nexus-remote-ssh`.

**What it covers:** the **off-by-default** confined SSH endpoint
(`monitor/remote-up.sh`) that lets a LAN client file a request into
the inbox and read its own reply — a forced command giving it exactly
what a local in-sandbox agent has and nothing more. Two safe bind
postures (LAN-direct behind a **fail-closed `from_cidr` pin**, or
loopback plus a forward-only tunnel for zero LAN exposure), the
out-of-band secret flow (host key and one-time token — **never** on
GitHub), token-gated pubkey self-enrollment, the copy-paste client
prompt, and rotate/revoke.

**Relationship to the RFC:** this is **Part A**, the transport. The
request inbox and reply protocol (`ng request file/await/fetch`) are
Parts B/D; the full spec is `docs/agent-channel-rfc.md`.

## `nexus.ci-triage`

→ [`skills/nexus.ci-triage/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.ci-triage/SKILL.md)

**Audience:** any agent whose PR has gone red; the orchestrator when it
triages a red on `dev`.

**Trigger:** a PR's CI is RED and it is not yet known whether the base
or the diff caused it.

**What it covers:** CI builds the MERGE ref, so a red at your head is a
claim about `base + yours`, never about yours alone — and inheriting a
red is the normal case here. The check-`dev`-in-isolation recipe with a
UNIQUE per-caller worktree (never a fixed path, never `git checkout` on
the main clone), what a worktree's missing gitignored and untracked
files hide from a run, why `ci-signal` green is not merge clearance, and
why a failing lint's OFFENDER LIST is read rather than its count.

## `nexus.longjob`

→ [`skills/nexus.longjob/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.longjob/SKILL.md)

**Audience:** any worker or orchestrator that starts a computation which
will outlive the 30-minute `Monitor` cap — a Slurm job, a 40-minute test
suite, a multi-hour script — and must be WOKEN when it ends, fails, or hits
a custom event.

**Trigger:** you are about to end a turn with work in flight; `add` said
NOT ARMED; or you need to know what the watch does when it does NOT fire.

**What it covers:** the ONE host-armed plugin monitor every nexus session
carries (the longjob-watch dispatcher, `monitor/longjob-watch.sh`,
`ng longjob`): the one-liner `ng longjob run -- <cmd>` for a long local
command, auto-watched `sbatch`, `add slurm:|asyncrun:|pid:|file:|cmd:`,
the five-answer probe contract (`unknown` is not `running`), event caps,
what survives a respawn (the spool, keyed on the session id) and what does
not (the dispatcher process), the fallback wake (`await` under
`run_in_background`) for an unarmed session, and the host's rollout flag
(`tengu_amber_sentinel`) that decides whether plugin monitors arm at all.

## `nexus.claims`

→ [`skills/nexus.claims/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.claims/SKILL.md)

**Audience:** every agent about to publish a checkable claim — in an
issue, a PR body, a comment, a report or a skeptic verdict.

**Trigger:** the text you are about to post carries a count, a
`path:line`, a timeline across refs, a set membership, or a "nobody has
done this".

**What it covers:** this workspace's dominant defect family — a tool
answering confidently, at rc 0, in a shape that reads as normal — and
what provenance makes a number re-derivable (command + ref + whether the
files were staged); the merge-shape taxonomy behind a "PRs merged"
denominator; why a predicate over source text for a runtime property
must state which direction it errs in; and the cross-checks that agree
with themselves and therefore verify nothing.

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
