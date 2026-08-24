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
| Operating/diagnosing the watcher itself — judging liveness (loop-proof heartbeat, NOT `watcher.log` mtime), the supervisor's silent self-heal, recovery recipes by failure signature (wedge / stale-lock / decapitation-duplicate; diagnose by process GROUP not pid), phantom-window auto-resurrection, the eligible-comment eyes-ack + stale-eyes re-emit, CC-banner vs gated cc-update | `skills/nexus.watcher/SKILL.md` |
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
| An agent hits a bug or rough edge in a <your-lab>-authored **software tool** (kompot, Mellon, Crowding, Palantir, SEACells, …) and must route it to the code owner instead of silently working around it — the first-line-tester rationale, the tool → owner → routing table, and the "file on the owner's nexus asset repo + `@`-ping the owner" protocol (with the `dpeerlab/Palantir` external-upstream draft-and-review nuance) | `skills/nexus.tool-ecosystem/SKILL.md` |
| Installing a **private** GitHub package inside a worker (R `remotes::install_github`, `uv`/`pip` `git+…`, …) — authenticate with the user's `gh auth token` via `GITHUB_PAT`/`GITHUB_TOKEN`, NOT the bot's installation token (which 404s silently); fail loud when the PAT is unset | `skills/nexus.private-package-install/SKILL.md` |
| Enabling, operating, or connecting a client to the confined **remote agent channel** — the OFF-BY-DEFAULT in-sandbox SSH endpoint (`monitor/remote-up.sh`) that lets a LAN client file requests into the inbox and read its own reply; bind postures + fail-closed `from_cidr` pin, the out-of-band secret flow, token-gated pubkey self-enrollment, the copy-paste client prompt, rotate/revoke | `skills/nexus.remote-access/SKILL.md` |

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
asset+issue repo — `<lab-org>/<operator>-nexus`, resolved from
`config/nexus.yml`'s `github.repo`, not hardcoded;
**not** `<your-org>/nexus-code`, which is the canonical implementation
repo every operator clones);
`GH_TOKEN=$(./monitor/mint-token.sh) gh ...` for cross-repo or
verbs `ng` doesn't cover. Local files referenced from a comment go
through `ng upload` first — `reports/` is gitignored, so bare paths
404. Only `git commit` and `git push` may use the user's identity.
Verb table, install scope, fail-loud token guard, push-author
verify, asset-upload defaults: `skills/nexus.bot/SKILL.md`.

**The bot is the DEFAULT — but the wrapper is a BACKSTOP, not the
mechanism.** Lead with the explicit mint and verify the author:

    GH_TOKEN=$("$NEXUS_ROOT"/monitor/mint-token.sh) gh <write> …
    "$NEXUS_ROOT"/monitor/assert-bot-author.sh <url-of-your-write>

The worker floor says this and it is right: the PATH-front wrapper has
been observed BROKEN on a live clone — five operator-authored writes in
one day (`#497`). The failure is silent by construction, because an
operator-authored write SUCCEEDS and GitHub mutes the operator's own
notification, so the thread simply goes dark. `assert-bot-author.sh` is
the only loud check. Treat the wrapper as defence in depth for the
"on it —" ack you would otherwise fire off bare.

The wrapper itself: a PATH-FRONT `gh` wrapper (`monitor/ghwrap/gh`),
prepended to the front of `PATH` for every agent process
(`monitor/locals-env.sh` + a per-command force-front, shared via
`monitor/shellenv/front-path.zsh`, in `.zshenv` AND the interactive/login
proxies `.zshrc`/`.zprofile`/`.zlogin` — the last is what wins the race
against `~/.zshrc`'s linuxbrew re-prepend in the LOGIN+INTERACTIVE shell
Claude Code snapshots for its Bash tool; `#578`), plus a fail-CLOSED
spawn-time precondition (`monitor/assert-shims-wrapped.sh`;
`assert-gh-wrapped.sh` survives only as a deprecated forwarder) that every
agent launcher runs and refuses to spawn if the wrapper is unreachable in a
spawned shell — and exits `79` "NOT CHECKED", never `0`, when it could not
examine the shims at all (`#612`). It intercepts `gh`, and it picks the real
client by **capability, not identity** — the first candidate on `PATH` meeting
a declared version floor (`NEXUS_GH_MIN_VERSION`, default `2.86.0`;
`monitor/gh-capable.sh`), not merely the first one that is not itself. It used
to be the latter, which silently selected the agent-sandbox's `/app/bin/gh`
**1.13.0 (2021)** over an installed 2.89.0 whenever `PATH` ordered them that
way — and at 1.13.0 `gh run view --job <id> --log` returns ZERO lines at rc 0,
`gh run view <run> --log` returns two of ten jobs, and `gh pr checks` prints
`pass` for a check whose REST conclusion is `skipped` (`#755`). Five `gh`
clients are installed on this host; the truncation is **not** 1.x-only —
`2.14.7` also returns two of ten — which is why the floor sits at the oldest
version measured correct rather than at the major-version boundary. `gh api` is
byte-identical across both clients, which is why it remains the right call
shape whenever an empty answer would be meaningful. Classification is
**fail-CLOSED** (`#568` A3): each command group declares its READS
(`pr list|view|diff|checks|status|checkout`, `issue list|view|status`,
`api` without a mutation signal, the read-only/local groups `auth`,
`search`, `status`, `config`, …) and **everything else is a WRITE**,
including a subcommand no arm enumerates and a command group the shim
has never heard of. Writes auto-inject the bot token via
`mint-token.sh`; reads and `gh auth …` run as the OPERATOR, with the
operator's OWN gh config restored — `locals-env` scopes the ambient
`GH_CONFIG_DIR` to a credential-free dir (so an UNWRAPPED `gh` fails
CLOSED: "please run gh auth login"), and the wrapper re-supplies the
operator's real config for reads. So a read — INCLUDING of a PRIVATE
repo — succeeds on the operator's credentials with NO caller-supplied
token: do NOT hand-roll `GH_TOKEN=$(mint-token.sh) gh …` for a read.
An already-set `GH_TOKEN` is never overridden. The polarity used to be the
other way round, which routed `gh project item-create`, `gh codespace
create|delete`, `gh release delete-asset`, `gh repo deploy-key add` and
`gh agent-task create` through the OPERATOR's credentials — so the
"posts as the bot" promise was false for exactly the surfaces nobody
had enumerated yet. Because it is a real executable (not a zsh
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

The tiers are defined by RELATIONSHIP, not by a fixed list of
owners — this repo is cloned by every operator, so a hardcoded
username here would hand one operator's authorization rule to
somebody else (<your-org>/nexus-code#568 C7). Resolve `<lab-org>` and
`<operator>` from your own `config/nexus.yml` (`github.repo`,
`github.user_login`); the examples in parentheses are this
workspace's instantiation, not the rule.

- **Internal** — the lab org and the operator's own PRIVATE repos
  (`<lab-org>/*`, private `<operator>/*`; here `<your-org>/*`): no
  fresh approval per action.
- **User-public** — the operator's own PUBLIC repos
  (`<operator>/<their-project>`, …): standing approval for ongoing
  work the user explicitly initiated; new directions need a fresh
  ack.
- **External public** — anything the operator does not own, plus any
  fork of somebody else's project even under the operator's account
  (`<operator>/<external-fork>` — GitHub VISIBILITY and PROVENANCE,
  not account ownership, decide): every push / PR / issue / comment needs
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
the nexus repo afresh into `work/<nexus-repo>-<task>/` (or use a
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

**Nexus STATE always belongs to the primary, and is now routed
there automatically** (<your-org>/nexus-code#577). Running a
secondary clone's `monitor/spawn-worker.sh` used to re-root
`NEXUS_ROOT` to that clone, forking the whole state: the action
log, the skeptic require-markers and the reports corpus all
landed under `work/<clone>/` where nothing reads them, and a
completed skeptic's verdict could never clear the marker
blocking its target's retirement. `spawn-worker.sh` now honours
an inherited `NEXUS_ROOT` and otherwise detects a clone nested
under `<primary>/work/` structurally, re-rooting loudly;
`ng report-init` pins reports to `<primary>/reports` from any
cwd. Prefer the primary's launcher with `-c <clone>` anyway —
that has always been the intended form, and it is what the
prompt should say.

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
- **In zsh, `"$ref:path"` silently applies a HISTORY MODIFIER —
  always brace it: `"${ref}:${path}"`.** This workspace is
  zsh-default, so every agent is exposed, and double quotes do
  NOT protect you. When a literal modifier letter follows
  `$var:`, zsh eats it:

  ```zsh
  b=main
  print -r -- "$b:audit/f"     # → <cwd>/mainudit/f   (:a = absolute path)
  print -r -- "$b:results/f"   # → mainesults/f       (:r = remove extension)
  print -r -- "$b:tests/f"     # → mainests/f         (:t = tail)
  print -r -- "$b:src/f"       # → zsh: bad substitution, exit 1
  print -r -- "${b}:audit/f"   # → main:audit/f       CORRECT
  ```

  Note the two failure modes: `audit`/`results`/`tests` yield a
  silently WRONG but plausible path; `src` errors outright. The
  silent one is the problem. It only fires on a LITERAL modifier
  letter directly after `$var:` — `"$b:$p/f"` is safe, which is
  why it survives casual testing and ambushes the one call site
  that hardcodes a directory name. Colliding repo directory
  names are common: `audit/ results/ tests/ src/ experiments/
  hooks/ lib/ config/ utils/`.

  It also **breaks the prescribed remedy for the `git rev-parse`
  trap**: `git rev-parse <ref>:<path>` pollutes stdout on a
  missing path, so use `git cat-file -e` — but only ever as
  `git cat-file -e "${ref}:${path}"`. Unbraced, it manufactures
  a confident FALSE existence answer. `git ls-tree` disagreeing
  is what caught it; prefer it when a second opinion is
  warranted.
- **zsh does not word-split unquoted parameters** — `for f in
  $VAR` iterates ONCE over the whole string where bash would
  split it. Use `${=VAR}` (or an array). Same family as the
  modifier trap above: zsh-is-not-bash, failing silently with a
  plausible-looking answer rather than an error.
- **`mapfile` / `readarray` DO NOT EXIST IN ZSH, and the failure
  is an EMPTY ARRAY, not an error you will notice.** This
  workspace is zsh-default, so a `mapfile -t X < <(find …)`
  pasted into a Bash tool call is `command not found` (rc 127)
  and the script then carries on with `${#X[@]}` = 0:

  ```zsh
  mapfile -t X < <(printf 'a\nb\n'); echo "${#X[@]}"   # zsh → 0   (rc 127)
  bash -c 'mapfile -t X < <(printf "a\nb\n"); echo ${#X[@]}'  # → 2
  ```

  Measured on this host. The rc is visible only if you check it —
  and you usually do not, because the *next* command succeeds and
  its rc is what surfaces. So the enumeration silently returns
  zero.

  **This is dangerous specifically when a count feeds a CLAIM.** A
  skeptic enumerating this repo's test files this way got `0 test
  files` and would have published it (<your-org>/nexus-code#721).
  "Zero members found" then reads as "the population is empty" —
  the same shape as the `grep -r … reports/` silent zero above.

  Any enumeration behind a number you intend to assert must run
  under an explicit `bash -c` **and** be sanity-checked against a
  known total (`find monitor -name 'test-*.sh' | wc -l`). Use
  `while IFS= read -r` or `find -print0 | xargs -0` when you want
  something that works in both shells.
- **`git checkout <branch>` on the main clone silently breaks
  the running watcher** if the branch has changed
  `monitor/watcher/_*.sh` helper signatures. Functions in
  memory call functions on disk with mismatched arity → bash
  fails quietly → eligible-comments stop surfacing without any
  log error. Always operate in a separate clone under
  `work/<nexus-repo>-<task>/` (or a worktree); see "Spawning
  workers" above for full recovery steps.
- **Prefer `uv pip` over plain `pip`.** Inside `agent-sandbox`
  the wrapped `/app/bin/pip` can hang >5 min; `uv pip install`
  finishes in seconds. Use `uv pip` outside the sandbox too.
- **A recursive `grep -r … reports/` returns a SILENT zero.** The
  operator's interactive `grep` is a shell function wrapping
  `ugrep --ignore-files`, and `reports/.gitignore` is a bare `*`,
  so a recursive search over the reports corpus matches NOTHING —
  0 hits, no error — across ~1,660 files. An agent asking "has
  this happened before?" gets a confident, wrong "no". This is
  the workspace's own dominant defect class (silence used as a
  proxy for absence) living inside the search primitive. Do NOT
  trust a zero from `grep -r`/`-rl`/`-rn` over `reports/`. Use
  **`monitor/ng report-grep <pattern>`** (alias for a corpus
  search that fails LOUD: it exits 3 with a diagnostic instead of
  a false zero when the tree is invisible to the search). The
  hand-rolled ignore-file-blind forms, **exactly as they must be
  typed** — each is executed against a planted fixture by
  `monitor/watcher/test-claude-md-618-remedies.sh`, so this list
  is checked, not asserted:

  <!-- BEGIN 618-REMEDIES -->
  ```zsh
  monitor/ng report-grep -l PATTERN ROOT              # preferred: refuses a zero it cannot vouch for
  command grep -raIl PATTERN ROOT                     # `command` bypasses the grep FUNCTION
  grep --no-ignore-files -raIl PATTERN ROOT           # tells the ugrep wrapper to stop honouring .gitignore
  rg --no-ignore -l PATTERN ROOT
  find ROOT -name '*.md' -print0 | xargs -0 grep -aIl PATTERN
  ```
  <!-- END 618-REMEDIES -->

  **`xargs -0 command grep` is NOT among them.** `xargs` execs a
  *program*; `command` is a shell *builtin*, so that pipeline exits
  **127 having never run grep** — a silent zero under `2>/dev/null`,
  i.e. `#618` reproduced inside its own remedy (`#707`). The same
  fact is why the `xargs` form needs no `command` in the first
  place: `xargs` does not go through the shell, so the `grep`
  function is never in play. Nor should you guess an absolute path
  to dodge the wrapper — **`/usr/bin/grep` does not exist on this
  host** (`whence -p grep` → `/bin/grep`), and guessing it wrong is
  another confident zero. Explicit file arguments (including a
  shell-expanded `reports/*.md` glob) are NOT suppressed; only
  recursion into the gitignored tree is.
  See `<your-org>/nexus-code#618`, `#707`.
- **`git ls-tree` with a GLOB pathspec is a confident zero — use
  `git ls-files`.** Third member of the family above, and the one
  that bites hardest, because it fires inside the probe you wrote
  to *attack* an emptiness claim: a skeptic enumerating a
  population this way got `0`, and only a sanity-check against a
  known total caught it (`<your-org>/nexus-code#770`). `ls-tree`
  pathspecs are **path prefixes rooted at the given tree**, not
  globs; `ls-files` pathspecs are globs. Same repo, same ref, same
  pathspec — measured on this tree, and executed against it by
  `monitor/watcher/test-claude-md-lstree-pathspec.sh`, so this is
  checked, not asserted:

  <!-- BEGIN LSTREE-PATHSPEC -->
  ```zsh
  git ls-tree -r --name-only HEAD -- '*.sh'    # WRONG:   0 hits, rc 0
  git ls-files -- '*.sh'                       # CORRECT: every .sh tracked
  ```
  <!-- END LSTREE-PATHSPEC -->

  Verified identical on git 2.17.1 and 2.33.0. A bare
  `git ls-tree HEAD <dir>` is the second trap: without `-r` it
  prints the ONE tree object, so `wc -l` says `1` for a directory
  holding hundreds. Neither form errors. If you must read a
  non-HEAD ref, use `git ls-tree -r --name-only <ref>` with NO
  pathspec and filter the output — then sanity-check the total.
- **A value sampled across refs is a TIMELINE only if each ref is an
  ancestor of the next — `git show <ref>:<path>` is not history.**
  Fourth member of the confident-wrong-answer family, and the worst of
  them, because its output *looks* like evidence: a monotone count
  series reads as a narrative, and the narrative is usually the very
  thing you were trying to establish. `git show` answers "what did this
  tree contain", never "what happened in what order". Sampling a value
  at several refs and reading the series as history is sound **only**
  when the refs form a chain. Refs on divergent branches produce a
  well-formed series that answers a different question, and nothing
  errors.

  This has already published a wrong mechanism. Counting `shopt -u
  nullglob` in `monitor/ng` gave `f75d588 → 3`, `862a693 → 0`,
  `514b04d → 0`, `16728e7 → 1` — read as "`#791` fixed it and `#781`'s
  merge resurrected it". Measured, the function being counted **did not
  exist** on `#791`'s branch, so `#791` could not have fixed anything;
  `3 → 0` was two unrelated branch tips, not a repair. Both claims were
  retracted on `<your-org>/nexus-code#790`.

  Check before you read any such series as history — one line per
  adjacent pair, and it is cheap:

  <!-- BEGIN ANCESTOR-TIMELINE -->
  ```zsh
  git merge-base --is-ancestor "${A}" "${B}"   # rc 0 ⇒ B descends from A: this pair IS a timeline
  git show "${ref}:${path}"                    # brace ALWAYS — see the modifier trap above
  ```
  <!-- END ANCESTOR-TIMELINE -->

  Both lines are executed against a purpose-built divergent-vs-linear
  fixture by `monitor/watcher/test-claude-md-ancestor-timeline.sh`, so
  this block is checked, not asserted.

  The second line is not a digression. **The zsh history-modifier trap
  above fires on exactly this call**: `git show "$ref:results/count"`
  silently becomes `mainesults/count` (`:r` = remove extension), and
  `"$ref:tests/x"` becomes `mainests/x` (`:t` = tail) — a wrong-but-
  plausible path, no error, and you are now sampling a file that does
  not exist across refs that are not a timeline. Two silent failures
  compounding into one confident graph. Always
  `git show "${ref}:${path}"`.

  **The precondition is NECESSARY, NOT SUFFICIENT — and the residual trap
  bit inside this very entry's own PR.** `<your-org>/nexus-code#828` was
  filed blaming commit `f18fa91` for turning a lint red, on the strength
  of `git log -S '<the flagged text>' -- monitor/ng`. The ancestor check
  was run and it PASSED: the refs did form a chain. The claim was still
  wrong. `monitor/ng` was **byte-identical** across the whole range; what
  changed was the **lint** — the predicate — which had been broadened one
  merge later to see a construct that had been sitting there all along.
  `48/0` at `a1fe980`, `49/1` at `5feba19`, same blob.
  `-S` dates when the SUBJECT appeared; it cannot date the FAILURE when
  the PREDICATE also changed inside the range. So:

  > Vary the axis the MECHANISM varies on, not the axis your SEARCH
  > varied on. A value has at least two inputs — the thing measured and
  > the thing measuring it. Hold one constant and bisect the other; if
  > you cannot say which one you held constant, you have not bisected.

  The cheap check is a blob comparison: `git rev-parse "${A}:${path}"`
  versus `git rev-parse "${B}:${path}"`. Identical blobs mean the subject
  is exonerated and your explanation is somewhere else entirely.

  The positive control, recorded because it is the shape to copy:
  `<your-org>/nexus-code#774` builds exactly such a table — marker counts
  in `CHANGELOG.md` across seven merges — and its refs *are* a linear
  first-parent chain into `dev`, every one an ancestor of the next. Its
  non-monotonic reading therefore stands. Per-merge against a
  first-parent walk is sound; comparing branch TIPS is not.
  See `<your-org>/nexus-code#804`, `#790`, `#774`.
- **A COUNT IS A PROPERTY OF A TREE. Report the command AND the ref
  that produced it, or it is not checkable.** Same family as the entry
  above, one step sideways: that one is about reading a SERIES across
  refs as history, this one is about asserting a SINGLE count *about*
  a ref you did not measure. A bare number identifies nothing — carry
  it to another ref and it silently measures something else, and no
  step in that journey errors.

  The trap is that the most natural counting commands answer about
  **your checkout**, not about a ref. `git ls-files`, `find`, `wc -l`
  over a glob and any `grep -c` all read the index or the working
  tree. So "N files at `<ref>`" is true only when your checkout *is*
  `<ref>` — and a worker on a feature branch, or with one extra file
  added since, reports a number that is off by exactly that and looks
  entirely plausible.

  Two counting forms, and they answer different questions:

  <!-- BEGIN COUNT-PROVENANCE -->
  ```zsh
  git ls-files -- '*test-*.sh' | wc -l                          # YOUR CHECKOUT, never a ref
  git ls-tree -r --name-only "${ref}" | grep -c 'test-.*\.sh$'  # THAT ref — filter output, no glob pathspec
  git rev-parse --short "${ref}"                                # report this BESIDE the number, always
  ```
  <!-- END COUNT-PROVENANCE -->

  All three are executed against a purpose-built two-ref fixture by
  `monitor/watcher/test-claude-md-count-provenance.sh`, so this block
  is checked, not asserted. The second line filters `ls-tree`'s OUTPUT
  rather than passing a glob pathspec, for the reason two entries
  above: `ls-tree` pathspecs are path prefixes and a glob there is a
  confident zero.

  **The cross-check that agrees with itself is the sharp edge.** A
  count is often justified by reconciling it against a second source —
  "my enumeration returns N, and the tool self-reports N, so both
  measure the same thing". That reconciliation is worthless when BOTH
  sides were computed on the same unnamed tree: it confirms the two
  agree, never that either describes the ref being claimed. Reconciled
  numbers therefore need their ref stated exactly as hard as raw ones,
  and arguably harder, because agreement reads as verification.

  If a count is going into an issue, a report, or a comment, write the
  command and the ref next to it. A reader who cannot re-run your
  number cannot check it, and a number nobody can check is the same
  liability as a silent zero — this workspace's dominant defect class,
  arriving as a confident *few* rather than a confident none.
- **Worker pane state: use `monitor/pane-state.sh <window-index>`**
  (alias `ng pane-state <window-index>`)
  (it is **index-keyed** — `<window-index|session:window>`, NOT a
  window name; passing a name fails the lookup), never
  eyeball `tmux capture-pane`. Claude Code's autosuggest renders
  identically to user input in plain text. The helper emits
  `state=<idle|busy|user-typing|autosuggest-only|empty|blocked|absent|
  over-limit|working-background|working-self-paced|idle-orphan-async>
  active=<0|1> [queued=1]`. There are **twelve** states (`unknown` was
  added for "could not look at all"), not seven. The ones that used to
  be omitted are the dangerous omission: `working-background` and
  `working-self-paced` both mean **the worker is ACTIVE**, so an
  orchestrator matching a short list drops them into an else branch and
  retires a live worker — precisely the misread `retire-preflight.sh`
  Hard gate 0 exists to prevent (2026-06-15 incident).
- **Never make a kill decision from a state you enumerated by hand.**
  The failure above is structural, not a lapse of care: any denylist
  with a permissive default arm retires whatever its author did not
  think of. Ask `monitor/_bookkeeping.sh:bk_pane_kill_authorized`
  instead — an **allowlist** (`idle`, `autosuggest-only`, `absent`,
  `idle-orphan-async`) with a default-**deny** arm. In particular
  `empty` means **"don't know yet"**, never "finished": a pane 4m38s
  into a verification pass with a queued message read `empty`, and the
  documented escalation recipe would have killed it (`#603`). `absent`
  is the state that positively asserts a dead agent. A pane showing
  `queued=1` has input already waiting behind a running turn — do not
  paste into it again, and never read a missing `UserPromptSubmit` as
  a lost paste while one is in flight (`#607`).
- **The same rule for PROCESSES, where the information you would filter
  on does not exist.** A worker stopping its own oversized test run built
  a kill list by `grep -v`-ing a few sibling clone names out of `ps` and
  killing the rest — and reaped SIBLING agents' runs (two legs dead
  `EXIT=143` mid-run, `#851`). **Name and path matching cannot work
  here**: sibling suites are invoked cwd-relative
  (`bash monitor/watcher/run-tests.sh --jobs 4`), so their `args` carry no
  clone path at all and are **byte-identical** to yours; a deleted cwd,
  routine for fixture-spawned processes, removes path attribution too. So
  every name-based predicate has a permissive default arm *by
  construction*. Ask **`monitor/proc-kill-authorized`** instead — session
  ownership, allowlist, default-**deny**:

  ```zsh
  kill $(ps -eo pid=,args= | awk '/run-tests\.sh/ {print $1}' \
           | "$NEXUS_ROOT"/monitor/proc-kill-authorized --filter)
  ```

  Note this composes with the `pkill-self` guard rather than replacing it:
  that one stops a `-f` match from riding your own argv, this one drops the
  pids you do not own. Neither subsumes the other — a `pgrep -f` whose
  pattern appears in your prompt matches YOUR claude process, and the
  filter refuses it as `self`, but you should not have matched it at all.

  `--filter` is the form that matters: the failure was not one wrong pid,
  it was a hand-rolled **list**. It prints only pids whose session is
  yours, names every refusal on stderr, and exits 1 when it dropped
  anything — so an empty result is loud rather than "nothing to do".
  Ancestry (`ppid`) is the wrong primitive and was measured so: a
  reparented process has `ppid` 1 while its **session survives**, so a
  parent walk refuses the very runaways you own. Note the deliberate
  false refusals — anything `setsid`-detached (the watcher, every
  registered service) is its own session leader and is never authorised;
  stop those with `monitor/svc.sh`.
- **"Is that text at the prompt an operator draft?" — read `input=`,
  never the rendering.** Autosuggest renders identically to typed input
  in PLAIN text, which is why eyeballing `capture-pane` is banned; it
  does NOT render identically in SGR. `pane-state.sh` now emits
  `input=<typed|ghost|blank|?>`: typed input carries bright white
  (`38;5;231`), a ghost carries faint (SGR 2). Before this, nineteen
  ghost panes at once all read `state=empty`, and the fallback heuristic
  (`-- INSERT --` + a non-blank row ⇒ draft) is **unsound** — it stalled
  the board for thirty minutes on ghosts (`#626`). `input=?` means a
  non-blank row matching neither marker: genuinely undecidable from
  bytes, so treat it as a draft.
- **Before you push a change under `monitor/`, ask which guards READ
  it — `ng guards-for-diff`.** Reach for it in the gap between "I ran
  the suites near my edit and they passed" and `git push`: that gap is
  where this has bitten three times in one night. A PR's green covers
  the suites its DIFF TOUCHES, not the suites its CHANGE AFFECTS, and
  the guards that catch you are the ones keyed on a **source
  construct** rather than a directory — `mapfile` use, early-exit
  readers, spawn shape, summary honesty. Their populations are
  repo-wide, so an edit anywhere can join one, and you cannot consult
  a guard you do not know exists. Selection is by what a guard READS,
  not by what your edit affects.

  <!-- BEGIN GUARDS-FOR-DIFF -->
  ```zsh
  monitor/ng guards-for-diff              # which registered guards read your changed files
  monitor/ng guards-for-diff --run        # …and run exactly those, reporting each verdict
  ```
  <!-- END GUARDS-FOR-DIFF -->

  Read the exit code, because two of them are not clearances: **3 = no
  registered guard reads your diff**, which is a measured answer and
  **not** a green light, and **2 = REFUSED** (a guard's population
  probe errored — fail-closed, because an index that silently drops a
  guard it could not ask looks exactly like one that had nothing to
  say). It is **not a substitute for the full suite**: most suites
  declare no population and are invisible to it. It prints that blind
  spot as a count on every run — read *that* line rather than any
  ratio quoted here, which is why none is: the enrolled-vs-tracked
  figure moved within a single day while `#834` was open, and a number
  pinned in this file would have been wrong before it was read.

## Shared infrastructure

If you run on shared infrastructure (HPC cluster, batch
scheduler, lab GPU pool), be efficient: test before scaling,
right-size resource requests, reuse intermediate results, and
prefer the appropriate partition/queue for the job size.
