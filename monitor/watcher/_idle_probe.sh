# shellcheck shell=bash
# monitor/watcher/_idle_probe.sh — detect worker windows that have
# been "really idle" for ≥ threshold seconds, classify each as
# wrapped-up vs missing-wrap-up, and dedupe against the previous
# cycle's classification so the watcher only emits transitions.
#
# Sourced from monitor/watcher/main.sh (alongside _lib.sh,
# _github.sh, _unstick.sh). Pure functions with two append-mostly
# state files under $STATE_DIR:
#
#   - idle-state.tsv       — prior cycle's (window, class) for dedupe
#   - engagement-log.tsv   — last `busy`/`user-typing` epoch per window
#   - operator-engaged.tsv — operator-engagement marks (issues #196,
#                            #201): one row per window the operator
#                            is (or was) driving, plus the last-
#                            processed user-prompt epoch; see the
#                            "operator-engaged" section below
#   - machine-input.tsv    — watcher/orchestrator-side pane-input
#                            stamps (issue #201): rows
#                            `<window>\t<epoch>\t<src>` written by
#                            _unstick.sh nudges and
#                            monitor/paste-followup.sh; consulted to
#                            attribute user-prompt submits
#   - user-prompt/<window> — per-window "last user-prompt submitted"
#                            stamp (`<epoch>\t<session-id>`), written
#                            by monitor/worker-heartbeat.sh from the
#                            UserPromptSubmit hook. THE operator-
#                            engagement trigger: a deterministic
#                            contract event from Claude Code itself,
#                            immune to the TUI character-rewriting
#                            that distorts `tmux capture-pane` reads
#   - pane-change/<window> — per-window pane-content-change stamp
#                            (`<last_hash>\t<last_change_epoch>`),
#                            written by the observe loop each cycle
#                            from pane-state.sh's `content_hash=`
#                            field (your-org/your-nexus#205 follow-up).
#                            `last_change_epoch` is the last cycle the
#                            transcript-region hash actually differed.
#                            THE corroboration substrate: a submit
#                            marks the operator only when change is
#                            observed within the decay TTL, and a mark
#                            stays valid only while change keeps
#                            landing within it — so a static pane's
#                            mark self-expires. Replaces #270's fragile
#                            one-frame bright-marker typing stamp
#   - machine-submit/<window> — per-window "last MACHINE-attributed
#                            user-prompt submit" stamp (`<epoch>`),
#                            written by the observe loop when the
#                            attribution rule claims a submit for the
#                            orchestrator (the #205 state-machine
#                            follow-up). Consulted by the wrap-up
#                            classifier: a machine submit NEWER than
#                            the window's wrap-up supersedes the
#                            wrap-up — the worker was re-tasked, so it
#                            regresses to the normal busy →
#                            no-wrap-up lifecycle instead of staying
#                            "wrapped" on a stale hand-off
#
# Why tmux's window_activity is NOT load-bearing for either the
# idle-pool entry gate OR retain-consume: tmux bumps
# `#{window_activity}` on any output change in the pane —
# autosuggest re-renders, cursor blinks, spinner glyph swaps, the
# status-bar token counter ticking. None of those are engagement.
# Empirical confirmation on `echo-density` (issue #111): retain.ts
# at 12:43:01, no human/agent input for 18 minutes, yet
# `#{window_activity}` advanced to 13:00:50 — pane-state at that
# moment was `autosuggest-only`. So `window_activity > retain.ts`
# alone is too loose a "retain consumed" signal, and
# `now - window_activity < threshold` is too tight a "really idle"
# gate (retained workers oscillate in and out, thrashing the
# `(N retained windows suppressed: …)` footer every minute or two).
#
# The engagement-log fixes both: each cycle we stamp
# `<window>\t<now>` only when `monitor/pane-state.sh` classifies
# the pane as `busy` or `user-typing` (the two states that reflect
# real engagement), AND we backfill `<window>\t<now>` on the very
# first observation of any window (issue #44) so the age
# computation never falls back to tmux's noisy
# `#{window_activity}`. The retain-consume gate compares the
# stored engagement epoch against `retain.ts`. The idle-pool
# entry gate computes age as `now - engagement_epoch`,
# unconditionally — because the backfill guarantees every
# observed window has a row. The displayed idle-age column
# therefore reflects the current idle stretch's true start, not
# the timestamp of the last cursor blink. Trade-off: workers
# that were already idle when the watcher started (or pre-existing
# windows on a fresh watcher process) get stamped at observation
# time, so they sit in "not really idle yet" for the first 60s
# after startup before entering the pool consistently. Cheap
# price for stable footer membership.
#
# Output contract for list_really_idle_workers — one line per
# really-idle worker window:
#
#     <window-name>\t<wrap-up-class>\t<activity-age-seconds>\t<detail>
#
# where <wrap-up-class> ∈ {wrapped, wrapped-but-stub, no-wrap-up,
# idle-too-long, pane-absent, retained, operator-engaged,
# paste-unconfirmed}. Non-idle and non-worker windows (watcher,
# claude/orchestrator, monitor) are never emitted.
#
# `operator-engaged` (issues #196, #201, #205) is a suppression class
# for a window the operator drives, wrapped or never-wrapped: any
# worker whose UserPromptSubmit hook stamped a prompt submit NOT
# attributable to the orchestrator/watcher (no paste-followup /
# machine-input / spawn stamp covering the submit) AND CORROBORATED by
# observed pane-content change within the decay TTL (your-org/your-nexus#205
# follow-up — this replaces #270's fragile one-frame `user-typing`
# read; a submit with no real interaction following it is a redraw
# artifact and must not suppress the nags). While the mark is VALID the
# window classifies as `operator-engaged` instead of
# `wrapped`/`no-wrap-up` — so it does not nag "consider follow-up
# paste", its `idle_prompt` decisions are not surfaced, and it is not
# retire-eligible. The mark is SELF-EXPIRING: the moment the pane goes
# static past MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS (default 600)
# the mark lapses and the window returns to its normal
# retire-eligibility — so a still-wanted window is released (and is
# recoverable by respawn) rather than pinned open forever on a stale or
# false mark. An `engaged-done` finished-signal or a newer spawn (or
# window close) also ends it. A wrap-up does NOT: an interactive
# session that wraps stays engaged by default (the operator may have
# follow-up inquiries — the #205 state-machine follow-up); `ng wrap-up`
# prompts the agent to run `ng engaged-done` when it is finished.
# While a mark is kept valid by sustained change but the operator has
# not submitted for the grace, the away phase emits a once-per-period
# `engaged-close-reminder` (default 24 h). Full lifecycle: the
# "operator-engaged marks" section below.
#
# `pane-absent` fires when `monitor/pane-state.sh` reports
# `state ∈ {absent, empty, blocked}` for a worker window — i.e.
# the inner Claude Code process has died (pane fell back to shell
# / no input chevron), the renderer landed in an ambiguous state,
# or the pane is blocked on an unhandled overlay. Inviolable like
# `idle-too-long`: never suppressed by `window-retain`. The whole
# point is to surface a crash that nothing else surfaces.
#
# `retained` is a post-classification override applied when the
# orchestrator has logged a recent `window-retain` event for the
# window via `monitor/ng log-action monitor --event window-retain
# --extra window=<name> --extra reason=<short>`. The override
# converts a base classification of `wrapped` or `no-wrap-up` into
# `retained` (the row is collated into a footer rather than emitted
# as a stand-alone "consider close" line); `wrapped-but-stub`,
# `idle-too-long`, and `pane-absent` are inviolable and never
# suppressed — broken reports, runaway windows, and crashed panes
# must surface regardless of intent. The retain is consumed only by
# *real engagement* recorded in engagement-log.tsv (any `busy` or
# `user-typing` observation since retain.ts) and expires after
# MONITOR_RETAIN_TTL_SECONDS (default 86400 = 24h). Detail for
# `retained` rows carries the retain reason verbatim.
#
# The dedupe state file is line-oriented:
#
#     <window-name>\t<class>
#
# It captures the prior-cycle's "really idle" set. Transitions
# detected by diffing this cycle's set against the prior:
#
#   - NOT_IDLE -> IDLE_*       : emit (worker just went silent)
#   - IDLE_NO_WRAP_UP -> IDLE_WRAPPED : emit (worker landed wrap-up;
#                                       orchestrator can consider close)
#   - IDLE_* -> NOT_IDLE       : no emit (worker is busy again)
#   - IDLE_X -> IDLE_X         : no emit (still in same state)
#   - IDLE_X -> RETAINED       : suppression engaged; footer re-emits
#   - RETAINED -> IDLE_X       : suppression lifted; footer re-emits
#
# Thresholds:
#   MONITOR_IDLE_THRESHOLD_SECONDS  — "really idle" age (default 60)
#   MONITOR_IDLE_CLOSE_HOURS        — idle-too-long cutoff (default 24h)
#   MONITOR_RETAIN_TTL_SECONDS      — window-retain lifetime
#                                     (default 86400 = 24h)

# ---- internals ----------------------------------------------------------

# Emit the set of service window-names declared in the service
# registry, one per line. Consumed by _idle_list_worker_windows to
# exempt registry-declared infra/service windows from the worker
# sweep — a healthy nginx/serve window (e.g. `demo-serve` on
# :8731) is infrastructure, not a dead worker, and must never trip
# the pane-absent "relaunch or close" alarm.
#
# Mirrors bootstrap-recover.sh's `_recover_parse_registry` line
# handling so the two stay in lock-step: skip blank lines and `#`
# comments, require the exact four-field TAB shape, and take field 1
# (name). A malformed line is skipped silently — a single bad entry
# must not break the idle sweep. A missing registry yields no names,
# so the caller degrades to the hardcoded reserved set exactly as
# before. The path resolves the same way the rest of the stack does:
# $NEXUS_SERVICES_REGISTRY override, else $NEXUS_ROOT/monitor/
# services.registry, else this file's sibling monitor dir (mirrors
# the pane-state.sh / ng resolution elsewhere in this module).
_idle_registry_service_names() {
    local registry="${NEXUS_SERVICES_REGISTRY:-}"
    if [[ -z "$registry" ]]; then
        if [[ -n "${NEXUS_ROOT:-}" ]]; then
            registry="$NEXUS_ROOT/monitor/services.registry"
        else
            registry="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/services.registry"
        fi
    fi
    [[ -n "$registry" && -f "$registry" ]] || return 0
    local line name workdir launch health
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        IFS=$'\t' read -r name workdir launch health <<<"$line"
        [[ -z "$name" || -z "$workdir" || -z "$launch" || -z "$health" ]] && continue
        printf '%s\n' "$name"
    done < "$registry"
}

# List every worker window's (name, activity-epoch, index).
# Excludes the configured target window ($TARGET — the orchestrator's
# window, whatever the operator named it), the cockpit window
# ($SERVICES_WINDOW — the `svc.sh` dashboard, default `services`),
# plus the reserved names watcher / claude / orchestrator / monitor by
# convention, AND any window whose name appears in the service registry
# (field 1). Without the $TARGET exclusion, a non-default
# `monitor.target_window` makes the orchestrator's own window classify
# as a worker — it then leaks into the idle pool, the over-limit worker
# scan (double-stamping the same pane as both orchestrator and worker),
# and every other consumer of this lister. The cockpit exclusion is the
# same generalization for infra windows: the `services` window runs
# `svc.sh` (a bash dashboard loop), NOT `claude`, so the pane-state
# probe finds no inner Claude process and would (wrongly) classify it
# `pane-absent` — "relaunch or close" against a healthy cockpit
# (your-org/your-nexus#204). The registry exemption extends this to
# declared infra/service windows (a long-running nginx viewer, a deploy
# watcher): not workers, not idle-swept — their supervised loop, not the
# orchestrator, owns them. The index is required because
# monitor/pane-state.sh takes `<window-index>` or `<session>:<window>` —
# not a window name — so callers need the index to dispatch state
# classification.
# Output: <name>\t<window_activity_epoch>\t<window_index>
_idle_list_worker_windows() {
    command -v tmux >/dev/null 2>&1 || return 0
    local svc_names
    svc_names=$(_idle_registry_service_names)
    tmux list-windows -F '#{window_name}|#{window_activity}|#{window_index}' 2>/dev/null \
        | awk -F'|' -v target="${TARGET:-orchestrator}" \
              -v cockpit="${SERVICES_WINDOW:-services}" -v svc_list="$svc_names" '
            BEGIN {
                n = split(svc_list, _svc_arr, "\n")
                for (i = 1; i <= n; i++)
                    if (_svc_arr[i] != "") svc[_svc_arr[i]] = 1
            }
            $1 == "" { next }
            $1 ~ /^•/ { next }   # drop transient sandbox-notify •bell windows (see snapshot_local)
            $1 == target { next }
            $1 == cockpit { next }
            $1 == "watcher" || $1 == "claude" || $1 == "orchestrator" || $1 == "monitor" { next }
            $1 in svc { next }
            { printf "%s\t%s\t%s\n", $1, $2, $3 }
        '
}

# Window-name basename heuristic — true iff `report` (a wrap-up
# `report` basename) could plausibly belong to `window` under the
# project-slot or slug-slot conventions. Used as a fallback when an
# action-log entry has no authoritative `window` field (pre-#109).
_idle_basename_matches() {
    local rep="$1" win="$2"
    [[ "$rep" == "${win}_"*    \
       || "$rep" == *"_${win}"* \
       || "$rep" == *"-${win}"* \
       || "$rep" == *"_${win}."* ]]
}

# Locate the most recent `spawn` event for a window. Spawn events are
# recorded by `monitor/spawn-worker.sh` (issue #72) and define the
# birth ts of the window's CURRENT lifecycle. The classifier uses this
# anchor to scope wrap-up matching: a wrap-up event written before the
# spawn ts belongs to a prior life of the same window-name and must
# not be treated as authoritative. Closes the "stale wrap-up survives
# claude --continue" regression (issue #72 regression 3).
#
# Prints the ISO ts of the most recent spawn event on stdout (the same
# `ts` field jq emits); empty stdout when no spawn event exists for
# the window (legacy worker spawned before this anchor was added).
_idle_window_spawn_ts() {
    local window="$1" log_file="${2:-${STATE_DIR}/action-log.jsonl}"
    [[ -f "$log_file" ]] || return 1
    [[ -n "$window" ]]   || return 1
    if command -v jq >/dev/null 2>&1; then
        grep '"event":"spawn"' "$log_file" 2>/dev/null \
            | tac \
            | jq -r --arg w "$window" \
                'select(.window == $w) | .ts' 2>/dev/null \
            | head -1
    else
        # Pure-sed fallback: walk newest-first, find first line whose
        # window matches, extract its ts.
        local line ts entry_window
        while IFS= read -r line; do
            entry_window=$(printf '%s' "$line" | sed -n 's/.*"window":"\([^"]*\)".*/\1/p')
            [[ "$entry_window" == "$window" ]] || continue
            ts=$(printf '%s' "$line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
            [[ -n "$ts" ]] && printf '%s' "$ts"
            return 0
        done < <(grep '"event":"spawn"' "$log_file" 2>/dev/null | tac)
    fi
}

# Locate the action-log's most recent `wrap-up` event for a window.
# Two matching modes, in priority order:
#
#   1. `window` field on the event matches the target window exactly.
#      Authoritative; recorded by `ng wrap-up` from $TMUX since
#      issue #109. No false positives.
#   2. Basename heuristic against `report` field (back-compat for
#      pre-#109 entries that didn't carry `window`):
#
#         Project-slot pattern:  reports/<window>_<ts>_<slug>.md
#         Slug-slot pattern:     reports/<project>_<ts>_*<window>*.md
#
# A worker that wraps multiple times (write report → wrap → expand
# → wrap again with a fresher entry) supersedes the prior match —
# the watcher cares about the LATEST wrap-up for that window. The
# scan is tac'd to walk newest-first; the first match wins.
#
# Lifecycle scoping (issue #72): when the action-log has a `spawn`
# event for the window, only wrap-up entries with `ts >= spawn.ts`
# are considered. A wrap-up from a previous life of the window-name
# (window closed and a fresh worker reused the name; or
# `claude --continue` extended an already-wrapped session) drops out
# of scope automatically, regardless of whether engagement-log was
# pruned. Pre-spawn-event entries (legacy workers) bypass the scope
# check — preserves back-compat at the cost of leaving the original
# stale-wrap-up case open for pre-#72 windows; new spawns are
# covered.
#
# Prints `<basename>\t<ts>` on stdout and returns 0 (`<ts>` is the
# raw ISO-8601 timestamp of the matched entry, or `_NULL_`/empty for
# pre-#109 entries without one); prints nothing and returns 1 on no
# match. Callers that only want the basename use the
# `_idle_window_wrap_up_report` wrapper below.
_idle_window_wrap_up_entry() {
    local window="$1" log_file="${2:-${STATE_DIR}/action-log.jsonl}"
    [[ -f "$log_file" ]] || return 1
    [[ -n "$window" ]]   || return 1
    # Lifecycle anchor: most-recent spawn ts. Empty when no spawn
    # event exists (legacy window) — scope check is skipped in that
    # case.
    local spawn_ts spawn_epoch
    spawn_ts=$(_idle_window_spawn_ts "$window" "$log_file")
    spawn_epoch=0
    if [[ -n "$spawn_ts" ]]; then
        spawn_epoch=$(_idle_iso_to_epoch "$spawn_ts")
        [[ -n "$spawn_epoch" ]] || spawn_epoch=0
    fi
    local entry_window entry_report entry_ts entry_epoch
    if command -v jq >/dev/null 2>&1; then
        # `// "_NULL_"` keeps the tab-separated output three-column
        # even when an entry has no `window` field (pre-#109 entries).
        while IFS=$'\t' read -r entry_window entry_report entry_ts; do
            [[ -n "$entry_report" ]] || continue
            # Lifecycle scope: skip wrap-ups recorded before the
            # current spawn. Only enforced when we have a spawn
            # anchor (epoch > 0); otherwise we operate as before.
            if (( spawn_epoch > 0 )) && [[ -n "$entry_ts" && "$entry_ts" != "_NULL_" ]]; then
                entry_epoch=$(_idle_iso_to_epoch "$entry_ts")
                if [[ "$entry_epoch" =~ ^[0-9]+$ ]] \
                   && (( entry_epoch < spawn_epoch )); then
                    continue
                fi
            fi
            if [[ "$entry_window" != "_NULL_" ]]; then
                # Post-#109: authoritative window field present.
                # Match only on exact equality; skip otherwise.
                if [[ "$entry_window" == "$window" ]]; then
                    printf '%s\t%s' "$entry_report" "$entry_ts"
                    return 0
                fi
                continue
            fi
            # Pre-#109: no window field → fall back to basename heuristic.
            if _idle_basename_matches "$entry_report" "$window"; then
                printf '%s\t%s' "$entry_report" "$entry_ts"
                return 0
            fi
        done < <(grep '"event":"wrap-up"' "$log_file" \
                    | tac \
                    | jq -r '[(.window // "_NULL_"), (.report // ""), (.ts // "_NULL_")] | @tsv' 2>/dev/null)
    else
        local line
        while IFS= read -r line; do
            entry_report=$(printf '%s' "$line" \
                | sed -n 's/.*"report":"\([^"]*\)".*/\1/p')
            entry_window=$(printf '%s' "$line" \
                | sed -n 's/.*"window":"\([^"]*\)".*/\1/p')
            entry_ts=$(printf '%s' "$line" \
                | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
            [[ -n "$entry_report" ]] || continue
            if (( spawn_epoch > 0 )) && [[ -n "$entry_ts" ]]; then
                entry_epoch=$(_idle_iso_to_epoch "$entry_ts")
                if [[ "$entry_epoch" =~ ^[0-9]+$ ]] \
                   && (( entry_epoch < spawn_epoch )); then
                    continue
                fi
            fi
            if [[ -n "$entry_window" ]]; then
                if [[ "$entry_window" == "$window" ]]; then
                    printf '%s\t%s' "$entry_report" "$entry_ts"
                    return 0
                fi
                continue
            fi
            if _idle_basename_matches "$entry_report" "$window"; then
                printf '%s\t%s' "$entry_report" "$entry_ts"
                return 0
            fi
        done < <(grep '"event":"wrap-up"' "$log_file" | tac)
    fi
    return 1
}

# Basename-only view of `_idle_window_wrap_up_entry` — the historical
# interface most callers want. Prints the matching basename on stdout
# and returns 0; prints nothing and returns 1 on no match.
_idle_window_wrap_up_report() {
    local entry
    entry=$(_idle_window_wrap_up_entry "$@") || return 1
    [[ -n "$entry" ]] || return 1
    printf '%s' "${entry%%$'\t'*}"
}

# Locate the action-log's most recent `window-retain` event for a
# window. The event is recorded by the orchestrator via:
#
#     ng log-action monitor --event window-retain \
#         --extra window=<name> --extra reason=<short>
#
# Only the `window` extra matters for matching; the basename
# heuristic used for wrap-up events is intentionally NOT applied
# here — `window-retain` is a post-#109 verb, so we require an
# explicit `window` extra.
#
# Prints `<ts>\t<reason>` on stdout (tab-separated) and returns 0
# on match; prints nothing and returns 1 otherwise. `<ts>` is the
# raw ISO-8601 timestamp from the log entry; the caller is
# responsible for converting to epoch when needed.
_idle_window_retain_event() {
    local window="$1" log_file="${2:-${STATE_DIR}/action-log.jsonl}"
    [[ -f "$log_file" ]] || return 1
    [[ -n "$window" ]]   || return 1
    local entry_window entry_ts entry_reason
    if command -v jq >/dev/null 2>&1; then
        while IFS=$'\t' read -r entry_window entry_ts entry_reason; do
            [[ "$entry_window" == "$window" ]] || continue
            printf '%s\t%s' "$entry_ts" "$entry_reason"
            return 0
        done < <(grep '"event":"window-retain"' "$log_file" \
                    | tac \
                    | jq -r '[(.window // ""), (.ts // ""), (.reason // "")] | @tsv' 2>/dev/null)
    else
        local line
        while IFS= read -r line; do
            entry_window=$(printf '%s' "$line" \
                | sed -n 's/.*"window":"\([^"]*\)".*/\1/p')
            [[ "$entry_window" == "$window" ]] || continue
            entry_ts=$(printf '%s' "$line" \
                | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
            entry_reason=$(printf '%s' "$line" \
                | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p')
            printf '%s\t%s' "$entry_ts" "$entry_reason"
            return 0
        done < <(grep '"event":"window-retain"' "$log_file" | tac)
    fi
    return 1
}

# Convert an ISO-8601 timestamp (as written by `ng log-action`,
# i.e. `date -Is` form like `2026-05-11T10:11:00-07:00`) to a unix
# epoch. Prints the epoch on stdout; prints nothing on parse
# failure. GNU date only — the watcher runs on Linux.
_idle_iso_to_epoch() {
    local iso="$1"
    [[ -n "$iso" ]] || return 1
    date -d "$iso" +%s 2>/dev/null
}

# Resolve a wrap-up report basename to an absolute path on disk.
# Prefers $NEXUS_ROOT/reports/<basename>; falls back to walking up
# from the watcher's working directory (mirrors `ng report-init`'s
# `_report_reports_dir` lookup). Empty stdout when no candidate
# resolves.
_idle_resolve_report_path() {
    local basename="$1"
    [[ -n "$basename" ]] || return 1
    if [[ -n "${NEXUS_ROOT:-}" && -f "$NEXUS_ROOT/reports/$basename" ]]; then
        printf '%s' "$NEXUS_ROOT/reports/$basename"
        return 0
    fi
    local d
    d=$(pwd)
    while [[ "$d" != / && -n "$d" ]]; do
        if [[ -f "$d/reports/$basename" ]]; then
            printf '%s' "$d/reports/$basename"
            return 0
        fi
        d=$(dirname "$d")
    done
    return 1
}

# Run `ng report-check <path>` quietly. Returns 0 on pass, 1 on
# fail; prints the failing-fields summary on stdout (single line,
# `;`-joined) so the caller can include it in the emit line.
_idle_run_report_check() {
    local path="$1" ng
    if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/ng" ]]; then
        ng="$NEXUS_ROOT/monitor/ng"
    elif [[ -x "$(dirname "${BASH_SOURCE[0]}")/../ng" ]]; then
        ng=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ng
    else
        return 0  # no ng available → skip (treat as pass)
    fi
    local err
    if err=$("$ng" report-check "$path" 2>&1 >/dev/null); then
        return 0
    fi
    # Collapse the multi-line stderr to a single ;-joined summary;
    # drop the leading "ng report-check: ..." header and the
    # `incomplete:` label.
    printf '%s' "$err" \
        | grep -E '^[[:space:]]*-[[:space:]]' \
        | sed -e 's/^[[:space:]]*-[[:space:]]*//' \
        | tr '\n' ';' \
        | sed 's/;\+$//; s/^;\+//'
    return 1
}

# Read pane-state via monitor/pane-state.sh and print the bare
# `state=` key on stdout (one of {idle, busy, user-typing,
# autosuggest-only, empty, blocked, absent}, or `unknown` if the
# script couldn't run). The helper takes a window INDEX (or
# session:window pair) — not a name — so callers pass the index
# discovered by _idle_list_worker_windows.
#
# NEXUS_ROOT may be unset in tests; resolve pane-state.sh from
# this file's own directory then /monitor.
_idle_pane_state_get() {
    local window_index="$1"
    local line
    line=$(_idle_pane_state_line "$window_index")
    [[ -n "$line" ]] || { printf 'unknown'; return 0; }
    local state
    state=$(printf '%s' "$line" | sed -n 's/.*state=\([a-z-]*\).*/\1/p')
    printf '%s' "${state:-unknown}"
}

# Same call as `_idle_pane_state_get` but returns the FULL emit line
# (state + active + window + name [+ reset_at when over-limit]) so the
# caller can pull additional fields (issue #87: `reset_at` plumbing for
# over-limit classification). Empty stdout on resolver failure.
_idle_pane_state_line() {
    local window_index="$1"
    local pane_state_script
    if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/pane-state.sh" ]]; then
        pane_state_script="$NEXUS_ROOT/monitor/pane-state.sh"
    elif [[ -x "$(dirname "${BASH_SOURCE[0]}")/../pane-state.sh" ]]; then
        pane_state_script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pane-state.sh
    else
        return 0
    fi
    local hb_args=()
    if [[ -n "${MONITOR_HEARTBEAT_STALENESS_SECONDS:-}" ]] \
        && [[ "$MONITOR_HEARTBEAT_STALENESS_SECONDS" =~ ^[0-9]+$ ]]; then
        hb_args+=(--heartbeat-staleness "$MONITOR_HEARTBEAT_STALENESS_SECONDS")
    fi
    "$pane_state_script" "${hb_args[@]}" "$window_index" 2>/dev/null
}

# Extract `field=<token>` from a pane-state emit line. Empty stdout on
# miss. Used by the over-limit path to pull `reset_at` from the same
# subprocess invocation that produced the state token.
_idle_pane_line_field() {
    local line="$1" field="$2"
    [[ -n "$line" && -n "$field" ]] || return 1
    printf '%s' "$line" | sed -n "s/.*${field}=\\([^ ]*\\).*/\\1/p"
}

# ---- turn-failure (interrupted-mid-turn) marker -------------------------
#
# A worker turn that dies to an API/model error fires the StopFailure
# hook (NOT Stop), and `monitor/hooks/turn-failure-emit.sh` writes
# `$STATE_DIR/turn-failure/<window>.json`. Its presence (and freshness)
# is what separates an *interrupted-mid-turn* worker (process alive,
# empty box, paste resumes) from a *done-but-forgot-to-wrap* worker
# (also idle, also empty box, but a clean Stop fired and no marker
# exists). The classifier reads it to emit `interrupted` with the
# recovery verb instead of nagging "no-wrap-up".
#
# Freshness gate: the Stop hook clears the marker on the next
# successful turn, so a lingering marker normally means the worker is
# still stalled. But a missed clear (jq absent, unwritable dir,
# window-name reuse across a respawn) must not wedge a window forever
# — so we also require the marker's `ts` to be within
# MONITOR_TURN_FAILURE_STALENESS_SECONDS (default 1800 s, matching the
# Stop-anchored heartbeat staleness). An older marker is treated as
# absent; the window falls back to the normal wrap-up classification.
_turn_failure_path() {
    printf '%s/turn-failure/%s.json' "${STATE_DIR:-.}" "$1"
}

# _idle_turn_failure_fresh <window> <now> → exit 0 if a fresh marker
# exists, else 1. "Fresh" = file exists, parseable, and ts within the
# staleness window.
_idle_turn_failure_fresh() {
    local window="$1" now="$2"
    local f staleness ts
    f=$(_turn_failure_path "$window")
    [[ -f "$f" ]] || return 1
    staleness="${MONITOR_TURN_FAILURE_STALENESS_SECONDS:-1800}"
    [[ "$staleness" =~ ^[0-9]+$ ]] || staleness=1800
    if command -v jq >/dev/null 2>&1; then
        ts=$(jq -r '.ts // empty' "$f" 2>/dev/null) || return 1
    else
        ts=$(grep -oE '"ts"[[:space:]]*:[[:space:]]*[0-9]+' "$f" 2>/dev/null \
                | grep -oE '[0-9]+' | tail -1)
    fi
    [[ "$ts" =~ ^[0-9]+$ ]] || return 1
    local age=$(( now - ts ))
    (( age >= 0 )) || age=0
    (( age <= staleness )) || return 1
    return 0
}

# _idle_turn_failure_field <window> <field> → print a scalar field
# (category / recovery / error) from the marker, empty on miss.
_idle_turn_failure_field() {
    local window="$1" field="$2" f
    f=$(_turn_failure_path "$window")
    [[ -f "$f" ]] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$field" '.[$k] // empty' "$f" 2>/dev/null
    else
        grep -oE "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$f" 2>/dev/null \
            | sed -E 's/.*"([^"]*)"$/\1/' | tail -1
    fi
}

# Path of the engagement-log artifact. One row per worker window
# the watcher has ever observed in a `busy` or `user-typing` state
# this session: `<window>\t<last-engagement-epoch>`. Consulted by
# the retain-consume gate; written by the probe inside the main
# loop. Missing file or missing row is meaningful — see
# _engagement_log_lookup.
_engagement_log_path() {
    printf '%s/engagement-log.tsv' "${STATE_DIR:-.}"
}

# Print the last-engagement epoch for `window`. Prints nothing
# (empty stdout, exit 0) when there is no row — the caller treats
# that as "no engagement since beginning of time," i.e. the
# strongest possible retain-survives signal. We deliberately do
# NOT default to `0` inside the helper so the caller can
# distinguish "never engaged" from "engaged at unix epoch 0".
_engagement_log_lookup() {
    local window="$1" path
    path=$(_engagement_log_path)
    [[ -f "$path" ]] || return 0
    awk -F'\t' -v w="$window" '$1 == w { print $2; exit }' "$path"
}

# Stamp `<window>\t<epoch>` into the engagement-log, replacing any
# prior row for the same window so the file stays at-most-one-row-
# per-window. Atomic enough for the watcher's single-threaded poll
# (rewrite to a tmp file, then rename).
_engagement_log_stamp() {
    local window="$1" epoch="$2" path tmp
    path=$(_engagement_log_path)
    [[ -n "$window" && -n "$epoch" ]] || return 1
    mkdir -p "$(dirname "$path")"
    tmp=$(mktemp "${path}.XXXXXX")
    if [[ -f "$path" ]]; then
        awk -F'\t' -v w="$window" '$1 != w' "$path" > "$tmp"
    fi
    printf '%s\t%s\n' "$window" "$epoch" >> "$tmp"
    mv "$tmp" "$path"
}

# Drop any engagement-log row for `window`. Atomic rewrite + rename
# matching _engagement_log_stamp. Silent no-op when the file or the
# row is absent. Used by the per-cycle disappearance pruner so that
# a future resumption of the same window-name takes PR #46's
# fresh-row backfill path (no row → stamp NOW) instead of inheriting
# the prior life's epoch and immediately tripping the idle gate
# (issue #61).
_engagement_log_drop() {
    local window="$1" path tmp
    [[ -n "$window" ]] || return 1
    path=$(_engagement_log_path)
    [[ -f "$path" ]] || return 0
    tmp=$(mktemp "${path}.XXXXXX")
    awk -F'\t' -v w="$window" '$1 != w' "$path" > "$tmp"
    mv "$tmp" "$path"
}

# ---- operator-engaged marks (issues #196, #201) ---------------------------
#
# Detect that the OPERATOR is driving a worker window — wrapped or
# never-wrapped — and hold a per-window "engaged" mark for the rest
# of that window's lifecycle. The consumers:
#
#   - list_really_idle_workers classifies a marked idle window as
#     `operator-engaged` (a single deduped informational row) instead
#     of `wrapped` / `no-wrap-up`, so conversation think-gaps longer
#     than MONITOR_IDLE_THRESHOLD_SECONDS stop re-emitting
#     "idle … WITHOUT wrap-up — consider follow-up paste" every round.
#   - render_pending_decisions withholds `idle_prompt` decision rows
#     for marked windows (the turn-end pings of an operator chat are
#     not decisions the orchestrator must ack).
#   - The window-cleanup policy treats `operator-engaged` as
#     do-not-close, so an operator-driven window can't be retired.
#   - list_idle_transitions emits a low-frequency `engaged-close-
#     reminder` row once the operator has been away for a full
#     reminder period (below) — the only surface a lingering
#     operator window gets.
#
# State file `operator-engaged.tsv`, one row per window:
#
#   <window>\t<since>\t<last>\t<prompt_seen>\t<src>\t<reminded>
#
#   since       — epoch the current engagement episode started
#   last        — epoch of the last engagement-compatible observation
#   prompt_seen — epoch of the last PROCESSED user-prompt stamp
#                 (0 = none yet). The seed below fires only when the
#                 window's user-prompt stamp is newer than this, so
#                 each submit is attributed exactly once. (Pre-
#                 hook-trigger rows stored the idle-stretch start
#                 here; any such epoch predates every post-deploy
#                 stamp, so old rows converge harmlessly.)
#   src         — seed source: submit | submit-after-wrap (legacy
#                 rows may still carry typing | busy-after-wrap |
#                 busy-after-prompt from the pane-transition era)
#   reminded    — epoch of the last close-reminder emit (0 = never).
#                 Missing column (pre-#201 rows) reads as 0.
#
# Seed (CREATE) — hook-driven, the ONLY way a mark is created:
#
#   * user-prompt submit (issues #201 + the hook-trigger revision):
#     the worker's UserPromptSubmit hook stamped
#     `user-prompt/<window>` with an epoch newer than the row's
#     `prompt_seen` — someone SUBMITTED INPUT to this window. The
#     stamp is a contract event from Claude Code itself (fires the
#     instant a prompt is submitted, operator typing+Enter or
#     orchestrator paste alike); no pane content is read, so the
#     tmux-2.6 TUI character-rewriting that distorts capture-pane
#     output cannot distort the trigger. Attribution decides whose
#     submit it was:
#
#       The submit is the ORCHESTRATOR'S (no seed) iff a known
#       machine input for the window — an action-log
#       `paste-followup` event (stamped by monitor/paste-followup.sh
#       or `ng log-action … --event paste-followup --extra
#       window=W`), a machine-input.tsv row (stamped by the
#       watcher's own unstick Enter-nudges), or the window's `spawn`
#       event (launcher prompt / --resume continuation nudge) —
#       carries an epoch ≥ prompt_epoch − MONITOR_OPERATOR_ENGAGED_
#       INPUT_SLACK_SECONDS (default 120; the slack absorbs clock
#       skew between the stamp writers — paste-followup.sh stamps
#       BEFORE pasting, so its epoch normally precedes the hook's
#       by well under a second). A machine-claimed submit REGRESSES
#       the window to busy (the #205 state-machine follow-up): the
#       engagement-log is stamped at the submit epoch (resetting the
#       idle-age anchor and consuming any standing window-retain, so
#       the window reads as working again even if the busy turn falls
#       between probe cycles), and the submit epoch is recorded in
#       machine-submit/<window> so a wrap-up OLDER than it is treated
#       as superseded by the classifier (the worker was re-tasked;
#       it owes a fresh wrap-up, not a stale "wrapped" row).
#
#       Otherwise the submit is the OPERATOR'S iff it is CORROBORATED
#       by observed pane-content change within the decay TTL
#       (your-org/your-nexus#205 follow-up — this REPLACES #270's
#       fragile one-frame `user-typing` corroboration). The per-window
#       pane-change stamp's `last_change_epoch` (the last cycle the
#       transcript-region hash actually differed) must be
#       ≥ prompt_epoch − MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS
#       (default 600). A genuine submit makes the agent answer, which
#       grows the transcript and advances the change epoch within a
#       cycle; the submit may land one probe BEFORE that answer
#       renders, so corroboration is AWAITED up to the TTL.
#
#       An operator-attributed submit with NO corroborating change for
#       the whole TTL — a redraw artifact / phantom — is consumed
#       without marking. Why change instead of a bright-text read:
#       Claude Code's TUI redraws heavily distort `capture-pane`, so a
#       one-frame bright marker is missed when a person really is
#       typing and occasionally fabricated by a redraw; sustained
#       change across the much larger transcript region is far harder
#       to fake or miss. And crucially, even a mis-seeded mark now
#       SELF-EXPIRES (see EXPIRE), so the cost of an over-seed is a
#       transient suppression, never a window pinned open.
#
#     src=submit-after-wrap when the window has a current-lifecycle
#     wrap-up older than the submit (the #196 special case, kept
#     for observability); src=submit otherwise. An orchestrator
#     that pastes without stamping defeats the attribution — its
#     paste still fires the worker's UserPromptSubmit hook —
#     monitor/paste-followup.sh is the canonical paste path for
#     exactly this reason. The stamp is consumed (`prompt_seen` :=
#     stamp epoch) once attribution resolves (marked, machine-claimed,
#     or artifact-timed-out); it stays unconsumed only during the
#     bounded await for corroboration.
#
#   Pane-state's role is REFRESH-ONLY (soft fallback): a busy /
#   working-background / working-self-paced observation can extend an
#   existing fresh mark's `last` (the away-phase clock), never create a
#   mark. `user-typing` is excluded even here — that bright-marker read
#   is the unreliable signal #270 over-trusted. The idle→busy
#   pane-transition seed is long gone for the same reason.
#
#   REFRESH — while the mark is fresh (within the grace): a newer
#     CORROBORATED operator-attributed user-prompt stamp bumps `last`
#     to the stamp epoch; a busy / working-background /
#     working-self-paced pane observation bumps `last` to now (soft
#     liveness, refresh only). The change clock that gates VALIDITY is
#     refreshed separately, every cycle, from the content hash.
#     CRUCIALLY, attribution re-runs on every newer submit, mark present
#     or not: a newer MACHINE-attributed submit (paste-followup /
#     unstick / spawn within slack) REGRESSES an existing mark to busy —
#     it zeroes the mark fields, not merely `prompt_seen` — so a
#     correctly-stamped orchestrator relay landing on an already-marked
#     window can SELF-HEAL a stale/mis-seeded operator mark (bug B; live
#     incident 2026-06-18). Without this, REFRESH bumped `prompt_seen`
#     while leaving `since`/`src` intact, and a properly machine-stamped
#     paste was structurally incapable of clearing the mark.
#   EXPIRE (THE part-A self-expiry; your-org/your-nexus#205 follow-up)
#     — `_openg_marked` holds the mark VALID only while the pane has
#     changed within MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS. Once
#     the pane goes static past the TTL (operator stepped away, or the
#     mark was an artifact), the mark LAPSES and the window returns to
#     its normal retire-eligibility — every suppression surface drops
#     it at once. This is the non-negotiable bias toward RELEASE: a
#     window is never pinned open indefinitely on a stale/false mark.
#   AWAY (close reminder; issue #201) — a SEPARATE soft clock on `last`
#     (last operator submit): when a mark is kept VALID by sustained
#     change but the operator hasn't submitted for
#     MONITOR_OPERATOR_ENGAGED_GRACE_SECONDS (default 1800), the
#     episode is "away". While away < MONITOR_OPERATOR_ENGAGED_CLOSE_
#     REMINDER_SECONDS (default 86400) nothing emits; once away ≥ that
#     period, list_idle_transitions emits ONE "consider closing"
#     reminder per period (`reminded` stamps the cadence). A returning
#     operator-attributed submit re-seeds and resets `reminded`. (With
#     the change-TTL far below the grace, most abandoned windows EXPIRE
#     before they can go away; this reminder is the surface for the
#     narrow case of a window the agent keeps changing on the
#     operator's behalf without fresh submits.)
#   INVALIDATE — an `engaged-done` or spawn event NEWER than `since`
#     kills the mark immediately (regardless of change): `engaged-done`
#     is the agent's explicit finished-signal for an interactive
#     session (`ng engaged-done`, prompted by `ng wrap-up`'s
#     interactive-wrap clarification — the #205 state-machine
#     follow-up), and a fresh spawn is a new lifecycle. A WRAP-UP no
#     longer invalidates: an interactive session that wraps stays
#     engaged by default, because the operator may have follow-up
#     inquiries; the self-expiry (EXPIRE above) still bounds an
#     abandoned mark to the change TTL, so "stay engaged by default"
#     can never pin a window open indefinitely.
#   PRUNE — rows for disappeared windows are dropped alongside the
#     engagement-log rows in the per-cycle disappearance pruner;
#     the window's user-prompt and pane-change stamp files are
#     removed there too.
#
# Note the marked short-circuit runs before the idle-too-long
# override: a VALID (change-corroborated) operator-engaged window does
# not trip the runaway-window alarm; once it expires, idle-too-long
# applies normally again.

_openg_path() {
    printf '%s/operator-engaged.tsv' "${STATE_DIR:-.}"
}

_openg_grace_seconds() {
    local g="${MONITOR_OPERATOR_ENGAGED_GRACE_SECONDS:-}"
    if [[ ! "$g" =~ ^[0-9]+$ ]]; then
        g=""
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
            g=$("$NEXUS_ROOT/config/load.sh" monitor.operator_engaged_grace_seconds 1800 2>/dev/null || echo 1800)
        fi
        [[ "$g" =~ ^[0-9]+$ ]] || g=1800
    fi
    printf '%s' "$g"
}

# Cadence of the "operator away — consider closing" reminder
# (issue #201). Also the away-time floor before the FIRST reminder.
_openg_reminder_seconds() {
    local r="${MONITOR_OPERATOR_ENGAGED_CLOSE_REMINDER_SECONDS:-}"
    if [[ ! "$r" =~ ^[0-9]+$ ]]; then
        r=""
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
            r=$("$NEXUS_ROOT/config/load.sh" monitor.operator_engaged_close_reminder_seconds 86400 2>/dev/null || echo 86400)
        fi
        [[ "$r" =~ ^[0-9]+$ ]] || r=86400
    fi
    printf '%s' "$r"
}

# Attribution slack for the user-prompt-submit seed: a machine-input
# stamp this many seconds OLDER than the submit's hook epoch still
# claims the submit. Absorbs clock skew between the stamp writers;
# over-claiming only delays an operator seed to the operator's next
# message.
_openg_input_slack_seconds() {
    local s="${MONITOR_OPERATOR_ENGAGED_INPUT_SLACK_SECONDS:-120}"
    [[ "$s" =~ ^[0-9]+$ ]] || s=120
    printf '%s' "$s"
}

# Ledger of watcher-side machine inputs into worker panes (unstick
# Enter-nudges and the like): append-only rows `<window>\t<epoch>\t<src>`,
# written by _unstick.sh via the MACHINE_INPUT_TSV global and by
# monitor/paste-followup.sh. Compacted by the per-cycle pruner.
_machine_input_path() {
    printf '%s/machine-input.tsv' "${STATE_DIR:-.}"
}

# Per-window "last user-prompt submitted" stamp, written by
# monitor/worker-heartbeat.sh from the worker's UserPromptSubmit
# hook (`<epoch>\t<session-id>`). THE engagement trigger.
_user_prompt_stamp_path() {
    printf '%s/user-prompt/%s' "${STATE_DIR:-.}" "$1"
}

# Epoch of the newest user-prompt submit stamped for `window`;
# prints `0` when no stamp exists (window never submitted to since
# the hook started stamping, or the stamp was pruned with the
# window). Deterministic contract data — never pane content.
_openg_user_prompt_epoch() {
    local window="$1" path e
    [[ -n "$window" ]] || { printf '0'; return 0; }
    path=$(_user_prompt_stamp_path "$window")
    [[ -f "$path" ]] || { printf '0'; return 0; }
    e=$(awk -F'\t' 'NR == 1 { print $1; exit }' "$path" 2>/dev/null)
    [[ "$e" =~ ^[0-9]+$ ]] || e=0
    printf '%s' "$e"
}

# Session-id column of the newest user-prompt submit stamped for
# `window`. worker-heartbeat.sh writes the stamp as
# `<epoch>\t<session-id>` — the session-id is claude's OWN session
# (the hook fires inside the pane's Claude Code process), so it
# identifies WHICH session submitted the prompt. Empty stdout +
# non-zero when no stamp / no session-id column.
_openg_user_prompt_session() {
    local window="$1" path sid
    [[ -n "$window" ]] || return 1
    path=$(_user_prompt_stamp_path "$window")
    [[ -f "$path" ]] || return 1
    sid=$(awk -F'\t' 'NR == 1 { print $2; exit }' "$path" 2>/dev/null)
    [[ -n "$sid" ]] || return 1
    printf '%s' "$sid"
}

# The window's OWN spawn session-id — the `--session-id` UUID
# spawn-worker.sh generates at birth (your-org/your-nexus#206) and
# records in the provenance record `windows/<window>.json`
# (`.session_id`). Primary source is that record; a spawn action-log
# `session-id=` extra is the fallback for a window whose provenance
# JSON is absent. Empty stdout + non-zero when neither is available
# (loop-wrapper workers take no `--session-id`, so their own session
# is unknowable here — the self-classification simply does not fire,
# falling back to the pre-existing attribution). The window-name is
# sanitized identically to spawn-worker.sh's `_write_provenance_record`.
_openg_window_own_session() {
    local window="$1" f sid=""
    [[ -n "$window" ]] || return 1
    f="${STATE_DIR:-.}/windows/${window//[^a-zA-Z0-9_-]/_}.json"
    if [[ -f "$f" ]]; then
        if command -v jq >/dev/null 2>&1; then
            sid=$(jq -r '.session_id // empty' "$f" 2>/dev/null) || sid=""
        else
            sid=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)
        fi
    fi
    if [[ -z "$sid" ]]; then
        # Fallback: newest spawn action-log event's `session-id=` extra.
        local log_file="${STATE_DIR:-.}/action-log.jsonl"
        if [[ -f "$log_file" ]] && command -v jq >/dev/null 2>&1; then
            sid=$(grep '"event":"spawn"' "$log_file" 2>/dev/null | tac \
                | jq -r --arg w "$window" \
                    'select(.window == $w) | .["session-id"] // empty' 2>/dev/null \
                | head -1) || sid=""
        fi
    fi
    [[ -n "$sid" ]] || return 1
    printf '%s' "$sid"
}

# TRUE when `window`'s newest user-prompt submit was stamped with the
# window's OWN spawn session-id — provably machine/self input, NOT the
# operator. The operator drives a DIFFERENT Claude Code session and
# never types into a spawned worker's pane, so a submit carrying the
# worker's own session-id is autosuggest / post-wrap typing / the
# worker's own tool loop (the coembed-283-followup false positive,
# 2026-07-17). Requires BOTH ids present AND equal — any doubt (a
# missing stamp session-id, an unknown own session-id) returns FALSE,
# so the pre-existing attribution stays in force and a genuine operator
# submit (a DIFFERENT session-id) is never misclassified as self.
_openg_prompt_is_self() {
    local window="$1" stamp_sid own_sid
    [[ -n "$window" ]] || return 1
    stamp_sid=$(_openg_user_prompt_session "$window") || return 1
    own_sid=$(_openg_window_own_session "$window") || return 1
    [[ -n "$stamp_sid" && -n "$own_sid" && "$stamp_sid" == "$own_sid" ]]
}

# Remove `window`'s user-prompt stamp (disappearance prune). A
# reused window-name then starts from "no submit yet" instead of
# inheriting the prior life's stamp.
_user_prompt_stamp_drop() {
    local window="$1"
    [[ -n "$window" ]] || return 1
    rm -f "$(_user_prompt_stamp_path "$window")" 2>/dev/null || true
}

# Decay TTL for the change-corroboration signal (your-org/your-nexus#205
# follow-up). THE knob that makes the operator-engaged mark
# self-expiring and bias toward RELEASE. A present-mark stays valid
# only while the pane has CHANGED (transcript content) within this many
# seconds; once the pane has been static past the TTL the mark lapses
# and the window returns to its normal retire-eligibility. The same
# TTL bounds create/refresh corroboration: an operator-attributed
# submit not accompanied by observed pane change within the TTL is
# treated as a redraw artifact and never marks.
#
# Must span at least a couple watcher cycles (default cycle 60 s) so a
# normal think-pause — operator reading a long answer, composing the
# next message — doesn't drop a real session. Default 600 (10 min):
# generous for think-pauses (and a real submit re-corroborates the
# instant the agent answers), yet short enough that a stale or false
# mark releases the window within minutes instead of pinning it open
# for the 24 h away-grace. Env: MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS;
# config: monitor.operator_engaged_change_ttl_seconds.
_openg_change_ttl_seconds() {
    local t="${MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS:-}"
    if [[ ! "$t" =~ ^[0-9]+$ ]]; then
        t=""
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
            t=$("$NEXUS_ROOT/config/load.sh" monitor.operator_engaged_change_ttl_seconds 600 2>/dev/null || echo 600)
        fi
        [[ "$t" =~ ^[0-9]+$ ]] || t=600
    fi
    printf '%s' "$t"
}

# Per-window pane-content-change stamp (your-org/your-nexus#205
# follow-up): `<last_hash>\t<last_change_epoch>`. `last_hash` is the
# most recent `content_hash` pane-state.sh reported for the window;
# `last_change_epoch` is the epoch that hash last DIFFERED from the
# prior one (or first-sight). Updated every cycle by _openg_observe
# from the pane-state line's `content_hash=` field. THE corroboration
# substrate: sustained change keeps a mark valid, stasis lets it lapse.
# Replaces #270's fragile one-frame `user-typing` (typing-observed)
# stamp — a screen read distorted by TUI redraws must not be the
# load-bearing signal for holding a window open.
_openg_change_path() {
    printf '%s/pane-change/%s' "${STATE_DIR:-.}" "$1"
}

# Epoch the pane content last changed for `window`; `0` when no stamp
# exists (never observed with a hash, or pruned with the window).
# Callers read 0 as "no corroboration" — which, per the release bias,
# means the mark does NOT hold.
_openg_change_epoch() {
    local window="$1" path e
    [[ -n "$window" ]] || { printf '0'; return 0; }
    path=$(_openg_change_path "$window")
    [[ -f "$path" ]] || { printf '0'; return 0; }
    e=$(awk -F'\t' 'NR == 1 { print $2; exit }' "$path" 2>/dev/null)
    [[ "$e" =~ ^[0-9]+$ ]] || e=0
    printf '%s' "$e"
}

# Record this cycle's pane content hash for `window` at `now`,
# advancing `last_change_epoch` to `now` iff the hash DIFFERS from the
# stored one (or there was no stored one — first sight counts as a
# change so a freshly-observed window starts corroborated). A repeated
# (identical) hash leaves `last_change_epoch` frozen — that frozen
# epoch is exactly what lets a static pane's mark age out. Forgiving:
# any failure skips the stamp, never the caller.
_openg_change_stamp() {
    local window="$1" hash="$2" now="$3" path tmp prev_hash prev_epoch new_epoch
    [[ -n "$window" && -n "$hash" && "$now" =~ ^[0-9]+$ ]] || return 0
    path=$(_openg_change_path "$window")
    prev_hash=""; prev_epoch=0
    if [[ -f "$path" ]]; then
        IFS=$'\t' read -r prev_hash prev_epoch < "$path" 2>/dev/null
        [[ "$prev_epoch" =~ ^[0-9]+$ ]] || prev_epoch=0
    fi
    if [[ "$hash" == "$prev_hash" ]]; then
        new_epoch="$prev_epoch"
    else
        new_epoch="$now"
    fi
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
    tmp="${path}.$$.tmp"
    if printf '%s\t%s\n' "$hash" "$new_epoch" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# Mark `window`'s pane content changed AT `now` without a hash to
# compare — used when pane-state took the heartbeat-authoritative
# busy/working fast path and emitted no `content_hash` (no capture
# taken), yet the agent is demonstrably working (the transcript IS
# streaming). Keeps the change clock fresh through a long busy stretch
# so a genuinely-working window's mark isn't aged out by the absence
# of a hash. Preserves the stored hash so the next real comparison is
# still anchored.
_openg_change_touch() {
    local window="$1" now="$2" path tmp prev_hash prev_epoch
    [[ -n "$window" && "$now" =~ ^[0-9]+$ ]] || return 0
    path=$(_openg_change_path "$window")
    prev_hash=""
    [[ -f "$path" ]] && IFS=$'\t' read -r prev_hash prev_epoch < "$path" 2>/dev/null
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
    tmp="${path}.$$.tmp"
    if printf '%s\t%s\n' "$prev_hash" "$now" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# Remove `window`'s pane-change stamp (disappearance prune),
# mirroring _user_prompt_stamp_drop.
_openg_change_drop() {
    local window="$1"
    [[ -n "$window" ]] || return 1
    rm -f "$(_openg_change_path "$window")" 2>/dev/null || true
}

# Per-window "last MACHINE-attributed user-prompt submit" stamp (the
# #205 state-machine follow-up): bare `<epoch>`, written by
# _openg_observe's machine branch when the attribution rule claims a
# submit for the orchestrator. THE wrap-up supersession substrate: the
# classifier treats a wrap-up OLDER than this epoch as stale — the
# orchestrator re-tasked the worker after its hand-off, so the window
# regresses to the normal busy → no-wrap-up lifecycle.
_machine_submit_stamp_path() {
    printf '%s/machine-submit/%s' "${STATE_DIR:-.}" "$1"
}

# Epoch of the newest machine-attributed submit for `window`; `0`
# when none recorded (window never received an orchestrator-claimed
# submit, or the stamp was pruned with the window).
_openg_machine_submit_epoch() {
    local window="$1" path e
    [[ -n "$window" ]] || { printf '0'; return 0; }
    path=$(_machine_submit_stamp_path "$window")
    [[ -f "$path" ]] || { printf '0'; return 0; }
    e=$(awk 'NR == 1 { print $1; exit }' "$path" 2>/dev/null)
    [[ "$e" =~ ^[0-9]+$ ]] || e=0
    printf '%s' "$e"
}

# Record a machine-attributed submit at `epoch`. Forgiving: any
# failure skips the stamp, never the caller.
_machine_submit_stamp_write() {
    local window="$1" epoch="$2" path tmp
    [[ -n "$window" && "$epoch" =~ ^[0-9]+$ ]] || return 0
    path=$(_machine_submit_stamp_path "$window")
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
    tmp="${path}.$$.tmp"
    if printf '%s\n' "$epoch" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# Remove `window`'s machine-submit stamp (disappearance prune),
# mirroring _user_prompt_stamp_drop.
_machine_submit_stamp_drop() {
    local window="$1"
    [[ -n "$window" ]] || return 1
    rm -f "$(_machine_submit_stamp_path "$window")" 2>/dev/null || true
}

# Epoch of the newest known MACHINE input delivered to `window`'s
# pane, across all three stamp sources:
#   1. action-log `paste-followup` events (orchestrator follow-up
#      pastes via monitor/paste-followup.sh or ng log-action),
#   2. machine-input.tsv rows (watcher-internal sends + the paste
#      helper's authoritative direct stamp),
#   3. the window's `spawn` event (launcher prompt; `--resume`
#      continuation nudges ride the respawn's spawn event).
# Prints `0` when none. A user-prompt submit whose epoch is ≤ this
# epoch + slack is explained as machine input; see the section
# header's attribution rule.
_openg_machine_input_epoch() {
    local window="$1" best=0 e ts
    [[ -n "$window" ]] || { printf '0'; return 0; }
    local log_file="${STATE_DIR:-.}/action-log.jsonl"
    if [[ -f "$log_file" ]]; then
        if command -v jq >/dev/null 2>&1; then
            ts=$(grep '"event":"paste-followup"' "$log_file" 2>/dev/null \
                | tac \
                | jq -r --arg w "$window" \
                    'select(.window == $w) | .ts' 2>/dev/null \
                | head -1)
        else
            ts=""
            local line entry_window
            while IFS= read -r line; do
                entry_window=$(printf '%s' "$line" \
                    | sed -n 's/.*"window":"\([^"]*\)".*/\1/p')
                [[ "$entry_window" == "$window" ]] || continue
                ts=$(printf '%s' "$line" \
                    | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
                break
            done < <(grep '"event":"paste-followup"' "$log_file" 2>/dev/null | tac)
        fi
        if [[ -n "$ts" ]]; then
            e=$(_idle_iso_to_epoch "$ts")
            [[ "$e" =~ ^[0-9]+$ ]] && (( e > best )) && best=$e
        fi
    fi
    local mi
    mi=$(_machine_input_path)
    if [[ -f "$mi" ]]; then
        e=$(awk -F'\t' -v w="$window" \
            '$1 == w && $2 ~ /^[0-9]+$/ && ($2 + 0) > m { m = $2 + 0 } END { print m + 0 }' \
            "$mi" 2>/dev/null)
        [[ "$e" =~ ^[0-9]+$ ]] && (( e > best )) && best=$e
    fi
    ts=$(_idle_window_spawn_ts "$window")
    if [[ -n "$ts" ]]; then
        e=$(_idle_iso_to_epoch "$ts")
        [[ "$e" =~ ^[0-9]+$ ]] && (( e > best )) && best=$e
    fi
    printf '%s' "$best"
}

# ---- injection ↔ hook pairing validation (the #205 state-machine
# follow-up) ----------------------------------------------------------
#
# The attribution rule above answers "whose was this submit?". The
# inverse defect — an orchestrator paste that never BECAME a submit —
# was previously invisible: paste-followup.sh stamps the ledger, the
# paste lands in the pane, but the Enter is swallowed (VI mode, an
# overlay, a race with a redraw) and the worker's UserPromptSubmit hook
# never fires. The orchestrator believes the worker was nudged; the
# worker sits idle on queued text. The `paste-unconfirmed` class
# surfaces exactly that: a guaranteed-submit paste older than the
# confirm grace with NO user-prompt stamp at-or-after it.
#
# Scope guards (each suppresses the flag, biasing toward silence):
#   - only `paste-followup` stamps count — unstick Enter-nudges submit
#     only IF text is queued, and `--no-enter` pastes (ledger src
#     `paste-followup-no-enter`; action-log `no_enter=1`) deliberately
#     don't submit, so neither implies a hook MUST have fired;
#   - the window must have a live heartbeat file (hooks demonstrably
#     installed) — a hook-less legacy worker can never confirm a paste;
#   - the paste must belong to the current spawn lifecycle.

# Confirm grace: how long after a guaranteed-submit paste the probe
# waits for the UserPromptSubmit stamp before flagging. The hook fires
# sub-second in practice; the grace only needs to absorb a slow cycle.
# Env: MONITOR_PASTE_CONFIRM_GRACE_SECONDS; config:
# monitor.paste_confirm_grace_seconds. Default 180 (3 probe cycles).
_paste_confirm_grace_seconds() {
    local g="${MONITOR_PASTE_CONFIRM_GRACE_SECONDS:-}"
    if [[ ! "$g" =~ ^[0-9]+$ ]]; then
        g=""
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
            g=$("$NEXUS_ROOT/config/load.sh" monitor.paste_confirm_grace_seconds 180 2>/dev/null || echo 180)
        fi
        [[ "$g" =~ ^[0-9]+$ ]] || g=180
    fi
    printf '%s' "$g"
}

# Epoch of the newest UNCONFIRMED guaranteed-submit paste for `window`,
# or `0` when every paste is confirmed (or out of scope per the guards
# above, or simply too recent to judge). `now` is supplied by the
# caller's sweep so one cycle shares one clock.
_idle_unconfirmed_paste_epoch() {
    local window="$1" now="$2" best=0 e ts
    [[ -n "$window" && "$now" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
    # Hooks must demonstrably work for this window — the heartbeat
    # file is written by the same worker-heartbeat.sh that writes the
    # user-prompt stamp, so its absence means "cannot confirm",
    # not "unconfirmed".
    [[ -f "${STATE_DIR:-.}/heartbeat/$window.json" ]] || { printf '0'; return 0; }
    # Newest guaranteed-submit paste epoch across both stamp surfaces.
    local mi
    mi=$(_machine_input_path)
    if [[ -f "$mi" ]]; then
        e=$(awk -F'\t' -v w="$window" \
            '$1 == w && $3 == "paste-followup" && $2 ~ /^[0-9]+$/ && ($2 + 0) > m { m = $2 + 0 } END { print m + 0 }' \
            "$mi" 2>/dev/null)
        [[ "$e" =~ ^[0-9]+$ ]] && (( e > best )) && best=$e
    fi
    local log_file="${STATE_DIR:-.}/action-log.jsonl"
    if [[ -f "$log_file" ]] && command -v jq >/dev/null 2>&1; then
        ts=$(grep '"event":"paste-followup"' "$log_file" 2>/dev/null \
            | tac \
            | jq -r --arg w "$window" \
                'select(.window == $w) | select((.no_enter // "") != "1") | .ts' 2>/dev/null \
            | head -1)
        if [[ -n "$ts" ]]; then
            e=$(_idle_iso_to_epoch "$ts")
            [[ "$e" =~ ^[0-9]+$ ]] && (( e > best )) && best=$e
        fi
    fi
    (( best > 0 )) || { printf '0'; return 0; }
    # Lifecycle scope: a paste older than the current spawn belongs to
    # a prior life of the window-name.
    local spawn_ts spawn_epoch
    spawn_ts=$(_idle_window_spawn_ts "$window")
    if [[ -n "$spawn_ts" ]]; then
        spawn_epoch=$(_idle_iso_to_epoch "$spawn_ts")
        if [[ "$spawn_epoch" =~ ^[0-9]+$ ]] && (( best < spawn_epoch )); then
            printf '0'; return 0
        fi
    fi
    # Confirmed? paste-followup.sh stamps BEFORE pasting, so the hook
    # stamp lands at-or-after the ledger epoch (same host, same clock).
    local prompt_epoch
    prompt_epoch=$(_openg_user_prompt_epoch "$window")
    (( prompt_epoch >= best )) && { printf '0'; return 0; }
    # Too recent to judge — the hook may still be about to fire.
    local grace
    grace=$(_paste_confirm_grace_seconds)
    (( now - best >= grace )) || { printf '0'; return 0; }
    printf '%s' "$best"
}

# Drop machine-input rows for `window` (disappearance prune), and
# opportunistically compact the append-only ledger to one max-epoch
# row per window once it grows past 200 lines. Single writer (the
# watcher cycle), so the rewrite is race-free in practice; atomic
# rename keeps concurrent readers consistent.
_machine_input_prune() {
    local window="$1" path tmp
    path=$(_machine_input_path)
    [[ -f "$path" ]] || return 0
    tmp=$(mktemp "${path}.XXXXXX")
    if [[ -n "$window" ]]; then
        awk -F'\t' -v w="$window" '$1 != w' "$path" > "$tmp"
    else
        cat "$path" > "$tmp"
    fi
    if (( $(wc -l < "$tmp") > 200 )); then
        awk -F'\t' -v OFS='\t' \
            '$2 ~ /^[0-9]+$/ && ($2 + 0) > m[$1] { m[$1] = $2 + 0; s[$1] = $3 }
             END { for (w in m) print w, m[w], s[w] }' \
            "$tmp" > "${tmp}.compact" && mv "${tmp}.compact" "$tmp"
    fi
    mv "$tmp" "$path"
}

# Print the row's value fields
# `<since>\t<last>\t<prompt_seen>\t<src>\t<reminded>` for `window`.
# Empty stdout when there is no row. Pre-#201 5-column rows read
# their missing `reminded` as 0.
_openg_lookup() {
    local window="$1" path
    path=$(_openg_path)
    [[ -f "$path" ]] || return 0
    awk -F'\t' -v w="$window" \
        '$1 == w { printf "%s\t%s\t%s\t%s\t%s", $2, $3, $4, $5, ($6 == "" ? 0 : $6); exit }' \
        "$path"
}

# Upsert the row for `window`. Atomic rewrite + rename, mirroring
# _engagement_log_stamp.
_openg_write() {
    local window="$1" since="$2" last="$3" prompt_seen="$4" src="$5" reminded="${6:-0}" path tmp
    [[ -n "$window" ]] || return 1
    path=$(_openg_path)
    mkdir -p "$(dirname "$path")"
    tmp=$(mktemp "${path}.XXXXXX")
    if [[ -f "$path" ]]; then
        awk -F'\t' -v w="$window" '$1 != w' "$path" > "$tmp"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$window" "$since" "$last" "$prompt_seen" "$src" "$reminded" >> "$tmp"
    mv "$tmp" "$path"
}

# Drop any row for `window`. Silent no-op when file or row is absent.
_openg_drop() {
    local window="$1" path tmp
    [[ -n "$window" ]] || return 1
    path=$(_openg_path)
    [[ -f "$path" ]] || return 0
    tmp=$(mktemp "${path}.XXXXXX")
    awk -F'\t' -v w="$window" '$1 != w' "$path" > "$tmp"
    mv "$tmp" "$path"
}

# Epoch of the current-lifecycle wrap-up event for `window`; prints
# `0` when none (or when its ts is unparseable). The underlying
# matcher is already spawn-scoped, so a wrap-up from a prior life of
# the window-name yields 0 here too.
_openg_wrap_epoch() {
    local window="$1" entry ts epoch
    entry=$(_idle_window_wrap_up_entry "$window") || { printf '0'; return 0; }
    ts="${entry#*$'\t'}"
    if [[ -n "$ts" && "$ts" != "_NULL_" ]]; then
        epoch=$(_idle_iso_to_epoch "$ts")
        [[ "$epoch" =~ ^[0-9]+$ ]] && { printf '%s' "$epoch"; return 0; }
    fi
    printf '0'
}

# Epoch of the most recent `engaged-done` action-log event for
# `window` — the agent's explicit interactive-session finished-signal,
# appended by `ng engaged-done` (the #205 state-machine follow-up).
# Prints `0` when none. An engaged-done NEWER than a mark's `since`
# invalidates the mark (see _openg_marked); one older than the current
# episode's seed is inert, so a stale signal from a prior conversation
# (or a prior life of the window-name) can never kill a fresh
# engagement.
_openg_done_epoch() {
    local window="$1" log_file="${2:-${STATE_DIR}/action-log.jsonl}"
    [[ -n "$window" && -f "$log_file" ]] || { printf '0'; return 0; }
    local ts="" e
    if command -v jq >/dev/null 2>&1; then
        ts=$(grep '"event":"engaged-done"' "$log_file" 2>/dev/null \
            | tac \
            | jq -r --arg w "$window" \
                'select(.window == $w) | .ts' 2>/dev/null \
            | head -1)
    else
        local line entry_window
        while IFS= read -r line; do
            entry_window=$(printf '%s' "$line" \
                | sed -n 's/.*"window":"\([^"]*\)".*/\1/p')
            [[ "$entry_window" == "$window" ]] || continue
            ts=$(printf '%s' "$line" \
                | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
            break
        done < <(grep '"event":"engaged-done"' "$log_file" 2>/dev/null | tac)
    fi
    if [[ -n "$ts" ]]; then
        e=$(_idle_iso_to_epoch "$ts")
        [[ "$e" =~ ^[0-9]+$ ]] && { printf '%s' "$e"; return 0; }
    fi
    printf '0'
}

# Pure predicate over already-fetched values: is a mark with this
# (since, last) fresh and not invalidated by the `engaged-done`
# finished-signal at `done_epoch`? (Pre-#205-state-machine this slot
# carried the wrap-up epoch — a wrap-up no longer invalidates a mark;
# interactive sessions stay engaged across their own hand-off.)
# Callers supply `now` and `grace`.
_openg_mark_fresh() {
    local since="$1" last="$2" done_epoch="$3" now="$4" grace="$5"
    [[ "$since" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] || return 1
    (( since > 0 && last > 0 ))   || return 1
    (( now - last <= grace ))     || return 1
    (( since >= done_epoch ))     || return 1
    return 0
}

# Is `window` carrying a VALID engagement mark — seeded, not
# invalidated by a newer `engaged-done` finished-signal or spawn, AND
# still corroborated by RECENT pane-content change? (A wrap-up does
# NOT invalidate — see the INVALIDATE rule in the section header; the
# #205 state-machine follow-up.) This predicate gates every suppression
# surface, so the change-TTL check here is the load-bearing self-expiry
# (your-org/your-nexus#205 follow-up): the moment a marked window's
# pane has been static past MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS,
# this returns 1 everywhere at once and the window drops back to its
# normal retire-eligibility. A window is therefore NEVER pinned open
# indefinitely on a stale or false mark — when the signal is uncertain
# (no change stamp, or change aged out) we fail toward RELEASE, because
# a released-but-wanted window is recoverable (respawn) whereas a
# window held open on a bad mark lingers forever, the worse failure.
#
# Use `_openg_active` when "operator around right now" matters (the
# soft `last`-submit grace for the away-phase close reminder, which
# rides on top of this validity check).
_openg_marked() {
    local window="$1"
    local row since last prompt_seen src reminded
    row=$(_openg_lookup "$window")
    [[ -n "$row" ]] || return 1
    IFS=$'\t' read -r since last prompt_seen src reminded <<<"$row"
    [[ "$since" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] || return 1
    (( since > 0 && last > 0 )) || return 1
    local done_epoch
    done_epoch=$(_openg_done_epoch "$window")
    (( since >= done_epoch )) || return 1
    # Spawn-lifecycle guard: a spawn event newer than the mark means
    # a new worker took over this window-name; the mark is stale.
    local spawn_ts spawn_epoch
    spawn_ts=$(_idle_window_spawn_ts "$window")
    if [[ -n "$spawn_ts" ]]; then
        spawn_epoch=$(_idle_iso_to_epoch "$spawn_ts")
        if [[ "$spawn_epoch" =~ ^[0-9]+$ ]] && (( spawn_epoch > since )); then
            return 1
        fi
    fi
    # Self-expiry (THE part-A fix): the mark holds only while the pane
    # has changed within the decay TTL. A static/abandoned/artifact-only
    # window's change clock froze; once `now - change_epoch` exceeds the
    # TTL the mark lapses and the window becomes retire-eligible again.
    # change_epoch=0 (never observed changing) reads as not-corroborated
    # → released, per the bias above.
    local change_epoch change_ttl now
    change_epoch=$(_openg_change_epoch "$window")
    change_ttl=$(_openg_change_ttl_seconds)
    now=$(date +%s)
    (( change_epoch > 0 )) || return 1
    (( now - change_epoch <= change_ttl )) || return 1
    return 0
}

# Is `window` operator-engaged AND the operator around right now
# (mark refreshed within the grace)? Marked-but-not-active is the
# away phase: suppression continues, refresh-on-busy stops.
_openg_active() {
    local window="$1" now="$2" grace="$3"
    _openg_marked "$window" || return 1
    local row since last rest
    row=$(_openg_lookup "$window")
    IFS=$'\t' read -r since last rest <<<"$row"
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    (( now - last <= grace )) || return 1
    return 0
}

# Per-cycle bookkeeping, called for every worker window with this
# cycle's pane-state AND content hash. Three jobs:
#
#   1. CHANGE TRACKING — record this cycle's `content_hash` so the
#      per-window pane-change stamp advances `last_change_epoch`
#      whenever the transcript actually changed. When pane-state took
#      the heartbeat fast path and emitted NO hash but the agent is
#      demonstrably working (busy / working-background /
#      working-self-paced), the change clock is touched instead — the
#      transcript IS streaming, we just didn't capture it. A
#      `user-typing` read is deliberately NOT treated as change: that
#      bright-marker read is the unreliable signal #270 over-trusted,
#      so it must not on its own refresh the corroboration clock.
#
#   2. CREATE / REFRESH — a UserPromptSubmit stamp newer than
#      `prompt_seen` means someone submitted. The TRIGGER never reads
#      pane content — a distorted / garbled / unknown pane-state
#      processes the submit identically, off the deterministic stamp
#      alone. ATTRIBUTION then decides whose: a machine-input stamp
#      (paste-followup / unstick nudge / spawn) within the slack claims
#      it for the orchestrator (no mark). Otherwise the submit is the
#      operator's — but it marks ONLY when CORROBORATED by observed
#      pane change within the decay TTL (the #205-follow-up swap: a
#      one-frame bright-text read is replaced by sustained change). The
#      submit may land a cycle before the agent's answer renders, so
#      corroboration is awaited up to the TTL; an operator submit with
#      no change at all inside the TTL is a redraw artifact and is
#      consumed WITHOUT marking.
#
# Expiry is NOT handled here — `_openg_marked` lapses a mark the moment
# its pane goes static past the TTL, which is what biases toward
# release.
_openg_observe() {
    local window="$1" pane_state="$2" content_hash="$3" now="$4" grace="$5"

    # (1) Change tracking — advance the corroboration clock from the
    # captured hash, or touch it on a hashless agent-working state.
    if [[ -n "$content_hash" ]]; then
        _openg_change_stamp "$window" "$content_hash" "$now"
    else
        case "$pane_state" in
            busy|working-background|working-self-paced)
                _openg_change_touch "$window" "$now" ;;
        esac
    fi

    local row since=0 last=0 prompt_seen=0 src="" reminded=0
    row=$(_openg_lookup "$window")
    [[ -n "$row" ]] && IFS=$'\t' read -r since last prompt_seen src reminded <<<"$row"
    [[ "$since"       =~ ^[0-9]+$ ]] || since=0
    [[ "$last"        =~ ^[0-9]+$ ]] || last=0
    [[ "$prompt_seen" =~ ^[0-9]+$ ]] || prompt_seen=0
    [[ "$reminded"    =~ ^[0-9]+$ ]] || reminded=0
    local wrap_epoch done_epoch changed=0
    wrap_epoch=$(_openg_wrap_epoch "$window")
    done_epoch=$(_openg_done_epoch "$window")

    # (2) CREATE / REFRESH. A user-prompt stamp newer than
    # `prompt_seen` means someone submitted input since the last check.
    local prompt_epoch
    prompt_epoch=$(_openg_user_prompt_epoch "$window")
    if (( prompt_epoch > prompt_seen )); then
        local machine slack change_epoch change_ttl
        machine=$(_openg_machine_input_epoch "$window")
        slack=$(_openg_input_slack_seconds)
        if (( machine >= prompt_epoch - slack )); then
            # MACHINE-attributed (orchestrator paste / nudge / spawn).
            # Consume the stamp, never mark — a stalled worker the
            # orchestrator just pasted to must keep surfacing. The
            # window REGRESSES TO BUSY (the #205 state-machine
            # follow-up): stamp the engagement-log at the submit
            # epoch — resetting the idle-age anchor and consuming any
            # standing window-retain even when the busy turn falls
            # between probe cycles — and record the machine-submit
            # stamp so a wrap-up older than this follow-up reads as
            # superseded in the classifier.
            local prior_engagement
            prior_engagement=$(_engagement_log_lookup "$window")
            [[ "$prior_engagement" =~ ^[0-9]+$ ]] || prior_engagement=0
            if (( prompt_epoch > prior_engagement )); then
                _engagement_log_stamp "$window" "$prompt_epoch"
            fi
            _machine_submit_stamp_write "$window" "$prompt_epoch"
            # REGRESS any PRE-EXISTING operator-engaged mark to busy (bug
            # B; live incident 2026-06-18 watcher-robustness). A
            # machine-attributed submit means the orchestrator (re-)drove
            # this window, so a prior operator-engaged mark is now stale.
            # The CREATE path tore a mark down implicitly — a fresh window
            # reaches here with since/last already 0, so the final write
            # produced a since=0 (unmarked) row. But when a mark ALREADY
            # exists this branch left since/last/src untouched, so the
            # final write PRESERVED the stale mark and the window stayed
            # `operator-engaged` forever (only engaged-done / spawn /
            # change-TTL-expiry could tear it down). A correctly
            # paste-followup-stamped orchestrator relay was therefore
            # structurally unable to self-heal a mis-seeded mark. Zero the
            # mark fields here so the machine submit consumes the stamp AND
            # clears the mark, exactly as the CREATE path does; a later
            # genuine operator submit (no covering machine stamp) re-seeds
            # a fresh episode normally. _openg_marked requires since>0, so
            # the resulting since=0 row reads as unmarked everywhere.
            since=0; last=0; reminded=0; src="machine"
            prompt_seen="$prompt_epoch"; changed=1
        elif _openg_prompt_is_self "$window"; then
            # SELF-attributed (your-org/your-nexus, coembed-283-followup
            # 2026-07-17). No covering machine-input stamp, yet the submit
            # carries the window's OWN spawn session-id — so it is the
            # worker's own pane self-activity (autosuggest, post-wrap
            # typing, its own tool loop) under the operator's stated
            # invariant (they drive a DIFFERENT session and never raw-type
            # into a worker pane; they relay via paste-followup, which
            # machine-stamps). Note the hook fires inside the worker's own
            # session, so a human raw-typing here would stamp the same own
            # session-id — indistinguishable; that path is out of scope by
            # the invariant, and on the retire side check-1 pane-state
            # (`user-typing`/`busy`) is the live backstop. Unlike
            # the MACHINE branch above, we do NOT stamp the engagement-log
            # or machine-submit ledger: this is not the orchestrator
            # (re-)driving the window with new work, it is noise — so it
            # must neither seed an operator-engaged mark NOR reset the
            # idle-age anchor that keeps a wrapped, self-active-only window
            # retire-eligible. Consume the stamp (advance prompt_seen) so
            # attribution doesn't re-run, exactly like the phantom/redraw
            # branch below.
            prompt_seen="$prompt_epoch"; changed=1
        else
            # OPERATOR-attributed by the machine rule. Mark only when
            # corroborated by observed pane change within the TTL.
            # change_epoch advances to ~now once the agent's answer
            # renders, so a recent-enough change (before or after the
            # submit) confirms real interaction.
            change_epoch=$(_openg_change_epoch "$window")
            change_ttl=$(_openg_change_ttl_seconds)
            if (( change_epoch >= prompt_epoch - change_ttl )); then
                # Corroborated. Refresh a fresh mark, else seed a new
                # episode. Epochs come from the stamp — the submit
                # instant is exact, no poll-cycle smear. Freshness is
                # gated on the engaged-done finished-signal, NOT the
                # wrap-up: a post-wrap operator prompt refreshes the
                # surviving mark (interactive sessions span their own
                # hand-off), while a post-done prompt seeds a NEW
                # episode (the operator re-engaged a finished window).
                if _openg_mark_fresh "$since" "$last" "$done_epoch" "$now" "$grace"; then
                    (( prompt_epoch > last )) && last="$prompt_epoch"
                else
                    since="$prompt_epoch"; last="$prompt_epoch"; reminded=0
                    if (( wrap_epoch > 0 )) && (( prompt_epoch > wrap_epoch )); then
                        src="submit-after-wrap"
                    else
                        src="submit"
                    fi
                fi
                prompt_seen="$prompt_epoch"; changed=1
            elif (( now - prompt_epoch > change_ttl )); then
                # Awaited a full TTL with no corroborating change —
                # this submit was a redraw artifact / phantom. Consume
                # without marking so attribution doesn't re-run forever.
                prompt_seen="$prompt_epoch"; changed=1
            fi
            # else: still within the await window — leave the stamp
            # UNCONSUMED so the next cycle re-checks as the agent's
            # answer (and its content change) lands.
        fi
    fi

    # Pane-state soft REFRESH of `last` — never creates a mark, only
    # extends an already-fresh episode's away-phase clock so a long
    # busy turn between operator submits doesn't flap into the away
    # phase mid-conversation. `user-typing` is excluded (unreliable
    # read); mark VALIDITY no longer rides on `last` anyway — it rides
    # on the change-TTL in `_openg_marked` — so this only nudges the
    # close-reminder cadence.
    case "$pane_state" in
        busy|working-background|working-self-paced)
            if _openg_mark_fresh "$since" "$last" "$done_epoch" "$now" "$grace"; then
                last="$now"; changed=1
            fi
            ;;
    esac

    if (( changed )); then
        _openg_write "$window" "$since" "$last" "$prompt_seen" "${src:-}" "$reminded"
    fi
}

# Path of the worker-notifications JSONL log. Workers' default
# Notification hook (see `<!-- worker-hooks-default -->` in
# skills/nexus.worker-defaults/SKILL.md) `>>`-appends one row per
# claude-side notification event:
#
#   {"event":"Notification","notification":{...},"window":"<name>","ts":<epoch>}
#
# Concurrent workers append safely because each `jq -c >> path` opens,
# writes, and closes the fd; there's no long-held writer. The watcher
# reads the file every cycle to count workers awaiting input and
# rotates it when it crosses MONITOR_NOTIFICATIONS_LOG_MAX_BYTES
# (default 10MiB). Path is intentionally NOT under DIFF_DIR — it's
# event data, not a per-cycle archive.
_notifications_log_path() {
    printf '%s/worker-notifications.jsonl' "${STATE_DIR:-.}"
}

# Stamp file marking the epoch of the last `render_idle_prelude` call.
# Used to scope the awaiting-input count to events newer than the
# previous prelude render — i.e., notifications that have arrived
# since the orchestrator last saw the count. Missing file means
# "first render"; we treat that as "no scope yet" and skip the count
# rather than over-reporting every historical row.
_notifications_stamp_path() {
    printf '%s/last-prelude.ts' "${STATE_DIR:-.}"
}

# Count distinct worker windows whose latest notification row is newer
# than the supplied epoch. Pure read, no side effects on the log or
# stamp. Returns "0" on missing log, missing jq, or unparseable rows
# (silent degrade — the prelude line still renders).
#
# Distinct-by-window because two `permission_prompt`s in the same
# cycle from one worker shouldn't double-count toward "awaiting-input";
# the operator's signal is "how many workers want my attention right
# now", not "how many events arrived".
_notifications_count_distinct_since() {
    local since_epoch="${1:-0}" path
    path=$(_notifications_log_path)
    [[ -f "$path" ]] || { printf '0'; return 0; }
    # Accept both integer and fractional epochs (the prelude stamps
    # `date +%s.%N` so the comparison can disambiguate same-second
    # appends from a hook that fires during the prelude render).
    [[ "$since_epoch" =~ ^[0-9]+(\.[0-9]+)?$ ]] || since_epoch=0
    if command -v jq >/dev/null 2>&1; then
        jq -r --argjson since "$since_epoch" \
            'select((.ts // 0) > $since) | (.window // "")' \
            "$path" 2>/dev/null \
            | awk 'NF>0' \
            | sort -u \
            | awk 'END {print NR+0}'
    else
        # sed fallback: tolerate the canonical jq-emitted compact form
        # the worker hook produces. Number-typed ts; double-quoted
        # window. Robust enough for the in-house log shape.
        awk -v since="$since_epoch" '
            { ts=""; win=""
              if (match($0, /"ts":[ ]*[0-9.]+/)) {
                  s = substr($0, RSTART+5, RLENGTH-5); gsub(/[ ]/,"",s); ts = s
              }
              if (match($0, /"window":[ ]*"[^"]*"/)) {
                  w = substr($0, RSTART+9, RLENGTH-9); gsub(/^[ ]*"|"$/,"",w); win = w
              }
              if (ts == "" || win == "") next
              if (ts+0 > since+0) print win
            }' "$path" 2>/dev/null \
            | sort -u \
            | awk 'END {print NR+0}'
    fi
}

# Atomic-by-rename rotation. When the notifications log exceeds
# `max_bytes`, rename it to `<path>.<epoch>` and let the next worker
# append re-create the live file. Old archives are pruned along the
# same retention window the watcher applies to its diff archive
# (DIFF_RETENTION_DAYS, default 7 days).
#
# Race window: two appends bracketing a `mv` lose at most the second
# append's row (it lands in the rotated file rather than the new live
# file). Acceptable — the next prelude render still sees the rotated
# row's window, just labelled to the prior cycle.
#
# Silent no-op when the file doesn't exist or is below threshold.
_notifications_rotate_if_oversized() {
    local max_bytes="${1:-10485760}" path size
    path=$(_notifications_log_path)
    [[ -f "$path" ]] || return 0
    [[ "$max_bytes" =~ ^[0-9]+$ ]] || return 0
    (( max_bytes > 0 )) || return 0
    size=$(stat -c '%s' "$path" 2>/dev/null || stat -f '%z' "$path" 2>/dev/null || echo 0)
    [[ "$size" =~ ^[0-9]+$ ]] || return 0
    (( size >= max_bytes )) || return 0
    local archive
    archive="${path}.$(date +%s)"
    mv -f "$path" "$archive" 2>/dev/null || return 0
    # Best-effort cleanup of older archives. find with -mtime is the
    # cheap option; matches the pattern the watcher uses for
    # DIFF_DIR pruning.
    local retention="${DIFF_RETENTION_DAYS:-7}"
    [[ "$retention" =~ ^[0-9]+$ ]] || retention=7
    find "$(dirname "$path")" -maxdepth 1 -type f \
        -name 'worker-notifications.jsonl.*' \
        -mtime "+$retention" -delete 2>/dev/null || true
}

# Path of the previous-cycle window-set artifact. Newline-separated
# list of window names that were "tracked" in the prior cycle —
# defined as `(tmux windows the probe saw) ∪ (engagement-log keys
# left after the prior cycle's prune)`. The union is what makes the
# cold-start case (watcher restarted with a stale engagement-log row
# but no previous-windows file) prune in two cycles rather than
# never:
#
#   cycle 1 (file absent): prev=∅, current=∅ → nothing dropped;
#                          persist current ∪ engagement-log keys =
#                          {stale-row}.
#   cycle 2 (file present): prev={stale-row}, current=∅ →
#                          disappeared={stale-row} → drop. Persist ∅.
#
# A window alive across cycles stays in the file via the `current`
# half of the union; a row that's been dropped this cycle drops out
# of the union next cycle naturally because it's no longer in the
# engagement-log when we re-read.
_idle_previous_windows_path() {
    printf '%s/idle-probe-previous-windows.txt' "${STATE_DIR:-.}"
}

# ---- public surface -----------------------------------------------------

# Enumerate worker windows whose tmux activity-age ≥ threshold AND
# whose pane-state warrants surfacing; classify each into one of
# the buckets below (Pieces 1–2, 5, 8 in PR #4; pane-absent added
# in #111-extension):
#
#     wrapped           — wrap-up event exists and the cited report
#                         passes `ng report-check`.
#     wrapped-but-stub  — wrap-up event exists but the cited report
#                         fails the schema/completeness check.
#                         Detail column carries the `;`-joined
#                         missing-fields summary.
#     no-wrap-up        — really idle but no wrap-up event matches
#                         the window (orchestrator should paste the
#                         wrap-up-missing follow-up template).
#     idle-too-long     — really idle for ≥ MONITOR_IDLE_CLOSE_HOURS
#                         (default 24h, config knob
#                         monitor.idle_close_hours). Overrides the
#                         other three — once the hard-close
#                         threshold is hit the orchestrator should
#                         consider close regardless of wrap-up
#                         state. NOT suppressible by `window-retain`
#                         (a runaway window must always surface).
#     pane-absent       — pane-state is absent|empty|blocked: the
#                         inner Claude Code process is gone, the
#                         renderer is in an ambiguous state, or the
#                         pane is sitting on a stalled overlay.
#                         Inviolable like idle-too-long — never
#                         suppressed by `window-retain`.
#     retained          — base class was `wrapped` or `no-wrap-up`
#                         but the orchestrator has logged a recent
#                         `window-retain` event for this window and
#                         no real engagement (busy / user-typing)
#                         has been observed since. Collated into a
#                         `(N retained windows suppressed: …)`
#                         footer by render_idle_section instead of
#                         emitting a per-window row.
#                         `wrapped-but-stub`, `idle-too-long`, and
#                         `pane-absent` are NEVER suppressed.
#     operator-engaged  — the window carries a valid operator-
#                         engagement mark (see the "operator-engaged
#                         marks" section above): the operator drives
#                         this window — right now, or stepped away.
#                         Informational, deduped to one row per
#                         engagement episode; replaces the
#                         wrapped/no-wrap-up classification, the
#                         follow-up-paste nag, the idle-too-long
#                         alarm, and retire eligibility until the
#                         mark is invalidated by a newer wrap-up /
#                         spawn or the window closes. Once the
#                         operator has been away a full reminder
#                         period, list_idle_transitions adds a
#                         once-per-period `engaged-close-reminder`
#                         emit on top. Detail column carries the
#                         seed source (submit | submit-after-wrap;
#                         legacy rows: typing | busy-after-wrap |
#                         busy-after-prompt).
#     paste-unconfirmed — an orchestrator `paste-followup` older than
#                         MONITOR_PASTE_CONFIRM_GRACE_SECONDS
#                         (default 180) fired NO UserPromptSubmit
#                         hook on a window with live hooks — the
#                         nudge silently failed (Enter swallowed by
#                         VI mode / overlay / redraw race). Replaces
#                         the wrapped/no-wrap-up row so the
#                         orchestrator re-pastes via
#                         monitor/paste-followup.sh. Never suppressed
#                         by `window-retain`; idle-too-long still
#                         overrides it. Detail carries the paste age.
#
# Side effect: as part of each cycle this function stamps
# engagement-log.tsv twice for each observed window:
#   1. Backfill — if no row exists for the window yet, stamp with
#      `now` (first-observation baseline; closes issue #44).
#   2. Engagement refresh — if pane-state is `busy` or
#      `user-typing`, stamp with `now` (refreshes the row to the
#      current engagement moment).
# Both happen BEFORE the age gate so a worker that's actively busy
# now (low activity-age) still records engagement, and a worker
# the watcher has never seen before still gets a stable age anchor
# rather than falling through to tmux's noisy `#{window_activity}`.
#
# Output: <window>\t<class>\t<age-seconds>\t<detail>
#         (detail is the missing-fields summary for wrapped-but-stub,
#          the retain reason for retained, the pane-absent advisory
#          string for pane-absent; empty otherwise)
# parked-awaiting-skeptic exemption (skills/nexus.skeptic, PR #285).
#
# A worker parked in `skeptic-channel.sh await` is legitimately WAITING
# for a skeptic's next request, not idle and not hung. It would otherwise
# look idle to pane-state during the gaps between the renderer's spinner
# updates, and — once past the close threshold — be misclassified
# `idle-too-long` (→ the orchestrator closes it mid-handshake, killing
# the await) or nagged `no-wrap-up`.
#
# The signal is the EXISTING skeptic-pending marker
# ($STATE_DIR/skeptic/pending/<window>) — the same one ng wrap-up writes
# for a `require` gate and retire-preflight.sh blocks a close on. The
# worker's await loop refreshes the marker's mtime every poll, so a
# "live" marker (exists AND mtime within the hang threshold,
# monitor.skeptic.await_hang_seconds, default 600s) proves the worker is
# actively parked. A marker gone STALE (await died / the worker never
# entered the loop) lapses the exemption so the genuine hang resurfaces
# through normal idle classification — that is the hang-vs-wait boundary.
#
# NOTE (scope, verified PR #285): the watcher AUTO-respawns only the
# orchestrator (TARGET); worker windows are never auto-respawned on
# staleness — they are FLAGGED here and the orchestrator acts. So this
# idle-classification exemption (plus retire-preflight's existing marker
# gate) is the complete worker-side hardening; there is no separate
# worker staleness-respawn path to exempt.
#
# == emit/exemption fidelity: the marker alone is NOT proof of a skeptic ==
#
# The load-bearing correction. The skeptic-pending marker is refreshed by
# the WORKER's own `skeptic-channel await` loop (_await_heartbeat), so a
# FRESH marker proves only that the worker is parked and looping — NOT that
# a skeptic is actually reviewing. When a wrap-up's `require`/`auto` gate
# writes the marker but the orchestrator NEVER spawns the skeptic
# (observed live: `sandbox-issue-sweep --skeptic auto` parked at wrap, no
# skeptic ever dispatched), the worker parks forever, its await loop
# re-touches the marker forever, and the exemption stuck INDEFINITELY — the
# window lingered all night, never flagged idle-too-long. The exemption
# must require an ACTUAL live skeptic, with a bounded grace so the
# orchestrator has time to spawn one before we call the marker orphaned.

# Resolve the await-hang freshness window (marker mtime must be younger
# than this for the worker to count as actively parked). Env > config >
# default 600s.
_idle_skeptic_hang_seconds() {
    local hang="${MONITOR_SKEPTIC_AWAIT_HANG_SECONDS:-}"
    if [[ -z "$hang" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        hang=$("$NEXUS_ROOT/config/load.sh" monitor.skeptic.await_hang_seconds 600 2>/dev/null || echo 600)
    fi
    [[ "$hang" =~ ^[0-9]+$ ]] || hang=600
    printf '%s' "$hang"
}

# Grace window: how long a fresh marker with NO live skeptic may still
# confer the exemption (giving the orchestrator time to spawn the skeptic)
# before the marker is declared orphaned. Env > config > default 600s.
_idle_skeptic_orphan_grace() {
    local g="${MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS:-}"
    if [[ -z "$g" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        g=$("$NEXUS_ROOT/config/load.sh" monitor.skeptic.orphan_grace_seconds 600 2>/dev/null || echo 600)
    fi
    [[ "$g" =~ ^[0-9]+$ ]] || g=600
    printf '%s' "$g"
}

# Is a LIVE skeptic reviewing window $1? Authoritative signal:
# spawn-worker.sh logs a `skeptic-spawn` action-log event
# (window=<skeptic-window> target-window=<reviewed> orig-window=<chain-root>)
# at the moment a real skeptic is dispatched — the single point tied to an
# ACTUAL spawn. A live skeptic is the most-recent such event naming $1 (as
# target OR orig) whose skeptic window is still alive in tmux. Fallback: a
# live tmux window named `<$1>-skeptic` (the _skeptic_spawn_cmd template
# name), covering an action-log gap. Parsed with awk/sed (no jq dependency
# in the idle path). $2 = live tmux window names (newline-sep; queried if
# empty). Returns 0 (live skeptic present) / 1 (none).
_idle_skeptic_live_window() {
    local name="$1" live="${2:-}"
    [[ -n "$live" ]] || live=$(tmux list-windows -F '#{window_name}' 2>/dev/null)
    local log="${STATE_DIR:-}/action-log.jsonl" sw=""
    if [[ -n "$log" && -r "$log" ]]; then
        sw=$(grep -F '"event":"skeptic-spawn"' "$log" 2>/dev/null \
            | awk -v t="\"target-window\":\"${name}\"" -v o="\"orig-window\":\"${name}\"" \
                'index($0,t) || index($0,o)' \
            | sed -n 's/.*"window":"\([^"]*\)".*/\1/p' \
            | awk 'NF{last=$0} END{if(last!="")print last}')
    fi
    if [[ -n "$sw" ]] && grep -qxF -- "$sw" <<<"$live"; then
        return 0
    fi
    grep -qxF -- "${name}-skeptic" <<<"$live" && return 0
    return 1
}

# Epoch at which a skeptic was last REQUIRED for window $1 — the orphan
# grace clock. Unlike the marker mtime (refreshed by the worker's await
# loop) the `skeptic-request` action-log event's ts is written ONCE at
# wrap-up and never moves, so `now - request_epoch` is the true "how long
# has the orchestrator had to spawn a skeptic." Echoes an epoch, or 0 when
# no such event exists (caller falls back to the marker mtime).
_idle_skeptic_request_epoch() {
    local name="$1"
    local log="${STATE_DIR:-}/action-log.jsonl"
    [[ -n "$log" && -r "$log" ]] || { printf '0'; return; }
    local ts
    ts=$(grep -F '"event":"skeptic-request"' "$log" 2>/dev/null \
        | awk -v t="\"target-window\":\"${name}\"" 'index($0,t)' \
        | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p' \
        | awk 'NF{last=$0} END{if(last!="")print last}')
    [[ -n "$ts" ]] || { printf '0'; return; }
    date -d "$ts" +%s 2>/dev/null || printf '0'
}

# Returns 0 (parked → exempt) / 1 (not parked → classify normally).
# Exempt only when the marker is FRESH *and* (a live skeptic is reviewing
# OR we are still within the orphan grace since the skeptic was required).
# $3 = live tmux window names (optional; queried if empty).
_idle_skeptic_parked() {
    local name="$1" now="$2" live="${3:-}"
    local safe="${name//[^a-zA-Z0-9_-]/_}"
    local state_dir="${STATE_DIR:-}"
    [[ -n "$state_dir" ]] || return 1
    local marker="${state_dir}/skeptic/pending/${safe}"
    [[ -e "$marker" ]] || return 1
    local hang mtime age
    hang=$(_idle_skeptic_hang_seconds)
    mtime=$(date +%s -r "$marker" 2>/dev/null || echo 0)
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    age=$(( now - mtime ))
    (( age <= hang )) || return 1
    # Fresh marker — but require a live skeptic, else stay exempt only
    # within the grace window (orchestrator may still be spawning).
    if _idle_skeptic_live_window "$name" "$live"; then
        return 0
    fi
    local req grace
    req=$(_idle_skeptic_request_epoch "$name")
    [[ "$req" =~ ^[0-9]+$ ]] || req=0
    (( req == 0 )) && req="$mtime"
    grace=$(_idle_skeptic_orphan_grace)
    (( now - req <= grace )) && return 0
    return 1
}

# Returns 0 (ORPHANED: fresh marker, NO live skeptic, past grace) / 1 (not
# orphaned). The complement of the exemption's failure case that is
# actionable — a marker the orchestrator must resolve by either spawning
# the skeptic or clearing the marker. A STALE marker (await died) is NOT
# orphaned here — it lapses via the hang check and resurfaces through
# normal idle classification (the genuine-hang path). $3 = live windows.
_idle_skeptic_orphaned() {
    local name="$1" now="$2" live="${3:-}"
    local safe="${name//[^a-zA-Z0-9_-]/_}"
    local state_dir="${STATE_DIR:-}"
    [[ -n "$state_dir" ]] || return 1
    local marker="${state_dir}/skeptic/pending/${safe}"
    [[ -e "$marker" ]] || return 1
    local hang mtime age
    hang=$(_idle_skeptic_hang_seconds)
    mtime=$(date +%s -r "$marker" 2>/dev/null || echo 0)
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    age=$(( now - mtime ))
    (( age <= hang )) || return 1
    _idle_skeptic_live_window "$name" "$live" && return 1
    local req grace
    req=$(_idle_skeptic_request_epoch "$name")
    [[ "$req" =~ ^[0-9]+$ ]] || req=0
    (( req == 0 )) && req="$mtime"
    grace=$(_idle_skeptic_orphan_grace)
    (( now - req > grace ))
}

# ---- background-compute orphan-grace (your-org/nexus-code#445) -----------
#
# A SHELL-driven `working-background` verdict (pane-state.sh emits it
# with a `bg_cpu=<jiffies>` field) normally suppresses the idle probe —
# a worker running background compute (Palantir polling a job in a
# `run_in_background` shell, an `& disown` job) must NEVER be false-
# flagged `idle … WITHOUT wrap-up`. But a background shell is fire-and-
# forget: claude is not woken when it finishes, so a HUNG or
# doing-nothing shell would otherwise exempt the window forever. The
# cap: track the background subtree's CPU jiffies across cycles; while
# they advance the worker is genuinely computing (exempt), but once
# they FREEZE for the orphan grace the shell is doing nothing and the
# window falls back to normal idle classification (reapable). Mirrors
# the skeptic orphan-grace (`_idle_skeptic_orphaned`) and the #205
# pane-change stamp: stamp a token, advance the epoch only on change,
# let stasis age it out. A Monitor-handle working-background carries NO
# `bg_cpu` field (it is self-waking) and is never subjected to this cap.

# Orphan grace: how long a background shell's CPU may stay frozen
# before its `working-background` exemption lapses. Generous by design
# — the CPU-delta test means a live compute worker (any progress) never
# ages out regardless of this value, so the grace only bounds a truly
# frozen shell. Env > config > default 3600s.
_bg_orphan_grace_seconds() {
    local g="${MONITOR_BACKGROUND_ORPHAN_GRACE_SECONDS:-}"
    if [[ -z "$g" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        g=$("$NEXUS_ROOT/config/load.sh" monitor.background_orphan_grace_seconds 3600 2>/dev/null || echo 3600)
    fi
    [[ "$g" =~ ^[0-9]+$ ]] || g=3600
    printf '%s' "$g"
}

# Per-window background-CPU progress stamp: `<bg_cpu>\t<last_progress_epoch>`.
_bg_progress_path() {
    printf '%s/background-progress/%s' "${STATE_DIR:-.}" "$1"
}

# Record this cycle's bg_cpu for `window` at `now`, advancing
# `last_progress_epoch` to `now` iff the jiffy count DIFFERS from the
# stored one (or first sight — a freshly-observed background job starts
# corroborated). A repeated (identical) count leaves the epoch frozen —
# that frozen epoch is what lets a stalled shell age out. Echoes the
# resolved `last_progress_epoch`. Forgiving: any failure echoes `now`
# (treat as progressing — bias toward NOT reaping a live worker).
_bg_progress_check() {
    local window="$1" bg_cpu="$2" now="$3" path tmp prev_cpu prev_epoch new_epoch
    [[ -n "$window" && "$bg_cpu" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || { printf '%s' "$now"; return 0; }
    path=$(_bg_progress_path "$window")
    prev_cpu=""; prev_epoch=0
    if [[ -f "$path" ]]; then
        IFS=$'\t' read -r prev_cpu prev_epoch < "$path" 2>/dev/null
        [[ "$prev_epoch" =~ ^[0-9]+$ ]] || prev_epoch=0
    fi
    if [[ "$bg_cpu" == "$prev_cpu" ]]; then
        new_epoch="$prev_epoch"
        (( new_epoch > 0 )) || new_epoch="$now"
    else
        new_epoch="$now"
    fi
    mkdir -p "$(dirname "$path")" 2>/dev/null || { printf '%s' "$new_epoch"; return 0; }
    tmp="${path}.$$.tmp"
    if printf '%s\t%s\n' "$bg_cpu" "$new_epoch" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    printf '%s' "$new_epoch"
}

# Drop `window`'s background-progress stamp (disappearance prune). A
# reused window-name then starts fresh (first-sight = corroborated).
_bg_progress_drop() {
    local window="$1"
    [[ -n "$window" ]] || return 1
    rm -f "$(_bg_progress_path "$window")" 2>/dev/null || true
}

# ---- idle-with-children long timeout + clarification protocol -----------
# your-org/nexus-code#455 refine.
#
# The #445/#455 detector already tells us when an otherwise-idle worker
# still has ≥1 live background-shell child (state=working-background,
# bg_shells>=1, bg_reliable=1). Two refinements ride on that signal:
#
#   (a) A worker legitimately WAITING on a background job (a Slurm job
#       polled by a shell, a blocking `sbatch --wait`, a long compute)
#       must get a LONG, EXPONENTIALLY-BACKING-OFF grace before any
#       nudge — never reaped just because its child's CPU froze (a
#       blocking wait shows no CPU). The flat #445 orphan-grace reaped
#       such a worker after one hour; a Slurm job can run for many.
#       Instead we escalate a clarification request on a backing-off
#       schedule and only surface as reapable at a bounded hard ceiling.
#
#   (b) A worker that has already WRAPPED UP but STILL has live child
#       processes is in an inconsistent state (leftover/stale children,
#       or a premature wrap while a job runs). Surface it distinctly —
#       EXCEPT when a skeptic is pending, which is case (c).
#
#   (c) A worker parked in `skeptic-channel await` reaches (b)'s exact
#       shape BY DESIGN: `ng wrap-up` writes the skeptic-pending marker,
#       then the worker holds its re-check loop in a background shell.
#       That is `parked-awaiting-skeptic`, not an inconsistency. The
#       marker ($STATE_DIR/skeptic/pending/<window>) is authoritative;
#       when it goes stale the park lapses and (b) resurfaces.
#
# In all cases the orchestrator can inject a clarification prompt (the
# existing paste/nudge channel) instructing the worker to answer via a
# file — `monitor/worker-health.sh` writes
# `$STATE_DIR/worker-health/<window>.json`; the watcher reads it here to
# extend the grace (declared runtime), reap (stuck/done), or keep asking.
#
# DESIGN PRIORITY (your-org/nexus-code#455 follow-up — this INVERTS the
# priority PR #455 originally shipped with, which was "never false-idle a
# live worker"). The operator's ordering is:
#
#   1. Never let a worker linger forever. We would rather misclassify a
#      live worker as a retire CANDIDATE than have it stick around
#      indefinitely. Every exemption is therefore bounded by an absolute
#      ceiling that neither a worker-health declaration nor a
#      CPU-advancing child can postpone.
#   2. Inconsistent states are SURFACED for the orchestrator to
#      investigate — never silently suppressed, never auto-killed.
#
# The safety valve is unchanged and lives elsewhere: this probe only ever
# PROPOSES a class. `monitor/retire-preflight.sh` is the gate that decides
# an actual kill, and it independently refuses (safe=0) on a live worker,
# a pending skeptic, or an engaged operator. Detectors propose; preflight
# disposes.

# Backoff schedule constants (env- and config-overridable).
_bg_children_grace_base_seconds() {
    local v="${MONITOR_BG_CHILDREN_GRACE_BASE_SECONDS:-}"
    if [[ -z "$v" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        v=$("$NEXUS_ROOT/config/load.sh" monitor.background_children_grace_base_seconds 3600 2>/dev/null || echo 3600)
    fi
    [[ "$v" =~ ^[0-9]+$ ]] || v=3600
    printf '%s' "$v"
}
_bg_children_backoff_mult() {
    local v="${MONITOR_BG_CHILDREN_BACKOFF_MULT:-}"
    if [[ -z "$v" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        v=$("$NEXUS_ROOT/config/load.sh" monitor.background_children_backoff_multiplier 2 2>/dev/null || echo 2)
    fi
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 )) || v=2
    printf '%s' "$v"
}
_bg_children_interval_cap_seconds() {
    local v="${MONITOR_BG_CHILDREN_INTERVAL_CAP_SECONDS:-}"
    if [[ -z "$v" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        v=$("$NEXUS_ROOT/config/load.sh" monitor.background_children_interval_cap_seconds 21600 2>/dev/null || echo 21600)
    fi
    [[ "$v" =~ ^[0-9]+$ ]] || v=21600
    printf '%s' "$v"
}
_bg_children_grace_ceiling_seconds() {
    local v="${MONITOR_BG_CHILDREN_GRACE_CEILING_SECONDS:-}"
    if [[ -z "$v" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        v=$("$NEXUS_ROOT/config/load.sh" monitor.background_children_grace_ceiling_seconds 172800 2>/dev/null || echo 172800)
    fi
    [[ "$v" =~ ^[0-9]+$ ]] || v=172800
    printf '%s' "$v"
}
_worker_health_slack_seconds() {
    local v="${MONITOR_WORKER_HEALTH_SLACK_SECONDS:-}"
    if [[ -z "$v" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        v=$("$NEXUS_ROOT/config/load.sh" monitor.worker_health_slack_seconds 600 2>/dev/null || echo 600)
    fi
    [[ "$v" =~ ^[0-9]+$ ]] || v=600
    printf '%s' "$v"
}

# Per-window backoff state: `<child_sig>\t<level>\t<last_escalation_epoch>`.
_bg_backoff_path() { printf '%s/bg-backoff/%s' "${STATE_DIR:-.}" "$1"; }

# Read the backoff row; echoes `<sig>\t<level>\t<last_esc>`. `sig` is `-`
# (a sentinel, never a real child count) when the state file is
# absent/malformed — a bare empty first field does NOT round-trip through
# `read` because a leading tab is IFS whitespace and gets stripped.
_bg_backoff_read() {
    local window="$1" path sig level last
    path=$(_bg_backoff_path "$window")
    sig="-"; level=0; last=0
    if [[ -f "$path" ]]; then
        IFS=$'\t' read -r sig level last < "$path" 2>/dev/null
        [[ -n "$sig" ]] || sig="-"
        [[ "$level" =~ ^[0-9]+$ ]] || level=0
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
    fi
    printf '%s\t%s\t%s' "$sig" "$level" "$last"
}
_bg_backoff_write() {
    # No-op in read-only mode so a count-only probe pass never advances the
    # edge-triggered backoff level (see _bg_children_decide).
    [[ -z "${MONITOR_IDLE_PROBE_READONLY:-}" ]] || return 0
    local window="$1" sig="$2" level="$3" last="$4" path tmp
    path=$(_bg_backoff_path "$window")
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
    tmp="${path}.$$.tmp"
    if printf '%s\t%s\t%s\n' "$sig" "$level" "$last" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
}
_bg_backoff_drop() {
    local window="$1"
    [[ -n "$window" ]] || return 1
    rm -f "$(_bg_backoff_path "$window")" 2>/dev/null || true
}

# The with-children EPISODE age is DERIVED, never stored (your-org/nexus-code#455
# follow-up, round-2 skeptic finding). `pane-state.sh` reads the start epoch of
# the oldest background-shell root straight off the process tree and emits it as
# `bg_oldest_start=`; the probe subtracts it from `now`.
#
# The first cut of this stored the episode start in a `bg-firstseen` state file
# and inferred "the episode ended" from the pane state. That shape cannot be
# made correct. Keying the file on the child COUNT let ordinary churn reset the
# ceiling; keying the reset on the pane state traded that for a worse vector,
# because `autosuggest-only` is emitted from the renderer ladder BEFORE the
# process tree is ever walked (`pane-state.sh`, the `_finalize_idle_verdict`
# bypass) — so a single dim autosuggest ghost silently deleted the clock. And
# no assignment of authority to pane states fixes both that and the
# busy-boundary inheritance case: they pull in opposite directions.
#
# Deriving the age removes the entire class. It is immune to child-count churn,
# to a child exiting, to any pane rendering, and to a watcher restart. There is
# no state file to migrate, leak, or go stale.

# Worker-health clarification file, written by monitor/worker-health.sh.
_worker_health_path() { printf '%s/worker-health/%s.json' "${STATE_DIR:-.}" "$1"; }
_worker_health_drop() {
    local window="$1"
    [[ -n "$window" ]] || return 1
    rm -f "$(_worker_health_path "$window")" 2>/dev/null || true
}

# Read + validate the worker-health file for `window`. On a well-formed
# file echoes `<health>\t<expected_runtime_s>\t<written_at>\t<job_kind>\t<job_id>`
# and returns 0; returns 1 (no output) when absent/unparseable. `written_at`
# falls back to the file mtime when the field is missing. `health` is
# normalised to one of running|done|stuck (else treated as absent).
_worker_health_read() {
    local window="$1" path health expected written kind id
    path=$(_worker_health_path "$window")
    [[ -f "$path" && -r "$path" ]] || return 1
    if command -v jq >/dev/null 2>&1; then
        local row
        row=$(jq -r '[(.health // ""),
                      (.expected_runtime_s // 0),
                      (.written_at // 0),
                      (.job_kind // ""),
                      (.job_id // "")] | @tsv' "$path" 2>/dev/null) || return 1
        [[ -n "$row" ]] || return 1
        IFS=$'\t' read -r health expected written kind id <<<"$row"
    else
        # jq-less fallback: crude field extraction.
        local content
        content=$(<"$path") || return 1
        health=$(printf '%s' "$content" | sed -n 's/.*"health"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
        expected=$(printf '%s' "$content" | sed -n 's/.*"expected_runtime_s"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
        written=$(printf '%s' "$content" | sed -n 's/.*"written_at"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
        kind=$(printf '%s' "$content" | sed -n 's/.*"job_kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        id=$(printf '%s' "$content" | sed -n 's/.*"job_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi
    [[ "$expected" =~ ^[0-9]+$ ]] || expected=0
    if ! [[ "$written" =~ ^[0-9]+$ ]] || (( written == 0 )); then
        written=$(stat -c %Y "$path" 2>/dev/null || echo 0)
        [[ "$written" =~ ^[0-9]+$ ]] || written=0
    fi
    case "$health" in
        running|done|stuck) : ;;
        *) health="" ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s' "$health" "$expected" "$written" "$kind" "$id"
}

# Is this window's most-recent lifecycle event a wrap-up (i.e. wrapped and
# NOT superseded by a newer machine/operator re-task submit)? Used by the
# case-(b) inconsistency detector. Returns 0 (wrapped) / 1 (not wrapped).
_bg_window_is_wrapped() {
    local window="$1" wrap_epoch msub_epoch
    _idle_window_wrap_up_report "$window" >/dev/null 2>&1 || return 1
    wrap_epoch=$(_openg_wrap_epoch "$window")
    [[ "$wrap_epoch" =~ ^[0-9]+$ ]] && (( wrap_epoch > 0 )) || return 1
    msub_epoch=$(_openg_machine_submit_epoch "$window")
    if [[ "$msub_epoch" =~ ^[0-9]+$ ]] && (( msub_epoch > wrap_epoch )); then
        return 1   # re-tasked after wrap-up → not a wrapped state
    fi
    return 0
}

# Case (a): decide what an idle-with-live-children worker (NOT wrapped)
# should surface this cycle. Reads/writes the backoff state and honours a
# worker-health declaration. Args:
#   window now stall_start_epoch child_count oldest_child_start_epoch
# Consults the worker-health file directly. Prints `<class>\t<detail>`.
# Classes: idle-awaiting-job | idle-children-clarify | idle-too-long.
#
# The hard ceiling is ABSOLUTE (your-org/nexus-code#455 follow-up). It is
# tested before the worker-health override and against `bound_age` — the max of
# the CPU-freeze age and the with-children EPISODE age (derived from the oldest
# live background shell's start time) — so neither a `running` declaration, nor
# a child that burns a jiffy per poll, nor background shells coming and going,
# nor an `autosuggest-only` render can suppress the window past the ceiling.
# Past it the window surfaces as a retire CANDIDATE; retire-preflight remains
# the gate that decides an actual kill.
_bg_children_decide() {
    local window="$1" now="$2" stall_start="$3" child_count="$4" oldest_start="${5:-0}"
    # Read-only mode (MONITOR_IDLE_PROBE_READONLY): the prelude/full-state/
    # canonical paths call list_really_idle_workers purely to COUNT, and both
    # they and the authoritative transition emit (render_idle_section) run per
    # cycle. The backoff level-advance is edge-triggered, so if a count-only
    # call committed the escalation first, the authoritative call would see it
    # already advanced and emit `idle-awaiting-job` instead of the due
    # `idle-children-clarify` — the nudge would be lost. In read-only mode we
    # compute the class from current state but persist NOTHING (no level
    # advance, no health-file prune), so only the authoritative emit mutates.
    local ro="${MONITOR_IDLE_PROBE_READONLY:-}"
    local sig level last row
    row=$(_bg_backoff_read "$window")
    IFS=$'\t' read -r sig level last <<<"$row"
    [[ "$level" =~ ^[0-9]+$ ]] || level=0
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [[ "$sig" != "-" && "$sig" != "$child_count" ]]; then
        # The child set CHANGED across cycles → a new job started. Reset the
        # backoff and invalidate the now-stale per-job health declaration (a
        # new job earns a new grace and a fresh declaration). `-` is the
        # no-prior-state sentinel, never a real count, so it is NOT a change.
        [[ -n "$ro" ]] || _worker_health_drop "$window"
        level=0; last="$stall_start"
    elif (( last == 0 )); then
        # First sight (no prior backoff state). Initialise the clock to the
        # stall start — but do NOT drop the health file: a worker may have
        # answered the clarification before we ever wrote backoff state.
        level=0; last="$stall_start"
    fi
    sig="$child_count"
    [[ "$last" =~ ^[0-9]+$ ]] && (( last > 0 )) || last="$now"

    local base mult cap ceiling slack stall_age child_age bound_age
    base=$(_bg_children_grace_base_seconds)
    mult=$(_bg_children_backoff_mult)
    cap=$(_bg_children_interval_cap_seconds)
    ceiling=$(_bg_children_grace_ceiling_seconds)
    slack=$(_worker_health_slack_seconds)
    stall_age=$(( now - stall_start ))
    (( stall_age >= 0 )) || stall_age=0
    # `child_age` is the with-children EPISODE age, derived from the oldest
    # live background-shell's start time. Nothing but that shell exiting can
    # move it: not the child count, not the pane rendering, not a restart.
    child_age=0
    if [[ "$oldest_start" =~ ^[0-9]+$ ]] && (( oldest_start > 0 )) && (( now > oldest_start )); then
        child_age=$(( now - oldest_start ))
    fi
    bound_age="$stall_age"
    (( child_age > bound_age )) && bound_age="$child_age"

    # ABSOLUTE hard ceiling — tested BEFORE the worker-health override and
    # against `bound_age`, so no declaration and no CPU-advancing child can
    # hold the window exempt indefinitely. Past the ceiling the window becomes
    # a retire CANDIDATE (the orchestrator's retire-preflight still gates the
    # kill, and a live declaration is echoed so the investigation has context).
    if (( bound_age >= ceiling )); then
        _bg_backoff_write "$window" "$sig" "$level" "$last"
        local ceil_note="no health decl"
        local c_health c_expected c_written c_kind c_id c_row
        if c_row=$(_worker_health_read "$window"); then
            IFS=$'\t' read -r c_health c_expected c_written c_kind c_id <<<"$c_row"
            [[ -n "$c_health" ]] && ceil_note="worker declared ${c_health}${c_kind:+ (${c_kind}${c_id:+ $c_id})}"
        fi
        printf 'idle-too-long\t%d child(ren) idle %ds past the %ds ceiling; %s — retire candidate (investigate, then retire-preflight)' \
            "$child_count" "$bound_age" "$ceiling" "$ceil_note"
        return 0
    fi

    # Worker-health override. A `running` declaration extends the exemption up
    # to — but never past — the ceiling: the deadline is clamped so a worker
    # cannot declare (or repeatedly re-declare) its way out of ever surfacing.
    local h_health h_expected h_written h_kind h_id health_row
    if health_row=$(_worker_health_read "$window"); then
        IFS=$'\t' read -r h_health h_expected h_written h_kind h_id <<<"$health_row"
        case "$h_health" in
            running)
                local deadline=$(( h_written + h_expected + slack ))
                local ceil_deadline=$(( now + ceiling - bound_age ))
                local clamp_note=""
                if (( deadline > ceil_deadline )); then
                    deadline="$ceil_deadline"
                    clamp_note=", clamped to ceiling"
                fi
                if (( now < deadline )); then
                    _bg_backoff_write "$window" "$sig" "$level" "$last"
                    printf 'idle-awaiting-job\t%d child(ren); declared %s%s ~%ds (running, %ds left%s)' \
                        "$child_count" "${h_kind:-job}" "${h_id:+ $h_id}" "$h_expected" \
                        "$(( deadline - now ))" "$clamp_note"
                    return 0
                fi
                # Declared runtime elapsed → resume nudging (fall through).
                ;;
            stuck)
                _bg_backoff_write "$window" "$sig" "$level" "$last"
                printf 'idle-children-clarify\t%d child(ren); worker reports STUCK — resume or close' \
                    "$child_count"
                return 0
                ;;
            done)
                _bg_backoff_write "$window" "$sig" "$level" "$last"
                printf 'idle-children-clarify\t%d child(ren); worker reports job DONE — leftover children, safe to close' \
                    "$child_count"
                return 0
                ;;
        esac
    fi

    # Exponential-backoff nudge schedule. interval(level) = base * mult^level,
    # capped. A nudge is due when the last escalation is interval-old.
    local interval="$base" i
    for (( i = 0; i < level; i++ )); do
        interval=$(( interval * mult ))
        (( interval >= cap )) && { interval="$cap"; break; }
    done
    (( interval <= cap )) || interval="$cap"

    if (( now - last >= interval )); then
        level=$(( level + 1 ))
        _bg_backoff_write "$window" "$sig" "$level" "$now"
        printf 'idle-children-clarify\t%d child(ren) idle %ds waiting on a background job (nudge L%d) — ask the worker to declare runtime/health via monitor/worker-health.sh' \
            "$child_count" "$bound_age" "$level"
        return 0
    fi

    _bg_backoff_write "$window" "$sig" "$level" "$last"
    printf 'idle-awaiting-job\t%d child(ren) idle %ds; long-timeout backoff active (next check ~%ds, ceiling in %ds)' \
        "$child_count" "$bound_age" "$(( last + interval - now ))" "$(( ceiling - bound_age ))"
    return 0
}

# Case (b): compose the wrapped-with-children detail (health-aware).
_bg_wrapped_children_detail() {
    local window="$1" child_count="$2"
    local h_health h_expected h_written h_kind h_id health_row
    if health_row=$(_worker_health_read "$window"); then
        IFS=$'\t' read -r h_health h_expected h_written h_kind h_id <<<"$health_row"
        case "$h_health" in
            running) printf '%d live child(ren) after wrap-up; worker declares job still RUNNING (wrapped prematurely) — extend or close' "$child_count"; return 0 ;;
            done)    printf '%d live child(ren) after wrap-up; worker declares job DONE — leftover, safe to close' "$child_count"; return 0 ;;
            stuck)   printf '%d live child(ren) after wrap-up; worker reports STUCK — resume or close' "$child_count"; return 0 ;;
        esac
    fi
    printf '%d live child process(es) after wrap-up — ask for clarification (monitor/worker-health.sh) or close' "$child_count"
}

list_really_idle_workers() {
    local threshold="${MONITOR_IDLE_THRESHOLD_SECONDS:-60}"
    local close_hours="${MONITOR_IDLE_CLOSE_HOURS:-24}"
    local retain_ttl="${MONITOR_RETAIN_TTL_SECONDS:-86400}"
    # Spawn grace: newly-spawned windows skip idle-pool classification
    # for their first N seconds. The spawn-time engagement-log stamp
    # already prevents the worst brand-new-window false-positives, but
    # in the window between `tmux new-window` and the launcher running
    # `claude` the pane briefly hosts the launcher shell — pane-state
    # could legitimately classify that as `idle` and surface a
    # "no-wrap-up 60s" emit before the worker has even started.
    # Issue #72 regression 3 sub-case. Anchor: most-recent spawn event
    # ts for the window; gate measures `now - spawn_epoch`.
    local spawn_grace="${MONITOR_IDLE_POOL_SPAWN_GRACE_SECONDS:-120}"
    # Resolve close-hours and retain-ttl from config when the env
    # knob isn't set explicitly. The watcher's launcher already
    # exports MONITOR_IDLE_CLOSE_HOURS where it's wired; this
    # fallback makes the helper usable in tests that source it
    # directly.
    if [[ -z "${MONITOR_IDLE_CLOSE_HOURS:-}" ]]; then
        local cfg_close
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
            cfg_close=$("$NEXUS_ROOT/config/load.sh" monitor.idle_close_hours 24 2>/dev/null || echo 24)
            [[ "$cfg_close" =~ ^[0-9]+$ ]] && close_hours="$cfg_close"
        fi
    fi
    if [[ -z "${MONITOR_RETAIN_TTL_SECONDS:-}" ]]; then
        local cfg_ttl
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
            cfg_ttl=$("$NEXUS_ROOT/config/load.sh" monitor.retain_ttl_seconds 86400 2>/dev/null || echo 86400)
            [[ "$cfg_ttl" =~ ^[0-9]+$ ]] && retain_ttl="$cfg_ttl"
        fi
    fi
    local close_threshold=$(( close_hours * 3600 ))
    # Operator-engagement grace (issue #196), resolved once per sweep.
    local engaged_grace
    engaged_grace=$(_openg_grace_seconds)
    local now
    now=$(date +%s)
    # Live tmux window names, captured once per sweep for the skeptic
    # fidelity check (emit/exemption fidelity): the exemption is conferred
    # only when an actual skeptic window is alive, not merely when the
    # skeptic-pending marker exists.
    local live_windows
    live_windows=$(tmux list-windows -F '#{window_name}' 2>/dev/null || true)

    # Disappearance prune (issue #61). Enumerate this cycle's worker
    # windows once, compare against the previous cycle's persisted
    # set, drop engagement-log rows for any window present last
    # cycle but gone now. A resumed window-name then takes PR #46's
    # backfill path (no row → stamp NOW) instead of inheriting the
    # prior life's epoch and tripping the idle-pool gate immediately.
    local worker_windows current_set prev_windows_file prev_set
    worker_windows=$(_idle_list_worker_windows)
    current_set=$(printf '%s\n' "$worker_windows" \
                  | awk -F'\t' 'NF>0 && $1 != "" { print $1 }' \
                  | sort -u)
    prev_windows_file=$(_idle_previous_windows_path)
    prev_set=""
    [[ -f "$prev_windows_file" ]] && prev_set=$(sort -u "$prev_windows_file")
    if [[ -n "$prev_set" ]]; then
        local stale
        while IFS= read -r stale; do
            [[ -n "$stale" ]] || continue
            _engagement_log_drop "$stale"
            _openg_drop "$stale"
            _machine_input_prune "$stale"
            _user_prompt_stamp_drop "$stale"
            _openg_change_drop "$stale"
            _machine_submit_stamp_drop "$stale"
            _bg_progress_drop "$stale"
            _bg_backoff_drop "$stale"
            _worker_health_drop "$stale"
        done < <(comm -23 \
                    <(printf '%s\n' "$prev_set") \
                    <(printf '%s\n' "$current_set"))
    fi

    local name activity_epoch window_index age pane_state pane_line pane_reset_at
    while IFS=$'\t' read -r name activity_epoch window_index; do
        [[ -n "$name" && "$activity_epoch" =~ ^[0-9]+$ ]] || continue

        # Backfill: every observed window gets an engagement-log
        # row at first sight. PR #33 anchored idle-age to the
        # engagement-log epoch but fell back to `now -
        # window_activity` for windows with no row — which
        # re-introduced the autosuggest-bump flap (issue #44) for
        # workers that had been continuously idle since before
        # this watcher's process lifetime began (PR #23 era).
        # Stamping at first observation gives every window a
        # stable, monotone age anchor; the explicit trade-off is a
        # 60s post-restart grace before a previously-idle worker
        # enters the idle pool. Once stamped, the engagement-log
        # is only refreshed by genuine engagement (busy /
        # user-typing below), so the age column grows monotonically
        # and the suppressed-set footer stays stable across the
        # autosuggest re-renders / cursor blinks / status-bar ticks
        # that bump tmux's #{window_activity}.
        local existing_engagement
        existing_engagement=$(_engagement_log_lookup "$name")
        if [[ -z "$existing_engagement" ]]; then
            _engagement_log_stamp "$name" "$now"
        fi

        # pane-state.sh takes a window index. Fall back to name for
        # test stubs that don't enumerate indexes. Capture the full
        # emit line so we can pull reset_at on the over-limit branch
        # and orphan_kinds on the idle-orphan-async branch without
        # spawning a second subprocess.
        local probe_target="${window_index:-$name}"
        local pane_orphan_kinds="" pane_content_hash="" pane_bg_cpu=""
        pane_line=$(_idle_pane_state_line "$probe_target")
        if [[ -z "$pane_line" ]]; then
            pane_state=unknown
            pane_reset_at=""
        else
            pane_state=$(printf '%s' "$pane_line" \
                | sed -n 's/.*state=\([a-z-]*\).*/\1/p')
            [[ -n "$pane_state" ]] || pane_state=unknown
            pane_reset_at=$(_idle_pane_line_field "$pane_line" reset_at)
            pane_orphan_kinds=$(_idle_pane_line_field "$pane_line" orphan_kinds)
            pane_content_hash=$(_idle_pane_line_field "$pane_line" content_hash)
            pane_bg_cpu=$(_idle_pane_line_field "$pane_line" bg_cpu)
        fi

        # Background-compute orphan-grace (your-org/nexus-code#445).
        # A SHELL-driven `working-background` carries `bg_cpu=<jiffies>`.
        # Stamp its progress EVERY cycle (before the engagement stamp and
        # age gate, both of which the exemption otherwise short-circuits)
        # and decide whether the shell is genuinely computing or has gone
        # stalled/orphaned. bg_stalled=1 only when we have a real CPU
        # reading that has FROZEN past the grace — absent/blank bg_cpu (a
        # Monitor-handle working-background, or any non-shell state) never
        # stalls, preserving the existing exemption. A live compute worker
        # (any CPU delta) resets the clock and is never flagged.
        local bg_stalled=0 bg_progress_epoch=0
        if [[ "$pane_state" == "working-background" && "$pane_bg_cpu" =~ ^[0-9]+$ ]]; then
            local bg_grace
            bg_progress_epoch=$(_bg_progress_check "$name" "$pane_bg_cpu" "$now")
            bg_grace=$(_bg_orphan_grace_seconds)
            if [[ "$bg_progress_epoch" =~ ^[0-9]+$ ]] \
               && (( now - bg_progress_epoch > bg_grace )); then
                bg_stalled=1
            fi
        fi

        # Idle-with-children long timeout + inconsistency detection
        # (your-org/nexus-code#455 refine). Engage ONLY when the process
        # tree reading was AUTHORITATIVE (bg_reliable=1) and it saw ≥1 live
        # background-shell child; the footer-fallback path (bg_reliable=0)
        # keeps the legacy #445 flat-grace behaviour via bg_stalled above.
        #
        #   has_live_children=1 → this idle worker still has a child process.
        #   bg_wrapped=1        → it has ALSO wrapped up (case b: inconsistency).
        #   bg_surface=1        → we WILL surface a row (case b always; case a
        #                         once its child's CPU has frozen ≥ base). A
        #                         CPU-advancing / recently-active child stays
        #                         silently exempt (today's behaviour preserved),
        #                         so bg_surface stays 0 and the engagement stamp
        #                         below fires as before.
        local pane_bg_shells pane_bg_reliable
        pane_bg_shells=$(_idle_pane_line_field "$pane_line" bg_shells)
        pane_bg_reliable=$(_idle_pane_line_field "$pane_line" bg_reliable)
        [[ "$pane_bg_shells" =~ ^[0-9]+$ ]] || pane_bg_shells=0
        [[ "$pane_bg_reliable" =~ ^[0-9]+$ ]] || pane_bg_reliable=0
        local has_live_children=0 bg_wrapped=0 bg_surface=0
        local bg_child_class="" bg_child_detail=""
        if [[ "$pane_state" == "working-background" ]] \
           && (( pane_bg_reliable == 1 )) && (( pane_bg_shells >= 1 )); then
            has_live_children=1
            # Episode age, DERIVED from the process tree (no state file).
            # A missing/zero `bg_oldest_start` means "unknown" — treat the
            # episode as brand new rather than instantly past the ceiling.
            local bg_oldest_start bg_child_age bg_ceiling
            bg_oldest_start=$(_idle_pane_line_field "$pane_line" bg_oldest_start)
            [[ "$bg_oldest_start" =~ ^[0-9]+$ ]] || bg_oldest_start=0
            bg_child_age=0
            if (( bg_oldest_start > 0 )) && (( now > bg_oldest_start )); then
                bg_child_age=$(( now - bg_oldest_start ))
            fi
            bg_ceiling=$(_bg_children_grace_ceiling_seconds)
            if _bg_window_is_wrapped "$name"; then
                # A wrapped worker with live children is NOT automatically an
                # inconsistency — a skeptic-gated worker reaches exactly this
                # shape by design. `ng wrap-up` is what WRITES the skeptic-
                # pending marker, and the worker then holds its
                # `skeptic-channel await` re-check loop in a background shell.
                # So consult the authoritative park signal FIRST, mirroring the
                # ordering render_full_state_snapshot already uses.
                if _idle_skeptic_parked "$name" "$now" "$live_windows"; then
                    # Expected, named state — the PR #285 exemption.
                    bg_surface=1
                    bg_child_class="parked-awaiting-skeptic"
                    bg_child_detail="skeptic reviewing; exempt from idle/close (${pane_bg_shells} await child(ren))"
                elif _idle_skeptic_orphaned "$name" "$now" "$live_windows"; then
                    # Fresh marker, no live skeptic past grace — a stuck park,
                    # actionable in its own right rather than mislabelled.
                    bg_surface=1
                    bg_child_class="orphaned-skeptic-pending"
                    bg_child_detail="skeptic-pending marker but no live skeptic past grace — spawn the skeptic or clear the marker"
                else
                    # Case (b): wrapped, no skeptic pending, children still
                    # live. Surface always, regardless of CPU (a wrapped worker
                    # whose child is still computing is the strongest form of
                    # the inconsistency). A STALE marker fails both checks
                    # above and lands here, so a died-mid-await worker still
                    # surfaces rather than staying muted forever.
                    bg_wrapped=1; bg_surface=1
                    bg_child_class="wrapped-with-children"
                    bg_child_detail=$(_bg_wrapped_children_detail "$name" "$pane_bg_shells")
                fi
            else
                # Case (a): idle worker waiting on a background job. Surface
                # once its child's CPU has frozen for ≥ base seconds (a
                # blocking wait on a Slurm job shows no CPU delta) — OR once
                # the child set has simply existed past the ABSOLUTE ceiling,
                # which a CPU-advancing child cannot reset. The latter is the
                # bound that stops a quiet polling loop from holding the window
                # exempt forever (inverted priority, #455 follow-up).
                local bg_stall_start bg_stall_age bg_base
                bg_stall_start="$bg_progress_epoch"
                [[ "$bg_stall_start" =~ ^[0-9]+$ ]] && (( bg_stall_start > 0 )) || bg_stall_start="$now"
                bg_stall_age=$(( now - bg_stall_start ))
                bg_base=$(_bg_children_grace_base_seconds)
                if (( bg_stall_age >= bg_base )) || (( bg_child_age >= bg_ceiling )); then
                    bg_surface=1
                    local bg_decision
                    bg_decision=$(_bg_children_decide "$name" "$now" "$bg_stall_start" "$pane_bg_shells" "$bg_oldest_start")
                    bg_child_class="${bg_decision%%$'\t'*}"
                    bg_child_detail="${bg_decision#*$'\t'}"
                fi
            fi
        fi

        # Engagement-log stamp comes BEFORE the age gate. A worker
        # that's busy *right now* may have an activity-age below
        # threshold yet still represent real engagement that should
        # consume any standing retain on the next cycle.
        #
        # `working-background` and `working-self-paced` (issue #183)
        # also count as engagement — the worker has an in-flight
        # async tool handle or a scheduled wakeup, which is real
        # ongoing work even though the renderer shows no busy
        # spinner. Stamping engagement here keeps a retained worker
        # from being closed mid-monitor.
        # A STALLED background shell (your-org/nexus-code#445) is NOT
        # engagement — stamping it would reset the idle-age anchor and
        # keep the window below the idle threshold forever, defeating
        # the orphan cap. Withhold the stamp so its age grows and it
        # reaches classification.
        case "$pane_state" in
            busy|user-typing|working-self-paced)
                _engagement_log_stamp "$name" "$now" ;;
            working-background)
                if (( has_live_children == 1 )); then
                    # Withhold the stamp only when we're about to surface a
                    # row (case b, or a frozen case-a child): its age must
                    # grow to cross the idle threshold and reach the
                    # classification below. Otherwise stamp as engagement
                    # (advancing / within-base child → silent exempt).
                    (( bg_surface == 1 )) || _engagement_log_stamp "$name" "$now"
                else
                    (( bg_stalled == 1 )) || _engagement_log_stamp "$name" "$now"
                fi ;;
        esac

        # Operator-engaged bookkeeping (issues #196, #201). Runs on
        # EVERY observed state — before the over-limit short-circuit,
        # the spawn grace, and the age gate — because the seed is
        # hook-driven (the UserPromptSubmit stamp) and must be
        # processed regardless of how (or whether) pane-state
        # classified the window this cycle; the soft refresh also
        # rides on states (busy, user-typing) that exit this loop
        # early below.
        _openg_observe "$name" "$pane_state" "$pane_content_hash" "$now" "$engaged_grace"

        # Over-limit short-circuit (issue #87). Bypasses the spawn
        # grace AND the age gate — a worker hitting the weekly limit
        # was likely busy moments ago, so its engagement-anchored
        # age sits at zero. Surfacing the suspension immediately is
        # the whole point of the state. Inviolable like
        # `pane-absent`; `window-retain` does not suppress it.
        if [[ "$pane_state" == over-limit ]]; then
            printf '%s\t%s\t%s\t%s\n' \
                "$name" "over-limit" "$(( now - activity_epoch ))" \
                "${pane_reset_at:-unknown}"
            continue
        fi

        # Spawn-grace skip. If this window has a recent `spawn` event
        # and we're still within the grace window, drop out — the
        # worker is still booting and any classification at this stage
        # is likely premature (issue #72). Pre-existing windows that
        # never had a spawn event recorded (legacy / observed at
        # watcher startup) pass through; the engagement-log first-sight
        # backfill below covers their idle-anchor.
        if (( spawn_grace > 0 )); then
            local spawn_ts_for_grace spawn_epoch_for_grace spawn_age
            spawn_ts_for_grace=$(_idle_window_spawn_ts "$name")
            if [[ -n "$spawn_ts_for_grace" ]]; then
                spawn_epoch_for_grace=$(_idle_iso_to_epoch "$spawn_ts_for_grace")
                if [[ "$spawn_epoch_for_grace" =~ ^[0-9]+$ ]]; then
                    spawn_age=$(( now - spawn_epoch_for_grace ))
                    if (( spawn_age < spawn_grace )); then
                        continue
                    fi
                fi
            fi
        fi

        # Idle-pool entry gate. Anchor: the engagement-log epoch,
        # always — the backfill above guarantees every observed
        # window has a row. Not `max(engagement, activity)` —
        # activity > engagement is the common case (any cursor
        # blink post-engagement bumps it), and picking the larger
        # would defeat the fix. The engagement-log records only
        # `busy` / `user-typing` observations plus a first-sight
        # baseline, so its epoch is the reliable floor for "when
        # did the current idle stretch begin"; tmux's
        # `#{window_activity}` includes autosuggest re-renders,
        # cursor blinks, and status-bar ticks, so a retained
        # worker rendering its spinner glyph every minute would
        # oscillate in and out of the idle pool under
        # window_activity-only gating, thrashing the suppressed-
        # set footer. The activity_epoch is kept as a defensive
        # fallback for the unlikely case where the engagement-log
        # row is somehow malformed; the backfill guarantees the
        # primary path.
        local age_anchor="$activity_epoch"
        local engagement_epoch_for_age
        engagement_epoch_for_age=$(_engagement_log_lookup "$name")
        if [[ -n "$engagement_epoch_for_age" \
              && "$engagement_epoch_for_age" =~ ^[0-9]+$ ]]; then
            age_anchor="$engagement_epoch_for_age"
        fi
        age=$(( now - age_anchor ))
        (( age >= threshold )) || continue

        local cls detail=""
        case "$pane_state" in
            absent|blocked)
                # `pane-absent` short-circuits the wrap-up
                # classification entirely — the inner Claude
                # process is gone or unresponsive; whether a
                # report exists is moot until it's relaunched.
                # Post-rethink: `empty` is no longer mapped here.
                # pane-state.sh distinguishes `empty` (alive
                # claude, transient render state) from `absent`
                # (no live claude in pane), so only `absent` and
                # `blocked` warrant the inviolable pane-absent
                # surface.
                cls=pane-absent
                detail="claude process gone or unresponsive; relaunch or close"
                printf '%s\t%s\t%s\t%s\n' "$name" "$cls" "$age" "$detail"
                continue
                ;;
            idle|autosuggest-only)
                : ;;
            idle-orphan-async)
                # Issue #183: worker declared async external work
                # (slurm, CI, queued task, …) but installed no
                # resume mechanism. Surface as a contract-violation
                # row with the offending job ids. Inviolable like
                # `pane-absent` and `idle-too-long` — `window-retain`
                # does NOT suppress it; the operator needs to see
                # the contract break, not its absence. Detail
                # column carries the `kind:id,…` summary so
                # render_idle_section can interpolate it into the
                # advisory line.
                cls=idle-orphan-async
                detail="${pane_orphan_kinds:-unknown}"
                printf '%s\t%s\t%s\t%s\n' "$name" "$cls" "$age" "$detail"
                continue
                ;;
            empty)
                # Renderer in a transient state but claude is
                # alive. Normally skip — re-classify on a future
                # cycle when the renderer has settled. Engagement-log
                # was not stamped above (empty is not engagement)
                # so the worker re-enters the idle pool naturally
                # when classification stabilises.
                #
                # EXCEPTION: a fresh turn-failure marker means the
                # empty box IS the stall — the motivating incident
                # showed `pane-state state=empty active=0` right
                # after the 500 killed the turn. Fall through to the
                # interrupted detection below so a crashed worker
                # surfaces promptly instead of being skipped every
                # cycle. Without a marker, keep the skip.
                if ! _idle_turn_failure_fresh "$name" "$now"; then
                    continue
                fi
                ;;
            working-background)
                # Idle-with-children long timeout + inconsistency detection
                # (your-org/nexus-code#455 refine). When the authoritative
                # process tree saw a live child and we resolved a row to
                # surface (case b: wrapped-with-children; or case a: a
                # frozen child past base → the backoff decision — one of
                # idle-awaiting-job / idle-children-clarify / idle-too-long),
                # emit it directly and skip the wrap-up classification below.
                # This mirrors the idle-orphan-async short-circuit: a
                # working-state row is emitted in place rather than deferred
                # to the interrupted/skeptic/no-wrap-up cascade.
                #
                # Because this short-circuits BEFORE the parked-awaiting-
                # skeptic check further down, `bg_child_class` is resolved
                # skeptic-aware at its assignment site above — a worker parked
                # in `skeptic-channel await` DOES reach here (the await loop is
                # a real background child), so it must already carry the
                # `parked-awaiting-skeptic` class rather than be mislabelled a
                # wrapped-with-children inconsistency (#455 follow-up).
                if (( has_live_children == 1 )) && (( bg_surface == 1 )); then
                    printf '%s\t%s\t%s\t%s\n' \
                        "$name" "$bg_child_class" "$age" "$bg_child_detail"
                    continue
                fi
                # Background-compute orphan-grace (your-org/nexus-code#445).
                # A shell whose CPU is still advancing is genuinely
                # computing → exempt (engagement stamped above kept its
                # age below threshold, so it normally never even reaches
                # here; the explicit continue is the belt-and-suspenders
                # guard). A shell whose CPU has FROZEN past the grace is
                # orphaned — its engagement stamp was withheld above so
                # its age crossed the threshold; fall through to normal
                # idle classification so it becomes reapable.
                (( bg_stalled == 1 )) || continue
                ;;
            *)
                # busy / user-typing / working-self-paced / unknown —
                # not idle enough to surface. Engagement-log was already
                # stamped above (for busy / user-typing /
                # working-self-paced); `unknown` just means pane-state
                # couldn't run, treat as skip.
                continue
                ;;
        esac

        # Interrupted-mid-turn detection (the stall-detection work).
        # A fresh turn-failure marker means the worker's last turn
        # died to an API/model error (StopFailure fired, NOT Stop) —
        # the inner claude process is alive (the `absent` short-
        # circuit above guarantees it), the input box is empty, and
        # no clean Stop ran. This is byte-identical to a forgot-to-
        # wrap worker from the renderer alone, but the correct
        # recovery is resume/respawn, not a wrap-up nag. Surface it as
        # `interrupted` carrying `<category>:<recovery>` so the
        # orchestrator pastes-to-resume (transient) or respawns
        # (config/conversation) correctly.
        #
        # Precedence: above operator-engaged, no-wrap-up, and retain —
        # a crashed turn is actionable and must not be muted by a
        # standing retain or an away-operator mark. BELOW idle-too-long
        # (an abandoned crash that's sat ≥ close_threshold is a close
        # candidate, not a resume candidate), which the inline override
        # preserves. Inviolable w.r.t. window-retain.
        #
        # ALSO above parked-awaiting-skeptic (the PR #285 short-circuit
        # below): a fresh turn-failure marker means the worker's await
        # loop died mid-handshake, so the skeptic-pending marker — though
        # it may still be momentarily fresh — no longer reflects a live
        # park. An interrupted skeptic-parked worker is recoverable, not
        # parked, so the crash must surface for paste/respawn rather than
        # be masked by the park exemption. In the normal clean-park case
        # there is no turn-failure marker, so this check skips and the
        # park short-circuit below fires unchanged — no regression.
        if _idle_turn_failure_fresh "$name" "$now"; then
            local tf_category tf_recovery
            tf_category=$(_idle_turn_failure_field "$name" category)
            tf_recovery=$(_idle_turn_failure_field "$name" recovery)
            cls=interrupted
            detail="${tf_category:-unknown}:${tf_recovery:-paste}"
            if (( age >= close_threshold )); then
                cls=idle-too-long
            fi
            printf '%s\t%s\t%s\t%s\n' "$name" "$cls" "$age" "$detail"
            continue
        fi

        # parked-awaiting-skeptic short-circuit (skills/nexus.skeptic,
        # PR #285). A worker with a LIVE skeptic-pending marker (mtime
        # refreshed by its `skeptic-channel await` loop within the hang
        # threshold) is legitimately parked, not idle. Emit the
        # informational class and skip ALL wrap-up classification below —
        # this is the exemption from idle-too-long / no-wrap-up that
        # keeps the orchestrator from closing the worker mid-handshake.
        # Surfaces ONCE via list_idle_transitions' (window,class) dedupe,
        # so it informs without nagging. A stale marker (await died)
        # fails _idle_skeptic_parked and falls through to normal
        # classification, so a genuine hang still surfaces. Runs before
        # operator-engaged: the skeptic gate is the stronger claim while
        # it's live. Runs AFTER interrupted detection above: a crashed
        # await beats a (momentarily-fresh) park because it's recoverable.
        if _idle_skeptic_parked "$name" "$now" "$live_windows"; then
            printf '%s\t%s\t%s\t%s\n' \
                "$name" "parked-awaiting-skeptic" "$age" "skeptic reviewing; exempt from idle/close"
            continue
        fi

        # Orphaned skeptic-pending marker (emit/exemption fidelity). A fresh
        # marker with NO live skeptic past the grace window is NOT a park —
        # it is a stuck state the orchestrator must resolve. Surface it as
        # its own actionable class instead of silently exempting forever.
        # Deduped by (window,class) like the park class, so it informs once;
        # the periodic full-state snapshot re-shows it. Once the orchestrator
        # spawns the skeptic (→ live) or clears the marker, the class changes
        # and normal classification resumes.
        if _idle_skeptic_orphaned "$name" "$now" "$live_windows"; then
            printf '%s\t%s\t%s\t%s\n' \
                "$name" "orphaned-skeptic-pending" "$age" "skeptic-pending marker but no live skeptic past grace — spawn the skeptic or clear the marker"
            continue
        fi

        # Operator-engaged short-circuit (issues #196, #201). An idle
        # window with a valid mark belongs to the operator — engaged
        # right now, or merely stepped away. Emit the informational
        # class instead of the wrap-up classification so the dedupe
        # machinery surfaces ONE row per engagement episode and
        # nothing nags; the away-phase reminder rides on top in
        # list_idle_transitions. Only a newer wrap-up/spawn (or the
        # window closing) re-opens the normal classes.
        if _openg_marked "$name"; then
            local openg_src
            openg_src=$(_openg_lookup "$name" | cut -f4)
            printf '%s\t%s\t%s\t%s\n' \
                "$name" "operator-engaged" "$age" "${openg_src:-engaged}"
            continue
        fi

        cls=no-wrap-up
        local report_basename
        if report_basename=$(_idle_window_wrap_up_report "$name"); then
            # Wrap-up supersession (the #205 state-machine follow-up):
            # a MACHINE-attributed submit NEWER than the wrap-up means
            # the orchestrator re-tasked the worker after its hand-off.
            # The wrap-up is stale — the window regressed to busy at
            # the follow-up and, now idle again without a fresh
            # wrap-up, belongs on the no-wrap-up nag schedule rather
            # than parked on a "wrapped" row. (An OPERATOR submit
            # after a wrap-up takes the operator-engaged short-circuit
            # above instead and never reaches this branch while the
            # mark is valid.)
            local wrap_epoch_cls msub_epoch
            wrap_epoch_cls=$(_openg_wrap_epoch "$name")
            msub_epoch=$(_openg_machine_submit_epoch "$name")
            if (( msub_epoch > 0 && wrap_epoch_cls > 0 \
                  && msub_epoch > wrap_epoch_cls )); then
                cls=no-wrap-up
            else
                cls=wrapped
                local report_path
                if report_path=$(_idle_resolve_report_path "$report_basename"); then
                    local check_summary
                    if ! check_summary=$(_idle_run_report_check "$report_path"); then
                        cls=wrapped-but-stub
                        detail="$check_summary"
                    fi
                fi
            fi
        fi

        # Piece 5: the hard 24h-class overrides everything else.
        # A worker that has been idle for ≥ close_threshold is a
        # default-to-close candidate regardless of whether the
        # cited report passes report-check. `idle-too-long` is
        # inviolable — never suppressed by `window-retain`.
        if (( age >= close_threshold )); then
            cls=idle-too-long
            # Preserve the prior detail (a stub finding) so the
            # orchestrator still has the report-check hint even on
            # the strong-close path.
            :
        fi

        # Injection ↔ hook pairing validation (the #205 state-machine
        # follow-up): an orchestrator paste that never fired the
        # worker's UserPromptSubmit hook means the nudge silently
        # failed — surface it instead of the wrapped/no-wrap-up row so
        # the orchestrator re-pastes. Below idle-too-long (a runaway
        # window must keep alarming) and above retain (a failed paste
        # is actionable; a standing retain must not mute it).
        if [[ "$cls" == "wrapped" || "$cls" == "no-wrap-up" ]]; then
            local unconfirmed_paste
            unconfirmed_paste=$(_idle_unconfirmed_paste_epoch "$name" "$now")
            if (( unconfirmed_paste > 0 )); then
                cls=paste-unconfirmed
                detail="paste $(( now - unconfirmed_paste ))s ago"
            fi
        fi

        # `window-retain` suppression. Only `wrapped` and `no-wrap-up`
        # are eligible — `wrapped-but-stub`, `idle-too-long`, and
        # `pane-absent` are inviolable. The retain is consumed only
        # by *real engagement* (busy / user-typing recorded in
        # engagement-log.tsv since retain.ts), NOT by tmux
        # `#{window_activity}` bumps — autosuggest re-renders /
        # cursor blinks / status-bar ticks bump activity without
        # any human or agent input. Missing engagement-log row
        # means "no engagement since beginning of time" → retain
        # holds. Retain expires after retain_ttl seconds.
        if [[ "$cls" == "wrapped" || "$cls" == "no-wrap-up" ]]; then
            local retain_row retain_ts retain_reason retain_ts_epoch retain_age
            if retain_row=$(_idle_window_retain_event "$name"); then
                IFS=$'\t' read -r retain_ts retain_reason <<<"$retain_row"
                retain_ts_epoch=$(_idle_iso_to_epoch "$retain_ts")
                if [[ -n "$retain_ts_epoch" ]]; then
                    retain_age=$(( now - retain_ts_epoch ))
                    local engagement_epoch
                    engagement_epoch=$(_engagement_log_lookup "$name")
                    # Missing row = "never engaged" — sentinel 0
                    # always passes the `<= retain_ts_epoch` check.
                    [[ -z "$engagement_epoch" ]] && engagement_epoch=0
                    if (( retain_age >= 0 )) \
                       && (( retain_age <= retain_ttl )) \
                       && (( engagement_epoch <= retain_ts_epoch )); then
                        cls=retained
                        detail="$retain_reason"
                    fi
                fi
            fi
        fi

        printf '%s\t%s\t%s\t%s\n' "$name" "$cls" "$age" "$detail"
    done <<<"$worker_windows"

    # Persist `current ∪ engagement-log-keys-after-prune` for the
    # next cycle's disappearance check. The union makes the
    # cold-start-with-stale-row case prune in two cycles (see the
    # header on `_idle_previous_windows_path`); on the steady-state
    # path, the engagement-log half of the union is a no-op because
    # every key with a row is also a currently-alive window.
    local elog_keys persist_payload
    elog_keys=""
    if [[ -f "$(_engagement_log_path)" ]]; then
        elog_keys=$(awk -F'\t' 'NF>0 && $1 != "" { print $1 }' \
                        "$(_engagement_log_path)")
    fi
    persist_payload=$(printf '%s\n%s\n' "$current_set" "$elog_keys" \
                      | awk 'NF>0' | sort -u)
    mkdir -p "$(dirname "$prev_windows_file")"
    if [[ -n "$persist_payload" ]]; then
        printf '%s\n' "$persist_payload" > "$prev_windows_file"
    else
        : > "$prev_windows_file"
    fi
}

# Diff this cycle's idle set against the previous cycle's; emit only
# transitions worth surfacing (per the state machine in the header).
# Reads/writes $STATE_DIR/idle-state.tsv.
#
# Dedupe key is (window, class) — the detail column doesn't gate
# the diff (a wrapped-but-stub finding whose detail string changed
# between cycles is still "the same state" from the orchestrator's
# POV; re-emitting would be noise).
#
# Retained-row handling differs: the suppressed set is treated as
# a single dedupe unit. When the set changes (any window added or
# removed), ALL current retained rows are emitted so the renderer
# can produce a complete footer listing every currently-suppressed
# window. When the set is unchanged, no retained rows surface even
# if other (non-retained) transitions are emitted this cycle.
#
# Output: <window>\t<class>\t<age-seconds>\t<detail>  — only NEW
#         transitions and (conditionally) the current retained set.
# Carry-forward for episode-scoped dedupe rows. A window
# mid-conversation oscillates out of the idle pool on every busy /
# user-typing observation; if its `(window, class)` row left the
# state file each time, every think-gap would re-emit the row —
# recreating the per-round noise these classes exist to stop. Two
# classes are episode-scoped:
#
#   operator-engaged (issue #196) — carried while the engagement
#     mark is still valid.
#   parked-awaiting-skeptic (emit-gate-recover) — carried while the
#     skeptic-pending marker is still live. A worker parked in the
#     `skeptic-channel.sh await` loop flaps busy↔idle on every poll
#     of the loop; without the carry, each idle re-entry re-emitted
#     the parked row (the 2026-07-06 per-minute resurface flood).
#     "Surfaces ONCE per park episode" is the intended contract.
#
# A carried row drains naturally — when the mark/marker is
# invalidated (newer wrap-up/spawn; skeptic verdict retiring the
# park) the window re-enters the pool under its normal class (a
# class change, which emits), and a closed window's mark is pruned.
#
# Args: state_file, newline-separated current window names. Emits
# carried `<window>\t<class>` rows on stdout.
_idle_carry_engaged_rows() {
    local state_file="$1" cur_names="$2"
    [[ -f "$state_file" ]] || return 0
    local w cls now
    now=$(date +%s)
    while IFS=$'\t' read -r w cls; do
        [[ -n "$w" ]] || continue
        grep -qxF -- "$w" <<<"$cur_names" && continue
        case "$cls" in
            operator-engaged)
                _openg_marked "$w" || continue
                printf '%s\toperator-engaged\n' "$w" ;;
            parked-awaiting-skeptic)
                _idle_skeptic_parked "$w" "$now" || continue
                printf '%s\tparked-awaiting-skeptic\n' "$w" ;;
        esac
    done < "$state_file"
}

# Close-reminder pass (issue #201). For each idle operator-engaged
# window in this cycle's set: once the operator has been away
# (now − last) for a full reminder period, emit ONE
# `engaged-close-reminder` row and stamp `reminded`, so the row
# re-fires at most once per period. The row is emit-only — it is
# never persisted into idle-state.tsv, so it cannot perturb the
# (window, class) dedupe; the underlying class stays
# `operator-engaged` throughout. A returning operator re-seeds the
# episode (resetting `reminded`) and the cadence re-arms.
#
# Args: this cycle's full `<window>\t<class>\t<age>\t<detail>` set.
# Emits due `<window>\tengaged-close-reminder\t<away>\t<src>` rows.
_idle_emit_due_close_reminders() {
    local cur_set="$1"
    [[ -n "$cur_set" ]] || return 0
    local now rem_secs w cls age detail
    now=$(date +%s)
    rem_secs=$(_openg_reminder_seconds)
    while IFS=$'\t' read -r w cls age detail; do
        [[ "$cls" == "operator-engaged" ]] || continue
        local row since last prompt_seen src reminded
        row=$(_openg_lookup "$w")
        [[ -n "$row" ]] || continue
        IFS=$'\t' read -r since last prompt_seen src reminded <<<"$row"
        [[ "$last" =~ ^[0-9]+$ ]] || continue
        [[ "$reminded" =~ ^[0-9]+$ ]] || reminded=0
        local away=$(( now - last ))
        (( away >= rem_secs )) || continue
        if (( reminded == 0 )) || (( now - reminded >= rem_secs )); then
            printf '%s\tengaged-close-reminder\t%s\t%s\n' \
                "$w" "$away" "${src:-engaged}"
            _openg_write "$w" "$since" "$last" "$prompt_seen" "${src:-}" "$now"
        fi
    done <<<"$cur_set"
}

list_idle_transitions() {
    local state_file="${STATE_DIR}/idle-state.tsv"
    local cur_set
    cur_set=$(list_really_idle_workers)
    if [[ -z "$cur_set" ]]; then
        # Preserve mid-episode engaged rows even when the pool
        # empties (the engaged window itself being busy/typing is
        # the common cause in small workspaces).
        _idle_carry_engaged_rows "$state_file" "" > "${state_file}.next" 2>/dev/null \
            || : > "${state_file}.next"
        mv "${state_file}.next" "$state_file"
        return 0
    fi
    # `! -s` (missing OR empty), not `! -f`: an EMPTY state file —
    # the normal residue of a cycle where every idle window went
    # busy — must take the emit-everything branch too. Feeding an
    # empty file through the awk dedupe below silently swallows the
    # current set's first row (with zero records in file 1, awk's
    # `FNR == NR` holds for file 2's first record), so a workspace
    # whose ONLY idle worker went busy and idled again never re-saw
    # its row (issue #196 demo regression).
    if [[ ! -s "$state_file" ]]; then
        printf '%s\n' "$cur_set" \
            | awk -F'\t' 'NF>0 { printf "%s\t%s\n", $1, $2 }' > "$state_file"
        printf '%s\n' "$cur_set"
        _idle_emit_due_close_reminders "$cur_set"
        return 0
    fi
    # Split this cycle's set into the non-retained subset (deduped
    # row-by-row) and the retained subset (emitted as a single
    # group when the membership changes).
    local cur_normal cur_retained
    cur_normal=$(printf '%s\n' "$cur_set" \
        | awk -F'\t' '$2 != "retained" && NF>0')
    cur_retained=$(printf '%s\n' "$cur_set" \
        | awk -F'\t' '$2 == "retained" && NF>0')
    # Non-retained dedupe against the prior state file.
    if [[ -n "$cur_normal" ]]; then
        awk -F'\t' '
            FNR == NR { prev[$1 "\t" $2] = 1; next }
            { key = $1 "\t" $2; if (!(key in prev)) print $0 }
        ' "$state_file" <(printf '%s\n' "$cur_normal")
    fi
    # Suppressed-set change detection: compare the prior cycle's
    # retained window names (sorted) against this cycle's.
    local prev_retained_names cur_retained_names
    prev_retained_names=$(awk -F'\t' '$2 == "retained" { print $1 }' "$state_file" | sort -u)
    cur_retained_names=$(printf '%s\n' "$cur_retained" \
        | awk -F'\t' 'NF>0 { print $1 }' | sort -u)
    if [[ "$prev_retained_names" != "$cur_retained_names" ]] \
       && [[ -n "$cur_retained" ]]; then
        printf '%s\n' "$cur_retained"
    fi
    # Persist this cycle's full set for the next dedupe pass, plus
    # the carried operator-engaged rows for windows currently out of
    # the pool mid-episode (see _idle_carry_engaged_rows).
    local carried cur_names
    cur_names=$(printf '%s\n' "$cur_set" | awk -F'\t' 'NF>0 { print $1 }')
    carried=$(_idle_carry_engaged_rows "$state_file" "$cur_names")
    {
        printf '%s\n' "$cur_set" \
            | awk -F'\t' 'NF>0 { printf "%s\t%s\n", $1, $2 }'
        [[ -n "$carried" ]] && printf '%s\n' "$carried"
    } > "${state_file}.next"
    mv "${state_file}.next" "$state_file"
    # Emit-only close reminders for long-away engaged windows — after
    # the persist on purpose (the rows must never enter the dedupe).
    _idle_emit_due_close_reminders "$cur_set"
}

# Render a one-line summary of the workspace state for use as an emit
# prelude. Format:
#
#   N busy | N idle | N retained | N idle-too-long | N pane-absent | N over-limit | N orphan-async | N interrupted | N awaiting-input
#
# The counts reflect THIS cycle's `list_really_idle_workers` output
# (plus a "busy" tally derived from windows the probe didn't classify
# as idle, since those are by definition busy / user-typing / freshly-
# spawned), and an `awaiting-input` count derived from the worker
# notifications log (issue #76) — workers whose `Notification` hook
# has fired since the previous prelude render. Closes issue #72
# regression 6's "operator can't tell what the workspace looks like
# from a single emit" gap and complements `pane-state=blocked`
# heuristics with a structural signal from claude itself. The
# `over-limit` axis (issue #87) counts workers whose pane shows the
# canonical "You've hit your limit · resets <time>" notice — a
# functional suspension the orchestrator should resolve by scheduling
# a resume at the named reset time.
#
# The function ALWAYS prints exactly one line. Empty workspace prints
# `0 busy | 0 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | 0 interrupted | 0 parked-skeptic | 0 awaiting-input`.
#
# `parked-skeptic` (PR #285) counts workers parked on a live
# skeptic-pending marker (`parked-awaiting-skeptic` class) — waiting on an
# independent validation pass, NOT actively working — and is excluded from
# the `busy` residue so "busy" means genuinely-working.
#
# Side effects: rotates the notifications log when oversized
# (default 10MiB; override via MONITOR_NOTIFICATIONS_LOG_MAX_BYTES)
# and stamps the prelude epoch into `last-prelude.ts` so the next
# render scopes its awaiting-input count to events that arrived
# after this emit. The first render after a fresh STATE_DIR sees
# no stamp and reports 0 awaiting-input — accepted trade-off so
# stale historical rows don't inflate the first count after a
# watcher cold-start.
render_idle_prelude() {
    # Total workers (non-reserved) seen this cycle. Reserved windows
    # are excluded by _idle_list_worker_windows.
    local total_workers idle_set
    total_workers=$(_idle_list_worker_windows | awk -F'\t' 'NF>0 && $1!="" {n++} END {print n+0}')
    # Pull the current idle set without persisting transition state —
    # render_idle_section's caller (render_idle_section itself) already
    # advances the dedupe file, so calling list_really_idle_workers
    # again here is read-only with respect to the engagement-log.
    # We rely on the probe being deterministic when invoked twice in
    # the same cycle (no time-dependent side-effects beyond stamping).
    # Read-only: the prelude only COUNTS. The authoritative transition emit
    # (render_idle_section) is the sole cycle-mutator of the idle-with-children
    # backoff state; a count-only pass here must not advance the edge-triggered
    # level and steal a clarification nudge (your-org/nexus-code#455 refine).
    idle_set=$(MONITOR_IDLE_PROBE_READONLY=1 list_really_idle_workers 2>/dev/null)
    local n_idle n_retained n_idle_too_long n_pane_absent n_over_limit n_orphan_async
    # `orphaned-skeptic-pending` (emit/exemption fidelity) folds into the
    # idle tally so it is excluded from the `busy` residue (like the parked
    # class) — it is a stuck-not-working state. Its distinct, actionable row
    # still surfaces in the idle SECTION; only the prelude scalar buckets it.
    n_idle=$(printf '%s\n' "$idle_set" | awk -F'\t' '
        NF>0 && ($2=="no-wrap-up" || $2=="wrapped" || $2=="wrapped-but-stub" || $2=="paste-unconfirmed" || $2=="orphaned-skeptic-pending") {n++}
        END {print n+0}')
    n_retained=$(printf '%s\n' "$idle_set" | awk -F'\t' '$2=="retained" {n++} END {print n+0}')
    n_idle_too_long=$(printf '%s\n' "$idle_set" | awk -F'\t' '$2=="idle-too-long" {n++} END {print n+0}')
    n_pane_absent=$(printf '%s\n' "$idle_set" | awk -F'\t' '$2=="pane-absent" {n++} END {print n+0}')
    n_over_limit=$(printf '%s\n' "$idle_set" | awk -F'\t' '$2=="over-limit" {n++} END {print n+0}')
    # orphan-async (issue #183): workers with self-declared external
    # waits but no resume mechanism. Distinct from `idle` (genuinely
    # nothing to do) and `over-limit` (suspended by Anthropic) — the
    # operator's action is to install a wake mechanism or dismiss
    # the waits.
    n_orphan_async=$(printf '%s\n' "$idle_set" | awk -F'\t' '$2=="idle-orphan-async" {n++} END {print n+0}')
    # interrupted (stall-detection): workers whose last turn died to an
    # API/model error (StopFailure marker fresh, process alive). Distinct
    # from `idle`/`no-wrap-up` (clean finish) — the operator's action is
    # to resume (transient) or respawn (config), not to nag a wrap-up.
    local n_interrupted
    n_interrupted=$(printf '%s\n' "$idle_set" | awk -F'\t' '$2=="interrupted" {n++} END {print n+0}')
    # parked-awaiting-skeptic (skills/nexus.skeptic, PR #285). A worker
    # parked in `skeptic-channel.sh await` (or whose required-skeptic
    # verdict has not yet retired it) is NOT actively working — it is
    # waiting on an independent validation pass. list_really_idle_workers
    # emits it as its own `parked-awaiting-skeptic` class and short-circuits
    # (it is neither idle nor busy). Without its own tally it fell into the
    # `n_busy = total - n_idle_total` residue and inflated "N busy",
    # misleading the operator ("all 11 busy" when their PRs had merged and
    # the workers were merely parked). Give it a distinct axis and exclude
    # it from busy so "busy" means genuinely-working.
    local n_parked
    n_parked=$(printf '%s\n' "$idle_set" | awk -F'\t' '$2=="parked-awaiting-skeptic" {n++} END {print n+0}')
    # idle-with-children (your-org/nexus-code#455 refine): workers idle but
    # holding ≥1 live background child. `idle-awaiting-job` is the exempt
    # long-timeout state; `idle-children-clarify` and `wrapped-with-children`
    # are actionable (inject a clarification prompt / resolve the
    # inconsistency). All three are idle-not-busy — give them a distinct axis
    # and exclude from the busy residue.
    local n_bg_children
    n_bg_children=$(printf '%s\n' "$idle_set" | awk -F'\t' '
        $2=="idle-awaiting-job" || $2=="idle-children-clarify" || $2=="wrapped-with-children" {n++}
        END {print n+0}')
    # Busy ≈ workers not appearing in the idle set. Approximation:
    # spawn-grace skips and `empty`-skip windows count as busy here,
    # which matches the operator's mental model ("not idle = working").
    local n_idle_total=$(( n_idle + n_retained + n_idle_too_long + n_pane_absent + n_over_limit + n_orphan_async + n_interrupted + n_parked + n_bg_children ))
    local n_busy=$(( total_workers - n_idle_total ))
    (( n_busy < 0 )) && n_busy=0

    # awaiting-input counter (issue #76). Rotate first, then count,
    # then stamp — rotation moves the live file out of the way under
    # an archive-suffixed name, so the rotated rows don't double-count
    # on the next cycle. The stamp's purpose is to scope the count to
    # "since the last render" so a notification that's already been
    # surfaced doesn't keep showing up cycle after cycle until it's
    # answered (the operator sees it once, then it's their move).
    #
    # Stamp carries subsecond precision (`date +%s.%N`) so a hook that
    # fires in the same wall-second the prelude finishes is still
    # counted — jq's `now` in the worker hook emits a float, the
    # comparison `ts > since` is float-aware via jq, and the
    # awk fallback uses numeric comparison too.
    local max_bytes="${MONITOR_NOTIFICATIONS_LOG_MAX_BYTES:-10485760}"
    _notifications_rotate_if_oversized "$max_bytes"
    local stamp_path stamp_epoch n_awaiting now
    stamp_path=$(_notifications_stamp_path)
    stamp_epoch=0
    if [[ -f "$stamp_path" ]]; then
        stamp_epoch=$(cat "$stamp_path" 2>/dev/null || echo 0)
        [[ "$stamp_epoch" =~ ^[0-9]+(\.[0-9]+)?$ ]] || stamp_epoch=0
    fi
    n_awaiting=$(_notifications_count_distinct_since "$stamp_epoch")
    now=$(date +%s.%N 2>/dev/null || date +%s)
    # Dry-run (issue #104): caller is computing a canonical-form prelude
    # for the full-state identity check, NOT emitting. Leave the stamp
    # un-advanced so the next real render still sees the same since-
    # window and the operator-facing awaiting-input count is preserved
    # across suppression cycles.
    if [[ -z "${MONITOR_PRELUDE_DRY_RUN:-}" ]]; then
        mkdir -p "$(dirname "$stamp_path")" 2>/dev/null || true
        printf '%s' "$now" > "$stamp_path" 2>/dev/null || true
    fi

    printf '%d busy | %d idle | %d retained | %d idle-too-long | %d pane-absent | %d over-limit | %d orphan-async | %d interrupted | %d parked-skeptic | %d idle-children | %d awaiting-input\n' \
        "$n_busy" "$n_idle" "$n_retained" "$n_idle_too_long" "$n_pane_absent" "$n_over_limit" "$n_orphan_async" "$n_interrupted" "$n_parked" "$n_bg_children" "$n_awaiting"
}

# Render every currently-tracked worker window's full classification
# row for the periodic full-state snapshot emit. Same line shape as
# render_idle_section produces for transitions — but NOT deduped, NOT
# gated on transition. Caller decides when to render (typically every
# Nth cycle). Includes busy / user-typing windows as a "(active)"
# annotation so the operator's full-state snapshot is genuinely full.
render_full_state_snapshot() {
    local raw
    raw=$(_idle_list_worker_windows)
    [[ -n "$raw" ]] || return 0
    local now name activity_epoch window_index pane_state engaged_grace
    now=$(date +%s)
    engaged_grace=$(_openg_grace_seconds)
    # Live windows once, for the skeptic fidelity check (emit/exemption
    # fidelity) — see list_really_idle_workers.
    local live_windows
    live_windows=$(tmux list-windows -F '#{window_name}' 2>/dev/null || true)
    while IFS=$'\t' read -r name activity_epoch window_index; do
        [[ -n "$name" ]] || continue
        local probe_target="${window_index:-$name}"
        local pane_line pane_reset_at
        pane_line=$(_idle_pane_state_line "$probe_target")
        pane_state=$(printf '%s' "$pane_line" \
            | sed -n 's/.*state=\([a-z-]*\).*/\1/p')
        [[ -n "$pane_state" ]] || pane_state=unknown
        pane_reset_at=$(_idle_pane_line_field "$pane_line" reset_at)
        # parked-awaiting-skeptic annotation (PR #285): a worker with a
        # live skeptic-pending marker is parked in `await`. It usually
        # renders `busy` (the await tool's spinner), but label it
        # explicitly so the full-state snapshot shows parked workers
        # distinctly from ordinary active work.
        if _idle_skeptic_parked "$name" "$now" "$live_windows"; then
            printf '  - %s parked-awaiting-skeptic (state=%s; skeptic reviewing — exempt from idle/close)\n' \
                "$name" "$pane_state"
            continue
        fi
        # Orphaned marker (emit/exemption fidelity): fresh marker, no live
        # skeptic past grace — surface distinctly in the cumulative snapshot
        # so a stuck park is visible at the heartbeat cadence, not masked as
        # ordinary activity.
        if _idle_skeptic_orphaned "$name" "$now" "$live_windows"; then
            printf '  - %s orphaned-skeptic-pending (state=%s; skeptic-pending marker but no live skeptic — spawn or clear)\n' \
                "$name" "$pane_state"
            continue
        fi
        # Idle-with-children (your-org/nexus-code#455 refine): re-show the
        # wrap-up-with-children inconsistency and the long-wait state at the
        # full-state cadence so the operator sees them even after the
        # per-transition row has deduped out.
        if [[ "$pane_state" == "working-background" ]]; then
            local snap_bg_shells snap_bg_reliable
            snap_bg_shells=$(_idle_pane_line_field "$pane_line" bg_shells)
            snap_bg_reliable=$(_idle_pane_line_field "$pane_line" bg_reliable)
            [[ "$snap_bg_shells" =~ ^[0-9]+$ ]] || snap_bg_shells=0
            [[ "$snap_bg_reliable" =~ ^[0-9]+$ ]] || snap_bg_reliable=0
            if (( snap_bg_reliable == 1 )) && (( snap_bg_shells >= 1 )); then
                if _bg_window_is_wrapped "$name"; then
                    printf '  - %s wrapped-with-children (%d live child(ren) after wrap-up — inconsistency; clarify or close)\n' \
                        "$name" "$snap_bg_shells"
                else
                    printf '  - %s idle-awaiting-job (state=working-background; %d live background child(ren) — long-timeout backoff)\n' \
                        "$name" "$snap_bg_shells"
                fi
                continue
            fi
        fi
        case "$pane_state" in
            busy|user-typing|working-background|working-self-paced)
                printf '  - %s (active, state=%s)\n' "$name" "$pane_state" ;;
            absent|blocked)
                printf '  - %s pane-absent (state=%s)\n' "$name" "$pane_state" ;;
            over-limit)
                printf '  - %s OVER-LIMIT (resets %s)\n' \
                    "$name" "${pane_reset_at:-unknown}" ;;
            *)
                local age_anchor epoch
                epoch=$(_engagement_log_lookup "$name")
                if [[ "$epoch" =~ ^[0-9]+$ ]]; then
                    age_anchor=$epoch
                else
                    age_anchor=$activity_epoch
                fi
                local age=$(( now - age_anchor ))
                # Interrupted-mid-turn (stall-detection): a fresh
                # turn-failure marker reclassifies an otherwise-idle
                # window. Show it in the snapshot so the full-state
                # view matches the transition emit.
                if _idle_turn_failure_fresh "$name" "$now"; then
                    local snap_rec
                    snap_rec=$(_idle_turn_failure_field "$name" recovery)
                    printf '  - %s interrupted (idle %ds; turn crashed, recovery=%s)\n' \
                        "$name" "$age" "${snap_rec:-paste}"
                elif _openg_marked "$name"; then
                    local openg_last away
                    openg_last=$(_openg_lookup "$name" | cut -f2)
                    [[ "$openg_last" =~ ^[0-9]+$ ]] || openg_last="$now"
                    away=$(( now - openg_last ))
                    if (( away > engaged_grace )); then
                        printf '  - %s operator-engaged (operator away %ds; idle %ds, state=%s)\n' \
                            "$name" "$away" "$age" "$pane_state"
                    else
                        printf '  - %s operator-engaged (idle %ds, state=%s)\n' \
                            "$name" "$age" "$pane_state"
                    fi
                else
                    printf '  - %s idle %ds (state=%s)\n' "$name" "$age" "$pane_state"
                fi
                ;;
        esac
    done <<<"$raw"
}

# Render the idle-workers section body for inclusion in the watcher
# emit. Empty stdout if no transitions this cycle. Six shapes:
# five per-row formats (one per non-retained class, matching the
# table in `skills/nexus.window-cleanup` and `monitor/README.md`)
# plus a `(N retained windows suppressed: …)` footer that collates
# all currently-retained rows from this cycle's transitions.
# Reasons over 40 chars are truncated with `…`.
render_idle_section() {
    local transitions
    transitions=$(list_idle_transitions)
    [[ -n "$transitions" ]] || return 0
    # Per-window rows (non-retained classes only).
    printf '%s\n' "$transitions" | awk -F'\t' '
        function fmt_age(s,    h, m) {
            if (s >= 3600) {
                h = int(s / 3600); m = int((s % 3600) / 60)
                return sprintf("%dh%02dm", h, m)
            }
            return sprintf("%ds", s)
        }
        $2 == "wrapped" {
            printf "  - %s wrapped up (idle %s; wrap-up logged)\n", $1, fmt_age($3)
        }
        $2 == "wrapped-but-stub" {
            detail = ($4 == "" ? "report incomplete" : $4)
            printf "  - %s wrapped-but-stub (%s)\n", $1, detail
        }
        $2 == "no-wrap-up" {
            printf "  - %s idle %s WITHOUT wrap-up — consider follow-up paste\n", $1, fmt_age($3)
        }
        $2 == "operator-engaged" {
            src = ($4 == "" ? "engaged" : $4)
            printf "  - %s operator-engaged (src=%s; idle %s — operator driving; idle/retire handling suppressed while engaged)\n", $1, src, fmt_age($3)
        }
        $2 == "engaged-close-reminder" {
            src = ($4 == "" ? "engaged" : $4)
            printf "  - %s operator-engaged but operator away %s (src=%s) — consider closing this window; reminder re-fires once per period until the operator returns or it closes\n", $1, fmt_age($3), src
        }
        $2 == "paste-unconfirmed" {
            detail = ($4 == "" ? "paste unconfirmed" : $4)
            printf "  - %s paste-unconfirmed (%s; no UserPromptSubmit fired — the nudge silently failed; re-paste via monitor/paste-followup.sh)\n", $1, detail
        }
        $2 == "parked-awaiting-skeptic" {
            # PR #285: worker is parked in the skeptic-channel await
            # loop, legitimately waiting for the reviewing skeptic next
            # request. Exempt from idle-too-long / no-wrap-up until the
            # skeptic-pending marker clears (verdict returned). Surfaced
            # so the orchestrator sees parked workers; NOT an action item.
            printf "  - %s parked-awaiting-skeptic (idle %s; skeptic reviewing — exempt from idle/close until verdict; see skills/nexus.skeptic)\n", $1, fmt_age($3)
        }
        $2 == "orphaned-skeptic-pending" {
            # emit/exemption fidelity: a fresh skeptic-pending marker with
            # NO live skeptic past the grace window. NOT a park — a stuck
            # state. Actionable: the orchestrator either spawns the skeptic
            # (marker becomes a real park) or clears the marker (window
            # retires normally). Left unhandled it exempted the window from
            # idle/close forever (the bug this fixes).
            printf "  - %s orphaned-skeptic-pending (idle %s; skeptic-pending marker but NO live skeptic — spawn the skeptic per skills/nexus.skeptic, or clear monitor/.state/skeptic/pending/%s)\n", $1, fmt_age($3), $1
        }
        $2 == "idle-awaiting-job" {
            # your-org/nexus-code#455 refine, case (a): idle worker with a
            # live background child (a Slurm job / long compute it is waiting
            # on). Exempt from reap under the exponential-backoff long
            # timeout. Informational — surfaces once per episode; NOT an
            # action item.
            detail = ($4 == "" ? "waiting on a background job" : $4)
            printf "  - %s idle-awaiting-job (idle %s; %s — exempt under long-timeout backoff)\n", $1, fmt_age($3), detail
        }
        $2 == "idle-children-clarify" {
            # your-org/nexus-code#455 refine, case (a): a clarification nudge
            # is due (the child CPU has been frozen past the current
            # backoff step, or the worker declared stuck/done). INJECT a
            # clarification prompt asking the worker to declare the job
            # expected runtime + health via monitor/worker-health.sh; the
            # watcher reads monitor/.state/worker-health/<window>.json next
            # cycle to extend the grace, reap, or keep asking.
            detail = ($4 == "" ? "waiting on a background job" : $4)
            printf "  - %s idle-children-clarify (idle %s; %s — paste the worker-health clarification prompt; see skills/nexus.window-cleanup)\n", $1, fmt_age($3), detail
        }
        $2 == "wrapped-with-children" {
            # your-org/nexus-code#455 refine, case (b): the worker wrapped up
            # but STILL has live child processes — an inconsistency (leftover
            # children, or a premature wrap while a job runs). Ask for
            # clarification (worker-health.sh) or close; default is ASK, not
            # auto-reap.
            detail = ($4 == "" ? "live children after wrap-up" : $4)
            printf "  - %s wrapped-with-children (idle %s; %s — inconsistency: paste the worker-health clarification prompt or close; see skills/nexus.window-cleanup)\n", $1, fmt_age($3), detail
        }
        $2 == "idle-too-long" {
            printf "  - %s idle-too-long %s (exceeds close threshold; consider close)\n", $1, fmt_age($3)
        }
        $2 == "pane-absent" {
            printf "  - %s pane-absent (claude process gone or unresponsive; relaunch or close)\n", $1
        }
        $2 == "over-limit" {
            reset_at = ($4 == "" ? "unknown" : $4)
            printf "  - %s OVER-LIMIT (resets %s; weekly Opus limit hit — schedule resume)\n", $1, reset_at
        }
        $2 == "idle-orphan-async" {
            # Issue #183: worker has self-declared external waits
            # but no resume mechanism (no Monitor handle, no
            # background bash, no ScheduleWakeup). The advisory
            # text quotes the offending kind:id list so the
            # operator can see the contract violation at a glance,
            # and points at the worker-defaults skill so a fix is
            # one paste away.
            kinds = ($4 == "" ? "unknown" : $4)
            printf "  - %s idle-orphan-async (waits=%s; no resume mechanism — install Monitor / background poller, or `declare-no-wait.sh <kind> <id>`; see skills/nexus.worker-defaults)\n", $1, kinds
        }
        $2 == "interrupted" {
            # stall-detection: last turn died to an API/model error
            # (StopFailure fired, NOT Stop) — claude is ALIVE, the box
            # is empty, no clean Stop ran. $4 = "<category>:<recovery>".
            # Recovery verb drives the operator action: paste resumes
            # in place (transient blip); respawn relaunches via
            # `--continue` (a config/conversation error re-fails on a
            # verbatim resend); operator needs a human (auth/model).
            split(($4 == "" ? "unknown:paste" : $4), tf, ":")
            cat = tf[1]; rec = tf[2]
            if (rec == "respawn")
                printf "  - %s interrupted %s — turn crashed (%s); a resume would re-fail, RESPAWN via `claude --continue` or fresh spawn\n", $1, fmt_age($3), cat
            else if (rec == "operator")
                printf "  - %s interrupted %s — turn crashed (%s); needs operator (credentials/model access), not a paste\n", $1, fmt_age($3), cat
            else
                printf "  - %s interrupted %s — turn crashed (%s, transient); process alive, PASTE a resume nudge to continue\n", $1, fmt_age($3), cat
        }
    '
    # Retained footer. Walks all retained rows in the transitions
    # output (list_idle_transitions only includes them when the
    # suppressed-set changed this cycle, so this naturally dedupes).
    printf '%s\n' "$transitions" | awk -F'\t' '
        BEGIN { n = 0; out = "" }
        $2 == "retained" && NF > 0 {
            reason = $4
            # Truncate to 40 chars (39 + …) so footer stays readable.
            if (length(reason) > 40) reason = substr(reason, 1, 39) "…"
            if (reason == "") reason = "(no reason)"
            n++
            entry = sprintf("%s (%s)", $1, reason)
            out = (out == "" ? entry : out ", " entry)
        }
        END {
            if (n > 0) printf "(%d retained windows suppressed: %s)\n", n, out
        }
    '
}

# ---- pending decisions (issue #129) -------------------------------------
#
# Workers spawned with `--settings monitor/worker-settings.json`
# write one JSON file per pending Claude Code notification to
# `$STATE_DIR/decisions/<window>.<fp>.json` via the
# `monitor/hooks/decision-emit.sh` handler. The orchestrator removes
# the file when it has answered the prompt (paste-decided or
# escalated); a sibling `<window>.<fp>.handled.json` is honoured as
# a terminal marker (audit-copy kept after answering).
#
# render_pending_decisions reads that directory each cycle and
# emits one operator-facing line per pending decision:
#
#   window=<W> fp=<FP> kind=<K> unresolved=<true|false>
#               prompt-excerpt=<first non-empty line>
#               file=<absolute path to the JSON>
#
# Cooldown: re-emit when the fingerprint is new OR when
# DECISION_REEMIT_COOLDOWN_SECONDS (default 300) has elapsed since
# the prior emit of the same (window, fp). The cooldown stamp is a
# TSV at `$STATE_DIR/pending-decisions-emit-state.tsv` with rows
# `<window>\t<fp>\t<last_emit_epoch>`. Pruned in-place each cycle so
# only currently-existing decisions retain a row — once the
# orchestrator removes a file, the next cycle drops its row.
#
# Empty stdout when nothing is pending. Anything we'd return to the
# caller is also gated by the caller's compose_report (it only
# inserts the section when stdout is non-empty).

_decisions_dir() {
    printf '%s/decisions' "${STATE_DIR:-.}"
}

_pending_decisions_emit_state_path() {
    printf '%s/pending-decisions-emit-state.tsv' "${STATE_DIR:-.}"
}

# Default cooldown — env overrideable. The 300s figure matches the
# operator's spec; tune only if a specific decision class observably
# needs faster re-pokes.
_decision_reemit_cooldown_seconds() {
    local cd="${DECISION_REEMIT_COOLDOWN_SECONDS:-300}"
    [[ "$cd" =~ ^[0-9]+$ ]] || cd=300
    printf '%s' "$cd"
}

render_pending_decisions() {
    local dir state_file
    dir=$(_decisions_dir)
    state_file=$(_pending_decisions_emit_state_path)
    [[ -d "$dir" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local now cooldown
    now=$(date +%s)
    cooldown=$(_decision_reemit_cooldown_seconds)

    # Gather current pending set into a TSV: window\tfp\tfile\tkind\texcerpt\tunresolved
    # We skip *.handled.json tombstones — those are terminal.
    local current=""
    local f bn win_fp win fp kind excerpt unresolved
    shopt -s nullglob 2>/dev/null
    for f in "$dir"/*.json; do
        case "$f" in
            *.handled.json) continue ;;
        esac
        # Filename convention: <window>.<fp>.json. Split on the LAST
        # dot before .json to tolerate window names with dots (the
        # CLAUDE.md gotcha says workspace conventions disallow dots
        # in window names, but be defensive — fp is 12 hex chars,
        # window is everything before the final `.fp.json` token).
        bn=$(basename "$f" .json)
        # Split window.fp by removing the final `.<12hex>` segment.
        # Falls through to whole basename + empty fp on malformed names.
        if [[ "$bn" =~ ^(.+)\.([0-9a-f]{12})$ ]]; then
            win="${BASH_REMATCH[1]}"
            fp="${BASH_REMATCH[2]}"
        else
            # Defensive fallback; read window/fp out of the JSON itself.
            win=$(jq -r '.window // ""' "$f" 2>/dev/null)
            fp=$(jq -r '.fingerprint // ""' "$f" 2>/dev/null)
            [[ -n "$win" ]] || continue
            [[ -n "$fp"  ]] || continue
        fi
        # Read kind / excerpt / unresolved from the JSON. The excerpt
        # is the first non-empty line of `prompt_excerpt`.
        kind=$(jq -r '.kind // "unknown"' "$f" 2>/dev/null)
        excerpt=$(jq -r '.prompt_excerpt // ""' "$f" 2>/dev/null \
                  | awk 'NF > 0 { print; exit }')
        # Truncate excerpt at 160 chars to keep the emit line readable.
        if (( ${#excerpt} > 160 )); then
            excerpt="${excerpt:0:157}…"
        fi
        unresolved=$(jq -r 'if .unresolved == true then "true" else "false" end' "$f" 2>/dev/null)
        current+="$win"$'\t'"$fp"$'\t'"$f"$'\t'"$kind"$'\t'"$excerpt"$'\t'"$unresolved"$'\n'
    done
    shopt -u nullglob 2>/dev/null

    [[ -n "$current" ]] || {
        # No pending decisions — clear stale state so a future row's
        # cooldown starts fresh.
        : > "$state_file"
        return 0
    }

    # Load prior emit state into associative array.
    declare -A prev_emit
    if [[ -f "$state_file" ]]; then
        while IFS=$'\t' read -r pw pfp pts; do
            [[ -n "$pw" ]] || continue
            prev_emit["$pw"$'\t'"$pfp"]="$pts"
        done < "$state_file"
    fi

    # Compute which rows to emit (new fp OR cooldown elapsed) and
    # write the next state file in the same pass.
    local emit_lines=""
    local next_state=""
    while IFS=$'\t' read -r win fp file kind excerpt unresolved; do
        [[ -n "$win" ]] || continue
        # Operator-engaged suppression (issues #196, #201). The
        # `idle_prompt` pings of a window the operator drives are
        # ordinary turn-end notifications, not decisions to ack — drop
        # the row from both the emit AND the cooldown state, leaving
        # the decision FILE in place. Suppression spans the away
        # phase too (the close-reminder is that phase's surface); if
        # the mark is invalidated (newer wrap-up/spawn) with the file
        # still present, the next cycle treats it as brand-new and
        # surfaces it — nothing is permanently muted. Other kinds
        # (permission_prompt, …) surface regardless.
        #
        # Same suppression for a skeptic-parked window
        # (emit-gate-recover): its await loop re-fires the SAME
        # idle_prompt fingerprint on every poll turn-end, and the
        # park is by definition not an action item ("waiting on the
        # skeptic; exempt from idle/close"). Without this, the
        # standing decision re-nagged every cooldown period for the
        # whole park — half of the 2026-07-06 A/B resurface flood.
        # When the park ends with the file still present, the next
        # cycle surfaces it as brand-new — nothing permanently muted.
        if [[ "$kind" == "idle_prompt" ]] \
           && { _openg_marked "$win" || _idle_skeptic_parked "$win" "$now"; }; then
            continue
        fi
        local key="$win"$'\t'"$fp"
        local last="${prev_emit[$key]:-}"
        local should_emit=0 last_emit_ts="$now"
        if [[ -z "$last" ]]; then
            # Brand-new (window, fp): emit.
            should_emit=1
        else
            # Cooldown check. Last emit recorded; re-emit only if
            # cooldown has elapsed.
            if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last >= cooldown )); then
                should_emit=1
            else
                last_emit_ts="$last"
            fi
        fi
        if (( should_emit == 1 )); then
            emit_lines+="window=$win fp=$fp kind=$kind unresolved=$unresolved"$'\n'
            emit_lines+="    prompt-excerpt=$excerpt"$'\n'
            emit_lines+="    file=$file"$'\n'
        fi
        next_state+="$win"$'\t'"$fp"$'\t'"$last_emit_ts"$'\n'
    done <<<"$current"

    # Persist next state (only currently-present (window,fp) pairs).
    printf '%s' "$next_state" > "$state_file"

    # Emit.
    if [[ -n "$emit_lines" ]]; then
        printf '%s' "$emit_lines"
    fi
}
