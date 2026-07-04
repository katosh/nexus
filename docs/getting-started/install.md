# Install

The recommended path is Claude-Code-driven: launch a one-shot
bootstrap session in agent-sandbox and let it walk you through
asset-repo creation, the GitHub App, the webhook, `config/nexus.yml`,
the smoke tests, and the first `./watcher`. You answer three or four
questions and click through a couple of browser pages; Claude Code
does the heavy lifting and stops if anything fails.

A [manual install path](#manual-install-advanced) is preserved
below for operators who prefer to do it themselves or who need to
debug the bootstrap.

!!! warning "Containment required"
    Nexus launches each worker as `claude --dangerously-skip-permissions`,
    so workers can run shell commands without per-action confirmation.
    Run nexus **only** inside [agent-sandbox](https://github.com/katosh/agent_sandbox)
    (recommended), a VM, or another containment layer that constrains
    what the worker can read, write, and execute. Do not run on a
    development laptop without containment. Both `./monitor/bootstrap-install.sh`
    and `./watcher` refuse to start unless they detect an agent-sandbox
    environment.

## Prerequisites

- A Linux host you can leave a tmux session running on (workstation,
  HPC interactive node, dev server). Walltime-limited compute is
  the wrong shape — the orchestrator must survive idle.
- [`agent-sandbox`](https://github.com/katosh/agent_sandbox) installed
  per-user: `brew tap katosh/tools && brew install agent-sandbox`.
- A GitHub **org admin** (you, or someone you can ask) to create and
  install the bot's **GitHub App** and the asset+issue repo. The
  nexus does all its GitHub work as that App — a dedicated bot
  identity with its own minted token, **not** your personal account.
  If you're not an admin, you'll relay the App ID, Installation ID,
  and private key from whoever is.
- `gh` CLI is **optional**. Its only install-time use is the one-time
  `gh repo create` in Phase 1, which has a browser/admin fallback
  (create the empty private repo at `https://github.com/new`). The
  bot uses its own GitHub App token at runtime, never your `gh` auth,
  so an unauthenticated `gh` does **not** block the install.
- Node.js ≥ 18 with `npm`. A pre-installed Claude Code is **not**
  required: when no `claude` binary is found, the bootstrap installs a
  project-local copy (`node_modules/.bin/claude`) via
  `monitor/install-claude-local.sh`. A system `claude` on PATH or a
  `CLAUDE_BIN` override is honored if you have one. You'll
  authenticate Claude Code on first launch if you haven't before.
- Standard shell toolkit: `bash`, `tmux`, `git`, `jq`, `openssl`,
  `python3` with `pyyaml`, `curl`.
- ~15–30 minutes, most of which is letting the bootstrap drive.

!!! note "<your-lab> operators"
    See the [<your-lab> addendum](../admin/site-addendum.md) for
    the lab-specific filesystem path (`<hpc-mount>/...`) and the shared-
    node coordination pattern (`<login-node>` → `<shared-node-tool>` → shared HPC node).

## Step 1 — clone `<your-org>/nexus-code`

You clone the upstream code repo directly — there is no fork to make.
The repo carries no per-operator state; every operator clones the
same upstream and `git pull origin main` for updates.

```bash
git clone https://github.com/<your-org>/nexus-code.git
cd nexus-code
```

If you'd rather put the clone under a project-scratch path like
`/fast/<lab>/user/<you>/nexus-code`, do that — the bootstrap will
record whatever cwd it lands in as `nexus.root` in `config/nexus.yml`.

## Step 2 — launch the install bootstrap

From inside the nexus-code clone:

```bash
agent-sandbox tmux new-session ./monitor/bootstrap-install.sh
```

`./monitor/bootstrap-install.sh` self-checks that it's running
inside tmux + agent-sandbox, refuses to overwrite an existing
`config/nexus.yml`, installs a project-local Claude Code
(`monitor/install-claude-local.sh`) when no `claude` binary is
found, then launches Claude Code with the bootstrap prompt at
`monitor/install-prompt.md` baked in.

Claude Code will:

- Greet you and confirm the prerequisites are in place (`openssl`,
  `jq`, `python3`+pyyaml; `gh` auth is optional — needed only for the
  Phase 1 `gh repo create`, which has a browser/admin fallback).
- Ask you three short questions: your GitHub login, the org that
  will own the bot and the asset repo, and the asset repo's name.
- Help you create the asset+issue repo (`gh repo create`).
- Walk you through creating a **GitHub App** in your browser,
  field-by-field: name, webhook URL (from `smee.io`), webhook secret
  (generated locally), permissions (the exact five rows), event
  subscriptions (the exact five), install location, private-key
  download, install scope.
- Generate `config/nexus.yml` from your inputs with the right
  perms (`chmod 600`).
- Run the smoke tests (`mint-token.sh`, `ng issue`, `ng preflight`,
  `ng upload`) and the webhook-deliveries probe.
- Seed the dashboard labels and the `nexus:overview`-labelled
  issue itself using the bot's installation token — no browser
  clicks beyond a fallback "pin this issue" nudge if GitHub
  refuses the App-authenticated pin mutation.
- Tell you to kill the bootstrap session and launch `./watcher`.

If any step fails the bootstrap **stops** rather than papering
over — it'll surface the verbatim error, point at the relevant
section of [GitHub App § Common failure modes](../admin/github-app.md#common-failure-modes),
and ask you what's on screen.

!!! tip "What if I already have a `config/nexus.yml`?"
    The bootstrap is designed for fresh installs and refuses to run
    against an existing config. If you genuinely want to re-bootstrap
    (e.g. moving to a new asset repo), back up the existing config first:

        mv config/nexus.yml config/nexus.yml.bak
        agent-sandbox tmux new-session ./monitor/bootstrap-install.sh

    Or pass `--force` to skip the refusal (the bootstrap will still
    see the existing config and ask you what to do).

## Step 3 — launch the watcher

When the bootstrap reports "install complete," kill that tmux
session and start the watcher:

```bash
cd <nexus-root>
agent-sandbox tmux new-session ./watcher
```

`./watcher` brings up the whole stack: the watcher starts as a
headless service (no tmux window; log at
`monitor/.state/watcher.log`), the watcher spawns the real
orchestrator (a fresh `orchestrator` tmux window running the
`claude` CLI), and the window you launched from becomes the
`services` cockpit — a read-only dashboard of the stack. From this
point on you drive
nexus from GitHub — comment on the overview issue from a browser,
laptop, or phone. The full first-session walkthrough is
[First run](first-run.md).

Subsequent restarts after an SSH drop or host reboot are the same
single command, idempotent:

```bash
cd <nexus-root>
agent-sandbox tmux new-session ./watcher
```

Pass `--continue` to resume the prior orchestrator conversation —
the watcher resumes the exact session named by the session-id pin
(`monitor/.state/orchestrator-session-id`) via `claude --resume`;
without a valid pin it starts a fresh session instead (it never
resumes an arbitrary most-recent session):

```bash
agent-sandbox tmux new-session ./watcher --continue
```

## What you should see

Within ~30 seconds of `./watcher` starting:

- The invoking window becomes the `services` cockpit, showing the
  watcher row UP (with its heartbeat age) and any registered
  services.
- An `orchestrator` tmux window appears with the orchestrator running
  its initial pass — spawned by the headless watcher, not by
  `./watcher` itself.
- The watcher's log (`monitor/.state/watcher.log`, cockpit key `0`
  or `monitor/svc.sh logs watcher`) prints heartbeat lines and
  records the first state-change report pasted into the
  `orchestrator` pane.
- On GitHub, the overview issue's body gets a real dashboard
  spliced between the `<!-- NEXUS_DASHBOARD_START -->` markers;
  any preexisting eligible comments get `👀` then `🚀` reactions
  from the bot.

The detailed first-session walkthrough — what to type into the
overview issue, what the bot does, when to look at tmux vs GitHub —
is [First run](first-run.md).

## Troubleshooting the bootstrap

The failure modes you're most likely to hit:

- **`bootstrap-install: not running inside agent-sandbox`** — you
  invoked the script directly instead of through
  `agent-sandbox tmux new-session`. The bootstrap (and the watcher)
  launch Claude Code with `--dangerously-skip-permissions`, which is
  only defensible inside the sandbox. Re-run the launch command from
  the host shell.
- **`bootstrap-install: config/nexus.yml already exists`** — see the
  tip in [Step 2](#step-2-launch-the-install-bootstrap). The
  bootstrap refuses to overwrite an existing config.
- **`gh auth status` reports unauthenticated** — this is **not** a
  blocker. The bot uses its own GitHub App token; personal `gh` is
  only used for the one-time `gh repo create` in Phase 1, which has a
  browser/admin fallback (create the empty private repo at
  `https://github.com/new`). Authenticate with `gh auth login` only
  if you prefer the CLI repo-creation path.
- **`bootstrap-install: project-local Claude Code install failed`** —
  the bootstrap found no `claude` binary and tried to install a
  project-local one, but the npm install did not complete (no
  network, registry hiccup, Node.js older than 18). The lines above
  this message name the exact cause and recovery command; fix that,
  then relaunch the bootstrap — it retries the install.

For failures that surface during the bootstrap's smoke tests
(`mint-token.sh`, `ng preflight`, `ng upload`), see
[GitHub App → Common failure modes](../admin/github-app.md#common-failure-modes).

---

## Manual install (advanced)

If you'd rather not use Claude Code to bootstrap — debugging the
bootstrap itself, running outside agent-sandbox in a different
containment layer, or just preferring a fully manual setup — here
are the same steps in procedural form. The bootstrap performs
exactly this sequence, asking you for each value as it goes.

### M0 — Prerequisites

Confirm these are in place before starting. See [Overview](overview.md#prerequisites)
for the full list and rationale.

- A Linux host you can leave a tmux session running on. Replace
  `<your-host>` below with your hostname.
- [`agent-sandbox`](https://github.com/katosh/agent_sandbox) installed
  per-user (`brew install agent-sandbox` after `brew tap katosh/tools`).
- A GitHub account with admin on a private repo, and the `gh` CLI
  authenticated.
- Standard shell toolkit: `bash`, `tmux`, `git`, `jq`, `openssl`,
  `python3` + `pyyaml`, `curl`.
- Claude Code installed and authenticated (`claude --version` reports
  the binary).

### M1 — Pick a host filesystem

Nexus is the central working directory: `work/` holds project
checkouts (each its own git repo), `reports/` accumulates structured
agent session logs, and intermediate compute artifacts often land
alongside the code. Pick a fast filesystem with quota and IO headroom
— not your home directory.

On an HPC shared cluster the right location is usually a project-
scratch path like `/fast/<lab>/user/<you>/nexus` or
`/scratch/<you>/nexus`. On a personal workstation, a dedicated data
partition or an SSD-backed directory under `~/work/nexus` is fine.
Replace `<your-nexus-root>` with the path you pick.

```bash
export NEXUS_ROOT=<your-nexus-root>/nexus     # used only as a placeholder in this guide
mkdir -p "$(dirname "$NEXUS_ROOT")"
```

### M2 — Clone `<your-org>/nexus-code`

You **clone** `<your-org>/nexus-code` directly — there is **no fork**
to make. The repository carries no per-operator state; every operator
clones the same upstream and `git pull origin main` for updates.

```bash
cd "$(dirname "$NEXUS_ROOT")"
git clone git@github.com:<your-org>/nexus-code.git "$(basename "$NEXUS_ROOT")"
cd "$NEXUS_ROOT"
git remote -v
# → origin    git@github.com:<your-org>/nexus-code.git (fetch)
# → origin    git@github.com:<your-org>/nexus-code.git (push)
```

If you don't have SSH set up against GitHub, the HTTPS clone URL
(`https://github.com/<your-org>/nexus-code.git`) works for the read
path; you'll need a token-or-SSH path before pushing PRs back upstream.

### M3 — Create your asset+issue repo

Nexus separates the **code repo** (`<your-org>/nexus-code`, shared) from
the **asset+issue repo** (private, one per operator). The asset+issue
repo hosts:

- The pinned **`Nexus` overview issue** the bot maintains as a live
  dashboard.
- The **per-thread issues** that track work, decisions, and blocked
  items.
- The **`assets/` tree on `main`** — uploaded reports, embedded images,
  anything `monitor/ng upload` pushes for issue-body rendering.

Create it empty (no README, no `.gitignore`, no licence — the first
asset upload writes the initial commit).

```bash
gh repo create <your-org>/<you>-nexus-assets --private \
    --description "Asset + issue repo for my nexus deployment"
gh repo view <your-org>/<you>-nexus-assets    # confirm it exists
```

The `-assets` suffix is convention, not requirement. Any private repo
you control works as long as no other tool writes to it. Two operators
must not share one — the dashboard, issues, and asset history are
single-tenant.

You'll point `github.repo` at this repo in step M5 and install your
GitHub App on it in step M4. The full rationale for the two-repo
split is in [Admin → Repos](../admin/repos.md).

### M4 — Create and install your GitHub App

The bot writes to GitHub as a **GitHub App**, not a personal access
token. Each operator runs their own App against their own asset+issue
repo. The full walkthrough — App creation, the permission table tied
to grep-verifiable code paths, the webhook sink, the deliveries log
— is in [Admin → GitHub App](../admin/github-app.md). The short
version of what you need to come away with:

| You'll need | Where it comes from |
|---|---|
| `bot_app_id` | The App settings page, top of the page after creation. |
| `bot_installation_id` | The URL after you install the App — `.../installations/<n>`. |
| `bot_pem_path` | A `.pem` private key file you download from the App settings, saved to `~/.claude/<your-bot>.pem` with `chmod 600`. |
| `bot_login` | The App's slug, visible at `https://github.com/apps/<slug>`. The `[bot]` suffix is implicit. |
| `bot_webhook_url` | A `smee.io` channel (or any URL returning 200). GitHub records every delivery in `/app/hook/deliveries` regardless of the receiver's outcome. |
| `bot_webhook_secret_path` | Path to a `chmod 600` file holding the secret you paste into the App settings' Webhook secret field. Slot-prepared for future HMAC verification. |

Install the App on **your asset+issue repo only** (the one you
created in step M3). Do NOT install it on `<your-org>/nexus-code`.
Your bot is per-operator and only ever writes to your own repo.

### M5 — Seed `config/nexus.yml`

`config/nexus.yml` is the single per-operator config file. It is
gitignored; the committed template at `config/nexus.example.yml`
documents every key with inline comments.

```bash
cd "$NEXUS_ROOT"
cp config/nexus.example.yml config/nexus.yml
chmod 600 config/nexus.yml
```

Fill in the minimum-viable set:

| Key | What to set | Notes |
|---|---|---|
| `nexus.root` | Absolute path to the clone (`$NEXUS_ROOT`). | Used by scripts that need to find the workspace from outside it. |
| `github.user_login` | Your GitHub login. | Only this user's comments are eligible directives. |
| `github.repo` | `<your-org>/<you>-nexus-assets` from step M3. | **Not** `<your-org>/nexus-code`. The monitor writes the dashboard here. |
| `github.bot_app_id` | From step M4. | |
| `github.bot_installation_id` | From step M4. | |
| `github.bot_pem_path` | Path to the `.pem` file from step M4. | `~/.claude/<your-bot>.pem` works; `chmod 600`. |
| `github.bot_git_name` | `<your-bot>[bot]` | Visible on asset-repo commits authored by the bot. |
| `github.bot_git_email` | `<your-bot>[bot]@users.noreply.github.com` | Same scope. |
| `github.bot_login` | `<your-bot>` (the slug, no `[bot]`). | Used by the deliveries path (`monitor.deliveries.bot_mention_enabled`) and cross-repo mention gating. |
| `github.bot_webhook_url` | The `smee.io` channel from step M4. | Documentation-only today; the watcher reads `/app/hook/deliveries` directly. |
| `github.bot_webhook_secret_path` | Path to the `chmod 600` secret file from step M4. | Slot-prepared for future HMAC verification. |

`github.asset_repo` defaults to `github.repo` — leave commented
unless you intentionally want assets in a separate repo from issues
(rare).

Notification keys (`notifications.pushover.*`, `notifications.ntfy.*`,
`notifications.email.*`) are optional. With nothing configured, the
helper silently no-ops, so you can defer this until
[Operating → Notifications](../operating/notifications.md).

Every key is documented inline in `config/nexus.example.yml`; the
canonical [Config reference](../reference/config.md) is searchable.

### M6 — Verify the wiring

Three independent smoke tests. Each is re-runnable; if one fails,
fix the cause and re-run before moving on.

```bash
cd "$NEXUS_ROOT"
./monitor/ng issue 1
# expected: `#1 state=... title=...` or `ng: not found` — either proves
# the token mints and the App resolves your asset+issue repo.

./monitor/ng preflight "$(./config/load.sh github.repo)"
# expected: `bot installed yes`. A `no` means the App is not installed
# on your asset+issue repo — re-do step M4's install step.

./monitor/ng upload README.md --message "preflight"
# expected: a URL of the form
# https://github.com/<your-org>/<you>-nexus-assets/blob/<sha>/assets/general/README.md
# This commits one file to your asset repo's main branch; safe to
# delete via the GitHub UI afterwards if you want a clean history.
```

All three passing means: the bot is minting tokens, can read your
asset+issue repo, and can push commits to it. If any fail, see
[Admin → GitHub App → Common failure modes](../admin/github-app.md#common-failure-modes)
for the symptom-to-fix table.

### M7 — Verify webhook deliveries

Trigger any subscribed event in your asset+issue repo:

1. Open any issue in `github.repo`.
2. Add a `:thumbsup:` reaction to the issue body.
3. Wait ~5 s for GitHub to record the delivery.

Then run the deliveries probe:

```bash
JWT=$(./monitor/mint-token.sh --jwt-only)
curl -sS \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/hook/deliveries?per_page=3" \
  | jq '.[].event, .[].status_code'
```

The newest entry should show `"issues"` (or `issue_comment`, …) and
a status code. `200` means smee delivered; non-200 means the smee
channel is unreachable but GitHub still recorded the delivery (fine
— the watcher reads from `/app/hook/deliveries`, not from the URL).

If the array stays empty, the App isn't subscribed to the event you
triggered. Re-check [GitHub App → Step 5](../admin/github-app.md#step-5-subscribe-to-events)
against the App settings page's "Subscribe to events" block.

### M8 — Seed the overview issue

If you ran the bootstrap (`./monitor/bootstrap-install.sh`), Phase 5
already created the labels and the overview issue under the bot's
installation token — skip ahead to M9. This section is the manual
fallback: skipped-bootstrap, recovery from a half-finished install,
or a hand-curated re-run.

The monitor discovers the dashboard issue **by label**, not by title
or number. One-time setup on the asset+issue repo:

1. Create the label `nexus:overview` (mandatory). The bootstrap also
   creates `nexus:active`, `nexus:decision`, and `nexus:blocked` as
   thread-organising defaults — do the same if you want parity with
   the reference deployment.
2. Open a new issue titled `Nexus`, apply the `nexus:overview` label,
   and paste a placeholder body that includes the dashboard markers:

    ```markdown
    <!-- NEXUS_DASHBOARD_START -->
    _dashboard not yet populated_
    <!-- NEXUS_DASHBOARD_END -->
    ```

3. Pin the issue so it stays at the top of the Issues tab.

On its first run the orchestrator splices the dashboard between the
markers via `monitor/ng dashboard put`; the placeholder body is what
makes the splice idempotent.

### M9 — Launch the sandboxed nexus session

Inside `tmux` on `<your-host>`, from the nexus root:

```bash
cd "$NEXUS_ROOT"
agent-sandbox tmux new-session ./watcher
```

`./watcher` is the workspace entry point (a symlink to
`monitor/watcher/entry.sh`; `./nexus` is an equivalent alias). It:

1. Self-checks that it's running inside tmux + agent-sandbox.
2. Brings up the stack via `monitor/svc.sh up`: the watcher launches
   as a headless service (setsid-detached, log at
   `monitor/.state/watcher.log`), plus every service registered in
   `monitor/services.registry`.
3. The watcher then spawns the orchestrator (`orchestrator` window)
   itself, within a few probe cycles (~10 s).
4. Renames the current window to `services` and execs the read-only
   `monitor/svc.sh` cockpit in it — the live stack view.

agent-sandbox layers a bubblewrap filesystem namespace,
libcap-restricted Linux capabilities, and seccomp syscall filters
over the Claude Code session. Writes are limited to the workspace
directory and `~/.claude/`; network and compute side-effects are
not bounded. See [Admin → Security](../admin/security.md) for the
full sandbox model.

The orchestrator launches with `--dangerously-skip-permissions`.
Combined with agent-sandbox the filesystem blast radius is bounded;
for everything else the bot's authorization tiers (internal /
user-public / external-public) gate writes — see the `## GitHub
writes — identity and authorization` section of
[`CLAUDE.md`](https://github.com/<your-org>/nexus-code/blob/main/CLAUDE.md).

### M10 — Resume after an SSH drop or restart

The single command is the same every time, including after a crash
or a host reboot:

```bash
cd "$NEXUS_ROOT"
agent-sandbox tmux new-session ./watcher
```

`./watcher`'s startup is idempotent: a healthy watcher and live
services are left alone, and the watcher skips the orchestrator
spawn if the `orchestrator` window already exists. Pass `--continue`
to resume the prior orchestrator conversation:

```bash
agent-sandbox tmux new-session ./watcher --continue
```

With `--continue` the watcher resumes the exact session named by the
orchestrator session-id pin (`monitor/.state/orchestrator-session-id`)
via `claude --resume <sid>`, regardless of age. When the pin is
missing or its session log is gone, the watcher starts a fresh
session instead, with a one-line note — it never resumes an
arbitrary most-recent session. Without the flag, every invocation is
a fresh session (an existing pin is archived, not deleted).

## Where to next

- [First run](first-run.md) walks through your first nexus session
  end-to-end.
- [Concepts](concepts.md) defines every term used elsewhere on this
  site.
- [Admin → GitHub App](../admin/github-app.md) is the deep-dive for
  step M4.
