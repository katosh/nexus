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
| Spawning a worker for any nexus delegation — prompt-file pattern, follow-ups, VI hazard, per-spawn context curation, fix-at-source | `skills/nexus.tmux-spawn/SKILL.md` |
| Spawning a worker that requires/allows/denies a skeptic pass, deciding at wrap-up whether one is warranted, or acting AS a skeptic — three spawn modes (`require\|auto\|deny`), wrap-up enforcement, the worker↔skeptic channel | `skills/nexus.skeptic/SKILL.md` |
| Closing a worker window, or reading a pane's TRUE state before you kill or paste into it (`state=`, `input=`, autosuggest vs a real operator draft) — close/retain rules, pre-close report check, kill mechanism (orchestrator-exclusive) | `skills/nexus.window-cleanup/SKILL.md` |
| Responding to a watcher `--- service health ---` emit — restore first, dispatch a reversible root-cause fix, open an incident issue, close the loop | `skills/nexus.service-recovery/SKILL.md` |
| Operating or diagnosing the watcher — liveness by the UP/BUSY/WEDGED/DOWN verdict (NOT `watcher.log` mtime, and NOT a fresh heartbeat alone: WEDGED is alive-but-not-advancing), recovery recipes by failure signature, phantom-window resurrection, eyes-ack | `skills/nexus.watcher/SKILL.md` |
| Editing the always-applies worker safety floor (injected into every spawn prompt from the `## Worker floor` section) | `skills/nexus.worker-defaults/SKILL.md` |
| Making any GitHub write — PR, issue, comment, reaction, wiki upload; `ng` verbs, install scope, push-author verify, how the `gh` wrapper picks its client, and READING A USER-PASTED `user-attachments` ASSET (fetching one directly poisons the session) | `skills/nexus.bot/SKILL.md` |
| Delivering an instruction to an agent and knowing whether it ARRIVED — `ng send`, per-agent transport + receipt, the one common ledger, the exclusivity rule | `skills/nexus.agent-delivery/SKILL.md` |
| Writing or reviewing a report under `reports/` — sections, the infra-issue feedback loop | `skills/nexus.report/SKILL.md` |
| Grounding scientific work in the literature — `ng lit search` over S2 + ASTA + OpenAlex deduped against the reference library, `ng lit add`, citation convention | `skills/nexus.lit/SKILL.md` |
| Running periodic infrastructure meta-review across reports | `skills/nexus.infra-review/SKILL.md` |
| Fixing the nexus itself — orchestrator, watcher, monitor scripts, skills; the pre-flight gate before filing on `<your-org>/nexus-code`. Also: writing or changing a guard or test suite HERE (fixture-repo preconditions), adding a value to an existing field in `monitor/` state (a field that SELECTS is not a label), and what `ng guards-for-diff` does and does not clear before you push under `monitor/` | `skills/nexus.self-fix/SKILL.md` |
| Scheduling a multi-fire `CronCreate` whose state must survive an orchestrator respawn | `skills/nexus.cron-state-tsv/SKILL.md` |
| A user asks for a jupyter(lab)/notebook session, or a project needs a persistent kernel | `skills/nexus.jupyter/SKILL.md` |
| Seeding or maintaining the overview issue `#1` identity record + dashboard | `skills/nexus.dashboard/SKILL.md` |
| Evaluating a candidate Claude Code release before bumping the pin (orchestrator-only; a path-referenced guide, deliberately not auto-loaded) | `skills/nexus.cc-update/GUIDE.md` |
| Routing a bug in a <your-lab>-authored tool (kompot, Mellon, Crowding, Palantir, SEACells, …) to its code owner instead of working around it | `skills/nexus.tool-ecosystem/SKILL.md` |
| Installing a **private** GitHub package inside a worker — the user's `gh auth token`, never the bot's installation token (which 404s silently) | `skills/nexus.private-package-install/SKILL.md` |
| Enabling, operating or connecting a client to the confined remote agent channel | `skills/nexus.remote-access/SKILL.md` |
| A PR's CI has gone RED and you do not yet know whether the base or your diff did it — check `dev` in isolation first, the unique-per-caller worktree recipe, what a worktree's missing gitignored/untracked files hide, and why `ci-signal` green is not merge clearance | `skills/nexus.ci-triage/SKILL.md` |
| You are about to PUBLISH A CHECKABLE CLAIM — a count, a `path:line`, a timeline across refs, a set membership — in an issue, a PR body, a comment, a report or a skeptic verdict, and the enumeration behind it has to be able to say which direction it errs in | `skills/nexus.claims/SKILL.md` |
| A computation will OUTLIVE the 30-minute `Monitor` cap (a Slurm job, a 40-minute test suite, a multi-hour script) and you need to be WOKEN when it ends, fails, or hits a custom event — `ng longjob run -- <cmd>`, auto-watched `sbatch`, `add slurm:\|asyncrun:\|pid:\|file:\|cmd:`, and what happens when the watch does NOT fire (`add` says NOT ARMED at rc 3; `await` under `run_in_background` is the fallback) | `skills/nexus.longjob/SKILL.md` |

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
before finishing, going idle, or under context pressure — it is the
resumption surface if your session crashes. Use `nexus` for the
`{project}` slot when the work spans projects.

`monitor/ng report-init <slug>` writes a frontmatter'd skeleton at
that exact path, capturing your session-id and tmux window.
`monitor/ng report-check` enforces the schema.
`monitor/ng wrap-up <issue> <report-path> …` is the canonical
hand-off: it runs `report-check` as a pre-flight, uploads the
report to the asset repo, posts a templated link comment, rockets
the trigger comment given `--trigger-comment`, and logs the event
for the orchestrator's window-cleanup loop. Section semantics,
the append-only convention and the `## Infrastructure Issues`
feedback loop: `skills/nexus.report/SKILL.md`.

## GitHub writes — identity and authorization

Two questions per write: **WHO** posts (always the bot) and
**WHETHER** to post (depends on the target repo's tier).

**WHO — always the bot, never the user's `gh`.** GitHub mutes
notifications for actions taken by the recipient's own account, so
a PR/issue/comment posted as the user silently fails to wake them.
Use `monitor/ng <verb>` for the nexus repo (`github.repo` — the
asset+issue repo, resolved from `config/nexus.yml`, **not**
hardcoded and **not** `<your-org>/nexus-code`, which is the canonical
implementation repo every operator clones); a minted token for
cross-repo work or verbs `ng` doesn't cover. Local files referenced
from a comment go through `ng upload` first — `reports/` is
gitignored, so bare paths 404. Only `git commit` and `git push` may
use the user's identity.

**Lead with the explicit mint and verify the author** — the
PATH-front `gh` wrapper is a BACKSTOP, not the mechanism:

    GH_TOKEN=$("$NEXUS_ROOT"/monitor/mint-token.sh) gh <write> …
    "$NEXUS_ROOT"/monitor/assert-bot-author.sh <url-of-your-write>

The wrapper has been observed BROKEN on a live clone — five
operator-authored writes in one day (`#497`). The failure is silent
by construction: an operator-authored write SUCCEEDS and GitHub
mutes the operator's own notification, so the thread simply goes
dark. `assert-bot-author.sh` is the only loud check. How the
wrapper works, which client it selects and why, its fail-CLOSED
read/write classification, the `GH_IMPERSONATE` opt-in, and the
measured `gh` client traps (a stale client returns a ZERO-line job
log at rc 0; `gh run view --job <id> --log` serves the run's LATEST
attempt regardless of the job id, so read a job log with
`gh api repos/O/R/actions/jobs/<id>/logs`):
`skills/nexus.bot/SKILL.md`.

**WHETHER — by repo tier.** The tiers are defined by RELATIONSHIP,
not by a fixed list of owners: this repo is cloned by every
operator, so a hardcoded username here would hand one operator's
authorization rule to somebody else (`#568` C7). Resolve
`<lab-org>` and `<operator>` from your own `config/nexus.yml`
(`github.repo`, `github.user_login`).

- **Internal** — the lab org and the operator's own PRIVATE repos:
  no fresh approval per action.
- **User-public** — the operator's own PUBLIC repos: standing
  approval for ongoing work the user explicitly initiated; new
  directions need a fresh ack.
- **External public** — anything the operator does not own, plus
  any fork of somebody else's project even under the operator's
  account (GitHub VISIBILITY and PROVENANCE decide, not account
  ownership): every push / PR / issue / comment needs a fresh,
  specific user go-ahead, and worker prompts default to "draft +
  STOP for review". Before any external-public write, grep the
  draft for internal identifiers (lab names, study names, sample
  IDs, treatment names, cell/clone counts, internal-repo refs) and
  redact.

The orchestrator picks the tier at spawn time and surfaces the
relevant rule into the worker prompt — workers act on their
target's rule, not the whole taxonomy.

## Spawning workers — tmux, never the in-process `Agent` tool

For any nexus delegation, spawn a tmux window via the prompt-file
+ launcher pattern in `skills/nexus.tmux-spawn/SKILL.md`. Use the
in-process `Agent` tool only for tight, bounded research that
stays in your own thinking loop — never for nexus delegations.

If you find yourself orchestrating, delegate. If the action would
land in a worker's "What Was Done", run it in a worker's window.
Read-only orchestration (`tmux list-windows`, dashboard pushes,
bootstrap) is coordination.

**Watcher-touching work needs a separate clone. Never `git
checkout <branch>` on the main clone while the watcher is
running.** The watcher (`monitor/watcher/main.sh`) sources
`_github.sh`/`_lib.sh`/`_unstick.sh` once at startup; checking out
a branch with diverged helper signatures silently breaks
`snapshot_github` — functions in memory call functions on disk
with mismatched arity, bash fails quietly, and eligible-comments
stop surfacing with no log error. Workers touching
`monitor/watcher/*` MUST clone the nexus repo afresh into
`work/<nexus-repo>-<task>/` (or use a worktree). After a
watcher-affecting change lands, the orchestrator `git pull`s in
the main clone — that is the whole step: the version-aware watcher
detects its source-set drift and self-restarts
(`monitor/watcher/_version_restart.sh`, `#186`). A manual
`monitor/svc.sh restart watcher` is needed only when that is
disabled or the running watcher predates the module. The watcher
runs headless; its log is `monitor/.state/watcher.log`.

## Overview issue is routing-only

The Nexus overview issue (`<github.repo>` issue tagged
`nexus:overview`, typically `#1`) is **routing-only**. Never carry
content discussion or per-task back-and-forth there — every
actionable thread lives in its own issue or PR.

When a user comment on the overview initiates new work or asks a
content question, do not reply with content there. Spawn a
dedicated worker AND open a dedicated tracking issue
(`monitor/ng issue create`); link it from the overview with a
one-liner ("dispatched to `<window>`, tracking at `#N`"). The
worker comments back on the dedicated issue. Carry-over
confirmations stay ultra-terse — with many parallel projects in
flight, the overview gets unfollowable when content threads pile
up alongside routing comments.

## Independent clones for parallel work

When agents could collide on the same project — two workers
editing the same `work/<project>`, or a worker editing files the
running watcher reads — operate on **separate clones**, not on the
shared tree. Lockfiles are not the mechanism; isolation is.

- **Fresh clone** — `git clone <remote> work/<project>-<task>/`.
  Fully isolated `.git` and working tree; use when the task
  touches data the primary reads.
- **Worktree** — `git -C work/<project> worktree add
  ../<project>-<task> -b <operator>/<task>`. Lighter; shares
  `.git`. Default for code-only edits.

When the worker runs in a **secondary clone**, say so explicitly in
its prompt. Secondary clones edit and test freely; writes that need
to land in canonical state route through the primary or via PR.

**Nexus STATE always belongs to the primary, and is routed there
automatically** (`#577`). A secondary clone's
`monitor/spawn-worker.sh` used to re-root `NEXUS_ROOT` to that
clone, forking the whole state — the action log, the skeptic
require-markers and the reports corpus landed where nothing reads
them, and a completed skeptic's verdict could never clear the
marker blocking its target's retirement. `spawn-worker.sh` now
honours an inherited `NEXUS_ROOT` and otherwise detects a nested
clone structurally; `ng report-init` pins reports to the primary
from any cwd. Prefer the primary's launcher with `-c <clone>`
anyway — that is the intended form.

## Common gotchas

Workspace-wide traps that have bitten spawned workers more than
once. Pull the relevant ones into worker prompts when delegating.

Each entry is the RULE, the measurement that makes it credible, and
the remedy. Where an entry carries a `BEGIN`/`END` marker pair, a
suite OWNS that block and `monitor/watcher/claude-md-markers.manifest`
names it. Usually the fenced forms are EXTRACTED and RUN against a
planted fixture, so the block is CHECKED, not asserted — the one pair
carrying no fence at all (`WINDOW-KEY-VOCABULARY`) has its CLAIMS
driven against the real tools instead. Either way the block is the
part to copy and the part not to reword. The incident history behind
each entry lives on the issue it cites.

**They are nearly all one family, named here so the entries need not
keep re-deriving it: a tool answers CONFIDENTLY, at rc 0, with nothing
on stderr, and the answer is wrong in a shape that reads as normal.**
The recurring shapes are a **silent zero** (a confident *none* meaning
*none my predicate can see*), a **short count** (worse than a zero,
which is at least suspicious), a **plausible over-count** (a bigger
number reads as thoroughness), a **confident uniform value** (the same
answer for every item usually means the probe answered about their
CONTAINER), and a **manufactured success** — the worst, because every
visible artefact says the work was done and the only evidence is an
absence. Two habits cover most of them: **sanity-check any number you
intend to assert against an independently derived total**, and **read
the status of the step that could fail, not the one that just ran**.
When such a number is about to be published, open
`skills/nexus.claims/SKILL.md`.

### GitHub writes and the board

- **`#N` in a GitHub body auto-links, and a BACKTICKED `` `#N` `` creates
  NO cross-reference event** (`#1396`). Don't use `#1`, `#2`, … as
  numbered-list markers — every item becomes a link; use `1.`, bullets
  or `(1)`. `owner/repo#N` for cross-repo. Measured on two live PRs:
  eleven backticked `#N` and one in the TITLE produced zero
  `cross-referenced` events on the two issues the PR fixed, while a bold
  `**#N**` produced one each. So a PR body or comment must carry at least
  one issue number BARE or bold, or the issue reads as "nobody is working
  on this" — the dominant defect on the one surface an agent consults to
  ask exactly that. Key an automated ownership check on
  `gh pr list --search`, which sees backticked PRs, never on the issue's
  cross-reference list.
- **`github.com/user-attachments/…` URLs poison the session.** An external
  fetcher agent 404s; feeding that failure through Read-as-image returns
  400, which silently disables every subsequent image fetch in the
  conversation. NEVER hand one to a sub-agent or to Read. Use
  `monitor/ng fetch-asset <url>` (it reads the user's PAT — the bot's
  installation token 404s on this surface) and Read the local file:
  `skills/nexus.bot/SKILL.md` "Reading user-pasted assets".

### git

- **`git checkout <ref> -- <path>` overwrites the working tree
  without warning** — destructive on a dirty tree. For read-only
  peeks at content at another ref, use `git show <ref>:<path>`.
- **`git -C <non-repo>` WALKS UP and answers about the ENCLOSING repository
  at rc 0 — and `--is-inside-work-tree` CERTIFIES IT AS FINE**
  (`<your-org>/nexus-code#1196`, `#1080`, `#1174`). Git does not fail on a
  directory that is not itself a repository; it answers about the nearest
  enclosing one, and **in a nexus that is always the nexus itself**, because
  every analysis tree lives under `work/`. Measured 2026-09-01: **57 of 925**
  top-level `work/` directories are not their own repository, and every one
  reports the nexus's HEAD as its own.

  <!-- BEGIN REPO-WALKUP -->
  ```zsh
  git -C DIR rev-parse HEAD                    # WALKS UP: a valid sha at rc 0 — the ENCLOSING repo's
  git -C DIR rev-parse --is-inside-work-tree   # `true`, TRUTHFULLY — and it certifies the wrong thing
  git -C DIR rev-parse --show-toplevel         # DISCRIMINATOR: unequal to DIR ⇒ you are reading an ANCESTOR
  git -C DIR rev-parse --show-prefix           # DISCRIMINATOR: NON-EMPTY ⇒ you are BELOW the root
  monitor/repo-root.sh DIR                     # THE ANSWER: verdict=yes|no kind= top= reason=
  ```
  <!-- END REPO-WALKUP -->

  `--is-inside-work-tree` is the first thing a careful author reaches for and
  it is the one that lies, because it answers a true question you did not ask.
  `monitor/repo-root.sh` is the form to prefer: fail-closed and three-valued,
  so *"I could not tell"* is not silently *"no"*. The same walk-up is a WRITE
  hazard one script over (`#1080`) and a silent-hook hazard in a third place
  (`#1174`).

  **HOW IT WAS CAUGHT IS THE TRANSFERABLE PART: by UNIFORMITY.** Nine analysis
  trees shared one sha, and nine independent trees agreeing to the character is
  not a plausible measurement — nothing errored, and the SHAPE of the answer
  was the only tell. **When a per-item probe returns the SAME value for every
  item, suspect it answered a question about their CONTAINER rather than about
  them**: the inverse of the silent-zero family, a confident uniform *value*
  that reads as consistency.
- **`git -C ""` and `cd ""` are NO-OPS — a fixture path that expanded EMPTY
  aims git at the ENCLOSING repository and WRITES there at rc 0**
  (`<your-org>/nexus-code#1429`). The walk-up trap's empty-string cousin, and the
  one `--show-toplevel` cannot catch, because the command never left the
  repository you are standing in. In a suite, call
  `th_require_fixture_repo "$dir"` (`monitor/watcher/_test_helpers.sh`) before
  the first git command against a fixture: it refuses an empty path, a
  non-directory, and a directory that is not its OWN repository root, at exit
  97 — so the refusal cannot be read as an assertion failure. Detail:
  `skills/nexus.self-fix/SKILL.md`.
- **NEVER write the operator's GLOBAL git config from a probe — it IS
  writable, and nothing validates a commit's author**
  (`<your-org>/nexus-code#1244`). Measured 2026-09-05: `ls -la ~/.gitconfig`
  reports `-rw-rw-rw-` and `[ -w ~/.gitconfig ]` succeeds. It has fired twice;
  two commits authored `d@e` have been ancestors of `origin/dev` since
  2026-08-15 while NOT being in `origin/main`, so a promotion carries them
  across. **The failure has no artefact**: `git commit` does not validate an
  author, the push succeeds, CI does not look, and `assert-bot-author.sh`
  checks GitHub API writes rather than git commits. In a probe use
  `git -c user.email=… <cmd>` or `--local`; never the global file. There is no
  tracked writer to fix, so this line is the whole defence.

### zsh is not bash

- **In zsh, `"$ref:path"` silently applies a HISTORY MODIFIER — always brace
  it: `"${ref}:${path}"`.** This workspace is zsh-default and double quotes do
  NOT protect you. Re-measured 2026-09-05:

  ```zsh
  b=main
  print -r -- "$b:audit/f"     # → <cwd>/mainudit/f   (:a = absolute path)
  print -r -- "$b:results/f"   # → mainesults/f       (:r = remove extension)
  print -r -- "$b:tests/f"     # → mainests/f         (:t = tail)
  print -r -- "$b:src/f"       # → zsh: bad substitution, exit 1
  print -r -- "${b}:audit/f"   # → main:audit/f       CORRECT
  ```

  Two failure modes, and the silent one is the problem: `audit`/`results`/
  `tests` yield a plausible WRONG path, `src` errors outright. It fires only
  on a LITERAL modifier letter directly after `$var:` — `"$b:$p/f"` is safe,
  which is why it survives casual testing and ambushes the one call site that
  hardcodes a directory name. Colliding directory names are common: `audit/
  results/ tests/ src/ experiments/ hooks/ lib/ config/ utils/`. It also
  breaks the prescribed remedy for the `git rev-parse` trap: use
  `git cat-file -e "${ref}:${path}"`, braced — unbraced it manufactures a
  confident FALSE existence answer, and `git ls-tree` disagreeing is what
  caught it.
- **`mapfile` / `readarray` DO NOT EXIST IN ZSH, and the failure is an EMPTY
  ARRAY, not an error you will notice.** A `mapfile -t X < <(find …)` pasted
  into a Bash tool call is `command not found` (rc 127) and the script carries
  on with `${#X[@]}` = 0. Re-measured 2026-09-05:

  ```zsh
  mapfile -t X < <(printf 'a\nb\n'); echo "${#X[@]}"          # zsh → 0   (rc 127)
  bash -c 'mapfile -t X < <(printf "a\nb\n"); echo ${#X[@]}'  # → 2
  ```

  The rc is visible only if you check it, and you usually do not, because the
  *next* command succeeds and its rc is what surfaces. **This is dangerous
  specifically when a count feeds a CLAIM**: a skeptic enumerating this repo's
  test files this way got `0 test files` and would have published it (`#721`).
  Any enumeration behind a number you intend to assert runs under an explicit
  `bash -c`. Use `while IFS= read -r` or `find -print0 | xargs -0` for
  something that works in both shells.

### Searching — this workspace's dominant defect class is a silent zero

- **A recursive `grep -r … reports/` returns a SILENT zero.** The operator's
  interactive `grep` is a shell function wrapping `ugrep --ignore-files`, and
  `reports/.gitignore` is a bare `*`, so a recursive search over the reports
  corpus matches NOTHING — 0 hits, no error — across thousands of files. An
  agent asking "has this happened before?" gets a confident, wrong "no". Use
  **`monitor/ng report-grep <pattern>`**, which exits 3 with a diagnostic
  instead of vouching for a zero it cannot see. The ignore-file-blind forms,
  exactly as they must be typed:

  <!-- BEGIN 618-REMEDIES -->
  ```zsh
  monitor/ng report-grep -l PATTERN ROOT              # preferred: refuses a zero it cannot vouch for
  command grep -raIl PATTERN ROOT                     # `command` bypasses the grep FUNCTION
  grep --no-ignore-files -raIl PATTERN ROOT           # tells the ugrep wrapper to stop honouring .gitignore
  rg --no-ignore -l PATTERN ROOT
  find ROOT -name '*.md' -print0 | xargs -0 grep -aIl PATTERN
  ```
  <!-- END 618-REMEDIES -->

  **`xargs -0 command grep` is NOT among them.** `xargs` execs a *program* and
  `command` is a shell *builtin*, so that pipeline exits **127 having never run
  grep** — `#618` reproduced inside its own remedy (`#707`). The same fact is
  why the `xargs` form needs no `command`: `xargs` does not go through the
  shell. Nor should you guess an absolute path to dodge the wrapper —
  `/usr/bin/grep` does not exist on this host.

  **And `reports/*.md` IS DEPTH-BLIND, a second blind spot inside this entry's
  own remedy list** (`#1198`). A shell glob is not ignore-file-blind, but it
  does not descend, and a long-lived corpus gets archived into dated
  subdirectories as ordinary housekeeping — so the glob's share SHRINKS EVERY
  MONTH with no error. Measured 2026-09-01 under `bash -c`: `find reports
  -maxdepth 1 -name '*.md'` → 715 against `find reports -name '*.md'` → 3,293.
  `report-grep` recurses and is correct on both axes; the glob answers about
  one level. See `#618`, `#707`, `#1198`.
- **IF YOUR SHELL WRAPS A COREUTIL IN A FUNCTION OR ALIAS, A REJECTED ARGUMENT
  COMES BACK AS A SILENT ZERO** (`<your-org>/nexus-code#849`). The generalisation
  of the entry above: a shell FUNCTION shadowing a coreutil routes your command
  to a different implementation with different argument semantics; the
  rejection lands on stderr, agents habitually append `2>/dev/null`, and the
  answer is a silent zero.

  **THIS ENTRY IS CONDITIONAL, AND THAT IS DELIBERATE.** The exposure depends
  on the operator's own shell config and on which implementation is installed.
  A shared file telling every clone-holder they have a defect contingent on one
  operator's config would itself be this class, one level up. So what is pinned
  is the DETECTION and the REMEDIES, never "the broken form returns zero". It
  is per-SHELL, not per-host, which is why a probe and the code it checks can
  disagree for no reason but how each was invoked:

  <!-- BEGIN SHELL-WRAPPED-COREUTIL -->
  ```zsh
  whence -w find grep sort head              # zsh:  "find: function" means YOU are exposed
  type -t find grep sort head               # bash: "function"/"alias" likewise
  bash -c "find DIR -name '*.md' | wc -l"   # REMEDY: a non-interactive bash never loads the wrapper
  command find DIR -name '*.md' | wc -l     # REMEDY: bypass the function — a BUILTIN, so NOT usable through xargs
  find DIR -name '*.md' -mmin -720 | wc -l  # REMEDY: prefer argument forms with no dialect variance
  ```
  <!-- END SHELL-WRAPPED-COREUTIL -->

  Measured on the reporting host, 2026-09-01: `whence -w find` → **function**,
  routing to `bfs` 4.1.1, while `whence -p find` says `/usr/bin/find` — GNU
  findutils 4.7.0. `bfs` rejects the relative timestamps GNU accepts, so
  `-newermt '12 hours ago'` returns 0 at rc 1 where `-mmin -720` returns 5.
  That zero was one step from filing a phantom that would have sent a worker to
  fix a working pipeline; an independent total disagreeing is what caught it.

  **AND THE SECOND TRAP IS INSIDE THE FIRST PROBE.** `cmd 2>&1 | wc -l` counts
  DIAGNOSTICS AS DATA — a plausible file count that was ten lines of error
  text. Two rules that hold whatever is wrapped: **sanity-check a zero against
  an independently derived total**, and **never let stderr into a number**.
- **`grep -h` OVER SEVERAL FILES RETURNS THE RIGHT LINES IN THE WRONG ORDER
  under the ugrep wrapper — an ORDERING corruption at rc 0, and `-h` is the
  flag that removes the evidence** (`<your-org>/nexus-code#1461`). Not argument
  ACCEPTANCE this time but OUTPUT ORDER: ugrep's default `--sort` orders
  multi-file output alphabetically BY FILENAME and discards the order the
  caller supplied; GNU `grep` preserves argument order. Nothing errors, stderr
  is empty, and **the total is unchanged** — so the habit named in the preamble
  is not looking anywhere near it: this one returns everything, correctly,
  permuted.

  <!-- BEGIN GREP-H-ORDER -->
  ```zsh
  grep -H PAT a b            # REMEDY: keep the filenames — the order is then CHECKABLE
  command grep -h PAT a b    # REMEDY: bypass the shell function; GNU preserves argument order
  grep --no-sort -h PAT a b  # NOT a remedy: neither argument order nor alphabetical — do not write it down as the fix
  ```
  <!-- END GREP-H-ORDER -->

  **The coupling is the trap.** `-h` is exactly the flag you reach for to put
  one line from each of two files side by side — *which copy carries the
  narrowed pattern?* — and exactly the flag that strips the filenames that
  would let you see the swap. It produced the exact inverse of the truth in a
  skeptic pass, and re-reading the two lines — the only check anyone applies to
  a two-line comparison — confirms the wrong answer. **A wrapper can differ
  from the tool it shadows in the ORDER of a complete, correct answer, not
  only in which arguments it accepts.**
- **`grep -v '^\+\+\+'` DELETES EVERY ADDED LINE — in BRE, GNU's `\+` is the
  ONE-OR-MORE OPERATOR** (`<your-org>/nexus-code#1158`). `^\+\+\+` means *one-or-
  more `+`, three times*, so under `-v` it deletes precisely the lines the
  pipeline exists to keep.

  <!-- BEGIN GREP-BRE-DIALECT -->
  ```zsh
  grep -c  '^\+\+\+' DIFF          # WRONG: 3 — BRE \+ is ONE-OR-MORE, so EVERY +-prefixed line matches
  command grep -v '^\+\+\+' DIFF   # WORSE: keeps 1 of 4 — same wrong answer, and now nothing can complain
  grep -cE '^\+\+\+' DIFF          # CORRECT: 1 — in ERE, \+ is a literal +
  grep -cF '+++'     DIFF          # CORRECT: 1 — and it says what it means
  grep -c  'x=$(cmd'  SRC          # GNU BRE: 1, a mid-pattern $ is LITERAL — the ugrep wrapper: 0, rc 1, stderr EMPTY
  command grep -c 'x=$(cmd' SRC    # 1 — HERE bypassing the wrapper is the remedy: the polarities of the lines above, REVERSED
  grep -c  'x=\$(cmd' SRC          # CORRECT in both: 1 — escape the $
  grep -cF 'x=$(cmd'  SRC          # CORRECT in both: 1 — -F is the ONE remedy the two halves of this block share
  ```
  <!-- END GREP-BRE-DIALECT -->

  **THE INVERSION IS THE ENTRY, not the regex fact.** A wrapper that rejects
  the pattern makes this LOUD; `command grep`, prescribed a few lines above as
  the remedy for the recursive-search family, bypasses a shell function *by
  construction*, so the diagnostic is unreachable. **A remedy that makes a
  defect harder to see is worse than no remedy**, and this one sits inside the
  same list. The two facts that settle which `grep` you have, because a bare
  absence check cannot see the second:

  ```zsh
  command -v ugrep            # NOTHING — no standalone binary. NOT the answer.
  type grep                   # `grep is a shell function` — from Claude Code's shell snapshot
  grep --version | sed -n 1p  # ugrep 7.8.4 — the function runs ugrep EMBEDDED in the `claude` binary
  ```

  Deliberately an UNMARKED fence: a `BEGIN`/`END` marker here is a promise that
  a suite executes the block, and this one answers differently on another
  operator's harness build. Do not add markers to it. It fired inside this
  repo's own LEAK SCREEN, where `0 added lines examined` reads as *no
  identifiers found* about material whose exposure would be permanent.

  > **A backslash before a punctuation character does not reliably mean
  > "literal" — in BRE it can CREATE an operator the bare character does not
  > have.** When a pattern's job is to EXCLUDE, get the dialect right or use
  > `-F`: an over-matching exclusion deletes the population instead of the
  > header, and the result is a zero shaped exactly like a true negative.

  The asymmetry trains the eye wrong: `-E '^\+'` on the SELECTING stage is
  correct, and the dialect only bites where the escape count goes above one —
  the `-v` stage, whose failure direction is *delete everything*.

  **AND THE SAME WRAPPER FAILS THE OTHER WAY ROUND ON THE OTHER PUNCTUATION
  CHARACTER: ugrep `-G` reads a MID-PATTERN `$` as an end-of-line ANCHOR, where GNU BRE
  reads it as a literal — so a bare `grep 'x=$(cmd'` through the wrapper is a
  SILENT ZERO on the `$(` of a command substitution, the commonest construct in
  shell source** (measured 2026-09-05, ugrep 7.8.4 against GNU grep 3.1;
  recorded on `<your-org>/nexus-code#1461`). The lower half of the block above is
  that measurement: GNU `1`, the wrapper `0` at rc 1 with stderr EMPTY, and `-F`
  or `\$` giving `1` through both. It is `#1158` with the POLARITIES REVERSED —
  there GNU is permissive and the wrapper is LOUD; here GNU is right and the
  wrapper is SILENT, which is the direction that costs — and a reader of the
  paragraphs above would reasonably conclude the wrapper always complains. It
  does not. The false answer it produced was a false ALARM, *"the
  manifest-keyed line changed"*, about a commit that had just been made
  correctly: a `grep` over that commit's own source for a `$(…)` line that was
  there. So `command grep` is the remedy HERE and the anti-remedy one paragraph
  up. **AND THE ADJACENT REMEDY FAILS, WHICH MATTERS MORE THAN THE DEFECT.** A
  reader who has internalised the paragraphs above reaches for `-E`, exactly as
  they were taught — and `-E 'x=$(cmd'` is rc 2 *Unmatched (* under BOTH
  implementations, because in ERE `$` is an anchor EVERYWHERE and `(` opens a
  group. The defect announces itself as a zero; the wrong remedy announces
  itself as YOUR OWN MISTAKE — a malformed pattern, apparently — so the natural
  next move is to fix the pattern rather than to recognise a second dialect
  trap, and nothing on the screen says otherwise. **The one remedy the two
  halves share is `-F`**; `\$` is the escape when a regex is genuinely needed.

  **AND THIS ENTRY'S OWN REMEDY IS THE NEXT DEFECT, ON THE OTHER DIFF MARKER: a
  pattern beginning with `-` is an OPTION, so `grep -vF '---'` never filters
  anything** (`<your-org>/nexus-code#1186`). `+` introduces no option and `-`
  does, so the idiom works on one half of the pair and not the other —
  **testing the safe half and generalising is how it arrives**. TWO modes, and
  the second has no stderr at all:

  <!-- BEGIN DASH-PATTERN-OPTION -->
  ```zsh
  grep -vF '---'    FIX   # MODE 1: rc 2, LOUD, prints nothing — a confident zero under 2>/dev/null
  grep -cF '-i'     FIX   # MODE 2: count 0, stderr EMPTY — `-i` eaten, and FIX slid into the PATTERN slot
  grep -vF -e '---' FIX   # CORRECT: -e declares the next argument a PATTERN
  grep -vF -- '---' FIX   # CORRECT: -- ends option parsing
  ```
  <!-- END DASH-PATTERN-OPTION -->

  **Mode 2 is identical under GNU grep 3.1 and ugrep 7.8.4. MODE 1 IS NOT, and
  the divergence is the wrong way round** — GNU is loud (rc 2), ugrep is
  SILENT, so under ugrep Mode 1 *becomes* Mode 2 and "Mode 1 is at least loud"
  is not portable. Mode 2 is the reason `--` is not optional: a leading-dash
  string that happens to BE a valid flag is consumed in silence, your FILE
  argument slides into the PATTERN slot, and grep reads STDIN instead — a zero
  with an empty stderr, or, with stdin INHERITED as an agent's Bash tool call
  has it, a BLOCK.

### Pathspecs, timelines and published counts

Full treatment — including the merge-shape taxonomy behind a "PRs merged"
denominator, and the direction each enumeration errs in:
`skills/nexus.claims/SKILL.md`.

- **`git ls-tree` with a GLOB pathspec is a confident zero — use
  `git ls-files`.** It bites hardest because it fires inside the probe you
  wrote to *attack* an emptiness claim: a skeptic enumerating a population this
  way got `0`, and only a sanity-check against a known total caught it
  (`#770`). `ls-tree` pathspecs are **path prefixes rooted at the given tree**,
  not globs; `ls-files` pathspecs are globs.

  <!-- BEGIN LSTREE-PATHSPEC -->
  ```zsh
  git ls-tree -r --name-only HEAD -- '*.sh'    # WRONG:   0 hits, rc 0
  git ls-files -- '*.sh'                       # CORRECT: every .sh tracked
  ```
  <!-- END LSTREE-PATHSPEC -->

  Verified identical on git 2.17.1 and 2.33.0. A bare `git ls-tree HEAD <dir>`
  is the second trap: without `-r` it prints the ONE tree object, so `wc -l`
  says `1` for a directory holding hundreds. To read a non-HEAD ref, use
  `git ls-tree -r --name-only <ref>` with NO pathspec and filter the output.
  **This entry is only half the lesson — read the next one before you use the
  form it prescribes.**
- **git's pathspec glob `*` CROSSES `/`.** The other half of the entry above,
  and its **false floor**: that entry sends you to `ls-files` *because* its
  pathspecs are globs, and this is where that form lies to you. Pathspecs are
  matched with `fnmatch` **without** `FNM_PATHNAME`, so `monitor/*.sh` is every
  `.sh` at any depth beneath it, not the ones in `monitor/`. Measured on `dev`
  @ `e256d4a`, git 2.17.1: **471**, against `echo monitor/*.sh | wc -w` → 103.

  <!-- BEGIN PATHSPEC-GLOB-DEPTH -->
  ```zsh
  git ls-files -- 'monitor/*.sh'             # WRONG SCOPE: git's * CROSSES / — 471
  git ls-files -- ':(glob)monitor/*.sh'      # CORRECT: depth-1, as the shell means it — 103
  git ls-files -- ':(glob)monitor/**/*.sh'   # the WIDE form, asked for ON PURPOSE — 471
  ```
  <!-- END PATHSPEC-GLOB-DEPTH -->

  `:(glob)` turns on `FNM_PATHNAME` so `*` stops at `/`. It is **the form, not
  a workaround**, and it works at git 2.17.1 — the oldest git on this host.
  Post-filtering is a workaround and should not be written down as the answer.
  It is the pathspec machinery, not `ls-files`: `git grep`, `git log`,
  `git add`, `git diff` and `git restore` take the same pathspecs.

  This is the **plausible over-count**, so the sanity check is the opposite
  question — **is this number larger than the directory could possibly hold?**
  `#903` published "103 unguarded arms across 24 files" from this form;
  re-derived, it was 37 across 8. See `#954`, `#903`, `#770`, `#931`.
- **A value sampled across refs is a TIMELINE only if each ref is an ancestor
  of the next — `git show <ref>:<path>` is not history.** The worst of the
  confident-wrong-answer family, because its output *looks* like evidence: a
  monotone count series reads as a narrative, and the narrative is usually the
  very thing you were trying to establish. Refs on divergent branches produce a
  well-formed series answering a different question, and nothing errors. This
  has already published a wrong mechanism, retracted on `#790`.

  <!-- BEGIN ANCESTOR-TIMELINE -->
  ```zsh
  git merge-base --is-ancestor "${A}" "${B}"   # rc 0 ⇒ B descends from A: this pair IS a timeline
  git show "${ref}:${path}"                    # brace ALWAYS — see the modifier trap above
  ```
  <!-- END ANCESTOR-TIMELINE -->

  The second line is not a digression: the zsh history-modifier trap above
  fires on exactly this call, so unbraced you are sampling a file that does not
  exist across refs that are not a timeline — two silent failures compounding
  into one confident graph.

  **The precondition is NECESSARY, NOT SUFFICIENT.** `#828` blamed a commit for
  turning a lint red on the strength of `git log -S`; the ancestor check was
  run and PASSED. The claim was still wrong — the file was **byte-identical**
  across the whole range and what had changed was the **lint**. So: *vary the
  axis the MECHANISM varies on, not the axis your SEARCH varied on.* A value
  has at least two inputs — the thing measured and the thing measuring it. The
  cheap check is a blob comparison, `git rev-parse "${A}:${path}"` against
  `"${B}:${path}"`: identical blobs exonerate the subject.
- **A COUNT IS A PROPERTY OF A TREE. Report the command AND the ref that
  produced it, or it is not checkable.** A bare number identifies nothing —
  carry it to another ref and it silently measures something else. The trap is
  that the most natural counting commands answer about **your checkout**, not
  about a ref: `git ls-files`, `find`, `wc -l` over a glob and any `grep -c`
  all read the index or the working tree.

  <!-- BEGIN COUNT-PROVENANCE -->
  ```zsh
  git ls-files -- '*test-*.sh' | wc -l                          # YOUR CHECKOUT, never a ref
  git ls-tree -r --name-only "${ref}" | grep -c 'test-.*\.sh$'  # THAT ref — filter output, no glob pathspec
  git rev-parse --short "${ref}"                                # report this BESIDE the number, always
  git rev-parse "${ref}"                                        # the FULL sha whenever the output will be MATCHED
  ```
  <!-- END COUNT-PROVENANCE -->

  **AN ABBREVIATED HASH'S WIDTH IS NOT A PROPERTY OF THE REF — it is a property
  of the READING repository's object count** (`#1249`, worked example `#1122`).
  Command + ref is necessary and INSUFFICIENT. Measured: two clones of one repo
  at ONE commit, native `%h` width **7** at in-pack 16151 and **8** at 21181 —
  so a native-only run in the smaller clone proves nothing, and the failure
  arrives as a non-match rather than as an error. Use `%H` whenever the output
  will be MATCHED; keep `--short` for being READ beside a number.

  **The cross-check that agrees with itself is the sharp edge.** "My
  enumeration returns N and the tool self-reports N" is worthless when BOTH
  sides were computed on the same unnamed tree: it confirms the two agree,
  never that either describes the ref being claimed. Reconciled numbers need
  their ref stated as hard as raw ones, and arguably harder, because agreement
  reads as verification.

  **A NUMBER IS ALSO A PROPERTY OF A MOMENT — and the moment most likely to
  have moved is the one YOUR OWN WORK moved** (`#996`). Two measured instances,
  both **correct when taken**, were false when published; neither is a
  miscount, and that is the point — **a stale number sits at no suspicious
  extreme**, so it looks exactly like every correct number near it. The
  dangerous pattern is *measure the board → act on the board → quote the first
  measurement*. Re-fetch immediately before quoting, above all for a population
  your own actions have since joined.

  **A LINE NUMBER IS A COUNT'S TWIN — a property of a tree, and worse when
  stale** (`#1163`). A stale count LOOKS wrong; a stale `path:line` points at
  DIFFERENT CODE THAT STILL PARSES, so the reader lands somewhere real, reads
  something coherent, and concludes the citation was about that.

  <!-- BEGIN LOCATION-PROVENANCE -->
  ```zsh
  git show "${ref}:${path}" | grep -n 'CONSTRUCT'   # the CONTENT at the line — and brace ALWAYS
  git rev-parse "${ref}:${path}"                    # the BLOB: cite it beside the line
  ```
  <!-- END LOCATION-PROVENANCE -->

  **And never reconcile two citations by their DELTA.** An edit above a region
  shifts everything below it uniformly, so a matching offset distinguishes
  NOTHING — measured, all three call sites in one file shifted by exactly 19,
  so *any* of them "reconciles" a delta-19 claim. The only sound check is the
  CONTENT at the line; a wrong PATH is the lesser hazard because it fails
  loudly.

  **The DENOMINATOR is a count too, and `grep 'Merge pull request #'` gets it
  wrong** (`#931`). A SQUASH-merged PR has no such subject, and a REBASE merge
  has no distinguishing subject AT ALL (`#1271`) — it is an ordinary one-parent
  commit wearing the author's own subject, indistinguishable git-locally from a
  direct push. Enumerate with NO subject filter and classify afterwards:

  <!-- BEGIN MERGE-ENUMERATION -->
  ```zsh
  git log --first-parent -n 300 --format='%s' | grep -c 'Merge pull request #'   # WRONG: misses every squash
  git log --first-parent -n 300 --format='%h|%p|%s'                              # walk with NO filter, classify after
  git log --first-parent -n 300 --format='%s' | grep -cE 'Merge pull request #|\(#[0-9]+\)$|^Merge PR #[0-9]+'
  git log --first-parent --format='%H%x09%p%x09%s' | awk -F'\t' 'split($2,a," ")==1 && $3 !~ /Merge pull request #|\(#[0-9]+\)$|^Merge PR #[0-9]+/'
  ```
  <!-- END MERGE-ENUMERATION -->

  When the walk is wide and the number matters, `gh api …/pulls` keyed on
  `merge_commit_sha` is the ONLY form that answers the question; the subject
  shapes say what they are, which is subject shapes. The worked numbers, the
  errors that cancel, and why widening the walk a little gives a FALSE
  confirmation: `skills/nexus.claims/SKILL.md`.

### Exit status, quoting and parsing

- **A PIPELINE'S EXIT STATUS IS ITS LAST COMMAND'S — so `cmd | tail` reports
  `tail`'s success, never `cmd`'s** (`<your-org>/nexus-code#928`). `tail`, `head`,
  `wc` and `grep -c` essentially always succeed, so every downstream test of
  that status reads the wrong thing.

  <!-- BEGIN PIPELINE-STATUS -->
  ```zsh
  bash -c 'bash -c "exit 1" | tail -8; echo "rc=$?"'                        # MASKS a failure: rc=0, real rc was 1
  bash -c './no-such.sh | tail -5 || echo FALLBACK && echo "closed 17"'     # MANUFACTURES success: prints, fallback never ran
  bash -c 'set -o pipefail; bash -c "exit 1" | tail -8; echo "rc=$?"'       # CORRECT: rc=1
  ```
  <!-- END PIPELINE-STATUS -->

  The first hid a real `rc 1` behind `| tail -8`. The second ran a
  window-close script that **does not exist**, the pipeline still returned `0`,
  the `||` arm never fired, and it printed `closed 17` for a kill that never
  happened — believed, and the window resurfaced later. **Masking a failure is
  recoverable; FABRICATING a success is not.**

  The repo's `pipefail` convention does not fix it: both instances were ad-hoc
  command lines, where no `set -o` from any file applies. And `a || b && c`
  parses as `(a || b) && c`, so a trailing `&& echo "<done>"` announces the
  same thing whether the primary or the fallback ran.

  **AND IT NEEDS NO PIPE: `"$(cmd)" "$?"` in ONE argument list destroys the
  status too** (`#1202`). Arguments evaluate left to right, so the substitution
  RUNS — and writes `$?` — before the later `"$?"` is expanded:

  <!-- BEGIN PRINTF-STATUS-CLOBBER -->
  ```zsh
  bash -c 'false; printf "rc=%s\n" "$(basename /x/y)" "$?"'                        # WRONG:   rc=0 — false's 1 destroyed by the substitution
  bash -c 'false; printf "rc=%s name=%s\n" "$?" "$(basename /x/y)"'                # rc=1 — ORDER is the entire mechanism
  bash -c 'false; rc=$?; n=$(basename /x/y); printf "name=%s rc=%s\n" "$n" "$rc"'  # CORRECT: rc=1
  ```
  <!-- END PRINTF-STATUS-CLOBBER -->

  **The middle line is the boundary**: move `"$?"` LEFT of every substitution
  and the same argument list reads correctly, so the mechanism is argument
  evaluation ORDER and nothing about `printf`. `printf` is only the amplifier —
  it RECYCLES its format string over surplus arguments, so the wrong form
  prints two lines and a reader scanning a column finds a zero in the right
  place. **Read `$?` into a variable on the very next line; anything that
  executes between the command and the read of `$?` is a write to `$?`.**

  **AND A `timeout` WRAPPER INJECTS A STATUS THE CALLEE CANNOT PRODUCE**
  (`#1248`) — the member that arrives by OBEYING this workspace's own advice to
  bound every wait. Nothing executes between the command and the read of `$?`;
  the status is MANUFACTURED by a wrapper you added on purpose.

  <!-- BEGIN TIMEOUT-STATUS-INJECTION -->
  ```zsh
  bash -c 'timeout 1 sleep 5; echo "rc=$?"'                       # 124 — in NO callee's vocabulary
  bash -c 'timeout 1 sleep 5; echo; echo "rc=$?"'                 # rc=0 — the 124 HIDDEN by one echo
  bash -c 'timeout -s KILL 1 sleep 5; echo "rc=$?"'               # 137 — so a 124-only test MISSES it
  bash -c 'timeout --preserve-status 1 sleep 5; echo "rc=$?"'     # 143 — the flag whose NAME promises otherwise
  bash -c 'timeout 5 bash -c "exit 11"; echo "rc=$?"'             # 11 — passthrough: the injection is INTERMITTENT
  bash -c 'timeout 1 sleep 5; rc=$?; case $rc in 124|125|126|127|137|143) echo "WRAPPER, not a tool verdict";; esac'
  ```
  <!-- END TIMEOUT-STATUS-INJECTION -->

  **Line 3 defeats the obvious remedy.** *"Test for `124` first"* is correct
  for the DEFAULT and silently wrong the moment anyone hardens the call:
  `-s KILL` injects **137**, and `--preserve-status` — the flag whose NAME
  promises otherwise — injects **143**. Test the SET, not the value. **Line 5
  is why it survives testing:** a callee that finishes in time passes its own
  status through untouched, so the injection is INTERMITTENT, correct on every
  run you watch and wrong on the one that matters. **Before wrapping, check
  whether the tool already has a bound and a code for it** — in this repo's
  long-running tools it usually does, and an outer bound that fires first makes
  the tool's own well-typed expiry code unreachable.

  **The `124` test is a PROXY, and stating its error direction is what this
  file's own `shopt` rule demands.** A callee may legitimately exit 124 —
  measured, `timeout 5 bash -c "exit 124"` is `124`, indistinguishable from the
  wrapper's — so the test cannot separate *the wrapper killed it* from *the
  tool said 124*. For the small vocabularies in this repo that is a SAFE proxy;
  say so rather than treating it as identity.
- **A BACKTICKED IDENTIFIER INSIDE A DOUBLE-QUOTED `--message "…"` IS
  COMMAND-SUBSTITUTED BEFORE `ng` EVER SEES IT — and the corrupted text is
  written to a permanent record at rc 0** (`<your-org>/nexus-code#1157`). Agent
  prose here is dense with backticked window names, paths and function names,
  and `ng request reply` / `ng send` / `ng skeptic ask` are this workspace's
  transports for durable, machine-read records, so the exposure is continuous
  and the artefact outlives the session.

  <!-- BEGIN BACKTICK-SUBSTITUTION -->
  ```zsh
  zsh  -c 'msg="expiry `nxmerge` recorded";     printf "[%s]\n" "$msg"'   # MODE 1: token DELETED; rc 127 lands on the ASSIGNMENT nobody tests
  zsh  -c 'msg="run `basename /a/b/tmux` next"; printf "[%s]\n" "$msg"'   # MODE 2: STDOUT spliced in — rc 0, stderr EMPTY, reads as prose
  bash -c 'msg="run `basename /a/b/tmux` next"; printf "[%s]\n" "$msg"'   # IDENTICAL in bash: NOT a member of the zsh-only family
  zsh  -c 'msg=$(cat MSGFILE);                  printf "[%s]\n" "$msg"'   # CORRECT: a FILE's bytes are never shell-expanded — what --file buys
  zsh  -c $'cat <<\'EOF\'\nthe window `true` is literal\nEOF'             # CORRECT: heredoc, and ONLY because the delimiter is QUOTED
  zsh  -c $'cat <<EOF\nthe window `true` is literal\nEOF'                 # WRONG: an UNQUOTED delimiter has identical exposure
  ```
  <!-- END BACKTICK-SUBSTITUTION -->

  Mode 2 is the shape to fear: *"run tmux next"* is grammatical, plausible and
  permanently wrong, with nothing on stderr and rc 0. Mode 1 at least leaves a
  `command not found` — but the `127` lands on the ASSIGNMENT, which nothing
  tests. **This happened and the record is still wrong**: a filed reply carries
  a DOUBLE SPACE where a backticked word used to be. Single-quote the argument,
  or pass `--file` (all three verbs take it) written through a
  QUOTED-delimiter heredoc. `ng` cannot defend you — the shell destroyed the
  evidence before the process started. Filed among zsh traps while NOT being
  one: POSIX backtick substitution, identical in bash, so a bash-tested remedy
  does not exonerate it.

  **THE AUTHORING PATH CARRIES THE SAME HAZARD, AND ITS ESCAPE SET IS THE
  INVERSE OF THE ONE YOU WOULD SPOT-CHECK: a `sed`/`awk` backreference written
  inside a NON-RAW Python string is destroyed** (`#1203`). `"\1"` is a valid
  Python OCTAL escape and becomes the byte `0x01`; `\(`, `\)`, `\+`, `\.`,
  `\d`, `\w`, `\s` are not Python escapes and survive verbatim. So in a regex
  dense with escaped punctuation, exactly the one character carrying the RESULT
  is replaced by a control byte while everything around it passes through.

  <!-- BEGIN PYTHON-BACKREF-ESCAPE -->
  ```zsh
  python3 -c 'print(repr("s/(\([0-9]*\))/\1/"))'    # WRONG:  the \( survived; the \1 is now \x01
  python3 -c 'print(repr("\8 \9 \d"))'              # SURVIVE: \8 \9 are not OCTAL, \d is not an escape
  python3 -c 'print(repr(r"s/(\([0-9]*\))/\1/"))'   # CORRECT: r"" — every backslash stays a backslash
  python3 -W error -c 'print("\1")'                 # SILENT: rc 0 — a VALID escape warns NOWHERE
  python3 -W error -c 'print("\d")'                 # LOUD:   rc 1 — the INVALID escape is the one tooling sees
  ```
  <!-- END PYTHON-BACKREF-ESCAPE -->

  **The remedy above does not transfer — only the `--file` half does.**
  Single-quoting defeats the shell and is IRRELEVANT to Python, where `'\1'`
  and `"\1"` are the SAME byte. Only the `r` prefix protects.

  **The last two lines are the entry.** `\0`–`\7`, `\a`, `\b`, `\f`, `\n`,
  `\r`, `\t`, `\v` are CONSUMED; `\8`, `\9` and every letter that is not an
  escape SURVIVE, with four exceptions that fail LOUD — `\x`, `\u`, `\U` and
  `\N` are SyntaxErrors. So the two probes a reader reaches for, a
  high-numbered backreference and a `\d`, both come back intact, and
  generalising from them walks you into `\1`. And `-W error`, flake8 W605 and
  every linter of that family flag the INVALID escape while staying silent on
  the VALID one: **the tooling built for this class cannot see the member that
  destroys data.** Octal escapes are in the language spec, so `r""` is the fix
  on every interpreter. The corrupted regex still WORKS AS A MATCHER, so no
  stage is ever empty; downstream the `0x01` passed a `[[ -z "$n" ]]` guard as
  a value successfully found. **An emptiness check is a presence test wearing a
  validity test's name**: validate the SHAPE, `[[ "$n" =~ ^[0-9]+$ ]] || exit 3`.
- **`datetime.fromisoformat` DOES NOT EXIST on this host's Python 3.6.9**
  (`<your-org>/nexus-code#935`) — it arrived in 3.7. Re-measured 2026-09-05:
  `sys.version` `3.6.9`, `hasattr(datetime.datetime, "fromisoformat")` `False`.
  The call itself is loud, so the trap is not the call:

  <!-- BEGIN FROMISOFORMAT -->
  ```zsh
  python3 -c 'import datetime; print(hasattr(datetime.datetime,"fromisoformat"))'   # False on 3.6.9
  python3 -c 'import datetime; datetime.datetime.fromisoformat("2026-08-14")'       # rc 1, AttributeError — LOUD
  python3 -c 'import sys; print(sys.version.split()[0])'                            # confirm the interpreter first
  ```
  <!-- END FROMISOFORMAT -->

  **The silence has TWO modes and an `except` is only one of them.** Mode 1: a
  per-item `try: … except Exception: continue`, entirely reasonable for bad
  ROWS, also swallows *no such method*, so every row is attempted and discarded
  at rc 0. **Mode 2 needs no `except` anywhere** — the failing step is loud
  (traceback, rc 1) but **its rc is never tested**, so the shell continues, the
  intermediate is empty, and the number is produced by LATER steps that each
  succeed. **The error need not be lost; it only needs to be off the path that
  produces your number.** Mode 2's general symptom is worse than a zero: a
  DATA-dependent failure halfway through leaves the intermediate **truncated**,
  so the count is short and plausible — and a short count is more dangerous
  than a zero, because a zero is at least suspicious. So **TEST THE PRODUCER'S
  RC**; refusing an EMPTY intermediate catches only the zero case, and the
  truncated one passes it. The two modes and their different checks:
  `skills/nexus.claims/SKILL.md`. The 3.6-safe substitute — note that `%z` on
  3.6 rejects a COLON in the offset, which is exactly what
  `git log --format=%cI` emits:

  <!-- BEGIN ISO-PARSE-36 -->
  ```zsh
  python3 -c 'import datetime,re
  s="2026-08-14T10:18:41-07:00"
  s=re.sub(r"([+-]\d{2}):(\d{2})$", r"\1\2", s[:-1]+"+0000" if s.endswith("Z") else s)
  print(datetime.datetime.strptime(s,"%Y-%m-%dT%H:%M:%S%z"))'
  ```
  <!-- END ISO-PARSE-36 -->

### Shell state that changes under you

- **In zsh, `path` IS `$PATH` — assigning to it destroys your PATH for the rest
  of the shell, with no error and rc 0** (`<your-org>/nexus-code#945`). `path` is
  a tied array bound to `$PATH`, and it is the most natural variable name there
  is:

  <!-- BEGIN ZSH-PATH-TIE -->
  ```zsh
  zsh  -c 'path=/tmp/nowhere; echo "PATH=$PATH"; command -v git || echo "git NOT FOUND"'   # WRONG: PATH=/tmp/nowhere
  bash -c 'path=/tmp/nowhere; echo "PATH=$PATH"'                                           # bash: PATH untouched
  zsh  -c 'f() { local -h path; path=/tmp/nowhere; }; before=$PATH; f; [[ $PATH == $before ]] && echo INTACT'
  ```
  <!-- END ZSH-PATH-TIE -->

  Measured: PATH collapsed from 26 entries to one, and `tr` and `wc` were gone
  by the very next command — the tools you would reach for to diagnose it are
  the first casualties. **It is not a typo, which is why it survives review**:
  `path="$repo/x"`, `path=$(mktemp -d)` and `for path in …` are idiomatic
  everywhere else, and **bash does not do this**, so anything tested under
  `bash -c` works and breaks only in the zsh-default agent path. `local -h
  path` genuinely protects; bare `local path=` only SCOPES the damage — `$PATH`
  is destroyed for the whole function body, where your commands actually run.
  Prefer another name. The blast radius here is specific: `monitor/ghwrap` is
  prepended to the FRONT of `PATH`, so losing PATH silently removes it and an
  unwrapped `gh` write is `#497`.
- **In zsh a bare `> file` RUNS `$NULLCMD` (`cat`) and BLOCKS FOREVER on
  inherited stdin — at 0% CPU, with no error, no output and no timeout**
  (`<your-org>/nexus-code#1393`). The ordinary truncate-a-file idiom is inert in
  bash and a COMMAND in zsh.

  <!-- BEGIN NULLCMD-REDIRECT -->
  ```zsh
  bash -c '> f; echo returned' < /dev/null   # returns — bash: a command-less redirection only truncates
  zsh  -c '> f; echo returned' < /dev/null   # returns — the MASK: stdin is /dev/null, so NULLCMD's cat hits EOF
  zsh  -c '> f; echo returned'               # BLOCKS FOREVER at 0% CPU — zsh runs $NULLCMD (cat) on inherited stdin
  zsh  -c ': > f; echo returned'             # CORRECT in both shells: `:` is the command, `>` is its redirection
  ```
  <!-- END NULLCMD-REDIRECT -->

  **The second line is why nobody finds it.** `< /dev/null` makes the idiom
  WORK, so the same text is correct in every script that redirects stdin and in
  every `bash -c` test of it — unreachable in testing and armed for whoever
  omits the redirect. `: > file` is the portable form and it is one character.

  **The SIGNATURE is the reason to file it.** A job ran **7 h 30 m at 0% CPU**
  having produced nothing; `/proc` showed the child `cmdline = "cat "` with NO
  ARGUMENTS. Every `cat` the author wrote had a file argument; this one has
  none because zsh supplied it. **Read a job at 0% CPU for hours as BLOCKED,
  not as long-running** — a spinning job invites suspicion, a job at 0% looks
  like one correctly waiting on I/O. `wchan`, `fd/0` and an argument-less
  `cmdline` are the three fields that settle it.

  **DORMANT IN THE CORPUS, LIVE IN THE AGENT PATH — do not go "fix" the
  scripts.** Scanned at `28026081` over `git ls-files monitor`, shebanged files
  carrying a command-less `>` redirect (a deliberately loose scan that may
  over-count comments and heredocs): **69 tracked shell files match and ZERO
  are non-bash**, so nothing in the repo is broken today. The exposure is the
  zsh-invoked path — an agent typing the idiom into a Bash tool call — which is
  why the guard keys on the CONSTRUCT rather than on the absence of
  `< /dev/null`.
- **`shopt` STATE IS DYNAMIC, so EVERY STATIC PREDICATE FOR IT UNDER-COUNTS —
  AND IN A DIFFERENT DIRECTION PER PREDICATE** (`<your-org>/nexus-code#1214`).
  "Which code runs with this option set" looks like a question you can answer
  by reading, and every natural reading rule is wrong in its own way: scoping
  by FILE cannot see a sourced library; scoping by LINE POSITION is a LEXICAL
  rule for a DYNAMIC option, and a function DEFINED before the option is set
  can be CALLED after it; scoping by CALL GRAPH assumes the setting site is in
  your corpus, and with the option set OUTSIDE there is no site to root at, so
  it enumerates ZERO. The three wrong rules and their measured directions:
  `skills/nexus.claims/SKILL.md`.

  <!-- BEGIN SHOPT-DYNAMIC-SCOPE -->
  ```zsh
  bash -c 'f(){ a=( ./nope-* ); echo "${#a[@]}"; }; shopt -s nullglob; f'   # 0 — defined BEFORE the set, still affected
  bash -c 'f(){ a=( ./nope-* ); echo "${#a[@]}"; }; f'                      # 1 — the same function, option off: glob stays LITERAL
  bash -c 'shopt -s nullglob; bash -c "shopt nullglob"'                     # off — a child PROCESS does not inherit it
  bash -c 'shopt -s nullglob; export BASHOPTS; bash -c "shopt nullglob"'    # on  — …UNLESS BASHOPTS is EXPORTED
  bash -c 'f=$(mktemp); echo "shopt -s nullglob" >"$f"; BASH_ENV="$f" bash -c "shopt nullglob"; rm -f "$f"'   # on — BASH_ENV is a carrier too, and THIS NEXUS EXPORTS ONE
  ```
  <!-- END SHOPT-DYNAMIC-SCOPE -->

  **The only rule that does not under-count is "every shell file"** — decided
  by the shared predicate `monitor/shell-files.sh:shf_is_shell`, never by a
  filename glob. **The last three block lines decide reachability and they cut
  opposite ways.** A separate process is a real boundary, but an exported
  option ERASES it, so *"it is a child process"* is only an answer once you
  have checked the carriers: **`BASHOPTS`, `SHELLOPTS`, `BASH_ENV` together
  with its `NEXUS_PREV_BASH_ENV` chain, and invocation options such as
  `bash -O nullglob`**. (`GLOBIGNORE` is NOT a carrier — measured.)
  **`BASH_ENV` is the one a nexus worker will actually MEET, and this repo
  exports it by design**: `monitor/locals-env.sh` sets it for every agent
  process, and bash sources it at the start of every NON-interactive shell — so
  a single `shopt -s nullglob` added to that prelude silently changes every
  `ng` invocation in the nexus. Under `nullglob` an unmatched glob **VANISHES**
  rather than staying literal, so a command with a meaningful BARE form runs
  bare: `ls`/`du` act on the CWD, `cat`/`grep`/`wc` read STDIN.

  **When a property is set at RUNTIME, a predicate over SOURCE TEXT is an
  approximation, and you should be able to say which direction it errs in.** If
  you cannot, you do not know whether your zero means "none" or "none that my
  rule can see".

### When CI goes red

- **When your PR's CI goes red, check `dev` in ISOLATION before you read your
  own diff.** CI builds the **merge ref**, so every open PR inherits whatever
  is broken on the base; a red at your head is a claim about `base + yours`,
  never about yours alone. Measured on one night, three-for-three: two of three
  reds were inherited, and reading the diff first would have sent a worker into
  another agent's code both times. **Inheriting a red is the NORMAL case** —
  `#829` and `#841` are both `dev-red hotfix` PRs, each opened while every
  other PR in flight inherited a red it did not cause. Vary the base, hold your
  diff constant, and the question answers itself. The recipe (a UNIQUE
  per-caller worktree, never a fixed path, and never `git checkout origin/dev`
  on the main clone), why `ci-signal` green is not merge clearance, and why you
  read a failing lint's OFFENDER LIST rather than its count:
  `skills/nexus.ci-triage/SKILL.md`.

  **AND THE REMEDY NARROWS THE TESTED POPULATION: a worktree contains neither
  GITIGNORED nor UNTRACKED files** (`<your-org>/nexus-code#1150`). The tree it
  hands you is not the tree you have, so the population you test is not the one
  your suite runs against at home, and nothing errors.

  <!-- BEGIN WORKTREE-BLIND-SPOT -->
  ```zsh
  git -C SRC worktree add --detach WT REF   # NO -q: absent at git 2.17.1, THIS host — rc 129, and NO worktree
  git -C WT rev-parse HEAD                  # GUARD 1: must equal the source tree's HEAD, or every absence below is a false zero
  git -C WT status --porcelain --ignored    # GUARD 2: a LEFTOVER PLANT — HEAD equality is blind to one, and this is IN THE WORKTREE
  git -C WT ls-files -- CLAUDE.md           # POSITIVE CONTROL: a TRACKED file must be VISIBLE before any absence is believed
  git -C SRC status --porcelain --ignored   # in the SOURCE tree: exactly what the worktree will NOT have
  comm -3 SETA SETB                         # diff the failing-ID SETS — a matching TOTAL is not evidence
  ```
  <!-- END WORKTREE-BLIND-SPOT -->

  **Run the GUARD and the POSITIVE CONTROL first, BEFORE you read any absence.**
  This is not ceremony: `#1150`'s own author passed a `-q` that does not exist
  at this host's default git, so the worktree was never created and both probes
  duly reported the files "absent" from a directory that did not exist — a
  perfect false zero, produced while writing up false zeroes, caught only by
  the HEAD cross-check. **The HEAD guard is NECESSARY AND NOT SUFFICIENT**: a
  worktree carrying a LEFTOVER MUTATION PLANT passes it (`#1228`), and **a
  leftover plant pushes toward KEEP-OPEN, which is the prior** — the error that
  agrees with your expectation gets published. `status --porcelain --ignored`
  **in the WORKTREE** is the line that earns its place, because a plant into a
  gitignored path is invisible to `HEAD`, to the tree object, and to a plain
  `status --porcelain`.

  **The dangerous direction is the SKIP, not the failure.** A fixture-gated
  test whose data is gitignored skips in BOTH arms, so it cannot fail at base
  and cannot be seen to STOP failing — it leaves the population rather than
  turning red, and its absence reads as stability. **And a matching total is
  not evidence**: same repo, same ref, two instruments agreed on the failure
  column while membership differed by one each way. Diff the failing-ID SETS.
  If your suite has fixture-gated or asset-dependent tests, run it in a fresh
  CLONE and copy the gitignored data in — or say plainly that those rows are
  unmeasured. Per-git-version behaviour and the four-plant table:
  `skills/nexus.ci-triage/SKILL.md`.

### Panes, processes and kill decisions

- **Worker pane state: use `monitor/pane-state.sh <window-key>`** (alias
  `ng pane-state <window-key>`), never eyeball `tmux capture-pane` — Claude
  Code's autosuggest renders identically to user input in plain text.

  <!-- BEGIN WINDOW-KEY-VOCABULARY -->
  **`pane-state.sh` and `paste-followup.sh` accept the SAME window
  key: an index, a `session:window`, or a NAME.** They used to
  disagree — `pane-state.sh` was index-keyed and `paste-followup.sh`
  name-keyed, so `pane-state.sh 9` worked and `paste-followup.sh 9`
  was rejected in the very next command (`<your-org>/nexus-code#905`).

  They share ONE vocabulary in `monitor/_tmux-window.sh`, though not
  one entry point: `paste-followup.sh` resolves via
  `resolve_window_key`; `pane-state.sh` resolves a NAME via
  `resolve_window_index` and uses `resolve_window_key` for the
  ambiguity check. Stated precisely because "both go through
  `resolve_window_key`" was written here once while it was FALSE for
  `pane-state.sh`, which is the defect this block exists to prevent.

  **The ambiguous key is REFUSED, not guessed** — a key whose window
  part is both a window NAME and a *different* window's INDEX, in
  either spelling (`1` and `0:1` alike). Exit codes differ by tool
  and are what you actually get: **`pane-state.sh` exits 2**,
  **`paste-followup.sh` exits 1**, **`monitor/_tmux-window.sh key`
  exits 4**. Pass the unambiguous name.
  <!-- END WINDOW-KEY-VOCABULARY -->

  The helper emits
  `state=<idle|busy|user-typing|autosuggest-only|empty|blocked|absent|
  over-limit|working-background|working-self-paced|idle-orphan-async|
  unknown> active=<0|1> [queued=1] [throttled=1]`.

  **DO NOT COUNT THIS LIST AND DO NOT COPY IT. `monitor/pane-state.sh --states`
  IS the vocabulary; the above is a reading aid**, asserted against `--states`
  in both directions by
  `monitor/watcher/test-claude-md-pane-state-vocabulary.sh`. A hand-maintained
  list beside a hand-maintained count is two things to keep in sync: the list
  once omitted **`unknown`** — the state meaning *"could not look at all"* —
  while the prose beside it supplied a count, so **the document's own number
  was what stopped the check**. `working-background` and `working-self-paced`
  both mean **the worker is ACTIVE**, so dropping them into an else branch
  retires a live worker.

  **`throttled=1` IS A SUB-CONDITION OF `busy`, NOT A STATE** (`#1340`).
  Claude Code's `/low-priority` mode paints a retry banner on a pane that is
  MID-TURN and generating no tokens, and the busy detector keyed on the token
  counter — so a live worker with a visibly incrementing retry counter read
  `idle`, which is on the KILL ALLOWLIST. It is carried as a FIELD rather than
  a new token because every consumer already treats `busy` as never-kill, so a
  field needs no consumer audit while **a brand-new state token can be dropped
  by a permissive default arm**. It is **cc-version-sensitive** — the strings
  are the HARNESS's, and a reword upstream returns the pane to `idle`, the
  dangerous direction — so it belongs on the collision list
  `skills/nexus.cc-update/GUIDE.md` checks before a pin bump.
- **Never make a kill decision from a state you enumerated by hand.** The
  failure above is structural, not a lapse of care: any denylist with a
  permissive default arm retires whatever its author did not think of. Ask
  `monitor/_bookkeeping.sh:bk_pane_kill_authorized` instead — an **allowlist**
  (`idle`, `autosuggest-only`, `absent`, `idle-orphan-async`) with a
  default-**deny** arm. In particular `empty` means **"don't know yet"**, never
  "finished": a pane 4m38s into a verification pass with a queued message read
  `empty`, and the documented escalation recipe would have killed it (`#603`).
  `absent` is the state that positively asserts a dead agent. A pane showing
  `queued=1` has input already waiting behind a running turn — do not paste
  into it again, and never read a missing `UserPromptSubmit` as a lost paste
  while one is in flight (`#607`).
- **The same rule for PROCESSES, where the information you would filter on does
  not exist.** A worker stopping its own oversized test run built a kill list
  by `grep -v`-ing sibling clone names out of `ps` and killing the rest — and
  reaped SIBLING agents' runs (`#851`). Name and path matching cannot work
  here: sibling suites are invoked cwd-relative, so their `args` carry no clone
  path and are **byte-identical** to yours, and a deleted cwd removes path
  attribution too. Every name-based predicate has a permissive default arm *by
  construction*. Pipe candidates through **`monitor/proc-kill-authorized
  --filter`** — session ownership, allowlist, default-**deny**. It prints only
  pids whose session is yours, names every refusal on stderr, and exits 1 when
  it dropped anything, so an empty result is loud rather than "nothing to do".
  Ancestry is the wrong primitive and was measured so: a reparented process has
  `ppid` 1 while its **session survives**, so a parent walk refuses the very
  runaways you own. Note the deliberate false refusals — anything
  `setsid`-detached (the watcher, every registered service) is its own session
  leader and is never authorised; stop those with `monitor/svc.sh`.
- **A predicate keyed on a STRING cannot tell the THING from the DESCRIPTION of
  the thing — so a process-existence check matches SIBLING AGENTS' argv, and
  bracketing does not help.** The entry above is about KILLING; this one is
  about WAITING. Agent prompts quote verbatim the very thing being watched, and
  `claude`'s argv **is** its prompt, so the population that matches your pattern
  **grows with every worker spawned**. Measured on this board 2026-08-27 while
  a real job ran, a correctly bracketed pattern returned 12 hits, three of them
  live sibling `claude` processes holding the string in their PROMPTS
  (`<your-org>/nexus-code#1073`, `#1042`).
  **Bracketing is correct and insufficient**: `[g]` stops the grep matching
  *itself* and does nothing about a sibling. **It fails in BOTH directions**,
  so inverting the loop is not a fix — `until … grep -q` EXITS IMMEDIATELY on a
  prompt match when your job never started, and `while … grep -q` WAITS FOREVER
  while any agent holds the string; a loop of that shape held a window 5h20m.

  <!-- BEGIN PROC-EXISTS-AUTHORIZED -->
  ```zsh
  "$NEXUS_ROOT"/monitor/proc-exists-authorized --until-present --token "$tok"
  "$NEXUS_ROOT"/monitor/proc-exists-authorized --until-gone --pid "$pid" --start-time "$st"
  "$NEXUS_ROOT"/monitor/proc-exists-authorized --match 'myjob'      # session-scoped, one-shot
  "$NEXUS_ROOT"/monitor/proc-exists-authorized --until-gone --match 'myjob'   # REFUSED, rc 2
  ```
  <!-- END PROC-EXISTS-AUTHORIZED -->

  `monitor/proc-exists-authorized` keys on session ownership and pid identity,
  reads `/proc` (so it has no observer to self-match), and **owns the loop** —
  you never write the `until`/`while`, so the polarity cannot be inverted.
  **The last line is a REFUSAL and it is the design**: your own
  `setsid`-detached job left your session at launch and is invisible to any
  session-scoped match, so `--until-gone --match` would report GONE the instant
  you asked. You cannot establish that something is gone from a NAME — wait on
  a handle, or relaunch through `monitor/async-run.sh --desc "<what>" -- <cmd>`.
  **Read the exit code — three of the five are not answers:** `0` present, `1`
  absent (positively established), `2` usage/refused combination, **`3` REFUSED
  — could not determine, NEITHER present nor absent**, `4` timeout. `3` is what
  breaks the both-directions failure: a shell `until` loops on non-zero and a
  `while` loops on zero, so *any* two-valued predicate is read backwards by one
  of them.
- **THE ALLOWLIST DOCTRINE HAS A THIRD PROPERTY, AND THE FIRST TWO ARE NOT
  ENOUGH: no SAFE arm may precede a DENY arm that could fire on the same
  input** (`<your-org>/nexus-code#1121`). A classifier can be an allowlist with a
  provably-reached default-deny arm, every arm individually sound, and still
  pronounce the single most direct expression of its hazard SAFE — decided one
  arm too early. The worked example had a dedicated *"UNSAFE — body names the
  wrapper LITERALLY"* arm that was unreachable for 86% of its corpus because
  `classify()` opened with a permissive `SAFE-STUB` arm; the shim whose text
  literally contains the string the scanner exists to find was classified
  `SAFE-STUB`, and was measured reaching the operator's live tmux socket.

  <!-- BEGIN ARM-ORDER-SHADOWING -->
  ```zsh
  safe_first(){ case "$1" in *mock*)    echo SAFE;; *wrapper*) echo DENY;; *) echo DENY-DEFAULT;; esac; }
  deny_first(){ case "$1" in *wrapper*) echo DENY;; *mock*)    echo SAFE;; *) echo DENY-DEFAULT;; esac; }
  safe_first 'a mock that names the wrapper'   # SAFE — the DENY arm below it is UNREACHABLE
  deny_first 'a mock that names the wrapper'   # DENY — same arms, same default, ONE reordering
  eq_first(){   case "$1" in idle)      echo SAFE;; busy)      echo DENY;; *) echo DENY-DEFAULT;; esac; }
  eq_first idle                                # SAFE — and no reordering can change it
  ```
  <!-- END ARM-ORDER-SHADOWING -->

  **Why the shape does not give it away.** Every review heuristic points at the
  TERMINAL arm ("is the default deny?") and at COVERAGE ("what spelling did you
  miss?"). Both were satisfied, and three prior skeptic rounds did not surface
  it. The check is a different question and it is a static read: **go top to
  bottom and ask, for each SAFE arm, whether any input it accepts could also
  match a later DENY arm.** No fixture, no run.

  **THE HAZARD LIVES WHERE ARMS ARE PATTERNS, NOT WHERE THEY ARE EQUALITY**,
  and that is the half that tells you where to look. `eq_first` above is
  order-INDEPENDENT — literal equality over disjoint sets, so no input matches
  two arms — which is why the kill/wait guards this file prescribes are sound
  for a stateable reason rather than by luck, and would stop being so the day
  either state list gained a glob. **A SAFE arm that returns before a DENY arm
  is a claim that no input matches both, and a glob, a regex, a substring
  search or an `index()` is where that claim quietly becomes false.**

  It composes with `#1119`, and the composition is worse than either alone:
  when a permissive arm returns FIRST **and** that arm is itself a denylist
  with a permissive default, the architecture's advertised guarantee describes
  almost none of its actual traffic.
- **"Is that text at the prompt an operator draft?" — read `input=`, never the
  rendering.** Autosuggest renders identically to typed input in PLAIN text,
  which is why eyeballing `capture-pane` is banned; it does NOT render
  identically in SGR. `pane-state.sh` emits `input=<typed|ghost|blank|?>`:
  typed input carries bright white, a ghost carries faint. The fallback
  heuristic (`-- INSERT --` plus a non-blank row ⇒ draft) is **unsound** and
  stalled the board for thirty minutes on ghosts (`#626`). `input=?` means a
  non-blank row matching neither marker — genuinely undecidable from bytes, so
  treat it as a draft. Detail: `skills/nexus.window-cleanup/SKILL.md`.

### Before you change anything under `monitor/`

- **A FIELD THAT *SELECTS* IS NOT A LABEL — before writing a value into an
  existing field, find out whether anything MATCHES on it**
  (`<your-org>/nexus-code#1050`). If a value selects, adding a member is a
  BEHAVIOURAL CHANGE that must teach the matcher in the same commit. **When in
  doubt add a COLUMN, not a TOKEN.** Two matchers can read one column and
  filter it differently, and the documentation at the WRITE site describes the
  matcher its author cared about — so **grep every READER of a field, not the
  comment next to the writer**. The measured instance, why a live and correct
  exemption is worse for discoverability than a broken one, and the companion
  rule (*order any two-part operation so the failure mode is the OBSERVABLE
  one*): `skills/nexus.self-fix/SKILL.md`.
- **Before you push a change under `monitor/`, ask which guards READ it —
  `ng guards-for-diff`.** Reach for it in the gap between "I ran the suites
  near my edit and they passed" and `git push`. A PR's green covers the suites
  its DIFF TOUCHES, not the suites its CHANGE AFFECTS, and the guards that
  catch you are the ones keyed on a **source construct** rather than a
  directory — their populations are repo-wide, so an edit anywhere can join
  one, and you cannot consult a guard you do not know exists.

  <!-- BEGIN GUARDS-FOR-DIFF -->
  ```zsh
  monitor/ng guards-for-diff              # which registered guards read your changed files
  monitor/ng guards-for-diff --run        # …and run exactly those, reporting each verdict
  ```
  <!-- END GUARDS-FOR-DIFF -->

  **Read the exit code, because none of them is a clearance.** `3` = no
  registered guard reads your diff — a measured answer, not a green light.
  `2` = REFUSED, a guard's population probe errored (fail-closed, because an
  index that silently drops a guard it could not ask looks exactly like one
  that had nothing to say). `4` = green but UNVERIFIED. `1` = a selected guard
  FAILED, and `5` = the `--timeout` deadline expired with selected guards left
  **WITHOUT A VERDICT** — never started, or cut off mid-run. `5` is the one to
  learn: a guard that did not finish is not a guard that passed, and before it
  existed a truncated `--run` was indistinguishable from a clean one. And
  **`0` is the code nothing warned you about** (`#1078`): it says only that
  SOME declaring guard read a file you changed, never that the guard that
  matters ran — a suite declaring no population is INVISIBLE to the index
  rather than excluded by it, appearing in neither `SELECTED` nor
  `CONSIDERED AND EXCLUDED`, so its absence looks like a considered
  exclusion. Read the tool's own per-run blind-spot COUNT, not the exit
  code; that line prints byte-identically at `0` and at `3`. **`git add`
  before you trust it** (`#1054`): selection counts your full working set
  including untracked files, while a population guard enumerates
  `git ls-files` — tracked only — so a guard can be selected, run, and
  return a confident green about a tree that does not contain your new file.
  The honest provenance for a population-based guard is therefore **command
  + ref + whether the files were staged**. It is **not a substitute for the
  full suite**. The header of `monitor/guards-for-diff.sh` IS the exit-code
  vocabulary — read it there, not from a list; worked detail:
  `skills/nexus.self-fix/SKILL.md`.

## Shared infrastructure

If you run on shared infrastructure (HPC cluster, batch scheduler, lab GPU
pool), be efficient: test before scaling, right-size resource requests, reuse
intermediate results, and prefer the appropriate partition for the job size.
