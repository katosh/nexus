# ng CLI

`monitor/ng` is the nexus's GitHub helper. It wraps the common bot
operations — reacting on comments, opening issues and PRs, posting
replies, uploading assets, wrapping up reports — into tight
subcommands so an agent can write to GitHub without juggling
`gh` + `jq` + raw REST URLs in every shell call.

Every write uses the bot's installation token (minted by
`monitor/mint-token.sh` from the GitHub App private key), **never**
the user's `gh` token. GitHub mutes notifications for actions taken
by the recipient's own account; routing through the bot is what
keeps the operator's notification surface alive. The only GitHub
interactions that should still use the user's identity are
`git commit` and `git push` (for accurate commit authorship). See
[Security](../admin/security.md) for the full identity boundary.

## Conventions

**Identity** — `github.repo` and `github.user_login` come from
`config/nexus.yml` via `config/load.sh` (see [Config](config.md)).
`MONITOR_REPO` / `MONITOR_USER_LOGIN` override.

**Repo argument** — most verbs accept `--repo <owner>/<name>` to
target a non-default repo. Unset, the cwd-derive default depends on
whether the verb writes or reads:

- **Read verbs** (`issue view`, `pr view`, `show`) prefer the cwd's
  `git remote get-url origin` if it is a `github.com` URL (with a
  one-line stderr warning when different from `$REPO`), else fall
  back to `$REPO`.
- **Write verbs** (`reply`, `issue create`, `issue comment`,
  `pr create|edit|merge`, `upload`, `wrap-up`) prefer `$REPO` from
  config. If the cwd has a `github.com` origin that **differs** from
  `$REPO`, the verb refuses to write — closing the soon-to-be-public
  nexus-code leak risk — and emits a structured error asking for an
  explicit `--repo`.

**Body input** — verbs that POST a body (`reply`, `issue create`,
`issue comment`, `pr create`, `pr edit`) accept the body via
`--body-file <path>` or stdin. Pass long markdown in a file; piping
short replies via `echo "thanks" | ng reply 7` works too.

**Output discipline** — verbs print *just* their primary result
(URL, SHA, comment ID, …) on stdout. Stderr carries warnings and
errors. This makes pipelines (`url=$(ng pr create …)`) trivial.

**Exit codes** — `0` on success, `1` on usage/operation failure,
verb-specific codes documented per verb (e.g.
[`ng fetch-asset`](#ng-fetch-asset), [`ng report-check`](#ng-report-check),
[`ng watcher-status`](#ng-watcher-status)).

## Quick reference

| Verb | One-line | Section |
|---|---|---|
| `ng process <id>` | eyes-react + fetch body for a user comment | [→](#ng-process) |
| `ng process-issue <n>` | eyes-react + fetch body for a user issue | [→](#ng-process-issue) |
| `ng react <id> <kind>` | post a reaction on a comment | [→](#ng-react) |
| `ng react-issue <n> <kind>` | post a reaction on an issue | [→](#ng-react-issue) |
| `ng show <id>` | read a comment body (no eligibility filter) | [→](#ng-show) |
| `ng reply <n>` | post a comment on an issue/PR | [→](#ng-reply) |
| `ng close <n>` | close an issue, optionally with a comment | [→](#ng-close) |
| `ng issue <n>` | view issue (one-liner; flags expand) | [→](#ng-issue) |
| `ng issue create` | open a new issue | [→](#ng-issue-create) |
| `ng issue comment <n>` | alias of `ng reply` under `issue` namespace | [→](#ng-issue-comment) |
| `ng pr create` | open a PR with auto-requested reviewer | [→](#ng-pr-create) |
| `ng pr edit <n>` | patch a PR title or body | [→](#ng-pr-edit) |
| `ng pr merge <n>` | merge a PR via REST | [→](#ng-pr-merge) |
| `ng pr view <n>` | one-line PR summary | [→](#ng-pr-view) |
| `ng preflight <repo>` | is the bot installed on this repo? | [→](#ng-preflight) |
| `ng upload <file>` | push asset to asset repo, print pinned URL | [→](#ng-upload) |
| `ng wrap-up <n> <report>` | end-of-task hand-off (upload + comment + rocket + log + retain) | [→](#ng-wrap-up) |
| `ng wrap-up-check <window>` | verify a worker's wrap-up obligations before closing | [→](#ng-wrap-up-check) |
| `ng skeptic <sub>` | worker↔skeptic comms channel + nudge (delegator) | [→](#ng-skeptic) |
| `ng respawn <window\|sid>` | resume a wrapped/closed worker's session in a tmux window | [→](#ng-respawn) |
| `ng service-incident <svc>` | assemble a service incident report from recorded state | [→](#ng-service-incident) |
| `ng spawn-decision <window>` | advisory continue-vs-spawn classifier for a window | [→](#ng-spawn-decision) |
| `ng engaged-done` | release an operator-engaged interactive window | [→](#ng-engaged-done) |
| `ng interactive-sessions` | list resumable interactive sessions (+ overview upsert) | [→](#ng-interactive-sessions) |
| `ng suppress-emit <id>` | operator-side manual emit-suppression of a comment | [→](#ng-suppress-emit) |
| `ng report-init <slug>` | create a frontmatter'd report skeleton | [→](#ng-report-init) |
| `ng report-check <path>` | validate a report against the schema | [→](#ng-report-check) |
| `ng fetch-asset <url>` | fetch a `user-attachments/...` URL via user PAT | [→](#ng-fetch-asset) |
| `ng dashboard get` | read the overview-issue dashboard middle | [→](#ng-dashboard-get) |
| `ng dashboard put` | splice + PATCH the dashboard middle | [→](#ng-dashboard-put) |
| `ng dashboard scaffold` | print the canonical dashboard section skeleton | [→](#ng-dashboard-scaffold) |
| `ng dashboard validate` | strict check: required sections present? | [→](#ng-dashboard-validate) |
| `ng nexus-identity` | render + upsert the auto-generated identity block | [→](#ng-nexus-identity) |
| `ng watcher-status` | heartbeat age + target + liveness | [→](#ng-watcher-status) |
| `ng log-action <agent>` | append a JSONL event to the action log | [→](#ng-log-action) |
| `ng mint-jwt` | print an App-level JWT (for `/app/*` endpoints) | [→](#ng-mint-jwt) |
| `ng lit search "<q>"` | content-relevance paper discovery (S2 + ASTA) | [→](#ng-lit) |
| `ng lit add <doi>` | fetch metadata + add a paper to the library | [→](#ng-lit) |
| `ng lit status` | keys / library / setup readiness | [→](#ng-lit) |

---

## Comment + issue triage

### `ng process`

Eyes-react on a user-authored comment and print its body. The unified
"surface a comment for the agent" verb.

**Usage**

```
ng process <comment-id> [--repo <owner>/<name>]
```

**Behaviour**

1. Fetch comment metadata from `/repos/$REPO/issues/comments/<id>`.
2. Verify the comment author matches `github.user_login` — refuse
   otherwise (security boundary).
3. Verify the comment is not already marked processed (no `rocket`,
   no non-self `eyes`).
4. POST an `eyes` reaction (bot identity).
5. Cache `<id>` in `monitor/.state/processed-comments.txt` so the
   watcher suppresses the comment during GitHub's propagation lag.
6. Print:

   ```
   issue=<n>
   author=<login>
   body<<EOF
   …body…
   EOF
   ```

**Exit codes** — `0` on success; `1` if the comment doesn't exist,
isn't authored by the configured user, or is already marked processed.

**Example**

```bash
monitor/ng process 4272693242
```

### `ng process-issue`

Same as [`ng process`](#ng-process) but for an issue itself (not one
of its comments).

**Usage**

```
ng process-issue <issue-number> [--repo <owner>/<name>]
```

**Behaviour** — mirrors `ng process`, reading `/repos/$REPO/issues/<n>`
and acting on the issue's own reactions. Caches under `issue:<n>` in
the propagation-lag file.

### `ng react`

React on a comment (no eligibility check; for explicit closing actions).

**Usage**

```
ng react <comment-id> <eyes|rocket> [--repo <owner>/<name>]
```

**Behaviour** — POST the reaction to
`/repos/$REPO/issues/comments/<id>/reactions`. Cache the comment-id
under the processed-comments file (both `eyes` and `rocket` count as
processed markers; the watcher elides them on subsequent polls).

**Example**

```bash
monitor/ng react 4272693242 rocket
```

### `ng react-issue`

Issue-level analogue of [`ng react`](#ng-react).

**Usage**

```
ng react-issue <issue-number> <eyes|rocket> [--repo <owner>/<name>]
```

### `ng show`

Read-only comment fetch. Bypasses the
[`ng process`](#ng-process) eligibility filter so agents can quote
prior bot-authored output in their replies — the security boundary
is in the *processing* path, not the read path.

**Usage**

```
ng show <comment-id> [--repo <owner>/<name>]
```

**Output** — comment body, raw.

---

## Replies and closes

### `ng reply`

Post a comment on an issue or PR.

**Usage**

```
ng reply <issue-or-pr> [--repo <owner>/<name>] [--body-file <path>]
```

Body comes from `--body-file` or stdin. Prints the new comment URL.

**Examples**

```bash
echo "done — see follow-up issue" | monitor/ng reply 7
monitor/ng reply 7 --body-file response.md
monitor/ng reply 42 --repo <your-org>/nexus-code --body-file response.md
```

### `ng close`

Optionally post a comment and then close an issue.

**Usage**

```
ng close <issue> [--comment <text>]
```

Prints `CLOSED` on success.

**Example**

```bash
monitor/ng close 12 --comment "shipped in linked PR"
```

---

## Issues

### `ng issue`

Dispatcher for the issue namespace. A bare numeric argument falls
through to [`ng issue view`](#ng-issue-view).

**Usage**

```
ng issue <n>                             # numeric → view
ng issue create  …                       # see below
ng issue comment <n> …                   # see below
ng issue close   <n> …                   # delegate to ng close
ng issue view    <n> …                   # see below
```

### `ng issue view`

One-line issue summary, with optional body and comment expansion.

**Usage**

```
ng issue <n> [--repo <owner>/<name>] [--with-body] [--with-comments]
```

**Output**

```
#<n> state=OPEN|CLOSED title=<title>
```

`--with-body` appends `--- body ---\n<body>`.
`--with-comments` appends a chronological dump of every comment with
its `[created_at] <author>:` header.

**Example**

```bash
monitor/ng issue 1 --with-body --with-comments
```

### `ng issue create`

Open a new issue under the bot account. Body required (file or stdin).

**Usage**

```
ng issue create --title <t> [--body-file <path>] [--label <l>]... [--repo <owner>/<name>]
```

Prints the new issue's HTML URL.

**Examples**

```bash
monitor/ng issue create --title "tracking: follow-up" --body-file b.md
monitor/ng issue create --title bug --body-file b.md --label bug --label triage
```

### `ng issue comment`

Alias of [`ng reply`](#ng-reply) under the issue namespace, kept for
discoverability.

**Usage**

```
ng issue comment <n> [--repo <owner>/<name>] [--body-file <path>]
```

---

## Pull requests

### `ng pr create`

Open a PR. Body required (file or stdin). The branch must already be
pushed to `origin`; this is pure API and does not push for you.

**Usage**

```
ng pr create --head <branch> [--base main] --title <t>
             [--body-file <path>] [--repo <owner>/<name>]
             [--reviewer <login> | --no-reviewer]
```

**Reviewer behaviour** — bot-opened PRs auto-request review from
`github.user_login`. GitHub mutes notifications for actions taken by
the recipient's account, so without this the dashboard surface goes
cold for any repo missing `CODEOWNERS`. Opt-out with `--no-reviewer`;
override with `--reviewer <other-login>`.

**Cross-repo PRs** — when `--repo` targets a non-nexus repo, the verb
runs [`ng preflight`](#ng-preflight) first so a missing bot install
fails with a clear remediation instead of the GraphQL
"Resource not accessible by integration" error.

Prints the new PR's HTML URL.

**Example**

```bash
git push -u origin <your-handle>/<branch>
monitor/ng pr create \
    --head <your-handle>/<branch> \
    --title "docs: reference — config and ng CLI" \
    --body-file pr-body.md \
    --repo <your-org>/nexus-code
```

### `ng pr edit`

Patch a PR title and/or body.

**Usage**

```
ng pr edit <n> [--title <t>] [--body-file <path>] [--repo <owner>/<name>]
```

At least one of `--title` / `--body-file` is required. Prints the
PR's HTML URL.

### `ng pr merge`

Merge a PR via REST. Prints the merge commit SHA.

**Usage**

```
ng pr merge <n> [--squash|--merge|--rebase] [--delete-branch] [--repo <owner>/<name>]
```

Default merge method is `--squash`. `--delete-branch` removes the
head ref after a successful merge (logs a warning if the branch is
already gone).

### `ng pr view`

One-line PR summary.

**Usage**

```
ng pr view <n> [--repo <owner>/<name>]
```

**Output**

```
#<n> state=OPEN author=<login> <head>-><base> title=<title>
```

---

## Repo introspection

### `ng preflight`

Check whether the bot's installation can write to a given repo.

**Usage**

```
ng preflight <owner>/<name>
```

**Exit codes** — `0` yes, `1` no (with a remediation line on stdout
naming the bot and the target).

**Why** — cross-repo PR/issue verbs would otherwise surface a
confusing GraphQL "Resource not accessible by integration" error.
This turns that into one explicit yes/no line front-loaded.

**Example**

```bash
monitor/ng preflight <your-org>/sibling-repo
# → bot installed: yes (<your-org>/sibling-repo)
# or: bot installed: NO — ask org admin to install <bot-name> on <your-org>/sibling-repo
```

---

## Asset upload

### `ng upload`

Push a local file to the asset repo and print a browser-renderable
URL pinned to the resulting commit SHA. Thin wrapper around
`monitor/upload-asset.sh`.

**Usage**

```
ng upload <local-path>
          [--issue N]
          [--repo-path <path>]
          [--shape pin|latest]
          [--message <msg>]
```

**URL shapes**

- Images, PDFs, CSVs, …: `https://github.com/<asset-repo>/raw/<sha>/<path>`
  — embed-friendly, redirects to a viewer-session-bound signed CDN URL
  so `![alt](…)` renders inline even on private repos.
- Markdown (`.md`) / Jupyter (`.ipynb`):
  `https://github.com/<asset-repo>/blob/<sha>/<path>` — GitHub renders
  the content as a page.

`--shape pin` (default) pins to the commit SHA — permalinks survive
overwrites. `--shape latest` emits `…/main/<path>` for a "latest"
link.

**Asset tree layout** under the asset repo root:

| Path | When |
|---|---|
| `assets/<issue-N>/<basename>` | `--issue N` is passed |
| `assets/reports/<basename>` | uploading from `reports/` |
| `assets/general/<basename>` | everything else |
| `<free-form>` | `--repo-path <path>` overrides the default placement |

**Defaults**

- `--repo` — from `github.asset_repo`, falling back to `github.repo`.
  Env override: `NEXUS_ASSET_REPO`. Branch: `main` (env override:
  `NEXUS_ASSET_BRANCH`).
- `--message` — `"Add asset <basename> via upload-asset.sh"`.

**Exit codes** — `0` URL on stdout; `1` bad usage; `2`
`mint-token.sh` failed; `3` asset-repo clone/pull/push failed.

**Example**

```bash
monitor/ng upload diagram.png --issue 13
# → https://github.com/<your-org>/<your-instance>-nexus-assets/raw/<sha>/assets/13/diagram.png
```

---

## Reports and wrap-up

These three verbs form the canonical hand-off flow. See
[Reports](../operating/reports.md) for the workflow narrative.

### `ng report-init`

Create a frontmatter'd report skeleton at the canonical path. Captures
session-id + tmux window automatically.

**Usage**

```
ng report-init <slug>
              [--project <name>]
              [--issue <n>]
              [--comment-id <id>]
              [--reports-dir <path>]
```

**Path shape**

```
<reports-dir>/<project>_<YYYY-MM-DD>_<HHMMSS>_<slug>.md
```

**Resolution order**

- `<project>` — `--project`, else the `work/<project>` parent if cwd
  is under one, else the literal `nexus`.
- `<reports-dir>` — `--reports-dir`, else `$NEXUS_ROOT/reports` if
  the dir exists, else the nearest `reports/` walking up from cwd,
  else `pwd/reports`.
- `<session-id>` — `$CLAUDE_PROJECT_DIR/sessions/current_session_id`
  if set; else the most recently modified jsonl under
  `~/.claude/projects/<slugified-cwd>/`; else the empty string (the
  caller substitutes `"unknown"`, which `ng report-check` then
  rejects).
- `<tmux window>` — `tmux display-message -t $TMUX_PANE '#{window_name}'`
  if inside tmux; empty otherwise.

**Output** — absolute path of the new file on stdout.

**Example**

```bash
report=$(monitor/ng report-init docs-w4-config-cli --issue 1)
$EDITOR "$report"
```

### `ng report-check`

Validate a report against the schema enforced by
[`ng wrap-up`](#ng-wrap-up).

**Usage**

```
ng report-check <path> [--allow-todo]
```

**Schema** — defined in the `nexus.report` skill; this verb is the
machine check:

- Frontmatter delimited by `---` lines, with required fields
  `project`, `date`, `session-id`, `status`.
- `session-id` must not be literal `"unknown"` (the capture
  heuristics failed; resume becomes impossible).
- `status` ∈ {`completed`, `partial`, `blocked`}.
- All five canonical sections present: `## Summary`,
  `## What Was Done`, `## Current State`, `## What Remains`,
  `## How to Resume`.
- Body length ≥ [`monitor.report_min_chars`](config.md#monitorreport_min_chars)
  (default 500), counting everything after the frontmatter.
- No literal `TODO`, `FIXME`, `<...>`, `_(fill in)_`, or
  `_(later)_` placeholder text. `--allow-todo` bypasses these last
  four checks for intentional in-progress checkpoints.

**Exit codes**

| Code | Meaning |
|---|---|
| `0` | Report is complete |
| `1` | Incomplete (specifics on stderr) |
| `2` | File missing or unreadable |

**Example**

```bash
monitor/ng report-check reports/nexus_2026-05-11_142233_docs-w4.md
# → report-check: nexus_2026-05-11_142233_docs-w4.md OK (3247 body chars)
```

### `ng wrap-up`

End-of-task hand-off folded into one verb.

**Usage**

```
ng wrap-up <issue> <report-path>
          [--trigger-comment <id>]
          [--repo <owner>/<name>]
          [--trigger-repo <owner>/<name>]
          [--comment-body-file <path> | --no-comment]
          [--allow-stub]
          [--retain <reason> | --no-retain]
          [--skeptic-decision require|deny] [--skeptic-rationale <text>]
          [--skeptic-waive <reason>]
          [--skeptic-role] [--skeptic-verdict credible|check|suspect|refuted]
          [--skeptic-target <window>] [--skeptic-depth <n>]
          [--skeptic-findings <n>] [--skeptic-orig <window>]
```

**Steps**

0. **Pre-flight `ng report-check`** — refuse stubs (`--allow-stub`
   forwards `--allow-todo` to the check for intentional in-progress
   checkpoints).
0b. **Skeptic gate** (`skills/nexus.skeptic`). Runs *before* the
   GitHub hand-off, so a refused wrap-up never announces "done" on the
   issue or rockets the trigger. The verb reads the worker's
   spawn-stamped skeptic mode (`require` / `auto` / `deny`) from
   `monitor/.state/windows/<window>.json` and acts on it. The gate can
   **refuse the whole wrap-up** (return non-zero before any
   upload/comment/rocket/log) when:
   - an `auto`-mode worker reaches wrap-up **undecided** and
     `monitor.skeptic.enforce_auto_decision` is on — record a choice
     with `--skeptic-decision require|deny --skeptic-rationale "<why>"`;
   - a `require`-mode worker tries `--skeptic-decision deny` (the
     requirement is mandatory; only an operator may release it);
   - `--skeptic-waive` is attempted from inside a worker context
     (`NEXUS_WORKER_WINDOW` set) — the waive is an operator override only;
   - `--skeptic-role` is passed without a valid `--skeptic-verdict`.

   On `require` (or an auto-mode `--skeptic-decision require`), the gate
   sets a skeptic-pending marker and prints the await-loop guidance; the
   window then cannot retire until a skeptic returns a verdict
   (`retire-preflight.sh` enforces the marker). `--skeptic-role` marks a
   skeptic's *own* wrap-up: it logs the `--skeptic-verdict` and applies
   bounded recursion (`--skeptic-depth` / `--skeptic-findings`, chain
   root via `--skeptic-orig`). `--skeptic-waive` is the operator override
   that releases a required skeptic.
1. **Upload the report** via `monitor/upload-asset.sh` →
   `assets/<issue>/<basename>` on the asset repo.
2. **Post the link comment** on `<issue>` in `--repo`:
   - `--comment-body-file <path>` supplies the prose. `{{REPORT_URL}}`
     is substituted with the SHA-pinned asset URL; if no token is
     present, a `Full report: <URL>` footer is appended.
   - `--no-comment` skips this step (caller will `ng reply` later).
   - Default: a templated body built from the report's H1 + Summary.
3. **Rocket-react the trigger comment** on `--trigger-repo` (defaults
   to `--repo`) if `--trigger-comment <id>` is supplied.
4. **Append a wrap-up event** to `monitor/.state/action-log.jsonl`
   with per-step status, asset URL, comment URL, repo, trigger-repo,
   and source tmux window.
5. **Auto-retain the source window** — ON BY DEFAULT. A successful
   wrap-up logs a `window-retain` event for the source tmux window so
   the watcher's idle-worker probe suppresses the wrapped row into a
   footer for `monitor.retain_ttl_seconds` (default 24 h). The auto-tag
   is `wrap-up-<YYYY-MM-DD>`. Pass `--retain <reason>` for a custom tag,
   or `--no-retain` to close-immediately (a short-lived helper that is
   truly done, or a context-pressure wrap-up that won't be resumed).
   `--retain` and `--no-retain` are mutually exclusive. Step 5 is
   silently skipped when wrap-up runs outside the worker's tmux pane
   (no source window to retain), and a retain-logging failure does
   **not** flip the exit code — the hand-off already succeeded.

**Exit code** — `0` only if every attempted step succeeded. On
partial failure the verb still attempts every reachable step (rocket
and log-action do not depend on the upload), then emits a structured
stderr report naming which steps ok/failed so the caller can retry
just the failed ones.

**Cross-repo trigger** — pass `--trigger-repo` when the trigger
comment lives in a different repo from the issue thread (e.g. a
worker on a `nexus-code` clone wrapping up against
`<your-instance>-nexus-assets#1` with the trigger comment on
`nexus-code#4`).

**Stdout** — one machine-readable line per step:

```
uploaded: <asset-url>
posted comment: <comment-url>
rocketed comment <id>
logged action: wrap-up issue=<n> report=<basename>
retained window: <window> (reason=<tag>; ttl=monitor.retain_ttl_seconds)
```

The `retained window:` line prints only when step 5 ran (in-pane,
`--no-retain` not passed). When the source window carries a live
operator-engagement mark, a trailing note explains that the wrap-up
does **not** release the window — see [`ng engaged-done`](#ng-engaged-done)
to signal the finished state.

**Example**

```bash
monitor/ng wrap-up 1 reports/nexus_2026-05-11_142233_docs-w4.md \
    --trigger-comment 4422219722 \
    --repo <your-org>/<your-instance>-nexus-assets \
    --trigger-repo <your-org>/nexus-code \
    --comment-body-file wrap-up-comment.md
```

---

## Worker lifecycle

Window-lifecycle verbs the orchestrator uses to validate, recover, and
classify worker windows, plus the worker↔skeptic comms channel. See
[`skills/nexus.window-cleanup`](skills.md), [`skills/nexus.skeptic`](skills.md),
and [`skills/nexus.tmux-spawn`](skills.md) for the policies these
implement.

### `ng wrap-up-check`

Verify a worker has met every wrap-up obligation **before** the
orchestrator closes its window. Independent of [`ng wrap-up`](#ng-wrap-up)'s
own Step 0 pre-flight (which fires before the worker has uploaded
anything); this checks the *post*-conditions.

**Usage**

```
ng wrap-up-check <window>
```

**Checks**

1. The action log carries a `wrap-up` event for `<window>` in the
   current lifecycle (its `ts` is newer than the window's most-recent
   `spawn` event).
2. The cited report exists on disk (under `$NEXUS_ROOT/reports/` or
   `reports/`) and passes [`ng report-check`](#ng-report-check).
3. The trigger comment was rocketed, or the rocket step was skipped at
   wrap-up time (both pass; only a `failed` rocket flips to missing).

**Output**

```
status=<ok|incomplete> wrap_up=<present|missing> report_check=<ok|fail|missing> rocket=<ok|skipped|missing>
```

**Exit codes**

| Code | Meaning |
|---|---|
| `0` | `status=ok` — safe to close |
| `1` | `status=incomplete` — at least one obligation missing; do NOT close yet |

### `ng skeptic`

Thin delegator to `monitor/skeptic-channel.sh`, the worker↔skeptic
comms channel and nudge. Gives the skeptic protocol a discoverable home
on the `ng` surface; every argument is forwarded verbatim, and the exit
codes are the channel's own.

**Usage**

```
ng skeptic <ask|await|answer|await-answer|reconcile|close|poll|status|list|nudge|init|dir> ...
```

**Subcommands**

| Sub | Who runs it | What it does |
|---|---|---|
| `ask <task> <slug> …` | skeptic | write a request (`<slug>.open.md`) |
| `await <task>` | worker | block for `*.open.md`, ack each (→`.ack.md`), exit `0`; `DONE` sentinel → exit `10`; timeout → exit `4` |
| `answer <task> <req> …` | worker | reply to a request (→`.answered.md`) |
| `await-answer <task> <req> …` | skeptic | block for the worker's answer |
| `reconcile <task> …` | skeptic | ensure every open request was acked |
| `close <task>` | skeptic | drop the `DONE` sentinel that ends the worker's await loop |
| `poll \| status \| list <task>` | either | inspect channel state (open/ack/answered) |
| `nudge <window> …` | orchestrator/skeptic | wake an idle worker |
| `init \| dir <task>` | either | create / print the channel directory |

The rename is the signal at every step. Run `ng skeptic --help` for the
full surface and exit-code contract.

### `ng respawn`

Resume a wrapped or closed worker's Claude Code session in a fresh
tmux window with full spawn parity (env exports, worker-settings hooks,
window options, lifecycle anchors). Thin wrapper over
`monitor/spawn-worker.sh --resume`.

**Usage**

```
ng respawn <window | session-id>
           [--window <name>]
           [--workdir <path>]
           [--replace]
           [--nudge | --no-nudge]
           [--dry-run]
```

Pass a tmux window name (the common case) or a session-id UUID. The
session-id and workdir auto-resolve from the report frontmatter, the
action log, or `~/.claude/projects/`; pass a UUID positionally with
`--window` to override resolution. `--replace` reuses an existing
window of the same name; `--dry-run` prints the resolved spawn command
without launching. A worker whose last heartbeat was mid-turn (busy)
gets a continuation prompt automatically — `claude --resume` alone does
not restart an interrupted turn; `--nudge` / `--no-nudge` force or
suppress that.

**Why not hand-roll it** — never `tmux new-window … claude --resume`
directly: that loses the `NEXUS_ROOT` / `NEXUS_WORKER_WINDOW` exports
and every worker hook breaks.

### `ng spawn-decision`

Advisory continue-vs-spawn classifier for a retained worker window.
Inspects the window's pane state, its most-recent `spawn` and
`window-retain` action-log timestamps, and the retain TTL, then emits a
recommendation. Mirrors the policy in
[`skills/nexus.window-cleanup`](skills.md) (Continue-vs-spawn). Always
advisory — the orchestrator decides what to do with the advice.

**Usage**

```
ng spawn-decision <window> [--topic <slug>]
```

`--topic` names the topic of the prospective new task; when omitted the
helper assumes topic-match (the caller already decided the routing
applies to this window).

**Output**

```
decision=<continue|spawn|ambiguous> reason=<short> pane_state=<state> retain_age_s=<n|none> spawn_age_s=<n|none>
```

**Exit codes**

| Code | Meaning |
|---|---|
| `0` | a decision was rendered (any class) |
| `1` | window unknown to tmux / classifier couldn't run |

### `ng engaged-done`

The interactive session's explicit FINISHED-signal. A wrap-up from an
operator-engaged window keeps the window engaged by default (follow-up
inquiries are expected), so it does not follow the typical
wrapped-window cleanup. This verb appends the `engaged-done` event that
invalidates the engagement mark, dropping the window back onto the
normal retain-footer → retire-eligibility path. A later operator prompt
re-engages — the release is never a lock-out.

**Usage**

```
ng engaged-done [--window <name>]
```

Window resolution mirrors wrap-up's: the calling pane's tmux window via
`$TMUX_PANE`; pass `--window` when invoking from outside the pane.

### `ng interactive-sessions`

Enumerate recently paused or closed interactive windows from their
provenance records (`monitor/.state/windows/<window>.json`, written by
`spawn-worker.sh --kind interactive`) and render a markdown "Resumable
Interactive Sessions" table with per-session resume commands. The block
is bounded by HTML-comment delimiters and idempotently upserted into
the overview issue body on `--upsert-overview` (bot identity, REST
PATCH), so repeated runs replace it in place.

**Usage**

```
ng interactive-sessions [--limit N] [--days D] [--upsert-overview] [--dry-run]
```

- `--limit N` — include at most N sessions (default 20).
- `--days D` — only sessions active within the last D days (default 30).
- `--upsert-overview` — PATCH the rendered block into the overview issue.
- `--dry-run` — print the block; skip the GitHub PATCH.

**Exit codes** — `0` on success (rendered, and patched when
`--upsert-overview` without `--dry-run`); `1` if a write failed.

---

## User-attachments fetch

### `ng fetch-asset`

Download a `github.com/user-attachments/...` URL via the **user's**
PAT (the bot's installation token returns 404 silently on this
surface; user-OAuth credentials are required). Both URL forms are
accepted: `user-attachments/assets/<uuid>` (pasted images) and
`user-attachments/files/<id>/<name>` (uploaded file attachments).

**Usage**

```
ng fetch-asset <user-attachments URL> [--out <path>] [--image-only]
```

**Why it exists** — when the user pastes an image into a GitHub
comment, the link is `https://github.com/user-attachments/assets/<uuid>`.
Pointing a sub-agent or the Read tool at that URL produces a 404
followed by a 400 from the image fetcher, which **silently disables
every subsequent image fetch in the conversation**. This verb is the
workaround: read the user's `gh auth token` PAT (NOT the bot's
installation token — bot tokens 404 silently), follow the 302 from
`github.com/user-attachments/...` to the 5-minute signed S3 URL, and
write the bytes to disk. The agent then reads the local file.

**Defaults**

- `--out` — `monitor/.state/assets/<asset-id>.<ext>` (extension
  inferred from response `Content-Type`).
- `--image-only` — refuses non-image content types (exit 4).

**Output** — three lines on stdout:

```
path=<absolute-path>
content_type=<mime>
bytes=<size>
```

**Exit codes**

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | User input error (not a user-attachments URL, missing arg, unknown flag) |
| `2` | Auth failure (`gh auth token` empty, or PAT rejected at stage 1) |
| `3` | Fetch failure (stage 1 missing `Location`, stage 2 non-200, network) |
| `4` | `--image-only` set and content-type is not `image/*` |

**Example**

```bash
monitor/ng fetch-asset \
    https://github.com/user-attachments/assets/01234567-89ab-cdef-0123-456789abcdef \
    --image-only
# → path=/.../monitor/.state/assets/01234567-89ab-cdef-0123-456789abcdef.png
#    content_type=image/png
#    bytes=84219
```

---

## Dashboard

### `ng dashboard get`

Fetch the overview-issue dashboard middle. Caches to
`monitor/.state/dashboard.md`.

**Usage**

```
ng dashboard get
```

**Output** — the content between the `<!-- NEXUS_DASHBOARD_START -->`
and `<!-- NEXUS_DASHBOARD_END -->` markers in the overview issue's
body.

**Overview-issue resolution** — three layers of robustness against
the GitHub labelled-issue index's eventual consistency:

1. `github.overview_issue_number` in `config/nexus.yml` if set —
   skip the lookup entirely.
2. Per-process cache at `monitor/.state/overview-number`.
3. Live API call with 3 attempts (1 s + 2 s backoff) when the label
   index returns `[]` transiently.

### `ng dashboard put`

Splice a new middle into the overview issue's body and PATCH.

**Usage**

```
ng dashboard put --body-file <path>
```

**Behaviour**

1. Read the new middle from `--body-file` (refuse if empty).
2. Fetch the overview body; refuse if the `<!-- NEXUS_DASHBOARD_START -->`
   / `<!-- NEXUS_DASHBOARD_END -->` markers are missing.
3. Replace the middle between the markers (header + footer
   preserved), PATCH the issue body.
4. Cache the new middle to `monitor/.state/dashboard.md` and write
   `monitor/.state/dashboard-updated.ts` (the freshness timestamp
   the watcher reads).

Prints the overview issue's HTML URL.

`put` runs the section-schema check in **warn-only** mode: if the body
is missing any required section (see
[`ng dashboard validate`](#ng-dashboard-validate)) it prints the gaps
to stderr but still PATCHes — the operator must never be blocked from
updating the dashboard in a hurry.

### `ng dashboard scaffold`

Print the canonical dashboard skeleton: the six required H2 sections,
each with a one-line hint. Seed a new dashboard by piping into
`dashboard put`.

**Usage**

```
ng dashboard scaffold | ng dashboard put --body-file /dev/stdin
```

The sections — the single source of truth is `DASH_REQUIRED_SECTIONS`
in `monitor/ng`:

| Section | Populated by |
|---------|--------------|
| `## Identity` | pointer to the `ng nexus-identity` block (never a copy) |
| `## Infra` | operator-narrated: watcher / orchestrator / CC-pin health |
| `## Services` | auto-populatable from `monitor/services.registry` |
| `## In-flight` | active worker windows |
| `## Awaiting operator` | threads/decisions blocked on the operator |
| `## Recent landings` | last few merged PRs / completed tasks |

### `ng dashboard validate`

Strict schema gate: exit `0` if every required section heading is
present, exit `1` (listing the missing ones on stderr) otherwise. The
hard-failure counterpart to `put`'s warn-only check — use it for CI,
pre-commit, or a deliberate conformance check.

**Usage**

```
ng dashboard validate --body-file <path>     # or pipe via stdin
```

---

## Identity

### `ng nexus-identity`

Render the auto-generated **Nexus identity** block — the working
directory front and centre — and idempotently upsert it into the
overview issue body between `<!-- nexus-identity:start -->` /
`<!-- nexus-identity:end -->`. The point is auto-generation: every
field is DERIVED from this nexus's own environment/config, so a second
operator running the same code gets their own correct block with zero
edits, and repeated runs replace the block in place (no drift, no
duplication) — the same upsert pattern as the dashboard markers.

**Usage**

```
ng nexus-identity --dry-run            # render to stdout, no GitHub write
ng nexus-identity --upsert-overview    # PATCH the block into the overview issue
ng nexus-identity --upsert-overview --repo <owner/name>
```

**Derived fields** (nothing hardcodes one operator):

| Field | Source |
|-------|--------|
| **Working directory** (headline) | `$NEXUS_ROOT`, else script-relative root |
| Host | `hostname` |
| Asset + issue repo | `github.repo` + overview issue number |
| Implementation clone | the nexus root's git `origin` remote + current branch |
| Watcher pidfile / log | `<root>/monitor/.state/watcher.{pid,log}` |

It is **identity, not status** — a stable "where things live" record.
Live status is the [dashboard](#dashboard)'s job. See the
[`nexus.dashboard`](skills.md) skill for the cross-nexus convention.

`--dry-run` renders without the PATCH (use it to preview the block).
The GitHub write uses the bot identity (installation token, REST
PATCH).

---

## Watcher + audit

### `ng watcher-status`

One-shot watcher liveness report.

**Usage**

```
ng watcher-status [--scheduler]
```

`--scheduler` appends a per-task v2 scheduler summary read from
`monitor/.state/watcher-scheduler.jsonl` — one line per task
(`compose_emit`, `snapshot_local`, `deliveries_poll`, `github_poll`, …)
with its most recent `phase`, `rc`, `elapsed_ms`, and the ISO `ts` of
that fire. The cron-supervisor passes it to verify v2-migration
completeness; a missing JSONL prints `scheduler: telemetry absent`.

**Output** — a key=value block (human-friendly, also easy to grep):

```
heartbeat: <ISO ts> (age=<s>s)        # or "missing"
pid: <pid> (alive|DEAD|unknown)
target: <window-name>
lock: pid=<pid> started=<ts>          # or "absent"
instance-lock: held|free|absent       # state-dir-scoped flock singleton
hosting: headless                     # or "legacy tmux window 'watcher' present (headless expected)"
archived_diffs: <n>
```

`instance-lock:` reports the state-dir-scoped `flock` singleton — the
cross-sandbox / cross-host guard the pid `lock:` can't provide. `held`
appends an assessment + host/pid/started detail (a stale lock whose
recorded host rebooted is flagged); `free` means stale metadata is
present and will be reclaimed on next start; `absent` means no lock
file. Full inspection: `monitor/watcher/launcher.sh --instance-status`.

**Exit codes** (from `_watcher_alive` in `monitor/watcher/_lib.sh`,
shared with the bootstrap script so the two paths can't drift —
the watcher is headless, so the buckets are pid identity +
heartbeat age, no window check):

| Code | Meaning |
|---|---|
| `0` | Fresh: heartbeat age ≤ `2× + slack` of `monitor.interval_seconds`, pid identity-validated alive |
| `1` | Stale: heartbeat age within `(2× + slack, 5×]` of `monitor.interval_seconds` |
| `2` | Very stale (> 5×), or heartbeat pid dead / recycled to a non-watcher process |
| `3` | No heartbeat file |

### `ng log-action`

Append one line to `monitor/.state/action-log.jsonl`. Used by
[`ng wrap-up`](#ng-wrap-up) and by agents recording orchestration
events.

**Usage**

```
ng log-action <agent> --event <name> [--note <text>] [--extra k=v]...
```

**Line shape** — JSONL with `ts`, `agent`, `event`, optional `note`,
plus any `--extra k=v` pairs folded in as additional string fields.
Values are preserved as strings; pass quoted JSON in `--extra` when
you need structure.

**Example**

```bash
monitor/ng log-action orchestrator \
    --event window-closed \
    --note "wrapped + idle > 20m" \
    --extra window=docs-w4-config-cli \
    --extra reason=window-cleanup
```

### `ng service-incident`

Assemble a structured service incident report for a registered service
**from the recorded state** — the per-service files the watcher's
service-health task writes under `monitor/.state/service-health/`
(`<svc>.state` current-incident record + `<svc>.events` append-only
history), plus the service logfile. Machine facts (down→restored
timestamps, the failing healthcheck, each restart attempt + outcome,
the verbatim event timeline, a 40-line logfile tail) are filled from
the state so they can't drift from what actually happened; the
root-cause / how-to-undo sections are templated placeholders the
dispatched fix-worker completes. See
[`skills/nexus.service-recovery`](skills.md).

**Usage**

```
ng service-incident <svc> [--state-dir <path>]
```

`--state-dir` overrides the default `monitor/.state/service-health/`
lookup directory. The verb dies if neither `<svc>.state` nor
`<svc>.events` exists there (the name must be a registry service that
has had an incident).

**Output** — markdown to stdout with the required sections (Failure
report / Immediate response / Root-cause fix / References / Worker
report). Pipe it to `ng issue create`:

```bash
monitor/ng service-incident jupyter \
    | monitor/ng issue create --title "incident: jupyter down" --body-file -
```

### `ng suppress-emit`

Operator-side manual emit-suppression — the backup lever for when the
reactions/dedup filters fail to exclude a comment that re-surfaces
every poll cycle. Appends a `comment:<id>` line to
`monitor/.state/emit-suppression.lines`; `compose_emit`'s
`_filter_suppression` stage drops any matching `id=<N>` line from the
eligible-comments stream on the next compose tick.

**Usage**

```
ng suppress-emit <comment-id> [--repo <owner>/<name>] [--reason <short>]
```

The comment-id must be numeric. The file is append-only and persists
across watcher restarts (the operator clears entries by editing or
truncating it directly). A `monitor` action-log `emit-suppress` event
is recorded so the meta-review can see when and why the backup channel
was used; `--reason` is folded in as the event note, `--repo` as an
extra field. Prints `suppressed: comment:<id>` (or `already suppressed:
…` if the entry was present).

### `ng mint-jwt`

Print an App-level JWT (no installation-token exchange). Thin shim
over `monitor/mint-token.sh --jwt-only`.

**Usage**

```
ng mint-jwt
```

**Why** — `/app/*` endpoints (most importantly
`/app/hook/deliveries`, the App's webhook delivery log) authenticate
with the App-level JWT, not an installation token. Most agents will
never call this directly; the watcher's deliveries path uses it
internally.

---

## Literature research

### `ng lit`

Content-relevance literature discovery for scientific work, native to the
nexus (plain `curl` + `jq`; no `bip` install required). Backed by
`monitor/lit.sh`. Full reference, key acquisition, and the report-citation
convention: [Literature research](literature.md) and the
[`nexus.lit` skill](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.lit/SKILL.md).

```console
$ ng lit status                                          # readiness
$ ng lit search "<query>" [--source s2|asta|both] [--limit N] [--year A:B] [--human]
$ ng lit add <DOI|S2-id> [--human]                       # grow the library
$ ng lit setup                                           # key-acquisition refs
```

- **`search`** queries Semantic Scholar and ASTA by relevance, dedups
  against the reference library, and annotates each hit `in_library`. A
  backend with no key is **skipped with a note** (never a hang). Default
  output is JSON; `--human` is readable.
- **`add`** fetches a paper by DOI or S2 id and appends a schema-compatible
  record to the library (`<nexus.root>/.bipartite/refs.jsonl` by default, or
  `lit.library_path`). Dedup-checked by DOI.
- **`status` / `setup`** report configured backends (env / `config/nexus.yml`
  `lit.*` / legacy `bip` config — never the key itself) and, when nothing is
  configured, print key-acquisition references and exit non-zero.

---

## What about archived diffs?

Listing and dumping archived snapshot diffs is intentionally **not** a
subcommand. The archive under `monitor/.state/diffs/` is a directory
of sortable filenames; the bootstrap snippet that loads them does:

```bash
find monitor/.state/diffs -newer monitor/.state/last-ack.txt \
    -type f | sort | xargs -r cat
```

No CLI wrapper saves enough to justify the surface area.

---

## Maintenance burden

The verb list, exit codes, and flag semantics on this page mirror
`monitor/ng`'s own `--help` text and the per-verb code comments.
Whenever you add, rename, or remove a verb, or change a flag:

1. Update `monitor/ng`'s top-of-file usage block (canonical) and the
   per-verb function comment.
2. Update the section for the verb on this page and the
   [Quick reference](#quick-reference) table.

Drift between `ng --help` and this page is the failure mode to
watch. See [Development](../contributing/development.md).
