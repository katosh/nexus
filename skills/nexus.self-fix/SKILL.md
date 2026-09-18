---
description: "Fixing the nexus itself — orchestrator, watcher, monitor scripts, skills, BOT_ADMIN_GUIDE. Pre-flight gate (freshness + substantiation + scope + docs + a by-PATH tracker search across issues, open PRs and unmerged branches) before filing on <your-org>/nexus-code. Covers cross-fork ping discovery and (future) `ng propagate` for fork-fan-out. Also: writing or changing a guard or test suite here (fixture-repo preconditions, exit 97), adding a value to an existing field in monitor/ state (a field that SELECTS is not a label), and what each `ng guards-for-diff` exit code does and does not clear before you push under monitor/."
---

# nexus.self-fix — bug-fixing the nexus and propagating across forks

TRIGGER when: agent is about to file an issue on
`<your-org>/nexus-code` or propose a nexus-self fix; agent is editing
files under `monitor/`, `skills/`, or the workspace `CLAUDE.md`;
agent is writing or changing a guard or test suite HERE; agent is
about to write a value into an existing field in `monitor/` state;
agent is about to push under `monitor/` and is reading a
`ng guards-for-diff` exit code;
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
triage budget and pollutes the tracker. Run these five checks
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

5. **Search the tracker by PATH, not by symptom — and search
   all three places work can already be.** Check 2 above already
   made you name the responsible file. Search with it before you
   write a line of the issue body, and cite what you found or
   state that you searched and the count was zero.

   **Why the path and not your description.** Five agents filed
   the same `monitor/force-push-check.sh` defect (`#898`, `#909`,
   `#910`, `#912`, `#920` — three of them inside 39 minutes), and
   each described the mechanism in its own vocabulary: "anonymised
   `To` line", "scp-style remote", "drops `git@`", "user-stripped
   URL". Measured over the whole issue corpus, a **title** search
   on any one agent's own word returns **1 of 5** — only that
   agent's own issue. The **basename** returns **5 of 5**. Symptom
   vocabulary diverges between agents; a path does not.

   Search **title AND body**, never title alone. The basename
   happens to score 5/5 on titles too *for this family*, because
   all five filings named the file in their title — that is a
   property of those five, not of the method. `porcelain` scores
   1/5 on titles and 5/5 on title+body, and body search costs
   nothing extra.

   <!-- BEGIN SELF-FIX-TRACKER-SEARCH -->
   ```zsh
   BASENAME=force-push-check.sh        # the file check 2 made you name
   REPO=<your-org>/nexus-code

   # (a) ISSUES — text, title AND body. `--state all`: a CLOSED
   #     duplicate is still the answer to "has this been reported".
   gh issue list --repo "$REPO" --state all --limit 1000 \
       --json number,title,body \
       -q ".[] | select((.title + \" \" + .body) | test(\"${BASENAME}\";\"i\")) | \"\(.number)\t\(.title)\""

   # (b) OPEN PRs — an EXACT PATH match, not a text search. `gh issue
   #     list` does NOT return PRs, so (a) cannot see a fix in flight.
   gh pr list --repo "$REPO" --state open --limit 200 \
       --json number,title,headRefName,files \
       -q ".[] | select(.files[].path | test(\"${BASENAME}\")) | \"\(.number)\t\(.headRefName)\t\(.title)\"" | sort -u

   # (c) PUSHED BRANCHES WITH NO PR — the case (a) and (b) both miss.
   #     Needs a real fetch first: refs/remotes reads your LOCAL store.
   git fetch --prune origin
   for b in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin | grep -v '/HEAD$'); do
       git merge-base --is-ancestor "$b" origin/dev 2>/dev/null && continue   # already merged (cost filter: its 3-dot diff is empty anyway)
       files=$(git diff --name-only "origin/dev...${b}" 2>/dev/null)
       [ "$(printf '%s\n' "$files" | grep -c .)" -gt 60 ] && continue          # mirror/squash root, not a feature branch
       printf '%s\n' "$files" | grep -q -- "$BASENAME" && printf '  %s\n' "$b"
   done
   ```
   <!-- END SELF-FIX-TRACKER-SEARCH -->

   **All three, not just (a).** Each finds something the others
   cannot, measured on this repo:

   | probe | cost | what only it finds |
   |---|---|---|
   | (a) issues | ~2.6 s / 393 issues | closed duplicates, and reports nobody turned into work |
   | (b) open PRs | ~2.2 s / 36 PRs | a fix in flight. `gh issue list` **excludes PRs**, so `#930` — the PR that consolidated all five filings above — is invisible to (a) |
   | (c) unmerged branches | ~7 s / 279 refs + the fetch | **finished work that was never submitted.** `#966` is exactly this: a complete, reviewed, `dev`-descended fix sitting on a pushed branch with no PR in any state. Neither (a) nor (b) can see it |

   (c) is not a hypothetical tail case. `#981` measured the
   corpus-level bottleneck as **submission and merge, not
   fixing** — so "somebody already fixed this and it never
   landed" is the *likeliest* form of duplicate work here, and it
   is the one form a tracker search cannot reach.

   Two ways (c) goes wrong, both measured and both handled above:
   `refs/remotes/origin` is your **local** store, so without the
   `git fetch` it answers about whenever you last synced; and
   without the 60-file cap the loop reports `gh-pages` (755 files
   vs `dev`), `public-mirror-squash-v2` (574) and
   `strip-institutional` (241) for *any* path you ask about, while
   the real hit diffs 9. Three confident false positives around
   one true one is how a probe teaches you to skim its output.

   **If you find something open, comment on it with your repro
   rather than opening a new issue.** A second independent
   reproduction is worth more to triage than a second issue. If
   (c) finds a branch, the cheapest next action in the whole
   corpus is usually to verify its tip and open the PR.

   *`monitor/watcher/test-self-fix-tracker-search.sh` executes the
   (c) probe above against a purpose-built fixture, so that block
   is checked, not asserted.*

Each check is a verifiable action (run the command, paste the
SHA, name the file, cite the search). Pass all five before
opening the issue or the PR — not posture, output.

## Opening the self-fix PR — base `dev`, gated merge

Once the five checks pass and you have a fix, open the PR
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

## Adding a value to an existing field in `monitor/` state

**A FIELD THAT *SELECTS* IS NOT A LABEL — before writing a value into an
existing field, find out whether anything MATCHES on it**
(`<your-org>/nexus-code#1050`). If a value selects, adding a member is a
BEHAVIOURAL CHANGE that must teach the matcher in the same commit. **When in
doubt add a COLUMN, not a TOKEN.**

**The mechanism is why nobody notices: two matchers can read one column and
filter it differently, and the documentation at the WRITE site describes the
matcher its author cared about.** `monitor/.state/machine-input.tsv`'s `src`
column reads as a label, and two readers disagree about it —
`_openg_machine_input_epoch` matches `$1 == w && $2 ~ /^[0-9]+$/` with **no
src filter at all** (to it, `src` is pure provenance), while
`_idle_unconfirmed_paste_epoch` matches `$3 == "paste-followup"` **exactly**
(to it, `src` dispatches). So an author who reads the call site carefully,
believes the comment, and picks a descriptive token has done everything right
and still switched off the lost-instruction guard. **Grep every READER of a
field, not the comment next to the writer.**

**The exemption is LIVE and CORRECT, which is worse for discoverability, not
better.** Measured 2026-09-01, `awk -F'\t' '{print $3}'` over the ledger:
`paste-followup` 95, `over-limit-wake` 6, `skeptic-notify-delta-busy-skip` 5,
`unstick-permission` 1, `skeptic-answer` 1, `paste-followup-no-enter` 1 — six
distinct tokens where the issue found three, and every non-matching one is a
deliberate, reasoned exemption. Nothing is broken today. **A dormant trap is
found by whoever trips it; a live one that is working correctly generates no
signal at all** and will never be debugged into.

The worked example is `#683`, the sharpest member: it put `--administrative`
in **column 4**, deliberately NOT a new `src` token, because *"relabelling an
administrative paste would exempt it from the `paste-unconfirmed` detector
entirely."* The right call, for the right reason, discoverable only by reading
the header of the file its author happened to be editing. `monitor/send.sh` has
since made the same fact a load-bearing design rule — *"a transport that writes
any other token is SILENTLY exempt from the delivery guard"* — and
`monitor/watcher/_lib.sh` carries a correction of its own comment, which had
said the token was "purely additive audit/debug provenance". **That comment was
the document an agent enumerating this hazard would have trusted, and it named
the wrong axis.**

**Not confined to `src`.** `monitor/watcher/_idle_probe.sh` reaches for the same
shape twice, and the two are not the same predicate. The `n_idle` tally is an
awk allowlist over the classification column —
`$2=="no-wrap-up" || $2=="wrapped" || $2=="wrapped-but-stub" ||
$2=="paste-unconfirmed" || $2=="orphaned-skeptic-pending"` — so a new
classification silently drops out of the COUNT and lands in the `busy` residue.
The `paste-unconfirmed` conversion is a narrower bash gate on two tokens,
`[[ "$cls" == "wrapped" || "$cls" == "no-wrap-up" ]]`. Both are exact-token
allowlists; neither has a default arm that would tell you it had met something
new. Grep the CONSUMERS before you add a token.

Why it is nastier than the usual proxy-vs-property defect: a proxy approximates
a property and diverges at the edges, so there is a wrong thing a reviewer can
find. This is **two functions wearing one name**, coinciding perfectly until
someone adds a member — so every existing caller is correct, every test passes,
and **the trap is armed only for code not yet written**. "It would pass review"
is not a lapse here; it is the predicted outcome.

Companion rule from the same investigation: **order any two-part operation so
the failure mode is the OBSERVABLE one.** `paste-followup.sh` stamps BEFORE it
sends (`#665`) because stamp→send fails LOUD and send→stamp fails SILENT.

## Writing a test suite here — fixture-repo preconditions

`git -C ""` and `cd ""` are NO-OPS, so a fixture path that expanded EMPTY aims
git at the ENCLOSING repository and WRITES there at rc 0
(`<your-org>/nexus-code#1429`). It is the repository-walk-up trap's empty-string
cousin, and the one `--show-toplevel` cannot catch, because the command never
left the repository you are standing in. A `local a="$1" b="$a"`
expansion-order slip, an unset variable under no `set -u`, a `mktemp` whose rc
nobody read — none of them makes the next `git -C "$dir"` fail.

Call `th_require_fixture_repo "$dir"` (in
`monitor/watcher/_test_helpers.sh`) before the first git command against a
fixture. It refuses an empty path, a non-directory, and a directory that is not
its OWN repository root (via `monitor/repo-root.sh`), at **exit 97** — chosen
so the refusal cannot be read as an assertion failure.

Related and one script over: `monitor/git-https-setup` once wrote bot identity
into the ENCLOSING repository's config (`#1080`), and a third place had the
same walk-up as a silent-hook hazard (`#1174`). All three now ask
`monitor/repo-root.sh`, and
`monitor/watcher/test-repo-root-provenance.sh` reverts each caller to its
pre-fix form and requires the assertion to flip.

## The axis your harness cannot reach — a guard can be INERT and green

**A guard whose answer depends on a property of the ENVIRONMENT that no test
harness reproduces does not fail as a red test. It fails as a confident, allowed,
EMPTY answer, in production only** (<your-org>/nexus-code#1497, #1498).

The measured instance. `monitor/assert-shims-wrapped.sh` probes shim
reachability by spawning `$SHELL -lic` under `timeout`. GNU `timeout` puts the
child in a new — therefore **background** — process group, and an interactive
shell in a background pgrp cannot make progress against the controlling
terminal. That needs a **controlling tty**, and a tmux pane always has one.

**THE FORM OF THE FAILURE IS SHELL-DEPENDENT, and that decides whether the
bound works at all.** Read from `/proc/<pid>/status` rather than inferred:

| `$SHELL` | what happens | does the bound end it? |
|---|---|---|
| zsh 5.4.2 | **SPINS** — `stat=R`, `pcpu=100` for the whole bound. `SigBlk` `0x380000` blocks TSTP/TTIN/TTOU, so `tcsetpgrp` errors instead of stopping and zsh retries | yes — no handlers, so SIGTERM kills it. 40 s, empty surface, **one core pinned per spawn** |
| bash 4.4 | **STOPS** — `SigIgn` `0x280004` **ignores SIGTTOU**, so the stop is **SIGTTIN** | **NO. Never returns.** |

**The bash row is why `-k` is load-bearing rather than tidy.** bash *catches*
SIGTERM (`SigCgt` bit 14), and a caught signal cannot be delivered to a stopped
process. Measured directly: after `kill -TERM` the child is still `T` with
`ShdPnd: 0000000000004000` — the TERM **pending and undelivered**; `kill -CONT`
only lets it re-stop; **only SIGKILL ends it**. So a bare `timeout` has *no
bound at all* on a bash host — one such pair was observed here at **4909 s
against a 10 s bound, 491x** — and `$SHELL` is what selects which mode a given
operator gets. `setsid` cures both by removing the controlling terminal.

**Do not write this class up as "SIGTTOU".** That was the first account, it was
published, and bash's own `SigIgn` refutes it. Read the dispositions.

Measured 2026-09-10 on <cluster>k87, the guard run inside a real tmux pane:

| | dev `b87192b9` | with the #1498 fix |
|---|---|---|
| orchestrator launcher shape | 42149 ms, **5** `did not resolve at all (empty)` | 3135 ms, 0 |
| worker launcher shape | 44092 ms, **5** | 3064 ms, 0 |

**`rc 0` in every cell.** The guard degraded to allow — correctly, by design —
so nothing downstream disagreed. **The failure is not the 13x; it is the 5 → 0.**
For weeks the guard burned 42 s on every spawn and vouched for a surface it had
never resolved. That is worse than a guard that refuses and worse than no guard,
because both of those are visible.

**Why no suite caught it.** Swept `git ls-files` (903 files) for pty creation —
`openpty|forkpty|posix_openpt|command -v script|SCRIPT_BIN|socat…pty`: **0 hits
at `b87192b9`, 6 at the fix.** No harness in this repo could create a controlling
tty, so the axis was unreachable by construction. Not overlooked — unreachable.

**What to do when you write or review a guard here:**

- **Name the environment properties your probe's answer depends on** — a
  controlling tty, an interactive shell, a real `$HOME`, network, a writable
  tree, a process-group placement — and say for each whether your suite
  reproduces it. An axis you cannot reach is an axis to DECLARE, not to assume
  benign.
- **A degrade-to-allow arm needs a test that pins the ALLOW, not just the
  return.** #1498's own kill-path case asserted `rc != 124` (came back fast) and
  not `rc == 0` (came back permissive) — and the guard exits `1` and `79` on its
  refusal paths, so the case passed on a refusal. The property that makes a
  bounded probe safe is *which verdict* it degrades to.
- **A latency is an observable.** If a guard's cost is documented anywhere, the
  figure is a claim: `_lib.sh` carried "a ~1.7 s window … dominated by
  `assert-shims-wrapped.sh` (~2.2 s)" — a whole smaller than the part said to
  dominate it, ~25x off, and visible as wrong without measuring anything. A
  budget sized against a stale figure fires on healthy runs
  (`NEXUS_SPAWN_TRUST_VERIFY_SECONDS=20` against a 42 s guard), and an alarm that
  always fires is an instrument with no signal.
- **Give the sweep a positive control before you believe its zero.** The sweep
  above returned 0 on BOTH trees on the first attempt, because it keyed on a
  literal `script -qfc` and the fixture uses `$SCRIPT_BIN`. A "no test does X"
  claim needs a tree that DOES X to prove the instrument can see it.

## `ng guards-for-diff` — the exit codes, worked

The rule and the executed `GUARDS-FOR-DIFF` block are in the workspace
`CLAUDE.md`. What is here is why each code is not a clearance.

The vocabulary is six-valued — `monitor/guards-for-diff.sh`'s own header is the
authority, so read it there rather than counting the paragraphs below. `1` is
the only unambiguous one: under `--run`, a selected guard FAILED. `5` is the one
worth naming beside it, because it is a NON-verdict wearing a failure's clothes:
under `--run --timeout <s>`, the deadline expired with selected guards left
without a verdict — never started, or started and cut off. They are named. A
guard that did not finish is not a guard that passed, and before `5` existed a
truncated `--run` was indistinguishable from a clean one
(`<your-org>/nexus-code#965`). The remaining four are the ones that look like
answers and are not.

**`3` = no registered guard reads your diff.** A measured answer, not a green
light.

**`2` = REFUSED** — a guard's population probe errored. Fail-closed on purpose,
because an index that silently drops a guard it could not ask looks exactly
like one that had nothing to say.

**`4` = green but UNVERIFIED**, and it is the code that looks most like
success (`<your-org>/nexus-code#1054`). SELECTION counts your full working set —
committed vs base, staged, unstaged **and untracked** — while a population
guard enumerates `git ls-files`, i.e. **tracked only**. So a guard can be
selected, run, and return a confident green *about a tree that does not contain
your new file*. Measured on `dev` @ `2d32449`, content held constant and
trackedness the only variable: a planted file with one early-exit reader scored
**21 passed / 0 failed** while untracked and **20 passed / 1 failed** once
`git add`ed — the plant is absent from the guard's population in the first case
and present in the second. Two agents reported opposite results for the same
guard at the same commit without either being careless; the discriminating
variable was **the index**, not the ref. `--run` now prints such a green as
`UNVERIFIED` and exits 4 rather than `PASS`/0. A red still exits 1 — adding the
untracked files can only find more.

**`0` is the code nothing warned you about** (`#1078`). It says only that SOME
declaring guard read a file you changed. It never says the guard that matters
ran, because a suite that declares no population is INVISIBLE to the index
rather than excluded by it: it appears in neither `SELECTED` nor `CONSIDERED
AND EXCLUDED`, so its absence looks exactly like a considered exclusion. Most
tracked suites declare nothing. The line to read is therefore the tool's own
per-run blind-spot count, and that line is printed byte-identically at 0 and at
3 — the measured reason 0 deserves the same suspicion. `#1065` is the worked
example: exit 0, a header announcing the selected guards, and the one suite
about to go red named nowhere in the output.

It is **not a substitute for the full suite**. Do not quote an
enrolled-vs-tracked ratio anywhere: the figure moved within a single day while
`#834` was open, so a pinned number is wrong before it is read. Read the count
the tool prints on the run you actually did.

## Editing the workspace `CLAUDE.md` itself

Three conventions are enforced by guards, so getting them wrong is a red rather
than a review comment.

**A `BEGIN`/`END` marker pair is a PROMISE that a suite executes the fenced
block.** Every pair needs a row in
`monitor/watcher/claude-md-markers.manifest`, and set-equality runs BOTH
directions — a marker added without a row and a row left behind by a deleted
marker are each RED
(`monitor/watcher/test-claude-md-marker-ownership.sh`, `<your-org>/nexus-code#1264`).
`test-claude-md-block-coverage.sh` additionally requires every pair to have a
non-comment CODE reference outside the document.

Two consequences that are easy to trip:

- **Do not write the literal marker text in prose.** The extractor matches
  the BEGIN comment against `[A-Z0-9-]*`, so an illustrative pair written out
  in full inside a sentence registers as a real extra marker whose name is
  whatever placeholder you used, with no `END` and no owner, and reddens three
  ratchets. Write it as `` `BEGIN`/`END` marker pair `` instead. (The file's own convention paragraph is written that way for exactly
  this reason.)
- **A block cannot currently MOVE to a skill.** Both the manifest and the
  coverage ratchet read `$_repo_root/CLAUDE.md` as a hardcoded single document,
  so relocating a block needs a schema change (a `doc` column, or a declared
  document list) before it is possible at all. Until then a block KEEPs where
  it is — which is the binding constraint on shrinking the file, since 27
  blocks anchor 27 entries in place.

**Do not put a stated COUNT beside an inline or bulleted list.**
`monitor/watcher/test-claude-md-count-vs-list.sh` (`#1464`) pairs the two and
reddens on a MISMATCH — and the failure it exists to prevent is worse than the
red: a hand-maintained list beside a hand-maintained count is two things to keep
in sync, and when they drift **the document's own number is what stops a reader
from recounting**. That is how `unknown` went missing from the pane-state list
while the prose said twelve. Check your edit with
`bash monitor/watcher/test-claude-md-count-vs-list.sh --scan` (rc 0, every row
`MATCH`).

**Some entries are pinned by their PROSE, not only by their block.** A suite may
assert that an exact sentence is present, absent, or unique — the "no SAFE arm
may precede a DENY arm" phrase, `th_require_fixture_repo`, the
`state=<…>` vocabulary line, the escape table before "are CONSUMED", and the
absence of an `N of M` literal inside the `guards-for-diff` bullet are all live
examples. Before rewording an entry, `git grep` its distinctive phrases under
`monitor/watcher/` and run `run-tests.sh --filter claude-md`.

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
