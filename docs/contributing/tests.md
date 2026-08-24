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

### Which bash you are testing under

Every run ends with a line stating the interpreter it took its
evidence under, and whether that matches CI's:

```
=== COVERAGE BOUNDARY: this run took its evidence under bash 4.4; CI runs bash 5.2 ===
```

This is not decoration. No host in this workspace ships bash
5.x; CI runs only 5.2. That asymmetry has already hidden two
real defects, and it hides them in *both* directions:

- **5.2-only, invisible locally.** `run-tests.sh`'s fork-floor
  probe used `( ulimit -Su N; /bin/true )`. Bash may exec the
  last simple command of a subshell in place of the subshell,
  and 5.2 does so where 4.4 does not — so no child was created,
  `RLIMIT_NPROC` was never exercised, every candidate
  "succeeded", and the binary search collapsed to its lower
  bound. CI capped forks at 87 against a real floor of 566 and
  every test then died of `EAGAIN`. It could not be reproduced
  on 4.4 even in principle (`#597`).
- **4.4-only, invisible in CI.** 4.4 is what every host here,
  including the one running the live watcher, actually executes.
  The `bash-legacy` job in `tests.yml` exists for this half.

To run any suite under CI's interpreter, build it once and point
`NEXUS_TEST_SHELL` at it:

```bash
monitor/toolchain-bash.sh --version 5.2          # ~2 min, cached, sha256-pinned
NEXUS_TEST_SHELL=$(monitor/toolchain-bash.sh --print-path) \
    monitor/watcher/run-tests.sh --jobs 4 monitor/test-*.sh
```

The parity line then reads `interpreter parity: bash 5.2`. Add
`--require-ci-parity` to make a mismatch a hard refusal rather
than a declaration — worth it before pushing anything that
touches shell-version-sensitive behaviour (subshell/fork
semantics, parameter expansion, `patsub_replacement`).

`monitor/ci-bash-version` holds the pin, and `tests.yml` asserts
the runner's actual bash matches it — so the boundary local runs
declare cannot quietly become a lie when GitHub bumps its image.

### Do not assert with `printf … | grep -q`

`grep -q` exits the moment it matches, without draining its
input; the writer upstream then takes EPIPE, and under
`set -o pipefail` that becomes the pipeline's status. The
assertion reports **failure at the exact moment the thing it
tested turned out to be true**. This produced a red `dev` on a
~90-byte payload where the code under test was correct. Write
it as a redirection instead — no pipe, no reader to close it:

```bash
grep -q 'needle' <<<"$haystack"      # yes
printf '%s' "$haystack" | grep -q 'needle'   # no
```

`monitor/watcher/test-sigpipe-assertion-lint.sh` enforces this
for `printf` and `echo` — the builtins where the rewrite is
mechanical — and demonstrates the mechanism executably.

The same hazard exists when the producer is a **process**. The
`tmux` half — `tmux list-windows … | grep -qxF "$WINDOW"` and
friends, where a spurious 141 reads as "the window does not
exist" when it does — is owned by
`monitor/watcher/test-tmux-lookup-sigpipe.sh`, which also proves
the rewrite is behaviour-preserving. The remaining producers
(`tr`, `ls`, `locale`, `ss`, `sed`, `cat`, `python`) are not
linted yet and are **not** safe; they are tracked with a full
enumeration at
[`#622`](https://github.com/<your-org>/nexus-code/issues/622).
The drop-in is `grep -q PAT <<<"$(cmd)"`.

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
| [`test-target-window-live.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-target-window-live.sh) | `_target_window_present` against a REAL `remain-on-exit` corpse — the two claims a mock cannot check: that `#{pane_dead}` means what we think on the installed tmux, and that `list-panes -s` did not widen the probe's session scope (`#741`) | real `tmux`, `SLOW_TESTS=1` |
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
- **Slow tests** (`test-respawn-loop-integration.sh` and the
  `SLOW_TESTS`-gated files) self-skip in the fast gate — it does
  not set `SLOW_TESTS=1`. They are **not** unguarded: since
  <your-org>/nexus-code#737 they run as their own blocking check in
  `tests-slow-integration.yml` (below), which is where their
  verdict now comes from.
- **Integration tests** (`monitor/watcher/test-integration/*`)
  self-skip in the fast gate — it does not set `RUN_INTEGRATION=1`.
  They spin up a real tmux server per scenario.

### SLOW + integration band

[`.github/workflows/tests-slow-integration.yml`](https://github.com/<your-org>/nexus-code/blob/main/.github/workflows/tests-slow-integration.yml)
carries **two** jobs, split by cost (<your-org>/nexus-code#737):

- **`SLOW band vs enumerated tolerance`** — the seven
  `SLOW_TESTS=1` scenarios, no integration suite, ~7 min. Runs on
  every PR and push touching `monitor/**` / `config/**`, and it
  **blocks**. This is the band `#729`'s three broken assertions
  lived in, and the one the fast gate is silent about.
- **`SLOW + integration band (scheduled)`** — the **full** suite
  with both gates on (`SLOW_TESTS=1 RUN_INTEGRATION=1`), nightly
  (`cron: '0 7 * * *'`) plus `workflow_dispatch`. Deliberately not
  a per-PR gate: dozens of multi-minute tests plus per-scenario
  tmux bring-up, order 30-60 min wall.

**Why the cheap half became blocking.** "Not blocking" was never
the defect. The defect was non-blocking **and** known-red, under
which a genuine new red is indistinguishable from the accepted
ones — the mechanism that let `#729` sit red for an unknown
period. The fix is that the tolerated set is now **data**
(`monitor/slow-band-known-red.tsv`) and the verdict is a diff
against it (`monitor/slow-band-drift.sh`), in both directions: a
new red fails, a tolerated red that starts passing fails
(`STALE-TOLERATION`, so the list cannot grow monotonically into an
excuse), and a tolerated red the ledger never mentions fails
(`UNACCOUNTED`). That is what lets the band block while a known
red is outstanding.

**Why it also grew `pull_request:` and `push:` triggers.** Until
2026-08-06 this workflow had only `schedule` + `workflow_dispatch`.
GitHub registers and schedules cron from the **default branch**;
the file was added to `dev` on 2026-07-24 and `main` is hundreds of
commits behind, so it never reached the default branch and the
Actions API returned **404** for it — not "runless", *unknown*. It
produced zero runs in the thirteen days it read as coverage. The
control that isolates the variable: `ci-signal.yml` is also
`dev`-only and had 151 runs, because a `pull_request` trigger fires
from the PR head ref. `monitor/lint-workflows.py` rule `SR001` now
fails any workflow that declares `schedule` and nothing that fires
off the default branch, so this cannot recur silently.

It exists to keep slow + integration rot VISIBLE and report it red,
the gap that let `#554` sit unguarded on `dev`
(<your-org>/nexus-code#559).

Mechanics worth knowing:

- Drives the bounded/resumable runner (`--state … --resume
  --max-seconds …`, <your-org>/nexus-code#499) in a loop until the
  ledger is complete (exit `!= 3`), so the ~175-test band
  terminates with an honest PASS/FAIL/TIMEOUT ledger instead of
  timing out unaccounted. `env -u NEXUS_ROOT -u NEXUS_LOCALS` is
  the canonical clean-env drive.
- Two **anti-vacuous-pass guards** run before the band: one asserts
  the integration suite is actually selected (kills the "green
  because it ran nothing" mode of `#484`); the other plants an
  always-failing gated test and asserts the runner goes RED on it
  and self-skips green when the gate is unset (proves the harness
  both runs gated tests and reports their failures).
- The band is honestly red until the residual integration defects
  (unmasked by PR `#561`'s `#554` comm fix) are burned down; per
  `#559` the job is promoted to a required check only once green.
  The ledger + per-test logs upload as a build artifact for
  post-mortem.

To reproduce the fast gate locally, mirror the runner invocation:

```bash
bash monitor/watcher/run-tests.sh --jobs 2
# or, with verbose per-file output:
bash monitor/watcher/run-tests.sh --jobs 2 --profile
```
