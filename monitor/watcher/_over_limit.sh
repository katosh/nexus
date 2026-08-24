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
# EIGHT fields, and it must stay eight. The observation epoch that the emit
# gate depends on (your-org/nexus-code#592) lives in a SIDECAR file,
# `over-limit-observed.tsv`, not in a 9th column — see
# `_over_limit_observation_get`.
#
# `<key>` is `_orchestrator` when the pane is the watcher's TARGET,
# otherwise the window name. `<role>` is `orchestrator` or `worker`.
# All epoch fields are unix seconds.
#
# Public functions:
#
#   _over_limit_reset_at_to_epoch <token> [<now>]
#     Pure parser — a function of (token, now) ONLY; it never consults the
#     wall clock, so it can be pinned to any instant under test. Returns
#     the next occurrence of the stated wall-clock time in the stated
#     timezone, STRICTLY after <now>, and always within 25h of it.
#     Token shapes accepted:
#       "3am_America/Los_Angeles"  → next 3am in LA tz
#       "11pm"                      → next 11pm in caller's tz
#       "midnight_UTC"              → next midnight UTC
#       "unknown" / "" / unparseable / invalid tz / out-of-band result
#                                   → now + safety fallback (6h)
#     Always prints an integer epoch on stdout (return 0).
#
#   _over_limit_record <key> <window> <role> <reset_at_token>
#     Insert-or-refresh a stamp. Preserves first_seen_epoch and
#     attempts across refreshes (so repeated observations of an
#     unchanged suspension don't reset progress through backoff).
#     ALSO preserves reset_epoch + next_attempt_epoch whenever the token
#     is unchanged (your-org/nexus-code#581): the reset instant of an
#     ongoing hold is fixed at first observation. Only a CHANGED token
#     recomputes them — that is the mid-suspension renderer update the
#     recompute was there to serve. Recomputing unconditionally rolled the
#     horizon a day forward at the exact moment the reset landed; see the
#     comment in the function body.
#
#   _over_limit_drop <key>
#     Remove the row, atomically. Silent no-op when row absent.
#
#   _over_limit_load <key>
#     Tab-separated row for <key>, or empty on miss. Use IFS=$'\t' read.
#
#   _over_limit_orchestrator_paused
#     Exit 0 when an `_orchestrator` row exists AND its suspension was
#     OBSERVED within MONITOR_OVER_LIMIT_OBSERVATION_STALENESS_SECONDS;
#     1 otherwise. Used by main.sh's paste-gate to suppress routine emits to a
#     suspended orchestrator (would pile up unread). Archive still runs.
#     Row-existence alone is NOT sufficient (your-org/nexus-code#592) — a row
#     is a prediction, and a stale one silently severs the operator's channel.
#
#   _over_limit_keys
#     One key per line. Caller iterates to dispatch wake checks.
#
#   _over_limit_scan_panes <target_window>
#     Probe the orchestrator pane + every worker pane via pane-state.sh.
#     For each pane returning state=over-limit, _over_limit_record it.
#     Idempotent — re-running on a stable suspension leaves the row's
#     horizon, wake time, first_seen and attempts all untouched. It runs
#     every 60s for the whole of a multi-hour hold, so anything it mutates
#     is mutated hundreds of times; see _over_limit_record.
#
#   _over_limit_process_wakes <target_window>
#     The wake loop. For each stamped row whose next_attempt_epoch ≤
#     now, re-probe. If still over-limit: bump backoff (60s → 120s →
#     240s → cap 300s), increment attempts; at MAX_ATTEMPTS (default
#     4) FAIL OPEN — paste the resume brief anyway and drop the row.
#     The paste is deliberate, not optimistic: a suspended pane never
#     repaints on its own and the hook stamp only clears on a
#     successful turn, so "still reads over-limit" is EXPECTED after
#     a genuine reset; the paste triggers the turn that either
#     confirms recovery (Stop hook clears the stamp) or re-stamps
#     with the current reset time (StopFailure hook). This is the
#     anti-latch guarantee: the hold is bounded by
#     reset_epoch + margin + Σbackoff (≈12 min past reset at
#     defaults), never indefinite. If transitioned out — ANY alive
#     state (idle/busy/empty/user-typing/autosuggest-only AND the
#     refined-idle states working-background/working-self-paced/
#     idle-orphan-async): paste the resume brief and drop the row.
#     An UNRECOGNISED state routes through the same MAX_ATTEMPTS
#     fail-open as over-limit, so NO state can hold the gate forever
#     (skeptic finding, PR #526 round 1). If pane-absent or window
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
#   MONITOR_OVER_LIMIT_MAX_ATTEMPTS           (default 4)
#       Fail OPEN (paste the resume brief + drop the row) after this
#       many still-over-limit wake attempts. Default 4 ≈ 7 min of
#       grace past the reset margin (60+120+240s) before the paste.
#   MONITOR_OVER_LIMIT_OBSERVATION_STALENESS_SECONDS (default 600 = 10 min)
#       How long an OBSERVED over-limit sighting (row field 9) keeps the
#       orchestrator emit gate suppressed. The scan refreshes it every 60s
#       during a genuine hold, so 10 min tolerates ten consecutive missed
#       cycles before the gate opens. This is the liveness cross-check the
#       gate previously lacked entirely (your-org/nexus-code#592): a wrong
#       reset epoch, clock skew, wedged scan or broken probe used to sever
#       the operator↔orchestrator channel indefinitely and in silence. The
#       polarity is deliberate — absent evidence of suspension opens the
#       gate. Emitting into a live pane is cheap; withholding is not.
#   MONITOR_OVER_LIMIT_SUPPRESSION_ALERT_SECONDS     (default 900 = 15 min)
#       How long a hold must last before the FIRST out-of-band announcement
#       that the orchestrator's emit channel is being withheld.
#   MONITOR_OVER_LIMIT_SUPPRESSION_REMINDER_SECONDS  (default 3600 = 1h)
#       Cadence of the reminders after that first announcement. Separate from
#       the announcement delay on purpose: a legitimate 5h hold fired 20
#       critical-class bells when both used the same 15-min interval, which
#       trains the operator to ignore exactly the signal this exists to send.
#   MONITOR_OVER_LIMIT_MAX_HOLD_SECONDS       (default 90000 = 25h)
#       Absolute per-row hold ceiling. A row older than this
#       (now - first_seen) fails OPEN regardless of pane state or
#       probe outcome — the belt-and-suspenders that bounds EVERY
#       wake path, including a persistently-failing pane-state probe.
#       Must exceed the longest legitimate reset horizon (24h).
#
# Logger contract: callers may set `_OVER_LIMIT_LOG_FN` to the name of
# a function that takes one string arg. Default is a noop. Tests pin a
# capturing impl; main.sh wires it to the watcher's `log` helper.
#
# Paster contract: callers may set `_OVER_LIMIT_PASTE_FN` to a function
# accepting `<window> <body_file>`. Default is noop. Tests pin a
# capturing impl; main.sh wires it to `paste_with_retry`.
#
# Alert contract: callers may set `_OVER_LIMIT_ALERT_FN` to a function taking
# one string. Default is a noop. main.sh wires it to `_watcher_alert`, whose
# whole premise matches this case exactly — "the orchestrator-paste channel may
# itself be the thing that is broken", so it reports out-of-band (alerts log +
# sandbox-notify), not through the channel being suppressed.

_OVER_LIMIT_LOG_FN="${_OVER_LIMIT_LOG_FN:-_over_limit_log_noop}"
_OVER_LIMIT_PASTE_FN="${_OVER_LIMIT_PASTE_FN:-_over_limit_paste_noop}"
_OVER_LIMIT_ALERT_FN="${_OVER_LIMIT_ALERT_FN:-_over_limit_alert_noop}"

_over_limit_log_noop() { :; }
_over_limit_paste_noop() { return 0; }
_over_limit_alert_noop() { :; }

_over_limit_state_path() {
    printf '%s/over-limit-state.tsv' "${STATE_DIR:-.}"
}

# ---- observation sidecar (your-org/nexus-code#592) ------------------------
#
# `<key>\t<epoch>` — when a scan last OBSERVED that pane rendering the
# over-limit notice. Distinct in kind from every epoch in the row file, which
# are predictions or bookkeeping; this one is evidence, and it is what the
# emit-suppression gate trusts.
#
# WHY A SIDECAR RATHER THAN A 9TH COLUMN. The row file survives restarts and
# version skew — `_version_restart.sh` exists precisely because the watcher can
# be mid-transition — so the format has to tolerate being read by code that
# predates it. It does not: an older watcher reads a row with
# `IFS=$'\t' read -r ... attempts`, and the trailing variable absorbs the
# remainder, so `attempts` becomes `0<TAB><epoch>` and the wake loop's
# `$(( attempts + 1 ))` dies with `bad math expression`. That converts a
# routine rollback into an outage of the very wake path this module is.
# Verified, not assumed. A sidecar is invisible to old code by construction.
#
# The reverse direction is safe by the gate's own polarity: new code finding no
# sidecar (rolled forward onto an old state dir) sees no observation, treats it
# as stale, and OPENS the gate. Absent evidence is not evidence.
#
# It is also why the write asymmetry is structural rather than a discipline:
# `_over_limit_record` is the only writer of this file, and every other mutator
# touches the row file instead, so no future call site can accidentally forge
# or clobber an observation.
_over_limit_observation_path() {
    printf '%s/over-limit-observed.tsv' "${STATE_DIR:-.}"
}

# Epoch, or empty when never observed / file absent.
_over_limit_observation_get() {
    local key="$1" path
    path=$(_over_limit_observation_path)
    [[ -f "$path" ]] || return 0
    awk -F'\t' -v k="$key" '$1 == k && $2 ~ /^[0-9]+$/ { print $2; exit }' "$path"
}

_over_limit_observation_set() {
    local key="$1" epoch="$2" path tmp
    [[ -n "$key" && "$epoch" =~ ^[0-9]+$ ]] || return 0
    path=$(_over_limit_observation_path)
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    tmp=$(mktemp "${path}.XXXXXX") || return 0
    [[ -f "$path" ]] && awk -F'\t' -v k="$key" '$1 != k' "$path" > "$tmp"
    printf '%s\t%s\n' "$key" "$epoch" >> "$tmp"
    mv "$tmp" "$path"
}

_over_limit_observation_drop() {
    local key="$1" path tmp
    [[ -n "$key" ]] || return 0
    path=$(_over_limit_observation_path)
    [[ -f "$path" ]] || return 0
    tmp=$(mktemp "${path}.XXXXXX") || return 0
    awk -F'\t' -v k="$key" '$1 != k' "$path" > "$tmp"
    if [[ -s "$tmp" ]]; then mv "$tmp" "$path"; else rm -f "$path" "$tmp"; fi
}

# Off-time log (operator ask, your-nexus#275): a human-readable,
# consolidated record of what the watcher HELD while the orchestrator was
# over-limit. main.sh appends one line per suppressed emit; the resume
# brief (the special first flushed emit) points the operator here so they
# can see exactly what they missed during the off-time. Freshly started at
# the top of each orchestrator hold (`_over_limit_held_log_start`), so it
# always describes the most-recent incident; the per-emit full bodies stay
# archived under monitor/.state/diffs/ as the permanent record.
_over_limit_held_log_path() {
    printf '%s/over-limit-held.log' "${STATE_DIR:-.}"
}

# Start (truncate + header) the off-time log for a new orchestrator hold.
# Called from _over_limit_record when a fresh `_orchestrator` row appears.
_over_limit_held_log_start() {
    local t0="$1" path pretty
    path=$(_over_limit_held_log_path)
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    pretty=$(date -d "@$t0" -Is 2>/dev/null || printf '%s' "$t0")
    printf '# over-limit off-time log — orchestrator hold began %s (epoch %s)\n# one line per emit the watcher held while the pane was over-limit; full bodies under monitor/.state/diffs/\n' \
        "$pretty" "$t0" > "$path" 2>/dev/null || true
    # New hold ⇒ new alert clock, so the first escalation is measured from
    # THIS hold's start rather than inheriting the previous incident's stamp.
    rm -f "$(_over_limit_alert_stamp_path)" 2>/dev/null || true
}

# Where the last suppression ALERT was fired (epoch). Reset at hold start.
_over_limit_alert_stamp_path() {
    printf '%s/over-limit-alert.stamp' "${STATE_DIR:-.}"
}

# Append a held-emit record to the off-time log. Called by main.sh's
# over-limit-suppressed emit branch. Best-effort; never fails the caller.
#
# ALSO makes the suppression VISIBLE (your-org/nexus-code#592). Withholding the
# operator's channel was previously recorded only in watcher.log, which is
# exactly why a 15-hour blackout passed unnoticed: the watcher dutifully logged
# "emit paste suppressed" once per ~50s cycle into a file no human reads, while
# an operator comment and four spawn requests went undelivered. A condition
# that mutes operator communication must announce itself out-of-band. So once
# a hold outlives MONITOR_OVER_LIMIT_SUPPRESSION_ALERT_SECONDS, escalate
# through the injected alert channel (main.sh wires `_watcher_alert`: alerts
# log + watcher log + sandbox-notify), and keep re-announcing at that interval
# for as long as it continues. Rate-limited via a stamp file so the ~50s emit
# cadence cannot turn this into a notification storm.
_over_limit_record_held() {
    local archive="$1" reason="$2" path ts
    path=$(_over_limit_held_log_path)
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    ts=$(date -Is 2>/dev/null || date 2>/dev/null || printf '?')
    printf '%s\theld\tarchive=%s\treason=%s\n' "$ts" "$archive" "$reason" \
        >> "$path" 2>/dev/null || true
    _over_limit_maybe_alert_suppression
}

# ONE announcement per hold, then periodic reminders — not an alert every
# interval. A legitimate 5h hold used to fire 20 critical-class bells, which is
# precisely how an operator learns to ignore the announcement, defeating the
# visibility this exists to provide. At the defaults a 5h hold now fires one
# announcement plus four hourly reminders.
#
# The text describes what OBTAINS; it does not assert a cause. The earlier
# wording told the operator to suspect a stale stamp — which, since #592, is
# false BY CONSTRUCTION at the moment this fires: the gate only suppresses on a
# fresh observation, so anything alerting here is a live hold with the pane
# genuinely rendering the notice. Sending them hunting for a stale stamp that
# cannot be there is worse than saying nothing, because it trains the wrong
# reflex for the first occurrence that is real.
_over_limit_maybe_alert_suppression() {
    local first_delay reminder stamp_path last now row first_seen held_n
    local token observed kind since_obs
    first_delay="${MONITOR_OVER_LIMIT_SUPPRESSION_ALERT_SECONDS:-900}"
    reminder="${MONITOR_OVER_LIMIT_SUPPRESSION_REMINDER_SECONDS:-3600}"
    [[ "$first_delay" =~ ^[0-9]+$ ]] || first_delay=900
    [[ "$reminder"    =~ ^[0-9]+$ ]] || reminder=3600
    (( first_delay > 0 )) || return 0
    now=$(date +%s)
    row=$(_over_limit_load "_orchestrator") || return 0
    IFS=$'\t' read -r _ _ _ token _ first_seen _ _ <<<"$row"
    [[ "$first_seen" =~ ^[0-9]+$ ]] || return 0
    (( now - first_seen >= first_delay )) || return 0
    stamp_path=$(_over_limit_alert_stamp_path)
    last=$(cat "$stamp_path" 2>/dev/null)
    if [[ "$last" =~ ^[0-9]+$ ]]; then
        # Already announced — only a reminder is due, and only on the slower
        # cadence.
        (( now - last >= reminder )) || return 0
        kind="continues"
    else
        kind="began"
    fi
    printf '%s' "$now" > "$stamp_path" 2>/dev/null || true
    # `grep -c` prints `0` on no match AND exits 1; `|| printf '0'` appended a
    # second one, rendering "(0\n0 emits held)" in the operator emit (#725).
    held_n=$(grep -c $'\theld\t' "$(_over_limit_held_log_path)" 2>/dev/null) || held_n=0
    [[ "$held_n" =~ ^[0-9]+$ ]] || held_n=0
    observed=$(_over_limit_observation_get "_orchestrator")
    if [[ "$observed" =~ ^[0-9]+$ ]]; then
        since_obs="$(( now - observed ))s ago"
    else
        since_obs="not recorded"
    fi
    "$_OVER_LIMIT_ALERT_FN" \
        "over-limit hold ${kind}: the orchestrator's emit channel has been suppressed for $(( (now - first_seen) / 60 )) min (${held_n} emits held). The pane is still rendering the over-limit notice — last observed ${since_obs} — so this is a live hold, not a stale stamp; the reset it states is '${token}'. Held emits are archived and summarised on resume: $(_over_limit_held_log_path)."
}

_over_limit_sanitize_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'
}

# Is this a usable IANA timezone name? (your-org/nexus-code#574)
#
# The point is to catch what GNU `date` will NOT: an invalid TZ does not make
# it fail — it silently falls back to UTC and still exits 0. A malformed token
# therefore produces a WRONG epoch that passes every downstream check, because
# the only guard is `[[ $epoch =~ ^[0-9]+$ ]]` and a wrong answer is just as
# numeric as a right one. Measured skew from the live token: 17 hours, rc=0.
#
# Charset first: a real zone name is a restricted alphabet, so control
# characters, quotes, spaces and ANSI escapes are rejected outright — that
# alone kills the observed token. Then require it to actually resolve. If the
# host has no zoneinfo tree at all (minimal containers), fall back to accepting
# any charset-valid name rather than rejecting every zone on the box.
_over_limit_valid_tz() {   # $1 = candidate zone
    local tz="$1"
    [[ -n "$tz" ]] || return 1
    [[ "$tz" =~ ^[A-Za-z0-9_+/-]+$ ]] || return 1
    case "$tz" in UTC|GMT|Z|UCT|Universal|Zulu) return 0 ;; esac
    [[ -d /usr/share/zoneinfo ]] || return 0
    [[ -f "/usr/share/zoneinfo/$tz" ]]
}

# Run `date` in an optional zone without bleeding TZ into the caller.
# Empty zone → the caller's own zone (the terse `11pm` token shape).
_over_limit_date_in_zone() {   # <zone|""> <date-args...>
    local zone="$1"; shift
    if [[ -n "$zone" ]]; then
        TZ="$zone" date "$@"
    else
        date "$@"
    fi
}

# Convert a reset_at token to a unix epoch. See header for shape rules.
# Always prints an integer epoch; never fails the pipeline.
#
# PURE in (token, now): the calendar date is anchored EXPLICITLY to `now`
# in the target zone, never to `date`'s idea of "today"
# (your-org/nexus-code#581). The old `date -d "<time> today"` form read the
# real wall clock regardless of the `now` argument, which had two costs.
# It made the function impossible to pin at a boundary instant — so every
# test asserted only "some epoch within 26h" and the ratchet below sailed
# through review. And it is the primitive the ratchet was built on: "today,
# else tomorrow" is memoryless, so evaluating it one second before vs. one
# second after the stated time yields answers a full day apart.
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
    # Sanitise at the CONSUMER (your-org/nexus-code#574). Every producer
    # channel converges here, so this is the one place a fix covers all of
    # them — including the third producer that filed report could not locate.
    # Control characters and quotes are exactly what rode in on the live token.
    time_part=$(printf '%s' "$time_part" | tr -d '\000-\037\177"'"'")
    tz_part=$(printf '%s' "$tz_part"   | tr -d '\000-\037\177"'"'")
    # An unusable zone must engage the safety net, NOT silently resolve in the
    # wrong zone. This is the branch that never fired before.
    if [[ -n "$tz_part" ]] && ! _over_limit_valid_tz "$tz_part"; then
        printf '%d' "$fallback"; return 0
    fi
    # GNU date accepts "3am" / "11pm" / "3:30am" but NOT the bare words
    # `midnight` / `noon` (coreutils 8.28 rejects both "midnight today" and
    # "midnight 2026-07-29"). The header has advertised `midnight_UTC` since
    # #87 while that shape silently took the 6h fallback; normalising here
    # makes the documented token actually resolve.
    case "$time_part" in
        [Mm]idnight) time_part="00:00" ;;
        [Nn]oon)     time_part="12:00" ;;
    esac
    # Anchor to the calendar date at `now` IN THE TARGET ZONE.
    local anchor
    anchor=$(_over_limit_date_in_zone "$tz_part" -d "@$now" +%F 2>/dev/null)
    [[ -n "$anchor" ]] || { printf '%d' "$fallback"; return 0; }
    epoch=$(_over_limit_date_in_zone "$tz_part" -d "$time_part $anchor" +%s 2>/dev/null)
    [[ "$epoch" =~ ^[0-9]+$ ]] || { printf '%d' "$fallback"; return 0; }
    # Strictly after `now`: if the stated time has already passed today,
    # the next occurrence is tomorrow. Re-resolve against the next calendar
    # DAY rather than adding 86400 — across a DST transition the flat
    # addition lands an hour off the stated wall clock (verified: 3am PST
    # + 86400s = 4am PDT).
    if (( epoch <= now )); then
        local anchor_next
        anchor_next=$(_over_limit_date_in_zone "$tz_part" -d "$anchor + 1 day" +%F 2>/dev/null)
        [[ -n "$anchor_next" ]] || { printf '%d' "$fallback"; return 0; }
        epoch=$(_over_limit_date_in_zone "$tz_part" -d "$time_part $anchor_next" +%s 2>/dev/null)
        [[ "$epoch" =~ ^[0-9]+$ ]] || { printf '%d' "$fallback"; return 0; }
    fi
    # Invariant: the next occurrence of a DATE-LESS wall-clock time is always
    # within 24h of now (25h allows the DST-long day). A result outside that
    # band is an arithmetic error, not a real reset horizon — take the safety
    # net rather than park a hold a day out. This is the standing assertion
    # that would have caught #581 at the source.
    if (( epoch <= now || epoch > now + 90000 )); then
        printf '%d' "$fallback"; return 0
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

# Is the orchestrator's emit channel suppressed?
#
# The gate is NOT "a row exists" (your-org/nexus-code#592). A row is a
# PREDICTION — it says a pane was suspended and names a computed instant. The
# suppression it drives is total: main.sh composes each emit, archives it, then
# refuses to paste. So a stale row severs operator→orchestrator communication
# entirely, in silence, with the orchestrator visibly alive and heartbeating.
# Measured 2026-07-29: "emit paste suppressed: orchestrator over-limit" logged
# once per ~50s cycle for over FIFTEEN HOURS after the quota had actually
# reset, withholding an operator comment and four spawn-skeptic requests. That
# is a strictly worse outage than the late wake that triggered it.
#
# So the gate additionally requires the suspension to have been OBSERVED
# recently. The observation epoch lives in the sidecar and is stamped only by
# `_over_limit_record`, i.e. only when a scan actually saw the pane render the
# over-limit notice. During a genuine hold the 60s scan refreshes it
# continuously and the gate stays closed. The moment observation stops — pane
# recovered, scan wedged, probe broken, epoch miscomputed — it goes stale and
# the gate OPENS. Emits resuming into a live pane cost nothing; withholding
# them costs the nexus.
#
# A state dir written before the sidecar existed has no entry → stale → OPEN.
# Correct polarity for an upgrade, and the next scan stamps it.
_over_limit_orchestrator_paused() {
    local path staleness now observed
    path=$(_over_limit_state_path)
    [[ -f "$path" ]] || return 1
    grep -q $'^_orchestrator\t' "$path" 2>/dev/null || return 1
    observed=$(_over_limit_observation_get "_orchestrator")
    [[ "$observed" =~ ^[0-9]+$ ]] || return 1
    staleness="${MONITOR_OVER_LIMIT_OBSERVATION_STALENESS_SECONDS:-600}"
    [[ "$staleness" =~ ^[0-9]+$ ]] || staleness=600
    now=$(date +%s)
    (( now - observed <= staleness ))
}

# Atomic rewrite: read all rows, replace any with matching key, append
# the new row, rename into place. Deliberately EIGHT fields — see the
# observation sidecar above for why the observation epoch is not a 9th.
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
    local now wake_margin first_seen attempts
    now=$(date +%s)
    wake_margin="${MONITOR_OVER_LIMIT_WAKE_MARGIN_SECONDS:-300}"
    [[ "$wake_margin" =~ ^[0-9]+$ ]] || wake_margin=300
    first_seen=$now
    attempts=0
    # Empty ⇒ "compute fresh below". A refresh of an UNCHANGED hold carries
    # both forward from the existing row instead.
    local reset_epoch="" next_attempt=""
    # Anchor for a fresh computation. `now` for a new row or a token the
    # renderer has just changed; first_seen when HEALING a row (below), since
    # that is when the banner we are re-deriving from was actually observed.
    local anchor_now="$now"
    local existing _
    if existing=$(_over_limit_load "$key"); then
        local e_token e_reset e_first e_next e_attempts
        IFS=$'\t' read -r _ _ _ e_token e_reset e_first e_next e_attempts <<<"$existing"
        [[ "$e_first" =~ ^[0-9]+$ ]] && first_seen="$e_first"
        [[ "$e_attempts" =~ ^[0-9]+$ ]] && attempts="$e_attempts"
        # THE RATCHET FIX (your-org/nexus-code#581). An ongoing hold KEEPS the
        # reset instant it was first given. Recomputing it on every refresh is
        # what broke the wake loop: the token states a wall-clock time with NO
        # DATE, so the parser can only answer "today's occurrence, else
        # tomorrow's" — memoryless. `_over_limit_scan_panes` refreshes every
        # 60s and a suspended pane keeps reading over-limit (the banner never
        # repaints on its own), so at the instant the reset arrives the very
        # next scan re-resolves the same token to TOMORROW and rewrites
        # next_attempt with it. The wake was due at reset+5min; the refresh
        # moved it a full day out ~4 minutes before it could fire, every time.
        # Observed 2026-07-28: four panes (orchestrator + three workers)
        # parked at 2026-07-30 03:00 with attempts=0 — not one wake attempt
        # was ever due. Carrying next_attempt forward also stops the refresh
        # from wiping the wake loop's exponential-backoff progress.
        # Only a CHANGED token — the renderer now states a different reset
        # time — may move the horizon, which is the mid-suspension update the
        # original recompute existed to serve.
        if [[ "$e_token" == "$token" ]] \
            && [[ "$e_reset" =~ ^[0-9]+$ ]] && [[ "$e_next" =~ ^[0-9]+$ ]]; then
            # SELF-HEAL, by EXACT re-derivation (skeptic finding B on #582).
            #
            # Post-fix the horizon is computed exactly once, at first
            # observation, so a healthy row satisfies the invariant
            #     reset_epoch == parse(token, first_seen)
            # and a row the pre-fix code ratcheted does not. Comparing against
            # that re-derivation is therefore an exact test.
            #
            # It replaces a `> first_seen + 90000` threshold, which could not
            # discriminate: legitimate horizons occupy (first, first+90000] and
            # ratcheted ones (first+86400, first+176400], so a row stamped less
            # than an hour before its reset ratcheted into the overlap and was
            # preserved verbatim — stalling a further ~24h past the upgrade.
            #
            # Anchor at FIRST_SEEN, not `now`: the banner was observed at
            # first_seen, so that reproduces the horizon the row should have
            # had. Re-deriving at `now` would just reproduce the ratchet, since
            # the reset has by then passed and `now` answers "tomorrow" again.
            #
            # Residual (accepted, narrow): if the renderer CHANGED the token
            # mid-hold to a time that had already passed between first_seen and
            # the change, the re-derivation disagrees and this heals
            # spuriously. Consequence is an early wake, not a stall — the
            # fail-open direction — and it self-terminates at MAX_ATTEMPTS.
            # Discriminating it exactly would need the anchor stored as its own
            # column; not worth a second schema change for a documented edge.
            local expected_reset
            expected_reset=$(_over_limit_reset_at_to_epoch "$token" "$e_first")
            if [[ "$e_reset" != "$expected_reset" ]]; then
                anchor_now="$e_first"
                "$_OVER_LIMIT_LOG_FN" \
                    "over-limit: '${window}' (key=${key}) horizon ${e_reset} disagrees with the re-derivation from first_seen (${expected_reset}); healing"
            else
                reset_epoch="$e_reset"
                next_attempt="$e_next"
            fi
        fi
    elif [[ "$key" == "_orchestrator" ]]; then
        # Fresh orchestrator hold (no prior row) → start the off-time log
        # so it describes THIS incident from the moment emits begin to be
        # held. Refreshes of an existing hold leave it untouched.
        _over_limit_held_log_start "$now"
    fi
    if [[ -z "$reset_epoch" ]]; then
        reset_epoch=$(_over_limit_reset_at_to_epoch "$token" "$anchor_now")
    fi
    if [[ -z "$next_attempt" ]]; then
        next_attempt=$(( reset_epoch + wake_margin ))
        # Don't push next_attempt into the past if we've been sitting on a
        # stamp longer than the reset window suggested. Lower bound is now.
        #
        # NOTE (skeptic finding C on #582): this clamp means a HEALED row does
        # not fire immediately — its re-derived horizon is already past, so it
        # lands here and fires at now + wake_margin (300s). That is the
        # intended behaviour, not an oversight: it keeps the margin's
        # clock-skew allowance and avoids a thundering wake the instant the
        # watcher restarts. After a stall measured in hours, 300s is noise.
        (( next_attempt > now )) || next_attempt=$(( now + wake_margin ))
    fi
    _over_limit_write_row "$key" "$window" "$role" "$token" \
        "$reset_epoch" "$first_seen" "$next_attempt" "$attempts"
    # `now` IS the observation: _over_limit_record is only ever reached from a
    # scan that just saw this pane render the over-limit notice. This is the
    # ONLY writer of the sidecar. Because every other mutator touches the row
    # file and not this one, "backing off is not an observation" and "reconcile
    # must not forge an observation" are STRUCTURAL rather than a discipline
    # each call site has to remember.
    _over_limit_observation_set "$key" "$now"
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
    # Keep the sidecar in step so it cannot accumulate entries for keys that
    # no longer exist, and so a re-stamped key starts from a fresh observation.
    _over_limit_observation_drop "$key"
}

# Probe one pane via pane-state.sh; emit `state reset_at` on stdout
# (space-separated). Empty stdout on resolver failure.
#
# Shared-recording consumer (your-org/nexus-code#562): serves the
# current sweep loop's recording of this window when `_pane_cache.sh`
# is loaded and the entry is fresh, instead of re-forking
# pane-state.sh; a direct fork's result is recorded for reuse.
# Optional $2 = expected window name (reused-index guard). Worst-case
# recording staleness (cache TTL, default 90s) is far inside the
# over-limit signal's own time constants (a limit episode lasts
# hours; the scan cadence is 60s). Fail-open on every cache condition.
_over_limit_probe_pane() {
    local window_arg="$1" expected_name="${2:-}"
    local line state reset_at
    if declare -F _pane_cache_read >/dev/null 2>&1; then
        line=$(_pane_cache_read "$window_arg" "$expected_name") || line=""
    else
        line=""
    fi
    if [[ -z "$line" ]]; then
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
        line=$("$pane_state_script" "${hb_args[@]}" "$window_arg" 2>/dev/null) || return 0
        if [[ -n "$line" ]] && declare -F _pane_cache_write >/dev/null 2>&1; then
            _pane_cache_write "$window_arg" "$line"
        fi
    fi
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
    # The resolver's rc is deliberately NOT split here (contrast the wake
    # path below, your-org/nexus-code#699): this arm's failure action is to
    # do NOTHING — no stamp recorded, no state dropped — which is already
    # the safe verdict for both "absent" and "could not look". Empty stdout
    # covers both. Do not "fix" this into a drop.
    local orch_index
    orch_index=$(_over_limit_resolve_window_index "$target" || true)
    if [[ -n "$orch_index" ]]; then
        probe=$(_over_limit_probe_pane "$orch_index" "$target")
        if [[ -n "$probe" ]]; then
            read -r state reset_at <<<"$probe"
            if [[ "$state" == "over-limit" ]]; then
                _over_limit_record "_orchestrator" "$target" \
                    "orchestrator" "$reset_at"
            else
                _over_limit_reconcile_alive "_orchestrator" "$state"
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
            probe=$(_over_limit_probe_pane "$probe_target" "$name")
            [[ -n "$probe" ]] || continue
            read -r state reset_at <<<"$probe"
            if [[ "$state" == "over-limit" ]]; then
                _over_limit_record "$name" "$name" "worker" "$reset_at"
            else
                _over_limit_reconcile_alive "$name" "$state"
            fi
        done < <(_idle_list_worker_windows)
    fi
}

# RECONCILE ON OBSERVED LIVENESS (your-org/nexus-code#592).
#
# The scan probes every pane every 60s and, until now, threw the answer away
# unless it read `over-limit`. That is the whole bug behind the 15-hour emit
# blackout: resumption was detected ONLY by the wake loop, which is gated on
# `now >= next_attempt`, so a row parked at a miscomputed instant kept the
# suppression gate shut while the scan watched a demonstrably live pane every
# minute and said nothing.
#
# Correct division of labour: the epoch decides when to start NUDGING a pane
# that still looks suspended; only OBSERVATION decides when to stop
# SUPPRESSING. So when a stamped pane probes as anything other than
# `over-limit`, expedite its row — set next_attempt to now — and let the wake
# loop (5s cadence) run its existing, tested resumption path on the next tick:
# re-probe, paste the right brief, stamp the machine-input ledger for a worker,
# drop the row. Expediting rather than duplicating that logic keeps one
# resumption implementation.
#
# `absent`/`blocked` are deliberately included: those mean the pane is gone,
# and the wake loop's handler for them is to drop the row — which is exactly
# the reconciliation wanted. An empty probe never reaches here (the caller
# skips it), so a broken pane-state.sh cannot expedite anything.
_over_limit_reconcile_alive() {
    local key_raw="$1" state="$2"
    [[ -n "$key_raw" && -n "$state" ]] || return 0
    local key row
    key=$(_over_limit_sanitize_key "$key_raw")
    row=$(_over_limit_load "$key") || return 0
    [[ -n "$row" ]] || return 0
    local r_key window role token reset_epoch first_seen next_attempt attempts
    IFS=$'\t' read -r r_key window role token reset_epoch first_seen next_attempt \
        attempts <<<"$row"
    local now
    now=$(date +%s)
    # Already due — the wake loop will handle it this tick; don't churn the file.
    (( next_attempt > now )) || return 0
    "$_OVER_LIMIT_LOG_FN" \
        "over-limit: '${window}' (key=${key}) observed alive (state=${state}) while stamped with a wake $(( next_attempt - now ))s out; expediting to now"
    _over_limit_write_row "$key" "$window" "$role" "$token" \
        "$reset_epoch" "$first_seen" "$now" "$attempts"
}

# Resolve a tmux window name to its index (for pane-state.sh).
#
# THREE-STATE, same contract as monitor/_tmux-window.sh's resolvers
# (your-org/nexus-code#699):
#
#   rc 0  index on stdout — present
#   rc 1  tmux answered, no window by that name — genuinely absent
#   rc 3  could NOT look: no tmux binary, `list-windows` failed, or a row
#         came back in a shape we cannot parse
#
# It used to `return 0` with EMPTY stdout for all three, and the wake
# path below read empty as absence and DROPPED the over-limit stamp,
# logging the word "absent" about a window it had never observed. A
# stamp dropped for a window that is actually still frozen means the
# watcher stops holding emits and starts piling them into a dead pane —
# the state is gone and nothing re-derives it.
#
# Deliberately NOT delegating to `resolve_window_index`: _over_limit.sh
# is sourced standalone by four test suites that do not source
# _tmux-window.sh, so a cross-file dependency here would make the helper
# undefined in exactly the hermetic paths that cover it. The contract is
# shared; the implementation is local on purpose — and the manifest arm of
# test-tmux-window-resolver.sh is what keeps the two from drifting.
#
# THE ROW-SHAPE BELT (your-org/nexus-code#701 item C). `#699` gave
# `_tmux_window_check_row` to resolve_window_id/_index and NOT to this
# function, which the same commit rewrote and declared to carry "the same
# contract". With the delimiter defeated the twin answered rc 3 and this one
# answered rc 1 — laundered to ABSENT, missing the `probe_rc >= 2` hold arm
# below, dropping the stamp for a window never observed. That is the `#699`
# defect verbatim, left inside `#699`'s own fix. A row we cannot parse is not
# an answer; it is the absence of one.
_over_limit_resolve_window_index() {
    local name="$1" out rc=0 row rname ridx
    [[ -n "$name" ]] || return 1
    command -v tmux >/dev/null 2>&1 || return 3
    out=$(tmux list-windows -F '#{window_name}|#{window_index}' 2>/dev/null) || rc=$?
    (( rc == 0 )) || return 3
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        rname="${row%|*}"; ridx="${row##*|}"
        if [[ "$row" != *'|'* || -z "$rname" || ! "$ridx" =~ ^[0-9]+$ ]]; then
            return 3
        fi
        [[ "$rname" == "$name" ]] || continue
        printf '%s' "$ridx"
        return 0
    done <<<"$out"
    return 1
}

# Build the SPECIAL first flushed emit that lands in the orchestrator's
# input box when the watcher detects resumption. Per the operator ask
# (your-nexus#275) it explains, in order: (a) what happened — the pane
# was over-limit and the watcher HELD its emits rather than piling them
# into a frozen pane; (b) the state now — limit reset, back online, this
# is the first emit since; (c) where to find a log of the off-time (the
# consolidated held-emit log + the per-emit diff archives). Normal
# state-change emits resume after this one. Arguments:
#   $1  reset_at token (display only)
#   $2  duration seconds (display only — formatted to Hh:MMm:SSs)
#   $3  optional: comma-separated list of currently-stamped worker windows
#   $4  optional: first_seen epoch (the hold start T0); when present the
#       brief prints the explicit T0→reset window
_over_limit_compose_resume_brief() {
    local token="$1" duration="$2" workers="$3" first_seen="${4:-}"
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
    local t0_pretty=""
    if [[ "$first_seen" =~ ^[0-9]+$ ]]; then
        t0_pretty=$(date -d "@$first_seen" -Is 2>/dev/null || printf '%s' "$first_seen")
    fi
    local held_log
    held_log=$(_over_limit_held_log_path)
    {
        printf '=== WATCHER: USAGE-LIMIT RECOVERY (read first) ===\n'
        printf '\n'
        printf 'WHAT HAPPENED: this session hit its usage limit and could not\n'
        printf 'complete turns. The watcher detected the over-limit status and HELD\n'
        printf 'its emits (state-change and eligible-comment pastes) instead of\n'
        printf 'piling them into a frozen pane.\n'
        if [[ -n "$t0_pretty" ]]; then
            printf 'The hold ran from %s until the limit reset (%s) — %s.\n' \
                "$t0_pretty" "$pretty" "$pretty_dur"
        else
            printf 'The hold lasted %s (limit reset: %s).\n' "$pretty_dur" "$pretty"
        fi
        printf '\n'
        printf 'STATE NOW: the limit has reset and you are back online. This is the\n'
        printf 'FIRST emit since recovery; normal state-change emits resume after it.\n'
        if [[ -n "$workers" ]]; then
            printf 'Workers still queued for wake: %s (the watcher pastes a resume\n' "$workers"
            printf 'directive into each as it transitions out).\n'
        else
            printf 'No workers were suspended in this window.\n'
        fi
        printf '\n'
        printf 'LOG OF THE OFF-TIME: the emits held while you were inert are recorded\n'
        printf 'at %s\n' "$held_log"
        printf '(one line per held emit); each full body is archived under\n'
        printf 'monitor/.state/diffs/, and current canonical state is in\n'
        printf 'monitor/.state/last-snapshot.txt. Review the held log to see what you\n'
        printf 'missed, then proceed with bootstrap.sh as on any resumption.\n'
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

# Fail-open terminal: compose the appropriate brief, paste it (best
# effort — the point is to break the hold, so a paste failure must not
# keep the row alive), and DROP the row so the emit gate reopens. Used
# both when a genuinely-over-limit pane exhausts its wake attempts and
# when an unrecognised pane state must not be allowed to hold the gate
# forever. Orchestrator gets the special resume brief (with T0); workers
# get the terse brief + a machine-input ledger stamp (stamp-before-paste,
# #293).
_over_limit_failopen() {
    local key="$1" window="$2" role="$3" token="$4" first_seen="$5" now="$6"
    local duration=$(( now - first_seen ))
    (( duration >= 0 )) || duration=0
    local body
    body=$(mktemp)
    if [[ "$role" == "orchestrator" ]]; then
        _over_limit_compose_resume_brief \
            "$token" "$duration" "$(_over_limit_worker_summary)" "$first_seen" > "$body"
    else
        _over_limit_compose_worker_brief "$token" > "$body"
        _machine_input_stamp "$window" "over-limit-wake"
    fi
    "$_OVER_LIMIT_PASTE_FN" "$window" "$body" || true
    rm -f "$body"
    _over_limit_drop "$key"
}

# "Still suspended" step: increment attempts, and at MAX_ATTEMPTS FAIL
# OPEN (paste + drop) instead of backing off forever. This is the
# anti-latch guarantee — EVERY non-resumption branch routes through here
# so no pane state can suppress emits indefinitely. `state_label` is for
# the log line only. Returns 0.
_over_limit_bump_or_failopen() {
    local key="$1" window="$2" role="$3" token="$4" reset_epoch="$5" \
          first_seen="$6" attempts="$7" now="$8" state_label="$9"
    local new_attempts=$(( attempts + 1 ))
    local max_attempts="${MONITOR_OVER_LIMIT_MAX_ATTEMPTS:-4}"
    [[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=4
    if (( new_attempts >= max_attempts )); then
        # A bare drop here would be a latch: the next _over_limit_scan_panes
        # re-stamps the still-suspended-reading pane with a FRESH reset
        # horizon, so "drop and wait" silently re-arms the suppression
        # forever (the pane never changes precisely BECAUSE we stopped
        # pasting). The wake paste is the probe that breaks the cycle — if
        # the limit genuinely reset the pasted brief lands and the pane
        # recovers; if it is truly still limited, the turn fails, the
        # StopFailure hook re-stamps with the CURRENT reset time, and the
        # next hold starts from accurate data. Cost is one paste; a
        # wrongly-held channel hangs the whole nexus (2026-07-14, 63 emits
        # into a frozen orchestrator).
        "$_OVER_LIMIT_LOG_FN" \
            "over-limit: max wake attempts (${max_attempts}) reached for '${window}' (key=${key}, state=${state_label}); failing OPEN — pasting wake brief and dropping stamp"
        _over_limit_failopen "$key" "$window" "$role" "$token" "$first_seen" "$now"
        return 0
    fi
    _over_limit_apply_backoff "$key" "$window" "$role" "$token" \
        "$reset_epoch" "$first_seen" "$new_attempts" "$now"
    "$_OVER_LIMIT_LOG_FN" \
        "over-limit: '${window}' still suspended (state=${state_label}, attempt ${new_attempts}/${max_attempts}); next probe at $(date -d "@$(_over_limit_load_next_attempt "$key")" -Is 2>/dev/null || echo '?')"
    return 0
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

    # ABSOLUTE anti-latch ceiling — the belt over every per-state
    # suspenders. No hold may outlive first_seen + MAX_HOLD regardless of
    # which branch it takes. This closes the ONE path the per-state
    # fail-opens don't: a persistently-FAILING pane-state probe (empty
    # output — not any pane state) backs off without consuming an attempt,
    # so on a broken pane-state.sh it would retry every 60s forever with
    # the gate closed (skeptic round-2 residual, PR #526). It also
    # backstops any future branch that forgets to bound itself. The
    # longest legitimate reset horizon is 24h ("resets <clock-time>"); the
    # default ceiling adds an hour of margin. A negative delta (bogus
    # future first_seen) never trips it.
    #
    # It is checked BEFORE the not-due guard (your-org/nexus-code#581). Behind
    # that guard the "absolute" ceiling was not absolute at all: it could only
    # fire on a row that was already due, so any defect that parked
    # next_attempt in the far future — exactly what the reset-horizon ratchet
    # did — silently disabled the one backstop meant to bound EVERY path. The
    # 2026-07-28 hold ran >12h with a 25h ceiling nominally in force and was
    # ended by a human, not by this check.
    local max_hold="${MONITOR_OVER_LIMIT_MAX_HOLD_SECONDS:-90000}"  # 25h
    [[ "$max_hold" =~ ^[0-9]+$ ]] || max_hold=90000
    if (( now - first_seen > max_hold )); then
        "$_OVER_LIMIT_LOG_FN" \
            "over-limit: '${window}' (key=${key}) hold exceeded absolute ceiling (${max_hold}s since first_seen); failing OPEN"
        _over_limit_failopen "$key" "$window" "$role" "$token" "$first_seen" "$now"
        return 0
    fi

    # Not due yet — leave the row alone.
    (( now >= next_attempt )) || return 0

    # Orchestrator and worker rows resolve identically: the wake loop
    # iterates EVERY row in the state file, and the only role-dependent
    # steps are which brief gets composed and the worker-only
    # machine-input stamp (both below).
    local probe_target probe_rc=0
    probe_target=$(_over_limit_resolve_window_index "$window") || probe_rc=$?
    if (( probe_rc >= 2 )); then
        # COULD NOT LOOK (your-org/nexus-code#699) — no tmux, or
        # `list-windows` failed. Dropping the stamp here would retire the
        # hold for a window we never observed; if it is in fact still
        # over-limit, every subsequent emit piles into a frozen pane and
        # the state that would have told us is gone. HOLD instead: the
        # stamp costs nothing to keep and the next wake re-evaluates.
        "$_OVER_LIMIT_LOG_FN" \
            "over-limit: could NOT determine whether window '${window}' (key=${key}) exists (rc ${probe_rc}) — holding the stamp; an unobserved window is not an absent one"
        return 0
    fi
    if (( probe_rc != 0 )) || [[ -z "$probe_target" ]]; then
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
            # Genuinely still suspended — back off, and fail OPEN at the
            # attempt cap rather than latch.
            _over_limit_bump_or_failopen "$key" "$window" "$role" "$token" \
                "$reset_epoch" "$first_seen" "$attempts" "$now" "over-limit"
            ;;
        absent|blocked)
            "$_OVER_LIMIT_LOG_FN" \
                "over-limit: '${window}' (key=${key}) reads ${state}; pane lost during suspension — dropping stamp"
            _over_limit_drop "$key"
            ;;
        idle|autosuggest-only|empty|busy|user-typing|working-background|working-self-paced|idle-orphan-async)
            # Resumption. ALL of these mean the pane is alive and
            # servicing turns again — the limit has lifted. The three
            # refined-idle states (working-background, working-self-paced,
            # idle-orphan-async; issue #183) are refinements of `idle`,
            # NOT a distinct suspension: an over-limit orchestrator that
            # recovers on its own (a standing Monitor-handle self-wake or
            # an operator prompt, both routine) and then idles under a
            # `· N monitor ·` footer probes as working-background every
            # cycle. Omitting them here left the row in the `*)` branch,
            # which backed off forever with no cap and latched the emit
            # gate closed indefinitely (skeptic finding, PR #526 round 1).
            # Paste the appropriate brief and drop the stamp. We compute
            # duration from first_seen so it reflects total inertness, not
            # just the last retry leg.
            local duration=$(( now - first_seen ))
            (( duration >= 0 )) || duration=0
            local body
            body=$(mktemp)
            if [[ "$role" == "orchestrator" ]]; then
                local workers
                workers=$(_over_limit_worker_summary)
                _over_limit_compose_resume_brief \
                    "$token" "$duration" "$workers" "$first_seen" > "$body"
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
            # Unrecognised pane state — a future pane-state.sh could add
            # one. Treat conservatively as still-suspended, BUT route
            # through the bounded step so even an unknown state cannot
            # back off forever: it hits the same MAX_ATTEMPTS fail-open as
            # `over-limit`. This is the belt-and-suspenders half of the
            # anti-latch guarantee (the known refined-idle states are
            # handled as resumption above; this catches anything new).
            _over_limit_bump_or_failopen "$key" "$window" "$role" "$token" \
                "$reset_epoch" "$first_seen" "$attempts" "$now" "unexpected:${state}"
            ;;
    esac
}

# Compute the next backoff and rewrite the row. Exponential: 60s →
# 120s → 240s → cap at 300s. Initial backoff and cap are configurable
# via env knobs.
#
# It does NOT touch the observation sidecar, and cannot: backing off is not an
# observation of the pane being over-limit. Advancing it here would let a retry
# loop hold the emit gate closed forever with no fresh evidence; clearing it
# would flap the gate open mid-retry during a genuine hold. Both are structural
# now — this function only writes the row file.
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
