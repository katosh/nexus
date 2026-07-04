---
description: "Spawn delegated nexus work in tmux windows via prompt-file + launcher; never use the in-process Agent tool for nexus delegations."
---

# nexus.tmux-spawn — delegating work into tmux windows

TRIGGER when: agent considers delegating non-trivial work to another
agent for a nexus project; agent reaches for the in-process `Agent`
tool to drive a `work/<project>` task; agent needs to send a follow-up
message to a running tmux agent; agent is briefing a fresh worker on a
project that already has prior reports.

## The one rule

For any nexus delegation, **spawn a tmux window** using the
prompt-file + launcher pattern below. Do **not** use the in-process
`Agent` tool (sub-agent) for nexus delegations.

Use the `Agent` tool only for tight, bounded research or file searches
that stay inside your own thinking loop (codebase questions, "find all
the places that …"). Never for delegations the nexus needs to track.

### Continue vs. spawn — check first

`ng wrap-up` auto-retains the source window by default (see
`nexus.window-cleanup` "Continue-vs-spawn"). Before spawning a
fresh worker for a follow-up, check: is there a retained worker
whose context covers this? If yes — same topic, idle pane, < 70%
context, within retain TTL — re-engage the existing window via a
`monitor/paste-followup.sh` (alias `ng paste-followup`) follow-up instead of spawning. If the window is gone
(or its pane is dead) but the prior session's loaded context is
still worth re-attaching, respawn it with `monitor/ng respawn
<window>` (see "Resuming a closed worker" below). Otherwise spawn
fresh AND pass `-r <prior-report-path>` to
`monitor/spawn-worker.sh` so the new worker reads What Was Done /
Current State / How to Resume before starting.

## Why

In-process `Agent` sub-agents are:

- **Blocking** — they consume the orchestrator's turn until they
  return.
- **Distracting** — they pull the nexus away from its main
  monitor-agent responsibilities.
- **Context-hungry** — their final result funnels back into the
  orchestrator's context even when launched async, eating tokens for
  output the orchestrator doesn't need to see in detail.

Tmux agents, in contrast:

- Run **truly parallel** on their own compute.
- Land their output **in the real world** — commits, reports in
  `reports/`, GitHub comments — without ever traversing the
  orchestrator's context.
- Are **visible** (`tmux list-windows`), **inspectable**
  (`tmux capture-pane`), and **redirectable** (paste-buffer
  follow-ups).

The orchestrator learns about their progress through the watcher loop
(reports under `reports/`, the dashboard, `tmux list-windows` snapshots),
not through the Agent tool's transcript.

**Never instruct a worker to `SendMessage` the orchestrator.** A
tmux-spawned worker is an independent `claude` session — not an
in-process subagent and not an Agent Team peer — so the call fails
("No agent named 'orchestrator' is currently addressable"). The
worker→orchestrator channel is the report + `ng wrap-up` event
(surfaced by the watcher), plus `sandbox-notify` for urgent
out-of-band pings. True cross-session messaging would require Agent
Teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` + `TeamCreate`),
which the standard spawn path does not set up.

For worker-pane inspection, call `monitor/pane-state.sh <window-index>`
instead of parsing `tmux capture-pane` output yourself. It
classifies the pane (`idle | busy | user-typing |
autosuggest-only | empty | blocked | absent`) and reports
`active=<0|1>` — the source-of-truth for "is this real user
input or just Claude Code's autosuggest ghost".

**Manual fallback** when the helper returns something surprising or
appears miscalibrated (e.g. after a Claude Code release): inspect
the raw escape sequences yourself with

```sh
tmux capture-pane -t 0:<win> -e -p -S -10 | cat -v
```

and look at the line containing `❯<NBSP>` (the input row).
`cat -v` renders ANSI escapes as `^[`, so the markers are visible
as plain text:

| `cat -v` rendering         | Meaning                                  |
|---|---|
| `^[[7m<char>^[[0;2m...`    | autosuggest (dim ghost) — ignore         |
| `^[[38;5;231m...`          | bright user-typed text — respect         |
| `^[[7m ^[[0m` (space only) | empty input box                          |
| `↓ <N> tokens` near input  | active spinner — agent is busy           |
| `✻ <Verb>ed for <dur>`     | past-tense banner — agent is idle        |

If a Claude Code update shifts these markers (e.g. `0;2m` → `2m`
alone), update `_detect_autosuggest` / `_detect_user_typing` /
`_detect_busy` in `monitor/pane-state.sh` — they're the single
edit points.

When Agent Teams pane splitting fails (common in nested tmux / sandbox
environments), the prompt-file + launcher pattern is the reliable way
to spawn. **Never pass prompts inline via shell expansion** — it
breaks in nested tmux.

## The pattern

Canonical: `monitor/spawn-worker.sh` handles floor injection,
launcher generation, and tmux window creation in one call. The
orchestrator writes only the task-specific prompt — the worker
floor (bot identity, no `--no-verify`/force-push, sandbox-notify,
report convention) is injected automatically from
`skills/nexus.worker-defaults/SKILL.md`'s `## Worker floor` section.

```bash
# 1. Write the TASK-SPECIFIC prompt to a temp file. Do NOT include
#    the worker floor — it is prepended automatically.
cat > /tmp/prompt-TASKNAME.txt <<'EOF'
Your task-specific prompt. Multi-line, free-form, can include
backticks and $variables — the heredoc keeps everything literal.
EOF

# 2. If the brief names a worktree/clone, create it FIRST so the
#    worker can land in its own working tree (not the nexus root).
git -C "$NEXUS_ROOT" worktree add \
    work/<project>-TASKNAME \
    -b <user>/<task>

# 3. Single call: floor injection + launcher + tmux window. -c MUST
#    point at the work dir the worker will actually edit in.
monitor/spawn-worker.sh \
    -n TASKNAME \
    -c "$NEXUS_ROOT/work/<project>-TASKNAME" \
    -p /tmp/prompt-TASKNAME.txt
```

### What the helper does

- Resolves `NEXUS_ROOT` from its own location, so it works from
  forks and fresh clones with no path hardcoding.
- Reads `$NEXUS_ROOT/skills/nexus.worker-defaults/SKILL.md`,
  extracts the `## Worker floor` section body up to the next
  `## ` H2 (or EOF), and prepends it to the prompt with a `---`
  separator before launching `claude`.
- Fails loud (non-zero exit + clear stderr) on missing floor file,
  empty floor section, unreadable prompt-file, missing workdir,
  no tmux server, or window-name collision.
- Generates the same self-cleaning `/tmp` launcher that the inline
  fallback below uses.

### Per-worker model pin (`--model <model-id>`)

Opt-in, default-off. `--model claude-fable-5` (or `--model=<id>`)
pins THIS worker's `claude` to the given model without touching the
global default or any other worker. The pin is threaded through the
generated launcher into `claude` — and, under the loop wrapper,
into every `claude --continue` respawn, so a restarted worker keeps
its model. When omitted, the launcher is byte-identical to the
pre-flag behaviour. The id is not validated at spawn time; an
invalid id fails at `claude` launch (existing cause-classify path).

Two caveats:

- This is **launch-time model selection**, the same effect as a
  `model` pin in `worker-settings.json` — it does NOT override any
  Anthropic-side model auto-switch (e.g. the content safeguard that
  can move a session off Fable on turn 1). Don't advertise it as a
  guaranteed "runs on Fable" switch; it's model-selection plumbing.
- `spawn-worker.sh --resume` does not currently re-apply a model
  pin; only the loop wrapper's `--continue` respawns carry it.

Phase 2 (separate issue, NOT yet implemented): an orchestrator
convention that reads a `model:<id>` issue label and passes
`--model` automatically, so a labeled issue runs on the chosen
model hands-free.

### Inline fallback (bootstrap only)

If `monitor/spawn-worker.sh` is unavailable — fresh clone that
hasn't synced this helper, ad-hoc spawning from a directory that
isn't a nexus root, or debugging the helper itself — fall back to
the inline pattern. **The orchestrator must inject the worker
floor manually in this case** — copy the `## Worker floor` body
from `skills/nexus.worker-defaults/SKILL.md` into the prompt above
the task content.

```bash
cat > /tmp/prompt-TASKNAME.txt <<'EOF'
[paste the ## Worker floor body verbatim here]

---

Your task-specific prompt.
EOF

# Resolve $CLAUDE_BIN: project-local install if present, else system
# claude on PATH. Spawn surfaces in monitor/ all source
# `monitor/_claude-bin.sh`; this inline fallback inlines the same logic
# so a bootstrap operator without the helper still picks the right
# binary.
CLAUDE_BIN="${CLAUDE_BIN:-}"
if [[ -z "$CLAUDE_BIN" ]]; then
    if [[ -x "$NEXUS_ROOT/node_modules/.bin/claude" ]]; then
        CLAUDE_BIN="$NEXUS_ROOT/node_modules/.bin/claude"
    else
        CLAUDE_BIN="$(command -v claude)"
    fi
fi

cat > /tmp/launch-TASKNAME.sh <<LAUNCHER
#!/bin/bash
prompt=\$(</tmp/prompt-TASKNAME.txt)
rm -f /tmp/prompt-TASKNAME.txt /tmp/launch-TASKNAME.sh
"$CLAUDE_BIN" --dangerously-skip-permissions "\$prompt"
LAUNCHER
chmod +x /tmp/launch-TASKNAME.sh

tmux new-window -d -n 'TASKNAME' -c '/path/to/workdir'
tmux send-keys -t 'TASKNAME' '/tmp/launch-TASKNAME.sh' Enter
```

### Why this shape

- **Floor injection by the launcher, not the orchestrator.** The
  irreducible safety floor lives in one editable file
  (`skills/nexus.worker-defaults/SKILL.md`); the spawn mechanism
  distributes it. Worker prompts under `work/<project>/` cwd
  cannot resolve relative `skills/` paths, so a "read this skill
  first" instruction would silently fail. Injecting the floor
  body sidesteps the path problem entirely.
- **Prompt file, not shell expansion.** Inline `"$(cat ...)"` or
  single-quoted multi-line prompts break with special characters,
  nested quotes, and zsh escaping in tmux. The `<<'EOF'` heredoc
  preserves the prompt verbatim.
- **Separate `new-window` and `send-keys`.** Combining them as
  `tmux new-window -n name "command"` can fail silently in nested
  tmux sessions.
- **`-d` flag.** Creates the window without switching the attached
  client's focus; the orchestrator keeps its current view.
- **`-c <absolute-workdir>`.** Sets the working directory for the
  spawned agent. Use absolute paths (e.g.
  `$NEXUS_ROOT/work/<project>`). Pass the worker's actual work dir,
  not the nexus root.
- **Self-cleaning.** The launcher removes its own temp files after
  reading them, so /tmp doesn't accumulate prompt scraps.
- **`"$CLAUDE_BIN" --dangerously-skip-permissions "$prompt"`.** Positional
  arg starts an **interactive** session with the prompt as the first
  user turn. Do not use `-p`/`--print` — that's non-interactive print
  mode and exits after one turn. `$CLAUDE_BIN` resolves to the
  project-local install (`$NEXUS_ROOT/node_modules/.bin/claude`) if
  present, otherwise system `claude` on PATH. `monitor/_claude-bin.sh`
  is the shared resolver; spawn surfaces source it before writing the
  launcher heredoc.

## Skeptic spawn modes

`monitor/spawn-worker.sh` decides at spawn time whether the
worker's result will be independently validated by a skeptic. The
full skeptic protocol (mandate, the worker↔skeptic comms channel,
verdict ladder, recursion) lives in
`skills/nexus.skeptic/SKILL.md`; this section covers only the
**spawn-time decision** the orchestrator makes.

Three flags govern it:

- `--skeptic <require|auto|deny>` — the mode (default `auto` when
  unspecified).
- `--skeptic-depth N` — recursion counter (default 0).
- `--skeptic-role --skeptic-target <reviewed-window>` — passed
  only when spawning a skeptic itself, not a normal worker.
- `--skeptic-orig <original-worker-window>` — with `--skeptic-role`
  on a RECURSIVE (second-or-later) skeptic: the chain root, so the
  skeptic reviews the WHOLE chain (original worker + prior skeptic)
  and can adjudicate their disagreement. Defaults to
  `--skeptic-target`; `ng wrap-up` threads it forward in the
  recursive spawn command it emits.

The mode is stamped into the worker's provenance record
`monitor/.state/windows/<window>.json` (fields `skeptic_mode`,
`skeptic_depth`, `skeptic_role`, `skeptic_target`, `skeptic_orig`)
and read back authoritatively by `ng wrap-up`. It is **NOT** written
into an ordinary worker's prompt — the worker is not pre-warned of a
possible subsequent skeptic and learns of it only at wrap-up
(`skills/nexus.skeptic`). Only a `--skeptic-role` spawn carries a
`Skeptic role: YES` line in its `## Worker environment` header, since
being a skeptic IS its task.

### The three modes

| Mode | Meaning | Wrap-up behaviour |
|---|---|---|
| `require` | A skeptic MUST validate this worker's result. | `ng wrap-up` emits "SKEPTIC REQUIRED", sets a skeptic-pending marker; the task is not "done" until a skeptic returns a verdict. |
| `auto` (default) | The worker DECIDES at wrap-up whether a skeptic is warranted, per the responsible-default heuristic. | The worker applies the heuristic and must record the decision. |
| `deny` | No skeptic (trivial / low-impact / easily-reversible work). | Wrap-up records the denial. |

### Picking a mode at spawn time

Bias toward skepticism. When unsure, leave it UNSPECIFIED — `auto`
is the default and lets the worker make the responsible call at
wrap-up.

- **`require`** — high-impact core-infra changes
  (watcher/monitor/spawn/`ng`/skills/CI), scientific
  results/figures/gene-lists/data/analysis, external-public writes,
  or anything hard to reverse.
- **`deny`** — genuinely trivial, reversible work (doc typo,
  one-line config).
- **UNSPECIFIED (`auto`)** — anything else, or when unsure. The
  worker applies the responsible-default heuristic at wrap-up.

### The responsible-default heuristic (the `auto` decision)

Also printed by `ng wrap-up`. Spawn a skeptic when the task:

- (a) touched shared infrastructure;
- (b) produced or altered scientific
  results/figures/gene-lists/data/analysis;
- (c) made or proposed external writes;
- (d) involved non-trivial reasoning the worker is uncertain about;
- (e) has high blast radius / is hard to reverse.

Skip ONLY trivial, low-impact, easily-reversible, high-confidence
work.

### Spawning a skeptic to review a worker

```bash
monitor/spawn-worker.sh \
    -n <orig>-skeptic \
    -c <workdir> \
    -p /tmp/prompt-skeptic.txt \
    --skeptic-role \
    --skeptic-target <orig-window> \
    --skeptic-depth <N+1>
```

This records a `skeptic-spawn` action-log event and seeds the
comms channel for the reviewed task. The skeptic's prompt should
brief it per `skills/nexus.skeptic/SKILL.md`.

Recursion is bounded: depth strictly increments, capped at
`monitor.skeptic.max_depth` (default 3). A second-pass skeptic
spawns only when the prior pass found substantive new issues; it
reviews the **whole chain** (the original worker + the prior
skeptic) and adjudicates their disagreements. At the cap, escalate
to the operator instead. Full details in
`skills/nexus.skeptic/SKILL.md`.

## Sending follow-up messages

`claude "prompt"` starts an interactive session, so follow-ups go
through tmux. The message is queued and delivered when the agent's
current turn finishes.

**Always use the helper — never raw tmux commands:**

```bash
# Write the follow-up to a temp file (avoids quoting issues)
cat > /tmp/followup-TASKNAME.txt <<'EOF'
Your follow-up instructions here.
EOF

monitor/paste-followup.sh 'TASKNAME' --file /tmp/followup-TASKNAME.txt \
    --note 'one-line what/why' --issue 42
rm -f /tmp/followup-TASKNAME.txt
# Short messages: monitor/paste-followup.sh 'TASKNAME' --message '...'
```

**Why the helper is mandatory (issue #201).** Every paste fires the
worker's `UserPromptSubmit` hook, and the watcher attributes each
stamped submit to either the operator or the orchestrator. The
helper stamps the machine-input ledger BEFORE pasting; a raw
`tmux paste-buffer` follow-up is unstamped, so the watcher reads
the resulting submit as OPERATOR input, marks the window
`operator-engaged`, and mutes its stall-nag /
`idle_prompt` surfacing for up to 24 h — exactly the worker you
wanted to keep an eye on. The helper also handles the mechanics that
used to be hand-rolled here: `set-buffer` + `paste-buffer` (atomic,
any length; `send-keys` drops characters on long strings), the
paste→Enter delay, and the VI-mode hazard below. It fails loudly
when the window is gone (then use `spawn-worker.sh --resume`).

## VI-mode hazard (context for the helper's insert-mode guard)

Claude Code uses VI keybindings. If the agent is in **normal mode**
(no `-- INSERT --` in the status bar), keystrokes are interpreted as
VI commands and a raw-pasted message is silently lost (or worse,
executes random VI motions on the prompt line).

`monitor/paste-followup.sh` already sends the `i BSpace` insert-mode
guard before every paste (the `i` switches to insert mode when
needed and self-inserts otherwise; the `BSpace` erases the
self-inserted character — safe in both modes). Nothing to do
manually; this section survives as documentation of the guard's
purpose.

## Resuming a closed worker — `--resume` / `ng respawn`

When the worker's tmux window is gone (or its pane is dead) but the
Claude Code session transcript is still on disk, the canonical
respawn is:

```bash
monitor/spawn-worker.sh --resume <window-name>
# equivalently:
monitor/ng respawn <window-name>
```

That single call resolves the session-id (report frontmatter →
`window-close` action-log event → freshest
`~/.claude/projects/<workdir-slug>/*.jsonl`) and the workdir (live
pane path → action-log events → spawn-prompt cache), then recreates
the window with **full spawn parity**: exported `NEXUS_ROOT` +
`NEXUS_WORKER_WINDOW`, `--settings monitor/worker-settings.json`,
`--dangerously-skip-permissions`, the resolved `$CLAUDE_BIN`, the
window options (`remain-on-exit` / `automatic-rename` /
`allow-rename`), the cwd pin, and fresh lifecycle anchors
(engagement-log row + `spawn` action-log event tagged
`mode=resume`). It also suppresses the stale-large-session resume
picker so the transcript reloads as-is.

**Busy-at-death workers get a continuation nudge automatically.**
`claude --resume` reloads the conversation but does NOT restart an
interrupted turn — a worker that was mid-task when its session died
would come back idle with the task half-done. When the window's
last heartbeat shows a mid-turn state (`busy` / `user_prompt`) or a
pending-tool record survives, the respawn passes a continuation
prompt alongside `--resume` so the worker re-orients and picks the
task back up. Idle-at-death workers get no nudge (it would inject a
phantom user turn); a worker that died on `permission_prompt` is
also not auto-nudged — it was waiting on a human, and "continue"
could steamroll the pending question.

**Never hand-roll `tmux new-window … claude --resume <id>`.** A
manual resume that forgets the env exports breaks every hook in
`worker-settings.json` — heartbeat, async-launch detect, pending-tool
tracker, notifications — each failing with
`/bin/sh: /monitor/worker-heartbeat.sh: not found` on every tool use,
and the watcher loses busy/idle visibility for the window.

Variants:

- `--resume <session-id> -n <window>` — explicit UUID override when
  the resolver would pick the wrong session.
- `-c <workdir>` — explicit workdir when no trace of the window
  remains on disk.
- `--replace` — kill a still-LIVE same-name window first (a dead
  pane is replaced automatically; without `--replace` a live pane is
  refused — paste a follow-up into it instead).
- `--nudge` / `--no-nudge` — force or suppress the continuation
  prompt, overriding the heartbeat-driven default.
- `--dry-run` — print the resolved window/session/workdir + nudge
  decision without touching tmux; use as a pre-flight.

Resolution failures are loud (distinct exit codes + the list of
sources tried). When the transcript has been pruned, fall back to a
fresh spawn with `-r <prior-report-path>`.

Decision guidance — live retained window → paste a follow-up; window
gone but session context still valuable (loaded state, direct
continuation) → `ng respawn`; new direction or stale session → fresh
spawn with `-r`. See `nexus.window-cleanup` "Continue-vs-spawn" for
the full criteria.

## Naming convention

Short, descriptive, kebab-case window names tied to the task or
project: `repro-skills`, `data-mgmt`, `slurm-update`, `kompot-fig3`,
`<shared-node-tool>-list`. The watcher's `tmux list-windows` snapshot surfaces
the name on the dashboard, so use something a human can identify at a
glance.

Before spawning, check `tmux list-windows` for collisions. The
dashboard's running-agents table also lists current windows.

## Spawning interactive windows (`--kind interactive`)

Most workers are **task windows**: they pick up a scoped job, file a
report, and close. Append `--kind interactive` (and `--topic "…"`) to
`monitor/spawn-worker.sh` when instead you are opening an open-ended
conversation window that the operator may return to repeatedly — a
Jupyter exploration session, a data-investigation shell, a live
debugging companion.

```bash
monitor/spawn-worker.sh \
    -n jupyter-explore \
    -c "$NEXUS_ROOT/work/kompot" \
    -p /tmp/prompt-jupyter.txt \
    --kind interactive \
    --topic "kompot UMAP exploration — operator-interactive"
```

What `--kind interactive` changes:

- A **provenance record** is written to
  `monitor/.state/windows/<window>.json` with `"kind": "interactive"`.
  Its absence from any window marks it as operator-manual (the
  orchestrator must not manage it autonomously).
- The watcher's `engaged-close-reminder` signal — already emitted
  when the operator has been away for
  `monitor.operator_engaged_close_reminder_seconds` (default 24 h) —
  becomes the **auto-retire trigger** for interactive windows. No new
  timer is needed.
- The `--topic` string feeds the `monitor/ng interactive-sessions`
  registry command, which upserts a markdown table into the overview
  issue so the operator can see all open interactive windows and the
  commands to resume them.

Interactive windows are **NOT** retired on the normal
`wrapped + idle` task-worker cycle. See
`nexus.window-cleanup` "Interactive-window auto-retire lifecycle"
for the full close flow (overview refresh → pre-close check →
`tmux kill-window` → tombstone pending decisions).

### Session resume for interactive windows

```bash
# Respawn a closed interactive window:
monitor/spawn-worker.sh --resume jupyter-explore

# Or equivalently:
monitor/ng respawn jupyter-explore

# Refresh the overview registry after manually closing:
monitor/ng interactive-sessions --upsert-overview
```

### When NOT to use `--kind interactive`

- The worker will file a report and wrap up: use the default
  `--kind task` (or omit `--kind`).
- The session is ephemeral (one-shot command execution): no kind
  flag needed.
- You are running a dedicated Jupyter service (not a CC session):
  see `nexus.jupyter` instead.

## Briefing agents with prior-report context

Spawned agents working on a `work/<project>` task should discover
their own context by scanning `reports/`. Include this in every
delegation prompt:

```
Before starting, scan for prior work:
  ls reports/{project}_* 2>/dev/null
Read the title and status lines (head -7) of any matches to decide
which are relevant. Read full reports only if they directly inform
your task.
```

This lets the agent triage itself instead of bloating the
orchestrator's prompt with pre-digested summaries that may be wrong
or stale. Replace `{project}` with the actual subdirectory name
(e.g. `kompot`, `<hpc-skills>`, `labsh`, or `nexus` for
workspace-level work).

**If the work is issue-driven**, the GitHub issue thread itself is
the operative context — milestone comments link to wiki-uploaded
reports, and the `nexus.report` slug convention embeds the issue
number (`*_issue<N>_*.md`) so the prior-report scan finds the chain.
Include in the briefing:

```
gh issue view <N> -R <repo>
```

Use `GH_TOKEN=$(./monitor/mint-token.sh) gh ...` for private repos
that need the bot's installation token; bare `gh` under user auth
suffices for public repos.

`reports/` is the resumption surface (what survives a session
crash); the issue thread is the durable record of decisions.

## Curating per-spawn context

**Worker prompts get only the rules that bear on the worker's
task. The orchestrator carries the meta-knowledge of which rules
apply to which task shape and surfaces the relevant subset
per spawn.**

Workers are not made safer by being handed every workspace rule;
they are made slower and more distractible. Pick what's relevant,
omit what isn't. We don't try to defend against every possible
mis-use — that complicates worker prompts more than the misuses
cost.

### Irreducible default-set (handled by the launcher)

`monitor/spawn-worker.sh` injects the `## Worker floor` section
of `skills/nexus.worker-defaults/SKILL.md` automatically. The
orchestrator does **not** write the floor into the prompt-file;
the helper prepends it.

Floor contents (bot identity, no `--no-verify`/force-push,
sandbox-notify, working-tree expectation, report convention) live
in one editable file. To change the floor, edit
`skills/nexus.worker-defaults/SKILL.md`'s `## Worker floor`
section; every subsequent spawn picks up the change.

The orchestrator's prompt-file should contain only the
**task-specific** content — including:

- The absolute working-tree path and whether it's the primary or a
  secondary clone (writes-route note if secondary).
- Task description, success criteria, hand-off expectations.
- Any task-shape-specific context from the table below.

Everything beyond the floor is task-shape-specific.

### Task-shape-specific context (include only when applicable)

For each spawn, ask which categories apply. Include the relevant
ones in the prompt; omit the rest. Don't paste the source files
wholesale — point at them.

| Category | Include when… | Source-of-truth |
|---|---|---|
| Target-repo tier rule (internal / user-public / external public) | worker will write to GitHub | `CLAUDE.md` "GitHub writes — identity and authorization" |
| External-public redaction grep | target is external public | same |
| "Fix at the source" decision | dispatching a fix to a tool the lab/operator owns | this skill, "Fix at the source" below |
| Watcher-isolation rule | worker touches `monitor/watcher/*` | `CLAUDE.md` "Spawning workers" |
| Independent clone vs worktree | two workers might collide on the same project, or worker reads/edits files the watcher reads | `CLAUDE.md` "Independent clones for parallel work" |
| `#N` auto-link gotcha | worker authors GitHub comment markdown | `CLAUDE.md` "Common gotchas" |
| `user-attachments` `fetch-asset` rule | worker reads user-pasted assets | `nexus.bot` "Reading user-pasted assets" |
| `uv pip` over `pip` | worker installs Python packages | `CLAUDE.md` "Common gotchas" |
| HPC efficiency reminders | worker submits Slurm / batch jobs | `CLAUDE.md` "Shared infrastructure" |
| Deliverable-write-path probe | worker writes a result to a path outside its working tree | this skill, "Deliverable-write targets" below |
| Push-author-verify (REST form) | worker `git push`-es to an existing PR branch they didn't open | `nexus.bot` "Pushing to an existing PR branch" |
| Three-tier taxonomy rationale | worker is itself orchestrator-shaped (e.g. `nexus.self-fix`) | "Why three tiers" below |
| Prior-report context (`spawn-worker.sh -r <path>`) | a prior worker wrapped on this surface AND continue-vs-spawn favoured fresh-spawn | `nexus.window-cleanup` "Continue-vs-spawn" |

Not exhaustive. When briefing, skim `CLAUDE.md` and `nexus.bot`
for items pertinent to *this* task; consult the full source rather
than a remembered subset.

### Why three tiers (orchestrator meta-knowledge)

The internal / user-public / external public split is about
**WHETHER** (per-action vs standing approval), not WHO (always
bot). Rationale:

- **Internal** writes have full operator authority by default —
  the user runs the lab/repo, standing approval is implicit in the
  monitor-agent contract.
- **User-public** writes reach the user's broader audience
  (open-source users, collaborators); the user has initiated the
  work but ongoing direction-changes need re-confirmation.
- **External public** writes touch repos the user does not
  control, with audiences who do not implicitly grant the bot any
  trust; every action needs explicit go-ahead, and internal
  identifiers must be redacted from anything that surfaces.

The orchestrator picks the tier from the target repo's
owner+visibility at spawn time and embeds the per-tier rule into
the worker prompt. Workers don't need the taxonomy; they need the
rule for their target.

### Fix at the source — don't wrap upstreams the lab/operator owns

Spawn-time decision rule. Before dispatching a worker to wrap a
tool with workspace-side compensating logic, check the tool's
GitHub org. If it's lab-owned (`<your-org>/*` always) or
operator-owned (`<operator>/*` when this nexus is operated by <operator>),
spawn the worker against the upstream repo instead. Wrappers ship
fixes in disguise — the upstream stays broken for everyone else,
and the workspace has to carry the wrapper forward forever.

Identity follows the existing routing: `<your-org>/*` is bot;
`<operator>/*` is user (the bot is not installed there). For
third-party orgs (`TrigosTeam/*`, `<your-institution>/*`, others) a stop-gap
is acceptable when upstream is slow, but file the issue upstream
too and document inside the wrapper which upstream issue would
retire it.

`monitor/labsh-attach` was the cautionary tale (katosh/labsh#3 —
should have been an upstream subcommand from the start).

### Deliverable-write targets — probed at spawn; worker probes the rest

A worker can't deliver if it can't write. `spawn-worker.sh` probes
the worker's workdir and the reports dir at dispatch and **aborts the
spawn fail-fast** (exit 15) if either is read-only, printing an
actionable remedy — so a dead-on-arrival worker never starts. Writable
targets pass silently (a tiny touch+rm, no measurable latency), so this
is invisible on a normal spawn.

That covers the two surfaces the orchestrator knows. When a worker's
task writes a deliverable **outside its working tree**, to a path the
orchestrator can't predict, brief it to run
`<nexus-root>/monitor/write-probe.sh <target>` before committing
compute — naming the concrete path in the prompt is what makes the
worker actually run it. The probe exits non-zero and prints the remedy
on a read-only target, and adapts the remedy to the environment on its
own, so the prompt needs none of those mechanics. See
`monitor/write-probe.sh` for the contract and exit codes.

## Closing windows

Spawning is half the lifecycle; closing the window when its
work wraps is the other half. Workers do not tear themselves
down — the orchestrator decides cleanup, weighing report
status, idle time, and retention reasons before any
`tmux kill-window`. The full policy (triggers, retention
overrides, pre-close checks, mechanism, cadence) lives in
`skills/nexus.window-cleanup/SKILL.md`.

## See Also

- `nexus.worker-defaults` — the every-worker safety floor that
  every spawn prompt references. Single source of truth for
  applies-to-everyone rules.
- `nexus.bot` — the spawned agent's GitHub identity. Every delegation
  posting to GitHub must use the bot, not user `gh`.
- `nexus.report` — what the spawned agent should write before
  finishing or going idle. Reports are the primary channel by which
  the orchestrator learns the outcome.
- `nexus.window-cleanup` — the orchestrator's close/retain
  decision rules: triggers (wrapped + idle, long-idle without
  report, stuck after unstick exhaustion, pane absent),
  retention overrides, pre-close checks, kill mechanism.
- nexus root `CLAUDE.md` — workspace-level architecture, watcher
  protocol, and the "Spawning Agents in Tmux Windows" canonical
  reference.
