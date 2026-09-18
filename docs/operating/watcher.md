# Watcher

The watcher is the heart of the nexus. It runs as a **headless service** — setsid-detached, no tmux window, pidfile at `monitor/.state/watcher.pid`, log at `monitor/.state/watcher.log` — polls a small set of signals every cycle, and pastes a structured report into the orchestrator's pane whenever something changes. Supervise it with [`monitor/svc.sh`](dashboard.md): `svc.sh status` for one table, `svc.sh logs watcher` (or cockpit key `0`) to tail its log, `svc.sh restart watcher` to bounce it. This page covers what an operator sees and what they can do with it. The protocol-level deep dive (eligibility filter, emit classifier, dedup rules, rate-limit cascade) lives in [`reference/watcher-protocol.md`](../reference/watcher-protocol.md).

## What the watcher polls

Every `monitor.interval_seconds` (default 60) the watcher snapshots:

- **Local state.** `reports/*.md` filenames and mtimes, `tmux list-windows` with bell-flag, and per `work/<project>` repo the HEAD and clean/dirty status. Diffed against the previous snapshot.
- **GitHub state.** Eligible comments on any open issue or PR in `github.repo`, plus freshly opened issues authored by the configured user. The eligibility filter (no non-user 👀, no 🚀 from anyone) is enforced inside the GraphQL query.
- **Standing tmux bells** on non-orchestrator windows (an agent's "needs attention" signal).
- **Idle worker transitions** — workers whose engagement-anchored idle age crossed `monitor.idle_threshold_seconds` (default 60) since the last poll, classified into `wrapped`, `wrapped-but-stub`, `no-wrap-up`, `idle-too-long`, `pane-absent`, `over-limit`, `operator-engaged`, `parked-awaiting-skeptic`, `engaged-close-reminder`, `paste-unconfirmed`, `idle-orphan-async`, and friends. Vocabulary: [Reference → Worker states](../reference/worker-states.md); authoritative lifecycle diagram: [`monitor/docs/agent-state-machine.md`](https://github.com/<your-org>/nexus-code/blob/main/monitor/docs/agent-state-machine.md).
- **Component version drift** — per-component source-set hashes of the code each running component loaded at start, compared against disk; a confirmed drift after a `git pull` triggers the component's auto-restart (see [Upgrading](upgrading.md)).

On every observed change the watcher does four things, in order:

1. Archives the report under `monitor/.state/diffs/<ts>_<shortid>.md` so nothing is lost if a paste fails.
2. Pastes the report into the target tmux window (default `orchestrator`) via `tmux set-buffer` + `tmux paste-buffer` + `Enter`.
3. Logs an append-only line to `monitor/.state/watcher.log`, and stamps `monitor/.state/watcher-cycle` — the "a full compose cycle completed" proof (see [Heartbeat and liveness](#heartbeat-and-liveness)).
4. Handles ancillary work — auto-unstick, GraphQL-backoff bookkeeping, deliveries-log consumption.

The liveness heartbeat is deliberately **not** on this list: it is bumped by a background ticker independent of the emit path, so a quiet workspace (which is supposed to stay silent for long stretches) still reads healthy.

Mid-snapshot dirty-hash bumps and `*-interim*.md` report additions are reclassified as noise and suppressed (the baseline advances, one log line is written, but no paste fires); everything else surfaces.

## What the watcher emits

A typical paste into the orchestrator's pane:

```text
=== nexus state changed at 2026-05-11T13:42:07-07:00 (poll) ===
*If unsure how to proceed: see CLAUDE.md.*
workspace: 4 busy | 2 idle | 0 retained | 0 idle-too-long | …

--- local state changes ---
 --- tmux ---                     # a diff CONTEXT line: note the leading space
 --- reports ---
+reports/kompot_2026-05-11_134105_fig3-pass2.md

--- eligible github comments ---
issue=42 id=4422219722 author=<your-login>
  body: please open the PR when tests pass

--- idle workers ---
kompot-fig3 wrapped up (idle 0:35:12; wrap-up logged)

--- dashboard ---
last put: 2026-05-11T13:18:42-07:00 (local stamp — when `ng dashboard put` last ran here)
```

In a `compose_report` emit the header, the `workspace:` prelude and the `--- dashboard ---` footer are always present; everything between is conditional. (The one exception is the `comment_surface` fast path, reason `comments`, which bypasses `compose_report` entirely and emits just the header, the CLAUDE.md cue, `--- eligible github comments ---` and the signature.) `compose_report` (in `monitor/watcher/main.sh`) emits the sections in this fixed order — the infra-health sections are pinned at the top, ahead of the routine local diff, so a watcher self-failure or service outage can't scroll out of view:

| Section | Trigger |
|---|---|
| State-change header | Always present. The parenthesised token is the emit *reason* — `startup-sweep`, or one of `poll`, `poll-full-state`, `poll-resurface`, `poll-cc-update`, `poll-component-drift`, `poll-service-health`, `poll-requests`, `poll-reports-roll` (plus `comments` for the `comment_surface` fast path, which builds its body inline). A one-line `workspace:` prelude follows; when its render blows its wall-clock budget the line is explicitly labelled `PARTIAL` / `STALE` / `UNAVAILABLE` rather than silently vanishing. |
| `--- watcher revived (was down) ---` | The watcher-supervisor daemon revived a crashed watcher; this is its first emit reporting its own death-and-return. Pinned at the very top. |
| `--- arm watcher supervisor ---` | The orchestrator's watcher-supervisor `Monitor` is not armed (no fresh supervisor heartbeat) → a watcher crash would have no turn-independent revival. Standing reminder; self-clears once armed. |
| `--- install failure ---` | The project-local Claude Code install failed at watcher startup. Surfaced once; rerun `monitor/install-claude-local.sh` to retry. |
| `--- watcher hosting migration ---` | This watcher is running legacy window-hosted; surfaced once per lifecycle, telling the orchestrator how to converge to headless hosting (see [Upgrading](upgrading.md)). |
| `--- component drift (restart needed) ---` | A nexus-code component changed on disk and its restart needs the orchestrator (cockpit ask, tripped self-restart guard, or a disabled auto-restart channel). Automated restarts never surface here. |
| `--- service health ---` | A registered service (`monitor/services.registry`) failed its healthcheck. Reports the full state (grace/recovering/emit-only/flapping); on an emit-only/flapping escalation the orchestrator runs the [service-recovery protocol](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.service-recovery/SKILL.md). |
| `--- claude code update available ---` | A newer Claude Code release than the local pin exists. Gated advisory: the orchestrator spawns an evaluator briefed with the cc-update guide before any promote. Surfaced once per candidate. **Off by default** — `monitor.cc_update.emit_enabled` defaults to `false`, so on a stock config this section never appears; detection still runs and the autonomous `cc_auto_update` routine closes the loop without the nag. |
| `--- reports archived ---` | The auto-roll moved aged reports into monthly `reports/YYYY-MM/` buckets. One-shot informational breadcrumb; no action needed. |
| `--- local state changes ---` | At least one of `reports/`, `tmux`, or any `work/<project>` HEAD changed. **The only truncatable section** — capped at `MONITOR_EMIT_SECTION_MAX_LINES` (default 50) lines, overflow replaced by one `[+N more lines omitted]` marker; every other section is exempt. |
| `--- eligible github comments ---` | One or more comments passed the eligibility filter. |
| `--- standing bells ---` | A non-orchestrator window has bell=1 (silenced after emit so the next ring re-fires). |
| `--- pending decisions ---` | One or more structured decision records await the operator, **and their panes are not already busy** (sourced from `monitor/.state/decisions/*.json`; ack with `ng decision-ack <window> <fp>` — removing the file does *not* stick, `#790`). |
| `--- requests ---` | A claimed request in the watcher-mediated inbox (`monitor/.state/requests/*.claimed.md`). Each row's `handling:` line says how *that* request closes — `ng request reply <id>` or `ng request ack <id>`. |
| `--- idle workers ---` | One or more workers transitioned across the idle threshold this cycle. |
| `--- workspace snapshot ---` | Periodic full-state snapshot (every Nth emit), giving a cumulative view between the narrow transition emits. |
| `--- dashboard ---` | Always present. Prints `last put:` — the **local** `ng dashboard put` stamp, not a read of the issue. Past 2 h it says so in those words and points at `ng dashboard get`; it deliberately does *not* claim the dashboard is stale, because nothing here reads the board (`#1010`). |

(A trailing `--- nexus-emit-sig … ---` signature line lets `paste_to_target` content-verify the emit; it's machinery, not operator-facing.)

The operator-actionable ones — `service health` and `component drift (restart needed)`, plus `claude code update available` where its emit gate has been turned on — each map to a dedicated response protocol; the rest are informational or self-clearing.

## How the orchestrator wakes up

A wake is just an incoming paste in the orchestrator's tmux pane — there is no separate IPC channel. The orchestrator's first action on every turn is `monitor/watcher/bootstrap.sh`, which:

1. Runs the shared `_watcher_alive` probe. It respawns the watcher via `monitor/watcher/launcher.sh` — and writes a `reports/nexus_*_watcher-incident.md` evidence package — **only on established death**, buckets `2` and `3`. A merely-aging heartbeat (bucket `1`, BUSY) and a live-but-wedged loop (bucket `4`, WEDGED) are both logged and left alone: killing them from a per-turn bootstrap is how healthy watchers died on 2026-07-09, and the supervisor `Monitor` + `revive-watcher.sh` own the wedged case.
2. Prints any archived diffs newer than `monitor/.state/last-ack.txt` — the catch-up path for diffs missed between turns (orchestrator was busy, paste-to-target failed, etc.).
3. Advances `last-ack.txt` to `date -Is`.

Idempotent: running it on a turn with no missed diffs costs you one `[bootstrap] no missed diffs` line.

## Heartbeat and liveness

`monitor/.state/watcher-heartbeat` is the canonical liveness signal. The PID, an ISO timestamp and the target window are inside. It is bumped by a **background `setsid` ticker** inside the watcher process at `monitor.watcher.heartbeat_tick_seconds` (default 20 s) — *not* by the poll loop, and not once per emit. That decoupling is the point (`#491`): cycle duration scales with worker count while the liveness thresholds are constants, so a workload-driven heartbeat guaranteed a false DOWN at ≥ 12 workers. Two companion files carry what the heartbeat no longer does:

- `monitor/.state/watcher-progress` — the loop is moving (bumped every scheduler iteration and at stage boundaries).
- `monitor/.state/watcher-cycle` — a full compose cycle completed, carrying the measured loop period.

`_watcher_alive` folds all three into one bucket and `_watcher_liveness_verdict` renders the `UP` / `BUSY` / `WEDGED` / `DOWN` trichotomy on top; **`BUSY` is healthy under load — do not restart it.** Full table: [Reference → Watcher protocol → Liveness signals](../reference/watcher-protocol.md#liveness-signals).

Two paths use the heartbeat:

- **Orchestrator → watcher.** Every turn `bootstrap.sh` runs the probe. Established death (bucket 2/3) → respawn + incident report; BUSY and WEDGED are left to the supervisor.
- **Watcher → orchestrator.** Two detectors. *Window absent:* after `monitor.agent_missing_respawn_delay` confirming polls (default 3, ~8 s of confirmed absence) plus a pre-launch re-verification, the watcher launches a fresh `claude` session in the target window. *Window present but inert:* a hook-driven liveness state machine (`monitor/watcher/_orchestrator_liveness.sh`) watches the orchestrator's Stop-hook heartbeat and paste-received signals after each paste, tries an Enter/unstick pass and a one-shot re-submit rescue, and only then respawns. Either way the new agent validates the call and kills the watcher if the respawn was wrong.

Both directions defer to `github.user_login` as the external tie-breaker: a comment on the overview issue overrides local state.

For a one-shot snapshot of liveness state:

```bash
monitor/ng watcher-status
```

Prints heartbeat age, PID + alive/dead, target window, `watcher.lock` state, the instance-lock summary, hosting (`hosting: headless` is healthy; `hosting: legacy tmux window 'watcher' present` flags a not-yet-swept leftover — see [Upgrading](upgrading.md)), and the archived-diffs count. `--scheduler` appends a per-task last-fire summary from `monitor/.state/watcher-scheduler.jsonl`.

The exit code is `_watcher_alive`'s bucket, verbatim: `0` fresh (age ≤ 2× interval + 15 s), `1` stale (age ≤ 5× interval), `2` very stale (age > 5× interval), or the heartbeat pid is no longer a live watcher *and* the instance flock is free, `3` no heartbeat, **`4` wedged** — alive and beating, but progress and cycle have both stalled past the measured-period cutoff. The boundary is inclusive at the top: at exactly 5× interval the bucket is still `1`. Scripts branch on the bucket; humans read the stdout block. Note that the block carries no `state=` line — the `UP`/`BUSY`/`WEDGED`/`DOWN` words come from `monitor/svc.sh status`, which renders `_watcher_liveness_verdict`.

## Single-instance contract

**The supported topology is one cockpit per `NEXUS_ROOT`.** A second nexus instance is supported only when it points at a *different* `NEXUS_ROOT` (its own `monitor/.state/`). Two cockpits sharing one `NEXUS_ROOT` — most plausibly two separate `agent-sandbox` instances bind-mounting the same tree — is **unsupported and actively guarded**, because they would share one `monitor/.state/` while keeping separate control planes (separate tmux servers, separate orchestrators). The dangerous asymmetry is *separate control planes, shared side-effects*: both watchers would `snapshot_github` and react/dispatch/`wrap-up` on the **same** eligible comments, producing duplicate bot reactions, duplicate worker spawns, and duplicate issue comments — plus interleaved writes to the emit-dedup, decisions, and service-supervisor state.

Why the older pid-based guards are not enough on their own. `agent-sandbox` runs each cockpit under `bwrap --unshare-pid`, so every instance has its **own pid namespace and `/proc`**. A peer sandbox's watcher pid is therefore invisible — `kill -0`/`/proc/<pid>/cmdline` either find nothing or an unrelated local process — so `watcher.lock` / `watcher.pid` and the `entry.sh` cockpit-peer scan (tmux-server-local) all read a live peer as *absent* and would clobber the shared state. (This is exactly the `stale lock (pid=…); overwriting` line in the wild.)

The guard that closes this is an **flock-based instance lock** at `monitor/.state/nexus-instance.lock`:

- The watcher acquires an exclusive flock on it at startup and **holds it for its whole lifetime** (an open fd). flock keys on the inode + open-file-description, not the pid, so it crosses the pid-namespace boundary — which is exactly the boundary two sandboxes on one host sit either side of.
- A second start that finds a **live holder refuses loudly and exits `4`** — the launcher fast-fails before spawning (so you get an immediate, actionable message rather than a 15 s timeout), and `main.sh` is the authoritative gate. The refusal is built **from** the holder's recorded metadata (see *Lockfile contents* below) and tells you the suspected situation, the normal resolution, and the false-positive resolution.
- It blocks **coexistence, never succession.** The blessed self-replace paths (`launcher.sh --replace`, the version-restart self-restart, `bootstrap-recover`) all terminate the prior watcher *before* the successor starts, so the prior flock is already released when the successor acquires.

**flock does not carry the cross-HOST case, and a second mechanism does.** `flock(2)` over NFS is implementation-dependent, and empirically it did *not* block a second cockpit on another host sharing this NFS state dir — a remote starter can see the lock as free. So the live watcher also refreshes a **beacon**, `monitor/.state/nexus-instance.heartbeat`, on every loop iteration (atomic tmp + rename; a separate file from the flock target, so refreshing it never renames the locked inode). A starter whose flock probe came back free reads that beacon and **refuses while it is fresh**, taking over only once it has aged past `monitor.instance_heartbeat_staleness_seconds` (default 600 s — generous against the ≤ 10 s refresh cadence, so a cc-update restart gap never triggers a false takeover). A dead remote holder therefore needs no intervention: the beacon ages out and the next start wins.

The running watcher also **self-fences**: before each refresh it checks whether the beacon on disk is still its own (by a per-instance nonce, so even a same-host second instance is detected) and stands down rather than overwriting a newer holder's — the case where this loop wedged past the window, a peer legitimately took over, and this loop then un-wedged.

Cross-host / cross-sandbox `--replace` is intentionally **not** a take-over: you cannot signal a peer you cannot see, so the successor refuses rather than risk double-running. Stop the holder in its own sandbox, then start yours.

### Lockfile contents

The lock file body is **advisory diagnostics only** — liveness is the flock itself, never the text. At acquire time the watcher records (one `key: value` per line): `pid`, `host`, `boot_id` (the kernel's per-boot UUID — see *Can the flock be stale?*), `pid_ns`, `sandbox` (`$SANDBOX_PROJECT_DIR`), `tmux` (`$TMUX` socket, so you can find the other cockpit), `user`, `nexus_root`, and `started_at` (ISO 8601). No secrets. The set lives in one writer (`_nexus_instance_lock_metadata`, `_lib.sh`) so the refusal message, `--instance-status`, and `ng watcher-status` all read the same schema.

### Can the flock be stale?

Honest answer: **almost never, and the one case that can be is detectable.** Reasoning by case:

- **Holder process died (same host).** An flock is bound to the holder's open fd; when that process exits — *even on SIGKILL* — the kernel closes its fds and **auto-releases** the lock. A fresh acquirer then succeeds normally and overwrites the (harmless) leftover metadata. **Never stale.** This is the auto-reclaim path; no logic needed.
- **Holder alive in another sandbox / pid namespace on the same host.** The genuine coexistence case. flock arbitrates across pid namespaces, so the guard correctly blocks it. Assessment: **`live-local`** — treat it as a live peer.
- **Same host, but the machine rebooted since the lock was taken.** Detected by `boot_id` mismatch (the recorded boot id ≠ the current one). The recorded holder cannot still be alive; a held flock in this state would be an NFS server-side remnant. Assessment: **`stale-reboot`** — safe to clear.
- **Cross-host (NFS).** flock over NFS does **not** reliably arbitrate between clients, so this case is not decided by the flock at all — a remote peer may show up as a held lock whose holder you cannot probe, or the lock may read free while a live peer runs. From here you cannot run a `/proc` liveness check on a pid in another host's namespace, so the guard handles it **conservatively** on both sides: a held lock recorded to another host is assessed **`live-remote`** and refuses, telling you to verify that host is actually down before clearing; and a *free* lock is cross-checked against the `nexus-instance.heartbeat` beacon, which refuses on a fresh remote record and lets a stale one age out into an automatic takeover. This is the one case where the flock alone is not the answer.

**Resolving a block.** Inspect first:

```
monitor/watcher/launcher.sh --instance-status   # prints holder metadata + the assessment
monitor/ng watcher-status                       # one-line instance-lock summary
```

- **Normal case (a live peer).** Use or close the other instance (find it via the recorded `host` / `sandbox` / `tmux`). Same sandbox? Take it over with `monitor/watcher/launcher.sh --replace` (the **succession** path). Different sandbox/host? You cannot `--replace` a peer you cannot see — stop it in its own sandbox, or run your instance against a **different `NEXUS_ROOT`**.
- **False positive (a stale lock).** Once `--instance-status` confirms no live peer owns it (and, for a `live-remote` record, you've confirmed that host is really down), clear it with `rm monitor/.state/nexus-instance.lock` (the **clear-stale** path, distinct from succession). **Caveat:** only `rm` when you are *sure* no live peer holds it — removing the file while a peer is alive lets **both** run (the peer keeps the old inode's lock; your start creates and locks a new file).

## Auto-unstick

The watcher carries a small auto-unstick library (`monitor/watcher/_unstick.sh`) that recovers from a handful of recurring wedge shapes without operator intervention:

- **Case A — permission Enter.** A Claude Code session is sitting on an *Allow / Deny* permission prompt. The watcher detects the prompt fingerprint via `pane-state.sh`, captures a pre-action snapshot for the audit trail under `monitor/.state/unstick/`, sends `Enter`, and logs `case=A action=sent-Enter`.
- **Case B — rate-limit cascade.** Claude Code surfaces an Anthropic rate-limit prompt. Scope is session-wide: a single reset event triggers one cascade across every stuck worker window, not a per-window action. The watcher reads the reset epoch (via the `anthropic-ratelimit-*-reset` headers if `MONITOR_RATELIMIT_PROBE=true` and `ANTHROPIC_API_KEY` is set; otherwise from `monitor.watcher.ratelimit_heuristic_minutes`, default 30 min), waits, then pastes "please continue" into every stuck worker window in one cascade. It sends a heads-up message to the orchestrator naming how many windows it nudged and then waits up to `monitor.watcher.ratelimit_ack_timeout_s` (default 60 s) for a `ratelimit-resume-ack` action-log entry; if none arrives within that window, the watcher logs `orchestrator-unresponsive` and the orchestrator-respawn path may take over.
- **Case C — Anthropic API error.** A transient Anthropic API error wedges the session. The watcher sends an Enter-nudge, backs off if it doesn't help, and logs `case=C action=sent-Enter`.
- **Case D — AskUserQuestion chip-bar (target window only).** The orchestrator's own pane is sitting on an `AskUserQuestion` overlay, which blocks the watcher's paste channel; the watcher sends Escape to dismiss it so emits flow again.
- **Case W — blocked-question relay (worker windows).** A *worker* sitting on an `AskUserQuestion` overlay past a grace period (`monitor.watcher.worker_askuq_grace_seconds`, default 300 s — a human at the pane gets first right of reply) is never keyed by the watcher; instead the watcher synthesizes a decision record (`kind: "blocked_question"`) into the pending-decisions channel so the orchestrator can answer on the operator's behalf.

The unstick library is opt-out via `MONITOR_AUTO_UNSTICK=false` (config: `monitor.watcher.auto_unstick`); default `true`. All unstick actions write append-only to `monitor/.state/watcher-unstick.log`. Every line carries `case=<A|B|C|D|W> action=<...>`; per-window actions add `window=<name> fp=<fingerprint>`, while Case B's *cascade* lines are workspace-scoped and carry neither — so key a parser on `case=`/`action=`, never on `window=` being present. Pre-action pane captures land beside it under `monitor/.state/unstick/<window>.<permission|api-error|askuq|worker-askuq|ratelimit>.<fp>.audit`.

## GraphQL rate-limit handling

When the bot installation's shared GraphQL bucket exhausts (typical trigger: ≥ 4 active workers + orchestrator + watcher all minting installation tokens), `_snapshot_*` calls return `graphql_rate_limit`. Previous behaviour swallowed the error silently; the current shape captures stderr, writes a backoff file at `monitor/.state/graphql-backoff-<surface>`, and emits a `watcher_alert=rate-limit surface=<surface> reset=<epoch>` sentinel into the orchestrator's pane.

Subsequent polls short-circuit until `now >= reset + 30 s`, and in any case no longer than `MONITOR_GRAPHQL_BACKOFF_MAX_SECONDS` (default 900) from when the rate-limit response was observed — past that ceiling the surface re-opens regardless of what the API said, because a suppression of the operator channel must not be able to outlive its own evidence. Sentinel + log dedup via a flag file at `monitor/.state/graphql-alert-emitted-<surface>-<reset>` — one alert per bucket-exhaustion event, not one per poll. A hold that persists past `MONITOR_GRAPHQL_BACKOFF_ANNOUNCE_SECONDS` (default 300) raises a second, out-of-band `watcher_alert=graphql-backoff` sentinel saying that comments on that surface are not reaching the emit. The deliveries surface (App-JWT, separate bucket) is unaffected and keeps surfacing comments during the GraphQL backoff window.

To inspect after a suspected silence:

```bash
tail monitor/.state/watcher-alerts.log
# [2026-05-11T13:42:07-07:00] WARN issue_comments graphql_rate_limit reset=1762901000 reset_iso=...
```

## Crash-loop guard

If the watcher respawns the orchestrator's window more than `monitor.respawn_loop_limit` times (default 3) within `monitor.respawn_loop_window_seconds` (default 120 s), the watcher stops respawning and `sandbox-notify`s the operator once. The history clears on the next successful paste-to-target, or by time as the sliding window empties.

This catches feedback loops where a fresh `claude` session immediately wedges on the same condition that killed its predecessor.

## Manual operation

The watcher is meant to run unattended. For debugging or sharper feedback, drop the polling interval or run a single cycle:

```bash
cd "$(config/load.sh nexus.root)"/monitor

./watcher/main.sh --once                         # one poll cycle, attended foreground, exit
MONITOR_INTERVAL=10 ./watcher/main.sh            # snappier polling, attended foreground
./watcher/launcher.sh                            # spawn the usual headless watcher
                                                 # (--target defaults to config
                                                 #  monitor.target_window; pass it
                                                 #  only to override)
./watcher/launcher.sh --replace                  # kill the recorded watcher first, then spawn
./svc.sh restart watcher                         # same as --replace, via the service CLI
```

(An attended foreground run is legacy hosting, so its first emit
carries the one-shot `--- watcher hosting migration ---` notice —
expected and harmless while debugging.)

The latest emit body is cached at `monitor/.state/last-change.txt` and archived under `monitor/.state/diffs/<ts>_<shortid>.md`. To stop the watcher:

```bash
monitor/svc.sh stop watcher
```

Note that this takes GitHub integration and orchestrator revival down until the next `svc.sh start watcher` / `svc.sh up`. A PID-based lock at `monitor/.state/watcher.lock` (plus the launcher's pidfile-identity check) is the first-line guard against two watchers on one state directory; it is namespace-local and therefore blind to a peer in another sandbox, which is what the flock and beacon above exist for.

## When to suspect the watcher

Symptoms that point at the watcher specifically rather than the orchestrator, the bot, or your network:

- *Comments you posted aren't being processed* and `monitor/svc.sh status` shows the watcher `WEDGED` or `DOWN` (or `ng watcher-status` exits `2`, `3` or `4`). A `DOWN` verdict is recovered by the orchestrator's next `bootstrap.sh` or by the supervisor `Monitor`; `WEDGED` is the supervisor's and `monitor/revive-watcher.sh`'s job. `BUSY` is **not** a symptom — under load the loop period legitimately reaches many minutes. If you can't wait, run `monitor/svc.sh restart watcher` manually.
- *Eligible-comment emits stopped, no rate-limit sentinel in sight* — check `tail monitor/.state/watcher-alerts.log`. The detect-and-react path on GraphQL failures should always log a line, but some bucket-exhaustion modes can present as silence.
- *The watcher keeps respawning the orchestrator and you never asked it to* — crash-loop guard hasn't tripped yet; check `monitor/.state/watcher.log` for `respawn target=<window>` lines and `pane-state.sh <window-index>` to see what state the orchestrator is wedged in.

More failure modes (with cause / fix / prevention) live in [Troubleshooting](troubleshooting.md).
