#!/usr/bin/env bash
# Auto-continue plan: which workers a running recovery is about to resume by
# ITSELF, so nobody else resumes them too.
#
# The incident (2026-09-27, 11:49). A sandbox restart booted with
# `--continue`. `monitor/bootstrap-recover.sh` brings the orchestrator up
# FIRST (your-org/your-nexus#202) and only then resumes the prior workers
# (`spawn-worker.sh --resume`, one at a time). The orchestrator's recovery
# brief is composed at the moment it is spawned, so it showed a tmux server
# holding nothing but `bash` and said "Confirm your last in-flight
# delegation". The workers (authmail, ncbundle7, ncbundle7sk, mirrorsync)
# came back 50-104 s later. The orchestrator read the brief as "the workers
# are gone" and ran `spawn-worker.sh --resume` on three of them IN PARALLEL
# with recovery's own resume, which can run one Claude session in two panes.
#
# Recovery writes a PLAN before it spawns the orchestrator (the brief reads
# it), updates each row as it goes, and marks it done at the end. Three
# readers:
#
#   - `watcher/spawn-fresh-orchestrator.sh` renders it into the brief:
#     every worker by name, its session id, and whether its window is up
#     or still pending, plus a plain "do NOT resume these by hand".
#   - `spawn-worker.sh --resume` refuses (exit 27) to resume a window the
#     ACTIVE plan still lists as pending, unless the caller carries the
#     plan's token (recovery itself) or passes `--replace`.
#   - `monitor/_autocontinue_plan.sh status`, the live view, for an
#     orchestrator reading a brief that is minutes old.
#
# "Active" means the plan's OWNER PROCESS is still alive (pid AND /proc
# start time, so a recycled pid is not mistaken for it) and the plan is not
# marked done. A recovery that dies mid-walk therefore stops blocking hand
# resumes the moment it is gone. There is no TTL to tune.
#
# The second guard, `ac_session_held`, answers a narrower question with a
# different instrument: does a LIVE `claude` process hold this session id
# right now? It reads Claude Code's own per-process registry
# (`~/.claude/sessions/<pid>.json`: pid, sessionId, procStart, pidDomain),
# never argv. A `claude` process's argv IS its prompt, so an argv match
# would accept any agent whose brief merely MENTIONS the id
# (your-org/nexus-code#1073, #1612). The registry is the HARNESS's file, so
# its absence is "cannot tell" (rc 3), never "not held".
#
# File: $STATE_DIR/auto-continue-plan.tsv
#   line 1: #owner<TAB>pid<TAB>starttime<TAB>token<TAB>epoch<TAB>state<TAB>boot
#           state ∈ running | done; boot ∈ continue | mid-life
#   rows:   window<TAB>session-id|-<TAB>status<TAB>epoch<TAB>why
#           status ∈ pending | resumed | already-alive | held-live
#                    | over-cap:<max_workers> | skipped:<why> | failed:<rc>
#           why    ∈ active | engaged | follow-up:<signals> — WHY recovery
#                    resumes it (bootstrap-recover.sh's predicate). A LABEL:
#                    nothing selects on it. Absent on a plan written before
#                    the column existed; the renderer then omits it.
#
# Side-effect-free on source. Run directly with `status [state-dir]` for
# the live rendering.

# Path of the plan. Arg: $1 state dir.
ac_plan_path() { printf '%s/auto-continue-plan.tsv' "$1"; }

# /proc/<pid>/stat field 22 (start time in clock ticks), or empty. Parsed
# after the LAST ')' because field 2 (comm) may contain spaces or parens.
ac_proc_starttime() {
    local stat rest
    stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    rest="${stat##*) }"
    local -a f
    read -ra f <<<"$rest"
    # rest starts at field 3, so field 22 is index 19.
    [[ "${f[19]:-}" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "${f[19]}"
}

# rc 0 iff <pid> is alive AND is the same process that recorded <start>.
ac_pid_is() {
    local pid="$1" start="$2" now
    [[ "$pid" =~ ^[0-9]+$ && "$start" =~ ^[0-9]+$ ]] || return 1
    now=$(ac_proc_starttime "$pid") || return 1
    [[ "$now" == "$start" ]]
}

# Atomic rewrite: stdin → the plan path. Never leaves a torn file for a
# concurrent reader (the brief, a hand --resume).
_ac_write() {
    local path="$1" tmp
    tmp="$path.tmp.$$"
    cat > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# ac_plan_begin <state-dir> <token> <boot> <window> <sid> <why> [<window> <sid> <why> ...]
# Owner is the CALLING shell ($$ — in a sourced library that is the script
# that sourced it, i.e. recovery). Every row starts `pending`.
#
# REFUSES (rc 2, nothing written) while ANOTHER live recovery owns an active
# plan: a second recovery during the walk (SessionStart hook on the
# orchestrator's resume, a manual `svc.sh up`) used to overwrite it, which
# turned the first recovery's own resumes into exit-27 refusals (skeptic F1
# on #1660). The caller then leaves that plan's pending windows alone.
ac_plan_begin() {
    local state_dir="$1" token="$2" boot="$3"; shift 3
    local start now
    if ac_plan_active "$state_dir" && [[ "$(_ac_owner_field "$state_dir" 2)" != "$$" ]]; then
        return 2
    fi
    start=$(ac_proc_starttime "$$") || start=0
    now=$(date +%s)
    {
        printf '#owner\t%s\t%s\t%s\t%s\trunning\t%s\n' "$$" "$start" "$token" "$now" "$boot"
        while (( $# >= 3 )); do
            printf '%s\t%s\tpending\t%s\t%s\n' "$1" "${2:--}" "$now" "${3:--}"
            shift 3
        done
    } | _ac_write "$(ac_plan_path "$state_dir")"
}

# ac_plan_set_status <state-dir> <window> <status>
# <token>: the caller's plan token. A writer that no longer OWNS the plan
# (another recovery replaced it) must not touch it: rc 2, nothing written
# (skeptic F1 on #1660 — a concurrent recovery used to be marked done by the
# first one's finish while it was still walking).
ac_plan_set_status() {
    local state_dir="$1" window="$2" row_st="$3" token="$4" path now
    path=$(ac_plan_path "$state_dir")
    [[ -f "$path" ]] || return 1
    [[ "$(ac_plan_token "$state_dir")" == "$token" ]] || return 2
    now=$(date +%s)
    awk -F'\t' -v OFS='\t' -v w="$window" -v s="$row_st" -v t="$now" \
        'NR > 1 && $1 == w { $3 = s; $4 = t } { print }' "$path" \
        | _ac_write "$path"
}

# ac_plan_finish <state-dir> <token> — owner line state → done. Only the
# plan's own owner may finish it (rc 2 otherwise).
ac_plan_finish() {
    local path
    path=$(ac_plan_path "$1")
    [[ -f "$path" ]] || return 0
    [[ "$(ac_plan_token "$1")" == "$2" ]] || return 2
    awk -F'\t' -v OFS='\t' 'NR == 1 && $1 == "#owner" { $6 = "done" } { print }' "$path" \
        | _ac_write "$path"
}

# ac_plan_owner_field <state-dir> <n> — field n (1-based) of the owner line.
_ac_owner_field() {
    local path
    path=$(ac_plan_path "$1")
    awk -F'\t' -v n="$2" 'NR == 1 && $1 == "#owner" { print $n; exit }' "$path" 2>/dev/null
}

# ac_plan_active <state-dir>
#   0  a plan exists, is marked running, and its owner process is alive
#   1  no plan, plan done, or owner gone (a dead recovery blocks nothing)
#   3  CANNOT TELL: the plan exists and could not be read or parsed
ac_plan_active() {
    local path pid start state
    path=$(ac_plan_path "$1")
    [[ -e "$path" ]] || return 1
    { : ; } 2>/dev/null < "$path" || return 3
    [[ "$(head -c 7 "$path" 2>/dev/null)" == "#owner"$'\t' ]] || return 3
    pid=$(_ac_owner_field "$1" 2)
    start=$(_ac_owner_field "$1" 3)
    state=$(_ac_owner_field "$1" 6)
    [[ "$pid" =~ ^[0-9]+$ && "$start" =~ ^[0-9]+$ ]] || return 3
    case "$state" in
        running) ;;
        done)    return 1 ;;
        *)       return 3 ;;
    esac
    ac_pid_is "$pid" "$start" || return 1
    return 0
}

# ac_plan_token <state-dir> — the plan's token (recovery's exemption).
ac_plan_token() { _ac_owner_field "$1" 4; }

# ac_plan_pending_match <state-dir> <window> <sid>
# rc 0 (and prints the matching window) iff a PENDING row names <window>
# or carries <sid>. Callers check ac_plan_active first.
ac_plan_pending_match() {
    local path
    path=$(ac_plan_path "$1")
    awk -F'\t' -v w="$2" -v s="$3" '
        NR > 1 && $3 == "pending" && ($1 == w || (s != "" && s != "-" && $2 == s)) { print $1; found = 1; exit }
        END { exit found ? 0 : 1 }' "$path" 2>/dev/null
}

# Claude Code's per-process session registry.
ac_sessions_dir() {
    printf '%s' "${NEXUS_CC_SESSIONS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions}"
}

# ac_session_held <session-id>
#   0  a LIVE process holds it — prints "pid=<p> name=<n> tmux=<t>"
#   1  the registry was read and no live entry holds it
#   3  CANNOT TELL: no registry dir, unreadable, or jq missing
# A registry entry is live only when /proc/<pid> exists with the SAME start
# time the entry recorded, and — when the entry names a pid namespace — the
# namespace is ours. Both matter here: the registry outlives a sandbox
# restart, and the restarted namespace reuses the old pid numbers.
ac_session_held() {
    local sid="$1" dir f pid start name tmux dom ns
    dir=$(ac_sessions_dir)
    [[ -d "$dir" && -r "$dir" && -x "$dir" ]] || return 3
    command -v jq >/dev/null 2>&1 || return 3
    ns=$(readlink /proc/self/ns/pid 2>/dev/null || true)
    local rows
    # One jq over every entry; a malformed file is skipped, not fatal.
    rows=$(for f in "$dir"/*.json; do
               [[ -f "$f" ]] || continue
               jq -r --arg s "$sid" \
                  'select(.sessionId == $s) | [(.pid|tostring), (.procStart // ""|tostring), (.name // "-"), (.tmux // "-"), (.pidDomain // "")] | @tsv' \
                  "$f" 2>/dev/null || true
           done) || true
    while IFS=$'\t' read -r pid start name tmux dom; do
        [[ -n "$pid" ]] || continue
        if [[ -n "$dom" && -n "$ns" && "$dom" != *":$ns" ]]; then
            continue
        fi
        if ac_pid_is "$pid" "$start"; then
            printf 'pid=%s name=%s tmux=%s' "$pid" "$name" "$tmux"
            return 0
        fi
    done <<<"$rows"
    return 1
}

# Window names currently in tmux, one per line. rc 1 when tmux could not
# be asked — the caller must then say it cannot tell, never "not up".
_ac_tmux_windows() {
    command -v tmux >/dev/null 2>&1 || return 1
    tmux list-windows -F '#W' 2>/dev/null
}

# ac_plan_render <state-dir> — the brief's markdown section. Prints nothing
# (rc 1) when no plan is active. The one sentence it must never imply is
# "these workers are gone".
ac_plan_render() {
    local state_dir="$1" path rc=0
    path=$(ac_plan_path "$state_dir")
    ac_plan_active "$state_dir" || rc=$?
    if (( rc == 1 )); then
        return 1
    fi
    if (( rc == 3 )); then
        printf '## Worker auto-continue: CANNOT TELL\n\n'
        printf 'A recovery plan exists at `%s` but could not be read or parsed, so this brief\n' "$path"
        printf 'cannot tell whether workers are being resumed automatically right now.\n'
        printf 'Do NOT conclude that workers missing from tmux are gone, and do not resume any\n'
        printf 'by hand until `tmux list-windows` has been stable for a couple of minutes.\n\n'
        return 0
    fi
    local pid boot windows tmux_ok=1 n_pending=0
    pid=$(_ac_owner_field "$state_dir" 2)
    boot=$(_ac_owner_field "$state_dir" 7)
    windows=$(_ac_tmux_windows) || tmux_ok=0
    printf '## Worker auto-continue IN PROGRESS: do NOT resume these workers by hand\n\n'
    if [[ "$boot" == continue ]]; then
        printf 'The nexus restarted with `--continue`. '
    fi
    printf 'Recovery (`monitor/bootstrap-recover.sh`, pid %s) is resuming the workers below\n' "$pid"
    printf 'ITSELF, one at a time, after bringing you up first. Windows missing from tmux\n'
    printf 'are not gone: they are queued. A hand `spawn-worker.sh --resume` racing recovery\n'
    printf 'can run one session in two panes; it now refuses a pending window (exit 27) and\n'
    printf 'any session a live process already holds (exit 26).\n\n'
    local window sid row_st _t why state because
    while IFS=$'\t' read -r window sid row_st _t why; do
        [[ -n "$window" ]] || continue
        if (( tmux_ok == 1 )) && grep -Fxq -- "$window" <<<"$windows"; then
            state="**up** (window is live)"
        elif (( tmux_ok == 0 )); then
            state="CANNOT TELL (tmux list-windows failed); recovery status: $row_st"
        else
            case "$row_st" in
                pending)       state="**pending**: recovery has not reached it yet; its window will appear"
                               n_pending=$(( n_pending + 1 )) ;;
                resumed)       state="resumed, but its window is not visible yet — cannot tell if it came up" ;;
                already-alive|held-live)
                               state="recovery found it already running ($row_st) but its window is not visible — cannot tell" ;;
                over-cap*)     state="**NOT auto-continued**: past recovery's sanity cap (recover.max_workers=${row_st#over-cap:}, counted in candidate order, alive windows included) — yours to decide" ;;
                skipped:*|failed:*)
                               state="**NOT auto-continued** (${row_st}): yours to decide" ;;
                *)             state="unknown recovery status '$row_st' — cannot tell" ;;
            esac
        fi
        # WHY recovery took it: an active worker was interrupted mid-task; an
        # engaged one is the operator's session; a follow-up one had WRAPPED
        # but was dispatched another round, held, or is in an open skeptic
        # pairing — so "it wrapped" does not mean "it is done".
        case "${why:-}" in
            ''|-)         because="" ;;
            active)       because=" (why: active, interrupted mid-task)" ;;
            engaged)      because=" (why: operator-engaged)" ;;
            follow-up:*)  because=" (why: wrapped, but follow-up live: ${why#follow-up:})" ;;
            *)            because=" (why: $why)" ;;
        esac
        printf -- '- `%s`: session `%s` — %s%s\n' "$window" "$sid" "$state" "$because"
    done < <(awk 'NR > 1' "$path" 2>/dev/null)
    printf '\nAs of %s. Live view: `monitor/_autocontinue_plan.sh status`.\n\n' "$(date -Is)"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        status)
            _sd="${2:-${NEXUS_STATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.state}}"
            if ! ac_plan_render "$_sd"; then
                echo "no auto-continue in progress (no active plan at $(ac_plan_path "$_sd"))"
            fi ;;
        held)
            [[ -n "${2:-}" ]] || { echo "usage: $0 held <session-id>" >&2; exit 2; }
            ac_session_held "$2"; _rc=$?; echo; exit "$_rc" ;;
        *)  echo "usage: $0 status [state-dir] | held <session-id>" >&2; exit 2 ;;
    esac
fi
