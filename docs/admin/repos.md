# Repos

Every nexus deployment uses **two repos**: a shared code repo and a
per-operator asset+issue repo. They serve different roles, have
different visibility, and almost never need to live together. This
page explains the split, what lives in each, and how to wire them up
for a new deployment.

## The two-repo topology

| Repo | Owner | Visibility | Holds | Bot installed? |
|---|---|---|---|---|
| **Code repo** (`<your-org>/nexus-code`) | The nexus-code maintainers | Public | The watcher, the orchestrator prompt, the `ng` CLI, the skills tree, this docs site | No — the bot does not need to be installed here to run a nexus. (It happens to be installed for maintainer convenience when opening PRs against the upstream code.) |
| **Asset+issue repo** (`<your-org>/<your-handle>-nexus-assets`) | You, the operator | Private (recommended) | The overview issue and per-thread issues, uploaded assets under `assets/`, the dashboard body | Yes — every operator installs their own GitHub App here. |

The code repo is **shared**; the asset+issue repo is **yours**.
The recommended pattern is one nexus per operator: each operator
clones `nexus-code`, runs their own watcher against their own
private asset+issue repo, and never sees other operators' state.
Each operator's writes flow through their own bot, surfacing on
their own phone via their own notification channels. Teams that
want to collaborate do so informally — see
[Collaboration patterns](#collaboration-patterns) below.

```
                          GitHub
   +-------------------------------------------------+
   |  <your-org>/nexus-code  (public, shared code)     |
   |  └─ docs/, monitor/, skills/, config/...        |
   |                                                 |
   |  <your-org>/<handle>-nexus-assets  (private)    |
   |  ├─ Issues:  overview + per-thread              |
   |  └─ main:    assets/{N}/..., assets/reports/... |
   +-------------------------------------------------+
                 ▲                       ▲
                 │ git clone (read)      │ App installed here
                 │                       │ — bot reads issues,
                 │                       │   patches dashboard,
                 │                       │   pushes assets
                 │                       │
   +-------------------------------------------------+
   |  Your host                                      |
   |  ~/<nexus>/  ← clone of <your-org>/nexus-code     |
   |    config/nexus.yml  (gitignored, per-operator) |
   |    assets/           (gitignored clone of the   |
   |                       asset+issue repo)         |
   +-------------------------------------------------+
```

## Why the split exists

### Separation of concerns

The code repo is implementation. The asset+issue repo is state. The
two evolve on different cadences:

- **Code** changes when the implementation gains a feature or fixes
  a bug. Every operator pulls. Reviews flow through PRs on
  `<your-org>/nexus-code`.
- **State** changes constantly during normal operation — every
  orchestration cycle writes to the dashboard, every worker uploads
  an asset, every comment thread grows. None of this should land in
  the shared code history.

Mixing the two means every `git pull` on the code carries unrelated
state changes, and every code release ships with one operator's
issue history. The split keeps both clean.

### Public/private boundary

The code repo is going **public**. The asset+issue repo stays
**private**. Reports, dashboard content, work-in-progress code
snippets, internal lab identifiers — none of it leaks into the
public surface, because none of it lives there.

If you uploaded an internal artefact to the code repo (e.g. an issue
template referencing a study), it would be visible to the world the
moment `nexus-code` flips to public. By placing every per-operator
artefact in your own private repo, the boundary is automatic.

### Forkability

A sibling lab wanting to run their own nexus does **not** fork the
asset+issue repo — that would inherit your issue history, your
dashboard, your reports. They clone `nexus-code` and create their
own asset+issue repo. The pattern scales by addition, not by
forking-and-mutating.

The convention for fork discoverability is the GitHub topic
`nexus-fork` on the asset+issue repo; see
[GitHub App → Cross-fork variant](github-app.md#cross-fork-variant).

## What lives in each repo

### Code repo (`<your-org>/nexus-code`)

Tracked content (everyone sees it):

- `monitor/` — the watcher and `ng` CLI
- `skills/` — agent-facing capability descriptors
- `config/nexus.example.yml` — the documented template
- `docs/` — this site
- `CLAUDE.md` — workspace contract for spawned agents
- `.github/workflows/` — CI guards, docs build

Notably **not** in the code repo:

- `config/nexus.yml` — gitignored; per-operator secrets and IDs.
- `reports/` — gitignored except for `reports/.gitignore` itself. A
  CI workflow (`check-no-reports-leaked.yml`) fails any PR that adds
  a file under `reports/` other than the `.gitignore`, after a stray
  report leaked in an early PR.
- `assets/` — gitignored; the local clone of your asset+issue repo
  lives here for the uploader's convenience.
- `~/.claude/...` — bot pem, token cache, webhook secret — host paths,
  not repo content.
- `work/*/` — gitignored; per-project working checkouts.

### Asset+issue repo (e.g. `<your-org>/<your-handle>-nexus-assets`)

The bot owns this repo's `main` branch and its issue tracker:

- **Issues tracker** — the overview issue (labelled `nexus:overview`),
  per-thread work issues, decision issues.
- **`main` branch** — a flat `assets/` tree:

    | Path | Source | Printed URL shape |
    |---|---|---|
    | `assets/<N>/<basename>` | `ng upload --issue N <path>` | `.../raw/<sha>/assets/<N>/<basename>` for binaries, `.../blob/<sha>/...` for `.md`/`.ipynb` |
    | `assets/reports/<basename>` | `ng upload reports/<file>.md` (auto-routed) | `.../blob/<sha>/assets/reports/<basename>` |
    | `assets/general/<basename>` | `ng upload <path>` without `--issue` | `.../raw/<sha>/assets/general/<basename>` |

    Override placement with `--repo-path`. Every printed URL is pinned
    to the post-push SHA — subsequent overwrites at the same path
    don't change what a previously-shared URL resolves to.

The repo should not have any working code, README boilerplate, or
unrelated history. Standing one up fresh means **leave the new repo
completely empty** — no auto-generated README, no `.gitignore`, no
LICENSE. The first `monitor/upload-asset.sh` push creates the
`assets/...` tree and lands the initial commit.

## Standing up a new nexus

The full step-by-step lives in [Install](../getting-started/install.md);
this section is the repo-level summary so you can see the topology
before diving in. For first-time installs the recommended path is
the Claude-Code-driven bootstrap (`agent-sandbox tmux new-session
./monitor/bootstrap-install.sh`); the manual steps below match what
that bootstrap walks you through.

1. **Clone the code repo** (read access only is enough):

    ```bash
    git clone git@github.com:<your-org>/nexus-code.git nexus
    cd nexus
    ```

2. **Create your asset+issue repo** — empty, private:

    ```bash
    gh repo create <your-org>/<your-handle>-nexus-assets --private \
        --description "Asset + issue repo for my nexus deployment"
    ```

3. **Create your GitHub App** and install it on the asset+issue repo
   only — see [GitHub App](github-app.md).

4. **Point `config/nexus.yml` at your asset+issue repo**:

    ```yaml
    github:
      repo: <your-org>/<your-handle>-nexus-assets
      # asset_repo: defaults to `repo` if absent — leave commented.
    ```

5. **Bootstrap the overview issue**: label `nexus:overview`, title
   `Nexus`, body with the dashboard markers
   (`<!-- NEXUS_DASHBOARD_START -->` … `<!-- NEXUS_DASHBOARD_END -->`).
   See [GitHub App → First-time overview-issue setup](github-app.md#first-time-overview-issue-setup).

6. **Verify**: `./monitor/ng issue 1`, `./monitor/ng preflight "$(./config/load.sh github.repo)"`,
   `./monitor/ng upload README.md --message "preflight"`. All three
   should succeed before you launch the watcher.

## Branch protection and access

Recommended settings on the asset+issue repo:

- **Visibility: private.** Contains reports that may reference
  in-progress work, internal artefacts, and full agent dialogue.
- **Default branch: `main`.** The uploader pushes here directly; the
  bot is the only writer.
- **Branch protection on `main`**:
    - Allow direct pushes from the bot identity (`<bot-slug>[bot]`).
    - Discourage force-pushes (workspace rule: `nexus.worker-defaults`
      forbids `--force` in worker scripts; protect the branch to make
      the rule structural).
    - You generally don't need PR-only merges here, since the only
      writer is your bot and there are no human collaborators.
- **Collaborators**: just you (and any co-operator who actively works
  on this asset+issue repo). The bot's installation token is sufficient
  for every write the watcher and workers do.

The code repo (`<your-org>/nexus-code`) is governed by the project's
own contribution rules; see [Contributing → Development](../contributing/development.md).

## Collaboration patterns

Each nexus instance is designed for a single operator. The
recommended pattern for teams is that every operator runs their
own asset+issue repo, sandbox, and nexus, with the per-operator
plumbing each instance needs:

- One clone of `<your-org>/nexus-code` (read access is enough; PRs
  land changes back upstream).
- One private asset+issue repo.
- One GitHub App, installed on that operator's asset+issue repo.
- One `~/.claude/` directory with the per-operator pem, token
  cache, and webhook secret.
- One `config/nexus.yml`.

Two watchers can run on the same host as long as their
`bot_token_cache` filenames differ (see
[GitHub App → Cross-fork variant](github-app.md#cross-fork-variant)).
There is no tested multi-operator-on-one-instance setup, and
sharing an asset+issue repo across operators is not currently
supported.

Operators collaborate informally, in two ways:

- **Through the GitHub interface.** One operator's bot can open
  issues, post comments, or open PRs on another operator's
  asset+issue repo (or on the shared `nexus-code` repo). These
  cross-operator interactions are **advisory, not
  auto-actioned**: if operator A's bot opens an issue on operator
  B's nexus repo, B's nexus does not pick it up automatically.
  B's operator reads it like any other comment and decides
  whether to engage. The GitHub surface is a message-board, not
  an RPC.
- **Through shared write directories.** If operators share a
  filesystem (a lab volume, an HPC scratch path), their workers
  can edit the same `work/<project>/` checkout. The
  collision-avoidance rules from
  [`CLAUDE.md`](https://github.com/<your-org>/nexus-code/blob/main/CLAUDE.md)
  apply: when two workers might touch the same project, isolate
  via a fresh clone or a worktree rather than relying on
  lockfiles.

Stronger coordination — cross-bot synchronisation, distributed
locking, automated cross-instance triggers — is out of scope for
now.

## Asset-repo separation (rare)

`github.asset_repo` defaults to `github.repo`. Setting it to a
different value sends `monitor/ng upload` to a separate repo while
issues, comments, and the dashboard stay where they are. Use this
only if you have a concrete reason to keep assets out of the
asset+issue repo (e.g. you want assets in a fully public showcase
repo while issues stay private). The default-collapsed shape is
simpler to reason about; most operators should leave the key
commented out.

## What's gitignored

The code-repo `.gitignore` keeps per-operator state out:

- `config/nexus.yml` — your filled-in workspace config.
- `assets/` — local clone of the asset+issue repo (working tree for
  `monitor/upload-asset.sh`).
- `monitor/.state/` — watcher heartbeat, lock, logs, dedup caches.
- `reports/` — local-only work records.
- `work/<project>/` — per-project working checkouts.
- `~/.claude/...` (under `$HOME`, not the repo) — bot pem, tokens,
  webhook secret.

A CI workflow (`.github/workflows/check-no-reports-leaked.yml`) fails
any PR that adds a file under `reports/` other than the `.gitignore`
itself. The guard exists because a stray report leaked in PR `#40`
before the gitignore was in place; the workflow prevents recurrence.

## Related

- [GitHub App](github-app.md) — creating and installing the App on
  the asset+issue repo.
- [Security](security.md) — public/private boundary, the three
  authorization tiers, redaction discipline for external-public
  writes.
- [Reports](../operating/reports.md) — what goes into `reports/`
  and why it stays out of the code repo.
- [Install](../getting-started/install.md) — full step-by-step
  setup from scratch.
