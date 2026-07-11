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
in this flow MUST carry an explicit `--repo <your-org>/nexus-code`. A bare
`ng` write defaults to `github.repo` (the asset repo) — that default is
the exact footgun this routing rule exists to prevent. Do **not** open a
tracking issue in the current (asset) repo, even though standard nexus
practice ("every actionable thread gets its own issue") would otherwise
point you there.

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

### 2c. VI-mode insert handling (spawns + follow-ups)

Claude Code uses VI keybindings. Spawn/follow-up delivery sends `i`
first to force insert mode before pasting, else the message executes as
VI motions and is silently lost (`skills/nexus.tmux-spawn` "VI-mode
hazard"). If a release changes the default mode, the mode indicator, or
the key to enter insert, re-validate the spawn + follow-up paste paths
(`monitor/spawn-worker.sh`, the follow-up `set-buffer`/`paste-buffer`
sequence).

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
- The `skipDangerousModePermissionPrompt: true` settings key.
- Confirm the candidate still honours the same hook-event names,
  matcher syntax, the hook input/output JSON contract (the heartbeat /
  paste-received / session-pin / decision-emit / async-launch-detect
  hooks all parse it), and the settings keys. A renamed event or a
  changed matcher schema silently disables a hook — and a disabled
  heartbeat/Stop hook is exactly the wedge the watcher can't see.

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

Exit 0 = **GREEN** (renderer surfaces intact). Non-zero = **RED**.

**What a pass/fail means per surface.** A green gate proves the
renderer-classification surfaces (2a, and 2b's overlay shape) still
hold against the candidate. It does **not** cover 2c (VI-mode), 2d
(hooks/settings — the scenarios run renderer-path only, not the
heartbeat-substrate variant; see the README "What's NOT here yet"), or
2e (CLI flags) — those you validate by reading the changelog (Step 1) +
the manual checks in Step 2. So: **green gate + clean changelog review
across 2c/2d/2e = safe**. A **red** gate means a specific scenario
failed → a renderer drift → `pane-state.sh` needs a matching
`_detect_*` update (and a fresh fixture captured from the candidate)
*before* the bump is safe.

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
| **safe to bump** | gate GREEN **and** changelog shows nothing touching 2c/2d/2e | proceed to Step 5 |
| **needs manual review** | gate GREEN but changelog flags VI-mode / hook / settings / CLI changes (2c/2d/2e), **or** a minor/major version jump | do the targeted manual check for the flagged surface; if it holds, bump; if uncertain, surface on `<your-org>/nexus-code` with the specifics (never the asset repo) |
| **block** | gate RED, **or** a confirmed contract break you can't mitigate | do NOT bump. Fix the affected `_detect_*` / dialog signature / hook first (capture a fresh fixture), land that, re-gate. Surface the blocker on `<your-org>/nexus-code` (issue or `cc-compat` PR), never the asset repo. |

When a verdict needs surfacing (needs-review you can't clear, or block),
report it with evidence (which scenarios passed, which changelog entries
you cleared) on the **`<your-org>/nexus-code`** tracking issue — explicit
`--repo <your-org>/nexus-code` — never the asset repo and never the
overview (routing-only). A **safe** verdict that you apply needs no issue
at all (see the routing invariant above).

## Step 5 — APPLY the bump (only if Step 4 says so)

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
  mid-flight, records `behind_main=N` clone staleness in every apply
  record, and verifies the post-restart invariant (0 old-group
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
