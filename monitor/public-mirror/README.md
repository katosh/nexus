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
| `scrub.pl` | Yes | Data-driven substitution engine (reads a mapping; hardcodes nothing). Matches **case-insensitively** and preserves the match's case shape. |
| `build.sh` | Yes | Applies the scrub to the current checkout in place; skips `exclude` paths in the scrub loop, then drops them and **verifies they are gone** (exit 3 otherwise). |
| `leak-gate.sh` | Yes | Fails on any surviving denied token, **and** on any `exclude`-listed dictionary path still present in the tree (reads `deny`/`keep`/`exclude` from the mapping). |
| `README.md` | Yes | This file. |

## Mapping format (`mapping.tsv`, TAB-separated, applied in file order)

```
map      SOURCE   BARE_REPLACEMENT   ANGLE_REPLACEMENT   # substring; .md/.yml use ANGLE
deny     REGEX                                            # leak gate fails on a case-insensitive match
keep     REGEX                                            # exempts a line that also matches a deny
exclude  PATH                                             # drop from the public mirror output
```
Order matters — put longer sources before their prefixes (e.g. a
`your-org/some-repo` line before the bare `your-org` line).

`map` SOURCEs match **case-insensitively** (so the case-insensitive `deny`
gate can never flag a variant the scrub missed — the mismatch that leaked
`@SECRETORG-BOT` while stripping the lowercase form). The replacement is the
authored string for lowercase/Titlecase matches and upper-cased for an
ALL-CAPS match, so `SECRETORG` → `YOUR-ORG` while `Secretorg` → `your-org`.

### The dictionary is a leak vector — it is dropped, never shipped

`mapping.tsv` is the ONE file that names the internal SOURCE identifiers (by
design — it has to, to find them). It is therefore **excluded** from the
public output rather than scrubbed: a scrubbed dictionary is a useless one
(its SOURCE column would no longer match anything), and scrubbing it *in place
mid-run* corrupts the dictionary for every file processed afterwards — the
183-file leak of <your-org>/nexus-code#537. Two independent guards enforce that
it never ships: `build.sh` drops it and hard-fails (exit 3) if the drop did not
take, and `leak-gate.sh` fails if any `exclude` path is present in the scanned
tree. The shipped, generic stand-in is `mapping.example.tsv`.

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

The unit suite stays green under the disable switch:
`monitor/watcher/_test_helpers.sh` exports `NEXUS_PUBLIC_ENABLED=1` (inert
on a tree that ships no guard), so hermetic tests that execute guarded entry
points — e.g. `test-jupyter-service.sh` running `bootstrap-recover.sh` — pass
on the mirror's CI.

**The guard's *refusal* path (it still fires when `NEXUS_PUBLIC_ENABLED` is
unset) is not yet asserted by any CI** (<your-org>/nexus-code#520). It cannot be
covered from this source repo: `_public-guard.sh` and its call sites ship only
in the mirror (bootstrap state carried in the published tree, not produced by
`build.sh`), and nothing in source consumes `NEXUS_PUBLIC_ENABLED` beyond the
setter above — so a source-side test could only exercise a hand-written
fixture, not the shipped guard. The refusal assertion therefore belongs in the
**mirror** (a mirror-side test asserting a guarded entry point refuses with the
unlock variable unset), landed with the mirror sync.
