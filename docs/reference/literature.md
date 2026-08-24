# Literature research (`ng lit`)

`ng lit` is the nexus literature-research tool: on-demand, content-relevance
paper discovery for Claude workers, deduplicated against a local reference
library, with a one-step "pull this paper into the library" verb. It is a
native reimplementation (plain `curl` + `jq`) of the small subset of
[bipartite](https://github.com/matsen/bipartite) (`bip`) utilities the nexus
needs, so it ships in nexus-code and works in any operator's clone with **no
dependency on a locally-installed `bip` binary**.

Literature research is a first-class part of scientific work in the nexus.
Workers on a scientific task should use `ng lit` to ground claims in the
literature whenever relevant, and may cite the references they find (and the
statements those references support) in their reports — see
[the `nexus.lit` skill](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.lit/SKILL.md).

## Backends

| Backend | What it is | Key |
|---|---|---|
| **Semantic Scholar (S2)** | Allen Institute academic graph; relevance search, citation graph, metadata | free, but requires a contact-form request (no guaranteed turnaround); the unauthenticated pool 429s under real load |
| **ASTA** | Allen AI academic search tool (MCP) | request via the ASTA program |
| **OpenAlex** | Fully open academic graph (works, citations, institutions, funders) | **none** — works unauthenticated, no request needed |

The three backends are **complementary, not redundant**: ASTA and S2 rank by
semantic/citation relevance over the S2 graph; OpenAlex ranks by its own
`relevance_score`, needs no key, covers a much broader corpus, and adds the
citation graph plus institution/funder metadata. `ng lit search` queries every
backend selected by `--source` (default `all`), dedups the union, and fuses
the rankings — for a tool whose point is comprehensiveness, more independent
sources beats picking one.

They have different failure modes, and knowing them is worth more than a
single quality score. On queries built from **distinctive vocabulary**
OpenAlex is excellent. On **compositional** queries — a concept assembled
from common words, e.g. *differential abundance testing* + *single cell* +
*neighborhoods* — its tail skews toward generically famous papers that merely
contain the words (measured: median ~2100 citations for OpenAlex hits vs
single digits for S2/ASTA, and OpenAlex is the only backend that returns the
same landmark papers across unrelated queries). Its top hit is usually right;
the tail is the weak part. Rank fusion is what keeps that tail from being
presented as equal to a strong S2/ASTA hit.

S2 and ASTA are **optional**: an unconfigured KEYED backend is **skipped with
a note** — never a silent hang, never a hard failure of the whole command.
OpenAlex is **never unconfigured** — it requires no key, so it is always
attempted when selected (which is always, by default). Only an explicit
`--source s2|asta|both` request with no matching key falls back to printing
setup references and exiting non-zero — the default (`all`) always succeeds
because OpenAlex alone is enough to serve a search.

## Acquiring keys

### Semantic Scholar (S2)

1. Visit <https://www.semanticscholar.org/product/api#api-key-form>.
2. Fill in the request form (name, email, intended use). In practice this is
   a general contact form; a submission may be acknowledged only with a
   "we are working through a backlog" notice and no stated turnaround —
   treat it as best-effort, not "free and instant," and provision it ahead
   of when you need it rather than expecting it on demand.
3. You will receive the key by email, if/when it arrives.

!!! warning "S2 keys expire on inactivity"
    Semantic Scholar deactivates keys that go **unused for ~60 days** (stated
    on the request form). The failure mode is silent: after a quiet stretch,
    searches that worked before start coming back as auth errors / skipped-S2
    notes for no obvious reason. If that happens, the key was almost certainly
    pruned — re-request a fresh one at the same form. (OpenAlex, which needs no
    key, is unaffected and keeps `ng lit` working through any S2 gap.)

### ASTA (Allen AI)

ASTA keys are issued through the ASTA program at Allen AI (the
`asta-tools.allen.ai` MCP service). Request access through the ASTA program
contact; the key is delivered as a string you install exactly like the S2 key.

### OpenAlex

No key, no request, no waiting — `ng lit` calls the OpenAlex REST API
unauthenticated. The only thing worth configuring is a contact email for
OpenAlex's "polite pool" (a higher, more reliable rate limit — it is not an
auth mechanism, just good etiquette): see [Installing a key](#installing-a-key)
below.

## Installing a key

Resolution order per backend (first hit wins):

1. **Environment** — `export S2_API_KEY=...` (or `ASTA_API_KEY=...`). Wins over
   all config; best for ephemeral or CI use.
2. **Nexus config** — add under a `lit:` block in `config/nexus.yml` (which is
   gitignored, so inlining the secret is safe):

   ```yaml
   lit:
     s2_api_key: "your-s2-key"
     asta_api_key: "your-asta-key"        # optional
     openalex_mailto: "you@your-org.edu"  # optional; polite-pool contact
   ```

3. **Legacy `bip` config** — `s2_api_key:` / `asta_api_key:` in
   `<nexus.root>/.config/bip/config.yml`. Read as a fallback so an existing
   `bip` setup keeps working without migration.

OpenAlex has no key to install; `lit.openalex_mailto` is optional and falls
back to `notifications.email.address` (already set for most nexuses) if left
blank, so a fresh clone gets the polite pool with zero extra setup.

Verify with `ng lit status`.

## The reference library

A JSONL file (one paper per line) that `ng lit search` dedups against and
`ng lit add` appends to.

- **Default path:** `<nexus.root>/.bipartite/refs.jsonl`.
- **Versioned library:** set `lit.library_path` in `config/nexus.yml` to a path
  inside your asset repo to track the library under version control.

Record schema (compatible with `bip`'s `refs.jsonl`): `id`, `doi`, `title`,
`authors[]` (`{first,last}`), `abstract`, `venue`, `published.{year,month,day}`,
`source.{type,id}`, `pmid`, `pmcid`. `source.type` is `s2`, `asta`, or
`openalex` depending on which backend the record was pulled from.

## Commands

```
ng lit status [--human]
ng lit search "<query>" [--source s2|asta|openalex|both|all] [--limit N] [--year A:B] [--human]
ng lit add <DOI|S2-id|openalex:Wid> [--human]
ng lit setup
```

Default output is JSON (for agent consumption); `--human` is readable.

### `ng lit status`

Reports the library path + count, which backends are configured (and from
which source — env / config / legacy-bip, never the key itself), and whether
the tool is ready. OpenAlex always reports available (no key needed), so
`ng lit status` no longer exits non-zero for a missing S2/ASTA key — search
still works. Setup references are still printed as a hint whenever S2 and
ASTA are both unconfigured, since that leaves relevance ranking and `add`
unavailable even though search itself keeps working via OpenAlex.

### `ng lit search`

Content-relevance discovery across the selected backend(s). Results are
deduplicated (by **case-folded** DOI, falling back to id/title), fused into a
single relevance ranking, and annotated with `in_library` (true if the DOI is
already in the reference library).

#### Ranking — how multiple backends become one ordered list

Backends rank their own hits well but score them on **incomparable scales**
(S2's score, ASTA's, and OpenAlex's `relevance_score` are unrelated numbers),
so results are combined by **reciprocal-rank fusion** (RRF) over each hit's
*rank within its own backend* — the only cross-backend-comparable signal.
Each backend that returned a paper contributes `1/(60 + rank)`, and the
scores are summed.

The practical consequence: **agreement between backends wins.** A paper
returned by two backends outranks one sitting at the same position in only
one, because cross-backend consensus is itself a relevance signal. (A plain
mean-of-ranks would throw that away — worse, it would *penalise* a paper for
also being found, slightly lower, by a second backend.) A paper missing from
a backend is simply absent from the sum rather than charged a fabricated
worst-case rank.

Each result therefore carries:

| Field | Meaning |
|---|---|
| `rrf` | fused score; the list is sorted by this, descending |
| `rank` | best (lowest) rank the paper achieved in any single backend |
| `mean_rank` | mean of its ranks across the backends that returned it |
| `sources` | every backend that returned it, e.g. `["openalex","s2"]` |
| `found_by` | how many backends returned it |

Deduplication case-folds the DOI because OpenAlex lowercases every DOI it
returns while S2/ASTA return them as deposited — roughly one DOI in eight
carries an uppercase letter, so a case-sensitive key would split those papers
into two records.

`--source` selects backends:

| Value | Backends | Notes |
|---|---|---|
| `all` (default) | S2 + ASTA + OpenAlex | every usable backend; OpenAlex always joins since it needs no key |
| `both` | S2 + ASTA | legacy pair, for scripts that want to pin out OpenAlex explicitly |
| `s2` / `asta` / `openalex` | one backend | |

A requested KEYED backend (s2/asta) with no key is skipped with a note, same
as before OpenAlex existed. Requesting `s2`, `asta`, or `both` with no
matching key(s) configured still exits non-zero with setup references — but
the default `--source all` never does, since OpenAlex alone is enough to
serve results. A backend that fails at request time (network error, rate
limit) is likewise skipped with a note; the command only fails if *every*
selected backend failed or was skipped.

### The three result states

Because the command usually **succeeds** even when a backend died, the state
of the search announces itself **in-band**, on stdout, where a caller that
captures JSON will actually see it (stderr notes are easy to miss). `status`
is the first field of every response and has exactly three values:

| `status` | Meaning | Exit | A `count` of 0 means |
|---|---|---|---|
| `ok` | every requested backend was searched | 0 | nothing matched **the query as asked** — not a verified absence |
| `partial` | ≥1 backend failed or was skipped | 0 | **nothing** — the search was incomplete |
| `error` | the query itself failed | 2 | *there is no `count` key* |

`summary` states the same thing in one sentence, written to be read by an
agent. Supporting fields:

| Field | Meaning |
|---|---|
| `failed_backends` | requested, attempted, and errored — **your results are incomplete** |
| `skipped_backends` | requested but unusable (no key) — expected, benign |
| `partial` | `true` iff `status != "ok"` (either of the above, **or an unrunnable probe**) |
| `complete` | `true` iff every requested backend contributed |
| `probe` | what the zero-result relaxation probe did: `state` (`not_run`/`hits`/`empty`/`inconclusive`), `reason`, `backend`, `content_terms`, `drops_tried`, `max_drops`, `dropped_term`, `query` |

`probe.reason` names *why* a probe did not produce a verdict, or which way it
did, so `not_run`/`inconclusive`/`hits` do not repeat the ambiguity `partial`
had: `results_returned`, `too_few_content_terms`, `quoted_phrase`,
`no_backend_available`, `backend_error`, `reduction_recovered`. It is `null`
when a single term was named.

`partial` has **two** causes and the backend lists witness only one of them.
A probe that could not run also sets `partial`, with `failed_backends` **and**
`skipped_backends` both empty — so a caller inspecting only those two lists
finds nothing wrong and concludes nothing is. Read `probe.state`:
`inconclusive` is that case.

On `status: "error"` the response deliberately carries **no `count` and no
`results` key** — `.count` reads `null`, never `0`, and the command exits 2.
A well-formed empty result set is exactly how a broken search comes to be
read as an empty literature, so an error is never dressed as one.

`--human` mirrors this: an incomplete search is headlined `INCOMPLETE` with a
`WARNING:` line, and a failed one prints `SEARCH FAILED` and no result count.

**Why the distinction is enforced rather than advisory.** Every backend ANDs
the query terms, so a long query is over-constrained and returns a real,
well-formed zero. Measured live (2026-07-29), one on-topic query's S2 total
walked 8616 → 136 → 21 → 2 → 0 as it grew from 7 to 22 words, HTTP 200
throughout; OpenAlex answered the same 41-word query with `count: 0`,
`partial: false`, no failed backends and exit 0, while a 6-word prefix of it
returned thousands of hits. That zero is arithmetically true of the
conjunction and substantively false about the literature — and an agent handed
it will legitimately write *"to our knowledge, no prior work addresses X."*

Since no response field separates the two cases, `ng lit` **measures** rather
than guesses. On a zero-result search over 7+ **content terms** (stopwords
dropped, deduplicated), it re-runs the query against a backend that already
answered with **one content term removed**, once per term, stopping at the
first relaxation that hits — *leave-one-out*. If some single-term drop finds
papers, you get `status: "error"`, `error.kind: "query_over_constrained"`, the
name of the term that binds the zero, and that near-query to retry. If none
does, the zero is reported cleanly with the probe result and its coverage
stated alongside it. The probe runs only on the zero-result path and can only
ever escalate a zero — never suppress a hit.

**Cost.** One drop-zero baseline plus up to `LIT_PROBE_MAX_DROPS` (6) extra
requests on a zero-result search, early-exiting at the first hit — so a genuine zero pays the full cap
and an over-constrained query usually pays one or two. Lower the cap to trade
detection for latency. The drops are spaced by `LIT_PROBE_DELAY_SECS` (1s,
never before the first): fired back-to-back they earn `S2: Too Many Requests`
(measured 2026-07-30), which degrades a would-be clean zero to
`partial` / `probe.state: "inconclusive"`. A genuine zero therefore costs
roughly the cap in requests plus five seconds of pacing.

**Why leave-one-out and not a shorter query.** The original probe re-ran the
query's first six whitespace tokens. A conjunction is commutative and a
positional prefix is not, so the same eight terms re-ordered landed on
opposite branches — same corpus, same ground truth, different verdict. The
relaxation is now built from the query's canonical content-term **set**, which
makes the verdict invariant under re-ordering, and under case, surrounding
punctuation and stopword decoration. Pinned by
`monitor/watcher/test-lit-probe-order-dependence.sh`.

Dropping one term also says something a prefix cannot. It is the *closest*
query to the one you asked that still hits, so the remedy points at your own
question rather than at a broader one, and a hit **names** the binding term.

**What the probe does NOT establish.** It is corroborating evidence, not a
verdict, and neither branch of it is reported as one:

- A relaxation's result set is a **superset** of the full query's, so a probe
  hit means only *"the rest of the conjunction is populated"*. A genuine,
  meaningful conjunctive gap inside a populated topic — nothing published on
  X ∧ Y — has exactly that signature. `query_over_constrained` therefore says
  the zero **may** reflect an over-specific query, not that it does.
- The probe is **capped**, so `probe.state: "empty"` means *"no single-term
  drop among the `drops_tried` I got to recovered anything"*, not *"no term is
  responsible"*. With more content terms than the cap, drops that sort past it
  are never tried; the miss is invariant and fails safe (you get the hedged
  zero, not a confident one), and `drops_tried` / `content_terms` report the
  coverage actually achieved.
- `dropped_term` names the term whose removal recovered hits **from the query
  reduced to its content terms**, not from the query as you wrote it. The
  reduction lowercases, trims punctuation, drops stopwords, dedupes and
  re-orders — and two of those can recover hits *on their own*, which would
  make any named term a guess. Both are handled by refusing to name one:
  - **Stopwords.** The probe first searches the reduction with **nothing
    dropped**. If that already hits, a stopword (or punctuation, or casing)
    was the binding constraint, not any content term: you get
    `probe.reason: "reduction_recovered"`, `dropped_term: null`, and the
    message says *no single content term accounts for this result*. Without
    that baseline the first drop hits trivially and an arbitrary term gets
    blamed — measured, `… medulloblastoma without` was blamed on `cell`,
    which is not binding.
  - **Quoted phrases**, since
    the reduction un-quotes it and an un-quoted phrase is strictly broader —
    so *any* drop would hit. A query containing a double quote is **not
    probed** at all: `probe.state: "inconclusive"`,
    `probe.reason: "quoted_phrase"`, and the zero is reported as `partial` /
    UNVERIFIED rather than with a wrong culprit.

A `count: 0` from this command is consequently never labelled *genuine*,
*confirmed*, or *verified* — it reports what was observed and leaves the
inference to you.

The corollary for callers: to support *"to our knowledge, no prior work
addresses X"*, run several differently-worded and differently-scoped searches.
One `count: 0` is a single observation, not a literature review.

Other `error.kind` values: `query_too_long` (over OpenAlex's 1500-character
ceiling; caught pre-flight, before a request is spent), `query_rejected` (a
backend returned a query-fault error — unretryable, and it condemns the whole
search because every backend answered the same bad query), and
`no_backend_searched` (nothing ran at all, so nothing was established).

```console
$ ng lit search "single-cell differential abundance testing" --limit 5 --human
Found 5 papers (sources: asta openalex)

  [IN-LIB] Differential abundance testing on single-cell data using K-nearest neighbour graphs
      E. Dann, N. Henderson, S. Teichmann, M. Morgan, J. Marioni
      Nature Biotechnology (2021)  cites:960  doi:10.1038/s41587-021-01033-z  [openalex]
  ...
```

### `ng lit add`

Fetches a paper's metadata and appends a schema-compatible record to the
library, dedup-checked by DOI (refused if already present):

- **With an S2 key** (unchanged): accepts a bare DOI (`10.xxxx/...`) or an
  S2 paper id / `CorpusId:...`, via S2.
- **Without an S2 key**: falls back to OpenAlex, which needs no key but only
  resolves a bare DOI or an OpenAlex work id (`Wnnnn` or `openalex:Wnnnn`) —
  it has no equivalent of an S2 paper id / `CorpusId:...` to look up by.

So `ng lit add <DOI>` now works on a completely unconfigured nexus; only
non-DOI ids still require an S2 key.

### `ng lit setup`

Prints the key-acquisition and installation references (the same guidance shown
when S2 and ASTA are both unconfigured).

## Optional: in-library semantic similarity

Content discovery (S2/ASTA relevance search) needs **no** embeddings. A separate
embedding-based "find papers in my library similar to X" capability exists in
`bip` (`bip semantic`/`bip index build`) and requires a running Ollama with the
`all-minilm:l6-v2` model; it is **not** required for discovery or library
updates and is not reimplemented here.

## See also

- [`nexus.lit` skill](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.lit/SKILL.md) — when and how a worker
  should reach for literature research.
- [`ng` CLI reference](ng-cli.md) — the full verb index.
