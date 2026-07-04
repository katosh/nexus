# shellcheck shell=bash
# monitor/watcher/_over_limit.sh — watcher-side wake scheduler for
# panes (orchestrator + workers) that hit the weekly Opus limit.
#
# Issue #87. Architectural premise: when a claude pane renders the
# canonical "You've hit your limit · resets <time>" notice, the
# session is functionally suspended. The orchestrator pane shares
# the same account/budget as workers, so an orchestrator-side
# scheduler can't be assumed alive at the moment it's needed.
# The watcher (pure shell, no claude budget) is the right responsible
# party: it's already polling pane state every cycle, and `tmux
# paste-buffer` requires no LLM mediation.
#
# State substrate: `monitor/.state/over-limit-state.tsv`. One row per
# suspended pane. Atomic-by-rename rewrites; reads are line-grep.
# Survives watcher restart by design — the wake-loop is the load-
# bearing recovery path; losing state would leave a worker stranded.
#
# Row schema (tab-separated):
#
#   <key> <window> <role> <reset_at_token> <reset_epoch>
#       <first_seen_epoch> <next_attempt_epoch> <attempts>
#
# `<key>` is `_orchestrator` when the pane is the watcher's TARGET,
# otherwise the window name. `<role>` is `orchestrator` or `worker`.
# All epoch fields are unix seconds.
#
# Public functions:
#
#   _over_limit_reset_at_to_epoch <token> [<now>]
#     Pure parser. Token shapes accepted:
#       "3am_America/Los_Angeles"  → next 3am in LA tz
#       "11pm"                      → next 11pm in caller's tz
#       "midnight_UTC"              → next midnight UTC
#       "unknown" / "" / unparseable → now + safety fallback (6h)
#     Always prints an integer epoch on stdout (return 0).
#
#   _over_limit_record <key> <window> <role> <reset_at_token>
#     Insert-or-refresh a stamp. Preserves first_seen_epoch and
#     attempts across refreshes (so repeated observations of an
#     unchanged suspension don't reset progress through backoff).
#     Recomputes reset_epoch + next_attempt_epoch each time, in case
#     the renderer's reset_at changes mid-suspension (theoretical
#     edge — clock-rollover during the wait).
#
#   _over_limit_drop <key>
#     Remove the row, atomically. Silent no-op when row absent.
#
#   _over_limit_load <key>
#     Tab-separated row for <key>, or empty on miss. Use IFS=$'\t' read.
#
#   _over_limit_orchestrator_paused
#     Exit 0 when an `_orchestrator` row exists, 1 otherwise. Used by
#     main.sh's paste-gate to suppress routine emits to a suspended
#     orchestrator (would pile up unread). Archive still runs.
#
#   _over_limit_keys
#     One key per line. Caller iterates to dispatch wake checks.
#
#   _over_limit_scan_panes <target_window>
#     Probe the orchestrator pane + every worker pane via pane-state.sh.
#     For each pane returning state=over-limit, _over_limit_record it.
#     Idempotent — re-running on a stable suspension just refreshes
#     the row's reset_epoch (no progress reset).
#
#   _over_limit_process_wakes <target_window>
#     The wake loop. For each stamped row whose next_attempt_epoch ≤
#     now, re-probe. If still over-limit: bump backoff (60s → 120s →
#     240s → cap 300s), increment attempts, drop after MAX_ATTEMPTS
#     (default 10). If transitioned out (idle/busy/empty/etc): paste
#     the resume brief and drop the row. If pane-absent or window
#     missing: log + drop. Returns 0 always (logs are advisory).
#
# Env knobs (override config or default):
#   MONITOR_OVER_LIMIT_WAKE_MARGIN_SECONDS    (default 300 = 5 min)
#       Safety margin added to reset_epoch before the first wake
#       attempt. Allows for clock-skew + the rate-limit-bucket-refill
#       not landing on the dot.
#   MONITOR_OVER_LIMIT_INITIAL_BACKOFF_SECONDS (default 60)
#       Delay before the first retry when a wake attempt finds the
#       pane still suspended.
#   MONITOR_OVER_LIMIT_MAX_BACKOFF_SECONDS    (default 300)
#       Cap on the exponential backoff between retries.
#   MONITOR_OVER_LIMIT_MAX_ATTEMPTS           (default 10)
#       Give up + drop the row after this many wake attempts.
#
# Logger contract: callers may set `_OVER_LIMIT_LOG_FN` to the name of
# a function that takes one string arg. Default is a noop. Tests pin a
# capturing impl; main.sh wires it to the watcher's `log` helper.
#
# Paster contract: callers may set `_OVER_LIMIT_PASTE_FN` to a function
# accepting `<window> <body_file>`. Default is noop. Tests pin a
# capturing impl; main.sh wires it to `paste_with_retry`.

_OVER_LIMIT_LOG_FN="${_OVER_LIMIT_LOG_FN:-_over_limit_log_noop}"
_OVER_LIMIT_PASTE_FN="${_OVER_LIMIT_PASTE_FN:-_over_limit_paste_noop}"

_over_limit_log_noop() { :; }
_over_limit_paste_noop() { return 0; }

_over_limit_state_path() {
    printf '%s/over-limit-state.tsv' "${STATE_DIR:-.}"
}

_over_limit_sanitize_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'
}

# Convert a reset_at token to a unix epoch. See header for shape rules.
# Always prints an integer epoch; never fails the pipeline.
_over_limit_reset_at_to_epoch() {
    local token="$1" now="${2:-$(date +%s)}"
    local fallback=$(( now + 21600 ))  # 6h safety net
    [[ -n "$token" && "$token" != "unknown" ]] || { printf '%d' "$fallback"; return 0; }
    local time_part tz_part epoch=""
    if [[ "$token" == *_* ]]; then
        time_part="${token%%_*}"
        tz_part="${token#*_}"
    else
        time_part="$token"
        tz_part=""
    fi
    # GNU date is forgiving with phrases like "3am" / "11pm" / "midnight".
    # Wrap the TZ in a subshell env-prefix when present so we don't bleed
    # TZ into the surrounding process.
    if [[ -n "$tz_part" ]]; then
        epoch=$(TZ="$tz_part" date -d "$time_part today" +%s 2>/dev/null)
    else
        epoch=$(date -d "$time_part today" +%s 2>/dev/null)
    fi
    [[ "$epoch" =~ ^[0-9]+$ ]] || { printf '%d' "$fallback"; return 0; }
    # If today's target has already passed, the next reset is tomorrow.
    if (( epoch <= now )); then
        epoch=$(( epoch + 86400 ))
    fi
    printf '%d' "$epoch"
}

# Read a row by key. Empty stdout when row absent. Returns 0 on hit
# (truthy use: `row=$(_over_limit_load k); [[ -n $row ]]`).
_over_limit_load() {
    local key="$1" path
    path=$(_over_limit_state_path)
    [[ -f "$path" ]] || return 1
    awk -F'\t' -v k="$key" '$1 == k { print; found=1; exit } END { exit !found }' "$path"
}

_over_limit_keys() {
    local path
    path=$(_over_limit_state_path)
    [[ -f "$path" ]] || return 0
    awk -F'\t' 'NF>=1 && $1 != "" { print $1 }' "$path"
}

_over_limit_orchestrator_paused() {
    local path
    path=$(_over_limit_state_path)
    [[ -f "$path" ]] || return 1
    awk -F'\t' '$1 == "_orchestrator" { found=1; exit } END { exit !found }' "$path"
}

# Atomic rewrite: read all rows, replace any with matching key, append
# the new row, rename into place.
_over_limit_write_row() {
    local key="$1" window="$2" role="$3" token="$4"
    local reset_epoch="$5" first_seen="$6" next_attempt="$7" attempts="$8"
    local path tmp dir
    path=$(_over_limit_state_path)
    dir=$(dirname "$path")
    mkdir -p "$dir" 2>/dev/null || true
    tmp=$(mktemp "${path}.XXXXXX")
    if [[ -f "$path" ]]; then
        awk -F'\t' -v k="$key" '$1 != k' "$path" > "$tmp"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$key" "$window" "$role" "$token" \
        "$reset_epoch" "$first_seen" "$next_attempt" "$attempts" \
        >> "$tmp"
    mv "$tmp" "$path"
}

_over_limit_record() {
    local key_raw="$1" window="$2" role="$3" token="$4"
    [[ -n "$key_raw" && -n "$window" && -n "$role" ]] || return 1
    local key
    key=$(_over_limit_sanitize_key "$key_raw")
    local now reset_epoch wake_margin first_seen attempts
    now=$(date +%s)
    reset_epoch=$(_over_limit_reset_at_to_epoch "$token" "$now")
    wake_margin="${MONITOR_OVER_LIMIT_WAKE_MARGIN_SECONDS:-300}"
    [[ "$wake_margin" =~ ^[0-9]+$ ]] || wake_margin=300
    first_seen=$now
    attempts=0
    local existing
    if existing=$(_over_limit_load "$key"); then
        local _ _ _ _ _ existing_first existing_attempts _
        IFS=$'\t' read -r _ _ _ _ _ existing_first _ existing_attempts <<<"$existing"
        [[ "$existing_first" =~ ^[0-9]+$ ]] && first_seen="$existing_first"
        [[ "$existing_attempts" =~ ^[0-9]+$ ]] && attempts="$existing_attempts"
    fi
    local next_attempt=$(( reset_epoch + wake_margin ))
    # Don't push next_attempt into the past if we've been sitting on a
    # stamp longer than the reset window suggested. Lower bound is now.
    (( next_attempt > now )) || next_attempt=$(( now + wake_margin ))
    _over_limit_write_row "$key" "$window" "$role" "$token" \
        "$reset_epoch" "$first_seen" "$next_attempt" "$attempts"
}

_over_limit_drop() {
    local key_raw="$1"
    [[ -n "$key_raw" ]] || return 1
    local key path tmp
    key=$(_over_limit_sanitize_key "$key_raw")
    path=$(_over_limit_state_path)
    [[ -f "$path" ]] || return 0
    tmp=$(mktemp "${path}.XXXXXX")
    awk -F'\t' -v k="$key" '$1 != k' "$path" > "$tmp"
    if [[ -s "$tmp" ]]; then
        mv "$tmp" "$path"
    else
        # Empty result — drop the file entirely so callers can use
        # `[[ -f path ]]` as a "any rows?" probe.
        rm -f "$path"
        rm -f "$tmp"
    fi
}

# Probe one pane via pane-state.sh; emit `state reset_at` on stdout
# (space-separated). Empty stdout on resolver failure.
_over_limit_probe_pane() {
    local window_arg="$1"
    local pane_state_script
    if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/pane-state.sh" ]]; then
        pane_state_script="$NEXUS_ROOT/monitor/pane-state.sh"
    elif [[ -x "$(dirname "${BASH_SOURCE[0]}")/../pane-state.sh" ]]; then
        pane_state_script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pane-state.sh
    else
        return 0
    fi
    local hb_args=() line state reset_at
    if [[ -n "${MONITOR_HEARTBEAT_STALENESS_SECONDS:-}" ]] \
        && [[ "$MONITOR_HEARTBEAT_STALENESS_SECONDS" =~ ^[0-9]+$ ]]; then
        hb_args+=(--heartbeat-staleness "$MONITOR_HEARTBEAT_STALENESS_SECONDS")
    fi
    line=$("$pane_state_script" "${hb_args[@]}" "$window_arg" 2>/dev/null) || return 0
    state=$(printf '%s' "$line" | sed -n 's/.*state=\([a-z-]*\).*/\1/p')
    reset_at=$(printf '%s' "$line" | sed -n 's/.*reset_at=\([^ ]*\).*/\1/p')
    [[ -n "$state" ]] || return 0
    printf '%s %s' "$state" "${reset_at:-unknown}"
}

# Scan the orchestrator pane + every worker pane. Stamp any returning
# state=over-limit. Reuses _idle_list_worker_windows from
# _idle_probe.sh for the worker enumeration so the reserved-name
# filter (target / cockpit `services` / `watcher` / `claude` /
# `orchestrator` / `monitor` + registry services) stays in one place.
_over_limit_scan_panes() {
    local target="${1:?target window required}"
    local probe state reset_at
    # Orchestrator pane: name-targeted lookup. tmux's send-keys et al.
    # accept the window NAME, so pane-state.sh — which expects an
    # index or `session:window` — needs the index resolved first.
    local orch_index
    orch_index=$(_over_limit_resolve_window_index "$target")
    if [[ -n "$orch_index" ]]; then
        probe=$(_over_limit_probe_pane "$orch_index")
        if [[ -n "$probe" ]]; then
            read -r state reset_at <<<"$probe"
            if [[ "$state" == "over-limit" ]]; then
                _over_limit_record "_orchestrator" "$target" \
                    "orchestrator" "$reset_at"
            fi
        fi
    fi
    # Workers: only when _idle_probe.sh is sourced (it provides the
    # reserved-name filter). If the lister isn't available, we
    # silently skip worker stamps — orchestrator stamps still work.
    if declare -F _idle_list_worker_windows >/dev/null 2>&1; then
        local name activity_epoch window_index
        while IFS=$'\t' read -r name activity_epoch window_index; do
            [[ -n "$name" ]] || continue
            local probe_target="${window_index:-$name}"
            probe=$(_over_limit_probe_pane "$probe_target")
            [[ -n "$probe" ]] || continue
            read -r state reset_at <<<"$probe"
            if [[ "$state" == "over-limit" ]]; then
                _over_limit_record "$name" "$name" "worker" "$reset_at"
            fi
        done < <(_idle_list_worker_windows)
    fi
}

# Resolve a tmux window name to its index (for pane-state.sh).
# Empty stdout when tmux is missing or the window doesn't exist.
_over_limit_resolve_window_index() {
    local name="$1"
    command -v tmux >/dev/null 2>&1 || return 0
    tmux list-windows -F '#{window_name}|#{window_index}' 2>/dev/null \
        | awk -F'|' -v n="$name" '$1 == n { print $2; exit }'
}

# Build the resume brief that lands in the orchestrator's input box
# when the watcher detects resumption. Arguments:
#   $1  ISO-formatted reset_at token (display only)
#   $2  duration seconds (display only — formatted to Hh:MMm:SSs)
#   $3  optional: comma-separated list of currently-stamped worker
#       windows; empty means "no workers affected"
_over_limit_compose_resume_brief() {
    local token="$1" duration="$2" workers="$3"
    # Pretty-print the token. The first `_` separates the time from
    # the tz; subsequent `_` chars inside the tz (e.g.
    # `America/Los_Angeles`) MUST be preserved. So we split on
    # first `_` only.
    local pretty
    if [[ "$token" == *_* ]]; then
        pretty="${token%%_*} (${token#*_})"
    else
        pretty="$token"
    fi
    local d_h=$(( duration / 3600 ))
    local d_m=$(( (duration % 3600) / 60 ))
    local d_s=$(( duration % 60 ))
    local pretty_dur
    pretty_dur=$(printf '%dh %02dm %02ds' "$d_h" "$d_m" "$d_s")
    {
        printf 'Watcher resume: weekly Opus limit reset (%s).\n' "$pretty"
        printf 'You were suspended for %s.\n' "$pretty_dur"
        if [[ -n "$workers" ]]; then
            printf 'Workers still queued for wake: %s.\n' "$workers"
            printf 'The watcher will paste a resume directive into each as it transitions out.\n'
        else
            printf 'No workers were suspended in this window.\n'
        fi
        printf 'Most recent watcher state is in monitor/.state/last-snapshot.txt; the previous emits remain archived under monitor/.state/diffs/ (paste path was paused while you were inert).\n'
        printf 'Proceed with bootstrap.sh as you would on any resumption.\n'
    }
}

# Build the worker-side wake brief. Workers carry their own
# conversation context; a terse "resume" suffices.
_over_limit_compose_worker_brief() {
    local token="$1" pretty
    # Same first-underscore-only split as the orchestrator brief.
    if [[ "$token" == *_* ]]; then
        pretty="${token%%_*} (${token#*_})"
    else
        pretty="$token"
    fi
    {
        printf 'Watcher resume: weekly Opus limit reset (%s). You can continue the work you had in flight before suspension.\n' "$pretty"
    }
}

# Format human-readable list of currently-stamped worker windows for
# the orchestrator brief. Empty stdout when no worker rows exist.
_over_limit_worker_summary() {
    local path
    path=$(_over_limit_state_path)
    [[ -f "$path" ]] || return 0
    awk -F'\t' '$3 == "worker" { print $2 }' "$path" \
        | sort -u \
        | paste -sd, -
}

# Per-row wake decision. Args: tab-row from the state file. Mutates
# state (drops row, updates attempts/next_attempt) and pastes via the
# injected _OVER_LIMIT_PASTE_FN.
_over_limit_evaluate_row() {
    local row="$1" now="$2"
    local key window role token reset_epoch first_seen next_attempt attempts
    IFS=$'\t' read -r key window role token reset_epoch first_seen next_attempt attempts \
        <<<"$row"
    [[ -n "$key" ]] || return 0
    # Not due yet — leave the row alone.
    (( now >= next_attempt )) || return 0

    local probe_target
    if [[ "$role" == "orchestrator" ]]; then
        probe_target=$(_over_limit_resolve_window_index "$window")
    else
        probe_target=$(_over_limit_resolve_window_index "$window")
    fi
    if [[ -z "$probe_target" ]]; then
        "$_OVER_LIMIT_LOG_FN" \
            "over-limit: window '${window}' (key=${key}) absent at wake; dropping stamp"
        _over_limit_drop "$key"
        return 0
    fi

    local probe state reset_at
    probe=$(_over_limit_probe_pane "$probe_target")
    if [[ -z "$probe" ]]; then
        "$_OVER_LIMIT_LOG_FN" \
            "over-limit: pane-state probe failed for '${window}' (key=${key}); will retry"
        # Apply backoff so we don't busy-loop on a flaky probe.
        _over_limit_apply_backoff "$key" "$window" "$role" "$token" \
            "$reset_epoch" "$first_seen" "$attempts" "$now"
        return 0
    fi
    read -r state reset_at <<<"$probe"

    case "$state" in
        over-limit)
            local new_attempts=$(( attempts + 1 ))
            local max_attempts="${MONITOR_OVER_LIMIT_MAX_ATTEMPTS:-10}"
            [[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=10
            if (( new_attempts >= max_attempts )); then
                "$_OVER_LIMIT_LOG_FN" \
                    "over-limit: max wake attempts (${max_attempts}) reached for '${window}' (key=${key}); dropping stamp — operator intervention required"
                _over_limit_drop "$key"
                return 0
            fi
            _over_limit_apply_backoff "$key" "$window" "$role" "$token" \
                "$reset_epoch" "$first_seen" "$new_attempts" "$now"
            "$_OVER_LIMIT_LOG_FN" \
                "over-limit: '${window}' still suspended (attempt ${new_attempts}/${max_attempts}); next probe at $(date -d "@$(_over_limit_load_next_attempt "$key")" -Is 2>/dev/null || echo '?')"
            ;;
        absent|blocked)
            "$_OVER_LIMIT_LOG_FN" \
                "over-limit: '${window}' (key=${key}) reads ${state}; pane lost during suspension — dropping stamp"
            _over_limit_drop "$key"
            ;;
        idle|autosuggest-only|empty|busy|user-typing)
            # Resumption. Paste the appropriate brief and drop the
            # stamp. We compute duration from first_seen so it
            # reflects total inertness, not just the last retry leg.
            local duration=$(( now - first_seen ))
            (( duration >= 0 )) || duration=0
            local body
            body=$(mktemp)
            if [[ "$role" == "orchestrator" ]]; then
                local workers
                workers=$(_over_limit_worker_summary)
                _over_limit_compose_resume_brief \
                    "$token" "$duration" "$workers" > "$body"
            else
                _over_limit_compose_worker_brief "$token" > "$body"
                # Stamp the machine-input ledger BEFORE the worker wake
                # paste (stamp-before-paste ordering). This is a
                # watcher-initiated wake into a *worker* pane, so the
                # resulting UserPromptSubmit must be attributed to the
                # machine, not the operator — an unstamped wake leaves
                # machine_epoch stale and falsely marks the window
                # operator-engaged, holding retire-preflight at safe=0
                # until staleness (#293, gap row 6). Orchestrator wakes
                # are NOT stamped: the orchestrator window is not
                # retire-gated (matches the unstamped orchestrator-pane
                # paths, inventory rows 8/9).
                _machine_input_stamp "$window" "over-limit-wake"
            fi
            if "$_OVER_LIMIT_PASTE_FN" "$window" "$body"; then
                "$_OVER_LIMIT_LOG_FN" \
                    "over-limit: '${window}' resumed (suspended ${duration}s); resume brief pasted"
                _over_limit_drop "$key"
            else
                "$_OVER_LIMIT_LOG_FN" \
                    "over-limit: '${window}' transitioned out but paste failed; will retry next cycle"
                # Paste failed — re-attempt next cycle without
                # consuming an attempt slot (the suspension is gone;
                # the failure is in the paste path).
                _over_limit_apply_backoff "$key" "$window" "$role" "$token" \
                    "$reset_epoch" "$first_seen" "$attempts" "$now"
            fi
            rm -f "$body"
            ;;
        *)
            "$_OVER_LIMIT_LOG_FN" \
                "over-limit: '${window}' reads unexpected state '${state}'; treating as still-suspended"
            local new_attempts=$(( attempts + 1 ))
            _over_limit_apply_backoff "$key" "$window" "$role" "$token" \
                "$reset_epoch" "$first_seen" "$new_attempts" "$now"
            ;;
    esac
}

# Compute the next backoff and rewrite the row. Exponential: 60s →
# 120s → 240s → cap at 300s. Initial backoff and cap are configurable
# via env knobs.
_over_limit_apply_backoff() {
    local key="$1" window="$2" role="$3" token="$4"
    local reset_epoch="$5" first_seen="$6" attempts="$7" now="$8"
    local initial="${MONITOR_OVER_LIMIT_INITIAL_BACKOFF_SECONDS:-60}"
    local cap="${MONITOR_OVER_LIMIT_MAX_BACKOFF_SECONDS:-300}"
    [[ "$initial" =~ ^[0-9]+$ ]] || initial=60
    [[ "$cap"     =~ ^[0-9]+$ ]] || cap=300
    # attempts here is the *resulting* attempt count for the row; the
    # first retry uses `initial`, the second uses `2*initial`, etc.
    local shift_n=$(( attempts > 0 ? attempts - 1 : 0 ))
    (( shift_n > 16 )) && shift_n=16  # guard against pathological << overflow
    local delay=$(( initial << shift_n ))
    (( delay > cap )) && delay=$cap
    (( delay < initial )) && delay=$initial
    local next_attempt=$(( now + delay ))
    _over_limit_write_row "$key" "$window" "$role" "$token" \
        "$reset_epoch" "$first_seen" "$next_attempt" "$attempts"
}

_over_limit_load_next_attempt() {
    local row
    row=$(_over_limit_load "$1") || { printf '0'; return 0; }
    awk -F'\t' '{print $7}' <<<"$row"
}

_over_limit_process_wakes() {
    local target="${1:?target window required}"
    local path now
    path=$(_over_limit_state_path)
    [[ -f "$path" ]] || return 0
    now=$(date +%s)
    # Snapshot the rows up front so a mid-loop _over_limit_drop /
    # _over_limit_write_row doesn't disturb the iteration.
    local snapshot
    snapshot=$(cat "$path" 2>/dev/null)
    [[ -n "$snapshot" ]] || return 0
    local row
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        _over_limit_evaluate_row "$row" "$now"
    done <<<"$snapshot"
}
