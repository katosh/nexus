# RFC — inbound agent channels: a watcher-mediated request inbox, signal-source standardization, confined remote access, and the bidirectional client↔orchestrator protocol over SSH

**Status:** 🟡 PROPOSAL — review-first, **nothing implemented**. This is the
"thorough review, then clean design" the operator asked for: a self-contained
context document a future developer can read to understand *why* the inbound
channels are shaped the way they are, and to extend them without drift.
**Baseline:** `dev` @ `f6d6a25`. **Scope:** four coupled asks — a unified
request-inbox channel (Part B), a standardization of the watcher's signal
sources (Part C), authenticated remote access into the running sandbox
(Part A), and the **full bidirectional request/reply protocol** a remote SSH
client uses to file a request *and* detect, read, and follow the orchestrator's
reply (Part D — the round-trip the operator asked be made concrete and
implementation-ready). **Decision gate:** the operator greenlights (or amends)
the design before any code lands. Parts that touch
[`katosh/agent_sandbox`](https://github.com/katosh/agent_sandbox) (the kernel
sandbox layer) are **proposed here, not implemented** — that repo is public,
has no bot install, and is the operator's call.
**Validation:** an independent adversarial **skeptic pass** reviewed this RFC and
returned **`credible`** — boundary preserved, inbox backlog-safe, harmony real,
Part C coherent, ~14 review citations verified accurate — with three minor
implementation-time refinements, now folded in (§2.5 ack idempotency, §2.6
act→ack action idempotency, §4.2 forced-command test mandate).

> **Reading order.** The design is presented **B → C → A → D**, not in the
> request's A/B/C order, because **C generalizes B** (the request inbox is one
> instance of a standardized signal channel), **A is largely orthogonal** (it
> reuses the Part B channel as its *only* write primitive but is otherwise a
> separate security surface), and **D builds on all three** (D is the end-to-end
> round-trip: a remote client lands via A, files via B, and reads a reply written
> back through a return path that extends B's lifecycle). The
> [executive summary](#executive-summary) addresses A/B/C in the operator's order
> and then D; the [current-architecture review](#1-current-architecture-the-review)
> grounds everything in citations first.

---

## Executive summary

**Part A — confined remote access.** A client on the LAN (e.g. another Claude)
should authenticate and land **inside the running sandbox**, attach to the tmux
session, and talk to the orchestrator through the existing prompt-injection
machinery — and **nothing more**. The defining insight from the review: the
tmux session lives **inside** the `bwrap --unshare-pid` namespace
(`launcher.sh` creates session `nexus` inside the sandbox), so the cleanest
confinement is to **run an SSH server *inside* the sandbox**. A successful login
is then confined by the kernel sandbox *by construction* — it inherits exactly
the writable-path set (`$SANDBOX_PROJECT_DIR` + `~/.claude/`) and the pid/mount
namespace that a local in-sandbox agent already has. We further constrain the
principal with a forced command so it can do **only** "attach read-only to tmux"
and "file a request into the Part B inbox," never an arbitrary shell. The
sandbox boundary is **preserved, never weakened**; any design element that would
require loosening it is flagged out-of-bounds. The endpoint is a **registered but
OFF-BY-DEFAULT supervised service** (a `services.registry` row + healthcheck +
`monitor/remote-up.sh`, modelled on the jupyterlab service), where **registration
is the single enable signal** (no separate config flag) the **orchestrator turns
on by direct action** — `monitor/remote-up.sh` to enable, `--down` to disable
(§4.8). The in-sandbox command filter is a config choice (`command_policy`:
`channel-only` default, or `unfiltered` for a sandbox-confined shell). All **secret material** (host key, client keys, a
one-time enrollment token, any password) is provisioned **strictly out-of-band —
never on GitHub** (direct Claude Code output or an operator-only `0600` file),
with the private key never leaving the client and the token single-use + TTL'd
(§4.9). The operator gets a precise client-side **setup runbook** (§4.10). This
part is proposed against `agent_sandbox` and is the operator's decision.

**Part B — watcher-mediated request inbox.** Today a worker that wants something
from the orchestrator (canonically: "please spawn a skeptic") has no first-class
channel — it relies on the orchestrator polling files or on an ad-hoc paste.
We propose a single **inbox of markdown request files** under
`monitor/.state/requests/`, watched by the **watcher** (the component that
already owns the only hardened, verified write into the orchestrator pane). The
watcher claims each request by an **atomic rename** (the lock), surfaces it in
its normal emit as a `--- requests ---` section, and **re-emits until the
orchestrator acks** by renaming the file — the exact GitHub-comment 👀-gate model,
already implemented for cross-repo mentions in
[`_reemit.sh`](#13-the-re-emit-until-acked-resurface-mechanism) and for
[pending decisions](#14-the-pending-decisions-channel). The schema and the
"rename **is** the signal" lifecycle are deliberately **harmonized with the
existing skeptic↔worker convention** ([`skeptic-channel.sh`](#15-the-skepticworker-channel))
— same atomic-rename primitive, same markdown-with-frontmatter shape — so this
is a *generalization* of conventions already in the tree, not a competing
scheme. The result is stable under backlog: many requests queue, none are lost
(durable files + re-emit), none are double-processed (claim-rename + ack-rename
are atomic), and the orchestrator drains at its own pace.

**Part D — the bidirectional request/reply protocol over SSH.** The operator's
follow-up makes the *return path* first-class: not just "a remote client can file
a request" (Part B) but the **full round-trip** — place a request, **detect** that
a reply landed, **read** it, and **follow the work to completion**. The design
extends Part B's lifecycle with a single new state, `.replied.md`: the
orchestrator writes its reply **into the originating request file** (a `## Reply`
section + structured `reply:` frontmatter) and signals completion by the **same
atomic rename** the skeptic channel uses for `.answered.md` — "the rename is the
signal," reused verbatim. The client **correlates** by the stable request id
(`ng request file` prints it on stdout) and **detects** the reply by polling for
the `.claimed.md → .replied.md` transition (a server-side blocking `ng request
await` verb, mirroring the skeptic channel's `await-answer`). The reply **carries
references** so the client can follow the work: the spawned **worker's window**,
its **working directory**, and the **GitHub issue** the orchestrator opened. If
the request asks **not to publish on GitHub**, the reply instead names a
**progress file** and a **results file** under a per-request reply dir, which the
client pulls over the same confined SSH channel (`ng request fetch <id>
progress|results`). No new orchestrator-pane writer, no new network primitive
beyond Part A; the whole round-trip rides the request file as its correlation
anchor. [§D.7 worked example](#d7-end-to-end-worked-example) walks every file and
path.

**Part C — signal-source standardization.** The watcher already surfaces ~8
signal classes (GitHub comments, mentions, service health, cc-update, idle
workers, pending decisions, …). They split cleanly into **two shapes**: *observed
conditions* (self-clearing; re-emit while the condition holds) and *discrete
requests* (durable; re-emit until explicitly acked). The pending-decisions
channel and the proposed request inbox are both the second shape. We recommend a
**single internal contract — "a source produces ack-gated emit lines; the
watcher renders + re-emits until acked"** — implemented as a thin shared helper,
with each source keeping its own producer. This is the *facade-over-scripts*
philosophy the repo already chose in
[`ng-interface-proposal.md`](ng-interface-proposal.md): unify the **contract**,
not the implementations. We explicitly do **not** recommend collapsing all
sources into one mega-producer (it would destroy per-source tests and inflate
`main.sh`). The win is a future developer adding a new request source by
implementing one documented interface, not by reverse-engineering `compose_emit`.

---

## 1. Current architecture (the review)

This section is the map a future developer needs before touching any inbound
channel. Every claim carries a `path:line` citation against `dev` @ `f6d6a25`.

### 1.0 The two prompt-injection directions (the load-bearing distinction)

"Prompt injection" in nexus is *one component writing text into another's tmux
input line*. There are **two directions**, and conflating them is the most
common source of confusion in this area:

| Direction | Writers today | Hardened? | Pane |
|---|---|---|---|
| **watcher → orchestrator** | watcher **only** | yes | the orchestrator pane |
| **orchestrator → worker** | orchestrator (`paste-followup.sh`), watcher (unstick B/C), spawn launcher | yes (`paste-followup`) | worker panes |

The **watcher → orchestrator** channel is **already exclusive to the watcher**.
The audit found exactly three writers into the orchestrator pane, all in the
watcher: the steady-state emit (`paste_to_target`, `main.sh:1464-1528`), the
rate-limit cascade heads-up (`_unstick.sh:762-785`, via `_paste_line_to_window`
at `:708`), and the respawn recovery prompt (`_respawn.sh:707-733`). Nothing outside the watcher writes to
the orchestrator pane.

The **orchestrator → worker** channel is *not* exclusive — `paste-followup.sh`
(`:158-170`) is the canonical orchestrator-run path into a worker pane, used for
routed directives and skeptic nudges, and it stamps `machine-input.tsv` so the
watcher attributes the paste to the machine rather than the operator
(`paste-followup.sh:149-151`; the attribution ledger is read by the idle probe's
`operator-engaged` gate).

> **What "keep prompt-injection exclusive to the watcher" means (Part B).** It
> means *do not add a new writer to the **orchestrator** pane*. Today, the only
> way for a worker to get the orchestrator's attention out-of-band would be to
> paste into the orchestrator pane (a second writer — forbidden) or to have the
> orchestrator poll. The request inbox resolves this by routing worker→orchestrator
> requests **through the watcher's existing emit**: the watcher reads the inbox
> and includes requests in the report it *already* pastes. No new orchestrator-pane
> writer is introduced; the exclusivity invariant is preserved. (Part B does **not**
> propose moving `paste-followup.sh` into the watcher — that is the orthogonal
> worker-pane direction, out of scope here.)

### 1.1 The watcher emit pipeline

The watcher is a single bash loop driven by a per-task priority-queue scheduler
(`_scheduler.sh`; see [`docs/reference/watcher-protocol.md`](reference/watcher-protocol.md)
and [`docs/watcher-scheduling-refactor.md`](watcher-scheduling-refactor.md) for
the full model). Each registered task stages output; `compose_emit` merges the
staged outputs into one report and pastes it.

- **Compose.** `_compose_report_body` (`main.sh:1274-1428`) renders a fixed
  section order: header → standing infra sections (watcher-revived, supervisor,
  install-failure, hosting-migration, component-drift, service-health,
  cc-update) → local diff → `--- eligible github comments ---` (`:1368`) →
  standing bells → **pending decisions** (`:1378-1386`) → idle workers →
  workspace snapshot → dashboard → the unique trailer signature
  `--- nexus-emit-sig <iso> <nonce> ---` (`:1427`).
- **Dedup.** Before render, the staged GitHub lines pass a filter pipeline
  *assembled* at the `_v2_task_compose_emit` call site (`main.sh:3029-3040`) —
  the stages are individual functions chained there (e.g.
  `_filter_to_user_author` at `_github.sh:314`, `_dedup_emit_lines` below), not
  a single pipeline function:
  `_filter_to_user_author → _filter_skip_marker → _filter_cross_repo_surface →
  _dedup_emit_lines → _filter_suppression → _filter_processed_comments →
  _filter_reemit_backoff → _filter_emit_cooldown`. `_dedup_emit_lines`
  (`_emit_filters.sh:412-435`) keys on the `id=<x>` token: the first block
  through from *either* source (webhook delivery or GraphQL backstop) marks
  `seen[id]=1`; later blocks with the same id are dropped — so the same comment
  surfacing through multiple sources emits once.
- **Paste + verify.** `paste_to_target` (`main.sh:1464-1528`) forces insert mode
  (`send-keys i BSpace`, `:1479` — VI-mode hardening), `load-buffer` +
  `paste-buffer` + `Enter`, then **greps the pane capture for the trailer
  signature** (`:1496-1500`). Return codes: `0` ok, `1` no tmux, `2` target
  absent, `3` tmux API failed, `4` submitted-but-signature-absent.
  `paste_with_retry` (`:1530-1541`) retries once after 500 ms on rc 3/4. This
  content-level verification is what makes the channel *reliable* — a paste that
  didn't land is detected and retried rather than silently lost.

### 1.2 Signal vs. noise; resurface

Not every state change pages the orchestrator. `_classify_diff` (`_lib.sh`)
blanket-suppresses git-section churn and interim-report adds. The **resurface
mechanism** is central: the watcher re-emits on *every* poll while the GitHub
list / bell list / idle transition is non-empty — not only on first appearance —
so a missed paste reappears next cycle until the orchestrator acks (👀/🚀). The
baseline (`last-snapshot.txt`) is overwritten **only** on an actual local diff,
never on a comment-only resurface, so a resurface can't mask a fresh local change.

### 1.3 The re-emit-until-acked / resurface mechanism

`_reemit.sh` is the durable, ack-gated re-emit registry — the closest existing
mechanism to what Part B needs, built originally to rescue cross-repo
bot-mentions that have no GraphQL backstop (`_reemit.sh:2-23`):

- **Register.** `_reemit_register` (`:138-223`) writes fresh blocks to a durable
  registry, skipping any already registered or already 🚀-acked
  (`rocket:<id>` in `processed-comments.txt`, `:171-172`).
- **Two-tier cadence.** `_reemit_pending` (`:246-304`) re-feeds due blocks:
  **fast tier** every `MONITOR_REEMIT_NOEYES_MINUTES` (default 5 min) until the
  bot 👀-acks, then **slow tier** every `MONITOR_REEMIT_NOROCKET_HOURS`
  (default 6 h) until 🚀-done.
- **GC + live recheck.** `_reemit_gc` (`:360-531`) evicts 🚀-acked or
  max-age-expired entries (`MONITOR_REEMIT_MAX_AGE_SECONDS`, default 3 days,
  matching GitHub webhook retention), demotes 👀-seen to the slow tier, and
  throttles the per-entry reaction recheck to one API call per
  `MONITOR_EMIT_COOLDOWN_SECONDS` (300 s).

This is **exactly** the "re-emit a request until it's acked, with backoff and a
hard max-age" semantics Part B wants — the design reuses this machinery rather
than reinventing it.

### 1.4 The pending-decisions channel — the closest existing precedent

The pending-decisions channel (issue `#129`) is a *watcher-surfaced, file-backed,
ack-by-rename request channel* already in production — Part B is its
generalization.

- **Records.** JSON files at `monitor/.state/decisions/<window>.<fp>.json`,
  written atomically (temp + `mv -f`) by either a hook
  (`hooks/decision-emit.sh:66-67,133-157`; schema at `:140-156`:
  `{ts, window, session_id, kind, prompt_excerpt, tool_context, fingerprint}`)
  or by the watcher's Case-W relay (`_unstick.sh:511-599`,
  `kind:"blocked_question"`). The `fingerprint` is a 12-hex SHA1 of
  `window|kind|message` (`decision-emit.sh:91-104`).
- **Surface.** `render_pending_decisions` (`_idle_probe.sh:2871-2989`) scans the
  dir, skips `*.handled.json` tombstones (`:2889`), and emits the line shape
  `window=<W> fp=<FP> kind=<K> unresolved=<bool>` + `prompt-excerpt=…` +
  `file=<abs-path>` (`:2974-2976`). It re-emits on a per-(window,fp) cooldown
  (`DECISION_REEMIT_COOLDOWN_SECONDS`, default 300 s; state in
  `pending-decisions-emit-state.tsv`). Scheduled at 10 s (`main.sh:3315`).
- **Ack.** Two shapes (`monitor/README.md:638-653`): **ack-and-allow** =
  `rm <file>` (a still-true condition re-relays — the desired behaviour if the
  answer failed to land); **ack-and-suppress** = `mv <file> <file>.handled.json`
  (terminal tombstone). The orchestrator acts on these directly via the shell;
  there is no `ng` verb. The processing protocol is documented for the
  orchestrator at `agent-prompt.md:476-509`.

### 1.5 The skeptic↔worker channel — the convention to harmonize with

`skeptic-channel.sh` is the file-based comms channel between a worker and its
skeptic, and the design Part B must be *harmonious* with (not parallel to). Its
defining property — **"the rename is the signal"** — mirrors the operator's own
"edit and change the name" mental model.

- **Layout.** Per-task dir `monitor/.state/skeptic/<task-id>/` (task-id = the
  reviewed worker's window name; `skeptic-channel.sh:138,185-187`). Pending
  markers at `…/skeptic/pending/<window>` (`:139,191`); nudge timestamps at
  `…/skeptic/.nudge/<window>` (`:703`).
- **Request files + lifecycle.** `req-NNN-<slug>.open.md` → `.ack.md` →
  `.answered.md`, with a `DONE` sentinel to close. Each file carries **YAML
  frontmatter + markdown sections** (`cmd_ask`, `:353-364`):
  ```
  ---
  skeptic-request: NNN
  task-id: <task-id>
  slug: <safe-slug>
  state: open
  created: 2026-06-29T12:34:56Z
  ---
  ## Skeptic request
  <body>
  ## Worker response
  _(awaiting…)_
  ```
- **Atomicity.** Every state-producing write (`ask`, `answer`, `close`) builds a
  temp file and `mv -f`s into the terminal name (`:348,352,523,535`); the ack
  (`open`→`ack`) *is* the atomic rename (`:473-474`), so a request is acked
  exactly once even under a racing poll.
- **State machine.** `open ──ack──▶ ack ──answer──▶ answered`; `close` drops
  `DONE`, the worker's `await` loop sees it and exits 10.
- **`ng skeptic` facade.** `ng skeptic <sub>` execs `skeptic-channel.sh`
  (`ng:3815-3819`) — `init|ask|await|answer|await-answer|reconcile|close|nudge|
  list|status|…`.

### 1.6 The signal-source inventory (Part C raw material)

The watcher surfaces these signal classes today (per
[`watcher-protocol.md`](reference/watcher-protocol.md) "Emit classes" and the
review above). Each is a registered scheduler task whose staged output
`compose_report` renders:

| Source | Shape | Re-emit / ack model |
|---|---|---|
| eligible GitHub comments | observed list | resurface while non-empty; ack = bot 👀/🚀 reaction |
| cross-repo mentions / deliveries | discrete blocks | **`_reemit.sh`** two-tier, ack = 🚀 / max-age |
| pending decisions | discrete records | per-(window,fp) cooldown re-emit; ack = `rm`/tombstone |
| standing bells | observed list | cleared after emit |
| idle workers | observed transitions | transition-dedup; self-clears |
| service health | observed condition | full-state every cycle; self-clears when healthy |
| component drift (restart) | observed asks | re-nag-guarded per candidate hash; self-clears |
| cc-update available | discrete advisory | surfaced once per candidate |

The split is clean: **observed conditions** self-clear (re-emit *while the
condition holds*), while **discrete requests** (mentions, decisions, cc-update)
are durable and re-emit *until explicitly acked*. Part C is about giving the
second group one shared contract. Note that the *scheduling* is already
unified (`_scheduler.sh`); what is **not** unified is the *emit→ack* contract —
each discrete source hand-rolls its own register/re-emit/ack bookkeeping
(`_reemit.sh` for mentions, `pending-decisions-emit-state.tsv` for decisions).

### 1.7 The tmux / sandbox / chaperon wiring (Part A feasibility)

Established from this repo (facts), with agent_sandbox internals flagged as
**to-confirm**:

- **tmux is inside the sandbox.** `agent-sandbox tmux new-session ./watcher`
  boots the stack; the session is named `nexus` and is created **inside** the
  `bwrap --unshare-pid` namespace (`entry.sh`; `launcher.sh`). The orchestrator,
  workers, and services cockpit are windows in that one inner session; the
  watcher runs headless (setsid-detached, `WATCHER_WINDOW=headless`). The tmux
  socket is in the sandbox's mount/pid namespace and is **not reachable from the
  host tmux** — a critical fact for Part A.
- **Writable surface.** The sandbox confines writes to `$SANDBOX_PROJECT_DIR`
  (the nexus tree) + `~/.claude/` only; everything else is read-only or
  inaccessible, kernel-enforced (`docs/admin/security.md`; `write-probe.sh`
  documents the probe).
- **Existing inside→outside channel.** `sandbox-notify "<msg>"` reaches **both**
  the inner tmux and the **outer/host tmux via the chaperon** (a component of
  `agent_sandbox`, not this repo;
  [`docs/operating/notifications.md`](operating/notifications.md)). This is the
  *only* existing cross-boundary signalling path, and it is **outbound** (inside
  → out). There is **no inbound network listener** anywhere in the repo — a grep
  for `sshd|listen|nc |socat|Port` over `monitor/` finds nothing. Part A would
  introduce the first inbound channel.
- **Cross-sandbox state coordination precedent.** The watcher's single-instance
  guard is an **flock** on `monitor/.state/nexus-instance.lock`
  (`watcher-protocol.md` "Single-instance lock") — chosen precisely because
  `bwrap --unshare-pid` gives each sandbox its own pid namespace, so pid-based
  guards go blind across two sandboxes sharing one bind-mounted `.state/`. flock
  keys on the inode and crosses the namespace (and, on the NFS state mount, the
  host) boundary. This is the established pattern for safe cross-boundary
  coordination and informs Part A's locking.

> The agent's investigation inferred some `agent_sandbox` internals (exact mount
> layout, `EXTRA_WRITABLE_PATHS`, the chaperon's transport). Those are **not
> verifiable from this repo** and are marked **to-confirm against
> `katosh/agent_sandbox`** wherever Part A relies on them.

---

## 2. Part B — the watcher-mediated request inbox

### 2.1 Goal and the one-paragraph design

Give any agent (canonically a worker) a durable, first-class way to send a
**request** to the orchestrator that (a) cannot be lost, (b) cannot be
double-processed, (c) drains at the orchestrator's pace under heavy backlog, and
(d) introduces **no new writer to the orchestrator pane**. The mechanism: a
markdown **inbox** the **watcher** watches; the watcher **claims** each request
by atomic rename, **surfaces** it in its normal emit, and **re-emits until the
orchestrator acks** by renaming. This is the pending-decisions channel
([§1.4](#14-the-pending-decisions-channel)) generalized to arbitrary requests,
using the skeptic channel's rename-is-the-signal markdown convention
([§1.5](#15-the-skepticworker-channel)).

### 2.2 The request-file schema

One markdown file per request under `monitor/.state/requests/`, with YAML
frontmatter (harmonized with the skeptic channel's shape):

```
monitor/.state/requests/<ts>-<origin>-<slug>.<state>.md
```

- `<ts>` — `YYYYMMDDTHHMMSSZ` creation stamp (UTC; sortable → FIFO-by-default).
- `<origin>` — the requesting window name (provenance; also the fairness key).
- `<slug>` — short kebab description, for human-readable `ls`.
- `<state>` — the lifecycle state, **carried in the filename** so "the rename is
  the signal" (skeptic-channel convention).

```markdown
---
request: <ts>-<origin>-<slug>      # stable id (the stem; survives renames)
origin: <window-name>              # who filed it
kind: spawn-skeptic | question | escalation | …   # routing discriminator
created: 2026-06-29T18:42:01Z
priority: normal | high            # optional; default normal
state: new                         # mirrors the filename suffix (advisory)
---

## Request

<one-line summary the watcher surfaces verbatim>

## Details

<full body: the ask, the rationale, file:line refs, the proposed action.
For kind=spawn-skeptic: the target window, the skeptic mode, the rationale —
exactly the fields `spawn-worker.sh --skeptic-role --skeptic-target` needs.>
```

The **stable id** is the stem (`<ts>-<origin>-<slug>`), invariant across renames
— the dedup/ack key, analogous to the GitHub `id=` token and the decision
`<window>.<fp>`. It is also the **correlation id for the reply** (Part D): a
producer that wants a reply captures the id printed by `ng request file` and
polls for `<id>.replied.md`. When the orchestrator replies, it appends a
`## Reply` section and a structured `reply:` frontmatter block to *this same
file* — the reply-bearing fields are specified in
[§D.5](#d5-reply-schema-references-publish-flag-fetch-pointers); the producer-only
fields above are the request half of one round-trip document.

#### 2.2a Collision-free id generation

`<ts>` is second-granular, so two producers sharing an `origin`+`slug` in the
same second would collide on the stem. `ng request file` makes id allocation
**atomically collision-free** and guarantees **the printed id equals the on-disk
stem** — the property a remote client depends on to correlate its reply
([§D.2](#d2-request-placement-client--orchestrator--concretely) step 3):

1. Compute the candidate stem `<ts>-<origin>-<slug>`.
2. **Atomically reserve the stem with `mkdir`** of a marker directory
   `…/requests/.ids/<stem>` — `mkdir` is the reservation primitive because it is
   atomic *across NFS clients*, whereas an `O_EXCL` / `set -C` (`set -o
   noclobber`) open is **not reliably atomic on the NFS-cross-client `.state`
   substrate** (the same reason the watcher coordinates with `flock`, not an
   exclusive-create open — RFC §1.7). A `mkdir` that races a sibling **fails**
   rather than clobbering, and exactly one caller wins per name.
3. On a collision (the `mkdir` fails because the marker exists), append the next
   numeric disambiguator (`<stem>-01`, `-02`, …) and retry from step 2 until a
   `mkdir` wins.
4. **Print the winning stem.** Because the id is emitted *only after* the
   reserving `mkdir` succeeds, the client is never told an id that a racing
   producer then takes — printed id ≡ on-disk stem, always. The body is then
   written into the reserved `<stem>.new.md` via the temp+`mv -f` publish (the
   reserved name as the rename target). The `.ids/<stem>` marker persists for the
   request's life and is GC'd with its terminal file.

This is the same monotonic-disambiguation idea as
`monitor/skeptic-channel.sh:251` (`_next_req_num`, `req-NNN`), hardened with a
`mkdir` reservation so concurrent inbox producers (workers **and** remote
clients) cannot collide — reusing the convention, not reinventing it. **`mkdir`
(not `O_EXCL`) is mandatory here**: the inbox lives on the cross-client `.state`
mount, where only `mkdir`/`flock` give true atomicity. The disambiguator is part
of the **single** id the client receives; there is no separate
"nonce-added-later" step that could diverge from what was printed
([§6](#6-failure-modes--and-how-each-fails-closed)).

### 2.3 Lifecycle states (the rename **is** the signal)

```
 producer (worker)            watcher                       orchestrator
 ────────────────             ───────                       ────────────
 ask ──▶ …-<slug>.new.md
                       claim (atomic rename, the lock)
                      …-<slug>.new.md → …-<slug>.claimed.md
                              │  emit `--- requests ---` line (id + file path)
                              ▼  RE-EMIT every cooldown while .claimed.md exists
                                                  orchestrator reads, acts, then ACKS:
                                                  …-<slug>.claimed.md → …-<slug>.done.md
                              │  (next poll: no longer .claimed.md → stops emitting)
                              ▼
                      …-<slug>.done.md   (retained for audit; GC'd at max-age)
```

| State (filename suffix) | Written by | Meaning | Watcher behaviour |
|---|---|---|---|
| `.new.md` | producer (`mkdir` reserve, §2.2a; body via temp+`mv -f`) | filed, unclaimed | claim it: rename → `.claimed.md` |
| `.claimed.md` | **watcher** (atomic rename) | watcher owns it; being surfaced | emit + **re-emit until acked** |
| `.replied.md` | orchestrator (atomic rename) | **reply written into the file** (Part D); the producer/remote client may now read it | stop emitting; retain until GC |
| `.done.md` | orchestrator (atomic rename) | acknowledged / handled, **no reply body** needed | stop emitting; retain for audit |
| `.failed.md` | orchestrator or watcher | unactionable (malformed, stale origin) | stop emitting; surfaced once as an error |

Two-step claim/ack mirrors the GitHub model precisely: **claim** = the watcher's
👀 (I've seen it, I'm surfacing it); **done**/**replied** = the orchestrator's 🚀
(acted). The producer only ever writes `.new.md`; the watcher only ever does
`.new → .claimed`; the orchestrator only ever does `.claimed → {.done | .replied
| .failed}`. Single-writer-per-transition + atomic rename = **no race, no
double-processing**.

**`.done` vs. `.replied` — when each is terminal.** The two terminal states are
not redundant; they encode whether a reply body is expected:

- `.done.md` is the terminal for an **internal worker request** that needs only
  an ack — canonically `kind=spawn-skeptic`, where the requesting worker *sees*
  the skeptic appear and needs no prose reply. This is the original Part B path,
  unchanged.
- `.replied.md` is the terminal for a request whose **deliverable is the reply
  itself** — canonically a remote SSH client (Part D) that must learn *where the
  work went* (worker window, directory, GitHub issue) or *how to fetch results*
  (no-publish branch). The orchestrator writes the `## Reply` section, then
  renames `.claimed → .replied`; that rename **is** the "reply ready" signal the
  client detects.

A request may carry `reply: required` in its frontmatter (Part D producers set
this) to assert it expects `.replied`, never a bare `.done`; the orchestrator
drain ([§2.5](#25-the-orchestrators-drain-ack-protocol)) honours it. The
full reply mechanics — detection, schema, no-publish fetch — are
[Part D](#d-part-d--the-bidirectional-clientorchestrator-protocol-over-ssh).

### 2.4 The watcher's watch → claim → emit → re-emit → ack loop

A new scheduler task `requests_poll` (cheap, ~5–10 s cadence, matching
`pending_decisions`):

1. **Claim.** For each `*.new.md`, atomically `mv -f` to `*.claimed.md`. The
   rename is the lock: if two watcher instances ever raced (they cannot — the
   instance flock forbids it; [§1.7](#17-the-tmux--sandbox--chaperon-wiring-part-a-feasibility)),
   `mv -f` still yields exactly one winner per inode. A malformed file (no
   parseable frontmatter) is renamed to `.failed.md` and surfaced once.
2. **Render.** For each `*.claimed.md`, stage an emit line into the
   `--- requests ---` section:
   ```
   --- requests ---
   request=<id> origin=<window> kind=<k> priority=<p>
       summary: <## Request line, ≤160 chars>
       file=<abs-path-to-.claimed.md>
   ```
   This rides the watcher's *existing* `compose_emit` → `paste_to_target` →
   signature-verify path. **No new orchestrator-pane writer.**
3. **Re-emit until acked.** Reuse the `_reemit.sh` two-tier discipline
   ([§1.3](#13-the-re-emit-until-acked-resurface-mechanism)) keyed on the stable
   id: fast cooldown (default 5 min) until first surfaced-and-not-acted, then a
   slow "still pending" cadence; **hard max-age** eviction → `.failed.md` + a
   loud log, so a never-acked request cannot re-emit forever. A `*.claimed.md`
   whose file the orchestrator has renamed to `.done.md` simply no longer matches
   the glob, so emission stops on the next poll — self-clearing, exactly like a
   removed decision file.
4. **GC.** `.done.md` and `.failed.md` are retained for audit and pruned at
   `monitor.requests.retention_seconds` (default 3 days, matching `_reemit` and
   webhook retention).

### 2.5 The orchestrator's drain (ack protocol)

The orchestrator processes a `--- requests ---` line exactly like a pending
decision (the protocol it already knows, `agent-prompt.md:476-509`):

1. Read the cited `.claimed.md` file (`## Request` + `## Details`).
2. Act per `kind`. For `kind=spawn-skeptic`: run
   `spawn-worker.sh --skeptic-role --skeptic-target <origin> …` with the fields
   from `## Details` — this **formalizes the auto-skeptic request** the operator
   called out as unreliable today (the worker *files* the request; the
   orchestrator *spawns*; no auto-spawn fragility).
3. **Ack** by renaming `.claimed.md → .done.md` (canonically via a new façade,
   [§2.7](#27-the-ng-request-facade)). Ack-and-allow vs. ack-and-suppress is
   subsumed: a request is a discrete ask, so `.done.md` is terminal; if the
   orchestrator's action *failed* and the producer still needs it, the producer
   files a **new** request (new id) — cleaner than the decision channel's
   re-relay, because a request is a one-shot ask, not a standing condition.
   `ng request ack` must be **idempotent**: `mv -f` of an already-renamed (or
   missing) source errors harmlessly, so the verb swallows the
   already-`.done` case and exits 0 rather than failing a double-ack.
4. **Reply** (when the request carries `reply: required`, or the orchestrator
   chooses to answer): instead of step 3's bare ack, call
   `ng request reply <id> …` (§2.7), which **appends** a `## Reply` section + a
   `reply:` frontmatter block to the claimed file (via temp + `mv -f` so the
   write is atomic) **and** renames `.claimed.md → .replied.md` in one verb. The
   producer/remote client detects the rename and reads the reply
   ([Part D](#d-part-d--the-bidirectional-clientorchestrator-protocol-over-ssh)).
   `ng request reply` is the orchestrator's drain verb for the bidirectional
   case; it is likewise idempotent (a second reply to an already-`.replied` id
   is refused with a non-zero, never a torn file).

### 2.6 Backlog, fairness, idempotency under load

The operator's explicit goal — "stability + consistency under high load with a
backlog aggregating." How each property is guaranteed:

- **None lost.** Requests are durable files; the watcher re-emits `.claimed.md`
  until acked; a paste that didn't land is caught by the trailer-signature
  verify ([§1.1](#11-the-watcher-emit-pipeline)) and retried. Even a watcher
  crash loses nothing — files persist; on restart the startup sweep re-surfaces
  every `.claimed.md`.
- **None double-processed.** Each lifecycle transition has a **single writer**
  and is an **atomic rename**; the orchestrator's `.claimed → .done` is
  idempotent (`ng request ack` swallows an already-`.done`/missing source, §2.5).
  **Action idempotency across the act→ack window (caveat).** The atomic rename
  guarantees the *ack* happens once; it does **not** by itself guarantee the
  *action* happens once. Because re-emit keys on `.claimed.md` existing, a
  request whose handling outlives the fast-tier cooldown
  (`MONITOR_REEMIT_NOEYES_MINUTES`, default 5 min) could re-surface and be acted
  on a second time. Two defences, both cheap: (1) the orchestrator may
  **ack-first-then-act** (rename `.claimed → .done` *before* the spawn, so a
  re-emit can't recur — at the cost of losing the "still pending" signal if the
  act then fails, which the producer recovers by filing a fresh request); or
  (2) treat **action idempotency as a per-`kind` requirement** documented in the
  schema. For the canonical `kind=spawn-skeptic` the action is seconds (vs a
  5-min cooldown) *and* a double-spawn is independently caught by the
  `skeptic-pending` marker, so the window is not a real race — but a new `kind`
  with a slow, non-idempotent action MUST declare its strategy. B1/B2 pin this
  down per `kind`. This is the same act-vs-ack property as the proven
  GitHub-comment 👀/🚀 model.
- **Bounded emit under backlog.** The `--- requests ---` section is **capped**
  (`monitor.requests.max_per_emit`, default e.g. 10) and ordered by
  `(priority, ts)` so high-priority and oldest win — the rest wait for the next
  emit. The cap reuses the existing `test-emit-section-cap.sh` discipline. The
  orchestrator drains at its own pace; the backlog is the on-disk file set, not
  an in-memory queue that can overflow.
- **Fairness.** Default order is FIFO by `<ts>`. To prevent one chatty `origin`
  from starving others, the per-emit selection round-robins across distinct
  `origin` values before falling back to FIFO within an origin (a ~15-line
  selection function; documented, testable). Stated as a **knob**, not baked in,
  so the operator can choose strict-FIFO if preferred.
- **Idempotent producer.** A producer that files the "same" request twice
  produces two ids (distinct `<ts>`); a `kind`+`origin`+content fingerprint
  (reusing the decision channel's SHA1-12 scheme) can optionally collapse
  duplicates at claim time — proposed as an opt-in, since most requests are
  legitimately distinct.

### 2.7 The `ng request` facade

Following the repo's facade-over-scripts convention
([`ng-interface-proposal.md`](ng-interface-proposal.md)): a thin
`request-channel.sh` with an `ng request` façade (`exec`, preserving an
independent `test-request-channel.sh` unit), symmetric with `ng skeptic`:

```bash
# ── producer / client side ──────────────────────────────────────────────────
ng request file --origin <window> --kind <k> [--priority high] [--reply required] \
    --slug <slug> [--file body.md | --message "…"]   # writes .new.md; PRINTS the id
ng request await <id> [--timeout S] [--interval S]    # block until .replied/.done; print reply
ng request fetch <id> progress|results                # no-publish branch: pull a fetch file
ng request list [--state new|claimed|replied|done|all]# human-readable table
ng request show <id>                                  # print a request file (incl. ## Reply)

# ── orchestrator side ───────────────────────────────────────────────────────
ng request ack  <id>                                  # .claimed → .done   (no reply body)
ng request reply <id> [--file reply.md | --message "…"] \
    [--worker <window>] [--dir <abs-path>] [--issue <owner/repo#N>] \
    [--no-publish] [--progress <path>] [--results <path>]   # .claimed → .replied
ng request fail  <id> --reason "<why>"                # mark unactionable
```

`ng request file` is what a worker (or remote client) calls instead of trying to
reach the orchestrator directly — it **prints the stable id on stdout** so the
caller can correlate a reply. `ng request await` is the client's blocking
detect-and-read verb (the mirror of `ng skeptic await-answer`). `ng request ack`
/ `reply` are the orchestrator's drain verbs — `ack` for a bare acknowledgement,
`reply` for the bidirectional case that writes a `## Reply` and renames to
`.replied.md`. The watcher's claim/emit/re-emit stays internal (no verb).

### 2.8 Harmonization with the skeptic↔worker convention (explicit)

Part B is a **generalization**, not a parallel scheme. Concretely:

| Property | skeptic channel | request inbox (Part B) | Same? |
|---|---|---|---|
| medium | markdown + YAML frontmatter | markdown + YAML frontmatter | ✅ identical |
| "rename is the signal" | `.open→.ack→.answered` | `.new→.claimed→.done`/`.replied` | ✅ same primitive |
| reply into same file | `## Worker response` + `.answered` | `## Reply` + `.replied` (Part D) | ✅ same model |
| blocking detect/read | `await-answer` (skeptic) | `ng request await` (client, Part D) | ✅ same loop |
| atomicity | temp + `mv -f`; rename = ack | temp + `mv -f`; rename = claim/ack | ✅ same |
| stable id | `req-NNN-<slug>` stem | `<ts>-<origin>-<slug>` stem | ✅ same idea |
| facade | `ng skeptic` | `ng request` | ✅ same shape |
| direction | worker ↔ skeptic (peer) | worker → orchestrator (up) | ⟂ complementary |
| surfacer | the *parties* poll their own dir | the **watcher** surfaces | ⟂ by design |

The two channels are complementary, not competing: skeptic↔worker is **peer-to-peer
within a review**, while the request inbox is **worker→orchestrator escalation**.
A worker asking *to be reviewed* (`kind=spawn-skeptic`) files a **request**; the
back-and-forth *during* the review stays on the **skeptic channel**. They share
the primitive and the `ng <noun> <verb>` ergonomics so a developer who knows one
knows the other. **Recommended refactor (optional):** extract the shared atomic
rename-state-machine into a tiny `_channel_lib.sh` both `skeptic-channel.sh` and
`request-channel.sh` source — single home for "the rename is the signal," per
the repo's no-bloat / single-source-of-truth principle.

---

## 3. Part C — signal-source standardization

### 3.1 The question, answered

> *Should existing signals flow through this request-file process? Should we
> standardize the sources? Does the watcher want refactoring?*

**Recommendation: standardize the *contract*, not the *implementations*.** Adopt
one internal interface — **"a discrete-request source produces ack-gated emit
blocks keyed by a stable id; a shared helper renders them and re-emits until
acked, with two-tier backoff and max-age eviction"** — and migrate the
hand-rolled discrete sources (mentions via `_reemit.sh`, pending decisions via
`pending-decisions-emit-state.tsv`, the new request inbox) onto it. **Do not**
route *observed-condition* sources (service health, idle workers, bells, drift)
through it — they are a different shape (self-clearing, no explicit ack) and
forcing them through a request lifecycle would be a worse fit, not a better one.

### 3.2 Why this is the right altitude

The repo already made this exact call once, in
[`ng-interface-proposal.md`](ng-interface-proposal.md): *facade-over-scripts,
unify the contract not the code; reserve "migrate into one file" for genuinely
new ops.* The same trade-off applies:

| | **Unify the contract** (recommended) | **Collapse into one producer** (rejected) |
|---|---|---|
| Future dev adds a source | implement one documented interface | edit `compose_emit` internals |
| Per-source tests | preserved (each producer keeps its unit) | destroyed / merged |
| `main.sh` size | unchanged (helper is sourced) | grows; worse conflict surface |
| Re-emit/ack logic | one shared home (`_reemit.sh` generalized) | duplicated or entangled |
| Observed vs. request shapes | kept distinct (correct) | conflated (wrong) |

### 3.3 The concrete shared interface

Generalize `_reemit.sh` into the canonical **ack-gated emit registry** and give
it a tiny producer-facing contract. A discrete-request source implements:

```
# Produce zero or more blocks. Each block:
#   <id-token> <metadata kv pairs>
#       summary: <one line>
#       <optional detail lines>
# The id-token is stable across re-emits and is the ack key.
<source>_produce() { … emit blocks to stdout … }

# Report whether id <x> has been acked (so the registry can evict/stop).
<source>_is_acked() { … return 0 if acked … }
```

The shared registry handles: register-fresh, two-tier cadence
(fast-until-seen / slow-until-acked), max-age eviction, the per-id recheck
throttle, and rendering into a named `--- <section> ---` block. GitHub mentions,
pending decisions, and requests become three implementations of this interface;
their producers shrink to `_produce` + `_is_acked`. The observed-condition
sources are **untouched** — they keep their self-clearing render functions.

This is a **refactor with behavioural parity** (the `_reemit.sh` semantics are
already correct; we're widening their reach), so it ships behind the same kind
of A/B parity test the scheduling refactor used
([`watcher-scheduling-refactor.md`](watcher-scheduling-refactor.md) §6): diff the
archived emit bodies across old/new on canned state, require identity modulo the
new section.

### 3.4 Maintainability outcome

A future developer wanting "surface a new kind of worker→orchestrator request"
writes a `_produce`/`_is_acked` pair and an `ng request`-style façade, registers
one scheduler task, and gets re-emit-until-ack, backoff, max-age, dedup, the cap,
and the verified paste **for free** — without reading `compose_emit`. That is the
anti-drift property the operator asked for.

---

## 4. Part A — confined remote access into the sandbox

> **This part touches `katosh/agent_sandbox` (public, no bot install). It is
> PROPOSED, not implemented. The operator decides.** The design's prime
> directive: an authenticated remote client gets **exactly** what a local
> in-sandbox agent has — the tmux + the request channel — and **nothing more**.
> No host access, no other sandbox, no escape, **no weakening of the
> kernel-enforced filesystem sandbox.** Any element that would require loosening
> the boundary is flagged **out-of-bounds** below.

### 4.1 The core idea: SSH server *inside* the sandbox

Because the tmux session lives **inside** the `bwrap --unshare-pid` namespace
([§1.7](#17-the-tmux--sandbox--chaperon-wiring-part-a-feasibility)), the
confinement falls out for free if the **SSH daemon runs inside the same
sandbox**. A login then:

- inherits the sandbox's writable-path set (`$SANDBOX_PROJECT_DIR` + `~/.claude/`)
  and pid/mount namespace — **the kernel enforces the same boundary on the SSH
  session as on any local agent**;
- can reach the inner tmux socket (it's in the same namespace) — so it can attach
  to the session;
- **cannot** reach the host, other sandboxes, or anything the local agent
  couldn't — because it *is* a process in the sandbox, subject to the same bwrap
  rules.

This is strictly better than an SSH server on the **host** that forwards in:
a host-side daemon would have host privileges and would need a carefully audited
bridge *into* the sandbox — re-introducing exactly the boundary-crossing risk we
want to avoid. **Running the daemon inside the sandbox means the sandbox is the
confinement; we add no new trust boundary, we inherit the existing one.**

> **Out-of-bounds (flagged):** any approach that bind-mounts the host SSH socket
> in, that runs the daemon on the host with a pty into the sandbox, or that adds
> writable paths to reach tmux, would weaken or bypass the sandbox. Rejected.

### 4.2 What the authenticated client may do (forced command)

A bare shell — even inside the sandbox — is more than "what a local agent has
via the request channel" and invites lateral movement within the writable tree.
So the principal is pinned to a **forced command** (`command=` in
`authorized_keys`, or an `sshd` `ForceCommand`) that offers exactly two verbs:

1. **`attach`** — `tmux attach -t nexus -r` (**read-only**, the `-r` flag) so the
   remote client can *observe* the session (watch the orchestrator, workers,
   cockpit) without keystroke injection. Read-only attach means the remote client
   cannot paste into any pane directly — it must go through the request channel
   to *act*, preserving the "only the watcher writes the orchestrator pane"
   invariant.
2. **`request file`** — a wrapper over `ng request file …`
   ([§2.7](#27-the-ng-request-facade)) that lets the remote client **file a
   request into the Part B inbox**. This is the *acting* channel: the remote
   Claude files a request; the watcher surfaces it; the orchestrator drains it.
   The wrapper **forces `--origin remote-<principal>`** (the `authorized_keys`
   principal name, never client-supplied) so provenance and the reply-read
   ownership check ([§D.4](#d4-reply-detection--read-the-clients-side)) cannot be
   spoofed. It echoes the stable id back over the SSH stdout so the client can
   correlate.
3. **`request await <id>` / `request fetch <id> progress|results`** — the
   **reply-read** verbs (Part D). `await` blocks server-side until the request
   reaches `.replied.md`/`.done.md` (or times out) and streams the reply back;
   `fetch` streams a no-publish progress/results file. Both are **confined
   reads**: the dispatcher resolves the id to a file **under the inbox tree
   only**, **verifies the file's `origin` equals this principal's
   `remote-<principal>`** (so one remote client cannot read another's reply), and
   reads *only* the request file or its `replies/<id>/` dir — never an arbitrary
   path. This is the read primitive the remote client gets, and it is scoped to
   *its own* round-trip, nothing else.

The forced command is a small, auditable allowlist dispatcher (a `case` over the
`SSH_ORIGINAL_COMMAND`), refusing anything else and logging every invocation.
This is the same discipline as the `gh` wrapper's write-verb allowlist. The
read verbs (`await`/`fetch`) are the **only** read primitives a request-only
principal gets, and they are path-confined to the principal's own inbox/reply
files — so adding them does **not** widen the principal into a general reader
(it cannot `cat` the bot `.pem` or any file outside its own request's reply
dir).

> **The whole confinement rests on this dispatcher being airtight.** It is the
> single point where a remote string becomes an action, so its test suite is
> load-bearing and MUST cover: (a) **`SSH_ORIGINAL_COMMAND` injection** — no
> shell metacharacter, `;`, `&&`, `$(…)`, newline, or argument smuggling can
> escape the `case` into an arbitrary command; (b) **`attach -r` cannot be
> widened by client-supplied args** — the dispatcher invokes a *pinned*
> `tmux attach -t nexus -r` and never forwards client tmux flags (which could
> otherwise drop `-r` or retarget the session); (c) unknown verbs **fail closed**
> (refuse + non-zero, never a shell). Treat any gap here as a sandbox-boundary
> regression, not a cosmetic bug.

> **Design choice to surface to the operator.** Read-only `tmux attach` still
> lets a remote client *see* everything in the session (worker output, file
> paths, possibly secrets echoed in a pane). If even read visibility is too much,
> the `attach` verb can be dropped, leaving only `request` (write-only into the
> inbox) — a strictly tighter posture. Recommended default: **`request` only**,
> with `attach -r` as an opt-in (`monitor.remote.allow_attach`), because
> observation is a real convenience for a cooperating remote agent but is the
> looser choice.

### 4.3 Authentication and the threat model

- **Who can reach the endpoint.** Bind the in-sandbox `sshd` to the **LAN
  interface only** (or, tighter, a host-only/Wireguard address), never
  `0.0.0.0` on a public NIC. Document a firewall rule as the outer gate. The
  endpoint is reachable only by hosts the operator places on that network — the
  first line of defence is network reachability, the second is key auth.
- **How auth works.** **SSH public-key only**, no passwords, no
  keyboard-interactive. A **dedicated principal** (a single `authorized_keys`
  entry per authorized remote agent) with the forced command and hardened
  options: `no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty`
  (no pty needed — `attach -r` runs under the forced command;
  drop `no-pty` only if interactive attach is enabled and then scope it).
  Optionally pin `from="<lan-cidr>"` in the key entry as defence-in-depth.
- **Fail closed.** If the forced-command wrapper cannot resolve the inbox dir,
  cannot find tmux, or sees an unknown verb, it **refuses and exits non-zero**
  (never falls through to a shell) — same fail-loud philosophy as the `gh`
  wrapper and `mint-token.sh`. If `sshd` config validation fails at start, the
  service does not come up (it's a registered `services.registry` entry with a
  healthcheck; a wedged daemon surfaces via `--- service health ---`).
- **What an authenticated client cannot do** (the confinement claims): cannot
  escape the sandbox (kernel bwrap); cannot write outside `$SANDBOX_PROJECT_DIR`
  + `~/.claude/` (kernel bwrap — *same as a local agent*); cannot read the bot
  `.pem` any more than a local agent can (it's in `~/.claude/`, readable by local
  agents too — **this is a pre-existing property, not a regression**, but worth
  stating: a remote principal with `request`-only and no shell **cannot exfil
  the pem**, because its only read primitive is the **path-confined**
  `await`/`fetch` ([§4.2](#42-what-the-authenticated-client-may-do-forced-command)),
  which resolves *only* to the principal's own request file and its
  `replies/<id>/` dir — it has no primitive that can name `~/.claude/*.pem`; with
  `attach -r` it could see whatever a pane shows but still cannot `cat` the pem);
  cannot inject keystrokes
  into the orchestrator pane (read-only attach + request-only); cannot reach
  another sandbox or the host.

### 4.4 Threat-model table

| Threat | Mitigation | Residual |
|---|---|---|
| Unauthorized network reach | LAN-only / host-only bind + firewall + `from=` pin | operator must not expose the NIC publicly |
| Credential theft → login | pubkey-only, dedicated principal, per-agent key | a stolen private key = that agent (revoke the `authorized_keys` line) |
| Shell escape / lateral movement | forced command allowlist; no-pty (request-only) | wrapper bugs (small, auditable, tested) |
| Sandbox escape | **kernel bwrap — unchanged**; daemon runs *inside* | inherits agent_sandbox's existing posture, no worse |
| Orchestrator-pane injection | read-only attach + request-only; only the watcher writes that pane | none beyond the request channel itself |
| Secret exfiltration | request-only principal's sole read primitive (`await`/`fetch`) is path-confined to its own request + `replies/<id>/` dir — cannot name any other path | `attach -r` (if enabled) exposes pane *visibility* only |
| Cross-client reply read | `await`/`fetch` verify the request's `origin` equals the calling principal before reading | a principal can read only its own round-trip |
| Audit gap | every forced-command invocation logged; requests are durable files | — |
| Secret leaked onto GitHub | secrets out-of-band ONLY (§4.9): stdout / `0600` op-only file; pre-write grep guard refuses a GitHub write matching key/token patterns; never under `reports/`/`ng upload` | operator must read the secret from the out-of-band surface, not paste it anywhere public |
| Enrollment token replay / theft | single-use + short TTL (`enrollment_token_ttl_seconds`); consumed on first use; stored hashed | a stolen *unused* token within TTL enrolls one key — revoke by deleting the pending token; spent tokens fail closed |
| Service enabled by accident | off-by-default = no `nexus-remote-ssh` registry row; the supervisor exits-without-listening, the healthcheck is healthy-because-off, and the wrapper refuses while unregistered | operator/orchestrator must deliberately `remote-up.sh` (register + start) |

### 4.5 Why this preserves (never weakens) the sandbox

The sandbox boundary is the kernel `bwrap --unshare-pid` confinement. Part A
**adds a process inside that confinement** and **authenticates who may become
that process** — it does not punch a hole through bwrap, does not add writable
mounts, does not run anything with host privilege that proxies in. The remote
client's confinement is *identical* to a local agent's because it **is** a local
(in-sandbox) process. The only new attack surface is the in-sandbox `sshd` + the
forced-command wrapper, both of which are inside the sandbox and therefore
themselves confined. This is "an authenticated inbound channel **within** the
existing confinement," exactly as the operator framed it — not a hole through it.

### 4.6 What lands in `agent_sandbox` vs. nexus-code

- **`agent_sandbox` (propose; operator decides):** whether/how the sandbox image
  ships an `sshd` (or a lighter alternative — e.g. `tmux -CC` over an existing
  channel, or a unix-socket request drop reachable via the chaperon — see
  alternatives below); how the in-sandbox daemon binds to a network interface
  given the sandbox's network namespace; key provisioning into `~/.claude/`. The
  chaperon already proves cross-boundary signalling is an agent_sandbox concern.
- **nexus-code (implementable later, behind a flag):** the forced-command
  wrapper (`monitor/remote-forced-command.sh`), the **off-by-default registered
  service** (`monitor/remote-sshd-supervised.sh` + `remote-ssh-health.sh` + the
  `services.registry` row + `monitor/remote-up.sh` enable helper, §4.8), the
  **secret-provisioning tooling** (`ng remote enroll`, host-key generation, the
  out-of-band token flow, §4.9), the `ng request` inbox (Part B) the `request`
  verb rides on, behavioral config knobs (`monitor.remote.*`; enable = registration), and
  the **operator setup runbook** (`skills/nexus.remote-access/SKILL.md`, §4.10).

### 4.7 Alternatives considered (for the operator)

1. **No SSH — a unix-socket request drop via the chaperon.** Instead of a full
   `sshd`, expose only a request-filing primitive across the boundary (the
   remote client writes a request that the chaperon relays inbound to the inbox).
   *Tighter* (no shell, no attach, no network listener — reuses the existing
   chaperon transport) but needs agent_sandbox to add an **inbound** chaperon
   path (today it's outbound-only) and gives up the observe/attach convenience.
   **Strong contender if "request-only" is the chosen posture** — it makes Part A
   a pure extension of Part B with no new network daemon at all.
2. **Host `sshd` + forced command that `agent-sandbox exec`s in.** Rejected:
   host-privileged daemon + a bridge into the sandbox re-introduces the boundary
   crossing we're avoiding.
3. **Wireguard + in-sandbox sshd.** The bind-tightening variant of §4.1; good
   defence-in-depth if the LAN is not trusted. Compatible with the recommended
   design.

**Recommendation:** start from **request-only** (§4.2), and prefer **alternative
(1)** if agent_sandbox can add an inbound chaperon drop — it is the smallest,
tightest surface and makes A a clean extension of B. Fall back to **in-sandbox
sshd with a request-only forced command** (§4.1–4.5) if a real network login is
required. Either way, **attach is opt-in and read-only**.

### 4.8 The SSH endpoint as a registered service — off by default, orchestrator-enableable

The remote endpoint is a **supervised infra service**, modelled exactly on the
jupyterlab pattern (`jupyter-up.sh` + a `services.registry` row + a healthcheck;
[`skills/nexus.jupyter`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.jupyter/SKILL.md)). It is **registered
but DISABLED by default**; a single config knob enables it, and the
**orchestrator can flip it on by direct action** (config edit + a register/start
step) — no operator shell required.

**4.8.1 Config schema (`config/nexus.yml`).** A `monitor.remote` block of
**behavioral** parameters (committed to `config/nexus.example.yml` with safe
defaults; the live `config/nexus.yml` is operator-local). **There is no
`enabled` flag** — registration is the single enable signal (§4.8.3): the
service is off until the `nexus-remote-ssh` row is registered, so a fresh
clone ships inert (no row). Collapsing the would-be `enabled` knob into
registration removes a redundant second toggle (round-2 operator feedback,
PR `#379`).

```yaml
monitor:
  remote:
    command_policy: channel-only  # in-sandbox command FILTER (not a sandbox control, §4.2):
                                  #   channel-only (default) — forced command: request file/await/fetch
                                  #   unfiltered — a sandbox-confined login SHELL (arbitrary commands)
    bind_address: 127.0.0.1       # LAN/host-only; NEVER 0.0.0.0 on a public NIC (§4.3)
    port: 22022                   # in-sandbox sshd port (high, unprivileged)
    allow_attach: false           # read-only `attach -r` opt-in (§4.2); channel-only
    principals_dir: ~/.claude/nexus-remote/   # authorized_keys + host key live here (op-only, 0700)
    enrollment_token_ttl_seconds: 900         # one-time token lifetime (§4.9)
    from_cidr: ""                 # optional `from=` pin for every authorized_keys line (defence-in-depth)
```

Registration is load-bearing: the supervisor, the healthcheck, and the
forced-command wrapper all gate on *"is the `nexus-remote-ssh` row present?"*
(`_remote_registered`). With no row the supervisor exits without listening,
the healthcheck treats not-running as healthy (no flap), and the wrapper
refuses (belt-and-suspenders — a stray daemon can't serve an unregistered
channel). `command_policy` chooses the in-sandbox command filter: the default
`channel-only` pins the forced command; `unfiltered` is the operator's
opt-in trust mode (a sandbox-confined shell — the kernel sandbox, not the
filter, is the boundary).

**4.8.2 The `services.registry` row.** One TAB-separated line (the schema in
[`services.registry.example`](https://github.com/<your-org>/nexus-code/blob/main/monitor/services.registry.example)):

```
nexus-remote-ssh<TAB>$NEXUS_ROOT<TAB>monitor/remote-sshd-supervised.sh<TAB>monitor/remote-ssh-health.sh<TAB>monitor/.state/remote-ssh.log<TAB>emit-only
```

- **launch** `remote-sshd-supervised.sh` — a restart-loop wrapper (mirrors
  `labsh-supervised.sh`) that execs the in-sandbox `sshd` with the hardened
  config (`-o` overrides: `PasswordAuthentication no`, `PermitRootLogin no`,
  `AllowTcpForwarding no`, `X11Forwarding no`, `MaxAuthTries 3`,
  `LoginGraceTime 15`, `MaxStartups`/`MaxSessions`/`ClientAlive*` caps,
  `PermitTTY no`, `PermitUserRC no`, `AuthorizedKeysCommand none`, the §4.3
  options), binding `monitor.remote.bind_address:port`. `PermitTTY` follows the
  command policy (yes for `unfiltered`/`allow_attach`, else no). It **exits 0
  without listening** when the `nexus-remote-ssh` row is not registered.
  **NB — no global `ForceCommand`.** The forced command is pinned **per key**
  via `command="…/remote-forced-command.sh <principal>"` in `authorized_keys`,
  NOT a global `sshd_config` `ForceCommand`: OpenSSH evaluates a global
  `ForceCommand` *before* the per-key `command=`, so a global one would shadow
  the per-key `<principal>` arg and break every key. Because the whole
  confinement then rests on every `authorized_keys` line carrying a
  `command="…"`, the supervisor **validates `authorized_keys` before each
  launch** and refuses to bind if any non-comment line lacks a forced command
  (a command=-less line would grant a shell) — the belt-and-suspenders the
  global `ForceCommand` was meant to provide, relocated to a startup gate.
- **healthcheck** `remote-ssh-health.sh` — cheap: registered ⇒ assert the
  forced-command wrapper is executable AND a real sshd answers on the configured
  bind/port — an **identity-aware** probe that reads the `SSH-2.0-` banner (not
  just a socket), so a foreign listener squatting the port is *not* false-healthy
  (the jupyter-health lesson); not-registered ⇒ exit 0 (correctly-not-running =
  "healthy", so it never false-alarms).
- **policy `emit-only`** (the 6th field) — a wedged/compromised `sshd` is **not**
  blindly restarted; after the grace window the watcher escalates to the
  orchestrator via `--- service health ---` (§4.3). A network listener is exactly
  the "blind restart unsafe / wants human judgment" case the registry's
  `emit-only` policy exists for.

**4.8.3 The orchestrator-driven enable procedure** — ONE command (direct
action, no operator shell). `monitor/remote-up.sh` mirrors `jupyter-up.sh` and
encapsulates it idempotently. **Registration is the enable signal — there is no
separate config flag to flip** (round-2 simplification, PR `#379`):

1. **Register the row = enable.** `remote-up.sh` appends the `nexus-remote-ssh`
   row to `monitor/services.registry` if absent (idempotent). This row IS the
   enable: the supervisor/healthcheck/wrapper all gate on its presence.
   *(Optionally edit `config/nexus.yml` first to change `command_policy`/
   `bind_address`/`port`/`allow_attach` from defaults — behavioral params, not
   the on/off switch.)*
2. **Provision host key + first principal** (§4.9) — generated in-sandbox, secret
   material kept out-of-band.
3. **Start.** `remote-up.sh` starts the supervisor via the same `recover_service`
   path bootstrap uses (or the next `bootstrap-recover.sh` sweep picks it up — the
   row makes it self-reviving).
4. **Verify green.** `remote-up.sh` waits for `remote-ssh-health.sh` to pass and
   prints the bind address + command policy + host-key fingerprint (the
   fingerprint is **not** secret; the operator pins it, §4.10).

**Disable** is one command: `monitor/remote-up.sh --down` removes the row (the
single off switch) and stops the supervisor; the running supervisor also
self-exits on its next periodic registration re-check.

**Disable** is one command: `monitor/remote-up.sh --down` removes the row and
stops the supervisor; with no row the healthcheck treats not-running as
healthy. Revoking a single client is removing its `authorized_keys` line
(§4.9) without disabling the service.

### 4.9 Secret provisioning — out-of-band ONLY, never on GitHub

The endpoint's setup touches secret material: the **server host key**, each
client's **keypair**, and a **one-time enrollment token**. The crux:
**no secret ever transits a public surface.** The bot identity model (CLAUDE.md
"GitHub writes — identity and authorization") means every GitHub write is the bot
— and
**no GitHub write (PR / issue / comment / wiki / release asset) may ever carry
key material, a token, a password, or a private key.** Secrets travel **only**
out-of-band:

- **direct Claude Code output** (the orchestrator/worker prints the secret in its
  session, which the operator reads — never echoed into a file the bot uploads,
  never into a report under `reports/` that `ng wrap-up` ships to the asset repo);
- **an operator-only file** under `~/.claude/` (mode `0600`, outside
  `$SANDBOX_PROJECT_DIR`'s GitHub-tracked tree, never `ng upload`ed); or
- **another operator-only channel** the operator already trusts (the existing
  `sandbox-notify` tmux surface, a local path the operator alone reads).

**What is secret vs. not** (get this right — it is the whole threat model):

| Material | Secret? | Surface |
|---|---|---|
| Client **private** key | YES | **never leaves the client host**; the operator generates it client-side and it transits nothing |
| Client **public** key | No | safe to move over any channel (it authorizes nothing on its own) |
| Server **host public key fingerprint** | No | delivered for pinning; not sensitive |
| **One-time enrollment token** | YES | out-of-band only; short TTL; single-use; consumed on first enrollment |
| Server host **private** key | YES | generated in-sandbox, stays in `principals_dir` (op-only), never copied out |
| Any bootstrap **password** (avoid) | YES | recommended posture is **pubkey-only, no password at all**; if one exists, rotate it post-enrollment and deliver the reset out-of-band |

**The provisioning flow** (no secret on a public surface at any step):

1. **Server host key** — `remote-up.sh` (§4.8.3 step 3) generates an `ed25519`
   host key into `principals_dir` (in-sandbox, `0600`). Its **fingerprint**
   (non-secret) is printed for the operator to pin (§4.10); the private host key
   never leaves the sandbox.
2. **Client keypair** — generated **on the client host by the operator**
   (`ssh-keygen`); the **private key never moves**. Only the **public** key is
   enrolled.
3. **One-time enrollment token** — to authorize adding a client's public key
   *before* any channel exists, the orchestrator issues a single-use token
   (random, `enrollment_token_ttl_seconds` TTL, recorded hashed in
   `principals_dir/enroll/`). The token is **handed to the operator out-of-band**
   (printed in the Claude Code session, or written to a `0600` op-only file). The
   operator presents `pubkey + token` to a one-shot enrollment step
   (`ng remote enroll --pubkey <file> --token <tok>`, run in-sandbox); on a valid
   token the public key is appended to `authorized_keys` (with the forced command
   + hardened options + optional `from=` pin) and the **token is consumed**
   (deleted; a replay fails closed).
4. **Reset / rotate** — after enrollment the orchestrator **revokes the spent
   token** (already consumed) and, if any bootstrap password was ever set, resets
   it and delivers the new value out-of-band (the recommended pubkey-only posture
   means there is usually nothing here). Routine rotation = issue a fresh token /
   re-enroll a new key and drop the old `authorized_keys` line.

#### 4.9.1 Token-authenticated self-enrollment over SSH (default; pubkey-only)

Step 3 above (the operator hand-carries the public key and runs `ng remote
enroll`) is **automated** by `monitor.remote.self_enroll` (default on). The
client delivers its public key THROUGH the SSH key-offer itself and authorizes
it with its one-time token, so the operator runs no second command. The server
stays **pubkey-only** — no password is added.

**Why not token-in-username (the obvious first idea).** OpenSSH authenticates
against a real OS account: for a non-existent login user (`enroll-<token>@host`)
sshd sets `authctxt->valid = 0`, short-circuits pubkey auth *before*
`AuthorizedKeysCommand` runs, and a `fatal("authenticated invalid user")`
backstop makes success structurally impossible (verified against OpenSSH
source; holds 7.6p1–9.x). With one real sandbox account, the token cannot ride
in the username. Keyboard-interactive is also out (the hardened config is
`UsePAM=no`, so it has no backend). The token therefore rides the session's
**stdin**, inside a pubkey-only bootstrap:

1. **Bootstrap gate (`AuthorizedKeysCommand`) — RETIRED; superseded by the
   rootless per-window enroll-key path (§4.9.1 below; impossibility proof in
   [`docs/remote-access-akc-note.md`](remote-access-akc-note.md)).** As
   *originally* designed: sshd consults the `AuthorizedKeysFile` FIRST (enrolled
   keys match there and never reach the command); for an unknown key, a dynamic
   `AuthorizedKeysCommand` would emit an authorizing line — for the OFFERED key
   (`%t %k`, signature-verified by sshd) to a one-shot, **enroll-only** forced
   command (`remote-enroll-session.sh`, `restrict` [+ `from=`]) — **only while a
   token is pending**, otherwise nothing → the unknown key denied. This proved
   impossible for a non-root in-sandbox sshd (OpenSSH requires the AKC uid-0-owned;
   the sandbox userns has no uid-0 files), so the actual implementation installs a
   per-window enroll-only `AuthorizedKeysFile` line instead (steps 2–3 hold
   unchanged).
2. **Enroll-only session.** The client presents its one-time token over
   **stdin** (never argv — keeps it out of `ps`, the client's shell history,
   and `/proc/<pid>/environ`). `remote-enroll-session.sh` refuses any client
   command (`SSH_ORIGINAL_COMMAND` must be empty), reads only a bounded token,
   and delegates to `ng remote enroll` — which performs the **atomic single-use
   consume** (`mv` test-and-claim), the **server-side line reconstruction**
   (forced command + `restrict` [+ `from=`], key baked from the auth-time
   `%t %k` — never a key read from stdin), and takes the **principal from the
   token record**. On any absent/garbage/expired/replayed token it writes no
   key, logs sans token, and exits non-zero.
3. **Reconnect.** The client reconnects with its now-enrolled key, which matches
   the `authorized_keys` FILE and gets the normal channel-only wrapper.

**Invariants:** bootstrap gated SOLELY by a valid one-time token (single-use,
TTL'd, sha256-at-rest, fail-closed, logged); the enroll path is enroll-ONLY (no
shell, no channel verbs, no read/write beyond appending its own
server-reconstructed line); the persisted line is reconstructed server-side
from the key type+blob only; the sandbox stays the boundary (this hardens the
external enrollment path — a worst-case compromise yields a *confined channel
login*, not escape); loopback stays the default, LAN-direct keeps `from_cidr` +
the loud warning, and the token is the only enroll gate either way. The manual
`ng remote enroll --pubkey F --token T` path remains a **fallback** for
environments where the bootstrap is unavailable (e.g. a live sshd that rejects
the `AuthorizedKeysCommand` on path permissions — in which case the
`AuthorizedKeysFile` still authorizes manually-enrolled keys, so the service
still serves).

**Guardrails making "no secret on GitHub" enforceable, not just aspirational:**

- `ng remote enroll` / `remote-up.sh` **never** call a GitHub verb; secrets are
  emitted to stdout or a `0600` file only.
- A **pre-write grep guard** (the same discipline the external-public redaction
  rule uses) scans any RFC/report/comment draft for token/key patterns
  (`BEGIN .* PRIVATE KEY`, `ssh-ed25519 …`, the token format) and **refuses the
  GitHub write** if matched.
- Secrets are **never** written under `reports/` (which `ng wrap-up` uploads) or
  anywhere `ng upload` could reach — only `~/.claude/` (op-only) or session
  stdout.

### 4.10 Operator setup runbook (what the orchestrator hands the operator)

This is the client-side procedure the orchestrator gives the operator verbatim
(extracted at implementation time into a path-referenced
`skills/nexus.remote-access/SKILL.md` so it is available to instruct the operator,
not auto-loaded into every worker). The **secret (the one-time token) is delivered
out-of-band per §4.9** — the runbook text below carries a placeholder, never the
value, so the runbook itself is safe to post on GitHub.

> **Enrolling a remote client (operator steps).**
>
> 1. **Generate your client keypair** (on the client host; the private key never
>    leaves it):
>    ```bash
>    ssh-keygen -t ed25519 -f ~/.ssh/nexus-remote -N ''
>    ```
> 2. **Get your one-time enrollment token.** The orchestrator delivers it
>    **out-of-band** — printed directly in the Claude Code session, or in a
>    `~/.claude/nexus-remote-enroll.token` file readable only by you. *(It is
>    never posted to GitHub; it expires in ~15 min and works once.)*
> 3. **Enroll your public key.** Hand your **public** key + the token to the
>    enrollment step the orchestrator runs in-sandbox:
>    ```bash
>    # orchestrator-side, in-sandbox (you provide the .pub contents + token):
>    ng remote enroll --pubkey ~/.ssh/nexus-remote.pub --token <TOKEN-FROM-STEP-2>
>    ```
>    On success your key is authorized (forced command, request-only) and the
>    token is consumed.
> 4. **Pin the server host key.** The orchestrator gives you the host-key
>    **fingerprint** (non-secret). Verify it on first connect and add it to
>    `~/.ssh/known_hosts` so a future key swap is detected.
> 5. **Connect** (the forced command pins what you can do — file a request,
>    detect/read the reply, fetch results; §4.2, Part D):
>    ```bash
>    ssh -i ~/.ssh/nexus-remote -p 22022 nexus@<bind-address> \
>        request file --kind question --reply required --slug my-ask \
>        --message "…"          # prints the request id; keep it
>    ssh -i ~/.ssh/nexus-remote -p 22022 nexus@<bind-address> \
>        request await <id> --timeout 1800     # detect + read the reply
>    ```
> 6. **Rotate / revoke.** To rotate, re-run steps 1–3 with a fresh key + a new
>    token and tell the orchestrator to drop the old `authorized_keys` line. To
>    revoke immediately, the orchestrator removes your line (no service restart
>    needed).

The orchestrator's half (issue the token out-of-band, run `ng remote enroll`,
print the fingerprint, manage `authorized_keys`) is in §4.8–§4.9; the operator
never needs in-sandbox shell access — they generate a keypair, receive a token
out-of-band, and connect.

### 4.11 The session self-describes its restrictions; expansion is out-of-band only

So a connecting client is never left guessing what it may do (operator round-2
ask, PR `#379`), the endpoint discloses its posture **in three places**. The
LEAN restrictions notice — `_remote_policy_notice`, the one source of truth for
the contract recap + access summary — is emitted by:

1. **Pre-auth SSH `Banner`** — the supervisor writes a banner file from the
   current `command_policy` and passes `-o Banner=…`, so EVERY connection (both
   policies, even an `unfiltered` shell client whose key has no forced command)
   sees the restrictions + options before auth.
2. **A bare connection** (`ssh nexus@host` with no command) prints the notice
   and exits 0 — informational, not a refusal.

The notice states the **imposed access** (channel-only = request-channel only,
no shell; unfiltered = sandbox-confined shell) and the **available commands**.

3. **The `policy` verb** (aliases `help`, `onboarding`) in the `channel-only`
   allowlist emits the FULLER `_remote_onboarding_notice`: the lean notice above
   as a header PLUS the request-channel usage examples, the on-request
   capability-note template, and the "why this is not a C2 backchannel"
   elaboration (paste-length refactor, operator round-3 ask). This is the
   server-delivered half of shrinking the operator-pasted client prompt — the
   verbose material a client needs to actually drive the channel is retrieved
   over the channel **post-connect** instead of bloating the paste. It is
   read-only informational (no new capability; `channel-only` policy unchanged),
   and it RECAPS the control contract while explicitly deferring to the
   operator-supplied paste as the source of consent — a server-delivered
   contract alone would be circular, so the compressed contract stays in the
   paste (`skills/nexus.remote-access`).

> **No in-nexus expansion intake — by design (operator directive, PR `#379`).**
> There is deliberately **no** verb, request kind, or any other path by which a
> remote client can ask the nexus to expand its own privileges. The nexus must
> never have a mechanism that could route — or, worse, let the orchestrator
> accidentally act on — a privilege-expansion request without this sandbox
> operator's explicit, manual decision. The session therefore only *informs*:
> the notice tells the client that broader access is obtained **out-of-band,
> through the client's OWN operator**, who arranges it operator-to-operator with
> this sandbox's operator. If that operator agrees, they relax `command_policy`
> and re-enroll the key **by hand** (§4.8.3, §4.9) — a manual config change is
> the *only* path to relaxation. No request channel, no orchestrator decision,
> no GitHub, no sandbox change.

---

## D. Part D — the bidirectional client↔orchestrator protocol over SSH

> **This part answers the operator's follow-up directly** (PR `#374`): *"full
> communication with the orchestrator through ssh — how to place the request
> file, and how to detect a reply and read it… the orchestrator may spawn a
> normal worker and include references to the worker, directory, and a github
> issue in its reply… alternatively, if requested not to publish on github we may
> lay out in the reply how the client can fetch progress or final results."*
> Part D specifies that round-trip concretely — implementation-ready, harmonized
> with Parts A/B and the skeptic↔worker convention, no new primitive invented.

### D.1 The round-trip at a glance

One request file is the **whole conversation**: the client writes the request
half, the orchestrator appends the reply half, and the **filename suffix tracks
whose turn it is** — exactly the skeptic channel's single-file,
`## Worker response`-section, rename-to-signal model
([§1.5](#15-the-skepticworker-channel)), reused rather than reinvented.

```
 remote client (via SSH/Part A)      watcher              orchestrator
 ──────────────────────────────      ───────              ────────────
 ng request file --reply required
   │  writes  <id>.new.md
   │  ← prints <id> on stdout         claim (atomic rename)
   │                                  <id>.new.md → <id>.claimed.md
   │                                     │ emit `--- requests ---`
 ng request await <id>  ◀──────────┐     │ re-emit until acked
   │  (blocks, polling for             reads, acts:
   │   <id>.replied.md)                  • spawns a worker (optional)
   │                                     • opens a GitHub issue (optional)
   │                                  ng request reply <id> --worker … --dir … --issue …
   │                                     │ appends ## Reply + reply: frontmatter
   │                                     │ atomic mv -f, then rename
   │                                  <id>.claimed.md → <id>.replied.md
   ▼  detects the rename, reads ## Reply ◀──────────────────────────────┘
 follows the references:
   • watches the GitHub issue, OR
   • ng request fetch <id> progress|results   (no-publish branch)
```

The **stable id** ([§2.2](#22-the-request-file-schema)) is the correlation key
end-to-end: it names the request file, it is what `await`/`fetch` resolve, and it
is echoed in the reply frontmatter (`reply.request`) so a client that lost its
local copy can still match. There is **no out-of-band channel** — the request
file *is* the protocol state, which is what makes the round-trip crash-safe
(both ends recover by re-reading the file) and race-safe (every transition is a
single-writer atomic rename).

### D.2 Request placement (client → orchestrator) — concretely

A remote client places a request by invoking, **over the SSH forced command**
([§4.2](#42-what-the-authenticated-client-may-do-forced-command)):

```bash
ssh nexus-remote request file --kind question --reply required \
    --slug summarize-foo --message "Summarize work/foo and propose next steps."
# stdout (the one line the client captures):
#   20260629T184201Z-remote-alice-summarize-foo
```

What happens on the inside, step by exact step:

1. The forced-command dispatcher runs `ng request file` with
   **`--origin remote-<principal>` forced** (the `authorized_keys` principal,
   never client-supplied) and the client's `--kind/--slug/--reply/--message`
   (or `--file`) passed through after allowlist validation. The `remote-`
   prefix is **filename-safe by construction** — a hyphen, never a colon — so the
   stem stays a clean `scp`/`rsync`/tmux-safe token, consistent with the
   window-name origins Part B already uses; `ng request file` rejects a
   principal containing anything outside `[A-Za-z0-9_-]`.
2. `ng request file` **reserves the stem via the `mkdir` reservation-loop**
   ([§2.2a](#22a-collision-free-id-generation)): it atomically creates
   `monitor/.state/requests/<ts>-remote-<principal>-<slug>[-NN].new.md`, retrying
   with the next disambiguator if a sibling producer won the race, then writes the
   body into the reserved name (temp + `mv -f` for the content, the reserved name
   as the rename target). The winning stem is fixed on disk before anything is
   printed.
3. It **prints the stable id** — *the exact stem that won the create in step 2*
   (`<ts>-remote-<principal>-<slug>[-NN]`) — to stdout, which the SSH channel
   returns to the client. Because the id is emitted only after the atomic create
   succeeded, **the printed id is guaranteed to equal the on-disk stem** (no
   racing producer can have taken it). *This is the correlation handle the client
   must keep.*
4. The watcher's `requests_poll` task ([§2.4](#24-the-watchers-watch--claim--emit--re-emit--ack-loop))
   claims it (`.new → .claimed`) and surfaces it to the orchestrator. From here
   the request is an ordinary Part B inbox item — Part D adds only the reply half.

The request file at this point:

```markdown
---
request: 20260629T184201Z-remote-alice-summarize-foo
origin: remote-alice
kind: question
reply: required          # ← Part D: asserts a .replied terminal, not a bare .done
created: 2026-06-29T18:42:01Z
priority: normal
state: new
---

## Request

Summarize work/foo and propose next steps.

## Details

(body as supplied; for a no-publish request, add `publish: false` here or pass
`--no-publish` so the orchestrator routes results back over SSH — see §D.6.)
```

The `reply: required` field is the **only** schema addition a producer makes for
the bidirectional case; everything else is the Part B schema verbatim.

### D.3 The reply channel (orchestrator → client)

When the orchestrator drains a `reply: required` request, it does **not** bare-ack
(`.done`). It calls `ng request reply <id> …`, which:

1. **Appends** a `## Reply` markdown section and a `reply:` frontmatter block to
   the *claimed* file, built in a **temp copy** and `mv -f`'d over the original —
   so a reader never sees a half-written reply (same temp+`mv -f` atomicity as
   the skeptic channel's `answer`, `skeptic-channel.sh:348,523`).
2. **Renames** `<id>.claimed.md → <id>.replied.md`. *This rename is the "reply
   ready" signal* — the single event the client's `await` is watching for. Because
   the content write (step 1) completes *before* the rename (step 2), observing
   `.replied.md` guarantees the `## Reply` is fully present (rename is atomic;
   no torn read).

The orchestrator writes the reply **once**; `ng request reply` refuses a second
reply to an already-`.replied` id (idempotent, fail-closed). If the orchestrator
must amend (e.g. the spawned worker finished and final results are ready), it
updates the **progress/results files** (§D.6), not the terminal request file —
keeping "one reply per request" invariant, mirroring the skeptic channel's "one
answer per request; ask a follow-up with a new slug" rule
(`skeptic-channel.sh:514`).

### D.4 Reply detection + read (the client's side)

The client **detects** a reply by polling for the `.claimed.md → .replied.md`
rename, keyed on the id it captured in §D.2. This is the mirror of the skeptic
channel's `await-answer` blocking loop (`skeptic-channel.sh:547-573`):

```bash
# over SSH; blocks server-side until <id>.replied.md (or .done.md / .failed.md)
ssh nexus-remote request await 20260629T184201Z-remote-alice-summarize-foo --timeout 1800
```

`request await` (the forced-command verb → `ng request await`) loops on a short
interval, globbing `monitor/.state/requests/<id>.*.md` and inspecting the suffix:

| Observed suffix | `await` returns | Exit |
|---|---|---|
| `.replied.md` | prints the `## Reply` body + `reply:` frontmatter | `0` |
| `.done.md` | prints "acknowledged, no reply body" | `0` |
| `.failed.md` | prints the failure reason | `2` |
| (timeout, still `.claimed`/`.new`) | prints "still pending" | `4` |

Three properties make detection **race-safe**:

- **Atomic transition.** The orchestrator's `mv -f` rename is atomic on one
  filesystem; the client observes either `.claimed.md` or `.replied.md`, never a
  torn intermediate (§D.3). The reply *content* is fully written before the
  rename, so "saw `.replied` ⇒ content present."
- **Stable-id correlation.** The id is invariant across every rename
  ([§2.2](#22-the-request-file-schema)); the client never has to guess a path,
  and a late/duplicate poll resolves to the same terminal file.
- **Ownership scoping.** `await`/`fetch` verify the file's `origin` equals the
  calling principal before reading ([§4.2](#42-what-the-authenticated-client-may-do-forced-command)),
  so a remote client can read **only its own** round-trip — no cross-client leak.

A client that prefers not to hold a blocking SSH session can **poll** instead:
`ng request show <id>` (or a bare `request await --timeout 0`) returns the current
state immediately; the client re-invokes on its own cadence. Either way the
detection contract is the same: *the suffix is the state; the rename is the
signal.*

### D.5 Reply schema: references, publish flag, fetch pointers

The `## Reply` section is human-readable prose; the **machine-readable**
references live in a `reply:` frontmatter block the orchestrator appends. This is
what lets the client *follow the work to completion*:

```markdown
---
request: 20260629T184201Z-remote-alice-summarize-foo
origin: remote-alice
kind: question
reply: required
created: 2026-06-29T18:42:01Z
state: replied
reply:
  status: spawned          # spawned | answered | rejected | deferred
  replied_at: 2026-06-29T18:44:10Z
  publish: true            # true → follow the GitHub issue; false → fetch over SSH (§D.6)
  worker:                  # present iff a worker was spawned
    window: foo-summary    # tmux window name (what `ng pane-state` keys on)
    directory: $NEXUS_ROOT/work/foo-summary
    session_id: 7f3c…      # Claude Code session UUID (for liveness via the jsonl mtime)
  github_issue: <your-org>/<your-nexus>#412   # present iff publish=true
  # no-publish branch (publish=false) — present instead of github_issue.
  # ADVISORY ONLY: human/local-reader hints. `fetch` IGNORES these and recomputes
  # the path from <id> (§D.6) — they cannot redirect a fetch outside replies/<id>/.
  progress_path: monitor/.state/requests/replies/<id>/progress.md
  results_path:  monitor/.state/requests/replies/<id>/results.md
---

## Reply

Spawned worker `foo-summary` in `work/foo-summary/`; tracking at
<your-org>/<your-nexus>#412. Follow that issue for progress and the final summary,
or `request await`/watch the issue. (If you asked not to publish, see the
progress/results paths above and `request fetch`.)
```

| `reply:` field | Meaning | Operator ask it satisfies |
|---|---|---|
| `status` | `spawned`/`answered`/`rejected`/`deferred` — what the orchestrator did | — |
| `worker.window` | tmux window of the spawned worker | "references to the **worker**" |
| `worker.directory` | the worker's working tree (abs path) | "references to the **directory**" |
| `worker.session_id` | session UUID — lets the client reason about liveness (jsonl mtime, per CLAUDE.md) | worker reference (liveness) |
| `github_issue` | `owner/repo#N` the orchestrator opened | "a **github issue** in its reply" |
| `publish` | `true` → follow the issue; `false` → fetch over SSH | switches the two branches |
| `progress_path` / `results_path` | **advisory** location hints for the no-publish files (§D.6); `fetch` ignores them and recomputes from `<id>` | "how the client can **fetch progress / final results**" |

`status=answered` (with no `worker`) covers the case where the orchestrator
answered **inline** in `## Reply` without spawning anything — the client just
reads the prose. `status=rejected`/`deferred` carry a reason in `## Reply`.

### D.6 The no-publish branch — fetch progress / final results over SSH

If the request set `publish: false` (or passed `--no-publish`), the orchestrator
**does not open a GitHub issue**. Instead it (and the worker it spawns) write to a
**per-request reply dir** the client can pull over the confined channel:

```
monitor/.state/requests/replies/<id>/
    progress.md     # append-only; the worker/orchestrator update it as work proceeds
    results.md      # the final deliverable; written last (temp + mv -f → atomic)
    manifest.json   # optional: {files: […], status: running|done, updated_at}
```

The client pulls them with the `fetch` verb, which takes a **fixed selector
(`progress`|`results`), never a path**:

```bash
ssh nexus-remote request fetch <id> progress   # tail replies/<id>/progress.md
ssh nexus-remote request fetch <id> results    # replies/<id>/results.md (not-ready → non-zero)
```

`ng request fetch <id> {progress|results}` — **path-confined by construction**:

- computes the target as `replies/<id>/progress.md` or `replies/<id>/results.md`
  **from `<id>` and the fixed selector alone** — it **never dereferences a
  client-supplied path and never reads a `*_path` field from the reply
  frontmatter**. The only filesystem location it can ever name is
  `monitor/.state/requests/replies/<id>/{progress,results}.md`, and `<id>` is
  ownership-checked against the calling principal's `origin`
  ([§D.4](#d4-reply-detection--read-the-clients-side)). There is no input through
  which the client can widen the target — this is what restores the unambiguous
  guarantee: **a client can only ever read under its own `replies/<id>/`**;
- streams `progress.md` (which the worker keeps current) or `results.md`;
- if `results.md` does not yet exist, exits non-zero with "not ready — poll
  `progress`," so the client polls progress until the manifest flips to `done`.

> **`progress_path`/`results_path` in the reply are ADVISORY, not a fetch
> input.** They document *where the files live* for a human reading the reply (and
> for a local agent that already has full read access); `fetch` ignores them and
> recomputes the path from `<id>`. So even a malformed or hostile `*_path` value
> in the frontmatter cannot redirect a fetch outside `replies/<id>/`. (The fields
> are retained because they are informative and because the local, in-sandbox
> reader — which is *not* path-confined — may use them directly.)

**How the worker keeps the fetch files current.** The orchestrator spawns the
worker with its working dir = `reply.worker.directory` and instructs it (in the
spawn prompt) to write `progress.md`/`results.md` **into the reply dir**
(`monitor/.state/requests/replies/<id>/`). To reuse the existing **report**
convention cheaply, the worker (or orchestrator) **materializes the report
*into* the reply dir** — a symlink `replies/<id>/results.md → ../../../../reports/…md`
**resolved and validated to stay under the nexus tree**, or a plain `cp` of the
report into `replies/<id>/results.md` on wrap-up. Either way the artifact the
client fetches **lives at the fixed `replies/<id>/` location**; the report is
*copied/linked in*, never reached by an arbitrary-path dereference. (A symlink is
only honoured if its resolved target stays within `$SANDBOX_PROJECT_DIR`; `fetch`
rejects a symlink that escapes — defence in depth, since the client cannot supply
the link target anyway.) **No GitHub, no external publish** — exactly the
operator's "fetch progress / final results over the channel" alternative.

This branch is a clean specialization: same request file, same reply rename, same
`await` detection; only `publish=false` swaps the reply's *reference* fields from
`github_issue` to the advisory `{progress,results}_path` and unlocks the `fetch`
verb — whose reachable surface stays pinned to `replies/<id>/{progress,results}.md`.

### D.7 End-to-end worked example

A concrete walk, with the file at each step. Remote client = another Claude on
the LAN, principal `alice`; this nexus's issue repo = `<your-org>/<your-nexus>`.

**1 — authenticate + place the request (client).**

```bash
$ ssh nexus-remote request file --kind question --reply required \
      --slug summarize-foo --message "Summarize work/foo; open an issue to track."
20260629T184201Z-remote-alice-summarize-foo          # ← client captures this id
```
On disk: `monitor/.state/requests/20260629T184201Z-remote-alice-summarize-foo.new.md`
(frontmatter as §D.2, `origin: remote-alice`, `reply: required`).

**2 — watcher claims + surfaces (watcher → orchestrator).**
`requests_poll` renames `.new.md → .claimed.md` and stages into the next emit:

```
--- requests ---
request=20260629T184201Z-remote-alice-summarize-foo origin=remote-alice kind=question priority=normal
    summary: Summarize work/foo; open an issue to track.
    file=…/requests/20260629T184201Z-remote-alice-summarize-foo.claimed.md
```
The orchestrator sees this in the pane it already reads; re-emitted until acked.

**3 — client begins waiting (client).**

```bash
$ ssh nexus-remote request await 20260629T184201Z-remote-alice-summarize-foo --timeout 1800
# blocks server-side, polling for .replied.md
```

**4 — orchestrator acts: spawn a worker + open an issue (orchestrator).**
The orchestrator reads the claimed file, spawns a worker via the tmux-spawn
pattern (window `foo-summary`, dir `work/foo-summary/`), opens
`<your-org>/<your-nexus>#412` via the bot, then replies:

```bash
$ ng request reply 20260629T184201Z-remote-alice-summarize-foo \
      --worker foo-summary \
      --dir $NEXUS_ROOT/work/foo-summary \
      --issue <your-org>/<your-nexus>#412 \
      --message "Spawned foo-summary; tracking at <your-org>/<your-nexus>#412."
```
This appends `## Reply` + the `reply:` block (§D.5, `publish: true`,
`github_issue: <your-org>/<your-nexus>#412`, `worker.{window,directory,session_id}`)
and renames `.claimed.md → .replied.md`.

**5 — client detects + reads (client).**
`await` observes `.replied.md`, returns 0, and prints the `## Reply` + frontmatter:

```
status: spawned
worker.window: foo-summary
worker.directory: $NEXUS_ROOT/work/foo-summary
github_issue: <your-org>/<your-nexus>#412
## Reply
Spawned worker `foo-summary` …; tracking at <your-org>/<your-nexus>#412.
```

**6 — client follows the work (client).**
Because `publish=true`, the client watches `<your-org>/<your-nexus>#412` (it has its
own GitHub read access, independent of this channel) for progress and the final
summary the worker posts on wrap-up.

**No-publish variant (steps 4–6).** If step 1 passed `--no-publish`, step 4's
reply carries `publish: false` + `progress_path`/`results_path` instead of
`github_issue`, and the worker writes those files. Step 6 becomes:

```bash
$ ssh nexus-remote request fetch <id> progress   # poll until manifest=done
$ ssh nexus-remote request fetch <id> results     # pull the final summary
```
Nothing touches GitHub; the deliverable travels back over the same SSH channel.

### D.8 Race-safety, correlation & crash-recovery (for the reviewer)

A compact statement of the invariants a skeptic should check:

- **Single-writer per transition.** `new`(client) → `claimed`(watcher) →
  `{replied|done|failed}`(orchestrator). No two components ever write the same
  suffix; every transition is one atomic `mv -f`. No lock needed beyond the
  rename itself (same argument as [§2.3](#23-lifecycle-states-the-rename-is-the-signal)).
- **Content-before-signal.** The reply body is written (temp + `mv -f` over the
  file) **before** the state rename, so "observed `.replied` ⇒ body complete."
  No torn read is possible across the detection boundary.
- **Correlation is the stable id**, allocated **collision-free** by the `mkdir`
  reservation-loop ([§2.2a](#22a-collision-free-id-generation)) and **printed only
  after the create wins**, so the id the client holds is exactly the on-disk stem;
  it is invariant across renames and echoed in `reply.request`. The client needs
  nothing but the id `file` printed.
- **Crash recovery.** Watcher crash → files persist; startup sweep re-surfaces
  every `.claimed.md`. Orchestrator crash mid-handle → the request stays
  `.claimed.md`, re-emitted until it acks/replies after restart. Client
  disconnect mid-`await` → state is on disk; the client reconnects and
  re-`await`s (or `show`s) the same id — no lost reply. Reply written but client
  never reads → GC retains `.replied.md` until `monitor.requests.retention_seconds`.
- **Bounded, ownership-scoped reads.** `await`/`fetch` resolve only within the
  inbox/reply tree and only for the calling principal's own `origin`
  ([§4.2](#42-what-the-authenticated-client-may-do-forced-command)) — detection
  adds no new exfil surface.
- **No new orchestrator-pane writer; no new network primitive.** The reply rides
  the request file (disk), and the only inbound transport is Part A's confined
  SSH — Part D introduces neither a new pane writer nor a new listener.

---

## 5. Phased implementation plan

Ordered so each phase is independently valuable and the risky/cross-repo parts
land last, behind flags.

| Phase | Lands | Flag / default | Depends on |
|---|---|---|---|
| **B0** | `request-channel.sh` + `ng request` façade + schema + `test-request-channel.sh`; **no watcher wiring** (inert, like the scheduler Phase 0) | n/a (new scripts, unused) | — |
| **B1** | watcher `requests_poll` task: claim → `--- requests ---` emit → re-emit-until-ack (reusing `_reemit.sh`); cap + fairness; tests | `monitor.requests.enabled` (default **off**) | B0 |
| **B2** | orchestrator drain protocol in `agent-prompt.md` + `nexus.tmux-spawn` skill; `kind=spawn-skeptic` formalizes the skeptic request; flip default **on** after a soak | `monitor.requests.enabled` → on | B1 |
| **D1** | reply half: `.replied.md` state + `ng request reply` (writes `## Reply` + `reply:` frontmatter, atomic) + `ng request await` (client detect/read, mirrors `await-answer`) + `ng request fetch` + reply-dir convention; tests for atomicity, ownership scoping, timeout/exit-code map | `monitor.requests.enabled` (rides B) | B0/B1 |
| **D2** | orchestrator reply protocol in `agent-prompt.md` (spawn-worker → fill `reply.worker.*`, open issue or write `replies/<id>/`); no-publish routing | `monitor.requests.enabled` → on | D1, B2 |
| **C1** | generalize `_reemit.sh` into the shared ack-gated registry; migrate **pending decisions** onto it behind an A/B parity test | parity-gated; old path until soaked | B1 |
| **C2** | migrate **mentions** onto the shared registry; retire the per-source bookkeeping; doc the `_produce`/`_is_acked` interface | parity-gated | C1 |
| **A0** | `monitor/remote-forced-command.sh` (request-only: `request file`/`await`/`fetch` + opt-in `attach -r`) **with a test suite covering `SSH_ORIGINAL_COMMAND` injection + non-wideable `attach -r` + forced `--origin remote-<principal>` + ownership-scoped `await`/`fetch` path-confinement + fail-closed unknown verbs** (§4.2, §D.4) + `monitor.remote.*` config (default `enabled: false`, §4.8.1) | `monitor.remote.enabled` (default **off**) | B2 + D1 (the `request`/`await`/`fetch` verbs) |
| **A0b** | the **registered off-by-default service** (§4.8): `remote-sshd-supervised.sh` + `remote-ssh-health.sh` + the `services.registry` row (`emit-only`) + `monitor/remote-up.sh` enable helper (mirrors `jupyter-up.sh`); healthcheck treats disabled-as-healthy; tests for "inert while `enabled:false`" | `monitor.remote.enabled` (off) | A0 |
| **A0c** | the **out-of-band secret flow** (§4.9): `ng remote enroll` (one-time token, single-use+TTL, consumed), host-key generation, the pre-write grep guard refusing GitHub writes that match key/token patterns; tests for token replay-fails-closed + no-secret-on-any-`ng`-verb | off | A0b |
| **A0d** | the **operator setup runbook** as `skills/nexus.remote-access/SKILL.md` (§4.10), path-referenced (not auto-loaded), with the secret as an out-of-band placeholder; **propose the agent_sandbox side as an issue/PR on `katosh/agent_sandbox`** | off; operator go-ahead for the agent_sandbox PR | A0c |
| **A1** | (operator-gated) the chosen transport — inbound chaperon drop *or* in-sandbox sshd — in `agent_sandbox`; opt-in `attach -r`; orchestrator runs the §4.8.3 enable procedure | operator decision | A0d + agent_sandbox |

Part B is usable on its own (B0–B2) without ever doing A or C. **Part D (D1–D2)
adds the reply half on top of B** and is what makes the channel a true
round-trip — it is in-repo (no cross-repo dependency) and rides the same
`monitor.requests.enabled` flag. Part C is a pure internal cleanup that makes B
and the existing sources share one engine. Part A is the only cross-repo,
security-sensitive piece and is fully gated; the remote client's *acting* and
*reply-reading* affordances are exactly the B+D verbs (`file`/`await`/`fetch`)
exposed through A's forced command.

---

## 6. Failure modes — and how each fails closed

| Failure | Behaviour | Fails closed? |
|---|---|---|
| Watcher crashes mid-backlog | files persist; startup sweep re-surfaces every `.claimed.md` | ✅ nothing lost |
| Paste of `--- requests ---` doesn't land | trailer-signature verify (rc 4) → `paste_with_retry` | ✅ retried |
| Orchestrator never acks a request | two-tier re-emit, then **max-age → `.failed.md`** + loud log | ✅ bounded, surfaced |
| Two producers, same `<ts>`+`origin`+`slug` (same second) | **`mkdir` reservation-loop** ([§2.2a](#22a-collision-free-id-generation)): the loser of the atomic `mkdir` retries with the next numeric disambiguator (`-01`, `-02`, …) until a `mkdir` wins; the **id printed to the client is the stem that won**, so no clobber and no client/disk divergence | ✅ no silent loss, no id mismatch |
| Malformed request file | watcher renames `.new → .failed`, surfaces once | ✅ never blocks the queue |
| Reply written but client never `await`s (Part D) | `.replied.md` + `replies/<id>/` persist until `retention_seconds` GC | ✅ reply not lost; client can read late |
| Client disconnects mid-`await` (Part D) | state is on disk; reconnect + re-`await`/`show` same id | ✅ no lost reply |
| Orchestrator replies twice (Part D) | `ng request reply` refuses an already-`.replied` id, non-zero | ✅ one reply per request; no torn file |
| Torn read of a half-written reply (Part D) | content `mv -f`'d **before** the state rename; reader sees `.claimed` until atomic flip | ✅ "saw `.replied` ⇒ body complete" |
| No-publish results not ready when fetched (Part D) | `request fetch results` exits non-zero "not ready — poll progress" | ✅ client polls, no empty/partial pull |
| Cross-client reply read attempt (Part D) | `await`/`fetch` verify `origin` == calling principal first | ✅ reads only own round-trip |
| Backlog explosion (1000s of requests) | per-emit cap + on-disk backlog (no memory growth); fairness round-robin | ✅ orchestrator drains at its pace |
| Remote `sshd` wedged (Part A) | registered service healthcheck → `--- service health ---` | ✅ surfaced, not silent |
| Remote forced-command sees unknown verb | refuse + non-zero exit + log; **never** a shell | ✅ fail-loud |
| Remote key compromised | revoke the `authorized_keys` line; principal is request-only (no shell, no read primitive) | ✅ blast radius bounded |
| Anything requiring sandbox-weakening | flagged out-of-bounds; not in the design | ✅ by construction |

---

## 7. Compatibility and non-goals

**Compatible by construction with:**
- the **skeptic↔worker channel** — same primitive, complementary direction
  ([§2.8](#28-harmonization-with-the-skepticworker-convention-explicit)); the
  proposed `_channel_lib.sh` extraction makes the shared core literal. **Part D's
  reply half reuses the skeptic channel's exact single-file, response-section,
  rename-to-signal, `await`-loop model** (`.replied.md` ≙ `.answered.md`,
  `ng request await` ≙ `await-answer`) — it is the same convention extended to
  the worker→orchestrator direction, not a competing one.
- the **pending-decisions channel** — Part B is its generalization; Part C
  migrates it onto the shared registry with a parity test.
- the **watcher's exclusive orchestrator-pane write** — preserved; no new writer.
- the **`ng` facade convention** — `ng request` mirrors `ng skeptic`.

**Non-goals (explicitly out of scope):**
- Moving `paste-followup.sh` (orchestrator→worker) into the watcher — different
  direction, not this RFC.
- Routing observed-condition sources (service health, idle, bells, drift)
  through the request lifecycle — wrong shape ([§3.1](#31-the-question-answered)).
- Any change to the GitHub eligibility filter or the bot identity model.
- Implementing the agent_sandbox side of Part A — proposed only.
- A networked message bus / external queue — the on-disk inbox + the watcher's
  existing emit are sufficient and keep the no-new-daemon property (except the
  optional, gated Part A endpoint).

---

## 8. Recommendation summary (stop here for the operator's decision)

1. **Adopt Part B** as specified: a markdown request inbox under
   `monitor/.state/requests/`, watcher-claimed and watcher-surfaced, re-emit-until-ack
   via the generalized `_reemit.sh`, harmonized with the skeptic-channel
   rename-is-the-signal convention. Ship B0→B2 behind `monitor.requests.enabled`.
   This formalizes the worker→orchestrator request (canonically "spawn a
   skeptic") with no new orchestrator-pane writer.
2. **Adopt Part C** as a contract-unification (not a code-collapse): generalize
   the ack-gated emit registry, migrate the discrete-request sources (decisions,
   mentions) onto it behind parity tests, leave observed-condition sources
   distinct. This is the maintainability/anti-drift win.
3. **Adopt Part D** as the bidirectional round-trip: extend the Part B lifecycle
   with `.replied.md`, add `ng request reply` (orchestrator writes `## Reply` +
   `reply:` frontmatter into the request file, atomic, then renames) and
   `ng request await`/`fetch` (client detects via the rename and reads — the
   mirror of the skeptic channel's `await-answer`). The reply carries the
   **worker window, working directory, session id, and GitHub issue** so the
   client can follow the work; the `publish: false` branch swaps the issue for
   **progress/results files** the client pulls over the same confined SSH channel.
   This is in-repo (D1–D2), rides `monitor.requests.enabled`, and reuses the
   skeptic convention rather than inventing one — it is the concrete,
   implementation-ready answer to the operator's "full communication with the
   orchestrator through SSH" directive.
4. **Decide Part A's posture.** Recommended: **request-only**, with **read-only
   attach opt-in**. Prefer the **inbound-chaperon request drop** (alternative 1)
   if agent_sandbox can add it — smallest, tightest surface, a pure extension of
   B; otherwise an **in-sandbox `sshd` with a request-only forced command**. The
   remote client's full affordance is the B+D verb set (`file`/`await`/`fetch`)
   behind the forced command — file a request, detect the reply, read it or fetch
   results — and nothing more (in `channel-only`; `unfiltered` grants a
   sandbox-confined shell as an opt-in trust mode). The endpoint ships as a
   **registered, OFF-BY-DEFAULT supervised service** (registration is the enable
   signal — no separate flag; jupyterlab-pattern registry row + healthcheck +
   `remote-up.sh` enable/`--down` disable helper, §4.8) the orchestrator turns on
   by direct action; **all secret material is provisioned
   strictly out-of-band, never on GitHub** (one-time TTL'd enrollment token,
   client private key never leaves the client, pre-write grep guard, §4.9); and
   the operator follows a precise **client-side setup runbook** (§4.10). The
   sandbox boundary is preserved by running the daemon *inside* the sandbox; the
   agent_sandbox side is **proposed, operator-decided**, and lands last behind
   `monitor.remote.enabled`.

**Implement nothing beyond this RFC until the operator greenlights the design.**
(The operator has asked for full implementation with expert-subagent reviews; per
the standing review-first rule that is a **separate, orchestrator-dispatched
effort** once this spec is confirmed credible — this round locks the spec only.)

---

## Appendix A — file:line index (review citations)

| Mechanism | Primary citation |
|---|---|
| compose report body + section order | `monitor/watcher/main.sh:1274-1428` |
| emit filter pipeline | `monitor/watcher/main.sh:3029-3040` |
| `_dedup_emit_lines` (id-keyed dedup) | `monitor/watcher/_emit_filters.sh:412-435` |
| `paste_to_target` + signature verify + rc map | `monitor/watcher/main.sh:1464-1528` |
| `paste_with_retry` | `monitor/watcher/main.sh:1530-1541` |
| re-emit registry (two-tier, GC, max-age) | `monitor/watcher/_reemit.sh:138-531` |
| pending-decision write (hook) + schema | `monitor/hooks/decision-emit.sh:66-67,91-104,140-157` |
| Case-W relay (watcher-synthesized decision) | `monitor/watcher/_unstick.sh:511-599` |
| `render_pending_decisions` + line shape | `monitor/watcher/_idle_probe.sh:2854-2989` |
| decision ack shapes (rm / tombstone) | `monitor/README.md:638-653`; `agent-prompt.md:476-509` |
| skeptic channel layout + lifecycle + frontmatter | `monitor/skeptic-channel.sh:138,185-187,338-364,442-535,654-658` |
| `ng skeptic` facade | `monitor/ng:3815-3819` |
| `paste-followup.sh` (orchestrator→worker) + ledger | `monitor/paste-followup.sh:149-170` |
| spawn-worker skeptic wiring + provenance | `monitor/spawn-worker.sh:520-593,1386-1422` |
| tmux session inside sandbox; headless watcher | `monitor/watcher/launcher.sh`; `monitor/watcher/entry.sh` |
| `sandbox-notify` / chaperon (inside→outside) | `docs/operating/notifications.md`; `monitor/notify.sh` |
| single-instance flock (cross-namespace) | `docs/reference/watcher-protocol.md` "Single-instance lock" |
| sandbox writable-path confinement | `docs/admin/security.md`; `monitor/write-probe.sh` |
| supervised-service registry schema (name/workdir/launch/health/log/policy) | `monitor/services.registry.example` |
| off-by-default → enable helper (jupyterlab pattern, §4.8) | `monitor/jupyter-up.sh`; `monitor/labsh-supervised.sh`; `monitor/jupyter-health.sh` |
| service start/stop + registry ownership | `monitor/svc.sh`; `monitor/bootstrap-recover.sh:224` |
| config knob read pattern (`monitor.*` from `config/nexus.yml`) | `config/nexus.example.yml`; `monitor/ng:1222` (`_skeptic_cfg_int`) |

## Appendix B — design conventions reused

| This RFC reuses | From |
|---|---|
| facade-over-scripts; unify contract not code | [`docs/ng-interface-proposal.md`](ng-interface-proposal.md) |
| A/B parity test for a behaviour-preserving refactor | [`docs/watcher-scheduling-refactor.md`](watcher-scheduling-refactor.md) §6 |
| "the rename is the signal"; atomic temp+`mv -f` | `monitor/skeptic-channel.sh` |
| reply-into-same-file + `## Reply` section (Part D ≙ `## Worker response`) | `monitor/skeptic-channel.sh:363-364,442-535` |
| `await`-loop blocking detect/read (Part D ≙ `await-answer`) | `monitor/skeptic-channel.sh:544-573` |
| re-emit-until-acked, two-tier backoff, max-age | `monitor/watcher/_reemit.sh` |
| ack-by-rename / tombstone | pending-decisions channel (issue `#129`) |
| fail-loud refusal (never fall through) | the `gh` wrapper; `monitor/mint-token.sh` |
| registered service + healthcheck surfacing | `monitor/services.registry`; `--- service health ---` |
