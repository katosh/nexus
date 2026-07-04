# Spawning workers

A *worker* is an agent in its own tmux window, on the same host, working on a delegated task. The orchestrator spawns workers; workers file reports; the orchestrator closes the window when the report lands. This page covers the operator-visible mechanics — what your comments do, what the worker does back, and where to look if something stalls.

## Two ways a worker gets spawned

```text
   You comment on GitHub                         You direct an existing worker
                ↓                                              ↓
        watcher polls,                                    @worker-foo:
        bot reacts 👀                                            ↓
                ↓                                       orchestrator pastes
   orchestrator wakes (paste-buffer),                    into worker's pane
   reads the comment, decides:                                  ↓
                ↓                                       worker reads the
       (free-form delegation)                          paste as user input
                ↓
       monitor/spawn-worker.sh
       opens a new tmux window
```

Free-form delegation is the common path: a comment like *"please add tests for the new `_classify_diff` cases"* prompts the orchestrator to write a task-specific prompt to a temp file, call `monitor/spawn-worker.sh`, and post a confirmation comment with the new window name.

Direct routing (`@<window>:`) skips the spawn and feeds a follow-up to an existing window.

## Routed directives

The orchestrator auto-routes any comment whose first non-empty line matches `@<window-name>:<instruction>`. The instruction is pasted into the named tmux window via `monitor/paste-followup.sh` (see [Follow-up messages](#follow-up-messages)), and a confirmation comment is posted on the issue.

```text
@kompot-fig3: please skip the slow preprocessing step and use the cached parquet
```

If `kompot-fig3` exists, the line after the colon is pasted into its pane, the bot reacts 🚀, and a "routed `@kompot-fig3` directive" comment appears on the thread.

### The bang convention for destructive instructions

The orchestrator declines to auto-forward instructions that look destructive — anything containing `delete`, `drop`, `force push`, `reset`, or `clean`. Instead it replies asking you to re-send with a bang:

```text
@kompot-fig3!: please delete the failed sbatch run output
```

`@<window>!:` means "yes, I read the warning, do it anyway". This is the one place where you can post a confirmation from your phone without typing the full instruction twice — copy the bot's quoted reply, add the `!`, post.

The keyword list is intentionally crude (substring match, not semantic). False positives (a benign comment that happens to contain the word *reset*) bounce; you re-send with `!`. False negatives are the more dangerous failure, so the bias is to over-flag.

If the named window doesn't exist, or the comment is ambiguous about which window it targets, the orchestrator likewise asks for clarification rather than guessing.

## Free-form delegation

For anything more substantive than a one-liner, write a plain comment describing the work. The orchestrator decides whether the request creates new work (spawn a worker) or fits an existing one (route or reply). When it spawns:

1. It writes the task-specific prompt to `/tmp/prompt-<window>.txt`.
2. It calls `monitor/spawn-worker.sh -n <window> -c <workdir> -p /tmp/prompt-<window>.txt`.
3. `spawn-worker.sh` reads the **worker floor** (the always-applies safety contract: bot identity for GitHub writes, no `--no-verify`, no force-push, [report convention](reports.md), `ng wrap-up` at end-of-task) from `skills/nexus.worker-defaults/SKILL.md`'s `## Worker floor` section, prepends a `## Worker environment` header with absolute paths, then prepends the floor body, all separated by `---`.
4. It launches `claude` in a detached tmux window via the [`monitor/nexus.tmux-spawn`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.tmux-spawn/SKILL.md) launcher pattern (separate `new-window` + `send-keys`, `-d` for non-stealing focus, `-c` for the workdir).
5. The orchestrator posts a confirmation comment naming the new window and its tracking issue.

The worker reads its prompt as the first user turn of an interactive `claude` session and starts working. Every worker is a **fresh** `claude` session — `spawn-worker.sh` does not pass `--continue`, so a worker never inherits prior conversational state. (The `--continue` resume flag only applies to the cold-start orchestrator path in `monitor/watcher/entry.sh`.)

### Why a prompt file, not inline shell

Inline `"$(cat ...)"` and single-quoted multi-line prompts break with special characters, nested quotes, and zsh escaping in tmux. A `<<'EOF'` heredoc plus a separate temp file is the only reliable shape. The launcher self-cleans (`rm -f` after sourcing) so `/tmp` doesn't accumulate prompt scraps.

For the deeper rationale (Agent-tool vs tmux, parallel execution, the artifact-ownership argument) see [`skills/nexus.tmux-spawn/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.tmux-spawn/SKILL.md). Contributors writing new orchestrator behaviour read that source directly; operators rarely need to.

## The worker's contract

Once spawned, every worker honours the floor:

- **Workdir** is in its `## Worker environment` header — either the primary clone (writes land directly) or a secondary clone / worktree (canonical writes route via PR).
- **GitHub writes go through the bot**, via `monitor/ng <verb>` or `GH_TOKEN=$(./monitor/mint-token.sh) gh ...`. Plain `gh` (which would post under your account and silence your own notifications) is never used.
- **No `--no-verify`, no force-push.** Pre-commit hook fails → fix the root cause and create a new commit.
- **Reports first, then wrap-up.** The worker starts its final report via `monitor/ng report-init <slug>`, fills in the five mandatory sections, then calls:

    ```bash
    monitor/ng wrap-up <issue> <report-path> \
        --trigger-comment <id> --repo <owner>/<repo>
    ```

    `ng wrap-up` uploads the report to the asset repo, posts a templated link comment on the tracking issue, rockets the trigger comment, and appends a `wrap-up` event to the action log. See [Reports](reports.md) for the full flow.

The orchestrator never inlines these rules per spawn — they live in one editable file (`skills/nexus.worker-defaults/SKILL.md`), and `monitor/spawn-worker.sh` injects the body verbatim on every spawn. Editing the source updates every subsequent worker.

## Follow-up messages

Two ways a follow-up reaches a running worker, one per audience:

**You, the human operator: just type.** Switch to the worker's tmux window and type in the Claude Code TUI like a normal chat — no helper script, no tmux incantation. The watcher attributes your (unstamped) input to the operator, marks the window `operator-engaged`, and suppresses idle nags and cleanup while you drive; when you walk away the mark self-expires and normal lifecycle handling resumes. The full engagement lifecycle is diagrammed in [`monitor/docs/agent-state-machine.md`](https://github.com/<your-org>/nexus-code/blob/main/monitor/docs/agent-state-machine.md). (GitHub remains the recommended default — a `@<window>:` directive works from your phone and leaves a trail on the issue — but the pane is always there for tight, interactive iterations.)

**The orchestrator: `monitor/paste-followup.sh`.** When the *orchestrator* sends a follow-up (including a `@<window>:` directive you posted on GitHub), it must not look like a human at the keyboard — an unstamped paste would falsely mark the window `operator-engaged` and mute its stall-nag for up to a day. `monitor/paste-followup.sh <window> --file <path>` stamps the machine-input ledger before pasting, performs the VI-safe paste sequence, and appends an audit event. That distinction — humans type, machines stamp — is the whole reason the helper exists. Mechanics and rationale: the [orchestrator guide](https://github.com/<your-org>/nexus-code/blob/main/monitor/docs/orchestrator-guide.md).

## Window naming

Short, descriptive, kebab-case window names tied to the task or project: `repro-skills`, `data-mgmt`, `kompot-fig3`, `bench-eligibility`. The dashboard's *Active Agents* table surfaces the name; the watcher's `tmux list-windows` snapshot uses it; the [window-cleanup policy](#closing-windows) keys on it.

Check `tmux list-windows` or the dashboard before spawning to avoid collisions. The launcher refuses to create a window whose name already exists.

## Closing windows

Workers do not tear themselves down. The orchestrator decides cleanup on every wake, weighing four triggers and a handful of retention overrides. Full policy lives in [`skills/nexus.window-cleanup/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.window-cleanup/SKILL.md); the operator-visible shape:

- **Wrapped + idle.** A matching report exists, `ng wrap-up` ran, the session jsonl hasn't been modified for ≥ 30 min. The clean case.
- **Long-idle without report.** Pane idle for ≥ 90 min and no matching report. The orchestrator pastes a *Finish-and-report* follow-up; closes after another 30 min if the report still doesn't land.
- **Stuck after auto-unstick.** Pane `blocked`, [unstick library](watcher.md#auto-unstick) has exhausted retries. The orchestrator pastes a stuck-window template asking the worker to report what it tried and why it blocked.
- **Idle-too-long (≥ 24 h).** Strong default to close; retention overrides (recent user engagement, loaded-kernel cost, open-ended research thread) still apply.
- **Pane absent.** Window already gone — drop the row from the dashboard.

Two states *block* cleanup entirely:

- **Operator-engaged.** You typed into the worker's pane; the window is yours. The orchestrator does not close it and does not paste follow-ups while the engagement mark is valid (it self-expires once the pane goes static; `ng engaged-done` ends it explicitly).
- **Over-limit.** The worker hit the weekly Opus limit. Never closed; the watcher owns the scheduled resume.

The authoritative lifecycle — every state, every transition threshold, the orchestrator reaction per state — is the diagram in [`monitor/docs/agent-state-machine.md`](https://github.com/<your-org>/nexus-code/blob/main/monitor/docs/agent-state-machine.md).

The `monitor/ng log-action monitor --event window-close` entry captures workdir and session id at kill time, so `claude --resume` is available as a last-resort recovery if the post-mortem reveals the close was premature. The default path remains spawn-a-fresh-worker-with-the-prior-report-as-context.

## Delegation discipline (orchestrator-side)

The line that keeps the system coherent: **if the action would have appeared in a worker's "What Was Done" section, it should have run in a worker's window.** The orchestrator does coordination — dashboard writes, reactions, comments, tmux survey, action-log entries — but no code edits, data analysis, builds, or commits. Each spawned worker owns its artifacts; that's how parallelism survives and how the orchestrator's context stays bounded.

This rule matters mostly to contributors editing the orchestrator's behaviour. Operators feel it indirectly: if you ask the orchestrator a code question, it spawns a worker rather than rolling its sleeves up itself.
