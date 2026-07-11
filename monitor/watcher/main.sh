#!/usr/bin/env bash
# Nexus monitor — continuous watcher.
#
# Long-running companion to the monitor agent:
#
#   - Polls local + github state on an interval.
#   - On every observed change, classifies the diff as signal vs.
#     noise via `_classify_diff` in `_lib.sh`. Signal cycles compose
#     a report, paste it into a target tmux window (the orchestrator,
#     by default `orchestrator`), and archive the same body under
#     `monitor/.state/diffs/` so nothing is lost if the paste step
#     fails. Pure-noise cycles (mid-dirty hash bumps, *-interim*
#     report churn) advance the baseline and log one line.
#   - Touches `monitor/.state/watcher-heartbeat` every cycle so agents
#     can detect a dead watcher.
#   - Prunes archived diffs older than DIFF_RETENTION_DAYS (default 7).
#
# The watcher itself runs inside a dedicated tmux window (spawned via
# `monitor/watcher/launcher.sh`). If the target window disappears or
# tmux isn't installed, the loop keeps running and keeps archiving;
# only the paste step is skipped.
#
# Env / config:
#   NEXUS_ROOT             -> nexus.root
#   MONITOR_INTERVAL       -> monitor.interval_seconds      (default 60)
#   MONITOR_REPO           -> github.repo
#   MONITOR_USER_LOGIN     -> github.user_login
#   MONITOR_TARGET         -> monitor.target_window         (default "orchestrator")
#   DIFF_RETENTION_DAYS    -> monitor.diff_retention_days   (default 7)
#   AGENT_DEAD_THRESHOLD   -> monitor.agent_dead_threshold  (default 3)
#                             slow-path knob, reserved for the future
#                             "window present, agent silent" detector.
#   AGENT_MISSING_RESPAWN_DELAY
#                          -> monitor.agent_missing_respawn_delay (default 3)
#                             extra confirming polls before fast-respawn
#                             on a missing target window. The target_window
#                             probe runs at 2 s cadence, so the default of
#                             3 means ~8 s of confirmed absence before a
#                             respawn fires. 0 = respawn on first
#                             detection (the pre-incident-2026-06-02
#                             behaviour: a single transient misread —
#                             tmux rename race, list-windows glitch —
#                             spawned a duplicate orchestrator).
#   MONITOR_AUTO_UNSTICK   -> monitor.watcher.auto_unstick  (default true)
#   MONITOR_WORKER_ASKUQ_GRACE_SECONDS
#                          -> monitor.watcher.worker_askuq_grace_seconds
#                             (default 300) — worker-blocked-question
#                             relay (Case W in _unstick.sh). A live
#                             AskUserQuestion overlay on a NON-target
#                             pane observed continuously past this
#                             grace gets relayed to the orchestrator
#                             as a pending-decision record (kind
#                             blocked_question). 0 disables the relay.
#   MONITOR_IDLE_THRESHOLD_SECONDS
#                          -> monitor.idle_threshold_seconds (default 60)
#                             "really idle" window age threshold
#                             consumed by _idle_probe.sh.
#   MONITOR_IDLE_CLOSE_HOURS
#                          -> monitor.idle_close_hours       (default 24)
#                             hard-close threshold; once a worker
#                             window has been "really idle" for ≥
#                             this many hours the watcher classifies
#                             it as `idle-too-long` regardless of
#                             wrap-up status (orchestrator's
#                             retention overrides still apply).
#   MONITOR_GRAPHQL_THRESHOLD -> monitor.graphql_threshold    (default 200)
#                             skip the `github_poll` task fire if
#                             gh api /rate_limit reports
#                             graphql.remaining below this value.
#                             Cadence comes from the task interval
#                             itself (default 600 s); the threshold
#                             is the reactive bucket-floor safety net.
#   MONITOR_GRAPHQL_TIMEOUT -> monitor.graphql_timeout_seconds (default 30)
#                             hard wall-clock ceiling on each
#                             `snapshot_github` `gh api graphql` call
#                             (issue #367): a hung GitHub request is
#                             killed within the budget so it fails
#                             that snapshot gracefully instead of
#                             freezing the watcher scheduler.
#   MONITOR_GRAPHQL_TIMEOUT_KILL_AFTER
#                          -> monitor.graphql_timeout_kill_after_seconds (default 5)
#                             SIGKILL backstop if gh ignores the
#                             SIGTERM at the timeout boundary.
#   MONITOR_RATELIMIT_PROBE -> monitor.watcher.ratelimit_probe (default false)
#   ANTHROPIC_API_KEY      -> environment-only (no config); enables the
#                             rate-limit reset probe when set
#   MONITOR_RATELIMIT_HEURISTIC_MIN
#                          -> monitor.watcher.ratelimit_heuristic_minutes (default 30)
#   MONITOR_RATELIMIT_ACK_TIMEOUT_S
#                          -> monitor.watcher.ratelimit_ack_timeout_s (default 60)
#   MONITOR_PROBE_MODEL    -> monitor.watcher.probe_model (default
#                             claude-haiku-4-5-20251001)
#   MONITOR_HEARTBEAT_STALENESS_SECONDS
#                          -> monitor.heartbeat_staleness_seconds  (default 30)
#   MONITOR_API_ERROR_BACKOFF_MIN
#                          -> monitor.watcher.api_error_backoff_minutes
#                             (default 30) — minutes a same-fingerprint
#                             case-C api-error wedge is allowed to recur
#                             before the watcher will Enter-nudge it
#                             again. Tunable so a chronically broken
#                             endpoint can be quieted without code change.
#   MONITOR_NOTIFICATIONS_LOG_MAX_BYTES
#                          -> monitor.notifications_log_max_bytes
#                             (default 10485760 = 10MiB)
#                             worker-notifications.jsonl is rotated to
#                             worker-notifications.jsonl.<epoch> by
#                             render_idle_prelude when its size crosses
#                             this threshold. Rotated archives are pruned
#                             on DIFF_RETENTION_DAYS. See issue #76.
#   MONITOR_SCHEDULER_LOG_MAX_BYTES
#                          -> monitor.scheduler.log_max_bytes
#                             (default 52428800 = 50MiB) — rotation cap
#                             for watcher-scheduler.jsonl, the per-fire
#                             telemetry sink (your-org/your-nexus#180
#                             R2; grew unbounded to 310 MB live before
#                             this). Rotated by prune_archive to
#                             <name>.<epoch>; archives pruned on
#                             DIFF_RETENTION_DAYS. 0 disables.
#   MONITOR_STATE_LOG_MAX_BYTES
#                          -> monitor.state_log_max_bytes
#                             (default 10485760 = 10MiB) — shared
#                             rotation cap for watcher.log
#                             (copytruncate — the launcher redirect
#                             holds its inode), functional-check.tsv,
#                             and action-log.jsonl. Same lifecycle as
#                             above. 0 disables.
#   MONITOR_OVER_LIMIT_WAKE_MARGIN_SECONDS
#                          -> monitor.over_limit.wake_margin_seconds
#                             (default 300) — safety margin added to a
#                             pane's `reset_at` before the first wake
#                             attempt. Issue #87 watcher-side scheduler.
#   MONITOR_OVER_LIMIT_INITIAL_BACKOFF_SECONDS
#                          -> monitor.over_limit.initial_backoff_seconds
#                             (default 60)
#   MONITOR_OVER_LIMIT_MAX_BACKOFF_SECONDS
#                          -> monitor.over_limit.max_backoff_seconds
#                             (default 300)
#   MONITOR_OVER_LIMIT_MAX_ATTEMPTS
#                          -> monitor.over_limit.max_attempts
#                             (default 10) — give up + drop the stamp
#                             after this many still-suspended retries.
#                             A drop without resumption is a load-bearing
#                             signal of an Anthropic-side stall; the
#                             operator should manually intervene.
#   MONITOR_ORCH_UNRESPONSIVE_THRESHOLD_S
#                          -> monitor.orchestrator_unresponsive_threshold_seconds
#                             DEPRECATED (#164). When set, seeds the
#                             new dead_threshold default so existing
#                             deployments don't see a behaviour change
#                             on upgrade. New name:
#                             MONITOR_ORCH_DEAD_THRESHOLD_S /
#                             monitor.watcher.orchestrator_dead_threshold_seconds
#                             (default 300; see below). Drop in a
#                             future release.
#   MONITOR_ORCH_PASTE_RESPONSE_GRACE_S
#                          -> monitor.watcher.paste_response_grace_seconds
#                             (default 120) — grace window after a
#                             paste before the orchestrator-liveness
#                             state machine deems the heartbeat
#                             stale-relative-to-paste. Inside this
#                             window the orch is assumed to be mid-
#                             turn; tool-call latency, paste-then-
#                             think gaps, etc. legitimately consume
#                             this time. Raised from 60 after the
#                             2026-05-29..31 incidents: healthy
#                             heavy turns ran ~90-180 s and entered
#                             the countdown they should never see.
#                             Doubles as the response window granted
#                             to the one-shot re-submit rescue.
#   MONITOR_ORCH_UNSTICK_WINDOW_S
#                          -> monitor.watcher.unstick_window_seconds
#                             (default 150) — budget for unstick
#                             cases A-D to recover a wedged
#                             orchestrator before the state machine
#                             escalates to the re-submit rescue.
#                             detect_and_unstick runs every cycle
#                             independently; this knob is the time
#                             window the state machine gives those
#                             probes to bump the heartbeat. Lowered
#                             from 180 alongside the grace raise so
#                             grace + unstick (270) stays below the
#                             dead threshold (300), preserving a
#                             re-submit verification window before
#                             the absolute deadline.
#   MONITOR_ORCH_DEAD_THRESHOLD_S
#                          -> monitor.watcher.orchestrator_dead_threshold_seconds
#                             (default 300) — hard floor on
#                             "no heartbeat at all post-paste,
#                             including through unstick attempts
#                             and the re-submit rescue."
#                             Must exceed paste_response_grace +
#                             unstick_window. With the Stop-hook
#                             heartbeat firing reliably, false-
#                             positive restarts drop to near-zero
#                             so this floor can be much higher than
#                             the legacy unresponsive-threshold
#                             (120 s).
#   MONITOR_ORCH_LIVENESS_LOG_THROTTLE_S
#                          -> monitor.watcher.liveness_log_throttle_seconds
#                             (default 30) — minimum spacing between
#                             `waiting` verdict log lines. State
#                             entries, transitions, and re-submit /
#                             respawn events always log regardless.
#   MONITOR_VERSION_RESTART_ENABLED
#                          -> monitor.version_restart.enabled (default true)
#                             master switch for the version-aware
#                             component auto-restart (issue 186):
#                             per-component source-set hashes are
#                             compared against the recorded running
#                             versions and a STABLE drift triggers the
#                             component's restart path (watcher
#                             self-replace / cockpit ask / service
#                             restart). See _version_restart.sh for
#                             the guard stack and _config.sh for the
#                             companion knobs (interval_seconds,
#                             settle_seconds, cooldown_seconds,
#                             self, services, self_loop_limit,
#                             self_loop_window_seconds,
#                             cockpit_window).
#   WATCHER_WINDOW         -> LEGACY: tmux window hosting this watcher.
#                             The launcher sets "headless" (the watcher
#                             is setsid-detached, windowless); the
#                             lockfile status field reads it, and any
#                             other value triggers the one-shot
#                             legacy-hosting migration notice in the
#                             startup sweep (_hosting_migration.sh,
#                             issue 182).
#
# Flags:
#   --target <name>       override MONITOR_TARGET / config
#   --once                run one poll cycle and exit (for debugging)

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_monitor_dir=$(cd "$_script_dir/.." && pwd)
_cfg="$_monitor_dir/../config/load.sh"

# shellcheck source=_lib.sh
source "$_script_dir/_lib.sh"

# Explicit log mode at creation (your-org/nexus-code#484/#509):
# `_ensure_service_log` keeps watcher.log / watcher-alerts.log and
# friends 0640, never group-writable. Sourced early so every log-append
# helper defined below can call it.
# shellcheck source=../_log-mode.sh
source "$_monitor_dir/_log-mode.sh"

# Read-only-filesystem guard (#473): the per-cycle fresh-open() probe, the
# fire-once escalation, and the degraded-mode state machine. Must follow
# _lib.sh — it calls that file's probe + escalation helpers at run time.
# shellcheck source=_fs_guard.sh
source "$_script_dir/_fs_guard.sh"

# Robust tmux window targeting (#323): resolve_window_id re-resolves a
# window NAME → its current @id, so paste_to_target's worker-wake leg
# (over-limit) targets a dotted worker name by @id instead of letting
# `-t name` dot-parse and silently drop the wake. Leaf module, no deps;
# tracked in the watcher source set via this `source` line.
# shellcheck source=../_tmux-window.sh
source "$_script_dir/../_tmux-window.sh"

# shellcheck source=_respawn.sh
source "$_script_dir/_respawn.sh"

# Recovery-prompt bodies for respawn_agent (issue 180 seam S4).
# Functions only; no side effects on source.
# shellcheck source=_respawn_prompts.sh
source "$_script_dir/_respawn_prompts.sh"

# Legacy-hosting detection + one-shot migration notice (issue 182).
# Functions only; no side effects on source.
# shellcheck source=_hosting_migration.sh
source "$_script_dir/_hosting_migration.sh"

NEXUS_ROOT="${NEXUS_ROOT:-$("$_cfg" nexus.root)}"

# Publish our PID as the FIRST thing after resolving NEXUS_ROOT —
# before the ~50 further `config/load.sh` lookups below
# (your-org/your-nexus#180 R5). Each lookup spawns a fresh
# `config/load.sh` (a YAML parse in a subprocess); on a loaded NFS
# root the whole block can take >15 s, and `launcher.sh`'s
# headless-spawn verify polls `watcher.pid` for only 15 s before
# declaring the spawn a failure (it tripped twice on post-merge
# bounces). Publishing here — needing nothing but NEXUS_ROOT — makes
# the "before any heavy setup" contract real: the pidfile appears in
# the time of one lookup, not fifty. The canonical WATCHER_PIDFILE /
# STATE_DIR assignments in the path-defs block below recompute the
# same values; this early write is the load-bearing one. Atomic
# tmp+mv so a half-written file can never confuse the launcher's
# reader; every step is best-effort (`|| true`) so a transient FS
# hiccup here never aborts startup before the real lock/heartbeat
# path runs.
_early_state_dir="${NEXUS_ROOT}/monitor/.state"
WATCHER_PIDFILE="${_early_state_dir}/watcher.pid"
mkdir -p "$_early_state_dir" 2>/dev/null || true
# Duplicate-watcher self-close (issue #203 follow-up, operator
# direction: "the watcher should not run twice and close instead").
# launcher.sh already refuses to SPAWN over a live watcher, but a
# direct `main.sh` run bypasses it — and the very next line would
# CLOBBER the live watcher's pidfile, orphaning it from launcher/svc
# liveness checks. Identity-verified (argv program slot, not bare
# kill -0) so a stale/recycled pid never blocks a legitimate start.
_peer_pid=$(cat "$WATCHER_PIDFILE" 2>/dev/null)
if [[ "$_peer_pid" =~ ^[0-9]+$ ]] && (( _peer_pid != $$ )) \
   && _watcher_pid_is_live_watcher "$_peer_pid"; then
    echo "main.sh: another live watcher is running (pid=$_peer_pid per $WATCHER_PIDFILE) — refusing to start a duplicate. Use 'monitor/watcher/launcher.sh --replace' (or 'monitor/svc.sh restart watcher') to replace it." >&2
    exit 1
fi
unset _peer_pid
# Publish an EARLY HEARTBEAT — for the SAME reason as the early pidfile
# (your-org/your-nexus watcher-supervision; skeptic #001), and STRICTLY
# BEFORE it. `_watcher_alive` keys ONLY on the heartbeat's `pid=` field,
# not on watcher.pid. The canonical first `bump_heartbeat` runs only
# after the >15 s config/source/setup block, so without this a freshly-
# (re)started watcher would read DOWN for that whole window — the
# heartbeat still names the OLD, now-dead pid (bucket 2) — making `svc.sh
# restart watcher`'s post-check a deterministic false-failure and risking
# a revive→kill→respawn crash-loop against a healthy-but-slow-starting
# watcher. ORDERING IS LOAD-BEARING: the heartbeat is written BEFORE the
# pidfile so the invariant "watcher.pid live ⇒ heartbeat names OUR live
# pid (fresh)" holds for every observer — the launcher's verify polls the
# pidfile, and `svc.sh restart watcher` / the supervise tick check
# `_watcher_alive` the instant the launcher returns; a heartbeat written
# AFTER the pidfile leaves a race window where they read the stale
# old-pid heartbeat. TARGET isn't parsed yet (resolved below); the field
# is cosmetic for `_watcher_alive`/`_watcher_reason` and self-heals at the
# first real bump_heartbeat. Atomic tmp+mv; best-effort.
{
    printf 'pid=%d\nts=%s\ntarget=%s\n' "$$" "$(date -Is 2>/dev/null || echo unknown)" "${TARGET:-}" \
        > "${_early_state_dir}/watcher-heartbeat.tmp" 2>/dev/null \
        && mv "${_early_state_dir}/watcher-heartbeat.tmp" "${_early_state_dir}/watcher-heartbeat" 2>/dev/null
} || true
printf '%d\n' "$$" > "${WATCHER_PIDFILE}.tmp" 2>/dev/null \
    && mv "${WATCHER_PIDFILE}.tmp" "${WATCHER_PIDFILE}" 2>/dev/null || true
# Config resolution (env -> config -> default for every watcher knob).
# Extracted to _config.sh (issue 180 seam S1). Sourcing RUNS the ~50
# `config/load.sh` lookups and sets the knob globals — it is NOT
# side-effect-free, and on a loaded NFS root it can take >15 s, which
# is exactly why the pidfile publish above must stay ahead of it
# (issue 180 R5 / PR #245).
# shellcheck source=_config.sh
source "$_script_dir/_config.sh"

# Config guard (your-org/your-nexus#236 B11; broadened per the #311
# operator ask). config/load.sh falls through to the repo-tracked
# nexus.example.yml template when no real config/nexus.yml is present (it
# is gitignored — a fresh clone or a worktree that never received it hits
# this). The placeholder values (github.repo=your-org/...,
# nexus.root=/path/to/nexus, github.bot_app_id=0000000, ...) are
# real-looking enough that the watcher would "start clean" yet post to a
# non-existent repo AND fail to mint a bot token (snapshot_github mints
# every cycle and silently skips on failure — eligible comments would
# never surface). Refuse loudly instead — the same fail-fast contract as
# the instance-lock / wrong-window / duplicate-watcher guards. `--validate`
# checks the full required set (identity + the bot credentials mint-token
# needs), a superset of B11's `--check-identity`. We do NOT override
# NEXUS_ROOT on this call: load.sh must resolve the example relative to
# its own (real) clone, not against a placeholder root we might have just
# read out of the example. Only a definitive placeholder verdict (exit 4)
# refuses; an inconclusive result (no config at all, python/pyyaml
# missing) is left to the existing per-key failure modes.
"$_cfg" --validate || _identity_rc=$?
if [[ "${_identity_rc:-0}" == 4 ]]; then
    echo "main.sh: REFUSING to start — nexus config is unconfigured (details above). Configure config/nexus.yml before launching the watcher." >&2
    exit 1
fi
unset _identity_rc

ONCE=0
while (( $# > 0 )); do
    case "$1" in
        --target) TARGET="${2:-}"; shift 2 ;;
        --once)   ONCE=1; shift ;;
        *)        echo "main.sh: unknown flag: $1" >&2; exit 1 ;;
    esac
done

# Wrong-window self-close (issue #203 follow-up, operator direction:
# "detect if it is launched wrong and close with an informative
# message"). A watcher RUNNING INSIDE the window named $TARGET hides
# the orchestrator's absence from its own name-based probe — recovery
# can never fire. Only trusted when the $TMUX_PANE pane actually HOSTS
# this process (_nexus_self_pane_window's ancestry check): the
# legitimate headless watcher inherits the spawning Bash tool's
# TMUX_PANE through env but is setsid-detached (pane_pid is not an
# ancestor), so it is never refused. Rename the window off the target
# name first (so the running peer/successor watcher sees the slot
# absent and respawns the real orchestrator) unless a live
# orchestrator shares the window.
if _self_pane_info=$(_nexus_self_pane_window); then
    _self_win_id="${_self_pane_info%%$'\t'*}"
    _self_win_name="${_self_pane_info#*$'\t'}"
    if [[ "$_self_win_name" == "$TARGET" ]]; then
        if ! _nexus_window_has_orchestrator "$_self_win_id"; then
            tmux rename-window -t "$_self_win_id" 'watcher-misplaced' 2>/dev/null || true
        fi
        echo "main.sh: REFUSING to run inside the '$TARGET' window — that window belongs to the orchestrator and a watcher squatting there masks the orchestrator's absence from its own probe. The window has been renamed off '$TARGET' (unless a live orchestrator shares it). Launch the watcher headless instead: monitor/watcher/launcher.sh" >&2
        exit 1
    fi
fi
unset _self_pane_info _self_win_id _self_win_name

STATE_DIR="${NEXUS_ROOT}/monitor/.state"
DIFF_DIR="${STATE_DIR}/diffs"
HEARTBEAT="${STATE_DIR}/watcher-heartbeat"
# Liveness/progress split (nexus-code#491) — see _lib.sh "Liveness vs.
# progress". PROGRESS is bumped by the main loop + stage boundaries;
# CYCLE at each complete compose cycle, carrying the measured period.
PROGRESS_FILE="${STATE_DIR}/watcher-progress"
CYCLE_FILE="${STATE_DIR}/watcher-cycle"
LOCKFILE="${STATE_DIR}/watcher.lock"
# State-dir-scoped singleton lock (issue: multi-instance-guard). Keyed
# on the inode under the SHARED monitor/.state/, held via an open fd for
# this watcher's whole lifetime. Unlike LOCKFILE/WATCHER_PIDFILE (which
# record a bare pid validated against /proc and so go blind across the
# agent-sandbox `bwrap --unshare-pid` boundary), an flock crosses the
# pid-namespace AND host boundaries — see _nexus_instance_lock_live in
# _lib.sh. This is what actually prevents two cockpits in separate
# sandboxes from both driving one state dir + double-posting to GitHub.
INSTANCE_LOCK="${STATE_DIR}/nexus-instance.lock"
INSTANCE_LOCK_FD=""
# Cross-host companion to the flock: a heartbeat beacon this watcher refreshes
# every loop iteration. flock over NFSv3 does not reliably arbitrate BETWEEN
# CLIENTS, so a cockpit on another host could see the flock as free; the
# beacon lets a cross-host starter (and this watcher's own acquire) refuse a
# live remote peer and take over only a stale one. Separate file from the
# flock target so refreshing it never renames the locked inode. See the
# instance-heartbeat helpers in _lib.sh.
INSTANCE_HEARTBEAT_FILE="$(_nexus_instance_heartbeat_path "${STATE_DIR}")"
# Per-instance identity, generated ONCE here and pinned for our lifetime. The
# beacon records it so the per-loop self-fence (see _nexus_instance_beacon_loop_step
# in the main loop) can tell "this beacon is mine" from "a different instance
# overwrote it" at finer grain than host — distinguishing even a same-host
# takeover. Exported so _nexus_instance_heartbeat_write stamps it into the beacon.
NEXUS_INSTANCE_NONCE="$(_nexus_instance_gen_nonce)"
export NEXUS_INSTANCE_NONCE
# Set to 1 by the per-loop self-fence when a newer instance has superseded us,
# so release_instance_lock stands down WITHOUT deleting the newer holder's beacon.
INSTANCE_SUPERSEDED=0
# Launcher-visible liveness signal (issue #96). The watcher writes its
# own PID here on startup; `launcher.sh` reads it and uses `kill -0`
# to decide whether to refuse spawning. Self-published PID > `pgrep
# -f` regex against the global process table — workers whose argv
# merely references this path can't false-positive.
WATCHER_PIDFILE="${STATE_DIR}/watcher.pid"
LAST_CHANGE="${STATE_DIR}/last-change.txt"
BASELINE="${STATE_DIR}/last-snapshot.txt"
TARGET_FILE="${STATE_DIR}/watcher-target"
LOGFILE="${STATE_DIR}/watcher.log"
UNSTICK_DIR="${STATE_DIR}/unstick"
UNSTICK_LOG="${STATE_DIR}/watcher-unstick.log"
ACTION_LOG="${STATE_DIR}/action-log.jsonl"
# Machine-input ledger (issue #201): watcher-side Enter-nudges into
# worker panes stamp here so the idle-probe's operator-attribution
# rule doesn't read them as operator input. Writers: _unstick.sh,
# monitor/paste-followup.sh. Reader: _idle_probe.sh.
MACHINE_INPUT_TSV="${STATE_DIR}/machine-input.tsv"
RESPAWN_HISTORY="${STATE_DIR}/respawn-history.txt"
RESPAWN_TRIPPED="${STATE_DIR}/respawn-guard-tripped"
# Slow-grind counter + tripped stamp (issue #77). Counter persists
# `count=N` + `last_failure_ts=epoch`. Tripped stamp's mtime gates
# the cooldown window — its existence means "guard fired, pause
# respawns"; its age vs RESPAWN_SLOW_GRIND_COOLDOWN decides when to
# re-arm.
RESPAWN_CONSEC_COUNTER="${STATE_DIR}/respawn-consecutive-failures.txt"
RESPAWN_SLOW_GRIND_TRIPPED="${STATE_DIR}/respawn-slow-grind-tripped"
# Stamp file for the periodic full-state emit (issue #72 D4). Holds
# the epoch of the most recent emit that included the workspace
# snapshot. Compared against `now` to decide whether the next emit
# qualifies for snapshot inclusion.
FULL_STATE_STAMP="${STATE_DIR}/last-full-state-emit.ts"
# Canonical form of the most recently EMITTED full-state snapshot
# (issue #104). Cycle-to-cycle identity check: if the candidate
# canonical equals this file's contents AND the file's mtime is
# within MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS, suppress the emit.
# The file's mtime tracks the last actual emit, not the last
# cadence-check — so a long run of identical canonicals still emits
# at the safety-floor cadence. Recoverable on watcher restart (first
# cadence-due cycle finds no cache file and emits normally).
FULL_STATE_CANONICAL_CACHE="${STATE_DIR}/last-full-state-canonical.txt"
# Idle-streak anchor for the adaptive full-state heartbeat backoff
# (emit/exemption fidelity). Holds the epoch at which the canonical
# full-state snapshot last CHANGED (a genuine transition). compose_emit
# resets it to `now` whenever the candidate canonical differs from the
# cached one, and reads it (now - anchor = how long the canonical has
# been continuously unchanged) to pick the effective safety floor via
# `_full_state_effective_floor`. Survives restarts (missing ⇒ treated as
# a fresh streak, so the heartbeat starts responsive after a cold start).
FULL_STATE_IDLE_ANCHOR="${STATE_DIR}/last-full-state-change.ts"
# Content-hash dedup state. EMIT_DEDUP_HASH_FILE holds the sha256 of
# the last successfully-emitted body's stable canonical form (see
# `_compose_emit_stable_hash`); EMIT_DEDUP_TS_FILE holds the epoch of
# that emit. Both written atomically (tmp + rename) by
# `_compose_emit_apply_dedup` on the emit path. Recoverable on
# watcher restart — a missing hash file simply means "first compose
# after startup, emit normally."
EMIT_DEDUP_HASH_FILE="${STATE_DIR}/last-emit-stable-hash"
EMIT_DEDUP_TS_FILE="${STATE_DIR}/last-emit-stable-ts"
# Recent-emit hash ring (emit-gate-recover): epoch<TAB>hash per line,
# newest last, depth MONITOR_EMIT_DEDUP_RING_SIZE. Lets the dedup
# gate collapse ALTERNATING body shapes (the 2026-07-06 resurface
# flood was a two-shape A/B flap that single-slot dedup can never
# suppress). The single-slot pair above is still written as the
# newest entry for post-mortem tooling + first-run-after-upgrade
# fallback.
EMIT_DEDUP_RING_FILE="${STATE_DIR}/last-emit-stable-hash.ring"
# Orchestrator-liveness fallback (PR #148). Pin file is written by
# the orchestrator's UserPromptSubmit hook (PR #147); its mtime is
# the watcher's heartbeat for "this orchestrator is responsive".
# Cooldown marker is stamped by spawn-fresh-orchestrator.sh; its
# mtime gates re-firing so a stuck workspace doesn't loop spawn.
ORCH_PIN_FILE="${STATE_DIR}/orchestrator-session-id"
ORCH_FRESH_SPAWN_COOLDOWN_FILE="${STATE_DIR}/orchestrator-fresh-spawn.last"
# Paste-driven liveness anchor (#157). main.sh stamps this with the
# wall-clock epoch every time `paste_to_target` lands a paste on the
# orchestrator window with verified delivery (paste_rc=0 incl. the
# sig-trailer grep). `_orchestrator_unresponsive` reads it to decide
# whether the orch has had time to react. Atomic write via tmp+rename;
# missing file ⇒ no signal (first-watcher-cycle grace).
ORCH_LAST_PASTE_FILE="${STATE_DIR}/orchestrator-last-paste.ts"
# ---- emit-delivery tracking (nexus-code#236, silent-watcher hardening) ----
# The HEARTBEAT itself is the proof-of-working-loop (bumped ONLY at the end of
# a correct compose cycle — see bump_heartbeat + the compose_emit cycle-end
# bumps), so liveness needs no separate emit-cycle file. These two track
# DELIVERY health (orthogonal to "the loop ran"): a paste can fail while the
# loop is perfectly healthy.
#   EMIT_LAST_DELIVERY_FILE epoch of the last SUCCESSFUL emit paste to the
#                          orchestrator. functional_check's watcher-fault guard
#                          reads it to tell watcher-fault (no delivery) from
#                          orchestrator-fault (delivery fine, no reaction).
#   EMIT_DELIVERY_FAIL_FILE consecutive emit-paste failures (rc 3/4); reset on
#                          any success. Crossing the limit ⇒ loud alert +
#                          cooldown-guarded self-heal restart.
EMIT_LAST_DELIVERY_FILE="${STATE_DIR}/watcher-last-emit-delivery.ts"
EMIT_DELIVERY_FAIL_FILE="${STATE_DIR}/watcher-emit-delivery-fail.count"
# snapshot_local change-detection format tag (first line of the snapshot).
# A change here means the snapshot SHAPE changed; compose_emit reseeds the
# baseline silently on a tag mismatch instead of pasting a spurious whole-
# snapshot reformat diff. Bump the version when the section set/shape changes.
SNAPSHOT_LOCAL_FORMAT_TAG='# snapshot-format=v2 tmux-first,reports-bounded-count,git-off'
# Hook-driven orchestrator heartbeat (#164). `Stop` hook in
# `monitor/orchestrator-settings.json` touches this file at every
# turn-end; the state machine in
# `monitor/watcher/_orchestrator_liveness.sh` compares its mtime
# against ORCH_LAST_PASTE_FILE to decide whether the orchestrator
# has reacted to a paste. Missing file (settings predate the hook,
# fresh state dir) is benign — the state machine falls back to
# the paste-received and jsonl-mtime signals.
ORCH_HEARTBEAT_FILE="${STATE_DIR}/orchestrator-heartbeat"
# Paste-receipt signal (#164 follow-up). `UserPromptSubmit` hook
# in `monitor/orchestrator-settings.json` touches this file the
# moment the orchestrator's input queue picks up a watcher paste.
# Strictly weaker than the heartbeat (paste-received fires before
# Stop) but fresher during a long tool turn — the orchestrator
# received the prompt and is processing, even though Stop hasn't
# fired yet. The state machine prefers this signal over the
# fragile jsonl-mtime fallback (which depends on Claude Code's
# log format and write cadence). Both touches run asynchronously
# via the detached-subshell pattern `(... &) >/dev/null 2>&1` so
# the hook returns instantly; a slow filesystem or contention
# can't stall the orchestrator's paste-receipt path.
ORCH_PASTE_RECEIVED_FILE="${STATE_DIR}/orchestrator-paste-received"
# Unresponsive-since marker (#164). Stamped when the state machine
# first observes "pasted but no response past the grace window";
# cleared on any healthy decision. Its mtime is the anchor for the
# unstick-window budget — orchestrator gets `unstick_window_seconds`
# from this stamp for `detect_and_unstick` to recover the wedge
# before the watcher escalates to respawn.
ORCH_UNRESPONSIVE_SINCE_FILE="${STATE_DIR}/orchestrator-unresponsive-since"
# Re-submit attempt marker (orchestrator-liveness resilience). Stamped
# by the liveness task when the one-shot re-paste rescue fires at the
# unstick-window-exhaustion boundary; its existence caps the rescue at
# exactly one attempt per wedge episode and its mtime anchors the
# post-resubmit response window (one paste-response grace). Cleared on
# any healthy decision (alongside unresponsive-since) and on respawn.
ORCH_RESUBMIT_MARKER_FILE="${STATE_DIR}/orchestrator-resubmit-attempted"
# Idle-pane override counter (2026-06-15 incident). Holds the count of
# CONSECUTIVE idle-pane suppressions of a respawn verdict. Incremented by
# the idle-pane guard each time it overrides; reset on any genuine healthy
# verdict, on a non-idle pane (real wedge/dead), and when the override
# budget (ORCH_IDLE_OVERRIDE_MAX) is exhausted and the respawn is honored.
# Bounds the false-negative: a hung-but-idle pane cannot suppress its own
# respawn indefinitely.
ORCH_IDLE_OVERRIDE_COUNT_FILE="${STATE_DIR}/orchestrator-idle-override-count"
# Functional-check audit trail (other-nexus-lessons L1). Append-only TSV
# row per check: ts<TAB>n_emits<TAB>n_processed<TAB>n_stale<TAB>decision.
# Useful for post-hoc "did the watcher think we were wedged at <ts>?".
FUNCTIONAL_CHECK_STATE_FILE="${STATE_DIR}/functional-check.tsv"
# Claude Code update-detection signal files (see _cc_update.sh). The
# detection task maintains the advisory signal; the emit surfaces it.
#   cc-update-available — present iff a newer cc release than the pin
#     exists. key=value body (candidate/installed/package/detected/skill).
#     `cat` it any time to see the pending candidate; self-healed away by
#     the detection task once the pin catches up.
#   cc-update-surfaced  — the candidate version last surfaced into an
#     emit; the re-nag guard compares against it.
CC_UPDATE_STATE_FILE="${STATE_DIR}/cc-update-available"
CC_UPDATE_SURFACED_FILE="${STATE_DIR}/cc-update-surfaced"
# Autonomous daily cc-update routine state (see _cc_auto_update.sh).
# Everything under cc-auto-update/ — last-fire-date (the once-per-day
# stamp), last-eval (awaiting-operator guard), decisions.tsv (append-
# only audit), eval-prompt-<date>.md, apply.log, gate-<ver>.log. On
# disk so the daily cadence survives watcher restarts and orchestrator
# respawns alike.
CC_AUTO_UPDATE_STATE_DIR="${STATE_DIR}/cc-auto-update"
# Version-aware component-restart state (your-org/your-nexus#186; see
# _version_restart.sh for the file vocabulary). Holds per-component
# running-version records, drift pending/cooldown state, the watcher
# self-restart loop guard, and the drift-<comp> ask records the emit
# surfaces.
VERSION_STATE_DIR="${STATE_DIR}/version"
# Continuous service-health watch (service-health-watch). Per-service
# incident state — current-incident records, the append-only event
# history the `ng service-incident` generator reads, and the emit re-nag
# guards. See monitor/watcher/_service_health.sh.
SERVICE_HEALTH_STATE_DIR="${STATE_DIR}/service-health"
# Automatic reports-archive roll (your-org/nexus-code#447; roller is
# monitor/reports-roll.sh, #444/#446). The watcher runs the idempotent,
# ≥1-month-buffered roller on startup + once per day-boundary.
#   reports-roll-last-day — the YYYY-MM-DD stamp of the last run; a tick
#     whose date matches is a cheap no-op (date compare, no scan), so the
#     roll runs at most once per calendar day (plus the startup fire).
#   reports-roll-notice — one-shot audit breadcrumb written ONLY when a run
#     actually moves ≥1 file; surfaced once by compose_emit's
#     `--- reports archived ---` section (consumed on read, self-clearing),
#     so a quiet run stays silent. REPORTS_ROLL_MIN_AGE_SECONDS arms the
#     roller's opt-in mid-write guard on this automated path.
REPORTS_ROLL_LAST_DAY_FILE="${STATE_DIR}/reports-roll-last-day"
REPORTS_ROLL_NOTICE_FILE="${STATE_DIR}/reports-roll-notice"
# MONITOR_REPORTS_ROLL_{ENABLED,INTERVAL_SECONDS,MIN_AGE_SECONDS} are derived
# from config in _config.sh; belt-and-suspenders defaults so a stripped-down
# invocation (e.g. a unit test sourcing main.sh without _config) still works.
: "${MONITOR_REPORTS_ROLL_ENABLED:=true}"
: "${MONITOR_REPORTS_ROLL_INTERVAL_SECONDS:=3600}"
: "${MONITOR_REPORTS_ROLL_MIN_AGE_SECONDS:=300}"
# Watcher-supervision (your-org/your-nexus, mutual-liveness design).
# The ORCHESTRATOR arms a persistent Monitor (watcher-supervise-tick.sh)
# that revives a crashed watcher; that Monitor TOUCHES this heartbeat each
# tick. The watcher STATS it: if it is stale/absent the supervisor is not
# armed, and the watcher emits an `--- arm watcher supervisor ---`
# reminder nudging the (possibly freshly-restarted) orchestrator to
# (re)arm the Monitor. This is the mutual-liveness contract: watcher
# revives orchestrator (orchestrator-liveness) + reminds it to arm the
# supervisor; orchestrator-Monitor revives watcher.
WATCHER_SUPERVISOR_HEARTBEAT="${STATE_DIR}/watcher-supervisor-heartbeat"
# Self-failure report marker: revive-watcher.sh writes this when the
# orchestrator-Monitor revives a CRASHED watcher; the revived watcher's
# first emit surfaces + clears it (a dead watcher can't report its own
# death — the successor does).
WATCHER_REVIVED_MARKER="${STATE_DIR}/watcher-revived"
export ACTION_LOG TARGET RATELIMIT_PROBE RATELIMIT_HEURISTIC_MIN \
       RATELIMIT_ACK_TIMEOUT_S PROBE_MODEL ANTHROPIC_API_KEY \
       GRAPHQL_THRESHOLD GRAPHQL_TIMEOUT GRAPHQL_TIMEOUT_KILL_AFTER \
       API_ERROR_BACKOFF_MIN \
       ON_DIALOG MONITOR_WORKER_ASKUQ_GRACE_SECONDS

mkdir -p "${STATE_DIR}" "${DIFF_DIR}" "${UNSTICK_DIR}"

# The PID was already published immediately after NEXUS_ROOT resolved,
# before the heavy config block (issue 180 R5 — see the early-publish
# note near the top). The `mkdir` above is idempotent with the early
# one, so nothing here needs to re-write the pidfile.

# stderr only. Headless, the launcher appends the watcher's stderr to
# $LOGFILE (monitor/watcher/launcher.sh) — that redirect is the single
# writer, and it also captures non-log() output (bash errors, crash
# traces). A second append here would double every line in the file
# (the windowed era needed it because stderr went to an ephemeral
# pane; the pane is gone).
log() {
    printf '[%s] %s\n' "$(date -Is)" "$*" >&2
}

# ---- lock / heartbeat ----------------------------------------------------

# Acquire a PID-based lock. If an existing lock's PID is alive, refuse
# to start (prevents two watchers racing on the same state dir).
acquire_lock() {
    if [[ -f "$LOCKFILE" ]]; then
        local existing_pid
        existing_pid=$(_watcher_lock_field "$LOCKFILE" pid)
        # `_watcher_pid_is_live_watcher`, not a bare `kill -0`: after a
        # machine/container restart the PID namespace resets and the
        # lock's recorded pid (the recurring `pid=13`) gets recycled to
        # an unrelated process. A bare `kill -0` then succeeds and the
        # watcher refuses to start, deadlocking recovery (incident
        # 2026-06-07). Validating that the pid is actually a watcher
        # lets a recycled-pid stale lock be overwritten so recovery
        # proceeds.
        if [[ -n "$existing_pid" ]] && _watcher_pid_is_live_watcher "$existing_pid"; then
            log "another watcher already running (pid=$existing_pid); refusing to start"
            exit 3
        fi
        log "stale lock (pid=${existing_pid:-?}); overwriting"
    fi
    cat > "$LOCKFILE" <<EOF
pid: $$
started_at: $(date -Is)
target_window: ${TARGET}
tmux_window: ${WATCHER_WINDOW:-unknown}
interval_seconds: ${INTERVAL}
EOF
}

release_lock() {
    [[ -f "$LOCKFILE" ]] || return 0
    local owner_pid
    owner_pid=$(_watcher_lock_field "$LOCKFILE" pid)
    [[ "$owner_pid" == "$$" ]] && rm -f "$LOCKFILE"
}

# Acquire the state-dir-scoped singleton lock and HOLD it (open fd kept
# for our lifetime). A live holder — on this host or, via the NFS lock
# manager, any other host sharing this state dir, in ANY pid namespace —
# makes us refuse loudly and exit non-zero rather than coexist. This is
# the guard the pid-based checks cannot provide across `bwrap
# --unshare-pid` sandboxes. The blessed succession paths (launcher.sh
# --replace, _version_restart_self, bootstrap-recover) all SIGTERM/KILL
# the prior watcher BEFORE this runs, so its flock is already released
# and the successor acquires cleanly — the guard blocks coexistence,
# never succession.
acquire_instance_lock() {
    # mkdir already done for STATE_DIR upstream; open O_RDWR|O_CREAT,
    # NO truncate, so a refused start preserves the holder's metadata.
    if ! exec {INSTANCE_LOCK_FD}<>"$INSTANCE_LOCK"; then
        log "WARN: cannot open instance lock $INSTANCE_LOCK; starting WITHOUT the state-dir singleton guard"
        INSTANCE_LOCK_FD=""
        return 0
    fi
    if ! flock -n "$INSTANCE_LOCK_FD"; then
        local holder _l
        holder=$(cat "$INSTANCE_LOCK" 2>/dev/null)
        log "REFUSING to start: another nexus cockpit holds the instance lock for this NEXUS_ROOT."
        # Situation-aware, actionable block (normal vs false-positive
        # resolution, stale-lock assessment) — shared with the launcher
        # fast-fail so both gates emit identical guidance. See
        # _nexus_instance_lock_refusal in _lib.sh.
        while IFS= read -r _l; do
            log "$_l"
        done < <(_nexus_instance_lock_refusal "$holder" "$INSTANCE_LOCK" "$NEXUS_ROOT")
        exec {INSTANCE_LOCK_FD}>&- 2>/dev/null || true
        INSTANCE_LOCK_FD=""
        exit 4
    fi
    # flock acquired ⇒ no same-host / NLM-visible peer. But flock over NFSv3
    # may NOT see a peer on ANOTHER host (unreliable cross-client NLM), so
    # consult the cross-host heartbeat before committing: a FRESH beacon from
    # a different host means a live remote instance we must not coexist with.
    # Only live-remote refuses here — a corrupt/stale/same-host beacon is our
    # own leftover (the flock is the authoritative same-host gate and it just
    # said free), so we proceed and overwrite it. This is the deliberate
    # asymmetry with the starter preflight, which fails closed on corrupt:
    # the watcher restart path must NEVER self-block, and the flock is its
    # backstop.
    local _hb_verdict
    _hb_verdict=$(_nexus_instance_remote_verdict \
        "$(cat "$INSTANCE_HEARTBEAT_FILE" 2>/dev/null || true)" \
        "$(hostname 2>/dev/null || echo unknown)" \
        "$(date +%s 2>/dev/null || echo 0)" \
        "$(_nexus_instance_staleness_window)")
    if [[ "$_hb_verdict" == "live-remote" ]]; then
        local _rh _rts
        _rh=$(_nexus_instance_lock_field "$(cat "$INSTANCE_HEARTBEAT_FILE" 2>/dev/null)" host) || _rh="?"
        _rts=$(_nexus_instance_lock_field "$(cat "$INSTANCE_HEARTBEAT_FILE" 2>/dev/null)" ts) || _rts="?"
        log "REFUSING to start: a live nexus instance on host ${_rh} holds the cross-host heartbeat (as of ${_rts})."
        log "  monitor/.state is shared over NFS — two cockpits would race it. Use / stop the instance on ${_rh}."
        log "  If ${_rh} is down, the beacon ages out and this host takes over automatically: $INSTANCE_HEARTBEAT_FILE"
        flock -u "$INSTANCE_LOCK_FD" 2>/dev/null || true
        exec {INSTANCE_LOCK_FD}>&- 2>/dev/null || true
        INSTANCE_LOCK_FD=""
        exit 4
    fi
    # Held. Refresh the advisory metadata block (liveness is the flock
    # itself, never this text). truncate first so a shorter record never
    # leaves a prior holder's trailing bytes. The field set lives in
    # _nexus_instance_lock_metadata (_lib.sh) so launcher/main/status
    # and the refusal/inspect surfaces read one schema.
    truncate -s 0 "$INSTANCE_LOCK" 2>/dev/null || true
    _nexus_instance_lock_metadata >&"$INSTANCE_LOCK_FD"
    # Deliberately leave INSTANCE_LOCK_FD OPEN — the held fd IS the lock.
    # Publish the initial cross-host beacon immediately (before the first
    # loop) so a peer racing our startup sees us. Refreshed every loop
    # iteration thereafter; removed by release_instance_lock on clean exit.
    _nexus_instance_heartbeat_write "$INSTANCE_HEARTBEAT_FILE" || \
        log "WARN: could not write instance heartbeat $INSTANCE_HEARTBEAT_FILE (cross-host guard degraded; flock still guards same-host)"
}

release_instance_lock() {
    [[ -n "${INSTANCE_LOCK_FD:-}" ]] || return 0
    flock -u "$INSTANCE_LOCK_FD" 2>/dev/null || true
    exec {INSTANCE_LOCK_FD}>&- 2>/dev/null || true
    INSTANCE_LOCK_FD=""
    # Remove the cross-host beacon on clean shutdown so a legitimate
    # successor (incl. --replace succession) reclaims immediately instead of
    # waiting out the staleness window. On an unclean death (SIGKILL, crash)
    # the trap may not run and the beacon is left behind — that is fine, its
    # epoch ages past the window and a starter then treats it as stale.
    #
    # EXCEPTION: when we are standing down because a NEWER instance superseded
    # us (self-fence), the beacon on disk is the SUCCESSOR's, not ours —
    # deleting it would strand the live winner without a beacon and reopen the
    # very cross-host race the fence just resolved. Leave it untouched.
    if [[ "${INSTANCE_SUPERSEDED:-0}" == "1" ]]; then
        return 0
    fi
    [[ -n "${INSTANCE_HEARTBEAT_FILE:-}" ]] && rm -f "$INSTANCE_HEARTBEAT_FILE" 2>/dev/null || true
}

# Only remove the PID file if it still holds OUR pid — guards against
# a launcher that started a successor watcher (after detecting us as
# stale) and overwrote the file during our shutdown.
release_pidfile() {
    [[ -f "$WATCHER_PIDFILE" ]] || return 0
    local owner_pid
    owner_pid=$(cat "$WATCHER_PIDFILE" 2>/dev/null)
    [[ "$owner_pid" == "$$" ]] && rm -f "$WATCHER_PIDFILE"
}

# The heartbeat is the watcher's PROOF-OF-WORKING-LOOP (nexus-code#236,
# operator refinement on #317). It is bumped ONLY at the end of a correct
# compose cycle — the point where "an emit could have been made" (snapshot
# built without error, change-detection / emit-decision reached) — NOT by any
# separate always-ticks task. So:
#   - fresh heartbeat  ⇒ the loop ran a full cycle correctly (whether or not
#                        it actually emitted — a quiet workspace is SUPPOSED
#                        to stay silent for long stretches to save tokens;
#                        that silence is healthy and the heartbeat proves it);
#   - stale heartbeat  ⇒ the loop is WEDGED mid-cycle (the silent stall we
#                        hit on 2026-06-18) → the supervisor restarts it,
#                        independent of whether an emit was due.
# A dead PROCESS is caught separately+instantly by _watcher_alive's pid check;
# the heartbeat AGE specifically catches "process alive but loop wedged".
# Bumped from the compose_emit async subshell too — `$$` stays the main
# watcher pid in a `( )` subshell, so the pid field is correct.
bump_heartbeat() {
    printf 'pid=%d\nts=%s\ntarget=%s\n' "$$" "$(date -Is)" "$TARGET" > "$HEARTBEAT"
}

# ---- liveness ticker + progress/cycle signals (nexus-code#491) -------------
# The heartbeat above is now a PURE liveness signal: a background ticker
# beats it at a fixed cadence so no amount of loop workload can starve
# it (at >=12 workers the compose cycle exceeded every constant
# threshold and a healthy watcher was GUARANTEED to be reported DOWN;
# the compose watchdog even killed the only task that bumped it, so
# under load the heartbeat could never beat again). Forward progress
# and functional proof live in their own files — see _lib.sh.

# Cadence of the liveness ticker. Deliberately far below the fresh
# cutoff (2*interval+15) so a single missed beat never flips a verdict.
HEARTBEAT_TICK_SECONDS="${MONITOR_HEARTBEAT_TICK_SECONDS:-$("$_cfg" monitor.watcher.heartbeat_tick_seconds 20)}"
[[ "$HEARTBEAT_TICK_SECONDS" =~ ^[0-9]+$ ]] && (( HEARTBEAT_TICK_SECONDS >= 1 )) || HEARTBEAT_TICK_SECONDS=20

_HEARTBEAT_TICKER_PID=0
# Start (or restart, if the child died) the liveness ticker. Called
# once after the instance lock is held — a doomed second watcher must
# never beat the real one's heartbeat — and re-checked every loop
# iteration so a crashed ticker self-heals within one tick.
#
# The ticker runs OUTSIDE our process group/session (setsid re-exec),
# for two reasons (nexus-code#491):
#   - its own periodic sleep/date forks must never pollute the
#     "youngest group member" fork-freshness signal that separates a
#     BUSY watcher from a WEDGED one;
#   - it holds NO inherited lock fds (closed on the spawn line), so it
#     can never pin the instance flock past our death (the #451/#468/
#     #471 fd-leak class).
# Group kills therefore do not reap it — its `kill -0 <our pid>` watch
# exits it within one tick of our death instead, and the heartbeat's
# pid field (us, dead by then) makes any final beat inert.
_start_heartbeat_ticker() {
    if (( _HEARTBEAT_TICKER_PID > 0 )) && kill -0 "$_HEARTBEAT_TICKER_PID" 2>/dev/null; then
        return 0
    fi
    if [[ -n "${INSTANCE_LOCK_FD:-}" ]]; then
        setsid bash -c 'source "$1" && _watcher_heartbeat_ticker_loop "$2" "$3" "$4" "$5"' \
            _ "$_script_dir/_lib.sh" "$HEARTBEAT" "$$" "$HEARTBEAT_TICK_SECONDS" "$TARGET" \
            </dev/null {INSTANCE_LOCK_FD}>&- &
    else
        setsid bash -c 'source "$1" && _watcher_heartbeat_ticker_loop "$2" "$3" "$4" "$5"' \
            _ "$_script_dir/_lib.sh" "$HEARTBEAT" "$$" "$HEARTBEAT_TICK_SECONDS" "$TARGET" \
            </dev/null &
    fi
    _HEARTBEAT_TICKER_PID=$!
}

# _close_inherited_locks lives in _lib.sh (nexus-code#491): production
# text, single definition, exercised directly by the tests instead of
# a fixture re-definition (skeptic M4 on PR#503).
#
# Hook consulted by _scheduler_fire_async at the top of every async
# task subshell (declared-if-present contract; unit tests that source
# the scheduler standalone simply have no hook).
_scheduler_subshell_init() { _close_inherited_locks; }

_stop_heartbeat_ticker() {
    (( _HEARTBEAT_TICKER_PID > 0 )) && kill "$_HEARTBEAT_TICKER_PID" 2>/dev/null || true
    _HEARTBEAT_TICKER_PID=0
}

# Forward-progress stamp. Cheap (one tiny atomic write); called from
# the parent loop every iteration and at stage boundaries inside the
# startup sweep and compose_emit ($BASHPID keeps subshell tmp names
# unique; $$ stays the main watcher pid in subshells, which is what
# the probes validate). Best-effort — progress accounting must never
# break the loop it measures.
_progress_bump() {
    local stage="${1:-}"
    printf 'pid=%d\nepoch=%s\nts=%s\nstage=%s\n' \
        "$$" "$(date +%s)" "$(date -Is)" "$stage" \
        > "$PROGRESS_FILE.tmp.$BASHPID" 2>/dev/null \
        && mv -f "$PROGRESS_FILE.tmp.$BASHPID" "$PROGRESS_FILE" 2>/dev/null || true
}

# Threshold (x INTERVAL) past which a measured cycle period is warned
# about — the loop period may exceed the OLD liveness thresholds now
# without consequence, but it must never do so SILENTLY.
MONITOR_LOOP_PERIOD_WARN_MULT="${MONITOR_LOOP_PERIOD_WARN_MULT:-3}"
[[ "$MONITOR_LOOP_PERIOD_WARN_MULT" =~ ^[0-9]+$ ]] || MONITOR_LOOP_PERIOD_WARN_MULT=3

# Completed-cycle stamp + measured loop period. Single-writer (the
# scheduler's in-flight guard serializes compose fires; startup calls
# it once before the scheduler starts). period_s = gap since the
# previous stamp; ema_s = 4-sample smoothing that survives restarts
# (the file persists in the state dir, so the wedge/cycle cutoffs stay
# load-calibrated across a respawn).
_cycle_bump() {
    local now prev ema period
    now=$(date +%s)
    prev=$(_watcher_heartbeat_field "$CYCLE_FILE" epoch); [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
    ema=$(_watcher_heartbeat_field "$CYCLE_FILE" ema_s);  [[ "$ema" =~ ^[0-9]+$ ]] || ema=0
    period=0
    (( prev > 0 && now > prev )) && period=$(( now - prev ))
    if (( period > 0 )); then
        if (( ema == 0 )); then ema=$period; else ema=$(( (ema * 3 + period) / 4 )); fi
    fi
    printf 'pid=%d\nepoch=%d\nts=%s\nperiod_s=%d\nema_s=%d\n' \
        "$$" "$now" "$(date -Is)" "$period" "$ema" \
        > "$CYCLE_FILE.tmp.$BASHPID" 2>/dev/null \
        && mv -f "$CYCLE_FILE.tmp.$BASHPID" "$CYCLE_FILE" 2>/dev/null || true
    if (( period > INTERVAL * MONITOR_LOOP_PERIOD_WARN_MULT )); then
        log "WARN loop period ${period}s exceeds ${MONITOR_LOOP_PERIOD_WARN_MULT}x interval (${INTERVAL}s) — the sweep is overloaded (workers scale per-cycle cost). Liveness is unaffected (ticker); the wedge cutoff auto-scales to $(_watcher_wedge_cutoff "$INTERVAL" "$ema")s. Sections already degrade via budgets; consider raising monitor.interval_seconds or reducing worker count if this persists."
    fi
}

# Startup re-anchor: reset the cycle clock to NOW (so a successor is
# never judged by its predecessor's last cycle age) while PRESERVING
# the learned ema (so the cutoffs stay calibrated to the observed
# load through a restart).
_cycle_reset() {
    local ema
    ema=$(_watcher_heartbeat_field "$CYCLE_FILE" ema_s); [[ "$ema" =~ ^[0-9]+$ ]] || ema=0
    printf 'pid=%d\nepoch=%d\nts=%s\nperiod_s=%d\nema_s=%d\n' \
        "$$" "$(date +%s)" "$(date -Is)" 0 "$ema" \
        > "$CYCLE_FILE.tmp.$BASHPID" 2>/dev/null \
        && mv -f "$CYCLE_FILE.tmp.$BASHPID" "$CYCLE_FILE" 2>/dev/null || true
}

# ---- self-heal (nexus-code#236) -------------------------------------------
# Stability-first: the watcher should not stall in the first place; if
# delivery genuinely breaks, fail LOUD; restart only as the cooldown-guarded
# last resort.

# Loud, channel-independent diagnostic. The orchestrator-paste channel may
# itself be the thing that's broken, so "loud" means the out-of-band
# surfaces: the alerts log (#314's watcher-alerts.log), the watcher log, and
# a sandbox-notify. Never silent.
_watcher_alert() {
    local msg="$1"
    local iso; iso=$(date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    _ensure_service_log "${STATE_DIR}/watcher-alerts.log"
    printf '[%s] ALERT %s\n' "$iso" "$msg" >> "${STATE_DIR}/watcher-alerts.log" 2>/dev/null || true
    log "ALERT $msg"
    if command -v sandbox-notify >/dev/null 2>&1; then
        sandbox-notify "watcher ALERT: $msg" >/dev/null 2>&1 || true
    fi
}

# Record a SUCCESSFUL emit delivery: stamp the delivery clock, clear the
# consecutive-failure counter.
_emit_delivery_ok() {
    date +%s > "$EMIT_LAST_DELIVERY_FILE" 2>/dev/null || true
    rm -f "$EMIT_DELIVERY_FAIL_FILE" 2>/dev/null || true
}

# Record a FAILED emit delivery. rc=2 (target window missing) is the
# ORCHESTRATOR-respawn path, NOT a watcher delivery fault — it never counts
# toward self-heal (restarting the watcher would not bring the window back,
# and double-driving the orchestrator respawn risks a storm). For genuine
# watcher-side paste faults (rc 3/4, rc 1) we increment, alert LOUDLY, and —
# past the limit — self-heal restart through the cooldown-guarded chokepoint.
_emit_delivery_fail() {
    local rc="${1:-0}"
    [[ "$rc" == 2 ]] && return 0
    local n=0
    [[ -f "$EMIT_DELIVERY_FAIL_FILE" ]] && n=$(cat "$EMIT_DELIVERY_FAIL_FILE" 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    n=$(( n + 1 ))
    printf '%s\n' "$n" > "$EMIT_DELIVERY_FAIL_FILE" 2>/dev/null || true
    local limit="${MONITOR_EMIT_DELIVERY_FAIL_LIMIT:-3}"
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=3
    _watcher_alert "emit delivery to '${TARGET}' FAILED rc=$rc (${n} consecutive, limit ${limit}); emit ARCHIVED but UNDELIVERED — the watcher's own paste path is degraded."
    if (( n >= limit )); then
        _watcher_self_heal_restart "emit-delivery-failed rc=$rc consecutive=$n"
    fi
}

# The single storm-proof recovery chokepoint. EVERY watcher self-restart
# (delivery-failure path, functional_check backstop) funnels through here so
# they share ONE cooldown stamp + ONE loop-guard history with the version
# self-restart — making a respawn storm structurally impossible. Reuses the
# battle-tested version-restart primitives.
_watcher_self_heal_restart() {
    local reason="$1"
    if [[ "${MONITOR_WATCHER_SELF_HEAL_ENABLED:-true}" != "true" ]]; then
        log "self-heal requested ($reason) but MONITOR_WATCHER_SELF_HEAL_ENABLED=false; loud alert only, no restart"
        return 0
    fi
    if [[ "${MONITOR_VERSION_SELF_RESTART:-true}" != "true" ]]; then
        log "self-heal requested ($reason) but self-restart disabled (monitor.version_restart.self=false); loud alert only"
        return 0
    fi
    local now cooldown
    now=$(date +%s)
    cooldown="${MONITOR_VERSION_RESTART_COOLDOWN_SECONDS:-600}"
    if ! _version_cooldown_ok "$VERSION_STATE_DIR" watcher "$cooldown" "$now"; then
        log "self-heal suppressed ($reason): inside ${cooldown}s restart cooldown (no storm)"
        return 0
    fi
    if ! _version_self_guard_ok "$VERSION_STATE_DIR" \
            "${MONITOR_VERSION_SELF_LOOP_LIMIT:-3}" \
            "${MONITOR_VERSION_SELF_LOOP_WINDOW_SECONDS:-3600}" "$now"; then
        log "self-heal suppressed ($reason): self-restart loop guard TRIPPED — manual restart required (no storm)"
        return 0
    fi
    # Leave a revived-marker so the SUCCESSOR's startup sweep surfaces the
    # self-heal to the orchestrator — THIS process can't paste (its delivery
    # is what's broken), so the successor reports for it.
    {
        printf 'reason=%s\n' "watcher self-heal: $reason"
        printf 'downtime_estimate_s=%s\n' "0"
        printf 'detected_at=%s\n' "$(date -Is 2>/dev/null || echo '?')"
        printf 'restarted_by=%s\n' "watcher-self-heal"
    } > "$WATCHER_REVIVED_MARKER" 2>/dev/null || true
    _watcher_alert "SELF-HEAL RESTART ($reason) — relaunching via launcher --replace to restore emit delivery."
    # The remedy must not destroy its own evidence (skeptic finding 2b
    # on PR#503): this function usually runs inside an ASYNC scheduler
    # task whose stdout is flushed to watcher.log only on completion —
    # and the restart below kills the host before that flush, so the
    # `log` line above dies with it (the 17:39:35 restart looked
    # unattributed for twenty minutes; only watcher-alerts.log kept
    # it). Append the trigger DIRECTLY to the logfile, an independent
    # unbuffered sink, BEFORE signalling anything.
    if [[ -n "${LOGFILE:-}" && "${LOGFILE}" != /dev/null ]]; then
        printf '[%s] ALERT SELF-HEAL RESTART (%s) — recorded pre-signal (async stdout dies with the host)\n' \
            "$(date -Is 2>/dev/null || echo '?')" "$reason" >> "$LOGFILE" 2>/dev/null || true
    fi
    WATCHER_LAUNCH_CALLER="watcher-self-heal: $reason" \
    _version_restart_self "$VERSION_STATE_DIR" "$_script_dir/launcher.sh" "${TARGET:-orchestrator}" \
        "${LOGFILE:-/dev/null}" \
        || log "self-heal restart launch FAILED ($reason); cooldown stamped, slow retry after cooldown"
    return 0
}

# _run_bounded <budget_s> <outfile> <fn> [args...]
#
# Run a shell FUNCTION (render_idle_section, render_full_state_snapshot, …)
# under a hard wall-clock bound — `timeout(1)` can't wrap a shell function,
# so we background it and reap with a poll. stdout → <outfile> (partial
# output is preserved on timeout). rc = the function's rc on completion, or
# 124 if the budget was exceeded (the function's process tree — including any
# pane-state.sh grandchildren — is killed). Lets the SYNCHRONOUS startup
# sweep degrade to a partial render + a loud WARN instead of blocking loop
# entry unboundedly (the ~66 s startup stall on 2026-06-18).
_run_bounded() {
    local budget="$1" outfile="$2"; shift 2
    [[ "$budget" =~ ^[0-9]+$ ]] || budget=20
    : > "$outfile" 2>/dev/null || true
    ( _close_inherited_locks; "$@" > "$outfile" 2>/dev/null ) &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null && (( waited < budget )); do
        sleep 1
        waited=$(( waited + 1 ))
    done
    if kill -0 "$pid" 2>/dev/null; then
        pkill -P "$pid" 2>/dev/null || true
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        return 124
    fi
    wait "$pid" 2>/dev/null
    return $?
}

# ---- snapshot helpers ----------------------------------------------------

# Local state: reports filenames+mtimes, tmux windows+bell, work/* git HEAD + clean/dirty.
# This exact shape is what `_classify_diff` expects — section markers
# `--- reports ---`, `--- tmux ---`, `--- git ---`, lines sorted within
# each section.
snapshot_local() {
    # CHANGE-DETECTION payload — diffed against BASELINE every compose_emit
    # to decide whether to emit. Deliberately distinct from the full-state
    # DISPLAY snapshot (render_full_state_snapshot): this one must stay
    # O(1)-ish and NOISE-FREE so report/worktree churn neither DRIVES nor
    # MASKS an emit (nexus-code#236, silent-watcher hardening). The poll
    # should fire on real local state transitions (windows), not on a
    # report file being rewritten or a worktree going dirty.
    #
    # Format-tagged (first line): a SHAPE change reseeds the baseline
    # silently in compose_emit instead of pasting a spurious reformat diff.
    printf '%s\n' "${SNAPSHOT_LOCAL_FORMAT_TAG:-# snapshot-format=v2}"

    # tmux FIRST — the highest-signal section (window add/remove, bell-flag
    # flips ARE the real local state transitions). Placed ahead of reports
    # so the `diff -u | head -N` cap can never truncate a window transition
    # behind report-listing churn (the masking half of the confounder).
    echo '--- tmux ---'
    # Defense-in-depth filter against phantom dead-pane window names.
    # The load-bearing fix is in spawn-worker.sh (it disables
    # automatic-rename + allow-rename on every spawned window), but
    # we still drop any row whose window name starts with `•` here
    # so a stray transient — pre-fix worker, externally-created
    # window, future rename surface we missed — can't pollute the
    # snapshot diff. Bullet-prefixed names have only ever been
    # observed as dead-pane artifacts; if a legitimate window ever
    # starts with `•`, revisit the filter.
    tmux list-windows -F '#{window_name} bell=#{window_bell_flag}' \
        2>/dev/null | awk '$1 !~ /^•/' | sort || true

    # reports — a BOUNDED, deterministic summary: a total count plus the
    # most-recent N final-report basenames. The change-detection signal is
    # still report add/remove (add = a worker finished; remove = retired):
    # an add/remove flips the count line AND, for recent reports, the
    # recent-N tail — both `.md`/count diffs that _classify_diff treats as
    # signal. NOT mtimes and NOT interim breadcrumbs (nexus-code#236:
    # embedding `%T@` mtimes turned every report rewrite into a churn-only
    # emit; bare basenames keep a rewrite a no-op for change detection).
    #
    # Why bounded (nexus-code reportscan): emitting the FULL basename set
    # was fine at dozens of reports but at 1326+ it (a) approached the scan
    # budget so the listing intermittently completed vs bailed, flapping
    # the section between a ~1326-line dump and the bail sentinel — a giant
    # per-poll diff to the orchestrator, and (b) cost an O(N) sort+paste
    # every poll. count + recent-N is small, stable (same file set → same
    # bytes), and serves the section's purpose (what newly landed). N is
    # tunable (MONITOR_SNAPSHOT_REPORTS_RECENT_N, default 20). LC_ALL=C
    # sort keeps the ordering locale-independent → deterministic.
    #
    # Bounded by a wall-clock budget too: a slow/NFS-stalled reports dir
    # must not wedge the emit loop (crash-over-silence: degrade loud). On a
    # budget-bail we re-emit a STABLE last-known-good cache (see below)
    # rather than a sentinel, so a transiently-slow stat can't flap the
    # section; a cold-start bail (no cache yet) still degrades to a bounded
    # one-line sentinel + a throttled WARN.
    echo '--- reports ---'
    local _rep_to="${MONITOR_SNAPSHOT_REPORTS_TIMEOUT_SECONDS:-5}"
    [[ "$_rep_to" =~ ^[0-9]+$ ]] || _rep_to=5
    local _rep_n="${MONITOR_SNAPSHOT_REPORTS_RECENT_N:-20}"
    [[ "$_rep_n" =~ ^[0-9]+$ ]] || _rep_n=20
    # Last-known-good cache (nexus-code reportscan follow-up). Even bounded
    # to count + recent-N, the scan still does an NFS `find` over ~1300+
    # entries, which intermittently exceeds the (deliberately short) budget.
    # Without a cache that would flap the section ~24 lines/poll between the
    # live block and a bail sentinel. Instead: on a budget-bail we re-emit
    # the LAST SUCCESSFUL block verbatim, so the section is BYTE-STABLE
    # until a scan succeeds again (which refreshes the cache + surfaces any
    # real add/remove one cycle later — acceptable: stability over an
    # instant reaction to a transiently-slow stat). The cache lives in
    # STATE_DIR (always set: line ~372).
    local _rep_cache="${STATE_DIR:-}/snapshot-reports.cache"
    # Directory-mtime fast path (nexus-code reportscan-budget follow-up).
    # The bounded scan below is count + recent-N — but computing it still
    # `find`s the whole reports dir every snapshot_local cycle (30 s), and at
    # 1700+ entries on NFS that alone blew the 5 s budget EVERY cycle (179
    # WARN lines / 5000 log rows observed live 2026-07-07). Yet the emitted
    # block only changes when a report is ADDED or REMOVED — and either bumps
    # the reports DIRECTORY's mtime (link/unlink updates the dir; a report
    # REWRITE touches only the file, not the dir, which is exactly the churn
    # we already didn't want to react to). So: stat the dir once (one NFS
    # round-trip), and when its mtime is unchanged since the last successful
    # scan AND the cache is warm, re-emit the cached block verbatim WITHOUT
    # re-enumerating. The common case (no report landed this cycle) collapses
    # from an O(N) stat-storm to a single stat + cat. A change bumps the dir
    # mtime → exactly one rescan refreshes the cache + stored mtime. Quiet
    # nights never scan at all after the first warm cache.
    local _rep_dirmtime_file="${STATE_DIR:-}/snapshot-reports.dirmtime"
    local _rep_dir="${NEXUS_ROOT}/reports"
    local _rep_dirmtime _rep_dirmtime_cached=""
    _rep_dirmtime=$(date +%s -r "$_rep_dir" 2>/dev/null || echo "")
    [[ -f "$_rep_dirmtime_file" ]] && _rep_dirmtime_cached=$(cat "$_rep_dirmtime_file" 2>/dev/null || echo "")
    local _rep_fast=0
    if [[ -n "$_rep_dirmtime" && "$_rep_dirmtime" == "$_rep_dirmtime_cached" && -s "$_rep_cache" ]]; then
        # Fast path: dir unchanged since the last scan → no add/remove → the
        # cached block is still current. Emit it and skip the scan entirely
        # (no WARN — this is the healthy steady state, not a degradation).
        # Fall through to the git section so the snapshot SHAPE is identical
        # to the scan path (a mid-function return would drop `--- git ---`).
        cat "$_rep_cache" 2>/dev/null
        _rep_fast=1
    fi
    local _rep_out _rep_rc=0
    if (( _rep_fast == 0 )); then
    # No `-type f`: on NFS the per-entry type probe is a stat() per file and
    # IS the budget-blowing cost (1700+ stats). A flat reports dir holds only
    # files by convention; `-name "*.md"` + the interim exclusion are pure
    # name matches (readdir only, no stat), so the scan stays a bulk directory
    # read even when the dir-mtime fast path above misses (e.g. right after an
    # add/remove, or an interim-report write).
    _rep_out=$(NEXUS_ROOT="$NEXUS_ROOT" REPN="$_rep_n" timeout "${_rep_to}s" bash -c '
        names=$(find "${NEXUS_ROOT}/reports" -maxdepth 1 -name "*.md" \
            ! -name "*-interim*.md" -printf "%f\n" 2>/dev/null | LC_ALL=C sort)
        if [[ -n "$names" ]]; then
            total=$(printf "%s\n" "$names" | wc -l | tr -d " ")
        else
            total=0
        fi
        printf "reports-total: %s\n" "$total"
        [[ -n "$names" ]] && printf "%s\n" "$names" | tail -n "$REPN"') \
        || _rep_rc=$?
    if (( _rep_rc == 0 )) && [[ -n "$_rep_out" ]]; then
        # Success → emit live + refresh the cache atomically (tmp + mv). The
        # cached bytes are exactly what we emit, so a later bail re-emit is
        # byte-identical (no diff, no flap).
        printf '%s\n' "$_rep_out"
        if [[ -n "${STATE_DIR:-}" && -d "${STATE_DIR}" ]]; then
            printf '%s\n' "$_rep_out" > "${_rep_cache}.tmp.$$" 2>/dev/null \
                && mv -f "${_rep_cache}.tmp.$$" "$_rep_cache" 2>/dev/null \
                || rm -f "${_rep_cache}.tmp.$$" 2>/dev/null
            # Stamp the dir-mtime the cache reflects so the next cycle can take
            # the fast path when the dir hasn't changed. Written AFTER the cache
            # so a crash between the two only costs one extra scan, never a
            # stale-mtime false fast-path.
            [[ -n "$_rep_dirmtime" ]] \
                && printf '%s\n' "$_rep_dirmtime" > "${_rep_dirmtime_file}.tmp.$$" 2>/dev/null \
                && mv -f "${_rep_dirmtime_file}.tmp.$$" "$_rep_dirmtime_file" 2>/dev/null \
                || rm -f "${_rep_dirmtime_file}.tmp.$$" 2>/dev/null
        fi
    elif (( _rep_rc == 124 )) && [[ -s "$_rep_cache" ]]; then
        # Budget-bail WITH a warm cache → re-emit last-known-good verbatim.
        # Section stays byte-stable across a transient slow stat (no flap).
        cat "$_rep_cache" 2>/dev/null
        declare -F log >/dev/null 2>&1 && \
            log "WARN snapshot_local: reports scan exceeded ${_rep_to}s budget; re-emitted last-known-good cache (section byte-stable; emit loop NOT blocked)"
    else
        # Cold start (bail before any success has warmed the cache) or an
        # empty result → bounded, LOUD sentinel. Never a full dump.
        echo 'reports-total: (scan exceeded budget)'
        declare -F log >/dev/null 2>&1 && \
            log "WARN snapshot_local: reports scan unavailable (rc=${_rep_rc}, no warm cache); emitted stable bounded sentinel (emit loop NOT blocked)"
    fi
    fi   # end: if (( _rep_fast == 0 ))

    # git — OFF by default (MONITOR_SNAPSHOT_GIT_ENABLED=false). EVERY
    # git-row transition (clean↔dirty, SHA bump, worktree add/remove) is
    # classified as pure NOISE by _classify_diff, so the per-worktree
    # `git status --porcelain` scan (the 109-worktree, ~66 s stall on
    # 2026-06-18) buys ZERO change-detection signal while costing O(worktrees)
    # NFS round-trips on the critical path. Excluded entirely by default; the
    # full-state DISPLAY snapshot is unaffected. Gated + budgeted when an
    # operator deliberately restores it.
    if [[ "${MONITOR_SNAPSHOT_GIT_ENABLED:-false}" == "true" ]]; then
        echo '--- git ---'
        local _git_to="${MONITOR_SNAPSHOT_GIT_TIMEOUT_SECONDS:-10}"
        [[ "$_git_to" =~ ^[0-9]+$ ]] || _git_to=10
        local _git_out _git_rc=0
        _git_out=$(NEXUS_ROOT="$NEXUS_ROOT" timeout "${_git_to}s" bash -c '
            for d in "${NEXUS_ROOT}"/work/*/; do
                [[ -d "${d}/.git" ]] || continue
                proj=$(basename "${d}")
                head=$(git -C "${d}" rev-parse HEAD 2>/dev/null || echo none)
                if [[ -n $(git -C "${d}" status --porcelain 2>/dev/null) ]]; then
                    dirty="dirty"
                else
                    dirty="clean"
                fi
                echo "${proj} ${head} ${dirty}"
            done | sort') || _git_rc=$?
        if (( _git_rc == 124 )); then
            echo '(git listing unavailable: scan exceeded budget)'
            declare -F log >/dev/null 2>&1 && \
                log "WARN snapshot_local: git scan exceeded ${_git_to}s budget; emitted stable sentinel (emit loop NOT blocked)"
        elif [[ -n "$_git_out" ]]; then
            printf '%s\n' "$_git_out"
        fi
    fi
}

# GitHub-snapshot helpers (snapshot_github + friends). See _github.sh
# for the union shape and the EYES/ROCKET/processed-comments filter.
# Required globals (STATE_DIR, REPO, USER_LOGIN) are set above.
# shellcheck source=_github.sh
source "$_script_dir/_github.sh"

# Deliveries-polling helpers (snapshot_deliveries). Sourced
# unconditionally — function definitions only, no side effects. The
# poll-cycle code below decides whether to call it based on
# DELIVERIES_ASSET_ENABLED / DELIVERIES_BOT_MENTION_ENABLED. See
# _deliveries.sh for the line-shape vocabulary
# and the eligibility filter.
# shellcheck source=_deliveries.sh
source "$_script_dir/_deliveries.sh"
# Mentions-search helpers (snapshot_mentions). Same sourcing
# discipline; gated below on MENTIONS_ENABLED.
# shellcheck source=_mentions.sh
source "$_script_dir/_mentions.sh"
MINT_JWT_BIN="${MINT_JWT_BIN:-$_monitor_dir/mint-token.sh}"
MINT_TOKEN_BIN="${MINT_TOKEN_BIN:-$_monitor_dir/mint-token.sh}"
export STATE_DIR REPO USER_LOGIN BOT_LOGIN CROSS_REPO_SURFACE \
       MINT_JWT_BIN MINT_TOKEN_BIN \
       DELIVERIES_ASSET_ENABLED DELIVERIES_BOT_MENTION_ENABLED \
       BOT_MENTIONS_ENABLED MENTIONS_CONNECT_TIMEOUT MENTIONS_MAX_TIME

# Raw GraphQL-source emitter for the `github_poll` v2 task. Gated by
# the bucket-floor probe in `_graphql_polling_gate` (skip the fire if
# graphql.remaining < threshold). Emits `snapshot_github` plus, when
# the operator opts in, `snapshot_mentions` and/or
# `snapshot_bot_mentions` — all ride the same App-installation GraphQL
# bucket and so share the same gate.
#
# Raw output only: no filters applied here. `_gh_filter_dedup_pipeline`
# is the single chokepoint that runs filter_to_user_author +
# filter_cross_repo_surface + dedup across the deliveries + github
# streams; it lives at the consumption end (compose_emit + startup
# sweep) so cross-source duplicates can be collapsed.
_snapshot_github_raw() {
    _graphql_polling_gate || return 0
    snapshot_github
    [[ "${MENTIONS_ENABLED:-false}" == "true" ]] && snapshot_mentions
    # Bot-mention search: @<bot> on installed non-asset repos (the
    # webhook-free channel for the gap deliveries can't reach when off).
    [[ "${BOT_MENTIONS_ENABLED:-false}" == "true" ]] && snapshot_bot_mentions
    return 0
}

# Raw webhook-source emitter for the `deliveries_poll` v2 task.
# Skipped entirely when BOTH split concerns are off (no curl cost); the
# per-emit gate inside `_process_delivery` decides which concern actually
# surfaces. The task stays registered so a config reload picks up a flip
# without restart. The webhook bucket is App-JWT and independent of the
# GraphQL bucket, so there's no rate-limit gate here. See the deliveries
# flag SPLIT block in _config.sh for the two flags + their defaults.
_snapshot_deliveries_raw() {
    [[ "${DELIVERIES_ASSET_ENABLED:-false}" == "true" \
       || "${DELIVERIES_BOT_MENTION_ENABLED:-false}" == "true" ]] || return 0
    snapshot_deliveries
}

# Post-processing pipeline shared by every consumer of the raw
# emitters above. Encapsulates eight transforms:
#
#   1. `_filter_to_user_author` — single chokepoint for the
#      USER_LOGIN-authored rule (issue #86).
#   2. `_filter_skip_marker` — operator opt-out. Drops any emit block
#      whose body carries the `/skip` (or `/nexus-skip`) leading
#      slash-command, or the invisible `<!-- nexus:skip -->` HTML
#      marker. A first-class "side note, don't act on this" escape
#      hatch replacing the racy self-🚀 / alternate-identity
#      workarounds. Conservative fixed-string match — a false drop is a
#      lost directive, so any parse uncertainty forwards. Runs right
#      after the author filter so it only weighs operator content.
#   3. `_filter_cross_repo_surface` — `@<bot>`-mention gate for
#      cross-repo `mention=`/`cross_repo=` blocks (issue #86 follow-up;
#      `mention_only` default).
#   4. `_dedup_emit_lines` — collapses cross-source id= duplicates so
#      a comment surfacing through both the webhook and the GraphQL
#      backstop emits once.
#   5. `_filter_suppression` — manual operator override. Drops any emit
#      block whose `id=<N>` matches an entry in
#      `monitor/.state/emit-suppression.lines` (written via
#      `monitor/ng suppress-emit <id>`). PR #188.
#   6. `_filter_processed_comments` — live re-check of the
#      processed-comments cache. Closes the staleness window in which
#      the v2 scheduler holds an eligibility-filtered snapshot of
#      `_snapshot_issue_comments`' output in `github_poll.out` for up
#      to 600s. Without this hop, a comment that became
#      reaction-excluded AFTER the last github_poll fire would
#      resurface every compose_emit until the next 600s tick refreshed
#      the staged file (the live reproduction at
#      `your-org/your-nexus#128` comment 4560117367 on 2026-05-27).
#   7. `_filter_reemit_backoff` — body-INDEPENDENT re-emit backoff for
#      cross-repo `mention=`/`cross_repo=` blocks only. Caps a mention
#      id's re-emit cadence to once per `MONITOR_REEMIT_BACKOFF_SECONDS`
#      regardless of body, so a stale-registry-body vs live-edited-body
#      divergence can't double-emit a mention before the orchestrator
#      👀-acks it (your-org/nexus-code#358). In-$REPO shapes pass
#      through; the SHA cooldown (next hop) still owns their cadence.
#   8. `_filter_emit_cooldown` — last-hop per-comment rate limiter.
#      After an emit of `id=<N>`, subsequent emits within
#      `MONITOR_EMIT_COOLDOWN_SECONDS` are dropped unless the body
#      content-hash changes. Caps the emit rate even when every
#      upstream layer somehow misses; runs LAST so the stamp/sha
#      records actually-emitted state.
#
# Callers feed the concatenated raw streams via stdin; output is the
# eligible-comments view the compose path consumes.
_gh_filter_dedup_pipeline() {
    _filter_to_user_author \
        | _filter_skip_marker \
        | _filter_cross_repo_surface \
        | _dedup_emit_lines \
        | _filter_suppression \
        | _filter_processed_comments \
        | _filter_reemit_backoff \
        | _filter_emit_cooldown
}

# File-fed variant for `_run_bounded` (which feeds args, not stdin). Reads
# the staged raw-emit concatenation from <infile> and runs it through the
# full filter pipeline on stdout. Used by `_v2_task_compose_emit` to BOUND
# the body-processing stage: this is the one compose_emit step whose input
# is operator-controlled comment content (vs. the watcher's own rendered
# state), so a single pathological body must never be able to hang it and
# wedge the cycle-end heartbeat. On overrun the caller treats the result
# as empty and keeps beating (nexus-code: compose_emit multibyte wedge).
_gh_filter_dedup_pipeline_file() {
    _gh_filter_dedup_pipeline < "$1"
}

# Emit filters (the `_gh_filter_dedup_pipeline` members defined in this
# repo: suppression, processed-comments re-check, per-comment cooldown,
# cross-source dedup). Extracted to _emit_filters.sh (issue 180 seam
# S2). Functions only; no side effects on source. Required globals
# (STATE_DIR, MONITOR_EMIT_COOLDOWN_SECONDS) are set above and read at
# call time.
# shellcheck source=_emit_filters.sh
source "$_script_dir/_emit_filters.sh"

# Standing bells on non-orchestrator windows (excludes the configured
# target window $TARGET, plus the reserved names 'orchestrator',
# 'claude' (legacy orch-window name, kept indefinitely so stale tmux
# sessions don't self-bell-loop), and 'monitor' to avoid orchestrator-
# self-bell feedback loops). Also drops `•`-prefixed rows: a transient
# sandbox-notify `•bell` window carries bell_flag=1 and would otherwise
# surface here as a phantom standing bell (same drop as snapshot_local /
# _idle_list_worker_windows). Format: <idx>\t<name>.
list_bell_windows() {
    tmux list-windows -F '#{window_index}|#{window_name}|#{window_bell_flag}' \
        2>/dev/null \
        | awk -F'|' -v target="${TARGET:-orchestrator}" \
            '$3==1 && $2 !~ /^•/ && $2!=target && $2!="orchestrator" && $2!="claude" && $2!="monitor" {print $1 "\t" $2}'
}

# Clear bells without shifting the attached client's focus. Uses a
# detached helper session in the same session group — selecting a window
# there clears the shared bell flag without touching the attached
# session's current-window pointer.
clear_bells() {
    local indices="$1" sess helper idx
    [[ -z "$indices" ]] && return 0
    sess=$(tmux display -p '#{session_name}' 2>/dev/null) || return 0
    helper="nx-bell-clear-$$"
    tmux new-session -d -s "$helper" -t "$sess" 2>/dev/null || return 0
    while IFS= read -r idx; do
        [[ -z "$idx" ]] && continue
        tmux select-window -t "${helper}:${idx}" 2>/dev/null || true
    done <<< "$indices"
    tmux kill-session -t "$helper" 2>/dev/null || true
}

# ---- emit / paste / archive ---------------------------------------------

# Content-hash emit-dedup gate (stable hash + bypass + the
# decide/record pair around paste_with_retry). Extracted to
# _emit_dedup.sh (issue 180 seam S3). Functions only; no side effects
# on source. Required globals (EMIT_DEDUP_HASH_FILE, EMIT_DEDUP_TS_FILE,
# MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS, the `log` fn) are set above and
# read at call time.
# shellcheck source=_emit_dedup.sh
source "$_script_dir/_emit_dedup.sh"

# Re-emit-until-acked registry for cross-repo bot-mention comments
# (nexus-code#236). Functions only; no side effects on source. Required
# globals (STATE_DIR, USER_LOGIN, MONITOR_REEMIT_*, MONITOR_EMIT_COOLDOWN_SECONDS,
# the `log` fn) are set above and read at call time.
# shellcheck source=_reemit.sh
source "$_script_dir/_reemit.sh"
# Request inbox (agent-channel RFC Part B/D). Defines requests_poll_emit
# (claim .new→.claimed, re-emit-until-ack with cooldown/cap/fairness, GC).
# Function definitions only; gated at runtime by MONITOR_REQUESTS_ENABLED
# (default off) so sourcing is inert on a fresh clone.
# shellcheck source=_requests.sh
source "$_script_dir/_requests.sh"

# Compose the report body (stdout). No `--- relaunch ---` footer: the
# watcher is persistent, so that instruction is obsolete. The dashboard
# freshness footer stays — it's still a useful hint.
#
# Trailing arg `full_state_lines` (optional) carries the periodic
# full-state snapshot rendered by `render_full_state_snapshot` in
# _idle_probe.sh. When non-empty, the snapshot is inserted as a
# `--- workspace snapshot ---` section after the transition-only
# idle-workers section, giving the operator a complete view at the
# configured cadence (default every 10 min; see issue #72 D4).
# Per-section emit guard — answers the operator design ask: "prevent
# emitting too-long messages WITHOUT risking dropping important signals."
#
# Caps each emit section at MONITOR_EMIT_SECTION_MAX_LINES content lines
# (default 50), replacing the overflow with a single
# `[+N more lines omitted]` marker. SIGNAL sections are EXEMPT — never
# truncated — via the explicit allowlist below; everything else is
# truncatable-by-default, so a future bulk section can't silently bloat an
# emit while a new signal section just gets added to the allowlist.
#
# DESIGN (the answer to the operator's question):
#   * cap value         MONITOR_EMIT_SECTION_MAX_LINES, default 50.
#   * truncatable        ONLY `--- local state changes ---` (the
#                        change-detection diff: the canonical bulk section,
#                        already bounded at the source for reports). tmux
#                        sub-section is ordered first so window transitions
#                        live in the kept head, never the dropped tail.
#   * EXEMPT allowlist   every signal section (see `exempt[]` below) plus
#                        the preamble (banner + CLAUDE.md hint + the
#                        `workspace:` state line, all before the first
#                        header). The emit-sig trailer is exempt + has no
#                        body, so it always survives as the final line
#                        (paste_to_target verifies it via tail -1).
#
# DETERMINISTIC (pure line transform — no clock, no randomness; same input
# → same bytes, so it can't itself introduce a flap) and CHEAP (one awk
# pass, no dir scan). A "section" runs from a header line matching
# `^--- <words> ---$` to the next such header (or EOF). local_diff lines
# are safely NOT mistaken for headers: unified-diff context markers carry a
# leading space (` --- reports ---`) and file headers (`--- baseline<TAB>…`)
# do not end in ` ---`.
_cap_emit_sections() {
    local max="${MONITOR_EMIT_SECTION_MAX_LINES:-50}"
    [[ "$max" =~ ^[0-9]+$ ]] || max=50
    awk -v max="$max" '
        BEGIN {
            # --- EXEMPT ALLOWLIST: signal sections, NEVER truncated -------
            # Inherently small + the whole point of the emit. To keep a NEW
            # signal section un-capped, add its exact header here.
            exempt["--- watcher revived (was down) ---"]      = 1
            exempt["--- arm watcher supervisor ---"]          = 1
            exempt["--- install failure ---"]                 = 1
            exempt["--- watcher hosting migration ---"]       = 1
            exempt["--- component drift (restart needed) ---"]= 1
            exempt["--- service health ---"]                  = 1
            exempt["--- claude code update available ---"]    = 1
            exempt["--- reports archived ---"]                = 1
            exempt["--- eligible github comments ---"]        = 1
            exempt["--- standing bells ---"]                  = 1
            exempt["--- pending decisions ---"]               = 1
            exempt["--- requests ---"]                        = 1
            exempt["--- idle workers ---"]                    = 1
            exempt["--- workspace snapshot ---"]              = 1
            exempt["--- dashboard ---"]                       = 1
            ex = 1; n = 0; omit_n = 0   # preamble: always preserved
        }
        function flush_omit() {
            if (omit_n > 0) {
                printf "  [+%d more line%s omitted]\n", omit_n, (omit_n == 1 ? "" : "s")
                omit_n = 0
            }
        }
        # Section header: `--- words ---` at column 0. The emit-sig trailer
        # matches too but is exempt-by-default below (unlisted ⇒ would be
        # capped, but it has no body, so cap is a no-op) — guard it anyway.
        /^--- .+ ---$/ {
            flush_omit()
            ex = ($0 in exempt || $0 ~ /^--- nexus-emit-sig /) ? 1 : 0
            n = 0
            print
            next
        }
        {
            if (ex) { print; next }
            n++
            if (n <= max) { print; next }
            omit_n++
        }
        END { flush_omit() }
    '
}

compose_report() {
    # Thin wrapper: build the body, then run it through the per-section emit
    # guard so no single section can flood the orchestrator paste.
    _compose_report_body "$@" | _cap_emit_sections
}

_compose_report_body() {
    local reason="$1" local_diff="$2" github_list="$3" bell_lines="$4" idle_lines="${5:-}" full_state_lines="${6:-}" pending_decisions="${7:-}" install_failure_lines="${8:-}" cc_update_lines="${9:-}" hosting_migration_lines="${10:-}" version_drift_lines="${11:-}" service_health_lines="${12:-}" watcher_revived_lines="${13:-}" supervisor_arm_lines="${14:-}" requests_lines="${15:-}" reports_roll_lines="${16:-}"
    echo "=== nexus state changed at $(date -Is) (${reason}) ==="
    echo "*If unsure how to proceed: see CLAUDE.md.*"
    # One-line workspace prelude. Always printed — gives the operator
    # a glance-level read on workspace state at the top of every emit
    # without scrolling. Issue #72 D4.
    local prelude
    prelude=$(render_idle_prelude 2>/dev/null || true)
    if [[ -n "$prelude" ]]; then
        printf 'workspace: %s\n' "$prelude"
    fi
    if [[ -n "$watcher_revived_lines" ]]; then
        # SELF-FAILURE REPORT (watcher-supervision). The watcher cannot
        # report its own death — it is down. So when the watcher-supervisor
        # daemon revives a CRASHED watcher, it leaves a `watcher-revived`
        # marker, and THIS (the revived watcher's first emit) surfaces it,
        # then clears it. Pinned at the very top: a watcher that silently
        # died and came back is exactly what the operator must know about.
        echo '--- watcher revived (was down) ---'
        printf '%s\n' "$watcher_revived_lines"
    fi
    if [[ -n "$supervisor_arm_lines" ]]; then
        # The orchestrator's watcher-supervisor Monitor is not armed (no
        # fresh supervisor heartbeat). Pinned high: an unarmed supervisor
        # means a watcher crash has no turn-independent revival. Standing
        # reminder — self-clears the instant the Monitor is armed.
        echo '--- arm watcher supervisor ---'
        printf '%s\n' "$supervisor_arm_lines"
    fi
    if [[ -n "$install_failure_lines" ]]; then
        # Project-local Claude Code install failed at watcher startup.
        # Surfaced once (the launcher.sh writes a flag file; the
        # watcher consumes + deletes it on first emit). Orchestrator
        # can rerun `monitor/install-claude-local.sh` to retry.
        echo '--- install failure ---'
        printf '%s\n' "$install_failure_lines"
    fi
    if [[ -n "$hosting_migration_lines" ]]; then
        # This watcher is running legacy window-hosted (issue 182).
        # Computed once at startup (_hosting_is_legacy), surfaced only
        # in the startup sweep — at most once per watcher lifecycle.
        # The watcher keeps operating normally; the section tells the
        # orchestrator how to converge to headless hosting.
        echo '--- watcher hosting migration ---'
        printf '%s\n' "$hosting_migration_lines"
    fi
    if [[ -n "$version_drift_lines" ]]; then
        # A nexus-code component changed on disk and its restart needs
        # the orchestrator (cockpit ask, tripped self-restart guard, or
        # a disabled auto-restart channel). Watcher- and service-drift
        # restarts that ARE automated never surface here — only the
        # asks. See monitor/watcher/_version_restart.sh.
        echo '--- component drift (restart needed) ---'
        printf '%s\n' "$version_drift_lines"
    fi
    if [[ -n "$service_health_lines" ]]; then
        # A registered infra service (monitor/services.registry) failed
        # its healthcheck. The watcher gives it a self-heal grace window
        # first (deferring to its supervisor wrapper), then acts only if
        # still unhealthy and only per the service's restart policy
        # (auto-restart → flap-controlled svc.sh restart; emit-only →
        # escalate). This section ALWAYS reports the full state —
        # grace/recovering/emit-only/flapping (and one-shot recovered
        # breadcrumbs) plus the policy in effect. On an emit-only/flapping
        # escalation the orchestrator runs the availability-and-trust
        # protocol in skills/nexus.service-recovery: restore first,
        # dispatch a root-cause worker, open an operator incident issue
        # (monitor/ng service-incident <svc>). Re-nag guarded in
        # _service_health_emit_section; cleared on a clean recovery.
        echo '--- service health ---'
        printf '%s\n' "$service_health_lines"
    fi
    if [[ -n "$cc_update_lines" ]]; then
        # A newer Claude Code release than the local pin is available.
        # GATED advisory: the orchestrator spawns an evaluator briefed
        # with the updater skill (skills/nexus.cc-update/GUIDE.md) to run
        # the cc-harness gate before any promote. Surfaced once per
        # candidate (see _cc_update_emit_section's re-nag guard).
        echo '--- claude code update available ---'
        printf '%s\n' "$cc_update_lines"
    fi
    if [[ -n "$reports_roll_lines" ]]; then
        # The auto-roll (your-org/nexus-code#447) moved aged reports into
        # monthly reports/YYYY-MM/ buckets. One-shot audit breadcrumb: written
        # ONLY on a run that actually moved ≥1 file, surfaced once, then
        # consumed (self-clearing → no flap). Purely informational — no
        # operator action needed; the ≥1-month buffer guarantees nothing
        # recent/in-flight was touched.
        echo '--- reports archived ---'
        printf '%s\n' "$reports_roll_lines"
    fi
    if [[ -n "$local_diff" ]]; then
        # Change-detection diff vs the baseline snapshot (tmux/reports/git
        # sub-sections). The canonical BULK / low-priority section — the
        # ONLY section truncatable-by-default under the per-section emit cap
        # (_cap_emit_sections). Wrapped in its own marker so the cap can
        # identify and bound it; tmux is ordered FIRST in snapshot_local so
        # a window transition never falls into the truncated tail behind
        # report churn, and the reports sub-section is already bounded
        # (count + recent-N) at the source.
        echo '--- local state changes ---'
        printf '%s\n' "$local_diff"
    fi
    if [[ -n "$github_list" ]]; then
        echo '--- eligible github comments ---'
        printf '%s\n' "$github_list"
    fi
    if [[ -n "$bell_lines" ]]; then
        echo '--- standing bells ---'
        printf '%s\n' "$bell_lines" \
            | awk -F'\t' 'NF>=2 {printf "  - %s (idx %s)\n", $2, $1}'
        echo '(silenced after emit; agents will re-ring on the next event)'
    fi
    if [[ -n "$pending_decisions" ]]; then
        # Structured per-decision channel (issue #129). Sourced from
        # monitor/.state/decisions/*.json — written by workers' own
        # Notification hook (monitor/hooks/decision-emit.sh). Deduped
        # with cooldown in render_pending_decisions. Ack channel =
        # orchestrator removes the cited file once answered.
        echo '--- pending decisions ---'
        printf '%s' "$pending_decisions"
        echo '(read the cited file for full JSON; ack by removing it once answered)'
    fi
    if [[ -n "$requests_lines" ]]; then
        # Watcher-mediated request inbox (agent-channel RFC Part B/D).
        # Sourced from monitor/.state/requests/*.claimed.md — filed by a
        # worker (or, Phase 2, a confined remote SSH client) via
        # `ng request file`. Claimed + re-emitted (cooldown, cap, origin
        # fairness) by monitor/watcher/_requests.sh. Ack/answer protocol:
        #   ng request ack <id>     (.claimed → .done; bare acknowledgement)
        #   ng request reply <id> … (.claimed → .replied; writes ## Reply +
        #                            reply: refs — worker/dir/issue, or the
        #                            no-publish progress/results fetch path)
        # See agent-prompt.md "Draining the request inbox".
        echo '--- requests ---'
        printf '%s' "$requests_lines"
        echo '(read the cited file; ack via `ng request ack <id>` or answer via `ng request reply <id> …`)'
    fi
    if [[ -n "$idle_lines" ]]; then
        # Idle-worker transitions: wrapped → orchestrator can consider
        # close per nexus.window-cleanup; no-wrap-up → orchestrator
        # pastes the "wrap-up missing" follow-up. One emit per
        # transition, deduped against the prior cycle's set (see
        # _idle_probe.sh).
        echo '--- idle workers ---'
        printf '%s\n' "$idle_lines"
        echo '(emitted on transitions only; see skills/nexus.window-cleanup)'
    fi
    if [[ -n "$full_state_lines" ]]; then
        # Periodic full-state snapshot (issue #72 D4). Every Nth emit
        # this section is filled in regardless of transitions, giving
        # operators a cumulative view. Transition emits in between
        # stay narrow.
        echo '--- workspace snapshot ---'
        printf '%s\n' "$full_state_lines"
        echo '(full snapshot; transitions only between snapshots)'
    fi
    # Every emit already implies "state has shifted since", so the only
    # useful gate on the refresh prompt is age: suppress it when the
    # dashboard is fresh (< 2h) so it doesn't become noise.
    echo '--- dashboard ---'
    local dash_ts_file="${STATE_DIR}/dashboard-updated.ts" dash_ts dash_age_s
    if [[ -f "$dash_ts_file" ]]; then
        dash_ts=$(cat "$dash_ts_file")
        echo "last updated: $dash_ts"
        dash_age_s=$(( $(date +%s) - $(date -d "$dash_ts" +%s 2>/dev/null || echo 0) ))
        if (( dash_age_s >= 7200 )); then
            echo '(> 2h old; refresh via `monitor/ng dashboard put`)'
        fi
    else
        echo 'last updated: unknown'
        echo '(no dashboard-updated.ts; refresh via `monitor/ng dashboard put`)'
    fi
    # Trailer signature. Used by paste_to_target for content-level
    # verification: unique per emit (contains timestamp + shortid) and
    # lives near the bottom of the rendered message so it rarely
    # scrolls out of the capture-pane window even for long bodies.
    printf -- '--- nexus-emit-sig %s %s ---\n' "$(date -Is)" "$EMIT_SIG_NONCE"
}

# Paste body into target tmux window.
#
# VI-mode hardening (CLAUDE.md docs that Claude Code uses VI
# keybindings — a paste arriving in normal mode gets interpreted as
# commands and the content is lost). We prepend `i` + BSpace before
# every paste, which leaves the target in insert mode with an unchanged
# buffer regardless of starting state:
#   - From insert mode: `i` inserts a literal 'i', BSpace deletes it.
#     Net: no buffer change, still in insert mode.
#   - From normal mode:  `i` enters insert mode, BSpace is a no-op on an
#     empty buffer (or deletes one char of pre-existing text, which is
#     unlikely for an agent target). Net: now in insert mode.
# The `Escape` + `i` alternative was rejected because Escape has real
# side effects in the Claude Code REPL (cancels menus, can abort
# mid-turn generation).
#
# Content-level verification: after the submit, grep the target pane
# for the first line of the body (a unique `=== nexus state changed at
# <ISO> (reason) ===` signature). If absent, the paste didn't land —
# paste_with_retry triggers a second attempt.
#
# Optional `$3` stamp mode: the default (`stamp`) records the paste in
# the orchestrator-liveness anchor; `no-liveness-stamp` suppresses that
# recording. The liveness task's re-submit rescue uses the latter — a
# re-paste of an already-pending body must NOT advance the last-paste
# clock, otherwise the rescue would reset the dead-threshold deadline
# it is supposed to be racing against.
#
# Return codes:
#   0  pasted + submitted + content verified
#   1  tmux not available
#   2  target window missing
#   3  paste / submit tmux API call failed
#   4  paste submitted but signature not visible in pane
paste_to_target() {
    local target="$1" body_file="$2" stamp_mode="${3:-stamp}"
    command -v tmux >/dev/null 2>&1 || return 1
    tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qxF "$target" || return 2
    # Re-resolve name→@id for the tmux -t verbs (#323). The over-limit
    # worker-wake leg passes a WORKER name, which may contain a dot
    # (`cc-update-2.1.183`); `-t name` would dot-parse it as window.pane
    # and the wake paste would silently never land. KEEP $target as the
    # NAME for the existence check above and the liveness-stamp gate
    # below — both are name-keyed by design. Fall back to the name if
    # resolution fails (the existence check just passed, so this is
    # belt-and-suspenders).
    local tgt; tgt=$(resolve_window_id "$target" 2>/dev/null || true); tgt="${tgt:-$target}"
    # Force target into insert mode without corrupting an already-insert
    # target. See function-header comment for the rationale.
    tmux send-keys -t "$tgt" i BSpace 2>/dev/null || return 3
    local buf="nexus-watcher-$$-$(date +%s%N)"
    tmux load-buffer -b "$buf" "$body_file" 2>/dev/null || return 3
    tmux paste-buffer -b "$buf" -t "$tgt" 2>/dev/null \
        || { tmux delete-buffer -b "$buf" 2>/dev/null; return 3; }
    sleep 0.1
    tmux send-keys -t "$tgt" Enter 2>/dev/null \
        || { tmux delete-buffer -b "$buf" 2>/dev/null; return 3; }
    tmux delete-buffer -b "$buf" 2>/dev/null || true
    # Content-level verification. Every emit body ends with a
    # `--- nexus-emit-sig <iso> <nonce> ---` trailer — unique per emit
    # and close to the cursor in the rendered pane so it stays visible
    # even when the paste is long enough to push the header off-screen.
    # Grep for the bare `nexus-emit-sig <iso> <nonce>` substring so
    # leading dashes don't look like grep options.
    sleep 0.2
    local sig
    sig=$(tail -1 "$body_file" 2>/dev/null \
          | sed -n 's/.*\(nexus-emit-sig [^ ]* [^ ]*\).*/\1/p' | head -c 100)
    if [[ -n "$sig" ]]; then
        tmux capture-pane -t "$tgt" -p -S -200 2>/dev/null \
            | grep -qF -e "$sig" || return 4
    fi
    # Refresh the orchestrator-liveness pin (issue #150). A successful
    # round-trip here is the strongest "orch is reachable" signal the
    # watcher has — stronger than UserPromptSubmit-hook fires, which
    # the previous wiring (PR #147) depended on and which skip on
    # quiet workspaces (no paste, no hook) and on busy orchestrators
    # (paste queued mid-tool-call → no hook). Helper is a strict no-op
    # on missing/empty pin file (see _orchestrator_refresh_pin in
    # _lib.sh for the rationale). No log line: the existing
    # `log "pasted to ..."` at every caller already evidences the
    # refresh, and this fires every poll on a healthy workspace.
    _orchestrator_refresh_pin "$ORCH_PIN_FILE"
    # Paste-driven liveness anchor (#157). Stamp the last-paste epoch
    # IFF the paste targeted the orchestrator window. Other paste
    # consumers (over-limit wake-loop pasting into a worker pane)
    # legitimately use this helper but their pastes are not signal
    # for the orchestrator's liveness probe — gating on target prevents
    # the probe from being silently disarmed by unrelated worker
    # traffic. The downstream consumer
    # `_orchestrator_unresponsive` reads epoch from line 1; atomic
    # tmp+mv write keeps a torn read impossible.
    # Re-submit rescues pass `no-liveness-stamp` so the re-paste of an
    # already-pending body can't reset the dead-threshold clock.
    if [[ "$target" == "${TARGET:-}" && "$stamp_mode" != "no-liveness-stamp" ]]; then
        _orchestrator_record_paste "$ORCH_LAST_PASTE_FILE"
    fi
    return 0
}

paste_with_retry() {
    local target="$1" body_file="$2" stamp_mode="${3:-stamp}" rc
    paste_to_target "$target" "$body_file" "$stamp_mode"; rc=$?
    # rc=3 (tmux API glitch) and rc=4 (content didn't land) are both
    # retryable with a 0.5 s delay. rc=2 (target missing) is handled
    # by the agent-respawn path upstream; rc=1 (no tmux) is terminal.
    if (( rc == 3 || rc == 4 )); then
        sleep 0.5
        paste_to_target "$target" "$body_file" "$stamp_mode"; rc=$?
    fi
    return $rc
}

# Respawn the monitoring agent in the target tmux window. Called when
# the target has been observed missing on more than
# AGENT_MISSING_RESPAWN_DELAY consecutive polls (default 3 — four
# consecutive absent observations at the 2 s probe cadence) AND the
# pre-launch re-verification (`_respawn_verify_target_absent`) found
# no evidence of a live orchestrator.
# The new agent's initial prompt explicitly invites it to validate the
# respawn and kill the watcher if the call was wrong. Mirror of the
# agent->watcher respawn in bootstrap.sh — a full duplex liveness contract
# between the two, with the configured user (`github.user_login` in
# config/nexus.yml) as the external tie-breaker on GitHub.
respawn_agent() {
    local target="$1"
    local reason="${RESPAWN_REASON:-target window '${target}' absent; spawned new agent}"

    # Issue #176: pin-resolve the resume command BEFORE composing the
    # recovery prompt so the boilerplate names the exact mode the
    # resumed orchestrator will see. The shared helper is idempotent
    # — passing the same sid to `_respawn_orchestrator` via
    # `--resume-sid` guarantees the two see the same decision (no
    # race if the pin file changes between this read and the spawn).
    local resume_choice resume_mode resume_sid resume_cmd_label
    resume_choice=$(_respawn_choose_resume_mode "$NEXUS_ROOT")
    resume_mode="${resume_choice%%$'\t'*}"
    resume_sid="${resume_choice#*$'\t'}"
    case "$resume_mode" in
        resume)
            resume_cmd_label="claude --resume ${resume_sid}"
            ;;
        *)
            # Issue #200: pin missing/stale → cold spawn. Do NOT claim
            # any session was resumed (the old `--continue` fallback
            # resurrected an arbitrary freshest jsonl — the footgun
            # behind the 2026-05-29 second-death).
            resume_mode="fresh"
            resume_cmd_label="a fresh session (no prior context resumed)"
            ;;
    esac

    # Compose the recovery prompt the freshly spawned orchestrator gets
    # pasted as turn-1. Two flavours, keyed on $resume_mode:
    #   resume — the agent already has its prior context (--resume
    #            <pinned-sid>); the prompt just explains the respawn and
    #            asks it to validate the call before resuming work.
    #   fresh  — the agent has NO prior context; the prompt must say so
    #            plainly and point it at CLAUDE.md / agent-prompt.md so
    #            it re-onboards rather than assuming a resumed history.
    # Bodies live in _respawn_prompts.sh (issue 180 seam S4).
    local prompt_file prompt_tmpdir
    prompt_tmpdir="${RESPAWN_TMPDIR:-/tmp}"
    prompt_file=$(mktemp --suffix=.txt "$prompt_tmpdir/nexus-respawn-prompt-XXXXXX") \
        || { log "respawn-agent: mktemp prompt failed"; return 1; }
    # issue #238: the in-process watcher-supervisor Monitor died with the
    # orchestrator we are replacing. Pass the exact (re-)arm command into
    # the turn-1 prompt so the new orchestrator re-arms it as its first
    # post-validation action — closing the post-respawn gap deterministically
    # instead of relying on the heartbeat-staleness emit. Single source of
    # truth via _supervisor_monitor_command (shared with the arm-emit + the
    # supervise-tick DOWN message), so the command can never drift.
    local sup_cmd
    sup_cmd=$(_supervisor_monitor_command "$NEXUS_ROOT")
    if [[ "$resume_mode" == "resume" ]]; then
        _respawn_render_prompt_resume "$target" "$reason" "$resume_cmd_label" "$sup_cmd" \
            > "$prompt_file"
    else
        _respawn_render_prompt_fresh "$target" "$reason" "$sup_cmd" > "$prompt_file"
    fi

    # Issue #161 + #176 + #200: route through the shared
    # `_respawn_orchestrator` helper. Pass `--resume-sid <sid>` when the
    # pin pointed to a valid jsonl so the spawn uses `claude --resume
    # <sid>` (deterministic). When the pin can't identify a session,
    # pass `--no-continue` to force a COLD spawn — this is what keeps
    # the prompt above (which tells the agent it has no context)
    # consistent with what claude actually does, and closes the
    # `--continue` most-recent-jsonl footgun (issue #200).
    local rc=0
    # Absent-target path: forward the streak-start anchor and DO NOT set
    # --force-replace, so the helper's pre-kill re-verify guard (issue
    # #203) aborts if a live orchestrator reappeared in the window
    # between this (possibly async / restart-surviving) decision and the
    # actual kill.
    local -a respawn_args=("$target" --prompt-file "$prompt_file" --log-fn log \
        --streak-start "${missing_target_since:-0}")
    if [[ "$resume_mode" == "resume" && -n "$resume_sid" ]]; then
        respawn_args+=(--resume-sid "$resume_sid")
    else
        respawn_args+=(--no-continue)
    fi
    _respawn_orchestrator "${respawn_args[@]}" || rc=$?
    rm -f "$prompt_file"

    case "$rc" in
        0)
            # Successful spawn resets the slow-grind counter — the
            # failure mode this counter targets (tmux can't create
            # the window) is now demonstrably absent. Paste-to-target
            # may still fail (rc=4), but that's a different axis
            # owned by the paste_with_retry callers and the helper's
            # own rc=4 propagation.
            _respawn_consec_reset "$RESPAWN_CONSEC_COUNTER"
            ;;
        5)
            # Issue #203: the re-verify guard aborted the kill because a
            # live orchestrator reappeared in the window. This is the
            # CORRECT outcome (a healthy orchestrator was NOT destroyed),
            # not a failure — do not touch the slow-grind / consec
            # counters. Log loudly + action-log so the event is auditable.
            log "respawn-agent: ABORTED — re-verify found a live orchestrator in '${target}'; no window destroyed (issue #203 guard)"
            if [[ -x "$_monitor_dir/ng" ]]; then
                "$_monitor_dir/ng" log-action watcher \
                    --event respawn-aborted-live-orchestrator \
                    --note "$reason" \
                    >/dev/null 2>&1 || true
            fi
            return 0
            ;;
        2)
            log "respawn-agent: tmux not installed; skipping"
            return 1
            ;;
        3)
            # Issue #77: slow-grind axis. Burst-limit guard upstream
            # only catches N-in-W; a 1-per-60 s drip needs this
            # consecutive-failure counter to escalate.
            _respawn_consec_record_failure "$RESPAWN_CONSEC_COUNTER"
            return 1
            ;;
        *)
            log "respawn-agent: helper returned rc=$rc"
            return 1
            ;;
    esac

    # The replaced session took its pasted-but-unread requests with it:
    # reset the delivery stamps so every still-claimed request is due
    # again and surfaces to the fresh orchestrator within one poll
    # (#489 skeptic C2).
    requests_reset_delivery_state

    # Action-log entry the respawn. Never block the watcher on this.
    if [[ -x "$_monitor_dir/ng" ]]; then
        "$_monitor_dir/ng" log-action watcher \
            --event watcher-respawn-agent \
            --note "$reason" \
            >/dev/null 2>&1 || true
    fi
    log "respawn-agent: spawned new claude in window '${target}'"
    return 0
}

# Async-respawn wrapper (issue #171). Source-loads
# `_respawn_async.sh` so the `target_window` scheduler task can
# launch `respawn_agent` in a backgrounded subshell instead of
# blocking the whole scheduler loop for the wall-time of the respawn
# dance. Functions only; no side effects on source.
# shellcheck source=_respawn_async.sh
source "$_script_dir/_respawn_async.sh"

# Target-absent decision tree (issue #174). The hoisted-out body of
# the rc=2 branch — incremented counter, async-reap, slow-grind /
# crash-loop / launch gating. The `target_window` scheduler probe
# calls it on every absent observation. Functions only.
# shellcheck source=_target_absent.sh
source "$_script_dir/_target_absent.sh"

# Write the archive entry and return the path. Filename uses a sortable
# ts + 6-char random id so repeated emits in the same second don't collide.
# Optional `$2` is a filename tag inserted before the .md extension —
# `resurface` for comment-only re-emits where last-snapshot.txt is left
# untouched, so the archive line shape advertises the variant for
# post-hoc debugging.
archive_emit() {
    local body_file="$1" tag="${2:-}"
    local ts shortid suffix out
    ts=$(date -u +%Y-%m-%d_%H-%M-%S)
    shortid=$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 6)
    [[ -n "$shortid" ]] || shortid=$(printf '%06d' $((RANDOM % 1000000)))
    suffix=""
    [[ -n "$tag" ]] && suffix="_${tag}"
    out="${DIFF_DIR}/${ts}_${shortid}${suffix}.md"
    cp "$body_file" "$out"
    printf '%s' "$out"
}

# Newest emit archive by NAME (stat-free). Prints the absolute path of the
# most-recent archive in <dir>, or nothing when the dir is empty/absent.
#
# your-org/nexus-code#<this> (sibling of #402/#403): the orchestrator-liveness
# "resubmit" rescue picked the newest archive with
#   find "$DIFF_DIR" -printf '%T@ %p\n' | sort -rn | head -n1
# which stat()s EVERY file just to select ONE. On the ~17k-file 7-day plateau
# that took ~9-14 min on the NFS state dir, and — because orchestrator_liveness
# runs in the SYNC phase every 5 s (no --async) — it stalled the scheduler
# heartbeat past the staleness threshold → supervisor "watcher DOWN" → the
# 2026-07-07 outage. Exactly the wedge class #403 fixed for prune_archive; this
# path was missed.
#
# archive_emit names files `%Y-%m-%d_%H-%M-%S_<id>[_tag].md` — a lexically
# sortable UTC timestamp prefix — so the lexically-GREATEST name is the newest
# emit. Bash pathname expansion reads the directory and returns names
# collation-sorted with NO per-file stat; LC_ALL=C forces byte order so the
# sortable-ts names come out chronological regardless of locale (mirrors
# _prune_diffs_bounded). The last glob element is therefore the newest — O(1)
# after the single readdir, no sort pipeline, no stat storm.
#
# Tag suffixes (`_full-state`, `_resurface`) sort AFTER a bare `<id>.md` at the
# same `<ts>_<id>` prefix, but each emit writes exactly ONE archive with a
# fresh random <id>, so no two files ever share a `<ts>_<id>` prefix — the max
# is always a single real emit body. A tagged newest emit is itself a valid
# body to re-paste (full-state/resurface archives are real pasted emits), so
# returning it is correct.
_newest_emit_archive() {
    local dir="${1:?dir required}"
    [[ -d "$dir" ]] || return 0
    local LC_ALL=C
    local _restore_nullglob files
    _restore_nullglob=$(shopt -p nullglob)
    shopt -s nullglob
    files=( "$dir"/*.md )
    eval "$_restore_nullglob"
    local n=${#files[@]}
    (( n > 0 )) || return 0
    printf '%s' "${files[n-1]}"
}

# Size-capped rotation for an append-only .state file (issue 180 R2).
# Mirrors `_notifications_rotate_if_oversized` in _idle_probe.sh:
# rotate to `<path>.<epoch>` past the cap, prune rotated archives older
# than DIFF_RETENTION_DAYS. Two modes, chosen by the writer's fd
# discipline:
#
#   rename       — for files whose writers open-append-close on every
#                  write (`>>` in a fresh process or per-call
#                  redirection: scheduler JSONL, functional-check TSV,
#                  ng's action-log). The next write recreates the file.
#   copytruncate — for watcher.log ONLY. The headless launcher holds a
#                  long-lived O_APPEND fd on the inode
#                  (`setsid main.sh >>"$LOGFILE" 2>&1`); a rename would
#                  leave that fd appending to the archive forever while
#                  the new live file stays empty. cp + truncate keeps
#                  the inode. O_APPEND makes the post-truncate writes
#                  land at offset 0 — no null-padding. The race window
#                  (lines written between cp and truncate are dropped)
#                  loses at most a few telemetry lines.
#
# Silent no-op when the file is missing, the cap is 0/non-numeric, or
# the size is under the cap.
_prune_rotate_if_oversized() {
    local path="$1" cap="$2" mode="${3:-rename}"
    [[ -f "$path" ]] || return 0
    [[ "$cap" =~ ^[0-9]+$ ]] || return 0
    (( cap > 0 )) || return 0
    local size
    size=$(stat -c '%s' "$path" 2>/dev/null || stat -f '%z' "$path" 2>/dev/null || echo 0)
    [[ "$size" =~ ^[0-9]+$ ]] || return 0
    (( size >= cap )) || return 0
    local archive="${path}.$(date +%s)"
    if [[ "$mode" == "copytruncate" ]]; then
        cp "$path" "$archive" 2>/dev/null || return 0
        : > "$path" 2>/dev/null || true
    else
        mv -f "$path" "$archive" 2>/dev/null || return 0
    fi
    log "rotated $(basename "$path") ($(( size / 1048576 )) MiB >= cap) -> $(basename "$archive")"
    local retention="${RETENTION_DAYS:-7}"
    [[ "$retention" =~ ^[0-9]+$ ]] || retention=7
    find "$(dirname "$path")" -maxdepth 1 -type f \
        -name "$(basename "$path").*" \
        -mtime "+$retention" -delete 2>/dev/null || true
}

# Bound the append-only processed-comments.txt 👀/🚀-ack cache
# (your-org/nexus-code#360). It has NO built-in pruning and grows one line
# per bot reaction forever. The cache is only a propagation-lag / cadence
# bridge over the LIVE reaction query that is the real source of truth
# (snapshot_github GraphQL + the re-emit registry recheck); an entry for a
# comment reacted-on long ago is dead weight — the 600s snapshot has long
# since re-seen the reaction. Retain the most recent N entries: the file is
# append-ordered (newest at the tail), so `tail -N` is BOTH the bound AND the
# correct keep-newest policy, with NO format change so every awk/grep reader
# stays untouched. 0 disables. Atomic tmp+mv.
_prune_processed_comments() {
    local f="${STATE_DIR}/processed-comments.txt"
    local cap="${MONITOR_PROCESSED_COMMENTS_MAX_ENTRIES:-2000}"
    [[ "$cap" =~ ^[0-9]+$ ]] || return 0
    (( cap > 0 )) || return 0
    [[ -f "$f" ]] || return 0
    local n
    n=$(wc -l < "$f" 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || return 0
    (( n > cap )) || return 0
    local tmp="${f}.prune.$$"
    if tail -n "$cap" "$f" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
        log "pruned processed-comments.txt ($n -> $cap entries)"
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
}

# Bounded, NAME-based prune of the emit-archive dir (DIFF_DIR).
# your-org/nexus-code#402: the previous `find -mtime` sweep stat-scanned
# EVERY file to test age, so its cost was O(total files) — on a 13,933-
# file NFS dir it took ~12 min (scheduler telemetry: prune_archive
# rc=0 elapsed_ms=715897). Because prune_archive runs in the SYNC phase
# it blocked the scheduler's heartbeat refresh past the staleness
# threshold → supervisor false-positive "watcher DOWN" → revive churn
# (crash-loop 2026-07-01).
#
# The archive filenames embed a lexically-sortable UTC timestamp
# (`archive_emit`: `%Y-%m-%d_%H-%M-%S_<id>.md`), so we prune by NAME:
# one readdir (no per-file stat) + a string compare per entry. Two
# bounds keep a single run cheap regardless of dir size:
#   * age  — delete entries whose embedded date is older than
#            RETENTION_DAYS (preserves the prior -mtime semantics; these
#            files are cp'd once and never re-touched, so name-date ==
#            mtime-date). Enumerated oldest-first, so the scan stops at
#            the first in-retention entry.
#   * count cap (MONITOR_DIFF_MAX_FILES) — force-delete the OLDEST
#            entries beyond the cap so a high emit-rate burst can't grow
#            the dir without bound between age boundaries.
# At most MONITOR_DIFF_PRUNE_MAX_PER_RUN deletions per run; a backlog
# drains over subsequent 600 s runs, never in one long sync sweep.
_prune_diffs_bounded() {
    local dir="$1" retention_days="$2" max_files="$3" max_per_run="$4"
    [[ -d "$dir" ]] || return 0
    [[ "$retention_days" =~ ^[0-9]+$ ]] && (( retention_days > 0 )) || return 0

    # Age cutoff as a comparable YYYYMMDD integer from the filename date.
    local cutoff cutoff_num
    cutoff=$(date -u -d "-${retention_days} days" +%Y%m%d 2>/dev/null) || return 0
    cutoff_num=$((10#$cutoff))

    # Enumerate names ONLY, oldest-first. Bash pathname expansion reads
    # the directory and matches names — NO per-file stat (unlike
    # `find -mtime`, whose stat-per-file cost was the wedge) — and
    # returns them collation-sorted. LC_ALL=C forces byte-order sort so
    # the sortable-ts filenames come out chronological regardless of the
    # ambient locale. `local LC_ALL` re-runs setlocale for this frame
    # only. nullglob so an empty dir yields no literal-pattern entry.
    local LC_ALL=C
    local files=() f
    local _restore_nullglob
    _restore_nullglob=$(shopt -p nullglob)
    shopt -s nullglob
    files=( "$dir"/*.md )
    eval "$_restore_nullglob"

    local total=${#files[@]}
    (( total > 0 )) || return 0
    local over=$(( total - max_files ))
    (( max_files > 0 )) || over=0        # 0 disables the count cap
    (( over < 0 )) && over=0

    local deleted=0 idx name namedate del
    for (( idx = 0; idx < total; idx++ )); do
        (( max_per_run > 0 && deleted >= max_per_run )) && break
        f="${files[idx]}"
        name="${f##*/}"
        del=0
        if (( idx < over )); then
            del=1                        # over the count cap → oldest go
        else
            namedate="${name:0:10}"      # YYYY-MM-DD
            if [[ "$namedate" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                if (( 10#${namedate//-/} < cutoff_num )); then
                    del=1                # older than RETENTION_DAYS
                else
                    break                # sorted asc → all remaining are newer
                fi
            fi
            # A non-conforming name (no date prefix) is left in place.
        fi
        if (( del )); then
            rm -f -- "$f" 2>/dev/null && deleted=$(( deleted + 1 ))
        fi
    done

    if (( deleted > 0 )); then
        local remaining=$(( total - deleted ))
        log "prune_diffs: deleted $deleted archive(s) (age>${retention_days}d / over cap ${max_files}); ${remaining} remain"
    fi
}

# Prune the emit-archive dir (bounded, name-based — see
# `_prune_diffs_bounded`). Guard against unbounded retention (-1/0) and
# a completely missing dir.
#
# Also prunes the per-comment emit-history directory written by
# `_filter_emit_cooldown`. Entries older than
# `MONITOR_EMIT_HISTORY_RETENTION_SECONDS` (default 24h) are removed.
# Same cheap `-mmin` discipline (emit-history is small, so a stat scan
# there is bounded by the cooldown horizon, not the archive volume).
#
# And rotates the unbounded append-only telemetry files (issue 180
# R2) via `_prune_rotate_if_oversized` above — the scheduler JSONL on
# its own (larger) cap, the slower-growing logs on the shared
# state-log cap. watcher.log is copytruncate (see helper docstring).
prune_archive() {
    _prune_diffs_bounded "$DIFF_DIR" "$RETENTION_DAYS" \
        "${MONITOR_DIFF_MAX_FILES:-20000}" "${MONITOR_DIFF_PRUNE_MAX_PER_RUN:-5000}"
    local hist_dir="${STATE_DIR}/emit-history"
    local horizon="${MONITOR_EMIT_HISTORY_RETENTION_SECONDS:-86400}"
    if [[ "$horizon" =~ ^[0-9]+$ ]] && (( horizon > 0 )) && [[ -d "$hist_dir" ]]; then
        # `-mmin +N` is minute-granularity; convert seconds to minutes
        # with ceiling so a 90 s retention doesn't silently round down
        # to "delete everything older than 1 min" (which would defeat
        # very-short cooldown configs operators might use during
        # debug). For the default 86400 (24h) this is exactly 1440 min.
        local mmin=$(( (horizon + 59) / 60 ))
        find "$hist_dir" -maxdepth 1 -type f -name 'comment-*.meta' \
            -mmin "+${mmin}" -delete 2>/dev/null || true
    fi
    # Mirror the sweep for `_filter_reemit_backoff`'s per-mention stamp dir
    # (`reemit-backoff/comment-<id>.ts`). It parallels emit-history — one tiny
    # epoch file per unique cross-repo mention id — so GC it on the same
    # horizon to avoid unbounded inode growth (a stamp older than the horizon
    # is far past any re-emit backoff window and inert).
    local backoff_dir="${STATE_DIR}/reemit-backoff"
    if [[ "$horizon" =~ ^[0-9]+$ ]] && (( horizon > 0 )) && [[ -d "$backoff_dir" ]]; then
        local bmmin=$(( (horizon + 59) / 60 ))
        find "$backoff_dir" -maxdepth 1 -type f -name 'comment-*.ts' \
            -mmin "+${bmmin}" -delete 2>/dev/null || true
    fi
    # Telemetry-file rotation (issue 180 R2). The scheduler JSONL is
    # the fast grower (one row per fire at 2-5 s cadences); the rest
    # share the smaller state-log cap. watcher.log MUST stay
    # copytruncate — the launcher's redirect holds a long-lived
    # O_APPEND fd on its inode (see _prune_rotate_if_oversized).
    _prune_rotate_if_oversized "${MONITOR_SCHEDULER_LOG:-${STATE_DIR}/watcher-scheduler.jsonl}" \
        "$MONITOR_SCHEDULER_LOG_MAX_BYTES" rename
    _prune_rotate_if_oversized "$LOGFILE" \
        "$MONITOR_STATE_LOG_MAX_BYTES" copytruncate
    _prune_rotate_if_oversized "$FUNCTIONAL_CHECK_STATE_FILE" \
        "$MONITOR_STATE_LOG_MAX_BYTES" rename
    _prune_rotate_if_oversized "$ACTION_LOG" \
        "$MONITOR_STATE_LOG_MAX_BYTES" rename
    _prune_processed_comments
}

# Auto-unstick helpers (detect_and_unstick + friends). See _unstick.sh
# header for the case-A / case-B narrative and the asymmetry rationale.
# Required globals (AUTO_UNSTICK, UNSTICK_DIR, UNSTICK_LOG,
# WATCHER_WINDOW) are set above.
# shellcheck source=_unstick.sh
source "$_script_dir/_unstick.sh"

# Idle-worker probe (tmux window_activity + pane-state.sh). See
# _idle_probe.sh for the state machine and dedupe contract.
# shellcheck source=_idle_probe.sh
source "$_script_dir/_idle_probe.sh"

# Over-limit wake-scheduler (issue #87). Sourced AFTER _idle_probe.sh
# so its `_over_limit_scan_panes` can reuse `_idle_list_worker_windows`
# for the reserved-name filter. Functions only; no side effects on
# source.
# shellcheck source=_over_limit.sh
source "$_script_dir/_over_limit.sh"

# Orchestrator-liveness state machine (issue #164). Replaces the
# binary unresponsive_age > threshold check from #157 with a
# three-knob model that distinguishes idle-but-healthy from
# stuck-or-dead. Functions only; no side effects on source.
# shellcheck source=_orchestrator_liveness.sh
source "$_script_dir/_orchestrator_liveness.sh"

# Functional-check signal (other-nexus-lessons L1). Orthogonal to the
# orchestrator-liveness state machine: pid/heartbeat/paste-receipt
# can all be healthy while the orchestrator quietly fails to issue
# `gh api reactions` writes against surfaced eligible comments.
# Functions only; no side effects on source.
# shellcheck source=_functional_check.sh
source "$_script_dir/_functional_check.sh"

# Claude Code update-detection (GATED self-update, detect→inform half).
# Compares the package.json pin against the npm `latest` dist-tag and
# maintains monitor/.state/cc-update-available; the emit surfaces it
# once per candidate. NEVER auto-bumps. Functions only; no side effects
# on source.
# shellcheck source=_cc_update.sh
source "$_script_dir/_cc_update.sh"

# Autonomous daily cc-update routine (the DRIVE half closing the gated
# loop; your-org/your-nexus#207). Fires once per calendar day at the
# configured time, re-checks the registry, and spawns the autonomous
# evaluator worker that runs the GUIDE flow — bumping only behind gate
# evidence via monitor/cc-auto-update-apply.sh. Registered only when
# the operator enables it. Functions only; no side effects on source.
# shellcheck source=_cc_auto_update.sh
source "$_script_dir/_cc_auto_update.sh"

# Version-aware component restart (your-org/your-nexus#186). Per-
# component source-set hashing + drift state machine + restart
# orchestration: watcher self-restart via launcher --replace, cockpit
# restart ASK via the emit, registered-service restart via svc.sh.
# Makes `git pull` the whole nexus-code update story. Functions only;
# no side effects on source.
# shellcheck source=_version_restart.sh
source "$_script_dir/_version_restart.sh"

# Continuous service-health watch (service-health-watch). Defines
# `_service_health_check_tick` (the service_health task body) and
# `_service_health_emit_section` (consumed by compose_emit). Functions
# only; NO `source` of bootstrap-recover.sh at load time (it redefines
# log() + run-mode globals) — the restart action shells out to svc.sh.
# shellcheck source=_service_health.sh
source "$_script_dir/_service_health.sh"

# Effective Claude Code version resolver (floor-plus-local-pin scheme,
# your-org/nexus-code#226). Provides cc_version_effective — the gate
# baseline (_v2_task_cc_version_check) compares the registry `latest`
# against the EFFECTIVE version (operator-local pin if present, else the
# shared package.json floor), NOT the lagging floor alone. Lives one dir
# up (monitor/), shared with install-claude-local.sh. Functions only.
# shellcheck source=../_cc-version.sh
source "$_script_dir/../_cc-version.sh"

# v2 scheduler module (issue #169). Defines `_schedule_task`,
# `_scheduler_tick`, `_scheduler_sleep_until_next`, etc. Functions
# only; no side effects on source.
# shellcheck source=_scheduler.sh
source "$_script_dir/_scheduler.sh"

# Compose-emit nudge hook. Defines `_compose_emit_nudge_check`, which
# watches `deliveries-queue.lines` and `github_poll.out` mtimes and
# pulls compose_emit forward via `_schedule_fire_now` + 5/60 override
# when new bytes arrive. Wired into `_scheduler_post_tick_hook` below
# so every scheduler tick consults it.
# shellcheck source=_compose_nudge.sh
source "$_script_dir/_compose_nudge.sh"
# Telemetry sink: every fire writes one JSONL row here. Path
# placement matches the existing `monitor/.state/watcher-*.jsonl`
# family so log-rotation tooling sees it without special-casing.
: "${MONITOR_SCHEDULER_LOG:=${STATE_DIR}/watcher-scheduler.jsonl}"
export MONITOR_SCHEDULER_MAX_SLEEP MONITOR_SCHEDULER_LOG \
       MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR

# Wire the helper's log + paste contracts into watcher infrastructure.
# `log` prints to stderr (the launcher redirect lands it in LOGFILE);
# `paste_with_retry` is the same paste-+-content-verify path routine
# emits take.
_over_limit_log_to_watcher() { log "$@"; }
_over_limit_paste_via_watcher() {
    local window="$1" body_file="$2"
    paste_with_retry "$window" "$body_file"
}
_OVER_LIMIT_LOG_FN=_over_limit_log_to_watcher
_OVER_LIMIT_PASTE_FN=_over_limit_paste_via_watcher
export _OVER_LIMIT_LOG_FN _OVER_LIMIT_PASTE_FN

# ---- main loop -----------------------------------------------------------

tmp_dir=$(mktemp -d)
trap '_stop_heartbeat_ticker; release_pidfile; release_lock; release_instance_lock; rm -rf "${tmp_dir}"' EXIT
# Startup-window signal semantics (issue #405 post-review, B1). Bash
# RESUMES execution after a non-exiting signal trap, so hanging the
# release chain directly on INT/TERM let a signal landing in the
# startup window — after acquire_instance_lock below but before
# _scheduler_install_signal_handlers replaces these handlers with the
# cooperative shutdown flag — run every release (flock dropped, cross-
# host beacon deleted, pidfile removed, tmp_dir rm'd) and then CONTINUE
# starting up as a fully unguarded instance: a second cockpit could
# acquire the "freed" flock and coexist (double GitHub writes). So:
# log-then-exit, same pattern as the HUP trap below; the EXIT trap
# carries the cleanup exactly once (no double-release — the release fns
# are idempotent and the signal handler itself releases nothing). Once
# the scheduler installs its own INT/TERM handlers these two are gone
# and shutdown is cooperative (flag → loop break → exit 0 → EXIT trap),
# exactly as before.
trap 'log "watcher exiting on SIGINT during startup (scheduler handlers not yet installed)"; exit 130' INT
trap 'log "watcher exiting on SIGTERM during startup (scheduler handlers not yet installed)"; exit 143' TERM
# Forensic attribution (2026-06-02 incident). Headless (setsid) the
# watcher no longer gets HUP'd by window kills, but a stray HUP (e.g.
# a legacy windowed instance during migration, or controlling-terminal
# teardown on a manual foreground run) would — untrapped — die without
# running the EXIT trap, leaving a clean log tail indistinguishable
# post-hoc from a silent crash. Trap it: log the cause, then exit so
# the EXIT trap still releases the pidfile/lock instead of lingering
# as a PPID=1 orphan (issue #106).
trap 'log "watcher exiting on SIGHUP (host terminal/window went away)"; exit 129' HUP
current="${tmp_dir}/current"
emit_body="${tmp_dir}/emit.md"

# Self-heal the per-process scratch dir (nexus-code#236).
#
# `tmp_dir` is created ONCE via `mktemp -d` at startup, but the watcher
# is a long-lived process (days of uptime). On a host whose /tmp is
# swept by a periodic reaper (systemd-tmpfiles, tmpwatch — common on
# shared HPC), the directory can be deleted out from under the still-
# running process once its files age past the reaper's threshold. That
# is precisely what wedged the live watcher on 2026-06-18: `tmp_dir`
# vanished after ~10 h, every `_v2_task_compose_emit` fire then failed
# its first `cp "$local_snapshot" "$current_tmp"` and `return 0`'d, so
# the SOLE deliveries-queue drainer and orchestrator-paste path silently
# no-op'd for ~hour — and nexus-code#310/#311 (queued, never drained)
# never surfaced. compose_emit logged nothing; the wedge was invisible.
#
# Guard: recreate `tmp_dir` if it has gone missing, and surface a
# throttled WARN so a recurrence is diagnosable instead of silent. The
# directory holds only ephemeral scratch (emit.md, compose-current,
# diff) — no durable state — so recreating it is always safe. Called at
# the top of every emit-composing path.
_ensure_watcher_tmp_dir() {
    [[ -d "$tmp_dir" ]] && return 0
    mkdir -p "$tmp_dir" 2>/dev/null || true
    local alerts="${STATE_DIR}/watcher-alerts.log"
    local marker="${STATE_DIR}/.tmp-dir-reaped-warned"
    local now last=0
    now=$(date +%s)
    [[ -f "$marker" ]] && last=$(<"$marker")
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if (( now - last >= 600 )); then
        local iso; iso=$(date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
        _ensure_service_log "$alerts"
        printf '[%s] WARN watcher scratch dir %s was missing (likely /tmp reaper on a long-lived process) — recreated; emit path self-healed. Consider a tmp reaper exclusion or a longer retention for the watcher uid.\n' \
            "$iso" "$tmp_dir" >> "$alerts" 2>/dev/null || true
        printf '%s\n' "$now" > "$marker" 2>/dev/null || true
        log "watcher scratch dir was reaped; recreated $tmp_dir (emit path self-healed)"
    fi
    return 0
}

# Cross-namespace/cross-host singleton gate FIRST (refuses loudly and
# exits 4 if a peer cockpit already owns this state dir), then the
# legacy same-namespace pid lock as belt-and-suspenders.
acquire_instance_lock
acquire_lock
bump_heartbeat
# Liveness/progress split (nexus-code#491): re-anchor the cycle clock
# (preserving the learned period ema), stamp first progress, and start
# the constant-cadence liveness ticker — AFTER the instance lock, so a
# doomed second watcher never beats the real one's heartbeat. From here
# on the heartbeat stays fresh through arbitrarily long sweeps; the
# 13.5-minute startup sweep measured at 15 workers can no longer read
# as a dead watcher.
_cycle_reset
_progress_bump startup
if (( ONCE == 0 )); then
    _start_heartbeat_ticker
fi
# Persist the target so `ng watcher-status` can report it even on
# crashes before the first emit.
printf '%s\n' "$TARGET" > "$TARGET_FILE"

# Record THIS process's running source-set hash (issue #186). Right
# here — after every `source` above completed and before the loop —
# the on-disk source set IS what this process is running, so the hash
# is the exact running version the version_check task compares against.
# Failure is benign (first check adopts the on-disk hash instead).
if [[ "$MONITOR_VERSION_RESTART_ENABLED" == "true" ]]; then
    if _self_version=$(_version_startup_record "$VERSION_STATE_DIR" "$_script_dir/main.sh"); then
        log "version: recorded running watcher source-set hash ${_self_version:0:12}"
    else
        log "version: startup self-hash failed; first version_check will adopt the on-disk hash"
    fi
    unset _self_version
fi

# Initialise persistent baseline if missing (first ever run).
if [[ ! -f "${BASELINE}" ]]; then
    if ! snapshot_local > "${BASELINE}"; then
        log "initial snapshot failed"
        exit 1
    fi
    log "initialised persistent baseline at ${BASELINE}"
fi

log "watcher up: repo=${REPO} user=${USER_LOGIN} target=${TARGET} interval=${INTERVAL}s retention=${RETENTION_DAYS}d dead_threshold=${AGENT_DEAD_THRESHOLD} missing_respawn_delay=${AGENT_MISSING_RESPAWN_DELAY} respawn_loop=${RESPAWN_LOOP_LIMIT}/${RESPAWN_LOOP_WINDOW}s respawn_consec_limit=${RESPAWN_CONSEC_LIMIT} slow_grind_cooldown=${RESPAWN_SLOW_GRIND_COOLDOWN}s auto_unstick=${AUTO_UNSTICK} on_dialog=${ON_DIALOG} worker_askuq_grace_s=${MONITOR_WORKER_ASKUQ_GRACE_SECONDS} ratelimit_probe=${RATELIMIT_PROBE} probe_key=$([[ -n "${ANTHROPIC_API_KEY:-}" ]] && echo set || echo unset) api_error_backoff_min=${API_ERROR_BACKOFF_MIN} deliveries=(asset=${DELIVERIES_ASSET_ENABLED} bot_mention=${DELIVERIES_BOT_MENTION_ENABLED} connect=${DELIVERIES_CONNECT_TIMEOUT}s max=${DELIVERIES_MAX_TIME}s fetch_cap=${DELIVERIES_MAX_FETCH_PER_CYCLE} seed_first=${DELIVERIES_SEED_ON_FIRST_RUN}) mentions_enabled=${MENTIONS_ENABLED} bot_mentions_enabled=${BOT_MENTIONS_ENABLED}(connect=${MENTIONS_CONNECT_TIMEOUT}s max=${MENTIONS_MAX_TIME}s) graphql_threshold=${GRAPHQL_THRESHOLD} cross_repo_surface=${CROSS_REPO_SURFACE} bot_login=${BOT_LOGIN:-<unset>} orch_fresh_spawn=${ORCH_FRESH_SPAWN_ENABLED} orch_paste_response_grace_s=${ORCH_PASTE_RESPONSE_GRACE_S} orch_unstick_window_s=${ORCH_UNSTICK_WINDOW_S} orch_dead_threshold_s=${ORCH_DEAD_THRESHOLD_S} orch_stale_paste_ceiling_s=${ORCH_STALE_PASTE_CEILING_S} orch_liveness_log_throttle_s=${ORCH_LIVENESS_LOG_THROTTLE_S} orch_stale_s=${ORCH_STALE_SECONDS} orch_fresh_spawn_cooldown_s=${ORCH_FRESH_SPAWN_COOLDOWN_SECONDS} version_restart=${MONITOR_VERSION_RESTART_ENABLED}/${MONITOR_VERSION_CHECK_INTERVAL_SECONDS}s(settle=${MONITOR_VERSION_SETTLE_SECONDS}s cooldown=${MONITOR_VERSION_RESTART_COOLDOWN_SECONDS}s self=${MONITOR_VERSION_SELF_RESTART} services=${MONITOR_VERSION_SERVICE_RESTART})"
if [[ -n "${MONITOR_ORCH_UNRESPONSIVE_THRESHOLD_S:-}" ]]; then
    log "DEPRECATED: MONITOR_ORCH_UNRESPONSIVE_THRESHOLD_S=${MONITOR_ORCH_UNRESPONSIVE_THRESHOLD_S} seeded the new MONITOR_ORCH_DEAD_THRESHOLD_S; rename to MONITOR_ORCH_DEAD_THRESHOLD_S (or set monitor.watcher.orchestrator_dead_threshold_seconds) — legacy var removed in a future release."
fi

# Structural coherence — ENFORCED, not merely warned (2026-06-15 incident).
# On a static workspace the only guaranteed paste is the full-state
# TIMEOUT HEARTBEAT: the canonical identity check (issue #104) suppresses
# unchanged cadence emits until the safety floor expires, so the maximum
# gap between compose_emit pastes is the floor rounded UP to the next
# cadence tick, plus one loop tick:
#
#   heartbeat = ceil(safety_floor / full_state_emit_interval)
#                 * full_state_emit_interval        (floor > interval)
#             = full_state_emit_interval             (floor <= interval)
#   max gap   = heartbeat + loop_interval
#
# (Defaults: ceil(900/600)*600 = 1200s heartbeat → 1260s gap.) If
# dead_threshold is below that gap, last_paste_ts can age past the
# deadline before the next paste resets it, producing a false-positive
# respawn of a healthy idle orchestrator. We eliminate the race at the
# SOURCE by clamping the effective dead_threshold up to (gap + margin), so
# a static-workspace heartbeat always resets the clock before the
# deadline. This makes the false positive structurally impossible; the
# bounded idle-pane guard below remains only as defense-in-depth for
# residual misfires (e.g. compose_emit starvation). The clamp preserves
# the load-bearing invariant dead_threshold < stale_paste_ceiling; if it
# can't (the gap itself is near the ceiling), it declines to clamp and
# warns — which is why the safety-floor DEFAULT (900s, _config.sh) is
# sized to keep gap + margin comfortably under the 1800s ceiling.
# Runs BEFORE the knob-ordering check below so that check sees the
# effective (clamped) deadline and won't false-alarm about an ordering the
# clamp has already resolved.
#
# Adaptive-idle-backoff note (emit/exemption fidelity): the clamp uses the
# BASE safety_floor, so its arithmetic is unchanged. The backoff only
# STRETCHES the heartbeat gap during sustained no-change idle (up to
# idle_backoff_max_seconds). A stretched gap makes pastes RARER, never more
# frequent, so it cannot manufacture a false-positive respawn: the
# dead-threshold probe requires a paste NEWER than stale_paste_ceiling
# (1800s) to fire, and once the stretched heartbeat lets the last paste age
# past the ceiling the probe treats the workspace as idle (not wedged) and
# stands down until the next heartbeat re-arms it. The only trade is
# slightly slower wedge DETECTION on a deep-idle night — the deliberate
# quiet-night behaviour the operator asked for.
_orch_hb_interval=$MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS
if (( MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS > 0 )) \
   && (( MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS > MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS )); then
    _orch_hb_interval=$(( ( (MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS + MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS - 1) \
        / MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS ) * MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS ))
fi
_orch_paste_gap=$(( _orch_hb_interval + INTERVAL ))
_orch_eff_dead=$(_orchestrator_effective_dead_threshold \
    "$ORCH_DEAD_THRESHOLD_S" "$_orch_hb_interval" \
    "$INTERVAL" "$ORCH_DEAD_THRESHOLD_FLOOR_MARGIN_S" "$ORCH_STALE_PASTE_CEILING_S")
if (( _orch_eff_dead != ORCH_DEAD_THRESHOLD_S )); then
    log "orchestrator-liveness: dead_threshold (${ORCH_DEAD_THRESHOLD_S}s) <= max compose_emit gap (full-state heartbeat ${_orch_hb_interval}s [ceil(safety_floor ${MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS}s / full_state_emit_interval ${MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS}s) ticks] + loop_interval ${INTERVAL}s = ${_orch_paste_gap}s) — clamping effective dead_threshold up to ${_orch_eff_dead}s (gap + margin ${ORCH_DEAD_THRESHOLD_FLOOR_MARGIN_S}s) to eliminate the static-workspace false-positive respawn race at the source. Set monitor.full_state.safety_floor_seconds / monitor.full_state_emit_interval_seconds lower or orchestrator_dead_threshold_seconds higher to pick your own value; the real wedge detector (waiting -> unstick -> one-shot re-submit -> resubmit-failed respawn) fires at grace+unstick (~270-390s) regardless and is unaffected."
    ORCH_DEAD_THRESHOLD_S=$_orch_eff_dead
elif (( _orch_paste_gap >= ORCH_DEAD_THRESHOLD_S )); then
    log "WARN orchestrator-liveness: cannot clamp dead_threshold above the compose_emit gap (${_orch_paste_gap}s = full-state heartbeat ${_orch_hb_interval}s + loop_interval ${INTERVAL}s) without crossing stale_paste_ceiling (${ORCH_STALE_PASTE_CEILING_S}s) — leaving dead_threshold=${ORCH_DEAD_THRESHOLD_S}s and relying on the bounded idle-pane guard. Lower monitor.full_state.safety_floor_seconds / monitor.full_state_emit_interval_seconds, or raise monitor.watcher.stale_paste_ceiling_seconds, to close the race at the source."
fi

# Liveness-knob ordering sanity check. The re-submit rescue fires at
# the unstick-window-exhaustion boundary (grace + unstick_window after
# the paste); for it to ever run before the unconditional dead
# threshold, grace + unstick_window must stay strictly below
# dead_threshold. A misordered config silently degrades to "respawn
# without rescue" — surface that at startup instead of letting the
# operator discover it from a lost orchestrator session. Evaluated on the
# effective (post-clamp) dead_threshold.
if (( ORCH_PASTE_RESPONSE_GRACE_S + ORCH_UNSTICK_WINDOW_S >= ORCH_DEAD_THRESHOLD_S )); then
    log "WARN orchestrator-liveness knobs misordered: grace (${ORCH_PASTE_RESPONSE_GRACE_S}) + unstick_window (${ORCH_UNSTICK_WINDOW_S}) >= dead_threshold (${ORCH_DEAD_THRESHOLD_S}); the re-submit rescue will never fire before the dead-threshold respawn. Lower grace/unstick_window or raise orchestrator_dead_threshold_seconds."
fi

# Validate the cross-repo gate's config combination once at startup.
# `mention_only` (the default) requires a configured `github.bot_login`
# to match the body `@`-token; with no bot login the gate degrades to
# `off` and silently drops every cross-repo event. The operator almost
# certainly wants either to set `github.bot_login` or to switch
# `monitor.cross_repo_surface` to `author_only` explicitly.
if [[ "$CROSS_REPO_SURFACE" == "mention_only" && -z "$BOT_LOGIN" ]]; then
    log "WARN monitor.cross_repo_surface=mention_only but github.bot_login is empty; cross-repo events will be dropped. Set github.bot_login (the App slug without [bot]) or switch monitor.cross_repo_surface to author_only."
fi
case "$CROSS_REPO_SURFACE" in
    mention_only|author_only|off) ;;
    *) log "WARN monitor.cross_repo_surface=${CROSS_REPO_SURFACE} is not a recognised mode; falling back to mention_only" ;;
esac

# Bot-mention channel is default-ON (2026-06-23) but needs a configured
# `github.bot_login` to know which `@<handle>` to search for. With no bot
# identity, `snapshot_bot_mentions` degrades to a clean per-cycle no-op
# (it returns before issuing any search — the empty-handle query is never
# sent). Surface that ONCE here at startup so an operator who hasn't set a
# bot identity understands why the channel is silent, without spamming the
# log every poll cycle. Not an error: the no-op is the correct, safe
# behaviour, not a misconfiguration the watcher must refuse to start on.
if [[ "$BOT_MENTIONS_ENABLED" == "true" && -z "$BOT_LOGIN" ]]; then
    log "WARN monitor.bot_mentions_enabled is on (the default) but github.bot_login is empty; the @bot-mention channel is a no-op until a bot identity is set. Set github.bot_login (the App slug without [bot]), or set monitor.bot_mentions_enabled: false to silence this."
fi

# Consecutive POLL cycles where the target tmux window is missing.
# Counted per poll (not per emit) so a quiet workspace + dead
# orchestrator still recovers — incremented at the top of every loop
# iteration via _target_window_present. Crosses
# AGENT_MISSING_RESPAWN_DELAY -> respawn_agent fires (fast path),
# counter resets. AGENT_DEAD_THRESHOLD is reserved for a separate
# (not yet wired) "window present, agent silent" detector.
# missing_target_since anchors the streak's first absent observation
# (epoch) so the pre-launch re-verify can compare orchestrator
# liveness signals against it (see _target_absent.sh).
missing_target_polls=0
missing_target_since=0

# Watcher-start anchor for the orchestrator-liveness probe. The probe
# treats `max(pin_mtime, WATCHER_START_TS)` as the last-known-healthy
# anchor — without this, a fresh install with no pin file would look
# infinitely stale and the probe would fire on its first cycle. We
# also advance this on successful fresh-spawn so the next cycle gives
# the newly-spawned claude a clean grace window to write its first pin.
WATCHER_START_TS=$(date +%s)

# Startup sweep: honour any eligible comments, standing bells, or
# idle-worker transitions present at launch. Always signal (no
# local diff to classify), so it pastes unconditionally. The idle
# probe's dedupe state file persists across watcher restarts, so a
# worker that was idle pre-restart and is still idle now produces
# no transition (no emit) — only a worker whose state changed
# since the last live cycle gets surfaced.
#
# Issue #72 D4: ALWAYS include a workspace-snapshot section on the
# startup sweep so the resuming orchestrator sees the cumulative
# state of all worker windows even if nothing transitioned.
#
# Progress-logging note (issue #162): each call below can take
# multiple seconds (especially the github raw call's three GraphQL
# queries), so we bracket them with short `log` lines. Without them
# the watcher pane sits silent for tens of seconds between
# `watcher up:` and the first `startup-sweep archive=…`, which
# operators reasonably read as a hang.
log "startup-sweep start"
log "snapshot-github start"
gh_now=$(
    {
        _snapshot_deliveries_raw
        _snapshot_github_raw
    } | _gh_filter_dedup_pipeline
)
gh_lines=$(printf '%s' "$gh_now" | awk 'NF>0 && $1 !~ /^[[:space:]]*body:/ {n++} END {print n+0}')
log "snapshot-github done (eligible_lines=${gh_lines})"
_progress_bump startup:github-done
bell_now=$(list_bell_windows)
log "local-snapshot start"
# Bound the SYNCHRONOUS startup renders (nexus-code#236). Each probes worker
# panes / git worktrees and historically blocked loop entry unboundedly (the
# ~66 s startup stall that delayed the first emit). Wrap each in a wall-clock
# budget: past it, abort LOUDLY and continue with whatever partial render
# landed — a partial startup sweep that emits beats a full one that never does.
_startup_to="${MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS:-20}"
[[ "$_startup_to" =~ ^[0-9]+$ ]] || _startup_to=20
_sb_tmp="${tmp_dir}/startup-render.$$"
if _run_bounded "$_startup_to" "$_sb_tmp" render_idle_section; then
    idle_now=$(cat "$_sb_tmp" 2>/dev/null || true)
else
    idle_now=$(cat "$_sb_tmp" 2>/dev/null || true)
    log "WARN startup-sweep: render_idle_section exceeded ${_startup_to}s budget; using partial render (loop entry NOT blocked)"
fi
if _run_bounded "$_startup_to" "$_sb_tmp" render_pending_decisions; then
    pending_now=$(cat "$_sb_tmp" 2>/dev/null || true)
else
    pending_now=$(cat "$_sb_tmp" 2>/dev/null || true)
    log "WARN startup-sweep: render_pending_decisions exceeded ${_startup_to}s budget; using partial render (loop entry NOT blocked)"
fi
# Request inbox crash-recovery (agent-channel RFC §2.6, §6): re-surface
# every still-claimed request on watcher restart so a request filed (or
# claimed) before a crash is not lost. requests_poll_emit also claims any
# .new.md that arrived while the watcher was down. Inert when disabled.
requests_now=""
if _run_bounded "$_startup_to" "$_sb_tmp" requests_poll_emit; then
    requests_now=$(cat "$_sb_tmp" 2>/dev/null || true)
else
    requests_now=$(cat "$_sb_tmp" 2>/dev/null || true)
    log "WARN startup-sweep: requests_poll_emit exceeded ${_startup_to}s budget; using partial render (loop entry NOT blocked)"
fi
if _run_bounded "$_startup_to" "$_sb_tmp" render_full_state_snapshot; then
    startup_full_state=$(cat "$_sb_tmp" 2>/dev/null || true)
else
    startup_full_state=$(cat "$_sb_tmp" 2>/dev/null || true)
    log "WARN startup-sweep: render_full_state_snapshot exceeded ${_startup_to}s budget; using partial render (loop entry NOT blocked)"
fi
rm -f "$_sb_tmp" 2>/dev/null || true
startup_worker_n=$(_idle_list_worker_windows 2>/dev/null \
    | awk 'NF>0 && $1!="" {n++} END {print n+0}')
startup_report_n=$(find "${NEXUS_ROOT}/reports" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
log "local-snapshot done (workers=${startup_worker_n} reports=${startup_report_n})"
_progress_bump startup:local-done

# Local-claude install-failure surfacing. The watcher's launcher.sh
# attempts `monitor/install-claude-local.sh` if the project-local
# install is absent; on failure it writes a
# `local-claude-install-failed.<epoch>` flag containing the install
# stderr. We collect any such flags here, render them as an emit
# section, and delete them — so the failure shows up exactly once in
# the orchestrator's first paste. Spawn surfaces have a PATH fallback,
# so a failed install doesn't brick spawning, but the orchestrator
# should know it's running on the un-updateable system binary.
install_failure_now=""
install_failure_flags=$(find "$STATE_DIR" -maxdepth 1 -name 'local-claude-install-failed.*' -type f 2>/dev/null | sort)
if [[ -n "$install_failure_flags" ]]; then
    install_failure_now=$(
        printf 'Project-local Claude Code install failed at watcher startup.\n'
        printf 'Spawn surfaces are falling back to the system `claude` on PATH.\n\n'
        while IFS= read -r flag; do
            [[ -z "$flag" ]] && continue
            printf '[%s]\n' "$(basename "$flag")"
            cat -- "$flag"
            printf '\n'
        done <<< "$install_failure_flags"
        printf 'Retry manually: `%s/monitor/install-claude-local.sh`\n' "$NEXUS_ROOT"
        printf 'Spawned workers + the orchestrator will switch to the local binary on their NEXT spawn (current sessions stay on the system binary).\n'
    )
    while IFS= read -r flag; do
        [[ -n "$flag" ]] && rm -f "$flag"
    done <<< "$install_failure_flags"
    log "startup-sweep: local-claude install-failure flag(s) consumed and surfaced"
fi
# cc update-detection: surface a pending (unsurfaced) candidate on the
# first paste after a restart. The detection task's own first fire lands
# on a later tick; this picks up any signal already persisted from a
# prior run. Re-nag guarded (cc-update-surfaced) so an already-surfaced
# candidate stays quiet across restarts.
cc_update_now=$(_cc_update_emit_section "$STATE_DIR" 2>/dev/null || true)
[[ -n "$cc_update_now" ]] && log "startup-sweep: cc-update signal surfaced"
# Component-drift asks persisted by a prior run (issue #186): surface
# any unsurfaced drift-<comp> records on the first paste after a
# restart — e.g. a self-restart-guard trip or a cockpit ask whose emit
# never landed. Re-nag guarded per candidate hash, so already-surfaced
# records stay quiet across restarts.
version_drift_now=$(_version_emit_section "$VERSION_STATE_DIR" "$NEXUS_ROOT" 2>/dev/null || true)
[[ -n "$version_drift_now" ]] && log "startup-sweep: component-drift signal surfaced"
# Service-health incidents persisted by a prior run (service-health-watch):
# surface any unsurfaced down/recovering/flapping record on the first paste
# after a restart — e.g. a service that went down while the watcher was
# bouncing. Re-nag guarded, so already-surfaced records stay quiet.
service_health_now=$(_service_health_emit_section "$SERVICE_HEALTH_STATE_DIR" "$NEXUS_ROOT" 2>/dev/null || true)
[[ -n "$service_health_now" ]] && log "startup-sweep: service-health signal surfaced"
# Self-failure report (watcher-supervision). A crashed watcher cannot
# report its own death; the watcher-supervisor daemon leaves a
# `watcher-revived` marker when it restarts a dead watcher, and THIS
# (the revived watcher's first emit) surfaces + clears it. The marker is
# key=value (reason / downtime_estimate_s / detected_at / restarted_by).
watcher_revived_now=""
if [[ -f "$WATCHER_REVIVED_MARKER" ]]; then
    _wr_reason=$(awk -F= '$1=="reason"{sub(/^[^=]*=/,"");print;exit}' "$WATCHER_REVIVED_MARKER" 2>/dev/null)
    _wr_down=$(awk -F= '$1=="downtime_estimate_s"{print $2;exit}' "$WATCHER_REVIVED_MARKER" 2>/dev/null)
    _wr_at=$(awk -F= '$1=="detected_at"{sub(/^[^=]*=/,"");print;exit}' "$WATCHER_REVIVED_MARKER" 2>/dev/null)
    _wr_by=$(awk -F= '$1=="restarted_by"{print $2;exit}' "$WATCHER_REVIVED_MARKER" 2>/dev/null)
    watcher_revived_now=$(
        printf 'The watcher was DOWN and has been automatically revived by the %s.\n' "${_wr_by:-watcher-supervisor}"
        printf 'Detected: %s. Estimated downtime: ~%ss (%s).\n' "${_wr_at:-?}" "${_wr_down:-?}" "${_wr_reason:-not alive}"
        printf 'During the outage the watcher could not paste to the orchestrator, run the\n'
        printf 'orchestrator-liveness / service-health tasks, or surface GitHub comments — so\n'
        printf 'anything that needed the watcher in that window may have been missed. Sweep\n'
        printf 'for unattended GitHub comments / decisions and check the registered services.\n'
        printf 'If this recurs, inspect the cause: monitor/svc.sh logs watcher (and watcher-supervisor).\n'
    )
    rm -f "$WATCHER_REVIVED_MARKER" 2>/dev/null || true
    log "startup-sweep: watcher-revived self-failure report surfaced (downtime≈${_wr_down:-?}s)"
    unset _wr_reason _wr_down _wr_at _wr_by
fi
# Arm-watcher-supervisor reminder (mutual-liveness). A freshly-(re)started
# watcher almost always finds no fresh supervisor heartbeat — the
# orchestrator hasn't armed (or re-armed) its Monitor yet — so this nudge
# is exactly what a revived/booted watcher should surface. Standing
# condition; self-clears once the Monitor's first tick touches the
# heartbeat.
supervisor_arm_now=$(_supervisor_arm_emit_section "$WATCHER_SUPERVISOR_HEARTBEAT" \
    "${MONITOR_WATCHER_SUPERVISOR_HEARTBEAT_STALE_SECONDS:-90}" "$NEXUS_ROOT" 2>/dev/null || true)
[[ -n "$supervisor_arm_now" ]] && log "startup-sweep: arm-watcher-supervisor reminder surfaced"
# Auto-roll audit breadcrumb (your-org/nexus-code#447). The roll TASK fires
# on the first scheduler tick (after this sweep), so normally no notice exists
# yet here — but read+consume any notice a crash left un-surfaced between its
# write and the compose that would have shown it. One-shot, self-clearing.
reports_roll_now=$(_reports_roll_emit_section "$REPORTS_ROLL_NOTICE_FILE" 2>/dev/null || true)
[[ -n "$reports_roll_now" ]] && log "startup-sweep: reports auto-roll breadcrumb surfaced"
# Legacy-hosting migration notice (issue 182). The launcher's headless
# spawns carry WATCHER_WINDOW=headless; anything else means this
# watcher was started the pre-cutover way (window-hosted entry.sh,
# manual foreground run). Surface a one-time how-to-converge notice
# through the startup sweep and keep working normally — computed once
# per process start, so it can never nag on later cycles.
hosting_migration_now=""
if _hosting_is_legacy "${WATCHER_WINDOW:-}"; then
    hosting_migration_now=$(_hosting_render_migration_notice "$NEXUS_ROOT" "${WATCHER_WINDOW:-}")
    log "startup-sweep: legacy hosting detected (WATCHER_WINDOW='${WATCHER_WINDOW:-<unset>}'); surfacing one-time migration notice"
fi
# Compute the startup canonical so a successful paste can seed the
# identity-check cache (issue #104). Without seeding, the first
# cadence-due cycle post-startup would always emit (no cache file),
# even if nothing has changed since the startup sweep.
startup_canonical=""
if [[ -n "$startup_full_state" ]]; then
    # render_idle_prelude probes every worker pane via pane-state.sh
    # and can take several seconds per dozen windows; log before so
    # the pane shows motion (issue #162).
    log "startup-sweep canonical-check"
    _progress_bump startup:canonical-check
    startup_canonical_prelude=$(MONITOR_PRELUDE_DRY_RUN=1 render_idle_prelude 2>/dev/null || true)
    # Canonical form = the SHARED volatile strip (_emit_dedup.sh).
    # The old inline `sed 's/idle Ns/idle/'` only knew one age token;
    # renderers later grew `operator away Ns` / `interrupted NhNNm`
    # rows and the un-extended strip made every render unique,
    # silently defeating the issue-#104 identity check for weeks.
    startup_canonical=$(printf '%s\n---snapshot---\n%s' \
        "$startup_canonical_prelude" "$startup_full_state" \
        | _emit_volatile_strip)
fi
# NOTE: supervisor_arm_now is render-only (NOT in this gate) — a standing
# reminder rides on emits triggered by real signal; it never forces a
# quiet-workspace emit. watcher_revived_now IS in the gate (a one-shot
# self-failure report worth an emit on its own).
if [[ -n "$gh_now" || -n "$bell_now" || -n "$idle_now" || -n "$pending_now" || -n "$requests_now" || -n "$startup_full_state" || -n "$install_failure_now" || -n "$cc_update_now" || -n "$hosting_migration_now" || -n "$version_drift_now" || -n "$service_health_now" || -n "$watcher_revived_now" || -n "$reports_roll_now" ]]; then
    EMIT_SIG_NONCE=$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 6)
    # compose_report itself calls render_idle_prelude a second time;
    # bracket it explicitly so the pane shows progress (issue #162).
    log "startup-sweep composing emit"
    _progress_bump startup:composing-emit
    compose_report "startup-sweep" "" "$gh_now" "$bell_now" "$idle_now" "$startup_full_state" "$pending_now" "$install_failure_now" "$cc_update_now" "$hosting_migration_now" "$version_drift_now" "$service_health_now" "$watcher_revived_now" "$supervisor_arm_now" "$requests_now" "$reports_roll_now" > "$emit_body"
    _progress_bump startup:emit-composed
    cp "$emit_body" "$LAST_CHANGE"
    archive_path=$(archive_emit "$emit_body")
    log "startup-sweep archive=${archive_path}"
    # Same over-limit gate as the steady-state emit (see below). On
    # restart the watcher may find the orchestrator already stamped
    # suspended — pasting the startup sweep into an inert pane would
    # be lost. The archive is preserved either way.
    log "startup-sweep paste start (target=${TARGET})"
    if _over_limit_orchestrator_paused; then
        log "startup-sweep paste suppressed: orchestrator over-limit"
    elif paste_with_retry "$TARGET" "$emit_body"; then
        log "startup-sweep pasted to ${TARGET}"
        _emit_delivery_ok
        # Seed the dedup gate with this just-emitted body so the
        # first steady-state compose_emit post-restart can dedup
        # against a current anchor rather than a stale pre-restart
        # hash. The startup sweep is itself never gated — the
        # operator always sees the workspace on watcher restart.
        _compose_emit_record_emit "$emit_body"
        # Delivery-stamp the request ids this paste actually carried
        # (stamp-on-paste, your-org/nexus-code#483): the startup render
        # above deliberately wrote no cooldown rows, so a suppressed or
        # failed startup paste leaves every request due for the
        # steady-state loop.
        requests_commit_emitted "$emit_body"
        _respawn_loop_reset "$RESPAWN_HISTORY"
        rm -f "$RESPAWN_TRIPPED"
        # Successful paste = orchestrator reachable on both axes:
        # the burst-limit reset clears its sliding window; the
        # slow-grind reset clears the consecutive-failure counter
        # (issue #77) and any cooldown stamp.
        _respawn_consec_reset "$RESPAWN_CONSEC_COUNTER"
        rm -f "$RESPAWN_SLOW_GRIND_TRIPPED"
        date +%s > "$FULL_STATE_STAMP" 2>/dev/null || true
        # Seed the canonical cache (issue #104) so the first cadence
        # check post-startup compares against the startup emit's
        # state and suppresses if unchanged. Empty startup_canonical
        # (no workers at startup) skips the seed; the next cadence
        # cycle will emit + seed on its own.
        if [[ -n "$startup_canonical" ]]; then
            printf '%s' "$startup_canonical" > "${FULL_STATE_CANONICAL_CACHE}.tmp" \
                && mv "${FULL_STATE_CANONICAL_CACHE}.tmp" "$FULL_STATE_CANONICAL_CACHE" 2>/dev/null || true
        fi
    else
        rc=$?
        case $rc in
            1) log "startup-sweep: tmux not available; archive only" ;;
            2) log "startup-sweep: target window '${TARGET}' missing; archive only" ;;
            4) log "startup-sweep: paste submitted but signature not visible (VI mode?); archive only" ;;
            *) log "startup-sweep: paste failed (rc=$rc); archive only" ;;
        esac
        _emit_delivery_fail "$rc"
    fi
    if [[ -n "$bell_now" ]]; then
        clear_bells "$(printf '%s\n' "$bell_now" | awk -F'\t' '{print $1}')"
        snapshot_local > "${BASELINE}" 2>/dev/null || true
    fi
fi
# The startup sweep (a full correct cycle: snapshot → emit-decision →
# paste) has completed. Stamp the CYCLE signal — its first measured
# period is the sweep's real wall-clock cost, seeding the load-aware
# wedge/cycle cutoffs — plus progress, and bump the heartbeat (a belt
# alongside the #491 ticker; on --once runs it is the only bump).
_cycle_bump
_progress_bump startup:done
bump_heartbeat


# ---- scheduler entry point ----------------------------------------------
# Registers the priority-queue tasks and drives `_scheduler_tick` /
# `_scheduler_sleep_until_next` until SIGTERM.
#
# Task catalog. Data-gathering tasks write to staging files under
# `monitor/.state/scheduler-staging/<name>.out`; `compose_emit` reads
# those staging files and runs the emit-decision tree.
#
#   (heartbeat is NOT a task — bumped only at the end of a correct compose
#    cycle so it proves the loop works; see _v2_task_compose_emit. #236)
#   over_limit_wakes       @ 5s    sync   cheap     process due wakes
#   target_window          @ 2s    sync   cheap     probe + respawn trigger
#   orchestrator_liveness  @ 5s    sync   cheap     state machine; spawn forked
#   pending_decisions      @ 10s   sync   cheap     render_pending_decisions
#   bell_windows           @ 30s   sync   cheap     list_bell_windows
#   detect_unstick         @ 10s   async  medium    detect_and_unstick
#   snapshot_local         @ 30s   async  medium    snapshot_local
#   over_limit_scan        @ 60s   async  expensive _over_limit_scan_panes
#   idle_section           @ 30s   async  expensive render_idle_section
#   deliveries_poll        @ 15s   async  medium    snapshot_deliveries (webhook)
#   github_poll            @ 600s  async  expensive snapshot_github + mentions (GraphQL)
#   full_state_snap        @ 600s  async  expensive render_full_state_snapshot
#   version_check          @ 60s   async  medium    _version_check_tick (issue 186)
#   prune_archive          @ 600s  sync   cheap     prune_archive
#   compose_emit           @ INT   async  medium    reads staging, emits
#
# Cadence-critical sync probes are bounded by their helper's natural
# cost (≤ 100 ms each); compose_emit runs --async so its 5–20 s body
# never holds the scheduler's sync slot. target_window stays under
# 5 s gap during respawn/emit cycles even under heavy concurrent
# work (issue #172 / #179 cron-supervisor evidence).
#
# Event-fetch split (issue #181): the webhook surface
# (`/app/hook/deliveries`, App-JWT bucket) runs at the fast 15 s
# cadence as the primary event source; the GraphQL surface
# (`snapshot_github` + optional `snapshot_mentions`) backstops at
# 600 s on its separate-bucket fallback path. Webhook events are
# real-time and cross-repo by design; GraphQL is the catch-up for
# anything the webhook missed (App not installed, retention
# elapsed, etc.).
#
# Open-question resolutions:
#   §8.1 (catch-up):        long-running task re-fires next tick.
#   §8.2 (probe cache):     out of scope; deferred follow-up.
#   §8.3 (GraphQL suspend): per-surface backoff inside the helper.
#   §8.4 (debug mode):      MONITOR_INTERVAL sets compose_emit base.
#   §8.5 (staging):         IMPLEMENTED — per-task .out files,
#                            atomic via tmp+rename in _scheduler.sh.
#   §8.6 (prelude cache):   out of scope.
#   §8.7 (lockfile):        unchanged; one watcher per state dir.
#   §8.8 (--once semantics):drain pipeline — one data-gather tick,
#                            drain async, force-fire compose_emit.
log "scheduler active (interval=${INTERVAL}s max_sleep=${MONITOR_SCHEDULER_MAX_SLEEP}s async_timeout_floor=${MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR}s log=${MONITOR_SCHEDULER_LOG})"
_scheduler_install_signal_handlers

# Staging directory. Same accessor the scheduler uses for async
# `.out` writes; compose_emit reads from the same path. We `mkdir`
# once eagerly so sync-task atomic writes don't race with
# _scheduler_fire_async's mkdir on the very first tick.
V2_STAGE_DIR=$(_scheduler_stage_dir)
mkdir -p "$V2_STAGE_DIR" 2>/dev/null || true

# ---- sync-task wrappers (atomic staging writes for consumed
#      output, plain helpers otherwise) -------------------------
# NB: there is deliberately NO separate `heartbeat` task (nexus-code#236
# operator refinement). An always-ticks heartbeat is what let a wedged loop
# read as healthy on 2026-06-18. The heartbeat is now bumped ONLY at the end
# of a correct compose cycle (see bump_heartbeat + _v2_task_compose_emit), so
# it doubles as the proof-of-working-loop the supervisor checks.
_v2_task_prune_archive()     { prune_archive; }
_v2_task_over_limit_wakes()  { _over_limit_process_wakes "$TARGET"; }
_v2_task_bell_windows() {
    list_bell_windows | _scheduler_stage_write_atomic bell_windows
}
_v2_task_pending_decisions() {
    { render_pending_decisions 2>/dev/null || true; } \
        | _scheduler_stage_write_atomic pending_decisions
}
# Request inbox (agent-channel RFC Part B). requests_poll_emit claims new
# requests (atomic .new→.claimed), GCs terminal files, and renders the due
# `.claimed.md` set; compose_emit reads the staging file and wraps it in
# `--- requests ---`. Inert (no claim, no emit) while MONITOR_REQUESTS_ENABLED
# is false, so this is a safe no-op until the channel is enabled.
_v2_task_requests_poll() {
    { requests_poll_emit 2>/dev/null || true; } \
        | _scheduler_stage_write_atomic requests_poll
}

# ---- async-task wrappers (helper output captured to
#      `<name>.out` by _scheduler_fire_async; atomic via
#      .tmp+rename) ----------------------------------------------
_v2_task_idle_section()      { render_idle_section 2>/dev/null || true; }
# Event-fetch split (issue #181). The two sources ride different
# rate-limit buckets and live at different cadences:
#
#   deliveries_poll — App-JWT bucket; /app/hook/deliveries; webhook
#                     is the primary, real-time, cross-repo event
#                     source. Bounded above by what the App-JWT
#                     bucket sustains alongside other JWT callers.
#
#   github_poll     — App-installation GraphQL bucket; backstop for
#                     events the webhook missed (App not installed,
#                     3-day retention elapsed, listener down, etc.).
#                     Gated by `_graphql_polling_gate`'s bucket-
#                     floor probe so a draining bucket never gets
#                     hammered. Folds `snapshot_mentions` and
#                     `snapshot_bot_mentions` in when enabled (both
#                     GraphQL searches on the same bucket; the latter
#                     is the webhook-free channel for @bot-mentions on
#                     installed non-asset repos).
#
# Both write raw output; `compose_emit` runs the
# filter+cross_repo+dedup pipeline at the consumption end so
# cross-source duplicates collapse.
_v2_task_deliveries_poll()   { _snapshot_deliveries_raw; }
_v2_task_github_poll()       { _snapshot_github_raw; }
_v2_task_full_state_snap()   { render_full_state_snapshot 2>/dev/null || true; }
_v2_task_over_limit_scan()   { _over_limit_scan_panes "$TARGET"; }
_v2_task_snapshot_local()    { snapshot_local; }
_v2_task_detect_unstick()    { detect_and_unstick; }

# ---- target_window probe (2 s) -------------------------------
# Probe tmux directly. Owns the absent-respawn decision tree —
# revival latency bounded by the 2 s probe cadence (see
# _target_absent.sh / issue #174).
#
# Force-fires compose_emit on rc=2 so the freshly respawned
# orchestrator gets a workspace snapshot pasted promptly. Override
# narrows compose_emit's cadence to 5 s for the next 60 s.
# compose_emit is async, so the override won't starve other sync
# probes.
_v2_task_target_window_probe() {
    _target_window_present "$TARGET"
    _V2_LAST_TARGET_RC=$?
    case "$_V2_LAST_TARGET_RC" in
        0|1)
            missing_target_polls=0
            ;;
        2)
            _watcher_handle_target_absent_observation
            _schedule_fire_now compose_emit
            _schedule_override compose_emit 5 60
            ;;
    esac
    return 0
}
_V2_LAST_TARGET_RC=""

# ---- orchestrator_liveness task (5 s) ------------------------
# State machine + pin refresh + fork-and-disown for the spawn
# helper. The state-machine step itself is cheap (file stats).
# `spawn-fresh-orchestrator.sh` is multi-second and runs in a
# backgrounded `()` block so this task's sync slot returns
# immediately. The cooldown file is stamped BEFORE forking so a
# subsequent tick's cooldown check sees the in-flight event
# (idempotent — the helper re-stamps on success).
_v2_task_orchestrator_liveness() {
    # Gate: only valid when probe says target window is present.
    local target_rc="${_V2_LAST_TARGET_RC:-}"
    [[ "$target_rc" == "0" ]] || return 0
    [[ "$ORCH_FRESH_SPAWN_ENABLED" == "true" ]] || return 0

    # Poll-cycle pin refresh (issue #150). Cheap: stat + touch.
    _orchestrator_poll_refresh_pin \
        "$ORCH_PIN_FILE" "$ORCH_STALE_SECONDS" "$NEXUS_ROOT"

    # Recent-respawn skip: defer to the respawn path's own state.
    local respawn_recent=0 now_ts recent_cutoff recent_count
    if [[ -f "$RESPAWN_HISTORY" ]]; then
        now_ts=$(date +%s)
        recent_cutoff=$(( now_ts - ORCH_STALE_SECONDS ))
        recent_count=$(awk -v cutoff="$recent_cutoff" \
            '$1 ~ /^[0-9]+$/ && $1 >= cutoff {n++} END {print n+0}' \
            "$RESPAWN_HISTORY" 2>/dev/null || echo 0)
        (( recent_count > 0 )) && respawn_recent=1
    fi
    (( respawn_recent == 1 )) && return 0

    local liveness_verdict liveness_rc=0
    liveness_verdict=$(_orchestrator_liveness_step \
        "$ORCH_HEARTBEAT_FILE" "$ORCH_PASTE_RECEIVED_FILE" \
        "$ORCH_LAST_PASTE_FILE" \
        "$ORCH_PIN_FILE" "$ORCH_UNRESPONSIVE_SINCE_FILE" \
        "$ORCH_RESUBMIT_MARKER_FILE" \
        "$ORCH_FRESH_SPAWN_COOLDOWN_FILE" \
        "$ORCH_PASTE_RESPONSE_GRACE_S" \
        "$ORCH_UNSTICK_WINDOW_S" \
        "$ORCH_DEAD_THRESHOLD_S" \
        "$ORCH_FRESH_SPAWN_COOLDOWN_SECONDS" \
        "$ORCH_STALE_PASTE_CEILING_S" \
        "$NEXUS_ROOT") || liveness_rc=$?

    # Idle-pane guard (2026-06-15 incident) — DEFENSE-IN-DEPTH. The
    # static-workspace false-positive race is eliminated at the source by
    # the dead_threshold clamp at startup (above), so in normal operation
    # this guard never fires. It remains as a runtime backstop for residual
    # misfires (e.g. compose_emit starvation). The decision is the pure,
    # unit-tested `_orchestrator_idle_pane_guard`, which gates ONLY
    # `respawn reason=dead-threshold` (a resubmit-failed respawn has already
    # proven non-responsiveness via the re-paste probe and is never
    # suppressed). On an idle/empty pane it returns `suppress` (process
    # alive, not visibly wedged) until the override budget
    # ORCH_IDLE_OVERRIDE_MAX is spent, then `escalate` (an alive pane that
    # never recovers is itself a wedge — bounds the false-negative). This
    # block owns only the pane-state call and the override-count state file.
    # See docs/reference/orchestrator-liveness.md.
    if (( liveness_rc == 0 )) && [[ "$liveness_verdict" == respawn* ]]; then
        local _idle_guard_state="" _idle_guard_count=0 _idle_guard_decision
        if [[ -x "$NEXUS_ROOT/monitor/pane-state.sh" ]]; then
            _idle_guard_state=$(
                "$NEXUS_ROOT/monitor/pane-state.sh" "$TARGET" 2>/dev/null \
                    | grep -o 'state=[^ ]*' | head -n1 | cut -d= -f2
            ) || true
        fi
        if [[ -f "$ORCH_IDLE_OVERRIDE_COUNT_FILE" ]]; then
            _idle_guard_count=$(head -n1 "$ORCH_IDLE_OVERRIDE_COUNT_FILE" 2>/dev/null | tr -d '[:space:]')
            [[ "$_idle_guard_count" =~ ^[0-9]+$ ]] || _idle_guard_count=0
        fi
        _idle_guard_decision=$(_orchestrator_idle_pane_guard \
            "$liveness_verdict" "${_idle_guard_state:-}" \
            "$_idle_guard_count" "${ORCH_IDLE_OVERRIDE_MAX:-5}")
        case "$_idle_guard_decision" in
            suppress)
                _idle_guard_count=$(( _idle_guard_count + 1 ))
                mkdir -p "$(dirname "$ORCH_IDLE_OVERRIDE_COUNT_FILE")" 2>/dev/null || true
                printf '%d\n' "$_idle_guard_count" > "$ORCH_IDLE_OVERRIDE_COUNT_FILE" 2>/dev/null || true
                log "orchestrator-liveness: idle-pane-override (#${_idle_guard_count}/${ORCH_IDLE_OVERRIDE_MAX:-5}): pane state='${_idle_guard_state:-unknown}' — suppressed likely-false-positive respawn ($liveness_verdict); clock resets on next compose_emit paste"
                rm -f "$ORCH_UNRESPONSIVE_SINCE_FILE" "$ORCH_RESUBMIT_MARKER_FILE" 2>/dev/null || true
                liveness_verdict="healthy reason=idle-pane-override"
                liveness_rc=1
                ;;
            escalate)
                log "orchestrator-liveness: idle-pane-override budget exhausted (${_idle_guard_count}/${ORCH_IDLE_OVERRIDE_MAX:-5}, pane state='${_idle_guard_state:-unknown}') — pane looks idle but the orchestrator never recovered across overrides; honoring respawn ($liveness_verdict)"
                rm -f "$ORCH_IDLE_OVERRIDE_COUNT_FILE" 2>/dev/null || true
                ;;
            *)
                # proceed: pane is not idle/empty (real wedge, dead, or
                # pane-state errored) — honor the respawn and clear the
                # override budget.
                rm -f "$ORCH_IDLE_OVERRIDE_COUNT_FILE" 2>/dev/null || true
                ;;
        esac
    fi
    # Any GENUINE healthy verdict (orchestrator demonstrably responded, or
    # the paste aged past the stale-paste ceiling) resets the idle-override
    # budget — the suppression streak counts only consecutive no-recovery
    # cycles. The guard's own `idle-pane-override` healthy verdict is
    # excluded so it cannot reset its own counter.
    if [[ "$liveness_verdict" == healthy* && "$liveness_verdict" != *idle-pane-override* ]]; then
        rm -f "$ORCH_IDLE_OVERRIDE_COUNT_FILE" 2>/dev/null || true
    fi

    # Throttled verdict logging (state entry + every
    # ORCH_LIVENESS_LOG_THROTTLE_S + transitions). MUST run in the
    # current shell — the throttle state lives in process globals
    # that a command substitution's subshell would discard.
    _orchestrator_liveness_log_decide \
        "$liveness_verdict" "$(date +%s)" "$ORCH_LIVENESS_LOG_THROTTLE_S"
    [[ -n "${_ORCH_LIVENESS_LOG_LINE:-}" ]] && \
        log "orchestrator-liveness: $_ORCH_LIVENESS_LOG_LINE"

    case "$liveness_verdict" in
        respawn*)
            if (( liveness_rc == 0 )); then
                local prev_sid=""
                [[ -f "$ORCH_PIN_FILE" ]] && prev_sid=$(cat "$ORCH_PIN_FILE" 2>/dev/null || true)
                log "orchestrator-liveness state machine fired: $liveness_verdict (forked spawn)"
                # Stamp cooldown pre-fork (idempotent; spawn helper
                # re-stamps on success) so the next 5 s tick sees
                # the in-flight event and won't double-spawn.
                mkdir -p "$(dirname "$ORCH_FRESH_SPAWN_COOLDOWN_FILE")" 2>/dev/null || true
                touch -c "$ORCH_FRESH_SPAWN_COOLDOWN_FILE" 2>/dev/null || \
                    : > "$ORCH_FRESH_SPAWN_COOLDOWN_FILE"
                _ensure_service_log "$LOGFILE"
                (
                    # Disowned fork that can outlive us — it must never
                    # pin the instance flock (skeptic finding 5, PR#503).
                    _close_inherited_locks
                    if NEXUS_ROOT="$NEXUS_ROOT" \
                       STATE_DIR="$STATE_DIR" \
                       bash "$_script_dir/spawn-fresh-orchestrator.sh" \
                            --target "$TARGET" \
                            --reason "$liveness_verdict" \
                            --previous-sid "$prev_sid" >>"$LOGFILE" 2>&1; then
                        log "orchestrator fresh-spawn (forked) succeeded: target=$TARGET prev_sid=${prev_sid:-none}"
                        # Same reset as respawn_agent (#489 skeptic C2):
                        # the fresh session must see the live request
                        # set, not the dead session's delivery clocks.
                        requests_reset_delivery_state
                    else
                        log "orchestrator fresh-spawn (forked) returned non-zero (cooldown stamped regardless)"
                    fi
                    if command -v sandbox-notify >/dev/null 2>&1; then
                        sandbox-notify "watcher: orchestrator fresh-spawn fired ($liveness_verdict)" \
                            >/dev/null 2>&1 || true
                    fi
                ) &
                disown
                rm -f "$ORCH_UNRESPONSIVE_SINCE_FILE" 2>/dev/null || true
                rm -f "$ORCH_RESUBMIT_MARKER_FILE" 2>/dev/null || true
                WATCHER_START_TS=$(date +%s)
            fi
            ;;
        resubmit*)
            # One-shot re-paste rescue (orchestrator-liveness
            # resilience). Body extracted to _orch_resubmit_rescue in
            # _orchestrator_liveness.sh (#489 skeptic C1: the branch
            # mutates request-delivery state and needs regression
            # coverage, which main.sh-inline code cannot get).
            _orch_resubmit_rescue "$TARGET" "$DIFF_DIR" \
                "$ORCH_RESUBMIT_MARKER_FILE" "$liveness_verdict"
            ;;
        waiting*|blocked-by-cooldown*|healthy*)
            # Logging handled by the throttle above.
            : ;;
        *)
            log "orchestrator-liveness: unknown verdict shape: $liveness_verdict"
            ;;
    esac
    return 0
}

# ---- functional_check task (--async, 600 s default cadence) --
# other-nexus-lessons L1. Orthogonal to orchestrator_liveness: that
# task watches pid/heartbeat/paste-receipt; this one watches
# whether the bot actually REACTED (eyes/rocket) to comments the
# watcher recently surfaced. Each fire makes one `gh api reactions`
# call per surfaced comment in the last few emits — bounded above
# by MONITOR_FUNCTIONAL_MAX_EMITS × (eligible comments per emit).
# Async so the network round-trips don't hold the sync slot;
# 600 s cadence so the cumulative GraphQL/REST cost stays modest
# alongside the existing 600 s github_poll backstop.
#
# Gates:
#
#   - knob = 0 → check disabled at the decide layer (no network call).
#   - Workspace quiet (no recent emits / no eligible comments) →
#     decide returns "bypass …", no escalation.
#
# Escalation on `stale`: log loud + sandbox-notify. We do NOT call
# spawn-fresh-orchestrator here — that's reserved for the pid/
# heartbeat path which has a much tighter false-positive budget.
# The functional check's role is to surface a wedge the existing
# state machine can't see; the operator then decides whether to
# bounce the orchestrator manually or wait for the next signal.
# Refining toward automatic respawn lives in a follow-up once the
# false-positive rate of the functional check is well-characterised.
_v2_task_functional_check() {
    local sla="${MONITOR_FUNCTIONAL_SLA_SECONDS:-600}"
    [[ "$sla" =~ ^[0-9]+$ ]] || sla=600
    local max_emits="${MONITOR_FUNCTIONAL_MAX_EMITS:-5}"
    [[ "$max_emits" =~ ^[0-9]+$ ]] || max_emits=5
    local verdict rc=0
    verdict=$(_functional_check_decide \
        "$DIFF_DIR" "$sla" "$max_emits" \
        "$REPO" "${BOT_LOGIN:-}" \
        "$FUNCTIONAL_CHECK_STATE_FILE" \
        gh) || rc=$?
    case "$verdict" in
        stale*)
            log "functional-check FIRED: $verdict"
            if command -v sandbox-notify >/dev/null 2>&1; then
                sandbox-notify "watcher: functional check stale ($verdict)" \
                    >/dev/null 2>&1 || true
            fi
            # Close the detection→recovery loop (nexus-code#236), GUARDED to
            # the WATCHER-FAULT case only. functional_check fires when surfaced
            # comments go un-acked past the SLA; that can be one of THREE
            # domains, only one of which a watcher restart fixes:
            #
            #   - watcher-fault      — the watcher's loop is wedged (stale
            #                          loop-proof heartbeat) OR its paste path
            #                          is actively failing (emits generated but
            #                          stuck). A restart DOES help.
            #   - orchestrator-fault — a paste landed recently (delivery clock
            #                          fresh) but the orchestrator never
            #                          reacted. A watcher restart would not
            #                          help and risks a storm; orchestrator-
            #                          liveness owns this.
            #   - quiet              — the loop is alive (fresh heartbeat) and
            #                          the paste path is not failing; nothing
            #                          has been emitted lately so the delivery
            #                          clock has simply aged past the SLA. This
            #                          is normal idle, NOT a fault.
            #
            # The PRIOR gate keyed solely on the delivery clock (`delivery_age
            # > sla` ⇒ watcher-fault) and so conflated `quiet` with
            # `watcher-fault`: on a genuinely quiet workspace the delivery
            # clock ages past the SLA while the loop is perfectly alive, and
            # the watcher spuriously self-revived (~0s downtime, every ~13min).
            # We re-aim it: judge watcher-liveness by the LOOP-PROOF HEARTBEAT
            # (`_watcher_alive`, the same source svc.sh / revive-watcher.sh
            # use) and the emit-delivery failure counter — NOT by delivery
            # staleness, which is normal when quiet. `_functional_fault_class`
            # owns the (pure, unit-tested) decision; the self-heal chokepoint
            # is itself cooldown- and loop-guarded, so this can never storm
            # even if misfiring.
            local _deliv_age=999999 _deliv_ts _fc_now
            _fc_now=$(date +%s)
            if [[ -f "$EMIT_LAST_DELIVERY_FILE" ]]; then
                _deliv_ts=$(cat "$EMIT_LAST_DELIVERY_FILE" 2>/dev/null || echo 0)
                [[ "$_deliv_ts" =~ ^[0-9]+$ ]] || _deliv_ts=0
                (( _deliv_ts > 0 )) && _deliv_age=$(( _fc_now - _deliv_ts ))
            fi
            # Loop-proof heartbeat liveness (0=fresh 1=aging 2=dead 3=no-hb).
            local _loop_alive_rc=0
            _watcher_alive "$STATE_DIR" "$INTERVAL" >/dev/null 2>&1 || _loop_alive_rc=$?
            # Consecutive emit-delivery failures (emits-generated-but-stuck);
            # absent/cleared ⇒ 0 (a successful delivery clears the counter).
            local _deliv_fail=0
            if [[ -f "$EMIT_DELIVERY_FAIL_FILE" ]]; then
                _deliv_fail=$(cat "$EMIT_DELIVERY_FAIL_FILE" 2>/dev/null || echo 0)
                [[ "$_deliv_fail" =~ ^[0-9]+$ ]] || _deliv_fail=0
            fi
            local _fault_class _fault_rc=0
            _fault_class=$(_functional_fault_class \
                "$_loop_alive_rc" "$_deliv_fail" "$_deliv_age" "$sla") || _fault_rc=$?
            if (( _fault_rc == 0 )); then
                log "functional-check: WATCHER-FAULT confirmed ($_fault_class) — invoking cooldown-guarded self-heal"
                _watcher_self_heal_restart "functional-check watcher-fault: $verdict, $_fault_class"
            else
                log "functional-check: emits un-acked but NOT a watcher fault ($_fault_class) — no watcher restart (loop heartbeat fresh; orchestrator-liveness owns un-acked-but-delivered work)"
            fi
            ;;
        bypass*)
            # Quiet — bypass is the steady state on an idle workspace.
            : ;;
        healthy*)
            # Verbose only at debug; the steady-state row goes to the
            # TSV state file regardless.
            : ;;
        *)
            log "functional-check: unknown verdict shape: $verdict"
            ;;
    esac
    return 0
}

# ---- cc_version_check task (--async, 24h default cadence) ----
# DETECT→INFORM half of the GATED Claude Code self-update loop. Compares
# the EFFECTIVE Claude Code version (operator-local pin if present, else
# the shared package.json FLOOR — see monitor/_cc-version.sh) against the
# npm `latest` dist-tag; on a newer release, writes
# monitor/.state/cc-update-available (idempotent per candidate). The compose_emit task surfaces it ONCE per candidate
# (re-nag guarded by cc-update-surfaced), pointing the orchestrator at
# the updater skill so a human-spawned evaluator runs the cc-harness
# gate before any pin is promoted. NEVER auto-bumps.
#
# Fail-safe: a registry-fetch failure leaves the signal untouched and
# returns benign — version detection must never block the watcher loop.
# Async so the registry round-trip never holds the sync slot; 24h
# cadence so the cost is negligible (cc publishes ~daily, but we only
# need to know "is there something newer than the pin", not catch every
# point release the moment it lands).
_v2_task_cc_version_check() {
    local pinned verdict rc=0
    # Gate baseline = the EFFECTIVE version the operator ACTUALLY runs:
    # the operator-local pin (monitor/.state/cc-version-local) if present,
    # else the shared package.json FLOOR. Comparing against effective
    # (not the lagging maintainer floor) means the gate fires when a
    # release newer than the running version exists, and STOPS firing
    # once a gated bump advances the local pin — even though the shared
    # floor never moved. See monitor/_cc-version.sh / nexus-code#226.
    pinned=$(cc_version_effective \
        "$NEXUS_ROOT/package.json" "$MONITOR_CC_UPDATE_PACKAGE" "$NEXUS_ROOT" 2>/dev/null || true)
    verdict=$(_cc_update_decide \
        "$STATE_DIR" \
        "$MONITOR_CC_UPDATE_PACKAGE" \
        "$pinned" \
        "$MONITOR_CC_UPDATE_SKILL_PATH" \
        _cc_update_default_fetch \
        "$MONITOR_CC_UPDATE_FETCH_TIMEOUT_SECONDS") || rc=$?
    case "$verdict" in
        available*)
            log "cc-update FIRED: $verdict skill=$MONITOR_CC_UPDATE_SKILL_PATH"
            ;;
        current*)
            # Steady state on an up-to-date pin — quiet.
            : ;;
        unreachable*)
            # Fail-safe path: registry unreachable. Log quietly so a
            # persistent network problem is visible in the watcher log
            # without alarming; the signal (if any) is preserved.
            log "cc-update: $verdict (fail-safe; signal unchanged)"
            ;;
        *)
            log "cc-update: $verdict"
            ;;
    esac
    return 0
}

# ---- cc_auto_update task (--async, 5 min default cadence) ----
# Autonomous daily cc-update routine (DRIVE half; your-nexus#207).
# Each fire is a cheap due-check (today's fire_time passed? day stamp
# absent?); at most once per calendar day it runs a fresh registry
# decide and, on a new candidate that isn't already awaiting the
# operator, spawns the autonomous evaluator worker (window
# `cc-auto-update`, prompt rendered from monitor/cc-auto-update-prompt.md).
# The evaluator runs the GUIDE flow; only its provably-safe verdict
# bumps, via monitor/cc-auto-update-apply.sh's gated `safe` verb. All
# state is on-disk under monitor/.state/cc-auto-update/ so the cadence
# survives watcher restarts AND orchestrator respawns (the reason this
# is a scheduler task, not a harness CronCreate — see the module
# header). Fail-safe: registry failures retry next tick without
# consuming the day; every other uncertainty declines and stamps.
_v2_task_cc_auto_update() {
    _cc_auto_update_tick \
        "$NEXUS_ROOT" \
        "$STATE_DIR" \
        "$MONITOR_CC_UPDATE_PACKAGE" \
        "$MONITOR_CC_AUTO_UPDATE_FIRE_TIME" \
        _cc_update_default_fetch \
        "$MONITOR_CC_UPDATE_FETCH_TIMEOUT_SECONDS"
    return 0
}

# ---- version_check task (--async, 60 s default cadence) ------
# Version-aware component restart (issue #186). Each fire hashes every
# component's source set against its recorded running version and, on
# a STABLE drift (the settle window outwaits torn pulls), triggers the
# component's restart path: watcher → detached launcher --replace
# (cooldown + loop-guarded), cockpit → ask record surfaced by
# compose_emit (the watcher never kills the orchestrator-owned TUI),
# registered service → svc.sh restart (once, cooldown-gated). All
# state is on-disk under monitor/.state/version/, so running --async
# in a subshell is safe; the detached launcher survives this process's
# own SIGTERM during a self-replace. Hashing a few dozen small files
# is cheap, but NFS reads justify keeping it off the sync slot.
_v2_task_version_check() {
    _version_check_tick
    return 0
}

# ---- service_health task (--async, 120 s default cadence) ----
# Continuous service-health watch (service-health-watch). Each fire runs
# every registry service's column-4 healthcheck. A freshly-unhealthy
# service gets a self-heal grace window first (defer to its supervisor);
# only one still unhealthy after grace is acted on, and then per its
# restart policy (auto-restart → flap-controlled svc.sh restart →
# recover_service; emit-only → escalate, no restart). It records a
# per-service incident state file at every step. compose_emit surfaces the
# grace/recovering/emit-only/flapping/recovered conditions. All state is
# on-disk, so running --async in a subshell is safe; the restart shells out
# to svc.sh (a separate process — no log()/global clobber of the watcher).
_v2_task_service_health() {
    _service_health_check_tick
    return 0
}

# ---- automatic reports-archive roll (your-org/nexus-code#447) -------------
# Runs the idempotent, ≥1-month-buffered roller (monitor/reports-roll.sh,
# #444/#446) on the FIRST scheduler tick after startup (the scheduler seeds a
# fresh task's next_fire=0) and, thereafter, at most once per calendar day.
# The day-stamp gate keeps every other tick a cheap no-op — a `date` compare
# and a file read, NO reports-dir scan — so we never reintroduce #443's
# per-loop cost. The roll itself is idempotent and buffer-protected: it can
# only ever move reports strictly older than the previous month, so a
# recent / in-flight report is never touched no matter the current state.
#
# Emit hygiene: SILENT when nothing moves. Only a run that actually rolls
# ≥1 file writes the one-shot notice file, which compose_emit surfaces once
# (and consumes) as `--- reports archived ---`, routed through the normal
# change-or-timeout gate and pulled forward with `_schedule_fire_now`.
_v2_task_reports_roll() {
    local today last
    today=$(date +%Y-%m-%d)
    last=$(cat "$REPORTS_ROLL_LAST_DAY_FILE" 2>/dev/null || true)
    [[ "$today" == "$last" ]] && return 0   # already rolled today → cheap skip

    local roller="$_script_dir/../reports-roll.sh"
    if [[ ! -x "$roller" ]]; then
        log "reports-roll: roller not found/executable at $roller; skipping"
        return 0
    fi

    local out rc=0
    out=$(NEXUS_ROOT="$NEXUS_ROOT" \
          REPORTS_ROLL_MIN_AGE_SECONDS="$MONITOR_REPORTS_ROLL_MIN_AGE_SECONDS" \
          "$roller" --now --quiet 2>&1) || rc=$?
    if (( rc != 0 )); then
        # Never wedge the scheduler on a roller error; retry next day-boundary.
        # Deliberately do NOT stamp the day, so the next tick re-attempts.
        log "reports-roll: roller exited rc=$rc; will retry next tick. Output: ${out}"
        return 0
    fi

    # Stamp today regardless of whether anything moved — we DID run today.
    printf '%s\n' "$today" > "${REPORTS_ROLL_LAST_DAY_FILE}.tmp.$$" 2>/dev/null \
        && mv -f "${REPORTS_ROLL_LAST_DAY_FILE}.tmp.$$" "$REPORTS_ROLL_LAST_DAY_FILE" 2>/dev/null \
        || rm -f "${REPORTS_ROLL_LAST_DAY_FILE}.tmp.$$" 2>/dev/null

    local rolled
    rolled=$(printf '%s' "$out" | grep -oE 'rolled [0-9]+' | head -1 | grep -oE '[0-9]+' || true)
    rolled=${rolled:-0}
    if (( rolled > 0 )); then
        # One-shot audit breadcrumb, written to a DURABLE notice file.
        # compose_emit's _reports_roll_emit_section surfaces it once, then
        # consumes it (self-clearing → no flap). We do NOT force-fire
        # compose_emit here: this task runs in a `( … ) &` async subshell, so a
        # `_schedule_fire_now` would mutate subshell-local scheduler state and
        # be lost. The durable-file + own-cadence pickup is the same pattern
        # deliveries_poll uses, and the roll also changes snapshot_local's
        # reports section, which the scheduler's post-tick hook already uses to
        # pull compose_emit forward — so the breadcrumb surfaces promptly.
        printf 'Auto-archived aged reports into monthly reports/YYYY-MM/ buckets.\n%s\n' \
            "$out" > "${REPORTS_ROLL_NOTICE_FILE}.tmp.$$" 2>/dev/null \
            && mv -f "${REPORTS_ROLL_NOTICE_FILE}.tmp.$$" "$REPORTS_ROLL_NOTICE_FILE" 2>/dev/null \
            || rm -f "${REPORTS_ROLL_NOTICE_FILE}.tmp.$$" 2>/dev/null
        log "reports-roll: ${out}"
    fi
    return 0
}

# _reports_roll_emit_section <notice_file>
# One-shot: if a roll notice is pending, print it and CONSUME it (delete),
# so it surfaces exactly once and a subsequent quiet cycle re-adds nothing.
# Same self-clearing shape as the watcher-revived one-shot.
_reports_roll_emit_section() {
    local notice="${1:-}"
    [[ -n "$notice" && -s "$notice" ]] || return 0
    cat "$notice" 2>/dev/null || return 0
    rm -f "$notice" 2>/dev/null || true
}

# ---- compose_emit task (--async, cadence = MONITOR_INTERVAL) -
# Reads staged outputs from
# `monitor/.state/scheduler-staging/<name>.out`, computes
# local_diff vs BASELINE, applies the emit-decision tree, composes
# + archives + pastes. All state mutations are file-based
# (BASELINE, FULL_STATE_STAMP, FULL_STATE_CANONICAL_CACHE,
# RESPAWN_HISTORY counters), so running in an async subshell is
# safe. EMIT_SIG_NONCE is set locally in the subshell — fresh per
# fire.
_v2_task_compose_emit() {
    local stage_dir="$V2_STAGE_DIR"
    local local_snapshot="$stage_dir/snapshot_local.out"
    # Self-heal a reaped scratch dir BEFORE any path under it is used
    # (nexus-code#236). Without this the cp below would fail and the
    # whole emit path would silently no-op for the rest of the watcher's
    # life — the exact wedge that buried nexus-code#310/#311.
    _ensure_watcher_tmp_dir
    local current_tmp="${tmp_dir}/compose-current.$$"
    # Pull the latest local snapshot. If snapshot_local hasn't
    # fired yet (first tick before drain), bail — nothing to diff,
    # the next compose_emit will pick it up.
    [[ -f "$local_snapshot" ]] || return 0
    if ! cp "$local_snapshot" "$current_tmp" 2>/dev/null; then
        log "compose_emit: cannot stage local snapshot to $current_tmp (scratch dir issue?); skipping this fire"
        return 0
    fi

    _progress_bump compose:start

    # Seed BASELINE on first ever run.
    if [[ ! -f "$BASELINE" ]]; then
        cp "$current_tmp" "$BASELINE" 2>/dev/null || true
        rm -f "$current_tmp" 2>/dev/null || true
        _cycle_bump
        bump_heartbeat   # healthy cycle (snapshot built, baseline seeded)
        return 0
    fi

    # Baseline format-upgrade guard (nexus-code#236). snapshot_local is
    # format-tagged on its first line; when the SHAPE changes (this
    # hardening's tmux-first / no-mtime / git-off reshape), the first
    # post-deploy diff would otherwise be a spurious whole-snapshot reformat
    # pasted to the orchestrator. Detect a tag mismatch and reseed the
    # baseline SILENTLY — real signal resumes on the next cycle.
    local _base_tag _cur_tag
    _base_tag=$(head -n1 "$BASELINE" 2>/dev/null || true)
    _cur_tag=$(head -n1 "$current_tmp" 2>/dev/null || true)
    if [[ "$_base_tag" != "$_cur_tag" ]]; then
        cp "$current_tmp" "${BASELINE}.tmp.$$" 2>/dev/null \
            && mv "${BASELINE}.tmp.$$" "$BASELINE" 2>/dev/null || true
        log "snapshot baseline format upgraded ('${_base_tag:0:48}' -> '${_cur_tag:0:48}'); reseeded silently (no spurious reformat emit)"
        rm -f "$current_tmp" 2>/dev/null || true
        _cycle_bump
        bump_heartbeat   # healthy cycle (snapshot built, baseline reseeded)
        return 0
    fi

    local gh_now bell_now idle_now pending_now requests_now
    # Event-fetch split (issue #181). Concat both raw streams, then
    # run the shared filter+cross_repo+dedup pipeline so cross-source
    # duplicates (same comment surfacing through both webhook and
    # GraphQL backstop) collapse to a single emit block.
    #
    # Deliveries side reads the durable queue, NOT the scheduler
    # staging file (issue #186). The scheduler's atomic-replace write
    # of `_v2_task_deliveries_poll`'s stdout to `deliveries_poll.out`
    # is overwritten on every 15s tick, so a 60s read window misses
    # three of every four ticks. The queue is drained (locked
    # rename + read + rm) so events surface even when the fire that
    # produced them was followed by an empty fire.
    # Re-emit-until-acked for cross-repo bot-mention comments
    # (nexus-code#236). The deliveries queue is a DURABLE but emit-ONCE
    # buffer: a cross-repo `mention=` block drained here whose paste then
    # fails is gone with no retry (unlike in-$REPO comments, which
    # `snapshot_github`/github_poll.out re-emit until 👀-acked every
    # 600s). So: drain once, garbage-collect acked/aged registry entries,
    # register every fresh cross-repo block into the durable re-emit
    # registry, then compose gh_now from the fresh drain + the GraphQL
    # backstop + the registry's still-un-acked blocks. The shared
    # pipeline's `_dedup_emit_lines` collapses the drain/registry overlap,
    # `_filter_processed_comments` drops anything the bot has since 👀'd
    # (stops re-emit), and `_filter_emit_cooldown` throttles each comment
    # to the re-emit cadence (no per-poll storm).
    local _drained
    _drained=$(_drain_deliveries_queue 2>/dev/null || true)
    _reemit_gc 2>/dev/null || true
    # Scope the durable registry by the bot's PARTICIPATION, not by author
    # (your-org/nexus-code#359 round-2; operator: "other users' comments
    # shouldn't be drained unless the bot participated... it could be user-
    # relevant"). The deliveries log is global across every installed repo, so
    # a raw drain carries cross-tenant blocks from other operators' nexuses.
    #   * `_filter_cross_repo_surface` (mention_only) keeps ONLY cross-repo
    #     blocks whose body @-mentions THIS bot -- the discussions the bot is
    #     addressed in / participates in -- and drops the rest (genuine foreign
    #     noise the bot is NOT involved in; those are the only blocks actually
    #     DRAINED away). Adopted from #359's scoping, but as a PARTICIPATION
    #     gate, not an author gate.
    #   * `_reemit_register` then classifies the survivors by author:
    #     operator-authored -> `direct=yes` (two-tier direct re-emit);
    #     other-user-authored -> `direct=no` RETAINED CONTEXT (kept in the
    #     registry, NEVER re-fed for direct emission). A user-relevant
    #     cross-tenant comment the bot is involved in is preserved, not
    #     discarded -- while the operator-author chokepoint in
    #     `_gh_filter_dedup_pipeline` still guarantees no foreign block ever
    #     direct-emits.
    # The `/skip` opt-out filter is deliberately NOT applied: a cross-repo @bot
    # mention is itself the eligibility gate (operator call, #359 thread).
    # NOTE: `_filter_to_user_author` is intentionally NO LONGER in this
    # pre-pass -- it would drop the very foreign-but-bot-involved blocks we now
    # preserve as context; the DIRECT path keeps it as the chokepoint.
    printf '%s\n' "$_drained" \
        | _filter_cross_repo_surface \
        | _reemit_register 2>/dev/null || true
    # BOUNDED body-processing stage (compose_emit multibyte wedge). This
    # filter pipeline is the compose_emit step MOST exposed to operator-
    # controlled comment content; LC_ALL=C inside each filter makes a byte-
    # truncated (invalid-UTF-8) body byte-safe, and capping wall-clock here
    # means no future pathological body (or filter regression) in THIS stage
    # can hang and stall the cycle-end heartbeat. (The upstream
    # `_reemit_register` pre-pass and the downstream compose_report/paste
    # remain unbounded — out of scope here; the supervisor-revive backstop
    # still covers a hang there.) On a non-zero _run_bounded result: empty
    # gh_now + loud log; the cycle continues and still bumps the heartbeat
    # (skip the bad input, keep beating) rather than going stale and forcing
    # a supervisor revive (~9min downtime in the 2026-06-24 incident).
    _ensure_watcher_tmp_dir
    local _ghf_to="${MONITOR_COMPOSE_FILTER_TIMEOUT_SECONDS:-30}"
    [[ "$_ghf_to" =~ ^[0-9]+$ ]] || _ghf_to=30
    local _ghf_in="${tmp_dir}/compose-ghfilter-in.$$"
    local _ghf_out="${tmp_dir}/compose-ghfilter-out.$$"
    {
        printf '%s\n' "$_drained"
        cat "$stage_dir/github_poll.out" 2>/dev/null || true
        _reemit_pending 2>/dev/null || true
    } > "$_ghf_in" 2>/dev/null || true
    local _ghf_rc=0
    _run_bounded "$_ghf_to" "$_ghf_out" _gh_filter_dedup_pipeline_file "$_ghf_in" || _ghf_rc=$?
    if (( _ghf_rc == 0 )); then
        gh_now=$(cat "$_ghf_out" 2>/dev/null || true)
    else
        gh_now=""
        # rc 124 = _run_bounded wall-clock kill (the hang case); any other
        # non-zero is a pipeline-internal failure. Both degrade identically
        # (skip this cycle's eligible-comments, keep beating) but log
        # distinctly so a timeout isn't misattributed to a crash, or v.v.
        if (( _ghf_rc == 124 )); then
            log "WARN compose_emit: gh-filter pipeline exceeded ${_ghf_to}s (wall-clock kill); eligible-comments treated as EMPTY this cycle (bad body/filter skipped, cycle NOT blocked, heartbeat preserved)"
        else
            log "WARN compose_emit: gh-filter pipeline failed (rc=${_ghf_rc}); eligible-comments treated as EMPTY this cycle (cycle NOT blocked, heartbeat preserved)"
        fi
    fi
    rm -f "$_ghf_in" "$_ghf_out" 2>/dev/null || true
    bell_now=$(cat "$stage_dir/bell_windows.out" 2>/dev/null || true)
    idle_now=$(cat "$stage_dir/idle_section.out" 2>/dev/null || true)
    pending_now=$(cat "$stage_dir/pending_decisions.out" 2>/dev/null || true)
    requests_now=$(cat "$stage_dir/requests_poll.out" 2>/dev/null || true)

    # Full-state cadence + identity-check gate.
    local full_state_lines="" full_state_canonical="" full_state_due=0
    local last_full_ts now_ts canonical_prelude cached_canonical last_emit_mtime
    local _fs_idle_anchor _fs_idle_dur _fs_eff_floor
    if (( MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS > 0 )); then
        last_full_ts=0
        if [[ -f "$FULL_STATE_STAMP" ]]; then
            last_full_ts=$(cat "$FULL_STATE_STAMP" 2>/dev/null || echo 0)
            [[ "$last_full_ts" =~ ^[0-9]+$ ]] || last_full_ts=0
        fi
        now_ts=$(date +%s)
        if (( now_ts - last_full_ts >= MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS )); then
            full_state_due=1
            full_state_lines=$(cat "$stage_dir/full_state_snap.out" 2>/dev/null || true)
            # Re-render inline if staging is empty (e.g. very first
            # compose_emit before full_state_snap async completed). These
            # renders probe every worker pane (O(workers)) and can stall under
            # load — and they run INSIDE the compose cycle whose completion
            # bumps the proof-of-working-loop heartbeat. So they are WALL-CLOCK
            # BOUNDED (nexus-code#236): past the budget the cycle continues with
            # a partial render rather than letting a slow render stale the
            # heartbeat and trip a false supervisor restart. _run_bounded kills
            # the render's pane-probe subtree on overrun.
            _ensure_watcher_tmp_dir
            local _ce_to="${MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS:-20}"
            local _ce_tmp="${tmp_dir}/compose-render.$$"
            if [[ -z "$full_state_lines" ]]; then
                if ! _run_bounded "$_ce_to" "$_ce_tmp" render_full_state_snapshot; then
                    log "WARN compose_emit: inline full-state render exceeded ${_ce_to}s; using partial (cycle NOT blocked)"
                fi
                full_state_lines=$(cat "$_ce_tmp" 2>/dev/null || true)
            fi
            if MONITOR_PRELUDE_DRY_RUN=1 _run_bounded "$_ce_to" "$_ce_tmp" render_idle_prelude; then
                canonical_prelude=$(cat "$_ce_tmp" 2>/dev/null || true)
            else
                canonical_prelude=$(cat "$_ce_tmp" 2>/dev/null || true)
                log "WARN compose_emit: inline prelude render exceeded ${_ce_to}s; using partial (cycle NOT blocked)"
            fi
            rm -f "$_ce_tmp" 2>/dev/null || true
            # Canonical form = the SHARED volatile strip
            # (_emit_dedup.sh) — same normalization the dedup gate
            # hashes, so both change detectors agree on what
            # "unchanged" means. Must stay in sync with the startup
            # canonical seed above.
            full_state_canonical=$(printf '%s\n---snapshot---\n%s' \
                "$canonical_prelude" "$full_state_lines" \
                | _emit_volatile_strip)
            if [[ -f "$FULL_STATE_CANONICAL_CACHE" ]]; then
                cached_canonical=$(cat "$FULL_STATE_CANONICAL_CACHE" 2>/dev/null || true)
                if [[ "$full_state_canonical" == "$cached_canonical" ]]; then
                    last_emit_mtime=$(date +%s -r "$FULL_STATE_CANONICAL_CACHE" 2>/dev/null || echo 0)
                    [[ "$last_emit_mtime" =~ ^[0-9]+$ ]] || last_emit_mtime=0
                    # Adaptive idle backoff. The idle-streak anchor tracks when
                    # the canonical last CHANGED; the effective floor stretches
                    # the longer it has stayed identical, so a quiet night drops
                    # to ~1 heartbeat/hour instead of ~1/20min. A heartbeat
                    # re-emit does NOT touch the anchor (only a genuine change
                    # below does), so the streak — and thus the stretch — carries
                    # across successive no-change heartbeats. Missing anchor ⇒
                    # seed from the last emit (conservative: starts near-base).
                    _fs_idle_anchor=0
                    if [[ -f "$FULL_STATE_IDLE_ANCHOR" ]]; then
                        _fs_idle_anchor=$(cat "$FULL_STATE_IDLE_ANCHOR" 2>/dev/null || echo 0)
                        [[ "$_fs_idle_anchor" =~ ^[0-9]+$ ]] || _fs_idle_anchor=0
                    fi
                    if (( _fs_idle_anchor == 0 )); then
                        _fs_idle_anchor="$last_emit_mtime"
                        printf '%s' "$_fs_idle_anchor" > "${FULL_STATE_IDLE_ANCHOR}.tmp" 2>/dev/null \
                            && mv "${FULL_STATE_IDLE_ANCHOR}.tmp" "$FULL_STATE_IDLE_ANCHOR" 2>/dev/null || true
                    fi
                    _fs_idle_dur=$(( now_ts - _fs_idle_anchor ))
                    (( _fs_idle_dur < 0 )) && _fs_idle_dur=0
                    _fs_eff_floor=$(_full_state_effective_floor "$_fs_idle_dur")
                    [[ "$_fs_eff_floor" =~ ^[0-9]+$ ]] || _fs_eff_floor="$MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS"
                    if (( now_ts - last_emit_mtime < _fs_eff_floor )); then
                        full_state_due=0
                        full_state_lines=""
                        date +%s > "$FULL_STATE_STAMP" 2>/dev/null || true
                        log "full-state suppressed: canonical unchanged, floor_age=$((now_ts - last_emit_mtime))s/${_fs_eff_floor}s (base ${MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS}s, idle ${_fs_idle_dur}s)"
                    fi
                else
                    # Canonical CHANGED — reset the idle-streak anchor so the
                    # effective floor snaps back to base and the heartbeat is
                    # responsive again. This is the "snap back the moment the
                    # canonical changes / a worker transitions" half of the
                    # backoff contract. The emit itself proceeds below.
                    printf '%s' "$now_ts" > "${FULL_STATE_IDLE_ANCHOR}.tmp" 2>/dev/null \
                        && mv "${FULL_STATE_IDLE_ANCHOR}.tmp" "$FULL_STATE_IDLE_ANCHOR" 2>/dev/null || true
                fi
            else
                # No cache yet (first full-state cycle after a cold start) —
                # seed the anchor now so the streak measures from here.
                printf '%s' "$now_ts" > "${FULL_STATE_IDLE_ANCHOR}.tmp" 2>/dev/null \
                    && mv "${FULL_STATE_IDLE_ANCHOR}.tmp" "$FULL_STATE_IDLE_ANCHOR" 2>/dev/null || true
            fi
        fi
    fi

    local local_diff=""
    if ! cmp -s "$BASELINE" "$current_tmp"; then
        local_diff=$(diff -u "$BASELINE" "$current_tmp" | head -120 || true)
    fi

    local signal_from_diff=0 noise_summary=""
    if [[ -n "$local_diff" ]]; then
        printf '%s\n' "$local_diff" > "${tmp_dir}/compose_diff.$$"
        local classify_rc=0
        noise_summary=$(_classify_diff "${tmp_dir}/compose_diff.$$") || classify_rc=$?
        case "$classify_rc" in
            0) signal_from_diff=1 ;;
            1) signal_from_diff=0 ;;
            *) signal_from_diff=1
               log "classify-diff error (rc=$classify_rc); treating as signal" ;;
        esac
        rm -f "${tmp_dir}/compose_diff.$$" 2>/dev/null || true
    fi

    # cc update-detection: a newer-release advisory, surfaced once per
    # candidate (re-nag guarded inside _cc_update_emit_section). Computed
    # before the emit gate so it can itself trigger an emit on an
    # otherwise-quiet workspace — the signal would otherwise sit
    # unsurfaced until the next unrelated state change. Marking-surfaced
    # is a side effect of this call, which is consistent because a
    # non-empty result is added to BOTH gate predicates below, so a
    # surfaced candidate always actually composes.
    local cc_update_now=""
    cc_update_now=$(_cc_update_emit_section "$STATE_DIR" 2>/dev/null || true)

    # Component-drift asks (issue #186): same surfacing model as the
    # cc-update advisory — computed before the gate so a drift ask can
    # itself trigger an emit on an otherwise-quiet workspace, surfaced
    # once per candidate hash (re-nag guarded inside the helper).
    local version_drift_now=""
    version_drift_now=$(_version_emit_section "$VERSION_STATE_DIR" "$NEXUS_ROOT" 2>/dev/null || true)

    # Service-health incidents (service-health-watch): same surfacing
    # model — computed before the gate so a down/flapping service can
    # itself trigger an emit on an otherwise-quiet workspace, re-nag
    # guarded per status:attempts inside the helper (and the recovered
    # breadcrumb is one-shot, closing the incident).
    local service_health_now=""
    service_health_now=$(_service_health_emit_section "$SERVICE_HEALTH_STATE_DIR" "$NEXUS_ROOT" 2>/dev/null || true)

    # Auto-roll audit breadcrumb (your-org/nexus-code#447). One-shot: present
    # ONLY on the cycle right after a roll that actually moved ≥1 file (the
    # roll task fires compose_emit forward), consumed on read so it surfaces
    # exactly once — a genuine trigger (worth an emit on an otherwise-quiet
    # workspace), never a standing/periodic one.
    local reports_roll_now=""
    reports_roll_now=$(_reports_roll_emit_section "$REPORTS_ROLL_NOTICE_FILE" 2>/dev/null || true)

    # Arm-watcher-supervisor reminder (mutual-liveness). A STANDING
    # condition reflecting the live supervisor-heartbeat freshness:
    # non-empty once the heartbeat is stale (> stale_seconds, default 90)
    # or absent, empty the instant the orchestrator's Monitor touches it.
    # It is RENDER-ONLY (see the gate note below) — it does NOT itself
    # trigger an emit; it rides emits caused by real signal or the periodic
    # full-state cadence, and content-hash dedup collapses repeats while it
    # remains unarmed. Because of that, the post-orchestrator-respawn gap is
    # NOT closed by this reminder on a quiet workspace (worst case it waits
    # for the full-state cadence); the deterministic close is the turn-1
    # respawn-prompt arm step injected by respawn_agent (issue #238).
    local supervisor_arm_now=""
    supervisor_arm_now=$(_supervisor_arm_emit_section "$WATCHER_SUPERVISOR_HEARTBEAT" \
        "${MONITOR_WATCHER_SUPERVISOR_HEARTBEAT_STALE_SECONDS:-90}" "$NEXUS_ROOT" 2>/dev/null || true)

    # supervisor_arm_now is render-only (NOT a gate trigger): the standing
    # arm-reminder rides on emits caused by real signal / the periodic
    # full-state cadence; it must never force a quiet-workspace emit.
    if [[ -n "$local_diff" || -n "$gh_now" || -n "$bell_now" || -n "$idle_now" \
          || -n "$pending_now" || -n "$requests_now" || -n "$cc_update_now" || -n "$version_drift_now" || -n "$service_health_now" || -n "$reports_roll_now" || $full_state_due -eq 1 ]]; then
        if (( signal_from_diff == 1 )) \
           || [[ -n "$gh_now" || -n "$bell_now" || -n "$idle_now" || -n "$pending_now" || -n "$requests_now" || -n "$cc_update_now" || -n "$version_drift_now" || -n "$service_health_now" || -n "$reports_roll_now" ]] \
           || (( full_state_due == 1 )); then
            local resurface_only=0 reason archive_tag
            if [[ -z "$local_diff" && -z "$bell_now" ]]; then
                resurface_only=1
            fi
            reason="poll"
            archive_tag=""
            if (( full_state_due == 1 )) \
               && [[ -z "$local_diff" && -z "$gh_now" && -z "$bell_now" && -z "$idle_now" ]]; then
                reason="poll-full-state"
                archive_tag="full-state"
            elif (( resurface_only == 1 )); then
                reason="poll-resurface"
                archive_tag="resurface"
            fi
            # A cc-update-driven emit gets its own reason/tag so the
            # forensic archive is not mislabelled "resurface" — the
            # signal is genuinely new, not a re-paste of prior state.
            if [[ -n "$cc_update_now" && -z "$local_diff" && -z "$gh_now" \
                  && -z "$bell_now" && -z "$idle_now" && -z "$pending_now" \
                  && -z "$version_drift_now" && $full_state_due -ne 1 ]]; then
                reason="poll-cc-update"
                archive_tag="cc-update"
            fi
            # Same forensic labelling for a drift-ask-driven emit: the
            # signal is genuinely new, not a re-paste of prior state.
            if [[ -n "$version_drift_now" && -z "$local_diff" && -z "$gh_now" \
                  && -z "$bell_now" && -z "$idle_now" && -z "$pending_now" \
                  && -z "$cc_update_now" && $full_state_due -ne 1 ]]; then
                reason="poll-component-drift"
                archive_tag="component-drift"
            fi
            # Same forensic labelling for a service-health-driven emit:
            # the down/flapping/recovered signal is genuinely new.
            if [[ -n "$service_health_now" && -z "$local_diff" && -z "$gh_now" \
                  && -z "$bell_now" && -z "$idle_now" && -z "$pending_now" \
                  && -z "$cc_update_now" && -z "$version_drift_now" && $full_state_due -ne 1 ]]; then
                reason="poll-service-health"
                archive_tag="service-health"
            fi
            # Same forensic labelling for a request-inbox-driven emit: a
            # claimed request re-surfacing is a genuine worker→orchestrator
            # ask, not a re-paste of prior state (agent-channel RFC Part B).
            if [[ -n "$requests_now" && -z "$local_diff" && -z "$gh_now" \
                  && -z "$bell_now" && -z "$idle_now" && -z "$pending_now" \
                  && -z "$cc_update_now" && -z "$version_drift_now" \
                  && -z "$service_health_now" && $full_state_due -ne 1 ]]; then
                reason="poll-requests"
                archive_tag="requests"
            fi
            # Same forensic labelling for an auto-roll-driven emit: the
            # reports-archived breadcrumb is a genuinely new one-shot event.
            if [[ -n "$reports_roll_now" && -z "$local_diff" && -z "$gh_now" \
                  && -z "$bell_now" && -z "$idle_now" && -z "$pending_now" \
                  && -z "$cc_update_now" && -z "$version_drift_now" \
                  && -z "$service_health_now" && -z "$requests_now" && $full_state_due -ne 1 ]]; then
                reason="poll-reports-roll"
                archive_tag="reports-roll"
            fi
            local EMIT_SIG_NONCE
            EMIT_SIG_NONCE=$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 6)
            compose_report "$reason" "$local_diff" "$gh_now" "$bell_now" "$idle_now" "$full_state_lines" "$pending_now" "" "$cc_update_now" "" "$version_drift_now" "$service_health_now" "" "$supervisor_arm_now" "$requests_now" "$reports_roll_now" > "$emit_body"
            cp "$emit_body" "$LAST_CHANGE"
            local archive_path
            archive_path=$(archive_emit "$emit_body" "$archive_tag")
            log "emit archive=$(basename "$archive_path") reason=${reason}"
            # Content-hash dedup gate. The emit-decision tree above
            # already filters down to "this is signal"; suppress
            # when the body's stable hash matches a recently-emitted
            # one (hash ring) within the configured quiet window.
            # Bypassed when the body carries operator-attention
            # signal (eligible comments). The archive write above
            # happens unconditionally so the forensic record stays
            # complete; only the paste is gated. State-record runs
            # only after a successful paste so retries of an
            # undelivered body are not poisoned.
            #
            # full_state_due bodies SKIP this gate: the canonical
            # identity check + safety floor (issue #104) already
            # adjudicated them — what survives is either a genuine
            # canonical change or the safety-floor timeout
            # HEARTBEAT, and the (default-24h) quiet window here
            # would swallow that heartbeat, starving the
            # orchestrator-liveness paste clock (see the
            # dead_threshold clamp at startup for the arithmetic).
            if (( full_state_due != 1 )) \
               && _compose_emit_should_suppress "$emit_body" "$reason"; then
                :
            elif _over_limit_orchestrator_paused; then
                log "emit paste suppressed: orchestrator over-limit (archive=$(basename "$archive_path"))"
            elif paste_with_retry "$TARGET" "$emit_body"; then
                log "pasted to ${TARGET}"
                _emit_delivery_ok
                _compose_emit_record_emit "$emit_body"
                # Delivery-stamp the request ids this paste actually
                # carried (stamp-on-paste, your-org/nexus-code#483) —
                # same post-paste-only discipline as the emit-dedup
                # record above: a suppressed or failed paste writes no
                # cooldown, so the request stays due and re-surfaces
                # next cycle instead of aging silently. Then consume the
                # requests stage file: it now describes a delivered set,
                # and a fast follow-up compose (the 5s engage override)
                # would otherwise re-read it and — request bodies bypass
                # the dedup gate — re-paste a duplicate inside the ≤10s
                # window before the next requests_poll tick regenerates
                # it from the claimed files + fresh stamps. Worst case
                # for the truncation itself is wiping a render that
                # landed in the same instant, which the next tick
                # re-renders from source ≤10s later — nothing is lost.
                if [[ -n "$requests_now" ]]; then
                    requests_commit_emitted "$emit_body"
                    : > "$stage_dir/requests_poll.out" 2>/dev/null || true
                fi
                _respawn_loop_reset "$RESPAWN_HISTORY"
                rm -f "$RESPAWN_TRIPPED"
                _respawn_consec_reset "$RESPAWN_CONSEC_COUNTER"
                rm -f "$RESPAWN_SLOW_GRIND_TRIPPED"
                if (( full_state_due == 1 )); then
                    date +%s > "$FULL_STATE_STAMP" 2>/dev/null || true
                    if [[ -n "$full_state_canonical" ]]; then
                        printf '%s' "$full_state_canonical" > "${FULL_STATE_CANONICAL_CACHE}.tmp" \
                            && mv "${FULL_STATE_CANONICAL_CACHE}.tmp" "$FULL_STATE_CANONICAL_CACHE" 2>/dev/null || true
                    fi
                fi
            else
                local rc=$?
                case $rc in
                    1) log "tmux not available; archive only" ;;
                    2) log "target window '${TARGET}' missing; archive only" ;;
                    4) log "paste submitted but signature not visible (VI mode?); archive only" ;;
                    *) log "paste failed (rc=$rc); archive only" ;;
                esac
                # Fail LOUD, never silent: track the delivery failure, alert
                # out-of-band, and — past the limit — self-heal restart
                # (cooldown-guarded). "archive only" with no recovery was
                # exactly the silent-drop that wedged delivery on 2026-06-18.
                _emit_delivery_fail "$rc"
            fi
            if [[ -n "$bell_now" ]]; then
                clear_bells "$(printf '%s\n' "$bell_now" | awk -F'\t' '{print $1}')"
                # Refresh the snapshot post-clear so the next diff
                # absorption sees the post-clear tmux state. v1
                # called snapshot_local inline here too; this
                # subshell-local refresh is cheap relative to
                # bell-clear frequency.
                snapshot_local > "$current_tmp" 2>/dev/null || true
            fi
        else
            log "suppressed emit: ${noise_summary:-noise-only}"
        fi
        if [[ -n "$local_diff" || -n "$bell_now" ]]; then
            # Atomic baseline write so a concurrent reader
            # (next compose_emit's `cmp`) never sees a torn file.
            cp "$current_tmp" "${BASELINE}.tmp.$$" 2>/dev/null \
                && mv "${BASELINE}.tmp.$$" "$BASELINE" 2>/dev/null || true
        fi
    fi

    rm -f "$current_tmp" 2>/dev/null || true
    # Proof-of-working-cycle stamp (nexus-code#236, re-homed by #491).
    # Reaching here means a HEALTHY cycle completed — staged a snapshot, ran
    # the emit-decision tree, and pasted / suppressed / found-nothing (ALL
    # healthy outcomes; a quiet "found-nothing" cycle is exactly the
    # token-efficient silence we WANT, and it still proves the loop works).
    # A wedged cycle (reaped scratch dir, missing snapshot, a hang the
    # watchdog killed) returns earlier and does NOT stamp, so the CYCLE
    # signal goes stale past _watcher_cycle_cutoff and the watcher reads
    # WEDGED — while the liveness heartbeat (ticker) keeps proving the
    # process itself is alive. _cycle_bump also records the measured loop
    # period that calibrates those cutoffs. bump_heartbeat stays as a belt
    # for ticker-degraded runs and --once.
    _cycle_bump
    bump_heartbeat
    return 0
}

# ---- task registration --------------------------------------
# NB: still NO `heartbeat` scheduler task. The liveness heartbeat is a
# background ticker (nexus-code#491) whose cadence cannot depend on this
# scheduler; the functional proof #236 wanted lives in the CYCLE signal
# (_cycle_bump at each correct compose-cycle end), and the silent-stall
# class is caught by the progress/cycle cutoffs (_watcher_wedged), not
# by starving the liveness signal.
_schedule_task over_limit_wakes        5            _v2_task_over_limit_wakes       --class cheap
_schedule_task target_window           2            _v2_task_target_window_probe    --class cheap
_schedule_task orchestrator_liveness   5            _v2_task_orchestrator_liveness  --class cheap
_schedule_task pending_decisions       10           _v2_task_pending_decisions      --class cheap
_schedule_task requests_poll           10           _v2_task_requests_poll          --class cheap
_schedule_task bell_windows            30           _v2_task_bell_windows           --class cheap
_schedule_task prune_archive           600          _v2_task_prune_archive          --class cheap
# Async tasks. Each output captured to <name>.out by
# _scheduler_fire_async (atomic .tmp + rename).
_schedule_task detect_unstick          10           _v2_task_detect_unstick         --class medium    --async
_schedule_task snapshot_local          30           _v2_task_snapshot_local         --class medium    --async
_schedule_task idle_section            30           _v2_task_idle_section           --class expensive --async
_schedule_task over_limit_scan         60           _v2_task_over_limit_scan        --class expensive --async
# Event-fetch split (issue #181). Webhook (App-JWT bucket) is the
# primary 15 s source; GraphQL backstop runs at 600 s on the
# installation bucket. Compose_emit reads both staging files.
_schedule_task deliveries_poll         15           _v2_task_deliveries_poll        --class medium    --async
_schedule_task github_poll             600          _v2_task_github_poll            --class expensive --async
_schedule_task full_state_snap         600          _v2_task_full_state_snap        --class expensive --async
# Automatic reports-archive roll (your-org/nexus-code#447). Fires on the
# first tick (next_fire seeds to 0 → startup migration/self-heal) and then
# hourly by default; the day-stamp gate inside the task makes every tick but
# the first-of-day a cheap no-op (date compare, no scan). --async because the
# once-per-day roll touches the NFS reports dir. ON by default; disabled via
# monitor.reports_roll.enabled=false or interval_seconds=0.
if [[ "$MONITOR_REPORTS_ROLL_ENABLED" == "true" || "$MONITOR_REPORTS_ROLL_ENABLED" == "1" ]] \
   && (( MONITOR_REPORTS_ROLL_INTERVAL_SECONDS > 0 )); then
    _schedule_task reports_roll        "$MONITOR_REPORTS_ROLL_INTERVAL_SECONDS" \
                                       _v2_task_reports_roll           --class medium    --async
else
    log "reports-roll: auto-roll disabled (monitor.reports_roll.enabled=${MONITOR_REPORTS_ROLL_ENABLED}, interval=${MONITOR_REPORTS_ROLL_INTERVAL_SECONDS}); manual 'ng reports-roll' still available"
fi
# Functional-check signal (other-nexus-lessons L1). 600 s cadence: same
# cost class as github_poll (one or two `gh api reactions` calls per
# fire on a typical workspace); deeper-than-pid wedge detection. Set
# MONITOR_FUNCTIONAL_SLA_SECONDS=0 to disable.
_schedule_task functional_check        600          _v2_task_functional_check       --class expensive --async
# cc update-detection (GATED self-update, detect→inform). 24h default
# cadence — one npm-registry round-trip per fire; the signal it
# maintains is surfaced once per candidate by compose_emit. Registered
# only when the interval is > 0 (monitor.cc_update.interval_seconds=0
# disables detection). NEVER auto-bumps.
if (( MONITOR_CC_UPDATE_INTERVAL_SECONDS > 0 )); then
    _schedule_task cc_version_check     "$MONITOR_CC_UPDATE_INTERVAL_SECONDS" \
                                                       _v2_task_cc_version_check       --class expensive --async
else
    log "cc-update: detection disabled (monitor.cc_update.interval_seconds=0)"
fi
# Autonomous daily cc-update routine (DRIVE half, your-nexus#207).
# OFF by default — an operator turns it on deliberately
# (monitor.cc_auto_update.enabled: true). The interval is the
# due-window poll cadence; the once-per-day gate lives in the task.
#
# REGISTRATION-TIME ONLY (nexus-code#513): MONITOR_CC_AUTO_UPDATE_ENABLED
# is resolved ONCE, at watcher startup (_config.sh), and consumed here to
# decide whether the task is scheduled AT ALL. Toggling the config on a
# RUNNING watcher is INERT — the already-scheduled task keeps ticking and
# its restart reconcile keeps firing. It therefore CANNOT serve as an
# emergency stop for an unwanted orchestrator restart (it nearly got
# applied as one twice on 2026-07-10, and would have done nothing until
# the very watcher restart the hold existed to avoid). The tick-checked
# off switch is the restart-hold marker:
#     monitor/cc-auto-update-apply.sh hold --reason "…" [--until-version X]
if [[ "$MONITOR_CC_AUTO_UPDATE_ENABLED" == "true" ]] \
   && (( MONITOR_CC_AUTO_UPDATE_CHECK_INTERVAL_SECONDS > 0 )); then
    _schedule_task cc_auto_update      "$MONITOR_CC_AUTO_UPDATE_CHECK_INTERVAL_SECONDS" \
                                                       _v2_task_cc_auto_update         --class expensive --async
    log "cc-auto-update: enabled (fire_time=$MONITOR_CC_AUTO_UPDATE_FIRE_TIME check_interval=${MONITOR_CC_AUTO_UPDATE_CHECK_INTERVAL_SECONDS}s window=$CC_AUTO_WINDOW)"
else
    log "cc-auto-update: disabled (monitor.cc_auto_update.enabled=${MONITOR_CC_AUTO_UPDATE_ENABLED})"
fi
# Version-aware component restart (issue #186). Registered only when
# the master enable is on AND the interval is > 0; either off-switch
# restores the manual pull-then-restart discipline wholesale.
if [[ "$MONITOR_VERSION_RESTART_ENABLED" == "true" ]] \
   && (( MONITOR_VERSION_CHECK_INTERVAL_SECONDS > 0 )); then
    _schedule_task version_check       "$MONITOR_VERSION_CHECK_INTERVAL_SECONDS" \
                                                       _v2_task_version_check          --class medium    --async
else
    log "version-restart: disabled (monitor.version_restart.enabled=${MONITOR_VERSION_RESTART_ENABLED}, interval=${MONITOR_VERSION_CHECK_INTERVAL_SECONDS})"
fi
# Continuous service-health watch (service-health-watch). Registered only
# when the master enable is on AND the interval is > 0; either off-switch
# falls back to supervisor-only self-heal with no continuous detection or
# orchestrator emit.
if [[ "$MONITOR_SERVICE_HEALTH_ENABLED" == "true" ]] \
   && (( MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS > 0 )); then
    _schedule_task service_health      "$MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS" \
                                                       _v2_task_service_health         --class medium    --async
else
    log "service-health: disabled (monitor.service_health.enabled=${MONITOR_SERVICE_HEALTH_ENABLED}, interval=${MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS})"
fi
# Watcher-supervision is mutual-liveness now (no watcher-side task): the
# orchestrator arms the supervisor Monitor, and the `--- arm watcher
# supervisor ---` emit reminder (composed in compose_report when the
# supervisor heartbeat is stale) is the watcher's only role here.
# Cadence = MONITOR_INTERVAL so the steady-state emit cadence is
# the operator-tunable knob; --async so the ~5–20 s compose/paste
# body never holds the scheduler's sync slot. target_window
# force-fires this on rc=2.
_schedule_task compose_emit            "$INTERVAL"  _v2_task_compose_emit           --class medium    --async

# Post-tick hook: compose_emit is async, so its body cannot use the
# in-memory scheduler-override primitive (subshell mutations to the
# parent's associative arrays are lost). Instead, the parent shell
# consults the on-disk source files at the end of every tick. New
# deliveries-queue appends and non-empty github_poll fires both pull
# compose_emit forward via `_schedule_fire_now` + 5 s-for-60 s override
# — same primitive the target-absent probe (rc=2) uses, so the
# scheduler test suite §8d behavior applies.
_scheduler_post_tick_hook() {
    _compose_emit_nudge_check \
        "${STATE_DIR}/deliveries-queue.lines" \
        "${V2_STAGE_DIR}/github_poll.out" \
        "${V2_STAGE_DIR}/requests_poll.out" \
        >/dev/null 2>&1 || true
}

# --once: drain pipeline. First tick fires the data-gathers
# (sync ones write staging immediately; async ones launch
# subshells); compose_emit is disabled for this tick so a
# previous invocation's left-over staging files don't trigger a
# pre-drain emit. We then drain the async fires so staging is
# fully populated, re-enable + force-fire compose_emit, tick
# again, and drain compose_emit's own subshell. Net effect: one
# --once invocation produces a single emit equivalent to one
# steady-state poll.
if (( ONCE == 1 )); then
    _schedule_disable compose_emit
    _scheduler_tick; sched_rc=$?
    if (( sched_rc == 99 )); then
        log "scheduler shutdown (signal during once-tick)"
        exit 0
    fi
    _scheduler_drain_async 60 || log "--once: async drain exceeded 60 s budget; proceeding"
    _schedule_enable compose_emit
    _schedule_fire_now compose_emit
    _scheduler_tick; sched_rc=$?
    if (( sched_rc == 99 )); then
        log "scheduler shutdown (signal during compose tick)"
        exit 0
    fi
    _scheduler_drain_async 60 || log "--once: compose drain exceeded 60 s budget; proceeding"
    log "--once: exiting after drain pipeline"
    exit 0
fi

while true; do
    # Probe FIRST, every cycle, with a fresh open(). On a read-only project
    # FS the whole scheduler is suspended — every task it runs writes to the
    # project tree, so running them would only produce a storm of EROFS and
    # a heartbeat that cannot be bumped. We keep looping (a live watcher is
    # what notices recovery, and what answers "what is wrong" for everyone
    # else) and re-probe on a short cadence until the mount comes back.
    if ! _fs_guard_tick; then
        # Validate the interval: a non-numeric value would make `sleep` error
        # out instantly and turn the degraded loop into a busy-spin — burning
        # a core during an outage, when the machine is already unhappy.
        _fs_poll="${MONITOR_FS_DEGRADED_POLL_SECONDS:-15}"
        [[ "$_fs_poll" =~ ^[0-9]+$ ]] && (( _fs_poll > 0 )) || _fs_poll=15
        sleep "$_fs_poll"
        continue
    fi

    _scheduler_tick; sched_rc=$?
    # Forward-progress stamp + liveness-ticker self-heal (nexus-code#491).
    # The stamp is what separates a BUSY loop from a WEDGED one: it stops
    # advancing exactly when this loop stops executing. The ticker check
    # respawns a crashed ticker within one iteration (~10s), so a ticker
    # death can never mature into a stale-heartbeat false DOWN.
    _progress_bump loop-tick
    _start_heartbeat_ticker
    # Refresh the cross-host instance beacon once per loop iteration (the
    # scheduler caps its sleep at ~10s, so this fires well within the
    # staleness window), but SELF-FENCE first (D4): if the beacon on disk now
    # belongs to a DIFFERENT, still-fresh instance, we have been superseded
    # (our loop wedged past the staleness window, a starter on another host
    # took over) — stand down instead of blindly overwriting the winner's
    # beacon and re-creating two live cockpits. The step is cheap (one read of
    # a tiny file) and best-effort on the write side; only a proven
    # supersession makes it return non-zero. See _nexus_instance_beacon_loop_step.
    if [[ -n "${INSTANCE_LOCK_FD:-}" && -n "${INSTANCE_HEARTBEAT_FILE:-}" ]]; then
        if ! _nexus_instance_beacon_loop_step "$INSTANCE_HEARTBEAT_FILE" \
                "$(hostname 2>/dev/null || echo unknown)" \
                "${NEXUS_INSTANCE_NONCE:-}" \
                "$(date +%s 2>/dev/null || echo 0)" \
                "$(_nexus_instance_staleness_window)"; then
            INSTANCE_SUPERSEDED=1
            _fh_beacon=$(cat "$INSTANCE_HEARTBEAT_FILE" 2>/dev/null)
            _fh_rh=$(_nexus_instance_lock_field "$_fh_beacon" host) || _fh_rh="?"
            _fh_rts=$(_nexus_instance_lock_field "$_fh_beacon" ts) || _fh_rts="?"
            _fh_win=$(_nexus_instance_staleness_window)
            log "SELF-FENCE: a newer nexus instance (host ${_fh_rh}, beacon as of ${_fh_rts}) has taken over this NEXUS_ROOT's cross-host beacon."
            log "  This instance's loop was superseded (likely a wedge past the ${_fh_win}s staleness window). Standing down cleanly — NOT overwriting the successor's beacon."
            log "  monitor/.state is shared over NFS; two cockpits would race it (double GitHub writes, emit races). One cockpit per NEXUS_ROOT is the supported topology."
            break
        fi
    fi
    if (( sched_rc == 99 )); then
        log "scheduler shutdown (signal observed in tick)"
        break
    fi
    _scheduler_sleep_until_next; sched_rc=$?
    if (( sched_rc == 99 )); then
        log "scheduler shutdown (signal observed in sleep)"
        break
    fi
done
exit 0
