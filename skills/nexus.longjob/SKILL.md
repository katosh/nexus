---
description: "Being WOKEN when a long computation ends, fails, or does anything you asked to be told about — a Slurm job, a multi-hour local command, a pid, a file appearing/growing/matching, or any command's exit status — via the ONE host-armed plugin monitor every nexus session carries (monitor/longjob-watch.sh, `ng longjob`). Use when a job will outlive the 30-minute Monitor cap, when you are about to end a turn with work in flight, when `add` said NOT ARMED, or when you need to know what the watch does when it does NOT fire."
---

# nexus.longjob — be woken by a long job

## The problem this closes

The model-armed `Monitor` is capped at 30 minutes, enforced at arm time and at
runtime. `CronCreate` waits for an idle REPL (measured 18m35s late). The Bash
tool's `run_in_background` re-invokes you, but it must be launched by a turn
and re-launched per job. `monitor/async-run.sh` RETAINS an exit status and
re-invokes nobody (`<your-org>/nexus-code#1523`: an `await` expired cleanly and
the agent sat idle 809 s). A worker that started a four-hour Slurm job had no
way to be told it finished.

Claude Code has exactly one wake mechanism that is armed WITHOUT a model turn
and outlives the cap: a plugin-declared monitor (`experimental.monitors`,
loaded with `claude --plugin-dir`). Every nexus launch surface (worker spawn,
worker resume, the claude-loop wrapper, the orchestrator respawn) now arms ONE
such monitor: the **longjob-watch dispatcher**, `monitor/longjob-plugin/`. It
never exits, polls a per-session spool of watch specs you drop in at any time,
and prints one line per meaningful transition. Each printed line reaches you
as a task notification, whether you are idle or mid-turn.

## How to use it — three shapes

**A local long command (the 40-minute test suite, a multi-hour script) — one line:**

    monitor/ng longjob run --desc "watcher suite" -- monitor/watcher/run-tests.sh --jobs 4

This launches through `monitor/async-run.sh` (exit status retained) and
watches the token. End your turn. You are woken with a line like

    longjob-watch: DONE ar-3f2c… asyncrun:ar-3f2c… — rc=0 elapsed=2412s … | record: monitor/longjob-watch.sh show ar-3f2c…

or `FAILED … rc=1 …`. `show <id>` has the spec and the last probe; the
job's own output is where async-run put it (`async-run.sh --status <token>`).

**A Slurm job — nothing to do.** The PostToolUse launch hook already detects
`sbatch` / `srun --no-block` and now auto-adds `slurm:<jobid>` (watch id
`auto-slurm-<jobid>`). You are woken on `COMPLETED`, `FAILED`, `TIMEOUT`,
`OUT_OF_MEMORY`, `CANCELLED`, `NODE_FAIL`, … — every terminal state, and on
UNKNOWN when the job never appears in accounting (a failed submission). A job
you deliberately fire-and-forget: `monitor/declare-no-wait.sh slurm <id>`
first, and no watch is added. Manual form, for a job id you got some other
way: `monitor/ng longjob add slurm:<jobid> --desc "…"`.

**Anything else — `add <kind>:<target>`:**

| kind | target | terminal when |
|---|---|---|
| `slurm:` | job id | sacct reports any terminal state; UNKNOWN if never in accounting |
| `asyncrun:` | async-run token | the runner wrote its status (`done` rc 0, `failed` otherwise, `failed\|died` if the pid vanished with no status) |
| `pid:` | pid (start-time pinned at add) | the process is gone — **exit status NOT retained**; use `asyncrun:` when the rc matters |
| `file:` | path, `--when exists\|grew\|match --pattern ERE` | the predicate holds |
| `cmd:` | a shell command line, re-run each poll | rc 0 done · 1 running · 2 failed · 3 unknown · other failed |

Options: `--desc`, `--id`, `--interval S` (default 60), `--ttl S` (7 days),
`--notify terminal|transitions` (default terminal: nothing is printed until
the end), `--persistent` (emit on EVERY transition, never retire — the
level-triggered tick shape), `--max-events N`, `--unknown-max N`.

`ng longjob list | show <id> | rm <id> | events | status` read the spool.

## What happens when the watch does NOT fire

This is the paragraph that earns its place. A dispatcher that has stopped
looks exactly like one with nothing to report, so the design puts the
detectors OUTSIDE the emit path:

- **`add` tells you, on stdout, at rc 3, when the session is NOT ARMED** —
  the ledger (`dispatcher.json`) is absent, its pid is dead, or its last poll
  is stale. Read that line. The watch is still recorded and declared as an
  external wait, but nothing will wake you. The fallback that DOES re-invoke
  you is
  `monitor/longjob-watch.sh await <id> --timeout <s>` in a Bash call with
  `run_in_background: true` (rc 0 done, 1 failed, 3 unknown/parked, 4 timeout),
  and `ng longjob status` says why the session is unarmed; the launcher's
  reason is in `monitor/.state/longjob/arming.log` (`epoch`, `window`,
  `armed|skipped`, `reason`, `src`). **A row whose fifth column names a
  `watcher/test-*.sh` is a FIXTURE row written by a test suite, not a
  launch** — read only rows with an empty fifth column as launcher reasons.
- **The host arms plugin monitors only under a remote rollout flag.** On
  2.1.272 the gate is the GrowthBook feature `tengu_amber_sentinel`
  (default FALSE), served only to first-party sessions with telemetry on;
  nothing on this side can force it (the public build stubs every local
  override). `ng longjob status` prints the value the last session cached
  AND ITS AGE (`host_rollout_flag tengu_amber_sentinel=true age=855s`, from
  `cachedGrowthBookFeaturesAt` — never from the file's mtime, which is
  session state rewritten constantly: measured 41 s mtime against an 855 s
  old cache). An old `true` is not a current one: the cache is refreshed only
  by first-party sessions. If it reads false or absent, NO nexus session has
  a dispatcher, whatever the launcher passed — the same NOT ARMED path applies, and the cc-update GUIDE (2g) is
  where that gets re-argued. This is also why the cc-harness cannot arm it
  (the mock backend is a third-party provider) and why the real-binary
  evidence comes from real-auth probes.
- **`unknown` is a fifth answer and it is not `running`.** A probe that cannot
  tell says so; after `unknown_max` consecutive unknowns (default 5 polls) the
  watch emits `UNKNOWN … PARKED` once and stops probing. Check the subject
  yourself, then re-add or `rm`.
- **Every emit is checked — and "written" is the most this side can say.**
  A stdout write that fails is counted in the ledger and logged to
  `emit-failures.log`; `status` surfaces it. But the host's own rate limiter
  (2.1.272: a token bucket of 10 batches refilling one per 2 s) DISCARDS a
  batch that finds the bucket empty and delivers only a "suppressed N
  events" count later — invisible to printf, so invisible to every record
  here. `events.log` therefore says `written`, never delivered, and the
  ledger counts `written`. The defence is arithmetic, not detection: emits
  are paced ≥ 2.5 s apart (`monitor.longjob` / `MONITOR_LONGJOB_EMIT_MIN_GAP_MS`),
  so the bucket can never drain however many watches go terminal in one
  pass; N events cost ~2.5·N s of latency, never content.
- **A line is composed head-first under the host's 500-char cut.** State, id,
  subject, the record pointer and the action clause come first; the detail
  is what gets trimmed. What survives truncation is what you must act on.
- **A non-terminal retirement keeps the external wait.** A TTL `EXPIRED`
  ("the subject may still be running") and an `UNKNOWN … PARKED` retire the
  WATCH but leave the `external_waits` entry declared, so the session still
  reads `idle-orphan-async` and the watcher's orphan-async loop still probes
  the subject live through `resolve`. Only a terminal state clears the wait.
- **Caps.** One delivered line has cost a session 3m26s and $1.53 of
  commissioned work. Default watches print only their terminal state; each
  watch stops after `watch_max_events` (8); the session mutes after
  `session_max_events` (60) with ONE final MUTED line — `ng longjob unmute`
  grants a fresh budget.
- **The pane-state backstop.** Every `add` declares an `external_waits` entry.
  A session whose dispatcher is absent therefore reads `idle-orphan-async`,
  and the watcher's orphan-async loop resolves the wait through
  `longjob-watch.sh resolve` and wakes the window — slower, but not silent.
- **TTL.** A watch with no terminal state after 7 days emits EXPIRED and
  retires; the subject may still be running.

## The ledger contract

`dispatcher.json` is written by `dispatch` alone, atomically: when armed,
after every poll pass, and inside a pass before every paced wait — so
`last_poll` never ages by more than the pacing gap while the dispatcher is
alive. Freshness is judged against the ledger's OWN `poll_seconds` (never a
reader's config), and `_ledger_verdict` (`ng longjob ledger-verdict`) is the
one reader of liveness AND service that `status`, `add` and pane-state's
discount share. **`armed` means SERVICE, not process:** the ledger carries a
`service` field (`polling` | `disabled` | `unscoped`), and a live, fresh
ledger whose service is not `polling` — the kill switch's own branch — reads
`disabled`, so `add` says NOT ARMED (rc 3) instead of "safe to end your
turn". The kill-decision discount counts live watches FROM THE SPOOL through
`ledger-verdict`'s `active=`, never from the ledger's cached field, which is
published only by a completed pass. Every field has a named reader; the
schema `version` is refused by any other reader — **which has a rollout
cost, stated here because the reader was asked for and this is what it
buys:** when a ledger schema bump lands, every session still running a
pre-upgrade dispatcher writes the old version, the new reader classifies
that ledger `absent`, the discount does not fire, and that pane reads
`working-background` (never retired by idle-age) until the session
respawns. Safe direction for kills, board-freeze direction for cleanup;
bounded by the retain TTL and closed by a respawn. The heartbeat inside a
pass beats on TIME (before a probe once `poll_seconds` have elapsed, and
before every paced wait), never only on events; the contract's bound is
`poll_seconds + probe_timeout_seconds`, and `dispatch` refuses a config
whose probe timeout could outlast the freshness window. The full contract, field
by field, is in the header of `monitor/longjob-watch.sh`; three skeptic
passes found violations of it before it was written down.

## What survives what

The **spool** (`monitor/.state/longjob/<session-key>/`, keyed on
`$CLAUDE_CODE_SESSION_ID`) survives a respawn, a crash and a sandbox restart:
it is a directory. A `--resume`/`--continue` session keeps its id and its
dispatcher re-arms from that spool on the first poll; a NEW session has a new
id and an empty spool, so a dead session's watches cannot leak into it.

The **dispatcher process** is session-scoped. It dies with the `claude` that
armed it and comes back only when a session is launched with the plugin
present — which every nexus launcher does, and which you cannot do for
yourself mid-session. Measured (`<your-org>/<your-nexus>#375` S1): a plugin
monitor command that exits is NOT relaunched, and its exit reaches the model
as a "script failed" notice that costs a turn (measured 2026-09-15: ~16–21 s,
~$0.11). The dispatcher therefore never returns — an empty spool, an
unreadable spool and a fatal poll error are all loops that sleep — and the
suite asserts it is alive after every watch has retired.

Nothing here outlives the sandbox. PID 1's argv ends
`-- tmux new-session ./watcher --continue`: the watcher is the sandbox's init
payload, a sandbox restart revives it with no nexus machinery, and it revives
the board. That is the outer boundary of what any in-session mechanism covers.

## Measured, and what is not

On Claude Code 2.1.272, hermetic tmux, n=1 per probe unless stated
(`<your-org>/nexus-code#1535` report; the plugin-monitor mechanism itself is
`<your-org>/<your-nexus>#375`):

- armed at session start with zero turns; command alive at 41 min; a line
  emitted at T0+32m delivered the same minute; keeps ticking while the REPL
  is blocked on a modal.
- **arming fails open**: a missing plugin dir, a malformed manifest, a
  manifest naming a non-existent command, and a command that exits at once
  all start a session that takes turns. The launcher additionally
  pre-validates and omits the flag on any doubt.
- **mid-turn delivery**: a line emitted during a 100 s foreground tool call
  was surfaced inside that turn, after the tool result and before the
  model's reply — not deferred to idle (n=1).
- the monitor inherits the launcher's environment (`NEXUS_ROOT`,
  `NEXUS_WORKER_WINDOW`, `CLAUDE_CODE_SESSION_ID`) and runs in the session cwd.
- **not measured**: an upper bound on delivery (33–41 min are lower bounds);
  behaviour under `over-limit`; more than one build.

## cc-update collision surface

`experimental.monitors` is EXPERIMENTAL; the top-level `monitors` form is
already announced for removal, and `CLAUDE_CODE_SESSION_ID` / the
`· N monitor ·` footer token are harness strings. The collision-list entry is
`skills/nexus.cc-update/GUIDE.md` 2g. The day the host stops arming plugin
monitors, three detectors that are not the dispatcher notice: every `add`
prints NOT ARMED (rc 3), `ng longjob status` reads `absent`, and the footer
stops showing `1 monitor` on fresh sessions (pane-state's fixture
`idle-longjob-dispatcher-armed-realmodel-272.ansi` pins the current rendering).

## Second tenant: a level-triggered tick

The `cmd:` kind with `--persistent` expresses "run this every 60 s and emit
when it says DOWN" — the in-session leg `<your-org>/<your-nexus>#375` asked for:

    monitor/ng longjob add cmd:'monitor/watcher-supervise-tick.sh; case $? in 0) exit 1;; *) exit 2;; esac' \
        --persistent --interval 60 --desc "watcher liveness"

alive → `running`, down → `failed`; the dispatcher emits on each transition
(down, and recovery) and never retires the watch, so the detector survives its
own fire.

## Files

- `monitor/longjob-watch.sh` — the tool and the dispatcher (`ng longjob`)
- `monitor/longjob-probes.d/<kind>.sh` — one probe per subject kind; adding a
  kind is one file implementing `lj_probe_main <target> <spec> → state|detail`
- `monitor/longjob-plugin/` — the plugin manifest + `dispatch.sh`
- `monitor/_longjob-plugin.sh` — the fail-open launcher helper
- `config/nexus.example.yml` `monitor.longjob.*` — kill switch, caps, cadence
- suites: `test-longjob-watch.sh`, `test-longjob-plugin-arming.sh`,
  `test-pane-state-longjob-discount.sh`
