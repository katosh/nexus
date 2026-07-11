# Security

This page is the threat model, the eligibility filter that bounds the
bot's authority, and the three-tier authorization taxonomy that
governs every GitHub write a nexus agent attempts. It is also the
place to start if you suspect compromise.

!!! warning "Best-effort, not a security product"
    nexus orchestrates AI coding agents that run with full code
    execution inside [agent-sandbox](https://github.com/katosh/agent_sandbox).
    The sandbox provides kernel-enforced filesystem isolation; nexus
    adds an identity, authorization, and audit layer on top. The
    composite is not a security product in any regulated sense, and
    comes with no guarantees. The scope below names what the design
    *claims* to enforce — anything beyond that is out of scope.

For reporting a vulnerability, see [Reporting a vulnerability](#reporting-a-vulnerability)
below or the repo-root [`SECURITY.md`](https://github.com/<your-org>/nexus-code/blob/main/SECURITY.md).

## Threat model

### What nexus claims to enforce

- **Single-driver authority.** Only comments authored by the
  configured GitHub login (`github.user_login`) can drive the bot.
  Any other login posting in the same issue is silently ignored,
  even with repo write access.
- **Bot-cannot-self-drive.** The bot has its own `[bot]` account,
  excluded from the directive stream by author. There is no
  body-prefix convention to forget or get wrong.
- **Per-action audit trail.** Every meaningful bot action emits a
  line to `monitor/.state/action-log.jsonl` and (for paste-to-target
  events) to the watcher log. Every wrap-up is recorded as a
  structured event.
- **Bounded write surface.** The bot's installation token can only
  resolve repos the App is installed on, and only at the granted
  permission level. Three-tier authorization (below) layers on top
  of GitHub's own permission model with a user-go-ahead requirement
  for external public repos.
- **Sandbox-bounded execution.** Every Claude Code session runs
  inside agent-sandbox, with writable paths limited to the project
  directory and `~/.claude/`. Workers cannot mutate the watcher,
  the orchestrator's process, or anything outside their sandbox
  directory.

### What nexus does NOT enforce

- **Network isolation.** Agents have outbound network access (they
  need it to talk to the Anthropic API and GitHub). The watcher
  does not isolate this. See agent-sandbox's
  [security model](https://katosh.github.io/agent_sandbox/reference/security/)
  for the underlying network posture.
- **Confidentiality of report bodies.** Reports live in `reports/`
  on the host (gitignored, never pushed to the code repo), and on
  the asset+issue repo's `main` branch (private, but anyone with
  read access to the asset repo sees them). Treat the asset+issue
  repo as the disclosure boundary.
- **Protection against a compromised host.** Anyone with shell
  access to the watcher host can read `~/.claude/<bot-slug>.pem`,
  forge installation tokens, and act as the bot. Host security is
  out of scope; see [Host security](#host-security) for the bare
  minimum.
- **Protection against a malicious GitHub App admin.** The App
  owner (org admin or personal account owner) can rotate the
  private key, broaden the permission set, or install on additional
  repos. The bot's authority is bounded by the App's owner, full
  stop.
- **Resistance to prompt injection in user comments.** A determined
  attacker who *is* the configured `github.user_login` can pass
  anything they want into the orchestrator. The eligibility filter
  is identity-based, not content-based.

## The eligibility filter

The watcher's `snapshot_github` function in
[`monitor/watcher/_github.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/_github.sh)
is the security boundary. A comment is surfaced to the orchestrator
**only if all three** of these hold:

1. `comment.author.login == github.user_login`
2. The comment has **no** `eyes` (👀) reaction from any non-user
   login.
3. The comment has **no** `rocket` (🚀) reaction from any login.

Translation:

- **Identity check** rejects everyone except the configured user.
  No other repo collaborator can drive the bot, regardless of their
  GitHub permission level on the asset+issue repo.
- **Eyes-reaction dedup** prevents the bot from re-processing a
  comment it has already acknowledged.
- **Rocket-reaction dedup** prevents reprocessing after action is
  taken; a self-rocket by the user on their own comment is the
  one-tap mobile opt-out ("skip this").

The filter runs inside the GraphQL query plus a local `jq` step,
before any comment reaches the orchestrator. A directive that gets
through has, by construction, originated from the configured user
and has not yet been handled.

GitHub's eight reaction types are
`+1 -1 laugh confused heart hooray rocket eyes`. The watcher uses
exactly two:

- `eyes` from the bot = "agent has seen this and is processing"
- `rocket` from the bot = "action taken"
- `rocket` from the user on their own comment = "skip this" (mobile
  opt-out)

Any of these three signals marks a comment processed.

### Why this is structural, not conventional

Many bots use a body-prefix convention like `/bot please do X`. That
shape is fragile: anyone with repo access can post the prefix, and
the bot's own outputs can accidentally re-trigger it. The
author-based eligibility filter is structural:

- Only one specific GitHub login can drive the bot.
- The bot account is, by definition, not that login.
- No content the bot writes can re-enter as a directive.

If you change the configured user (`github.user_login`), every
existing directive thread loses its driver — useful as a hard kill
switch, but mind the downtime.

## Authorization: the three-repo-tier taxonomy

The eligibility filter answers **WHO** can drive the bot (always the
configured user). The three-tier taxonomy answers **WHETHER** a given
write should land — that depends on the target repo's tier, because
the user's standing approval is bounded by visibility and ownership.

Defined in [`CLAUDE.md`](https://github.com/<your-org>/nexus-code/blob/main/CLAUDE.md)'s
"GitHub writes — identity and authorization" section, the taxonomy
governs every PR, issue, comment, reaction, or asset upload an agent
considers.

| Tier | Examples | Rule |
|---|---|---|
| **Internal** | `<your-org>/*` repos you own, private collaborator repos | No fresh approval per action. Standing approval covers writes within the scope of the work the user initiated. |
| **User-public** | Your own public repos (`<your-handle>/<personal-project>`, etc.) | Standing approval for ongoing work the user explicitly initiated; **new directions** need a fresh user ack. |
| **External public** | Third-party repos (other orgs, public forks of upstream projects, foundation/consortium repos) | **Every push, PR, issue, or comment needs a fresh, specific user go-ahead.** Worker prompts default to "draft + STOP for review", never auto-submit. Before any external-public write, drafts are grepped for internal identifiers (lab names, study names, sample IDs, internal-repo refs) and redacted. |

**Visibility, not ownership, decides.** A public fork of an upstream
project owned by the same user as the asset+issue repo is still
external-public, because the writes are world-visible.

The orchestrator picks the tier at worker-spawn time and surfaces the
relevant rule into the worker's prompt — workers act on their
target's rule, not the whole taxonomy. See
[Operating → Spawning workers](../operating/spawning-workers.md) for
the spawn-time mechanics.

### Why the tier matters

Internal-tier writes are routine: the user has standing approval to
direct work on their own repos, and the audit trail in
`action-log.jsonl` plus the bot's authorship makes every action
attributable.

External-public writes are different. A bot-authored issue on a
third-party repo:

- Is visible to the world the instant it's posted.
- Can leak internal artefacts (lab names, study names, internal
  paths, sample IDs) if the draft hasn't been scrubbed.
- Affects a maintainer who never opted into hosting an AI agent's
  output.

The "fresh ack per external-public write" rule forces the user to
review the exact draft before it lands. The redaction grep catches
common slips before the user sees them.

## Identity: who posts every write

Two channels, both bot-identity:

1. **`monitor/ng <verb>`** — preferred for writes to the asset+issue
   repo (`github.repo`). Mints the bot token internally, picks up the
   target repo from `config/nexus.yml`, hides the verbose `gh api`
   JSON.
2. **`GH_TOKEN=$(./monitor/mint-token.sh) gh <verb>`** — for
   cross-repo writes, or verbs `ng` doesn't yet cover. Setting
   `GH_TOKEN` makes `gh` use the bot token instead of the user's
   cached auth.

The only GitHub interactions that may still use the user's identity
are `git commit` and `git push` — commit authorship stays the user's
on the commit graph, which is desirable for human-readable history.

### Why bot identity, not user identity

GitHub mutes mobile push notifications for actions taken by the
recipient's own account. A PR opened, issue created, or comment
posted as `@<user>` silently fails to notify `@<user>` — defeating
the whole point of the GitHub-issues control surface. The bot
identity ensures every action wakes the user's phone.

The eligibility filter relies on the same property in reverse: the
bot's own writes are author-excluded from the directive stream, so
the bot cannot accidentally drive itself.

The full rule, including which verbs to use for which channel, lives
in [`skills/nexus.bot/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.bot/SKILL.md).
Every worker reads this skill before any GitHub write.

## Audit trail

Every meaningful action surfaces in one of three places:

- **`monitor/.state/action-log.jsonl`** — append-only JSONL. One line
  per processed comment, dashboard update, asset upload, wrap-up
  event, or watcher respawn. Schema: `{ts, agent, event, ...}` with
  reserved keys; `monitor/ng log-action` is the canonical writer.
- **`monitor/.state/watcher.log`** — append-only watcher activity:
  startup, every emit, paste-to-target outcomes, respawns,
  rate-limit alerts. Plain text.
- **`monitor/.state/watcher-alerts.log`** — `[iso] WARN <surface> ...`
  one-line entries for GraphQL failures, rate-limit hits, and other
  surface-specific anomalies. See
  [Monitoring](monitoring.md#watcher-alerts) for inspection recipes.

Combined with GitHub's own audit (the bot's authorship appears on
every action visible in the UI), these three files cover every state
mutation the system performs.

## Compromise: revoke fast

If you suspect the bot is compromised — leaked `.pem`, leaked token,
unexpected actions in the audit trail — revoke first, diagnose
second.

### Revocation order (fastest first)

1. **Uninstall the App** from the asset+issue repo at
   `https://github.com/settings/installations` (or the org URL). This
   invalidates every outstanding installation token immediately. The
   bot cannot write to anything until you reinstall.
2. **Rotate the private key** on the App settings page (Generate a
   private key → delete the old one). Invalidates any in-flight JWT
   signed with the old key. Even if a clone of the pem leaked, the
   attacker cannot mint new tokens after this.
3. **Stop the watcher** to prevent it from re-minting and racing
   you:

    ```bash
    monitor/svc.sh stop watcher
    # The coordinator window is NOT always named `orchestrator` — resolve it,
    # or the kill silently hits nothing and the session keeps running.
    tmux kill-window -t "$(config/load.sh monitor.target_window orchestrator)"
    ```

4. **Audit the action log** for the suspect window:

    ```bash
    jq 'select(.ts >= "2026-05-10T00:00:00")' \
        monitor/.state/action-log.jsonl
    ```

    Cross-reference against GitHub's own activity feed for the bot
    account (`https://github.com/apps/<bot-slug>`).

5. **Reinstall** when ready (re-do
   [GitHub App → Step 7](github-app.md#step-7-install-the-app-on-your-assetissue-repo))
   with the new key in place, then restart the watcher.

### Common compromise vectors

- **Leaked `.pem`** — committed by mistake, shared in a paste, copied
  to a less-trusted host. Rotation is the only fix; the file's value
  is the secret.
- **Cached installation token leaked** (`~/.claude/.nexus-bot-token.json`).
  Less severe: tokens expire ~1 h. Rotation of the pem invalidates
  them earlier.
- **Webhook secret leaked** — currently informational
  (see [GitHub App → Webhook secret](github-app.md#step-3-webhook-secret-and-smee-channel)).
  Rotate when convenient. Becomes load-bearing if a self-hosted
  receiver verifies HMAC signatures locally.
- **`config/nexus.yml` leaked** — contains App ID, installation ID,
  and paths to secrets but not the secret values themselves. The
  values reveal the install topology but no auth material. Treat as
  hygienically as you would config-with-IDs in general.

## Host security

The bot's authority is bounded by the host's authority. Bare-minimum
host hygiene:

- The watcher host should be a host you control end-to-end. Shared
  development boxes where other users have shell access are a poor
  fit — anyone with the same UID can read `~/.claude/`.
- `~/.claude/<bot-slug>.pem` must be `chmod 600`. Anything looser is
  rejected by `monitor/mint-token.sh` with `"private key not found"`.
- `config/nexus.yml` is `chmod 600`. The file isn't strictly secret
  (no auth material), but the perm keeps it consistent with the pem
  and token cache.
- Notification secrets follow the same pattern:
  `~/.claude/.nexus-pushover-app-token`,
  `~/.claude/.nexus-pushover-user-key`,
  `~/.claude/.nexus-notify-token` — all `chmod 600` (or `0400`).
- Agents run inside [agent-sandbox](https://github.com/katosh/agent_sandbox).
  The watcher and the orchestrator both run sandboxed. Workers
  spawned via `monitor/spawn-worker.sh` inherit the sandbox boundary.
  Filesystem writes outside the project directory and `~/.claude/`
  are blocked at the kernel level.

## Reports and asset embedding

Reports under `reports/` and other locally-referenced files are
**gitignored** in the code repo. A worker that posts a comment like
`see reports/foo.md` produces a broken link on github.com — the
file is on no branch.

The fix is `monitor/ng upload <path>`, which commits the file to the
asset+issue repo's `main` branch under `assets/...` and prints a
SHA-pinned URL. The URL renders for anyone with read access to the
asset+issue repo, both desktop and mobile.

A CI workflow (`.github/workflows/check-no-reports-leaked.yml`) fails
any PR that adds a file under `reports/` to the code repo (other than
the `.gitignore` itself). The guard exists because a stray report
leaked in PR `#40` before the gitignore existed.

### External-public posting hygiene

Before any external-public write (PR, issue, comment, asset
reference), grep the draft for internal identifiers:

- Lab names, group names, internal team names.
- Study names, sample IDs, treatment names, cohort identifiers.
- Internal-repo references (`<your-org>/internal-tool`, `<your-org>/private-asset-repo`).
- Cell counts, sequencer IDs, anything operationally identifying.

The orchestrator's worker prompts for external-public targets include
this redaction step as a checklist item. Workers default to "draft
and STOP for review" on external-public; nothing auto-submits.

## Reporting a vulnerability

**Do not open a public issue for security vulnerabilities.**

Use GitHub's [private vulnerability reporting](https://github.com/<your-org>/nexus-code/security/advisories/new)
on `<your-org>/nexus-code` to submit a report. This keeps the details
confidential until a fix is available.

In scope for the nexus codebase specifically:

- The bot posting as the user (eligibility filter bypass).
- The watcher reading or writing repos it isn't installed on.
- The agent escaping its sandbox directory (delegate to the
  agent-sandbox project — this is a layered-isolation failure).
- The App pem leaking off the host (configuration default that
  loosens perms, write-out path that doesn't `chmod 600`).
- The audit trail being silently incomplete (action that should
  emit a log line but doesn't).
- Worker code being trickable into running on the wrong repo
  (`config/nexus.yml` resolution misbehaviour, `git remote` confusion).

Out of scope (documented as accepted trade-offs):

- Network exfiltration by an agent — agents need outbound network for
  the Anthropic API; isolation is not currently in scope.
- A malicious GitHub App owner — the App owner is the trust root.
- Anything that requires shell access to the watcher host — that's
  game-over by construction.

Please include:

- A minimal reproducer or step-by-step trace.
- Which version (or commit SHA) you reproduced against.
- The expected vs observed behaviour.
- Your assessment of impact and a suggested mitigation if you have
  one.

Response expectations:

- **Acknowledgment** within 1 week. The project is hobbyist-scale;
  best-effort.
- **Triage** as soon as practical.
- **Coordinated disclosure** with the reporter. If the issue cannot
  be fixed quickly, it lands here as a documented known limitation
  with mitigations.

## Related

- [GitHub App](github-app.md) — App creation, permission grants,
  install scope.
- [Repos](repos.md) — public/private split, what's gitignored.
- [Monitoring](monitoring.md) — log locations, watcher health probes,
  silent-failure detection.
- [Operating → Spawning workers](../operating/spawning-workers.md) —
  how worker prompts pick up the tier at spawn time.
- [Reference → Watcher protocol](../reference/watcher-protocol.md) —
  the eligibility filter's implementation details.
- [`skills/nexus.bot/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.bot/SKILL.md)
  — the worker-facing rule for every GitHub write.
- agent-sandbox [security model](https://katosh.github.io/agent_sandbox/reference/security/)
  — the sandbox layer underneath every nexus session.
