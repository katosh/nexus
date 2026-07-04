#!/usr/bin/env bash
# monitor/hooks/turn-failure-emit.sh
#
# Claude Code StopFailure-hook handler. Sibling to over-limit-emit.sh:
# that handler owns the `rate_limit` sub-case (weekly Opus suspension);
# THIS handler owns every OTHER turn-killing error — the transient API
# 500/529, the broken model pin, the malformed-transcript 400 — i.e.
# the class of failures that leave a worker stalled **idle-without-
# wrap-up** with the inner `claude` process still alive.
#
# Why a structured marker at all (the motivating incident):
#   StopFailure fires *instead of* Stop when a turn dies to an API
#   error (empirically verified: a clean turn fires UserPromptSubmit →
#   Stop; a failed turn fires UserPromptSubmit → StopFailure, no Stop).
#   Because Stop never fires, none of the Stop-hook state updates run:
#   the heartbeat keeps its last `busy` stamp (which goes stale at 30 s)
#   and no `last_turn_end` is written. The pane shows an empty input
#   box. To the watcher's renderer-only view this is byte-identical to
#   a worker that finished and forgot to wrap up — so it nags
#   "idle Ns WITHOUT wrap-up" when the correct action is "the turn
#   crashed; paste a resume." This marker is the structured signal that
#   disambiguates the two, and carries the recovery verb so the
#   watcher/orchestrator pick paste-vs-respawn correctly.
#
# Writes (atomically) on a non-rate_limit StopFailure:
#
#   $NEXUS_ROOT/monitor/.state/turn-failure/<window>.json
#     {"ts": <epoch>,
#      "error": <structured token, e.g. "server_error">,
#      "category": <transient|config|conversation|auth|unknown>,
#      "recovery": <paste|respawn|operator>,
#      "last_msg": <first 200 chars of last_assistant_message>,
#      "session_id": <claude session id>,
#      "window": <tmux window name>,
#      "hook_event_name": "StopFailure"}
#
# Cleanup contract: the file persists until the NEXT successful turn's
# Stop hook clears it (the Stop block in worker-settings.json carries a
# matching `rm -f turn-failure/<window>.json`). A successful turn = the
# worker recovered. Consumers (pane-state.sh / _idle_probe.sh) also
# apply a freshness gate so a missed clear can't wedge a window forever.
#
# Required env (exported by spawn-worker.sh):
#   NEXUS_ROOT           absolute path to the primary nexus clone
#   NEXUS_WORKER_WINDOW  tmux window name this worker was spawned into
#   NEXUS_STATE_DIR      direct override (test escape hatch); when set,
#                        takes precedence over NEXUS_ROOT/monitor/.state.
#
# Hot-path discipline: O(ms), pure builtins + jq. Every failure path
# short-circuits to exit 0 — a wedged hook MUST NOT block claude's turn.

set -u

payload=$(cat 2>/dev/null || true)

window="${NEXUS_WORKER_WINDOW:-}"
[[ -n "$window" ]] || exit 0

# State-dir precedence mirrors worker-heartbeat.sh / ng so tests can
# pin a hermetic NEXUS_STATE_DIR.
if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    state_dir="$NEXUS_STATE_DIR"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    state_dir="$NEXUS_ROOT/monitor/.state"
else
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

# Locate the pure classifier next to this script.
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || _self_dir=""
if [[ -n "$_self_dir" ]] && [[ -r "$_self_dir/_cause_classify.sh" ]]; then
    # shellcheck source=/dev/null
    . "$_self_dir/_cause_classify.sh"
else
    exit 0
fi

# The StopFailure payload carries `error` as a STRING token (observed:
# "server_error", "model_not_found", "unknown") and the human copy in
# `last_assistant_message` (e.g. "API Error: 500 Internal server
# error..."). `error_type` is ABSENT on real payloads — over-limit-
# emit.sh's `.error_type` probe is why a 500 never produced a marker.
error_token=$(jq -r '.error // empty' <<<"$payload" 2>/dev/null) || error_token=""
last_msg=$(jq -r '.last_assistant_message // empty' <<<"$payload" 2>/dev/null) || last_msg=""
session_id=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null) || session_id=""

# Classify. rate_limit → category=rate_limit, recovery=none: that's
# over-limit-emit.sh's territory, so we write NOTHING and exit (no
# double-marking, no race on which handler "wins" a rate-limit event).
classified=$(cause_classify_error "$error_token" "$last_msg")
category="${classified%%$'\t'*}"
recovery="${classified#*$'\t'}"

[[ "$category" == "rate_limit" ]] && exit 0

dest_dir="$state_dir/turn-failure"
mkdir -p "$dest_dir" 2>/dev/null || exit 0

ts=$(date +%s)
last_msg_trunc="${last_msg:0:200}"

dest="$dest_dir/$window.json"
tmp="$dest_dir/.$window.$$.tmp"

if jq -nc \
    --argjson ts          "$ts" \
    --arg     error       "$error_token" \
    --arg     category    "$category" \
    --arg     recovery    "$recovery" \
    --arg     last_msg    "$last_msg_trunc" \
    --arg     session_id  "$session_id" \
    --arg     window      "$window" \
    '{
        ts:              $ts,
        error:           $error,
        category:        $category,
        recovery:        $recovery,
        last_msg:        $last_msg,
        session_id:      $session_id,
        window:          $window,
        hook_event_name: "StopFailure"
     }' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$dest" 2>/dev/null || rm -f "$tmp"
else
    rm -f "$tmp"
fi
exit 0
