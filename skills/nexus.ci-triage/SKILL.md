---
description: "A PR's CI has gone RED and you do not yet know whether the base or your diff caused it. CI builds the MERGE ref, so a red at your head is a claim about base+yours, never about yours alone — and inheriting a red is the normal case here, not the exotic one. Covers the check-dev-in-isolation recipe (a UNIQUE per-caller worktree, never a fixed path, never `git checkout` on the main clone), what a worktree's missing gitignored and untracked files hide from the run, why `ci-signal` green is not merge clearance, and why you read a failing lint's OFFENDER LIST rather than its count."
---

# nexus.ci-triage — is `dev` broken, or is it me?

TRIGGER when: a PR's CI is red and you have not yet established whose
red it is; you are about to read your own diff looking for the cause;
you are about to run a suite "at the base" to compare; a lint has gone
red and you are counting its output lines.

The rule this skill exists to enforce lives in the workspace
`CLAUDE.md` under "When CI goes red"; this is the recipe and the
measured detail behind it.

## First move, before you read your own diff

CI builds the **merge ref**, so every open PR inherits whatever is
broken on the base. A red at your head is a claim about `base + yours`;
it says nothing about the part you did not vary. Hold your diff
constant, vary the base, and the question answers itself.

```zsh
WT=$(mktemp -u -d /tmp/devcheck.XXXXXX)                       # UNIQUE per caller — never a fixed path
git worktree add --detach "$WT" origin/dev || return 1        # CHECK THE RC — see below
bash "$WT"/monitor/watcher/test-<the-failing-suite>.sh < /dev/null
git worktree remove --force "$WT"
```

### The path is unique and the rc is checked, and both are load-bearing

`<your-org>/nexus-code#1215`. This recipe once named `/tmp/devcheck`
literally, and **a fixed path in guidance that many agents read is a
coupling mechanism** — it re-couples exactly the agents the
clone-isolation rule just separated. Measured, two repos and one fixed
path:

    agent 1: git worktree add --detach /tmp/devcheck  -> rc 0, tree created
    agent 2: git worktree add --detach /tmp/devcheck  -> rc 128 "already exists"
    agent 2: bash /tmp/devcheck/…/test-X.sh           -> ran AGENT ONE's TREE

`git worktree add` does NOT silently clobber — it REFUSES, loudly, at rc
128. That is why this is not the same defect as an `rsync` into a shared
directory, and it is also exactly why it bit: the recipe was three lines
with **no rc check anywhere**, so the loud failure went unread and the
next line measured another agent's tree at another agent's ref. The
status that matters is not the status anything tests.

The DIRECTION is the worst available for a recipe whose entire purpose
is to answer *"is `dev` broken, or is it me?"*: a wrong answer sends a
worker into another agent's code, which is the outcome the recipe exists
to prevent. (A foreign repo cannot destroy the owner's worktree —
`git worktree remove` from the wrong repo refuses at rc 128, *"is not a
working tree"* — so the cleanup line is safe; it is the measurement that
is not.)

**The general rule, worth more than the fix:** any path a piece of
guidance hands to EVERY reader must be unique per caller, or the
guidance is a coupling mechanism. Isolation that stops at the repository
boundary is not isolation. Banners, READMEs and `CLAUDE.md` snippets are
precisely the surfaces that get copied into many briefs at once.

### A worktree, NOT `git checkout origin/dev`

Not a style preference. Checking `dev` out in the main clone is the
operation the workspace `CLAUDE.md` bans, because the watcher sources
its helpers once at startup and a swapped-out `monitor/watcher/_*.sh`
breaks `snapshot_github` SILENTLY. A worktree also needs no stash, which
removes a second failure: `git stash -u` on a CLEAN tree creates no
entry, so a closing `git stash pop` exits 1.

If you only need to READ a file at another ref rather than run a suite,
`git show "${ref}:${path}"` is cheaper and touches nothing — braced, per
the zsh history-modifier entry.

### `git worktree add` has no `-q` on every git — state the BOUNDARY

Measured across every git installed on the reporting host: `-q` is
rejected ONLY at **2.17.1** (exit 129, and NO worktree is created); it
is accepted at 2.23.0, 2.28.0, 2.32.0, 2.33.1, 2.36.0 and 2.38.1. Say
the boundary rather than the bare fact — passing it under a loaded
`git/2.2x+` module creates the worktree silently, and a reader who hits
that concludes the guidance is wrong, which is worse than no guidance
because it discredits its neighbours.

Which way that cuts: CI's runner has a newer git, so **CI cannot catch
this**, and a suite asserting the rejection unconditionally would be
green on one host and red everywhere else.

## The remedy narrows the tested population

`<your-org>/nexus-code#1150`. A worktree contains neither GITIGNORED nor
UNTRACKED files, so the population you test is not the population your
suite runs against at home, and nothing errors. Measured on git 2.17.1,
a planted repo with one file of each kind at the SAME commit:
`tracked.txt` `clone=YES worktree=YES`; a gitignored
`reports/ignored_fixture.txt` `clone=YES worktree=NO`; an untracked
`untracked_fixture.txt` `clone=YES worktree=NO`.

The `WORKTREE-BLIND-SPOT` block in `CLAUDE.md` carries the guard and the
positive control. Run them BEFORE you read any absence — this is not
ceremony. `#1150`'s own author passed a `-q` that does not exist at that
host's default git, so the worktree was never created and both probes
duly reported the files "absent" from a directory that did not exist: a
perfect false zero, produced while writing up false zeroes, caught only
by a HEAD cross-check. It reproduced while the entry was being drafted,
from a different mistake with an identical signature (a fixture whose
`git commit` never ran) — the TRACKED positive control then read
`clone=YES worktree=NO` too, which is exactly what a positive control is
for and the only reason the run was thrown away rather than believed.

### The witness pair, and why it is a pair

One test is fixture-marked against a GITIGNORED data directory and SKIPS
in a worktree, so a real regression there is unobservable. A second
FAILS only in a worktree, for want of UNTRACKED vendored assets. One
gitignored, one untracked, opposite directions — which is what stops
*"just add the data"* being a rebuttal. (The two node IDs are on
`#1150`; they name tests in another project.)

**The dangerous direction is the SKIP, not the failure.** A
fixture-gated test whose data is gitignored skips in BOTH arms, so it
cannot fail at base and cannot be seen to STOP failing — it leaves the
population rather than turning red, and its absence reads as stability.

### A matching total is not evidence

Same repo, same ref, two instruments: `45P/70F/4S/11E` in a worktree
against `48P/70F/1S/11E` in a clone — the F column MATCHES while
membership differs by one each way, one test swapped out and one swapped
in. A reader comparing totals concludes stability and stops; that
reading was published and corrected. **Diff the failing-ID SETS.** It is
the repo's own *"a number that reconciles because its errors cancel is
not verified"* rule arriving in the verification INSTRUMENT rather than
in the code under test.

### The HEAD guard is necessary and NOT sufficient

`<your-org>/nexus-code#1228`. A worktree carrying a LEFTOVER MUTATION
PLANT passes it — found by an agent in its OWN verification worktrees:
two carried unreverted plants from a run lost to a session limit, `HEAD`
matched, the guard passed, and the trees were not the ref. The DIRECTION
is what makes it expensive rather than merely possible: **a leftover
plant pushes toward KEEP-OPEN, and KEEP-OPEN is the prior.** An error
that disagrees with your expectation gets investigated; one that agrees
with it gets published.

`#1228` proposed `git -C WT rev-parse 'HEAD^{tree}'` as the better
remedy. Measured, it is the WEAKER one and does not catch the reported
case. Four plants, one fixture, git 2.17.1:

| plant in WT | `HEAD` equal | `HEAD^{tree}` equal | `status --porcelain` | …`--ignored` |
|---|---|---|---|---|
| uncommitted edit | passes | **passes** | FIRES | FIRES |
| committed | FIRES | FIRES | passes | passes |
| into a GITIGNORED path | passes | passes | **passes** | **FIRES** |
| empty commit, same tree | FIRES | passes | passes | passes |

`HEAD^{tree}` is a pure function of `HEAD`, so wherever `HEAD` matches
its tree matches **by construction** — it can add nothing to a HEAD
check, and row 4 shows it is strictly more PERMISSIVE. The line that
earns its place is `status --porcelain --ignored` **in the WORKTREE**,
which asks a different question from `--ignored` in the SOURCE tree. Row
3 is the one to fear: a plant into a gitignored fixture or `reports/`
path is invisible to `HEAD`, to the tree object, AND to a plain
`status --porcelain` — and gitignored data is exactly what this section
is otherwise about.

**So:** if the suite you are about to run has fixture-gated or
asset-dependent tests, run it in a fresh CLONE and copy the gitignored
data in — or say plainly that those rows are unmeasured.

## Inheriting a red is the NORMAL case

Measured, 2026-08-08, three-for-three on one night:

| red at my head | `dev` in isolation | whose |
|---|---|---|
| `test-early-exit-reader-manifest.sh` | green | **mine** — a new `\| head` under `pipefail` |
| `test-ambient-shell-option-scope.sh` | **red** (49/1) | `#823`'s broadened recogniser |
| `test-summary-honesty-manifest.sh` | **red** | `#827`'s three unrecorded suites |

Two of three were inherited, and reading the diff first would have sent
a worker into another agent's code both times.

That night was not special. `<your-org>/nexus-code#829` is a `dev-red
hotfix` opening "`dev` has been RED on `tests` since `5feba193` (the
`#823` merge) — **six of six** unit-suite bands"; `#841` is a second,
independent `dev-red hotfix`, for `#827`'s three unrecorded suites.
Every PR open across either window inherited a red it did not cause. The
point is not the count, which keeps growing — it is that checking the
base first is the DEFAULT move rather than a last resort.

## Two corollaries that cost real time

- **`ci-signal` green is NOT merge clearance, and this is observed, not
  asserted.** At head `18ec3dca`, `ci-signal` concluded `success` while
  `tests` concluded `failure` in the same run set. Enumerate the bands
  independently; `ci-signal`'s own log says it is not a clearance.
- **Do not enumerate the bands by hand — `ng ci-attempts <sha|branch|PR#>`
  exists for it.** `gh run list` and the check-runs API return only the LATEST
  attempt, so a band that concluded `failure` and was re-run to `success` at the
  SAME sha is byte-identical to one that passed first time. Its exit vocabulary
  is wider than the four you will meet most — read `monitor/ci-head-attempts.sh`'s
  own header rather than this sentence — but those four are `0` first-pass green,
  `5` a live red, `6` a green that REPLACED a red at the same sha, and, given a
  PR number, `4` for a band that should have gated the change and carries NO
  verdict, including the partial case where every run that DID happen is green.
  `3` is the one that is not a verdict at all: still running.
  It also prints, in its `Merge-ref base: VERIFIED` block, the full
  base sha the green was computed against (`monitor/_merge_ref_base.sh`), which
  is what `ng pr merge --base-sha` consumes: a green is a claim about a
  base+head PAIR, and the base half is the half that moves under you.
- **A failing lint names its offenders — read the LIST, not the count.**
  `test-ambient-shell-option-scope` printed three paths; two were its
  own planted positive-control FIXTURES and one was the real tree
  offender. Counting them made one problem look like three.
  Independently hit and written up by a different worker on a different
  night (`#829`, "exactly ONE test file, exactly ONE assertion, exactly
  ONE real-tree offender"). Same lint, same trap, twice.

## Reading a job log

Read it with `gh api repos/O/R/actions/jobs/<id>/logs`, never
`gh run view --job <id> --log`, on ANY client — the latter IGNORES the
job id and serves the run's LATEST attempt. Client-version detail and
the two corollaries for briefs: `skills/nexus.bot/SKILL.md`.

## See also

- `CLAUDE.md` "When CI goes red" — the rule and the executed
  `WORKTREE-BLIND-SPOT` block.
- `skills/nexus.claims/SKILL.md` — a red is a claim about the tree you
  tested, exactly as a zero is a claim about the population you
  searched.
- `skills/nexus.self-fix/SKILL.md` — `ng guards-for-diff`, and filing on
  `<your-org>/nexus-code`.
