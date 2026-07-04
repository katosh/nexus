# Nexus bot: GitHub App setup

Quick reference for an operator who's already familiar with the nexus
bot's shape. For a from-scratch walkthrough — including the smee.io
channel, webhook secret, deliveries-path verification, and
`config/nexus.yml` population using `<your-org>-bot` as the worked
example — see [`monitor/BOT_ADMIN_GUIDE.md`](BOT_ADMIN_GUIDE.md). For
architecture, the issue layout, and day-to-day operation, see
[`monitor/README.md`](README.md).

## Overview

The monitor writes to GitHub as a **GitHub App** (not a personal access
token). The App is installed on **your asset+issue repo** (configured
in `github.repo`, e.g. `<your-org>/<yourname>-nexus-assets`); every
REST write (`ng react`, `ng reply`, `ng close`, `ng dashboard put`)
and the asset-repo `git push` in `monitor/upload-asset.sh` authenticate
with an installation access token minted on demand by
`monitor/mint-token.sh`.

The implementation repo (`<your-org>/nexus-code`) is a separate code
checkout — your `origin` remote in this clone — and the bot does
not need to be installed there to run a nexus. (It happens to be
installed on `<your-org>/nexus-code` for the maintainers' convenience
when opening PRs against the upstream code.)

Why a GitHub App and not a PAT:

- **Scoped identity.** The App posts as its own `[bot]` account. The
  eligibility filter in `monitor/watcher/main.sh:snapshot_github` keys
  off `author.login == github.user_login`, which means bot-authored
  comments are excluded from the user-directive stream by construction —
  no body-prefix convention needed, and the bot cannot read its own
  output as input.
- **Narrow permissions.** Each permission below traces to a specific
  code path. A PAT would carry the full scope of the user account.
- **Self-refreshing tokens.** `monitor/mint-token.sh` signs a short-lived
  JWT with the App's RSA key and exchanges it for a ~1 h installation
  token, cached at `github.bot_token_cache` with `chmod 600`. No
  30/90-day PAT-expiry drama.
- **Per-operator separation.** Each operator runs their own App on
  their own asset+issue repo without sharing any secret with other
  operators of the same `nexus-code` checkout.

## Prerequisites

- `gh` CLI authenticated as yourself (for smoke tests; not used by the
  minted-token path).
- `python3` + `pyyaml` (used by `config/load.sh`).
- `openssl`, `jq`, `curl`, `bash` — already listed in the tech stack in
  `monitor/README.md`.
- A writable `~/.claude/` for the App's RSA key and the token cache.

## Step 0 — create your asset+issue repo

Before creating the App you need a target for it to install on:
your operator-specific asset+issue repo. The monitor reads issues
from this repo, writes the dashboard there, and pushes uploaded
assets to its `main` branch under `assets/...`. It is separate
from the cloned implementation repo (`<your-org>/nexus-code`) on
purpose — see the README "How to run" step 4 for the rationale.

```bash
gh repo create <your-org>/<yourname>-nexus-assets --private \
    --description "Asset + issue repo for my nexus deployment"
gh repo view <your-org>/<yourname>-nexus-assets    # confirm it exists
```

Leave the repo empty (no README, no `.gitignore`, no licence). The
first `monitor/upload-asset.sh` call clones it, creates the
`assets/...` tree, and pushes the initial commit on its own.

The `-assets` suffix is a convention; any private repo you control
works as long as nothing else writes to it. Two operators must not
share one — the dashboard, issues, and asset history are
single-tenant.

Step 9 below walks you through the App-install on this repo
specifically; step 11 wires its `<owner>/<name>` into `github.repo`.

## Step-by-step: creating the App

1. Open the App-creation page. For an org-owned nexus, it's
   `https://github.com/organizations/<org>/settings/apps/new`; for a
   personal-account nexus, `https://github.com/settings/apps/new`.
2. **Name** it something distinctive (e.g. `<org>-<user>-nexus-bot`) and
   set a **homepage URL** — any URL will do; the bot never links out.
   **Callback URL**: leave blank. The bot does not use OAuth.
3. **Webhook**: **enable**, with three sub-steps:

   1. Provision an inert sink. The simplest is a smee.io channel: visit
      `https://smee.io/new` (it 302s to a fresh `https://smee.io/<slug>`
      URL). Any reachable HTTP endpoint that returns 200 works — a
      Cloudflare Worker, a self-hosted receiver, etc. The watcher does
      NOT POST to this URL; GitHub does. The URL only needs to exist so
      that GitHub retains every delivery in `/app/hook/deliveries`,
      where the watcher reads them with the App JWT.
   2. Paste the URL into the App settings' **Webhook URL** field, and
      generate a secret with `openssl rand -hex 32`. Paste the secret
      into the App settings' **Webhook secret** field. Leave **SSL
      verification** ON.
   3. Save the same secret to `~/.claude/<bot-slug>-webhook-secret`,
      `chmod 600`. Record the smee URL at `github.bot_webhook_url` and
      the secret-file path at `github.bot_webhook_secret_path` in
      `config/nexus.yml`. Both keys are documentation-only today (the
      watcher trusts GitHub's deliveries log); they become load-bearing
      once HMAC verification moves into a self-hosted receiver, at
      which point only `bot_webhook_url` changes — everything else
      stays.
4. **Permissions**: grant exactly what the code below requires. See the
   permission table in the next section; set each field from that
   table's "Grant" column.
5. **Subscribe to events**: `issues`, `issue_comment`, `pull_request`,
   `pull_request_review`, `pull_request_review_comment`. The
   deliveries-polling watcher
   (`monitor/watcher/_deliveries.sh`, gated by
   `monitor.deliveries.*` in `config/nexus.yml`) folds these five
   event kinds into its line-shape vocabulary; subscribing to anything
   else just inflates the deliveries log without surfacing anywhere.
6. **Install location**: "Only on this account" — restricts the install
   to the org or user that owns the asset+issue repo created in step 0.
7. Click **Create GitHub App**.
8. On the new App's settings page, scroll to **Private keys** and click
   **Generate a private key**. A `.pem` file downloads. Save it to
   `~/.claude/<bot-name>.pem` and `chmod 600` it. This is the value of
   `github.bot_pem_path` in `config/nexus.yml`.
9. Click **Install App** in the left-nav, select the account that owns
   your asset+issue repo, and restrict the install to that **single
   asset+issue repo** (e.g. `<your-org>/<yourname>-nexus-assets`).
   Do NOT install it on `<your-org>/nexus-code` — your bot is
   per-operator and only ever writes to your own asset+issue repo.
   After install, GitHub redirects to a URL of the form
   `https://github.com/settings/installations/<n>` (or
   `/organizations/<org>/settings/installations/<n>`). Copy `<n>` —
   that's `github.bot_installation_id`.
10. Back on the App settings page, the **App ID** is at the top — copy
    it into `github.bot_app_id`.
11. `cp config/nexus.example.yml config/nexus.yml` and fill in
    `github.user_login`, `github.repo` (your asset+issue repo from step
    0, **not** `<your-org>/nexus-code`), `github.bot_app_id`,
    `github.bot_installation_id`, and `github.bot_pem_path`.
    `chmod 600 config/nexus.yml`. `github.asset_repo` defaults to
    `github.repo`, so leave it commented unless you intentionally want
    assets and issues in different repos.
12. Smoke test: `./monitor/ng issue 1` (or any existing issue number).
    Expected output: `#1 state=OPEN title=…`. If that succeeds, the App
    is minting tokens and the token has the scope needed to read issues.
    Then run the verify section below to confirm asset uploads work
    end-to-end.

## Verify (post-install smoke tests)

After step 12 succeeds, run these three commands in order. Each is
independently re-runnable; if one fails, fix the cause and re-run
just that command before moving on.

```bash
# 1. Token mint + repo metadata read.
./monitor/ng issue 1
# expected: #1 state=… title=…  (or "ng: not found" — both prove
# the token mints and the App can resolve the repo)

# 2. Bot install scope (ng preflight, post-#31 omnibus).
./monitor/ng preflight "$(./config/load.sh github.repo)"
# expected: bot installed yes (or a clear "no" if step 9 was skipped)

# 3. Asset upload end-to-end (commits one file to your asset repo's
#    main branch, prints the URL).
./monitor/ng upload README.md --message "preflight"
# expected: https://github.com/<your-asset-repo>/blob/<sha>/assets/general/README.md
```

If all three pass, the bot is minting tokens, can read your
asset+issue repo, and can push commits to it as the App identity.
You're ready for `./watcher` (README step 6).

The third command leaves a `assets/general/README.md` commit in
your asset repo. Delete it via the GitHub UI if you want a clean
asset history, or leave it as a sentinel that the wiring works.

## Permission table

Every permission below traces to a concrete call site. "Grant" is the
value to set in step 4 above.

| Permission                   | Grant      | Code paths (grep-verifiable)                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Why                                                                                                                                                                                                                                                                   |
|------------------------------|------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Repository → **Metadata**    | Read       | Implicit — every `api …` call in `monitor/ng` depends on `/repos/:r` resolving. `monitor/mint-token.sh`'s output is useless without it.                                                                                                                                                                                                                                                                                                                                                 | GitHub mandates Metadata: read on every App. Without it the installation token cannot resolve the repo.                                                                                                                                                               |
| Repository → **Issues**      | Read+Write | GET: `ng process` at `/repos/:r/issues/comments/:id` + `/reactions?per_page=100`; `ng issue` at `/repos/:r/issues/:n`; `_overview_number` at `/repos/:r/issues?labels=nexus:overview`; `cmd_dashboard_get`/`cmd_dashboard_put` at `/repos/:r/issues/:n`. GraphQL: `monitor/watcher/main.sh:snapshot_github` (`search(type: ISSUE)` + `comments.nodes { reactions }`). POST: `ng react`, `ng process`, `ng reply`, `ng close` (pre-close comment) at `/repos/:r/issues{,/comments}/:id{,/reactions,/comments}`. PATCH: `ng close` (state=closed) and `ng dashboard put` (body splice) at `/repos/:r/issues/:n`. | The dashboard is issue-body content; the eligibility filter reads comment bodies and reactions; every user-directive turn reacts 👀/🚀, posts replies, closes threads, or patches the overview body. All of that is the Issues scope. |
| Repository → **Contents**    | Read+Write | `monitor/upload-asset.sh`: `git clone`/`git fetch`/`git reset`/`git push` against `https://x-access-token:<TOKEN>@github.com/<asset-repo>.git` (the `main` branch under `assets/...`).                                                                                                                                                                                                                                                                                                  | Pushing to the asset repo's `main` branch is gated by the repo's Contents permission for GitHub Apps. Without Contents: write the `git push origin main` in `upload-asset.sh` returns 403.                                                                            |
| Repository → **Pull requests** | Read+Write | No monitor script invokes a PR endpoint directly. Granted for worker agents spawned in tmux windows that authenticate as the bot (`GH_TOKEN=$(monitor/mint-token.sh) gh pr create/edit/merge …`) to open, update, or land PRs on their feature branches.                                                                                                                                                                                                                                | Bot-authored PR operations require this scope; `gh pr create` and `gh pr merge` both 403 without it. Grep-present users: the agent flow documented in `skills/nexus.bot/SKILL.md` (the `ng pr ...` verb table and the `GH_TOKEN=$(./monitor/mint-token.sh) gh pr ...` escape hatch), not the monitor loop.                                          |
| Organization → **Members**   | Read       | `gh pr edit` invoked as the bot against a PR in an org-owned head repo. Added **2026-04-23** after PR #13 (`<your-org>/<your-nexus>#13`) failed `gh pr edit` with an org-membership error.                                                                                                                                                                                                                                                                                                   | `gh pr edit` validates the authenticated identity's edit rights by checking org membership before issuing the REST call. Without this scope the CLI errors out client-side; adding it is the minimal fix.                                                             |

Skip all the other permissions GitHub lists (Deployments, Actions,
Secrets, …) — nothing in `monitor/` touches them, and leaving them
ungranted keeps the blast radius small.

## First-time overview-issue setup

The install bootstrap (`./monitor/bootstrap-install.sh`, Phase 5)
does this for you using the bot's installation token once the
Phase 4 smoke tests pass. You only need this section if you
skipped the bootstrap and are wiring things up by hand, or if
you're re-bootstrapping with `--force` and want to know what the
agent is about to run.

The monitor discovers the overview issue **by label**, not by number or
title (`_overview_number` in `monitor/ng`). One-time setup on a fresh
repo:

1. Create the label `nexus:overview` (mandatory). The bootstrap also
   creates `nexus:active`, `nexus:decision`, and `nexus:blocked` —
   recommended defaults that organise threads in the asset+issue repo.
   The reference deployment `<your-org>/<your-nexus>` carries all four;
   colours and descriptions are documented in `monitor/install-prompt.md`
   Phase 5.1.
2. Open a new issue titled `Nexus`, apply the `nexus:overview` label,
   and use a placeholder body that includes the dashboard markers:

   ```
   <!-- NEXUS_DASHBOARD_START -->
   _dashboard not yet populated_
   <!-- NEXUS_DASHBOARD_END -->
   ```

3. The first `./monitor/ng dashboard put --body-file <file>` splices new
   content between the markers (preserving any static prose outside
   them).
4. Pin the issue so it stays at the top of the Issues tab. The
   bootstrap tries `gh issue pin` under the bot token; some org-policy
   combinations 403 App-authenticated pin mutations, in which case it
   falls back to a one-line "pin in the browser" nudge.

The bot patches this issue's body between the markers via
`monitor/ng dashboard put`. Idempotency notes for `--force`
re-bootstraps:

- Labels are created via the REST API (`gh api repos/$repo/labels`,
  portable to the `gh 1.13.0` in the sandbox base image); the
  upsert PATCHes an existing label in place on a 422 rather than
  erroring.
- The bootstrap checks for an existing open `nexus:overview` issue
  before creating; if one is found, it reuses the number.
- `gh issue pin` on an already-pinned issue is a no-op.

## Troubleshooting

- **`gh pr edit` fails with an organisation-membership error** —
  symptom: `GraphQL: Resource not accessible by integration` or
  `could not look up members of organisation <org>` when the bot runs
  `gh pr edit`. Fix: grant **Organization → Members: read** on the App
  settings page and accept the new-permission request on the
  installation. This is the exact fix applied on 2026-04-23 for PR #13.

- **`mint-token.sh` returns "private key not found"** — the pem moved,
  or `github.bot_pem_path` in `config/nexus.yml` points somewhere that
  doesn't exist. Check the path, `chmod 600`, try again. `ls -l
  "$("$_cfg" github.bot_pem_path)"` must show `-rw-------`.

- **Installation token expired mid-flight** — `mint-token.sh` checks the
  cache at `github.bot_token_cache` and re-mints when within 5 min of
  expiry, so in-process scripts self-heal. For raw `curl` calls that
  grabbed the token hours ago: re-mint (`GH_TOKEN=$(monitor/mint-token.sh)`)
  and retry.

- **`ng upload` push returns 403 to the asset repo** — Contents:
  write is granted on the App, but the App is not installed on
  the asset+issue repo configured in `github.repo` (or
  `github.asset_repo` if set explicitly). Re-check step 9: install
  the App on **your asset+issue repo** specifically. Confirm with
  `./monitor/ng preflight "$(./config/load.sh github.repo)"` —
  `bot installed yes` means the install scope covers the repo.

- **`ng upload` push returns 404 cloning the asset repo** — the
  asset+issue repo doesn't exist on GitHub yet, or `github.repo`
  is misspelled. Run `gh repo view "$(./config/load.sh
  github.repo)"`; if the repo is missing, re-do step 0; if it's
  spelled wrong, fix `config/nexus.yml`.

- **Private-repo raw URLs don't render in issue markdown** — symptom: a
  `raw.githubusercontent.com/…` URL embedded in a comment shows as a
  broken image in the mobile GitHub app or a logged-in browser. Cause:
  cookies for `github.com` don't attach to `raw.githubusercontent.com`.
  Fix: upload the asset via `./monitor/ng upload <path>`, which returns
  a `https://github.com/<owner>/<asset-repo>/raw/<sha>/<path>` URL
  on the asset repo's `main` branch — same-domain redirect to a
  viewer-session-bound signed CDN URL. See the "Embedding files
  (images and reports)" section of `monitor/README.md`.
