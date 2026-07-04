# Watcher scheduling refactor — design proposal (IMPLEMENTED)

> **Status: IMPLEMENTED — historical.** The scheduling refactor this
> document proposed has fully landed. The single-loop priority queue
> (Option A below) is the production implementation in
> `monitor/watcher/_scheduler.sh`; `main.sh` drives only the
> scheduler, registering every check as a per-task entry with its own
> cadence. No `MONITOR_SCHEDULER` v1/v2 gate remains — there is no
> v1 single-cadence loop to fall back to — and the scheduler is
> covered by `monitor/watcher/test-scheduler-priority-queue.sh` and
> `monitor/watcher/test-v2-staging-tasks.sh`.
>
> This proposal is retained **only for historical context** — the
> motivation, the architectural bake-off, and the §5 sketch that
> `_scheduler.sh`'s header still references. For the **current**
> scheduler model — the live task→cadence table, the async-staging
> and back-pressure mechanics, and how `compose_emit` is pulled
> forward — see [Watcher protocol](reference/watcher-protocol.md),
> which is the authoritative spec. The detail below describes the
> design as proposed and may diverge from the shipped code (e.g. the
> production task set and exact cadences live in `main.sh`, not here).
>
> This page is not in the mkdocs nav. Whether to delete it outright
> is left to a future integrator.

Tracks: [`<your-org>/nexus-code#169`](https://github.com/<your-org>/nexus-code/issues/169).

---

## 1. Motivation (as proposed)

`monitor/watcher/main.sh` today runs every check on a single
`MONITOR_INTERVAL` cadence (default 60 s). One coarse cadence governs
every signal from `tmux list-windows` (sub-millisecond) to the three
GraphQL surfaces (seconds, rate-limit-bounded) to per-pane probes
across every worker window (tens of seconds at scale).

Quoting issue #169:

> Forcing everything onto the slowest cadence sacrifices snappiness
> on the cheap checks; forcing everything onto the fastest cadence
> exhausts the GraphQL bucket within minutes. […] An orchestrator gone
> for a minute is a minute of missed pastes even though presence is a
> microsecond `tmux list-windows` away.

Empirical measurements taken from the live nexus workspace
(17 worker windows, 22 `work/*` clones, 624 reports, ~800 archived
diffs; one-shot sources of each function timed in isolation):

| Check                          | Today's cadence | Measured cost      |
| ------------------------------ | --------------- | ------------------ |
| `bump_heartbeat`               | every cycle     | <1 ms              |
| `prune_archive`                | every cycle     | ~50 ms             |
| `detect_and_unstick`           | every cycle     | ~0.9 s             |
| `_over_limit_scan_panes`       | every cycle     | **~7.3 s**         |
| `_over_limit_process_wakes`    | every cycle     | <1 ms (no-op idle) |
| `_target_window_present`       | every cycle     | ~55 ms             |
| `_orchestrator_liveness_step`  | every cycle     | ~30 ms             |
| `snapshot_local`               | every cycle     | **~7 s**           |
| `snapshot_github_combined`     | every 5th cycle | **~8 s**           |
| `list_bell_windows`            | every cycle     | ~55 ms             |
| `render_idle_section`          | every cycle     | **~20 s**          |
| `render_pending_decisions`     | every cycle     | ~10 ms             |
| `render_full_state_snapshot`   | every 600 s     | ~6 s               |
| `render_idle_prelude` (per emit) | per emit      | **~20 s**          |
| `_classify_diff` (per non-empty diff) | per cycle | ~10 ms             |
| `paste_to_target` (per emit)   | per emit        | ~0.5 s             |

The aggregate non-sleep work per cycle, when every check is due, is
30–60 s. With `sleep 60` on top, the real wall-clock cycle is roughly
90–120 s. Three independent costs dominate: the per-pane probes
(`_over_limit_scan_panes`, `render_idle_section`, `render_idle_prelude`,
`detect_and_unstick` — four independent passes over every worker
window per cycle), the per-clone `git status` inside `snapshot_local`,
and the GraphQL surfaces inside `snapshot_github_combined`.

A scheduling refactor cannot itself eliminate the cost of any single
check, but it allows three things the current single-cadence loop
cannot:

1. **Lower latency on the cheap checks.** A 2-second
   `_target_window_present` cadence means a dead orchestrator is
   detected at most ~2 s after it vanishes, not 60–120 s.
2. **Raise cadence sanity on the expensive ones.** The 20 s
   `render_idle_section` does not need to fire every poll; once every
   30 s is fine, and freeing those 20 s lets cheaper checks run more
   often without raising total throughput.
3. **Independent back-pressure.** A GraphQL rate-limit event should
   suppress the GraphQL polling task on its own schedule, not the
   entire loop. The current `_graphql_backoff_active` already encodes
   this at per-surface granularity; the scheduler makes it a
   first-class concept.

## 2. Catalog of existing checks

Every check the current loop fires, ordered as it appears in
`main.sh`. "Ideal cadence" is the largest interval that still meets
the user-facing latency goal stated in the issue.

| # | Check | Current cadence | Measured cost | Ideal cadence | Cost class | Notes |
|---|---|---|---|---|---|---|
| 1 | `bump_heartbeat` | every cycle | <1 ms | 5 s | cheap | Faster cadence improves stale-watcher detection from agents. |
| 2 | `prune_archive` | every cycle | ~50 ms | 600 s | cheap | `find -mtime`; archive churn is slow. |
| 3 | `detect_and_unstick` | every cycle | ~0.9 s (AUTO_UNSTICK=true, no wedge today) | 10 s | medium | Recovery cadence. Faster than today; wedge-detection benefits from 5–15 s. Worst case (active unstick + ack-poll) is multi-second. |
| 4 | `_over_limit_scan_panes` | every cycle | ~7.3 s | 60 s | expensive | Probes every worker pane for the `Claude AI usage limit reached \| <epoch>` footer. Rarely transitions; 60 s plenty. |
| 5 | `_over_limit_process_wakes` | every cycle | <1 ms (no-op when idle) | 5 s | cheap | Reads state file, acts on due wakes. Cheap; benefits from snappier cadence to honour scheduled epochs. |
| 6 | `sleep INTERVAL` | every cycle | 60 s | n/a — scheduler-driven | — | Replaced by the scheduler's dynamic sleep. |
| 7 | `_target_window_present` (poll-classification) | every cycle | ~55 ms | **2–5 s** | cheap | The motivating example: orchestrator absence under cadence floor. |
| 8 | `_orchestrator_poll_refresh_pin` | every cycle | ~10 ms | 60 s | cheap | Refreshes pin's mtime when jsonl is fresh; not latency-critical. |
| 9 | `_orchestrator_liveness_step` | every cycle | ~30 ms | 5–10 s | cheap | Three file stats + a decision. Faster cadence detects wedges quicker. |
| 10 | `snapshot_local` | every cycle | ~7 s | 30 s | medium | `git status` across all `work/*` is the long pole. Could parallelise per-clone (orthogonal optimisation). |
| 11 | `snapshot_github_combined` | every 5th cycle (~300 s) | ~8 s when due | 60–120 s | expensive | Already cadence-throttled via `MONITOR_GRAPHQL_CADENCE`. Preserve under the scheduler; expose as `task.interval`. |
| 12 | `list_bell_windows` | every cycle | ~55 ms | 30 s | cheap | Bell events are user-noise; quick cadence preferred for snappy clear. |
| 13 | `render_idle_section` | every cycle | ~20 s | 30 s | expensive | Per-pane probes dominate. Implementation PR should cache pane-state across callers (see §8). |
| 14 | `render_pending_decisions` | every cycle | ~10 ms | 5–10 s | cheap | Scans `monitor/.state/decisions/`; new prompt should surface fast. |
| 15 | `render_full_state_snapshot` | per `full_state_due` (every 600 s) | ~6 s | 600 s | expensive | Already periodic; preserve cadence under the scheduler. |
| 16 | `render_idle_prelude` (called by `compose_report`, per emit) | per emit | ~20 s | per emit, with cache | expensive | A naive scheduler does not change this — `compose_report` calls it inline. The fix is structural: cache the prelude output keyed by `now / cadence_bucket` so repeated emits inside one window reuse it. Listed here so the catalog is complete; the scheduler enables this fix but does not contain it. |
| 17 | `_classify_diff` | per non-empty local diff | ~10 ms | inline | cheap | Runs as part of the `snapshot_local` task. |
| 18 | `compose_report` + `paste_to_target` + `archive_emit` | per emit | ~0.5 s | emit-driven | inline | Naturally event-driven (emit signal), not scheduler-driven. The scheduler emits a `compose_and_paste` task at most once per task-tick from each upstream snapshot task. |

Two structural notes worth surfacing inline:

- **Per-pane probe redundancy.** Items 3, 4, 13, and 16 each
  independently traverse every worker window and call `pane-state.sh`.
  With 17 worker windows that is ~68 pane probes per cycle when
  nothing actually transitions. The scheduler enables, but does not
  perform, a cross-task probe cache (see §8 "Open questions").
- **Compose-time work.** Item 16 (`render_idle_prelude` inside
  `compose_report`) and the second invocation of `render_full_state_snapshot`
  at compose time both duplicate work the loop has already done.
  These are emit-time, not poll-time, so they're not direct candidates
  for scheduling — they're candidates for caching, which §8 lists as
  follow-up work.

## 3. Architectural options compared

Four patterns were named in the issue. Each is evaluated against the
codebase's existing shape: Bash, single-process, mock-tmux test
harness in `monitor/watcher/test-*.sh`, agent-sandbox runtime
(no extra binaries to install), and the existing helper-file split
(`_lib.sh` / `_github.sh` / `_unstick.sh` / `_idle_probe.sh` /
`_orchestrator_liveness.sh` / `_over_limit.sh`).

### Option A — single-loop priority queue

Maintain an associative array `next_fire[$task] = <epoch>` keyed by
task name. Each iteration: scan, fire every due task, recompute
`next_fire`, sleep until the soonest among the remaining.

**Gains.** Pure Bash. Composes cleanly with the existing helper
decomposition — every helper function becomes a registered task with
no signature change. Adaptive intervals are a one-line override. Test
harness needs only an injectable clock and a "force-fire" hook.
Cadence is precise to the second.

**Costs.** Bash associative arrays are 4-ish lines of boilerplate per
task. The loop's scan cost grows linearly with the task count, but
the task count is small (≤20). No concurrency means two
back-to-back-due slow tasks still serialise — fine, the current loop
already serialises them.

**Interaction with existing helpers.** None of `_unstick.sh`,
`_idle_probe.sh`, `_orchestrator_liveness.sh`, `_github.sh` need
restructuring: each entry-point function (`detect_and_unstick`,
`render_idle_section`, `_orchestrator_liveness_step`,
`snapshot_github_combined`, …) becomes one registered task.

**Failure modes.** A task that overruns its interval — `next_fire`
math handles the catch-up. A signal mid-task — runs to completion;
SIGTERM/SIGINT trapped at loop top with cooperative shutdown
(matching current behaviour).

### Option B — tiered cadence groups (fast / medium / slow)

Bin every check into one of three tiers; main loop's `MONITOR_INTERVAL`
becomes the fast tier; medium and slow tiers fire every Nth iteration.

**Gains.** Simpler than A: no per-task state. Already partially
implemented (today's `MONITOR_GRAPHQL_CADENCE` is exactly this for
GraphQL). Migration is essentially free.

**Costs.** Coarser. Bins are easy to reason about but easy to misuse —
the `bump_heartbeat` (5 s) and `_target_window_present` (2 s) gap
already crosses a tier boundary in this model and forces one of them
to use the wrong cadence, or forces a fourth tier. Adaptive intervals
do not compose naturally: an override that says "fire `window-present`
every 1 s for the next 30 s" cannot be expressed as a tier shift.
Backpressure on GraphQL is naturally per-surface, not per-tier.

**Interaction with existing helpers.** Easiest of the four; just gate
each helper invocation behind a `(( cycle % tier_N == 0 ))` check.

**Failure modes.** When a task overruns its tier interval, the next
iteration's cycle counter is already past its slot — silently skipped
or fires immediately on the next-due tier? Either choice is defensible,
both are surprising. No first-class scheduling means no observable
"next fire" introspection — operators reading logs see "every Nth
cycle" and have to do arithmetic.

### Option C — event-driven via `inotify`

Use `inotifywait` for filesystem-event sources (`monitor/.state/decisions/`,
`monitor/.state/heartbeat/`); keep time-based polling for everything
else (GraphQL, periodic git status).

**Gains.** Decisions surface within milliseconds of being written. Best
expressiveness for filesystem-event signals.

**Costs.** Adds an `inotifywait` binary dependency that the
agent-sandbox runtime is not guaranteed to have. Mock-tmux fixtures
already exist in `monitor/watcher/test-*.sh`; mock-`inotifywait` would
have to be invented. Most checks are not filesystem-event-driven —
`pane-state.sh` reads from the live tmux server, not from a file the
worker writes; `tmux list-windows` is a server query, not an fs event;
GraphQL is network. The scope of benefit is one or two checks
(decisions, possibly heartbeat).

**Interaction with existing helpers.** Adds a parallel control-flow:
some checks fire on events, others on intervals. The combined dispatch
loop is two loops, or one loop with `inotifywait -t <interval>` as the
sleep — either way, debugging dispatch order becomes harder.

**Failure modes.** `inotifywait` death is a silent dead branch. Event
floods (a worker that writes `decisions/*.json` rapidly) can blast the
queue. Mock fixtures grow.

### Option D — background workers per cost class

Spawn one bash subshell per cost tier. Each runs its own loop at its
own cadence; emits output to a shared FIFO that `main.sh` reads.

**Gains.** True concurrency. Slow GitHub poll runs without blocking
the fast `_target_window_present` check. Cost-class budgets are
naturally enforced (one subshell can't starve another).

**Costs.** Bash signal handling across subshells is fragile: SIGTERM
to the parent must propagate to every child; orphaned children on a
hard kill linger. FIFO drains need careful synchronisation (POSIX
guarantees atomicity only for writes ≤PIPE_BUF). Shared state on disk
needs locks (today's lockfile guards two watchers; now it must guard
N child workers per watcher). Test harness must mock subshell
lifecycles, FIFOs, and signals.

**Interaction with existing helpers.** Every helper that writes shared
state (`render_idle_section` writes idle-state files;
`detect_and_unstick` writes unstick markers) now races against other
workers. Audit and lock-discipline rewrite is non-trivial.

**Failure modes.** A wedged child silently stops emitting; the parent
has no clean way to notice without a watchdog timer per child. SIGTERM
during a paste is now two race conditions (paste in subshell A, paste
in subshell B). The complexity tax is real.

## 4. Recommended option — single-loop priority queue (Option A)

Recommended for these reasons, in priority order:

1. **It fits Bash.** A single associative-array map + a single sleep
   is the smallest delta from today's loop that delivers per-task
   cadence. No subshells, no FIFOs, no inotify.
2. **It composes with the existing helper decomposition.** The
   refactor is "register every helper as a task and replace the
   sleep/dispatch block". No helper signatures change.
3. **It composes with the existing mock-tmux test harness.** Tests
   already inject `PATH`-prepended `tmux` and `gh` stubs; the only
   new mock surface is an injectable clock (`NEXUS_TEST_NOW` env var).
4. **Adaptive intervals and per-task back-pressure fall out
   naturally.** An override is `next_fire[$task] = now + n`; a
   back-pressure signal from a task is an exit code the scheduler
   interprets as "double the interval once".
5. **Observable.** The scheduler logs every fire with `task=<name>
   rc=<code> elapsed_ms=<N>`; operators see exactly when each check
   ran and how long it took. Today's "every Nth cycle" arithmetic
   disappears.

Option B is the credible fallback. It's simpler but coarser, and the
two motivating cadences (2 s window-present vs 5 s heartbeat-bump)
already make the three-tier model awkward. Option C is rejected on
binary-dependency grounds. Option D is rejected on signal-handling
and lock-discipline complexity grounds.

## 5. Concrete sketch

### 5.1 Data structures

Eight associative arrays in scheduler-local scope (declared in
`_scheduler.sh`, sourced once at watcher startup):

```bash
declare -A TASK_FN           # name → registered function symbol
declare -A TASK_INTERVAL     # name → base interval seconds
declare -A TASK_NEXT_FIRE    # name → epoch
declare -A TASK_LAST_FIRE    # name → epoch (telemetry)
declare -A TASK_LAST_RC      # name → last exit code
declare -A TASK_LAST_ELAPSED # name → last duration in ms (telemetry)
declare -A TASK_CLASS        # name → cheap|medium|expensive
declare -A TASK_OVERRIDE_TIL # name → epoch; while now < this, override interval applies
declare -A TASK_OVERRIDE_INT # name → override interval seconds (paired with TASK_OVERRIDE_TIL)
declare -A TASK_ENABLED      # name → 1/0; gates whole task without unregistering
```

All bookkeeping lives in memory inside the watcher process. There is
no on-disk scheduler state — the scheduler is rebuilt at every
restart from the (static) task-registration calls.

### 5.2 Helper API

Three public functions are exported from `_scheduler.sh`:

```bash
# Register a task. Idempotent; overwrites prior registration of the
# same name (useful for a SIGHUP reload).
_schedule_task <name> <interval_sec> <fn> [--class cheap|medium|expensive] [--disabled]

# Apply a temporary cadence override. Until `now + duration_sec`,
# the task fires every `override_interval_sec` instead of its base.
# Stacking calls overwrite the override window (latest wins).
_schedule_override <name> <override_interval_sec> <duration_sec>

# Force the named task to fire on the next tick regardless of next_fire.
# Used by tests and by hand from operator-introspection tools.
_schedule_fire_now <name>
```

A fourth, `_scheduler_tick`, is the public iterator. It is normally
called only by the main loop in `main.sh`, but tests call it directly
(with the clock injected) to simulate cadence.

### 5.3 Main-loop pseudocode

```bash
# In main.sh, replacing the current `while true; do … sleep $INTERVAL`
# block. Each registration corresponds to one row in §2.
_schedule_task bump_heartbeat              5    bump_heartbeat                  --class cheap
_schedule_task prune_archive              600   prune_archive                   --class cheap
_schedule_task target_window_present        2   _scheduled_target_window_check  --class cheap
_schedule_task orchestrator_liveness        5   _scheduled_orchestrator_step    --class cheap
_schedule_task pending_decisions            5   _scheduled_pending_decisions    --class cheap
_schedule_task bell_windows                30   _scheduled_bell_windows         --class cheap
_schedule_task pin_refresh                 60   _scheduled_pin_refresh          --class cheap
_schedule_task over_limit_wakes             5   _over_limit_process_wakes       --class cheap
_schedule_task detect_unstick              10   detect_and_unstick              --class medium
_schedule_task snapshot_local              30   _scheduled_snapshot_local       --class medium
_schedule_task idle_section                30   _scheduled_idle_section         --class expensive
_schedule_task over_limit_scan             60   _scheduled_over_limit_scan      --class expensive
_schedule_task github_poll                 60   _scheduled_github_poll          --class expensive
_schedule_task full_state_emit            600   _scheduled_full_state_emit      --class expensive

while true; do
    _scheduler_tick   # fires every due task, returns the next sleep delay
    rc=$?             # 99 ⇒ shutdown requested by a task; anything else ⇒ continue
    (( rc == 99 )) && break
    _scheduler_sleep_until_next   # interruptible sleep
done
```

Each `_scheduled_*` shim is a thin adapter: it calls the underlying
helper, captures stdout into the cycle's emit-staging buffers, and
returns the helper's rc (mapped to the scheduler's back-pressure
codes; see §5.6). The emit/paste path is not in the scheduler — it
runs at the end of every `_scheduler_tick` if any snapshot task wrote
to the staging buffers, and `compose_report` + `paste_to_target` fire
at most once per tick.

`_scheduler_tick`'s body (pseudocode):

```bash
_scheduler_tick() {
    local now name nf rc elapsed_ms soonest
    now=$(nexus_clock)
    for name in "${!TASK_FN[@]}"; do
        (( TASK_ENABLED[$name] == 1 )) || continue
        nf=${TASK_NEXT_FIRE[$name]:-0}
        (( nf > now )) && continue

        local start_ns end_ns
        start_ns=$(date +%s%N)
        "${TASK_FN[$name]}"; rc=$?
        end_ns=$(date +%s%N)
        elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

        TASK_LAST_FIRE[$name]=$now
        TASK_LAST_RC[$name]=$rc
        TASK_LAST_ELAPSED[$name]=$elapsed_ms
        TASK_NEXT_FIRE[$name]=$(_scheduler_next_fire "$name" "$rc")
        _scheduler_log_fire "$name" "$rc" "$elapsed_ms"
    done
    _scheduler_post_tick_emit_if_pending   # composes + pastes if any task staged a signal
    return 0
}
```

### 5.4 Time injection

```bash
nexus_clock() {
    if [[ -n "${NEXUS_TEST_NOW:-}" ]]; then
        printf '%s\n' "$NEXUS_TEST_NOW"
    else
        date +%s
    fi
}
```

Every wall-clock read in the scheduler routes through this. Tests
set `NEXUS_TEST_NOW=$((NEXUS_TEST_NOW + delta))` between
`_scheduler_tick` calls to simulate elapsed time.

### 5.5 Adaptive intervals

A task that wants tighter cadence after an observed condition calls:

```bash
# After a paste-to-target failure, run window-present every 1 s for
# the next 30 s in case the orchestrator is mid-respawn.
_schedule_override target_window_present 1 30
```

The next-fire computation consults the override window:

```bash
_scheduler_next_fire() {
    local name="$1" rc="$2" now interval
    now=$(nexus_clock)
    if (( ${TASK_OVERRIDE_TIL[$name]:-0} > now )); then
        interval=${TASK_OVERRIDE_INT[$name]}
    else
        interval=${TASK_INTERVAL[$name]}
        # Auto-clear an expired override so future fires don't have
        # to keep checking.
        unset TASK_OVERRIDE_TIL[$name]
        unset TASK_OVERRIDE_INT[$name]
    fi

    # Back-pressure on transient failure: rc=75 (EX_TEMPFAIL) doubles
    # the interval for the next fire, capped at 4×.
    if (( rc == 75 )); then
        local capped=$(( interval * 4 ))
        interval=$(( interval * 2 ))
        (( interval > capped )) && interval=$capped
    fi

    # If already overdue, fire next tick instead of in the past.
    local candidate=$(( ${TASK_LAST_FIRE[$name]} + interval ))
    (( candidate <= now )) && candidate=$(( now + 1 ))
    printf '%s\n' "$candidate"
}
```

### 5.6 Back-pressure on expensive checks

`snapshot_github_combined` is the primary client. When a GraphQL
surface hits rate-limit, the existing `_watcher_handle_graphql_failure`
already writes the `graphql-backoff-<surface>` file. We add: on
return, the GraphQL task exits with rc=75. The scheduler doubles its
interval once (60 s → 120 s for the next fire). The per-surface
backoff file is unchanged; it just gives the new fire one more
chance to dodge the still-active per-surface backoff.

For the catastrophic case (every surface in backoff), the GraphQL
task short-circuits cheaply (it reads the backoff file before any
network call) and returns rc=0. Back-pressure is asymmetric on
purpose: detected rate-limit ⇒ slow down once; persistent backoff ⇒
cheap polls, normal cadence.

### 5.7 Signal handling

```bash
_scheduler_shutdown_requested=0

trap '_scheduler_shutdown_requested=1' SIGTERM SIGINT
trap '_scheduler_reload'              SIGHUP

_scheduler_sleep_until_next() {
    local now soonest delay
    now=$(nexus_clock)
    soonest=$(_scheduler_soonest_next_fire)
    delay=$(( soonest - now ))
    (( delay < 1 )) && delay=1
    (( delay > MONITOR_SCHEDULER_MAX_SLEEP )) && delay=$MONITOR_SCHEDULER_MAX_SLEEP
    sleep "$delay" &  # backgrounded so the wait is signal-interruptible
    wait $! 2>/dev/null
    (( _scheduler_shutdown_requested == 1 )) && return 99
    return 0
}
```

`MONITOR_SCHEDULER_MAX_SLEEP` (default 10 s) caps the sleep so a
process-level signal is observed within a bounded interval even if
no task is due for several minutes. The `sleep &; wait $!` idiom is
the canonical Bash pattern for an interruptible sleep — a bare `sleep`
ignores SIGTERM until it returns.

A task fired mid-iteration runs to completion; the scheduler observes
the shutdown flag on the next loop boundary. This is identical to the
current loop's behaviour: there is no in-task interruption today and
the refactor preserves that contract.

### 5.8 Telemetry

Every fire writes a JSONL row to
`monitor/.state/watcher-scheduler.jsonl`:

```json
{"ts":"2026-05-21T18:42:07-07:00","task":"github_poll","rc":0,"elapsed_ms":7280,"next_fire":"2026-05-21T18:43:07-07:00"}
```

Rotation matches the existing `worker-notifications.jsonl` cap
(`MONITOR_NOTIFICATIONS_LOG_MAX_BYTES`). `ng watcher-status` learns a
new sub-command `--scheduler-fires` that prints the last N rows for
operator introspection.

## 6. Migration plan

The single hard constraint: the v1 loop must keep working until v2
has been operator-tested for one release cycle. Two clones of nexus
share state (the primary clone runs the watcher; this clone hosts
the proposal PR); we cannot tear out the loop the primary clone is
mid-cycle on.

### Phase 0 — this PR (proposal, no behaviour change)

- `docs/watcher-scheduling-refactor.md` — this design doc.
- `monitor/watcher/_scheduler.sh` — inert scaffold: declares the
  helper API as empty stubs that source-load successfully but are
  not wired into `main.sh`. A smoke test confirms the helpers are
  callable.

No behaviour change. The existing test suite remains green because
nothing in `main.sh` calls `_scheduler.sh` yet.

### Phase 1 — implementation PR

- Flesh out `_scheduler.sh` (the §5.3 body).
- Add `MONITOR_SCHEDULER` env var, defaults to `v1`.
- In `main.sh`, gate the new loop body behind `[[ "$MONITOR_SCHEDULER" == "v2" ]]`.
  Both v1 and v2 paths must produce identical emits for the same
  state — the regression test for this is "diff the
  `monitor/.state/diffs/*.md` archive across an A/B run on canned
  state".
- Add scheduler-specific tests under `monitor/watcher/test-scheduler-*.sh`:
  - Clock-injected basic fire / re-fire cycle.
  - Adaptive override applies and expires correctly.
  - Back-pressure rc=75 doubles interval once, recovers next fire.
  - SIGTERM during sleep terminates the loop within
    `MONITOR_SCHEDULER_MAX_SLEEP` seconds.
  - Force-fire ignores `next_fire`.
  - Task overrun: long task → next_fire honours base interval, no
    drift.

### Phase 2 — production cutover

- Flip `MONITOR_SCHEDULER` default to `v2` after one release of
  Phase 1 has soaked.
- Operator escape hatch documented:
  `MONITOR_SCHEDULER=v1` in `~/.config/agent-sandbox/sandbox.conf`
  (or `monitor.scheduler_version: v1` in `config/nexus.yml`) reverts
  to the old loop.
- Watch `monitor/.state/watcher-scheduler.jsonl` for outlier elapsed
  times across the soak. If any single task consistently exceeds its
  interval, retune the interval or move it to a longer cadence.

### Phase 3 — v1 removal

- After one release of Phase 2 with no v1 fallback reports, delete
  the v1 loop body, the `MONITOR_SCHEDULER` env var, and the v1
  test fixtures.
- Document `monitor.scheduler.*` config keys as canonical.

### Backward compatibility

`MONITOR_INTERVAL` keeps working as the **registration knob for the
default tick**: every v1 task that fires at "every cycle" today
registers at `MONITOR_INTERVAL` seconds under v2. Operators using
`MONITOR_INTERVAL=10` for snappier debug feel get exactly that
under v2 — the 14 tasks registered at the base interval all tick at
10 s; the per-task interval overrides only kick in when a task
explicitly opts out of the base.

`MONITOR_GRAPHQL_CADENCE` is folded into the v2 GraphQL task's
interval (`GRAPHQL_CADENCE * MONITOR_INTERVAL`). The legacy env var
keeps working and logs a deprecation once on startup.

## 7. Test strategy

The existing `monitor/watcher/test-*.sh` fixtures mock `tmux` and
`gh` via prepended `PATH`. The scheduler adds two new mock surfaces.

### Injectable clock

Every wall-clock read in `_scheduler.sh` routes through `nexus_clock`,
which honours `NEXUS_TEST_NOW`. Tests look like:

```bash
NEXUS_TEST_NOW=1000
_schedule_task probe 30 my_test_fn
_scheduler_tick
[[ "${TASK_NEXT_FIRE[probe]}" == "1030" ]] || fail "expected next=1030"

NEXUS_TEST_NOW=1030
_scheduler_tick
[[ "${TASK_NEXT_FIRE[probe]}" == "1060" ]] || fail "expected next=1060"
```

### Force-fire override

`_schedule_fire_now <name>` sets `TASK_NEXT_FIRE[$name] = 0` so the
next `_scheduler_tick` fires it. Used by tests that exercise a
specific task without advancing the clock past every other task's
next-fire.

### Adaptive-interval decay

```bash
NEXUS_TEST_NOW=1000
_schedule_task probe 10 my_test_fn
_schedule_override probe 1 5     # 1s cadence for 5 seconds
_scheduler_tick                  # fires at t=1000, next=1001 (override active)
NEXUS_TEST_NOW=1006
_scheduler_tick                  # fires at t=1006, override expired, next=1016
[[ "${TASK_NEXT_FIRE[probe]}" == "1016" ]] || fail
```

### Back-pressure

```bash
NEXUS_TEST_NOW=1000
ratelimit_task() { return 75; }
_schedule_task gh 60 ratelimit_task
_scheduler_tick                  # rc=75, next_fire = 1000 + 60*2 = 1120
[[ "${TASK_NEXT_FIRE[gh]}" == "1120" ]] || fail
NEXUS_TEST_NOW=1120
recovered_task() { return 0; }
_schedule_task gh 60 recovered_task   # rebind
_scheduler_tick                  # rc=0, next_fire back to base interval
[[ "${TASK_NEXT_FIRE[gh]}" == "1180" ]] || fail
```

### Per-task isolation

```bash
NEXUS_TEST_NOW=1000
_schedule_task fast 1  cheap_fn
_schedule_task slow 60 expensive_fn --class expensive

slow_fired=0; expensive_fn() { slow_fired=$((slow_fired+1)); return 0; }

for i in 1 2 3 4 5; do
    NEXUS_TEST_NOW=$((NEXUS_TEST_NOW + 1))
    _scheduler_tick
done
# slow fires only at the t=1060 boundary; not yet reached
[[ "$slow_fired" == "0" ]] || fail "expensive task fired prematurely"
```

### SIGTERM during sleep

Run `monitor/watcher/main.sh --once-scheduler` (a future test-only
flag added in Phase 1), send SIGTERM mid-sleep, assert exit within
`MONITOR_SCHEDULER_MAX_SLEEP + 1` seconds.

### Long-task drift

```bash
slow_fn() { sleep 0; NEXUS_TEST_NOW=$((NEXUS_TEST_NOW + 25)); return 0; }
_schedule_task drift 10 slow_fn
NEXUS_TEST_NOW=1000
_scheduler_tick    # fires at 1000, runs 25s synthetic, next = 1010 but 1010 < 1025 so next = now+1 = 1026
[[ "${TASK_NEXT_FIRE[drift]}" == "1026" ]] || fail
```

### Phase-1 regression test for v1/v2 parity

```bash
# Run v1 against canned state, archive emit body. Run v2 against
# same state, archive emit body. Diff — must match modulo timestamps
# and the new scheduler-jsonl row.
NEXUS_ROOT=$tmp1 MONITOR_SCHEDULER=v1 main.sh --once
NEXUS_ROOT=$tmp2 MONITOR_SCHEDULER=v2 main.sh --once
diff <(strip_timestamps "$tmp1/monitor/.state/diffs"/*.md) \
     <(strip_timestamps "$tmp2/monitor/.state/diffs"/*.md)
```

## 8. Open questions

These are honest uncertainties. The implementation PR should resolve
each one explicitly before deletion of the v1 path.

1. **Should the scheduler ever skip a task whose previous fire has
   not returned?** Today the loop serialises everything, so this can't
   happen — but if Phase-1 testing reveals that `render_idle_section`
   sometimes runs >30 s on a busy day, its next-fire would already be
   in the past when it returns. Options: (a) honour the catch-up (fire
   again immediately), (b) skip until the next aligned interval. I
   lean (a) since today's loop has the same catch-up behaviour. Worth
   confirming.

2. **Per-pane probe cache scope.** The biggest practical win sits
   outside the scheduler: today `_over_limit_scan_panes`,
   `render_idle_section`, `render_idle_prelude`, and `detect_and_unstick`
   each independently probe every worker pane. A cross-task cache
   keyed by `(window_name, cache_bucket = now / 5)` would let four
   callers share one probe per 5-second bucket. The scheduler **enables**
   this — adjacent fires sit in the same bucket — but does not
   contain it. Should the implementation PR include the cache, or
   should it be a separate follow-up? I lean separate: scoping risk.

3. **Should the GraphQL task fire even when its per-surface backoff
   is fully active?** Today the gate is checked inside the helper; the
   scheduler-level interval is the same as the gate's cadence. A
   refinement: if every surface is in backoff, the scheduler suspends
   the task entirely until the earliest reset; saves a no-op fire.
   Worth measuring but not load-bearing.

4. **`MONITOR_INTERVAL=1` debug mode.** Today setting interval=1 makes
   the loop tick once per second; useful for chasing a race. Under v2,
   the analogue is `MONITOR_SCHEDULER_MAX_SLEEP=1` plus every task's
   interval ≥1 — but tasks at interval 30 won't fire faster. Should
   `MONITOR_INTERVAL` debug-mode collapse every task to interval=1? I
   lean no (it would also trigger every GraphQL call once per second,
   exhausting the bucket within a minute), but the v1 debug semantics
   are worth a paragraph in the operator doc.

5. **Where do the snapshot tasks stage their output?** Today every
   helper writes stdout that `main.sh` captures into local variables
   (`gh_now=$(snapshot_github_combined)`). The scheduler shims have
   to put that output somewhere accessible to the post-tick emit
   step. Options: (a) per-task stdout files under
   `monitor/.state/scheduler-staging/`; (b) a single in-memory
   associative array indexed by task name. Option (b) is simpler but
   requires the helpers to keep returning stdout for the v1 path. I
   lean (b) with a thin wrapper inside each shim:
   `STAGED_OUTPUT[name]=$(helper_fn)`.

6. **`render_idle_prelude` invocation inside `compose_report`.** The
   scheduler doesn't change emit-time invocations. The 20-second
   prelude render happens whenever a paste fires, which under v2 may
   be more frequent (cheaper checks). The implementation PR must
   either cache the prelude's output (keyed by the upstream idle
   task's last_fire) or accept that emit cost stays at v1 levels. I
   lean: cache, but call it out as a measured-then-decided question
   in the v2 soak.

7. **Lockfile interaction.** The watcher's PID-based lockfile is per
   watcher, not per task. The v2 scheduler does not need additional
   locks because every task runs in the main process. Confirmed in
   §3 Option D rejection. No change required, but worth recording.

8. **`--once` semantics under v2.** Today `--once` runs one cycle and
   exits. Under v2, "one cycle" is ambiguous — one tick of the
   scheduler, or one fire of every task? I lean: one tick (the
   minimal observable unit). Tests that need every-task coverage
   set every task's interval to 0 before calling `_scheduler_tick`.

---

## Appendix A — relationship to existing helpers

| Helper file | Touched by this refactor? | How |
|---|---|---|
| `_lib.sh` | no | Untouched; the scheduler does not consume any helper from here. |
| `_github.sh` | no, except adapter shim | `_scheduled_github_poll` calls `snapshot_github_combined` and stages output. Helper unchanged. |
| `_unstick.sh` | no, except adapter shim | `detect_and_unstick` becomes a task; helper unchanged. |
| `_idle_probe.sh` | no, except adapter shim | `render_idle_section` / `render_pending_decisions` / `render_full_state_snapshot` become tasks. The cross-task probe cache (Open Q 2) would touch this file but is out of scope for the proposal. |
| `_orchestrator_liveness.sh` | no, except adapter shim | `_orchestrator_liveness_step` becomes a task. Helper unchanged. |
| `_over_limit.sh` | no, except adapter shim | `_over_limit_scan_panes` / `_over_limit_process_wakes` become tasks. Helpers unchanged. |
| `_deliveries.sh`, `_mentions.sh` | no | Consumed via `snapshot_github_combined`, indirectly via the GraphQL task. |
| `_respawn.sh` | no | Called from inside the window-presence task on respawn paths; unchanged. |
| `main.sh` | **yes** | Loop body replaced under `MONITOR_SCHEDULER=v2`. |

## Appendix B — non-goals

For the avoidance of scope creep, the following are explicitly **not**
addressed by this proposal:

- Pane-state caching across tasks (open question §8.2; deferred to a
  follow-up PR after v2 is in production).
- Parallel `git status` across `work/*` (orthogonal optimisation; the
  scheduler does not require it).
- A first-class config-file for task intervals (env vars +
  `config/nexus.yml` keys suffice; a YAML task map is over-engineering
  for ≤20 tasks).
- Replacing `gh api /rate_limit` with the GraphQL rate-limit query
  (separate issue; rate-limit probing is orthogonal to scheduling).
- Removing `MONITOR_INTERVAL` as a concept (kept as the default tick
  for backward compatibility; deletion can happen long after v2 is
  stable).
