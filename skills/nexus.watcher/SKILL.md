---
description: "Operating and diagnosing the nexus watcher: judging liveness by the loop-proof heartbeat (NOT watcher.log mtime), the supervisor's silent self-heal, recovery recipes by failure signature (wedge / stale-lock / decapitation-duplicate), phantom-window auto-resurrection, the eligible-comment eyes-ack + stale-eyes re-emit, and CC-banner vs gated cc-update. Orchestrator-facing; pairs with nexus.self-fix for code fixes and nexus.service-recovery for service-health emits."
---

# nexus.watcher — operating & diagnosing the watcher

TRIGGER when: judging whether the watcher is alive; a supervisor
`Monitor` exited or you got a "watcher DOWN" signal; a fresh
`watcher/main.sh` pid / `startup-sweep` emit appears; an eligible GitHub
comment keeps re-emitting; a phantom `claude` window spawns and
vanishes; or you're about to conflate the Claude Code TUI update banner
with the gated cc-update emit.

**Audience: orchestrator-only.** A worker never operates the watcher.

This skill is for **operating** the watcher (liveness, recovery, emit
semantics). To **change watcher code**, use `nexus.self-fix` and the
separate-clone rule in `CLAUDE.md` § "Spawning workers" (never
`git checkout` a diverged branch on the main clone — it silently breaks
the running loop). For a `--- service health ---` emit, use
`nexus.service-recovery`.

The watcher runs headless (no tmux window); its log is
`monitor/.state/watcher.log`.

## 1. Judge liveness by the heartbeat, never `watcher.log` mtime

Since the "heartbeat IS the proof-of-working-loop" change, the
authoritative liveness signal is the **loop-proof heartbeat** the main
loop writes each tick — what `watcher-supervise-tick.sh` and
`revive-watcher.sh` check. **`watcher.log` mtime ≠ loop liveness:** the
log can keep getting touched while the loop is wedged (e.g. a
`compose_emit` hang), giving a FALSE "healthy" read. Do not
`stat watcher.log` to judge health — run `monitor/svc.sh status` (reads
the watcher row) or trust the supervisor's verdict.

An even stronger signal than either heartbeat or log mtime: **is the
loop forking fresh children** (`tac`/`jq`/`gh`)? A wedged loop stops
spawning.

## 2. The supervisor self-heals SILENTLY — don't over-react

`watcher-supervise-tick.sh` does **not** merely exit on a DOWN tick — it
**internally revives** the watcher and returns 0, so the
`until ! tick; do sleep 15; done` loop keeps running and sends **no
notification**. Consequences:

- A `startup-sweep` emit + a **new watcher pid is NORMAL.** It is usually
  the supervisor's silent revive, or a cc-update restart onto a new
  binary (§5) — not necessarily a crash. Don't reflexively revive; just
  verify **exactly one** `watcher/main.sh` (see §3 on how) + one
  `[w]atcher-supervise-tick` loop, and re-arm the supervisor only if it
  is genuinely unarmed (`svc.sh status` watcher-sup row).
- **You only get an exit-notification when the revive itself FAILS**
  (e.g. a stale lock blocks the launch, §4c). That is the mutual-liveness
  contract working — it wakes you promptly; respond, don't ignore it.

`revive-watcher.sh` is idempotent, single-flight-locked, and
group-reaping — it converges to exactly one live watcher and no-ops if
genuinely up. So the correct response to a real DOWN is: run
`revive-watcher.sh` (the harness auto-backgrounds it; wait for its
completion notification — `--replace` group-reaps the old watcher BEFORE
launching the new, so for ~3–4 min there is NO live `main.sh` and status
reads DOWN; that is convergence, not a hang — do **not** re-launch),
THEN re-arm the supervisor.

## 3. Diagnose by process GROUP, not pid

`ppid==1` is a **false** "top-level watcher" test. `main.sh` forks a
subshell chain; if the leader dies the chain reparents to `init`,
inherits argv, and `ps | grep main.sh` shows it as a watcher. A bare
`grep 'watcher/main.sh'` also matches your own shell's command text.

- Identify by process **group** (`pgid`), and count group leaders to
  detect duplicates.
- Reap a group with `kill -TERM -- -<pgid>`, bounded wait, then
  `-KILL -- -<pgid>`; assert zero members after.
- **Never `pkill -f`** — it reaps sibling workers sharing the launcher
  argv and your own shell (see `nexus.worker-defaults` / worker bash
  footguns).
- When inspecting worker/watcher process trees, `cut -c1-160` the
  `ps -o args` output — a `claude` process dumps its entire spawn prompt
  and floods context.

## 4. Recovery recipes by failure signature

**(a) `compose_emit` wedge (loop-heartbeat stale).** The loop hangs on a
long `compose_emit` — historically an invalid-multibyte awk choke on a
science comment full of `⟂ σ µ → ≈ $z$` (fix: `LC_ALL=C` on the awk, as
`_reemit.sh` already does), or a slow-NFS / GitHub-API i/o timeout. The
watcher's own watchdog kills the hang (~300s) and the supervisor
revives. If it doesn't self-heal, `revive-watcher.sh`.

**(b) Decapitation duplicate (TWO concurrent watchers).** Killing the
leader pid leaves the reparented chain looping; revive then spawns a new
watcher *next to* the chain that never stopped → two watchers racing the
same `monitor/.state/` files (emit cadence balloons). `flock` binds to
the open file description and every `fork()` inherits it, so
`nexus-instance.lock` is structurally blind to this
(`fuser nexus-instance.lock` shows many holders). **Diagnose by group
(§3); reap the stale group by pgid.** Killing the duplicate roughly
halves loop cost. Tracked at `<your-org>/nexus-code#491`.

**(c) Stale lock blocks auto-revival.** Signature: `revive-watcher.sh`
AND `svc.sh restart watcher` return **silently, no output, watcher stays
DOWN showing the SAME old dead pid** (no new pid) — a stale lock is
blocking the launch, the commands did not hang. Recipe:
1. `cat monitor/.state/watcher.lock` → read `pid:`; `ps -p <pid>` to
   confirm DEAD.
2. Only after confirming no live `watcher/main.sh` exists, remove the
   exact stale locks: `rm -f monitor/.state/watcher.lock
   monitor/.state/nexus-instance.lock` (+ any 0-byte op-locks the kill
   left: `unacked-mentions.lock`, `deliveries-queue.lock`). Name exact
   files — never broad-glob `monitor/.state/`.
3. `timeout 60 monitor/svc.sh restart watcher` (now succeeds).
4. Re-arm the supervisor `Monitor`; verify exactly one loop.

## 5. Auto-resurrection — phantom `claude` windows

`monitor/watcher/main.sh` (`respawn-agent`) spawns a fresh `claude`
session in the target window when paste-to-target fails
`monitor.agent_dead_threshold` consecutive emits (default 3). Common
false positive: tmux's auto-rename briefly retitles the orchestrator
window during a long Bash call or a UI spinner, breaking the
name-based half of the `_target_window_present` lookup → after 3
misses the watcher respawns. Since `#741` the probe also asks whether
a LIVE pane is in that window, not just whether the name is listed: a
crashed claude leaves a `remain-on-exit` corpse that used to read
PRESENT forever, which meant a genuinely dead orchestrator was never
respawned at all — the opposite failure, and the silent one. The respawned agent reads `monitor/agent-prompt.md`, validates
whether the window was truly absent, and (on a false positive) diagnoses
it in seconds and exits — visible as a "window N bell spawning and
disappearing" pattern. The `--- standing bells ---` lines show which
windows are flagged. Killing a stuck resurrected agent is fine.

## 6. Eligible-comment eyes-ack (and the stale-eyes re-emit)

An `--- eligible github comments ---` entry is **re-emitted every poll
until it receives the bot's 👀 (eyes) reaction** — not a rocket, not the
`ng wrap-up` link comment. Ack with the canonical bot-identity tool:

```bash
./monitor/ng react <COMMENT_ID> eyes --repo <owner>/<repo>
```

Eyes = "seen + being handled." Rocket does NOT clear eligibility (use it
only as the wrap-up trigger ack).

- **Never** `gh api …/reactions -f content=eyes` for this — the `gh` CLI
  authenticates from the operator's keyring and posts a *user* 👀, which
  does **not** clear the re-emit (the watcher requires the **bot's** 👀);
  even a `GH_TOKEN=` prefix can be ignored. Only `ng react` yields
  `eyes by …-bot[bot]`. Verify:
  `gh api repos/<repo>/issues/comments/<id>/reactions --jq '.[].user.login'`.
- **Stale-eyes re-emit (a known papercut).** The watcher only counts a
  bot reaction as clearing an emit if it falls within the emit's SLA
  time-window `[emit_mtime - SLA, now]` — a 👀 from hours ago goes
  "stale" against a fresh re-emit and stops clearing it (cross-repo
  comments compound this). So an already-handled comment can re-surface
  indefinitely. When you **recognize** a re-emitted comment as handled:
  verify once that the bot 👀 **and** a visible bot reply are present,
  then **let subsequent re-emits pass — do not re-implement or re-ack**
  (re-adding 👀 is a no-op; GitHub keeps the original timestamp).
  Hardening this (accept a valid bot 👀/🚀 from any time) is watcher code
  → `nexus.self-fix`, operator-gated.

## 7. CC update banner ≠ gated cc-update emit

The Claude Code TUI status line shows its own npm-registry banner
(`vX ⬆ Y`) — Claude Code's built-in check, **not** the watcher's gated
signal. Only treat a cc-update as gated-triggered when the **watcher**
emits `--- claude code update available ---` (logged as
`cc-update FIRED: … candidate=X installed=Y`; state in
`monitor/.state/cc-update-available`). The check runs on a cadence, so
the registry can be ahead of the gate for a while — present the banner
as at most an early heads-up, never as the gate firing. On a SAFE verdict
the routine bumps the pin and restarts the watcher (and tries the
orchestrator) silently; an `APPLY_EXIT=20 safe-bumped-restart-deferred`
is a benign version-split that self-heals on the next natural respawn —
don't force-kill your own window to chase it. Evaluation procedure:
`nexus.cc-update`.

## See also

- `nexus.self-fix` — changing watcher code (separate-clone gate).
- `nexus.service-recovery` — `--- service health ---` emits.
- `nexus.cc-update` — evaluating a CC release before the pin bump.
- `nexus.worker-defaults` — the `pkill -f` / bash-footgun floor.
- `monitor/README.md` — watcher architecture, env vars, liveness.
