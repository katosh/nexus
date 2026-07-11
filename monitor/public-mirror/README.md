# public-mirror scrub toolkit

Reproducible, versioned tooling to publish a **scrubbed public mirror** of this
nexus checkout — with every institutional / private identifier removed or
genericized — as a single squashed commit on the public repo.

## Self-scrub contract

The toolkit **scrubs itself**. The only file that names the internal
identifiers being scrubbed *from* is `mapping.tsv`, and that file is
**excluded from the public mirror output** (its own `exclude` line, honored by
`build.sh`). Every other file here — `scrub.pl`, `build.sh`, `leak-gate.sh`,
this README, and `mapping.example.tsv` — names only the public *replacement*
vocabulary and the transform logic, never an internal source string. So the
public copy of this directory passes the same zero-leak gate as the rest of the
tree. A scrubber that shipped the very dictionary of secrets it scrubs would be
the failure mode; this design closes it.

## Files

| File | Ships to public? | Purpose |
|---|---|---|
| `mapping.tsv` | **No** (excluded) | Internal `map`/`deny`/`keep`/`exclude` dictionary. The one file with internal strings. |
| `mapping.example.tsv` | Yes | Placeholder template a new operator fills in. |
| `scrub.pl` | Yes | Data-driven substitution engine (reads a mapping; hardcodes nothing). |
| `build.sh` | Yes | Applies the scrub to the current checkout in place; drops `exclude` paths. |
| `leak-gate.sh` | Yes | Fails on any surviving denied token (reads `deny`/`keep` from the mapping). |
| `README.md` | Yes | This file. |

## Mapping format (`mapping.tsv`, TAB-separated, applied in file order)

```
map      SOURCE   BARE_REPLACEMENT   ANGLE_REPLACEMENT   # literal substring; .md/.yml use ANGLE
deny     REGEX                                            # leak gate fails on a case-insensitive match
keep     REGEX                                            # exempts a line that also matches a deny
exclude  PATH                                             # drop from the public mirror output
```
Order matters — put longer sources before their prefixes (e.g. a
`your-org/some-repo` line before the bare `your-org` line).

## Usage (ongoing sync)

```bash
# on a CLEAN checkout of the source branch (e.g. dev):
monitor/public-mirror/build.sh                       # scrub in place, drop excludes
monitor/public-mirror/leak-gate.sh monitor/public-mirror/mapping.tsv .   # must PASS
# then lay the scrubbed tree as ONE squashed commit on the public repo's
# current HEAD (fast-forward; never force):
tree=$(git write-tree)
commit=$(git commit-tree "$tree" -p <public-HEAD-sha> -m "Sync public mirror to <source-sha>")
git push <public-remote> "$commit:refs/heads/main"
```

The public mirror is deliberately **single-commit-based**: it is a squash on the
public repo's existing HEAD, never a replay of the private history.

## Bootstrap transforms (baked into the published tree, not re-derived here)

The first public cut also applied a few **structural** changes beyond identifier
substitution, which live in the published tree and are preserved on each sync:
the public-template disable switch (`monitor/_public-guard.sh` + its call sites,
so a fork cannot autostart agents), the docs-build / Pages-deploy workflow split,
and a small number of file renames (institution-specific basenames →
neutral). `build.sh` handles the reproducible **identifier** scrub + the
self-scrub exclusion; the structural decisions above are one-time bootstrap
state carried forward in the tree.
