#!/usr/bin/env bash
# svc.sh — nexus service cockpit + unified service CLI.
#
# DASHBOARD (default, read-only): one screen shows the whole nexus
# stack — the core (watcher + orchestrator, pinned) and every service
# registered in services.registry — with live status, auto-refreshing
# in place (no flicker). Single-key controls:
#   1-9     tail that service's log — in a tmux split pane when inside
#           tmux (scroll via copy-mode, `prefix + [`; the cockpit keeps
#           focus), else inline (Ctrl-C returns)
#   0       tail the watcher's logs (monitor/.state/watcher.log startup
#           sweep + watcher-scheduler.jsonl live per-fire telemetry)
#   x       close the log split
#   n / p   next / previous page when the table overflows the pane.
#           Rendering is height-aware: the core rows and every
#           unhealthy service are ALWAYS visible — only healthy rows
#           page, and an explicit `+N more ... page X/Y` line counts
#           whatever is off-screen (red if anything unhealthy is).
#   r       refresh now            q  quit
# The dashboard never launches, restarts, or kills anything.
#
# Dormant capabilities are ADVERTISED: when no real `jupyterlab`
# row exists in services.registry, the listing shows a synthesized,
# display-only DOWN row with an activation hint (or a labsh-install
# pointer when labsh is absent). The virtual row is never written to
# the registry, so bootstrap-recover.sh can never auto-start it.
#
# VERBS (explicit and scriptable — these DO act):
#   svc.sh status            print one status table and exit
#   svc.sh up [--dry-run] [--no-services] [--no-workers]
#                            idempotent whole-stack bring-up. Delegates
#                            to bootstrap-recover.sh (watcher +
#                            services + last-snapshot workers).
#                            `--no-services` brings up the nexus core
#                            only — the watcher plus the orchestrator
#                            it manages — and skips every registered
#                            service AND every worker respawn.
#                            `--no-workers` skips only the worker
#                            respawn (services still recover). The
#                            watcher then spawns/revives the
#                            orchestrator via its own liveness
#                            machinery — `up` does not (and must not)
#                            spawn the orchestrator directly.
#   svc.sh start <name>      start one service iff not running (same
#                            idempotent decision path as recovery)
#   svc.sh stop <name>       stop a service: TERM its supervisor's
#                            process group, escalate to KILL after 5 s
#   svc.sh restart <name>    stop + start (`restart watcher` uses
#                            launcher.sh --replace)
#   svc.sh logs <name>       tail -F the service's log(s) in this
#                            terminal — for labsh JupyterLab services
#                            the server's own stdout
#                            (.jupyter/labsh.bg.log) is tailed too
#
# `watcher` is addressable by every verb. The orchestrator is
# watcher-managed: it has no start/stop verbs here by design.
#
# SANDBOX-AGNOSTIC by design: nothing here wraps itself in
# agent-sandbox. Choose the execution context explicitly:
#     agent-sandbox monitor/svc.sh up     # sandboxed
#     monitor/svc.sh up                   # bare host
#
# Data source — the SAME declarative registry the recovery path uses:
#   $NEXUS_ROOT/monitor/services.registry   (operator-local, gitignored)
# Format + schema: monitor/services.registry.example (optional 5th
# field = logfile; absent -> <workdir>/serve.log). This tool sources
# bootstrap-recover.sh and reuses its primitives, so status/health/
# launch semantics here are exactly recovery's — no second
# implementation to drift.
#
# Launch the dashboard as its own tmux window (name must match
# monitor.services_window, default `services`, so the watcher's
# idle probe exempts it from the dead-worker sweep):
#   tmux new-window -n services 'monitor/svc.sh'
#
# Env:
#   NEXUS_ROOT  — live nexus root the registry + logs + state are read
#                 from (default: script-relative, the monitor/ parent).
#                 Point it at a checkout to drive the cockpit off that
#                 tree.
#   SVC_REFRESH — dashboard auto-refresh interval, seconds (default 5).

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Live nexus root: where the registry + service logs actually live.
# Defaults script-relative (the monitor/ dir's parent), matching the
# siblings this script sources (bootstrap-recover.sh, boot-recover.sh) —
# so a checkout's svc.sh drives its OWN tree, never a hardcoded operator's.
# Running from a dev clone against the live tree? Set NEXUS_ROOT explicitly.
_nexus_root_default=$(cd "$_script_dir/.." && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$_nexus_root_default}"
export NEXUS_ROOT
SERVICES_REGISTRY="${NEXUS_SERVICES_REGISTRY:-$NEXUS_ROOT/monitor/services.registry}"
REFRESH="${SVC_REFRESH:-5}"

# Reuse the recovery path's primitives so health/launch/liveness
# semantics match exactly. bootstrap-recover.sh guards its main behind
# a BASH_SOURCE test, so sourcing yields the functions (and, via its
# own source of watcher/_lib.sh, the watcher liveness probes) plus the
# STATE_DIR / INTERVAL / _cfg globals — with no side effects.
# shellcheck source=bootstrap-recover.sh
source "$_script_dir/bootstrap-recover.sh"

# The tmux window the watcher pastes into — the orchestrator's home.
# The cockpit window name (this dashboard) is config-resolved too, so
# the idle-probe exemption and the cockpit's own window all track one
# value instead of a literal scattered across scripts (your-nexus#204).
if [[ -x "$_cfg" ]]; then
    TARGET_WINDOW=$("$_cfg" monitor.target_window orchestrator)
    SERVICES_WINDOW="${MONITOR_SERVICES_WINDOW:-$("$_cfg" monitor.services_window services)}"
else
    TARGET_WINDOW=orchestrator
    SERVICES_WINDOW="${MONITOR_SERVICES_WINDOW:-services}"
fi
WATCHER_HB="$STATE_DIR/watcher-heartbeat"
ORCH_HB="$STATE_DIR/orchestrator-heartbeat"
WATCHER_LOG="$STATE_DIR/watcher.log"
WATCHER_PIDFILE="$STATE_DIR/watcher.pid"
# Watcher-supervision (your-org/your-nexus, mutual-liveness design). The
# ORCHESTRATOR arms a Monitor that revives a crashed watcher and TOUCHES
# this heartbeat each tick; the cockpit's `watcher-sup` row reads
# ARMED/UNARMED from its freshness. The stop sentinel lets an intentional
# `stop watcher` be respected even by a still-armed Monitor (revive-
# watcher.sh refuses while it exists); start/restart clear it.
WATCHER_SUP_HEARTBEAT="$STATE_DIR/watcher-supervisor-heartbeat"
WATCHER_STOP_SENTINEL="$STATE_DIR/watcher-stop-requested"
WATCHER_SUP_STALE_SECONDS="${MONITOR_WATCHER_SUPERVISOR_HEARTBEAT_STALE_SECONDS:-90}"
[[ "$WATCHER_SUP_STALE_SECONDS" =~ ^[0-9]+$ ]] || WATCHER_SUP_STALE_SECONDS=90
# Per-fire scheduler telemetry (heartbeat / target_window / paste rows).
# After the scheduler handoff the watcher logs ALL ongoing activity here;
# watcher.log only ever holds the startup sweep, so tailing it alone shows
# a frozen log and reads as a dead watcher. Same default as main.sh.
SCHEDULER_LOG="${MONITOR_SCHEDULER_LOG:-$STATE_DIR/watcher-scheduler.jsonl}"

# --- colours (degrade gracefully on dumb terminals) -----------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 \
   && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    C_G=$(tput setaf 2); C_R=$(tput setaf 1); C_Y=$(tput setaf 3)
    C_DIM=$(tput dim);   C_B=$(tput bold);    C_0=$(tput sgr0)
else
    C_G=''; C_R=''; C_Y=''; C_DIM=''; C_B=''; C_0=''
fi

# --- registry parsing (5-field aware) -------------------------------------
#
# Modelled on bootstrap-recover.sh's _recover_parse_registry, extended to
# carry the optional 5th <logfile> column. Emits one validated record per
# line: name\tworkdir\tlaunch\thealth\tlogfile  (logfile may be empty →
# caller defaults it). Blank/`#` lines skipped; a row with fewer than the
# 4 required fields is skipped with a warning, never fatal.
svc_parse_registry() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local line name workdir launch health logfile rest
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        IFS=$'\t' read -r name workdir launch health logfile rest <<<"$line"
        if [[ -z "$name" || -z "$workdir" || -z "$launch" || -z "$health" ]]; then
            echo "[svc] registry: skipping malformed line (need ≥4 TAB fields): $line" >&2
            continue
        fi
        # Expand ~ and $NEXUS_ROOT in workdir + logfile for portability.
        workdir="${workdir/#\~/$HOME}"; workdir="${workdir//\$NEXUS_ROOT/$NEXUS_ROOT}"
        logfile="${logfile/#\~/$HOME}"; logfile="${logfile//\$NEXUS_ROOT/$NEXUS_ROOT}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$workdir" "$launch" "$health" "$logfile"
    done < "$file"
}

# Resolve a service's logfile: explicit 5th column if present, else the
# <workdir>/serve.log default. Relative paths resolve under workdir.
svc_logfile() {
    local workdir="$1" logfield="$2" lf
    lf="${logfield:-$workdir/serve.log}"
    [[ "$lf" != /* ]] && lf="$workdir/$lf"
    printf '%s' "$lf"
}

# Every log worth tailing for a service, one path per line: the registry
# logfile first, then — for labsh JupyterLab services — the server's own
# stdout (.jupyter/labsh.bg.log, which prints the tokened URL on
# startup; that is how browser users retrieve the token). The server log
# joins only when it exists, so non-jupyter services and missing files
# never produce noise. Always returns 0.
svc_log_files() {
    local workdir="$1" lf="$2" srv
    srv="$workdir/.jupyter/labsh.bg.log"
    printf '%s\n' "$lf"
    [[ -f "$srv" && "$srv" != "$lf" ]] && printf '%s\n' "$srv"
    return 0
}

# Every log worth tailing for the watcher core row, one path per line:
# the startup log (launch context) plus the scheduler's per-fire jsonl
# (the only file that moves once the scheduler takes over). Only files
# that exist are emitted — a fresh boot without a jsonl yet tails the
# startup log alone, and nothing here ever errors the cockpit. Empty
# output means neither exists; callers decide how loudly to say so.
watcher_log_files() {
    local f
    for f in "$WATCHER_LOG" "$SCHEDULER_LOG"; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
    done
    return 0
}

# Headless-supervisor state from the per-service pidfile, reusing recovery's
# OWN primitive (_recover_supervisor_state: pid alive AND cmdline still
# matches the wrapper) so the cockpit and recovery never diverge on "is the
# supervisor up?".
#
# The optional 3rd arg is the service's CURRENT health verdict ('UP' when the
# registry healthcheck passes). It exists so the cell never prints a word
# that contradicts the STATUS column without saying so:
#
#   pid:N    a live supervisor.
#   orphan   the pid record is dead BUT the healthcheck passes — the daemon
#            outlived its supervisor and is running UNSUPERVISED. `stale`
#            here read as "ignore me, cosmetic"; it is the opposite. Nothing
#            is left to perform the wrapper self-heal that the watcher's
#            grace window defers to.
#   stale    the pid record is dead and the service is DOWN too. Consistent:
#            the supervisor died and took the service with it; recovery will
#            relaunch on the next bootstrap/health tick.
#   -        no pidfile — unmanaged or not-yet-migrated. Nothing to contradict.
#
# Callers that pass no health verdict (unit tests, ad-hoc probes) keep the
# original two-state `pid:N` / `stale` / `-` contract.
svc_supervisor() {
    local name="$1" launch="$2" up="${3:-}" st
    st=$(_recover_supervisor_state "$name" "$launch")
    case "$st" in
        alive:*) printf 'pid:%s' "${st#alive:}" ;;
        absent)  printf '%s' '-' ;;
        *)       [[ "$up" == UP ]] && printf 'orphan' || printf 'stale' ;;
    esac
}

# --- external-bind detection (display only) --------------------------------
# Healthchecks probe http://localhost:PORT, but a service bound to
# 0.0.0.0/::/a routable IP is reachable from outside — render the real
# host so the DETAIL column is a copy-pasteable, externally valid URL.
# Signal: the live listening socket's bind address (ss -ltn) — it
# reflects what the service actually did, independent of how it was
# launched or configured. Any non-loopback listener on the URL's port
# => external. No listener (service down), no `ss`, or no parsable
# port => keep the URL untouched. Healthcheck COMMANDS are never
# rewritten; they keep probing localhost.

SVC_FQDN=''         # cached once per process: hostname -f can hit DNS
SVC_LISTEN=''       # ss snapshot, refreshed at most once per frame
SVC_LISTEN_FRESH=0  # render_status resets this each frame
ORPHAN_N=0          # healthy-but-unsupervised rows in the current frame

svc_fqdn() {
    [[ -n "$SVC_FQDN" ]] || SVC_FQDN=$(hostname -f 2>/dev/null || hostname)
    printf '%s' "$SVC_FQDN"
}

# True iff some listener on local TCP port $1 binds beyond loopback.
svc_port_is_external() {
    local port="$1" la addr
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    if (( ! SVC_LISTEN_FRESH )); then
        SVC_LISTEN=$(ss -ltnH 2>/dev/null) || SVC_LISTEN=''
        SVC_LISTEN_FRESH=1
    fi
    while read -r la; do
        [[ "${la##*:}" == "$port" ]] || continue
        addr="${la%:*}"
        case "$addr" in
            127.*|'[::1]') ;;     # loopback listener — keep scanning
            *) return 0 ;;        # 0.0.0.0 / [::] / * / routable IP
        esac
    done < <(awk '{print $4}' <<<"$SVC_LISTEN")
    return 1
}

# Display-only rewrite: http(s)://localhost:PORT... gets the real FQDN
# when the port is bound beyond loopback; loopback-only binds, down
# services, and URLs without an explicit port pass through unchanged.
svc_display_url() {
    local url="$1" scheme rest host port
    scheme="${url%%://*}"; rest="${url#*://}"
    host="${rest%%[:/]*}"
    [[ "$host" == localhost || "$host" == 127.0.0.1 ]] || { printf '%s' "$url"; return; }
    port="${rest#"$host":}"; port="${port%%[!0-9]*}"
    if [[ -n "$port" ]] && svc_port_is_external "$port"; then
        printf '%s://%s%s' "$scheme" "$(svc_fqdn)" "${rest#"$host"}"
    else
        printf '%s' "$url"
    fi
}

# Tokened, directly-openable URL for a labsh JupyterLab service. This
# cockpit serves an internal lab network, so showing the token is the
# point: the DETAIL cell is meant to be copy-pasted straight into a
# browser. Reads PORT/SCHEME from .jupyter/labsh-service.env and the
# token from .jupyter/token (both written by labsh-supervised.sh /
# labsh); host rewritten to the FQDN when the bind is external (same
# rule as svc_display_url). Returns 1 when no port is recorded — the
# caller falls back to the generic endpoint; a missing token degrades
# to the bare URL. Never errors.
svc_jupyter_url() {
    local workdir="$1" env_file="$1/.jupyter/labsh-service.env"
    local port scheme token url
    port=$(sed -n 's/^PORT=//p' "$env_file" 2>/dev/null | head -1)
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    scheme=$(sed -n 's/^SCHEME=//p' "$env_file" 2>/dev/null | head -1)
    case "$scheme" in http|https) ;; *) scheme=http ;; esac
    url=$(svc_display_url "$scheme://localhost:$port/lab")
    token=$(tr -d '[:space:]' < "$workdir/.jupyter/token" 2>/dev/null)
    [[ -n "$token" ]] && url+="?token=$token"
    printf '%s' "$url"
}

# Best-effort human endpoint for a healthcheck: the URL for curl checks
# (rewritten to the real host when externally bound), pid:N for pgrep
# checks, else "-". Purely cosmetic.
svc_endpoint() {
    local health="$1" url pat pid
    url=$(grep -oE 'https?://[^ ]+' <<<"$health" | head -1)
    if [[ -n "$url" ]]; then svc_display_url "$url"; return; fi
    if [[ "$health" == *pgrep* ]]; then
        pat=$(sed -nE 's/.*pgrep[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-f[[:space:]]+([^ ]+).*/\2/p' <<<"$health")
        [[ -z "$pat" ]] && pat=$(sed -nE 's/.*pgrep[[:space:]]+([^ -][^ ]*).*/\1/p' <<<"$health")
        pid=$(pgrep -f "$pat" 2>/dev/null | head -1)
        [[ -n "$pid" ]] && printf 'pid:%s' "$pid" || printf 'pid:-'
        return
    fi
    printf '%s' '-'
}

# Compact age: 45s / 12m / 3h.
fmt_age() {
    local s="$1"
    if   (( s < 0 ));    then printf '?'
    elif (( s < 120 ));  then printf '%ds' "$s"
    elif (( s < 7200 )); then printf '%dm' $(( s / 60 ))
    else                      printf '%dh' $(( s / 3600 ))
    fi
}

# --- in-memory service table ----------------------------------------------
# Populated by load_services(): parallel arrays indexed 1..N for the menu.
declare -a SVC_NAME SVC_WORKDIR SVC_LAUNCH SVC_HEALTH SVC_LOG
SVC_N=0

load_services() {
    SVC_NAME=() SVC_WORKDIR=() SVC_LAUNCH=() SVC_HEALTH=() SVC_LOG=()
    SVC_N=0
    local name workdir launch health logfield
    while IFS=$'\t' read -r name workdir launch health logfield; do
        [[ -n "$name" ]] || continue
        SVC_N=$(( SVC_N + 1 ))
        SVC_NAME[$SVC_N]="$name"
        SVC_WORKDIR[$SVC_N]="$workdir"
        SVC_LAUNCH[$SVC_N]="$launch"
        SVC_HEALTH[$SVC_N]="$health"
        SVC_LOG[$SVC_N]="$(svc_logfile "$workdir" "$logfield")"
    done < <(svc_parse_registry "$SERVICES_REGISTRY")
}

# --- advertised capability: jupyterlab --------------------------------------
#
# The work-root JupyterLab (jupyter-up.sh --root) is a capability nearly
# every operator wants eventually, but it must never start unprompted.
# The cockpit therefore ADVERTISES it: when no real `jupyterlab`
# row exists in services.registry, the listing renders a synthesized,
# display-only DOWN row with an activate hint. The virtual row exists
# only in this renderer — it is never written to the registry, and
# bootstrap-recover.sh iterates the registry file exclusively, so
# recovery can never see or auto-start it. Once `jupyter-up.sh --root`
# creates the real row, that row wins and the advertisement disappears
# (and returns after `--down` deregisters it).
#
# Must match ROOT_SERVICE_NAME in jupyter-up.sh.
ADVERTISED_JUPYTER='jupyterlab'

# PATH probe only — rendering the advertisement must never execute
# labsh (the row is the discovery surface; it has to show on hosts
# without labsh installed).
_labsh_available() { command -v labsh >/dev/null 2>&1; }

# Real-row check against the loaded table (call after load_services).
_jupyter_root_registered() {
    local i
    for (( i=1; i<=SVC_N; i++ )); do
        [[ "${SVC_NAME[$i]}" == "$ADVERTISED_JUPYTER" ]] && return 0
    done
    return 1
}

# Detail-column hint: the activation command when
# labsh is on PATH, the installer when it isn't. jupyter-up.sh itself
# fails loud on missing labsh/uv with install instructions, so the
# activate hint is safe to show whenever labsh is present.
_jupyter_hint() {
    if _labsh_available; then
        printf '%s' 'monitor/jupyter-up.sh --root'
    else
        printf '%s' 'monitor/install-labsh.sh'
    fi
}

# Look up a registry service by name; sets REG_I or dies listing what
# exists. Core names get a pointed redirect instead of "unknown".
svc_require() {
    local name="$1" i
    load_services
    for (( i=1; i<=SVC_N; i++ )); do
        [[ "${SVC_NAME[$i]}" == "$name" ]] && { REG_I=$i; return 0; }
    done
    # Advertised-but-dormant capability: the cockpit shows it, but no
    # registry row exists until activation — redirect there.
    if [[ "$name" == "$ADVERTISED_JUPYTER" ]]; then
        echo "svc.sh: '$ADVERTISED_JUPYTER' is advertised but not activated — activate with: monitor/jupyter-up.sh --root" >&2
        exit 1
    fi
    echo "svc.sh: unknown service '$name' (registry: $SERVICES_REGISTRY)" >&2
    if (( SVC_N > 0 )); then
        echo "  registered: ${SVC_NAME[*]:1:$SVC_N} (+ watcher)" >&2
    else
        echo "  registry is empty; 'watcher' is still addressable" >&2
    fi
    exit 1
}

# --- status rendering -------------------------------------------------------
#
# Flicker-free: the frame is accumulated in $FRAME and emitted in one
# write. In dashboard mode (INPLACE=1) we home the cursor instead of
# clearing, terminate every line with clear-to-EOL, and clear below the
# prompt with clear-to-end-of-screen — so a refresh repaints in place
# with no blank-screen flash. A full `clear` happens only on the first
# draw and after a terminal resize (WINCH).
#
# HEIGHT-AWARE (dashboard mode only): the frame is budgeted against the
# pane height so it can never scroll — a taller-than-pane frame used to
# push the TOP rows (exactly the pinned core rows and the earliest DOWN
# rows) silently off-screen and pile a stale duplicate frame into
# scrollback every refresh tick. When the registry rows overflow the
# budget: core rows and unhealthy rows are ALWAYS visible; healthy rows
# fill the remaining space and page via n/p; anything hidden is counted
# on an explicit indicator line (red when unhealthy rows are off-page,
# which can only happen when the unhealthy rows ALONE overflow the
# pane). The non-TTY `status` verb is never budgeted: scripts and
# agents always get the full table.
INPLACE=0
NEED_CLEAR=0
EL='' ED=''
FRAME=''
MSG=''            # one-shot notice rendered under the table
SVC_FOLLOW=''     # name whose log the split/inline tail is following
TERM_ROWS=0       # pane height (0 = unbudgeted, non-TTY)
TERM_COLS=80      # pane width, for wrap-aware line costs
FRAME_COST=0      # physical lines in $FRAME at TERM_COLS
COST=1            # line_cost() result (global: no subshell per line)
SVC_PAGE=1        # current page of the paged healthy rows
SVC_PAGES=1       # recomputed every frame by render_status
PROMPT_RESERVE=2  # rows kept free for the input prompt (may wrap once)

# Pane geometry, re-probed every frame: tracks WINCH and the log split
# (the split shrinks this pane's pty, so `tput lines` already reflects
# it). SVC_ROWS/SVC_COLS env override everything (tests, odd
# terminals). Detection failure must NEVER error the cockpit: fall back
# to a conservative 24x80.
term_geometry() {
    local r="${SVC_ROWS:-}" c="${SVC_COLS:-}"
    [[ "$r" =~ ^[0-9]+$ ]] || r=$(tput lines 2>/dev/null)
    [[ "$c" =~ ^[0-9]+$ ]] || c=$(tput cols 2>/dev/null)
    [[ "$r" =~ ^[0-9]+$ ]] || r="${LINES:-}"
    [[ "$c" =~ ^[0-9]+$ ]] || c="${COLUMNS:-}"
    if [[ -n "${TMUX:-}" ]]; then
        [[ "$r" =~ ^[0-9]+$ ]] || r=$(tmux display-message -p '#{pane_height}' 2>/dev/null)
        [[ "$c" =~ ^[0-9]+$ ]] || c=$(tmux display-message -p '#{pane_width}' 2>/dev/null)
    fi
    [[ "$r" =~ ^[0-9]+$ ]] && (( r >= 5 ))  || r=24
    [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 20 )) || c=80
    TERM_ROWS=$r TERM_COLS=$c
}

# extglob powers the SGR-stripping patterns in line_cost; enabled here,
# before that definition is parsed, and deliberately not reverted
# (sourcing callers tolerate it; nothing below depends on it being off).
shopt -s extglob

# Physical terminal lines a rendered line occupies at TERM_COLS — wraps
# counted, colour escapes (SGR, plus the \e(B half of tput sgr0)
# zero-width. Result lands in $COST: this runs per line per frame, so
# no $(...) subshell. Under a non-UTF-8 locale ${#s} counts bytes,
# which can only OVER-estimate width — errs toward a shorter frame,
# never toward scrolling.
line_cost() {
    local s="$1"
    if [[ "$s" == *$'\e'* ]]; then
        s=${s//$'\e'\[*([0-9;])[a-zA-Z]/}
        s=${s//$'\e'\(B/}
    fi
    COST=1
    (( TERM_COLS > 0 && ${#s} > TERM_COLS )) \
        && COST=$(( (${#s} + TERM_COLS - 1) / TERM_COLS ))
}

emit() { FRAME+="$1$EL"$'\n'; line_cost "$1"; FRAME_COST=$(( FRAME_COST + COST )); }

# One service-style row, rendered into $ROW (emit_row appends it to the
# frame; render_status pre-renders registry rows through format_row so
# the height budget can weigh them before deciding what to show). Args:
# gutter key name color status sup_color sup detail. DETAIL is the last
# column and renders untruncated so a full tokened JupyterLab URL
# (~90-113 chars) survives intact; its wrap is priced by line_cost.
ROW=''
format_row() {
    local gut="$1" key="$2" name="$3" upc="$4" up="$5" supc="$6" sup="$7" detail="$8"
    printf -v ROW '%s%-2s %-*s %s%-8s%s %s%-10s%s %s' \
        "$gut" "$key" "$ROW_W" "$name" "$upc" "$up" "$C_0" \
        "$supc" "$sup" "$C_0" "$detail"
}
emit_row() { format_row "$@"; emit "$ROW"; }

# The filesystem row (your-org/nexus-code#473).
#
# Rendered ABOVE the per-service rows, because when the project tree is
# read-only every row below it is noise: services report `UP` from pidfiles
# and healthchecks that were true a moment ago and cannot be updated now,
# and nothing that reads this table can write anything. On 2026-07-09 this
# table cheerfully printed `UP` services while the watcher was dead and no
# agent in the workspace could save a file.
#
# The probe is a FRESH create+unlink (monitor/_fs_probe.sh) — never a stat,
# never a cached fd, both of which keep succeeding on a detached mount.
# Sets SVC_FS_OK for the caller's exit status.
SVC_FS_OK=1
render_fs_row() {
    local up upc detail
    # `nexus_path_writable` (monitor/_fs_probe.sh, in scope via
    # bootstrap-recover.sh -> watcher/_lib.sh) probes the nearest EXISTING
    # ancestor, so a fresh clone whose monitor/.state has never been created
    # reports OK rather than a spurious READ-ONLY.
    if nexus_path_writable "$STATE_DIR"; then
        SVC_FS_OK=1
        up='OK'; upc="$C_G"
        detail="$STATE_DIR writable"
    else
        SVC_FS_OK=0
        up='READ-ONLY'; upc="$C_R"
        detail="cannot write $STATE_DIR — restart the sandbox from OUTSIDE; every row below is stale"
    fi
    emit_row '' '' 'fs' "$upc" "$up" "$C_0" '' "$detail"
    if (( ! SVC_FS_OK )); then
        emit "${C_R}  the project filesystem is read-only. Nothing inside the sandbox can repair it.${C_0}"
        emit "${C_R}  No data is lost and the filer is healthy — do not page storage-support. See skills/nexus.service-recovery.${C_0}"
    fi
}

# Core rows: the watcher (UP/BUSY/WEDGED/DOWN trichotomy from
# _watcher_liveness_verdict — the exact probe recovery uses — plus a
# process-GROUP duplicate check, nexus-code#491) and the orchestrator
# (watcher-managed; window presence + turn-end heartbeat age). Pinned
# above the registry services because the GitHub integration hangs off
# them.
#
# WATCHER_DUP_N counts live watcher process groups beyond the first
# (plus decapitated orphan groups); `status` exits non-zero when it is
# >0 — a status line naming ONE pid while a second watcher runs is
# asserting a state that was never established.
WATCHER_DUP_N=0
render_core_rows() {
    local rc age pid up upc sup supc detail gut l

    local verdict state period cage page
    verdict=$(_watcher_liveness_verdict "$STATE_DIR" "$INTERVAL"); rc=$?
    state=$(_watcher_verdict_field "$verdict" state)
    period=$(_watcher_verdict_field "$verdict" period_s)
    cage=$(_watcher_verdict_field "$verdict" cycle_age)
    page=$(_watcher_verdict_field "$verdict" progress_age)
    age=$(_watcher_heartbeat_age "$WATCHER_HB")
    pid=$(_watcher_heartbeat_field "$WATCHER_HB" pid)
    case "$state" in
        UP)     up='UP';     upc="$C_G" ;;
        BUSY)   up='BUSY';   upc="$C_Y" ;;
        WEDGED) up='WEDGED'; upc="$C_R" ;;
        *)      up='DOWN';   upc="$C_R" ;;
    esac
    if [[ -n "$pid" ]] && _watcher_pid_is_live_watcher "$pid"; then
        sup="pid:$pid"; supc="$C_G"
    else
        sup='-'; supc="$C_DIM"
    fi
    case "$state" in
        UP)     detail="hb $(fmt_age "$age"), loop ~${period:-?}s -> $TARGET_WINDOW" ;;
        BUSY)   detail="alive+advancing (progress $(fmt_age "${page:-0}") ago), loop ~${period:-?}s, cycle $(fmt_age "${cage:-0}") ago — slow, NOT down" ;;
        WEDGED) detail="alive but NOT advancing (progress $(fmt_age "${page:-0}"), cycle $(fmt_age "${cage:-0}")) — revive: monitor/revive-watcher.sh" ;;
        *)      detail=$(_watcher_reason "$STATE_DIR" 2>/dev/null || echo 'not healthy') ;;
    esac
    gut=' '; [[ "$SVC_FOLLOW" == watcher ]] && gut='>'
    emit_row "$gut" '0' 'watcher' "$upc" "$up" "$supc" "$sup" "$detail"

    # Duplicate / decapitated watcher GROUPS (nexus-code#491). Counted
    # from the process table (argv identity + pgrp, never ppid==1);
    # two live groups = double emits + racing state writes, and a
    # leaderless group is a defunct loop nothing supervises. Either is
    # an attention row that must never hide behind a green 'UP'.
    WATCHER_DUP_N=0
    local _wg _wleader _wn _live_groups=() _dead_groups=()
    while IFS=$'\t' read -r _wg _wleader _wn; do
        [[ "$_wg" =~ ^[0-9]+$ ]] || continue
        if [[ "$_wleader" == live ]]; then _live_groups+=("$_wg"); else _dead_groups+=("$_wg"); fi
    done < <(_watcher_list_live_groups "$NEXUS_ROOT")
    if (( ${#_live_groups[@]} > 1 )); then
        WATCHER_DUP_N=$(( ${#_live_groups[@]} - 1 ))
        # Cross-check against the heartbeat's recorded pid so the row
        # says which group the rest of the stack believes in.
        local _hb_mark=''
        [[ -n "$pid" ]] && _hb_mark=" (heartbeat names $pid)"
        emit_row ' ' '!' 'watcher-dup' "$C_R" 'DUP' "$C_R" "${#_live_groups[@]}x" \
            "${#_live_groups[@]} live watcher groups (pgids: ${_live_groups[*]})${_hb_mark} — reconcile: monitor/svc.sh restart watcher"
    fi
    if (( ${#_dead_groups[@]} > 0 )); then
        WATCHER_DUP_N=$(( WATCHER_DUP_N + ${#_dead_groups[@]} ))
        emit_row ' ' '!' 'watcher-orphan' "$C_R" 'DECAP' "$C_R" '-' \
            "decapitated watcher group(s) ${_dead_groups[*]} (leader dead, loop still running) — reconcile: monitor/svc.sh restart watcher"
    fi

    # Watcher-supervisor row (mutual-liveness): ARMED iff the
    # orchestrator's Monitor has touched the supervisor heartbeat within
    # the staleness window. UNARMED is a real concern (a watcher crash
    # then has no turn-independent revival), so colour it red.
    local sup_age; sup_age=$(_watcher_heartbeat_age "$WATCHER_SUP_HEARTBEAT")
    [[ "$sup_age" =~ ^[0-9]+$ ]] || sup_age=999999
    if (( sup_age <= WATCHER_SUP_STALE_SECONDS )); then
        emit_row ' ' '-' 'watcher-sup' "$C_G" 'ARMED' "$C_DIM" 'monitor' \
            "orchestrator Monitor armed (hb $(fmt_age "$sup_age"))"
    else
        emit_row ' ' '-' 'watcher-sup' "$C_R" 'UNARMED' "$C_DIM" '-' \
            "no crash-revival — orchestrator must arm the supervisor Monitor"
    fi

    if _recover_window_exists "$TARGET_WINDOW"; then
        up='UP'; upc="$C_G"
    else
        up='DOWN'; upc="$C_R"
    fi
    # The watcher is the orchestrator's supervisor: it spawns/revives
    # the target window via its liveness machinery. Colour the word by
    # the watcher's own state so a dead supervisor is visible here too.
    sup='watcher'
    case "$rc" in 0) supc="$C_DIM" ;; 1) supc="$C_Y" ;; *) supc="$C_R" ;; esac
    if [[ -f "$ORCH_HB" ]]; then
        detail="last turn $(fmt_age "$(_watcher_heartbeat_age "$ORCH_HB")") ago"
    else
        detail='no turn-end heartbeat'
    fi
    emit_row ' ' '-' "$TARGET_WINDOW" "$upc" "$up" "$supc" "$sup" "$detail"
}

# Pre-render everything that follows the registry rows (advertised
# jupyterlab row, empty-registry notice, advertise hint, one-shot $MSG)
# into FOOT[]/FOOT_COST so render_status knows the frame's tail height
# BEFORE budgeting the rows. compact=1 drops the advertise hint block
# to reclaim lines once paging is already squeezing the pane (the row
# itself, with the activation command in DETAIL, always stays).
declare -a FOOT=()
FOOT_COST=0
build_footer() {
    local compact="$1" advertise="$2" l f
    FOOT=(); FOOT_COST=0
    if (( advertise )); then
        format_row ' ' '-' "$ADVERTISED_JUPYTER" "$C_DIM" 'DOWN' "$C_DIM" '-' \
            "$(_jupyter_hint)"
        FOOT+=("$ROW")
    fi
    if (( SVC_N == 0 )); then
        FOOT+=('')
        printf -v l '%sno registered services%s (expected at %s)' \
            "$C_R" "$C_0" "$SERVICES_REGISTRY"
        FOOT+=("$l")
    fi
    if (( advertise && ! compact )); then
        FOOT+=('')
        if _labsh_available; then
            printf -v l '%s%s: work-root JupyterLab, available but not activated — activate: monitor/jupyter-up.sh --root%s' \
                "$C_DIM" "$ADVERTISED_JUPYTER" "$C_0"
        else
            printf -v l '%s%s: work-root JupyterLab, available but not activated — needs labsh: monitor/install-labsh.sh (or brew install operator/tools/labsh)%s' \
                "$C_DIM" "$ADVERTISED_JUPYTER" "$C_0"
        fi
        FOOT+=("$l")
    fi
    FOOT+=('')
    if [[ -n "$MSG" ]]; then
        printf -v l '%s%s%s' "$C_Y" "$MSG" "$C_0"
        FOOT+=("$l")
    fi
    for f in "${FOOT[@]}"; do line_cost "$f"; FOOT_COST=$(( FOOT_COST + COST )); done
}

# Overflow path: the registry rows exceed the pane budget. Unhealthy
# (attention) rows pin first — a problem must never require paging to
# be SEEN; healthy rows fill what remains and n/p pages them. Only when
# the attention rows ALONE overflow the budget does everything page
# (attention rows first, so problems start on page 1) — and then the
# indicator goes red about the unhealthy rows that are off-page. Reads
# R_TXT/R_COST/R_ATT from render_status's scope (bash dynamic scoping);
# sets SVC_PAGE/SVC_PAGES.
render_paged_rows() {
    local budget="$1"
    (( budget < 1 )) && budget=1
    local i c idx l
    local -a pin=() pageable=()
    local att_cost=0
    for (( i=1; i<=SVC_N; i++ )); do
        (( R_ATT[i] )) && att_cost=$(( att_cost + R_COST[i] ))
    done
    if (( att_cost > 0 && att_cost >= budget )); then
        for (( i=1; i<=SVC_N; i++ )); do (( R_ATT[i] )) && pageable+=("$i"); done
        for (( i=1; i<=SVC_N; i++ )); do (( R_ATT[i] )) || pageable+=("$i"); done
    else
        for (( i=1; i<=SVC_N; i++ )); do
            if (( R_ATT[i] )); then pin+=("$i"); else pageable+=("$i"); fi
        done
        budget=$(( budget - att_cost ))
        (( budget < 1 )) && budget=1
    fi
    # Greedy page boundaries: rows cost 1+ physical lines (URL wraps),
    # so pages are cut by accumulated cost, not by row count.
    local -a starts=()
    local cur=0
    for idx in "${!pageable[@]}"; do
        c=${R_COST[${pageable[$idx]}]}
        if (( idx == 0 )) || (( cur + c > budget )); then
            starts+=("$idx"); cur=0
        fi
        cur=$(( cur + c ))
    done
    SVC_PAGES=${#starts[@]}
    (( SVC_PAGES < 1 )) && SVC_PAGES=1
    (( SVC_PAGE > SVC_PAGES )) && SVC_PAGE=$SVC_PAGES
    (( SVC_PAGE < 1 )) && SVC_PAGE=1

    for i in "${pin[@]}"; do emit "${R_TXT[$i]}"; done
    local s=0 e=${#pageable[@]} hid_att=0 hid_ok=0
    (( ${#starts[@]} )) && s=${starts[$(( SVC_PAGE - 1 ))]}
    (( SVC_PAGE < SVC_PAGES )) && e=${starts[$SVC_PAGE]}
    for idx in "${!pageable[@]}"; do
        i=${pageable[$idx]}
        if (( idx >= s && idx < e )); then
            emit "${R_TXT[$i]}"
        elif (( R_ATT[i] )); then
            hid_att=$(( hid_att + 1 ))
        else
            hid_ok=$(( hid_ok + 1 ))
        fi
    done
    if (( hid_att > 0 )); then
        printf -v l '%s! %d unhealthy + %d healthy hidden — page %d/%d (n next, p prev)%s' \
            "$C_R" "$hid_att" "$hid_ok" "$SVC_PAGE" "$SVC_PAGES" "$C_0"
        emit "$l"
    elif (( hid_ok > 0 || SVC_PAGES > 1 )); then
        printf -v l '%s+%d more UP — page %d/%d (n next, p prev)%s' \
            "$C_DIM" "$hid_ok" "$SVC_PAGE" "$SVC_PAGES" "$C_0"
        emit "$l"
    fi
}

render_status() {
    FRAME=''
    FRAME_COST=0
    SVC_LISTEN_FRESH=0   # re-snapshot listening sockets once per frame
    (( INPLACE )) && term_geometry
    local l i
    printf -v l '%snexus service cockpit%s  %s%s%s' \
        "$C_B" "$C_0" "$C_DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_0"
    emit "$l"
    printf -v l '%sregistry: %s%s' "$C_DIM" "$SERVICES_REGISTRY" "$C_0"
    emit "$l"
    emit ''

    # Live row wins: advertise only while no real registry row exists.
    local advertise_jupyter=0
    _jupyter_root_registered || advertise_jupyter=1

    # Name column width across core + registry + advertised rows.
    ROW_W=12   # fits 'orchestrator'
    (( ${#TARGET_WINDOW} > ROW_W )) && ROW_W=${#TARGET_WINDOW}
    for (( i=1; i<=SVC_N; i++ )); do
        (( ${#SVC_NAME[$i]} > ROW_W )) && ROW_W=${#SVC_NAME[$i]}
    done
    if (( advertise_jupyter )) && (( ${#ADVERTISED_JUPYTER} > ROW_W )); then
        ROW_W=${#ADVERTISED_JUPYTER}
    fi

    printf -v l '%s %-2s %-*s %-8s %-10s %s%s' \
        "$C_B" '#' "$ROW_W" 'SERVICE' 'STATUS' 'SUPERVISOR' 'DETAIL' "$C_0"
    emit "$l"

    # Truth first. A read-only filesystem invalidates every row below.
    render_fs_row
    render_core_rows

    # Registry rows pre-render into R_* (text / physical-line cost /
    # needs-attention) so the height budget can decide what to show.
    # Attention = failing healthcheck OR a dead supervisor record (`stale`
    # or `orphan`) — all mean an operator should look, so none may ever hide.
    ORPHAN_N=0
    local -a R_TXT=() R_COST=() R_ATT=()
    local name workdir launch health up upc sup supc detail gut
    for (( i=1; i<=SVC_N; i++ )); do
        name="${SVC_NAME[$i]}"; workdir="${SVC_WORKDIR[$i]}"
        launch="${SVC_LAUNCH[$i]}"; health="${SVC_HEALTH[$i]}"
        if _recover_service_healthy "$workdir" "$health"; then
            up='UP';   upc="$C_G"
        else
            up='DOWN'; upc="$C_R"
        fi
        # Health verdict feeds the supervisor cell so a dead pid record next
        # to a passing healthcheck renders as `orphan`, never a bare `stale`.
        sup="$(svc_supervisor "$name" "$launch" "$up")"
        case "$sup" in
            pid:*)  supc="$C_G" ;;
            stale)  supc="$C_R" ;;
            orphan)
                # The supervisor's liveness is part of service health, not a
                # footnote to it. A daemon that outlived its wrapper is one
                # crash away from a terminal outage: nothing will restart it.
                # Reporting that as a plain green `UP` is what let
                # nexus-remote-ssh sit unsupervised for ~19h and then die
                # (your-org/your-nexus#265). Degrade the STATUS cell itself.
                supc="$C_Y"; up='DEGRADED'; upc="$C_Y"
                ORPHAN_N=$(( ORPHAN_N + 1 ))
                ;;
            *)      supc="$C_DIM" ;;
        esac
        # A labsh JupyterLab service that is SERVING shows its reachable,
        # tokened URL; everything else falls back to the healthcheck-
        # derived endpoint. Keyed on the raw healthcheck, not the possibly
        # degraded STATUS word — a DEGRADED service is still serving, and
        # withholding its URL would help nobody.
        detail=''
        [[ "$up" == UP || "$up" == DEGRADED ]] && detail=$(svc_jupyter_url "$workdir")
        [[ -n "$detail" ]] || detail=$(svc_endpoint "$health")
        gut=' '; [[ "$SVC_FOLLOW" == "$name" ]] && gut='>'
        format_row "$gut" "$i" "$name" "$upc" "$up" "$supc" "$sup" "$detail"
        R_TXT[$i]="$ROW"
        line_cost "$ROW"; R_COST[$i]=$COST
        if [[ "$up" != UP || "$sup" == stale || "$sup" == orphan ]]; then
            R_ATT[$i]=1
        else
            R_ATT[$i]=0
        fi
    done

    # Advertised dormant capability (virtual row — see the block above
    # svc_require) renders inside the footer. Dim DOWN, not red:
    # "available but not activated" is an invitation, not a failure,
    # and must never read as an alarm.
    build_footer 0 "$advertise_jupyter"

    # Height budget (dashboard only): rows + footer + prompt must fit
    # the pane, or the frame scrolls and the TOP rows — exactly the
    # core + earliest DOWN ones — vanish silently into stale scrollback.
    local total=0 budgeted=0 budget=0
    for (( i=1; i<=SVC_N; i++ )); do total=$(( total + R_COST[i] )); done
    if (( INPLACE && TERM_ROWS > 0 )); then
        budgeted=1
        budget=$(( TERM_ROWS - PROMPT_RESERVE - FRAME_COST - FOOT_COST ))
    fi
    if (( ! budgeted || total <= budget )); then
        SVC_PAGE=1 SVC_PAGES=1
        for (( i=1; i<=SVC_N; i++ )); do emit "${R_TXT[$i]}"; done
    else
        build_footer 1 "$advertise_jupyter"   # reclaim the hint lines
        render_paged_rows \
            $(( TERM_ROWS - PROMPT_RESERVE - FRAME_COST - FOOT_COST - 1 ))
    fi

    # Never render DEGRADED/orphan without saying what it means. One line,
    # only when at least one service is in that state — the word alone would
    # read as cosmetic, which is exactly the misreading that let an
    # unsupervised daemon sit unnoticed for ~19h and then die.
    if (( ORPHAN_N > 0 )); then
        emit "$(printf '%s ! %d service(s) DEGRADED/orphan: still serving, but the supervisor is DEAD — nothing will restart them. Reconcile: monitor/svc.sh restart <name>%s' \
            "$C_Y" "$ORPHAN_N" "$C_0")"
    fi

    for l in "${FOOT[@]}"; do emit "$l"; done
    MSG=''

    if (( INPLACE )); then
        if (( NEED_CLEAR )); then clear 2>/dev/null || true; NEED_CLEAR=0; fi
        tput cup 0 0 2>/dev/null || printf '\033[H'
    fi
    printf '%s' "$FRAME"
}

# --- terminal lifecycle -----------------------------------------------------
_cockpit_sigint() { exit 130; }

_cockpit_cleanup() {
    [[ -n "${SVC_LOG_PANE:-}" ]] && tmux kill-pane -t "$SVC_LOG_PANE" 2>/dev/null
    tput rmcup 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    printf '\n'
}

init_term() {
    [[ -t 1 ]] || return 0
    INPLACE=1
    EL=$'\033[K'; ED=$'\033[J'
    # Alternate screen (smcup/rmcup — standard, honored per-pane even
    # by tmux 2.6): refreshes can never pollute the shell's scrollback,
    # even if a frame ever misjudges the pane height. Failure is
    # harmless — the height budget plus the EL/ED repaint discipline
    # keeps the primary screen clean on terminals without it.
    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true
    clear 2>/dev/null || true
    trap '_cockpit_cleanup' EXIT
    trap '_cockpit_sigint' INT TERM
    trap 'NEED_CLEAR=1' WINCH
}

# --- follow a log -----------------------------------------------------------
# Inside tmux: open (or reuse) ONE dedicated split pane that `tail -F`s
# the chosen log; the cockpit pane KEEPS focus and keeps refreshing.
# Successive picks swap the log in the same split instead of stacking
# panes; `x` closes it. Outside tmux: inline tail (Ctrl-C returns).
# tail -F (capital) survives log rotation / re-creation either way.
SVC_LOG_PANE=''

# follow_log <name> <logfile> [workdir] — workdir (when given) pulls
# the jupyter server log into the same tail via svc_log_files; the
# watcher core row pulls the live scheduler jsonl via watcher_log_files.
follow_log() {
    local name="$1" lf="$2" workdir="${3:-}"
    local -a files=()
    if [[ "$name" == watcher ]]; then
        mapfile -t files < <(watcher_log_files)
    elif [[ -f "$lf" ]]; then
        files=("$lf")
        [[ -n "$workdir" ]] && mapfile -t files < <(svc_log_files "$workdir" "$lf")
    fi
    if (( ${#files[@]} == 0 )); then
        MSG="logfile not found: $lf"
        return
    fi
    if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
        _follow_split "$name" "${files[@]}"
    else
        _follow_inline "$name" "${files[@]}"
    fi
    SVC_FOLLOW="$name"
}

# tmux path: a dedicated, reused split pane. `-d` keeps focus on the
# cockpit. Titling via select-pane would STEAL focus (select-pane -T
# also activates the target), so the restore to the previously active
# pane is part of the title helper.
_set_pane_title() {
    local pane="$1" title="$2" cur
    cur=$(tmux display-message -p '#{pane_id}' 2>/dev/null)
    tmux select-pane -t "$pane" -T "$title" 2>/dev/null
    [[ -n "$cur" ]] && tmux select-pane -t "$cur" 2>/dev/null
}

_follow_split() {
    local name="$1"; shift
    local cmd='exec tail -n 200 -F' f
    for f in "$@"; do printf -v cmd '%s %q' "$cmd" "$f"; done
    if [[ -n "$SVC_LOG_PANE" ]] \
       && tmux list-panes -F '#{pane_id}' 2>/dev/null | grep -qxF "$SVC_LOG_PANE"; then
        tmux respawn-pane -k -t "$SVC_LOG_PANE" "$cmd" 2>/dev/null
    else
        SVC_LOG_PANE=$(tmux split-window -d -v -p 40 -P -F '#{pane_id}' "$cmd" 2>/dev/null)
        NEED_CLEAR=1   # our pane shrank; repaint clean
    fi
    [[ -n "$SVC_LOG_PANE" ]] && _set_pane_title "$SVC_LOG_PANE" "log:$name"
}

# non-tmux fallback: inline tail in place. INT kills the tail and
# returns to the cockpit; the cockpit's own INT handler is restored
# afterwards (a bare `trap - INT` would clobber it).
_follow_inline() {
    local name="$1" tpid; shift
    clear 2>/dev/null || printf '\n'
    printf '%sfollowing %s%s — %s\n' "$C_B" "$name" "$C_0" "$*"
    printf '%spress Ctrl-C to return to the cockpit%s\n\n' "$C_DIM" "$C_0"
    tail -n 200 -F "$@" &
    tpid=$!
    trap 'kill "$tpid" 2>/dev/null' INT
    wait "$tpid" 2>/dev/null
    trap '_cockpit_sigint' INT
    SVC_FOLLOW=''
    NEED_CLEAR=1
}

_close_log_pane() {
    [[ -n "$SVC_LOG_PANE" ]] && tmux kill-pane -t "$SVC_LOG_PANE" 2>/dev/null
    SVC_LOG_PANE=''
    SVC_FOLLOW=''
    NEED_CLEAR=1
}

# --- wrong-launch guard (issue #203 follow-up, 2026-06-11 incident) ---------
# The cockpit must refuse to run wrong (operator direction): a cockpit
# occupying the window named monitor.target_window masks the
# orchestrator's absence from the watcher's name-based probe, so no
# recovery ever fires; a second cockpit is pure clutter that has been
# mistaken for a takeover. Two checks, both CONSERVATIVE (indeterminate
# probes fail open — a legitimate first cockpit is never refused; the
# helpers live in watcher/_lib.sh):
#
#   1. Own window named "$TARGET_WINDOW" (only trusted when the pane
#      actually HOSTS this process — $TMUX_PANE is inherited through
#      env, see _nexus_self_pane_window): rename the window OFF the
#      target name FIRST (so the running watcher sees the orchestrator
#      absent and respawns it) unless a live orchestrator process
#      shares the window (then the name is its, not ours to move) —
#      then exit 4 with the fix.
#   2. A live peer cockpit pane exists anywhere in the tmux server
#      (pane scan, not a pidfile, so pre-guard cockpits count): exit 4
#      pointing at it.
_cockpit_wrong_launch_guard() {
    local self_info win_id win_name
    if self_info=$(_nexus_self_pane_window); then
        win_id="${self_info%%$'\t'*}"
        win_name="${self_info#*$'\t'}"
        if [[ "$win_name" == "$TARGET_WINDOW" ]]; then
            if ! _nexus_window_has_orchestrator "$win_id"; then
                tmux rename-window -t "$win_id" "${SERVICES_WINDOW}-misplaced" 2>/dev/null || true
                tmux set-window-option -t "$win_id" automatic-rename off 2>/dev/null || true
            fi
            cat >&2 <<MSG
svc.sh: REFUSING to run the cockpit inside the '$TARGET_WINDOW' window —
that window belongs to the orchestrator; a cockpit squatting there hides
the orchestrator's absence from the watcher and blocks recovery.
The window has been renamed off '$TARGET_WINDOW' (unless a live
orchestrator shares it) so the watcher can respawn the real orchestrator.
Run the cockpit in its own window instead:
  tmux new-window -dn $SERVICES_WINDOW $0
MSG
            exit 4
        fi
    fi
    local peer p_pid p_win p_name
    if peer=$(_nexus_find_live_cockpit_pane "${TMUX_PANE:-}"); then
        IFS=$'\t' read -r p_pid p_win p_name <<<"$peer"
        cat >&2 <<MSG
svc.sh: a service cockpit is already running (pid=$p_pid in tmux window
'$p_name' $p_win) — refusing to start a second one. Attach to that
window instead, or use 'svc.sh status' for a one-shot table.
MSG
        exit 4
    fi
    return 0
}

# --- dashboard loop ---------------------------------------------------------
cockpit() {
    _cockpit_wrong_launch_guard
    init_term
    local choice rc d2 prompt
    while true; do
        load_services
        render_status
        prompt="${C_B}[0-$SVC_N]${C_0} log"
        [[ -n "${TMUX:-}" ]] && prompt+=" -> split"
        (( SVC_PAGES > 1 )) && prompt+="   ${C_B}n/p${C_0} page $SVC_PAGE/$SVC_PAGES"
        [[ -n "$SVC_FOLLOW" ]] && prompt+="   ${C_B}x${C_0} close log:$SVC_FOLLOW"
        prompt+="   ${C_B}r${C_0} refresh   ${C_B}q${C_0} quit > "
        printf '%s%s' "$prompt" "$ED"

        # Single-key dispatch; the timeout doubles as the refresh tick.
        choice=''
        read -rt "$REFRESH" -n1 choice; rc=$?
        if (( rc > 128 )); then continue; fi          # timeout / WINCH -> refresh
        if (( rc > 0 )); then                          # EOF
            [[ -t 0 ]] && continue
            printf '\n'; return 0                      # piped: render once, leave
        fi
        case "$choice" in
            q|Q)   return 0 ;;
            r|R|'') continue ;;
            x|X)   _close_log_pane ;;
            # Page through the healthy rows (cyclic). Problems never
            # need paging: unhealthy + core rows render on every page.
            n|N)   (( SVC_PAGES > 1 )) && SVC_PAGE=$(( SVC_PAGE % SVC_PAGES + 1 )) ;;
            p|P)   (( SVC_PAGES > 1 )) && SVC_PAGE=$(( (SVC_PAGE + SVC_PAGES - 2) % SVC_PAGES + 1 )) ;;
            0)     follow_log watcher "$WATCHER_LOG" ;;
            [1-9])
                if (( SVC_N > 9 )); then
                    # Allow a second digit for two-digit registries.
                    d2=''
                    read -rt 1 -n1 d2 2>/dev/null
                    [[ "$d2" == [0-9] ]] && choice="$choice$d2"
                fi
                if (( choice >= 1 && choice <= SVC_N )); then
                    follow_log "${SVC_NAME[$choice]}" "${SVC_LOG[$choice]}" \
                        "${SVC_WORKDIR[$choice]}"
                else
                    MSG="no service #$choice"
                fi
                ;;
            *)     ;;   # ignore anything else
        esac
    done
}

# --- verbs -------------------------------------------------------------------
die() { echo "svc.sh: $*" >&2; exit 1; }

_orchestrator_redirect() {
    die "the orchestrator is watcher-managed — run 'svc.sh up' (or 'svc.sh start watcher') and the watcher spawns/revives it"
}

# Exits NON-ZERO when the project filesystem is read-only. A status command
# that returns success while nothing can be written is the same class of lie
# as a health probe that reports healthy during an outage: scripts gate on
# the exit code, and today they all sailed straight through the outage.
cmd_status() {
    load_services
    render_status
    (( SVC_FS_OK )) || return 1
    # Non-zero on duplicate / decapitated watcher groups (nexus-code#491)
    # so scripts and supervisors can KEY on the anomaly instead of
    # parsing the table. 6 is distinct from every launcher/revive code.
    if (( WATCHER_DUP_N > 0 )); then
        echo "svc.sh: WATCHER SINGLETON VIOLATION — see the watcher-dup/watcher-orphan row(s) above (exit 6)" >&2
        return 6
    fi
    return 0
}

cmd_up() {
    echo "[svc] whole-stack bring-up (idempotent) — delegating to bootstrap-recover.sh" >&2
    "$_script_dir/bootstrap-recover.sh" "$@" \
        || die "bootstrap-recover.sh failed (rc=$?)"
    if ! _recover_window_exists "$TARGET_WINDOW"; then
        echo "[svc] orchestrator window '$TARGET_WINDOW' still absent after recovery — the direct orchestrator-first spawn did not take (see [recover] log lines above); the watcher's absent-target machinery is the backstop" >&2
    fi
    echo >&2
    cmd_status
}

cmd_start() {
    local name="$1"
    case "$name" in
        # Start the watcher idempotently (--ensure). Clear any intentional-
        # stop sentinel so the orchestrator's supervisor Monitor may revive
        # it again. The Monitor itself is orchestrator-owned (it arms it per
        # skills/nexus.service-recovery); svc.sh does not spawn a daemon.
        watcher)
            rm -f "$WATCHER_STOP_SENTINEL" 2>/dev/null || true
            exec "$_script_dir/watcher/launcher.sh" --ensure --target "$TARGET_WINDOW" ;;
        orchestrator|"$TARGET_WINDOW") _orchestrator_redirect ;;
    esac
    svc_require "$name"
    local outcome
    outcome=$(recover_service "${SVC_NAME[$REG_I]}" "${SVC_WORKDIR[$REG_I]}" \
        "${SVC_LAUNCH[$REG_I]}" "${SVC_HEALTH[$REG_I]}" "${SVC_LOG[$REG_I]}")
    echo "[svc] $name: $outcome" >&2
    case "$outcome" in
        healthy|relaunched|supervisor-alive|window-present) return 0 ;;
        *) return 1 ;;
    esac
}

# TERM the supervisor's process group (setsid made it a session+group
# leader, so the wrapper and its children go together), escalate to
# KILL after 5 s, then drop the pidfile. A passing healthcheck after
# that is loudly flagged — a daemonizing child (e.g. nginx) can escape
# the group and needs its own shutdown.
_stop_service() {
    local name="$1" workdir="$2" launch="$3" health="$4"
    local pf pid i
    pf=$(_recover_pidfile "$name")
    if ! _recover_service_running "$name" "$launch"; then
        echo "[svc] $name: no live supervisor — nothing to stop" >&2
        # Removing the record does NOT stop an orphaned daemon: the supervisor
        # is what we track, and it is already gone. Say so loudly, or `stop`
        # reads as "service stopped" while the daemon keeps serving,
        # unsupervised and now unrecorded.
        if [[ -f "$pf" ]]; then
            rm -f "$pf"
            echo "[svc] $name: removed stale pidfile" >&2
            if _recover_service_healthy "$workdir" "$health"; then
                echo "[svc] $name: WARNING — the healthcheck STILL PASSES: an orphaned daemon is serving without a supervisor, and its pid record is now gone." >&2
                echo "[svc] $name:           'stop' removed the record, not the daemon. Use 'svc.sh restart $name' to reconcile (it will bounce the daemon)." >&2
            fi
        fi
        return 0
    fi
    read -r pid < "$pf" 2>/dev/null
    echo "[svc] $name: stopping supervisor pid $pid (TERM to its process group)" >&2
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "[svc] $name: still alive after 5s — KILL" >&2
        kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
        sleep 0.2
    fi
    rm -f "$pf"
    if _recover_service_healthy "$workdir" "$health"; then
        echo "[svc] $name: WARNING — healthcheck still passes after stop; a daemonized child likely escaped the process group" >&2
        return 1
    fi
    echo "[svc] $name: stopped" >&2
}

# --- watcher control (mutual-liveness) ------------------------------------
# The supervisor is the ORCHESTRATOR's armed Monitor, not a daemon svc.sh
# spawns; svc.sh only stops/starts/restarts the watcher process and manages
# the intentional-stop sentinel the orchestrator's revive path honours.

_stop_watcher() {
    local pid i
    # Mark an INTENTIONAL stop so a still-armed orchestrator Monitor does
    # not immediately revive the watcher we're deliberately stopping
    # (revive-watcher.sh refuses while this sentinel exists). Cleared by
    # `start`/`restart watcher`. The orchestrator should also disarm its
    # Monitor for a lasting stop (it owns the Monitor); this is the
    # belt-and-suspenders so an intentional stop is never fought.
    : > "$WATCHER_STOP_SENTINEL" 2>/dev/null || true
    echo "[svc] watcher: wrote intentional-stop sentinel ($WATCHER_STOP_SENTINEL); disarm the orchestrator Monitor for a lasting stop" >&2
    [[ -f "$WATCHER_PIDFILE" ]] || { echo "[svc] watcher: no pidfile ($WATCHER_PIDFILE) — nothing to stop" >&2; return 0; }
    pid=$(cat "$WATCHER_PIDFILE" 2>/dev/null)
    if ! _watcher_pid_is_live_watcher "$pid"; then
        echo "[svc] watcher: pidfile is stale (pid=$pid is not a live watcher) — removing" >&2
        rm -f "$WATCHER_PIDFILE"
        return 0
    fi
    # Group kill (the watcher is a setsid session leader, pid==pgid) so no
    # child/orphan survives — and the death test is GROUP emptiness, not
    # leader exit (nexus-code#491): a leader-only wait "succeeds" while
    # the orphaned subshell chain keeps running the loop (decapitation).
    echo "[svc] watcher: stopping process group $pid (TERM, KILL after 5s, verify group empty)" >&2
    # Root passed so the reap re-verifies argv identity at kill time
    # (skeptic finding 1 on PR#503: the pid is not the identity). The
    # pid was _watcher_pid_is_live_watcher-verified just above, so an
    # rc-2 refusal here means the scan and the pid check disagree —
    # fall back to a leader-verified direct group kill rather than
    # leaving a confirmed watcher running after 'stop'.
    local _reap_rc=0
    _watcher_reap_group "$pid" 5 "$NEXUS_ROOT" || _reap_rc=$?
    if (( _reap_rc == 2 )); then
        echo "[svc] watcher: group scan could not re-verify $pid (pid check says live watcher) — direct leader-group kill" >&2
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        for i in 1 2 3 4 5 6 7 8 9 10; do
            _watcher_group_alive "$pid" || break
            sleep 0.5
        done
        if _watcher_group_alive "$pid"; then
            kill -KILL -- "-$pid" 2>/dev/null || true
            sleep 0.5
        fi
        if _watcher_group_alive "$pid"; then _reap_rc=1; else _reap_rc=0; fi
    fi
    if (( _reap_rc == 1 )); then
        echo "[svc] watcher: WARNING — group $pid still has members after SIGKILL; inspect: ps -eo pid,ppid,pgid,args | awk -v g=$pid '\$3==g'" >&2
        rm -f "$WATCHER_PIDFILE"
        return 1
    fi
    rm -f "$WATCHER_PIDFILE"
    echo "[svc] watcher: stopped (group empty; NOTE: GitHub integration + orchestrator revival are down until 'svc.sh start watcher')" >&2
}

# THE idempotent watcher restart (operator-facing + the revive command
# revive-watcher.sh calls): single-flighted + full-process-group reap in
# launcher.sh --replace, then verify exactly one live watcher, FAIL LOUD
# on zero. An intentional restart, so it CLEARS the stop sentinel. Safe to
# run repeatedly and when the watcher is already down.
_restart_watcher() {
    rm -f "$WATCHER_STOP_SENTINEL" 2>/dev/null || true
    echo "[svc] watcher: idempotent restart — reap old tree, spawn one, verify (single-flighted)" >&2
    "$_script_dir/watcher/launcher.sh" --replace --target "$TARGET_WINDOW" >&2
    local rc=$?
    # Confirm the spawn took. main.sh now publishes an EARLY heartbeat
    # alongside the early pidfile, so `_watcher_alive` reads the fresh
    # live pid immediately (skeptic #001 fix). Belt-and-suspenders: also
    # accept a live `watcher.pid` — the SAME signal the launcher waited
    # for — so a transient heartbeat-write hiccup can't turn a SUCCESSFUL
    # spawn into a false "restart FAILED" (the deadly input to the revive
    # crash-loop). The instance flock guarantees ≤1 live watcher.
    _watcher_alive "$STATE_DIR" "$INTERVAL"
    local alive_rc=$?
    local pid; pid=$(cat "$WATCHER_PIDFILE" 2>/dev/null)
    if (( alive_rc == 0 || alive_rc == 4 )) || _watcher_pid_is_live_watcher "$pid"; then
        # The singleton claim is CHECKED, not asserted (nexus-code#491):
        # count live watcher process GROUPS for this root. Exactly one
        # is the contract; anything else fails loud with the pgids so
        # the operator can reconcile by recorded pid — never pkill -f.
        local _wg _wleader _wn _groups=()
        while IFS=$'\t' read -r _wg _wleader _wn; do
            [[ "$_wg" =~ ^[0-9]+$ ]] && _groups+=("$_wg($_wleader)")
        done < <(_watcher_list_live_groups "$NEXUS_ROOT")
        if (( ${#_groups[@]} == 1 )) || (( ${#_groups[@]} == 0 )); then
            # 0 groups can only mean /proc scanning is unavailable —
            # the pid/liveness checks above already passed.
            echo "[svc] watcher: restart OK — exactly one live watcher group (pid=${pid:-?})" >&2
            return 0
        fi
        echo "[svc] watcher: restart FAILED SINGLETON CHECK — ${#_groups[@]} watcher groups live after restart: ${_groups[*]}" >&2
        echo "[svc] watcher:   reconcile: rerun 'svc.sh restart watcher' (reaps every group by pgid), or kill the stray group by recorded pgid" >&2
        return 6
    fi
    echo "[svc] watcher: restart FAILED — no live watcher after launcher (rc=$rc, liveness bucket=$alive_rc); check $WATCHER_LOG" >&2
    return 1
}

cmd_stop() {
    local name="$1"
    case "$name" in
        watcher) _stop_watcher; return ;;
        orchestrator|"$TARGET_WINDOW") _orchestrator_redirect ;;
    esac
    svc_require "$name"
    _stop_service "${SVC_NAME[$REG_I]}" "${SVC_WORKDIR[$REG_I]}" \
        "${SVC_LAUNCH[$REG_I]}" "${SVC_HEALTH[$REG_I]}"
}

# Evidence that SOMEONE deliberately restarted this service, and who. The
# service-health watch reads this to ATTRIBUTE a recovery instead of inferring
# one: "healthcheck went green and the watcher didn't restart it" does NOT
# imply a self-heal — an orchestrator or operator running `svc.sh restart`
# satisfies the same predicate, and calling that a "transient blip, no action
# needed" buries a real outage someone had to fix (your-org/your-nexus#265).
#
# Actor: the watcher stamps SVC_RESTART_ACTOR=watcher when it calls us; any
# other caller is an operator/orchestrator intervention. Best-effort — a
# failure to record must never block the restart itself.
_record_restart_marker() {
    local name="$1" dir="$STATE_DIR/service-health"
    mkdir -p "$dir" 2>/dev/null || return 0
    { printf 'actor=%s\n' "${SVC_RESTART_ACTOR:-operator}"
      printf 'at=%s\n'    "$(date +%s 2>/dev/null || echo 0)"
      printf 'iso=%s\n'   "$(date -Is 2>/dev/null || date)"
    } > "$dir/$name.restart" 2>/dev/null || true
    return 0
}

cmd_restart() {
    local name="$1"
    case "$name" in
        # THE canonical, idempotent watcher restart — see _restart_watcher.
        watcher) _restart_watcher; return ;;
        orchestrator|"$TARGET_WINDOW") _orchestrator_redirect ;;
    esac
    _record_restart_marker "$name"
    cmd_stop "$name" || true
    cmd_start "$name"
}

cmd_logs() {
    local name="$1" lf
    local -a files
    case "$name" in
        watcher)
            # Startup log + live scheduler jsonl — whichever exist.
            mapfile -t files < <(watcher_log_files)
            (( ${#files[@]} )) \
                || die "logfile not found: $WATCHER_LOG (no $SCHEDULER_LOG either)"
            ;;
        orchestrator|"$TARGET_WINDOW")
            die "the orchestrator is an interactive window, not a logged service — 'tmux select-window -t $TARGET_WINDOW'"
            ;;
        *)
            svc_require "$name"
            lf="${SVC_LOG[$REG_I]}"
            [[ -f "$lf" ]] || die "logfile not found: $lf"
            mapfile -t files < <(svc_log_files "${SVC_WORKDIR[$REG_I]}" "$lf")
            ;;
    esac
    exec tail -n 200 -F "${files[@]}"
}

# --- entrypoint ---------------------------------------------------------------
usage() { awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; }

main() {
    # An EXPLICIT empty first argument (`svc.sh ""`) is a caller bug —
    # an unset/empty variable expanding into the verb slot — and used
    # to silently dispatch to the interactive cockpit (the '' case
    # below matches no-arg AND empty-arg alike). Fail loud instead;
    # only a genuinely argument-less invocation gets the dashboard.
    if (( $# > 0 )) && [[ -z "$1" ]]; then
        die "empty argument (an unset variable expanding to \"\"?) — refusing to guess; run with no arguments for the dashboard or pass an explicit verb"
    fi
    case "${1:-}" in
        -h|--help)        usage ;;
        status|--status|-1) cmd_status ;;
        up)               shift; cmd_up "$@" ;;
        start|stop|restart|logs)
            local verb="$1" name="${2:-}"
            [[ -n "$name" ]] || die "usage: svc.sh $verb <name>"
            "cmd_$verb" "$name"
            ;;
        '')               cockpit ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
}

# Run main only when executed directly; sourcing (e.g. from a test) gets
# the functions without starting the cockpit. Mirrors bootstrap-recover.sh.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
