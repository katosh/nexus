# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project does not yet have tagged releases — entries
accumulate under `[Unreleased]`. See
[`docs/contributing/release.md`](docs/contributing/release.md)
for the current release convention.

## [Unreleased]

### Fixed


- **`run-tests.sh` could print a `FAIL`, report `0 failed`, and exit `0` — and
  on the `--jobs` arm CI actually uses.** The per-test rows come from `run_one`
  directly; the VERDICT is aggregated from per-job sidecars under `$run_dir`.
  Two independent channels, and the one that produces the exit code is the one
  that can silently lose its input. Measured on `dev` with `mktemp -p` failing:
  `0 failed`, `rc=0`, for a run in which **zero tests executed**
  (<your-org>/nexus-code#877).

  **What this closes, stated exactly.** Three channels are reconciled: what the
  runner DISPATCHED, what it RECORDED, and what it PRINTED. Not "the accounting
  and the verdict cannot disagree" — that was the original framing, it is a
  universal claim about a runner with more than two channels, and it was false
  as written. `<your-org>/nexus-code#887`'s skeptic reproduced `#877`'s exact
  symptom (`FAIL` row, `0 failed`, `rc=0`) on the *fixed* runner by selectively
  destroying an outcome sidecar: the record still reconciled against dispatch,
  the dispatcher still exited 0, and the printed row and the tally came from two
  separate writes in `run_one` five lines apart.

  That third channel is now closed too — the terminal record carries the STATUS
  beside the path, so the printed row and the verdict derive from one write, and
  the summary refuses when they disagree. Beyond those three, no claim is made.

  Three guards, and all are load-bearing:
  `run_one` now writes a terminal-accounting record for EVERY outcome and the
  summary refuses a clean verdict when fewer tests were accounted for than
  dispatched; and the parallel dispatcher's own exit status is captured instead
  of discarded. Three triggers were exercised — a refused `mktemp`, a run dir
  destroyed mid-run, and a child killed by a signal — and the run-dir case is
  caught ONLY by the dispatch status (its sidecars are annihilated along with
  the directory), which is why neither guard subsumes the other.

  The record is written ABOVE the outcome `case`, not per-arm, so an outcome
  added later cannot silently escape the count; and it is its own file rather
  than a quantity derived from the outcome sidecars, because `exit 77` (SKIP)
  writes no outcome sidecar at all — a naive "no sidecars means refuse" rule
  reddens a legitimately all-skipped run.

- **The fork-bomb guard lowered `RLIMIT_NPROC`'s HARD limit, irreversibly, and
  said nothing when it therefore could not engage.** `ulimit -u N` sets soft
  AND hard; only a privileged process can raise hard back. A NESTED
  `run-tests.sh` — which is exactly what `test-run-tests-bounded.sh` runs —
  inherited that ceiling, could not probe its own fork floor above it, skipped
  its own guard, and printed nothing, so `T6a` failed with `banner absent or
  wrong` and no way to tell why (<your-org>/nexus-code#863).

  The cap is now applied with `ulimit -Su` (soft only). Containment is
  unchanged, because the kernel checks `fork()` against the SOFT limit — the
  hard limit only bounded how far soft could be raised back, so the only thing
  the bare form added was the damage. Measured on the fix host with soft held
  identical at `1627` and only the hard limit varying: under the old soft+hard
  cap the nested guard's banner is ABSENT, under the soft-only cap it is
  present. A guard that declines to engage now says so on every path, since
  silence was the part that made the failure undiagnosable.
- **A full-screen select dialog classified as `state=empty` — "don't know yet" —
  so nothing in the control surface ever saw it.** `pane-state.sh` had an arm
  for each dialog anyone had enumerated (permission prompt, rate-limit menu,
  AskUserQuestion chip-bar, Bypass Permissions modal) and none for the shape
  they share, so any other dialog fell past every check to the input-row logic,
  found no `❯<NBSP>` chevron, and landed on the most ambiguous value available.
  `_unstick.sh` never fired (its `case_B` needs `blocked`), and a worker that
  would **never** proceed was indistinguishable from one that had merely not
  started, for as long as it hung. Claude Code 2.1.232 turned that from a
  rarity into every spawn: nested git repos stopped inheriting workspace trust
  from a parent, every `work/<project>` is a nested repo, so every worker booted
  into the folder-trust dialog and the whole board read as quiet
  (<your-org>/nexus-code#888 found it; `#896` is the classifier half).
  `_has_menu_dialog_frame` now detects the frame **structurally** — a
  navigation footer (`Enter to …` / `Esc to …`) in the bottom slice, a
  chevron-selected numbered option with at least one sibling above it, and no
  REPL input row below the footer — so a dialog nobody has enumerated is still
  seen. `overlay=<kind>` carries the naming separately (`workspace-trust`, or
  the honest generic `dialog`), which is the seam that keeps detection
  independent of wording; blinding the naming table leaves the live capture
  `blocked`, and the suite asserts it. The previous instance of this class
  (`#768`) was closed with two text literals, which is why this one cost
  another release cycle to find. Nothing auto-answers it: `_unstick.sh` runs its
  own text-keyed detection and no arm matches, so a security prompt is
  **surfaced**, not silently confirmed. Widening `blocked` takes nothing off
  `bk_pane_kill_authorized`'s allowlist — `empty` was already refused as
  indeterminate and `blocked` is refused as active — so the change moves a pane
  from one refusing state to another. Regression cover: a fixture **captured
  from the live binary** (not transcribed from a PR body) plus
  `test-realmodel-trust-dialog.sh`, which re-derives that capture from the real
  binary on every gate run with a trusted-parent control arm, so the committed
  copy cannot rot into fiction. `test-pane-state.sh` 156 → 188 assertions:
  one dialog whose wording exists nowhere (the class assertion), four near-miss
  panes each failing exactly one condition, a sweep proving `overlay=` appears
  on exactly the `blocked-*` fixtures and no others, and a mutation per
  condition against the pane only that condition rejects. It also gave the six
  `working-background-*` fixtures a prefix arm — they had none, so the loop
  silently SKIPped them and six committed captures were asserting nothing.

- **`ng wrap-up` recorded an OMITTED `--skeptic-findings` as a measured `0`,
  and fed that number to the gate that decides whether a second skeptic pass
  is warranted** (`<your-org>/nexus-code#881`). `[[ -n "$findings" ]] ||
  findings=0` is the sibling of `#601` and the one `#601` left standing:
  `#601` stopped an *unreadable* value becoming the one value that means
  "nothing found", and the very next line did it to an *unstated* one.
  `bk_require_int --allow-empty` preserves the empty-vs-invalid distinction
  deliberately; the default discarded the surviving half. Downstream the
  fabricated zero was consumed as an observation — printed as
  `new findings : 0`, logged as `"findings":"0"`, compared against the
  recursion threshold — so *"the skeptic measured zero new issues"* and
  *"the skeptic never said"* became one record. The repo's own dominant
  defect class, absence rendered as a measurement, living inside the
  machinery that adjudicates the other instances of it.
  **The historical population is unrecoverable and that is stated rather
  than papered over.** Measured on one operator's log: 338 of 615
  `skeptic-verdict` records carry `findings=0` and NOT ONE can be
  classified — two hermetic wrap-ups differing only in whether the flag was
  passed emit byte-identical records across *every* event the verb writes;
  `ng` logs no argv, the `wrap-up` event carries no count, and nothing else
  under `.state/` holds the invocation. Records predating `#601`
  (2026-07-30) are three-way ambiguous, since prose also coerced to `0`.
  **The fix carries absence as absence — no sentinel.** A `-1` would be the
  same defect in a new costume, because a consumer can do arithmetic on it
  without noticing nobody supplied it. Unstated now prints
  `new findings : not stated`, logs `findings-stated=false` with **no**
  `findings` key (and `findings-stated=true` alongside a real count, so the
  distinction is a positive assertion on disk rather than a missing field),
  and the threshold comparison is simply **not reached** — unguarded,
  `(( findings >= thresh ))` on an empty string is not even an error in
  bash, it silently answers "below threshold" for a count never taken.
  With **neither** a count nor a readable `disposition:`, wrap-up now
  ESCALATES instead of terminating: nothing is on record saying the chain
  may end, and `#678`'s own point 4 is that a blank statement is the case
  that should ask. Every terminal message distinguishes the two — a
  `no-further-pass` with no count terminates on the *disposition*, and says
  so, instead of claiming "no substantive new issues" over a measurement
  that was never made. A legitimate clean pass is unchanged: an explicit
  `--skeptic-findings 0` still terminates the chain silently and cleanly.
  29 assertions in `monitor/test-bookkeeping-contract.sh`, which asserts
  the two states are DISTINGUISHABLE rather than checking either against a
  value — a test asserting `findings == 0` after an omission would pin the
  bug, which is roughly how it survived `#601`.

- **A skeptic-stamped window could not wrap up worker work without asserting
  a skeptic verdict it had no basis for** (`<your-org>/nexus-code#879`). The
  role is derived from the window's *provenance* record (`skeptic_role:
  true`), and a window is stamped for its lifetime rather than for one task.
  A retained skeptic that later authored a patch therefore met
  `--skeptic-role requires --skeptic-verdict ...` on a wrap-up that was not
  a verdict, and no flag meant *"this is not one"* — so the only way to
  complete the documented hand-off was to supply a verdict on its own diff.
  That is worse than refusing: a self-review is indistinguishable
  downstream from an independent clearance, and the verb was therefore
  manufacturing the exact artefact the skeptic protocol exists to prevent.
  The workaround on the board (hand-rolled `ng upload` + comment) skips the
  `report-check` pre-flight, the templated link comment and the action-log
  `wrap-up` event the window-cleanup loop reads, so the window looks
  un-wrapped.
  New **`--not-a-skeptic-verdict "<why>"`**: takes the ordinary producer
  path, so the window's own work gets the normal skeptic decision for its
  spawn mode, and records `skeptic-role-not-asserted` with the reason. The
  reason is mandatory and substantive (>=20 chars, the
  `GH_IMPERSONATE_REASON` shape) — an opt-out nobody has to justify is a
  way to dodge an obligation. It **discharges nothing**: no skeptic marker
  is cleared, so a verdict the window owes is still owed and its target
  stays blocked. Mutually exclusive with `--skeptic-role` and
  `--skeptic-verdict` (refused at parse time, before the upload, so a
  contradiction cannot strand a half-completed hand-off), and refused
  outright on a window that was never stamped. The original refusal now
  **names the escape hatch** — a refusal whose only open path is the false
  one is what produced the fabricated verdicts. 17 assertions in
  `monitor/watcher/test-skeptic-channel.sh`, which also gains the
  assertion-count floor it lacked, plus 7 parse-time assertions in
  `monitor/test-bookkeeping-contract.sh`.
  **Checked against `#906`(A) before adding the flag**, since that finding
  raises the possibility that `#879` is `#883`'s class — a correct mechanism
  behind a lying interface, where the fix is to advertise rather than add.
  Measured at `origin/dev`: all **ten** pre-existing `--skeptic-*` flags
  refuse a stamped window doing worker work, and exactly one thing completes
  the hand-off — asserting the verdict. Structurally, the role path is
  entered on provenance and has one exit; every other flag is read in the
  producer path (unreachable from there) or decorates a verdict rather than
  substituting for one. The mechanism was genuinely missing.

- **`ng wrap-up --help` advertised NONE of the eleven `--skeptic-*` flags it
  parses** — wrap-up's share of `<your-org>/nexus-code#906`(A)/`#883`. This is
  not cosmetic for `#879`: a caller cannot consult a flag it cannot see, so an
  unadvertised escape hatch is not an escape hatch, and "assert a verdict"
  read as the only way out of the role gate. `_usage_for cmd_wrap_up` was a
  hand-written string; it now carries the whole family, grouped producer-side
  vs skeptic-side, with the `#881` note on `--skeptic-findings`. Scoped to
  this verb — the rest of `#906`(A) is untouched and not claimed.
  A drift guard keeps the hand-written string honest by extracting the arg
  loop's `--skeptic-*` arms and asserting each appears in `--help`. Per
  `#906`(B) — `#900`'s derived synopsis degraded *silently* on an arm it
  could not parse — the guard **refuses to be vacuous**: it asserts the
  extractor found >= 12 arms before comparing anything, and fails with "it
  did NOT run" otherwise. An extraction that returns nothing is not evidence
  of no drift; it is evidence the extractor did not run. Mutating the
  extractor's anchor to match nothing is one of the ten mutations run against
  this branch's assertions.

- **`monitor.cc_auto_update.tracking_issue` took a bare `N`, which resolves
  against whichever repo the consumer supplies — so a run of evaluations posted
  to an unrelated closed PR and was never seen.** `#N` is repo-relative.
  `CLAUDE.md` already warns about this for comment BODIES, where GitHub renders
  the link and the ambiguity is at least visible; in a **config field** nothing
  renders it, so the repo is supplied invisibly at the point of use. The
  evaluator prompt pairs the value with the *surface repo* (the implementation
  repo every operator clones), so a number written against an operator's own
  asset repo was read against the shared one. Nothing errored — the number
  resolved, the API returned `201`, the comments posted; the operator was
  watching a different `#N`.
  The fix is a **qualified reference**, `owner/repo#N`, not a corrected number:
  a corrected number is right until the next reader supplies a different repo,
  and is then wrong again with no more warning than before. Only a reference
  that carries its repo is stable under being read from anywhere.
  **Resolution now REFUSES rather than guesses**, because guessing is what
  produced a plausible target for a month. New `monitor/issue-ref.sh` parses a
  qualified reference (exit 0), reports *not configured* separately (exit 3),
  and refuses anything else (exit 4) — bare `N`, half-qualified `repo#N`,
  leading-zero numbers, issue `0`, and a pasted issue URL (for which it prints
  the exact config-form translation). `config/load.sh --validate` refuses the
  same shape at config load; the cc-update evaluator **declines to fire** and
  records `refused-unqualified-tracking-issue` in `decisions.tsv` rather than
  posting to a guessed repo — a skipped evaluation is visible on the next fire,
  a misrouted one is invisible forever. A **missing** resolver is also a
  refusal (absence of the checker is not evidence the reference is fine); an
  **empty** value skips it entirely (nothing to get wrong). The prompt now
  carries `TRACKING_REPO` beside `TRACKING_ISSUE` so a qualified reference is
  used against *its own* repo instead of being re-paired with the surface repo.
  **Second instance documented:** `monitor.remote.endpoint_issue` is the same
  shape, mitigated by an explicit `endpoint_issue_repo` companion — but its
  default resolves to the operator's **asset** repo while cc-update's resolves
  to the **implementation** repo. Opposite defaults, neither stated where the
  value is typed, so a convention learned from one field is silently wrong
  about the other. Both fields now say so.
  The discriminator worth carrying forward is not "resolves against an implied
  context" — nearly every config value does. It is **resolves against an
  implied context AND fails silently when that context is wrong**: a wrong tmux
  window identifier prints `no such tmux window`; a wrong issue number returns
  `201 Created`.

- **The worker floor's blanket force-push ban told every worker to refuse the
  rebase the merge gate requires (`#835`).** Two standing rules could not both
  be satisfied on a personal PR branch: the floor said *"never force-push"*,
  flat, while the merge gate requires the branch be rebased onto the **current**
  base before merge — and a rebase makes the push non-fast-forward. The gate is
  not negotiable: a `pull_request` run is computed against a merge ref built at
  **run creation**, so if the base moves afterwards a later green describes a
  tree that no longer exists, and `rerun-failed-jobs` **reuses that same stale
  ref**, so a later green can describe a base that has moved. (An earlier
  version of this entry said "only a NEW HEAD re-evaluates". That was
  **REFUTED by experiment**: the merge ref is **demand-triggered** —
  `refs/pull/N/merge` is recomputed when something asks GitHub for the PR's
  mergeability, and not otherwise. Measured: two refs sat stale for **26 and 36
  hours** across many base advances, while one refreshed within **two minutes of
  a single `GET /pulls/{n}`** and an untouched control did not move. So "it has
  been a while, it must have refreshed" is false, and **querying the PR
  refreshes it — the act of checking changes what you are checking**. Query the
  PR, then create a new run, then enumerate that run. The carve-out itself is
  unaffected: a rebase still makes the push non-fast-forward.) `#823`
  merged on exactly such a green and turned `dev` red across six of six
  unit-suite bands, and `#826` hit the contradiction directly, requiring the
  operator to authorise the force-push by hand, per worker.
  The floor now carries only the **boundary**, in one sentence: never
  force-push a *shared* branch (`dev`, `main`, or any branch carrying another
  author's commits); force-pushing your *own* PR branch after rebasing it onto
  the current base is expected. The runnable half — the checkable precondition,
  the `--force-with-lease` caveat, and the merge-ref rationale — moves to three
  new `force-push` rows in `bash-footgun-patterns.conf`, delivered by
  `bash-footgun-guard.sh` at the instant the worker runs `git push`.
  **The precondition must key on the PROPERTY, not on AUTHORSHIP**, and the
  first version of this change got that wrong. It shipped
  `git log --format='%an' origin/dev..HEAD | sort -u`, glossed as "if this
  lists only you, no other agent has commits here" — which is false *in this
  workspace, for a reason the same floor states two clauses earlier*: `git
  commit` / `git push` use the operator's identity, so every agent commits as
  the same author and the check cannot see a sibling at all (18 of the last 25
  `dev` commits are one name). Measured on a two-agent branch, it returned one
  name, read SAFE, and the force-push destroyed the sibling's commit and its
  file. `--force-with-lease` did **not** backstop it: the lease is satisfied by
  the very `git fetch` that rebasing onto current `dev` requires, and the push
  went through as `(forced update)`. The shipped check asks what would be
  overwritten — `git log --oneline <branch>..origin/<branch>`, run **before**
  the rebase (after it, a rebase has rewritten the remote's commits out of
  `HEAD`, so it always reports commits) — with
  `--force-with-lease=<branch>:<sha-you-saw-before-fetching>` as the pinned
  alternative. Caught by the `#835` skeptic pass.
  **That correction then had to be corrected**, by the same skeptic on the
  delta, for the same underlying reason one costume further on: shipped as
  prose, the property check was right whenever it could look and **silently
  safe whenever it could not**. Three states print empty — the branch is not on
  the remote yet, the fetch **failed**, or the tracking ref is stale because
  the fetch was skipped — and the first two are byte-identical at the terminal
  (same empty stdout, same `rc 128`, same stderr shape), so a failed fetch
  renders exactly like the all-clear. It is now **`monitor/force-push-check.sh`**:
  one command that fetches and compares together (so there is no step to skip,
  and no stale tracking ref to read), failing CLOSED with
  `guards-for-diff.sh`'s `#803` exit-code shape — `0` safe, `1` UNSAFE with the
  commits listed, `2` REFUSED (could not check, explicitly **not** a
  clearance), `3` no such remote branch (known, and distinct from `2`). Pinned
  by `monitor/watcher/test-force-push-check.sh`, whose fixtures are real repos
  with real remotes because the states being separated are git's own — including
  a control asserting the author check *would* have cleared the unsafe one.
  **And then a third correction, a false SAFE rather than a refusal**: the
  script compared `HEAD`, but a push moves `refs/heads/<dst>` on the remote from
  `<src>` locally, and **neither is necessarily the checked-out branch**.
  Measured: local `feature` lacking a sibling commit while `HEAD` sat on
  `integration` which contained it printed `SAFE rc 0`, and the push then
  reported `(forced update)` with the sibling gone. It now resolves what the
  push will actually move — `<branch>`, `<src>:<dst>`, or `push.default` +
  `@{upstream}` — and refuses rather than guessing for `matching`, `nothing`,
  and a detached `HEAD` with no ref given. Pinned by four ground-truth cases
  that ask the script, then perform the **real** forced push and check whether
  the sibling commit survived: a SAFE verdict followed by a lost commit is the
  failure. Against the pre-fix script those cases are 3/9 with two false SAFEs.
  Worth recording as a method rather than three bugs: authorship that could not
  detect a sibling, a check that could not tell "nothing to destroy" from "I
  could not look", and a check that compared the wrong ref — three levels, each
  fix opening the next hole, and **every one found by building the failing case
  rather than by reading the code**.
  **And then a fourth, on a fourth axis: the wrong REMOTE.**
  `remote.pushDefault` and `branch.<n>.pushRemote` select the push remote; the
  check assumed `origin`, said SAFE, and the push destroyed a commit on the
  other remote. At that point the diagnosis stopped being any individual fix:
  every round had been **re-implementing a piece of git's own push-target
  resolution** — `push.default`, `remote.pushDefault`, `branch.<n>.remote`,
  `branch.<n>.merge`, `branch.<n>.pushRemote`, explicit refspecs, `+` markers,
  `--all`, `--mirror`, per-remote push refspecs — a surface larger than anyone
  enumerates in advance, so each fix relocated the hole rather than closing it.
  The check now **asks git instead of modelling it**:
  `git push --dry-run --porcelain --force <the caller's own arguments>` reports
  exactly which refs would move on which remote, authoritative by construction
  because it **is** the resolution. The hand-rolled resolver is deleted; a test
  asserts no push-target config is re-derived. Side effects: multi-ref pushes
  (`push.default=matching`, `--all`, `--mirror`) became **answerable** instead
  of refused, and deletions (`-`) and unknown porcelain flags now fail closed.
  Residual named rather than left to be found: TOCTOU, network required (an
  unreachable remote is REFUSED, never a pass), server-side hooks not consulted
  (errs safe), and it reports what a plain `--force` would do, so a real
  `--force-with-lease` may be refused where this said UNSAFE — never the
  reverse.
  Two follow-ups from the round-five pass, neither a correctness defect but
  both fixed rather than deferred, because a residual is something that
  *cannot* be fixed and these could. **The two fail-closed arms were
  untested** — `!` (rejected) and the unrecognised-flag default arm had no
  assertion, so deleting either would not have reddened the suite: the same
  decoration-not-guard shape as the vacuous `\p` assertion earlier in this
  PR. Both are now exercised and mutation-checked; removing either arm makes
  the suite report a **false SAFE**. They need a PATH-front `git` stub because
  a live rig cannot reach them, and the reason is itself now measured and
  recorded: **receive-side policy is invisible to the dry-run** —
  `receive.denyNonFastForwards` and pre-receive hooks are enforced when the
  remote *receives*, so such a push is still reported `+ (forced update)` and
  classified UNSAFE. A false ALARM, never a false clearance, and pinned by a
  test because "errs safe" is a claim like any other. **And the check made two
  remote round trips** — the dry-run ran twice, once per stream, doubling
  latency and *observing the remote twice* so the two runs could disagree
  (the URL came from the second). Now one invocation with stderr captured via
  a temp file; measured 2 → 1 with an invocation counter. That split is the floor's own stated
  design principle applied: the floor is prepended to EVERY spawn prompt, so a
  rule with a hookable trigger belongs at the trigger, not in the preamble.
  Three implementation details are load-bearing and are now pinned by tests.
  Coverage is three rows, not two: `--force*`, an order-insensitive
  `-[a-zA-Z]*f` (clustered `-uf` is a real forced update and used to miss), and
  `[[:space:]]\+` for the `+refspec` forms — `git push origin +dev` **is** the
  forbidden act and drew no warning at all. The hook also now accepts `\p` as a
  literal `|` in a regex field, which is what lets the exclusion classes read
  `[^;&\p]`; without it `git push origin main | grep -f pats` matched on
  *grep's* `-f` and, first-match-wins, cost the worker its cwd-pinning
  reminder. That `\p` assertion was itself **vacuous** as first written: its
  example piped into `grep`, and unsubstituted `[^;&\p]` excludes the *letter*
  `p`, so grep's own `p` blocked the match and the test passed whether or not
  `\p` worked. The example is now `xargs` (no `p`); deleting the substitution
  takes the suite to 31/1 where it previously stayed 32/0.
  The force-push rows must PRECEDE the generic `git-push` row, because the hook
  takes the first match and the generic regex matches every force-push too —
  with the order wrong, a force-push silently receives the cwd-leak reminder
  instead of the boundary (no error, no failing match, just the wrong advice at
  the one moment it matters). The conf's `|` field separator forbids alternation
  in the regex field, so `--force*` and `-f*` are two rows sharing one tag; the
  tempting single-regex form `[[:space:]]-[-]*f` also fires on `--follow-tags`.
  And the precondition survives as a pipeline only because `message` is
  `read`'s LAST field, which absorbs embedded delimiters intact.
  The blanket ban is also removed from `CONTRIBUTING.md`,
  `docs/contributing/development.md`, `docs/operating/spawning-workers.md`,
  `docs/admin/repos.md`, `docs/reference/skills.md`, `README.md` and
  `nexus.tmux-spawn`, so the contradiction does not survive one file over.
  Branch protection on the shared branches is what makes the narrowed rule
  structural, and `docs/admin/repos.md` now says so.

- **`skills/**` matched no workflow `paths:` filter, so the highest-blast-radius
  edit in the repo ran NO tests (`#835`).** `test-spawn-worker.sh` EXECUTES
  `skills/nexus.worker-defaults/SKILL.md` as a fixture — it extracts the
  `## Worker floor` body and asserts its content, because that body is injected
  verbatim into every future worker's prompt. But `skills/**` appeared in no
  workflow filter, so a PR editing ONLY the floor triggered no `tests` run at
  all, while `gh pr checks` showed the by-construction-green `ci-signal` and
  read as "all checks passed" (`#604`). Same class as `#736` and the reason
  `CLAUDE.md` was added to this filter. `lint-workflows.py`'s PF rule did not
  catch it and was not wrong to miss it: `spawn-worker.sh` reads the floor
  through a runtime variable, and PF explicitly scopes itself to statically
  resolvable `run:`/source edges. Found while adding the floor's own force-push
  assertions — which were themselves unreachable on the PRs that would need
  them.

- **The autosuggest ghost-text detector matched a dim BOX BORDER, so one
  cosmetic renderer change would have turned every idle pane on the board into
  `autosuggest-only` at once (`#801`).** `_detect_dim_run` asked whether a faint
  (SGR 2) run carried a visible character, searching `${input_row#*❯}` —
  everything after the chevron **to end of line**. A dim closing border is
  exactly that. Measured, not reasoned: an empty input box rendered
  `…❯<NBSP>\x1b[7m \x1b[0m   \x1b[2m│\x1b[0m` classified `autosuggest-only
  input=ghost` for 28 s of deterministic polling, and `state=idle` was
  **unreachable** for that renderer. Claude Code does not draw that border today
  (9 of 9 idle captures carry no dim run after the chevron; its rules are
  `\x1b[38;5;244m`, not a whole-parameter 2) — the guard's correctness rested on
  a cosmetic property of somebody else's renderer that nothing checked and
  nobody owned. `_strip_dim_box_chrome` now erases dim runs whose entire visible
  content is box chrome, and **both** dim-keyed readers run through it.
  The second reader is the dangerous one and was not in the filed report:
  `_input_row_typed_text` cuts the row at its first dim run, and a dim **left**
  border precedes the chevron, so the cut takes the chevron with it. Measured on
  the new fixture, a vim-INSERT pane holding **real operator text** with no
  bright marker read `state=autosuggest-only input=ghost` — a kill-authorised
  state, and the token that tells an orchestrator the text is model-generated
  and safe to paste over. It is the operator's.
  Also fixed in passing, surfaced by that fixture: the vim-INSERT refinement set
  `state=user-typing` but left `input=` at whatever the pre-refinement detectors
  said, publishing `state=user-typing input=blank` — "a human is at this
  keyboard" and "the box is empty, paste away" on one line. It now says `typed`.
  Narrows a permissive answer; widens nothing.
  **Skeptic F1 (`#827`), material:** the first strip was a single `s///g` pass
  whose branch consumes the terminating ESC, so `g` resumed after that byte and
  ADJACENT dim runs were stripped alternately — one survived, and a surviving
  dim run carrying a visible character is `#801` intact. Measured: a DOUBLED
  border reproduced both halves. Closed with a `sed` label loop (`:a … ;ta`),
  which re-runs from the start of the line until nothing more matches.
  The deeper finding is the boundary, not the loop: `input-box-chrome.manifest`
  was offered as *the* coverage boundary while bounding only the GLYPH axis,
  and the mechanism also varies on RUN STRUCTURE (how many dim introducers the
  renderer emits across the border). A bound that is honest, tested, and drawn
  on the axis the SEARCH varied on rather than the axis the MECHANISM varies on
  is still false. The manifest now names both axes and points at the two
  adjacent-run fixtures that pin the second; the `#801` block mutant-tests all
  five.
  Coverage boundary is **data**: `monitor/watcher/input-box-chrome.manifest`
  carries a disposition per glyph, executed by `test-input-box-chrome.sh`. ASCII
  `|` and `+` are deliberately **content**, so an ASCII-art border is a recorded
  gap rather than a surprise; `■` (U+25A0) and `⓿` (U+24FF) sit one codepoint
  outside the two implemented ranges and go red if either quietly widens. Three
  fixtures pin the classifier itself — negative (empty box + border → `idle`),
  positive (real ghost bytes + border → still `autosuggest-only`), and
  kill-axis — plus a mutation that neuters the strip and asserts all three
  collapse, so the assertions cannot pass for an unrelated reason.

- **The watcher told the operator to relaunch a live agent that was waiting on a
  question (`#808`).** `_idle_probe.sh` maps `absent|blocked` to one
  `pane-absent` class, which is right — both need the operator — but the
  advisory described only the `absent` half: *"claude process gone or
  unresponsive; relaunch or close"*. A `blocked` pane is **alive** and rendering
  a modal only a human can clear. Observed in production 2026-08-07 22:49
  against window `idflake`, which was displaying an AskUserQuestion: five
  operator probes returned `state=blocked overlay=askuq` with `pane_pid`
  unchanged throughout, and the surface said the process was gone. Relaunching
  destroys a live agent's context and discards the question it is asking.
  The advisory is now per-state. The kill gate had held throughout
  (`bk_pane_kill_authorized` refuses `blocked`; `retire-preflight.sh` carries an
  explicit do-not-kill arm), so this is stated as a **trust** defect, not a
  safety one — the expensive outcome is an operator learning to discount
  `pane-absent`, a surface documented as inviolable and never suppressed.
  Second half, and the reason a classifier-only fix would have been invisible:
  the renderer's `pane-absent` arm printed a **fixed string and discarded `$4`**,
  so the advisory was decided in one file and overwritten in another. Every
  other class in that renderer already read `$4`. It now does too, falling back
  to the historical wording when the column is empty.
  Two documented contracts were stale and are corrected with it: the module
  header still claimed `state ∈ {absent, empty, blocked}` long after `empty`
  stopped mapping here, and `monitor/README.md`'s class table carried the fixed
  advisory as if it were the only one. Out of scope, and said so rather than
  silently: `n_pane_absent` in the summary line still counts both states into
  one number.
  Coverage: the existing suite asserted the **class** and passed throughout the
  incident; it now asserts the **string**, in both directions — `absent` keeps
  the relaunch advisory and must not acquire the blocked one, so "make
  everything say the blocked thing" fails. The blocked negative probes for
  *"claude process gone"*, not *"relaunch or close"*: the corrected wording ends
  *"do NOT relaunch or close"* and contains that phrase, so the obvious
  assertion flags the fix as the defect (it did, on the first draft).

- **`remote-up`'s port-collision guard refused to start over a peer that was
  already gone, and its refusal contradicted itself in its own text (`#810`).**
  The guard observed the port occupied, verified ownership with an ssh-keyscan,
  and then refused on the strength of the **first** observation — two
  observations of a mutable fact, so a run aborted with `nothing was registered
  or started` while printing `Connection refused` and `no LISTEN socket visible`
  about the same port. Seen in CI on `#795` under `cpu-stall%=58.47` on 2 vCPUs,
  which widens the gap between the two.
  Fixed on the property rather than the proxy, in two halves. **Occupancy is now
  answered by an actual `bind()`** (`_remote_port_bindable`, SO_REUSEADDR +
  `listen()` so it mirrors what sshd does) — a connect answers a different
  question and is wrong in *both* directions. That is not theoretical here: the
  new suite measures, on this host, a port held as an ESTABLISHED outbound
  **source port** answering the connect probe "free" while `bind()` gets
  EADDRINUSE. `#769`'s defect was live in this guard too, un-filed, in the
  direction that reintroduces the EADDRINUSE-backoff-forever state the guard
  exists to prevent. **And every refusal now re-establishes its own premise**: a
  port that is bindable at verification time is not holding anything.
  This cannot weaken the guard — the proceed arm fires only when we have just
  bound the port ourselves, an inconclusive probe (no python3, unbindable
  address) leaves the refusal standing, and the three connect/`ss` signals
  survive as the no-python3 fallback so such a host keeps the previous
  behaviour exactly. The residual race is **declared, not papered over**: a
  third party may bind between the probe and the sshd bind. Closing it outright
  means handing sshd a pre-bound descriptor, which `sshd -p` cannot accept; when
  it is lost, the supervisor reports EADDRINUSE and the identity-aware
  healthcheck surfaces it.
  Every now-proceeds case in the new suite is paired with a real-listener case
  that must still refuse and a probe-cannot-tell case that must still refuse,
  because "stop refusing" is trivially achievable by disabling the guard. The
  suite never registers, starts, or binds the `nexus-remote-ssh` service.

- **The CI-enumeration recipe checked WHICH runs and WHAT they concluded, and
  never AGAINST WHAT BASE (`#823`).** A `pull_request` run does not test your
  branch: it tests `refs/pull/N/merge`, a merge commit GitHub computes **at run
  creation**. If the base branch moves afterwards, every green stays green while
  describing a tree that no longer exists. `#823` merged on exactly that, and
  the enumeration that cleared it was **correct about everything it checked** —
  head sha, run attempt, band multiplicity, conclusions. The gap was not a
  mistake in the recipe; it was a question the recipe did not contain.
  `ng ci-attempts` now answers it, in the recipe rather than in prose:
  `monitor/_merge_ref_base.sh` reads the runner's own
  `Merge <head> into <base>` checkout line — a RECORD OF WHAT WAS TESTED —
  and compares it against the PR's current base tip. A stale base **withholds
  the clearance at its own exit code 8**, whose action is its own (rebase or
  push, so a new run is computed against the current base; re-running CI at the
  same head cannot fix it, because `rerun-failed-jobs` reuses the merge ref from
  run creation).
  Every other available signal is a reconstruction and was rejected as such:
  reading `refs/pull/N/merge` **now** returns the merge recomputed since, and
  comparing run-creation time against the base tip's commit **date** is a
  heuristic that reports a stale run as fresh whenever a commit was authored
  before it was pushed — the unsafe direction. `gh api` for the log, never
  `gh run view --log`, whose 1.13.0 client returns zero lines at rc 0 (`#755`).
  **Three states, and `unread` is not folded into either of the others.** GitHub
  expires logs, so "could not read it" is ordinary and must not block; it is
  reported as `NOT CHECKED` beside the verdict — *"that is `not looked at`, NOT
  `looked at and current`"* — the same treatment absent attempt provenance
  already gets. A VERIFIED base is printed too, because a reader cannot
  otherwise tell a verified base from a check that never ran.
  The scan reads **several** successful runs, not the first: measured on
  `#823`'s own head, three of its successful runs check out
  `refs/remotes/origin/dev` directly and carry no merge line, while the round
  that ran the tests carries it. Reading only the first reports `unread` on the
  very head the check exists for — an *"I looked in the wrong place"* dressed as
  *"it cannot be known"*. Declared limit: if two rounds at one head tested
  different bases, the answer names the run it came from and does not detect the
  disagreement.
  `monitor/watcher/test-merge-ref-base.sh` (13 assertions) drives the library
  directly — including the **STALE** arm, which no live PR can be made to
  demonstrate on demand — with a negative-control mutant that makes a stale base
  read as current. `test-ci-head-attempts.sh` 22 → **25**, wiring the three
  states through the verb end-to-end.

- **`#812`'s credit, scoped.** The `skipped`-reads-as-`success` case is closed by
  machinery that already existed: `VERDICT_CONCLUSIONS` is an allowlist of
  `{success, failure}` and `classify_runs` returns `NO_VERDICT` for
  `skipped`/`cancelled`/`neutral`, and both are **untouched** by the `#812`
  change. `#812` closes a different hole — the expectations-only path, where no
  run data was supplied at all. The prior entry did not claim otherwise but did
  not say so either, and a changelog about verdicts that claim more than they
  measured should not leave that to the reader.

- **`ci-trigger-audit.py` announced a `success` verdict on the path where it was
  shown no runs (`#812`).** With `--observed` omitted the audit printed, two
  lines apart, `band multiplicity: NOT CHECKED — … that is 'not looked at', not
  'looked at and clean'` and `OK: every workflow that should have gated this PR
  has CONCLUDED and carries a success verdict`, at **rc 0** — and the `#748`
  qualifier that would have softened it was guarded by `elif observed is not
  None`, so the one path most in need of a qualifier received none. The `#762`
  shape one step further out: a positive claim quantified over something never
  measured, rendered as `OK` at exit 0, inside this repo's own instrument for
  detecting exactly that.
  The remedy is **structural, not editorial**, because a better sentence stays
  one edit away from being reachable again. The verdict sentence now lives in
  one function, `cleared_lines()`, guarded by `_require_measured()` which
  RAISES (`UnmeasuredClaim`) if it is ever reached without run data; the three
  terminal states are selected by one function, `clearance_report()`, on the
  question *what was this run in a position to answer* rather than *was
  anything wrong*; and the no-data case gets its own sentence and its own
  **exit code 7 (EXPECTATIONS ONLY)**. Both production callers pass
  `--observed` unconditionally, so 7 is unreachable there and their default
  arms make it fail closed.
  `test-ci-trigger-audit.sh` 59 → **66 assertions**, asserting the SENTENCE and
  not only the code — including the two absences (`^OK: `, ``carries a
  `success` verdict``) — plus a function-boundary probe that `cleared_lines(g,
  None)` raises, and **two negative-control mutants**: deleting the arm alone
  makes the precondition fire (rc 2, refused), deleting the arm *and* the
  precondition reproduces `#812` verbatim (rc 0 + the OK line over no data).

- **`test-remote-identity-health.sh` flaked on fixture startup because its port
  allocator predicted `bind()` from a `connect()` (`#769`), and threw away the
  evidence on every occurrence (`#794`).** The suite allocated fixture ports by
  probing with a TCP connect and handing back any port that refused it. A
  connect only detects a **listening** socket; it cannot see a port already held
  as the **ephemeral source port** of an outbound connection — and four of the
  five fixture windows sit inside the kernel's ephemeral range (32768–60999).
  Such a port answers the probe with "free" and then fails `bind()` with
  `[Errno 98] Address already in use`, `SO_REUSEADDR` or not. The allocator now
  probes by **binding** the port, which is the operation the fixture actually
  performs, and remembers ports found unusable so a retry tries a different one
  — without that, the probe is deterministic and re-hands the identical port
  (observed doing so three times on port 33054). Allocation also moved to
  immediately before each bind; it used to happen ~15 s earlier, at the top of
  the file. Case 0 is the regression test, with the holder modelled as a real
  ESTABLISHED outbound socket.
  The filed mechanism — "CPU contention against a bind-readiness ceiling" — is
  **refuted**: on the failing job the ceiling was 80 polls ≥ 16 s while the whole
  suite ran 15.67 s, and the captured post-mortems show the child exiting after
  **one** 0.2 s poll. No deadline was ever involved.
- **A fixture's readiness was a liveness proxy, in the suite whose purpose is
  refusing liveness proxies (`#769`).** "A TCP connect to my port succeeds" was
  read as "my fixture came up", so a stranger holding the port made the suite
  report the forger started and then measure the stranger — 82 passed, 8 failed,
  including `…named as IMPERSONATION` verbatim, i.e. accusing an unrelated
  process of impersonation. Readiness is now an **announcement**: `sshd -e`
  prints `Server listening on …`, and the two python fixtures print a `READY`
  line after `listen()`. Two listeners cannot hold one addr:port, so an
  announcement proves ownership.
- **A diagnostic may only name a path that outlives the process printing it
  (`#794`).** The fixture-start failure pointed at `$WORK/forge-<port>.log`, a
  file the suite's own `trap … EXIT` deletes before `run-tests.sh` records the
  failure and long before CI's `collect failure artifacts` step runs — confirmed
  by downloading all four artifacts of a real failing run, none of which contain
  it. Failure paths now print the log's **contents** inline, plus which exit the
  bind loop took and who holds the port. `#794` scoped this to one call site; a
  corpus scan over the pre-fix tree at `16728e7` finds **two**
  (`test-remote-identity-health.sh:531` and `test-mint-token.sh:300`), and
  `test-diagnostics-outlive-their-paths.sh` now pins the boundary as a manifest
  (currently empty) with its own positive and negative controls. The detector's
  span must span the whole diagnostic: an earlier draft stopped at `;`, which
  made it blind to `#794`'s own line — whose format string reads
  `(python3 is present; see %s)`. That case is now the positive control.

### Changed

- **An unstartable forging fixture is now `th_skip` with a named precondition
  rather than a FAIL (`#769`), gated on an allowlist with a default-deny arm.**
  Only a demonstrated host fault (seized port, bind ceiling, no free port) may
  downgrade; a broken `forge.py`, a bad pubkey or anything unclassified still
  FAILs. The three substrate fixtures deliberately keep the hard FAIL: the only
  mechanism for downgrading them is a file-level `exit 77`, whose reason
  `run-tests.sh` recovers from `head -n 3` of **stdout**, while these
  diagnostics are on stderr hundreds of lines in — it would render as a SKIP
  with an invisible cause. Verified by negative control: a real `#609`-class
  impersonation regression still reddens loudly (34 passed, **56 failed**, zero
  skips).

- **`live-skeptic-window` was matching a naming convention, not looking for a
  skeptic (`#771`).** The spawn-skeptic request's field that exists to stop
  duplicate review resolved via `grep -qxF "${target}-skeptic"` over
  `tmux list-windows`. Skeptic windows are not named that way: of 468
  `skeptic_role: true` spawn records on the reporting nexus, **198 (42%)**
  carry a name the pattern cannot match — `fig4sk`, `nexuscode-716sk`,
  `debench-skeptic3`, `skeptic-B7`, `audit-skeptic` for target `ncode-audit`.
  Each was invisible to the field from the moment it was spawned.
  - `#771` reported the symptom exactly right — `fig4sk` was `busy`,
    re-pinned, working the delta, while the request said `no`; four duplicate
    requests in twelve minutes — but hypothesised the detector keyed on
    **wrap-up bookkeeping**. It never did. Re-pinning correlates because
    iterative rounds are when an operator reaches for `…-skeptic2` or a short
    name; the field was equally wrong for those 198 windows on their *first*
    pass. The fix is correspondingly broader than the report.
  - A window is now live when the **spawn record**
    (`monitor/.state/windows/<w>.json`, `skeptic_role` + `skeptic_target`,
    written by `spawn-worker.sh --skeptic-role` itself) names this target,
    a tmux window of that name exists **now**, and the pane does not
    positively assert a dead agent. Records alone would be the opposite
    error — they are never pruned, so they answer "was there ever a skeptic".
    The legacy name match is kept as a **union member** so a pre-provenance
    window still counts.
  - Liveness gates on new `bk_pane_asserts_dead`, true for `absent` and
    nothing else — the **dual** of `bk_pane_kill_authorized`, not its
    negation. Both are default-deny; they differ in which act is dangerous,
    so reusing the kill predicate here would invert it: `idle` is
    kill-authorised, and an `idle` skeptic is the most re-pinnable state
    there is. Every indeterminate reading (`empty` especially) and every
    state a future `pane-state.sh` adds resolves to **alive**.
  - **Which way it errs, stated rather than left to fall out.** The field
    never suppresses the request, so a wrong `yes` costs one look at a named
    window while a wrong `no` costs a duplicate reviewer rebuilding an
    enumeration and posting into an issue the operator is reading. It errs
    toward `yes`. "Could not look" (no tmux, no window list, no `jq`) is a
    third value, `unknown`, not laundered into `no`; every verdict quotes the
    evidence it rests on.
  - Applying the same rule to the fix turned up one more instance: the
    single-batch `jq` over the record store aborts on the first **malformed**
    record, exiting non-zero having emitted only the files it reached — an
    invisible truncation feeding a confident `no`. The rc is now read; partial
    results are still used, but the lookup is marked blind, and a blind lookup
    cannot produce `no`.

- **`test-remote-identity-health.sh`'s three fixture daemons now scale their
  bind ceilings, instead of asserting an unloaded-host timing (`#558` class).**
  The suite referenced `th_deadline` **zero** times: `start_sshd` (12 s),
  `start_banner_only` (8 s) and `start_forger` (8 s) each polled a flat,
  unscaled ceiling. At `--jobs 4` on a 2-vCPU runner that reddened case 12 —
  `the forging fixture could not start — case 12 did NOT run` — in **one of six**
  matrix cells, the one whose name (`NEXUS_ROOT exported`) invites a
  configuration diagnosis it does not deserve.

  This is verbatim the failure `th_deadline`'s own docstring documents:
  *"`test-jupyter-service.sh` … green 93/93 standalone, failing EVERY
  full-suite run at `--jobs 4`, because its 20 s deadlines were sized on an
  idle host. Nothing was wrong with the code under test."*

  Evidence it is the deadline and not the environment variable: the suite
  passes **6/6 locally with `NEXUS_ROOT` exported AND with it unset**, and it
  was green in that same cell one commit earlier. A polled ceiling costs zero
  wall time on a green run, so scaling changes only how long a genuinely broken
  fixture takes to be declared broken — at scale 1 the poll counts are
  byte-identical to the old flat values.

  Fixed by scaling rather than by raising the flat number, and **not** by
  re-running the band: a retried green is not a first-pass green, and
  `ci-signal` reports it as `REPLACED-VERDICT` (exit 6) precisely so it cannot
  be laundered.

### Added

- **`CLAUDE.md` gotcha: a value sampled across refs is a timeline only if each
  ref is an ancestor of the next (`#804`).** `git show <ref>:<path>` answers
  "what did this tree contain", never "what happened in what order" — but a
  monotone count series *reads* as a narrative, and the narrative is usually the
  thing you were trying to establish. It has already published a wrong
  mechanism: a `3 → 0 → 0 → 1` series across four unrelated branch tips became
  "`#791` fixed it and `#781`'s merge resurrected it", when the function being
  counted did not exist on `#791`'s branch at all (retracted on `#790`).
  The entry carries the two-line check in a delimited block, executed by
  `test-claude-md-ancestor-timeline.sh` against a fixture repo whose true
  history is known by construction — so the expectation never comes from the
  thing under test. The suite reproduces the trap rather than only guarding
  against it: it asserts the misleading series is exactly `3 0 0 1` **and that
  every `git show` in it exits 0**, because the defect is not that the wrong
  reading fails but that it succeeds while lying. A linear chain is the positive
  control, without which an `--is-ancestor` that always said no would pass.
  The zsh half is pinned too, since it fires on this exact call shape:
  `git show "$ref:results/count.txt"` silently becomes `mainesults/count.txt`
  (`:r`), so the documented form is always braced. That assertion **skips
  loudly** where zsh is absent rather than passing silently.

- **`monitor/guards-for-diff.sh` — which guards READ the files you changed
  (`#803`), asked of the guards themselves.** A PR's green covers the suites its
  diff **touches**, not the suites its change **affects**; three occurrences in
  one night, each a guard whose scanned population the change had just entered,
  keyed on a source construct rather than on a directory. "Run the full suite"
  is the workaround (~570 s over 270 files), so in practice workers run what
  they *believe* is relevant — and believing correctly is what failed three
  times.
  There is **no registry of guards** in the tool. A guard is discovered iff it
  implements the `--population` protocol (`monitor/_guard_population.sh`), and
  the discovery predicate is the implementation itself — the literal call
  `gp_handle "$@"` — not a name, a directory, or a comment that can drift from
  it. Deliberately the CALL and not the flag string: a rule whose false
  positive is *execute an arbitrary test suite* is not a discovery rule.
  **Population means the set of files whose BYTES a guard reads**, not the set
  where the construct occurs. A file scanned and found clean is exactly the file
  an edit can dirty. That definition is what makes selection sound in the
  direction that matters (a guard that does not read your file cannot be
  affected by editing it); the converse is not claimed, so the index
  over-selects on purpose. Six guards enrolled, each declaring by calling its
  **own** enumerator — never a copy, because a copy drifts and the index then
  reports with total confidence that a guard does not read a file it does read.
  Everything is fail-CLOSED: an empty population, an enumerator that errors, a
  path that no longer exists, or a guard the index could not ask are all
  REFUSALS, because downstream each is indistinguishable from "does not read
  your diff". An empty **selection** is a sentence with the full considered
  list and its own exit code (3), never silence.
  The coverage boundary is pinned as DATA in
  `monitor/watcher/guard-populations.manifest` and enforced by
  `monitor/watcher/test-guards-for-diff.sh` (40 assertions), on the axis the
  mechanism varies on — **how a guard declares what it reads**. The index
  prints its own residual on every run (*291 of 297 tracked suites declare
  nothing and are invisible to this index; it is not a substitute for the full
  suite*), so the number is measured rather than implied, and it is a ratchet
  that should only fall. It also states the one thing no per-branch index can
  see: populations are computed against **your** tree, so a guard whose
  population DEFINITION changed on another branch selects differently after
  merge — `#803`'s first occurrence (`#781` × `#791`) exactly.
  Available as `ng guards-for-diff [--run]`.

- **`ng-usage.jsonl` rows name their producing suite (`#720`).** `win` is empty
  on every row written on a CI runner (no tmux) and `ts` has one-second
  resolution while the band runs at `--jobs 4`, so the CI occurrence at
  `d1cc62b` — 23 rows leaked into the inherited root — was narrowable to four
  concurrent `ng`-verb suites and no further. `#720`'s own comment named two
  remedies and called this the better one: `watcher/run-tests.sh` now sets
  `NEXUS_TEST_SUITE=<parent>/<basename>` per child and `_usage_tap` writes it as
  a new `src` field, so the row is self-attributing with no second run, no
  bisect and no runner minutes — and it survives any future `--jobs` value,
  which serialising the band would not. A separate field, never folded into
  `win`, which `ng usage` groups by.
  **`#720` is not closed by this.** Its closing condition is a CI occurrence
  classified to a producing suite; this is the instrument that makes the next
  one classifiable, which is a different claim. The prior negative (31 probed,
  17 hermetic, 14 TIMEOUT, 0 leaks) is untouched and was **not** re-derived —
  the selector that produced "31" is a description of a result, not a
  reproducible predicate, and re-collecting under a fresh grep would be
  `#721` rewrite 1's error a third time.

- **`monitor.integration_branch` — one property, one claimant, enforced by
  construction (`#763`).** "The branch merged fixes land on" is repo-wide,
  but it was recorded under `monitor.clone_drift.branch`, a name scoped to
  one of its two consumers, and each consumer looked it up on its own.
  `#754` declined to fix the name precisely because a second key would be
  *worse* than the bad one: two records of one property drift apart, and the
  deployment gate and the drift detector would then disagree about the same
  clone. So the fix is a shared resolver, not a rename.
  - `monitor/_integration_branch.sh` (new) is the single chain:
    `$MONITOR_INTEGRATION_BRANCH` → `$MONITOR_CLONE_DRIFT_BRANCH`
    (deprecated) → `monitor.integration_branch` → `monitor.clone_drift.branch`
    (deprecated, honoured with a one-line note) → `dev`. Both consumers —
    `monitor/watcher/_clone_drift.sh` and `cc-auto-update-apply.sh`'s
    `_gate_integration_branch` — now call it and hold no private lookup.
    `_clone_drift_tick`'s own `${MONITOR_CLONE_DRIFT_BRANCH:-dev}` was a
    second claimant in its own right: it answered `dev` for every caller
    that had not sourced `_config.sh`.
  - **The migration is the hazard, not the rename.** `config/nexus.yml` is
    per-operator and not tracked here, so a bare rename lands on every clone
    as a silent default-fallback — the new key absent, the default applied,
    an operator who deliberately set `release` silently getting `dev`,
    nothing erroring, on the surface `#754` had just finished making
    trustworthy. Hence read-both / prefer-new / note-on-old.
  - **The trap lives inside the remedy.** `config/load.sh <key> <default>`
    prints `dev` both for "absent" and for "set to dev", so a resolver
    written that way never reaches the deprecated key and reproduces the
    reported bug inside its own fix. The resolver therefore calls the loader
    with **no default** and branches on the exit code — rc 2 (absent) is the
    only code that licenses falling through; rc 1/3 ("could not look") get a
    distinct `default-unreadable-config` source and a loud note, because a
    missing config file must not read like a deliberate `dev`.
  - Both keys present with different values is reported as a `CONFLICT`
    rather than silently resolved. `monitor/watcher/test-config-integration-branch.sh`
    (new, 44 assertions) pins the old-key-only/non-default case together with
    a **negative control** that runs the naive rename against the same
    fixture and asserts it answers `dev`; `test-cc-auto-update.sh` gains the
    gate-level twin.
  - The resolver is a core (`_nexus_resolve_integration_branch`, sets
    `$NEXUS_INTEGRATION_BRANCH_VALUE`/`_SOURCE` in the caller's shell) plus
    two wrappers: the branch on stdout, or `<branch>\t<source>` for the
    `$( )` caller. Smoke-testing `_config.sh` under `set -u` caught the first
    shape asserting a contract it did not keep — `$( )` is a subshell, so the
    provenance assignment died there and a reader got "unbound variable".
  - **The deprecated key is read until 2026-11-07**, a date carried in the
    operator-facing note itself (not only in this changelog) and asserted
    identical across the resolver, `monitor/README.md` and
    `config/nexus.example.yml`.

- **A merge-conflict marker in a tracked file now reddens CI, and it is
  checked tree-wide rather than per-suite (`#774`).** One `|||||||` line in
  `CHANGELOG.md` reached `dev` and survived **seven** consecutive merges.
  Re-derived from history here (marker count in the merge, then in each
  parent): `#760` 0/0/0 · `#759` 1/0/**1** · `#758` 1/1/0 · `#761` 0/1/0 ·
  `#766` 0/0/0 · `#756` 1/0/**2** · `#772` 1/1/0. Non-monotonic: introduced on
  the `#759` head, silently removed by an unrelated rebase resolution at
  `#761`, silently reintroduced on the `#756` head. No step in that sequence
  was aware of it, because nothing looked.
  - `monitor/test-conflict-marker-lint.sh` (new) scans every `git ls-files`
    path for all four canonical markers. Replayed against history it reddens
    at exactly the four merges that carried one and stays green at the three
    that did not.
  - **The diff3 marker is the one that matters, and a guard checking only
    `<<<<<<<`/`>>>>>>>` reproduces the bug.** Every marker in this repo's
    history was `|||||||` — it appears only under `merge.conflictStyle =
    diff3` and, rendered in a Markdown changelog between two bullet blocks, it
    does not *look* like damage.
  - **No filename allowlist and no exemption mechanism at all.** The lint scans
    itself like any other file; assertions fail if either `CHANGELOG.md` or the
    lint drops out of the scanned set. What makes that safe is that **markers
    are matched only at LINE START — never begin a line with one; indent an
    illustrative marker by one space.** That rule is now pinned by four
    assertions (column 0 matches; the same marker indented, mid-line, or in
    backticks does not), because the justification first recorded here — "the
    lint carries no literal marker anywhere" — was **false**: the trailing
    comments on its own pattern constructors are literal seven-runs, harmless
    only because they sit mid-line. The distinction matters because this gate
    has no escape hatch and runs on every PR, and a fenced example of a
    conflict is a natural thing to write when documenting this very feature.
  - `.github/workflows/conflict-markers.yml` (new) runs it with **no `paths:`
    and no `branches:` filter**. `CHANGELOG.md` matches no existing workflow's
    filter, so `ci-trigger-audit.py` reported `gating workflows for this PR:
    NONE` — exit 0 — for a CHANGELOG-only change; it now names this workflow.
    Adding `CHANGELOG.md` to `tests.yml` would have been a filename allowlist
    standing in for a whole-tree property. The two triggers are not redundant:
    `pull_request` checks the merge preview, `push` is the only one that can
    see a marker introduced **by the merge resolution itself**, which `#761`
    and `#756` show is a real source and not a hypothetical one.

- **A boot wedged on the Bypass Permissions modal now names itself instead of
  reporting `empty` (`#768`).** The binary migrates
  `.claude.json`'s `bypassPermissionsModeAccepted` into `settings.json` as
  `skipDangerousModePermissionPrompt: true` and **deletes the original**
  (measured on 2.1.224), so after any boot only `settings.json` suppresses the
  warning — and anything rewriting that file between boots without
  re-supplying the key wedges the next boot on the modal.
  - The modal reached **no** overlay arm in `monitor/pane-state.sh`: it has a
    `❯ N.` menu but not `Do you want to proceed?`, so it fell through to the
    input-row logic. With claude alive that yields `empty` — *"don't know
    yet"* — so a deterministic config fault presented as a **slow boot**. It
    cost a probe run of three cells reported as "VI mode is unreachable". That
    `empty` path is what this arm addresses, and only it: a pane whose pid
    yields no live claude reports `absent` (the one **kill-authorising** state)
    from a liveness gate ~260 lines upstream that the overlay check never
    reaches. Moot in production — a wedged modal means claude is alive — but
    the `absent` side is `#780`'s territory, not this arm's.
  - `_has_bypass_permissions_modal` adds the fourth arm, and `state=blocked`
    now always carries `overlay=<rate-limit|permission|bypass-permissions|askuq>`.
    `blocked` was already correct for all four (it is in `_BK_ACTIVE_STATES`,
    so never kill-authorised, and no `_unstick.sh` arm fires on this modal —
    every arm there needs two co-occurring literals it does not carry, so
    nothing auto-answers a security prompt). The **kind** is what turns
    "something is blocked" into a diagnosis.
  - A **live-vs-quoted guard** is load-bearing rather than defensive: the
    modal's text is quoted in the issue, in `pane-state.sh`'s own comment and in
    `synthesize.sh`, so any agent reading them has every shape literal on
    screen. It is **two** tests, and the structural one carries the weight: a
    live modal REPLACES the REPL, so no `❯<NBSP>` input row may appear below the
    footer. A bottom-slice margin alone was not enough — the `#776` skeptic
    **constructed** the pane that defeats it (an idle agent quoting the modal
    with two chrome rows below), which is now a committed boundary fixture.
    Their proposed remedy, tightening the slice to `tail -n 1`, was declined
    with reason: it keeps a margin as the discriminator and trades a
    safe-direction false positive for an **unsafe** false negative — trailing
    chrome on a real wedged pane would drop the case back to `empty`, and
    neither of us has a capture of one. Each test is proven load-bearing by a
    mutation against the pane only *it* rejects.
  - **A name nobody prints is not a diagnosis**, so the cc-harness
    `wait_for`'s expiry now
    emits the observed pane-state line — and, for this overlay, the re-seed
    remedy. `monitor/watcher/test-cc-harness-waitfor-diagnostic.sh` (new)
    covers it hermetically (no binary, no node, no tmux): it is a
    FAILURE-path emit, which a passing gate run never exercises. Its controls
    are the load-bearing part — a plain `state=empty` must still be reported
    but must NOT be attributed to the modal, a `permission` overlay is
    reported as itself, and a satisfied wait stays silent.
  - Recorded where the next person meets it: cc-update collision surfaces
    `2d` (the migration, with the measured before/after) and `2a` (the modal
    literals are now a detection surface).

- **A `nexus-remote-ssh` port change now reaches the operator durably, and
  the alert itself fails loud (`#757`).** `select_and_record_port`'s header
  promised an alert that is *"LOUD and DURABLY"*; what implemented it was a
  single `sandbox-notify`, `2>/dev/null`-muted and `|| true`-swallowed. The
  port-selection logic was and stays sound — sticky preference, fail-closed
  identity probe, refusal to move on an INDETERMINATE verdict. The **alert**
  was the defect, and it is this repo's dominant class (silence read as
  delivery) arriving one layer up.
  - A bell is ephemeral, and the event it exists for is a reboot-time
    bring-up. Worse, and **measured** rather than reasoned: that exact message
    matches no arm in `monitor/notifywrap/sandbox-notify` and falls to the
    default `task` class — the catch-all every worker `ready`/`done` ping also
    lands in — so its 300 s cross-window cooldown BATCHES it. Fire any other
    task-class bell, then the port alert 1 s later, and the decision log reads
    `"verdict":"suppress-cooldown"` with zero bells emitted.
  - `monitor/remote-port-change-notify.sh` (new) fires **only on an actual
    recorded change** (a sticky recorded port never re-fires, so a restart loop
    cannot spam) and fans out over surfaces that outlive the session: a bot
    comment on the operator's endpoint tracking issue, a push
    (`monitor/notify.sh --priority emergency --require-delivery`), and a local
    copy that is deliberately **not** counted as delivery.
  - The issue target resolves from new `monitor.remote.endpoint_issue` /
    `endpoint_issue_repo` keys with **no default** — nexus-code is cloned by
    every operator, and a literal number would post one operator's endpoint
    into somebody else's thread. **Unset is a FAILED surface, never a silent
    skip.**
  - The comment carries *the exact text to forward to the client agent*: new
    `host:port`, the fingerprint to re-pin (unchanged — the host key does not
    move), and, when `_remote_from_audit` says so, **"a re-enroll is also
    owed"** with the remedy, so a port change and a `from_cidr` re-pin are one
    client touch rather than two. That paste (`_remote_client_repin_notice`) is
    single-sourced with `_remote_onboarding_notice` through the new
    `_remote_endpoint_params`, so the out-of-band text cannot drift from what
    the client is told once it reconnects.
  - Fail-loud without blocking: zero durable deliveries ⇒ exit 3 plus a
    `port-change-notice.UNDELIVERED` marker that `remote-up.sh --status`
    surfaces on **every** run until resolved. The bring-up still completes —
    the port has already moved and been recorded by then, so aborting would
    leave a stale client *and* a dead endpoint.
  - The transient bell is kept but prefixed `CRITICAL:`, which measurably
    moves it out of the `task` catch-all into the `critical` class — it now
    rings where the shipped text read `suppress-cooldown` under identical
    conditions. It stays defence in depth, never the durable surface, and its
    failure is reported rather than swallowed.
  - **The marker's OWN failures are reported too.** A skeptic pass found the
    persistence mechanism was itself `|| true`-swallowed: on an unwritable
    `principals_dir` the emitter announced "Marker written" with no marker on
    disk, and a successful delivery whose `rm -f` failed left a STALE marker
    that `--status` would then cry wolf over forever, silently. Both paths now
    pre-check writability — so a shell redirection diagnostic cannot bleed out
    unattributed (`#723`) — and VERIFY rather than assume. Neither changes the
    delivery verdict.
  - A refusing `--dry-run` no longer arms the persistent marker: a rehearsal
    was never going to deliver, so there is no delivery failure to make
    durable, and marking would make `--status` cry wolf over a notice that
    does not exist — the inverse of the failure the marker exists to prevent.
    The gate still runs in dry-run (a rehearsal that skips the gate the real
    run must pass is not a rehearsal), and the refusal is still loud and rc 3.
  - `monitor/watcher/test-remote-port-change-notify.sh` (new): 124 assertions
    enumerating the axis the mechanism varies on (which durable surface
    accepted), shown non-vacuous by 13 mutants — the reverted swallow, an
    always-0 verdict, a silent unconfigured skip, a removed secret guard, a
    dropped re-enroll clause, an uncleared marker, a blocking alert, a silent
    `--status`, a reverted `CRITICAL:` prefix, an unchecked marker write, and
    a silent stale-marker clear, a marker-arming rehearsal, and a gate-skipping
    rehearsal — each reddening distinct assertions with the count unchanged
    at 124.

- **A red in the SLOW band can no longer be silent about which assertion
  failed (`#752`), and the respawn fixture can no longer spawn the
  operator's real Claude Code binary (`#746`).**

  `#752` was filed as a suspected flake: at head `d4df844f`
  (run `31153179861`) the blocking SLOW band went red on attempt 1 and
  green on attempt 2 at the same sha, with `test-respawn-loop-integration.sh`
  reporting `rc=1` and **no** failing assertion. Reading both attempts'
  artifacts refutes the premise. That test failed on **both** attempts,
  identically; it was a tolerated entry in `monitor/slow-band-known-red.tsv`
  at that sha, so the job went green anyway. The only test that flipped is
  `test-jupyter-service.sh`, already fixed by `#749`. There was no flake here
  to diagnose — the red was deterministic and knowingly excused.

  What was real is the legibility half. `run-tests.sh` built its failure
  detail by tailing `.err` alone — a **proxy** for "show what the test said".
  That suite's `.err` was 0 bytes and its `.out` was 10,563 bytes ending
  `FAIL: guard did not trip within deadline`, so the runner had the diagnosis
  on disk and printed none of it. The fix is in the **runner**, not the tests:
  the affected set is not statically decidable, because sourcing
  `_test_helpers.sh` is no guarantee — that suite *does* source it and routes
  every `assert_*` to stderr correctly, but hand-rolls its terminal verdict.
  A corpus scan misses the very file that motivated the change — and does so
  under *every* operationalization, since that suite carries `FAIL … >&2` at
  its fixture-drift guard, so any static "does it route FAIL to stderr" scan
  classifies it compliant. (One such scan scores 63 of 271; the predicate is
  spelled out verbatim at `_rt_failure_tail`, because the phrase alone admits
  readings scoring 23-207.) `run-tests.sh` now falls
  back to the stdout tail when stderr is empty, labels which stream it read,
  and says so explicitly when a test emitted nothing at all.

  `#746`: the fixture installs a stub `claude` and puts its dir first on
  `PATH`, but that does not make the stub win — `monitor/locals-env.sh`
  re-fronts `$NEXUS_LOCALS/bin` ahead of it, reached by every non-interactive
  bash via `BASH_ENV`. Running the band the documented way therefore started a
  **real, billed Claude Code session inside the fixture**; CI escaped only
  because it invokes the band under `env -u NEXUS_ROOT -u NEXUS_LOCALS`. New
  shared helper `th_require_stub_claude` asserts the **resolution** rather than
  PATH order (an exported `CLAUDE_BIN` short-circuits `_claude-bin.sh` before
  `PATH` is consulted at all) and refuses before anything spawns. The fixture's
  crash-log guard also stopped asserting *fixture copy-list drift* as the cause
  — a real failure mode this file has had three times, and the wrong one on
  `#746`, which sent the reporter to audit the one place the problem was not.
  It now states what was observed and ranks the candidates.

  Also measured while here: this test hardcoded a bare `+ 60` deadline and
  never called `th_deadline`, so `#749`'s band-wide `NEXUS_TEST_DEADLINE_SCALE=2`
  had **no effect on it** — `#752`'s hypothesis that `#749` "may well cover
  this too" cannot hold. It now scales.

- **A workflow can no longer invoke `run-tests.sh` with an inert deadline
  scale (`#751`, generalising `#749`).** `th_deadline()` scales polled
  deadlines by CPU oversubscription, `ceil(NEXUS_TEST_JOBS / nproc)`. A band
  passing no `--jobs` gets `jobs=1`, so on a 2-vCPU `ubuntu-latest` the scale
  is `ceil(1/2) = 1` and every deadline is its bare literal — while the
  deadlines carry comments saying they are scaled. `#749` made the effective
  scale *visible* in `run-tests.sh`'s header; that is legibility, and it
  requires someone to read the log of a run that already happened.

  New `lint-workflows.py` rule family **TD**. `TD001` requires any step
  invoking `monitor/watcher/run-tests.sh` to either set
  `NEXUS_TEST_DEADLINE_SCALE` explicitly or pass `--jobs N` with **N greater
  than** the runner's vCPU count. The `>` is load-bearing: `ceil` is not
  strictly increasing here, so `--jobs 2` on a 2-vCPU runner is `ceil(2/2) = 1`,
  identical to passing nothing — a rule demanding merely "some `--jobs`" would
  bless the inert case. This widens the linter's remit from MC + SR, a scope
  decision `#751` hands over deliberately.

  Verified against its own motivating case: run against the workflow file as
  it stood *before* `#749`'s fix, `TD001` flags the exact step `#749` repaired.
  A rule that would not have caught the bug it generalises is not a fix.

  Re-deriving the call sites found **four** exposed, not the two `#751`
  enumerated: `cc-harness.yml`'s real-binary scenarios (sequential, so no
  `--jobs`, and its deadlines poll a real Claude Code pane — the slowest thing
  this repo waits on), two steps in `tests-slow-integration.yml`'s
  `slow-integration` job, and `tests.yml`'s `jobs: 2` matrix cell. All four now
  set the scale explicitly; setting it only lengthens deadlines, so the change
  cannot introduce a new failure.

  Coverage boundary, stated on the rule: TD001 judges the **invocation**, not
  whether the tests behind it honour the scale. A test that hardcodes a literal
  deadline instead of calling `th_deadline` is invisible to this rule *and* to
  `#749`'s header — both report the scale, neither reports who consults it.
  `test-respawn-loop-integration.sh` was exactly that case (`#752`).

- **The cc-harness now boots the keyboard mode production actually runs
  (`#724`).** `cch_setup` seeded no `editorMode`, so every real-binary
  scenario — and the whole pre-update gate — booted the DEFAULT mode while
  every nexus agent inherits `editorMode: "vim"` from user scope. The gate
  was validating a configuration nobody is in, same class as the `tui` fix
  in `#568`. It is not cosmetic: vim mode paints `-- INSERT --` into the
  status row, and `pane-state.sh`'s `_detect_vim_insert` reads exactly that
  row to decide `user-typing` vs `idle`, so the production keyboard mode is
  an INPUT to the classification the harness exists to gate.

  Measured against 2.1.224 before seeding anything, because seeding it by a
  route production does not use would reproduce the defect one level down:
  the key is live in BOTH `$CLAUDE_CONFIG_DIR/settings.json` and
  `.claude.json`, and either alone suffices — `-- INSERT --` renders from a
  settings.json-only seed, from a .claude.json-only seed, and from neither
  when neither is present. The harness seeds it the way the operator
  declares it.

  `test-realmodel-vimode.sh` is committed rather than left as the throwaway
  scratchpad probe of the 2.1.223 evaluation, so no future candidate
  evaluation restarts blind, and it is wired into `gate.sh`'s HARDCODED
  scenario list — a scenario that exists but is not named there is not
  gated, which would have been `#724` one level down. The **control boot is
  the non-vacuity assertion**, because the obvious version of this test is
  vacuous: an unseeded vim probe asserts a marker against a binary never put
  into vim mode. Seeded worker => marker PRESENT, unseeded control => marker
  ABSENT; neither cell alone is evidence.

- **A shell-option scope guard (`#721`).** `test-ambient-shell-option-scope.sh`
  holds the two invariants that keep `#721`'s masking class dormant: no test
  file may both set an option ambiently and source a library that scopes it
  (P1), and no SOURCED library may restore an option with an unconditional
  `shopt -u` (P2). P2's population is DERIVED from the tree rather than
  listed — a leak crosses a function return, not a process boundary, so a
  script nothing sources cannot leak to anybody, and the day something
  sources it the file enters the gated set on its own.

  P1's envelope is narrower than that sentence and the file says so where a
  reader hits it: *glob-family options, line-anchored `shopt -s`, DIRECTLY
  sourced libraries.* Transitive sourcing, non-glob options and inline
  conditional setters are out of reach — measured, not live on this tree, and
  tracked as a follow-up. A guard that overstates its envelope is worse than a
  narrow one.

### Fixed

- **Three checks that answered a different question than the one asked, and
  reported success (`#762`, `#773`, `#765`).** One defect class in three
  costumes: *did the concluded runs pass?* substituted for *did everything
  conclude?*; *is Actions broken?* for *is this PR conflicted?*; *did the
  triggered workflows pass?* for *was this change actually tested?* Each
  substitution renders as a green.
  - **`#762` — a green quantified over an empty set.** `ci-trigger-audit.py`'s
    `OK:` line and `ci-head-attempts.sh`'s `VERDICT:` lines both asserted over
    the CONCLUDED subset, so a head whose bands were all `in_progress` made
    the claim vacuously true and printed it as `OK` … `cleared`, at exit 0.
    Observed live on PR `#758`'s own head. The per-row output already said
    `.... still in_progress`, which is the tell that the bug was in the
    AGGREGATION — so the fix changes what the claim is quantified over
    (`gating`, not `gating minus pending`) rather than rewording the summary.
    New exit **3**, NOT CONCLUDED, with distinct sentences for "none
    concluded" (no evidence at all) and "some concluded" (partial and
    provisional) under one code, because the belief differs and the action
    does not.
  - The two consumers want opposite things from that state, which is why one
    number could not serve both. `ci-signal.yml` is a PEER check racing its
    siblings — it finishes in about a minute, the bands take tens of minutes —
    so it maps 3 to success and says so in a `::notice::`; reddening it would
    have muted the guard on essentially every PR. `ng ci-attempts` is read on
    the MERGE path and maps the same 3 to a refusal to clear. Both boundaries
    are stated in code at the point the reader forms the belief.
  - **`#773` — a conflicted PR gets ZERO check-runs by construction.** A
    fourth cause of the empty observed set that `#758`'s three-way
    decomposition did not name: with `mergeable_state: dirty` the merge ref
    `refs/pull/N/merge` is uncomputable, and `push:` is scoped `[main, dev]`,
    so neither trigger can fire. It landed in the outage arm and pointed the
    reader at GitHub — which on PR `#744` produced the diagnosis "Actions
    stopped creating runs repo-wide" while PR `#767` had 13 runs at the same
    moment. Now its own arm and its own exit **7**, with a remedy naming the
    rebase. The issue supposed `mergeable_state` was already fetched here; it
    was not, appearing only in a comment, so this costs one API call — spent
    lazily, only on the paths where the answer changes the advice, and cached.
  - The arm's boundary is drawn in code, not only in prose: `dirty` is
    CLAIMED; `clean|behind|blocked|unstable|draft|has_hooks` are NOT (none
    stops the merge ref computing, and `behind` in particular is not a
    conflict); and `unknown` is neither — GitHub computes mergeability in a
    background job, so it is retried and then REPORTED as unread rather than
    silently read as "not conflicted".
  - **`#765` — a path filter that hid the runner it invokes.**
    `cc-harness.yml`'s `paths:` omitted `monitor/watcher/run-tests.sh` and
    `monitor/watcher/_test_helpers.sh`, so a PR to the real-binary runner got
    zero real-binary evidence behind a full, correct-looking enumeration.
    `#568` D6 had already fixed this once by hand under a comment stating the
    principle exactly — and left the runner out, because nothing recomputed
    the closure.
  - So the filter is now **derived, not patched**: new rule family **PF** in
    `monitor/lint-workflows.py` computes a workflow's transitive
    execute/source closure from its own `run:` steps and fails when the
    `paths:` filter does not cover it. It found **eight** omissions, not two —
    including `monitor/_submit_evidence.sh`, three hops out
    (`pane-state.sh` → `_idle_probe.sh` → `../_submit_evidence.sh`) behind an
    inline `$(dirname "${BASH_SOURCE[0]}")`, which is why no reader ever wrote
    it down.
  - PF is a **lower bound** and says so wherever it reports: a path built from
    a runtime variable cannot be resolved, so unresolved edges are counted and
    printed, and a clean PF result means "no hole on the edges it could
    follow", never "the filter is complete". It deliberately does NOT flag
    superfluous entries — the lower bound makes "matches nothing I derived"
    evidence of nothing.
  - **`tests.yml` does NOT have the same hole**, checked rather than assumed:
    PF reports it CHECKED and clean, because its filter globs coarsely
    (`monitor/**`, `config/**`, `.github/workflows/**`, `CLAUDE.md`) where
    `cc-harness.yml` enumerates leaf files. Enumeration is kept for
    `cc-harness.yml` regardless — it boots the real binary twice, and
    `monitor/**` would run it on every unrelated monitor change — which is
    safe now only because PF checks it.
  - **And a fourth, found by `#762`'s own PR going red: `ci-signal.yml`'s
    exit-code dispatch was DEAD CODE for every non-zero rc.** GitHub runs
    `run:` bodies under `bash -e {0}`; the audit step opened with `set -uo
    pipefail`, which does not clear `-e`, and ran the audit as `python3 … |
    tee`. Under errexit+pipefail a non-zero audit aborted the step AT THE
    PIPELINE — before `rc=${PIPESTATUS[0]}`, so the whole `case "$rc"` never
    ran and not one `::error::ci-signal: …` explanation was ever emitted. The
    red was correct; the sentence saying WHY was silently dropped. This is
    `#739` recurring in a second workflow, and the same defect class again: an
    absence that looks like nothing is missing, inside the guard written
    against it. Fixed with an explicit `set +e -uo pipefail`, guarded by a new
    `monitor/test-ci-signal-step-contract.sh` (8 assertions) that EXTRACTS the
    real step body and EXECUTES it under `bash -e` — the sibling of
    `test-slow-band-step-contract.sh`, same method, other file — with a mutant
    restoring `set -uo pipefail` to prove `+e` is what makes the dispatch
    reachable.
  - **And the skeptic pass on this change caught the same defect in its own
    remedy.** `ci-signal.yml`'s new comment justified mapping exit 3 to success
    with *"the pending bands carry their own required check-runs and GitHub's
    own gate independently blocks the button on them."* **Both halves are false
    here** — `branches/{dev,main}` report `protected: false` with
    `required_status_checks.contexts: []`, all three ruleset endpoints return
    `[]`, and a live PR with six `failure` check-runs reports
    `mergeable_state: unstable` rather than `blocked`. The sentence was
    inherited verbatim from issue `#762`'s own text, and this change's own
    report contained the refuting fact. Citing a guard that does not exist, in
    a change whose thesis is that stated-but-unchecked properties are the
    dominant defect, WAS that defect. The mapping stands on two grounds that
    are actually true — it is structurally unreachable when a band is absent
    (that is exit 4, and 4 is red), and pending is the normal state for a peer
    check that finishes minutes before its siblings — and the consequence is
    recorded plainly: `ng ci-attempts` returning 3 is not a second line of
    defence, it is the only one.
  - Also from that pass: the rc 3 arm now **returns** instead of rewriting `rc`
    and falling into the `case`, which had *also* printed the rc-0 arm's
    "every gating workflow … carries a success verdict" — the vacuous
    quantifier this entry is about, printed directly beneath the honest notice
    that contradicts it. Pinned by a new assertion, verified non-vacuous by
    mutation. PF now prints its resolved/unresolved edge counts on the **clean**
    path too, not only beside a finding, since green is where a bounded claim
    gets over-read (`cc-harness.yml`: 24 resolved, 22 unresolved). And the
    `#568` D6 comment is corrected: `_harness.sh`/`stub-claude.sh` are the
    substrate of the five **integration** scenarios, not of this workflow's
    realmodel ones — a true fact attached to the wrong workflow's filter. The
    entries are kept (over-inclusion hides nothing, and `monitor/**` already
    gates them elsewhere) but no longer document a false dependency.
  - Tests, each demonstrated red on the pre-fix commit rather than asserted:
    `test-ci-trigger-audit.sh` 47 → 53 assertions (case 10k, which had PINNED
    the defect by asserting rc 0 for an all-`in_progress` head, now asserts
    rc 3; plus a partial case, a control, a distinctness case and a mutant
    that restores the vacuous green); `test-ci-head-attempts.sh` 14 → 20
    (all-pending, partial, control, `dirty`, a clean-PR control proving the
    arm discriminates rather than relabels, and `unknown`);
    `test-lint-workflows.sh` 18 → 23 (four planted PF repos in `--selftest`
    plus two mutants of the real `cc-harness.yml` — one restoring `#765`
    verbatim, one stripping the three-hop edge so a resolver that degraded to
    one hop cannot pass).

- **Three sourced libraries no longer hand their caller a glob option OFF
  however it had it (`#721`).** `_trash.sh:158` and `watcher/_requests.sh`
  x2 converted to the `shopt -p` / `eval` save-restore form already in
  `watcher/main.sh` and adopted by `#726` at `_idle_probe.sh`. These three
  are the only ones of `#721`'s eight listed sites that are structurally
  CAPABLE of leaking; the other four (`install-claude-local.sh`,
  `upload-asset.sh`, `ng` x2) are sourced by nothing, and
  `_test_helpers.sh:56` neutralises a bash 5.2 interpreter default rather
  than a caller's option and is exempted by MARKER with a reason.

- **`cch_write_settings` makes a between-boot re-seed safe.** The real
  binary MIGRATES `.claude.json`'s `bypassPermissionsModeAccepted` into
  `settings.json` as `skipDangerousModePermissionPrompt` on first boot and
  deletes the original, so a scenario that rewrote `settings.json` between
  boots wedged the NEXT boot on the Bypass Permissions modal — forever, at
  `state=empty`, which reads as a timeout rather than a config error. Found
  while building `#724`'s control boot, which is the first scenario to need
  two boots with different settings.

### Changed

- **The inherited-root warn step now PRINTS the leaked rows, not just their
  paths (`#720`).** The artifacts self-attribute and nobody had read them:
  an `ng-usage.jsonl` row carries `verb`/`sub`/`origin`/`win`/`pid`/`ts`.
  This makes the next CI occurrence attributable; it does not attribute the
  recorded one, and `#720` stays open on that distinction.

- **A green that required a re-run is no longer readable as a first-pass
  green (`#748`).** Nothing in the nexus read GitHub's `run_attempt`.
  This is the programmatic half `#750` defers ("any future consumer that
  reads CI state programmatically — a watcher emit, `ng`, a dashboard
  section — inherits the same blindness"); `#750` covers the SLOW band's
  own run summary, this covers everything that reads CI *about* a head.
  `GET /actions/runs`, `gh run list` and the check-runs API all return only
  the **latest** attempt, so a band that concluded `failure` and was re-run
  to `success` **at the same sha** was byte-identical to one that passed
  first time — to every tool, every emit and every check in this repo. At
  head `d4df844f` the SLOW band did exactly that (`test-jupyter-service.sh`
  went red, then green on re-run) and read as clean; the red was found only
  by enumerating attempts by hand.
  - This is a **different** failure from the ones `#604`/`#628` cover, and
    the distinction is load-bearing. Those are species of *absence* —
    no run, or a run that reached no verdict — and are caught by
    enumerating that every expected band is named and `success`. A
    **replaced** verdict defeats that enumeration by construction: the band
    *is* named and *is* `success`. So it is reported as its own finding
    rather than folded into the existing ones.
  - `monitor/ci-observed-runs.jq` now carries `run_attempt` and `id`. This
    costs **zero** extra API calls — the field was in the payload
    `ci-signal.yml` already fetched, and the extractor was dropping it.
  - `monitor/ci-attempt-history.sh` (new) resolves what the *superseded*
    attempts concluded, one call per superseded attempt and none at all for
    the overwhelmingly common attempt-1 head. `run_attempt` says a retry
    happened; only this says what it replaced.
  - `monitor/ci-trigger-audit.py` gains `classify_attempts()` and exit
    code **6**: `REPLACED-VERDICT` when a superseded attempt concluded
    `failure`, `ATTEMPTS-UNKNOWN` when its conclusion could not be read.
    A retry over a `cancelled` attempt replaced no verdict and is a stated
    **note**, not a finding. Exit 6 ranks *below* `FAILED`, so it carries
    the narrow meaning "the check set is otherwise clean and the thing
    wrong with it is the retry".
  - Absence of the attempt column reads as **UNSUPPLIED**, never as
    attempt 1 — otherwise the audit would print "each of those greens is a
    first-pass green" having looked at nothing, which is the detected
    defect wearing the detector's clothes. The positive claim is made only
    when provenance was actually supplied.
  - `ng ci-attempts <sha|branch|PR#>` (new) is the agent-facing half. The
    near-miss was not a PR gate failing — it was an agent reading `gh run
    list` at a head and concluding "green, merge it". This workspace's
    standard already says to enumerate CI "by name AND by attempt"; before
    this verb nothing did the second half.
  - `monitor/test-ci-trigger-audit.sh` grows cases 12–14 (16 assertions,
    31 → 47), including a negative control that neuters `classify_attempts`
    and confirms the new cases go green, and a stub-`gh` test asserting
    from the call log that an attempt-1 run costs no API call.

### Fixed

- **An Actions outage defeated every verdict guard at once, and the residue
  read as success (`#740`).** On 2026-08-06, PR `#739` carried zero
  check-runs at its head and presented as `mergeable=true
  mergeable_state=clean` — not pending, not blocked: *clean*. Every verdict
  guard this repo has built is **itself an Actions workflow**, so the outage
  disabled all of them simultaneously and the absence of evidence rendered
  as evidence of absence.
  - `ng ci-attempts` now **composes** the expected-band audit rather than
    punting it. That division was right about ownership and wrong about
    **reachability**: `ci-trigger-audit.py` is invoked from `ci-signal.yml`,
    which is a workflow, so the guard that would have caught the outage was
    among the things the outage stopped. `ng ci-attempts` is the only CI
    surface here that already runs **locally**, so it is where a merge-path
    reader can still get an answer. It shells out to the real
    `ci-trigger-audit.py` — nothing is reimplemented, and trigger semantics
    plus the `#628` verdict invariant keep their single owner.
  - **The zero case was never the dangerous one** — an empty run list was
    already a loud refusal here. The silent case is a **partial** set: some
    bands ran, all of them green, the missing ones invisible. "Every
    completed run is a first-pass success" is *true* and reads as approval.
    That case now exits **4**.
  - **An empty set has three causes and they no longer collapse**: the
    provider was down (bands expected, none ran → rc 4); the triggers
    genuinely select nothing (rc 4, stated as a sentence — untested on
    purpose is still untested); and *I could not look* (no PR context, so
    "no runs" cannot be separated from "no runs were expected" → rc 2,
    UNDETERMINED). Reporting these as one number would have been this
    repo's dominant defect class reproduced inside its own remedy.
  - Workflows are read **at the head sha** (local objects, then the contents
    API, then a refusal) — never from whatever this clone has checked out.
    Auditing a head against another revision's triggers would answer a
    question about the wrong tree.
  - **Two enumeration guards**, because a count that reads clean is a claim
    about the tally and not about the enumeration. The runs page is compared
    against the API's `total_count` (`per_page=100`, nothing paginated), and
    the PR's file list against `changedFiles`. A short file list would
    silently *shrink* the expected set, turning a missing band into a band
    that was never expected. Both refuse rather than report a subset.
  - The coverage boundary is declared **in the verdict**, where the reader
    forms the belief, not in a docstring: a bare sha says in so many words
    that the expected-band audit did not run and that a workflow which never
    fired would be invisible.
  - New `monitor/test-ci-head-attempts.sh` (8 cases, auto-discovered by the
    unit band). Mutation-validated: ignoring the audit in the verdict reddens
    the partial case, collapsing the empty-set causes reddens two, dropping
    the truncation guard reddens one. Exercised additionally against **real**
    heads — `d4df844f` (documented retry-over-red → rc 6) and PR `#753`
    (complete CI → cleared).
  - Note on provenance: the historical outage state is **no longer
    reproducible**. Actions has since backfilled `1d00aa71`, which now
    reports 5 workflow runs and 16 check-runs where the issue recorded zero.
    The zero-observed cases are therefore exercised on fixtures, and this
    change reproduces the outage's *shape*, not the outage.

- **The `cc-auto-update` deployment gate measured staleness against a
  branch fixes do not land on (`#754`).** PRs on this repo merge to the
  integration branch; `main` lags it by weeks. Re-measured on the live
  primary at `HEAD=f0c9510`: **5** commits behind `origin/main`, **23**
  behind `origin/dev`. Among those 23 was the `#747` merge installing
  `monitor/_pane-live.sh` — the `#745` guard whose absence lets a watcher
  paste into a dead orchestrator pane kill the tmux server, and with it
  (`bwrap` PID 1 under `--die-with-parent`) the whole sandbox. The gate
  reported "5 behind, proceed" about a clone missing the guard that makes
  the restart it authorizes survivable; a hand-set durable hold is what
  actually caught it.
  - The gate no longer implements its own staleness check. It delegates to
    `_clone_drift_probe` (`#620`), which the watcher's clone-drift detector
    already used and which was already right. **Two mechanisms answering
    "is this clone stale" was one too many** — the wrong one was the only
    one consulted at apply time. This is the collapse, not a second
    correction.
  - That fixed **two further defects of the same shape**, neither reported.
    (1) The old `rev-list HEAD..origin/main` ran after a best-effort
    `fetch … || true`, so a failed fetch left it answering **confidently
    from a stale remote-tracking ref** — measured on a fixture: it reported
    `behind=5` as fact when the true distance was **11**. The probe resolves
    the tip from a live `ls-remote`, so a failed fetch degrades the *margin*
    to `unknown`, never the *verdict* to a wrong number. (2) `behind=unknown`
    was gated behind `[[ =~ ^[0-9]+$ ]]`, so "could not measure" emitted **no
    WARN and no notification at all** — indistinguishable from "up to date".
    That is `#740`'s thesis living inside `#754`'s gate, and it is now a
    distinct, loud third state.
  - The remediation string names the ref it measured. Following the old
    `pull --ff-only origin main` landed the operator on a two-week-old tree
    that **still lacked the guard the WARN was about**.
  - The branch is **resolved, not hardcoded** — config
    `monitor.clone_drift.branch` (default `dev`), the repo's single existing
    record of the property, read rather than duplicated. Hardcoding `dev`
    would have been the same proxy one branch over. The key's name is
    historical and now under-general; renaming it is a config migration for
    every operator clone and is deliberately not bundled here.
  - Audit rows carry `behind_integration=<n|unknown> integration_branch=<b>
    drift=<up-to-date|behind|unknown>` in place of `behind_main=<n>`, so
    historical rows stay unambiguous under the new semantics.
  - Four regression cases in `monitor/watcher/test-cc-auto-update.sh`, each
    written to fail against the old code and each verified non-vacuous by
    mutation: reverting to `main` reddens 4 assertions, restoring the
    stale-ref read reddens 1, dropping the loud-`unknown` arm reddens 1,
    hardcoding `dev` reddens 1. A test asserting only "some number is
    emitted" would have passed the original bug.


- **The `gh` wrapper now selects a client by CAPABILITY, not by identity
  (`#755`).** `monitor/ghwrap/gh` resolved the real client as *"the first
  `gh` on `PATH` that is not THIS wrapper"* — an identity criterion asked
  to carry a capability guarantee it never made. Two clients are installed
  on the operator's host, `/app/bin/gh` **1.13.0 (2021-07-20)** from the
  agent-sandbox base image and `~/.linuxbrew/bin/gh` **2.89.0**, and which
  one won was decided by PATH ordering. Resolution now prefers the first
  candidate meeting a declared floor (`NEXUS_GH_MIN_VERSION`, default
  `2.86.0`), implemented in the new `monitor/gh-capable.sh`.
  - **Measured divergence, same job, same bot token, 2026-08-07.** Three
    surfaces degrade SILENTLY at 1.13.0 — rc 0, nothing on stderr:
    `run view --job <id> --log` returns **zero lines** (2.89.0: 622);
    `run view <run> --log` returns **two of the run's ten jobs** in a
    plausible-looking 1456-line output (2.89.0: all ten, 5448 lines); and
    `pr checks` prints **`pass` for a check whose REST conclusion is
    `skipped`**. The middle one is worse than empty because it looks
    complete. The third is a verdict misreport on exactly the distinction
    `#628`/`#740` exist to preserve — `skipped` and `cancelled` are not
    `success` — laundered before any enumeration sees it.
  - **`gh api` is unaffected**, byte-identical across both clients on every
    REST and GraphQL probe. That matters for scope: `gh api` is the
    repo's dominant call shape (117 of ~1,050 call sites, and the only one
    on any CI-reading path), so **no executable code path in this repo was
    exposed**. The exposure is ad-hoc agent invocation — which is how the
    defect was found, triaging `#744` — and that is precisely why the
    remedy lives in resolution rather than in patched call sites.
  - **The floor is a declared PROXY, and the file says so.** `#755` is an
    issue about identity standing in for capability, and a version number
    is also an identity claim; the honest defence is that it is *licensed
    by the measured table above* rather than by a changelog, and that the
    alternative which looks more like capability is blind to the headline
    case — both clients advertise `run view --log` in `--help`, so
    help-text probing cannot see the advertised-but-broken class at all.
  - **Coverage boundary, on the axis the mechanism varies on.** FIVE clients
    are installed on this host and all five were measured against one 10-job
    run, counting the jobs `run view --log` returns: `1.3.1` **0/10**,
    `1.13.0` **2/10**, `2.14.7` **2/10**, `2.86.0` **10/10**, `2.89.0`
    **10/10**. The first draft set the floor at `2.0.0` on two data points and
    was **wrong**: the truncation is not a 1.x defect, and `2.0.0` would have
    vouched for `2.14.7` — issuing the very false capability guarantee this
    change exists to stop. The floor is therefore `2.86.0`, the oldest version
    measured correct. Measured bad `<= 2.14.7`; measured good `>= 2.86.0`;
    `2.15`–`2.85` **unmeasured** and excluded, because being too strict costs a
    warning while being too lax silently vouches for a truncating client.
  - **Two of those five report `gh version DEV`** — no parseable number — and
    they sit at opposite ends of the capability range (`1.3.1` returns nothing,
    `2.14.7` truncates). That is the version proxy failing in the wild, and it
    is why an unreadable client is taken **in place** and reported
    `unverified` rather than stepped over: skipping would change which binary
    runs on the strength of a silence.
  - **Availability is preserved deliberately.** The wrapper never refuses
    over version: it is on the path of every agent and the watcher, on a
    nexus that cannot be restarted, so a below-floor host degrades to the
    old behaviour plus a throttled stderr warning and a durable breadcrumb
    at `monitor/.state/gh-below-floor`. The stderr nag is rate-limited
    (`NEXUS_GH_STALE_NAG_SECS`, default 300) because a per-call banner
    would be captured as data by the corpus's many `gh … 2>&1` sites — the
    warning must not become an instance of the class it warns about.
  - **`assert-shims-wrapped.sh` gains a version-floor leg** that measures
    the EFFECTIVE client end-to-end (a bare `gh --version` in a spawned
    probe shell, through the real wrapper) rather than scanning PATH for a
    capable binary — the proxy would have passed on the host where `#755`
    was observed, since 2.89.0 was installed the whole time. It **warns by
    default** and refuses only under `NEXUS_REQUIRE_GH_FLOOR=1`, because a
    refusal here also reaches `_respawn.sh`'s 78 and would stop the board
    self-healing (the blast radius PR `#670` documents). An unreadable
    version is a WARNING, not `79`: the guard *did* examine its subject,
    which is the boundary that file already draws for the nproc leg.
  - New suite `monitor/watcher/test-gh-capable.sh` — 45 assertions, count
    asserted, six seeded mutants (including a revert to identity
    resolution) each shown to redden it. It fakes the version axis with
    stubs, so it verifies resolution and gating logic only; the
    behavioural claims above are host measurements and are **not**
    reproducible on a runner, which has one `gh` and no `/app/bin`.

- **`test-jupyter-service.sh`: a timed-out precondition no longer reports
  as a product regression, and the blocking band's deadline scaling is no
  longer inert (`#749`).** The `d4df844f` failure printed four lines, of
  which only two were the timeout:

      FAIL: server back on a new port (deadline 20s)
      FAIL: env port moved past the squatter — got 0 want 1
      FAIL: healthy again after rotation (deadline 20s)
      FAIL: rotation forced exactly one restart — got 2 want 3

  `wait_for` returns 1 on timeout and the script carries on, so the
  *dependent* assertions sampled stale state and failed on their **values**.
  "rotation forced exactly one restart — got 2 want 3" reads as broken
  rotation logic; the rotation had simply not happened yet.
  - A `blocked_by` helper now skips dependents whose precondition timed out
    and reports them as `NOT EVALUATED (precondition timed out: …)`. The
    assertion **count is preserved** — one outcome per dependent, exactly as
    if it had run — so the suite cannot be quieted by breaking it earlier.
  - `th_deadline()`'s scale is CPU **oversubscription**, `ceil(jobs/nproc)`.
    The SLOW band passes no `--jobs` and exports no `NEXUS_TEST_JOBS`, so
    `jobs=1`; on a 2-vCPU runner that is `ceil(1/2) = 1`. The `#558`
    machinery was **structurally inert** in precisely the band `#737` made
    blocking — a lever that looks engaged and is not, since the deadlines
    carry a comment saying they are scaled. Oversubscription was also the
    wrong axis: `d4df844f` failed at `loadavg 0.16`, an idle host.
    `tests-slow-integration.yml` now sets `NEXUS_TEST_DEADLINE_SCALE=2`.
  - **Why 2.** Polled deadlines cost zero wall-clock on a green run, so the
    only ceiling is the per-test `--timeout 600`: this file's deadlines
    total ~219 s unloaded, so scale 2 worst-cases at ~438 s (inside 600, a
    timing failure still reports as labelled per-assertion FAILs) while
    scale 3 worst-cases at ~657 s, tripping the timeout and collapsing that
    detail into a bare `TIMEOUT`. 2 is the largest scale that keeps a
    failure legible.
  - `run-tests.sh` now prints the **effective** `deadline-scale=` in its run
    header. A band that forgets the lever previously looked identical in its
    log to one that set it deliberately: `jobs=1` was printed, `nproc` was
    not, and the reader was left to do the division.

- **`ci-signal`: "no checks ran" is now a RED check with a name, not a
  silence (`#604`).** `on: pull_request: branches: [main, dev]` filters the
  PR's **base**, so a PR stacked on a feature branch matched no workflow,
  collected zero checks, and rendered identically to all-green — `gh pr
  view` reporting `MERGEABLE` with an empty `statusCheckRollup`, no red on
  the merge button, nothing to click past. `#593` sat in exactly that state
  and was caught only because a human noticed its check count looked unlike
  its neighbours'.
  - `.github/workflows/ci-signal.yml` runs on **every** PR into **every**
    base with no `branches:` and no `paths:` filter, so the check set is
    never empty.
  - `monitor/ci-trigger-audit.py` recomputes, from the workflow sources,
    which workflows *should* have gated this (base, changed-files) pair and
    compares that against the runs GitHub recorded — the property, not the
    proxy "at least one check exists" (which this very workflow would
    satisfy by construction). Two verdicts with different remedies:
    `TRIGGER-GAP` (paths match, `branches:` excludes this base — the `#593`
    shape) and `MISSING-RUN` (expected on every axis, no run). Unparsed
    input is REFUSED, never defaulted.
  - The audit checks **itself**: a `branches:`/`paths:` filter appearing on
    `ci-signal.yml` is reported as `SELF-BROKEN`, so the trigger-gap
    detector cannot be trigger-gapped out of existence.
  - **Retargeting a PR now re-runs CI.** Changing a base emits only the
    `edited` event, never `synchronize`, so the documented remedy for the
    trigger gap silently failed to trigger. `tests.yml`, `cc-harness.yml`
    and `docs.yml` now list `edited` and gate their jobs on the base having
    actually changed, so title/body edits cost no runner minutes.
  - `monitor/test-ci-trigger-audit.sh` replays the `#593` PR shape against
    the real workflow files and asserts it can never audit clean.

- **The suite can now run under CI's bash, and says so when it does not
  (`#610`).** No host in this workspace ships bash 5.x; CI runs only 5.2.
  That asymmetry already hid two defects — the `#597` fork-floor probe that
  collapsed to its lower bound (CI capped forks at 87 against a real floor
  of 566, every test then dying of `EAGAIN`; unreproducible on 4.4 *even in
  principle*) and `patsub_replacement` corrupting generated `gh` stubs.
  - `monitor/toolchain-bash.sh` builds and caches a sha256-pinned GNU bash
    (5.2 and 4.4.18 pinned) under `monitor/.state/toolchain/`. Measured, not
    assumed: ~2 minutes on this host.
  - `run-tests.sh` gains `NEXUS_TEST_SHELL` (the interpreter each test is
    actually launched with — refused, never silently substituted, if it is
    missing or not bash) and ends **every** run, green included, with an
    interpreter line: `interpreter parity: bash 5.2` when it matches CI's
    pin, or a `COVERAGE BOUNDARY` block naming what was not tested and how
    to close it. `--require-ci-parity` turns the declaration into a refusal.
  - `monitor/ci-bash-version` holds the pin, and `tests.yml` asserts the
    runner's actual bash matches it — so the boundary local runs declare
    cannot quietly become a lie when GitHub bumps its image.
  - A `bash-legacy` CI job runs the unit suite under 4.4 — the mirror
    direction, and the version this lab's hosts (including the one running
    the live watcher) actually execute.

### Fixed

- **`pane-state.sh`: an idle `tui: fullscreen` pane's `content_hash`
  churned on tmux 3.x, so stale engagement marks never expired
  (`<your-org>/nexus-code#573`).** Under fullscreen (alternate-screen)
  rendering the input box is pinned to the bottom and the padded gap above
  it periodically flashes a RIGHT-ALIGNED contextual nudge (`● <tip> ·
  /<cmd>`). It lands ABOVE the `❯<NBSP>` input row — inside the hashed
  transcript region — and is non-numeric, so the existing digit-strip never
  neutralised it; every blink moved the hash, refreshing the watcher's
  change-corroborated `operator-engaged` mark forever and pinning the window
  open. `_content_hash` now drops these nudges before hashing, keyed on
  RIGHT-JUSTIFICATION (a `●` pushed to the right edge by a large leading-space
  run, ≥32) — a `●` at column 0 OR any small indent (a code-fence line, a
  pasted TUI capture, a nested-list bullet) is real content and still moves the
  hash. Real transcript content is never right-justified, and measured indents
  are ~2–4 columns (deep nesting rarely >16), so nothing real reaches the
  threshold; the residual error is biased to the RECOVERABLE side (an
  implausibly narrow, <~48-column pane could leave a nudge under the threshold,
  merely holding a window open a cycle longer — never a kill). An absolute
  space count is used, not a width-relative midpoint, so the test is ASCII-only
  and locale-safe. Measured against the real binary via `monitor/cc-harness` on
  tmux 3.4: over 60 s of a genuinely-idle fullscreen pane the nudge was the
  ONLY moving region byte. The `cc-harness` `fullscreen` matrix cell
  (previously advisory, red on `dev`) now passes. No-op in the inline
  renderer, where the same nudges render below the input row.

- **`printf … | grep -q` assertions inverted their own verdict under
  `pipefail`.** `grep -q` exits the instant it matches without draining its
  input; the writer then takes EPIPE, and under `set -o pipefail` that
  becomes the pipeline's status — so the assertion reported FAILURE at the
  exact moment the thing it tested turned out to be TRUE. Confirmed from the
  `#598` merge run on `dev`: `test-interactive-sessions.sh` line 198 emitted
  `printf: write error: Broken pipe` and failed T8b while its own dump
  showed the awk upsert under test had produced exactly the right body — on
  a ~90-byte payload, passing on the serial re-run. All 36 instances across
  18 files are converted to `grep -q PATTERN <<<"$var"`, including seven in
  `monitor/spawn-worker.sh` and instances in `monitor/lit.sh`,
  `monitor/cc-auto-update-apply.sh` and the PreToolUse hooks, where a
  spuriously non-zero `if` takes the wrong branch in production.
  `monitor/watcher/test-sigpipe-assertion-lint.sh` blocks reintroduction and
  demonstrates the mechanism executably.

- **Worker wrap-up can deliver to the request/reply channel instead of a
  forced GitHub issue (`--reply-to`).** A worker spawned to answer a
  confined request-channel request — canonically a remote SSH client that
  filed a `kind=question` and wants DATA back, explicitly *"no repo
  modification needed"* — had exactly one sanctioned hand-off:
  `ng wrap-up <issue> <report>`, which requires an issue number and posts
  to GitHub. The reply half of the round-trip already existed
  (`ng request reply`, RFC Parts B+D); the gap was the worker wrap-up
  integration. Both halves are now wired, with the delivery surface chosen
  by the ORCHESTRATOR at dispatch — never parsed from a remote client's
  (untrusted) prose.
  - `monitor/spawn-worker.sh --reply-to <request-id> [--issue <n>]`. The
    id is resolved against the inbox **at spawn time** (exit 16 on unknown
    or already-terminal), so a typo fails at dispatch rather than an hour
    later when the worker discovers its answer has nowhere to go. `--issue`
    without `--reply-to` is refused (exit 17) rather than silently ignored.
  - A new `## Reply-to wrap-up override` section in
    `skills/nexus.worker-defaults/SKILL.md`, extracted the same awk way as
    the floor and injected *after* it with `<REQUEST_ID>` substituted. Read
    **only** in `--reply-to` mode: with no flag the composed prompt is
    byte-identical to the pre-flag behaviour — the load-bearing invariant,
    since `spawn-worker.sh` composes the prompt for every nexus worker.
  - `monitor/ng wrap-up --reply-to <id> <report> [--issue <n>]
    [--answer-file <path>]` extends the existing verb rather than forking a
    parallel path, so `report-check`, the skeptic gate, the action log and
    the window retain stay unified. Steps 1–3 (upload / issue comment /
    trigger rocket) are skipped unless `--issue` is given; a new step 2c
    delivers the answer via `request-channel.sh reply` (the channel is not
    reimplemented). The answer is `--answer-file` when given, else the
    report's **full** `## Summary` section, plus a footer naming the report
    and any GitHub artifacts. A failed delivery — or an empty answer body —
    FAILS the wrap-up: the requester is blocked on it, so a silent success
    would be the worst outcome.
  - Visibility without an issue: the request + reply files under
    `monitor/.state/requests/` (plus the byte-exact
    `replies/<id>/results.md`), the watcher's request emit, the unchanged
    `reports/` write-up, and a `wrap-up` action-log event carrying
    `reply-to=<id> channel=ok`. The window provenance record gains a
    `reply_to` field so the orchestrator can see which windows owe a
    channel answer.
  - Tests: `monitor/watcher/test-spawn-worker-reply-to.sh` (36 assertions,
    including a byte-identity check of the no-flag prompt against an
    independent reference composition) and
    `monitor/watcher/test-ng-wrap-up-reply-to.sh` (66 assertions, including
    zero-length `gh` and `upload-asset` captures as the "no GitHub
    artifact" evidence).

- **Read-only-filesystem guard: the watcher degrades instead of dying
  (issue 473).** Twice — 2026-06-29 and 2026-07-09 — the project tree
  went read-only inside the sandbox mount namespace and the watcher
  disappeared without a word. Both incidents run the identical script:
  `version_check` sees drifted sources → `launcher.sh --replace` →
  SIGTERM the incumbent → the successor dies in `>>"$LOGFILE"`, a fresh
  `open()`, *before `main.sh` executes one line* → "did not publish a
  live pidfile" → silence. The incumbent it replaced was fine: it held
  its log fd from before the remount and had been logging normally
  throughout. That asymmetry — an open fd survives its mount being
  detached, a fresh `open()` does not — is why the outage was invisible
  from the inside, and it is the constraint every part of this change
  is built around.
  - `monitor/_fs_probe.sh` — ONE canonical probe (`nexus_dir_writable`,
    `nexus_path_writable`), sourceable and a CLI. It performs a
    create+unlink of a **new** path on **every** call. Never a cached
    fd, never a `stat`: a probe that appends to a held fd reports
    *healthy* during a total outage, which is strictly worse than no
    probe at all.
  - `monitor/watcher/_fs_guard.sh` — a per-cycle probe in the watcher
    loop. On failure the watcher enters **read-only degraded mode**: it
    suspends every project-tree write, keeps its loop alive (a live
    watcher is what notices recovery), and escalates **exactly once**
    per incident over channels that need no filesystem write
    (`sandbox-notify` → a GitHub incident issue via `mint-token.sh`,
    whose cache lives on a different mount → a tmux paste). The
    fire-once latch is in memory, deliberately: there is nowhere to
    write a rate-limit cursor, and the process dies with the incident.
  - **`launcher.sh` no longer decapitates.** `--replace` probes first
    and refuses on a read-only FS, leaving the working incumbent alive;
    `_version_restart_self` suppresses the self-restart for the same
    reason. If a watcher must nonetheless cold-start on a read-only FS,
    the launcher redirects its output to `$TMPDIR` so it *starts*,
    discovers the condition, and reports it — rather than dying in its
    own log redirect.
  - **Durable trace on recovery.** The 2026-06-29 incident left no
    record and was re-diagnosed from scratch ten days later. On the
    recovery edge the watcher appends the incident (duration, onset
    bounds, escalation channels used) to `.state/fs-incidents.jsonl`
    and comments the resolution on the open incident issue.
  - **`svc.sh status` leads with the truth**: a first-class
    `fs <OK|READ-ONLY>` row *above* the per-service rows, and a
    non-zero exit when read-only. It previously printed `UP` services,
    and exited `0`, while nothing in the workspace could save a file.
  - **The `PreToolUse` pending-tool hook fails OPEN**
    (`monitor/hooks/pending-tool-record.sh`). It was an inline redirect
    into the project tree whose non-zero exit blocked the tool call, so
    a storage hiccup became a total `Bash`/`Write`/`Edit` outage for
    every hook-gated worker. It is bookkeeping, not a security
    boundary: it warns and gets out of the way.
  - The operator-facing escalation message now leads with the remedy,
    quotes the discriminating evidence (mount `ro` over an `rw`
    superblock; the project's read-write bind absent from the
    namespace), states that no data is lost and that the filer is
    healthy so storage-support need not be paged, says what a restart costs,
    and never suggests remounting or `unshare`-ing around a
    kernel-enforced sandbox. It no longer asserts an NFS-flap root
    cause, which was never established.
  - `monitor/watcher/test-fs-guard.sh` — T1–T10, both directions.

- **Worker respawn on recovery (`bootstrap-recover.sh` step 3 +
  `--no-workers`).** Boot recovery now also respawns the worker
  agents that were active in the last watcher snapshot
  (`.state/last-snapshot.txt`, `--- tmux ---` section), via the
  canonical resume surface `spawn-worker.sh --resume <window>`
  (issue 197) — never a hand-rolled `claude --resume`. A snapshot
  window qualifies iff it is not infra (`orchestrator`, `services`,
  `watcher`, registry-named legacy service windows excluded), it has
  a `spawn` event in `.state/action-log.jsonl` (recovery only owns
  nexus-spawned workers), and that `spawn` is its latest lifecycle
  event — a later `wrap-up` / `window-close` means the worker already
  handed off, and the orchestrator's dispatch loop owns continuations
  of wrapped work. Idle-but-unwrapped workers ARE respawned.
  Idempotent (already-alive windows never double-spawned), bounded
  (`recover.max_workers` config, default 12, excess skipped with a
  loud notice), loud-on-skip (unresolvable sessions are logged, never
  fatal). Flag matrix: default = watcher + services + workers;
  `--no-services`/`--watcher-only` (core-only) also skips workers;
  the new `--no-workers` skips only the worker respawn;
  `--services-only` skips just the watcher. `boot-recover.sh`'s
  health gate now also fires on the `would resume` dry-run marker.
  Tests: `watcher/test-bootstrap-recover.sh` (worker identification +
  inclusion criteria, idempotency, flag matrix, unresolvable-session
  skip, cap), `watcher/test-boot-recover.sh` (worker-only-need gate).
  (issue 198)

- **Core-only startup flag (`--no-services`).**
  `monitor/bootstrap-recover.sh --no-services` (synonym:
  `--watcher-only`; also reachable as `monitor/svc.sh up
  --no-services`) brings up the nexus core alone — the watcher, which
  then revives the orchestrator via its own liveness machinery — and
  skips every service registered in `services.registry`. Idempotent
  like the rest of recovery; combining it with `--services-only` is
  rejected with a clear error (exit 1) since together they would
  recover nothing. `svc.sh up` now propagates a nonzero
  `bootstrap-recover.sh` exit instead of swallowing it. Tests:
  `watcher/test-bootstrap-recover.sh` (core-up with zero services,
  healthy-stack no-op, bad-combo rejection),
  `watcher/test-svc.sh` (`up --no-services` pass-through + failure
  propagation). (issue 195)

- **JupyterLab as a service (`monitor/jupyter-up.sh` +
  `skills/nexus.jupyter`).** One idempotent command turns a project's
  [labsh](https://github.com/katosh/labsh) JupyterLab into a
  registry-managed service: ensures a project kernel (`labsh kernel
  add`, or `--venv DIR` → `labsh kernel register` for existing/Lmod
  venvs), maintains a `jupyter-<project>` row in `services.registry`,
  and launches `monitor/labsh-supervised.sh` (a watchdog that bounces
  unhealthy servers, follows labsh's port auto-increment via
  `.jupyter/labsh-service.env`, adopts hand-started servers, and runs
  `labsh stop` on TERM) through `recover_service` — so
  `bootstrap-recover.sh` revives it on boot and `svc.sh` manages it.
  `monitor/jupyter-health.sh` is the shared authenticated healthcheck
  (`/api/status` with the project token; token rotation self-heals via
  a supervised bounce). `--down` deactivates (stop + deregister),
  `--status` reports. The `nexus.jupyter` skill encodes the foolproof
  default: a bare "jupyter session" request → `jupyter-up.sh <dir>`,
  then `labsh kernel exec/inspect` per `<yourlab>.labsh`. Tests:
  `watcher/test-jupyter-service.sh` (hermetic stub labsh) and
  `watcher/test-integration/test-jupyter-service-real.sh`
  (`RUN_INTEGRATION=1`, real servers/venvs/kernels in throwaway `/tmp`
  projects). (issue 184)

### Changed

- **The shim precondition gained a THIRD outcome: `exit 79`, "NOT
  CHECKED" (<your-org>/nexus-code#612).** `monitor/assert-shims-wrapped.sh`
  used to return `0` in three states where it had examined nothing at all —
  `NEXUS_ROOT` unset, no `monitor/*wrap` shim dirs anywhere, and no probe
  shell — so "the check did not run" and "the check ran and was clean"
  were the same observable value. That is the defect class the guard exists
  to close, reproduced inside the guard. Those three now exit `79`, which
  every launcher's emitted guard block (`monitor/guard-block.sh.in`)
  records as a durable `NOT CHECKED` row in
  `monitor/.state/guard-unverified.log` and then ALLOWS — the caller
  decides, and `NEXUS_REQUIRE_SHIM_CHECK=1` escalates it to a refusal (78).
  A CONFIRMED failure still outranks it: a run where one leg was
  unexaminable and another FAILED exits `1`.
  - The contract lives in `assert-shims-wrapped.sh`, **not** in the
    deprecated `assert-gh-wrapped.sh` forwarder. The block searches the
    generalised name first, so a third outcome implemented in the forwarder
    would have been unreachable dead code with every suite still green.
  - Explicit caller opt-outs (`NEXUS_ASSERT_SKIP_SHIMS`,
    `NEXUS_ASSERT_SKIP_NPROC`) deliberately do **not** produce `79` — a
    caller that disabled a leg already knows. That bound is asserted, along
    with the fact that no launcher sets either flag.
  - Two suites now pin this, on deliberately **disjoint** contracts:
    `test-assert-shims-wrapped.sh` pins the exit code across every route
    into each condition (including the no-override route a real launcher
    takes), and `test-spawn-guard-fail-closed.sh` pins the consequence —
    the durable row, the escalation, and forwarder equivalence. The split
    is the point: an implementation was demonstrated that satisfied both
    of the pre-existing suites at once by branching on which override
    variable the fixture had set, because both were reading the same
    observable.

- **`ng lit search`'s zero-result relaxation probe is now
  order-invariant: leave-one-out over the query's canonical content-term
  set, replacing the positional six-word prefix.** The prefix made a
  logically commutative conjunction land on different branches depending
  on where its terms happened to sit: the same eight terms, same corpus,
  same ground truth (a real zero) gave `status: error,
  query_over_constrained, exit 2` in one wording and a clean `status: ok,
  count: 0, exit 0` in another. The probe now builds its relaxations from
  `_probe_terms` — tokens lowercased, punctuation-trimmed, stopwords
  dropped, deduplicated, `LC_ALL=C` sorted — so every probe query, the
  order the drops are tried in, and therefore the verdict, are functions
  of the term SET. Permuting a query changes nothing but the echoed
  `query` field; so does re-casing it, punctuating it, or padding it with
  stopwords.
  - **Leave-one-out says more than a prefix could.** A drop is the
    closest query to the one asked that still hits, so a hit NAMES the
    binding term and the remedy is that near-query — where the prefix
    steered the caller at a broader question than the one they asked
    (`#600` item 4). When nothing hits, the claim is narrower and honest:
    no single term among those tried explains the zero.
  - **Cost, stated rather than hidden.** Up to `LIT_PROBE_MAX_DROPS` (6,
    env-tunable) requests on the zero-result path, early-exiting at the
    first hit; the old probe cost one. The cap is a real coverage limit —
    a drop sorting past it is never tried — so `probe.drops_tried` /
    `probe.content_terms` report the coverage actually achieved, and a
    missed hit degrades to the hedged zero rather than a confident one.
  - **The burst is paced** (`LIT_PROBE_DELAY_SECS`, 1s, never before the
    first drop). Fired back-to-back against the real S2 the drops earn
    `Too Many Requests` where the old single-request probe did not,
    degrading a would-be clean zero to `partial` / probe `inconclusive`.
    Found by running the changed binary against the live backend, not by
    inspection.
  - **The probe establishes a DROP-ZERO BASELINE before naming any term.**
    The reduction differs from the caller's query by more than the dropped
    term — stopwords are gone too — so when a stopword was the binding
    constraint the reduction ALONE already hits, the first drop hits
    trivially, and an arbitrary content term gets blamed. Measured:
    `… medulloblastoma without` was blamed on `cell`, while dropping
    `cell` and keeping `without` still returned 0. Disclosure could not
    cure this one, because the scoped claim ("X is the term whose removal
    recovered hits") is false when nothing needed removing. The probe now
    searches the unperturbed reduction first; if that hits, the verdict is
    `probe.reason: "reduction_recovered"` with `dropped_term: null` and
    the message says *no single content term accounts for this result* —
    which is the verdict a leave-one-out probe can actually support.
  - **A quoted phrase is not probed at all.** The probe rebuilds its query
    from content terms, which strips the quotes, and an un-quoted phrase is
    a strictly broader search — so on a phrase query *any* drop hits and
    the tool named whichever term it tried first. Reproduced against a
    phrase-aware stub: it blamed `aged`, and removing `aged` recovered
    nothing. A query containing a double quote now reports
    `probe.state: "inconclusive"`, `probe.reason: "quoted_phrase"` and
    claims nothing. The `_relax_probe` header claim ("varies only the one
    dropped term, so a hit is attributable to that term and nothing else")
    was false as written for the same reason and is now accurate.
  - **`_probe_terms` no longer depends on the ambient locale.** Trimming
    with `[^[:alnum:]]` meant that under `LC_ALL=C` awk treated every byte
    of a multi-byte character as non-alphanumeric: `γδ` vanished entirely
    and `α-synuclein` became `synuclein`, so the term set — and with it
    the `LIT_PROBE_MIN_TERMS` gate — changed with the environment. Trimming
    is now against an explicit ASCII list, with standalone Unicode
    punctuation dropped by whole-token match (a byte-wise trim would alias:
    the trailing byte of Cyrillic `М` is the trailing byte of `“`).
  - **New `probe` object on every search response** (`state` `not_run` |
    `hits` | `empty` | `inconclusive`, plus `reason`, `backend`,
    `content_terms`, `drops_tried`, `max_drops`, `dropped_term`, `query`).
    `reason` (`results_returned` / `too_few_content_terms` /
    `quoted_phrase` / `no_backend_available` / `backend_error`) keeps the
    non-verdict states from repeating the ambiguity below. This also
    resolves `#600` item 3: `partial` had two causes and the backend
    lists witnessed only one, so an unrunnable probe set `partial` with
    `failed_backends` **and** `skipped_backends` empty — a caller written
    to the documented contract found nothing wrong and concluded nothing
    was. `probe.state: "inconclusive"` is that case.
  - The probe threshold is now counted in **content terms** rather than
    whitespace words (`LIT_PROBE_MIN_TERMS`, still 7): a stopword is not
    what makes a conjunction too narrow, so it must not decide whether a
    zero gets corroborated. `#600` item 2 (a genuinely short query is
    still never probed) and item 5 (latency on the ASTA slow path, which
    this change makes worse in the worst case) remain open.
  - `monitor/watcher/test-lit-probe-order-dependence.sh` now pins the
    invariance it previously documented as an open defect (67 → 269
    assertions, with an assertion-COUNT floor so a helper that vanishes
    into rc 127 cannot pass silently), and six negative controls — every
    one consuming the live binary rather than a fixture's copy of a format
    string. Three are new: the equality predicate
    fed a differing term set must fail, and a copy of `lit.sh` with the
    canonicalising sort removed must diverge end to end on a permuted
    pair — without the latter, "the two orderings agree" is also what a
    probe that never fires would look like. No claim assertion changed:
    "no ordering certifies a zero" was written to be independent of which
    branch a query lands on. (issue `#600`, from the PR `#596` skeptic
    review, finding F1)
- **Work-root JupyterLab service renamed `jupyter-workroot` →
  `jupyterlab`; cockpit shows the tokened URL; `logs` includes the
  server's output.** The single root service registered by
  `jupyter-up.sh --root` (and advertised by the `svc.sh` cockpit when
  dormant) is now plainly `jupyterlab`; `--root` activation migrates a
  leftover legacy `jupyter-workroot` row in place (stops/cleans its
  supervisor, re-registers under the new name — a stale row is never
  fatal). The cockpit's `DETAIL` column, now the final untruncated
  column (the seldom-useful `WINDOW` column is gone), renders an UP
  labsh service's reachable, directly-openable URL —
  `http://<fqdn>:<port>/lab?token=…`, FQDN-rewritten on external binds
  (issue 252's rule), degrading to the bare URL when no token is
  resolvable and never erroring the cockpit. `svc.sh logs <name>` and
  the cockpit log split tail the jupyter server's own stdout
  (`.jupyter/labsh.bg.log`, which prints the access URL on startup)
  alongside the supervisor log. (issue 191)

- **`./watcher` retargeted to the unified headless start; upgrade is
  self-delivering.** The user entry point (`monitor/watcher/entry.sh`;
  new alias symlink `./nexus`) no longer hosts the watcher in a
  window or spawns the orchestrator itself: it self-checks (tmux +
  agent-sandbox), brings the stack up via `monitor/svc.sh up`
  (headless watcher + registry services; the watcher then spawns the
  orchestrator), and leaves the invoking window running the `svc.sh`
  cockpit (window name `services`). `--continue` is reconciled onto
  the orchestrator session-id pin
  (`monitor/.state/orchestrator-session-id`): the default boot
  archives the pin (timestamped, never deleted) so the cold start is
  fresh; `--continue` keeps it so the watcher resumes that exact
  session via `claude --resume <sid>` — without a valid pin the
  watcher spawns fresh, never `claude --continue` (issue 200).
  Additionally, a watcher that starts under **legacy window hosting**
  (`WATCHER_WINDOW != headless`, the launcher's marker) now surfaces
  a one-shot `--- watcher hosting migration ---` notice in its
  startup-sweep emit — converge steps: pull BEFORE restart, then
  `monitor/svc.sh restart watcher` — and keeps operating normally
  (new module `monitor/watcher/_hosting_migration.sh`). New page
  [`docs/operating/upgrading.md`](docs/operating/upgrading.md)
  documents the mechanism and the manual checklist; the windowed-era
  descriptions across `README.md`, `docs/`, and `monitor/README.md`
  were swept to the headless model. (<your-org>/<your-nexus> issue 182)

- **Watcher folded into the services model — headless, no tmux
  window.** `watcher/launcher.sh` now launches `main.sh`
  `setsid`-detached with stdout/stderr appended to
  `monitor/.state/watcher.log`, verifies the self-published pidfile
  before reporting success (exit 3 on a spawn that didn't stick), and
  sweeps a leftover legacy `watcher` window on the next spawn.
  `_watcher_alive` / `_watcher_reason` drop the tmux-window-presence
  check (pid identity + heartbeat age are the whole story; the
  window parameter is retained-and-ignored for arity compatibility).
  `ng watcher-status` reports `hosting: headless` and flags a legacy
  window. The canonical bounce is `monitor/svc.sh restart watcher`
  (== `launcher.sh --replace`); `--window`/`--force` are accepted
  but ignored. The cockpit tails the watcher log via key `0` /
  `svc.sh logs watcher`.

- **`svc.sh` grew into the stable stack surface.** Flicker-free
  in-place repaint; log picks no longer steal focus (the
  `select-pane -T` titling side effect); single-key controls;
  pinned core rows (watcher tri-state liveness, orchestrator window
  + turn-end heartbeat). New explicit verbs: `status` / `up`
  (idempotent whole-stack bring-up via `bootstrap-recover.sh`; the
  watcher then spawns/revives the orchestrator) / `start` / `stop`
  (process-group TERM, KILL escalation, loud warning if the
  healthcheck survives) / `restart` / `logs`. Sandbox-agnostic by
  design — prefix `agent-sandbox` explicitly when wanted.

- **Respawn hardening after the 2026-06-02 false-positive-respawn +
  watcher-death incident.** Two root causes, both fixed:

  - **Target-absent respawn now requires confirmed absence.**
    `monitor.agent_missing_respawn_delay` default raised 0 → 3 (four
    consecutive absent observations at the 2 s probe cadence, ~8 s),
    and a new pre-launch re-verification
    (`_respawn_verify_target_absent` in `monitor/watcher/_respawn.sh`)
    runs at the moment of decision: a fresh window probe, a pane scan
    for a live orchestrator process (identified via the
    `NEXUS_IS_ORCHESTRATOR=1` environment marker, with tmux
    rename-race healing), and a liveness-signal comparison against
    the absent-streak start each independently abort the respawn.
    Aborts are logged and action-logged
    (`respawn-aborted-reverify`).

  - **A false-positive respawn can no longer take the watcher down.**
    The recovery prompt pasted into a respawned orchestrator used to
    instruct it to *kill the watcher* when it discovered the respawn
    was wrong — which is exactly what happened on 2026-06-02, leaving
    the workspace unmonitored. The prompt now mandates a stand-down
    protocol scoped to the duplicate itself: restore the original
    agent's window name, record the false positive, and remove ONLY
    the duplicate's own window (by window id). It explicitly forbids
    killing the watcher, the tmux session, or any other window. The
    watcher additionally traps SIGHUP to log its own demise
    (attributable post-mortem instead of a clean log tail) and to
    release its pidfile/lock on `tmux kill-window -t watcher`.

- **Watcher / orchestrator rethink** (issue #72; closes the seven
  detection regressions catalogued there). Five coordinated
  changes shipped together so we don't re-introduce the
  brittle-layering problem the meta-issue diagnosed:

  - **Classifier hardening.** `pane-state.sh` now distinguishes
    `empty` (renderer transient — claude alive in the pane's
    process tree) from `absent` (no live claude). Probe-side,
    `_idle_probe.sh` maps only `absent` and `blocked` to the
    inviolable `pane-absent` class; `empty` becomes a
    skip-and-retry-next-cycle signal. Closes regressions 1 + 2.

  - **Lifecycle anchors.** `monitor/spawn-worker.sh` writes an
    authoritative `spawn` action-log event AND seeds the
    engagement-log with epoch=now at window creation. The idle
    probe's wrap-up matcher scopes candidates to entries newer
    than the current-lifecycle spawn ts, so a stale wrap-up from
    a prior life of a recycled window-name (or from before
    `claude --continue`) drops out automatically. New knob
    `monitor.idle_pool_spawn_grace_seconds` (default 120s) guards
    the gap between `tmux new-window` and `claude` actually
    starting. Closes regression 3.

  - **Retain persistence.** `spawn-worker.sh` and
    `respawn_agent` set `tmux remain-on-exit on` at window
    creation. The pane survives a claude exit so the operator
    can revisit a retained worker's transcript and pane-state.sh
    can classify the post-exit pane as `state=absent` instead of
    the window vanishing silently. Closes regression 5.

  - **Emit completeness.** Every emit now starts with a one-line
    workspace prelude (`N busy | N idle | N retained | N
    idle-too-long | N pane-absent`). New section
    `--- workspace snapshot ---` lists every tracked worker
    window with its current pane-state and idle-age; force-
    included on emits hitting the configured cadence
    (`monitor.full_state_emit_interval_seconds`, default 600s)
    AND on the startup-sweep emit. Pure-cadence emits are tagged
    `poll-full-state` in the archive. Transition emits in
    between stay narrow. Closes regression 6.

  - **Decision helpers.** New verbs `ng spawn-decision <window>`
    (advisory continue-vs-spawn classifier) and
    `ng wrap-up-check <window>` (verifies a worker has completed
    its hand-off obligations before close). Both mirror the
    policy in `skills/nexus.window-cleanup`. Tests under
    `monitor/watcher/test-ng-spawn-decision.sh`.

  New config knobs:
  `monitor.idle_pool_spawn_grace_seconds` (default 120),
  `monitor.full_state_emit_interval_seconds` (default 600).
  Existing knobs unchanged; full back-compat for legacy windows
  with no spawn-event anchor.

  - **Per-spawn Claude Code hook scaffolding.** `spawn-worker.sh`
    now extracts the JSON block following the
    `<!-- worker-hooks-default -->` marker in
    `skills/nexus.worker-defaults/SKILL.md` and (when non-empty)
    writes it to `/tmp/spawn-hooks-<window>.<pid>.json`, passing
    `--settings <path>` to claude. The launcher trap-cleans the
    file on exit. Default block is `{}` so back-compat is the
    empty case — user-global hooks remain unaffected. Operators
    populate the block to apply nexus-wide hooks (heartbeat
    writes, notification surfacing, etc.) on every spawn. Hook
    schema, reliable events, and clobbering caveats documented
    in the SKILL's new `## Worker hooks` section. Tests in
    `test-spawn-worker.sh` cover both the empty-default
    (no `--settings`) and populated paths.

### Added

- **Docs site scaffolding** (`mkdocs.yml`, `docs/`,
  `.github/workflows/docs.yml`, `docs/requirements.txt`).
  mkdocs-material site auto-deployed to GitHub Pages on every
  push to `main`. Full content fan-out across five sections
  (Getting started, Operating, Admin, Reference, Contributing)
  follows in subsequent PRs. (PR #13.)
- **`ng wrap-up` verb** — one-shot end-of-task hand-off: upload
  report, post link comment, rocket trigger comment, log the
  event. Supports `--comment-body-file` for bespoke comment
  prose with `{{REPORT_URL}}` token expansion, `--no-comment`
  to skip the comment step, `--allow-stub` for intentional
  checkpoint wraps. Runs `ng report-check` as a pre-flight and
  refuses stub reports. (PR #4.)
- **`ng report-init` verb** — writes a frontmatter'd skeleton
  at the canonical
  `<reports-dir>/<project>_<YYYY-MM-DD>_<HHMMSS>_<slug>.md`
  path, capturing session-id + tmux window automatically.
- **`ng report-check` verb** — validates a report against the
  schema (frontmatter present, all five canonical sections,
  body ≥ `monitor.report_min_chars`, no placeholder markers).
  Used by `ng wrap-up` as pre-flight and by the watcher's
  idle-probe to classify `wrapped-but-stub`.
- **`ng fetch-asset` verb** — user-PAT bridge for fetching
  `github.com/user-attachments/...` URLs the bot's installation
  token can't reach. Writes bytes locally so the agent reads a
  file path instead of poisoning the session with a 404 on the
  attachments host. (PR #73 upstream.)
- **`ng reply --repo OWNER/REPO`** — cross-repo reply target;
  overrides the cwd-derived origin. (PR #4.)
- **Idle-worker probe** (`monitor/watcher/_idle_probe.sh`) —
  combines tmux's `#{window_activity}` with `pane-state.sh`
  classification to surface really-idle workers, classify them
  as `wrapped` / `no-wrap-up` / `wrapped-but-stub` /
  `idle-too-long`, and emit transitions to the orchestrator.
- **`pane-state.sh`** — distinguishes Claude Code's autosuggest
  ghost from real user input by ANSI escape inspection.
  Replaces eyeballing `tmux capture-pane` output. (PR #94
  upstream.)
- **GraphQL polling gate** — bucket-floor + cadence gate
  before every GraphQL call so a single bad cycle can't burn
  the quota. (PR #70 upstream.)
- **Deliveries surface** — webhook-deliveries log as a primary
  comment source alongside the GraphQL surface; mentions search
  as a tertiary fallback. JWT minting for the deliveries
  endpoint. (PRs #62, #68 upstream.)
- **`nexus.window-cleanup` skill** — orchestrator-exclusive
  policy for closing worker tmux windows: triggers, retention
  overrides, pre-close report check, kill mechanism, cadence.
  (PR #101 upstream.)
- **`nexus.infra-review` skill** — periodic meta-review of
  `## Infrastructure Issues` sections across `reports/` into a
  ranked, deduplicated backlog.
- **Crash-loop guard** for the agent respawn path; bounded
  respawn rate with history file in `monitor/.state/`.
- **CI guard against report leaks**
  (`.github/workflows/check-no-reports-leaked.yml`) — fails any
  PR adding files under `reports/` except `reports/.gitignore`.
  (PR #3.)
- **`@<operator>` as default CODEOWNER reviewer** + `ng pr create`
  auto-`--reviewer` based on `github.user_login`. (PR #37,
  PR #36 upstream.)
- **Cross-fork discovery** — topic tag + issue-association in
  report slugs lets bots discover work across forks. (PR #71
  upstream.)

### Changed

- **Asset-repo cutover** — `monitor/upload-asset.sh` now uploads
  to the dedicated asset+issue repo's `main` branch rather than
  to the (deprecated) wiki. Per-operator state cleanly separates
  from the shared code repo. (PR #1.)
- **Watcher inverted as entry point** — `monitor/watcher/entry.sh`
  is now the user-facing entry; it brings up the `claude`
  orchestrator window from inside the watcher loop rather than
  the other way round. Cleaner startup ordering, fewer
  race conditions on `--continue`. (PR #92/#93 upstream.)
- **Worker safety floor** moved into
  `skills/nexus.worker-defaults/SKILL.md` and injected verbatim
  into every spawn prompt by `monitor/spawn-worker.sh`. Floor
  body slimmed ~30% by folding per-step hand-off into the new
  `ng wrap-up` verb.
- **Spawn prompts** carry an explicit `## Worker environment`
  header with absolute paths so reports in secondary clones
  (worktrees, fresh clones) still land in the primary's
  `reports/` dir. (PR #96 upstream.)
- **Report schema** now requires YAML frontmatter (`project`,
  `date`, `session-id`, `window`, `trigger`, `status`) on top
  of the five canonical sections.
- **GitHub-writes authorization** documented as three tiers
  (internal / user-public / external-public) with explicit
  per-action approval rules; the bot identity rule (`WHO`)
  separated from the per-write approval rule (`WHETHER`).
- **CLAUDE.md** slimmed substantially; orchestrator-only prose
  moved into `monitor/README.md` and `skills/nexus.*`. The
  top-level contract now fits on one screen.
- **Lockfiles** moved into `monitor/.state/lockfiles/` from
  workspace root. Independent-clones pattern adopted as the
  primary parallel-work convention; lockfiles persist as
  fallback. (PR #57 upstream.)
- **Overview-issue routing-only rule** — the pinned `Nexus`
  issue now carries only routing one-liners; content threads
  live on dedicated issues.

### Fixed

- **`ng lit search` no longer answers a failed search with `count: 0`.**
  (`#588`.) A search that did not establish anything returned a clean,
  well-formed empty result set — and to an agent `count: 0` is a
  substantive claim about the world, so it gets believed and written up as
  *"to our knowledge, no prior work addresses X."* An error is visible and
  gets retried; a confident zero gets cited. Measured live (2026-07-29):
  a 41-word on-topic query returned `count: 0`, `partial: false`, no failed
  backends and **exit 0**, while a 6-word prefix of the same query on the
  same backend returned thousands of hits.
  - Every response now leads with **`status`** — `ok` (every requested
    backend searched; a 0 means nothing matched the query as asked),
    `partial` (a backend failed
    or was skipped; a 0 establishes nothing), `error` (the query itself
    failed) — plus a one-sentence `summary` and a `complete` flag. The
    distinction is carried by the DEFAULT rendering, JSON and `--human`
    alike, not by extra fields a caller must think to read.
  - On `status: error` the response carries **no `count` and no `results`**
    (`.count` reads `null`, never `0`) and exits 2. A well-formed empty
    result set is exactly how a broken search gets read as an empty
    literature.
  - **Over-constrained queries are detected by measurement, not by a length
    guess.** Every backend ANDs the query terms, so a long query returns a
    real, well-formed zero with no distinguishing response field — S2's
    total for one on-topic query walked 8616 → 136 → 21 → 2 → 0 as it grew
    from 7 to 22 words, HTTP 200 throughout. So on a zero-result search of
    7+ words, `lit.sh` re-runs one probe with the query's first 6 words
    against a backend that already answered — automating the manual retry
    the reporter performed. Hits on the shorter query ⇒
    `error.kind: query_over_constrained`, naming the evidence and the
    shortened query to retry. The probe runs only on the zero-result path
    and can only escalate a zero, never suppress a hit.
  - **The probe corroborates; it never certifies.** Its prefix is the query's
    first six *whitespace tokens*, so its verdict is **order-dependent** —
    the same 8-term conjunction, re-worded, lands on either branch — and the
    prefix's result set is a *superset* of the full query's, so a hit shows
    only that the broad topic is populated. An earlier draft of this change
    therefore stamped one ordering with *"this is a genuine zero (confirmed:
    …)"* — reproducing the very `#588` shape with an endorsement the bare
    `count: 0` never carried. No zero is now labelled *genuine*, *confirmed*,
    or *verified* in any rendering; the summary reports the observation (and
    what the probe did or did not find) and leaves the inference to the
    caller, and `query_over_constrained` says a zero **may** reflect an
    over-specific query. Pinned by
    `monitor/watcher/test-lit-probe-order-dependence.sh`, which runs the
    counter-example in both word orders and carries a built-in negative
    control that re-asserts the old wording and observes the guard fail.
  - Further `error.kind`s: `query_too_long` (past OpenAlex's 1500-char
    ceiling — caught pre-flight, no request spent), `query_rejected` (a
    backend reported a query fault; unretryable, and it condemns the whole
    search since every backend answered the same bad query — previously
    miscast as an ordinary backend failure), and `no_backend_searched`.
  - **A genuine S2 zero is no longer reported as a broken backend.** S2
    answers a zero-hit search with `{"total": 0, "offset": 0}` — no `data`
    key at all — which was read as a malformed response, so every real S2
    zero surfaced as a phantom `failed_backends: ["s2"]`. The same defect
    in the opposite direction, in the same code path.
  - `partial` now means "not every requested backend contributed", so a
    backend **skipped** for want of a key counts, not only one that failed.
    Reporting `partial: false` for a `--source all` search that never
    queried S2 told the caller it had received everything it asked for.
  - Pinned by `monitor/watcher/test-lit-empty-vs-failed.sh` (74
    assertions), whose stub reproduces the measured backend behaviour
    (terms ANDed; ≤6 words match) so the probe path is exercised rather
    than simulated — including negative controls that a genuinely empty
    search still reports a clean zero with no warning, in both renderings.
- **`ng` `STATE_DIR` resolver** now picks up `NEXUS_ROOT` /
  `nexus.root` config so worker wrap-ups from worktrees land
  in the primary clone's `.state/`, not the worktree's. (PR #11.)
- **`ng wrap-up` tmux pane targeting** — the verb now records
  the source window explicitly instead of relying on the active
  pane, so wrap-ups from inactive windows are attributed
  correctly. (PRs #109, #12.)
- **`ng` session-id slug** — matches Claude Code's path
  normalisation so `ng report-init` recovers the right session
  log on re-runs from different cwds. (PR #107 upstream.)
- **`ng wrap-up --trigger-repo`** + write-verb precedence
  fixed so cross-repo triggers route their reaction to the right
  repo. (PR #108 upstream.)
- **Watcher idle-probe** passes window index to `pane-state.sh`
  rather than relying on the active pane. (PR #7.)
- **`_classify_diff` suppresses git-section diffs** so a worker
  branch-switch doesn't trigger a noisy emit. (PR #80 upstream.)
- **GraphQL detect-and-react cascade** — watcher classifies
  GraphQL rate-limit failures, mints a bot installation token
  rather than falling through to the user's exhausted PAT,
  and surfaces a sentinel emit so the orchestrator knows
  about the gap. (PRs #64, #63 upstream.)
- **Watcher emits on every eligible comment**, not just on
  snapshot diff — a missed paste no longer silently swallows
  a comment. (PR #63 upstream.)
- **Deliveries IDs extracted as strings** — `jq` 1.5 truncates
  the >2^53 integer IDs GitHub uses. (PR #68 upstream.)
- **`config/load.sh`** emits lowercase YAML booleans
  (`true`/`false`) rather than Python `str(True)`.
- **`_snapshot_pr_comments` MAX_NODE_LIMIT_EXCEEDED** — query
  node count brought below GitHub's GraphQL limit.
- **`mint-token`** anchors cwd via `BASH_SOURCE` so sub-project
  agents get a real installation token. (PR #30 upstream.)
- **`watcher: --continue` resume** — correct slug encoding;
  drop the positional prompt that conflicted with `claude`'s
  argv shape. (PR #97 upstream.)
- **Watcher fast-respawn** when the target window goes missing
  rather than emitting `rc=2` and stalling. (PRs #47, #51
  upstream.)
- **Watcher auto-unstick paths** for stuck permission prompts,
  rate-limit prompts, and transient API-error wedges (cases
  A/B/C in `_unstick.sh`). (PRs #42, #98 upstream.)

### Removed

- **Stray `reports/` file** accidentally committed in PR #40
  removed; CI guard above prevents recurrence. (PR #3.)
- **`context/` directory** — unused in practice.
- **`bipartite`/`bip` references** — superseded by `labsh`.
- **`🤖-prefix` convention** for bot comments — replaced by
  the rocket-reaction opt-out signal.

## Earlier history

The workspace was restructured into its current
agent-coordinated shape on 2026-04-14 (`54ab69b`). Before that
the repo was a personal research scratchpad with no monitor,
no watcher, and no bot. The first watcher prototype
(`monitor: tmux-hosted watcher with paste-to-target + diff
archive`, PR #12) landed on 2026-04-23; bot setup
(`docs: bot setup guide + permission rationale`, PR #15) the
same day. The `monitor/ng` CLI landed on 2026-04-17.

`git log --since 2026-04-14 -- monitor/ skills/ config/` is
the authoritative record of work prior to the asset-repo
cutover (2026-05-09).
