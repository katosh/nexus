# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project does not yet have tagged releases — entries
accumulate under `[Unreleased]`. See
[`docs/contributing/release.md`](docs/contributing/release.md)
for the current release convention.

## [Unreleased]

### Added

- **Worker respawn on recovery (`bootstrap-recover.sh` step 3 +
  `--no-workers`).** Boot recovery now also respawns the worker
  agents that were active in the last watcher snapshot
  (`.state/last-snapshot.txt`, `--- tmux ---` section), via the
  canonical resume surface `spawn-worker.sh --resume <window>`
  (issue 197) — never a hand-rolled `claude --resume`. A snapshot
  window qualifies iff it is not infra (`orchestrator`, `services`,
  `watcher`, registry-named legacy service windows excluded), it has
  a `spawn` event in `.state/action-log.jsonl` (recovery only owns
  nexus-spawned workers), and that `spawn` is its latest lifecycle
  event — a later `wrap-up` / `window-close` means the worker already
  handed off, and the orchestrator's dispatch loop owns continuations
  of wrapped work. Idle-but-unwrapped workers ARE respawned.
  Idempotent (already-alive windows never double-spawned), bounded
  (`recover.max_workers` config, default 12, excess skipped with a
  loud notice), loud-on-skip (unresolvable sessions are logged, never
  fatal). Flag matrix: default = watcher + services + workers;
  `--no-services`/`--watcher-only` (core-only) also skips workers;
  the new `--no-workers` skips only the worker respawn;
  `--services-only` skips just the watcher. `boot-recover.sh`'s
  health gate now also fires on the `would resume` dry-run marker.
  Tests: `watcher/test-bootstrap-recover.sh` (worker identification +
  inclusion criteria, idempotency, flag matrix, unresolvable-session
  skip, cap), `watcher/test-boot-recover.sh` (worker-only-need gate).
  (issue 198)

- **Core-only startup flag (`--no-services`).**
  `monitor/bootstrap-recover.sh --no-services` (synonym:
  `--watcher-only`; also reachable as `monitor/svc.sh up
  --no-services`) brings up the nexus core alone — the watcher, which
  then revives the orchestrator via its own liveness machinery — and
  skips every service registered in `services.registry`. Idempotent
  like the rest of recovery; combining it with `--services-only` is
  rejected with a clear error (exit 1) since together they would
  recover nothing. `svc.sh up` now propagates a nonzero
  `bootstrap-recover.sh` exit instead of swallowing it. Tests:
  `watcher/test-bootstrap-recover.sh` (core-up with zero services,
  healthy-stack no-op, bad-combo rejection),
  `watcher/test-svc.sh` (`up --no-services` pass-through + failure
  propagation). (issue 195)

- **JupyterLab as a service (`monitor/jupyter-up.sh` +
  `skills/nexus.jupyter`).** One idempotent command turns a project's
  [labsh](https://github.com/katosh/labsh) JupyterLab into a
  registry-managed service: ensures a project kernel (`labsh kernel
  add`, or `--venv DIR` → `labsh kernel register` for existing/Lmod
  venvs), maintains a `jupyter-<project>` row in `services.registry`,
  and launches `monitor/labsh-supervised.sh` (a watchdog that bounces
  unhealthy servers, follows labsh's port auto-increment via
  `.jupyter/labsh-service.env`, adopts hand-started servers, and runs
  `labsh stop` on TERM) through `recover_service` — so
  `bootstrap-recover.sh` revives it on boot and `svc.sh` manages it.
  `monitor/jupyter-health.sh` is the shared authenticated healthcheck
  (`/api/status` with the project token; token rotation self-heals via
  a supervised bounce). `--down` deactivates (stop + deregister),
  `--status` reports. The `nexus.jupyter` skill encodes the foolproof
  default: a bare "jupyter session" request → `jupyter-up.sh <dir>`,
  then `labsh kernel exec/inspect` per `<yourlab>.labsh`. Tests:
  `watcher/test-jupyter-service.sh` (hermetic stub labsh) and
  `watcher/test-integration/test-jupyter-service-real.sh`
  (`RUN_INTEGRATION=1`, real servers/venvs/kernels in throwaway `/tmp`
  projects). (issue 184)

### Changed

- **Work-root JupyterLab service renamed `jupyter-workroot` →
  `jupyterlab`; cockpit shows the tokened URL; `logs` includes the
  server's output.** The single root service registered by
  `jupyter-up.sh --root` (and advertised by the `svc.sh` cockpit when
  dormant) is now plainly `jupyterlab`; `--root` activation migrates a
  leftover legacy `jupyter-workroot` row in place (stops/cleans its
  supervisor, re-registers under the new name — a stale row is never
  fatal). The cockpit's `DETAIL` column, now the final untruncated
  column (the seldom-useful `WINDOW` column is gone), renders an UP
  labsh service's reachable, directly-openable URL —
  `http://<fqdn>:<port>/lab?token=…`, FQDN-rewritten on external binds
  (issue 252's rule), degrading to the bare URL when no token is
  resolvable and never erroring the cockpit. `svc.sh logs <name>` and
  the cockpit log split tail the jupyter server's own stdout
  (`.jupyter/labsh.bg.log`, which prints the access URL on startup)
  alongside the supervisor log. (issue 191)

- **`./watcher` retargeted to the unified headless start; upgrade is
  self-delivering.** The user entry point (`monitor/watcher/entry.sh`;
  new alias symlink `./nexus`) no longer hosts the watcher in a
  window or spawns the orchestrator itself: it self-checks (tmux +
  agent-sandbox), brings the stack up via `monitor/svc.sh up`
  (headless watcher + registry services; the watcher then spawns the
  orchestrator), and leaves the invoking window running the `svc.sh`
  cockpit (window name `services`). `--continue` is reconciled onto
  the orchestrator session-id pin
  (`monitor/.state/orchestrator-session-id`): the default boot
  archives the pin (timestamped, never deleted) so the cold start is
  fresh; `--continue` keeps it so the watcher resumes that exact
  session via `claude --resume <sid>` — without a valid pin the
  watcher spawns fresh, never `claude --continue` (issue 200).
  Additionally, a watcher that starts under **legacy window hosting**
  (`WATCHER_WINDOW != headless`, the launcher's marker) now surfaces
  a one-shot `--- watcher hosting migration ---` notice in its
  startup-sweep emit — converge steps: pull BEFORE restart, then
  `monitor/svc.sh restart watcher` — and keeps operating normally
  (new module `monitor/watcher/_hosting_migration.sh`). New page
  [`docs/operating/upgrading.md`](docs/operating/upgrading.md)
  documents the mechanism and the manual checklist; the windowed-era
  descriptions across `README.md`, `docs/`, and `monitor/README.md`
  were swept to the headless model. (<your-org>/<your-nexus> issue 182)

- **Watcher folded into the services model — headless, no tmux
  window.** `watcher/launcher.sh` now launches `main.sh`
  `setsid`-detached with stdout/stderr appended to
  `monitor/.state/watcher.log`, verifies the self-published pidfile
  before reporting success (exit 3 on a spawn that didn't stick), and
  sweeps a leftover legacy `watcher` window on the next spawn.
  `_watcher_alive` / `_watcher_reason` drop the tmux-window-presence
  check (pid identity + heartbeat age are the whole story; the
  window parameter is retained-and-ignored for arity compatibility).
  `ng watcher-status` reports `hosting: headless` and flags a legacy
  window. The canonical bounce is `monitor/svc.sh restart watcher`
  (== `launcher.sh --replace`); `--window`/`--force` are accepted
  but ignored. The cockpit tails the watcher log via key `0` /
  `svc.sh logs watcher`.

- **`svc.sh` grew into the stable stack surface.** Flicker-free
  in-place repaint; log picks no longer steal focus (the
  `select-pane -T` titling side effect); single-key controls;
  pinned core rows (watcher tri-state liveness, orchestrator window
  + turn-end heartbeat). New explicit verbs: `status` / `up`
  (idempotent whole-stack bring-up via `bootstrap-recover.sh`; the
  watcher then spawns/revives the orchestrator) / `start` / `stop`
  (process-group TERM, KILL escalation, loud warning if the
  healthcheck survives) / `restart` / `logs`. Sandbox-agnostic by
  design — prefix `agent-sandbox` explicitly when wanted.

- **Respawn hardening after the 2026-06-02 false-positive-respawn +
  watcher-death incident.** Two root causes, both fixed:

  - **Target-absent respawn now requires confirmed absence.**
    `monitor.agent_missing_respawn_delay` default raised 0 → 3 (four
    consecutive absent observations at the 2 s probe cadence, ~8 s),
    and a new pre-launch re-verification
    (`_respawn_verify_target_absent` in `monitor/watcher/_respawn.sh`)
    runs at the moment of decision: a fresh window probe, a pane scan
    for a live orchestrator process (identified via the
    `NEXUS_IS_ORCHESTRATOR=1` environment marker, with tmux
    rename-race healing), and a liveness-signal comparison against
    the absent-streak start each independently abort the respawn.
    Aborts are logged and action-logged
    (`respawn-aborted-reverify`).

  - **A false-positive respawn can no longer take the watcher down.**
    The recovery prompt pasted into a respawned orchestrator used to
    instruct it to *kill the watcher* when it discovered the respawn
    was wrong — which is exactly what happened on 2026-06-02, leaving
    the workspace unmonitored. The prompt now mandates a stand-down
    protocol scoped to the duplicate itself: restore the original
    agent's window name, record the false positive, and remove ONLY
    the duplicate's own window (by window id). It explicitly forbids
    killing the watcher, the tmux session, or any other window. The
    watcher additionally traps SIGHUP to log its own demise
    (attributable post-mortem instead of a clean log tail) and to
    release its pidfile/lock on `tmux kill-window -t watcher`.

- **Watcher / orchestrator rethink** (issue #72; closes the seven
  detection regressions catalogued there). Five coordinated
  changes shipped together so we don't re-introduce the
  brittle-layering problem the meta-issue diagnosed:

  - **Classifier hardening.** `pane-state.sh` now distinguishes
    `empty` (renderer transient — claude alive in the pane's
    process tree) from `absent` (no live claude). Probe-side,
    `_idle_probe.sh` maps only `absent` and `blocked` to the
    inviolable `pane-absent` class; `empty` becomes a
    skip-and-retry-next-cycle signal. Closes regressions 1 + 2.

  - **Lifecycle anchors.** `monitor/spawn-worker.sh` writes an
    authoritative `spawn` action-log event AND seeds the
    engagement-log with epoch=now at window creation. The idle
    probe's wrap-up matcher scopes candidates to entries newer
    than the current-lifecycle spawn ts, so a stale wrap-up from
    a prior life of a recycled window-name (or from before
    `claude --continue`) drops out automatically. New knob
    `monitor.idle_pool_spawn_grace_seconds` (default 120s) guards
    the gap between `tmux new-window` and `claude` actually
    starting. Closes regression 3.

  - **Retain persistence.** `spawn-worker.sh` and
    `respawn_agent` set `tmux remain-on-exit on` at window
    creation. The pane survives a claude exit so the operator
    can revisit a retained worker's transcript and pane-state.sh
    can classify the post-exit pane as `state=absent` instead of
    the window vanishing silently. Closes regression 5.

  - **Emit completeness.** Every emit now starts with a one-line
    workspace prelude (`N busy | N idle | N retained | N
    idle-too-long | N pane-absent`). New section
    `--- workspace snapshot ---` lists every tracked worker
    window with its current pane-state and idle-age; force-
    included on emits hitting the configured cadence
    (`monitor.full_state_emit_interval_seconds`, default 600s)
    AND on the startup-sweep emit. Pure-cadence emits are tagged
    `poll-full-state` in the archive. Transition emits in
    between stay narrow. Closes regression 6.

  - **Decision helpers.** New verbs `ng spawn-decision <window>`
    (advisory continue-vs-spawn classifier) and
    `ng wrap-up-check <window>` (verifies a worker has completed
    its hand-off obligations before close). Both mirror the
    policy in `skills/nexus.window-cleanup`. Tests under
    `monitor/watcher/test-ng-spawn-decision.sh`.

  New config knobs:
  `monitor.idle_pool_spawn_grace_seconds` (default 120),
  `monitor.full_state_emit_interval_seconds` (default 600).
  Existing knobs unchanged; full back-compat for legacy windows
  with no spawn-event anchor.

  - **Per-spawn Claude Code hook scaffolding.** `spawn-worker.sh`
    now extracts the JSON block following the
    `<!-- worker-hooks-default -->` marker in
    `skills/nexus.worker-defaults/SKILL.md` and (when non-empty)
    writes it to `/tmp/spawn-hooks-<window>.<pid>.json`, passing
    `--settings <path>` to claude. The launcher trap-cleans the
    file on exit. Default block is `{}` so back-compat is the
    empty case — user-global hooks remain unaffected. Operators
    populate the block to apply nexus-wide hooks (heartbeat
    writes, notification surfacing, etc.) on every spawn. Hook
    schema, reliable events, and clobbering caveats documented
    in the SKILL's new `## Worker hooks` section. Tests in
    `test-spawn-worker.sh` cover both the empty-default
    (no `--settings`) and populated paths.

### Added

- **Docs site scaffolding** (`mkdocs.yml`, `docs/`,
  `.github/workflows/docs.yml`, `docs/requirements.txt`).
  mkdocs-material site auto-deployed to GitHub Pages on every
  push to `main`. Full content fan-out across five sections
  (Getting started, Operating, Admin, Reference, Contributing)
  follows in subsequent PRs. (PR #13.)
- **`ng wrap-up` verb** — one-shot end-of-task hand-off: upload
  report, post link comment, rocket trigger comment, log the
  event. Supports `--comment-body-file` for bespoke comment
  prose with `{{REPORT_URL}}` token expansion, `--no-comment`
  to skip the comment step, `--allow-stub` for intentional
  checkpoint wraps. Runs `ng report-check` as a pre-flight and
  refuses stub reports. (PR #4.)
- **`ng report-init` verb** — writes a frontmatter'd skeleton
  at the canonical
  `<reports-dir>/<project>_<YYYY-MM-DD>_<HHMMSS>_<slug>.md`
  path, capturing session-id + tmux window automatically.
- **`ng report-check` verb** — validates a report against the
  schema (frontmatter present, all five canonical sections,
  body ≥ `monitor.report_min_chars`, no placeholder markers).
  Used by `ng wrap-up` as pre-flight and by the watcher's
  idle-probe to classify `wrapped-but-stub`.
- **`ng fetch-asset` verb** — user-PAT bridge for fetching
  `github.com/user-attachments/...` URLs the bot's installation
  token can't reach. Writes bytes locally so the agent reads a
  file path instead of poisoning the session with a 404 on the
  attachments host. (PR #73 upstream.)
- **`ng reply --repo OWNER/REPO`** — cross-repo reply target;
  overrides the cwd-derived origin. (PR #4.)
- **Idle-worker probe** (`monitor/watcher/_idle_probe.sh`) —
  combines tmux's `#{window_activity}` with `pane-state.sh`
  classification to surface really-idle workers, classify them
  as `wrapped` / `no-wrap-up` / `wrapped-but-stub` /
  `idle-too-long`, and emit transitions to the orchestrator.
- **`pane-state.sh`** — distinguishes Claude Code's autosuggest
  ghost from real user input by ANSI escape inspection.
  Replaces eyeballing `tmux capture-pane` output. (PR #94
  upstream.)
- **GraphQL polling gate** — bucket-floor + cadence gate
  before every GraphQL call so a single bad cycle can't burn
  the quota. (PR #70 upstream.)
- **Deliveries surface** — webhook-deliveries log as a primary
  comment source alongside the GraphQL surface; mentions search
  as a tertiary fallback. JWT minting for the deliveries
  endpoint. (PRs #62, #68 upstream.)
- **`nexus.window-cleanup` skill** — orchestrator-exclusive
  policy for closing worker tmux windows: triggers, retention
  overrides, pre-close report check, kill mechanism, cadence.
  (PR #101 upstream.)
- **`nexus.infra-review` skill** — periodic meta-review of
  `## Infrastructure Issues` sections across `reports/` into a
  ranked, deduplicated backlog.
- **Crash-loop guard** for the agent respawn path; bounded
  respawn rate with history file in `monitor/.state/`.
- **CI guard against report leaks**
  (`.github/workflows/check-no-reports-leaked.yml`) — fails any
  PR adding files under `reports/` except `reports/.gitignore`.
  (PR #3.)
- **`@<operator>` as default CODEOWNER reviewer** + `ng pr create`
  auto-`--reviewer` based on `github.user_login`. (PR #37,
  PR #36 upstream.)
- **Cross-fork discovery** — topic tag + issue-association in
  report slugs lets bots discover work across forks. (PR #71
  upstream.)

### Changed

- **Asset-repo cutover** — `monitor/upload-asset.sh` now uploads
  to the dedicated asset+issue repo's `main` branch rather than
  to the (deprecated) wiki. Per-operator state cleanly separates
  from the shared code repo. (PR #1.)
- **Watcher inverted as entry point** — `monitor/watcher/entry.sh`
  is now the user-facing entry; it brings up the `claude`
  orchestrator window from inside the watcher loop rather than
  the other way round. Cleaner startup ordering, fewer
  race conditions on `--continue`. (PR #92/#93 upstream.)
- **Worker safety floor** moved into
  `skills/nexus.worker-defaults/SKILL.md` and injected verbatim
  into every spawn prompt by `monitor/spawn-worker.sh`. Floor
  body slimmed ~30% by folding per-step hand-off into the new
  `ng wrap-up` verb.
- **Spawn prompts** carry an explicit `## Worker environment`
  header with absolute paths so reports in secondary clones
  (worktrees, fresh clones) still land in the primary's
  `reports/` dir. (PR #96 upstream.)
- **Report schema** now requires YAML frontmatter (`project`,
  `date`, `session-id`, `window`, `trigger`, `status`) on top
  of the five canonical sections.
- **GitHub-writes authorization** documented as three tiers
  (internal / user-public / external-public) with explicit
  per-action approval rules; the bot identity rule (`WHO`)
  separated from the per-write approval rule (`WHETHER`).
- **CLAUDE.md** slimmed substantially; orchestrator-only prose
  moved into `monitor/README.md` and `skills/nexus.*`. The
  top-level contract now fits on one screen.
- **Lockfiles** moved into `monitor/.state/lockfiles/` from
  workspace root. Independent-clones pattern adopted as the
  primary parallel-work convention; lockfiles persist as
  fallback. (PR #57 upstream.)
- **Overview-issue routing-only rule** — the pinned `Nexus`
  issue now carries only routing one-liners; content threads
  live on dedicated issues.

### Fixed

- **`ng` `STATE_DIR` resolver** now picks up `NEXUS_ROOT` /
  `nexus.root` config so worker wrap-ups from worktrees land
  in the primary clone's `.state/`, not the worktree's. (PR #11.)
- **`ng wrap-up` tmux pane targeting** — the verb now records
  the source window explicitly instead of relying on the active
  pane, so wrap-ups from inactive windows are attributed
  correctly. (PRs #109, #12.)
- **`ng` session-id slug** — matches Claude Code's path
  normalisation so `ng report-init` recovers the right session
  log on re-runs from different cwds. (PR #107 upstream.)
- **`ng wrap-up --trigger-repo`** + write-verb precedence
  fixed so cross-repo triggers route their reaction to the right
  repo. (PR #108 upstream.)
- **Watcher idle-probe** passes window index to `pane-state.sh`
  rather than relying on the active pane. (PR #7.)
- **`_classify_diff` suppresses git-section diffs** so a worker
  branch-switch doesn't trigger a noisy emit. (PR #80 upstream.)
- **GraphQL detect-and-react cascade** — watcher classifies
  GraphQL rate-limit failures, mints a bot installation token
  rather than falling through to the user's exhausted PAT,
  and surfaces a sentinel emit so the orchestrator knows
  about the gap. (PRs #64, #63 upstream.)
- **Watcher emits on every eligible comment**, not just on
  snapshot diff — a missed paste no longer silently swallows
  a comment. (PR #63 upstream.)
- **Deliveries IDs extracted as strings** — `jq` 1.5 truncates
  the >2^53 integer IDs GitHub uses. (PR #68 upstream.)
- **`config/load.sh`** emits lowercase YAML booleans
  (`true`/`false`) rather than Python `str(True)`.
- **`_snapshot_pr_comments` MAX_NODE_LIMIT_EXCEEDED** — query
  node count brought below GitHub's GraphQL limit.
- **`mint-token`** anchors cwd via `BASH_SOURCE` so sub-project
  agents get a real installation token. (PR #30 upstream.)
- **`watcher: --continue` resume** — correct slug encoding;
  drop the positional prompt that conflicted with `claude`'s
  argv shape. (PR #97 upstream.)
- **Watcher fast-respawn** when the target window goes missing
  rather than emitting `rc=2` and stalling. (PRs #47, #51
  upstream.)
- **Watcher auto-unstick paths** for stuck permission prompts,
  rate-limit prompts, and transient API-error wedges (cases
  A/B/C in `_unstick.sh`). (PRs #42, #98 upstream.)

### Removed

- **Stray `reports/` file** accidentally committed in PR #40
  removed; CI guard above prevents recurrence. (PR #3.)
- **`context/` directory** — unused in practice.
- **`bipartite`/`bip` references** — superseded by `labsh`.
- **`🤖-prefix` convention** for bot comments — replaced by
  the rocket-reaction opt-out signal.

## Earlier history

The workspace was restructured into its current
agent-coordinated shape on 2026-04-14 (`54ab69b`). Before that
the repo was a personal research scratchpad with no monitor,
no watcher, and no bot. The first watcher prototype
(`monitor: tmux-hosted watcher with paste-to-target + diff
archive`, PR #12) landed on 2026-04-23; bot setup
(`docs: bot setup guide + permission rationale`, PR #15) the
same day. The `monitor/ng` CLI landed on 2026-04-17.

`git log --since 2026-04-14 -- monitor/ skills/ config/` is
the authoritative record of work prior to the asset-repo
cutover (2026-05-09).
