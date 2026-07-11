---
description: "Orchestrator-exclusive policy for closing worker tmux windows: triggers (wrapped + idle, long-idle without report, stuck after unstick exhaustion, pane absent), retention overrides, the MANDATORY synchronous pre-kill preflight (retire-preflight.sh), pre-close checks, kill mechanism, and cadence."
---

# nexus.window-cleanup — closing worker windows

TRIGGER when: orchestrator surveys the running-agents table at
the start of a wake; orchestrator notices the dashboard is
crowded with idle workers; orchestrator considers tearing down a
worker that has filed its final report; orchestrator needs to
decide whether a long-idle worker should be retained or closed.

## Why this policy exists

Spawning is half the worker lifecycle; closing is the other
half. Workers do not tear themselves down — the orchestrator
decides cleanup. Without an explicit policy, idle worker
windows accumulate to the point where the dashboard's
running-agents table is unscannable and `tmux list-windows`
output flips between current and stale state cycle to cycle.
At the same time, closing a worker the user might have
re-engaged loses loaded context (kernel, partial training
run, in-progress branch) that is expensive to rebuild.

The policy below is the contract the orchestrator follows on
every wake: a small set of trigger conditions, retention
overrides for context the user might still want, pre-close
checks that ensure a final report exists, and a
deterministic kill mechanism. **This policy is
orchestrator-exclusive — workers never close themselves and
never close siblings.**

## Scope

This policy applies to **worker windows only**. The
`watcher` and `orchestrator` windows are governed
by the mutual-liveness contract in `monitor/README.md`
(`monitor.agent_dead_threshold`,
`monitor.agent_missing_respawn_delay`, the heartbeat
staleness path). Never close them under this policy.

## Trigger source: the watcher's `--- idle workers ---` section

The watcher emits an `--- idle workers ---` section on
transitions only (one line per worker whose state changed
since the prior poll). One of four classifications per line,
plus a `(N retained windows suppressed: …)` footer when the
orchestrator has logged a recent `window-retain` event for one
or more idle workers.

"Really idle" gates on engagement-anchored age ≥
`MONITOR_IDLE_THRESHOLD_SECONDS` (default 60). Age is
`now - engagement_epoch` when the worker has a row in
`monitor/.state/engagement-log.tsv`, otherwise the historical
`now - tmux #{window_activity}` (fallback for fresh workers
the watcher has never observed `busy` / `user-typing`). The
engagement-log anchor avoids the cursor-blink / autosuggest-
render / status-bar-tick false bumps that previously caused
retained workers to oscillate in and out of the idle pool
every minute or two and thrash the suppressed-set footer.
Independent of the bell flag (cleared when the user views the
window). The pane-state classifier (`monitor/pane-state.sh`)
then routes each gated window:

- `state ∈ {idle, autosuggest-only}` → wrap-up classification
  flow (`wrapped` | `wrapped-but-stub` | `no-wrap-up` |
  `idle-too-long`).
- `state ∈ {absent, empty, blocked}` → `pane-absent`
  (inviolable; inner Claude process is gone, the renderer
  landed in an ambiguous state, or the pane is sitting on a
  stalled overlay).
- `state = over-limit` → `over-limit` (inviolable; canonical
  "You've hit your limit · resets `<time>`" notice; worker is
  functionally suspended until the named reset). Short-circuits
  the spawn-grace AND the 60 s age gate so the suspension
  surfaces on the first poll.
- `state ∈ {busy, user-typing}` → no row emitted; the probe
  ALSO stamps `monitor/.state/engagement-log.tsv` with the
  current epoch so the retain-consume gate (below) reflects
  real engagement.

The classifier consults `monitor/.state/action-log.jsonl` for a
matching `wrap-up` event (project-slot or slug-slot rule, same
as "Matching reports to windows" below) AND runs
`monitor/ng report-check` on the cited report. The 24h hard-
close threshold (`MONITOR_IDLE_CLOSE_HOURS`, default 24,
config `monitor.idle_close_hours`) overrides the other
classifications once age exceeds it. The full lifecycle
state machine (every state, transition condition, threshold
constant, and reaction) is diagrammed in
`monitor/docs/agent-state-machine.md`.

| Class | Watcher line shape | Orchestrator action |
|---|---|---|
| `wrapped` | `<window> wrapped up (idle <age>; wrap-up logged)` | Proceed through trigger / retention / pre-close. The pre-close `wrap-up` grep stays as belt-and-suspenders. |
| `wrapped-but-stub` | `<window> wrapped-but-stub (<missing-fields>)` | Paste the **Finish-and-expand** follow-up (below) naming the specific missing sections / fields. Re-check next wake. If still stub after 30 min, escalate to long-idle. |
| `no-wrap-up` | `<window> idle <age> WITHOUT wrap-up — consider follow-up paste` | Paste the **Wrap-up missing** template (below). Re-check next wake. If 30 min pass without the row flipping to `wrapped`, escalate to long-idle. |
| `idle-too-long` | `<window> idle-too-long <age> (exceeds close threshold; consider close)` | **Strong default to close.** Retention overrides still apply (recent user engagement, loaded-kernel cost). Rank: this triggers closing **above** the long-idle-without-report path. |
| `pane-absent` | `<window> pane-absent (claude process gone or unresponsive; relaunch or close)` | The inner Claude Code process has died (pane fell back to shell), the renderer is ambiguous, or the pane is stuck on an unhandled overlay. Relaunch the worker via `monitor/spawn-worker.sh` (preserving the prior report's `How to Resume` brief) or close. Inviolable — never suppressed by `window-retain`. |
| `over-limit` | `<window> OVER-LIMIT (resets <reset_at>; weekly Opus limit hit — schedule resume)` | The worker's claude session hit the weekly Opus limit and is functionally suspended. **Do NOT close**, and **don't try to schedule the resume yourself** — the watcher owns the wake-loop (issue #87 amendment). The orchestrator may itself be over-limit on the same weekly budget, so the actor responsible for scheduling must be one with no claude-API consumption. The watcher stamps the pane in `monitor/.state/over-limit-state.tsv`, retries every `monitor.over_limit.initial_backoff_seconds` (default 60s, exponential up to a 300s cap, gives up at `monitor.over_limit.max_attempts` default 10), and pastes a resume brief into the pane the moment `pane-state.sh` shows the suspension has cleared. `reset_at` is informational on this row. Inviolable — never suppressed by `window-retain`. |
| `operator-engaged` | `<window> operator-engaged (src=<submit\|submit-after-wrap>; idle <age> — operator driving; idle/retire handling suppressed while engaged)` | **Do NOT close. Do NOT paste follow-ups.** The operator drives this window (issues #196, #201) — wrapped or never-wrapped. Seed: the worker's `UserPromptSubmit` hook stamped a prompt submit with no machine-input stamp covering it (no `paste-followup` event, no `machine-input.tsv` row, no spawn), AND that submit was corroborated by observed pane-content change within `monitor.operator_engaged_change_ttl_seconds` (default 600 — the <your-org>/<your-nexus>#205 follow-up replaced a fragile one-frame bright-text read with sustained transcript change). The hook is a deterministic contract event from Claude Code itself. Every orchestrator follow-up MUST still go through `monitor/paste-followup.sh`: an unstamped raw `tmux paste-buffer` fires the worker's `UserPromptSubmit` hook and reads as operator input. One informational row per engagement episode; while valid, `idle_prompt` decision rows are withheld and the window is **not retire-eligible**. The mark is **self-expiring**: once the pane goes static past the change TTL it lapses and the window becomes retire-eligible again — so it is never pinned open indefinitely on a stale or false mark. An `engaged-done` finished-signal, a newer spawn, or window close also ends it. A **wrap-up does NOT** (the <your-org>/<your-nexus>`#205` state-machine follow-up): an interactive session stays engaged across its own hand-off — the operator may have follow-up inquiries — and `ng wrap-up` prompts the agent to run `ng engaged-done` when it is genuinely finished; that signal drops the window back to the typical wrapped-window cleanup path. A post-wrap ORCHESTRATOR follow-up (stamped paste) instead regresses the window to busy: the engagement-log re-anchors at the submit, the standing retain is consumed, and the old wrap-up is superseded (the worker owes a fresh one — its idle row returns as `no-wrap-up`, not `wrapped`). |
| `parked-awaiting-skeptic` | `<window> parked-awaiting-skeptic (idle <age>; skeptic reviewing — exempt from idle/close until verdict; see skills/nexus.skeptic)` | **Do NOT close** (`#285`). The worker wrapped up in `require` / auto-`require` mode and is blocked in `monitor/skeptic-channel.sh await`, legitimately waiting for the reviewing skeptic — a live `skeptic-pending` marker (`monitor/.state/skeptic/pending/<window>`, mtime refreshed each poll within `monitor.skeptic.await_hang_seconds`, default 600 s) drives this row. The marker clears only when the skeptic returns a verdict, at which point the window becomes retire-eligible and the next idle cycle reclassifies it `wrapped`. `retire-preflight.sh` independently blocks the kill while the marker is live (Hard gate 0, check 1b), so even a stale snapshot cannot strand the review. A *stale* marker (the `await` died, or the worker never entered the loop) lapses the exemption and the window resurfaces under normal idle classification. One informational row per park; not an action item. Protocol: [`skills/nexus.skeptic`](../nexus.skeptic/SKILL.md). |
| `paste-unconfirmed` | `<window> paste-unconfirmed (paste <age>s ago; no UserPromptSubmit fired — the nudge silently failed; re-paste via monitor/paste-followup.sh)` | A `paste-followup` older than `monitor.paste_confirm_grace_seconds` (default 180; env `MONITOR_PASTE_CONFIRM_GRACE_SECONDS`) never fired the worker's `UserPromptSubmit` hook even though the window's hooks are demonstrably live (heartbeat present) — the Enter was swallowed (VI mode, an overlay, a redraw race) and the worker never received the prompt. **Re-paste via `monitor/paste-followup.sh`**; a confirmed re-paste clears the row. Never suppressed by `window-retain`; `idle-too-long` still overrides it. `--no-enter` pastes and hook-less windows are exempt by design. |
| `engaged-close-reminder` | `<window> operator-engaged but operator away <age> (src=<seed>) — consider closing this window; reminder re-fires once per period until the operator returns or it closes` | The away phase's only surface (issue #201): fires once the operator has stopped driving for `monitor.operator_engaged_close_reminder_seconds` (default 86400 = 24 h; env `MONITOR_OPERATOR_ENGAGED_CLOSE_REMINDER_SECONDS`), then at most once per period. **Still do NOT auto-close** — the window belongs to the operator; relay the reminder (overview routing one-liner or dashboard) so the operator decides. The operator returning re-marks the window engaged and resets the cadence. |
| `idle-awaiting-job` | `<window> idle-awaiting-job (idle <age>; <n> child(ren) … — exempt under long-timeout backoff)` | **Do NOT close.** (<your-org>/nexus-code#455 refine, case a.) The worker is idle but the AUTHORITATIVE process tree shows ≥1 live background-shell child whose CPU has frozen — the signature of a blocking wait on a long job (e.g. `sbatch --wait` on a Slurm job). It is exempt from reap under an exponentially-backing-off long timeout. Informational, one row per episode; not an action item. It flips to `idle-children-clarify` when the next backoff nudge is due, and surfaces as a retire candidate (`idle-too-long`) at the **absolute** hard ceiling (`monitor.background_children_grace_ceiling_seconds`, default 48 h) — which no health declaration and no CPU-advancing child can postpone. |
| `idle-children-clarify` | `<window> idle-children-clarify (idle <age>; … — paste the worker-health clarification prompt; …)` | **Paste the Background-child clarification template (below).** (Case a.) A clarification nudge is due: the child CPU has stayed frozen past the current backoff step, or the worker declared `stuck`/`done`. The worker answers via `monitor/worker-health.sh` → `monitor/.state/worker-health/<window>.json`; the watcher reads it next cycle to **extend** the grace (a declared-runtime job still running), **reap** (stuck / done-with-leftover-children), or keep asking on the backing-off schedule. Never auto-close — ask first. |
| `wrapped-with-children` | `<window> wrapped-with-children (idle <age>; … — inconsistency: …)` | **Inconsistency — clarify or close, do NOT auto-reap.** (Case b.) The worker ran `ng wrap-up`, has **no skeptic pending**, but STILL has ≥1 live background-shell child: either leftover/stale children, or a premature wrap while a job runs (strongest when the child CPU is still advancing). Paste the Background-child clarification template (below); the worker answers via `monitor/worker-health.sh`. If it declares `done` the children are leftover and the window is safe to close; if `running` it wrapped prematurely (extend or close); if `stuck` it needs help. **Not** emitted for a skeptic-parked worker — see `parked-awaiting-skeptic`. |
| `parked-awaiting-skeptic` | `<window> parked-awaiting-skeptic (… skeptic reviewing — exempt from idle/close)` | **Do NOT close.** Wrapped-with-children is the *expected* shape here, not an inconsistency: `ng wrap-up` is what writes the skeptic-pending marker, and the worker then holds its `skeptic-channel await` re-check loop in a background shell. The park is authoritative on the marker `monitor/.state/skeptic/pending/<window>`, not on the pane. A STALE marker (the await loop died past the hang threshold) lapses the exemption and the window resurfaces as `wrapped-with-children`, so the park can never mute a window forever. |
| Suppressed (footer) | `(N retained windows suppressed: <w1> (<reason1>), <w2> (<reason2>), …)` | None — the orchestrator already decided to retain these. The footer is auditability so retention remains visible without re-triaging. |

The watcher dedupes against its prior cycle's idle set on
`(window, class)`, so a row only appears the cycle it
transitions — no recurring noise for a stable worker. The
retained footer is deduped against the prior cycle's
suppressed set, so it re-emits only when a window enters or
leaves suppression.

### Retain-as-mute: how `window-retain` suppresses rows

A `wrapped` or `no-wrap-up` row is suppressed into the footer
when the orchestrator has recently logged a `window-retain`
event for that window:

```bash
monitor/ng log-action monitor \
    --event window-retain \
    --extra "window=<name>" \
    --extra "reason=<short>"
```

Suppression conditions (all must hold):

- The retain event's `ts` is within
  `monitor.retain_ttl_seconds` (default 86400 = 24 h; env
  `MONITOR_RETAIN_TTL_SECONDS`).
- The window has had no **engagement** since `retain.ts` —
  engagement = a `pane-state.sh` observation of `busy` or
  `user-typing`, stamped in `monitor/.state/engagement-log.tsv`
  by the probe on every cycle. The retain-consume gate
  compares the stored engagement epoch against `retain.ts`.
  Workers with no engagement-log row are treated as "never
  engaged" → retain holds. **Critically NOT consumed by
  `tmux #{window_activity}` alone** — autosuggest re-renders,
  cursor blinks, spinner glyphs, and status-bar token-counter
  ticks all bump `window_activity` without representing real
  engagement (issue #111: `echo-density` retain consumed
  inside 30 min while pane-state reliably reported idle /
  autosuggest-only).

`wrapped-but-stub`, `idle-too-long`, and `pane-absent` are
**inviolable** — they never convert to `retained`. A broken
report, a runaway 24h-idle window, or a crashed Claude
process must surface even if retention was logged: the
orchestrator must not be able to silently bury these.

Logging a retain is the canonical way to tell the watcher
"this idle is intentional." Without it, the worker keeps
producing `no-wrap-up` rows on every transition (since the
basic classifier has no theory of mind about why a window is
idle).

## The wake-time survey

At the start of each wake, after `monitor/watcher/bootstrap.sh`
and before processing the watcher diff, run:

```bash
tmux list-windows                         # names + indexes
monitor/pane-state.sh --all               # per-window state
ls -t reports/*.md | head -40             # recent reports
```

Match each non-{`watcher`,`orchestrator`} window against the rules
below. Most surveys produce an empty close list — that's the
common case, and the survey is cheap (a handful of stat calls
plus one tmux query). The watcher's `--- idle workers ---`
section narrows the survey when it's present: only windows it
flagged need triage; the rest are confirmed busy or untracked.

## Triggers — when to consider closing

A window is a **close candidate** when any of the following
matches. Active panes (`state=busy` or `state=user-typing`)
are never close candidates regardless of elapsed time — the
worker has work in flight.

1. **Idle-too-long (24h+ hard close).** Watcher's
   `--- idle workers ---` section flags a row as
   `idle-too-long` (age ≥ `MONITOR_IDLE_CLOSE_HOURS`, default
   24h, config `monitor.idle_close_hours`). **Strong default
   to close.** Retention overrides still apply (recent user
   engagement, loaded-kernel cost, cross-issue spillover) —
   the watcher's strong recommendation isn't a forced action.
   Ranked above the long-idle-without-report path: an
   idle-too-long worker without a report goes through this
   trigger, not (2).
2. **Wrapped + idle.** A matching `reports/*.md` exists (see
   "Matching reports to windows" below), AND `pane-state.sh`
   reports `idle | autosuggest-only | empty`, AND the
   worker's session jsonl
   (`~/.claude/projects/<slug>/<session>.jsonl`) has not
   been modified for **≥ 30 min**. The clean case — the
   worker filed its report and stopped.
3. **Long-idle without report.** Pane is `idle | autosuggest-
   only | empty` for **≥ 90 min** AND no matching report.
   Don't close yet — paste the finish-and-report follow-up
   (template below) and re-check on the next wake. Close
   after a further **30 min** if the report hasn't landed.
4. **Stuck after auto-unstick.** Pane is `blocked` AND
   `monitor/.state/watcher-unstick.log` shows the unstick
   library has logged exhausted attempts for cases A, B, and
   C on this window without recovery. Paste the stuck
   follow-up template; close after the long-idle-without-
   report timeout if the report still doesn't land.
5. **Pane absent.** Watcher's `--- idle workers ---` flags
   the row as `pane-absent` (`pane-state.sh` reports
   `state ∈ {absent, empty, blocked}`). The `name=` field on
   the emit always carries the live tmux window name in this
   surface; direct `pane-state.sh <idx>` callers now exit 3
   with stderr on non-existent indexes (issue #140), so a
   `state=absent` row from the script always denotes a real
   window with dead claude. Two sub-cases:
   - **Window vanished from tmux** — already handled by tmux
     housekeeping. Drop the row from the dashboard and log a
     `window-close` with `reason=tmux-already-gone`. Don't
     try to kill an absent window.
   - **Window still in tmux but Claude died inside it**
     (state=absent), the renderer is ambiguous (state=empty),
     or the pane is on a stalled overlay (state=blocked) —
     the worker had loaded context and may have work in
     flight. Read its last report (if any) to decide:
     relaunch via the spawn-worker pattern preserving the
     prior `How to Resume` brief, or log `window-close` with
     `reason=pane-absent-no-recovery`. `pane-absent` is
     inviolable; `window-retain` does not suppress it.
6. **Over-limit.** Watcher's `--- idle workers ---` flags
   the row as `over-limit` (`pane-state.sh` reports
   `state=over-limit`; the canonical "You've hit your limit
   · resets `<time>`" notice replaced the input box). The
   pane is functionally suspended: ignores input, no
   spinner, can't progress. **Do NOT close** — closing
   forfeits loaded context and the pending in-flight work.
   **Do NOT schedule the resume yourself, either.** The
   watcher owns this wake-loop. Architectural rationale:
   when a pane hits the weekly Opus limit, every claude
   session on the same account/budget is at risk of the same
   suspension — including the orchestrator. Scheduling the
   resume from the orchestrator's own loop would create a
   pure-claude actor responsible for waking itself, which
   cannot work when both sides share the budget. The watcher
   is pure shell, has no claude-API consumption, and is
   already polling pane state every cycle — it is the right
   actor.

   What the watcher does (no operator action required):
   - On the cycle that first observes `state=over-limit`,
     stamps a row in `monitor/.state/over-limit-state.tsv`
     with the parsed `reset_at`, a target wake epoch, and
     an attempt counter. The row is keyed
     `_orchestrator` when the suspended pane is the watcher
     `TARGET`, otherwise by window name.
   - At `reset_at + monitor.over_limit.wake_margin_seconds`
     (default 300s) the wake-loop re-probes the pane. If
     still suspended → exponential backoff (60s → 120s →
     240s, capped at 300s; default 10 attempts before giving
     up). If transitioned out → pastes a resume brief into
     the pane (the orchestrator pane gets a richer brief
     including the names of any still-suspended workers; a
     worker pane gets a terse "weekly limit reset; resume
     your work") and drops the row.
   - While an `_orchestrator` row exists in the state file,
     the watcher suppresses routine emits to the
     orchestrator pane (they'd queue uselessly in an inert
     input box). Emits are still archived to
     `monitor/.state/diffs/`; only the paste-to-TARGET step
     is paused. Resumption restores normal paste flow.

   The operator's role on `over-limit` rows is therefore
   passive: read the row to know which workers are
   suspended, intervene manually if the watcher hits its
   `max_attempts` cap (logged as `max wake attempts reached
   for '<window>' (key=<key>); dropping stamp`), and
   otherwise let the wake-loop run. `over-limit` is
   inviolable; `window-retain` does not suppress it.

### Matching reports to windows

A worker's report can land under either slot of the report
filename: `<project>_<date>_<time>_<slug>.md`. Match by either:

- **Project slot** — `reports/<window-name>_*.md` (worker
  whose `work/<project>` matches the window name, e.g.
  `echo-density`, `agent-sandbox-doc`,
  `repltime-histones`).
- **Slug slot** — `reports/<project>_*<window-name>*.md`
  (workspace-level worker that uses `nexus` as project; the
  window name appears inside the slug, e.g.
  `nexus_2026-05-07_185302_merge-watcher-prs.md`,
  `nexus_2026-05-07_184017_watcher-continue-fix.md`).

If neither pattern matches and no comparable basename appears
within the last day's reports, treat as no report.

## Retention — when to *keep* a flagged window past the trigger

A trigger fires; retention overrides it. The window stays
alive when any of the following holds:

- **Wrap-up auto-retain (new default).** `ng wrap-up`
  auto-logs a `window-retain` event on every successful
  hand-off (unless `--no-retain` was passed). The retain TTL
  is `monitor.retain_ttl_seconds` (default 24 h). A worker
  that just wrapped therefore stays around by default so the
  orchestrator can `claude --continue` against a follow-up
  user comment instead of paying spawn + ramp-up cost. See
  **Continue-vs-spawn** below for the decision flow.
- **Recent user engagement.** A user comment on the worker's
  tracking issue (or any issue tagged with the worker's
  project) within the last hour. Resets the idle timer.
- **Loaded-context cost.** The worker holds non-trivial
  in-process state — a large dataset in a kernel, a
  partially-trained model, a long-running Slurm job
  referenced in its last report. Re-engagement cost is
  high. Retain unless idle ≥ 24 h.
- **Open-ended scope.** Long-running research threads the
  user routinely re-engages (`kompot-fig*`,
  `repltime-histones`, `echo-density`-style worker windows
  whose tracking issue is still open). Close only on
  explicit user directive, not on idle alone.
- **Cross-issue spillover.** The worker's tracking issue is
  closed but a related issue may route follow-ups to the
  same agent. Retain through one full wake-and-survey cycle
  after the parent issue closes.

When retention applies, log it once so the next wake doesn't
re-evaluate from scratch AND so the watcher's `--- idle
workers ---` section stops re-emitting per-row noise for the
retained window:

```bash
monitor/ng log-action monitor \
    --event window-retain \
    --extra window=<name> \
    --extra reason=<short>
```

The classifier honours this entry: a `wrapped` or
`no-wrap-up` row for the named window is collated into a
`(N retained windows suppressed: …)` footer instead of
firing as a per-row "consider close" / "WITHOUT wrap-up"
line. See the "Retain-as-mute" subsection under
"Trigger source" for the full conditions, including the TTL
and activity-consumes-retain rules. `wrapped-but-stub` and
`idle-too-long` ignore retain — they always surface.

The note's effect expires when the underlying reason no
longer holds — the next idle window past the 24-h
kernel-cost clock, the next wake after a closed parent
issue cycle, etc. Retention is not a permanent pin; it's a
"don't close this round" decision the orchestrator
re-evaluates at each wake.

### Activity-aware retention pressure

Retention is not uniform across workspace load. At low
activity, keeping wrapped windows around is cheap and the
upside (skip ramp-up if the user re-engages) is real. At
high activity, every idle pane competes for the
running-agents table, the operator's glance budget, and —
if loaded contexts overlap — memory. The orchestrator
should let workspace pressure tilt the retention vs. close
decision.

The watcher's per-emit prelude line gives the orchestrator
the signal cheaply:

```
workspace: N busy | N idle | N retained | N idle-too-long | N pane-absent | N awaiting-input
```

(`awaiting-input` counts workers whose `Notification` hook —
`permission_prompt`, `idle_prompt`, MCP elicitation — fired
since the previous prelude render. A non-zero value means
those workers want orchestrator attention right now and
short-circuits the close vs. retain debate for those
windows: respond first, then re-evaluate.)

Three tiers, evaluated at each wake (no hard knob — the
orchestrator internalises the thresholds):

- **Low pressure** (≤ 3 busy + ≤ 5 retained, roughly).
  Default to retain. Closing wrapped+retained windows
  saves nothing the operator can feel; the next user
  follow-up benefits from the warm context. Don't close
  unless the worker is `idle-too-long` or
  `wrapped-but-stub`.
- **Moderate pressure** (4–6 busy, or 6–10 retained).
  Tilt toward closing wrapped+retained windows that have
  been idle past, say, 4–6 h *and* whose tracking issue
  is closed (no obvious re-engagement path). Loaded-
  context cost still pins workers with kernels / Slurm
  jobs / partial training runs.
- **High pressure** (≥ 7 busy, ≥ 10 retained, total
  active workers `busy + idle + retained > 10`, or the
  running-agents table is unscannable in one screen).
  Close wrapped+retained windows aggressively. Retain
  only those with explicit loaded-context cost OR a
  reasonable expectation of user re-engagement within
  the next hour (recent comment thread, in-flight PR
  review). The retain-by-default policy from
  `ng wrap-up` is a *default*, not a permanent lease —
  override it freely under pressure.

The total-count condition (`busy + idle + retained > 10`)
catches two distributions the per-axis floors miss: (a)
many `idle` workers that haven't been logged as
`retained` — the retain-mark suppresses the idle-pool row
but the window still exists, costing operator glance
budget; (b) a skewed mix where one axis sits near its
tier floor and another well below, so neither individual
axis tips into High but the sum is unmanageable. When the
total-count condition fires, treat each wake as a prompt
to **survey + propose** closures even without a user ask:
surface a close list naming the candidates and their
tracker status (PR merged, issue closed, no recent
comment thread) and let the user ack or override. The
goal is to keep the running-agents table at a size a
human can take in at a glance.

The fuzziness is intentional. Hard thresholds wired into
the watcher would close windows the user wanted kept on
the wrong day; the orchestrator sees the prelude every
cycle and can apply judgement (the user's email signature
mid-thread, an upcoming meeting on the calendar, the time
of day) the watcher can't. Activity pressure is one more
lever in the retention decision, not a clock-driven
mechanism.

When closing under pressure, log a richer close reason so
post-hoc audit can distinguish pressure-driven closes from
the standard triggers:

```bash
monitor/ng log-action monitor \
    --event window-close \
    --extra window=<name> \
    --note "pressure-close: busy=<N> retained=<N>; <short rationale>"
```

The tier breakpoints above (≤ 3 / 4–6 / ≥ 7 busy and ≤ 5 /
6–10 / ≥ 10 retained) are provisional, calibrated by eyeball
at the time of writing. Recheck them against the workspace's
actual distribution every couple of weeks:

```bash
monitor/calibrate-pressure-thresholds.sh
```

It reads every `workspace: …` prelude line archived under
`monitor/.state/diffs/`, prints the per-axis distribution
(p25 / p50 / p75 / p90 / p95), and flags `REVISE` when any
tier boundary diverges from the observed percentile by ≥ 2.
If REVISE fires, edit the bullets above to match the new
floors and update the hardcoded `SKILL_*` constants in the
script so the next recalibration compares against the
revised baseline. See <your-org>/nexus-code#79 for the
calibration cadence and the deferred post-hoc audit.

## Continue-vs-spawn — what to do when the user follows up

The wrap-up auto-retain default keeps wrapped workers alive
for 24 h. When a user comment lands on the same tracking
issue (or routes to the same window via `@<window>:`), the
orchestrator chooses between **continuing** the retained
worker and **spawning** a fresh one. Default-to-continue is
the workspace bias — the whole point of retention is to
preserve loaded context and skip ramp-up.

Tilt continue when ALL of:

- **Same topic.** The new request is on the same tracking
  issue, the same `work/<project>`, or names the same
  `@<window>` the prior wrap-up came from. Active-exchange
  follow-ups (bug refinement, design tweak, "also do X on
  the same branch") are the textbook case.
- **Pane state is `idle`, `autosuggest-only`, or `empty`**
  per `monitor/pane-state.sh <window-index>`. A pane in `busy` /
  `user-typing` is mid-flight — queue the comment as a
  paste-buffer follow-up, don't double-spawn.
- **Worker is at < 70% context utilisation.** Check the
  pane's status bar token-counter (e.g. `↓ 38k tokens` near
  the input chevron). When in doubt, prefer continue;
  Claude's compaction kicks in before failure.
- **Within retain TTL.** `now - retain.ts ≤
  monitor.retain_ttl_seconds`. After TTL expiry the window
  may still exist, but a fresh worker is cleaner than a
  retain-expired one.
- **No conflicting concurrent work.** No other worker is
  currently editing the same files / branch. Two workers
  on one branch is the canonical conflict footgun.

Tilt fresh-spawn when ANY of:

- **Materially different scope.** New task is a different
  project, a different layer of the stack, or a new
  direction the prior worker isn't briefed for. The prior
  report is still useful — feed it in via
  `monitor/spawn-worker.sh -r <prior-report-path>` so the
  fresh worker reads What Was Done / Current State / How to
  Resume without resuming the loaded conversation.
- **High context utilisation (≥ 70%).** Continuing risks
  hitting context limits mid-task. Fresh worker preserves
  operating headroom; pass `-r` to keep the lineage.
- **Prior worker handled finalised work.** Tracking issue
  closed, PR merged, report wrapped with `--no-retain`.
  Spawn fresh; reference the prior report only if the new
  task builds on the same surface.
- **You're not sure the prior worker is healthy.** Pane in
  `blocked`, `pane-absent`, or `wrapped-but-stub`. Spawn
  fresh after triage; the wrapped-but-stub case may also
  warrant a follow-up paste to expand the stub before close.

**Default to continue when the call is ambiguous.** The
user's stated preference is collaboration efficiency:
ramp-up cost is real and the user feels it. A wrong-continue
costs at most a context-window squeeze; a wrong-fresh-spawn
costs all the loaded state plus the user's time waiting for
a redundant bootstrap.

### Advisory helper: `monitor/ng spawn-decision <window>`

`ng spawn-decision <window>` collapses the pane-state + retain-age
+ TTL checks above into one advisory verb. Output:

```
decision=<continue|spawn|ambiguous> reason=<short>
pane_state=<state> retain_age_s=<n|none> spawn_age_s=<n|none>
```

- `decision=continue` — retained, idle, within TTL → paste the
  follow-up into the existing window.
- `decision=spawn` — no retain on record, retain expired, pane
  blocked / absent → spawn fresh (optionally with `-r <prior-report>`).
- `decision=ambiguous` — pane mid-flight (busy / user-typing) or
  state unknown → queue the comment as a paste-buffer follow-up
  rather than double-spawning, then re-evaluate next cycle.

Always exit 0; the verb is advisory, not authoritative — the
orchestrator still owns the call and may override on loaded-context
or cross-issue-spillover grounds the helper can't see.

### Mechanism — `claude --continue` against a retained window

The retained worker's tmux window still exists; its
underlying Claude session is the most recent one in its
workdir's `~/.claude/projects/<slug>/`. To re-engage:

1. Confirm the window is alive: `tmux list-windows | grep <name>`.
2. Confirm pane state: `monitor/pane-state.sh <window-index>` — must be
   one of `idle`, `autosuggest-only`, `empty`.
3. Paste the follow-up via `monitor/paste-followup.sh
   <window> --file <msg>` (see `skills/nexus.tmux-spawn/SKILL.md`
   "Sending follow-up messages") — it stamps the machine-input
   ledger (issue #201) and handles the VI-mode insert guard.

Note: `claude --continue` is the CLI for *starting a new
session* by resuming the most recent transcript in the cwd —
useful when the window has been closed but the prior session
jsonl is still on disk (see "Optional resumption" below). To
re-engage a still-running retained worker you just paste into
the existing tmux window; no `--continue` call is needed.

After the user's follow-up is delivered, the worker should
re-wrap with a fresh `monitor/ng wrap-up` once the new task
finishes (auto-retain refreshes the TTL on each successful
wrap-up).

## Pre-close requirements

`monitor/ng wrap-up-check <window>` collapses checks 1 + 2 + a
piece of check 4 into one verb and is the recommended pre-flight
when an orchestrator script automates close. Exit 0 means
`status=ok` (safe to close); exit 1 names the missing obligation
(`wrap_up=missing` / `report_check=fail` / `rocket=missing`).
Mirror the manual list below when the verb is unavailable.

### Hard gate 0 — the synchronous pre-kill preflight (MANDATORY, inviolable)

**Before ANY `tmux kill-window` on a worker window, the
orchestrator MUST run `monitor/retire-preflight.sh <window>`
(alias `ng retire-preflight <window>`) and
ABORT the kill unless it exits 0 with `safe=1`.** This is the
safety floor for an irreversible action; there is no exception
and no override. The other pre-close checks below assume the
worker is genuinely quiet — this gate is what makes that
assumption safe at the instant of the kill.

```bash
if pf=$(monitor/retire-preflight.sh "$WIN"); then
    : # safe=1 exit 0 — proceed to the checks below, then kill
else
    # safe=0 / exit 2 / exit 3 — treat the window as operator-driven.
    # Do NOT kill. Leave it, surface to the operator, re-evaluate next
    # wake. The reason= field says why (fresh operator submit, pane
    # user-typing/busy, valid engaged mark, or pane unverifiable).
    echo "retire aborted: $pf"
fi
```

Why this gate exists — the **2026-06-15 incident**: the orchestrator
killed worker window `pr277-liveness-review` **9 seconds after the
operator submitted a directive into it**, destroying an in-flight
interaction (recovered only because the session jsonl was resumable).
The operator's prompt landed at 13:38:20; the orchestrator ran
`tmux kill-window` at 13:38:29 from a 13:37:47 poll snapshot that
predated the submit. Engagement attribution is poll-driven (~60 s
lag) and **no poll ran in the 9 s gap**, so `operator-engaged.tsv`
never marked the window and every snapshot-based check read it as a
retire-eligible `wrapped + idle` window.

`retire-preflight.sh` closes that gap because it reads **LIVE** state
synchronously, not the stale poll snapshot: the authoritative live
pane-state (`user-typing` / `busy` / `working-*` / `blocked` /
unreadable → no-go), the **raw** `UserPromptSubmit` stamp
(`monitor/.state/user-prompt/<window>`, attributed against machine
input exactly as the watcher does — so a just-arrived operator
submit counts *before* the poll attributes it), a live
**`skeptic-pending` marker** (check 1b, `#285`: a required skeptic
that has not yet returned a verdict — the task is not done, so the
window cannot retire; see [`skills/nexus.skeptic`](../nexus.skeptic/SKILL.md)),
and a valid `operator-engaged` mark. It is cheap, side-effect-free, and
**conservative — any doubt is a no-go** (a deferred retire costs one
wake cycle and is fully recoverable; a wrong kill destroys live
operator context). Treat exit `1` (no-go), `2` (bad usage), and `3`
(window absent from tmux) all as "do not kill"; only `safe=1` /
exit 0 authorizes the kill. This gate sits **above** every retention
and wrap-up consideration — it is the last synchronous re-check
between the decision and the irreversible action.

Before any `tmux kill-window` (after Hard gate 0 returns `safe=1`):

1. **Report exists and passes `report-check`.** A matching
   report is present and `monitor/ng report-check
   <path>` exits 0 — i.e. the frontmatter, the five sections
   (`Summary`, `What Was Done`, `Current State`,
   `What Remains`, `How to Resume`; `Infrastructure Issues`
   conditionally), and the body length (≥
   `monitor.report_min_chars`, default 500) all check out.
   When the watcher's idle-workers section already shows
   `wrapped-but-stub`, this step has effectively failed
   upstream — paste the finish-and-expand follow-up and
   re-check on the next wake. Don't close until either
   `report-check` passes or the long-idle-without-report
   hard timeout fires.
2. **Wrap-up event recorded.** The action log
   (`monitor/.state/action-log.jsonl`) carries an `event:
   "wrap-up"` entry whose `issue=` extra matches this
   window's tracking issue. The worker floor's final step
   is `monitor/ng wrap-up <issue> <report-path> ...`, which
   uploads the report, posts the link comment, rockets the
   trigger comment, and appends this log line. Verify with:

   ```bash
   grep '"event":"wrap-up"' monitor/.state/action-log.jsonl \
       | grep "\"issue\":\"$N\"" | tail -1
   ```

   - **Report present AND wrap-up event recorded** → proceed
     to step 3.
   - **Report present, wrap-up event missing** → paste the
     wrap-up-missing follow-up (below) and re-check on the
     next wake. Don't close: the issue thread still has no
     link comment, so the user can't follow the work to the
     report.
   - **Report missing AND wrap-up event missing** → fall
     through to the existing long-idle-without-report path
     ("Long-idle without report" trigger above).
3. **Live state acknowledged.** If the worker's last report
   mentions a Slurm job ID, a notebook kernel, or a
   partially-merged branch, confirm `How to Resume`
   captures enough context for a successor (or the user) to
   pick it up. If not, paste a request for the missing
   details before closing.
4. **No newer activity.** Re-read `pane-state.sh` and the
   session jsonl mtime immediately before kill — a worker
   that resumed during your survey is no longer a close
   candidate. Skip and re-evaluate next wake. **Hard gate 0
   (`retire-preflight.sh`) automates this check synchronously
   and is the authoritative version** — it reads the raw
   `UserPromptSubmit` stamp, so it catches a just-submitted
   operator prompt the poll snapshot has not yet attributed.
   This manual re-read remains as belt-and-suspenders.
5. **Not operator-engaged.** A live `operator-engaged`
   classification in the idle section vetoes the close. Trust
   that emitted class, not the bare presence of a row in
   `monitor/.state/operator-engaged.tsv`: since the
   <your-org>/<your-nexus>#205 follow-up the mark is **self-expiring**
   — `_openg_marked` holds it only while the pane has changed
   within `monitor.operator_engaged_change_ttl_seconds` (default
   600), so a row can persist on disk while its mark has already
   lapsed (pane static past the TTL → the window is back to its
   normal class and IS retire-eligible). The
   `engaged-close-reminder` row is a relay-to-operator advisory,
   NOT close authorization. The operator owns an engaged window;
   closing it mid-conversation destroys loaded context the user
   is actively using (issue #196 — exactly this mistake prompted
   the rule). Close only on the operator's explicit say-so, after
   the mark self-expires (the window re-surfaces under its normal
   class), or after a newer wrap-up/spawn has invalidated it.
   Skip and
   re-evaluate next wake.

### Follow-up message templates

Paste each via `monitor/paste-followup.sh <window> --file
<template>` (see `nexus.tmux-spawn` "Sending follow-up
messages") — the helper stamps the machine-input ledger so
the watcher doesn't misread the resulting busy turn as
operator engagement (issue #201), and handles the VI-mode
insert guard itself.

**Finish-and-report** (long-idle without report):

```
You appear idle. Please write your final report at
<reports-dir>/<project>_<YYYY-MM-DD>_<HHMMSS>_<slug>.md
(sections: What Was Done / Current State / What Remains /
How to Resume; Infrastructure Issues if applicable) and
end your turn. The orchestrator will close this window
after the report lands.
```

**Finish-and-expand** (stub report):

```
Your report at <path> is missing required sections. Please
expand it to include What Was Done / Current State /
What Remains / How to Resume and end your turn. The
orchestrator will close this window after the file is
substantive.
```

**Wrap-up missing** (report present, but no `wrap-up` action-log
entry):

```
Your report at <path> is on disk but no `wrap-up` event landed
in monitor/.state/action-log.jsonl — the issue thread doesn't
have your link comment yet. Please run:

    monitor/ng wrap-up <issue> <path> \
        --trigger-comment <id> --repo <owner>/<repo>

and end your turn. The orchestrator will close this window
after the log entry appears.
```

**Stuck** (case A / B / C unstick exhausted):

```
This window appears stuck and the unstick library has
exhausted its retries. Please write your final report
capturing what was attempted and why the work blocked,
then end the turn — the orchestrator will close the window.
```

**Background-child clarification** (`idle-children-clarify` /
`wrapped-with-children`, <your-org>/nexus-code#455 refine): the
worker is idle (or wrapped) but still has ≥1 live background-shell
child. Ask it to declare the job's health + expected runtime via
the health FILE — the watcher reads the file, not the pane text, so
a prose reply in the pane does nothing.

```
You are idle but still have a live background child process (a job
you launched with run_in_background / & disown). The watcher can't
tell whether you are legitimately waiting on a long job (e.g. a
Slurm job) or the child is stale/leftover. Tell it by running ONE
of these — do NOT just answer in the chat, the watcher reads the
FILE:

  # still waiting on a live job — declare the remaining runtime so
  # the watcher stays quiet until it should reasonably be done:
  monitor/worker-health.sh --health running --kind slurm \
      --job-id <id> --runtime <seconds> --note "<what it is>"

  # the job finished; the child is leftover and this window is done:
  monitor/worker-health.sh --health done --note "<context>"

  # your wait is wedged and you need help:
  monitor/worker-health.sh --health stuck --note "<what is stuck>"

Then continue waiting (running) or end your turn (done/stuck).
```

Paste it the same way as the others (`monitor/paste-followup.sh
<window> --file <template>`). For a `wrapped-with-children` window
the same template applies — a `done` answer confirms the children
are leftover and the window is safe to close.

## Mechanism

For each window cleared by triggers + retention + pre-close.
**Capture the workdir and the session jsonl uuid BEFORE the
`tmux kill-window`** — both vanish at kill time and the
`window-close` log entry is the only way to reconstruct them
later (see "Optional resumption" below; usually a fresh worker
referencing the prior report is preferred, but the recording
makes resume-from-the-same-session viable as a last resort).

```bash
WIN='<window>'

# 0. MANDATORY synchronous pre-kill gate (Hard gate 0 above). Reads
#    LIVE state — a fresh operator submit between the retire decision
#    and this kill aborts here even if no watcher poll has attributed
#    it yet (the 2026-06-15 incident). NEVER skip this; NEVER kill on
#    a non-zero exit.
if ! pf=$(monitor/retire-preflight.sh "$WIN"); then
    echo "retire-preflight veto — NOT killing $WIN: $pf" >&2
    # Leave the window for the operator; re-evaluate next wake.
    return 1 2>/dev/null || exit 1
fi

# 0b. Re-resolve the window NAME → its current @id and target every
#     tmux op below by id (#323). A dotted name (`cc-update-2.1.183`)
#     handed to `display -t name` / `kill-window -t name` dot-parses as
#     window.pane → `can't find pane …` → the kill silently no-ops and
#     the window leaks. The @id is per-server-lifetime, so we re-resolve
#     here (NAME is the durable key) rather than caching it across turns.
WID=$(monitor/_tmux-window.sh id "$WIN") \
    || { echo "could not resolve @id for $WIN — already gone? tmux list-windows to confirm" >&2; return 1 2>/dev/null || exit 1; }

# 1. Capture the workdir from the live pane BEFORE kill.
WORKDIR=$(tmux display -p -t "$WID" '#{pane_current_path}' 2>/dev/null || true)

# 2. Locate the worker's most recent session jsonl. Claude Code
#    writes to ~/.claude/projects/<workdir-slug>/<uuid>.jsonl;
#    the slug is the workdir path with '/' -> '-' (verify by ls).
SLUG=$(printf '%s' "$WORKDIR" | sed 's|/|-|g')
JSONL=$(ls -t "$HOME/.claude/projects/$SLUG/"*.jsonl 2>/dev/null | head -1)
SESSION_ID=$(basename -s .jsonl "$JSONL" 2>/dev/null || true)

# 3. (Optional) post a brief closing message into the worker's
#    transcript. Forensically useful; the session log retains
#    it as the last user turn. Skip when the worker is stuck
#    or absent — the paste won't be processed and adds noise.
cat > /tmp/closing-$WIN.txt <<'EOF'
Closing this window — thanks for the work. If more context
is needed, the user will reach back on issue `#<n>`.
EOF
monitor/paste-followup.sh "$WIN" --file /tmp/closing-$WIN.txt \
    --note "closing notice"
rm -f /tmp/closing-$WIN.txt

# 4. Kill the window (by the @id resolved in step 0b — never `-t "$WIN"`,
#    which dot-parses a dotted name and silently leaves the window alive).
tmux kill-window -t "$WID"

# 5. Log the close. workdir + session-id feed `ng respawn
#    <window>` (the canonical resume surface) if the
#    fresh-spawn-with-report-reference path doesn't fit.
monitor/ng log-action monitor \
    --event window-close \
    --extra "window=$WIN" \
    --extra "report=<basename-or-none>" \
    --extra "workdir=${WORKDIR:-unknown}" \
    --extra "session-id=${SESSION_ID:-unknown}" \
    --note "<reason: wrapped-idle | long-idle-no-report | stuck-exhausted | tmux-absent>"

# 6. (Optional) prune the worker's worktree if it had one
#    AND the branch is merged or abandoned. Conservative —
#    leave the worktree in place when the branch is unmerged.
git -C work/<project> worktree list
git -C work/<project> worktree remove ../<project>-<task>   # only if safe
```

### Optional resumption (last-resort, not the default)

The captured `workdir` + `session-id` make `claude --resume`
viable on a closed worker, but **the preferred path remains
spawn-a-fresh-worker-with-the-prior-report-as-context**. A
fresh worker reading the report gets a clean conversation
window and re-derives any in-progress decisions; resuming
re-attaches to a session whose conversation may carry stale
state (loaded data references, partial tool outputs, an old
TODO list). Use resume only when:

- The prior session held loaded context the report can't
  cheaply re-derive (large dataset in a kernel, partial
  training run, ipython namespace), AND
- The work that needs to continue is a direct extension of
  the prior turn, not a new direction.

When resume IS the right call, use the canonical respawn
surface — never a hand-rolled `tmux new-window … claude
--resume`:

```bash
monitor/ng respawn <window>
# equivalently: monitor/spawn-worker.sh --resume <window>
```

It resolves the session-id and workdir automatically (report
frontmatter → the `window-close` log entry recorded at kill
time → freshest project-dir jsonl) and recreates the window
with full spawn parity: the `NEXUS_ROOT` /
`NEXUS_WORKER_WINDOW` env exports every worker-settings hook
depends on, `--settings`, window options, cwd pin, and fresh
lifecycle anchors. A manual resume that loses the env exports
breaks heartbeat / async-launch / pending-tool / notification
hooks with `worker-heartbeat.sh: not found` on every tool use.
Workers that were BUSY at death get a continuation prompt
automatically (`claude --resume` alone does not restart an
interrupted turn). See `skills/nexus.tmux-spawn/SKILL.md`
"Resuming a closed worker" for variants (`--replace`,
`--nudge`/`--no-nudge`, `--dry-run`, explicit session-id /
workdir overrides).

If every source was logged as `unknown` (live pane was absent
at close time) and no report or transcript survives, resume is
not available and the fresh-spawn path is the only option —
`ng respawn` fails loud naming what it tried.

The dashboard's running-agents table updates on the next
`monitor/ng dashboard put`, folded into the next wake
naturally — no separate dashboard step needed.

## Cadence

Cleanup is **opportunistic, not scheduled**. The survey runs
once per wake (after `bootstrap.sh`, before processing the
watcher diff); most surveys produce an empty close list. The
orchestrator's existing wake cadence — driven by the
watcher's poll interval — is exactly the right frequency for
checking whether retention reasons still apply. When the
High-pressure total-count condition (`busy + idle + retained
> 10`) holds, escalate the survey to **propose + name
candidates** every wake, not just inventory — the goal is to
walk the workspace back under the threshold. A separate
cron would either fire too often (fighting the retention
overrides on every minute) or too rarely (letting the
running-agents table balloon between cron firings).

The watcher's idle-worker probe (`_idle_probe.sh`) **detects**
idle + wrap-up state but does **not** decide close. Detection
is cheap, deterministic, and load-bearing for the orchestrator's
wake survey; the close decision still depends on retention
overrides the watcher can't see (recent user engagement, loaded
kernel cost, cross-issue spillover). Do **not** push retention
or close logic into `monitor/watcher/*`, and do **not** add a
`monitor/ng prune-windows` verb — both would convert a
judgement surface into a clock-driven mechanism that closes
windows the user wanted kept.

## Tombstone rule — every resurfaced `idle_prompt` decision MUST be acked

The watcher's `render_pending_decisions` re-emits every
`monitor/.state/decisions/<window>.<fp>.json` each cooldown period
(default 300 s) **until** a sibling
`monitor/.state/decisions/<window>.<fp>.handled.json` exists. There is
no other durable suppressor — `window-retain` does not stop decision
re-emits, and the `operator-engaged` mark only suppresses `idle_prompt`
kinds while the mark is valid.

**Every resurfaced `idle_prompt` decision MUST receive a recorded
disposition. Never ignore one as "noise."** The orchestrator's choices:

| Window kind / situation | Action |
|---|---|
| Finished task worker | Close the window (existing retire flow). The close removes the decision file via its retire steps. |
| Operator-manual window (no provenance record) | Tombstone with `reason: user-owned-idle`. DO NOT manage the window. |
| Interactive window the operator still wants open | Tombstone with `reason: interactive-kept`. Optionally log a `window-retain` event too. |
| Interactive window ready to retire | Run the interactive auto-retire flow (see below) — tombstone is written as the last step with `reason: interactive-auto-retired`. |

**Tombstoning the decision signal is NOT "managing the window"** — it
does not kill, paste into, or inspect the pane. It records the
orchestrator's judgment and stops the re-emit flood.

### Why the periodic re-emit happens

`render_pending_decisions` in `monitor/watcher/_idle_probe.sh` emits
every active decision that has no `.handled.json` sibling, gated only
by the re-emit cooldown and a valid `operator-engaged` mark. Once the
`operator-engaged` mark self-expires (pane static past
`monitor.operator_engaged_change_ttl_seconds`, default 600 s), the
`idle_prompt` decision resurfaces again — and keeps doing so every
cooldown period forever, even after the window closes. Without a
tombstone, a single ignored decision from a long-dead window
re-fires indefinitely.

### Tombstone recipe

```bash
WIN='<window>'
FP='<12-hex-fingerprint>'  # from the emit line: fp=<FP>
REASON='<user-owned-idle | interactive-kept | interactive-auto-retired>'
DECISIONS_DIR="$NEXUS_ROOT/monitor/.state/decisions"

jq -n \
    --arg window "$WIN" \
    --arg fp     "$FP" \
    --arg reason "$REASON" \
    --arg ts     "$(date -Is)" \
    '{"window": $window, "fp": $fp, "reason": $reason, "ts": $ts}' \
  > "$DECISIONS_DIR/${WIN}.${FP}.handled.json"
```

The watcher skips any `*.handled.json` file on the next cycle; the
decision disappears from the pending-decisions section. The original
`<window>.<fp>.json` may optionally be left in place (it acts as an
audit record) or removed — the watcher only reads it when no
`.handled.json` sibling exists.

## Interactive-window auto-retire lifecycle

Windows spawned with `--kind interactive` (see
`skills/nexus.tmux-spawn/SKILL.md`) are operator-engaging conversation
windows that should **last, but not forever**. Their lifecycle diverges
from task workers in two important ways:

- They are NOT retire-eligible on a normal `wrapped + idle` cycle
  (the operator may return with follow-up questions).
- They ARE retire-eligible once the operator has been away for a full
  reminder period: the watcher emits `engaged-close-reminder` (see
  the window-cleanup trigger table above) after
  `monitor.operator_engaged_close_reminder_seconds` (default 86 400 = 24 h).

**The orchestrator CONSUMES the `engaged-close-reminder` signal for
interactive windows by running the interactive auto-retire flow below.**
No new watcher timer is needed — the reminder is already the
"operator away too long" surface.

### Interactive auto-retire flow

When the watcher emits `engaged-close-reminder` for a window AND that
window's provenance record (`monitor/.state/windows/<window>.json`)
has `"kind": "interactive"`:

1. **Verify a resumable provenance record exists.** The session-id
   must be resolvable by `monitor/spawn-worker.sh --resume --dry-run
   <window>`. If it fails, attempt to collect it from the heartbeat
   (`monitor/.state/heartbeat/<window>.json`) and log a `window-close`
   event manually with `session-id=` captured — so resume is possible.

2. **Refresh the overview registry.**
   ```bash
   monitor/ng interactive-sessions --upsert-overview
   ```
   This ensures the overview shows the window as available for resume
   BEFORE it closes.

3. **Run the standard pre-close check.** Skip the wrap-up requirement
   for interactive windows: they may not have filed a formal report
   (they are conversation windows, not task workers). The orchestrator
   still verifies the session-id is logged and that no active work is
   in flight (pane not `busy`).

4. **Close the window** using the standard mechanism (log `window-close`
   with `reason=interactive-auto-retired`, then `tmux kill-window`).

5. **Tombstone any pending decision** for the window:
   ```bash
   for f in monitor/.state/decisions/"${WIN}".*.json; do
       [[ -f "$f" ]] || continue
       [[ "$f" != *.handled.json ]] || continue
       fp=$(basename "$f" .json); fp="${fp##*.}"
       jq -n --arg w "$WIN" --arg fp "$fp" \
              --arg r "interactive-auto-retired" --arg ts "$(date -Is)" \
           '{"window":$w,"fp":$fp,"reason":$r,"ts":$ts}' \
           > "monitor/.state/decisions/${WIN}.${fp}.handled.json"
   done
   ```

### Distinction from task retire

| Aspect | Task worker | Interactive window |
|---|---|---|
| Retire trigger | `wrapped + idle` or `idle-too-long` | `engaged-close-reminder` (operator away ≥ reminder period) |
| Wrap-up required before close? | Yes | No (conversation window; session-id record is sufficient) |
| Overview registry updated? | No | Yes (step 2 above) |
| Close reason | `wrapped-idle` / `long-idle-no-report` | `interactive-auto-retired` |
| Resume path | Fresh worker with `-r prior-report` | `monitor/spawn-worker.sh --resume <window>` |

### Configuring the inactivity threshold

The interactive auto-retire TTL is driven by the same config key as the
`engaged-close-reminder` cadence:

```
monitor.operator_engaged_close_reminder_seconds  (default 86400 = 24 h)
MONITOR_OPERATOR_ENGAGED_CLOSE_REMINDER_SECONDS  (env override)
```

To adjust it (e.g. shorten to 4 h for transient interactive sessions):

```yaml
# config/nexus.yml
monitor:
  operator_engaged_close_reminder_seconds: 14400
```

## Out of scope

- **Watcher / orchestrator window cleanup.** Governed by
  the mutual-liveness contract in `monitor/README.md`. Never
  close them under this policy. A `monitor/watcher/*` change
  landing on `main` normally needs no manual restart at all —
  the version-aware watcher self-restarts after the pull
  (`monitor/watcher/_version_restart.sh`, issue #186). If you
  do restart manually, **don't rely on `tmux kill-window -t
  watcher` to terminate the process** — `main.sh` detaches from
  the pane and survives as a PPID=1 orphan (issue #106). Use
  `monitor/watcher/launcher.sh --replace` (`--target` defaults to
  config `monitor.target_window` — never hard-code it),
  which SIGTERMs the recorded pid (escalates to SIGKILL after
  5s) and respawns; or `kill $(cat monitor/.state/watcher.pid)`
  manually before invoking the launcher.
- **Auto-close in the watcher.** See "Cadence" above — the
  watcher detects idle + wrap-up state and emits, but never
  pastes follow-ups or kills windows. Detection is shell-only
  and lean; close-decision lives in the orchestrator.
- **A `monitor/ng prune-windows` verb.** The four mechanism
  steps are trivial single-line invocations. Bundling them
  into a verb hides the per-window judgement the policy
  depends on.
- **Worker-driven cleanup.** Workers do not close
  themselves and do not close siblings — every close
  decision is the orchestrator's.

## See Also

- `monitor/retire-preflight.sh` — Hard gate 0, the MANDATORY
  synchronous go/no-go run immediately before every
  `tmux kill-window`. Reads live pane-state + the raw
  `UserPromptSubmit` stamp + the operator-engaged mark; `safe=1`
  exit 0 authorizes the kill, anything else aborts it. Closes
  the 2026-06-15 retire-the-just-re-engaged-window race.
- `nexus.tmux-spawn` — the spawn lifecycle this policy pairs
  with. Window naming, paste-buffer follow-up pattern, and
  the VI-mode hazard live there.
- `nexus.report` — what counts as "the report exists":
  required sections, the slug convention, the
  Infrastructure Issues feedback loop.
- `monitor/README.md` — watcher / orchestrator mutual-
  liveness contract; the rules that govern the
  `watcher` and `orchestrator` windows themselves (out of scope
  for this skill).
- nexus root `CLAUDE.md` — workspace-level architecture,
  including the watcher-touching-work isolation rule that
  often dictates whether a closed worker's worktree should
  be pruned.
