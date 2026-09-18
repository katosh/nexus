# Development

Hacking on `nexus-code` itself — orchestrator, watcher, `ng`,
skills, monitor scripts.

!!! tip "Read this first if you are writing a check"

    [Design guidelines](design-guidelines.md) states the one defect
    class that dominates this repo — a check asserting a **proxy** for
    the property it claims, failing toward a well-formed answer at
    rc 0 — and indexes the executable doctrine that enforces it. Most
    of the machinery on this page and in [Tests](tests.md) exists
    because of it.

## Prerequisites

The same prerequisites the [Install](../getting-started/install.md)
guide names plus the bits you need for editing:

- A working nexus instance you can break without breaking a
  production one. Either run dev work in a fresh, throwaway
  clone (recommended) or know which clone the live watcher
  is sourcing from (so you don't break it — see
  [Watcher isolation](#watcher-isolation) below).
- `git` ≥ 2.30 (for `git worktree`).
- `bash` ≥ 4 — most of the shell code uses bash arrays and
  associative arrays.
- `jq` ≥ 1.6 for JSON parsing in `ng` and the watcher.
- [`uv`](https://github.com/astral-sh/uv) for Python-side
  dependency management. The docs site build uses
  `uv pip install -r docs/requirements.txt`; plain `pip`
  works too but is markedly slower and inside `agent-sandbox`
  the wrapped `/app/bin/pip` can hang for minutes.

## Repository layout

```
monitor/            # the runtime: watcher loop, ng CLI, agent prompt
  ng                # the operator-facing CLI verb dispatcher
  spawn-worker.sh   # injects the worker floor + launches tmux
  watcher/          # the polling loop and its helper modules
    main.sh         # entry point that sources the helpers
    _lib.sh         # generic helpers (paste, diff classification, …)
    _github.sh      # GraphQL/REST surface with rate-limit gate
    _deliveries.sh  # webhook-deliveries event surface
    _mentions.sh    # mentions:<user> search fallback surface
    _idle_probe.sh  # idle-worker classifier
    _unstick.sh     # auto-unstick paths (case A/B/C)
    test-*.sh       # the test suite (see contributing/tests.md)
config/             # nexus.yml schema + loader
docs/               # this site (mkdocs-material)
skills/nexus.*/     # SKILL.md files Claude Code discovers at runtime
reports/            # local-only; gitignored, blocked by CI
work/               # local-only; per-project checkouts
```

The runtime **MUST** remain plain bash with `gh`, `jq`, `curl`, and
`tmux`. It **MUST NOT** acquire a Python service, a daemon, or an
embedded database (SQLite included): state **MUST** live in
`monitor/.state/` as flat files — JSONL action log, last-snapshot
hash files, dedup sets, lock directories.

This is an invariant, not a description of how things happen to be.
The runtime is inspectable with `cat` and repairable with `rm`,
recoverable from a half-written file, and free of a process whose
death is a separate failure mode from the watcher's. A change that
introduces any of the three is an architecture change and needs to
be argued as one, not landed as an implementation detail. Python is
fine as a *tool* invoked and exited (`monitor/lint-workflows.py`,
`monitor/usage-report.py`); it is the long-lived service that is
excluded.

## Branches and commits

Pick a topic-prefixed branch name — the convention so far is
`<handle>/<short-slug>`, e.g. `alice/ng-wrap-up-target-pane`
or `bob/dashboard-cache`. CI runs from any branch; only `main`
deploys the docs site to GitHub Pages.

Commit messages are conventional-ish but not strict. The pattern
that has emerged from `git log`:

- `fix(<area>): <imperative>` — one-line bug fix.
- `<area>: <imperative>` — feature or refactor (no `feat:`
  prefix in practice).
- `docs: <imperative>` — documentation only.
- `ci: <imperative>` — `.github/workflows/` changes.

Wrap PR titles ≤ 70 characters; put detail in the body. The PR
body should explain *why* the change exists and what would surprise
a reviewer. The diff already explains what changed.

## Worktrees vs fresh clones

Two independent agents on the same `work/<project>` will clobber
each other unless they operate on separate working trees. The
workspace contract calls this out under "Independent clones for
parallel work" — the same rule applies when you, the human, are
editing alongside a running worker.

Two paths, picked on isolation needs:

- **Fresh clone** — `git clone git@github.com:<your-org>/nexus-code.git
  work/nexus-code-<task>/`. Separate `.git`, separate working tree,
  separate index. Use this when the task touches data the running
  nexus reads, or when you want a guaranteed-clean remote checkout.
- **Worktree** — `git worktree add ../nexus-code-<task>
  -b <handle>/<task>`. Lighter; the `.git` dir is shared with the
  primary clone but the working tree and branch are separate.
  Default choice for code-only edits that don't touch shared state.

A worktree directory under `work/` is gitignored from the primary
clone, so you can park them next to project checkouts without
polluting `git status`.

## Watcher isolation

> **This is the load-bearing rule for nexus-code development.**

Never `git checkout <branch>` on a clone whose watcher is
running. The watcher (`monitor/watcher/main.sh`) sources its
helper modules — `_lib.sh`, `_github.sh`, `_deliveries.sh`,
`_mentions.sh`, `_idle_probe.sh`, `_unstick.sh` — exactly once
at startup. If a checkout swaps those files for versions with
diverged function signatures, the long-running shell still has
the old definitions in memory but calls the new versions on
disk; arity mismatches surface as silent failures (jq parse
errors, empty arrays, exit-1 from sub-functions) that the
watcher's outer loop swallows. Eligible comments stop being
surfaced, no error appears in the log, and the only symptom is
"the orchestrator went quiet".

Mechanism, restated:

1. The watcher source-loads each helper at startup.
2. Functions live in the shell's memory; helper-file definitions
   live on disk.
3. Some helpers (notably `_github.sh`) call other helpers
   defined in the same load. When the on-disk file changes,
   the in-memory caller dispatches to a different on-disk
   version.
4. Bash function calls don't validate arity, so the wrong
   version returns garbage or errors that the outer loop
   treats as "no eligible comments this cycle".

The rule, in two operational forms:

- **Watcher-touching work needs a separate clone.** Anything
  that edits `monitor/watcher/_*.sh` (or `main.sh`, or anything
  the watcher source-loads transitively) MUST land in a fresh
  clone or a dedicated worktree. Operate there, push your branch,
  open a PR.
- **After a watcher-affecting change merges to `main`,**
  `git pull` the primary clone. The running watcher is
  version-aware (issue `#186`): it detects that its on-disk
  source set drifted and self-restarts within roughly a minute —
  no manual restart (see
  [Operating → Upgrading](../operating/upgrading.md)).

A manual `monitor/svc.sh restart watcher` is needed only when the
auto-restart is disabled (`monitor.version_restart.enabled:
false`), the running watcher predates the version-aware module
(the bootstrap caveat), or you can't wait for the settle window —
and then always pull first, since `main.sh` sources module files
that must exist on disk.

## GitHub identity during development

The `nexus.bot` rule still applies when you're hacking on the
code: any PR, issue, or comment posted *by a worker* runs as
the bot. PRs you push yourself from your own checkout sign as
you — `git commit` and `git push` are the only operations that
use your identity. `gh pr create` from inside a spawned worker
should be `GH_TOKEN=$(./monitor/mint-token.sh) gh pr create` or
`monitor/ng pr create` so the open notification routes back to
you instead of being silenced by GitHub's
"you don't notify yourself" rule.

When you're driving manually from a terminal, plain `gh` is
fine — you're the one writing, you don't need a notification.

## Running the test suite

`monitor/watcher/test-*.sh` is the existing suite. Run it through
the runner, which discovers the set and executes each file as its
own process:

```bash
bash monitor/watcher/run-tests.sh
```

**You MUST NOT run the suite as `bash monitor/watcher/test-*.sh`.**
The shell expands the glob before `bash` sees it, so `bash` gets the
FIRST file as its script and every other file as a positional
argument — the rest never execute, and the run exits **0**. Measured
on three trivial fixtures:

```text
$ bash test-*.sh
RAN test-a.sh with args: test-b.sh test-c.sh
rc=0
```

One of three ran; the two that did not are indistinguishable from
two that passed. This is the repo's dominant defect class in a
command line: a well-formed answer at rc 0 over a population that
is not the one you asked about. [Tests](tests.md) states the same
rule from the runner's side.

Each file is self-contained — no shared fixtures, no test
framework — and prints `ALL TESTS PASSED` on success. See
[Tests](tests.md) for the per-file scope and the failure-mode
patterns to follow when you add a new test, and
[Design guidelines](design-guidelines.md) for the class of defect
those patterns exist to catch.

## Editing the docs site

The site is mkdocs-material; pages live under `docs/` and the
nav is in `mkdocs.yml`. To preview locally:

```bash
uv venv .venv-docs
source .venv-docs/bin/activate
uv pip install -r docs/requirements.txt
mkdocs serve -a 127.0.0.1:8000
```

Before pushing, run `mkdocs build --strict` — the same command
CI runs via `.github/workflows/docs.yml`. Strict mode fails on
broken cross-links, missing nav entries, and broken admonitions,
which are the most common ways a docs PR breaks the deploy.

`mkdocs gh-deploy` pushes the rendered site to `gh-pages`; CI
does this automatically on every push to `main`. Don't deploy
from your laptop — the version that lands is whichever ran
last, and you can race the workflow.

## CI checks

Workflows that fire on PRs:

- **`ci-signal.yml`** — runs on **every** PR into **every**
  base, with no `branches:` and no `paths:` filter. See
  "Zero checks is not green" below; it is the reason that
  section exists.
- **`tests.yml`** — `bash -n` over every `monitor/**/*.sh`, then
  the unit suite across a login-shell matrix (bash and zsh, both
  at `--jobs 4`), a `NEXUS_ROOT`-unset leg, a `NEXUS_ROOT`-exported
  leg, a tmux-version matrix, and a bash 4.4 leg. Fires on PRs into
  `main`/`dev`, and on pushes to them, touching **`monitor/**`,
  `config/**`, `.github/workflows/**`, `CLAUDE.md`, or
  `skills/**`** — the last three because this suite *executes* those
  files as fixtures, so a guard that did not list them would be
  blind to the files it guards. The `paths:` list in the workflow is
  canonical; each entry carries the issue that added it.
- **`cc-harness.yml`** — the real Claude Code binary against
  the mock backend, on PRs touching the harness surface.
- **`docs.yml`** — builds the docs with `mkdocs build --strict`
  and (on `main` only) deploys to `gh-pages`. Fires on any PR
  that touches `docs/`, `mkdocs.yml`, or the workflow itself.
- **`check-no-reports-leaked.yml`** — fails any PR that adds
  files under `reports/` except `reports/.gitignore`. `reports/`
  is local-only; agents upload to the asset repo via
  `monitor/ng upload`. The guard exists because exactly one
  stray report has been committed in the past.
- **`tests-slow-integration.yml`** — two jobs, split by cost. The
  cheap half, **`SLOW band vs enumerated tolerance`**, runs the
  `SLOW_TESTS=1` scenarios (no integration suite) on every PR and push
  touching `monitor/**`, `config/**` or the workflow itself, and it
  **blocks** — its verdict is a diff against the tolerated-red ledger
  `monitor/slow-band-known-red.tsv` via `monitor/slow-band-drift.sh`. The expensive half, **`SLOW +
  integration band (scheduled)`**, runs the full suite with both gates
  on, nightly (`cron: '0 7 * * *'`) plus `workflow_dispatch`, and does
  not gate a PR. See [Tests](tests.md#slow--integration-band).
- **`conflict-markers.yml`** — refuses a PR carrying leftover merge
  conflict markers. Like `ci-signal.yml` it carries **no `paths:` and no
  `branches:` filter**, deliberately: a marker can land in any tracked
  byte, and the one that reached `dev` landed in `CHANGELOG.md`, which
  matches no other workflow's `paths:` (<your-org>/nexus-code#774). Its
  `pull_request` leg checks out the merge preview, so it also reddens a
  PR that would merge *into* a dirty base.

### Zero checks is not green

`on: pull_request: branches: [main, dev]` filters the PR's
**base** branch, not its head. A PR whose base is a *feature*
branch therefore matches no filtered workflow and collects
**zero checks** — and GitHub renders that identically to
all-green: `gh pr view` reports `MERGEABLE` with an empty
`statusCheckRollup`, and the merge button shows no red and
nothing to click past. `<your-org>/nexus-code#593` sat in exactly
that state and was caught only because a human noticed its check
count looked unlike its neighbours'.

`ci-signal.yml` closes this. It runs on every PR regardless of
base or paths, recomputes from the workflow files which
workflows *should* have gated your change, and goes RED naming
any that did not run. Two verdicts, two remedies:

- **`TRIGGER-GAP`** — a workflow's paths match your files but
  its `branches:` excludes your base. Retarget onto `dev`, or
  dispatch the workflow on your head ref.
- **`MISSING-RUN`** — everything matched and GitHub still
  recorded no run. Nothing about the PR explains it; look at
  Actions.

**Retargeting a PR does not, by itself, re-run CI.** Changing a
PR's base emits only the `edited` event — never `synchronize` —
so a workflow whose `types:` omit `edited` keeps whatever
verdict it had on the old base, including no verdict at all.
This repo's gating workflows now list `edited` and gate their
jobs on the base having actually changed, so a retarget *does*
fire them. If you are looking at a workflow elsewhere that does
not, the escape hatch is:

```sh
gh workflow run tests.yml --repo <your-org>/nexus-code --ref <your-branch>
```

`ci-signal` counts a `workflow_dispatch` run as signal, because
the question it asks is whether the code was tested, not by
which event.

Prefer not to stack PRs on feature branches at all: once a base
lands in `dev`, retarget the child onto `dev`. A stale stack
base produces a confusing diff *and* opts the PR out of CI.

## Conventions

- **No `--no-verify` on `git commit`.** Hooks fail for a reason.
  If a hook trips, fix the underlying issue and re-commit.
- **No `git push --force` to a *shared* branch** — `dev`, `main`,
  or any branch someone else has pushed commits to. Force-pushing
  there rewrites public history.

  Force-pushing your **own** PR branch is a different act and is
  **expected**: the merge gate requires the branch be rebased onto
  the current base before merge, and a rebase makes the push
  non-fast-forward. A `pull_request` run is computed against a
  merge ref built at **run creation**; if the base moves
  afterwards, a later green describes a tree that no longer
  exists, and `rerun-failed-jobs` reuses that same stale ref.
  **The merge ref is demand-triggered**, which was established by
  experiment and overturned the earlier belief that "only a new head
  re-evaluates". `refs/pull/N/merge` is recomputed when something asks
  GitHub for the PR's mergeability, and not otherwise — measured, two
  refs sat stale for 26 and 36 hours across many base advances, while
  one refreshed within two minutes of a single `GET /pulls/{n}` and an
  untouched control did not move. That is a model with a measured
  exception, not a mechanism: a `GET` has been seen to refresh
  `mergeable` while the ref's base stayed put (n=2), and what actually
  triggers the rebase is not established — see `monitor/_merge_ref_base.sh`
  and <your-org>/nexus-code#923 before leaning on "one GET refreshes it".

  So: "it has been a while, it must have refreshed" is false. And
  **querying the PR refreshes it — the act of checking changes what you
  are checking.** Do not read a green, then query the PR, then assume
  the green describes what you just queried. Query first, then create a
  new run, then enumerate that run.

  **Check it; do not assume it.** One command, which fetches and
  compares in a single step and fails **closed**:

  ```bash
  bash monitor/force-push-check.sh <the same args you'll give git push>
  ```

  It runs `git push --dry-run --porcelain --force` and reads back which
  refs would move on which remote, so **the answer comes from git's own
  resolution rather than a model of it**. That matters because this check
  produced four false clearances on four separate axes while it tried to
  derive the push target by hand — authorship, empty-means-safe, the
  wrong ref (`HEAD` is not what a push moves), and the wrong remote
  (`remote.pushDefault` / `branch.<n>.pushRemote`). Each fix closed one
  axis and exposed the next, because git's push-target resolution has
  more surface than anyone enumerates in advance.

  Residual, stated rather than left to be discovered: the verdict is
  TOCTOU (someone can push in the gap), it needs the network (an
  unreachable remote is REFUSED, never a pass), server-side hooks are not
  consulted (errs safe — a rejected push destroys nothing), and it
  reports what a plain `--force` would do, so a real
  `--force-with-lease` may be refused where this said UNSAFE — never the
  reverse.

  ```text
  0  SAFE     the remote branch is fully contained in your HEAD
  1  UNSAFE   commits on the remote you would DESTROY — they are listed
  2  REFUSED  could not check (fetch failed, no such remote) — NOT a clearance
  3  NO SUCH REMOTE BRANCH — nothing to overwrite, and nothing compared
  ```

  **Do not hand-roll it as `git fetch` + `git log`.** Three different
  states print *empty* there — the branch is not on the remote yet, the
  fetch **failed**, or the tracking ref is stale because the fetch was
  skipped — and under "anything listed is a commit you would destroy",
  empty reads as a clearance. The first two are byte-identical at the
  terminal: same empty stdout, same `rc 128`, same stderr shape. So the
  failure renders exactly like the all-clear, for the reader on a flaky
  network who is about to force-push.

  **Authorship is the wrong axis entirely.** Every agent here commits
  with the *operator's* identity (the worker floor mandates it), so
  `git log --format='%an' … | sort -u` returns one name no matter who
  else pushed. Measured on a two-agent branch, that false clearance
  destroyed the sibling's commit — and **`--force-with-lease` did not
  backstop it**, because its lease is satisfied by the very `git fetch`
  that rebasing onto current `dev` requires. Pin the lease explicitly
  if you want it to bite:

  ```bash
  git push --force-with-lease=<branch>:<sha-you-saw-before-fetching>
  ```
- **Don't commit `reports/*.md` or `monitor/.state/*`.** Both
  are gitignored; the CI guard above catches the reports case.
- **`#N` in a comment auto-links** to an issue or PR in the
  current repo. In Markdown intended for GitHub (PR bodies,
  issue comments, the dashboard), wrap a literal hash-N in
  backticks (`` `#13` ``) unless you actually want the link.
  In docs site Markdown the auto-link doesn't fire, but the
  same backtick treatment is friendlier when the content gets
  copied back to a PR description.
- **`git checkout <ref> -- <path>`** silently overwrites the
  working tree. For a read-only peek at content at another
  ref, use `git show <ref>:<path>`.
