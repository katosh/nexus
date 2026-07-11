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
#   2. evaluator-window-alive      — never two concurrent evaluators
#      (plus spawn-worker.sh's own exit-7 window-name collision guard).
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
    tmux list-windows -F '#W' 2>/dev/null | grep -Fxq -- "$window" || return 1
    local dead
    dead=$(tmux display-message -p -t "$window" '#{pane_dead}' 2>/dev/null || echo "")
    [[ "$dead" != "1" ]]
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
    printf '%s' "$sid" | grep -qE \
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' \
        || return 0
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
    # (e.g. yesterday's run still in flight) consumes today's fire so
    # the log carries exactly one line about it.
    if _cc_auto_window_alive "$CC_AUTO_WINDOW"; then
        _cc_auto_stamp "$stamp" "$now"
        _cc_auto_log_decision "$auto_dir" "-" "skipped-window-alive" "window=$CC_AUTO_WINDOW"
        declare -F log >/dev/null 2>&1 \
            && log "cc-auto-update: evaluator window '$CC_AUTO_WINDOW' still alive from a prior run; skipping today's fire"
        return 0
    fi

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
    if tmux list-windows -F '#W' 2>/dev/null | grep -Fxq -- "$CC_AUTO_WINDOW"; then
        tmux kill-window -t "$CC_AUTO_WINDOW" 2>/dev/null || true
    fi

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
            "TRACKING_ISSUE=${MONITOR_CC_AUTO_UPDATE_TRACKING_ISSUE:-}" \
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
