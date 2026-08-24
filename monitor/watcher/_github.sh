#!/usr/bin/env bash
# GitHub-snapshot helpers for the nexus watcher.
#
# Loaded by monitor/watcher/main.sh and by monitor/watcher/test-*.sh.
# Side-effect-free: only function definitions, no top-level state
# (plus one pure-function source: _log-mode.sh, nexus-code#509).
# The caller is responsible for setting these globals before any
# function is invoked:
#
#   STATE_DIR    monitor/.state — used to read processed-comments.txt
#   REPO         github.repo, e.g. "your-org/your-nexus"
#   USER_LOGIN   github.user_login — only this user's content is
#                eligible; enforced by `_filter_to_user_author`
#                downstream regardless of which source emitted it.
#
# Four sources are unioned. The first three emit COMMENT lines, the
# fourth emits an ISSUE-creation line:
#
#   1. Open-issue comments  -> "issue=<n> id=<cid> author=<login>"
#   2. Open-PR conversation comments  -> "pr=<n> id=<cid> author=<login>"
#   3. Open-PR review-thread comments (inline-on-diff) ->
#         "pr_review=<n> id=<cid> author=<login> path=<file>"
#   4. NEW open issues (the issue itself, not its comments) ->
#         "issue_new=<n> id=<n> author=<login>"
#
# `issue_new=` is its own line-shape (not `issue=`) so existing parsers
# that only look for `issue=` / `pr=` / `pr_review=` keep working
# unchanged. The body preview line below the header is identical
# across all four shapes.
#
# Dedup. Single file `monitor/.state/processed-comments.txt`, one
# entry per line, prefixed by kind:
#
#   comment:<databaseId>     comments (sources 1-3)
#   issue:<issue-number>     issues   (source 4)
#
# A single file with prefixed entries (rather than a sibling
# processed-issues.txt) keeps the propagation-lag guard and its
# population in one place. The cache is a best-effort guard against
# the GH-side propagation lag between POST /reactions and the next
# `snapshot_github` reading the EYES/ROCKET reaction; stale entries
# only cost one extra emit, never correctness, since the eligibility
# filter against live reactions is the actual security boundary.

# Detect-and-react on GraphQL failures.
#
# The `_snapshot_*` helpers below issue `gh api graphql` calls against
# the bot installation token's GraphQL bucket. When that bucket
# exhausts (4–5 active workers can drain 5,000 pts/hr in well under an
# hour), every call returns a `graphql_rate_limit` error that the
# previous `2>/dev/null` swallowed — leaving the watcher silently
# productive while no eligible comments surfaced. The 2026-05-01
# incident silenced the watcher for 2 h 17 m before operator noticed.
#
# Two helpers close that gap:
#
#   _graphql_backoff_active <surface>
#       Returns 0 (active) if the per-surface backoff file
#       `${STATE_DIR}/graphql-backoff-<surface>` holds an epoch in the
#       future (with a 30 s grace past reset). Cleans up the file when
#       the window has elapsed and removes any stale alert flags.
#
#   _watcher_handle_graphql_failure <stderr_file> <surface>
#       Classifies the captured stderr. On rate-limit signature
#       (`"type":"RATE_LIMIT"` or `"code":"graphql_rate_limit"`),
#       writes the backoff file, appends one line to
#       `watcher-alerts.log`, and emits a `watcher_alert=rate-limit …`
#       sentinel line on stdout (rides `_dedup_emit_lines` →
#       `compose_report` → `paste_to_target` so the orchestrator sees
#       it within one cycle). Sentinel + log dedup via a flag file
#       keyed on (surface, reset-epoch): one alert per bucket-
#       exhaustion event, not one per poll. On other failure classes,
#       writes a single rate-limited (one per 10 min per surface) log
#       line; no sentinel emit, to avoid alert-storm on transient
#       network noise.
#
# State files (all under `${STATE_DIR}/`, gitignored via .state/):
#
#   graphql-backoff-<surface>                 reset epoch (digits)
#   graphql-alert-emitted-<surface>-<epoch>   flag: alert + log emitted
#   graphql-other-last-log-<surface>          last non-rate-limit log epoch
#   watcher-alerts.log                        append-only [iso] level surface key
#
# Bucket-floor gate: should the watcher run GraphQL polling right
# now? Probes `gh api /rate_limit` (free, REST core) and skips if
# `graphql.remaining < MONITOR_GRAPHQL_THRESHOLD`. Default threshold
# 200 — leaves headroom for orchestrator + worker writes while the
# bucket replenishes. The `github_poll` task interval (600 s,
# registered in main.sh) supplies the cadence; this gate adds a
# reactive safety net for bursty bucket draws (worker storms,
# concurrent gh-api callers).
#
# Probe failures (network glitch, gh CLI missing, malformed JSON)
# prefer skip + a single rate-limited line in `watcher-alerts.log`
# (one per 10 min per failure-class). Better to lose a backstop poll
# than to churn against an unhealthy bucket.
#
# Composes with `_graphql_backoff_active`:
#
#   - This gate runs BEFORE `snapshot_github` is called, gating the
#     entire GraphQL surface (issue_comments + pr_comments +
#     new_issues + mentions) for the fire.
#   - `_graphql_backoff_active` runs INSIDE each `_snapshot_*` helper,
#     gating per-surface after a confirmed RATE_LIMIT response.
#
# So a fire can:
#   - fail the gate (remaining below floor)
#     → 0 GraphQL calls;
#   - pass the gate, then have one surface in per-surface backoff
#     → that surface skips, the others run normally;
#   - pass the gate, then hit a fresh rate-limit on a surface
#     → the detect-and-react path arms backoff for that surface,
#       future fires' per-surface check short-circuits it.
#
# Caller globals (set by main.sh):
#   STATE_DIR              monitor/.state — for watcher-alerts.log
#   GRAPHQL_THRESHOLD      env-or-config-resolved floor (non-negative int)
#   MINT_TOKEN_BIN         path to mint-token.sh (used for the probe)
#
# Exit:
#   0 — run GraphQL polling
#   1 — skip GraphQL polling
#
# stdout: nothing.
# `_ensure_service_log` (nexus-code#484/#509): the alerts-log append
# below must never create the file group-writable.
_github_module_dir="${BASH_SOURCE[0]%/*}"
[[ "$_github_module_dir" == "${BASH_SOURCE[0]}" ]] && _github_module_dir=.
# shellcheck source=../_log-mode.sh
source "$_github_module_dir/../_log-mode.sh"
unset _github_module_dir

_graphql_polling_gate() {
    local threshold="${GRAPHQL_THRESHOLD:-200}"
    [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=200

    # Bucket-floor probe. `gh api /rate_limit` is a free call (does
    # not consume from any bucket). Use the bot installation token if
    # available so we measure the bucket the watcher actually drains;
    # fall back to whatever GH_TOKEN/PAT gh uses by default if mint
    # fails (caller may still be on a healthy user PAT).
    #
    # WEDGE-SAFETY (your-org/nexus-code#367): this REST probe runs FIRST
    # every github_poll cycle (it gates the GraphQL surface), on the same
    # async task that the bounded graphql calls ride. An unbounded hung
    # probe would wedge the scheduler exactly like an unbounded graphql
    # call — so bound it with the SAME `timeout` ceiling. A hung probe
    # exits non-zero within the budget; the existing `|| probe_json=""`
    # + empty-check below then alerts `probe_failed` and skips the fire
    # (retry next cycle), never blocking.
    local now; now=$(date +%s 2>/dev/null || echo 0)
    local _gt="${GRAPHQL_TIMEOUT:-30}"; [[ "$_gt" =~ ^[0-9]+$ && "$_gt" -gt 0 ]] || _gt=30
    local _gk="${GRAPHQL_TIMEOUT_KILL_AFTER:-5}"; [[ "$_gk" =~ ^[0-9]+$ ]] || _gk=5
    local probe_token=""
    if [[ -n "${MINT_TOKEN_BIN:-}" && -x "${MINT_TOKEN_BIN}" ]]; then
        probe_token=$("$MINT_TOKEN_BIN" 2>/dev/null) || probe_token=""
    fi
    local probe_json
    if [[ -n "$probe_token" ]]; then
        probe_json=$(GH_TOKEN="$probe_token" timeout -k "$_gk" "$_gt" gh api /rate_limit 2>/dev/null) \
            || probe_json=""
    else
        probe_json=$(timeout -k "$_gk" "$_gt" gh api /rate_limit 2>/dev/null) || probe_json=""
    fi
    if [[ -z "$probe_json" ]]; then
        _graphql_gate_alert "$now" probe_failed "rate_limit probe returned no data"
        return 1
    fi

    local remaining
    remaining=$(jq -r '.resources.graphql.remaining // empty' \
                <<<"$probe_json" 2>/dev/null)
    if [[ -z "$remaining" || ! "$remaining" =~ ^[0-9]+$ ]]; then
        _graphql_gate_alert "$now" probe_malformed "rate_limit JSON missing graphql.remaining"
        return 1
    fi

    if (( remaining < threshold )); then
        _graphql_gate_alert "$now" below_floor \
            "graphql.remaining=$remaining below threshold=$threshold; deliveries path remains active if enabled"
        return 1
    fi
    return 0
}

# Throttled writer for `watcher-alerts.log` from the gate. One line
# per (kind, 10-min window) so a sustained low-bucket condition logs
# once every 10 min instead of once per cycle. Idempotent on STATE_DIR
# absence (best-effort, never fails the caller).
_graphql_gate_alert() {
    local now="$1" kind="$2" detail="$3"
    [[ -d "${STATE_DIR:-}" ]] || return 0
    local marker="${STATE_DIR}/graphql-gate-last-log-${kind}"
    local last=0
    [[ -f "$marker" ]] && last=$(<"$marker")
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if (( now - last < 600 )); then
        return 0
    fi
    local iso; iso=$(date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    _ensure_service_log "${STATE_DIR}/watcher-alerts.log"
    printf '[%s] WARN graphql_gate %s %s\n' "$iso" "$kind" "$detail" \
        >> "${STATE_DIR}/watcher-alerts.log" 2>/dev/null || true
    printf '%s\n' "$now" > "$marker" 2>/dev/null || true
}

# ---- backoff ceiling + reconciliation (your-org/nexus-code#594) ----------
#
# `_graphql_backoff_active` decides whether to WITHHOLD the operator's
# comments from the orchestrator. Before #594 it decided that from a
# stored future instant alone — the same defect `#592`/`#593` fixed on
# the egress gate `_over_limit_orchestrator_paused`. A stored instant is
# a PREDICTION ("the bucket will still be exhausted at T"); it is never
# an OBSERVATION ("the bucket is exhausted"). When the prediction is
# wrong — miscomputed, clock-skewed, ratcheted by a bad `reset_at`, or
# simply never cleared — the channel closes and stays closed, silently.
# It was strictly worse than the gate `#593` fixed, because nothing
# bounded it: `reset` came straight from the API payload (or a 15-min
# fallback) and was never range-checked, so a single absurd value could
# suppress a surface indefinitely.
#
# Three properties close it, mirroring `#593`:
#
#   BOUND       No armed backoff may suppress a surface for longer than
#               `MONITOR_GRAPHQL_BACKOFF_MAX_SECONDS` (default 900),
#               measured from the OBSERVATION that armed it — not from
#               the predicted reset. Past the ceiling the gate opens
#               regardless of what the stored instant says. The worst
#               case is now a number in this file, not whatever GitHub
#               put in a payload.
#   RECONCILE   Every call repairs rather than waits out a bad file:
#               a malformed reset, a missing armed stamp, an expired
#               window and a ceiling breach all CLEAR the state and
#               re-open the gate. A stale epoch cannot outlive one poll.
#   ANNOUNCE    A suppression that persists past
#               `MONITOR_GRAPHQL_BACKOFF_ANNOUNCE_SECONDS` emits an
#               out-of-band `watcher_alert=` sentinel on stdout (which
#               rides compose_report to the orchestrator) in addition to
#               the log line. A condition that mutes operator
#               communication must not be reportable only through the
#               channel it mutes.
#
# On-disk format is backward compatible: line 1 is the reset epoch
# (unchanged, so an in-flight watcher reading an old file still works),
# line 2 is the epoch at which the rate-limit response was OBSERVED. A
# legacy single-line file gets its observation from the file's mtime —
# a real observation, since the file is written at arm time.
_graphql_backoff_ceiling() {
    local v="${MONITOR_GRAPHQL_BACKOFF_MAX_SECONDS:-900}"
    [[ "$v" =~ ^[0-9]+$ && "$v" -gt 0 ]] || v=900
    printf '%s' "$v"
}

# Clear every state file for one surface's armed backoff.
_graphql_backoff_clear() {
    local surface="$1"
    rm -f "${STATE_DIR}/graphql-backoff-${surface}" \
          "${STATE_DIR}/graphql-alert-emitted-${surface}-"* \
          "${STATE_DIR}/graphql-backoff-announced-${surface}" 2>/dev/null || true
}

# Throttled WARN row for a reconciliation (the gate opening itself back
# up). Distinct `reason` per cause so the log distinguishes "the window
# simply elapsed" from "we refused to honour a bad epoch".
_graphql_backoff_reconcile_log() {
    local surface="$1" reason="$2" detail="$3"
    [[ -d "${STATE_DIR:-}" ]] || return 0
    local iso; iso=$(date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    _ensure_service_log "${STATE_DIR}/watcher-alerts.log"
    printf '[%s] WARN %s graphql_backoff_reconciled reason=%s %s\n' \
        "$iso" "$surface" "$reason" "$detail" \
        >> "${STATE_DIR}/watcher-alerts.log" 2>/dev/null || true
}

_graphql_backoff_active() {
    local surface="$1"
    local file="${STATE_DIR}/graphql-backoff-${surface}"
    [[ -f "$file" ]] || return 1
    local reset armed
    { read -r reset; read -r armed; } < "$file" 2>/dev/null || true
    local now; now=$(date +%s)

    # RECONCILE — a reset we cannot parse is not evidence of anything.
    if [[ ! "$reset" =~ ^[0-9]+$ ]]; then
        _graphql_backoff_clear "$surface"
        _graphql_backoff_reconcile_log "$surface" malformed_reset \
            "stored reset=${reset:-<empty>} is not an epoch; refusing to withhold on an unparseable instant"
        return 1
    fi
    # Legacy single-line file (or a torn write): recover the observation
    # from the file's mtime, which IS when the backoff was armed.
    if [[ ! "$armed" =~ ^[0-9]+$ ]]; then
        armed=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo "$now")
        [[ "$armed" =~ ^[0-9]+$ ]] || armed="$now"
    fi

    # BOUND — the ceiling is measured from the observation, and it wins
    # over the stored prediction unconditionally. A clock that jumped
    # backwards yields a negative age; treat that as "cannot trust this
    # stamp" and reconcile rather than suppress.
    local ceiling; ceiling=$(_graphql_backoff_ceiling)
    if (( now - armed >= ceiling || now < armed )); then
        _graphql_backoff_clear "$surface"
        _graphql_backoff_reconcile_log "$surface" ceiling \
            "suppression reached the ${ceiling}s ceiling (armed=${armed} reset=${reset} now=${now}); re-opening the surface — the next call re-arms only on a FRESH rate-limit response"
        return 1
    fi

    # The ordinary expiry, unchanged (30 s grace past the reset).
    if (( now >= reset + 30 )); then
        _graphql_backoff_clear "$surface"
        return 1
    fi

    # ANNOUNCE — still suppressing. Past the announce delay, say so
    # somewhere that does not depend on the surface we are muting.
    _graphql_backoff_announce "$surface" "$armed" "$reset" "$now"
    return 0
}

# Out-of-band announcement for a live suppression. One sentinel per
# (surface, armed-epoch), so an ongoing hold announces ONCE rather than
# every poll — the `#593` announcement model. stdout rides the caller's
# emit stream to the orchestrator.
_graphql_backoff_announce() {
    local surface="$1" armed="$2" reset="$3" now="$4"
    local delay="${MONITOR_GRAPHQL_BACKOFF_ANNOUNCE_SECONDS:-300}"
    [[ "$delay" =~ ^[0-9]+$ ]] || delay=300
    (( now - armed >= delay )) || return 0
    local flag="${STATE_DIR}/graphql-backoff-announced-${surface}"
    [[ -f "$flag" && "$(cat "$flag" 2>/dev/null)" == "$armed" ]] && return 0
    printf '%s\n' "$armed" > "$flag" 2>/dev/null || true
    local ceiling; ceiling=$(_graphql_backoff_ceiling)
    local iso; iso=$(date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    _ensure_service_log "${STATE_DIR}/watcher-alerts.log"
    printf '[%s] WARN %s graphql_backoff_suppressing armed=%s reset=%s ceiling=%s\n' \
        "$iso" "$surface" "$armed" "$reset" "$ceiling" \
        >> "${STATE_DIR}/watcher-alerts.log" 2>/dev/null || true
    printf 'watcher_alert=graphql-backoff surface=%s held_s=%s ceiling_s=%s\n  body: The %s snapshot has been suppressed for %s min after a rate-limit response. Operator comments on that surface are NOT reaching this emit while it holds. It reconciles automatically at the %ss ceiling even if the API-supplied reset says otherwise.\n' \
        "$surface" "$(( now - armed ))" "$ceiling" \
        "$surface" "$(( (now - armed) / 60 ))" "$ceiling"
}

_watcher_handle_graphql_failure() {
    local err_file="$1" surface="$2"
    local err_body=""
    [[ -f "$err_file" ]] && err_body=$(<"$err_file")
    local alerts="${STATE_DIR}/watcher-alerts.log"
    local now; now=$(date +%s)
    local iso; iso=$(date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

    # Match the rate-limit signature regardless of JSON whitespace
    # (gh outputs both compact and pretty-printed forms depending on
    # the failure path). The quoted strings `"RATE_LIMIT"` and
    # `"graphql_rate_limit"` are unique to this error class. The gh
    # CLI also flattens rate-limit errors into a human-readable text
    # form (`gh: API rate limit already exceeded for installation ID
    # NNN.`); the literal phrase is identical across REST + GraphQL
    # paths and is what stderr actually carries when gh handles the
    # error itself before printing.
    if grep -qE '"RATE_LIMIT"|"graphql_rate_limit"|API rate limit already exceeded' <<<"$err_body"; then
        # Try to recover the reset epoch from the payload. GitHub
        # exposes it inconsistently (sometimes header-only, sometimes
        # `extensions.reset_at_epoch`, sometimes ISO `extensions.reset_at`).
        # Fall back to now + 15 min if neither parses — that's longer
        # than the typical 1-hour bucket reset slice, but the next
        # successful call will reset the backoff regardless.
        local reset_raw reset=""
        reset_raw=$(jq -r '
              (.errors // [])[]
              | (.extensions // {})
              | ((.reset_at_epoch // empty) | tostring),
                (.reset_at // empty)
            ' <<<"$err_body" 2>/dev/null | head -n1)
        if [[ "$reset_raw" =~ ^[0-9]+$ ]]; then
            reset="$reset_raw"
        elif [[ -n "$reset_raw" ]]; then
            reset=$(date -d "$reset_raw" +%s 2>/dev/null || true)
        fi
        [[ "$reset" =~ ^[0-9]+$ ]] || reset=$(( now + 900 ))

        # your-org/nexus-code#594 — clamp the API-supplied prediction at
        # arm time as well as at read time. `reset` here is whatever
        # GitHub put in the payload; nothing validated its range before,
        # so one absurd `reset_at` (or a clock skew) could park the
        # surface far into the future. The read-side ceiling in
        # `_graphql_backoff_active` would still rescue it, but clamping
        # on write keeps the on-disk state honest — a human reading the
        # file sees the horizon actually in force. A reset already in
        # the past collapses to `now`, which the read side then expires
        # on its next call.
        local ceiling; ceiling=$(_graphql_backoff_ceiling)
        if (( reset > now + ceiling )); then
            printf '[%s] WARN %s graphql_backoff_clamped api_reset=%s clamped_to=%s ceiling=%s\n' \
                "$iso" "$surface" "$reset" "$(( now + ceiling ))" "$ceiling" >> "$alerts"
            reset=$(( now + ceiling ))
        fi
        (( reset < now )) && reset="$now"

        # Line 1 reset (unchanged, backward compatible), line 2 the
        # epoch we OBSERVED the rate-limit response — the ceiling is
        # measured from the observation, never from the prediction.
        printf '%s\n%s\n' "$reset" "$now" > "${STATE_DIR}/graphql-backoff-${surface}"
        rm -f "${STATE_DIR}/graphql-backoff-announced-${surface}" 2>/dev/null || true

        local flag="${STATE_DIR}/graphql-alert-emitted-${surface}-${reset}"
        if [[ ! -f "$flag" ]]; then
            : > "$flag"
            local reset_iso
            reset_iso=$(date -d "@$reset" -Is 2>/dev/null || echo "epoch=$reset")
            printf '[%s] WARN %s graphql_rate_limit reset=%s reset_iso=%s\n' \
                "$iso" "$surface" "$reset" "$reset_iso" >> "$alerts"
            printf 'watcher_alert=rate-limit surface=%s reset=%s\n  body: GraphQL bucket exhausted; suppressing %s snapshot until %s. Deliveries path (if enabled) remains active.\n' \
                "$surface" "$reset" "$surface" "$reset_iso"
        fi
        return 0
    fi

    # Non-rate-limit failure (transport hiccup, malformed query,
    # MAX_NODE_LIMIT_EXCEEDED, etc.). Throttle the log to once per
    # 10 min per surface so a transient outage doesn't fill the file.
    # No sentinel emit — we don't want to alert-storm the orchestrator
    # for noise we can't classify.
    local marker="${STATE_DIR}/graphql-other-last-log-${surface}"
    local last=0
    [[ -f "$marker" ]] && last=$(<"$marker")
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if (( now - last >= 600 )); then
        local detail
        if [[ -z "$err_body" ]]; then
            detail="empty_stderr"
        else
            detail=$(printf '%s' "$err_body" | tr '\n\r\t' '   ' | head -c 500)
        fi
        printf '[%s] WARN %s graphql_failure %s\n' "$iso" "$surface" "$detail" >> "$alerts"
        printf '%s\n' "$now" > "$marker"
    fi
    return 0
}

# ---- sustained-degradation escalation (your-org/nexus-code#595) -----------
#
# The non-rate-limit branch above throttles to one WARN per 10 min per
# surface and emits NOTHING out-of-band. That is exactly how `#595`
# stayed invisible: `issue_comments` failed with
# `RESOURCE_LIMITS_EXCEEDED` on ~80% of polls for hours, logging
# faithfully to `watcher-alerts.log`, and no human read the file. The
# rule the `#592`/`#594`/`#595` cluster converges on is that no fetch on
# the operator-communication path may fail on the strength of a log line
# alone.
#
# So: track how long a surface has been CONTINUOUSLY failing and, past
# `MONITOR_GRAPHQL_DEGRADED_ESCALATE_SECONDS` (default 1800), emit a
# `watcher_alert=` sentinel that rides compose_report to the
# orchestrator, re-nagging on the slower
# `MONITOR_GRAPHQL_DEGRADED_REMIND_SECONDS` (default 3600) cadence. A
# recovery after an escalation announces itself too — an alert that
# never retracts trains the reader to ignore it.
#
# State: `graphql-degraded-<surface>` holding `first`/`count`/`announced`.
_graphql_degraded_path() { printf '%s/graphql-degraded-%s' "${STATE_DIR:-.}" "$1"; }

_graphql_degraded_field() {
    local f="$1" key="$2"
    [[ -f "$f" ]] || return 1
    awk -F= -v k="$key" '$1==k{print $2; exit}' "$f" 2>/dev/null
}

# Record one FAILED fetch of <surface>. stdout: an escalation sentinel
# when one is due (empty otherwise).
# <kind> distinguishes a surface that returned NOTHING (`total`) from one
# that delivered some pages but stopped early (`truncated`). Both are
# degradation — a truncated walk withholds an unknown tail — but the
# operator needs to know which, because the remedies differ (a total
# failure is usually transport or rate limit; a truncation usually means
# the page size is too large for one issue's comment history).
_graphql_note_failure() {
    local surface="$1" kind="${2:-total}"
    [[ -d "${STATE_DIR:-}" ]] || return 0
    local now; now=$(date +%s)
    local f; f=$(_graphql_degraded_path "$surface")
    local first count announced
    first=$(_graphql_degraded_field "$f" first 2>/dev/null || true)
    count=$(_graphql_degraded_field "$f" count 2>/dev/null || true)
    announced=$(_graphql_degraded_field "$f" announced 2>/dev/null || true)
    [[ "$first" =~ ^[0-9]+$ ]] || first="$now"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [[ "$announced" =~ ^[0-9]+$ ]] || announced=0
    count=$(( count + 1 ))
    # A clock that moved backwards must not manufacture a huge outage.
    (( now < first )) && first="$now"

    local escalate="${MONITOR_GRAPHQL_DEGRADED_ESCALATE_SECONDS:-1800}"
    [[ "$escalate" =~ ^[0-9]+$ ]] || escalate=1800
    local remind="${MONITOR_GRAPHQL_DEGRADED_REMIND_SECONDS:-3600}"
    [[ "$remind" =~ ^[0-9]+$ ]] || remind=3600

    local due=0 held=$(( now - first ))
    if (( held >= escalate )); then
        if (( announced == 0 )) || (( now - announced >= remind )); then
            due=1; announced="$now"
        fi
    fi
    printf 'first=%s\ncount=%s\nannounced=%s\n' "$first" "$count" "$announced" \
        > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
    (( due == 1 )) || return 0

    local iso; iso=$(date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    _ensure_service_log "${STATE_DIR}/watcher-alerts.log"
    printf '[%s] WARN %s graphql_degraded_escalated kind=%s held_s=%s consecutive_failures=%s\n' \
        "$iso" "$surface" "$kind" "$held" "$count" >> "${STATE_DIR}/watcher-alerts.log" 2>/dev/null || true
    if [[ "$kind" == "partial" ]]; then
        printf 'watcher_alert=ingest-degraded surface=%s kind=partial held_s=%s occurrences=%s\n  body: The %s fetch has discarded at least one page on every attempt for %s min (%s consecutive). The walk completes, but the issues on the discarded page are NOT being surfaced. Most likely a single issue has a comment history too large for the current page size: lower monitor.graphql.search_page_size. See %s/watcher-alerts.log for the graphql_partial_walk line naming the cause.\n' \
            "$surface" "$held" "$count" \
            "$surface" "$(( held / 60 ))" "$count" "${STATE_DIR}"
    elif [[ "$kind" == "truncated" ]]; then
        printf 'watcher_alert=ingest-degraded surface=%s kind=truncated held_s=%s occurrences=%s\n  body: The %s fetch has been TRUNCATED on every attempt for %s min (%s consecutive). Some pages land, but the walk stops early every cycle, so the issues after the stopping point are NOT being surfaced at all — an unknown tail, not a slow one. Most likely a single issue has a comment history too large for the current page size: lower monitor.graphql.search_page_size. See %s/watcher-alerts.log for the graphql_partial_walk line naming the cause.\n' \
            "$surface" "$held" "$count" \
            "$surface" "$(( held / 60 ))" "$count" "${STATE_DIR}"
    else
        printf 'watcher_alert=ingest-degraded surface=%s kind=total held_s=%s failures=%s\n  body: The %s fetch has failed on EVERY attempt for %s min (%s consecutive failures). This is the ingest side of the operator channel: comments on that surface are not being surfaced while it fails. They are not lost — an un-acked comment resurfaces on the first successful fetch — but freshness is degraded until this clears. See %s/watcher-alerts.log for the underlying error.\n' \
            "$surface" "$held" "$count" \
            "$surface" "$(( held / 60 ))" "$count" "${STATE_DIR}"
    fi
    return 0
}

# Record one SUCCESSFUL fetch of <surface>. stdout: a recovery line when
# the surface had previously escalated (empty otherwise).
_graphql_note_success() {
    local surface="$1"
    [[ -d "${STATE_DIR:-}" ]] || return 0
    local f; f=$(_graphql_degraded_path "$surface")
    [[ -f "$f" ]] || return 0
    local first count announced now
    now=$(date +%s)
    first=$(_graphql_degraded_field "$f" first 2>/dev/null || true)
    count=$(_graphql_degraded_field "$f" count 2>/dev/null || true)
    announced=$(_graphql_degraded_field "$f" announced 2>/dev/null || true)
    rm -f "$f" 2>/dev/null || true
    [[ "$announced" =~ ^[0-9]+$ && "$announced" -gt 0 ]] || return 0
    local iso; iso=$(date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    _ensure_service_log "${STATE_DIR}/watcher-alerts.log"
    printf '[%s] INFO %s graphql_degraded_recovered after_s=%s failures=%s\n' \
        "$iso" "$surface" "$(( now - ${first:-$now} ))" "${count:-?}" \
        >> "${STATE_DIR}/watcher-alerts.log" 2>/dev/null || true
    printf 'watcher_alert=ingest-recovered surface=%s\n  body: The %s fetch is succeeding again after %s min degraded (%s consecutive failures). Any comment withheld during the outage surfaces on this cycle.\n' \
        "$surface" "$surface" "$(( (now - ${first:-$now}) / 60 ))" "${count:-?}"
    return 0
}

# Single source of truth for the user-author eligibility filter.
#
# Every comment-surfacing emit (snapshot_github, snapshot_deliveries,
# snapshot_mentions) is piped through this function before reaching
# the rest of the watcher pipeline. Drops emit blocks (header line +
# any subsequent `  body:` continuation) whose `author=<login>` token
# does not equal $USER_LOGIN. Lines that don't match a known emit-
# header prefix pass through untouched (so `watcher_alert=` sentinels
# and unrelated stdout chatter aren't accidentally swallowed).
#
# This is the chokepoint introduced by issue #86. Previously each
# `snapshot_*` source enforced the user filter locally; the
# `snapshot_deliveries` path leaked when it accepted `mention_only`
# / `author_or_mention` modes that surfaced non-user-authored content
# (e.g. a sibling bot opening an issue surfaced as
# `mention=… author=<bot>[bot]`). Concentrating the filter at the
# pipeline level means no future source can forget the rule — every
# consumer pipes through `_gh_filter_dedup_pipeline` in main.sh.
#
# Cross-instance bot notifications (bot pings user from elsewhere)
# are an accepted loss; the operator monitors those threads manually.
#
# Reads stdin, writes stdout. Caller globals:
#   USER_LOGIN   github.user_login (the only login that surfaces)
_filter_to_user_author() {
    # LC_ALL=C — byte-safe regex on body previews carrying byte-truncated
    # (invalid) UTF-8; no multibyte interpretation under any ambient locale.
    # Mirrors the _reemit.sh re-feed discipline (see _reemit.sh ~L194).
    LC_ALL=C awk -v user="${USER_LOGIN:-}" '
        function is_header(s) {
            return s ~ /^(issue|pr|pr_review|issue_new|mention|cross_repo)=/
        }
        function is_body(s) { return s ~ /^[[:space:]]+body:/ }
        {
            if (is_header($0)) {
                a = ""
                if (match($0, /author=[^[:space:]]+/)) {
                    a = substr($0, RSTART + 7, RLENGTH - 7)
                }
                if (user != "" && a == user) { drop = 0; print }
                else { drop = 1 }
            }
            else if (is_body($0)) {
                if (drop == 0) print
            }
            else {
                drop = 0
                print
            }
        }
    '
}

# Cross-repo surface gate. Runs immediately after `_filter_to_user_author`
# in `_gh_filter_dedup_pipeline` (main.sh). Decides whether each
# cross-repo emit block (`mention=` from `_deliveries.sh`,
# `cross_repo=` from `_mentions.sh`) reaches the eligible-comments
# stream, based on the `monitor.cross_repo_surface` knob (resolved
# into `CROSS_REPO_SURFACE` by `main.sh`).
#
# Three modes:
#
#   mention_only (default)
#     Cross-repo blocks surface only when the body explicitly
#     `@`-mentions `github.bot_login` (case-insensitive, word-boundary).
#     The operator's everyday cross-repo chatter (e.g. directing
#     another operator on `your-org/other-nexus#37` with no
#     `@<bot>` token) is dropped — it isn't a directive for this bot
#     instance. Recommended default per operator request 2026-05-18.
#
#   author_only
#     Legacy pre-2026-05-18 behaviour: every cross-repo block that
#     passed the user-author chokepoint surfaces, mention or not.
#     Provided so operators who want the broad "see everything I post
#     anywhere" view can opt back in.
#
#   off
#     Cross-repo blocks never surface, even with an explicit
#     @-mention. For operators who only care about activity on
#     `$REPO` itself.
#
# In-`$REPO` shapes (`issue=`, `pr=`, `pr_review=`, `issue_new=`) and
# non-header lines (`watcher_alert=`, separators, etc.) always pass
# through untouched in every mode — `$REPO` is the canonical input
# channel and must not require an `@`-mention.
#
# Bot-login matching strips a trailing `[bot]` from `BOT_LOGIN` if
# present (GitHub `@`-mention syntax targets the slug without the
# `[bot]` suffix). If `BOT_LOGIN` is empty under `mention_only`, the
# mode degrades to `off` — there is no bot to match, so the safest
# interpretation of "surface only when the bot is mentioned" is to
# surface nothing. `main.sh` logs a single warning at startup when
# this degradation kicks in.
#
# Unknown / misspelled modes fall back to `mention_only` (the
# documented default) rather than silently passing everything through.
#
# Reads stdin, writes stdout. Caller globals:
#   CROSS_REPO_SURFACE   mode token (mention_only|author_only|off)
#   BOT_LOGIN            github.bot_login (slug, optionally [bot]-suffixed)
_filter_cross_repo_surface() {
    # LC_ALL=C — byte-safe. `tolower(body) ~ bot_pat` decodes the WHOLE body
    # preview; a byte-truncated (invalid) UTF-8 char there warns + makes the
    # match undefined under the ambient locale. Mirrors _reemit.sh ~L194.
    LC_ALL=C awk -v bot="${BOT_LOGIN:-}" -v mode="${CROSS_REPO_SURFACE:-mention_only}" '
        BEGIN {
            bot_lc = tolower(bot)
            sub(/\[bot\]$/, "", bot_lc)
            if (mode != "author_only" && mode != "off" && mode != "mention_only") {
                mode = "mention_only"
            }
            if (mode == "mention_only" && bot_lc == "") {
                mode = "off"
            }
            if (bot_lc != "") {
                bot_pat = "(^|[^[:alnum:]_])@" bot_lc "([^[:alnum:]_-]|$)"
            }
            header = ""
            body = ""
        }
        function decide_cross_repo(b) {
            if (mode == "author_only") return 1
            if (mode == "off") return 0
            return (tolower(b) ~ bot_pat)
        }
        function emit_block(    is_cross, keep) {
            if (header == "") return
            is_cross = (header ~ /^(mention|cross_repo)=/)
            keep = is_cross ? decide_cross_repo(body) : 1
            if (keep) {
                print header
                if (body != "") print body
            }
            header = ""; body = ""
        }
        /^(issue|pr|pr_review|issue_new|mention|cross_repo)=/ {
            emit_block()
            header = $0
            body = ""
            next
        }
        /^[[:space:]]+body:/ {
            if (header != "" && body == "") {
                body = $0
            } else {
                emit_block()
                print
            }
            next
        }
        {
            emit_block()
            print
        }
        END { emit_block() }
    '
}

# Operator opt-out marker. Lets the operator post a comment (or open an
# issue) that the watcher will NOT forward to the orchestrator — a
# first-class "side note / don't act on this" escape hatch that replaces
# the older racy self-🚀 reaction and clumsy alternate-identity
# workarounds.
#
# Two recognized forms, matched against the body-preview continuation
# line (`  body: …`) of each emit block:
#
#   1. PRIMARY — slash command. The comment's FIRST non-empty line,
#      trimmed and case-insensitive, is exactly `/skip` (synonym:
#      `/nexus-skip`). The operator types `/skip` on the first line and
#      their note below. Trivial to type, near-zero false-positive.
#
#   2. SECONDARY — invisible HTML marker `<!-- nexus:skip -->` appearing
#      ANYWHERE in the body. A power-user form that leaves no rendered
#      trace in GitHub markdown. Kept because it costs one OR clause.
#
# Applies to EVERY surface the watcher forwards: issue comments
# (`issue=`), PR conversation comments (`pr=`), PR review-thread comments
# (`pr_review=`), new-issue bodies (`issue_new=`), and cross-repo blocks
# (`mention=`, `cross_repo=`). Honoring it on `issue_new=` is deliberate
# — the operator can open a tracking issue without the orchestrator
# jumping on it.
#
# COLLAPSED-BODY NOTE. By the time a body reaches this filter the
# emitter has already run `gsub("[\n\r\t]+"; " ")`, so newlines are
# spaces and the original line structure is gone. "First non-empty line
# is exactly /skip" therefore re-expresses, losslessly for every
# operator-given case, as "the body, after trimming leading whitespace,
# begins with the `/skip` (or `/nexus-skip`) token followed by
# whitespace or end-of-string." A `/skip` that started on line 3 lands
# mid-string after collapse and correctly does NOT match.
#
# HARD SAFETY RULE (watcher-critical). The eligibility filter is the
# operator's control surface; a false drop is a real directive silently
# lost. So this layer drops ONLY on an unambiguous fixed match:
#   - the HTML marker is matched with awk `index()` — a literal
#     fixed-string scan, no regex metacharacters, so it can never
#     over-match;
#   - the slash command requires the token at the very start followed by
#     a word boundary (`/skipfoo`, `/skip-x`, "let's skip this", or
#     `/skip` buried mid-body all KEEP/forward).
# Any block without an unambiguous hit passes through — preserving the
# file's standing "false positive = one extra emit is the safe bias".
# This is strictly an additional drop condition layered on top of the
# author + cross-repo filters; it does not alter either.
#
# Each drop writes one diagnostic line to `${STATE_DIR}/watcher.log`
# (mirroring `log`'s file destination) when STATE_DIR is set, else to
# stderr — so a skip is diagnosable, never a silent swallow. The
# diagnostic NEVER touches stdout, which is the emit stream the
# orchestrator consumes.
#
# Reads stdin, writes stdout. Caller globals:
#   STATE_DIR   (optional) monitor/.state — drop diagnostics land in
#               its watcher.log; absent → diagnostics go to stderr.
_filter_skip_marker() {
    # LC_ALL=C — byte-safe. `body_is_skip` runs tolower()/sub()/index() over
    # the whole body preview, which may carry byte-truncated (invalid) UTF-8.
    # Mirrors _reemit.sh ~L194.
    LC_ALL=C awk -v statedir="${STATE_DIR:-}" '
        BEGIN {
            html_marker = "<!-- nexus:skip -->"
            logfile = (statedir != "") ? statedir "/watcher.log" : "/dev/stderr"
            header = ""; body = ""
        }
        # Decide whether a body-preview line carries an opt-out marker.
        function body_is_skip(line,    c, lc) {
            c = line
            sub(/^[[:space:]]*body:[[:space:]]*/, "", c)
            # Secondary form: invisible HTML marker, fixed-string scan.
            if (index(c, html_marker) > 0) return 1
            # Primary form: leading slash command. Trim leading
            # whitespace (collapse already turned newlines to spaces, so
            # this lands us at the first non-empty line) then require an
            # exact token at the start.
            sub(/^[[:space:]]+/, "", c)
            lc = tolower(c)
            if (lc == "/skip"       || lc ~ /^\/skip[[:space:]]/)       return 1
            if (lc == "/nexus-skip" || lc ~ /^\/nexus-skip[[:space:]]/) return 1
            return 0
        }
        function emit_block(    keep) {
            if (header == "") return
            keep = 1
            if (body != "" && body_is_skip(body)) keep = 0
            if (keep) {
                print header
                if (body != "") print body
            } else {
                printf "[skip-marker] dropped emit (opt-out): %s\n", header >> logfile
            }
            header = ""; body = ""
        }
        /^(issue|pr|pr_review|issue_new|mention|cross_repo)=/ {
            emit_block()
            header = $0
            body = ""
            next
        }
        /^[[:space:]]+body:/ {
            if (header != "" && body == "") {
                body = $0
            } else {
                emit_block()
                print
            }
            next
        }
        {
            emit_block()
            print
        }
        END { emit_block() }
    '
}

# Throttled (once per 10 min) WARN row for a failed/empty mint-token
# result, mirroring `_watcher_handle_graphql_failure`'s non-rate-limit
# branch. Goes to watcher-alerts.log — snapshot_github runs inside an
# async scheduler subshell whose stderr is a per-task sidecar, so a
# plain stderr echo would not reach the operator's log reliably.
_watcher_alert_mint_failure() {
    local alerts="${STATE_DIR}/watcher-alerts.log"
    local marker="${STATE_DIR}/mint-token-last-warn"
    local now last=0
    now=$(date +%s)
    [[ -f "$marker" ]] && last=$(<"$marker")
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last >= 600 )) || return 0
    local iso
    iso=$(date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '[%s] WARN mint-token failed or returned empty; snapshot_github skipped — eligible comments will NOT surface until minting recovers (check monitor/mint-token.sh, App key, clock skew)\n' \
        "$iso" >> "$alerts"
    printf '%s\n' "$now" > "$marker"
}

snapshot_github() {
    local processed_file="${STATE_DIR}/processed-comments.txt"
    local processed_content=""
    [[ -f "$processed_file" ]] && processed_content=$(<"$processed_file")
    # Mint a bot installation token for this poll cycle so all `gh api`
    # calls below run on the App's separate rate-limit bucket. Without
    # this, `gh` falls through to the user's stored PAT — which today
    # has a 5,000/hr GraphQL bucket shared with every other tool the
    # user runs (`gh`, `labsh-rust-skill`, `watcher-merge`, etc.). Once
    # exhausted, every GraphQL call here returns an error that the
    # `2>/dev/null` redirect swallows, leaving `snapshot_github`
    # silently empty and the watcher unable to surface comments.
    # A mint failure (or an empty token) means the whole snapshot is
    # skipped — eligible comments stop surfacing until minting
    # recovers. That used to happen in TOTAL silence (`|| return 0`,
    # stderr discarded): the watcher looked healthy while its primary
    # input channel was dead (your-org/your-nexus#180 R4). Now it
    # leaves a throttled WARN in watcher-alerts.log.
    local _gh_token
    if ! _gh_token=$("${MINT_TOKEN_BIN:-${_monitor_dir:-./monitor}/mint-token.sh}" 2>/dev/null) \
       || [[ -z "$_gh_token" ]]; then
        _watcher_alert_mint_failure
        return 0
    fi
    # Sub-call progress markers (issue #162). Each GraphQL call below
    # can take a couple of seconds; without intermediate logs the
    # watcher pane shows nothing while three queries run back-to-back.
    # `_snapshot_progress` is a no-op when sourced standalone (tests).
    _snapshot_progress "snapshot-github: issue-comments"
    GH_TOKEN="$_gh_token" _snapshot_issue_comments "$processed_content"
    _snapshot_progress "snapshot-github: pr-comments"
    GH_TOKEN="$_gh_token" _snapshot_pr_comments "$processed_content"
    _snapshot_progress "snapshot-github: new-issues"
    GH_TOKEN="$_gh_token" _snapshot_new_issues "$processed_content"
}

# Progress marker hook. main.sh defines `log` (writes to stderr +
# watcher.log); when this file is sourced from a test harness without
# main.sh, `log` is undefined and `_snapshot_progress` degrades to a
# no-op so test stdout stays clean.
_snapshot_progress() {
    declare -F log >/dev/null 2>&1 && log "$@"
}

# Run one snapshot `gh api graphql` call under a hard wall-clock
# ceiling (your-org/nexus-code#367).
#
# `gh api graphql` honours NO curl timeout flag — `_mentions.sh`
# already notes this is why its poll uses a raw `--max-time` curl
# instead of `gh` (lines ~684-686). The three `snapshot_github`
# GraphQL calls below stayed on `gh api graphql` and had no guard at
# all: a single hung / black-holed GitHub request froze the whole
# watcher scheduler indefinitely (heartbeat stops advancing, child
# task-forks pile up, multi-minute blind window until the supervisor
# force-restarts — observed twice in ~2 days on a live operator).
#
# `timeout` is the bound (the right tool for a `gh` subprocess that
# ignores curl flags): SIGTERM at GRAPHQL_TIMEOUT s, then SIGKILL
# `GRAPHQL_TIMEOUT_KILL_AFTER` s later if gh ignores TERM. On the
# timeout exit codes — 124 (killed by the TERM) or 137 (killed by the
# KILL backstop) — we append a recognizable `graphql_timeout` marker
# to the caller's stderr file so `_watcher_handle_graphql_failure`
# surfaces a CLEAR, throttled log line (non-rate-limit branch: log +
# return, no backoff) instead of an opaque empty-stderr failure. The
# snapshot fails gracefully and retries next cycle; the scheduler is
# never blocked.
#
# `timeout` cannot exec a bash function, so the unit tests (which
# shadow `gh` with a function) install a matching `timeout` shadow
# that strips the flags and runs the rest — keeping a SINGLE
# production code path under test.
#
#   $1   stderr-capture file (caller-owned mktemp)
#   $2…  the `api graphql …` argv, passed through verbatim
# stdout: the GraphQL response body (empty on failure)
# return: the gh / timeout exit status (0 on success)
_snapshot_graphql() {
    local err_file="$1"; shift
    local t="${GRAPHQL_TIMEOUT:-30}"
    [[ "$t" =~ ^[0-9]+$ && "$t" -gt 0 ]] || t=30
    local k="${GRAPHQL_TIMEOUT_KILL_AFTER:-5}"
    [[ "$k" =~ ^[0-9]+$ ]] || k=5
    local out rc
    out=$(timeout -k "$k" "$t" gh "$@" 2>"$err_file")
    rc=$?
    if (( rc == 124 || rc == 137 )); then
        printf 'graphql_timeout: gh api graphql exceeded %ss wall-clock ceiling (signal %s)\n' \
            "$t" "$([[ $rc == 137 ]] && echo KILL || echo TERM)" >> "$err_file"
    fi
    printf '%s' "$out"
    return "$rc"
}

# ---- paginated search (your-org/nexus-code#595) --------------------------
#
# WHY. The single-shot `search(first: 100)` shape below used to fetch
# every open issue's last 50 comments in ONE query. Measured against
# your-org/your-nexus on 2026-07-30 that query returned HTTP 200 with a
# 2.59 MB body carrying **2,933 `RESOURCE_LIMITS_EXCEEDED` field errors**
# — GitHub had resolved the query PARTIALLY and nulled fields to stay
# inside its budget: `author` was null on all 1,247 comments, `body` and
# `reactions` null on 439 of them, and some `databaseId`s null too. `gh`
# exits 1 when errors are present, so the whole response was discarded
# and the surface produced nothing on ~80% of polls for hours.
#
# WHAT ACTUALLY DRIVES THE COST. Not node count: `rateLimit.nodeCount`
# fell from 255,100 to 55,100 to 10,100 as `reactions(first:)` went
# 50 → 10 → 1, and the query failed IDENTICALLY at all three (same 2,933
# errors, same 2,592,723-byte body). The limiter tracks the work of
# materialising comment BODIES. Ablation on the same repo:
#
#   search first:100, comments last:50, reactions first:50 → FAIL 2.59 MB
#   search first:100, comments last:50, reactions first:10 → FAIL 2.59 MB
#   search first:100, comments last:50, reactions first:1  → FAIL 2.59 MB
#   search first:100, comments last:20, reactions first:50 → ok   1.86 MB
#   search first:25,  comments last:50, reactions first:50 → ok   1.40 MB
#
# So the trip point sits between 1.86 MB and the ~3.07 MB the full set
# actually weighs. Paging the SEARCH (rather than shrinking
# `comments(last:)`) is the fix that costs no coverage: narrowing the
# comment window would let an un-acked comment scroll permanently out of
# view, because eligibility has no time bound — a comment stays eligible
# until it is ROCKET-ed or processed.
#
# Measured after, same repo, page size 10: 6 pages, largest page
# 794,073 B, total 3,075,347 B (i.e. ~0.48 MB MORE real content than the
# failing query returned — the difference is what GitHub was silently
# nulling), 15.1 s wall, zero errors on every page.
#
# WHY PARTIAL PAGES ARE DISCARDED, NOT SALVAGED. A partially-resolved
# page nulls `reactions`. The EYES/ROCKET filter reads exactly that
# field to decide a comment was already acked, so consuming partial data
# would make every acked comment look eligible and re-emit the backlog.
# Discarding the page and retrying next cycle is the only safe reading.
#
# WHY `sort:created-asc`. Cursor pagination over an unstable ordering can
# SKIP an item when the set reorders mid-walk. Default search relevance
# and `sort:updated` both reorder whenever an issue is touched — and the
# walk takes ~15 s, during which a comment arriving on page 5's issue
# would move it to page 1 and shift a page-6 issue out of view.
# Creation time never changes, so `created-asc` is the only ordering
# here that is immutable for a fixed result set.
#
# COVERAGE BOUNDARY (one sentence, on the axis the mechanism varies on —
# the SIZE OF THE RESULT SET, since that is what pagination bounds):
# this makes the fetch cost-safe for up to
# `MONITOR_GRAPHQL_SEARCH_MAX_PAGES` × `MONITOR_GRAPHQL_SEARCH_PAGE_SIZE`
# open issues (default 40 × 10 = 400) whose individual last-50-comment
# payload fits one page's budget; beyond that page cap the walk stops
# and says so loudly, and a SINGLE issue whose own last 50 comments
# exceed the per-query budget fails its page every cycle — degrading
# that page's ten issues, and, ONLY if that page also yields no usable
# cursor, every LATER page with it.
#
# That second clause is load-bearing and was absent from the first
# version of this comment (found by the #595 skeptic, req-001). The
# original code `break`-ed on a partial page, so one bad page withheld
# the entire TAIL — pages 2..N, not ten issues — and because earlier
# pages HAD landed, the caller then recorded a SUCCESS, clearing the
# degradation counter and leaving a throttled WARN as the only trace.
# That is precisely the log-only invisibility this issue exists to
# kill, reproduced one level down. Now a partial page is SKIPPED (its
# `pageInfo` is shallow and normally survives the nulling that hits
# deep `comments.nodes[].*` paths, so the walk continues from its
# cursor), and any walk that still ends early sets
# `_SEARCH_PAGES_TRUNCATED`, which the caller treats as degradation
# rather than success — so a PERSISTENT truncation escalates
# out-of-band like any other failing fetch on the operator channel.
#
# _snapshot_search_paged <surface> <query> <q> <out_file>
#   <query> must declare ($q: String!, $first: Int!, $after: String) and
#   select `search(... first: $first, after: $after)` with a
#   `pageInfo { hasNextPage endCursor }`.
# <out_file> receives one COMPACT JSON page per line — successful,
#   COMPLETE pages only. It is a FILE and not stdout on purpose: this
#   function must run in the CALLER's shell so its page-count globals
#   survive (a `$(...)` capture would fork a subshell and silently
#   discard them), and the caller's stdout is the live emit stream.
# globals: _SEARCH_PAGES_TOTAL _SEARCH_PAGES_OK _SEARCH_PAGES_FAILED
# return: 0 if at least one page succeeded, 1 if every page failed.
_snapshot_search_paged() {
    local surface="$1" query="$2" q="$3" out="$4"
    # Set the counters BEFORE any early return: the caller reads them
    # unconditionally, and under `set -u` an unset global is a hard
    # error that would take the whole snapshot down on a condition as
    # mundane as an unwritable temp file.
    _SEARCH_PAGES_TOTAL=0; _SEARCH_PAGES_OK=0; _SEARCH_PAGES_FAILED=0
    # Set when the walk ends EARLY — pages after this point were never
    # fetched. Distinct from a failed page: a truncated walk withholds an
    # unknown number of issues, so the caller must treat it as degradation
    # rather than success (your-org/nexus-code#595 skeptic req-001).
    _SEARCH_PAGES_TRUNCATED=0
    : > "$out" 2>/dev/null || return 1
    local page_size="${MONITOR_GRAPHQL_SEARCH_PAGE_SIZE:-10}"
    [[ "$page_size" =~ ^[0-9]+$ && "$page_size" -gt 0 && "$page_size" -le 100 ]] || page_size=10
    local max_pages="${MONITOR_GRAPHQL_SEARCH_MAX_PAGES:-40}"
    [[ "$max_pages" =~ ^[0-9]+$ && "$max_pages" -gt 0 ]] || max_pages=40
    local budget="${MONITOR_GRAPHQL_SEARCH_BUDGET_SECONDS:-180}"
    [[ "$budget" =~ ^[0-9]+$ && "$budget" -gt 0 ]] || budget=180

    local started; started=$(date +%s)
    local cursor="" _err _stdout rc nerr hasnext
    local -a argv
    while (( _SEARCH_PAGES_TOTAL < max_pages )); do
        # Wall-clock budget for the WHOLE walk. `_snapshot_graphql`
        # bounds each individual call, but N bounded calls are still
        # N×timeout unbounded in aggregate — and this runs on the async
        # scheduler slot the wedge guard (#367) exists to protect.
        if (( $(date +%s) - started >= budget )); then
            _snapshot_progress "snapshot-github: ${surface} page walk hit ${budget}s budget after ${_SEARCH_PAGES_TOTAL} pages"
            _SEARCH_PAGES_TRUNCATED=1
            _graphql_search_partial_log "$surface" budget_exhausted \
                "walk stopped after ${_SEARCH_PAGES_TOTAL} pages / ${budget}s; remaining issues not fetched this cycle"
            break
        fi
        _SEARCH_PAGES_TOTAL=$(( _SEARCH_PAGES_TOTAL + 1 ))
        _err=$(mktemp)
        argv=(api graphql -f query="$query" -f q="$q" -F first="$page_size")
        # An OMITTED nullable variable is null in GraphQL, which is what
        # `after:` wants for the first page — so no cursor interpolation
        # into the query string is ever needed.
        [[ -n "$cursor" ]] && argv+=(-f after="$cursor")
        _stdout=$(_snapshot_graphql "$_err" "${argv[@]}"); rc=$?
        if (( rc != 0 )); then
            _SEARCH_PAGES_FAILED=$(( _SEARCH_PAGES_FAILED + 1 ))
            _SEARCH_PAGES_TRUNCATED=1
            _watcher_handle_graphql_failure "$_err" "$surface"
            rm -f "$_err"
            break
        fi
        rm -f "$_err"
        # CHECK THE PROPERTY, NOT THE PROXY. rc=0 means "gh was happy",
        # not "this page is complete". GitHub returns HTTP 200 with a
        # populated `data` AND a top-level `errors` array when it
        # partially resolves; a page carrying any error has null fields
        # (see the partial-page note above) and must not be consumed.
        nerr=$(printf '%s' "$_stdout" | jq '(.errors // []) | length' 2>/dev/null)
        [[ "$nerr" =~ ^[0-9]+$ ]] || nerr=0
        if (( nerr > 0 )); then
            _SEARCH_PAGES_FAILED=$(( _SEARCH_PAGES_FAILED + 1 ))
            # SKIP THE PAGE, DO NOT ABANDON THE WALK. Breaking here
            # would discard every LATER page too, so one pathological
            # issue on page 2 would withhold pages 2..N — the whole tail
            # — not its own ten issues. `pageInfo` is a shallow, cheap
            # field and survives the nulling that hits deep
            # `comments.nodes[].*` paths, so the cursor is normally
            # still usable: take it and carry on, losing only this page.
            # If it is NOT usable we genuinely cannot continue, and that
            # is a TRUNCATED walk, flagged so the caller can escalate.
            hasnext=$(printf '%s' "$_stdout" | jq -r '.data.search.pageInfo.hasNextPage // false' 2>/dev/null)
            cursor=$(printf '%s' "$_stdout" | jq -r '.data.search.pageInfo.endCursor // empty' 2>/dev/null)
            if [[ "$hasnext" == "true" && -n "$cursor" ]]; then
                _graphql_search_partial_log "$surface" partial_resolution \
                    "page ${_SEARCH_PAGES_TOTAL} returned ${nerr} field errors (fields nulled); page DISCARDED, walk CONTINUES from its cursor — reduce MONITOR_GRAPHQL_SEARCH_PAGE_SIZE (now ${page_size})"
                continue
            fi
            if [[ "$hasnext" == "true" ]]; then
                # More pages exist but we have no cursor to reach them:
                # the TAIL is withheld, not just this page.
                _SEARCH_PAGES_TRUNCATED=1
                _graphql_search_partial_log "$surface" partial_resolution \
                    "page ${_SEARCH_PAGES_TOTAL} returned ${nerr} field errors AND no usable cursor; walk TRUNCATED — every later page withheld this cycle. Reduce MONITOR_GRAPHQL_SEARCH_PAGE_SIZE (now ${page_size})"
            else
                # It was the LAST page: its own issues are withheld, but
                # there is no tail behind it. Do NOT call that truncated
                # — an accurate blast radius is the whole point of these
                # messages.
                _graphql_search_partial_log "$surface" partial_resolution \
                    "final page ${_SEARCH_PAGES_TOTAL} returned ${nerr} field errors; page DISCARDED (no later pages exist, so no tail withheld). Reduce MONITOR_GRAPHQL_SEARCH_PAGE_SIZE (now ${page_size})"
            fi
            break
        fi
        # Same discipline one level down: "no errors" is not "is a search
        # result". An empty or non-envelope body with rc=0 would otherwise
        # count as a healthy page, clear the degradation counter, and read
        # as a recovered surface — a green light for a fetch that returned
        # nothing at all.
        if [[ "$(printf '%s' "$_stdout" | jq -r 'try (.data.search | type) catch "none"' 2>/dev/null)" != "object" ]]; then
            _SEARCH_PAGES_FAILED=$(( _SEARCH_PAGES_FAILED + 1 ))
            _SEARCH_PAGES_TRUNCATED=1
            _graphql_search_partial_log "$surface" malformed_page \
                "page ${_SEARCH_PAGES_TOTAL} carried no .data.search object despite a clean exit; walk TRUNCATED — every later page withheld this cycle"
            break
        fi
        printf '%s' "$_stdout" | jq -c '.' 2>/dev/null >> "$out"
        _SEARCH_PAGES_OK=$(( _SEARCH_PAGES_OK + 1 ))
        hasnext=$(printf '%s' "$_stdout" | jq -r '.data.search.pageInfo.hasNextPage // false' 2>/dev/null)
        cursor=$(printf '%s' "$_stdout" | jq -r '.data.search.pageInfo.endCursor // empty' 2>/dev/null)
        [[ "$hasnext" == "true" && -n "$cursor" ]] || break
    done
    if (( _SEARCH_PAGES_TOTAL >= max_pages )); then
        _SEARCH_PAGES_TRUNCATED=1
        _graphql_search_partial_log "$surface" page_cap \
            "walk stopped at the ${max_pages}-page cap (${page_size}/page); issues past #$(( max_pages * page_size )) in creation order were NOT fetched this cycle"
    fi
    (( _SEARCH_PAGES_OK > 0 ))
}

# Throttled (once per 10 min per surface+reason) WARN for a walk that
# completed only partially. Distinct from `graphql_failure` so a
# coverage gap is never mistaken for a transport hiccup: silent
# truncation reads as "covered everything" when it did not.
_graphql_search_partial_log() {
    local surface="$1" reason="$2" detail="$3"
    [[ -d "${STATE_DIR:-}" ]] || return 0
    local marker="${STATE_DIR}/graphql-partial-last-log-${surface}-${reason}"
    local now last=0
    now=$(date +%s)
    [[ -f "$marker" ]] && last=$(<"$marker")
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last >= 600 )) || return 0
    local iso; iso=$(date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    _ensure_service_log "${STATE_DIR}/watcher-alerts.log"
    printf '[%s] WARN %s graphql_partial_walk reason=%s %s\n' \
        "$iso" "$surface" "$reason" "$detail" \
        >> "${STATE_DIR}/watcher-alerts.log" 2>/dev/null || true
    printf '%s\n' "$now" > "$marker" 2>/dev/null || true
}

_snapshot_issue_comments() {
    local processed_content="$1"
    _graphql_backoff_active issue_comments && return 0
    local _pages
    _pages=$(mktemp)
    _snapshot_search_paged issue_comments '
          query($q: String!, $first: Int!, $after: String) {
            search(type: ISSUE, query: $q, first: $first, after: $after) {
              pageInfo { hasNextPage endCursor }
              nodes {
                ... on Issue {
                  number
                  comments(last: 50) {
                    nodes {
                      databaseId
                      author { login }
                      body
                      reactions(first: 50) {
                        nodes { content user { login } }
                      }
                    }
                  }
                }
              }
            }
          }' \
        "repo:${REPO} is:issue is:open sort:created-asc" "$_pages"
    if (( _SEARCH_PAGES_OK == 0 )); then
        # Every page failed — the surface produced nothing this cycle.
        # `_watcher_handle_graphql_failure` already logged the cause;
        # this is the out-of-band escalation `#595` requires.
        rm -f "$_pages"
        _graphql_note_failure issue_comments total
        return 0
    fi
    if (( _SEARCH_PAGES_FAILED > 0 )); then
        # PARTIAL DELIVERY IS NOT SUCCESS (skeptic req-001). Gate on
        # FAILED, not on truncation: ANY page we could not consume is a
        # set of issues we did not see this cycle, whether or not the
        # walk also stopped early. Calling `_graphql_note_success` here
        # — which the first version did, because some pages had landed —
        # would clear the degradation counter and leave a throttled WARN
        # as the ONLY trace of the withheld issues. That is precisely
        # the log-only invisibility this issue exists to kill,
        # reproduced one level down. A one-off stays quiet; a PERSISTENT
        # one escalates out-of-band like any other failing fetch on the
        # operator channel. `truncated` vs `partial` only changes the
        # message, because the blast radius genuinely differs: a tail of
        # unknown size versus one known page.
        if (( _SEARCH_PAGES_TRUNCATED == 1 )); then
            _graphql_note_failure issue_comments truncated
        else
            _graphql_note_failure issue_comments partial
        fi
    else
        _graphql_note_success issue_comments
    fi
    # Author filter is NOT applied here — `_filter_to_user_author`
    # downstream gates every emit through a single chokepoint
    # (issue #86). EYES/ROCKET and processed-comments dedup stay
    # local; only the author rule moved.
    # jq consumes the page file as a STREAM of JSON documents (one per
    # line), so the per-comment filter below is unchanged from the
    # single-query shape — each page is just another document.
    jq -r --arg login "${USER_LOGIN}" --arg processed "$processed_content" '
        ($processed | split("\n") | map(select(. != ""))) as $ids
        | .data.search.nodes[]?
        | .number as $n
        | .comments.nodes[]?
        | select(([.reactions.nodes[]?
                   | select(.content == "ROCKET"
                            or (.content == "EYES" and (.user.login // "") != $login))]
                  | length) == 0)
        | (.databaseId | tostring) as $cid
        | select(($ids | index("comment:" + $cid)) | not)
        | (.body // "" | gsub("[\n\r\t]+"; " ")) as $b
        | "issue=\($n) id=\(.databaseId) author=\(.author.login)\n  body: "
          + (if ($b | length) > 400 then ($b[0:400] + "…") else $b end)
      ' < "$_pages" 2>/dev/null
    rm -f "$_pages"
}

# PR conversation comments + PR review-thread (inline-on-diff)
# comments. Single GraphQL query covers both: PRs share `comments`
# with issues and additionally expose `reviewThreads` whose comments
# live at repos/{repo}/pulls/{n}/comments in the REST world. The jq
# union emits two object shapes which are routed to "pr=" or
# "pr_review=" headers below.
_snapshot_pr_comments() {
    local processed_content="$1"
    _graphql_backoff_active pr_comments && return 0
    # GraphQL node-count budget. GitHub caps each query at 500,000
    # possible nodes (computed as the product of all `first`/`last`
    # values along the deepest path). The previous shape used
    # `first:100 ⨯ last:50 ⨯ last:50 ⨯ first:50 = 12.5M` for the
    # reviewThreads → comments → reactions chain and silently failed
    # with MAX_NODE_LIMIT_EXCEEDED, suppressed by `2>/dev/null` —
    # which is why the `pr=` / `pr_review=` line shapes never fired
    # in production.
    # New shape: `100 ⨯ 20 ⨯ 20 ⨯ 10 = 400,000` (review path) plus
    # `100 ⨯ 50 ⨯ 10 = 50,000` (top-level path), under the cap and
    # plenty for the EYES/ROCKET filter (reactions/comment rarely
    # exceed a handful; review threads on an open PR rarely exceed
    # ~20).
    local _err _stdout
    _err=$(mktemp)
    if ! _stdout=$(_snapshot_graphql "$_err" api graphql \
        -f query='
          query($q: String!) {
            search(type: ISSUE, query: $q, first: 100) {
              nodes {
                ... on PullRequest {
                  number
                  comments(last: 50) {
                    nodes {
                      databaseId
                      author { login }
                      body
                      reactions(first: 10) {
                        nodes { content user { login } }
                      }
                    }
                  }
                  reviewThreads(last: 20) {
                    nodes {
                      comments(last: 20) {
                        nodes {
                          databaseId
                          author { login }
                          body
                          path
                          reactions(first: 10) {
                            nodes { content user { login } }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }' \
        -f q="repo:${REPO} is:pr is:open"); then
        _watcher_handle_graphql_failure "$_err" pr_comments
        rm -f "$_err"
        return 0
    fi
    rm -f "$_err"
    # Author filter is NOT applied here — `_filter_to_user_author`
    # downstream is the single chokepoint (issue #86).
    printf '%s' "$_stdout" \
    | jq -r --arg login "${USER_LOGIN}" --arg processed "$processed_content" '
        ($processed | split("\n") | map(select(. != ""))) as $ids
        | .data.search.nodes[]? as $node
        | $node.number as $n
        | (
            ($node.comments.nodes[]?         | {kind:"pr",        path:null,  c:.}),
            ($node.reviewThreads.nodes[]?.comments.nodes[]?
                                              | {kind:"pr_review", path:.path, c:.})
          )
        | select(([.c.reactions.nodes[]?
                   | select(.content == "ROCKET"
                            or (.content == "EYES" and (.user.login // "") != $login))]
                  | length) == 0)
        | (.c.databaseId | tostring) as $cid
        | select(($ids | index("comment:" + $cid)) | not)
        | (.c.body // "" | gsub("[\n\r\t]+"; " ")) as $b
        | (if .kind == "pr_review"
           then "pr_review=\($n) id=\(.c.databaseId) author=\(.c.author.login) path=\(.path // "?")"
           else "pr=\($n) id=\(.c.databaseId) author=\(.c.author.login)"
           end)
          + "\n  body: "
          + (if ($b | length) > 400 then ($b[0:400] + "…") else $b end)
      ' 2>/dev/null
}

# NEW open issues authored by USER_LOGIN — surfaces an issue the user
# just opened (with a body but no follow-up comment) which the
# comment-only sources above would miss until someone commented.
# Same EYES/ROCKET filter as comments, but the reactions live on the
# ISSUE itself, not on its comments. The marker pulses are dead
# symmetric: bot posts EYES on the issue when starting work
# (`ng process-issue <n>`), bot posts ROCKET when fully done
# (`ng react-issue <n> rocket`); user can self-rocket from mobile to
# opt out exactly like with comments. The line-shape uses
# `issue_new=<n> id=<n>` so a parser that already looks for `id=<x>`
# Just Works.
_snapshot_new_issues() {
    local processed_content="$1"
    _graphql_backoff_active new_issues && return 0
    local _err _stdout
    _err=$(mktemp)
    if ! _stdout=$(_snapshot_graphql "$_err" api graphql \
        -f query='
          query($q: String!) {
            search(type: ISSUE, query: $q, first: 100) {
              nodes {
                ... on Issue {
                  number
                  author { login }
                  body
                  reactions(first: 100) {
                    nodes { content user { login } }
                  }
                }
              }
            }
          }' \
        -f q="repo:${REPO} is:issue is:open author:${USER_LOGIN}"); then
        _watcher_handle_graphql_failure "$_err" new_issues
        rm -f "$_err"
        return 0
    fi
    rm -f "$_err"
    # Author filter at the GraphQL query layer (`author:${USER_LOGIN}`
    # in the q= string) already restricts the API response; the jq
    # `select(.author.login == $login)` was redundant and removed to
    # keep `_filter_to_user_author` the single chokepoint for the
    # rule (issue #86).
    printf '%s' "$_stdout" \
    | jq -r --arg login "${USER_LOGIN}" --arg processed "$processed_content" '
        ($processed | split("\n") | map(select(. != ""))) as $ids
        | .data.search.nodes[]?
        | select(([.reactions.nodes[]?
                   | select(.content == "ROCKET"
                            or (.content == "EYES" and (.user.login // "") != $login))]
                  | length) == 0)
        | (.number | tostring) as $n
        | select(($ids | index("issue:" + $n)) | not)
        | (.body // "" | gsub("[\n\r\t]+"; " ")) as $b
        | "issue_new=\($n) id=\($n) author=\(.author.login)\n  body: "
          + (if ($b | length) > 400 then ($b[0:400] + "…") else $b end)
      ' 2>/dev/null
}
