# Nexus admin guide: standing up a fresh nexus from scratch

End-to-end walkthrough for a lab admin spinning up a nexus on a new
host, organisation, or fork. Reads top-to-bottom; every step has a
**worked example** drawn from the live `<your-org>-bot` deployment
so you can see what each placeholder resolves to in practice.

Companion docs:

- [`monitor/BOT_SETUP.md`](BOT_SETUP.md) — quick reference for an
  operator who is already familiar with the bot's shape.
- [`monitor/README.md`](README.md) — runtime architecture, watcher
  liveness, secret handling, env-var precedence.
- [`config/nexus.example.yml`](../config/nexus.example.yml) — the
  template you'll copy and edit.

Placeholders below are wrapped in `<ANGLE_BRACKETS>`. Grep-replace each
one with your value as you go. The recurring placeholders:

| Placeholder            | Worked example (`<your-org>-bot`)         |
|------------------------|-----------------------------------------------|
| `<ORG>`                | `<your-org>`                                    |
| `<BOT_SLUG>`           | `<your-org>-bot`                          |
| `<REPO>`               | `<your-nexus>`                                 |
| `<USER_LOGIN>`         | `<operator>` (the human admin / primary user)      |
| `<APP_ID>`             | `3416373`                                     |
| `<INSTALLATION_ID>`    | `124868979`                                   |
| `<SMEE_CHANNEL>`       | a freshly-provisioned `https://smee.io/<id>`  |
| `<SECRET_FILE>`        | `~/.claude/<operator>-bot-webhook-secret`          |
| `<PEM_FILE>`           | `~/.claude/<BOT_SLUG>.pem`                    |

## Prerequisites

- Admin rights on the GitHub organisation that will own the App.
- A writable `~/.claude/` on the host running the watcher.
- `gh` CLI authenticated as yourself (smoke tests only; not used by
  the minted-token path).
- `python3` + `pyyaml` (used by `config/load.sh`).
- `openssl`, `jq`, `curl`, `bash` — already listed in
  `monitor/README.md` "Tech stack".

## Step 1 — Create the GitHub App (org-owned)

For lab use, an **organisation-owned App** is the right choice: it
survives any single admin's account, scopes the install to the lab's
repos, and centralises secret rotation. A personal App works for solo
operators (see `BOT_SETUP.md`) but is the wrong identity for
multi-admin labs.

Visit:

```
https://github.com/organizations/<ORG>/settings/apps/new
```

**Worked example:** `https://github.com/organizations/<your-org>/settings/apps/new`.

## Step 2 — App basics

On the new-App page, fill in:

- **Name:** the slug becomes the bot's GitHub login. Convention:
  `<ORG>-<USER_LOGIN>-bot` keeps fork/admin attribution legible.
  Worked example: `<your-org>-bot` (its install URL is
  `https://github.com/apps/<your-org>-bot`).
- **Homepage URL:** the repo URL is fine — any URL the App can claim
  ownership of works; the bot never links out.
- **Callback URL:** leave blank. The bot does not use OAuth.
- **Webhook → Active:** **on**. (`BOT_SETUP.md` step 3 has the rationale
  and the smee/secret/SSL details — repeated below for the walkthrough.)
- **Webhook URL:** provision a smee.io channel by visiting
  `https://smee.io/new` (302s to a fresh `https://smee.io/<id>`); paste
  that URL here. The watcher does NOT POST to this URL — GitHub does.
  Any reachable HTTP endpoint that returns 200 works (Cloudflare
  Worker, self-hosted receiver). The URL only needs to exist so GitHub
  retains every delivery in `/app/hook/deliveries`, where the watcher
  reads them with the App JWT.
- **Webhook secret:** generate with `openssl rand -hex 32` and paste
  the value here. Save the same value to a file in step 8.
- **SSL verification:** **enabled**. Leaving this off lets a downstream
  attacker who hijacks the smee channel forge deliveries; with it on,
  GitHub validates the receiver's TLS chain.

## Step 3 — Permissions

Set each row from the table in `BOT_SETUP.md` "Permission table" — the
table traces every grant to a concrete code path. Summary:

| Permission                      | Grant      |
|---------------------------------|------------|
| Repository → Metadata           | Read       |
| Repository → Issues             | Read+Write |
| Repository → Contents           | Read+Write |
| Repository → Pull requests      | Read+Write |
| Repository → Repository projects| Read+Write |
| Organization → Members          | Read       |

Skip every other permission GitHub lists. **Worked example:** the
public permission summary for the live App is at
`https://github.com/apps/<BOT_SLUG>` — admins can sanity-check theirs
matches the reference deployment.

## Step 4 — Subscribe to events

The deliveries-polling watcher (`monitor/watcher/_deliveries.sh`) folds
these five event kinds into its line-shape vocabulary:

- `issues`
- `issue_comment`
- `pull_request`
- `pull_request_review`
- `pull_request_review_comment`

Subscribing to anything else just inflates `/app/hook/deliveries`
without surfacing anywhere; subscribing to fewer drops directives on
the floor.

## Step 5 — Generate and download the private key

On the App settings page, scroll to **Private keys → Generate a private
key**. A `.pem` file downloads to your laptop. Move it to the host
running the watcher and save it as `<PEM_FILE>`, `chmod 600`.

**Worked example:** `~/.claude/<your-org>-bot.pem`.

The path goes into `github.bot_pem_path` in step 9.

## Step 6 — Install the App on the repo(s)

Click **Install App** in the App's left-nav, select `<ORG>`, and
restrict the install to the specific repos the bot will operate
against. The bot's installation token will only have access to repos
you tick here; you can add more later via *Settings → Integrations →
Configure* on the App.

**Worked example:** `<your-org>-bot` is installed on
`<your-org>/<your-nexus>` plus 5 sibling lab repos.

## Step 7 — Capture App ID and installation ID

- **App ID** is at the top of the App settings page (a 7-digit
  integer). Record as `<APP_ID>`. Worked example: `3416373`.
- **Installation ID** is in the URL after install completes:
  `https://github.com/organizations/<ORG>/settings/installations/<n>`
  (org-owned) or
  `https://github.com/settings/installations/<n>` (user-owned). The
  trailing `<n>` is `<INSTALLATION_ID>`. Worked example: `124868979`.

## Step 8 — Save the webhook secret

Paste the secret value generated in step 2 into a file:

```bash
echo -n "<paste-secret-here>" > <SECRET_FILE>
chmod 600 <SECRET_FILE>
```

**Worked example:** `~/.claude/<operator>-bot-webhook-secret`. The path goes
into `github.bot_webhook_secret_path` in step 9.

The secret is **operationally informational today** — the watcher
reads `/app/hook/deliveries` over the authenticated App-JWT channel and
trusts GitHub end-to-end. The file becomes load-bearing once HMAC
verification moves into a self-hosted receiver, at which point only
the smee URL changes; the secret-file path stays.

## Step 9 — Populate `config/nexus.yml`

```bash
cd <NEXUS_ROOT>
cp config/nexus.example.yml config/nexus.yml
chmod 600 config/nexus.yml
```

Edit every value below in `config/nexus.yml`:

```yaml
nexus:
  root: <NEXUS_ROOT>           # absolute path to this repo's checkout

github:
  user_login: <USER_LOGIN>     # the human admin / primary user
  repo: <ORG>/<REPO>           # the bot's primary nexus repo

  bot_app_id: <APP_ID>
  bot_installation_id: <INSTALLATION_ID>
  bot_pem_path: <PEM_FILE>
  bot_token_cache: ~/.claude/.nexus-bot-token.json
  # ^ per-workspace; pick a unique name (e.g.
  # ~/.claude/.<ORG>-bot-token.json) if running multiple nexus
  # instances on one host.

  bot_git_name:  <BOT_SLUG>[bot]
  bot_git_email: <BOT_SLUG>[bot]@users.noreply.github.com
  bot_login:     <BOT_SLUG>

  bot_webhook_url:         <SMEE_CHANNEL>
  bot_webhook_secret_path: <SECRET_FILE>

monitor:
  deliveries:
    asset_enabled: true
    bot_mention_enabled: true
```

(Pushover / ntfy / email blocks: see `config/nexus.example.yml` —
optional but recommended; without them `notify.sh` no-ops silently.)

## Step 10 — Smoke-test App credentials

```bash
# Installation token — paste-able into GH_TOKEN.
./monitor/mint-token.sh

# App-level JWT — used for the deliveries probe below.
./monitor/mint-token.sh --jwt-only

# Deliveries probe — should return a JSON array (possibly empty).
JWT=$(./monitor/mint-token.sh --jwt-only)
curl -sS \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/hook/deliveries?per_page=3" \
  | jq '.[].event'
```

Common failure modes:

- `private key not found` → `bot_pem_path` is wrong, or perms are
  loose. `ls -l <PEM_FILE>` must show `-rw-------`.
- `Bad credentials` on the deliveries probe → `bot_app_id` mismatched
  the pem you downloaded; re-check the App page.
- Deliveries probe returns `[]` → expected on a fresh install. Step 11
  populates it.

## Step 11 — Verify webhook subscription end-to-end

Trigger any subscribed event in `<ORG>/<REPO>`. The simplest:

1. Open any issue in the repo.
2. React `:thumbsup:` on the issue body (or comment).
3. Wait ~5 s for GitHub to deliver.

Re-run the deliveries probe from step 10. The newest entry should now
show:

```
"event": "issues"        # or issue_comment, pull_request, ...
"status_code": 200       # smee channel returned 200
```

A non-200 status code means smee is unreachable or the channel was
deleted; recreate the channel and update `<SMEE_CHANNEL>` in
`config/nexus.yml`. (GitHub still records the delivery either way;
non-200 just means the receiver dropped it — irrelevant to the
watcher, which reads from `/app/hook/deliveries` directly.)

## Step 12 — Start the watcher

```bash
monitor/watcher/launcher.sh --target <TARGET_WINDOW>
```

`<TARGET_WINDOW>` is the tmux window the watcher pastes reports into;
the workspace convention is `orchestrator`. The watcher runs
**headless** — `setsid`-detached, with **no tmux window of its own**;
its output goes to `monitor/.state/watcher.log` and its liveness is
anchored by the pidfile `monitor/.state/watcher.pid` + heartbeat. The
launcher is idempotent: it refuses to double-start when a watcher is
already alive, so re-running after a config edit is safe. Pass
`--replace` to kill a wedged watcher first.

(Most operators don't run this step by hand — `./watcher` brings the
whole stack up and lands you in the `services` cockpit. This is the
low-level equivalent.)

Sanity check (headless — there is no watcher window to grep for):

```bash
monitor/ng watcher-status                 # heartbeat fresh + pid alive
tail -n 5 monitor/.state/watcher.log      # should show "snapshot ok"
```

## Step 13 — Cross-fork variant (sibling nexus deployments)

When a sibling lab forks the nexus (e.g.,
`<your-org>/<other-nexus>`), each fork needs its **own GitHub App and
installation**. The watcher code is shared (same git remote); the
per-fork values are:

- `<APP_ID>` — different App, different ID.
- `<INSTALLATION_ID>` — different install on the new repo.
- `<PEM_FILE>` — each fork generates and stores its own private key.
- `<SECRET_FILE>` — each fork has its own webhook secret.
- `<SMEE_CHANNEL>` — provision a fresh smee channel; do not share.
- `bot_token_cache` — pick a unique filename
  (e.g. `~/.claude/.<other-nexus>-bot-token.json`) so per-fork tokens
  don't overwrite each other when both watchers run on the same host.

The `BOT_SLUG`, `ORG`, `REPO`, and `USER_LOGIN` are by definition
fork-specific. Everything in this guide applies verbatim — repeat
steps 1–12 against the new fork's org and repo.

## Step 14 — Tag the fork for discoverability

Cross-fork bug-fix pings (a fix landing in one fork that siblings
should pull) need a way to enumerate the live forks. The convention is
the GitHub topic `nexus-fork`: tag your fork once and every nexus
agent can list siblings via `gh search repos topic:nexus-fork`.

After forking the nexus pattern (creating a `<USER_LOGIN>-nexus`
repo), tag it:

```bash
gh repo edit <ORG>/<USER_LOGIN>-nexus --add-topic nexus-fork
```

Run as a user with admin on the fork (the bot's installation token
typically can't write topics on repos it isn't installed on; bare
`gh` under a maintainer's PAT is the right channel).

Once the bot is installed on the fork as well,
`gh repo edit <your-org>/<user>-nexus --add-topic nexus-fork` can be
run via `GH_TOKEN=$(./monitor/mint-token.sh) gh repo edit ...`
(bot identity instead of user PAT).

Verify the fork now appears alongside its siblings:

```bash
gh search repos topic:nexus-fork org:<ORG> --json fullName,description
```

## When something is off

- **Deliveries log keeps returning `[]` after step 11** — App is not
  subscribed to the event you triggered. Re-check step 4 against the
  App settings page's *Subscribe to events* block.
- **Watcher logs `snapshot_deliveries: 404 — App has no webhook URL`**
  — the App's *Webhook → Active* toggle is off, or the URL field is
  blank. Re-check step 2.
- **`gh pr edit` from the bot fails with an org-membership error** —
  the *Organization → Members: read* permission is missing; see the
  troubleshooting block in `BOT_SETUP.md`.
- **Token suddenly stops working hours later** — installation tokens
  are ~1 h scoped; `mint-token.sh` self-heals via its cache. Long-lived
  raw `curl` invocations need to re-mint:
  `GH_TOKEN=$(./monitor/mint-token.sh)`.

For deeper architecture (eligibility filter, cross-repo mention path,
notification routing) see `monitor/README.md`.
