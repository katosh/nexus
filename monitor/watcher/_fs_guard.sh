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
    # orchestrator's pane. `paste_to_target` cannot help here — it stages the
    # body through a file on the very filesystem that is read-only — so this
    # is a literal, write-free send-keys.
    if [[ -z "$oob" ]] && command -v tmux >/dev/null 2>&1; then
        if tmux send-keys -t "$TARGET" -l "$text" 2>/dev/null; then
            tmux send-keys -t "$TARGET" Enter 2>/dev/null || true
            chans="${chans:+$chans,}tmux-paste"
        fi
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
            FS_DEGRADED=0; FS_ESCALATED=0; FS_CHANNELS=''
            FS_DEGRADED_CYCLES=0; FS_ONSET=0
        fi
        FS_LAST_OK=$now
        return 0
    fi

    if (( ! FS_DEGRADED )); then
        FS_DEGRADED=1
        FS_ONSET=$now
        FS_DEGRADED_CYCLES=0
        log "fs-guard: CRITICAL — the project FS is READ-ONLY (cannot write $STATE_DIR)."
        log "fs-guard: entering read-only DEGRADED mode. The loop stays alive; all project-tree writes are suspended."
        log "fs-guard: this cannot be repaired from inside the sandbox — it needs a restart from OUTSIDE. Never remount, bind, or unshare around it."
        _fs_escalate_once
    fi
    FS_DEGRADED_CYCLES=$(( FS_DEGRADED_CYCLES + 1 ))
    return 1
}

