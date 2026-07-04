# Configuration

Every key the nexus monitor honours, what it does, what it defaults
to, the environment variable that overrides it, and a runnable example.

The single source of truth is `config/nexus.yml` in your nexus
checkout. Copy `config/nexus.example.yml` to `config/nexus.yml`,
`chmod 600`, and edit each value to match your environment.
See [Install](../getting-started/install.md) for the bootstrap walkthrough.

## How config is loaded

Values flow through a small ladder; the first match wins:

```
1. Process-local env var      (e.g. MONITOR_INTERVAL, NEXUS_ROOT)
2. config/nexus.yml           (the canonical site config)
3. Script default             (each script names its own fallback)
```

`config/load.sh <dotted.key> [default]` resolves a single value;
every script in `monitor/` calls it for each configurable knob.
Env-var overrides are intentional escape hatches — they let an
operator restart the watcher with a snappier `MONITOR_INTERVAL` for
a debugging session without editing the file. The mapping between
env vars and config keys is listed against each key below.

Paths starting with `~` expand against `$HOME`. Secret files
(`.pem`, Pushover keys, webhook secrets, …) must be `chmod 600`;
the scripts refuse to read group/world-readable secret files.

## Variables index

| Key | Type | Env override | Default |
|---|---|---|---|
| [`nexus.root`](#nexusroot) | path | `NEXUS_ROOT` | — (required) |
| [`nexus.node_module`](#nexusnode_module) | string | `NEXUS_NODE_MODULE` | `nodejs` |
| [`github.user_login`](#githubuser_login) | string | `MONITOR_USER_LOGIN` | — (required) |
| [`github.repo`](#githubrepo) | `owner/name` | `MONITOR_REPO` | — (required) |
| [`github.asset_repo`](#githubasset_repo) | `owner/name` | `NEXUS_ASSET_REPO` | falls back to `github.repo` |
| [`github.bot_app_id`](#githubbot_app_id) | int | `NEXUS_BOT_APP_ID` | — (required) |
| [`github.bot_installation_id`](#githubbot_installation_id) | int | `NEXUS_BOT_INSTALLATION_ID` | — (required) |
| [`github.bot_pem_path`](#githubbot_pem_path) | path | `NEXUS_BOT_PRIVATE_KEY_PATH` | — (required) |
| [`github.bot_token_cache`](#githubbot_token_cache) | path | `NEXUS_BOT_TOKEN_CACHE` | `~/.claude/.nexus-bot-token.json` |
| [`github.bot_git_name`](#githubbot_git_name) | string | — | legacy fallback (see entry) |
| [`github.bot_git_email`](#githubbot_git_email) | email | — | legacy fallback (see entry) |
| [`github.bot_login`](#githubbot_login) | string | `MONITOR_BOT_LOGIN` | empty |
| [`github.bot_webhook_url`](#githubbot_webhook_url) | URL | — | empty |
| [`github.bot_webhook_secret_path`](#githubbot_webhook_secret_path) | path | — | empty |
| [`github.overview_issue_number`](#githuboverview_issue_number) | int | — | unset (live-resolved) |
| [`notifications.pushover.user_key_path`](#notificationspushoveruser_key_path) | path | `NEXUS_PUSHOVER_USER_KEY_FILE` | unset |
| [`notifications.pushover.app_token_path`](#notificationspushoverapp_token_path) | path | `NEXUS_PUSHOVER_APP_TOKEN_FILE` | unset |
| [`notifications.ntfy.topic_url_path`](#notificationsntfytopic_url_path) | path | `NEXUS_NOTIFY_TOKEN` | unset |
| [`notifications.email.address`](#notificationsemailaddress) | email | `NEXUS_EMAIL_TO` | — (required for email tier) |
| [`notifications.email.probe_address`](#notificationsemailprobe_address) | email\|`null` | — | `null` (probes go to `address`) |
| [`notifications.email.smtp_host`](#notificationsemailsmtp_host) | host | `NEXUS_SMTP_HOST` | — (`smtp.example.org` placeholder) |
| [`notifications.email.smtp_port`](#notificationsemailsmtp_port) | int | `NEXUS_SMTP_PORT` | `25` |
| [`monitor.interval_seconds`](#monitorinterval_seconds) | int (s) | `MONITOR_INTERVAL` | `60` |
| [`monitor.target_window`](#monitortarget_window) | string | `MONITOR_TARGET` | `orchestrator` |
| [`monitor.diff_retention_days`](#monitordiff_retention_days) | int (d) | `DIFF_RETENTION_DAYS` | `7` |
| [`monitor.idle_threshold_seconds`](#monitoridle_threshold_seconds) | int (s) | `MONITOR_IDLE_THRESHOLD_SECONDS` | `60` |
| [`monitor.idle_close_hours`](#monitoridle_close_hours) | int (h) | `MONITOR_IDLE_CLOSE_HOURS` | `24` |
| [`monitor.report_min_chars`](#monitorreport_min_chars) | int | `MONITOR_REPORT_MIN_CHARS` | `500` |
| [`monitor.agent_dead_threshold`](#monitoragent_dead_threshold) | int | `AGENT_DEAD_THRESHOLD` | `3` |
| [`monitor.respawn_loop_limit`](#monitorrespawn_loop_limit) | int | `MONITOR_RESPAWN_LOOP_LIMIT` | `3` |
| [`monitor.respawn_loop_window_seconds`](#monitorrespawn_loop_window_seconds) | int (s) | `MONITOR_RESPAWN_LOOP_WINDOW` | `120` |
| [`monitor.deliveries.asset_enabled`](#monitordeliveriesasset_enabled) | bool | `MONITOR_DELIVERIES_ASSET_ENABLED` | `true` |
| [`monitor.deliveries.bot_mention_enabled`](#monitordeliveriesbot_mention_enabled) | bool | `MONITOR_DELIVERIES_BOT_MENTION_ENABLED` | `true` |
| [`monitor.mentions_enabled`](#monitormentions_enabled) | bool | `MONITOR_MENTIONS_ENABLED` | `false` |
| [`monitor.graphql_threshold`](#monitorgraphql_threshold) | int (pts) | `MONITOR_GRAPHQL_THRESHOLD` | `200` |
| [`monitor.skeptic.enforce_auto_decision`](#monitorskeptic) | bool | `MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION` | `true` |
| [`monitor.skeptic.findings_threshold`](#monitorskeptic) | int | `MONITOR_SKEPTIC_FINDINGS_THRESHOLD` | `1` |
| [`monitor.skeptic.max_depth`](#monitorskeptic) | int | `MONITOR_SKEPTIC_MAX_DEPTH` | `3` |
| [`monitor.skeptic.await_timeout_seconds`](#monitorskeptic) | int (s) | `MONITOR_SKEPTIC_AWAIT_TIMEOUT_SECONDS` | `900` |
| [`monitor.skeptic.await_interval_seconds`](#monitorskeptic) | int (s) | `MONITOR_SKEPTIC_AWAIT_INTERVAL_SECONDS` | `5` |
| [`monitor.skeptic.await_hang_seconds`](#monitorskeptic) | int (s) | `MONITOR_SKEPTIC_AWAIT_HANG_SECONDS` | `600` |
| [`monitor.watcher.auto_unstick`](#monitorwatcherauto_unstick) | bool | `MONITOR_AUTO_UNSTICK` | `true` |
| [`monitor.watcher.ratelimit_probe`](#monitorwatcherratelimit_probe) | bool | `MONITOR_RATELIMIT_PROBE` | `false` |
| [`monitor.watcher.probe_model`](#monitorwatcherprobe_model) | string | `MONITOR_PROBE_MODEL` | `claude-haiku-4-5-20251001` |
| [`monitor.watcher.ratelimit_heuristic_minutes`](#monitorwatcherratelimit_heuristic_minutes) | int (min) | `MONITOR_RATELIMIT_HEURISTIC_MIN` | `30` |
| [`monitor.watcher.ratelimit_ack_timeout_s`](#monitorwatcherratelimit_ack_timeout_s) | int (s) | `MONITOR_RATELIMIT_ACK_TIMEOUT_S` | `60` |
| [`monitor.watcher.api_error_backoff_minutes`](#monitorwatcherapi_error_backoff_minutes) | int (min) | `MONITOR_API_ERROR_BACKOFF_MIN` | `30` |
| [`monitor.watcher.paste_response_grace_seconds`](#monitorwatcherpaste_response_grace_seconds) | int (s) | `MONITOR_ORCH_PASTE_RESPONSE_GRACE_S` | `120` |
| [`monitor.watcher.unstick_window_seconds`](#monitorwatcherunstick_window_seconds) | int (s) | `MONITOR_ORCH_UNSTICK_WINDOW_S` | `150` |
| [`monitor.watcher.orchestrator_dead_threshold_seconds`](#monitorwatcherorchestrator_dead_threshold_seconds) | int (s) | `MONITOR_ORCH_DEAD_THRESHOLD_S` | `300` |
| [`monitor.watcher.stale_paste_ceiling_seconds`](#monitorwatcherstale_paste_ceiling_seconds) | int (s) | `MONITOR_ORCH_STALE_PASTE_CEILING_S` | `1800` |
| [`monitor.watcher.dead_threshold_floor_margin_seconds`](#monitorwatcherdead_threshold_floor_margin_seconds) | int (s) | `MONITOR_ORCH_DEAD_THRESHOLD_FLOOR_MARGIN_S` | `60` |
| [`monitor.watcher.idle_pane_override_max`](#monitorwatcheridle_pane_override_max) | int | `MONITOR_ORCH_IDLE_OVERRIDE_MAX` | `5` |
| [`monitor.watcher.liveness_log_throttle_seconds`](#monitorwatcherliveness_log_throttle_seconds) | int (s) | `MONITOR_ORCH_LIVENESS_LOG_THROTTLE_S` | `30` |
| [`monitor.version_restart.enabled`](#monitorversion_restart) | bool | `MONITOR_VERSION_RESTART_ENABLED` | `true` |
| [`monitor.version_restart.interval_seconds`](#monitorversion_restart) | int (s) | `MONITOR_VERSION_CHECK_INTERVAL_SECONDS` | `60` |
| [`monitor.version_restart.settle_seconds`](#monitorversion_restart) | int (s) | `MONITOR_VERSION_SETTLE_SECONDS` | `45` |
| [`monitor.version_restart.cooldown_seconds`](#monitorversion_restart) | int (s) | `MONITOR_VERSION_RESTART_COOLDOWN_SECONDS` | `600` |
| [`monitor.version_restart.self`](#monitorversion_restart) | bool | `MONITOR_VERSION_SELF_RESTART` | `true` |
| [`monitor.version_restart.services`](#monitorversion_restart) | bool | `MONITOR_VERSION_SERVICE_RESTART` | `true` |
| [`monitor.version_restart.self_loop_limit`](#monitorversion_restart) | int | `MONITOR_VERSION_SELF_LOOP_LIMIT` | `3` |
| [`monitor.version_restart.self_loop_window_seconds`](#monitorversion_restart) | int (s) | `MONITOR_VERSION_SELF_LOOP_WINDOW_SECONDS` | `3600` |

The worker-lifecycle / engagement keys (`monitor.retain_ttl_seconds`,
`monitor.operator_engaged_*`, `monitor.paste_confirm_grace_seconds`,
`monitor.idle_pool_spawn_grace_seconds`, `monitor.over_limit.*`, …)
are tabulated with their defaults and exact semantics in the
[agent state machine](https://github.com/<your-org>/nexus-code/blob/main/monitor/docs/agent-state-machine.md)
"Switching conditions and times" table — the single source of truth
for lifecycle thresholds, deliberately not duplicated here.

Two env vars have no corresponding YAML key:

| Env var | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic API key for the case-B rate-limit reset probe. Read only from the environment; never persisted to config. Required when `monitor.watcher.ratelimit_probe: true`. |
| `NEXUS_ASSET_BRANCH` | Branch that `monitor/upload-asset.sh` pushes to in the asset repo (default `main`). Operationally a knob, not a site policy — kept env-only. |

---

## `nexus`

### `nexus.root`

**Type** path · **Env** `NEXUS_ROOT` · **Default** — (required)

Absolute path to the nexus workspace root (the directory holding
`monitor/`, `work/`, `reports/`, …). Scripts use it to resolve
`monitor/.state/`, the assets clone, the reports dir, and the
per-project `work/<project>/` checkouts.

```yaml
nexus:
  root: /home/<you>/nexus
```

### `nexus.node_module`

**Type** string · **Env** `NEXUS_NODE_MODULE` · **Default** `nodejs`

Environment-module name that provides Node.js, for HPC hosts where
`node` is not on the default `PATH` but is available via Lmod / Tcl
environment-modules (e.g. <your-institution> <cluster>: `module load nodejs`).
`monitor/install-claude-local.sh` consults this **only** when `node`
is absent: it sources the module init, `module load`s this name (then
falls back to discovering the highest `>=18` versioned module if the
site has no default), and re-checks. Leave as the default `nodejs`
for FH <cluster> and most EasyBuild sites; override only if your site's
node module is named differently. No effect on hosts where `node` is
already on `PATH`. Env var `NEXUS_NODE_MODULE` wins over this key.

---

## `github`

### `github.user_login`

**Type** string · **Env** `MONITOR_USER_LOGIN` · **Default** — (required)

GitHub login of the single authorised operator. The watcher only
surfaces issues and comments authored by this user; the bot rejects
everything else as a security boundary (see
[Security](../admin/security.md)).

`ng pr create` also auto-requests this login as the reviewer on
bot-opened PRs, so it must resolve to a real GitHub collaborator on
`github.repo` — otherwise the `request_reviewers` POST returns 422
and every PR open emits a warning naming the unfilled placeholder.

### `github.repo`

**Type** `owner/name` · **Env** `MONITOR_REPO` · **Default** — (required)

The asset+issue repo the watcher polls and the bot writes to — issues,
overview body, dashboard reactions. This is **your** per-operator
state repo, **not** the canonical implementation repo
`<your-org>/nexus-code` (which is read-only for non-maintainers).

Convention: `<your-org>/<your-handle>-nexus-assets` (private). One
asset+issue repo per operator; nothing in the implementation repo
hard-codes its name.

### `github.asset_repo`

**Type** `owner/name` · **Env** `NEXUS_ASSET_REPO` · **Default** falls back to `github.repo`

Repo where `monitor/upload-asset.sh` pushes uploaded assets (reports,
PNGs, PDFs, notebooks …). Defaults to `github.repo`; leave commented
unless you want assets in a separate repo.

`monitor/upload-asset.sh` clones this to `<nexus.root>/assets/`
(gitignored) and pushes new files to its `main` branch under
`assets/<issue-N>/…` or `assets/general/…`. URLs returned by
`ng upload` are pinned to the post-push commit SHA, so subsequent
overwrites do not change what an old URL resolves to. See
[`ng upload`](ng-cli.md#ng-upload).

### `github.bot_app_id`

**Type** int · **Env** `NEXUS_BOT_APP_ID` · **Default** — (required)

Numeric App ID of the GitHub App that authors bot writes. Visible on
the App's settings page. See [GitHub App setup](../admin/github-app.md)
for App creation, permission grants, and installation.

### `github.bot_installation_id`

**Type** int · **Env** `NEXUS_BOT_INSTALLATION_ID` · **Default** — (required)

Numeric installation ID for the App on `github.repo`. Pinning the
installation ID lets `monitor/mint-token.sh` skip a discovery call
on every token mint.

### `github.bot_pem_path`

**Type** path · **Env** `NEXUS_BOT_PRIVATE_KEY_PATH` · **Default** — (required)

Path to the App's RSA private key (PEM). `chmod 600`; scripts refuse
to read it otherwise. Used by `monitor/mint-token.sh` to sign the
App-level JWT exchanged for an installation token.

### `github.bot_token_cache`

**Type** path · **Env** `NEXUS_BOT_TOKEN_CACHE` · **Default** `~/.claude/.nexus-bot-token.json`

Cache file for the minted installation token (+ its expiry). Tokens
live ~1 h; `mint-token.sh` reuses the cached token until ~5 min
before expiry, then mints a fresh one. Safe to delete to force a
fresh mint on the next call.

### `github.bot_git_name`

**Type** string · **Default** legacy fallback (a pre-cutover bot name)

Git author name used on bot-side commits — currently the asset
pushes in `monitor/upload-asset.sh`. GitHub's convention for App
commits is `<app-slug>[bot]`. Find the slug in
`https://github.com/apps/<slug>`. Leaving this unset falls back to
a legacy default baked into `upload-asset.sh` for back-compat with
pre-cutover installs; new deployments should always set this key
explicitly.

### `github.bot_git_email`

**Type** email · **Default** legacy fallback (matching `bot_git_name`)

Git author email for bot-side commits. GitHub's noreply form
(`<slug>[bot]@users.noreply.github.com`) keeps the commit attributable
to the App in the GitHub UI without exposing a real mailbox.

### `github.bot_login`

**Type** string · **Env** `MONITOR_BOT_LOGIN` · **Default** empty

The bot's GitHub login **slug** (no `[bot]` suffix). Informational
since issue #86 retired the bot-mention dispatch in
`_deliveries.sh` — the watcher now restricts every comment path to
`github.user_login`-authored content via the
`_filter_to_user_author` chokepoint, so non-user `@bot` mentions
are an accepted loss. The slug is kept for operator reference.

### `github.bot_webhook_url`

**Type** URL · **Default** empty

GitHub App webhook URL. The watcher does **not** POST to this URL —
GitHub does. Setting any reachable URL on the App settings page is
what makes GitHub retain every delivery in `/app/hook/deliveries`,
which the watcher reads with the App JWT.

Any inert sink works: a [smee.io](https://smee.io) channel, a
Cloudflare Worker returning 200, eventually a self-hosted receiver.
This key is documentation-only today; the slot exists so the URL is
recorded in the same place as everything else.

### `github.bot_webhook_secret_path`

**Type** path · **Default** empty

Path to a file holding the webhook HMAC secret (matching the value
pasted into the App settings' "Webhook secret" field). `chmod 600`.
Generate with `openssl rand -hex 32`.

The watcher does not read this file today — it trusts GitHub's
deliveries log over an authenticated channel. The slot is here so
secret rotation becomes a config change rather than a code change
once a self-hosted receiver verifies HMAC signatures locally.

### `github.overview_issue_number`

**Type** int · **Default** unset (live-resolved)

Pin the overview issue number to avoid the labelled-issue lookup that
`ng dashboard` and friends would otherwise run on every call. GitHub's
label index is eventually consistent and returns empty results during
high write activity, so pinning is the cheapest robustness fix. Set
to the integer (no `#`) of your overview issue.

Unset, `ng` does a 3-attempt retry on the live label query and caches
the result in `monitor/.state/overview-number` for the life of the
state dir.

`github.overview_issue_number` is the canonical key — it is what
`config/nexus.example.yml` documents and what the resolver in `ng`
reads (the `_overview_number` lookup and the dashboard scaffold).
One `ng dashboard --upsert-overview` code path reads a differently
spelled `github.overview_issue` (no `_number` suffix, default `1`)
instead; that second spelling is **not** a documented key and falls
through to its hard-coded `1` default for every operator whose
overview is not issue `#1`. Set `overview_issue_number` (the correct
key) and treat any bare `overview_issue` as inert.

---

## `notifications`

Both Pushover and ntfy are optional; with neither configured,
`monitor/notify.sh` silently no-ops so scripts can call it
unconditionally.

### `notifications.pushover.user_key_path`

**Type** path · **Env** `NEXUS_PUSHOVER_USER_KEY_FILE` · **Default** unset

File whose first line is the Pushover **user key** from
[pushover.net](https://pushover.net). `chmod 600`.

### `notifications.pushover.app_token_path`

**Type** path · **Env** `NEXUS_PUSHOVER_APP_TOKEN_FILE` · **Default** unset

File whose first line is the Pushover **application token** from
[pushover.net/apps/build](https://pushover.net/apps/build). `chmod 600`.

### `notifications.ntfy.topic_url_path`

**Type** path · **Env** `NEXUS_NOTIFY_TOKEN` · **Default** unset

Fallback push channel. File's first line holds the full ntfy topic
URL (e.g. `https://ntfy.sh/<unguessable-topic>`). The topic name is a
bearer secret on `ntfy.sh`'s public instance — choose something
unguessable.

### `notifications.email.address`

**Type** email · **Env** `NEXUS_EMAIL_TO` · **Default** — (required for email tier)

Where emergency-tier emails go (production address). Used by
`monitor/notify.sh` when push is unavailable or the alert tier is
"emergency".

### `notifications.email.probe_address`

**Type** email \| `null` · **Default** `null`

Optional disposable alias for liveness probes (the daily watcher
probe email, …). Set to `null` to send probes to `address` instead.

**Reserved; not yet consumed.** No script reads this key today —
`monitor/notify.sh` routes every tier (probes included) to
`address`. The slot is recorded here and in the example config so
that when a separate probe channel lands it is a config change, not
a code change.

### `notifications.email.smtp_host`

**Type** host · **Env** `NEXUS_SMTP_HOST` · **Default** — (`smtp.example.org` is the example-config placeholder, not a code fallback)

Outbound SMTP relay. Must accept mail from this host without auth.
Set to whatever your institution's relay is. `monitor/notify.sh` has
no built-in default — the `smtp.example.org` shown here is the
placeholder shipped in `config/nexus.example.yml`, which will not
deliver mail; replace it before relying on the email tier.

### `notifications.email.smtp_port`

**Type** int · **Env** `NEXUS_SMTP_PORT` · **Default** `25`

SMTP port. Adjust if your relay uses submission (587) or implicit TLS
(465). `monitor/notify.sh` does not negotiate STARTTLS today — pick
an unauthenticated relay your host can reach.

---

## `monitor`

### `monitor.interval_seconds`

**Type** int (s) · **Env** `MONITOR_INTERVAL` · **Default** `60`

Seconds the watcher sleeps between snapshots. Lower values surface
events faster at the cost of GraphQL points and CPU.

### `monitor.target_window`

**Type** string · **Env** `MONITOR_TARGET` · **Default** `orchestrator`

Name of the tmux window the watcher pastes snapshots into. Default
matches the workspace convention for the orchestrator window
(self-enforced by the orchestrator's session-pin hook, which renames
the hosting window to `orchestrator` and disables tmux's
`automatic-rename` on first turn). The watcher respawns a fresh
orchestrator session (the `claude` CLI) in this window if it goes
missing for `monitor.agent_missing_respawn_delay` consecutive
confirming polls (see
[`monitor.agent_dead_threshold`](#monitoragent_dead_threshold)).
Stack recovery (`bootstrap-recover.sh`) additionally pins this
window to the canonical tmux index `monitor.target_window_index`
(default `2`) — non-destructively: an occupied slot is logged, never
stolen.

### `monitor.diff_retention_days`

**Type** int (d) · **Env** `DIFF_RETENTION_DAYS` · **Default** `7`

Days before archived snapshot diffs under `monitor/.state/diffs/` are
pruned. Set higher to retain a longer audit window; lower to bound
disk use.

### `monitor.idle_threshold_seconds`

**Type** int (s) · **Env** `MONITOR_IDLE_THRESHOLD_SECONDS` · **Default** `60`

A worker tmux window is "really idle" when its `#{window_activity}`
age crosses this threshold AND `monitor/pane-state.sh` reports
`idle` / `autosuggest-only` / `empty`. The threshold is independent
of the tmux bell flag (which clears on view, so bell-clear ≠ idle).

### `monitor.idle_close_hours`

**Type** int (h) · **Env** `MONITOR_IDLE_CLOSE_HOURS` · **Default** `24`

Hard-close threshold for the same probe: a window idle for ≥ this
many hours surfaces as `idle-too-long` and the orchestrator defaults
to closing it. Retention overrides (recent user engagement, loaded
kernel cost) still apply. Raise for long-running observational
workers.

### `monitor.report_min_chars`

**Type** int · **Env** `MONITOR_REPORT_MIN_CHARS` · **Default** `500`

Minimum body length (chars, excluding frontmatter) for
[`ng report-check`](ng-cli.md#ng-report-check) to accept a report.
Guards against stub asset uploads by gating
[`ng wrap-up`](ng-cli.md#ng-wrap-up) on a substantive report. Lower
for noisier projects; the default catches placeholder
`# title \n_(later)_` skeletons.

### `monitor.agent_dead_threshold`

**Type** int · **Env** `AGENT_DEAD_THRESHOLD` · **Default** `3`

Reserved for the slow-path "window present, agent silent" detector
(not yet wired in). The fast path — target window confirmed *absent*
— is governed by `monitor.agent_missing_respawn_delay` (env
`AGENT_MISSING_RESPAWN_DELAY`, default `3`): that many consecutive
absent observations (~8 s at the probe cadence), plus a pre-launch
re-verification, before the watcher launches a fresh orchestrator
(`claude` CLI) session in [`target_window`](#monitortarget_window).
The window-present-but-inert case is handled by the hook-driven
liveness state machine (`monitor.watcher.*` liveness keys; see
[`monitor/README.md` § Mutual-liveness contract](https://github.com/<your-org>/nexus-code/blob/main/monitor/README.md#mutual-liveness-contract)).

### `monitor.respawn_loop_limit`

**Type** int · **Env** `MONITOR_RESPAWN_LOOP_LIMIT` · **Default** `3`

Crash-loop guard for orchestrator respawns. If more than this many
respawns happen within
[`respawn_loop_window_seconds`](#monitorrespawn_loop_window_seconds),
the watcher stops respawning until the sliding window empties or a
paste-to-target succeeds (which clears the history). One
`sandbox-notify` fires on the `ok → tripped` transition, then quiet.
Set to a large value (e.g. `999`) to effectively disable.

### `monitor.respawn_loop_window_seconds`

**Type** int (s) · **Env** `MONITOR_RESPAWN_LOOP_WINDOW` · **Default** `120`

Sliding-window length (seconds) for the
[`respawn_loop_limit`](#monitorrespawn_loop_limit) guard.

### `monitor.deliveries.asset_enabled`

**Type** bool · **Env** `MONITOR_DELIVERIES_ASSET_ENABLED` · **Default** `true`

Gate the **in-`github.repo` (asset-nexus) deliveries emit path** — the
`issue=`/`pr=`/`pr_review=`/`issue_new=` shapes that surface operator
comments on the asset repo within ~15 s, no @bot-mention required. The
near-real-time complement to the always-on `snapshot_github` poll (the
~600 s asset baseline, untouched by this flag). Set `false` to opt out.

The deliveries-polling source reads `/app/hook/deliveries` (the App's
webhook delivery log) on a separate auth bucket (App-level JWT). It is
active when this flag OR
[`deliveries.bot_mention_enabled`](#monitordeliveriesbot_mention_enabled)
is on, and degrades to a clean no-op when the App has no webhook URL
configured. Effective surfacing needs:

1. The App has a webhook URL configured (any inert sink — smee.io
   channel, Cloudflare Worker returning 200, …). GitHub records every
   delivery in the log regardless of receiver outcome; the watcher
   reads from the log, not from the URL.
2. The App is subscribed to the events the watcher folds into its
   line shapes: `issue_comment`, `pull_request_review_comment`,
   `pull_request_review`, `issues`, `pull_request`.

Only `USER_LOGIN`-authored events surface (issue #86's universal
user-author filter via the `_filter_to_user_author` chokepoint).

> A stale `monitor.deliveries_enabled` key (the removed pre-split
> umbrella) is silently ignored — set the two `deliveries.*` flags
> instead.

See [Watcher protocol](watcher-protocol.md) for the line-shape
vocabulary and dedup rules between this path and the GraphQL search.

### `monitor.deliveries.bot_mention_enabled`

**Type** bool · **Env** `MONITOR_DELIVERIES_BOT_MENTION_ENABLED` · **Default** `true`

Gate the **cross-repo `mention=` deliveries emit path** — @bot-mentions
the operator posts on App-installed repos other than `github.repo`,
discovered via the App webhook delivery log. Set `false` to opt out.
This is the webhook-based channel; `monitor.bot_mentions_enabled` is the
webhook-FREE GraphQL-poll equivalent for the same concern — running both
is safe (cross-source `id=` duplicates collapse in the dedup hop). If the
App has no webhook URL configured, the deliveries path 404s and this flag
is moot; the poll channel covers it.

### `monitor.mentions_enabled`

**Type** bool · **Env** `MONITOR_MENTIONS_ENABLED` · **Default** `false`

Enable the **mentions-search fallback path**. When `true`, the watcher
runs an additional GraphQL search each cycle for issues/PRs that
@-mention [`github.user_login`](#githubuser_login) (NOT `bot_login` —
that qualifier does not index `[bot]` accounts).

Scope: cross-repo activity in repos where the App is NOT installed —
the gap that the deliveries path can't reach. Complementary to the
deliveries path; safe to enable both.

Routing logic should treat `cross_repo=` events as **read-only
context** until the bot is installed on the referenced repo (the bot
cannot comment back from a repo it isn't installed on). Cost: one
GraphQL search call per poll cycle (50 results) plus one
`/installation/repositories` call per 24 h to refresh the cache at
`monitor/.state/bot-installed-repos.txt`.

### `monitor.graphql_threshold`

**Type** int (points) · **Env** `MONITOR_GRAPHQL_THRESHOLD` · **Default** `200`

Minimum GraphQL remaining points before the watcher will issue any
GraphQL search. Below this, GraphQL polling is skipped for that
cycle (per-surface — both `issue_comments` and `mentions` are gated).
The deliveries path keeps surfacing events on its separate bucket
while the GraphQL bucket replenishes. The default leaves headroom
for orchestrator + worker writes during the cycle.

---

## `monitor.skeptic`

Knobs for the universal skeptic protocol (`skills/nexus.skeptic`) —
the independent, adversarial validation pass a worker's result may
require. The wrap-up enforcement and the recursion bound live in
[`monitor/ng`](https://github.com/<your-org>/nexus-code/blob/main/monitor/ng);
the worker↔skeptic comms channel (`await`/`answer`) lives in
[`monitor/skeptic-channel.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/skeptic-channel.sh);
the await-hang exemption lives in the idle probe. Each key resolves
through the standard env → `config/load.sh` → inline-default ladder.

| Key | Type | Env override | Default | Governs |
|---|---|---|---|---|
| `enforce_auto_decision` | bool | `MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION` | `true` | When truthy, `ng wrap-up` refuses to complete an `auto`-mode hand-off until the worker has recorded a skeptic decision — the wrap-up gate. |
| `findings_threshold` | int | `MONITOR_SKEPTIC_FINDINGS_THRESHOLD` | `1` | Minimum substantive new findings in a skeptic pass to warrant a further recursive pass. Floored at `1` (a `0` would recommend a second pass on a clean run, defeating the diminishing-returns rule). |
| `max_depth` | int | `MONITOR_SKEPTIC_MAX_DEPTH` | `3` | Recursion cap on the skeptic chain. Depth strictly increments and is capped, so the chain terminates after at most `max_depth + 1` passes. |
| `await_timeout_seconds` | int (s) | `MONITOR_SKEPTIC_AWAIT_TIMEOUT_SECONDS` | `900` | Per-call ceiling for `skeptic-channel.sh await`; a single blocking call is bounded by this, then exits (the worker re-enters await, which re-heartbeats). |
| `await_interval_seconds` | int (s) | `MONITOR_SKEPTIC_AWAIT_INTERVAL_SECONDS` | `5` | Poll cadence inside the `await` loop. |
| `await_hang_seconds` | int (s) | `MONITOR_SKEPTIC_AWAIT_HANG_SECONDS` | `600` | Idle-probe exemption window: a worker parked in `await` is not treated as hung until its pane has been static past this threshold. |

---

## `monitor.watcher`

### `monitor.watcher.auto_unstick`

**Type** bool · **Env** `MONITOR_AUTO_UNSTICK` · **Default** `true`

Auto-resolve stalled agent prompts. The watcher captures every
non-watcher tmux pane each cycle; if a recognised wedge is showing,
the watcher pastes the appropriate recovery keystroke:

- **Case A — permission prompt** (`"Do you want to proceed?"`): paste
  Enter to accept the default-highlighted option.
- **Case B — rate-limit prompt**: every stuck non-watcher window
  receives Enter + a "please continue" follow-up once the limit has
  reset, and the orchestrator gets a separate heads-up paste.
- **Case C — transient API-error chip** (Claude Code's per-turn
  `"Internal server error"` wedge): a single Enter nudges the failed
  turn into retry, with a per-fingerprint backoff
  ([`api_error_backoff_minutes`](#monitorwatcherapi_error_backoff_minutes))
  so a chronically broken endpoint isn't hammered.

Set to `false` to opt out of all three branches and require manual
confirmation. Action + pre-action pane captures are recorded under
`monitor/.state/watcher-unstick.log` and `monitor/.state/unstick/`
for post-hoc audit.

### `monitor.watcher.ratelimit_probe`

**Type** bool · **Env** `MONITOR_RATELIMIT_PROBE` · **Default** `false`

Probe the Anthropic API on rate-limit detection (case B) to discover
the reset timestamp via response headers
(`anthropic-ratelimit-unified-reset` / `-tokens-reset`). The probe
costs a few hundred input tokens + 1 output token per rate-limit
incident (cached for the duration).

Requires `ANTHROPIC_API_KEY` in env. The API key is read from the
environment **only** — never from config — to keep secrets out of the
file. With the probe disabled (or when it fails: no key, network
error, missing header), the watcher falls back to
[`ratelimit_heuristic_minutes`](#monitorwatcherratelimit_heuristic_minutes).

### `monitor.watcher.probe_model`

**Type** string · **Env** `MONITOR_PROBE_MODEL` · **Default** `claude-haiku-4-5-20251001`

Model used for the rate-limit probe. The cheapest available Anthropic
model is the right pick; `max_tokens` is hard-coded to 1 in the probe
call, so token cost is dominated by the model's input pricing.

### `monitor.watcher.ratelimit_heuristic_minutes`

**Type** int (min) · **Env** `MONITOR_RATELIMIT_HEURISTIC_MIN` · **Default** `30`

Fallback wait time (in minutes) used when the probe is disabled or
fails. The watcher schedules the cascade for `now + this many
minutes` and waits, logging once every 5 min. Tune to your
subscription's typical reset cadence (5 h limits sit on a different
schedule than per-minute throttles).

### `monitor.watcher.ratelimit_ack_timeout_s`

**Type** int (s) · **Env** `MONITOR_RATELIMIT_ACK_TIMEOUT_S` · **Default** `60`

After cascading the unstick, how many seconds the watcher waits for
the orchestrator's `ratelimit-resume-ack` action-log entry before
logging `orchestrator-unresponsive`. Allows for one poll-interval
round-trip plus a small margin.

### `monitor.watcher.api_error_backoff_minutes`

**Type** int (min) · **Env** `MONITOR_API_ERROR_BACKOFF_MIN` · **Default** `30`

Case C backoff window in minutes. When the watcher detects a per-turn
API failure wedge (typically `type=api_error`, `"Internal server
error"`), it sends Enter to nudge the failed turn into retry. The
same fingerprint (request_id + message) reappearing within this many
minutes is logged as `case=C action=skip-backoff` and skipped, so a
chronically broken endpoint isn't hammered. Distinct fingerprints
and same-fingerprint reappearances after the window elapses re-fire
the Enter. Set to `0` to disable backoff (every detection acts).

### `monitor.watcher.paste_response_grace_seconds`

**Type** int (s) · **Env** `MONITOR_ORCH_PASTE_RESPONSE_GRACE_S` · **Default** `120`

Orchestrator-liveness grace window. After the watcher pastes to the
orchestrator, it waits this long before declaring
"pasted-without-response" — multi-step tool turns legitimately take
this long before any liveness signal advances. Also the response
window granted to the one-shot re-submit rescue. See
[Orchestrator liveness](orchestrator-liveness.md).

### `monitor.watcher.unstick_window_seconds`

**Type** int (s) · **Env** `MONITOR_ORCH_UNSTICK_WINDOW_S` · **Default** `150`

Budget for the auto-unstick cycle (permission-Enter / api-error-Enter
/ AskUserQuestion-Escape) to resolve a wedge before the watcher fires
the one-shot re-submit rescue. `grace + unstick_window` must stay
below `orchestrator_dead_threshold_seconds` so the rescue retains a
verification window before the absolute deadline (enforced as a
startup WARN).

### `monitor.watcher.orchestrator_dead_threshold_seconds`

**Type** int (s) · **Env** `MONITOR_ORCH_DEAD_THRESHOLD_S` · **Default** `300`

Absolute deadline: if the orchestrator was pasted to this many
seconds ago and **no** liveness signal (heartbeat / paste-received /
jsonl / tool-results) has advanced past the paste, respawn
unconditionally (subject to cooldown). The re-submit rescue cannot
defer this ceiling. **Clamped up at startup** when it would sit at or
below the maximum compose_emit gap
(`full_state_emit_interval_seconds + interval_seconds`) — see
[`dead_threshold_floor_margin_seconds`](#monitorwatcherdead_threshold_floor_margin_seconds)
and [Orchestrator liveness](orchestrator-liveness.md). Must stay below
[`stale_paste_ceiling_seconds`](#monitorwatcherstale_paste_ceiling_seconds).

### `monitor.watcher.stale_paste_ceiling_seconds`

**Type** int (s) · **Env** `MONITOR_ORCH_STALE_PASTE_CEILING_S` · **Default** `1800`

Upper bound on how old a last-paste timestamp may be and still serve
as evidence of wedging. Once the paste age crosses this, the state
machine treats it as too old to be a wedge signal and returns healthy
(`paste-too-stale`) — a quiet workspace with no eligible pastes for
half an hour is not a wedge. Must satisfy
`orchestrator_dead_threshold_seconds < stale_paste_ceiling_seconds`,
else the ceiling masks the dead-threshold check and the detector
never fires.

### `monitor.watcher.dead_threshold_floor_margin_seconds`

**Type** int (s) · **Env** `MONITOR_ORCH_DEAD_THRESHOLD_FLOOR_MARGIN_S` · **Default** `60`

Margin added when the watcher clamps the effective
`orchestrator_dead_threshold_seconds` up to
`full_state_emit_interval_seconds + interval_seconds + margin`. The
clamp closes the static-workspace false-positive respawn race at the
source (the 2026-06-15 incident): with defaults it lifts the deadline
from 300 to `600 + 60 + 60 = 720` s, so a static-workspace full-state
paste always resets the clock before the deadline. The clamp declines
(leaving the configured value, with a WARN) if it would cross
`stale_paste_ceiling_seconds`.

### `monitor.watcher.idle_pane_override_max`

**Type** int · **Env** `MONITOR_ORCH_IDLE_OVERRIDE_MAX` · **Default** `5`

Budget for the runtime idle-pane guard — the defense-in-depth backstop
that suppresses a `dead-threshold` respawn when `pane-state.sh` reports
the orchestrator alive and `idle`/`empty`. The guard suppresses at most
this many **consecutive** times (the counter resets on any genuine
healthy verdict, a non-idle pane, or budget exhaustion); after the
budget it escalates and honors the respawn, so a hung-but-idle pane
cannot suppress its own respawn forever. Set to `0` to disable the
bound (unconditional suppression — **not recommended**, reintroduces
the dead-forever risk). See [Orchestrator liveness](orchestrator-liveness.md).

### `monitor.watcher.liveness_log_throttle_seconds`

**Type** int (s) · **Env** `MONITOR_ORCH_LIVENESS_LOG_THROTTLE_S` · **Default** `30`

Throttle for the repeated `waiting` verdict log lines emitted while the
liveness task polls (~every 5 s). State entries, transitions, and
resubmit/respawn/idle-pane-override events always log regardless.

---

## `monitor.version_restart`

The version-aware component auto-restart (issue `#186`,
[`monitor/watcher/_version_restart.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/_version_restart.sh))
— what makes `git pull` the entire update story. The running watcher
hashes, per component, the source set each running instance loaded at
start against the same files on disk; on confirmed drift it restarts
the component (itself via a detached `launcher.sh --replace`,
registered services via `svc.sh restart <name>`) or asks the
orchestrator (the cockpit, whose TUI window the watcher never kills).
Operator-facing walkthrough: [Operating → Upgrading](../operating/upgrading.md).

| Key | Default | Governs |
|---|---|---|
| `enabled` | `true` | Master switch. `false` (or `interval_seconds: 0`) restores the fully manual pull-then-restart discipline. |
| `interval_seconds` | `60` | Drift-evaluation cadence (a scheduler task inside the watcher loop). |
| `settle_seconds` | `45` | A changed hash must hold **unchanged** this long before any action — outwaits a mid-pull torn tree (a source set with a missing file is `torn` and never acted on). |
| `cooldown_seconds` | `600` | Per-component minimum spacing between actions; a persistent mismatch retries slowly instead of tight-looping. |
| `self` | `true` | Watcher self-restart channel. `false` degrades a confirmed self-drift to an emit advisory — never silent. |
| `services` | `true` | Registry-service restart channel. Same advisory degradation when `false`. |
| `self_loop_limit` | `3` | Max watcher self-restarts per window before the loop guard trips (auto self-restart suspends; an advisory emit asks for manual intervention). |
| `self_loop_window_seconds` | `3600` | The loop-guard window; re-arms after a full quiet window. |

**Bootstrap caveat:** only a version-aware watcher can auto-restart
anything — the first-ever deploy of this module is itself still a
manual `git pull` + `monitor/svc.sh restart watcher`.

---

## Maintenance burden

This page mirrors `config/nexus.example.yml` and the env-var table in
`monitor/README.md`. Whenever you add, rename, or remove a config key,
or change its default:

1. Update `config/nexus.example.yml` first (this is the canonical
   doc, with the long-form rationale in YAML comments).
2. Update this page's index table and the section for the key.
3. If a new env-var override is introduced, update both this page and
   `monitor/README.md`'s env-var table.

The two pages drift quietly when only one is changed. See
[Development](../contributing/development.md) for the standing
convention.
