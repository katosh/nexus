---
description: "You are about to PUBLISH A CHECKABLE CLAIM — a count, a `path:line`, a timeline across refs, a set membership, a 'nobody has done this' — in an issue, a PR body, a comment, a report or a skeptic verdict. Covers this workspace's dominant defect family (a tool answering confidently, at rc 0, in a shape that reads as normal), what provenance makes a number re-derivable, the merge-shape taxonomy behind a 'PRs merged' denominator, why a predicate over source text for a runtime property must state which direction it errs in, and the cross-checks that agree with themselves and therefore verify nothing."
---

# nexus.claims — publishing a number somebody could check

TRIGGER when: a count, a percentage, a `path:line`, a
`before → after` series, a "N of M", or a claim of ABSENCE is about to
leave your session — into an issue, a PR body, a comment, a report, a
dashboard or a skeptic verdict; you are enumerating a population you
intend to assert something about; you are reconciling two numbers and
about to treat their agreement as verification.

The one-line rules live in the workspace `CLAUDE.md` under "Pathspecs,
timelines and published counts" and carry the executed blocks. This is
the worked detail.

## The family

A tool answers CONFIDENTLY, at rc 0, with nothing on stderr, and the
answer is wrong in a shape that reads as normal. In rough order of how
well each survives review:

| shape | why it survives | the check |
|---|---|---|
| **silent zero** | "none found" and "none exists" are the same bytes | sanity-check against an independently derived total |
| **short count** | sits at no suspicious extreme; a zero at least invites doubt | test the PRODUCER's rc, not the last command's |
| **plausible over-count** | a bigger number reads as thoroughness | ask the opposite question — is this larger than the container could hold? |
| **confident uniform value** | reads as consistency | suspect the probe answered about the CONTAINER |
| **manufactured success** | every artefact says the work was done; the only evidence is an absence | never test a status you did not capture before piping |

**A stale number is the quietest member and is not in the table**,
because it is not produced by a wrong tool at all: it is a correct
measurement, carried across a change to one of its inputs.

## Provenance — what makes a number re-derivable

A count is a property of **a tree**, of **a moment**, and — for an
abbreviated hash — of **the repository doing the reading**.

- **Name the command AND the ref.** The most natural counting commands
  answer about YOUR CHECKOUT, not about a ref: `git ls-files`, `find`,
  `wc -l` over a glob and any `grep -c` read the index or the working
  tree. "N files at `<ref>`" is true only when your checkout IS
  `<ref>` — and a worker on a feature branch reports a number off by
  exactly that, looking entirely plausible.
- **An abbreviated hash's WIDTH is not a property of the ref**
  (`<your-org>/nexus-code#1249`, worked example `#1122`). `#1122` pinned
  its ref correctly and broke anyway: it matched a hard-coded
  7-character prefix against `--format='%h'` in a repository that had
  grown enough for git to print 8. Measured — two clones of one repo at
  ONE commit, native `%h` width **7** at in-pack 16151 and **8** at
  21181. A native-only run in the smaller clone proves nothing, and the
  failure arrives as a non-match rather than as an error. Use `%H` (or
  `git rev-parse "${ref}"`) whenever the output will be MATCHED; keep
  `--short` for being READ beside a number.
- **A LINE NUMBER is a count's twin, and worse when stale**
  (`#1163`). A stale count LOOKS wrong; a stale `path:line` points at
  DIFFERENT CODE THAT STILL PARSES, so the reader lands somewhere real,
  reads something coherent, and concludes the citation was about that.
  Cite `path:line` with its ref AND its blob, or quote the line.
- **Never reconcile two citations by their DELTA.** An edit above a
  region shifts everything below it uniformly, so a matching offset
  distinguishes NOTHING: measured on one file across two blobs, all
  three `os.listdir` call sites shifted by exactly 19, so *any* of them
  "reconciles" a delta-19 claim — and in the exchange that produced
  this, one party reconciled against the wrong site, the delta agreed,
  and that agreement is why nobody looked further. Cite by NAME, never
  by distance; a pointer that says "two paragraphs above" is itself a
  line number. A wrong PATH is the lesser hazard precisely because it
  fails loudly.

### A number is also a property of a MOMENT

`<your-org>/nexus-code#996`. Two measured instances from one PR pair, and
in both the figure was **correct when taken**: a positive control quoted
as `5/20` from a 25-assertion version of a suite that had since gained
two controls (`7/20` at the tip), and an open-PR count of `36` fetched
*before* the author opened the two PRs the count was then used to reason
about (`38`, with a real file overlap). The author could have written,
honestly and checkably, *"36 open PRs, `gh pr list` at 08:00Z"* — and
the claim published at 08:25Z would still have been false.

Neither is a miscount, and that is the point. The dangerous pattern is
*measure the board → act on the board → quote the first measurement*.
Two detectors, both cheap, neither run at the time:

- **Reconcile against a declared total before publishing.** `5 + 20 = 25`
  against a suite declaring `27` is falsifiable with no tooling at all.
- **Re-fetch immediately before quoting**, not once at session start —
  above all for a population your own actions have since joined.

### The cross-check that agrees with itself

"My enumeration returns N, and the tool self-reports N, so both measure
the same thing." That reconciliation is worthless when BOTH sides were
computed on the same unnamed tree: it confirms the two agree, never that
either describes the ref being claimed. **Reconciled numbers need their
ref stated exactly as hard as raw ones, and arguably harder, because
agreement reads as verification.**

## A series across refs is a TIMELINE only if the refs form a chain

`git show <ref>:<path>` answers "what did this tree contain", never
"what happened in what order". A monotone count series reads as a
narrative, and the narrative is usually the very thing you were trying
to establish. Refs on divergent branches produce a well-formed series
answering a different question, and nothing errors.

This has already published a wrong mechanism. Counting `shopt -u
nullglob` in `monitor/ng` gave `f75d588 → 3`, `862a693 → 0`,
`514b04d → 0`, `16728e7 → 1` — read as "`#791` fixed it and `#781`'s
merge resurrected it". Measured, the function being counted **did not
exist** on `#791`'s branch, so `#791` could not have fixed anything;
`3 → 0` was two unrelated branch tips. Both claims were retracted on
`<your-org>/nexus-code#790`.

### The ancestor check is NECESSARY, NOT SUFFICIENT

`#828` was filed blaming commit `f18fa91` for turning a lint red, on the
strength of `git log -S`. The ancestor check was run and it PASSED: the
refs did form a chain. The claim was still wrong. `monitor/ng` was
**byte-identical** across the whole range; what changed was the
**lint** — the predicate — broadened one merge later to see a construct
that had been sitting there all along. `48/0` at `a1fe980`, `49/1` at
`5feba19`, same blob. `-S` dates when the SUBJECT appeared; it cannot
date the FAILURE when the PREDICATE also changed inside the range.

> **Vary the axis the MECHANISM varies on, not the axis your SEARCH
> varied on.** A value has at least two inputs — the thing measured and
> the thing measuring it. Hold one constant and bisect the other; if you
> cannot say which one you held constant, you have not bisected.

The cheap check is a blob comparison: `git rev-parse "${A}:${path}"`
against `"${B}:${path}"`. Identical blobs mean the subject is exonerated
and your explanation is somewhere else entirely.

The positive control, recorded because it is the shape to copy:
`<your-org>/nexus-code#774` builds exactly such a table — marker counts in
`CHANGELOG.md` across seven merges — and its refs ARE a linear
first-parent chain into `dev`, every one an ancestor of the next. Its
non-monotonic reading therefore stands. Per-merge against a first-parent
walk is sound; comparing branch TIPS is not.

## The DENOMINATOR is a count too — merge shapes

`grep 'Merge pull request #'` gets it wrong (`<your-org>/nexus-code#931`).
A SQUASH-merged PR has no such subject — its subject is the PR title
ending in `(#N)` — so a merge-subject grep silently omits every squashed
PR. Measured over the last 300 first-parent commits at `e256d4a`: **269**
match the merge subject, and **25 more** end in `(#N)`, so a denominator
built the first way is short by 25 of 294. The `MERGE-ENUMERATION` block
in `CLAUDE.md` carries the four forms.

### That 294 is right THROUGH TWO ERRORS THAT CANCEL

`#946` F1, and it is the part worth internalising. The `(#N)$` bucket
matches a SUBJECT SHAPE; it does not identify a squash-merged PR, and
labelling it "squashed" asserts a property the predicate never checks.
Measured at `e256d4a` against the only key that IS the property — the
`merge_commit_sha` of a merged PR:

```zsh
gh api --paginate 'repos/<your-org>/nexus-code/pulls?state=closed&per_page=100' \
  --jq '.[] | select(.merged_at != null) | .merge_commit_sha' | sort -u \
  | comm -12 - <(git log --first-parent -n 300 --format='%H' e256d4a | sort -u) | wc -l
# -> 294, from 523 merged PRs
```

Same total, **different membership**, by exactly one each way:

- `348f2ce` ends `(#493)` and is in the shape bucket but is **no PR's
  merge commit** — `#493` is an ISSUE. A trailing `(#N)` is a reference,
  not reliably a PR number.
- `a2a28f2` **is** PR `#443`'s merge commit but wears a hand-edited
  third subject shape, `Merge PR #443: …`, invisible to both buckets.
- `76d27ac` lands in the right bucket for the wrong reason: it is PR
  `#448`'s merge commit and its subject ends `(#447)`.

One false member, one missed member, and the totals agree. **A number
that reconciles because its errors cancel is not verified** — the
agreement is what stops anyone looking. Key on `merge_commit_sha` when
the claim is about PRs; use the subject shapes only to say what they
are, which is subject shapes.

The shape UNION answers `295`, not `294`, and that is not a typo: it
repairs the MISSED member and cannot repair the FALSE one, so it sits at
property **+1**. The gap has flipped sign — from silently 25 short to
quietly 1 over. **Do not read the union as a PR count.**

### And a THIRD merge shape neither predicate can see at all

`<your-org>/nexus-code#1271`. GitHub's **rebase merge** REPLAYS the PR's
commits onto the base, so its `merge_commit_sha` is an ORDINARY
one-parent commit wearing the author's own subject, verbatim. It is not
a subject shape anyone forgot to enumerate; it is the ABSENCE of one,
and it is indistinguishable — git-locally — from a direct push.

Measured 2026-09-03 (632 merged PRs), keyed on `merge_commit_sha` plus
the discriminator below: **17 rebase-merged PRs**, of which **15** sit on
`dev`'s first-parent line, and of those **13 are INVISIBLE to the three
documented predicates**. The other two are caught by the `(#N)$` shape
BY ACCIDENT — their subjects end in ISSUE references, not PR numbers. So
15 and 13 answer different questions, and a first draft of this entry
labelled the 13 "rebase-merged PRs": a set named for a property its
predicate never checked, `#946` F1 committed inside the entry that
teaches it.

**THE DEPTH FLAG IS DOING THE WORK, AND WIDENING THE WALK A LITTLE
CONFIRMS THE WRONG ANSWER.** The numbers above are taken over `-n 300`,
where the rebase population is genuinely EMPTY — so *"the union is only
+1 off"* reads as a property of the repository when it is a property of
a window. All 13 sit in one contiguous band, depths **538–554** on
`dev`'s first-parent walk at `5bd6d400`:

    -n 300 -> 0      -n 500 -> 0      -n 537 -> 0
    -n 538 -> 1      -n 554 -> 13     (full walk, 709) -> 13

A reader doing due diligence by raising 300 to 500 gets a FALSE
CONFIRMATION — the check most likely to be run is the one that cannot
fail — and only past 537 does the union silently go 13 short.

The honest git-local answer is the no-filter walk, and **its output is a
CANDIDATE SET, not a verdict**: at `e256d4a` it returns 86 one-parent
no-shape commits over the full walk, of which exactly 13 are the
union-invisible rebase merges and the rest are direct pushes. No
git-local predicate can split that set, because there is nothing in the
commit to split it ON. That form also carries NO REF, so like
`git ls-files` it answers about YOUR CHECKOUT — measured, the same form
returns 87 at `5bd6d400` and 86 at `e256d4a`.

The discriminator, because *"it has one parent"* is not sufficient (a
squash has one parent too): a rebase merge's `merge_commit_sha` carries
the subject of the PR's LAST commit, verbatim, where a squash carries
the PR TITLE plus `(#N)`. Verified against all 17 and a 12-member squash
control group — 17/17 and 0/12.

## A predicate over SOURCE TEXT for a RUNTIME property

**You should be able to say which direction it errs in.** If you cannot,
you do not know whether your zero means "none" or "none that my rule can
see". The worked case is `shopt` state (`<your-org>/nexus-code#1214`);
`CLAUDE.md` carries the rule and the executed block, and the three
natural reading rules fail in three different directions:

- **Scope by FILE** — *"the files containing `shopt -s nullglob`"* —
  cannot see a **sourced library**: the option is shell-wide, so a file
  with no `shopt` anywhere is exposed the moment a setting caller
  sources it. An enumeration built this way missed `monitor/ng`, the
  main CLI, for a compounding second reason: it used a `*.sh` pathspec,
  and `ng` is a shell file by SHEBANG with no extension. The population
  predicate failed on its most important member.
- **Scope by LINE POSITION** — *"the lines after the first global
  `shopt -s`"* — is a LEXICAL rule for a DYNAMIC option and fails in the
  complementary direction: **a function DEFINED before the option is set
  can be CALLED after it.** A scanner using this skipped three real
  sites whose enclosing function was defined 4,400 lines above.
- **Scope by CALL GRAPH** — the rule you reach for once told the first
  two are wrong — still under-counts, in the direction that matters
  most: rules 1 and 2 both assume the setting site is IN YOUR CORPUS,
  and it need not be. With the option set outside (an exported
  `BASHOPTS`, an interactive shell sourcing your file) there is **no
  setting site to root the graph at, so a call-graph rule enumerates
  ZERO** — measured on a two-file corpus containing zero `shopt`
  mentions. That is the silent-zero shape arriving in the most
  sophisticated of the three.

**Three rules, three directions, and the third is not a longer list — it
is the BOUND on the other two.** Rules 1 and 2 fail *within* a corpus
that contains the `shopt`; rule 3 fails when it does not. So the honest
statement is that **the affected set is not bounded by the text you can
search**, and any predicate that starts from a `shopt` you can find is
answering a smaller question than the one you asked. The only rule that
does not under-count is "every shell file", decided by a shared
predicate rather than a filename glob — the only one that does not need
to locate the setting site.

A second, lesser blind spot of a static graph: indirect invocation —
`"$fn" …` where `$fn` holds a shell FUNCTION name. This repo has such
call sites at `monitor/watcher/test-service-health-selfmatch.sh:92,
108-123` (where `fn` iterates `_recover_service_healthy
_sh_service_healthy`) and `monitor/watcher/test-empty-needle-local-copies.sh:240`
— all at `a3177ef6`; cite the CONTENT, because these are the twin this
section is about.
(`${!var}` is NOT an example: of the `${!…}` sites under `monitor/` —
**90** by
`git grep -h -F -e '${!' a3177ef6 -- monitor | grep -oF '${!' | wc -l`
(the ref is IN the command, so it does not answer about your checkout;
`-F` on both stages, per the dialect entry), of which 77
are named expansions and 13 are `${!#}` / `${!1:-}` positional-indirect —
none is function-name indirection: they are array-index `${!arr[@]}`
and indirect-VARIABLE `${!envvar:-}` expansions. An earlier wording
cited three files that carry those forms, so **the claim was true and
the evidence attached to it was not evidence of it** — a quieter defect
than being wrong, because a reader who checks the citation cannot tell
whether the claim or the pointer is at fault. Fix the citation, not just
the claim.)

## A zero out of a parse pipeline is a claim about YOUR INTERPRETER

The worked case is `datetime.fromisoformat` on Python 3.6.9
(`<your-org>/nexus-code#935`); `CLAUDE.md` carries the rule and the two
executed blocks. **The silence has TWO modes and they need DIFFERENT
checks**, which is why lumping them helps nobody.

**Mode 1 — the error is DESTROYED.** A per-item
`try: … except Exception: continue` inside a loop, written to tolerate
BAD ROWS and entirely reasonable for that, also swallows *no such
method* — which is not a data problem at all. Every row is attempted and
discarded, and the probe reports `0 of N` at rc 0.
→ *do not let a bare `except Exception` stand between you and a count
you intend to assert.*

**Mode 2 — the error is PRESERVED AND NEVER CONSULTED**, and this one
needs no `except` anywhere:

    python3 gen.py < rows.txt > parsed.tsv     # rc 1, traceback VISIBLE
    echo "rows parsed: $(wc -l < parsed.tsv)"  # 0 — the file is empty
    while read x; do n=$((n+1)); done < parsed.tsv   # iterates zero times
    echo "gate: clear"                         # succeeds; overall rc 0

Measured (`#926`): `python3` rc **1**, `parsed.tsv` **0 bytes**, loop
iterations **0**, overall rc **0**. Every downstream artefact is
well-formed and prints BELOW the traceback, so the last thing on screen
is a clean-looking answer. That instance shipped seven `gate=clear`
lines and was caught only by reconciling against a known 733.
→ *TEST THE PRODUCER'S RC. That is the half that generalises.*

**The mode's general symptom is worse than that zero.** A missing METHOD
fails before any data is read, so nothing is emitted. A DATA-dependent
failure halfway through leaves the intermediate **truncated at the point
of failure** — a short, entirely plausible count. Measured, a producer
dying on row 3 of 5: intermediate **2 rows**, producer rc **1**, overall
rc **0**. Buffering does not rescue you: on an unhandled exception
CPython runs finalization and flushes `sys.stdout`, so `python3` and
`python3 -u` both leave those 2 rows (identical at 2, 10, 500 and 5000
rows). Do not generalise that to "a dying producer leaves its rows
behind" — `os._exit` and a signal kill BYPASS finalization and leave
**0**, which is worse: same unconsulted rc, and now an empty intermediate
that looks like the zero case. **Refusing an EMPTY intermediate catches
only the zero; the truncated case passes any emptiness check.**

So the generic is NOT "the error was lost" — in mode 2 nothing was lost.
**The error need not be lost; it only needs to be off the path that
produces your number.**

## A claim of ABSENCE is only as old as your last fetch

`git branch -a`, `git log --all`, `git cat-file -e` and friends read the
LOCAL object store. A commit that was never fetched is not "absent from
the repo", it is absent from your copy, and every follow-up check agrees
with the wrong answer. And **LOCAL operations advance REMOTE-knowledge
indicators**: a FAILED `git fetch` truncates `.git/FETCH_HEAD` to zero
bytes and updates its mtime, and your own `git push` writes
`refs/remotes/origin/<branch>` without fetching anything. Neither is a
fetch time. `git fetch` first, or scope the claim to a sha and a date.
See `<your-org>/nexus-code#814`.

## See also

- `CLAUDE.md` "Pathspecs, timelines and published counts" — the rules
  and the executed `LSTREE-PATHSPEC`, `PATHSPEC-GLOB-DEPTH`,
  `ANCESTOR-TIMELINE`, `COUNT-PROVENANCE`, `LOCATION-PROVENANCE` and
  `MERGE-ENUMERATION` blocks.
- `skills/nexus.ci-triage/SKILL.md` — a red is a claim about the tree
  you tested, exactly as a zero is a claim about the population you
  searched.
- `skills/nexus.report/SKILL.md` — where a published number usually ends
  up.
- `skills/nexus.skeptic/SKILL.md` — the pass whose whole job is to
  attack a claim like this one.
