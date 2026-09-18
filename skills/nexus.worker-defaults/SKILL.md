---
description: "Always-applies workspace defaults for any nexus-spawned worker: bot identity for GitHub writes, no --no-verify, no force-push to a shared branch, sandbox-notify, report convention. The ## Worker floor section is injected verbatim into every spawn prompt by monitor/spawn-worker.sh."
---

# nexus.worker-defaults — every-worker safety floor

This skill's `## Worker floor` section is injected verbatim by
`monitor/spawn-worker.sh` into every spawn prompt. **Don't
reference this skill from inside a worker prompt** — the launcher
already has it, and worker cwds under `work/<project>/...` can't
resolve a relative `skills/...` path anyway.

The other H2s here are **orchestrator-facing** prose: when to
update, how injection works, what's in the floor and why. The
worker never sees this prose.

## What this skill is for

The single source of truth for the executable rules every nexus
worker must follow regardless of task shape. Editing the
`## Worker floor` section below propagates to every subsequent
spawn through the launcher; no per-spawn boilerplate to update.

The floor stays tight (~6 bullets) and **executable**: a worker
can act on every line without consulting another skill. Anything
that needs deeper prose (verb tables, push-author-verify, fetch-
asset, the Infrastructure Issues feedback loop, the slug
convention) lives in `nexus.bot` / `nexus.report` and is consulted
**only when the floor is insufficient** for the case at hand.

**Design principle (context engineering).** Every token in the
floor is prepended to EVERY worker prompt, ahead of the worker's
actual task, and spends the model's finite "attention budget"
whether or not the worker ever needs it — and irrelevant
front-loaded instructions measurably degrade accuracy, not just
token count (Anthropic, *Effective context engineering for AI
agents*, 2025; Chroma, *Context Rot*, 2025; Anthropic, *Best
practices for Claude Code* — "bloated CLAUDE.md files cause Claude
to ignore your actual instructions"). So a rule earns its place in
the floor only if it is **generally relevant to every worker** AND
either cheap or load-bearing-with-no-hookable-trigger. A rule that
only matters at a specific command (self-matching `pkill`, a
wrong-clone `git push`, a `gh` write, an async launch, a poisoning
asset URL) is delivered **just-in-time** by a hook that fires at
that command — the same progressive-disclosure pattern
`ng wrap-up` already uses to carry report + skeptic guidance at
wrap time rather than front-loading it. See `## Just-in-time hooks`
below for the mechanisms and `reports/nexus-code-workerfloor_*.md`
for the full taxonomy + research.

**Worked example of that split — the force-push rule
(<your-org>/nexus-code#835).** The floor used to say *"never
force-push"*, flat. That contradicted the merge gate, which
*requires* a rebase onto the current base before merge: a
`pull_request` run is computed against a merge ref built at run
creation, and `rerun-failed-jobs` reuses that same stale ref — so a
later green can describe a base that has moved, and rebasing onto the
current base makes the push non-fast-forward.

**Do not say "only a new head re-evaluates" — that was REFUTED by
experiment.** The merge ref is **demand-triggered**: `refs/pull/N/merge`
is recomputed when something asks GitHub for the PR's mergeability, and
not otherwise. Measured: two refs sat stale for **26 and 36 hours**
across many base advances, while one refreshed to the base's current tip
**within two minutes of a single `GET /pulls/{n}`** and an untouched
control did not move. (A model, not a mechanism: a `GET` has since been
measured refreshing `mergeable` while the ref's base stayed put, n=2 —
see `monitor/_merge_ref_base.sh` and `#923` before leaning on "one GET
refreshes it".) Two consequences, and the second is the sharp one:
"it has been a while, it must have refreshed" is false; and **querying
the PR refreshes it, so the act of checking changes what you are
checking.** Never read a green, then query the PR, then treat that green
as describing what you just queried. Safe order: **GET the PR** to force
the refresh, **then create a new run**, **then enumerate** it. `#823` merged on a green
computed against a stale merge ref and turned `dev` red. The floor
now carries only the **boundary** (shared branch vs your own PR
branch, one sentence); the checkable precondition, the
`--force-with-lease` caveat, and the merge-ref rationale live in the
`force-push` rows of `bash-footgun-patterns.conf`, delivered by
`bash-footgun-guard.sh` at the instant the worker runs `git push`.
Don't restore the blanket ban here: it reads as correct, and it
tells every worker to refuse a rebase the merge gate demands.

**And do not re-key the boundary on AUTHORSHIP.** The first version of
this rule shipped `git log --format='%an' origin/dev..HEAD | sort -u`
as the precondition, glossed as "if this lists only you, no other agent
has commits here". That is **false in this workspace, and this very
floor is why** — it mandates *"`git commit` / `git push` use your
identity"*, so every agent commits as the operator and the author check
can never see a sibling. Measured on a purpose-built two-agent branch,
it returned one name and read SAFE while a sibling's commit sat on the
branch; the force-push then destroyed that commit and its file.
`--force-with-lease` did **not** save it, because the lease is satisfied
by the very `git fetch` that rebasing onto current `dev` requires.
The boundary must key on the **property** — commits on the remote you
would destroy. Caught by the `#835` skeptic pass; it is the workspace's
dominant defect class (a proxy asserted in place of the property)
re-instantiated inside the fix.

**And the property check must FAIL CLOSED, which the first correction
did not.** Shipped as prose — *"`git fetch origin <branch>`, then
`git log --oneline <branch>..origin/<branch>`"* — it was right whenever
it could look and **silently safe whenever it could not**. Three states
print empty: the branch is not on the remote yet, the fetch **failed**,
or the tracking ref is stale because the fetch was skipped. The first
two are byte-identical at the terminal (same empty stdout, same
`rc 128`), so the failure renders as the clearance. It is now one
command that fetches and compares together and cannot be half-run —
`monitor/force-push-check.sh`, exit codes `0` safe / `1` UNSAFE / `2`
REFUSED / `3` no such remote branch, mirroring `guards-for-diff.sh`'s
`#803` shape where "could not check" and "nothing found" are separate
codes and neither is a pass.

**And its `1` is a claim to reconcile, not a verdict to obey**
(`#835`, `#898`). The check matches commits by patch-id, so a rebase
whose replay needed conflict resolution, a content-changing `--amend`,
and a rebase that flattens a merge all report UNSAFE — byte-identical
to a real loss — while destroying nothing. The `force-push` conf rows
now say so at the push, name the per-file patch-id reconciliation
that separates the two, and mark the one PERMANENT `2` (a multi-URL
remote, `#930`) with its per-URL next step. The posture is not
weakened: a false UNSAFE costs one reconciliation, a false SAFE costs
a sibling their commit.

**And it must compare the ref the push MOVES, not `HEAD`** — the third
correction, and a false SAFE rather than a refusal. A push updates
`refs/heads/<dst>` on the remote from `<src>` locally, and neither is
necessarily the checked-out branch. Measured: local `feature` lacking a
sibling commit while HEAD sat on `integration` which contained it
printed `SAFE rc 0`, and the push then reported `(forced update)` with
the sibling gone. The script now resolves `<branch>` / `<src>:<dst>` /
`push.default` the way git does, and refuses (never guesses) for
`matching`, `nothing`, and a detached HEAD with no ref given.

**And a fourth: it compared the wrong REMOTE.** `remote.pushDefault` and
`branch.<n>.pushRemote` select the push remote; the check assumed
`origin`, said SAFE, and the push destroyed a commit on the other remote.

Four false clearances on four distinct axes — authorship, cannot-tell-
failure-from-clearance, wrong ref, wrong remote — and **every one found
by BUILDING the failing case, never by reading the code**. The diagnosis
that ended it is not any of the four fixes: each round was
**re-implementing a piece of git's own push-target resolution**, and that
surface (`push.default`, `remote.pushDefault`, `branch.<n>.remote`,
`branch.<n>.merge`, `branch.<n>.pushRemote`, explicit refspecs, `+`
markers, `--all`, `--mirror`, per-remote push refspecs) is larger than
anyone enumerates in advance. Fixing one axis per round only relocates
the hole.

So the check now **asks git instead of modelling it** —
`git push --dry-run --porcelain --force <your args>` reports exactly
which refs move on which remote, authoritative by construction because it
IS the resolution. That deleted the class rather than adding a fifth
axis, and as a side effect multi-ref pushes became answerable instead of
refused.

Two transferable rules: **an answer you cannot vouch for must not look
like a good one**, and **when a check keeps re-deriving something a tool
already computes, stop deriving and ask the tool.**

## How injection works

`monitor/spawn-worker.sh` resolves `NEXUS_ROOT` — an inherited,
valid `$NEXUS_ROOT` wins, else its own `dirname`, except that a
script-relative root sitting under another nexus's `work/` is
re-rooted to that primary (`#577`), so state never forks into a
secondary clone — reads this file, extracts the `## Worker floor`
section body via awk
(`/^## Worker floor[[:space:]]*$/` to the next `## ` H2 or EOF; per-spawn
Claude Code settings come from the dedicated
`monitor/worker-settings.json` file — see `## Worker settings`
below), and composes the worker's prompt as three blocks
separated by `---`:

1. A synthesised `## Worker environment` header listing absolute
   paths — workdir, primary nexus root, primary reports dir.
   Workers in secondary clones (worktrees, fresh clones) read
   the absolute reports dir from this header so their final
   report lands in the primary clone's `reports/`, not their
   own clone's.
2. The `## Worker floor` body extracted from this file.
3. The orchestrator's task-specific prompt.

Then `claude` launches in a tmux window. Missing file or empty
section → exit non-zero with a clear error; the spawn never
proceeds without the floor.

**Conditional fourth block — `--reply-to`.** When (and only when) the
spawn carries `--reply-to <request-id>`, the launcher extracts the
`## Reply-to wrap-up override` section the same awk way, substitutes
the literal `<REQUEST_ID>` token with the validated id, and inserts it
between block 2 and block 3. Without the flag the section is never
read and the composed prompt is byte-identical to the pre-flag
behaviour — regression-pinned in
`monitor/watcher/test-spawn-worker-reply-to.sh` T1, which compares the
no-flag prompt against an independent reference composition rather
than a checked-in golden (a golden churns on every legitimate floor
edit and gets rubber-stamped). This is the
orchestrator's dispatch-time choice of delivery surface — channel vs
GitHub — never something parsed out of a remote client's prose. See
`## Reply-to wrap-up override` below for the injected text and
`skills/nexus.remote-access` for the channel itself.

H2 boundaries are load-bearing for the awk extraction. Don't
introduce H2s inside the floor section, and don't use level-1
headers anywhere except the document title above.

`## Reply-to wrap-up override` is, like `## Worker floor`, a
**pure injectable body** — every byte of it lands in the worker's
prompt, so keep orchestrator-facing meta-prose out of it (it
belongs here instead).

`--print-prompt` emits the composed prompt to stdout and exits
without spawning a tmux window — useful when validating that
the env header and floor render as intended.

## Worker floor

Rules every worker follows. **Deeper rules arrive just-in-time:**
a PreToolUse/PostToolUse hook injects the relevant reminder into
your context the moment you reach for a footgun (self-matching
`pkill`, a wrong-clone `git push`, a `gh` write, launching an
async job, a poisoning asset URL). You don't need to hold those
here — act on the hook when it fires. Consult `skills/` only when
a hook or your task prompt points you there.

- **Working tree** is in `## Worker environment` above. Whether
  it is your primary tree or a secondary clone (worktree / fresh
  clone) is stated in your task prompt (ask if unstated);
  secondary clones edit and test freely and land canonical
  writes via PR.
- **GitHub writes: mint the bot token EXPLICITLY, then verify the
  author.** `GH_TOKEN=$("$NEXUS_ROOT"/monitor/mint-token.sh) gh
  <write> …`, or `monitor/ng <verb>` (which mints internally). Do
  NOT rely on the PATH-front `gh` shim — it is defence in depth,
  not the mechanism (it has been observed broken on a live clone:
  five operator-authored writes in one day, `#497`). After each
  write, assert its identity in one command:
  `"$NEXUS_ROOT"/monitor/assert-bot-author.sh <url-of-your-write>`
  — an operator-authored write SUCCEEDS but GitHub mutes
  self-notifications, so the thread silently goes dark; the
  assertion is the only loud failure. Never `--no-verify`; never
  force-push a **shared** branch (`dev`, `main`, or any branch
  someone else has pushed commits to) — force-pushing your **own**
  PR branch after rebasing it onto the current base is expected.
  `git commit` / `git push` use your identity, everything else
  the bot's.
- **A negative claim about a repository is only as old as its
  last fetch.** `git branch -a`, `git log --all`, `git cat-file
  -e` and friends read the LOCAL object store — a commit that was
  never fetched is not "absent from the repo", it is absent from
  your copy, and every follow-up check agrees with the wrong
  answer. `## Worker environment` above prints your clone's
  remote-tracking date; if a `no such branch / no newer design /
  nobody has done this` answer is going into a report or a
  comment, `git fetch` first or scope the claim to a sha and a
  date. Same family as the `grep -r … reports/` and `git ls-tree`
  glob silent zeros (`#618`, `#707`, `#770`, `#814`).

  **The trap is that LOCAL operations advance REMOTE-knowledge
  indicators.** Two measured instances, both of which read *fresher*
  than your clone actually is:
  - a **FAILED** `git fetch` truncates `.git/FETCH_HEAD` to zero
    bytes and updates its mtime;
  - **your own `git push`** writes `refs/remotes/origin/<branch>`
    locally without fetching anything, so any date derived from
    remote-tracking refs jumps to *now* — and pushing your branch is
    something this floor tells you to do.

  Neither is a fetch time. The only thing that makes a negative claim
  current is an actual successful `git fetch`.
- **Three hazards that used to live in every brief now have TOOLS.**
  Reach for the tool; the refusal it prints IS the explanation, with
  the measured number in it.
  - **A tmux socket path holds 107 bytes** — `sun_path` is 108
    INCLUDING the NUL. tmux composes
    `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/<socket-name>`, and a session
    scratchpad `TMUX_TMPDIR` (~124 bytes here) is over the limit
    before the suffix. Every real-tmux suite then fails `File name
    too long` and reports it as a defect in the code under test —
    and it reproduces on EVERY tree, so "clean `dev` fails too"
    answers YES and means the opposite of what it is read to mean.
    Five wrong attributions and one retracted finding (`#991`).
    `monitor/watcher/run-tests.sh` now REFUSES such a run (exit 2)
    rather than dispatching doomed suites. Check a path yourself
    with `monitor/tmux-socket-fits.sh --socket <name>` (exit 3 =
    too long, naming the measured length); `--suggest` prints a
    dir that fits. Keep it short: `/tmp/<brief>`, never the
    scratchpad — **for the SOCKET DIRECTORY ONLY.** `/tmp/c71780` and
    any short `TMUX_TMPDIR` you pick hold tmux sockets and nothing
    else; everything else you write goes under the session scratchpad
    (`$TMPDIR`) or inside your clone. Measured 2026-09-03: workers who
    read "put scratch in `/tmp/c71780`" literally left **16.5 GiB** of
    per-window payload in a directory whose short name exists for the
    108-byte `sun_path` limit, and `monitor/tmpfs-guard.sh --check`
    now goes UNHEALTHY above `monitor.tmpfs.max_c71780_payload_mib`
    (<your-org>/nexus-code#1422).
  - **Never hand-roll a mutation gate** — `monitor/mutation-gate.sh
    --suite <f> --list`, then `--line N`. Commenting a line that
    does not END a logical line does not delete it, it PROMOTES the
    next line to a standalone command; one such mutant executed
    `yes yes` and filled the sandbox-wide 378 GB `/tmp` to 8 KB
    free (`#1032`). The tool refuses such a line AND, independently,
    bounds every mutant with `timeout` + `ulimit -f` + a free-space
    floor — the second is what saves you, because the first is a
    predicate that can be wrong.
  - **`monitor/public-mirror/build.sh` destroys the checkout it is
    invoked from.** DRY RUN by default (exit 6); `--yes` is the
    opt-in, and a dirty tree is refused (exit 7) unless
    `--allow-dirty` (`#1001`). Throwaway clones only.
- **`ng send` returning `UNKNOWN` is not a licence to re-send** (a fallback fires only on rc 4);
  resolve it after the fact with `ng send <window> --check --last` (or `--list`, then `--check --nonce <hex>`).
- **`sandbox-notify "<msg>"`** on blocker / ready / done.
- **You can reach the orchestrator mid-task — `SendMessage`.** Use it
  for a blocker, a scope question, or a finding that should not wait
  for your report; `sandbox-notify` has been observed missed, and
  nothing else reaches the orchestrator before you wrap up. Address it
  by the name **`ListAgents` prints** — read that name, do not
  construct it: it is normally your tmux window name, but an older
  Claude Code pin degrades to a workdir-derived one. **Never follow a
  `success:false` did-you-mean hint blind**: it proposes
  near-neighbour names, and with siblings like `overlay` beside
  `overlay-sk` a blind retry delivers your message to the wrong agent
  — re-read `ListAgents` instead. **Upward only.** A raw `SendMessage`
  to another WORKER writes no `machine-input.tsv` stamp, so the
  watcher cannot see the re-task: that worker never supersedes its
  last wrap-up and can be reported `wrapped` for work it never did.
  The orchestrator is exempt because nothing retires it on idle-age.
- **Never invoke `pip` in ANY form — `uv pip` only.** That means
  bare `pip`, `pip3`, AND `python -m pip`, every verb (`install`,
  `download`, …). The sandbox's wrapped pip fork-storms without
  bound and took the node down twice in two days
  (<your-org>/nexus-code`#487`); a PATH-front shim now refuses bare
  `pip`/`pip3` and a worker RLIMIT_NPROC ceiling bounds the blast
  radius — this text is the explanation, those hooks are the
  enforcement. PyPI name trap: dandelion's package is
  `sc-dandelion`, not `dandelion`. Same rule generalized: bound
  any command whose process tree can grow without a named bound
  (`ulimit -u`, hard `timeout`, capped `--jobs`) before you run it.
- **Own your async work, and launch it with something that KEEPS
  THE EXIT STATUS.** If you `sbatch` / `srun --no-block` /
  `nohup &` a job, you OWN the wake — don't end your turn with a
  job in flight and no resume mechanism armed. A hook spells out
  the three acceptable mechanisms the moment you launch one; act
  on it then. For a local background job use
  `monitor/async-run.sh --desc "<what>" -- <cmd> …` and read it
  back with `--status <token>`: a bare `nohup … &` destroys the
  exit status (the child survives, reparented to init — the
  parent shell that would reap it does not), so "finished
  cleanly" and "SIGKILLed" both read as simply absent, and a
  producer killed mid-write leaves a TRUNCATED, plausible
  intermediate that passes every emptiness check. **A job at 0% CPU
  for hours is BLOCKED, not long-running** — read its `wchan`, `fd/0`
  and `cmdline` in `/proc` before waiting on it; a command-less
  `> file` typed into a zsh tool call is one way there
  (<your-org>/nexus-code`#1393`: 7 h 30 m, a child `cat` with no
  arguments). If you idle
  anyway the watcher resolves your waits and pastes the verdict
  — that is a BACKSTOP, not your resume mechanism.
  **A retained exit status is not an armed wake**
  (<your-org>/nexus-code`#1523`). `async-run.sh` keeps the rc for you
  to READ; it never RE-INVOKES you, so it is not a parking mechanism.
  Exactly two things re-invoke this agent when a wait ends: the Bash
  tool's `run_in_background` option (the harness re-invokes you when
  the job exits, which is what makes a typed rc actionable) and a
  `Monitor` until-loop (for a condition rather than a job). A parked
  agent must be able to name what will RE-INVOKE it; if the answer is
  a status file, it is not parked — it is asleep. Measured: a skeptic
  `await` launched through `async-run.sh` expired cleanly (rc 4,
  retained) and the agent sat idle 809 s until the watcher backstop
  pasted. Wherever the skeptic contract says to run `await`
  BACKGROUNDED, it means `run_in_background`, never `async-run.sh`.
- **A job that will outlive the 30-minute `Monitor` cap gets a
  longjob WATCH, and you end your turn** (<your-org>/nexus-code`#1535`).
  Every nexus session carries ONE host-armed plugin monitor (the
  longjob-watch dispatcher) that wakes you with a task notification on
  ANY terminal state of a watched subject. Three shapes, cheapest first:
  an `sbatch` / `srun --no-block` is auto-watched by the launch hook
  (nothing to do); a long LOCAL command is
  `monitor/ng longjob run --desc "<what>" -- <cmd …>` (launched via
  `async-run.sh`, rc retained, watch armed, one line); anything else is
  `monitor/ng longjob add slurm:<id>|asyncrun:<token>|pid:<pid>|file:<path>|cmd:'<probe>'`.
  **READ `add`'s LAST LINE.** `dispatcher: ARMED` means end your turn.
  `NOT ARMED` (rc 3) means nothing in this session will wake you: run
  `monitor/longjob-watch.sh await <id> --timeout <s>` in a Bash call with
  `run_in_background: true` instead, then `ng longjob status` says why.
  A watch that cannot tell emits `UNKNOWN … PARKED` after 5 blind polls
  rather than sleeping you forever; every delivered line costs a wake
  PLUS whatever work you then do, so default watches print only their
  terminal state. This closes `#1523`'s shape: `async-run.sh` retains
  an rc and re-invokes nobody, and `asyncrun:<token>` is the wake it
  lacked. `skills/nexus.longjob/SKILL.md` for the rest.
- **Never `| head` an existence query over a large tree, never
  recurse into `reports/`, and route anything that might run long
  through `async-run.sh`** (<your-org>/nexus-code`#1446`). `grep -r … |
  head -5` reads as "stop after 5 hits" and behaves as "scan
  everything" when the hits run out: `head` exits, the producer only
  learns via SIGPIPE on its NEXT write, and with no further matches it
  walks the whole tree in silence — so the hang is specific to the
  answer "no", which is the one you were hunting. Three workers wedged
  49m, 1h54m and 2h48m in one session, each pane reading
  `working-background`. `-m1` bounds per FILE, not overall. Bound the
  WALK: `find DIR -maxdepth N -type f -print0 | xargs -0 grep -l PAT`.
  `reports/` is gitignored, so a recursive `grep` there returns a
  confident zero (`#618`): use `monitor/ng report-grep PAT`, which exits
  3 rather than vouch for a zero it cannot see. And a child at ~0% CPU
  for an hour is BLOCKED on the filesystem, not computing —
  `pane-state` now says so (`bg_wedged=1`).
- **`/tmp/c71780` holds SOCKETS ONLY** (<your-org>/nexus-code`#1422`).
  Its short name exists for the 107-byte `sun_path` limit and nothing
  else; it held 16.5 GiB of per-worker scratch because briefs handed it
  out as general scratch. Scratch goes under the session scratchpad
  (`$TMPDIR` / the directory your brief names) or inside your clone —
  never under `/tmp/c71780`, which the tmpfs reaper deliberately never
  touches because live sockets are exactly what it must not delete.
- **An orphan left by your OWN backgrounded Bash call is stopped
  with `TaskStop`, not with a signal — and the guard that refuses
  it is right.** Backgrounding makes that shell its own SESSION
  LEADER, so it sits OUTSIDE your session and
  `proc-kill-authorized` refuses it `not-owned`. That refusal is
  CORRECT and it is also AMBIGUOUS: *"another agent's"* and
  *"yours, but it left your session"* read identically, and nothing
  downstream disagrees. One orphan ran **twelve hours** because its
  own launcher hit that refusal at ten minutes old and took the
  sibling reading; a second was measured at **28 hours**, still
  looping on a sentinel that could never appear
  (<your-org>/nexus-code`#1235`). The refusal now prints
  `NOT-A-SIBLING` whenever it can establish the parent is yours —
  when you see it, the answer is the harness-native **`TaskStop
  <task-id>`**: the harness launched the task, so the harness can
  stop it. `svc.sh` stops `setsid`-detached services; nothing
  stops a default-deny refusal by hand-rolling a signal past it.
- **Label a parameter you CHOSE as chosen, never as upstream
  convention** (<your-org>/nexus-code`#970`). If you pick a value the
  tool does not default for you — a bin width, a threshold, a seed, a
  filter cutoff — say so plainly in BOTH the script comment and the
  report: *"we chose N because Y"*. Do not write *"the default per
  common usage"* or similar unless you have verified it against the
  tool's own source or docs AND can cite where. Measured: a 40 kb bin
  width annotated as *"the default per common ATAClone usage"* — where
  the argument is REQUIRED and the package ships no default and no
  vignette call supplying one — survived an OOM, a memory patch and
  three failed runs unexamined, because every review of the run treated
  the bin width as settled. That is what the mislabelling buys: a value
  presented as convention is re-derived by nobody downstream, human or
  agent, so the one number nobody chose deliberately is also the one
  number nobody checks.
- **Before you finish, idle, or run low on context: file a
  report and wrap up.** `monitor/ng report-init <slug>` writes a
  five-section skeleton at the canonical reports path (captures
  your session-id + window); fill it in — substantive body, not
  a stub — then:

      monitor/ng wrap-up <issue> <report-path> \
          --trigger-comment <id> --repo <owner>/<repo>

  `wrap-up` runs `report-check` as a pre-flight, uploads the
  report, posts the link comment, rockets the trigger, and walks
  you through anything else that applies at that moment (skeptic
  validation if your spawn required it, finalisation reminders).
  Do task-specific finalisation — build, tests, branch push, PR
  — BEFORE wrap-up. End your turn on exit 0; on **1**, retry only
  the failed step(s) named on stderr. **Exit 3 is not a failure and
  retrying cannot clear it**: every step did what it was asked and
  your correction still reached nobody — the report changed, the
  link comment is composed from `## Summary` alone, and yours is
  byte-identical to the one already posted. Re-running reproduces
  it exactly. Do what stderr says instead: edit `## Summary` in
  place so the correction is IN the composed body and re-run, or
  pass `--comment-body-file`, or say it on the thread yourself.

Deeper skills, consulted only when the above is insufficient:
`skills/nexus.bot/SKILL.md` (verb table, cross-repo `GH_TOKEN`,
push-author verify), `skills/nexus.report/SKILL.md` (section
semantics, append-only, Infrastructure Issues loop). Resolve by
absolute path via the spawn prompt.

## Reply-to wrap-up override

**Wrap-up override — this spawn answers a CHANNEL request, not a
GitHub issue.** Request `<REQUEST_ID>` sits in the nexus request inbox
and its author is blocked on the channel waiting for your answer. The
floor's `ng wrap-up <issue> <report-path>` form does NOT apply to you.
Write your `reports/` report exactly as the floor describes (it is
still your crash-resumption surface), then hand off with:

    monitor/ng wrap-up --reply-to <REQUEST_ID> <report-path>

That delivers your answer over the request/reply channel: no GitHub
issue is opened, no issue comment is posted, no trigger is rocketed.

**The answer that reaches the requester is your report's `## Summary`
section, verbatim.** Write `## Summary` as the ANSWER to the request —
the finding, the number, the recommendation — not as a narration of
your process. If the answer is an artifact that does not belong in
`## Summary` (a table, a dataset, a code listing, a diff), write it to
a file and pass `--answer-file <path>` instead; that file's bytes
become the reply body.

If the orchestrator ALSO gave you a GitHub issue number for this task,
add `--issue <n>` — wrap-up then does both (channel reply AND the
normal upload + link comment).

## Just-in-time hooks

These hooks (wired in `monitor/worker-settings.json`) deliver the
rules that used to live in the floor, at the exact tool call that
makes each relevant. Each reminder fires **once per worker
session** (per-window dedup) so it informs without nagging.

| Hook (PreToolUse/PostToolUse) | Fires when… | Delivers |
|---|---|---|
| `hooks/bash-footgun-guard.sh` (Bash, data-driven by `bash-footgun-patterns.conf`) | a Bash command matches a footgun pattern: `pkill/pgrep -f`, `kill $(jobs -p)`, `git push`, `git push --force`/`-f`, `scancel --name/--partition`, foreground `sleep`, `python…\| tail`, `ml…\| tail` | the specific self-kill / wrong-remote / force-push-boundary / sibling-job / buffering reminder as `additionalContext` |
| `hooks/gh-write-guard.sh` (Bash) | a `gh` write is attempted | bot-identity guidance (`ng` verbs, `GH_TOKEN` mint for cross-repo); already warns on a bypass that would post as the operator |
| `hooks/async-launch-detect.sh` (Bash) | `sbatch` / `srun --no-block` / `nohup &` is launched | the async-ownership rule + the three resume mechanisms; records the wait for the watcher's `idle-orphan-async` |
| `hooks/bash-footgun-guard.sh` row `async-status` (Bash) | a bare `nohup … &` in command position | hands over `monitor/async-run.sh`, which retains the rc and registers a RESOLVABLE `asyncrun:<token>` wait (<your-org>/nexus-code#1071) |

**Proposed, NOT wired.** The following is a design note, not a
guard that exists. It sat inside the table above, under a heading
asserting the hooks are wired in `monitor/worker-settings.json`, and
the heading wins on a skim — so this text shipped in every worker
prompt promising a blocking guard against the irrecoverable
`user-attachments` poisoning. The worker who believes it exists is
exactly the worker who will test it (<your-org>/nexus-code#568 C5).

| Proposed hook | Would fire when… | Would deliver |
|---|---|---|
| `hooks/context-poison-guard.sh` (Read/WebFetch) | a `user-attachments` URL is about to be read | BLOCK (exit 2) and redirect to `ng fetch-asset` before the session is poisoned |

Until it is written and wired, the `user-attachments` rule is
enforced by convention only: never hand such a URL to Read or to a
sub-agent; use `monitor/ng fetch-asset <url>` and read the local file.

Adding a footgun to `bash-footgun-guard` is a **data edit** to
`bash-footgun-patterns.conf` (row `tag\|severity\|command_regex\|message`),
no code change — mirroring `async-launch-patterns.conf`. Footguns
whose trigger is a literal shell pipe can't be conf-expressed
(the `\|` field separator) and are matched in-code in the hook.

Case-by-case rules the orchestrator injects per-spawn (not
floor, not hook) — because they apply only to some tasks and the
orchestrator knows the task shape at spawn time:

- **Secondary-clone semantics** beyond the one-line floor note
  (what's canonical, what routes via PR).
- **External-repo redaction** — grep the draft for internal
  identifiers before any external-public write.
- **Watcher-branch isolation** — a worker touching
  `monitor/watcher/*` must operate in a separate clone/worktree.
- **Python-under-Slurm toolchain** — `source
  monitor/bootstrap-venv.sh` (the nexus-wide, home-free `uv` +
  managed-interpreter venv) when the task runs compute Python.
- **Out-of-tree deliverable probe** — `ng write-probe <target>`
  before staging a costly result to a path outside the working
  tree (workdir + reports dir are already probed at spawn).
- **Relevant `CLAUDE.md` gotchas** — `#N` auto-link, `git
  checkout -- <path>` destructiveness, `uv pip` over `pip`,
  `pane-state.sh` — pulled in when the task touches them.

## Worker settings

Per-spawn Claude Code settings live in **`monitor/worker-settings.json`**
(repo-tracked JSON file, not embedded here). Every spawn invokes
`claude --settings $NEXUS_ROOT/monitor/worker-settings.json
--dangerously-skip-permissions ...` — `spawn-worker.sh` passes the
flag automatically. Operators editing worker hooks edit that JSON
file directly; no awk extraction, no marker convention, no per-spawn
tmp file. Missing file is a spawn-blocker (exit 10) so a
misconfigured fork fails fast.

The default file ships with:

- **`skipDangerousModePermissionPrompt: true`** — suppresses the
  bypass-permissions startup dialog ("Yes, I accept" / "No, exit")
  that otherwise renders on first invocation in a fresh worker dir.
  Without this, workers spawned into a never-before-claude'd
  worktree wedge on the dialog until manually dismissed.
- **`hooks.PostToolUse / Notification / UserPromptSubmit`** —
  feed `monitor/worker-heartbeat.sh` (which writes
  `$NEXUS_ROOT/monitor/.state/heartbeat/$NEXUS_WORKER_WINDOW.json`
  for `pane-state.sh` to consume as the primary busy/idle signal)
  and `$NEXUS_ROOT/monitor/.state/worker-notifications.jsonl`
  (which `render_idle_prelude` in `_idle_probe.sh` reads to
  surface a per-cycle `N awaiting-input` count). The worker's
  process tree exports `NEXUS_ROOT` and `NEXUS_WORKER_WINDOW`,
  which hook command strings reference verbatim — those expand
  when the hook subprocess fires.
- **`hooks.PostToolUse` matcher `Bash`** — fires
  `monitor/hooks/async-launch-detect.sh`, which reads
  `monitor/async-launch-patterns.conf` and appends a `(kind, id,
  desc)` row to the heartbeat's `external_waits` array when the
  worker's Bash command matches a launch pattern (sbatch, srun
  --no-block, nohup &). The watcher's classifier uses
  `external_waits` to emit `idle-orphan-async` per issue #183.
  Adding a new launch class is data-only (edit the conf file).

Settings precedence: CLI > local > project > user. The injected
file wins on any key it defines (notably any `hooks.*` event)
and leaves unrelated user-global settings (model, theme, MCP
servers) untouched. Operators with a custom global `Notification`
hook should fold their logic into `monitor/worker-settings.json`
or accept that workers won't fire it.

Boundary discipline if you add hooks: a hook command runs
synchronously on the agent's turn (especially `PostToolUse`).
Keep commands O(milliseconds). Long-running side effects belong
in `&`-backgrounded commands or separate pollers, not the hook
itself.

Reliable events for nexus use: `PostToolUse`, `Notification`,
`UserPromptSubmit`, `SessionStart`. Unreliable: `Stop` /
`SubagentStop` (only fires on graceful exit; `tmux kill-window`
skips them).


## See Also

- `nexus.bot` — GitHub identity, `ng` verb table, wiki upload,
  push-author verify, fail-loud token guard.
- `nexus.report` — report sections, append-only convention,
  Infrastructure Issues feedback loop.
- `nexus.tmux-spawn` — the spawn-worker.sh launcher pattern that
  injects the `## Worker floor` section above into every prompt.
- workspace `CLAUDE.md` — the cross-cutting workspace contract.
  Common gotchas (`#N` auto-link, `user-attachments` poisoning,
  `git checkout -- <path>` destructive, `uv pip` over `pip`) live
  there; the orchestrator pulls the relevant ones into worker
  prompts only when they apply to the task.
