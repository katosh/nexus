# GitHub App

The nexus bot is a **GitHub App**, not a personal access token. Every
write the agents perform (reactions, replies, dashboard edits, PR
operations, asset commits) authenticates with an installation token
minted on demand from the App's RSA private key. This page is the
end-to-end walkthrough: create the App, grant the right permissions,
install it on your asset+issue repo, populate `config/nexus.yml`, and
verify the wiring.

For the broader public/private split that motivates a per-operator
App, see [Repos](repos.md). For the day-to-day identity rules every
worker follows, see [Security](security.md).

!!! info "Audience"
    A first-time operator standing up their own nexus. The flow below
    assumes you have completed the [Install](../getting-started/install.md)
    prerequisites and already have a private asset+issue repo to point
    the bot at.

!!! tip "Recommended path: let Claude Code drive"
    For first-time installs the recommended flow is the Claude-Code-
    driven bootstrap — `agent-sandbox tmux new-session
    ./monitor/bootstrap-install.sh` — which walks you through every
    step on this page interactively, asks back for the values it
    needs, generates `config/nexus.yml`, and runs the smoke tests.
    The walkthrough below is the authoritative reference the
    bootstrap quotes; keep it open if you want to follow along, or
    if you're debugging the bootstrap. See
    [Install § Step 2](../getting-started/install.md#step-2-launch-the-install-bootstrap).

## Why a GitHub App and not a PAT

| Property | GitHub App | Personal access token |
|---|---|---|
| Identity | Its own `[bot]` account | Your user account |
| Permission scope | Per-repo, per-resource granular | The full scope of your user |
| Token lifetime | ~1 h installation token, auto-refreshed | 30–90 days, manual rotation |
| Notification routing | Mobile push always fires for the user | Muted on actions taken by your own account |
| Eligibility filter | Author-based exclusion is structural | Requires body-prefix conventions |

The last row is load-bearing. The watcher's eligibility filter
(see [Security](security.md#the-eligibility-filter)) keys off
`comment.author.login == github.user_login` — bot-authored comments
are excluded from the directive stream by construction, so the bot
can never read its own output as user input.

## Prerequisites

- `gh` CLI authenticated as yourself (smoke tests only; the bot path
  uses minted installation tokens).
- `python3` with `pyyaml` (used by `config/load.sh`).
- `openssl`, `jq`, `curl`, `bash` — already required by the watcher.
- A writable `~/.claude/` directory for the App's RSA private key and
  the token cache.
- An existing asset+issue repo (your bot will install onto this repo
  only). Convention: `<your-org>/<your-handle>-nexus-assets`, private.
  See [Install](../getting-started/install.md) for the repo-creation
  step.

## Step 1 — open the App-creation page

Solo operator (personal-account App):

```
https://github.com/settings/apps/new
```

Org-owned App (recommended for labs — survives any single admin's
account leaving, centralises secret rotation):

```
https://github.com/organizations/<your-org>/settings/apps/new
```

Both flows are otherwise identical; the App's owner determines who
can rotate its secrets later.

## Step 2 — App basics

| Field | Value |
|---|---|
| **GitHub App name** | A distinctive slug — convention `<org>-<user>-bot` keeps fork attribution legible. The slug becomes the bot's login (`<slug>[bot]`). |
| **Homepage URL** | Anything you can claim ownership of (the repo URL works); the bot never links out. |
| **Callback URL** | Leave blank. The bot does not use OAuth. |
| **Setup URL** | Leave blank. |
| **Webhook → Active** | **On**. See [Step 3](#step-3-webhook-secret-and-smee-channel). |

## Step 3 — webhook, secret, and smee channel

The watcher reads webhook deliveries from GitHub's authenticated
`/app/hook/deliveries` endpoint using an App JWT — it does NOT poll
the URL you configure here. The URL only needs to exist so that GitHub
retains every delivery in its log.

1. Provision an inert sink. The simplest path is a [smee.io](https://smee.io)
   channel: visit `https://smee.io/new`, which 302s to a fresh
   `https://smee.io/<slug>` URL. Any reachable HTTP endpoint that
   returns `200` works (Cloudflare Worker, self-hosted receiver, etc.).
2. Paste that URL into the App settings' **Webhook URL** field.
3. Generate a secret and paste it into **Webhook secret**:

    ```bash
    openssl rand -hex 32
    ```

4. Leave **SSL verification** ON. Disabling it lets anyone who hijacks
   the smee channel forge deliveries.
5. Save the secret to a `chmod 600` file on the watcher host:

    ```bash
    echo -n "<paste-secret-here>" > ~/.claude/<bot-slug>-webhook-secret
    chmod 600 ~/.claude/<bot-slug>-webhook-secret
    ```

    The path goes into `github.bot_webhook_secret_path` in
    [Step 8](#step-8-populate-confignexusyml).

!!! note "The webhook secret is informational today"
    The watcher trusts GitHub end-to-end over the App-JWT channel and
    does not currently HMAC-verify deliveries. The secret slot exists
    so that rotation becomes a config change rather than a code change
    once a self-hosted receiver verifies signatures locally. Keep
    perms tight regardless.

## Step 4 — permissions

Grant exactly what the code below requires. Each row traces to a
concrete call site in `monitor/`; nothing else is needed, and leaving
the rest ungranted keeps the bot's blast radius small.

| Permission | Grant | Code path | Why |
|---|---|---|---|
| Repository → **Metadata** | Read | Implicit — every `gh api /repos/:r/...` resolves through it; `monitor/mint-token.sh`'s output is unusable without it | Required by every GitHub App. |
| Repository → **Issues** | Read & Write | `monitor/ng process\|react\|reply\|close\|dashboard ...`; `monitor/watcher/_github.sh:snapshot_github` (GraphQL `search(type: ISSUE)` + comment-reactions fetch) | The dashboard is issue-body content; the eligibility filter reads comment bodies and reactions; every directive turn reacts 👀/🚀, posts replies, closes threads, or patches the overview body between the `<!-- NEXUS_DASHBOARD_START -->` markers. |
| Repository → **Contents** | Read & Write | `monitor/upload-asset.sh`: `git clone` / `git fetch` / `git push` against `https://x-access-token:<TOKEN>@github.com/<asset-repo>.git` | Pushing to the asset repo's `main` branch under `assets/...` requires Contents write. Without it `git push origin main` returns 403. |
| Repository → **Pull requests** | Read & Write | `monitor/ng pr create\|edit\|merge\|view ...`; worker invocations of `GH_TOKEN=$(./monitor/mint-token.sh) gh pr ...` | Bot-authored PR operations 403 without this scope. Used by worker agents that open PRs on their feature branches. |
| Organization → **Members** | Read | `gh pr edit` invoked as the bot against a PR in an org-owned head repo | `gh pr edit` validates the authenticated identity's edit rights by checking org membership before issuing the REST call. Without this scope the CLI errors out client-side. |

Skip every other permission GitHub lists (Deployments, Actions,
Secrets, Variables, …) — nothing in `monitor/` touches them.

## Step 5 — subscribe to events

Subscribe to **exactly** these five event kinds; the deliveries-polling
watcher (`monitor/watcher/_deliveries.sh`, gated by
`monitor.deliveries.*`) folds them into its line-shape vocabulary:

- `issues`
- `issue_comment`
- `pull_request`
- `pull_request_review`
- `pull_request_review_comment`

Subscribing to more events just inflates `/app/hook/deliveries`
without surfacing anywhere. Subscribing to fewer drops directives
on the floor.

## Step 6 — install location and private key

1. **Where can this GitHub App be installed?** — choose **Only on
   this account**. This restricts the install to the org or user
   that owns your asset+issue repo.
2. Click **Create GitHub App**.
3. On the new App's settings page, scroll to **Private keys** and
   click **Generate a private key**. A `.pem` file downloads. Move
   it to the watcher host and store it with tight perms:

    ```bash
    mv ~/Downloads/<bot-slug>.*.private-key.pem ~/.claude/<bot-slug>.pem
    chmod 600 ~/.claude/<bot-slug>.pem
    ```

    The path goes into `github.bot_pem_path` in
    [Step 8](#step-8-populate-confignexusyml). Treat this file like
    an SSH private key. Rotation: [see below](#rotating-the-private-key).

4. Capture the **App ID** at the top of the settings page (7-digit
   integer); it becomes `github.bot_app_id`.

## Step 7 — install the App on your asset+issue repo

1. Click **Install App** in the App's left-nav.
2. Choose the account that owns your asset+issue repo.
3. **Restrict the install to that single repo.** Do NOT install on
   `<your-org>/nexus-code` — your bot is per-operator and writes only
   to your own asset+issue repo. The code repo carries no
   per-operator state.
4. After install, GitHub redirects to a URL of the form
   `https://github.com/settings/installations/<n>` or
   `https://github.com/organizations/<org>/settings/installations/<n>`.
   The trailing `<n>` is `github.bot_installation_id`.

!!! warning "One install per operator"
    A single GitHub App can be installed on multiple repos, but each
    nexus deployment should run its own App. Sharing an App across
    operators couples their token caches and conflates audit trails.
    For sibling labs / forks, repeat the entire flow per fork — see
    [Cross-fork variant](#cross-fork-variant) below.

## Step 8 — populate `config/nexus.yml`

```bash
cd <nexus-root>
cp config/nexus.example.yml config/nexus.yml
chmod 600 config/nexus.yml
```

Edit the file. The minimum to fill in:

```yaml
nexus:
  root: <absolute-path-to-this-clone>

github:
  user_login: <your-github-login>
  repo: <your-org>/<your-handle>-nexus-assets

  bot_app_id: <APP_ID>            # from Step 6
  bot_installation_id: <INSTALL_ID>  # from Step 7
  bot_pem_path: ~/.claude/<bot-slug>.pem
  bot_token_cache: ~/.claude/.nexus-bot-token.json
  # ^ pick a unique filename per nexus if you run multiple on one host.

  bot_git_name:  <bot-slug>[bot]
  bot_git_email: <bot-slug>[bot]@users.noreply.github.com
  bot_login:     <bot-slug>

  bot_webhook_url:         https://smee.io/<your-channel>
  bot_webhook_secret_path: ~/.claude/<bot-slug>-webhook-secret

monitor:
  deliveries:
    asset_enabled: true
    bot_mention_enabled: true
```

`github.asset_repo` defaults to `github.repo`, so leave it commented
unless you intentionally want assets in a different repo from issues
(rare). Other knobs — Pushover, ntfy, email, idle thresholds — are
covered in [Config](../reference/config.md).

## Step 9 — smoke tests

Run each command in order from the nexus root. Each step is
independently re-runnable; fix the cause and re-run before moving on.

```bash
# 1. Mint an installation token. Should print a JWT-shaped value.
./monitor/mint-token.sh

# 2. App-JWT smoke (used by the deliveries probe).
./monitor/mint-token.sh --jwt-only

# 3. Resolve an issue via the bot token. Both "ok" and "ng: not found"
#    prove the token mints and the App can read the repo.
./monitor/ng issue 1

# 4. Bot install scope.
./monitor/ng preflight "$(./config/load.sh github.repo)"
# expected: "bot installed yes"

# 5. End-to-end asset upload. Commits one file to the asset repo's
#    main branch and prints the SHA-pinned URL.
./monitor/ng upload README.md --message "preflight"
```

If all five succeed, the bot mints tokens, reads your asset+issue
repo, and can push commits as the App identity. You're ready for the
watcher.

### Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `private key not found` | `bot_pem_path` is wrong or the file moved | `ls -l "$(./config/load.sh github.bot_pem_path)"` must show `-rw-------`. Re-`chmod 600`. |
| `Bad credentials` on the deliveries probe | `bot_app_id` doesn't match the pem you downloaded | Recheck the App page; the App ID is at the top. |
| `ng preflight` returns `bot installed no` | App is not installed on the asset+issue repo | Re-do [Step 7](#step-7-install-the-app-on-your-assetissue-repo). |
| `ng upload` 403 on push | Contents permission granted on the App but not installed on the asset repo | Same — re-do Step 7. |
| `ng upload` 404 cloning the asset repo | The repo doesn't exist on GitHub, or `github.repo` is misspelled | `gh repo view "$(./config/load.sh github.repo)"`. |
| `gh pr edit` fails with `Resource not accessible by integration` or `could not look up members of organisation` | Missing Organization → Members: read permission | Add it via App settings, accept the new-permission request on the installation. |
| Deliveries probe returns `[]` after `--jwt-only` | Expected on a fresh install | Trigger any subscribed event in the asset repo (react `:thumbsup:` on any issue) and re-run the probe. |

## Step 10 — verify webhook subscription end-to-end

Trigger any subscribed event in your asset+issue repo:

1. Open any issue in `github.repo`.
2. Add a `:thumbsup:` reaction to the issue body.
3. Wait ~5 s for GitHub to record the delivery.

Then re-run the deliveries probe:

```bash
JWT=$(./monitor/mint-token.sh --jwt-only)
curl -sS \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/hook/deliveries?per_page=3" \
  | jq '.[].event, .[].status_code'
```

The newest entry should show:

```
"issues"        # or issue_comment, pull_request, ...
200             # smee channel returned 200
```

A non-200 status code means the smee channel is unreachable or
deleted. GitHub still records the delivery either way; the watcher
reads from `/app/hook/deliveries` directly, so non-200 only matters
if you ever wire up a self-hosted receiver.

## First-time overview-issue setup

The install bootstrap (`./monitor/bootstrap-install.sh`, Phase 5) does
this for you using the bot's installation token once the Phase 4 smoke
tests pass. You only need this section if you skipped the bootstrap
and are wiring the asset+issue repo by hand, or if you're re-running
the bootstrap with `--force` and want to know what the agent will
execute.

The monitor discovers the overview issue **by label**, not by number
or title. One-time setup on a fresh asset+issue repo:

1. Create the label `nexus:overview` (mandatory). The bootstrap also
   creates `nexus:active`, `nexus:decision`, and `nexus:blocked` as
   thread-organising defaults; colours and descriptions match the
   reference deployment `<your-org>/<your-nexus>`.
2. Open a new issue titled `Nexus`, apply the `nexus:overview` label,
   and use a placeholder body with the dashboard markers:

    ```
    <!-- NEXUS_DASHBOARD_START -->
    _dashboard not yet populated_
    <!-- NEXUS_DASHBOARD_END -->
    ```

3. The first `./monitor/ng dashboard put --body-file <file>` splices
   new content between the markers, preserving any static prose
   around them.
4. Pin the issue so it stays at the top of the Issues tab. The
   bootstrap tries `gh issue pin` under the bot token first; if
   GitHub refuses (some org-policy combinations 403 App-authenticated
   pin mutations), it falls back to a one-line "pin in the browser"
   nudge — pinning is cosmetic and doesn't affect runtime correctness.

`--force` re-bootstrap idempotency: labels are created via the REST
API (`gh api repos/$repo/labels`, portable to the `gh 1.13.0` in the
sandbox base image) and PATCHed in place on a 422; the bootstrap
reuses any existing open `nexus:overview` issue before creating;
`gh issue pin` is a no-op on already-pinned issues.

## Secret handling and rotation

### Files the bot writes to

| Path (default) | Purpose | Perms |
|---|---|---|
| `~/.claude/<bot-slug>.pem` | App private key — signs the JWT that mints installation tokens | `0600` |
| `~/.claude/.nexus-bot-token.json` | Cached installation token + expiry. Re-minted within 5 min of expiry. | `0600` (set by the mint helper) |
| `~/.claude/<bot-slug>-webhook-secret` | HMAC secret matching the App settings' webhook field. Informational today; load-bearing once a self-hosted receiver verifies signatures. | `0600` (or `0660` for a bot-uid group) |
| `config/nexus.yml` | Workspace config; holds non-secret IDs and paths to the above files | `0600` |

None of these belong inside `monitor/.state/` (which is shared with
the watcher's runtime state) and none should ever be committed.

### Rotating the private key

If the `.pem` leaks or you suspect compromise:

1. On the App settings page, scroll to **Private keys** → click
   **Generate a private key**. A new `.pem` downloads. (You can have
   multiple active keys briefly; the App accepts JWTs signed by any
   of them.)
2. Replace the file at `github.bot_pem_path` with the new one
   (`chmod 600`).
3. Mint a token to confirm: `./monitor/mint-token.sh` should print a
   fresh JWT-shaped value.
4. On the App settings page, **delete the old key** to invalidate
   any in-flight JWT signed with it.
5. The next watcher cycle picks up the new key automatically — no
   restart needed because `mint-token.sh` re-reads the pem on every
   mint.

### Rotating the webhook secret

1. Generate a new value: `openssl rand -hex 32`.
2. Paste it into the App settings' **Webhook secret** field.
3. Overwrite the file at `github.bot_webhook_secret_path` with the
   same value.
4. The deliveries log keeps flowing because GitHub records deliveries
   regardless of receiver outcome; nothing in the watcher reads the
   file today, so rotation is hygiene rather than load-bearing.

### Rotating the installation

If the bot is installed on the wrong repo, or you need to revoke its
access entirely, **uninstall the App** from
`https://github.com/settings/installations` (or the org equivalent).
This invalidates every outstanding installation token. Re-install per
[Step 7](#step-7-install-the-app-on-your-assetissue-repo) to restore.

## Cross-fork variant

When a sibling lab forks the nexus pattern (creating a separate
`<their-org>/<their-handle>-nexus-assets` repo and running their own
operator on their own host), each fork needs its **own GitHub App
and installation**. The code is shared (one clone of `nexus-code`
per operator, all from the canonical implementation repo); the
per-fork values are:

- A separate **App** with its own App ID.
- A separate **installation** on the sibling fork's asset+issue repo.
- A separate **`.pem`** file.
- A separate **webhook secret** file.
- A separate **smee channel** — do not share.
- A unique **`bot_token_cache`** filename
  (e.g. `~/.claude/.<other-handle>-bot-token.json`) if both
  watchers run on the same host. Otherwise per-fork tokens will
  overwrite each other.

The `<bot-slug>`, `<org>`, `<repo>`, and `<user-login>` are by
definition fork-specific. Everything in this guide applies verbatim;
repeat Steps 1–10 against the new fork's org and repo.

### Discoverability via the `nexus-fork` topic

Cross-fork bug-fix pings (a fix landing in one fork that siblings
should pull) need a way to enumerate the live forks. The convention
is the GitHub topic `nexus-fork`. After standing up a fork, tag it:

```bash
gh repo edit <your-org>/<your-handle>-nexus-assets --add-topic nexus-fork
```

Run as a user with admin rights on the fork. (The bot's installation
token typically can't write repo topics on repos it isn't installed
on; a maintainer's `gh` PAT is the right channel for the initial
tag.)

Verify siblings show up:

```bash
gh search repos topic:nexus-fork --json fullName,description
```

## What the bot can read and write

The bot is **not** a general-purpose GitHub identity. Its access is
bounded by:

- **Install scope** — the single asset+issue repo you ticked in
  Step 7. The token cannot resolve any other repo.
- **Permission scope** — the five rows in the [permission table](#step-4-permissions).
  Outside those, the token returns 403.
- **Authority scope** — the watcher only surfaces comments authored
  by `github.user_login`. A bot with all the right permissions still
  acts only on that one user's directives. See
  [Security → The eligibility filter](security.md#the-eligibility-filter).

If the bot ever needs to operate outside this envelope (e.g. open a
PR on `<your-org>/nexus-code` from a worker), the worker uses
`GH_TOKEN=$(./monitor/mint-token.sh) gh ...` and the App must be
installed on that target repo too. The
[`monitor/ng preflight`](../reference/ng-cli.md#ng-preflight) verb tells
you whether a given repo is in the install scope.

## Related

- [Repos](repos.md) — the public/private split and why the asset+issue
  repo lives separately.
- [Security](security.md) — the eligibility filter, the three
  authorization tiers, threat model.
- [Monitoring](monitoring.md) — verifying the bot is alive, log
  locations, the deliveries probe in operational use.
- [Config](../reference/config.md) — every `github.bot_*` key and its
  env-var override.
- [ng CLI](../reference/ng-cli.md) — verb table including `preflight`,
  `upload`, `dashboard`, `watcher-status`.
