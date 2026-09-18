# Watcher integration harness

End-to-end scenarios that drive a real tmux server + stubbed `claude`
shim through the watcher's pane-state / lifecycle paths. Closes the
structural gap flagged by <your-org>/nexus-code#72: every fix shipped in
PRs `#45` / `#46` / `#55` / `#63` / `#68` / `#73` was unit-tested at
the helper-function level, yet the interaction surface
(`tmux → claude → watcher`) kept regressing because nothing exercised
it as one system.

## Why a separate suite

The fast suite under `monitor/watcher/test-*.sh` is fixture-driven:
ANSI captures in `fixtures/*.ansi` feed `pane-state.sh` directly, and
synthetic state-dir scaffolds feed `main.sh --once`. That gives
millisecond-grade iteration but it cannot catch the bugs that only
surface when a real tmux is rendering, a real `claude` process is
alive in the pane's process tree, and the watcher is reading the same
two surfaces under the same race-window. The integration suite is
explicitly the place for those scenarios.

Trade-offs you sign up for here:

- **Wall-clock cost** — each scenario brings up a tmux server,
  spawns a stub process, and waits for tmux to render. Expect
  ~5-15 s per scenario versus sub-second for the fast suite.
- **Environment dependency** — `tmux` must be on `PATH`. Headless
  CI runners need it installed; macOS local runs need the homebrew
  build. The shim assumes a POSIX `bash` + `ps` + `pgrep`.
- **Real concurrency** — sleeps in the stub interact with the
  watcher's polling cadence. The harness picks tight (sub-second)
  cadences but the scenarios should still assert with generous
  timeouts (`wait_for`) rather than fixed sleeps.

## Opt-in gate

Set `RUN_INTEGRATION=1` to enable. Without it, every integration
test self-skips (matching the `SLOW_TESTS=1` convention but on a
separate axis — slow unit tests run in pre-push, integration tests
run on demand or in a dedicated CI job).

```
RUN_INTEGRATION=1 bash monitor/watcher/test-integration/test-spawn-busy-idle-absent.sh
RUN_INTEGRATION=1 monitor/watcher/run-tests.sh --filter integration
```

`run-tests.sh` picks the suite up automatically (each file self-
skips when the env gate is unset, so the default fast loop pays
only the ~50 ms of `bash -c '<skip>'` per scenario). `--list` tags
them `(integration? mentions RUN_INTEGRATION; …)` and `--filter`
matches by path suffix, so a filter like `integration` catches both
the file in this directory and the legacy
`test-respawn-loop-integration.sh` in `watcher/`.

**The tag says "mentions", and that is the honest word**
(<your-org>/nexus-code#1041 item 2). The `--list` predicate is a
`grep -q` over the whole file, so a usage comment or a `grep`
pattern earns the tag — it is not evidence that a file GATES on the
variable. Most scenarios here mention `RUN_INTEGRATION` only in
their usage header; the real gate is `_harness.sh`, which they
source. Do not read the tag as a gating claim, and do not "tighten"
the predicate: five of the six scenarios that mention the token
mention it only in a comment, so a comment-excluding rule would
drop them while keeping the one known false positive, which carries
the token inside a `grep` pattern string.

## Layout

- `_harness.sh` — shared library. `harness_setup` brings up a
  dedicated tmux server on a private socket, materializes a fake
  nexus root with stubbed `claude` + `tmux` wrappers on `PATH`, and
  exports the bookkeeping every scenario needs (`$HARNESS_DIR`,
  `$HARNESS_SOCK`, `$HARNESS_SESSION`, `$HARNESS_TMUX`,
  `$HARNESS_BIN`). `harness_teardown` kills the server and removes
  the tmpdir. `wait_for` polls a predicate up to a deadline.
- `stub-claude.sh` — controllable `claude` shim. Env knobs:
  - `STUB_CLAUDE_BUSY_SECONDS` — render the `↑ N tokens` spinner
    that `pane-state.sh::_detect_busy` recognises for N seconds,
    then transition to the empty-input-box idle banner. Default 0
    (idle immediately).
  - `STUB_CLAUDE_EXIT_AFTER_BUSY=1` — exit (rc=0) after the busy
    phase instead of going idle. Combined with tmux
    `remain-on-exit on` lets a scenario assert the watcher's
    "claude exited gracefully, window survives" path.
  - `STUB_CLAUDE_HOLD_SECONDS` — after going idle, hold the idle
    render for N seconds before exiting. Default 30 (long enough
    that a scenario asserting on idle has time to capture).
- `test-spawn-busy-idle-absent.sh` — first worked scenario. Spawns
  the stub, waits for tmux to render the busy spinner, asserts
  `pane-state.sh` returns `state=busy`, waits for the idle
  transition, asserts `state=idle`, then kills the window and
  asserts `state=absent`. Validates the same `absent` ↔ `empty`
  disambiguation that has regressed in production three times
  (`#55`, `#63`, the post-`#73` residual surfaced in the operator
  session report).
- `test-slow-grind-respawn.sh` — first Pass B scenario. Boots a
  full `main.sh` poll loop against a fail-injecting tmux wrapper
  that rejects `new-window` for the configured target window.
  Walks the consec-failure counter to its limit, asserts the
  slow-grind stamp + log line on trip, the `respawn paused`
  message during cooldown, the `cooldown elapsed; re-arming guard`
  message after the cooldown override (a small
  `MONITOR_RESPAWN_SLOW_GRIND_COOLDOWN_SECONDS`) elapses, and a
  successful `claude` window spawn once the fail flag is dropped.
  Exercises PR `#80`'s substrate end-to-end — converts its unit
  coverage (`test-respawn-loop-guard.sh`) into a real-loop check.
- `test-wrapup-retain-close.sh` — Pass B scenario 2/4. Boots a
  real `main.sh` poll loop with a low
  `MONITOR_IDLE_THRESHOLD_SECONDS` override, spawns a stub
  worker that runs busy for 3 s then idles, and walks the
  idle-pool classifier through `no-wrap-up` → `wrapped` →
  `retained` by injecting `wrap-up` and `window-retain`
  action-log rows directly. Asserts the corresponding rows + the
  `(N retained windows suppressed: ...)` footer land in the
  archived emits, then `tmux kill-window`s the worker and
  confirms both the tmux window list and the engagement-log row
  drop. Locks in the wrap-up matcher (`_idle_window_wrap_up_report`),
  the retain overlay (`_idle_window_retain_event` +
  `list_really_idle_workers`'s suppression branch), and the
  disappearance prune end-to-end.

## The `#78` two-pass landing — COMPLETE

The issue called for a two-pass landing: Pass A (this directory)
shipped the infrastructure plus one example, Pass B the remaining
four end-to-end scenarios. **All four of Pass B have shipped:**

1. `test-slow-grind-respawn.sh` (1/4)
2. `test-wrapup-retain-close.sh` (2/4)
3. `test-graceful-exit-relaunch.sh` (3/4) — graceful `claude` exit →
   relaunch, over tmux `remain-on-exit on` plus the
   `monitor/claude-loop.sh` opt-in wrapper.
4. `test-same-name-recycle.sh` (4/4) — same-name worker recycle →
   stale wrap-up ignored, asserting on the spawn-time seed from
   `#73`'s D2.

The directory has since grown a second family the Layout section
above does not enumerate: `test-realmodel-*.sh` drives the REAL
`claude` binary against the auth-free mock backend
(`monitor/cc-harness/mock-backend.py`), and
`test-jupyter-service-real.sh` drives real labsh servers on
throwaway ports. **`ls monitor/watcher/test-integration/` is the
list; the Layout section above is a reading aid for the original
four files and is not exhaustive.**

Adding a scenario is mechanical once the harness is in place: source
`_harness.sh`, call `harness_setup`, spawn the stub with the env
knobs the scenario needs, and assert with `wait_for` + the existing
`assert_*` helpers from `_test_helpers.sh`.
