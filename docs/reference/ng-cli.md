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

- **Read verbs** (`issue view`, `pr view`, `show`,
  `stranded-branches`) prefer the cwd's `git remote get-url origin`
  if it is a `github.com` URL (with a one-line stderr warning when
  different from `$REPO`), else fall back to `$REPO`.
- **Write verbs** (`process`, `process-issue`, `react`,
  `react-issue`, `reply`, `comment`, `comment-edit`, `close`,
  `close-set`, `issue create`, `issue comment`,
  `pr create|edit|merge`, `wrap-up`, `interactive-sessions
  --upsert-overview`, `nexus-identity --upsert-overview`) prefer
  `$REPO` from config. If the cwd has a `github.com` origin that
  **differs** from `$REPO`, the verb refuses to write — closing the
  soon-to-be-public nexus-code leak risk — and emits a structured
  error asking for an explicit `--repo`.

Both rules live in one place, `_resolve_repo <read|write>` in
`monitor/ng`. **[`ng upload`](#ng-upload) is the exception and does
not use it**: its destination is the *asset* repo, resolved from
`github.asset_repo` with its own default-deny rules, and on that verb
`--repo` means something different. See its section.

**Body input** — verbs that POST a body (`reply`, `issue create`,
`issue comment`, `pr create`, `pr edit`) accept the body via
`--body-file <path>` or stdin. Pass long markdown in a file; piping
short replies via `echo "thanks" | ng reply 7` works too.

**Output discipline** — verbs print *just* their primary result
(URL, SHA, comment ID, …) on stdout. Stderr carries warnings and
errors. This makes pipelines (`url=$(ng pr create …)`) trivial.

**Exit codes** — `0` on success and `1` on the general refusal path
(`die`), plus **`64` = EX_USAGE for one specific condition: a flag
given no value, or an empty value where the flag's contract requires
one** (`_die_usage` / `_argloop_stuck`; `<your-org>/nexus-code#990`
aligned `ng` with the sixteen other scripts in this repo that already
used `64`). So `ng pr merge 42 --sha` and `ng pr merge 42 --sha ""`
both exit `64` rather than merging unpinned — a caller that branches
only on `1` will read that as success. Beyond those, verbs carry
their own codes, documented per verb (e.g.
[`ng wrap-up`](#ng-wrap-up) `3`,
[`ng fetch-asset`](#ng-fetch-asset) `4`,
[`ng upload`](#ng-upload) `4`/`7`,
[`ng report-check`](#ng-report-check) `2`,
[`ng watcher-status`](#ng-watcher-status) `0`–`4`).

## Quick reference

**This page is not the complete verb list — `ng verbs` is.** `ng`
dispatches **59** operational verbs; the sections below cover 35 of
them. The other 24 are mostly pass-through facades over a standalone
`monitor/*.sh` (whose own `--help` is the reference), plus narrow
state queries and aliases. `ng verbs` — the categorized index printed
by `ng --help` / `ng help` / `ng -h`, generated from `_verb_index` in
`monitor/ng` — gives each a one-liner. It is hand-maintained and
nothing asserts it against the dispatch table, so **11** of the 59
are currently missing from it (see [Maintenance
burden](#maintenance-burden)). **The table below is derived from the
dispatch table itself and covers every verb `ng` dispatches that is
not one of the 35 with its own section above — plus the handful whose
section is new, pointed at with `[→]`.** Most are a thin `exec` over
a standalone script that is the real reference; the right-hand column
says where to look.

| Verb | What it is | Reference |
|---|---|---|
| `ci-attempts <sha\|branch\|PR#>` | was this head green, and green on the *first* attempt? | `monitor/ci-head-attempts.sh`; [`nexus.ci-triage`](skills.md) |
| `close-set --bodies <dir> <issue>…` | bulk close with per-issue verification | [→](#ng-close-set) |
| `comment <n>` | alias of [`ng reply`](#ng-reply) | [→](#ng-reply) |
| `comment-edit <id>` | compare-and-swap edit of an existing comment | [→](#ng-comment-edit) |
| `declare-wait` / `declare-no-wait` | worker self-declares (or releases) an async external wait | `monitor/declare-wait.sh`, `monitor/declare-no-wait.sh` |
| `guards-for-diff` | which construct-keyed guards read the files you changed | [→](#ng-guards-for-diff) |
| `obligation <sub>` | the who-owes-whom ledger (`open\|settle\|note\|state\|show\|list\|gate\|pairs\|preserve-closures`) | `monitor/obligations.sh` |
| `pane-state <window>` | classify a worker pane | `monitor/pane-state.sh`; [Worker states](worker-states.md) |
| `paste-followup <window>` | the canonical follow-up paste into a window | `monitor/paste-followup.sh`; [`nexus.tmux-spawn`](skills.md) |
| `remote <sub>` | confined remote SSH endpoint | `monitor/remote-enroll.sh`; [`nexus.remote-access`](skills.md) |
| `report-grep <pattern>` | ignore-file-blind search of the reports corpus | [→](#ng-report-grep) |
| `reports-for-window <window>` | which reports name this window | `monitor/ng`; [`nexus.report`](skills.md) |
| `reports-roll [--dry-run]` | archive pre-buffer reports into `reports/YYYY-MM/` | `monitor/reports-roll.sh` |
| `request <sub>` | worker→orchestrator request inbox (`file\|await\|fetch\|show\|reqfile\|dir\|list\|reply\|ack\|fail`) | `monitor/request-channel.sh` |
| `retire-preflight <window>` | synchronous go/no-go gate before a kill | `monitor/retire-preflight.sh`; [`nexus.window-cleanup`](skills.md) |
| `retire-window <window>` | preflight + kill + prune every state surface + verify | `monitor/ng`; [`nexus.window-cleanup`](skills.md) |
| `send <agent> …` | harness-neutral agent delivery with a receipt | `monitor/send.sh`; [`nexus.agent-delivery`](skills.md) |
| `session-id <window>` | the Claude Code session-id behind a window | `monitor/window-session-id.sh` |
| `skeptic-arm` · `skeptic-disposition` · `skeptic-evidence` · `skeptic-obligations` · `skeptic-orphans` | the skeptic **bookkeeping** verbs (distinct from the `ng skeptic` channel) | [→](#skeptic-bookkeeping-verbs) |
| `stranded-branches` | pushed branches that never got a PR | [→](#ng-stranded-branches) |
| `token` / `user-pat` | print the bot installation token / the user PAT | `monitor/mint-token.sh`, `monitor/user-pat.sh` |
| `usage [--json]` | which `ng` mechanisms are used, how often, what is cold | `monitor/usage-report.py` |
| `write-probe <path>` | pre-flight that a deliverable path is writable | `monitor/write-probe.sh` |

Most verbs also answer `ng <verb> --help` with their own usage line
(`_usage_for` in `monitor/ng`, or — for a facade — the target
script's own usage). `monitor/watcher/test-ng-usage-flag-coverage.sh`
is a **ratchet** over that: it fails CI on any *new* flag the parser
accepts but the usage line omits, and equally when a recorded known
drift is fixed and left in its manifest, so that gap can only shrink.
It makes the per-verb `--help` the *flag* surface least able to
drift. It does **not** guarantee the verb has a `--help` at all:
measured at `a3177ef6`, `ng skeptic-arm --help` and
`ng skeptic-obligations --help` die `unknown flag`, and
`ng skeptic-disposition --help` prints the whole file header instead
of a usage line.

| Verb | One-line | Section |
|---|---|---|
| `ng process <id>` | eyes-react + fetch body for a user comment | [→](#ng-process) |
| `ng process-issue <n>` | eyes-react + fetch body for a user issue | [→](#ng-process-issue) |
| `ng react <id> <kind>` | post a reaction on a comment | [→](#ng-react) |
| `ng react-issue <n> <kind>` | post a reaction on an issue | [→](#ng-react-issue) |
| `ng show <id>` | read a comment body (no eligibility filter) | [→](#ng-show) |
| `ng reply <n>` | post a comment on an issue/PR | [→](#ng-reply) |
| `ng close <n>` | close an issue, optionally with a comment | [→](#ng-close) |
| `ng comment-edit <id>` | compare-and-swap edit of an existing comment | [→](#ng-comment-edit) |
| `ng close-set <issue>…` | bulk close with per-issue verification | [→](#ng-close-set) |
| `ng issue <n>` | view issue (one-liner; flags expand) | [→](#ng-issue) |
| `ng issue create` | open a new issue | [→](#ng-issue-create) |
| `ng issue comment <n>` | alias of `ng reply` under `issue` namespace | [→](#ng-issue-comment) |
| `ng pr create` | open a PR with auto-requested reviewer | [→](#ng-pr-create) |
| `ng pr edit <n>` | patch a PR title or body | [→](#ng-pr-edit) |
| `ng pr merge <n>` | merge a PR via REST | [→](#ng-pr-merge) |
| `ng pr view <n>` | one-line PR summary | [→](#ng-pr-view) |
| `ng preflight <repo>` | is the bot installed on this repo? | [→](#ng-preflight) |
| `ng stranded-branches` | pushed branches that never got a PR | [→](#ng-stranded-branches) |
| `ng guards-for-diff` | which guards read the files you changed (pre-push) | [→](#ng-guards-for-diff) |
| `ng upload <file>` | push asset to asset repo, print pinned URL | [→](#ng-upload) |
| `ng wrap-up <n> <report>` | end-of-task hand-off (upload + comment + rocket + log + retain) | [→](#ng-wrap-up) |
| `ng wrap-up-check <window>` | verify a worker's wrap-up obligations before closing | [→](#ng-wrap-up-check) |
| `ng skeptic <sub>` | worker↔skeptic comms channel + nudge (delegator) | [→](#ng-skeptic) |
| `ng skeptic-arm\|-obligations\|-evidence\|-orphans\|-disposition` | skeptic pending-marker bookkeeping | [→](#skeptic-bookkeeping-verbs) |
| `ng respawn <window\|sid>` | resume a wrapped/closed worker's session in a tmux window | [→](#ng-respawn) |
| `ng service-incident <svc>` | assemble a service incident report from recorded state | [→](#ng-service-incident) |
| `ng spawn-decision <window>` | advisory continue-vs-spawn classifier for a window | [→](#ng-spawn-decision) |
| `ng engaged-done` | release an operator-engaged interactive window | [→](#ng-engaged-done) |
| `ng interactive-sessions` | list resumable interactive sessions (+ overview upsert) | [→](#ng-interactive-sessions) |
| `ng suppress-emit <id>` | operator-side manual emit-suppression of a comment | [→](#ng-suppress-emit) |
| `ng report-init <slug>` | create a frontmatter'd report skeleton | [→](#ng-report-init) |
| `ng report-check <path>` | validate a report against the schema | [→](#ng-report-check) |
| `ng report-grep <pattern>` | search the reports corpus without a silent zero | [→](#ng-report-grep) |
| `ng fetch-asset <url>` | fetch a `user-attachments/...` URL via user PAT | [→](#ng-fetch-asset) |
| `ng dashboard get` | read the overview-issue dashboard middle | [→](#ng-dashboard-get) |
| `ng dashboard put` | splice + PATCH the dashboard middle | [→](#ng-dashboard-put) |
| `ng dashboard scaffold` | print the canonical dashboard section skeleton | [→](#ng-dashboard-scaffold) |
| `ng dashboard validate` | strict check: required sections present? | [→](#ng-dashboard-validate) |
| `ng nexus-identity` | render + upsert the auto-generated identity block | [→](#ng-nexus-identity) |
| `ng watcher-status` | heartbeat age + target + liveness | [→](#ng-watcher-status) |
| `ng decision-ack <w> <fp>` | durably ack a `--- pending decisions ---` row | [→](#ng-decision-ack) |
| `ng log-action <agent>` | append a JSONL event to the action log | [→](#ng-log-action) |
| `ng mint-jwt` | print an App-level JWT (for `/app/*` endpoints) | [→](#ng-mint-jwt) |
| `ng lit search "<q>"` | content-relevance paper discovery (S2 + ASTA + OpenAlex) | [→](#ng-lit) |
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
ng show <comment-id> [--repo <owner>/<name>] [--meta]
```

**Output** — the comment body, raw. `--meta` switches to a
key=value + heredoc block instead:

```
id=<comment-id>
updated_at=<ISO ts>
body<<EOF
…body…
EOF
```

That `updated_at` is the compare-and-swap snapshot
`ng comment-edit --expect-updated-at <ts>` compares against, so the
safe read-modify-write loop is `ng show <id> --meta` → edit →
`ng comment-edit <id> --expect-updated-at <ts>` (exit `4` if the
comment changed underneath you).

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
ng close <issue> [--comment <text>] [--repo <owner>/<name>]
```

Prints `CLOSED` on success.

**Example**

```bash
monitor/ng close 12 --comment "shipped in linked PR"
```

### `ng comment-edit`

Compare-and-swap edit of an existing issue/PR comment. **Prefer
[`ng reply`](#ng-reply) (append) on a contended thread** — editing is
the operation that can destroy somebody else's words.

**Usage**

```
ng comment-edit <comment-id> (--expect-updated-at <ts> | --force)
                [--repo <owner>/<name>] [--body-file <path>]
```

One of `--expect-updated-at` / `--force` is **required** and they are
mutually exclusive: the verb is compare-and-swap by design and will
not guess. The safe loop:

```bash
monitor/ng show 4272693242 --meta        # 1. read body + updated_at
$EDITOR new.md                           # 2. modify
monitor/ng comment-edit 4272693242 \
    --body-file new.md --expect-updated-at 2026-09-08T17:41:02Z
```

**Exit codes** — `0` prints the comment URL; **`4`** the comment's
`updated_at` no longer matches what you passed, so a concurrent edit
would have been clobbered and nothing was written; `1` on the usual
failures. `--force` is deliberate last-writer-wins and warns loudly
on stderr before writing.

### `ng close-set`

Close a **set** of issues, each with its own body, verifying every
one individually. Built for the end of a batch — a PR that closes
eleven issues — where a partial success reported as success is the
failure that matters (`<your-org>/nexus-code#1444`).

**Usage**

```
ng close-set --bodies <dir> [--pr <n>] [--merge <sha>]
             [--repo <owner>/<name>] [--dry-run | --only-verify]
             <issue>...
```

**Behaviour**, per issue `N`:

1. Read `<dir>/<N>.md`. **No file ⇒ that issue is NOT-CLOSED** and the
   run continues to the next.
2. Substitute `__PR__` (from `--pr`) and `__MERGE__` (from `--merge`).
   **Any surviving `__TOKEN__` refuses that issue** — including a
   `__PR__` / `__MERGE__` you did not supply a value for. The guard
   matches the placeholder SHAPE (`__[A-Z][A-Z_]*__`), not any
   two-underscore substring, so an `a__b` in an evidence table does
   not trip it. An unfilled placeholder posted to a thread is worse
   than no comment.
3. POST the comment, then `assert-bot-author.sh` it. A comment whose
   author cannot be vouched for leaves the issue NOT-CLOSED and says
   so — repair by hand, do not re-post.
4. Close, then **re-read the issue** and require `state=closed` from
   that direct read. The close PATCH's own status is deliberately
   discarded (`|| true`): the read is the property, and a PATCH that
   reports success proves nothing the read does not.

**Output** — one `ISSUE <n>: CLOSED …` / `ISSUE <n>: NOT-CLOSED — <why>`
line each, then both sets with their counts:

```
CLOSED SET (9): 1401 1402 …
NOT-CLOSED SET (2): 1408 1411
```

**Exit codes** — `0` iff the NOT-CLOSED set is **empty**; `1`
otherwise. So the verb is safe to `&&` against.

`--dry-run` runs steps 1–2 (so a missing body or an unfilled token is
still reported), prints `ISSUE <n>: DRY-RUN — would post <bytes> and
close` instead of writing, and returns `0` regardless.
`--only-verify` skips steps 1–4's writes entirely and does nothing
but the per-issue read — `--bodies` is not required with it.

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
ng pr merge <n> [--squash|--merge|--rebase] [--sha <verified-head>]
                [--base-sha <verified-base>|--verify-base]
                [--delete-branch] [--repo <owner>/<name>]
```

Default merge method is `--squash`. `--delete-branch` removes the
head ref after a successful merge (logs a warning if the branch is
already gone).

**Pinning what you verified.** A green describes a `<head>` merged into
a `<base>`, and both can move between the check and the merge.

- `--sha <verified-head>` pins the HEAD you verified. GitHub rejects
  the merge (409) if the head moved (`#628`). Absent it, the freshly
  fetched head is pinned, which closes the fetch→PUT window but does
  not vouch for a head verified earlier.
- `--base-sha <verified-base>` pins the BASE that head's green was
  computed against. `ng ci-attempts` prints that sha **in full** on its
  `Merge-ref base: VERIFIED` line for exactly this purpose.
- `--verify-base` does the same **without a sha**: it re-runs the
  merge-ref base check inside this verb, milliseconds before the PUT.
  Prefer it — measured on this repo, the window between a verdict and
  the merge has been as short as **4 seconds** (`#899`), which is
  shorter than the round trip a caller needs to carry a sha.

Why either is needed: GitHub 409s a moved head, and 409s a base that
moved *conflictingly*. It accepts a base that advanced and still merges
**cleanly** — which is the whole hazard (`#823`), and measured at
**5 of 17 merges** on this board (`#880`). Both are **opt-in**: a base
check that fired on every merge would block the board every time the
base moved during a review, and a gate that always fires is a gate
somebody disables.

A missing flag value is refused, not defaulted — `ng pr merge 42 --sha`
exits **`64`** (EX_USAGE) rather than merging unpinned, and so does
`--sha ""`: an empty value is the same user-visible condition as a
missing one (`<your-org>/nexus-code#990`).

### `ng pr view`

One-line PR summary.

**Usage**

```
ng pr view <n> [--repo <owner>/<name>] [--json [field,...]]
```

**Output**

```
#<n> state=OPEN author=<login> <head>-><base> title=<title>
```

`--json` switches to scriptable output instead: bare, the whole
`/pulls/<n>` object (`jq -S .`); with a comma-separated field list
(`--json number,state,mergeable_state`), only those keys, each
`null` when absent. Field names are validated against
`^[A-Za-z0-9_.]+$` — anything else is refused rather than
interpolated into the `jq` filter.

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

### `ng stranded-branches`

List remote branches that are **not** merged into the integration
branch — pushed work that no surface an orchestrator reads can see
(`<your-org>/nexus-code#1399`). Open issues, live windows, open PRs and
cross-reference events all miss a branch that was pushed and never
PR'd; this enumerates them directly from refs.

**Usage**

```
ng stranded-branches [--since <date>] [--base <ref>] [--remote <name>]
                     [--with-prs] [--repo <owner>/<name>]
```

Must run inside a git checkout. It **fetches first** — a stale
negative is the failure mode here — and warns on stderr if the fetch
failed rather than silently answering from an old tree. `--base`
defaults to the repo's integration branch resolved via
`monitor/_integration_branch.sh`, falling back to `dev`; `--remote`
defaults to `origin`; `--since <date>` drops branches whose last
commit is older.

**Output** — a `base: <remote>/<branch> @ <short-sha>` header, then
one tab-separated row per stranded branch, then a total:

```
<branch>	<n> ahead	<YYYY-MM-DD>	<pr-col>	<last commit subject>
stranded: 72 branch(es) ahead of origin/dev; 65 with NO open PR  [fetched origin just now; …]
```

`--with-prs` adds the `pr=` column by asking GitHub (a read) which
branches have an open PR. **A failed PR listing prints `pr=?`, never
`pr=NONE`** — an empty list would mark every branch un-PR'd, which is
the silent-zero direction — and a warning goes to stderr.

Always exits `0` when it could look; `1` (via `die`) when the ref or
`--since` date is unusable, or when the cwd is not a checkout.

### `ng guards-for-diff`

Before you push a change under `monitor/`: **which construct-keyed
guards read the files you changed?** A PR's green covers the suites
its *diff touches*, not the suites its *change affects*
(`<your-org>/nexus-code#803`). Facade over
`monitor/guards-for-diff.sh`; `CLAUDE.md` carries the canonical
invocation block.

**Usage**

```
ng guards-for-diff [--run] [--timeout <s>]
```

It is a **pass-through facade**: every flag `monitor/guards-for-diff.sh`
accepts works here too (`--base`, `--quiet`, `--changed-files`,
`--suites-from`), and that script's header is the authority for the
flag set and the exit codes — the table below is a reading aid, not a
second source.

It asks each guard for its population via a `--population` protocol,
prints what it **considered and excluded** as well as what it
selected, and states how many suites declare nothing and are
therefore invisible to it. `--run` additionally runs the selected
guards and reports each verdict.

**Exit codes — none of them is a clearance:**

| Code | Meaning |
|---|---|
| `0` | at least one registered guard reads a file in your diff (under `--run`, they all passed). Says *some* declaring guard matched — never that the guard that matters ran (`#1078`) |
| `1` | `--run`: a selected guard **FAILED** |
| `2` | **REFUSED** — a guard's population probe errored, or the diff could not be computed. Fail-closed on purpose |
| `3` | **no** registered guard reads your diff. A measured answer, not a green light |
| `4` | `--run`: every selected guard came back green, but at least one green is **UNVERIFIED** — a population guard enumerates `git ls-files`, so it cannot see an **untracked** file in your diff (`#1054`). `git add` and re-run |
| `5` | `--run`: the `--timeout` deadline expired with selected guards left **without a verdict** |

Read the tool's own per-run **blind-spot count**, not the exit code:
that line prints byte-identically at `0` and at `3`. And `git add`
before you trust it — selection counts your whole working set
including untracked files, while a population guard enumerates
tracked files only, so a guard can be selected, run, and return a
confident green about a tree that does not contain your new file.
This is **not** a substitute for the full suite. Worked exit-code
detail: [`nexus.self-fix`](skills.md).

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
          [--asset-repo <owner>/<name>]
```

Exactly **one** positional (the local path). A second bare positional
is refused — a bare number used to bind to `--repo-path` and write
`assets/<N>` as a *file* where that issue's asset *directory* lives,
at exit 0 with a resolving URL (`<your-org>/nexus-code#858`).

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
| `assets/<N>/<basename>` | `--issue N` is passed (e.g. `assets/13/fig.png`) |
| `assets/reports/<basename>` | uploading from `reports/` |
| `assets/general/<basename>` | everything else |
| `<free-form>` | `--repo-path <path>` overrides the default placement |

A `--repo-path` without a leading `assets/` gets one — every push
lands under `assets/`.

**Destination repo** — this verb pushes to the **asset** repo, and
that is the one place on the `ng` surface where `--repo` does not
mean the issue repo:

- The default is `github.asset_repo`, falling back to `github.repo`.
  Env override: `NEXUS_ASSET_REPO`. The branch is `main`, and is not
  configurable.
- `--asset-repo <owner>/<name>` is the flag that says what it means.
  Use it when you genuinely mean a different asset repo.
- `--repo` is the **deprecated spelling** of `--asset-repo`. It is
  accepted only when it *restates* the configured asset repo; any
  other value is **refused (exit 7)**, because every other `ng` verb
  that takes `--repo` means the ISSUE repo by it, and a worker who
  typed it that way pushed a report onto the implementation repo
  (`<your-org>/nexus-code#1173`).
- Pushing to the repository this nexus checkout itself came from is
  also refused (exit 7) unless `NEXUS_ALLOW_ORIGIN_ASSET_REPO=1`.

**Defaults**

- `--shape` — `pin`.
- `--message` — `"Add asset <basename> via upload-asset.sh"`.

**Exit codes** — `0` URL on stdout; `1` bad usage; `2`
`mint-token.sh` failed; `3` asset-repo clone/pull/push failed; `4`
REFUSED, the nexus primary root could not be established or
`<root>/assets` is not a git repository rooted at itself
(`<your-org>/nexus-code#1077` — distinct from `3` on purpose: `3` means
the asset repo was reached and the operation failed, `4` means the
script declined to act because it could not prove *where* it was
acting); `7` REFUSED, wrong destination repository (the two rules
above). Both `4` and `7` are decided before anything is staged and
before any git verb runs.

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

`--repo` is **rejected** with a structured error, not accepted and
ignored: `reports/` is always written under `$NEXUS_ROOT`, including
from a worktree or a secondary clone.

> **Known divergence.** `ng report-init --help` advertises a
> `[--skeptic-role]` the verb does not parse: it takes the
> `unknown flag` arm and exits `1`. Deliberately absent from the
> synopsis above, which describes what the parser accepts.
> `test-ng-usage-flag-coverage.sh` checks parsed-flag → usage-line,
> not the reverse, so this direction is unguarded.

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
ng report-check <path> [--allow-todo] [--skeptic-gate-settling]
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
  (default 500; `MONITOR_REPORT_MIN_CHARS` overrides it for one run),
  counting everything after the frontmatter.
- No literal `TODO`, `FIXME`, `<...>`, `_(fill in)_`, or
  `_(later)_` placeholder text. `--allow-todo` bypasses these last
  four checks for intentional in-progress checkpoints.
- A frontmatter `disposition: no-further-pass` must not **contradict a
  skeptic gate** for the report's `window:` (`<your-org>/nexus-code#1363`):
  it is refused when a skeptic-pending marker
  (`monitor/.state/skeptic/pending/<window>`) is live for that window, or
  the window record is spawn-stamped `skeptic_mode: require`.
  `retire-preflight.sh` reads this field as its first gate and
  `no-further-pass` is the permissive value, so the contradiction can only
  ever make retirement easier than the marker says it should be. State
  `second-pass`, or settle the gate first. Skeptic-*role* windows are
  exempt (their verdict path clears their own marker); a report with no
  `window:` is not compared (`ng wrap-up` repeats the check keyed on the
  invoking pane, and adds `--skeptic-decision require`, which is not on
  disk until the wrap-up records it). `--skeptic-gate-settling` is passed
  by a `--skeptic-waive` / `--skeptic-satisfied` wrap-up, whose run is the
  settlement rather than a contradiction; it is not an authoring override.

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

### `ng report-grep`

**Search the reports corpus. Use this, not `grep -r reports/`.**
`reports/.gitignore` is a bare `*`, so an ignore-file-honouring
`grep` — which the operator's interactive `grep` is — matches
**nothing** across thousands of files and returns a confident,
wrong "no" (`<your-org>/nexus-code#618`). This verb searches with
`command grep -r` — the `command` builtin bypasses that shell
function — recurses (so it also sees `reports/YYYY-MM/` archives),
and **refuses a zero it cannot vouch for**. The residual vector the
guard exists for is an ignore-file-aware `grep` *executable* ahead of
`/bin/grep` on `PATH`, which `command grep` would still honour.

**Usage**

```
ng report-grep [grep-opts] <pattern> [path...]
```

Default search root is the resolved reports dir; explicit paths
override it. Options before the pattern are forwarded to `grep`
(`-l`, `-n`, `-i`, `-c`, `-E`, `--include=…`); `--` terminates
options so a pattern may start with `-`. **Grep options taking a
separate argument (`-m 5`) are not supported** — use `--opt=value`
form, or `command grep` directly.

**Exit codes** — this is the whole point of the verb:

| Code | Meaning |
|---|---|
| `0` | matches printed |
| `1` | genuine no-match — **and the corpus was proven visible** |
| `3` | the corpus is **INVISIBLE** to the search; the visibility guard fired and printed a diagnostic. Not a no-match |
| ≥2 (other) | the underlying `grep`'s own error, passed through |

The `1`/`3` split is the contract: nothing else in this workspace
distinguishes "searched and found none" from "could not search". The
guard keys on a sentinel — a root holding at least one standard
`ng report-init` report is reliable; **a root of only non-standard
files is a `3` ("don't know"), never a false zero.**

The guard is **one-directional**: it converts an untrustworthy zero
inside this verb into a loud refusal. It does not neutralise a bare
`grep -r reports/` typed elsewhere — that still returns a silent
zero.

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
          [--guards | --no-guards-preflight] [--strict-guards]
          [--retain <reason> | --no-retain]
          <skeptic flags — see below>

ng wrap-up --reply-to <request-id> <report-path>
          [--issue <n>] [--answer-file <path>]
          [--repo <owner>/<name>] [--allow-stub]
          [--retain <reason> | --no-retain]

ng wrap-up --last [<window>]
ng wrap-up --explain [<window>]
```

**Skeptic flags** — producer side (the worker being reviewed):

```
[--skeptic-decision require|deny --skeptic-rationale <why>]
[--skeptic-waive <reason>]
[--skeptic-satisfied --skeptic-satisfied-by <report-path|sha256>]
[--skeptic-contradicted <what>]
[--skeptic-delta <what changed since a DECLINED prior request>]
[--skeptic-rearm <what changed>]
```

…and the skeptic's own wrap-up:

```
[--skeptic-role --skeptic-verdict credible|check|suspect|refuted
 [--skeptic-target <window>] [--skeptic-depth <n>]
 [--skeptic-findings <n>] [--skeptic-orig <window>]]
[--skeptic-subject <report-path|sha256>]
[--not-a-skeptic-verdict <why>]
```

`--skeptic-subject` is what you actually READ, and it is the one
field on this path that is your assertion rather than an inference:
`--skeptic-target` is a spawn-time stamp and goes stale the moment a
retained reviewer is re-tasked (`<your-org>/nexus-code#963`).

**Channel delivery — `--reply-to`** (`ng request`'s inbox). Delivers
the answer over the request/reply channel instead of a GitHub issue:
no issue comment, no rocket, unless `--issue <n>` is also passed,
which does **both**. `--answer-file <path>` supplies the reply body.

**Re-reading a run — `--last` / `--explain` (read-only)**

Every `ng wrap-up` invocation persists its stdout, stderr (prefixed
`[stderr] `) and exit code under
`monitor/.state/wrap-up-output/<window>/`, and `--last` prints the most
recent record verbatim; `--explain` appends the window's pending-marker
state and its `ng skeptic-evidence` line. Both are **read-only**: no
upload, no comment, no skeptic step, no ledger row, no action-log event.
Use them to re-read output a pipe truncated. Do **not** re-run the verb
for that — every run re-arms the skeptic step (Step 0b), and a re-run whose
only purpose was to read the diagnostic appended discharge rows that bind
to nothing (`<your-org>/nexus-code#1370`). `<window>` defaults to the
invoking tmux window; off-tmux runs are recorded under `_no-window`.
A run that exits from inside a parse refusal leaves a record without an
`rc:` footer, and `--last` says so.

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

   `--skeptic-findings` is **optional, and its absence is recorded AS
   absence** (`<your-org>/nexus-code#881`). Omitted, it prints
   `new findings : not stated`, logs `findings-stated=false` with **no**
   `findings` key, and never reaches the threshold comparison — where it
   used to be defaulted to `0`, making "measured zero new issues" and
   "never said" the same record. There is no sentinel number. With
   **neither** a count nor a readable frontmatter `disposition:` in the
   report, wrap-up **refuses** (`<your-org>/nexus-code#1095`, superseding
   `#881`'s escalation) rather than terminating on a value nobody
   supplied. Stating either one — `--skeptic-findings 0` or
   `disposition: no-further-pass` — lifts the refusal. Whether the chain
   then *terminates* depends on the verdict, not on the statement: at
   `credible` / `check` either statement ends it; at `suspect` /
   `refuted` **neither does** — the verdict sets the severity signal on
   its own, which `#678` makes non-overridable by a disposition, so a
   second pass is recommended regardless, and the refusal text says so
   rather than promising a termination it cannot deliver
   (`<your-org>/nexus-code#914`).

   `--not-a-skeptic-verdict "<why>"` is for a window whose **provenance**
   carries `skeptic_role: true` but whose current wrap-up is ordinary
   worker work (`<your-org>/nexus-code#879`). Windows are stamped for their
   lifetime, not per task, so a retained skeptic that later authors a
   patch would otherwise have to supply a `--skeptic-verdict` on its own
   diff — a self-review indistinguishable downstream from an independent
   clearance. The flag takes the ordinary producer path and records
   `skeptic-role-not-asserted` with the reason (mandatory, >= 20 chars).
   It **clears no skeptic marker — including the opting-out window's
   own**: an opt-out is a statement about *this hand-off*, not a release
   of a pending obligation (`#879` F1; the three producer branches that
   would otherwise clear it are guarded, and say so loudly). It is
   mutually exclusive with `--skeptic-role` and `--skeptic-verdict`, and
   refused outright on a window that was never stamped.
0c. **Async-wait pre-flight** (`<your-org>/nexus-code#1181`). Reads
   `monitor/.state/orphan-async-state.tsv` for the invoking window. A wait
   with a **parsed handle** (`asyncrun:ar-…`, `slurm:<jobid>`) **refuses**
   the wrap-up, naming it — it is answerable (`async-run.sh --status-line`,
   `sacct -j`) and the agent still has the context to settle it with
   `monitor/declare-no-wait.sh <kind> <id>` once it is confirmed dead. A
   `syn-` wait (the launcher retained no handle; possibly a phantom) only
   **warns**. A token the pre-flight cannot parse refuses. Nothing is ever
   auto-cleared. Runs before Step 0b, so a refusal arms nothing.
0d. **Disposition-vs-gate check** (`<your-org>/nexus-code#1363`), the
   `report-check` rule above repeated for the invoking window plus this
   invocation's `--skeptic-decision require`. Skipped when the wrap-up
   itself settles the gate (`--skeptic-waive`, `--skeptic-satisfied`).
0f. **Guards-for-diff pre-flight** (`<your-org>/nexus-code#1459`). Runs
   [`ng guards-for-diff`](#quick-reference)'s selector and names every
   selected guard the report never mentions. **Advisory by default**;
   `--strict-guards` turns an unreported selection into a refusal
   (return 1). It is expensive (~80 s measured), so the automatic arm
   fires only for a wrap-up that plainly describes nexus-code work —
   cwd inside a repository carrying `monitor/guards-for-diff.sh`
   **and** the report under the primary's reports corpus. `--guards`
   forces it; `--no-guards-preflight` or `NG_WRAPUP_GUARDS_PREFLIGHT=0`
   skips it. Every non-selector outcome (selector exit `2`/`3`, the
   `NG_WRAPUP_GUARDS_TIMEOUT` expiry, a missing binary) prints
   **UNMEASURED / not a clearance** and returns 0 — it never converts
   "could not look" into "looked and it was fine".
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

**Exit codes** — three, and the third is the one callers get wrong:

| Code | Meaning |
|---|---|
| `0` | published — every attempted step succeeded |
| `1` | a step **FAILED**. Retry it |
| `3` | nothing failed and **NOTHING WAS PUBLISHED** |

On a `1`, the verb still attempts every reachable step (rocket and
log-action do not depend on the upload), then emits a structured
stderr report naming which steps ok/failed so the caller can retry
just the failed ones.

A `3` is **not** a retryable failure: no step failed, so re-running
the command unchanged reproduces it exactly. Either the composed
teaser carried no claim (`<your-org>/nexus-code#1114`), or your report
changed outside its `## Summary` section while the composed comment
body did not (`#862`) — the comment is built from the first ~200
characters of `## Summary` alone, so a correction anywhere else
leaves it byte-identical and there is nothing to publish. stderr
names which and lists the ways out. **A re-run is not free**: the
upload runs again and so does the skeptic step (0b), which *arms* —
"no step failed" is not "no step had an effect"
(`<your-org>/nexus-code#1230`). To re-read the diagnostic, use
`ng wrap-up --last`, which replays it read-only.

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
3. The trigger comment was rocketed, or the rocket step was legitimately
   skipped at wrap-up time — both normalise to `rocket=ok`. A `failed`
   rocket becomes `missing`; a rocket withheld because nothing was
   published becomes `withheld`; any other recorded value becomes
   `unknown`.
4. The link comment was actually **published** — a wrap-up that exited
   `3` (`degenerate-teaser` / `nothing-published`) reports
   `comment=unpublished` and is **not** ok.

**Output** — five fields, on one line:

```
status=<ok|incomplete> wrap_up=<present|missing> report_check=<ok|fail|missing> rocket=<ok|missing|withheld|unknown> comment=<ok|unpublished|failed>
```

`status=ok` requires all four to read positively — `wrap_up=present`
**and** `report_check=ok` **and** `rocket=ok` **and** `comment=ok`.
Each is compared for **equality** against its ok-value, not against a
denylist of bad ones, so `withheld` and `unknown` — every state
nobody thought of — read as `incomplete` rather than slipping through
a permissive default (`<your-org>/nexus-code#1116` F1).

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
ng skeptic <init|dir|reqfile|ask|poll|status|list|await|answer
            |await-answer|reconcile|close|resolve|reset|defer
            |nudge|notify-delta> ...
```

**Subcommands**

| Sub | Who runs it | What it does |
|---|---|---|
| `ask <task> <slug> …` | skeptic | write a request (`<slug>.open.md`) |
| `await <task>` | worker | block for `*.open.md`, ack each (→`.ack.md`), exit `0`; `DONE` sentinel → exit `10`; counterpart finished without closing → `11`; displaced by a newer await → `12`; `defer`red → `13`; timeout → `4` |
| `answer <task> <req> …` | worker | reply to a request (→`.answered.md`) |
| `await-answer <task> <req> …` | skeptic | block for the worker's answer |
| `reconcile <task> …` | skeptic | ensure every open request was acked |
| `close <task>` | skeptic | drop the `DONE` sentinel that ends the worker's await loop |
| `resolve <task> --reason …` | **orchestrator only** | clear a skeptic-pending marker a returned verdict failed to clear, with a mandatory rationale + audit event — the sanctioned replacement for a hand-`rm` (`#577`). `--disposition` additionally releases `retire-preflight` check 1c and is the one form that succeeds with **no** marker present (`#813`) |
| `defer <task> --reason …` | skeptic/orchestrator | release the worker's *current* await (exit `13`) while the requirement **stands** — the pending marker is untouched and `retire-preflight` keeps gating (`#845` H) |
| `reset <task>` | skeptic | open a new round: archive the prior `DONE` + `.answered.md` under `skeptic/.archive/<task>.reset-<ts>/` |
| `poll \| status \| list <task>` | either | inspect channel state (open/ack/answered) |
| `nudge <window> …` | orchestrator/skeptic | wake an idle worker |
| `notify-delta <skeptic-window> --target <w> …` | target side | the reverse of `nudge`: wake a **pinned skeptic** that a new round exists. Its absence is why a parked target and its idle skeptic could each wait on the other for hours (`#845`) |
| `init \| dir <task>` | either | create / print the channel directory |
| `reqfile <task> <req>` | either | resolve a req id/stem/filename → path |

The rename is the signal at every step. Run `ng skeptic --help` for the
full surface and exit-code contract.

#### Skeptic bookkeeping verbs

Five **top-level** verbs — not `ng skeptic` sub-verbs — read and write
the pending-marker bookkeeping that gates retirement. They are
read-only except `skeptic-arm`. Each exit code is stated because the
whole family exists to keep "nothing outstanding" distinguishable
from "could not look":

| Verb | What it answers | Exit codes |
|---|---|---|
| `skeptic-arm <window> --report <path> [--issue N] [--state-dir D]` | **records what an arm is about**, for the writers of armed state that live outside `ng` (`spawn-worker.sh --skeptic-role`) | `0` an `armed` row was appended · `2` usage · `3` this artefact is **already outstanding**, so nothing was appended (a second arm for one artefact *is* `ambiguous-N-arms-outstanding`, `#1156` pole B) · `4` could not name a subject — a marker may still exist |
| `skeptic-obligations <window> [--state-dir D]` | **what this window owes, by task** — one line per artefact still outstanding, naming its issue and report | `0` nothing outstanding · `1` one or more · `2` usage · `3` no marker store. The pending *marker* cannot answer this: its content is `1`, so presence cannot say **which** obligation (`#961`) |
| `skeptic-evidence <window> [--state-dir D]` | **does a verdict exist, and could the bookkeeping match it** — separates "no verdict exists" from "a verdict was delivered and could not be matched to an arm", opposite instructions printed identically until `#1156` | `0` looked · `3` could not look |
| `skeptic-orphans [--state-dir D]` | **every** pending marker, classified by whether its window is present in tmux — the only discriminator separating a live pairing from an orphan (age does not, measured). Report only; reaps nothing | `0` looked · `3` no marker store |
| `skeptic-disposition <window> [--reports-dir D]` | the window's `disposition:` as read from its reports, emitted `key=value` (`state= source= report= report_mtime= blocking= reports= detail=`) | `0` read · `2` could not determine (`state=unknown`) |

Per orphan the remedy is `ng skeptic-evidence <window>`, then
`ng skeptic resolve <task> --reason "<why>"`.

> **Known divergence at `a3177ef6`.** `ng skeptic-arm --help` and
> `ng skeptic-obligations --help` die `unknown flag` — neither
> function calls `_help_check`, though both have a `_usage_for` arm.
> `ng skeptic-disposition --help` has the inverse defect: it calls
> `_help_check`, has **no** `_usage_for` arm, and so falls back to
> printing `monitor/ng`'s whole file header. Use the table above
> until that is repaired.

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
| `0` | a decision was rendered (any class) — including `decision=spawn reason=window-absent`, which is a genuine verdict about a missing window, not a failure |
| `1` | the classifier could not run: `reason=no-tmux` or `reason=enumeration-failed` |

The `no-tmux` line is the one short row — it carries `decision=` and
`reason=` only. Parse defensively, or key on the exit code first.

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
ng interactive-sessions [--limit N] [--days D] [--upsert-overview]
                        [--dry-run] [--repo <owner>/<name>]
```

- `--limit N` — include at most N sessions (default 20).
- `--days D` — only sessions active within the last D days (default 30).
  Both must be positive integers; anything else is refused.
- `--upsert-overview` — PATCH the rendered block into the overview issue.
- `--dry-run` — print the block; skip the GitHub PATCH.
- `--repo <owner>/<name>` — which repo holds the overview issue
  (write-verb resolution; only consulted for the PATCH).

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

1. Read the new middle from `--body-file` (or stdin; `-` asks for stdin
   explicitly). Refuse if empty — the diagnostic names the INPUT, not the
   dashboard.
2. **Refuse if the supplied body contains a dashboard marker.** `put` takes
   the INNER region; `gh issue edit --body-file` takes the whole body.
   Accepting the wrong one nests the markers and every later put duplicates
   the content (`#959`).
3. Fetch the overview body; refuse unless it carries **exactly one** START
   and **exactly one** END marker. Presence is not uniqueness (`#1058`,
   `#1118`): a body with two ENDs used to pass this check and then no-op.
4. Replace the middle between the markers (header + footer preserved).
5. **Refuse before sending** if the merged body exceeds GitHub's
   262,144-byte issue-body cap; warn from 90%.
6. PATCH, then **verify the write by reading the body back with an
   INDEPENDENT GET.** A 200 is not evidence of a write — and neither is the
   PATCH response, which echoes the body you SENT even when the store keeps
   the old one (measured on scratch issue `#1128`). The response is compared
   too, but that only catches corruption on *our* side of the wire.
7. Only once verified: cache the new middle to `monitor/.state/dashboard.md`
   and write `monitor/.state/dashboard-updated.ts` (the freshness timestamp
   the watcher reads).

Prints the overview issue's HTML URL, and only when the write is verified.

**Exit codes**

| rc | meaning |
|----|---------|
| `0` | verified applied (or `#1010` UNCHANGED — nothing to do) |
| `1` | refused before sending, PATCH failed, or **verified NOT applied** |
| `4` | the PATCH may have applied but could **not be verified** — a refusal to claim, not a claim of failure |

On any non-zero rc no cache is written and no freshness stamp is advanced.

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

Strict schema gate: exit `0` if every required section heading is present
**exactly once**, exit `1` otherwise (missing and duplicated sections listed
on stderr). The hard-failure counterpart to `put`'s warn-only check — use it
for CI, pre-commit, or a deliberate conformance check.

**Usage**

```
ng dashboard validate                        # the LIVE dashboard (default)
ng dashboard validate --body-file <path>     # a candidate, before pushing
ng dashboard validate --body-file -          # explicitly stdin
```

With **no `--body-file` it validates the LIVE dashboard**, which is what the
verb name implies. It used to read stdin — empty in every non-interactive
shell — and report that emptiness as `empty dashboard body`, a verdict about
the dashboard derived from the caller's empty pipe (`#958`). A healthy 15 kB
dashboard failed that way, and the message's obvious consequent action
(regenerate and push) would have overwritten it.

**What it checks**

- every required section present — searched in the whole issue body, not just
  the region, so a `## Identity` pointer whose generated block sits *above*
  the START marker is not reported missing;
- each required section appears **once** — a duplicate is always a defect on a
  routing surface;
- exactly one START and one END marker, when given a whole body;
- near-miss headings (`## 🛑 Infra — …`) are named rather than silently
  counted as missing;
- duplicate *names* that differ after their separator are reported as a NOTE
  and the verdict stops calling itself an unqualified OK (rc stays `0`);
- body size and section counts accompany every verdict.

Given only a region it says so, rather than asserting a section is absent
when it cannot see the rest of the body.

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
| `0` | Fresh: heartbeat age ≤ `2× + 15 s` of `monitor.interval_seconds`, pid identity-validated alive |
| `1` | Stale: heartbeat age within `(2× + 15 s, 5×]` of `monitor.interval_seconds` |
| `2` | Very stale (> 5×), or heartbeat pid dead / recycled to a non-watcher process |
| `3` | No heartbeat file |
| `4` | **Wedged**: pid alive and the heartbeat is fresh, but the progress/cycle signal has stalled — the liveness ticker is beating for a loop that no longer moves (`<your-org>/nexus-code#491`). A distinct bucket precisely so a caller cannot conflate it with DEAD or with merely-slow |

The DEAD threshold (`5×`) can be **raised** by a third argument to
`_watcher_alive` — the supervise-tick passes a cutoff above the
watcher's own async hang-watchdog floor so it does not race a
self-recovery in progress. It is never lowered. `ng watcher-status`
itself passes no override.

A pid that fails the identity check is not immediately `2`: the
check reads `/proc/<pid>/cmdline` and is therefore pid-namespace
local, so a live watcher across a sandbox boundary would false-read
as dead. Before declaring `2`, `_watcher_alive` consults the
state-dir `flock`; a held instance lock falls through to the
heartbeat-age buckets instead.

### `ng decision-ack`

Durably ack a `--- pending decisions ---` row (<your-org>/nexus-code`#790`).

**Usage**

```
ng decision-ack <window> <fingerprint> [--reason <text>]
ng decision-ack <path-to-decision-json>  [--reason <text>]
ng decision-ack <window> --all           [--reason <text>]
```

The emit row cites the exact invocation on its `ack=` line, and the
`file=` path is accepted verbatim so nothing has to be re-split by hand
(a mistyped fingerprint tombstones nothing while reporting success).

**Why not just `rm` the file.** That was the documented ack for a year
and it is a **no-op**. The fingerprint is `sha1(window | kind | message)`,
and `idle_prompt`'s message is the constant `Claude is waiting for your
input` — so for that kind the fingerprint is a pure function of the
window. Remove the file, let the worker sit idle another minute, and the
hook writes back a byte-identical name. Measured on a live nexus:
`civerdict.bb0f332f628a.json` removed at 15:41, present again at
16:09:32 with the same fingerprint; `guardgap.672915acaad8` acked three
times over one session. The reader could not distinguish "fired again
because something changed" from "fired again because I deleted a file".

This verb performs the durable move instead — `<w>.<fp>.json` →
`<w>.<fp>.handled.json` — which **both** the hook's write path and the
watcher's reader have always honoured as terminal. It then verifies the
property (tombstone present *and* live file gone) rather than trusting
`mv`'s exit status, and logs a `decision-ack` action-log event.

**Scope of the suppression.** Terminal for that fingerprint until the
window is retired (`ng retire-window` prunes `decisions/<w>.*`) or reaped
(the watcher drops decisions for windows absent from tmux past
`MONITOR_PENDING_REAP_MIN_AGE_SECONDS`, default 900 s). For
`idle_prompt` that means this window's idle pings stop being *decision*
rows — which is correct: `--- idle workers ---` is the surface that
tracks idle workers, it cannot be tombstoned, and two channels nagging
about the same fact is what made this one skimmable. A
`permission_prompt` embeds the tool and its arguments in the message, so
a *different* prompt is a different fingerprint and surfaces normally;
only the identical prompt is muted.

**Exit codes**: `0` acked (or already acked — idempotent); non-zero on a
malformed fingerprint, a missing decision, or a tombstone that could not
be written.

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
$ ng lit search "<query>" [--source s2|asta|openalex|both|all] [--limit N] [--year A:B] [--human]
$ ng lit add <DOI|S2-id|openalex:Wid> [--human]          # grow the library
$ ng lit setup                                           # key-acquisition refs
```

- **`search`** queries Semantic Scholar, ASTA, and OpenAlex by relevance
  (default `--source all` — the three are complementary, not redundant),
  dedups against the reference library, and annotates each hit
  `in_library`. A keyed backend (S2/ASTA) with no key is **skipped with a
  note** (never a hang); OpenAlex needs no key so it's never skipped for
  that reason. Default output is JSON; `--human` is readable.
  Every response leads with **`status`** — `ok` (every requested backend
  searched; a `count` of 0 means nothing matched the query as asked, which
  is not the same as a verified absence), `partial` (a backend failed
  or was skipped; a 0 establishes nothing), or `error` (the query itself
  failed — exit 2, and **no `count`/`results` key at all**, so a broken
  search can never be read as an empty literature). See
  [Literature research](literature.md#the-three-result-states).
- **`add`** fetches a paper by DOI, S2 id, or OpenAlex work id and appends a
  schema-compatible record to the library (`<nexus.root>/.bipartite/refs.jsonl`
  by default, or `lit.library_path`). Dedup-checked by DOI. Works with zero
  keys configured via the OpenAlex DOI fallback; an S2 key is only needed
  for non-DOI ids.
- **`status` / `setup`** report configured backends (env / `config/nexus.yml`
  `lit.*` / legacy `bip` config — never the key itself). OpenAlex always
  reports available (no key required), so the tool is never fully
  "unconfigured"; `status` prints key-acquisition references as a hint when
  S2/ASTA are both unconfigured, but only exits non-zero when a specific
  `--source` request (`s2`/`asta`/`both`) has no matching key.

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

**The code is canonical; this page is a narrative over it.** **Four**
surfaces describe `ng`. The first is ground truth — it *is* what
dispatches. Of the other three, exactly **one** is machine-checked:

| Surface | Meant to be canonical for | Guarded by |
|---|---|---|
| the `case "$sub"` in `main()` | the verb set — the **only** surface that decides what dispatches | the shell |
| `_verb_index` in `monitor/ng` | the browsable index (`ng verbs`) | **nothing** |
| `_usage_for` in `monitor/ng` | each verb's flag set | `test-ng-usage-flag-coverage.sh` (parsed flag ⇒ must appear in the usage line) |
| this page | *why* a verb behaves as it does — exit-code semantics, refusal rationale, worked examples | **nothing** |

Whenever you add, rename, or remove a verb, or change a flag or an
exit code:

1. Update `monitor/ng`'s top-of-file usage block, its `_usage_for`
   arm, and `_verb_index`.
2. Update the section for the verb on this page and the
   [Quick reference](#quick-reference) table — **including the
   subset list**, if a verb gained or lost a section here.

**Three known gaps, so you know what the guards do *not* buy you.**
`test-ng-usage-flag-coverage.sh` checks parsed-flag → usage-line and
**not the reverse** — a usage line may advertise a flag no parser
accepts (see [`ng report-init`](#ng-report-init)). Nothing compares
this page against either source. And **nothing asserts `_verb_index`
against the dispatch table**, so a verb can ship without ever
reaching the index that exists to make verbs findable. Measured at
`a3177ef6` (`monitor/ng` is unmodified at that ref), the `case` in
`main()` dispatches **59** verbs and `_verb_index` names **48** of
them. The **11** it omits: `ci-attempts`, `close-set`,
`reports-for-window`, `send`, `session-id`, `skeptic-arm`,
`skeptic-disposition`, `skeptic-evidence`, `skeptic-obligations`,
`skeptic-orphans`, `stranded-branches`. All 11 dispatch; `--help`
support among them is **uneven** — see the measured examples in the
[Quick reference](#quick-reference) note above, which is a separate
gap from this one. Add a verb to `_verb_index` in the same commit
that adds its `case` arm. See
[Development](../contributing/development.md).
