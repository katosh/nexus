---
description: "Fixing the nexus itself — orchestrator, watcher, monitor scripts, skills, BOT_ADMIN_GUIDE. Pre-flight gate (freshness + substantiation + scope) before filing on <your-org>/nexus-code. Covers cross-fork ping discovery and (future) `ng propagate` for fork-fan-out."
---

# nexus.self-fix — bug-fixing the nexus and propagating across forks

TRIGGER when: agent is about to file an issue on
`<your-org>/nexus-code` or propose a nexus-self fix; agent is editing
files under `monitor/`, `skills/`, or the workspace `CLAUDE.md`;
agent is investigating a nexus-infra bug (watcher silently dropping
deliveries, eligibility filter misclassifying, `ng` verb
misbehaving); agent needs to propagate a nexus-internals fix to
sibling fork repos.

This skill is **nexus-self-only**. Project agents (kompot,
perturb-bench, fig4-subtle-de, etc.) doing GitHub writes against
their own work should rely on `nexus.bot` instead — cross-fork
discovery and propagation are nexus-bug-fix concerns, not general
GitHub-write concerns.

## Before filing an issue or proposing a fix

Self-improvement is high-leverage but easy to misfire — a
mis-scoped issue or a stale-checkout repro burns the operator's
triage budget and pollutes the tracker. Run these four checks
before opening an issue on `<your-org>/nexus-code` or authoring a
self-fix PR.

1. **Pull before you claim.** `git fetch origin && git pull
   --rebase origin dev` on the clone you're diagnosing from,
   then cite the SHA (`git rev-parse HEAD`) in the issue body.
   `dev` is the nexus-code integration branch — diagnose
   against it, and base self-fixes on it, not `main` (which is
   promoted from `dev` separately, on an operator-gated soak).
   A repro against a stale checkout proves nothing about
   current behavior — "filed against already-fixed code" is a
   recurring false-positive when an agent's clone lags
   `dev`.

2. **Substantiate the repro.** The issue body must carry:
   - Exact command(s), copy-pasteable.
   - Expected vs observed output as literal bytes, not
     paraphrase.
   - The SHA the repro ran against.
   - The file and line in nexus-code identified as
     responsible. Can't point to the code? The issue is not
     ready — keep investigating.

3. **Scope gate — is this nexus-specific?** Apply the mental
   test: *Would the same symptom occur in a clean shell with
   no nexus involvement?* If yes, the venue is the upstream
   project, not nexus-code. Common false positives that have
   landed as nexus-code issues and shouldn't have:

   | Upstream surface | Symptoms misread as nexus-bugs |
   |---|---|
   | Claude Code Bash tool | cwd persistence between calls, pane render, autosuggest, `settings.json` semantics |
   | `gh` CLI version drift | `gh 1.13.0` (base image) missing flags / different error messages than `gh 2.x`. **But WHICH client the wrapper selects is ours** — that half is `#755`, and it is a nexus-code bug, not an upstream one |
   | tmux platform quirks | window-name parsing, `remain-on-exit`, `automatic-rename` interactions |
   | Anthropic API behavior | rate limits, token counting, prompt cache hits, cache TTL |
   | Linux kernel | Landlock ABI, user namespaces, seccomp filters |

   If upstream is at fault: file there (Anthropic, `cli/cli`,
   `tmux/tmux`, the relevant kernel surface), or document the
   host-side workaround on the operator's instance — **don't**
   absorb into nexus-code core docs or the auto-injected
   worker floor. If you genuinely believe nexus-code's
   *integration with* the upstream tool is wrong (the wrapper
   carries an avoidable error path, the watcher misuses an
   API), the issue body must make the nexus-specific dimension
   explicit and substantiate it on its own merits.

4. **Read the relevant docs first.** Grep `docs/`,
   `monitor/README.md`, `skills/`, `monitor/agent-prompt.md`,
   and `CLAUDE.md` for existing coverage before claiming a
   feature is missing or a knob doesn't work. Cite the doc you
   checked in the issue body. Coupled with check 1, this
   catches the stale-checkout-against-recently-added-feature
   failure mode.

Each check is a verifiable action (run the command, paste the
SHA, name the file). Pass all four before opening the issue or
the PR — not posture, output.

## Opening the self-fix PR — base `dev`, gated merge

Once the four checks pass and you have a fix, open the PR
against **`dev`** (`--base dev`), never `main`. `dev` is the
integration branch where self-fixes soak; `main` is promoted
from `dev` separately, on an operator-gated soak, so a self-fix
that targets `main` directly jumps the integration step.

**Do NOT merge your own self-fix PR.** The merge is gated, not
autonomous. After opening the PR (base `dev`), wait for an
explicit OK from the current code owner OR a direct
confirmation from the operator before merging. A self-fix
touches the very machinery every operator runs — letting the
authoring agent self-merge removes the one human checkpoint
that catches a plausible-but-wrong infra change before it fans
out. Open it, link it, and stop; the code owner or operator
pulls the trigger.

### Merge-time gotchas

- **CI red because of infra, not code, is an operator-override case —
  not a self-merge license.** When the `dev → main` (or PR) CI is red
  because GitHub Actions is *blocked before any step runs* (billing cap
  hit → jobs rejected in 2–7 s, log shows only "Waiting for a runner…";
  or a runner outage / scoped-token expiry), a **fresh clone of the head
  SHA** run through `monitor/watcher/run-tests.sh --jobs 2` showing a full
  green (e.g. 72/72) is sufficient evidence for the operator to authorise
  the merge. Clone fresh (never the primary clone the watcher reads),
  verify HEAD matches the PR's `headRefOid`, surface the SHA + X/Y
  assertion count, and merge **only** after explicit operator
  authorisation — local-green is evidence, not a self-authorising
  override. Document it in the report's `## What Was Done` +
  `## Infrastructure Issues`. **Never** use this for *code-side* CI
  failures — those need a real fix.

- **A stacked PR whose base already merged does NOT auto-retarget to
  `dev`.** GitHub only auto-retargets an OPEN stacked PR when its base
  merges; if the base (Phase-1) merged to `dev` *before* the stacked
  (Phase-2) commits were pushed onto it, merging the stack lands its
  commits on the already-merged base branch — they never reach `dev`
  (observed: `#379` stranded 4-ahead/14-behind `dev`; recovery was a
  fresh cherry-pick PR). Always verify a stacked PR's commits actually
  reached `dev` after merge:
  `gh api repos/<owner>/<repo>/compare/dev...<stacked-branch> --jq .ahead_by`
  (>0 with the expected commits = stranded). Prefer not stacking on a
  base that may merge first, or land the stack as one PR.

## Watch for sandbox-only test passes

A test that references a nexus-exported env var (`NEXUS_ROOT`, …) **bare
under `set -u`** passes in the sandbox (where the var is exported) but
FAILS on a clean CI runner where it's unset — `set -u` aborts a fixture
heredoc *after* `>` already truncated the target, so emit-body fixtures
render EMPTY and hash to the empty-string SHA-256, silently defeating the
discriminating assertion (sandbox 32/32, CI 31/32). Pin the default in
the harness: `NEXUS_ROOT="${NEXUS_ROOT:-/nexus}"; export NEXUS_ROOT`.
Debugging rule: when a nexus/nexus-code test is green in the sandbox but
red on a clean runner, reproduce with `env -u <VAR> bash test-X.sh`
**before** suspecting a code bug or tool-version drift.

## Upstream-tool defects don't belong in nexus core docs

Distinguish a *nexus-code defect* (fix it here) from an *upstream-tool
defect surfacing in a nexus context* (Claude Code Bash-tool cwd
persistence, `gh` CLI version artifacts, tmux platform quirks). The
latter's home is upstream (file with Anthropic / gh / tmux) plus a
host-side fix if applicable (`brew install gh` for a stale binary) — NOT
a doc PR bolting the workaround into the worker floor, `nexus.bot`, or
other always-loaded core skills, which only dilutes their load-bearing
nexus-specific content. When triaging an issue or a fix proposal, decline
upstream-issue band-aid patches to core docs and explain the root cause +
the upstream/host fix.

## Cross-fork pings (`nexus-fork` topic) — legacy

> **Heads-up — partly obsolete after the asset-repo cutover.** With
> the canonical implementation living at `<your-org>/nexus-code` (every
> operator clones the same repo; `git pull` fans out updates), most
> "propagate this fix to sibling forks" cases now collapse to a
> single PR on `<your-org>/nexus-code`. The topic-discovery path below
> applies to legacy forks that still hold their own copy of the
> implementation, and to per-operator asset+issue repos when an
> operator-specific fix needs sibling-operator awareness.

When a fix in one nexus fork should be propagated to siblings (a bug
that affects every fork's watcher, a doc correction in a shared
skill), enumerate live forks via the `nexus-fork` GitHub topic that
each fork maintainer tags their repo with:

```bash
gh search repos topic:nexus-fork org:<your-org> --json fullName,description
```

This uses **bare `gh`** under the caller's user PAT, not the bot
token: bot installation tokens are scoped per-fork and don't see
sibling forks they aren't installed on. Topic search is read-only
metadata and works for any logged-in user.

For each fork the fix applies to, ping the maintainer in the PR or
issue body:

```
cc @<maintainer> (`<owner>/<repo>`)
```

Listing the repo in backticks alongside the mention disambiguates
multi-fork pings and avoids GitHub's `#N` auto-link surprises if a
number ever creeps in. New forks must run
`gh repo edit <your-org>/<user>-nexus --add-topic nexus-fork` once to
appear in the lookup; see `monitor/BOT_ADMIN_GUIDE.md` step 14.

## Cross-fork PR body convention (for the future `ng propagate` verb)

When opening a cross-fork PR via `ng propagate <PR>`, the PR body on
each target fork should differ from the upstream PR's body. Lead with
a simple, non-technical explanation aimed at the fork's maintainer
(who may not be deep in nexus internals):

```
## What this does for your fork

[1-2 plain-English sentences: this PR brings <fix> from upstream nexus.
 Merging it means <user-visible consequence>. No action required after
 merge beyond the standard `git pull` — the version-aware watcher
 self-restarts onto the new code.]

## Upstream PR

Full technical detail and discussion: <upstream PR URL>.

## What changed (one-line summary per file)

[terse table of file paths + change kind, no implementation depth]
```

Tone: "what merging this does for you" first; "how it works" linked,
not embedded. The upstream PR body is for nexus developers; the
cross-fork PR body is for fork maintainers who want the fix without
becoming nexus-internals experts.

The `ng propagate` verb does not exist yet — this convention is
documented now so the eventual implementation has a target.

## See Also

- `nexus.bot` — general GitHub-write rules (bot identity, `ng` verb
  table, the wiki-upload rule). All cross-fork writes still flow
  through the bot-identity discipline documented there.
- `nexus.report` — the `## Infrastructure Issues` section is where
  nexus-bug findings get recorded for the periodic infra meta-review.
- `nexus.infra-review` — the periodic review that turns infra-issue
  reports into a ranked backlog of nexus self-fixes.
- `nexus.watcher` — *operating* the running watcher (liveness, recovery
  recipes); this skill is for *changing* watcher code.
- `monitor/README.md` — runtime architecture, watcher liveness,
  env-var precedence; the canonical reference when investigating a
  watcher-side bug.
- `monitor/BOT_ADMIN_GUIDE.md` — fresh-fork stand-up walkthrough;
  step 14 is the topic-tag step that makes a new fork discoverable.
