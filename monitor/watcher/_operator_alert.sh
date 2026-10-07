#!/usr/bin/env bash
# _operator_alert.sh — the TEXT-CARRYING, TURN-INDEPENDENT operator alert.
# your-org/nexus-code#1548 (expiry arm alerted nobody for 7 h 22 m), #1533
# (`sandbox-notify` delivers ONE BIT), #1534 (service-health has no alert path).
#
# ============================================================================
# WHAT WAS MEASURED, AND WHY THIS IS A MODULE RATHER THAN A CALL
# ============================================================================
#
# On 2026-09-17 the operator's login expired at 04:02:10 and every agent lost
# the ability to take a turn for 7 h 24 m. The watcher DETECTED it in 41.4 s
# (`auth-hold: EXPIRY observed`) and told the operator nothing for 7 h 22 m,
# because the expiry arm's only outputs were a log line and — after its 7200 s
# ceiling — 3364 more log lines. The one alert of the day fired at 11:24:55,
# AFTER the operator had already opened `/login` by themselves.
#
# Three facts about the channels decided the shape of this file:
#
#   * `sandbox-notify` (via `_watcher_alert`) delivers ATTENTION, not CONTENT:
#     the real tool assigns `msg` once and never reads it again (#1533). The
#     words reach `watcher-alerts.log` and `watcher.log`; the operator hears a
#     bell. It IS worth ringing — the `watcher ALERT:` prefix is measured to
#     reach the notify wrapper's `critical` arm and RING (33 rings in 3 days,
#     #1551) — but a bell cannot say "run /login".
#   * `monitor/notify.sh` (Pushover → ntfy → SMTP) carries text off-terminal and
#     needs no model turn. Its evidence is ONE probe returning `pushover ok`,
#     which proves API acceptance and not that a device rendered it. UNVERIFIED
#     as a delivery channel; carried here as a leg, never as the mechanism.
#   * A GitHub issue authored by the BOT (installation token, a separate
#     credential that kept working through the whole outage) reaches the
#     operator through GitHub's own push channel — the one channel the
#     operator is observed to answer daily. Text, durable, turn-independent.
#
# So an alert here is FOUR legs, cheapest and most certain first:
#
#   1. a DURABLE, GREPPABLE record — `$STATE_DIR/operator-alerts.jsonl`, one
#      JSON line per raise / reminder / clear / leg outcome. This is the leg
#      that cannot fail to reach the reader who comes looking afterwards, and
#      it is the one #1548's forensics had to reconstruct from 3364 log lines.
#   2. the watcher ALERT ring — `_watcher_alert` when the host defines it
#      (alerts log + watcher log + the bell). Attention.
#   3. a push — `monitor/notify.sh`, `--priority emergency` for a `critical`
#      announcement (the one email of the incident), `routine` otherwise.
#      Off-terminal, unverified.
#   4. a GitHub incident issue — `operator-alert: <key>`, one OPEN issue per
#      key, re-used while open, closed by `clear`. Off-terminal, on the one
#      channel with observed delivery.
#
# ============================================================================
# FAIL-OPEN ON TELLING, NEVER ON THE CALLER (your-org/nexus-code#1553)
# ============================================================================
#
# A notification path must never be able to break the thing it reports on. So:
# every function here returns 0; every leg is `|| true`; the two NETWORK legs
# run in a backgrounded, `timeout`-bounded subshell so the watcher's 5 s sync
# task never waits on Pushover or GitHub; a missing `timeout` SKIPS the network
# legs and says so in the record (a leg that could run unbounded is the #1553
# F2 defect); and an unwritable state dir loses the record, not the bell.
#
# ============================================================================
# CADENCE — one announcement, then reminders, then a clear (#976)
# ============================================================================
#
# A 5 h over-limit hold once fired 20 critical bells, which is how an operator
# learns to ignore the bell. Per KEY: the first `raise` announces (all legs);
# a `raise` inside `MONITOR_OPERATOR_ALERT_REMINDER_SECONDS` (default 3600) of
# the last announcement is a silent no-op — no record either, because the
# callers run on 5 s cadences and a record per call is the 3364-line flood in
# JSON; a `raise` past it is a REMINDER (record + bell + push, never a second
# GitHub issue); `clear` removes the key, records the duration, sends a
# `routine` push and closes the issue. Nothing rings on `clear`.
#
# EMAIL: ONE PER INCIDENT, AND IT MUST ARRIVE (your-org/nexus-code#1653).
# `notify.sh` sends email on `--priority emergency` and on nothing else, so the
# push priority IS the email decision. Measured on 2026-09-27: a login expiry
# and a service-health alert riding on it, each re-sent as `emergency` on this
# 3600 s reminder, emailed the operator 6 times in 2 h 3 m — then 2 more for
# FALSE re-detections at 10:22 and 12:00. The rules, each keyed on durable
# incident state in the state dir (see INCIDENT STATE SIDECARS), so a watcher
# restart neither re-sends a delivered email nor forgets an undelivered one:
#
#   * a NEW incident (`began`) emails at once. Reminders and the clear do not.
#   * an ESCALATION (a raise at `critical` on a key announced as `warning`) is
#     an announcement, and emails once (F1).
#   * the email is DELIVERED only when notify.sh reports the EMAIL leg ok —
#     not when some push backend accepted. Until then it is retried, email
#     only, on a doubling backoff capped at the reminder period (F3).
#   * the same key back within REARM of its last clear is RESUMED: every leg
#     but email, and the email DEFERRED by REARM_CONFIRM, sent only if the
#     condition still stands then (F4). A genuine re-occurrence therefore
#     still emails — REARM_CONFIRM late — and a transient false one never
#     does. A raise past REARM is a new incident and emails at once.
#
# A FLAPPING condition — raised, cleared, raised again every few minutes during
# a partial outage — is the one shape in which "one issue per condition" could
# become a flood on a real repo (an ISSUE-CREATING alert is the leg whose
# failure mode is the loudest). Three defences, layered:
#
#   * a CLEAR HOLD-DOWN: `clear` does not finalise on the first call. It marks
#     the stamp `pending` and finalises only when the caller keeps saying
#     "absent" for MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS (default 300).
#     A `raise` inside the hold-down CANCELS the pending clear and is recorded
#     as a `flap` — no bell, no push, no GitHub write: from the operator's
#     side the condition never cleared. Callers therefore call `clear` on EVERY
#     cycle the condition is absent, not once on the transition.
#   * ISSUE REUSE on the network side: a `began` first looks for an OPEN issue
#     with the key's title, then for the most recently CLOSED one (a flap
#     slower than the hold-down), which it REOPENS; it CREATES only when
#     neither exists. So a key files at most one issue for as long as the
#     closed one is findable (first page of closed issues by update time).
#   * a COMMENT RATE CAP per key, MONITOR_OPERATOR_ALERT_COMMENT_INTERVAL_SECONDS
#     (default 3600): reminders and re-opens comment at most that often;
#     state changes (close/reopen) are never capped, because an issue whose
#     state disagrees with the condition is worse than a missing comment.
#
# REMINDERS BACK OFF, AND THEIR COMMENTS ARE CAPPED (your-org/nexus-code#1713).
# A fixed hourly reminder is unbounded in the outage's length: a login expiry
# over a weekend is ~24 bells, pushes and `still standing` comments a day until
# someone intervenes (measured: 4 comments on your-nexus#384 in a 4.5 h
# outage). So the delay after the incident's n-th announcement is
# REMINDER * 2^(n-1), capped at REMINDER_MAX: reminders at +1, +3, +7, +15 h,
# then one a day. Over an outage of T seconds that is at most
# ceil(log2(MAX/REMINDER)) + 1 + T/MAX reminders — 5 in the first day, then 1
# a day. `n` is the stamp's count field, i.e. DURABLE incident state: a watcher
# restart cannot reset the backoff (an in-process schedule would re-start it at
# one hour on every restart). The schedule resets when the incident clears
# (the stamp goes) and is untouched by a FLAP (a cancelled pending clear keeps
# the stamp). Stated degradation: a memo-only key (the state dir unwritable, so
# no stamp and no count) reminds at the base REMINDER, which is the pre-#1713
# cadence, never faster.
# On GitHub, an incident posts at most MAX_REMINDER_COMMENTS reminder comments;
# the last one says so, and after it the issue stays quiet until the clear
# comments and closes it. The count is the `<key>.ghreminders` sidecar keyed on
# the incident's first-raised epoch. Reopen/close, the email rules and the
# local record are unchanged.
#
# GitHub being unreachable, rate-limiting the bot, or refusing the write is
# recorded (`github-failed`, with the reason) and costs nothing else: the
# durable record and the bell have already happened, the caller has returned.
#
# ============================================================================
# INJECTION CONTRACTS (mirroring _auth_hold.sh / _over_limit.sh)
# ============================================================================
#
#   _OPERATOR_ALERT_LOG_FN   one message → the watcher log. Default no-op.
#   _OPERATOR_ALERT_BELL_FN  one message → the attention ring. Default resolves
#                            `_watcher_alert` at CALL time when the host
#                            defines it, else no-op.
#   _OPERATOR_ALERT_PUSH_CMD the push executable; default
#                            `$NEXUS_ROOT/monitor/notify.sh`. Tests point it at
#                            a recorder.
#   _OPERATOR_ALERT_CLEARED_FN  `<key> <first_epoch>` on the CLEAR TRANSITION —
#                            the first "absent" call after a raise, i.e. the
#                            call that STARTS the hold-down (or, with no
#                            hold-down, the one that finalises). Once per
#                            transition, never on the repeat calls inside the
#                            hold-down. Default no-op; main.sh uses it to pull
#                            the next emit forward (#1567 G2). `first_epoch`
#                            may be empty, or (memo-only key) the LAST
#                            announcement — a bound at or after the first raise.
#
# Knobs (each a value WE CHOSE, per the workspace rule on chosen parameters):
#   MONITOR_OPERATOR_ALERT_PUSH_ENABLED     (true)   leg 3
#   MONITOR_OPERATOR_ALERT_GITHUB_ENABLED   (true)   leg 4
#   MONITOR_OPERATOR_ALERT_REMINDER_SECONDS (3600)   the FIRST reminder's delay
#   MONITOR_OPERATOR_ALERT_REMINDER_MAX_SECONDS (86400) the backoff's ceiling
#   MONITOR_OPERATOR_ALERT_MAX_REMINDER_COMMENTS (5)  GitHub reminder comments
#                                            per incident; 0 = no cap
#   MONITOR_OPERATOR_ALERT_NET_TIMEOUT_SECONDS (60)  bound on each network leg
#
# `NEXUS_NOTIFY_QUIET=1` (the test-harness hard-off the notify wrapper honours)
# disables BOTH network legs here too, so a suite driving the real callers can
# never page the operator or file an issue.

_operator_alert_log_noop() { :; }
_OPERATOR_ALERT_LOG_FN="${_OPERATOR_ALERT_LOG_FN:-_operator_alert_log_noop}"
_operator_alert_bell_default() {
    if declare -F _watcher_alert >/dev/null 2>&1; then
        _watcher_alert "$1" || true
    fi
}
_OPERATOR_ALERT_BELL_FN="${_OPERATOR_ALERT_BELL_FN:-_operator_alert_bell_default}"
_operator_alert_cleared_noop() { :; }
_OPERATOR_ALERT_CLEARED_FN="${_OPERATOR_ALERT_CLEARED_FN:-_operator_alert_cleared_noop}"

# ---- paths ----------------------------------------------------------------
_operator_alert_log_path()  { printf '%s/operator-alerts.jsonl' "${STATE_DIR:-.}"; }
_operator_alert_dir()       { printf '%s/operator-alert' "${STATE_DIR:-.}"; }
_operator_alert_stamp_path() { printf '%s/%s.stamp' "$(_operator_alert_dir)" "$1"; }

# ---- knobs ----------------------------------------------------------------
_operator_alert_int() { local v="$1" d="$2"; [[ "$v" =~ ^[0-9]+$ ]] || v="$d"; printf '%s' "$v"; }
_operator_alert_reminder()    { _operator_alert_int "${MONITOR_OPERATOR_ALERT_REMINDER_SECONDS:-3600}" 3600; }
_operator_alert_reminder_max() { _operator_alert_int "${MONITOR_OPERATOR_ALERT_REMINDER_MAX_SECONDS:-86400}" 86400; }
_operator_alert_max_comments() { _operator_alert_int "${MONITOR_OPERATOR_ALERT_MAX_REMINDER_COMMENTS:-5}" 5; }
# The delay before the next reminder, after an incident's <n>-th announcement
# (#1713): REMINDER * 2^(n-1), capped at REMINDER_MAX. n <= 1 (or a count that
# could not be read) is the base REMINDER. A MAX below the base disables the
# backoff (the base wins). Builtins only: `due` runs on a 5 s cadence.
_operator_alert_reminder_after() {   # <n> → seconds
    local n="${1:-0}" d m i
    d=$(_operator_alert_reminder); m=$(_operator_alert_reminder_max)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    for (( i = 1; i < n && d < m; i++ )); do d=$(( d * 2 )); done
    (( d > m && m >= $(_operator_alert_reminder) )) && d=$m
    printf '%s' "$d"
}
_operator_alert_net_timeout() { _operator_alert_int "${MONITOR_OPERATOR_ALERT_NET_TIMEOUT_SECONDS:-60}" 60; }
_operator_alert_holddown()    { _operator_alert_int "${MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS:-300}" 300; }
_operator_alert_comment_iv()  { _operator_alert_int "${MONITOR_OPERATOR_ALERT_COMMENT_INTERVAL_SECONDS:-3600}" 3600; }
_operator_alert_comment_stamp_path() { printf '%s/%s.ghcomment' "$(_operator_alert_dir)" "$1"; }
# rc 0 iff a comment on <key>'s issue is allowed now; stamps when it is.
_operator_alert_comment_allowed() {
    local key="$1" f last now
    f=$(_operator_alert_comment_stamp_path "$key"); now=$(date +%s)
    last=$(cat "$f" 2>/dev/null); [[ "$last" =~ ^[0-9]+$ ]] || last=0
    local memo; memo=$(_operator_alert_memo_last "$key" comment); (( memo > last )) && last=$memo
    (( now - last >= $(_operator_alert_comment_iv) )) || return 1
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    { printf '%s\n' "$now" > "$f"; } 2>/dev/null || true
    # The memo is set UNCONDITIONALLY: an unwritable cap stamp must not turn
    # the cap off (F2: 20 comments in 20 cycles).
    _operator_alert_memo_set "$key" "$now" comment || true
    return 0
}
# ---- INCIDENT STATE SIDECARS (your-org/nexus-code#1653) -----------------------
# Beside `<key>.stamp`, never inside it: every stamp reader parses exactly four
# tab fields and `read` hands the remainder to the LAST variable, so a fifth
# field would corrupt `pending`. All live in the state dir, so a watcher restart
# neither forgets an undelivered email nor re-sends a delivered one.
#
#   <key>.sev      the highest severity ANNOUNCED for this incident (F1). A
#                  raise at a higher severity than announced is an ESCALATION,
#                  and an escalation is email-worthy once.
#   <key>.mail     `first  state  attempts  next` — the incident's one email:
#                    first     the incident's first-raised epoch (its identity;
#                              a result for another incident is ignored)
#                    state     pending | delivered | unconfigured | refused | deferred
#                    next      when the next attempt (or the confirmation) is due
#                  `delivered` means notify.sh reported the EMAIL leg ok, not that
#                  some push backend accepted (F3). A failed email is retried,
#                  email-only, on a backoff of MAIL_RETRY doubling up to the
#                  reminder period, until it lands or the incident clears.
#   <key>.chain    `acc_s  emailed  last_email` — the CHAIN of resumed episodes
#                  since the key last began (G1). acc_s is the CUMULATIVE
#                  standing time of resumed episodes that cleared without
#                  emailing; a resume is deferred only by REARM_CONFIRM − acc_s,
#                  so a genuine outage whose detection FLICKERS still emails
#                  once its standing time adds up. emailed=1 once a resumed
#                  episode was CONFIRMED (last_email = when). After that the
#                  cumulative path is LATCHED — without the latch a flicker
#                  emailed every episode (13 in 3 h, measured) — but a resumed
#                  episode that stands CONTINUOUSLY for REARM_CONFIRM still
#                  confirms, no sooner than a reminder period after the chain's
#                  last email (H1: the round-3 latch dropped a genuine third
#                  outage that stood 3.7 h — 0 emails).
#   <key>.cleared  the epoch the last incident on this key FINALLY cleared (F4).
#                  A raise within REARM of it is the same key coming back: its
#                  email is DEFERRED by REARM_CONFIRM and sent only if the
#                  condition is still standing then. Measured 2026-09-27: both
#                  re-detections (10:22, 12:00; 236 s and 5444 s after a clear)
#                  were FALSE positives that cleared within 93 s and 185 s
#                  (278 s CUMULATIVE, under 600 s: 0 emails).
#
#   THE BOUND (G1): a resumed chain emails within one watcher tick of its
#   CUMULATIVE standing time reaching REARM_CONFIRM (600 s), however the
#   standing time is split into episodes, provided no gap exceeds REARM (a gap
#   past REARM breaks the chain, and the next raise is a NEW incident that
#   emails at once). Worst-case wall-clock delay from the first resume =
#   600 s of standing + every off-period in between. Once the chain has
#   emailed (H1), only an episode standing CONTINUOUSLY for 600 s confirms.
#   EVERY confirmation waits until at least the reminder period (3600 s) after
#   the key's last began/confirmed email. The first raise of a new incident
#   is never delayed.
#
#   THE CONTRACT (your-org/nexus-code#1653 round 4), property-tested over
#   seeded random schedules by test-operator-alert-property.sh:
#     LIVENESS  every run the condition stands CONTINUOUSLY for >= L = 900 s
#               has an email for its key within [run start - W, run start + L],
#               W = 3600 s (an email already sent within the hour counts).
#     SAFETY    any two non-escalation emails for a key are >= 3600 s apart
#               (so N <= 24 per key per day), and escalation emails never
#               exceed the key's warning->critical transitions.
#
# Knobs (values WE CHOSE):
#   MONITOR_OPERATOR_ALERT_REARM_SECONDS         (7200) the auth hold's own
#       max_hold; covers the measured 5444 s gap with margin. A 1800 s window
#       would have emailed at 12:00.
#   MONITOR_OPERATOR_ALERT_REARM_CONFIRM_SECONDS (600)  above the longest
#       measured false re-detection (185 s) plus the 300 s clear hold-down.
#   MONITOR_OPERATOR_ALERT_MAIL_RETRY_SECONDS    (300)  first retry of a failed
#       email; doubles per attempt, capped at the reminder period.
_operator_alert_rearm()      { _operator_alert_int "${MONITOR_OPERATOR_ALERT_REARM_SECONDS:-7200}" 7200; }
_operator_alert_rearm_confirm() { _operator_alert_int "${MONITOR_OPERATOR_ALERT_REARM_CONFIRM_SECONDS:-600}" 600; }
_operator_alert_mail_retry() { _operator_alert_int "${MONITOR_OPERATOR_ALERT_MAIL_RETRY_SECONDS:-300}" 300; }
_operator_alert_side() { printf '%s/%s.%s' "$(_operator_alert_dir)" "$1" "$2"; }   # <key> <sev|mail|cleared>
_operator_alert_mail_backoff() {   # <attempt n ≥ 1> → seconds until attempt n+1
    local n="$1" d cap; d=$(_operator_alert_mail_retry); cap=$(_operator_alert_reminder)
    while (( n > 1 && d < cap )); do d=$(( d * 2 )); n=$(( n - 1 )); done
    (( d > cap )) && d=$cap
    printf '%s' "$d"
}
_operator_alert_mail_put() {   # <key> <first> <state> <attempts> <next>
    mkdir -p "$(_operator_alert_dir)" 2>/dev/null || true
    { printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" > "$(_operator_alert_side "$1" mail)"; } 2>/dev/null || true
}
# The push leg reports the EMAIL leg's outcome for the incident it was sent for.
_operator_alert_mail_result() {   # <key> <first> <ok|failed|unconfigured|refused|skipped|unknown>
    local key="$1" first="$2" est="$3" f m_first m_state m_att m_next
    f=$(_operator_alert_side "$key" mail)
    { IFS=$'\t' read -r m_first m_state m_att m_next < "$f"; } 2>/dev/null || return 0
    [[ "$m_first" == "$first" && "$m_state" == pending ]] || return 0   # another incident, or already settled
    case "$est" in
        ok)           _operator_alert_mail_put "$key" "$first" delivered "$m_att" 0
                      _operator_alert_record mail-delivered "$key" attempts="$m_att" ;;
        refused)      _operator_alert_mail_put "$key" "$first" refused "$m_att" 0
                      _operator_alert_record mail-refused "$key" attempts="$m_att" note="the mail policy refused the recipient or sender (notify.sh rc 5/6); retrying cannot fix it (your-org/nexus-code#1663)" ;;
        unconfigured|quiet) _operator_alert_mail_put "$key" "$first" unconfigured "$m_att" 0
                      _operator_alert_record mail-unconfigured "$key" attempts="$m_att" note="no address or SMTP host; retrying cannot fix it" ;;
        *)            _operator_alert_record mail-failed "$key" attempts="$m_att" email="$est" next_in_s="$(( m_next - $(date +%s) ))" ;;
    esac
    return 0
}
_operator_alert_flag_on() {   # <value> → rc 0 unless an OFF spelling
    case "${1:-true}" in false|0|no|off|FALSE|NO|OFF) return 1 ;; esac
    return 0
}
_operator_alert_push_enabled()   { _operator_alert_flag_on "${MONITOR_OPERATOR_ALERT_PUSH_ENABLED:-true}"; }
_operator_alert_github_enabled() { _operator_alert_flag_on "${MONITOR_OPERATOR_ALERT_GITHUB_ENABLED:-true}"; }
_operator_alert_quiet() { [[ "${NEXUS_NOTIFY_QUIET:-0}" == "1" ]]; }

# ---- the DEDUP STATE MUST SURVIVE THE DISK IT LIMITS (skeptic oplivesk F2) ----
# The stamp lives in the state dir, and the state dir is exactly what fails in
# the incidents this module exists for (a read-only project FS, ENOSPC).
# Measured by the skeptic's rig: RO state dir, 20 cycles → 20 bells + 20
# emergency pushes; a zero-byte unwritable stamp with the issue open → 20
# pushes + 20 GitHub COMMENTS (720/h). So the last-announce time is ALSO kept
# (a) in this process — the watcher's sync tasks share one bash — and (b) in a
# fallback file under ${TMPDIR:-/tmp}, a different mount that stays writable
# when the project FS does not (`_nexus_critical_alarm`'s precedent). Reads
# take the MAX of all three; a raise that could persist nothing skips its
# repeatable network legs.
declare -gA _OPERATOR_ALERT_MEMO 2>/dev/null || true
declare -gA _OPERATOR_ALERT_COMMENT_MEMO 2>/dev/null || true
# NAMESPACED BY STATE DIR (skeptic oplivesk2 G1). $TMPDIR is shared by every
# nexus instance on the host, and the first cut keyed the memo on the alert
# key alone — so instance A's `auth-expired` memo made instance B's FIRST
# raise of the same key read as "announced recently" and go SILENT. The
# discriminator is a checksum of the INSTANCE — the state dir AND the nexus
# root, so an unset or relative state dir cannot collapse two instances into
# one namespace (two instances that genuinely share one absolute state dir
# share their stamps too, and sharing the memo is then correct). Cached per
# instance because `due` runs on a 5 s cadence and must not fork every time.
_operator_alert_memo_ns() {
    local sd="${STATE_DIR:-.}|${NEXUS_ROOT:-}"
    if [[ "${_OPERATOR_ALERT_NS_FOR:-}" != "$sd" ]]; then
        _OPERATOR_ALERT_NS=$(printf '%s' "$sd" | cksum 2>/dev/null | cut -d' ' -f1)
        [[ "$_OPERATOR_ALERT_NS" =~ ^[0-9]+$ ]] || _OPERATOR_ALERT_NS=0
        _OPERATOR_ALERT_NS_FOR="$sd"
    fi
    printf '%s' "$_OPERATOR_ALERT_NS"
}
_operator_alert_memo_path() { printf '%s/.nexus-operator-alert.%s.%s.%s' "${TMPDIR:-/tmp}" "$(_operator_alert_memo_ns)" "$2" "${1//[^A-Za-z0-9._-]/_}"; }
_operator_alert_memo_last() {   # <key> [kind=raise] → max(in-process, tmp file), 0 when none
    local key="$1" kind="${2:-raise}" a=0 b
    local mk; mk="$(_operator_alert_memo_ns):$key"
    if [[ "$kind" == comment ]]; then a="${_OPERATOR_ALERT_COMMENT_MEMO[$mk]:-0}"; else a="${_OPERATOR_ALERT_MEMO[$mk]:-0}"; fi
    [[ "$a" =~ ^[0-9]+$ ]] || a=0
    b=$(cat "$(_operator_alert_memo_path "$key" "$kind")" 2>/dev/null); [[ "$b" =~ ^[0-9]+$ ]] || b=0
    (( b > a )) && a=$b
    printf '%s' "$a"
}
_operator_alert_memo_set() {    # <key> <epoch> [kind] — rc 0 iff the tmp file took it
    local key="$1" ts="$2" kind="${3:-raise}" f mk
    mk="$(_operator_alert_memo_ns):$key"
    if [[ "$kind" == comment ]]; then _OPERATOR_ALERT_COMMENT_MEMO[$mk]="$ts"; else _OPERATOR_ALERT_MEMO[$mk]="$ts"; fi
    f=$(_operator_alert_memo_path "$key" "$kind")
    { printf '%s\n' "$ts" > "$f"; } 2>/dev/null
}
_operator_alert_memo_clear() {  # <key>
    local mk; mk="$(_operator_alert_memo_ns):$1"
    unset "_OPERATOR_ALERT_MEMO[$mk]" "_OPERATOR_ALERT_COMMENT_MEMO[$mk]" 2>/dev/null || true
    rm -f "$(_operator_alert_memo_path "$1" raise)" "$(_operator_alert_memo_path "$1" comment)" 2>/dev/null || true
}

# ---- when NOTHING can be persisted: a memo held by the KERNEL (#1567 G4) ----
# The three stores above all fail together in one configuration: the state dir
# AND $TMPDIR unwritable AND the caller in a SUBSHELL (service_health and the
# self-heal loop guard both raise from async tasks), so the in-process memo dies
# with the subshell. Then every cycle reads as a FIRST raise and runs the GitHub
# leg — network-idempotent (it reuses the open issue), but one issue-list read
# per cycle against the bot's rate limit during exactly the incident where the
# token is needed elsewhere (~720/h at a 5 s cadence).
#
# No file can hold the fact, and a subshell cannot write its parent's memory,
# so the fact is held by a PROCESS: the degraded attempt leaves a `sleep` whose
# argv[0] names the instance and the key, living one reminder period. While it
# lives, a first raise that could persist nothing skips the GitHub leg. It is in
# the watcher's process group, so a watcher restart ends it and the new process
# gets its own first attempt ("first attempt in the process").
#
# Matched on argv[0] EXACTLY, never by substring: an agent's argv IS its prompt,
# and a prompt quoting this name must not read as the sentinel (#1073). argv[0]
# of every agent is its binary. Error direction, stated: where /proc cannot be
# read, or the sentinel cannot be forked, `alive` answers NO and the leg runs —
# the pre-fix cost, never a silenced alert.
_operator_alert_sentinel_name() {   # <key>
    printf 'nexus-operator-alert-sentinel.%s.%s' "$(_operator_alert_memo_ns)" "${1//[^A-Za-z0-9._-]/_}"
}
_operator_alert_sentinel_alive() {   # <key> → rc 0 iff a live sentinel holds it
    local want f a0
    want=$(_operator_alert_sentinel_name "$1")
    for f in /proc/[0-9]*/cmdline; do
        { IFS= read -r -d '' a0 < "$f"; } 2>/dev/null || continue
        [[ "$a0" == "$want" ]] && return 0
    done
    return 1
}
_operator_alert_sentinel_start() {   # <key>
    local name; name=$(_operator_alert_sentinel_name "$1")
    # CLOSE EVERY INHERITED FD ABOVE 2 before the exec (the #451/#468/#471
    # fd-leak class). The watcher calls this from its MAIN process, holding the
    # instance flock on INSTANCE_LOCK_FD: a sentinel that kept it pinned the lock
    # for up to a reminder period after a crashed watcher, and the successor
    # could not start (skeptic B1 on PR #1630, measured). A `sleep` needs no
    # descriptor, so every one goes — not only the instance lock, and without
    # depending on _lib.sh's _close_inherited_locks being loaded here.
    local rem; rem=$(_operator_alert_reminder)
    (
        for _oa_fd in /proc/"$BASHPID"/fd/*; do
            _oa_fd=${_oa_fd##*/}
            [[ "$_oa_fd" =~ ^[0-9]+$ ]] && (( _oa_fd > 2 )) && eval "exec ${_oa_fd}>&-" 2>/dev/null
        done
        exec -a "$name" sleep "$rem"
    ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
    return 0
}

# A key names a CONDITION, and it becomes a filename and an issue title, so its
# alphabet is fixed here rather than sanitised: a silently rewritten key is a
# stamp that cannot be cleared by the caller that raised it.
_operator_alert_key_ok() { [[ "${1:-}" =~ ^[a-z0-9][a-z0-9._:-]{0,63}$ ]]; }

# ---- the durable record ---------------------------------------------------
# One JSON line, escaped by hand (no jq on this path: the record is the leg
# that must not depend on anything). Control characters are dropped, not
# escaped — a message is prose, and a stray tab inside it is worth less than
# a record that always parses.
_operator_alert_json_str() {
    printf '%s' "$1" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}
# _operator_alert_record <event> <key> <k=v>… ; the trailing pairs are string
# fields. Best-effort: an unwritable log never fails the caller.
_operator_alert_record() {
    local event="$1" key="$2"; shift 2
    local path now iso line f k v
    path=$(_operator_alert_log_path)
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
    now=$(date +%s); iso=$(date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    line=$(printf '{"ts":%s,"iso":"%s","event":"%s","key":"%s"' \
        "$now" "$iso" "$(_operator_alert_json_str "$event")" "$(_operator_alert_json_str "$key")")
    for f in "$@"; do
        k="${f%%=*}"; v="${f#*=}"
        line="$line,\"$(_operator_alert_json_str "$k")\":\"$(_operator_alert_json_str "$v")\""
    done
    # Brace-grouped: a redirection failure is reported by the SHELL, not the
    # command, so `cmd >> f 2>/dev/null` still prints it (#723). The record is
    # best-effort and must be silent when it cannot land.
    { printf '%s}\n' "$line" >> "$path"; } 2>/dev/null || true
    return 0
}

# ---- board context, for callers composing a message ------------------------
# The supervisor's arm state rides on every auth alert because it is the
# exposure #1532 measured (7 h 13 m unarmed during the same outage) and the
# operator cannot see it from a phone. Prints one clause or nothing.
_operator_alert_context() {
    local hb="${WATCHER_SUPERVISOR_HEARTBEAT:-}" stale="${MONITOR_WATCHER_SUPERVISOR_HEARTBEAT_STALE_SECONDS:-90}" age
    [[ -n "$hb" ]] || return 0
    declare -F _watcher_heartbeat_age >/dev/null 2>&1 || return 0
    [[ "$stale" =~ ^[0-9]+$ ]] || stale=90
    age=$(_watcher_heartbeat_age "$hb"); [[ "$age" =~ ^[0-9]+$ ]] || age=999999
    if (( age <= stale )); then
        printf 'watcher-supervisor: ARMED (heartbeat %ss ago).' "$age"
    elif (( age >= 999999 )); then
        printf 'watcher-supervisor: UNARMED (no heartbeat) — a watcher crash has no turn-independent revival until an orchestrator turn re-arms it.'
    else
        printf 'watcher-supervisor: UNARMED for %ss — a watcher crash has no turn-independent revival until an orchestrator turn re-arms it.' "$age"
    fi
}

# ---- network legs (run in a backgrounded subshell) -------------------------
_operator_alert_push_leg() {   # <key> <severity> <kind> <message> [incident-first]
    local key="$1" severity="$2" kind="$3" msg="$4" first="${5:-}" cmd pri rc tmo esf est track=0
    local -a eo=()
    cmd="${_OPERATOR_ALERT_PUSH_CMD:-${NEXUS_ROOT:-}/monitor/notify.sh}"
    [[ -x "$cmd" ]] || { _operator_alert_record push-skipped "$key" reason=no-notify-cmd cmd="$cmd"; return 0; }
    case "$severity" in critical) pri=emergency ;; *) pri=routine ;; esac
    # ONE EMAIL PER INCIDENT: `emergency` is the only priority on which
    # notify.sh sends email. So only an ANNOUNCEMENT carries it — `began`, an
    # `escalated` severity (F1), a `confirmed` re-raise (F4) and a one-shot
    # `event` — plus a `mail-retry`, which is email ALONE so a push that already
    # landed is not re-rung (F3). A reminder, a `resumed` re-raise and a clear
    # push `routine`. See the EMAIL note in the header.
    case "$kind" in
        began|escalated|confirmed|resumed-confirmed|event) ;;
        mail-retry) pri=emergency; eo=(--email-only) ;;
        *) pri=routine ;;
    esac
    [[ "$pri" == emergency && "$kind" != event && -n "$first" ]] && track=1
    mkdir -p "$(_operator_alert_dir)" 2>/dev/null || true
    esf="$(_operator_alert_dir)/.email-status.${BASHPID}.${RANDOM}"
    tmo=$(_operator_alert_net_timeout)
    timeout "$tmo" "$cmd" "nexus operator-alert: $key ($kind)" "$msg" \
        --priority "$pri" ${eo[@]+"${eo[@]}"} --email-status-file "$esf" \
        --require-delivery --quiet >/dev/null 2>&1
    rc=$?
    est=""; { IFS= read -r est < "$esf"; } 2>/dev/null || true
    rm -f "$esf" 2>/dev/null || true
    [[ -n "$est" ]] || est=unknown     # killed by timeout, or a notifier without the flag: NOT delivered
    _operator_alert_record push "$key" kind="$kind" priority="$pri" rc="$rc" email="$est" \
        note="rc 0 = a backend ACCEPTED the message (API acceptance, not device delivery); 2 = no backend configured; 3 = every backend failed; 124 = timeout. email= is the EMAIL leg alone"
    (( track )) && _operator_alert_mail_result "$key" "$first" "$est"
    return 0
}

# One OPEN issue per key. REST list endpoint (immediately consistent), title
# prefix match, first 5 pages — the same idempotency `_nexus_github_incident_escalate`
# uses and for the same reason: the search index lags minutes and would
# double-file. `began` files (or finds) the issue and comments nothing;
# `continues` comments a reminder on it; `clear` comments and closes.
_operator_alert_github_leg() {   # <key> <severity> <kind> <message> [incident-first]
    local key="$1" severity="$2" kind="$3" msg="$4" first="${5:-}"
    local root="${NEXUS_ROOT:-}" cfg repo login mint tok tmo title num page page_json found count body resp
    cfg="$root/config/load.sh"
    command -v gh >/dev/null 2>&1 || { _operator_alert_record github-skipped "$key" reason=no-gh; return 0; }
    command -v jq >/dev/null 2>&1 || { _operator_alert_record github-skipped "$key" reason=no-jq; return 0; }
    repo="${MONITOR_REPO:-}"
    [[ -n "$repo" || ! -x "$cfg" ]] || repo=$("$cfg" github.repo 2>/dev/null)
    login="${MONITOR_USER_LOGIN:-}"
    [[ -n "$login" || ! -x "$cfg" ]] || login=$("$cfg" github.user_login 2>/dev/null)
    [[ -n "$repo" && -n "$login" ]] || { _operator_alert_record github-skipped "$key" reason=no-repo-or-login; return 0; }
    mint="${NEXUS_MINT_TOKEN_BIN:-$root/monitor/mint-token.sh}"
    [[ -f "$mint" ]] || { _operator_alert_record github-skipped "$key" reason=no-mint; return 0; }
    tmo=$(_operator_alert_net_timeout)
    tok=$(NEXUS_ROOT="$root" timeout "$tmo" bash "$mint" 2>/dev/null) || tok=""
    [[ -n "$tok" ]] || { _operator_alert_record github-failed "$key" reason=mint-failed; return 0; }
    title="operator-alert: $key"
    # The OPEN issue for this key, walking up to 5 pages; a list failure is a
    # network failure and is recorded, never mistaken for "no issue".
    num=""; page=1; list_ok=1
    while (( page <= 5 )); do
        page_json=$(GH_TOKEN="$tok" timeout "$tmo" gh api \
            "/repos/$repo/issues?state=open&per_page=100&page=$page" 2>/dev/null) || { list_ok=0; break; }
        found=$(printf '%s' "$page_json" | jq -r --arg t "$title" \
            '[.[] | select(.pull_request == null) | select((.title // "") == $t) | .number] | first // empty' 2>/dev/null)
        if [[ -n "$found" ]]; then num="$found"; break; fi
        count=$(printf '%s' "$page_json" | jq -r 'length' 2>/dev/null)
        [[ "$count" =~ ^[0-9]+$ ]] || { list_ok=0; break; }
        (( count < 100 )) && break
        (( page++ ))
    done
    if (( ! list_ok )); then
        _operator_alert_record github-failed "$key" kind="$kind" reason=list-failed \
            note="GitHub unreachable, rate-limited or refusing; the record and the bell already happened"
        return 0
    fi
    case "$kind" in
        began|resumed|resumed-confirmed)
            if [[ -n "$num" ]]; then
                _operator_alert_record github "$key" kind="$kind" action=reused issue="$num"
                return 0
            fi
            # A flap slower than the hold-down: the issue was CLOSED moments
            # ago. REOPEN it rather than file a second one — the closed list
            # by update time, first page, is where it sits.
            page_json=$(GH_TOKEN="$tok" timeout "$tmo" gh api \
                "/repos/$repo/issues?state=closed&sort=updated&direction=desc&per_page=100" 2>/dev/null) || page_json=""
            found=$(printf '%s' "$page_json" | jq -r --arg t "$title" \
                '[.[] | select(.pull_request == null) | select((.title // "") == $t) | .number] | first // empty' 2>/dev/null)
            if [[ -n "$found" ]]; then
                if GH_TOKEN="$tok" timeout "$tmo" gh api -X PATCH "/repos/$repo/issues/$found" \
                    -f state=open >/dev/null 2>&1; then
                    _operator_alert_record github "$key" kind="$kind" action=reopened issue="$found"
                    if _operator_alert_comment_allowed "$key"; then
                        GH_TOKEN="$tok" timeout "$tmo" gh api -X POST "/repos/$repo/issues/$found/comments" \
                            -f "body=@$login re-raised — $msg" >/dev/null 2>&1 || true
                    else
                        _operator_alert_record github-comment-capped "$key" kind="$kind" issue="$found"
                    fi
                else
                    _operator_alert_record github-failed "$key" kind="$kind" reason=reopen-failed issue="$found"
                fi
                return 0
            fi
            body=$(printf '@%s — **%s**\n\n%s\n\n<sub>Auto-filed by the watcher (%s). One issue per condition: closed automatically when the condition clears, reopened if it returns. Record: `monitor/.state/operator-alerts.jsonl` key=`%s`.</sub>' \
                "$login" "$msg" "$(_operator_alert_context)" "$severity" "$key")
            resp=$(GH_TOKEN="$tok" timeout "$tmo" gh api -X POST "/repos/$repo/issues" \
                -f "title=$title" -f "body=$body" 2>/dev/null) || resp=""
            num=$(printf '%s' "$resp" | jq -r '.number // empty' 2>/dev/null)
            if [[ -n "$num" ]]; then
                _operator_alert_comment_allowed "$key" >/dev/null   # the body counts as the first comment
                _operator_alert_record github "$key" kind="$kind" action=filed issue="$num"
            else
                _operator_alert_record github-failed "$key" kind="$kind" reason=create-failed
            fi
            ;;
        continues|escalated|confirmed)
            [[ -n "$num" ]] || { _operator_alert_record github-skipped "$key" kind="$kind" reason=no-open-issue; return 0; }
            # #1713: a REMINDER (`continues`) comments at most MAX_REMINDER_COMMENTS
            # times per incident. Escalations and confirmations are announcements
            # and are neither counted nor capped here.
            local grf g_first="" g_n=0 g_cap suffix=""
            grf=$(_operator_alert_side "$key" ghreminders); g_cap=$(_operator_alert_max_comments)
            if [[ "$kind" == continues ]] && (( g_cap > 0 )); then
                { IFS=$'\t' read -r g_first g_n < "$grf"; } 2>/dev/null || true
                [[ "$g_first" == "$first" && "$g_n" =~ ^[0-9]+$ ]] || g_n=0
                if (( g_n >= g_cap )); then
                    _operator_alert_record github-reminders-exhausted "$key" kind="$kind" issue="$num" posted="$g_n" cap="$g_cap"
                    return 0
                fi
            fi
            if ! _operator_alert_comment_allowed "$key"; then
                _operator_alert_record github-comment-capped "$key" kind="$kind" issue="$num"; return 0
            fi
            if [[ "$kind" == continues ]] && (( g_cap > 0 && g_n + 1 >= g_cap )); then
                suffix=$(printf '\n\nThis is the last reminder comment for this incident (%s of %s): no further reminders will be posted here until the condition clears. The watcher still records it, and the clear will comment and close this issue.' "$(( g_n + 1 ))" "$g_cap")
            fi
            if GH_TOKEN="$tok" timeout "$tmo" gh api -X POST "/repos/$repo/issues/$num/comments" \
                -f "body=@$login still standing — $msg$suffix" >/dev/null 2>&1; then
                _operator_alert_record github "$key" kind="$kind" action=reminded issue="$num"
                if [[ "$kind" == continues ]] && (( g_cap > 0 )); then
                    mkdir -p "$(_operator_alert_dir)" 2>/dev/null || true
                    { printf '%s\t%s\n' "$first" "$(( g_n + 1 ))" > "$grf"; } 2>/dev/null || true
                fi
            else
                _operator_alert_record github-failed "$key" kind="$kind" reason=comment-failed issue="$num"
            fi
            ;;
        clear)
            [[ -n "$num" ]] || { _operator_alert_record github-skipped "$key" kind="$kind" reason=no-open-issue; return 0; }
            if _operator_alert_comment_allowed "$key"; then
                GH_TOKEN="$tok" timeout "$tmo" gh api -X POST "/repos/$repo/issues/$num/comments" \
                    -f "body=✅ cleared — $msg" >/dev/null 2>&1 || true
            fi
            # The close is a STATE change and is never capped.
            GH_TOKEN="$tok" timeout "$tmo" gh api -X PATCH "/repos/$repo/issues/$num" \
                -f state=closed >/dev/null 2>&1 \
                && _operator_alert_record github "$key" kind="$kind" action=closed issue="$num" \
                || _operator_alert_record github-failed "$key" kind="$kind" reason=close-failed issue="$num"
            ;;
    esac
    return 0
}

# Both network legs, detached. `timeout` is REQUIRED for a bounded leg: absent,
# both are skipped and the record says why (#1553 F2: a notifier that ran
# unbounded when `timeout` was off PATH).
_operator_alert_network() {   # <key> <severity> <kind> <message> [incident-first]
    local key="$1" severity="$2" kind="$3" msg="$4" first="${5:-}" do_push=0 do_gh=0
    _operator_alert_push_enabled   && do_push=1
    _operator_alert_github_enabled && do_gh=1
    if _operator_alert_quiet; then
        _operator_alert_record network-skipped "$key" kind="$kind" reason=NEXUS_NOTIFY_QUIET
        return 0
    fi
    (( do_push || do_gh )) || return 0
    if ! command -v timeout >/dev/null 2>&1; then
        _operator_alert_record network-skipped "$key" kind="$kind" reason=no-timeout-on-PATH
        return 0
    fi
    # `_OPERATOR_ALERT_NETWORK_SYNC=1` runs the legs INLINE — a test seam, so a
    # suite can assert on the recorders deterministically. Production is
    # detached: the caller is a 5 s watcher task and must never wait on a
    # network round trip (the bound is `timeout`, the isolation is the fork).
    if [[ "${_OPERATOR_ALERT_NETWORK_SYNC:-0}" == "1" ]]; then
        (( do_push )) && _operator_alert_push_leg   "$key" "$severity" "$kind" "$msg" "$first"
        (( do_gh ))   && _operator_alert_github_leg "$key" "$severity" "$kind" "$msg" "$first"
        return 0
    fi
    (
        (( do_push )) && _operator_alert_push_leg   "$key" "$severity" "$kind" "$msg" "$first"
        (( do_gh ))   && _operator_alert_github_leg "$key" "$severity" "$kind" "$msg" "$first"
        exit 0
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
    return 0
}

# ---- the verbs ------------------------------------------------------------
#
#   _operator_alert raise <key> <critical|warning> <message>
#   _operator_alert clear <key> <message>
#   _operator_alert notify <key> <critical|warning> <message>
#   _operator_alert standing <key>          rc 0 iff the key is raised
#   _operator_alert due <key> [severity]    rc 0 iff a raise NOW would announce
#                                           (no stamp, or past the reminder, or
#                                           an escalation to [severity], or the
#                                           incident's email is due) —
#                                           so a 5 s caller can skip composing
#                                           a message it will not send
#   _operator_alert since <key>             prints the first-raised epoch
#
# `raise`/`clear` bracket a STANDING CONDITION (a stamp, reminders, one issue).
# `notify` is an EVENT — something that happened once and is over (the
# watcher sent Escape into an abandoned login): record + log + bell + push,
# no stamp, no reminders, no issue to close.
#
# Always returns 0 from raise/clear/notify. `critical` rings the bell and
# pushes at emergency priority; `warning` records, pushes routine and files
# the issue but does NOT ring — the bell is for conditions where a human must
# act now.
_operator_alert() {
    local verb="${1:-}"; shift || true
    case "$verb" in
        raise)    _operator_alert_raise "$@" ;;
        clear)    _operator_alert_clear "$@" ;;
        notify)   _operator_alert_notify "$@" ;;
        standing) _operator_alert_key_ok "${1:-}" || return 1
                  [[ -f "$(_operator_alert_stamp_path "$1")" ]] && return 0
                  (( $(_operator_alert_memo_last "$1") > 0 )) ;;
        due)      _operator_alert_due "${1:-}" "${2:-}" ;;
        since)    _operator_alert_key_ok "${1:-}" || return 1
                  [[ -f "$(_operator_alert_stamp_path "$1")" ]] || return 1
                  cut -f1 "$(_operator_alert_stamp_path "$1")" 2>/dev/null ;;
        *)        return 2 ;;
    esac
}

# `due` MUST answer 0 while a clear is PENDING (skeptic oplivesk F1). Every
# production caller is `due && raise`; the first cut answered from `last`
# alone, so inside the reminder window it said "not due", `raise` was never
# reached, the flap cancellation below never ran, and the pending clear
# finalised ACROSS a condition that was present. Measured by the skeptic's
# rig, 10 fast flaps: due-gated 4 bells / 7 pushes / 3 close+reopen / 0 flap
# records, against 1 / 1 / 0 / 9 through a direct raise. The suite's flap
# section called `raise` directly, which is exactly why it could not see it.
# `due` also answers 0 when a raise NOW would do something the reminder window
# must not swallow (your-org/nexus-code#1653): an ESCALATION of the key's
# severity (F1 — only a caller that passes its severity can be told), and an
# EMAIL attempt that has come due (F3 retry, F4 confirmation). Reads only
# builtins: `due` runs on a 5 s cadence.
_operator_alert_due() {
    local key="${1:-}" want="${2:-}" stamp first last count pending memo sev m_first m_state m_att m_next
    _operator_alert_key_ok "$key" || return 1
    stamp=$(_operator_alert_stamp_path "$key")
    last=0; pending=""; first=""; count=0
    if [[ -f "$stamp" ]]; then
        { IFS=$'\t' read -r first last count pending < "$stamp"; } 2>/dev/null || true
        [[ "$pending" =~ ^[0-9]+$ ]] && return 0
        if [[ "$want" == critical ]]; then
            sev=""; { IFS= read -r sev < "$(_operator_alert_side "$key" sev)"; } 2>/dev/null || true
            [[ "$sev" == warning ]] && return 0      # the same readable-warning rule as raise's F1
        fi
        if { IFS=$'\t' read -r m_first m_state m_att m_next < "$(_operator_alert_side "$key" mail)"; } 2>/dev/null \
            && [[ "$m_first" == "$first" && ( "$m_state" == pending || "$m_state" == deferred ) && "$m_next" =~ ^[0-9]+$ ]] \
            && (( $(date +%s) >= m_next )); then
            return 0
        fi
    fi
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    memo=$(_operator_alert_memo_last "$key"); (( memo > last )) && last=$memo
    (( last > 0 )) || return 0
    # The SAME schedule raise applies (#1713): `due` and `raise` disagreeing
    # would either compose messages nobody sends or swallow a due reminder.
    (( $(date +%s) - last >= $(_operator_alert_reminder_after "$count") ))
}

_operator_alert_raise() {
    local key="${1:-}" severity="${2:-critical}" msg="${3:-}"
    local stamp first last count now kind reminder
    _operator_alert_key_ok "$key" || { "$_OPERATOR_ALERT_LOG_FN" "operator-alert: REFUSED raise — bad key '${key}'"; return 0; }
    [[ -n "$msg" ]] || msg="(no message)"
    case "$severity" in critical|warning) ;; *) severity=critical ;; esac
    now=$(date +%s)
    stamp=$(_operator_alert_stamp_path "$key")
    reminder=$(_operator_alert_reminder)
    first=""; last=""; count=0; local pending=""
    if [[ -f "$stamp" ]]; then
        { IFS=$'\t' read -r first last count pending < "$stamp"; } 2>/dev/null || true
        [[ "$first" =~ ^[0-9]+$ ]] || first="$now"
        [[ "$last"  =~ ^[0-9]+$ ]] || last=0
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        if [[ "$pending" =~ ^[0-9]+$ ]]; then
            # A clear was pending and the condition is BACK: a FLAP. Cancel the
            # pending clear; from the operator's side nothing changed, so no
            # leg fires. Recorded, so a flapping condition is visible in the
            # ledger even though it never rings twice.
            { printf '%s\t%s\t%s\t\n' "$first" "$last" "$count" > "$stamp"; } 2>/dev/null || true
            _operator_alert_record flap "$key" pending_s="$(( now - pending ))" standing_s="$(( now - first ))"
            "$_OPERATOR_ALERT_LOG_FN" "operator-alert: FLAP key=${key} — cleared ${pending}s ago, back again; the pending clear is cancelled (no re-ring, no re-file)"
            pending=""
        fi
        kind=continues
    else
        first="$now"; kind=began
    fi
    # F2: the last announcement is the MAX of the stamp and the memos, so a
    # stamp that is absent, zero-byte or unwritable cannot reset the cadence.
    local memo_last; memo_last=$(_operator_alert_memo_last "$key")
    if (( memo_last > last )); then
        last=$memo_last
        kind=continues            # announced before, whatever the stamp says
    fi
    # ---- the incident's email (your-org/nexus-code#1653) ----
    local sevf mailf tombf announced="" m_first="" m_state="" m_att=0 m_next=0 mail_due=0 cleared_at=""
    sevf=$(_operator_alert_side "$key" sev); mailf=$(_operator_alert_side "$key" mail); tombf=$(_operator_alert_side "$key" cleared)
    if [[ "$kind" == began ]]; then
        # F4: the same key back within REARM of its last clear is a RESUMED
        # incident — announced on every leg but email, and its email DEFERRED.
        { IFS= read -r cleared_at < "$tombf"; } 2>/dev/null || true
        if [[ "$cleared_at" =~ ^[0-9]+$ ]] && (( now - cleared_at < $(_operator_alert_rearm) )); then
            kind=resumed
            # A resume whose confirmation is ALREADY due (the chain has stood
            # long enough, the rate cap has passed) confirms NOW, in this raise:
            # waiting for the next tick lost the email whenever the episode
            # lasted one tick (property seed 615; LIVENESS-C) — and lagged it
            # by a tick otherwise (seeds 327, 644).
            if [[ "$severity" == critical ]]; then
                local r_acc=0 r_em=0 r_last=0 r_next
                { IFS=$'\t' read -r r_acc r_em r_last < "$(_operator_alert_side "$key" chain)"; } 2>/dev/null || true
                [[ "$r_acc" =~ ^[0-9]+$ ]] || r_acc=0; [[ "$r_em" =~ ^[01]$ ]] || r_em=0; [[ "$r_last" =~ ^[0-9]+$ ]] || r_last=0
                if (( r_em )); then r_next=$(( now + $(_operator_alert_rearm_confirm) ))
                else r_next=$(( now + $(_operator_alert_rearm_confirm) - r_acc )); (( r_next < now )) && r_next=$now; fi
                (( r_last + reminder > r_next )) && r_next=$(( r_last + reminder ))
                (( r_next <= now )) && kind=resumed-confirmed
            fi
        else
            rm -f "$tombf" "$mailf" "$sevf" "$(_operator_alert_side "$key" chain)" "$(_operator_alert_side "$key" ghreminders)" 2>/dev/null || true
        fi
    else
        { IFS= read -r announced < "$sevf"; } 2>/dev/null || announced=unreadable
        if { IFS=$'\t' read -r m_first m_state m_att m_next < "$mailf"; } 2>/dev/null \
            && [[ "$m_first" == "$first" && ( "$m_state" == pending || "$m_state" == deferred ) && "$m_next" =~ ^[0-9]+$ ]] \
            && (( now >= m_next )); then
            mail_due=1
        fi
        [[ "$m_att" =~ ^[0-9]+$ ]] || m_att=0
        if [[ "$severity" == critical && "$announced" == warning ]]; then
            # F1: severity is re-evaluated on every raise. A key ANNOUNCED as
            # warning that is now critical ESCALATES — an email-worthy event,
            # once: `.sev` then records critical. Only a READABLE `.sev` saying
            # warning escalates. An unreadable one (a state dir that cannot be
            # written, or a stamp older than this code) does not, because in the
            # unwritable case it could never record the escalation and EVERY
            # raise would re-announce — measured: 21 bells and pushes for 21
            # raises. Stated cost: in those two cases a warning key cannot
            # escalate by email.
            kind=escalated
        elif (( mail_due )) && [[ "$m_state" == deferred && "$severity" == critical ]]; then
            # F4: still standing REARM_CONFIRM after resuming. ONLY at critical:
            # a deferred confirmation that comes due while the key stands at
            # WARNING sends no email, so it must not confirm — it used to, and
            # recorded a last_email that was never sent, rate-capping the next
            # genuine critical run out of its email (property test, seed 161).
            kind=confirmed
        fi
    fi
    if [[ "$kind" == continues ]] && (( now - last < $(_operator_alert_reminder_after "$count") )); then
        # Inside the reminder window: SILENT (see the cadence note) — unless the
        # incident's email is due for a RETRY (F3), which goes out email-only.
        # A RETRY is only of an email already attempted (`pending`); a
        # `deferred` one that is due at warning waits for critical (seed 161).
        (( mail_due )) && [[ "$m_state" == pending ]] || return 0
        m_att=$(( m_att + 1 ))
        _operator_alert_mail_put "$key" "$first" pending "$m_att" "$(( now + $(_operator_alert_mail_backoff "$m_att") ))"
        _operator_alert_record mail-retry "$key" attempt="$m_att"
        "$_OPERATOR_ALERT_LOG_FN" "operator-alert: EMAIL RETRY #${m_att} key=${key} — the incident's email has not been reported delivered"
        MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false _operator_alert_network "$key" critical mail-retry "$msg" "$first"
        return 0
    fi
    count=$(( count + 1 ))
    mkdir -p "$(dirname "$stamp")" 2>/dev/null || true
    { printf '%s\t%s\t%s\t\n' "$first" "$now" "$count" > "$stamp"; } 2>/dev/null || true
    # Did ANY persistent store take it? Read the stamp back rather than trust
    # the write's status (a zero-byte unwritable file "succeeds" at nothing).
    local persisted=0 _rb=""
    { IFS=$'\t' read -r _ _rb _ _ < "$stamp"; } 2>/dev/null || true
    [[ "$_rb" == "$now" ]] && persisted=1
    _operator_alert_memo_set "$key" "$now" && persisted=1
    local standing_for=$(( now - first ))
    # The incident's durable email state, written BEFORE the network leg runs so
    # a result can only ever settle an attempt that is already on record.
    case "$kind" in
        began|resumed) { printf '%s\n' "$severity" > "$sevf"; } 2>/dev/null || true ;;
        escalated|confirmed|resumed-confirmed) { printf 'critical\n' > "$sevf"; } 2>/dev/null || true ;;
    esac
    local chainf c_acc=0 c_emailed=0 c_last=0 c_rem c_next
    chainf=$(_operator_alert_side "$key" chain)
    { IFS=$'\t' read -r c_acc c_emailed c_last < "$chainf"; } 2>/dev/null || true
    [[ "$c_acc" =~ ^[0-9]+$ ]] || c_acc=0; [[ "$c_emailed" =~ ^[01]$ ]] || c_emailed=0; [[ "$c_last" =~ ^[0-9]+$ ]] || c_last=0
    case "$kind" in
        began)     # last_email only if this began actually EMAILS (critical);
                   # a warning began must not rate-cap a later confirmation
                   # against an email that was never sent (LIVENESS).
                   if [[ "$severity" == critical ]]; then c_last=$now; else c_last=0; fi
                   { printf '0\t0\t%s\n' "$c_last" > "$chainf"; } 2>/dev/null || true ;;
        confirmed|resumed-confirmed) { printf '%s\t1\t%s\n' "$c_acc" "$now" > "$chainf"; } 2>/dev/null || true ;;
    esac
    if [[ "$severity" == critical ]]; then
        case "$kind" in
            began|escalated|confirmed|resumed-confirmed)
                _operator_alert_mail_put "$key" "$first" pending 1 "$(( now + $(_operator_alert_mail_backoff 1) ))" ;;
            resumed)
                if (( c_emailed )); then
                    # LATCHED (the chain already emailed): the cumulative path
                    # is closed, but this episode still confirms if it stands
                    # CONTINUOUSLY for REARM_CONFIRM — no sooner than a reminder
                    # period after the chain's last email (H1). A clear before
                    # then removes `.mail`, so only continuous standing fires it.
                    c_next=$(( now + $(_operator_alert_rearm_confirm) ))
                else
                    # G1: deferred only by what the chain has NOT yet stood.
                    c_rem=$(( $(_operator_alert_rearm_confirm) - c_acc )); (( c_rem < 0 )) && c_rem=0
                    c_next=$(( now + c_rem ))
                fi
                # SAFETY (the rate invariant): no confirmation sooner than a
                # reminder period after the key's last began/confirmed email.
                (( c_last + reminder > c_next )) && c_next=$(( c_last + reminder ))
                _operator_alert_mail_put "$key" "$first" deferred 0 "$c_next" ;;
        esac
    fi
    _operator_alert_record raise "$key" severity="$severity" kind="$kind" \
        standing_s="$standing_for" n="$count" next_reminder_s="$(_operator_alert_reminder_after "$count")" message="$msg"
    if [[ "$kind" == began ]]; then
        "$_OPERATOR_ALERT_LOG_FN" "operator-alert: RAISED key=${key} severity=${severity} — ${msg} [record: $(_operator_alert_log_path)]"
    elif [[ "$kind" == resumed-confirmed ]]; then
        "$_OPERATOR_ALERT_LOG_FN" "operator-alert: RESUMED+CONFIRMED key=${key} severity=${severity} $(( now - cleared_at ))s after its last clear — the chain's confirmation was already due — ${msg}"
    elif [[ "$kind" == resumed ]]; then
        "$_OPERATOR_ALERT_LOG_FN" "operator-alert: RESUMED key=${key} severity=${severity} $(( now - cleared_at ))s after its last clear — its email is deferred $(_operator_alert_rearm_confirm)s and sent only if it is still standing then — ${msg}"
    elif [[ "$kind" == escalated || "$kind" == confirmed ]]; then
        "$_OPERATOR_ALERT_LOG_FN" "operator-alert: ${kind^^} key=${key} severity=${severity} standing for ${standing_for}s — ${msg}"
    else
        "$_OPERATOR_ALERT_LOG_FN" "operator-alert: REMINDER #${count} key=${key} severity=${severity} standing for ${standing_for}s; next reminder in $(_operator_alert_reminder_after "$count")s (#1713 backoff) — ${msg}"
    fi
    if [[ "$severity" == critical ]]; then
        "$_OPERATOR_ALERT_BELL_FN" "$msg" || true
    fi
    if (( persisted )); then
        _operator_alert_network "$key" "$severity" "$kind" "$msg" "$first"
        if [[ "$kind" == continues ]] && (( mail_due )) && [[ "$m_state" == pending ]]; then
            # A reminder (routine) that finds the incident's email still due:
            # retry it too, email-only (F3).
            m_att=$(( m_att + 1 ))
            _operator_alert_mail_put "$key" "$first" pending "$m_att" "$(( now + $(_operator_alert_mail_backoff "$m_att") ))"
            _operator_alert_record mail-retry "$key" attempt="$m_att"
            MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false _operator_alert_network "$key" critical mail-retry "$msg" "$first"
        fi
    elif [[ "$kind" == began || "$kind" == resumed* ]] && _operator_alert_sentinel_alive "$key"; then
        # A degraded attempt already ran within the reminder period and could
        # remember it only in its sentinel (#1567 G4): the issue it filed or
        # found is still there, so the list read would buy nothing.
        _operator_alert_record network-skipped "$key" kind="$kind" reason=nothing-persisted-attempted
    elif [[ "$kind" == began || "$kind" == resumed* ]]; then
        # Nothing could be persisted, not even under $TMPDIR, so a caller in a
        # SUBSHELL would re-announce every cycle. The GitHub leg is idempotent
        # over the network (it reuses the open issue and comments nothing on
        # reuse), so it runs ONCE per sentinel lifetime; the PUSH is the
        # repeatable leg, so it does not run at all.
        _operator_alert_sentinel_start "$key"
        _operator_alert_record network-degraded "$key" kind="$kind" reason=nothing-persisted note="push skipped; github leg runs once per reminder period (sentinel)"
        MONITOR_OPERATOR_ALERT_PUSH_ENABLED=false _operator_alert_network "$key" "$severity" "$kind" "$msg"
    else
        _operator_alert_record network-skipped "$key" kind="$kind" reason=nothing-persisted
    fi
    return 0
}

_operator_alert_notify() {
    local key="${1:-}" severity="${2:-critical}" msg="${3:-}"
    _operator_alert_key_ok "$key" || { "$_OPERATOR_ALERT_LOG_FN" "operator-alert: REFUSED notify — bad key '${key}'"; return 0; }
    [[ -n "$msg" ]] || msg="(no message)"
    case "$severity" in critical|warning) ;; *) severity=critical ;; esac
    _operator_alert_record notify "$key" severity="$severity" message="$msg"
    "$_OPERATOR_ALERT_LOG_FN" "operator-alert: NOTIFY key=${key} severity=${severity} — ${msg}"
    if [[ "$severity" == critical ]]; then
        "$_OPERATOR_ALERT_BELL_FN" "$msg" || true
    fi
    # An event files no issue: push only.
    MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false _operator_alert_network "$key" "$severity" event "$msg"
    return 0
}

_operator_alert_clear() {
    local key="${1:-}" msg="${2:-cleared}" stamp first last count pending now dur holddown
    _operator_alert_key_ok "$key" || return 0
    stamp=$(_operator_alert_stamp_path "$key")
    if [[ ! -f "$stamp" ]]; then
        # No stamp. Either nothing is standing, or the raise could only be
        # remembered in the memo (F2: an unwritable state dir). A memo-only
        # key cannot carry a pending mark, so it clears at once.
        local memo_first; memo_first=$(_operator_alert_memo_last "$key")
        (( memo_first > 0 )) || return 0
        _operator_alert_memo_clear "$key"
        _operator_alert_record clear "$key" duration_s=-1 message="$msg" note="memo-only key (the stamp was never persistable)"
        "$_OPERATOR_ALERT_LOG_FN" "operator-alert: CLEARED key=${key} (memo-only) — ${msg}"
        "$_OPERATOR_ALERT_CLEARED_FN" "$key" "$memo_first" || true
        return 0
    fi
    { IFS=$'\t' read -r first last count pending < "$stamp"; } 2>/dev/null || first=""
    now=$(date +%s)
    holddown=$(_operator_alert_holddown)
    if (( holddown > 0 )); then
        if ! [[ "$pending" =~ ^[0-9]+$ ]]; then
            # First "absent" after a raise: START the hold-down, finalise
            # nothing. The caller says "absent" again every cycle.
            { printf '%s\t%s\t%s\t%s\n' "$first" "${last:-$now}" "${count:-1}" "$now" > "$stamp"; } 2>/dev/null || true
            _operator_alert_record clear-pending "$key" holddown_s="$holddown"
            # THE transition (#1567 G2): the condition just went absent. Fired
            # here, not at finalisation, because the hold-down is for the
            # OPERATOR's channel (no close/reopen churn); a caller that wants to
            # act on recovery should not wait 300 s to learn of it. A flap back
            # cancels the pending clear and the next first-absent fires again.
            "$_OPERATOR_ALERT_CLEARED_FN" "$key" "$first" || true
            return 0
        fi
        (( now - pending >= holddown )) || return 0    # still inside the hold-down
    fi
    if [[ "$first" =~ ^[0-9]+$ ]]; then dur=$(( now - first )); else dur=-1; fi
    # G1: a RESUMED episode that cleared without emailing adds its standing time
    # (raise → the condition going absent) to the chain's cumulative total.
    local c_first c_state c_att c_next c_acc=0 c_emailed=0 c_last=0 c_end chainf
    chainf=$(_operator_alert_side "$key" chain)
    if { IFS=$'\t' read -r c_first c_state c_att c_next < "$(_operator_alert_side "$key" mail)"; } 2>/dev/null \
        && [[ "$c_state" == deferred && "$c_first" == "$first" && "$first" =~ ^[0-9]+$ ]]; then
        { IFS=$'\t' read -r c_acc c_emailed c_last < "$chainf"; } 2>/dev/null || true
        [[ "$c_acc" =~ ^[0-9]+$ ]] || c_acc=0; [[ "$c_emailed" =~ ^[01]$ ]] || c_emailed=0; [[ "$c_last" =~ ^[0-9]+$ ]] || c_last=0
        if [[ "$pending" =~ ^[0-9]+$ ]]; then c_end=$pending; else c_end=$now; fi
        (( c_end > first )) && c_acc=$(( c_acc + c_end - first ))
        { printf '%s\t%s\t%s\n' "$c_acc" "$c_emailed" "$c_last" > "$chainf"; } 2>/dev/null || true
        _operator_alert_record chain-accumulated "$key" episode_s="$(( c_end - first ))" acc_s="$c_acc"
    fi
    rm -f "$stamp" "$(_operator_alert_side "$key" sev)" "$(_operator_alert_side "$key" mail)" "$(_operator_alert_side "$key" ghreminders)" 2>/dev/null || true
    # F4: when this key last cleared — a raise within REARM of it is RESUMED.
    { printf '%s\n' "$now" > "$(_operator_alert_side "$key" cleared)"; } 2>/dev/null || true
    _operator_alert_memo_clear "$key"
    _operator_alert_record clear "$key" duration_s="$dur" message="$msg" \
        holddown_s="$holddown"
    "$_OPERATOR_ALERT_LOG_FN" "operator-alert: CLEARED key=${key} after ${dur}s — ${msg}"
    _operator_alert_network "$key" warning clear "$msg (stood for ${dur}s)"
    # With no hold-down this finalising call IS the transition; with one, the
    # transition already fired when the hold-down started.
    (( holddown > 0 )) || "$_OPERATOR_ALERT_CLEARED_FN" "$key" "$first" || true
    return 0
}
