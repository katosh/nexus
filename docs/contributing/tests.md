# Tests

The bulk of the test suite lives under `monitor/watcher/test-*.sh`,
with a further set one level up in `monitor/` for the non-watcher
scripts. Both roots are discovered by the runner and by CI; a suite
in either is a first-class member.

**Every test file MUST be a self-contained bash script with a
hand-rolled harness.** It **MUST NOT** introduce a test framework
(`bats`, `shunit2`, `pytest`) or a shared fixture directory that
other suites depend on, and it **MUST** print `ALL TESTS PASSED` and
exit 0 on success.

This is an invariant, not an accident of history. It is what keeps
the repo zero-dependency, keeps a suite greppable as ordinary shell,
and — the load-bearing part — keeps every suite runnable **on its
own**, so a bisect or a single-file repro never has to reconstruct a
framework's state. A shared fixture couples suites, and coupled
suites fail together for reasons that belong to neither.

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
| [`test-respawn-loop-integration.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/test-respawn-loop-integration.sh) | crash-loop guard end-to-end through `main.sh` against a real tmux server on a private socket | ~13 s wall-clock per its own skip message (its header comment still says 15–30 s — the file disagrees with itself); the runner's glob DOES select it (it appears in `run-tests.sh --list`), but it self-skips unless `SLOW_TESTS=1` is exported — so run it as `SLOW_TESTS=1 bash monitor/watcher/test-respawn-loop-integration.sh` |

`test-respawn-loop-integration.sh` is the one to know about: it
spins up a dedicated tmux server on a fixture-private socket so
it cannot pollute the running nexus tmux. The harness comment at
the top of the file is worth a read if you're adding an
integration test of your own.

## Conventions

The rules below are test-authoring specifics. The class of defect they
exist to catch is stated once, in
[Design guidelines](design-guidelines.md); read that first if you are
writing a guard rather than a unit test.

### Mocks on `PATH`

The dominant pattern: shadow `gh`, `curl`, `tmux`, or `date`
with bash functions that branch on env vars to canned responses,
record their argv to side-channel files for assertions, and exit
with controlled codes. The unit-under-test calls the real
invocation shape — `gh api ...`, `curl -D <hdr> -o <body> ...`,
`tmux capture-pane -t ...` — and the mock matches on that
shape.

### Temp roots

**Every test MUST set up its own `NEXUS_ROOT` under a `mktemp -d`
`$WORK` and MUST tear it down on exit.** A test **MUST NOT** read or
write the real `monitor/.state/`, and **MUST NOT** depend on state
another suite left behind.

The reason is the runner: suites execute in parallel (`--jobs 4` in
CI), so a suite that touches the shared root is racing every sibling,
and the failure surfaces in whichever suite loses — never in the one
that caused it. A hermetic root is also what makes a red
reproducible from a single-file invocation.

State files (`.state/action-log.jsonl`, dedup sets,
`idle-state.tsv`) are inspected via `cat`/`grep` rather than parsed
structurally; that is a convention, not an invariant.

### Two isolation classes — and `env -u NEXUS_ROOT` only covers one

<your-org>/nexus-code#1349, #1386, #1335. "Keep the suite off the operator's
tree" has been briefed board-wide as `env -u NEXUS_ROOT -u NEXUS_LOCALS`.
That is correct for one class of consumer and a **no-op** for the other,
and the gate that exists to catch the second class used to report a
scrub-"fixed" suite `hermetic`.

**SPAWN class** — `spawn-worker.sh`, `launcher.sh`, `bootstrap-recover.sh`,
anything that honours an inherited `NEXUS_ROOT` directly. `env -u
NEXUS_ROOT` (with `-u NEXUS_LOCALS`) is correct and remains the fix.

**STATE class** — anything resolving a state dir through the four-arm
chain (`monitor/ng`, `obligations.sh`, `request-channel.sh`,
`skeptic-channel.sh`, `paste-followup.sh`; `retire-preflight.sh` has no
config arm and is NOT a member):

```
1. $NEXUS_STATE_DIR                     unconditional
2. $NEXUS_ROOT/monitor/.state
3. config nexus.root + /monitor/.state  <- on an operator's primary, THE PRIMARY
4. $_script_dir/.state
```

Removing a variable never scopes anything; it advances the search to the
next arm. `env -u NEXUS_ROOT` moves the write from arm 2 to arm 3, and on
the box where it matters those are the same directory. A mid-suite
`unset NEXUS_STATE_DIR` does the same one arm earlier (measured in
`test-orphan-async.sh`: the checkout's own `monitor/.state/heartbeat/`
appeared, holding nothing but the fixture's heartbeat). **The only safe
direction is to SET arm 1.**

**Scope the pin, because arm 1 cannot be fallen past and cannot be
opted out of either** (#1386):

- **Probes** — a one-off `ng` / `declare-wait` / `log-action` call whose
  writes must not land in the operator's state: pin
  `NEXUS_STATE_DIR=<mktemp -d>` **and create the directory** (an absent one
  makes `ng`'s usage tap a silent no-op, so the "fixture" passes without
  exercising the write path).
- **Suites** — anything that arranges its own state dir: **do not pin an
  ambient one around it.** Measured: `test-tmux-window-resolver.sh` goes
  `93/0 -> 91/2` and `test-cc-auto-update.sh` `196/0 -> 87/119` under an
  ambient pin, because the pin overrides every per-fixture root the suite
  built — a red indistinguishable from a diff defect, and one that "check
  `dev` in isolation first" CONFIRMS rather than refutes. If a suite's
  isolation is in doubt, ask the gate instead of pinning from outside:
  `monitor/nexus-root-sensitivity.sh probe <suite>` answers
  `verdict=hermetic|LEAK` per suite, and scrubs any ambient
  `NEXUS_STATE_DIR` itself so its verdict does not depend on your shell.
- **Inside a suite** — pin once, near the top, from the suite's own
  `$WORK`, and never `unset` it later: `th_pin_ng_state <ng> <dir>`
  (`_test_helpers.sh`) does the pin, the `mkdir`, and a behavioural check
  that a real `ng` writes INTO the pin and NOT into a decoy root, failing
  closed and distinguishing "did not leak" from "NOT CHECKED". A suite
  that does not source `_test_helpers.sh` gets `command not found` from
  it — rc 127, no counter moved, a green summary, and the leak intact — so
  carry the check inline there (`test-ng-wrap-up.sh` is the shape).

**Scripts that resolve a state dir and spawn a nexus child must export
`NEXUS_STATE_DIR`**, not just `STATE_DIR` (#1335): `ng` reads the former
and never the latter, so a script whose READS honour `--state-dir` and
whose `ng log-action` WRITES do not puts the audit row in the operator's
live log — 33.7% of it, measured on #1369.

The gate's decoy plants a `config/nexus.yml` naming itself, so an
arm-3 fall-through is observable there (before #1349 it fell into a
placeholder path and the probe read hermetic).

### Failure output

**A passing assertion MUST print `ok: <description>`. A failing one
MUST print `FAIL: <description>` together with the captured value,
and MUST exit non-zero** so the runner echoes `TESTS FAILED`. A
failure that prints a verdict without the value that produced it is
not a usable failure: the next reader cannot tell a real regression
from a stale expectation, and the cheapest resolution of that
ambiguity is to ignore the red.

`test-unstick.sh` is the canonical harness shape — copy it when you
start a new file. Its leading comment explains why bash-native
rather than `bats` or `shunit2`.

### Did this test CONSTRUCT the condition it asserts, or OBSERVE it?

<your-org>/nexus-code#1225. A static read — no fixture, no run, no population
probe. You look at the setup and ask which it did.

> **A fixture that manufactures its own precondition cannot fail for the
> reason it exists.** If the condition was constructed, the assertion is a
> claim about the construction.

The worked instance: a suite asserting `an_IGNORED_file_does_NOT_count_as_dirty`
wrote **its own two-line `.gitignore`**. The assertion was true — of the
fixture. It said nothing whatever about what the repository ignores, which is
the only thing a reader would take it to mean. In the author's words, *"my
suite's own scaffolding committing the defect class the suite exists to
catch."* It now copies the **real** file, which is also what makes the test
beside it mean anything.

This is the mutation-testing question one level out. Not *"would this test
notice a broken subject"* but ***"is this test looking at the subject at
all?"*** Both have the same green answer and only the second is usually asked.

It belongs with the family the repo keeps re-finding — `#1054`
(untracked vs tracked), `#1150` (worktree vs clone), `#1217` (staged vs
committed), `#1224` (applicability vs conformance). Same root: **the instrument
read a tree, or a world, other than the one the claim is about**, and nothing
errored.

### Never ship a test that is RED BY CONSTRUCTION on the documented path

Same issue. A tripwire that cannot pass where the docs tell people to run it is
worse than no tripwire:

> **A test that is red-by-construction on the prescribed path trains people to
> ignore reds.** It spends the alarm budget of every future reader on a signal
> that carries no information.

The instance needed **splitting**, and the split is the reusable part. One half
— does the shipped rule really hide the path — is measurable anywhere. The
other half — is anything tracked under a given directory — needs a **real
checkout**, and the project's own runner banner prescribes
`rsync --exclude .git`, so an unconditional version of that half is red on the
documented path by construction.

The fix is not to delete the half that cannot always run. It is to make it
**say on stderr that it could not look**, rather than failing. A skip that
names what went unmeasured is honest; a red that everyone learns to ignore is
not. The first version had no split and went red in the stripped copy — caught
by **its own positive control**, which is the argument for having one.

### Annotate what BREAKS, not "do not change"

<your-org>/nexus-code#1180.

> **A fix whose CORRECT behaviour looks like a defect will be reverted by
> someone trying to help.**
>
> The remedy is not a comment saying *"do not change this"* — it is a comment
> saying **what BREAKS when you do**, next to the value.

The failure mode is not carelessness. It is a competent reader meeting a value
that looks wrong, having no way to learn why it is right, and improving it.
**Review does not catch it**, because at review time the reverting diff looks
like a tidy-up and the original justification is not in the file — it is in an
issue nobody opens while deleting a line.

So when a guard, ceiling, exit code, timeout or default is set to a value a
reader could reasonably think is a mistake, the comment beside it states the
failure that returns if it is changed. Two worked shapes:

```sh
# --timeout 900, NOT the 600 in this file's header: test-run-tests-bounded.sh
# takes 629s standalone, and at 600 the gate reports it as a HANG that is not
# one — a false positive on #547's hangs criterion, in the "dev regresses"
# direction. See #1151.
```

```sh
# Ends with `exit $rc` so the notification carries the await's code, not the
# echo's. A routine `4` will render as "failed" — that is EXPECTED. Remove
# this and a `11` (COUNTERPART-FINISHED) flattens to `0` = "acked open
# requests", and the loop answers requests that do not exist. See #1161.
```

Both share the shape worth recognising: a value whose **correct** setting is
locally implausible, whose justification lives outside the file, and whose
reversion is silent, well-intentioned, and invisible at review. Both fail
toward a **confident wrong answer** rather than an error — this repo's dominant
defect class, reached through maintenance rather than through authorship.

**Why this lives here and not in `CLAUDE.md`.** That file's gotchas are a
specific genre — *a tool lies to you*, each entry carrying a checked,
executable block under `monitor/watcher/test-claude-md-*.sh`. This rule is
about the CONTENT OF A COMMENT: nothing can assert it, and putting an
unassertable prose rule among assertable ones dilutes the property that makes
that section trustworthy, which is that every claim in it has been run.

### A differential MUST NOT share anything with its arms except the input

<your-org>/nexus-code#1210, BLINDNESS A.

> **A differential is blind to any change ABOVE the level it patches.**
> If the treatment is applied below the thing that carries the effect,
> the treatment was applied to the control.

The measured instance: a differential monkeypatched two functions to
compare a memoised implementation against a naive one. The memo lived
in their **caller**, above both patch points — so it was common to
both arms, and the differential reported zero difference for a cache
that was silently wrong on 1,485 of 20,234 inputs. **It could not
have been written more carefully and still seen this.** No amount of
assertion strength reaches a variable that is not varied.

**So the remedy is structural, not editorial. Materialise the base
version as a sibling module (or a separate process) and drive both
arms from one input.** Nothing may be shared between the arms except
that input. If you cannot state, in one sentence, what the two arms
do *not* share, you do not have a differential — you have one
implementation measured twice.

### A convergence check MUST obtain its cold observation from a fresh process

<your-org>/nexus-code#1210, BLINDNESS B — the half that survives careful
writing, and the one worth carrying.

> **You cannot detect a leak by comparing two runs that both leaked.**
> A check for contaminated state needs an observation from BEFORE the
> contamination existed. A write-once cache reaches its fixed point
> after one pass, so within a process there is exactly ONE cold
> observation — and the first measurement consumes it.

Idempotence (sweep the same inputs twice) and order-independence
(forward versus reversed) feel like differentials and are not. They
patch nothing. Against a write-once, deterministic cache they compare
two **post-convergence** observations, which are equal *by
construction* — whatever the order, however many inputs. Measured:
both formulations reported zero drift against a genuinely hoisted
cache. A green from either is a statement about arithmetic, not about
the code.

**Process isolation is therefore not fastidiousness here; it is the
only way to obtain a second cold observation.** The shipped test runs
two **subprocesses** over the same inputs in opposite orders, each
with its own cold cache, so order decides which input writes each
position first — and the two genuinely disagree on 19 of 34 blocks.

The generalisation, because it is not about caches: **when the state
you suspect is monotone — write-once, memoised, accumulated, lazily
initialised — the number of independent observations available inside
one process is one.** Ask how many cold observations your check needs
before you ask how many runs it performs.

### Red is not enough — WHICH assertion went red is the deliverable

<your-org>/nexus-code#1210, the third hazard, met while fixing the first two.

> **A test that fails for the right reason by ACCIDENT is barely
> better than one that passes for the wrong one — because the message
> is what the next person acts on.**

The first formulation *did* go red on the mutant. It went red by
tripping its own **potency assertion**, not its property assertion:
the same module-scoped cache that broke the property also starved the
emulation the potency check depended on. A future reader would have
been told *"this test is stale"* when the truth was *"this code is
broken"* — and would have fixed the test.

**So a mutation run MUST record which assertion fired and what it
says, not merely that the run was red.** A red whose message names
the wrong subject is a wrong answer with a green-looking provenance.

**And a classifier can commit the same error against source text.**
A live instance, at `5bd6d400`: `_tmux_shim_scan.awk` flagged a line
of `test-tmux-shim.sh` as
`UNSAFE|copy: body names the wrapper LITERALLY`. The verdict was
correct and the statement it named was not — the `tmuxwrap` literal
belongs to a `grep -q 'monitor/tmuxwrap/tmux' "$TWO_OLD/tmux"`
**assertion**, four simple commands further along the same `&&`-joined
logical line than the `sed` that does the writing. The scanner
attributed the literal to the whole logical line, so it reported a
writer where there was a checker. Fixed by scoping the body to its own
simple command. (Cited by content, not by line: the blob is
`14627a60ffa06e4b41698a4c66262cfc157fdd22`.) **Whatever your unit of
attribution is — a logical line, a function, a file — a finding names
that unit, not the statement inside it that you meant.**

### The evidence standard for a mutation run

Same issue, and the shape to copy. **A plant MUST be proven applied
in the FILE and in the RUN** — a prior suite recorded a mutant that
landed in the file and never executed, so the guard reported a clean
pass for code that never ran:

```text
md5 clean    5a76afe6556367176ca54109cc2c9cc8
md5 mutant   4b5d372f43d09164caa279124f024874
structural   module-level `reach_at` present = 1, local = 0
in the RUN   import olay.attest -> hasattr(A, "reach_at") is True

rc_red   = 1   FAIL <the property assertion, named>
rc_green = 0   PASS after restore
restore  verified by md5, `diff -q`, and an empty `git status --porcelain`
```

Four independent facts, because each alone has a failure mode: an md5
proves the bytes changed and not that they were imported; a
structural grep proves the text is there and not that the branch ran;
an in-the-run probe proves execution and not that the restore
happened.

**And the rc MUST be captured with NOTHING between the command and
`$?`** — no pipe, no `timeout`, no trailing `&& echo`. A pipeline's
status is its last command's (<your-org>/nexus-code#928), a command
substitution in the same argument list overwrites `$?` before it is
read (`#1202`), and `timeout` injects `124` of its own. In a mutation
run the artefact under construction *is* a status report, which is
the worst possible place to lose a status.

**Finally, under the same mutant the OTHER tests must be run too**, and
their passing recorded. That is what reproduces the blindness rather
than taking it on trust — it is the difference between "my new test
catches this" and "my new test catches this and the old ones
demonstrably do not".

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
runs the fast unit suite on every `pull_request` into **`main` or
`dev`**, every `push` to those branches, and on `workflow_dispatch`.
The `paths:` filter — identical on both triggers — is:

```yaml
- 'monitor/**'
- 'config/**'
- '.github/workflows/**'   # the suite EXECUTES the workflow corpus
- 'CLAUDE.md'              # 30 test-claude-md-*.sh suites read it; 26 of its
                           # 27 marker blocks are EXECUTED as fixtures. The
                           # 27th, WINDOW-KEY-VOCABULARY, carries no fence at
                           # all — mode `drives` in claude-md-markers.manifest
- 'skills/**'              # test-spawn-worker.sh executes the worker floor
```

The last three are not housekeeping. This suite runs those files as
**fixtures**, so omitting them makes the guard blind to the files it
guards — a PR editing only the worker floor, the highest-blast-radius
edit in the repo, would match no path here and run no tests while
`gh pr checks` showed the by-construction-green `ci-signal`. Each
entry in the workflow carries the issue that added it
(<your-org>/nexus-code#736, `#604`, `#835`). **The workflow's own
`paths:` list is canonical; this block is a reading aid and MUST be
re-derived from the yaml before it is quoted.**

This workflow is not one job. At `a3177ef6` it carries `syntax`,
`unit` (a `login_shell` × `jobs` matrix — bash@4 and zsh@4),
`clean-env`, `inherited-root`, `inherited-root-gate`, `bash-legacy`
and `tmux-matrix`; the yaml is canonical and this list is a reading
aid. The steps below are the fast unit path only, split across
`syntax` (2, 3) and `unit` (1, 4):

1. Install `jq` + `tmux` + `zsh` on the runner. Ubuntu's
   pre-installed `bash` / `curl` / `openssl` / `gh` cover the rest.
   `tmux` is needed for the few tests that install a real tmux shim
   on PATH (so `command -v tmux` succeeds — `test-lib.sh`,
   `test-full-state-suppression.sh`).
2. Assert the runner's `bash` matches `monitor/ci-bash-version`, so
   the coverage boundary a local run declares cannot quietly become
   a lie when GitHub bumps its image.
3. `bash -n` every shell file under `monitor/` as a cheap syntax
   gate.
4. Discover the suite with
   `find monitor monitor/watcher -maxdepth 1 -name 'test-*.sh'` —
   **both** roots, because `monitor/` holds the suites for the
   non-watcher scripts and discovering only `monitor/watcher/` once
   meant those ran nowhere (<your-org>/nexus-code#484). The step
   **refuses to report green on an empty selection**. It then runs
   `monitor/watcher/run-tests.sh --jobs 4` over that set, once per
   login-shell matrix cell (bash and zsh).

There is **no EXCLUDE list** in this workflow. An earlier version of
this page described one; it is gone.

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

- **`SLOW band vs enumerated tolerance`** — every
  `SLOW_TESTS=1`-gated scenario on disk (the job enumerates them with
  `grep -l SLOW_TESTS monitor/watcher/test-*.sh`; 13 at `a3177ef6`),
  no integration suite, ~7 min. Runs on
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
  the canonical clean-env drive — for the SPAWN class. It does not
  isolate STATE-class consumers (`ng`, `obligations.sh`, …), whose
  resolver falls through to config `nexus.root`; a runner's own
  ad-hoc `ng` calls need `NEXUS_STATE_DIR` pinned to a created
  scratch dir, while the suites keep their own pins. See "Two
  isolation classes" under Conventions (<your-org>/nexus-code#1349).
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
