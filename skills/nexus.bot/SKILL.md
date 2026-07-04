---
description: "nexus bot identity for all GitHub writes: monitor/ng for nexus repo, GH_TOKEN=$(mint-token.sh) gh for cross-repo. Never plain gh."
---

# nexus.bot — GitHub identity for spawned agents

TRIGGER when: agent considers any GitHub write (open/edit/merge a PR, create/comment/close an issue, add a reaction, edit the dashboard, upload an asset to the asset repo); agent reaches for `gh pr create`, `gh issue create`, `gh issue comment`, or `gh pr review`; agent embeds a local file (image, PDF, report) in a comment or PR/issue body.

## The one rule

Every GitHub write originating from a nexus agent MUST run as the
**bot**, not the user. Two channels:

1. **`monitor/ng <verb>`** — preferred for the nexus repo. Mints the
   bot token internally, picks up the configured repo from
   `config/nexus.yml`, hides the verbose `gh api` JSON.
2. **`GH_TOKEN=$(./monitor/mint-token.sh) gh <verb>`** — for cross-repo
   writes, or one-offs `ng` doesn't cover yet. Setting `GH_TOKEN` makes
   `gh` use the bot token instead of the user's cached auth.

The only GitHub interactions that may still use the user's identity
are `git commit` and `git push` (commit authorship stays the user's
on the commit graph).

## The bot is the DEFAULT — the `gh` wrapper

You do not have to remember the rule for the common case: a bare
`gh <write>` already runs as the bot. A PATH-FRONT `gh` wrapper
(`monitor/ghwrap/gh`) is prepended to the front of `PATH` for every
agent process: process-wide by `monitor/locals-env.sh` (full mode),
and re-asserted to the FRONT per-command by
`monitor/shellenv/.zshenv` (reached via
`ZDOTDIR=$NEXUS_ROOT/monitor/shellenv`). The per-command force-front
is the load-bearing bit — `~/.zshenv` re-prepends linuxbrew (where
the real `gh` lives) on every `zsh -c`, so the wrapper dir is pushed
back to the front AFTER that, winning the race (<your-org>/nexus-code
PR #349, operator request comment 4795415597).

A real **executable** — not the earlier zsh *function* — because a
function only shadows `gh` inside the zsh shells that source it; the
wrapper, being on PATH, is inherited by EVERY child an agent spawns
(bash subshells, `python subprocess`, Makefiles). The classification
+ token logic is single-sourced in `monitor/gh-shim.sh`, which the
wrapper sources after resolving the real `gh` (first on PATH that is
not itself — recursion-safe).

What it does, per invocation:

- **WRITE verb → auto-inject the bot token** (minted via
  `monitor/mint-token.sh`, the same source `ng` uses — no token
  logic is reimplemented). It FAILS LOUD on an empty/failed
  mint (refuses the call) rather than letting `GH_TOKEN=""` fall
  through to the operator's ambient auth (the security-boundary
  rule below).
- **READ + `gh auth …` → pass through untouched.** Reads don't
  notify; `gh auth token` is the user-PAT path `ng fetch-asset`
  needs.
- **`GH_TOKEN` already set → pass through unchanged.** The watcher
  and correct callers (incl. `GH_TOKEN=$(./monitor/mint-token.sh)
  gh …`) set it explicitly; the wrapper never double-injects.

Verb classification (err toward WRITE on ambiguity):

| Group | Classified WRITE when subcommand / form is… |
|---|---|
| `pr` | create·edit·merge·comment·close·reopen·ready·review |
| `issue` | create·edit·comment·close·reopen·lock·unlock·delete·transfer·pin·unpin·develop |
| `release` | create·edit·delete·upload |
| `repo` | create·edit·delete·archive·unarchive·rename·fork·sync·set-default |
| `label` | create·edit·delete·clone |
| `gist` | create·edit·delete·rename |
| `secret`/`variable` | set·delete·remove |
| `workflow`/`run`/`cache`/`gpg-key`/`ssh-key` | run·enable·disable / cancel·rerun·delete / delete / add·delete |
| `api` | `--method`/`-X` in {POST,PATCH,PUT,DELETE}; OR a request body (`-f/-F/--field/--raw-field`, or `--input <file>`) with no explicit GET (gh defaults those to POST); OR **`api graphql`** (mutations are hard to tell from queries — graphql defaults to the bot) |
| everything else (reads, `gh auth`, `status`, `search`, …) | pass through |

Scope: the wrapper is **inert for the watcher** (it runs with
`WATCHER_WINDOW` set and presets `GH_TOKEN` inline, so its
deterministic `gh` calls — including `snapshot_mentions`'
intentional user-PAT `gh api graphql` — short-circuit straight to
the real `gh`) and **inert for the operator's own interactive
shells** (they use `locals-env`'s PATH-only mode, which never
prepends the wrapper dir). A PreToolUse backstop
(`monitor/hooks/gh-write-guard.sh`) WARNS (does not block) if a `gh`
write bypasses the wrapper via `command gh` / an absolute path with
neither a token nor `GH_IMPERSONATE`.

## Impersonating the operator — the loud opt-in

For the one legitimate case — an **external** repo with NO bot
install (`TrigosTeam/*`, `<your-institution>/*`, third-party), where the
operator has explicitly authorised posting as themselves — opt in
loudly:

```bash
GH_IMPERSONATE=1 GH_IMPERSONATE_REASON="external repo, no bot install; operator OK'd" \
  gh issue comment -R TrigosTeam/foo 5 --body-file note.md
```

A reason is **required** (the shim refuses without one), and every
impersonated call is appended to `monitor/.state/impersonate.log`.
A `--dangerously-impersonate` pseudo-flag is an equivalent trigger
(stripped before `gh` sees it). Note the auto-inject already makes
this case self-correcting: a bot token 404s on a repo it can't see,
so the default fails loud and nudges you toward the conscious
opt-in.

## Why

GitHub mutes mobile push notifications for actions taken by the
recipient's own account. Any PR opened, issue created, or comment
posted as `@<user>` silently fails to notify `@<user>` — defeating the
whole point of the GitHub-issues control surface. The bot has its own
account (`<bot>[bot]`), so its writes always wake the user.

The bot also gives the watcher's eligibility filter a clean signal:
only comments authored by `github.user_login` are surfaced to the
monitor agent, so bot-authored content can never be mistaken for a
directive.

## `ng` verb table

Run from the nexus root (`monitor/ng <verb> ...` or
`./monitor/ng ...`). All verbs auto-mint the bot token.

| Subcommand | Purpose | Stdout on success |
|------------|---------|-------------------|
| `ng pr create --head <branch> [--base main] --title "…" --body-file b.md` | Open a PR | PR URL |
| `ng pr edit <n> [--title "…"] [--body-file b.md]` | Edit a PR | PR URL |
| `ng pr merge <n> [--squash\|--merge\|--rebase] [--delete-branch]` | Merge a PR | merge SHA |
| `ng pr view <n>` | Brief PR summary | `#<n> state=… author=… title=…` |
| `ng issue create --title "…" --body-file b.md [--label foo]…` | Create an issue | issue URL |
| `ng issue comment <n> --body-file b.md` | Comment on an issue | comment URL |
| `ng issue close <n> [--comment "…"]` | Optional comment, then close | `CLOSED` |
| `ng issue <n>` | One-line issue summary | `#<n> state=<STATE> title=<title>` |
| `ng reply <n>` | Same as `issue comment`, body from stdin | comment URL |
| `ng react <comment-id> <eyes\|rocket>` | Single reaction POST | (silent — see "react silence" below) |
| `ng process <comment-id>` | Eligibility check + eyes + fetch body | `issue=<n>` / `author=<login>` / `body<<EOF` … |
| `ng dashboard get` | Fetch overview-issue dashboard middle | dashboard markdown |
| `ng dashboard put [--body-file <path>]` | Splice + PATCH dashboard | issue URL |
| `ng upload <local-path> [--issue N] [--repo-path <path>] [--shape pin\|latest] [--message <msg>]` | Commit a file to the nexus asset repo's `main` and print a SHA-pinned URL that renders in any logged-in browser | asset URL pinned to the post-push SHA |
| `ng fetch-asset <user-attachments URL> [--out PATH] [--image-only]` | Download a `github.com/user-attachments/...` asset via the user's PAT (the bot's installation token 404s on this surface). Default `--out` is `monitor/.state/assets/<asset-id>.<ext>` | `path=…` / `content_type=…` / `bytes=…` |
| `ng watcher-status` | One-shot watcher liveness summary | key=value block |
| `ng log-action <agent> --event <name> [--note <t>] [--extra k=v]…` | Append one JSONL action-trace line | (silent) |
| `ng wrap-up <issue> <report-path> [--trigger-comment <id>] [--repo <owner/name>] [--retain <reason>\|--no-retain]` | Universal end-of-task hand-off: uploads the report, posts a templated link comment, rockets the trigger comment, logs the wrap-up, AND auto-logs a `window-retain` event for the source tmux window (reason `wrap-up-<YYYY-MM-DD>` unless `--retain` overrides; `--no-retain` opts out). The retain mutes the wrapped row for `monitor.retain_ttl_seconds` (default 24 h) so the orchestrator can `claude --continue` against a follow-up user comment instead of spawning a fresh worker every time. | per-step status lines on stdout |

### `react` silence

`ng react` exits 0 on success but prints nothing on the happy path —
trust the exit code. There's a documented friction request to add a
`reacted <content> on comment <id>` confirmation; until then, scripts
must check `$?` rather than parsing stdout.

### Verbs landing soon (`<operator>/ng-omnibus`, not yet merged)

- `ng preflight <repo>` — hits `/installation/repositories` and prints
  whether the bot is installed on the target repo. Lets cross-repo
  writes fail fast instead of returning a confusing GraphQL 403.
- `ng show <comment-id>` — read-only fetch that bypasses the eligibility
  filter, so an agent can quote a prior bot-authored comment.
- `--repo OWNER/NAME` flag on `ng pr ...` and `ng issue ...` —
  retargets the verb at a sibling <your-org> repo without falling back
  to raw `gh api`.

Until these merge, cross-repo writes use the `GH_TOKEN=…` escape
hatch below.

## Embedding local files (the asset-repo rule)

GitHub readers cannot see anything outside `main`. Bare paths to local
files — `reports/<file>.md`, scratch images, PDFs — render as broken
links on github.com. Upload to the asset repo first.

```bash
url=$(./monitor/ng upload reports/<your-report>.md --issue 104)
# in the comment body:  [full report]($url)

url=$(./monitor/ng upload path/to/figure.png --issue 104)
# in the comment body:  ![figure]($url)
```

`ng upload` commits the file to the asset repo's `main` branch under
`assets/<path>` and prints a SHA-pinned URL pointing at the
post-push commit. Two URL shapes by extension:

- `.md` / `.ipynb` → `https://github.com/{owner}/{repo}/blob/<sha>/<path>` (renders as a page on github.com).
- everything else → `https://github.com/{owner}/{repo}/raw/<sha>/<path>` (same-domain redirect to a viewer-session-bound signed CDN URL — the embed-friendly shape).

Both URLs pin to the SHA at upload time, so subsequent pushes to the
same path do NOT change what the URL resolves to. Permalinks survive
overwrites. Pass `--shape latest` to emit a `main`-branch URL instead
(useful when you genuinely want "current head" semantics).

Three defaults worth knowing:

- **`--issue N` routes to `assets/N/`.** Pass `--issue 104` for an
  asset that belongs to issue `#104`; the file lands at
  `assets/104/<basename>`. The per-issue subtree keeps related
  artefacts together.
- **`reports/` auto-clusters at `assets/reports/`** when no
  `--issue` is given. Sources whose path contains `reports/` keep
  the `assets/reports/<basename>` placement.
- **Everything else lands at `assets/general/<basename>`** — non-
  issue-tied figures, lab diagrams, branding, etc.

Override the default destination with `--repo-path foo/bar.png` for
fine control. The push always lands under `assets/`; the loader
prepends if you omit it.

What **not** to use: `raw.githubusercontent.com/...` (wrong-domain
cookies on private repos), `data:` URIs in `<img>` (sanitiser strips
them), signed Contents-API `?token=` URLs (5-min TTL), release
assets (anonymous 404), and bare repo paths to gitignored content
(404 on github.com). The legacy wiki shape
(`github.com/.../wiki/status-assets/...`) still resolves for the
URLs already in the corpus, but new uploads should use the asset
repo.

## Reading user-pasted assets (the `fetch-asset` rule)

`ng upload` is for **outbound** local-file → renderable-URL embedding.
The opposite direction — a user pastes an image into an issue/PR
comment, GitHub stores it at `https://github.com/user-attachments/{assets,files}/<uuid>`,
and an agent needs to read the bytes — uses `ng fetch-asset`.

```bash
./monitor/ng fetch-asset \
    'https://github.com/user-attachments/assets/<uuid>'
# → path=monitor/.state/assets/<uuid>.png content_type=image/png bytes=42364
```

The bot's installation token returns 404 silently on
`user-attachments` URLs — this surface is scoped to user-OAuth only,
which is why the verb deliberately reads the user's `gh auth token`
PAT instead of going through the `api()` helper. Default output path
is gitignored under `monitor/.state/assets/`. Use `--image-only` to
refuse non-`image/*` content-types upfront (exit 4).

There is **no upload counterpart** — GitHub does not expose a
documented REST or GraphQL endpoint to write to `user-attachments`.
For agent-originated images that need to render in a comment, use
`ng upload` (asset repo) instead.

## Installing private repos from R / Python

See `skills/nexus.private-package-install/SKILL.md`. The bot's
installation token 404s silently on `remotes::install_github`
and `pip install git+...` for private repos; bootstrap scripts
must use the user's OAuth via
`GITHUB_PAT="$(gh auth token)"` (R) /
`GITHUB_TOKEN="$(gh auth token)"` (Python), and fail loudly
when unset rather than letting the bot token take over.

## Cross-repo writes (the `GH_TOKEN` escape hatch)

For repos `ng` doesn't yet target with `--repo`, mint the token
inline:

```bash
GH_TOKEN=$(./monitor/mint-token.sh) gh pr create \
  --repo <your-org>/<repo> \
  --head <branch> --base main \
  --title "…" \
  --body-file body.md
```

Same for `gh issue create`, `gh issue comment`, `gh api ...`.

> **`gh api` body-from-file gotcha — `-F`, never `-f`.** The `@file`
> load-from-file syntax works ONLY with `-F`/`--field` (capital). With
> `-f`/`--raw-field` (lowercase) the value is sent **verbatim**, so
> `gh api … -f body=@note.md` posts the literal string `@note.md` — the
> file is never read. (`gh api` has no `--body-file` flag; that's a
> `gh pr`/`gh issue` convenience.) Correct forms:
>
> ```bash
> # capital -F reads the file:
> GH_TOKEN=$(./monitor/mint-token.sh) gh api \
>   repos/<your-org>/<repo>/issues/<n>/comments -F body=@note.md
> # or inline-expand and keep lowercase -f:
> GH_TOKEN=$(./monitor/mint-token.sh) gh api \
>   repos/<your-org>/<repo>/issues/<n>/comments -f body="$(cat note.md)"
> ```
>
> For the nexus repo, prefer `ng issue comment <n> --body-file note.md`,
> which sidesteps the trap entirely. Always re-fetch and eyeball the
> rendered body after a raw-`gh api` post — a stray `@path` body is the
> tell that `-f` swallowed the literal.

### Bot install scope caveat

The bot is a GitHub App; it can only act on repos it's installed on.
At time of writing it covers a subset of `<your-org>/*` (the nexus repo
plus a handful of project repos that have been individually opted
in). Cross-repo writes to **uninstalled** repos return:

- HTTP 403 `Resource not accessible by integration`, or
- a misleading GraphQL error `Could not resolve to a Repository`.

If you hit either on a <your-org> repo, the bot is not yet installed
there. Surface it as a blocker:

1. Push your branch under the user's identity (`git push`) so the
   work isn't lost.
2. Record it in your final report's `## Infrastructure Issues`
   section with the repo name and command that failed.
3. The user / org admin expands the App's repo scope (one click in
   the App settings page); a follow-up agent can then open the PR.

## Fix at the source — don't wrap upstreams the lab/operator owns

Before adding a workspace wrapper around a tool, check the
tool's GitHub org. If it's lab-owned (`<your-org>/*` always) or
operator-owned (`<operator>/*` when this nexus is operated by
<operator>), open the upstream issue + PR there instead. Wrappers
ship fixes in disguise — the upstream stays broken for everyone
else, and the workspace has to carry the wrapper forward forever.

Identity follows the existing routing: `<your-org>/*` is bot;
`<operator>/*` is user (the bot is not installed there). For
third-party orgs (`TrigosTeam/*`, `<your-institution>/*`, others) a
stop-gap is acceptable when upstream is slow, but file the
issue upstream too and document inside the wrapper which
upstream issue would retire it.

`monitor/labsh-attach` was the cautionary tale (katosh/labsh#3
— should have been an upstream subcommand from the start).

## Pushing to an existing PR branch (verify author first)

Especially for forks: before `git push`-ing to a branch attached to
an existing PR you didn't open, check who owns the head and whether
maintainers can modify. Use the **REST** form — `gh pr view --json`
hits the GraphQL bucket (shared, frequently exhausted on busy days),
while the REST core bucket is essentially empty:

```bash
GH_TOKEN=$(./monitor/mint-token.sh) gh api "/repos/<owner>/<repo>/pulls/<n>" \
    --jq '{author: .user.login, headRepositoryOwner: .head.repo.owner.login, maintainerCanModify: .maintainer_can_modify}'
```

If the head repo isn't yours and `maintainerCanModify` is false, you
cannot push there — ask the author to push, or open a new PR from
your own branch. Don't discover this from a rejected push five
minutes in.

**Prefer REST over GraphQL whenever the data is reachable.** The bot
installation's GraphQL bucket (5,000 pts/hr, shared across
orchestrator + watcher + every active worker) regularly exhausts on
busy days; the REST core bucket sits ~99% unused. `gh api /repos/...`
is REST; `gh api graphql ...` and `gh pr view --json` /
`gh issue view --json` / `gh search` are GraphQL. Reach for the
REST shape unless you genuinely need a deeply nested traversal or a
search query (full-text/`is:issue`/`mentions:`) that REST can't
express.

## The fail-loud rule (security boundary)

`mint-token.sh` returning empty MUST exit non-zero — never let
`GH_TOKEN=""` fall through to the user's cached `gh` auth. An empty
`GH_TOKEN` is treated by `gh` as "no override", so the API call
silently runs as the user. If the user happens to have the right
scope, the action succeeds — posted as `@<user>`, not `@<bot>` —
and the user-side notification is muted. The bot/user identity
boundary is silently breached.

Two defenses in scripts that mint tokens:

```bash
GH_TOKEN=$(./monitor/mint-token.sh) || { echo "mint-token failed" >&2; exit 1; }
[ -n "$GH_TOKEN" ] || { echo "empty GH_TOKEN — refusing to run" >&2; exit 1; }
gh <whatever>
```

Don't pipe `mint-token.sh` straight into `GH_TOKEN=$(...)` without
checking — the script is also CWD-sensitive, and a silent empty
return from a non-nexus-root cwd is the most-cited security-relevant
foot-gun in the workspace report corpus.

## See Also

- `nexus.worker-defaults` — every-worker safety floor that points
  at this skill for GitHub-write detail. Workers land here from
  there.
- `nexus.tmux-spawn` — how to delegate work into a tmux window so the
  spawned agent inherits this skill cleanly.
- `nexus.report` — the report convention; the `## Infrastructure
  Issues` section is the right place to flag bot-install gaps,
  missing `ng` verbs, and any other tooling friction.
- `nexus.self-fix` — cross-fork ping discovery (`gh search repos
  topic:nexus-fork`) and the cross-fork PR body convention. Loads
  only for nexus-internals work, not general project agents.
  (Post-cutover the canonical implementation is single-tenant
  `<your-org>/nexus-code`; the topic-discovery path is legacy from
  the pre-split era when each operator forked the code repo.)
- `monitor/README.md` (in the nexus root) — full architecture, GitHub
  interaction model, the eligibility filter, env-var override table.
- `monitor/agent-prompt.md` — the launch prompt for the monitor
  agent itself; references the same `ng` verbs.
