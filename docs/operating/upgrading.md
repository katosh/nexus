# Upgrading

How a running nexus picks up new code, and specifically how a
deployment on the old **watcher-in-a-window** setup converges to the
current **headless service** hosting.

## The standard update routine: `git pull` — that's it

One step, on the live clone:

```bash
git -C <nexus-root> pull
```

A running watcher is **version-aware**
([`monitor/watcher/_version_restart.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/_version_restart.sh),
issue `#186`): every cycle it compares, per component, the source-set
hash of the code the running instance loaded at start against the same
files on disk now, and on confirmed drift triggers the right restart
on its own:

| Component | On confirmed drift |
|---|---|
| watcher (`main.sh` + every module it sources) | self-restarts via a detached `launcher.sh --replace` |
| registered services (`monitor/services.registry`) | `svc.sh restart <name>` |
| services cockpit (`svc.sh` stack) | **asks** the orchestrator via an emit — the TUI window is orchestrator-owned; the watcher never kills it |

The drift must hold stable for `monitor.version_restart.settle_seconds`
(default 45 s — a mid-pull torn tree is detected and never acted on),
actions are cooldown-gated per component (default 600 s), and watcher
self-restarts are loop-guarded (3/hour). So after a pull, expect the
watcher to bounce itself within roughly a minute; no manual step.
Master switch: `monitor.version_restart.enabled` (default `true`).

A service's fingerprint is its **launch script** — the first
file-backed token of the registry `launch` command (e.g. `serve.sh`
in `./serve.sh --flag`). A change to that script's own bytes triggers
the restart; a change buried in code the script merely *imports at
runtime* (a sibling `lib/*.py`, a sourced helper) is **not** seen,
because only the launch script itself is hashed. Keep a service's
entrypoint thin so meaningful changes touch it, or restart such a
service by hand. A launch with no file-backed token
(`python -m http.server`) is untrackable and simply not
version-managed.

**The one bootstrap caveat:** only a version-aware watcher can
auto-restart anything. The *first* deploy of a watcher that includes
this module — or any deploy where the feature is disabled — is still
the manual two-step:

```bash
git -C <nexus-root> pull
monitor/svc.sh restart watcher
```

**If you restart manually, always pull before restarting.**
`monitor/watcher/main.sh` sources sibling module files (`_config.sh`,
`_emit_filters.sh`, `_hosting_migration.sh`, ...) at startup;
restarting onto a tree where those files don't exist yet — or where
their function signatures have diverged from what an already-running
process holds in memory — fails quietly. The pull puts the whole
module set on disk first; the restart loads it atomically. (This
ordering hazard is exactly what the auto-restart's torn-pull detection
guards against on the automatic path.)

**Not covered by the auto-restart:** the orchestrator's own running
`claude` process (a Claude Code *binary* upgrade needs the
[cc-update flow](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.cc-update/GUIDE.md),
which replaces the orchestrator session deliberately), and any worker
sessions already in flight — both keep running what they started with,
by design.

## Coming from the windowed watcher: the upgrade is self-delivering

You don't need to know about the cutover in advance. A pre-cutover
watcher predates the version-aware module, so this is the bootstrap
case: one manual pull-then-restart is enough, because the new watcher
detects legacy hosting and tells the orchestrator how to finish:

1. **You pull and restart the watcher however you used to.** Any
   restart path that goes through `monitor/watcher/launcher.sh` or
   `./watcher` (both the old muscle-memory commands) already spawns
   the new way — headless, setsid-detached, log at
   `monitor/.state/watcher.log` — and **sweeps the leftover `watcher`
   tmux window automatically**. Self-converging; no manual window
   cleanup.
2. **If the watcher still came up window-hosted** (for example you
   run `main.sh` directly in a window from a custom script), the new
   code notices: the launcher marks its headless spawns with
   `WATCHER_WINDOW=headless`, and a watcher started any other way
   surfaces a one-shot `--- watcher hosting migration ---` section in
   its first emit to the orchestrator, spelling out exactly the steps
   on this page. It then **continues working normally** — no refusal,
   no degraded mode, and the notice fires at most once per watcher
   start (it rides only the startup sweep). Source:
   [`monitor/watcher/_hosting_migration.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/_hosting_migration.sh).

So the migration loop closes itself: pull → restart → (if still
legacy) the watcher's own emit tells the orchestrator → one
`monitor/svc.sh restart watcher` → headless.

## Manual checklist

The full manual sequence — needed only for the bootstrap caveat above,
when `monitor.version_restart.enabled` is `false`, or when you want
the restart *now* rather than within the settle window:

1. `git -C <nexus-root> pull` on the live clone (before any restart —
   see above).
2. `monitor/svc.sh restart watcher`. This runs
   `watcher/launcher.sh --replace`: it TERMs the recorded watcher
   process (escalating to KILL after 5 s), respawns headless, and
   sweeps a leftover legacy `watcher` window.
3. Optional: create `monitor/services.registry` from
   [`monitor/services.registry.example`](https://github.com/<your-org>/nexus-code/blob/main/monitor/services.registry.example)
   to put additional infra services (notebook servers, dashboards,
   ...) under the same supervision. The registry is operator-local and
   gitignored.
4. Verify:
    - `monitor/ng watcher-status` exits 0 and reports
      `hosting: headless`.
    - `monitor/svc.sh status` shows the watcher row `UP` (and the
      orchestrator row once the watcher has spawned it).

## What changed, in one paragraph

Before the cutover, `./watcher` renamed the invoking window to
`watcher` and ran the watch loop in the foreground there, and the
window doubled as the supervision surface. Now the watcher is a
headless service — pidfile `monitor/.state/watcher.pid`, log
`monitor/.state/watcher.log` — supervised by
[`monitor/svc.sh`](dashboard.md) like every registry service, and the
invoking window of `./watcher` becomes the `services` cockpit instead.
The watcher (not `./watcher`) owns spawning and reviving the
orchestrator. Details: [Operating → Watcher](watcher.md) and
[Reference → Architecture](../reference/architecture.md).

## Resuming the orchestrator across the upgrade

`./watcher --continue` keeps its meaning across the cutover, with a
sharper contract: the watcher resumes the exact session named by the
orchestrator session-id pin (`monitor/.state/orchestrator-session-id`)
via `claude --resume <sid>`. Without a valid pin it starts fresh — it
never resumes an arbitrary most-recent session. A plain
`monitor/svc.sh restart watcher` doesn't touch the orchestrator at
all: a live orchestrator window is left alone, and a dead one is
revived from the pin.
