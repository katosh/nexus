---
description: "The <your-lab> software-tool ecosystem and the bug-routing protocol for lab agents. When an agent hits a bug or rough edge in a lab-authored tool (kompot, Mellon, Palantir, …), route the report FAST to the tool's code owner — open an issue on the owner's nexus asset repo (fall back to the tool's own repo) and @-ping the owner — rather than silently working around it. Carries the tool → owner → routing table and the first-line-tester rationale."
---

# nexus.tool-ecosystem — lab tools, their owners, and where to file a bug

TRIGGER when: a lab agent hits a bug, crash, wrong result, or
rough edge in a <your-lab>-authored **software tool** (a package
or method — kompot, Mellon, Crowding, Palantir, SEACells, …), and
is deciding whether to work around it silently or report it; an
agent asks "who owns tool X" or "where do I file a bug against
tool X"; the operator wants the tool→owner map maintained.

Not for third-party tools the lab merely *uses* (scanpy, anndata,
signac, ArchR) — those get filed upstream in the normal way. This
skill is specifically for tools the lab **authors and maintains**,
where a fast internal route to the owner exists.

## Why this exists — the first-line-tester contract

Each lab member runs a **nexus**: an agent workspace paired with a
GitHub "asset + issue" repo (e.g. `<your-org>/<your-nexus>` is
<operator>'s, `<your-org>/<other-nexus>` is otheruser's). Agents in these
nexuses do real single-cell analysis every day, and that work
leans on the lab's own software — kompot for differential
abundance, Mellon for density inference, Palantir for trajectories,
and so on.

That makes lab agents the **first-line testers** of the lab's
software. An agent running a real workload exercises these tools on
real data, at real scale, before most human users of the current
release do. When such an agent trips over a bug — a crash, a wrong
number, a missing parameter, a confusing error — that signal is
*valuable*, and it is perishable: worked around silently, it never
reaches the person who could fix it, and the next agent trips over
the same thing.

**So: do not silently work around a lab-tool bug. Route it.** A
30-second issue on the owner's tracker, with a copy-pasteable repro,
is worth more to the lab than a clever local monkey-patch that dies
with your session.

## The routing protocol

When you hit a bug or rough edge in a lab-authored tool:

1. **Identify the tool's code owner** from the table below (or, if
   the tool is not listed, from its dominant commit author —
   `GH_TOKEN=$(./monitor/mint-token.sh) gh api
   repos/<your-org>/<tool>/commits --jq '.[].author.login'` — then
   map to a verified lab handle).

2. **Open an issue on the owner's nexus asset repo** — that is the
   owner's control surface; their watcher will surface it. Post as
   the bot (`monitor/ng` for the nexus repo, or
   `GH_TOKEN=$(./monitor/mint-token.sh) gh issue create --repo
   <your-org>/<owner>-nexus …` cross-repo), then assert the author
   with `monitor/assert-bot-author.sh <url>`.

   **Fallbacks, in order**, if the owner has no nexus asset repo:
   - File on the **tool's own repo** (`<your-org>/<tool>/issues`),
     and `@`-ping the owner in the body.
   - If neither fits, `@`-ping the owner on the most relevant
     existing thread.

3. **Always `@`-ping the code owner's handle** in the issue body,
   whichever venue you chose — the ping is what wakes them
   (GitHub mutes self-notifications, so the bot pinging *them* is
   exactly right).

4. **Give a real repro.** Exact command, expected vs. observed as
   literal bytes, tool version / commit SHA, and the smallest input
   that triggers it. A vague "kompot seems off" wastes the owner's
   triage budget; a copy-pasteable repro gets fixed.

### Worked example

> An agent computing density with **Mellon** hits a
> `ValueError` on a 1.2M-cell AnnData that works fine at 100k cells.
> Mellon's owner is **@<operator>**, whose nexus asset repo is
> `<your-org>/<your-nexus>`. The agent (as the bot) opens an issue on
> `<your-org>/<your-nexus>` titled "Mellon: ValueError at >1M cells in
> `DensityEstimator.fit`", pastes the exact call, the full
> traceback, `mellon.__version__`, and a note that 100k cells
> succeed — then `@<operator>` in the body. Done in under a minute; the
> owner wakes on the ping.

### Cross-group nuance — `dpeerlab/Palantir` and other external upstreams

Several lab-authored methods live under **another group's** GitHub
org because that is their canonical home — most notably
**`dpeerlab/Palantir`** (otheruser wrote Palantir in Dana Pe'er's
lab; it still lives there and otheruser, now the lab PI, co-maintains it
alongside <operator>). `dpeerlab`, `broadinstitute`, and the like are
**external-public** repos under the workspace tier rules.

For a bug in an external-upstream lab tool:
- Prefer routing to the owner's **<your-org>-side** surface first —
  their nexus asset repo (`@otheruser` → `<your-org>/<other-nexus>`) —
  where you can post freely as the bot.
- **Do NOT auto-post an issue or PR to the external upstream**
  (`dpeerlab/*`, etc.). Those are external-public: **draft the
  report and STOP for operator review** before anything lands
  upstream, and grep the draft for internal identifiers (study
  names, sample IDs, cell counts, internal-repo refs) and redact.
  See the "GitHub writes — WHETHER, by repo tier" section of the
  workspace `CLAUDE.md` and `skills/nexus.bot/SKILL.md`.

## Tool → owner → routing table

**Handles are real people — verified against the current lab-member
roster.** Owners marked `handle?` could not be confidently mapped to
a current member (the dominant committer is not in the provided
roster, or the repo is co-owned); route those through the fallback
maintainer or the tool's own repo and let the operator confirm,
rather than `@`-pinging a stranger. "Not in the roster" is not proof
of departure — the committer may simply be absent from the roster we
were handed; the operator confirms current ownership.

Owners are the tool's **dominant commit author**, mapped to a
verified roster handle — **except** where operator knowledge
overrides (a tool named for / conceived by a member who had someone
else commit for them; e.g. `otheruser_annotation` is otheruser's tool
even though `@<operator>` authored the commits). Commit-author is the
signal; the owner-review pings are how the exceptions get corrected.
Almost every member now runs a nexus — route a bug to the owner's
nexus asset repo below.

**Member → nexus asset repo (routing target):** `@<operator>` →
`<your-org>/<your-nexus>` · `@otheruser` → `<your-org>/<other-nexus>` ·
`@otheruser` → `<your-org>/<other-nexus>` · `@otheruser` →
`<your-org>/<other-nexus>` · `@otheruser` → `<your-org>/<other-nexus>` ·
`@<other-nexus>` → `<your-org>/<other-nexus>` · `@otheruser` →
`<your-org>/<other-nexus>` · `@otheruser` →
`<your-org>/<other-nexus>` · `@otheruser` →
`<your-org>/<other-nexus>`.

### Actively-maintained <your-org> packages & methods

| Tool | Purpose | Repo | Owner (handle) | File a bug at |
|---|---|---|---|---|
| **kompot** | Differential abundance & gene expression in single-cell data | `<your-org>/kompot` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **Mellon** | Non-parametric density inference for single-cell analysis | `<your-org>/Mellon` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **Crowding** | kNN-distance non-parametric density estimator | `<your-org>/Crowding` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **2for1separator** | Deconvolve CUT&Tag 2for1 data (`sep241`) | `<your-org>/2for1separator` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **kdpeak** | KDE-based ATAC peak caller | `<your-org>/kdpeak` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **spatial-smooth** | Composable spatial & cell-state smoothing of gene signatures | `<your-org>/spatial-smooth` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **convert2anndata** | R package: SingleCellExperiment / Seurat → AnnData | `<your-org>/convert2anndata` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **annzarro** | Zarr-based AnnData visualization tool | `<your-org>/annzarro` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **barnacle** | Persistent shared-node HPC workspaces via self-extending SLURM chains | `<your-org>/shared-node-tool` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **labsh** | Project-local JupyterLab management CLI for humans & agents | `katosh/labsh` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **agent_sandbox** | Sandbox AI agents on HPC / SLURM (the lab's agent sandbox) | `katosh/agent_sandbox` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **iso_de** | Differential of log-isoform fractions | `<your-org>/iso_de` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **genextf** | Associate transcription factors to genes via accessible sites | `<your-org>/genextf` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **jupyter_kernel_inspector** | Inspect & list Jupyter kernels | `<your-org>/jupyter_kernel_inspector` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **unprintable** | Find & remove hidden characters in text files | `<your-org>/unprintable` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **fh-hpc-skills** | Claude Code skills for <your-institution> HPC usage | `<your-org>/hpc-skills` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **agent_container** | Responsible-usage tooling for AI coding agents | `<your-org>/agent_container` | operator (`@<operator>`) | `<your-org>/<your-nexus>` |
| **otheruser_annotation** | Utilities to ease cell-type annotation | `<your-org>/otheruser_annotation` | **otheruser (`@<other-nexus>`)** — operator-confirmed owner (`@<operator>` committed on her behalf) | `<your-org>/<other-nexus>` |
| **scEcho** (a.k.a. "echo") | Statistical framework for desynchronized cell states + driver genes/REs from paired scRNA + scATAC | `<your-org>/scEcho` | otheruser (`@otheruser`) | `<your-org>/<other-nexus>` |
| **Desync** | Desynchronization method (`scEcho` family) | `<your-org>/Desync` | otheruser (`@otheruser`) — *confirm: standalone tool vs. `scEcho` component* | `<your-org>/<other-nexus>` |
| **Singlecept** | Quantify receptor downstream activity at single-cell resolution (scMultiome) | `<your-org>/Singlecept` | otheruser (`@otheruser`) | `<your-org>/<other-nexus>` |
| **ContextNet** | Infer context-specific TF-target relations from RNA + ATAC multiome | `<your-org>/ContextNet` | otheruser (`@otheruser`) | `<your-org>/<other-nexus>` |
| **ccflowR** / **ccflow** | Cell-cell communication flow analysis | `<your-org>/ccflowR`, `<your-org>/ccflow` | otheruser (`@otheruser`) — *confirm tool vs. analysis* | `<your-org>/<other-nexus>` |
| **context_specific_grn** | Context-specific GRN construction from paired RNA + ATAC | `<your-org>/context_specific_grn` | otheruser (`@otheruser`) — *confirm tool vs. analysis* | `<your-org>/<other-nexus>` |
| **trendsetter** | Plotting & utilities for single-cell trend analysis | `<your-org>/trendsetter` | otheruser (`@otheruser`) | `<your-org>/<other-nexus>` |
| **insilico-chip** | In-silico ChIP-seq in Python | `<your-org>/insilico-chip` | otheruser (`@otheruser`) | `<your-org>/<other-nexus>` |
| **atac_metacell_utilities** | Snakemake pipeline for scATAC metacell scores, chromVAR, in-silico ChIP | `<your-org>/atac_metacell_utilities` | otheruser (`@otheruser`) | `<your-org>/<other-nexus>` |
| **useful-plots** | Reusable plotting functions that don't fit a package | `<your-org>/useful-plots` | otheruser (`@otheruser`) | `<your-org>/<other-nexus>` |
| **multimodal-integration** | Multimodal single-cell integration | `<your-org>/multimodal-integration` | otheruser (`@otheruser`) — *confirm tool vs. analysis* | `<your-org>/<other-nexus>` |
| **proseg-workflow** | Proseg (spatial cell segmentation) Nextflow pipeline for Cirro | `<your-org>/proseg-workflow` | otheruser (`@otheruser`) | `<your-org>/<other-nexus>` |
| **check-strand** | Infer strandedness of RNA-Seq data | `otheruser/check-strand` | otheruser (`@otheruser`) | `<your-org>/<other-nexus>` |
| **TBmisc** | R package of utilities for biomedical data | `otheruser/TBmisc` | otheruser (`@otheruser`) | `<your-org>/<other-nexus>` |
| **getspan** | Gene-trend regression & span identification | `<your-org>/getspan` | otheruser (`handle?` — not in provided roster; recently GitHub-active, confirm owner) | `<your-org>/getspan` (operator to route) |
| **CellDensities** | Single-cell density utilities | `<your-org>/CellDensities` | `otheruser` (`handle?` — not in provided roster; fallback maintainer `@<operator>`) | `<your-org>/CellDensities` |

### Cross-group / legacy <yourlab> methods

Trajectory / metacell classics whose **canonical home is an external
group** (`dpeerlab`, Pe'er lab) — these are **external-public**:
never auto-post upstream; **draft + STOP for operator review** and
redact internal identifiers first. Route the <your-org>-side report to
`@otheruser`'s nexus (`<your-org>/<other-nexus>`) as an interim.

| Tool | Purpose | Canonical repo | Owner (handle) | File a bug at |
|---|---|---|---|---|
| **Palantir** | Single-cell trajectory detection | `dpeerlab/Palantir` | otheruser (`@otheruser`, author) + operator (`@<operator>`, active maintainer) | `<your-org>/<other-nexus>`; external upstream → **draft + operator review** |
| **Harmony** | Framework connecting scRNA-seq across discrete time points | `dpeerlab/Harmony` | otheruser (`@otheruser`) | `<your-org>/<other-nexus>`; upstream → **draft + review** |
| **wishbone** | Align cells along branching developmental trajectories | `dpeerlab/wishbone` | otheruser (`@otheruser`) | `<your-org>/<other-nexus>`; upstream → **draft + review** |
| **SEACells** | Infer metacell states from single-cell genomics | `dpeerlab/SEACells` | otheruser (`@otheruser`) + upstream Pe'er-lab maintainers | `<your-org>/<other-nexus>`; upstream → **draft + review** |
| **ChIPKernels** | R package: string kernels for DNA-sequence analysis | `otheruser/ChIPKernels` | otheruser (`@otheruser`) | `<your-org>/<other-nexus>` |
| **SeqGL** | Group-lasso extraction of TF sequence signals from ChIP/DNase/ATAC | `otheruser/SeqGL` (mirror `<your-org>/SeqGL`) | otheruser (`@otheruser`) | `<your-org>/<other-nexus>` |
| **sc-dynamics-bench** | Benchmarking suite for non-splicing single-cell dynamics inference | `<your-org>/sc-dynamics-bench` | otheruser (`@otheruser`) — *confirm* | `<your-org>/<other-nexus>` |

> **Not lab-authored — file upstream normally:** `wot`
> (Waddington-OT, Broad Institute), and third-party dependencies the
> lab forks but does not maintain (`scanpy`, `anndata`, `signac`,
> `ArchR`). A bug in these is a normal upstream report, not a
> lab-routing case.
>
> **Ambiguous / low-signal repos not tabled** (a member should claim
> or disclaim them): `spatial-trajectory`, `spatial-visualization`
> (`@otheruser`, 1 commit each — likely scratch); `dolimap`,
> `knmap` (`@<operator>` knowledge-base engines, not single-cell tools).

## Maintaining this table

The roster and ownership drift. Re-derive an owner from the
dominant commit author when in doubt
(`gh api repos/<your-org>/<tool>/commits --jq '.[].author.login'`),
and only `@`-ping a handle you have verified against the current
lab-member roster (or that `gh api users/<handle>` resolves AND you
have confirmed is a current member). When a mapping is uncertain,
flag it `handle?` and route through a fallback rather than guessing
a ping. New tools get a row; retired ones get struck.

## See also

- `skills/nexus.bot/SKILL.md` — bot-identity discipline for every
  GitHub write (the issue you file goes out as the bot).
- `skills/nexus.self-fix/SKILL.md` — the analogous protocol for
  bugs in the **nexus itself** (watcher, monitor, skills); routes
  to `<your-org>/nexus-code`, not to a tool owner.
- Workspace `CLAUDE.md`, "GitHub writes — identity and
  authorization" — the repo-tier rules that govern whether an
  external-upstream write may auto-post.
