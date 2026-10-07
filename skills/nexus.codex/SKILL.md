---
name: nexus.codex
description: "OpenAI Codex CLI in the nexus (<your-org>/nexus-code#1640). Layer 1: a Claude Code worker delegates a BOUNDED subtask to `codex exec` through `ng codex run` (monitor/codex-run.sh) and gets a typed verdict, the event stream, the final message, the diff of the tree and a list of every other write back, while the worker stays the owner of the report, the wrap-up and the skeptic contract. Covers when a co-worker is worth it, the exit-code vocabulary (7 = indeterminate, neither), the measured traps of a raw `codex exec` (it reads and APPENDS inherited stdin, it does not read OPENAI_API_KEY, its own bubblewrap sandbox cannot run a single command inside this nexus's kernel sandbox), the pinned install in its own package root, the model default, `--background` for long runs, and the hermetic mock Responses backend for testing against the real binary. Layer 2: a Codex TUI as a FIRST-CLASS worker, `spawn-worker.sh --harness codex` — what is reused unchanged, what differs (persisted folder trust, the TUI's auth.json, hooks → the nexus heartbeat and submit-stamp, pane-state's Codex classifier, `ng send` via harness/codex.sh, `codex resume`, report session id from CODEX_THREAD_ID), what a Codex worker does NOT get, and the coverage boundary."
---

# Codex as a supervised co-worker

**What it is.** `monitor/ng codex run` (`monitor/codex-run.sh`) runs one
`codex exec` turn on a git working tree you name, and hands back everything
you need to *judge* the result:

| artefact (`--out` dir) | what it is |
|---|---|
| `status` | `key=value`: verdict, codex's process rc, thread id, model, installed vs expected version, commands run/failed, tree snapshots |
| `diff.patch`, `diffstat.txt` | Codex's change to the **non-ignored part of `--cd`**: the working tree snapshotted before and after through a private index. Your index and HEAD are never touched, and pre-existing edits are never attributed to Codex. It is **not** every write Codex made (next rows) |
| `writes.txt`, `writes-outside-diff.txt` | every file written during the run under `--cd` and each `--also-watch DIR` (a `find -newer` marker taken just before Codex started), and the subset the diff does NOT show: gitignored files and `--also-watch` writes. The count is `writes_outside_diff` in `status` and in the verdict line |
| `commands.txt` | every command Codex ran, with its exit code. Under `danger-full-access` Codex can write anywhere the kernel sandbox allows; a write outside `--cd` and every `--also-watch` dir shows up **only** here |
| `last-message.txt` | Codex's final message |
| `events.jsonl` | the full `codex exec --json` stream (every command, its exit code) |
| `prompt.txt`, `argv.txt`, `stderr.log` | what was sent, how, and what codex said on stderr |

**What it is not.** A way to offload responsibility. You remain the owner of
the report, the wrap-up and the skeptic contract. Codex's final message is a
*claim*, and its diff is a *proposal*. Read both, run the tests yourself, and
cite them in your report the way you would cite a colleague's work: with
your own verification beside it.

## When it is worth it

- **A second, independent implementation or review** of something you
  wrote, where agreement between two different model families is evidence
  and disagreement is a lead.
- **A bounded, well-specified edit** you can verify mechanically: a
  refactor with a test suite, a port, a mechanical sweep.
- **Not** for anything touching GitHub, the board, other workers, or state
  under `monitor/.state/`. Codex does not know the nexus contract. It reads
  none of the hooks, the floor or this file, and a Codex process writes as
  YOUR uid.

## How

```zsh
monitor/ng codex run --cd <git-root> --prompt-file task.md             # sync, default 1800 s bound
monitor/ng codex run --cd <git-root> --prompt-file task.md --background  # long: armed via ng longjob
monitor/ng codex run --cd <git-root> --prompt-file task.md --resume <thread-id>   # continue a thread
monitor/ng codex run --cd <git-root> --prompt-file task.md --dry-run   # show the argv, run nothing
```

- `--cd` must be a git repository **root**. A subdirectory is refused
  (exit 6), because `git -C <subdir>` walks up and the snapshot would
  describe the enclosing repo (CLAUDE.md, REPO-WALKUP). Use a worktree of
  your own clone when you want Codex's edits isolated from yours.
- A dirty tree is refused unless `--allow-dirty`. Pre-existing edits are
  never attributed to Codex either way; the flag exists because Codex may
  edit the files you have open.
- **What is captured, precisely.** `diff.patch` covers the non-ignored part
  of `--cd`. `writes-outside-diff.txt` adds gitignored writes under `--cd`
  and writes under every `--also-watch DIR`. Deletions outside the diff are
  not listed. Anything else Codex touched is visible only through
  `commands.txt`. Pass `--also-watch` for any directory you care about,
  such as the nexus state dir or a sibling clone.
- Write the task as you would brief a contractor: goal, constraints, the
  test that decides success, what NOT to touch. Codex sees only the prompt
  and the tree.

### Exit codes: read them, every one

| rc | verdict | meaning |
|---|---|---|
| 0 | `completed` | codex emitted `turn.completed`. Says nothing about correctness |
| 2 | `usage` | nothing ran |
| 3 | `turn-failed` | codex emitted `turn.failed`/`error` (quota, auth, refusal). The message is in the verdict line |
| 4 | `timeout` | the `--timeout` bound fired (wrapper rc 124/137/143, tested as a SET) |
| 5 | `unavailable` | no binary, or no credential of any kind |
| 6 | `workdir` | not a repo root, dirty without `--allow-dirty`, or the snapshot failed |
| 7 | `indeterminate` | codex exited with **no** terminal event. **Neither** outcome is established; read the artefacts |
| 8 | `background-launch-failed` | `--background` could not arm the longjob |

The verdict comes from the **event stream**, not from codex's process rc,
and both are reported. `rc 0 + no terminal event` is 7, never 0, because a
clean exit is a claim about the process, not about the turn.

## Measured traps: why never a raw `codex exec`

All measured on codex-cli 0.156.1 inside this nexus's kernel sandbox,
2026-09-26.

1. **It reads your stdin and APPENDS it to the task.** With stdin not a
   tty, `codex exec` prints `Reading additional input from stdin...` and
   splices whatever arrives into the prompt. From an agent's Bash tool call,
   stdin is inherited, so the call can block or ingest junk. `codex-run`
   feeds the prompt as stdin *from a file* (and passes `-`), so neither can
   happen.
2. **It does not read `OPENAI_API_KEY`.** Only `OPENAI_API_KEY` set gives
   `401 Missing bearer`. With `CODEX_API_KEY` set to the same value, the key
   is accepted. The agent-sandbox provisions `OPENAI_API_KEY` (its codex
   overlay declares both names). `codex-run` exports the mapping, and never
   as an `env KEY=… codex` argv, where the value would be readable through
   `/proc`. The interactive TUI reads neither: it needs
   `$CODEX_HOME/auth.json`.
3. **Its own sandbox cannot run anything here.** `read-only` and
   `workspace-write` run every command through bubblewrap, which fails with
   `bwrap: Failed to make / slave: Operation not permitted`. The deprecated
   landlock path (`--enable use_legacy_landlock`) did not execute the test
   command either. **Only `danger-full-access` executes**, so it is the
   default. It drops Codex's *inner* layer only. The kernel sandbox this
   nexus runs in still binds every write, exactly as it does for Claude Code
   under `--dangerously-skip-permissions`. Nothing here touches the outer
   sandbox, and nothing may. A `read-only` run is allowed for a
   pure-reasoning task and warns that every command will fail.
4. **The prompt belongs off argv.** Sibling agents' `/proc` scans ingest
   argv (<your-org>/nexus-code#1612). The raw form puts your whole brief
   there.
5. **An update prompt and a folder-trust dialog block the TUI** on first
   start. `exec` is unaffected. This matters for the interactive harness,
   not for this helper.

## Install, version, model

- **Binary.** `codex-cli/node_modules/.bin/codex`, installed by
  `monitor/install-codex-local.sh` (`--check` verifies without installing).
  It lives in its **own package root**, `codex-cli/`, not the nexus
  root. Measured while building this: adding codex to the root
  `package.json` made one `npm install` rewrite nine
  `@anthropic-ai/claude-code` lock entries. On an operator whose cc
  local-pin is ahead of the floor, that silently downgrades Claude Code.
- **Version.** `codex-cli/package.json` is a vetted floor. We
  pinned 0.156.1 because 0.157.1 was under a day old, the same ≥1-day rule
  as the cc floor. `monitor/.state/codex-version-local` (gitignored)
  overrides it. A local pin file that exists but is blank reads
  `<unreadable-pin>` and is never silently treated as the floor. Every run
  records `codex_version` against `expected_version` and warns on drift.
- **Model.** `config: monitor.codex.model`, default `gpt-6-astra`. That is
  our choice, not an upstream default: it is the catalogue's frontier
  entry. `gpt-6-sol` is its cheaper "workhorse model for coding". List what
  the installed CLI knows with
  `codex-cli/node_modules/.bin/codex debug models </dev/null`.
- **Credential.** Presence only: `ng codex run` exits 5 when there is
  neither a key in the environment nor an `auth.json`. A key that is present
  but out of quota is a `turn-failed` (3) whose message says so. That was
  the state of this nexus's key on 2026-09-26.

## Testing against the real binary without OpenAI

`monitor/codex-harness/mock-responses.py` is a stdlib, py3.6-safe mock of
the OpenAI Responses API (the Codex counterpart of
`monitor/cc-harness/mock-backend.py`). Point codex at it with a custom
provider. No key reaches it: measured, a custom provider without `env_key`
sends no `Authorization` header at all.

```zsh
--config model_provider=nexusmock \
--config 'model_providers.nexusmock={name="nexusmock",base_url="http://127.0.0.1:PORT/v1",wire_api="responses"}'
```

A `control.json` scripts the turn: `text`, `shell` (one real tool call),
`hang`, `error`. Use model `gpt-5.5` for `shell` scenarios. The gpt-6
entries route shell through a JavaScript code-mode tool the mock does not
script. Suites: `monitor/watcher/test-codex-run.sh` (stub, hermetic,
always runs) and `monitor/watcher/test-codex-run-real.sh` (real binary +
mock; SKIP 77 where the binary is not installed).

## Coverage boundary

- A **real OpenAI** turn has NOT been observed end to end through
  `codex-run`: this nexus's key returned `Quota exceeded` on the only live
  attempt. Every end-to-end claim above is real-binary-against-mock. The
  quota failure itself is the one real-API observation, and it surfaced as
  exit 3 as designed.
- The mock implements the Responses SSE subset codex 0.156.1 consumed in
  our scenarios. A newer codex may need events it does not send. The real
  suite is where that would show, as a failure, not a skip.
- Layer 2's boundary is in its own section below.

# Codex as a first-class worker (layer 2)

```zsh
monitor/spawn-worker.sh -n <window> -c <workdir> -p <task> --harness codex [--model <openai-model>]
monitor/spawn-worker.sh --resume <window>          # a Codex window resumes as `codex resume <thread>`
```

A Codex TUI in its own tmux window, addressed, watched, messaged, retired
and resumed like any worker. **One-time operator setup:**
`monitor/install-codex-local.sh`, then, inside the sandbox,
`printenv OPENAI_API_KEY | codex-cli/node_modules/.bin/codex login --with-api-key`.
The TUI reads **no** API key from the environment (measured), so without
`$CODEX_HOME/auth.json` the spawn refuses with exit 25 rather than parking a
worker on a login screen.

## What is reused unchanged

The argument contract, root/state resolution, the write probe, the skeptic
self-spawn guard, the floor and prompt composition, the launcher prelude
(NEXUS_* exports, locals-env, TMPDIR, the nproc ceiling, the fail-closed
shim guard), the tmux window, the lifecycle anchors, the provenance record
(`harness: codex`), `ng report-init` / `report-check` / `ng wrap-up`, and
the skeptic contract.

## What differs, each item measured on codex-cli 0.156.1

| concern | Claude Code worker | Codex worker |
|---|---|---|
| launch | `claude --dangerously-skip-permissions --settings worker-settings.json` | `codex -s danger-full-access -a never` + `-c` overrides (`monitor/_spawn-codex.sh`) |
| folder trust | `CLAUDE_CODE_SANDBOXED=1` + verify | **persisted** in `$CODEX_HOME/config.toml` (`monitor/codex-trust-workdir.sh`): a `-c projects…` override does NOT suppress the dialog |
| first-run dialogs | trust | update prompt (`check_for_update_on_startup=false`), trust (seeded), hook review (`--dangerously-bypass-hook-trust`, below) |
| hooks | `worker-settings.json` | `-c hooks.<Event>=…` → `monitor/codex-hook.sh` → `worker-heartbeat.sh`: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop. Same heartbeat, same submit-stamp |
| session id | pre-assigned `--session-id` | Codex has no such flag: `SessionStart` writes the thread id into the descriptor; `$CODEX_THREAD_ID` in every Codex shell |
| pane-state | the Claude ladder | `monitor/_pane-state-codex.sh`, from real captures; identity from the process walk (`…/@openai/codex…/bin/codex`) or Codex's chrome |
| delivery | `ng send` (claude-code adapter) | `ng send` via `monitor/harness/codex.sh` → tmux-paste; receipt = submit-stamp, and it arrives on the QUEUED path too (a steer fires UserPromptSubmit when consumed — unlike #1099) |
| resume | `claude --resume <sid>` | `codex resume <thread>` (rollout under `$CODEX_HOME/sessions`); Codex compacts the thread on resume |
| instructions | CLAUDE.md files auto-loaded up the tree | `CLAUDE.md` inside the workdir's repository via `project_doc_fallback_filenames` (budget 256 KiB; the default 32 KiB truncated the nexus one); the nexus `CLAUDE.md` via the prompt's Codex addendum. **No `AGENTS.md` is ever created under `work/`** |

## What a Codex worker does NOT get, and the substitute

The `## Codex worker addendum` in `skills/nexus.worker-defaults/SKILL.md` is
injected after the floor into every Codex spawn, and says this to the worker:

- **No `SendMessage` / `ListAgents`.** The upward channel is
  `ng request file --origin <window> …`.
- **No wake mechanism.** There is no `Monitor`, no `run_in_background`, and
  the longjob dispatcher is a Claude Code plugin monitor. A Codex turn ends
  and nothing re-invokes it; the orchestrator sees the pane go idle.
- **Codex HAS `PreToolUse`** (and `PermissionRequest`); 0.156.1 lists both
  among its hook events. The nexus wires `PreToolUse` to the heartbeat only,
  so a tool's START marks the turn busy. The Claude PreToolUse **guard
  scripts** (footgun guard, `gh` write guard) are deliberately NOT wired:
  their matchers key on Claude tool names (`Bash|Write|Edit`), and their
  payload contract for Codex's tools (`exec_command`, `apply_patch`) is
  unmeasured. That is a follow-up, not an impossibility. The PATH shims
  (`gh`, `pip`, `tmux`) still apply.
- **No Claude trust verification** after spawn. A Codex dialog reads
  `blocked overlay=codex-*` in pane-state and is never auto-answered. The
  `codex-` prefix exists so the Claude recovery path, which matches
  `overlay=workspace-trust` and types into the pane, can never select it.

## Hook trust: a stated residual

Codex refuses to run session-flag hooks until their sha256 is trusted, and
the hash is not reproducible offline, so the launcher passes
`--dangerously-bypass-hook-trust`. That also runs a foreign repo's
`.codex/hooks.json` unreviewed once its folder is trusted. We BELIEVE this
is parity with a Claude worker, whose trusted workspace runs project hooks
under `--dangerously-skip-permissions`; the Claude side of that was not
re-measured here. Codex-internal only: the kernel sandbox binds both.

## Tests

- `monitor/watcher/test-codex-worker.sh`: hermetic, stub codex and tmux.
  Spawn refusals (24/25), the launcher, the descriptor, trust, the addendum
  (with a Claude negative control), resume, the hook adapter, the trust
  seeder, the report session id (never another agent's Claude transcript),
  and the delivery adapter.
- `monitor/watcher/test-pane-state-codex.sh`: the kill hazard as a
  differential pair (exe `…/bin/codex` idle vs `…/bin/codax` absent), the
  heartbeat override, `unknown` for unreadable chrome, the whole Claude
  corpus as a negative control, and the kill allowlist agreeing. Plus 14
  REAL captures in `pane-state-fixtures.manifest`.
- `monitor/watcher/test-integration/test-codex-worker-e2e.sh`
  (`RUN_INTEGRATION=1`): the real `spawn-worker.sh` and the real codex TUI
  on a private tmux server against the mock. It covers task execution,
  busy→idle with **no** `absent`, heartbeat, submit-stamp and descriptor
  thread id, `ng send` + `--check` delivered, and `--resume` with history.
  Its header lists every isolation pin and why.

## Layer 2 coverage boundary

- A **real OpenAI turn in a Codex worker** was not observed (quota). The
  real TUI against the real API was captured idle, working, typed and
  quota-failed; every multi-turn claim is real-TUI-against-mock.
- **Not captured:** the approval dialog and the `request_user_input`
  dialog. Workers bypass approvals, and no scenario asked a question. Both
  are covered only by the generic menu arms; a dialog matching neither reads
  `unknown` (safe), not `blocked`.
- **Watcher-level features keyed on Claude private state** degrade
  gracefully for a Codex window but are not Codex-aware:
  paste-followup's own transcript confirmation (it returns `UNKNOWN`, and
  `ng send --check` resolves it on the submit-stamp), `_submit_evidence`
  content-digest matching, the orchestrator-liveness and cc-update paths,
  and async-run / longjob session keys (`CLAUDE_CODE_SESSION_ID`).
- **The Codex version pin** is floor + local pin + a drift warning. There is
  no gated auto-update like `cc-update`; bump `codex-cli/package.json`
  deliberately, then re-run the fixtures (Codex's chrome is
  version-sensitive, exactly as Claude's is).
