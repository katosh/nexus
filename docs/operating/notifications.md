# Notifications

Most of what the bot does reaches you through GitHub's own push channel — comments, reactions, mentions. The nexus runs its own out-of-band notifier (`monitor/notify.sh`) only for events GitHub cannot surface: local-state changes, dashboard body edits, Slurm transitions, watcher emergencies. This page covers what fires when, who hears it, and how to add or silence triggers.

## The two-tier model

| Tier | Channels (in order) | Semantics |
|---|---|---|
| `routine` (default) | Pushover priority 0 → ntfy priority 3 fallback | "you'd want to know, no hurry" |
| `emergency` | Pushover priority 1 → ntfy priority 5 fallback, **plus** email | "human intervention needed" |

Routine GitHub activity (comments, mentions, assignments) is **not** routed through this helper — GitHub's own push channel already covers it.

## Channel setup

### Pushover (primary phone channel)

1. Install the app:
    [iOS](https://apps.apple.com/us/app/pushover-notifications/id506088175) ·
    [Android](https://play.google.com/store/apps/details?id=net.superblock.pushover).
    Free 30-day trial; $5 one-time per platform after.
2. Create an application at <https://pushover.net/apps/build> (name `Nexus Monitor`, type `Application`).
3. Drop the **user key** (single 30-char line, from the app's main screen) at the path in `notifications.pushover.user_key_path` (default `~/.claude/.nexus-pushover-user-key`, `chmod 600`).
4. Drop the **application API token** (single 30-char line, from the app builder page) at `notifications.pushover.app_token_path` (default `~/.claude/.nexus-pushover-app-token`, `chmod 600`).

Pushover fires only when both files exist with the correct perms. Wrong perms = silent skip; the helper refuses to read 0644 files.

### ntfy.sh (fallback)

Used automatically when Pushover isn't configured. Install the [iOS](https://apps.apple.com/us/app/ntfy/id1625396347) / [Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy) app, subscribe to the topic URL stored at `notifications.ntfy.topic_url_path` (strip the `https://ntfy.sh/` prefix when subscribing).

### Email (emergency only)

Used when the tier is `emergency` and at least one push channel succeeded — or as a last-resort if every push channel failed.

- **Recipient.** `notifications.email.address` (env override: `$NEXUS_EMAIL_TO`). `notifications.email.probe_address` is a disposable alias for probes only.
- **Relay.** `notifications.email.smtp_host` / `.smtp_port` (env overrides: `$NEXUS_SMTP_HOST`, `$NEXUS_SMTP_PORT`). Must accept mail from the cluster host without authentication.
- **Body shape.** `notify.sh` enforces: subject `[nexus] <title>`; plain-text body starts with `Event: <title>` and `Issue: <click-url-or-(no link)>`, followed by the message. Sender is `nexus-monitor@<cluster-host>`.
- **Inline images.** Pass `--image <path.png>`. `notify.sh` builds a `multipart/related` MIME tree — plain-text alternative plus an HTML `<img src="cid:...">` referencing the attached image. The payload travels with the mail; no public URL needed.

## `monitor/notify.sh`

```text
monitor/notify.sh "<title>" "<body>"
                  [--priority routine|emergency]   # default: routine
                  [--url <click-url>]
                  [--image <path-to-png>]          # attaches on email and push
                  [--tag <ntfy-tag>]...            # ntfy-only
                  [--require-delivery] [--quiet]
```

Round-trip ~0.4 s per channel; `--max-time 5|6` caps per request. Silent no-op when nothing is configured, so callers in the monitor loop need no conditional.

Pass `--require-delivery` for manual probes; the helper then exits nonzero on total failure. Exit codes: `0` ok or silently-skipped, `1` usage, `2` `--require-delivery` set with no configured backend, `3` `--require-delivery` set and every backend failed, `4` missing `curl` / `python3`.

## `sandbox-notify` — the in-pane wake

Inside the [agent-sandbox](https://github.com/katosh/agent_sandbox) wrapper the orchestrator and every worker can call:

```bash
sandbox-notify "watcher heartbeat stale 8 min; respawned via launcher"
```

This emits a tmux notification in both the sandbox tmux and the outer tmux (via the chaperon). The hooks for `Notification` and `Stop` events are pre-configured so the operator sees an alert when an agent finishes a turn or needs attention.

`sandbox-notify` is the right tool for **in-pane blockers** ("worker is wedged on a permission prompt, paste needed") and **end-of-turn cues** ("worker filed final report, ready for review"). For events that should reach the phone, use `notify.sh`.

## Trigger policy

The orchestrator decides which diffs warrant a push. Conservative defaults: the *only* default-enabled trigger today is the local-state one that GitHub cannot see.

**Default-enabled:**

| Event | Title | Tier |
|---|---|---|
| tmux window disappeared without a matching new `reports/*.md` | `tmux window exited` | `routine` |

**Opt-in** (do **not** push unless the operator has explicitly asked for the class):

| Event | Title | Tier |
|---|---|---|
| Dashboard body edit with > 20 line diff | `dashboard changed` | `routine` |
| New `nexus:decision` issue created by the bot | `decision needed` | `routine` |
| Slurm job transitioned from running → complete / failed | `slurm: <state>` | `routine` |
| Monitor-detected pipeline wedge (bot token revoked, watcher crash-looping, project stuck > 2 h with no report) | `nexus emergency` | `emergency` |

The pasted watcher report gives the orchestrator enough to detect the local ones; `squeue -u $USER` deltas surface Slurm transitions; `gh api` calls surface decision-issue creations.

**Adding a trigger.** Open the [overview issue](dashboard.md) with a description of the new class. The orchestrator wires it into its dispatch logic, files a `## Infrastructure Issues` note if the wiring needed new code, and reports back. Adding triggers conservatively is load-bearing — *firehose = design failure*. A notifier that pages on every dashboard edit gets muted; a notifier that pages on the things you genuinely cannot afford to miss stays trusted.

## Secret handling

- `~/.claude/.nexus-pushover-user-key`, `~/.claude/.nexus-pushover-app-token`, and `~/.claude/.nexus-notify-token` are bearer tokens. Perms must be `0600` or `0400`; anything else is rejected. Never commit, never place inside `monitor/.state/`, never paste in comments.
- **Pushover rotation.** Delete the app at <https://pushover.net/apps>, create a new one, rewrite the app-token file. The user key rotates only by creating a new Pushover account (rare; only on key leak).
- **ntfy rotation.** `openssl rand -hex 16`, rewrite the topic-URL file, re-subscribe in the app.
- **Email recipient address.** Not secret; lives in `notifications.email.address`.
- `~/.claude/<bot-slug>-webhook-secret` (path at `github.bot_webhook_secret_path`) holds the HMAC secret matching the App settings page's *Webhook secret* field. Perms `0600` or `0660`. **Operationally informational** today — the watcher reads the deliveries log over an authenticated channel (`mint-token.sh` JWT) and trusts GitHub end-to-end, so the file is hygiene rather than load-bearing. It becomes load-bearing the moment HMAC verification moves into a self-hosted receiver. Rotation: `openssl rand -hex 32`, rewrite the file, paste the same value into the App settings page.

## A probe-and-check shape

Quickest way to verify the channel works end-to-end after first setup:

```bash
monitor/notify.sh "nexus probe" "if you see this, push works" \
    --priority routine --require-delivery
echo $?
```

Exit 0 with a tap-vibrate on the phone confirms the channel; exit 3 means every backend failed (check perms on the credential files, check `notifications.*` keys in `config/nexus.yml`).

For the emergency tier:

```bash
monitor/notify.sh "nexus probe (emergency)" "test of the urgent path" \
    --priority emergency --url https://github.com/$(config/load.sh github.repo)/issues/1 \
    --require-delivery
```

The `--url` field becomes the tap target on Pushover and ntfy and the first link in the email body.
