#!/usr/bin/env bash
# Auto-unstick helpers for the nexus watcher.
#
# Loaded by monitor/watcher/main.sh and by monitor/watcher/test-unstick.sh.
# Side-effect-free: only function definitions, no top-level state. The
# caller is responsible for setting these globals before any function
# is invoked:
#
#   AUTO_UNSTICK              "true" / "false" — feature flag
#   UNSTICK_DIR               directory for per-window fingerprint +
#                             retry counters + pre-action pane captures
#                             (audit trail) + cascade-state files
#   UNSTICK_LOG               append-only log of detections / actions /
#                             backoffs / cascades
#   WATCHER_WINDOW            tmux window hosting the watcher (skipped
#                             from scan so we never auto-Enter our own
#                             pane)
#   TARGET                    orchestrator tmux window name (case-B
#                             heads-up paste target). When unset,
#                             defaults to "orchestrator".
#   ACTION_LOG                path to monitor/.state/action-log.jsonl
#                             (used by case B to verify the orchestrator
#                             received the heads-up). Optional — when
#                             unset, the ack check is skipped.
#   RATELIMIT_PROBE           "true" / "false" — whether to call the
#                             Anthropic API to discover the rate-limit
#                             reset time. Default false. Requires
#                             ANTHROPIC_API_KEY.
#   ANTHROPIC_API_KEY         Anthropic API key for the probe. Pulled
#                             from environment only — never read from
#                             config. When empty the probe no-ops.
#   PROBE_MODEL               Model id for the probe (default
#                             "claude-haiku-4-5-20251001" — currently
#                             the cheapest model).
#   RATELIMIT_HEURISTIC_MIN   Minutes-from-now to set as the synthetic
#                             reset-epoch when the probe is disabled or
#                             fails. Default 30.
#   RATELIMIT_ACK_TIMEOUT_S   Seconds to wait for an
#                             `ratelimit-resume-ack` action-log line
#                             from the orchestrator after a cascade
#                             before declaring it unresponsive.
#                             Default 60.
#   API_ERROR_BACKOFF_MIN     Minutes a same-fingerprint case-C
#                             api-error wedge is allowed to recur
#                             before the watcher will Enter-nudge it
#                             again. Default 30. Tunable via the
#                             monitor.watcher.api_error_backoff_minutes
#                             config knob.
#   ON_DIALOG                 Case-D action mode (auto-dismiss / skip
#                             / error). Default `auto-dismiss`. Set
#                             from `monitor.watcher.on_dialog` in the
#                             watcher's caller. See the Case D
#                             narrative below.
#
# Three scenarios this defends against:
#
#   A) Permission prompt during normal run.
#      Even with `--dangerously-skip-permissions`, Claude Code still
#      prompts on certain command shapes (paths outside the project,
#      mount/dev commands, etc.). The prompt looks like:
#
#         Do you want to proceed?
#         ❯ 1. Yes
#           2. Yes, and allow access to ...
#           3. No
#
#      The default-highlighted option is "1. Yes" — pressing Enter
#      resumes. Continuous automation should not silently stall here,
#      so the watcher sends Enter directly. Risk: that action grants
#      whatever the prompted command was. Acceptable since the agent
#      was launched with --dangerously-skip-permissions (the operator
#      already opted into the bypass); the audit trail is the
#      pre-action pane capture under $UNSTICK_DIR plus the
#      $UNSTICK_LOG line.
#
#   B) Rate-limit prompt (Claude.ai usage limit hit).
#      Claude Code's rate-limit menu has the title "What do you want
#      to do?" with one of the option lines reading "Stop and wait
#      for limit to reset". We treat case B as a session-wide event:
#
#        1. Probe the Anthropic API (or fall back to a heuristic
#           timer) to learn when the rate limit resets.
#        2. Wait. Per-window detection lines log only on first sight.
#        3. Once the reset epoch passes, cascade an unstick across
#           every stuck window EXCEPT the watcher and the
#           orchestrator (TARGET): Enter to dismiss the menu, then
#           paste-buffer "Please continue with your task. The API
#           rate limit has reset." + Enter.
#        4. Inform the orchestrator with a heads-up paste containing
#           the count of windows we just unstuck and a one-liner
#           prompting `monitor/ng log-action ... --event
#           ratelimit-resume-ack`. The watcher polls the action-log
#           on subsequent cycles to confirm the orchestrator is
#           alive; if no ack lands within RATELIMIT_ACK_TIMEOUT_S the
#           watcher logs `orchestrator-unresponsive` so the operator
#           can intervene.
#
# Asymmetry: case A unsticks any non-watcher window directly with a
# single keypress (no cascade — no follow-up needed for permission).
# Case B fans out across every stuck window then sends a separate
# heads-up to the orchestrator; the watcher already captures every
# pane each cycle, so making it the cascade actor is cheaper and more
# direct than asking the orchestrator to tmux-walk its siblings.
#
#   C) Transient API error wedge.
#      Claude Code occasionally lands on a per-turn API failure (most
#      commonly an "Internal server error" / type=api_error response)
#      that wedges the input prompt: the `⏺` arrow sits idle waiting
#      for user input with the JSON error chip rendered just below the
#      command line, e.g.
#
#         ⏺ Do something.
#           ⎿  API Error: {"type":"error","error":{...,"type":"api_error",
#              "message":"Internal server error"},"request_id":"…"}
#
#      Pressing Enter on this idle prompt usually nudges Claude Code
#      to retry the failed turn. The watcher detects the chip via
#      capture-pane, fingerprints the API error block, and sends Enter.
#      A per-(window, fingerprint) backoff (API_ERROR_BACKOFF_MIN,
#      default 30 min) prevents hammering a chronically broken endpoint:
#      the same fingerprint reappearing within the window is logged
#      once per cycle as `case=C action=skip-backoff` and skipped.
#      Distinct fingerprints (different request_ids / messages) and
#      same-fingerprint reappearances after the backoff elapses re-fire
#      the Enter. Enter alone is the chosen action — Claude Code
#      retries the failed turn from this idle state, so a separate
#      "please continue" follow-up is unnecessary today. Expand to a
#      paste-buffer follow-up if Enter ever observed insufficient.
#
#   D) AskUserQuestion chip-bar dialog (dialog-guard).
#      The orchestrator is paste-driven; any blocking modal that
#      intercepts the watcher's paste-buffer push either corrupts
#      dialog state, stalls the channel, or feeds Case A's auto-Enter
#      into selecting whatever option happens to be index 1. The
#      operator's verbatim constraint: "we cannot risk the orchestrator
#      not being receptive for watcher prompt injections."
#
#      SCOPE — orchestrator window ONLY for the dismiss-and-paste
#      action. The severed-paste-channel hazard is specific to the
#      single paste-driven window (TARGET, default `orchestrator`).
#      Other session-0 windows must never be force-dismissed:
#        - operator-owned interactive windows (the operator may be
#          hand-driving Claude and legitimately answering a dialog —
#          force-dismissing destroys their work), and
#        - worker panes, whose in-process sub-agent ("dynamic
#          workflow") chains can legitimately raise AskUserQuestion;
#          force-dismissing corrupts worker output.
#      The dismiss-and-paste also carries orchestrator-specific wording
#      ("Nexus orchestrators must never call AskUserQuestion…") that is
#      nonsensical in a worker or operator pane. The same detection on
#      a NON-target window therefore routes to Case W below (the
#      blocked-question relay), which never sends keys to the pane.
#      (An AskUQ overlay on a non-orchestrator window also cannot trip
#      Case A: Case A requires the `Do you want to proceed?` permission
#      text, which AskUQ overlays never carry.)
#
#      Layer A1 of the safety net (the `PreToolUse` matcher in
#      `monitor/orchestrator-settings.json`) blocks the orchestrator
#      from ever dispatching `AskUserQuestion`. Case D here is Layer
#      B — the watcher safety net for orchestrator sessions whose
#      settings file is missing, corrupt, or older than the hook
#      landing, and for any future modal whose rendered shape carries
#      the same chip-bar signature. The detection signature combines a
#      shape gate with a live-ness gate. Shape: the chip-bar's two
#      final options (`Type something.` penultimate + `Chat about this`
#      final). Live-ness: the navigation footer (`Esc to cancel`,
#      rendered as `Enter to select · ↑/↓ to navigate · Esc to cancel`)
#      must appear at the BOTTOM of the pane — within the last few
#      non-blank lines, where a live overlay always renders it. The
#      option literals alone are insufficient: a single line of prose
#      enumerating them (a worker summarising the Claude-Code
#      TUI-state-detection surface, say) satisfied both and false-
#      positived the guard in the field, and even a full overlay block
#      quoted into the orchestrator's scrollback is not a live block.
#      Bottom-anchoring the footer is what discriminates a genuinely-
#      blocking overlay from any pane that merely displays the literals:
#      quoted text and the normal REPL chrome (input box + `◉ model`
#      status line) push the footer above the bottom slice. Validated
#      against the field captures: the one true positive had the footer
#      as its last line; every false positive had REPL chrome or a
#      different (workflow) footer at the bottom.
#
#      Action: capture pane (audit), send Escape (cancels the menu —
#      Claude Code's documented behaviour for modal overlays; the
#      `paste_to_target` mode-force in `main.sh` rejected Escape only
#      for its side-effect of cancelling MID-GENERATION, which by
#      construction can't apply here because the dialog itself is
#      already blocking generation), wait 0.5 s, then paste a meta-
#      message into the now-clean input box explaining what happened
#      and pointing at `monitor/agent-prompt.md`. The meta-message is
#      the next thing the orchestrator sees — so the dismissal also
#      restores the watcher's communication channel in the same
#      action.
#
#      Behaviour is tunable via `ON_DIALOG` (set from
#      `monitor.watcher.on_dialog`, default `auto-dismiss`):
#        - `auto-dismiss` — the action above (recommended).
#        - `skip`         — log detection only; the dialog is left
#                           in place. Useful for debugging the
#                           detection regex without acting.
#        - `error`        — log a WARN line; otherwise the same as
#                           `skip`. Surfaces the wedge in unstick
#                           logs without auto-dismissing.
#      Ordering: Case D is matched BEFORE Case A in
#      `_handle_unstick_window` because Case A's `❯ N.` chevron
#      pattern (the permission-prompt heuristic) would also match an
#      AskUQ overlay's numbered options — running A first would
#      silently auto-Enter the first option of the wrong dialog.
#
#   W) Worker-blocked-question relay (your-org/your-nexus#180).
#      The same AskUQ detection (shape + bottom-anchored live-ness
#      gate, see Case D) firing on a NON-target window means a worker
#      or operator-interactive pane is blocked on a question nobody
#      may be watching. The operator's mandate: "since I cannot
#      always answer questions like you just asked me, the watcher
#      should have detected and resolved this by having the
#      orchestrator answer."
#
#      Action: NO keys are ever sent to the pane. Instead the relay
#      synthesizes a pending-decision record (the issue-129 channel —
#      `monitor/.state/decisions/<window>.<fp>.json`, kind
#      `blocked_question`) carrying the parsed question, the option
#      list, and the captured pane tail. `render_pending_decisions`
#      surfaces it in the next emit exactly like a hook-written
#      decision; the orchestrator answers on the operator's behalf
#      (Escape + paste a textual answer — see monitor/agent-prompt.md)
#      and acks by removing the record. This deliberately covers
#      HOOKLESS panes (operator-launched interactive windows have no
#      per-spawn Notification hook, so the decisions channel never
#      fires for them — the 2026-06-09 svc-cockpit2 incident).
#
#      Grace: the relay fires only after the overlay has been
#      continuously observed for MONITOR_WORKER_ASKUQ_GRACE_SECONDS
#      (default 300; 0 disables the relay), preserving the Case D
#      rationale — a human mid-answer makes the overlay vanish and
#      nothing fires. Continuity is mtime-tracked on the first-seen
#      marker: a gap of > 90 s between sightings (several missed 10 s
#      scan cycles) means the overlay went away and came back, so the
#      episode re-arms and the grace clock restarts. Single-shot per
#      (window, fp): an existing record or `.handled.json` tombstone
#      suppresses re-writes; a new question (new fp) re-arms. If the
#      orchestrator acks (rm) while the worker is STILL blocked on the
#      same fp, the next scan re-writes the record — correct, because
#      the question remains unanswered; the emit-level content-hash
#      dedup keeps the re-surface from flooding (issue #152 lesson).

# `_ensure_service_log` (nexus-code#484/#509): the unstick log must
# never be created group-writable by a bare `>>`.
_unstick_module_dir="${BASH_SOURCE[0]%/*}"
[[ "$_unstick_module_dir" == "${BASH_SOURCE[0]}" ]] && _unstick_module_dir=.
# shellcheck source=../_log-mode.sh
source "$_unstick_module_dir/../_log-mode.sh"
unset _unstick_module_dir

unstick_log() {
    local msg
    msg="[$(date -Is)] $*"
    _ensure_service_log "$UNSTICK_LOG"
    printf '%s\n' "$msg" >> "$UNSTICK_LOG" 2>/dev/null || true
}

# Stable fingerprint of the prompt instance: pulls out the lines that
# define the prompt (title + numbered options + highlight arrow) and
# hashes them. Spinner / cursor / status-line characters that change
# every capture are excluded so the same prompt yields the same
# fingerprint across poll cycles.
_unstick_fingerprint() {
    grep -E '(Do you want to proceed\?|What do you want to do\?|❯[[:space:]]+[0-9]+\.|^[[:space:]]*[0-9]+\.[[:space:]]|Stop and wait for limit)' \
        | sha1sum | cut -c1-12
}

# Stable fingerprint of an API-error chip. Pulls every line carrying
# any of the chip tokens (the rendered "API Error:" header, the inner
# JSON `"type":"api_error"`, the message string, and the request_id)
# and hashes the lot. Different request_ids yield different
# fingerprints, so each transient failure is unique; the same wedge
# captured across poll cycles yields the same fingerprint as long as
# pane content is stable. A wrapped chip (long line broken across
# rendered rows) still fingerprints stably because each visual line
# matches one of the patterns.
_unstick_fingerprint_api_error() {
    grep -E '(API Error|"type":"api_error"|Internal server error|"request_id")' \
        | sha1sum | cut -c1-12
}

# Probe the Anthropic API to discover the rate-limit reset timestamp.
# Output: ISO 8601 timestamp on stdout, empty string on any failure
# (probe disabled, no key, curl missing, header absent, non-2xx, etc.)
# Cost: ~1 token output + a few hundred input tokens per call. Callers
# MUST cache the result for the duration of the rate-limit hit and not
# re-probe each cycle.
_probe_ratelimit_reset() {
    [[ "${RATELIMIT_PROBE,,}" == "true" ]] || return 0
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    local model="${PROBE_MODEL:-claude-haiku-4-5-20251001}"
    local resp_headers
    resp_headers=$(curl -sS -m 15 -D - -o /dev/null \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        --data "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\".\"}],\"max_tokens\":1}" \
        https://api.anthropic.com/v1/messages 2>/dev/null) || return 0
    # Prefer the unified-reset (covers both input + output token buckets);
    # fall back to the tokens-reset header which older API versions emit.
    local reset
    reset=$(grep -i '^anthropic-ratelimit-unified-reset:' <<<"$resp_headers" \
            | tr -d '\r' | awk '{print $2}' | head -1)
    [[ -z "$reset" ]] && reset=$(grep -i '^anthropic-ratelimit-tokens-reset:' <<<"$resp_headers" \
            | tr -d '\r' | awk '{print $2}' | head -1)
    printf '%s' "$reset"
}

# Record a watcher-side machine input into a worker pane (the Enter
# nudges below) in the machine-input ledger, so the idle-probe's
# operator-attribution rule (issue #201; see the "operator-engaged
# marks" section of _idle_probe.sh) doesn't mistake the resulting
# busy transition for operator input and falsely suppress the
# window's stall-nag. Thin wrapper over `_machine_input_stamp`
# (monitor/watcher/_lib.sh) — the single ledger-write chokepoint
# shared by every watcher-side injector (#293) — preserving the
# historical `unstick` default src for callers that omit it.
_unstick_stamp_machine_input() {
    local window="$1" src="${2:-unstick}"
    _machine_input_stamp "$window" "$src"
}

# Send Enter to a permission-prompt window to accept the
# default-highlighted "Yes". Idempotent across the per-prompt fp +
# tries counter; backs off after one retry to avoid hammering an
# unresponsive prompt.
_act_permission() {
    local window="$1" pane="$2"
    local case_key="permission"
    local fp_file="$UNSTICK_DIR/${window}.${case_key}.fp"
    local tries_file="$UNSTICK_DIR/${window}.${case_key}.tries"
    local fp prev_fp tries
    fp=$(printf '%s\n' "$pane" | _unstick_fingerprint)
    prev_fp=""
    [[ -f "$fp_file" ]] && prev_fp=$(<"$fp_file")
    tries=0
    [[ -f "$tries_file" ]] && tries=$(<"$tries_file")
    if [[ "$fp" != "$prev_fp" ]]; then
        tries=0
    fi
    if (( tries >= 2 )); then
        unstick_log "window=$window case=A action=skip-backoff fp=$fp tries=$tries"
        return 0
    fi
    local audit="$UNSTICK_DIR/${window}.${case_key}.${fp}.audit"
    [[ -f "$audit" ]] || printf '%s\n' "$pane" > "$audit"
    if tmux send-keys -t "$window" Enter 2>/dev/null; then
        printf '%s' "$fp" > "$fp_file"
        printf '%d' "$(( tries + 1 ))" > "$tries_file"
        _unstick_stamp_machine_input "$window" "unstick-permission"
        local action_label="sent-Enter"
        (( tries >= 1 )) && action_label="sent-Enter-retry"
        unstick_log "window=$window case=A action=$action_label fp=$fp audit=$(basename "$audit")"
    else
        unstick_log "window=$window case=A action=send-keys-failed fp=$fp"
    fi
}

# Send Enter to a window wedged on a transient API-error chip. The
# chip indicates the previous turn's request returned an error rather
# than a completion; pressing Enter on the idle prompt prompts Claude
# Code to retry the failed turn. Backoff is per-(window, fingerprint):
# the same fingerprint reappearing within API_ERROR_BACKOFF_MIN
# (default 30 min) is logged and skipped, so a chronically broken
# endpoint isn't hammered. Distinct fingerprints (different request_ids
# / messages) and same-fingerprint reappearances after the backoff
# elapses re-fire the Enter.
#
# Why Enter alone (no follow-up paste): from this idle state Claude
# Code retries the failed turn on Enter; a separate "please continue"
# prompt is unnecessary today. If we ever observe Enter not nudging
# it, expand here to a paste-buffer follow-up after a short sleep.
_act_api_error() {
    local window="$1" pane="$2"
    local case_key="api-error"
    local fp_file="$UNSTICK_DIR/${window}.${case_key}.fp"
    local epoch_file="$UNSTICK_DIR/${window}.${case_key}.epoch"
    local fp prev_fp last_epoch now backoff_min backoff_s age
    fp=$(printf '%s\n' "$pane" | _unstick_fingerprint_api_error)
    prev_fp=""
    [[ -f "$fp_file" ]] && prev_fp=$(<"$fp_file")
    last_epoch=0
    [[ -f "$epoch_file" ]] && last_epoch=$(<"$epoch_file")
    now=$(date +%s)
    backoff_min="${API_ERROR_BACKOFF_MIN:-30}"
    backoff_s=$(( backoff_min * 60 ))
    age=$(( now - last_epoch ))
    if [[ "$fp" == "$prev_fp" ]] && (( age < backoff_s )); then
        unstick_log "window=$window case=C action=skip-backoff fp=$fp age_s=$age backoff_s=$backoff_s"
        return 0
    fi
    local audit="$UNSTICK_DIR/${window}.${case_key}.${fp}.audit"
    [[ -f "$audit" ]] || printf '%s\n' "$pane" > "$audit"
    if tmux send-keys -t "$window" Enter 2>/dev/null; then
        printf '%s' "$fp" > "$fp_file"
        printf '%s' "$now" > "$epoch_file"
        _unstick_stamp_machine_input "$window" "unstick-api-error"
        unstick_log "window=$window case=C action=sent-Enter fp=$fp audit=$(basename "$audit")"
    else
        unstick_log "window=$window case=C action=send-keys-failed fp=$fp"
    fi
}

# Stable fingerprint of an AskUserQuestion chip-bar overlay. Pulls
# the lines that carry the chip-bar's distinguishing markers (the
# `Type something.` and `Chat about this` literals, the numbered
# options, and any question line ending in `?`) and hashes them.
# Cosmetic chrome — chip arrows, status-bar bytes — is excluded so
# the same dialog yields the same fingerprint across poll cycles,
# letting `_act_askuq` de-duplicate retries via the per-(window, fp)
# audit file. The `\?$` clause distinguishes dialogs whose options
# are identical but question text differs (load-bearing for the
# "distinct fp re-fires" test — without it, two consecutive dialogs
# with the same options would silently be treated as a single
# already-handled fp).
_unstick_fingerprint_askuq() {
    grep -E '(Type something\.|Chat about this|^[[:space:]]*[0-9]+\.[[:space:]]|❯[[:space:]]+[0-9]+\.|\?[[:space:]]*$)' \
        | sha1sum | cut -c1-12
}

# Dismiss an AskUserQuestion chip-bar overlay on a window and paste a
# meta-message into the now-clean input box. The meta-message is what
# the orchestrator will see next — its content explains what happened
# and points at `monitor/agent-prompt.md` so any future code path that
# slipped past Layer A1 (the `PreToolUse` matcher) is also self-
# documenting from the orchestrator's side. Layered behaviour:
#
#   ON_DIALOG=auto-dismiss (default)  capture + Escape + paste meta
#   ON_DIALOG=skip                    log detection, take no action
#   ON_DIALOG=error                   log WARN, take no action
#
# Single-shot per (window, fingerprint): once we've fired the
# dismissal+meta paste for a fp, repeated detections of the same fp
# are logged as `case=D action=skip-fired fp=<fp>` so the orchestrator
# isn't flooded with duplicate meta-messages on slow render cycles.
# A distinct fp (new dialog) clears the fired marker.
_act_askuq() {
    local window="$1" pane="$2"
    local case_key="askuq"
    local mode="${ON_DIALOG:-auto-dismiss}"
    local fp_file="$UNSTICK_DIR/${window}.${case_key}.fp"
    local fired_file="$UNSTICK_DIR/${window}.${case_key}.fired"
    local fp prev_fp
    fp=$(printf '%s\n' "$pane" | _unstick_fingerprint_askuq)
    prev_fp=""
    [[ -f "$fp_file" ]] && prev_fp=$(<"$fp_file")
    if [[ "$fp" != "$prev_fp" ]]; then
        rm -f "$fired_file"
    fi
    printf '%s' "$fp" > "$fp_file"

    case "$mode" in
        skip)
            unstick_log "window=$window case=D action=skip-detected fp=$fp on_dialog=$mode"
            return 0
            ;;
        error)
            unstick_log "WARN window=$window case=D action=detected-no-act fp=$fp on_dialog=$mode"
            return 0
            ;;
        auto-dismiss|"") ;;
        *)
            unstick_log "WARN window=$window case=D action=unknown-mode fp=$fp on_dialog=$mode (defaulting to skip)"
            return 0
            ;;
    esac

    if [[ -f "$fired_file" ]]; then
        unstick_log "window=$window case=D action=skip-fired fp=$fp"
        return 0
    fi

    local audit="$UNSTICK_DIR/${window}.${case_key}.${fp}.audit"
    [[ -f "$audit" ]] || printf '%s\n' "$pane" > "$audit"

    # Escape dismisses the modal — same key the Claude Code REPL
    # binds to "cancel menu". The `paste_to_target` mode-force in
    # main.sh avoided Escape because Escape mid-generation aborts
    # the in-flight turn; by construction that concern doesn't apply
    # here (the dialog itself blocks generation, so there's no
    # turn to abort).
    if ! tmux send-keys -t "$window" Escape 2>/dev/null; then
        unstick_log "window=$window case=D action=escape-failed fp=$fp"
        return 1
    fi
    sleep 0.5

    local meta='[nexus watcher] An AskUserQuestion dialog was open and has been dismissed automatically. Nexus orchestrators must never call AskUserQuestion — communicate with the operator via GitHub issue comments. See monitor/agent-prompt.md.'
    if ! _paste_line_to_window "$window" "$meta"; then
        unstick_log "window=$window case=D action=meta-paste-failed fp=$fp"
        return 1
    fi
    printf '1' > "$fired_file"
    unstick_log "window=$window case=D action=dismissed-and-pasted fp=$fp audit=$(basename "$audit")"
    return 0
}

# Case W — worker-blocked-question relay. See the Case W narrative in
# the file header. Called by `_handle_unstick_window` when the AskUQ
# live-overlay detection fires on a NON-target window. Never sends
# keys to the pane; the only outputs are the first-seen/audit state
# files under $UNSTICK_DIR and, once the grace elapses, a synthesized
# pending-decision record on the issue-129 channel.
#
# First-seen marker protocol (`<window>.worker-askuq.<fp>.first-seen`):
#   content = epoch of the episode's first sighting (the grace anchor)
#   mtime   = epoch of the most recent sighting (the continuity probe)
# Every sighting touches the mtime; a sighting whose predecessor is
# > 90 s stale means the overlay vanished and reappeared between scans
# (the human answered, then a new identical question arrived, or the
# capture flickered) — the episode resets and the grace clock restarts.
# 90 s ≈ nine 10 s detect_unstick cadences; generous enough that async
# scheduler starvation can't false-reset, small enough that a same-fp
# question hours later doesn't inherit a long-expired grace anchor.
_act_worker_askuq() {
    local window="$1" pane="$2"
    local grace="${MONITOR_WORKER_ASKUQ_GRACE_SECONDS:-300}"
    [[ "$grace" =~ ^[0-9]+$ ]] || grace=300
    (( grace == 0 )) && return 0   # relay disabled by the operator

    local fp now
    fp=$(printf '%s\n' "$pane" | _unstick_fingerprint_askuq)
    now=$(date +%s)

    local first_file="$UNSTICK_DIR/${window}.worker-askuq.${fp}.first-seen"
    if [[ ! -f "$first_file" ]]; then
        printf '%s' "$now" > "$first_file"
        unstick_log "window=$window case=W action=first-seen fp=$fp grace=${grace}s"
        return 0
    fi

    local last_seen first_seen
    last_seen=$(stat -c %Y "$first_file" 2>/dev/null || echo 0)
    [[ "$last_seen" =~ ^[0-9]+$ ]] || last_seen=0
    if (( now - last_seen > 90 )); then
        printf '%s' "$now" > "$first_file"
        unstick_log "window=$window case=W action=re-armed fp=$fp (sighting gap $(( now - last_seen ))s)"
        return 0
    fi
    touch "$first_file" 2>/dev/null || true

    first_seen=$(<"$first_file")
    [[ "$first_seen" =~ ^[0-9]+$ ]] || { printf '%s' "$now" > "$first_file"; return 0; }
    (( now - first_seen < grace )) && return 0

    # Grace elapsed with the overlay continuously live — relay.
    local decisions_dir="${STATE_DIR:-$(dirname "$UNSTICK_DIR")}/decisions"
    local dest="$decisions_dir/${window}.${fp}.json"
    local tomb="$decisions_dir/${window}.${fp}.handled.json"
    if [[ -f "$tomb" ]]; then
        unstick_log "window=$window case=W action=skip-tombstone fp=$fp"
        return 0
    fi
    # Already relayed and not yet acked — single-shot per (window, fp).
    [[ -f "$dest" ]] && return 0

    if ! command -v jq >/dev/null 2>&1; then
        unstick_log "WARN window=$window case=W action=jq-missing fp=$fp (relay skipped)"
        return 1
    fi
    mkdir -p "$decisions_dir" 2>/dev/null || true

    # Parse the question (the last `?`-terminated line above the
    # options renders as the row excerpt in the pending-decisions
    # section) and the numbered option list. Parse failures degrade to
    # a pointer at the pane tail — the relay must surface even when
    # the overlay shape drifts.
    local question options excerpt
    question=$(grep -E '\?[[:space:]]*$' <<<"$pane" | tail -n 1 \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -n "$question" ]] || question="(question text not parsed — see tool_context pane capture)"
    options=$(grep -E '^[[:space:]]*(❯[[:space:]]+)?[0-9]+\.' <<<"$pane")
    excerpt=$(printf '%s\n%s' "$question" "$options")

    local audit="$UNSTICK_DIR/${window}.worker-askuq.${fp}.audit"
    [[ -f "$audit" ]] || printf '%s\n' "$pane" > "$audit"

    local tmp="$dest.tmp.$$"
    if jq -nc \
        --arg ts             "$(date -Is)" \
        --arg window         "$window" \
        --arg kind           "blocked_question" \
        --arg prompt_excerpt "$excerpt" \
        --arg tool_context   "$pane" \
        --arg fingerprint    "$fp" \
        '{
            ts: $ts,
            window: $window,
            session_id: "",
            kind: $kind,
            prompt_excerpt: $prompt_excerpt,
            tool_context: $tool_context,
            fingerprint: $fingerprint
         }' > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp"; return 1; }
        unstick_log "window=$window case=W action=relayed fp=$fp decision=$(basename "$dest") waited=$(( now - first_seen ))s audit=$(basename "$audit")"
    else
        rm -f "$tmp"
        unstick_log "WARN window=$window case=W action=record-write-failed fp=$fp"
        return 1
    fi
    return 0
}

# Per-window detection logging for the rate-limit prompt. Distinct from
# the action — case B's cascade is a session-wide single-shot kicked
# off by `_act_ratelimit`, not by per-window state.
_record_ratelimit_seen() {
    local window="$1" pane="$2"
    local case_key="ratelimit"
    local fp_file="$UNSTICK_DIR/${window}.${case_key}.fp"
    local tries_file="$UNSTICK_DIR/${window}.${case_key}.tries"
    local fp prev_fp
    fp=$(printf '%s\n' "$pane" | _unstick_fingerprint)
    prev_fp=""
    [[ -f "$fp_file" ]] && prev_fp=$(<"$fp_file")
    if [[ "$fp" != "$prev_fp" ]]; then
        printf '%s' "$fp" > "$fp_file"
        printf '%d' "0" > "$tries_file"
        unstick_log "window=$window case=B action=detected fp=$fp"
    fi
}

# Inspect a single tmux window for a stuck prompt. Acts on case A
# directly; for case B it just records the detection and prints the
# string `ratelimit` so the caller can collect candidates for the
# global cascade. Prints empty string if no prompt matched.
_handle_unstick_window() {
    local window="$1"
    # Never paste into the watcher's own pane.
    [[ "$window" == "${WATCHER_WINDOW:-watcher}" ]] && return 0
    local pane
    pane=$(tmux capture-pane -t "$window" -p -S -25 2>/dev/null) || return 0
    [[ -z "$pane" ]] && return 0

    # Order matters: rate-limit menu also contains numbered-option
    # lines that overlap with the permission prompt regex, so check
    # the rate-limit fingerprint first. Case D (AskUserQuestion
    # chip-bar) MUST also be matched before Case A — Case A's
    # `❯ N.` chevron pattern would otherwise auto-Enter the first
    # option of an AskUQ overlay, silently mis-selecting whichever
    # option happens to be highlighted. Case C (api-error chip) is
    # disjoint from all menus (no `Type something.` / `Chat about
    # this` / `What do you want to do?` / `Do you want to proceed?`
    # text), so its position in the chain is incidental.
    if grep -qE 'What do you want to do\?' <<<"$pane" \
       && grep -qE 'Stop and wait for limit' <<<"$pane"; then
        _record_ratelimit_seen "$window" "$pane"
        printf 'ratelimit'
        return 0
    fi
    # AskUserQuestion chip-bar (Cases D + W). The detection is shared;
    # the WINDOW decides the action:
    #
    #   - TARGET (orchestrator) → Case D dismiss-and-paste: the paste
    #     channel must be restored, and Layer A1 says the orchestrator
    #     should never have asked. See the Case D narrative.
    #   - any other window      → Case W blocked-question relay: never
    #     touch the pane; grace-gate, then synthesize a pending-decision
    #     record so the orchestrator answers on the operator's behalf.
    #     See the Case W narrative.
    #
    # LIVE-vs-QUOTED guard (both cases): the overlay's navigation
    # footer (`Esc to cancel`) must sit at the BOTTOM of the pane
    # (within the last few non-blank lines), where a live interactive
    # overlay always renders it. A pane that merely *displays* the
    # chip-bar literals — an agent discussing this feature, quoting a
    # worker's TUI-surface inventory, or echoing a captured overlay —
    # keeps the normal Claude Code REPL chrome (input box + `◉ model`
    # status line) or other output at the bottom, pushing any mention
    # of the footer above the slice. The two option literals
    # (`Type something.` penultimate + `Chat about this` final) gate
    # the chip-bar shape; the bottom-anchored footer gates live-ness.
    if grep -qF 'Type something.' <<<"$pane" \
       && grep -qF 'Chat about this' <<<"$pane" \
       && printf '%s\n' "$pane" | grep -v '^[[:space:]]*$' | tail -n 3 \
            | grep -qF 'Esc to cancel'; then
        if [[ "$window" == "${TARGET:-orchestrator}" ]]; then
            _act_askuq "$window" "$pane"
            printf 'askuq'
        else
            _act_worker_askuq "$window" "$pane"
            printf 'worker-askuq'
        fi
        return 0
    fi
    # Tight match: the rendered chip starts with `API Error: {"type":"error"`
    # and the inner failure we currently auto-retry has the literal
    # message "Internal server error". The two-grep AND keeps benign
    # mentions of either substring (e.g. user prose, code generation)
    # from triggering. -F (fixed string) avoids regex-meta concerns
    # around the brace and quotes.
    if grep -qF 'API Error: {"type":"error"' <<<"$pane" \
       && grep -qF '"Internal server error"' <<<"$pane"; then
        _act_api_error "$window" "$pane"
        printf 'api-error'
        return 0
    fi
    if grep -qE 'Do you want to proceed\?' <<<"$pane" \
       && grep -qE '❯[[:space:]]+[0-9]+\.' <<<"$pane"; then
        _act_permission "$window" "$pane"
        printf 'permission'
        return 0
    fi
    return 0
}

# Paste a single line of text to a tmux window via the paste-buffer
# (avoids the send-keys per-character escaping pitfall). Mirrors the
# paste_to_target hardening from main.sh: `i BSpace` first to force the
# target into insert mode regardless of starting state.
_paste_line_to_window() {
    local window="$1" text="$2"
    local buf="nexus-unstick-$$-${RANDOM}-${RANDOM}"
    local tmpfile
    tmpfile=$(mktemp)
    printf '%s' "$text" > "$tmpfile"
    tmux send-keys -t "$window" i BSpace 2>/dev/null || true
    tmux load-buffer -b "$buf" "$tmpfile" 2>/dev/null || { rm -f "$tmpfile"; return 1; }
    rm -f "$tmpfile"
    tmux paste-buffer -b "$buf" -t "$window" 2>/dev/null || {
        tmux delete-buffer -b "$buf" 2>/dev/null
        return 1
    }
    sleep 0.1
    tmux send-keys -t "$window" Enter 2>/dev/null || {
        tmux delete-buffer -b "$buf" 2>/dev/null
        return 1
    }
    tmux delete-buffer -b "$buf" 2>/dev/null || true
    return 0
}

# Cascade the unstick to a single non-orchestrator window: Enter to
# dismiss the menu, then a follow-up paste prompting the agent to
# continue. Returns 0 on success.
_cascade_unstick_to_window() {
    local window="$1"
    local pane
    pane=$(tmux capture-pane -t "$window" -p -S -25 2>/dev/null) || return 1
    local fp
    fp=$(printf '%s\n' "$pane" | _unstick_fingerprint)
    local audit="$UNSTICK_DIR/${window}.ratelimit.${fp}.audit"
    [[ -f "$audit" ]] || printf '%s\n' "$pane" > "$audit"
    if ! tmux send-keys -t "$window" Enter 2>/dev/null; then
        unstick_log "window=$window case=B action=cascade-send-keys-failed fp=$fp"
        return 1
    fi
    sleep 0.2
    # Stamp BEFORE the paste (stamp-before-paste ordering — a paste
    # must never outrun its stamp, else the worker's UserPromptSubmit
    # races ahead of the ledger row and reads as an operator submit).
    # This is a watcher-initiated worker wake → machine attribution is
    # correct by construction (#293, gap row 7).
    _unstick_stamp_machine_input "$window" "unstick-ratelimit"
    if ! _paste_line_to_window "$window" "Please continue with your task. The API rate limit has reset."; then
        unstick_log "window=$window case=B action=cascade-paste-failed fp=$fp"
        return 1
    fi
    printf '%s' "$fp" > "$UNSTICK_DIR/${window}.ratelimit.fp"
    printf '%d' "1" > "$UNSTICK_DIR/${window}.ratelimit.tries"
    unstick_log "window=$window case=B action=cascade-resumed fp=$fp audit=$(basename "$audit")"
    return 0
}

# Send the orchestrator a heads-up about the cascade we just performed.
# The orchestrator is special: it doesn't need a "please continue"
# instruction — it needs a status update so it can verify each agent
# is making progress. We also ask the orchestrator to record the
# acknowledgement in the action-log so the watcher can confirm it is
# responsive (see _check_orchestrator_ack).
_cascade_heads_up_orchestrator() {
    local n="$1"; shift
    local target="${TARGET:-orchestrator}"
    local windows=("$@")
    if ! tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qxF "$target"; then
        unstick_log "case=B action=heads-up-skip target=$target reason=window-missing"
        return 1
    fi
    # Enter to dismiss any menu (no-op if the orchestrator wasn't stuck).
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep 0.1
    local headsup
    headsup="Heads-up from watcher: rate limit reset; auto-unstuck ${n} agent window(s) (${windows[*]}). Verify each is making progress and re-dispatch if not. Then run: monitor/ng log-action monitor --event ratelimit-resume-ack --note \"saw heads-up\""
    if ! _paste_line_to_window "$target" "$headsup"; then
        unstick_log "case=B action=heads-up-failed target=$target n=$n"
        return 1
    fi
    unstick_log "case=B action=heads-up target=$target n=$n windows=${windows[*]}"
    return 0
}

# Decide whether to cascade now, wait for the reset, or skip because a
# previous cascade is still pending an ack. State is held in
# $UNSTICK_DIR:
#   ratelimit.reset.epoch   — Unix epoch when we expect the limit to
#                             reset (probed or heuristic). Cleared
#                             after a successful cascade.
#   ratelimit.cascade.epoch — Unix epoch of the most recent cascade.
#                             Cleared by _check_orchestrator_ack once
#                             the ack has landed (or the timeout
#                             fired).
#   ratelimit.last-wait.epoch — Throttle for waiting log-spam.
_act_ratelimit() {
    local windows=("$@")
    local reset_file="$UNSTICK_DIR/ratelimit.reset.epoch"
    local cascade_file="$UNSTICK_DIR/ratelimit.cascade.epoch"
    local wait_file="$UNSTICK_DIR/ratelimit.last-wait.epoch"
    local now
    now=$(date +%s)

    # If a previous cascade is still awaiting ack, don't double-fire.
    # _check_orchestrator_ack runs at the top of each detect_and_unstick
    # cycle and clears the marker.
    if [[ -f "$cascade_file" ]]; then
        return 0
    fi

    # Determine reset epoch (cached or freshly probed).
    local reset_epoch=""
    [[ -f "$reset_file" ]] && reset_epoch=$(<"$reset_file")
    if [[ -z "$reset_epoch" ]]; then
        local probed
        probed=$(_probe_ratelimit_reset)
        if [[ -n "$probed" ]]; then
            reset_epoch=$(date -d "$probed" +%s 2>/dev/null || true)
        fi
        if [[ -z "$reset_epoch" ]]; then
            local heur="${RATELIMIT_HEURISTIC_MIN:-30}"
            reset_epoch=$(( now + heur * 60 ))
            unstick_log "case=B action=schedule-cascade source=heuristic-${heur}min reset_epoch=$reset_epoch count=${#windows[@]}"
        else
            unstick_log "case=B action=schedule-cascade source=probe reset_iso=$probed reset_epoch=$reset_epoch count=${#windows[@]}"
        fi
        printf '%s\n' "$reset_epoch" > "$reset_file"
    fi

    if (( now < reset_epoch )); then
        local last_wait=0
        [[ -f "$wait_file" ]] && last_wait=$(<"$wait_file")
        # Throttle waiting-log lines to once per 5 minutes so a long
        # rate-limit window doesn't fill watcher-unstick.log.
        if (( now - last_wait >= 300 )); then
            unstick_log "case=B action=waiting reset_epoch=$reset_epoch remaining_s=$(( reset_epoch - now )) windows=${#windows[@]}"
            printf '%s' "$now" > "$wait_file"
        fi
        return 0
    fi

    # Reset has passed — perform the cascade.
    local target="${TARGET:-orchestrator}"
    local n=0
    local w
    for w in "${windows[@]}"; do
        # The orchestrator gets the heads-up, not the per-agent
        # "please continue" follow-up.
        [[ "$w" == "$target" ]] && continue
        if _cascade_unstick_to_window "$w"; then
            n=$(( n + 1 ))
        fi
    done
    _cascade_heads_up_orchestrator "$n" "${windows[@]}"
    printf '%s\n' "$now" > "$cascade_file"
    rm -f "$reset_file" "$wait_file"
    unstick_log "case=B action=cascade-complete unstuck=$n total_windows=${#windows[@]} target=$target"
}

# Verify the orchestrator acknowledged the most recent cascade by
# checking action-log.jsonl for a `ratelimit-resume-ack` event with a
# timestamp newer than the cascade. Cleans up the cascade marker once
# the ack lands or the timeout fires.
_check_orchestrator_ack() {
    local cascade_file="$UNSTICK_DIR/ratelimit.cascade.epoch"
    [[ -f "$cascade_file" ]] || return 0
    local cascade_epoch
    cascade_epoch=$(<"$cascade_file")
    if ! [[ "$cascade_epoch" =~ ^[0-9]+$ ]]; then
        rm -f "$cascade_file"
        return 0
    fi
    local now
    now=$(date +%s)
    local age=$(( now - cascade_epoch ))
    local ack_log="${ACTION_LOG:-}"
    if [[ -n "$ack_log" && -f "$ack_log" ]] && command -v jq >/dev/null 2>&1; then
        local newest_ack_ts
        newest_ack_ts=$(jq -r 'select(.event == "ratelimit-resume-ack") | .ts' "$ack_log" 2>/dev/null | tail -1)
        if [[ -n "$newest_ack_ts" ]]; then
            local newest_ack_epoch
            newest_ack_epoch=$(date -d "$newest_ack_ts" +%s 2>/dev/null || echo 0)
            if (( newest_ack_epoch > cascade_epoch )); then
                unstick_log "case=B action=orchestrator-ack ack_ts=$newest_ack_ts latency_s=$age"
                rm -f "$cascade_file"
                return 0
            fi
        fi
    fi
    local timeout="${RATELIMIT_ACK_TIMEOUT_S:-60}"
    if (( age >= timeout )); then
        unstick_log "case=B action=orchestrator-unresponsive cascade_age_s=$age timeout_s=$timeout"
        rm -f "$cascade_file"
        return 0
    fi
}

detect_and_unstick() {
    [[ "${AUTO_UNSTICK,,}" == "true" ]] || return 0
    command -v tmux >/dev/null 2>&1 || return 0
    _check_orchestrator_ack
    local windows
    windows=$(tmux list-windows -F '#{window_name}' 2>/dev/null) || return 0
    local -a ratelimit_windows=()
    local case_key
    while IFS= read -r w; do
        [[ -z "$w" ]] && continue
        case_key=$(_handle_unstick_window "$w") || true
        if [[ "$case_key" == "ratelimit" ]]; then
            ratelimit_windows+=("$w")
        fi
    done <<<"$windows"
    if (( ${#ratelimit_windows[@]} > 0 )); then
        _act_ratelimit "${ratelimit_windows[@]}"
    fi
}
