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
| `build.sh` | Yes | Applies the scrub to the current checkout in place; skips `exclude` paths in the scrub loop, then drops them and **verifies they are gone** (exit 3 otherwise). **Dry run by default** — `--yes` to act (exit 6 without it), refuses a dirty tree (exit 7) unless `--allow-dirty`, and refuses (exit 8) when it cannot establish a work-tree root (#1001). |
| `leak-gate.sh` | Yes | Fails on any surviving denied token **in file contents or in a file PATH**, and on any `exclude`-listed dictionary path still present in the tree (reads `deny`/`keep`/`exclude` from the mapping). **Refuses (exit 5)** rather than answering when the index and working tree disagree. |
| `overlay/renames.tsv` | **No** (excluded) | Post-scrub PATH renames, for basenames that carry an internal identifier in the file NAME. |
| `README.md` | Yes | This file. |

## Mapping format (`mapping.tsv`, TAB-separated, applied in file order)

```
map      SOURCE   BARE_REPLACEMENT   ANGLE_REPLACEMENT   # substring; .md/.yml use ANGLE
deny     REGEX                                            # leak gate fails on a case-insensitive match
keep     REGEX                                            # exempts a line that also matches a deny
exclude  PATH                                             # drop from the public mirror output
```

### Every `map` needs a `deny`, and the gate reads PATHS too

Two invariants, both learned by measurement rather than argument, and both
enforced by `monitor/watcher/test-public-mirror-dictionary-coverage.sh`
(<your-org>/nexus-code#979 §2):

**A category absent from this file is invisible to BOTH halves of the
toolkit.** The gate reads its `deny` patterns from the same dictionary the
scrub reads its `map` rules from, so an identifier nobody wrote down is not
stripped *and* not flagged — the gate reports CLEAN where the honest answer is
"I was never told to look". A `map` without a matching `deny` is the weaker
version of the same thing: it fixes today's tree and says nothing about
tomorrow's. So every non-sentinel `map` SOURCE must be matched by some `deny`
pattern, and the coverage guard fails when one is not.

**The gate refuses to vouch for a tree it cannot see.** It reads the WORKING
TREE; `git write-tree` — the publish path — reads the INDEX. When the two
disagree, a PASS describes an artifact nobody is going to push, so the gate
exits **5** and says which one you probably meant. `--allow-unstaged` is the
opt-in for deliberately scanning a working copy, and scopes its verdict out
loud. The refusal is about *disagreement*, not about having edited: stage and
the gate answers normally; a staged tree with a denied token still fails 1.
Measured motivation and the recipe are in "Usage" below.

**The gate reads file NAMES as well as file contents.** `git grep` reads
contents only, so a denied identifier sitting in a basename shipped with every
check green; nothing but an operator's memory kept such names off the mirror.
Names cannot be fixed by substitution, which is what `overlay/renames.tsv` is
for — `build.sh` applies the path renames after the scrub and refuses (exit 5)
if one does not take.

### Anchoring a rule whose token collides with ordinary code

Some internal vocabulary is short enough to collide with unrelated identifiers
— an institution abbreviation that is also a common file-handle variable name,
for instance. A rule keyed on the bare token corrupts working code, and the
corruption is silent. Anchor to the specific identifiers, and where a broad
prefix rule is genuinely wanted, bracket it with the **sentinel round-trip**
already used for kept public assets: park the colliding form on a throwaway
token, apply the broad rule, restore. Pair it with a `keep` so the gate makes
the same exemption the scrub does.
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

> `build.sh` rewrites **the checkout it is invoked from, in place**. Run it on a
> throwaway clone, never on a tree you care about.
>
> Since <your-org>/nexus-code#1001 it is **DRY RUN by default**: with no flag it
> prints what it would do and exits **6**, having changed nothing. `--yes` (or
> `NEXUS_MIRROR_BUILD_OK=1`) is the deliberate opt-in for the destructive path,
> and it **refuses a dirty tree** (exit **7**) unless you also pass
> `--allow-dirty`. Exit 6 is not 0 on purpose — a caller that forgot the flag
> must not be handed a success for work that was not done. It also **refuses
> outright (exit 8) when it cannot establish a work-tree root**: that line used
> to be `root=$(git rev-parse --show-toplevel) && cd "$root"`, which outside a
> work tree assigns an EMPTY root, short-circuits, and carries on scrubbing the
> caller's cwd — the incident's own mechanism, inside the script.
>
> The reason is an actual incident: the build was run inside a chain whose
> earlier `cd` had failed (a `git clone --local` hit `Invalid cross-device link`,
> and `zsh` does not abort a `&&`-less chain on a failed `cd`), so it landed in
> the LIVE working tree — 513 files rewritten, the dictionary and the whole
> overlay directory deleted. It is self-concealing: the scrub rewrites rather
> than reports, so `git status` afterwards is a wall of plausible modifications,
> and the file you would use to find out what happened is among the casualties.

```bash
# on a THROWAWAY clone of the source branch (e.g. dev):
monitor/public-mirror/build.sh                       # DRY RUN — prints the plan, exits 6
monitor/public-mirror/build.sh --yes                 # scrub in place, drop excludes, rename paths
git add -A                                           # <-- NOT OPTIONAL. See below.
monitor/public-mirror/leak-gate.sh monitor/public-mirror/mapping.tsv .   # must PASS
# LINT THE ASSEMBLED TREE, not just source (<your-org>/nexus-code#979 §4).
# The linter is run FROM the source checkout AGAINST the assembled tree's
# workflow dir, so a scrub bug in the linter itself cannot hide a workflow bug:
python3 <source-checkout>/monitor/lint-workflows.py .github/workflows   # must exit 0
#   exit 2 = REFUSED (empty or missing dir) — a wrong path cannot pass as clean
# then lay the scrubbed tree as ONE squashed commit on the public repo's
# current HEAD (fast-forward; never force):
tree=$(git write-tree)
commit=$(git commit-tree "$tree" -p <public-HEAD-sha> -m "Sync public mirror to <source-sha>")
git push <public-remote> "$commit:refs/heads/main"
# and record it, so the NEXT sync can compute its merge base:
printf 'sync\t%s\t%s\t%s\tnote\n' "$(date -I)" "$(git rev-parse --short <source-sha>)" \
    "$(git rev-parse --short "$commit")" >> monitor/public-mirror/sync-log.tsv
```

The public mirror is deliberately **single-commit-based**: it is a squash on the
public repo's existing HEAD, never a replay of the private history.

### `git add -A` is the difference between publishing the scrub and publishing the source

`build.sh` scrubs the **working tree** and does not stage. `git write-tree`
records the **index**. Omit the staging step and the commit you push carries the
UNSCRUBBED content — while `leak-gate`, which reads the working tree, reports it
PASS. **The gate proves a different artifact clean than the one that ships.**

Measured on this repo (<your-org>/nexus-code#979): 509 files modified-unstaged
after a build, and `git write-tree`'s copy of one file alone carried **12**
occurrences of an internal identifier that the working copy no longer had. With
`git add -A`: 0 occurrences, dictionary absent, path renames recorded.

**This is enforced, not merely documented** (<your-org>/nexus-code#979 F2). A
documented step that silently ships 512 unscrubbed files when skipped, on a
surface whose failure mode is a permanent public disclosure, is not a remedy —
and nothing about the decision needs operator judgement. So `leak-gate.sh`
**refuses with exit 5** when the index and the working tree disagree, rather
than answering a question about a tree nobody is going to push:

```
LEAK GATE: REFUSED — the index and the working tree disagree.
  If you are publishing:      git add -A   (then re-run this gate)
  If you are scanning a copy: re-run with --allow-unstaged
```

`--allow-unstaged` exists for the legitimate other caller — a test, or an
operator spot-checking a working copy not bound for publication — and prints
that its verdict covers the working tree only, so the two cases never share a
spelling. The refusal is about *disagreement*, not about having edited: stage
the edit and the gate answers normally, and a staged tree carrying a denied
token still fails with exit 1.

`sync-base.sh` runs the three steps in this order for you, which is the point of
having it.

### Lint the ASSEMBLED tree — source-side checks cannot see mirror-only state

`monitor/lint-workflows.py` lints a workflow **directory**, and the only one it
ever sees in this repository is source's own. The mirror carries workflows
source has no copy of — the docs-build / Pages-deploy split is bootstrap state
living in the published tree, not something `build.sh` produces (see "Bootstrap
transforms" below). So a mirror-only workflow can violate a lint rule that
**every source-side check passes**, and nothing in source predicts it.

That happened: a mirror-only workflow's `--jobs` value engaged no deadline
scaling on a 2-vCPU runner (`TD001`), and the sync would have turned the
mirror's CI red on a file no source-side test can read
(<your-org>/nexus-code#979 §4). It was fixed in the mirror by hand.

**The step above is the remedy, and the timing is the whole of it.** The
mirror-only workflows are absent from `build.sh`'s output and appear only after
the three-way merge with the mirror's existing tree — so linting the *built*
tree checks the wrong population and passes. Lint the **merged** tree, in the
window between the merge and `git write-tree`.

The step cannot be vacuous: `lint-workflows.py` **refuses** with exit 2 over an
empty or missing directory rather than reporting a clean lint over nothing
(measured: both cases, `REFUSED: ... no workflow files`). So a mistyped path
fails loudly instead of becoming a confident zero.

A source-side fixture copy of the mirror-only workflows was the other candidate
and is worse: a copy drifts from the thing it stands for, silently, which is the
same defect class one layer up. The assembled tree is the artifact; lint the
artifact.

**Generalises past workflows.** Any source-side guard keyed on the real tree —
a linter, a manifest check, a path enumeration — can be broken by bootstrap
state that exists only downstream. When such a guard's subject is a directory,
point it at the assembled tree before the push; when it is not parameterisable,
record that its verdict does not cover mirror-only state.

## Reconstructing the mirror: the merge base decides correctness

A sync is a three-way merge — the mirror carries hand-made structural decisions
(the public-template disable switch, the workflow split, the renamed basenames)
that a fresh scrub does not reproduce. The merge is sound. **The base is where
it goes wrong, silently, in the leakier direction.**

Take a file unchanged between the two source commits and a dictionary rule that
improved between them — leaky value `L`, good value `G`:

```
CORRECT base = scrub_old(source_old)        WRONG base = scrub_now(source_old)
  base   L                                    base   G   (the improvement IS the base)
  ours   L   (what the mirror carries)        ours   L
  theirs G   (today's scrub)                  theirs G
  -> only theirs moved; take G  ✓             -> ours reads as a deliberate public-side
                                                 revert G->L, theirs as unchanged;
                                                 take L  ✗  no conflict, no diagnostic
```

Nothing errors. The loss is exactly proportional to how much the dictionary has
improved: the better you make the scrub, the more the wrong base throws away. On
the sync that surfaced this, the wrong base produced 2 conflicts and silently
carried a denied token plus 19 occurrences of a URL for a repository that does
not exist; the right base produced 18 — the extra 16 being precisely the
decisions that would otherwise have been made in silence.

**Use `sync-base.sh`.** The correct base is cheap to compute *because the
dictionary is versioned alongside the source*: `scrub_old(source_old)` is just
"check out `source_old` — dictionary, overlay and renames included — and build".
There is no old dictionary to reconstruct. The entire trap is accidentally using
the CURRENT checkout's dictionary against an OLD source tree, which is the
default if you build the base any other way.

```bash
monitor/public-mirror/sync-base.sh /tmp/base        # sha from sync-log.tsv
monitor/public-mirror/sync-base.sh /tmp/base <sha>  # or state it
```

It prints `base_source_sha`, `base_tree`, `base_dir`, `gate`, `renames`,
`overlays`. Exit 2 = bad usage or unresolvable sha, 3 = build failed, 4 = the
base does not pass its own leak gate. A commit whose dictionary it cannot read
reports `gate=UNCHECKED`, never `gate=clean` — "could not check" and "checked
and clean" do not share a spelling here.

**The base it builds will contain values the current dictionary would strip.**
That is correct and is the whole point: it reproduces the artifact the previous
sync actually shipped. A base that looks clean is the wrong base.

`sync-log.tsv` is what makes the sha available without anyone remembering it.
Append to it as part of every sync; a sync that did not record itself has handed
the next one a guess.

Both behaviours are pinned by
`monitor/watcher/test-public-mirror-sync-base.sh`, which builds the scenario and
asserts **both** outcomes — including the wrong one, because a test that only
pins the right answer cannot tell you the trap is still there.

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
