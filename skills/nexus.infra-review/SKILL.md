---
description: "Periodic infrastructure meta-review: cluster `## Infrastructure Issues` sections across reports/ into a ranked, de-duplicated backlog of tooling fixes."
---

# nexus.infra-review — periodic infrastructure meta-review

TRIGGER when: user asks to "do an infrastructure meta-review", "audit
infra issues across reports", "scan the report corpus for recurring
friction", "build a backlog of tooling fixes from reports/", or
"meta-review of infrastructure issues". Also when the orchestrator
notices the report corpus has grown by ~50+ entries since the last
meta-review and a refresh is due.

## What this skill does

Reads every `## Infrastructure Issues` section across the entire
`reports/` corpus, theme-clusters by frequency, cross-references
against `git log` and `monitor/infra-resolved.md` to drop already-fixed
themes, and produces a single ranked backlog report. Output is one
report file under
`reports/nexus_<YYYY-MM-DD>_<HHMMSS>_infrastructure-meta-review.md`,
uploaded to the wiki via `./monitor/ng upload`, with the URL posted to
the nexus overview issue.

The 2026-04-28 meta-review
(`reports/nexus_2026-04-28_202950_infrastructure-meta-review.md`) is
the canonical reference shape for the output.

## Delegation (orchestrator: spawn a worker — do NOT run inline)

When this skill is invoked in an **orchestrator** context, the
orchestrator MUST DELEGATE the meta-review to a tmux worker rather
than execute the corpus scan inline. The whole procedure below runs in
the **worker's** window, not the orchestrator's.

**Why.** The meta-review bulk-reads the entire `reports/` corpus
(typically 150-200 files, chunked extracts) plus `git log` and the
tooling sources. Running that inline bloats the orchestrator's context
and courts the giant-tool-output hang. It is read-only, self-contained,
single-agent work — the textbook delegation case (see the root
`CLAUDE.md`, "Spawning workers — tmux, never the in-process `Agent`
tool").

**Spawn shape.** Write a prompt file with the task (point it at this
skill by absolute path), then:

```bash
monitor/spawn-worker.sh -n infra-review \
  -c <MAIN-clone-abs-path> \
  -p <prompt-file> \
  --skeptic deny
```

`--skeptic deny` — read-only triage, nothing to independently
re-validate. Use the prompt-file + launcher pattern in
`skills/nexus.tmux-spawn/SKILL.md`; don't inline the prompt.

**Worker constraints** (state these in the prompt):

- Run in the **MAIN clone** — `reports/` is gitignored and lives only
  there; a fresh clone or worktree has an empty corpus.
- **Read-only** on both the report corpus and the code. No branch
  checkout, no edits to monitor/watcher/services, no touching the live
  watcher or running services.
- The **only** writes are: the one meta-review report file under
  `reports/`, its wiki upload via `./monitor/ng upload`, and the one
  overview-issue comment. Nothing else lands on GitHub (see "Out of
  scope" below).

The orchestrator's job ends at the spawn; it relays the backlog
highlights when the worker wraps.

## Pre-flight: read the resolved index FIRST

```bash
cat monitor/infra-resolved.md
```

The file has two tables:

- **Resolved** — themes already retired by shipped PRs. **Out of
  scope.** Don't reopen them; cite once in the "Already-fixed"
  section as de-duplication evidence.
- **In-flight (not yet merged)** — themes with a fix open as a PR but
  not landed. **Also out of scope** for backlog purposes — the fix is
  in progress. Cite in the "Already-fixed" section with the open PR
  number, but don't add to the ranked backlog.

If `monitor/infra-resolved.md` doesn't exist, treat the entire corpus
as in-scope and start a fresh resolved index in the same PR (see PR
#34 for the seed shape).

## Bulk extract (Read tool's per-call cap forces this)

`reports/` holds hundreds of markdown files; reading each individually
exhausts the Read tool budget fast. Bulk-extract once, then read chunks
of the extract.

**Recurse into the monthly archive.** As of #444 the reports dir is
time-partitioned: only the current + previous month stay FLAT in
`reports/`; older months are rolled into `reports/YYYY-MM/` buckets (by
`monitor/ng reports-roll`). This meta-review reads the ENTIRE historical
corpus, so it MUST descend into the buckets — a flat `reports/*.md` glob
would silently miss every archived month. Use `find` (or
`shopt -s globstar; reports/**/*.md`):

```bash
find reports -type f -name '*.md' -print0 \
  | xargs -0 grep -l '^## Infrastructure Issues' > /tmp/_infra-files.txt

awk '
  /^## Infrastructure Issues/ { in_block=1; print "<<< " FILENAME " >>>"; print; next }
  in_block && /^## / && !/^## Infrastructure Issues/ { in_block=0 }
  in_block { print }
' $(cat /tmp/_infra-files.txt) > /tmp/infra-extracts.md

wc -l /tmp/infra-extracts.md   # sanity-check size
```

Then read `/tmp/infra-extracts.md` in 600-line chunks (the Read tool
caps around there). The `<<< FILENAME >>>` markers preserve the
provenance of each extract.

## Theme clustering

Pattern-match symptoms across reports. A theme = a set of reports
flagging the same root cause, paraphrased differently. For each
candidate theme:

1. **Cite frequency.** Count distinct reports flagging it. 6+
   citations = top-tier theme; 2-5 = recurring; 1 = one-off (still
   list if high impact, e.g. security boundary).
2. **Drop if resolved.** Cross-reference against
   `monitor/infra-resolved.md`. If the theme appears there with a
   merge-commit hash, skip — note in "Already-fixed" only.
3. **Drop if in-flight.** Same check against the In-flight table.
4. **Sample cite.** Pick 2-3 verbatim quotes from the strongest
   reports as evidence.

The 2026-04-28 meta-review's "Top recurring themes" structure is the
template: each theme gets **Frequency**, **Symptoms** (paraphrased
quotes with report cites), **Root cause** (point at the exact file +
line), **Fix shape**, **Effort × impact**.

## Cross-reference against current state

For each surviving theme:

```bash
# Recent fix commit on main?
git log --oneline --all | grep -E '<keywords>'

# Inspect the actual tooling
$EDITOR monitor/ng monitor/upload-asset.sh monitor/mint-token.sh CLAUDE.md

# Open / merged PR for this theme?
GH_TOKEN=$(./monitor/mint-token.sh) gh pr list --state all --limit 30 \
  --json number,title,state,mergedAt --repo "$(./config/load.sh github.repo)"
```

If you find a fix that shipped after `monitor/infra-resolved.md` was
last edited, propose a row to add to it (in your PR body, not in the
meta-review report — the resolved index lives in its own commit).

## Output format

Single report file, sections in this order:

1. **TL;DR** — top 5 cheapest wins, one paragraph each. Lead with the
   highest-frequency / highest-impact items.
2. **Top recurring themes** (5-10 items) — frequency-counted, each
   with sample cites, root cause pointed at file + line, fix shape,
   effort × impact rating.
3. **High-impact one-offs** — single-cite themes that still merit
   attention (e.g. security-boundary issues).
4. **Skill / prompt gaps** — missing skills, missing trap-callouts in
   `CLAUDE.md` / `monitor/agent-prompt.md`.
5. **Already-fixed (de-duplication evidence)** — table of themes
   retired since the last meta-review, with merge-commit hashes.
   Surface anything from `monitor/infra-resolved.md` that the
   extracted reports still cite (proves the index is working).
6. **Ranked backlog** — 8-15 items ordered by ROI. Each item:
   `<title>` + `Scope` + `Files touched` + `Spawn shape` + `Size` +
   `Risk`. Sized `<small>` / `<medium>` / `<large>` for orchestrator
   triage.

A single example row from each section is enough — keep prose
density high.

## Closing the loop

```bash
# Upload the report to the wiki
url=$(./monitor/ng upload reports/nexus_<DATE>_<TIME>_infrastructure-meta-review.md)
echo "$url"

# Post to the nexus overview issue
GH_TOKEN=$(./monitor/mint-token.sh) gh issue list --repo "$(./config/load.sh github.repo)" \
  --label nexus:overview --state open --json number --jq '.[0].number'
# (then) ./monitor/ng issue comment <n> --body-file <comment>.md
```

Comment body: TL;DR (5 bullet points) + the wiki URL. Keep it short —
the full content is the wiki page.

When a fix ships for any backlog item, the PR that lands it appends a
row to `monitor/infra-resolved.md` (this is the contract the
`nexus.report` skill encodes — every PR retiring a recurring infra
issue updates the index in the same commit). That keeps the next
meta-review from re-listing the same themes.

## Out of scope

- **Don't fix issues.** Produce backlog only. Each backlog item is
  self-contained enough that a one-shot tmux agent can pick it up;
  the meta-review agent itself stays in read-only mode for the
  corpus.
- **Don't audit scientific methodology.** This skill triages tooling /
  workflow / sandbox / GitHub-interface friction. Project-specific
  scientific issues belong in per-project reports, not here.
- **Don't post on GitHub beyond the wiki upload + URL comment.**
  No PRs, no issue creates, no reactions on existing comments.

## See Also

- `nexus.report` — the `## Infrastructure Issues` section convention
  this skill mines. Required reading for understanding why every
  agent is supposed to write one.
- `nexus.bot` — `./monitor/ng upload` and the GitHub-write rules.
  The wiki upload + overview-issue comment at the end of the
  meta-review run through `ng`.
- `monitor/README.md` — `ng` verb table and broader monitor
  architecture; the meta-review touches several `ng` verbs as part
  of its current-state cross-references.
- `monitor/infra-resolved.md` — the de-duplication index. Read it
  before you start; reference it in the "Already-fixed" section;
  propose new rows in your PR body when you find shipped fixes.
