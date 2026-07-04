# Monitoring

The day-to-day "is the nexus alive and surfacing what it should" page.
Names every observable signal — heartbeat, action log, watcher log,
graphql backoff state — and gives the recipes for catching the
specific failure mode where the system *looks* fine but isn't
surfacing user comments.

For the operator-facing watcher overview (what it does and how to
debug a wedged run), see [Operating → Watcher](../operating/watcher.md).
For the protocol-level deep dive (the eligibility filter, the four
emit classes, the rate-limit cascade), see
[Reference → Watcher protocol](../reference/watcher-protocol.md).

## The one-shot health check

```bash
./monitor/ng watcher-status
```

Prints a `key=value` block: heartbeat age, watcher PID and live/dead,
target window, lock state, tmux presence, archived-diffs count. Exit
codes carry a coarse classification so scripts can branch:

| Exit | Meaning |
|---|---|
| `0` | Heartbeat fresh (within poll interval). |
| `1` | Heartbeat stale, less than 5× poll interval. |
| `2` | Heartbeat very stale, ≥ 5× poll interval. |
| `3` | No heartbeat file present. |

Humans read the stdout block; scripts branch on `$?`. Run it from a
cron, a Slack-bot probe, or any other automation that wants a
heartbeat without parsing logs.

## State files: what to watch

All paths below are under `monitor/.state/` (gitignored). Default
`$NEXUS_ROOT` resolution honors `nexus.root` in `config/nexus.yml`,
with the env var taking precedence.

| File | What it tells you |
|---|---|
| `watcher-heartbeat` | `<PID>` + ISO timestamp. The watcher bumps this every poll cycle. If `mtime` is older than `2 × monitor.interval_seconds`, the watcher is stuck or dead. |
| `watcher.lock` | PID-based lock preventing two watchers on the same state dir. Stale if its PID is gone. |
| `watcher-target` | The tmux window the watcher pastes reports into (typically `orchestrator`). Written at watcher startup; should match the orchestrator's window. |
| `watcher.log` | Append-only watcher activity: startup, every emit, paste-to-target outcomes, respawns. |
| `watcher-alerts.log` | `[iso] WARN <surface> graphql_rate_limit\|graphql_failure\|empty_stderr ...`. One line per surface-level anomaly. **Empty file = healthy** on the GraphQL surfaces. |
| `graphql-backoff-<surface>` | Reset epoch (digits only) for a rate-limit hit on `issue_comments`, `pr_comments`, or `new_issues`. Present means the corresponding `_snapshot_<surface>` is short-circuited until `now ≥ reset + 30 s`. |
| `graphql-alert-emitted-<surface>-<epoch>` | Flag file: the rate-limit sentinel for this `(surface, reset)` pair has been emitted once. Prevents per-poll alert storms. |
| `action-log.jsonl` | Append-only JSONL action trace: `{ts, agent, event, ...}` per meaningful action. |
| `processed-comments.txt` | Local dedup cache of comment IDs the bot has already reacted on. Defends against GraphQL propagation lag between react-POST and re-read. |
| `last-ack.txt` | ISO timestamp of the newest diff the monitor agent has acknowledged via `bootstrap.sh`. The agent's "where I left off" pointer. |
| `last-snapshot.txt` | Persistent snapshot baseline; carries across watcher restarts so the very-first cycle doesn't re-emit every standing comment. |
| `last-change.txt` | Cache of the most recent emit body. |
| `diffs/<ts>_<shortid>.md` | Archived watcher emits. Pruned at `monitor.diff_retention_days` (default 7). |
| `dashboard.md` | Local cache of the dashboard-middle content. |
| `dashboard-updated.ts` | ISO timestamp of the last successful `ng dashboard put`. |
| `watcher-unstick.log` | Auto-unstick action log: detections, send-Enters, backoffs, cascades, orchestrator acks. |
| `unstick/` | Per-window-per-case fingerprints, retry counters, pre-action pane captures, and case-B session state (rate-limit reset / cascade / last-wait epochs). |

Full table including tracked-vs-not status: see
[Reference → Files](../reference/files.md).

## Watcher liveness recipes

### Is the watcher running right now?

```bash
./monitor/ng watcher-status
```

`watcher-status` exits 0 when the heartbeat is fresh and the pid is
alive. The watcher runs **headless** (no tmux window of its own), so
don't look for a `watcher` window — `watcher-status` and the
heartbeat/pidfile under `monitor/.state/` are the source of truth.

### Has it actually been polling?

```bash
tail -n 20 monitor/.state/watcher.log
```

Look for recent `snapshot ok` lines. The cadence should match
`monitor.interval_seconds` (default 60 s).

### Did a recent paste-to-target succeed?

```bash
grep -E 'paste[- ]ok|paste[- ]fail' monitor/.state/watcher.log | tail -n 5
```

Paste failures usually mean the target window (`orchestrator` by default)
went missing. The watcher will respawn after
`monitor.agent_missing_respawn_delay` confirming polls
(default `3` = ~8 s of confirmed absence at the 2 s probe cadence),
re-verifying the absence just before the launch; see
[Operating → Watcher](../operating/watcher.md) for the contract.

## The silent-failure problem

The hardest failure mode is **the watcher is alive, the heartbeat
is fresh, but no eligible comments are reaching the orchestrator.**
There is no error to grep for, no exception to catch — just an
absence.

### Cause: GraphQL rate-limit on the bot installation

Several active workers + the orchestrator + the watcher itself can
exhaust the bot installation's shared GraphQL bucket. When that
happens, `_snapshot_github`'s three sub-snapshots all return
`graphql_rate_limit`. The watcher used to swallow this silently;
since 2026-05-01 it captures stderr and routes failures through
`_watcher_handle_graphql_failure`.

You can detect rate-limit silence in two ways:

1. **`watcher-alerts.log` has fresh entries:**

    ```bash
    tail -n 10 monitor/.state/watcher-alerts.log
    # [2026-05-09T18:14:32Z] WARN issue_comments graphql_rate_limit reset=1715284000 reset_iso=2026-05-09T18:26:40Z
    ```

2. **A `graphql-backoff-<surface>` file exists:**

    ```bash
    ls monitor/.state/graphql-backoff-* 2>/dev/null
    # monitor/.state/graphql-backoff-issue_comments
    cat monitor/.state/graphql-backoff-issue_comments
    # 1715284000   ← reset epoch; backoff active until this passes
    ```

The watcher emits a `watcher_alert=rate-limit` sentinel line on the
first hit per bucket-exhaustion event (deduped via the
`graphql-alert-emitted-<surface>-<reset>` flag) and routes it through
the standard paste-to-target pipeline, so the orchestrator sees the
alert within one cycle. The deliveries path (App-JWT, separate
bucket) is unaffected and keeps surfacing comments during the
backoff window.

### Cause: deliveries enabled but no events firing

If the deliveries path is enabled (`monitor.deliveries.asset_enabled`
/ `monitor.deliveries.bot_mention_enabled`, both default true) but
`/app/hook/deliveries` returns `[]` on probe, the App is not
receiving events. Most likely the App is not subscribed to the
right events (`issues`, `issue_comment`, `pull_request`,
`pull_request_review`, `pull_request_review_comment`) or the
Webhook → Active toggle is off. See
[GitHub App → Step 5](github-app.md#step-5-subscribe-to-events).

### Cause: bot install scope is wrong

If `ng preflight "$(./config/load.sh github.repo)"` returns
`bot installed no`, the App is not installed on the asset+issue
repo. Re-do
[GitHub App → Step 7](github-app.md#step-7-install-the-app-on-your-assetissue-repo).

### Cause: target window absent

If the orchestrator's `orchestrator` window was killed (manual `tmux
kill-window`, or a crash), the watcher detects this in
`agent_missing_respawn_delay` confirming polls (default 3),
re-verifies the absence, and spawns a fresh
session. Until that respawn lands, paste-to-target fails and emits
go to `watcher.log` but the agent doesn't pick them up. The
crash-loop guard (`monitor.respawn_loop_limit` / `_window_seconds`)
prevents thrashing if the respawn itself keeps dying.

## The deliveries probe

```bash
JWT=$(./monitor/mint-token.sh --jwt-only)
curl -sS \
    -H "Authorization: Bearer $JWT" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/hook/deliveries?per_page=5" \
  | jq '.[] | {event, status_code, delivered_at}'
```

Run from the nexus root. A healthy deliveries log shows recent
entries (within minutes of recent activity) with `status_code: 200`.

Common readings:

- **`[]`** — App not subscribed to any event, or the events haven't
  fired yet. Try a `:thumbsup:` reaction on any issue in the asset
  repo and re-run.
- **All `status_code: 502` / `503`** — the smee channel is
  unreachable. Re-provision; watcher is unaffected since it reads
  from `/app/hook/deliveries`, not from the smee URL.
- **`404 — App has no webhook URL`** — Webhook → Active is off on
  the App settings, or the URL field is blank.
- **`Bad credentials`** — `bot_app_id` doesn't match the pem you
  downloaded.

## The action log

`monitor/.state/action-log.jsonl` is the structured trace of every
meaningful action a nexus agent takes. Schema:

```json
{"ts":"<ISO8601>","agent":"<name>","event":"<verb>","..."}
```

Reserved keys: `ts`, `agent`, `event`, `note`. Other keys are
event-specific (e.g. `report` / `issue` / `comment` / `rocket` on
`wrap-up` events).

### Useful queries

```bash
# Last 20 events.
tail -n 20 monitor/.state/action-log.jsonl

# All wrap-up events in the last 24 h.
jq -c 'select(.event == "wrap-up" and .ts >= (now - 86400 | todate))' \
    monitor/.state/action-log.jsonl

# Count events per agent in the current calendar day.
jq -r 'select(.ts >= ("'"$(date -Iseconds -d 'today 00:00')"'")) | .agent' \
    monitor/.state/action-log.jsonl | sort | uniq -c

# Spot processed-comment events that didn't produce a follow-up
# wrap-up — useful when investigating "did the bot drop the ball
# on directive X?".
jq -c 'select(.event == "process" or .event == "wrap-up")' \
    monitor/.state/action-log.jsonl | tail -n 50
```

A monotonically-growing log with no `event` you don't recognise is
the happy path. Gaps in the timestamp sequence (after a watcher
restart) are expected.

## Watcher alerts

```bash
tail -n 20 monitor/.state/watcher-alerts.log
```

Line shape: `[<iso>] WARN <surface> <classification> [details...]`.

| Classification | Surface | What it means | Action |
|---|---|---|---|
| `graphql_rate_limit` | `issue_comments` / `pr_comments` / `new_issues` | Bot installation's GraphQL bucket exhausted. Backoff active. | Wait until `reset_iso`. Reduce active worker count if it's chronic. |
| `graphql_failure` | (same) | Other (non-rate-limit) GraphQL error. Throttled at 1/10 min. | Investigate the bot's GraphQL availability; usually GitHub-side noise. |
| `empty_stderr` | (same) | `gh api graphql` produced no stderr but failed. Edge case (e.g. transport-level error). Throttled. | Usually transient. |

Empty file means the GraphQL surfaces are healthy. A line appearing
mid-shift is the signal to investigate before silence becomes
operationally invisible.

## Heartbeat semantics in detail

The watcher touches `monitor/.state/watcher-heartbeat` every poll
cycle (every `monitor.interval_seconds`, default 60 s) with:

```
<PID>
<ISO timestamp>
```

The monitor agent reads this on every wake via
`monitor/watcher/bootstrap.sh`. If `mtime` is stale by more than
`2 ×` the poll interval (or the file is missing), bootstrap writes
a `reports/nexus_*_watcher-incident.md` evidence package and
respawns the watcher via `monitor/watcher/launcher.sh`. The agent
reads the report and decides between two paths:

- **Benign respawn** — log via `monitor/ng log-action monitor --event watcher-respawn` and continue.
- **Suspected bug** — spawn a `watcher-fix` worker with the
  incident report as the brief.

After a suspected-bug redeploy, the agent schedules a short-lived
CronCreate (~10–15 min) that cancels itself after three consecutive
healthy heartbeats. This is the
[mutual-liveness contract](https://github.com/<your-org>/nexus-code/blob/main/monitor/README.md#mutual-liveness-contract)
between the agent and the watcher; the configured `github.user_login`
is the external tie-breaker if they disagree.

## Manual watcher restarts

Rarely needed for upgrades: after a `git pull`, the version-aware
watcher detects its own source drift and self-restarts (see
[Operating → Upgrading](../operating/upgrading.md)). The manual
bounce remains for config changes, debugging, the
auto-restart-disabled case, and the first-ever deploy of the
version-aware module:

```bash
# Stop + respawn the headless watcher (== launcher.sh --replace).
monitor/svc.sh restart watcher

# Verify.
./monitor/ng watcher-status     # expect rc 0 and 'hosting: headless'
```

The restart kills the recorded watcher process (SIGTERM, escalating
to SIGKILL after 5 s) and respawns it headless. If the restart is
meant to pick up new code, `git pull` first — `main.sh` sources
sibling module files at startup (see
[Operating → Upgrading](../operating/upgrading.md)). A leftover
legacy `watcher` window is swept automatically.

## Watcher debugging mode

For active debugging (e.g. trying to reproduce a paste-to-target
issue), run the watcher in foreground:

```bash
cd "$(config/load.sh nexus.root)"/monitor

# One poll cycle and exit.
./watcher/main.sh --once

# Snappier polling, attended.
MONITOR_INTERVAL=10 ./watcher/main.sh
```

The cached emit body lands at `monitor/.state/last-change.txt` and
archived diffs accumulate under `monitor/.state/diffs/`.

## When to look at GitHub vs when to look at the host

| Symptom | First place to check |
|---|---|
| "My comment got no eyes/rocket" | Eligibility — is your comment's author `github.user_login`? Is the issue in `github.repo`? Then watcher alerts + heartbeat. |
| "Bot replied but my phone didn't buzz" | Pushover/ntfy config; GitHub's own notification settings. The bot's identity should always wake you for actions on your repos. |
| "Watcher is paste-failing repeatedly" | `tmux list-windows` — is the target window still there? Then crash-loop guard state in `watcher.log`. |
| "Asset upload returns 403" | `ng preflight "$(./config/load.sh github.repo)"` — bot install scope. Then permission grants ([GitHub App → Step 4](github-app.md#step-4-permissions)). |
| "Bot's writes look stale or out of order" | `action-log.jsonl` with `jq -c` for the relevant time window. Then `watcher.log` paste-to-target lines. |
| "Watcher quietly stopped surfacing comments" | `watcher-alerts.log` (rate-limit signature?) and `graphql-backoff-*` files. |
| "Heartbeat is fresh but I see nothing happening" | Paste-to-target failures in `watcher.log`. Then verify `orchestrator` window exists. |
| "I changed `config/nexus.yml` and nothing took effect" | The watcher reads config on startup; restart per [Manual watcher restarts](#manual-watcher-restarts). |

## Related

- [Operating → Watcher](../operating/watcher.md) — operator-facing
  watcher overview.
- [Operating → Troubleshooting](../operating/troubleshooting.md) —
  symptom-keyed recipes including the rate-limit cascade.
- [GitHub App](github-app.md) — permission grants, install scope,
  smoke tests.
- [Security](security.md) — audit trail, compromise response.
- [Reference → Files](../reference/files.md) — full state-file index.
- [Reference → Watcher protocol](../reference/watcher-protocol.md) —
  eligibility filter, emit classes, rate-limit cascade.
- [Reference → ng CLI](../reference/ng-cli.md) — `watcher-status`,
  `log-action`, `preflight` verbs.
