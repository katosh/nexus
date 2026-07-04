# Nexus monitor

Event-driven agent + watcher that turn a nexus repo's GitHub Issues
into a two-way control surface for workspace work. User side is
github.com in a logged-in browser (desktop or mobile). Agent side
runs on the cluster in a dedicated tmux window.

Every user-specific value (repo, GitHub App IDs, pem path, email
target, Pushover token paths, email relay) lives in
**`config/nexus.yml`** at the workspace root. A committed template,
`config/nexus.example.yml`, documents every field. All scripts in
this directory read the config via `config/load.sh`; no shell source
needs editing after a fork.

**First-time setup** (creating the GitHub App, granting permissions,
seeding the overview issue) is documented in
[`BOT_SETUP.md`](BOT_SETUP.md). This README assumes the bot is already
minting tokens.

## Starting the stack

One command, from the workspace root:

```sh
cd /path/to/nexus && agent-sandbox tmux new-session ./watcher
```

`./watcher` and `./nexus` are equivalent symlinks to
`monitor/watcher/entry.sh`. Add `--continue` to resume the pinned
orchestrator session instead of booting a fresh one. The command is
idempotent — re-running it against a healthy stack launches nothing
new and just lands you in the cockpit.

Everything else under `monitor/` that can start things is a
lower-level helper the entry point (or automated recovery) calls for
you. What each one is for:

| Helper | Role | Run it directly when… |
|---|---|---|
| `monitor/watcher/entry.sh` (= `./watcher`, `./nexus`) | User-facing entry point: self-checks, fresh-vs-`--continue` pin reconciliation, stack bring-up via `svc.sh up`, then turns the invoking window into the cockpit | This is the recommended command — use it by default |
| `monitor/svc.sh up` | Stack bring-up without the window rebind (delegates to `bootstrap-recover.sh`); `svc.sh` with no args is the read-only cockpit dashboard | You're already in a shell window and want the stack checked/raised without becoming the cockpit |
| `monitor/bootstrap-recover.sh` | The idempotent recovery engine: watcher → orchestrator → services → workers, each stage skippable by flag | Partial or scripted recovery (`--dry-run`, `--services-only`, `--no-workers`, …) — see "Architecture" 2b |
| `monitor/watcher/launcher.sh` | Lowest-level watcher (re)spawn: pidfile-guarded, single-flight-locked, group-reaping headless launch (`--replace` / `--ensure` / bare) | Restarting only the watcher: `monitor/svc.sh restart watcher` (idempotent — see "Watcher restart") |
| `monitor/watcher-supervise-tick.sh` | One tick of the orchestrator-armed watcher-supervisor Monitor: touches the supervisor heartbeat + reports watcher liveness (exit code) | Inside the orchestrator's `Monitor` until-loop — see "Watcher supervision" |
| `monitor/revive-watcher.sh` | Orchestrator's crash-revive: loop-guarded, writes the self-report marker, calls `svc.sh restart watcher`; honours an intentional-stop sentinel | When the supervisor Monitor fires (watcher down) — see "Watcher supervision" |
| `monitor/boot-recover.sh` | Cold-boot trigger: debounced, non-blocking check that backgrounds `bootstrap-recover.sh` when the stack is down | Normally wired into a SessionStart hook / login shell ("Cold-boot recovery trigger" below), rarely by hand |

When adding a new long-running helper program, don't add a new
startup command: register it in `monitor/services.registry` and
`bootstrap-recover.sh` (and therefore the one command above) will
own its launch and recovery.

## Architecture

Three pieces:

1. **`monitor/watcher/main.sh`** — long-running watcher loop. Runs
   HEADLESS as a service: `setsid`-detached, no tmux window,
   stdout/stderr appended to `monitor/.state/watcher.log`,
   liveness anchored by the self-published pidfile
   `monitor/.state/watcher.pid`. Every spawn path goes through
   `monitor/watcher/launcher.sh` (which marks the environment with
   `WATCHER_WINDOW=headless`, verifies the pidfile publish, and
   sweeps a leftover legacy `watcher` window). Two ways it gets
   started:

   - **User-invoked entry point**: `agent-sandbox tmux new-session
     ./watcher [--continue]` runs `monitor/watcher/entry.sh` (the
     `./watcher` symlink; `./nexus` is an equivalent alias) as the
     foreground command of a fresh inner-tmux session. `entry.sh`
     self-checks (tmux + agent-sandbox present), reconciles the
     fresh-vs-resume intent onto the orchestrator session-id pin
     (`monitor/.state/orchestrator-session-id`: default archives
     the pin → fresh boot; `--continue` keeps it → the watcher
     resumes that exact session via `claude --resume <sid>`, or
     spawns fresh when the pin is missing/stale — never
     `claude --continue`), brings the stack up via `monitor/svc.sh
     up`, then renames the invoking window to `services` and execs
     the read-only `svc.sh` cockpit. `svc.sh up` delegates to
     `bootstrap-recover.sh`, which brings the orchestrator up
     **directly and FIRST** — before respawning workers — and pins
     its window to the canonical slot (`monitor.target_window_index`,
     default 2; <your-org>/<your-nexus>#202). Re-running `./watcher`
     against a healthy stack is an idempotent no-op plus the cockpit.
   - **Recovery**: the canonical full-stack path is
     `monitor/bootstrap-recover.sh` (or `svc.sh up`, which delegates
     to it; auto-fired at a cold boot by `boot-recover.sh`). It
     relaunches the watcher via `monitor/watcher/launcher.sh`, then
     brings the orchestrator up **directly and FIRST** via
     `watcher/spawn-fresh-orchestrator.sh` (resolving the session-id
     pin) and pins its window, then recovers services and respawns
     workers (<your-org>/<your-nexus>#202). The watcher's own
     absent-target liveness machinery remains the BACKSTOP — it
     spawns the orchestrator within a few probe cycles (~10 s) if the
     direct bring-up ever fails or recovery wasn't run — but it is no
     longer the primary path. `launcher.sh` on its own (e.g.
     `bootstrap.sh`'s stale-heartbeat respawn, or `svc.sh restart
     watcher` = `launcher.sh --replace`) brings up only the watcher;
     the orchestrator then comes via that backstop.

   A watcher started any other way (e.g. `main.sh` run in a tmux
   window, the pre-cutover hosting) detects the legacy hosting at
   startup (`WATCHER_WINDOW != headless`) and surfaces a one-shot
   `--- watcher hosting migration ---` notice to the orchestrator
   (see `_hosting_migration.sh`), then keeps operating normally.

   Every `MONITOR_INTERVAL` seconds the loop snapshots:
   - **local state**: `reports/*.md` (filename + mtime),
     `tmux list-windows` with **bell flag** (fires when an agent's
     idle hook hits, i.e. "needs attention"), and per `work/*` repo
     (HEAD + clean/dirty), diffed against the previous snapshot.
     The `tmux` section drops any row whose window name starts
     with `•` (bullet glyph) — phantom dead-pane artifacts that
     tmux's auto-rename used to produce before
     `monitor/spawn-worker.sh` started pinning worker windows
     with `automatic-rename off` + `allow-rename off`. The
     filter is defense-in-depth so a stray transient from a
     pre-fix worker or an externally-created window can't
     pollute the diff.
   - **eligible GitHub comments** in the current snapshot. Same
     filter as before (author == `github.user_login`, no non-user
     EYES, no ROCKET). Emitted as a full list every cycle with a
     one-line body preview.
   - **standing bells** on non-orchestrator windows.
   - **idle-worker transitions** in a `--- idle workers ---`
     section: one line per worker window whose
     engagement-anchored idle age crossed
     `monitor.idle_threshold_seconds` (default 60). Age is
     `now - engagement_epoch` when the worker has a row in
     `monitor/.state/engagement-log.tsv`, otherwise
     `now - tmux #{window_activity}` (fallback for fresh
     workers the watcher has never observed busy). See
     "Suppression rule" below for why the engagement-log is
     the load-bearing floor and `tmux #{window_activity}` is
     too noisy to gate on directly. The pane is then routed by
     `pane-state.sh`: `idle|autosuggest-only` flow into wrap-up
     classification; `absent|blocked` short-circuit to
     `pane-absent` (`empty` means a live claude mid-render —
     skip, retry next cycle); `busy|user-typing` are real
     engagement and never surface. The full lifecycle — every state, every
     transition condition with its exact threshold, and the
     orchestrator reaction per state — is diagrammed in
     [`monitor/docs/agent-state-machine.md`](docs/agent-state-machine.md).
     Classifier vocabulary (full state space;
     see `skills/nexus.window-cleanup`):

     | Class | Line shape | Orchestrator action |
     |---|---|---|
     | `wrapped` | `<window> wrapped up (idle <age>; wrap-up logged)` | Consider close per trigger / retention rules. |
     | `wrapped-but-stub` | `<window> wrapped-but-stub (<missing-fields>)` | Paste finish-and-expand template; re-check next wake. |
     | `no-wrap-up` | `<window> idle <age> WITHOUT wrap-up — consider follow-up paste` | Paste wrap-up-missing template; re-check next wake. |
     | `idle-too-long` | `<window> idle-too-long <age> (exceeds close threshold; consider close)` | Strong default-to-close at ≥ `monitor.idle_close_hours` (default 24h); retention overrides still apply. |
     | `pane-absent` | `<window> pane-absent (claude process gone or unresponsive; relaunch or close)` | Inner Claude Code process is gone (pane fell back to shell), the renderer is in an ambiguous state, or the pane is sitting on a stalled overlay. Relaunch via `monitor/spawn-worker.sh` or close. Inviolable — never suppressed by `window-retain`. |
     | `over-limit` | `<window> OVER-LIMIT (resets <reset_at>; weekly Opus limit hit — schedule resume)` | Worker's claude session hit the weekly Opus limit and is functionally suspended. Do NOT close. The **watcher** owns the wake-loop (issue #87): stamps a row in `monitor/.state/over-limit-state.tsv`, retries on exponential backoff (60s → 300s cap, default 10 attempts), pastes a resume brief into the pane the moment `pane-state.sh` reports the suspension cleared. While the orchestrator's own pane is in this state, the watcher also suppresses routine emit-pastes to it (they'd queue uselessly in an inert input box) — archives still write. `reset_at` is a single token (spaces→`_`, parens stripped). Inviolable — never suppressed by `window-retain`. |
     | `operator-engaged` | `<window> operator-engaged (src=<submit\|submit-after-wrap>; idle <age> — operator driving; idle/retire handling suppressed while engaged)` | None — the operator drives this window (issues #196, #201), wrapped or never-wrapped. Do NOT close, do NOT paste follow-ups. One informational row per engagement episode; while the mark is valid the window's `idle_prompt` decisions are also withheld. Seed: the worker's `UserPromptSubmit` hook stamped a prompt submit (`.state/user-prompt/<window>`, written by `worker-heartbeat.sh` — a deterministic Claude Code contract event, immune to the TUI character-rewriting that distorts pane reads) with NO machine-input stamp (`paste-followup` action-log event, `machine-input.tsv` row, or spawn event) covering it, AND corroborated by observed pane-content change within `monitor.operator_engaged_change_ttl_seconds` (default 600 — the <your-org>/<your-nexus>#205 follow-up: a fragile one-frame bright-text read no longer gates the mark; sustained transcript change does). Orchestrator follow-ups MUST still go through `monitor/paste-followup.sh` (an unstamped paste fires the hook with no machine stamp and, if the agent then changes the pane, briefly engages the window and mutes its stall-nag). The mark is **self-expiring**: the moment the pane goes static past that TTL it lapses and the window returns to normal retire-eligibility — a window is never pinned open indefinitely on a stale or false mark. An `engaged-done` finished-signal (`ng engaged-done`), a newer spawn, or window close also ends it; a wrap-up does NOT — interactive sessions stay engaged across their own hand-off (the <your-org>/<your-nexus>#205 state-machine follow-up), and `ng wrap-up` prompts the agent to signal `engaged-done` when finished. Full lifecycle diagram: `monitor/docs/agent-state-machine.md`. |
     | `paste-unconfirmed` | `<window> paste-unconfirmed (paste <age>s ago; no UserPromptSubmit fired — the nudge silently failed; re-paste via monitor/paste-followup.sh)` | Injection↔hook pairing validation (the <your-org>/<your-nexus>#205 state-machine follow-up): a `paste-followup` older than `monitor.paste_confirm_grace_seconds` (default 180) fired no `UserPromptSubmit` on a hook-live window — the paste never submitted. Re-paste via `monitor/paste-followup.sh`. Not retain-suppressible. |
     | `engaged-close-reminder` | `<window> operator-engaged but operator away <age> (src=<seed>) — consider closing this window; reminder re-fires once per period until the operator returns or it closes` | The away phase's only surface (issue #201): emitted at most once per `monitor.operator_engaged_close_reminder_seconds` (default 86400 = 24 h) once the operator has been away that long. Relay to the operator / nudge on the overview routing thread; do NOT auto-close — the window still belongs to the operator. |
     | `interrupted` | `<window> interrupted <age> — turn crashed (<category>); …` (the tail names the verb: `process alive, PASTE a resume nudge` for `transient`; `a resume would re-fail, RESPAWN via claude --continue or fresh spawn` for `config`/`conversation`; `needs operator` for `auth`) | The worker's last turn died to an API/model error: Claude Code fired the **`StopFailure`** hook (NOT `Stop`), so no state-clear ran and the idle/empty pane was previously mis-nagged as `no-wrap-up`. `monitor/hooks/turn-failure-emit.sh` (StopFailure) wrote `monitor/.state/turn-failure/<window>.json` with a `(category, recovery)` classification (`monitor/hooks/_cause_classify.sh`); a fresh marker (freshness-gated by `MONITOR_TURN_FAILURE_STALENESS_SECONDS`, default 1800) on an alive idle pane reclassifies to `interrupted`. The recovery verb is load-bearing — **PASTE** for `transient` (server 5xx blip; same turn succeeds on resume), **RESPAWN** for `config`/`conversation` (a paste re-runs the doomed turn), **operator** for `auth`. The Stop hook clears the marker on the next successful turn. End-to-end coverage: `monitor/watcher/test-integration/test-realmodel-apispoof.sh`. Full lifecycle: `monitor/docs/agent-state-machine.md`. |
     | Suppressed (retained) | `(N retained windows suppressed: <w1> (<reason1>), <w2> (<reason2>), …)` footer | None — the orchestrator already decided to keep these open via `ng log-action ... --event window-retain ...`. The footer is auditability only. |

     `wrapped-but-stub` is decided by running `ng report-check`
     on the cited report — fails if the schema or completeness
     check from `nexus.report` doesn't pass. Deduped against
     the prior cycle's `(window, class)` set so stable workers
     don't re-emit.

     Suppression rule: a worker whose base class is `wrapped`
     or `no-wrap-up` is converted to `retained` (footer-only)
     when a `window-retain` event for that window exists in
     `monitor/.state/action-log.jsonl` and:

     - the event is younger than `monitor.retain_ttl_seconds`
       (default 86400 = 24h; env: `MONITOR_RETAIN_TTL_SECONDS`), AND
     - the window has had no **engagement** since the event —
       engagement defined as a `pane-state.sh` observation of
       `busy` or `user-typing`, recorded in
       `monitor/.state/engagement-log.tsv`. The probe stamps
       the engagement-log on every cycle that observes either
       state for a worker; the retain-consume gate compares
       the stored epoch against `retain.ts`. A worker with no
       engagement-log row is treated as "no engagement since
       beginning of time" → retain holds. **Critically NOT
       consumed by `tmux #{window_activity}` bumps alone** —
       autosuggest re-renders, cursor blinks, spinner glyph
       swaps, and status-bar token-counter ticks all advance
       `window_activity` without representing real
       engagement. The empirical motivation is documented
       inline at the top of `monitor/watcher/_idle_probe.sh`
       (issue #111: `echo-density` retain consumed inside 30
       min despite no human or agent interaction).

     `wrapped-but-stub`, `idle-too-long`, `pane-absent`, and
     `over-limit` are inviolable: they NEVER convert to
     `retained`. Broken reports, runaway windows, crashed
     panes, and weekly-limit suspensions must surface
     regardless of intent. The footer is emitted on changes
     to the suppressed set (window added or removed) so a
     stable retained set stays quiet.

   On every observed change it:
   - Archives the report to `monitor/.state/diffs/<ts>_<shortid>.md`.
   - Pastes the report into the target tmux window (the monitor
     agent; default `orchestrator`, overridable per launcher invocation)
     via the `tmux set-buffer` + `tmux paste-buffer` + `Enter`
     pattern documented in `skills/nexus.tmux-spawn/SKILL.md`.
     Retries once on transient failure, then gives up and relies
     on the archive.
   - Touches `monitor/.state/watcher-heartbeat` (PID + ISO
     timestamp) so agents can detect staleness.
   - On observing the target window absent in tmux, launches a
     fresh orchestrator session (the `claude` CLI) in the target
     window after `monitor.agent_missing_respawn_delay` confirming polls
     (default `3` — four consecutive absent observations at the 2 s
     probe cadence, ~8 s of confirmed absence). Just before the
     launch the watcher re-verifies the absence
     (`_respawn_verify_target_absent`): a fresh window probe, a
     pane scan for a live orchestrator process (healing tmux rename
     races by renaming the window back), and a liveness-signal
     check each independently abort a false-positive respawn. The
     new agent is told to validate the call (read CLAUDE.md, check
     if another live monitor exists) and — if the call was wrong —
     stand down by removing ONLY its own duplicate window; it must
     never kill the watcher or the tmux session.
     `monitor.agent_dead_threshold` (default 3) is reserved
     for the slow-path case — window present, agent silent — for
     which a detector is not yet wired in.
   - Crash-loop guard: if more than `monitor.respawn_loop_limit`
     respawns happen within `monitor.respawn_loop_window_seconds`
     (defaults: 3 within 120 s), the watcher stops respawning the
     orchestrator and `sandbox-notify`s the operator once. The history
     clears on the next successful paste-to-target, OR by time as
     the sliding window empties.

   Startup sweep emits any eligible comments / standing bells
   immediately on launch.

   **Single-instance contract — one cockpit per `NEXUS_ROOT`.** Two
   guards keep a second watcher off a shared `monitor/.state/`:
   - A PID-based lock at `monitor/.state/watcher.lock` (+ the
     `watcher.pid` file) — same-pid-namespace, same-host. It records
     a bare pid validated against `/proc`, so it catches a duplicate
     started in the **same** sandbox.
   - An **flock-based instance lock** at
     `monitor/.state/nexus-instance.lock`, held by the watcher for its
     whole lifetime (issue: multi-instance-guard). This is the guard
     that survives the **cross-sandbox** case: each agent-sandbox
     cockpit runs under `bwrap --unshare-pid`, so a peer sandbox's
     watcher pid is invisible in this namespace's `/proc` and every
     pid-based check reads a live peer as *dead*. flock keys on the
     inode, not the pid — it crosses the pid-namespace boundary, and
     on the NFSv3 state mount (`local_lock=none`) the host boundary
     too (forwarded to the server's NLM). A second watcher that finds
     a live holder **refuses loudly and exits non-zero** (launcher
     fast-fails before spawn; `main.sh` is the authoritative gate). The
     refusal is built from the holder's recorded metadata (`host`,
     `boot_id`, `pid`, `sandbox`, `tmux`, `started_at`, …) and spells
     out both the normal resolution (use / close / `--replace` the
     other instance) and the false-positive resolution (clear a stale
     lock). A same-host flock auto-releases on holder death — even on
     SIGKILL — so the only stale class is a cross-host NFS lock whose
     client died, or a same-host lock whose machine rebooted (detected
     by `boot_id` mismatch); inspect a holder before deciding with
     `monitor/watcher/launcher.sh --instance-status` or `ng
     watcher-status`. The blessed succession paths (`launcher.sh
     --replace`, the version-restart self-restart, `bootstrap-recover`)
     all terminate the prior watcher *before* the successor starts, so
     the guard blocks **coexistence**, never **succession**. To run a
     second instance, point it at a **different `NEXUS_ROOT`**; true
     two-cockpits-one-root is unsupported and guarded. Stale-lock case
     analysis + resolve guidance: `docs/operating/watcher.md`
     ("Single-instance contract").

   Mid-dirty hash bumps and
   `*-interim*.md` report additions are classified as noise and
   suppressed (baseline advances + one log line); everything
   else (transitions, final reports, tmux window add/remove,
   bells, eligible GitHub comments) pastes as before.

2. **`monitor/watcher/bootstrap.sh`** — agent-side on-wake check.
   The monitor agent runs it every turn. It (a) checks the
   watcher heartbeat and respawns via `launcher.sh` if stale
   (> 2× poll interval), (b) prints archived diffs newer than
   `monitor/.state/last-ack.txt` so nothing is lost across agent
   restarts, (c) advances `last-ack.txt` to `date -Is`. When it
   respawns a dead watcher it also runs `bootstrap-recover.sh
   --services-only` — a dead watcher is the strongest signal the
   whole stack went down, so the registered infra services come
   back in the same step.

2b. **`monitor/bootstrap-recover.sh`** — idempotent full-stack
   recovery for after a machine / tmux restart (the 2026-06-07
   incident: only the orchestrator came back; the watcher and every
   infra service stayed dead). Relaunches the watcher if not healthy
   AND each registered infra service that is unhealthy with no live
   supervisor. Services run HEADLESS — launched detached via `setsid`
   (no tmux window), their supervised-restart wrapper being the
   crash-survival mechanism — and "live supervisor" is keyed off a
   per-service pidfile (`$NEXUS_STATE_DIR/services/<name>.pid`, verified
   alive AND cmdline-matched so a recycled PID isn't mistaken for it). A
   legacy tmux window of the service's name is still honoured as a
   second leave-it-alone signal, so a not-yet-migrated windowed service
   is never double-launched. Healthy / live-supervisor / windowed
   services are never double-launched. Driven by a declarative registry
   (`monitor/services.registry`, operator-local; template at
   `monitor/services.registry.example`) so adding a service is a
   one-line edit, not a code change.

   **Order matters (<your-org>/<your-nexus>#202).** After the watcher and
   BEFORE services + workers, recovery brings the **orchestrator** up
   directly — it is the supervisor that owns worker continuations, so
   it must exist before workers are respawned. Iff the target window
   (`monitor.target_window`, default `orchestrator`) is absent, recovery
   spawns it via `watcher/spawn-fresh-orchestrator.sh` (which resolves
   the session-id pin: valid pin → deterministic `--resume <sid>`;
   missing/stale pin → loud cold spawn, never a deadlock) and then
   **pins its window** to the canonical index
   (`monitor.target_window_index`, default 2). The pin is non-
   destructive: already-correct → no-op; slot free → `tmux
   move-window`; slot held by a different window → leave the
   orchestrator put and log loudly. An already-alive orchestrator
   window is never killed/respawned (only re-pinned). Pre-#202,
   recovery left the orchestrator to the watcher's absent-target
   machinery (~4 poll cycles AFTER the watcher), so a worker respawned
   in the same run grabbed the orchestrator's canonical slot and the
   supervisor came up late at a higher index — exactly the 2026-06-11
   incident. The watcher's machinery is now the backstop, not the
   primary path.

   Then it **respawns the worker agents** from the last watcher
   snapshot (`.state/last-snapshot.txt`), via the canonical resume
   surface `spawn-worker.sh --resume <window>` — a snapshot window
   qualifies iff it is not infra (`orchestrator`, `services`,
   `watcher`, registry-named legacy service windows are excluded), it
   has a `spawn` event in `.state/action-log.jsonl` (recovery only owns
   nexus-spawned workers), AND **either** that `spawn` is its latest
   lifecycle event (active — abruptly interrupted) **or** the window is
   **operator-engaged** (<your-org>/<your-nexus>#202). A later `wrap-up` /
   `window-close` normally retires a window (the orchestrator owns
   continuations of wrapped work), BUT a window the operator is driving
   must survive a restart even if it wrapped: recovery consults the
   watcher's own authoritative engagement mark (`_openg_marked` over
   `.state/operator-engaged.tsv`, issues #196/#201/#263/#264 — a valid
   hook-driven mark not superseded by a newer wrap-up/spawn AND still
   corroborated by pane-content change within
   `monitor.operator_engaged_change_ttl_seconds`, the <your-org>/<your-nexus>#205
   follow-up self-expiry), so a wrapped-then-re-driven window whose pane
   is still changing is respawned while a wrapped-and-abandoned one (its
   mark long since lapsed) is skipped (no resurrection of done work). The
   engaged set is captured at the very start of recovery, before the
   watcher relaunch prunes the marks for not-yet-respawned windows.
   Idle-but-unwrapped workers ARE respawned. Already-alive windows are
   never double-spawned; respawns are capped at `recover.max_workers`
   (default 12); an unresolvable session is skipped with a loud log
   line, never fatal.

   Flag matrix (watcher / orchestrator / services / workers): default =
   all four; `--no-services` (= `--watcher-only`) is core-only =
   watcher + orchestrator (skips services AND workers); `--no-workers`
   skips only the worker respawn; `--no-orchestrator` skips only the
   direct orchestrator bring-up (leaving it to the watcher backstop);
   `--services-only` skips the watcher AND the orchestrator (the
   per-turn `bootstrap.sh` refresh — the orchestrator is the caller
   there), services + workers still recover. The orchestrator runs it
   on wake after a suspected restart; `bootstrap.sh` also invokes it
   (`--services-only`) automatically on the watcher-respawn path.
   `--dry-run` / `--list` inspect without launching.

2c. **`monitor/boot-recover.sh`** — the *cold-boot trigger* for
   `bootstrap-recover.sh`. Recovery existed but nothing ran it at a
   true reboot: its only triggers (the orchestrator running it by
   hand, or `bootstrap.sh`'s watcher-respawn path) both presuppose the
   orchestrator is already alive and taking turns. This guard is the
   missing automatic fire. It is idempotent, debounced (a stamp under
   `.state` collapses a burst of boot-time login shells into one
   attempt), and non-blocking (it asks `bootstrap-recover.sh
   --dry-run` whether anything needs launching and, only if so,
   backgrounds the real recovery — so it never blocks the login /
   session start that invoked it). `--force` skips the debounce;
   `--sync` runs recovery in the foreground for debugging.

   **Wiring it (see "Cold-boot recovery trigger" below).** The
   strongest trigger deliverable from inside the agent-sandbox is a
   Claude Code **SessionStart** hook (matcher `resume`) on the
   orchestrator — it fires the instant the chaperon brings the
   orchestrator back via `claude --resume`, the one component that
   reliably returns at boot. A ready-to-merge snippet ships at
   `monitor/boot-recover.session-start-hook.json`. A trigger that
   fires with *zero* dependence on the orchestrator resuming must live
   outside the sandbox (the real `~/.zprofile`, or a `sandbox.conf`
   on-start entry) — documented below, since the sandbox mounts
   `$HOME` as an ephemeral tmpfs and bind-mounts the login dotfiles
   read-only, so it cannot be persisted from within.

2d. **Continuous service-health watch** (`monitor/watcher/_service_health.sh`,
   service-health-watch) — the steady-state complement to 2b.
   `bootstrap-recover.sh` only runs at boot / on the watcher-respawn
   path; nothing watched service health *between* those events, so a
   service that **wedged** (process alive but healthcheck failing — an
   HTTP hang), or whose supervisor wrapper itself died, was never
   detected, restarted, or surfaced. The `service_health` scheduler task
   (registered `--async`, cadence `monitor.service_health.interval_seconds`,
   default 120 s) closes that gap. Each tick runs **every registry
   service's column-4 healthcheck** — detection keys on the registry
   healthcheck, never on tmux/worker heuristics, and registry-listed
   service windows stay exempt from worker-dead detection
   (`_idle_probe.sh`, the `$1 in svc` predicate, <your-org>/<your-nexus>#204).

   On an unhealthy service the watcher does **not** restart on the first
   failed check — that would fight the service's own `*-supervised.sh`
   wrapper, which already self-heals a crashed *process* (double-restart,
   churn, masked faults). Instead it gives the service a **self-heal grace
   window** (`grace_seconds`, default 30): a process-crash the wrapper
   relaunches recovers within grace and the watcher **never touches it**
   (breadcrumb only — "don't restart unnecessarily"). Surviving the grace
   window is the signal that the failure is one the wrapper *can't* fix — a
   **wedged** process (alive but healthcheck failing — an HTTP hang) or a
   **dead wrapper** — and only then does the watcher act. The grace window
   needs no coupling to the supervisor pidfile: surviving it *is* the
   discriminator.

   What it does after grace is governed by a **per-service restart policy**
   — the optional 6th column in `services.registry`, or
   `monitor.service_health.default_policy` (default `auto-restart`) for rows
   that omit it. "Honor service configuration" is first-class:
   - **`auto-restart`** — a flap-controlled, **minimal-downtime restart**
     via `monitor/svc.sh restart <svc>`, which reuses `recover_service()`
     for the relaunch AND first stops a live-but-wedged supervisor's
     process group (`_stop_service`), the step bare `recover_service`
     cannot do (it would defer to the live supervisor). Flap control: a
     per-service restart cooldown (`restart_cooldown_seconds`, default 300)
     and a per-incident attempt ceiling (`flap_ceiling`, default 3); past
     the ceiling the watcher stops thrashing and escalates "won't-recover"
     (`flapping`) rather than loop.
   - **`emit-only`** — the watcher **never auto-restarts**; after grace it
     escalates to the orchestrator and lets it decide. For services where a
     blind restart is unsafe or wants human judgment.

   It **never degrades or falsifies** the service to make a check pass — the
   only ever action is an honest restart. Per-service incident state —
   first-unhealthy → restored timestamps, the policy in effect, whether it
   self-healed within grace, every restart attempt + outcome — is recorded
   under `monitor/.state/service-health/<name>.{state,events}`, the raw
   material the issue generator reads.

   The condition is surfaced to the orchestrator through a
   `--- service health ---` `compose_emit` section that **always reports the
   full state** regardless of which path fired: detected, grace-in-progress
   (informational, no action), restart attempted + its outcome
   (recovering), escalation (`emit-only` / `flapping`), the policy in
   effect, and a one-shot `recovered` breadcrumb. It is re-nag guarded per
   `status:attempts` so a persistently-down service does not spam every
   loop, and cleared once the service is healthy again. Grace and a clean
   self-heal stay quiet (a breadcrumb, not a nag); `emit-only` and
   `flapping` are the loud escalations that need judgment — so the
   orchestrator keeps full intervention capacity without being nagged for
   what the watcher is already handling. On an escalation it follows
   **`skills/nexus.service-recovery`**: restore first (minimal downtime),
   dispatch a root-cause worker (reversible, non-degrading fix), and open an
   operator incident issue assembled from the recorded state by
   **`monitor/ng service-incident <svc>`** (so the issue prose — what
   changed, when, the impact, the policy, how to undo — cannot drift from
   the machine facts). Knobs: `monitor.service_health.{enabled,
   interval_seconds,grace_seconds,default_policy,restart_cooldown_seconds,
   flap_ceiling}`.

3. **The monitor agent** — a Claude Code session in a dedicated
   tmux window (suggested name: `monitor`). Wakes when the watcher
   pastes a report into its pane, runs `bootstrap.sh` as its first
   step, processes the diff (refresh overview issue body, react to
   user comments, route directives to other tmux windows), and
   records meaningful actions in
   `monitor/.state/action-log.jsonl` via `monitor/ng log-action`.
   No `ScheduleWakeup`, no relaunch dance. Its command surface —
   `spawn-worker.sh`, `paste-followup.sh`, `pane-state.sh`, window
   cleanup, `ng` — is collected in
   [`monitor/docs/orchestrator-guide.md`](docs/orchestrator-guide.md);
   the worker lifecycle it reacts to is diagrammed in
   [`monitor/docs/agent-state-machine.md`](docs/agent-state-machine.md).

## Mutual-liveness contract

The watcher and the monitor agent each check the other is alive;
the configured user on GitHub (`github.user_login` in
`config/nexus.yml`) is the external tie-breaker if they disagree.

- **Agent → watcher.** Every turn the agent runs
  `monitor/watcher/bootstrap.sh`. If
  `monitor/.state/watcher-heartbeat` is stale (> 2× poll interval)
  or missing, the script writes a
  `reports/nexus_*_watcher-incident.md` evidence package and
  respawns via the launcher. The agent reads the report and
  decides: benign respawn (log via `monitor/ng log-action`) or
  spawn a `watcher-fix` worker with the report as the brief. After
  a suspected-bug redeploy, the agent schedules a short-lived
  `CronCreate` (~10–15 min) that cancels itself after 3
  consecutive healthy heartbeats. For multi-fire crons whose state
  must survive an orchestrator respawn (fire count, target window,
  recovery semantics), use the TSV + recovery-marker pattern in
  `skills/nexus.cron-state-tsv/SKILL.md` — the harness's
  `durable: true` flag is silently ignored, so on-disk state is the
  workaround.
- **Watcher → agent (window absent).** If the orchestrator's tmux
  window disappears entirely (claude crashed, window closed), the
  watcher's poll-level `_target_window_present` check fires
  `respawn_agent` after `monitor.agent_missing_respawn_delay`
  confirming polls (default 3 — ~8 s of confirmed absence at the
  2 s probe cadence) plus a pre-launch re-verification that aborts
  when the window reappears or a live orchestrator process is
  found. This is the fast path; window-missing must be CONFIRMED
  absence, not a single transient misread (incident 2026-06-02).
- **Watcher → agent (window present but inert — issue #164).** A
  wedged orchestrator leaves the tmux window alive but the TUI
  frozen: pastes deliver into a stuck input box, no Stop hook
  fires, the session log doesn't advance. The watcher detects
  this with a hook-driven state machine in
  `monitor/watcher/_orchestrator_liveness.sh`. Three orchestrator-
  side signals feed it:

  - **Heartbeat.** The orchestrator's `Stop` hook (in
    `monitor/orchestrator-settings.json`) touches
    `monitor/.state/orchestrator-heartbeat` at every turn-end.
  - **Paste-received.** The orchestrator's `UserPromptSubmit`
    hook touches `monitor/.state/orchestrator-paste-received`
    the moment its input queue picks up a watcher paste. Covers
    the multi-step tool turn case where Stop hasn't fired yet
    (heartbeat stale) but the orchestrator is demonstrably
    processing the prompt. Strictly weaker than the heartbeat,
    so a fresh heartbeat past a paste always supersedes a
    fresh paste-receipt.
  - **Pinned-session jsonl mtime** — backward-compat fallback
    for sessions whose settings file predates the hooks.
    Fragile (depends on Claude Code's log format); drops out
    after the deprecation window.

  Both hook commands run asynchronously via
  `(... &) >/dev/null 2>&1` — the detached subshell forks the
  touch and returns instantly, so the hook can never stall the
  orchestrator on a slow filesystem or contention.

  - `monitor/.state/orchestrator-last-paste.ts` is the trigger:
    stamped by main.sh on every successful paste to the
    orchestrator.
  - **Healthy** iff any of the three signals (heartbeat,
    paste-received, jsonl) advanced past the last-paste epoch,
    or there has been no paste at all (idle is alive), or the
    last paste is older than
    `monitor.watcher.stale_paste_ceiling_seconds` (default 1800)
    — too stale to be evidence of wedging. A fresh paste resets
    the clock, so the ceiling never masks a real wedge.
  - **Pasted-without-response** when neither evidence is past
    the paste and `monitor.watcher.paste_response_grace_seconds`
    (default 120) has elapsed. The state machine stamps an
    `unresponsive-since` marker and lets the standard
    `detect_and_unstick` loop probe cases A–D (permission
    Enter, rate-limit cascade, api-error Enter, AskUQ chip-bar
    Escape) for up to
    `monitor.watcher.unstick_window_seconds` (default 150).
  - **Re-submit rescue** when the unstick window exhausts —
    before any respawn, the watcher re-pastes the most recent
    emit body to the orchestrator pane exactly once per wedge
    episode (tracked via an `orchestrator-resubmit-attempted`
    marker). A dropped or un-submitted Enter on an otherwise
    alive pane is rescued by a re-paste, not a respawn
    (substantiated by the 2026-05-29..31 incidents where four
    healthy-but-slow orchestrator turns were killed). The
    re-paste deliberately does not advance the last-paste
    clock, so it can never defer the dead threshold. The
    re-submit gets one grace window to produce a response
    signal.
  - **Respawn** when the rescue also fails —
    `now - resubmit_marker > paste_response_grace_seconds`
    with still no response signal — OR unconditionally at
    `now - last_paste >= monitor.watcher.orchestrator_dead_threshold_seconds`
    (default 300), and only while `now - last_paste <
    stale_paste_ceiling_seconds` (the ceiling caps the
    dead-threshold check; outside that range pure idle wins).
    With Stop-hook heartbeats firing reliably, false positives
    drop to near-zero so the dead-threshold can be much higher
    than the legacy #157 default of 120 s. A cooldown
    (`monitor.orchestrator_fresh_spawn_cooldown_seconds`,
    default 1800) gates retry rate.
  - **Log throttling.** The liveness task polls every ~5 s; the
    `waiting` countdown logs on state entry, then at most every
    `monitor.watcher.liveness_log_throttle_seconds` (default
    30), plus on every transition (re-submit, respawn,
    recovery summary). A slow turn leaves a few breadcrumbs in
    `watcher.log`, not ~40 identical lines.

  The new agent validates the call (reads `CLAUDE.md`, checks
  for an existing monitor elsewhere) and kills the watcher if
  the respawn was wrong.

  Replaces the #157 binary `unresponsive_age > threshold` check,
  which conflated "stuck" with "idle but healthy" and produced
  false-positive restarts on quiet workspaces (2026-05-21
  15:12:42 — three issues filed in quick succession then a
  user-side wait → trip at `unresponsive_age=143s threshold=120s`,
  context preserved by `--continue` but a tmux cycle wasted).

  The legacy `monitor.orchestrator_unresponsive_threshold_seconds`
  config key (and its `MONITOR_ORCH_UNRESPONSIVE_THRESHOLD_S` env
  var) are honoured for one release as a fallback default for
  `orchestrator_dead_threshold_seconds`; rename to the new name.
- **Verification.** `monitor/ng watcher-status` is one-shot
  (heartbeat age, pid, target, lock, tmux presence, diff count).
  Exit code: 0=fresh, 1=stale (<5× interval), 2=very-stale
  (≥5× interval), 3=no heartbeat. Scripts branch on the bucket;
  humans read the stdout block.

## How decisions flow (issue #129)

Every worker spawned via `monitor/spawn-worker.sh` runs with
`--settings monitor/worker-settings.json`. That settings file
declares a `Notification` hook that invokes
`monitor/hooks/decision-emit.sh` for every Claude Code
notification (permission prompts, idle prompts, MCP elicitations,
auth events). The handler reads the hook payload from stdin and
writes one atomic JSON event per pending decision to
`monitor/.state/decisions/<window>.<fp>.json` (fingerprint is
stable across re-fires of the same prompt, so one file per
distinct pending decision, not one per re-render). The PreToolUse
hook for sensitive tools (`Bash|Write|Edit|NotebookEdit`)
captures the tool name + argument summary into
`monitor/.state/pending-tool/<window>.json`, which the
Notification handler embeds into the decision file's
`tool_context` field so downstream readers see the operation the
prompt is asking about without inspecting the pane.

Each watcher cycle calls `render_pending_decisions` (in
`watcher/_idle_probe.sh`), which scans the decisions directory
and emits a `--- pending decisions ---` section listing each
pending file with `window=`, `fp=`, `kind=`, `unresolved=`,
`prompt-excerpt=`, and `file=` — orchestrator reads the cited
JSON for the full payload. The cooldown
(`DECISION_REEMIT_COOLDOWN_SECONDS`, default 300) prevents a
stale prompt from re-emitting every cycle.

Ack channel — two shapes with different semantics:

- `rm <window>.<fp>.json` — **ack-and-allow**. The same
  fingerprint may re-fire later (e.g. a retained-idle worker
  hitting another `idle_prompt`); each fire produces a fresh
  `<fp>.json` for the orchestrator to re-handle. Use when the
  next instance might warrant different handling.
- `mv <window>.<fp>.json <window>.<fp>.handled.json` —
  **ack-and-suppress**. The tombstone is honoured by
  `decision-emit.sh` on the write path: future fires of the same
  fingerprint are silently no-op'd, so the watcher never re-emits.
  Permanent for the lifetime of `monitor/.state/decisions/`; to
  un-suppress, `rm <window>.<fp>.handled.json`. Use for one-shot
  prompts the orchestrator has answered for the rest of this
  worker's life (e.g. retained-idle workers whose `idle_prompt`
  carries no real question).

The `Stop` hook stamps `unresolved=true` on any decision file
still present at turn-end so the watcher can flag it more
loudly. Tombstones are skipped by both the Stop hook and the
watcher's reader — they are terminal.

**Watcher-synthesized records — the blocked-question relay (Case
W).** The Notification-hook path above only covers panes spawned
via `spawn-worker.sh`; operator-launched interactive windows have
no hooks, so a worker blocked on an `AskUserQuestion` overlay in
one of those panes never reaches the decisions channel. The
watcher closes that gap at the pane-render level: when the
auto-unstick scan sees a live AskUQ overlay (the Case D chip-bar
signature + bottom-anchored footer) on a **non-target** window
continuously for `monitor.watcher.worker_askuq_grace_seconds`
(default 300 s; the grace gives a human at the pane first right
of reply — an overlay answered during the grace simply vanishes
and nothing fires), it synthesizes a decision record itself —
same path, same schema, `kind: "blocked_question"`, with the
parsed question + option list in `prompt_excerpt` and the
captured pane tail in `tool_context`. The watcher never sends
keys to the pane. The orchestrator answers on the operator's
behalf (see `agent-prompt.md`, "Answering a relayed blocked
question") and acks through the normal channel above. Case W
narrative + lifecycle: `watcher/_unstick.sh`.

How the orchestrator should ACT on other pending-decision kinds
(paste keys, escalate to user, etc.) is a separate layer not yet
wired into `agent-prompt.md`.

## Skeptic protocol

An independent **skeptic** agent adversarially validates a worker's
result to high scientific standards before it propagates — a merge, a
figure, a gene list, an external write. The skeptic catches the class
of error a self-reviewing worker misses: labels confused for
membership, figures that don't reproduce, claims asserted but never
verified. The methodology is adapted from `<yourlab>.ms-audit` and
`matsen/bipartite`. The canonical reference, with the full skeptic
workflow and verdict rubric, is
[`skills/nexus.skeptic/SKILL.md`](../skills/nexus.skeptic/SKILL.md);
this section documents the monitor surfaces.

### Spawn modes

`monitor/spawn-worker.sh` takes `--skeptic <require|auto|deny>`
(default `auto`), `--skeptic-depth N` (default 0), and the
skeptic-side pair `--skeptic-role --skeptic-target <window>` (spawn a
skeptic to review the named worker). The mode is recorded in the
worker's provenance record (`monitor/.state/windows/<window>.json`:
`skeptic_mode`, `skeptic_depth`, `skeptic_role`, `skeptic_target`) and
read back by `monitor/ng wrap-up`, which enforces, presents, or skips
per the mode.

| Mode | Behaviour |
|---|---|
| `require` | A skeptic MUST validate. `wrap-up` emits `SKEPTIC REQUIRED` and sets the pending marker; the task is not done until a verdict lands. Only the operator can waive. |
| `auto` (default) | The worker decides at wrap-up per the responsible-default heuristic and records the decision (`--skeptic-decision` + `--skeptic-rationale`). |
| `deny` | No skeptic — trivial or reversible work. The choice is still recorded. |

`wrap-up` carries the full skeptic flag set:
`--skeptic-decision`, `--skeptic-rationale`, `--skeptic-waive`,
`--skeptic-role`, `--skeptic-verdict`, `--skeptic-target`,
`--skeptic-depth`, `--skeptic-findings`.

### Comms channel

`monitor/skeptic-channel.sh` is the worker↔skeptic comms channel plus
nudge engine (also reachable as `ng skeptic <sub>`). Subcommands:
`init`, `ask`, `await`, `answer`, `await-answer`, `reconcile`, `close`,
`poll`, `status`, `list`, `nudge`, `dir`, `reqfile`. Each review gets a
per-task channel directory at `monitor/.state/skeptic/<task-id>/`, where
the task-id is the reviewed worker's window name. The not-yet-validated
gate is a marker at `monitor/.state/skeptic/pending/<window>`.

The **primary** wake mechanism is a **worker-run blocking await loop**,
not a hook. (A `PostToolUse` autodetect hook used to surface requests,
but it only fired while the worker was issuing tool calls — and a worker
is idle, firing none, exactly when a skeptic probes its finished result.
The hook is removed; the loop replaces it.) Each lifecycle transition is
an atomic rename, and the rename IS the signal:

```
  skeptic                          channel dir                       worker
    |                                  |                                |
    |-- ask (temp+rename) ----------->[req-NNN-<slug>.open.md]          |
    |                                  |                                |
    |                                  |<-- await: ACK by renaming -----| (blocking poll loop;
    |                                  |   .open.md → .ack.md, exit 0   |  refreshes pending marker)
    |                                  |[req-NNN-<slug>.ack.md] -------->| reads, appends reply,
    |                                  |<-- answer: rename --------------|  renames .ack.md →
    |                                  |[req-NNN-<slug>.answered.md]     |  .answered.md, RE-ENTERS await
    |-- await-answer --> reads <-------|                                |
    |                                  |                                |
    |-- reconcile (ensure all acked; nudge stragglers) --------------->|
    |-- close ----------------------->[DONE] -------------------------->| await sees DONE → exit 10
    |                                  |                                |  worker stops looping, retires
```

`await` (worker) blocks until a request lands, acks it, and exits 0 (or
10 on `DONE`, 4 on timeout — a bounded single call; the worker re-enters).
`reconcile` (skeptic, at its wrap) ensures every filed request is past
`.open.md`, nudging stragglers, and fails loud (exit 6) if a worker never
acks. `close` drops the `DONE` sentinel so the worker can retire.

The `nudge` subcommand wakes a worker that stopped re-entering await. It
reuses `paste-followup.sh`, resolves the window NAME → tmux INDEX before
probing `pane-state.sh` (fail-safe skip if unresolvable), skips panes
that are busy or user-typing (so it never interrupts active work), and is
rate-limited (default 120 s between nudges) so a polling skeptic can't
spam the pane.

**Parked-awaiting-skeptic (watcher exemption).** A worker parked in
`await` reads `busy` (the await tool's spinner) and is additionally
exempted by the watcher: each `await` poll refreshes the worker's
`skeptic-pending` marker mtime, and the idle probe (`_idle_probe.sh`)
classifies a worker with a **live** marker (within
`monitor.skeptic.await_hang_seconds`, default 600 s) as
`parked-awaiting-skeptic` — exempt from `idle-too-long`/`no-wrap-up` and
surfaced as its own snapshot row. A stale marker lapses the exemption so
a genuine hang resurfaces (the hang-vs-wait boundary). This reuses the
existing marker (no new pane-state). The watcher auto-respawns only the
orchestrator; worker windows are flagged, never auto-respawned on
staleness, so this exemption plus retire-preflight's marker gate is the
complete worker-side hardening.

### Verdicts

A skeptic ends its pass by recording exactly one verdict via
`ng wrap-up --skeptic-role --skeptic-verdict <…>` (the `ms-audit` /
`bipartite` ladder; the rubric is canonical in
[`skills/nexus.skeptic/SKILL.md`](../skills/nexus.skeptic/SKILL.md)):

| Verdict | Meaning | Downstream |
|---|---|---|
| `credible` | No surviving concern; the result holds. | Proceed. |
| `check` | Keep, but specific concerns must be resolved first. | Pause; resolve before building on it. Not, by itself, substantive — does not auto-trigger a second pass. |
| `suspect` | Strong reason to doubt; do not build on it. | Stop. Triggers a second pass. |
| `refuted` | The worker's result (or the spec it followed) is wrong. | Overturned; route the correction. Triggers a second pass. |

The verdict is logged as a `skeptic-verdict` action-log event and (on
`suspect`/`refuted`, or `--skeptic-findings >= findings_threshold`)
drives the bounded recursion below.

### Recursion

A skeptic's findings can themselves warrant scrutiny, so recursion is
bounded by `monitor.skeptic.max_depth` (default 3). A second-pass
skeptic spawns only on substantive new issues — a `suspect` or
`refuted` verdict, or findings count >= `monitor.skeptic.findings_threshold`
(default 1). At the cap, the chain escalates to the operator rather
than spawning again. Termination is guaranteed: depth strictly
increments and is capped, so a review chain runs at most `max_depth+1`
passes.

### Config and action-log

Config knobs (under `monitor.skeptic.`):

- `max_depth` (default 3) — recursion ceiling.
- `findings_threshold` (default 1; floored at 1) — findings count that
  justifies a second pass.
- `enforce_auto_decision` (default true) — `auto` mode refuses a wrap-up
  that records no decision + rationale (set false for advisory-only).
- `await_timeout_seconds` (default 900) — per-call `await` timeout (the
  loop heartbeats throughout; on timeout the worker re-enters).
- `await_interval_seconds` (default 5) — `await` poll / heartbeat cadence.
- `await_hang_seconds` (default 600) — hang-vs-wait threshold: a parked
  worker is exempt from idle flagging only while its pending-marker mtime
  is within this window.

Every mode's wrap-up prints a `CONSEQUENCE:` line stating plainly what
happens next (require → the window cannot retire until a verdict lands;
auto → record a decision now, and the retire gate applies if you choose
require; deny → proceeding without a skeptic, recorded), so no worker is
surprised by the gate.

Action-log events (`monitor/ng log-action`): `skeptic-request`,
`skeptic-spawn`, `skeptic-verdict`, `skeptic-decision`,
`skeptic-escalate`, `skeptic-nudge`.

Tests: `monitor/watcher/test-skeptic-channel.sh` (119 assertions: the
worker await→ack→answer→re-await loop, the DONE terminal exit, atomic-
rename race safety, the heartbeat's `touch -c` no-recreate guard,
reconcile fail-loud, the nudge guards, and the bounded-recursion /
chain-termination paths) plus the
`parked-awaiting-skeptic` exemption block in
`monitor/watcher/test-idle-probe.sh`, the retire-gate marker check in
`monitor/test-retire-preflight.sh`, the wrap-up gate-before-handoff in
`monitor/watcher/test-ng-wrap-up.sh`, and the provenance round-trip in
`monitor/watcher/test-spawn-worker.sh`.

## Monitor agent scope: delegate, don't do work

The monitor agent (the session in the `orchestrator` tmux window)
coordinates other agents — it does **not** run code, scripts,
data analysis, or image processing itself, even for "quick"
diagnostics. Every task that produces an artifact (a script's
output, a numpy table, a generated image, a code change, a
commit) must run in a fresh tmux worker via the prompt-file +
launcher pattern in `skills/nexus.tmux-spawn/SKILL.md`.

Read-only orchestration tool calls — `tmux list-windows`,
`gh issue view`, `head -7 reports/*.md`, dashboard pushes via
`monitor/ng dashboard put`, action-log writes, the bootstrap
script — are coordination, not work, and stay in-orchestrator.

The line: if the action would have appeared in a worker's
"What Was Done" section, it should have run in a worker's window.
Doing work in-orchestrator bloats the monitor's context, blocks
parallel coordination, cuts the worker out of artifacts they
should own, and erodes the architectural separation the nexus is
built around.

## When to inspect the dashboard

1. **Start of a session** before spawning new work — open the
   `Nexus` issue on GitHub to see what's active, blocked, and
   pending. Check `tmux list-windows` to confirm a monitor is
   running.
2. **Before spawning a new tmux agent** — the dashboard's
   running-agents table lists window names in use, avoiding
   collisions.
3. **Before committing cross-project work** — the per-project
   status section shows branch + dirty state.

## Communicating with the nexus

The user-facing interface is GitHub Issues. (A human at the host can
also always switch to a worker's tmux pane and type in the Claude
Code TUI directly — no monitor command needed; the watcher marks the
window operator-engaged and suppresses idle handling while the
operator drives. GitHub stays the recommended default: it works from
anywhere and leaves a trail. The stamped-paste machinery,
`monitor/paste-followup.sh`, is for the ORCHESTRATOR's follow-ups
only — see `monitor/docs/orchestrator-guide.md`.)

- **General requests** → comment on the `Nexus` overview issue.
- **Per-thread input** → comment on the relevant per-thread issue.
- **Routing to a specific tmux agent** → start a comment line with
  `@<window-name>:` (e.g. `@worker-3: please skip the slow
  preprocessing step`). The monitor auto-forwards via tmux
  paste-buffer, then posts a confirmation. Destructive-looking
  instructions (`delete`, `drop`, `force push`, `reset`, `clean`)
  are held for confirmation rather than auto-forwarded — the user
  re-sends with `@<window>!:` (the bang means "yes, do it").

Bot identity is account-based: comments from anyone other than
`github.user_login` are silently ignored regardless of content
(see "Eligible comments" below for the full filter). Two ways to
opt a comment you just wrote out of processing:

- **`/skip` marker (preferred).** Start the comment with `/skip`
  on its own first line (synonym `/nexus-skip`), then your note
  below. The watcher drops it and the orchestrator never sees it
  — a first-class "side note, don't act on this" escape hatch.
  See "Skip marker" below for the exact matching rule and which
  surfaces honour it.
- **🚀 rocket reaction.** React with 🚀 — the eligibility filter
  treats any rocket reaction as "already processed". One-tap from
  mobile, but racy (the watcher may forward before the reaction
  lands) so prefer `/skip` when you know up front.

The bot also uses `rocket` to mark "action taken" and `eyes` to
mark "processing".

## GitHub interaction model

Authority and identity are split across two GitHub accounts:

| Account         | Role                                                  |
|-----------------|-------------------------------------------------------|
| `<user_login>`  | The user. Source of every directive. Configured in `github.user_login`. |
| `<bot>[bot]`    | The agent's identity, backed by a per-operator GitHub App (App ID, installation ID, pem path in `github.bot_*`). Posts comments, edits the overview issue body, adds reactions. |

GitHub mobile push notifications fire whenever the bot acts on the
user's comments — that's the wake signal for the user side.

### Bot authentication

Every GitHub write goes through `monitor/mint-token.sh`, which mints
or returns a cached installation access token from the App's private
key. Most agent ops route through the higher-level `monitor/ng` CLI
(see [Compact GitHub helper](#compact-github-helper-ng) below), which
mints the token internally; raw `gh` is still available when needed:

```bash
GH_TOKEN=$(monitor/mint-token.sh) gh issue comment ...
GH_TOKEN=$(monitor/mint-token.sh) gh api -X POST /repos/.../reactions -f content=eyes
```

Tokens are valid ~1 h and cached at `github.bot_token_cache` (default
`~/.claude/.nexus-bot-token.json`) with `chmod 600`; the helper
re-mints when within 5 min of expiry. App ID, installation ID, pem
path, and cache path come from `config/nexus.yml` (`github.bot_*`);
each also has a `$NEXUS_BOT_*` env override (see the env-var table
at the bottom).

### Eligible comments (the security boundary)

A user comment is surfaced **only if all** hold:

- `comment.author.login == <github.user_login>`
- `comment` has **no** `eyes` (👀) reaction from a non-user login
  (implemented as "no EYES reaction by a login other than the user"
  so the check stays portable across forks regardless of bot name).
- `comment` has **no** `rocket` (🚀) reaction from **any** login —
  a non-user rocket means the bot finished; a self-rocket by the
  user means "skip this" (one-tap mobile opt-out).

Bot identity is account-based — bot-authored comments are excluded by
the author filter, so no body-prefix convention is needed or honoured.

The filter is enforced inside `monitor/watcher/main.sh`'s
`snapshot_github` (GraphQL query + `jq` filter) before the agent
ever sees a comment. The EYES predicate is null-safe
(`(.user.login // "") != $login`) so reactions whose `.user` is null
in the GraphQL response still match the exclusion branch. Comments
from any other author are silently ignored even if that author has
repo write access.

#### Skip marker (operator opt-out)

A comment (or new issue) the operator flags with a skip marker is
dropped from the eligible set and never forwarded to the
orchestrator — the deliberate "side note / don't act on this"
escape hatch. Two forms:

- **`/skip` slash-command (primary).** The body's first non-empty
  line, trimmed and case-insensitive, is exactly `/skip` (synonym
  `/nexus-skip`). Type `/skip` on the first line, your note below.
- **`<!-- nexus:skip -->` HTML marker (secondary).** The literal
  token anywhere in the body — invisible in rendered GitHub
  markdown, for power users who want no visible trace.

Matching is conservative by design: a false drop is a lost
directive, so the watcher drops **only** on an unambiguous hit.
`/skip` buried mid-body, lookalikes like `/skipfoo` or `/skip-x`,
and prose such as "let's skip this" all still surface.

Honoured on every forwarded surface: issue comments, PR
conversation comments, PR review-thread comments, **and new-issue
bodies** — so the operator can open a tracking issue with a
leading `/skip` without the orchestrator jumping on it. Cross-repo
mention blocks are covered too.

Implemented as `_filter_skip_marker` in `monitor/watcher/_github.sh`,
chained right after `_filter_to_user_author` in
`_gh_filter_dedup_pipeline` (`main.sh`). Each drop writes one
`[skip-marker] dropped emit …` line to `monitor/.state/watcher.log`
(never to the orchestrator) so a skip stays diagnosable.

#### Manual emit-suppression (defense in depth)

If the reactions/dedup filters ever fail to exclude a comment that's
re-surfacing every poll cycle (rare; the symptom on the orchestrator
side is the same `id=<N>` line reappearing in `--- eligible github
comments ---` once per `monitor.interval_seconds`), the operator can
force-drop it via:

```bash
monitor/ng suppress-emit <comment-id> [--repo <owner/name>] [--reason "<short>"]
```

This appends `comment:<id>` to `monitor/.state/emit-suppression.lines`.
The last-hop awk filter `_filter_suppression` (in `main.sh`, chained
after `_filter_to_user_author | _filter_skip_marker |
_filter_cross_repo_surface | _dedup_emit_lines` inside
`_gh_filter_dedup_pipeline`) drops any emit
block whose `id=<N>` matches a `comment:<N>` entry in the file on the
next compose cycle. The file is append-only and persists across
watcher restarts; operator clears entries by editing the file
directly. Blank lines, leading whitespace, and lines starting with
`#` are ignored. The `signature:<hash>` prefix is reserved for a
future emit-signature-based suppression extension.

GitHub's eight reaction types are `+1 -1 laugh confused heart hooray
rocket eyes`. `eyes` from the bot means "agent has seen this and is
processing"; `rocket` from the bot means "action taken"; `rocket`
from the user on their own comment means "skip this" (mobile-friendly
opt-out). Any of these three signals marks a comment processed.

### Comment processing loop

For each eligible comment, the agent does, in order:

1. React `eyes`.
2. Decide the action:
   - **Routed directive** — first non-empty line matches
     `@<window-name>:\s*<instruction>` (e.g. `@worker-1: please skip
     the Tal1 step`). Auto-paste into the named tmux window
     (paste-buffer pattern from `skills/nexus.tmux-spawn/SKILL.md`),
     then post a confirmation comment. If the window doesn't exist, the
     instruction is ambiguous, or it looks destructive (`delete`,
     `drop`, `force push`, `reset`, `clean`), do NOT auto-forward —
     post a comment asking the user to confirm with `@<window>!:`.
   - **Plain comment** — post a new reply comment, or update the
     overview issue body and reply confirming. Never edit the user's
     comment.
3. React `rocket` when fully processed.

### Authored content

The bot only writes:

- New reply comments on issues.
- Edits to its own content, primarily the overview issue body
  between the `<!-- NEXUS_DASHBOARD_START -->` markers.

The bot's App username + avatar make its authorship visible, and the
author-based eligibility filter ensures the bot can never read its
own output as user input. No body-prefix convention is used.

### Detect-and-react on GraphQL failures

The watcher's three `_snapshot_*` helpers (`issue_comments`,
`pr_comments`, `new_issues` in `_github.sh`) all hit the bot
installation's shared GraphQL bucket. When that bucket exhausts
(typical trigger: 4–5 active workers + orchestrator + watcher all
minting installation tokens and issuing `gh api graphql` calls),
every `_snapshot_*` call returns a `graphql_rate_limit` error.
Previous behaviour swallowed it via `2>/dev/null`, leaving the
watcher silently productive while no eligible comments surfaced —
the 2026-05-01 incident silenced the watcher for 2 h 17 m before
<operator> noticed (research: `reports/nexus_2026-05-01_124942_watcher-rate-limit.md`).

The current shape captures stderr per call and routes failures
through `_watcher_handle_graphql_failure`:

- **Rate-limit signature** (`"RATE_LIMIT"` or `"graphql_rate_limit"`
  in stderr JSON): write a backoff file
  `monitor/.state/graphql-backoff-<surface>` containing the reset
  epoch (parsed from `extensions.reset_at_epoch` /`reset_at`, or
  `now + 15 min` fallback); emit a `watcher_alert=rate-limit
  surface=<surface> reset=<epoch>` sentinel line on stdout that
  rides `_dedup_emit_lines` → `compose_report` → `paste_to_target`
  so the orchestrator sees the alert within one cycle. Subsequent
  polls short-circuit via `_graphql_backoff_active` until
  `now >= reset + 30 s`. Sentinel + log dedup via flag file
  `graphql-alert-emitted-<surface>-<reset>` — one alert per
  bucket-exhaustion event, not one per poll. Deliveries-path
  (App-JWT, separate bucket) is unaffected and keeps surfacing
  comments during the backoff window.
- **Unknown failure** (non-rate-limit JSON or empty stderr): no
  sentinel emit (avoid alert-storm on transient noise); one log
  line per surface per 10 min to `monitor/.state/watcher-alerts.log`.

To inspect after a suspected silence, `tail
monitor/.state/watcher-alerts.log` for `WARN <surface>
graphql_rate_limit reset=...` (rate-limit fires) or
`graphql_failure ...` (other failure classes).

## Compact GitHub helper (`ng`)

`monitor/ng` is the agent-facing wrapper around the operations the
loop performs every wake. It mints the bot token internally, hides
the verbose JSON `gh api` returns, and folds two-step sequences
("react then fetch", "splice then PATCH") into a single subcommand
so each user comment is processed in three or four tool calls
instead of eight.

| Subcommand | Effect | stdout |
|------------|--------|--------|
| `ng process <comment-id>` | Defensive eligibility check (author, no non-user EYES, no ROCKET from anyone) → POST eyes reaction → fetch body. Exit 1 on rejection. | `issue=<n>` / `author=<login>` / `body<<EOF` … `EOF` |
| `ng react <comment-id> <eyes\|rocket>` | Single reaction POST. | (silent) |
| `ng reply <issue> [--repo <owner/name>] [--body-file <path>]` | Post a comment (body from `--body-file` or stdin). `--repo` overrides the cwd-derived target (useful when running from a worktree whose `origin` points at the code repo, not the issue repo). | comment URL |
| `ng close <issue> [--comment <text>]` | Optional comment, then close. | `CLOSED` |
| `ng issue <issue>` | One-line issue summary. | `#<n> state=<STATE> title=<title>` |
| `ng upload <local-path> [--issue N] [--repo-path <path>] [--shape pin\|latest] [--message <msg>]` | Thin shim over `monitor/upload-asset.sh` — commit a local file (image or report markdown) to the asset repo's `main` branch under `assets/...` and print a SHA-pinned URL suitable for embedding. `--issue N` routes under `assets/N/`; sources under `reports/` auto-cluster to `assets/reports/`; everything else lands at `assets/general/`. `.md`/`.ipynb` get a `blob/<sha>/` URL (renderable page); other extensions get `raw/<sha>/` (embed-friendly). | asset URL pinned to post-push SHA |
| `ng wrap-up <issue> <report-path> [--trigger-comment <id>] [--repo <owner/name>] [--comment-body-file <path> \| --no-comment] [--retain <reason> \| --no-retain]` | The universal end-of-task hand-off, folded into one verb: (1) upload the report via `ng upload --issue N`; (2) post a comment on `<issue>` — templated body by default (title from H1, one-sentence summary from `## Summary` or first 200 chars), bespoke when `--comment-body-file` is set (substitutes `{{REPORT_URL}}` token, else appends `Full report: <URL>` footer), skipped when `--no-comment` is set; (3) rocket-react `--trigger-comment` if supplied; (4) `log-action monitor --event wrap-up`; (5) `log-action monitor --event window-retain` for the source tmux window so the watcher mutes the wrapped row for `monitor.retain_ttl_seconds` (default 24 h) — auto-tagged `wrap-up-<YYYY-MM-DD>` unless `--retain <reason>` overrides; `--no-retain` opts out (close-immediately). Step 5 is silently skipped off-tmux and its failure does not flip exit. (6) when the source window carries a live operator-engagement mark, prints the interactive-wrap clarification: staying engaged is the DEFAULT (follow-up inquiries expected); `ng engaged-done` is the explicit finished-signal. Exit 0 only when every attempted hand-off step (1–4) succeeds; on partial failure, prints which steps ok/failed on stderr so the caller can retry. | per-step status lines on stdout |
| `ng engaged-done [--window <name>]` | The interactive session's explicit FINISHED-signal (the <your-org>/<your-nexus>#205 state-machine follow-up). Appends an `engaged-done` action-log event for the calling pane's window (or `--window`); the watcher treats it as the engagement-mark invalidation, dropping the window back to the typical wrapped-window cleanup path. A later operator prompt re-engages — the release is never a lock-out. | confirmation line |
| `ng dashboard get` | Fetch the overview issue body and emit only the content between `<!-- NEXUS_DASHBOARD_START -->` / `<!-- NEXUS_DASHBOARD_END -->`. Caches to `.state/dashboard.md`. | dashboard middle |
| `ng dashboard put [--body-file <path>]` | Re-fetch the body, splice the new middle in (preserving the static prose around the markers), PATCH. Updates the cache on success. Runs the section-schema check in **warn-only** mode — prints missing required sections to stderr but never blocks the push. | issue URL |
| `ng dashboard scaffold` | Print the canonical dashboard skeleton (the six required sections — `## Identity` · `## Infra` · `## Services` · `## In-flight` · `## Awaiting operator` · `## Recent landings` — each with a one-line hint). Seed a new dashboard by piping into `dashboard put`. | section skeleton |
| `ng dashboard validate [--body-file <path>]` | **Strict** schema gate: exit 0 if every required section heading is present, exit 1 (listing the missing ones) otherwise. The hard-failure counterpart to `put`'s warn-only check. Reads `--body-file` or stdin. | OK line / missing list |
| `ng nexus-identity [--upsert-overview] [--dry-run] [--repo <owner/name>]` | Render the auto-generated **Nexus identity** block — working-directory headline plus host, asset+issue repo, implementation-clone remote/branch, and watcher pidfile/log — and idempotently upsert it into the overview issue body between `<!-- nexus-identity:start -->` / `<!-- nexus-identity:end -->`. Every field is DERIVED from `$NEXUS_ROOT` / `github.repo` / hostname / the clone's git origin, so it's generic across operators. `--dry-run` renders without the PATCH. | identity block / issue URL |
| `ng watcher-status` | One-shot liveness summary: heartbeat age, PID + alive/dead, target window, lock state, tmux presence, archived-diffs count. | key=value block |
| `ng log-action <agent> --event <name> [--note <t>] [--extra k=v]...` | Append one JSONL line to `monitor/.state/action-log.jsonl`. Structured trace of meaningful actions (processed comments, dashboard updates, agent spawns). Reserved keys: `ts`, `agent`, `event`, `note`. | (silent) |

This table is the GitHub-write/lifecycle subset. **`ng help` (or
`ng verbs`, `ng --help`) prints the complete categorized index of
every dispatchable verb** — the single "what can `ng` do" surface.

### Pass-through facades

These verbs are thin `exec` front doors over standalone
`monitor/*.sh` scripts (the `ng skeptic` shape): `ng <verb>` forwards
`"$@"` and passes stdout, stderr, and the exit code through
**unchanged**. The gate/logic and its dedicated `test-*.sh` unit stay
single-source in the script — `ng` adds only a discoverable home, no
new logic. Each script remains directly callable (`source`, `$(…)`
capture, the test suite); the facade is an *alias*, not a migration.

| Subcommand | Forwards to | Used by |
|------------|-------------|---------|
| `ng retire-preflight <window>` | `retire-preflight.sh` | orchestrator — synchronous go/no-go gate before `tmux kill-window` |
| `ng pane-state <window-index>` | `pane-state.sh` | orchestrator — classify a worker pane (`idle\|busy\|user-typing\|…`) |
| `ng write-probe <path>` | `write-probe.sh` | worker — pre-flight that a deliverable path is writable |
| `ng declare-wait <kind> <id> <desc>` | `declare-wait.sh` | worker — self-declare an async external wait |
| `ng declare-no-wait <kind> <id>` | `declare-no-wait.sh` | worker — mark an async launch fire-and-forget |
| `ng paste-followup <window> ...` | `paste-followup.sh` | orchestrator — canonical follow-up paste into a worker window |
| `ng token` | `mint-token.sh` | both — print a bot installation token (the `$(…)` idiom; symmetry with `ng mint-jwt`) |
| `ng user-pat` | `user-pat.sh` | worker — print the user PAT for private-repo reads |

There is intentionally no `ng diffs-since`. The archive is a plain
directory of sortable filenames; the agent-bootstrap one-liner is
`find monitor/.state/diffs -newer monitor/.state/last-ack.txt
-type f | sort | xargs -r cat`.

Errors print a single `ng: <reason>` to stderr and exit 1 — no JSON
dumps. Identity (`github.repo`, `github.user_login`, dashboard
markers) comes from `config/nexus.yml`; no script-local env vars
unique to `ng`.

## Issue structure

- **One pinned overview issue** labelled `nexus:overview`. Title:
  `Nexus`. The body carries two bot-managed, auto-generated, delimited
  blocks, both idempotently upserted (replace-in-place, never
  duplicate):

  1. **Nexus identity** (`ng nexus-identity`) — the standing "where
     this nexus lives" record: working directory (headline), host,
     asset+issue repo, implementation-clone remote/branch, watcher
     pidfile/log. All DERIVED from the environment/config, so it's
     correct for every operator with zero edits. Identity, not status.

         <!-- nexus-identity:start -->
         ## Nexus Identity
         **Working directory:** `<root>` ...
         <!-- nexus-identity:end -->

  2. **Dashboard** (`ng dashboard put`) — live status between the
     markers, with a **formalized six-section schema** (`## Identity` ·
     `## Infra` · `## Services` · `## In-flight` · `## Awaiting
     operator` · `## Recent landings`). `ng dashboard scaffold` prints
     the skeleton; `ng dashboard validate` is the strict checker;
     `ng dashboard put` warns (doesn't block) on missing sections. The
     `## Identity` section is a **pointer** to the identity block above,
     not a copy. See `skills/nexus.dashboard/SKILL.md`.

         <!-- NEXUS_DASHBOARD_START -->
         ...dashboard: the six required sections...
         <!-- NEXUS_DASHBOARD_END -->

  User comments on this issue = "ask the nexus anything" channel
  (spawn agent, start project, general questions).

- **Per-thread issues** for active work / open decisions, labelled
  `nexus:active` | `nexus:decision` | `nexus:blocked` plus
  `project:<work-subdir>`. Linked from the overview issue body.
  Closed when the work is done or the decision made.

## Embedding files (images and reports)

**Whenever you reference a local file (image, PDF, report markdown)
in a GitHub issue body or comment, upload it to the asset repo first
and link/embed via the printed URL.** Local files in `reports/` and
build outputs are gitignored — anyone reading the comment on
github.com can't see them otherwise. The asset repo is configured
by `github.asset_repo` (defaulting to `github.repo` if absent); its
`main` branch holds an `assets/` tree, so binaries and ephemeral
reports don't bloat the code repo's history.

One shape:

```bash
url=$(monitor/ng upload path/to/figure.png --issue 104)
# markdown image: ![figure]($url)

url=$(monitor/ng upload reports/nexus_2026-04-27_120000_thing.md --issue 104)
# markdown link:  [report]($url)
```

The printed URL is pinned to the SHA of the post-push commit —
subsequent overwrites at the same path do NOT change what the URL
resolves to. Two URL shapes by extension:

- `.md` / `.ipynb` → `https://github.com/{owner}/{repo}/blob/<sha>/<path>` (renders as a page on github.com).
- everything else → `https://github.com/{owner}/{repo}/raw/<sha>/<path>` (same-domain 302 to a viewer-session-bound signed CDN URL; embed-friendly).

Both render for any viewer logged into github.com (desktop or
mobile browser).

### `ng upload` defaults

`ng upload` is a thin shim over `monitor/upload-asset.sh` (same flags,
same output). The uploader maintains a local clone of the asset repo
at `<nexus_root>/assets/` (gitignored), copies the file into
`assets/<repo-path>`, commits as the bot, and pushes to `main`.

| Source path | Flag | Asset destination | Printed URL |
|-------------|------|-------------------|-------------|
| `figure.png` | `--issue 104` | `assets/104/figure.png` | `.../raw/<sha>/assets/104/figure.png` |
| `reports/foo.md` (or `*/reports/foo.md`) | (default) | `assets/reports/foo.md` | `.../blob/<sha>/assets/reports/foo.md` |
| `figure.png` | (default, no `--issue`) | `assets/general/figure.png` | `.../raw/<sha>/assets/general/figure.png` |

Three notable behaviours:

- **`--issue N` routes to `assets/N/`.** Pass `--issue 104` for an
  asset belonging to issue `#104`; per-issue subtrees keep related
  artefacts together.
- **Reports auto-cluster** at `assets/reports/<basename>` when no
  `--issue` is given. Sources whose path contains `reports/` keep
  that placement.
- **SHA-pinned by default.** Use `--shape latest` to emit a
  `main`-branch URL when you want "current head" semantics instead
  of a permalink.

Override with `--repo-path` for fine control (e.g. `--repo-path
fig4/v3-final.png` lands at `assets/fig4/v3-final.png`). The leading
`assets/` is auto-prepended if absent.

### What not to use

Do **not** use `raw.githubusercontent.com/...` (wrong-domain cookies
on private repos), `data:` URIs in `<img src>` (markdown sanitiser
strips them), signed Contents-API `?token=` URLs (5-min TTL), or
release assets (anonymous 404).

Linking to a `reports/<file>.md` path in the source repo also
doesn't work — `reports/` is gitignored, so the file isn't on any
branch and the link 404s on github.com. Always upload first.

The pre-cutover wiki shape
(`github.com/.../wiki/status-assets/...`) is preserved as legacy.
URLs in older comments still resolve because the wiki is a separate
Git surface that we don't delete. New uploads use the asset-repo
shape above.

Inline images in **emails** from `notify.sh` take a different path:
`multipart/related` with the PNG referenced by `cid:` — no public
URL needed, payload travels with the mail.

## Push notifications (phone + email)

`monitor/notify.sh` fans out to up to three channels for events
GitHub cannot surface on its own (local state, dashboard body edits,
Slurm completion). Tiered by `--priority`:

| Tier | Channels | Semantics |
|------|----------|-----------|
| `routine` (default) | Pushover priority 0 (falls back to ntfy priority 3 if Pushover isn't configured) | "you'd want to know, no hurry" |
| `emergency` | Pushover priority 1 **+** email (falls back to ntfy priority 5 + email) | "human intervention needed" |

Routine GitHub activity (comments, mentions, assignments) is **not**
sent through this helper — GitHub's own push channel already covers
it.

### Channel setup

**Pushover (default routine channel)**

1. Install the app:
   [iOS](https://apps.apple.com/us/app/pushover-notifications/id506088175) /
   [Android](https://play.google.com/store/apps/details?id=net.superblock.pushover).
   Free 30-day trial, then $5 one-time per platform.
2. Create an application at https://pushover.net/apps/build (name
   `Nexus Monitor`, type `Application`).
3. Drop the **user key** (single 30-char line) in the file at
   `notifications.pushover.user_key_path` (default
   `~/.claude/.nexus-pushover-user-key`, `chmod 600`).
4. Drop the **application API token** (single 30-char line) in the
   file at `notifications.pushover.app_token_path` (default
   `~/.claude/.nexus-pushover-app-token`, `chmod 600`).

Pushover fires only when both files exist with the correct perms.

**ntfy.sh (fallback)**

Used automatically when Pushover is missing. Install the
[iOS](https://apps.apple.com/us/app/ntfy/id1625396347) /
[Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy)
app; subscribe to the topic stored in the first line of the file at
`notifications.ntfy.topic_url_path` (strip the `https://ntfy.sh/`
prefix).

**Email (emergency only)**

- **Recipient**: `notifications.email.address`
  (env override: `$NEXUS_EMAIL_TO`). `notifications.email.probe_address`
  is a disposable alias used only for probes.
- **Relay**: `notifications.email.smtp_host` / `.smtp_port`
  (env override: `$NEXUS_SMTP_HOST` / `$NEXUS_SMTP_PORT`). Must
  accept mail from the cluster host without authentication.
- **Body shape** (enforced inside `notify.sh`): subject `[nexus]
  <title>`; plain-text first two lines are always:

      Event: <title>
      Issue: <click-url or "(no link)">

  followed by the message. Sender is `nexus-monitor@<cluster-host>`.
- **Inline image** (optional): pass `--image <path.png>` and
  `notify.sh` builds a `multipart/related` MIME tree — plain-text
  plus an HTML alternative whose `<img src="cid:...">` references
  the attached image.

### Helper: `monitor/notify.sh`

```
monitor/notify.sh "<title>" "<body>"
                  [--priority routine|emergency]   # default: routine
                  [--url <click-url>]
                  [--image <path-to-png>]          # attaches on email/push
                  [--tag <ntfy-tag>]...            # ntfy-only
                  [--require-delivery] [--quiet]
```

- Round-trip ~0.4 s per channel, `--max-time 5|6` caps.
- Silent no-op when no backend is configured — callers in the
  monitor loop need no conditional. Pass `--require-delivery` to
  make the helper exit nonzero on total failure (manual probes
  only).
- Exit codes: `0` ok / silently-skipped, `1` usage, `2`
  `--require-delivery` set with no configured backend, `3`
  `--require-delivery` set and every backend failed, `4` `curl` /
  `python3` missing.

### Secret handling

- `~/.claude/.nexus-pushover-user-key`,
  `~/.claude/.nexus-pushover-app-token`, and
  `~/.claude/.nexus-notify-token` are bearer tokens. Perms must be
  `0600` or `0400`; anything else is rejected. Never commit, never
  place inside `monitor/.state/`, never paste in comments.
- Pushover rotation: delete the app at https://pushover.net/apps,
  create a new one, rewrite the app-token file. User key rotation
  needs a new Pushover account (rare; only on key leak).
- ntfy rotation: `openssl rand -hex 16`, rewrite the topic-URL
  file, re-subscribe in the app.
- `~/.claude/<bot-slug>-webhook-secret` (path recorded at
  `github.bot_webhook_secret_path`) holds the HMAC secret that matches
  the value pasted into the App settings page's *Webhook secret*
  field. Perms `0600` or `0660` (group-readable for the bot uid only).
  **Operationally informational today** — the watcher reads the
  deliveries log over an authenticated channel (`mint-token.sh` JWT)
  and trusts GitHub end-to-end, so the file is hygiene rather than
  load-bearing. It becomes load-bearing the moment HMAC verification
  moves into a self-hosted receiver. Rotation: `openssl rand -hex 32`,
  rewrite the file, paste the same value into the App settings page;
  the deliveries log keeps flowing because GitHub records deliveries
  regardless of receiver outcome.
- Email address: not secret.

### Trigger policy

The monitor agent decides which diffs warrant a push (see
`monitor/agent-prompt.md` "Notifications" for the current routing
table). Default-enabled set:

| Event | Tier | Why push |
|-------|------|----------|
| tmux window disappeared without a matching new `reports/*.md` | `routine` | local-only; invisible on GitHub |

Opt-in (not wired; ask the user before enabling):

- Dashboard body edit with >20 line diff → `routine`.
- New `nexus:decision` issue created by the bot → `routine`.
- Slurm job transitions from running → complete/failed → `routine`.
- Monitor-detected pipeline wedge (watcher dying repeatedly, bot
  token revoked, long-running project stuck >2 h with no report) →
  `emergency`.

Add triggers conservatively — firehose defeats the mechanism.

## Standing up your own nexus

You don't fork `nexus-code`. You **clone** it (origin stays at
`<your-org>/nexus-code`) and create your own asset+issue repo
(e.g. `<your-org>/<yourname>-nexus-assets`) that the monitor
writes to. Every per-operator value lives in one file at the
workspace root: `config/nexus.yml` (gitignored). A committed
template sits next to it: `config/nexus.example.yml`, fully
documented. The end-to-end walkthrough is the README's "How to
run" section + [`BOT_SETUP.md`](BOT_SETUP.md). The skeleton:

1. `git clone git@github.com:<your-org>/nexus-code.git` onto a fast
   filesystem.
2. `gh repo create <your-org>/<yourname>-nexus-assets --private`
   — your asset+issue repo. The bot installs here, the monitor
   writes the dashboard here, `monitor/upload-asset.sh` pushes
   `assets/...` here.
3. Create your own GitHub App at
   https://github.com/settings/apps/new (permissions per
   `BOT_SETUP.md`'s permission table), install it on the
   asset+issue repo from step 2 (NOT on `nexus-code`), download
   the RSA key.
4. `cp config/nexus.example.yml config/nexus.yml && chmod 600
   config/nexus.yml`. Edit every value:
   - `nexus.root` — absolute path to the cloned `nexus-code`
     checkout.
   - `github.user_login` — your GitHub login (only your comments
     drive the monitor).
   - `github.repo` — `<owner>/<name>` of your asset+issue repo,
     not `<your-org>/nexus-code`.
   - `github.asset_repo` — leave commented; defaults to
     `github.repo`. Set explicitly only if you want assets in a
     different repo from issues (rare).
   - `github.bot_app_id`, `github.bot_installation_id`,
     `github.bot_pem_path` — from step 3. Each operator runs
     their own App; do not reuse another operator's installation.
   - `notifications.pushover.{user_key_path,app_token_path}` —
     Pushover user key (from the app's main screen) and app API
     token (from https://pushover.net/apps/build) in their
     respective files, single-line, `chmod 600`.
   - `notifications.ntfy.topic_url_path` — single line holding the
     full ntfy topic URL, e.g. `https://ntfy.sh/<unguessable-topic>`.
   - `notifications.email.*` — production + probe recipient, SMTP
     relay. Pick whatever SMTP accepts your cluster's mail without
     auth.
5. Verify the wiring per `BOT_SETUP.md`'s "Verify" section
   (`ng issue 1`, `ng preflight`, `ng upload README.md`).

Every helper (`monitor/watcher/main.sh`, `monitor/mint-token.sh`,
`monitor/notify.sh`, `monitor/upload-asset.sh`) reads values via
`config/load.sh <dotted.key>`; no shell source needs editing. Env
vars on each script still override.

### Claude Code version: vetted floor + operator-local pin

The project-local Claude Code install (`node_modules/.bin/claude`,
managed by `monitor/install-claude-local.sh`) runs on a **two-tier**
version model (<your-org>/nexus-code#226):

- The `@anthropic-ai/claude-code` version in the shared `package.json`
  is a **maintainer-managed, vetted FLOOR** — used for **initial setup
  only**. A fresh clone with no local pin installs exactly this version:
  deterministic, gate-vetted, never an unvetted "latest". The maintainer
  advances the floor **deliberately** (something that has run stably for
  **≥1 day**, bundled with other updates), so it lags the bleeding edge
  by design and does **not** track each ~daily Claude Code release.
- Each operator's **running** version is an **operator-local pin**:
  `monitor/.state/cc-version-local` (gitignored). A successful gated
  cc-update run (`skills/nexus.cc-update/GUIDE.md`) writes this file and
  advances the local install **without touching the shared
  `package.json`**. The working tree stays clean — this retires the old
  "unpushed local `chore: bump` commit" divergence.

`monitor/_cc-version.sh` is the single resolver every consumer reads:
**`effective = local-pin (if present) else package.json floor`**.
`install-claude-local.sh` installs + verifies the effective version (and,
when a local pin is present, installs it explicitly with
`npm install --no-save` so the floor is untouched); the watcher's
update-detection gate (`_v2_task_cc_version_check`) compares the npm
`latest` dist-tag against the **effective** version, so it fires for the
version you actually run and stops firing once your local pin catches up
— independent of the lagging floor. You never edit `package.json` to move
your own version; only the maintainer does, and only to raise the floor.

The manual **"update available" emit is OFF by default**
(`monitor.cc_update.emit_enabled: false`, env
`MONITOR_CC_UPDATE_EMIT_ENABLED`). Detection (`cc_version_check`) still
runs on its cadence and maintains `monitor/.state/cc-update-available`,
but the watcher no longer surfaces the `--- claude code update available
---` nag to the orchestrator — when the autonomous daily routine below is
enabled it runs the same gate itself, so the manual nag is redundant. Set
`emit_enabled: true` and restart the watcher to restore the manual gate
(for operators who prefer a human evaluation trigger and do **not** enable
the autonomous routine). Note: this gates the *surface* only — it disables
neither detection nor any gate; the gate lives in the autonomous routine
(`cc-auto-update-apply.sh`). With both `emit_enabled` and
`cc_auto_update.enabled` off, the signal file is still recorded but nothing
acts on it.

### Autonomous daily cc-update (opt-in)

Detection alone only *informs*. With `monitor.cc_auto_update.enabled:
true`, the watcher additionally **drives** the gated loop end-to-end:
once per calendar day at `monitor.cc_auto_update.fire_time` (default
04:00 local, anacron-style catch-up, durable across watcher restarts
and orchestrator respawns via on-disk stamps under
`monitor/.state/cc-auto-update/`) the `cc_auto_update` task
(`monitor/watcher/_cc_auto_update.sh`) re-checks the registry and
spawns an autonomous evaluator worker. The evaluator runs the full
GUIDE flow (changelog → collision analysis → cc-harness gate) and
branches through `monitor/cc-auto-update-apply.sh`:

- **provably safe** (gate GREEN + non-gate surfaces cleared) → full
  bump autonomously: operator-local pin + `install-claude-local.sh` +
  watcher restart + the Step-5b watchdog-observed orchestrator
  restart. No operator engagement.
- **nexus-code compat change required** → never bumps: comments the
  findings on an existing open `cc-compat` PR, or opens one (base
  `dev`) and **holds for operator approval**.
- **block / any uncertainty** → never bumps; records + surfaces.

Every decision lands in the append-only audit trail
`monitor/.state/cc-auto-update/decisions.tsv`. Default **disabled**;
enabling it is a deliberate per-operator config change.

### Precedence for a given value

1. Script-local env var (e.g. `MONITOR_REPO`).
2. `config/nexus.yml` (your fork).
3. `config/nexus.example.yml` (template; used only if a key is
   absent from `nexus.yml` AND no env var is set).
4. Hardcoded fallback inside the script (last-resort backcompat).

### `config/load.sh`

Tiny Python/pyyaml wrapper. `config/load.sh github.repo` prints the
value, `config/load.sh monitor.interval_seconds 60` prints the value
falling back to `60` if missing, `config/load.sh --dump` prints
every resolved key.

## Tech stack

Components the monitor depends on, ordered by criticality:

- **`agent-sandbox`** (`$HOME/.linuxbrew/Cellar/agent-sandbox/`)
  — kernel-enforced filesystem sandbox every Claude Code session
  runs inside; limits writes to the project dir and `~/.claude/`.
- **`<hpc-skills>`** (`work/<hpc-skills>/`) — skill library the
  agents surface when handling <your-institution> HPC tasks (Slurm, storage
  tiers, modules, etc.).
- **`labsh`** (`work/labsh/`) — project-local JupyterLab for
  stateful kernel execution across turns.
- **GitHub App** (`<bot>`) — identity for every write; App ID +
  installation ID sourced from `config/nexus.yml`.
- **Pushover** — primary phone-push transport; creds in
  `notifications.pushover.*`.
- **ntfy.sh** — fallback phone-push transport; creds in
  `notifications.ntfy.topic_url_path`.
- **SMTP** — emergency-tier email transport; relay in
  `notifications.email.smtp_host:smtp_port`.
- **Runtime shell toolkit** — `gh` (GitHub CLI), `jq`, `git`,
  `tmux`, `uv`, `python3` (+`pyyaml`), `openssl`, `curl`, `bash`.

## Starting the monitor

### Canonical full-stack startup — `svc.sh up`

The normal way to bring the nexus up — at a fresh start or after a
machine / tmux restart — is the **full-stack** bring-up, which starts
the watcher, the orchestrator (first, pinned to its canonical window
slot), every registered infra service, and respawns the workers that
were in flight at the last snapshot:

```bash
monitor/svc.sh up                 # idempotent whole-stack bring-up
# equivalent (svc.sh up delegates to it):
monitor/bootstrap-recover.sh
```

Both are idempotent and safe to re-run: a healthy component is left
untouched. `svc.sh up` additionally execs the read-only `svc.sh`
cockpit afterward. The user-facing entry point
(`agent-sandbox tmux new-session ./watcher [--continue]` →
`watcher/entry.sh`) runs `svc.sh up` under the hood, so `./watcher`
is the same full-stack path plus the fresh-vs-resume session-pin
reconciliation (see the **Architecture** section). At a true cold
boot, `boot-recover.sh` fires `bootstrap-recover.sh` on its own (see
**Cold-boot recovery trigger**). Ordering, the orchestrator-first
window pin, the worker-inclusion predicate, and the flag matrix are
documented under `bootstrap-recover.sh` (item 2b above).

### Watcher-only startup (the rare case)

Starting **only** the watcher — without the orchestrator, services,
or worker respawn — is appropriate just for narrow situations: a
deliberately-minimal core where you'll drive the orchestrator by
hand, a debugging bounce, or recovering the watcher in isolation
after a watcher-only crash. The watcher's absent-target machinery
will still bring the orchestrator up as a backstop within a few
probe cycles, but services and workers stay down until a full-stack
`svc.sh up`.

```bash
monitor/watcher/launcher.sh                  # watcher only
# or, to ALSO place the orchestrator directly but skip services+workers:
monitor/bootstrap-recover.sh --watcher-only  # watcher + orchestrator (core)
```

The launcher runs `watcher/main.sh` HEADLESS — `setsid`-detached, no
tmux window — appending stdout/stderr to
`monitor/.state/watcher.log` (tail it via `svc.sh logs watcher` or
cockpit key `0`). To stop the watcher: `monitor/svc.sh stop
watcher`.

### Watcher restart

**THE restart command (use this):**

```bash
monitor/svc.sh restart watcher
```

It is **idempotent** and **safe to run repeatedly** — including when
the watcher is already down. It reaps the ENTIRE old watcher process
group (the watcher is a `setsid` session leader, so a group kill takes
`main.sh` AND any children/orphans — no overlapping process trees the
old root-only kill could leave), spawns exactly ONE replacement, waits
for a live heartbeat, and **fails loud** if it ends with zero live
watchers. Operators should NOT hand-roll the old `launcher.sh --replace`
dance; this verb is the supported surface. It is also exactly what
`monitor/revive-watcher.sh` (the orchestrator's crash-revive path) calls.

Under the hood every restart path — this verb, the orchestrator's
crash-revive (`revive-watcher.sh`), the version-drift self-restart, and
`bootstrap-recover` — runs
`launcher.sh`, which holds a **single-flight flock**
(`monitor/.state/watcher-restart.lock`) over the whole kill+spawn+verify
window. Concurrent restart attempts therefore SERIALIZE and converge to
exactly one live watcher instead of racing (one launcher SIGKILLing
another's fresh spawn — the "overlapping trees" failure). The
state-dir-scoped **instance flock** `main.sh` holds for its lifetime
(`nexus-instance.lock`, crossing pid-namespaces + hosts) is the ultimate
uniqueness backstop: at most one `main.sh` can hold it.

`launcher.sh` flags (rarely run by hand now):
`--replace` (forced kill+spawn, group-reaping), `--ensure` (idempotent
spawn-if-dead — a live watcher → exit 0; used by the crash-revive +
recovery), bare (cold first spawn, refuses over a live watcher). A
leftover legacy `watcher` tmux window from the pre-headless era is swept
automatically; `--window`/`--force` are accepted but ignored.

### Watcher supervision — the MUTUAL-LIVENESS contract

The watcher is the nexus's only always-on loop (it supervises the
orchestrator AND the registered services). Nothing used to
continuously supervise the WATCHER itself: it self-restarts only on
version drift (a dead watcher can't restart its own crash), the
orchestrator revives it only on its turn cadence (`bootstrap.sh`), and
`boot-recover.sh` only at a cold boot. So a watcher that hard-crashed
while the orchestrator was idle entered a **self-perpetuating dead
state** — dead watcher → nothing pastes to the orchestrator →
orchestrator stays idle → never re-runs `bootstrap.sh` → watcher stays
dead. And inside the agent-sandbox there is no OS supervisor to fall
back on (no cron spool, no systemd user bus — see "Cold-boot recovery
trigger").

The fix needs an always-on loop *outside* the watcher. Rather than a new
process, it reuses the one already there: **the orchestrator's own agent
loop.** The watcher already revives the orchestrator (orchestrator-
liveness); the orchestrator now revives the watcher — closing the
circularity by **mutuality**, not a third daemon.

**The contract (both directions):**
- **watcher → orchestrator:** the existing orchestrator-liveness state
  machine respawns a wedged/dead orchestrator. PLUS the watcher emits a
  top-pinned **`--- arm watcher supervisor ---`** reminder whenever it
  does not see a fresh *supervisor heartbeat* (the orchestrator's Monitor
  isn't armed) — nudging a freshly-(re)started orchestrator to (re)arm.
- **orchestrator → watcher:** the orchestrator arms a persistent
  **`Monitor`** whose until-loop runs `monitor/watcher-supervise-tick.sh`
  every ~15 s. Each tick **touches the supervisor heartbeat**
  (`monitor/.state/watcher-supervisor-heartbeat` — that is what clears
  the reminder) and reports watcher liveness via exit code. When the
  watcher dies the loop exits, waking the orchestrator, which runs
  **`monitor/revive-watcher.sh`** (crash-loop-guarded; writes the
  `watcher-revived` self-report marker; reuses `svc.sh restart watcher`)
  and re-arms the Monitor. The exact arming recipe lives in
  `skills/nexus.service-recovery`:

  ```
  Monitor({command: 'until ! <NEXUS_ROOT>/monitor/watcher-supervise-tick.sh; do sleep 15; done'})
  # on exit (watcher down):  <NEXUS_ROOT>/monitor/revive-watcher.sh   then re-arm
  ```

**Residual both-down-at-once** (a true reboot kills watcher AND
orchestrator) falls to the existing cold-boot path: `boot-recover.sh` at
SessionStart runs `bootstrap-recover.sh`, which brings the watcher +
orchestrator back; the orchestrator then re-arms the Monitor (nudged by
the reminder if it forgets).

The cockpit shows a pinned **`watcher-sup`** core row reading
**ARMED**/**UNARMED** from the supervisor-heartbeat freshness. An
intentional `svc.sh stop watcher` writes a `watcher-stop-requested`
sentinel that `revive-watcher.sh` honours (it won't fight a deliberate
stop); `start`/`restart watcher` clear it. Config under
`monitor.watcher_supervisor.*` (`enabled` gates the reminder;
`heartbeat_stale_seconds` is the arm-detection threshold).

**Pull before restart.** When the restart is meant to pick up new
code, `git pull` FIRST: `main.sh` sources sibling module files
(`_config.sh`, `_emit_filters.sh`, `_hosting_migration.sh`, ...) at
startup, so restarting onto a tree where those don't yet exist on
disk fails quietly. Operators coming from the windowed-watcher era:
pull + restart converges the hosting automatically (the launcher
sweeps the legacy window; a watcher that still comes up
window-hosted surfaces a one-shot migration notice to the
orchestrator). Full guide: `docs/operating/upgrading.md`.

### Version-aware auto-restart (`git pull` is the update story)

A running watcher detects when a `git pull` changed the code any
component loaded at start and triggers the right restart on its own
(<your-org>/<your-nexus>#186; `monitor/watcher/_version_restart.sh`).
Per-component **source-set hashes** — not a coarse HEAD SHA — so a
component restarts only when *its* files changed:

| component | source set | running version recorded | on confirmed drift |
|---|---|---|---|
| watcher | `main.sh` + every module it `source`s (parsed from the on-disk `main.sh`) | by `main.sh` at startup (`.state/version/watcher.running`) | detached `launcher.sh --replace` self-restart |
| services cockpit | `svc.sh` + `bootstrap-recover.sh` + `watcher/_lib.sh` + `watcher/_version_restart.sh` | adopted at first observation | **ask** the orchestrator via an emit section — the TUI window is orchestrator-owned; the watcher never kills it |
| registered services | the registry row's launch script | by `_recover_launch_service` at launch (`.state/version/service-<name>.running`) | `svc.sh restart <name>` (only while a live supervisor runs the old code) |

Guard stack (all knobs in `_config.sh`, `monitor.version_restart.*`):
a changed hash must hold **stable for `settle_seconds`** (default 45;
tolerates mid-pull torn state — a source set with a missing file is
`torn` and never acted on), actions are **cooldown-gated per
component** (default 600 s), watcher self-restarts are additionally
**loop-guarded** (default 3 per hour; past that the guard trips, auto
self-restart suspends, and an advisory emit asks for manual
intervention). Disabled channels (`monitor.version_restart.self` /
`.services` = false) degrade a confirmed drift to an emit advisory —
never silent. Master switch `monitor.version_restart.enabled`
(default **true**); set it false (or `interval_seconds: 0`) to restore
the fully manual discipline above.

**Bootstrap caveat:** only a version-aware watcher can auto-restart
anything, so the *first* deploy of this feature is itself still the
manual pull-then-restart.

**PID-identity check (post-restart deadlock fix, 2026-06-07).** The
"is the recorded pid alive?" test in `launcher.sh`,
`main.sh`'s `acquire_lock`, and `_watcher_alive` is not a bare
`kill -0` — it is `_watcher_pid_is_live_watcher`, which also
validates that the pid's argv is actually a `monitor/watcher/main.sh`
invocation. Rationale: after a machine/container restart the PID
namespace resets and the recorded low pid (the recurring `pid=13`
in `watcher.log`) gets recycled to an unrelated process; a bare
`kill -0` then succeeds and the watcher refuses to start, deadlocking
recovery. Validating the identity lets a recycled-pid stale
lock/pidfile be treated as dead so recovery proceeds — while still
ignoring a worker `claude` whose prompt merely quotes the watcher
path (the #57/#96 false-positive class), because the match looks
only at the program slot (argv[0]/argv[1]).

## Cold-boot recovery trigger

`bootstrap-recover.sh` makes recovery idempotent; `boot-recover.sh`
makes it *fire on its own at a cold boot*. The two earlier triggers
(the orchestrator running recovery on wake, and `bootstrap.sh`'s
watcher-respawn path) both presuppose the orchestrator is already
alive and taking turns — so on a true sandbox/machine reboot, until
something first revives the orchestrator, nothing re-establishes the
watcher, the registered infra services, or the worker agents that
were active in the last snapshot. `boot-recover.sh` is the
missing automatic fire: debounced, non-blocking, safe to call from a
boot/login context.

**What the agent-sandbox does and does not allow.** The sandbox
mounts `$HOME` as an ephemeral tmpfs overlay and bind-mounts the real
`~/.zprofile` / `~/.zshrc` / `~/.profile` **read-only**, so a
login-shell hook cannot be persisted from *inside* the sandbox.
`systemctl --user` has no session bus and `cron` has no spool here, so
neither a user systemd unit nor an `@reboot` crontab is available
either. The only persistent, sandbox-writable surfaces are the
project repo and `$CLAUDE_CONFIG_DIR` (`~/.claude/…`).

**Primary trigger — SessionStart hook (in-sandbox-deliverable).** A
Claude Code `SessionStart` hook with matcher `resume` fires the
instant the chaperon brings the orchestrator back via `claude
--resume` / `--continue` — the one component that reliably returns at
boot. It lives in the orchestrator's `settings.json` under
`$CLAUDE_CONFIG_DIR` (persistent + sandbox-writable). Merge the
ready-made snippet into that file (splice into any existing `hooks`
object; substitute your `NEXUS_ROOT`):

```bash
# snippet: monitor/boot-recover.session-start-hook.json
# command: "<NEXUS_ROOT>/monitor/boot-recover.sh", "async": true
```

This converts the previously *manual* "orchestrator runs recovery on
wake" step into an automatic one.

**Belt-and-suspenders — true cold-boot hook (OUTSIDE the sandbox).**
A trigger that fires with zero dependence on the orchestrator
resuming must be installed where the sandbox cannot reach from
within. Pick one, edited from outside the sandbox:

- Real login shell — append to your actual `~/.zprofile` (or
  `~/.bash_profile`):

  ```sh
  # nexus cold-boot recovery (idempotent, debounced, non-blocking)
  [ -x $NEXUS_ROOT/monitor/boot-recover.sh ] && \
      $NEXUS_ROOT/monitor/boot-recover.sh >/dev/null 2>&1 || true
  ```

- Or a `sandbox.conf` on-start entry that runs the same one-liner when
  the sandbox launches.

Both are honest about the boundary: the script is in-repo and does the
work; the *hook that calls it at reboot* is the operator's to install
outside the writable area. `boot-recover.sh` is idempotent and
debounced, so wiring more than one trigger is safe — they collapse to
a single recovery attempt via the `.state/boot-recover.stamp` window.

## Manual watcher use (debugging)

```bash
cd "$(config/load.sh nexus.root)"/monitor
./watcher/main.sh --once                  # run one poll cycle and exit
MONITOR_INTERVAL=10 ./watcher/main.sh     # snappier polling (attended foreground)
./watcher/launcher.sh --target orchestrator     # spawn the usual headless watcher
```

The latest emit body is cached at `monitor/.state/last-change.txt`
and archived under `monitor/.state/diffs/<ts>_<shortid>.md`.

## Service cockpit + service CLI (`svc.sh`)

The single stable user-facing surface for the nexus stack: a
**read-only dashboard** (default) plus **explicit verbs** that act.
The command surface is meant to stay put while the machinery behind
it (bootstrap, recovery, watcher hosting) keeps evolving.

**Dashboard** — one screen shows the whole stack over the same
`services.registry` that drives recovery: the core pinned on top
(`watcher`, with its real tri-state liveness `UP`/`STALE`/`DOWN`
from `_watcher_alive` + heartbeat age; `orchestrator`, window
presence + turn-end heartbeat age, supervised by the watcher), then
every registered service with live `UP`/`DOWN` (its healthcheck), a
`SUPERVISOR` column reading the headless pidfile (`pid:N` alive /
`stale` / `-`), and a final untruncated `DETAIL` column: for an UP
labsh JupyterLab service the full tokened, directly-openable URL
(`http://<fqdn>:<port>/lab?token=…` — internal lab cockpit, so the
token is shown deliberately; missing token degrades to the bare URL),
else the healthcheck-derived endpoint-or-PID.
It repaints **in place** (no clear-screen flicker, on the alternate
screen so refreshes never pollute scrollback) and reacts to
single keypresses: `1`-`9` tails that service's log, `0` the
watcher's (`monitor/.state/watcher.log`), `x` closes the log view,
`n`/`p` page when the table overflows, `r`
refreshes, `q` quits. Inside tmux the log opens in ONE dedicated
split pane — reused on each pick, retitled `log:<name>`, and the
cockpit **keeps focus** — so scrollback comes free via copy-mode
(`prefix + [`); outside tmux it falls back to an inline `tail -F`
(Ctrl-C returns). The dashboard never launches, restarts, or kills
anything.

Rendering is **height-aware**: the frame is budgeted against the
live pane height (probed every refresh, so terminal resizes and the
log split are tracked), and when the registry outgrows the pane the
core rows and **every unhealthy service stay visible on every page**
— only healthy rows page via `n`/`p`, and an explicit
`+N more UP — page X/Y` line counts what is off-screen (red, with
the unhealthy count, in the degenerate case where unhealthy rows
alone overflow the pane). A problem can never scroll away silently.
The non-TTY `status` verb is never budgeted or paginated — scripts
and agents always get the full table.

**Verbs** — explicit, scriptable, delegating to the recovery
primitives (same decision paths, no second implementation):

```bash
tmux new-window -n services 'monitor/svc.sh'   # the dashboard
monitor/svc.sh status            # one-shot table, scriptable
monitor/svc.sh up                # idempotent whole-stack bring-up
monitor/svc.sh up --no-services  # nexus core only: watcher (+ its
                                 #   orchestrator); skip every service
                                 #   AND every worker respawn
monitor/svc.sh up --no-workers   # watcher + services; skip only the
                                 #   worker respawn
monitor/svc.sh start  <name>     # start iff not running ('watcher' ok)
monitor/svc.sh stop   <name>     # TERM the supervisor's process group
monitor/svc.sh restart <name>    # restart watcher == launcher.sh --replace
monitor/svc.sh logs   <name>     # tail -F the service's log(s)
```

`up` delegates to `bootstrap-recover.sh` (watcher + services +
last-snapshot workers) and
deliberately does NOT spawn the orchestrator: the watcher's
liveness machinery does the initial spawn and every revival
(`spawn-fresh-orchestrator.sh`), so there is exactly one
orchestrator-spawn path. `up --no-services` brings up the nexus
core alone — the watcher, which then revives its orchestrator —
and skips every registered service ("they ARE the nexus") and
every worker respawn; `up --no-workers` skips only the worker
respawn; `--services-only` skips just the watcher, and combining
it with `--no-services` is rejected with exit 1. For the same reason `start/stop
orchestrator` refuse and point at the watcher. `stop` kills the
supervisor's process group (setsid made it a session leader) and
flags loudly if the healthcheck still passes afterwards — a
daemonizing child can escape the group and needs its own shutdown.

`svc.sh` is **sandbox-agnostic**: it never wraps itself in
`agent-sandbox`. Pick the context explicitly — `agent-sandbox
monitor/svc.sh up` or bare `monitor/svc.sh up`.

The status auto-refreshes every `SVC_REFRESH` seconds (default 5).
`NEXUS_ROOT` selects the live tree the registry + logs + state are
read from (default the primary nexus root), so the cockpit can run
from a dev clone and still observe the running services. Note the
orchestrator row's `UP`/`DOWN` reads tmux window presence, so it is
scoped to the tmux server you run the cockpit in.

Log mapping uses the registry's optional 5th `<logfile>` column
(see `services.registry.example`); rows without it fall back to
`<workdir>/serve.log`. That same column is where `bootstrap-recover.sh`
appends a headless launch's output, so the cockpit tails exactly what
recovery writes. 4-field rows stay valid for both. For labsh
JupyterLab services, `logs` (and the cockpit log split) additionally
tails the server's own stdout, `<workdir>/.jupyter/labsh.bg.log` —
the file that prints the access URL on startup.

Tests: `bash monitor/watcher/test-svc.sh`.

## JupyterLab as a service (`jupyter-up.sh`)

Any project can run its [labsh](https://github.com/katosh/labsh)
JupyterLab as a registry-managed service that survives crashes and
reboots. One command activates everything (idempotent, safe to
re-run):

```bash
monitor/jupyter-up.sh --root                    # ROOT session: one server, all project kernels
monitor/jupyter-up.sh /path/to/project          # per-project: activate + print URL
monitor/jupyter-up.sh /path/to/project --status # one-line status
monitor/jupyter-up.sh /path/to/project --down   # deactivate (stop + deregister)
```

**Root mode (`--root`).** ONE JupyterLab rooted at the work root
(`$NEXUS_ROOT/work`) as the single service `jupyterlab`, with
every project venv registered as kernelspec `proj-<project>` by
`monitor/jupyter-kernel-crawl.sh` — a shallow `work/*/` sweep (no
recursive find over NFS), fired async at activation and re-run by the
supervisor's periodic hook (`.jupyter/labsh-service.periodic`, every
`LABSH_SVC_PERIODIC_EVERY` probe intervals, default ~10 min) or on
demand. Idempotent (already-registered specs are skipped by
interpreter identity); a stale `proj-*` spec whose interpreter is gone
is pruned; a sanitized-name collision is refused, never clobbered.
Idle kernelspecs are free — kernels spawn on attach. This is the
default for an unqualified "give me a jupyter session"; per-project
mode below remains for isolation, and both coexist. Project agents
inside `work/<project>` reach the root server through
`monitor/labsh-root.sh` (exports `JUPYTER_CONFIG_DIR`/
`JUPYTER_DATA_DIR` at the work root, execs labsh):
`labsh-root.sh notebook attach nb.ipynb --kernel-name proj-<project>`,
then `labsh-root.sh kernel exec -n nb.ipynb 'CODE'`.

**Lifecycle.** Activation ensures a project kernel (`labsh kernel
add`, reusing an existing `./.venv`), writes a `jupyter-<project>`
row into `services.registry`, and launches
`monitor/labsh-supervised.sh` through `recover_service` — the same
idempotent decision path recovery uses, so an already-healthy or
already-supervised service is never double-launched. From then on
the service is a first-class registry citizen: `bootstrap-recover.sh`
revives a dead supervisor on boot, and `svc.sh` shows/manages it
(`status` / `logs` / `restart jupyter-<name>`). The supervisor is a
watchdog (not a restart-loop parent — `labsh start` daemonizes its
own payload): it probes `monitor/jupyter-health.sh` every
`LABSH_SVC_INTERVAL` s (15) and bounces the server after
`LABSH_SVC_FAILS` (3) consecutive failures; on TERM it runs `labsh
stop` so `svc.sh stop` shuts the server down with the supervisor. A
server the human already started by hand is **adopted**, not
duplicated (`labsh start` refuses while one is live).

**Ports.** First start picks a deterministic per-project port in
9700–9949 (path-hash spread); labsh auto-increments past taken
ports, and the supervisor persists the ACTUAL port/scheme to
`<project>/.jupyter/labsh-service.env` after every start, so the
healthcheck always probes where the server really listens. Pin with
`--port N`; persist `--ip 127.0.0.1` / `--https` (replayed on every
restart) via the same flags.

**Kernel registration.** Default: `labsh kernel add` (creates
`./.venv` if absent, reuses it otherwise; extra packages via
`--pkgs "scanpy ..."`). Existing/Lmod venv living elsewhere:
`--venv DIR` → `labsh kernel register --project DIR` (bakes
`LD_LIBRARY_PATH` into `kernel.json`). Kernelspecs are project-local
(`<project>/.jupyter/share/jupyter/kernels/`), so any number of
projects coexist without collisions.

**Healthcheck.** `jupyter-health.sh` curls `/api/status` with the
project's current token (`.jupyter/token`) — a squatter on the port
or a login page does not pass. Token rotation (`labsh token
--rotate`) therefore self-heals: the probe fails, the supervisor
bounces the server, the new token applies (running kernels are lost,
as with any server restart).

**Troubleshooting.** `svc.sh logs <name>` tails the supervisor log
(`.jupyter/labsh-service.log`) AND jupyter's own stdout
(`.jupyter/labsh.bg.log`) together; the cockpit `DETAIL` column shows
the tokened access URL while the service is UP.
Agent-facing usage and the foolproof default behavior:
`skills/nexus.jupyter/SKILL.md`; labsh primitives: the `<yourlab>.labsh`
skill and `work/labsh/doc/labsh.md`.

Tests: `bash monitor/watcher/test-jupyter-service.sh` (unit, stubbed
labsh) and `RUN_INTEGRATION=1 bash
monitor/watcher/test-integration/test-jupyter-service-real.sh`
(real servers in throwaway `/tmp` projects).

## Files

| Path                         | Purpose                                | Tracked? |
|------------------------------|----------------------------------------|----------|
| `watcher/main.sh`            | Continuous watcher loop (headless, `setsid`-detached) — snapshot, paste-to-target, archive, heartbeat, prune | yes |
| `watcher/launcher.sh`        | Launches `main.sh` headless (`setsid`, no window, output to `monitor/.state/watcher.log`), verifies the self-published pidfile, sweeps a leftover legacy `watcher` window; `--replace` bounces a live watcher | yes |
| `watcher/bootstrap.sh`       | Agent-side on-wake check: heartbeat liveness, incident-report on staleness, full-stack service recovery on respawn, diff catch-up, ack advance | yes |
| `bootstrap-recover.sh`       | Idempotent full-stack recovery after a restart: relaunches the watcher if unhealthy + each registered infra service that is unhealthy with no live supervisor. Services run HEADLESS (`setsid`-detached, no window); idempotency keyed off a per-service pidfile (`$NEXUS_STATE_DIR/services/<name>.pid`, alive + cmdline-matched), with a legacy tmux window honoured as a second leave-it-alone signal. Driven by `services.registry`. `--dry-run` / `--list` / `--services-only` / `--no-services` (= `--watcher-only`: core only, skip all services; combining it with `--services-only` is rejected). | yes |
| `svc.sh`                     | The stable user-facing stack surface: flicker-free read-only dashboard (core `watcher` + `orchestrator` rows pinned over the registry services; single-key log tailing into one reused, focus-preserving tmux split) PLUS explicit verbs — `status` / `up` (idempotent whole-stack bring-up via `bootstrap-recover.sh`; the watcher then spawns/revives the orchestrator) / `start` / `stop` (process-group TERM) / `restart` / `logs`. Reuses recovery's primitives; sandbox-agnostic (prefix `agent-sandbox` explicitly). Tests: `watcher/test-svc.sh` | yes |
| `services.registry.example`  | Annotated template for the operator-local `services.registry` (gitignored): one TAB-separated `name⇥workdir⇥launch-cmd⇥healthcheck` line (plus an optional 5th `⇥logfile` for the `svc.sh` cockpit) per infra service that `bootstrap-recover.sh` should bring back. Also the source of truth for which windows the idle-sweep exempts as infra (not dead workers) | yes |
| `jupyter-up.sh`              | One-command activation of a labsh JupyterLab as a registry-managed service. Per-project: ensures kernel (`labsh kernel add` / `--venv` register), maintains the `jupyter-<project>` row. `--root`: the single work-root session `jupyterlab` with all project kernels via the crawl. Launches via `recover_service`, waits healthy, prints URL + agent quickstart. `--down` deactivates (stop + deregister), `--status` one-liner. See "JupyterLab as a service" above + `skills/nexus.jupyter/SKILL.md` | yes |
| `jupyter-kernel-crawl.sh`    | Shallow `work/*/` sweep for the root session: registers each project venv as kernelspec `proj-<dir>` (`labsh kernel register`), prunes `proj-*` specs whose interpreter is gone, refuses name collisions. Idempotent, flock-guarded, per-project failures never abort the sweep | yes |
| `labsh-root.sh`              | Project-agent door into the root session: exports `JUPYTER_CONFIG_DIR`/`JUPYTER_DATA_DIR` at the work root and execs labsh, so attach/exec/url work from inside any `work/<project>` | yes |
| `labsh-supervised.sh`        | Foreground watchdog a `jupyter-*` registry row launches: probes `jupyter-health.sh` every `LABSH_SVC_INTERVAL` s, bounces the labsh server after `LABSH_SVC_FAILS` consecutive failures, persists actual port/scheme to `.jupyter/labsh-service.env`, adopts hand-started servers, runs the optional `.jupyter/labsh-service.periodic` hook async every `LABSH_SVC_PERIODIC_EVERY` intervals, TERM → `labsh stop`. Tests: `watcher/test-jupyter-service.sh` | yes |
| `jupyter-health.sh`          | Authenticated healthcheck for a project's JupyterLab: curls `/api/status` with the project's `.jupyter/token` at the port recorded in `.jupyter/labsh-service.env`. Registry healthcheck AND the watchdog's probe — one implementation | yes |
| `boot-recover.sh`            | Cold-boot trigger for `bootstrap-recover.sh`: idempotent, debounced, non-blocking guard meant to fire from a SessionStart hook / login shell at reboot. `--force` skips the debounce; `--sync` runs in foreground | yes |
| `boot-recover.session-start-hook.json` | Ready-to-merge Claude Code `SessionStart` (matcher `resume`) hook snippet that fires `boot-recover.sh` when the orchestrator session is brought back at boot | yes |
| `watcher/_lib.sh`            | Shared watcher helpers: heartbeat/lock parsers, liveness probe (`_watcher_alive`), PID-identity check (`_watcher_pid_is_live_watcher`, immunises lock/pid checks against post-restart PID reuse), emit classifier (`_classify_diff`) | yes |
| `watcher/_github.sh`         | `snapshot_github` + helpers — three-source union (issues, PR conversation, PR review threads); honours `processed-comments.txt` dedup | yes |
| `watcher/_unstick.sh`        | Auto-unstick library: case A (permission Enter) + case B (rate-limit cascade + Anthropic API probe + orchestrator ack) + case C (api-error chip Enter) + case D (AskUserQuestion chip-bar Escape + meta-paste, the orchestrator-paste safety net — see `monitor.watcher.on_dialog`) + case W (worker-blocked-question relay: non-target AskUQ overlay → grace → synthesized `blocked_question` pending-decision; never touches the pane — see `monitor.watcher.worker_askuq_grace_seconds`) | yes |
| `watcher/_orchestrator_liveness.sh` | Orchestrator-liveness state machine (issue #164). Hook-driven heartbeat compared against last-paste timestamp; sequences grace + unstick-window + dead-threshold budgets before escalating to fresh-spawn. Replaces the #157 binary `unresponsive_age > threshold` check. | yes |
| `watcher/_config.sh`         | Watcher config resolution — the env → config → default lookup block for every knob (extracted from `main.sh`, issue 180 seam S1). NOT side-effect-free: sourcing runs the ~50 `config/load.sh` lookups; `main.sh` sources it once, after the early pidfile publish | yes |
| `watcher/_emit_filters.sh`   | Emit-stream filters composing the bulk of `_gh_filter_dedup_pipeline`: manual suppression (`ng suppress-emit`), processed-comments live re-check, per-comment emit cooldown, cross-source id dedup (extracted from `main.sh`, issue 180 seam S2) | yes |
| `watcher/_emit_dedup.sh`     | Content-hash emit-dedup gate: stable-hash, operator-attention bypass, and the decide/record pair around `paste_with_retry` (extracted from `main.sh`, issue 180 seam S3) | yes |
| `watcher/_respawn_prompts.sh` | Turn-1 recovery-prompt bodies `respawn_agent` pastes into a respawned orchestrator (resume / fresh flavours, issue #200), as render functions (extracted from `main.sh`, issue 180 seam S4) | yes |
| `watcher/_hosting_migration.sh` | Legacy-hosting detection (`WATCHER_WINDOW != headless`, the launcher's headless marker) + the one-shot `--- watcher hosting migration ---` notice body the startup sweep emits (issue 182). Watcher keeps operating normally either way | yes |
| `watcher/_version_restart.sh` | Version-aware component auto-restart (issue #186): per-component source-set hashing, the adopt→pending→drift stability state machine (torn-pull safe), per-component cooldowns, the watcher self-restart loop guard, restart orchestration (self via detached `launcher.sh --replace`, services via `svc.sh restart`, cockpit via an emit ask), and the `--- component drift ---` emit section. Also sourced by `bootstrap-recover.sh` for the launch-time version stamp. | yes |
| `watcher/test-version-restart.sh` | Unit tests for `_version_restart.sh`: hashing/source-set/torn detection, the drift state machine, per-component isolation, cooldown + loop guard, advise-fallback channels, service restart-once via a stubbed `svc.sh`, emit-section re-nag guard (run: `bash monitor/watcher/test-version-restart.sh`) | yes |
| `watcher/test-version-restart-self.sh` | Integration test: a confirmed watcher self-drift drives the REAL `launcher.sh --replace` against a fixture watcher — old pid dies, exactly one successor publishes the pidfile, cooldown blocks an immediate second trigger (run: `bash monitor/watcher/test-version-restart-self.sh`) | yes |
| `watcher/test-lib.sh`        | Mock-tmux unit tests for the standalone classifiers in `_lib.sh` (e.g. `_target_window_present`) (run: `bash monitor/watcher/test-lib.sh`) | yes |
| `watcher/test-unstick.sh`    | Mock-tmux unit tests for `_unstick.sh` (run: `bash monitor/watcher/test-unstick.sh`) | yes |
| `watcher/test-snapshot-github.sh` | Mock-gh unit tests for `_github.sh` (run: `bash monitor/watcher/test-snapshot-github.sh`) | yes |
| `watcher/test-snapshot-github-failure.sh` | Mock-gh unit tests for the detect-and-react path in `_github.sh` (rate-limit sentinel, backoff, expiry) (run: `bash monitor/watcher/test-snapshot-github-failure.sh`) | yes |
| `watcher/test-deliveries-race.sh` | Mock-curl unit tests for the deliveries durable queue (`_append_to_deliveries_queue` / `_drain_deliveries_queue` in `_deliveries.sh`). Covers the multi-tick overwrite race, cumulative-emit semantics, drain idempotency, and the drain-then-new-event interleaving (run: `bash monitor/watcher/test-deliveries-race.sh`) | yes |
| `watcher/test-cc-version.sh` | Unit tests for the effective-version resolver `_cc-version.sh` (floor-plus-local-pin, #226): floor extraction, local-pin path resolution / trim / blank-handling, `effective = local-pin else floor`, atomic write round-trip, and gate-baseline wiring (the gate fires against the effective version, not the lagging floor) (run: `bash monitor/watcher/test-cc-version.sh`) | yes |
| `_cc-version.sh`             | Shared resolver for the EFFECTIVE Claude Code version (floor-plus-local-pin, #226). `effective = local-pin (monitor/.state/cc-version-local) else package.json floor`. Read by `install-claude-local.sh` (install + verify) and the watcher gate baseline (`_v2_task_cc_version_check`). Atomic local-pin write. | yes |
| `install-claude-local.sh`    | Installs the project-local Claude Code into `node_modules/.bin/claude` at the EFFECTIVE version (local pin if present — installed via `npm install --no-save <pkg>@<ver>` so the shared floor is untouched — else the package.json floor via bare `npm install`). Idempotent; fail-loud verify that the binary runs and reports the effective version. | yes |
| `paste-followup.sh`          | THE canonical follow-up paste into a worker window (issue #201): stamps `.state/machine-input.tsv` BEFORE pasting (so the watcher attributes the submitted prompt — the paste fires the worker's `UserPromptSubmit` hook — to the orchestrator, not the operator), performs the VI-safe `i BSpace` → `set-buffer` → `paste-buffer` → `Enter` sequence, appends a `paste-followup` action-log audit event. Raw `tmux paste-buffer` follow-ups falsely mark the window `operator-engaged` and mute its stall-nag — always use this helper. | yes |
| `mint-token.sh`              | Mints / caches the bot's installation token | yes |
| `git-https-setup`            | **Opt-in per-repo helper** (niche). Configures a single clone for bot-identity git commit + push via a fresh installation token on every challenge. Use only where the user's `gh auth setup-git` path isn't available (e.g. inside agent-sandbox with a read-only `~/.gitconfig`) — note that bot-authored commits make later attribution of work back to a human harder, which matters for projects intended to go public. Not auto-invoked. | yes |
| `ng`                         | Compact GitHub / watcher helper (`process`, `react`, `reply`, `close`, `dashboard get|put|scaffold|validate`, `nexus-identity`, `issue`, `upload`, `watcher-status`, `log-action`) | yes |
| `upload-asset.sh`            | Commits a local file (image or report markdown) into the asset repo's `main` branch under `assets/...`; prints a SHA-pinned `github.com/{owner}/{asset-repo}/{raw\|blob}/<sha>/...` URL that renders in any browser logged into github.com | yes |
| `notify.sh`                  | Tiered Pushover / ntfy / SMTP fan-out  | yes      |
| `agent-prompt.md`            | Launch prompt for the monitor agent    | yes      |
| `worker-settings.json`       | Per-spawn Claude Code settings passed to every worker via `claude --settings`. Carries `skipDangerousModePermissionPrompt: true` (suppresses the bypass-mode startup dialog) + the canonical hook block (heartbeat, decision-emit, decision-mark-unresolved, notifications JSONL, pending-tool capture). Edit this file to add/change worker hooks; no awk extraction. | yes |
| `hooks/decision-emit.sh`     | Notification-hook handler: reads the hook payload from stdin, writes one atomic JSON event per pending decision to `.state/decisions/<window>.<fp>.json`. Fingerprint stable across re-fires so the same prompt yields one file. Tool context (when present) is embedded from `.state/pending-tool/<window>.json`. Hot-path discipline: O(ms), exits 0 on any failure to never block the agent's turn. | yes |
| `hooks/decision-mark-unresolved.sh` | Stop-hook handler: per turn-end, walks `.state/decisions/<window>.*.json` and adds `unresolved: true` to lingering files (the orchestrator removed any answered ones). Idempotent; tombstones (`*.handled.json`) skipped. | yes |
| `README.md`                  | This file                              | yes      |
| `.state/diffs/`              | Archived watcher emits, `<ts>_<shortid>.md`, pruned at `monitor.diff_retention_days` | no |
| `.state/watcher-heartbeat`   | PID + ISO timestamp; mtime-bumped every poll cycle | no |
| `.state/orchestrator-heartbeat` | Empty file; mtime touched by the orchestrator's `Stop` hook in `monitor/orchestrator-settings.json` at every turn-end (issue #164). The `_orchestrator_liveness_decide` state machine compares this against `orchestrator-last-paste.ts` to decide whether the orchestrator has reacted to a paste. Missing file (settings predate the hook, fresh state dir) is benign — the state machine falls back to the paste-received signal, then jsonl-mtime. The touch runs asynchronously via `(... &) >/dev/null 2>&1` so the hook returns instantly. | no |
| `.state/orchestrator-paste-received` | Empty file; mtime touched by the orchestrator's `UserPromptSubmit` hook the moment its input queue picks up a watcher paste. Strictly weaker than the heartbeat (paste-received fires the moment the input lands; Stop fires at turn-end). Covers the mid-tool-turn case where the heartbeat is stale because Stop hasn't fired yet but the orchestrator is demonstrably processing the prompt. Same async touch pattern as the heartbeat. | no |
| `.state/orchestrator-unresponsive-since` | Empty file; mtime stamped by the liveness state machine on first entry into the pasted-without-response phase, cleared on any healthy decision. Anchors the `unstick_window_seconds` budget — detect_and_unstick has from this moment to bump the heartbeat before the watcher escalates to the re-submit rescue. | no |
| `.state/orchestrator-resubmit-attempted` | Empty file; mtime stamped by the liveness task when the one-shot re-submit rescue fires at unstick-window exhaustion. Its existence caps the rescue at one attempt per wedge episode; its mtime anchors the post-resubmit response window (one paste-response grace). Cleared on any healthy decision and on respawn. | no |
| `.state/version/`            | Version-aware restart state (issue #186): `<comp>.running` (the source-set hash each running component loaded at start), `<comp>.pending` (drift stability tracking), `<comp>.restart.last` (cooldown stamps), `self-restart-history.txt` + `self-restart-tripped` (watcher loop guard), `drift-<comp>` (+ `-surfaced`) ask records the emit surfaces once per candidate | no |
| `.state/watcher.lock`        | PID-based lock; prevents multiple watchers on the same state dir | no |
| `.state/watcher-target`      | Current target window (written by `main.sh` at startup) | no |
| `.state/watcher.log`         | Append-only watcher log (startup, emits, paste failures, respawns) | no |
| `.state/last-ack.txt`        | ISO timestamp of the newest diff the monitor agent has acknowledged | no |
| `.state/action-log.jsonl`    | Append-only JSONL action trace: `{ts,agent,event,...}` per meaningful action | no |
| `.state/last-snapshot.txt`   | Persistent snapshot baseline (carries across watcher restarts) | no |
| `.state/engagement-log.tsv`  | One row per worker window the watcher has ever observed in `busy` / `user-typing` state: `<window>\t<last-engagement-epoch>`. Consulted by `_idle_probe.sh` for both the idle-pool entry gate (`now - engagement_epoch` is the worker's idle age when a row exists; otherwise fall back to `now - #{window_activity}`) and the retain-consume gate (engagement past `retain.ts` consumes the retain). Replaces direct comparisons against `tmux #{window_activity}` in both places; see issue #111. Append-mostly; at-most-one row per window. | no |
| `.state/user-prompt/`        | Per-window "last user-prompt submitted" stamp `<window>` (`<epoch>\t<session-id>`), written by `worker-heartbeat.sh` from the worker's `UserPromptSubmit` hook. THE operator-engagement trigger (issues #196, #201): `_idle_probe.sh` attributes each new stamp to the operator or the orchestrator via the machine-input rule — no pane content involved. Pruned with the window by the per-cycle disappearance pruner. | no |
| `.state/watcher-unstick.log` | Auto-unstick action log (one line per detection / send-Enter / backoff / cascade / heads-up / ack) | no |
| `.state/unstick/`            | Per-window-per-case fingerprint + retry counters + pre-action pane captures (audit trail) AND case-B session state: `ratelimit.reset.epoch`, `ratelimit.cascade.epoch`, `ratelimit.last-wait.epoch` | no |
| `.state/decisions/`          | One file per pending decision: `<window>.<fp>.json` (issue #129). Written atomically by `hooks/decision-emit.sh` on every Notification. Each file carries `{ts, window, session_id, kind, prompt_excerpt, tool_context, fingerprint, unresolved?}`. The orchestrator removes the file once the prompt has been answered; `Stop` hook stamps `unresolved=true` on anything still present at turn-end. `*.handled.json` siblings are honoured as tombstones (audit copy after answering). | no |
| `.state/pending-tool/`       | Per-window single-file snapshot of the most-recent PreToolUse for sensitive tools (`Bash|Write|Edit|NotebookEdit`): `<window>.json` with `{tool, input_summary, ts}`. Overwritten on each new PreToolUse; cleared by PostToolUse. Read opportunistically by `hooks/decision-emit.sh` to embed `tool_context` in the decision file. | no |
| `.state/pending-decisions-emit-state.tsv` | Cooldown bookkeeping for `render_pending_decisions`. Rows: `<window>\t<fp>\t<last_emit_epoch>`. Re-emit gated by `DECISION_REEMIT_COOLDOWN_SECONDS` (default 300). Pruned each cycle to only rows whose decision file still exists. | no |
| `.state/worker-notifications.jsonl` | Shared append-only JSONL log of every Notification across all workers (`{event, notification, window, ts}`). Read by `render_idle_prelude` for the `N awaiting-input` counter. Rotated at `MONITOR_NOTIFICATIONS_LOG_MAX_BYTES`. The per-decision file under `.state/decisions/` is the actionable surface; this is the aggregate. | no |
| `.state/last-change.txt`     | Cache of the most recent emit body | no |
| `.state/last-emit-stable-hash` | sha256 hex of the last successfully-pasted emit body in its canonical (timestamp-stripped) form. Read by `_compose_emit_should_suppress` to decide whether the candidate emit duplicates the previous one; advanced by `_compose_emit_record_emit` on every successful paste. Atomic tmp+rename writes. Missing/empty ⇒ no anchor; next eligible emit pastes and seeds the file. | no |
| `.state/last-emit-stable-ts` | Epoch seconds of the last successfully-pasted emit. Paired with `last-emit-stable-hash`; suppression fires only when the hash matches AND `now - last-emit-stable-ts < monitor.emit_dedup_max_quiet_seconds`. | no |
| `.state/dashboard.md`        | Cache of the dashboard-middle content | no |
| `.state/dashboard-updated.ts`| ISO timestamp of the last successful `ng dashboard put` | no |
| `.state/processed-comments.txt` | Local cache of comment IDs already reacted on (propagation-lag guard) | no |
| `.state/watcher-alerts.log`  | Append-only `[iso] WARN <surface> <classification> ...` log written by `_watcher_handle_graphql_failure` (`graphql_rate_limit`, `graphql_failure`, `empty_stderr`) | no |
| `.state/graphql-backoff-<surface>` | Per-surface GraphQL rate-limit reset epoch; `_snapshot_<surface>` short-circuits while present + 30 s grace | no |
| `.state/graphql-alert-emitted-<surface>-<epoch>` | Flag file: `watcher_alert=rate-limit ...` sentinel already emitted for this (surface, reset) pair — one alert per exhaustion event, not per poll | no |
| `.state/deliveries-queue.lines` | Durable queue of deliveries-channel emit blocks. Each `_v2_task_deliveries_poll` fire (15 s cadence) appends new blocks under flock; `compose_emit` (`MONITOR_INTERVAL` cadence, default 60 s) drains via rename + read + rm. Decouples the producer's 15 s ticks from the consumer's drain reads so a delivery emitted at tick T is not wiped by the empty tick T+1 — pre-fix, the scheduler's atomic-replace of `<stage>/deliveries_poll.out` overwrote the previous tick's output, losing three of every four ticks' events to the 600 s GraphQL backstop. Mtime advances on every append; `_compose_emit_nudge_check` reads it to pull compose_emit forward (see "Compose-emit nudge" below). | no |
| `.state/deliveries-queue.lock` | flock target serializing appenders against the drainer of `.state/deliveries-queue.lines`. Append/drain hold an exclusive lock; the rename-then-read drain ensures concurrent appenders write to a fresh file after rename. | no |
| `.state/cc-version-local`    | The **operator-local Claude Code pin** (floor-plus-local-pin, #226): a single line holding the version this operator has validated via the gated cc-update routine. Written by the cc-update APPLY step; read by `_cc-version.sh` (`effective = this else package.json floor`). Absent on a fresh install ⇒ the install + gate baseline fall back to the package.json floor. Gitignored (`monitor/.gitignore` `.state/`); never committed. | no |

### Compose-emit nudge (deliveries-queue + github_poll → fast drain)

`compose_emit`'s base cadence is `MONITOR_INTERVAL` (default 60 s) so
the steady-state idle-floor stays predictable, but a comment that lands
right after a compose_emit fire would otherwise sit in
`deliveries-queue.lines` for the full inter-fire window before being
drained and pasted. Pre-nudge observed worst-case end-to-end latency
(comment-creation → orchestrator paste) was 52 s on
`<your-org>/<your-nexus>` issue `#1` comment 4559632841 (2026-05-27).

The fix lives in `monitor/watcher/_compose_nudge.sh`. Once per
scheduler tick (called from `_scheduler_post_tick_hook` in `main.sh`)
the helper compares the current mtimes of

  * `.state/deliveries-queue.lines` (append by `snapshot_deliveries`)
  * `<stage>/github_poll.out` (atomic-replace by `snapshot_github`)

against the last-seen mtimes held in module-scoped integer variables.
When either mtime advances **and** the file has bytes, the helper calls

```bash
_schedule_fire_now compose_emit          # next_fire ← 0
_schedule_override compose_emit 5 60     # 5 s cadence for 60 s
```

— the same primitive pair `_v2_task_target_window_probe` uses on rc=2
(target-absent respawn), so the scheduler test suite §8d behaviour
carries over to this trigger.

Properties:

* **Additive.** Base `MONITOR_INTERVAL`, the 600 s `github_poll`
  backstop, and `MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS` are all
  untouched. The hook only adds a demand-driven re-fire when new events
  arrive.
* **Size-guarded.** `github_poll.out` is atomically replaced every fire
  even on empty output; the `size > 0` check prevents a 600 s
  backstop tick with nothing to surface from re-nudging compose_emit.
* **Idempotent.** Module state tracks the last-seen mtime so successive
  ticks with no new bytes are no-ops; consecutive nudges within the
  60 s override window simply advance the override TIL (latest wins,
  no leak).
* **Restart-safe.** Module state resets on watcher restart; a
  pre-existing non-empty queue or staging file nudges once on the
  first post-startup tick, surfacing any unprocessed work immediately.

### Content-hash dedup gate

The emit-decision tree above filters down to "this is signal" before
`compose_emit` ever renders a body, but on a truly quiet workspace the
narrow `poll-full-state` body can repeat verbatim every cadence tick
— in one audited overnight stretch the orchestrator was woken three
times (02:12, 06:15, 10:22) by identical
`0 busy | 0 idle | 0 retained | 0 awaiting-input | dashboard stale | no eligible comments`
emits. Zero new information, three orchestrator turns burned.

The content-hash dedup gate (`_compose_emit_should_suppress` +
`_compose_emit_record_emit` in `monitor/watcher/main.sh`) closes
this. It runs after `compose_report > "$emit_body"` and before
`paste_with_retry`:

```
hash(body) where body has its timestamp components stripped:
  - leading `=== nexus state changed at <iso> (<reason>) ===` →
      collapses to `=== state (<reason>) ===` (reason kept; it's content)
  - dashboard `last updated: <ts>` line dropped
  - per-window `idle Ns` ages collapse to `idle`
      (mirrors the canonical-form strip the full-state gate uses)
  - trailing `--- nexus-emit-sig <iso> <nonce> ---` footer dropped
```

The candidate hash is compared against
`monitor/.state/last-emit-stable-hash` and
`monitor/.state/last-emit-stable-ts`. When they match AND the gap is
under `monitor.emit_dedup_max_quiet_seconds` (default 86400 / 24h),
the paste is suppressed — a single
`emit-dedup: suppressed identical-hash emit (reason=<r>, last_emit=<ts>, hash=<short>)`
row goes to `watcher.log` instead. The archive write under
`monitor/.state/diffs/` still happens unconditionally, so the
forensic record of every composed emit stays complete; only the
paste is gated. State files advance only after a successful paste —
a paste failure (over-limit, target window missing) does not poison
the next retry.

Three bypass surfaces unconditionally let the body through, even on
an identical-hash repeat:

* any `id=<digits>` row under `--- eligible github comments ---`
* any non-blank row under `--- pending decisions ---`
* `N awaiting-input` with N > 0 in the workspace prelude

These are operator-attention signals. The `nexus-emit-sig` footer
remains in every body — it's still useful for ad-hoc debugging of
paste-vs-archive delivery; only its role as the dedup key is
explicitly disclaimed (it embeds a per-fire nonce and timestamp).

Knob: `monitor.emit_dedup_max_quiet_seconds` (env override
`MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS`). 0 disables the gate
entirely — every eligible emit pastes, no state files written.
The startup-sweep emit on watcher restart is never gated; it does
seed the dedup state so the first steady-state cadence tick has a
current anchor instead of a stale pre-restart hash.

## Environment variables

Each env var, if set, overrides the corresponding key in
`config/nexus.yml`. The "Config key" column points at the source of
truth.

| Env var                       | Config key                                | Purpose                                |
|-------------------------------|-------------------------------------------|----------------------------------------|
| `NEXUS_ROOT`                  | `nexus.root`                              | nexus workspace root                   |
| `MONITOR_INTERVAL`            | `monitor.interval_seconds`                | seconds between snapshots              |
| `MONITOR_TARGET`              | `monitor.target_window`                   | tmux window the continuous watcher pastes reports into (default `orchestrator`) |
| `DIFF_RETENTION_DAYS`         | `monitor.diff_retention_days`             | days before archived diffs are pruned (default 7) |
| `AGENT_DEAD_THRESHOLD`        | `monitor.agent_dead_threshold`            | slow-path threshold (default 3): consecutive polls a future "window-present-but-agent-silent" detector must observe before it presumes the agent dead. Reserved — no current detector wires this in. The cleanly-missing-window case is now governed by `AGENT_MISSING_RESPAWN_DELAY` (fast path). |
| `AGENT_MISSING_RESPAWN_DELAY` | `monitor.agent_missing_respawn_delay`     | fast-path knob (default 3): extra confirming polls after a missing-window observation before the watcher respawns the agent. At the 2 s probe cadence the default demands ~8 s of confirmed absence. `0` respawns on first detection — the pre-2026-06-02 behaviour, where a single transient misread spawned a duplicate orchestrator; do not lower without a reason. The pre-launch re-verification (`_respawn_verify_target_absent`) is an additional, always-on guard. |
| `MONITOR_AUTO_UNSTICK`        | `monitor.watcher.auto_unstick`            | auto-Enter on stuck permission prompts (case A) AND auto-resume rate-limit prompts post-reset (case B: cascades to all stuck windows + heads-up to orchestrator). Default `true`. |
| `MONITOR_RATELIMIT_PROBE`     | `monitor.watcher.ratelimit_probe`         | probe the Anthropic API for the rate-limit reset timestamp on case B detection (uses `anthropic-ratelimit-unified-reset` / `-tokens-reset` headers). Default `false`. Requires `ANTHROPIC_API_KEY` in env. |
| `ANTHROPIC_API_KEY`           | (env-only, never config)                  | Anthropic API key for the case-B reset probe. Falsey/missing disables the probe; the watcher then falls back to `ratelimit_heuristic_minutes`. |
| `MONITOR_RATELIMIT_HEURISTIC_MIN` | `monitor.watcher.ratelimit_heuristic_minutes` | fallback wait (minutes) when the probe is off or fails (default 30). |
| `MONITOR_RATELIMIT_ACK_TIMEOUT_S` | `monitor.watcher.ratelimit_ack_timeout_s` | seconds to wait for the orchestrator's `ratelimit-resume-ack` action-log entry after a cascade (default 60). |
| `MONITOR_PROBE_MODEL`         | `monitor.watcher.probe_model`             | model id for the probe (default `claude-haiku-4-5-20251001` — cheapest current model). |
| `MONITOR_ORCH_PASTE_RESPONSE_GRACE_S` | `monitor.watcher.paste_response_grace_seconds` | Grace window (s) after a successful paste-to-orchestrator before the #164 state machine declares pasted-without-response. Default 120 (raised from 60 after the 2026-05-29..31 false-positive respawns; healthy heavy turns ran ~90-180 s). Multi-step tool turns can legitimately consume this time. Also the response window granted to the re-submit rescue. |
| `MONITOR_ORCH_UNSTICK_WINDOW_S` | `monitor.watcher.unstick_window_seconds`      | Budget (s) for `_unstick.sh` cases A-D to bump the orchestrator heartbeat once the state machine is in the pasted-without-response state. Default 150 (lowered from 180 alongside the grace raise so `grace + unstick_window < dead_threshold` keeps a re-submit verification window before the deadline). |
| `MONITOR_ORCH_DEAD_THRESHOLD_S` | `monitor.watcher.orchestrator_dead_threshold_seconds` | Hard floor (s): respawn the orchestrator if no heartbeat at all post-paste, including through the unstick window and the re-submit rescue. Default 300. Must satisfy `paste_response_grace + unstick_window < dead_threshold` (startup WARN otherwise) so the rescue always fires before the cap. Subsumes the legacy `MONITOR_ORCH_UNRESPONSIVE_THRESHOLD_S` (which seeds this default for one release). |
| `MONITOR_ORCH_LIVENESS_LOG_THROTTLE_S` | `monitor.watcher.liveness_log_throttle_seconds` | Minimum spacing (s) between `waiting` verdict log lines from the orchestrator-liveness task. State entries, transitions, and re-submit / respawn events always log. Default 30. |
| `MONITOR_ORCH_STALE_PASTE_CEILING_S` | `monitor.watcher.stale_paste_ceiling_seconds` | Upper bound (s) on how old the last paste-to-orchestrator may be and still serve as evidence of wedging. Once `now - last_paste >= ceiling`, the #164 state machine returns healthy `paste-too-stale` instead of escalating via the dead-threshold cap — a quiet workspace with no eligible pastes for half an hour is not the same as a wedged orchestrator. Default 1800. Must satisfy `dead_threshold < stale_paste_ceiling` (otherwise the ceiling masks the wedge detector inside the in-window range and respawns never fire). Any fresh paste resets `last_paste_ts`, so the ceiling never hides a real wedge. |
| `MONITOR_ON_DIALOG`           | `monitor.watcher.on_dialog`               | Case-D action mode (the watcher's `AskUserQuestion` chip-bar safety net — see `monitor/watcher/_unstick.sh`). One of `auto-dismiss` (default — capture pane, send `Escape`, paste a meta-message into the now-clean input box), `skip` (log detection only; leave the dialog up — useful for debugging), or `error` (log a `WARN` line; otherwise the same as `skip`). The orchestrator-side hook in `monitor/orchestrator-settings.json` (`PreToolUse` matcher on `AskUserQuestion`) blocks dispatch at the API level; this knob tunes the watcher safety net for sessions whose settings file is missing/corrupt or for future modal shapes whose render carries the same chip-bar signature. |
| `MONITOR_WORKER_ASKUQ_GRACE_SECONDS` | `monitor.watcher.worker_askuq_grace_seconds` | Worker-blocked-question relay (Case W — see `monitor/watcher/_unstick.sh`). A live `AskUserQuestion` overlay on a **non-target** pane observed continuously past this grace is relayed to the orchestrator as a synthesized pending-decision record (`kind: blocked_question`, the issue-129 channel) so it can answer on the operator's behalf. The grace gives a human at the pane first right of reply. Default 300; 0 disables the relay. |
| `MONITOR_SCHEDULER_LOG_MAX_BYTES` | `monitor.scheduler.log_max_bytes` | Rotation cap for `watcher-scheduler.jsonl`, the per-fire telemetry sink (one row per task fire at 2–5 s cadences ≈ 15 MB/day; it had grown unbounded to 310 MB live before this cap). `prune_archive` (600 s task) rotates it to `<name>.<epoch>` past the cap and prunes archives older than `DIFF_RETENTION_DAYS`. Default 52428800 (50 MiB); 0 disables. |
| `MONITOR_STATE_LOG_MAX_BYTES` | `monitor.state_log_max_bytes` | Shared rotation cap for the slower-growing append-only state files: `watcher.log` (copytruncate — the headless launcher's redirect holds a long-lived O_APPEND fd on its inode, so rename rotation would strand the live log), `functional-check.tsv`, and `action-log.jsonl` (both rename). Same `<name>.<epoch>` + retention lifecycle as above. Default 10485760 (10 MiB); 0 disables. |
| `MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR` | `monitor.scheduler.async_timeout_floor_seconds` | Async hang watchdog. An async scheduler task still in flight past `max(4 × its interval, this floor)` has its child process tree killed (PID-scoped) and re-arms on its next due tick; a `phase="async-timeout"` rc=124 telemetry row + a `WARN` to the watcher log record it. Closes the silent-permanent-task-death mode — a hung helper (e.g. a `gh` call on a black-holed connection, which has no client-side timeout) left the in-flight guard skipping every future fire of that task with no log line. Default 300; 0 disables the watchdog. See `monitor/watcher/_scheduler.sh`. |
| `MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS` | `monitor.emit_dedup_max_quiet_seconds` | Content-hash dedup gate: suppress an emit's paste when its stable-content sha256 matches the last successfully-pasted body AND the gap is shorter than this many seconds. Bypassed when the body carries operator-attention signal (eligible-comments / pending-decisions / awaiting-input > 0). Default 86400 (24h) — i.e. the watcher pastes a heartbeat-style emit at least once a day even on an unchanged workspace. 0 disables the gate. See "Content-hash dedup gate" above. |
| `MONITOR_REPO`                | `github.repo`                             | GitHub repo to poll                    |
| `MONITOR_USER_LOGIN`          | `github.user_login`                       | only this user's comments are eligible |
| `NEXUS_BOT_APP_ID`            | `github.bot_app_id`                       | GitHub App ID                          |
| `NEXUS_BOT_INSTALLATION_ID`   | `github.bot_installation_id`              | installation ID on the target org/user |
| `NEXUS_BOT_PRIVATE_KEY_PATH`  | `github.bot_pem_path`                     | RSA private key for the App            |
| `NEXUS_BOT_TOKEN_CACHE`       | `github.bot_token_cache`                  | cached installation token + expiry     |
| `NEXUS_PUSHOVER_USER_KEY_FILE`| `notifications.pushover.user_key_path`    | Pushover user key file                 |
| `NEXUS_PUSHOVER_APP_TOKEN_FILE` | `notifications.pushover.app_token_path` | Pushover app token file                |
| `NEXUS_NOTIFY_TOKEN`          | `notifications.ntfy.topic_url_path`       | ntfy topic URL file                    |
| `NEXUS_EMAIL_TO`              | `notifications.email.address`             | emergency email recipient              |
| `NEXUS_SMTP_HOST` / `NEXUS_SMTP_PORT` | `notifications.email.smtp_host` / `.smtp_port` | outbound SMTP relay  |
| `NEXUS_ASSET_REPO`            | (upload-asset.sh only)                    | repo for `upload-asset.sh` commits     |
| `NEXUS_ASSET_BRANCH`          | (upload-asset.sh only)                    | branch for `upload-asset.sh` commits   |
