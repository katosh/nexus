# Reports

`reports/` is the durable, append-only log of what every agent did and what it learned. The watcher snapshots filenames and mtimes; the orchestrator surfaces new reports in *Recently Completed*; `ng wrap-up` uploads them to the asset repo and posts link comments on the tracking issue. This page covers the operator-visible contract; the per-section semantics live in [`skills/nexus.report/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.report/SKILL.md).

## Filename convention

```
<reports-dir>/<project>_<YYYY-MM-DD>_<HHMMSS>_<slug>.md
```

- **`<reports-dir>`** is the absolute path injected into every worker's spawn prompt by `monitor/spawn-worker.sh`. Workers in a secondary clone (worktree or fresh clone) write to the *primary* clone's `reports/`, not their own.
- **`<project>`** is the `work/<subdir>` the worker is editing (e.g. `kompot`, `labsh`), or `nexus` for workspace-level work that spans projects.
- **`<YYYY-MM-DD>_<HHMMSS>`** is ISO date plus 24-hour time. UTC or local — be consistent across a session.
- **`<slug>`** is short kebab-case: `fig2-revision`, `bench-eligibility`, `pr14-validate`. When the work is issue-driven, embed the issue number: `*_issue53_*.md` so `ls reports/*issue53* 2>/dev/null` retrieves the chain.

Example: `reports/kompot_2026-04-14_153200_fig2-revision.md`.

## The five required sections

```markdown
---
project: <slug>
date: <YYYY-MM-DD>
session-id: <uuid>
window: <tmux-window>
trigger: <issue#> [comment-id]
status: completed | partial | blocked
---

# <Title>

## Summary
- One or two sentences. `ng wrap-up` quotes this into the link comment.

## What Was Done
- Concise list of actions taken and files changed.

## Current State
- State of the work right now, files created/modified, running jobs.

## What Remains
- Specific next steps, blockers, decisions needed.

## How to Resume
- Exact commands or instructions to pick up where this left off.

## Infrastructure Issues
- Anything that made the work harder than it needed to be.
- Omit the section entirely when nothing came up. No placeholders.
```

`Summary`, `What Was Done`, `Current State`, `What Remains`, `How to Resume` are mandatory. `Infrastructure Issues` is conditional — present and substantive when something hurt, absent otherwise.

## Why reports exist

Three reasons, in order of frequency.

**Resumption surface.** If a session crashes, the orchestrator restarts, or a sibling worker needs to pick up where you left off, the report is what survives. `How to Resume` is load-bearing: it tells the next worker which branch to check out, which Slurm job ID to poll, which kernel still holds the loaded dataset.

**Dashboard input.** The watcher's report-snapshot diff feeds the orchestrator's wake; the orchestrator's *Active Agents* and *Recently Completed* sections are computed from the filename list. A new `reports/*.md` is the visible signal that work has progressed.

**Source for the periodic infra-review.** `## Infrastructure Issues` sections aggregate across sessions into a ranked backlog of tooling fixes. See [the feedback loop](#the-infrastructure-issues-feedback-loop) below.

## Append-only, not overwritten

Reports are never edited or overwritten in place. If state changes significantly mid-session, write a *new* file with a fresh timestamp:

```
reports/kompot_2026-04-14_103000_fig2-start.md     ← start of session
reports/kompot_2026-04-14_153200_fig2-done.md      ← end of session
```

The trail of progressive reports preserves history; an overwritten file loses it. CI guards (`check-no-reports-leaked.yml`) refuse PRs that add files under `reports/` — they're meant to be uploaded to the asset repo via `ng wrap-up`, not committed to the code repo.

## The three `ng` verbs

```bash
# 1. Start the report — frontmatter'd skeleton, captures session id + tmux window.
monitor/ng report-init <slug> [--project <name>] [--issue <#>] [--comment-id <id>]

# 2. Validate the report against the schema.
monitor/ng report-check <path> [--allow-todo]

# 3. Wrap up — upload + link comment + rocket + retain + log-action, all atomic.
monitor/ng wrap-up <issue> <report-path> \
    [--trigger-comment <id>] [--repo <owner>/<repo>] [--trigger-repo <owner>/<repo>] \
    [--comment-body-file <path> | --no-comment] [--retain <reason> | --no-retain] [--allow-stub]
```

### `ng report-init`

Writes a correctly-frontmatter'd skeleton at the canonical `<reports-dir>/<project>_<YYYY-MM-DD>_<HHMMSS>_<slug>.md` path. Reads the session id from the running Claude Code session, captures the current tmux window, and fills in the issue / comment refs from the flags. The agent then opens the file and fills in the five content sections.

### `ng report-check`

Validates a report against the schema: frontmatter fields, the five required sections (`Infrastructure Issues` conditional), body length ≥ `monitor.report_min_chars` (default 500), and absence of placeholder text (`TODO`, `FIXME`, `<...>`, `_(fill in)_`, `_(later)_`).

`ng wrap-up` runs `report-check` as a pre-flight and refuses to ship a stub asset URL. If you're intentionally checkpointing mid-flight (e.g. a context-pressure save) and the body legitimately contains placeholders, pass `--allow-stub` to `wrap-up`, which forwards `--allow-todo` to the check.

### `ng wrap-up`

The end-of-task hand-off, folded into one verb:

1. Run `ng report-check` as a pre-flight. If the report fails schema validation (missing sections, body below `monitor.report_min_chars`, or placeholder text), the verb refuses with a non-zero exit before any side-effects. Pass `--allow-stub` (forwards `--allow-todo` to the check) to bypass for intentional mid-flight checkpoints.
2. Upload the report to the asset repo's `main` branch under `assets/<issue>/<basename>` via `monitor/upload-asset.sh`. The comment lands on `<issue>` in `--repo`; pass `--trigger-repo <owner>/<repo>` when the trigger comment lives in a *different* repo than the issue (defaults to `--repo`).
3. Post a templated comment on `<issue>`: `## <Title>\n\n<Summary>\n\nFull report: <URL>`. Pass `--comment-body-file <path>` for a bespoke body (the `{{REPORT_URL}}` token is substituted), or `--no-comment` to skip the comment entirely (the two are mutually exclusive).
4. Rocket-react the trigger comment if `--trigger-comment <id>` is supplied.
5. **Retain the worker's tmux window.** `wrap-up` *auto-retains by default* — it logs a `window-retain` event so the orchestrator's window-cleanup loop keeps the window alive (default `monitor.retain_ttl_seconds`, 24 h) under the tag `wrap-up-<YYYY-MM-DD>`, giving you a resume surface. Pass `--retain <reason>` for a custom tag, or `--no-retain` to close-immediately (`--no-retain` and `--retain` are mutually exclusive). The retain is logged only when the verb runs inside the tmux window it's retaining.
6. Append a `wrap-up` event to `monitor/.state/action-log.jsonl`.

Exit 0 only when every attempted step succeeds; on partial failure, prints which steps ok / failed on stderr so the caller can retry just the failed ones.

## Why `reports/` is gitignored

`reports/` is workspace-scoped and ephemeral. Most reports cite paths, commit shas, and configuration values specific to a single operator's environment; committing them to the public code repo would conflate workspace state with shippable code, and growing the log over time would bloat `git log` and clone size.

Instead, `ng wrap-up` pushes each report to the asset repo's `main` branch and prints a SHA-pinned URL. The link comment on the tracking issue is what readers on github.com see. The asset repo (`github.asset_repo` — typically a private repo per operator) is the durable surface; the code repo stays clean.

Linking to a bare `reports/<file>.md` path in the code repo doesn't work — github.com 404s, because the file isn't on any branch. Always upload via `ng wrap-up` first.

## The Infrastructure Issues feedback loop

When the work hits something rough — a command that was hard to discover or had surprising behaviour, broken / flaky tooling, sandbox or Slurm surprises, a GitHub-interface rough edge, agent-to-agent communication friction — record it in a `## Infrastructure Issues` section with concrete reproduction detail.

These sections are the source material for the **periodic infrastructure meta-review**. The 2026-04-28 review triaged 173 reports — 93 of them carrying `## Infrastructure Issues` content — and clustered the cross-cutting themes into a ranked backlog of fixes. Themes that surfaced ≥ 6 times each got a PR:

- `monitor/ng react` exited silently on success — 11 cites.
- The bot's GitHub App was installed on a subset of internal repos, blocking cross-repo writes — 16 cites.
- `ng pr create` / `ng issue create` were repo-locked to the nexus with no `--repo` flag — 8 cites.
- `mint-token.sh` returned empty silently from a non-nexus-root cwd — 1 cite, but the highest-severity finding (security boundary bypassed by falling through to user `gh` auth).

None of those would have been spotted without agents writing them down. The `monitor/infra-resolved.md` table lists every retired theme alongside the fix commit/PR so future meta-reviews don't re-discover them.

The skill that drives the periodic review is [`nexus.infra-review`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.infra-review/SKILL.md). Operators don't run it manually — the orchestrator runs it on a schedule and spawns the resulting fix-workers.

**One rule for agents writing reports:** don't write placeholders ("nothing to report"). Omit the section.

## Cadence — when an agent writes a report

1. **Task completion.** Final report summarises what was done; `status: completed`.
2. **Before going idle.** Partial work, waiting on input or a decision; report captures the partial state, `status: partial` or `blocked`. The orchestrator or any successor agent can resume from it.
3. **Context pressure.** Context window filling up; write the report *before* it's lost. A crashed session with no report is wasted compute.
4. **Handoff.** Spawning a follow-up worker that needs to pick up the in-progress work; the report is the brief.

For the deep dive — section semantics, the issue-driven slug, share-on-GitHub patterns — read [`skills/nexus.report/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.report/SKILL.md). Operators rarely need it; orchestrator and worker prompts pull it in by absolute path.
