---
description: "How every nexus agent writes: Simplified Technical English (ASD-STE100) writing rules, sentences under 20 words, one idea per sentence, stats and results in tables, internal terms defined on first use from the shared GLOSSARY.md. Use when writing a report, an issue or PR comment, a dashboard section, or a figure caption."
---

# nexus.writing — how every agent writes

TRIGGER when: you are writing prose a human will read. That covers
a report, an issue or PR comment, a PR body, a dashboard section,
and a figure caption.

The `## Worker floor` in `nexus.worker-defaults` carries rules 3
to 5b. Those are the ones you can apply without reading anything.
This skill is the rest. It gives the standard behind them, the
point where that standard stops, and the glossary that keeps
definitions stable.

## The six rules

| # | Rule | Where it lives |
|---|---|---|
| 1 | A memory about how agents must write | orchestrator memory — see below |
| 2 | Follow the ASD-STE100 writing rules | this skill, `## Simplified Technical English` |
| 3 | Sentences under 20 words | floor bullet |
| 4 | One idea per sentence | floor bullet |
| 5a | No undefined jargon — define words | floor bullet + `GLOSSARY.md` |
| 5b | Report stats and results in a table | floor bullet + `## Tables` |
| 6 | Keep definitions and tables stable across turns | `GLOSSARY.md` + `## Tables` |

**The numbering is the operator's, from the request that created
this skill.** Keep it. Every other artefact discussing these rules
uses it, and renumbering breaks cross-references.

Rule 1 is not itself a writing rule, and it has no agent-facing
form here. Agent memory is scoped per project directory, so a
memory reaches the orchestrator only. Workers are reached by the
floor bullet and by this skill.

The rules apply to new writing only. The nexus does not rewrite
its existing reports, issues, or skills to match.

## Simplified Technical English

ASD-STE100 is a controlled language. The AeroSpace and Defence
Industries Association of Europe maintains it. Its origin is
civil aviation maintenance documentation. It has two parts.

| Part | Content | Adopted here? |
|---|---|---|
| Part 1 — writing rules | 53 rules in 9 sections, covering words, verbs, sentences, procedures, punctuation | **Yes** |
| Part 2 — dictionary | ~900 approved words, each with one approved meaning | **No** |

Counts are from Issue 7 and still hold at Issue 9 (January 2025).
Issue 7 consolidated the rule set from 65 down to 53. Cite 53.

**The dictionary is not adopted, and this is deliberate.** The
approved-word list was built for aircraft maintenance. It does
not contain `chromatin`, `eigenvector`, `deflation`, or
`insulation score`. A literal reading would forbid the vocabulary
this workspace exists to use.

STE itself supplies the escape. Its Technical Name and Technical
Verb rules cover words the dictionary omits. A word qualifies when
it names a real part, material, process, or measurement in the
subject domain. Every domain term below qualifies. Use them
freely, and define them per rule 5a.

### The Part 1 rules that bind here

| Rule | Applied form |
|---|---|
| Sentence length | Under 20 words. STE allows 25 for descriptive text; the nexus uses 20 everywhere, which is stricter and simpler to check. |
| One idea per sentence | Split on `and`, `but`, and semicolons when each half stands alone. |
| Active voice | Name the actor. Write "the watcher emits", not "an emit is produced". |
| Paragraph length | Six sentences or fewer. |
| Noun clusters | Three words maximum. "watcher snapshot staleness bound" becomes "the staleness bound on the watcher snapshot". |
| Articles | Keep `a`, `an`, `the`. Do not write telegraphic prose. |
| One word, one meaning | See the caveat below. |

**Caveat on "one word, one meaning".** One nexus term departs from
this rule, and one only looks like it does.

| Term | Status in the dictionary | Verdict |
|---|---|---|
| `emit` | unapproved, with an alternative given | no breach — rule 1.6 permits it as a Technical Name |
| `floor` | approved, and used in dictionary examples | a real departure from rule 1.3 |

So `floor` is the honest example, not `emit`. The nexus reuses an
approved word in a second sense.

STE also supplies the remedy. Rule 1.8 says to use technical names
that agree with approved nomenclature. `GLOSSARY.md` **is** that
nomenclature. Listing a term there is the sanctioned fix, not a
confession.

The specification also permits one word in both roles. It must fit a
Technical Name category and a Technical Verb category. Its own example
is "rivet". So dual-role words are not banned outright. Still, do not
coin new ones. Each costs a glossary row and a reader's second guess.

## Defining internal terms

Rule 5a says "no jargon". Taken literally the nexus cannot obey
it. `emit`, `floor`, `wrap-up`, `parked`, `ghost`, and `preflight`
are load-bearing internal terms. None has a plain-English
equivalent. Project work adds its own. Gene names, assay names,
and metric names are all Technical Names.

The achievable rule is narrower and is the one that binds:

> Define every internal term on first use, in **every artefact
> that travels on its own.**

A report, an issue comment, a PR body, and a figure caption each
circulate separately. A reader may see one and never the others.
So each one carries its own first-use definition. Repeating a
definition across artefacts is correct, not redundant.

The definition is one clause, inline, in parentheses or after an
em dash:

> The watcher emitted a service-health line (an *emit* — one
> block the watcher prints for the orchestrator to act on).

## The glossary makes definitions stable

Rule 6 asks for consistency across turns. No agent can honour
that from memory. A fresh session does not know what wording the
last session used, so definitions drift.

`skills/nexus.writing/GLOSSARY.md` is the mechanism. It holds one
approved definition per internal term. Read it, then copy the
definition rather than inventing one.

| Action | How |
|---|---|
| Define a term | Copy its line from `GLOSSARY.md` verbatim. |
| Term is missing | Add a row in the same PR that first uses the term. |
| Definition is wrong | Change `GLOSSARY.md`. Do not write a local variant. |

The glossary is repo-tracked, so it survives every session
restart. That is the whole point: the consistency lives in the
file, not in an agent's context.

## Tables

Rule 5b: put every stat and every result in a table. Prose hides
numbers; a table lines them up for comparison.

A table is required when you report counts, sizes, durations,
rates, pass/fail outcomes, or per-item results. A single number
in a sentence is fine.

Fixed columns keep tables comparable across turns:

| Table kind | Required columns, in order |
|---|---|
| Measurements | `Metric` \| `Value` \| `Unit` \| `Source` |
| Per-item results | `Item` \| `Result` \| `Evidence` |
| Comparisons | `Item` \| `Before` \| `After` \| `Delta` |
| Findings | `Finding` \| `Where` \| `Severity` \| `Action` |

Add columns when a table needs them. Do not rename or reorder
the required ones. `Source` and `Evidence` mean a file path, a
command, a log line, or a URL. Give something a reader can check.

## What this does not cover

- **Code and commit messages.** Follow the surrounding
  conventions in the repo you are editing.
- **Machine-read output.** JSON, TSV, and log lines follow their
  own formats.
- **Enforcement.** Nothing checks these rules today.
  `ng report-check` validates report structure, not style. A
  style check in `report-init` or `report-check` is the obvious
  next step; it is not built.

## See Also

- `nexus.worker-defaults` — the `## Worker floor` bullet that
  carries rules 3 to 5b into every worker spawn prompt.
- `nexus.report` — report structure. Structure is that skill;
  style is this one.
- `nexus.dashboard` — dashboard size budgets. Tables over
  narrative there is the same instinct as rule 5b here.
- `nexus.self-fix` — the cross-fork PR body template. Its
  "1-2 plain-English sentences" plus "terse table" is this
  skill applied to one artefact.
