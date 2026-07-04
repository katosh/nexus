#!/usr/bin/env bash
# worker-heartbeat.sh — emit a worker-side state heartbeat from a
# Claude Code hook (PostToolUse / Notification / UserPromptSubmit).
#
# Called per-tool-use or per-notification from the per-spawn
# `--settings` hook block injected by `monitor/spawn-worker.sh`.
# Writes (atomically) the worker's empirical state to a small JSON
# file under `<state-dir>/heartbeat/<window>.json` so the watcher's
# `pane-state.sh` classifier can use claude's own event signal as
# the primary detection axis — bypassing the ANSI-grep substrate
# whose false-positives motivated issue #74.
#
# Usage (from a hook):
#   worker-heartbeat.sh <state>
#
# State token comes from the caller (the hook config in SKILL.md):
#   busy              PostToolUse fired — agent is mid-step.
#   notify            Notification fired — refine via stdin payload
#                     (`permission_prompt` → blocked, `idle_prompt`
#                     → idle; unknown notification → keep as
#                     `notify` so the consumer falls back to the
#                     renderer path).
#   user_prompt       UserPromptSubmit fired — agent just received
#                     a new prompt; transient signal, classifier
#                     treats it as busy. ALSO writes a durable
#                     per-window stamp `<state-dir>/user-prompt/
#                     <window>` (`<epoch>\t<session-id>`) — the
#                     heartbeat JSON is overwritten by the next
#                     PostToolUse, so the watcher's operator-
#                     engagement trigger (issues #196/#201) reads
#                     this stamp instead. UserPromptSubmit is a
#                     contract event from Claude Code itself: it
#                     fires deterministically on every submitted
#                     prompt (operator typing+Enter or an
#                     orchestrator paste) and cannot be distorted
#                     by TUI character-rewriting the way
#                     `tmux capture-pane` output can.
#   turn_end          Stop fired — the agent's turn truly ended.
#                     Emits state=idle_prompt AND adds
#                     `last_turn_end=<now>` to the JSON. The
#                     classifier (pane-state.sh) uses last_turn_end
#                     to apply a longer staleness threshold than
#                     last_activity, because a Stop-derived idle
#                     doesn't go stale the way a tool-derived busy
#                     does — the agent really is done with its turn.
#   permission_prompt PermissionRequest fired — emit state=
#                     permission_prompt directly (classifier maps
#                     to `blocked`). Same vocab as the Notification
#                     `permission_prompt` refinement above.
#
# The helper is forgiving by design — every error path that could
# wedge a hook (missing env, missing jq, unwritable state dir)
# short-circuits to a silent exit 0. A failed hook MUST NOT block
# claude's turn. The classifier degrades cleanly: no heartbeat ⇒
# fall through to renderer detection.
#
# Reads from stdin: the claude hook payload JSON (best-effort).
# Captures `tool_name`, `session_id`, and the notification
# `message` for downstream introspection / debugging.
#
# Inputs / env:
#   $1                    state token (required)
#   $NEXUS_WORKER_WINDOW  tmux window name — exported by spawn-worker.sh.
#                         If unset the helper exits 0 silently
#                         (a worker not spawned by us isn't part
#                         of the watcher's surface).
#   $NEXUS_STATE_DIR      direct override (test escape hatch).
#   $NEXUS_ROOT           used as `<root>/monitor/.state` fallback.
#
# Output: writes `<state-dir>/heartbeat/<window>.json` via
# write-tmp + mv to keep readers free of half-written bytes.
#
# Hook boundary discipline (from SKILL.md): keep this O(ms). No
# network, no GraphQL, no long sleeps. The jq invocation is the
# only non-builtin cost.

set -u

state_token="${1:-}"
[[ -n "$state_token" ]] || exit 0

window="${NEXUS_WORKER_WINDOW:-}"
[[ -n "$window" ]] || exit 0

# Resolve state dir. Mirror monitor/ng's precedence so tests can
# pin a hermetic NEXUS_STATE_DIR and prod uses $NEXUS_ROOT.
if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    state_dir="$NEXUS_STATE_DIR"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    state_dir="$NEXUS_ROOT/monitor/.state"
else
    exit 0
fi

hb_dir="$state_dir/heartbeat"
mkdir -p "$hb_dir" 2>/dev/null || exit 0
hb_file="$hb_dir/$window.json"
tmp_file="$hb_file.$$.tmp"

# Read claude's hook payload from stdin (best-effort). Capping at
# 64 KiB keeps a pathological payload from stalling the hook;
# claude's events are small (<2 KiB typical).
payload=$(head -c 65536 2>/dev/null || true)

now=$(date +%s)

# Map the caller's state token plus the hook payload to a
# pane-state vocabulary entry. `busy` and `idle_prompt` /
# `permission_prompt` are the values the issue #74 spec calls for
# in the on-disk JSON; the consumer (pane-state.sh) maps these to
# its emit-vocab.
emit_state="$state_token"
event_name=""
tool_name=""
session_id=""
message=""
notification_type=""
# ScheduleWakeup-derived enrichment: when PostToolUse fires for a
# ScheduleWakeup tool call, pull `delaySeconds` out of the
# tool_input so we can stamp `scheduled_wakeup_at = now +
# delaySeconds` into the heartbeat. The classifier reads that
# field to emit `working-self-paced` instead of false-positive
# `idle` against self-paced /loop workers (issue #183).
schedule_delay_seconds=""

if command -v jq >/dev/null 2>&1 && [[ -n "$payload" ]]; then
    event_name=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null) || event_name=""
    tool_name=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || tool_name=""
    session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || session_id=""
    message=$(printf '%s' "$payload" | jq -r '.message // empty' 2>/dev/null) || message=""
    notification_type=$(printf '%s' "$payload" | jq -r '.notification_type // empty' 2>/dev/null) || notification_type=""
    if [[ "$tool_name" == "ScheduleWakeup" ]]; then
        schedule_delay_seconds=$(printf '%s' "$payload" | jq -r '.tool_input.delaySeconds // empty' 2>/dev/null) || schedule_delay_seconds=""
        [[ "$schedule_delay_seconds" =~ ^[0-9]+$ ]] || schedule_delay_seconds=""
    fi
fi

# Durable user-prompt stamp (issues #196/#201). The heartbeat JSON
# below is transient (the next PostToolUse overwrites it), so the
# submit event gets its own per-window file the watcher's
# operator-engagement attribution reads directly. Forgiving like
# everything else here: any failure skips the stamp, never the hook.
if [[ "$state_token" == "user_prompt" ]]; then
    up_dir="$state_dir/user-prompt"
    if mkdir -p "$up_dir" 2>/dev/null; then
        up_tmp="$up_dir/$window.$$.tmp"
        if printf '%s\t%s\n' "$now" "$session_id" > "$up_tmp" 2>/dev/null; then
            mv -f "$up_tmp" "$up_dir/$window" 2>/dev/null || rm -f "$up_tmp"
        else
            rm -f "$up_tmp" 2>/dev/null
        fi
    fi
fi

# Refinement for Notification: claude bundles permission and idle
# prompts (and auth_success / elicitation_*) under the same event.
# Prefer the structured `.notification_type` field (empirically a
# top-level string on the payload, e.g. "permission_prompt" /
# "idle_prompt"; see PR #132 for the captured payload shape) over
# the prior `.message` substring match — the structured field is
# i18n-stable and won't drift if Claude Code reworks the banner copy.
# Fall back to the message text-match when `.notification_type` is
# missing (older Claude Code, jq missing, or a non-Notification
# payload routed through this token by mistake). Unknown values
# yield `notify` so the consumer (pane-state.sh) falls through to
# the renderer path.
if [[ "$state_token" == "notify" ]]; then
    if [[ -n "$notification_type" ]]; then
        case "$notification_type" in
            permission_prompt) emit_state="permission_prompt" ;;
            idle_prompt)       emit_state="idle_prompt" ;;
            *)                 emit_state="notify" ;;
        esac
    else
        case "$message" in
            *permission*|*Permission*) emit_state="permission_prompt" ;;
            *waiting*|*idle*|*input*|*Idle*|*Waiting*) emit_state="idle_prompt" ;;
            *) emit_state="notify" ;;
        esac
    fi
fi

# `turn_end` is the Stop-hook token (issue #129 item 3). Maps to the
# same idle_prompt vocab as Notification's idle_prompt so the
# consumer (pane-state.sh) emits `idle` either way. The crucial
# difference is on-disk: turn_end also stamps `last_turn_end=$now`,
# letting the classifier apply a longer staleness threshold to the
# Stop-derived signal than to a tool-derived busy heartbeat — a
# Stop event means the agent's turn truly ended, which a 30 s
# silence doesn't invalidate the way it would for a `busy` stamp.
last_turn_end=""
if [[ "$state_token" == "turn_end" ]]; then
    emit_state="idle_prompt"
    last_turn_end="$now"
fi

# Preserve fields that other writers own. The async-signal layer
# (issue #183) splits the heartbeat into:
#   - tick-owned fields (this hook): state, last_activity,
#     last_turn_end, event, last_tool, session_id, window,
#     scheduled_wakeup_at (when ScheduleWakeup fires).
#   - worker-owned fields: external_waits (written by
#     `monitor/declare-wait.sh`).
# Per-event PostToolUse overwrites the file in full; we must read
# the prior content and copy worker-owned fields forward so a
# declare-wait call isn't clobbered by the next tool's heartbeat.
# Best-effort: read fails / corrupt JSON / jq absent ⇒ empty
# external_waits, the worker can re-declare. No-op when there's
# no prior content.
preserved_waits='[]'
preserved_dismissed='[]'
preserved_scheduled_wakeup_at=''
if [[ -f "$hb_file" ]] && [[ -r "$hb_file" ]] && command -v jq >/dev/null 2>&1; then
    prior=$(<"$hb_file") || prior=""
    if [[ -n "$prior" ]] && printf '%s' "$prior" | jq empty >/dev/null 2>&1; then
        waits_json=$(printf '%s' "$prior" | jq -c '.external_waits // []' 2>/dev/null) || waits_json="[]"
        [[ -n "$waits_json" ]] && preserved_waits="$waits_json"
        dismissed_json=$(printf '%s' "$prior" | jq -c '.dismissed_waits // []' 2>/dev/null) || dismissed_json="[]"
        [[ -n "$dismissed_json" ]] && preserved_dismissed="$dismissed_json"
        # Carry forward any previously-stamped wakeup unless this
        # tick is itself a ScheduleWakeup (in which case the new
        # delaySeconds wins, computed below). The wakeup expires
        # naturally — the classifier compares fire_at against now.
        if [[ -z "$schedule_delay_seconds" ]]; then
            prior_swa=$(printf '%s' "$prior" | jq -r '.scheduled_wakeup_at // empty' 2>/dev/null) || prior_swa=""
            [[ "$prior_swa" =~ ^[0-9]+$ ]] && preserved_scheduled_wakeup_at="$prior_swa"
        fi
    fi
fi

# Compute the wakeup epoch this tick stamps. ScheduleWakeup tool
# call ⇒ fire_at = now + delaySeconds. Otherwise carry forward
# the prior stamp (if any) so the classifier doesn't lose track
# of a pending wakeup between tool calls.
if [[ -n "$schedule_delay_seconds" ]]; then
    scheduled_wakeup_at_value=$(( now + schedule_delay_seconds ))
elif [[ -n "$preserved_scheduled_wakeup_at" ]]; then
    scheduled_wakeup_at_value="$preserved_scheduled_wakeup_at"
else
    scheduled_wakeup_at_value=""
fi

# Build the JSON. Prefer jq (proper escaping); fall back to a
# minimal hand-rolled JSON when jq is unavailable so a stripped
# environment doesn't disable the hook silently. jq path always
# emits `external_waits` (preserved from prior write) and the
# optional `scheduled_wakeup_at` (omitted when unset rather than
# null, to keep the classifier's `> 0` check simple).
if command -v jq >/dev/null 2>&1; then
    jq_args=(
        --arg state "$emit_state"
        --argjson last_activity "$now"
        --arg event "$event_name"
        --arg tool "$tool_name"
        --arg session "$session_id"
        --arg window "$window"
        --argjson external_waits "$preserved_waits"
        --argjson dismissed_waits "$preserved_dismissed"
    )
    if [[ -n "$last_turn_end" ]]; then
        jq_args+=( --argjson last_turn_end "$last_turn_end" )
    fi
    if [[ -n "$scheduled_wakeup_at_value" ]]; then
        jq_args+=( --argjson scheduled_wakeup_at "$scheduled_wakeup_at_value" )
    fi
    # The filter assembles the object from optional pieces. Keys
    # whose source variable is absent get dropped via `|
    # del(.k|select(. == null))`.
    jq_filter='{state: $state,
        last_activity: $last_activity,
        event: ($event // null),
        last_tool: (if $tool == "" then null else $tool end),
        session_id: (if $session == "" then null else $session end),
        window: $window,
        external_waits: $external_waits,
        dismissed_waits: $dismissed_waits}'
    if [[ -n "$last_turn_end" ]]; then
        jq_filter="$jq_filter"' + {last_turn_end: $last_turn_end}'
    fi
    if [[ -n "$scheduled_wakeup_at_value" ]]; then
        jq_filter="$jq_filter"' + {scheduled_wakeup_at: $scheduled_wakeup_at}'
    fi
    jq -nc "${jq_args[@]}" "$jq_filter" \
        > "$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; exit 0; }
else
    # Minimal fallback: emit the original three-field shape (state /
    # last_activity / window) plus, when known, the wakeup. We don't
    # try to preserve external_waits in this branch — without jq we
    # can't safely read & re-emit arbitrary JSON. A jq-less worker is
    # already degraded; the classifier falls through to pane-footer
    # parsing for the async signals.
    if [[ -n "$scheduled_wakeup_at_value" ]]; then
        printf '{"state":"%s","last_activity":%s,"window":"%s","scheduled_wakeup_at":%s,"external_waits":[],"dismissed_waits":[]}\n' \
            "$emit_state" "$now" "$window" "$scheduled_wakeup_at_value" \
            > "$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; exit 0; }
    else
        printf '{"state":"%s","last_activity":%s,"window":"%s","external_waits":[],"dismissed_waits":[]}\n' \
            "$emit_state" "$now" "$window" \
            > "$tmp_file" 2>/dev/null || { rm -f "$tmp_file"; exit 0; }
    fi
fi

mv -f "$tmp_file" "$hb_file" 2>/dev/null || rm -f "$tmp_file"
exit 0
