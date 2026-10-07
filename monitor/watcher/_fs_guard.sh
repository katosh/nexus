#!/usr/bin/env bash
# _fs_guard.sh — keep the watcher ALIVE and HONEST when the project
# filesystem goes read-only (your-org/nexus-code#473).
#
# Sourced by monitor/watcher/main.sh after _lib.sh. Side-effect-free:
# function definitions plus in-memory incident state, nothing else — so
# tests can source it, drive it against a 0555 fixture, and observe every
# transition without a real read-only mount.
#
# Depends (at CALL time, not source time) on:
#   _nexus_dir_writable, _nexus_critical_alarm, _nexus_rofs_alarm_text,
#   _nexus_github_incident_escalate, _nexus_fs_incident_record,
#   _nexus_fs_incident_close_comment   (all monitor/watcher/_lib.sh)
#   log, STATE_DIR, NEXUS_ROOT, TARGET (main.sh)
#
# THE POINT. On 2026-06-29 and again on 2026-07-09 the project tree went
# read-only and the watcher did not degrade — it vanished. Both incidents
# run the same script: `version_check` sees drifted sources, fires
# `launcher.sh --replace`, the launcher SIGTERMs the incumbent, and the
# successor dies in `>>"$LOGFILE"` — a FRESH open() — before `main.sh`
# executes one line. The incumbent it replaced was fine: it held its log
# fd from before the remount and had been logging normally throughout.
#
# So the guard has two halves, and both matter:
#   * do not die   — degrade, keep looping, keep something alive that can
#                    observe the condition and notice recovery;
#   * do not lie   — probe with a fresh open() every cycle, never through
#                    a held fd, which would report healthy mid-outage.

# Incident state, held IN MEMORY, deliberately. There is nowhere to write a
# rate-limit cursor during the incident — that is the whole condition — and
# the process dies with the incident anyway, so a file would buy nothing and
# cost a write we cannot make. FS_ESCALATED is what makes the alert fire
# exactly once: an alert that repeats every cycle is an alert that gets muted.
#
# `:=` so a test (or a re-source) may seed them without being clobbered.
: "${FS_DEGRADED:=0}"         # 1 while the project FS is not writable
: "${FS_ONSET:=0}"            # epoch of the first cycle whose probe FAILED
: "${FS_LAST_OK:=0}"          # epoch of the last cycle whose probe SUCCEEDED
: "${FS_ESCALATED:=0}"        # 1 once this incident has been escalated
: "${FS_CHANNELS:=}"          # escalation channels that actually delivered
: "${FS_DEGRADED_CYCLES:=0}"
# The repeating DEGRADED note (your-org/nexus-code#1724), in memory like the
# rest: the next epoch a note is due, the current gap, and how many went out.
: "${FS_NOTE_NEXT:=0}"
: "${FS_NOTE_GAP:=0}"
: "${FS_NOTE_COUNT:=0}"
_FS_GUARD_MONITOR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)

# ---------------------------------------------------------------------------
# THE DEGRADED NOTE — the watcher keeps TALKING while it cannot operate
# (your-org/nexus-code#1724). The one-shot escalation below fires at onset;
# an 18 h incident then went silent for 18 h. Every degraded cycle now asks
# whether a short note is due, on a DOUBLING backoff (first after
# MONITOR_FS_DEGRADED_NOTE_BASE_SECONDS, default 300; capped at
# MONITOR_FS_DEGRADED_NOTE_MAX_SECONDS, default 3600), so it never stops while
# the condition holds and never floods (the #1713 lesson).
#
# WHERE IT GOES, and what it must never do. It is delivered through the SAME
# paste path as every emit (`paste_to_target`): the typed/undecidable-input
# refusal (an operator draft is never typed over), the overlay and dead-pane
# refusals, the Enter handling and the submit receipt all apply. That path's
# only writes (its per-target lock and the deferral counter) live under
# $STATE_DIR, which is the very directory that failed, so for this one call
# STATE_DIR points at a private run dir outside the tree. When the pane
# refuses, NOTHING is typed: the note survives in the watcher log (a held fd)
# and in the status file `ng degraded status` reads. There is no raw
# `send-keys` fallback, on purpose.
#
# The status file lives in NEXUS_DEGRADED_RUNDIR (default
# /tmp/nexus-degraded-<uid>, mode 0700): /tmp is never the detached mount, and
# a sandbox restart wiping it loses only a live status, never a record.
_fs_rundir_path() {   # -> the run dir's path; creates nothing (readers use this)
    printf '%s' "${NEXUS_DEGRADED_RUNDIR:-/tmp/nexus-degraded-$(id -u 2>/dev/null || echo unknown)}"
}
_fs_status_path() {   # <state_dir> -> its status file's path; creates nothing
    printf '%s/%s.status' "$(_fs_rundir_path)" "$(printf '%s' "${1:?}" | tr -c 'A-Za-z0-9._-' '_')"
}
_fs_rundir() {   # -> the run dir (created 0700), or rc 1
    local d; d=$(_fs_rundir_path)
    ( umask 077; mkdir -p "$d" ) 2>/dev/null
    [[ -d "$d" && -w "$d" ]] || return 1
    printf '%s' "$d"
}
_fs_status_file() {   # <state_dir> -> path of its status file (run dir created)
    _fs_rundir >/dev/null || return 1
    _fs_status_path "$1"
}

# _fs_note_due <now> — 0 when a note is due now; advances the backoff.
_fs_note_due() {
    local now="${1:?now}" base="${MONITOR_FS_DEGRADED_NOTE_BASE_SECONDS:-300}" cap="${MONITOR_FS_DEGRADED_NOTE_MAX_SECONDS:-3600}"
    [[ "$base" =~ ^[0-9]+$ ]] && (( base > 0 )) || base=300
    [[ "$cap" =~ ^[0-9]+$ ]] && (( cap >= base )) || cap=$(( base > 3600 ? base : 3600 ))
    if (( FS_NOTE_NEXT == 0 )); then
        FS_NOTE_GAP=$base; FS_NOTE_NEXT=$(( FS_ONSET + base ))
    fi
    (( now >= FS_NOTE_NEXT )) || return 1
    FS_NOTE_GAP=$(( FS_NOTE_GAP * 2 )); (( FS_NOTE_GAP > cap )) && FS_NOTE_GAP=$cap
    FS_NOTE_NEXT=$(( now + FS_NOTE_GAP ))
    return 0
}

# _fs_probe_detail — "<VERDICT> <detail>" for $STATE_DIR from degraded-probe.sh
# (EROFS / ENOSPC / EACCES / HANG / …), bounded; "UNKNOWN probe unavailable"
# when the probe itself cannot run.
_fs_probe_detail() {
    local probe="$_FS_GUARD_MONITOR_DIR/degraded-probe.sh" row v d
    [[ -r "$probe" ]] || { printf 'UNKNOWN degraded-probe.sh unavailable'; return 0; }
    # CAPTURE, THEN MATCH: no early-exit reader on the producer's pipe (#682).
    local raw line
    raw=$(bash "$probe" --timeout "${MONITOR_FS_DEGRADED_PROBE_TIMEOUT:-3}" \
            --surface "state=$STATE_DIR" 2>/dev/null)
    row=""
    while IFS= read -r line; do
        [[ "$line" == "surface=state "* ]] && { row="$line"; break; }
    done <<<"$raw"
    v=$(sed -n 's/.* verdict=\([A-Z]*\).*/\1/p' <<<"$row")
    d=$(sed -n 's/.* detail=//p' <<<"$row")
    printf '%s %s' "${v:-UNKNOWN}" "${d:-no detail}"
}

# _fs_status_write <key=value>... — rewrite the status file (best-effort).
_fs_status_write() {
    local f; f=$(_fs_status_file "$STATE_DIR") || return 1
    { printf '%s\n' "$@"; printf 'updated=%s\n' "$(date +%s 2>/dev/null)"; } > "$f.tmp" 2>/dev/null \
        && mv -f "$f.tmp" "$f" 2>/dev/null
}

# _fs_note_deliver <text> — paste the note through paste_to_target with a
# private STATE_DIR. Prints the delivery word; never types anything itself.
_fs_note_deliver() {
    local text="$1" fn="${FS_NOTE_PASTE_FN:-paste_to_target}" rd body rc=0
    declare -F "$fn" >/dev/null 2>&1 || { printf 'not-delivered (no paste path loaded)'; return 0; }
    [[ -n "${TARGET:-}" ]] || { printf 'not-delivered (no target)'; return 0; }
    rd=$(_fs_rundir) || { printf 'not-delivered (no writable run dir)'; return 0; }
    mkdir -p "$rd/paste-state" 2>/dev/null
    body="$rd/note.$$.${RANDOM}.md"
    { printf '%s\n' "$text"; printf -- '--- nexus-emit-sig %s %s ---\n' "$(date -Is)" "fsnote$$${RANDOM}"; } > "$body" 2>/dev/null \
        || { printf 'not-delivered (cannot stage the body)'; return 0; }
    STATE_DIR="$rd/paste-state" "$fn" "$TARGET" "$body" no-liveness-stamp; rc=$?
    rm -f "$body" 2>/dev/null
    case "$rc" in
        0) printf 'delivered' ;;
        7) printf 'refused (input box holds typed or undecidable text, or an overlay is up; nothing typed)' ;;
        6) printf 'not-submitted (left for the operator; not re-pasted)' ;;
        2) printf 'not-delivered (target window absent)' ;;
        5) printf 'not-delivered (target is a dead pane)' ;;
        4) printf 'unconfirmed (pasted and Enter sent; no receipt; not re-pasted)' ;;
        *) printf 'not-delivered (paste rc %s; retried at the next note)' "$rc" ;;
    esac
}

# _fs_degraded_note_tick <now> — called once per degraded cycle.
_fs_degraded_note_tick() {
    local now="${1:-$(date +%s)}" dur pd verdict detail text delivery
    dur=$(( now - FS_ONSET )); (( dur < 0 )) && dur=0
    _fs_note_due "$now" || return 0
    FS_NOTE_COUNT=$(( FS_NOTE_COUNT + 1 ))
    pd=$(_fs_probe_detail); verdict="${pd%% *}"; detail="${pd#* }"
    text="[nexus watcher] DEGRADED for ${dur}s: cannot write ${STATE_DIR} (${verdict}: ${detail}). The loop is alive; the scheduler is suspended. Next note in ${FS_NOTE_GAP}s. Details: monitor/ng degraded status"
    delivery=$(_fs_note_deliver "$text")
    log "fs-guard: DEGRADED note #${FS_NOTE_COUNT} (${verdict}) — ${delivery}"
    _fs_status_write mode=degraded "state_dir=$STATE_DIR" "onset=$FS_ONSET" \
        "verdict=$verdict" "detail=$detail" "notes=$FS_NOTE_COUNT" "last_note=$now" \
        "next_note=$FS_NOTE_NEXT" "delivery=$delivery" || true
}

# Escalate the read-only condition exactly ONCE per incident, over channels
# that survive a read-only project FS, in preference order:
#   1. sandbox-notify  — pure PATH resolution + exec; no temp file, no cache
#   2. a GitHub issue  — mint-token.sh caches under $HOME/.claude, a
#                        DIFFERENT mount; a warm cache serves read-only
#   3. a tmux paste    — last resort, only if 1 and 2 both failed
_fs_escalate_once() {
    (( FS_ESCALATED )) && return 0
    FS_ESCALATED=1
    local chans='' oob='' text
    text=$(_nexus_rofs_alarm_text "$STATE_DIR" "watcher main.sh")

    # `_nexus_critical_alarm` returns 0 whenever it RANG, but stderr is its
    # floor — it "rings" even on a host with no `sandbox-notify` binary, where
    # stderr goes to a log on the filesystem that just died. So track the
    # channels that actually reached a HUMAN OUT-OF-BAND (`oob`) separately
    # from what we report (`chans`). Only an empty `oob` justifies interrupting
    # the orchestrator's pane. Crediting stderr as delivery would leave a
    # notify-less host silently unescalated.
    if _nexus_critical_alarm "watcher-rofs" \
        "${MONITOR_ROFS_ALARM_THROTTLE_SECONDS:-120}" "$text"; then
        if command -v sandbox-notify >/dev/null 2>&1; then
            chans='sandbox-notify'; oob='sandbox-notify'
        else
            chans='stderr'   # logged, NOT delivered — deliberately not `oob`
        fi
    fi

    if _nexus_github_incident_escalate "$NEXUS_ROOT" "$STATE_DIR" \
        "watcher main.sh (degraded)" \
        "watcher ALIVE in read-only degraded mode; no project-tree writes possible"; then
        chans="${chans:+$chans,}github-issue"
        oob="${oob:+$oob,}github-issue"
    fi

    # A status-line notice costs nothing and writes nothing. It is visible
    # only to someone already looking at the terminal, so it is not `oob`.
    if command -v tmux >/dev/null 2>&1; then
        tmux display-message "nexus: project FS READ-ONLY — restart the sandbox" \
            >/dev/null 2>&1 && chans="${chans:+$chans,}tmux-display"
    fi

    # Only if EVERY out-of-band channel failed do we interrupt the
    # orchestrator's pane — and through the SAME paste path as every emit,
    # with its writes redirected off the read-only tree (_fs_note_deliver,
    # your-org/nexus-code#1724). This used to be a raw `send-keys -l` + Enter,
    # which typed over an operator draft and submitted it. A refusal now types
    # nothing; the log line and `ng degraded status` carry the text.
    if [[ -z "$oob" ]]; then
        local _d; _d=$(_fs_note_deliver "$text")
        [[ "$_d" == delivered ]] && chans="${chans:+$chans,}tmux-paste"
        log "fs-guard: last-resort pane notice — ${_d}"
    fi

    FS_CHANNELS="${chans:-none}"
    log "fs-guard: escalated once via [${FS_CHANNELS}]"
    return 0
}

# One probe per cycle. Returns 0 when the project FS is writable, 1 when it
# is not (the caller must then skip every project-tree write).
#
# The probe is a FRESH create+unlink (monitor/_fs_probe.sh). It must never
# become an append to a held fd: this very process holds `watcher.log` open,
# and that fd keeps working after the mount is detached — a probe through it
# would report HEALTHY during a total outage. That is the exact failure mode
# this guard exists to prevent.
_fs_guard_tick() {
    local now dur
    now=$(date +%s 2>/dev/null || echo 0)

    if _nexus_dir_writable "$STATE_DIR"; then
        if (( FS_DEGRADED )); then
            dur=$(( now - FS_ONSET )); (( dur < 0 )) && dur=0
            log "fs-guard: project FS is WRITABLE again after ${dur}s (${FS_DEGRADED_CYCLES} degraded cycles) — resuming normal operation"
            # Durable trace: the 2026-06-29 incident left no record and was
            # re-diagnosed from scratch ten days later.
            if _nexus_fs_incident_record "$STATE_DIR" "$FS_ONSET" "$FS_LAST_OK" \
                "$now" "$FS_CHANNELS" "watcher main.sh"; then
                log "fs-guard: incident recorded in $STATE_DIR/fs-incidents.jsonl"
            else
                log "fs-guard: WARN could not append the incident trace to $STATE_DIR/fs-incidents.jsonl"
            fi
            if _nexus_fs_incident_close_comment "$NEXUS_ROOT" "$dur" \
                "$FS_CHANNELS" "watcher main.sh"; then
                log "fs-guard: posted the recovery comment on the open incident issue"
            else
                log "fs-guard: recovery comment not posted (best-effort; the local trace stands)"
            fi
            _fs_status_write mode=ok "state_dir=$STATE_DIR" "recovered=$now" \
                "last_incident_seconds=$dur" "notes=$FS_NOTE_COUNT" || true
            FS_DEGRADED=0; FS_ESCALATED=0; FS_CHANNELS=''
            FS_DEGRADED_CYCLES=0; FS_ONSET=0
            FS_NOTE_NEXT=0; FS_NOTE_GAP=0; FS_NOTE_COUNT=0
        fi
        FS_LAST_OK=$now
        return 0
    fi

    if (( ! FS_DEGRADED )); then
        FS_DEGRADED=1
        FS_ONSET=$now
        FS_DEGRADED_CYCLES=0
        FS_NOTE_NEXT=0; FS_NOTE_GAP=0; FS_NOTE_COUNT=0
        log "fs-guard: CRITICAL — the project FS is READ-ONLY (cannot write $STATE_DIR)."
        log "fs-guard: entering read-only DEGRADED mode. The loop stays alive; all project-tree writes are suspended."
        log "fs-guard: this cannot be repaired from inside the sandbox — it needs a restart from OUTSIDE. Never remount, bind, or unshare around it."
        _fs_escalate_once
    fi
    FS_DEGRADED_CYCLES=$(( FS_DEGRADED_CYCLES + 1 ))
    if (( FS_DEGRADED_CYCLES == 1 )); then
        _fs_status_write mode=degraded "state_dir=$STATE_DIR" "onset=$FS_ONSET" \
            "notes=0" "next_note=$(( FS_ONSET + ${MONITOR_FS_DEGRADED_NOTE_BASE_SECONDS:-300} ))" \
            "delivery=escalated once via [${FS_CHANNELS:-none}]" || true
    fi
    _fs_degraded_note_tick "$now"
    return 1
}

