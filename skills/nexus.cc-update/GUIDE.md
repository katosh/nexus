# nexus.cc-update — evaluating a Claude Code update before promoting it

> **On-demand reference, NOT an auto-loaded skill.** This file is named
> `GUIDE.md` (not `SKILL.md`) on purpose: it is consulted by exactly one
> agent — the evaluator the orchestrator spawns when the watcher reports
> an available update — so it is referenced by **path** and deliberately
> kept out of every agent's auto-loaded skill list (it would be pure
> distraction for the workers and turns that never do update work). The
> orchestrator reaches it via the watcher emit line, the `CLAUDE.md`
> skills table, and the evaluator's spawn prompt; no auto-discovery is
> needed. Read it (or brief a worker with it) when the trigger fires.

USE when: the watcher emit carries a
`--- claude code update available ---` section (the orchestrator is
being informed a newer Claude Code release than the local pin exists);
or an operator asks to evaluate / bump the Claude Code version; or
`monitor/.state/cc-update-available` is present.

This guide is the **EVALUATE → DECIDE → APPLY** half of the gated
Claude Code self-update loop. The watcher does the **DETECT → INFORM**
half automatically (`monitor/watcher/_cc_update.sh`, the
`cc_version_check` task on a 24 h cadence) and never bumps anything.
**You** run the evaluation and, only if it passes, perform the bump.

> **The manual "update available" emit is OFF by default.** As of the
> emit-gate change, `monitor.cc_update.emit_enabled` defaults to `false`,
> so the watcher no longer surfaces the `--- claude code update available
> ---` nag. The rationale: when the autonomous daily routine
> (`cc_auto_update`, ~04:00) is enabled, it runs THIS gate itself and the
> manual nag is redundant. Detection still runs and maintains
> `monitor/.state/cc-update-available`, so you can always `cat` it or be
> spawned to evaluate on demand. To restore the manual nag (e.g. you do
> NOT enable the autonomous routine and want a human gate), set
> `monitor.cc_update.emit_enabled: true` in your config (env:
> `MONITOR_CC_UPDATE_EMIT_ENABLED=true`) and restart the watcher.
> **Note:** silencing the emit removes the manual *trigger* only, not any
> gate — the gate lives in the autonomous routine
> (`monitor/cc-auto-update-apply.sh`), which only runs when
> `monitor.cc_auto_update.enabled: true` — and that key has two defaults:
> code default off, shipped template on (<your-org>/nexus-code#1476). Absent
> from an existing `nexus.yml` it is `false`; a tree with no `nexus.yml`
> reads `config/nexus.example.yml`'s `true`. With both off, nothing tracks
> or applies cc updates for you (detection still records the signal file,
> but nothing acts on it).

## The cardinal rule: updates are GATED, never silent

A Claude Code release can drift the exact terminal bytes
`monitor/pane-state.sh` and `monitor/watcher/_unstick.sh` parse, or
change the CLI flag / hook / settings contracts the whole control
surface rides on. When those break, the watcher mis-classifies panes,
fails to unstick dialogs, or silently drops the orchestrator — the
nexus loses its eyes and hands at once. So the flow is always:

```
detect (watcher) → inform (emit) → evaluate (you, this guide)
                 → decide → apply (bump + restart) → verify
```

Never `npm install`-bump the pin off the back of the emit alone. The
emit is an *advisory*; the gate is the *authority*.

## What is REVERSIBLE and what is NOT — read this before you defer anything

**OPERATOR DIRECTIVE, `<your-org>/nexus-code#1492` (<operator>, 2026-09-08):**

> *"we do not need to be so restrictive about halting the update. Issues keep
> coming up even though this already worked a long time ago. the watchdog is
> there to catch any issues that remain even after testing passed, and if
> testing is not passed or the watcher finds an issue we should not simply
> give up, but find the issue, file it and consider fixing it. … There is some
> fundamental misunderstanding in the design that should be resolved in its
> doc, since we keep running into unnecessary roadblocks."*

This section is that resolution. Before it existed, this guide addressed
reversibility **nowhere** — measured at `77181f33`, blob `6bb14948`:
`grep -cwiE 'rollback|roll back|revert|irreversible|reversible'` → **1**, and
that one hit (`:308`) is about shell snapshots, not about the pin. (A bare
substring `grep -ci rollback` returns **2**; both are inside the word
`scrollback`. The word-boundary form is the honest one.) A reader therefore
had no way to price the downside of applying, and priced it as permanent.

### The four things a bump touches, and which of them come back

| what moves | reversible? | by what |
|---|---|---|
| the operator-local pin (`monitor/.state/cc-version-local`) | **yes** | `cc-auto-update-apply.sh rollback` |
| the installed binary (`node_modules/`) | **yes** | the same verb reinstalls at the restored pin |
| the WATCHER process | **yes** | it is restartable and holds no unique state |
| **an agent's in-flight context, if its window is killed** | **NO** | *nothing* |

**The fourth row was the whole reason a deployment gate existed.** Everything
above it is recoverable; that row is not, and no pin restore returns it. So
the gate was never protecting the pin — the pin can be put back. It was
protecting **live agents from being restarted out from under their work**.
**Since 2026-09-12 that row is protected by the restart path, not by the
gate**: measured (w239 D13), no kill primitive on the restart path can select
a worker window — see "The board arms are gone" below — so the fourth row is
reached only by a name-resolution residual that is guarded twice and named in
the apply script's deployment-gate header.

Read the table in both directions, because both readings are corrections:

- **Do not defer to protect something reversible.** A deferral that exists to
  keep the pin safe is protecting the one thing that was never at risk.
- **The board arms are gone (2026-09-12), on the operator's go-ahead.**
  `#1492` explicitly held two changes as requiring a fresh operator go-ahead:
  removing the board-quiet arm, and applying while a worker is genuinely
  mid-task. The operator gave both at once: *"a cc-update will not kill the worker, and if they, for whatever reason, would crash, then the orchestrator can continue them with no context lost."*
  The premise was **measured before the arms went** (w239 D13, at
  `8d0cff30`): every kill primitive on the restart path enumerated — the
  watcher is reaped by process group behind an argv-identity check that
  refuses a group holding no watcher member (`_watcher_reap_group` rc 2,
  measured against a worker pane's own pgid), the orchestrator is killed by
  window name after an exact-name index resolution and a baseline pane-pid
  re-read, nothing selects a worker; `restart-orchestrator` and
  `launcher.sh --replace` driven on a private tmux with worker windows alive,
  every worker keeping its window id, pane pid and child process;
  `spawn-worker.sh --resume <sid>` driven end-to-end against an
  argv-recording stub, the window coming back under its own name with
  `--resume <sid>` and the worker env exports. **What that does not prove**:
  that Claude Code restores the conversation on `--resume` — that is Claude
  Code's semantics, and an interrupted turn's unpersisted in-flight work is
  re-derived by the continuation nudge, not restored. The board is still
  **enumerated and written to every apply record** (`live_windows=`,
  `unquiet_windows=[…]`); it no longer vetoes. `max_live_windows` is no
  longer read.

### The rollback boundary, stated exactly

`rollback_pin` inside `cmd_safe` is **not** the rollback. It is a function
local to that one call, with both call sites *before* the watcher restart, so
it covers install failure and post-install verify mismatch and nothing after
them. Probed at `77181f33` against the suite's own fixture harness:

| failure | rc | pin afterwards |
|---|---|---|
| install fails | 4 | restored |
| post-install verify mismatch | 5 | restored |
| **watcher restart fails** | 6 | **new pin stands** |
| **watchdog never arms** | 22 | **new pin stands** |
| **stale session pin** | 21 | **new pin stands** |

The externally-invocable verb closes that gap:

```bash
monitor/cc-auto-update-apply.sh rollback --reason "orchestrator unhealthy after 2.1.263"
monitor/cc-auto-update-apply.sh rollback --to 2.1.250     # explicit target
```

It restores the pin from a durable breadcrumb written *before* the pin moves
(`monitor/.state/cc-auto-update/rollback-state`), reinstalls, **verifies the
binary actually reports the restored version**, writes a restart-hold so the
reconcile cannot silently re-apply, and consumes the breadcrumb. It refuses
(exit 3) rather than guess when the breadcrumb is missing, torn, or holds a
value that is not a version — **a refusal is not a finding that the pin is
already correct.**

**It does not restore a killed agent's context.** See the fourth row.

### The watchdog is the POST-APPLY detector — so a pre-apply gate need not be perfect

`Step 5b` spawns `cc-restart-watchdog`, which carries agency through the gap
between the orchestrator's kill and its verified resume. Its mandate is to
keep **fixing** until exactly one target window runs properly on the new
binary. That is a real detector, and the gate should be calibrated knowing it
exists — which does **not** mean the gate may proceed under a live worker,
because the watchdog cannot restore what that would destroy.

Add to its playbook: if the workspace cannot be brought back to health on the
new binary, `rollback` is now an option, not just forward repair.

**The operator's tmux window selection survives the restart**
(<your-org>/nexus-code#1528). `restart-orchestrator` records, per session, the
active window before its kill (and tmux's auto-selection after it) into
`<state-dir>/tmux-selection-capture`; `_respawn_spawn_window` restores it once
the new window exists — an operator who was on the orchestrator lands on the
new orchestrator, one who was on a window that has since closed lands on the
orchestrator, anyone else stays put, and a deliberate move during the gap is
never overridden. With NO capture (the window vanished on its own — a crash
without remain-on-exit, an external kill) the watcher's rolling last-seen
snapshot (`selection_snapshot`, 10 s) decides whether the orchestrator was the
active window when it went; with no fresh snapshot the orchestrator is the
default (operator decision, 2026-09-13). Cosmetic and best-effort: it cannot
change the respawn's rc. Contract and tmux 2.6 measurements:
`monitor/_tmux-window.sh`.

### "Could not measure" is a DEFECT TO FILE, not a verdict

Three of the deployment gate's five arms used to fire when a **query
errored** rather than when a hazard was present, and each returned early — so
a broken `gh` became a stronger blocker than a busy board, and the arms below
it never ran. That is the "unnecessary roadblock" the directive names.

Since `#1492` the treatment depends on **which instrument measures the
irreversible hazard**:

| instrument | on failure | why |
|---|---|---|
| `restart-path-pr-query` | **UNMEASURED, continue** | a proxy; a stronger arm runs after it |
| `pr-activity-query` | **UNMEASURED, continue** | the weaker proxy still; its own comment concedes it does not carry the property |
| `board-enumeration` | **UNMEASURED, continue** (since 2026-09-12; was **DEFER**) | the board is recorded, not gated on — an unenumerable board writes `live_windows=UNMEASURED`, never `0` |

All three **file a defect** on the gate repo (deduplicated by key, one issue
per distinct blind spot, with a repeat count rather than a daily duplicate).
Recording and filing are not alternatives: every degraded instrument does
both.

**The ordering used to be the safety argument** — the board arms ran **last**,
so a degraded proxy could only let a bump through onto a board every window of
which positively asserted it held nothing. Since D13 removed the board arms
that argument is history; what survives is the rule that "could not look" is
never written as a confident zero.

**And the audit row now says `UNMEASURED`, never `none`.** A row reading
`restart_path_prs=none` when the probe never answered is a confident zero
standing in for "could not look" — this workspace's dominant defect class —
written into the record a later reader reconstructs the decision from.

### The doctrine this replaces

> ~~"A deferred safe-to-bump is a complete result."~~

That line appeared twice and is what encoded the give-up. **A deferral is a
complete result only when it names a hazard.** A deferral produced by the
gate's own blindness is an unfinished measurement wearing a verdict's clothes,
and the correct response to it is to file the defect and fix the instrument —
not to record the deferral and move on. `GATE_DEFER_STREAK_ALERT` makes a
never-clearing gate loud; loudness was the wrong remedy, because a gate that
reliably announces it is blocking is still blocking.

## When the gate is right and the pin still has not moved

**This section exists because the operator has raised the same complaint twice**
— *"issues keep coming up even though this already worked a long time ago …
there is some fundamental misunderstanding in the design"* (#1492), and again on
2026-09-10. Each previous round fixed the arm that fired last time. That is
treating a **trigger**. This section is about the **generator**.

### The generator: a conjunction sampled once a day

The deployment gate is **two** `_gate_defer` arms since 2026-09-12 (five before
D13 removed the three board arms) — re-derive with
`grep -cE '^\s*(if ! )?_gate_defer "' monitor/cc-auto-update-apply.sh` (anchored;
the bare `grep -c '_gate_defer "'` form counted the script's own comment and
over-reported by one). **"Seven" was wrong and it was mine to catch**: it
entered with #1492's own recalibration commit (`96450b67`), stood in this file
and in the script, and I repeated it in #1507's title without deriving it.
Corrected here, in the script, and on the issue.

Every arm is individually correct, and every individual deferral survives review
— which is exactly why this took three rounds to see. What no single audit row
shows is that they are **ANDed**, and evaluated at **one instant per day** on a
board that is busy on *some* axis nearly always.

Measured over the whole ledger — `monitor/.state/cc-auto-update/decisions.tsv`,
253 rows, 2026-06-16 .. 2026-09-09, `awk -F'\t' '$3=="safe-deferred"'`:

| arm | kind | deferrals |
|---|---|---|
| restart-path PR (`deferred-pending-PR<N>`) | proxy — **still an arm** | **5** |
| PR-under-active-review | proxy — **still an arm** | 3 |
| live-window COUNT (`live-windows=N>max=8`) | proxy — *removed 2026-09-12* | 2 |
| board-not-quiet (state) | **DIRECT** — *removed 2026-09-12* | **1** (2 by 2026-09-12) |
| board-enumeration-failed | **DIRECT** — *removed 2026-09-12* | **0** — never fired |
| **total `safe-deferred`** | | **11** (12 by 2026-09-12) |

against **33** applied bumps in the same span. **So this is not a gate that
never clears — it clears about three quarters of the time.** The failure is a
*streak*: four consecutive fires (09-07 .. 09-10) deferred on **three different
arms**. #1492 fixed the 09-08 arm; 09-09 deferred on another; 09-10 deferred on
`pr-under-active-review=PR1506` — **the very PR that adds the bound**.

**The last two rows are kept separate deliberately**, even now that both are
gone. They were the two DIRECT arms, and one of them was the arm the whole
safety case turned on until D13. An earlier draft of this table folded the
live-window COUNT together with board-not-quiet into a single "live-windows
3", which collapses precisely the proxy/direct axis the bound was built on —
and the ledger is what a future reader re-derives from.

**That distribution is the whole argument.** Fixing any one arm moves P(defer)
a little and can never drive it to zero, because the next fire draws from the
other six. And each additional arm makes the conjunction *strictly* less likely
to clear, so the gate gets tighter every time somebody correctly adds a check.

**Two corollaries worth stating, because both have already misled a round:**

- **The arm that fired last time is the least informative thing about the next
  fire.** Do not size a fix to it.
- **The work of diagnosing the gate arms the gate.** A worker spawned to
  investigate why the update will not apply is itself a live agent window. Any
  proposal whose clearing condition is "the board is quiet" has to survive the
  fact that investigating it makes the board un-quiet.

### The operator's principle, and what it does and does not license

> **"A very busy board should only DELAY the update and not PREVENT it."**

Implemented as a **bounded deferral**, not as a loosened arm:
`GATE_DEFER_STREAK_CAP` and `GATE_DEFER_MAX_AGE_SECONDS` (measured from the
streak's first deferral), whichever trips first. At the bound, the arm's veto
**expires**.

**The cap is its own constant with a FLOOR, and getting there took two failed
shapes that are worth keeping — the number is the genuinely hard part.**

| shape | outcome |
|---|---|
| `cap = 5`, a hunch | **UNREACHABLE.** Recorded streaks `1,1,2,2,3,3,4` (max **4**), longest span **3 days** — the bound never fired in 253 rows, *including during the live incident it was written for* (round 1, F4) |
| `cap` tied to the ALERT threshold | **COLLAPSIBLE TO ZERO DELAY.** `CC_AUTO_GATE_DEFER_STREAK_ALERT=1` — a plausible *"tell me about every deferral"* setting — drove the cap to 1 and expired every proxy veto on its **first** deferral (round 2, R1, measured) |
| **`cap = 3`, own constant, floor 2** | current |

**The lesson is OWNERSHIP, not arithmetic.** A **safety** threshold and a
**noise** threshold have different owners and different reasons to change, so
deriving one from the other means every future notification-tuning silently
retunes a veto — and the triggering operator action is *asking for more
information*, which is the worst possible trigger for a safety change. The claim
that replaced it, *"one calibrated constant cannot drift out of step with
itself"*, was also simply **false**: there were always two constants, the cap
and the independent age bound.

The floor is **2** because a cap of 1 overrides on the first deferral — zero
delay, and the principle is *delay*, not *never veto*. **The floor clamps and
SAYS SO**, in the log and in the audit row (`defer_cap_clamped=1`). An earlier
draft rejected clamping as *"silently disagreeing with a configured value"*;
that argument was **broader than its evidence** — it indicts a *silent* clamp,
not one that announces itself, and honouring a value that disables the mechanism
is worse.

**The cap VALUE was CHOSEN BY THE OPERATOR, not defaulted into place.**
Surfaced as a choice on #1507 and agreed **2026-09-10** (<operator>, *"cap 3 sounds
good"*). The thing agreed to is the sentence, not the integer:

> **"about three days of a busy board is enough delay before we update anyway"**

That distinction is the point. The streak distribution says which values are
**reachable**; the operator says which is **wanted**. If the routine's cadence
changes or the board's character changes, it is the sentence that has to be
re-agreed and the number follows from it — so do not re-derive 3 from the
distribution alone and conclude it is settled. The age bound is an independent second
bound expressing the same interval in TIME (3 d ≈ 3 daily fires) so a slower
cadence cannot make the mechanism unreachable — and it is that independence,
not observability, that limits the damage when the cap is misconfigured high.

**The ledger fields are a diagnostic aid, not the safety property.** Every
deferral row carries `defer_cap=`, `defer_max_age=`, `defer_cap_clamped=` and
`overridable=`, but with two honest limits: they are **prospective only**
(`defer_cap=` appears on **0** of the 253 pre-existing rows), and
`max(streak) < cap` is **not** "unreachable" — it is equally what a healthy gate
that keeps clearing looks like, so the comparison only means something read
against how often the gate cleared. The safety property is the floor.

**The streak is GLOBAL, not per-arm.** A streak earned on one proxy arm expires
the other proxy arms on their first fire. Deliberate: the operator's complaint
is "the pin has not moved", not "this arm keeps firing", and the board demonstrably
hops between arms — a per-arm counter would have reset on 09-08, again on 09-09,
and never reached any cap. The cost is real and is stated rather than hidden: a
first-ever fire of one proxy arm can be overridden on another arm's history.
The direct arms are unaffected. Pinned by case **O6**.

**The bound is OPT-IN PER ARM and the default is DENY**, and the line is the one
this guide already draws between an instrument that measures the irreversible
hazard *directly* and one that measures a *proxy*:

| arm | overridable | why |
|---|---|---|
| restart-path PR | **yes** | its own comment calls `GATE_RESTART_PATHS` a proxy |
| PR-under-active-review | **yes** | `updatedAt` recency is a proxy, as its comment says |
| live-window COUNT | *removed 2026-09-12* | a count is not a hazard; the count is still recorded |
| board-not-quiet (state) | *removed 2026-09-12* | was "measures the hazard directly"; states still recorded |
| board-enumeration-failed | *removed 2026-09-12* | now degrades to `live_windows=UNMEASURED` + a filed defect |

**An override means "this arm's veto has expired", never "proceed".** It returns
0 so evaluation **continues into the remaining arms**. Until D13 the board arms
ran **last**, so a restart-path override could not bypass the board-quiet arm —
the property `monitor/watcher/test-cc-auto-update.sh` case **O2** pinned. Since
2026-09-12 no arm follows the proxies, so an expired proxy veto **clears** the
gate while the board is written to the record; O2 now pins *that*, and O3 pins
that a busy board alone never defers. The contract is unchanged; the arm list
is shorter.

**It does not license overriding an instrument failure.** A deferral produced by
the gate's own blindness is an unfinished measurement wearing a verdict's
clothes; bounding *that* would mean applying without having looked. Case **O5**
pins the same rule one level down: an **unreadable** streak age does not trip
the bound, because *"I could not tell how long this has been blocked"* is not
*"long enough"*.

### The in-code rationale at `cmd_rollback` is HONOURED, not overridden

`monitor/cc-auto-update-apply.sh`, `cmd_rollback`'s header:

> "This restores the PIN and the INSTALLED BINARY. It does not restore a KILLED
> AGENT'S CONTEXT. The irreversible core of the restart hazard is untouched by
> this verb. Until 2026-09-12 that sentence was the reason the board-quiet arm
> stayed absolute; the operator then removed the board arms on a MEASURED
> premise …"

That argument was about the **board-quiet arm**, and it was correct as far as
it went: rollback restores nothing a killed agent held. What it never
established is that the restart path kills an agent other than the
orchestrator — and measured (D13), it does not. The bounded deferral of
`#1507` applied the operator's principle to the **proxy** arms only, which
that paragraph never covered and which produced **9 of the 10** deferrals then
recorded. D13 then removed the board arms themselves on the operator's explicit
go-ahead. **Neither step overrode the operator's own safety reasoning; the
second step measured its premise and found the veto was guarding a kill that
does not happen.**

**Read one adjacent inconsistency, though, before quoting that paragraph as if
it settled more than it does.** The same file's force-restart path says the
opposite about the one agent it actually kills:

> "FORCE restart: orchestrator not at a turn boundary within [IDLE_WAIT] s …
> restarting anyway per operator decision. **The pinned session resumes from its
> transcript, so the mid-turn kill only re-runs the interrupted turn (repeated
> tokens), not lost work.**"

and the ledger records **21** `safe-bumped-restart-forced` rows against 22
handoffs — so mid-turn force-killing the orchestrator is ordinary business here.
**The apply path kills only `TARGET_WINDOW` (the orchestrator) and
`WATCHDOG_WINDOW`; it never kills a worker window.** Whatever the board-quiet
arm is protecting, it is not workers from being killed — it is workers from a
watcher blink mid-turn, which is a real but much smaller hazard than the one the
`cmd_rollback` paragraph describes. Do not let that paragraph's *"killed agent's
context"* framing be carried onto workers unexamined. **D13 examined it**: the
kill primitives, their selectors and a hermetic exercise of both restart legs
are recorded in the apply script's deployment-gate header, and the one
residual found — tmux 2.6 resolving `-t <name>` by *prefix* when the exact
window is absent — is named there with its two guards.

### The cost, stated plainly

A bounded deferral is **not free**, and presenting it as free is how it gets
rolled back later:

- At the bound the update applies onto a board that a correct arm said was not
  ready. The residual is bounded by what runs *after* the gate — the
  orchestrator's `IDLE_WAIT` (900 s) turn-boundary wait, then a force-restart;
  the restart watchdog; and `cc-auto-update-apply.sh rollback`.
- **What none of that restores** is a worker's in-flight turn interrupted by a
  watcher blink. The watcher restart is short (measured ~4 s on 2026-09-05,
  `04:17:17` → `04:17:21`) but it is not zero.
- The bound trades a **rare, unbounded** failure (the pin never moves; the fleet
  drifts arbitrarily far behind, which is its own security exposure) for a
  **bounded, occasional** one. That is the trade the operator asked for. It is
  a trade, not a strict improvement.

### The residual the bound did NOT cover — RESOLVED 2026-09-12

*(Kept as the record of how the decision was reached. The stall this section
describes fired once more, on 2026-09-12 — `board-not-quiet=[w237=idle,
w238=working-background]` — and the operator resolved it by going past option 3
below: the board arms were removed outright, on the measured premise recorded
in the apply script's deployment-gate header.)*

The bound expires **proxy** arms. It did not touch **board-not-quiet**. So a
nexus that reliably had a busy worker at fire time could still stall
indefinitely, and the bound would not save it.

**This is not hypothetical and it is self-referential.** A worker spawned to
investigate why the update will not apply is a live agent window; while it is
mid-turn the board-not-quiet arm defers, correctly. On 2026-09-10 the board was
reported clear from roughly 15:00 the previous day until 02:00 — **entirely
between two fires** — and the ~04:00 fire found a worker running. Quiet and the
fire have to coincide by luck, and nothing steers either toward the other.
(*The 11-hour window is the orchestrator's reconstruction; I did not find a
board-state record at that resolution to confirm it independently. The design
question below does not depend on it.*)

**Three options, in increasing order of how much they give up:**

1. **Accept the delay.** Workers finish; the next fire clears. This is already
   the operator's principle applied honestly — *delay, not prevent* — and it is
   adequate **provided** the stall is genuinely self-limiting. The evidence that
   it is: 33 applies against 10 deferrals. The evidence that it may not be: the
   quiet window and the fire have never been steered toward each other.
2. **`CC_AUTO_GATE_WINDOW_EXEMPT`** for windows known to hold nothing a watcher
   blink would cost — a long-lived monitor, a parked skeptic. Cheap, already
   built, and it is an **operator judgement per window**, which is the right
   place for it. The failure mode is an exemption that outlives its reason.
3. **Bound the board-not-quiet arm too**, at a much longer horizon (weeks, not
   days), so *"delay, not prevent"* holds without exception. **This is the one
   that argues with `cmd_rollback`'s rationale**, and it should not be taken
   quietly. What can be said for it: the apply path never kills a worker window,
   only `TARGET_WINDOW` and `WATCHDOG_WINDOW`; the orchestrator's own kill
   already waits 900 s for a turn boundary and then **forces** (21 recorded
   `safe-bumped-restart-forced` rows) on the stated ground that a pinned session
   resumes from its transcript. What can be said against it: a watcher blink
   across a worker's in-flight turn is a real cost that no rollback restores,
   and it is exactly the cost the arm was built to avoid.

**Option 3 was the operator's call, not an agent's**, which is why it was
written here as a costed option rather than shipped switched on. **The operator
took it further on 2026-09-12** — not a longer horizon but removal — with the
sentence quoted under "What is REVERSIBLE and what is NOT" above, after the
premise behind it was measured (w239 D13).

### Should the FIRE be triggered by quiet instead of by the clock?

Considered and **rejected**, and the reasoning is worth keeping so it is not
re-proposed. Firing on a board-goes-quiet transition optimises the *probability
that quiet coincides with the fire*. The bound removes the need for that
coincidence **entirely**, so the trigger change buys nothing once the bound
exists — while adding a new failure mode: a brief lull mid-campaign is
indistinguishable from a finished board, and firing into it is precisely the
`#1113` hazard the board-quiet arm existed to prevent. With the board arms gone
the schedule question is moot in the other direction too: the fire no longer
waits for quiet at all. **Keep the fixed schedule.**

### "The update did not go through" — the two readings, reconciled

The routine's authors and the operator have been using the phrase differently,
and that is the "fundamental misunderstanding in the design" the operator kept
pointing at:

- To the **routine**, a recorded, unapplied safe-to-bump was a *complete
  result*. That sentence is retracted (see "The doctrine this replaces") and, as
  of this change, is gone from the code as well — it survived in **three** places
  in `cc-auto-update-apply.sh` after the GUIDE struck it, including the contract
  comment on `_deployment_gate` itself.
- To the **operator**, the deliverable is a **moved pin**. By that measure a run
  of correct deferrals is a failure however well documented each one is.

**The operator's reading is the right one**, because the routine exists to keep
the fleet current, not to produce verdicts. `gate-defer-streak` measures the gap
between the two readings; before this change **nothing consumed it** — it was
bumped, printed and cleared, and no arm read it. Loudness was already identified
as the wrong remedy: *"a gate that reliably announces it is blocking is still
blocking."*

## ⚑ SETTLED — 2.1.223/224: flagged by name, then dropped from the table

**Outcome, so the next round inherits the lesson rather than the alarm.**
`2.1.223` and `2.1.224` were evaluated together on 2026-08-07 and the
bump landed (pin `2.1.224`, gate GREEN, skeptic-confirmed safe). But of
the entries pre-flagged below **by name**, three never appeared in the
round's changelog table at all — the `bypassPermissions`, dynamic
`import()` and `sandbox.filesystem.denyWrite` entries — alongside six
others, 9 of 50 unaccounted, under the heading *"Both releases read in
full"*. They are all inert here; **that was established by the skeptic,
not by the evaluation.** This is why Step 1's completeness rule is now
mechanical (`--changelog-ledger`, `--changelog-dispositioned`).

The entries, quoted verbatim from `anthropics/claude-code`
`CHANGELOG.md` (re-fetch and re-quote before relying on this list — see
Step 1):

- *"Fixed a **Bash permission bypass** where a crafted command could hide
  parts of itself from permission checks"*
- *"Fixed permission prompts so commands **padded with tabs or invisible
  Unicode** can no longer hide part of the command from the approval
  dialog"*
- *"Fixed **workflow scripts** being able to use dynamic `import()` to run
  code outside the workflow sandbox"*
- *"Fixed a permission gap where an agent definition's
  **`bypassPermissions`** mode ignored the org bypass-permissions disable
  policy"*
- *"Fixed **sandboxed commands** failing to start on Linux when
  `sandbox.filesystem.denyWrite` covers the working directory"*
- *"Fixed **managed settings**: server-delivered settings no longer
  disable the env block of a machine-local `managed-settings.json` or MDM
  profile; admin env now merges per key"*

Why each matters HERE:

- The first two touch the **same surface as the nexus PreToolUse guards**
  (`monitor/hooks/gh-write-guard.sh`, `bash-footgun-guard.sh`), which
  pattern-match the Bash command string, and the **unstick Case A
  permission dialog** (2b). A change to how a command string is
  normalised before the approval dialog can shift both the bytes
  `_unstick.sh` matches and the `.tool_input.command` the guards parse.
  → **2b and 2d get a careful read on .223.**
- The `bypassPermissions` entry lands on `--dangerously-skip-permissions`
  / `skipDangerousModePermissionPrompt`, which **every nexus spawn**
  depends on (2e).
- The Linux-sandbox entry matters because this nexus runs inside
  `agent-sandbox`.

What the 2026-08-07 round actually established on these: the permission
dialog survives a command padded with a literal TAB, U+00A0 and U+200B —
it gains an advisory `Contains Unicode whitespace` line and every literal
`_unstick.sh` greps still renders (skeptic ARM D, 5 assertions); the
PreToolUse guards still bind on the running binary (`bash-footgun-guard.sh`
fired live); there is no `.claude/agents` directory and no
`bypassPermissions` key in any nexus settings file; no `.claude/workflows`
directory; and no `sandbox`/`deny*` key in any of the four effective
settings files. Re-establish, do not inherit — these are configuration
facts, not invariants.

Run the PreToolUse gate scenario (Step 3) rather than reasoning about 2d,
and label the surfaces honestly per the rule immediately below.

## ⚠ HOW AGENTS BREAK THIS — read before you touch anything

**This process is well designed and keeps getting broken in execution, not in
design.** Every failure below was observed on 2026-09-03, in ONE bump
(2.1.246 -> 2.1.259), by an orchestrator that had read the rest of this guide.
The operator had to hand-navigate the routine to completion. That is the defect
this section exists to prevent, and it is a DISCIPLINE defect: nothing in Steps
0–6 is wrong.

### DONE is not "the pin is written"

**DONE is: every agent window is RUNNING the new binary.** A process keeps the
binary it started with, so a pin and an install change only what starts NEXT.

    claude --version                 # the INSTALL — necessary, not sufficient
    tmux capture-pane -p -t <w> | grep -oE 'v2\.1\.[0-9]+' | tail -1   # per window

If the orchestrator banner still shows the old version, **the bump is not
finished**, no matter what `decisions.tsv` says. On 2026-09-03 the pin and
binary read 2.1.259 for 25 minutes while every one of six windows still ran
2.1.246, and the routine was reported as complete. It was not.

### The four operations, and which are actually required

**Two flags decompose it, and what each does AROUND the verb matters as much
as inside it** (<your-org>/nexus-code#1425, #1438). `safe --no-restart` pins,
installs and verifies, then stops: the deployment gate is SKIPPED (its arms
guard restarts, and none will run) and a `restart-hold` with
`until_version=<candidate>` is written so the watcher's every-tick reconcile
does not re-fire the orchestrator hand-off you just declined. `safe
--no-orchestrator-restart` additionally restarts the watcher, keeps the gate,
and stops BEFORE the session-pin pre-flight (a pin-less nexus is a reason to
decline, not an aborted restart); it writes the same hold. Both are released
with `unhold`. Measured before #1438: the gate deferred both flags like the
bare verb, the reconcile re-fired within one tick, and the pin-less case
recorded an ABORTED restart at rc 21 — none of it tested.

`safe` welds four things together. They are not equally necessary, and knowing
which is which is what stops you from taking risk for nothing:

| operation | needed for the bump? | why |
|---|---|---|
| write the local pin | **yes** | decides what installs |
| install the binary | **yes** | decides what new spawns exec |
| **restart the watcher** | **NO** | it is `bash main.sh`; it EXECs `node_modules/.bin/claude` fresh at every spawn, so a running watcher serves the new binary with no restart. Restarting it is the *risky* operation (decapitation, duplicate groups — `#503`) and it buys nothing. |
| restart the orchestrator | **yes** | it IS a running `claude` process (Step 5b) |

**This matters more than it looks.** The entire deployment gate — since
2026-09-12 the two PR arms, restart-path PRs and PR-under-active-review; before
that also board-quiet and the live-window count — exists to answer
*"is now a safe moment to restart?"* If the only required restart is the
orchestrator's, and an orchestrator restart preserves context, then those arms
are gating an operation that largely should not happen. On 2026-09-03 four arms
deferred all day to protect a watcher restart that was never needed.

### Divergence 1 — skipping Step 5b "to be safe"

**Do not.** Step 5b is not optional and it is not risky: the orchestrator
resumes from its pinned transcript, so a mid-turn kill re-runs the interrupted
turn and loses nothing. Skipping it leaves the workspace version-split AND —
measured — hides the next failure, because the thing that would have exposed it
is the restart itself.

### Divergence 2 — killing the watchdog

**The watchdog must stay online until the board is healthy, not until the kill
fires.** It is the only thing watching the transition. On 2026-09-03 an
orchestrator tidying dead windows ran
`tmux kill-window -t cc-restart-watchdog` on an ARMED watchdog and destroyed the
mechanism that was about to restart it. The tell: `detached-restart.log` reaches

    restart: idle-wait cap (900s) reached ... arming the restart watchdog

and the NEXT line — `watchdog armed — killing orchestrator` — never appears.
Compare a healthy run (2026-08-26) where the two lines are 61 s apart.

**Never kill a window named `cc-restart-watchdog`.** If it looks dead, read its
pane before touching it: a spawn REFUSAL and a dead agent look identical from
the window list.

### Divergence 3 — hand-invoking `restart-orchestrator` blind

It is normally re-exec'd by `cmd_safe` with its arguments pre-derived, so its
required flags are not obvious. **Both are mandatory** and it exits immediately
without them:

    setsid nohup bash monitor/cc-auto-update-apply.sh restart-orchestrator \
        --candidate <version> --sid <orchestrator-session-id> &

Read the signature before invoking, not after three failed tries.

### Divergence 4 — narrowing deployment-gate arms one at a time

When a TIMING arm defers, the temptation is to treat it as a bug and narrow it.
On 2026-09-03 four arms deferred in sequence and were attacked one by one, for
hours. **Three were genuine defects and are filed (`#1320`, `#1414`, `#1408`);
the fourth was correct.** The lesson is not "three of four were bugs" — it is
that the SEQUENCE should have been recognised after the second:

> **Separate COMPATIBILITY from DEPLOYMENT TIMING.** Compatibility (the
> realmodel gate, changelog disposition, surface classes) must block, always,
> with no override — it caught the `2.1.248` trust-dialog regression and
> correctly held the pin for five releases. Timing arms ask *"is now
> convenient?"*, and on an actively-worked nexus the answer is permanently no.
> **A timing arm that can never clear is a compatibility verdict nobody asked
> for.**

If two timing arms defer in a row, stop narrowing and take the sanctioned manual
path — the `GATE_DEFER_STREAK_ALERT` warning in `cc-auto-update-apply.sh`
(`:1771` at `a3177ef6`; grep the string, the line moves) names three: close
the stale windows, exempt them via `CC_AUTO_GATE_WINDOW_EXEMPT`
(`:252`, default `services`), or apply manually. **Record every arm that
was deferring and why each was set aside** — a manual bump is precisely the kind
that becomes unreconstructable.

Note the recursion, because it is the clearest sign the mismatch is structural
rather than a bug: **the PR opened to FIX the gate tripped the gate's own
`pr-under-active-review` arm.**

**UPDATED BY `<your-org>/nexus-code#1492`, and the update narrows what this
warning is about.** Three of the arms being attacked in that 2026-09-03
sequence were not timing arms at all — they fired on a QUERY FAILURE, and two
of those now degrade to UNMEASURED and let the gate continue rather than
returning early. So the advice above applies to arms that name a HAZARD
(a live restart-path PR, a PR under active review; until 2026-09-12 also
`board-not-quiet` and `live-windows>max`, removed by operator decision — D13):
those defer for a reason, and narrowing them one at a time is
the trap this section describes. **An arm that defers because its own
instrument broke is a different animal — that is a defect to file, and the
gate now files it.** If you find yourself narrowing an arm, first check which
kind you are holding: see "What is REVERSIBLE and what is NOT" above.

### Divergence 5 — the recovery path needs the thing that is broken

**The restart watchdog is itself a SPAWN.** So anything that wedges spawning
also wedges the restart, and the failure presents one step short of the kill.

On 2026-09-03 a shell snapshot written with **zero** shim references became the
newest on the host, and `assert-shims-wrapped` — whose frozen-snapshot leg
selected newest-by-mtime, a proxy not linked to the spawning process (`#670`
finding 1) — refused **every** spawn board-wide. On 2026-09-06 the same
condition recurred and, this time, took the orchestrator down with it:
**1,104 failed respawns over 18 h, 75 emits archived undelivered, the 04:05
cc-update fire never ran**, and nothing could clear it, because the only thing
that writes a nexus-provenance snapshot is a nexus-launched agent — which the
guard was refusing to launch (`<your-org>/nexus-code#1477`).

**An earlier version of this section said that refusal was CORRECT and must
never be weakened. That was wrong in a specific way, and the guard has changed
(#1477):** a snapshot with **no shim dir anywhere in its PATH** was written by a
`claude` launched **outside** the nexus launcher — no `ZDOTDIR`, so no
front-path — and says nothing about the child, which writes its own snapshot
from the env the guard just verified live. That is a **FOREIGN** artifact and
the guard now **warns** on it (loudly, with provenance) instead of refusing.
What still refuses a **worker** spawn is **BURIAL**: shim dirs present in the
recorded PATH with a guarded name resolving ahead of them — the real
`#652`/`#654` race. And on the **orchestrator** path (`NEXUS_IS_ORCHESTRATOR=1`)
the snapshot leg never refuses at all: a burial there is a WARNING plus a row in
`monitor/.state/guard-unverified.log`, because the board being able to come
back outranks a possibly-buried orchestrator, which can repair the shell-init
itself and whose fresh snapshot un-latches every worker spawn after it. The
live probe legs and the nproc leg can still refuse an orchestrator; those
adjudicate the spawn's own env and clear on repair rather than latching.

**Anti-recurrence — this is the rule for YOU, the agent running a manual step:**
**never launch `claude` by hand from a plain shell inside this nexus.** A
hand-launched `claude` (a manual verification run during a bump, a forensic
session, a quick `claude --version` that opens a session) writes a snapshot
with no nexus env, and until `#1477` that alone armed the trap; it is still the
thing that makes every `selected via: newest … (mtime PROXY)` line describe a
shell that is not yours. Launch through the nexus env:

```bash
# a worker — the sanctioned form; the guard reads the spawner's own snapshot
monitor/spawn-worker.sh …
# a bare interactive check that MUST be by hand: give it the nexus shell env
ZDOTDIR="$NEXUS_ROOT/monitor/shellenv" bash -c '. "$NEXUS_ROOT/monitor/locals-env.sh"; exec claude …'
```

`apply.log`'s own manual-path block (*"WHAT THIS MANUAL PATH DID NOT RECORD THAT
apply.sh WOULD HAVE"*) lists what a manual bump trades away; **a foreign
snapshot in the CC home is on that list** — record it when you take the manual
path.

**Detect** — the guard now prints this on every spawn, pass or not:

```
assert-shims-wrapped: NOTE: snapshot leg examined <path> — selected via: <route>; provenance: nexus-fronted|FOREIGN
```

and by hand, a `0` means the newest snapshot fronts none of the shims:

```bash
SD=~/.claude/sandbox-config/shell-snapshots
S=$(ls -t "$SD" | head -1)
grep -c 'ghwrap\|tmuxwrap\|pipwrap' "$SD/$S"      # 0 => FOREIGN newest (warn-only since #1477)
```

**Repair a BURIAL** (the case that still refuses workers): fix the shell-init
race at source (`monitor/shellenv/*` re-fronting after the operator's rc), then
let the orchestrator's next spawn write a fresh snapshot. The older stopgap —
verify a known-good snapshot's content FIRST, then `touch` it newest — is
exactly reversible and still available for a wedged board:

```bash
SD=~/.claude/sandbox-config/shell-snapshots
for f in $(ls -t "$SD"); do
  if [ "$(grep -c 'ghwrap\|tmuxwrap\|pipwrap' "$SD/$f")" -gt 0 ]; then
    touch "$SD/$f"; echo "restored via $f"; break
  fi
done
monitor/assert-shims-wrapped.sh >/dev/null 2>&1; echo "rc=$?"   # expect 0
```

**Never touch a snapshot you have not read** — that converts a fail-closed guard
into a rubber stamp, which is far worse than the wedge. Never delete one. Never
edit `monitor/shellenv/*` to get past it.

**A wedged spawn presents as `pane-absent`**, which reads as *an agent died*
rather than *a precondition refused* — it was misdiagnosed as a death first,
both times. Read the dead pane's last lines before treating it as a crash.

### Divergence 6 — a BLOCK that never becomes a fix

`2.1.248` regressed the trust dialog. The gate caught it and BLOCKED — correctly
— on `.248`, `.250`, `.251` and `.252`. **Four consecutive correct diagnoses and
not one fixing PR was ever opened.** The same regression was rediagnosed four
times and nothing shipped, and the pin sat 8 releases and 13 days stale.

**Standing operator rule:** a BLOCK must produce **an issue AND a fixing PR**,
immediately, not a log line and a retry tomorrow. Falling behind on the cc
version is not the safe default — it is a cost with its own failure mode, and it
excludes the nexus from features that raise productivity.

### Divergence 7 — silence read as success

A `safe-refused` outcome **notifies nobody** (`#1400`). Two consecutive days of
false BLOCKs surfaced only because the operator asked directly. **A false BLOCK
looks exactly like the gate working.** Whenever you see a deferral streak, treat
it as an incident, not as the routine idling: `GATE_DEFER_STREAK_ALERT` exists,
is set to 3, and did not reach a human.

### The completion checklist — run it, do not assume it

    1. claude --version                        -> candidate
    2. cat monitor/.state/cc-version-local     -> candidate
    3. orchestrator pane banner                -> candidate   (Step 5b done)
    4. every worker pane banner                -> candidate, or a recorded plan to cycle it
    5. newest shell snapshot has shim refs > 0  (a fresh good one should now exist;
       a 0 means YOUR manual step launched claude by hand — Divergence 5)
    6. exactly ONE orchestrator window; watcher alive; heartbeat fresh
    7. a spawn actually succeeds                (the only real proof of 5)
    8. decisions.tsv + apply.log carry the attestations, including any manual step

**Steps 3, 4 and 7 are the ones that get skipped**, and they are the ones that
distinguish "the routine ran" from "the workspace is on the new version".

## The evidence-class rule — read this BEFORE you label anything

**The recurring defect this routine has, stated plainly.** In five of six
rounds the evaluation reached a *defensible conclusion* through an
*unsubstantiated mechanism*: a probe that was **reachability-only** got
labelled **empirical**, and `--surfaces-clear` laundered that into "I
tested it". The conclusions happened to be right; the evidence did not
support them. That is not a near-miss — it is a process that cannot
detect the round where the conclusion is wrong.

**The rule.** In your report table and in `apply.sh`, every surface
carries exactly one evidence class:

| Class | Means | Payable when |
|---|---|---|
| `gate` | a cc-harness scenario covered it | 2a, 2b, **2c-vi** and 2d — exactly the keys `_surface_gate_scenarios` maps (`monitor/cc-auto-update-apply.sh:670-678`); `2c-vi` since `<your-org>/nexus-code#867`, via `test-realmodel-vimode`. Nothing in the harness covers `2c-paste` or 2e. `apply.sh` cross-checks the scenario name against your gate log. |
| `empirical` | you drove a probe against the candidate **and showed the probe can go RED** | only with a stated **differential / negative control** |
| `reachability` | the hazardous input path cannot be reached in this nexus, so the entry is inert here | when you established the path is unreachable — and you say so |
| `source-inspection` | you read the code and reasoned about it | always honest; never dressed up as `empirical` |

**A surface with two mechanisms carries two labels.** Surface 2c is one
GUIDE row but *two* things: the **paste-buffer delivery** path and the
**VI-insert guard**. Six of seven rounds drove the first, could not reach
the second, and labelled the pair `empirical` — the driven half paying
for the inert one. The keys are therefore **split**: label `2c-paste` and
`2c-vi` separately, each with its own class and, for `empirical`, its own
negative control. `apply.sh` **refuses the aggregate key `2c`** and names
the two halves. The audit row still records a derived `2c`, computed as
the **weakest of its sub-claims** — so a composite can never read as
driven when half of it was argued. `2c-paste` is `empirical` (with the
control). **`2c-vi` has no fixed answer — it is a per-host measurement,
and this file is shared across operators.** Both of these were measured
on 2026-08-07:

| Host | `editorMode` in the operator's config | Live agent panes rendering `-- INSERT --` | Honest label |
|---|---|---|---|
| A | `"vim"` in **both** `~/.claude.json` and `~/.claude/settings.json` | 9 of 10 windows (the non-match is `services`, not an agent pane) | VI is REACHED. `#724`'s probe exists (`test-realmodel-vimode.sh`), the harness seeds `"vim"` so the mode the gate boots is the one production runs, and since `#867` `apply.sh` maps `2c-vi → test-realmodel-vimode` — so the honest label is **`gate`**, provided that scenario name appears in the gate log you supply |
| B | absent from all 5 present settings files | 0 of 4 | `reachability` — both re-checks return zero |

So: **run the two re-check commands in §2c and label from what they
return.** `reachability` is payable only where both come back zero;
where they do not, VI mode is reached and the honest label is **`gate`**,
paid for by `test-realmodel-vimode` appearing in your gate log — see the
note on `2c-vi` and `gate` payability in §2c. Do not inherit either row,
and do not fall back to `source-inspection`: it does not CLEAR 2c (see
"Silence is not clearance" below), so it converts a bumpable candidate
into a needless `needs-review`.

**`empirical` requires a control, no exceptions.** Break the assertion,
or strip the behaviour under test, and observe a red. If you cannot
produce that, the honest label is `reachability` or `source-inspection`
— and those are *perfectly good answers*. A clean `reachability` call is
a better result than a fake `empirical` one.

**The two known ways a probe silently stops testing anything.** Both have
happened here; name-check your probe against both:

1. **No-op input prefix.** The 2.1.216 and 2.1.222 VI-mode probes
   prefixed their paste with `send-keys i BSpace` to force VI insert
   mode. The harness booted panes in **default (emacs)** mode *at the
   time* (it seeds `vim` since `#724`), so the prefix typed `i` and
   deleted it — a net no-op. Proven by differential
   control: removing the line left the probe passing *identically*. The
   probe could not distinguish VI-insert hardening working from absent.
2. **Dead instrumentation.** The 2.1.218 probe's turn-counter regex never
   matched anything, yet every assertion built on it reported PASS.

### Silence is not clearance — 2b, 2c and 2d are never self-verified

Two distinct things can make you write "2d is clear": you **drove** it,
or the changelog **did not mention it**. Only the first is evidence. The
second is the routine's oldest failure mode, and it is the reason this
rule is stated separately from the class table above. Until
`<your-org>/nexus-code#1004` it existed in no repo file — it was quoted to
skeptics in orchestrator spawn prompts only, so it bound the REVIEW and
not the ROUTINE, and lapsed on every fire that was not skeptic-reviewed.

**The rule: surfaces 2b, 2c and 2d may never be cleared on your own
say-so.** For these three, "the changelog flagged nothing that touches
this surface" is **not a disposition** — it is the *absence* of one.
Each must carry a class that something other than your reasoning
produced:

- `gate` — a named cc-harness scenario covered it and appears in your
  gate log (payable for 2b, `2c-vi` and 2d; `2c-paste` has no scenario);
- `empirical` — you drove a probe against the candidate **and** showed it
  can go RED, with the negative control written down;
- `reachability` — you ran the re-check commands and they came back zero,
  and you say which commands and what they returned.

`source-inspection` is an honest label and a perfectly good answer, but
for 2b/2c/2d it is **not a clearing one** — it records that you read the
code, not that the surface is safe. A `safe` verdict that rests on
`source-inspection` for any of 2b/2c-paste/2c-vi/2d is a verdict resting
on nobody having checked. Where it really is the best available, the
verdict is **needs-review**, not **safe** — escalate rather than absorb.

**But check that it really is the best available before you escalate.**
`2c-vi` on a host where VI mode is reached is **not** such a case: the
scenario exists (`#724`) and `apply.sh` maps it (`#867`), so the label
there is `gate`. This rule is meant to escalate the cases nobody can
drive, not to manufacture permanent manual review out of cases someone
already built a probe for. `2c-paste` is the one half with no scenario:
drive it and label `empirical` with its control, or escalate.

**Why these three specifically.** They are the surfaces where the failure
is *silent in production*: a changed dialog signature (2b) makes
`_unstick.sh` stop unsticking, a changed insert-mode handling (2c) makes
pastes land mangled, a changed settings schema (2d) makes hooks quietly
stop firing. None of them throws. Nothing in the nexus goes red — the
capability just leaves, and the next person to notice is whoever needed
it. 2a announces itself (panes misclassify loudly) and 2e fails closed (a
removed flag errors on the command line); 2b/2c/2d do not.

**What enforces this — and what does not.** `apply.sh` does **not** check
this rule: `_check_surface_evidence` accepts `2b`/`2c-paste`/`2c-vi`/`2d`
`= source-inspection` at exit 0 (the class set is uniform across surface
keys), and it cannot see a changelog section that was never published
(see "An OPAQUE changelog" under Step 1). Do not read the *"This is
enforced, not advisory"* paragraph below as covering it — that paragraph
is about the per-surface *labels* and the changelog *counts*. This rule
binds **you**, the evaluator, and on an autonomous fire nothing else will.

**And note what "self" means here.** This is not only about a *skeptic*.
The rule binds the evaluator whether or not anyone reviews the fire — the
great majority of fires are autonomous and unreviewed, which is precisely
when an unearned clearance survives to production. If a skeptic *does*
run, they are a second check on top of this rule, never a substitute for
it, and never the thing that makes it apply.

**This is enforced, not advisory.** `monitor/cc-auto-update-apply.sh safe`
refuses (exit 3) unless every surface key (`2a 2b 2c-paste 2c-vi 2d 2e`)
carries a class, an `empirical` class carries `--negative-control
<surface>=<what you broke and what went red>`, a `gate` class names a
scenario that actually appears in the gate log you supplied, and the
changelog accounting is complete (Step 1). See Step 5.

## The routing invariant: surface to `nexus-code`, never the asset repo

cc-update work is **implementation-repo** business. The operator's asset
repo (`github.repo` — `<your-org>/<operator>-nexus`) is where scientific
work lives; it must **NEVER** receive a cc-update notice, tracking issue,
or eval comment — that is pure churn bothering the operator mid-science.
The evaluation resolves to exactly two outcomes:

1. **SAFE → apply silently.** No issue, no comment, anywhere. A clean
   gated bump bothers no one.
2. **review / compat / block warranted → surface on the IMPLEMENTATION
   repo `<your-org>/nexus-code` ONLY** — an issue or a `cc-compat` PR
   there, never in the asset repo.

Concretely: every `ng issue create` / `ng issue comment` / `ng wrap-up`
in this flow MUST carry an explicit `--repo`. A bare `ng` write defaults
to `github.repo` (the asset repo) — that default is the exact footgun
this routing rule exists to prevent. Do **not** OPEN a tracking issue in
the asset repo, even though standard nexus practice ("every actionable
thread gets its own issue") would otherwise point you there.

### The one exception, and which document governs (<your-org>/nexus-code#866)

The invariant above governs everything the evaluator **opens on its own
initiative** — a fresh issue, a `cc-compat` PR. Those are UNSOLICITED, and
unsolicited churn in the asset repo is what the rule exists to stop. They go
to `{{SURFACE_REPO}}` (the implementation repo), never the asset repo.

A **configured `monitor.cc_auto_update.tracking_issue` is different in kind.**
It is a qualified `owner/repo#N` reference that the operator wrote deliberately,
naming the thread they want to be told on. Writing there is SOLICITED — it is
the operator's explicit choice of venue, not churn — so it may legitimately
name the asset repo, and the evaluator writes to **the repo that reference
names**, which is rendered into the prompt as `{{TRACKING_REPO}}`.

**Precedence, stated so no agent has to adjudicate it:**

| for… | use | governed by |
|---|---|---|
| the configured tracking issue | `{{TRACKING_REPO}}` | **the rendered prompt** |
| anything you open fresh | `{{SURFACE_REPO}}` | **this guide** |

`{{TRACKING_REPO}}` is **not** guaranteed equal to `{{SURFACE_REPO}}`; never
substitute one for the other. The reference reaches the prompt only after
`monitor/issue-ref.sh` has resolved it, so if a value was unqualified the
evaluator never fired and you are not reading this in that run at all.

Earlier revisions of this guide said the tracking issue must be on
`<your-org>/nexus-code` and that every write must carry
`--repo <your-org>/nexus-code` literally. That predates qualified references and
**contradicted the prompt**, which is worse than an ambiguity: two documents an
agent is told to obey, disagreeing, with the stale one marked authoritative.
The rule above replaces it.

### Evaluator comments — verdict first, evidence collapsed, no re-post (<your-org>/nexus-code#1529)

The operator called the evaluator's comments *"incomprehensible blocks"*: on
`#1475` one evaluator posted 24 of them, the last ~100 lines of arm tables to
say "your clone is behind; pull it". Three rules, enforced by the prompt
(`monitor/cc-auto-update-prompt.md`, "Surfacing", which carries the worked
example — keep the two consistent):

1. **The verdict opens the comment, in 2–4 plain lines**: what happened,
   whether anything was applied, and the exact operator action if there is
   one. For a block on a possibly-stale classifier that is ONE sentence plus
   ONE command, and the command names the SAME ref the margin was measured
   against — the operator's `monitor.integration_branch`, printed by
   `apply.sh block` — never a literal the evaluator picks, and never a
   checkout on the clone:
   `git -C <nexus-root> pull --ff-only origin <integration-branch>`. (A first cut of this rule hard-coded `main`; on a
   `dev`-tracking primary that is a no-op pull plus a prescribed checkout
   that regresses the running watcher — w241sk F3. The dev-vs-main default
   is the operator's decision, open on `#1529`.)
2. **Every evidence table lives inside one collapsed `<details>` block**
   after the verdict: gate scenarios, ledger counts, the deployment-gate row,
   the apply exit code.
3. **Unchanged verdict, candidate and inputs ⇒ no new comment.** The
   evaluator asks `monitor/cc-surface-dedup.sh check` before posting; it
   fingerprints verdict + candidate + the live clone's HEAD + the RENDERED
   comment body against the last recorded post, so "unchanged" means the
   reader would see nothing new (a changed reason or ledger is a new
   comment by construction; timestamps stay out of the body). rc 12 means
   "unchanged since <date>": nothing is posted, nothing is edited, the
   report says so. rc 0 means post, then `record`. A dedup that cannot
   fingerprint (rc 3) never silences a finding — post and say so.

## Step 0 — orient

```bash
cat monitor/.state/cc-update-available     # candidate, installed, detected
```

Fields: `candidate=` (npm latest), `installed=` (the EFFECTIVE version
the gate compared against — the operator-local pin
`monitor/.state/cc-version-local` if present, else the shared
`package.json` floor; see `monitor/_cc-version.sh`), `detected=`,
`skill=` (this file). Confirm the candidate is real and note the delta
(a patch bump is lower-risk than a minor/major).

This work touches `monitor/watcher/*`, so any code AUTHORING (a compat
fix) is done by a **separate worker in its own worktree**, never on the
live main clone (a checkout on the running watcher's clone silently
breaks `snapshot_github` — see the workspace CLAUDE.md "Watcher-touching
work needs a separate clone") and never by the autonomous evaluator at
all: its window is refused every non-read-only `git` verb by the
PreToolUse hook (`<your-org>/nexus-code#1529`, below), so it files the
compat issue and blocks, and the orchestrator dispatches the author.

## Step 1 — read the release notes / changelog

Find what actually changed between `installed` and `candidate`:

```bash
# the published changelog (the package ships one). SAVE it — this file is
# what you pass as --changelog-evidence in Step 5; do not read it and
# discard it. The `tr -d '\n'` is portability insurance, not a fix for a
# measured failure: the API returns WRAPPED base64, and GNU coreutils
# 8.28 (this host, measured) decodes that fine at rc 0. Whether any
# `base64` you might meet rejects it is UNVERIFIED here — so keep the
# `tr` (it costs nothing) and do not "fix" a working pipeline elsewhere
# on the strength of this note. The same form is in
# `monitor/cc-auto-update-prompt.md`; keep the two identical.
mkdir -p monitor/.state/cc-auto-update
GH_TOKEN=$(./monitor/mint-token.sh) gh api \
  repos/anthropics/claude-code/contents/CHANGELOG.md \
  --jq '.content' | tr -d '\n' | base64 -d \
  > monitor/.state/cc-auto-update/changelog-<candidate>.md
sed -n '1,120p' monitor/.state/cc-auto-update/changelog-<candidate>.md
# or the npm tarball's CHANGELOG / the GitHub releases page.
```

Read every entry between the two versions, not just the top one (cc
publishes ~daily; you may be several releases behind). Flag anything
that mentions: the TUI / input box / status line / spinner,
autosuggest, permission prompts, AskUserQuestion / dialogs, VI / vi
mode / keybindings, hooks, settings schema, `--continue` / `--resume`
/ `--session-id` / `--settings` / `-p` / `--dangerously-skip-...`. Each
flagged item maps to a collision surface below.

### Changelog-reading discipline (two rounds were lost to this)

- **Re-fetch from source. Never summarise from memory** — not from a
  prior report, not from a prior session's notes, not from the emit.
  Run the `gh api` command above in THIS session and read its output.
- **Quote every flagged entry VERBATIM in the collision table**,
  including parentheticals. Paraphrase is where the information goes.
  The 2.1.222 round paraphrased *"…in background agent tasks
  **(summaries, compaction, renames)**"* down to "in background agent
  tasks" — dropping the clause that made the entry **more** reachable
  here, since summaries, compaction and window renames all occur
  routinely in long-running nexus sessions. A paraphrase that trims the
  detail arguing *against* your own conclusion is the failure mode;
  quoting verbatim removes the opportunity.
- **Account for EVERY entry**, not just the ones that map to a surface.
  The 2.1.217 defect was a simply-unread entry. Entries that map to no
  surface still get listed with a one-line "no nexus surface" disposition
  — an entry you never wrote down is an entry you never considered.

  **This is now enforced, and it needs a LEDGER FILE.** The 2.1.224 round
  wrote *"Both releases read in full"* and then tabulated **41 of 50**
  entries. The nine it dropped included the `bypassPermissions`
  vs org-disable-policy fix (the flag **every** nexus spawn rides), the
  workflow-sandbox dynamic-`import()` escape, and
  `sandbox.filesystem.denyWrite` covering the working directory (this
  nexus runs inside `agent-sandbox`) — three of them pre-flagged **by
  name** in that round's own brief. The skeptic then verified each is
  inert, which is exactly the problem: *"no impact" was the default, not
  a claim anyone made.* Same defect as 2.1.217's unread footer entry,
  five releases later.

  So, mechanically:

  1. Save the changelog you fetched — that file is
     `--changelog-evidence`. It is freshness-checked (a prior round's
     copy is refused), it must contain the candidate's own section, and
     **it is compared section-by-section against a copy `apply.sh`
     fetches from upstream itself.** Read the real thing: a doctored or
     truncated file is named as such.
  2. Write a **ledger**: **one line per entry**, the entry quoted
     **verbatim** plus its disposition (a surface, or an explicit "no
     nexus surface"). No wrapping, no paraphrase. That file is
     `--changelog-ledger`, and it is what your report table is built
     from.

     Markdown quoting is safe: whitespace is collapsed and **backslash
     escapes are normalised on both sides**, so a backtick span with
     escaped inner backticks (`` \` ``) compares equal to the raw entry
     (`<your-org>/nexus-code#867`). Before that, an upstream entry naming a
     flag or settings key in a code span — which they routinely do —
     failed the probe on the escape alone, and the refusal came out as a
     *completeness* failure ("N of M entries do not appear verbatim"),
     i.e. "you did not disposition these", for a ledger where every entry
     had been. If a probe fails now it says which of the two it is:
     **ABSENT** (the entry went unconsidered — the thing this check is
     for) or **DIVERGES after ~25c** (it was dispositioned and then
     re-worded; copy the line unaltered).

     The cheapest way to be verbatim by construction is not to hand-quote
     at all: emit the entries mechanically from the fetched changelog and
     attach dispositions, then verify with a corrupted-copy control that
     the check still fires.
  3. Pass `--changelog-dispositioned <release>=<N>` **for every release
     in the delta** — a two-release jump means both changelogs, not just
     the candidate's. `apply.sh` derives the release set from **the npm
     registry** — every version it publishes in `(installed, candidate]`
     (upstream skips patch numbers routinely, so an arithmetic range would
     be wrong, and the changelog's own `## <ver>` headers are not the set
     either, see below) — **counts M from the changelog copy it fetches
     itself**, and refuses when `N != M` or when any entry is missing from
     the ledger.

  You get `dispositioned N of M entries across K release(s)` in
  `decisions.tsv` out of it, with `K` the registry-derived count.

  **An OPAQUE release refuses, with its own exit code (8)**
  (`<your-org>/nexus-code#1007`). Until that fix the release set was the
  changelog's own `## <ver>` headers, so a release that PUBLISHES NO
  SECTION was never *in* the set: not counted toward M, never owed a
  disposition, and `dispositioned N of M` read GREEN over it. It fired on
  2026-08-25 — `2.1.242` is published and has no `## 2.1.242` section, and
  two independent fires read "406 of 406" across it. Now a version the
  registry publishes inside the delta with no section in the fetched
  changelog is REFUSED and NAMED (`exit 8`, outcome
  `safe-refused changelog-completeness:opaque-release=<ver>`). Nothing
  you pass can clear it — the evidence does not exist upstream — so do
  not route around it; the daily fire retries on its own, clearing the
  day the section appears. **The refusal is BOUNDED** (operator
  directive, 2026-09-10: a busy board may DELAY an update, not PREVENT
  it — the principle behind `defer_streak_cap`): after that many
  CONSECUTIVE refusals on the same opaque set (default 3, floor 2, the
  same knob and clamp as the deployment gate's bound; `0` escalates at
  the floor because the surfacing cannot be switched off) `apply.sh`
  escalates the operator itself — `sandbox-notify` plus a comment on the
  tracking issue (or a filed issue on the gate repo when none is
  configured) naming the candidate, the release(s), and the sentence
  *"upstream shipped no parseable sections; this needs a human
  disposition."* — and KEEPS refusing. Delay-then-surface, never
  delay-then-forget, never auto-proceed; the exit code and outcome token
  do not change. The streak is read from `decisions.tsv` as consecutive
  `safe-refused` rows with the same detail, so a fire that clears the
  condition resets it; the comment is posted once per opaque set per
  week, the notify on every fire past the bound. The `#1400` repeat-nag
  still fires on the second identical refusal. The registry fetch gets
  the changelog fetch's treatment —
  network failure, a non-JSON body, an empty version set, or a copy that
  does not list the candidate all REFUSE (`exit 3`), never fall back to
  the headers, because the fallback is the blind spot itself. The
  converse case is a CHOICE: a `## <ver>` header whose version the
  registry does NOT publish is dropped from the set with a `WARN` naming
  it (nothing installable carries those entries; `2.1.244` in the same
  delta was unpublished *and* sectionless, correctly nothing). The
  registry read is a direct `curl` against `registry.npmjs.org` — never
  `npm view`, which is cache-servable and served a stale `latest` to two
  independent evaluators the same day.

  **What M rests on, precisely — and what it does not.** `apply.sh`
  fetches `CHANGELOG.md` on every `safe` run and counts from that; a
  failed fetch REFUSES rather than falling back to your file. That is
  what stops the *file* from deciding M: the first cut of this check
  trusted `--changelog-evidence` (mtime + a grep for the candidate
  heading), and a skeptic truncated 2.1.223 from 19 bullets to five,
  declared `2.1.223=5`, and was accepted at rc 0 with "dispositioned 36
  of 36". Freshness was no obstacle — a hand-edited copy has a fresh
  mtime by construction.

  **It does not make the counts provenance-authoritative, and the script
  no longer pretends otherwise.** The fetch is a subprocess, and three
  successive attempts to pin its source were each defeated by a route
  the previous fix had not enumerated — a hand-edited file, then
  `CC_AUTO_CHANGELOG_FETCH_CMD`, then a `gh` earlier in `PATH`, every one
  of them accepted at rc 0. You cannot enumerate the ways a caller
  reaches a subprocess, so the acceptance line now reads `provenance NOT
  established` and asserts nothing about origin. This is deliberate: a
  claim that names a source nobody verified is worse than no claim,
  because it is what the next round quotes as evidence.

  **So the provenance is YOURS to establish**, by fetching the changelog
  in this session (Step 1) and reading what you fetched. The mechanism
  catches the failure that actually recurs — believing you read
  everything while nine entries went undispositioned — not a caller
  setting out to fool it. Such a caller already owns the bump path
  outright (`CC_AUTO_INSTALL_CMD` alone decides what gets installed), so
  hardening the changelog source further would be theatre. If it ever
  must be earned, the way is to verify the BYTES against a digest or
  signature published independently of the fetch path — upstream ships
  none for `CHANGELOG.md` today.

  What the check still cannot judge is whether a disposition is
  *correct* — only that every entry was looked at and written down.
- **An OPAQUE changelog is an ABSENCE of evidence, not a clean review.**
  This is the rule the routine most often inverts, and it inverts it
  silently. When the changelog for a release in the delta is missing,
  empty, truncated, unreachable, or written so vaguely that you cannot
  map an entry to a surface ("various fixes and improvements", "internal
  changes", a release with no section at all), the correct reading is
  **"I do not know what changed"** — never **"nothing relevant changed"**.
  The two are opposite states of knowledge, and only one of them is
  compatible with a `safe` verdict.

  So an opaque entry, or an opaque release, **escalates to probing** —
  drive the surfaces it could plausibly touch and label them `empirical`
  with a control — or, failing that, it escalates to **needs-review /
  block**. It NEVER escalates to assuming. Write the opacity down in the
  ledger as its own disposition (`opaque — probed 2a/2b`, or `opaque —
  could not probe, escalated`), because an unexplained "no nexus surface"
  on a vague entry is indistinguishable from a real clearance six weeks
  later when someone reads your table.

  Note the asymmetry that makes this dangerous: a **missing** section
  costs you nothing at the accounting gate. `_check_changelog_completeness`
  derives the release set with `awk '/^## /{print $2}'` over the changelog
  it fetched (`monitor/cc-auto-update-apply.sh`, the `releases=()` block)
  — so a release that publishes **no section is never in the set**,
  contributes zero entries, leaves the ledger complete, and lets
  `dispositioned N of M` read GREEN while that release went entirely
  unexamined. **The completeness check cannot see an absence.** You have
  to — so enumerate the delta from the **registry**, which is authoritative
  for what shipped, and diff it against the changelog's `## ` headers:

  ```bash
  curl -sSL -H 'Accept: application/vnd.npm.install-v1+json' \
    https://registry.npmjs.org/@anthropic-ai/claude-code \
    | python3 -c 'import json,sys; print(*json.load(sys.stdin)["versions"])'
  # every version in (installed, candidate] with no `## <ver>` section in
  # the changelog is an OPAQUE RELEASE — disposition it explicitly.
  ```

  **This is not hypothetical — it fired on the 2026-08-25 fire.**
  `2.1.242` is a published release inside that delta (`2.1.231` →
  `2.1.245`) and has **no `## 2.1.242` section** (found by the
  `<your-org>/nexus-code#1004` author; re-verified against the registry and
  the fetched changelog on 2026-09-12: the registry lists `2.1.242`, the
  changelog's headers run `## 2.1.243` → `## 2.1.241`). It was therefore
  never counted, never required in the ledger, and nobody noticed: the
  accounting could read complete with an entire release unexamined. Treat
  an opaque release as its own ledger line (`2.1.242 — no published
  section; probed 2a/2b` or `… escalated`). Closing the blind spot in
  code — deriving the release set from the registry rather than from the
  changelog's own headers — is a separate change; this paragraph only
  documents it.
- **Watch for entries that land on the harness substrate itself**, which
  the 2a-2e taxonomy has no row for. Example (2.1.222): *"stream idle
  timeout firing on custom `ANTHROPIC_BASE_URL` gateways despite server
  keep-alive pings"* — the cc-harness mock **is** a custom
  `ANTHROPIC_BASE_URL` (`monitor/cc-harness/_lib.sh`), so that entry
  lands on the thing you are measuring with. Note such entries explicitly
  under a **2f — harness substrate** heading in your table.

### The carry-forward queue — entries a PRIOR fire left undriven

A fire that reads an entry, judges it relevant, and then does not drive
it has produced a **debt**, not a disposition. Left in a report, that
debt is invisible: the next fire reads a fresh changelog, the entry is no
longer in its delta, and nobody looks at it again. The queue is how the
debt survives to a fire that can pay it.

**Read it first, before you fetch anything:**

```bash
cat "$NEXUS_ROOT"/monitor/.state/cc-auto-update/carry-forward.md 2>/dev/null \
  || echo "(no carry-forward queue — nothing owed)"
```

Each item names a changelog entry (quoted verbatim, with the release it
came from), the surface it lands on, and why the prior fire could not
drive it. **Treat every open item as if it were an entry in THIS fire's
delta**: drive it, or disposition it explicitly. It is subject to the same
rules as everything else — in particular, if it lands on 2b/2c/2d you
cannot clear it by inspection (see "Silence is not clearance"), and
carrying an item forward a second time is not a disposition either.

**Then write the file back before you finish**, whatever the verdict:

- an item you **drove** — remove it, and record the result in your report
  table and ledger like any other entry;
- an item you **could not** drive — leave it, and append a dated line
  saying what blocked you. An item that has been deferred **three** times
  stops being a queue entry and becomes an issue on `<your-org>/nexus-code`:
  the queue is not a place to park work indefinitely.

Items enter the queue from three places: a fire that flags an entry it
cannot reach, a skeptic pass that finds an entry the triage skipped, or an
operator adding one by hand. Append-only in, explicit-disposition out; the
file is gitignored local state (under `monitor/.state/`), so it is
per-operator by design. Nothing in code reads or writes it today — the
mechanism is this section and the matching step 0 in
`monitor/cc-auto-update-prompt.md`.

## Step 2 — COLLISION ANALYSIS (the checklist)

Walk every surface. For each, the question is: *did this release change
the bytes/contract this nexus code depends on?* The changelog narrows
where to look; the cc-harness gate (Step 3) is what actually proves
pass/fail for the renderer surfaces. `skills/nexus.tmux-spawn` is the
canonical pointer: "if a Claude Code update shifts these markers,
update `_detect_*` in `pane-state.sh`."

### 2a. `monitor/pane-state.sh` — fragile TUI markers

The classifier greps raw ANSI off the live pane. Current signatures
(verify they still match the candidate's rendering):

- **`_detect_autosuggest`** — TWO arms, both real, and a candidate can
  break either independently: (a) `\x1b[7m.\x1b[0;2m` (reverse-video
  first char + faint/dim tail on the input row); (b) a bare dim run
  after the chevron with no reverse-video cursor at all
  (`_detect_dim_run`, `<your-org>/nexus-code#626`) — nineteen windows
  rendering ghost text classified `empty` before arm (b) existed. Arm
  (a) alone is what a `0;2m` → `2m` change breaks; check both.
- **`_detect_user_typing`** — `\x1b[38;5;231m` (bright-white user text).
- **`_detect_busy`** — TWO forms, and the second is not optional:
  (a) the active token-counter `[↓↑] N tokens` on the spinner row in the
  10 lines above the input (the idle banner uses a past-tense form with
  no counter, so a wording/format change to the counter mis-reads
  busy↔idle); (b) `_detect_throttled`, below.
- **`_detect_throttled`** — **the entry `monitor/pane-state.sh` itself
  names this list for** (`:1598-1601`, `<your-org>/nexus-code#1340`). The
  `/low-priority` retry chrome: `esc to interrupt` AND
  (`waiting for capacity` | `lower priority`) in the spinner window,
  **both matched case-INSENSITIVELY**. Both strings are the HARNESS's,
  not ours, and the failure direction is the dangerous one — a reword
  (or a capitalisation-only change: `Waiting For Capacity`) returns a
  live, mid-turn pane to `idle`, which is on the KILL ALLOWLIST. It is
  carried as the FIELD `throttled=1` on `busy`, never as a state token.
  Fixture: `monitor/watcher/fixtures/throttled-low-priority-capitalised-synthetic.ansi`.
- **`_dialog_is_login`** — the `/login` flow's select dialog
  (`<your-org>/nexus-code#1518`). THREE disjuncts, any one sufficient, all
  case-INSENSITIVE: a bare `Login` row (`^\s*Login\s*$`),
  `Select login method:`, `How do you want to sign in?`. Captured from
  the real binary at **2.1.268**; fixtures
  `monitor/watcher/fixtures/blocked-login-method-realmodel-268.ansi` and
  `…/blocked-login-signin-realmodel-268.ansi`.
  **A FOURTH disjunct (d) covers the non-menu screens** (`w237sk` F2),
  two literals either sufficient: `Paste code here if prompted` and
  `Use the url below to sign in`. Fixture
  `…/blocked-login-codepaste-realmodel-268.ansi` (OAuth query string
  redacted — inert PKCE for a login that never completed). All four
  disjuncts are matched within the **bottom 20 non-blank rows** via
  `_bottom_rows`, anchored to the dialog region rather than the whole
  pane (`w237sk` F7), and `auth=login` additionally requires **no
  `❯<NBSP>` REPL input row** — the structural live-vs-quoted test, which
  is what stops a pane merely discussing a login screen from being
  labelled.
  **COVERAGE BOUNDARY, stated because it is what a checker needs:** the
  screens captured are the two method menus and the browser-auth /
  code-paste step. Whether the 2.1.268 flow has further screens, and what
  each classifies as, is **unmeasured**. A new screen is covered only if
  it carries one of these four literals in its bottom 20 rows.
  **CORRECTED — this entry previously claimed the failure direction was
  SAFE, and at the time that claim was FALSE** (skeptic `w237sk` F1).
  The reasoning was that both frames classify `state=blocked` from the
  *frame* rather than the wording, so a reword could only cost the label.
  The reasoning was right about `pane-state.sh` and wrong about the
  **hold**, which keyed on `auth=login` **AND** `state=blocked` — so a
  reword dropped the hold entirely and the watcher pasted into the
  operator's `/login` screen. Verified by construction. A checker who
  trusted this entry would have skipped the one string set that mattered,
  which is the worst possible failure for this document.
  **It is true NOW, and by construction rather than by argument.** The
  emit hold is a DISJUNCTION — `state=blocked` **OR** `auth=login` — so a
  reword of all four disjuncts still leaves the structural arm holding
  every menu frame. `test-auth-hold.sh` part F1 asserts it by calling
  `_auth_hold_active` on a reworded capture, which the superseded Part B
  did not do (it asserted a `pane-state.sh` property and concluded a
  `_auth_hold` one).
  **What a reword still costs:** the `auth=` label, hence the log line
  and the `sandbox-notify` wording — which then says the dialog kind is
  UNKNOWN rather than guessing `login`. Carried as the FIELD `auth=login`,
  never as a state token.
  **AND THE DISJUNCTION'S OTHER ARM IS NOT OPTIONAL** (`w237sk` F2): the
  flow's BROWSER-AUTH / CODE-PASTE step is not a multi-option menu, so
  `_has_menu_dialog_frame` declines and it classifies **`state=empty`** on
  the live pane — measured at 2.1.268. `empty` can never join the
  structural arm, so that screen is covered by `auth=login` alone, via
  disjuncts (d) below and the no-REPL-row live test. Check BOTH arms: a
  reword breaks the label arm, and a frame-shape change breaks the
  structural one.
- **`_detect_auth_expired`** — the LOGGED-OUT render
  (`<your-org>/nexus-code#1518`, the pane-surface half of `#1517`). THREE
  disjuncts in the bottom 15 non-blank rows, case-INSENSITIVE:
  `Please run /login`; `Login expired`; `401` *and* `token has expired`
  on ONE row. Measured at **2.1.268**, both mid-retry
  (`✻ 401 OAuth token has expired … · Retrying in 16s · attempt 6/10`)
  and terminal (`● Please run /login · API Error: 401 OAuth token has
  expired.`). Fixtures `…/auth-expired-retrying-realmodel-268.ansi`,
  `…/auth-expired-terminal-realmodel-268.ansi`.
  **Its failure direction is NOT safe, unlike the entry above, and the
  asymmetry is the reason both are listed separately.** This pane reads
  `state=idle` — on the KILL ALLOWLIST and the canonical paste-me state
  — so there is no structural fallback underneath these strings. A
  reword returns the board to `#1517` exactly: 8 resubmits and 10 false
  `recovered after …` lines over 45 h, with `auth` appearing in none of
  1,648 log lines. Disjunct (c) is the API's wording rather than the
  TUI's, so it rots on a different schedule and is the one most likely
  to survive a TUI release; (a) and (b) are the TUI's. Check all three.
  Carried as the FIELD `auth=expired`.
- **`_detect_queued_message`** — the literal `Press up to edit queued
  messages`, which Claude Code paints IN PLACE OF the input row while a
  turn is in flight with text submitted behind it. Note the ASCII space,
  not the `❯<NBSP>` of the real input row: a reword drops the pane back
  through `_find_input_row` to `empty` — *"don't know yet"* — for the one
  situation an orchestrator most needs to read correctly (`#603`, `#607`).
- **`_detect_empty_input`** — reverse-video space cursor `\x1b[7m \x1b[0m`,
  PLUS the 2.1.147 post-turn trailing-cursor variant (the harness's
  first catch; fixture `monitor/watcher/fixtures/idle-empty-post-turn-realmodel.ansi`).
- **`_has_blocked_overlay`** / over-limit / empty / absent — the dialog and
  dead-pane frames. `_has_blocked_overlay` is a five-arm ladder in
  precedence order: rate-limit (`What do you want to do?` +
  `Stop and wait for limit`), permission (`Do you want to proceed?` +
  the `❯ N.` chevron), `_has_bypass_permissions_modal`,
  `_has_askuq_overlay`, and — LAST, deliberately — the STRUCTURAL
  `_has_menu_dialog_frame`, which catches any select dialog nobody has
  enumerated yet (`<your-org>/nexus-code#896`). `_name_menu_dialog_kind`
  then keys on `trust this folder` /
  `Is this a project you created or one you trust?` to name
  `workspace-trust`; a reword there costs the KIND, not the `blocked`
  classification, because the structural arm still fires.
- **`_has_bypass_permissions_modal`** — the literals `Bypass Permissions
  mode` + `Yes, I accept`, plus a bottom-anchored `Enter to confirm`
  (the live-vs-quoted guard). Re-worded modal text does not merely lose
  a label: the case falls back through every overlay arm to `empty`,
  which is the mis-signposting `#768` cost a probe run to. Check this
  whenever a release touches the permissions modal, and note that its
  *suppression* is a `2d` concern (the migration) while its *detection*
  is this one.

A drift here is the highest-frequency historical breakage and the exact
class the cc-harness was built to catch.

### 2b. `monitor/watcher/_unstick.sh` — dialog signatures

The auto-unstick state machine matches literal dialog text:

- **Case A (permission prompt)** — the `Do you want to proceed?` /
  `What do you want to do?` text + the `❯ N.` numbered-option chevron.
  Action: auto-Enter the first option. If the release rewords the
  permission prompt or restyles the chevron, Case A stops firing.
- **Case D (AskUserQuestion chip-bar dialog)** — a **shape gate** (the
  chip-bar's two final options `Type something.` penultimate + `Chat
  about this` final) AND a **live-ness gate** (the bottom-anchored
  navigation footer `Enter to select · ↑/↓ to navigate · Esc to cancel`
  in the last few non-blank lines). Case D is matched BEFORE Case A
  (Case A's chevron would also match an AskUQ overlay). A change to the
  chip literals or the footer wording breaks the guard — and Case D is
  gated to the orchestrator window + a live-overlay check (#198), so
  re-verify both halves.
- **The rate-limit arm, matched FIRST** — `What do you want to do?` plus
  `Stop and wait for limit`. Same two literals as
  `_has_blocked_overlay`'s rate-limit arm in **2a**, so a reword breaks
  the classification and the unstick together; check them once, credit
  them twice.
- **Case C (api-error chip)** — a two-`grep -F` AND on
  `API Error: {"type":"error"` and `"Internal server error"`. These are
  a RENDERED API-error payload, i.e. bytes the candidate composes: a
  change to the chip's framing, or to the inner message text, silently
  stops the auto-retry and the pane sits wedged on an error nothing
  clears. Not covered by any gate scenario.

**What the gate covers here, precisely.** `test-realmodel-blocked-question.sh`
drives a live AskUserQuestion overlay and asserts `_has_blocked_overlay`,
so it covers the Case D **shape gate**. It does **NOT** cover the
bottom-anchored **footer** live-ness gate (`Enter to select · ↑/↓ to
navigate · Esc to cancel`), and it does not cover Case A at all. So
`2b=gate` is honest about the overlay shape only; a release that rewords
the navigation footer or the permission prompt is NOT caught by the gate
and needs a changelog read (carry-over open since 2.1.217).

**Footer parsing and OSC 8 hyperlinks.** Claude Code's status line can
render clickable badges as OSC 8 hyperlinks
(`ESC ] 8 ; ; <url> ESC \` … `ESC ] 8 ; ; ESC \`). `pane-state.sh`'s
`_strip_ansi` was CSI-only, so those bytes survived into the plain text
`_footer_handle_counts` parses — landing exactly on the ` · N shell[s] · `
boundary its regex anchors on, where they can both hide a real handle
count and contribute stray digits. `_strip_ansi` now strips OSC (both
BEL- and ST-terminated) before CSI, and
`monitor/watcher/fixtures/working-background-osc8-prbadge-synthetic.ansi`
plus its no-count negative control pin the behaviour.

Reachability, measured rather than assumed: on this host **tmux is 2.6**,
which predates tmux's hyperlink support (added in 3.2) — it consumes
OSC 8 and does not re-emit it from `capture-pane -e`, so these bytes do
not currently reach the parser through the live-pane path (verified
2026-08-06 by painting an OSC 8 anchor into an isolated pane and
capturing it with the production flags; **0 of the 28 pre-existing
committed fixtures** carry OSC bytes — the only 2 that did at that ref
were the differential pair the change adds, 2 of 30 then — and 0 of 5
live panes carried them, measured at `dc4c76f`. Re-derived at
`a3177ef6`: still exactly those 2, now of **60** `.ansi` fixtures).
**That proof is version-scoped, not
structural**: on tmux ≥ 3.2 `capture-pane -e` does re-emit hyperlinks, so
a host or container upgrade silently makes them reachable. Re-check the
tmux version if you are re-clearing this.

### 2c. VI-mode insert handling (spawns + follow-ups)

Claude Code supports VI keybindings. Spawn/follow-up delivery sends `i`
first to force insert mode before pasting, else the message would execute
as VI motions and be silently lost (`skills/nexus.tmux-spawn` "VI-mode
hazard"). If a release changes the default mode, the mode indicator, or
the key to enter insert, re-validate the spawn + follow-up paste paths
(`monitor/spawn-worker.sh`, the follow-up `set-buffer`/`paste-buffer`
sequence).

#### 2c is TWO sub-claims: `2c-paste` (driven) and `2c-vi` (measured per host)

Label them separately — `apply.sh` refuses the aggregate key `2c`. The
**delivery** half (multi-line `set-buffer`/`paste-buffer` arriving as one
turn) is genuinely drivable and has been driven with a real negative
control. The **VI-insert** half is the one this subsection is about, and its
class is **a property of the host you are evaluating on**, not of this repo.
The 2.1.224 round is the sixth of seven to label the pair `empirical` on the
strength of the delivery half alone.

#### 2c-vi is cleared by UNREACHABILITY or by probe — establish which, per host

> **This file is shared by every operator who clones `nexus-code`, and the
> answer differs between them — measured on two hosts the same day
> (2026-08-07): one has `editorMode: "vim"` set and ~90% of agent panes in
> VI mode, the other has no `editorMode` key anywhere and 0 panes.** So there
> is no verdict here to inherit, only a method. **Run the two commands
> below.** Both return zero → `2c-vi=reachability`. Either returns non-zero
> → VI mode is reached on your host and the honest label is `2c-vi=gate`,
> paid for by `test-realmodel-vimode` (`#724`'s probe, mapped by
> `<your-org>/nexus-code#867`) — provided that scenario name appears in the
> gate log you supply. See the end of this section.

**The standing fact, decomposed — because only one of its three conjuncts
is about this repo, and the third is host-dependent.** Checked
2026-08-07:

- `editorMode` / `vimMode` appear in **0** of this repo's config surfaces
  (`*.json` / `*.yml` / `*.yaml` under `monitor/`, `config/`, `skills/`).
  **True.**
- The cc-harness seeds a fresh `.claude.json` carrying **no `editorMode`
  key** (`monitor/cc-harness/_lib.sh`, `cch_setup`). **True**, and it is the
  subject of `<your-org>/nexus-code#724`.
- The **operator's config** does not select VI mode. **HOST-DEPENDENT — do
  not carry an answer across hosts.** Measured 2026-08-07 on two of them:
  - **Host A:** `editorMode: "vim"` set in **both** `~/.claude.json` and
    `~/.claude/settings.json`; **9 of 10** live tmux windows render
    `-- INSERT --`, the sole non-match being `services`, which is not an
    agent pane (stable across 4 consecutive runs).
  - **Host B:** `editorMode` / `vimMode` absent from **all 5** present
    settings files (`~/.claude.json`, `~/.claude/settings.json`,
    `~/.claude/sandbox-config/settings.json`, `monitor/worker-settings.json`,
    `monitor/orchestrator-settings.json`; `~/.claude/settings.local.json`
    does not exist); **0 of 4** live panes render an indicator.

**The differential control that reported the VI half inert seeded
`editorMode: "vi"`, and the binary does not accept that value.** Strings from
the pinned `claude.exe` (2.1.224): the schema enum is
`["normal","vim"]`, the field is declared
`Ir(wio).optional().catch(void 0)`, and the mode test is
`Lu("editorMode","normal").value==="vim"`. There is **no** comparison against
`"vi"` anywhere in the binary. `.catch(void 0)` means an out-of-enum value is
**silently discarded** rather than rejected, so seeding `"vi"` leaves the pane
in `normal` and no indicator can ever render. That control therefore **could
not fire** — the same "probe that cannot fail" this section exists to stop,
occurring inside the control written to establish it. Seed `"vim"`.

**The two readings are both correct — they are different hosts, and that
is the whole lesson.** An earlier revision recorded "no `editorMode` key
exists in `~/.claude.json` or `~/.claude/settings.json`", "0 of 5 live
panes"; the revision after it recorded `2` and `9 of 10` under four
independent tools (`grep`, `grep --no-ignore-files`, `rg`, a JSON parse)
and, reasonably, read the earlier `0` as unreproducible — the config
mtimes (2026-07-26, 2026-03-03) *predate* the measurement it was dated
to, so on **that** host the key was already present when the `0` was
written.

Re-run on Host B the same day, the `0` reproduces exactly: 0 hits across
all 5 present settings files, 0 of 4 live panes. Nothing was mis-measured
on either side. Two operators ran the same command on two machines with
different `~/.claude.json` files and got the two answers the machines
actually have.

What that costs, and it is not nothing: **a per-host measurement was
written into a shared repo as a repo-wide fact — twice, from both
directions.** The `"vi"`-vs-`"vim"` finding above is genuinely
version-scoped and belongs here; `editorMode` is user config and does
not. Keep host-specific numbers labelled with their host, and re-run the
commands rather than reading the table.

`<your-org>/nexus-code#724` — filed 2026-08-06 — states independently that
"every production nexus agent inherits `editorMode: "vim"` from user
scope." True on Host A, false on Host B; read it as the claim it is (one
operator's inheritance chain), and as one more reason to run the two
commands rather than cite the last round's answer.

Consequences, in order of how certain they are:

1. **Certain, by code — and it INVERTED when `#724` landed.** The
   cc-harness now seeds `editorMode` into `settings.json`, defaulting to
   **`vim`** (`cch_setup` → `cch_write_settings`, whose default comes from
   `CCH_EDITOR_MODE`), so panes booted here come up in **VI** mode —
   production parity — unless a scenario overrides `CCH_EDITOR_MODE`.
   **Until then** the harness seeded nothing and booted **default
   (emacs)**, which is why a probe prefixing its paste with `send-keys i
   BSpace` was a net no-op there: it typed `i` and deleted it, and so
   could not distinguish VI-insert hardening working from absent. (Proven
   by differential control on 2.1.222: the identical sequence with that
   line removed passed identically.) Two rounds — 2.1.216 and 2.1.222 —
   were fooled by exactly that. The rule outlives the fact: never assume
   the mode a pane booted in; assert the indicator.
2. **Measured — and the answer DIFFERS BY HOST, so measure yours.** On
   Host A, agent panes **are** in VI mode: `editorMode: "vim"` is set in
   `~/.claude.json` **and** `~/.claude/settings.json`, and 9 of 10 windows
   render a `-- INSERT --` indicator in the STATUS LINE (checked 2026-08-07
   at `473a55b` with check (ii) below; 4 consecutive runs identical, the one
   non-match being the non-agent `services` window). On Host B the same
   commands the same day return 0 of 5 settings files and 0 of 4 panes.
   Where the checks come back positive, `paste-followup` runs in **VI mode**
   and 2c is **live, not inert** — the `i`-prefix in the spawn/follow-up
   paste path is load-bearing there, and a release that changes the mode
   indicator or the insert key would break spawn delivery for real. Where
   they come back zero, it is inert. Neither is a fact about this repo.
3. **NOT a permanent invariant — do not write it as one.** VI mode is a
   *runtime-togglable user setting* (`/vim`), not a compile-time absence.
   Concretely, **20 of the 60 committed `.ansi` pane fixtures in
   `monitor/watcher/fixtures/` DO render `-- INSERT --`** (re-derived at
   `a3177ef6`; it was 10 of 30 when this was first written, i.e. the
   share is unchanged and the corpus doubled) — including real
   captures (`working-background-shell-realfooter.ansi`,
   `autosuggest-merge-win3.ansi`), i.e. panes on some operator's host
   genuinely were in VI mode when captured. Reachability is a property of
   THE HOST'S configuration TODAY, not of the nexus design — which is
   exactly why the two hosts above disagree, and why a verdict copied from
   the last round (or from another operator's clone) is worthless.

**So: re-establish reachability every round before you label 2c at all** —
it is two commands, and asserting it from memory is the same error class
this section exists to stop. The label follows the result, and only one of
these is payable:

- **returns 0** → `reachability` (inert on your host; say so explicitly,
  and say which host).
- **returns non-zero** → `reachability` is **not** payable. You need a real
  probe with a control (→ `empirical`), or you label it
  `source-inspection` and say the surface is unvalidated. Per the
  evidence-class rule above, what you must not do is keep the
  `reachability` label because a previous round — or another operator's
  clone — used it.

```bash
# (i) no CONFIG SURFACE selects VI mode. `editorMode` is a settings KEY, so
#     only config files can turn it on — scope the grep to those. A bare
#     repo-wide grep matches prose (this guide discusses `editorMode` by
#     name, as does monitor/cc-harness/_lib.sh) and returns a guaranteed
#     false alarm.
{ grep -rln --include='*.json' --include='*.yml' --include='*.yaml' \
       -e 'editorMode' -e 'vimMode' monitor config skills 2>/dev/null
  grep -ln -e 'editorMode' -e 'vimMode' \
       ~/.claude.json ~/.claude/settings.json \
       ~/.claude/settings.local.json 2>/dev/null
} | sort -u | grep -c .            # 0 => unreachable. YOURS is whatever this
                                   # prints: Host A read 2, Host B read 0.

# (ii) no live agent pane is actually in VI mode. Read the STATUS LINE, not
#      the scrollback: the indicator lives in the last rows the TUI paints,
#      whereas a pane merely DISCUSSING vi mode has the literal in its
#      transcript. NOTE `-S -N` sets the range START (N rows into history)
#      and still captures the whole visible pane — it does NOT mean "last N
#      rows"; take the tail explicitly. Target SESSION:INDEX rather than a
#      bare index: `-a` lists every session, but a bare `#{window_index}`
#      resolves against the CURRENT session, so on a multi-session host it
#      captures the wrong pane (or the same one twice). One session here, so
#      that is latent, not active.
tot=0; hit=0
while read -r idx _; do tot=$((tot+1))
  n=$(tmux capture-pane -t "$idx" -p 2>/dev/null \
        | grep -v '^[[:space:]]*$' | tail -n 3 \
        | grep -c -- '-- INSERT --\|-- NORMAL --')
  [ "$n" -gt 0 ] && hit=$((hit+1))
done < <(tmux list-windows -a -F '#{session_name}:#{window_index} #{window_name}')
echo "panes in VI mode: $hit of $tot"  # 0 of N => unreachable. YOURS is
                                       # whatever this prints: Host A read
                                       # 9 of 10, Host B read 0 of 4.
```

Both checks are control-tested — a check that cannot fire is the same defect
as a probe that cannot fail. Re-run at `473a55b` on 2026-08-07, each control
executed rather than carried over:

- (i) returns **0 for the repo surfaces** and **2 for the operator's
  config** (`~/.claude.json`, `~/.claude/settings.json`) — total **2** on
  2026-08-07 at `473a55b`, identical under `grep`,
  `grep --no-ignore-files`, `rg` and a JSON parse. It returns 1 more when
  `editorMode` is planted into `monitor/worker-settings.json`, so the
  repo-surface arm is live rather than vacuously zero.
- (ii) returns **`9 of 10`** across the live windows (4 consecutive runs, all
  identical; the non-match is `services`, not an agent pane), fires on both
  committed fixtures whose status line genuinely
  renders `-- INSERT --` (`working-background-shell-realfooter.ansi`,
  `autosuggest-merge-win3.ansi`), and does NOT fire on a pane whose
  *transcript* merely mentions the literal — the pane this was run from has
  3 scrollback hits and is still counted only via its real footer.

Both checks come back non-zero, so **on this host 2c is reachable**: any
changelog entry touching keybindings or input mode needs a real probe —
one that seeds `editorMode` explicitly and asserts the `-- INSERT --`
indicator actually renders before it claims to have driven VI mode.

**That probe now EXISTS** — `<your-org>/nexus-code#724` is closed and
`monitor/watcher/test-integration/test-realmodel-vimode.sh` is in the gate's
scenario list. `cch_setup` seeds `editorMode: "vim"`, so the harness finally
boots the mode production runs, and the scenario carries three arms: seeded
`"vim"` → indicator PRESENT; no key → ABSENT; out-of-enum `"vi"` → ABSENT.

**`2c-vi=gate` is now PAYABLE** (`<your-org>/nexus-code#867`).
`_surface_gate_scenarios` maps `2c-vi → test-realmodel-vimode`, so on a host
where the re-checks come back non-zero the honest label is `2c-vi=gate`,
provided the scenario name actually appears in the gate log you supply — the
cross-check is unchanged and still has the teeth.

Until that entry existed the map covered only `2a`, `2b` and `2d`, and the
claim was refused. That was fail-CLOSED, so it blocked no bump; the cost was
that a real, driven, control-tested probe passed every round while the surface
it covers recorded as argued-not-driven, on the input path spawn and follow-up
delivery depend on.

**`2c-paste` is deliberately still unpayable as `gate`.** Nothing in the
harness drives the paste-delivery half, so it keeps `empirical` (with a stated
negative control) or `source-inspection`. The two halves of `2c` keep separate
labels — that is the whole reason the surface was split — and the composite
still records as the WEAKEST of them.

### 2d. Hooks + settings schema

The nexus rides Claude Code's hook + settings contract. Files:
`monitor/orchestrator-settings.json`, `monitor/worker-settings.json`,
hook scripts in `monitor/hooks/`.

- Hook **events** in use. **Derive these, do not read them from here** —
  the settings files are the vocabulary, and this list has drifted from
  them before:

  ```bash
  python3 -c 'import json,sys
  for f in ("monitor/orchestrator-settings.json","monitor/worker-settings.json"):
      print(f, sorted(json.load(open(f)).get("hooks",{})))'
  ```

  At `a3177ef6` that returns **six** for the orchestrator —
  `Notification`, `PostToolUse`, `PreToolUse` (`AskUserQuestion` matcher
  → `block-askuserquestion.sh`, the Case D Layer A), `Stop` (heartbeat
  stamp), `StopFailure`, `UserPromptSubmit`
  (`orchestrator-session-pin.sh` + paste-received stamp) — and **seven**
  for the worker, the same set plus `PermissionRequest`. An earlier
  revision of this line named only three orchestrator events and omitted
  `StopFailure`, which is precisely the event the over-limit path rides.
- The `skipDangerousModePermissionPrompt: true` settings key — and the
  **MIGRATION** that puts it there, which is itself version-sensitive
  (<your-org>/nexus-code#768). On first boot the binary moves
  `.claude.json`'s `bypassPermissionsModeAccepted` into
  `settings.json` as `skipDangerousModePermissionPrompt: true` **and
  deletes the original** — both files in the config dir named by
  `CLAUDE_CONFIG_DIR` (written without a `$` on purpose: prose here is
  linted for copy-pasteability, and a bare sigil outside a fenced
  block has no defining shell). Measured on 2.1.224, isolated config
  dir, one boot:

  ```
  PRE-BOOT  .claude.json : {"bypassPermissionsModeAccepted":true,"hasCompletedOnboarding":true,"theme":"dark"}
  PRE-BOOT  settings.json: (does not exist)
  POST-BOOT .claude.json : {"bypassPermissionsModeAccepted":null,"hasCompletedOnboarding":true,"theme":null}
  POST-BOOT settings.json: {"editorMode":"vim","skipDangerousModePermissionPrompt":true}
  ```

  So after ANY boot the only thing suppressing the Bypass Permissions
  warning lives in `settings.json`. Two consequences a candidate
  evaluation must check, because both are silent:

  1. **Anything that rewrites a user-scope `settings.json` between
     boots must MERGE, or re-supply the key.** A replace wedges the
     next boot on the modal. Nothing in this repo writes that scope
     today (`spawn-worker.sh` passes `--settings
     monitor/worker-settings.json`, a *different* scope), so this is
     latent — it goes live the moment a bootstrap step, settings
     overlay, or config-reset recovery path manages user-scope
     settings. `monitor/cc-harness/_lib.sh:cch_write_settings` always
     re-supplies the key, which is why the harness is immune.
  2. **If the migration's shape changes** — a different target key, a
     different file, or the original no longer deleted — a config dir
     seeded the old way stops suppressing the modal. That is a `2d`
     finding, and it also lands on `2a`: the modal's literals are now
     a detection surface (`_has_bypass_permissions_modal` in
     `monitor/pane-state.sh`), so re-worded modal text breaks the
     naming as well as the suppression.

  The failure used to be mis-signposted, which is what made it
  expensive: the pane never reaches `idle`, and before `#768` it
  reached no overlay arm either, so it read `empty` — *"don't know
  yet"* — and presented as a slow boot. It now reports
  `state=blocked overlay=bypass-permissions`.
- Confirm the candidate still honours the same hook-event names,
  matcher syntax, the hook input/output JSON contract (the heartbeat /
  paste-received / session-pin / decision-emit / async-launch-detect
  hooks all parse it), and the settings keys. A renamed event or a
  changed matcher schema silently disables a hook — and a disabled
  heartbeat/Stop hook is exactly the wedge the watcher can't see.

#### What the gate actually covers for 2d — and what it does not

Be exact here; "partial gate coverage" is how this surface got
mis-credited. The gate wires hooks in exactly **two** scenarios:

| Scenario | Hook events wired | Covers |
|---|---|---|
| `test-realmodel-overlimit.sh` | `StopFailure` → `over-limit-emit.sh`, `Stop` → clear | the over-limit stamp path **only** |
| `test-realmodel-pretooluse-hook.sh` | `PreToolUse` (matcher `Bash`) | the PreToolUse payload contract |

Everything else boots through `cch_boot_worker`, which passes
`--settings` **only** when a scenario sets `CCH_SETTINGS` — so the
renderer scenarios still run hook-free by design.

**The 2.1.222 error, so it is not repeated:** that round credited
"partial gate coverage" for a **PreToolUse** changelog entry on the
strength of the over-limit scenario's `Stop`/`StopFailure` wiring. Those
are **different hook events**. Coverage of one hook event is not evidence
about another. `apply.sh` now refuses `2d=gate` unless
`test-realmodel-pretooluse-hook` appears in the gate log you supplied —
the over-limit scenario will not pay for it.

`test-realmodel-pretooluse-hook.sh` drives a real Bash tool call through
a `--settings`-wired PreToolUse hook and asserts `hook_event_name`,
`tool_name`, and an intact `.tool_input.command` — the exact fields
`monitor/hooks/gh-write-guard.sh` extracts at `:37` (`.tool_name`) and
`:40` (`.tool_input.command`), and that `bash-footgun-guard.sh` parses
too. It carries its own negative controls (a hooks-stripped arm that
must NOT produce the marker, and a doctored-payload arm proving the field
extractor is not vacuous), so a green result means something.

Hook events NOT covered by any scenario — `PostToolUse`, `Notification`,
`PermissionRequest`, `UserPromptSubmit` — remain `source-inspection`.
Say so; do not round them up to `gate`.

### 2e. CLI flags the nexus depends on

Spawn surfaces invoke the binary with these — confirm each still works:

- **`--dangerously-skip-permissions`** (or
  `skipDangerousModePermissionPrompt`) — every spawn relies on it.
- **`--settings <path>`** — `monitor/spawn-worker.sh` passes the repo-
  tracked settings file unconditionally.
- **`--continue` / `--resume`** — `monitor/watcher/spawn-fresh-orchestrator.sh`
  and the claude-loop wrapper resume sessions; PR #147's session-id pin
  depends on `--continue` picking the right jsonl.
- **`--session-id`** — **adopted, not prospective.** `spawn-worker.sh`
  generates a uuid and passes `--session-id` for every worker it invokes
  `claude` for directly (`:2925-2950`, `<your-nexus>#206`; the
  loop-wrapper shape is deliberately excluded, and a uuid-generation
  failure degrades to no flag), and the orchestrator's cold-spawn
  degradation (`#203`) uses it too — see Step 5b's pre-flight. A change
  to its acceptance or to the id format breaks worker session tracking
  and the cold-spawn fallback at once.
- **`-p` vs positional prompt** — the harness uses both (`claude -p`
  headless; the launcher passes a positional prompt).
- **`-n` / `--name <name>`** — probed by CAPABILITY, never by version, in
  `monitor/_claude-bin.sh:claude_supports_name_flag`, which greps
  `--help` for the literal `--name <name>`. It is what pins a session's
  MESSAGING address (`<your-org>/nexus-code#1047`). **A help-text reword
  alone is enough**: the probe degrades to "not supported", the session
  self-names from its cwd basename, and cross-session addressing fails
  later, far from the cause. The degrade is loud on stderr but does not
  fail a spawn — so nothing turns red, which is why it belongs on this
  list. The probe is bounded by the `NEXUS_CLAUDE_HELP_TIMEOUT` environment
  variable (default 10 s, set in `monitor/_claude-bin.sh`) and distinguishes a
  timeout from an answer.

- **`--plugin-dir <path>`** — probed by CAPABILITY in
  `monitor/_claude-bin.sh:claude_supports_plugin_dir_flag` (greps `--help`
  for the literal `--plugin-dir <path>`), spliced by
  `monitor/_longjob-plugin.sh:longjob_plugin_flag` into every launcher
  (worker fresh/resume/loop, orchestrator respawn). FAIL-OPEN: a reword or
  removal degrades to "no flag", one stderr line and a `skipped` row in
  `monitor/.state/longjob/arming.log` — the spawn proceeds, so nothing
  turns red, and every session then lacks its longjob-watch dispatcher.
  Surface 2g below is where that is caught.

A flag rename/removal/semantics-change here breaks spawning or respawn
outright. Grep the candidate's `--help` and diff against these.

### 2f. The shell snapshot's `grep` DELEGATION ARM SET (<your-org>/nexus-code#1234)

One command, and it is the only surface here whose drift invalidates
**documentation rather than code**:

```zsh
monitor/grep-delegation-arms.sh          # 0 reviewed · 1 BROKEN · 3 N/A · 4 unreviewed
```

**What it is about.** Claude Code's shell snapshot installs `grep` as a shell
FUNCTION running ugrep embedded in the `claude` executable — except that it
opens with a loop whose `case` arms hand certain ARGUMENTS to `command grep`
(the system GNU binary) instead. Two `CLAUDE.md` entries straddle that split and
are each correct only on their own side of it: `GREP-BRE-DIALECT` needs its
patterns to REACH ugrep (so a bare call is loud), and `DASH-PATTERN-OPTION` says
Mode 1 is loud here *only because* a `---`-leading argument is DELEGATED.

**Why it belongs in a bump review specifically.** The arm set is a property of
the harness BUILD, not of this repo, so it can move with no diff anywhere a
suite looks — and no suite can pin it without going red on every other
operator's host. A bump is the moment it can change and the moment somebody is
already reading a changelog.

**Reading the exit code:**

| | |
|---|---|
| `0` | dependencies hold **and** the arms match this version's record — nothing to do |
| `4` | dependencies hold, arms **unreviewed** for this build. Read the printed arm set, then add an `ARMS` row to `monitor/grep-delegation-arms.manifest`. This is the normal outcome of a bump. |
| `1` | **a documented dependency is BROKEN.** The output names the `CLAUDE.md` block the new build invalidates. Fix the entry — it is now wrong — before the bump lands, and do not treat this as a tool defect. |
| `3` | no snapshot `grep` function here. Not a failure and **not a clearance**. |

It cannot see a change in what ugrep *does* with an argument it still accepts:
same arms, different behaviour, is invisible. That residual is the honest
ceiling — the arms are what a static check can reach.

### 2g. Plugin monitors — the longjob-watch dispatcher (<your-org>/nexus-code#1535)

Every nexus launcher passes `--plugin-dir monitor/longjob-plugin`, whose
manifest declares ONE `experimental.monitors` entry; the host arms it at
session start with no model turn and delivers each stdout line of the
command as a task notification. This is the only mechanism that wakes an
agent when a job outlives the 30-minute `Monitor` cap, and it rests on
FOUR harness contracts, all EXPERIMENTAL or undocumented:

- **`experimental.monitors` in `plugin.json`** — the supported form; the
  top-level `monitors` form "will be removed in a future release" per
  `claude plugin validate` at 2.1.272. Schema (from the binary): `name`,
  `command`, `description`, `when: "always" | "on-skill-invoke:<skill>"`;
  the `CLAUDE_PLUGIN_ROOT` placeholder is substituted; runs in the session cwd; the
  command's environment is claude's own (measured: `NEXUS_*`,
  `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID` all present).
- **A monitor command that EXITS is not relaunched** and its exit is
  delivered as a "script failed" notice that costs a turn (measured
  2026-09-15: ~16–21 s, ~$0.11 per session). The dispatcher never returns
  for that reason. A release that starts relaunching would be harmless; a
  release that stops delivering the exit notice would hide a crashed
  dispatcher — `ng longjob status` (ledger freshness + pid identity) is
  the detector, not the notice.
- **`CLAUDE_CODE_SESSION_ID`** exported to the monitor command and to
  Bash-tool shells alike — the spool's session key. If a release drops it,
  the key falls back to the window name (`win-<name>`), the spool no
  longer follows `--resume`, and `test-realmodel-longjob-wake.sh` still
  passes (it pins the key explicitly) — so CHECK THE ENV by hand:
  `printenv CLAUDE_CODE_SESSION_ID` in a candidate session.
- **The host's per-monitor OUTPUT LIMITS** (skeptic F1/F4 on `#1535`): a
  token bucket `pce(dce=10, Ate=2000)` — 10 batches, refill one per 2000 ms,
  consumed per 200 ms batch (`mIs=200`) — whose empty-bucket arm DISCARDS the
  batch and later delivers only `[plugin monitor "…" suppressed N events]`;
  a per-line cut `bVe=500` and a per-batch cut `ylr=3000`. The dispatcher
  paces emits ≥ 2500 ms apart (`EMIT_MIN_GAP_MS`) and composes lines ≤ 480
  chars head-first. A release that tightens either constant silently
  re-opens both holes; a release that loosens them costs nothing. Re-read
  the constants from the candidate's strings (`dce=`, `Ate=`, `bVe=`).
- **The footer token `· N monitor ·` / `N monitor still running`** —
  `pane-state.sh:_footer_handle_counts` reads it, and
  `_longjob_dispatcher_discount` subtracts the idle dispatcher's handle
  from it using the dispatcher's ledger. A reword makes the count 0:
  every idle session reads `idle` (the SAFE direction for retirement,
  but the model-armed-Monitor exemption is lost with it). A change in
  the opposite direction (a new handle kind counted as `monitor`) makes
  idle sessions read `working-background` again — the board-freezing
  direction. Fixture:
  `monitor/watcher/fixtures/idle-longjob-dispatcher-armed-realmodel-272.ansi`.

- **THE ROLLOUT FLAG — the load-bearing one, and the one the gate cannot
  see.** Arming is `PCe()` in the binary:
  `if(Br("pluginMonitors"))return; if(!oD())return; if(Ae())return;` where
  `oD()` is `I("tengu_amber_sentinel", false)` — a GrowthBook feature flag
  whose DEFAULT IS FALSE. Plugin monitors arm only when GrowthBook serves
  that flag true, and GrowthBook is initialised only for first-party auth
  with telemetry on ("GrowthBook is off for this session: a third-party
  provider, or telemetry opted out" → defaults). The public build stubs
  every local override (`getEnvironmentOverrides(){return null}`,
  `readConfigOverrides(){return}`), so nothing on this side can force it.
  The value the last first-party session received is cached in the global
  config: `jq .cachedGrowthBookFeatures.tengu_amber_sentinel
  <CLAUDE_CONFIG_DIR>/.claude.json` (true on 2026-09-15; 645 flags cached),
  and `ng longjob status` prints it as `host_rollout_flag`. **If Anthropic
  flips it, every nexus session silently launches without a dispatcher**:
  no launcher error, no red suite, only `add` saying NOT ARMED, `status`
  reading `absent`, and the footer losing `1 monitor`. Check the cached
  value and the flag NAME (a rename reads `absent`) on every bump.
  `Br("pluginMonitors")` is the `--safe-mode`/`CLAUDE_CODE_SAFE_MODE` table
  (disabled there; `--bare` leaves it enabled); `Ae()` is "not interactive".

**What the gate checks, and what it cannot.** `test-realmodel-longjob-wake.sh`
exists and is **EXEMPT, by measurement**: under the mock backend the binary is
a third-party provider, GrowthBook is off, and `tengu_amber_sentinel` is its
default, so the dispatcher never arms — four harness boots on 2026-09-15
(trust seeded, telemetry re-enabled, the cache seeded with the flag true)
all read footer `0 monitor` and no ledger. The scenario boots, sees no
ledger and skips with that reason. **The real-binary measurement is
therefore a by-hand, real-auth probe, and it costs quota (≈ $0.5 for the
full set at 2.1.272):** `monitor/longjob-realauth-probe.sh` — hermetic tmux
on a private socket, the shipped plugin, one session per case — and it is
what produced the numbers on `<your-org>/nexus-code#1535`: armed with no turn,
env inherited, a session starts and takes a turn with a missing dir / a
malformed manifest / a non-existent command / a command exiting 3, an event
emitted during a 100 s foreground tool call surfaced inside that turn, and
the exit-notice cost of a crashed monitor. Run it against a candidate with
`CLAUDE_BIN=<candidate>`; read its `RESULTS.md`. Also run the capability
probe by hand, since a `--help` reword is read as "unsupported":
`CLAUDE_BIN=<candidate> bash -c '. monitor/_claude-bin.sh; claude_supports_plugin_dir_flag && echo yes'`.

**How we would notice the day the host stops arming them, without the
gate:** every `ng longjob add` prints `dispatcher: NOT ARMED` at rc 3 and the
worker floor tells the worker to read that line; `ng longjob status` reads
`absent`; fresh sessions' footers stop showing `1 monitor`; and every added
watch is declared as an `external_waits` entry, so an unarmed session reads
`idle-orphan-async` and the watcher's orphan-async loop resolves it through
`longjob-watch.sh resolve`. None of those is the emit path.

## Step 3 — TESTING PIPELINE (the cc-harness gate)

The renderer surfaces in 2a/2b can only be *proven* by driving the real
candidate binary. That is exactly `monitor/cc-harness/` (real binary,
auth-free injectable mock, no network egress — see
`monitor/cc-harness/README.md`).

```bash
monitor/cc-harness/gate.sh --version <candidate>
```

`gate.sh` installs the candidate into a throwaway prefix (the live pin
is untouched), then:

1. Runs **two** safety pre-flights, each first with `--selftest` (the
   negative control) and then for real:
   `monitor/cc-harness/lint-no-mass-kill.sh` and
   `monitor/cc-harness/lint-no-tmux-server-kill.sh` — see the hard rule
   below, which names both.
2. Drives the candidate through the scenarios named in `gate.sh`'s
   `gate_prod_scenarios` array — **not** every `test-realmodel-*.sh` on
   disk; the difference is exactly what `gate-coverage.tsv` ratchets —
   asserting `pane-state.sh` still classifies the live panes. The
   **eight** gated scenarios at `a3177ef6`
   (`monitor/cc-harness/gate.sh:606-657`):
   - `test-realmodel-idle-busy.sh` → exercises **2a** `_detect_busy` /
     `_detect_empty_input` (drip-streamed busy window vs post-turn idle).
   - `test-realmodel-blocked-question.sh` → exercises the
     AskUserQuestion overlay → `_has_blocked_overlay` (the **2b** Case D
     shape).
   - `test-realmodel-autosuggest.sh` → asserts the production classifier
     on the real autosuggest renderer bytes (**2a** `_detect_autosuggest`),
     anchored to a live pid + the liveness-gated `absent` degrade.
   - `test-realmodel-overlimit.sh` → the over-limit `StopFailure` payload
     shape + reset-time detection (**2d**, over-limit path only).
   - `test-realmodel-pretooluse-hook.sh` → a real Bash tool call through a
     `--settings`-wired **PreToolUse** hook, asserting the payload fields
     the nexus guards parse (**2d**, PreToolUse contract).
   - `test-realmodel-vimode.sh` → boots at production `editorMode: "vim"`
     and asserts the `-- INSERT --` indicator across three arms
     (`<your-org>/nexus-code#724`). **This is what makes `2c-vi=gate`
     payable**; see the evidence-class rule.
   - `test-realmodel-trust-dialog.sh` → the structural select-dialog arm
     (`#896`): un-seeds `hasTrustDialogAccepted` and asserts
     `blocked` + `overlay=workspace-trust` rather than `empty`.
   - `test-realmodel-trust-sandboxed-env.sh` → the `CLAUDE_CODE_SANDBOXED=1`
     canary every `spawn-worker.sh` launcher relies on to stay off the
     workspace-trust dialog (`#1334`), with a control arm.

   `test-realmodel-apispoof.sh` and `test-realmodel-long-exchange.sh`
   exist and are **exempt** — a named gap, tracked at
   `<your-org>/nexus-code#1486`, not an absence.

Exit 0 = **GREEN** (covered surfaces intact). Non-zero = **RED**.

**What a pass/fail means per surface** — this is the map you translate
into evidence classes:

| Surface | Gate coverage | Honest class on a green gate |
|---|---|---|
| **2a** pane-state markers | full (`idle-busy`, `autosuggest`) | `gate` |
| **2b** unstick dialogs | overlay **shape** only — not the Case D footer, not Case A | `gate` for the shape; footer/Case A need a changelog read |
| **2c-vi** VI-mode | `test-realmodel-vimode` (`#724`, mapped `#867`) | `gate` where the 2c re-checks come back NON-zero; `reachability` where they come back zero — re-check per host, see 2c |
| **2c-paste** paste delivery | none — `gate-coverage.tsv` declares `monitor/paste-followup.sh` a `known-gap` | `empirical` (with a stated negative control) or `source-inspection` |
| **2d** hooks + settings | `PreToolUse` + over-limit `Stop`/`StopFailure` | `gate` for those events; every other event is `source-inspection` |
| **2e** CLI flags | none | `empirical` (a `--help` diff on the candidate binary, with a negative control) or `source-inspection` |

So: **green gate + a changelog review that clears the uncovered
surfaces, each with an honest evidence class = safe**. A **red** gate
means a specific scenario failed → a drift → the matching `_detect_*` /
dialog signature / hook parse needs updating (and a fresh fixture
captured from the candidate) *before* the bump is safe.

**A gate that cannot fail is not a gate.** If you add or change a
scenario during an evaluation, run a mutation check on it: break the
thing it asserts and confirm the scenario goes RED. Shipping an
assertion that passes unconditionally reproduces the exact defect this
guide is built around.

### Staging a candidate binary for the non-gate probes — `--prefix`, never `cd` + install

The probes that need a candidate binary IN HAND (2c, 2d, the nested-repo
trust arms, `_unstick.sh` Case A) have nothing left after a plain
`gate.sh --version <v>` run: it installs into a throwaway prefix and
moves it aside on exit. Two supported ways to keep one
(`<your-org>/nexus-code#1002`):

```bash
CANDIDATE=2.1.270            # the version under evaluation
# (a) gate AND keep the staged install — the gate runs as usual, the
#     EXIT-trap teardown skips the prefix, and the binary path is printed:
monitor/cc-harness/gate.sh --version "$CANDIDATE" --keep-prefix \
    2>&1 | tee "$NEXUS_ROOT"/monitor/.state/cc-auto-update/gate-"$CANDIDATE".log
grep -F '=== kept-prefix:' "$NEXUS_ROOT"/monitor/.state/cc-auto-update/gate-"$CANDIDATE".log
#   → === kept-prefix: claude_bin=<dir>/node_modules/.bin/claude prefix=<dir> ===
export CLAUDE_BIN="<that claude_bin>"   # paste the printed claude_bin path

# (b) stage without gating — the same root-resolution-immune install the
#     gate uses, as a function (monitor/cc-harness/_lib.sh):
. monitor/cc-harness/_lib.sh
CLAUDE_BIN=$(cch_stage_candidate "$CANDIDATE" "$PWD/scratchpad/cc-$CANDIDATE")
"$CLAUDE_BIN" --version      # the helper has already asserted this is the CANDIDATE
```

Either way, remove the prefix when you are done — `trash_path <dir>`
(`monitor/_trash.sh`, rename-aside, safe over NFS) or `rm -rf` on a local
filesystem. `cch_stage_candidate` refuses (exit 2) an empty version or a
prefix that is the nexus root itself, refuses (exit 3) a stage that
produced no binary under the prefix, and refuses (exit 4) a binary that
does not report the requested version — the three shapes a mis-rooted
install takes. A `0` from it means the path it printed IS the candidate.

**If you stage by hand anyway, the ONLY form is `npm install --prefix
<dir> --no-save @anthropic-ai/claude-code@<v>`.** `--prefix` is immune to
npm's root-resolution walk. The tempting form — `mkdir -p <dir> && cd
<dir> && npm install --no-save …` — is **cwd-dependent and silently
wrong**: `<dir>` has no `package.json`, so npm walks UP to the nexus
root's, and installs the candidate into the **LIVE `node_modules`**. It
prints `changed 2 packages`, exits 0, and with `--no-save` nothing tracked
changes, so `git status` stays clean and nothing signals the drift. That
is exactly how the 2026-08-25 incident happened: a gate-RED 2.1.245 sat in
the live tree for a measured ~25 s, inside a ~37 s window during which
`node_modules/.bin/claude` was twice absent altogether — every spawn
resolves that path fresh, so a worker landing in either sub-window would
have booted the unvetted binary or failed to resolve `claude` at all. It
also bypassed the `trash_path` move-aside pattern (`#310`/`#312`) and left
a `.nfs` lock plus an orphaned staging dir in the live tree. Nothing
spawned in the window; that was luck, not design. The cause-agnostic
detector for this whole class is the live-tree assertion under Step 4.

### Hard safety rule (2026-05-29 postmortem) — do not weaken

The harness must **NEVER** run a cmdline-pattern process kill
(`pkill -f` / `--full`, `pgrep -f`, `killall`). In the sandbox's single
PID namespace such a pattern matches the shared project-local `claude`
binary across **every** agent and SIGTERMs them all at once (the
2026-05-29 mass-kill). `gate.sh` runs `lint-no-mass-kill.sh` as a
pre-flight that fails red on any such pattern; PID-scoped `pkill -P` is
the only allowed form.

**There is a SECOND pre-flight on the tmux-SOCKET axis, and its blast
radius is strictly worse**: `lint-no-tmux-server-kill.sh`
(`<your-org>/nexus-code#644`) — killing the tmux server ends the session
`bwrap` holds open and tears down the whole sandbox. It requires
`kill-server` to carry an explicit `-L`/`-S` and `kill-session` to carry
`-t`. `gate.sh` runs both lints, each `--selftest` first, at
`monitor/cc-harness/gate.sh:211-234`.

If you touch harness code during an evaluation, **do not** disable,
bypass, or loosen either lint.

## Step 4 — DECISION

Combine the gate result with the changelog review:

| Verdict | When | Action |
|---|---|---|
| **safe to bump** | gate GREEN **and** every surface key (`2a 2b 2c-paste 2c-vi 2d 2e`) carries an honest evidence class (no unsubstantiated `empirical`) **and** `2b`/`2c-paste`/`2c-vi`/`2d` are each cleared by `gate`, `empirical` or `reachability` — **never** by `source-inspection` and never by changelog silence (see "Silence is not clearance") **and** every changelog entry of every release in the delta is dispositioned, with no release contributing an opaque or absent section (see "An OPAQUE changelog", Step 1) **and** the live tree equals the effective pin (below) | proceed to Step 5 |
| **needs manual review** | gate GREEN but changelog flags VI-mode / hook / settings / CLI changes (2c/2d/2e), **or** a minor/major version jump, **or** any of 2b/2c/2d rests on `source-inspection`, **or** any release in the delta published an opaque/absent changelog section | do the targeted manual check for the flagged surface; if it holds, bump; if uncertain, surface on `<your-org>/nexus-code` with the specifics (never the asset repo) |
| **block** | gate RED, **or** a confirmed contract break you can't mitigate | do NOT bump. Fix the affected `_detect_*` / dialog signature / hook first (capture a fresh fixture), land that, re-gate. Surface the blocker on `<your-org>/nexus-code` (issue or `cc-compat` PR), never the asset repo. |

**Clone freshness is NOT a verdict input** (operator directive,
`<your-org>/nexus-code#1475`, 2026-09-06: *"The update should not depend on
nexus-code being the latest version. If the local cc test pass, it can and
should be updated."*). The gate you decide on is the one run **in the live
clone**, because that clone's classifier is what production runs and that
clone's pin is what moves. `behind_integration=N` in the deployment-gate row
is a fact recorded beside the verdict, never a reason to defer, refuse, or
wait:

- local gate **GREEN** → **safe to bump**, however far behind the
  integration branch the clone is. Do not pull first, do not wait for a pull.
- local gate **RED** → **block**, as the table says, on the local classifier
  — full stop. Record it as `block`; the surfaced comment says, in one plain
  sentence plus one command, that the clone is N commits behind
  `origin/<integration-branch>` so the red may be the checkout's, and names
  the deploy command for THAT SAME ref
  (`git -C <nexus-root> pull --ff-only origin <integration-branch>` — see
  "Evaluator comments" above). It never
  prescribes a checkout on the clone. Which branch that is —
  `monitor.integration_branch`, default `dev` — is an operator configuration
  decision, put to the operator on `#1529` and unanswered; the default is
  left alone. The next daily fire re-gates on whatever the operator deploys.

**The routine never touches remote nexus-code** (operator directive,
`<your-org>/nexus-code#1529`, 2026-09-14: *"the automatic cc-update should
never involve an automatic update of the nexus-code code. This is not
necessary and introduces a great security risk as many people can push to
this resource (especially not from the dev branch!)"*). The gate is run
only against the live clone's own checked-out code. Nothing on the automatic
path — the watcher drive, this evaluator, `apply.sh`, the gate harness, the
restart watchdog — pulls, merges, rebases, resets, checks out, switches,
clones, worktrees or EXECUTES any other nexus-code tree, from any branch.
A read-only `git fetch` that REPORTS "N commits behind" may run: it updates
remote-tracking refs and executes nothing. There is no exception for
authoring: a compat fix is filed as an issue and authored by a separate
worker (Step 0), never from the evaluator's session.
`monitor/watcher/test-cc-update-no-remote-code.sh` reddens if any of those
operations enters the routine's files, shell or prose. **And it is enforced
at runtime** (w241sk F2 measured that until 2026-09-14 it was not: the
evaluator is spawned with permissions bypassed, and no hook arm existed):
`monitor/hooks/bash-footgun-guard.sh`, arm `cc-update-git`, refuses every
`git` invocation from the evaluator and watchdog windows whose verb is not
on a read-only allowlist, or that reads a `<remote-ref>:<path>` blob — deny
is the default arm — so a pull, merge, rebase, reset, checkout, switch,
clone, worktree or `show origin/…:file | bash` exits 2 before the tool
runs. **Which class each layer covers, and what neither does:** the text
guard (`test-cc-update-no-remote-code.sh`) covers the routine's FILES — a
mutating verb, a remote blob read or a foreign-tree run written into the
drive, the prompts, the executor, the harness or this GUIDE; the hook
covers what the evaluator and watchdog windows TYPE into Bash/Monitor,
including the cc-update marker-file scope that fails closed on an
unreadable window name. Both are defence in depth against the routine
DRIFTING into an auto-update. Neither is a sandbox against a determined
agent: a `git` binary reached through a variable, a script written by the
Write tool and then executed, or a python call that spawns `git`, are
outside both, and that residual is stated here rather than claimed closed.

**Previous behaviour, so the change is visible:** until 2026-09-14 this
step invited a further gate run in a throwaway tree at the remote tip, to
tell a checkout's red from a candidate's. In practice
(`#1475`, e.g. comment 5663025742) that meant checking out and RUNNING the
harness and classifier of whatever was last pushed to `dev` — unattended
execution of remote code. That control is RETIRED: a RED blocks on the
local classifier, the operator deploys their configured integration branch
when they choose, and the next fire re-gates. Earlier still (2026-09-06), a local RED with a GREEN
remote control was framed as *"the last blocker is the un-pulled live
clone"* and held the candidate pending a pull — a bump gated on nexus-code
freshness in prose where the code gated on nothing. Both framings are gone.

### Before you report ANY verdict — assert the live tree still equals the pin

**Run this for every verdict, including `block` and `needs-review`, and
run it as the last thing before you write the verdict down:**

```bash
# run from the nexus root. _cc-version.sh is a SOURCED library, not a CLI:
# `monitor/_cc-version.sh effective …` fails rc 126 (mode 0660), and
# `bash monitor/_cc-version.sh effective …` is SILENT (rc 0, empty output)
# — written with a `|| cat <pin-file>` fallback, that silent form makes
# both sides empty and the assertion passes on a drifted tree.
. monitor/_cc-version.sh
eff=$(cc_version_effective "$PWD/package.json" @anthropic-ai/claude-code "$PWD")
live=$(./node_modules/.bin/claude --version 2>/dev/null | awk '{print $1}')
[ -n "$live" ] && [ "$live" = "$eff" ] \
  && echo "live tree OK: $live" \
  || echo "LIVE TREE DRIFT: live='$live' effective-pin='$eff'"
```

A mismatch means the live `node_modules` no longer holds the version the
nexus believes it is running. **Do not report a verdict on a drifted
tree** — restore it first (`monitor/install-claude-local.sh` reinstalls
the effective pin), confirm the restore, and say in your report that the
drift happened and what caused it.

**It is enforced in code as well as here.** `monitor/cc-auto-update-apply.sh`
runs the same comparison — the live binary's `--version` against
`cc_version_effective` — before `safe`, `block` and `compat-pr auto`
record anything, and refuses with **exit 9** on a mismatch or when either
side cannot be read. `safe` records `safe-refused` with a
`live-tree-drift` detail (so the daily `#1400` surfacing names it);
`block` and `compat-pr` record NO verdict (an audit row labelled
`live-tree-drift` only), so the next fire re-evaluates rather than
skipping a candidate whose verdict was never recorded. An exit 9 is a
finding about the TREE, never about the candidate: restore, then re-run
the verb.

**Why this is here and not only in Step 6.** Step 6 verifies a bump you
*intended*; this asserts against drift you did **not** intend, on every
fire, including the fires that change nothing. It is the one control in
this routine that is **cause-agnostic**: it does not care how the live
tree drifted — an ad-hoc `npm install` resolving out of a
`package.json`-less cwd (`<your-org>/nexus-code#1002`), a half-finished
install, a crashed rollback, a hand-edit — it turns all of them loud.
Every other guard in this file prevents one *known* path; this one detects
the outcome. It is also the control the 2026-08-25 incident would have
caught for free: that fire reported its `block` with the drift entirely
undetected (see "Staging a candidate binary" under Step 3).

When a verdict needs surfacing (needs-review you can't clear, or block),
report it with evidence (which scenarios passed, which changelog entries
you cleared) on the configured tracking issue — explicit
`--repo {{TRACKING_REPO}}`, the repo that reference names, which is not
necessarily the surface repo (see "The one exception" above) — and never the
overview (routing-only). A **safe** verdict that you apply needs no issue
at all (see the routing invariant above).

## Step 5 — APPLY the bump (only if Step 4 says so)

> **The autonomous routine applies via `monitor/cc-auto-update-apply.sh
> safe`, which now enforces the evidence-class rule.** `--surfaces-clear`
> alone is refused (exit 3). You must also pass, for every surface:
>
> ```bash
> monitor/cc-auto-update-apply.sh safe \
>     --candidate <candidate> \
>     --gate-evidence <gate log> \
>     --surfaces-clear \
>     --surface-evidence 2a=gate \
>     --surface-evidence 2b=gate \
>     --surface-evidence 2c-paste=empirical \
>     --surface-evidence 2c-vi=gate \
>     --surface-evidence 2d=gate \
>     --surface-evidence 2e=empirical \
>     --negative-control '2c-paste=broke the delivery grep; the probe went red' \
>     --negative-control '2e=removed a required flag from the expected set; the check went red' \
>     --changelog-evidence <the CHANGELOG.md you fetched this session> \
>     --changelog-ledger <one line per entry: verbatim quote + disposition> \
>     --changelog-dispositioned <older release>=<N> \
>     --changelog-dispositioned <candidate>=<N>
> ```
>
> Classes: `gate` (cross-checked against the scenario names in your gate
> log; payable for 2a/2b/**2c-vi**/2d — `2c-vi` since
> `<your-org>/nexus-code#867`, via `test-realmodel-vimode`; `2c-paste` and
> `2e` still have no scenario), `empirical` (**requires** a
> `--negative-control` for that surface), `reachability`,
> `source-inspection`. Surface keys are `2a 2b 2c-paste 2c-vi 2d 2e` —
> the aggregate `2c` is refused, because its two halves have different
> evidence (see the evidence-class rule above).
>
> The changelog flags are the **completeness** rule (Step 1): one
> `--changelog-dispositioned` per release in the delta — the delta being
> what the **registry** publishes in `(installed, candidate]`, not the
> changelog's headers (`<your-org>/nexus-code#1007`) — `N` checked against
> the entry count `apply.sh` derives from the changelog it fetches, and
> every entry required to appear verbatim in the ledger. A published
> release with NO section is refused as opaque (`exit 8`, bounded: after
> `defer_streak_cap` consecutive refusals the operator is escalated and
> the refusal continues); a registry that cannot be read refuses
> (`exit 3`) rather than falling back.
>
> Both accepted attestations are appended to `decisions.tsv` — a
> `surface-evidence` row (per-surface labels plus the derived
> weakest-of-sub-claims label for `2c`) and a `changelog-completeness`
> row (`dispositioned N of M entries across K release(s)`) — so a later
> reviewer can see what was claimed without re-reading the report. Use
> the same labels and the same counts in your report table.

The bump advances the **operator-LOCAL pin**, never the shared
`package.json`. The shared pin is a maintainer-managed vetted FLOOR
(initial-setup only); a successful gated bump writes
`monitor/.state/cc-version-local` (gitignored) and leaves `package.json`
untouched. This **replaces the old "unpushed local `chore: bump` commit"
divergence dance** entirely — there is no commit and no push, so the
working tree stays clean and the operator's
`git pull --ff-only origin <integration-branch>` never conflicts on a
phantom local bump. See `monitor/_cc-version.sh` and
`<your-org>/nexus-code#226`.

```bash
# 1. write the operator-local pin to the candidate. This is the ONLY
#    state the bump advances; the shared package.json floor stays put.
printf '%s\n' "<candidate>" > monitor/.state/cc-version-local
#    (equivalently, source monitor/_cc-version.sh and call
#     cc_version_write_local_pin "<candidate>" "$NEXUS_ROOT" — it writes
#     atomically.)
# 2. sync the local install (live clone). install-claude-local.sh now
#    resolves the EFFECTIVE version (the local pin you just wrote) and,
#    because a local pin is present, installs it explicitly with
#    `npm install --no-save @anthropic-ai/claude-code@<candidate>` — so
#    node_modules advances to the candidate WITHOUT rewriting the shared
#    package.json floor. It still pre-cleans stale
#    @anthropic-ai/.claude-code-* staging dirs, retries once on a
#    transient EBUSY/.nfs failure, never wipes node_modules (a failed
#    install leaves the prior binary standing), and refuses to exit 0
#    unless the binary runs and reports the effective version. If it
#    exits non-zero it prints the exact recovery command.
monitor/install-claude-local.sh
# 3. NO commit, NO push, NO package.json edit. The version lives in
#    gitignored local state; nothing goes to the shared repo. (Floor
#    advances are a SEPARATE, deliberate maintainer PR — see "Floor vs
#    local pin" in the Notes below.)
# 4. restart the watcher so it loads the new binary. This restart IS
#    manual: the version-aware auto-restart (_version_restart.sh) hashes
#    the watcher's SHELL source set, and a cc-pin bump changes only
#    gitignored state + node_modules — no source drift, no auto-fire.
#    The watcher is headless; never `tmux kill-window -t watcher`
#    (main.sh survives the pane as a PPID=1 orphan, issue #106):
monitor/svc.sh restart watcher    # == launcher.sh --replace
# 5. restart the orchestrator itself onto the new binary — Step 5b.
#    The watcher restart only covers FUTURE spawns; the running
#    orchestrator process stays on the OLD binary until replaced.
```

After the local pin reaches `candidate`, the `cc_version_check` task
self-heals: its next fire reads the EFFECTIVE version (now the local pin
== latest) and removes `monitor/.state/cc-update-available`, so the emit
stops surfacing it. (If you want to clear the advisory immediately, just
delete that file and `monitor/.state/cc-update-surfaced`.)

## Step 5b — restart the orchestrator onto the new binary

### Why this step exists

Step 5's watcher restart only changes what gets spawned *from now on*:
workers, respawns, and the watcher's own helpers all resolve
`node_modules/.bin/claude` fresh at spawn time. The orchestrator,
however, is itself a running `claude` process — it keeps executing the
OLD binary until its own process is replaced. Skipping this step leaves
the workspace version-split: every new worker on the candidate, the
agent coordinating them still on the previous pin. For full version
consistency the orchestrator must restart itself onto the new pin as
the FINAL act of the bump.

### The mechanism — kill-last, watcher-resume

The orchestrator does not spawn its own successor; it deletes itself
and lets the watcher's standard absent-target recovery do the rest:

```bash
# Resolve the coordinator window from config — it is NOT always named
# `orchestrator` (nexus-code#459); a hard-coded name kills nothing.
TARGET_WINDOW=$("$NEXUS_ROOT/config/load.sh" monitor.target_window orchestrator)
tmux kill-window -t "$TARGET_WINDOW"    # the orchestrator's own, final act
```

**Do NOT run this yet** — the pre-flight and the restart watchdog
below must both be in place first; the kill is always the last command
of the whole bump.

The tool call never returns — the process dies mid-turn. From there the
watcher's `target_window` probe (2 s cadence) drives the recovery
(`monitor/watcher/_target_absent.sh`):

1. **Absent streak accumulates** past `agent_missing_respawn_delay`
   (default 3, PR #214): the respawn launches on the 4th consecutive
   absent observation, ~8 s of confirmed absence.
2. **Pre-launch re-verification** (`_respawn_verify_target_absent`,
   PR #214) runs at the moment of decision: a fresh window probe, a
   scan of every tmux pane for a live process carrying
   `NEXUS_IS_ORCHESTRATOR=1`, and a check that no liveness signal
   (Stop-hook heartbeat, paste-received stamp, pinned-session jsonl)
   post-dates the streak start. A genuine self-kill passes all three —
   the process is really gone and writes nothing after death — so the
   respawn proceeds; the same gate is what prevents a transient
   misread from ever spawning a duplicate next to a live orchestrator.
3. **The pinned session is resumed** (`respawn_agent` →
   `_respawn_choose_resume_mode`): the session-id pin
   (`monitor/.state/orchestrator-session-id`, written on every
   `UserPromptSubmit` by the pin hook and re-affirmed at every spawn —
   issue #203 / PR #204) names the exact prior session, and the spawn
   uses `claude --resume <pinned-sid>`. **Context is preserved** —
   same conversation, same jsonl, the restart reads as a seam in one
   continuous session.
4. **The binary is resolved fresh at spawn time**:
   `_respawn_orchestrator` sources `monitor/_claude-bin.sh`, which
   points at `$NEXUS_ROOT/node_modules/.bin/claude` — the stable path
   whose *contents* Step 5's `install-claude-local.sh` just replaced.
   Whatever process comes up is therefore necessarily the new pin.
5. **Turn-1 of the resumed session is the watcher's recovery prompt**,
   which asks the orchestrator to validate the respawn (false-positive
   protocol). Having triggered the kill deliberately, the resumed
   orchestrator confirms the call was right and continues routine work.

Ordering matters: trigger this only AFTER the Step 5 watcher restart,
so the watcher process serving the recovery is itself running the
current code.

### Pre-flight — confirm the pin is current (the one real risk)

The seamlessness above rides entirely on the session pin. Check it
BEFORE triggering:

```bash
cat monitor/.state/orchestrator-session-id   # must be YOUR session id
# and its jsonl must exist + be the one you are writing:
ls -l ~/.claude/projects/<project-slug>/<pinned-sid>.jsonl
```

If the pin is ABSENT or STALE, the watcher's degradation (issue #200 /
#203) is a deterministic COLD spawn — `claude --session-id
<fresh-uuid>`, no `--resume`, no `--continue` — i.e. a fresh
orchestrator with **no conversation context**. That is the one real
risk of the self-restart: a stale pin silently converts "seamless
binary swap" into "context lost, re-onboard from scratch". Do not
trigger until the pin is confirmed current, and update your tracking
report first so even the cold-spawn worst case has a resumption
surface.

### The restart watchdog (REQUIRED — a Claude worker carrying agency through the gap)

The orchestrator cannot watch its own restart — and between the kill
and the verified resume, the workspace has **no intelligent agent at
all**. The watcher can only execute its pre-programmed respawn; if
anything deviates (respawn aborted, duplicate window, cold spawn,
watcher death, something nobody enumerated), nothing alive can react.
The watchdog exists to carry agency through that gap.

So BEFORE triggering the self-kill, spawn a **watchdog worker** — a
Claude agent in its own tmux window (via `skills/nexus.tmux-spawn`; it
survives the orchestrator's death) whose mandate is: keep monitoring
and **fixing** until exactly one orchestrator is verifiably running
properly, then stand down.

Two hard rules in the watchdog's prompt, each the fix for an actual
mistake the 2026-06-02 live run's watchdog made:

- **Job-first ordering**: arm → watch → fix → report LAST. Never frame
  the report as the deliverable of a watch task (the 2026-06-02
  watchdog polished its report before arming and needed a nudge to
  start watching).
- **Run the watch loop yourself — deterministic, in your own context,
  no nested subagent**: the agent does not watch by inference, and it
  does not delegate the watching downward either (the 2026-06-02
  watchdog spawned a further subagent for the polling — its own core
  job). It runs the bash watch loop below as a single long-running
  command in its own context and stays out of the way — zero tokens
  burned while the loop runs. Inference engages only when the loop
  exits: success (verify, stand down) or deviation (diagnose, fix,
  re-run the loop).

The kill-last ordering is strict:

```
spawn watchdog worker → it records baseline + starts its watch loop
                      → it writes the armed marker
orchestrator waits for the marker
                      → tmux kill-window -t <monitor.target_window>
```

The watchdog's mandate (the job list for its spawn prompt):

1. **Record the baseline**: candidate version, orchestrator pane pid,
   pinned session id + that jsonl's size, watcher pid (from
   `monitor/.state/watcher.pid` — the watcher is headless, it has no pane).
2. **Start the watch loop, then signal armed** (write
   `monitor/.state/restart-watchdog-armed`). The orchestrator
   self-kills ONLY after seeing the marker.
3. **Let the watch loop verify success**: (a) exactly ONE
   `orchestrator` window, no duplicate / stand-down window (the
   PR #214 false-positive class); (b) a fresh jsonl record — past the
   baseline byte offset — carries `"version":"<candidate>"` (Claude
   Code stamps every record); this single condition proves BOTH a
   context-preserving resume (the jsonl grew with new records, not a
   cold spawn) AND the new binary. It MUST be polled to the deadline,
   not checked one-shot: the dying orchestrator keeps writing
   old-binary records for ~30s after the baseline snapshot, and a
   one-shot grep racing the resume would see only those and spuriously
   fail (the 2026-06-03 cc-2.1.161 false negative). (c) the watcher
   pid still alive — it survived (the 2026-06-02 incident killed
   the watcher during a respawn stand-down).

   **`claude --version` answers a narrower question than it looks.**
   Every invocation EXECS A FRESH PROCESS, so it reports the binary
   **on disk** — never the version a long-running process is actually
   executing. The orchestrator, the watcher and every live worker keep
   running the binary they started with until they restart, so a
   correct-looking `--version` says nothing about whether the restart
   landed. The 2026-08-06 fire records exactly this split and calls it
   normal: `./node_modules/.bin/claude --version` → `2.1.223` while
   *"the orchestrator process alone is still on 2.1.220 — the normal,
   expected tail of a successful bump, not a fault."*

   So order the sources by **what each one answers**, not by trust:

   1. the loop's own jsonl `"version"` record — the ONLY source that
      reports the version a **running** process is executing. This is
      what `cc-restart-watchdog-loop.sh` asserts, and why it "proves
      BOTH a context-preserving resume AND the new binary";
   2. `./node_modules/.bin/claude --version` (or the installed
      `package.json`) — the binary on disk: *did the install land?*;
   3. `monitor/.state/cc-version-local` — the operator-local **pin**
      written by the APPLY step (`monitor/_cc-version.sh`): what has
      been *validated*. Intent, not a probe of what is installed, so
      it can lag a successful install whose apply step did not finish.

   **On PATH — bare `claude` is correct on a correctly-installed
   nexus**, and distrusting it sends you looking in the wrong place.
   `locals/bin/claude` has been a stable indirection to the
   project-local install since `7364f9a` (2026-06-18, `#307`), and
   `monitor/install-shell-hook.sh` exists to keep `locals/bin` on
   `PATH`. Measured on this operator's host: exactly ONE `claude`
   binary exists; `whence -p claude` → `locals/bin/claude` →
   `node_modules/.bin/claude`, identical under login, interactive and
   non-interactive shells; and no user-level install is present at any
   standard location (`~/.local/bin`, `~/.claude/local`, `~/bin`,
   `/usr/local/bin`, `/app/bin`, npm-global). If `whence -p claude`
   does NOT land in `locals/bin`, **that is itself the finding** —
   `locals/bin` has lost the front of `PATH`, the same race documented
   for the `gh` wrapper (`#578`) — rather than a reason to abandon
   `--version`.
4. **On loop success**: `sandbox-notify` a one-liner, remove the armed
   marker, write the report (`ng report-init`), stand down.
5. **On loop failure**: diagnose, FIX, and re-run the loop — do not
   just notify and quit. The known playbook:
   - *no respawn by the deadline* — read `monitor/.state/watcher.log`
     (re-verify abort? crash-loop / slow-grind tripped?); address the
     cause, or run `monitor/watcher/spawn-fresh-orchestrator.sh`.
   - *watcher died* — relaunch it immediately
     (`monitor/watcher/launcher.sh` — `--target` defaults to config
     `monitor.target_window`; never hard-code it, and never hand it an
     unset variable: an empty `--target` is refused, exit 2); the
     workspace must never sit unmonitored.
   - *duplicate orchestrator windows* — execute the stand-down
     protocol from the watcher's recovery prompt against the
     duplicate; NEVER kill the watcher.
   - *cold spawn (pin was stale or wrong)* — if the prior session's
     jsonl still exists on disk, the context is recoverable: re-pin
     the correct sid, kill the cold window, and let the watcher
     respawn it as a `--resume` (or run
     `spawn-fresh-orchestrator.sh`). If the jsonl is truly gone,
     brief the cold orchestrator instead: paste it pointers to the
     latest `reports/`, the tracking issue, and the fact that it was
     cold-spawned mid-bump.
   - *anything unenumerated* — fix it if confident; otherwise
     `sandbox-notify` LOUDLY with findings and hold the workspace
     stable until the operator responds.
6. **Never exit leaving the workspace agent-less** without a loud
   notification. Report LAST, then stand down.

The deterministic watch loop the watchdog runs is **shipped as a repo
file** — `monitor/cc-restart-watchdog-loop.sh`. Run it, do not re-adapt
an inline copy: a hand-adapted listing is exactly how the hard-coded
`orchestrator` window name in `<your-org>/nexus-code#459` survived, and how
a stale `tmux list-panes -t watcher` baseline outlives the watcher going
headless. The loop resolves the coordinator window itself (config
`monitor.target_window`), reads the watcher pid from
`monitor/.state/watcher.pid`, and logs to
`monitor/.state/restart-watchdog.log`:

```bash
NEXUS_ROOT=/abs/path/to/nexus WATCHDOG_DEADLINE_SECONDS=180 \
    /abs/path/to/nexus/monitor/cc-restart-watchdog-loop.sh
```

It records the baseline, writes the armed marker itself, waits for the
old pane to die and the respawn to appear, then verifies: exactly ONE
coordinator window, no stand-down window, the watcher pid alive, the
session pin unchanged, and a FRESH jsonl record (past the baseline byte
offset) stamped `"version":"<candidate>"` — polled to the deadline,
never one-shot (the dying orchestrator keeps writing old-binary records
for ~30 s; the 2026-06-03 cc-2.1.161 false negative). Exit 0 = verified
(armed marker removed); exit 1 = failure (failure marker written).

When the autonomous routine drives the bump, `cc-auto-update-apply.sh`
renders the loop invocation into the watchdog's spawn prompt with
`CC_AUTO_TARGET_WINDOW` already resolved, so the agent never re-derives
it.

Why not just this script, detached, with no agent around it? A script
can detect and notify, but it cannot react: every failure path above
would end with the operator doing the fixing while the workspace sits
agent-less. The watchdog worker closes that loop — the script is its
inner mechanism, not a substitute for it.

## Step 6 — verify

- `./node_modules/.bin/claude --version` reports the candidate.
- The restarted watcher's startup emit lands in the orchestrator pane
  (proves spawn + paste + hooks survived the bump).
- Worker panes classify correctly: `monitor/pane-state.sh <window-index>`.
- No `--- claude code update available ---` section recurs for this
  version.
- After the Step 5b self-restart: exactly ONE `orchestrator` window
  exists; the watcher window is alive; the resumed orchestrator
  reports the candidate version (fresh records in the pinned session's
  jsonl carry `"version":"<candidate>"`); and the conversation context
  survived — the resumed orchestrator recalls its pre-restart state
  (it remembers triggering the kill). The restart watchdog's report
  and its watch-loop log (`monitor/.state/restart-watchdog.log`) are
  the evidence trail for all four.

## Notes

- **Floor vs local pin (the version model, nexus-code#226):** the shared
  `package.json` `@anthropic-ai/claude-code` value is a
  **maintainer-managed vetted FLOOR**, used for INITIAL SETUP only (fresh
  install / fresh clone with no local pin). The maintainer advances it
  deliberately — based on what has run stably on their end for **≥1 day**,
  **bundled** with other updates — so it lags the bleeding edge by design
  and does NOT track each ~daily release. Your gated bump (Step 5)
  advances only the **operator-local pin**
  (`monitor/.state/cc-version-local`, gitignored); it never touches the
  floor. The maintainer raising the floor is a **separate, deliberate
  PR** on `<your-org>/nexus-code`, out of scope for this routine.
  `monitor/_cc-version.sh` is the single resolver
  (`effective = local-pin else floor`); both `install-claude-local.sh`
  and the watcher gate baseline read it.
- **This guide binds a fire only via the PRIMARY CLONE — and that is two
  steps, not one.** The watcher renders the evaluator prompt from
  `$NEXUS_ROOT/monitor/cc-auto-update-prompt.md` and resolves `{{GUIDE}}`
  from `MONITOR_CC_UPDATE_SKILL_PATH` (default
  `skills/nexus.cc-update/GUIDE.md`) against the evaluator's cwd, which is
  `$NEXUS_ROOT`. So a change merged to `dev` reaches the daily fire only
  after (1) it is on the branch the primary clone tracks **and** (2) the
  operator's `git pull --ff-only origin <integration-branch>` in that clone
  (the branch is `monitor.integration_branch`; whether its default should be
  `dev` or `main` is the operator's open decision on
  `<your-org>/nexus-code#1529`). A merge alone changes nothing on the
  running host — the clone is what the fire reads. While either step is
  outstanding, the routine runs the OLD guide and the OLD prompt, and
  nothing warns about it: neither file carries a version or freshness
  check, so the divergence is invisible from inside a fire.

  **Do not paper over that with the overrides — they are a trap, because
  they are per-half.** `monitor.cc_update.skill_path` is config-backed
  (`monitor/watcher/_config.sh`, `config/nexus.example.yml`) so the GUIDE
  half can be repointed at a local copy; the prompt template has **no
  config key at all**, only the env var `CC_AUTO_PROMPT_TEMPLATE` read in
  `monitor/watcher/_cc_auto_update.sh`. The two halves are therefore
  overridden by different mechanisms, and repointing one without the
  other gives you rules without the queue, or the queue without the rules
  — strictly worse than the lag you were trying to avoid, and silently so.
  If the lag genuinely must be closed early, the clean route is a narrow
  backport of the two documentation files to the tracked branch: no code
  depends on them, so it carries none of a full promotion's risk.
- **Tier:** `<your-org>/nexus-code` is INTERNAL — bot identity for GitHub
  writes, no per-action approval; PR `--base dev`.
- **Idempotency / re-nag:** the watcher surfaces a given candidate
  exactly once (guarded by `monitor/.state/cc-update-surfaced`). If you
  evaluate-and-defer, the signal persists in `cc-update-available` for
  `cat`; a *newer* candidate re-arms the emit.
- **Autonomous daily routine (code default off, shipped template on —
  <your-org>/nexus-code#1476):** with
  `monitor.cc_auto_update.enabled: true` the watcher runs this whole
  guide UNATTENDED once a day (`monitor/watcher/_cc_auto_update.sh`
  spawns the evaluator; `monitor/cc-auto-update-apply.sh` executes the
  decision — Step 5 + 5b on a provably-safe verdict, a held `cc-compat`
  PR when nexus-code needs a change, block otherwise). When the emit
  carries the "autonomous routine is ENABLED" note, do NOT also spawn a
  manual evaluator; check
  `monitor/.state/cc-auto-update/decisions.tsv` instead.
- **Deployment gate (nexus-code#512):** the gate above vets the BINARY;
  `apply.sh safe` additionally vets the ACT of deploying it, before any
  state mutation: it defers (exit 30, nothing applied, retried at the
  next daily fire) while an open nexus-code PR touches the watcher
  restart path or while an open PR is under active review (the
  live-window arms — `max_live_windows` and board-quiet — were removed
  2026-09-12 by operator decision; the window count is recorded in
  every apply record, not gated on), records clone staleness in every
  apply record as
  `behind_integration=<n|unknown> integration_branch=<b>
  drift=<up-to-date|behind|unknown>` — measured against the branch
  merged fixes land on, config `monitor.integration_branch` (`#763`;
  the deprecated `monitor.clone_drift.branch` is still read until
  **2026-11-07**), NOT
  `main` (`#754`); the pre-`#754` field was `behind_main=N` and
  under-reported, so old rows are not comparable — and verifies the
  post-restart invariant (0 old-group
  survivors, exactly one watcher group; violation = exit 31, no
  Step 5b). A deferral is a complete result **when it names a hazard**;
  a deferral produced by the gate's own blindness is not — see "What is
  REVERSIBLE and what is NOT" above (`<your-org>/nexus-code#1492`).
- **Holding a restart (nexus-code#513):** to stop a pending or in-flight
  orchestrator restart, write the durable hold —
  `monitor/cc-auto-update-apply.sh hold --reason "…" [--until-version
  X.Y.Z | --ttl-seconds N]` (release: `unhold`; inspect:
  `hold-status`). The running watcher's reconcile honours it every
  tick, and a SIGTERM'd detached restart writes it automatically.
  Flipping `monitor.cc_auto_update.enabled` is NOT a hold — it is read
  once at watcher startup and is inert on a running watcher.
- **Disable detection:** `monitor.cc_update.interval_seconds: 0` in
  `config/nexus.yml` (or `MONITOR_CC_UPDATE_INTERVAL_SECONDS=0`).
- **Fail-safe:** registry-unreachable never blocks the watcher and never
  clears a pending signal — see `_cc_update.sh`.
