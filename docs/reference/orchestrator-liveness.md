# Orchestrator liveness

The watcher restarts the orchestrator when — and ideally *only*
when — the orchestrator is genuinely wedged. Getting that judgement
right is subtle: a respawn fired on a healthy-but-idle orchestrator
wastes a session and interrupts work, while a respawn *suppressed*
on a truly-wedged orchestrator can leave it dead indefinitely. This
page is the spec for the **paste-driven orchestrator-liveness state
machine** that makes the call.

It is distinct from two neighbouring mechanisms:

- **Watcher liveness** (the `monitor/.state/watcher-heartbeat`
  file, the orchestrator→watcher check in `bootstrap.sh`) — covered
  in [`operating/watcher.md`](../operating/watcher.md).
- **Target-window-absent respawn** (`monitor.agent_dead_threshold`,
  default 3 consecutive paste failures / a missing tmux window) —
  covered in the [Watcher protocol](watcher-protocol.md). That path
  fires when the *window or process is gone*; the state machine here
  fires when the window is present and the process is alive but the
  agent is **not reacting to what the watcher pasted**.

Implementation: `monitor/watcher/_orchestrator_liveness.sh` (pure
decision functions), driven by `_v2_task_orchestrator_liveness` in
`monitor/watcher/main.sh`. Unit tests:
`monitor/watcher/test-orchestrator-liveness.sh`.

## The four clock inputs

The machine compares one watcher-side timestamp against four
orchestrator-side liveness signals. The watcher-side stamp is the
anchor; if none of the four signals has advanced past it, the
orchestrator was poked but is not demonstrably reacting.

| Signal | File | Written by | Meaning |
|---|---|---|---|
| **last_paste_ts** (anchor) | `monitor/.state/orchestrator-last-paste.ts` | `paste_to_target` in `main.sh`, on every verified paste to the orchestrator window | "The watcher poked the orchestrator at this epoch." |
| **heartbeat** | `monitor/.state/orchestrator-heartbeat` | `Stop` hook in `orchestrator-settings.json`, at every turn-end | Strongest: a turn finished after the paste. |
| **paste-received** | `monitor/.state/orchestrator-paste-received` | `UserPromptSubmit` hook | The input queue picked up the paste — fresher than the heartbeat during a long tool turn. |
| **jsonl mtime** | `<projects>/<slug>/<sid>.jsonl` | Claude Code session log | Deprecation-window fallback for sessions whose settings predate the hooks. |
| **tool-results mtime** | `<projects>/<slug>/<sid>/tool-results/` | Claude Code, per offloaded tool output | Hook-INDEPENDENT witness; catches an operator-driven turn invisible to paste-tracking (the 2026-06-05 missing-safeguard incident). |

`last_paste_ts` is stamped **only** when the paste targets the
orchestrator window *and* the emit signature is verified visible in
the pane (`paste_to_target` returns 0). Re-submit rescues pass
`no-liveness-stamp` so a re-paste of already-pending content cannot
reset the clock it is racing against.

## State machine

`age = now - last_paste_ts`. The decision (`_orchestrator_liveness_decide`)
walks these gates in order; the first match wins:

```
no last_paste_ts yet ........................ healthy  (nothing to react to)
age <= grace (120s) ......................... healthy  (within-grace; turns take time)
age >= stale_paste_ceiling (1800s) .......... healthy  (paste-too-stale; a quiet
                                                         workspace is not a wedge)
any signal mtime > last_paste_ts ............ healthy  (signal-past-paste; it responded)
                                              └─ checked strongest-first:
                                                 heartbeat > paste-received >
                                                 jsonl > tool-results
─ otherwise: pasted-without-response ─────────────────────────────────────────
age >= dead_threshold (300s) ................ RESPAWN  (dead-threshold; absolute,
                                                         unconditional, checked FIRST)
resubmit marker present, age > grace ........ RESPAWN  (resubmit-failed)
unstick window (150s) exhausted, no
  resubmit yet .............................. RESUBMIT (one-shot re-paste rescue)
inside unstick window ....................... WAITING  (let detect_and_unstick try)
```

The `_orchestrator_liveness_step` wrapper adds: stamping the
`unresponsive-since` marker on first entry to the waiting phase,
clearing both markers on any healthy verdict, and the **cooldown
gate** (a respawn within `orchestrator_fresh_spawn_cooldown_seconds`,
default 1800 s, of the last is suppressed as `blocked-by-cooldown`).

### Why the layering

A wedge is first given a chance to self-heal: `detect_and_unstick`
(permission-Enter, api-error-Enter, AskUserQuestion-Escape) runs
during the **waiting** window. If that budget is exhausted, exactly
**one** re-paste of the pending emit is attempted (a dropped/un-submitted
Enter on an otherwise-alive pane is rescued by a re-paste, not a
kill). Only after both fail does the machine escalate. The
**dead-threshold is the absolute ceiling**: it is checked first and
unconditionally, so no re-submit bookkeeping can defer a kill past
the deadline.

## Knobs

All under `monitor.watcher.*` (env override in parentheses):

| Config key | Env | Default | Role |
|---|---|---|---|
| `paste_response_grace_seconds` | `MONITOR_ORCH_PASTE_RESPONSE_GRACE_S` | `120` | Grace before declaring pasted-without-response; also the post-resubmit response window. |
| `unstick_window_seconds` | `MONITOR_ORCH_UNSTICK_WINDOW_S` | `150` | Budget for `detect_and_unstick` before the re-submit rescue. |
| `orchestrator_dead_threshold_seconds` | `MONITOR_ORCH_DEAD_THRESHOLD_S` | `300` | Absolute deadline: no signal at all post-paste ⇒ respawn. |
| `stale_paste_ceiling_seconds` | `MONITOR_ORCH_STALE_PASTE_CEILING_S` | `1800` | Above this age the paste is too old to be wedge evidence. |
| `dead_threshold_floor_margin_seconds` | `MONITOR_ORCH_DEAD_THRESHOLD_FLOOR_MARGIN_S` | `60` | Margin for the startup dead_threshold clamp (see below). |
| `idle_pane_override_max` | `MONITOR_ORCH_IDLE_OVERRIDE_MAX` | `5` | Idle-pane override budget (see below). |
| `liveness_log_throttle_seconds` | `MONITOR_ORCH_LIVENESS_LOG_THROTTLE_S` | `30` | Throttle for repeated `waiting` log lines. |

**Three coherence constraints** the machine relies on:

1. `grace + unstick_window < dead_threshold` (270 < 300) — so the
   one-shot re-submit retains a verification window before the
   absolute deadline. Violated ⇒ the rescue never fires before the
   kill. Surfaced as a startup `WARN` (evaluated on the *effective*,
   post-clamp dead_threshold).
2. `full_state_emit_interval + loop_interval < dead_threshold` — the
   structural-coherence constraint that the 2026-06-15 incident
   violated (660 ≥ 300). **ENFORCED at startup, not merely warned**:
   `main.sh` clamps the effective dead_threshold up to
   `full_state_emit_interval + interval + dead_threshold_floor_margin`
   (720 s with defaults) so a static-workspace paste always resets the
   clock before the deadline. See "The fix" below.
3. `dead_threshold < stale_paste_ceiling` (300 < 1800) — otherwise the
   ceiling masks the dead-threshold check and the wedge detector never
   fires. The clamp in (2) preserves this: if raising dead_threshold
   would cross the ceiling it declines and falls back to a `WARN`.

## The idle-pane guard (2026-06-15 incident)

### What happened

In a **fully-static workspace**, `compose_emit` pastes only when
workspace state changes or the full-state interval
(`monitor.full_state_emit_interval_seconds`, default 600 s) elapses.
With a 60 s loop tick plus scheduler jitter, the maximum gap between
pastes is ~660 s — well past `dead_threshold` (300 s). On
2026-06-15T12:14:39 the last paste was at 12:03:58 (age 641 s) with
every liveness signal predating it; the state machine produced
`respawn reason=dead-threshold` and fired **one second before** the
resurfacing full-state paste at 12:14:39 would have reset the clock.
The orchestrator was healthy and idle at its `>` prompt. (Log
forensics also showed `elapsed_unstick=0` — the age crossed from
within-grace straight past the deadline without the waiting/unstick
phase engaging, so the re-submit rescue never ran.)

This race exists whenever constraint (2) above is violated. The
`dead_threshold` default has been 300 s since the state machine was
introduced (`#168`, closing `#164`); contrary to an early commit
note, PR `#208` did **not** retune it (it changed only grace
60→120 and unstick_window 180→150). The exposure is the *pairing*
of a 300 s deadline with a 600 s full-state cadence, not a single
regressing commit.

### The fix — two layers

**Layer 1 (primary, eliminates the race at the source): the startup
clamp.** `main.sh` raises the *effective* dead_threshold to
`full_state_emit_interval + interval + dead_threshold_floor_margin`
(720 s with defaults) whenever the configured value would sit at or
below the maximum compose_emit gap. With the deadline above the gap, a
static-workspace full-state paste **always** resets `last_paste_ts`
before the deadline, so the false positive is **structurally
impossible** — not merely intercepted at runtime. The clamp is a pure
function (`_orchestrator_effective_dead_threshold`) and declines (with
a `WARN`) only if raising the deadline would cross
`stale_paste_ceiling` (constraint 3). The real wedge detector
(waiting → unstick → one-shot re-submit → `resubmit-failed` respawn at
~270–390 s) is independent of dead_threshold and unaffected by the
clamp.

**Layer 2 (defense-in-depth): the bounded idle-pane guard.** For any
residual `dead-threshold` respawn that still fires (e.g. compose_emit
starvation, or a config where the clamp had to decline),
`_v2_task_orchestrator_liveness` consults
[`monitor/pane-state.sh`](worker-states.md) and routes the verdict
through the pure function `_orchestrator_idle_pane_guard(verdict,
pane_state, override_count, max_overrides)`. It gates **only**
`respawn reason=dead-threshold` — a `resubmit-failed` respawn has
already proven non-responsiveness via the re-paste probe (a healthy
orchestrator would have gone `busy` on the re-paste) and is **never**
suppressed:

| pane-state | decision | rationale |
|---|---|---|
| `idle`, `empty` (budget available) | **suppress** | process alive, not visibly wedged; let the next paste reset the clock. `empty` is process-anchored to "claude alive, renderer transient" (a dead process emits `absent`, never `empty`) — it is the documented fresh-resume quirk this incident's own post-respawn probes showed. |
| `idle`/`empty`, budget **exhausted** | **escalate** | an alive pane permanently parked at idle, never advancing a signal across `idle_pane_override_max` consecutive cycles, is *itself* a wedge. Honor the respawn. |
| `busy`, `blocked`, `user-typing`, `absent`, `working-*`, … | **proceed** | a genuine wedge surfaces as one of these (frozen spinner=busy, overlay=blocked, dropped-Enter text=user-typing, dead=absent). |
| errored / no state token / unknown | **proceed** | fail TOWARD respawn (recoverable, `mode=resume` preserves the session) rather than suppression (risk: dead forever). |
| non-`dead-threshold` respawn (e.g. `resubmit-failed`) | **proceed** | already a proven wedge; out of the guard's scope. |

### Why bounded — the safety floor

By the time a respawn verdict is reached, every paste-keyed signal
is stale *by definition* (that staleness is why the verdict is
respawn), so a healthy-idle and a wedged-but-alive orchestrator are
indistinguishable from those signals alone. `pane-state.sh` adds an
orthogonal observation but cannot tell a responsive idle prompt from
a frozen one — both render as a bare `>` with no spinner. An
**unbounded** idle-suppression would therefore let a hung-but-idle
TUI suppress its own respawn forever: the dangerous false-negative.

The **override budget** (`idle_pane_override_max`, default 5)
neutralises this. The counter in
`monitor/.state/orchestrator-idle-override-count` increments on each
suppression and **resets on any genuine healthy verdict** (the
orchestrator demonstrably responded), on a non-idle pane, and when
the budget is spent and the respawn is honored. A merely-quiet
healthy orchestrator that answers even one full-state paste resets
the streak and never approaches the budget; only an orchestrator
that reads idle/empty *and* advances zero signals across ~5
consecutive full-state cycles (≈ 55 min) is treated as wedged. The
respawn is `mode=resume`, so an over-eager kill is recoverable;
indefinite suppression is not — the bound is deliberately tuned to
favour the recoverable failure.

Set `idle_pane_override_max=0` to disable the bound (legacy
unconditional suppression — not recommended).

### Tuning the deadline yourself

The Layer-1 clamp picks a safe effective deadline automatically, but
you can set your own: raise `orchestrator_dead_threshold_seconds`
above `full_state_emit_interval + interval` (the clamp then leaves
your value untouched), or lower `monitor.full_state_emit_interval_seconds`
so a configured-low deadline is coherent. Either way the real
wedge-recovery path (waiting → unstick → one-shot re-submit, all
firing well before the deadline) is unaffected — the deadline is only
the absolute backstop.

## Verdict logging

The liveness task polls every ~5 s. To avoid log spam,
`_orchestrator_liveness_log_decide` emits a line on state *entry*
(first `waiting`), at most once per `liveness_log_throttle_seconds`
while waiting, and on every transition (with a duration summary on
exit). `resubmit` / `respawn` / `idle-pane-override` events always
log verbatim.
