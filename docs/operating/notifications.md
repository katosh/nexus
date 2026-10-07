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

- **Recipient.** `notifications.email.address`. `$NEXUS_EMAIL_TO` may only narrow it: equal to that address, or empty for no email. Any other value is refused (rc 5) and never redirects. `notifications.email.probe_address` is a disposable alias for probes only (reserved; not consumed).
- **Mail policy** (operator rule, 2026-09-28, <your-org>/nexus-code#1663): the nexus emails **only the operator** and **never as the operator**. `notify.sh` refuses (rc 5) any recipient that is not exactly `notifications.email.address` in the PRIMARY nexus's own `config/nexus.yml` (resolved by the one-tree rule, `monitor/_nexus-root.sh`; `NEXUS_CONFIG` or `NEXUS_ROOT` naming another recipient is refused, never followed). No address configured means no email at rc 0, with the push backends unaffected. and refuses (rc 6) a sender that would carry the operator's address, local part or login. The envelope sender and recipient are set explicitly: `nexus-monitor@<host>` and the operator alone. Every message carries `Auto-Submitted: auto-generated` and a footer naming the host. `notify.sh` is the only file allowed to send mail, and `monitor/watcher/mail-path-lint.sh` enforces that.
- **Relay.** `notifications.email.smtp_host` / `.smtp_port` (env overrides: `$NEXUS_SMTP_HOST`, `$NEXUS_SMTP_PORT`). Must accept mail from the cluster host without authentication.
- **Body shape.** `notify.sh` enforces: subject `[nexus] <title>`; plain-text body starts with `Event: <title>` and `Issue: <click-url-or-(no link)>`, followed by the message. Sender is `nexus monitor <nexus-monitor@<cluster-host>>`, for the header and the envelope alike; the body ends with a footer naming the host.
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

Round-trip ~0.4 s per channel; each request carries its own `curl --max-time` cap — 10 s for Pushover, 15 s for an ntfy upload with `--image`, 5 s for a plain ntfy post (`monitor/notify.sh:216,248,252`). Silent no-op when nothing is configured, so callers in the monitor loop need no conditional.

Pass `--require-delivery` for manual probes; the helper then exits nonzero on total failure. Exit codes: `0` ok or silently-skipped, `1` usage, `2` `--require-delivery` set with no configured backend, `3` `--require-delivery` set and every backend failed, `4` missing `curl` / `python3`, `5` the email was refused because the recipient is not the operator, and `6` the email was refused because the sender would carry the operator's identity. `5` and `6` outrank a push that landed.

## `sandbox-notify` — the in-pane wake

Inside the [agent-sandbox](https://github.com/katosh/agent_sandbox) wrapper the orchestrator and every worker can call:

```bash
sandbox-notify "watcher heartbeat stale 8 min; respawned via launcher"
```

This emits a tmux notification in both the sandbox tmux and the outer tmux (via the chaperon). The hooks for `Notification` and `Stop` events are pre-configured so the operator sees an alert when an agent finishes a turn or needs attention.

**It delivers ATTENTION, not content** (<your-org>/nexus-code#1533). The real tool assigns its argument once and never reads it again; what reaches the operator is a bare BEL. The words survive only in the nexus wrapper's decision log (`monitor/.state/notify-decisions.jsonl` — every ring, suppression, batch and digest, with the text) and, for watcher alerts, in `monitor/.state/watcher-alerts.log`. So `sandbox-notify` is the right tool for **in-pane blockers** ("worker is wedged on a permission prompt, paste needed") and **end-of-turn cues** ("worker filed final report, ready for review") — cases where the operator is at the terminal and the bell points them at a pane. For anything a human must READ, or that must reach the phone, use the operator alert below or `notify.sh`.

The wrapper suppresses the harness's own `Needs attention` idle default for every agent (it fires after every turn). One context re-classifies it (#1551): when the window's last turn FAILED with no in-band remedy — a fresh `monitor/.state/turn-failure/<window>.json` with `recovery=operator`, i.e. an expired login — the same four bytes are reworded to `turn FAILED (needs operator): <window> cannot take a turn — …` and ring on the `failure` class (120 s cooldown). The harness payload cannot tell "idle" from "logged out" (`notification_type: idle_prompt` in both); the marker can.

## Operator alerts — raised by the watcher, no model turn needed

`monitor/watcher/_operator_alert.sh` (<your-org>/nexus-code#1548, #1533, #1534) is what the watcher uses when it alone knows the operator must act and no agent can take a turn. Keys today: `auth-expired` (the orchestrator is logged out — from the pane render or the typed `StopFailure` marker), `service-health:<name>` (an emit-only or flapping service is down while the emit route is unavailable), `auth-dialog-escaped` (an event: the watcher escaped an abandoned `/login`). Four legs, cheapest and most certain first, every one fail-open:

1. **`monitor/.state/operator-alerts.jsonl`** — one JSON row per raise / reminder / clear and per leg outcome. Durable and greppable; the first place to look when asking "was the operator told, and how?".
2. **the `watcher ALERT:` bell** via `_watcher_alert` — `watcher-alerts.log` + `watcher.log` + `sandbox-notify`. Attention.
3. **`monitor/notify.sh --priority emergency --require-delivery`** — Pushover → ntfy → SMTP. Its record states what its rc proves: `0` is API acceptance, not device delivery; the off-terminal leg is UNVERIFIED until an operator confirms a push arrived.
4. **a bot-authored GitHub issue `operator-alert: <key>`** on `github.repo`, @-pinging `github.user_login` — the one channel with observed delivery. One open issue per key while the condition stands; reminders comment on it; `clear` closes it.

Cadence: one announcement, reminders every `monitor.watcher.operator_alert.reminder_seconds` (3600), one clear. **A flapping condition cannot flood the repo**: a `clear` finalises only after the condition has been absent for `operator_alert.clear_holddown_seconds` (300) — a raise inside the hold-down is recorded as a `flap` and neither re-rings nor re-files; a raise after the issue was closed REOPENS it rather than creating another; GitHub comments are capped at one per key per `operator_alert.comment_interval_seconds` (3600), while open/close state changes are never capped. GitHub being unreachable or rate-limiting the bot is recorded as `github-failed` with the reason; the record and the bell have already landed. Other knobs: `operator_alert.push_enabled`, `operator_alert.github_enabled`, `operator_alert.net_timeout_seconds` (each network leg is `timeout`-bounded and detached from the watcher loop). `NEXUS_NOTIFY_QUIET=1` disables both network legs.

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
