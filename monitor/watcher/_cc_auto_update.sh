#!/usr/bin/env bash
# Watcher autonomous daily Claude Code update routine (the 04:00 trigger).
#
# This module is the DRIVE half that closes the gated self-update loop
# end-to-end without an operator in the common case:
#
#   detect (cc_version_check / this task's own fresh decide)
#     → 04:00 daily fire (this task)
#     → spawn the AUTONOMOUS EVALUATOR worker (tmux window, prompt from
#       monitor/cc-auto-update-prompt.md)
#     → the evaluator runs skills/nexus.cc-update/GUIDE.md Steps 1–4
#       (changelog → collision analysis → cc-harness gate → decision)
#     → branch:
#         safe       → monitor/cc-auto-update-apply.sh safe …
#                      (GUIDE Step 5 pin bump + Step 5b watchdog'd
#                      orchestrator restart, fully autonomous)
#         compat-pr  → check existing open compat PR on the nexus-code
#                      repo; comment findings on it, else open one and
#                      HOLD for operator approval (never bump)
#         block      → record + surface; never bump
#
# Why a watcher scheduler task and not a harness CronCreate: a recurring
# CronCreate auto-expires in 7 days and dies with the orchestrator
# session (its `durable: true` flag is silently ignored — see
# skills/nexus.cron-state-tsv). The watcher outlives orchestrator
# respawns by design (it is what respawns them), and every bit of this
# task's bookkeeping lives in on-disk state files, so a watcher restart
# resumes the cadence losslessly: the next tick re-reads the same
# last-fire-date stamp and the daily semantics hold.
#
# Time-of-day semantics (anacron-style catch-up): the task is due when
# `now >= today@fire_time` AND the last-fire-date stamp != today. A
# watcher that was down at 04:00 fires on its first due tick after
# coming back; a watcher restarted at 17:00 after a 04:10 fire does NOT
# re-fire (the stamp says today).
#
# Fail-safe by construction, mirroring _cc_update.sh: a registry-fetch
# failure stamps NOTHING (the next tick retries, bounded by the day
# window); every uncertain path declines to spawn; the spawned
# evaluator's own decision rules treat residual uncertainty as block.
# Nothing in this module ever writes the version pin — only
# cc-auto-update-apply.sh's `safe` verb does, and only behind gate
# evidence.
#
# Idempotency layers:
#   1. last-fire-date stamp        — at most one fire per calendar day.
#   2. evaluator-window-LIVE       — never two concurrent evaluators
#      (plus spawn-worker.sh's own exit-7 window-name collision guard).
#      DEFERS the day, it does not consume it: this arm must NOT stamp
#      last-fire-date, or a crashed-but-alive window cancels the round
#      instead of postponing it (your-org/nexus-code#968). Its own
#      `last-skip-date` marker keeps the audit row once-per-day while
#      the fire itself retries every tick.
#      LIVE, not merely PRESENT: window existence is a proxy for "an
#      evaluator is working", and a crashed session keeps its pane alive
#      forever. A pane POSITIVELY stalled for
#      CC_AUTO_EVALUATOR_STALE_SECONDS is reclaimed; every other reading
#      (working, indeterminate, stall too young) still defers — an
#      allowlist with a default-DENY arm, because the fire path KILLS
#      that window before spawning. And CC_AUTO_SKIP_STREAK_ALERT
#      consecutive deferred days notify the operator: a round that has
#      stopped running must not be visible only as a TSV row nobody
#      reads, which is exactly how #968 survived.
#   3. already-pinned              — `_cc_update_decide` rc=1 (current)
#      when candidate == effective version; no re-eval of a version
#      already running.
#   4. awaiting-operator           — a candidate whose last recorded
#      outcome was block / compat-pr-* is NOT re-evaluated daily; a
#      NEWER candidate re-arms (same model as cc-update-surfaced).
#
# Audit: every decision appends a TSV row to
# `monitor/.state/cc-auto-update/decisions.tsv`
# (ts<TAB>candidate<TAB>decision<TAB>detail), and fires log via the
# watcher log in the existing `cc-update FIRED` convention
# (`cc-auto-update FIRED: …`).
#
# All functions are file-state only (safe for an --async subshell) and
# free of side effects on source. Tests inject time via NEXUS_TEST_NOW
# (through nexus_clock when the scheduler is loaded, with a local
# fallback), the registry fetch via the fetch_cmd indirection, and the
# spawn/tmux surfaces via CC_AUTO_SPAWN_CMD / function override.

# ---- double-source guard ------------------------------------------------
if [[ -n "${_NEXUS_CC_AUTO_UPDATE_LOADED:-}" ]]; then
    return 0
fi
_NEXUS_CC_AUTO_UPDATE_LOADED=1

# `_ensure_service_log` (your-org/nexus-code#484/#509): every log this
# module appends to is created 0640, never group-writable. Pure-bash
# path derivation (no dirname — see nexus-code#513's portability aside).
_cc_auto_module_dir="${BASH_SOURCE[0]%/*}"
[[ "$_cc_auto_module_dir" == "${BASH_SOURCE[0]}" ]] && _cc_auto_module_dir=.
# shellcheck source=../_log-mode.sh
source "$_cc_auto_module_dir/../_log-mode.sh"
unset _cc_auto_module_dir

# Evaluator window name. Fixed so the window-alive guard and
# spawn-worker's collision check both key off one canonical name.
: "${CC_AUTO_WINDOW:=cc-auto-update}"

# Restart-watchdog window name — MUST match cc-auto-update-apply.sh's
# WATCHDOG_WINDOW so the reconciliation's single-flight guard sees the
# very window the detached `restart-orchestrator` hand-off spawns.
: "${CC_AUTO_WATCHDOG_WINDOW:=cc-restart-watchdog}"

# _cc_auto_clock — wall-clock indirection. Uses the scheduler's
# nexus_clock when loaded (NEXUS_TEST_NOW-aware); falls back to
# honouring NEXUS_TEST_NOW directly so the module is testable
# standalone.
_cc_auto_clock() {
    if declare -F nexus_clock >/dev/null 2>&1; then
        nexus_clock
    elif [[ -n "${NEXUS_TEST_NOW:-}" ]]; then
        printf '%s\n' "$NEXUS_TEST_NOW"
    else
        date +%s
    fi
}

# _cc_auto_day <epoch> — calendar day (local tz) for an epoch.
_cc_auto_day() {
    date -d "@${1:?epoch required}" +%Y-%m-%d
}

# _cc_auto_fire_epoch <now_epoch> <HH:MM>
#
# Epoch of TODAY's fire time (local tz), where "today" is the calendar
# day containing <now_epoch>. Prints the epoch; rc non-zero on a
# malformed fire time (callers fall back to the default).
_cc_auto_fire_epoch() {
    local now="${1:?now required}" fire="${2:?fire_time required}"
    [[ "$fire" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || return 1
    local day
    day=$(_cc_auto_day "$now") || return 1
    date -d "$day $fire" +%s 2>/dev/null
}

# _cc_auto_due <now_epoch> <HH:MM> <stamp_file>
#
# rc 0 iff the daily routine should fire: now is at/past today's fire
# time and the stamp file does not already record today. Pure read.
_cc_auto_due() {
    local now="${1:?now required}" fire="${2:?fire_time required}" stamp="${3:?stamp required}"
    local fire_epoch
    fire_epoch=$(_cc_auto_fire_epoch "$now" "$fire") || fire_epoch=$(_cc_auto_fire_epoch "$now" "04:00")
    [[ -n "$fire_epoch" ]] || return 1
    (( now >= fire_epoch )) || return 1
    local today last=""
    today=$(_cc_auto_day "$now")
    [[ -f "$stamp" ]] && last=$(tr -d '[:space:]' < "$stamp" 2>/dev/null || true)
    [[ "$last" != "$today" ]]
}

# _cc_auto_stamp <stamp_file> <now_epoch> — record today as fired
# (atomic tmp+rename so a torn write never half-stamps).
_cc_auto_stamp() {
    local stamp="${1:?stamp required}" now="${2:?now required}"
    mkdir -p "$(dirname "$stamp")" 2>/dev/null || true
    local tmp="$stamp.tmp.$$"
    _cc_auto_day "$now" > "$tmp" 2>/dev/null && mv -f "$tmp" "$stamp" 2>/dev/null \
        || rm -f "$tmp" 2>/dev/null || true
}

# _cc_auto_log_decision <auto_dir> <candidate> <decision> [detail]
#
# Append one audit row: ts<TAB>candidate<TAB>decision<TAB>detail.
# Append-only TSV per skills/nexus.cron-state-tsv discipline; never
# fails the caller.
_cc_auto_log_decision() {
    local dir="${1:?dir required}" candidate="${2:?candidate required}"
    local decision="${3:?decision required}" detail="${4:-}"
    mkdir -p "$dir" 2>/dev/null || return 0
    local ts
    ts=$(date -Is 2>/dev/null || echo unknown)
    printf '%s\t%s\t%s\t%s\n' "$ts" "$candidate" "$decision" "$detail" \
        >> "$dir/decisions.tsv" 2>/dev/null || true
}

# _cc_auto_surface_safe_refused <auto_dir> <candidate> <now>
#
# your-org/nexus-code#1400. If the last recorded outcome is `safe-refused`,
# log it and notify, at most once per day (stamp `last-safe-refused-nag-date`),
# and escalate when the two most recent safe-refused rows in decisions.tsv
# carry the SAME detail — the same reason twice is a standing defect in the
# gate, which is exactly the case that went unnoticed for two days.
_cc_auto_surface_safe_refused() {
    local dir="${1:?dir required}" candidate="${2:-?}" now="${3:-$(date +%s)}"
    local f="$dir/last-eval" decision detail last_cand
    [[ -f "$f" ]] || return 0
    decision=$(_cc_update_field "$f" decision 2>/dev/null || true)
    [[ "$decision" == "safe-refused" ]] || return 0
    detail=$(_cc_update_field "$f" detail 2>/dev/null || true)
    last_cand=$(_cc_update_field "$f" candidate 2>/dev/null || true)
    local today stamp last_nag=""
    today=$(date -d "@$now" +%F 2>/dev/null || date +%F)
    stamp="$dir/last-safe-refused-nag-date"
    [[ -f "$stamp" ]] && last_nag=$(tr -d '[:space:]' < "$stamp" 2>/dev/null || true)
    [[ "$last_nag" == "$today" ]] && return 0
    printf '%s\n' "$today" > "$stamp" 2>/dev/null || true
    # repetition: the two most recent safe-refused rows share a detail
    local n_same=0
    if [[ -r "$dir/decisions.tsv" ]]; then
        n_same=$(awk -F'\t' -v d="$detail" '$3=="safe-refused"{r[++n]=$4} END{c=0; for(i=n;i>=1&&r[i]==d;i--)c++; print c+0}' "$dir/decisions.tsv" 2>/dev/null || echo 0)
        [[ "$n_same" =~ ^[0-9]+$ ]] || n_same=0
    fi
    local kind="safe-refused-unapplied" msg
    msg="cc-auto-update: candidate ${last_cand:-$candidate} evaluated SAFE but was NOT applied (${detail:-no detail}) — a defect in the gate, not in the candidate; the pin stays stale until someone looks (#1400)"
    if (( n_same >= 2 )); then
        kind="safe-refused-repeat"
        msg="cc-auto-update: SAME safe-refused reason ${n_same} fires running (${detail:-no detail}) for ${last_cand:-$candidate} — a STANDING defect in the gate, not a transient tree state; the pin has been stale that many days (#1400)"
    fi
    _cc_auto_log_decision "$dir" "${last_cand:-$candidate}" "$kind" "${detail:-} same-reason-streak=$n_same"
    declare -F log >/dev/null 2>&1 && log "$msg"
    command -v sandbox-notify >/dev/null 2>&1 && sandbox-notify "$msg" || true
    return 0
}

# _cc_auto_last_eval_skip <auto_dir> <candidate>
#
# rc 0 iff <candidate> was already evaluated and its outcome is
# AWAITING THE OPERATOR (block / compat-pr-opened / compat-pr-commented)
# — re-running daily would only spam the surface. A different (newer)
# candidate, an absent file, or a non-terminal outcome all return
# non-zero (do not skip). The last-eval file is written by
# cc-auto-update-apply.sh's outcome recorder in the same key=value
# shape _cc_update_field parses.
_cc_auto_last_eval_skip() {
    local dir="${1:?dir required}" candidate="${2:?candidate required}"
    local f="$dir/last-eval"
    [[ -f "$f" ]] || return 1
    local last decision
    last=$(_cc_update_field "$f" candidate 2>/dev/null || true)
    [[ "$last" == "$candidate" ]] || return 1
    decision=$(_cc_update_field "$f" decision 2>/dev/null || true)
    case "$decision" in
        block|compat-pr-opened|compat-pr-commented) return 0 ;;
        *) return 1 ;;
    esac
}

# _cc_auto_window_alive <window>
#
# rc 0 iff a tmux window of that name exists with a LIVE pane. Tests
# override this function. A dead remain-on-exit pane does not block a
# fresh fire (spawn-worker --resume-style replacement is not needed; we
# kill the dead window before spawning).
_cc_auto_window_alive() {
    local window="${1:?window required}"
    grep -Fxq -- "$window" <<<"$(tmux list-windows -F '#W' 2>/dev/null)" || return 1
    local dead
    dead=$(tmux display-message -p -t "$window" '#{pane_dead}' 2>/dev/null || echo "")
    [[ "$dead" != "1" ]]
}

# ---- evaluator LIVENESS, not merely window existence (#968 part 2) --------
#
# `_cc_auto_window_alive` answers "does a window of this name exist with a
# live pane". That is a PROXY for "an evaluator is working", and on
# 2026-08-20 the two came apart: an evaluator whose turn crashed on
# `Login expired` two minutes after spawn kept its pane alive indefinitely.
# The window existed, no work was happening, and the guard could not tell
# the difference — so the round deferred forever instead of once.
#
# DIRECTION OF THE DEFAULT. The dangerous act here is PROCEEDING, not
# deferring: the fire path below KILLS $CC_AUTO_WINDOW (the dead
# remain-on-exit cleanup) before spawning, so a wrong "not working"
# verdict destroys a live evaluator mid-run. Deferring costs one tick
# (`check_interval_seconds`, 300 s by default) and is now a real retry
# rather than a cancellation. So this is an ALLOWLIST with a
# default-DENY arm: only a reading that POSITIVELY establishes a stall,
# sustained, lets the round reclaim the window.
#
# Arm-order shadowing (your-org/nexus-code#1121) cannot bite here: both
# lists are matched by exact string equality over sets measured
# DISJOINT, so no input matches two arms and no reordering changes an
# answer. That is a property of the arms, not luck — it would stop
# holding the day either list gained a glob.

# States that positively assert the evaluator is DRIVING WORK FORWARD.
_CC_AUTO_WORKING_STATES=(busy user-typing working-background working-self-paced)
# States that positively assert it is NOT: no turn is running and nothing
# resumes one without a human. Reclaimable — but only after
# CC_AUTO_EVALUATOR_STALE_SECONDS of CONTINUOUS stall, so an evaluator
# read in the seconds between window creation and its first turn is
# never mistaken for a corpse.
_CC_AUTO_STALLED_STATES=(idle autosuggest-only blocked over-limit absent idle-orphan-async)
# Everything else — `empty`, `unknown`, an unreadable probe, and any
# state this file has never heard of — is INDETERMINATE and denies.
# DO NOT hand-maintain these against a copied vocabulary list: the
# terminal arm is what covers a state added upstream, and
# test-cc-auto-update.sh asserts every member of
# `monitor/pane-state.sh --states` lands in exactly one class.

# How long a pane must stay continuously stalled before the round may
# reclaim its window. 30 min: far longer than any legitimate pause
# between an evaluator's turns, far shorter than a day.
: "${CC_AUTO_EVALUATOR_STALE_SECONDS:=1800}"
# Consecutive DEFERRED days after which the operator is told the routine
# has stopped running. One skip is routine; two is a stuck round.
: "${CC_AUTO_SKIP_STREAK_ALERT:=2}"

# _cc_auto_evaluator_class <window> [nexus_root]
#
# Prints `<class> <state>` where class is working|stalled|indeterminate.
# Never fails; an unreadable probe is a class, not an error.
_cc_auto_evaluator_class() {
    local window="${1:?window required}" nexus_root="${2:-.}"
    local cmd raw state="" s
    cmd="${CC_AUTO_PANE_STATE_CMD:-$nexus_root/monitor/pane-state.sh}"
    raw=""
    if [[ -x "$cmd" ]]; then
        raw=$("$cmd" "$window" 2>/dev/null) || raw=""
    fi
    # Parsed with a bash match rather than a `| sed | head` pipeline: the
    # pipeline's exit status would be `head`'s, and under pipefail an
    # early-closing `head` reports 141 for a perfectly good read.
    [[ "$raw" =~ state=([a-z-]+) ]] && state="${BASH_REMATCH[1]}"
    if [[ -z "$state" ]]; then
        printf 'indeterminate unreadable\n'
        return 0
    fi
    # Input already queued behind the running turn is work in flight
    # whatever the base verdict says (your-org/nexus-code#607).
    case "$raw" in *queued=1*) printf 'working %s\n' "$state"; return 0 ;; esac
    for s in "${_CC_AUTO_WORKING_STATES[@]}"; do
        [[ "$state" == "$s" ]] && { printf 'working %s\n' "$state"; return 0; }
    done
    for s in "${_CC_AUTO_STALLED_STATES[@]}"; do
        [[ "$state" == "$s" ]] && { printf 'stalled %s\n' "$state"; return 0; }
    done
    printf 'indeterminate %s\n' "$state"
}

# _cc_auto_evaluator_stale <auto_dir> <window> <now_epoch> [nexus_root]
#
# rc 0 → the window is NOT a live evaluator: positively stalled for at
#        least CC_AUTO_EVALUATOR_STALE_SECONDS, so the round may reclaim
#        it.
# rc 1 → treat it as live. Covers working, indeterminate, and a stall
#        not yet old enough.
#
# Sets CC_AUTO_EVAL_CLASS / CC_AUTO_EVAL_STATE / CC_AUTO_EVAL_STALL_AGE
# for the caller's audit row, so the reading that produced the verdict
# is in the record rather than inferred from it.
_cc_auto_evaluator_stale() {
    local dir="${1:?dir required}" window="${2:?window required}"
    local now="${3:?now required}" nexus_root="${4:-.}"
    local marker="$dir/evaluator-stalled-since"
    local threshold="${CC_AUTO_EVALUATOR_STALE_SECONDS:-1800}"
    [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=1800

    local reading class state
    reading=$(_cc_auto_evaluator_class "$window" "$nexus_root")
    class="${reading%% *}"
    state="${reading#* }"
    CC_AUTO_EVAL_CLASS="$class"
    CC_AUTO_EVAL_STATE="$state"
    CC_AUTO_EVAL_STALL_AGE=0

    case "$class" in
        working)
            # Positive evidence of work is the ONLY thing that clears an
            # accrued stall. An indeterminate reading deliberately does
            # not: `empty` is a documented transient, and letting it
            # reset the clock would make a stall unaccruable — a pane
            # flickering idle/empty would defer forever, which is the
            # very failure this axis exists to end.
            rm -f "$marker" 2>/dev/null || true
            return 1
            ;;
        stalled) ;;
        *) return 1 ;;
    esac

    mkdir -p "$dir" 2>/dev/null || true
    local since=""
    [[ -f "$marker" ]] && since=$(tr -dc '0-9' < "$marker" 2>/dev/null || true)
    if [[ -z "$since" ]]; then
        printf '%s\n' "$now" > "$marker" 2>/dev/null || true
        return 1
    fi
    CC_AUTO_EVAL_STALL_AGE=$(( now - since ))
    (( CC_AUTO_EVAL_STALL_AGE >= threshold )) || return 1
    return 0
}

# _cc_auto_skip_streak_bump <auto_dir> — increment and print the count of
# CONSECUTIVE days on which the round deferred. Called once per deferred
# day (the caller's own once-per-day gate).
_cc_auto_skip_streak_bump() {
    # NOT one `local` statement: bash 4.4 evaluates every RHS of a single
    # `local` before assigning any of them, so `f="$dir/…"` on the same
    # line dies with `dir: unbound variable` under `set -u` — and the
    # caller then reads an EMPTY streak that coerces to 1 forever, which
    # is this bundle's own defect class (a guard that silently never
    # counts). Measured on bash 4.4.20, this host.
    local dir="${1:?dir required}"
    local f="$dir/skip-streak" n=0 first=""
    if [[ -f "$f" ]]; then
        n=$(_cc_update_field "$f" days 2>/dev/null || echo 0)
        first=$(_cc_update_field "$f" first 2>/dev/null || echo "")
    fi
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    n=$(( n + 1 ))
    [[ -n "$first" ]] || first=$(date -Is 2>/dev/null || echo unknown)
    mkdir -p "$dir" 2>/dev/null || true
    local tmp="$f.tmp.$$"
    { printf 'days=%s\nfirst=%s\nlast=%s\n' "$n" "$first" \
        "$(date -Is 2>/dev/null || echo unknown)"; } > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    printf '%s\n' "$n"
}

# _cc_auto_skip_streak_clear <auto_dir> — the round got past the guard.
_cc_auto_skip_streak_clear() {
    rm -f "${1:?dir required}/skip-streak" 2>/dev/null || true
}

# _cc_auto_render_prompt <template> <out> [KEY=VALUE]...
#
# Render the evaluator prompt: replace each {{KEY}} with VALUE via
# plain bash substitution (no sed, so values never need escaping).
# Fails (rc 1) when the template is missing — the caller must NOT
# spawn with an empty prompt.
_cc_auto_render_prompt() {
    local template="${1:?template required}" out="${2:?out required}"
    shift 2
    [[ -f "$template" ]] || return 1
    local body
    body=$(<"$template") || return 1
    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        body="${body//\{\{$key\}\}/$val}"
    done
    mkdir -p "$(dirname "$out")" 2>/dev/null || true
    printf '%s\n' "$body" > "$out"
}

# ---- restart hold (your-org/nexus-code#513) ------------------------------
# A deliberately-refused orchestrator restart must be REPRESENTABLE, or it
# cannot stay refused: the reconcile's fire predicate is the version split
# itself, and its single-flight guard is a `kill -0` on the detached
# restart's pid — so correctly SIGTERMing an unwanted restart is exactly
# what re-arms the next one, every cooldown period, forever (the
# 2026-07-10 live incident: abort at 04:08, auto-refire at 04:09:55).
#
# The hold is a durable key=value marker at
# `$auto_dir/restart-hold`, checked by the RUNNING watcher on every
# reconcile pass — unlike `monitor.cc_auto_update.enabled`, whose env var
# is resolved once at watcher startup (main.sh registration) and is
# therefore INERT as a hold on a live watcher. Fields:
#   reason=<free text>       required — why the restart is held
#   ts=<ISO>                 when the hold was written
#   expires=<epoch>          optional TTL — inactive once now >= expires
#   until_version=<X.Y.Z>    optional — holds candidates <= this version;
#                            a NEWER effective version re-arms (the same
#                            model as the daily guard's awaiting-operator
#                            skip: a hold is per-candidate, not forever)
# Written by cc-auto-update-apply.sh's `hold` verb (operator/agent) and
# by a SIGTERM'd detached restart (abort-on-purpose). Released by the
# `unhold` verb or by its own expiry terms.

# _cc_auto_write_restart_hold <auto_dir> <reason> [expires_epoch] [until_version]
#
# Write the hold marker atomically (tmp+rename) and append the audit
# row. rc 0 on success; non-zero when the marker cannot be written —
# callers that abort a restart MUST treat that as loud, not silent.
_cc_auto_write_restart_hold() {
    local dir="${1:?auto_dir required}" reason="${2:?reason required}"
    local expires="${3:-}" until_version="${4:-}"
    mkdir -p "$dir" 2>/dev/null || return 1
    local tmp="$dir/restart-hold.tmp.$$"
    {
        printf 'reason=%s\n' "$reason"
        printf 'ts=%s\n' "$(date -Is 2>/dev/null || echo unknown)"
        if [[ -n "$expires" ]];       then printf 'expires=%s\n' "$expires"; fi
        if [[ -n "$until_version" ]]; then printf 'until_version=%s\n' "$until_version"; fi
    } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv -f "$tmp" "$dir/restart-hold" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    _cc_auto_log_decision "$dir" "${until_version:--}" "restart-hold-set" \
        "reason=$reason${expires:+ expires=$expires}"
    return 0
}

# _cc_auto_restart_hold_active <auto_dir> <effective_version> [now_epoch]
#
# rc 0 iff a hold marker exists AND none of its expiry terms have lapsed:
#   - `expires` set and now >= expires            → inactive (TTL lapsed)
#   - `until_version` set and effective is NEWER  → inactive (re-armed)
# Pure read; an expired marker is left in place as evidence (the next
# `hold`/`unhold` overwrites/removes it).
_cc_auto_restart_hold_active() {
    local dir="${1:?auto_dir required}" effective="${2:?effective required}"
    local now="${3:-$(_cc_auto_clock)}"
    local f="$dir/restart-hold"
    [[ -f "$f" ]] || return 1
    local expires until_version
    expires=$(_cc_update_field "$f" expires 2>/dev/null || true)
    if [[ "$expires" =~ ^[0-9]+$ ]] && (( now >= expires )); then
        return 1
    fi
    until_version=$(_cc_update_field "$f" until_version 2>/dev/null || true)
    if [[ -n "$until_version" ]] \
       && [[ "$(_cc_update_compare "$until_version" "$effective")" == "newer" ]]; then
        return 1
    fi
    return 0
}

# ---- restart outcome marker + abort-streak escalation --------------------
# The detached `restart-orchestrator` verb decouples the idle-wait → kill
# from cmd_safe's 600s-bound foreground call (see the apply.sh header). A
# consequence the 2026-07 live incident made painfully clear
# (your-org/nexus-code#511): the child's terminal exit code lands in a
# detached log nothing reads, and the ONLY per-fire record is an
# append-only `decisions.tsv` row. Reading the *latest* restart outcome
# then meant `tail`-ing that TSV — which two separate evaluators did and
# both miscounted (published "17" and "12" for a true 468). And nothing
# escalated: the SAME `target-window-unresolved` abort recurred ~48×/day
# for 12 days with no signal above the per-fire noise.
#
# This marker fixes both. `$auto_dir/restart-outcome` is the SINGLE
# latest-state file (key=value, mirrors restart-hold) — a caller reads the
# real outcome deterministically instead of grepping the append-only log.
# And it carries an `abort_streak` that counts CONSECUTIVE aborts of the
# same first-token cause; when the streak crosses a threshold the routine
# shouts ONCE (a distinct `restart-abort-escalation` audit row + notify),
# and again every repeat-interval thereafter — so a stuck restart surfaces
# on day 1, not day 9. A non-abort outcome (restarted/forced/noop/held)
# resets the streak: only a genuine, repeating failure escalates.
#
# _cc_auto_write_restart_outcome <auto_dir> <status> <code> <detail> <candidate>
#   status   the decision string just recorded (safe-bumped-restart-*)
#   code     the process exit code for that terminal path
#   detail   the decision detail (its first whitespace-token is the cause)
#   candidate the version the restart targeted
# Always rc 0 (best-effort; never fails the terminal path it rides on).
_cc_auto_write_restart_outcome() {
    local dir="${1:?auto_dir required}" status="${2:?status required}"
    local code="${3:-0}" detail="${4:-}" candidate="${5:-}"
    mkdir -p "$dir" 2>/dev/null || return 0

    # First whitespace-token of the detail is the stable cause key: it
    # drops the per-fire `sid=…` tail so a recurring `pin-stale-pre-wait`
    # or `target-window-unresolved=orchestrator` reads as ONE continuing
    # streak, not a fresh one each fire.
    local cause="${detail%% *}"
    [[ -n "$cause" ]] || cause="$status"

    # An abort is the only streak-continuing outcome. A deliberate hold, a
    # no-op (the split healed itself), and a success all reset the count —
    # escalation is for a real, repeating failure, never for expected paths.
    local is_abort=0
    [[ "$status" == "safe-bumped-restart-aborted" ]] && is_abort=1

    local prev_streak=0 prev_cause=""
    if [[ -f "$dir/restart-outcome" ]]; then
        prev_streak=$(_cc_update_field "$dir/restart-outcome" abort_streak 2>/dev/null || echo 0)
        prev_cause=$(_cc_update_field "$dir/restart-outcome" cause 2>/dev/null || echo "")
        [[ "$prev_streak" =~ ^[0-9]+$ ]] || prev_streak=0
    fi

    local streak=0
    if (( is_abort )); then
        if [[ "$cause" == "$prev_cause" ]]; then
            streak=$(( prev_streak + 1 ))
        else
            streak=1
        fi
    fi

    local tmp="$dir/restart-outcome.tmp.$$"
    {
        printf 'outcome=%s\n'      "$status"
        printf 'code=%s\n'         "$code"
        printf 'cause=%s\n'        "$cause"
        printf 'candidate=%s\n'    "$candidate"
        printf 'ts=%s\n'           "$(date -Is 2>/dev/null || echo unknown)"
        printf 'abort_streak=%s\n' "$streak"
    } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
    mv -f "$tmp" "$dir/restart-outcome" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }

    (( is_abort )) || return 0

    # Escalate when the streak FIRST reaches the threshold, then again
    # every repeat-interval — loud enough to catch on day 1, quiet enough
    # not to spam every ~30-min reconcile tick.
    local threshold="${CC_AUTO_RESTART_ABORT_ESCALATE:-3}"
    local repeat="${CC_AUTO_RESTART_ABORT_ESCALATE_REPEAT:-48}"
    [[ "$threshold" =~ ^[0-9]+$ && "$threshold" -gt 0 ]] || threshold=3
    [[ "$repeat"    =~ ^[0-9]+$ && "$repeat"    -gt 0 ]] || repeat=48
    if (( streak >= threshold )) \
       && (( streak == threshold || (streak - threshold) % repeat == 0 )); then
        _cc_auto_log_decision "$dir" "$candidate" "restart-abort-escalation" \
            "streak=$streak cause=$cause code=$code"
        declare -F log >/dev/null 2>&1 \
            && log "cc-auto-update: orchestrator restart has ABORTED $streak× in a row on the same cause ($cause) — the version split is NOT self-healing. Inspect: monitor/.state/cc-auto-update/{restart-outcome,decisions.tsv,detached-restart.log}"
        command -v sandbox-notify >/dev/null 2>&1 \
            && sandbox-notify "cc-auto-update: restart aborted ${streak}× in a row (cause=$cause) — version split persists; needs attention" || true
    fi
    return 0
}

# _cc_auto_reconcile_pending_restart <nexus_root> <state_dir> <package> [now_epoch]
#
# RESTART-PENDING RECONCILIATION — fires INDEPENDENTLY of the registry
# decide and the daily-due gate. The autonomous bump
# (cc-auto-update-apply.sh `safe`) installs the new binary AND hands the
# orchestrator restart to a detached watchdog; if that restart never
# completes (a crash, or the pre-#370 in-drive defer), the binary is
# current but the RUNNING orchestrator stays on the OLD one — and the
# daily routine, seeing "no registry delta -> current", no-ops forever,
# never reconciling the split (the 2026-06-29 live incident:
# installed=2.1.195 yet the orchestrator session ran 2.1.186 for two days,
# every daily fire logging "up to date" and skipping the pending restart).
#
# This closes that gap. When the pinned orchestrator's RUNNING binary
# (its transcript's last "version" stamp — ground truth, the same stamp
# the watchdog and `_already_on_candidate` read) is GENUINELY OLDER than
# the installed/effective version, it triggers the SAME watchdog-mediated
# detached `restart-orchestrator` hand-off cmd_safe uses. It invents NO
# new kill: the detached verb owns the valid-pin / already-on-candidate /
# idle-wait / arm-then-`tmux kill-window` chain with every #370 abort
# intact, so this only DECIDES to hand off — the kill safety stays there.
#
# Idempotent + loop-safe by construction (NO restart loops, NO false
# restarts). It never fires when:
#   - the orchestrator is ALREADY on the installed binary (compare==same)
#     or AHEAD of it (older: an operator-hand-rolled prerelease);
#   - there is no valid session pin or no readable running version
#     (a kill then would cold-spawn / be blind);
#   - an operator/agent RESTART-HOLD is active (nexus-code#513) — a
#     deliberately-refused restart stays refused until the hold expires,
#     a newer version re-arms it, or `apply.sh unhold` releases it;
#   - a reconcile/restart is already IN FLIGHT — a live detached restart
#     pid, the armed marker, or a live watchdog window (the running
#     version stays old until the respawn stamps the new one, so without
#     this every tick in that window would re-fire);
#   - we are inside the post-attempt COOLDOWN. The cooldown bounds retries
#     after ANY attempt, so a FAILED one (stale-pin abort, watchdog-spawn
#     failure) retries slowly instead of every tick. A SUCCESS heals the
#     split, so the compare short-circuits long before the cooldown
#     matters. Default 1800s comfortably exceeds the worst-case in-flight
#     time (idle-wait cap + arm-wait + respawn), so an attempt can never
#     double-fire even if the in-flight markers are momentarily absent.
# Always rc 0 (never errors the caller's tick).
_cc_auto_reconcile_pending_restart() {
    local nexus_root="${1:?nexus_root required}"
    local state_dir="${2:?state_dir required}"
    local package="${3:?package required}"
    local now="${4:-$(_cc_auto_clock)}"

    local auto_dir="$state_dir/cc-auto-update"
    local projects_dir="${CC_AUTO_PROJECTS_DIR:-$HOME/.claude/projects}"
    local cooldown="${CC_AUTO_RECONCILE_COOLDOWN_SECONDS:-1800}"

    # 1. Installed/effective version (operator-local pin if present, else
    #    the package.json floor). Unresolvable → nothing to compare.
    local effective
    effective=$(cc_version_effective \
        "$nexus_root/package.json" "$package" "$nexus_root" 2>/dev/null || true)
    [[ -n "$effective" ]] || return 0

    # 2. A valid session pin (names a sid + the transcript exists) is the
    #    whole seamlessness story; without it a kill would cold-spawn, so
    #    there is nothing safe to reconcile here. Mirrors cmd_safe's
    #    foreground pre-flight (exit 21).
    local sid
    sid=$(tr -d '[:space:]' < "$state_dir/orchestrator-session-id" 2>/dev/null || true)
    grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' \
        <<<"$sid" || return 0
    local slug jsonl
    slug=$(printf '%s' "$nexus_root" | sed 's|[^a-zA-Z0-9]|-|g')
    jsonl="$projects_dir/$slug/$sid.jsonl"
    [[ -f "$jsonl" ]] || return 0

    # 3. The RUNNING orchestrator binary = its transcript's LAST "version"
    #    stamp: a process writes only its OWN binary's version, so the most
    #    recent stamp is what the orchestrator is running NOW. Unreadable →
    #    cannot determine the running version → never kill blind.
    local running
    running=$(grep -oE '"version":"[0-9]+\.[0-9]+\.[0-9]+"' "$jsonl" 2>/dev/null \
        | tail -1 | sed -E 's/.*"version":"([0-9.]+)".*/\1/')
    [[ -n "$running" ]] || return 0

    # 4. Only a GENUINELY-OLDER running binary is a pending-restart split.
    #    same → already current (no needless kill); older → the running
    #    orchestrator is AHEAD of the pin — never kill. This is THE guard
    #    that keeps the reconciliation from firing when there is nothing to
    #    fix; it also short-circuits the steady state before the cooldown
    #    or any I/O below.
    [[ "$(_cc_update_compare "$running" "$effective")" == "newer" ]] || return 0

    # 4b. OPERATOR HOLD (your-org/nexus-code#513). A refused restart must
    #     STAY refused: the split just confirmed above is itself the fire
    #     predicate, so without a durable hold, aborting an unwanted
    #     restart re-arms the next one on every post-cooldown tick,
    #     forever — doing nothing selects decapitation by default. This
    #     check runs on the LIVE watcher every tick (the enabled flag
    #     cannot: it is read once at startup). Logged once per hold
    #     write, not per tick — the ack stamp mirrors the hold's mtime.
    if _cc_auto_restart_hold_active "$auto_dir" "$effective" "$now"; then
        local hold_f="$auto_dir/restart-hold" ack="$auto_dir/reconcile-held.acked"
        if [[ ! -f "$ack" || "$hold_f" -nt "$ack" ]]; then
            local hreason
            hreason=$(_cc_update_field "$hold_f" reason 2>/dev/null || echo '?')
            _cc_auto_log_decision "$auto_dir" "$effective" "reconcile-held" \
                "running=$running reason=$hreason"
            declare -F log >/dev/null 2>&1 \
                && log "cc-auto-update: version-split (running=$running installed=$effective) NOT reconciled — restart-hold active ($hreason). Release: monitor/cc-auto-update-apply.sh unhold"
            touch -r "$hold_f" "$ack" 2>/dev/null || true
        fi
        return 0
    fi

    # 5. Single-flight: never stack a second hand-off on an in-flight one.
    #    The detached `restart-orchestrator` records its PID first thing; a
    #    live pid, the armed marker, or a live watchdog window all mean a
    #    reconcile is already mid-flight.
    local rpid
    rpid=$(tr -d '[:space:]' < "$state_dir/restart-orchestrator.pid" 2>/dev/null || true)
    if [[ "$rpid" =~ ^[0-9]+$ ]] && kill -0 "$rpid" 2>/dev/null; then
        return 0
    fi
    [[ -f "$state_dir/restart-watchdog-armed" ]] && return 0
    _cc_auto_window_alive "$CC_AUTO_WATCHDOG_WINDOW" && return 0

    # 6. Cooldown/back-off after any attempt (a failed one must not thrash
    #    every tick).
    local stamp="$auto_dir/reconcile.last"
    if [[ -f "$stamp" ]]; then
        local mt
        mt=$(date +%s -r "$stamp" 2>/dev/null || echo 0)
        [[ "$mt" =~ ^[0-9]+$ ]] || mt=0
        (( now - mt < cooldown )) && return 0
    fi

    # 7. Fire. Stamp the cooldown BEFORE launching (a partially-failed
    #    launch must not re-fire next tick), audit + log + notify, then hand
    #    off to the SAME detached watchdog-mediated `restart-orchestrator`
    #    verb cmd_safe uses. The candidate is the EFFECTIVE installed
    #    version — the orchestrator must come up on the binary already on
    #    disk, and the watchdog verifies a fresh "version":"$effective"
    #    stamp before declaring success.
    mkdir -p "$auto_dir" 2>/dev/null || true
    touch "$stamp" 2>/dev/null || true
    _cc_auto_log_decision "$auto_dir" "$effective" "reconcile-fired" \
        "running=$running -> $effective; detached restart-orchestrator sid=$sid"
    declare -F log >/dev/null 2>&1 \
        && log "cc-auto-update: orchestrator version-split (running=$running installed=$effective) — reconciling via the detached watchdog-mediated restart (sid=$sid)"
    command -v sandbox-notify >/dev/null 2>&1 \
        && sandbox-notify "cc-auto-update: orchestrator on old binary ($running < $effective) — reconciling restart under watchdog" || true

    local apply_cmd="${CC_AUTO_APPLY_CMD:-$nexus_root/monitor/cc-auto-update-apply.sh}"
    local detached_log="$auto_dir/detached-restart.log"
    # Explicit mode at creation (your-org/nexus-code#484/#509) — both
    # branches below open this log with a bare `>>`.
    _ensure_service_log "$detached_log"
    if [[ "${CC_AUTO_RECONCILE_INLINE:-0}" == "1" ]]; then
        # Test seam (mirrors cmd_safe's CC_AUTO_RESTART_INLINE): run the
        # hand-off synchronously so a test asserts the chain deterministically.
        bash "$apply_cmd" restart-orchestrator \
            --candidate "$effective" --sid "$sid" >> "$detached_log" 2>&1 || true
    else
        setsid nohup bash "$apply_cmd" restart-orchestrator \
            --candidate "$effective" --sid "$sid" \
            >> "$detached_log" 2>&1 < /dev/null &
        disown 2>/dev/null || true
    fi
    return 0
}

# _cc_auto_update_tick <nexus_root> <state_dir> <package> <fire_time> \
#                      [fetch_cmd] [timeout]
#
# The scheduler task body. See the file header for the decision chain.
# Always rc 0 — this task must never error the watcher loop.
_cc_auto_update_tick() {
    local nexus_root="${1:?nexus_root required}"
    local state_dir="${2:?state_dir required}"
    local package="${3:?package required}"
    local fire_time="${4:?fire_time required}"
    local fetch_cmd="${5:-_cc_update_default_fetch}"
    local timeout="${6:-10}"

    local auto_dir="$state_dir/cc-auto-update"
    local stamp="$auto_dir/last-fire-date"
    local now today
    now=$(_cc_auto_clock)

    # Restart-pending reconciliation runs on EVERY tick — BEFORE the
    # daily-due gate AND independent of the registry decide. The operator
    # requirement: even when the binary is already current, the routine
    # must still process a pending orchestrator restart. Gating the restart
    # on a registry DELTA (the old behaviour) left a crashed/deferred
    # restart unreconciled forever; running this each tick (the cc_auto
    # cadence, ~5 min by default) heals the split promptly instead.
    _cc_auto_reconcile_pending_restart "$nexus_root" "$state_dir" "$package" "$now"

    _cc_auto_due "$now" "$fire_time" "$stamp" || return 0
    today=$(_cc_auto_day "$now")

    # Guard 2 — one evaluator at a time. A still-live evaluator window
    # (e.g. yesterday's run still in flight) DEFERS today's fire.
    #
    # It used to CONSUME it: this arm stamped `last-fire-date`, and the fire
    # predicate is `now >= today@fire_time AND last-fire-date != today`, so
    # stamping here cancelled the day outright rather than postponing it
    # (your-org/nexus-code#968). That is not a theoretical difference. On
    # 2026-08-20 an evaluator's turn crashed on `Login expired` about two
    # minutes after spawn, before it wrote anything; its process stayed alive,
    # so a window that could not do any work satisfied this guard, and the
    # 08-21 round was cancelled silently — and every subsequent round would
    # have been, for as long as the corpse existed. A security-relevant
    # evaluation stops running and nothing says so.
    #
    # Not stamping makes the guard self-healing: the next tick
    # (`check_interval_seconds`, 300 by default) retries, and the day resumes
    # the moment the stale window goes away. The stamp was never what stopped
    # a genuine double-spawn — `spawn-worker.sh`'s exit-7 name-collision guard
    # is, and it still is; the stamp only stopped the RETRY.
    #
    # The skip row and the log line stay once-per-day, keyed on their own
    # marker rather than on the fire stamp. Retrying every 300 s would
    # otherwise write ~288 identical `skipped-window-alive` rows a day, and a
    # log that repeats is read exactly as often as one that is silent.
    #
    # WINDOW EXISTENCE IS NOT EVALUATOR LIVENESS (#968 part 2). The
    # 2026-08-20 corpse satisfied `_cc_auto_window_alive` for as long as it
    # existed, so not stamping alone turns one silent cancellation into an
    # unbounded silent deferral — the same round never running, differently
    # spelled. `_cc_auto_evaluator_stale` adds the missing axis: a pane that
    # has been POSITIVELY stalled for CC_AUTO_EVALUATOR_STALE_SECONDS is not
    # a live evaluator and its window is reclaimed. Every other reading —
    # working, indeterminate, or a stall too young — still defers.
    local eval_live=0 eval_detail=""
    if _cc_auto_window_alive "$CC_AUTO_WINDOW"; then
        if _cc_auto_evaluator_stale "$auto_dir" "$CC_AUTO_WINDOW" "$now" "$nexus_root"; then
            _cc_auto_log_decision "$auto_dir" "-" "evaluator-window-reclaimed" \
                "window=$CC_AUTO_WINDOW state=$CC_AUTO_EVAL_STATE stalled_for=${CC_AUTO_EVAL_STALL_AGE}s"
            declare -F log >/dev/null 2>&1 \
                && log "cc-auto-update: evaluator window '$CC_AUTO_WINDOW' has been stalled (state=$CC_AUTO_EVAL_STATE) for ${CC_AUTO_EVAL_STALL_AGE}s with no work in flight — reclaiming it and firing today's round"
            rm -f "$auto_dir/evaluator-stalled-since" 2>/dev/null || true
        else
            eval_live=1
            eval_detail="window=$CC_AUTO_WINDOW class=$CC_AUTO_EVAL_CLASS state=$CC_AUTO_EVAL_STATE stalled_for=${CC_AUTO_EVAL_STALL_AGE}s"
        fi
    else
        rm -f "$auto_dir/evaluator-stalled-since" 2>/dev/null || true
    fi

    if (( eval_live )); then
        local skip_stamp="$auto_dir/last-skip-date" last_skip=""
        [[ -f "$skip_stamp" ]] && last_skip=$(tr -d '[:space:]' < "$skip_stamp" 2>/dev/null || true)
        if [[ "$last_skip" != "$today" ]]; then
            _cc_auto_stamp "$skip_stamp" "$now"
            local streak
            streak=$(_cc_auto_skip_streak_bump "$auto_dir")
            [[ "$streak" =~ ^[0-9]+$ ]] || streak=1
            _cc_auto_log_decision "$auto_dir" "-" "skipped-window-alive" \
                "$eval_detail streak=$streak"
            declare -F log >/dev/null 2>&1 \
                && log "cc-auto-update: evaluator window '$CC_AUTO_WINDOW' still alive from a prior run ($eval_detail); DEFERRING today's fire (retries each tick until the window clears)"
            # SURFACE A REPEATED SKIP (#968 part 3). One deferral is
            # routine. N consecutive days of them means the update
            # evaluation has stopped running, and until this the ONLY
            # trace of that was a TSV row nothing reads — the whole
            # reason a cancelled round went unnoticed for a day and would
            # have gone unnoticed indefinitely.
            local alert="${CC_AUTO_SKIP_STREAK_ALERT:-2}"
            [[ "$alert" =~ ^[0-9]+$ && "$alert" -gt 0 ]] || alert=2
            # RE-NAG GUARD (your-org/nexus-code#1342): escalate when the streak
            # FIRST reaches the threshold, then again every `repeat` deferred
            # days — the same idiom `_cc_auto_write_restart_outcome` uses 283
            # lines up, and for the same reason: an alert that fires every day
            # is not read. Measured before this guard: 5 notifications over six
            # deferred days where the restart arm would have sent 1.
            local repeat="${CC_AUTO_SKIP_STREAK_REPEAT:-7}"
            [[ "$repeat" =~ ^[0-9]+$ && "$repeat" -gt 0 ]] || repeat=7
            if (( streak >= alert )) \
               && (( streak == alert || (streak - alert) % repeat == 0 )); then
                _cc_auto_log_decision "$auto_dir" "-" "skipped-window-alive-escalation" \
                    "streak=$streak $eval_detail"
                declare -F log >/dev/null 2>&1 \
                    && log "cc-auto-update: the daily update evaluation has now been DEFERRED $streak days running by window '$CC_AUTO_WINDOW' ($eval_detail). No candidate has been evaluated in that time. Inspect the window, or close it: monitor/.state/cc-auto-update/decisions.tsv"
                command -v sandbox-notify >/dev/null 2>&1 \
                    && sandbox-notify "cc-auto-update: daily evaluation deferred ${streak} days running — evaluator window '$CC_AUTO_WINDOW' ($CC_AUTO_EVAL_STATE) is blocking every round" || true
            fi
        fi
        return 0
    fi
    _cc_auto_skip_streak_clear "$auto_dir"

    # Fresh registry decide at fire time (don't trust a possibly-24h-old
    # cc_version_check signal). Reuses _cc_update_decide wholesale, so
    # the shared cc-update-available signal file is maintained with the
    # exact same semantics the manual flow relies on.
    local pinned verdict rc=0
    pinned=$(cc_version_effective \
        "$nexus_root/package.json" "$package" "$nexus_root" 2>/dev/null || true)
    verdict=$(_cc_update_decide \
        "$state_dir" "$package" "$pinned" \
        "${MONITOR_CC_UPDATE_SKILL_PATH:-skills/nexus.cc-update/GUIDE.md}" \
        "$fetch_cmd" "$timeout") || rc=$?

    case "$rc" in
        1)
            # current — already on (or ahead of) registry latest.
            # Guard 3 (already-pinned) lands here by construction.
            _cc_auto_stamp "$stamp" "$now"
            declare -F log >/dev/null 2>&1 \
                && log "cc-auto-update: up to date ($verdict); nothing to do today"
            return 0
            ;;
        2)
            # unreachable/unknown — fail-safe: do NOT stamp, so the next
            # tick retries; the day rollover bounds the retry window.
            declare -F log >/dev/null 2>&1 \
                && log "cc-auto-update: $verdict (fail-safe; will retry next tick)"
            return 0
            ;;
    esac

    local candidate
    candidate=$(printf '%s' "$verdict" | sed -n 's/.*candidate=\([^ ]*\).*/\1/p')
    [[ -n "$candidate" ]] \
        || candidate=$(_cc_update_field "$state_dir/cc-update-available" candidate 2>/dev/null || true)
    if [[ -z "$candidate" ]]; then
        # Defensive: rc=0 with no parsable candidate — decline to act.
        declare -F log >/dev/null 2>&1 \
            && log "cc-auto-update: available but no parsable candidate ($verdict); declining (fail-safe)"
        _cc_auto_stamp "$stamp" "$now"
        return 0
    fi

    # Paranoia twin of guard 3: never spawn for the version already
    # running, even if compare said otherwise.
    if [[ "$candidate" == "$pinned" ]]; then
        _cc_auto_stamp "$stamp" "$now"
        return 0
    fi

    # A SAFE-REFUSED OUTCOME NOTIFIES SOMEBODY (your-org/nexus-code#1400).
    # `safe-refused` is "the candidate is fine, I could not apply it" — a
    # defect in US, not in the candidate — and it used to write one TSV row
    # and go dark; the daily fire then reproduced it byte-for-byte. Two days
    # of false BLOCKs surfaced only because the operator asked. So the tick
    # itself says so, once per day, via the log and sandbox-notify, naming the
    # reason and the candidate, and it says LOUDER when the previous refusal
    # carried the same reason (a standing defect, not a transient tree state).
    _cc_auto_surface_safe_refused "$auto_dir" "$candidate" "$now"

    # Guard 4 — candidate already surfaced to the operator (block or
    # compat-pr outcome). A newer candidate falls through and re-arms.
    if _cc_auto_last_eval_skip "$auto_dir" "$candidate"; then
        _cc_auto_stamp "$stamp" "$now"
        _cc_auto_log_decision "$auto_dir" "$candidate" "skipped-awaiting-operator" \
            "last-eval=$(_cc_update_field "$auto_dir/last-eval" decision 2>/dev/null || echo '?')"
        declare -F log >/dev/null 2>&1 \
            && log "cc-auto-update: candidate $candidate already surfaced (awaiting operator); skipping re-eval"
        return 0
    fi

    # Clean up a dead remain-on-exit evaluator window from a prior life
    # so spawn-worker's collision check (exit 7) doesn't refuse.
    if grep -Fxq -- "$CC_AUTO_WINDOW" <<<"$(tmux list-windows -F '#W' 2>/dev/null)"; then
        tmux kill-window -t "$CC_AUTO_WINDOW" 2>/dev/null || true
    fi

    # Resolve the tracking issue, or REFUSE to fire (your-org/nexus-code#866).
    #
    # This used to interpolate the configured value straight into the prompt,
    # where the template pairs it with SURFACE_REPO. A bare number therefore
    # resolved against whatever repo the template happened to name — so a
    # reference written for one repo was consumed against another, and every
    # write landed, succeeded, and was never seen. Nothing errored, because
    # nothing checked that the number and the repo came from the same place.
    #
    # A qualified reference carries its own repo, so the two cannot drift.
    # An unqualified one is REFUSED here rather than guessed: the evaluator
    # does not fire, the reason is logged, and the decision is recorded. That
    # is a deliberately worse outcome than firing — a skipped evaluation is
    # visible on the next fire, whereas a misrouted one is invisible forever.
    # Unset is the common case and has nothing to resolve, so the resolver is
    # only consulted when a value EXISTS. That also keeps "no standing issue"
    # working on a root where the resolver is somehow absent, while a value
    # that cannot be checked still refuses (below) — absence of the checker is
    # not evidence the reference is fine.
    local _ref_out _ref_rc=3 _track_repo="" _track_issue=""
    local _track_raw="${MONITOR_CC_AUTO_UPDATE_TRACKING_ISSUE:-}"
    _track_raw="${_track_raw#"${_track_raw%%[![:space:]]*}"}"
    if [[ -n "$_track_raw" ]]; then
        if [[ -r "$nexus_root/monitor/issue-ref.sh" ]]; then
            _ref_out=$(bash "$nexus_root/monitor/issue-ref.sh" "$_track_raw" \
                --field monitor.cc_auto_update.tracking_issue 2>&1)
            _ref_rc=$?
        else
            _ref_out="issue-ref: REFUSING — resolver missing at $nexus_root/monitor/issue-ref.sh; cannot verify the tracking reference"
            _ref_rc=4
        fi
    fi
    case "$_ref_rc" in
        0)  _track_repo=$(printf '%s\n' "$_ref_out" | sed -n 's/^REPO=//p')
            _track_issue=$(printf '%s\n' "$_ref_out" | sed -n 's/^ISSUE=//p') ;;
        3)  : ;;   # unset — legitimate: no standing issue, evaluator opens one if it must
        *)  declare -F log >/dev/null 2>&1 && log \
                "ERROR cc-auto-update: monitor.cc_auto_update.tracking_issue is not a qualified owner/repo#N reference; REFUSING to fire rather than posting to a guessed repo"
            printf '%s\n' "$_ref_out" | while IFS= read -r _l; do
                declare -F log >/dev/null 2>&1 && log "cc-auto-update:   $_l"
            done
            _cc_auto_stamp "$stamp" "$now"
            _cc_auto_log_decision "$auto_dir" "$candidate" "refused-unqualified-tracking-issue" \
                "value=${MONITOR_CC_AUTO_UPDATE_TRACKING_ISSUE:-} (want owner/repo#N)"
            return 0 ;;
    esac

    # Render the evaluator prompt.
    local template="${CC_AUTO_PROMPT_TEMPLATE:-$nexus_root/monitor/cc-auto-update-prompt.md}"
    local prompt_file="$auto_dir/eval-prompt-$today.md"
    if ! _cc_auto_render_prompt "$template" "$prompt_file" \
            "CANDIDATE=$candidate" \
            "INSTALLED=${pinned:-unknown}" \
            "NEXUS_ROOT=$nexus_root" \
            "STATE_DIR=$state_dir" \
            "DATE=$today" \
            "SURFACE_REPO=${CC_AUTO_SURFACE_REPO:-your-org/nexus-code}" \
            "TRACKING_ISSUE=${_track_issue}" \
            "TRACKING_REPO=${_track_repo}" \
            "GUIDE=${MONITOR_CC_UPDATE_SKILL_PATH:-skills/nexus.cc-update/GUIDE.md}"; then
        declare -F log >/dev/null 2>&1 \
            && log "ERROR cc-auto-update: prompt template missing/unreadable at $template; cannot spawn evaluator"
        _cc_auto_stamp "$stamp" "$now"
        _cc_auto_log_decision "$auto_dir" "$candidate" "spawn-failed" "template-missing"
        return 0
    fi

    # Stamp BEFORE spawning: a partially-failed spawn must not re-fire
    # every 5 minutes for the rest of the day (the failure is loud in
    # the log + audit trail instead).
    _cc_auto_stamp "$stamp" "$now"

    # Consume the orchestrator-facing nag for this candidate: the
    # autonomous evaluator now owns it, so compose_emit must not ALSO
    # tell the orchestrator to spawn a manual evaluator (duplicate
    # work). Same file the manual flow's re-nag guard reads.
    printf '%s\n' "$candidate" > "$state_dir/cc-update-surfaced" 2>/dev/null || true

    local spawn_cmd="${CC_AUTO_SPAWN_CMD:-$nexus_root/monitor/spawn-worker.sh}"
    # The evaluator's window NAME, written where the PreToolUse hook reads it
    # (your-org/nexus-code#1529, w241sk D2): `bash-footgun-guard.sh`'s
    # `cc-update-git` arm scopes on this name and cannot otherwise see a
    # custom CC_AUTO_WINDOW that was exported to the watcher but not to the
    # evaluator. Best-effort: a write that fails leaves the env default.
    printf '%s\n' "$CC_AUTO_WINDOW" > "$auto_dir/evaluator-window" 2>/dev/null || true
    declare -F log >/dev/null 2>&1 \
        && log "cc-auto-update FIRED: candidate=$candidate installed=${pinned:-?} spawning evaluator window=$CC_AUTO_WINDOW prompt=$prompt_file"
    if "$spawn_cmd" -n "$CC_AUTO_WINDOW" -c "$nexus_root" -p "$prompt_file" >/dev/null 2>&1; then
        _cc_auto_log_decision "$auto_dir" "$candidate" "spawned" "window=$CC_AUTO_WINDOW prompt=$prompt_file"
    else
        local spawn_rc=$?
        _cc_auto_log_decision "$auto_dir" "$candidate" "spawn-failed" "rc=$spawn_rc cmd=$spawn_cmd"
        declare -F log >/dev/null 2>&1 \
            && log "ERROR cc-auto-update: evaluator spawn failed (rc=$spawn_rc); see $auto_dir/decisions.tsv"
    fi
    return 0
}
