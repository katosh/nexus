# `ng` interface survey + unification proposal

**Status:** ✅ accepted & implemented — operator greenlit; realized in PR `#347`
(facade-over-scripts: eight pass-through `ng` facades + a categorized `ng --help`
verb index + the doc-update set in §4). Retained as the design record / ADR for
*why* facades over migration. Original proposal text preserved verbatim below.
**Baseline:** `dev` @ `48d3e7c`. Triggered by PR `#345` (`ng retire-preflight`)
and <operator>'s directive: *"see what other commands should be wrapped like this …
[and] consider, instead of just wrapping things, if commands should just be
migrated for a unified interface and intuitive use."*

The guiding constraint is the operator's own no-bloat principle (PR `#344`):
prefer single-source-of-truth; **wrap only where it adds real discoverability,
migrate only where it genuinely unifies.**

---

## 1. The surface today

`monitor/ng` is a 3829-line bash dispatcher exposing **≈41 leaf verbs** (29
top-level `case` arms at `ng:3789` + the `issue`/`pr`/`dashboard`/`skeptic`
sub-verbs). It already demonstrates *both* wrapping idioms:

- **Pure pass-through facade** — `ng skeptic <sub>` is literally
  `exec skeptic-channel.sh "$@"` (`ng:cmd_skeptic`). This is the exact shape
  PR `#345` adds for `retire-preflight`. **The precedent already exists and
  works.**
- **Partial wrap** — `ng mint-jwt` wraps `mint-token.sh --jwt-only`, yet the
  *common* path (`mint-token.sh` for the installation token) is **not** a verb:
  workers still call `GH_TOKEN=$(./monitor/mint-token.sh)`. That asymmetry is a
  small wart worth noting.
- **Thin shim** — `ng upload` over `upload-asset.sh` (same flags).

`ng` already shells out to four standalone scripts internally:
`mint-token.sh`, `skeptic-channel.sh`, `spawn-worker.sh`, `svc.sh`.

### The discoverability gap (the real problem PR `#345` is a symptom of)

`ng --help` runs `awk '/^$/{exit} NR>1'` — it prints **only the leading comment
block**, and there is **no top-level verb index** anywhere. The README verb
table (`README.md:1115`) documents ~12 of the 41 verbs — the GitHub-write
subset. **~29 verbs are undocumented in the table** (`pr`, `preflight`, `show`,
`report-init`, `report-check`, `fetch-asset`, `service-incident`,
`suppress-emit`, `mint-jwt`, `respawn`, `spawn-decision`, `wrap-up-check`,
`interactive-sessions`, `skeptic`, …). The orchestrator "kept reaching for
retire-preflight via `ng` and hitting `unknown subcommand`" precisely because
there is no single place that says *"here is everything `ng` can do."* Wrapping
one more script treats the symptom; the cure is a **verb index + a complete
table**.

---

## 2. Inventory & classification

Scope: command-line ops an orchestrator/worker invokes **directly** by hand.
Excluded as out-of-scope (correctly **leave**): sourced libs (`_*.sh`,
`locals-env.sh`, `bootstrap-venv.sh`), hook callbacks (`worker-heartbeat.sh`,
`hooks/*`), watcher internals (`watcher/*`), one-shot installers/provisioners
(`install-*.sh`, `link-nexus-tools.sh`), and the test harness (`test-*.sh`).

| Script | Purpose | Who calls it | Already `ng`? | Call |
|---|---|---|---|---|
| `retire-preflight.sh` | Synchronous go/no-go gate before `kill-window` | orchestrator | PR `#345` | **WRAP** (in flight ✓) |
| `pane-state.sh` | Classify a worker pane (`idle\|busy\|…`) | orchestrator | no | **WRAP** |
| `write-probe.sh` | Pre-flight a deliverable path is writable | worker | no | **WRAP** |
| `declare-wait.sh` | Worker self-declares async external wait | worker | no | **WRAP** |
| `declare-no-wait.sh` | Mark an async launch fire-and-forget | worker | no | **WRAP** |
| `paste-followup.sh` | Canonical follow-up paste into a worker window | orchestrator | no | **WRAP** (see note) |
| `mint-token.sh` | Print installation token (`$(…)` idiom) | both | partial (`mint-jwt`) | **WRAP-symmetry** (low) |
| `user-pat.sh` | Print user PAT for private reads | worker | no | **WRAP-symmetry** (low) |
| `skeptic-channel.sh` | Worker↔skeptic comms + nudge | both | `ng skeptic` ✓ | done |
| `upload-asset.sh` | Push file to asset repo, print pinned URL | both | `ng upload` ✓ | done |
| `svc.sh` | Service cockpit + lifecycle CLI (`up/restart/down`) | orchestrator | internal only | **LEAVE** |
| `spawn-worker.sh` | Worker launcher (floor injection, pinning, resume) | orchestrator | internal only | **LEAVE** |
| `notify.sh` | Push fan-out (Pushover/ntfy/SMTP) | both (via `sandbox-notify`) | no | **LEAVE** (weak-wrap optional) |
| `revive-watcher.sh` | One-shot watcher revival | orchestrator (Monitor) | no | **LEAVE** |
| `bootstrap-recover.sh` / `boot-recover.sh` | Full-stack / cold-boot recovery | hook + orchestrator | no | **LEAVE** |
| `jupyter-up.sh` + `jupyter-*` + `labsh-*` | Jupyter-as-a-service subsystem | both | no | **LEAVE** (own skill) |
| `calibrate-pressure-thresholds.sh` | Periodic activity-pressure-threshold calibration analysis (issue `#79`) | orchestrator (rare) | no | **LEAVE** (maintenance one-off, not a mid-loop op) |

### Classification rationale

**WRAP (facade belongs under `ng` for discoverability).** Every WRAP candidate
shares the retire-preflight shape: a **one-shot, machine-parseable op an agent
reaches for mid-loop**, where the natural instinct is to type `ng <thing>`.
`pane-state`, `write-probe`, `declare-wait`/`declare-no-wait` are the strongest:
they are short-lived, frequently-typed, and each already has a dedicated
`test-*.sh` unit that a facade **preserves** (the facade is `exec`, the logic
and its test stay put). `paste-followup` is orchestrator-only and already
muscle-memory, so its discoverability win is smaller — wrap it for *consistency*
(all window ops under one prefix) rather than need. `mint-token`/`user-pat` are
the symmetry fix: since `ng mint-jwt` exists, `ng mint-token` "should" too —
but both live inside a `$(…)` capture idiom that works identically whether the
callee is a script or `ng`, so this is low-value polish, not a real gap.

**MIGRATE (move logic INTO `ng`): recommended for *none* of them.** This is the
key finding and it directly answers the operator's "migrate vs wrap" question.
Migration means deleting the standalone and absorbing its body into `ng`. For
**every** candidate that buys nothing and costs three things: (1) it destroys
the script's independently-runnable `test-*.sh` unit (the suite sources or execs
the script directly — `test-pane-state.sh`, `test-retire-preflight.sh`,
`test-write-probe.sh`, `test-declare-wait.sh`, …); (2) it inflates an
already-3829-line file toward unmaintainability and a worse merge-conflict
surface; (3) it violates the PR `#344` no-bloat principle by *duplicating* logic
that already has a single home. The `ng skeptic` precedent proves the facade
gives a unified interface **without** migration. **Conclusion: facade-over-
scripts is the right convention; logic-in-`ng` should be reserved for genuinely
new ops that never had a standalone unit to preserve.**

**LEAVE (genuinely standalone).** Three sub-reasons:
- **Peer interfaces, not one-shot ops.** `svc.sh` is its own cockpit CLI
  (`svc.sh up/restart/down/status`); `spawn-worker.sh` is a substantial
  launcher subsystem. Each is a coherent front door. Folding them under `ng`
  would create *two* doors to the same thing and blur which is canonical. `ng`
  already calls both internally — that is the right relationship.
- **Recovery / lifecycle, not interactive.** `bootstrap-recover.sh`,
  `boot-recover.sh`, `revive-watcher.sh` are hook-wired or Monitor-wired
  recovery paths, not things you type during normal work.
- **Subsystems with their own entry + skill.** The `jupyter-*`/`labsh-*` family
  is documented end-to-end by `skills/nexus.jupyter`; `jupyter-up.sh` is its
  one-command door. `notify.sh` is reached through the `sandbox-notify`
  wrapper. Re-fronting these under `ng` adds a layer without unifying anything.

---

## 3. Unified-interface design sketch

If the operator greenlights wrapping, do it under **one consistent contract** so
`ng` reads as a single intuitive interface, not 41 ad-hoc verbs.

### a. Verb naming
Today's set mixes **action verbs** (`process`, `react`, `reply`, `close`,
`upload`, `respawn`) with **noun/status reads** (`pane-state`, `watcher-status`,
`nexus-identity`, `spawn-decision`). Codify the split already latent in the code:
- **Actions** → imperative verb (`react`, `close`, `wrap-up`, `paste-followup`).
- **Read-only state queries** → noun or `<noun>-status` (`pane-state`,
  `watcher-status`). New wraps follow suit: `pane-state` (read) keeps its noun;
  `write-probe`, `declare-wait`, `retire-preflight` (actions/checks) stay
  verb-ish. No renames of existing verbs — naming convention is **forward-only**
  guidance to avoid churn.

### b. The `--repo` contract (issue `#108`)
Write verbs derive the target repo from the cwd's git `origin`, which is **wrong
in any secondary clone or worktree** whose origin points at `nexus-code` rather
than the asset/issue repo. Today each write verb separately accepts `--repo`.
Unify it: (1) document that **every** mutating verb accepts `--repo` and that
secondary-clone workers MUST pass it; (2) consider a single `NG_REPO` env var /
`config/nexus.yml` default that all write verbs honor, collapsing the
per-call boilerplate the worker floor currently has to repeat. This is the
highest-value *intuitiveness* win in the whole survey — it removes a recurring
footgun, not just a keystroke.

### c. `--help` structure
- `ng --help` / `ng help` → **categorized verb index** (GitHub writes ·
  task lifecycle · window/worker ops · state queries · infra), one line each.
  This is the direct fix for the "`unknown subcommand`" papercut.
- `ng <verb> --help` → per-verb usage (the `_usage_for`/`_help_check`
  machinery already exists at `ng:256`; just guarantee every verb routes
  through it).

### d. Exit codes
Standardize and document: `0` success · `1` runtime error / eligibility
rejection · `2` usage error. Today everything funnels through `die → 1`; splitting
usage (`2`) from genuine failure (`1`) lets callers script retries (`ng wrap-up`
already prints per-step ok/fail — extend that discipline).

### e. Single source of truth — the core trade-off

| | **Facade-over-scripts** (wrap; `ng skeptic` model) | **Logic-in-`ng`** (migrate) |
|---|---|---|
| Discoverability | ✓ `ng <verb>` | ✓ `ng <verb>` |
| Test isolation | ✓ `test-<x>.sh` preserved | ✗ folded into `ng` suite |
| `ng` size / conflict surface | ✓ unchanged (thin `exec`) | ✗ grows past 3829 lines |
| No-bloat (PR `#344`) | ✓ one logic home | ✗ risks duplication |
| Indirection | ✗ two callable paths exist | ✓ one path |
| Direct `$(…)`/source use | ✓ script still callable | ✗ must go through `ng` |

**Recommendation: facade-over-scripts.** The only thing migration buys is
eliminating the second callable path — and for these scripts that second path
(direct invocation, `source`, `$(…)` capture, the test suite) is a **feature**,
not debt. Reserve logic-in-`ng` for net-new ops with no standalone unit.

---

## 4. Documentation update list (if wraps land)

No edits made here — this is the exact change-set a follow-up would touch:

1. **`monitor/README.md` §"Compact GitHub helper (`ng`)"** (`README.md:1115`) —
   the verb table lists ~12/41 verbs. **Add the ~29 missing verbs** and any new
   wraps; **reorganize into the categories** from §3c. This is the single
   highest-leverage doc fix.
2. **`monitor/ng` header comment** (lines 5–~250, the `_print_help` source) —
   add usage-example lines for each new wrap so `ng --help` surfaces them; if a
   categorized index is adopted, restructure this block.
3. **`CLAUDE.md`** (nexus-root + project copies) — the "Common gotchas" and
   skill-index bare-path references (`monitor/pane-state.sh`,
   `monitor/write-probe.sh`): add the `ng <verb>` alias alongside the canonical
   path (keep the path; note the alias).
4. **`monitor/agent-prompt.md`** — references `mint-token.sh`,
   `paste-followup.sh`, `notify.sh`, `bootstrap-recover.sh`, `boot-recover.sh`
   by path; add `ng` aliases where a wrap exists.
5. **Worker floor** (`## Worker floor` in `monitor/spawn-worker.sh`, injected
   into every spawn prompt) — references `write-probe.sh`, `declare-wait.sh`,
   `declare-no-wait.sh`. Surface the `ng` alias so spawned workers discover it.
6. **Skill `SKILL.md` files** with bare-script paths:
   `nexus.window-cleanup` (`retire-preflight.sh`), `nexus.skeptic`
   (`skeptic-channel.sh` — already notes `ng skeptic`), `nexus.tmux-spawn`
   (`spawn-worker.sh`, `paste-followup.sh`), `nexus.jupyter` (`jupyter-up.sh`),
   `nexus.service-recovery` (`ng service-incident`), `nexus.worker-defaults`.
   Add `ng` aliases where wrapped; leave LEAVE-class paths as-is.

---

## 5. Recommendation summary

1. **Land PR `#345`** (`ng retire-preflight`) — correct template.
2. **Wrap the high-value four** as pass-through facades: `ng pane-state`,
   `ng write-probe`, `ng declare-wait`, `ng declare-no-wait` (+ `paste-followup`
   for consistency). Each is a 3-line `exec` over the existing script; tests and
   direct callers untouched.
3. **Fix discoverability first** — a categorized `ng --help` index + a complete
   README verb table. This addresses the *actual* root cause (no single "what
   can `ng` do" surface), which wrapping alone does not.
4. **Migrate nothing.** Facade-over-scripts is the unifying convention;
   logic-in-`ng` is reserved for net-new ops.
5. **Optional polish:** `ng mint-token`/`ng user-pat` for symmetry; a `NG_REPO`
   default to retire the `--repo` boilerplate (issue `#108`).

**Stop here for the operator's design decision — implement nothing beyond this
proposal.**
