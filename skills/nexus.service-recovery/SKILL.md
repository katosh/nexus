---
description: "Orchestrator response protocol for a watcher service-health emit (`--- service health ---`): restore first (minimal downtime), dispatch a root-cause worker, open an operator incident issue via `ng service-incident`, apply a reversible documented fix, then verify and close the loop. The availability-and-trust contract for registered infra services."
---

# nexus.service-recovery — responding to a service-health emit

TRIGGER when: an orchestrator emit carries a
`--- service health ---` section — a registered infra service
(`monitor/services.registry`) failed its healthcheck and the
watcher's `service_health` task surfaced a `grace`, `recovering`,
`emit-only`, `flapping`, or `recovered` condition.

## Why this protocol exists

A user-facing service going down is an availability-and-trust
incident, not a routine notification. The operator's contract is
explicit: when a service goes down it must be **restored with
minimal downtime**, the failure must be made **not to reoccur**
via a fix that is **reversible and does not degrade or falsify
the service for the user**, and an operator nexus issue must
record **what changed, when, how the service was impacted, and
how to undo it.** This protocol is the unmissable sequence that
honours that contract. It is orchestrator-driven; the watcher has
already done the first-aid (a grace-gated, policy-aware
flap-controlled auto-restart) but the watcher never dispatches
workers or files issues.

## What the watcher already did (read the emit first)

The `service_health` task (`monitor/watcher/_service_health.sh`)
runs every registry service's column-4 healthcheck on a ~120 s
cadence. It deliberately does **not** restart on the first failed
check — that would fight the service's own `*-supervised.sh`
wrapper. It first grants a **self-heal grace window**
(`grace_seconds`, default 30); only a service still unhealthy after
grace (wedged, or wrapper dead) is acted on, and then **only per
the service's restart policy** (registry 6th column, or
`default_policy`): `auto-restart` does a minimal-downtime restart
via `monitor/svc.sh restart <svc>` (stops a wedged supervisor's
process group, then relaunches through `recover_service`);
`emit-only` never auto-restarts and escalates to you instead. The
emit **always reports the full state** — read it first; it tells you
the policy and exactly which path fired:

- **`grace`** — unhealthy but inside the self-heal window; the
  watcher is deferring to the supervisor. **Informational, no
  action** — it will either self-heal (→ `recovered`) or, after
  grace, act/escalate. Don't pre-empt it unless you have reason to.
- **`recovered`** — a transient blip that resolved (self-healed
  within grace, or an auto-restart that held). A one-shot
  breadcrumb; **no action required** unless you want a record.
- **`recovering`** — an auto-restart was issued and the watcher is
  waiting to verify on its next tick. Confirm it comes back; if it
  does, it converts to `recovered`. If it does not, it escalates.
- **`emit-only`** — the service's policy forbids auto-restart, so
  the watcher escalated to **you** after grace. **Actionable — your
  judgment is the point.** Decide whether a restart is safe, then
  run the protocol below (restore only if appropriate).
- **`flapping`** — the auto-restart **gave up** after hitting the
  flap ceiling. **The actionable failure case — run the full
  protocol below.**

The emit cites the per-service incident state file
(`monitor/.state/service-health/<svc>.state`) and event history
(`<svc>.events`) — the machine record the issue generator reads.

## The protocol — five steps, in order

### 1. Restore first (minimal downtime)

Availability before diagnosis. If the auto-restart already
recovered the service (`recovered`/`recovering` → verify), confirm
it is healthy and move on. Otherwise restore it **immediately**,
before anything else:

```
monitor/svc.sh restart <svc>      # stop (incl. a wedged supervisor) + relaunch
monitor/svc.sh status             # confirm it reads healthy
```

Do **not** edit the service to make its healthcheck pass — never
degrade or falsify the service for the user (the operator's
explicit constraint). If it genuinely cannot be honestly restored,
say so in the issue and keep it flagged rather than faking health.

### 2. Dispatch a root-cause worker

Spawn a tmux worker (`skills/nexus.tmux-spawn`) to find **why** it
failed and make it not reoccur. If the fix touches watcher or
service code, give the worker an **isolated clone** (the
watcher-branch-isolation rule in `CLAUDE.md` / `nexus.tmux-spawn`).
The worker's mandate:

- Diagnose the root cause from the logfile + the incident
  `.events` history.
- Design a fix that is **reversible** (a clean commit / PR that can
  be reverted) and **non-degrading** — it restores correct
  behaviour, it does not weaken the healthcheck or fake the service
  output. The fix lands in step 4; this step starts the
  investigation and assigns the mandate.
- Write a `reports/` file and wrap up normally.

### 3. Open an operator incident issue

Generate the structured incident report **from the recorded
state** so the prose cannot drift from the machine facts, then file
it on the operator nexus repo with the bot identity:

```
monitor/ng service-incident <svc> > /tmp/incident-<svc>.md
# fill in the Root-cause fix + impact placeholders (the rest is
# pre-filled from the state file + event timeline), then:
monitor/ng issue create \
    --title "service incident: <svc> down YYYY-MM-DD" \
    --body-file /tmp/incident-<svc>.md
```

The generated report **leads with a plain-language operator TL;DR**
— a non-technical "what happened / what this means for you / what
you should do" header an operator who only knows biology + basic
compute can act on, followed by a copy-pasteable recovery runbook
(detach the **nested** sandbox tmux with `Ctrl-a` then `d` — **not**
the outer `Ctrl-b` meta key — and restart with `agent-sandbox tmux
new-session ./watcher --continue`, with a `monitor/svc.sh restart
<svc>` fallback for the non-sandbox case). This mirrors the
EROFS-incident body in `monitor/watcher/_lib.sh`
(`_nexus_incident_issue_body`) so the operator meets the **same**
recovery procedure everywhere. **Leave that opening in** when you
file — it is the audience-first lead, deliberately ahead of the
machine facts.

Below the human lead it carries the five required sections —
**Failure report** (what went down, when, the failing
healthcheck, user-facing impact), **Immediate response** (the
auto-restart + any manual restart), **Root-cause fix** (what
changed, where, **how to undo**), **References** (logs, related
issues/PRs/commits), and **Worker report** (link the fix-worker's
report). Fill the **Root-cause fix** + **User-facing impact**
placeholders before filing. Wrap bare `#N` as `` `#N` `` in the body.

### 4. Apply the fix — reversible and documented

This is the step that actually repairs the root cause; the
preceding steps restored availability and recorded the incident,
but the service is not *fixed* until this lands. The fix-worker
from step 2 now produces the change. It is **not done** until all
three hold:

- **Reversible.** The fix lands as one reviewable, revertible unit
  — a PR, or a single clean commit — never a silent in-place
  mutation of the running system. The **exact undo path** is
  recorded: the commit to `git revert <sha>`, or the config value
  to restore. Anyone must be able to reverse it from the issue
  alone.
- **Non-degrading.** It restores correct behaviour and removes the
  failure mode. It does **not** weaken or disable the healthcheck,
  fake the service's output, or otherwise falsify health to make
  the check pass (the operator's explicit constraint, repeated here
  because this is where the temptation lives). If the root cause
  genuinely cannot be fixed without a trade-off, state the
  trade-off in the issue and get the operator's call — do not paper
  over it.
- **Documented.** The fix's **what / when / impact / undo** is
  written into the incident issue's **Root-cause fix** section (the
  same fields `ng service-incident` pre-templates: what was
  changed, where — file · commit SHA, how to undo, why it will not
  reoccur), and the fix-worker's `reports/` file is linked. Prose
  must match the landed commit, not intent.

Only once the fix is applied **and pushed** (and merged, or
explicitly tracked for merge) does the protocol proceed to verify.
Do not close the loop on a dispatched-but-unlanded fix.

### 5. Verify the fix holds and close the loop

Verify the fix holds and the service is stable across at least one
health cadence, confirm the **Root-cause fix** + worker-report
link from step 4 are in the issue, and update/close the issue once
confirmed. A `flapping` incident is not done until the service has
been healthy long enough that the watcher closed its incident
state (the emit stops re-surfacing).

## Tuning knobs (surface, don't silently retune)

The watcher defaults are sensible; if an incident reveals they are
wrong for a service, note the trade-off in the issue so the
operator can retune (`config/nexus.yml`, `monitor:` block):

- `monitor.service_health.interval_seconds` (default 120) —
  detection cadence.
- `monitor.service_health.grace_seconds` (default 30) — self-heal
  window the watcher defers to the supervisor before acting. Raise
  it if a service legitimately takes longer to come up and the
  watcher restarts too eagerly; lower it (or 0) for faster wedged
  recovery at the cost of possibly racing the wrapper.
- `monitor.service_health.default_policy` (default `auto-restart`)
  — policy for registry rows without an explicit 6th column. Pin a
  specific service to `emit-only` (its registry 6th column) when a
  blind restart is unsafe or you want to make the call yourself.
- `monitor.service_health.restart_cooldown_seconds` (default 300)
  — min seconds between auto-restarts of the same service.
- `monitor.service_health.flap_ceiling` (default 3) — attempts
  within one incident before the watcher gives up and escalates.
- `monitor.service_health.enabled` (default true) — master switch.

## Arming the watcher-supervisor Monitor (mutual-liveness)

The watcher revives the orchestrator; the orchestrator revives the
watcher. The orchestrator's half is a persistent `Monitor` IT owns —
the external always-on loop a crashed watcher needs (no daemon). Arm
it once per orchestrator session, and re-arm whenever a watcher emit
carries **`--- arm watcher supervisor ---`** (the supervisor heartbeat
went stale — e.g. you were just (re)started):

```
Monitor({command: 'until ! <NEXUS_ROOT>/monitor/watcher-supervise-tick.sh; do sleep 15; done'})
```

Each tick touches the supervisor heartbeat (clearing the watcher's
reminder) and reports watcher liveness. When the Monitor **fires** (its
until-loop exits → the watcher is DOWN), run the revive, then **re-arm**:

```
<NEXUS_ROOT>/monitor/revive-watcher.sh      # loop-guarded; reuses `svc.sh restart watcher`
# then re-arm the Monitor (same command as above)
```

`revive-watcher.sh` writes a `watcher-revived` marker the revived
watcher surfaces as `--- watcher revived (was down) ---` on its first
emit — sweep for anything missed during the outage. It refuses while an
intentional-stop sentinel exists (a deliberate `svc.sh stop watcher`);
for a lasting stop, **disarm the Monitor** (`TaskStop`) too. If the
revive guard trips (a watcher crash-looping on a real fault), it backs
off + `sandbox-notify`s — investigate (`monitor/svc.sh logs watcher`)
rather than re-arming blindly. Watcher + orchestrator down at once is
the cold-boot case (`boot-recover.sh` at SessionStart). Full design:
`monitor/README.md` "Watcher supervision — the MUTUAL-LIVENESS contract".

## Boundaries

- The watcher auto-restarts and emits; it never dispatches workers
  or files issues — that is this protocol's job.
- Service windows are **exempt from worker-dead detection**
  (`_idle_probe.sh` registry exemption); never treat a registered
  service window as a dead worker. Health is judged by the
  **registry healthcheck**, never by tmux/window heuristics.
- Keep consistent with `nexus.window-cleanup`, `nexus.tmux-spawn`,
  and `nexus.report`.
