---
description: "Literature research for scientific work: ng lit content-relevance discovery (S2 + ASTA) deduped against the reference library, ng lit add to grow it, and the convention that scientific reports cite the references (and supporting statements) they find. Use when a scientific task needs grounding in the literature."
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
ng lit search "<query>" [--source s2|asta|both] [--limit N] [--year A:B]
ng lit add <DOI|S2-id>                           # pull a paper into the library
ng lit setup                                     # key-acquisition references
```

- **Discovery** — `ng lit search "<content query>"` queries Semantic
  Scholar and ASTA by relevance and **dedups against the local reference
  library**, annotating each hit `in_library: true|false`. Frame the
  query by content (the phenomenon/method/claim), not by title.
- **Grow the library** — `ng lit add <DOI>` fetches metadata and appends
  a record. Add the papers you end up relying on so the library (and
  future dedup) stays current.
- **Backends degrade gracefully** — an unconfigured backend is skipped
  with a note, never a hang. If nothing is configured, the tool prints
  setup references; see `ng lit setup` and
  [`docs/reference/literature.md`](../../docs/reference/literature.md)
  for key acquisition (S2 is free + instant).

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
