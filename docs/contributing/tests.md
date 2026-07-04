# Tests

The bulk of the test suite lives under
`monitor/watcher/test-*.sh`, with two tests one level up in
`monitor/` (`test-interactive-sessions.sh` and
`test-retire-preflight.sh`). Each file is a self-contained bash
script with a hand-rolled harness — no shared fixtures, no test
framework. The convention came out of the watcher work and has
held: every test you add should print `ALL TESTS PASSED` on
success and exit 0.

## Running the suite

From a clone (worktree or fresh, doesn't matter for tests since
they all use temp dirs):

```bash
bash monitor/watcher/run-tests.sh
```

The runner loops over the discovered `test-*.sh` set (`for t in
test-*.sh`) and runs each file as its own bash process, so a
failure in one doesn't poison the next. Each script writes a
banner with its name before running its assertions. (Don't reach
for `bash monitor/watcher/test-*.sh` — the glob hands `bash`
only the first file and passes the rest as positional args, so
the suite never runs.)

To run a single file:

```bash
bash monitor/watcher/test-ng-wrap-up.sh
```

Several scripts are also `chmod +x` and can be invoked directly
(`./monitor/watcher/test-ng-wrap-up.sh`); the `bash` form works
for either.

## What each file covers

The scripts split into three groups: `ng` verb unit tests,
watcher-helper unit tests, and integration tests that bring up
real tmux. Every file's leading comment block names its scope —
the table below summarises but the source is canonical.

### `ng` CLI verbs

| File | Verb under test | Style |
|---|---|---|
| [`test-ng-wrap-up.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-ng-wrap-up.sh) | `ng wrap-up` (4-step contract: upload → comment → rocket → log) | mock-`gh`, mock-`upload-asset.sh` |
| [`test-ng-reply-repo.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-ng-reply-repo.sh) | `ng reply --repo` override + cwd-derived default | mock-`gh` |
| [`test-ng-report-init.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-ng-report-init.sh) | `ng report-init` skeleton generation + frontmatter capture | flag-driven |
| [`test-ng-report-check.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-ng-report-check.sh) | `ng report-check` schema validator (frontmatter, sections, min-chars, placeholders) | synthetic-report fixtures |
| [`test-ng-state-dir.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-ng-state-dir.sh) | `STATE_DIR` resolver precedence (`NEXUS_STATE_DIR` → `NEXUS_ROOT` → config → script-relative) | drives `ng log-action` |
| [`test-ng-fetch-asset.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-ng-fetch-asset.sh) | `ng fetch-asset` argument parsing, exit codes, extension derivation | mock-`curl`/`gh` |

### Watcher helpers

| File | Helper under test | Style |
|---|---|---|
| [`test-lib.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-lib.sh) | `_target_window_present`, `_classify_diff` (from `_lib.sh`) | mock-`tmux` |
| [`test-snapshot-github.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-snapshot-github.sh) | `snapshot_github` happy path (`_github.sh`) | mock-`gh` |
| [`test-snapshot-github-failure.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-snapshot-github-failure.sh) | GraphQL rate-limit detect-and-react: sentinel emit, per-surface backoff, expiry, unknown-error logging | mock-`gh` + shadowed `date` |
| [`test-graphql-gate.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-graphql-gate.sh) | `_graphql_polling_gate` + alert rate-limit (`_github.sh`) | mock-`gh /rate_limit` + stub `mint-token.sh` |
| [`test-snapshot-deliveries.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-snapshot-deliveries.sh) | `_deliveries.sh` payload parsing (`-D <hdr> -o <body>` shape) | mock-`curl` |
| [`test-snapshot-mentions.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-snapshot-mentions.sh) | `_mentions.sh` (`mentions:<user>` search fallback) | mock-`gh` GraphQL |
| [`test-idle-probe.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-idle-probe.sh) | `_idle_probe.sh` — really-idle threshold, pane-state filter, wrap-up classification, transition dedupe, idle-too-long, wrapped-but-stub | mock-`tmux` + mock-`pane-state.sh` |
| [`test-unstick.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-unstick.sh) | `_unstick.sh` (`detect_and_unstick`, rate-limit act, orchestrator-ack probe, rate-limit-reset probe) | mock-`tmux`/`curl` |
| [`test-respawn-loop-guard.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-respawn-loop-guard.sh) | crash-loop guard helpers in `_lib.sh` (history grow/decay/reset) | direct function calls |
| [`test-pane-state.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-pane-state.sh) | `pane-state.sh` classifier against ANSI capture fixtures | fixture-driven (`fixtures/*.ansi`) |
| [`test-emit-gate.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-emit-gate.sh) | The emit gate in `main.sh` — every poll with eligible comments must emit; baseline-write discipline | mock-`gh` + per-test `NEXUS_ROOT` |

### Spawn / worker lifecycle

| File | Helper under test | Style |
|---|---|---|
| [`test-spawn-worker.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-spawn-worker.sh) | `monitor/spawn-worker.sh` prompt composition — floor injection, `-r <prior-report>` injection, missing-file exit codes, section ordering | `--print-prompt` mode (no tmux), fake `NEXUS_ROOT` |
| [`test-bootstrap-venv.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-bootstrap-venv.sh) | `monitor/bootstrap-venv.sh` — NEXUS-WIDE toolchain: standalone checksum-pinned `uv` + shared interpreter at `$NEXUS_ROOT/locals` (not per-`work/<project>`), per-project venvs under `locals/venvs/<name>`, all UV_* redirected to `locals/uv/*` (no `$HOME` escape), `locals/bin` on PATH, `only-managed` + `--no-bin`, `PYTHONPATH` clear, no `module load`, `--python`/`--name`/`--dir`/`--root`/`--locals`/`BV_UV_TARGET`/`$NEXUS_ROOT` threading | `--dry-run` env+plan capture + static no-lmod/no-home grep (helper + `locals-env.sh`) + simulated fresh-tmpfs symlink survival (hermetic, no download). Opt-in live end-to-end (real download, two projects sharing one toolchain, `$HOME` wipe, zero-home-write + empty-work-dir asserts) behind `BV_LIVE_TEST=1` |
| [`test-locals-env.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-locals-env.sh) | `monitor/locals-env.sh` — the checked-in sourcer that joins the nexus-wide toolchain: self-locates the nexus root, prepends `locals/bin` to PATH (idempotent), redirects UV_* to `locals/uv/*`, honours pre-set `$NEXUS_ROOT`/`$NEXUS_LOCALS`, pure (no side effects) | source in isolated subshells; assert env values, PATH dedup on triple-source, no dirs created, existing PATH preserved (hermetic) |

### Integration tests (require tmux)

| File | Scope | Notes |
|---|---|---|
| [`test-entry.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-entry.sh) | `watcher/entry.sh` self-checks, session-pin reconciliation (default archive vs `--continue` keep), `svc.sh up` delegation, `services`-cockpit hand-off | stub `tmux` + fixture `monitor/svc.sh` recording argv; the svc.sh stub's exit replaces the cockpit exec |
| [`test-respawn-loop-integration.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-respawn-loop-integration.sh) | crash-loop guard end-to-end through `main.sh` against a real tmux server on a private socket | 15–30 s wall-clock; NOT picked up by `test-*.sh` glob in the way you might assume — invoke directly |

`test-respawn-loop-integration.sh` is the one to know about: it
spins up a dedicated tmux server on a fixture-private socket so
it cannot pollute the running nexus tmux. The harness comment at
the top of the file is worth a read if you're adding an
integration test of your own.

## Conventions

### Mocks on `PATH`

The dominant pattern: shadow `gh`, `curl`, `tmux`, or `date`
with bash functions that branch on env vars to canned responses,
record their argv to side-channel files for assertions, and exit
with controlled codes. The unit-under-test calls the real
invocation shape — `gh api ...`, `curl -D <hdr> -o <body> ...`,
`tmux capture-pane -t ...` — and the mock matches on that
shape.

### Temp roots

Each test sets up its own `NEXUS_ROOT` under `$WORK`
(`mktemp -d`) and tears it down on exit. State files
(`.state/action-log.jsonl`, dedup sets, `idle-state.tsv`) get
inspected via `cat`/`grep` rather than parsed structurally.

### Failure output

A passing assertion prints `ok: <description>`; a failing one
prints `FAIL: <description>` plus the captured value, exits 1,
and the runner echoes `TESTS FAILED`. The harness in
`test-unstick.sh` is the canonical shape — copy it when you
start a new file. The harness comment at the top of that file
explains why bash-native rather than `bats` or `shunit2`: it
keeps the repo zero-dep and the tests stay easy to grep.

## Adding a new test

The trigger is usually one of two patterns:

1. **A bug surfaced in production** that the watcher should have
   caught. Land a fixture that reproduces it (mock or real) and
   the fix that makes it pass in the same PR. This is the
   "test discipline" pattern: every infra fix the orchestrator
   ships under "Infrastructure Issues" should have at least a
   smoke-test in the same commit. The watcher work has been
   built almost entirely this way — `test-emit-gate.sh`,
   `test-snapshot-github-failure.sh`, `test-idle-probe.sh`,
   `test-ng-wrap-up.sh` were all bug-driven.
2. **A new verb or helper.** Mirror the closest existing test
   in style and structure. For a new `ng` verb, copy
   `test-ng-reply-repo.sh` as the template — it has the
   minimal fake-nexus-tree setup, `gh` shadowing, and stdout/
   side-effect capture pattern. For a new watcher helper, copy
   `test-lib.sh` or `test-unstick.sh` depending on whether
   you're testing pure functions or library functions with
   side effects.

For tests that need a real tmux server, follow
`test-respawn-loop-integration.sh`'s private-socket pattern so
the test cannot interfere with the running nexus. Name the file
`test-<scope>-integration.sh` so a future runner can skip the
integration tests cheaply.

### What's safe to mock vs what isn't

The rule of thumb: mock the external surface (`gh`, `curl`,
`tmux`), don't mock the code under test. If you find yourself
mocking a function in `_github.sh` to test `_github.sh`, the
test is going to lie. The watcher test for the GraphQL
rate-limit cascade shadows `gh` and `date` only — every other
function runs for real. That's the bar to hit.

`test-ng-fetch-asset.sh`'s leading comment names the explicit
counter-example: live integration against `github.com/user-attachments/...`
is **not** mocked, but neither is it run by the test. Handing
that URL to a live fetcher or to Read poisons the calling
session for downstream image fetches (the "image-fetch poison"
trap in `CLAUDE.md`). The implementing agent ran the live smoke
test once, recorded the result in the PR body, and the unit
tests cover everything else.

## CI

[`.github/workflows/tests.yml`](https://github.com/<your-org>/nexus-code/blob/main/.github/workflows/tests.yml)
runs the fast unit suite on every `pull_request` to `main`
and every `push` to `main` whose paths touch `monitor/**`,
`config/**`, or the workflow file itself. Steps:

1. Install `jq` + `tmux` on the runner. Ubuntu's pre-installed
   `bash` / `curl` / `openssl` / `gh` cover the rest. `tmux` is
   needed for the few tests that install a real tmux shim on
   PATH (so `command -v tmux` succeeds — `test-lib.sh`,
   `test-full-state-suppression.sh`).
2. `bash -n` every `monitor/**/*.sh` as a cheap syntax gate.
3. Run `monitor/watcher/run-tests.sh --jobs 2` over the
   discovered `monitor/watcher/test-*.sh` set, minus an explicit
   EXCLUDE list (see the workflow yaml — each entry links to a
   tracking issue for the pre-existing failure it papers over).

What runs vs. what self-skips:

- **Fast unit tests** — all of `monitor/watcher/test-*.sh` runs.
- **Slow tests** (`test-respawn-loop-integration.sh`) self-skip
  unless `SLOW_TESTS=1` is set. CI does not set it.
- **Integration tests** (`monitor/watcher/test-integration/*`)
  self-skip unless `RUN_INTEGRATION=1` is set. CI does not set
  it. Bringing integration tests into CI is a follow-up — they
  spin up a real tmux server per scenario and need their own
  job design.

To reproduce a CI failure locally, mirror the runner invocation:

```bash
bash monitor/watcher/run-tests.sh --jobs 2
# or, with verbose per-file output:
bash monitor/watcher/run-tests.sh --jobs 2 --profile
```
