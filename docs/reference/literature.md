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
| **Semantic Scholar (S2)** | Allen Institute academic graph; relevance search, citation graph, metadata | free, instant |
| **ASTA** | Allen AI academic search tool (MCP) | request via the ASTA program |

Both are **optional**. An unconfigured backend is **skipped with a note** —
never a silent hang, never a hard failure of the whole command. With neither
configured, `ng lit` prints these setup references and exits non-zero.

## Acquiring keys

### Semantic Scholar (S2)

1. Visit <https://www.semanticscholar.org/product/api#api-key-form>.
2. Fill in the request form (name, email, intended use). Keys are issued
   quickly, often within a day, sometimes instantly.
3. You will receive the key by email.

### ASTA (Allen AI)

ASTA keys are issued through the ASTA program at Allen AI (the
`asta-tools.allen.ai` MCP service). Request access through the ASTA program
contact; the key is delivered as a string you install exactly like the S2 key.

## Installing a key

Resolution order per backend (first hit wins):

1. **Environment** — `export S2_API_KEY=...` (or `ASTA_API_KEY=...`). Wins over
   all config; best for ephemeral or CI use.
2. **Nexus config** — add under a `lit:` block in `config/nexus.yml` (which is
   gitignored, so inlining the secret is safe):

   ```yaml
   lit:
     s2_api_key: "your-s2-key"
     asta_api_key: "your-asta-key"   # optional
   ```

3. **Legacy `bip` config** — `s2_api_key:` / `asta_api_key:` in
   `<nexus.root>/.config/bip/config.yml`. Read as a fallback so an existing
   `bip` setup keeps working without migration.

Verify with `ng lit status`.

## The reference library

A JSONL file (one paper per line) that `ng lit search` dedups against and
`ng lit add` appends to.

- **Default path:** `<nexus.root>/.bipartite/refs.jsonl`.
- **Versioned library:** set `lit.library_path` in `config/nexus.yml` to a path
  inside your asset repo to track the library under version control.

Record schema (compatible with `bip`'s `refs.jsonl`): `id`, `doi`, `title`,
`authors[]` (`{first,last}`), `abstract`, `venue`, `published.{year,month,day}`,
`source.{type,id}`, `pmid`, `pmcid`.

## Commands

```
ng lit status [--human]
ng lit search "<query>" [--source s2|asta|both] [--limit N] [--year A:B] [--human]
ng lit add <DOI|S2-id> [--human]
ng lit setup
```

Default output is JSON (for agent consumption); `--human` is readable.

### `ng lit status`

Reports the library path + count, which backends are configured (and from
which source — env / config / legacy-bip, never the key itself), and whether
the tool is ready. Exits non-zero and prints setup references if no backend is
configured.

### `ng lit search`

Content-relevance discovery across the configured backend(s). Results are
deduplicated and annotated with `in_library` (true if the DOI is already in the
reference library). `--source` selects backends (default `both`); a requested
backend with no key is skipped with a note.

```console
$ ng lit search "single-cell differential abundance testing" --limit 5 --human
Found 5 papers (sources: s2)

  [IN-LIB] Differential abundance testing on single-cell data using K-nearest neighbour graphs
      E. Dann, N. Henderson, S. Teichmann, M. Morgan, J. Marioni
      Nature Biotechnology (2021)  cites:653  doi:10.1038/s41587-021-01033-z  [s2]
  ...
```

### `ng lit add`

Fetches a paper's metadata from S2 by DOI or S2 paper id and appends a
schema-compatible record to the library. A bare DOI (`10.xxxx/...`) is accepted;
it is dedup-checked by DOI and refused if already present. Requires an S2 key.

### `ng lit setup`

Prints the key-acquisition and installation references (the same guidance shown
when the tool is unconfigured).

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
