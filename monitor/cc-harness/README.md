# cc-harness — real Claude Code binary, auth-free injectable backend

A CI-able test harness that runs the **real** project-local Claude Code
binary against an **auth-free, injectable mock "model"**, to
deterministically exercise the nexus machinery that actually breaks at
the `tmux → claude → watcher` boundary:

- **pane-state classification** (`monitor/pane-state.sh` — idle, busy,
  user-typing, autosuggest-only, blocked, over-limit, empty, absent and
  the rest; **`monitor/pane-state.sh --states` is the vocabulary**, this
  is a reading aid and is deliberately not a complete enumeration — the
  gate derives its own denominator from `--states`, never from prose),
- **prompt injection** (the watcher's `paste_to_target` send-keys path),
- **sticky-state / recovery** (backend stalls → busy-forever → unstick /
  respawn).

It runs with **NO real Anthropic auth** and **NO network egress**. The
point is the real binary's boot / hooks / tool-loop / pane rendering,
driven by canned or injected backend responses.

## Why this is distinct from `test-integration/`

`monitor/watcher/test-integration/` drives a fully *fake* `claude` shim
(`stub-claude.sh`). That's perfect for lifecycle wiring but cannot catch
**renderer drift**: when a new Claude Code release changes the bytes the
TUI paints (chevron, spinner token-counter, empty-box cursor,
AskUserQuestion chip-bar, dead-pane frame), only the *real* binary
reproduces it. This harness is that surface. The two are complementary:
the stub suite owns lifecycle; cc-harness owns "does the real TUI still
render what pane-state expects."

> **Second catch (<your-org>/nexus-code#568).** Asked to confirm that making
> `"tui": "fullscreen"` the shipped default left the observability surfaces
> unchanged, this harness found that it did not — and the default was
> consequently **never shipped**: `"tui": "fullscreen"` was reverted out of
> `worker-settings.json` / `orchestrator-settings.json` in b37bb68
> (`<your-org>/nexus-code#570`, see `#573`), so fullscreen is an OPT-IN mode and
> the binary's own default is what workers run. Under fullscreen
> (alternate-screen) rendering the input box is pinned to the bottom of a
> full-height screen and the gap above it is padded with blank rows. Every
> bottom-anchored scan in `pane-state.sh` used `tail -n 15`, which conflates
> "the last 15 rows of CONTENT" with "the last 15 rows of the GRID" — the same
> thing only in the inline renderer. Measured at the moment the notice was
> painted: **40 rows captured, 10 non-blank, notice at raw row 32 from the
> bottom but non-blank row 6.** So the scan saw nothing but padding and
> `_detect_over_limit` returned "no notice" for a pane visibly painting one —
> the renderer fallback silently degrading a rate-limited worker to `idle`.
> Masked in production by the heartbeat stamp, exposed exactly where the
> fallback matters (stale/missing heartbeat, inherited panes). Fixed with
> `pane-state.sh::_bottom_rows`, which strips blanks before bounding, keeping
> the anti-scrollback anchoring the raw form was chosen for. Regression
> fixture: `monitor/watcher/fixtures/over-limit-fullscreen-padded-synthetic.ansi`.
>
> The general point: the stub suite could not have caught this at all —
> `stub-claude.sh` has no TUI handling, so it would have gone green under both
> modes and that green would have meant nothing.

> **First catch.** On its first run this harness surfaced a real
> pane-state gap: claude 2.1.147 renders the *post-turn* idle box with
> the reverse-video space cursor as the **last cell** of the `❯<NBSP>`
> row (its `\x1b[0m` reset on the next line), so `_detect_empty_input`'s
> canonical `\x1b[7m \x1b[0m` pattern missed it and a genuinely-idle
> pane mis-classified as `empty`. Masked in production by the heartbeat
> substrate (workers carry hooks that supply `idle` authoritatively),
> but the renderer fallback — stale/missing heartbeat, inherited panes —
> had regressed silently. Fixed in `pane-state.sh::_detect_empty_input`;
> regression fixture: `monitor/watcher/fixtures/idle-empty-post-turn-realmodel.ansi`.

## Feasibility — proven (the load-bearing unknown)

The real `claude` binary completes a turn against a local mock endpoint
with NO valid Anthropic credentials. Confirmed for both headless
(`claude -p` → exit 0, canned text) and the interactive TUI (boots, and
`pane-state.sh` classifies the live pane). The invariants that make it
work:

- **`ANTHROPIC_BASE_URL=http://127.0.0.1:<port>`** points the SDK at the
  mock. claude does NOT validate the key or phone home before hitting
  base-url.
- **`ANTHROPIC_AUTH_TOKEN=<anything>`** (a bearer token) rather than
  `ANTHROPIC_API_KEY`. The mock accepts anything; using the auth-token
  avoids the interactive **custom-API-key approval dialog** that
  `ANTHROPIC_API_KEY` triggers in the TUI.
- **Pre-seeded `$CLAUDE_CONFIG_DIR/.claude.json`** to skip first-run
  gates: `theme` + `hasCompletedOnboarding` (theme picker), and
  per-project `projects.<cwd>.hasTrustDialogAccepted` (folder-trust
  dialog). `--dangerously-skip-permissions` covers per-tool prompts.
- **SSE framed with `Connection: close`.** Under HTTP/1.1 the streaming
  body has no `Content-Length`; the SDK waits for EOF, so the mock must
  close the connection at `message_stop` or the client hangs.
- Telemetry/auto-update disabled (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`,
  `DISABLE_AUTOUPDATER`, `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`,
  `DISABLE_BUG_COMMAND`) — belt-and-suspenders against egress.

## Components

| File | Role |
|---|---|
| `mock-backend.py` | Auth-free mock Anthropic Messages endpoint. stdlib-only (python 3.6+). Binds 127.0.0.1 only. Content-negotiates SSE vs JSON. Logs every request. |
| `_lib.sh` | Harness library: boot the real claude in an **isolated tmux socket** against the mock, seed config, inject prompts, classify panes via the production `pane-state.sh`. |
| `demo.sh` | Human-facing live demo (`--stop` to tear down). A real round-trip + an AskUserQuestion menu you attach to and pick from. |
| `gate.sh` | Pre-update gate: run the scenarios against a candidate cc version in a throwaway prefix; green/red exit. Runs BOTH pre-flight lints below (`lint-no-mass-kill.sh` and `lint-no-tmux-server-kill.sh`), each `--selftest` first, at `gate.sh:211-234`. |
| `lint-no-mass-kill.sh` | Safety lint: forbids cmdline-pattern process kills (`pkill -f`/`--full`, `pgrep -f`, `killall`) in harness code — they match the shared project-local claude binary across the sandbox's one PID namespace and wipe every agent (crash postmortem 2026-05-29). Allows PID-scoped `pkill -P`. Run by `gate.sh` and the CI workflow. |
| `lint-no-tmux-server-kill.sh` | Safety lint on the tmux-**socket** axis (blast radius strictly worse than the above: killing the tmux server ends the session `bwrap` holds open, tearing down the whole sandbox — <your-org>/nexus-code#644). Requires `kill-server` to carry an explicit `-L`/`-S`, `kill-session` to carry `-t`, and flags a `TMUX_TMPDIR` isolation in any file that never does `unset TMUX` — socket precedence is `-L`/`-S` > `$TMUX` > `TMUX_TMPDIR` > default, and `$TMUX` is always set because every agent runs in a pane. Quoted occurrences are treated as data, not calls. Wrapper-routed calls may carry a `# tmux-scoped: <reason>` pragma; pragmas are **counted** and the count is pinned by `--selftest`, so an exemption cannot be added silently. `--selftest` is the negative control (asserts the lint fails on planted violations, including the #644 line verbatim, for the expected rule id); `--manifest` lists every destructive call site. Run by `gate.sh` and the CI workflow. |
| `../watcher/test-integration/test-realmodel-*.sh` | The scenarios (ten on disk at `a3177ef6`: `idle-busy`, `blocked-question`, `autosuggest`, `long-exchange`, **`apispoof`**, **`overlimit`**, **`pretooluse-hook`**, **`trust-dialog`**, **`trust-sandboxed-env`**, **`vimode`** — of which `long-exchange` and `apispoof` are the two `exempt` rows in `gate-coverage.tsv`; the other eight are `gated`). Auto-discovered by `run-tests.sh`; gated on `RUN_CC_HARNESS=1`. `apispoof` is the end-to-end stall-detection test: real claude → mock 529/404 → real StopFailure → real `turn-failure-emit.sh` marker → real watcher classifier → `interrupted` + recovery verb → real resume that completes when the mock recovers. `overlimit` is the usage-limit chain (2026-07-14 incident): real claude → mock 429 `rate_limit_error` (retries exhausted via `CLAUDE_CODE_MAX_RETRIES=1`) → real StopFailure `error="rate_limit"` → real `over-limit-emit.sh` stamp with the reset time parsed from the notice → production `pane-state.sh` `over-limit` → watcher emit-gate hold → real Stop-hook clear → wake flush. `pretooluse-hook` is the GUIDE-2d hook-contract test: real claude booted with a `--settings`-wired **PreToolUse** hook (via the `CCH_SETTINGS` override) → mock `tool_use` turn → real Bash tool call → assert `hook_event_name=PreToolUse`, `tool_name=Bash`, and an intact `.tool_input.command`, the exact fields `monitor/hooks/gh-write-guard.sh` and `bash-footgun-guard.sh` parse. It ships two negative controls (a hooks-stripped arm that must NOT fire, and a doctored-payload arm proving the field extractor is not vacuous) so a green result is not decorative. `trust-dialog` is the structural select-dialog arm (<your-org>/nexus-code#896): the workspace-trust dialog used to classify `state=empty` — "don't know yet" — so nothing unstuck a worker that would never proceed, and 2.1.232 made that every nested-repo spawn. It un-seeds `hasTrustDialogAccepted` (the ONE key `_lib.sh` seeds to skip the gate), asserts the production classifier reports `blocked` + `overlay=workspace-trust`, carries a trusted control arm that must reach idle, and re-derives `monitor/watcher/fixtures/blocked-workspace-trust-realmodel.ansi` from the live binary so the committed capture cannot rot into fiction. It exercises the pinned version, not just a staged candidate: 2.1.232 changed WHEN the dialog appears, not WHAT it renders. The error control-knob also accepts a `headers` map; note CC's subscription unified-rate-limit headers are OAuth-gated and inert under the harness's bearer auth (see the scenario header). |

## Injectable control — "a pipe we can inject text into"

The mock reads a **control file** fresh on every `/v1/messages` request
(`$MOCK_CONTROL`, default `<MOCK_DIR>/control.json`). A scenario mutates
it between turns to script each response — deterministic and CI-robust
(a FIFO is a documented follow-up; a control file avoids blocking-pipe
fragility). Schema (all keys optional):

```json
{
  "mode": "text | hang | tool_use | error",
  "text": "<assistant text>",
  "delay_ms": 0,          // pause before first SSE byte
  "drip_ms": 0,           // pause between word chunks -> a visible busy
                          //   window (pane-state sees the ↑N-tokens spinner)
  "tool": {"name": "Bash", "input": {"command": "ls"}},   // tool_use mode
  "status": 500,           // error mode: HTTP status
  "error_type": "api_error",// error mode: Anthropic error .type — drives the
                            //   StopFailure `error` token CC surfaces
                            //   (overloaded_error -> server_error / transient;
                            //    not_found_error -> model_not_found / config;
                            //    invalid_request_error -> unknown / conversation)
  "error_text": "..."       // error mode: message body
}
```

- `text` — stream canned text (drip to induce **busy**).
- `hang` — open the stream, emit a few deltas, then never finish →
  claude stuck **busy** (substrate for sticky-state / unstick scenarios).
- `tool_use` — emit a tool_use block (e.g. `AskUserQuestion` → the
  selection overlay that classifies as **blocked**).
- `error` — return an HTTP error status (`status` + `error_type` + `error_text`).
  The real binary maps the (status, error.type) pair to the structured `error`
  token it surfaces in the `StopFailure` hook — the signal the stall-detection
  classifier keys off. Used by `test-realmodel-apispoof.sh` to spoof a real
  529 (transient → paste) and a real 404 (config → respawn).

## Running

```bash
# the scenarios (self-skip unless enabled):
RUN_CC_HARNESS=1 monitor/watcher/run-tests.sh --filter realmodel
RUN_CC_HARNESS=1 bash monitor/watcher/test-integration/test-realmodel-idle-busy.sh

# live demo you can attach to and click through:
monitor/cc-harness/demo.sh
tmux -L ccdemo attach -t cc-demo      # ↑/↓ + Enter on the menu
monitor/cc-harness/demo.sh --stop
```

Requirements: `node` (the real binary is a node program), `python3`,
`tmux`, `jq`, and a resolvable claude binary (the project-local install,
or `CLAUDE_BIN`). Missing any → the scenarios self-skip cleanly.

**Isolation.** Every run uses its own tmux socket (`-L cch-…` / `-L
ccdemo`), never the default session the live watcher scans. Test runs
cannot collide with the live watcher's `monitor/.state/`.

## Pre-update gate: bump → gate → promote

Claude Code publishes ~daily. This gate is the **canonical manual procedure
to run before any Claude Code self-update.** (Automating the bump→gate→promote
loop is a planned future item; today it is operator-invoked.) Before promoting
a version pin:

```bash
monitor/cc-harness/gate.sh --version <npm-version>   # green/red, candidate in a throwaway prefix
monitor/cc-harness/gate.sh --version <npm-version> --keep-prefix
    # …and KEEP the staged install for the non-gate probes: prints
    # `=== kept-prefix: claude_bin=<p> prefix=<d> ===`; export CLAUDE_BIN=<p>,
    # remove <d> yourself when done (<your-org>/nexus-code#1002)
```

The candidate install is `cch_stage_candidate <version> [<prefix>]` in
`_lib.sh` — `npm install --prefix <dir> --no-save …`, the one
root-resolution-immune form, which also refuses a stage whose binary is
missing (rc 3) or is not the requested version (rc 4). An ad-hoc probe
that needs a candidate in hand uses the same helper. **Never
`cd <dir> && npm install …`**: with no `package.json` in `<dir>` npm walks up
to the nexus root's and installs into the LIVE `node_modules` at rc 0
(`#1002`).

`gate.sh` first runs BOTH safety pre-flights — `lint-no-mass-kill.sh` and
`lint-no-tmux-server-kill.sh`, each `--selftest` (the negative control) then
for real — then bootstraps
`node` if it lives behind an environment module (shared
`monitor/_node-bootstrap.sh`, same logic the installer uses), then drives the
candidate binary through the `test-realmodel-*` scenarios named in its
`gate_prod_scenarios` array against the auth-free mock. Exit 0 = green (safe to
promote), non-zero = red. The headline carries a `passed / failed / skipped`
tally.

Note the wording above used to read *"every `test-realmodel-*` scenario"*, and
that was false: at `5bd6d400` the array named seven of the nine such files on
disk. That is precisely the omission `gate-coverage.tsv` now ratchets.

**A vacuous population is a REFUSAL (exit 2), never a clearance**
(`<your-org>/nexus-code#1268`). With zero scenarios the gate used to print
`0 passed / 0 failed / 0 skipped (of 0)` followed by `GATE GREEN (0/0 passed) —
candidate is safe to promote`, exit 0 — the same green-via-nothing-ran failure
the fail-on-skip rule below closes, left open for `empty`. The rule lives in
`gate-coverage.sh:gate_refuse_if_vacuous` and is applied at every population
the gate computes (executed scenarios, the pane-state vocabulary, the delivery
vocabulary, the on-disk scenario set), because one guarded site and three
unguarded ones is the same defect waiting to be rediscovered. A count that is
not a NUMBER is refused too, and is reported as `NOT-ESTABLISHED` rather than
as `0`.

**A GREEN carries its coverage boundary** (`<your-org>/nexus-code#1261`).
`GATE GREEN (7/7)` is a tally over a declared list and it drives an automatic
bump of the binary every agent on the board runs, so the ratio has to say what
its denominator is. `gate-coverage.sh` prints, above the verdict:

* `gate-coverage: pane-state N/M covered` — M derived from
  `monitor/pane-state.sh --states`, never hand-enumerated, with the uncovered
  states NAMED. Measured at `5bd6d400`: **7 of 12**, uncovered `empty`,
  `idle-orphan-async`, `unknown`, `working-background`, `working-self-paced`.
* `gate-coverage: delivery N/M covered` — M derived by asking each
  `monitor/harness/*.sh transports`, the same source `monitor/send.sh` uses.
  Measured at `5bd6d400`: **0 of 2**; neither `tmux-paste` (the
  `paste-followup.sh` production delivery path) nor `cc-sendmessage` is driven
  by any gated scenario.
* `gate-coverage: scenarios gated=… exempt=… on-disk=…` — with the exempt
  files named, so a scenario that exists and is not gated is a NAMED GAP rather
  than an absence.

Per-scenario coverage is DECLARED in `gate-coverage.tsv`, not derived from the
scenario text: a grep over-claims on a state named in a comment and
under-claims on one reached through a variable, and over-claiming is the
direction that matters in a coverage report. The derivation is used as a
FALSIFIER instead — a declared member whose token appears nowhere in the
scenario file is refused. That check is deliberately PERMISSIVE and is not
verification. The gate REFUSES when: a `test-realmodel-*.sh` on disk is neither
`gated` nor `exempt`; an `exempt` row carries no reason; a gated scenario has
no row; or a declared member is outside the derived vocabulary.

An uncovered state or transport is REPORTED, not RED. It is a fact about the
suite rather than a defect in the candidate, and a permanently red gate is one
nobody reads. What changed is that neither an operator nor
`cc-auto-update-apply.sh` can now read `7/7` as "everything".

Guarded by `monitor/watcher/test-cc-harness-gate-population.sh`.

**A skipped scenario is RED, not green.** Under the gate (`CCH_GATE=1`) a
scenario that self-skips — tmux/node/python/claude missing — exits with the
SKIP sentinel and fails the gate: a skip means the candidate was never
exercised, so it must not count toward "safe to promote". (This closes a hole
where the gate printed GREEN with every scenario skipped for lack of node.)
Note this is gate-specific: the same scenarios still self-skip with exit 0
under the fast-loop runner `run-tests.sh`, which counts that as a clean
non-failure.

If **green**:

1. Write the **operator-local pin**, not `package.json`
   (`<your-org>/nexus-code#226`): `printf '%s\n' "<candidate>" >
   monitor/.state/cc-version-local` (gitignored), or source
   `monitor/_cc-version.sh` and call `cc_version_write_local_pin`, which
   writes atomically. The `package.json` value is a
   **maintainer-managed vetted FLOOR** for initial setup only; advancing
   it is a separate, deliberate maintainer PR. A gated bump never
   touches it, so there is **no commit and no push** and the working
   tree stays clean. `monitor/_cc-version.sh` is the single resolver:
   `effective = local-pin else floor`.
2. `monitor/install-claude-local.sh` in the live clone. It resolves the
   EFFECTIVE version and, with a local pin present, installs it
   explicitly via `npm install --no-save @anthropic-ai/claude-code@<ver>`
   so the shared floor stays put. It PREFERS `npm install` over
   `npm ci` by design — `npm ci` wipes `node_modules` first, which is the
   no-binary risk on NFS; it is opt-in via `CLAUDE_INSTALL_USE_CI=1` and
   is bypassed outright when a local pin is in force. It refuses to exit
   0 unless the binary runs and reports the effective version.
3. Restart the watcher so it loads the new binary
   (`monitor/svc.sh restart watcher`). Do NOT `tmux kill-window -t watcher`:
   the watcher is headless and `main.sh` survives the pane as a PPID=1
   orphan (issue `#106`); and never hard-code the coordinator window —
   `launcher.sh` resolves it from config `monitor.target_window`.
4. Restart the **orchestrator** onto the new binary — GUIDE Step 5b.
   Steps 1–3 change only what starts NEXT; the orchestrator is itself a
   running `claude` process and keeps executing the old binary until it
   is replaced. **DONE is every agent window running the new binary, not
   "the pin is written."** Do not improvise the kill: the sequence
   (session-pin pre-flight → spawn the restart watchdog → wait for its
   armed marker → kill the coordinator window) is what
   `monitor/cc-auto-update-apply.sh` performs, and Step 5b of
   `skills/nexus.cc-update/GUIDE.md` is the procedure.

If **red**: do not promote; inspect which scenario failed — a renderer
regression means `pane-state.sh` needs a matching detector update (and a
new fixture captured from the candidate) before the bump is safe.

## What's NOT here yet (follow-ups)

- **Sticky-state → unstick / respawn** end-to-end: the `hang` mode is the
  substrate (claude stuck busy on a never-finishing stream); wiring a
  full `main.sh` poll loop + `_unstick.sh` assertion mirrors the
  heavier `test-integration` Pass-B scenarios.
- **3-miss paste→respawn** against the real binary.
- **Heartbeat-substrate variant**: boot with `worker-settings.json` hooks
  so the harness also exercises the heartbeat path. PARTIALLY DONE:
  `cch_boot_worker` now honours a `CCH_SETTINGS` env override (plus
  `CCH_EXTRA_ENV`), and `test-realmodel-pretooluse-hook.sh` uses it to
  pin the **PreToolUse** payload contract. Still hook-free by default,
  and still uncovered: `PostToolUse`, `Notification`,
  `PermissionRequest`, `UserPromptSubmit`, and the `Stop` heartbeat stamp
  itself (`test-realmodel-overlimit.sh` covers `Stop`/`StopFailure` only
  on the over-limit path).
- **FIFO injection** mode for live byte-streaming, in addition to the
  control file.
- **Live autosuggest emission.** `test-realmodel-autosuggest.sh` asserts the
  production classifier on the real autosuggest renderer bytes anchored to a
  live real-claude pid (and the liveness-gated `absent` degrade). It does NOT
  drive the binary to *emit* the suggestion: claude 2.1.147's input-box
  autosuggest is a server-gated background call (`[SUGGESTION MODE: …]`) that
  is not elicitable against a custom backend — confirmed empirically
  2026-05-29 (the mock's session-title structured call fires, the suggestion
  call never does). The mock already serves the suggestion path
  (`_is_suggestion_request`); if a future cc release emits it against the
  mock, upgrade the scenario to a pure-live capture assertion.
- ~~**Automated self-update**: the bump→gate→promote loop is operator-invoked
  today; automating it is a future item.~~ **DONE — do not read this as an
  open item.** The autonomous daily routine shipped: `cc_auto_update` is a
  registered watcher task (`monitor/watcher/main.sh:4168`,
  `monitor/watcher/_cc_auto_update.sh`) that fires once a day at
  `monitor.cc_auto_update.fire_time` (default `04:00`, anacron-style
  catch-up), spawns an evaluator agent from
  `monitor/cc-auto-update-prompt.md`, and applies through
  `monitor/cc-auto-update-apply.sh` behind a deployment gate. Its default is
  split — **code default off, shipped template on** (<your-org>/nexus-code#1476):
  `monitor.cc_auto_update.enabled` falls back to `false` in
  `monitor/watcher/_config.sh` when an existing `nexus.yml` lacks the key,
  while `config/nexus.example.yml` ships `enabled: true`, so a tree with no
  `nexus.yml` (fresh clone, CI, a copied template) runs it ON. An operator
  whose `nexus.yml` never gained the key still drives
  `gate.sh --version <npm-version>` by hand. Off in that case is not the
  same as not built.

## CI

`.github/workflows/cc-harness.yml` runs this harness on PRs touching the
harness surface (and via `workflow_dispatch`): it syntax-checks the scripts,
runs both pre-flight lints (`lint-no-mass-kill.sh` and
`lint-no-tmux-server-kill.sh`, each with `--selftest` first), installs the real
binary, and runs every `test-realmodel-*` scenario against the mock — with
**no `ANTHROPIC_*` secret** (the mock is the model). The <your-org>
runner-dispatch billing block that previously prevented green runs is resolved
(2026-05-29).

**"Every" is literal here, and it is where CI is WIDER than `gate.sh`.** The
workflow `find`s the scenario files (`.github/workflows/cc-harness.yml:373-374`,
a `mapfile` over `find … -name 'test-realmodel-*.sh'`) instead of reading
`gate_prod_scenarios`, so the two rows `gate-coverage.tsv` marks `exempt`
(`apispoof`, `long-exchange`) DO run in CI and do NOT run in the gate. Do not
read a green CI as the gate's coverage, or the gate's boundary as CI's.
