# Nexus workspace

You are an agent in a nexus workspace — a coordination repo that
hosts project checkouts under `work/`, plus a monitor agent that
turns GitHub issues into a control surface. Your role is set by
your launcher prompt; this file is the cross-cutting contract.

## Skills

Orchestrator re-anchor — when you don't know what to consult,
this is the index. One line per skill, "use when" framing:

| Use when… | Skill |
|---|---|
| Spawning a worker for any nexus delegation (prompt-file, follow-ups, VI hazard, per-spawn context curation, three-tier taxonomy, fix-at-source decision) | `skills/nexus.tmux-spawn/SKILL.md` |
| Spawning a worker that requires/allows/denies an independent skeptic validation pass, deciding at wrap-up whether one is warranted, acting AS a skeptic, or using the worker↔skeptic comms channel + nudge — three spawn modes (`require\|auto\|deny`), the responsible-default heuristic, wrap-up enforcement, bounded recursion | `skills/nexus.skeptic/SKILL.md` |
| Closing a worker window — close/retain decision rules, pre-close report check, kill mechanism (orchestrator-exclusive) | `skills/nexus.window-cleanup/SKILL.md` |
| Responding to a watcher `--- service health ---` emit (a registered infra service failed its healthcheck) — restore first (minimal downtime), dispatch a reversible/non-degrading root-cause fix, open an operator incident issue via `ng service-incident`, close the loop | `skills/nexus.service-recovery/SKILL.md` |
| Editing the always-applies worker safety floor (auto-injected into every spawn prompt by `monitor/spawn-worker.sh` from the `## Worker floor` section) | `skills/nexus.worker-defaults/SKILL.md` |
| Making any GitHub write — PR, issue, comment, reaction, wiki upload (`ng` verbs, install scope, push-author verify, fail-loud token guard) | `skills/nexus.bot/SKILL.md` |
| Writing or reviewing a report under `reports/` (sections, infra-issue feedback loop) | `skills/nexus.report/SKILL.md` |
| Doing scientific work that should be grounded in the literature — finding relevant papers by content (`ng lit search` over S2 + ASTA, deduped against the reference library), growing the library (`ng lit add`), and citing the references + their supporting statements in scientific reports | `skills/nexus.lit/SKILL.md` |
| Running periodic infrastructure meta-review across reports | `skills/nexus.infra-review/SKILL.md` |
| Fixing the nexus itself — orchestrator, watcher, monitor scripts, skills; pre-flight gate (fresh pull + substantiated repro + scope check) before filing on `<your-org>/nexus-code` | `skills/nexus.self-fix/SKILL.md` |
| Scheduling a multi-fire `CronCreate` whose state must survive an orchestrator respawn — TSV bookkeeping + recovery-marker pattern (workaround for the silently-ignored `durable: true` flag) | `skills/nexus.cron-state-tsv/SKILL.md` |
| A user asks for a jupyter(lab)/notebook session, or a project needs a persistent kernel that survives reboots — one-command activation (`monitor/jupyter-up.sh`), supervised service via `services.registry`, kernel registration, foolproof default behavior (labsh primitives: `<yourlab>.labsh`) | `skills/nexus.jupyter/SKILL.md` |
| Seeding or maintaining the overview issue `#1` identity record + dashboard — the auto-generated **Nexus identity** block (`ng nexus-identity`, working-directory headline) and the formalized dashboard schema (six required sections, `ng dashboard scaffold`/`validate`); standard across all operator nexuses | `skills/nexus.dashboard/SKILL.md` |
| Evaluating a candidate Claude Code release before bumping the pin (watcher emitted `--- claude code update available ---`) — changelog review, collision analysis against cc-version-sensitive surfaces, cc-harness gate, safe/review/block decision + bump procedure. Orchestrator-only; a path-referenced guide (`GUIDE.md`, deliberately NOT an auto-loaded `SKILL.md`) so it never distracts worker agents | `skills/nexus.cc-update/GUIDE.md` |

Skills under `skills/` may not auto-discover when cwd is inside
`work/<project>/...`. Reference them by path when delegating.

## Other docs

| Need | Look here |
|---|---|
| Monitor architecture, watcher liveness, env vars | `monitor/README.md` |
| Monitor agent launch behaviour | `monitor/agent-prompt.md` |
| Bot first-time setup | `monitor/BOT_SETUP.md` |

**Never create a `CLAUDE.md` anywhere under `work/`.** Each
`work/<project>` is its own git repo, often shared — a
nexus-specific CLAUDE.md leaking into a foreign repo is noise at
best and a footgun at worst. Workspace-level rules belong here.

## Reports — write one before you finish, idle, or run out of context

Every agent MUST write a `reports/{project}_{YYYY-MM-DD}_{HHMMSS}_{slug}.md`
file before finishing, going idle, or under context pressure —
the resumption surface if your session crashes. Use `nexus` for
the `{project}` slot when the work spans projects.

`monitor/ng report-init <slug>` is the canonical starter: it
writes a frontmatter'd skeleton at that exact path, capturing
your session-id + tmux window automatically. The five required
sections (`## Summary` | `## What Was Done` | `## Current
State` | `## What Remains` | `## How to Resume`; conditional
`## Infrastructure Issues`) are the schema enforced by
`monitor/ng report-check`. `monitor/ng wrap-up <issue>
<report-path> ...` is the canonical hand-off: it runs
`report-check` as a pre-flight, then uploads the report to the
asset repo, posts a templated link comment on the issue,
rockets the trigger comment if `--trigger-comment` is supplied,
and logs the wrap-up event for the orchestrator's
window-cleanup loop. Schema, append-only convention, and the
`## Infrastructure Issues` feedback loop:
`skills/nexus.report/SKILL.md`.

## GitHub writes — identity and authorization

Two questions per write: **WHO** posts (always the bot) and
**WHETHER** to post (depends on the target repo's tier). They
intertwine, so they live together.

**WHO — always the bot, never the user's `gh`.** GitHub mutes
notifications for actions taken by the recipient's own account, so
a PR/issue/comment posted as the user silently fails to wake them.
Use `monitor/ng <verb>` for the nexus repo (`github.repo` — the
asset+issue repo, e.g. `<your-org>/<your-nexus>` for this operator;
**not** `<your-org>/nexus-code`, which is the canonical implementation
repo every operator clones);
`GH_TOKEN=$(./monitor/mint-token.sh) gh ...` for cross-repo or
verbs `ng` doesn't cover. Local files referenced from a comment go
through `ng upload` first — `reports/` is gitignored, so bare paths
404. Only `git commit` and `git push` may use the user's identity.
Verb table, install scope, fail-loud token guard, push-author
verify, asset-upload defaults: `skills/nexus.bot/SKILL.md`.

**The bot is the DEFAULT, enforced — bare `gh <write>` already
posts as the bot.** A PATH-FRONT `gh` wrapper (`monitor/ghwrap/gh`),
prepended to the front of `PATH` for every agent process
(`monitor/locals-env.sh` + a per-command force-front in
`monitor/shellenv/.zshenv` that wins the race against `~/.zshenv`'s
linuxbrew re-prepend), intercepts `gh`: WRITE verbs (`pr/issue`
create·edit·comment·close·…, `release` upload·…, `api` with a
`POST/PATCH/PUT/DELETE` method, a `-f/-F`/`--input` body, or `api
graphql`) auto-inject the bot token via `mint-token.sh`; READS and
`gh auth …` pass through untouched; an already-set `GH_TOKEN` is
never overridden. Because it is a real executable (not a zsh
function), it covers every child an agent spawns — bash subshells,
`python subprocess`, Makefiles — not just zsh-direct calls. So even
the high-frequency "on it —" ack slip lands as the bot. The wrapper
fails LOUD (refuses, never falls through to the operator) if minting
yields an empty token. It is inert for the watcher (which runs with
`WATCHER_WINDOW` set + presets `GH_TOKEN`, so it passes through) and
for the operator's own interactive shells (`locals-env` PATH-only
mode never prepends it). To post as the operator on purpose — the
one legitimate case being an external repo with no bot install — opt
in LOUDLY: `GH_IMPERSONATE=1 GH_IMPERSONATE_REASON="why" gh …` (a
reason is required, and the call is audited to
`monitor/.state/impersonate.log`). `git commit`/`git push` are
unaffected (git, not `gh`).

**WHETHER — by repo tier.** Find the tier of the target repo, then
follow its rule:

- **Internal** (`<your-org>/*`, private `<operator>/*`): no fresh
  approval per action.
- **User-public** (`katosh/labsh`, `katosh/agent_sandbox`, …):
  standing approval for ongoing work the user explicitly initiated;
  new directions need a fresh ack.
- **External public** (`TrigosTeam/*`, `<your-institution>/*`, third-party
  repos, including `<operator>/<external-fork>` — GitHub visibility,
  not ownership, decides): every push / PR / issue / comment needs
  a fresh, specific user go-ahead. Worker prompts touching external
  repos default to "draft + STOP for review", never auto-submit.
  Before any external-public write, grep the draft for internal
  identifiers (lab names, study names, sample IDs, treatment
  names, cell/clone counts, internal-repo refs) and redact.

The orchestrator picks the tier at spawn time and surfaces the
relevant rule into the worker prompt — workers act on their
target's rule, not the whole taxonomy. Per-spawn curation:
`skills/nexus.tmux-spawn/SKILL.md` "Curating per-spawn context".

## Spawning workers — tmux, never the in-process `Agent` tool

For any nexus delegation, spawn a tmux window via the prompt-file
+ launcher pattern in `skills/nexus.tmux-spawn/SKILL.md`. Use the
in-process `Agent` tool only for tight, bounded research that
stays in your own thinking loop — never for nexus delegations.

If you find yourself orchestrating, delegate. If the action
would land in a worker's "What Was Done", run it in a worker's
window. Read-only orchestration (`tmux list-windows`, `head -7
reports/*.md`, dashboard pushes, bootstrap) is coordination.

**Watcher-touching work needs a separate clone.** Never `git
checkout <branch>` on the main clone while the watcher is
running. The watcher (`monitor/watcher/main.sh`) sources
`_github.sh`/`_lib.sh`/`_unstick.sh` once at startup; checking
out a branch with diverged helper signatures silently breaks
`snapshot_github` (functions in memory call functions on disk
with mismatched arity, bash fails quietly, no eligible-comments
get surfaced). Workers touching `monitor/watcher/*` MUST clone
the nexus repo afresh into `work/<your-nexus>-<task>/` (or use a
worktree as a lighter fallback) and operate there. After a
watcher-affecting change lands on `main`, the orchestrator
`git pull`s in the main clone — that's the whole step: the
version-aware watcher detects its source-set drift and
self-restarts on its own (`monitor/watcher/_version_restart.sh`,
issue `#186`). A manual `monitor/svc.sh restart watcher`
(equivalently `monitor/watcher/launcher.sh --replace` — `--target`
defaults to config `monitor.target_window`; never hard-code it)
is only needed when the auto-restart is disabled
(`monitor.version_restart.enabled: false`) or the running
watcher predates the version-aware module. The watcher runs
headless (no tmux window); its log is
`monitor/.state/watcher.log`.

## Overview issue is routing-only

The Nexus overview issue (`<github.repo>` issue tagged
`nexus:overview`, typically `#1`) is **routing-only**. Never
carry content discussion or per-task back-and-forth there —
every actionable thread lives in its own issue or PR.

When a user comment on the overview initiates new work or asks
a content question, do not reply with content on the overview.
Spawn a dedicated worker AND open a dedicated tracking issue
(`monitor/ng issue create`); link it from the overview with a
one-liner ("dispatched to `<window>`, tracking at `#N`"). Worker
comments back on the dedicated issue, not on the overview.

Carry-over confirmations stay ultra-terse on the overview — just
acknowledge and link. With many parallel projects in flight, the
overview gets unfollowable when content threads pile up
alongside routing comments.

## Independent clones for parallel work

When agents could collide on the same project — two workers
editing the same `work/<project>`, or a worker editing files the
running watcher reads — operate on **separate clones**, not on
the shared tree. Lockfiles are not the mechanism; isolation is.

Two ways to spin one up:

- **Fresh clone** — `git clone <remote>
  work/<project>-<task>/`. Fully isolated `.git` and working
  tree; use when the task touches data the primary reads, or a
  clean remote checkout matters.
- **Worktree** — `git -C work/<project> worktree add
  ../<project>-<task> -b <operator>/<task>`. Lighter; shares `.git`,
  separate working tree and branch. Default for code-only edits.

When the worker runs in a **secondary clone** — data-light,
sandboxed, or otherwise not the canonical state — say so
explicitly in its prompt. Secondary clones can edit and test
freely; writes that need to land in canonical state route
through the primary clone or via PR.

The watcher-branch-isolation rule under "Spawning workers" above
is the load-bearing example.

## Common gotchas

Workspace-wide traps that have bitten spawned workers more than
once. Pull the relevant ones into worker prompts when delegating.

- **`#N` in GitHub comment bodies auto-links to an issue or PR**
  in the *current* repo. Don't use `#1`, `#2`, … as numbered-list
  markers (every item becomes a link) — use `1.`, bullets, or
  `(1)`. For cross-repo, `owner/repo#N`. To show `#N` verbatim,
  wrap in backticks: `` `#11` ``.
- **`github.com/user-attachments/...` URLs poison the session.**
  External fetcher agents 404; feeding the failure through
  Read-as-image returns 400, which silently disables every
  subsequent image fetch in the conversation. NEVER hand a
  `user-attachments` URL to a sub-agent or to Read. The
  bot-side workaround is `monitor/ng fetch-asset <url>`, which
  reads the user's `gh auth token` PAT (the bot's installation
  token 404s on this surface) and writes the bytes under
  `monitor/.state/assets/<asset-id>.<ext>` — then Read the local
  file. See `skills/nexus.bot/SKILL.md` "Reading user-pasted assets".
- **`git checkout <ref> -- <path>` overwrites the working tree
  without warning** — destructive on a dirty tree. For read-only
  peeks at content at another ref, use `git show <ref>:<path>`.
- **`git checkout <branch>` on the main clone silently breaks
  the running watcher** if the branch has changed
  `monitor/watcher/_*.sh` helper signatures. Functions in
  memory call functions on disk with mismatched arity → bash
  fails quietly → eligible-comments stop surfacing without any
  log error. Always operate in a separate clone under
  `work/<your-nexus>-<task>/` (or a worktree); see "Spawning
  workers" above for full recovery steps.
- **Prefer `uv pip` over plain `pip`.** Inside `agent-sandbox`
  the wrapped `/app/bin/pip` can hang >5 min; `uv pip install`
  finishes in seconds. Use `uv pip` outside the sandbox too.
- **Worker pane state: use `monitor/pane-state.sh <window-index>`**
  (alias `ng pane-state <window-index>`)
  (it is **index-keyed** — `<window-index|session:window>`, NOT a
  window name; passing a name fails the lookup), never
  eyeball `tmux capture-pane`. Claude Code's autosuggest renders
  identically to user input in plain text. The helper emits
  `state=<idle|busy|user-typing|autosuggest-only|empty|blocked|absent>
   active=<0|1>`.

## Shared infrastructure

If you run on shared infrastructure (HPC cluster, batch
scheduler, lab GPU pool), be efficient: test before scaling,
right-size resource requests, reuse intermediate results, and
prefer the appropriate partition/queue for the job size.
