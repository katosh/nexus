# Upgrading

How a running nexus picks up new code, and specifically how a
deployment on the old **watcher-in-a-window** setup converges to the
current **headless service** hosting.

> **Derived at `main` @ `e382e9fd`** — the 2026-09-04 promotion. The previous
> derivation was `ca6205c8` (2026-08-28, PR `#1172`), so this revision closes a
> **444-commit** delta, of which **395** touched `monitor/`
> (`git rev-list --count ca6205c8..e382e9fd`, and the same with `-- monitor`;
> `ca6205c8` is an ancestor of `e382e9fd`, so the range is a real timeline).
>
> **Re-derive this page from the tree, not from the page.** A doc page's own
> staleness is invisible from inside it: the previous revision described a
> candidate 444 commits behind while reading as current, and nothing said so
> until somebody measured (<your-org>/nexus-code#1466). Restate this line at
> every promotion — it is what lets the next one measure its own drift in one
> command instead of rediscovering it.

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

## Upgrading across a large jump

The routine above assumes you pull often. A clone that has sat on a
release branch for weeks is a different operation: the gap is not a
bigger version of the same pull, it is a pull that crosses tooling
which did not exist when you last synced. Nothing here is a migration
step — there is **no config migration** and no manual data conversion
— but several commands that used to fail quietly, or not exist, now
**refuse loudly**, and a refusal you have never seen reads like a
break.

**Config: no key you must add.** `config/nexus.example.yml` carries
the same six top-level keys it always has. It grew substantially
(1709 -> 1995 lines between the 2026-08-28 `main` and `dev` tips) but
entirely in sub-keys and commentary, all of which have defaults. An
existing `config/nexus.yml` keeps working untouched. Diff the example
against your own config if you want the new knobs; you do not need
them to come up.

**What to do first, in order:**

1. `git -C <nexus-root> pull`.
2. `monitor/assert-shims-wrapped.sh` — see below. Run it *before* you
   trust any subsequent `gh` write. It is new, and it is the one check
   that fails loudly for a problem that is otherwise silent.
3. `monitor/svc.sh status` — every registry service should be `UP`.
4. `monitor/ng watcher-status` — expect exit 0 and `hosting: headless`.

## Loud refusals you may meet after upgrading

Each of these is a **deliberate refusal**, not a crash. The exit code
is the message. They are listed with what is genuinely new relative to
an older clone, because a refusal from a tool you did not know existed
is the one most likely to be misread as a regression.

### `monitor/assert-shims-wrapped.sh` — exit 0 / 1 / 79

New. Every agent launcher runs it as a spawn-time precondition and
refuses to spawn if the PATH-front `gh` shim is unreachable in a
spawned shell. **Exit 79 is the one to understand: "NOT CHECKED".**
It means the script could not examine the shims at all, and it is
deliberately *not* 0 — three states are not two, and a check that
could not run must never read as a check that passed. Exit 1 is a
genuine failure (the shim is reachable and wrong); exit 0 is a pass.

`monitor/assert-gh-wrapped.sh` still exists as a deprecated forwarder,
so old call sites keep working. Both files are new relative to a clone
predating this change — if neither is present in yours, every write
your agents make is running unverified.

### `monitor/spawn-worker.sh` — exit 19 and exit 78

Both new refusals in a script you already have, which is why they
surprise.

- **Exit 19** — `NEXUS_STATE_DIR` is set but not creatable or
  writable. It refuses rather than silently falling back to
  `$NEXUS_ROOT/monitor/.state`. A caller that pinned the state dir has
  already concluded it is isolated; honouring the pin or failing are
  the only safe options.
- **Exit 78** — the shim guard template
  (`monitor/guard-block.sh.in`) is missing or unreadable. An empty
  guard block is a guard that does not run, so it refuses to spawn
  instead of emitting one.

If you vendor or symlink parts of `monitor/`, these two are the
refusals a partial copy will produce.

### `monitor/guards-for-diff.sh` — six exit codes, none of them a clearance

New. Reports which registered guards read the files you changed;
`--run` runs exactly those. It has **six** exit codes, and the
authoritative list is the `# Exit codes:` block in the header of
`monitor/guards-for-diff.sh` — read it there rather than trusting a
copy. The point for an upgrade reader is that **not one of them is a
merge clearance**, including the green:

| Exit | Meaning |
|---|---|
| 0 | Some declaring guard read a file you changed (and under `--run` they all passed). **Not a clearance** — a suite that declares no population is invisible to the index, appearing in neither the selected nor the excluded list. Read the tool's own blind-spot count, not this code. |
| 1 | `--run`: a selected guard FAILED. |
| 2 | REFUSED — a guard's population probe errored, or the diff could not be computed. Fail-closed on purpose. |
| 3 | No registered guard reads your diff. A measured answer, not a green light. |
| 4 | `--run`: green but UNVERIFIED — at least one guard answered about a tree that does not contain your untracked files. `git add` and re-run. |
| 5 | `--run`: the `--timeout` deadline expired with selected guards left WITHOUT A VERDICT (never started, or cut off mid-run). They are named. A guard that did not finish is not a guard that passed. |

### `monitor/tmux-socket-fits.sh` — exit 3

New. A unix socket path holds 107 usable bytes (`sun_path` is 108
including the NUL). tmux composes
`${TMUX_TMPDIR:-/tmp}/tmux-<uid>/<socket-name>`, so a long
`TMUX_TMPDIR` puts you over before the suffix is added. Exit 3 means
the path does not fit, and names the measured length; `--suggest`
prints a directory that does. `monitor/watcher/run-tests.sh` now
refuses such a run outright rather than dispatching suites that would
all fail `File name too long` and be misread as code defects.

Keep `TMUX_TMPDIR` short — `/tmp/<something-brief>`.

### `monitor/mutation-gate.sh` — exit 3 / 5

New. Use it instead of hand-rolling a mutation test. Exit 3 refuses a
mutation it will not perform — notably commenting a line that does not
end a logical line, which does not delete that line but *promotes* the
next one to a standalone command. Exit 5 is the free-space halt.
Independently of the refusal, it bounds every mutant with `timeout`,
`ulimit -f` and a free-space floor.

### `monitor/public-mirror/build.sh` — exit 6 / 7

New refusals in an existing script, and worth reading before you run
it: **it destroys the checkout it is invoked from.** It now dry-runs
by default (exit 6) and refuses a dirty tree (exit 7) unless
`--allow-dirty`. Use a throwaway clone.

### `monitor/proc-kill-authorized` and `monitor/proc-exists-authorized`

New. Both replace hand-rolled `ps | grep` predicates, which cannot
distinguish a process from another agent's *description* of it — an
agent's argv is its prompt. `proc-kill-authorized --filter` prints
only pids whose session is yours and names every refusal.
`proc-exists-authorized` owns its own wait loop, so the polarity
cannot be inverted, and returns **rc 3 for "refused / could not
determine"** — neither present nor absent, which is what stops a
shell `until`/`while` from reading a refusal as an answer.

Sharpened since the previous derivation: a **bare `--pid` on a number that
is currently occupied** now STOPS the wait at **rc 3** rather than running
to **rc 4 (timeout)**. Pid numbers are recycled, so a bare pid is not an
identity — pass `--start-time` with it. The old reading was the worse of the
two: a timeout looks like *"the thing is still running"*, when the truth was
*"I cannot tell which process this number refers to"*.

### `monitor/async-run.sh` — exit 9, and 6 / 7 / 8 on the status side

New since the previous derivation. The launcher that keeps a background
job's **exit status**, which a bare `nohup … &` destroys. Two refusal
families, and they answer different questions:

* **exit 9 — REFUSED, an identical job is already running.** Same argv, same
  window. This is the duplicate-launch guard; it is not a failure to launch.
* **exit 6 / 7 / 8 on `--signal` and status verbs.** `6` DENIED (the token
  belongs to a *different session*), `7` REFUSED (ownership could not be
  determined), `8` REFUSED (the recorded pid's identity could not be
  verified — nothing was signalled). `5` is the plain "no such token in this
  window's namespace", and `4` means signalled but **still alive** after TERM
  and KILL.

Note the shape shared by 7 and 8: *could not determine* is its own answer and
is never folded into *absent*. `--help`/`-h` answer at exit **0** and are
resolved **before** the context gate, so asking for usage outside a nexus
context is not itself a refusal.

### `monitor/declare-no-wait.sh` — exit 4 and exit 5

New. Marks an async launch as deliberately fire-and-forget.

* **exit 4 — the write happened and MATCHED NOTHING.** Not an error, and
  deliberately not exit 0: a dismissal that dismissed nothing is a typo in
  the `(kind, id)` you passed, and returning 0 would let it read as done.
* **exit 5 — REFUSED, the heartbeat file EXISTS but does not parse.** The
  distinction that matters: an unparseable heartbeat is not an absent one,
  and treating it as absent is how a live wait gets declared finished.

### `monitor/svc.sh` — an unreadable registry does not render as an empty one

Not an exit code — a rendering change you may notice and misread. When
`monitor/services.registry` exists but cannot be read, the cockpit now says
so instead of printing an empty service list. *"You have no services"* and
*"I could not read your services"* are different sentences, and the old
behaviour said the first when it meant the second.

### What did *not* change

`config/load.sh --check-identity` still exits 4 on placeholder
identity keys. That behaviour predates this jump and is called out
only because it is easy to attribute to the upgrade when you meet it
for the first time.

**Your config needs no edit.** Across the whole 444-commit delta
`config/nexus.example.yml` gained exactly **one** key and changed nothing
else — verified by
`diff <(git show ca6205c8:config/nexus.example.yml) <(git show e382e9fd:config/nexus.example.yml)`,
whose entire output is that one addition:

* `cc_auto_update.restart_pr_active_seconds` (default `604800`, env
  `CC_AUTO_GATE_RESTART_PR_ACTIVE_SECONDS`) — how long an open PR touching
  the watcher **restart path** counts as "under repair". The arm previously
  had no recency bound at all, so a stalled cosmetic PR could block the
  cc-update routine indefinitely while the broader `pr_active_seconds`
  (default `7200`) aged everything else out. Deliberately far longer,
  because a restart-path PR is categorically more dangerous.

It is optional: the default is compiled in, so an untouched config keeps
working. Stating this positively is the point — "no config changes" is the
sentence an upgrade page most often carries forward without re-checking.

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
