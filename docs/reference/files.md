# Files

Every file and runtime artifact in a nexus-code checkout, grouped by
role. "Tracked?" means the file is committed to the code repo; state
artifacts under `monitor/.state/` and per-project trees under `work/`
are runtime-only and gitignored.

For the architectural framing see [Architecture](architecture.md).
For per-key config documentation see [Config](config.md).

## Repo root

| Path | Purpose | Tracked? |
|---|---|---|
| `CLAUDE.md` | Cross-cutting agent rules loaded into every Claude Code session in this workspace | yes |
| `README.md` | Repo landing — points at this docs site | yes |
| `LICENSE` | License (MIT) | yes |
| `CHANGELOG.md` | Reverse-chronological changes | yes |
| `CONTRIBUTING.md` | Thin pointer into `docs/contributing/` | yes |
| `SECURITY.md` | Vulnerability disclosure flow (thin pointer; full prose in `docs/admin/security.md`) | yes |
| `watcher` | Symlink to `monitor/watcher/entry.sh` — the user-invoked entry point | yes |
| `nexus` | Symlink to `monitor/watcher/entry.sh` — equivalent alias for `watcher` | yes |
| `package.json` | Project-local Claude Code npm manifest; the `@anthropic-ai/claude-code` version is a maintainer-managed vetted **floor** for fresh installs, not a per-release pin | yes |
| `package-lock.json` | npm lockfile recording the resolved Claude Code version for reproducible `npm ci` | yes |
| `mkdocs.yml` | Docs site config | yes |
| `docs/` | Docs site sources (you are here) | yes |
| `config/` | Config template + loader (see below) | yes |
| `monitor/` | Watcher + bot + helper scripts (see below) | yes |
| `skills/` | Agent-facing skills (see [Skills](skills.md)) | yes |
| `experiments/` | Scratch / exploratory material | yes |
| `work/` | Per-project checkouts (gitignored) | no |
| `reports/` | Append-only agent reports (gitignored) | no |
| `assets/` | Local clone of the asset+issue repo, maintained by `ng upload` (gitignored) | no |

`watcher` at the repo root is the canonical user-invoked entry
point (`nexus` is an equivalent alias): `agent-sandbox tmux
new-session ./watcher [--continue]` boots the whole stack inside an
inner-tmux session — headless watcher + registered services via
`monitor/svc.sh up`, the orchestrator spawned by the watcher, and
the invoking window left running the `services` cockpit.

## `config/`

| Path | Purpose | Tracked? |
|---|---|---|
| `config/nexus.example.yml` | Template documenting every key, default value, and env-var override | yes |
| `config/nexus.yml` | Per-operator config — gitignored, `chmod 600`. Copy `nexus.example.yml`, edit every value | no |
| `config/load.sh` | Tiny Python/pyyaml wrapper. `load.sh <dotted.key> [default]` prints the resolved value | yes |

The loader walks the precedence order: script-local env var →
`config/nexus.yml` → `config/nexus.example.yml` template → hardcoded
fallback inside the script. See [Config](config.md) for every key.

## `monitor/`

The core scripts. Three tiers: the watcher loop (`watcher/`),
agent-facing tooling (`ng`, `mint-token.sh`, etc.), and operator
notifications (`notify.sh`).

| Path | Purpose | Tracked? |
|---|---|---|
| `monitor/README.md` | The original architecture + ops doc; superseded by this docs site but still useful as the source-of-truth for the watcher implementation | yes |
| `monitor/agent-prompt.md` | Launch prompt for the monitor agent (orchestrator) | yes |
| `monitor/BOT_SETUP.md` | First-time GitHub App setup walkthrough | yes |
| `monitor/BOT_ADMIN_GUIDE.md` | Day-2 admin: rotation, troubleshooting, common errors | yes |
| `monitor/infra-resolved.md` | Closed-issue log — themes that have shipped fixes, consulted by `nexus.infra-review` | yes |
| `monitor/ng` | Compact GitHub / watcher helper CLI (every `ng <verb>`) | yes |
| `monitor/mint-token.sh` | Mints / caches the bot's installation access token (also `--jwt-only` for App-level JWT) | yes |
| `monitor/upload-asset.sh` | Commits a local file into the asset repo's `main` branch under `assets/...`; prints a SHA-pinned URL. `ng upload` is a thin shim over this | yes |
| `monitor/notify.sh` | Tiered Pushover / ntfy / SMTP fan-out for events GitHub can't surface | yes |
| `monitor/spawn-worker.sh` | Worker launcher — creates the tmux window, prepends the worker floor, execs `claude --dangerously-skip-permissions` | yes |
| `monitor/pane-state.sh` | Robust pane-state classifier (`state=<idle|busy|user-typing|autosuggest-only|empty|blocked|absent> active=<0|1>`); the helper to call instead of eyeballing `tmux capture-pane` | yes |
| `monitor/svc.sh` | Service cockpit (read-only dashboard) + unified service CLI: `status`, `up`, `start/stop/restart <name>`, `logs <name>` | yes |
| `monitor/bootstrap-recover.sh` | Idempotent whole-stack recovery — relaunches an unhealthy watcher via `launcher.sh` and every unhealthy, unsupervised registry service (headless). `svc.sh up` delegates here | yes |
| `monitor/services.registry.example` | Annotated template for the operator-local `services.registry` (one TAB-separated service per line: name, workdir, launch, healthcheck, optional logfile) | yes |
| `monitor/services.registry` | The operator's actual service registry | no |
| `monitor/claude-loop.sh` | The orchestrator loop wrapper — execs `claude` with the resolved `$CLAUDE_BIN`, `--dangerously-skip-permissions`, `--settings`, and `--continue`, suppressing the resume dialog via `CLAUDE_CODE_RESUME_*` env vars | yes |
| `monitor/spawn-fresh-orchestrator.sh` | Cold-spawn an orchestrator window (no resume), used when the session pin is stale/absent. (Lives under `watcher/`; see that table) | yes |
| `monitor/retire-preflight.sh` | The MANDATORY synchronous pre-kill gate — reads *live* pane state and returns `safe=<0\|1>` before any worker `tmux kill-window`; blocks while a `skeptic-pending` marker is live (`test-retire-preflight.sh` covers it) | yes |
| `monitor/skeptic-channel.sh` | The worker↔skeptic comms channel + `await` park used by `nexus.skeptic` (await-hang marker under `.state/skeptic/pending/`) | yes |
| `monitor/worker-heartbeat.sh` | Worker liveness writer invoked from `worker-settings.json` hooks; parses the hook payload (`.tool_name`, `.session_id`, `.notification_type`) into `heartbeat/<window>.json` | yes |
| `monitor/declare-wait.sh` / `monitor/declare-no-wait.sh` | Worker self-declarations of an external-wait (e.g. a long Slurm job) vs. no-wait, written keyed on `$NEXUS_WORKER_WINDOW` so the idle classifier refines `idle-orphan-async` | yes |
| `monitor/paste-followup.sh` | Deliver a follow-up message into a running worker/orchestrator window (VI-mode-hardened load-buffer/paste-buffer pattern) | yes |
| `monitor/user-pat.sh` | Resolves the user's `gh auth token` PAT for surfaces the bot's installation token can't reach (`ng fetch-asset`, private-package installs) | yes |
| `monitor/_claude-bin.sh` | Shared `$CLAUDE_BIN` resolver sourced by every spawn surface: env override → `node_modules/.bin/claude` → system `claude` | yes |
| `monitor/install-claude-local.sh` | Project-local Claude Code install/upgrade via `npm ci`/`npm install`; idempotent fast-path skips when the installed `--version` matches the pin | yes |
| `monitor/install-hpc-skills.sh` / `monitor/install-labsh.sh` / `monitor/_install-lib.sh` / `monitor/install-prompt.md` | Operator-setup installers (<your-institution> skill pack, labsh) and shared install helpers | yes |
| `monitor/bootstrap-install.sh` | First-run bootstrap launcher — execs `claude --dangerously-skip-permissions` against the install prompt to set the stack up from a fresh clone | yes |
| `monitor/jupyter-up.sh` / `monitor/jupyter-kernel-crawl.sh` / `monitor/jupyter-health.sh` | JupyterLab-as-a-service activation, work-root kernel discovery, and healthcheck (see `nexus.jupyter`) | yes |
| `monitor/labsh-root.sh` / `monitor/labsh-supervised.sh` / `monitor/_lab-context.sh` | labsh project-agent access, supervised-revival wrapper, and shared lab-context resolver | yes |
| `monitor/_cc-version.sh` / `monitor/cc-auto-update-apply.sh` / `monitor/cc-auto-update-prompt.md` / `monitor/cc-auto-update-watchdog-prompt.md` / `monitor/cc-restart-watchdog-loop.sh` | The gated Claude-Code self-update machinery (version resolution, apply, watchdog prompts/loop); see `skills/nexus.cc-update/GUIDE.md` | yes |
| `monitor/watcher-supervise-tick.sh` / `monitor/revive-watcher.sh` / `monitor/boot-recover.sh` / `monitor/boot-recover.session-start-hook.json` | Watcher supervision tick, manual watcher revival, and boot-time stack recovery (SessionStart hook) | yes |
| `monitor/calibrate-pressure-thresholds.sh` | One-shot calibration of context-pressure thresholds | yes |
| `monitor/git-https-setup` | Helper to wire git HTTPS credential flow for the bot | yes |
| `monitor/async-launch-patterns.conf` | Regex patterns `hooks/async-launch-detect.sh` matches to spot background spawns | yes |
| `monitor/test-interactive-sessions.sh` / `monitor/test-retire-preflight.sh` | Top-level `monitor/` unit tests (interactive-session detection; retire-preflight gate) | yes |

### `monitor/hooks/`

Claude Code hook handlers wired from `orchestrator-settings.json` /
`worker-settings.json`; each reads the hook-event JSON payload on stdin.

| Path | Purpose | Tracked? |
|---|---|---|
| `monitor/hooks/orchestrator-session-pin.sh` | UserPromptSubmit hook — pins the orchestrator session-id to `.state/orchestrator-session-id` for `--resume`; gated on `NEXUS_IS_ORCHESTRATOR=1` | yes |
| `monitor/hooks/block-askuserquestion.sh` | PreToolUse hook — blocks `AskUserQuestion` calls so the orchestrator never strands itself on a dialog | yes |
| `monitor/hooks/async-launch-detect.sh` | PostToolUse hook — spots background spawns (`ScheduleWakeup`, async bash) from `.tool_input.command` | yes |
| `monitor/hooks/decision-emit.sh` / `monitor/hooks/decision-mark-unresolved.sh` | Emit / un-resolve structured worker-decision rows (fingerprint + dedup) for the orchestrator | yes |
| `monitor/hooks/over-limit-emit.sh` | StopFailure hook — writes a per-window over-limit stamp when `.error_type == "rate_limit"`, probing plausible `reset_at` field paths | yes |
| `monitor/hooks/turn-failure-emit.sh` | StopFailure hook — emits turn-failure info even when the session crashed | yes |
| `monitor/hooks/_cause_classify.sh` | Shared helper that classifies a turn-end/failure cause from the payload | yes |

### `monitor/docs/`

| Path | Purpose | Tracked? |
|---|---|---|
| `monitor/docs/agent-state-machine.md` | The worker/orchestrator state-machine reference (pane states, transitions) | yes |
| `monitor/docs/orchestrator-guide.md` | Long-form orchestrator operating guide | yes |

### `monitor/cc-harness/`

The Claude-Code-update gate harness — exercises the spawn/respawn
surfaces against a mock backend before a version bump is promoted.

| Path | Purpose | Tracked? |
|---|---|---|
| `monitor/cc-harness/gate.sh` | The gate entry point — runs the harness and returns a pass/fail verdict for a candidate Claude Code release | yes |
| `monitor/cc-harness/demo.sh` | Demonstration / smoke driver for the harness | yes |
| `monitor/cc-harness/mock-backend.py` | Mock Claude backend the harness drives so spawns run offline/deterministically | yes |
| `monitor/cc-harness/lint-no-mass-kill.sh` | Lint guard asserting no spawn path can mass-kill windows | yes |
| `monitor/cc-harness/_lib.sh` | Shared harness helpers | yes |
| `monitor/cc-harness/README.md` | Harness rationale + usage | yes |

## `monitor/watcher/`

The watcher and its tests. The protocol is documented at
[Watcher protocol](watcher-protocol.md); this table is the file
inventory.

| Path | Purpose | Tracked? |
|---|---|---|
| `monitor/watcher/entry.sh` | User-invoked entry. Reconciles `--continue` onto the session-id pin, brings up the stack via `svc.sh up`, renames the current window to `services` and execs the `svc.sh` cockpit | yes |
| `monitor/watcher/main.sh` | The continuous watcher loop — snapshot, classify, paste, archive, heartbeat, prune | yes |
| `monitor/watcher/launcher.sh` | Watcher (re)spawn. Launches `main.sh` headless (setsid-detached, `WATCHER_WINDOW=headless`, log `monitor/.state/watcher.log`), verifies the pidfile publish, sweeps a legacy `watcher` window | yes |
| `monitor/watcher/_hosting_migration.sh` | Legacy-hosting detection (`WATCHER_WINDOW != headless`) + the one-shot migration-notice body the startup sweep emits | yes |
| `monitor/watcher/bootstrap.sh` | Agent-side on-wake check. Verifies the watcher is alive (heartbeat + pid + tmux window), respawns via `launcher.sh` if stale, prints archived diffs newer than `last-ack.txt`, advances `last-ack.txt` | yes |
| `monitor/watcher/_lib.sh` | Shared helpers: heartbeat / lock parsers, `_watcher_alive`, `_classify_diff`, `_target_window_present`, `_respawn_loop_check` | yes |
| `monitor/watcher/_github.sh` | `snapshot_github` + helpers — three GraphQL surfaces (issues, PR conversation, PR review threads, new issues), `_graphql_polling_gate`, `_graphql_backoff_active`, `_watcher_handle_graphql_failure` | yes |
| `monitor/watcher/_deliveries.sh` | `snapshot_deliveries` — polls `/app/hook/deliveries` on the App-JWT bucket; surfaces cross-repo bot-relevant events | yes |
| `monitor/watcher/_mentions.sh` | `snapshot_mentions` — cross-repo mentions search for repos where the App is NOT installed | yes |
| `monitor/watcher/_unstick.sh` | Auto-unstick library: case A (permission Enter), case B (rate-limit cascade + Anthropic API probe + orchestrator ack), case C (transient API error Enter-nudge) | yes |
| `monitor/watcher/_idle_probe.sh` | Idle-worker classifier: enumerates worker windows, classifies into `wrapped`/`wrapped-but-stub`/`no-wrap-up`/`idle-too-long`/`pane-absent`/`retained`, dedupes transitions | yes |
| `monitor/watcher/_respawn.sh` / `_respawn_async.sh` / `_respawn_prompts.sh` | Orchestrator respawn library: resume-mode choice (`--resume <pin>` vs cold fresh spawn), launcher composition, duplicate-orchestrator adjudication, and the respawn prompt bodies | yes |
| `monitor/watcher/_config.sh` | Watcher config-knob resolution (thresholds, cadences) | yes |
| `monitor/watcher/_emit_dedup.sh` / `_emit_filters.sh` | Emit signal-vs-noise dedup and the filters that suppress noise-only sections | yes |
| `monitor/watcher/_compose_nudge.sh` | Composes the unstick/follow-up nudge text delivered into a stuck pane | yes |
| `monitor/watcher/_functional_check.sh` | Post-emit functional check — reaction scan over the eligible-comments section | yes |
| `monitor/watcher/_orchestrator_liveness.sh` | Orchestrator liveness machine (heartbeat / paste-received / jsonl-mtime fallback) | yes |
| `monitor/watcher/_over_limit.sh` | Rate-limit / over-limit detection + re-wake scheduling | yes |
| `monitor/watcher/_service_health.sh` | Registered-service healthcheck runner → the `--- service health ---` emit (`nexus.service-recovery`) | yes |
| `monitor/watcher/_scheduler.sh` | Cadence scheduler for the watcher's periodic surfaces | yes |
| `monitor/watcher/_target_absent.sh` | Detect-and-recover when the target (orchestrator) window is absent | yes |
| `monitor/watcher/_cc_update.sh` / `_cc_auto_update.sh` | DETECT → INFORM half of the gated Claude-Code self-update loop (emits `--- claude code update available ---`) | yes |
| `monitor/watcher/_version_restart.sh` | Version-aware self-restart — detects watcher source-set drift after a pull and re-execs (issue `#186`) | yes |
| `monitor/watcher/_test_helpers.sh` | Shared helpers for the watcher test suite | yes |
| `monitor/watcher/spawn-fresh-orchestrator.sh` | Cold-spawn an orchestrator with no resume (safe degradation when the pin is stale/absent) | yes |
| `monitor/watcher/run-tests.sh` | Runs the whole `monitor/watcher/test-*.sh` suite | yes |
| `monitor/watcher/fixtures/` | Stub gh / tmux / mint-token binaries + `.ansi` pane fixtures used by the test scripts | yes |
| `monitor/watcher/test-*.sh` | Mock-tmux / mock-gh unit tests (~125 files, one per behavioural surface; run all via `run-tests.sh` or any with `bash <file>`) | yes |

The suite is large — roughly **125** `test-*.sh` files under
`monitor/watcher/` (plus a couple at the `monitor/` top level), one per
behavioural surface. The table below is a **curated sample** of the
load-bearing ones, not the full list; run the whole suite with
`monitor/watcher/run-tests.sh`.

| Test file | Covers |
|---|---|
| `test-lib.sh` | `_lib.sh` standalone classifiers (`_target_window_present`, `_classify_diff`, …) |
| `test-unstick.sh` | `_unstick.sh` cases A / B / C |
| `test-emit-gate.sh` | Compose-report / signal-vs-noise / resurface |
| `test-graphql-gate.sh` | `_graphql_polling_gate` cadence + bucket-floor |
| `test-snapshot-github.sh` | `snapshot_github` happy path |
| `test-snapshot-github-failure.sh` | Detect-and-react on GraphQL rate limit + other failures |
| `test-snapshot-deliveries.sh` | `_deliveries.sh` end-to-end (curl mock) |
| `test-snapshot-mentions.sh` | `_mentions.sh` cross-repo mention search |
| `test-idle-probe.sh` | `_idle_probe.sh` six-class transitions + dedup |
| `test-pane-state.sh` | `monitor/pane-state.sh` classifier across fixtures |
| `test-entry.sh` | `entry.sh` self-checks, pin reconciliation (`--continue`), `svc.sh up` delegation, cockpit hand-off |
| `test-hosting-migration.sh` | `_hosting_migration.sh` legacy-hosting detection + one-shot migration notice |
| `test-respawn-loop-guard.sh` / `test-respawn-loop-integration.sh` | `_respawn_loop_check` rate limit and end-to-end respawn behaviour |
| `test-ng-*.sh` | Each `ng` verb's edge cases (state-dir resolution, report init/check, fetch-asset, reply --repo, wrap-up) |

## `monitor/.state/` (runtime; not tracked)

Everything under `.state/` is local runtime state — never committed,
never shared across operators. The directory is created on first
watcher launch.

| Path | Purpose | Retention |
|---|---|---|
| `watcher-heartbeat` | pid + ISO ts + target; mtime-bumped every cycle | overwritten each poll |
| `watcher.pid` | Self-published watcher PID — the headless-hosting liveness anchor (`launcher.sh` and `svc.sh` validate the owner's identity, not just `kill -0`) | watcher lifetime |
| `watcher.lock` | PID-based lock; prevents two watchers on the same state dir | watcher lifetime |
| `watcher-target` | Current target window (written at startup) | watcher lifetime |
| `services/<name>.pid` | Per-registry-service headless-supervisor pidfile (`bootstrap-recover.sh` / `svc.sh`) | service lifetime |
| `orchestrator-session-id` | The orchestrator session-id pin — written at spawn and on every orchestrator turn; the watcher's `--resume` target. `./watcher` (no `--continue`) archives it to `*.archived.<epoch>` | until archived |
| `watcher.log` | Append-only watcher log (startup, emits, paste failures, respawns) | manual rotation |
| `diffs/<ts>_<shortid>.md` | Archived emit bodies — one per signal cycle | pruned at `monitor.diff_retention_days` (default 7) |
| `last-ack.txt` | ISO timestamp of the newest archived diff the orchestrator has read | advances on bootstrap |
| `last-snapshot.txt` | Persistent baseline for local-state diffing (carries across watcher restarts) | overwritten on absorb |
| `last-change.txt` | Cache of the most recent emit body | overwritten each emit |
| `action-log.jsonl` | Append-only JSONL trace of meaningful actions (`{ts,agent,event,...}`) | manual rotation |
| `dashboard.md` | Cache of the dashboard middle (between `NEXUS_DASHBOARD_START`/`END` markers) | overwritten on `ng dashboard get/put` |
| `dashboard-updated.ts` | ISO timestamp of the last successful `ng dashboard put` | overwritten each push |
| `processed-comments.txt` | Local cache of `comment:<id>` / `issue:<n>` entries already reacted on (propagation-lag guard) | append-only |
| `watcher-unstick.log` | Auto-unstick action log — one line per detection / send-Enter / backoff / cascade / heads-up / ack | manual rotation |
| `unstick/<window>.<case>.{fp,tries,epoch,audit}` | Per-(window, case) fingerprint + retry counter + pre-action pane capture | overwrites in place |
| `unstick/ratelimit.{reset,cascade,last-wait}.epoch` | Case-B session state (probed reset, last cascade, last waiting-log) | cleared on cascade or expiry |
| `watcher-alerts.log` | `[iso] WARN <surface> <classification> ...` lines from `_watcher_handle_graphql_failure` | append-only |
| `graphql-backoff-<surface>` | Per-surface GraphQL reset-epoch; per-surface short-circuit while present + 30 s grace | self-clears after reset |
| `graphql-alert-emitted-<surface>-<epoch>` | Flag: rate-limit sentinel + log already emitted for this (surface, reset) pair | self-clears with backoff file |
| `graphql-other-last-log-<surface>` | Marker for the once-per-10-min throttle on non-rate-limit GraphQL failures | self-overwrites |
| `graphql-gate-last-log-<kind>` | Throttle marker for `_graphql_polling_gate` alert lines (probe_failed, probe_malformed, below_floor) | self-overwrites |
| `last-delivery-cursor.txt` | Newest delivery GUID seen by `snapshot_deliveries` | overwrites each poll |
| `last-mention-cursor.txt` | Max `databaseId` seen by `snapshot_mentions` | overwrites each poll |
| `bot-installed-repos.txt` | `owner/repo` cache for `snapshot_mentions` repo-skip filter | refreshed at most once per 24 h |
| `idle-state.tsv` | `(window, class)` set from the previous idle-probe cycle; drives transition dedup | overwrites each cycle |
| `respawn-history.txt` | Sliding window of `epoch tag` lines for `_respawn_loop_check` | append + auto-prune |
| `respawn-guard-tripped` | Flag file written once on the ok→tripped transition; cleared on next successful paste | manual or auto-clear |

## `reports/` (runtime; not tracked)

The append-only project log. One file per significant state change,
named `<project>_<YYYY-MM-DD>_<HHMMSS>_<slug>.md`. The directory is
gitignored — any cross-repo embed must go through `ng upload` first.

See [`skills/nexus.report`](skills.md#nexusreport) for the schema
and [`docs/operating/reports.md`](../operating/reports.md) for the
operator workflow.

## `work/` (runtime; not tracked)

Per-project clones. Each `work/<project>/` is its own git repo. The
watcher snapshots `HEAD` and `clean|dirty` for each in its
`--- git ---` section; that section is suppressed as noise unless
paired with a real change (reports, tmux windows, bells).

The convention: never create a `CLAUDE.md` under `work/<project>/`
— it would leak nexus-specific rules into a foreign repo. Project
agents read the workspace `CLAUDE.md` instead.

## `skills/`

The agent-facing skill library. 14 skills today, one directory each.
All but one hold a `SKILL.md` with YAML frontmatter and a body;
`nexus.cc-update` ships a path-referenced `GUIDE.md` instead so it is
never auto-loaded into a worker's skill index.

| Path | Body |
|---|---|
| `skills/nexus.tmux-spawn/SKILL.md` | Delegating work via the prompt-file + launcher pattern |
| `skills/nexus.window-cleanup/SKILL.md` | Closing idle worker windows |
| `skills/nexus.worker-defaults/SKILL.md` | The injected worker safety floor |
| `skills/nexus.bot/SKILL.md` | Bot identity for GitHub writes |
| `skills/nexus.report/SKILL.md` | Report schema + Infrastructure Issues feedback loop |
| `skills/nexus.infra-review/SKILL.md` | Periodic infrastructure meta-review |
| `skills/nexus.self-fix/SKILL.md` | Editing the nexus itself |
| `skills/nexus.dashboard/SKILL.md` | Overview-issue identity block + dashboard schema |
| `skills/nexus.skeptic/SKILL.md` | Independent adversarial validation of a worker's result |
| `skills/nexus.service-recovery/SKILL.md` | Response protocol for a service-health emit |
| `skills/nexus.jupyter/SKILL.md` | JupyterLab-as-a-service for nexus projects |
| `skills/nexus.private-package-install/SKILL.md` | Installing private GitHub packages via the user's PAT |
| `skills/nexus.cron-state-tsv/SKILL.md` | Durable session-state for recurring `CronCreate` agents |
| `skills/nexus.cc-update/GUIDE.md` | Evaluating a Claude Code release before bumping the pin (path-referenced, not auto-loaded) |

See the [Skills catalog](skills.md) for trigger conditions and
audience per skill.

## `assets/` (runtime; not tracked)

Local clone of the asset+issue repo (`github.asset_repo`). Maintained
by `monitor/upload-asset.sh`: copies the source file into
`assets/<repo-path>`, commits as the bot, pushes to `main`. The
printed URL is SHA-pinned to the post-push commit.

The `assets/` tree on the remote follows this convention:

- `assets/<issue-number>/<basename>` — when `--issue N` is passed.
- `assets/reports/<basename>` — for sources whose path contains
  `reports/`.
- `assets/general/<basename>` — everything else without `--issue`.

URLs use `blob/<sha>/` for `.md` / `.ipynb` (renders as a page);
everything else gets `raw/<sha>/` (302 to a same-domain signed CDN
URL that renders for any logged-in github.com viewer). See
`monitor/README.md` "Embedding files" for the rationale and the
full failure matrix.

## Tracked files at a glance

If you want to know what the code repo ships, this is the canonical
list — `git ls-files` after a fresh clone. Everything else is
runtime, per-operator, or pulled in on demand.

```
.github/workflows/         CI (docs build, etc.)
config/                    nexus.example.yml + load.sh
docs/                      this docs site (mkdocs sources)
experiments/               scratch / exploratory material
mkdocs.yml                 docs site config
monitor/                   watcher + bot + helpers + agent prompt
  README.md  agent-prompt.md  BOT_SETUP.md  BOT_ADMIN_GUIDE.md
  ng  mint-token.sh  notify.sh  upload-asset.sh  spawn-worker.sh  pane-state.sh
  claude-loop.sh  retire-preflight.sh  skeptic-channel.sh  worker-heartbeat.sh
  install-*.sh  jupyter-*.sh  labsh-*.sh  _cc-version.sh  cc-auto-update-*
  hooks/                   Claude Code hook handlers (session-pin, decision-emit, …)
  docs/                    agent-state-machine.md  orchestrator-guide.md
  cc-harness/              gate.sh + mock-backend.py — cc-update gate
  watcher/                 entry, main, launcher, bootstrap, _*.sh helpers, ~125 test-*.sh
  infra-resolved.md
skills/                    one dir per nexus.* skill (14)
watcher  nexus            symlinks → monitor/watcher/entry.sh
package.json  package-lock.json     project-local Claude Code npm pin
CLAUDE.md  README.md  LICENSE  CHANGELOG.md
CONTRIBUTING.md  SECURITY.md
```
