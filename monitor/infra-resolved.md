# Resolved infrastructure friction

Append a row when a PR ships that retires a recurring friction
documented in agent reports' `## Infrastructure Issues` sections (the
source corpus for the periodic meta-review). Future meta-review
prompts read this file first and exclude these themes — that's how we
avoid re-discovering already-fixed problems.

Each row identifies the theme by its observable symptom, lists the
original report file(s) where it was first / most-cited, and points at
the fix commit or PR. Keep theme names short and stable; future
meta-reviews will pattern-match against them. Cite paths are
`reports/<file>.md` (omit the `reports/` prefix in the table for
density). When a fix is partial, link the follow-up alongside it
rather than removing the original row.

In-flight PRs that retire themes get listed under `## In-flight (not
yet merged)` at the bottom; when they merge, move the row up into the
main table with the actual merge commit.

## Reconciliation status

**Last reconciled: 2026-06-18**, against `<your-org>/nexus-code` merged
PRs #1–#297. This pass is the `<your-org>/<your-nexus>#236` **B14**
follow-up: the 2026-06-17 fleet meta-review flagged this index as
frozen at 2026-04-28 (pre repo-migration, ~280 PRs merged since), so it
could no longer be trusted to exclude already-shipped fixes.

**Repo-migration boundary.** The nexus split into two repos around
2026-05-10: `<your-org>/nexus-code` (the canonical implementation repo
every operator clones — where this file now lives) and the per-operator
asset+issue repos (e.g. `<your-org>/<your-nexus>`). Rows dated
**≤ 2026-04-28** cite **pre-migration `<your-org>/<your-nexus>`** PR
numbers and commit hashes — and some of those commits do **not** resolve
in `nexus-code` history (the migration did not carry full history; e.g.
`b685ef5` is absent). Rows dated **≥ 2026-05-10** cite
**`<your-org>/nexus-code`** PR numbers and merge commits. Cross-repo
references are written `owner/repo#N`.

**Scope caveat (what this pass did NOT do).** B14 reconciled the
*merged-PR side* — which fixes shipped. It did **not** re-attribute each
fix to its originating `## Infrastructure Issues` report cite, because
`reports/` is gitignored and lives only in the operator's main clone
(this reconciliation ran in a fresh `nexus-code` clone with no corpus).
New rows therefore cite the PR's own closing issue and/or the `#236`
universal-theme anchor rather than report filenames. A corpus-having
pass (run from the main clone per `skills/nexus.infra-review`) can
back-fill report cites if desired. Crucially, `#236`'s universal themes
**U1–U13 are still recurring as of June 2026** — rows were added here
**only** for symptoms a merged PR *completely* retired and that `#236`
does **not** still cite; broad still-open themes (watcher liveness,
EROFS deliverable-writes, Python source-builds, the `ng` papercut
cluster) were deliberately left out of Resolved.

## Resolved

| Date       | Theme                                                                                                                | Original cites                                                                                                                              | Fix                                                                                                              |
|------------|----------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------|
| 2026-04-23 | `ng dashboard put` returns nonzero with `tmp_new: unbound variable` under `set -u`                                   | `nexus_2026-04-18_113300_dashboard-refresh.md`; `nexus_2026-04-19_184500_dashboard-refresh.md`; `nexus_2026-04-23_111200_watcher-adoption.md` | `b685ef5` (PR #13)                                                                                               |
| 2026-04-23 | `ng` lacks `pr` / `issue` subcommands; agents fall back to raw `gh` for bot-write ops                                | `nexus_2026-04-19_102354_palantir-rng-review.md`; `agent_sandbox_2026-04-20_020905_hardening-audit.md`                                       | `3a69e67`, `8fe57a1`                                                                                             |
| 2026-04-23 | `ng issue create` rejects empty labels (`labels: [""]`)                                                              | `nexus_2026-04-23_130411_nexus-consolidate.md`                                                                                              | `8fe57a1`                                                                                                        |
| 2026-04-23 | `upload-asset.sh` double-prepends `status-assets/` when caller already includes it                                   | `nexus_2026-04-18_103731_status-assets-cleanup.md`                                                                                          | `b3a6cbf`                                                                                                        |
| 2026-04-23 | Tmux `new-window` steals attached client's focus when spawning agents                                                | `nexus_2026-04-23_104000_watcher-redesign.md`                                                                                               | `dd1e449`                                                                                                        |
| 2026-04-23 | Watcher mutual-liveness contract was ambiguous; agent and watcher could both wedge silently                          | various                                                                                                                                     | `7c1116e` (PR #19)                                                                                               |
| 2026-04-24 | Wiki bot git identity hardcoded; per-deployment values not in `nexus.yml`                                            | implicit                                                                                                                                    | `41c07a5` (PR #23)                                                                                               |
| 2026-04-26 | `🤖`-prefix convention for "agent comment, skip me" was brittle; replaced by rocket-reaction opt-out                  | implicit                                                                                                                                    | `51e33f2`                                                                                                        |
| 2026-04-28 | Wiki `.md` rendering 404 in subdirs (URL points at raw asset, not page renderer)                                     | `nexus_2026-04-27_181500_wiki-md-fix.md`                                                                                                    | `8bcfaa9` (PR #26) — partial; see in-flight `<operator>/wiki-md-root` (PR #32) for the proper root-routing fix |
| 2026-04-28 | `.gitignore` lacks `**/.nfs*` (NFS silly-rename) and `.worktrees/` (parallel-agent worktrees) patterns                | `kompot_notebooks_private_2026-04-18_105657_harmony-lolipop.md` (meta-review theme #10)                                                     | `b0e1f0b` (direct push to main)                                                                                  |
| 2026-04-28 | Five recurring agent traps not in `CLAUDE.md` / `monitor/agent-prompt.md` (PR-author verify; `mint-token.sh` cwd; `user-attachments` URL session-poison; `git checkout <ref> -- <path>` destructive; `pip` hang in sandbox → use `uv pip`) | `nexus_2026-04-28_205158_prompt-callouts.md` (meta-review theme #15 / orchestrator memory)                                                  | `07b1549` (PR #28). The `mint-token.sh cwd` callout was superseded the same day by PR #30's actual fix below.    |
| 2026-04-28 | `mint-token.sh` is cwd-sensitive and silently falls through to ambient user `gh` auth when invoked from a non-nexus-root cwd (security boundary) | `kompot_revisions_2026-04-19_195459_mahal-coupling-wrapup.md` (meta-review theme #4 / backlog item #2a)                                     | `4fc4438` (PR #30)                                                                                               |
| 2026-05-10 | Wiki-based asset hosting retired entirely — the subdir `.md` 404 (row above), basename collisions, and wiki-page-renderer routing are all moot; assets now host from the asset repo with SHA-pinned `blob`/`raw` URLs. **Supersedes** the 2026-04-28 wiki-`.md` row and the dead `<operator>/wiki-md-root` in-flight entry. | design discussion `<your-org>/<your-nexus>#104`                                                                                                | `<your-org>/nexus-code` PR #1 (`e0c802d`)                                                                          |
| 2026-05-19 | `upload-asset.sh` silently skips files matched by the asset repo's `.gitignore` (no breadcrumb), so a bare gitignored path 404s when referenced from a comment                                  | closes `<your-org>/nexus-code#144`                                                                                                            | `<your-org>/nexus-code` PR #145 (`1949f27`) — `git check-ignore` breadcrumb + `git add -f`                        |
| 2026-06-02 | `monitor.target_window` was configurable in name only, and `nexus.example.yml` shipped a stale `claude` default (vs code-default `orchestrator`); an operator copying the example verbatim hit a respawn crash-loop. Retires the `#236` **U1(d)** target-window-drift sub-theme. | closes `<your-org>/nexus-code#209`; `<your-org>/<your-nexus>#236` U1(d)                                                                          | `<your-org>/nexus-code` PR #210 (`0293af0`) — fixed example default + 4 hardcoded `orchestrator` sites + rename-off pinning |
| 2026-06-03 | `install-claude-local.sh` fails when `node` is absent from PATH on Lmod / environment-module HPC hosts (<your-institution> <cluster>, EasyBuild), degrading spawn surfaces to a system `claude` and losing the `package.json`-pinned upgrade path                            | closes `<your-org>/nexus-code#218`; diagnosed `<your-org>/<other-nexus>#41`                                                                     | `<your-org>/nexus-code` PR #219 (`b3d4c7d`) — Lmod-aware node bootstrap, invoked only when `node` absent          |
| 2026-06-05 | `install-claude-local.sh` `npm install` aborts with `EROFS` writing the default `$HOME/.npm` cache on read-only-`$HOME` sandbox / HPC hosts, breaking the fresh-operator bootstrap before any package fetch                                                      | closes `<your-org>/nexus-code#230`                                                                                                            | `<your-org>/nexus-code` PR #231 (`39928a4`) — exports project-local `npm_config_cache`                            |
| 2026-06-10 | Bash-tool process-kill footguns absent from the worker floor: `pkill -f`/`pgrep -f` self-kill (the worker's full prompt rides in `claude`'s argv), and `jobs -p` empty in each fresh Bash-tool shell so `kill $(jobs -p)` no-ops and leaks busy-loops. Retires the `#236` §4 process-kill one-offs (not the `cd <clone> &&` push rule — that part of B13 is still open). | `<your-org>/<your-nexus>#236` §4 high-impact one-offs (operator-witnessed 2026-06-09)                                                          | `<your-org>/nexus-code` PR #246 (`6ae3b28`) — two floor bullets in `skills/nexus.worker-defaults`                 |
| 2026-06-11 | After `git pull`, the running watcher / services cockpit / registered services kept executing OLD code until a manual restart                                                                  | closes `<your-org>/<your-nexus>#186`                                                                                                           | `<your-org>/nexus-code` PR #254 (`221f693`) — version-aware per-component drift detection + self-restart (default on) |

## In-flight (not yet merged)

The pre-migration in-flight branches below were all dispositioned in
the 2026-06-18 reconciliation — none remain open against `nexus-code`
under their old names:

- `<operator>/ng-omnibus` (was `<your-org>/<your-nexus>#31`) — **landed via
  migration.** The `ng` verbs it added (`react`, `reply --repo`,
  `preflight`, `wrap-up`, `--repo` plumbing) are all present in the
  current `monitor/ng`.
- `<operator>/wiki-md-root` (was `<your-org>/<your-nexus>#32`) —
  **superseded by `<your-org>/nexus-code#1`** (wiki asset-hosting retired
  for the asset repo; the `.md`-routing problem it targeted no longer
  exists).
- `<operator>/claude-md-consolidate` — **landed.** `CLAUDE.md` is the
  consolidated form; not-always-relevant content moved to the `nexus.*`
  skills.
- `<operator>/nexus-gitconfig` — **NOT landed.** `config/gitconfig` is
  absent from current `nexus-code`; the sandbox-git-defaults theme
  (`commit.gpgsign`, `safe.directory`, `gh auth setup-git` write
  failure) is unretired. Re-file if still wanted.
- `<operator>/<your-org>-sandbox-gotchas-skill` (`<your-org>/<hpc-skills>#2`)
  — **landed** (the `<your-org>.sandbox-gotchas` skill ships).
- `<operator>/nexus-skills` (`<your-org>/<hpc-skills>#3`) — **landed**
  (`nexus.bot` / `nexus.tmux-spawn` / `nexus.report` ship under
  `skills/`).
- `<operator>/paths-and-venv-extras` (`<your-org>/kompot_revisions#1`) — out
  of `nexus-code` scope (a downstream project repo); track there.

Newly opened, awaiting merge:

- 2026-06-24 — `compose_emit` awk filter pipeline trips gawk's
  invalid-multibyte decoder on byte-truncated non-ASCII comment-body
  previews (chronic `Invalid multibyte data detected` log noise +
  locale-undefined regex/token matching), coincident with a
  watcher-wedge → supervisor-revive incident. Fixed at the source with
  `LC_ALL=C` on every body-decoding compose_emit awk (mirrors the
  `_reemit.sh` re-feed precedent) plus a `_run_bounded` guard so the
  filter pipeline can never stall the cycle-end heartbeat. In-flight
  `<operator>/compose-emit-multibyte` (`<your-org>/nexus-code#354`). Move up
  into the Resolved table with the merge commit when it lands.
- 2026-06-25 — skeptic-pending markers LEAKED on essentially every
  skeptic retirement: `ng retire-preflight` returned `safe=0 (skeptic
  has not returned a verdict — marker live)` on skeptics + targets that
  had already verdicted, forcing a manual `rm
  monitor/.state/skeptic/pending/<name>` each time. Root cause: `ng
  wrap-up`'s verdict path speculatively wrote retire-blocking markers
  (the skeptic's own + a re-assert of the original) for a merely
  RECOMMENDED second-pass skeptic the orchestrator routinely declined,
  with no path to clear them. Fixed by clearing ALL chain markers on the
  verdict (a returned verdict satisfies the gate) and RE-establishing the
  block from `spawn-worker.sh` only when an actual next skeptic is
  spawned. In-flight `<operator>/skeptic-marker-cleanup`. Move up into the
  Resolved table with the merge commit when it lands.

**Current open backlog.** As of 2026-06-17 the authoritative
open-infrastructure backlog is the fleet meta-review at
`<your-org>/<your-nexus>#236` (items **B1–B15**, ranked by cross-operator
frequency; universal themes **U1–U13**). Those themes are *still
recurring* as of June 2026 — do **not** read the Resolved table above as
retiring them. Fixes are landing as `<operator>/bfix-B*` PRs against
`<your-org>/nexus-code` `dev`. The next meta-review should de-dup against
that backlog rather than re-rank it.
