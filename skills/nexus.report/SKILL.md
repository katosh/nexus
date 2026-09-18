---
description: "Write reports/{project}_{ts}_{slug}.md before finishing, going idle, or on context pressure. Required sections + the Infrastructure Issues feedback loop."
---

# nexus.report — agent report convention

TRIGGER when: agent is completing a delegated task; agent is going
idle with partial work and waiting for input; agent's context window
is filling up and state should be captured before it's lost; agent is
spawning a follow-up worker that needs a brief; agent is about to hand
off work to a sibling agent.

## The one rule

Every nexus agent MUST write a report file before finishing, going
idle, or when context is running low. Reports let work resume from
the file alone if the session crashes, the orchestrator restarts, or
a sibling needs to pick up where you left off.

Reports are **append-only during a session**. Write a new file for
each significant state change rather than overwriting the previous
one.

## Filename convention

```
{reports-dir}/{project}_{YYYY-MM-DD}_{HHMMSS}_{slug}.md
```

- **`{reports-dir}`** — the **absolute** reports path injected
  into every worker's prompt as part of the `## Worker
  environment` header (e.g. `/shared/your-lab-m/user/<operator>/nexus/reports`).
  Do **not** use a relative `reports/` from your workdir — when
  the workdir is a secondary clone (worktree / fresh clone), a
  relative path lands in that clone's tree and the orchestrator
  never sees the report. Spawning helpers
  (`monitor/spawn-worker.sh`) inject the absolute path so the
  destination is unambiguous.
- **`{project}`** — name of the `work/` subdirectory being worked on
  (e.g. `kompot`, `hpc-skills`, `labsh`). Use `nexus` for
  workspace-level tasks that span projects.
- **`{YYYY-MM-DD}`** — ISO date.
- **`{HHMMSS}`** — 24h time. UTC or local — be consistent across the
  session.
- **`{slug}`** — short kebab-case description, e.g. `fig2-revision`,
  `scout-setup`, `benchmark-run`, `nexus-skills`.

When the work is driven by a specific GitHub issue or PR, embed the
number in the slug, e.g.
`diff-dynamics_2026-05-02_184500_issue53-m8-drift-pressure.md`. This
lets future workers retrieve the chain via
`ls reports/*issue53* 2>/dev/null`.

To search report **content** (not just filenames) — "has this come up
before?" — use `monitor/ng report-grep <pattern>`, NOT a bare
`grep -r … reports/`. The operator's `grep` wraps `ugrep --ignore-files`
and `reports/.gitignore` is a bare `*`, so a recursive grep returns a
SILENT zero over the whole corpus (`<your-org>/nexus-code#618`);
`report-grep` fails loud (exit 3 + diagnostic) instead of handing back a
false "no". Filename globs like `ls reports/*issue53*` are explicit
arguments and are never suppressed.

**And a filename glob keyed on a WINDOW NAME is a silent zero of its own**
(`<your-org>/nexus-code#1195`). The `{project}` slug in a report's filename is
**cwd-derived** — `report-init` takes the first segment after the last `/work/`
in `$PWD`, falling back to the window name only when it ran outside a `work/`
tree — while the frontmatter `window:` field comes from live tmux. Measured on
this corpus they disagree for **136 of 709** reports, and **21** windows are
indexed under two or more slugs. It errs both ways: for one live window a
filename grep returns 6 where the frontmatter says 3.

Use `monitor/ng reports-for-window <window>`, which keys on the frontmatter and
keeps the three answers apart: rc 0 found, rc 1 looked-and-found-none, rc 2
**COULD NOT LOOK**.

Example: `reports/kompot_2026-04-14_153200_fig2-revision.md`.

The watcher snapshots `reports/*.md` filenames + mtimes on every poll
cycle, so a new report is automatically picked up by the monitor and
surfaced to the orchestrator.

## Required schema

Reports start with a YAML-style frontmatter block carrying the
identity fields, followed by a `# {Title}` H1 and the five
canonical sections. `monitor/ng report-init <slug>` produces a
correctly-frontmatter'd skeleton — use it instead of hand-rolling
the metadata block.

Four fields are **enforced** by `ng report-check` (`project`, `date`,
`session-id`, `status`); the rest are conventional — `report-init` writes them
all and you should keep them, but their absence is not what the checker fails
on. The annotations below say which is which, because "required" that nothing
checks and "required" that blocks your wrap-up are different promises.

```markdown
---
project: <slug>          # ENFORCED — `work/` subdir, or `nexus` for workspace-level
date: <YYYY-MM-DD>       # ENFORCED — ISO date
session-id: <uuid>       # ENFORCED — Claude Code session id; must NOT be the literal "unknown"
window: <tmux-window>    # conventional — written by report-init from live tmux; else "<unset>"
trigger: <issue#> [comment-id]   # conventional — what kicked this off
status: completed | partial | blocked   # ENFORCED — exactly one of these three
disposition: no-further-pass | second-pass   # REQUIRED whenever the wrap-up runs with
                         # a REQUIRED skeptic — spawned `--skeptic require`, or
                         # `--skeptic-decision require` under `auto` (and under
                         # `deny`, which escalates) — WHETHER OR NOT you are a
                         # skeptic: `ng wrap-up` REFUSES to file the spawn-skeptic
                         # request without it (<your-org>/nexus-code#1512, #1095).
                         # report-init seeds `TODO`; replace it with your own view,
                         # and delete the line only when no skeptic is required.
                         # Absent is fine then; UNREADABLE is refused (only those
                         # two values parse — `merge`, `credible`, `revise` do NOT).
fanout: <N> spawned / <M> returned   # optional; validated only when present, M <= N
---

# {Title}

## Summary
- Write every issue number this report claims or discharges BARE
  at least once here (`#1329`, not `` `#1329` ``): `ng wrap-up`
  projects this section verbatim into the issue comment, and a
  backticked `#N` creates no cross-reference event on that issue, so
  the issue reads as unowned (<your-org>/nexus-code#1396; the `nexus.bot`
  skill carries the measurement).
- One or two sentences. `ng wrap-up` quotes this into the link
  comment posted to the issue thread.
- The FIRST SENTENCE is what a thread reader sees. Make it state
  the result on its own — see "`## Summary` is the comment" below.

## What Was Done
- Concise list of actions taken and files changed.

## Current State
- What is the state of the work right now?
- What files were created or modified?
- Any running jobs (Slurm job IDs, PIDs)?

## What Remains
- Specific next steps, in order.
- Known blockers or decisions needed.

## How to Resume
- Exact commands or instructions to pick up where this left off.
- Branch name if applicable.
- Any context that would be lost without this report.

## Infrastructure Issues
- Anything that made the work harder than it needed to be, even if
  you worked around it. Be specific: what you tried, what happened,
  what you expected.
- Omit the section entirely if nothing came up. No placeholders.
```

The five content sections (`Summary`, `What Was Done`, `Current
State`, `What Remains`, `How to Resume`) are mandatory.
`Infrastructure Issues` is conditional — present and substantive
when something hurt, omitted when nothing did.

`monitor/ng report-check <path>` validates a report against this
schema (frontmatter fields, the five sections, body length ≥
`monitor.report_min_chars` default 500, absence of placeholder
text — `TODO` / `FIXME` / `<...>` / `_(fill in)_` / `_(later)_` — and,
when a `## Dispositions` section is present, that every bullet parses as
`- #N — ALREADY-ADDRESSED|VOID-AS-WRITTEN|GENUINELY-OPEN — text`). It
exits **0** complete, **1** incomplete with the specifics on stderr,
**2** file missing or unreadable — so a `1` is a report to fix and a `2`
is a path to fix. `ng wrap-up`
runs `report-check` as a pre-flight and refuses to ship a stub
asset URL — fix the report first, or pass `--allow-stub` to
forward `--allow-todo` to the check for an intentional checkpoint.
Existing pre-frontmatter reports don't need backfill; the schema
is enforced going forward only.

### `## Summary` IS the comment — what the composer guarantees

`ng wrap-up`'s link comment is a **projection** of your report, and
**every stage of that projection discards something.** The mechanism,
not a closed list — the list below is what is known today, and the
guarantee is stated in terms of the mechanism precisely because a
count of steps is the kind of thing that turns out to be wrong (it
already did: this block said "two" and there were three —
`<your-org>/nexus-code#1116` review, F2):

| stage | what it discards | filed as |
|---|---|---|
| report → `## Summary` | every other section, including one you appended | `#862` |
| `## Summary` → flattened text | every `**Key:** value` line, as metadata | `#1116` F2 |
| flattened text → teaser | everything after the first sentence, capped at 200 chars | `#1114` |

The middle one is the surprising one and is worth knowing by shape: a
Summary written **entirely** as `**Verdict:** BLOCK` / `**Confidence:**
high` / `**Findings:** …` flattens to **nothing**. It used to publish a
bare title at exit 0 with the trigger rocketed — a comment carrying no
verdict at all. It is now refused like any other empty composition.
One line of ordinary prose anywhere in the section is enough.

**The guarantee**, stated over the mechanism rather than over the
list: **at whatever stage the projection loses your claim, `wrap-up`
publishes nothing rather than publishing the residue.** It exits **3**
and names the cause and the ways out. A stage nobody has enumerated
yet is covered by this sentence; it would not have been covered by a
sentence about two steps. Exit
3 is not a failed step — no step failed, so re-running it unchanged
reproduces it exactly; only you can clear it.

**What it does NOT guarantee**, said plainly so nobody reads more
into it: that the teaser is a *good* summary, or that `## Summary`
describes your report. Those are properties of your prose and no
composer can check them. It guarantees only that a fragment is never
silently substituted for a claim.

**Two practical consequences.**

1. **A superseding verdict must reach the OPENING of `## Summary`.**
   Reports are append-only, so the natural place for a corrected
   conclusion is a new section at the bottom — and the composer never
   reads it. Editing `## Summary` is necessary and **not sufficient**:
   the teaser is its first sentence capped at 200 characters, so a
   correction added further down the section still leaves the composed
   body byte-identical and `wrap-up` still exits 3. Put it in the first
   sentence, or pass `--comment-body-file`. (Measured the hard way on
   `#1116`: two re-wraps, both correctly reporting NOTHING PUBLISHED.)
2. **Put at least one line of prose in `## Summary`.** An all-`**Key:**`
   section composes to nothing and is refused.
3. **Open with a sentence that stands alone.** The teaser is cut at
   the first *safe* sentence boundary; abbreviations, versions and
   initials (`e.g.` `Dr.` `Fig.` `v2.` `2.1.`) no longer end it, and
   a fragment is refused rather than posted. A one-word Summary
   (`Done.`) will be refused — that is the composer working.

Keeping the coupling (`## Summary` is the teaser source) is
deliberate. It is the one section `report-check` guarantees exists
and is non-stub, so it is the only source with a check behind it;
and it is what makes an idempotent re-run detectable — compose from
the whole report and every re-wrap would edit the comment. The
coupling was never the defect. The **unannounced loss** was.

## Why `Infrastructure Issues` matters (read this even if nothing came up)

This section is the **source material for periodic tooling
meta-reviews**. The 2026-04-28 review
(`reports/nexus_2026-04-28_202950_infrastructure-meta-review.md`)
triaged 173 reports — 93 of them carrying `## Infrastructure Issues`
content — and clustered the cross-cutting themes into a 15-item
ranked backlog of fixes the workspace shipped or queued. Themes
surfaced (each cited 6+ times) included:

- `monitor/ng react` exits silently on success — 11 reports.
- The bot's GitHub App was installed on a subset of `<your-org>/*`,
  blocking cross-repo writes — 16 reports.
- `ng pr create` and `ng issue create` were repo-locked to the nexus
  with no `--repo` flag — 8 reports.
- `mint-token.sh` returned empty silently from a non-nexus-root cwd —
  1 report, but the highest-severity finding (security boundary
  bypassed by falling through to user `gh` auth).

None of those would have been spotted without agents writing them
down. If your run hit any of:

- A command that was hard to discover or had surprising behaviour.
- Confusing or missing documentation.
- Broken / flaky tooling, or sandbox / Slurm / environment
  surprises.
- A GitHub-interface rough edge (auth confusion, missing `ng` verbs,
  misleading errors).
- Agent-to-agent communication friction (paste-buffer weirdness,
  lost follow-ups, unclear routing).

— record it. One paragraph per issue, with concrete reproduction
detail. Don't write placeholders ("nothing to report") — just omit
the section.

## When to write a report

1. **Task completion.** Final report summarises what was done and
   sets `Status: completed`.
2. **Before going idle.** Partial work, waiting on input or a
   decision: write a report capturing the partial state, set
   `status: partial` or `status: blocked`. The orchestrator and any
   successor agent can resume from it. (**Not `idle`** — the canonical
   set is exactly `completed | partial | blocked` and `ng report-check`
   refuses anything else, so a report saying `status: idle` fails the
   wrap-up pre-flight.)
3. **Context pressure.** If your context window is filling up,
   write a report **before** it's lost. A crashed session with no
   report is wasted compute.
4. **Handoff.** When spawning a follow-up worker that needs to pick
   up your in-progress work, write a report the new agent can
   consume — that's the brief.

## Append-only convention

Reports are not edited or overwritten. If state changes
significantly during the session, write a *new* report file with a
fresh timestamp. The trail of progressive reports preserves history;
a single overwritten file loses it.

This means it's normal for a single project to accumulate multiple
reports per session — `reports/kompot_2026-04-14_103000_fig2-start.md`
followed by `reports/kompot_2026-04-14_153200_fig2-done.md` is the
intended shape.

## How to share a report on GitHub

`reports/` is gitignored at the workspace level — readers on
github.com cannot see bare `reports/<file>.md` paths. The
canonical sharing path is `monitor/ng wrap-up <issue>
<report-path> [...]`, which uploads the report to the asset
repo and posts a templated link comment on the issue in one
shot (see `nexus.worker-defaults` floor; full verb-table entry
in `monitor/README.md`).

When you need an asset URL without a comment (e.g. embedding in
a PR body), upload it directly:

```bash
url=$(./monitor/ng upload reports/<your-report>.md)
# in the comment body:  [full report]($url)
```

`ng upload` routes `reports/*.md` to `assets/reports/<basename>`
on the asset repo's `main` branch and prints a SHA-pinned
`blob/<sha>/...` URL that renders as a page on github.com.
See the `nexus.bot` skill for the full upload-rule cheatsheet.

## The skeptic decision at wrap-up

Every worker is spawned with a **skeptic mode** (`require` | `auto` |
`deny`, default `auto`) stamped into its provenance record. `ng
wrap-up` reads that stamp and acts on it before it ships the report.
This section covers the wrap-up angle only; the full protocol
(mandate, worker↔skeptic comms channel, verdict ladder, bounded
recursion) lives in `nexus.skeptic` — read it when spawning a skeptic
or acting as one.

- **`require`** — wrap-up emits `SKEPTIC REQUIRED`, writes a
  skeptic-pending marker
  (`monitor/.state/skeptic/pending/<window>`), logs a
  `skeptic-request` action-log event, and prints the orchestrator
  spawn command. The task is **not** complete until a skeptic returns
  a verdict. The worker cannot waive it; only an operator can, via
  `--skeptic-waive "<reason>"`.
- **`auto`** — wrap-up prints the responsible-default heuristic and
  requires the worker to record a decision:
  `ng wrap-up ... --skeptic-decision require|deny --skeptic-rationale
  "<why>"`. A rationale is mandatory for an `auto` decision. Without
  one the result is advisory (recorded as `auto-undecided`), unless
  `monitor.skeptic.enforce_auto_decision` is on, in which case wrap-up
  fails until a decision is recorded.
- **`deny`** — wrap-up records `skeptic explicitly denied at spawn`
  and proceeds. A worker may escalate `deny`→`require` if it discovers
  higher impact than the spawn assumed.

### The responsible-default heuristic

Under `auto`, spawn a skeptic when the work: (a) touched shared
infrastructure (watcher / monitor / skills / spawn / CI); (b)
produced or altered scientific results, figures, gene lists, data, or
analysis; (c) made or proposed external (cross-repo / public) writes;
(d) involved non-trivial reasoning you are uncertain about; (e) has
high blast radius or is hard to reverse. Skip a skeptic **only** for
trivial, low-impact, easily-reversible, high-confidence work (a doc
typo, a one-line config). Bias toward skepticism: an unreviewed wrong
scientific or infra result costs far more than a skeptic pass. The
motivating case is the `#221` gene-list correction, a
labels-vs-membership error a skeptic catches.

### A skeptic's own wrap-up

When you are the skeptic, wrap up with:

```bash
ng wrap-up <issue> <report> --repo ... \
  --skeptic-role --skeptic-target <reviewed-window> \
  --skeptic-verdict <credible|check|suspect|refuted> \
  --skeptic-depth N --skeptic-findings N
```

This logs a `skeptic-verdict` event, clears the reviewed worker's
pending marker, and applies the bounded-recursion decision (a
second-pass skeptic only on substantive new issues, capped at
`monitor.skeptic.max_depth`, **default 3** — so a chain runs at most
`max_depth + 1` passes — escalating to the operator at the cap). The
skeptic's report uses the standard five sections plus its verdict and
the evidence backing it.

## See Also

- `nexus.worker-defaults` — every-worker safety floor that points
  at this skill for the report convention. Workers land here from
  there at task end.
- `nexus.bot` — the GitHub-write rules; needed when uploading the
  report to the wiki or referencing it from a PR/issue.
- `nexus.skeptic` — the full skeptic protocol the wrap-up decision
  feeds into: mandate, spawn modes, comms channel, verdict ladder,
  bounded recursion.
- `nexus.tmux-spawn` — when spawning a follow-up worker, briefing it
  with prior-report context (`ls reports/{project}_*` — but see the note
  below: that slug is cwd-derived and is NOT the window name) is part of
  the spawn pattern.
- nexus root `CLAUDE.md` — the canonical "Reports — write one before
  you finish, idle, or run out of context" section the workspace relies
  on. (The old citation named an "Agent Reports (CRITICAL)" heading that
  no longer exists — <your-org>/nexus-code#568 C8.)
