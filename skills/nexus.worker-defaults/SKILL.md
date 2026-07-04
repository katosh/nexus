---
description: "Always-applies workspace defaults for any nexus-spawned worker: bot identity for GitHub writes, no --no-verify/force-push, sandbox-notify, report convention. The ## Worker floor section is injected verbatim into every spawn prompt by monitor/spawn-worker.sh."
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

## How injection works

`monitor/spawn-worker.sh` resolves `NEXUS_ROOT` from its own
`dirname` (so it works in forks and fresh clones), reads this
file, extracts the `## Worker floor` section body via awk
(`/^## Worker floor$/` to the next `## ` H2 or EOF; per-spawn
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

H2 boundaries are load-bearing for the awk extraction. Don't
introduce H2s inside the floor section, and don't use level-1
headers anywhere except the document title above.

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
- **GitHub writes post as the bot automatically** — a PATH-front
  `gh` shim rewrites identity, so a bare `gh …` (or `monitor/ng
  <verb>`) is already correct. Never `--no-verify`, never
  force-push; fix the root cause. `git commit` / `git push` use
  your identity, everything else the bot's.
- **`sandbox-notify "<msg>"`** on blocker / ready / done.
- **Own your async work.** If you `sbatch` / `srun --no-block` /
  `nohup &` a job, you OWN the wake — don't end your turn with a
  job in flight and no resume mechanism armed. A hook spells out
  the three acceptable mechanisms the moment you launch one; act
  on it then.
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
  — BEFORE wrap-up. End your turn on exit 0; on non-zero, retry
  only the failed step(s) named on stderr.

Deeper skills, consulted only when the above is insufficient:
`skills/nexus.bot/SKILL.md` (verb table, cross-repo `GH_TOKEN`,
push-author verify), `skills/nexus.report/SKILL.md` (section
semantics, append-only, Infrastructure Issues loop). Resolve by
absolute path via the spawn prompt.

## Just-in-time hooks

These hooks (wired in `monitor/worker-settings.json`) deliver the
rules that used to live in the floor, at the exact tool call that
makes each relevant. Each reminder fires **once per worker
session** (per-window dedup) so it informs without nagging.

| Hook (PreToolUse/PostToolUse) | Fires when… | Delivers |
|---|---|---|
| `hooks/bash-footgun-guard.sh` (Bash, data-driven by `bash-footgun-patterns.conf`) | a Bash command matches a footgun pattern: `pkill/pgrep -f`, `kill $(jobs -p)`, `git push`, `scancel --name/--partition`, foreground `sleep`, `python…\| tail`, `ml…\| tail` | the specific self-kill / wrong-remote / sibling-job / buffering reminder as `additionalContext` |
| `hooks/gh-write-guard.sh` (Bash) | a `gh` write is attempted | bot-identity guidance (`ng` verbs, `GH_TOKEN` mint for cross-repo); already warns on a bypass that would post as the operator |
| `hooks/async-launch-detect.sh` (Bash) | `sbatch` / `srun --no-block` / `nohup &` is launched | the async-ownership rule + the three resume mechanisms; records the wait for the watcher's `idle-orphan-async` |
| `hooks/context-poison-guard.sh` (Read/WebFetch — **proposed**) | a `user-attachments` URL is about to be read | BLOCKS (exit 2) and redirects to `ng fetch-asset` before the session is poisoned |

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
