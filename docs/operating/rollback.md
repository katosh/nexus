# Rolling back a promotion

What to do when a `dev` -> `main` promotion turns out to have shipped
a defect, and how to leave `main` in a state the other operators can
still pull.

This page exists because `nexus-code` had no rollback procedure
anywhere in the repo at the time of the 2026-08-28 promotion, and a
promotion without a written way back is a one-way door.

**Every command on this page has been executed against a throwaway
bare origin, not composed.** That is not a style note: the first draft
of the re-merge step below was wrong in a way that reads perfectly and
silently does nothing, and only running it surfaced that. A rollback
procedure is reached for when something has already gone wrong, so a
step that fails quietly here costs more than it would anywhere else.

## The shape of the problem

`nexus-code` ships as a rolling `main`
([Contributing -> Release](../contributing/release.md)): every
operator clones it directly and pulls when they want to. Two
consequences decide everything below.

- **Other people's clones are the real state.** Once an operator has
  pulled, their local `main` contains the commits. Rewriting the
  remote does not rewrite theirs; it only guarantees their next pull
  conflicts.
- **`git log` since the last pull is the upgrade summary.** Anything
  that flattens or dangles that history — a squash, a rebase, a
  force-push — destroys the one artefact operators use to see what
  changed. This is also why a promotion is a merge commit and never a
  squash.

## Before you promote: the anchor

Tag `main` at its pre-merge tip **and push the tag**, before the merge
exists. The tag is the only thing that makes the rollback a
single-command operation instead of an archaeology exercise.

```bash
git fetch origin
git tag -a pre-dev-promotion-<YYYY-MM-DD> origin/main \
    -m "main tip before the dev -> main promotion of <YYYY-MM-DD>"
git push origin pre-dev-promotion-<YYYY-MM-DD>
```

Verify it landed on the remote, not just locally — a local tag is not
an anchor:

```bash
gh api repos/<your-org>/nexus-code/tags --jq '.[].name'
```

## Path A — revert the merge (the default)

**Use this whenever anyone might already have pulled.** It is
forward-only: it adds a commit rather than rewriting history, so every
downstream clone converges with an ordinary `git pull` and nobody's
tree breaks.

```bash
git fetch origin
git checkout -b rollback-<YYYY-MM-DD> origin/main
git revert -m 1 <merge-commit-sha>
git push -u origin rollback-<YYYY-MM-DD>
```

Then open a PR to `main` and merge it. `-m 1` means "keep the first
parent" — the `main` side — which is what discards the `dev` changes.

**Tell the operators.** They are the reason you chose this path; a
rollback they do not know about is a rollback that reaches them as a
mystery behaviour change.

### The trap: reverting a merge poisons the re-merge

This is the part that bites, and it bites later, when the fix is ready.

A reverted merge is still, to git, a merge that happened. The commits
are in `main`'s ancestry. So when you fix the defect on `dev` and
merge `dev` -> `main` again, git computes a merge base that already
includes them and **does not bring them back** — you get the fix and
none of the original 1000 commits, silently, with no conflict.

The fix is to revert the revert on the way back in:

**Branch from `origin/main`, not from `origin/dev`.** This is the
step to get right, and it is executed below rather than reasoned
about, because the wrong base fails in a way that looks like nothing
happened:

```bash
git checkout -b redo-promotion origin/main
git revert --no-edit <sha-of-the-revert-commit>
```

...then merge that branch. Do this deliberately and say so in the PR
body, or the next promotion will look like it worked and ship an empty
tree.

Branching from `origin/dev` instead — the intuitive choice, since `dev`
is what you are trying to restore — **does nothing at all**. The revert
you are reverting is not in `dev`'s history, so there is nothing there
to undo. Measured against a throwaway origin:

```
git checkout -b redo-promotion origin/dev
git revert --no-edit <revert-sha>
  -> rc 1, "nothing to commit, working tree clean"
  -> 0 commits created; the branch is byte-identical to origin/dev
```

`git revert` exits **1** and creates **no commit**. If you do not check
the exit status — and it is one command in the middle of a recovery
you are already unhappy about — you merge a branch that is just `dev`,
which is exactly the empty re-merge this section exists to prevent.

Verify before merging:

```bash
git diff --stat "origin/main...redo-promotion"
```

An empty or implausibly small diff is the symptom.

**Use the three-dot form, and do not substitute two dots.** They answer
different questions here and only one of them catches the failure
above. Measured on the same fixture, after a Path A rollback:

```
git diff --stat origin/main...redo-promotion   # THREE dots -> empty. Correct: catches it.
git diff --stat origin/main..redo-promotion    # TWO dots  -> "3 files changed, 3 insertions(+), 2 deletions(-)"
```

Three-dot diffs from the merge base, which after a rollback *is* the
`dev` tip, so a do-nothing `redo-promotion` correctly shows empty. Two-dot
diffs the endpoints directly and reports a plausible, non-empty
changeset for a branch that contains none of your work — a number that
reads as success. Both remain wrong-looking-right after an asset commit
lands on `main`, which was also measured: the merge base does not move,
so three-dot stays empty and two-dot stays plausible.

## Path B — reset and force-push (narrow window only)

**Only when all three hold**, and you can state why each does:

1. The merge is minutes old.
2. No other operator has pulled since. On this repo that means you have
   actually asked them, not that you assume it — `<your-org>/<other-nexus>`
   and `<your-org>/<other-nexus>` both track `main`.
3. No commit has landed on `main` after the merge, including bot asset
   uploads. `upload-asset.sh` pushes to `main` on its own schedule, so
   check rather than assume:

```bash
git fetch origin
git log --oneline <merge-commit-sha>..origin/main
```

If that prints anything, Path B is already wrong — use Path A.

```bash
git push origin "+pre-dev-promotion-<YYYY-MM-DD>^{commit}:main"
```

The `+` is the force. Pushing the tag's commit rather than a local
branch avoids force-pushing whatever happens to be checked out.

**The quotes are load-bearing.** `^{commit}` is glob syntax to zsh,
which is this workspace's default shell, and an unquoted refspec dies
before `git` is ever invoked:

```
zsh -c 'setopt extendedglob; : anchor^{commit}:main'
  -> zsh:1: no matches found: anchor^{commit}:main
```

That one is at least loud. Quote it anyway.

**This is a force-push to a shared branch**, which the worker floor
otherwise forbids outright. It is listed second, and hedged, for that
reason: it leaves no trace that the promotion happened, and any clone
that pulled in the interval is now ahead of the remote in a way that
resolves badly. Prefer Path A unless the window is genuinely still
open.

## After either path

Verify the remote is where you think it is — from the remote, not from
your local refs, which your own push has already advanced:

```bash
git fetch origin
git log --oneline -3 origin/main
git rev-parse origin/main
```

Then:

- **Confirm the tree.** `git diff --stat pre-dev-promotion-<date> origin/main`
  should show only what you expect (after Path B: nothing outside
  `assets/`).
- **Restart the watcher on any clone that pulled the bad code.** The
  version-aware watcher self-restarts on source drift within about a
  minute ([Upgrading](upgrading.md)), so a rollback pull is picked up
  the same way an upgrade is. Confirm with
  `monitor/ng watcher-status` and `monitor/svc.sh status`.
- **Say what happened on the promotion issue or PR**, including which
  path you took and why. The next person to promote reads that thread
  to decide whether to trust the procedure.
- **Keep the tag.** It costs nothing and it is the anchor for the
  re-promotion.

## What a rollback does not fix

Agent sessions already running keep the code they started with; so
does any worker mid-flight. Neither is restarted by a rollback, by
design. If the defect is in `monitor/spawn-worker.sh` or the worker
floor, in-flight workers stay affected until they finish.
