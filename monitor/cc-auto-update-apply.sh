#!/usr/bin/env bash
# monitor/cc-auto-update-apply.sh — deterministic executor for the
# autonomous cc-update routine's decision branches.
#
# The autonomous evaluator (spawned daily at the configured fire time by
# the watcher's cc_auto_update task — see monitor/watcher/_cc_auto_update.sh)
# does the JUDGMENT work of skills/nexus.cc-update/GUIDE.md Steps 1–4
# (changelog review, collision analysis, running the cc-harness gate).
# This script does the EXECUTION work, so every state-mutating step of
# the bump is deterministic, ordered, auditable, and testable:
#
#   safe            GUIDE Step 5 (operator-local pin bump + local
#                   install + watcher restart) AND Step 5b (the
#                   watchdog-observed orchestrator self-restart) —
#                   refused without gate evidence + the surfaces-clear
#                   attestation AND a per-surface evidence class
#                   (--surface-evidence 2a=… 2b=… 2c-paste=… 2c-vi=…
#                   2d=… 2e=…; an `empirical` class additionally requires
#                   a stated --negative-control) AND changelog
#                   completeness (--changelog-evidence, --changelog-ledger,
#                   --changelog-dispositioned <release>=<N> for EVERY
#                   release in the delta — the delta being what the npm
#                   REGISTRY publishes in (installed, candidate], with N
#                   checked against the entry count derived from the
#                   fetched changelog, and a published release with no
#                   changelog section refused as OPAQUE, exit 8).
#                   THE ONLY PATH THAT WRITES THE PIN.
#                   --no-restart: pin + install + verify, then STOP — no
#                   watcher restart, no orchestrator hand-off; the
#                   deployment gate is SKIPPED (its arms guard restarts)
#                   and a restart-hold (until_version=<candidate>) is
#                   written so the reconcile does not re-fire the
#                   hand-off. --no-orchestrator-restart: pin + install +
#                   watcher restart, then STOP before the session-pin
#                   pre-flight; hold written likewise. Release either
#                   hold with `unhold` (your-org/nexus-code#1425, #1438).
#   compat-pr auto  rule 4: check for an existing open compat PR on the
#                   nexus-code repo; comment findings on it (rc 0), or
#                   report none-found (rc 10 — the evaluator then
#                   authors the fix and opens the PR itself) or
#                   ambiguity (rc 11 — the evaluator picks). NEVER
#                   bumps.
#   block           rule 5: record + notify; NEVER bumps.
#   record-outcome  audit-trail writer for outcomes this script cannot
#                   observe (e.g. the evaluator opened a compat PR).
#                   Writes decisions.tsv (append) AND last-eval (OVERWRITE
#                   — the watcher's Guard 4 input: candidate match +
#                   decision block|compat-pr-opened|compat-pr-commented
#                   SKIPS the next daily fire). PRINTS the row and the
#                   last-eval content it wrote, so nobody re-runs it to
#                   learn the rc (your-org/nexus-code#1211). Context
#                   guard: refuses (rc 40) when NEXUS_WORKER_WINDOW names
#                   an agent window OTHER than the evaluator's
#                   ($CC_AUTO_WINDOW); unset or the evaluator window
#                   writes; --allow-context is the deliberate override.
#                   The guard is on THIS VERB only — the internal callers
#                   (safe/block/compat-pr/restart-orchestrator/rollback)
#                   record from whatever context runs them, and the
#                   watcher's reconcile path inherits the env of whoever
#                   last restarted the watcher (measured: the evaluator's).
#   hold            write the durable restart-hold marker (nexus-code#513):
#                   the RUNNING watcher's reconcile honours it every tick,
#                   so a refused orchestrator restart STAYS refused.
#                   --reason required; --ttl-seconds / --until-version
#                   bound it. (The config `enabled` flag is read once at
#                   watcher startup and is NOT a hold.)
#   unhold          release the hold.
#   hold-status     print the hold and whether it is active (rc 0/1).
#
# Fail-safe contract: any guard failure, any step failure, any
# uncertainty → the pin is NOT advanced (or is rolled back), the
# orchestrator is NOT killed, and the failure is recorded loudly.
# Distinct exit codes let the evaluator branch precisely:
#
#   0   success (verb-specific)
#   2   usage / unknown verb
#   3   refused: gate evidence missing, stale, or not GREEN; the
#       --surfaces-clear attestation absent; the per-surface evidence
#       is missing/ill-formed (unknown class or surface key, a COMPOSITE
#       surface labelled as a whole instead of per sub-claim, `empirical`
#       without a negative control, `gate` for a surface no scenario in
#       the supplied gate log covers); or the changelog accounting is
#       incomplete (evidence missing/stale/not the candidate's, a release
#       in the delta with no disposition, N != M for a release, or an
#       entry absent from the ledger); or the npm REGISTRY document the
#       release set is derived from could not be fetched, is not a
#       packument, lists no versions, or does not list the candidate
#       (your-org/nexus-code#1007 — refused, never fallen back to the
#       changelog's own headers)
#   4   install failed (pin rolled back)
#   5   binary verification failed (pin rolled back)
#   6   watcher restart failed (pin + install stand; NO orchestrator kill)
#   7   another apply is already in flight (lock held)
#   8   refused: an OPAQUE release (your-org/nexus-code#1007). The registry
#       publishes a version inside (installed, candidate] that has NO
#       `## <version>` section in the changelog this run fetched. The
#       release set is derived from the REGISTRY precisely so this case
#       is NAMED instead of vanishing from M — 2.1.242 (2026-08-25) was
#       published, sectionless, and `dispositioned 406 of 406` read GREEN
#       over it. Distinct from 3 because nothing the evaluator supplies
#       can clear it: the evidence does not exist upstream. The daily
#       fire retries and clears when the section appears. BOUNDED, not
#       terminal: after GATE_DEFER_STREAK_CAP consecutive refusals on the
#       same opaque set (default 3, floor 2, `0` escalates at the floor)
#       this script escalates the operator itself — sandbox-notify plus a
#       comment on the cc-update tracking issue (or a filed issue on
#       $GATE_REPO when none is configured) naming the candidate and the
#       release(s) — and KEEPS refusing. Delay-then-surface, never
#       auto-proceed (operator directive 2026-09-10: a busy board may
#       delay an update, not prevent it).
#   9   refused: LIVE TREE DRIFT (your-org/nexus-code#1002) — the live binary
#       (`$CLAUDE_BIN --version`) does not report the EFFECTIVE pin (the
#       operator-local pin, else the package.json floor), or one of the two
#       could not be read. Asserted by `safe`, `block` and `compat-pr auto`
#       BEFORE any verdict is recorded, so a drifted tree can never carry a
#       verdict about a candidate: `safe` records `safe-refused` with a
#       `live-tree-drift` detail (the #1400 daily surfacing names it);
#       `block`/`compat-pr` record NO verdict at all — an audit-only
#       `live-tree-drift` row — so the next fire re-evaluates instead of
#       skipping a candidate whose verdict was never reached. Nothing is
#       applied. Remedy: monitor/install-claude-local.sh (reinstalls the
#       effective pin), confirm with `--version`, re-run the verb, and say
#       in the report that the drift happened and what caused it.
#   10  compat-pr: no existing open compat PR (caller must open one)
#   11  compat-pr: multiple open compat PRs (caller must pick + comment)
#   21  safe: bumped, orchestrator restart NOT handed off (session pin
#       stale/absent — a kill would cold-spawn and lose the conversation
#       context, so we do not even detach the restart). Foreground
#       pre-flight; the bump itself stands.
#   30  safe: DEFERRED by the deployment gate (nexus-code#512) — an open
#       PR touches the watcher restart path, or an open PR is under
#       active review (both PROXY arms, both bounded; the live-window
#       arms were removed 2026-09-12 — see the deployment-gate knob
#       block). NOTHING was applied; the safe-to-bump verdict is
#       recorded and the next daily fire retries. That is a complete
#       result ONLY BECAUSE THE DEFERRAL NAMES A HAZARD — see the
#       doctrine note on `_deployment_gate`. A 30 that repeats is not
#       a series of complete results; read `gate-defer-streak`.
#   31  safe: bumped + watcher restarted, but the POST-RESTART INVARIANT
#       was violated (survivors of the old watcher group, or duplicate
#       watcher groups). The orchestrator restart is NOT handed off into
#       a duplicated-watcher world; operator inspection required.
#   40  record-outcome: REFUSED by the context guard — NEXUS_WORKER_WINDOW
#       names an agent window other than the evaluator's, and
#       --allow-context was not given. NEITHER file was touched
#       (your-org/nexus-code#1211).
#   41  record-outcome: the write did NOT land — last-eval or the
#       decisions.tsv row is missing or disagrees with what was passed
#       (unwritable state dir, disk full). Not a success at rc 0 with a
#       silent `|| true` (#1211).
#
# `safe` no longer BLOCKS on the orchestrator idle-wait: after the bump
# (pin + install + watcher restart, all synchronous) it hands the
# idle-wait → context-preserving kill+respawn to a DETACHED background
# process (the `restart-orchestrator` verb, re-exec'd disowned) and
# RETURNS exit 0 promptly. This decouples the restart from the cc-update
# evaluator's hard 600s Bash-tool ceiling (the old in-foreground idle-wait
# was SIGTERMed mid-loop daily) AND lets the idle cap be raised freely.
# The one exception that stays foreground is the stale-pin pre-flight
# (exit 21) — a doomed restart is never even detached.
#
# The detached `restart-orchestrator` verb owns the bounded wait and the
# kill. Its own exit codes (recorded as audit rows + notify; the disowned
# caller's rc is not observed):
#   0   restart triggered — orchestrator killed for a context-preserving
#       respawn. Turn-boundary verdict (idle / autosuggest-only /
#       Monitor-handle working-background / working-self-paced /
#       idle-orphan-async — see _restart_eligible, nexus-code#514) →
#       outcome safe-bumped-restarted; idle-cap reached while POSITIVELY
#       busy → safe-bumped-restart-FORCED (operator decision: restart a
#       busy orchestrator anyway — the pinned session resumes from its
#       transcript, so a mid-turn kill only re-runs the interrupted turn,
#       repeating some tokens, never losing work).
#   21  ABORT — session pin went stale/absent (or transcript missing)
#       before the kill; a kill now would cold-spawn. No kill.
#   22  ABORT — watchdog template missing / spawn failed / never armed.
#       No kill (never kill the orchestrator unwatched).
#   23  ABORT — orchestrator window unresolved, or pane-state UNREADABLE
#       (no parseable verdict), or the wait hit its cap having seen
#       NOTHING but `state=empty` (the classifier never positively
#       resolved the pane — force-killing on a verdict that was never
#       established would kill an unknown; nexus-code#514). No kill.
#       (state=empty remains a VALID not-idle verdict — claude alive,
#       renderer blip — it keeps waiting; only an ALL-empty wait refuses
#       the force at the cap.)
#   23  (also) ABORT — the wait hit its cap with the pane showing a LOGIN IN
#       PROGRESS (`auth=login`, your-org/nexus-code#1518): a login is not
#       "busy", forcing through it is the interruption #1518 prevents, and the
#       respawned session would still need the login. No kill; outcome row
#       `safe-bumped-restart-aborted auth-login-at-cap`; the reconcile retries.
#       Only while `monitor.watcher.auth_hold.enabled` is true — its escape
#       clock is what bounds an abandoned login; with the hold off the cap
#       FORCES as before (w239sk F3).
#   23  (also) REFUSED — restart-orchestrator found a DUPLICATE CLAIMANT: the
#       base pane pid changed under the wait (outcome row
#       `safe-bumped-restart-refused duplicate-claimant`, your-org/nexus-code#1438).
#   24  (also) REFUSED — restart-orchestrator single-flight: another claimant
#       holds the restart lock or a live claimant is mid-restart (#1400).
#       The OUTCOME rows are distinct; the codes are shared with the rows
#       above, so read the row, not only the code.
#   25  ABORT — restart-hold active (nexus-code#513), or this detached
#       restart was SIGTERMed and wrote the hold itself so the reconcile
#       does not auto-refire the abort. No kill. Release: `unhold`.
#   24  NO-OP — the orchestrator already respawned onto the candidate on
#       its own (a candidate-stamped record exists in the pinned
#       transcript, e.g. the version-aware watcher self-restart). Killing
#       would be needless. No kill.
#
# On any non-0 restart outcome the version bump itself is COMPLETE (new
# workers get the candidate); only the running orchestrator stays on the
# old binary. The evaluator/watchdog surfaces that version-split.
#
# Restart-outcome surfacing (your-org/nexus-code#511). The detached child's
# terminal code lands in a log nothing reads, so `restart-orchestrator`
# also writes `$AUTO_DIR/restart-outcome` — the SINGLE latest-state marker
# (`outcome=/code=/cause=/candidate=/ts=/abort_streak=`) — on every exit
# path. A caller reads the real restart outcome from that one file instead
# of `tail`-ing the append-only decisions.tsv (which two evaluators did and
# both miscounted, publishing "17"/"12" for a true 468). `abort_streak`
# counts CONSECUTIVE same-cause aborts; crossing a threshold emits a
# distinct `restart-abort-escalation` audit row + notify so a stuck restart
# is caught on day 1, not day 9. In the INLINE seam (CC_AUTO_RESTART_INLINE,
# below) `safe` runs the restart synchronously and PROPAGATES the child's
# non-zero abort code — so a synchronous caller can tell a bump whose
# restart succeeded from one whose restart aborted. The DETACHED (live) path
# still exits 0 at hand-off, because the outcome is a future event there.
#
# Test injection (all default to the live mechanism):
#   CC_AUTO_INSTALL_CMD           monitor/install-claude-local.sh
#   CC_AUTO_WATCHER_RESTART_CMD   monitor/svc.sh restart watcher
#   CC_AUTO_SPAWN_CMD             monitor/spawn-worker.sh
#   CC_AUTO_PANE_STATE_CMD        monitor/pane-state.sh
#   CC_AUTO_CLAUDE_BIN            node_modules/.bin/claude
#   CC_AUTO_TMUX                  tmux
#   CC_AUTO_GH                    gh
#   CC_AUTO_MINT_CMD              monitor/mint-token.sh
#   CC_AUTO_PROJECTS_DIR          ~/.claude/projects
#   CC_AUTO_GATE_PR_CMD           the deployment gate's restart-path PR
#                                 probe (number<TAB>path lines)
#   CC_AUTO_GATE_PR_ACTIVITY_CMD  the deployment gate's active-review
#                                 probe (number<TAB>updated-at lines).
#                                 A SEPARATE seam from the one above on
#                                 purpose: a reader that tolerated a
#                                 missing field on the other probe's
#                                 lines would be a permissive default
#                                 arm, which is the #1113 defect itself.
#   CC_AUTO_CHANGELOG_FETCH_CMD   the upstream CHANGELOG.md fetch (default:
#                                 `gh api` with a minted token; see
#                                 `_cl_fetch_changelog`)
#   CC_AUTO_REGISTRY_FETCH_CMD    the npm registry packument fetch the
#                                 changelog release set is derived from
#                                 (default: `curl` against
#                                 $MONITOR_CC_UPDATE_REGISTRY/<package>
#                                 with the abbreviated-packument Accept
#                                 header; see `_cl_fetch_registry`).
#                                 A SEPARATE seam from the changelog fetch
#                                 on purpose: the two documents answer
#                                 different questions (what SHIPPED vs
#                                 what was WRITTEN about it), and a test
#                                 must be able to fail one while the other
#                                 answers — your-org/nexus-code#1007.
#   CC_AUTO_TRACKING_ISSUE        the cc-update tracking issue as
#                                 `owner/repo#N` (default: config
#                                 monitor.cc_auto_update.tracking_issue,
#                                 resolved through monitor/issue-ref.sh —
#                                 a bare number is REFUSED, #866)
#   CC_AUTO_ISSUE_COMMENT_CMD     the tracking-issue comment post for the
#                                 bounded opaque-release escalation; receives
#                                 <repo> <issue> <body-file> (default: minted
#                                 token + `gh issue comment`)
#   CC_AUTO_GATE_ISSUE_CMD        the issue create/adopt used by the
#                                 deployment gate's defect filer AND by the
#                                 opaque-release escalation when no tracking
#                                 issue is configured; receives
#                                 <key> <title> <body-file>
#   CC_AUTO_RESTART_INLINE        when 1, `safe` runs the restart hand-off
#                                 synchronously in-process (test seam)
#                                 instead of detaching it — so a test can
#                                 assert the full chain deterministically.
#   NEXUS_STATE_DIR / NEXUS_CC_LOCAL_PIN  (the _cc-version.sh overrides)
#
# Never uses pkill -f / pgrep -f / killall (sandbox mass-kill hazard;
# see monitor/cc-harness/lint-no-mass-kill.sh). The only kill issued is
# `tmux kill-window` on the coordinator window, per GUIDE Step 5b.

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Absolute path to THIS script — used for the detached `restart-orchestrator`
# re-exec, which must not depend on $0 being absolute or on cwd.
SELF_PATH="$_self_dir/$(basename "${BASH_SOURCE[0]}")"
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$_self_dir/.." && pwd)}"
STATE_DIR="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"
# Window-selection capture bookkeeping for `restart-orchestrator` (your-org/
# nexus-code#1528, w240sk F1): GLOBAL so the EXIT trap can read them after
# any exit — a per-exit `rm` list missed the TERM trap, the EXIT trap itself
# and a `set -u` death. The kill line sets the flag; the EXIT trap drops the
# capture on every exit that did not reach it.
_SEL_CAPTURE_FILE=""
_SEL_KILL_REACHED=0
AUTO_DIR="$STATE_DIR/cc-auto-update"
APPLY_LOG="$AUTO_DIR/apply.log"

# Shared helpers: the effective-version resolver + pin writer, the
# key=value field parser, and the audit-row appender. All three modules
# are side-effect-free on source.
# shellcheck source=_cc-version.sh
source "$_self_dir/_cc-version.sh"
# shellcheck source=watcher/_cc_update.sh
source "$_self_dir/watcher/_cc_update.sh"
# shellcheck source=watcher/_cc_auto_update.sh
source "$_self_dir/watcher/_cc_auto_update.sh"
# `_ensure_service_log` (your-org/nexus-code#484).
# shellcheck source=_log-mode.sh
source "$_self_dir/_log-mode.sh"
# `_clone_drift_probe` / `_clone_drift_field` — the deployment gate's
# staleness measurement, SHARED with the watcher's clone-drift detector
# rather than re-implemented (your-org/nexus-code#754). Side-effect-free
# on source: a sourced-guard plus function definitions, nothing else.
# shellcheck source=watcher/_clone_drift.sh
source "$_self_dir/watcher/_clone_drift.sh"
# `nexus_integration_branch` — the ONE resolver for the branch merged
# fixes land on (your-org/nexus-code#763). See `_gate_integration_branch`
# below for why this gate must not resolve it on its own.
# shellcheck source=_integration_branch.sh
source "$_self_dir/_integration_branch.sh"
# `bk_is_transient_window_name` + `bk_pane_asserts_dead` — the deployment
# gate's board RECORD (your-org/nexus-code#1113). The per-window state
# classification is deliberately the SHARED primitive rather than a third
# hand-rolled state list: #771 already settled which of the two default-deny
# duals answers "is anybody still on this?", and a copy here would drift from
# it silently. Since 2026-09-12 the classification is AUDIT-ONLY — the board
# arms no longer veto (operator decision; see the deployment-gate knob block
# below) — but the row a later reader reconstructs a fire from still names
# every live window and what it read. Pure functions, no top-level side
# effects.
# shellcheck source=_bookkeeping.sh
source "$_self_dir/_bookkeeping.sh"
# Window-selection capture across the orchestrator restart (your-org/nexus-code#1528):
# `tmux_selection_capture` / `tmux_selection_note_post_kill`, consumed by the
# restore in `monitor/watcher/_respawn.sh` at the single window-creation site.
# shellcheck source=_tmux-window.sh
source "$_self_dir/_tmux-window.sh"

PACKAGE="${MONITOR_CC_UPDATE_PACKAGE:-@anthropic-ai/claude-code}"
COMPAT_REPO="${CC_AUTO_COMPAT_REPO:-your-org/nexus-code}"
# Resolve the orchestrator window NAME the same way launcher.sh:82 and
# spawn-fresh-orchestrator.sh do: CC_AUTO_TARGET_WINDOW → MONITOR_TARGET env →
# config `monitor.target_window` → literal `orchestrator`. The config leg is
# load-bearing: nexuses that set `monitor.target_window: claude` (the common
# case) name the orchestrator window `claude`, and a bare `orchestrator`
# default never resolves — the detached restart aborts every fire and the
# workspace stays version-split after an otherwise-successful bump (observed on
# 2.1.173 and 2.1.199). MONITOR_TARGET is usually unset in the detached
# restart's env, so consulting the config here is what makes it match.
TARGET_WINDOW="${CC_AUTO_TARGET_WINDOW:-${MONITOR_TARGET:-$("$NEXUS_ROOT/config/load.sh" monitor.target_window orchestrator 2>/dev/null || echo orchestrator)}}"
WATCHDOG_WINDOW="${CC_AUTO_WATCHDOG_WINDOW:-cc-restart-watchdog}"

# ---- deployment-gate knobs (your-org/nexus-code#512) ----------------------
# The release gate asks "is this Claude Code binary safe?"; the deployment
# gate asks "is this nexus in a state where restarting the watcher is safe
# RIGHT NOW?" — the question the 2026-07-10 incident showed nobody asking.
#
# THE BOARD ARMS ARE GONE (operator decision, 2026-09-12). Three arms used to
# live here: a live-window COUNT above `max_live_windows` deferred; any live
# agent window not POSITIVELY asserting it was dead deferred (board-not-quiet,
# your-org/nexus-code#1113); and a board that could not be enumerated deferred
# (board-enumeration-failed). The GUIDE held their removal as "requiring a
# fresh operator go-ahead". The operator gave it, in these words:
#
#     "a cc-update will not kill the worker, and if they, for whatever
#      reason, would crash, then the orchestrator can continue them with no
#      context lost."
#
# THE PREMISE WAS MEASURED BEFORE THE ARMS WERE REMOVED, not taken on faith
# (w239 D13, 2026-09-12, at 8d0cff30). (1) Every kill primitive on the restart
# path was enumerated: the watcher is reaped BY PROCESS GROUP behind an
# argv-identity check that REFUSES a group holding no watcher member
# (`_watcher_reap_group` rc 2 — measured against a worker pane's own pgid);
# the orchestrator is killed BY WINDOW NAME after an exact-name index
# resolution and a baseline pane-pid re-read; nothing on the path selects a
# worker. On a private tmux server holding worker-shaped windows,
# `restart-orchestrator` removed exactly the orchestrator window and every
# worker window kept its window id, its pane pid and its child process;
# `launcher.sh --replace` (what `svc.sh restart watcher` runs) did the same.
# (2) `spawn-worker.sh --resume <sid>` is the canonical respawn and was
# driven end-to-end against a stub claude recording its argv: the window came
# back under its own name, in the session's workdir, with `--resume <sid>` and
# the worker env exports. WHAT THAT DOES NOT PROVE, and is not claimed: that
# Claude Code restores the conversation — that rests on Claude Code's own
# `--resume` semantics — and an interrupted turn's UNPERSISTED in-flight work
# is re-derived by the continuation nudge, not restored.
#
# ONE RESIDUAL, NAMED SO IT IS NOT REDISCOVERED AS A SURPRISE: tmux 2.6
# resolves `-t <name>` by PREFIX when no exact-named window exists (measured:
# with `orchestrator` gone, `kill-window -t orchestrator` killed
# `orchestrator-sk`). The apply path is guarded twice — the exact-name index
# resolution aborts when the window is absent, and the baseline pane-pid
# re-read REFUSES when the name now answers with a different pid — so it
# reaches a worker only if the orchestrator window vanishes mid-restart AND a
# worker is named `<target>*` AND the pane-pid guard disarmed. ID-targeting
# the kill would close it; that is a hardening item, not part of this gate.
#
# So the board is still ENUMERATED AND RECORDED in every apply record
# (`live_windows=`, `unquiet_windows=[…]`), because it is the evidence a
# post-hoc reader needs to ask "was anyone mid-task when this fired?" — but
# it vetoes nothing. `monitor.cc_auto_update.max_live_windows` and
# CC_AUTO_MAX_LIVE_WINDOWS are therefore NOT READ any more; a value in
# nexus.yml is inert, and config/nexus.example.yml says so.
#
# Window names that are infrastructure, not agents (CSV; the orchestrator
# TARGET_WINDOW, the evaluator window and the restart watchdog are always
# exempt on top of these). Shapes the RECORDED count only.
GATE_WINDOW_EXEMPT="${CC_AUTO_GATE_WINDOW_EXEMPT:-services}"
# Repo whose open PRs are checked for restart-path collisions, and the
# restart-path file set (CSV). An open PR touching any of these means the
# restart mechanics are KNOWN to be under repair — defer the apply.
GATE_REPO="${CC_AUTO_GATE_REPO:-${CC_AUTO_COMPAT_REPO:-your-org/nexus-code}}"
GATE_RESTART_PATHS="${CC_AUTO_GATE_RESTART_PATHS:-monitor/watcher/launcher.sh,monitor/watcher/main.sh,monitor/revive-watcher.sh,monitor/svc.sh,monitor/watcher/_version_restart.sh}"
# ---- #1113: the two inputs that are ORTHOGONAL to the path list ----------
# GATE_RESTART_PATHS above is a PROXY, and it sits inside the gate whose
# whole job is deciding whether a restart is safe. The hazard is not "the
# restart mechanics are under repair"; it is restarting anything while
# agents hold IN-FLIGHT STATE — a skeptic verifying a delta at a pinned
# ref, a worker mid-write, a reviewer holding an enumeration it cannot
# rebuild. A PR can carry every one of those and touch none of the five
# named files. Measured 2026-08-28 ~04:20 PT during the 2.1.250
# evaluation: six live agent windows, three open MERGEABLE PRs with a
# skeptic verifying at that moment, ZERO restart-path hits, live windows
# 6 < max 8 — the gate would have CLEARED. It did not fire only because
# the candidate was red for an unrelated reason and the operator had
# placed a manual hold, and neither of those is a mechanism.
#
# How recently an open PR was touched before it counts as under active
# review. Kept SHORT on purpose: the gate fires daily at ~04:00, so a
# window long enough to span the previous evening would never clear and
# an inert routine is its own silent failure (which is why the repeated
# deferral is surfaced — see GATE_DEFER_STREAK_ALERT).
GATE_PR_ACTIVE_SECONDS="${CC_AUTO_GATE_PR_ACTIVE_SECONDS:-$("$NEXUS_ROOT/config/load.sh" monitor.cc_auto_update.pr_active_seconds 7200 2>/dev/null || echo 7200)}"
[[ "$GATE_PR_ACTIVE_SECONDS" =~ ^[0-9]+$ ]] || GATE_PR_ACTIVE_SECONDS=7200
# THE RESTART-PATH ARM HAS ITS OWN, MUCH LONGER, RECENCY BOUND
# (your-org/nexus-code#1414). Arm 2 selected on an exact path match with no
# recency at all, so a stalled cosmetic PR on monitor/svc.sh (updated 5.9
# days earlier, +8/-2 in a display-URL builder) blocked a fully-evidenced
# bump FOREVER while arm 3 — the broader arm, twelve lines down — aged the
# same PR out correctly. "Under repair" is a claim about ACTIVITY, not
# existence: a restart-path PR untouched for this long is stalled, and a
# gate with no exit condition is its own silent failure. Independently
# tunable from GATE_PR_ACTIVE_SECONDS on purpose — a restart-path PR IS
# categorically more dangerous (#503: a restart decapitated the WATCHER —
# leader dead, its loop orphaned beside the replacement — while 15 agents were
# mid-flight; no agent was killed, but two watcher trees raced monitor/.state),
# so its window is a week, not two hours. Fail-closed on missing activity data: a hit
# whose age cannot be established still defers.
GATE_RESTART_PR_ACTIVE_SECONDS="${CC_AUTO_GATE_RESTART_PR_ACTIVE_SECONDS:-$("$NEXUS_ROOT/config/load.sh" monitor.cc_auto_update.restart_pr_active_seconds 604800 2>/dev/null || echo 604800)}"
[[ "$GATE_RESTART_PR_ACTIVE_SECONDS" =~ ^[0-9]+$ ]] || GATE_RESTART_PR_ACTIVE_SECONDS=604800
# Consecutive deferred fires after which the operator is told the routine
# has stopped applying. A gate that never clears is indistinguishable
# from a gate that is not there, and only the second one is loud.
GATE_DEFER_STREAK_ALERT="${CC_AUTO_GATE_DEFER_STREAK_ALERT:-3}"
[[ "$GATE_DEFER_STREAK_ALERT" =~ ^[0-9]+$ && "$GATE_DEFER_STREAK_ALERT" -gt 0 ]] \
    || GATE_DEFER_STREAK_ALERT=3

# BOUNDED DEFERRAL — the operator's principle, your-org/nexus-code#1492 and
# the 2026-09-10 restatement: "a very busy board should only DELAY the update
# and not PREVENT it."
#
# WHY A BOUND IS NEEDED AT ALL, from this nexus's own ledger. Over the whole
# of monitor/.state/cc-auto-update/decisions.tsv (253 rows, 2026-06-16 ..
# 2026-09-09) there are 10 `safe-deferred` rows, and they are spread across
# FOUR different arms: restart-path PR 5, live-window COUNT 2, PR-under-
# active-review 2, board-not-quiet 1. The three most recent fires deferred on
# three DIFFERENT arms. Each arm is individually correct; their CONJUNCTION,
# sampled once a day at a fixed hour on a board that is busy on some axis
# nearly always, is a veto no single arm's author intended and that no single
# audit row reveals. Fixing the arm that fired last time is therefore not a
# fix — #1492 fixed the 2026-09-08 arm and 2026-09-09 deferred on another.
#
# WHAT IS AND IS NOT OVERRIDABLE. The override is OPT-IN PER ARM and the
# default is DENY, so an arm added later is non-overridable until its author
# says otherwise. Both remaining arms — restart-path PR and PR-under-active-
# review — are PROXIES (each admits it in its own comment; neither observes a
# worker) and both opt in.
#
# HISTORY, so the shape is not re-derived wrong: until 2026-09-12 the line ran
# between these proxy arms and two DIRECT arms (board-not-quiet,
# board-enumeration-failed) that were never overridable and ran LAST, on the
# argument in `cmd_rollback`'s header that rollback cannot restore a killed
# agent's context. The operator then removed the direct arms outright (the
# decision and its measured premise are in the knob block above), so today an
# expired proxy veto is followed by no further arm and the gate CLEARS. The
# board is still enumerated and recorded on the way out.
#
# AN OVERRIDE STILL MEANS "THIS ARM'S VETO HAS EXPIRED", NEVER "PROCEED". It
# returns 0 so evaluation CONTINUES into whatever arms remain, so no SAFE arm
# precedes a DENY arm that could fire on the same input (the arm-order rule
# in CLAUDE.md). That no arm currently follows the proxies is a fact about
# today's arm list, not a change to the contract.
# CALIBRATION — THE CAP IS ITS OWN CONSTANT, WITH A FLOOR.
#
# Two failed shapes preceded this one and both are worth keeping, because the
# number is the genuinely hard part and each failure sits at an opposite end:
#
#   cap = 5 (a hunch)      -> UNREACHABLE. Recorded streaks are 1,1,2,2,3,3,4
#                             (max 4) over 253 rows and the longest span is 3
#                             days, so the bound never fired — a mitigation
#                             that cannot fire, which is the class it exists
#                             to close (w231sk round 1, F4).
#   cap = $ALERT (a tie)   -> COLLAPSIBLE TO ZERO DELAY. The alert is a
#                             NOTIFICATION threshold; setting
#                             CC_AUTO_GATE_DEFER_STREAK_ALERT=1 to hear about
#                             every deferral drove the cap to 1 and expired
#                             every proxy veto on its FIRST deferral
#                             (w231sk round 2, R1 — measured, not argued).
#
# THE LESSON IS THE OWNERSHIP, NOT THE ARITHMETIC. A SAFETY threshold and a
# NOISE threshold have different owners and different reasons to change, so
# deriving one from the other means every future notification-tuning silently
# retunes a veto — and the operator action that triggers it is ASKING FOR MORE
# INFORMATION, which is the worst possible trigger for a safety change.
#
# So: an independent constant, DEFAULT 3 (calibrated against the distribution
# above — above the observed max of the healthy regime, reachable by the
# streaks that actually occur), and a FLOOR that no configuration can go under.
# The floor is 2 because a cap of 1 overrides on the first deferral, i.e. zero
# delay, and the operator's principle is DELAY, not "never veto".
#
# THE FLOOR CLAMPS AND SAYS SO — it is not silent. The earlier rejection of a
# clamp ("it would silently disagree with the operator's configured value") was
# broader than its evidence: that defect belongs to a SILENT clamp. One that
# announces itself in the log AND in the audit row is not that defect, and the
# alternative — honouring a value that disables the mechanism — is worse.
#
# THE CAP VALUE IS A POLICY PREFERENCE AND WAS CHOSEN BY THE OPERATOR, not
# defaulted into place. Surfaced as a choice on your-org/nexus-code#1507 and
# agreed 2026-09-10 (operator, "cap 3 sounds good"). The sentence agreed to, which
# is the thing to re-derive against rather than the integer:
#
#     "about three days of a busy board is enough delay before we update anyway"
#
# So 3 is a DECISION with an owner and a date, not a measurement and not a
# convention. If the cadence of the routine changes, or the board's character
# changes, that sentence is what has to be re-agreed — the number follows from
# it. Do not re-derive 3 from the streak distribution alone and conclude it is
# settled: the distribution says which values are REACHABLE, the operator says
# which is WANTED.
GATE_DEFER_STREAK_CAP_FLOOR=2
GATE_DEFER_STREAK_CAP="${CC_AUTO_GATE_DEFER_STREAK_CAP:-$("$NEXUS_ROOT/config/load.sh" monitor.cc_auto_update.defer_streak_cap 3 2>/dev/null || echo 3)}"
[[ "$GATE_DEFER_STREAK_CAP" =~ ^[0-9]+$ ]] || GATE_DEFER_STREAK_CAP=3
# ZERO STILL MEANS "STREAK BOUND DISABLED" — the floor applies to values that
# ARM the bound, not to the one that turns it off. Caught by O5 the moment the
# floor was added: a blanket `< FLOOR` clamp silently converted `cap=0` from
# "disabled" into "cap 2", which is the opposite of what the caller asked for
# and exactly the silent-disagreement defect the loud clamp exists to avoid.
# The age bound still applies when the streak bound is off, so 0 is not "no
# bound at all".
GATE_DEFER_STREAK_CAP_CLAMPED=0
if (( GATE_DEFER_STREAK_CAP >= 1 && GATE_DEFER_STREAK_CAP < GATE_DEFER_STREAK_CAP_FLOOR )); then
    GATE_DEFER_STREAK_CAP_CLAMPED=1
    GATE_DEFER_STREAK_CAP="$GATE_DEFER_STREAK_CAP_FLOOR"
fi
# THE SAME CAP BOUNDS THE OPAQUE-RELEASE REFUSAL (your-org/nexus-code#1007,
# orchestrator follow-up 2026-09-12). Exit 8 refuses a bump whose delta holds
# a published release with no changelog section, and on its own that refusal
# is TERMINAL — a permanently sectionless release would pin the fleet forever,
# which contradicts the directive above ("DELAY the update, not PREVENT it").
# So after this many CONSECUTIVE opaque refusals on the SAME opaque set the
# operator is ESCALATED (notify + a comment on the cc-update tracking issue),
# and the refusal continues: delay-then-SURFACE, never delay-then-forget, and
# never auto-proceed. It reuses THIS knob rather than a sibling because it
# expresses the same operator sentence — "about three days blocked is enough
# delay before we act" — and the act here is telling a human, which is the
# only act that can clear an absence of evidence. It also inherits the floor
# and the loud clamp. ONE deliberate divergence: `0` disables the OVERRIDE
# bound above, but it cannot disable the ESCALATION — a refusal nobody is
# told about is the forbidden outcome — so `0` escalates at the floor.
OPAQUE_ESCALATE_AT="$GATE_DEFER_STREAK_CAP"
(( OPAQUE_ESCALATE_AT >= 1 )) || OPAQUE_ESCALATE_AT="$GATE_DEFER_STREAK_CAP_FLOOR"
# The age bound is an INDEPENDENT second bound, not a restatement of the cap:
# it expresses the same "about three days blocked" in TIME, so a fire cadence
# slower than daily cannot make the bound unreachable. Keeping it independent
# is also what actually limits the damage when the cap is misconfigured high —
# credited here because an earlier draft credited observability instead, and
# the reason recorded beside a decision is what the next maintainer relies on.
GATE_DEFER_MAX_AGE_SECONDS="${CC_AUTO_GATE_DEFER_MAX_AGE_SECONDS:-$("$NEXUS_ROOT/config/load.sh" monitor.cc_auto_update.defer_max_age_seconds 259200 2>/dev/null || echo 259200)}"
[[ "$GATE_DEFER_MAX_AGE_SECONDS" =~ ^[0-9]+$ ]] || GATE_DEFER_MAX_AGE_SECONDS=259200
# How long a filed instrument-failure defect suppresses a re-file for the same
# key (your-org/nexus-code#1492). This routine fires DAILY, so a filer with no
# cooldown opens a fresh issue every morning for one broken instrument — spam
# that trains the operator to ignore the exact channel the directive created.
# A week: long enough that a persistent blind spot is one issue with a rising
# repeat count, short enough that a defect fixed and re-broken is filed again.
GATE_DEFECT_REFILE_SECONDS="${CC_AUTO_GATE_DEFECT_REFILE_SECONDS:-$("$NEXUS_ROOT/config/load.sh" monitor.cc_auto_update.defect_refile_seconds 604800 2>/dev/null || echo 604800)}"
[[ "$GATE_DEFECT_REFILE_SECONDS" =~ ^[0-9]+$ ]] || GATE_DEFECT_REFILE_SECONDS=604800

INSTALL_CMD="${CC_AUTO_INSTALL_CMD:-$NEXUS_ROOT/monitor/install-claude-local.sh}"
SPAWN_CMD="${CC_AUTO_SPAWN_CMD:-$NEXUS_ROOT/monitor/spawn-worker.sh}"
PANE_STATE_CMD="${CC_AUTO_PANE_STATE_CMD:-$NEXUS_ROOT/monitor/pane-state.sh}"
CLAUDE_BIN="${CC_AUTO_CLAUDE_BIN:-$NEXUS_ROOT/node_modules/.bin/claude}"
TMUX_CMD="${CC_AUTO_TMUX:-tmux}"
GH_CMD="${CC_AUTO_GH:-gh}"
MINT_CMD="${CC_AUTO_MINT_CMD:-$NEXUS_ROOT/monitor/mint-token.sh}"
PROJECTS_DIR="${CC_AUTO_PROJECTS_DIR:-$HOME/.claude/projects}"

GATE_EVIDENCE_MAX_AGE="${CC_AUTO_GATE_EVIDENCE_MAX_AGE_SECONDS:-21600}"
# The changelog must have been fetched from source in THIS evaluation —
# same freshness contract as the gate log, for the same reason (the
# GUIDE's "re-fetch from source, never summarise from memory" rule is
# otherwise unobservable from here).
CHANGELOG_EVIDENCE_MAX_AGE="${CC_AUTO_CHANGELOG_EVIDENCE_MAX_AGE_SECONDS:-$GATE_EVIDENCE_MAX_AGE}"
# How many bytes of each changelog entry must appear verbatim in the
# ledger for that entry to count as dispositioned. Long enough to be
# distinctive (the shortest entry across the whole upstream changelog is
# 14 chars; a prefix is used, so short entries match in full).
CHANGELOG_PROBE_CHARS="${CC_AUTO_CHANGELOG_PROBE_CHARS:-60}"
# Prefix used ONLY to classify a probe that already failed, so the refusal
# can distinguish "this entry is absent from the ledger" from "it is there
# and diverges after character K" (your-org/nexus-code#867). Never used to
# ACCEPT anything — a shorter prefix matching is not evidence of a
# disposition, only evidence about where the two texts part company. Kept
# well above the 14-char shortest upstream entry so it stays distinctive.
CHANGELOG_SHORT_PROBE_CHARS="${CC_AUTO_CHANGELOG_SHORT_PROBE_CHARS:-25}"
# Where this run READS the changelog from. Note the wording: reads from,
# not "the authoritative source". See the provenance note below — that
# distinction is the whole of it.
CHANGELOG_REPO="${CC_AUTO_CHANGELOG_REPO:-anthropics/claude-code}"
CHANGELOG_FETCH_CMD="${CC_AUTO_CHANGELOG_FETCH_CMD:-}"
# Where this run reads the npm REGISTRY from (your-org/nexus-code#1007).
# The changelog's RELEASE SET — which versions in (installed, candidate]
# owe a disposition — is what the registry PUBLISHES, never the
# changelog's own `## <ver>` headers: a release that publishes no section
# was invisible to a header-derived set, and `dispositioned N of M` read
# GREEN over it (2.1.242, 2026-08-25). Same base knob as the watcher's
# daily `latest` probe in monitor/watcher/_cc_update.sh, so one override
# moves both. A DIRECT fetch, never `npm view`: a bare `npm view` is
# cache-servable and served a stale `latest` to two independent
# evaluators on the same day (#1007) — a release set whose authority is a
# cache is the same shape as one whose authority is a header.
REGISTRY_BASE="${MONITOR_CC_UPDATE_REGISTRY:-https://registry.npmjs.org}"
REGISTRY_FETCH_CMD="${CC_AUTO_REGISTRY_FETCH_CMD:-}"
# The abbreviated packument for this package measured 474 KB / 513
# versions at 0.05 s on 2026-09-12; the bound is for a hung registry,
# not a slow one.
REGISTRY_TIMEOUT="${CC_AUTO_REGISTRY_TIMEOUT_SECONDS:-60}"

# ---- PROVENANCE IS NOT ESTABLISHED, AND THIS SCRIPT DOES NOT CLAIM IT --
#
# Read this before adding a check that "closes" the changelog source.
#
# The completeness rule below counts entries and demands a disposition
# for each. A natural next thought is that the counts are therefore
# upstream-authoritative. THEY ARE NOT, and three consecutive attempts to
# make them so failed in three different ways, each one a door left open
# beside the door just shut:
#
#   round 3 — trusted `--changelog-evidence`, a caller-supplied FILE.
#             Truncating it (19 entries -> 5) was accepted at rc 0.
#   round 4 — re-fetched via `gh`, so the file no longer decided M. But
#             CC_AUTO_CHANGELOG_FETCH_CMD is read from the caller's ENV;
#             pointing it at a truncated copy was accepted at rc 0.
#   round 5 — enumerated the four source-affecting env vars and labelled
#             the summary OVERRIDDEN when any was set. But GH_CMD is the
#             bare name `gh`, resolved through PATH: a fake `gh` earlier
#             in PATH was accepted at rc 0, with the summary printing
#             "M from a live upstream fetch" and no warning at all.
#
# The pattern is not three bugs. It is one category error: this script
# runs the fetch as a SUBPROCESS, and a caller who controls the
# environment controls subprocess resolution — env, PATH, cwd, the
# filesystem. You cannot enumerate the ways a caller reaches a
# subprocess, and each enumeration produces a summary line asserting a
# provenance the next seam quietly falsifies. A false assurance is worse
# than none: it is what the following round quotes as evidence.
#
# So the claim is DROPPED rather than defended. This script prints what
# it can actually prove — that M was counted, and every entry
# dispositioned, against the changelog THIS RUN READ — and says nothing
# about where those bytes came from. No `_cl_provenance`, no override
# enumeration, no WARN that goes quiet on the door nobody thought of.
#
# WHY THAT IS ACCEPTABLE, stated so nobody re-litigates it silently. The
# threat this check was built for is a SELF-DECEIVING evaluator: the
# 2.1.224 round asserted "both releases read in full" and left nine
# entries undispositioned, believing it had read them. Against that, a
# ledger demanding every entry verbatim works regardless of provenance.
# It is NOT built for a deliberately adversarial caller, and could not
# be: that caller already owns the bump path outright — CC_AUTO_INSTALL_CMD
# alone decides which bytes get installed, whatever the changelog says.
# Hardening the changelog source while the install command stays wide
# open would be theatre.
#
# If provenance ever must be earned, the honest way is to verify the
# BYTES against something the caller does not control — a digest or
# signature published independently of the fetch path — not to block one
# more door. Upstream publishes no such digest for CHANGELOG.md today,
# which is precisely why this says nothing instead.
IDLE_WAIT="${CC_AUTO_IDLE_WAIT_SECONDS:-900}"
# The login veto's BOUND lives in the watcher's auth hold (#1518): its escape
# clock (`monitor.watcher.auth_hold.escape_after_seconds`, ~1 h) is what turns
# an abandoned login back into a plain boundary. With the hold DISABLED nothing
# bounds a login frame, so an `auth=login` pane at the cap must fall back to
# the pre-existing FORCE rather than abort forever (w239sk F3). Same knob and
# default as _config.sh:426, env override honoured.
AUTH_HOLD_ENABLED="${MONITOR_AUTH_HOLD_ENABLED:-$("$NEXUS_ROOT/config/load.sh" monitor.watcher.auth_hold.enabled true 2>/dev/null || echo true)}"
# _auth_hold_knob_on — rc 0 iff the hold is ENABLED, with the SAME spellings
# `_auth_hold_active` (monitor/watcher/_auth_hold.sh) treats as off. A bare
# `== true` here disagreed with the hold on `1`/`yes`/`on`/`TRUE`: the watcher
# held while this script FORCED through the login (w239sk delta residual).
_auth_hold_knob_on() {
    case "$AUTH_HOLD_ENABLED" in
        false|0|no|off|FALSE|NO|OFF) return 1 ;;
    esac
    return 0
}
IDLE_POLL="${CC_AUTO_IDLE_POLL_SECONDS:-15}"
ARM_WAIT="${CC_AUTO_ARM_WAIT_SECONDS:-600}"
ARM_POLL="${CC_AUTO_ARM_POLL_SECONDS:-5}"

_UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

note() {
    local ts
    ts=$(date -Is 2>/dev/null || echo unknown)
    printf '%s %s\n' "$ts" "$*"
    mkdir -p "$AUTO_DIR" 2>/dev/null || true
    # Explicit mode at creation (your-org/nexus-code#484). Idempotent, and
    # cheap enough to sit on the log path: two syscalls once the file exists.
    _ensure_service_log "$APPLY_LOG"
    printf '%s %s\n' "$ts" "$*" >> "$APPLY_LOG" 2>/dev/null || true
}

notify() {
    # `9>&-`: deny the restart-orchestrator single-flight lock fd to the
    # notifier (flock-fd class #494; a no-op for callers holding no fd 9).
    command -v sandbox-notify >/dev/null 2>&1 && sandbox-notify "$*" 9>&- || true
}

# record_outcome <candidate> <decision> [detail] — last-eval (the daily
# guard's awaiting-operator input) + the append-only audit row.
RECORD_OUTCOME_LAST_EVAL_OK=0
record_outcome() {
    local candidate="$1" decision="$2" detail="${3:-}"
    mkdir -p "$AUTO_DIR" 2>/dev/null || true
    local tmp="$AUTO_DIR/last-eval.tmp.$$"
    # Never fails the caller (every internal call site is on a path whose
    # own outcome matters more), but the verb below READS this flag so a
    # write that did not land is reported instead of swallowed (#1211).
    RECORD_OUTCOME_LAST_EVAL_OK=0
    if {
        printf 'candidate=%s\n' "$candidate"
        printf 'decision=%s\n'  "$decision"
        printf 'date=%s\n'      "$(date -Is 2>/dev/null || echo unknown)"
        printf 'detail=%s\n'    "$detail"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$AUTO_DIR/last-eval" 2>/dev/null; then
        RECORD_OUTCOME_LAST_EVAL_OK=1
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
    # your-org/nexus-code#1400: a safe-refused outcome used to notify nobody.
    # Count how many of the most recent safe-refused rows ALREADY carry this
    # detail BEFORE appending ours, so a repeat is named as such.
    local _same=0
    if [[ "$decision" == "safe-refused" && -r "$AUTO_DIR/decisions.tsv" ]]; then
        _same=$(awk -F'\t' -v d="$detail" '$3=="safe-refused"{r[++n]=$4} END{c=0; for(i=n;i>=1&&r[i]==d;i--)c++; print c+0}' "$AUTO_DIR/decisions.tsv" 2>/dev/null || echo 0)
        [[ "$_same" =~ ^[0-9]+$ ]] || _same=0
    fi
    _cc_auto_log_decision "$AUTO_DIR" "$candidate" "$decision" "$detail"
    if [[ "$decision" == "safe-refused" ]]; then
        if (( _same >= 1 )); then
            _cc_auto_log_decision "$AUTO_DIR" "$candidate" "safe-refused-repeat" "$detail same-reason-streak=$(( _same + 1 ))"
            notify "cc-auto-update: SAME safe-refused reason $(( _same + 1 )) fires running ($detail) for $candidate — a STANDING defect in the gate, not a transient tree state (#1400)"
        else
            notify "cc-auto-update: $candidate evaluated SAFE but NOT applied ($detail) — a defect in the gate, not the candidate; the pin stays stale until someone looks (#1400)"
        fi
    fi
}

usage() {
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

# ---- verb: safe ----------------------------------------------------------

# _slug <path> — Claude Code project-dir slug (every non-alphanumeric
# char → '-'; mirrors spawn-worker.sh's _resume_slug).
_slug() { printf '%s' "$1" | sed 's|[^a-zA-Z0-9]|-|g'; }

# _resolve_target_index <window> — resolve a tmux window NAME to its
# INDEX. `monitor/pane-state.sh` is INDEX-keyed; handing it a window
# *name* (the historical Step 5b bug — TARGET_WINDOW defaults to the
# name "orchestrator") makes it print a usage message to stderr and
# exit 2 with EMPTY stdout. The idle loop then parsed empty, never
# matched "idle", and silently deferred the restart for the full
# IDLE_WAIT — leaving the workspace version-split on EVERY auto-update
# (2026-06-16 live incident). Echoes the index on stdout; empty stdout
# (rc 0) when tmux is unavailable or the name has no live window — the
# caller treats empty as a hard, fail-loud error. A numeric argument
# is already an index and passes through untouched. First match wins;
# mirrors `_over_limit_resolve_window_index` in watcher/_over_limit.sh.
_resolve_target_index() {
    local name="$1"
    [[ "$name" =~ ^[0-9]+$ ]] && { printf '%s' "$name"; return 0; }
    command -v "$TMUX_CMD" >/dev/null 2>&1 || return 0
    # `9>&-`: deny the restart-orchestrator single-flight lock fd to the tmux
    # client (flock-fd class #494; no-op for callers that hold no fd 9).
    "$TMUX_CMD" list-windows -F '#{window_name}|#{window_index}' 2>/dev/null 9>&- \
        | awk -F'|' -v n="$name" '$1 == n { print $2; exit }'
}

# _restart_eligible <state> <raw_probe_line> — rc 0 iff the verdict is a
# TURN BOUNDARY, i.e. safe to kill for a context-preserving respawn.
#
# pane-state.sh can never emit a literal `idle` for an orchestrator that
# holds a Monitor handle (your-org/nexus-code#514): its refinement
# promotes an idle base verdict to `working-background` whenever mon>0,
# and the orchestrator permanently holds one (the watcher supervisor).
# Keying strictly on `idle` made the interlock structurally
# unsatisfiable — 7/7 recorded fires force-killed mid-turn at the cap.
#
# Every state below is a refinement of an IDLE BASE VERDICT (empty input
# row, no spinner — the turn has ended); what varies is only the pending
# WAKE mechanism, which any restart loses and the respawn + watcher
# nudge restore:
#   idle                nothing pending at all
#   autosuggest-only    idle; the input row is drawing a ghost
#   working-self-paced  between turns; a self-scheduled wakeup pends
#   idle-orphan-async   between turns; an EXTERNAL job (slurm, CI)
#                       pends — the job itself survives the kill
#   working-background  between turns — eligible in its Monitor-handle
#                       flavour (no `bg_cpu=`: self-waking, no live
#                       child), OR in its SHELL-driven flavour (`bg_cpu=`
#                       present) when the process-tree walk was reliable
#                       and EVERY background-shell root is quiescent
#                       (`bg_quiesce >= bg_shells`): a pure nexus protocol
#                       wait loop with nothing but shells and `sleep`
#                       under it, or a #1208-stale waiter. Any other
#                       shell-driven reading has, or may have, an
#                       in-flight child the kill would destroy: NOT
#                       eligible, keep waiting.
#
# COVERAGE BOUNDARY (w234sk F3). "Any other reading" means any other reading
# the process-tree walk can SEE, and the walk has two blind spots. It counts
# only SHELL children of claude as roots, so a non-shell direct child of
# claude is never looked at: an `exec <compute>` from a background command,
# or an MCP server, which looks identical. And shell-script work under a
# recognised wait root passes the descendant check. The `bg_quiesce` paragraph
# in pane-state.sh's header states both.
#
# WHY THE SECOND ARM EXISTS. The #514 fix assumed the orchestrator's
# watcher-supervisor Monitor lives inside claude's node process and so
# never produces `bg_cpu=`. On current builds a `command` Monitor runs as a
# real zsh child of claude (measured 2026-09-11, Claude Code 2.1.268), so
# between turns the orchestrator reads
#     state=working-background … bg_shells=1 bg_reliable=1 bg_cpu=2 …
#     bg_infra=0 … bg_cmd=zsh:until_…/watcher-supe…
# and the Monitor-handle arm is unreachable for it. The ledger agrees: no
# `safe-bumped-restarted` row has ever been written, and every handoff since
# 2026-08-06 forced at the cap with `last state=working-background`.
#
# ERROR DIRECTION. A field this line does not carry (an older pane-state with
# no `bg_quiesce=`), a non-numeric value, or `bg_reliable` other than 1 all
# read NOT eligible. So the arm can only fail toward the pre-existing
# behaviour: wait, then force at the cap.
#
# `auth=login` VETOES EVERY BOUNDARY VERDICT (w239: the #1518 login hold
# meeting the #1513 turn-boundary gate). pane-state.sh's emitter records that
# a live `/login` frame reaches `state=idle` via the heartbeat classification
# route — and `idle` is the first arm below. A kill there destroys the
# operator's login in progress and respawns a session that is STILL
# unauthenticated, so nothing is gained and the operator's work is lost. The
# login therefore wins: not eligible, keep waiting — and the cap ABORTS rather
# than forces (see the wait loop) WHILE THE AUTH HOLD IS ENABLED, because
# forcing is exactly the interruption the operator asked #1518 to prevent, and
# #1518's escape clock (~1 h) bounds how long a login can hold the pane. With
# the hold disabled that clock does not run, so the cap forces as it always
# did (w239sk F3). The label this keys on is emitted for every idle-based
# verdict — `idle`, `working-background`, `working-self-paced` — since w239sk
# F1 narrowed pane-state's exclusion to the generating states. `auth=expired` does NOT
# veto: that session is logged out and idle, a resume-from-transcript restart
# loses nothing, and the board state waits in the transcript. Keyed with the
# delimiter-anchored field reader, so `xauth=login` cannot match.
_restart_eligible() {
    local st="$1" raw="$2"
    [[ "$(_restart_line_field "$raw" auth)" == login ]] && return 1
    case "$st" in
        idle|autosuggest-only|working-self-paced|idle-orphan-async)
            return 0 ;;
        working-background)
            [[ "$raw" != *"bg_cpu="* ]] && return 0
            _restart_bg_all_quiescent "$raw"
            return $? ;;
    esac
    return 1
}

# _restart_line_field <line> <key> — the value of a whitespace-delimited
# `key=value` token, or nothing. Anchored on a delimiter so `bg_shells` can
# never match inside another key.
_restart_line_field() {
    local re="(^|[[:space:]])$2=([^[:space:]]*)"
    [[ "$1" =~ $re ]] && printf '%s' "${BASH_REMATCH[2]}"
}

# _restart_bg_all_quiescent <raw_probe_line> — rc 0 iff a reliable walk found
# at least one background-shell root and every one of them is quiescent.
_restart_bg_all_quiescent() {
    local raw="$1" shells rel q
    shells=$(_restart_line_field "$raw" bg_shells)
    rel=$(_restart_line_field "$raw" bg_reliable)
    q=$(_restart_line_field "$raw" bg_quiesce)
    [[ "$rel" == 1 && "$shells" =~ ^[0-9]+$ && "$q" =~ ^[0-9]+$ ]] || return 1
    (( shells >= 1 && q >= shells ))
}

# _check_gate_evidence <file> <candidate> — rc 0 iff the file exists, is
# fresh, names a GREEN gate, and mentions the candidate.
# ---- surface evidence: the labelling rule, enforced -----------------------
#
# THE DEFECT THIS CLOSES. A cc-update evaluation clears five collision
# surfaces (GUIDE 2a-2e). Historically it then passed a bare
# `--surfaces-clear` and wrote a report table labelling surfaces
# `(empirical)`. In five of six rounds at least one of those labels was
# false: the probe was REACHABILITY-ONLY — it could not distinguish the
# hazardous behaviour working from the hazardous behaviour absent — and
# the attestation laundered that into "I tested it".
#
# Two documented failure modes, both of which this check names:
#   * NO-OP PREFIX — the 2.1.216 / 2.1.222 VI-mode probe prefixed its
#     paste with `send-keys i BSpace` to force VI insert mode. The harness
#     booted panes in DEFAULT (emacs) mode THEN (it seeds `vim` since
#     #724), so the prefix typed `i` and deleted it. Proven by differential control: removing the line left
#     the probe passing identically.
#   * DEAD INSTRUMENTATION — the 2.1.218 turn-counter regex never matched
#     anything, yet every assertion built on it reported PASS.
#
# THE RULE. A surface may be labelled `empirical` ONLY if a differential
# or negative control showed the probe can go RED — break the assertion,
# or strip the behaviour under test, and observe a failure. Anything else
# is `reachability` (the hazardous input path cannot be reached here) or
# `source-inspection` (read the code, reasoned about it). `gate` means a
# cc-harness scenario covered it, and is the only class this script can
# verify on its own — so it does, against the gate log.
#
# COMPOSITE SURFACES — the 2.1.224 recurrence (6th in 7 rounds). A single
# GUIDE surface can cover more than one mechanism, and the classes above
# are per-KEY, so a surface whose halves have DIFFERENT evidence could
# still attest the stronger class for the whole of it. Surface 2c is
# exactly that: the paste-buffer DELIVERY path (genuinely driven every
# round, with a real control) and the VI-INSERT guard (never yet driven —
# the harness boots panes with no `editorMode` key at all, so the
# `i BSpace` prefix is a no-op there; proven by differential control,
# removing the line left the probe passing identically). Labelling the
# pair `empirical` let the undriven half ride on the driven half's
# evidence.
#
# TWO CORRECTIONS THIS CHECK MUST NOT REPEAT, both found by skeptics
# INSIDE the commits that added the check:
#
#  * The control offered for "VI mode is unreachable" was seeding
#    `editorMode: "vi"` and observing no indicator. That control CANNOT
#    FIRE: strings from the pinned 2.1.224 binary give the schema enum as
#    ["normal","vim"], the mode test as == "vim", and NO comparison
#    against "vi" anywhere; `.catch(void 0)` discards an out-of-enum
#    value silently. So seeding "vi" leaves the pane in `normal` on every
#    release, and no indicator could ever render. A probe that cannot
#    fail — offered as evidence, inside the change that refuses exactly
#    that. Third consecutive round for this class. If you seed, seed
#    "vim", and assert the indicator RENDERS before concluding anything
#    from its absence.
#  * `2c-vi` is NOT permanently inert, and THIS FILE IS SHARED ACROSS
#    OPERATORS. On one operator's host `editorMode: "vim"` is set in both
#    ~/.claude.json and ~/.claude/settings.json and ~90% of live agent
#    panes render `-- INSERT --`; on another it is absent from every
#    settings file and 0 panes render it (both measured 2026-08-07). So
#    no host's configuration may be baked in here. The label is
#    established PER HOST, at evaluation time, by running the GUIDE's two
#    re-check commands — `reachability` only where they both return zero.
#
# The fix: 2c is SPLIT into `2c-paste` and `2c-vi`, so each half carries
# its own class and — when it claims `empirical` — its own negative
# control. The aggregate key `2c` is REFUSED with a pointer to the two
# halves. The audit row additionally records the derived parent label as
# the WEAKEST of its sub-claims (_class_rank below), so `2c` reads
# `reachability` in decisions.tsv the moment either half is argued rather
# than driven. Splitting the key rather than accepting a parent class +
# an enumeration of sub-claims is deliberate: an enumeration is only as
# complete as the enumerator, and "the sub-claim I did not declare" is
# the same silence-as-evidence failure the whole check exists to stop.
SURFACE_EVIDENCE_SUMMARY=""
SURFACE_EVIDENCE=(); NEGATIVE_CONTROLS=()
_SURFACE_KEYS=(2a 2b 2c-paste 2c-vi 2d 2e)
_SURFACE_CLASSES=(gate empirical reachability source-inspection)
# GUIDE surfaces that are labelled through sub-claim keys instead. The
# parent is never a valid --surface-evidence key; it is only a derived
# label in the audit row.
_SURFACE_COMPOSITES=(2c)

# _surface_subclaims <parent> — the sub-claim keys a composite surface is
# labelled through, space-separated; empty for a leaf surface.
_surface_subclaims() {
    case "$1" in
        2c) printf '2c-paste 2c-vi' ;;
        *)  printf '' ;;
    esac
}

# _class_rank <class> — evidence strength, for "weakest of the
# sub-claims". The ONLY load-bearing property of this order is that the
# DRIVEN classes (a machine-checked gate scenario; a probe with a stated
# negative control) outrank the ARGUED ones (a measured claim about
# reachability; reading the source) — so a composite can never read as
# driven when half of it was argued. The order within each pair is a
# convention, not a claim.
_class_rank() {
    case "$1" in
        gate)              printf 4 ;;
        empirical)         printf 3 ;;
        reachability)      printf 2 ;;
        source-inspection) printf 1 ;;
        *)                 printf 0 ;;
    esac
}

# _surface_key_check <key> <flag-name> — rc 0 iff <key> is a labelable
# surface. Refuses the composite PARENT with the halves named (the
# ergonomic case: `2c=` is what a caller reaches for out of habit) and
# any other unknown key outright (a typo used to be silently ignored,
# and then surfaced as the far less obvious "no evidence for surface X").
_surface_key_check() {
    local key="$1" flag="$2" k sub
    for k in "${_SURFACE_KEYS[@]}"; do [[ "$key" == "$k" ]] && return 0; done
    sub=$(_surface_subclaims "$key")
    if [[ -n "$sub" ]]; then
        note "REFUSED: $flag $key=… — surface $key is COMPOSITE and cannot carry one class. Label each sub-claim separately: $sub. A probe that drives one half and does not reach the other must not attest for both, and the halves routinely differ: for 2c the paste path is drivable everywhere, while the VI half's class depends on THIS host's editorMode setting and must be re-established each round."
    else
        note "REFUSED: $flag $key=… names no known surface (expected: ${_SURFACE_KEYS[*]})"
    fi
    return 1
}

# Which gate scenario substantiates a `gate` claim for a surface. A
# surface with no entry here CANNOT be claimed as `gate`: nothing in the
# harness covers it. 2d's entry is deliberately the PreToolUse scenario
# and NOT test-realmodel-overlimit — the over-limit scenario wires
# Stop/StopFailure, a DIFFERENT hook event, and crediting it for a
# PreToolUse changelog entry is exactly the 2.1.222 mistake.
# 2c-vi's entry (your-org/nexus-code#867): the probe exists, is driven, is
# control-tested, and is already in gate.sh's hardcoded scenario list — it
# simply could not be cited. `test-realmodel-vimode.sh` runs three arms with
# two negative controls (seeded `vim` -> indicator present; key dropped ->
# absent; out-of-enum value -> silently discarded, reads as no seed), and
# since `cch_setup` began seeding `editorMode` defaulting to `vim` the harness
# boots the mode production agents run, closing the gap that made earlier VI
# probes vacuous.
#
# The consequence of the missing entry was fail-CLOSED, which is why it
# blocked no bump and is not urgent: on a host whose config selects VI mode
# `reachability` is not payable either (the surface IS reached), so the only
# remaining label was `source-inspection` — a real, driven, controlled probe
# passing every round while the surface it covers recorded as
# argued-not-driven, on the input path spawn and follow-up delivery depend on.
#
# 2c-paste deliberately gets NO entry: the two halves of 2c keep separate
# labels, and nothing in the harness drives the paste half, so it remains
# `source-inspection` after this change. Adding it here would be the 2.1.222
# mistake in the other direction.
_surface_gate_scenarios() {
    case "$1" in
        2a)    printf 'test-realmodel-idle-busy test-realmodel-autosuggest' ;;
        2b)    printf 'test-realmodel-blocked-question' ;;
        2c-vi) printf 'test-realmodel-vimode' ;;
        2d)    printf 'test-realmodel-pretooluse-hook' ;;
        *)     printf '' ;;
    esac
}

_check_surface_evidence() {
    local gate_log="$1"
    local -A class_of=() ; local -A negctl_of=()
    local item key val

    for item in ${SURFACE_EVIDENCE+"${SURFACE_EVIDENCE[@]}"}; do
        key="${item%%=*}"; val="${item#*=}"
        if [[ "$key" == "$item" || -z "$val" ]]; then
            note "REFUSED: --surface-evidence must be <surface>=<class>, got '$item'"
            return 1
        fi
        _surface_key_check "$key" --surface-evidence || return 1
        class_of["$key"]="$val"
    done
    for item in ${NEGATIVE_CONTROLS+"${NEGATIVE_CONTROLS[@]}"}; do
        key="${item%%=*}"; val="${item#*=}"
        if [[ "$key" == "$item" || -z "$val" ]]; then
            note "REFUSED: --negative-control must be <surface>=<what showed the probe can fail>, got '$item'"
            return 1
        fi
        # A control attached to the composite parent (or to a typo) would
        # silently satisfy nothing, and the caller would then be refused
        # for an `empirical` half that "has" a control.
        _surface_key_check "$key" --negative-control || return 1
        negctl_of["$key"]="$val"
    done

    local surface class known scen ok
    for surface in "${_SURFACE_KEYS[@]}"; do
        class="${class_of[$surface]:-}"
        if [[ -z "$class" ]]; then
            note "REFUSED: no --surface-evidence for GUIDE surface $surface. Every surface needs an explicit evidence class: ${_SURFACE_CLASSES[*]}. A surface you cleared by reasoning is 'reachability' or 'source-inspection' — say so; do not label it 'empirical'."
            return 1
        fi
        known=0
        for val in "${_SURFACE_CLASSES[@]}"; do [[ "$class" == "$val" ]] && known=1; done
        if (( known == 0 )); then
            note "REFUSED: surface $surface has unknown evidence class '$class' (allowed: ${_SURFACE_CLASSES[*]})"
            return 1
        fi

        case "$class" in
            empirical)
                # The teeth. An `empirical` claim without a stated
                # differential/negative control is the exact label the
                # 2.1.216 and 2.1.222 rounds got wrong.
                if [[ -z "${negctl_of[$surface]:-}" ]]; then
                    note "REFUSED: surface $surface claims 'empirical' but carries no --negative-control $surface=<how you showed the probe can go RED>. A probe that cannot fail is not evidence — break the assertion or strip the behaviour under test and observe the red, then state it here. Known failure modes: a no-op input prefix (the VI-insert probe in a default-mode pane) and dead instrumentation (a regex that never matched). If you cannot produce one, the honest class is 'reachability' or 'source-inspection'."
                    return 1
                fi
                ;;
            gate)
                # Verifiable, so verified: a `gate` claim must name a
                # scenario that actually ran in THIS gate log.
                scen=$(_surface_gate_scenarios "$surface")
                if [[ -z "$scen" ]]; then
                    note "REFUSED: surface $surface cannot be cleared by 'gate' — no cc-harness scenario covers it. Use 'empirical' (with a negative control), 'reachability', or 'source-inspection'."
                    return 1
                fi
                ok=0
                for val in $scen; do
                    grep -qF "$val" "$gate_log" 2>/dev/null && ok=1
                done
                if (( ok == 0 )); then
                    note "REFUSED: surface $surface claims 'gate' but the gate evidence ($gate_log) shows none of: $scen. Do not credit coverage from a scenario that exercised a different surface."
                    return 1
                fi
                ;;
        esac
    done

    # Record the labels in the audit trail so a later reviewer can see
    # exactly what was claimed, per surface, without re-reading the report.
    local summary=""
    for surface in "${_SURFACE_KEYS[@]}"; do
        summary+="${summary:+,}$surface=${class_of[$surface]}"
    done
    # …and, for each composite surface, the derived parent label: the
    # WEAKEST of its sub-claims. This is the line a later reviewer reads
    # as "how well was 2c actually covered" — it cannot say `empirical`
    # while either half was merely argued.
    local parent sub low lowclass rank
    for parent in "${_SURFACE_COMPOSITES[@]}"; do
        low=99; lowclass=""
        for sub in $(_surface_subclaims "$parent"); do
            rank=$(_class_rank "${class_of[$sub]}")
            if (( rank < low )); then low=$rank; lowclass="${class_of[$sub]}"; fi
        done
        summary+=",$parent=$lowclass(weakest-of-subclaims)"
    done
    SURFACE_EVIDENCE_SUMMARY="$summary"
    note "surface evidence accepted: $summary"
    return 0
}

# _gate_log_tui_field <file> <key> — the value of <key> from the gate log's
# GEOMETRY stamp (`=== gated-tui: mode=… source=… ===`, your-org/nexus-code
# #1448), empty when absent. Same shape as the tree-field reader below and for
# the same reasons (one awk over the file, no early-exit reader).
_gate_log_tui_field() {
    local f="$1" k="$2"
    awk -v k="$k" '
        index($0, "=== gated-tui: ") == 1 {
            line = $0
            sub(/^=== gated-tui: /, "", line)
            sub(/ ===$/, "", line)
            last = line
        }
        END {
            n = split(last, parts, " ")
            val = ""; found = 0
            for (i = 1; i <= n && !found; i++) {
                p = index(parts[i], "=")
                if (p > 1 && substr(parts[i], 1, p - 1) == k) {
                    val = substr(parts[i], p + 1); found = 1
                }
            }
            if (found) print val
        }' "$f" 2>/dev/null
}

# _gate_log_tree_field <file> <key> — the value of <key> from the gate log's
# machine-readable tree stamp (`=== gated-tree: k=v ... ===`), empty when the
# stamp is absent. Same shape as `_clone_drift_field`, deliberately: one
# key=value idiom for both staleness surfaces rather than two parsers.
_gate_log_tree_field() {
    local f="$1" k="$2"
    # ONE awk over the FILE, not a `sed | tail | tr | awk '…{exit}'` pipeline.
    # This script runs under `set -o pipefail`, and an awk that `exit`s early
    # closes the pipe: the upstream writer takes EPIPE, the pipeline goes
    # non-zero, and the FUNCTION returns non-zero having produced a perfectly
    # correct answer. Harmless at today's call sites, which take the output
    # and ignore the status — and an inverted verdict the first time someone
    # writes `if _gate_log_tree_field …`. `test-early-exit-reader-manifest.sh`
    # caught it as a new `awk-exit` row; the fix is to not have the site.
    awk -v k="$k" '
        index($0, "=== gated-tree: ") == 1 {
            line = $0
            sub(/^=== gated-tree: /, "", line)
            sub(/ ===$/, "", line)
            last = line
        }
        END {
            n = split(last, parts, " ")
            val = ""; found = 0
            for (i = 1; i <= n && !found; i++) {
                p = index(parts[i], "=")
                if (p > 1 && substr(parts[i], 1, p - 1) == k) {
                    val = substr(parts[i], p + 1); found = 1
                }
            }
            if (found) print val
        }' "$f" 2>/dev/null
}

# Which check refused, so the audit row can name it. A `decisions.tsv` row
# reading `gate-evidence` cannot be told apart from any other gate-evidence
# refusal by a later reader — and un-attributable rows are the whole subject
# of your-org/nexus-code#1259.
GATE_EVIDENCE_REFUSAL=""

_check_gate_evidence() {
    local file="$1" candidate="$2"
    GATE_EVIDENCE_REFUSAL=""
    [[ -f "$file" ]] || { note "REFUSED: gate evidence file missing: $file"; return 1; }
    local age now mtime
    now=$(date +%s)
    mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    if (( age > GATE_EVIDENCE_MAX_AGE )); then
        note "REFUSED: gate evidence is ${age}s old (> ${GATE_EVIDENCE_MAX_AGE}s) — re-run the gate"
        return 1
    fi
    if ! grep -q 'GATE GREEN' "$file"; then
        note "REFUSED: gate evidence does not contain 'GATE GREEN' — a red/absent gate never bumps"
        return 1
    fi
    if ! grep -qF "$candidate" "$file"; then
        note "REFUSED: gate evidence does not mention candidate $candidate — wrong gate run?"
        GATE_EVIDENCE_REFUSAL="wrong-candidate"
        return 1
    fi

    # ---- WHICH TREE DID THE GATE MEASURE? (your-org/nexus-code#1259) -----
    #
    # A gate verdict is a property of (candidate x checkout). Everything
    # above validates the CANDIDATE half — the file is fresh, it says GATE
    # GREEN, it names this version — and nothing validated the other half,
    # so a green produced against ANY tree was accepted as licence to move
    # THIS clone's pin.
    #
    # That is not hypothetical. On 2026-09-01 the routine's red came from a
    # clone ninety minutes behind the `#1214` detector fix, and the GREEN
    # that corrected it was produced in a `git worktree` at the integration
    # tip — a different tree from the one whose pin would have moved. The
    # evaluator declined to bump for exactly that reason, by hand. This is
    # that judgement, encoded.
    #
    # NOTE THE DIRECTION. `_deployment_gate` below already measures whether
    # THIS CLONE is behind, with a live-probe trichotomy, and warns. It
    # cannot cover this: it measures the clone at APPLY time, which is a
    # different subject from the tree the GATE ran in, and the two coincide
    # only when the gate was run in place. The 2026-09-01 worktree GREEN is
    # precisely the case where they do not.
    #
    # FAIL CLOSED. Every arm below refuses rather than annotates, because
    # this is the ONLY path that writes the pin, and the cardinal rule of
    # this script is that uncertainty never bumps. The `block` path makes
    # the opposite trade for a stated reason — see `cmd_block`.
    if grep -q '^=== gated-tree: UNATTRIBUTABLE' "$file"; then
        local why
        why=$(_gate_log_tree_field "$file" reason)
        note "REFUSED: the gate could not establish WHICH TREE it gated (reason=${why:-unspecified}) — a green from an unidentified tree is licence to bump on evidence about nothing"
        GATE_EVIDENCE_REFUSAL="tree-unattributable"
        return 1
    fi
    local stamp_head stamp_dirty live_head
    stamp_head=$(_gate_log_tree_field "$file" head)
    if [[ ! "$stamp_head" =~ ^[0-9a-f]{40}$ ]]; then
        note "REFUSED: gate evidence carries no tree stamp — it cannot be attributed to a checkout, so it cannot support a bump. Re-run monitor/cc-harness/gate.sh (a log without '=== gated-tree:' predates your-org/nexus-code#1259, and gate evidence older than ${GATE_EVIDENCE_MAX_AGE}s is refused above anyway)."
        GATE_EVIDENCE_REFUSAL="tree-stamp-missing"
        return 1
    fi
    live_head=$(git -C "$NEXUS_ROOT" rev-parse HEAD 2>/dev/null)
    if [[ ! "$live_head" =~ ^[0-9a-f]{40}$ ]]; then
        note "REFUSED: cannot establish the HEAD of $NEXUS_ROOT — the clone whose pin this would move. 'Could not look' is not 'they match'."
        GATE_EVIDENCE_REFUSAL="live-head-unresolved"
        return 1
    fi
    if [[ "$stamp_head" != "$live_head" ]]; then
        note "REFUSED: the gate measured tree $stamp_head, but the pin about to move belongs to $live_head ($NEXUS_ROOT). A green about a DIFFERENT tree — a worktree, a second clone, a since-advanced checkout — does not license this one. Re-gate in place."
        GATE_EVIDENCE_REFUSAL="tree-mismatch"
        return 1
    fi
    # ---- TRACKED dirtiness, not any dirtiness (your-org/nexus-code#1320) --
    #
    # This arm used to read `dirty=`, which gate.sh computed from a bare
    # `git status --porcelain` -- INCLUDING UNTRACKED FILES. Combined with the
    # `tree-mismatch` arm above, that closed the bump path completely: evidence
    # must come from the primary clone, and a live primary clone is never free
    # of untracked files (measured on this nexus at `dev` 4ab4ed7a: 21
    # untracked, 0 tracked, two of them written by the nexus's own service
    # supervisor). Every daily fire ran a full evaluation and refused at the
    # last step. The refusal's own prescription -- "Commit or stash" -- is not
    # available to an unattended routine whose brief makes the tree read-only.
    #
    # THE PROPERTY is `head identifies the code the gate EXECUTED`. gate.sh now
    # measures that directly and stamps it as `dirty_tracked=`.
    #
    # THE NARROWING IS SCOPED, AND TWO EARLIER VERSIONS OF THIS COMMENT WERE
    # WRONG IN OPPOSITE DIRECTIONS. The first said untracked files cannot reach
    # the gate: FALSE. The second said they can only ever turn a green RED,
    # universally: ALSO FALSE, measured by the #1320 skeptic pass.
    #
    # MEASURED, lint channel: `cc-harness/lint-no-mass-kill.sh` and
    # `lint-no-tmux-server-kill.sh` enumerate with `shf_find0`, a `find` walk,
    # so an untracked plant takes the lint rc 0 -> rc 1. Fail-CLOSED there.
    #
    # MEASURED, the OTHER direction: `cc-harness/gate-coverage.sh` globs the
    # filesystem at `:137` and `:333` feeding vacuity/vocabulary REFUSALS, and
    # an untracked file SATISFIES those. Planting one untracked
    # `test-realmodel-*.sh` takes `gate_refuse_if_vacuous` from rc 3 REFUSED to
    # rc 0 CLEARED. So untracked CAN turn a refusal into a non-refusal.
    #
    # THAT RESIDUAL IS REAL AND IS NOT WHAT THIS ARM IS FOR. The old `dirty=`
    # predicate did not aim at it either -- it would have blocked it only
    # incidentally, and only on an otherwise-pristine clone, i.e. never. The
    # honest accounting: narrowing to `dirty_tracked` removes an INCIDENTAL
    # block on that case, and the right guard for it is a trackedness check
    # inside gate-coverage.sh's own globs, not a whole-tree dirtiness proxy.
    # What this arm needs and gets is the STATED property: whether `head`
    # identifies the code that ran, which only a TRACKED modification changes.
    #
    # No file COUNT is asserted here on purpose. Earlier drafts named one
    # (thirteen, then nineteen) with no ref beside it, and a count is a
    # property of a tree: it goes stale silently and reads as measurement.
    #
    # FAIL CLOSED ON EVIDENCE THAT PREDATES THE SPLIT. A log written before
    # #1320 carries no `dirty_tracked=` at all, so the field reads empty and
    # this arm refuses -- deliberately. Falling back to `dirty=` would re-import
    # the deadlock; treating an absent field as 0 would accept a stamp that
    # never measured the property.
    local stamp_untracked
    stamp_dirty=$(_gate_log_tree_field "$file" dirty_tracked)
    stamp_untracked=$(_gate_log_tree_field "$file" untracked)
    if [[ -z "$stamp_dirty" ]]; then
        note "REFUSED: gate evidence carries no dirty_tracked= field — it predates your-org/nexus-code#1320 and never measured whether the TRACKED tree matched head=$stamp_head. Re-run monitor/cc-harness/gate.sh."
        GATE_EVIDENCE_REFUSAL="gated-tree-dirty-field-missing"
        return 1
    fi
    if [[ "$stamp_dirty" != "0" ]]; then
        note "REFUSED: the gated tree carried TRACKED modifications (dirty_tracked=${stamp_dirty}), so head=$stamp_head does not identify what actually ran. Commit or stash the tracked changes, then re-gate. (untracked=${stamp_untracked:-unrecorded} entries are NOT what refused this.)"
        GATE_EVIDENCE_REFUSAL="gated-tree-dirty"
        return 1
    fi
    # ---- WHICH PANE GEOMETRY DID THE GATE RENDER? (your-org/nexus-code#1448)
    #
    # A gate verdict is a claim about (candidate x checkout x GEOMETRY). The
    # harness boots panes with an isolated CLAUDE_CONFIG_DIR, so for a whole
    # 14-fire run it never read production's `tui: fullscreen` and every
    # pin-control GREEN was a green in a mode production does not run — the
    # over-limit detector was blind under fullscreen AT THE PIN, and nothing in
    # the evidence could say so, because no log carried the geometry. gate.sh
    # stamps it now (`=== gated-tui: mode=… source=… ===`, PR #1473). This arm
    # makes the stamp REQUIRED on the bump path, the same way the tree stamp
    # is: evidence that cannot say which geometry it measured cannot license
    # moving the pin. PREVIOUS BEHAVIOUR: the field was additive and evidence
    # without it was accepted unremarked. A `binary-default` mode with
    # `source=unresolved` is still a stamp — it says, honestly, that the
    # scenarios ran in the binary's own geometry — and is accepted and recorded.
    local stamp_tui stamp_tui_src
    stamp_tui=$(_gate_log_tui_field "$file" mode)
    stamp_tui_src=$(_gate_log_tui_field "$file" source)
    if [[ -z "$stamp_tui" ]]; then
        note "REFUSED: gate evidence carries no geometry stamp (no '=== gated-tui:' line) — it cannot say which pane geometry the scenarios rendered in, and production runs 'tui: fullscreen' where the over-limit detector was measured blind at the pin (your-org/nexus-code#1448). Re-run monitor/cc-harness/gate.sh (a log without the stamp predates PR #1473)."
        GATE_EVIDENCE_REFUSAL="gated-tui-stamp-missing"
        return 1
    fi
    note "gate evidence attributed: tree=$stamp_head (matches $NEXUS_ROOT), subject=$(_gate_log_tree_field "$file" subject_path)@$(_gate_log_tree_field "$file" subject_blob), dirty_tracked=0, untracked=${stamp_untracked:-unrecorded} (audit only — outside the executed closure's WRITE surface; see #1320), tui=${stamp_tui} (source=${stamp_tui_src:-unrecorded}; #1448)"
    return 0
}

# ---- changelog completeness: every entry, every release, with counts -----
#
# THE DEFECT THIS CLOSES. The GUIDE has said "account for EVERY entry"
# since 2.1.217 — whose one missed entry was the whole defect — and it
# was advisory, so nothing checked it. The 2.1.224 round asserted "both
# releases read in full" and then tabulated 41 of 50 entries: the nine it
# omitted included the `bypassPermissions` vs org-disable-policy fix (the
# flag EVERY nexus spawn rides), the workflow-sandbox dynamic-`import()`
# escape, and `sandbox.filesystem.denyWrite` covering the working
# directory (this nexus runs inside agent-sandbox). Three of those had
# been pre-flagged BY NAME in the spawn brief. The skeptic then verified
# each is inert — which is the point: "no impact" was the DEFAULT, not a
# claim anyone made. Same shape as 2.1.217's unread footer entry.
#
# WHAT IS ENFORCED. Four things, in increasing order of teeth:
#
#  0. THE CHANGELOG IS FETCHED HERE, from upstream, by this script. The
#     first cut of this check trusted `--changelog-evidence` — a
#     caller-supplied file, validated only by its mtime and a grep for
#     the candidate heading. A skeptic truncated 2.1.223 from 19 bullets
#     to 5, declared `2.1.223=5`, and was ACCEPTED at rc 0 with
#     "dispositioned 36 of 36". Freshness was no obstacle: a hand-edited
#     copy has a fresh mtime by construction. So M was never the
#     caller's to assert only in the sense that they had to edit a file
#     first — which is no obstacle at all. Now `_cl_fetch_changelog`
#     mints a token and re-fetches `CHANGELOG.md` itself (the same
#     `mint-token.sh` the deployment gate's PR probe uses), and EVERY
#     count and entry below is read from THAT copy. A fetch that fails
#     REFUSES: the cardinal rule is that uncertainty never bumps.
#  1. `--changelog-evidence` is still required, still fresh, and must
#     still carry the candidate's section — but its role is now
#     narrower and honest: it is what the evaluator ACTUALLY READ, and
#     it is CROSS-CHECKED against the upstream fetch section by section.
#     A stale or doctored read is named as such instead of surfacing
#     later as a confusing ledger failure.
#  2. The RELEASE SET is derived from the npm REGISTRY: every version it
#     PUBLISHES with installed < ver <= candidate (your-org/nexus-code#1007).
#     A two-release jump needs both. Deriving beats enumerating patch
#     numbers — upstream skips versions routinely (39 gaps in the 2.1.x
#     series), so an arithmetic range would demand dispositions for
#     releases that do not exist. And the registry beats the changelog's
#     OWN `## <ver>` headers, which is what this used to read: a header
#     set cannot contain a release that published no header, so a
#     sectionless release was never IN the set — not counted toward M,
#     never owed a disposition — and the accounting read GREEN with a
#     whole release unexamined. It fired on 2026-08-25: 2.1.242 is
#     published (registry: true) and has no `## 2.1.242` section; two
#     independent fires read "406 of 406 across 18 releases" over it.
#     Now such a release is an OPAQUE release and REFUSES with its own
#     exit code (8), naming the version: an absence of evidence, not an
#     absence of entries. The refusal is BOUNDED: after OPAQUE_ESCALATE_AT
#     (= GATE_DEFER_STREAK_CAP) consecutive refusals on the same opaque
#     set, `_cl_opaque_escalate` tells the operator — notify + a
#     tracking-issue comment — and the refusal continues; it never
#     auto-proceeds. The registry fetch gets the changelog fetch's
#     treatment (rule 0): a failed fetch, a non-packument body, an empty
#     version set, or a copy that does not list the candidate all REFUSE
#     (exit 3) — NEVER fall back to the header-derived set, because that
#     fallback reintroduces the blind spot at exactly the moment the
#     check matters. The converse — a `## <ver>` header for a version the
#     registry does NOT publish — is a CHOICE: dropped from the set with a
#     WARN naming it. Nothing installable carries those entries, so they
#     cannot inflate M; the alternative (demand a disposition for a
#     release nobody can install) would train evaluators to route around
#     the check, which is the worse failure. The one shape where that
#     choice errs: a registry copy internally inconsistent with itself —
#     listing the candidate but missing an intermediate release the
#     changelog heads. No such document has been observed; the candidate-
#     presence check bounds the ordinary staleness case.
#  3. M (entries in a release) is COUNTED from the upstream fetch; N is
#     the caller's `--changelog-dispositioned <ver>=<N>`, and N != M
#     refuses. And because a count alone can be bluffed by an evaluator who
#     believes they read everything, each entry must additionally appear
#     VERBATIM in `--changelog-ledger` — one line per entry, quote plus
#     disposition. That file is what makes N honest: the ledger is the
#     artifact the report's table is built from.
#
# What is NOT checkable from here: whether a disposition is CORRECT. The
# ledger's verdict text is unread. This check enforces that every entry
# was looked at and written down — the failure mode that has actually
# recurred — not that the judgment on it was right.
CHANGELOG_SUMMARY=""
CHANGELOG_DISPOSITIONS=()
# The refusal REASON for the arms your-org/nexus-code#1007 added, appended
# to the `safe-refused` row's detail by cmd_safe (the GATE_EVIDENCE_REFUSAL
# shape): `registry-fetch`, `registry-unparseable`,
# `registry-candidate-absent`, or `opaque-release=<v1,v2,…>`. Empty for
# every pre-existing arm, whose rows are byte-identical to before. A
# distinct, STABLE detail is what lets the #1400 repeat-nag recognise the
# same refusal on consecutive fires — an opaque release IS the standing
# condition that nag exists for.
CHANGELOG_REFUSAL=""

# _ver_lt <a> <b> — rc 0 iff version a sorts strictly before b.
_ver_lt() {
    [[ "$1" == "$2" ]] && return 1
    local first
    first=$(printf '%s\n%s\n' "$1" "$2" | sort -V | sed -n 1p)
    [[ "$first" == "$1" ]]
}

# _cl_entries <file> <version> — the entry TEXT (bullet stripped), one
# per line, for that release's section.
#
# NESTED BULLETS COUNT. This was anchored at `^- `, which silently
# skipped an INDENTED sub-bullet: not counted into M, never demanded in
# the ledger, and the run accepted at rc 0 — a sub-entry describing a
# behaviour change would have passed entirely unread. The heading parser
# fails CLOSED (a heading shape this cannot read leaves a PUBLISHED
# release with no readable `## <ver>` line, which refuses as OPAQUE —
# exit 8, your-org/nexus-code#1007 — and a missing candidate section
# refuses outright; before #1007 an unreadable heading merely dropped the
# release from the header-derived set, which was the OPEN direction);
# the bullet parser failed OPEN, which is the more dangerous half and is
# exactly the sort of "the failure mode is safe" claim that stops people
# looking. Any bullet at any indent, `-` or `*`, is now an entry needing
# its own disposition. Upstream is flat today (0 indented bullets across
# all 357 sections, measured 2026-08-07), so this changes no count now —
# it removes a prospective silent pass, and over-counting is the safe
# direction: it can only demand MORE accounting, never less.
_cl_entries() {
    awk -v want="$2" '
        /^## /                              { sec = ($2 == want) ? 1 : 0; next }
        sec && /^[[:space:]]*[-*][[:space:]]/ {
            line = $0
            sub(/^[[:space:]]*[-*][[:space:]]+/, "", line)
            print line
        }' "$1"
}

# _cl_entry_count <file> <version> — how many such entries.
_cl_entry_count() {
    _cl_entries "$1" "$2" | grep -c '' || true
}

# _cl_fetch_changelog — print the upstream CHANGELOG.md on stdout; rc
# non-zero on any failure (mint, network, gh, base64). The caller treats
# a failure as a REFUSAL, never as "no entries" — a silent zero here
# would hand a clean bill of health to an unread changelog.
#
# `--jq .content` returns base64 WRAPPED at 60 cols. The `tr -d` is
# DEFENSIVE, not load-bearing here: measured on this host (GNU coreutils
# 8.28) against the live 668,667-byte / 10,963-line wrapped body, `base64
# -d` with and without it produce byte-identical 493,278-byte output,
# rc 0 both ways. Kept for the BSD/macOS `base64`, which is stricter.
#
# The earlier comment here claimed the wrapping was what broke a hand-run
# — it was not, and the misattribution is worth recording. What actually
# broke it was `gh api … 2>&1 | base64 -d`: with `gh` unauthenticated,
# `2>&1` folded "Welcome to GitHub CLI! To authenticate…" into the pipe
# and base64 choked on the prose. Reproduced deliberately (`GH_CONFIG_DIR=
# /nonexistent` → `base64: invalid input`). The lesson is about `2>&1` on
# a binary pipe, not about line wrapping — so this function keeps stderr
# out of stdout, which is the part that matters.
_cl_fetch_changelog() {
    if [[ -n "$CHANGELOG_FETCH_CMD" ]]; then
        "$CHANGELOG_FETCH_CMD"
        return $?
    fi
    local token
    token=$("$MINT_CMD") || return 1
    [[ -n "$token" ]] || return 1
    GH_TOKEN="$token" "$GH_CMD" api \
        "repos/$CHANGELOG_REPO/contents/CHANGELOG.md" --jq '.content' \
        | tr -d '\n' | base64 -d
}

# _cl_fetch_registry — print $PACKAGE's ABBREVIATED packument on stdout
# (the `application/vnd.npm.install-v1+json` document: `versions` keyed by
# version string, `dist-tags`, nothing else — roughly a tenth of the full
# one); rc non-zero on any failure (no curl, network, HTTP >= 400). The
# caller treats a failure as a REFUSAL, never as "no releases" — the rule
# `_cl_fetch_changelog` already follows, for the same reason: a silent
# zero here would hand the release set back to the changelog's headers,
# which is the blind spot your-org/nexus-code#1007 removes.
#
# `-f` makes an HTTP error an rc, so a 404 body ("Not Found" prose) never
# reaches the parser as a document; `-sS` keeps stderr out of stdout —
# the `2>&1`-into-a-binary-pipe lesson recorded on `_cl_fetch_changelog`.
_cl_fetch_registry() {
    if [[ -n "$REGISTRY_FETCH_CMD" ]]; then
        "$REGISTRY_FETCH_CMD"
        return $?
    fi
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsS --max-time "$REGISTRY_TIMEOUT" \
        -H 'Accept: application/vnd.npm.install-v1+json' \
        "$REGISTRY_BASE/$PACKAGE"
}

# _cl_registry_versions <packument-file> — every published version, one
# per line, semver-sorted (`sort -V`, the same comparator `_ver_lt` and
# the watcher's `_cc_update_compare` use). rc non-zero, NO output, when
# the document is not JSON, has no `versions` object, or lists none —
# the caller refuses on that rc rather than reading an empty set as an
# empty delta. `jq` is required (1.5 on this host; `keys` is jq 1.3+).
# `.versions // {}` makes a MISSING key an empty object (rc 1 below) and
# a `versions` that is not an object a jq error (also rc 1) — both the
# refusing direction.
_cl_registry_versions() {
    command -v jq >/dev/null 2>&1 || return 1
    local out
    out=$(jq -r '.versions // {} | keys[]' "$1" 2>/dev/null) || return 1
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out" | sort -V
}

# ---- the BOUNDED opaque-release refusal (your-org/nexus-code#1007 follow-up) --
#
# _cl_opaque_streak <detail> — how many CONSECUTIVE fires have been refused
# with exactly this `safe-refused` detail, read from decisions.tsv the way
# the #1400 repeat-nag reads it: walk the terminal `safe-refused` rows from
# the newest back while their detail matches. Two things BREAK the run — a
# `safe-refused` row with a different detail (some other refusal happened in
# between: the condition was not observed on that fire, so it does not count
# toward the bound), and a `changelog-completeness` acceptance row (the check
# PASSED on that fire, so whatever was opaque then is not this streak). Rows
# of any other kind — audit rows, gate rows, the trigger's own nag rows — are
# skipped, exactly as the #1400 reader skips them. An unreadable ledger reads
# as 0: the SAFE direction for a counter whose only effect is to tell someone
# sooner, since it can only delay the escalation, never suppress the refusal.
_cl_opaque_streak() {
    local detail="$1" n
    [[ -r "$AUTO_DIR/decisions.tsv" ]] || { printf '0'; return 0; }
    n=$(awk -F'\t' -v d="$detail" '
        $3=="safe-refused"           { r[++k]=$4; next }
        $3=="changelog-completeness" { r[++k]="<accepted>"; next }
        END { c=0; for (i=k; i>=1 && r[i]==d; i--) c++; print c+0 }' \
        "$AUTO_DIR/decisions.tsv" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# _cl_tracking_issue — print "<owner/repo> <N>" for the configured cc-update
# tracking issue; rc 1 (no output) when none is configured, the resolver is
# missing, or the value is not a qualified reference. Same resolution the
# watcher's fire path uses (`_cc_auto_update.sh`, #866): the config value
# through monitor/issue-ref.sh, which REFUSES a bare number rather than
# guessing its repo — a guessed repo is how writes land, succeed, and are
# never seen. CC_AUTO_TRACKING_ISSUE overrides the config (test seam, and the
# same shape as CC_AUTO_TARGET_WINDOW).
_cl_tracking_issue() {
    local raw ref repo issue
    raw="${CC_AUTO_TRACKING_ISSUE:-$("$NEXUS_ROOT/config/load.sh" monitor.cc_auto_update.tracking_issue "" 2>/dev/null || true)}"
    [[ -n "$raw" ]] || return 1
    [[ -r "$NEXUS_ROOT/monitor/issue-ref.sh" ]] || return 1
    ref=$(bash "$NEXUS_ROOT/monitor/issue-ref.sh" "$raw" --field monitor.cc_auto_update.tracking_issue 2>/dev/null) || return 1
    repo=$(awk -F= '$1=="REPO"{print $2; exit}' <<<"$ref")
    issue=$(awk -F= '$1=="ISSUE"{print $2; exit}' <<<"$ref")
    [[ -n "$repo" && "$issue" =~ ^[0-9]+$ ]] || return 1
    printf '%s %s' "$repo" "$issue"
}

# _cl_opaque_escalate <candidate> <detail> <opaque-csv> — the bound on exit 8.
# Returns 0 ALWAYS: a side effect, never a predicate. It does not change the
# exit code or the outcome token — the fire is still `safe-refused` / exit 8
# — it makes the Nth consecutive refusal LOUD and HUMAN-ADDRESSED instead of
# the (N)th identical dark row. The operator directive this serves is the one
# the deployment gate's bound serves: a busy board may DELAY the update, not
# PREVENT it — and a refusal nobody is told about is prevention wearing
# delay's clothes.
#
# Two channels, two cadences, mirroring `_gate_defer`'s ALERT and
# `_gate_file_defect`'s cooldown: the NOTIFY (and the audit row) fire on EVERY
# fire at or past the bound, like the defer alert; the ISSUE POST happens ONCE
# per opaque set per GATE_DEFECT_REFILE_SECONDS, like the defect filer,
# because a comment per morning on one sectionless release trains the
# operator to mute the channel. The breadcrumb lives under
# $AUTO_DIR/opaque-escalations/<opaque-csv>; a post that FAILS writes no
# breadcrumb, so the next fire retries, and says so in the ledger
# (`changelog-opaque-escalation-UNPOSTED`) — the filer's own failure has to
# be visible (w227 skeptic F2), or "we told someone" is a manufactured
# success.
#
# WHERE IT POSTS. The cc-update tracking issue when one is configured (a
# COMMENT — the thread the operator already watches); otherwise create-or-
# adopt an issue on $GATE_REPO carrying a marker, the `_gate_file_defect`
# shape, through the same seam (CC_AUTO_GATE_ISSUE_CMD). Bot identity via
# $MINT_CMD + $GH_CMD, the path every other GitHub write in this file uses.
# SAFE IN FIXTURES BY CONSTRUCTION: the mint must succeed before `gh` is
# reached, and a fixture's mint-token.sh does not exist.
_cl_opaque_escalate() {
    local candidate="$1" detail="$2" opaque="$3" streak
    streak=$(_cl_opaque_streak "$detail")
    note "opaque-release streak: $streak consecutive fire(s) refused on '$opaque' — escalation at $OPAQUE_ESCALATE_AT (defer_cap=$GATE_DEFER_STREAK_CAP defer_cap_clamped=$GATE_DEFER_STREAK_CAP_CLAMPED). The refusal stands either way; this bound only decides when a human is told."
    (( streak >= OPAQUE_ESCALATE_AT )) || return 0

    local sentence="upstream shipped no parseable sections; this needs a human disposition."
    local msg="cc-auto-update: candidate $candidate refused ${streak}× in a row (exit 8) — release(s) $opaque are published inside the delta with no changelog section: $sentence"
    note "ESCALATION (opaque release, bounded refusal): $msg"
    _cc_auto_log_decision "$AUTO_DIR" "$candidate" "changelog-opaque-escalation" \
        "streak=$streak escalate_at=$OPAQUE_ESCALATE_AT defer_cap=$GATE_DEFER_STREAK_CAP defer_cap_clamped=$GATE_DEFER_STREAK_CAP_CLAMPED $detail"
    notify "$msg"

    # The issue post — once per opaque set per cooldown.
    local dir="$AUTO_DIR/opaque-escalations" bc="$AUTO_DIR/opaque-escalations/$opaque"
    mkdir -p "$dir" 2>/dev/null || true
    if [[ -f "$bc" ]]; then
        local now mt age n head
        now=$(date +%s); mt=$(stat -c %Y "$bc" 2>/dev/null || echo 0)
        age=$(( now - mt ))
        if [[ "$age" =~ ^[0-9]+$ ]] && (( age < GATE_DEFECT_REFILE_SECONDS )); then
            n=$(awk -F'count=' 'NF>1{print $2+0; exit}' "$bc" 2>/dev/null)
            [[ "$n" =~ ^[0-9]+$ ]] || n=0
            head=$(sed -n '1s/ *count=[0-9]*//p' "$bc" 2>/dev/null)
            [[ -n "$head" ]] || head=$(sed -n 1p "$bc" 2>/dev/null)
            note "opaque-release escalation for '$opaque' already posted ($head); repeat $(( n + 1 )), not re-posting (cooldown ${GATE_DEFECT_REFILE_SECONDS}s)"
            printf '%s count=%s\n' "$head" "$(( n + 1 ))" > "$bc.tmp" 2>/dev/null \
                && mv -f "$bc.tmp" "$bc" 2>/dev/null
            return 0
        fi
    fi

    local body
    if ! body=$(mktemp 2>/dev/null) || [[ -z "$body" ]]; then
        note "opaque-release escalation for '$opaque' could NOT be posted — mktemp failed. The operator was notified but the thread was not; retried next fire."
        _cc_auto_log_decision "$AUTO_DIR" "$candidate" "changelog-opaque-escalation-UNPOSTED" "why=mktemp $detail"
        return 0
    fi
    local marker="<!-- cc-auto-opaque-release: $opaque -->"
    {
        printf '%s\n\n' "$marker"
        printf '## cc-auto-update: bounded opaque-release refusal — human disposition needed\n\n'
        printf -- '- **candidate**: `%s`\n' "$candidate"
        printf -- '- **opaque release(s)**: `%s` — published by the npm registry inside the delta, NO `## <version>` section in `%s` CHANGELOG.md\n' "$opaque" "$CHANGELOG_REPO"
        printf -- '- **consecutive refusals**: %s (escalation bound %s = `defer_streak_cap`; floor %s)\n\n' "$streak" "$OPAQUE_ESCALATE_AT" "$GATE_DEFER_STREAK_CAP_FLOOR"
        printf '%s\n\n' "$sentence"
        printf 'The autonomous routine has refused this bump `exit 8` on every fire since the streak began and will KEEP refusing — it never auto-proceeds past an absence of evidence. It clears on its own the day upstream publishes the section. Until then the fleet stays on the installed version, and this comment is the bound on that delay (operator directive 2026-09-10: a busy board may DELAY an update, not PREVENT it).\n\n'
        printf 'Options for a human: (1) wait for upstream; (2) read the release from its tarball / release page and, if it is judged safe, bump by hand per `skills/nexus.cc-update/GUIDE.md` Step 5 — the record of THAT reading is the disposition the changelog could not supply; (3) hold the routine (`monitor/cc-auto-update-apply.sh hold --reason …`).\n\n'
        printf 'Ledger: `monitor/.state/cc-auto-update/decisions.tsv`, rows `safe-refused changelog-completeness:opaque-release=%s` and `changelog-opaque-escalation`. Mechanism: `_cl_opaque_escalate` in `monitor/cc-auto-update-apply.sh` (your-org/nexus-code#1007).\n' "$opaque"
    } > "$body"

    local target out="" where=""
    if target=$(_cl_tracking_issue); then
        local repo="${target% *}" issue="${target#* }"
        where="$repo#$issue"
        if [[ -n "${CC_AUTO_ISSUE_COMMENT_CMD:-}" ]]; then
            out=$("$CC_AUTO_ISSUE_COMMENT_CMD" "$repo" "$issue" "$body" 2>&1) || out=""
        else
            local token
            if token=$("$MINT_CMD" 2>/dev/null) && [[ -n "$token" ]]; then
                out=$(GH_TOKEN="$token" "$GH_CMD" issue comment "$issue" --repo "$repo" --body-file "$body" 2>&1) || out=""
            else
                out=""
            fi
        fi
    else
        # No tracking issue: file, or adopt, ONE issue per opaque set on
        # $GATE_REPO — the deployment gate's defect-filer shape and seam.
        local key="opaque-release-$opaque"
        local title="cc-auto-update: opaque release(s) $opaque — no changelog section, bump refused ${streak}× (needs a human disposition)"
        where="$GATE_REPO (new/adopted issue, key $key)"
        if [[ -n "${CC_AUTO_GATE_ISSUE_CMD:-}" ]]; then
            out=$("$CC_AUTO_GATE_ISSUE_CMD" "$key" "$title" "$body" 2>&1) || out=""
        else
            local token found
            if token=$("$MINT_CMD" 2>/dev/null) && [[ -n "$token" ]]; then
                found=$(GH_TOKEN="$token" "$GH_CMD" issue list --repo "$GATE_REPO" --state open \
                            --search "$marker" --json number --jq '.[0].number' 2>/dev/null || true)
                if [[ "$found" =~ ^[0-9]+$ ]]; then
                    out=$(GH_TOKEN="$token" "$GH_CMD" issue comment "$found" --repo "$GATE_REPO" --body-file "$body" 2>&1) || out=""
                    [[ -n "$out" ]] || out="$GATE_REPO#$found"
                else
                    out=$(GH_TOKEN="$token" "$GH_CMD" issue create --repo "$GATE_REPO" \
                              --title "$title" --body-file "$body" 2>&1) || out=""
                fi
            else
                out=""
            fi
        fi
    fi
    rm -f "$body"

    if [[ -n "$out" ]]; then
        printf 'posted=%s at=%s first=%s count=1\n' "$where" "$(printf '%s' "$out" | tail -1 | cut -c1-200)" "$(date -Is 2>/dev/null || echo unknown)" > "$bc" 2>/dev/null || true
        note "opaque-release escalation for '$opaque' posted to $where"
        _cc_auto_log_decision "$AUTO_DIR" "$candidate" "changelog-opaque-escalation-posted" "where=$where $detail"
    else
        note "opaque-release escalation for '$opaque' could NOT be posted to ${where:-anywhere} (mint/gh/seam failure or no output). The operator was notified but the thread was not — THE BLIND SPOT IS DOUBLE until a fire succeeds; retried on the next fire at or past the bound."
        _cc_auto_log_decision "$AUTO_DIR" "$candidate" "changelog-opaque-escalation-UNPOSTED" "where=${where:-none} $detail"
        notify "cc-auto-update: opaque-release escalation for $candidate ($opaque) could NOT be posted to ${where:-the tracking issue} — nobody has been told but you"
    fi
    return 0
}

# _check_changelog_completeness <changelog> <ledger> <installed> <candidate>
#
# rc 0 accepted; rc 1 refused (cmd_safe exits 3); rc 2 refused because of
# an OPAQUE release (cmd_safe exits 8) — your-org/nexus-code#1007. The
# reason for the #1007 arms lands in CHANGELOG_REFUSAL.
_check_changelog_completeness() {
    local file="$1" ledger="$2" installed="$3" candidate="$4"
    local item key val ver

    if [[ -z "$file" ]]; then
        note "REFUSED: --changelog-evidence <file> is required — the changelog you fetched from source in THIS evaluation. It is cross-checked, section by section, against the copy this run fetches for itself."
        return 1
    fi
    [[ -s "$file" ]] || { note "REFUSED: changelog evidence missing or empty: $file"; return 1; }
    if [[ -z "$ledger" ]] || [[ ! -s "$ledger" ]]; then
        note "REFUSED: --changelog-ledger <file> is required and must be non-empty — ONE LINE PER ENTRY, each line carrying the entry quoted verbatim plus its disposition (a surface, or an explicit 'no nexus surface'). A count on its own is an assertion; the ledger is what makes it checkable."
        return 1
    fi

    local now mtime age
    now=$(date +%s); mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    if (( age > CHANGELOG_EVIDENCE_MAX_AGE )); then
        note "REFUSED: changelog evidence is ${age}s old (> ${CHANGELOG_EVIDENCE_MAX_AGE}s) — re-fetch it from source in this session, do not reuse a prior round's copy"
        return 1
    fi

    # ---- the authoritative copy: fetched HERE, not supplied -----------
    # Everything below counts and quotes from $fetched. The caller's
    # file is only ever compared against it.
    local fetched
    fetched=$(mktemp "${TMPDIR:-/tmp}/cc-changelog-fetched.XXXXXX" 2>/dev/null) \
        || { note "REFUSED: could not create a temp file for the changelog fetch"; return 1; }
    if ! _cl_fetch_changelog > "$fetched" 2>/dev/null || [[ ! -s "$fetched" ]]; then
        rm -f "$fetched"
        note "REFUSED: could not fetch $CHANGELOG_REPO CHANGELOG.md (mint/network/gh failure, or an empty body). This REFUSES rather than falling back to the supplied file: the supplied file is exactly what an unverified count would rest on. Retry, or fix the token; the next daily fire retries on its own."
        return 1
    fi
    # Every exit from here on must remove it.
    _cl_done() { rm -f "$fetched" 2>/dev/null || true; }

    # No provenance note here, deliberately. The previous revision
    # WARNed when any of four named env vars was set, which read as an
    # all-clear when none was — and PATH, which is not among them and
    # cannot be enumerated, was enough to spoof the whole thing. Silence
    # about an unknown is more honest than a green light. See the
    # provenance note at the top of this file.

    if ! grep -q "^## $candidate\$" "$fetched"; then
        _cl_done
        note "REFUSED: the $CHANGELOG_REPO CHANGELOG.md this run fetched has no '## $candidate' section — the candidate is not a published release there, or the changelog format changed under us. Not something to work around: establish what the candidate actually is."
        return 1
    fi
    if ! grep -q "^## $candidate\$" "$file"; then
        _cl_done
        note "REFUSED: your --changelog-evidence has no '## $candidate' section — you read something other than the candidate's changelog (stale fetch? wrong file?)"
        return 1
    fi

    # The release set, derived from the REGISTRY (your-org/nexus-code#1007):
    # every version it publishes with installed < ver <= candidate. See
    # rule 2 in the block above for why the changelog's own headers are
    # not the set. Empty `installed` means the effective version could
    # not be resolved; there is then no delta to derive, so fall back to
    # the candidate alone and say so LOUDLY rather than silently checking
    # nothing (the candidate's own section is already required above).
    local -a releases=() opaque=() unpublished=()
    CHANGELOG_REFUSAL=""
    if [[ -z "$installed" ]]; then
        note "WARN changelog: effective installed version unresolved — cannot derive the release delta; requiring the candidate's release only"
        releases=("$candidate")
    else
        local reg pub_list in_reg=0 hv
        reg=$(mktemp "${TMPDIR:-/tmp}/cc-registry-fetched.XXXXXX" 2>/dev/null) \
            || { _cl_done; CHANGELOG_REFUSAL="registry-fetch"; note "REFUSED: could not create a temp file for the registry fetch"; return 1; }
        if ! _cl_fetch_registry > "$reg" 2>/dev/null || [[ ! -s "$reg" ]]; then
            rm -f "$reg"; _cl_done
            CHANGELOG_REFUSAL="registry-fetch"
            note "REFUSED: could not fetch the $PACKAGE registry document from $REGISTRY_BASE (curl/network/HTTP failure, or an empty body). The release set is what the registry PUBLISHES in ($installed, $candidate]; this REFUSES rather than falling back to the changelog's own '## <version>' headers, because a release that publishes no section is exactly what a header-derived set cannot see (your-org/nexus-code#1007). Retry; the next daily fire retries on its own."
            return 1
        fi
        if ! pub_list=$(_cl_registry_versions "$reg"); then
            local reg_head
            reg_head=$(head -c 80 "$reg" 2>/dev/null | tr -d '\n' | tr -c '[:print:]' '?')
            rm -f "$reg"; _cl_done
            CHANGELOG_REFUSAL="registry-unparseable"
            note "REFUSED: the registry document fetched for $PACKAGE from $REGISTRY_BASE is not a packument this run can read — not JSON, no 'versions' object, or it lists no versions (body begins: ${reg_head}…). Same rule as a failed fetch: no fallback to the changelog headers (your-org/nexus-code#1007)."
            return 1
        fi
        rm -f "$reg"
        while IFS= read -r ver; do
            [[ -n "$ver" ]] || continue
            [[ "$ver" == "$candidate" ]] && in_reg=1
            _ver_lt "$installed" "$ver" || continue      # ver > installed
            _ver_lt "$candidate" "$ver" && continue      # ver <= candidate
            releases+=("$ver")
        done <<<"$pub_list"
        if (( in_reg == 0 )); then
            _cl_done
            CHANGELOG_REFUSAL="registry-candidate-absent"
            note "REFUSED: the registry document does not list the candidate $candidate among $PACKAGE's published versions. The candidate came from the registry's own 'latest' in the first place, so either it is not a published release or the copy this run read is STALE — and a stale registry answer is the defect this derivation exists to remove (a cache-served 'npm view' returned a superseded 'latest' to two independent evaluators on 2026-08-25, your-org/nexus-code#1007). Not something to work around: establish what the candidate actually is."
            return 1
        fi
        # OPAQUE releases: published, inside the delta, and no `## <ver>`
        # section in the changelog this run fetched. `-x -F`: the whole
        # line, literally — `2.1.15` must not match `## 2.1.155`.
        for ver in "${releases[@]}"; do
            grep -qxF -- "## $ver" "$fetched" || opaque+=("$ver")
        done
        if (( ${#opaque[@]} > 0 )); then
            _cl_done
            CHANGELOG_REFUSAL="opaque-release=$(IFS=,; printf '%s' "${opaque[*]}")"
            note "REFUSED (exit 8, OPAQUE RELEASE): ${opaque[*]} — ${#opaque[@]} release(s) the registry publishes inside the delta ($installed, $candidate] with NO '## <version>' section in the $CHANGELOG_REPO CHANGELOG.md this run fetched. An opaque release is an ABSENCE OF EVIDENCE, not an absence of entries: nothing in any ledger can account for what it changed, so this run cannot establish the bump is safe, and nothing you pass can clear this arm. Before your-org/nexus-code#1007 the release set was the changelog's own headers, so such a release was simply not IN the set and 'dispositioned N of M' read GREEN over it (2.1.242, 2026-08-25). The next daily fire retries and clears the day upstream publishes the section; after $OPAQUE_ESCALATE_AT consecutive refusals on this same set the operator is escalated automatically (notify + tracking-issue comment) — bounded delay, never a silent pin."
            return 2
        fi
        # Headers for versions the registry does NOT publish: dropped from
        # the set, by CHOICE (rule 2 above) — said out loud, never silent.
        while IFS= read -r hv; do
            [[ -n "$hv" ]] || continue
            _ver_lt "$installed" "$hv" || continue
            _ver_lt "$candidate" "$hv" && continue
            grep -qxF -- "$hv" <<<"$pub_list" || unpublished+=("$hv")
        done < <(awk '/^## /{print $2}' "$fetched")
        if (( ${#unpublished[@]} > 0 )); then
            note "WARN changelog: '## ${unpublished[*]}' — ${#unpublished[@]} section(s) inside the delta ($installed, $candidate] whose version the registry does NOT publish; dropped from the release set (nothing installable carries those entries; a disposition for one is refused as outside the delta). your-org/nexus-code#1007."
        fi
    fi
    if (( ${#releases[@]} == 0 )); then
        _cl_done
        note "REFUSED: the registry publishes no release in the delta ($installed, $candidate] — the effective version and the candidate do not describe a real bump"
        return 1
    fi

    local -A disp_of=()
    for item in ${CHANGELOG_DISPOSITIONS+"${CHANGELOG_DISPOSITIONS[@]}"}; do
        key="${item%%=*}"; val="${item#*=}"
        if [[ "$key" == "$item" || -z "$val" ]]; then
            _cl_done
            note "REFUSED: --changelog-dispositioned must be <release>=<count>, got '$item'"
            return 1
        fi
        if [[ ! "$val" =~ ^[0-9]+$ ]]; then
            _cl_done
            note "REFUSED: --changelog-dispositioned $key=$val — the count must be a number"
            return 1
        fi
        local in_set=0 r
        for r in "${releases[@]}"; do [[ "$key" == "$r" ]] && in_set=1; done
        if (( in_set == 0 )); then
            _cl_done
            note "REFUSED: --changelog-dispositioned $key=… names a release outside the delta. Releases requiring a disposition — what the registry publishes in ($installed, $candidate]: ${releases[*]}"
            return 1
        fi
        disp_of["$key"]="$val"
    done

    # One line per entry; collapse whitespace on BOTH sides so the ledger
    # may be a markdown table, a list, or plain lines. Then strip MARKDOWN
    # BACKSLASH ESCAPES on both sides (your-org/nexus-code#867).
    #
    # WHY THE ESCAPE STRIP. The GUIDE tells the evaluator to write a ledger
    # with "the entry quoted VERBATIM plus its disposition", and the natural
    # way to render "verbatim" in markdown is a backtick span. Upstream
    # `anthropics/claude-code` entries routinely contain backticks — they name
    # flags, settings keys and subcommands in code spans — so any such entry
    # needs its inner backticks escaped (`` \` ``), and the escape breaks
    # byte-equality against the fetched changelog under `grep -qF`.
    #
    # The refusal that followed was emitted as a COMPLETENESS failure — "N of
    # M entries do not appear verbatim" — which reads as "you did not
    # disposition these". The actual cause was a quoting artifact in a ledger
    # where every entry HAD been dispositioned. Given this machinery exists
    # precisely to stop entries going unconsidered, a false "you missed these"
    # is an expensive misdiagnosis, and it arrives late, at apply time.
    #
    # The rule is CommonMark's: only ASCII punctuation is escapable, so a
    # backslash before punctuation is markup and a backslash anywhere else is
    # a literal. That keeps the strip NARROW — it removes backslashes and
    # nothing else.
    #
    # IT DOES NOT KEEP IT INJECTIVE, and this comment used to claim it did
    # (your-org/nexus-code#1131 residual 1). The claim was an absolute — "it
    # cannot turn a genuinely absent entry into a present one" — and it is
    # false as written: the strip DELETES characters, so it is many-to-one,
    # and two distinct upstream entries can collapse to one probe. Measured:
    #
    #   printf -- '- Fixed the \\-\\-verbose flag when the pane is narrow\n
    #              - Fixed the --verbose flag when the pane is narrow\n' \
    #     | sed 's/\\\([[:punct:]]\)/\1/g' | sort -u | wc -l   ->  1
    #
    # Two inputs, one output. Driven against the real `safe` path, an entry
    # appearing NOWHERE in the ledger in any form was ACCEPTED at rc 0
    # because its escaped-only twin's ledger line satisfied the probe.
    #
    # AND #1131's OWN PROPOSED REMEDY DOES NOT WORK. It suggests "normalising
    # to a canonical form on both sides would remove the class". Both sides
    # ALREADY are normalised by this same canonical map — that is what the
    # two `_cl_unescape_md` call sites do — and it changes nothing, because
    # the map is non-injective BY REQUIREMENT: its entire job is to identify
    # `\-\-verbose` with `--verbose`. Any map that stops identifying them
    # re-opens #867. So no canonicalisation removes the class; the collision
    # is inherent to the identification the check is asked to make.
    #
    # WHAT ACTUALLY REMOVES IT is multiplicity — see the probe loop below. If
    # K distinct entries in a release collapse to one probe, the ledger must
    # contain that probe K times. That preserves the #867 identification
    # exactly and still refuses the case where one ledger line is made to
    # answer for two entries.
    _cl_unescape_md() { sed 's/\\\([[:punct:]]\)/\1/g'; }
    local ledger_norm
    ledger_norm=$(sed 's/[[:space:]][[:space:]]*/ /g' "$ledger" | _cl_unescape_md)

    local total_m=0 total_n=0 summary="" m n sup_m entry probe missing miss_shown
    local short_probe divergent
    for ver in "${releases[@]}"; do
        m=$(_cl_entry_count "$fetched" "$ver")

        # The caller's copy must BE the upstream copy for this section.
        # Without this, `--changelog-evidence` is decoration: a truncated
        # hand-edit passes every other check in this function (measured —
        # 2.1.223 cut from 19 bullets to 5 was accepted at rc 0).
        if ! diff -q <(_cl_entries "$fetched" "$ver") <(_cl_entries "$file" "$ver") \
                >/dev/null 2>&1; then
            sup_m=$(_cl_entry_count "$file" "$ver")
            _cl_done
            note "REFUSED: your --changelog-evidence does not match the changelog this run fetched, for release $ver — you have $sup_m entries, the fetched copy has $m. What you read is not what the fetch returned: re-fetch and re-read. (This is the check that makes the counts below mean anything; do not route around it by adjusting N.)"
            return 1
        fi

        n="${disp_of[$ver]:-}"
        if [[ -z "$n" ]]; then
            _cl_done
            note "REFUSED: release $ver is in the delta ($installed → $candidate) but carries no --changelog-dispositioned $ver=<N>. A multi-release jump means EVERY release's changelog, not just the candidate's — the 2.1.224 round read one table and left nine entries across two releases unaccounted for. $ver has $m entries in the fetched changelog."
            return 1
        fi
        if (( n != m )); then
            _cl_done
            note "REFUSED: release $ver — dispositioned $n of $m entries. Every entry needs an explicit disposition, including the ones that map to no surface ('no nexus surface' IS a disposition; silence is not). M is counted from the changelog this run fetched, not from your file. (Where those bytes came from is NOT established — see the provenance note at the top of this file.)"
            return 1
        fi

        # The teeth on N: every entry, verbatim, in the ledger.
        #
        # On a miss, re-probe with a SHORTER prefix and say which of the two
        # things went wrong (your-org/nexus-code#867). "Does not appear" and
        # "appears but diverges after character K" are different problems with
        # different fixes — the first means an entry went unconsidered, the
        # second means the ledger paraphrased or re-wrapped one that was. The
        # single undifferentiated message sent evaluators hunting for entries
        # they had already dispositioned.
        missing=0; miss_shown=""; divergent=0
        # PROBE MULTIPLICITY (your-org/nexus-code#1131 residual 1). How many
        # DISTINCT entries of this release collapse to each probe. Normally
        # every count is 1 and the check below is exactly the old existence
        # test; where two entries collide — escape-only twins, or a shared
        # first CHANGELOG_PROBE_CHARS — one ledger line can no longer answer
        # for both.
        local -A _probe_mult=()
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            probe=$(printf '%s' "$entry" | sed 's/[[:space:]][[:space:]]*/ /g' \
                        | _cl_unescape_md | cut -c1-"$CHANGELOG_PROBE_CHARS")
            _probe_mult["$probe"]=$(( ${_probe_mult["$probe"]:-0} + 1 ))
        done < <(_cl_entries "$fetched" "$ver")
        local _want _have
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            probe=$(printf '%s' "$entry" | sed 's/[[:space:]][[:space:]]*/ /g' \
                        | _cl_unescape_md | cut -c1-"$CHANGELOG_PROBE_CHARS")
            _want=${_probe_mult["$probe"]:-1}
            # `grep -cF --` counts MATCHING LINES; the ledger is one line per
            # entry, so lines are the right unit. `--` because a probe can
            # begin with `-` and would otherwise be read as an option
            # (CLAUDE.md's dash-pattern-option trap: silent, rc 0, and it
            # reads STDIN instead).
            _have=$(grep -cF -- "$probe" <<<"$ledger_norm")
            [[ "$_have" =~ ^[0-9]+$ ]] || _have=0
            (( _have >= _want )) && continue
            missing=$(( missing + 1 ))
            short_probe=$(printf '%s' "$probe" | cut -c1-"$CHANGELOG_SHORT_PROBE_CHARS")
            if grep -qF -- "$short_probe" <<<"$ledger_norm"; then
                divergent=$(( divergent + 1 ))
                (( missing <= 3 )) && miss_shown+="${miss_shown:+ | }DIVERGES after ~${CHANGELOG_SHORT_PROBE_CHARS}c: ${probe}"
            else
                (( missing <= 3 )) && miss_shown+="${miss_shown:+ | }ABSENT: ${probe}"
            fi
        done < <(_cl_entries "$fetched" "$ver")
        if (( missing > 0 )); then
            _cl_done
            note "REFUSED: release $ver claims $n of $m entries dispositioned, but $missing of those $m entries do not appear verbatim in the ledger ($ledger) — $(( missing - divergent )) ABSENT, $divergent PRESENT BUT NOT BYTE-IDENTICAL. First $(( missing < 3 ? missing : 3 )) of $missing: $miss_shown. An ABSENT entry means it went undispositioned — that is what this check is for. A DIVERGES entry was dispositioned and then paraphrased, re-wrapped or re-quoted; copy the changelog line unaltered. Markdown backslash escapes are normalised on both sides by this check, so a backslash-only difference is not the cause — but note that normalisation is many-to-one, so if two entries of this release differ ONLY by escapes the ledger needs a line for EACH (your-org/nexus-code#1131)."
            return 1
        fi

        total_m=$(( total_m + m )); total_n=$(( total_n + n ))
        summary+="${summary:+,}$ver=$n/$m"
    done
    _cl_done

    # What this line may say is bounded by what was actually established:
    # the counts, and that they were taken from the changelog this run
    # read. NOT where those bytes came from — see the provenance note.
    CHANGELOG_SUMMARY="dispositioned $total_n of $total_m entries across ${#releases[@]} release(s): $summary (release set = the registry's published versions in the delta; M counted from the changelog this run read; provenance NOT established)"
    note "changelog completeness accepted: $CHANGELOG_SUMMARY"
    return 0
}

# ---- deployment gate (your-org/nexus-code#512) -----------------------------

# _gate_default_pr_probe — print "number<TAB>path" lines, one per file of
# every open PR on $GATE_REPO. rc non-zero on any query failure (mint,
# network, gh) — the caller treats that as "cannot establish the restart
# path is unclaimed" and DEFERS, per the fail-safe contract. Overridable
# via CC_AUTO_GATE_PR_CMD (tests; also lets an operator wire a cache).
_gate_default_pr_probe() {
    local token
    token=$("$MINT_CMD") || return 1
    [[ -n "$token" ]] || return 1
    GH_TOKEN="$token" "$GH_CMD" pr list --repo "$GATE_REPO" --state open \
        --json number,files \
        --jq '.[] | .number as $n | .files[].path | "\($n)\t\(.)"'
}

# _gate_live_agent_windows — print the live tmux window names that count
# as agents-at-risk (everything except the orchestrator, this routine's
# own evaluator + watchdog windows, and the GATE_WINDOW_EXEMPT set).
#
# rc 0 = the board was ENUMERATED (the printed list may legitimately be
#        empty: every window was exempt).
# rc 1 = the board could NOT be enumerated. It used to be `|| return 0`,
#        which handed the caller an empty list at rc 0 — so a tmux that
#        failed, or was missing, read as "zero agents in flight" and
#        cleared the gate. That is a confident zero standing in for
#        "could not look", inside the gate that authorises restarting
#        the watcher and the orchestrator (your-org/nexus-code#1113).
#        An EMPTY raw list is refused for the same reason and is not a
#        pedantic case: this script runs inside a tmux window, so a tmux
#        reporting no windows at all has malfunctioned.
_gate_live_agent_windows() {
    local names w e keep
    names=$("$TMUX_CMD" list-windows -F '#{window_name}' 2>/dev/null) || return 1
    [[ -n "${names//[[:space:]]/}" ]] || return 1
    while IFS= read -r w; do
        [[ -n "$w" ]] || continue
        # Transient `•bell` phantoms are not windows an agent occupies
        # (your-org/nexus-code#1492). Dropped BEFORE the exemption loop, and
        # before anything classifies the name: a phantom reads `unreadable`
        # from pane-state, `_gate_window_may_hold_state` correctly refuses to
        # call an unreadable window quiet, and (until the board arms were
        # removed on 2026-09-12) a fully-evidenced bump then deferred on a
        # window that does not exist. Measured 2026-09-08T04:11:29-07:00 on
        # candidate 2.1.263: `unquiet_windows=[w226=busy,•bell=unreadable]`,
        # `live_windows=2` where the true agent count was 1. Today the same
        # phantom would only corrupt the RECORD, which is still worth fixing
        # here: the record is what a post-hoc reader trusts.
        #
        # FIXED HERE, NOT AT THE CLASSIFIER. The default-deny arm in
        # `_gate_window_may_hold_state` is #1113's whole point and must not be
        # weakened even as a recorder; the defect is that the phantom entered
        # the population being classified at all.
        bk_is_transient_window_name "$w" && continue
        keep=1
        for e in "$TARGET_WINDOW" "$WATCHDOG_WINDOW" "$CC_AUTO_WINDOW"; do
            [[ "$w" == "$e" ]] && { keep=0; break; }
        done
        if (( keep )); then
            local IFS=','
            for e in $GATE_WINDOW_EXEMPT; do
                [[ "$w" == "$e" ]] && { keep=0; break; }
            done
        fi
        (( keep )) && printf '%s\n' "$w"
    done <<<"$names"
    return 0
}

# _gate_default_pr_activity_probe — print "number<TAB>updated-at" lines,
# one per OPEN PR on $GATE_REPO, where updated-at is an ISO-8601 stamp.
# rc non-zero on any query failure; the caller DEFERS on that, exactly as
# it does for the restart-path probe. Overridable via
# CC_AUTO_GATE_PR_ACTIVITY_CMD.
#
# A second `gh pr list` rather than a third field on the restart-path
# probe's lines: that probe's contract is `number<TAB>path`, and a reader
# that TOLERATED a missing third field would be a permissive default
# arm — the shape this whole issue is about. A separate seam fails
# closed by construction, and this runs once a day.
_gate_default_pr_activity_probe() {
    local token
    token=$("$MINT_CMD") || return 1
    [[ -n "$token" ]] || return 1
    GH_TOKEN="$token" "$GH_CMD" pr list --repo "$GATE_REPO" --state open \
        --json number,updatedAt --jq '.[] | "\(.number)\t\(.updatedAt)"'
}

# _gate_window_may_hold_state <pane-state> — rc 0 iff this window might
# still hold in-flight state a restart would destroy.
#
# `! bk_pane_asserts_dead`, and the delegation is the point. #771 settled
# which of the two default-deny duals answers a question of this shape:
# for "is anybody still on this?", the dangerous act is asserting that
# NOBODY is, so an unestablished reading must not produce that assertion.
# `bk_pane_kill_authorized` is the WRONG dual here and reading its rc 0 as
# "gone" gets it exactly backwards — `idle` is kill-authorised, and an
# idle skeptic that has delivered one verdict and is waiting for the next
# delta is the single most re-pinnable state there is.
#
# So `absent` is the only quiet verdict. Since 2026-09-12 this predicate
# feeds the apply RECORD only (`unquiet_windows=[…]`), not a veto — the
# operator removed the board arms on a measured premise (knob block at the
# top of this file). The default-deny shape is kept on purpose: a record
# that calls an unknown state "quiet" is the same defect one level down.
_gate_window_may_hold_state() {
    bk_pane_asserts_dead "${1-}" && return 1
    return 0
}

# _gate_pane_state <window-name> — print the pane-state verdict token for
# a window NAME, or nothing when it could not be established. Resolves
# the name to an INDEX first: pane-state.sh handed a NAME by this script's
# historical Step-5b path printed a usage message and exited 2 with EMPTY
# stdout, and an empty verdict here must mean "could not look", never
# "quiet".
_gate_pane_state() {
    local name="${1-}" idx raw st=""
    idx=$(_resolve_target_index "$name")
    [[ -n "$idx" ]] || return 0
    raw=$("$PANE_STATE_CMD" "$idx" 2>/dev/null) || raw=""
    # A bash match, not `| sed | head`: a pipeline's status is its LAST
    # command's, and an early-closing `head` under pipefail reports 141
    # for a perfectly good read.
    [[ "$raw" =~ state=([a-z-]+) ]] && st="${BASH_REMATCH[1]}"
    case "$raw" in *queued=1*) st="queued" ;; esac
    printf '%s' "$st"
}

# _gate_defer_streak_bump — increment and print the count of CONSECUTIVE
# deferred fires; _gate_defer_streak_clear resets it. A gate that never
# clears is indistinguishable from a gate that is not there, and the
# tightening this issue adds makes that outcome more reachable, not less
# — so the deferral has to be as loud as the apply.
# ONE BUMP PER GATE RUN. With the bounded override an arm can return 0 and a
# LATER arm can still defer, so `_gate_defer` runs twice in a single fire. A
# naive bump would then count one fire as two, inflating the streak toward its
# own cap — a counter that accelerates because of the mechanism it feeds.
# `_gate_defer_run_streak` is cleared at the top of `_deployment_gate`.
_gate_defer_run_streak=""
_gate_defer_streak_bump() {
    local f="$AUTO_DIR/gate-defer-streak" n=0
    if [[ -n "$_gate_defer_run_streak" ]]; then
        printf '%s\n' "$_gate_defer_run_streak"
        return 0
    fi
    [[ -f "$f" ]] && n=$(tr -dc '0-9' < "$f" 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    n=$(( n + 1 ))
    mkdir -p "$AUTO_DIR" 2>/dev/null || true
    printf '%s\n' "$n" > "$f" 2>/dev/null || true
    # The streak START, for the AGE bound. Written only when the streak
    # begins, so a long run of deferrals keeps its original timestamp; a
    # bound that reset every fire would never expire, which is the defect
    # the bound exists to close. Absent/garbage reads as "starts now" —
    # the SAFE direction, since it can only DELAY an override.
    local sf="$AUTO_DIR/gate-defer-streak-since"
    if (( n == 1 )) || [[ ! -s "$sf" ]]; then
        printf '%s\n' "$(date +%s)" > "$sf" 2>/dev/null || true
    fi
    _gate_defer_run_streak="$n"
    printf '%s\n' "$n"
}
_gate_defer_streak_clear() {
    rm -f "$AUTO_DIR/gate-defer-streak" "$AUTO_DIR/gate-defer-streak-since" 2>/dev/null || true
}

# _gate_defer_streak_age — seconds since the current streak began, or empty
# when it cannot be established. EMPTY IS NOT ZERO and is not a large
# number either: the caller treats an unreadable age as "age bound not
# met", so a broken clock or a missing file can never TRIP an override.
# "I could not tell" must not become "long enough".
_gate_defer_streak_age() {
    local sf="$AUTO_DIR/gate-defer-streak-since" t now
    [[ -s "$sf" ]] || return 0
    t=$(tr -dc '0-9' < "$sf" 2>/dev/null || true)
    [[ "$t" =~ ^[0-9]+$ ]] || return 0
    now=$(date +%s 2>/dev/null) || return 0
    [[ "$now" =~ ^[0-9]+$ ]] || return 0
    (( now < t )) && return 0
    printf '%s' "$(( now - t ))"
}

# ---------------------------------------------------------------------------
# INSTRUMENT FAILURE IS A DEFECT TO FILE, NOT A VERDICT
# (OPERATOR DIRECTIVE, your-org/nexus-code#1492, operator 2026-09-08)
# ---------------------------------------------------------------------------
#
# > "if testing is not passed or the watcher finds an issue we should not
# >  simply give up, but find the issue, file it and consider fixing it."
#
# Three of this gate's then-FIVE arms fired when a QUERY ERRORED rather than
# when a hazard was present, and each returned early — so a broken instrument
# silently became a board-wide block, and the arms BELOW it (then including
# the one that measured the board directly) never ran at all. "I could not tell, so I
# will not act" reads as caution; what it actually does is convert the gate's
# own blindness into a verdict about the candidate.
#
# WHAT REPLACES IT, AND THE CUT THAT DECIDES WHICH ARM GETS WHICH TREATMENT.
# The cut is NOT reversible-vs-irreversible — that framing was checked against
# the code and does not survive it. `rollback_pin` (:1953) restores the prior
# pin, but it is LOCAL to cmd_safe with both call sites BEFORE the watcher
# restart, so it covers install failure and post-install verify mismatch and
# nothing after them. Measured at 77181f33: watcher-restart failure (rc 6),
# watchdog-never-armed (rc 22) and stale-session-pin (rc 21) all leave the NEW
# pin standing with no rollback, and there is no externally-invocable rollback
# verb. Above all, THE RESTART ITSELF IS NOT REVERSIBLE IN THE WAY THAT
# MATTERS: a killed worker's in-flight context is gone, and no pin restore
# returns it.
#
# So the cut USED TO BE which instrument measures the irreversible hazard:
# `_gate_live_agent_windows` plus the per-window state read measured it
# DIRECTLY and their failure stayed a hard DEFER, while the two PR probes
# measure PROXIES (the comment on arm 2b says so in as many words — "recency
# of `updatedAt` is itself a PROXY") and degrade to UNMEASURED and CONTINUE.
#
# SINCE 2026-09-12 THE BOARD IS RECORD-ONLY (operator decision; the knob block
# at the top of this file carries the sentence and the measurement behind it),
# so EVERY instrument failure now degrades the same way: the arm is recorded
# UNMEASURED — `live_windows=UNMEASURED` for the board — a defect is filed,
# and the gate continues. What is unchanged is the rule that "could not look"
# is never written as "nobody is there": an unenumerable board is recorded as
# UNMEASURED, never as `live_windows=0`. Precedent for degrade-and-continue
# predates this change: #1414's `act_ok=0` path already treats an
# unanswerable age probe as UNMEASURED rather than as a reason to stop.
#
# _gate_instrument_failed <candidate> <key> <what-could-not-be-measured>
#   Records the blind spot in the audit trail, tells the operator, and files
#   (or adopts) an issue on $GATE_REPO. Returns 0 ALWAYS — this is a side
#   effect, never a predicate. A filing that fails must not become a new
#   blocking dependency, which would re-create the exact defect being fixed
#   one level up.
_gate_instrument_failed() {
    local candidate="$1" key="$2" what="$3"
    note "deployment-gate INSTRUMENT FAILURE ($key): $what. This is a DEFECT TO FILE, not a verdict on $candidate — the arm is recorded UNMEASURED and the gate continues to the arms that CAN answer (your-org/nexus-code#1492)."
    _cc_auto_log_decision "$AUTO_DIR" "$candidate" "deployment-gate-instrument-failed" \
        "key=$key unmeasured=1 $what"
    notify "cc-auto-update: deployment-gate instrument '$key' could not answer — recorded UNMEASURED, filing a defect; the gate continues on the arms that can"
    _gate_file_defect "$candidate" "$key" "$what" || true
    return 0
}

# _gate_record_unfiled <candidate> <key> <why> — THE FILER'S OWN FAILURE MUST
# BE VISIBLE (w227 skeptic F2).
#
# THE DEPENDENCY SET IS THE DEFECT. `_gate_file_defect` needs the token mint
# AND `gh`; the two probes whose failure triggers it need the mint and `gh`
# TOO. So the filer's dependencies are a SUPERSET of the probes', and in the
# dominant failure cause — the mint is down, or the network is — the arms
# degrade and the "file it" half CANNOT RUN. Measured by the w227 skeptic: a
# natural mint failure degraded both proxies, applied at rc 0, and filed ZERO
# issues.
#
# That is not merely a bug. operator's directive on your-org/nexus-code#1492 was
# "do not simply give up — find the issue, file it and consider fixing it." A
# degrade that files nothing is the give-up the directive was aimed at, wearing
# better clothes.
#
# WHAT THIS DOES NOT DO: it does not make filing a precondition of the gate.
# That would re-create the exact defect being fixed one level up — an
# instrument failure becoming a blocker. Instead the UNFILED state is made
# durable, loud, counted, and RETRIED on the next fire, so "we could not tell
# anyone" is itself a thing somebody can see. A filer that silently files
# nothing is the same class as everything else in this file.
_gate_record_unfiled() {
    local candidate="$1" key="$2" why="$3"
    local dir="$AUTO_DIR/gate-defects" bc="$AUTO_DIR/gate-defects/$key.UNFILED"
    mkdir -p "$dir" 2>/dev/null || true
    local n=0
    if [[ -f "$bc" ]]; then
        n=$(awk -F'attempts=' 'NF>1{print $2+0; exit}' "$bc" 2>/dev/null)
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
    fi
    n=$(( n + 1 ))
    printf 'key=%s why=%s first_seen=%s attempts=%s\n' \
        "$key" "$why" "$(date -Is 2>/dev/null || echo unknown)" "$n" > "$bc.tmp" 2>/dev/null \
        && mv -f "$bc.tmp" "$bc" 2>/dev/null || rm -f "$bc.tmp" 2>/dev/null
    note "deployment-gate: could NOT file the '$key' defect — $why. THE BLIND SPOT IS NOW DOUBLE: the instrument could not answer AND nobody was told. Attempt $n; recorded at $bc and retried on the next fire. File it by hand on $GATE_REPO if this persists."
    _cc_auto_log_decision "$AUTO_DIR" "$candidate" "deployment-gate-defect-UNFILED" \
        "key=$key attempts=$n why=$why"
    notify "cc-auto-update: deployment-gate defect '$key' could NOT be filed ($why) — attempt $n. The gate degraded AND the report failed; nobody has been told but you."
    return 0
}

# _gate_unfiled_count — how many distinct defect keys are sitting UNFILED.
# Surfaced in the gate's audit row so a filer that has silently stopped working
# is visible from the record rather than only from a log nobody reads.
_gate_unfiled_count() {
    local d="$AUTO_DIR/gate-defects" n
    [[ -d "$d" ]] || { printf '0'; return 0; }
    n=$(find "$d" -maxdepth 1 -name '*.UNFILED' -type f 2>/dev/null | wc -l)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# _gate_file_defect <candidate> <key> <what> — file, or adopt, ONE issue per
# distinct instrument failure. Never returns non-zero to a caller that could
# act on it.
#
# DEDUP IS THE WHOLE DESIGN. This routine fires DAILY, so a filer with no
# idempotency key opens a fresh issue every morning for one broken instrument
# — spam that trains the operator to ignore exactly the channel this directive
# created. The key is a local breadcrumb under $AUTO_DIR/gate-defects/<key>
# plus a marker comment in the issue body, so an operator who deletes the
# breadcrumb re-adopts the open issue rather than duplicating it.
#
# SAFE IN FIXTURES BY CONSTRUCTION, not by a flag anyone can forget: the mint
# must succeed before `gh` is reached, and a test root's $MINT_CMD points at a
# mint-token.sh that does not exist there. A fixture therefore aborts at the
# mint with a note, having touched no network. `CC_AUTO_GATE_ISSUE_CMD` is the
# seam for a test that wants to ASSERT the filing rather than merely be safe
# from it; it receives <key> <title> <body-file>.
_gate_file_defect() {
    local candidate="$1" key="$2" what="$3"
    local dir="$AUTO_DIR/gate-defects" bc="$AUTO_DIR/gate-defects/$key"
    mkdir -p "$dir" 2>/dev/null || true

    # Cooldown: a still-open filed defect is not re-filed, and the repeat is
    # counted rather than announced. A number that goes up is the honest
    # record of a persistent blind spot; N identical issues is not.
    if [[ -f "$bc" ]]; then
        local age now mt
        now=$(date +%s); mt=$(stat -c %Y "$bc" 2>/dev/null || echo 0)
        age=$(( now - mt ))
        if [[ "$age" =~ ^[0-9]+$ ]] && (( age < GATE_DEFECT_REFILE_SECONDS )); then
            local n head
            # No `|| echo 0`. awk prints NOTHING and exits 0 on a file with no
            # match, so the fallback would never fire — and a fallback that
            # manufactures a value is the shape the count-fallback lint exists
            # to stop, even where the lint's axis (`grep -c`) does not reach it.
            # The SHAPE check on the next line is the real guard: it rejects
            # empty, and an emptiness check is a presence test wearing a
            # validity test's name.
            n=$(awk -F'count=' 'NF>1{print $2+0; exit}' "$bc" 2>/dev/null)
            [[ "$n" =~ ^[0-9]+$ ]] || n=0
            # STRIP the existing `count=` before re-emitting it. Appending
            # instead of replacing yields `… count=1 count=2`, which the awk
            # above then reads back as 1 forever — a counter frozen at its
            # first value while LOOKING like it is being maintained.
            head=$(sed -n '1s/ *count=[0-9]*//p' "$bc" 2>/dev/null)
            [[ -n "$head" ]] || head=$(sed -n 1p "$bc" 2>/dev/null)
            note "deployment-gate: instrument defect '$key' already filed ($head); repeat $(( n + 1 )), not re-filing (cooldown ${GATE_DEFECT_REFILE_SECONDS}s)"
            printf '%s count=%s\n' "$head" "$(( n + 1 ))" > "$bc.tmp" 2>/dev/null \
                && mv -f "$bc.tmp" "$bc" 2>/dev/null
            return 0
        fi
    fi

    local marker="<!-- cc-auto-gate-defect: $key -->"
    local title="cc-auto-update deployment gate: instrument '$key' could not answer"
    local body
    if ! body=$(mktemp 2>/dev/null) || [[ -z "$body" ]]; then
        _gate_record_unfiled "$candidate" "$key" "mktemp failed — could not compose the issue body"
        return 0
    fi
    {
        printf '%s\n\n' "$marker"
        printf '## What\n\n'
        printf 'A deployment-gate instrument returned a query failure during the autonomous cc-auto-update fire.\n\n'
        printf -- '- **key**: `%s`\n' "$key"
        printf -- '- **could not be measured**: %s\n' "$what"
        printf -- '- **candidate at the time**: `%s`\n' "$candidate"
        printf -- '- **gate repo**: `%s`\n\n' "$GATE_REPO"
        printf '## Why this is an issue and not a deferral\n\n'
        printf 'Per the operator directive on your-org/nexus-code#1492: a check that cannot\n'
        printf 'answer is a DEFECT TO FILE, not merely a reason to stop. The arm was recorded\n'
        printf 'UNMEASURED and the gate continued on the arms that could answer. Since\n'
        printf '2026-09-12 no arm vetoes on the board itself (operator decision, recorded in\n'
        printf 'the deployment-gate header of `monitor/cc-auto-update-apply.sh`); the board is\n'
        printf 'still enumerated and written to the apply record, so an UNMEASURED board row\n'
        printf 'here means the record for that fire is blind, not that the bump was unsafe.\n\n'
        printf 'The arm was recorded UNMEASURED in `monitor/.state/cc-auto-update/decisions.tsv`\n'
        printf '(row `deployment-gate-instrument-failed`). Grep that key for the repeat count.\n\n'
        printf '## Where\n\n'
        printf '`monitor/cc-auto-update-apply.sh` — `_deployment_gate`, and the probe behind\n'
        printf 'the named key. Filed automatically by `_gate_file_defect`.\n'
    } > "$body"

    local out="" num=""
    if [[ -n "${CC_AUTO_GATE_ISSUE_CMD:-}" ]]; then
        out=$("$CC_AUTO_GATE_ISSUE_CMD" "$key" "$title" "$body" 2>&1) || out=""
        num=$(grep -oE '[0-9]+$' <<<"$out" | tail -1)
    else
        local token
        if ! token=$("$MINT_CMD" 2>/dev/null) || [[ -z "$token" ]]; then
            _gate_record_unfiled "$candidate" "$key" "token mint failed"
            rm -f "$body"; return 0
        fi
        # Adopt an existing OPEN issue carrying the marker before creating one.
        local found
        found=$(GH_TOKEN="$token" "$GH_CMD" issue list --repo "$GATE_REPO" --state open \
                    --search "$marker" --json number --jq '.[0].number' 2>/dev/null || true)
        if [[ "$found" =~ ^[0-9]+$ ]]; then
            num="$found"
            note "deployment-gate: instrument defect '$key' already open as $GATE_REPO#$num — adopted, not duplicated"
        else
            out=$(GH_TOKEN="$token" "$GH_CMD" issue create --repo "$GATE_REPO" \
                      --title "$title" --body-file "$body" 2>&1) || out=""
            num=$(grep -oE '[0-9]+$' <<<"$out" | tail -1)
        fi
    fi
    rm -f "$body"

    if [[ "$num" =~ ^[0-9]+$ ]]; then
        # `owner/repo#N`, the QUALIFIED form. A bare number, or a `/`
        # separator, is a reference whose repo is supplied by whoever reads it
        # — the defect monitor/issue-ref.sh exists to refuse. The two log lines
        # below already used `#`; this one did not, and the two records of one
        # fact would have disagreed.
        printf 'issue=%s#%s first=%s count=1\n' "$GATE_REPO" "$num" "$(date -Is)" > "$bc" 2>/dev/null || true
        # A retry that SUCCEEDED clears the unfiled marker, so the backlog
        # count means "still unreported" rather than "ever failed".
        rm -f "$bc.UNFILED" 2>/dev/null || true
        note "deployment-gate: instrument defect '$key' filed as $GATE_REPO#$num"
        _cc_auto_log_decision "$AUTO_DIR" "$candidate" "deployment-gate-defect-filed" \
            "key=$key issue=$GATE_REPO#$num"
        notify "cc-auto-update: deployment-gate instrument defect '$key' filed as $GATE_REPO#$num"
    else
        _gate_record_unfiled "$candidate" "$key" "the create/adopt call returned no issue number"
    fi
    return 0
}

# _gate_defer <candidate> <detail> <human-message> — the ONE deferral
# exit. Every `return 1` in _deployment_gate goes through it, so no
# deferral can be added later that skips the streak accounting.
# _gate_defer <candidate> <detail> <human-message> [<overridable>]
#
# rc 1 — DEFER: the caller returns 1 and the apply does not happen.
# rc 0 — this arm's veto is BOUNDED AND HAS EXPIRED: the caller CONTINUES
#        into the remaining arms. It is NOT "proceed", and it never skips a
#        later arm; the board arms run last and still get the final word.
#
# <overridable> defaults to 0 (DENY). An arm added later is non-overridable
# until its author opts in, so the permissive path can never be reached by
# forgetting about it — the allowlist discipline in CLAUDE.md, applied to the
# one verdict here that is permissive.
_gate_defer() {
    local candidate="$1" detail="$2" msg="$3" overridable="${4:-0}" streak age
    streak=$(_gate_defer_streak_bump)
    [[ "$streak" =~ ^[0-9]+$ ]] || streak=1
    age=$(_gate_defer_streak_age)

    # THE OVERRIDE IS EVALUATED FIRST BUT ANNOUNCES ITSELF AS AN OVERRIDE,
    # never as an absence of a hazard: the hazard was measured and is recorded
    # below either way, so the audit row of an overridden fire still names it.
    if [[ "$overridable" == 1 ]] \
       && { (( GATE_DEFER_STREAK_CAP > 0 && streak >= GATE_DEFER_STREAK_CAP )) \
            || { [[ -n "$age" ]] && (( GATE_DEFER_MAX_AGE_SECONDS > 0 && age >= GATE_DEFER_MAX_AGE_SECONDS )); }; }; then
        note "OVERRIDE deployment-gate: $msg — but this arm measures a PROXY for the restart hazard, and its veto is bounded (streak=$streak cap=$GATE_DEFER_STREAK_CAP age=${age:-unreadable}s max_age=${GATE_DEFER_MAX_AGE_SECONDS}s). A busy board may DELAY the update, not PREVENT it (operator directive, your-org/nexus-code#1492). Continuing into the remaining arms; the board is enumerated and RECORDED on the way, and since 2026-09-12 it vetoes nothing (operator decision — see the deployment-gate header)."
        # ONE SPELLING IN BOTH ROW TYPES (w231sk round 2, R3). This row used to
        # write `cap=`/`max_age=` while the deferral row wrote
        # `defer_cap=`/`defer_max_age=` eight lines away — and `cap=` is a
        # SUBSTRING of `defer_cap=`, so `grep -o 'cap=[0-9]*'` silently matched
        # both row types and conflated them. That is worse than a clean
        # mismatch, and it undercut the one-line ledger check this field exists
        # to support. If you add a third row type, use these same keys.
        record_outcome "$candidate" "safe-deferred-overridden" \
            "$detail gate_defer_streak=$streak defer_streak_age=${age:-unreadable}s defer_cap=$GATE_DEFER_STREAK_CAP defer_max_age=${GATE_DEFER_MAX_AGE_SECONDS}s"
        _cc_auto_log_decision "$AUTO_DIR" "$candidate" "deployment-gate-defer-override" \
            "streak=$streak age=${age:-unreadable}s $detail"
        notify "cc-auto-update: the deployment gate deferred ${streak}× in a row on a PROXY arm and its bound has expired — that arm no longer vetoes the $candidate bump. The board state is recorded in the apply record, not gated on (operator decision 2026-09-12)."
        return 0
    fi

    note "DEFER: $msg"
    # THE BOUND'S OWN PARAMETERS GO IN THE DEFERRAL ROW, not only in the
    # override row. F4 of the w231sk round 1 pass was that the cap shipped at a
    # value the recorded streak distribution could never reach, and the only way
    # to find that out was to read the code and the ledger together.
    #
    # WHAT THIS DOES AND DOES NOT BUY — two limits, because the claim beside
    # these fields was previously unqualified (w231sk round 2, R4):
    #
    #   * IT IS PROSPECTIVE ONLY. Measured: `defer_cap=` appears on 0 of the
    #     253 pre-existing rows, `gate_defer_streak=` on 7. For any window
    #     before this change the answer still requires reading the source, so
    #     "the ledger is now sufficient" is true going FORWARD and false about
    #     the corpus the defect was actually found in.
    #   * `max(streak) < defer_cap` IS NOT "UNREACHABLE". It is equally what a
    #     HEALTHY gate that keeps clearing looks like. The check separates
    #     "cannot fire" from "has not fired yet" only when the streak
    #     distribution is read against how often the gate CLEARED — 33 applies
    #     against 11 deferrals here.
    #
    # So these fields are a DIAGNOSTIC AID, not the safety property. The safety
    # property is GATE_DEFER_STREAK_CAP_FLOOR, which no configuration can go
    # under.
    if (( GATE_DEFER_STREAK_CAP_CLAMPED )); then
        note "WARN deployment-gate: configured defer-streak cap was below the floor of $GATE_DEFER_STREAK_CAP_FLOOR and has been RAISED to it. A cap of 1 overrides on the first deferral — zero delay — which is not a bound. This clamp is deliberate and is recorded in the audit row (defer_cap_clamped=1)."
    fi
    record_outcome "$candidate" "safe-deferred" \
        "$detail gate_defer_streak=$streak defer_cap=$GATE_DEFER_STREAK_CAP defer_max_age=${GATE_DEFER_MAX_AGE_SECONDS}s defer_cap_clamped=$GATE_DEFER_STREAK_CAP_CLAMPED overridable=$overridable"
    notify "cc-auto-update: $candidate is safe but the apply is DEFERRED — $msg"
    if (( streak >= GATE_DEFER_STREAK_ALERT )); then
        note "WARN deployment-gate: this is deferral $streak in a row — the autonomous update has not applied since the streak began. Both remaining arms are PR arms: merge or close the PR that keeps firing, wait out its recency window, or apply manually. The proxy veto expires on its own at the streak cap / age bound. A gate that never clears is a routine that has silently stopped."
        _cc_auto_log_decision "$AUTO_DIR" "$candidate" "deployment-gate-defer-escalation" \
            "streak=$streak $detail"
        notify "cc-auto-update: the deployment gate has now deferred ${streak}× in a row — no autonomous update has applied"
    fi
    return 1
}

# _gate_integration_branch — the branch merged fixes actually land on.
#
# ONE claimant, and as of your-org/nexus-code#763 that is enforced BY
# CONSTRUCTION rather than by this comment asking nicely. The resolution
# chain lives in `monitor/_integration_branch.sh` and both consumers —
# this gate and the watcher's clone-drift detector — call it. Hardcoding
# `dev` here would re-instantiate #754's defect one branch over: a literal
# that is right today and silently wrong for any fork whose flow differs,
# which is precisely how `main` came to be baked in. Re-deriving the chain
# here would be worse still — two records of one property drift apart, and
# the gate and the detector would then disagree about the same clone.
#
# This wrapper survives only as the named seam the gate's evidence row
# refers to (`integration_branch=<b>`); it adds no logic of its own.
_gate_integration_branch() {
    nexus_integration_branch
}

# _deployment_gate <candidate> — rc 0: proceed. rc 1: DEFER the apply
# (nothing bumped; the caller records + exits 30).
#
# A DEFERRAL IS A COMPLETE RESULT ONLY WHEN IT NAMES A HAZARD
# (your-org/nexus-code#1492). The retracted form of this comment read
# "every deferral is a complete result — the verdict stands recorded and
# the next daily fire retries once conditions clear", and that sentence is
# what encoded the give-up: it makes a deferral produced by the gate's own
# blindness indistinguishable from one produced by a measured hazard, and
# it makes an unbounded RUN of deferrals read as a run of successes.
#
# THE ARMS ARE A CONJUNCTION SAMPLED ONCE A DAY, so P(clear) falls with
# every arm added and no single arm need ever be wrong for the routine to
# stop delivering. There are TWO `_gate_defer` arms since 2026-09-12 (five
# before; "seven" never) — re-derive with
# `grep -cE '^\s*(if ! )?_gate_defer "' "$0"` (anchored, so this comment's own
# mention does not count itself — the bare `grep -c '_gate_defer "'` form
# that stood here over-counted by exactly one for that reason), and read the
# knob block at the top of this file for why the three board arms went. Measured on this nexus, decisions.tsv, 2026-06-16 to 2026-09-12:
# 33 applies, 12 deferrals, spread across FOUR arms —
#
#   restart-path PR        5      (proxy, overridable — STILL AN ARM)
#   PR-under-active-review 3      (proxy, overridable — STILL AN ARM)
#   live-window COUNT      2      (REMOVED 2026-09-12; count still recorded)
#   board-not-quiet        2      (REMOVED 2026-09-12; states still recorded)
#   board-enumeration      0      (REMOVED 2026-09-12; never fired in either record)
#
# THE COUNT AND BOARD-NOT-QUIET ARMS ARE LISTED SEPARATELY ON PURPOSE, even
# now that both are gone: an earlier draft folded them into one "live-windows
# 3" bucket, and the ledger is what a future reader re-derives from.
#
# Four consecutive fires (09-07 .. 09-10) deferred on THREE different arms, so
# fixing the arm that fired last time is not a fix for the streak; #1492 fixed
# the 09-08 arm and 09-09 deferred on another. The 09-10 fire deferred on
# `pr-under-active-review=PR1506` — the very PR that adds this bound.
#
# `gate-defer-streak` is this bound's CONTROL INPUT: `_gate_defer` reads it and
# expires a proxy arm's veto at the cap. Before this change it was bumped,
# printed and cleared and read by nothing, which is what the GUIDE means by
# "a gate that reliably announces it is blocking is still blocking" — loudness
# was the wrong remedy. Detail: skills/nexus.cc-update/GUIDE.md, "When the gate
# is right and the pin still has not moved".
#
# THE STREAK IS GLOBAL, NOT PER-ARM, AND THAT IS A CHOICE. A streak earned on
# one proxy arm therefore expires the OTHER proxy arm on its first fire.
# That is deliberate: the operator's complaint is "the pin has not moved", not
# "this arm keeps firing", and the measured board hops between arms — a
# per-arm counter would have reset on 09-08 and again on 09-09 and never
# reached any cap. The cost is that a first-ever fire of one proxy arm can be
# overridden on the strength of the other arm's history. Pinned by
# test-cc-auto-update.sh case O6.
#
# Also records clone staleness (nexus-code#511's actual gap):
# `decisions.tsv` used to read `target-window-unresolved=…` as if it were
# a code bug while the live clone was 114 commits behind the fix. One
# `behind_integration=N` field collapses that whole misdiagnosis class.
# Staleness is WARN-only, deliberately: a stale clone runs the stale
# apply.sh regardless, so a defer here could never have protected the
# incident tree — surfacing is what was missing.
#
# THE MEASUREMENT IS DELEGATED, NOT RE-IMPLEMENTED (nexus-code#754). This
# gate used to hand-roll `fetch origin main` + `rev-list HEAD..origin/main`,
# which was wrong three separate ways, all of the same shape — a check
# answering a question nobody asked:
#
#   1. WRONG BRANCH. PRs on this repo merge to the INTEGRATION branch;
#      `main` lags it by weeks. Measured on the live primary at HEAD
#      f0c9510: 5 behind `main`, 23 behind `dev`. Among those 23 was the
#      #747 merge installing `monitor/_pane-live.sh` — the #745 guard whose
#      absence lets a watcher paste kill the tmux server and take the whole
#      sandbox down with it. The gate said "5 behind, proceed" about a clone
#      missing the guard that makes the restart it authorizes survivable.
#   2. STALE REMOTE-TRACKING REF. The fetch was `|| true`, and `rev-list`
#      against `origin/<b>` then answers CONFIDENTLY from whatever the last
#      successful fetch left behind. Measured on a fixture: after a failed
#      fetch it reported `behind=5` as fact when the true distance was 11.
#      A wrong number, not an `unknown`.
#   3. `unknown` WAS SILENT. `[[ $behind =~ ^[0-9]+$ ]]` guarded the WARN,
#      so "I could not measure" emitted no warning and no notification at
#      all — indistinguishable from "up to date". That is #740's thesis
#      ("could not look" collapsing into "nothing was wrong") living inside
#      #754's gate.
#
# `_clone_drift_probe` (#620) already solves all three: it resolves the tip
# from a LIVE `ls-remote` rather than a tracking ref, and returns a
# TRICHOTOMY — `up-to-date` / `behind` / `unknown` — in which `unknown` is a
# distinct, loud outcome. Two mechanisms answering "is this clone stale" is
# one too many; this is the collapse, and the watcher's is the survivor.
_deployment_gate() {
    _gate_defer_run_streak=""
    local candidate="$1"

    # 1. Clone staleness (warn + record, never defer).
    #
    # OPERATOR DIRECTIVE, your-org/nexus-code#1475 (operator, 2026-09-06):
    # "The update should not depend on nexus-code being the latest version.
    # If the local cc test pass, it can and should be updated." So this arm
    # is BY POLICY informational and must stay so: the verdict on a candidate
    # is the LOCAL gate's (the classifier production actually runs, on the
    # tree whose pin moves), and how far this clone sits behind the
    # integration branch is a fact recorded beside it, never a reason to
    # defer, refuse, or wait. PREVIOUS BEHAVIOUR, stated because it is what
    # the directive corrects: the code here already only warned, but the
    # evaluator FRAMED a local RED whose control run against the remote tip
    # was GREEN as "blocked on the un-pulled clone" and waited for an
    # operator pull (#1475's title) — a bump gated on nexus-code freshness in
    # prose where the code gated on nothing. GUIDE Step 4 carries the rule.
    #
    # AND THE ROUTINE NEVER TOUCHES REMOTE NEXUS-CODE (your-org/nexus-code
    # #1529, operator directive 2026-09-14: "the automatic cc-update should
    # never involve an automatic update of the nexus-code code … many people
    # can push to this resource (especially not from the dev branch!)").
    # The gate is run only against the live clone's own checked-out code.
    # Nothing on the automatic path pulls, merges, checks out, clones,
    # worktrees or executes any other nexus-code tree, from any branch; the
    # control that re-ran the gate in a throwaway tree at the remote tip is
    # RETIRED. `test-cc-update-no-remote-code.sh` reddens if any of those
    # operations against a remote ref enters this file, the drive, the
    # prompts, the harness or the GUIDE.
    local branch; branch=$(_gate_integration_branch)
    local drift="unknown" behind="unknown" reason=""
    if [[ -d "$NEXUS_ROOT/.git" ]] && command -v git >/dev/null 2>&1; then
        # Best-effort fetch so the margin is measurable without a network
        # round-trip per commit. Correctness does NOT depend on it: the
        # probe takes the tip from a live `ls-remote` either way, so a
        # failed fetch degrades the MARGIN to `unknown`, never the VERDICT
        # to a stale number.
        #
        # WHY THIS FETCH IS SAFE UNDER #1529: `git fetch` updates
        # remote-tracking REFS only. It writes nothing into the working
        # tree or the index, moves no branch, and executes nothing from the
        # objects it downloads — the code that runs after this line is
        # byte-for-byte the code that ran before it. It exists to REPORT
        # "N commits behind", never to bring anything in.
        timeout 10 git -C "$NEXUS_ROOT" fetch --quiet origin "$branch" >/dev/null 2>&1 || true
        local line; line=$(_clone_drift_probe "$NEXUS_ROOT" "$branch")
        drift=$(_clone_drift_field "$line" verdict)
        case "$drift" in
            up-to-date) behind=0 ;;
            behind)     behind=$(_clone_drift_field "$line" commits) ;;
            *)          drift="unknown"; behind="unknown"
                        reason=$(_clone_drift_field "$line" reason) ;;
        esac
    else
        reason="no_git_or_not_a_clone"
    fi
    # Three outcomes, three messages. "behind by an unmeasured margin" is
    # NOT the same finding as "could not tell whether it is behind" — the
    # first is a proven staleness, the second an unproven one.
    # THE COMMAND NAMES THE SAME REF THE DRIFT WAS MEASURED AGAINST — the
    # configured integration branch, as a VARIABLE, never a literal
    # (your-org/nexus-code#1529, w241sk F3: a hard-coded `main` was a no-op
    # pull on a dev-tracking primary, and the words around it prescribed a
    # checkout of main there — which CLAUDE.md forbids under a running
    # watcher and which would have regressed it by every dev-only commit).
    # Which branch operators deploy from is `monitor.integration_branch`, an
    # operator configuration decision; its default is untouched here. Text
    # for a human — nothing here pulls, and nothing prescribes a checkout.
    # The variable form is pinned by test-cc-update-no-remote-code.sh.
    local head_branch; head_branch=$(git -C "$NEXUS_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    local head_note=""
    if [[ -n "$head_branch" && "$head_branch" != "HEAD" && "$head_branch" != "$branch" ]]; then
        head_note=" NOTE: this clone is checked out on $head_branch, not $branch — align monitor.integration_branch with the branch you deploy from before pulling."
    fi
    if [[ "$drift" == "behind" ]] && [[ "$behind" =~ ^[0-9]+$ ]] && (( behind > 0 )); then
        note "WARN deployment-gate: this clone is $behind commits behind origin/$branch — the apply.sh executing right now may predate merged fixes. Deploy (branch = monitor.integration_branch): git -C $NEXUS_ROOT pull --ff-only origin $branch${head_note}"
        notify "cc-auto-update: clone is $behind commits behind origin/$branch — merged fixes are not deployed"
    elif [[ "$drift" == "behind" ]]; then
        note "WARN deployment-gate: this clone DIFFERS from origin/$branch but the margin could not be measured — the apply.sh executing right now may predate merged fixes. Deploy (branch = monitor.integration_branch): git -C $NEXUS_ROOT pull --ff-only origin $branch${head_note}"
        notify "cc-auto-update: clone differs from origin/$branch (margin unmeasured) — merged fixes may not be deployed"
    elif [[ "$drift" != "up-to-date" ]]; then
        note "WARN deployment-gate: COULD NOT DETERMINE whether this clone is behind origin/$branch (reason=${reason:-unspecified}). 'Could not look' is NOT 'up to date' — treat this apply as running on a possibly-stale tree."
        notify "cc-auto-update: could not determine clone staleness vs origin/$branch (${reason:-unspecified}) — staleness is UNVERIFIED, not clean"
    fi

    # 2. Open PRs touching the watcher restart path. The restart being
    #    under repair is EXACTLY when an autonomous restart must not fire
    #    (2026-07-10: the evaluator restarted the watcher while PR #503 —
    #    open precisely because that restart path decapitates — sat
    #    unmerged with 15 agents mid-flight).
    local ev="behind_integration=$behind integration_branch=$branch drift=$drift"
    # DEGRADE, DO NOT DEFER (your-org/nexus-code#1492 — see the
    # instrument-failure block above `_gate_defer`). This arm measures a PROXY
    # ("an open PR touches one of five named files") for the in-flight-agent
    # hazard. When its instrument cannot answer, deferring here RETURNED EARLY
    # and suppressed the board record below, so a broken `gh` became a
    # stronger blocker than a busy board. The blind spot is recorded, filed,
    # and carried into the evidence string; the gate continues.
    local pr_lines pr_probe="ok"
    if ! pr_lines=$("${CC_AUTO_GATE_PR_CMD:-_gate_default_pr_probe}" 2>/dev/null); then
        pr_lines=""; pr_probe="UNMEASURED"
        _gate_instrument_failed "$candidate" "restart-path-pr-query" \
            "could not query open PRs on $GATE_REPO — whether the watcher restart path is under repair is UNKNOWN, not clear"
    fi
    ev="$ev restart_path_pr_probe=$pr_probe"
    local hits="" prn path gp
    while IFS=$'\t' read -r prn path; do
        [[ -n "$prn" && -n "$path" ]] || continue
        local IFS=','
        for gp in $GATE_RESTART_PATHS; do
            if [[ "$path" == "$gp" ]]; then
                case " $hits " in *" PR$prn "*) ;; *) hits="${hits:+$hits }PR$prn" ;; esac
            fi
        done
    done <<<"$pr_lines"
    # #1414: a restart-path hit counts only while the PR is ALIVE — touched
    # within GATE_RESTART_PR_ACTIVE_SECONDS. Ages come from the activity
    # probe; when it cannot answer, every hit is treated as live (fail-closed),
    # which is exactly the pre-#1414 behaviour. Stale hits are recorded in the
    # evidence so the exemption is visible, never silent.
    local stale_hits="" live_hits="" act_probe="" act_ok=1 hp hage
    if [[ -n "$hits" ]]; then
        if act_probe=$("${CC_AUTO_GATE_PR_ACTIVITY_CMD:-_gate_default_pr_activity_probe}" 2>/dev/null); then
            act_ok=1
        else
            act_ok=0
        fi
        local IFS=' '
        for hp in $hits; do
            hage=""
            if (( act_ok == 1 )); then
                local _u
                _u=$(awk -F'\t' -v n="${hp#PR}" '$1==n{print $2; exit}' <<<"$act_probe")
                if [[ -n "$_u" ]]; then
                    local _ue
                    _ue=$(date -d "$_u" +%s 2>/dev/null) || _ue=""
                    [[ -n "$_ue" ]] && { hage=$(( $(date +%s) - _ue )); (( hage < 0 )) && hage=0; }
                fi
            fi
            if [[ -n "$hage" ]] && (( hage > GATE_RESTART_PR_ACTIVE_SECONDS )); then
                stale_hits="${stale_hits:+$stale_hits,}${hp}(${hage}s)"
            else
                live_hits="${live_hits:+$live_hits }${hp}"
            fi
        done
        unset IFS
        if [[ -n "$stale_hits" ]]; then
            ev="$ev stale-restart-path-pr=${stale_hits} restart_pr_active_window=${GATE_RESTART_PR_ACTIVE_SECONDS}s"
            # AN AGED-OUT EXEMPTION IS ANNOUNCED, not only recorded (#1449
            # skeptic): a decision that lives only in decisions.tsv and the
            # apply log is read by nobody — the #1400 shape, inside the PR
            # that closes #1400. The operator learns that a restart-path PR
            # stopped blocking BEFORE the bump proceeds on that basis.
            _cc_auto_log_decision "$AUTO_DIR" "$candidate" "restart-path-pr-aged-out" "${stale_hits} window=${GATE_RESTART_PR_ACTIVE_SECONDS}s"
            notify "cc-auto-update: restart-path PR(s) ${stale_hits} untouched longer than ${GATE_RESTART_PR_ACTIVE_SECONDS}s — NO LONGER blocking the ${candidate} bump (stalled, not under repair; #1414). If one of them IS a live repair, touch it or hold the routine."
        fi
    fi
    if [[ -n "$live_hits" ]]; then
        if ! _gate_defer "$candidate" "deferred-pending-${live_hits// /,} $ev" \
            "open PR(s) touch the watcher restart path ($live_hits on $GATE_REPO, touched within ${GATE_RESTART_PR_ACTIVE_SECONDS}s) — the restart mechanics are under repair. This deferral NAMES A HAZARD, which is what makes it a complete result; see gate-defer-streak for whether it is one of a run." 1
        then
            return 1
        fi
    fi

    # 2b. Open PRs UNDER ACTIVE REVIEW — orthogonal to the path list
    #     (your-org/nexus-code#1113). Whether a PR is being reviewed right
    #     now has nothing to do with which files it touches, and the 2026-08-28
    #     board had three of them at zero path hits.
    #
    #     STATED HONESTLY: recency of `updatedAt` is itself a PROXY for
    #     "under active review" — weaker than the per-window board read
    #     below, which since 2026-09-12 is RECORDED rather than gated on. It
    #     is here because it is orthogonal and nearly free, not because it is
    #     the property.
    # DEGRADE, DO NOT DEFER — same reasoning as arm 2, and this arm's own
    # comment above already concedes it is the weaker proxy of the two. An
    # arm that admits it does not carry the property must not, when its
    # instrument breaks, block the bump.
    local act_lines act_probe_state="ok"
    if ! act_lines=$("${CC_AUTO_GATE_PR_ACTIVITY_CMD:-_gate_default_pr_activity_probe}" 2>/dev/null); then
        act_lines=""; act_probe_state="UNMEASURED"
        _gate_instrument_failed "$candidate" "pr-activity-query" \
            "could not establish whether any open PR on $GATE_REPO is under active review — 'could not look' is not 'nobody is reviewing'"
    fi
    ev="$ev pr_activity_probe=$act_probe_state"
    local now_epoch active_prs="" upd upd_epoch age
    now_epoch=$(date +%s)
    while IFS=$'\t' read -r prn upd; do
        [[ -n "$prn" && -n "$upd" ]] || continue
        upd_epoch=$(date -d "$upd" +%s 2>/dev/null) || upd_epoch=""
        if [[ -z "$upd_epoch" ]]; then
            # An unparseable stamp is NOT "old". Fail closed on the row.
            active_prs="${active_prs:+$active_prs }PR${prn}(unparseable-ts)"
            continue
        fi
        age=$(( now_epoch - upd_epoch ))
        (( age < 0 )) && age=0
        (( age <= GATE_PR_ACTIVE_SECONDS )) \
            && active_prs="${active_prs:+$active_prs }PR${prn}(${age}s)"
    done <<<"$act_lines"
    if [[ -n "$active_prs" ]]; then
        if ! _gate_defer "$candidate" "pr-under-active-review=${active_prs// /,} pr_active_window=${GATE_PR_ACTIVE_SECONDS}s $ev" \
            "open PR(s) on $GATE_REPO were touched within ${GATE_PR_ACTIVE_SECONDS}s ($active_prs) — a review may be in flight at a pinned ref; restarting now would break it" 1
        then
            return 1
        fi
    fi

    # 3. Live agent windows — ENUMERATED AND RECORDED, NOT GATED ON.
    #
    #    Until 2026-09-12 this was the gate's DIRECT instrument and three
    #    arms lived here: the count above `max_live_windows` deferred, any
    #    window not positively asserting it was dead (`bk_pane_asserts_dead`)
    #    deferred, and an unenumerable board deferred. The operator removed
    #    all three on a measured premise — the restart path kills no worker,
    #    and a crashed worker is continued via `spawn-worker.sh --resume` —
    #    quoted and detailed in the knob block at the top of this file.
    #
    #    WHAT SURVIVES, AND WHY IT IS NOT DEAD CODE. The apply record is the
    #    surface a post-hoc reader uses to ask "who was mid-task when this
    #    fired?", so the count and every window's state still land in the
    #    `deployment-gate` row exactly as before (`live_windows=`,
    #    `unquiet_windows=[w=state,…]`). The classification keeps its
    #    default-deny shape — `absent` is the only state written as quiet,
    #    an unreadable or unresolvable window is written `unreadable` — because
    #    a record that quietly calls an unknown state "quiet" is the same
    #    defect one level down. "Could not look" is never written as zero: an
    #    enumeration failure records `live_windows=UNMEASURED` and files a
    #    defect, and the gate continues.
    local windows count board_probe="ok"
    if ! windows=$(_gate_live_agent_windows); then
        windows=""; count="UNMEASURED"; board_probe="UNMEASURED"
        _gate_instrument_failed "$candidate" "board-enumeration" \
            "could not enumerate tmux windows — the apply record for this fire carries live_windows=UNMEASURED (the board is recorded, not gated on, since 2026-09-12)"
    else
        count=$(awk 'NF { n++ } END { print n+0 }' <<<"$windows")
    fi

    local unquiet="" w st
    while IFS= read -r w; do
        [[ -n "$w" ]] || continue
        st=$(_gate_pane_state "$w")
        if _gate_window_may_hold_state "$st"; then
            unquiet="${unquiet:+$unquiet }${w}=${st:-unreadable}"
        fi
    done <<<"$windows"

    # `none` vs `UNMEASURED` is not cosmetic. A row reading `restart_path_prs=
    # none` when the probe never answered is a confident zero standing in for
    # "could not look" — this file's own dominant defect class — and it is
    # written to the permanent audit trail a later reader reconstructs the
    # decision from. Reaching this line no longer implies either probe
    # succeeded, so the row must say which.
    local _rp_field="none" _ar_field="none" _unfiled
    [[ "$pr_probe"        == "UNMEASURED" ]] && _rp_field="UNMEASURED"
    [[ "$act_probe_state" == "UNMEASURED" ]] && _ar_field="UNMEASURED"
    # The UNFILED backlog rides the same row (w227 skeptic F2). A filer whose
    # dependencies are down reports nothing BY CONSTRUCTION, so its silence is
    # indistinguishable from "nothing to report" unless the count is carried
    # somewhere a reader already looks.
    _unfiled=$(_gate_unfiled_count)
    if [[ "$_unfiled" != "0" ]]; then
        note "WARN deployment-gate: $_unfiled instrument defect(s) recorded but NOT FILED — the gate degraded and nobody was told. See $AUTO_DIR/gate-defects/*.UNFILED"
    fi
    if [[ -n "$unquiet" ]]; then
        note "deployment-gate: $(awk '{print NF}' <<<"$unquiet") live agent window(s) do not positively assert they are gone ($unquiet) — RECORDED, not a veto (operator decision 2026-09-12: the restart path kills no worker; a crashed worker resumes via spawn-worker.sh --resume)"
    fi
    note "deployment-gate: live agent windows=$count unquiet=[${unquiet:-none}] board_probe=$board_probe $ev restart-path PRs: $_rp_field, active-review PRs: $_ar_field"
    _cc_auto_log_decision "$AUTO_DIR" "$candidate" "deployment-gate" \
        "live_windows=$count unquiet_windows=[${unquiet// /,}] board_probe=$board_probe $ev restart_path_prs=$_rp_field active_review_prs=$_ar_field unfiled_defects=$_unfiled"

    _gate_defer_streak_clear
    return 0
}

# _watcher_restart_invariant <old_pid> <old_pgid> — post-restart invariant
# (nexus-code#512 item 3): survivors of the OLD watcher's process group
# must be 0, and at most one live watcher group may exist for this root.
# "The restart happened to be clean" is not evidence that it is safe —
# emit the invariant and fail LOUD when violated, instead of discovering
# a duplicate-emit storm later. Read-only (ps); never kills anything.
# rc 0 = holds (or unobservable — WARNed, not failed); rc 1 = violated.
_watcher_restart_invariant() {
    local old_pid="$1" old_pgid="$2"
    command -v ps >/dev/null 2>&1 || {
        note "WARN restart-invariant: ps unavailable — invariant unobservable"
        return 0
    }
    # Give TERM'd stragglers of the old group a bounded settle window
    # (tries tunable for tests via CC_AUTO_INVARIANT_TRIES).
    local tries=0 survivors=0 ps_out
    local max_tries="${CC_AUTO_INVARIANT_TRIES:-5}"
    while :; do
        ps_out=$(ps -eo pgid=,pid=,args= 2>/dev/null || true)
        survivors=0
        if [[ "$old_pgid" =~ ^[0-9]+$ ]]; then
            survivors=$(awk -v g="$old_pgid" '$1 == g { n++ } END { print n+0 }' <<<"$ps_out")
        fi
        (( survivors == 0 )) && break
        (( tries >= max_tries )) && break
        tries=$(( tries + 1 ))
        sleep 2
    done
    # Distinct live watcher groups for THIS root — absolute-path match on
    # the args column (never a suffix: /tmp test fixtures stay invisible).
    local groups
    groups=$(awk -v p="$NEXUS_ROOT/monitor/watcher/main.sh" \
        'index($0, p) { print $1 }' <<<"$ps_out" | sort -u | grep -c . || true)
    [[ "$groups" =~ ^[0-9]+$ ]] || groups=0
    if (( survivors > 0 )) || (( groups > 1 )); then
        note "restart-invariant VIOLATED: old-pgid(${old_pgid:-?}) survivors=$survivors, live watcher groups=$groups (want 0 and exactly 1) — two watchers racing monitor/.state is the #491/#503 decapitation class"
        return 1
    fi
    if (( groups == 0 )); then
        # The launcher's own post-spawn verification owns "did it come
        # up"; an empty match here is a fixture/probe limitation, not a
        # duplicate hazard — WARN, do not fail.
        note "WARN restart-invariant: no live watcher group matched $NEXUS_ROOT/monitor/watcher/main.sh (unobservable in this environment); survivors=0 held"
    else
        note "restart-invariant holds: old-group survivors=0, exactly one live watcher group"
    fi
    return 0
}

# ---- live-tree drift assertion (your-org/nexus-code#1002) -----------------
#
# THE CAUSE-AGNOSTIC CONTROL. Every other guard in this file prevents one KNOWN
# wrong path; this one detects the OUTCOME: the live binary must report the
# version the nexus believes it is running, before any verb writes a verdict
# down. On 2026-08-25 an ad-hoc `cd <dir> && npm install` — cwd-dependent, so
# npm walked UP to the nexus root's package.json — put a gate-RED 2.1.245 into
# the LIVE node_modules for a measured ~25 s (inside a ~37 s window in which
# `node_modules/.bin/claude` was twice ABSENT), and the fire went on to record
# `block` with the drift entirely undetected. Nothing errored: rc 0, `changed
# 2 packages`, and `git status` clean under --no-save. The staging fixes
# (gate.sh --keep-prefix, cch_stage_candidate) make the KNOWN wrong path
# unnecessary; this makes every path to a drifted tree LOUD.
#
# BOTH SIDES MUST RESOLVE. An unreadable binary is not a match, and an
# unresolvable pin is not a match — the hand-written `|| cat <pin-file>` form
# recorded on #1004 makes both sides EMPTY on an absent pin file and passes.
# So the pin must parse as a version, the binary must print one, and they
# must be equal; anything else refuses. Same regex and same `head -1` as the
# post-install verify below, deliberately: one vocabulary for "what version
# is this binary".
#
# WHAT IT RECORDS, AND WHY THOSE TOKENS. `decision` is a field that SELECTS
# (`_cc_auto_last_eval_skip` matches block|compat-pr-*; the #1400 surfacing
# matches safe-refused), so no new outcome token is minted here:
#   safe        → the CALLER records `safe-refused` with this detail — an
#                 existing token whose reader nags the operator daily, which
#                 is what a refusal for an environmental reason needs.
#   block /     → the CALLER writes NO record_outcome. No verdict was reached,
#   compat-pr     so last-eval must not say one was — Guard 4 would otherwise
#                 skip the candidate tomorrow on a verdict never recorded. An
#                 append-only audit row labelled `live-tree-drift` goes in
#                 instead. That label is matched by nothing: the readers of
#                 decisions.tsv column 3 were enumerated before adding it
#                 (`safe-refused` in _cc_auto_update.sh and record_outcome;
#                 the restart-outcome FILE, not this column, for the abort
#                 streak). Add a matcher before you give it a meaning.
#
# Returns 0 when live == effective (noted, so apply.log carries the "live
# tree OK" line every fire); else notes the remedy, notifies, sets
# LIVE_TREE_DRIFT_DETAIL and returns 1 — the caller records and exits 9.
LIVE_TREE_DRIFT_DETAIL=""
_assert_live_tree() {
    local verb="$1" candidate="$2" effective="" live=""
    effective=$(cc_version_effective "$NEXUS_ROOT/package.json" "$PACKAGE" "$NEXUS_ROOT" 2>/dev/null) || effective=""
    [[ "$effective" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || effective=""
    live=$("$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [[ -n "$effective" && -n "$live" && "$live" == "$effective" ]]; then
        note "$verb: live tree OK — $CLAUDE_BIN reports $live, equal to the effective pin"
        return 0
    fi
    LIVE_TREE_DRIFT_DETAIL="live-tree-drift live=${live:-unreadable} effective=${effective:-unresolvable} bin=$CLAUDE_BIN"
    note "REFUSED ($verb): LIVE TREE DRIFT — $CLAUDE_BIN reports '${live:-<nothing>}' but the effective pin is '${effective:-<unresolvable>}'. The live node_modules does not hold the version this nexus believes it is running, so NO verdict about $candidate is recorded on it. Restore first: $INSTALL_CMD (reinstalls the effective pin), confirm with \`$CLAUDE_BIN --version\`, then re-run this verb — and say in your report that the drift happened and what caused it (your-org/nexus-code#1002). [$LIVE_TREE_DRIFT_DETAIL]"
    notify "cc-auto-update: LIVE TREE DRIFT — binary reports ${live:-nothing}, effective pin is ${effective:-unresolvable}; $verb for $candidate REFUSED until $INSTALL_CMD restores the tree (#1002)"
    return 1
}

cmd_safe() {
    local candidate="" gate_evidence="" surfaces_clear=0
    local changelog_evidence="" changelog_ledger=""
    local no_restart=0 no_orch_restart=0
    SURFACE_EVIDENCE=(); NEGATIVE_CONTROLS=(); CHANGELOG_DISPOSITIONS=()
    while (( $# > 0 )); do
        case "$1" in
            --candidate)         candidate="$2"; shift 2 ;;
            --gate-evidence)     gate_evidence="$2"; shift 2 ;;
            --surfaces-clear)    surfaces_clear=1; shift ;;
            --surface-evidence)  SURFACE_EVIDENCE+=("$2"); shift 2 ;;
            --negative-control)  NEGATIVE_CONTROLS+=("$2"); shift 2 ;;
            --changelog-evidence)      changelog_evidence="$2"; shift 2 ;;
            --changelog-ledger)        changelog_ledger="$2"; shift 2 ;;
            --changelog-dispositioned) CHANGELOG_DISPOSITIONS+=("$2"); shift 2 ;;
            # ---- DECOMPOSITION (your-org/nexus-code#1400) ----------------
            # `safe` welded FOUR operations into one verb: pin, install,
            # watcher restart, orchestrator restart. Only the RESTARTS carry
            # the #1113 hazard, and the deployment gate's TIMING arms defer on
            # board activity — so on an actively-worked nexus those arms block
            # the PIN, which is inert for in-flight state. Measured: the pin
            # lives in monitor/.state/cc-version-local and the binary in
            # node_modules/, and _version_restart.sh's two source sets
            # (:145-160, :167-176) are SHELL FILES ONLY with zero references to
            # either — so pin+install produces no hash drift and no
            # self-restart. `cmd_safe` already names the intermediate state at
            # the watcher-restart failure arm: "pin + install stand (new binary
            # active for future spawns), NOT proceeding to orchestrator
            # restart". These flags make that state REQUESTABLE instead of
            # only reachable by failure. Defaults are unchanged.
            --no-restart)              no_restart=1; shift ;;
            --no-orchestrator-restart) no_orch_restart=1; shift ;;
            *) note "safe: unknown arg $1"; exit 2 ;;
        esac
    done
    [[ -n "$candidate" ]] || { note "safe: --candidate required"; exit 2; }

    # Live-tree drift (your-org/nexus-code#1002) — asserted FIRST. Every
    # refusal below is a statement about the CANDIDATE's evidence; this one is
    # about the TREE, and a verdict on a drifted tree is not a verdict. Also
    # ahead of the idempotency no-op further down: a pin already at the
    # candidate over a binary that is not is a torn install, and "nothing to
    # do" there would be the manufactured-success shape.
    if ! _assert_live_tree safe "$candidate"; then
        record_outcome "$candidate" "safe-refused" "$LIVE_TREE_DRIFT_DETAIL"
        exit 9
    fi

    # Guards — every refusal leaves the pin untouched.
    if (( surfaces_clear != 1 )); then
        note "REFUSED: --surfaces-clear attestation missing. Pass it ONLY after the changelog review cleared the non-gate surfaces (GUIDE 2c VI-mode / 2d hooks+settings / 2e CLI flags)."
        record_outcome "$candidate" "safe-refused" "no-surfaces-clear"
        exit 3
    fi
    if [[ -z "$gate_evidence" ]] || ! _check_gate_evidence "$gate_evidence" "$candidate"; then
        # The refusal REASON goes in the row. `gate-evidence` alone cannot be
        # told apart from any other gate-evidence refusal by a later reader,
        # and un-attributable audit rows are #1259's subject.
        record_outcome "$candidate" "safe-refused" "gate-evidence${GATE_EVIDENCE_REFUSAL:+:$GATE_EVIDENCE_REFUSAL}"
        exit 3
    fi
    # --surfaces-clear used to be a BARE attestation: `apply.sh:506` set a
    # flag, `:514` refused without it, and it verified nothing at all. Five
    # of six evaluation rounds then laundered a reachability argument into
    # "I tested it" through that flag. It now requires the evidence CLASS
    # per surface, and cross-checks the checkable ones. See the function.
    if ! _check_surface_evidence "$gate_evidence"; then
        record_outcome "$candidate" "safe-refused" "surface-evidence"
        exit 3
    fi
    # Append-only audit row (does NOT touch last-eval, which must keep
    # naming the terminal decision): what was claimed, per surface.
    _cc_auto_log_decision "$AUTO_DIR" "$candidate" "surface-evidence" \
        "$SURFACE_EVIDENCE_SUMMARY"

    # The effective version is BOTH the idempotency check below and the
    # lower bound of the changelog delta, so resolve it once, here.
    local effective
    effective=$(cc_version_effective "$NEXUS_ROOT/package.json" "$PACKAGE" "$NEXUS_ROOT" 2>/dev/null || true)

    # Idempotency: already on the candidate → success no-op. This sits
    # BEFORE the changelog check on purpose: a re-run against a bump that
    # already landed must stay a clean no-op, and the delta
    # (candidate, candidate] is empty, which the check would (correctly,
    # but unhelpfully) refuse.
    if [[ "$effective" == "$candidate" ]]; then
        note "safe: effective version is already $candidate — nothing to do"
        exit 0
    fi

    # Changelog completeness: every entry of every release in the delta,
    # each with an explicit disposition, counted against the fetched
    # changelog rather than asserted — the delta itself being what the
    # registry publishes. See the function. rc 2 is the OPAQUE-release
    # arm (your-org/nexus-code#1007) and gets its own exit code, 8: unlike
    # every rc-1 arm, nothing the evaluator supplies can clear it. The
    # detail carries the #1007 reason when there is one and is otherwise
    # the pre-existing bare token, so older rows and their readers are
    # unchanged.
    local cl_rc=0
    _check_changelog_completeness "$changelog_evidence" "$changelog_ledger" \
        "$effective" "$candidate" || cl_rc=$?
    if (( cl_rc == 2 )); then
        record_outcome "$candidate" "safe-refused" "changelog-completeness:${CHANGELOG_REFUSAL}"
        # The bound on exit 8: AFTER the row is written (so this fire counts),
        # BEFORE the exit; never changes either. `|| true` — a side effect
        # must not become a new failure mode on the refusal path.
        _cl_opaque_escalate "$candidate" "changelog-completeness:${CHANGELOG_REFUSAL}" \
            "${CHANGELOG_REFUSAL#opaque-release=}" || true
        exit 8
    elif (( cl_rc != 0 )); then
        record_outcome "$candidate" "safe-refused" "changelog-completeness${CHANGELOG_REFUSAL:+:$CHANGELOG_REFUSAL}"
        exit 3
    fi
    _cc_auto_log_decision "$AUTO_DIR" "$candidate" "changelog-completeness" \
        "$CHANGELOG_SUMMARY"

    # Single-flight lock (mkdir is atomic; stale-lock recovery is manual
    # by design — a torn apply needs eyes, not a silent re-run).
    mkdir -p "$AUTO_DIR" 2>/dev/null || true
    if ! mkdir "$AUTO_DIR/apply.lock" 2>/dev/null; then
        note "REFUSED: $AUTO_DIR/apply.lock held — another apply in flight (or a crashed one; inspect, then rmdir)"
        exit 7
    fi
    trap 'rmdir "$AUTO_DIR/apply.lock" 2>/dev/null || true' EXIT

    # ---- deployment gate (nexus-code#512): is restarting SAFE right now?
    # Runs before any state mutation, so a deferral leaves nothing
    # half-applied. Distinct from the release gate above: that one vetted
    # the BINARY; this one vets the ACT of deploying it.
    # your-org/nexus-code#1438 (1): under --no-restart NO restart of any kind
    # runs, and every arm of _deployment_gate guards a RESTART (an open
    # restart-path PR, a PR under active review; until 2026-09-12 also the
    # live-window count and board-quiet arms). #1425's own stated purpose
    # for the flag was to make the pin REQUESTABLE on an actively-worked nexus
    # where those arms would otherwise defer it — "the pin is inert for
    # in-flight state" — and measured, the gate still deferred `safe
    # --no-restart` identically to the bare verb (rc 30, no pin), so the
    # motivating case was unreachable. Under --no-orchestrator-restart the
    # watcher restart still runs, so the gate stays.
    if (( no_restart )); then
        note "safe: --no-restart — deployment gate SKIPPED: its arms guard restarts and none will run (your-org/nexus-code#1438)"
        # The streak clear for this path is NOT here — see the pin write below.
        # It used to be, and that cleared the streak on INTENT rather than on
        # delivery: an install or pin-write failure after this point wiped a
        # streak that represented real consecutive deferrals (w231sk round 2,
        # R6). Safe for the override (a lower streak only DELAYS it) and unsafe
        # for observability, which is the half that matters here — the
        # escalation counter reset having delivered nothing.
    elif ! _deployment_gate "$candidate"; then
        exit 30
    fi

    # ---- GUIDE Step 5: pin bump + local install + watcher restart ----
    # Snapshot prior pin for rollback.
    local prior_pin had_prior=0
    if prior_pin=$(cc_version_read_local_pin "$NEXUS_ROOT" 2>/dev/null); then
        had_prior=1
    fi
    rollback_pin() {
        if (( had_prior == 1 )); then
            cc_version_write_local_pin "$prior_pin" "$NEXUS_ROOT" \
                && note "rollback: local pin restored to $prior_pin"
        else
            rm -f "$(cc_version_local_pin_path "$NEXUS_ROOT")" 2>/dev/null \
                && note "rollback: local pin removed (floor resumes)"
        fi
    }

    # DURABLE BREADCRUMB for the `rollback` VERB (your-org/nexus-code#1492).
    # `rollback_pin` above is LOCAL to this function and both its call sites
    # are BELOW, before the watcher restart — so it covers install failure and
    # verify mismatch and NOTHING after them. Measured at 77181f33: watcher-
    # restart failure (rc 6), watchdog-never-armed (rc 22) and stale-session-
    # pin (rc 21) each leave the NEW pin standing with no rollback and no
    # external verb to invoke. The operator's risk calculus on #1492 rests on
    # a rollback being available AFTER the restart ("if the orchestrator
    # struggles after restart, the watchdog can roll back"); this file is what
    # makes that true, because `prior_pin` is otherwise a shell local that
    # dies with the process.
    #
    # WRITTEN BEFORE THE PIN MOVES, and the order is the design: crash between
    # the two and the breadcrumb names a pin that has not moved, so a rollback
    # is a harmless no-op. The inverse order fails the other way — a moved pin
    # with no record of what preceded it is unrecoverable, and that is the
    # failure mode that must not be the reachable one.
    mkdir -p "$AUTO_DIR" 2>/dev/null || true
    {
        printf 'prior_pin=%s\n' "$( (( had_prior == 1 )) && printf '%s' "$prior_pin" || printf '<none>' )"
        printf 'candidate=%s\n' "$candidate"
        printf 'effective_before=%s\n' "${effective:-unknown}"
        printf 'written=%s\n' "$(date -Is 2>/dev/null || echo unknown)"
    } > "$AUTO_DIR/rollback-state.tmp.$$" 2>/dev/null \
        && mv -f "$AUTO_DIR/rollback-state.tmp.$$" "$AUTO_DIR/rollback-state" 2>/dev/null \
        || { rm -f "$AUTO_DIR/rollback-state.tmp.$$" 2>/dev/null
             note "WARN: could not write $AUTO_DIR/rollback-state — the \`rollback\` verb will have nothing to restore from for this bump"; }

    note "safe: bumping operator-local pin ${effective:-?} -> $candidate (gate evidence: $gate_evidence)"
    if ! cc_version_write_local_pin "$candidate" "$NEXUS_ROOT"; then
        note "FAILED: could not write local pin"
        record_outcome "$candidate" "safe-failed" "pin-write"
        exit 4
    fi

    if ! "$INSTALL_CMD"; then
        note "FAILED: install ($INSTALL_CMD) — rolling back pin; prior binary stands (install never wipes node_modules)"
        rollback_pin
        record_outcome "$candidate" "safe-failed" "install"
        notify "cc-auto-update: install of $candidate FAILED; pin rolled back"
        exit 4
    fi

    local running
    running=$("$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [[ "$running" != "$candidate" ]]; then
        note "FAILED: binary reports '$running', expected $candidate — rolling back pin"
        rollback_pin
        record_outcome "$candidate" "safe-failed" "verify running=$running"
        notify "cc-auto-update: post-install verify FAILED ($running != $candidate); pin rolled back"
        exit 5
    fi
    note "safe: install verified — binary reports $candidate"

    # A PIN THAT MOVES ENDS THE STREAK, WHICHEVER PATH MOVED IT — and "moves"
    # means the bump is COMMITTED, not merely attempted. This sits after the
    # install AND the post-install verify because every failure above this line
    # calls `rollback_pin`: a pin written and then rolled back has NOT moved,
    # and clearing the streak there resets the escalation counter for a fire
    # that delivered nothing. Two rounds of this: R6 caught the clear sitting
    # before the pin write, and case O7b then caught the fix still sitting
    # before the install — the same error one step further down. The rule is
    # the outcome, not the step: clear where the bump can no longer be undone.
    # `_deployment_gate` does its own clear on the gated path; this covers
    # `--no-restart`, which skips the gate entirely.
    _gate_defer_streak_clear

    if (( no_restart )); then
        # your-org/nexus-code#1438 (2): WITHOUT a hold the watcher's every-tick
        # reconcile (running < effective pin) re-fires the declined orchestrator
        # hand-off within one tick — under a watcher that was NOT restarted,
        # inverting the ordering this verb says must hold. The flag's promise
        # is only true of the SYSTEM if the reconcile is held.
        local _hold_note=""
        if _cc_auto_write_restart_hold "$AUTO_DIR" "safe --no-restart: restarts declined by the caller (your-org/nexus-code#1438)" "" "$candidate"; then
            _hold_note="restart-hold written (until_version=$candidate): the reconcile will NOT re-fire the hand-off. Release: $SELF_PATH unhold"
        else
            _hold_note="WARNING: restart-hold could NOT be written — the reconcile WILL re-fire the orchestrator hand-off on its next tick; write it: $SELF_PATH hold --reason 'declined' --until-version $candidate"
        fi
        note "safe: --no-restart — pin + install + verify COMPLETE and stopping here. The new binary is active for FUTURE spawns; the running watcher and orchestrator stay on the binary they started with, so the workspace is deliberately VERSION-SPLIT until the next restart. No watcher restart, no orchestrator hand-off. $_hold_note"
        record_outcome "$candidate" "safe-bumped-no-restart" "pin+install verified; restarts declined by --no-restart; ${_hold_note%%:*}"
        notify "cc-auto-update: $candidate pinned and installed (--no-restart); future spawns get it, running agents keep their binary; ${_hold_note%%:*}"
        exit 0
    fi

    # Watcher restart so the WATCHER ITSELF runs current shell source and
    # drops its in-memory loop state after a version change (GUIDE Step 5).
    # NOT — as this comment used to say — "so FUTURE spawns and the Step-5b
    # respawn load the new binary": both of those resolve CLAUDE_BIN AT CALL
    # TIME (spawn-worker.sh sources _claude-bin.sh per invocation;
    # _respawn.sh sources it inside the respawn call), so a RUNNING watcher
    # already spawns the new binary with no restart at all. Measured
    # your-org/nexus-code#1416: CLAUDE_BIN is not even set in the live
    # watcher's environment. Ordering per GUIDE: this MUST precede the
    # orchestrator kill so the watcher serving the recovery runs
    # current code. Snapshot the OLD watcher's identity first — the
    # post-restart invariant below needs it.
    local old_wpid="" old_wpgid=""
    old_wpid=$(tr -d '[:space:]' < "$STATE_DIR/watcher.pid" 2>/dev/null || true)
    [[ "$old_wpid" =~ ^[0-9]+$ ]] \
        && old_wpgid=$(ps -o pgid= -p "$old_wpid" 2>/dev/null | tr -d '[:space:]')
    local watcher_rc=0
    if [[ -n "${CC_AUTO_WATCHER_RESTART_CMD:-}" ]]; then
        # shellcheck disable=SC2086 — operator/test override is a command line
        $CC_AUTO_WATCHER_RESTART_CMD || watcher_rc=$?
    else
        "$NEXUS_ROOT/monitor/svc.sh" restart watcher || watcher_rc=$?
    fi
    if (( watcher_rc != 0 )); then
        note "FAILED: watcher restart — pin + install stand (new binary active for future spawns), NOT proceeding to orchestrator restart"
        record_outcome "$candidate" "safe-failed" "watcher-restart"
        notify "cc-auto-update: watcher restart FAILED after bump to $candidate — manual: monitor/svc.sh restart watcher"
        exit 6
    fi
    note "safe: watcher restarted onto $candidate"

    # Post-restart invariant (nexus-code#512): do not TREAT a restart as
    # clean — OBSERVE that it was. A violation means two watcher trees
    # may be racing monitor/.state; handing the orchestrator restart off
    # into that world would compound it.
    if ! _watcher_restart_invariant "$old_wpid" "$old_wpgid"; then
        record_outcome "$candidate" "safe-bumped-restart-invariant-violated" \
            "old_pid=${old_wpid:-?} old_pgid=${old_wpgid:-?}"
        notify "cc-auto-update: $candidate applied but the watcher restart VIOLATED the post-restart invariant (old-group survivors or duplicate groups) — inspect before anything else restarts"
        exit 31
    fi

    # ---- GUIDE Step 5b: orchestrator restart under watchdog ----------
    # your-org/nexus-code#1438 (3): decided HERE, above the session-pin
    # pre-flight. It used to sit below it, so a nexus with no orchestrator pin
    # — one of the natural reasons to decline the orchestrator restart — got
    # rc 21 and an outcome row saying a restart it had DECLINED was ABORTED
    # (stale-pin); the flag was honoured by accident and the record lied.
    if (( no_orch_restart )); then
        local _hold_note=""
        if _cc_auto_write_restart_hold "$AUTO_DIR" "safe --no-orchestrator-restart: orchestrator hand-off declined by the caller (your-org/nexus-code#1438)" "" "$candidate"; then
            _hold_note="restart-hold written (until_version=$candidate): the reconcile will NOT re-fire the hand-off. Release: $SELF_PATH unhold"
        else
            _hold_note="WARNING: restart-hold could NOT be written — the reconcile WILL re-fire the orchestrator hand-off on its next tick; write it: $SELF_PATH hold --reason 'declined' --until-version $candidate"
        fi
        note "safe: --no-orchestrator-restart — pin + install + watcher restart COMPLETE and stopping here. The orchestrator keeps running on its original binary until it is next restarted; nothing is killed. $_hold_note"
        record_outcome "$candidate" "safe-bumped-no-orch-restart" "pin+install+watcher-restart done; orchestrator hand-off declined; ${_hold_note%%:*}"
        notify "cc-auto-update: $candidate applied and watcher restarted (--no-orchestrator-restart); the orchestrator was NOT killed; ${_hold_note%%:*}"
        exit 0
    fi

    # Pre-flight: the session pin is the whole seamlessness story. A
    # stale/absent pin degrades the respawn to a COLD spawn (context
    # lost) — never kill in that state.
    local pin_file="$STATE_DIR/orchestrator-session-id" sid="" jsonl=""
    sid=$(tr -d '[:space:]' < "$pin_file" 2>/dev/null || true)
    if ! grep -qE "$_UUID_RE" <<<"$sid"; then
        note "ABORT restart: orchestrator session pin absent/malformed ($pin_file) — a kill now would COLD-SPAWN (context lost). Bump itself is complete."
        record_outcome "$candidate" "safe-bumped-restart-aborted" "stale-pin"
        notify "cc-auto-update: bumped to $candidate but orchestrator restart aborted (stale session pin) — workspace is version-split"
        exit 21
    fi
    jsonl="$PROJECTS_DIR/$(_slug "$NEXUS_ROOT")/$sid.jsonl"
    if [[ ! -f "$jsonl" ]]; then
        note "ABORT restart: pinned session transcript missing ($jsonl). Bump itself is complete."
        record_outcome "$candidate" "safe-bumped-restart-aborted" "missing-jsonl"
        notify "cc-auto-update: bumped to $candidate but orchestrator restart aborted (pinned transcript missing) — workspace is version-split"
        exit 21
    fi

    # ---- Hand the idle-wait → restart off to a DETACHED process ------
    # The bump (pin + install + watcher restart) is now COMPLETE and
    # stands on its own. What remains — wait for the orchestrator to be
    # idle, then context-preservingly kill+respawn it — must NOT block
    # this foreground call: the whole apply runs inside the cc-update
    # evaluator's Bash tool call, which the harness SIGTERMs at a hard
    # 600s ceiling. A blocking idle-wait there is killed mid-loop before
    # it can restart anything (the daily exit-143 failure). So disown the
    # wait+restart to a fully detached background process and RETURN
    # PROMPTLY. setsid → a new session that survives this evaluator
    # window's retirement; stdio → a log file with stdin from /dev/null
    # so the harness Bash call does not block on an open pipe; the child
    # is NOT harness-tracked. The detached `restart-orchestrator` verb
    # owns the bounded idle-wait, the force-restart-on-cap, and the
    # re-validate-before-kill. Decoupling the wait from the 600s ceiling
    # also lets the operator raise the idle cap freely so a natural idle
    # is caught first (minimizing token-repeat) without risking timeout.
    local detached_log="$AUTO_DIR/detached-restart.log"
    # Explicit mode at creation (your-org/nexus-code#484) — both branches
    # below open this log with a bare `>>`.
    _ensure_service_log "$detached_log"
    local restart_rc=0
    if [[ "${CC_AUTO_RESTART_INLINE:-0}" == "1" ]]; then
        # Test/synchronous seam: run the restart in-process, so its terminal
        # outcome is known NOW. `trap - EXIT` clears the inherited
        # apply.lock-cleanup trap so the subshell's own exit does not
        # release the lock out from under this still-running function (the
        # lock is released by the real EXIT trap when `safe` itself returns
        # just below); the subshell's OWN EXIT trap, set inside
        # cmd_restart_orchestrator, still fires and writes the outcome
        # marker. Capture the child's exit code so it can be propagated
        # below — the `&& …=0 || …=$?` form is exact without `set -e`.
        ( trap - EXIT; cmd_restart_orchestrator --candidate "$candidate" --sid "$sid" ) \
            >> "$detached_log" 2>&1 && restart_rc=0 || restart_rc=$?
    else
        setsid nohup bash "$SELF_PATH" restart-orchestrator \
            --candidate "$candidate" --sid "$sid" \
            >> "$detached_log" 2>&1 < /dev/null &
        disown 2>/dev/null || true
    fi
    note "safe: bump to $candidate complete; orchestrator restart handed off to a detached watcher (idle-wait → force-restart-on-cap; log: $detached_log)"
    record_outcome "$candidate" "safe-bumped-restart-handoff" "detached sid=$sid"
    notify "cc-auto-update: $candidate applied; orchestrator restart handed off to a detached watcher (workspace version-split until it restarts)"
    # The DETACHED path (production) cannot know the restart outcome — it is
    # a future event on a disowned process — so it exits 0 = "bump applied,
    # restart handed off" and the eventual outcome is surfaced via the
    # restart-outcome marker + abort-streak escalation. The INLINE seam DID
    # observe the outcome synchronously, so it propagates a non-zero restart
    # abort, making bump-applied-vs-restart-aborted distinguishable to a
    # synchronous caller (your-org/nexus-code#511 fix 2). In the common
    # clean-restart case restart_rc is 0, so exit 0 is unchanged.
    exit "$restart_rc"
}

# ---- verb: restart-orchestrator -----------------------------------------
# The DETACHED second half of `safe` — auto-invoked by cmd_safe via a
# disowned `bash "$0" restart-orchestrator` re-exec (and the direct
# unit-test entry point for the restart behaviours). Runs the bounded
# idle-wait and the context-preserving kill+respawn that cmd_safe
# deliberately does NOT run in its 600s-bound foreground call. Re-derives
# everything from the session pin + env, so it is self-contained across
# the re-exec. See the file-header exit-code table (0/21/22/23/24).
#
# The single kill issued anywhere here is `tmux kill-window` — never a
# cmdline-pattern kill (lint-no-mass-kill.sh).
cmd_restart_orchestrator() {
    local candidate="" sid=""
    while (( $# > 0 )); do
        case "$1" in
            --candidate) candidate="$2"; shift 2 ;;
            --sid)       sid="$2"; shift 2 ;;
            *) note "restart-orchestrator: unknown arg $1"; exit 2 ;;
        esac
    done
    # DERIVE, DO NOT MERELY REPORT (your-org/nexus-code#1400, ccwatch item 6).
    # These two usage errors notified NOBODY — #1400's own thesis reproduced
    # inside the routine the issue is about. On 2026-09-03 they fired at
    # 11:40:47 and 11:41:00, were seen by no one, and the operator's retry is
    # what created the second claimant of item 2. Deriving removes the failure
    # rather than reporting it; both values are already on disk.
    if [[ -z "$candidate" ]]; then
        candidate=$(sed -n 's/^candidate=//p' "$AUTO_DIR/last-eval" 2>/dev/null | tail -1)
        [[ -n "$candidate" ]] && note "restart-orchestrator: --candidate omitted; derived '$candidate' from $AUTO_DIR/last-eval"
    fi
    if [[ -z "$sid" ]]; then
        sid=$(tr -d '[:space:]' < "$STATE_DIR/orchestrator-session-id" 2>/dev/null || true)
        [[ -n "$sid" ]] && note "restart-orchestrator: --sid omitted; derived '$sid' from $STATE_DIR/orchestrator-session-id"
    fi
    # Still missing after derivation is a REAL failure, and it now NOTIFIES.
    if [[ -z "$candidate" ]]; then
        note "restart-orchestrator: --candidate required and could not be derived from $AUTO_DIR/last-eval"
        notify "cc-auto-update: restart-orchestrator refused — no --candidate and none derivable from last-eval"
        exit 2
    fi
    if [[ -z "$sid" ]]; then
        note "restart-orchestrator: --sid required and could not be derived from $STATE_DIR/orchestrator-session-id"
        notify "cc-auto-update: restart-orchestrator refused — no --sid and none derivable from the session pin"
        exit 2
    fi

    # Record our own PID so an operator can find/inspect/kill this disowned
    # process (it is deliberately NOT harness-tracked). BASHPID is the live
    # process PID even under the test's inline subshell.
    mkdir -p "$AUTO_DIR" 2>/dev/null || true

    # ---- SINGLE-FLIGHT, IN THE VERB (your-org/nexus-code#1400, ccwatch item 2)
    #
    # A real guard already existed — three predicates at
    # monitor/watcher/_cc_auto_update.sh:684-688 (live restart-orchestrator.pid,
    # armed marker, live watchdog window) — but it gates only the WATCHER'S
    # FIRING. This verb took no lock at all, so a hand-fire created a second
    # claimant INVISIBLY.
    #
    # That is not hypothetical. On 2026-09-03 an interactive re-fire (apply.log
    # carries `--candidate required` 11:40:47 and `--sid required` 11:41:00 —
    # the signature of a usage-error retry) produced claimant 13708 beside the
    # watcher-launched 21558. BOTH armed, and BOTH issued
    # `kill-window -t orchestrator` at 11:59:20, ONE SECOND APART. It was benign
    # only because the respawn took 15s.
    #
    # EXCLUSIVITY MUST BE A PROPERTY OF THE OPERATION, NOT OF ONE CALLER. The
    # same three predicates run here, and a real flock is held for the verb's
    # whole duration so two claimants cannot both pass them.
    #
    # flock(2) binds to the OPEN FILE DESCRIPTION and bash cannot set
    # FD_CLOEXEC on an exec-opened fd, so every child spawned while this lock
    # is held inherits fd 9 and KEEPS THE LOCK after we exit (flock-fd class,
    # your-org/nexus-code#494; lint monitor/watcher/test-flock-fd-cloexec.sh).
    # This path spawns children by design — the watchdog spawn, tmux clients,
    # pane-state.sh (which backgrounds a `sleep 30 &` of its own) — so an
    # inherited fd would leave the single-flight lock held by an orphan no
    # living claimant believes it owns: a stuck lock on the path that
    # restarts the orchestrator, which is WORSE than the race it closes.
    # Remedy is the #451/#471/bootstrap.sh close-at-spawn idiom: every
    # external child below is denied the fd with a literal `9>&-` (a LITERAL
    # redirect, never synthesised from a variable — launcher.sh:684 records
    # `${FD:+${FD}>&-}` arriving as an ARGUMENT). Foreground coreutils
    # (`cat`, `tr`, `grep`, `sed`, `tail`, `cut`, `mkdir`, `rm`, `date`) are
    # waited on and cannot outlive this process; they are left alone.
    local _rlock="$STATE_DIR/restart-orchestrator.lock"
    exec 9>>"$_rlock" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        if ! flock -n 9; then
            note "REFUSED restart-orchestrator: another claimant holds $_rlock — a restart is already in flight. Exclusivity is a property of the OPERATION, not of the caller (your-org/nexus-code#1400)."
            exit 24
        fi
    else
        note "WARN restart-orchestrator: flock(1) unavailable — the lock is NOT held; falling back to the three predicates alone (they race)."
    fi
    # The caller's three predicates, now also enforced here.
    local _rpid
    _rpid=$(tr -d '[:space:]' < "$STATE_DIR/restart-orchestrator.pid" 2>/dev/null || true)
    if [[ "$_rpid" =~ ^[0-9]+$ ]] && [[ "$_rpid" != "$BASHPID" ]] && kill -0 "$_rpid" 2>/dev/null; then
        note "REFUSED restart-orchestrator: a live claimant (pid $_rpid) is already mid-restart."
        exit 24
    fi
    # DELIBERATELY *NOT* REFUSING ON THE ARMED MARKER ALONE.
    # A bare `[[ -f restart-watchdog-armed ]] -> exit` would be the #1320 shape
    # reproduced inside its own fix: a marker left by a CRASHED prior run would
    # block every future restart, permanently and silently, with no exit
    # condition. The flock above already supplies exclusivity — no second
    # claimant can be inside this verb — so a marker seen while WE hold the
    # lock is necessarily STALE, and the pre-arm cleanup below correctly
    # clears it. Logged, so a stale marker is visible rather than invisible.
    if [[ -f "$STATE_DIR/restart-watchdog-armed" ]]; then
        note "restart-orchestrator: a stale restart-watchdog-armed marker is present ($(cat "$STATE_DIR/restart-watchdog-armed" 2>/dev/null || echo '?')). We hold $_rlock, so no live claimant owns it; the pre-arm cleanup will clear it."
    fi

    printf '%s\n' "$BASHPID" > "$STATE_DIR/restart-orchestrator.pid" 2>/dev/null || true

    # A SIGTERM to this detached process is a DELIBERATE abort — it is
    # setsid-disowned, so nothing routine signals it. Pre-#513, dying
    # silently was indistinguishable from a crash, and the dead pid is
    # precisely what re-opens the reconcile's single-flight guard: the
    # abort CAUSED the refire (2026-07-10: SIGTERM at 04:08, auto-refire
    # at 04:09:55, and again every cooldown until a pin revert). Write
    # the durable hold for THIS candidate before dying — "stopped on
    # purpose" stays stopped; a NEWER candidate re-arms (until_version).
    _restart_abort_to_hold() {
        if _cc_auto_write_restart_hold "$AUTO_DIR" \
                "sigterm-detached-restart pid=$BASHPID" "" "$candidate"; then
            note "SIGTERM: detached restart deliberately aborted — restart-hold written (until_version=$candidate); the reconcile will NOT re-fire for this candidate. Release: $SELF_PATH unhold"
        else
            note "SIGTERM: detached restart aborted but the restart-hold could NOT be written — the reconcile WILL re-fire after its cooldown; write the hold manually ($SELF_PATH hold --reason …)"
        fi
        record_outcome "$candidate" "safe-bumped-restart-aborted" "sigterm-hold-written"
        notify "cc-auto-update: detached orchestrator restart SIGTERMed — hold set for $candidate (release: unhold)"
        exit 25
    }
    trap '_restart_abort_to_hold' TERM

    # Durable terminal-outcome surfacing (your-org/nexus-code#511). Every
    # exit path below records a decisions.tsv row then exits with a
    # documented code (0/21/22/23/24/25), but that code lands in a detached
    # log nothing reads and the row sits in an append-only TSV — so the
    # LATEST restart outcome was only discoverable by `tail`-ing the log
    # (which two evaluators did and both miscounted). This EXIT trap mirrors
    # the terminal row into the single-latest `restart-outcome` marker and
    # maintains the consecutive-abort streak that escalates a stuck restart.
    # Riding the EXIT trap covers every path — including the SIGTERM abort
    # and the inline-seam subshell — without editing each exit site, and it
    # never alters the exit code (it only reads $?).
    _restart_outcome_on_exit() {
        local _code=$? _last _status _detail
        # (#1528, w240sk F1) A window-selection capture belongs to a kill. On
        # ANY exit that did not reach the kill line — the per-exit aborts, the
        # TERM trap's exit 25, a `set -u` death — drop it, or a later
        # UNRELATED absent-target respawn consumes it inside its 1800 s bound
        # and moves an operator who chose another window (measured, F1).
        if (( _SEL_KILL_REACHED == 0 )) && [[ -n "$_SEL_CAPTURE_FILE" ]]; then
            rm -f "$_SEL_CAPTURE_FILE" 2>/dev/null || true
        fi
        _last=$(tail -n 1 "$AUTO_DIR/decisions.tsv" 2>/dev/null || true)
        # decisions.tsv row shape: ts<TAB>candidate<TAB>decision<TAB>detail
        _status=$(printf '%s' "$_last" | cut -f3)
        _detail=$(printf '%s' "$_last" | cut -f4)
        # Match every restart terminal status — including the dash-less
        # `safe-bumped-restarted` (clean restart) alongside
        # `safe-bumped-restart-forced/-aborted/-held/-noop`. A `*` after
        # `restart` (no hyphen) is required to catch the clean-restart case.
        case "$_status" in
            safe-bumped-restart*)
                _cc_auto_write_restart_outcome \
                    "$AUTO_DIR" "$_status" "$_code" "$_detail" "$candidate" ;;
        esac
        return 0
    }
    trap '_restart_outcome_on_exit' EXIT

    # Hold pre-flight (nexus-code#513): a held restart does not wait,
    # does not arm, does not kill.
    if _cc_auto_restart_hold_active "$AUTO_DIR" "$candidate"; then
        note "ABORT restart: restart-hold active ($(_cc_update_field "$AUTO_DIR/restart-hold" reason 2>/dev/null || echo '?')) — not waiting, not killing. Bump itself is complete. Release: $SELF_PATH unhold"
        record_outcome "$candidate" "safe-bumped-restart-held" "hold-pre-wait"
        exit 25
    fi

    local pin_file="$STATE_DIR/orchestrator-session-id"
    local jsonl="$PROJECTS_DIR/$(_slug "$NEXUS_ROOT")/$sid.jsonl"

    # _pin_still_ours — rc 0 iff the live pin still names OUR sid and its
    # transcript still exists. Re-checked at start AND at fire time: the
    # idle-wait can run for minutes, during which the operator (or a
    # respawn) could re-pin. A kill after the pin moved would cold-spawn a
    # DIFFERENT session — exactly the context loss the gate forbids.
    _pin_still_ours() {
        local cur
        cur=$(tr -d '[:space:]' < "$pin_file" 2>/dev/null || true)
        [[ "$cur" == "$sid" && -f "$jsonl" ]]
    }
    # _already_on_candidate — rc 0 iff the pinned transcript already holds
    # a record stamped with the candidate version. The session earns such
    # a record only once a process running the CANDIDATE binary writes to
    # it; while the orchestrator runs the OLD binary it stamps the old
    # version. So a candidate stamp ⇒ the orchestrator already respawned
    # onto the new binary on its own (e.g. the version-aware watcher
    # self-restart, issue #186) ⇒ a kill would be needless. Forward-only
    # bumps make this unambiguous (the candidate string cannot have been
    # written by an earlier run of this session).
    _already_on_candidate() {
        grep -qF "\"version\":\"$candidate\"" "$jsonl" 2>/dev/null
    }

    # Fire-time pre-flight #1 (start of the detached run): the session pin
    # is the whole seamlessness story; if it is already stale/absent, a
    # kill would COLD-SPAWN (context lost). Never kill in that state.
    if ! _pin_still_ours; then
        note "ABORT restart: session pin no longer names $sid (or transcript $jsonl gone) — a kill now would COLD-SPAWN a different session (context lost). Bump itself is complete."
        record_outcome "$candidate" "safe-bumped-restart-aborted" "pin-stale-pre-wait sid=$sid"
        notify "cc-auto-update: orchestrator restart aborted ($candidate) — session pin stale before the wait; workspace is version-split"
        exit 21
    fi
    if _already_on_candidate; then
        note "NO-OP restart: pinned transcript already holds a \"version\":\"$candidate\" record — the orchestrator respawned onto the new binary on its own. Nothing to kill."
        record_outcome "$candidate" "safe-bumped-restart-noop" "already-on-candidate-pre-wait sid=$sid"
        exit 24
    fi

    # Wait for the orchestrator to reach a TURN BOUNDARY: killing
    # mid-turn discards the in-flight turn's tokens. monitor/pane-state.sh
    # is the only sanctioned classifier (autosuggest renders identically
    # to typed input) — and it is INDEX-keyed, so resolve the window NAME
    # → index. A name that resolves to no live tmux window is a hard
    # error: we cannot read the idle state, and a kill without a readable
    # state would risk killing a window that isn't the orchestrator. Fail
    # loud (23), do NOT kill blind.
    #
    # The gate accepts every turn-boundary verdict, not just the literal
    # `idle` — which a Monitor-holding orchestrator can NEVER produce
    # (nexus-code#514; see _restart_eligible above).
    #
    # On reaching the IDLE_WAIT cap we do NOT defer (the old exit-20 bug:
    # during active drives the orchestrator was never idle, so the restart
    # simply never happened and the workspace stayed version-split). Per
    # the operator decision we FORCE-restart instead: the pinned session
    # resumes from its transcript, so a mid-turn kill only re-runs the
    # interrupted turn (some repeated token generation), never lost work.
    # Force applies ONLY when the classifier POSITIVELY resolved the pane
    # at least once during the wait (busy, user-typing, a shell-driven
    # working-background, …). A wait that saw NOTHING but `state=empty`
    # never established what the pane is doing — force-killing on a
    # verdict that never resolved would kill an unknown, so it aborts
    # loud (23) instead and the reconcile retries after its cooldown
    # (nexus-code#514 item 3). The aborts above/below stay aborts.
    #
    # Re-resolve the index INSIDE the loop, every poll — do NOT cache it
    # across the (up to IDLE_WAIT-long) wait. The index is only stable
    # while tmux `renumber-windows` is off (its default, and this nexus's
    # setting): with renumber on, closing a lower-indexed window would
    # shift the orchestrator's index out from under a cached value, and
    # we'd then poll — or ultimately kill the NAME of — a different window
    # than the one we read. Re-resolving costs one extra `tmux
    # list-windows` per poll and removes that coupling entirely. (First
    # match wins on a duplicate name, matching `tmux kill-window -t
    # <name>`'s own lowest-index resolution, so the read pane and the
    # killed pane stay the same window; persistent duplicate orchestrators
    # are in any case reaped by the watcher's _respawn.sh dedup.)
    local waited=0 st="" raw="" target_idx="" forced=0 resolved_seen=0
    while :; do
        target_idx=$(_resolve_target_index "$TARGET_WINDOW")
        if [[ -z "$target_idx" ]]; then
            note "ABORT restart: orchestrator window '$TARGET_WINDOW' did not resolve to a tmux index — cannot read idle state, will not kill blind. Bump itself is complete."
            record_outcome "$candidate" "safe-bumped-restart-aborted" "target-window-unresolved=$TARGET_WINDOW"
            notify "cc-auto-update: orchestrator restart aborted ($candidate) — window '$TARGET_WINDOW' not found in tmux; workspace is version-split"
            exit 23
        fi
        # Query by INDEX (the original bug was querying by name → empty).
        raw=$("$PANE_STATE_CMD" "$target_idx" 2>/dev/null 9>&-)
        st=$(printf '%s\n' "$raw" | sed -n 's/.*state=\([a-z-]*\).*/\1/p' | head -1)
        if [[ -z "$st" ]]; then
            # NO parseable `state=` verdict. With an already-resolved index
            # this is NOT "busy" — it is a broken probe (helper crashed, or
            # the window vanished). Distinct from `state=empty`, which IS a
            # valid verdict (renderer transient, claude alive) and parses to
            # st=empty → handled as a normal non-idle wait → force-restarts
            # at the cap. An UNREADABLE probe must fail loud, never be
            # misread as "busy" and force-killed against an unknown pane.
            note "ABORT restart: orchestrator pane-state UNREADABLE for window index $target_idx (probe output: '${raw:-<empty>}'). Idle cannot be confirmed and the pane identity is unknown, so we will not force-kill. Bump itself is complete."
            record_outcome "$candidate" "safe-bumped-restart-aborted" "pane-state-unreadable idx=$target_idx"
            notify "cc-auto-update: orchestrator restart aborted ($candidate) — idle-state unreadable (idx=$target_idx); workspace is version-split"
            exit 23
        fi
        [[ "$st" != "empty" ]] && resolved_seen=1
        _restart_eligible "$st" "$raw" && break
        if (( waited >= IDLE_WAIT )); then
            if (( resolved_seen == 0 )); then
                note "ABORT restart: state=empty for the ENTIRE ${IDLE_WAIT}s wait — the classifier never positively resolved this pane to busy OR to a turn boundary. Refusing to force-kill on a verdict that was never established; the reconcile retries after its cooldown, and a turn boundary now satisfies the eligibility gate. Bump itself is complete."
                record_outcome "$candidate" "safe-bumped-restart-aborted" "never-resolved-empty-at-cap idx=$target_idx"
                notify "cc-auto-update: orchestrator restart aborted ($candidate) — pane never positively resolved within ${IDLE_WAIT}s; will retry"
                exit 23
            fi
            if [[ "$(_restart_line_field "$raw" auth)" == login ]] && _auth_hold_knob_on; then
                # A login in progress is NOT "busy": forcing here is the
                # interruption #1518 exists to prevent, and the respawned
                # session would still need the login. Abort, let the
                # reconcile retry after its cooldown; #1518's escape clock
                # bounds an abandoned login, after which the pane reads
                # as a plain boundary and the next attempt proceeds. That
                # clock exists only while the auth hold is ENABLED — with it
                # off this arm is skipped and the FORCE below applies, so the
                # bound is real in both configurations (w239sk F3).
                note "ABORT restart: orchestrator pane shows a LOGIN IN PROGRESS (auth=login, last state=$st) for the entire ${IDLE_WAIT}s wait — not forcing a kill through the operator's login (#1518; bounded by the auth hold's escape clock). The reconcile retries after its cooldown. Bump itself is complete."
                record_outcome "$candidate" "safe-bumped-restart-aborted" "auth-login-at-cap idx=$target_idx last_state=$st"
                notify "cc-auto-update: orchestrator restart deferred ($candidate) — a /login is in progress on the orchestrator pane; will retry after the cooldown"
                exit 23
            fi
            note "FORCE restart: orchestrator not at a turn boundary within ${IDLE_WAIT}s (last state=$st) — restarting anyway per operator decision. The pinned session resumes from its transcript, so the mid-turn kill only re-runs the interrupted turn (repeated tokens), not lost work."
            forced=1
            break
        fi
        sleep "$IDLE_POLL"
        waited=$(( waited + IDLE_POLL ))
    done
    if (( forced )); then
        note "restart: idle-wait cap (${IDLE_WAIT}s) reached, orchestrator busy — FORCE-restarting (window index $target_idx); arming the restart watchdog"
    else
        note "restart: orchestrator at a turn boundary (state=$st, window index $target_idx) — arming the restart watchdog (probe: $raw)"
    fi

    # Fire-time pre-flight #2 (after the up-to-IDLE_WAIT wait, BEFORE we
    # arm the watchdog or kill): re-validate the pin and the
    # already-respawned gate. Doing it here — not after arming — avoids
    # spawning a watchdog that would then wait out its deadline for a kill
    # that never comes.
    if ! _pin_still_ours; then
        note "ABORT restart: session pin moved during the idle-wait (no longer $sid, or transcript gone) — NOT killing (would cold-spawn). Bump itself is complete."
        record_outcome "$candidate" "safe-bumped-restart-aborted" "pin-stale-at-fire sid=$sid"
        notify "cc-auto-update: orchestrator restart aborted ($candidate) — pin moved at fire time; workspace is version-split"
        exit 21
    fi
    if _already_on_candidate; then
        note "NO-OP restart: orchestrator came up on $candidate on its own during the wait — NOT killing."
        record_outcome "$candidate" "safe-bumped-restart-noop" "already-on-candidate-at-fire sid=$sid"
        exit 24
    fi
    # A hold can arrive DURING the (up to IDLE_WAIT-long) wait — an
    # operator writing it is precisely how "do not kill what you are
    # about to kill" is said to a detached process (nexus-code#513).
    if _cc_auto_restart_hold_active "$AUTO_DIR" "$candidate"; then
        note "ABORT restart: restart-hold arrived during the wait — NOT killing. Bump itself is complete. Release: $SELF_PATH unhold"
        record_outcome "$candidate" "safe-bumped-restart-held" "hold-at-fire"
        exit 25
    fi

    # Watchdog worker (REQUIRED by GUIDE Step 5b — a script can detect,
    # only an agent can FIX). Clear any stale armed marker first: the
    # marker's fresh write by THIS watchdog is the arm signal.
    rm -f "$STATE_DIR/restart-watchdog-armed" "$STATE_DIR/restart-watchdog-failed" 2>/dev/null || true
    # (your-org/nexus-code#1528) CAPTURE THE OPERATOR'S WINDOW SELECTION BEFORE
    # ANYTHING HERE CAN MOVE IT. The stale-watchdog kill just below is the
    # first such thing: measured on tmux 2.6, killing a session's ACTIVE window
    # moves that session's selection (killing a non-active one does not), so an
    # operator sitting on a prior attempt's watchdog window would be moved
    # before the orchestrator kill this capture exists for. The capture is
    # REFRESHED immediately before that kill (`--refresh`, honouring anything
    # the operator did during the arm-wait), the post-kill auto-selection is
    # noted right after it, and the watcher's `_respawn_spawn_window` consumes
    # the file once the new orchestrator window exists. A capture whose kill
    # never happened must not be consumed by a later, unrelated respawn: the
    # EXIT trap (`_restart_outcome_on_exit`) drops it on every exit that did
    # not reach the kill line, which sets `_SEL_KILL_REACHED` — one drop for
    # the per-exit aborts, the TERM trap and a `set -u` death alike (w240sk
    # F1: a per-exit `rm` list covered only the first). Best-effort
    # throughout — a capture that cannot vouch for itself writes nothing, and
    # nothing here can change this verb's rc. `9>&-` for the same reason every
    # other tmux call in the locked region carries it (19b: the single-flight
    # lock must not leak into tmux's children).
    _SEL_CAPTURE_FILE=$(tmux_selection_capture_file "$STATE_DIR")
    TMUX_WINDOW_TMUX_CMD="$TMUX_CMD" tmux_selection_capture "$TARGET_WINDOW" "$_SEL_CAPTURE_FILE" 9>&- || true
    if grep -Fxq -- "$WATCHDOG_WINDOW" <<<"$("$TMUX_CMD" list-windows -F '#W' 2>/dev/null 9>&-)"; then
        "$TMUX_CMD" kill-window -t "$WATCHDOG_WINDOW" 2>/dev/null 9>&- || true
    fi
    local wd_template="${CC_AUTO_WATCHDOG_PROMPT_TEMPLATE:-$NEXUS_ROOT/monitor/cc-auto-update-watchdog-prompt.md}"
    local wd_prompt="$AUTO_DIR/watchdog-prompt.md"
    # The watchdog loop's per-arm nonce (w234sk F1), minted HERE. It is rendered
    # into both the loop command (WATCHDOG_ATTEMPT) and the prompt's
    # --verify-only command, so the agent that verifies holds THIS attempt's
    # identity by construction. It never recovers the nonce from the
    # append-only restart-watchdog.log, where on a day of repeated attempts
    # (2026-07-21: 16 of them) an earlier attempt's line is what it would find.
    local wd_attempt
    wd_attempt="$(date +%s)-$$-${RANDOM}${RANDOM}"
    if ! _cc_auto_render_prompt "$wd_template" "$wd_prompt" \
            "CANDIDATE=$candidate" "NEXUS_ROOT=$NEXUS_ROOT" \
            "STATE_DIR=$STATE_DIR" "TARGET_WINDOW=$TARGET_WINDOW" \
            "ATTEMPT=$wd_attempt"; then
        note "ABORT restart: watchdog prompt template missing ($wd_template). Bump itself is complete."
        record_outcome "$candidate" "safe-bumped-restart-aborted" "watchdog-template"
        notify "cc-auto-update: orchestrator restart aborted ($candidate) — watchdog template missing"
        exit 22
    fi
    # The watchdog's window NAME, for the PreToolUse hook's `cc-update-git`
    # scope (your-org/nexus-code#1529, w241sk D2); see _cc_auto_update.sh.
    printf '%s\n' "$WATCHDOG_WINDOW" > "$AUTO_DIR/watchdog-window" 2>/dev/null || true
    if ! "$SPAWN_CMD" -n "$WATCHDOG_WINDOW" -c "$NEXUS_ROOT" -p "$wd_prompt" >/dev/null 2>&1 9>&-; then
        note "ABORT restart: watchdog spawn failed. Bump itself is complete; NOT killing the orchestrator unwatched."
        record_outcome "$candidate" "safe-bumped-restart-aborted" "watchdog-spawn"
        notify "cc-auto-update: orchestrator restart aborted ($candidate) — watchdog spawn failed"
        exit 22
    fi

    # Kill-last ordering: the kill fires ONLY after the watchdog's armed
    # marker appears (it has recorded its baseline and started its watch
    # loop).
    # BASELINE PANE PID, taken BEFORE the arm-wait (your-org/nexus-code#1400,
    # ccwatch item 1). The kill below used to be unconditional, so a SECOND
    # claimant that arrived after the first had already killed and the watcher
    # had already respawned would kill the REPLACEMENT. Measured today: two
    # claimants (13708 hand-fired, 21558 watcher-launched) both issued
    # `kill-window -t orchestrator` ONE SECOND APART; benign only because the
    # respawn took 15s. `orch_pid` is recorded by cc-restart-watchdog-loop.sh:77
    # in a DIFFERENT PROCESS, so this verb cannot read it — it must take its own.
    local base_pane_pid="" _wd_list="" _wd_rc=0
    # `display-message -p`, NOT `list-panes | head -1`: the piped form is an
    # EARLY-EXIT READER (your-org/nexus-code#682) and the manifest's own header
    # says a new site is to be FIXED, not recorded. This form needs no pipe, so
    # there is no EPIPE to mask and no manifest growth. Same idiom as
    # monitor/cc-harness/_lib.sh:710.
    base_pane_pid=$("$TMUX_CMD" display-message -p -t "$TARGET_WINDOW" '#{pane_pid}' 2>/dev/null 9>&- | tr -d '[:space:]')
    # NON-DEGRADING BY CONSTRUCTION. The first cut made an unreadable baseline
    # FATAL (exit 22), which REMOVED the ability to restart on any host whose
    # tmux does not answer `list-panes -F '#{pane_pid}'` — and took 16 fixture
    # runs with it. Before this change the kill was UNCONDITIONAL, so a guard
    # that can refuse to restart when it cannot read is strictly worse than the
    # code it replaces. This guard ADDS protection when the baseline is
    # readable and DISARMS ITSELF, loudly, when it is not.
    if [[ ! "$base_pane_pid" =~ ^[0-9]+$ ]]; then
        note "WARN restart: could not read a numeric pane pid for $TARGET_WINDOW (got '${base_pane_pid:-<empty>}'). The duplicate-claimant guard is DISARMED for this run — proceeding with the prior unconditional-kill behaviour. This is a degraded guard, not a degraded restart (your-org/nexus-code#1400)."
        base_pane_pid=""
    else
        note "restart: baseline pane pid for $TARGET_WINDOW = $base_pane_pid"
    fi

    waited=0
    while [[ ! -f "$STATE_DIR/restart-watchdog-armed" ]]; do
        # (ccwatch item 3) A DEAD watchdog and a SLOW one used to be
        # indistinguishable for the full ARM_WAIT, after which the whole
        # restart aborted. That is what stalled both claimants today. The
        # marker can only ever appear if the watchdog is alive to write it,
        # so a dead window is decisive NOW rather than in ${ARM_WAIT}s.
        # ABSENCE MUST BE ESTABLISHED, NOT INFERRED FROM AN EMPTY READ.
        # The first cut of this check treated "list-windows produced nothing"
        # as "the window is gone" — a confident zero — and aborted 16 fixture
        # runs whose stub tmux enumerates nothing. A failed or EMPTY
        # enumeration is "could not look", which must fall through to the
        # ARM_WAIT timeout rather than decide. Only a SUCCESSFUL, NON-EMPTY
        # listing that omits the window is evidence of absence.
        _wd_list=$("$TMUX_CMD" list-windows -a -F '#{window_name}' 2>/dev/null 9>&-); _wd_rc=$?
        if (( _wd_rc == 0 )) && [[ -n "${_wd_list//[[:space:]]/}" ]] \
           && ! grep -Fxq -- "$WATCHDOG_WINDOW" <<<"$_wd_list" \
           && [[ ! -f "$STATE_DIR/restart-watchdog-armed" ]]; then
            note "ABORT restart: watchdog window '$WATCHDOG_WINDOW' is GONE before arming (waited ${waited}s of ${ARM_WAIT}s). It cannot write the marker, so waiting out the full window would only delay this. NOT killing the orchestrator unwatched. Bump itself is complete."
            record_outcome "$candidate" "safe-bumped-restart-aborted" "watchdog-window-vanished"
            notify "cc-auto-update: orchestrator restart aborted ($candidate) — watchdog window $WATCHDOG_WINDOW vanished before arming"
            exit 22
        fi
        if (( waited >= ARM_WAIT )); then
            note "ABORT restart: watchdog never armed within ${ARM_WAIT}s. NOT killing the orchestrator unwatched. Bump itself is complete."
            record_outcome "$candidate" "safe-bumped-restart-aborted" "watchdog-never-armed"
            notify "cc-auto-update: orchestrator restart aborted ($candidate) — watchdog never armed; inspect window $WATCHDOG_WINDOW"
            exit 22
        fi
        sleep "$ARM_POLL"
        waited=$(( waited + ARM_POLL ))
    done
    note "restart: watchdog armed — killing $TARGET_WINDOW ($( ((forced)) && echo 'forced: busy past idle cap' || echo idle ); the watcher's absent-target recovery resumes the pinned session on the new binary)"
    # (ccwatch item 1) RE-READ before killing. If the pane pid no longer
    # matches the baseline, the orchestrator has ALREADY been replaced — by
    # another claimant, or by the watcher's absent-target recovery — and this
    # kill would decapitate the REPLACEMENT. Refuse; do not "kill anyway".
    local now_pane_pid=""
    if [[ -n "$base_pane_pid" ]]; then
        now_pane_pid=$("$TMUX_CMD" display-message -p -t "$TARGET_WINDOW" '#{pane_pid}' 2>/dev/null 9>&- | tr -d '[:space:]')
    fi
    # Only a baseline we actually READ can convict. An empty baseline means the
    # guard disarmed above and this comparison is skipped, never inverted.
    if [[ -n "$base_pane_pid" && "$now_pane_pid" != "$base_pane_pid" ]]; then
        note "REFUSED to kill $TARGET_WINDOW: pane pid changed ${base_pane_pid} -> ${now_pane_pid:-<gone>} since this restart armed. The orchestrator has already been replaced; killing now would decapitate the REPLACEMENT (your-org/nexus-code#1400, two claimants one second apart on 2026-09-03). Bump itself is complete."
        record_outcome "$candidate" "safe-bumped-restart-refused" "duplicate-claimant base_pane_pid=$base_pane_pid now=${now_pane_pid:-gone} sid=$sid"
        notify "cc-auto-update: orchestrator restart REFUSED ($candidate) — target already replaced (pane pid $base_pane_pid -> ${now_pane_pid:-gone}); no duplicate kill issued"
        exit 23
    fi
    # (#1528) Refresh the selection capture with what the operator is looking at
    # NOW, kill, then record where tmux put the selection. See the capture above.
    TMUX_WINDOW_TMUX_CMD="$TMUX_CMD" tmux_selection_capture --refresh "$TARGET_WINDOW" "$_SEL_CAPTURE_FILE" 9>&- || true
    "$TMUX_CMD" kill-window -t "$TARGET_WINDOW" 9>&-
    _SEL_KILL_REACHED=1   # the capture now belongs to a kill; the EXIT trap leaves it
    TMUX_WINDOW_TMUX_CMD="$TMUX_CMD" tmux_selection_note_post_kill "$_SEL_CAPTURE_FILE" 9>&- || true
    if [[ -r "$_SEL_CAPTURE_FILE" ]]; then
        note "restart: window selection captured for the respawn to restore ($_SEL_CAPTURE_FILE: $(grep -c '^prior|' "$_SEL_CAPTURE_FILE" 2>/dev/null || echo 0) session(s))"
    else
        note "restart: no window-selection capture written (tmux would not answer in a parseable shape); the respawn leaves the selection where tmux put it"
    fi
    if (( forced )); then
        record_outcome "$candidate" "safe-bumped-restart-forced" "restart-triggered-forced sid=$sid"
        notify "cc-auto-update: $candidate applied; orchestrator FORCE-restarted (busy past idle cap) under watchdog — pinned session resumes"
    else
        record_outcome "$candidate" "safe-bumped-restarted" "restart-triggered sid=$sid"
        notify "cc-auto-update: $candidate applied autonomously; orchestrator restart in progress under watchdog"
    fi
    exit 0
}

# ---- verb: compat-pr ------------------------------------------------------

# Open compat PRs are recognised by the `cc-compat` marker in the title
# (the convention this routine itself follows when opening one:
# `cc-compat <version>: <summary>`).
_compat_list_json() {
    local token
    token=$("$MINT_CMD") || { note "compat-pr: token mint failed"; return 1; }
    [[ -n "$token" ]] || { note "compat-pr: token mint returned empty (fail-loud guard)"; return 1; }
    GH_TOKEN="$token" "$GH_CMD" pr list --repo "$COMPAT_REPO" --state open \
        --search 'cc-compat in:title' --json number,title,url
}

cmd_compat_pr() {
    local mode="${1:-}"; shift || true
    case "$mode" in
        list)
            _compat_list_json
            ;;
        auto)
            local candidate="" findings=""
            while (( $# > 0 )); do
                case "$1" in
                    --candidate) candidate="$2"; shift 2 ;;
                    --findings)  findings="$2"; shift 2 ;;
                    *) note "compat-pr auto: unknown arg $1"; exit 2 ;;
                esac
            done
            [[ -n "$candidate" ]] || { note "compat-pr auto: --candidate required"; exit 2; }
            [[ -f "$findings" ]]  || { note "compat-pr auto: --findings <file> required and must exist"; exit 2; }
            command -v jq >/dev/null 2>&1 || { note "compat-pr auto: jq required"; exit 2; }
            # Live-tree drift (your-org/nexus-code#1002): a compat verdict is a
            # verdict. Audit row only, no last-eval — see _assert_live_tree.
            if ! _assert_live_tree compat-pr "$candidate"; then
                _cc_auto_log_decision "$AUTO_DIR" "$candidate" "live-tree-drift" \
                    "verb=compat-pr $LIVE_TREE_DRIFT_DETAIL"
                exit 9
            fi
            local json n
            json=$(_compat_list_json) || exit 1
            n=$(printf '%s' "$json" | jq 'length' 2>/dev/null || echo 0)
            case "$n" in
                0)
                    note "compat-pr: none-found — open a new PR on $COMPAT_REPO (base dev, title 'cc-compat $candidate: <summary>') and HOLD for operator approval"
                    printf 'none-found\n'
                    exit 10
                    ;;
                1)
                    local num url token
                    num=$(printf '%s' "$json" | jq -r '.[0].number')
                    url=$(printf '%s' "$json" | jq -r '.[0].url')
                    token=$("$MINT_CMD") || exit 1
                    [[ -n "$token" ]] || { note "compat-pr: token mint returned empty"; exit 1; }
                    if GH_TOKEN="$token" "$GH_CMD" pr comment "$num" --repo "$COMPAT_REPO" --body-file "$findings"; then
                        note "compat-pr: commented findings for $candidate on existing $url"
                        record_outcome "$candidate" "compat-pr-commented" "pr=$url"
                        printf 'commented %s\n' "$url"
                        exit 0
                    fi
                    note "compat-pr: comment on $url FAILED"
                    exit 1
                    ;;
                *)
                    note "compat-pr: $n open cc-compat PRs — ambiguous; caller must judge which covers this break and comment via 'compat-pr comment <number> --findings <file>'"
                    printf '%s\n' "$json"
                    exit 11
                    ;;
            esac
            ;;
        comment)
            local num="${1:-}"; shift || true
            local candidate="" findings=""
            while (( $# > 0 )); do
                case "$1" in
                    --candidate) candidate="$2"; shift 2 ;;
                    --findings)  findings="$2"; shift 2 ;;
                    *) note "compat-pr comment: unknown arg $1"; exit 2 ;;
                esac
            done
            [[ "$num" =~ ^[0-9]+$ ]] || { note "compat-pr comment: PR number required"; exit 2; }
            [[ -f "$findings" ]] || { note "compat-pr comment: --findings <file> required"; exit 2; }
            local token
            token=$("$MINT_CMD") || exit 1
            [[ -n "$token" ]] || { note "compat-pr: token mint returned empty"; exit 1; }
            GH_TOKEN="$token" "$GH_CMD" pr comment "$num" --repo "$COMPAT_REPO" --body-file "$findings" || exit 1
            record_outcome "${candidate:-unknown}" "compat-pr-commented" "pr=$COMPAT_REPO#$num"
            ;;
        *)
            note "compat-pr: unknown mode '${mode:-}' (list|auto|comment)"
            exit 2
            ;;
    esac
}

# ---- verb: block ----------------------------------------------------------

# A BLOCK IS A CLAIM ABOUT (candidate x checkout), AND USED TO RECORD ONLY
# THE CANDIDATE (your-org/nexus-code#1259).
#
# THE INSTANCE. 2026-09-01, candidate 2.1.252. The evaluator gated a clone
# whose HEAD predated the `#1214` trust-dialog detector fix by ninety
# minutes and recorded:
#
#   block  "2.1.252 STILL omits the trust dialog's numbered option rows
#           ... now 5 releases deep"
#
# That reason is FALSE, and nothing in `decisions.tsv`, `last-eval` or the
# issue comment named a tree, so no later reader — including the next
# evaluator, which reads `last-eval` to decide whether to skip — could tell
# it from the three genuine reds that preceded it. The margin was five
# minutes.
#
# THE FAILURE DIRECTION IS THE BAD ONE. A stale tree can only manufacture a
# spurious RED: an indefinite, silent refusal to ever bump, with a plausible
# reason attached each day. Nothing downstream disagrees, because "still
# blocked" is what the previous rounds also said.
#
# WHY THIS ANNOTATES WHERE `safe` REFUSES. Refusing a block when the tree is
# merely BEHIND was the issue's first proposal and it is wrong: first-parent
# commits landing on the integration branch run 6-20 a day here, so being
# behind at the daily fire is the NORMAL state, and refusing on it would
# convert a rare false block into a standing one — strictly worse, and
# attributed to the candidate in exactly the way this issue complains about.
# So `behind` is RECORDED, never refused.
#
# WHAT IS REFUSED is the narrower and genuinely unanswerable case: a gate
# log that cannot say which tree produced it. That is not a third opinion
# about the candidate, it is the absence of one, and it is recorded under
# its OWN decision (`block-unattributable`) so it can never be read as a
# candidate verdict — the third outcome, not collapsed into either.
cmd_block() {
    local candidate="" reason="" gate_evidence=""
    while (( $# > 0 )); do
        case "$1" in
            --candidate)     candidate="$2"; shift 2 ;;
            --reason)        reason="$2"; shift 2 ;;
            # OPTIONAL, and DERIVED when omitted — see below. Not every
            # block comes from a gate RED (a changelog surface can block on
            # its own), so requiring it would force a fake argument on the
            # blocks that have no gate log.
            --gate-evidence) gate_evidence="$2"; shift 2 ;;
            *) note "block: unknown arg $1"; exit 2 ;;
        esac
    done
    [[ -n "$candidate" ]] || { note "block: --candidate required"; exit 2; }
    [[ -n "$reason" ]]    || { note "block: --reason required"; exit 2; }

    # Live-tree drift (your-org/nexus-code#1002). A block is a verdict too —
    # the 2026-08-25 fire recorded one on a polluted tree. NO record_outcome
    # here: last-eval must not name a verdict that was never reached (see
    # _assert_live_tree); the audit row is the record.
    if ! _assert_live_tree block "$candidate"; then
        _cc_auto_log_decision "$AUTO_DIR" "$candidate" "live-tree-drift" \
            "verb=block $LIVE_TREE_DRIFT_DETAIL reason=$reason"
        exit 9
    fi

    # 1. The tree this clone is at. Local, free, and always available: the
    #    row becomes attributable even for a block with no gate log at all.
    local live_head="unknown" live_ref="unknown"
    live_head=$(git -C "$NEXUS_ROOT" rev-parse HEAD 2>/dev/null) || live_head=""
    [[ "$live_head" =~ ^[0-9a-f]{40}$ ]] || live_head="unknown"
    live_ref=$(git -C "$NEXUS_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null) || live_ref=""
    [[ -n "$live_ref" ]] || live_ref="unknown"

    # 2. The tree the GATE measured. Two different subjects from (1), never
    #    merged into one field.
    #
    #    DERIVED WHEN NOT SUPPLIED, AND THAT IS THE WHOLE POINT. The first
    #    cut of this only looked at `--gate-evidence`, and the production
    #    caller does not pass it: `monitor/cc-auto-update-prompt.md` invokes
    #
    #        cc-auto-update-apply.sh block --candidate X --reason "..."
    #
    #    so every arm below was UNREACHABLE IN PRODUCTION. Measured, same
    #    unattributable gate log, `--gate-evidence` the only variable:
    #    production shape -> rc 0 recorded as `block`; test shape -> rc 3
    #    recorded as `block-unattributable`. The distinction this fix exists
    #    to create collapsed in exactly the configuration that ships — a
    #    correct arm nothing can reach, which is this repo's own dominant
    #    defect class arriving one layer out from where it was looked for.
    #
    #    Deriving rather than making the caller pass it is deliberate. A flag
    #    the caller must remember is a flag the caller can forget, and the
    #    forgetting is silent and looks exactly like a clean block. The path
    #    is not a guess: the SAME prompt that invokes `block` tees the gate to
    #    `{{STATE_DIR}}/cc-auto-update/gate-{{CANDIDATE}}.log`, which is this
    #    file's own `$AUTO_DIR/gate-<candidate>.log`. Candidate-keyed, so it
    #    cannot pick up another version's run.
    #
    #    BOUNDED BY THE SAME FRESHNESS CONSTANT the bump path uses. A log left
    #    from an earlier fire is not this run's evidence, and silently
    #    attributing today's block to yesterday's gate would be a new instance
    #    of the very thing being fixed. Too old is its own outcome
    #    (`gate-log-stale`) and never collapses into "there is none".
    local gated_head="none" attribution="no-gate-evidence" gate_src="none"
    if [[ -n "$gate_evidence" ]]; then
        gate_src="supplied"
    else
        local derived="$AUTO_DIR/gate-${candidate}.log"
        if [[ -f "$derived" ]]; then
            local g_age g_mtime
            g_mtime=$(stat -c %Y "$derived" 2>/dev/null || echo 0)
            g_age=$(( $(date +%s) - g_mtime ))
            if (( g_age <= GATE_EVIDENCE_MAX_AGE )); then
                gate_evidence="$derived"; gate_src="derived"
            else
                attribution="gate-log-stale"; gate_src="derived-stale"
                note "NOTE: $derived exists but is ${g_age}s old (> ${GATE_EVIDENCE_MAX_AGE}s) — not treating it as this run's gate evidence."
            fi
        fi
    fi
    if [[ -n "$gate_evidence" ]]; then
        if [[ ! -f "$gate_evidence" ]]; then
            attribution="gate-evidence-missing"
        elif grep -q '^=== gated-tree: UNATTRIBUTABLE' "$gate_evidence"; then
            local why; why=$(_gate_log_tree_field "$gate_evidence" reason)
            note "REFUSED to attribute: the gate could not establish which tree it gated (reason=${why:-unspecified}), so this RED is not a statement about $candidate. Recording it as UNATTRIBUTABLE rather than as a candidate verdict (your-org/nexus-code#1259)."
            record_outcome "$candidate" "block-unattributable" \
                "gate-tree-unattributable reason=${why:-unspecified} live_head=$live_head live_ref=$live_ref gate_evidence=$gate_src detail=$reason"
            notify "cc-auto-update: $candidate gate RED is UNATTRIBUTABLE (${why:-unspecified}) — not recorded as a candidate block"
            exit 3
        else
            gated_head=$(_gate_log_tree_field "$gate_evidence" head)
            if [[ ! "$gated_head" =~ ^[0-9a-f]{40}$ ]]; then
                gated_head="none"
                attribution="gate-log-carries-no-tree-stamp"
                note "REFUSED to attribute: the gate log carries no tree stamp, so this RED cannot be told from one caused by the checkout (your-org/nexus-code#1259). Re-run monitor/cc-harness/gate.sh."
                record_outcome "$candidate" "block-unattributable" \
                    "gate-tree-stamp-missing live_head=$live_head live_ref=$live_ref gate_evidence=$gate_src detail=$reason"
                notify "cc-auto-update: $candidate gate RED carries no tree stamp — not recorded as a candidate block"
                exit 3
            elif [[ "$gated_head" == "$live_head" ]]; then
                attribution="gated-tree-is-live-clone"
            else
                attribution="gated-tree-DIFFERS-from-live-clone"
            fi
        fi
    fi

    # 3. Is the tree that produced this verdict current? Recorded, never
    #    refused (see the header). The trichotomy is the watcher's own
    #    `_clone_drift_probe`, which takes the tip from a LIVE `ls-remote`
    #    rather than a remote-tracking ref — a ref nobody fetched answers
    #    confidently about the past, and `0 behind` from a stale ref is
    #    exactly how a spawn-time freshness banner read CLEAN seventy-six
    #    seconds before the fix that would have changed the verdict merged.
    #    `unknown` stays `unknown` and never becomes `up-to-date`.
    local branch drift="unknown" behind="unknown"
    branch=$(_gate_integration_branch)
    if [[ -d "$NEXUS_ROOT/.git" ]] && command -v git >/dev/null 2>&1; then
        local line; line=$(_clone_drift_probe "$NEXUS_ROOT" "$branch")
        drift=$(_clone_drift_field "$line" verdict)
        case "$drift" in
            up-to-date) behind=0 ;;
            behind)     behind=$(_clone_drift_field "$line" commits) ;;
            *)          drift="unknown"; behind="unknown" ;;
        esac
    fi

    local subject="live_head=$live_head live_ref=$live_ref gated_head=$gated_head attribution=$attribution gate_evidence=$gate_src drift=$drift behind_integration=$behind integration_branch=$branch"
    if [[ "$attribution" == "gated-tree-DIFFERS-from-live-clone" ]]; then
        note "NOTE: the gate measured $gated_head but this clone is at $live_head — the drift figures above describe the LIVE CLONE, not the gated tree."
    fi
    # A block on a possibly-stale classifier says so in ONE plain sentence
    # plus the ONE command, naming the SAME ref the margin was measured
    # against (your-org/nexus-code#1529; the branch is the operator's
    # monitor.integration_branch). The verdict is the local gate's; nothing
    # re-runs it elsewhere, and nothing prescribes a checkout on this clone.
    if [[ "$drift" == "behind" ]]; then
        note "NOTE: this clone's classifier is $behind commit(s) behind origin/$branch (monitor.integration_branch), so the red may belong to the checkout rather than to $candidate; bring the clone current and let the next daily fire re-gate: git -C $NEXUS_ROOT pull --ff-only origin $branch"
    elif [[ "$drift" != "up-to-date" ]]; then
        note "NOTE: could not determine whether this clone is behind origin/$branch — 'could not look' is NOT 'current'."
    fi
    note "BLOCK: candidate=$candidate reason=$reason $subject — NOT bumping; surfacing for the operator"
    record_outcome "$candidate" "block" "$reason | $subject"
    notify "cc-auto-update: $candidate BLOCKED ($reason) — operator attention needed"
    exit 0
}

# ---- verbs: hold / unhold / hold-status (your-org/nexus-code#513) ----------
# The durable, tick-checked representation of "this restart is
# deliberately held". The RUNNING watcher's reconcile honours it every
# pass, and the detached restart re-checks it before the kill — unlike
# `monitor.cc_auto_update.enabled`, which is read ONCE at watcher startup
# and is inert on a live watcher. Shell-portable by design: the
# 2026-07-10 workaround (hand-sourcing _cc-version.sh for a pin revert)
# silently no-op'd under zsh.

cmd_hold() {
    local reason="" ttl="" until_version=""
    while (( $# > 0 )); do
        case "$1" in
            --reason)        reason="$2"; shift 2 ;;
            --ttl-seconds)   ttl="$2"; shift 2 ;;
            --until-version) until_version="$2"; shift 2 ;;
            *) note "hold: unknown arg $1"; exit 2 ;;
        esac
    done
    [[ -n "$reason" ]] || { note "hold: --reason required (the hold is read by humans and audit rows)"; exit 2; }
    local expires=""
    if [[ -n "$ttl" ]]; then
        [[ "$ttl" =~ ^[0-9]+$ ]] || { note "hold: --ttl-seconds must be an integer"; exit 2; }
        expires=$(( $(date +%s) + ttl ))
    fi
    if ! _cc_auto_write_restart_hold "$AUTO_DIR" "$reason" "$expires" "$until_version"; then
        note "hold: FAILED to write $AUTO_DIR/restart-hold"
        exit 1
    fi
    note "hold: restart-hold set (reason=$reason${expires:+ expires=$(date -d "@$expires" -Is 2>/dev/null || echo "$expires")}${until_version:+ until_version=$until_version}). The reconcile will log 'reconcile-held' once and stay silent; release with: $SELF_PATH unhold"
    notify "cc-auto-update: orchestrator restart HELD ($reason)"
    exit 0
}

cmd_unhold() {
    if [[ ! -f "$AUTO_DIR/restart-hold" ]]; then
        note "unhold: no restart-hold present — nothing to release"
        exit 0
    fi
    rm -f "$AUTO_DIR/restart-hold" "$AUTO_DIR/reconcile-held.acked" 2>/dev/null || true
    _cc_auto_log_decision "$AUTO_DIR" "-" "restart-hold-released" "by=unhold"
    note "unhold: restart-hold released — the reconcile may fire again after its cooldown"
    notify "cc-auto-update: restart-hold released"
    exit 0
}

cmd_hold_status() {
    local f="$AUTO_DIR/restart-hold"
    if [[ ! -f "$f" ]]; then
        printf 'no hold\n'
        exit 1
    fi
    cat "$f"
    local effective
    effective=$(cc_version_effective "$NEXUS_ROOT/package.json" "$PACKAGE" "$NEXUS_ROOT" 2>/dev/null || true)
    if [[ -n "$effective" ]] && _cc_auto_restart_hold_active "$AUTO_DIR" "$effective"; then
        printf 'status=ACTIVE (effective=%s)\n' "$effective"
        exit 0
    fi
    printf 'status=EXPIRED/inactive (effective=%s)\n' "${effective:-unresolvable}"
    exit 1
}

# ---- verb: record-outcome ---------------------------------------------------

# ---- verb: rollback ------------------------------------------------------
#
# Restore the operator-local pin to what it was before the most recent bump,
# reinstall at that version, and VERIFY the binary actually reports it.
#
# WHY THIS EXISTS (your-org/nexus-code#1492). The operator's stated design is
# that "if the orchestrator struggles after restart, the watchdog can roll
# back". That was false as built and measurably so: `rollback_pin` is a
# function LOCAL to `cmd_safe` whose two call sites (install failure, verify
# mismatch) both sit BEFORE the watcher restart, and no verb exposed it. So
# every failure at or past the restart boundary — precisely the ones the
# watchdog exists to detect — had no way back. Probed at 77181f33 against the
# suite's own fixture harness: rc 6 / rc 22 / rc 21 all left the NEW pin
# standing, and `rollback`/`revert`/`undo`/`unpin` were all usage errors.
#
# THIS VERB DOES NOT LICENSE ANY DEPLOYMENT-GATE ARM, and the separation is
# deliberate rather than incidental. The gate recalibration that ships
# alongside it stands on its OWN reasoning — which instrument measures the
# irreversible hazard, and the fact that the board arms run LAST — and would
# be exactly as sound if this verb did not exist. A later reader who concludes
# "the arms were loosened BECAUSE rollback now exists" will loosen them again
# the next time somebody adds a recovery path. They are two independent
# changes that happen to ship together.
#
# AND WHAT IT CANNOT RESTORE, stated here because a recovery path believed to
# be wider than it is, is worse than a known-absent one. This restores the PIN
# and the INSTALLED BINARY. It does not restore a KILLED AGENT'S CONTEXT. The
# irreversible core of the restart hazard is untouched by this verb. Until
# 2026-09-12 that sentence was the reason the board-quiet arm stayed absolute;
# the operator then removed the board arms on a MEASURED premise — the restart
# path kills no worker window (enumerated and exercised on a private tmux),
# and a crashed worker is continued from its transcript via
# `spawn-worker.sh --resume` — so the protection this verb cannot give is now
# supplied by the restart path never targeting a worker, not by a veto. The
# deployment-gate knob block at the top of this file carries the decision, the
# quoted sentence and the measurements. This paragraph is NOT a licence to
# remove the two remaining PR arms; those stand on their own reasoning.
cmd_rollback() {
    local reason="" to="" force=0
    while (( $# > 0 )); do
        case "$1" in
            --reason) reason="$2"; shift 2 ;;
            # Explicit target, for a caller that knows better than the
            # breadcrumb (an operator recovering a torn state by hand).
            --to)     to="$2"; shift 2 ;;
            --force)  force=1; shift ;;
            *) note "rollback: unknown arg $1"; exit 2 ;;
        esac
    done

    local bc="$AUTO_DIR/rollback-state" prior="" candidate="unknown"
    if [[ -n "$to" ]]; then
        prior="$to"
        note "rollback: target supplied explicitly (--to $to); the breadcrumb is not consulted"
    elif [[ -r "$bc" ]]; then
        prior=$(awk -F= '$1=="prior_pin"{print $2; exit}' "$bc" 2>/dev/null)
        candidate=$(awk -F= '$1=="candidate"{print $2; exit}' "$bc" 2>/dev/null)
        [[ -n "$candidate" ]] || candidate="unknown"
    else
        note "REFUSED: no rollback breadcrumb at $bc and no --to given — there is nothing to establish a prior pin FROM. This is a refusal, NOT a finding that the pin is already correct."
        exit 3
    fi
    # A breadcrumb that parsed to nothing is a TORN record, not an absent one,
    # and the two must not read alike. `<none>` is a VALUE (there was no local
    # pin; the shared floor was in force) and is handled below.
    if [[ -z "$prior" ]]; then
        note "REFUSED: $bc exists but no prior_pin could be parsed from it — a torn breadcrumb. Inspect it, then re-run with --to <version>."
        exit 3
    fi
    if [[ "$prior" != "<none>" && ! "$prior" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        note "REFUSED: prior pin '$prior' is not a version and not '<none>' — refusing to write it. An emptiness check is a presence test wearing a validity test's name."
        exit 3
    fi

    # THREE-VALUED, and for the same reason as the verify below (w227 skeptic
    # F1, swept from it). `cc_version_read_local_pin` returns non-zero for TWO
    # different worlds — no pin file at all, and a pin file that is present but
    # EMPTY or whitespace-only, which is exactly what a torn write leaves. A
    # bare `|| now_pin="<none>"` collapses them, and the collapse then feeds
    # the early-exit below: on the `prior=<none>` arm a TORN pin file would
    # compare equal to `<none>`, so the verb would exit 0 "nothing to restore"
    # and leave the torn file exactly where it was. "Could not read it" is not
    # "it is not there", and only one of those is safe to no-op on.
    local now_pin pin_path
    pin_path=$(cc_version_local_pin_path "$NEXUS_ROOT")
    if now_pin=$(cc_version_read_local_pin "$NEXUS_ROOT" 2>/dev/null); then
        :
    elif [[ -e "$pin_path" ]]; then
        # Present and unusable. Never equal to any prior, so the restore below
        # RUNS and overwrites or removes it — the safe direction.
        now_pin="<unreadable>"
        note "rollback: the local pin at $pin_path EXISTS but could not be read as a version (empty or whitespace — a torn write). Treating it as UNREADABLE, not as absent, and proceeding with the restore."
    else
        now_pin="<none>"
    fi
    if [[ "$now_pin" == "$prior" ]] && (( force == 0 )); then
        note "rollback: local pin is ALREADY $prior — nothing to restore. Re-running the install anyway would be the only remaining effect; pass --force if that is what you want."
        record_outcome "$candidate" "rollback-noop" "pin already $prior"
        exit 0
    fi

    note "rollback: restoring operator-local pin $now_pin -> $prior${reason:+ (reason: $reason)}"
    if [[ "$prior" == "<none>" ]]; then
        rm -f "$(cc_version_local_pin_path "$NEXUS_ROOT")" 2>/dev/null \
            || { note "FAILED: could not remove the local pin"; record_outcome "$candidate" "rollback-failed" "pin-remove"; exit 4; }
        note "rollback: local pin REMOVED — the shared package.json floor resumes"
    else
        cc_version_write_local_pin "$prior" "$NEXUS_ROOT" \
            || { note "FAILED: could not write the local pin"; record_outcome "$candidate" "rollback-failed" "pin-write"; exit 4; }
    fi

    # Reinstall at the restored effective version. The installer reads
    # whichever version the resolver names as effective, so restoring the pin
    # first and reinstalling second is the whole mechanism — there is no
    # separate "install version X" argument to get wrong.
    if ! "$INSTALL_CMD"; then
        note "FAILED: install ($INSTALL_CMD) after the pin restore. THE PIN IS RESTORED but the node_modules binary may still be the rolled-back-FROM version — the workspace is version-split in the OTHER direction. Recover: $INSTALL_CMD"
        record_outcome "$candidate" "rollback-failed" "install prior=$prior"
        notify "cc-auto-update: ROLLBACK to $prior — pin restored but the reinstall FAILED; run $INSTALL_CMD"
        exit 4
    fi

    # VERIFY, rather than assume. A rollback that reports success without
    # observing the binary is the manufactured-success shape: every visible
    # artefact says it worked and the only evidence would be an absence.
    #
    # THE EXPECTATION MUST RESOLVE BEFORE ANYTHING IS COMPARED (w227 skeptic
    # F1). This block previously read
    #
    #     want=$(cc_version_effective … || true)
    #     if [[ -z "$running" || ( -n "$want" && "$running" != "$want" ) ]]
    #
    # and the `|| true` turned a hard resolver error into an EMPTY `want`,
    # which made `-n "$want"` FALSE and DISABLED the comparison — reducing the
    # whole guard to "did the binary answer at all". Measured: with the floor
    # destroyed and the binary still at the rolled-back-FROM version, the verb
    # exited 0 logging "binary verified". A verify that cannot fail is worse
    # than no rollback at all, because it upgrades "we have no rollback" into
    # "we BELIEVE we have rollback" — and a belief is what a gate decision gets
    # made under. So: no `|| true`, and an unresolvable expectation is its own
    # loud failure with its own diagnostic, never a silent pass.
    #
    # Note WHY the expectation is re-derived rather than compared to $prior:
    # on the `<none>` arm the pin is REMOVED and the effective version becomes
    # the shared package.json floor, which is not $prior. The resolver is the
    # only thing that knows that, which is exactly why its failure must be
    # fatal here rather than absorbed.
    local want running
    want=$(cc_version_effective "$NEXUS_ROOT/package.json" "$PACKAGE" "$NEXUS_ROOT" 2>/dev/null) || want=""
    if [[ ! "$want" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        note "FAILED: post-rollback verify — could not RESOLVE the expected version after restoring the pin (got '${want:-<empty>}'). The pin was written and the install ran, but NOTHING HERE CAN CONFIRM the binary is correct, and 'could not check' is not 'checked and fine'. Inspect $NEXUS_ROOT/package.json and $(cc_version_local_pin_path "$NEXUS_ROOT")."
        record_outcome "$candidate" "rollback-failed" "verify-unresolvable-expectation want=${want:-empty} prior=$prior"
        notify "cc-auto-update: ROLLBACK to $prior — the expected version could NOT be resolved, so the post-install verify could not run. The rollback is UNCONFIRMED."
        exit 5
    fi
    running=$("$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [[ -z "$running" || "$running" != "$want" ]]; then
        note "FAILED: post-rollback verify — binary reports '${running:-<unreadable>}', expected '$want'. The pin says $prior; the BINARY does not agree."
        record_outcome "$candidate" "rollback-failed" "verify running=${running:-unreadable} want=$want"
        notify "cc-auto-update: ROLLBACK to $prior — post-install verify FAILED (binary reports ${running:-unreadable})"
        exit 5
    fi

    # Hold the reconcile. Without this the watcher's every-tick reconcile can
    # re-fire a hand-off toward the version we just rolled away from, which
    # would undo the rollback silently and on a timescale nobody is watching.
    local hold_note=""
    if _cc_auto_write_restart_hold "$AUTO_DIR" "rollback to $prior${reason:+: $reason}" "" ""; then
        hold_note="restart-hold written; release with: $SELF_PATH unhold"
    else
        hold_note="WARNING: restart-hold could NOT be written — the reconcile may re-fire toward the rolled-back-from version; write it: $SELF_PATH hold --reason 'rolled back'"
    fi

    # Consume the breadcrumb. Leaving it would let a second `rollback` restore
    # a pin that is already restored, from a record describing a bump that no
    # longer stands — a stale answer at no suspicious extreme.
    rm -f "$bc" 2>/dev/null || true

    note "rollback: COMPLETE — pin $prior, binary verified at $running. $hold_note"
    record_outcome "$candidate" "rolled-back" "prior=$prior running=$running from=$now_pin"
    notify "cc-auto-update: ROLLED BACK to $prior (was $now_pin); binary verified. $hold_note"
    exit 0
}

# your-org/nexus-code#1211. Two defects behind one incident: the verb was
# SILENT on success, so the evaluator re-ran it "purely to read its exit
# code" and appended a junk row; and it can be hand-invoked into LIVE state
# from any shell — and `last-eval`, which it OVERWRITES, is the watcher's
# Guard 4 (`_cc_auto_last_eval_skip`): a stray `--decision block` for the
# current candidate silently suppresses the next daily fire.
#
# (1) It PRINTS what it wrote — read back from disk, not echoed from the
#     arguments — and exits 41 if the write did not land.
# (2) CONTEXT GUARD, on this verb only. NEXUS_WORKER_WINDOW is exported by
#     spawn-worker.sh into every agent window; the evaluator's is
#     $CC_AUTO_WINDOW (default cc-auto-update, _cc_auto_update.sh). Any
#     OTHER window (a worker, the orchestrator, a skeptic) is refused at
#     rc 40 before either file is touched; unset (a plain shell, the
#     routine's own environment) and the evaluator window pass, so the
#     prompt's legitimate `record-outcome … compat-pr-opened` keeps
#     working. `--allow-context` is the deliberate operator override.
#     This guard would NOT have caught the recorded incident, which came
#     FROM the evaluator; (1) is what addresses that. The guard is worth
#     having against the class the issue names — an agent in another
#     window reaching the production writer by hand.
cmd_record_outcome() {
    local candidate="" decision="" detail="" allow_context=0
    while (( $# > 0 )); do
        case "$1" in
            --candidate) candidate="$2"; shift 2 ;;
            --decision)  decision="$2"; shift 2 ;;
            --detail)    detail="$2"; shift 2 ;;
            --allow-context) allow_context=1; shift ;;
            *) note "record-outcome: unknown arg $1"; exit 2 ;;
        esac
    done
    [[ -n "$candidate" && -n "$decision" ]] || { note "record-outcome: --candidate and --decision required"; exit 2; }
    local ctx="${NEXUS_WORKER_WINDOW:-}"
    if (( allow_context == 0 )) && [[ -n "$ctx" && "$ctx" != "$CC_AUTO_WINDOW" ]]; then
        note "record-outcome: REFUSED — NEXUS_WORKER_WINDOW='$ctx' is not the evaluator window '$CC_AUTO_WINDOW'. This verb OVERWRITES last-eval, the watcher's awaiting-operator guard (a stray decision=block for the current candidate suppresses the next daily fire). Nothing was written. Pass --allow-context for a deliberate operator invocation (your-org/nexus-code#1211)."
        exit 40
    fi
    record_outcome "$candidate" "$decision" "$detail"
    # Read back what landed; the arguments are not the evidence.
    local got_c got_d got_t row
    got_c=$(_cc_update_field "$AUTO_DIR/last-eval" candidate 2>/dev/null || true)
    got_d=$(_cc_update_field "$AUTO_DIR/last-eval" decision 2>/dev/null || true)
    got_t=$(_cc_update_field "$AUTO_DIR/last-eval" detail 2>/dev/null || true)
    row=$(tail -n 1 "$AUTO_DIR/decisions.tsv" 2>/dev/null || true)
    local row_ok=0
    [[ "$row" == *$'\t'"$candidate"$'\t'"$decision"$'\t'"$detail" ]] && row_ok=1
    if (( RECORD_OUTCOME_LAST_EVAL_OK == 1 && row_ok == 1 )) \
            && [[ "$got_c" == "$candidate" && "$got_d" == "$decision" && "$got_t" == "$detail" ]]; then
        note "record-outcome: wrote decisions.tsv row [${row//$'\t'/ | }] + last-eval (candidate=$got_c decision=$got_d detail=$got_t) in $AUTO_DIR"
        return 0
    fi
    note "record-outcome: write did NOT land — last-eval=$( (( RECORD_OUTCOME_LAST_EVAL_OK )) && echo "written (candidate=$got_c decision=$got_d detail=$got_t)" || echo "NOT written" ) decisions.tsv-row=$( (( row_ok )) && echo appended || echo "NOT appended (tail: ${row:-<empty>})" ) in $AUTO_DIR"
    exit 41
}

# ---- dispatch ---------------------------------------------------------------

verb="${1:-}"; shift || true
case "$verb" in
    safe)                 cmd_safe "$@" ;;
    restart-orchestrator) cmd_restart_orchestrator "$@" ;;
    compat-pr)            cmd_compat_pr "$@" ;;
    block)                cmd_block "$@" ;;
    record-outcome)       cmd_record_outcome "$@" ;;
    hold)                 cmd_hold "$@" ;;
    unhold)               cmd_unhold "$@" ;;
    hold-status)          cmd_hold_status "$@" ;;
    rollback)             cmd_rollback "$@" ;;
    *)                    usage ;;
esac
