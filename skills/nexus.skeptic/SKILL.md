---
description: "The universal skeptic protocol for the nexus: independently and adversarially validate a worker's result to the highest scientific standards. Three spawn modes (require|auto|deny), wrap-up enforcement, the worker↔skeptic comms channel + nudge, and bounded recursion. Use when spawning a skeptic, deciding at wrap-up whether one is warranted, or acting AS a skeptic."
---

# nexus.skeptic — adversarial validation to the highest scientific standards

A worker produces a result. Before that result propagates — into a
merge, a figure, a gene list, a downstream analysis, an external write —
an **independent skeptic** tries to break it. The skeptic does not trust
the worker's narration; it re-derives, reproduces on known-answer cases,
traces assumptions to their root, and separates what is *proven* from
what is merely *asserted*. Only findings that survive the skeptic's
adversarial pass are trusted.

This is the nexus's scientific-rigor posture made executable. It exists
because an unreviewed wrong result is far more expensive than a skeptic
pass — the canonical motivating case is a labels-vs-membership confusion
caught in a prior figure review, which had produced a plausible-but-wrong
gene list: exactly the class of error a skeptic catches and a self-review
misses.

**Lineage.** The methodology is adapted from two sources, cited where
their ideas appear below:

- **`<yourlab>.ms-audit`** (<your-lab> manuscript audit) — its *skeptic
  confirmation pass*: route every non-trivial finding to a fresh agent
  in a separate context to refute it before reporting. "Trust nothing.
  Read both sides." The bug-first checklist and the verdict ladder are
  lifted from its sibling `<yourlab>.conclusion-skeptic`.
- **`matsen/bipartite`** (Erick Matsen, MIT, public; HEAD `8888fe5`,
  2026-06-10) — the *bipartite* model: two coupled sides (generation and
  verification) with a dedicated `surprising-conclusion-skeptic` agent
  that "interrogates strong or negative claims before they propagate,"
  emitting a three-state verdict that *blocks downstream work* rather
  than a pass/fail. See
  `https://github.com/matsen/bipartite/blob/main/agents/surprising-conclusion-skeptic.md`.
  (Structure verified via the GitHub API; methodology paraphrased, not
  quoted verbatim — pull the raw file at the pinned commit to quote.)

---

## The three spawn modes

Every worker is spawned with a skeptic mode (`spawn-worker.sh --skeptic
<mode>`, default `auto`). The mode is stamped into the worker's
provenance record (`monitor/.state/windows/<window>.json`) and read back
by `ng wrap-up`.

**An ordinary worker is NOT told at spawn that a skeptic may follow.**
The mode lives only in the machine-readable provenance record, never in
the worker's prompt — the `## Worker environment` header carries no
skeptic line and the worker floor says nothing about being checked. The
worker does its work *unaware* of a possible subsequent skeptic and
learns of the decision/gate **only at wrap-up**, when `ng wrap-up` reads
the mode authoritatively from provenance and prints the consequences +
the await-loop mechanics. This keeps the work honest: a worker cannot
tailor its narration to a reviewer it does not know exists. (A
`--skeptic-role` spawn is the sole exception — being a skeptic IS its
task, so its prompt and header say so. The rule bars pre-warning the
*original* worker of a *future* skeptic; it never hides a skeptic's own
role.)

| Mode | Meaning | Wrap-up behaviour |
|---|---|---|
| `require` | A skeptic **must** validate this result. | Emits **SKEPTIC REQUIRED**, sets a `skeptic-pending` marker, logs `skeptic-request`. The marker is a **hard gate**: `retire-preflight.sh` (the mandatory pre-kill check) returns no-go while it is live, so the window **cannot be retired** until a skeptic returns a verdict (which clears it) — the task is genuinely not *done* until then. A worker cannot waive it: `--skeptic-decision deny` is refused, and `--skeptic-waive` is refused from a worker context (operator-scoped). The waive is loudly audited (`skeptic-decision decision=waived`); it is a discipline-and-audit control scoped to the operator session, not a cryptographic boundary. |
| `auto` | No specification at spawn — **the worker decides** at wrap-up. | Presents the responsible-default heuristic and requires the worker to record a decision (`--skeptic-decision require\|deny --skeptic-rationale "<why>"`). Enforced by default (`enforce_auto_decision: true`): wrap-up *fails* until a decision + rationale is recorded. |
| `deny` | No skeptic (trivial / low-impact / disabled at spawn). | Proceeds; records "skeptic explicitly denied at spawn." A worker may still *escalate* deny→require if it discovers the work was riskier than the spawn assumed (recorded). |

The orchestrator picks the mode at spawn time. When in doubt, leave it
unspecified (`auto`) and trust the worker's wrap-up decision — that is
the design's default and its point.

**Enforcement runs BEFORE the GitHub hand-off.** `ng wrap-up` evaluates
the skeptic step *first* — before it uploads the report, posts the link
comment, or rockets the trigger. So a wrap-up the gate refuses (an
undecided `auto` worker under `enforce_auto_decision`, a `require` worker
trying `--skeptic-decision deny`, a worker-context waive) returns early
and announces **nothing** externally, and a retry does **not** double-post.
This is why the undecided-`auto` block needs no pending marker of its
own: under enforcement the wrap-up simply *cannot complete* — there is no
external "done", and with no `wrap-up` action-log event the window has no
completed hand-off for cleanup to act on. The marker is the gate for a
*decided*-`require` result (wrap-up completes, but a skeptic must still
validate); the undecided state is gated by the wrap-up failure itself.
With `enforce_auto_decision` off (advisory), an undecided wrap-up records
`auto-undecided` and proceeds — the documented escape hatch.

### The responsible default (the `auto` heuristic)

This is the single source of truth for the decision; `ng wrap-up` prints
it and `skills/nexus.report` references it. **Spawn a skeptic when the
task:**

- **(a)** touched shared infrastructure (watcher / monitor / skills /
  spawn / CI), **or**
- **(b)** produced or altered scientific results, figures, gene lists,
  data, or analysis, **or**
- **(c)** made or proposed external (cross-repo / public) writes, **or**
- **(d)** involved non-trivial reasoning you are uncertain about, **or**
- **(e)** has high blast radius / is hard to reverse.

**Skip only** genuinely trivial, low-impact, easily-reversible,
high-confidence work (a doc typo, a one-line config). **Bias toward
skepticism** — the asymmetry is stark: a skeptic pass costs tokens and a
window; an unreviewed wrong scientific or infra result costs far more,
sometimes silently and much later.

---

## The skeptic's mandate

When you are spawned AS a skeptic (`--skeptic-role --skeptic-target
<window>`), your job is to **independently and adversarially validate the
reviewed worker's result to the highest scientific standards.** You are
not a co-author, not a cheerleader, and not a general code reviewer.

Read the reviewed worker's report, its diff/PR, its commits, and the
artifacts it produced — **cold, from files, not from its self-narration**
(`matsen/bipartite`'s `issue-lead` reads state directly from commits and
logs; trust the artifact, not the story). Then work the **bug-first
checklist**, in order, stopping at the first concrete concern (don't
enumerate theoretical worries when a real one exists):

1. **Is there a bug?** Reproduce the result on a trivial, known-answer
   case. Are the inputs what you think (stale data, swapped args,
   off-by-one, unit/log-vs-linear confusion, `obs_names` vs `var_names`,
   labels vs membership)? Did a recent change break it (`git blame` the
   critical path)? Are errors being silently swallowed?
2. **Is the comparison fair?** Does the scoring/validation treat both
   sides identically? Same params, seeds, preprocessing? Is one side
   getting oracle info or leaked labels?
3. **Is the effect size plausible?** 0% / 100% rates, all-or-nothing
   significance, many-orders-of-magnitude gaps almost always mean
   something *mechanical* (a threshold / denominator / sign /
   normalization bug), not a discovery. Compare against known baselines.
4. **Does it contradict established results?** If a well-validated
   reference disagrees, the burden is on this result to explain why with
   specifics.
5. **Trace assumptions to the root.** *(The most important and most
   skipped step.)* List every upstream result this depends on; confirm
   each was independently validated; **draw the dependency graph
   literally** ("this assumes X from PR #N, which assumes Y from #M…").
   One flawed loader / scoring fn / param map invalidates the whole
   chain.
6. **What's the simplest explanation?** Occam aggressively: "the scoring
   function is broken" beats "the entire approach is fundamentally
   limited"; "the spec has a typo" beats "the code is deeply wrong" when
   the code matches a textbook form.

When the worker produced or moved **scientific output**, run this checklist
with **"Verify the artifact, not the signal"** (below) held in mind — most
result corruptions hide behind a non-failing signal, and that section is
the posture that surfaces them.

**Scrutiny proportional to blast radius.** A result that would trigger
six months of follow-up, a merge to `dev`, or an external publication
deserves adversarial reproduction. A cosmetic change gets a glance. Spend
your verification budget where being wrong is expensive.

**Evidence discipline = citation discipline.** Every concern and every
resolution cites the exact artifact you *read* — `file:line`, a log
line, a commit SHA — never "around line 200ish," never a grep excerpt
standing in for reading the code. A claim without a citation is not a
finding.

**Default to PASS.** Most results are correct. A skeptic that flags
everything is as useless as one that flags nothing — a mostly-negative
report usually means the *skeptic* is misreading. But you are explicitly
empowered to overturn the worker (the `refuted` verdict): the spec /
instruction can be what's wrong, not only the work.

### The verdict ladder

Emit exactly one verdict (the `ms-audit` / `bipartite` ladder, mapped to
the wrap-up's `--skeptic-verdict`):

| Verdict | Meaning | Downstream |
|---|---|---|
| `credible` | No surviving concern. The result holds. | Proceed. |
| `check` | Keep, but specific concerns must be resolved first. | Pause; resolve before building on it. |
| `suspect` | Strong reason to doubt; do not build on it. | Stop. Triggers a second pass. |
| `refuted` | The worker's result (or the spec it followed) is wrong. | The finding is overturned; route the correction. Triggers a second pass. |

---

## Verify the artifact, not the signal

The bug-first checklist tells you *how* to interrogate. This is the single
posture that catches the most dangerous failure family in nexus science:
the run completes, CI is green, the heartbeat is fresh — **and the output
is still wrong, incomplete, or non-reproducible.** Every result-corrupting
incident on record shares this shape: a non-failing signal was mistaken
for a correct result.

**The governing judgment:** *a clean run, a green gate, and a fresh
heartbeat are not evidence of a correct result.* Absence of a crash is not
proof of correct output; a fresh heartbeat is not health; green CI is not
correctness — and a QA gate that short-circuits to green proves nothing at
all. So never sign off on a signal. **Verify the produced artifact itself,
against data, code, and domain expectation,** separating *proven-correct*
from *merely-didn't-crash*. Concretely, on any worker that produced or
moved scientific output, demand evidence for each of:

- **Existence & shape.** Inventory the actual output, don't take its word
  for it — shapes, NaN/zero/constant fractions, and **presence of every
  field downstream expects** (embeddings, coordinates, layers, metadata
  that an ingest or round-trip can silently drop). A served object missing
  a field, an all-NaN layer, records dropped mid-pipeline — these pass
  with no alarm.
- **Magnitude & sign.** Sanity-check the numbers against domain
  expectation. A units / scale / coordinate / normalization error yields
  plausible-*looking* output that only a magnitude or plausibility check
  (dynamic range, expected sign, order-of-magnitude vs a known reference)
  exposes. "It ran" says nothing about scale.
- **The right statistic, reproducibly.** Is the **replicate unit** the
  sample/section, not the pooled sub-unit (pooling inflates `n` → a
  meaningless p-value and no across-replicate CI)? Does the **plotted /
  reported** statistic match the one the verdict actually cites? Is the
  environment **pinned and provenance recorded** (so an env-sensitive
  threshold doesn't move on rerun)? Multi-seed, or a single run dressed as
  robust? Was a method/transform choice that flips a real fraction of
  calls **validated against a baseline**, or just asserted?
- **Delivery.** Did the result land where downstream expects it, or did a
  **silent fallback** stage it somewhere unreachable (scratch, a read-only
  mount)? "The run succeeded" and "the result is where it's needed" are
  different claims.
- **Conduct, even when the result is right.** Flag a broad-glob `rm` over a
  shared path (especially with errors silenced), internal identifiers
  leaking into an external-public artifact, or a write under the wrong
  identity — hazards in *how* the work was done, independent of whether the
  output is correct.

These are illustrations of one rule, not a closed checklist: when a result
is reported "done," ask *what evidence proves the output is correct* — and
if the only evidence is that nothing failed, you have not yet verified it.
Where a producer could have headed the failure off (a data inventory on
ingest, accumulated gate exit codes, pinned versions, a writability probe,
named-path deletes), **flag the absence of that guard** as a finding.

**Proportionality still applies.** Spend the verification budget where
being wrong is expensive — a merge, a figure, a gene list, an external
write, a multi-day run. A cosmetic change gets a glance. But when
scientific output is in play, *absence of a probe is not absence of the
failure.*

---

## The worker↔skeptic communication channel

A per-task shared directory (`monitor/.state/skeptic/<task-id>/`, where
`<task-id>` is the reviewed worker's window name) carries the back-and-
forth. The engine is `monitor/skeptic-channel.sh` (also reachable as `ng
skeptic <sub>`). **The rename is the signal** — mirroring the operator's
"edit and change the name" design.

The **primary** wake mechanism is a **worker-run blocking await loop**,
not a hook. (The old `PostToolUse` autodetect hook only fired while the
worker was *issuing tool calls* — but a worker is effectively DONE, idle
with no tool calls, exactly when a skeptic begins probing its finished
result, so in the common case the hook never fired. It is removed; the
loop replaces it.) At wrap-up a reviewed worker enters `await` instead of
going idle, and stays parked there for the duration of the review.

```
 skeptic                          channel dir                       worker
 ───────                          ───────────                       ──────
 ask ───────────────▶  req-001-why-lr.open.md ◀──── await (blocking poll loop)
                                      │                ACKS by renaming
                                      ▼                .open.md → .ack.md, exits 0
                          req-001-why-lr.ack.md  ─────────────────────▶
                                      │             worker reads, appends reply,
                                      ▼             RENAMES .ack.md → .answered.md,
 await-answer ◀──── req-001-why-lr.answered.md ◀──── answer   then RE-ENTERS await
 (reads the answer, continues)
        ⋯ at the skeptic's wrap ⋯
 reconcile ─ ensures every filed request is past .open.md (nudges stragglers)
 close ─────────────▶  DONE  ──────────────────────▶  await sees DONE → exit 10
                                                      worker stops looping, retires
```

**State machine (per request):** `open ──ack──▶ ack ──answer──▶
answered` (a worker may also answer a still-`.open.md` directly, which
implicitly acks). **Channel sentinel:** `close` drops a `DONE` file; the
worker's `await` detects it and exits **10**.

**Race-safety.** Every state-producing write — `ask`, `answer`, `close`
— builds into a temp file in the channel dir and `mv -f`s it into the
terminal name (an atomic rename on one filesystem), so a reader never
observes a half-written request. The ack (`open`→`ack`) is itself the
atomic rename, so a request is acked exactly once even under a racing
poll.

### Verbs (both forms are equivalent)

```bash
# Skeptic asks a question (atomically publishes req-NNN-<slug>.open.md):
monitor/skeptic-channel.sh ask <task> <slug> --message "Why lr=1e-4 when the spec says 5e-5?"
ng skeptic ask <task> <slug> --file question.md          # or pipe via -

# WORKER blocks until a request lands, acks it (→ .ack.md), exits:
ng skeptic await <task>           # exit 0 acked; exit 10 DONE; exit 4 timeout (re-enter)

# Worker answers (appends reply, renames .ack.md → .answered.md — the signal):
ng skeptic answer <task> 1 --message "Confirmed config drift; fixed to 5e-5."

# Skeptic blocks until a specific answer lands:
ng skeptic await-answer <task> 1 --timeout 600 --interval 5

# Skeptic, at its wrap: ensure every request it filed got acked/answered:
ng skeptic reconcile <task>       # nudges stragglers; exit 6 if a worker never acks

# Skeptic, when done: close the channel so the worker can retire:
ng skeptic close <task>           # drops the DONE sentinel

# Status / list:
ng skeptic status <task>      # open=N ack=A answered=M total=T done=0|1
ng skeptic list <task>        # human-readable table
```

`<req>` accepts a bare number (`1` / `003`), the stem (`req-003-foo`),
or a full filename in any state. One answer per request; ask a follow-up
with a new slug.

**Worker exit-code contract for `await`** (the loop the floor directs you
into): **0** — it acked open request(s) (now `*.ack.md`); read each,
`answer` them, then RE-ENTER await. **4** — timed out with nothing
pending; RE-ENTER await. **10** — `DONE` sentinel; the skeptic closed the
channel, stop looping and retire. **2** — bad task/channel. While parked
in `await` the loop refreshes the worker's skeptic-pending marker mtime
every poll — that heartbeat is what the watcher reads to classify the
worker `parked-awaiting-skeptic` (below).

### Reconcile — the skeptic's wrap-time ack check

At its own wrap the skeptic runs `reconcile <task>`: it waits a beat,
checks every request it filed has progressed past `.open.md` (acked or
answered), **nudges** any still-`.open.md` past a grace period (reusing
the fixed name→index nudge guard below), and returns when all are
acked/answered — so it can spawn the next-depth skeptic or finish. It is
**bounded**: after `--max-iter` iterations (default 20 × 15 s) with a
request still un-acked it **fails loud (exit 6)**, listing the un-acked
requests, so an orphaned worker can never hang the skeptic forever —
report it as a finding rather than blocking on it.

### Nudge — waking a worker that stopped re-entering await

If a worker goes idle without re-entering `await`, `reconcile` (or you,
directly) wakes it:

```bash
ng skeptic nudge <worker-window> [--task <id>] [--force] [--min-interval S]
```

This **reuses `monitor/paste-followup.sh`** — the only correct way to
inject input into a worker pane. A raw `tmux send-keys` would land
unstamped and the watcher would misattribute it to the operator,
muting the worker's stall-nag for up to a day (see the paste-followup.sh
header). The nudge:

- **skips a busy / user-typing pane** (resolved via `pane-state.sh`): a
  busy worker will re-enter await on its own turn; a typing pane belongs
  to the operator. Never steamroll either. The worker window **name** is
  resolved to its tmux **index** before the probe (`pane-state.sh` is
  index-keyed); if the index can't be resolved the nudge **fails safe
  and skips** rather than pasting into a pane whose state is unknowable.
  `--force` overrides.
- **rate-limits** per window (default 120 s) so a flapping skeptic can't
  spam the pane. `--force` overrides.
- **no-ops** when there are no open requests.

**Failure modes to know:** the nudge needs the worker window to exist in
tmux (`exit 3` if absent — the worker may have been closed; recreate via
`spawn-worker.sh --resume` or re-ask after it's back). The
autosuggest-ghost-text hazard and window-resolution pitfalls are handled
inside paste-followup.sh's VI-safe sequence; do not hand-roll around it.

### Parked-awaiting-skeptic — the watcher exemption

A worker parked in `await` is legitimately waiting, not idle and not
hung. Two facts make this safe:

- **It reads `busy`.** A worker blocked in the `await` Bash call shows
  the running-tool spinner, so `pane-state.sh` reports `busy` and the
  idle detector skips it.
- **The watcher exempts it explicitly.** Each `await` poll refreshes the
  worker's `skeptic-pending` marker mtime. The watcher's idle probe
  (`_idle_probe.sh`) treats a worker with a **live** marker (exists AND
  refreshed within `monitor.skeptic.await_hang_seconds`, default 600 s)
  as **`parked-awaiting-skeptic`**: exempt from `idle-too-long` and
  `no-wrap-up` flagging, and surfaced as its own informational row in the
  workspace snapshot so the orchestrator can see parked workers. A marker
  gone **stale** (the `await` died, or the worker never entered the loop)
  lapses the exemption, so a genuine hang resurfaces through normal idle
  classification — that mtime boundary is the hang-vs-wait threshold.

This reuses the **existing** pending marker (the same one `ng wrap-up`
writes for a `require` gate and `retire-preflight.sh` blocks a close on)
— no new pane-state taxonomy. **Scope note:** the watcher auto-respawns
only the orchestrator; worker windows are never auto-respawned on
staleness — they are flagged, and the orchestrator acts. So this
idle-flag exemption plus the retire-preflight marker gate is the complete
worker-side hardening; there is no separate worker staleness-respawn path.

`parked-awaiting-skeptic` is a first-class node in the worker-lifecycle
state machine — see the graph and classifications table in
[`docs/reference/worker-states.md`](../../docs/reference/worker-states.md)
(transitions: `wrapped` → `parked_skeptic` on a `require` wrap-up →
`retired_task` once a verdict clears the marker) and the orchestrator's
do-not-close handling in [`skills/nexus.window-cleanup`](../nexus.window-cleanup/SKILL.md).

---

## Recursion — the skeptic faces the same decision

The skeptic wraps up via the same `ng wrap-up` path and faces the same
require/auto/deny logic. A **second-pass skeptic** is warranted when the
prior pass found **substantive new issues** — a `suspect` or `refuted`
verdict, or `--skeptic-findings` at or above the threshold
(`monitor.skeptic.findings_threshold`, default 1; **floored at 1** — a
threshold of 0 would let a clean 0-findings pass recommend itself
forever, so the engine clamps it up).

**A `check` verdict is not, by itself, "substantive."** Only `suspect`
and `refuted` auto-trigger a second pass. A `check` skeptic that wants
its concerns to drive recursion must record them as `--skeptic-findings
>= 1`; with `check` + `findings=0` the chain **terminates** (the worker
is expected to resolve the named concerns, not spawn another skeptic).
This is deliberate: `check` means "keep, but fix these specific things
first," which is a worker fix-pass, not necessarily another full
adversarial pass.

**Bounded — the termination guarantee:** depth is a counter
(`--skeptic-depth`, starting 0; a skeptic reviewing depth-N work is
spawned at depth N+1). It strictly increments each pass and is capped at
`monitor.skeptic.max_depth` (default **3**). So a skeptic chain runs at
most `max_depth + 1` passes, period — there is no path to an infinite
chain. The **diminishing-returns rule** narrows it further: a second
pass fires only on substantive *new* issues, so a clean pass ends the
chain immediately.

- **substantive new issues AND depth < cap** → wrap-up emits
  **SECOND-PASS SKEPTIC RECOMMENDED** with the spawn command at depth+1,
  and sets a pending marker on the skeptic's own window.
- **substantive issues AT the cap** → wrap-up emits **MAX SKEPTIC DEPTH
  REACHED** and logs `skeptic-escalate`. Do **not** spawn another;
  persistent issues at the cap are a signal for **operator judgement**,
  not more automated passes.
- **clean / no new issues** → the chain terminates.

### The recursive skeptic sees the WHOLE chain — and breaks ties

A second-or-later skeptic is **not** there merely to grade the prior
skeptic. It validates the **entire chain**: **(a)** the original
worker's deliverable + report **and** **(b)** the prior skeptic's
critique. Both are read cold, from files. The chain root travels forward
as `--skeptic-orig <original-worker-window>`: the first skeptic's target
*is* the original deliverable (so `orig` defaults to `--skeptic-target`),
and `ng wrap-up`'s recursive spawn command threads `--skeptic-orig`
forward so every later pass still points at the true original. `ng wrap-up`
emits the spawn command pre-filled with both windows and the
whole-chain / tie-break briefing.

**It may question BOTH parties.** The comms channel is per-window, so a
recursive skeptic opens a channel to **each**:
`ng skeptic ask <original-worker> …` and `ng skeptic ask <prior-skeptic> …`.
Both are kept **parked-and-reachable** for it: when a pass recommends a
second pass, `ng wrap-up` keeps the original worker's `skeptic-pending`
marker **live** (it does not lapse mid-chain) and directs the prior
skeptic to enter `await` on its own window — so the next skeptic can
interrogate either. (If a party has nonetheless already retired, the
recursive skeptic proceeds from the artifact and notes it could not
reach them — graceful, not blocking.)

**It adjudicates disagreements — it breaks the tie in an "argument."**
When the original worker and the prior skeptic disagree on a point, the
recursive skeptic's job is to **resolve it with a reasoned verdict** —
*worker-right* / *skeptic-right* / *both-wrong* / *needs-more* — citing
the exact evidence (`file:line`, a log line, a commit SHA) that settles
it. It is the adjudicator of the chain, not a third opinion stacked on
the pile. This adjudication does **not** lift the depth cap: the chain is
still bounded at `max_depth + 1`; at the cap, persistent disagreement
escalates to **operator judgement**.

**Channel-close discipline across the chain.** Only the **final** skeptic
(the one whose verdict terminates the chain) closes the original worker's
channel (`ng skeptic close <original-worker>`), releasing it to retire. A
skeptic that recommends a further pass must **leave the original worker's
channel open** — closing it early would retire the worker before the next
skeptic can question it. At chain termination (`credible`/no-new-issues,
or escalation at the cap), `ng wrap-up` clears the original worker's
marker for you; each skeptic still `close`s every channel **it** opened.

---

## How a skeptic wraps up

Finish your validation, file your report (`ng report-init
<orig>-skeptic` → the five sections, plus your verdict and the evidence
that backs it), then:

```bash
ng wrap-up <issue> <report-path> --repo <owner>/<repo> \
    --skeptic-role \
    --skeptic-target <reviewed-window> \
    --skeptic-verdict <credible|check|suspect|refuted> \
    --skeptic-depth <your-depth> \
    --skeptic-findings <count-of-substantive-new-issues> \
    [--skeptic-orig <original-worker-window>]   # recursive passes
```

This logs `skeptic-verdict`, clears the **immediately-reviewed** worker's
pending marker, and applies the recursion decision above. `--skeptic-orig`
is read from the skeptic's own provenance when present (so you usually
need not pass it); pass it explicitly only when wrapping up off-tmux or to
override. On a recommended second pass the original worker's marker is
kept live (parked-and-reachable); on termination it is cleared too.

Every mode's wrap-up prints a `CONSEQUENCE:` line stating plainly what
happens next, so no worker is surprised by the gate: `require` → the
window cannot retire until a verdict lands; `auto` → record a decision
now, and if you choose `require` the retire gate applies; `deny` →
proceeding without a skeptic (recorded, no marker).

---

## How a reviewed worker wraps up

Under `require`, or under `auto` after deciding `require`:

```bash
# auto-mode worker that decides a skeptic IS warranted:
ng wrap-up <issue> <report> --repo <owner>/<repo> \
    --skeptic-decision require --skeptic-rationale "touched monitor/ + altered analysis"

# auto-mode worker that decides it is NOT (must still justify):
ng wrap-up <issue> <report> --repo <owner>/<repo> \
    --skeptic-decision deny --skeptic-rationale "one-line README typo, trivially reversible"
```

A `require`-spawned worker needs no decision flag — the skeptic is
mandatory. Then, instead of going idle, **enter the await loop** so the
skeptic's questions reach you and the watcher classifies you
`parked-awaiting-skeptic` (not idle):

```bash
ng skeptic await <your-window>
#   exit 0  → it acked open request(s) (now *.ack.md): read each, answer
#             with `ng skeptic answer <your-window> <req> --file <reply>`
#             (renames → *.answered.md, the signal), then RE-ENTER await.
#   exit 4  → timed out, nothing pending: RE-ENTER await.
#   exit 10 → DONE sentinel: the skeptic closed the channel; stop looping
#             and proceed to retire.
```

If you drift idle without re-entering await, a `nudge` (from the
skeptic's `reconcile`) wakes you. You physically cannot retire until the
skeptic returns a verdict (clearing your pending marker) — the
`retire-preflight.sh` gate enforces it.

---

## Config knobs

| Key | Env override | Default | Effect |
|---|---|---|---|
| `monitor.skeptic.max_depth` | `MONITOR_SKEPTIC_MAX_DEPTH` | `3` | Recursion cap. |
| `monitor.skeptic.findings_threshold` | `MONITOR_SKEPTIC_FINDINGS_THRESHOLD` | `1` | New-findings count that (absent suspect/refuted) triggers a second pass. Floored at 1. |
| `monitor.skeptic.enforce_auto_decision` | `MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION` | `true` | When on (the default), an `auto`-mode wrap-up *fails* until the worker records a decision. Set false for advisory-only. |
| `monitor.skeptic.await_timeout_seconds` | `MONITOR_SKEPTIC_AWAIT_TIMEOUT_SECONDS` | `900` | Per-call `await` timeout. On timeout `await` exits 4 and the worker re-enters; it bounds a single blocking call (the loop heartbeats throughout). |
| `monitor.skeptic.await_interval_seconds` | `MONITOR_SKEPTIC_AWAIT_INTERVAL_SECONDS` | `5` | `await` poll interval (also the heartbeat cadence). |
| `monitor.skeptic.await_hang_seconds` | `MONITOR_SKEPTIC_AWAIT_HANG_SECONDS` | `600` | Hang-vs-wait threshold. A parked worker is exempt from idle flagging only while its pending-marker mtime is within this window; a marker stale beyond it lets a genuine hang resurface. |

---

## Action-log events (audit + orchestrator integration)

All written to `monitor/.state/action-log.jsonl`:

- `skeptic-request` — a skeptic is required for `target-window` at `depth`.
- `skeptic-spawn` — a skeptic was dispatched (`window` reviews `target-window`).
- `skeptic-verdict` — a verdict landed (`verdict`, `target-window`, `findings`).
- `skeptic-decision` — an `auto`/`deny`/`waived` decision was recorded.
- `skeptic-escalate` — issues persist at the depth cap; operator needed.
- `skeptic-nudge` — a worker was nudged about pending requests.

The `skeptic-pending` markers under `monitor/.state/skeptic/pending/`
are the orchestrator's gate: a window with a pending marker has produced
a result that has **not yet** been validated. The gate is **enforced in
code**, not merely advisory — `monitor/retire-preflight.sh` (the
mandatory synchronous pre-kill check, see `skills/nexus.window-cleanup`)
returns `safe=0 reason=skeptic-pending…` while a marker is live, so the
orchestrator physically cannot retire the window until a skeptic returns
a verdict (clearing the marker) or an operator waives.

---

## See also

- `skills/nexus.tmux-spawn` — the three spawn modes at spawn time; when
  to `require` vs `deny`; spawning a skeptic-role worker.
- `skills/nexus.report` — the skeptic decision at wrap-up; the heuristic.
- `skills/nexus.worker-defaults` — the floor every worker reads. It does
  NOT pre-warn an ordinary worker of a skeptic; the await/answer
  mechanics are surfaced at wrap-up (`ng wrap-up` output) and here,
  reached only when a skeptic is actually invoked.
- `<yourlab>.ms-audit`, `matsen/bipartite` — the methodological lineage.
