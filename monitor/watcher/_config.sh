#!/usr/bin/env bash
# Watcher config resolution — the env → config → default lookup block
# for every knob the watcher consumes (one `config/load.sh` subprocess
# per key without an env override). Extracted verbatim from main.sh
# (your-org/your-nexus#180 seam S1); pure code movement, no logic
# change. The per-knob narrative comments live here with their knobs;
# the env-var → config-key index stays in main.sh's file header.
#
# NOT side-effect-free: sourcing this runs the ~50 lookups and sets
# the globals (INTERVAL, REPO, TARGET, the MONITOR_* family, the
# ORCH_* liveness knobs, RESPAWN_* guards, …) plus one export block.
# main.sh sources it exactly once, immediately after the early
# pidfile publish (issue 180 R5) — that publish MUST stay ahead of
# this block, because on a loaded NFS root these lookups can take
# >15 s, longer than launcher.sh's spawn-verify poll budget.
#
# Caller globals (set by main.sh before sourcing):
#   _cfg        path to config/load.sh (executable)
#   NEXUS_ROOT  resolved nexus root (consumed by the lookups only
#               indirectly via _cfg's own config file resolution)
INTERVAL="${MONITOR_INTERVAL:-$("$_cfg" monitor.interval_seconds 60)}"
REPO="${MONITOR_REPO:-$("$_cfg" github.repo)}"
USER_LOGIN="${MONITOR_USER_LOGIN:-$("$_cfg" github.user_login)}"
TARGET="${MONITOR_TARGET:-$("$_cfg" monitor.target_window orchestrator)}"
# Cockpit (svc.sh dashboard) window name. The cockpit pane runs svc.sh,
# not claude, so the idle/liveness probe must exempt it from the
# dead-worker sweep — see _idle_list_worker_windows (your-org/your-nexus#204).
# Hardcoded to `services` by entry.sh / svc.sh today; surfaced as a
# config knob so the exemption tracks any rename instead of drifting.
SERVICES_WINDOW="${MONITOR_SERVICES_WINDOW:-$("$_cfg" monitor.services_window services)}"
RETENTION_DAYS="${DIFF_RETENTION_DAYS:-$("$_cfg" monitor.diff_retention_days 7)}"
# Emit-archive-dir bounds (your-org/nexus-code#402 — prune_archive
# heartbeat-wedge fix). prune_archive is a SYNC scheduler probe (see
# main.sh task-registration; the ≤100 ms sync-cost contract), so its
# DIFF_DIR sweep must never scale with total-file-count. The sweep is
# now NAME-based (archive filenames embed a sortable UTC timestamp),
# governed by two bounds so a single run always finishes well under the
# heartbeat-staleness threshold regardless of how large the dir grew:
#   diff_max_files          — hard ceiling on archive count. A backstop
#     ABOVE the RETENTION_DAYS age-based steady state (emit-rate ×
#     retention_days ≈ 14k at 2k/day×7d); prune_archive force-deletes
#     the OLDEST entries beyond this so a high-emit-rate burst can't grow
#     the dir without bound between age boundaries. Set generously so
#     normal operation stays governed by RETENTION_DAYS. 0 disables the
#     count cap (age-only). Default 20000.
#   diff_prune_max_per_run  — max archive deletions per prune_archive
#     run. Bounds per-run cost: a large backlog drains over successive
#     600 s runs instead of one long sync sweep that stales the
#     heartbeat. 0 = unbounded (drain in one run). Default 5000.
MONITOR_DIFF_MAX_FILES="${MONITOR_DIFF_MAX_FILES:-$("$_cfg" monitor.diff_max_files 20000)}"
[[ "$MONITOR_DIFF_MAX_FILES" =~ ^[0-9]+$ ]] || MONITOR_DIFF_MAX_FILES=20000
MONITOR_DIFF_PRUNE_MAX_PER_RUN="${MONITOR_DIFF_PRUNE_MAX_PER_RUN:-$("$_cfg" monitor.diff_prune_max_per_run 5000)}"
[[ "$MONITOR_DIFF_PRUNE_MAX_PER_RUN" =~ ^[0-9]+$ ]] || MONITOR_DIFF_PRUNE_MAX_PER_RUN=5000
AGENT_DEAD_THRESHOLD="${AGENT_DEAD_THRESHOLD:-$("$_cfg" monitor.agent_dead_threshold 3)}"
# Default 3 (raised from 0 after the 2026-06-02 false-positive-respawn
# incident): the 2 s target_window probe must observe the window absent
# on 4 consecutive polls (~8 s) before a respawn fires. A duplicate
# orchestrator is a far worse outcome than an extra few seconds of
# revival latency.
AGENT_MISSING_RESPAWN_DELAY="${AGENT_MISSING_RESPAWN_DELAY:-$("$_cfg" monitor.agent_missing_respawn_delay 3)}"
AUTO_UNSTICK="${MONITOR_AUTO_UNSTICK:-$("$_cfg" monitor.watcher.auto_unstick true)}"
# Idle-worker probe knobs (see monitor/watcher/_idle_probe.sh).
# Resolved here so they're exported to the loop body and to the
# probe's sourced helpers. Env override > config > default.
MONITOR_IDLE_THRESHOLD_SECONDS="${MONITOR_IDLE_THRESHOLD_SECONDS:-$("$_cfg" monitor.idle_threshold_seconds 60)}"
MONITOR_IDLE_CLOSE_HOURS="${MONITOR_IDLE_CLOSE_HOURS:-$("$_cfg" monitor.idle_close_hours 24)}"
MONITOR_IDLE_POOL_SPAWN_GRACE_SECONDS="${MONITOR_IDLE_POOL_SPAWN_GRACE_SECONDS:-$("$_cfg" monitor.idle_pool_spawn_grace_seconds 120)}"
# Periodic full-state emit cadence (issue #72 D4). Every N seconds the
# next emit force-includes the `--- workspace snapshot ---` section
# regardless of transitions, so an operator reading at a distance gets
# a cumulative view at predictable cadence. 0 disables the periodic
# floor (transitions-only behaviour, pre-#72 default).
MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS="${MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS:-$("$_cfg" monitor.full_state_emit_interval_seconds 600)}"
# Full-state identity-check safety floor (issue #104). Even when the
# canonical-form snapshot is identical to the last emit, force a
# re-emit at least every N seconds — this IS the watcher's timeout
# HEARTBEAT on a static workspace: it proves the compose loop is
# alive, keeps the orchestrator paste channel warm, and resets the
# orchestrator-liveness paste clock.
#
# The default is COUPLED to the orchestrator-liveness knobs
# (emit-gate-recover). On a static workspace the heartbeat is the
# only paste, at effective cadence
# ceil(floor / full_state_emit_interval) * full_state_emit_interval;
# main.sh clamps orchestrator_dead_threshold up to that gap + one
# loop tick + margin, and the clamp must stay strictly below
# stale_paste_ceiling_seconds (default 1800). Default arithmetic:
# ceil(900/600)*600 = 1200s heartbeat → clamp 1200+60+60 = 1320s
# < 1800s ceiling, with 480s headroom for render/paste jitter. A
# floor past ~1600s (with default cadence/ceiling) makes the clamp
# decline and logs a startup WARN — raise stale_paste_ceiling_seconds
# too if you deliberately want a slower heartbeat.
# Operator-tunable via `monitor.full_state.safety_floor_seconds`.
MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS="${MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS:-$("$_cfg" monitor.full_state.safety_floor_seconds 900)}"
# Adaptive idle backoff for the full-state HEARTBEAT (emit/exemption
# fidelity). The safety floor above is the base cadence at which an
# UNCHANGED canonical still re-emits (the liveness heartbeat). On a
# genuinely quiet workspace that base (900s → ~1 wake / 20 min) is more
# often than the operator wants overnight. This backoff STRETCHES the
# effective floor the longer the canonical stays continuously unchanged:
# each time sustained idle crosses the next power-of-two multiple of the
# base, the effective floor doubles, capped at the max below. base=900,
# max=3600 → 900s while recently-active, 1800s after ~30 min idle, 3600s
# after ~60 min idle (≈1 wake/hour on a still night). It SNAPS BACK to the
# base the instant the canonical changes (main.sh resets the idle-streak
# anchor), so a genuine transition is never delayed — this only rarefies
# the no-change liveness heartbeat, never the change-triggered emit. The
# heartbeat still fires at the (stretched) floor, so a wedged orchestrator
# is still poked. Set enabled=false to restore the fixed-floor behaviour;
# max<=base also disables the stretch. Operator-tunable.
MONITOR_FULL_STATE_IDLE_BACKOFF_ENABLED="${MONITOR_FULL_STATE_IDLE_BACKOFF_ENABLED:-$("$_cfg" monitor.full_state.idle_backoff_enabled true)}"
case "$MONITOR_FULL_STATE_IDLE_BACKOFF_ENABLED" in true|false) ;; *) MONITOR_FULL_STATE_IDLE_BACKOFF_ENABLED=true ;; esac
MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS="${MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS:-$("$_cfg" monitor.full_state.idle_backoff_max_seconds 3600)}"
[[ "$MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS=3600
# Worker-side heartbeat staleness window (issue #74). The per-spawn
# Claude Code hooks write `monitor/.state/heartbeat/<window>.json`
# on every tool call / notification / user-prompt submission;
# pane-state.sh consults the file first and uses its state when
# `last_activity` is younger than this many seconds. Stale or
# missing ⇒ renderer detection. Plumbed through to pane-state.sh
# by `_idle_pane_state_get` in `_idle_probe.sh`.
MONITOR_HEARTBEAT_STALENESS_SECONDS="${MONITOR_HEARTBEAT_STALENESS_SECONDS:-$("$_cfg" monitor.heartbeat_staleness_seconds 30)}"
# Staleness window (seconds) for the CROSS-HOST nexus-instance heartbeat
# beacon (nexus-instance.lock's cross-machine companion; the flock guards the
# same-host case). A starter on ANOTHER host treats a beacon older than this
# as a dead holder and takes over; younger → a live peer → refuse.
# Deliberately GENEROUS relative to the ≤10s loop refresh cadence so a slow
# loop / cc-update self-restart never self-evicts a live remote instance
# (default 600s = 10 min). Exported so child processes (launcher → main.sh,
# entry.sh, bootstrap-recover.sh) and the _lib.sh helpers all read one
# window. See _nexus_instance_staleness_window in _lib.sh.
NEXUS_INSTANCE_HEARTBEAT_STALENESS="${NEXUS_INSTANCE_HEARTBEAT_STALENESS:-$("$_cfg" monitor.instance_heartbeat_staleness_seconds 600)}"
export NEXUS_INSTANCE_HEARTBEAT_STALENESS
# Per-comment emit cooldown (eligibility-staleness regression follow-up
# to PR #188). After a comment surfaces in an emit, subsequent emits of
# the same `comment:<id>` are dropped for this many seconds UNLESS the
# body content-hash changes (operator edited the request → re-surface
# fresh). Third defense layer behind the reactions filter (in
# `_snapshot_issue_comments`) and the suppress-emit channel: even when
# both upstream layers miss a re-surface, the cooldown caps the emit
# rate at 1-per-N-seconds-per-comment. 0 disables the filter.
# Default 300 (5 minutes); operator-tunable via
# `monitor.emit_cooldown_seconds`.
MONITOR_EMIT_COOLDOWN_SECONDS="${MONITOR_EMIT_COOLDOWN_SECONDS:-$("$_cfg" monitor.emit_cooldown_seconds 300)}"
# Garbage-collection horizon for the emit-history directory. Files
# older than this are pruned by `prune_archive`. Default 86400 (24h)
# — far longer than any reasonable cooldown, but short enough that a
# stale-but-rare comment-id never fills the directory.
MONITOR_EMIT_HISTORY_RETENTION_SECONDS="${MONITOR_EMIT_HISTORY_RETENTION_SECONDS:-$("$_cfg" monitor.emit_history_retention_seconds 86400)}"
# Content-hash dedup gate. Computed AFTER compose_report renders the
# body and BEFORE paste_to_target: when the stable-content hash of
# the candidate body matches a recently-emitted hash (ring, below)
# AND the time since that entry's emit is shorter than this cap, the
# paste is suppressed (a one-line `emit-dedup: suppressed
# identical-hash emit ...` entry is appended to watcher.log
# instead). Bypassed when the body carries eligible github comments
# (issue #152 narrowed the bypass to that single surface). NOT
# consulted for full-state cadence emits — those are adjudicated by
# the canonical identity check + safety floor above, whose timeout
# heartbeat must never be swallowed by this longer quiet window. 0
# disables the gate entirely. Default 86400 (24h).
MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS="${MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS:-$("$_cfg" monitor.emit_dedup_max_quiet_seconds 86400)}"
# Depth of the recent-emit hash ring the dedup gate compares against
# (emit-gate-recover). Depth 1 reproduces the old single-slot
# behavior — which an ALTERNATING pair of body shapes (the 2026-07-06
# resurface flood: parked-transition row ↔ pending-decision re-nag)
# defeats forever, since each body differs from the immediately
# previous one. A small ring collapses any short cycle of repeating
# shapes while genuinely new content still hashes fresh and emits.
MONITOR_EMIT_DEDUP_RING_SIZE="${MONITOR_EMIT_DEDUP_RING_SIZE:-$("$_cfg" monitor.emit_dedup_ring_size 8)}"
# Re-emit-until-acked registry for cross-repo bot-mention comments
# (nexus-code#236). The deliveries path surfaces a cross-repo `mention=`
# block exactly once (emit-once, cursor-gated); unlike in-$REPO comments
# it has no live-reaction backstop, so a single dropped paste loses it
# forever. The registry persists un-acked cross-repo blocks and re-feeds
# them into the emit pipeline until the bot 👀-acks them. See _reemit.sh.
#   _enabled        master switch. Default true.
#   _max_age        safety cap: evict (and stop re-emitting) an entry
#                   un-acked past this age, logging loudly. Default
#                   259200 (3 days, matching GitHub webhook retention).
#   _live_recheck   on GC, query the live reactions endpoint for entries
#                   past their re-emit cooldown and evict if the bot
#                   already reacted — recovers from a lost/truncated
#                   processed-comments cache. Default true. The re-emit
#                   cadence itself reuses MONITOR_EMIT_COOLDOWN_SECONDS.
MONITOR_REEMIT_ENABLED="${MONITOR_REEMIT_ENABLED:-$("$_cfg" monitor.reemit_enabled true)}"
MONITOR_REEMIT_MAX_AGE_SECONDS="${MONITOR_REEMIT_MAX_AGE_SECONDS:-$("$_cfg" monitor.reemit_max_age_seconds 259200)}"
MONITOR_REEMIT_LIVE_RECHECK="${MONITOR_REEMIT_LIVE_RECHECK:-$("$_cfg" monitor.reemit_live_recheck true)}"
# Body-INDEPENDENT re-emit backoff for cross-repo bot-mention blocks
# (`_filter_reemit_backoff`, hop 7 of `_gh_filter_dedup_pipeline`). The
# emit-cooldown filter keys its drop on (id, body-SHA), so a mention whose
# registry-stored body and live-snapshot body DIVERGE (operator edits the
# mention) defeats the SHA cooldown and the same id double-emits within
# seconds (your-org/nexus-code#358). This caps a mention id's re-emit
# cadence to once per N seconds REGARDLESS of body, giving the orchestrator
# time to 👀-ack. Separate from the #357 `last_recheck=` ack-recheck
# throttle — both coexist (this bounds EMIT cadence, that bounds RECHECK
# cadence). Default = MONITOR_EMIT_COOLDOWN_SECONDS (so the documented
# "re-emit cadence reuses the emit cooldown" contract holds, and disabling
# the emit cooldown disables this too); 0 disables. Operator-tunable via
# `monitor.mentions.reemit_backoff_seconds`.
MONITOR_REEMIT_BACKOFF_SECONDS="${MONITOR_REEMIT_BACKOFF_SECONDS:-$("$_cfg" monitor.mentions.reemit_backoff_seconds "$MONITOR_EMIT_COOLDOWN_SECONDS")}"
[[ "$MONITOR_REEMIT_BACKOFF_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_REEMIT_BACKOFF_SECONDS="$MONITOR_EMIT_COOLDOWN_SECONDS"
# Two-tier reaction-gated re-emit cadence (your-org/nexus-code#360). The
# bot's reaction IS the re-emit state machine — no file-tracked "done" flag,
# just the 👀/🚀 the orchestrator already places:
#   * NO 👀 yet (un-acknowledged)        -> FAST re-emit, _noeyes_minutes.
#                                           Nudge quickly until the bot 👀s.
#   * 👀 but no 🚀 (acked / in progress) -> SLOW re-emit, _norocket_hours.
#                                           Periodic "still on track?" check.
#   * 🚀 present (done)                  -> STOP (registry eviction).
# This makes the previously-inert 🚀 the terminal signal and the 👀 the
# fast-loop ack. The FAST tier is the floor `_filter_reemit_backoff` (#361)
# also enforces downstream; the registry gates both tiers at the source
# (`_reemit_pending`), so the policy holds even if the downstream backoff is
# disabled. Both cadences are operator-tunable; nothing is hardcoded.
MONITOR_REEMIT_NOEYES_MINUTES="${MONITOR_REEMIT_NOEYES_MINUTES:-$("$_cfg" monitor.mentions.reemit_noeyes_minutes 5)}"
[[ "$MONITOR_REEMIT_NOEYES_MINUTES" =~ ^[0-9]+$ ]] || MONITOR_REEMIT_NOEYES_MINUTES=5
MONITOR_REEMIT_NOROCKET_HOURS="${MONITOR_REEMIT_NOROCKET_HOURS:-$("$_cfg" monitor.mentions.reemit_norocket_hours 6)}"
[[ "$MONITOR_REEMIT_NOROCKET_HOURS" =~ ^[0-9]+$ ]] || MONITOR_REEMIT_NOROCKET_HOURS=6
# Terminal-ack on a CLOSED/MERGED target (your-org/nexus-code#384). The
# two-tier cadence above keeps a 👀'd cross-repo mention on the SLOW
# "still on track?" loop until a 🚀 (done) or max-age. That reminder is
# meaningful only while the target issue/PR is OPEN; once it is
# closed/merged there is nothing left to stay on track about, yet a bot 👀
# alone never evicts it, so an answered mention on a merged PR re-surfaced
# every slow cycle for the full max-age window (the bug #384). When true,
# `_reemit_gc` treats a non-operator 👀 as TERMINAL on a closed/merged
# target — eviction, matching `snapshot_github`'s EYES-clear for OPEN
# in-$REPO comments — while OPEN cross-repo work keeps its 6h reminder.
# Costs one extra (throttled) target-state API call per 👀'd entry that
# would otherwise persist. Gated by MONITOR_REEMIT_LIVE_RECHECK (the state
# check rides the same recheck pass). Operator-tunable; default true.
MONITOR_REEMIT_EVICT_EYES_ON_CLOSED="${MONITOR_REEMIT_EVICT_EYES_ON_CLOSED:-$("$_cfg" monitor.mentions.reemit_evict_eyes_on_closed true)}"
# Bound on the append-only processed-comments.txt 👀/🚀-ack cache
# (your-org/nexus-code#360). The cache is a propagation-lag / cadence
# bridge over the LIVE reaction query that is the real source of truth
# (snapshot_github GraphQL + the registry live-recheck); entries older than
# the bridge window are dead weight. `prune_archive` retains the most recent
# N entries (the file is append-ordered, newest at the tail), keeping it
# bounded without a format change. 0 disables pruning. Tunable; not hardcoded.
MONITOR_PROCESSED_COMMENTS_MAX_ENTRIES="${MONITOR_PROCESSED_COMMENTS_MAX_ENTRIES:-$("$_cfg" monitor.processed_comments_max_entries 2000)}"
[[ "$MONITOR_PROCESSED_COMMENTS_MAX_ENTRIES" =~ ^[0-9]+$ ]] || MONITOR_PROCESSED_COMMENTS_MAX_ENTRIES=2000
# Worker notifications log size cap (issue #76). The default
# `Notification` hook (see skills/nexus.worker-defaults/SKILL.md)
# `>>`-appends one row per claude-side notification event;
# render_idle_prelude rotates the file once it crosses this size.
MONITOR_NOTIFICATIONS_LOG_MAX_BYTES="${MONITOR_NOTIFICATIONS_LOG_MAX_BYTES:-$("$_cfg" monitor.notifications_log_max_bytes 10485760)}"
# Size caps for the remaining append-only .state telemetry files
# (your-org/your-nexus#180 item R2). Before these, only the
# notifications log (above) and watcher.log (launcher-side, but only
# AT LAUNCH) had any cap — the scheduler telemetry JSONL grew without
# bound (310 MB / 2.6M rows observed live after ~3 weeks), a slow
# disk-exhaustion path that ends in failed state writes. `prune_archive`
# (600 s task) rotates each file to `<name>.<epoch>` once it crosses
# its cap and prunes rotated archives older than DIFF_RETENTION_DAYS —
# the same lifecycle as the notifications log.
#   scheduler_log_max_bytes — watcher-scheduler.jsonl (per-fire rows at
#     2-5 s cadence ≈ 15 MB/day; 50 MiB ≈ a 3-4 day live window).
#   state_log_max_bytes     — watcher.log, functional-check.tsv,
#     action-log.jsonl (all far slower-growing; 10 MiB each).
MONITOR_SCHEDULER_LOG_MAX_BYTES="${MONITOR_SCHEDULER_LOG_MAX_BYTES:-$("$_cfg" monitor.scheduler.log_max_bytes 52428800)}"
MONITOR_STATE_LOG_MAX_BYTES="${MONITOR_STATE_LOG_MAX_BYTES:-$("$_cfg" monitor.state_log_max_bytes 10485760)}"
# Over-limit wake-loop knobs (issue #87). The watcher schedules the
# resume itself — the orchestrator may be suspended on the same Opus
# weekly budget, so we cannot rely on it to schedule its own wake.
MONITOR_OVER_LIMIT_WAKE_MARGIN_SECONDS="${MONITOR_OVER_LIMIT_WAKE_MARGIN_SECONDS:-$("$_cfg" monitor.over_limit.wake_margin_seconds 300)}"
MONITOR_OVER_LIMIT_INITIAL_BACKOFF_SECONDS="${MONITOR_OVER_LIMIT_INITIAL_BACKOFF_SECONDS:-$("$_cfg" monitor.over_limit.initial_backoff_seconds 60)}"
MONITOR_OVER_LIMIT_MAX_BACKOFF_SECONDS="${MONITOR_OVER_LIMIT_MAX_BACKOFF_SECONDS:-$("$_cfg" monitor.over_limit.max_backoff_seconds 300)}"
MONITOR_OVER_LIMIT_MAX_ATTEMPTS="${MONITOR_OVER_LIMIT_MAX_ATTEMPTS:-$("$_cfg" monitor.over_limit.max_attempts 10)}"
# Orchestrator-liveness fresh-spawn fallback. Layered on top of the
# PR #147 session-id pin: the pin fixed *who* gets resumed; this fallback
# ensures the orchestrator's absence is *detectable* and *recoverable*
# even when --continue / --resume can't help (wrong session resumed,
# hook misconfigured, claude wedged on the splash, etc.).
#
# The probe (#157) fires when the orchestrator has not reacted to a
# paste the watcher delivered more than ORCH_UNRESPONSIVE_THRESHOLD_S
# ago AND the target tmux window is still alive. "Reacted" means the
# orchestrator's session jsonl mtime has advanced past the paste's
# timestamp. On trip, a fresh-spawn is requested via
# monitor/watcher/spawn-fresh-orchestrator.sh — by default the helper
# kills the target and spawns claude with `--continue` (resumes the
# prior conversation from its jsonl) plus `--settings` (re-arms the
# session-pin hook), then pastes a situation report. The `--fresh`
# flag on the helper is reserved for true emergencies (jsonl corrupt,
# hook misconfigured, deliberate reset) and is not used from this
# routine probe path — unresponsiveness alone is not positive evidence
# the prior session is unrecoverable. Cooldown bounds retry rate.
#
# Replaces the pre-#157 jsonl-mtime-only liveness signal. That signal
# mistook quiet workspaces for dead orchestrators — an idle orch
# writes nothing, so its jsonl mtime aged out at ORCH_STALE_SECONDS
# and the probe fired every cooldown. The paste-driven rule honours
# the operator's directive: idle is alive; only unresponse to a real
# paste is death. Feature can be disabled via
# monitor.orchestrator_fresh_spawn_enabled.
ORCH_FRESH_SPAWN_ENABLED="${MONITOR_ORCHESTRATOR_FRESH_SPAWN_ENABLED:-$("$_cfg" monitor.orchestrator_fresh_spawn_enabled true)}"
# Legacy `orchestrator_stale_seconds`: was the jsonl-mtime-only
# threshold for the pre-#157 liveness rule. Now kept only as the
# freshness window for `_orchestrator_poll_refresh_pin` (which still
# refreshes the pin file's mtime when the pinned jsonl is fresh — the
# pin's role under the new rule is just providing the sid lookup).
ORCH_STALE_SECONDS="${MONITOR_ORCHESTRATOR_STALE_SECONDS:-$("$_cfg" monitor.orchestrator_stale_seconds $(( INTERVAL * 5 )))}"
ORCH_FRESH_SPAWN_COOLDOWN_SECONDS="${MONITOR_ORCHESTRATOR_FRESH_SPAWN_COOLDOWN_SECONDS:-$("$_cfg" monitor.orchestrator_fresh_spawn_cooldown_seconds 1800)}"
# Paste-driven unresponsive-window (#157). Replaces the previous
# jsonl-mtime-only threshold. The probe fires only when:
#   - the orchestrator was pasted to more than this many seconds ago,
#     AND
#   - its session jsonl mtime has NOT advanced past the paste
#     timestamp (orch demonstrably didn't react).
# Default 120 s: long enough to absorb multi-step tool turns, short
# enough to catch a real wedge before the operator notices.
ORCH_UNRESPONSIVE_THRESHOLD_S="${MONITOR_ORCH_UNRESPONSIVE_THRESHOLD_S:-$("$_cfg" monitor.orchestrator_unresponsive_threshold_seconds 120)}"
# Hook-driven heartbeat state machine (#164). Replaces the binary
# `unresponsive_age > threshold` rule from #157 with a three-knob
# model: grace before unstick kicks in, budget for unstick to
# resolve a wedge, and a hard floor for "no heartbeat at all even
# through unstick." See monitor/watcher/_orchestrator_liveness.sh
# for the decision tree. Defaults: grace=120, unstick_window=150,
# dead_threshold=300. Grace + unstick_window (270) sits below the
# dead_threshold (300) so the one-shot re-submit rescue retains a
# verification window before the absolute deadline — false
# positives drop to near zero once the Stop hook fires reliably,
# so the actual respawn threshold can be much higher than #157's
# 120 s.
#
# Backward compat: when MONITOR_ORCH_UNRESPONSIVE_THRESHOLD_S
# (the #157 env var) is explicitly set, its value seeds the
# dead_threshold knob so existing deployments don't see a
# behaviour change on upgrade. Removed in a future release; the
# config key `monitor.orchestrator_unresponsive_threshold_seconds`
# is similarly deprecated but kept for one cycle.
ORCH_PASTE_RESPONSE_GRACE_S="${MONITOR_ORCH_PASTE_RESPONSE_GRACE_S:-$("$_cfg" monitor.watcher.paste_response_grace_seconds 120)}"
ORCH_UNSTICK_WINDOW_S="${MONITOR_ORCH_UNSTICK_WINDOW_S:-$("$_cfg" monitor.watcher.unstick_window_seconds 150)}"
# Waiting-verdict log throttle. The liveness task polls every ~5 s;
# without throttling a single slow turn produced ~40 identical
# `waiting` lines (2026-05-29..31 incidents). State entries,
# transitions, and resubmit/respawn events always log.
ORCH_LIVENESS_LOG_THROTTLE_S="${MONITOR_ORCH_LIVENESS_LOG_THROTTLE_S:-$("$_cfg" monitor.watcher.liveness_log_throttle_seconds 30)}"
if [[ -n "${MONITOR_ORCH_UNRESPONSIVE_THRESHOLD_S:-}" ]]; then
    # Legacy env var explicitly set — seed the new floor so an
    # operator's `MONITOR_ORCH_UNRESPONSIVE_THRESHOLD_S=240` keeps
    # its semantics. Logged at startup so the deprecation is
    # discoverable.
    ORCH_DEAD_THRESHOLD_S_DEFAULT="${MONITOR_ORCH_UNRESPONSIVE_THRESHOLD_S}"
else
    ORCH_DEAD_THRESHOLD_S_DEFAULT=300
fi
ORCH_DEAD_THRESHOLD_S="${MONITOR_ORCH_DEAD_THRESHOLD_S:-$("$_cfg" monitor.watcher.orchestrator_dead_threshold_seconds "$ORCH_DEAD_THRESHOLD_S_DEFAULT")}"
# Stale-paste ceiling: upper bound on how old a paste timestamp may
# be and still serve as evidence of wedging. Caps the dead-threshold
# check — once the paste is too old, pure idle is not the same as
# wedged. Default 1800 s (30 min): well above dead_threshold (300)
# so the wedge window stays intact, large enough that a quiet
# workspace with no eligible pastes for half an hour stops tripping
# false-positive respawns. Must satisfy ORCH_DEAD_THRESHOLD_S <
# ORCH_STALE_PASTE_CEILING_S — otherwise the ceiling masks the
# dead-threshold inside the wedge window and the detector never
# fires.
ORCH_STALE_PASTE_CEILING_S="${MONITOR_ORCH_STALE_PASTE_CEILING_S:-$("$_cfg" monitor.watcher.stale_paste_ceiling_seconds 1800)}"
# Dead-threshold floor margin (2026-06-15 incident). main.sh clamps the
# effective dead_threshold up to (full_state_emit_interval + loop_interval
# + this margin) whenever the configured dead_threshold would otherwise sit
# at or below the maximum gap between compose_emit fires — closing the
# static-workspace false-positive respawn race at the source rather than
# leaning on the runtime idle-pane guard. The margin keeps the deadline a
# comfortable step beyond the worst-case paste gap (scheduler jitter,
# slow emits). Default 60 s. With defaults this lifts dead_threshold from
# 300 to full_state(600)+interval(60)+60 = 720 s.
ORCH_DEAD_THRESHOLD_FLOOR_MARGIN_S="${MONITOR_ORCH_DEAD_THRESHOLD_FLOOR_MARGIN_S:-$("$_cfg" monitor.watcher.dead_threshold_floor_margin_seconds 60)}"
# Idle-pane override budget (2026-06-15 incident). The runtime idle-pane
# guard in `_v2_task_orchestrator_liveness` suppresses a dead-threshold
# respawn when `monitor/pane-state.sh` reports the orchestrator alive and
# idle/empty (a false positive in a static workspace). The budget bounds
# that suppression: after this many CONSECUTIVE overrides with no
# intervening genuine-healthy verdict (the orchestrator never advanced a
# single liveness signal), the guard escalates and honors the respawn.
# This is the safety floor against the false-negative — a hung-but-idle
# TUI cannot suppress its own respawn forever. The counter resets on any
# genuine healthy verdict (the orchestrator demonstrably responded), so a
# merely-quiet healthy orchestrator that answers even one full-state paste
# never approaches the budget. Default 5 (~5 full-state cycles ≈ 55 min of
# an idle-rendering, signal-silent orchestrator before the bounded respawn
# fires). Set to 0 to disable the bound entirely (revert to unconditional
# suppression — NOT recommended; reintroduces the dead-forever risk).
ORCH_IDLE_OVERRIDE_MAX="${MONITOR_ORCH_IDLE_OVERRIDE_MAX:-$("$_cfg" monitor.watcher.idle_pane_override_max 5)}"
# Functional-check signal (other-nexus-lessons L1). Orthogonal to the
# pid/heartbeat/paste-receipt rules above: even a wedged orchestrator
# that passes those can quietly fail to issue `gh api reactions`
# writes against surfaced eligible comments. The functional check
# scans the most recent emit-archive files in monitor/.state/diffs/
# for bot-reaction evidence. Set to 0 to disable. Default 600 s.
# Runs on a slower 600 s cadence (see _schedule_task functional_check
# below) so the per-fire network calls don't load the main loop.
MONITOR_FUNCTIONAL_SLA_SECONDS="${MONITOR_FUNCTIONAL_SLA_SECONDS:-$("$_cfg" monitor.functional_sla_seconds 600)}"
MONITOR_FUNCTIONAL_MAX_EMITS="${MONITOR_FUNCTIONAL_MAX_EMITS:-$("$_cfg" monitor.functional_max_emits 5)}"
# ---- watcher-robustness: bounded snapshot + emit-functional liveness ----
# (nexus-code#236, silent-watcher hardening). The change-detection snapshot
# (`snapshot_local` -> last-snapshot.txt, diffed each compose_emit) must stay
# O(1)-ish and noise-free regardless of how many git worktrees / reports
# accumulate. Two sources of unbounded cost + churn are gated here.
#
#   _git_enabled   include the per-worktree `--- git ---` section in the
#                  CHANGE-DETECTION snapshot. DEFAULT FALSE: every git-row
#                  transition (clean<->dirty, SHA bump, worktree add/remove)
#                  is already classified as pure NOISE by `_classify_diff`,
#                  so computing it (one `git status --porcelain` per worktree
#                  — the 109-worktree / ~66 s stall on 2026-06-18) buys ZERO
#                  signal. Off by default removes that cost entirely; the
#                  full-state DISPLAY snapshot is unaffected. Set true only to
#                  restore the legacy (cost-bearing, suppressed) behaviour.
#   _reports_timeout  wall-clock budget (s) for the reports-dir scan. On an
#                  NFS stall the scan is killed and a stable sentinel +
#                  throttled WARN are emitted instead of wedging the loop.
#   _git_timeout   wall-clock budget (s) for the git scan when _git_enabled.
MONITOR_SNAPSHOT_GIT_ENABLED="${MONITOR_SNAPSHOT_GIT_ENABLED:-$("$_cfg" monitor.snapshot.git_enabled false)}"
case "$MONITOR_SNAPSHOT_GIT_ENABLED" in true|false) ;; *) MONITOR_SNAPSHOT_GIT_ENABLED=false ;; esac
MONITOR_SNAPSHOT_REPORTS_TIMEOUT_SECONDS="${MONITOR_SNAPSHOT_REPORTS_TIMEOUT_SECONDS:-$("$_cfg" monitor.snapshot.reports_timeout_seconds 5)}"
[[ "$MONITOR_SNAPSHOT_REPORTS_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_SNAPSHOT_REPORTS_TIMEOUT_SECONDS=5
MONITOR_SNAPSHOT_GIT_TIMEOUT_SECONDS="${MONITOR_SNAPSHOT_GIT_TIMEOUT_SECONDS:-$("$_cfg" monitor.snapshot.git_timeout_seconds 10)}"
[[ "$MONITOR_SNAPSHOT_GIT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_SNAPSHOT_GIT_TIMEOUT_SECONDS=10
# Wall-clock budget (s) for the SYNCHRONOUS startup-sweep heavy renders
# (idle section, pending decisions, full-state snapshot). These run once
# before the main loop starts and used to block it unboundedly (the 66 s
# startup stall). Each is wrapped to abort LOUDLY past this budget and
# continue with a partial sweep rather than delay the first emit forever.
MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS="${MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS:-$("$_cfg" monitor.startup_render_timeout_seconds 20)}"
[[ "$MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS=20
# Emit-FUNCTIONAL liveness is the HEARTBEAT itself (no separate knob). The
# watcher bumps watcher-heartbeat ONLY at the end of a correct compose cycle
# (main.sh), so `_watcher_alive`'s existing heartbeat-age thresholds
# (2×interval+15 fresh / 5×interval DEAD) already mean "a full cycle completed
# recently" — fresh ⇒ loop works (even when deliberately silent), stale ⇒ loop
# wedged. A quiet workspace is SUPPOSED to be silent for long stretches (saves
# tokens); the heartbeat stays fresh because the cycle still RUNS every
# interval. Nothing to tune here beyond monitor.interval_seconds.
# Watcher self-heal master switch + delivery-failure threshold. When the
# watcher's OWN paste delivery to the orchestrator fails this many times
# CONSECUTIVELY (rc 3/4 — tmux glitch / content-not-landing; NOT rc 2
# target-missing, which is the orchestrator-respawn path), it escalates
# LOUDLY and self-restarts via the version-restart primitive (sharing its
# cooldown + loop guard, so recovery can never storm). false ⇒ loud alert
# only, no self-restart (supervisor backstop still applies).
MONITOR_WATCHER_SELF_HEAL_ENABLED="${MONITOR_WATCHER_SELF_HEAL_ENABLED:-$("$_cfg" monitor.watcher.self_heal_enabled true)}"
case "$MONITOR_WATCHER_SELF_HEAL_ENABLED" in true|false) ;; *) MONITOR_WATCHER_SELF_HEAL_ENABLED=true ;; esac
MONITOR_EMIT_DELIVERY_FAIL_LIMIT="${MONITOR_EMIT_DELIVERY_FAIL_LIMIT:-$("$_cfg" monitor.watcher.delivery_fail_limit 3)}"
[[ "$MONITOR_EMIT_DELIVERY_FAIL_LIMIT" =~ ^[0-9]+$ ]] || MONITOR_EMIT_DELIVERY_FAIL_LIMIT=3
# Claude Code update-detection (GATED self-update, detect→inform half).
# The cc_version_check task (registered below) compares the package.json
# pin against the npm `latest` dist-tag on a slow cadence and, on a newer
# release, writes monitor/.state/cc-update-available which the emit then
# surfaces ONCE, pointing at the updater skill. NEVER auto-bumps. Set the
# interval to 0 to disable detection entirely.
MONITOR_CC_UPDATE_INTERVAL_SECONDS="${MONITOR_CC_UPDATE_INTERVAL_SECONDS:-$("$_cfg" monitor.cc_update.interval_seconds 86400)}"
[[ "$MONITOR_CC_UPDATE_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_CC_UPDATE_INTERVAL_SECONDS=86400
# Emit gate for the manual "update available" nag. DEFAULT FALSE — the
# orchestrator-facing emit is silent unless deliberately re-enabled. With
# the autonomous daily routine (cc_auto_update, ~04:00) closing the gated
# loop on its own, the manual evaluation nag is redundant. Detection still
# runs and maintains the signal file regardless of this flag; this only
# gates whether _cc_update_emit_section surfaces the section. Set to true
# to restore the manual gate. Env: MONITOR_CC_UPDATE_EMIT_ENABLED.
MONITOR_CC_UPDATE_EMIT_ENABLED="${MONITOR_CC_UPDATE_EMIT_ENABLED:-$("$_cfg" monitor.cc_update.emit_enabled false)}"
case "$MONITOR_CC_UPDATE_EMIT_ENABLED" in true|false) ;; *) MONITOR_CC_UPDATE_EMIT_ENABLED=false ;; esac
MONITOR_CC_UPDATE_PACKAGE="${MONITOR_CC_UPDATE_PACKAGE:-$("$_cfg" monitor.cc_update.package @anthropic-ai/claude-code)}"
MONITOR_CC_UPDATE_SKILL_PATH="${MONITOR_CC_UPDATE_SKILL_PATH:-$("$_cfg" monitor.cc_update.skill_path skills/nexus.cc-update/GUIDE.md)}"
MONITOR_CC_UPDATE_FETCH_TIMEOUT_SECONDS="${MONITOR_CC_UPDATE_FETCH_TIMEOUT_SECONDS:-$("$_cfg" monitor.cc_update.fetch_timeout_seconds 10)}"
[[ "$MONITOR_CC_UPDATE_FETCH_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_CC_UPDATE_FETCH_TIMEOUT_SECONDS=10
# Autonomous daily cc-update routine (the DRIVE half closing the gated
# loop; see monitor/watcher/_cc_auto_update.sh). Once daily at
# `fire_time` (local tz, anacron-style catch-up) the cc_auto_update
# task re-checks the registry and, when a new candidate exists, spawns
# the autonomous evaluator worker that runs the full GUIDE flow —
# including, on a provably-safe verdict, the Step-5/5b bump + watchdog'd
# orchestrator restart with no operator engagement. DEFAULT OFF: an
# operator enables it deliberately (monitor.cc_auto_update.enabled:
# true) after reviewing the autonomy/safety design — an auto-bump
# routine must never go live as a silent side effect of `git pull`.
# The check interval is the due-window poll cadence, not the fire
# cadence (fires are gated to once per calendar day by the
# last-fire-date stamp).
MONITOR_CC_AUTO_UPDATE_ENABLED="${MONITOR_CC_AUTO_UPDATE_ENABLED:-$("$_cfg" monitor.cc_auto_update.enabled false)}"
MONITOR_CC_AUTO_UPDATE_FIRE_TIME="${MONITOR_CC_AUTO_UPDATE_FIRE_TIME:-$("$_cfg" monitor.cc_auto_update.fire_time 04:00)}"
[[ "$MONITOR_CC_AUTO_UPDATE_FIRE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || MONITOR_CC_AUTO_UPDATE_FIRE_TIME="04:00"
MONITOR_CC_AUTO_UPDATE_CHECK_INTERVAL_SECONDS="${MONITOR_CC_AUTO_UPDATE_CHECK_INTERVAL_SECONDS:-$("$_cfg" monitor.cc_auto_update.check_interval_seconds 300)}"
[[ "$MONITOR_CC_AUTO_UPDATE_CHECK_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_CC_AUTO_UPDATE_CHECK_INTERVAL_SECONDS=300
# Tracking issue number on the IMPLEMENTATION repo your-org/nexus-code
# (NOT github.repo — the operator's asset repo must NEVER receive
# cc-update notices; see the routing invariant in
# monitor/cc-auto-update-prompt.md). The evaluator wraps up against it
# only on a surfaced verdict (review/compat/block) — a SAFE auto-update
# stays silent. Empty = no standing issue; the evaluator opens a fresh
# your-org/nexus-code issue if it needs to surface a block.
MONITOR_CC_AUTO_UPDATE_TRACKING_ISSUE="${MONITOR_CC_AUTO_UPDATE_TRACKING_ISSUE:-$("$_cfg" monitor.cc_auto_update.tracking_issue "")}"
# Version-aware component auto-restart (your-org/your-nexus#186; see
# monitor/watcher/_version_restart.sh for the component model + safety
# guards). ON by default: the operator's goal is "git pull is the
# entire update story", and the guards (per-component source-set hash,
# stability window, torn-pull detection, per-component cooldown,
# self-restart loop guard) bound the blast radius. Set the master
# enable to false — or the interval to 0 — to fall back to the manual
# pull-then-restart discipline. The per-channel knobs degrade a
# confirmed drift to an emit advisory instead of an action (never
# silent). NOTE the bootstrap caveat: only a version-aware watcher can
# auto-restart anything, so the FIRST deploy of this feature is itself
# still a manual `monitor/svc.sh restart watcher`.
MONITOR_VERSION_RESTART_ENABLED="${MONITOR_VERSION_RESTART_ENABLED:-$("$_cfg" monitor.version_restart.enabled true)}"
MONITOR_VERSION_CHECK_INTERVAL_SECONDS="${MONITOR_VERSION_CHECK_INTERVAL_SECONDS:-$("$_cfg" monitor.version_restart.interval_seconds 60)}"
[[ "$MONITOR_VERSION_CHECK_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_VERSION_CHECK_INTERVAL_SECONDS=60
# A changed source-set hash must hold still for this long before any
# action — the torn-pull / mid-write tolerance window. With the 60 s
# check cadence the default 45 s means action lands on the second
# consecutive observation of the same new hash (~60–120 s after pull).
MONITOR_VERSION_SETTLE_SECONDS="${MONITOR_VERSION_SETTLE_SECONDS:-$("$_cfg" monitor.version_restart.settle_seconds 45)}"
[[ "$MONITOR_VERSION_SETTLE_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_VERSION_SETTLE_SECONDS=45
# Per-component action cooldown: after a restart/ask, further actions
# on the SAME component wait at least this long (slow retry, no thrash).
MONITOR_VERSION_RESTART_COOLDOWN_SECONDS="${MONITOR_VERSION_RESTART_COOLDOWN_SECONDS:-$("$_cfg" monitor.version_restart.cooldown_seconds 600)}"
[[ "$MONITOR_VERSION_RESTART_COOLDOWN_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_VERSION_RESTART_COOLDOWN_SECONDS=600
# Per-channel action switches. false ⇒ confirmed drift becomes an emit
# advisory instead of an automatic restart. The cockpit channel has no
# switch: it is ALWAYS advisory (the watcher never touches the
# orchestrator-owned TUI window).
MONITOR_VERSION_SELF_RESTART="${MONITOR_VERSION_SELF_RESTART:-$("$_cfg" monitor.version_restart.self true)}"
MONITOR_VERSION_SERVICE_RESTART="${MONITOR_VERSION_SERVICE_RESTART:-$("$_cfg" monitor.version_restart.services true)}"
# Watcher self-restart loop guard: at most <limit> auto self-restarts
# per <window> seconds; past that the guard trips, auto self-restart
# suspends (advisory emitted), and a full quiet window re-arms it.
MONITOR_VERSION_SELF_LOOP_LIMIT="${MONITOR_VERSION_SELF_LOOP_LIMIT:-$("$_cfg" monitor.version_restart.self_loop_limit 3)}"
[[ "$MONITOR_VERSION_SELF_LOOP_LIMIT" =~ ^[0-9]+$ ]] || MONITOR_VERSION_SELF_LOOP_LIMIT=3
MONITOR_VERSION_SELF_LOOP_WINDOW_SECONDS="${MONITOR_VERSION_SELF_LOOP_WINDOW_SECONDS:-$("$_cfg" monitor.version_restart.self_loop_window_seconds 3600)}"
[[ "$MONITOR_VERSION_SELF_LOOP_WINDOW_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_VERSION_SELF_LOOP_WINDOW_SECONDS=3600
# The tmux window hosting the services cockpit TUI (the drift ask
# names it; `tmux new-window -n services 'monitor/svc.sh'` is the
# documented launch in svc.sh's header).
MONITOR_COCKPIT_WINDOW="${MONITOR_COCKPIT_WINDOW:-$("$_cfg" monitor.cockpit_window services)}"
# Continuous service-health watch (service-health-watch). The
# `service_health` watcher task runs every registry service's column-4
# healthcheck on this cadence, auto-restarts the unhealthy ones (flap-
# controlled) via `svc.sh restart`, and surfaces down/recovering/flapping
# conditions to the orchestrator through compose_emit. See
# monitor/watcher/_service_health.sh. ON by default — availability is the
# point; set the master enable to false (or interval to 0) to fall back to
# supervisor-only self-heal with no continuous detection or emit.
MONITOR_SERVICE_HEALTH_ENABLED="${MONITOR_SERVICE_HEALTH_ENABLED:-$("$_cfg" monitor.service_health.enabled true)}"
# Health-check cadence in seconds. Default 120. A wedged HTTP service is
# detected within one interval; lower it for tighter detection at the cost
# of more frequent healthcheck spawns. 0 disables the task. Env:
# MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS.
MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS="${MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS:-$("$_cfg" monitor.service_health.interval_seconds 120)}"
[[ "$MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS=120
# Self-heal grace window in seconds. A freshly-unhealthy service is given
# this long to recover ON ITS OWN (its *-supervised.sh wrapper's self-heal)
# BEFORE the watcher takes any action — so a process-crash the wrapper
# relaunches heals without the watcher fighting it (no double-restart,
# churn, or masking). Only a service STILL unhealthy after grace (wedged
# process, or dead wrapper) is acted on. This is the "don't restart
# unnecessarily" knob. Default 30. 0 = act on first detection (legacy).
# Keep it below the interval so the next tick reliably finds grace elapsed.
# Env: MONITOR_SERVICE_HEALTH_GRACE_SECONDS.
MONITOR_SERVICE_HEALTH_GRACE_SECONDS="${MONITOR_SERVICE_HEALTH_GRACE_SECONDS:-$("$_cfg" monitor.service_health.grace_seconds 30)}"
[[ "$MONITOR_SERVICE_HEALTH_GRACE_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_SERVICE_HEALTH_GRACE_SECONDS=30
# Default per-service restart policy for registry rows that don't declare
# one (the optional 6th column). 'auto-restart' = grace → minimal-downtime
# restart (flap-controlled) → emit; 'emit-only' = never auto-restart, emit
# and let the orchestrator decide (for services where a blind restart is
# unsafe or wants human judgment). Default 'auto-restart' — availability is
# the point. Env: MONITOR_SERVICE_HEALTH_DEFAULT_POLICY.
MONITOR_SERVICE_HEALTH_DEFAULT_POLICY="${MONITOR_SERVICE_HEALTH_DEFAULT_POLICY:-$("$_cfg" monitor.service_health.default_policy auto-restart)}"
case "$MONITOR_SERVICE_HEALTH_DEFAULT_POLICY" in auto-restart|emit-only) ;; *) MONITOR_SERVICE_HEALTH_DEFAULT_POLICY=auto-restart ;; esac
# Per-service restart cooldown: after an auto-restart, the same service is
# not restarted again for at least this long — the next tick within the
# window only verifies / waits. Bounds thrash. Default 300. Env:
# MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS.
MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS="${MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS:-$("$_cfg" monitor.service_health.restart_cooldown_seconds 300)}"
[[ "$MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS=300
# Flap ceiling: max auto-restart attempts within ONE incident before the
# watcher stops thrashing and escalates "won't-recover" to the
# orchestrator. Re-arms when the service becomes healthy again. Default 3.
# Env: MONITOR_SERVICE_HEALTH_FLAP_CEILING.
MONITOR_SERVICE_HEALTH_FLAP_CEILING="${MONITOR_SERVICE_HEALTH_FLAP_CEILING:-$("$_cfg" monitor.service_health.flap_ceiling 3)}"
[[ "$MONITOR_SERVICE_HEALTH_FLAP_CEILING" =~ ^[0-9]+$ ]] || MONITOR_SERVICE_HEALTH_FLAP_CEILING=3
# Watcher-supervision (your-org/your-nexus, mutual-liveness design). The
# ORCHESTRATOR arms a persistent Monitor that revives a crashed watcher
# and touches a supervisor heartbeat each tick. The watcher's only role
# is the `--- arm watcher supervisor ---` emit reminder when that
# heartbeat is stale/absent (the Monitor isn't armed). ENABLED gates that
# reminder; ON by default — an unarmed supervisor means a watcher crash
# has no turn-independent revival.
MONITOR_WATCHER_SUPERVISOR_ENABLED="${MONITOR_WATCHER_SUPERVISOR_ENABLED:-$("$_cfg" monitor.watcher_supervisor.enabled true)}"
# How old (seconds) the supervisor heartbeat may get before the watcher
# concludes the Monitor is NOT armed and emits the reminder. Must comfortably
# exceed the Monitor's tick interval (~15s) so a healthy armed Monitor never
# trips it. Default 90. Env: MONITOR_WATCHER_SUPERVISOR_HEARTBEAT_STALE_SECONDS.
MONITOR_WATCHER_SUPERVISOR_HEARTBEAT_STALE_SECONDS="${MONITOR_WATCHER_SUPERVISOR_HEARTBEAT_STALE_SECONDS:-$("$_cfg" monitor.watcher_supervisor.heartbeat_stale_seconds 90)}"
[[ "$MONITOR_WATCHER_SUPERVISOR_HEARTBEAT_STALE_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_WATCHER_SUPERVISOR_HEARTBEAT_STALE_SECONDS=90

# ── Request inbox (agent-channel RFC Part B/D; monitor/watcher/_requests.sh) ──
# Master switch for the watcher-mediated request inbox. Default OFF (Phase
# B1 ships inert; flip on after a soak, RFC §5). When false the
# requests_poll task is a no-op (no claim, no emit), so a fresh clone is
# inert. Env: MONITOR_REQUESTS_ENABLED. NOTE: this flag is not the ONLY
# enable — _requests_enabled ALSO turns the inbox on when the confined
# remote channel (`nexus-remote-ssh`) is registered, because a remote
# client's only path to the orchestrator IS a filed request (see
# _requests.sh). So enabling the remote channel drains the inbox without
# needing this flag; local-only use still requires it.
MONITOR_REQUESTS_ENABLED="${MONITOR_REQUESTS_ENABLED:-$("$_cfg" monitor.requests.enabled false)}"
# Re-emit cooldown (seconds) for a claimed-but-unacked request — mirrors
# the pending-decisions cooldown. A claimed request re-surfaces every
# cooldown until the orchestrator acks/replies (renames it off .claimed).
# Default 300. Env: MONITOR_REQUESTS_REEMIT_COOLDOWN_SECONDS.
MONITOR_REQUESTS_REEMIT_COOLDOWN_SECONDS="${MONITOR_REQUESTS_REEMIT_COOLDOWN_SECONDS:-$("$_cfg" monitor.requests.reemit_cooldown_seconds 300)}"
[[ "$MONITOR_REQUESTS_REEMIT_COOLDOWN_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_REQUESTS_REEMIT_COOLDOWN_SECONDS=300
# Per-emit cap on the `--- requests ---` section (backlog bound). Ordered
# by (priority, ts) with origin round-robin; the rest wait for the next
# emit. Default 10. Env: MONITOR_REQUESTS_MAX_PER_EMIT.
MONITOR_REQUESTS_MAX_PER_EMIT="${MONITOR_REQUESTS_MAX_PER_EMIT:-$("$_cfg" monitor.requests.max_per_emit 10)}"
[[ "$MONITOR_REQUESTS_MAX_PER_EMIT" =~ ^[0-9]+$ && "$MONITOR_REQUESTS_MAX_PER_EMIT" -gt 0 ]] || MONITOR_REQUESTS_MAX_PER_EMIT=10
# Fairness: round-robin across distinct origins before FIFO-within-origin
# so one chatty origin cannot starve others. Set false for strict FIFO.
# Default true. Env: MONITOR_REQUESTS_FAIRNESS.
MONITOR_REQUESTS_FAIRNESS="${MONITOR_REQUESTS_FAIRNESS:-$("$_cfg" monitor.requests.fairness true)}"
# Max age (seconds) a request may sit .claimed before the watcher gives up
# and renames it .failed (a never-acked request cannot re-emit forever).
# Default 259200 (3 days, matching _reemit + webhook retention). Env:
# MONITOR_REQUESTS_MAX_AGE_SECONDS.
MONITOR_REQUESTS_MAX_AGE_SECONDS="${MONITOR_REQUESTS_MAX_AGE_SECONDS:-$("$_cfg" monitor.requests.max_age_seconds 259200)}"
[[ "$MONITOR_REQUESTS_MAX_AGE_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_REQUESTS_MAX_AGE_SECONDS=259200
# Retention (seconds) for terminal .done/.failed files + reply dirs before
# GC. Default 259200 (3 days). Env: MONITOR_REQUESTS_RETENTION_SECONDS.
MONITOR_REQUESTS_RETENTION_SECONDS="${MONITOR_REQUESTS_RETENTION_SECONDS:-$("$_cfg" monitor.requests.retention_seconds 259200)}"
[[ "$MONITOR_REQUESTS_RETENTION_SECONDS" =~ ^[0-9]+$ ]] || MONITOR_REQUESTS_RETENTION_SECONDS=259200

export MONITOR_REQUESTS_ENABLED MONITOR_REQUESTS_REEMIT_COOLDOWN_SECONDS \
       MONITOR_REQUESTS_MAX_PER_EMIT MONITOR_REQUESTS_FAIRNESS \
       MONITOR_REQUESTS_MAX_AGE_SECONDS MONITOR_REQUESTS_RETENTION_SECONDS
export MONITOR_IDLE_THRESHOLD_SECONDS MONITOR_IDLE_CLOSE_HOURS MONITOR_IDLE_POOL_SPAWN_GRACE_SECONDS MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS MONITOR_HEARTBEAT_STALENESS_SECONDS MONITOR_NOTIFICATIONS_LOG_MAX_BYTES \
       MONITOR_EMIT_COOLDOWN_SECONDS MONITOR_EMIT_HISTORY_RETENTION_SECONDS \
       MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS MONITOR_EMIT_DEDUP_RING_SIZE \
       MONITOR_REEMIT_ENABLED MONITOR_REEMIT_MAX_AGE_SECONDS MONITOR_REEMIT_LIVE_RECHECK \
       MONITOR_REEMIT_BACKOFF_SECONDS \
       MONITOR_REEMIT_NOEYES_MINUTES MONITOR_REEMIT_NOROCKET_HOURS \
       MONITOR_REEMIT_EVICT_EYES_ON_CLOSED \
       MONITOR_PROCESSED_COMMENTS_MAX_ENTRIES \
       MONITOR_FUNCTIONAL_SLA_SECONDS MONITOR_FUNCTIONAL_MAX_EMITS \
       MONITOR_SNAPSHOT_GIT_ENABLED MONITOR_SNAPSHOT_REPORTS_TIMEOUT_SECONDS \
       MONITOR_SNAPSHOT_GIT_TIMEOUT_SECONDS MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS \
       MONITOR_WATCHER_SELF_HEAL_ENABLED MONITOR_EMIT_DELIVERY_FAIL_LIMIT \
       MONITOR_CC_UPDATE_INTERVAL_SECONDS MONITOR_CC_UPDATE_PACKAGE \
       MONITOR_CC_UPDATE_SKILL_PATH MONITOR_CC_UPDATE_FETCH_TIMEOUT_SECONDS \
       MONITOR_CC_UPDATE_EMIT_ENABLED \
       MONITOR_VERSION_RESTART_ENABLED MONITOR_VERSION_CHECK_INTERVAL_SECONDS \
       MONITOR_VERSION_SETTLE_SECONDS MONITOR_VERSION_RESTART_COOLDOWN_SECONDS \
       MONITOR_VERSION_SELF_RESTART MONITOR_VERSION_SERVICE_RESTART \
       MONITOR_VERSION_SELF_LOOP_LIMIT MONITOR_VERSION_SELF_LOOP_WINDOW_SECONDS \
       MONITOR_COCKPIT_WINDOW \
       MONITOR_SERVICE_HEALTH_ENABLED MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS \
       MONITOR_SERVICE_HEALTH_GRACE_SECONDS MONITOR_SERVICE_HEALTH_DEFAULT_POLICY \
       MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS MONITOR_SERVICE_HEALTH_FLAP_CEILING \
       MONITOR_WATCHER_SUPERVISOR_ENABLED MONITOR_WATCHER_SUPERVISOR_HEARTBEAT_STALE_SECONDS \
       MONITOR_OVER_LIMIT_WAKE_MARGIN_SECONDS MONITOR_OVER_LIMIT_INITIAL_BACKOFF_SECONDS \
       MONITOR_OVER_LIMIT_MAX_BACKOFF_SECONDS MONITOR_OVER_LIMIT_MAX_ATTEMPTS
# Crash-loop guard for `respawn_agent`. If more than RESPAWN_LOOP_LIMIT
# respawns happen within RESPAWN_LOOP_WINDOW seconds, the watcher
# stops respawning the orchestrator until the sliding window empties
# (or until a paste-to-target succeeds, which clears the history). One
# sandbox-notify on the transition from ok → tripped, then quiet.
RESPAWN_LOOP_WINDOW="${MONITOR_RESPAWN_LOOP_WINDOW:-$("$_cfg" monitor.respawn_loop_window_seconds 120)}"
RESPAWN_LOOP_LIMIT="${MONITOR_RESPAWN_LOOP_LIMIT:-$("$_cfg" monitor.respawn_loop_limit 3)}"
# Asymmetric counterpart to the burst-limit guard (issue #77). The
# burst guard above trips on N respawns within W seconds; this one
# trips on N CONSECUTIVE FAILED respawns regardless of cadence — a
# 1-per-60 s drip that slides under the burst window otherwise grinds
# forever. After the counter crosses the limit, respawn attempts are
# paused for the cooldown, after which the counter resets so the
# guard re-arms.
RESPAWN_CONSEC_LIMIT="${MONITOR_RESPAWN_CONSECUTIVE_FAILURE_LIMIT:-$("$_cfg" monitor.respawn_consecutive_failure_limit 5)}"
RESPAWN_SLOW_GRIND_COOLDOWN="${MONITOR_RESPAWN_SLOW_GRIND_COOLDOWN_SECONDS:-$("$_cfg" monitor.respawn_slow_grind_cooldown_seconds 600)}"
RATELIMIT_PROBE="${MONITOR_RATELIMIT_PROBE:-$("$_cfg" monitor.watcher.ratelimit_probe false)}"
RATELIMIT_HEURISTIC_MIN="${MONITOR_RATELIMIT_HEURISTIC_MIN:-$("$_cfg" monitor.watcher.ratelimit_heuristic_minutes 30)}"
RATELIMIT_ACK_TIMEOUT_S="${MONITOR_RATELIMIT_ACK_TIMEOUT_S:-$("$_cfg" monitor.watcher.ratelimit_ack_timeout_s 60)}"
PROBE_MODEL="${MONITOR_PROBE_MODEL:-$("$_cfg" monitor.watcher.probe_model claude-haiku-4-5-20251001)}"
API_ERROR_BACKOFF_MIN="${MONITOR_API_ERROR_BACKOFF_MIN:-$("$_cfg" monitor.watcher.api_error_backoff_minutes 30)}"
# AskUserQuestion / chip-bar dialog handling (Case D — dialog-guard).
# Layer A1 (the `PreToolUse` matcher in
# `monitor/orchestrator-settings.json`) blocks the orchestrator from
# dispatching `AskUserQuestion` in the first place; this knob tunes
# the watcher's safety net for sessions whose settings file is
# missing/corrupt or for future modal shapes whose render carries
# the same chip-bar signature.
#   auto-dismiss (default) — capture pane, Escape, paste meta-message
#   skip                   — log detection only; the dialog is left
#                            in place. Useful for debugging.
#   error                  — log a WARN line; otherwise the same as
#                            skip (auditable via watcher-unstick.log).
ON_DIALOG="${MONITOR_ON_DIALOG:-$("$_cfg" monitor.watcher.on_dialog auto-dismiss)}"
# Worker-blocked-question relay grace (Case W in _unstick.sh;
# your-org/your-nexus#180). When a NON-target pane sits on a live
# AskUserQuestion overlay continuously for this many seconds, the
# watcher synthesizes a pending-decision record (kind
# `blocked_question`) so the orchestrator answers on the operator's
# behalf. The grace window is what gives a human at the pane first
# right of reply — an overlay answered during the grace simply
# vanishes and nothing fires. 0 disables the relay.
MONITOR_WORKER_ASKUQ_GRACE_SECONDS="${MONITOR_WORKER_ASKUQ_GRACE_SECONDS:-$("$_cfg" monitor.watcher.worker_askuq_grace_seconds 300)}"
# Deliveries-polling source — see monitor/watcher/_deliveries.sh. This is
# the near-real-time channel for operator comments on $REPO: an in-$REPO
# `issue_comment` arrives on the App's webhook delivery log and surfaces via
# the 15 s `deliveries_poll` task, instead of waiting up to ~600 s for the
# `github_poll` GraphQL reconciliation pass (which remains the backstop).
#
# Default ON (2026-06-23, operator decision). Originally default-OFF in PR A
# after the deliveries path wedged the loop 3× on 2026-06-20 — but that wedge
# (un-timed-out curls + a cursor that only advanced at the end of the walk)
# is fixed by guards 1–3 in `_deliveries.sh` (BOUNDED curls + two-phase
# incremental cursor + per-cycle fetch cap), proven by test-deliveries-*.sh.
# Safe to default ON: every curl is bounded by DELIVERIES_CONNECT_TIMEOUT /
# DELIVERIES_MAX_TIME (non-fatal skip on a hung endpoint, never blocks the
# loop), and the path degrades to a clean no-op when the App has no webhook
# URL configured — `/app/hook/deliveries` 404s, `snapshot_deliveries` logs a
# single warning per day and emits nothing. Operators opt out per concern via
# the two flags below.
#
# Deliveries flag SPLIT (your-org/nexus-code #244 follow-up). `snapshot_deliveries`
# serves TWO independent concerns, each with its own gate:
#   DELIVERIES_ASSET_ENABLED        in-$REPO (asset-nexus) comment surfacing —
#     no @bot-mention needed, emitted as `issue=`/`pr=`/`pr_review=`/`issue_new=`
#     shapes. (The always-on poll, `snapshot_github`, is the asset baseline and
#     is untouched by this flag.)
#   DELIVERIES_BOT_MENTION_ENABLED  cross-repo @bot-mention surfacing — emitted
#     as the `mention=` shape.
# Both default `true`, so a config with neither key gets BOTH concerns ON
# (preserving PR #343's ~15 s asset surfacing). An operator can run fast asset
# surfacing without the cross-repo @bot-mention webhook channel (or vice versa)
# by setting just one flag false.
DELIVERIES_ASSET_ENABLED="${MONITOR_DELIVERIES_ASSET_ENABLED:-$("$_cfg" monitor.deliveries.asset_enabled true)}"
case "$DELIVERIES_ASSET_ENABLED" in true|false) ;; *) DELIVERIES_ASSET_ENABLED=true ;; esac
DELIVERIES_BOT_MENTION_ENABLED="${MONITOR_DELIVERIES_BOT_MENTION_ENABLED:-$("$_cfg" monitor.deliveries.bot_mention_enabled true)}"
case "$DELIVERIES_BOT_MENTION_ENABLED" in true|false) ;; *) DELIVERIES_BOT_MENTION_ENABLED=true ;; esac
# Deliveries WEDGE-SAFETY knobs (the deliveries path took the live watcher
# down 3× in 20 min on 2026-06-20 — un-timed-out curls hung the loop until
# the async hang-watchdog reaped them, and the cursor only advanced at the
# end of the walk so every poll re-walked from scratch). All bound the
# `snapshot_deliveries` cost; see the function header in _deliveries.sh.
#   _connect_timeout / _max_time  hard ceiling on EVERY deliveries curl
#     (listing + per-delivery). A hung endpoint exits non-zero within the
#     budget and the cycle skips (non-fatal). Defaults 5s / 15s.
#   _max_fetch_per_cycle  cap on per-delivery payload fetches per cycle; a
#     larger backlog drains over successive cycles (the cursor advances
#     incrementally). Default 25.
#   _seed_on_first_run  empty-cursor behaviour. false (default) WALKS the
#     recent backlog (bounded by the guards above) so freshly-arrived,
#     un-acted @bot mentions surface on enable; true seeds the cursor to
#     the newest delivery and processes nothing.
DELIVERIES_CONNECT_TIMEOUT="${MONITOR_DELIVERIES_CONNECT_TIMEOUT:-$("$_cfg" monitor.deliveries.connect_timeout_seconds 5)}"
[[ "$DELIVERIES_CONNECT_TIMEOUT" =~ ^[0-9]+$ ]] || DELIVERIES_CONNECT_TIMEOUT=5
DELIVERIES_MAX_TIME="${MONITOR_DELIVERIES_MAX_TIME:-$("$_cfg" monitor.deliveries.max_time_seconds 15)}"
[[ "$DELIVERIES_MAX_TIME" =~ ^[0-9]+$ ]] || DELIVERIES_MAX_TIME=15
DELIVERIES_MAX_FETCH_PER_CYCLE="${MONITOR_DELIVERIES_MAX_FETCH_PER_CYCLE:-$("$_cfg" monitor.deliveries.max_fetch_per_cycle 25)}"
[[ "$DELIVERIES_MAX_FETCH_PER_CYCLE" =~ ^[0-9]+$ ]] || DELIVERIES_MAX_FETCH_PER_CYCLE=25
DELIVERIES_SEED_ON_FIRST_RUN="${MONITOR_DELIVERIES_SEED_ON_FIRST_RUN:-$("$_cfg" monitor.deliveries.seed_on_first_run false)}"
case "$DELIVERIES_SEED_ON_FIRST_RUN" in true|false) ;; *) DELIVERIES_SEED_ON_FIRST_RUN=false ;; esac
# `github.bot_login` is consumed by `_filter_cross_repo_surface` in
# `_github.sh` to gate cross-repo emits on an explicit `@<bot>` body
# mention (the default `monitor.cross_repo_surface=mention_only`).
# The chokepoint refactor (issue #86) had retired this value; the
# cross-repo filter (2026-05-18) made it load-bearing again. Empty
# value + `mention_only` mode degrades to `off` with a warning below.
BOT_LOGIN="${MONITOR_BOT_LOGIN:-$("$_cfg" github.bot_login "")}"
# Cross-repo surfacing mode — see `_filter_cross_repo_surface` in
# `_github.sh`. One of `mention_only` (default; cross-repo emits
# require `@<BOT_LOGIN>` in body), `author_only` (legacy; every
# user-authored cross-repo event surfaces), or `off` (no cross-repo
# emits ever). In-`$REPO` activity is unaffected — it is the canonical
# input channel and must never require an `@`-mention.
CROSS_REPO_SURFACE="${MONITOR_CROSS_REPO_SURFACE:-$("$_cfg" monitor.cross_repo_surface mention_only)}"
# Mentions-search fallback source — see monitor/watcher/_mentions.sh.
# Default OFF: operator opt-in. Surfaces cross-repo activity that
# mentions github.user_login in repos where the App is NOT installed
# (the gap deliveries can't reach). Complements the deliveries path;
# safe to enable both.
MENTIONS_ENABLED="${MONITOR_MENTIONS_ENABLED:-$("$_cfg" monitor.mentions_enabled false)}"
# Bot-mention cross-repo search source — see `snapshot_bot_mentions` in
# monitor/watcher/_mentions.sh. Default OFF: operator opt-in. The
# WEBHOOK-FREE, poll-based equivalent of the deliveries path: surfaces
# `@<github.bot_login>` mentions the operator posts on INSTALLED repos
# OTHER than $REPO — the gap that opens when the deliveries webhook is
# unavailable (no App webhook URL) or disabled. Surfaced as the
# actionable `mention=` shape and gated by `cross_repo_surface`'s
# `mention_only` default. Rides the same `github_poll` async task, the
# same GraphQL bucket + `_graphql_polling_gate`, and the same re-emit-
# until-👀 registry. Safe to enable alongside the deliveries path and
# `mentions_enabled` (cross-source `id=` duplicates collapse in the
# dedup hop). This is the durable channel for installed non-asset repos;
# enabling it does NOT require the fragile webhook.
#
# Default ON (2026-06-23, operator decision): "if the bot is addressed,
# the watcher should emit" is the out-of-the-box behaviour for every
# operator nexus. Safe-on because the channel is wedge-safe (the single
# GraphQL POST is a raw `curl` bounded by MENTIONS_CONNECT_TIMEOUT /
# MENTIONS_MAX_TIME and rides the gated, async `github_poll` task at
# ~1 GraphQL point/cycle) AND degrades to a clean no-op when no bot
# identity is configured: `snapshot_bot_mentions` returns before issuing
# any search when `BOT_LOGIN` is empty (the empty-handle search is never
# sent), and the startup check below logs a single warning. Operators who
# want it off set `monitor.bot_mentions_enabled: false`.
BOT_MENTIONS_ENABLED="${MONITOR_BOT_MENTIONS_ENABLED:-$("$_cfg" monitor.bot_mentions_enabled true)}"
case "$BOT_MENTIONS_ENABLED" in true|false) ;; *) BOT_MENTIONS_ENABLED=true ;; esac
# WEDGE-SAFETY for the bot-mention search curl (mirrors the deliveries
# DELIVERIES_CONNECT_TIMEOUT / DELIVERIES_MAX_TIME knobs). Hard ceiling
# on the single GraphQL POST `snapshot_bot_mentions` makes: a hung /
# black-holed endpoint exits non-zero within the budget and the cycle
# skips (non-fatal). Defaults 5s connect / 20s total. This is why the
# poll source uses raw `curl` rather than `gh api graphql` (which honours
# neither knob) — so enabling the source can NEVER re-wedge the loop.
MENTIONS_CONNECT_TIMEOUT="${MONITOR_MENTIONS_CONNECT_TIMEOUT:-$("$_cfg" monitor.mentions.connect_timeout_seconds 5)}"
[[ "$MENTIONS_CONNECT_TIMEOUT" =~ ^[0-9]+$ ]] || MENTIONS_CONNECT_TIMEOUT=5
MENTIONS_MAX_TIME="${MONITOR_MENTIONS_MAX_TIME:-$("$_cfg" monitor.mentions.max_time_seconds 20)}"
[[ "$MENTIONS_MAX_TIME" =~ ^[0-9]+$ ]] || MENTIONS_MAX_TIME=20
# GraphQL bucket-floor — see _graphql_polling_gate in _github.sh.
# Default threshold 200 graphql.remaining below which the
# `github_poll` task fire is skipped. The cadence is the task
# interval itself (registered as 600 s below); this knob is the
# reactive safety net for bursty bucket draws.
GRAPHQL_THRESHOLD="${MONITOR_GRAPHQL_THRESHOLD:-$("$_cfg" monitor.graphql_threshold 200)}"
# WEDGE-SAFETY for the `snapshot_github` GraphQL calls
# (your-org/nexus-code#367). Hard wall-clock ceiling on each of the
# three `gh api graphql` calls (issue-comments, pr-comments,
# new-issues) in `_github.sh`. `gh api graphql` honours neither curl
# knob above, so the calls are wrapped in `timeout` instead: a hung /
# black-holed GitHub request is killed within the budget and that
# snapshot fails gracefully (logged, retried next cycle) rather than
# freezing the scheduler indefinitely (heartbeat stall + task-fork
# pileup, twice-observed on a live operator). Default 30s — generous
# vs the few-second healthy latency of these search queries, but a
# hard ceiling far under the 600s `github_poll` interval (three calls
# => 90s worst case). `_KILL_AFTER` is the SIGKILL backstop if gh
# ignores the initial SIGTERM (default 5s).
GRAPHQL_TIMEOUT="${MONITOR_GRAPHQL_TIMEOUT:-$("$_cfg" monitor.graphql_timeout_seconds 30)}"
[[ "$GRAPHQL_TIMEOUT" =~ ^[0-9]+$ && "$GRAPHQL_TIMEOUT" -gt 0 ]] || GRAPHQL_TIMEOUT=30
GRAPHQL_TIMEOUT_KILL_AFTER="${MONITOR_GRAPHQL_TIMEOUT_KILL_AFTER:-$("$_cfg" monitor.graphql_timeout_kill_after_seconds 5)}"
[[ "$GRAPHQL_TIMEOUT_KILL_AFTER" =~ ^[0-9]+$ ]] || GRAPHQL_TIMEOUT_KILL_AFTER=5
# v2 scheduler knobs. `MONITOR_SCHEDULER_MAX_SLEEP` caps the
# scheduler's longest single sleep so SIGTERM is observed within
# that window; `MONITOR_SCHEDULER_LOG` is the per-fire JSONL
# telemetry sink. See docs/watcher-scheduling-refactor.md and
# `_scheduler.sh`.
MONITOR_SCHEDULER_MAX_SLEEP="${MONITOR_SCHEDULER_MAX_SLEEP:-$("$_cfg" monitor.scheduler.max_sleep_seconds 10)}"
# Async hang-watchdog floor (your-org/your-nexus#180 R4): an async
# task still in flight past max(4 × its interval, this floor) gets
# its child tree killed and re-arms on its next due tick. Closes the
# silent-permanent-task-death mode: a hung helper (e.g. a gh call on
# a black-holed connection) left TASK_BG_PID set forever and the
# in-flight guard then skipped every future fire of that task with
# no log line. 0 disables. See _scheduler.sh.
MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR="${MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR:-$("$_cfg" monitor.scheduler.async_timeout_floor_seconds 300)}"
