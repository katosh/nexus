# cc-harness — real Claude Code binary, auth-free injectable backend

A CI-able test harness that runs the **real** project-local Claude Code
binary against an **auth-free, injectable mock "model"**, to
deterministically exercise the nexus machinery that actually breaks at
the `tmux → claude → watcher` boundary:

- **pane-state classification** (`monitor/pane-state.sh` —
  idle / busy / user-typing / autosuggest-only / blocked / over-limit /
  empty / absent),
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

> **First catch.** On its first run this harness surfaced a real
> pane-state gap: claude 2.1.147 renders the *post-turn* idle box with
> the reverse-video space cursor as the **last cell** of the `❯<NBSP>`
> row (its `\x1b[0m` reset on the next line), so `_detect_empty_input`'s
> canonical `\x1b[7m \x1b[0m` pattern missed it and a genuinely-idle
> pane mis-classified as `empty`. Masked in production by the heartbeat
> substrate (workers carry hooks that supply `idle` authoritatively),
> but the renderer fallback — stale/missing heartbeat, inherited panes —
> had regressed silently. Fixed in `pane-state.sh::_detect_empty_input`;
> regression fixture: `fixtures/idle-empty-post-turn-realmodel.ansi`.

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
| `gate.sh` | Pre-update gate: run the scenarios against a candidate cc version in a throwaway prefix; green/red exit. Runs `lint-no-mass-kill.sh` as a pre-flight. |
| `lint-no-mass-kill.sh` | Safety lint: forbids cmdline-pattern process kills (`pkill -f`/`--full`, `pgrep -f`, `killall`) in harness code — they match the shared project-local claude binary across the sandbox's one PID namespace and wipe every agent (crash postmortem 2026-05-29). Allows PID-scoped `pkill -P`. Run by `gate.sh` and the CI workflow. |
| `../watcher/test-integration/test-realmodel-*.sh` | The scenarios (`idle-busy`, `blocked-question`, `autosuggest`, `long-exchange`, **`apispoof`**). Auto-discovered by `run-tests.sh`; gated on `RUN_CC_HARNESS=1`. `apispoof` is the end-to-end stall-detection test: real claude → mock 529/404 → real StopFailure → real `turn-failure-emit.sh` marker → real watcher classifier → `interrupted` + recovery verb → real resume that completes when the mock recovers. |

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
```

`gate.sh` first runs `lint-no-mass-kill.sh` (safety pre-flight), bootstraps
`node` if it lives behind an environment module (shared
`monitor/_node-bootstrap.sh`, same logic the installer uses), then drives the
candidate binary through every `test-realmodel-*` scenario against the
auth-free mock. Exit 0 = green (safe to promote), non-zero = red. The headline
carries a `passed / failed / skipped` tally.

**A skipped scenario is RED, not green.** Under the gate (`CCH_GATE=1`) a
scenario that self-skips — tmux/node/python/claude missing — exits with the
SKIP sentinel and fails the gate: a skip means the candidate was never
exercised, so it must not count toward "safe to promote". (This closes a hole
where the gate printed GREEN with every scenario skipped for lack of node.)
Note this is gate-specific: the same scenarios still self-skip with exit 0
under the fast-loop runner `run-tests.sh`, which counts that as a clean
non-failure.

If **green**:

1. Bump the `@anthropic-ai/claude-code` pin in `package.json`.
2. `monitor/install-claude-local.sh` in the live clone. On the NFS clone
   prefer `npm install` over `npm ci` (the wrapped installer can stall;
   `npm ci` is stricter about the lock — see issue history). Commit the
   pin + lock.
3. Restart the watcher so it loads the new binary
   (`monitor/svc.sh restart watcher`). Do NOT `tmux kill-window -t watcher`:
   the watcher is headless and `main.sh` survives the pane as a PPID=1
   orphan (issue `#106`); and never hard-code the coordinator window —
   `launcher.sh` resolves it from config `monitor.target_window`.

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
  so the harness also exercises the heartbeat path (this slice is
  renderer-path only, which is what exposed the empty-box finding).
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
- **Automated self-update**: the bump→gate→promote loop is operator-invoked
  today (`gate.sh --version <npm-version>`); automating it is a future item.

## CI

`.github/workflows/cc-harness.yml` runs this harness on PRs touching the
harness surface (and via `workflow_dispatch`): it syntax-checks the scripts,
runs `lint-no-mass-kill.sh`, installs the real binary, and runs every
`test-realmodel-*` scenario against the mock — with **no `ANTHROPIC_*`
secret** (the mock is the model). The <your-org> runner-dispatch billing block
that previously prevented green runs is resolved (2026-05-29).
