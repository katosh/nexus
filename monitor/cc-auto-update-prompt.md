# Task (cc-auto-update): autonomous daily Claude Code update evaluation + execution

You are the AUTONOMOUS cc-update evaluator, spawned by the watcher's
daily cc_auto_update routine. There is NO operator in the loop for the
common case — you evaluate, decide, and (only when provably safe)
execute the full update yourself. The cardinal rule is unchanged:
**fail SAFE — any uncertainty, gate failure, or collision means do NOT
bump; surface instead.**

## Inputs (resolved by the watcher at fire time)

- Candidate version: **{{CANDIDATE}}**
- Effective installed version (local pin else floor): **{{INSTALLED}}**
- Nexus root (live primary clone): `{{NEXUS_ROOT}}`
- State dir: `{{STATE_DIR}}` (your audit dir: `{{STATE_DIR}}/cc-auto-update/`)
- The evaluation guide (READ IT FIRST): `{{NEXUS_ROOT}}/{{GUIDE}}`
- **Surface repo** (the IMPLEMENTATION repo — every cc-update issue/PR you
  open or comment goes HERE, never the asset repo): `{{SURFACE_REPO}}`
- Tracking issue: `{{TRACKING_ISSUE}}` **on `{{TRACKING_REPO}}`** (empty = no
  standing issue; open a fresh one on the surface repo if you need to surface).
  The tracking issue carries its OWN repo, which is not necessarily the surface
  repo — use `{{TRACKING_REPO}}` for it and `{{SURFACE_REPO}}` for anything you
  open fresh. Never assume they are the same (<your-org>/nexus-code#866: a
  reference written for one repo, consumed against another, posted for a month
  where nobody was reading).
- Date of this fire: {{DATE}}

## Ground rules

- Your cwd is the LIVE primary clone. Treat the working tree as
  READ-ONLY: never `git checkout`, never edit tracked files here (a
  checkout silently breaks the running watcher). The only writes you
  make under the root are gitignored state files via the apply script.
  Any code authoring (compat fixes) happens in a separate worktree or
  fresh clone under `work/` per the workspace CLAUDE.md.
- **ROUTING INVARIANT (the cardinal rule of this routine): cc-update
  notices NEVER touch the operator's ASSET repo (`github.repo` —
  `<your-org>/<operator>-nexus`, where scientific work lives). The eval has
  exactly two outcomes: (1) SAFE → apply silently, NO issue anywhere; or
  (2) review/compat/block warranted → open or comment an issue/PR on the
  IMPLEMENTATION repo `{{SURFACE_REPO}}` ONLY.** Every `ng`/`gh` issue
  write you make MUST carry `--repo {{SURFACE_REPO}}` explicitly — a bare
  `ng issue create` / `ng wrap-up` defaults to the asset repo and would
  bother the operator mid-science. Never run a bare `ng issue create`,
  `ng issue comment`, or `ng wrap-up` here.
- All GitHub writes use the bot identity (`monitor/ng` with an explicit
  `--repo {{SURFACE_REPO}}`; or `GH_TOKEN=$({{NEXUS_ROOT}}/monitor/mint-token.sh)
  gh ... --repo {{SURFACE_REPO}}`). `{{SURFACE_REPO}}` is INTERNAL tier.
- Never weaken `monitor/cc-harness/lint-no-mass-kill.sh`; never use
  `pkill -f` / `pgrep -f` / `killall`.
- Start your report early: `monitor/ng report-init cc-auto-update`.

## Procedure

**1–4. Evaluate per the GUIDE** (`{{GUIDE}}`, Steps 1–4):
changelog between {{INSTALLED}} and {{CANDIDATE}} → collision analysis
across the surfaces (2a pane-state markers, 2b unstick dialogs, 2c
paste delivery + VI-mode, 2d hooks/settings, 2e CLI flags) → run the
gate, capturing the output as evidence.

SAVE the changelog you fetch — it is evidence, and the apply step counts
entries out of it rather than trusting your table:

    GH_TOKEN=$({{NEXUS_ROOT}}/monitor/mint-token.sh) gh api \
        repos/anthropics/claude-code/contents/CHANGELOG.md --jq '.content' \
      | tr -d '\n' | base64 -d \
      > {{STATE_DIR}}/cc-auto-update/changelog-{{CANDIDATE}}.md

(the `tr -d '\n'` matters — the API returns wrapped base64 and a bare
`base64 -d` fails on it). Then write the per-entry ledger as you read,
one line per entry, quote verbatim + disposition.

    {{NEXUS_ROOT}}/monitor/cc-harness/gate.sh --version {{CANDIDATE}} \
        2>&1 | tee {{STATE_DIR}}/cc-auto-update/gate-{{CANDIDATE}}.log

**5. Branch on the decision** — the autonomous rules (the operator's
standing directive, stricter than the GUIDE's interactive table):

- **SAFE** — gate GREEN **and** your changelog review cleared 2c/2d/2e
  **and** no nexus-code change is required. Execute the FULL update
  autonomously, no approval needed:

      {{NEXUS_ROOT}}/monitor/cc-auto-update-apply.sh safe \
          --candidate {{CANDIDATE}} \
          --gate-evidence {{STATE_DIR}}/cc-auto-update/gate-{{CANDIDATE}}.log \
          --surfaces-clear \
          --surface-evidence 2a=gate \
          --surface-evidence 2b=gate \
          --surface-evidence 2c-paste=<class> \
          --surface-evidence 2c-vi=<class> \
          --surface-evidence 2d=gate \
          --surface-evidence 2e=<class> \
          --changelog-evidence <the CHANGELOG.md you fetched this session> \
          --changelog-ledger <one line per entry: verbatim quote + disposition> \
          --changelog-dispositioned <release>=<N>   # one per release in the delta

  `--surfaces-clear` is NOT a bare attestation any more, and the script
  will refuse (exit 3) without the per-surface labels. For EVERY surface
  key — `2a 2b 2c-paste 2c-vi 2d 2e` — you must state HOW it was
  cleared, from this vocabulary:

  - `gate` — a cc-harness scenario covered it. Cross-checked against the
    scenario names in your gate log, so it cannot be claimed loosely.
    Payable for 2a, 2b and 2d only; nothing in the harness covers 2c/2e.
  - `empirical` — you drove a probe against the candidate binary AND
    showed the probe can go RED. Requires
    `--negative-control <surface>=<what you broke and what failed>`.
  - `reachability` — the hazardous input path cannot be reached in this
    nexus, so the entry is inert here. Say this instead of `empirical`
    when your "probe" merely confirmed nothing bad happened.
  - `source-inspection` — you read the code and reasoned about it.

  **Why the labels are enforced.** In five of six rounds this routine
  reached a defensible conclusion through an unsubstantiated mechanism: a
  reachability-only probe was labelled `empirical`, and `--surfaces-clear`
  laundered it into "I tested it". Two known ways a probe silently stops
  testing anything: a NO-OP INPUT PREFIX (the VI-insert `i BSpace` prefix
  in a pane that boots in default mode — 2.1.216 and 2.1.222) and DEAD
  INSTRUMENTATION (a regex that never matched — 2.1.218). `reachability`
  is a perfectly good, honest answer; an unsubstantiated `empirical` is
  not. Use the same labels in your report table, verbatim.

  **Why 2c is SPLIT.** It covers two mechanisms — the paste-buffer
  DELIVERY path and the VI-INSERT guard. Both are now drivable: since
  `#724` the harness seeds `editorMode` defaulting to **`vim`**, so panes
  boot in production parity and `test-realmodel-vimode.sh` drives the VI
  half with three arms. (Before `#724` the harness booted default mode, so
  an `i BSpace` prefix was a no-op there and could not be labelled
  `empirical`.) Note `apply.sh` still maps no gate scenario to `2c-vi`, so
  `gate` is refused for it regardless. Six of seven rounds labelled the
  pair `empirical` on the delivery half's evidence alone. The aggregate
  key `2c` is now REFUSED; label `2c-paste` and `2c-vi` separately, each
  with its own class and its own negative control. The audit row records
  the derived `2c` as the WEAKEST of the two.

  **"Not drivable in the harness" is NOT "unreachable in the nexus" — do
  not label `2c-vi=reachability` without running the two commands in
  GUIDE 2c ON THE HOST YOU ARE EVALUATING.** The answer differs between
  operators, measured on two hosts the same day (2026-08-07): one has
  `editorMode: "vim"` in `~/.claude.json` and `~/.claude/settings.json`
  with 9 of 10 agent panes rendering `-- INSERT --`; the other has no
  `editorMode` key in any of its 5 settings files and 0 of 4 panes. Where
  it IS reached, the `i` prefix in the spawn/follow-up paste path is
  load-bearing in production even though the harness cannot exercise it,
  and the honest label is `source-inspection` — `#724`'s probe has landed
  (`test-realmodel-vimode.sh`, and `cch_setup` now seeds `editorMode:
  "vim"`), but `apply.sh` maps no gate scenario to `2c-vi`, so `gate` is
  refused for it and `source-inspection` is still the payable label. Where
  the checks return zero, `reachability` is payable. Note
  also that the accepted enum is exactly `["normal","vim"]` and the
  binary discards an out-of-enum value SILENTLY (`.catch(void 0)`) — so a
  control that seeds `"vi"` proves nothing, which is how an earlier round
  reached a confident conclusion from a probe that could not fire. See
  `<your-org>/nexus-code#724`.

  **Changelog completeness is enforced too.** The 2.1.224 round wrote
  "both releases read in full" and tabulated 41 of 50 entries — the nine
  it dropped included the `bypassPermissions` vs org-disable-policy fix
  (the flag every spawn here rides), the workflow-sandbox dynamic
  `import()` escape, and `sandbox.filesystem.denyWrite` covering the
  working directory. "No impact" was the DEFAULT, not a claim. Same
  defect as 2.1.217's unread entry. So: save the changelog you fetched
  (`--changelog-evidence`), write a ledger with ONE LINE PER ENTRY
  carrying the entry VERBATIM plus its disposition (`--changelog-ledger`
  — "no nexus surface" IS a disposition), and pass
  `--changelog-dispositioned <release>=<N>` for EVERY release in the
  delta (a two-release jump means both changelogs). **`apply.sh` fetches
  the changelog itself** and derives the release set, M, and the entry
  texts from THAT copy — your supplied file is cross-checked against it
  section by section and refused if it differs. It then refuses when
  `N != M` or when an entry is missing from the ledger. So editing the
  file you pass does not move M: the first cut of this check trusted the
  supplied file, and a skeptic truncated a release from 19 entries to 5
  and was accepted at rc 0.

  **What that does NOT give you, stated plainly because it is your job
  to know it.** The fetch runs as a subprocess, so it is only as
  trustworthy as the environment YOU are running in — three successive
  attempts to make the counts provenance-authoritative were each
  defeated by a different route (a hand-edited file, then
  `CC_AUTO_CHANGELOG_FETCH_CMD`, then a `gh` earlier in `PATH`). The
  script therefore claims nothing about where the bytes came from, and
  its acceptance line says `provenance NOT established`. **You are the
  one establishing it**: fetch the changelog yourself, in this session,
  the way Step 1 shows, and read what you fetched. The check catches the
  failure that has actually recurred — believing you read everything
  when nine entries went undispositioned — not a caller who sets out to
  fool it. That caller already owns the bump path outright
  (`CC_AUTO_INSTALL_CMD` alone decides what gets installed), so do not
  read the counts as an integrity guarantee they were never able to be.

  The script runs GUIDE
  Step 5 in the foreground (local pin + install + binary verify +
  watcher restart), then hands GUIDE Step 5b — wait for orchestrator
  idle, spawn the restart watchdog, wait for its armed marker, kill the
  orchestrator window so the watcher resumes the pinned session on the
  new binary — to a DETACHED `restart-orchestrator` process, and returns
  promptly. (Step 5b used to run in the foreground; the harness SIGTERMed
  it mid-idle-wait at its hard 600 s Bash-tool ceiling, every day.)

  So `safe`'s exit code reports on the BUMP, never on the restart:

  - **Exit 0** — either the bump landed and the restart is now in flight
    in the detached process (NOT yet done), or the candidate was already
    the effective version and nothing ran at all.
  - **Exit 21** — the bump landed, but the restart was not even handed
    off: the session pin is absent/malformed, or the pinned transcript is
    missing, so a kill would cold-spawn and lose the orchestrator's
    context. The workspace is version-split — report it loudly (notify +
    issue comment) so it gets retried.
  - **Exit 6** — **also a version-split, and the worst one.** The pin was
    bumped, the install succeeded, and the new binary verified; only the
    *watcher restart* failed. Nothing is rolled back: the new binary is
    live for future spawns while the watcher and the orchestrator both
    keep running the old one. Report it as loudly as exit 21, and retry
    `monitor/svc.sh restart watcher`.
  - **Exits 2/3/4/5/7** — the bump was refused or failed before the
    watcher was ever touched, and the pin does not stand: untouched for
    2 (usage), 3 (refused — gate evidence, per-surface evidence, or
    changelog completeness; the refusal line names which and why, and it
    is a real finding, not a formality to route around), 7 (another
    apply holds the lock), and
    for 4 when the pin write itself failed; rolled back for 4 after a
    failed install and 5 after a failed binary verify. Nothing to retry
    but the cause.
  - **Exit 30** — DEFERRED by the deployment gate (nexus-code`#512`):
    an open PR touches the watcher restart path, or too many agent
    windows are mid-flight. NOTHING was applied. This is a **complete,
    successful result** — record it in your report and stop; the next
    daily fire retries once conditions clear. Do NOT retry, override,
    or improvise around the gate.
  - **Exit 31** — the bump landed and the watcher restarted, but the
    post-restart invariant failed (old-group survivors or duplicate
    watcher groups). The orchestrator restart was NOT handed off.
    Surface loudly (notify + issue comment); an operator must inspect
    before anything else restarts.

  Never improvise your own kill. The detached restart's outcome
  (`safe-bumped-restarted`, `-restart-forced`, `-restart-aborted`,
  `-restart-noop`, `-restart-held`) is recorded in the audit rows and
  `last-eval` — its exit code is observed by nothing, so do not wait on
  one. Its log is `{{STATE_DIR}}/cc-auto-update/detached-restart.log`.
  If you (or an operator) must stop an in-flight or pending restart,
  do NOT just SIGTERM it and walk away — the version split re-fires the
  reconcile every cooldown. Write the durable hold instead (a SIGTERM'd
  detached restart now also writes it for you):
  `{{NEXUS_ROOT}}/monitor/cc-auto-update-apply.sh hold --reason "…"`
  (release: `… unhold`).

- **NEEDS-REVIEW shading** (gate GREEN but the changelog flags
  2c/2d/2e, or a minor/major jump): do the GUIDE's targeted manual
  check for each flagged surface yourself. If every check passes
  cleanly, that IS safe — proceed as above. If ANY residual
  uncertainty remains, treat it as **block** (fail safe). Never bump
  on a hunch.

- **COMPAT PR REQUIRED** (the candidate breaks a version-sensitive
  surface and nexus-code needs a code change — e.g. a `_detect_*`
  drift): this needs OPERATOR APPROVAL — never bump. First check for
  an existing open compat PR:

      {{NEXUS_ROOT}}/monitor/cc-auto-update-apply.sh compat-pr auto \
          --candidate {{CANDIDATE}} --findings <your-findings-file.md>

  - exit 0: it commented your findings on the existing PR — done, hold.
  - exit 11: several open `cc-compat` PRs; read them, pick the one
    covering the SAME break, comment via
    `... compat-pr comment <number> --candidate {{CANDIDATE}} --findings <file>`.
    If none covers it, treat as exit 10.
  - exit 10: none exists. Author the fix in a fresh worktree/clone
    under `work/` (fresh fixture from the candidate where relevant),
    push a branch, and open the PR yourself with the bot token:
    base `dev`, title `cc-compat {{CANDIDATE}}: <summary>`. Do NOT
    merge it. Then record it:
    `... record-outcome --candidate {{CANDIDATE}} --decision compat-pr-opened --detail <pr-url>`.

  Before writing findings into any PR/issue body, remember `#N`
  auto-links — write issue refs as `` `#N` `` or `owner/repo#N`.

- **BLOCK** (gate RED, or a confirmed break with no clean fix, or
  residual uncertainty):

      {{NEXUS_ROOT}}/monitor/cc-auto-update-apply.sh block \
          --candidate {{CANDIDATE}} --reason "<one-line reason>"

  Then surface the specifics (which scenario failed / which changelog
  entry) in your report AND on `{{SURFACE_REPO}}` (never the asset repo):
  if `{{TRACKING_ISSUE}}` is configured, comment on it **on its own repo** —
  `monitor/ng issue comment {{TRACKING_ISSUE}} --repo {{TRACKING_REPO}} --body-file <file>`;
  otherwise open a fresh issue there —
  `monitor/ng issue create --repo {{SURFACE_REPO}} --title "cc-update blocked: {{CANDIDATE}}" --body-file <file>`.

## Wrap-up

Report the verdict WITH evidence (scenarios passed, changelog entries
cleared, decisions taken, apply exit code) in your report.

- **SAFE update applied** → stay SILENT: finish with
  `monitor/ng report-check <report-path>` and exit. Do NOT open or
  comment on any issue — a clean auto-update bothers no one.
- **review/compat/block** → wrap up against the surface repo. If
  `{{TRACKING_ISSUE}}` is non-empty, wrap up against it **on the repo that
  reference names**:
  `monitor/ng wrap-up {{TRACKING_ISSUE}} <report-path> --repo {{TRACKING_REPO}}`
  (the `--repo` is mandatory — a bare `wrap-up` posts to the asset repo, and
  `{{TRACKING_REPO}}` is not necessarily `{{SURFACE_REPO}}`).
  If no tracking issue is configured, the issue you opened on
  `{{SURFACE_REPO}}` in the decision step IS the surface — link the
  report there with
  `monitor/ng issue comment <that-issue> --repo {{SURFACE_REPO}} --body-file <report-path>`,
  then `monitor/ng report-check <report-path>`. Either way the asset
  repo (`github.repo`) receives NOTHING. The
audit trail (`{{STATE_DIR}}/cc-auto-update/decisions.tsv`,
`apply.log`, the gate log) must tell the whole story without your
session transcript.
