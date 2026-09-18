---
name: nexus.agent-delivery
description: "The harness-neutral contract for delivering an instruction to an agent in a nexus, so agents of DIFFERENT harnesses can coexist in one nexus and the orchestrator can address any of them without knowing which harness it is. Pins four things: harness-neutral identity (the tmux window name), per-AGENT capability declaration (which transports reach it and what receipt each provides, including none), the common ledger (one stamp, one guard, one delivery record for every send `send.sh` carries, independent of transport and harness — with the `invoke: agent` exception, which escapes the ledger entirely, stated where the guarantee is made), and registration/discovery that never reads ~/.claude. Carries the EXCLUSIVITY RULE that makes a fallback chain safe against double delivery, and the measured reasons a Claude Code SendMessage cannot be a shell-invocable transport. Use when adding a transport or a harness, when sending to an agent from a script, or when reasoning about whether a delivery actually happened."
---

# Agent delivery — the harness-neutral contract

**Status.** The contract is implemented by `monitor/send.sh` (`ng send`) against
**one** harness, `claude-code`. Everything marked *UNVALIDATED* below could not be
tested, because a second harness does not exist in this nexus yet. Those parts are
proposals; the rest is measured. The distinction is kept explicit on purpose —
`<your-org>/nexus-code#1049` exists because a delivery claim was believed without a
receipt, and a spec nobody has built against is the same failure one level up.

Measurements below were taken on `dev` @ `a2cefa2`, Claude Code **2.1.246** —
and **every `path:line` citation below is pinned to `a2cefa2`, not to HEAD.**
Resolve one with `git show a2cefa2:<path> | sed -n '<n>p'`; `a2cefa2` is an
ancestor of `dev`, so it resolves in any clone. Re-verified against that commit
on 2026-09-09: `_idle_probe.sh:1481` is the `$3 == "paste-followup"` match,
`_idle_probe.sh:1964-1967` the four-column compaction, `paste-followup.sh:597-601`
the `isMeta`/`promptSource` classifier. All three have since MOVED (to `:1756`,
`:2239-2241` and `:658-667` at `a3177ef6`) while the constructs are unchanged —
so grep the construct rather than trusting a line against a newer tree.

## Why this exists

An orchestrator must be able to hand an instruction to an agent and find out
whether it arrived. Today there is exactly one way to do that (`paste-followup.sh`,
47 dependent files) and it is welded to tmux + Claude Code's hooks. A nexus that
hosts a second kind of agent — a different harness, in the same board, at the same
time — has no way to address it, and no way for the delivery guard to see it.

The guard is the point. `_idle_unconfirmed_paste_epoch` is what catches a lost
instruction, and it is keyed on a **string in a ledger column**. Anything that
writes a different string is silently exempt. So the danger of adding transports is
not that a new one fails — it is that a new one **succeeds at bypassing the guard**,
and the symptom is an absence.

## 1. Identity — the tmux window name

**An agent is addressed by its tmux window name.** Not a session id, not a pid, not
a socket path. A window name is harness-independent by construction: it is assigned
by the nexus at spawn, it is stable across a respawn, and it is what `pane-state.sh`,
`paste-followup.sh` and `retire-preflight.sh` already key on.

Measured, not assumed: `#1047`/`#1048` merged at `2d32449` ("name a session after
its tmux window, so a respawned orchestrator stays addressable"), and the live
registry agrees — this window is `ngsend` and its Claude Code session record carries
`"name": "ngsend"`.

A conforming harness MUST accept the window name as the address. How it maps that
name onto its own internal handle is the adapter's business.

### The uniqueness boundary — stated, because an undocumented one is a false promise

This contract makes the window name the address, so it owes you a statement of
where that address is guaranteed unique. **It is unique among LIVE tmux windows in
THIS nexus, and nowhere wider.** `monitor/spawn-worker.sh` enforces exactly that,
refusing a colliding name with **exit 7**.

**A transport whose address space is wider MUST disambiguate, and `cc-sendmessage`
is such a transport.** A retired window frees its name — deliberately, and
`#73` D2 built structural support for reusing it — but the harness's peer set has
included those retired names, surfaced as the operator's sessions on other
machines. Measured 2026-08-27: **13 addressable peers against 8 live windows**, one
of them `fig4e-skeptic`, a retired nexus name that a fresh `-n fig4e-skeptic` would
have re-issued. The name would then denote two entries at once.

**The residual check is an ORCHESTRATOR obligation, not a script's, and that is a
capability fact rather than a preference.** The peer list is available to an AGENT;
there is no command `spawn-worker.sh` could run to enumerate it. So the script does
what it can see — it refuses a live collision, and since `#1081` it also NOTES when
the name has been used in this nexus before, reading the durable
`monitor/.state/windows/<key>.json` records rather than the ~20 live windows. It
warns rather than refusing, because refusing every previously-used name would break
the supported recycle workflow.

**And that check is only as durable as the surface it reads.** Its first version
keyed solely on `monitor/.state/windows/<key>.json` — which is a member of
`BK_RETIRE_SURFACES`, so `ng retire-window`, the verb this workspace tells the
orchestrator to PREFER, **deletes it**. Coverage would have shrunk exactly as
operators adopted the preferred verb, and a properly retired name would read as one
never used. It now keys on `monitor/.state/action-log.jsonl` first, which is
append-only and not a retire surface, with the `windows/` record as a second
witness. Verified: the retired name `fig4e-skeptic` has 6 action-log entries and is
caught.

The residual boundary is still real and is worth stating plainly rather than
implying it away: **the log is the record of THIS nexus.** A name that was never
spawned here — an agent registered by another operator, a session on another
machine — leaves no trace in it, so the local check cannot see that half of the
address space at all. That is the same gap the orchestrator obligation below
covers, and it is why the obligation is not optional.

Before relying on a recycled name as a delivery address, the orchestrator MUST
enumerate peers and confirm exactly **one** row bears it. **READ-ONLY**: rows that
are the operator's own sessions on other machines are enumerable but MUST NOT be
messaged.

**What is still unmeasured**, and it is one experiment: how the harness RESOLVES an
ambiguous name — refuse, prompt, or silently pick one. Its own documentation says a
bare name is insufficient when two rows share it, which suggests it fails loud; if
that holds, the impact is a REFUSED delivery rather than a MISDIRECTED one. Nobody
has constructed the collision between two entries they own and watched it resolve.
Until someone does, treat a duplicate as capable of misdirecting.

Note the gap is not constant. Re-measured 2026-09-01 on this nexus: **18 addressable
peers, 20 live windows, and the set difference in the hazardous direction was
EMPTY** — every addressable peer was a live window, with `orchestrator` and
`services` live but not addressable (the harmless direction). So the collision is
constructible but not always present, and a spot check that finds no gap has
established nothing about another moment.

## 2. Capability — declared per AGENT, never assumed per nexus

In a mixed nexus the orchestrator may assume **nothing** is universal. The only
universal is what each agent declares.

Capability is resolved by a **harness adapter**, `monitor/harness/<harness>.sh`,
rather than stored in the descriptor. Storing a transport list would let it go stale
the moment a session dies — and a stale capability list is a confident wrong answer,
this workspace's dominant defect class. The adapter is asked at send time.

### The adapter contract

```
monitor/harness/<harness>.sh transports <window>
    → zero or more lines:  <name>\t<invoke>\t<receipt>\t<stamps>
      in PREFERENCE order, most-preferred first.

monitor/harness/<harness>.sh liveness <window> <transport>
    → rc 0  reachable
      rc 1  PROVABLY unreachable   (this is what licenses a fallback)
      rc 2  unknown                (never licenses a fallback)

monitor/harness/<harness>.sh send <window> <transport> <payload-file> <nonce>
    → performs a SHELL-invocable send; exit code per §5.
```

### `invoke` — the distinction that is easy to miss

- **`shell`** — a command a script can exec. **Only these can participate in an
  automatic chain**, because the watcher is a bash process with no tools.
- **`agent`** — reachable only from inside a running agent's own tool loop.
  `ng send` **cannot** invoke it. It can only stamp for it, via `--stamp-only`
  (§3 — the ledger; *not* §4, which is the nonce). A raw in-loop send that
  skips that stamp writes **no ledger row at all**; see §3's exception table.

This is not hypothetical, and it is the single most consequential finding here.
**Claude Code's `SendMessage` is `invoke: agent`.** Measured: `claude --help` at
2.1.246 offers `agents, auth, auto-mode, doctor, gateway, import, install, mcp,
plugin, project, setup-token, ultrareview, update` — **there is no `send` or
`message` subcommand**. The transport exists only as an in-process tool.

The private unix socket in the session registry (`messagingSocketPath`,
`/run/user/<uid>/cc-socks/<pid>.sock`) is *not* the loophole. It waits for the
client to speak first and publishes no frame format; the constants are not
recoverable from the 248 MB native binary (`grep -ao` over it yields the bare
strings `"sendMessage"`/`"SendMessage"` and no protocol). Reverse-engineering a
private IPC to carry production instructions would also be a cc-version-sensitive
surface of the exact kind `skills/nexus.cc-update` exists to police. **Not built,
deliberately.**

### `stamps` — who writes the ledger row

`self` means the transport stamps for itself; `caller` (the default) means
`monitor/send.sh` must stamp before invoking it.

The field exists because the answer is genuinely not uniform, and **the
implementation forced it**: `tmux-paste` runs `paste-followup.sh`, which stamps
before its own send and `die`s if that fails (`#665`). Stamping again in
`send.sh` would put **two rows in an append-only ledger for one send**, and the
watcher takes the max epoch per window — so the second row would move the
attribution instant off the moment the send actually began, which is the
precise false positive `#665` was filed to remove.

**`caller` is the default, and that direction is not arbitrary.** An adapter
that declares nothing gets stamped rather than silently exempted. A missing
field must never be the permissive arm, or the first harness whose author skips
the field re-opens the hole this contract exists to close.

`stamps: self` is legal **only** for a transport that writes the guard key
itself. `send.sh` never passes `--src` to `paste-followup.sh`, so its default
(`paste-followup`) stands.

### `receipt` — and `none` is a legal value

| receipt | meaning |
|---|---|
| `submit-stamp` | the peer wrote `<state>/user-prompt/<window>` = `epoch<TAB>session-id`, advancing past our epoch |
| `harness-ledger` | the peer's own transcript recorded a submission |
| `none` | the transport can produce no evidence of arrival |

**`submit-stamp` is the standard's receipt, and it is already harness-neutral.**
It is written by a *nexus-installed hook*, not by Claude Code: the hooks block
lives in **`monitor/worker-settings.json`** — which every spawn passes as
`claude --settings` (`spawn-worker.sh:21` is the comment that says so, not the
carrier) — and its `UserPromptSubmit` entry runs
`monitor/worker-heartbeat.sh user_prompt`, which writes
`<state-dir>/user-prompt/<window>` (`worker-heartbeat.sh:144`). A new harness
conforms by emitting that one file; it inherits the receipt, the guard and
the confirmation logic for free.

`harness-ledger` is **not** available to a cross-session message, and this was
measured rather than assumed (`#1049` constraint 2, re-verified at `a2cefa2`):
cross-session messages carry `promptSource: system` and `isMeta: true`, and the
classifier at `paste-followup.sh:597-601` rejects both — `select((.isMeta // false)
| not)` and `.promptSource != "system"`. `system` is the same bucket as
`<task-notification>`, so the exclusion is deliberate and not tunable.

**So a non-tmux transport confirms on ONE surface instead of two, and loses
specifically the one `paste-followup.sh` calls authoritative.** Stated here rather
than discovered later.

**`submit-stamp` IS NEVER WRITTEN FOR A QUEUED PASTE, so on that path it is not
a slow receipt — it is an absent one (`<your-org>/nexus-code#1099`).** The file is
written by the receiver's `UserPromptSubmit` hook, and a paste consumed out of
the QUEUE by an already-running turn does not fire it. Measured on two
independent sends in one hour: each window's stamp still read its SPAWN time
long afterwards and the file had never been rewritten, while one receiver had
quoted the pasted text back in its own report. `--check` therefore returned
`unknown` **terminally**, and its own "re-check" instruction named a loop that
could not exit on success. That is the shape this standard warns about
everywhere else: a PROXY (a hook fired) standing in for the PROPERTY (the bytes
reached the agent), sound on the path it was designed against and silently
absent on the path that happens when the board is busy.

**The second receipt — `content-digest`, and it is MESSAGE-scoped.**
`paste-followup.sh` records `digest=` (sha256 over the canonical bytes) in the
epoch-keyed sidecar BEFORE pasting, and `monitor/_submit_evidence.sh`'s
`se_submission_with_digest` matches it in the receiver's own transcript across
BOTH delivery spellings — a `type:"user"` submission and a
`queue-operation`/`enqueue`. The queued path produces the latter, so this
surface answers where `submit-stamp` cannot. `ng send --check` consults it
FIRST, because a hit is evidence about **this message** rather than about the
window (§5.1).

Two boundaries, both declared rather than discovered:

- it exists only for a send that recorded a digest — today, `tmux-paste`. Any
  other transport still confirms on `submit-stamp` alone;
- `enqueue` is **arrival**, not consumption, so a paste that was delivered and
  then CANCELLED out of the queue reads as delivered. There is no discriminator
  in the measured record set: `queue-operation`/`remove` fires for consumption
  and cancellation alike, and no `type:"user"` record is written when a queued
  message is consumed. This is tolerable **because of the licence, not the
  likelihood** — rc 0 and rc 3 permit the same action (no fallback), only rc 4
  licenses one, and no digest verdict can produce rc 4. So a false positive here
  cannot double-deliver; its whole cost is that a caller stops polling a message
  somebody deliberately cancelled.

A digest `no` never licenses a fallback either: it means "these bytes are in no
delivery record over the SCANNED RANGE", which is consistent with a paste
sitting unsent and with reading the wrong transcript. It sharpens the rc-3
diagnostic and changes no verdict.

### `none` is not "fast and silent" — it is ASYNCHRONOUS, and one observed delivery took FIVE MINUTES

`none` says the transport produces no evidence of arrival. It is read as though
it also said the send is *prompt* — so a sender waits, sees nothing, and
concludes the message was dropped. **That conclusion is unfalsifiable from the
sender's side, because an in-flight message and a lost one are the same absence**
(`<your-org>/nexus-code#1272`). This is the workspace's dominant defect class
arriving in the delivery path: silence used as a proxy for a negative.

Measured, one observation: a probe sent at 14:16 returned `success:true` with a
`msg_id` and **arrived at 14:21** — roughly five minutes and several intervening
turns later. Not lost. Queued.

**NO UPPER BOUND IS CLAIMED, and the five minutes must not be read as one.**
It is a single observation of a single delivery, not a distribution, not a
ceiling, and not a timeout to wait out. What it establishes is a lower bound on
how wrong "I saw nothing, therefore it was lost" can be — nothing more. A sender
that needs to KNOW must use a transport with a receipt (§2), not a longer wait.

**It is also the more parsimonious explanation for a loss claim already on this
board.** A report alleged a lossy subagent channel — *"all 20 subagent final
outputs failed to reach the parent"*. Twenty results that were merely SLOW
present exactly as twenty that were LOST, and nothing in the sender's view
separates them.

An attempted reproduction of the loss claim found **14 of 14 subagent final
outputs delivered inline, zero losses**, across 1-call/~6 s probes, an 8-wide
single-message fan-out, and two 80 s / 26-tool-call probes. So duration does not
detach a subagent into a lost-output path **at 80 s**.

**The reported regime — roughly 20 concurrent, many-minute subagents — is
UNTESTED. This is not a refutation of the loss claim; it is a competing simpler
mechanism that has to be excluded before loss is concluded.** Stated in that
direction on purpose: "14/14 delivered" over a smaller, shorter population is a
claim about the population measured, exactly as a green is a claim about the
tree tested.

Two corrections, both of which INVERT the natural reading and are the reason
this is worth writing down rather than filing as a latency note:

- **`success:true` DOES discriminate a reachable recipient.** A fabricated name
  returns `success:false`; a near-miss returns `success:false` with a
  did-you-mean. There is **no silent-accept path**, and an earlier inference of
  manufactured success was wrong. So the send-time answer is real information —
  about EXISTENCE.
- **The reachable set is WIDER than the system-reminder roster.** Absence from
  that listing is **not** evidence of non-existence, and the fuzzy-match
  suggester leaks the names of unrostered peers. A sender that treats the roster
  as the address space will refuse to address agents it can in fact reach.

**Existence validation at send time is NOT a delivery receipt.** The two answer
different questions — "is there someone at this address" versus "did these bytes
arrive" — and conflating them is how `success:true` gets read as delivery. That
is exactly the `none` class doing what it says: this transport's receipt is
`none`, and a truthful `success:true` does not change that.

The standing direction, unchanged: either surface a receipt, or document the
envelope so that *"I saw nothing"* is not read as *"it was lost"*. This section
is the second, and it is the weaker of the two.

## 3. The common ledger — one stamp, one guard

Every delivery attempt **that `monitor/send.sh` carries** — by any transport, on
any harness — writes **one** row to `monitor/.state/machine-input.tsv`:

```
<window>\t<epoch-micros>\t<guard-key>\t<admin>
```

**Column 3 is a SELECTOR, not a label, and conforming writers MUST write the literal
`paste-followup`.** `_idle_unconfirmed_paste_epoch` (`_idle_probe.sh:1481`) matches
`$3 == "paste-followup"` **exactly**; anything else is invisible to the
`paste-unconfirmed` detector. Verified still true at `a2cefa2`.

This is `#1049`'s constraint 3, and under a pluggable design it inverts into the
load-bearing insight: **the guard key is fixed by the ledger writer, not chosen by
the transport.** If each transport picked its own token, every new harness would
have to remember a magic string or patch a matcher — and the one that forgets is
silently exempt, which is exactly the hole this contract exists to close. Because
`monitor/send.sh` writes the column and no transport can override it, the guard's
**VALUE** is structurally inescapable rather than conventionally respected.

### The exception, stated here because this is where the guarantee is made

**"Structurally inescapable" is a claim about the guard key's VALUE, not about
ROW COVERAGE — and the difference is not academic, because the transport that
escapes coverage is the one this contract names as the Claude Code peer's
preferred one.** An `invoke: agent` transport (§2) cannot be executed by a shell
caller at all, so `monitor/send.sh` never carries it and therefore never stamps
for it. Two distinct paths follow, and only one of them lands a row:

| path | row written? |
|---|---|
| `ng send … --transport cc-sendmessage --stamp-only`, then the agent performs the send from its own tool loop | **yes** — but only because the caller *chose* to stamp first |
| a raw agent-to-agent `SendMessage`, issued directly from a tool loop | **NO ROW AT ALL** |

The second path is not exotic; it is what an agent does by default, because
`SendMessage` is simply a tool in its loop and nothing in the loop routes through
`send.sh`. Measured (`skills/nexus.tmux-spawn`): **six `SendMessage`s to a worker
produced zero ledger rows; two `paste-followup.sh` calls to the same worker
produced two.**

So for `invoke: agent` the guard is **conventionally respected after all** — it
holds exactly as far as the sending agent remembers `--stamp-only`. The
consequence is the one `monitor/send.sh`'s header spells out: an unstamped send's
submit reads as **operator input**, the delivery guard never sees it, and the
`paste-unconfirmed` detector cannot fire for a delivery it has no record of.

**The ledger can NAME this gap, per window** (`<your-org>/nexus-code#1368`). An
auditor counting rows for a window read 8 evidenced deliveries against 7 rows and
nearly published "the correction never propagated" — because to a reader, a
missing row and a row a transport never writes are indistinguishable. Ask the
ledger's writer before reading its silence:

```
ng send <window> --ledger-coverage     # rc 0: every declared transport stamps a row
                                       # rc 3: an invoke=agent transport is declared —
                                       #       a MISSING ROW IS NOT EVIDENCE of no send
```

It answers from the same harness descriptor every send reads, one line per
declared transport (`row=yes` / `row=NO-ROW unless … --stamp-only`), and names
which `machine-input.tsv` it is talking about. It is a QUERY, deliberately not a
file beside the rows: coverage is a property of the window's declared transports,
not of any row, so a stored copy would go stale the moment a descriptor changed
and would be an unmanifested per-window surface to `bk_state_refs_unmanifested`
at every retirement.

**And WHICH ledger is not a free choice either** (same issue, reopened). `send.sh`
used to resolve its state dir with a private three-arm resolver ending at its own
script-relative `.state` — so a send from a secondary clone under
`<primary>/work/` stamped the CLONE's ledger: the fail-loud stamp succeeded, the
delivery went out, and the primary's ledger had no row. A fail-loud stamp into
the wrong ledger is a silent failure of the ledger. It now resolves the PRIMARY
through `monitor/_nexus-root.sh`, the one resolver `ng`, `upload-asset.sh` and
`watcher-supervise-tick.sh` share, and EXPORTS the answer as `NEXUS_ROOT` to the
adapter and its children — because the shipped shell transport execs
`paste-followup.sh` (`stamps: self`), which resolves a state dir of its own, and a
send.sh-only fix would have moved the sidecar to the primary while the row still
landed in the clone. Measured both ways by
`monitor/watcher/test-send-ledger-primary.sh`, which runs paste-followup.sh's real
resolver text in the child environment. A missing `_nexus-root.sh` is a refusal,
never a fall-through to the old arm.

**This is a property of `invoke: agent`, not a Claude Code quirk**, so any future
harness whose preferred transport is in-process inherits it. It is why §2 makes
`stamps: caller` the default and why `receipt: none` is a legal declaration: the
contract's honesty depends on a transport declaring what it genuinely cannot do,
rather than on a guarantee stated more broadly than it holds.

The historical name is kept. Renaming it would be a breaking change across the nine
files that match it and buys nothing; read it as *"machine-injected input, subject
to the delivery guard"*.

### Per-send facts go in the epoch-keyed sidecar, NOT in new columns

`monitor/.state/paste-verdicts/<window>.<epoch>`, `key=value` lines:
`digest=`, `outcome=`, `rc=`, and (added here) **`nonce=`** and **`transport=`**.

This placement is forced, and checking it caught a real trap. The ledger's
compaction (`_idle_probe.sh:1964-1967`) rebuilds surviving rows as **exactly four
columns** — `print w, m[w], s[w], a[w]` — so a fifth or sixth column would be
**silently dropped once the ledger passes 200 lines**, i.e. only on a busy board,
which is both the hardest case to reproduce and the one where a lost delivery costs
most. That is the same hazard `#683` documents for column 4 and the same reasoning
`#676` used to put the verdict in a sidecar: **column 4 is a property of the
window's newest machine input; a nonce is a property of one send.** Per-send facts
do not belong in a structure that keeps one row per window.

Consequence: this contract needs **no edit to `_idle_probe.sh`** at all.

## 4. The nonce, and why it is not the double-delivery defence

Every send carries a nonce, recorded in the epoch-keyed sidecar. It makes "did
this agent get instruction X twice?" answerable after the fact, and it is the
key `--check` uses to find the send it is polling for.

**The nonce is recoverable after the fact; losing it is not a reason to re-send**
(`<your-org>/nexus-code#1367`). `UNKNOWN` is the NORMAL outcome on a busy board
(7 of 8 measured UNKNOWNs had in fact been delivered), and the nonce was printed
on stdout alone — the stream a broadcast loop does not capture and a verdict-line
`grep` discards. With no nonce there was no way to resolve the UNKNOWN, and the
path of least resistance from "I cannot check" was "send again": the issue's own
author did exactly that within the hour of filing it. The sidecar had recorded
the nonce since `#1049`; nothing read it back. Now:

```
ng send <window> --check --last      # the NEWEST ng-send record on that window, nonce read back
ng send <window> --list              # every record, newest first: epoch= time= nonce= transport= outcome=
ng send <window> --check --nonce <hex>
```

`--last` selects the newest record that CARRIES a nonce; a direct
`paste-followup.sh` paste writes a sidecar without one, and `--last` says so on
stderr when such a record is newer. Neither flag sends anything — resolving an
`UNKNOWN` must never become a fallback, and every `UNKNOWN` line `send.sh` prints
now says "Do NOT re-send" beside the two `--check` forms.

**As implemented it is an AUDIT key and nothing more, and that limit is worth
stating plainly.** The nonce is **not** injected into the payload, so the
receiving agent never sees it and **receiver-side dedupe is not available
today**. Adding it to the payload is possible for `tmux-paste` and would change
the bytes the agent reads, which is a decision about message format rather than
about delivery — deliberately not taken here.

So the nonce is **not** the double-delivery defence, and must not be described
as one. Receiver-side dedupe would need receiver cooperation a foreign harness
may not offer, which is why the actual defence is structural and needs nothing
from the receiver at all:

> ### The exclusivity rule
> **Advance to the next transport ONLY on an ESTABLISHED negative. On `unknown`,
> STOP and report `unknown`. A fallback fires on a proven non-delivery, never on an
> absent confirmation.**

A negative is established two ways, and only two:

1. the transport's own receipt reports an established negative (for `tmux-paste`,
   `paste-followup.sh` rc **4** — Enter retried, budget elapsed, session completely
   inert); or
2. the transport's **liveness probe** returns rc 1, *provably unreachable*.

Everything else — including a send that returned success — is `unknown`, and
`unknown` never chains.

**The rule is scoped to a MESSAGE, not to an agent — and getting that wrong is
how a correct rule still produces a double delivery.** "Is a fallback licensed?"
must be asked of **the transport that carried this message**, never of the
transports an agent happens to declare. `ng send --check` shipped asking the
second question: it probed every declared transport and licensed a fallback when
*any* was provably dead, including one that never carried the send. The sidecar
recorded `transport=` and the check discarded it. Measured end-to-end against a
real live socket: carrier `cc-sendmessage` **live**, sibling `tmux-paste`
**PROVEN-DEAD**, verdict `not-delivered` — a false established negative, licensing
a second copy of a message still in flight.

The rule itself was never breached; the hazard arrived through a helper answering
a question about the wrong noun. **A guard scoped to the wrong noun is not a
weaker guard — it is a guard on something else.** So: record the carrier at stamp
time, read it back when judging, and when it was not recorded report `unknown`
rather than probing whatever is to hand. An explicit transport may NAME the
recorded carrier; it may never replace it.

This is what makes the fallback safe without receiver cooperation, and it is why
`#1049`'s `success:true` measurement matters so much: a send to a **SIGKILLed** peer
returned `success:true` with a `msg_id` and no receipt, ~3 minutes after the kill.
Under this rule that outcome is `unknown` and the chain **halts**, rather than
pasting a second copy of an instruction that may yet arrive.

**The cost is honest and must not be papered over:** a transport with no receipt and
no liveness probe can never license a fallback, so a chain that begins with one is
useless. That is not a defect in the rule — it is the rule making a real limitation
visible instead of trading it for a double execution. A duplicated instruction has
produced duplicate comments and duplicate commits on this board; a fallback whose
failure mode is double execution is strictly worse than the single-transport status
quo it means to improve.

**Where the liveness probe pays for itself.** For `claude-code`, a zero-byte
`connect()` to the session's `messagingSocketPath` distinguishes live from dead
*without knowing the protocol*: measured on this host, pids 18555 and 35683 (dead
sessions) both give `ECONNREFUSED`, while the live pid 27835 accepts. That converts
the `success:true` case above from `unknown` into an established negative, which is
what lets an `agent`-invoked SendMessage safely fall back to a paste. Single
measurement class, one harness, and the standard does not depend on it — an adapter
that cannot answer returns rc 2 and simply never chains.

## 5. Verdicts

| verdict | rc | scope | meaning |
|---|---|---|---|
| `delivered` | 0 | **the WINDOW** | a receipt was observed — **never merely "the send call returned 0"** |
| `unknown` | 3 | — | neither delivery nor non-delivery established — **chain halts** |
| `not-delivered` | 4 | **the MESSAGE** | established negative — **chain may advance** |
| refused | 1 | — | usage, no such window, dead pane, unstampable ledger |

### The two codes DO NOT share a scope, and an implementer must know which is which

**`rc 4` is message-scoped. `rc 0` is not — it is a property of the window's LAST SUBMISSION.**
Read that asymmetry before relying on either.

The receipt surface is `<state>/user-prompt/<window>`: one epoch per **window**. Any submission
after our epoch satisfies it, so with two outstanding nonces on one window and **one** actual
submit, `--check` reports `delivered` for **both**. Measured. One of those two messages was
never delivered and its sender is told it was — and the line even names the nonce
(`delivered … (nonce %s)`), implying a message-scoped confirmation it does not have.

This is **structural, not incidental**: §4 records that the nonce is not injected into the
payload, so the receipt surface genuinely cannot tell two messages apart. Closing it means
changing the message format, which this contract deliberately declines. It is written down
rather than fixed.

**Which direction it fails matters, and it is the safe one for the hazard this contract is
built around.** `rc 0` *stops* a fallback, so it cannot manufacture a double delivery. It
produces the opposite error — a message silently lost while its sender believes it arrived.
That is real, and it is the other half of `#1049`'s origin class, but it is not the failure the
exclusivity rule exists to prevent.

**So the class "answer about the MESSAGE, not the window" is half-closed**, and a conforming
implementation must not assume otherwise: treat `rc 0` **from the submit-stamp** as *"this
window submitted something after your send"*, and `rc 4` as *"the transport that carried YOUR
message is provably unreachable"*.

**§5.1 — the OTHER half is now closed for any send carrying a content digest
(`<your-org>/nexus-code#1099`).** `--check` asks `content-digest` (§2) before the
submit-stamp, and a hit there IS message-scoped: sha256 over the exact canonical
bytes cannot be satisfied by unrelated content, so it answers the question the
caller asked rather than a question about the window. The paragraph above still
holds verbatim for every send WITHOUT a digest, and for a digest that answers
`no` or `unknown`. When the stamp advances but the digest says the bytes are
absent, `--check` still exits 0 — the licence ("stop; do not fall back") is
correct under either reading — and says so on stderr, so the two-nonce hazard
above is visible rather than silent.

The residual gap is unchanged in shape: a harness whose transport records no
digest still needs an identifier the receiver echoes, which this contract does
not yet define.

**A caller-supplied `--transport` is a claim, never evidence.** `--check` refuses it when it
disagrees with the recorded carrier, and reports `unknown` when no carrier was recorded at all —
otherwise a named-but-unverified transport that happened to be dead would yield `rc 4` asserting
`the CARRYING transport <x>` about something nothing established had carried anything.

`ng send` reports the per-transport trail and the final verdict, and never reports a
verdict stronger than what it established.

**That last clause is enforced, not merely asserted.** A `shell` transport that
declares `receipt: none` and returns 0 reports **`unknown`**, not `delivered` —
because `none` means *this transport can produce no evidence of arrival*, and rc 0
then says only that the send call returned. This is the clause a second harness
exercises first, and the implementation shipped violating it: `receipt` was parsed,
plumbed and printed in a diagnostic, and never reached the verdict. Latent for the
one existing harness, live with the first new one — i.e. the moment the standard
starts being used. A contract whose only implementation cannot violate it has not
been tested.

`--check` is scoped the same way: it answers about the **carrying** transport, so
its rc 4 means *that* carrier is provably unreachable, not that something the agent
declares is.

## 6. Registration and discovery — never `~/.claude`

An agent is discoverable through the **nexus-owned** descriptor
`monitor/.state/windows/<window>.json`, written by `spawn-worker.sh` at spawn. It
gains one field:

```json
{ "window": "ngsend", "harness": "claude-code", ... }
```

Harness resolution, in order: descriptor `.harness` → config
`monitor.default_harness` → `generic-tmux`.

**Explicitly out of bounds for the standard:** `~/.claude/sessions/*.json`,
`messagingSocketPath`, `peerFeatures`, `peerProtocol`, the transcript layout under
`~/.claude/projects/`. Every one of those is *one harness's implementation* of a
contract point, and belongs in `monitor/harness/claude-code.sh` and nowhere else.
A future reader should be able to grep the nexus for `.claude` and find it only
inside that adapter.

## 7. Graceful degradation — the conclusion varies, the citizenship does not

`generic-tmux` is the **terminal element of every chain**: it reaches anything with
a pane, needs no harness cooperation, and is why the chain always has a last
resort. It declares `receipt: submit-stamp` when the agent's hooks write the stamp
and `receipt: none` otherwise.

An agent that declares no receipt at all is still first-class. It is addressed the
same way, stamped the same way, and guarded the same way. The only thing that
changes is what the orchestrator may **conclude**: sends to it report `unknown`
rather than `delivered`. A no-receipt agent is not second-class; it is an agent
about which less is knowable, and the contract says so out loud instead of
inventing a confirmation.

## 8. Conformance checklist for a new harness

1. Accept the **window name** as the address.
2. Ship `monitor/harness/<name>.sh` implementing `transports` / `liveness` / `send`.
3. Emit the `submit-stamp` (`<state>/user-prompt/<window>`) on accepting input — or
   declare `receipt: none` and accept that sends report `unknown`.
4. Never write column 3 yourself; `monitor/send.sh` owns the guard key. If your
   transport genuinely must stamp (because it stamps before its own send, as
   `paste-followup.sh` does), declare `stamps: self` **and** write the literal
   guard key. Otherwise declare `caller` or nothing.
5. Return rc 1 from `liveness` **only** when unreachability is proven. rc 2 when
   unsure. A wrong rc 1 is what manufactures a double delivery.
6. Keep every harness-specific path inside your adapter.

## What is UNVALIDATED

- The adapter contract has one implementation plus a generic fallback. **No second
  harness has been written against it**, so its sufficiency is a proposal.
- `generic-tmux` is exercised against Claude Code panes only; whether a foreign
  harness's REPL tolerates the VI-safe bracketed-paste sequence is untested.
- Harness resolution precedence is asserted, not exercised against a mixed board.
- The `invoke: agent` latency envelope is ONE observation (~5 min). The regime the
  loss claim describes — roughly 20 concurrent, many-minute subagents — is
  UNMEASURED, and no upper bound on delivery latency has been established.
- Whether a foreign harness can emit the `submit-stamp` at the right instant
  (before its own turn begins) is untested and is the likeliest place this contract
  breaks first.

## Reading order

`monitor/send.sh` is the implementation; `monitor/paste-followup.sh`'s header is
still the authority on the tmux transport itself and on why confirmation is not the
send's return value. `<your-org>/nexus-code#1049` carries the original measurements.
