#!/usr/bin/env bash
# monitor/watcher/spawn-fresh-orchestrator.sh
#
# Watcher-driven last-ditch orchestrator recovery. Layered on top of
# PR #147's session-id pin: that PR ensures `claude --continue` picks
# the right jsonl at restart; this script ensures the orchestrator's
# absence is *detectable* and *recoverable* without operator
# intervention even when --continue can't help (wrong session
# resumed, hook misconfigured, claude wedged on the splash, etc.).
#
# What it does, in order:
#   1. Compose a situation report (snapshot of tmux windows, recent
#      reports, dashboard pointer, last watcher emit signature).
#   2. Kill the existing `orchestrator` (or configured target) tmux window —
#      best-effort, ignoring failures (the window may already be gone).
#   3. Generate a /tmp launcher script that exec's claude. The resume
#      mode is resolved from the orchestrator session-id pin (shared
#      `_respawn_choose_resume_mode`): a valid pin →
#      `--resume <pinned-sid>` (deterministic — resumes the EXACT prior
#      session); a missing/stale pin → cold spawn (NO --resume / NO
#      --continue). Issue #200: the old `--continue` fallback grabbed
#      the arbitrary freshest jsonl in the project dir, which
#      resurrected a transient recovery session during the 2026-05-29
#      crash recovery — a cold spawn is the safe degradation. With
#      `--fresh` (operator emergency: jsonl corrupt, hook
#      misconfigured, deliberate reset) the spawn is always cold.
#      CLAUDE.md, skills, and the orchestrator settings file (incl. PR
#      #147's session-pin hook) load fresh either way.
#   4. Spawn the target tmux window with the launcher as its command.
#   5. Wait for claude's TUI to come up via repeated pane-state.sh
#      probes (state=empty or state=idle ⇒ the input box is wired and
#      ready to accept paste). 30 s budget; on timeout, attempt the
#      paste anyway and log the timeout — current behaviour is no
#      worse. After load-buffer + paste-buffer + Enter, poll pane-state
#      again: state=busy or state=user-typing confirms the turn
#      submitted. If still `empty` after a couple of seconds, retry
#      the Enter once (no further retries — a wedged claude won't be
#      unstuck by hammering Enter).
#   6. Write a cooldown marker so the caller (main.sh's poll loop)
#      can throttle repeat attempts.
#   7. Log a structured event for post-hoc audit.
#
# Usage:
#   monitor/watcher/spawn-fresh-orchestrator.sh --target <window>
#                                              [--reason <text>]
#                                              [--previous-sid <sid>]
#                                              [--fresh]
#
# Env:
#   NEXUS_ROOT                              required when not running
#                                           from the canonical layout
#   STATE_DIR                               defaults to
#                                           $NEXUS_ROOT/monitor/.state
#   FRESH_SPAWN_CLAUDE_WAIT_SECONDS         legacy hardcoded wait;
#                                           ignored when the readiness
#                                           probe is available. Set to 0
#                                           in tests to skip both.
#   FRESH_SPAWN_READINESS_BUDGET_SECONDS    pane-state readiness probe
#                                           budget; default 30
#   FRESH_SPAWN_READINESS_POLL_SECONDS      poll interval inside the
#                                           budget; default 1
#   FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS   post-paste verification
#                                           budget for the busy/typing
#                                           transition; default 3
#
# Exit codes:
#   0  spawned + pasted successfully
#   1  bad usage / NEXUS_ROOT missing
#   2  tmux not on PATH
#   3  tmux new-window failed
#   4  paste step failed (window spawned, situation report not delivered)
#
# The cooldown marker is written even on rc>=3 — the caller's gate
# treats "we tried" as the throttle signal, not "we succeeded". A
# wedged tmux that fails new-window on every poll would otherwise
# burn through the loop with no backoff.

set -uo pipefail

_script_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
_monitor_dir=$(cd "$_script_dir/.." && pwd)
_nexus_root_default=$(cd "$_monitor_dir/.." && pwd)

# `_ensure_service_log` (nexus-code#484/#509): log() below appends to
# watcher.log — never create it group-writable.
# shellcheck source=../_log-mode.sh
source "$_monitor_dir/_log-mode.sh"

NEXUS_ROOT="${NEXUS_ROOT:-$_nexus_root_default}"
TARGET=""
REASON=""
PREVIOUS_SID=""
# Default to continue-by-default; `--fresh` opts in to the old
# discard-context behaviour for true emergencies. See header.
FRESH=0

while (( $# > 0 )); do
    case "$1" in
        --target)       TARGET="${2:-}"; shift 2 ;;
        --reason)       REASON="${2:-}"; shift 2 ;;
        --previous-sid) PREVIOUS_SID="${2:-}"; shift 2 ;;
        --fresh)        FRESH=1; shift ;;
        -h|--help)      sed -n '2,75p' "$0"; exit 0 ;;
        *) echo "spawn-fresh-orchestrator.sh: unknown flag: $1" >&2; exit 1 ;;
    esac
done

[[ -n "$TARGET" ]] || { echo "spawn-fresh-orchestrator.sh: --target required" >&2; exit 1; }
[[ -d "$NEXUS_ROOT" ]] || { echo "spawn-fresh-orchestrator.sh: NEXUS_ROOT not a directory: $NEXUS_ROOT" >&2; exit 1; }
command -v tmux >/dev/null 2>&1 || { echo "spawn-fresh-orchestrator.sh: tmux required" >&2; exit 2; }

STATE_DIR="${STATE_DIR:-$NEXUS_ROOT/monitor/.state}"
mkdir -p "$STATE_DIR" || { echo "spawn-fresh-orchestrator.sh: cannot create $STATE_DIR" >&2; exit 1; }

# Shared respawn primitives (issue #161). Single source of truth for
# launcher composition, tmux spawn, readiness probe, paste-buffer
# delivery, and Enter-retry verification. The function we call is
# `_respawn_orchestrator`.
# shellcheck disable=SC1091
. "$_script_dir/_respawn.sh"

# Resolve the effective resume mode up front so the situation report,
# the launcher flags, and the structured event line all agree.
#   --fresh (operator/emergency)  → cold spawn, always.
#   otherwise                     → ask the shared pin-resolver: a
#                                   valid pin → `--resume <sid>`
#                                   (deterministic); missing/stale pin
#                                   → cold spawn (issue #200 — NOT
#                                   `--continue`, which grabs the
#                                   arbitrary freshest jsonl).
RESUME_SID=""
if (( FRESH == 1 )); then
    RESUME_MODE="fresh"
else
    _resume_choice=$(_respawn_choose_resume_mode "$NEXUS_ROOT")
    RESUME_MODE="${_resume_choice%%$'\t'*}"
    RESUME_SID="${_resume_choice#*$'\t'}"
    [[ "$RESUME_MODE" == "resume" ]] || RESUME_MODE="fresh"
fi
# Duplicate-orchestrator guard (your-org/your-nexus#206): the pinned
# orchestrator session may only ever be resumed into the CONFIGURED
# coordinator window. Every production caller passes the
# config-resolved target, so a mismatch means a manual or buggy
# invocation — downgrade to a cold spawn, loudly, rather than running
# `claude --resume <orchestrator-sid>` into some other window (the
# resolver half of that incident lives in spawn-worker.sh; this is
# the recovery-side backstop). Resolution order mirrors
# monitor/watcher/_config.sh: MONITOR_TARGET env → config → default.
if [[ "$RESUME_MODE" == "resume" ]]; then
    _expected_target="${MONITOR_TARGET:-}"
    if [[ -z "$_expected_target" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        _expected_target=$("$NEXUS_ROOT/config/load.sh" monitor.target_window orchestrator 2>/dev/null || true)
    fi
    _expected_target="${_expected_target:-orchestrator}"
    if [[ "$TARGET" != "$_expected_target" ]]; then
        echo "spawn-fresh-orchestrator: REFUSING to resume the pinned orchestrator session ($RESUME_SID) into non-coordinator window '$TARGET' (configured coordinator: '$_expected_target') — downgrading to a COLD spawn (your-org/your-nexus#206)" >&2
        RESUME_MODE="fresh"
        RESUME_SID=""
    fi
fi
# A cold spawn (operator --fresh OR pin-can't-identify) gets the full
# re-onboarding report; only a positive `resume` keeps the terse
# "context is intact" wording.
COLD=1
[[ "$RESUME_MODE" == "resume" ]] && COLD=0
# Surface the pin-derived sid in the report when the operator didn't
# pass one explicitly.
[[ -z "$PREVIOUS_SID" && "$RESUME_MODE" == "resume" ]] && PREVIOUS_SID="$RESUME_SID"

COOLDOWN_FILE="$STATE_DIR/orchestrator-fresh-spawn.last"
REPORT_FILE="$STATE_DIR/orchestrator-fresh-spawn.last-report.md"
LOGFILE="$STATE_DIR/watcher.log"

# `pane-state.sh` ships next to this script under monitor/. Used by
# the shared helper for both the pre-paste readiness probe and the
# post-paste verification. A missing or non-executable helper degrades
# to the legacy fixed-sleep + best-effort-paste behaviour (logged once
# inside the helper). Path is env-overridable so tests can substitute
# a stub without touching the real monitor/ tree.
PANE_STATE="${PANE_STATE_BIN:-$_monitor_dir/pane-state.sh}"
export PANE_STATE_BIN="$PANE_STATE"

log() {
    local msg
    msg="[$(date -Is)] spawn-fresh-orchestrator: $*"
    echo "$msg" >&2
    _ensure_service_log "$LOGFILE"
    printf '%s\n' "$msg" >> "$LOGFILE" 2>/dev/null || true
}

# Compose the situation report onto stdout. Sections roughly mirror
# the operator's recovery checklist: "what tmux windows are open",
# "what reports were just filed", "is the dashboard fresh", "what
# did the watcher last emit". Kept short — the goal is a recovery
# spawn that can re-orient in one turn, not a full state archive.
#
# Branches on $COLD: a positive `resume` (pin-identified session) is
# terse (resumed agent has its full context; only needs to know why
# the window was respawned); a cold spawn (operator --fresh OR the pin
# couldn't identify a session) keeps the full re-onboarding preamble.
_compose_situation_report() {
    local now_iso
    now_iso=$(date -Is)
    if (( COLD == 1 )); then
        printf 'You are the nexus orchestrator. This is a **recovery spawn** — your prior session was unrecoverable or could not be positively identified, so you were started fresh (no `--resume`, no `--continue`). You have NO resumed conversation context.\n'
        printf '\n'
        printf 'Read CLAUDE.md and `skills/nexus.*` for your role; `monitor/agent-prompt.md` has your wake protocol.\n'
    else
        printf 'The watcher restarted your orchestrator window. Your prior conversation context has been resumed via `claude --resume %s`, so you already know what you were doing.\n' "$RESUME_SID"
        printf '\n'
        printf 'The kill+resume cycle happens when the watcher concludes the orchestrator is unresponsive to its pastes — most often a wedged TUI or a hung tool call. Re-orient quickly and resume.\n'
    fi
    printf '\n'
    printf '## Recovery context\n\n'
    printf -- '- Spawned at: %s\n' "$now_iso"
    printf -- '- Mode: %s\n' "$RESUME_MODE"
    [[ -n "$REASON" ]] && printf -- '- Reason: %s\n' "$REASON"
    [[ -n "$PREVIOUS_SID" ]] && printf -- '- Previous orchestrator session-id: %s\n' "$PREVIOUS_SID"
    printf -- '- Nexus root: %s\n' "$NEXUS_ROOT"
    printf '\n'

    printf '## Current tmux windows\n\n'
    printf '```\n'
    tmux list-windows -F '#I #W' 2>/dev/null || printf '(tmux list-windows failed)\n'
    printf '```\n\n'

    printf '## In-flight worker windows vs. recent reports\n\n'
    # Cross-reference: tmux windows that aren't the configured target
    # window ($TARGET) or the reserved names `watcher` / `orchestrator`
    # (or its legacy alias `claude`) / `monitor` against the most recent
    # reports. Lets the new orchestrator pick which workers it needs to
    # re-engage. The $TARGET exclusion matters when the operator
    # configured a non-default `monitor.target_window` — the window we
    # just spawned must not list itself as an in-flight worker.
    local reports_dir="$NEXUS_ROOT/reports"
    local windows
    windows=$(tmux list-windows -F '#W' 2>/dev/null \
              | grep -vE '^(watcher|orchestrator|claude|monitor)$' \
              | grep -vxF "$TARGET" \
              | sort -u || true)
    if [[ -n "$windows" ]]; then
        printf 'Worker windows currently in tmux:\n'
        while IFS= read -r w; do
            [[ -z "$w" ]] && continue
            local match=""
            if [[ -d "$reports_dir" ]]; then
                match=$(find "$reports_dir" -maxdepth 1 -type f -name "*${w}*.md" \
                        -printf '%T@\t%f\n' 2>/dev/null | sort -nr | head -1 | cut -f2-)
            fi
            if [[ -n "$match" ]]; then
                printf -- '- %s — most recent report: %s\n' "$w" "$match"
            else
                printf -- '- %s — no matching report under reports/\n' "$w"
            fi
        done <<< "$windows"
    else
        printf '(no worker windows currently in tmux)\n'
    fi
    printf '\n'

    printf '## Recent reports (top 5 by mtime)\n\n'
    if [[ -d "$reports_dir" ]]; then
        local entries
        entries=$(find "$reports_dir" -maxdepth 1 -type f -name '*.md' \
                  -printf '%T@\t%p\n' 2>/dev/null | sort -nr | head -5)
        if [[ -n "$entries" ]]; then
            while IFS=$'\t' read -r _ path; do
                local rel="${path#$NEXUS_ROOT/}"
                local first
                first=$(head -n1 "$path" 2>/dev/null | sed 's/[[:space:]]*$//')
                printf -- '- %s — %s\n' "$rel" "${first:-(empty)}"
            done <<< "$entries"
        else
            printf '(no reports)\n'
        fi
    else
        printf '(no reports dir at %s)\n' "$reports_dir"
    fi
    printf '\n'

    printf '## Dashboard pointer\n\n'
    local dash_file="$STATE_DIR/dashboard.json"
    if [[ -f "$dash_file" ]]; then
        local age_s
        age_s=$(( $(date +%s) - $(date +%s -r "$dash_file" 2>/dev/null || echo 0) ))
        printf -- '- %s (age: %ds)\n' "$dash_file" "$age_s"
    else
        printf '(no dashboard.json — run `monitor/ng dashboard get`)\n'
    fi
    printf '\n'

    printf '## Latest watcher emit signature\n\n'
    local snap="$STATE_DIR/last-snapshot.txt"
    if [[ -f "$snap" ]]; then
        printf '```\n'
        head -c 1200 "$snap" 2>/dev/null
        printf '\n```\n'
    else
        printf '(no last-snapshot.txt yet)\n'
    fi
    printf '\n'

    if (( COLD == 1 )); then
        printf '## First actions\n\n'
        printf '1. Run `monitor/watcher/bootstrap.sh` to verify watcher health and ingest missed diffs.\n'
        printf '2. Run `monitor/ng dashboard get` to see current operator-visible state.\n'
        printf '3. Resume the routine per `monitor/agent-prompt.md`.\n'
    else
        printf '## Suggested first checks\n\n'
        printf '1. Confirm your last in-flight delegation: `tmux list-windows` vs. the worker section above.\n'
        printf '2. If something stalled while you were down, `monitor/ng dashboard get` for the current state.\n'
        printf '3. Resume the routine per `monitor/agent-prompt.md`.\n'
    fi
}

_compose_situation_report > "$REPORT_FILE"

# Issue #161: route through the shared `_respawn_orchestrator` helper.
# Single surface for: --continue default, --settings handling, dialog
# dismissal, readiness probe, paste delivery, post-paste verify +
# Enter retry. respawn_agent in main.sh uses the same helper so the
# two recovery axes (window-absent / orchestrator-unresponsive) stay
# behaviourally consistent.
# Drive the helper explicitly from the mode we resolved above so the
# launcher flags match the report wording (no second, possibly-racing
# pin lookup inside the helper). resume → `--resume <sid>`; cold →
# `--no-continue` (issue #200: never degrade to `--continue`).
# --force-replace (issue #203): this is the orchestrator-UNRESPONSIVE
# recovery axis — its entire premise is replacing a live-but-wedged
# claude in a window that IS present. Opt OUT of the helper's pre-kill
# re-verify-absent guard (which would otherwise see the live process and
# abort). The absent-target path in main.sh's respawn_agent does the
# opposite: it omits --force-replace so a window that came back to life
# is never killed.
respawn_opts=()
if [[ "$RESUME_MODE" == "resume" && -n "$RESUME_SID" ]]; then
    respawn_opts+=(--resume-sid "$RESUME_SID")
else
    respawn_opts+=(--no-continue)
fi
respawn_opts+=(--prompt-file "$REPORT_FILE" --log-fn log --force-replace)

_respawn_orchestrator "$TARGET" "${respawn_opts[@]}"
helper_rc=$?

# Map helper rc → this script's exit codes (preserves historical
# contract documented in the file header):
#   helper 0 → 0   (full success)
#   helper 2 → 2   (tmux missing)
#   helper 3 → 3   (new-window failed)
#   helper 4 → 4   (paste failed but spawn succeeded)
#   helper 1 → 1   (bad usage / CLAUDE_BIN unresolvable)
case "$helper_rc" in
    0)  paste_rc=0 ;;
    4)  paste_rc=1 ;;
    *)
        # Stamp cooldown so the caller doesn't loop on every poll.
        date +%s > "$COOLDOWN_FILE"
        exit "$helper_rc"
        ;;
esac

# Cooldown marker — written even on paste failure so the caller's
# throttle gate engages. The marker's mtime IS the cooldown anchor.
date +%s > "$COOLDOWN_FILE"

# Structured event line for post-hoc inspection. Stays on one line
# so grep / awk pipelines downstream don't have to do multi-line
# parsing.
event_line=$(printf 'event=orchestrator-fresh-spawn ts=%s mode=%s reason=%s previous_sid=%s new_window=%s paste_rc=%d report=%s' \
    "$(date -Is)" \
    "$RESUME_MODE" \
    "${REASON:-unspecified}" \
    "${PREVIOUS_SID:-none}" \
    "$TARGET" \
    "$paste_rc" \
    "$REPORT_FILE")
log "$event_line"

# Action-log via ng (best-effort). The orchestrator's window-cleanup
# loop reads action-log.jsonl for retain semantics; surfacing the
# recovery there means a re-spawned orchestrator can see it as soon
# as it reads `monitor/ng log-action --show` or the dashboard.
ng="$_monitor_dir/ng"
if [[ -x "$ng" ]]; then
    "$ng" log-action watcher \
        --event orchestrator-fresh-spawn \
        --note "$event_line" \
        >/dev/null 2>&1 || true
fi

if (( paste_rc != 0 )); then
    log "situation-report paste failed (rc=$paste_rc); report on disk at $REPORT_FILE"
    exit 4
fi
exit 0
