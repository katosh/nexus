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
| `require` | A skeptic **must** validate this result. | Emits **SKEPTIC REQUIRED**, sets a `skeptic-pending` marker, logs `skeptic-request`, and **files a `kind=spawn-skeptic` request** into the watcher-mediated request inbox so the orchestrator gets a *push* signal to spawn the skeptic (<your-org>/nexus-code#545 — see "The push signal" below). The marker is a **hard gate**: `retire-preflight.sh` (the mandatory pre-kill check) returns no-go while it is live, so the window **cannot be retired** until a skeptic returns a verdict (which clears it) — the task is genuinely not *done* until then. A worker cannot waive it: `--skeptic-decision deny` is refused, and `--skeptic-waive` is refused from a worker context (operator-scoped). The waive is loudly audited (`skeptic-decision decision=waived`); it is a discipline-and-audit control scoped to the operator session, not a cryptographic boundary. |
| `auto` | No specification at spawn — **the worker decides** at wrap-up. | Presents the responsible-default heuristic and requires the worker to record a decision (`--skeptic-decision require\|deny --skeptic-rationale "<why>"`). Enforced by default (`enforce_auto_decision: true`): wrap-up *fails* until a decision + rationale is recorded. |
| `deny` | No skeptic (trivial / low-impact / disabled at spawn). | Proceeds; records "skeptic explicitly denied at spawn." A worker may still *escalate* deny→require if it discovers the work was riskier than the spawn assumed (recorded). |

### A SUPERSEDING verdict must reach `## Summary`

A second-pass verdict is the shape this protocol structurally produces: a
skeptic re-pinned on a delta renders a verdict that supersedes its first. The
append-only report convention says to write it as a new section at the bottom
— and `ng wrap-up` composes the link comment from `## Summary` **alone**, so a
verdict written where the convention says to write it leaves the thread showing
the superseded one. The surface an orchestrator scans when deciding whether to
merge then under-credits the target (`<your-org>/nexus-code#862`, observed live
on `#847`).

`wrap-up` no longer hides this: it publishes nothing, exits **3**, and says so.
Exit 3 is not a failed step and a retry cannot clear it — edit `## Summary` in
place so the correction is IN the composed body, or pass
`--comment-body-file`. Related: a teaser that composes to a fragment is refused
outright rather than posted (`#1114`). Both are the same contract, and it is
written up in `skills/nexus.report/SKILL.md` under "`## Summary` IS the
comment".

### When the gate stays shut on a verdict that DID come back

The marker is removed by exactly **three** writers, and the third is the
repair rather than the ordinary path: a skeptic's `--skeptic-role` wrap-up
(`monitor/ng:5345`) and `skeptic-channel close`
(`skeptic-channel.sh:1375`) are the two that discharge it in the normal
course; **`skeptic-channel resolve` (`skeptic-channel.sh:1618`) is the
audited release** — see "the release is `ng skeptic resolve`" below. If a
verdict exists but neither of the first two ran against the *primary* state
dir, the gate stays shut on its own — `retire-preflight` reports
`safe=0 … required skeptic marker is LIVE` for a window whose verdict you
can read — until someone runs `resolve`. **Do not `rm` the marker**: a guard
whose only visible bypass is hand-deleting it is a guard that trains its own
bypass, which is why `resolve` exists and writes a rationale beside the
record.

**Ask the ledger which kind of "missing" this is before you do anything.**

```zsh
monitor/ng skeptic-evidence <window>     # READ-ONLY; authorises nothing
```

It answers the question the marker cannot: *does a verdict EXIST, could the
bookkeeping match it, and **which verdict is the standing one**?*
`evidence=none` means nobody reviewed the work — get a review.
`evidence=unmatched-subject | no-open-arm | verdict-without-arm |
unmatched-other | ambiguous-arms | rearm-after-close | superseded-verdict |
prior-verdict-other-artefact | attributed` all mean a verdict **was
delivered** and the record cannot match it. There is deliberately **no class** for "supersession
could not be established" — that lives on `superseded=?`, because a
single-winner precedence chain is the wrong shape for a property orthogonal to
the one it ranks: placed high it masks a definite matching answer, placed low it
is unreachable. All of them mean — repair the record, and do **not** file a
`spawn-skeptic` request or push the reviewer, which has already discharged.
`evidence=?` means it could not tell, and asserts nothing in either direction.
`retire-preflight` now carries the same tag in its refusal, so you usually get
the answer without asking. Every class prints the discharge rows that produced
it, so you can check the classification rather than believe it
(<your-org>/nexus-code#1156).

**`superseded=` is the one to read even when another class wins**, and it has
**three** states, because a later verdict row is not automatically a superseding
one:

| `superseded=` | what it means | what to do |
|---|---|---|
| `1` | same issue, **differing** verdicts — a reader taking the cleanly-attributed row gets an answer that no longer holds | **take the later one** |
| `0` | different issues (unrelated **tasks** — neither supersedes the other), or the same verdict recorded twice (a **re-record**) | nothing; the attributed row is fine |
| `?` | an issue field is absent, so the relation **cannot be established** | read both rows before acting on either |

`superseded_why=` names which of those it is, so the judgement is checkable
rather than trusted.

**`0` also covers "the question does not apply", which is why you read
`superseded_why` and not the number.** `sup_state` is computed only when a
cleanly-matched row exists, so a ledger whose verdicts are ALL unmatched cannot
reach `1` or `?` — it falls through to `0`, whose gloss above is "the attributed
row is fine" when `attributed_verdict=-` sits on the same line. Measured over the
64 ledgers in this nexus's live `.state/skeptic/pending` on 2026-08-31: **19**
print `matched=0 superseded=0`, and **14 of those carry a delivered
`standing_verdict`**. Those now read
`superseded_why=no-attributed-row-to-supersede`. The VALUE stays `0` — only `1`
licenses discarding a verdict, and a third value would be a gate change wearing a
wording fix (`<your-org>/nexus-code#1199`). Distinct from `standing_stale`, which
answers whether the standing verdict is about the CURRENT artefact; this answers
whether `superseded` is answering anything at all.

**`standing_stale=` is the other three-valued field, and its `0` is NARROW.**
It answers whether the standing verdict is about the artefact's *current* bytes,
and it is **ledger-internal by design** — it reads `armed` rows, never the file
on disk. So it can only ever see an amendment that was *re-armed*:

| `standing_stale=` | what it means | what to do |
|---|---|---|
| `1` | a later `armed` row names a **different** sha — the standing verdict is about superseded bytes | read the REPORT alongside the ledger; do not treat the verdict as current |
| `0` | a later `armed` row names the **SAME** sha — the artefact was re-hashed at the same path and is unchanged | nothing; the standing verdict is current |
| `?` | **nothing established it** — no later arm at all, no standing verdict, no artefact named, or an unparseable ledger | read the report; `?` is not "fine" |

**A `0` here is a MEASURED currency claim, and only a same-sha re-arm earns
one.** "No arm after the standing verdict" used to print `0`, and that was the
one value it must never print: `ng send` — the transport a re-pin arrives on —
writes neither an arm nor a discharge, so a report **amended in place** and
re-reviewed leaves a ledger byte-identical in shape to a healthy one. Both then
printed `standing_stale=0 standing_stale_why=no-arm-after-the-standing-verdict`:
one line, two opposite realities, with the value that means *checked, and
current* on the case where nothing was checked. It now reads
`standing_stale=? standing_stale_why=no-arm-after-the-standing-verdict-artefact-bytes-not-re-examined`.
`retire-preflight` acts only on `1`, so this is a wording-and-honesty change and
not a gate change (`<your-org>/nexus-code#1199`).

**The `?` arm is DEFENSIVE, not common**, and an earlier revision of this table
said the opposite. It cited `#1146` — which is about the task/`disposition:`
field in report FRONTMATTER, a *different field* from a ledger row’s issue —
and asserted an absent issue was "the common case". Measured on this board:
**0 of 72** `discharged` rows and **0 of 88** `armed` rows lack one. The arm is
still right to exist, because `_skeptic_record_discharge` writes `${issue:--}`
so a wrap-up with no issue produces one by construction; it has simply never
fired on real data here. Cited here because a prevalence claim that measures
zero is exactly the kind of thing a skeptic should refuse to inherit — and this
one was inherited, from me, through a skeptic brief.

**Only `1` licenses "take the later one"** — that instruction *discards a
verdict*, and deciding it from ledger order alone would be window-keyed
newest-wins, the container error `#1156` exists to fix and `#962` forbids. It
can be excluded from the gate and still re-enter through the **prose**, and the
prose is what an operator acts on. Measured on a planted ledger: `credible` on
issue 1156 by `sk-a`, then `suspect` on issue **1200** by `sk-b` — two
unrelated tasks, and an order-only rule told the reader to discard a valid
verdict. And identical verdicts are **not** a supersession: nothing is weaker or
stronger about two identical strings.

Seven ways a delivered verdict goes unmatched. The middle four were all observed
on ONE afternoon, and before this existed each produced a byte-identical
refusal — which is what fired three duplicate `spawn-skeptic` requests (one for
a PR that had already merged) and two pushes at reviewers that had already
discharged:

- **State fork (<your-org>/nexus-code#577).** A skeptic spawned via a
  *secondary clone's* `spawn-worker.sh` used to inherit
  `NEXUS_ROOT=<clone>`, so its spawn record, its require-marker and its
  verdict report all landed in `work/<clone>/monitor/.state` and
  `work/<clone>/reports` — while the marker blocking retirement sat in the
  primary. Now fixed at the source (`spawn-worker.sh` resolves the primary
  root; `ng report-init` pins to the corpus), but an old marker can still
  be sitting there.
- **Re-armed after the fact** (`evidence=rearm-after-close`). A worker re-runs
  `wrap-up … --skeptic-decision require` *after* a verdict already
  returned, opening a round no one will answer.
- **The report was AMENDED after arming** (`evidence=unmatched-subject`). An
  arm names the report's CONTENT HASH; editing the report moves the hash off
  the armed one, and the reviewer's `--skeptic-subject` then recorded
  `asserted-not-armed` — a verdict that names an artefact nobody armed.

  **Pass the PATH and this now attributes** (<your-org>/nexus-code#1156).
  `--skeptic-subject reports/<the report you read>.md` is matched back to the
  arm that named that path on the same issue, and the round closes with detail
  `asserted-path`; the hash you actually held is kept in the row's eighth field
  as the drift evidence. **A bare sha is still a claim about BYTES** and is
  refused exactly as before — so is a path armed on a different issue, and a
  path nobody armed. The class is deliberately not `asserted`: "I read the
  revision that was armed" and "I read a LATER revision of the same
  deliverable" are different facts and this record keeps them apart.
- **Several rounds armed against ONE report path** (`evidence=ambiguous-arms`).
  Three `wrap-up` runs arm three rounds; one discharge could not close three
  arms, so it attributed nothing.

  **This no longer happens for one deliverable** (<your-org>/nexus-code#1156). A
  DELIVERABLE is `(issue, report path)` and the sha says which REVISION of it;
  a later arm on the same deliverable now REPLACES the earlier open arm, so
  three `wrap-up` runs over one report leave one arm and an ordinary verdict
  attributes — **with no flag at all**. Arms on DIFFERENT paths still stay
  distinct and still go ambiguous, which is the honest answer: state cannot say
  which of two artefacts the reviewer saw.
- **A SUPERSEDING verdict** (`evidence=superseded-verdict`, `superseded=1`). Two
  real verdicts from one reviewer on one target. The target landed a fix **while
  the skeptic was still reviewing**; the skeptic re-derived its findings against
  the new head rather than accepting the fix on its description, and amending
  its report to publish that moved the content hash off the arm. Arming happened
  once, against the original report. **The ledger then records the WEAKER first
  verdict as matched and the stronger later one as unmatched.**

  Two discharges for one arm is a **legitimate state, not a duplicate** — and
  note what this costs if left unnamed: it fires precisely *because* the skeptic
  did the harder, more correct thing. A reviewer that ignored the moving head,
  or re-armed and started over, would have recorded cleanly. A bookkeeping layer
  whose failure mode selects **against** the behaviour the protocol wants is a
  design fault, not an accounting gap. `--skeptic-subject <the report path>` on
  the amended report is the clean way to record it, and since
  <your-org>/nexus-code#1156 it ATTRIBUTES rather than landing
  `asserted-not-armed` — the superseding verdict closes the arm and the record
  keeps both hashes. Pass the PATH, not a sha: a sha is a claim about bytes and
  is still matched as one.
- **NOBODY EVER ARMED A SUBJECT** (`evidence=verdict-without-arm`, detail
  `no-arm-on-record`). The armed state has TWO writers and only one of them
  recorded a subject: a worker's `wrap-up --skeptic-decision require` wrote the
  marker AND an `armed` row, while `spawn-worker.sh --skeptic-role` wrote the
  marker ALONE. Its own source says it is "the ONLY thing that restores the
  block" for a second-or-later pass — so every re-validation round, the rounds
  that exist *because* something was already found wrong, armed with nothing the
  ledger could credit. `spawn-worker.sh` now records the arm it establishes,
  against the report the reviewer is POINTED at, via `ng skeptic-arm`.

  Worse, such a verdict used to be DROPPED entirely, so the key reported
  `evidence=none` — *get a review* — for work a reviewer had finished. It is now
  recorded with subject `-`, which authorises nothing. **Do not confuse this with
  `no-open-arm`**, which means a ledger EXISTS and everything on it is
  discharged — the ordinary terminal verdict of a chain that closed cleanly,
  where nothing is owed and no repair is needed. Here nothing ever armed the key,
  and the repair is to the ARM (`<your-org>/nexus-code#1207`, `#1191`).
- **The other ledger.** `$STATE_DIR/obligations` records the same dependency
  separately, and it can hold a **live edge** while the skeptic ledger is fully
  settled (matching hash, `attributed`, verdict recorded). `retire-preflight`
  names this as a `TWO-LEDGER DESYNC` and points at
  `ng obligation settle`/`ng skeptic close` — the fix is to settle the EDGE, not
  to ask for another review.

### Settling the EDGE does not release the CHANNEL

`skeptic-channel.sh close` is the **sole** writer of the `DONE` sentinel, and
`obligations.sh` writes nothing under `skeptic/<task>/` at all.

Do not try to establish that with a census of the `_done_sentinel` accessor —
**the writer does not use it.** `cmd_close` builds `"$dir/DONE"` literally
(`skeptic-channel.sh:1037`); the accessor's only non-comment sites are its own
definition and the READER in `await`. An earlier revision of this section cited
those two as "the writer in `close` and the reader in `await`", which is wrong
about which sites they are — the right total for the wrong reason. Keying on the
sentinel PATH does not rescue it either: the write is `mv -f "$tmp" "$sentinel"`,
so no `DONE` literal appears on the writing line at all. The claim is
behavioural, so it is tested behaviourally — settle a real edge and look for the
file (`test-skeptic-arm-recording.sh`).

So **`ng obligation settle` cannot release a counterpart sitting in `await`**, and
it never could. The two verbs read as interchangeable at the point of use — both
end an obligation, in different ledgers — and settling then walking away leaves
the target looping to its timeout. `settle` now says so on stderr, naming
`ng skeptic close <creditor>` and whether the require-marker is still live.

**And mind the NAME**: a reviewer awaits on its OWN channel, not its target's, so
closing the target releases nothing. `retire-preflight` detects this shape
directly and names the right window (`<your-org>/nexus-code#1190`).

When diagnosing it, note the ordering trap: running `close` *before* `settle`
cannot tell you which of them wrote the sentinel. The answer is structural, not
experimental.

The release is **`ng skeptic resolve <window> --reason "<why>"`** —
orchestrator-only (refused inside a worker), rationale mandatory and
substantive, refuses when there is no marker, appends the reason to
`.<window>.cleared-rationale` beside the marker and logs a
`skeptic-resolve` event. **Never `rm` the marker**: hand-clearing is what
this verb exists to replace, and a guard that trains its own bypass is
worse than no guard.

It is not a waive. `--skeptic-waive` says *no skeptic was required after
all* and is recorded as a decision about the **requirement**; `resolve`
says *the validation happened, here is where it landed* and is recorded as
a statement about the **evidence**. Waive also only ever clears the marker
of the window whose own wrap-up invokes it, so it structurally cannot
release another window's gate.

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

### The push signal (`kind=spawn-skeptic` request, #545)

Spawning a skeptic is orchestrator work by design — there is no auto-spawn.
Historically the orchestrator learned to spawn only by *polling* the
worker's pane or via the 600s-delayed `orphaned-skeptic-pending` backstop,
so first-pass requires routinely waited minutes (or were missed overnight).
`ng wrap-up` now closes that gap: on a `require`/`required-escalated`
resolution (and when a skeptic recommends a second pass), it files a
`kind=spawn-skeptic` request into the watcher-mediated request inbox
(`monitor/request-channel.sh`), which surfaces in the next watcher emit's
`--- requests ---` section. The request is filed **after** the report
uploads + the link comment posts, so it carries the asset + comment URLs
and the skeptic always has a complete artifact. Filing is **best-effort** —
a failure never fails the wrap-up (the pending marker + orphan backstop
still cover it). The inbox is **on by default** as of #545
(`monitor.requests.enabled: true`; reversible via `config/nexus.yml`).

The request `## Details` carries **pointers** (not inline copies): `issue`
+ `trigger-comment` (the operator's original ask), `report-path` +
`report-asset-url` + `link-comment-url` (**both are SNAPSHOTS pinned when the
request was filed, and are NOT re-pointed if the report is amended and
re-wrapped — `report-path` is the authoritative, current deliverable; read
that**, `<your-org>/nexus-code#1148`), the worker's
`worker-prompt-file` (the orchestrator's spawn brief + woven-in operator
context), `window`/`session-id`, and `depth`/`orig`/`mode`. The
orchestrator composes the skeptic brief from these, spawns
`spawn-worker.sh --skeptic-role`, and the spawn **auto-acks** the request
(join key `request.origin == --skeptic-target`), so it self-clears without
a manual `ng request ack`.

**A WORKER MAY NOT SPAWN ITS OWN SKEPTIC, and this is now ENFORCED
(`<your-org>/nexus-code#1098`).** `spawn-worker.sh --skeptic-role
--skeptic-target <w>` REFUSES with exit 20 when the spawning agent IS
`<w>` — matched on the session id recorded for `<w>`, or on the spawning
window's own `$NEXUS_WORKER_WINDOW`. It was prose here and nowhere else
until a careful worker walked straight through it: on 2026-08-27 a worker
filed a request at 23:43:53 and spawned its own reviewer at 23:44:35, 39 s
before the orchestrator acted on that same request. Two agents reviewed
one target, and one read a mandate written by the party under review. The
hazard is not a wrong answer — the brief that worker wrote was good — it
is an **unexamined region**, and an omission is invisible from inside the
brief that omits it. That is why brief-composition belongs to the
orchestrator, which has the spawn context the worker does not.

If you are a worker and you want review: file `ng request file --origin <your-window> --kind spawn-skeptic --slug <slug> --message '<what to review and why>'` and
stop. If a self-spawn is genuinely intended, it must be loud and audited
the way `GH_IMPERSONATE` is — `NEXUS_SKEPTIC_SELF_SPAWN=1` **plus**
`NEXUS_SKEPTIC_SELF_SPAWN_REASON='<why>'`, both required, recorded in
`monitor/.state/skeptic-self-spawn.log`.

**Is a reviewer already on this? — `live-skeptic-window` (`#771`).** The
request carries a tri-state field so the orchestrator does not have to
reconstruct the answer from tmux by hand:

- `yes: <window> (state=<s>) …` — a reviewer exists. **Re-pin it**; do not
  spawn a duplicate. The incumbent holds an enumeration a fresh skeptic
  would have to rebuild, and a second one starts blind to any findings the
  first has retracted.
- `no (…)` — checked, and nothing is there. The evidence is quoted.
- `unknown (…)` — the probe could not look (no tmux, no window list, no
  `jq`). **Not** the same claim as `no`.

A window counts as live when it is named by either the **spawn record**
(`monitor/.state/windows/<w>.json`, `skeptic_role` + `skeptic_target` — the
authority) **or** the legacy `<target>-skeptic` convention (kept as a union
member, so a window predating the records still counts), **and** a tmux
window of that name exists now, **and** the pane does not positively assert a
dead agent. It used to be the name match *alone* — which **43% of skeptic
windows on the reporting nexus** do not follow (one operator's store, not a
universal rate), so `fig4sk` reviewing `fig4rev` was invisible and four
duplicate requests were filed in twelve minutes. **Wrapped-up is not gone**: an `idle` skeptic is the most
re-pinnable state there is. The field errs toward `yes`, because it never
suppresses the request — a wrong `yes` costs one look at a named window,
while a wrong `no` costs a duplicate reviewer posting into an issue the
operator is reading.

**The orchestrator's say — `deliberate`.** The request carries a
`deliberate` flag so the orchestrator spends attention only when it matters:
- `deliberate: false` — a clean first-pass require. Auto-spawnable
  (rubber-stamp); the orchestrator composes the brief and spawns.
- `deliberate: true` — flagged when a prior skeptic disputed (a second-pass
  recommendation, `depth > 0`) **or** the worker overrode a skeptic
  suggestion via **`--skeptic-contradicted "<what/why>"`** at wrap-up. Here
  the orchestrator reads the prior verdict / the contradiction and decides
  (spawn-with-adjudication, decline, or escalate) rather than
  rubber-stamping — the consensus case where its bigger-picture view is
  wanted. Pass `--skeptic-contradicted` whenever you (the worker) knowingly
  did NOT follow a skeptic's recommendation, so the disagreement is
  arbitrated rather than silently shipped.

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

### State your disposition — the verdict is not a finding count

Write **one line** in your report saying whether the chain should
continue:

```
Disposition: no-further-pass
Disposition: second-pass
```

**Why this is required and not decorative.** `ng wrap-up` DERIVES a
second-pass recommendation from `--skeptic-findings` — a **count**. A
count is severity-blind by construction: one cosmetic nit and one
merge-blocking defect are both `findings=1`. That derived value overrode
reports whose own text concluded no further pass was warranted, three
times in one session (<your-org>/nexus-code#599), each costing an
orchestrator adjudication of a question the report had already answered.

Your disposition is the better evidence, so state it. When the derived
recommendation and your stated disposition **disagree**, wrap-up now says
so loudly and files the request with `recommendation=DISPUTED` rather
than picking one — **the orchestrator adjudicates.** Neither value is
silently allowed to win.

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
worker's `await` detects it and exits **10**. There is also **11**
(`COUNTERPART-FINISHED` — the skeptic recorded its verdict without closing
the channel, so nothing further can arrive: stop re-entering and retire),
and a displaced waiter exits **12** (`DISPLACED` — a newer `await` claimed
this channel under `#615`'s one-live-waiter lock and reaped this one; the
newer one is LIVE, so do **not** re-arm, and the reaper leaves a line in
`<channel>/.await-displaced`). A skeptic or the orchestrator can also
**defer**: `ng skeptic defer <task> --reason "<why>" [--until "<condition>"]`
releases the worker's CURRENT wait with exit **13** (`DEFERRED`) while the
requirement STANDS — the pending marker is untouched, so retirement stays
gated; the worker reads the reason, acts on it, and RE-ENTERS `await`
(<your-org>/nexus-code#845 claim H). The channel tree under
`<state>/skeptic/` is **pruned at retirement**: a retired window's channel
moves to `skeptic/.archive/<task>.retired-<ts>/` and `reset` archives a
prior round to `skeptic/.archive/<task>.reset-<ts>/`, so any survey over
live channels is a survey of survivors — read the archive too
(<your-org>/nexus-code#1434). A TERM that is *not* a displacement — an
operator `kill`, a `timeout` wrapper — still exits **143**
(`<your-org>/nexus-code#1178`).

**RUN `await` BACKGROUNDED AND ENDING IN `exit $rc`, or every one of those
codes reaches you as 0** (`<your-org>/nexus-code#1161):

```bash
monitor/skeptic-channel.sh await <task>; rc=$?; echo "AWAIT_RC=$rc"; exit $rc
```

Backgrounding is compulsory rather than a preference: the await budget is
900 s and the Bash tool ceiling is 600 s, so the timeout path cannot finish
in the foreground. But backgrounding is not what flattens the code — **a
`;`-list reports its LAST statement's status**, so a trailing `echo` does
it, and so does a bare trailing `rc=$?`. **Capturing is not the fix;
`exit $rc` is.** Measured over this board's transcripts: of 369
backgrounded `await` invocations, **11** ended in `exit $rc` — the other
97% reported 0 whatever actually happened, and `11` ("do NOT re-enter")
reads identically to `0` ("re-enter"), which is an infinite loop.

A correct `exit 4` renders as *"failed with exit code 4"* and is the
ROUTINE outcome. **Do not tidy the `exit $rc` away to silence it.** And
treat the counterpart's STATE — its pane state, its report on disk,
`settled_at` — as the primary signal, with the exit code as corroboration;
that is the only remedy that also covers 143.

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
#   run it via the Bash tool's run_in_background — NOT async-run.sh (#1523, below)

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
channel, stop looping and retire. **11** — `COUNTERPART-FINISHED`; the
skeptic recorded its verdict (which clears your pending marker) but never
ran `close`, so no `DONE` will ever arrive. Do **not** re-enter await —
read its report and retire. **13** — `DEFERRED`; your wait was released
WITHOUT discharging the requirement (the marker still gates you): act on the
printed reason/condition, then RE-ENTER await. **12** — `DISPLACED`; a NEWER
`await` claimed this channel and reaped yours (the one-live-waiter lock,
`#615`/`#1178`). Your listener is gone and the newer one is LIVE — do **not**
re-arm, that would displace it in turn. **2** — bad task/channel.
*(That is the full await vocabulary; `skeptic-channel.sh`'s own `Exit codes`
header block is the authority. The codes it lists that `await` cannot return
are `3` tmux/paste failure and `5` nudge skipped — both `nudge`'s — and `6`,
`reconcile`'s.)*

**How to run it — the WAKE, not only the rc** (<your-org>/nexus-code#1523).
The await budget is 900 s against the Bash tool's 600 s foreground ceiling,
so `await` runs BACKGROUNDED, and BACKGROUNDED means **the Bash tool's
`run_in_background` option**: the harness re-invokes you when the job exits,
which is what makes the typed rc above actionable. Alternatively a
`Monitor` until-loop, for a condition rather than a job. It does **not**
mean `monitor/async-run.sh` — that launcher RETAINS the rc and re-invokes
nobody, so an await run through it expires correctly (rc 4, retained) into
an agent that is not running to read it. Measured on w237sk, 2026-09-12:
`asyncrun:… terminal rc=4 elapsed=902s`, then 809 s idle until the watcher's
orphan-async backstop pasted the verdict. Run each re-entry the same way; the
rc-preserving `…; rc=$?; echo "AWAIT_RC=$rc"; exit $rc` form (`#1161`) and
the `run_in_background` launch are two separate properties and you need
both. The rule behind it lives in the worker floor
(`skills/nexus.worker-defaults/SKILL.md`, *A retained exit status is not an
armed wake*): a parked agent must be able to name what will RE-INVOKE it.

While parked in `await` the loop refreshes the worker's skeptic-pending
marker mtime every poll — that heartbeat is what the watcher reads to
classify the worker `parked-awaiting-skeptic` (below).

**The heartbeat establishes that the WAITER is alive. It does not
establish that the WAIT is meaningful** — those are different properties,
and conflating them is what left two workers parked indefinitely on
skeptics that had finished hours earlier (<your-org>/nexus-code#615). What
ends the wait is the **counterpart**, so `await` now checks the
counterpart directly: a pending marker it observed live and that has
since vanished means the verdict landed, and it exits **11** instead of
blocking to timeout. Re-arming also **reaps** the previous waiter — one
live `await` per (worker, channel), enforced rather than assumed, after
five concurrent awaits stacked up on one channel at ~1/min.

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
  resolved to its tmux **index** before the probe, and if the index can't
  be resolved the nudge **fails safe and skips** rather than pasting into
  a pane whose state is unknowable. `--force` overrides. *(That resolution
  is now belt-and-braces, not a requirement: `pane-state.sh` has accepted a
  NAME — as well as an index and a `session:window` — since
  `<your-org>/nexus-code#905`; it resolves one via `resolve_window_index`
  internally. `skeptic-channel.sh:1793`'s "pane-state.sh is INDEX-keyed"
  comment predates that and is stale. The fail-safe-on-unresolvable
  behaviour is unaffected.)*
- **rate-limits** per window (default 120 s) so a flapping skeptic can't
  spam the pane. `--force` overrides.
- **no-ops** when there are no open requests.

**Failure modes to know:** the nudge needs the worker window to exist in
tmux (`exit 3` if absent — the worker may have been closed; recreate via
`spawn-worker.sh --resume` or re-ask after it's back). The
autosuggest-ghost-text hazard and window-resolution pitfalls are handled
inside paste-followup.sh's VI-safe sequence; do not hand-roll around it.

### Notify-delta — waking a *pinned skeptic* that a new round exists

`nudge` wakes a **target** that owes its reviewer an answer. The mirror
direction had nothing, and its absence is `<your-org>/nexus-code#845`:

> A worker that finishes a round parks awaiting its skeptic's verdict.
> Its skeptic — correctly **pinned across rounds** rather than retired —
> idles awaiting a delta **it has not been told exists**. Neither side can
> release the other, and nothing surfaces the pair as blocked.

Both windows are behaving correctly: a worker may not paste into a window
it did not create, and an idle pane observes nothing. Measured: **seven
pairs in one session**, the longest **4h 6m**; then **2h 18m** for
`tmuxwrap`/`sk897` on 2026-08-14, where the orchestrator had explicitly
promised to route the head and did not.

**You almost never run this by hand.** `ng wrap-up` fires it for you: when
a `require` re-arm finds a **live pinned skeptic** for the wrapping window,
it reopens the obligation edge and notifies that reviewer, printing a
`=== PINNED SKEPTIC NOTIFIED ===` block. The spawn-skeptic request is still
filed — this removes the orchestrator from the **critical path** of a pair
that already knows about each other, not from the decision.

```bash
ng skeptic notify-delta <skeptic-window> --target <window> [--round N] \
    [--detail "<what changed>"] [--force] [--min-interval S]
```

Same guards as `nudge`, from the same `_wake_gate` — one gate, two
directions, because a second transcription is how two copies of a rule
drift apart. A reviewer's pane is not more interruptible than a worker's.

**Why this is not "a worker pasting into a window it did not create":** it
is the *tooling* pasting, on the path `nudge` has crossed in the other
direction since it existed (a skeptic nudges a worker whose window it did
not create). The invariant is *no ad-hoc `tmux send-keys` between agents*,
and this honours it — same `paste-followup.sh`, same machine-input stamp,
same audit event. The message is a **notice**, not an instruction: it names
the delta and points at the record, and does not tell the reviewer what to
conclude.

**Failure modes:**

| Situation | What happens |
|---|---|
| No live skeptic | Nothing notified. The spawn request is the whole mechanism, as before. Silent. |
| Could not look (no tmux / no jq / malformed record) | Nothing notified, and it **says so** — `unknown` never collapses into "none" (`#771`). Route by hand. |
| Skeptic pane busy / typing / unresolvable | Deferred (rc 5) with a reason. **The obligation edge is still recorded**, so `retire-preflight` protects the pair even when the wake did not land. |

### Obligations — the record that a pair depends on each other

The notify above breaks the deadlock going forward. The other half of
`#845` is that **nothing could see the dependency at all** — which is how
`sk911` was retired while it still owed `papercuts` a delta re-run, at
`retire-preflight` `safe=1`, with a `window-retain` already logged. The
preflight answers *"is anyone typing"*, not *"does this window still owe
or is it owed something"*.

An **obligation** is a directed edge `DEBTOR owes(kind) CREDITOR` between
two windows. It is opened by the mechanism that already knows the linkage,
so nobody has to remember it:

| Opened by | Edge |
|---|---|
| `spawn-worker.sh --skeptic-role --skeptic-target T` | `<new skeptic>` owes `T` a verdict (and the chain root, when recursive) |
| `ng wrap-up` re-arming a `require` round with a live pinned skeptic | that skeptic owes the target the new round |

| Ended by | How |
|---|---|
| `ng skeptic close <target>` | the protocol's **own** end-of-pairing signal — it already means "the skeptic closed the channel; stop looping and retire", and it releases the target's `await` with exit 10 |
| a **later** reviewer pinned to the same target | supersession — the pairing was handed over, so the earlier reviewer is free |
| the creditor window leaving tmux | a window that does not exist depends on nobody |
| `ng skeptic resolve <target> --reason "…"` | an orchestrator adjudicating the target's gate as done — a statement about the pairing, so it discharges **every** reviewer of that window (`<your-org>/nexus-code#926` F5) |
| `ng obligation settle --debtor <w> --reason "…"` | the audited manual release (reason ≥ 20 chars, on the record). `--creditor <w>` discharges every reviewer of `w` instead |

**A FILED VERDICT DOES NOT END THE PAIRING**, and this is the correction that
`sk926` forced (`<your-org>/nexus-code#926`). The first version settled the edge
on the debtor's first verdict, *and* derived a release from the creditor's
pending marker going absent — which the same verdict clears. So the edge
existed only over `[spawn → first verdict]`, and **the hazard begins exactly
where that interval ends**. Replayed from the recorded action log:

```
08:58:04  skeptic-spawn   sk911 -> papercuts     edge opens
09:19:36  skeptic-verdict sk911 -> papercuts     edge CLOSED here
09:21:21  window-retain   sk911                  <- the retirement
10:41:37  skeptic-spawn   sk911b -> papercuts    a THIRD reviewer needed
```

`papercuts` was still being worked at 10:55. A verdict discharges **one
round**; a retained reviewer is the designated reviewer for the *next* round
too — that is why it is retained rather than retired — so it is owed again the
moment its target pushes a delta, and there is no instant in between at which
destroying it is safe. The verdict is *recorded* on the edge (`ng obligation
show`) and releases nothing.

`retire-preflight` **check 1d** refuses to retire a live debtor.
Default-deny over the edge state: `live` and `unknown` refuse; only the four
states that *positively* assert this reviewer is no longer the one its target
depends on release it.

**The DONE sentinel is matched by CONTENT + INODE**, never by timestamp. Both
`opened_at` and `stat -c %Y` are second-resolution, so a reopen and a close in
the same second are indistinguishable by time — and the readings that
ambiguity must separate are "closed after this round was armed" (release) and
"the previous round's sentinel" (`#469`, do **not** release). A bare `touch`
(a `find -exec touch`, a restore, a filesystem migration) would otherwise
manufacture a release and retire a live reviewer. `close` rewrites the
`closed:` line *and* republishes via `mktemp` + `mv -f`, so a genuine close
changes both; two closes inside one second are still caught by the inode, and
a recycled inode is still caught by the content.

```bash
ng obligation pairs                  # who is waiting on whom, right now
ng obligation list --debtor <w>      # what this window owes, and in what state
ng obligation gate  <w>              # the predicate check 1d asks
ng obligation settle --debtor <w> --reason "<why this reviewer is no longer owed>"
ng skeptic close <target>            # the ordinary ending — do this, not settle
```

**Retiring a reviewer now needs the pairing closed first.** That is a workflow
change and it is the intended one: the protocol has always told the final
skeptic to `close` the channel, nothing checked it, and the check is what makes
the instruction real — exactly as check 1b made `require` real.

**It stays silent on healthy pairs**, which is what keeps it from being
disabled by whoever is under time pressure. It fires only when somebody is
retiring a *debtor*; a parked target with a working skeptic never reaches
it, and every ordinary ending releases it automatically.

**A `window-retain` is not an obligation.** A retain is a note about one
window; an obligation is a relation between two. `retire-preflight` reads
the second and not the first, deliberately — that is why the retain logged
for `sk911` did not save it.

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

### Operational gotchas when driving skeptics

Four traps that repeatedly cost idle worker-hours:

- **The `pending/<name>` marker is the authoritative "parked" signal — a
  busy pane is NOT.** A `require`/`auto` worker that wrapped can enter a
  periodic re-check/await loop whose pane reads `state=busy` with a long
  running timer (`✻ Worked 1h18m`) — indistinguishable from a worker
  still researching, and it suppresses the clean `parked-skeptic`
  transition emit. So on **every wake**, glance at `ls -A
  monitor/.state/skeptic/pending/` *before* trusting a busy timer: a
  marker present ⇒ the worker wrapped and is waiting for you to spawn its
  skeptic — spawn it now; a genuinely-researching worker has no marker.

- **Verify a skeptic WINDOW actually exists.** On a `parked-awaiting-skeptic`,
  do not trust the "skeptic reviewing" emit alone — confirm
  `tmux list-windows -a -F '#{window_name}' | grep skeptic` shows a
  `<worker>-skeptic` window. If a `skeptic-request` is logged but no
  window exists (pre-#545 sessions could log the request without filing
  the spawn-skeptic channel; the orphan backstop is 600 s), spawn it
  manually — `--skeptic-role` **requires** a real `-p` prompt file **and a
  real `-r` report. `-r` is the only thing that gives the arm a SUBJECT**
  (<your-org>/nexus-code#1251): without it `spawn-worker.sh` writes the marker
  alone and appends no `armed` row, the verdict lands `no-arm-on-record`, and
  nothing later can repair it — the ledger is append-only and that class is
  terminal, so the only repairable moment is this one. This recipe is the
  RECURSIVE shape, where `spawn-worker.sh` is the ONLY writer of the arm:
  ```bash
  ./monitor/spawn-worker.sh -n <w>-skeptic -c <worker-workdir> \
    -p <skeptic-prompt-file> -r <the-report-the-skeptic-must-read> \
    --skeptic-role --skeptic-target <w> \
    --skeptic-orig <w>
  ```
  Omit `--model` — the skeptic then inherits the `model` pin in
  `monitor/worker-settings.json`, so it tracks the operator's current
  default instead of a hardcoded id that goes stale on every release.

- **A skeptic that reached a verdict but ENDED ITS TURN before wrap-up.**
  The watcher flags `<skeptic> idle … WITHOUT wrap-up`. Read the pane
  first: a reached verdict + a "now close / wait then close" plan with no
  spinner and no running `Monitor` ⇒ **stalled** — nudge it through the
  sequence (`report-init → reconcile → ng wrap-up … --skeptic-role
  --skeptic-verdict <v> --skeptic-findings <n> → ng skeptic close
  <target>`). A live `✻ …ing · Monitor still running` ⇒ it's re-deriving
  async (good rigor) — let it finish, do not nudge.

- **A skeptic-channel answer misattributes as an operator submit.** When a
  parked worker answers the skeptic's question, the prompt-submit surfaces
  as a `UserPromptSubmit` the attribution logic can't tell from a real
  operator paste — the window hardens to `operator-engaged (src=submit)`
  and `retire-preflight.sh` returns `safe=0`. That gate is **correct to
  refuse** — do not force-kill. When the window is verifiably done
  (wrapped + credible verdict + channel closed), clear it with the
  *designed* release, not a kill: `monitor/ng engaged-done --window <w>`
  → preflight immediately returns `safe=1`. And if you drove the skeptic
  **externally** (spawned/closed it yourself rather than through the
  worker's channel), the worker's await loop waits on its own channel
  forever — paste an explicit RELEASE (`paste-followup <worker>`:
  "skeptic already ran, verdict `<v>`, closed — STOP the await loop, do
  not re-enter, end your turn") or it re-enters indefinitely and re-pins
  `safe=0` each pass.

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

**State the count, or state a disposition — do not leave both blank.**
`--skeptic-findings` is optional and its ABSENCE IS RECORDED AS ABSENCE
(`<your-org>/nexus-code#881`): omitted, it prints `not stated`, logs
`findings-stated=false` with no `findings` key, and never reaches the
threshold comparison. It used to be silently defaulted to `0` — the one
value that means "nothing found" — which made *"I measured zero"* and
*"I never said"* the same record, on the gate that decides whether
another pass is warranted. Now, with **neither** a count nor a readable
`disposition:`, wrap-up **REFUSES** (exit 1, `YOU STATED NEITHER A COUNT
NOR A DISPOSITION`) rather than terminating on a number nobody supplied —
it stopped being an escalation when `#1137` landed, and this line said
"escalates" for longer than that was true. Either statement ends the chain
honestly, and both are one line: `--skeptic-findings 0` (you looked and
found nothing new) or `disposition: no-further-pass` in your report
frontmatter.

`ng report-init` now seeds **`disposition: TODO`** into every report's
frontmatter, and `report-check` **refuses** until you replace it —
measured on `dev`: a filled report still carrying `TODO` exits 1
(`unreadable in frontmatter — value-not-a-token`, plus the placeholder
rule), and exits 0 once the value is real. So the field is a forcing
function rather than a scaffold, and it applies to **every** report rather
than only to windows that can be identified as skeptics
(`<your-org>/nexus-code#1146`).

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
#   LAUNCH: the Bash tool's run_in_background (it re-invokes you on exit),
#           ending in `exit $rc` (#1161). NOT async-run.sh — it retains the
#           rc and wakes nobody (#1523; "How to run it" above).
```

If you drift idle without re-entering await, a `nudge` (from the
skeptic's `reconcile`) wakes you — and the commonest way to drift idle
is to have launched the await through a launcher that cannot re-invoke
you (`#1523`). You physically cannot retire until the
skeptic returns a verdict (clearing your pending marker) — the
`retire-preflight.sh` gate enforces it.

---

## Config knobs

| Key | Env override | Default | Effect |
|---|---|---|---|
| `monitor.skeptic.max_depth` | `MONITOR_SKEPTIC_MAX_DEPTH` | `3` | Recursion cap. |
| `monitor.skeptic.findings_threshold` | `MONITOR_SKEPTIC_FINDINGS_THRESHOLD` | `1` | New-findings count that (absent suspect/refuted) triggers a second pass. Floored at 1. |
| `monitor.skeptic.enforce_auto_decision` | `MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION` | `true` | When on (the default), an `auto`-mode wrap-up *fails* until the worker records a decision. Set false for advisory-only. |
| `monitor.skeptic.await_timeout_seconds` | `MONITOR_SKEPTIC_AWAIT_TIMEOUT_SECONDS` | `900` | Per-call `await` timeout. On timeout `await` exits 4 and the worker re-enters; it bounds a single blocking call (the loop heartbeats throughout). The re-entry happens only if the launch can re-invoke the worker — `run_in_background`, not `async-run.sh` (`#1523`). |
| `monitor.skeptic.await_interval_seconds` | `MONITOR_SKEPTIC_AWAIT_INTERVAL_SECONDS` | `5` | `await` poll interval (also the heartbeat cadence). |
| `monitor.skeptic.await_hang_seconds` | `MONITOR_SKEPTIC_AWAIT_HANG_SECONDS` | `600` | Hang-vs-wait threshold. A parked worker is exempt from idle flagging only while its pending-marker mtime is within this window; a marker stale beyond it lets a genuine hang resurface. |

---

## A stamped window doing worker work

The skeptic role is derived from the window's **provenance record**
(`skeptic_role: true`), and a window is stamped for its **lifetime**, not
for one task. A retained skeptic that later authors a patch therefore
hits the role gate on a wrap-up that is not a verdict at all.

**Do not invent a verdict to get past it.** If the window authored the
work being wrapped up, any verdict it supplies is a self-review written
against another window's markers — and downstream it is indistinguishable
from an independent clearance, which is precisely what this protocol
exists to prevent. Say the true thing instead
(`<your-org>/nexus-code#879`):

```bash
ng wrap-up <issue> <report> --repo <owner>/<repo> \
    --not-a-skeptic-verdict "<what non-skeptic work this window did>"
```

It runs the **ordinary worker wrap-up** from there — so your own work
gets the normal skeptic decision for its spawn mode — and records
`skeptic-role-not-asserted` with your reason. The reason is mandatory and
must be substantive (>=20 chars), the `GH_IMPERSONATE_REASON` shape: an
opt-out nobody has to justify is a way to dodge an obligation.

It **discharges nothing** — not the stamped target's marker, and not
**your own**. If you still owe a verdict you still owe it, that target
stays blocked, and so do you; file it separately with a
`--skeptic-role --skeptic-verdict <v>` wrap-up. When a producer branch
would have cleared your own marker (spawn mode `deny`, an explicit
`--skeptic-decision deny`, or an operator waive) the removal is
suppressed and wrap-up prints `SKEPTIC MARKER KEPT`, because an opt-out
is a statement about *this hand-off*, not a release of a *pending
obligation* (`<your-org>/nexus-code#879` F1 — this paragraph asserted the
right behaviour before the code implemented it). The flag is mutually
exclusive with `--skeptic-role` and `--skeptic-verdict`, and refused
outright on a window that was never stamped.

---

## Action-log events (audit + orchestrator integration)

All written to `monitor/.state/action-log.jsonl`:

- `skeptic-request` — a skeptic is required for `target-window` at `depth`.
- `skeptic-spawn` — a skeptic was dispatched (`window` reviews `target-window`).
- `skeptic-verdict` — a verdict landed (`verdict`, `target-window`,
  `findings-stated`, and `findings` only when a count was supplied — `#881`).
- `skeptic-decision` — an `auto`/`deny`/`waived` decision was recorded.
- `skeptic-role-not-asserted` — a skeptic-STAMPED window wrapped up
  ORDINARY WORKER WORK via `--not-a-skeptic-verdict` (`reason` is
  mandatory). See "A stamped window doing worker work" below.
- `skeptic-escalate` — issues persist at the depth cap; operator needed.
- `skeptic-nudge` — a worker was nudged about pending requests.

The `skeptic-pending` markers under `monitor/.state/skeptic/pending/`
are the orchestrator's gate: a window with a pending marker has produced
a result that has **not yet** been validated. The gate is **enforced in
code**, not merely advisory — `monitor/retire-preflight.sh` (the
mandatory synchronous pre-kill check, see `skills/nexus.window-cleanup`)
returns

```
safe=0 window=<w> pane=<state> reason=required skeptic marker is LIVE — refusing kill; if a verdict exists, use `ng skeptic resolve <window> --reason …`
```

— `retire-preflight.sh:emit()` formats `safe=%s window=%s pane=%s reason=%s`,
and this reason carries one further suffix when the ledger can be read:
` | evidence=<class>: …` from `_sk_ev_clause` (empty when the class cannot be
established, so do not match on it). While a marker is live, so the orchestrator cannot retire the window until
a skeptic returns a verdict (clearing the marker), an operator waives, or
`ng skeptic resolve` releases it on the record.

**One carve-out, and it is the one that lets a kill through.** An
**ORPHANED** marker — `_idle_skeptic_orphaned` says no live skeptic past
the grace — does **not** block: `retire-preflight` notes it on *stderr*
(so the single stdout verdict stays authoritative), prints the
`ng skeptic-evidence` class, and **falls through**. So "physically cannot
retire" holds for a live pairing, not unconditionally. When that note says
`ledger evidence: none`, the kill is about to STRAND the required
validation — read it before proceeding.

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
