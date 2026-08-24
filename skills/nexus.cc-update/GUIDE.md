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
> `monitor.cc_auto_update.enabled: true`. With both off, nothing tracks
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
| `gate` | a cc-harness scenario covered it | 2a, 2b, 2d only — nothing in the harness covers 2c or 2e. `apply.sh` cross-checks the scenario name against your gate log. |
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
| A | `"vim"` in **both** `~/.claude.json` and `~/.claude/settings.json` | 9 of 10 windows (the non-match is `services`, not an agent pane) | VI is REACHED. `#724`'s probe now exists (`test-realmodel-vimode.sh`) and the harness seeds `"vim"`, so the mode the gate boots is the one production runs — but `apply.sh` does not yet map `2c-vi` to a gate scenario, so `gate` is refused and the honest label remains `source-inspection` |
| B | absent from all 5 present settings files | 0 of 4 | `reachability` — both re-checks return zero |

So: **run the two re-check commands in §2c and label from what they
return.** `reachability` is payable only where both come back zero;
where they do not, the honest label is `source-inspection` — see the note
on `2c-vi` and `gate` payability in §2c. Do not inherit either row.

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

This work touches `monitor/watcher/*`, so do it in a **separate
clone/worktree**, never on the live main clone (a `git checkout` on the
running watcher's clone silently breaks `snapshot_github` — see the
workspace CLAUDE.md "Watcher-touching work needs a separate clone").

## Step 1 — read the release notes / changelog

Find what actually changed between `installed` and `candidate`:

```bash
# the published changelog (the package ships one):
GH_TOKEN=$(./monitor/mint-token.sh) gh api \
  repos/anthropics/claude-code/contents/CHANGELOG.md \
  --jq '.content' | base64 -d | sed -n '1,120p'
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
  3. Pass `--changelog-dispositioned <release>=<N>` **for every release
     in the delta** — a two-release jump means both changelogs, not just
     the candidate's. `apply.sh` derives the release set from **the copy
     it fetches itself** (upstream skips patch numbers routinely, so an
     arithmetic range would be wrong), **counts M from that copy**, and
     refuses when `N != M` or when any entry is missing from the ledger.

  You get `dispositioned N of M entries` in `decisions.tsv` out of it.

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
- **Watch for entries that land on the harness substrate itself**, which
  the 2a-2e taxonomy has no row for. Example (2.1.222): *"stream idle
  timeout firing on custom `ANTHROPIC_BASE_URL` gateways despite server
  keep-alive pings"* — the cc-harness mock **is** a custom
  `ANTHROPIC_BASE_URL` (`monitor/cc-harness/_lib.sh`), so that entry
  lands on the thing you are measuring with. Note such entries explicitly
  under a **2f — harness substrate** heading in your table.

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

- **`_detect_autosuggest`** — `\x1b[7m.\x1b[0;2m` (reverse-video first
  char + faint/dim tail on the input row). A theme/renderer change to
  the dim code (`0;2m` → `2m`) breaks this.
- **`_detect_user_typing`** — `\x1b[38;5;231m` (bright-white user text).
- **`_detect_busy`** — the active token-counter `[↓↑] N tokens` on the
  spinner row in the 10 lines above the input. The idle banner uses a
  past-tense form with no counter; a wording/format change to the
  counter mis-reads busy↔idle.
- **`_detect_empty_input`** — reverse-video space cursor `\x1b[7m \x1b[0m`,
  PLUS the 2.1.147 post-turn trailing-cursor variant (the harness's
  first catch; fixture `monitor/cc-harness/fixtures/idle-empty-post-turn-realmodel.ansi`).
- **`_detect_blocked`** / over-limit / empty / absent — the dialog and
  dead-pane frames.
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

**What the gate covers here, precisely.** `test-realmodel-blocked-question.sh`
drives a live AskUserQuestion overlay and asserts `_detect_blocked`, so
it covers the Case D **shape gate**. It does **NOT** cover the
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
committed fixtures** carry OSC bytes — the only 2 that do at HEAD are the
differential pair this change adds, 2 of 30 total — and 0 of 5 live panes
carried them, measured at `dc4c76f`). **That proof is version-scoped, not
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
> → VI mode is reached on your host and the honest label is
> `2c-vi=source-inspection` (NOT `gate`, even though `#724`'s probe has
> landed — see the end of this section).

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
   Concretely, **10 of the 30 committed pane fixtures in
   `monitor/watcher/fixtures/` DO render `-- INSERT --`** — including real
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

**But `2c-vi=gate` is still REFUSED**, because `apply.sh`'s
`_surface_gate_scenarios` maps only `2a`, `2b` and `2d` to scenarios and
returns empty for `2c-vi`. That is fail-CLOSED — you are pushed to a weaker
label, never a stronger one — so it blocks nothing today. Until the map
gains the entry, the honest label on a host where the re-checks return
non-zero is `2c-vi=source-inspection`; do not claim `gate` and do not clear
`2c` by unreachability there.

### 2d. Hooks + settings schema

The nexus rides Claude Code's hook + settings contract. Files:
`monitor/orchestrator-settings.json`, `monitor/worker-settings.json`,
hook scripts in `monitor/hooks/`.

- Hook **events** in use: orchestrator → `PreToolUse`
  (`AskUserQuestion` matcher → `block-askuserquestion.sh`, the Case D
  Layer A), `UserPromptSubmit` (`orchestrator-session-pin.sh` +
  paste-received stamp), `Stop` (heartbeat stamp). Worker →
  `Notification`, `PermissionRequest`, `PostToolUse`, `PreToolUse`,
  `Stop`, `StopFailure`, `UserPromptSubmit`.
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
`monitor/hooks/gh-write-guard.sh:41-45` and `bash-footgun-guard.sh`
parse. It carries its own negative controls (a hooks-stripped arm that
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
- **`--session-id`** — if/once adopted by the nexus.
- **`-p` vs positional prompt** — the harness uses both (`claude -p`
  headless; the launcher passes a positional prompt).

A flag rename/removal/semantics-change here breaks spawning or respawn
outright. Grep the candidate's `--help` and diff against these.

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

1. Runs `monitor/cc-harness/lint-no-mass-kill.sh` as a **safety
   pre-flight** (see the hard rule below).
2. Drives the candidate through every `test-realmodel-*` scenario
   against the mock backend, asserting `pane-state.sh` still classifies
   the live panes:
   - `test-realmodel-idle-busy.sh` → exercises **2a** `_detect_busy` /
     `_detect_empty_input` (drip-streamed busy window vs post-turn idle).
   - `test-realmodel-blocked-question.sh` → exercises the
     AskUserQuestion overlay → `_detect_blocked` (the **2b** Case D
     shape).
   - `test-realmodel-autosuggest.sh` → asserts the production classifier
     on the real autosuggest renderer bytes (**2a** `_detect_autosuggest`),
     anchored to a live pid + the liveness-gated `absent` degrade.
   - `test-realmodel-overlimit.sh` → the over-limit `StopFailure` payload
     shape + reset-time detection (**2d**, over-limit path only).
   - `test-realmodel-pretooluse-hook.sh` → a real Bash tool call through a
     `--settings`-wired **PreToolUse** hook, asserting the payload fields
     the nexus guards parse (**2d**, PreToolUse contract).

Exit 0 = **GREEN** (covered surfaces intact). Non-zero = **RED**.

**What a pass/fail means per surface** — this is the map you translate
into evidence classes:

| Surface | Gate coverage | Honest class on a green gate |
|---|---|---|
| **2a** pane-state markers | full (`idle-busy`, `autosuggest`) | `gate` |
| **2b** unstick dialogs | overlay **shape** only — not the Case D footer, not Case A | `gate` for the shape; footer/Case A need a changelog read |
| **2c** VI-mode | none | `reachability` (re-check it — see 2c) |
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

### Hard safety rule (2026-05-29 postmortem) — do not weaken

The harness must **NEVER** run a cmdline-pattern process kill
(`pkill -f` / `--full`, `pgrep -f`, `killall`). In the sandbox's single
PID namespace such a pattern matches the shared project-local `claude`
binary across **every** agent and SIGTERMs them all at once (the
2026-05-29 mass-kill). `gate.sh` runs `lint-no-mass-kill.sh` as a
pre-flight that fails red on any such pattern; PID-scoped `pkill -P` is
the only allowed form. If you touch harness code during an evaluation,
**do not** disable, bypass, or loosen this lint.

## Step 4 — DECISION

Combine the gate result with the changelog review:

| Verdict | When | Action |
|---|---|---|
| **safe to bump** | gate GREEN **and** every surface key (`2a 2b 2c-paste 2c-vi 2d 2e`) carries an honest evidence class (no unsubstantiated `empirical`) **and** every changelog entry of every release in the delta is dispositioned | proceed to Step 5 |
| **needs manual review** | gate GREEN but changelog flags VI-mode / hook / settings / CLI changes (2c/2d/2e), **or** a minor/major version jump | do the targeted manual check for the flagged surface; if it holds, bump; if uncertain, surface on `<your-org>/nexus-code` with the specifics (never the asset repo) |
| **block** | gate RED, **or** a confirmed contract break you can't mitigate | do NOT bump. Fix the affected `_detect_*` / dialog signature / hook first (capture a fresh fixture), land that, re-gate. Surface the blocker on `<your-org>/nexus-code` (issue or `cc-compat` PR), never the asset repo. |

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
>     --surface-evidence 2c-vi=source-inspection \
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
> log; payable for 2a/2b/2d only), `empirical` (**requires** a
> `--negative-control` for that surface), `reachability`,
> `source-inspection`. Surface keys are `2a 2b 2c-paste 2c-vi 2d 2e` —
> the aggregate `2c` is refused, because its two halves have different
> evidence (see the evidence-class rule above).
>
> The changelog flags are the **completeness** rule (Step 1): one
> `--changelog-dispositioned` per release in the delta, `N` checked
> against the entry count `apply.sh` derives from the changelog file, and
> every entry required to appear verbatim in the ledger.
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
working tree stays clean and `git pull --ff-only origin dev` never
conflicts on a phantom local bump. See `monitor/_cc-version.sh` and
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
# 3. NO git commit, NO push, NO package.json edit. The version lives in
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
- **Tier:** `<your-org>/nexus-code` is INTERNAL — bot identity for GitHub
  writes, no per-action approval; PR `--base dev`.
- **Idempotency / re-nag:** the watcher surfaces a given candidate
  exactly once (guarded by `monitor/.state/cc-update-surfaced`). If you
  evaluate-and-defer, the signal persists in `cc-update-available` for
  `cat`; a *newer* candidate re-arms the emit.
- **Autonomous daily routine (opt-in):** with
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
  restart path or while more than
  `monitor.cc_auto_update.max_live_windows` agent windows are
  mid-flight, records clone staleness in every apply record as
  `behind_integration=<n|unknown> integration_branch=<b>
  drift=<up-to-date|behind|unknown>` — measured against the branch
  merged fixes land on, config `monitor.integration_branch` (`#763`;
  the deprecated `monitor.clone_drift.branch` is still read until
  **2026-11-07**), NOT
  `main` (`#754`); the pre-`#754` field was `behind_main=N` and
  under-reported, so old rows are not comparable — and verifies the
  post-restart invariant (0 old-group
  survivors, exactly one watcher group; violation = exit 31, no
  Step 5b). A deferred safe-to-bump is a complete result.
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
