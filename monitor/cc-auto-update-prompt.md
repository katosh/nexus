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
- Tracking issue **on `{{SURFACE_REPO}}`** (empty = no standing issue;
  open a fresh one there if you need to surface): `{{TRACKING_ISSUE}}`
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
VI-mode, 2d hooks/settings, 2e CLI flags) → run the gate, capturing
the output as evidence:

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
          --surfaces-clear

  Pass `--surfaces-clear` ONLY as a truthful attestation that the
  changelog review cleared the non-gate surfaces. The script runs GUIDE
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
    2 (usage), 3 (gate refused), 7 (another apply holds the lock), and
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
  if `{{TRACKING_ISSUE}}` is configured, comment on it —
  `monitor/ng issue comment {{TRACKING_ISSUE}} --repo {{SURFACE_REPO}} --body-file <file>`;
  otherwise open a fresh issue there —
  `monitor/ng issue create --repo {{SURFACE_REPO}} --title "cc-update blocked: {{CANDIDATE}}" --body-file <file>`.

## Wrap-up

Report the verdict WITH evidence (scenarios passed, changelog entries
cleared, decisions taken, apply exit code) in your report.

- **SAFE update applied** → stay SILENT: finish with
  `monitor/ng report-check <report-path>` and exit. Do NOT open or
  comment on any issue — a clean auto-update bothers no one.
- **review/compat/block** → wrap up against the surface repo. If
  `{{TRACKING_ISSUE}}` is non-empty, wrap up against it **on the
  implementation repo**:
  `monitor/ng wrap-up {{TRACKING_ISSUE}} <report-path> --repo {{SURFACE_REPO}}`
  (the `--repo` is mandatory — a bare `wrap-up` posts to the asset repo).
  If no tracking issue is configured, the issue you opened on
  `{{SURFACE_REPO}}` in the decision step IS the surface — link the
  report there with
  `monitor/ng issue comment <that-issue> --repo {{SURFACE_REPO}} --body-file <report-path>`,
  then `monitor/ng report-check <report-path>`. Either way the asset
  repo (`github.repo`) receives NOTHING. The
audit trail (`{{STATE_DIR}}/cc-auto-update/decisions.tsv`,
`apply.log`, the gate log) must tell the whole story without your
session transcript.
