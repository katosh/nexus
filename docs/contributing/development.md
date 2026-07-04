# Development

Hacking on `nexus-code` itself — orchestrator, watcher, `ng`,
skills, monitor scripts.

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

The runtime is plain bash with `gh`, `jq`, `curl`, and `tmux`.
There is no Python service, no daemon, no SQLite — state lives
in `monitor/.state/` as flat files (JSONL action log, last-snapshot
hash files, dedup sets, lock directories).

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

`monitor/watcher/test-*.sh` is the existing suite. Run all of
them with:

```bash
bash monitor/watcher/test-*.sh
```

Each file is self-contained — no shared fixtures, no test
framework — and prints `ALL TESTS PASSED` on success. See
[Tests](tests.md) for the per-file scope and the failure-mode
patterns to follow when you add a new test.

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

Two workflows currently fire on PRs:

- **`docs.yml`** — builds the docs with `mkdocs build --strict`
  and (on `main` only) deploys to `gh-pages`. Fires on any PR
  that touches `docs/`, `mkdocs.yml`, or the workflow itself.
- **`check-no-reports-leaked.yml`** — fails any PR that adds
  files under `reports/` except `reports/.gitignore`. `reports/`
  is local-only; agents upload to the asset repo via
  `monitor/ng upload`. The guard exists because exactly one
  stray report has been committed in the past.

There is no test workflow yet — the bash test suite runs
locally only. Adding `bash monitor/watcher/test-*.sh` to CI is
on the wish list; the blocker is that one of the tests
(`test-respawn-loop-integration.sh`) needs `tmux` on PATH and
takes 15–30 s wall-clock, so it needs a dedicated job.

## Conventions

- **No `--no-verify` on `git commit`. No `git push --force`.**
  Hooks fail for a reason; force-pushing rewrites public
  history. If a hook trips, fix the underlying issue and
  re-commit.
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
