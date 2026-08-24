---
description: "Literature research for scientific work: ng lit content-relevance discovery (S2 + ASTA + OpenAlex) deduped against the reference library, ng lit add to grow it, and the convention that scientific reports cite the references (and supporting statements) they find. Use when a scientific task needs grounding in the literature."
---

# nexus.lit — literature research for scientific work

TRIGGER when: a worker is doing scientific work (analysis, a method
write-up, an experiment, a manuscript or a claim that should be
grounded in prior art); a worker needs to know whether a phenomenon,
method, or result is already described in the literature; a worker
wants to find the canonical reference for a claim; a worker is
deciding what to cite in a scientific report.

## The principle

Literature research is an important aspect of **any** scientific task.
Respective workers should consider it whenever relevant — not as a
separate chore but as part of grounding the work. When you make a
quantitative or mechanistic claim, ask whether the literature confirms,
contradicts, or contextualizes it, and reach for `ng lit` to check.

## The tool: `ng lit`

On-demand, content-relevance paper discovery, native to the nexus (no
`bip` install required). Default output is JSON (agent-friendly);
`--human` is readable.

```
ng lit status                                    # keys / library / readiness
ng lit search "<query>" [--source s2|asta|openalex|both|all] [--limit N] [--year A:B]
ng lit add <DOI|S2-id|openalex:Wid>              # pull a paper into the library
ng lit setup                                     # key-acquisition references
```

- **Discovery** — `ng lit search "<content query>"` queries every usable
  backend by default (S2 + ASTA + OpenAlex, `--source all`) and **dedups
  against the local reference library**, annotating each hit
  `in_library: true|false`. Frame the query by content (the
  phenomenon/method/claim), not by title. The three backends are
  complementary — different sources surface different papers — so the
  default set queries all of them rather than picking one.
- **Grow the library** — `ng lit add <DOI>` fetches metadata and appends
  a record. Add the papers you end up relying on so the library (and
  future dedup) stays current. Works even with zero keys configured
  (falls back to OpenAlex for DOI lookups); an S2 key is only needed for
  non-DOI ids (S2 paper id / `CorpusId:...`).
- **Results are ranked — read from the top.** Hits are ordered by
  reciprocal-rank fusion over the backends' own rankings (their relevance
  scores are on incomparable scales, so only rank is fused). A paper
  returned by two backends outranks one at the same position in only one —
  `found_by` and `sources` show that consensus, `rrf` is the score the
  list is sorted by. If you read only the first N, you are reading the
  best N, which was **not** true before this fusion existed.
- **READ `status` FIRST — it is the first field of every response.** It
  has exactly three values, and they must never be conflated:

  | `status` | meaning | exit | what a `count` of 0 would mean |
  |---|---|---|---|
  | `ok` | every requested backend was searched | 0 | nothing matched **the query as asked** — not a verified absence |
  | `partial` | ≥1 backend failed or was skipped | 0 | **nothing** — the search was incomplete |
  | `error` | the query itself failed | 2 | there is no `count` key at all |

  `summary` spells the same thing out in one sentence. On `error` the
  response carries **no `count` and no `results`** — deliberately, so a
  broken search can never be read as an empty literature.
- **Backends degrade gracefully — but a thin result set is not a thin
  literature.** An unconfigured KEYED backend (S2/ASTA) is skipped with a
  note, never a hang; OpenAlex needs no key, so the default `--source all`
  usually still exits 0 **even when a backend died**. That is why
  `status: partial` exists: `failed_backends` names what broke,
  `skipped_backends` what was never configured, and `--human` prints
  `INCOMPLETE`. Re-run before concluding anything. See `ng lit setup` and
  [`docs/reference/literature.md`](../../docs/reference/literature.md)
  for key acquisition (S2/ASTA are optional extras; OpenAlex needs
  nothing).
- **A zero-result search is a signal to reformulate, not evidence of
  absence — and the tool now enforces that.** Every backend ANDs the
  query terms, so a long query is over-constrained and returns a real,
  well-formed zero: one on-topic query walked S2's total from 8616 hits
  at 7 words to 0 at 22, HTTP 200 the whole way. Nothing in the response
  distinguished that from a genuinely silent literature, which is how
  `count: 0` came to be read as "no prior work addresses X". So on a
  zero-result search over 7+ content terms `ng lit` now re-runs your
  query with **one term dropped**, once per term, until something hits;
  if some single-term drop finds papers you get `status: error`,
  `error.kind: query_over_constrained`, the **name of the term that binds
  the zero**, and that near-query to retry — not a zero. Prefer short,
  distinctive topical phrasing over a full sentence in the first place.
- **No `count: 0` is ever labelled *genuine*, *confirmed*, or *verified* —
  and you must not upgrade it yourself.** The probe corroborates; it does
  not certify. Its verdict no longer depends on the order you typed the
  terms in (it is built from the canonical term *set*), but a relaxation's
  result set is still a *superset* of the full query's, so a probe hit
  shows only that the rest of the conjunction is populated — a genuine gap
  inside a populated topic looks identical. The probe is also **capped**
  (`probe.drops_tried` of `probe.content_terms`), so `probe.state: empty`
  means "no drop I got to recovered anything", not "no term is
  responsible". The summary therefore states what was observed and stops
  there. **To write *"to our knowledge, no prior work addresses X"* you
  need several differently-worded and differently-scoped searches, not one
  zero.**
- **`status: partial` with both backend lists EMPTY means the probe could
  not run**, not that every backend answered. Read `probe.state`
  (`inconclusive`) and `probe.reason` — `failed_backends ∪
  skipped_backends` does not witness this case.
- **A named term is only named when the probe can support it.** Before
  attributing anything, the probe searches your content terms with
  *nothing* dropped. If that already hits, a stopword or punctuation was
  the binding constraint — not any content term — and you get
  `probe.reason: reduction_recovered` with `dropped_term: null` and
  "no single content term accounts for this result". Take that verdict
  at face value: it is what a leave-one-out probe can actually
  establish.
- **A quoted phrase suppresses the probe** (`probe.reason:
  quoted_phrase`). The probe rebuilds its query from content terms, which
  un-quotes the phrase and makes it a strictly broader search — any drop
  would then hit and the tool would blame whichever term it tried first.
  It declines instead, so a quoted zero comes back UNVERIFIED. Re-run
  unquoted if you want the corroboration.

## Citing in reports

Scientific reports **may include the literature references you find and
the statements those references support** — unless irrelevant to the
work. Prefer:

- A short claim → reference mapping (what the source establishes), not a
  bare URL dump.
- A real, resolvable identifier (DOI) for each reference.
- Inclusion only where it grounds or qualifies a claim in the report;
  omit literature that does not bear on the work.

This complements the report schema in [`nexus.report`](../nexus.report/SKILL.md):
references live in the body alongside the claims they support.

## What it is not

- Not an embedding/semantic-similarity search over your own library
  (that is `bip semantic`, which needs Ollama and is **not** required
  here). `ng lit` discovery is content-relevance search against S2/ASTA.
- Not a replacement for reading the paper — it finds and catalogs;
  judgment about relevance and correctness stays with the worker.

Full reference: [`docs/reference/literature.md`](../../docs/reference/literature.md).
