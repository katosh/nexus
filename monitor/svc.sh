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
#   svc.sh --force <verb> <name>
#                            override the cold-build guard. stop/restart of a
#                            labsh service REFUSE while a uvx cold build is in
#                            flight (~19 min on NFS, nothing listening the whole
#                            time): restarting discards the build and starts the
#                            clock over, which is what makes a slow bring-up
#                            look like a crash loop. Also via SVC_FORCE=1.
#   svc.sh orphans           READ-ONLY: list supervisor processes with ppid 1
#                            whose source path no registry row names, or which
#                            run from outside $NEXUS_ROOT (a retired clone, an
#                            ephemeral scratch dir). Signals nothing. Exit 0 =
#                            none found AND both positive controls held; 1 =
#                            found; 3 = REFUSED, could not determine.
#   svc.sh retire-orphan <pid> [--yes]
#                            the SANCTIONED retirement path for exactly the
#                            set `orphans` prints (your-org/nexus-code#1034
#                            rec. 2). Re-runs the scan and REFUSES (rc 2) any
#                            pid it does not classify as an orphan — a
#                            registered supervisor is never touched, and a
#                            scan whose controls did not hold retires nothing.
#                            Without --yes it prints the plan (the supervisor
#                            + its descendants, by recorded PPid, and the
#                            signals) and exits 4. With --yes: TERM the
#                            process group, escalate to KILL after the grace,
#                            append a row to monitor/.state/svc-retire.log.
#                            0 = retired; 1 = signalled but still present.
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

# Override the cold-build guard (_coldbuild_guard). Set by `--force`, or by a
# non-interactive caller exporting SVC_FORCE=1.
SVC_FORCE="${SVC_FORCE:-0}"

# Reuse the recovery path's primitives so health/launch/liveness
# semantics match exactly. bootstrap-recover.sh guards its main behind
# a BASH_SOURCE test, so sourcing yields the functions (and, via its
# own source of watcher/_lib.sh, the watcher liveness probes) plus the
# STATE_DIR / INTERVAL / _cfg globals — with no side effects.
# shellcheck source=bootstrap-recover.sh
source "$_script_dir/bootstrap-recover.sh"

# Build-identity predicates (labsh_build_in_progress). The cold-build guard in
# cmd_stop needs to know whether a uvx materialisation is in flight before it
# TERMs anything. Sourced, not reimplemented, so svc.sh and the watcher share
# ONE definition of "a build is running" — see _labsh_build_evidence.sh.
# shellcheck source=_labsh_build_evidence.sh
source "$_script_dir/_labsh_build_evidence.sh" 2>/dev/null || true

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
# Registry readability — the REPLICATED half of the contract documented in
# bootstrap-recover.sh ("registry READABILITY: three states, not two",
# your-org/nexus-code#1266). svc.sh is a THIRD parser, absent from that
# issue's consumer table; it feeds the cockpit, so an unreadable registry
# rendered an EMPTY service list that reads exactly like "you have no
# services". Replicated rather than sourced (the cockpit does not source
# bootstrap-recover.sh); the CONTRACT is identical. Keep in step.
#   0  readable, or genuinely ABSENT (both are adjudications)
#  79  exists and could not be read — no statement about contents available
svc_registry_readable() {
    local file="$1"
    [[ -e "$file" ]] || return 0
    [[ -f "$file" ]] || return 79
    # `2>/dev/null` FIRST — redirections apply left to right.
    { : ; } 2>/dev/null < "$file" || return 79
    return 0
}

svc_parse_registry() {
    local file="$1"
    if ! svc_registry_readable "$file"; then
        echo "[svc] registry: NOT READABLE at $file — refusing to report its contents (rc 79)" >&2
        return 79
    fi
    [[ -e "$file" ]] || return 0
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
    # Two separate opens (probe, then this); a fault between them is a SHORT
    # read, which is worse than a zero because it is plausible.
    done < "$file" || return 79
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

# A service's OWN declaration of the endpoint it serves, read from its tree:
# `<workdir>/.deploy/endpoint`, first line, one URL.
#
# WHY A FILE AND NOT A REGISTRY COLUMN (your-org/nexus-code#1144). The DETAIL
# cell used to be derived ENTIRELY from the healthcheck COMMAND TEXT, so it was
# a property of HOW A HEALTHCHECK IS SPELLED rather than of the service. That
# inverts the incentive, because the better probe is the one that loses: an
# inline `curl -fsS … http://localhost:8773/` renders a copy-pasteable URL,
# while a SCRIPT healthcheck — which is what you must write when the endpoint is
# auth-gated, or when one probe has to assert several properties — renders `-`,
# indistinguishable from a service that genuinely has no endpoint.
#
# The precedent is `svc_jupyter_url`, which already reads PORT/SCHEME from the
# service's own `.jupyter/labsh-service.env` rather than from anything the
# registry says. This generalises it: the endpoint is the SERVICE's fact, so ask
# the service. A registry column would have worked too, but it needs an operator
# edit per service, it is the 7th positional field behind two optional ones, and
# three other tools parse that file.
#
# VALIDATE THE SHAPE, NEVER MERELY NON-EMPTINESS. The bytes come from a file
# outside this repo and land in a terminal render, so a URL that is not
# URL-shaped is REFUSED rather than printed: an emptiness check would pass a
# line of ANSI escapes. Returns 1 when there is nothing valid to show, so the
# caller falls through to its next source. Never errors.
svc_declared_endpoint() {
    local workdir="${1:-}" line
    # A URL contains no whitespace, so stripping all of it also eats a stray
    # CR from a CRLF file — which would otherwise fail the shape check for a
    # reason nobody could see.
    local re='^https?://[A-Za-z0-9._~:/?#@%+=,&-]+$'
    [[ -n "$workdir" ]] || return 1
    line=$(head -1 "$workdir/.deploy/endpoint" 2>/dev/null) || return 1
    line="${line//[[:space:]]/}"
    [[ "$line" =~ $re ]] || return 1
    svc_display_url "$line"
}

# Best-effort human endpoint for a service: the URL named in a curl-style
# healthcheck, else the service's own `.deploy/endpoint` declaration, else
# pid:N for pgrep checks, else "-". All of them rewritten to the real host when
# externally bound. Purely cosmetic — nothing here changes what is PROBED, and
# healthcheck commands are still never rewritten (see the rule above).
#
# ORDER. The healthcheck's URL is consulted FIRST, so every rendering that was
# correct before this change is byte-identical after it — the declaration is
# additive and cannot silently redirect a cell that already worked. The cost of
# that choice, stated because it is a real limit: a service whose healthcheck
# names a URL that is NOT its front door cannot override the cell from its tree.
svc_endpoint() {
    local health="$1" workdir="${2:-}" url pat pid
    url=$(grep -oE 'https?://[^ ]+' <<<"$health" | head -1)
    if [[ -n "$url" ]]; then svc_display_url "$url"; return; fi
    if url=$(svc_declared_endpoint "$workdir"); then printf '%s' "$url"; return; fi
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
# 1 when the registry EXISTS and could not be READ, so SVC_N==0 is "could not
# look" rather than "nothing registered" (your-org/nexus-code#1266). The two
# render differently everywhere SVC_N==0 is reported; a flag nobody reads
# would be the same silence in a new place.
SVC_REGISTRY_UNREADABLE=0

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
    # `while … done < <(cmd)` DISCARDS cmd's rc, so the parser's 79 is
    # unobservable at the loop; re-ask the predicate here. An unreadable
    # registry must not render as an empty cockpit — "you have no services"
    # and "I could not read your services" are different sentences
    # (your-org/nexus-code#1266).
    if ! svc_registry_readable "$SERVICES_REGISTRY"; then
        SVC_REGISTRY_UNREADABLE=1
    else
        SVC_REGISTRY_UNREADABLE=0
    fi
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
    elif (( SVC_REGISTRY_UNREADABLE )); then
        echo "  registry at $SERVICES_REGISTRY is NOT READABLE — the name may well be registered;" >&2
        echo "  this listing could not be produced. ('watcher' is still addressable.)" >&2
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
        if (( SVC_REGISTRY_UNREADABLE )); then
            printf -v l '%sREGISTRY NOT READABLE%s at %s — this is NOT "no services"; the list below is EMPTY because it could not be read' \
                "$C_R" "$C_0" "$SERVICES_REGISTRY"
        else
            printf -v l '%sno registered services%s (expected at %s)' \
                "$C_R" "$C_0" "$SERVICES_REGISTRY"
        fi
        FOOT+=("$l")
    fi
    if (( advertise && ! compact )); then
        FOOT+=('')
        if _labsh_available; then
            printf -v l '%s%s: work-root JupyterLab, available but not activated — activate: monitor/jupyter-up.sh --root%s' \
                "$C_DIM" "$ADVERTISED_JUPYTER" "$C_0"
        else
            printf -v l '%s%s: work-root JupyterLab, available but not activated — needs labsh: monitor/install-labsh.sh (or brew install katosh/tools/labsh)%s' \
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
        [[ -n "$detail" ]] || detail=$(svc_endpoint "$health" "$workdir")
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
       && grep -qxF "$SVC_LOG_PANE" <<<"$(tmux list-panes -F '#{pane_id}' 2>/dev/null)"; then
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
        # Delimiter is '|', never a TAB: a non-UTF-8 locale rewrites a TAB in
        # tmux `-F`/`display-message -p` output to `_`, which used to collapse
        # both fields into one mangled string and make this guard fail OPEN
        # (your-org/nexus-code#701 item A).
        win_id="${self_info%%|*}"
        win_name="${self_info#*|}"
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
        # A green healthcheck over a dead supervisor record is NOT a
        # successful start (your-org/nexus-code#606): `start` did nothing, and
        # the thing that is serving answers to nobody. Fail loudly and name
        # the one verb that actually reconciles.
        healthy-unsupervised)
            echo "[svc] $name:   the healthcheck passes but the daemon is UNSUPERVISED — 'start' cannot adopt a running daemon." >&2
            echo "[svc] $name:   Reconcile: monitor/svc.sh restart $name" >&2
            return 1 ;;
        *) return 1 ;;
    esac
}

# Locate the daemon behind an ORPHANED service — one whose healthcheck
# passes while its supervisor record is stale. Prints the ONE verified pid,
# or returns non-zero when the owner cannot be identified UNAMBIGUOUSLY.
#
# IDENTIFY-BY-BASENAME ALONE IS A FOOTGUN, and it drew blood while this fix
# was being written: matching the wrapper BASENAME (`serve-supervised.sh`)
# hit four unrelated production rows that share that wrapper, and the caller
# TERMed all of them. The basename cannot be dropped either — registry launch
# fields are commonly RELATIVE (`./serve-supervised.sh`) while the running
# cmdline is absolute, so the token as written matches nothing. What makes a
# basename match safe is the SECOND half of the predicate:
#   (a) /proc/<pid>/cmdline mentions the wrapper basename, AND
#   (b) /proc/<pid>/cwd IS the service's workdir — recovery launches every
#       supervisor with `cd <workdir>`, and it is the workdir, not the
#       script, that distinguishes two rows sharing one wrapper.
# `pgrep` only PROPOSES; every candidate is re-verified from /proc before it
# is named to a caller that will signal it. We never `pkill -f` — pattern
# killing matches the watcher's own command line and has taken it down.
#
# AMBIGUITY IS FATAL, NEVER RESOLVED BY GUESSING: a service has exactly one
# supervisor, so two or more survivors mean the predicate did not identify
# it. Refuse. Killing "all the matches" is precisely the blast radius this
# whole change exists to prevent.
# Results are returned in GLOBALS, not on stdout: a caller capturing stdout
# with $(…) would run this in a subshell, and the ambiguity verdict set there
# would be discarded — the guard would then be unreachable, silently.
#   _SVC_LOCATE_PID        the single identified pid (return 0)
#   _SVC_LOCATE_AMBIGUOUS  space-separated candidates when >1 matched
# Returns 0 iff exactly one candidate was positively identified.
_SVC_LOCATE_PID=''
_SVC_LOCATE_AMBIGUOUS=''
_svc_locate_orphan_daemon() {
    local launch="$1" workdir="$2" tok base pid cl cwd uid wd_real
    local -a hits=()
    _SVC_LOCATE_PID=''; _SVC_LOCATE_AMBIGUOUS=''
    tok=${launch%% *}
    base=${tok##*/}
    [[ -n "$base" ]] || return 1
    command -v pgrep >/dev/null 2>&1 || return 1
    uid=$(id -u 2>/dev/null) || return 1
    wd_real=$(readlink -f "$workdir" 2>/dev/null)
    [[ -n "$wd_real" ]] || return 1
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        (( pid == $$ || pid == PPID )) && continue
        [[ -r "/proc/$pid/cmdline" ]] || continue
        # `{ …; } 2>/dev/null` — redirection ORDER (your-org/nexus-code#1305).
        cl=$( { tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null ) || continue
        [[ "$cl" == *"$base"* ]] || continue
        cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null) || continue
        [[ "$cwd" == "$wd_real" ]] || continue
        hits+=( "$pid" )
    done < <(pgrep -u "$uid" -f -- "$base" 2>/dev/null)
    if (( ${#hits[@]} == 1 )); then _SVC_LOCATE_PID="${hits[0]}"; return 0; fi
    (( ${#hits[@]} > 1 )) && _SVC_LOCATE_AMBIGUOUS="${hits[*]}"
    return 1
}

# Genuinely reconcile an orphaned service: locate the daemon, stop it,
# restart it under a supervisor, leave a valid record. Where it CANNOT, it
# fails loudly with the reason rather than reporting health — a passing
# healthcheck is never sufficient evidence that a reconcile worked
# (your-org/nexus-code#606).
_svc_reconcile_orphan() {
    local name="$1" workdir="$2" launch="$3" health="$4" logfile="$5"
    local st="$6" why="$7"
    local pf pid i
    pf=$(_recover_pidfile "$name")
    echo "[svc] $name: ORPHANED DAEMON — healthcheck passes, supervisor record is $st${why:+ ($why)}. Reconciling." >&2

    # No command substitution: the verdict comes back in globals (see the
    # function's header) precisely so the ambiguity branch stays reachable.
    if _svc_locate_orphan_daemon "$launch" "$workdir"; then
        pid="$_SVC_LOCATE_PID"
    else
        if [[ -n "$_SVC_LOCATE_AMBIGUOUS" ]]; then
            echo "[svc] $name: CANNOT RECONCILE — discovery is AMBIGUOUS: pids $_SVC_LOCATE_AMBIGUOUS all match" >&2
            echo "[svc] $name:   '${launch%% *}' in $workdir. A service has ONE supervisor, so this predicate has" >&2
            echo "[svc] $name:   not identified it — and killing every match is how a targeted bounce becomes an" >&2
            echo "[svc] $name:   outage. Nothing was signalled. Resolve by hand, by recorded pid." >&2
        else
            echo "[svc] $name: CANNOT RECONCILE — no process we can see runs '${launch%% *}' with cwd $workdir." >&2
            echo "[svc] $name:   Something IS answering the healthcheck, so the listener belongs to a process outside" >&2
            echo "[svc] $name:   this view: another container/pid-namespace (a record whose reason is 'foreign-namespace'" >&2
            echo "[svc] $name:   is the signature), or another UID entirely. Identify the owner before acting:" >&2
            echo "[svc] $name:     ss -ltnpe | grep <port>     # uid:65534 with no pid = not ours, do NOT kill" >&2
            echo "[svc] $name:   A daemon you cannot see is one you must not signal. Escalate to the operator." >&2
        fi
        echo "[svc] $name:   Pid record PRESERVED at $pf (evidence)." >&2
        return 1
    fi

    echo "[svc] $name: located daemon pid $pid (cwd $workdir) — TERM to its process group" >&2
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "[svc] $name: pid $pid still alive after 5s — KILL" >&2
        kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    fi
    sleep 0.5

    # The daemon we could see is gone. If the healthcheck STILL passes, then
    # whatever is serving was never ours — exactly the case a green probe
    # would otherwise launder into "reconciled".
    if _recover_service_healthy "$workdir" "$health"; then
        echo "[svc] $name: CANNOT RECONCILE — killed the process(es) we found, yet the healthcheck STILL passes." >&2
        echo "[svc] $name:   A DIFFERENT process is serving this endpoint — the healthcheck cannot tell it from ours" >&2
        echo "[svc] $name:   (a port probe, or an SSH banner, proves only that SOMETHING answers). Do not kill blindly:" >&2
        echo "[svc] $name:   identify the listener's owner first (ss -ltnpe), then escalate to the operator." >&2
        return 1
    fi

    rm -f "$pf"
    local outcome
    outcome=$(recover_service "$name" "$workdir" "$launch" "$health" "$logfile")
    echo "[svc] $name: relaunch outcome: $outcome" >&2
    case "$outcome" in
        relaunched|healthy) ;;
        *)  echo "[svc] $name: CANNOT RECONCILE — the daemon was stopped but the relaunch reported '$outcome'." >&2
            echo "[svc] $name:   The service is now DOWN and unsupervised. See the service log, then retry." >&2
            return 1 ;;
    esac
    # Insist on a VALID record: a reconcile that leaves no live supervisor
    # has not reconciled, however green the probe goes.
    _recover_supervisor_probe "$name" "$launch"
    if [[ "$_RECOVER_SUP_STATE" != alive:* ]]; then
        echo "[svc] $name: CANNOT RECONCILE — relaunched, but no live supervisor record exists (state: $_RECOVER_SUP_STATE${_RECOVER_STALE_REASON:+, $_RECOVER_STALE_REASON})." >&2
        return 1
    fi
    echo "[svc] $name: reconciled — daemon bounced, supervisor $_RECOVER_SUP_STATE, record $pf" >&2
    return 0
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
        # ORPHAN CHECK BEFORE ANY REMOVAL (your-org/nexus-code#606). The old
        # code deleted the record first and only then noticed the healthcheck
        # still passed — discarding the record of the daemon it had just
        # failed to stop, and then advising `restart`, which called straight
        # back into here. Order matters: probe, then decide.
        _recover_supervisor_probe "$name" "$launch"
        local st="$_RECOVER_SUP_STATE" why="$_RECOVER_STALE_REASON"
        if _recover_service_healthy "$workdir" "$health"; then
            echo "[svc] $name: REFUSING to drop the pid record — the healthcheck PASSES but no live supervisor holds it (record: $st${why:+, $why})." >&2
            echo "[svc] $name:   A daemon is SERVING UNSUPERVISED. 'stop' cannot stop what it does not track, and deleting" >&2
            echo "[svc] $name:   the record would destroy the only evidence of which supervisor died. Record PRESERVED." >&2
            echo "[svc] $name:   Reconcile (locates the daemon, bounces it, re-supervises): monitor/svc.sh restart $name" >&2
            return 1
        fi
        echo "[svc] $name: no live supervisor — nothing to stop" >&2
        # Healthcheck FAILS too: the record is consistent litter (the
        # supervisor died and took the service with it), so dropping it is
        # safe and keeps recovery from tripping over a dead pid.
        if [[ -f "$pf" ]]; then
            rm -f "$pf"
            echo "[svc] $name: removed stale pid record ($st${why:+, $why}); service is down, so nothing is left unsupervised" >&2
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

# ── cold-build guard (your-org/your-nexus#273) ─────────────────────────────
# A labsh bring-up must re-materialise its ephemeral uvx environment whenever
# the resolution drifts (the jupyterlab spec labsh passes is UNPINNED, so any
# new release among its ~96 packages changes the uv environments-v2 cache key).
# Measured on this nexus 2026-07-13: 15m24s to link 96 packages onto NFS, plus
# ~2min for jupyter-lab to import and bind — a ~19-minute bring-up during which
# NOTHING is listening and the healthcheck legitimately fails.
#
# Every `stop`/`restart` in that window DISCARDS the build and starts the clock
# over from zero. Two such restarts on 2026-07-13 turned one slow bring-up into
# a 40-minute outage that LOOKED like a crash loop (a new pid each cycle) but
# was just the same build being killed and restarted. The supervisor's own
# watchdog never bounced it — the kills came from outside.
#
# So: refuse, loudly, and make the operator/agent say `--force`.
#
# ── THE FAILURE DIRECTION, STATED PLAINLY ───────────────────────────────────
# This guard REFUSES a restart, so its dangerous direction is over-refusing:
#
#   refuses a PROGRESSING build   → correct; that is the whole point.
#   refuses a WEDGED build        → automated recovery is DEFEATED. A human
#                                   must diagnose it and run --force. WORSE
#                                   than the 19-minute outage it prevents.
#
# The first cut of this guard (your-org/nexus-code#525, pre-review) had NO time
# bound: it protected any live build at 2 seconds or at 5 hours. That silently
# nullified the watcher's `cold_build_ceiling`, whose documented purpose is
# exactly "a pathological wedged build must still be recoverable" — the watcher
# would correctly decide to act past its ceiling, call `svc.sh restart`, and be
# REFUSED. A guard against an operator footgun that becomes a footgun. Two
# bounds now stop that:
#
#   1. AGE CAP. Past the ceiling a "build" is pathological BY DEFINITION, not
#      in flight. The cap is the MINIMUM of the watcher's ceiling and the
#      supervisor's reap budget, so this guard can never outlast the layer that
#      is about to act — they cannot drift into a deadlock.
#   2. PROGRESS. A build is protected only while it is MOVING. We sample a
#      monotone counter (CPU time + bytes written + build-log growth) across
#      calls; a build that has not advanced it for LABSH_BUILD_STALL_SECONDS is
#      presumed wedged and released early.
#
# On AMBIGUITY (counters unreadable, no prior sample) we protect — but that
# protection is hard-bounded by the age cap, so the worst case is a bounded
# delay of automated recovery, never a permanent refusal.
#
# NOTE the stall window must be generous: a HEALTHY build on this NFS cache was
# measured showing ZERO forward motion (frozen file count, frozen wchar, ~0 CPU,
# `rpc_wait_bit_killable`) for 90+ seconds at a stretch while legitimately
# progressing. Calling that "wedged" is precisely the mistake this guard exists
# to prevent, so the default is 600s — ~6.7x the longest stall actually observed.

# The age cap: never outlast the layer that is about to act on this build.
_coldbuild_cap() {
    local watcher_ceiling=1800 reap_budget="${LABSH_COLD_BUILD_BUDGET:-1800}" cap
    if [[ -n "${MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS:-}" ]]; then
        watcher_ceiling="$MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS"
    elif [[ -x "${_cfg:-}" ]]; then
        watcher_ceiling=$("$_cfg" monitor.service_health.cold_build_ceiling_seconds 1800 2>/dev/null)
    fi
    [[ "$watcher_ceiling" =~ ^[0-9]+$ ]] || watcher_ceiling=1800
    [[ "$reap_budget"     =~ ^[0-9]+$ ]] || reap_budget=1800
    # A ceiling of 0 disables the watcher's cold-build defer entirely; if the
    # watcher will not defer at all, this guard must not either.
    (( watcher_ceiling == 0 )) && { printf '0'; return 0; }
    cap=$(( watcher_ceiling < reap_budget ? watcher_ceiling : reap_budget ))
    printf '%s' "$cap"
}

# A monotone progress counter for a live build: CPU consumed + bytes written +
# build-log growth. Any increase is forward motion. Prints nothing and fails if
# it cannot be read (⇒ caller treats as "cannot establish a stall").
_coldbuild_progress() {
    local pid="$1" workdir="$2" stat rest ticks=0 wchar=0 bg=0
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    rest=${stat#*") "}                        # drop "pid (comm) " — comm may hold spaces
    # shellcheck disable=SC2086
    set -- $rest                              # ${12}=utime, ${13}=stime (fields 14/15 overall)
    # ${12} NOT $12 — the latter is ${1}2, i.e. the state char with a "2" glued on.
    [[ "${12:-}" =~ ^[0-9]+$ && "${13:-}" =~ ^[0-9]+$ ]] || return 1
    ticks=$(( ${12} + ${13} ))
    wchar=$(awk '/^wchar/{print $2; exit}' "/proc/$pid/io" 2>/dev/null)
    [[ "$wchar" =~ ^[0-9]+$ ]] || wchar=0
    bg=$(stat -c %s "$workdir/.jupyter/labsh.bg.log" 2>/dev/null)
    [[ "$bg" =~ ^[0-9]+$ ]] || bg=0
    printf '%s' $(( ticks + wchar + bg ))
}

# True iff the build has PROVABLY made no forward progress for >= the stall
# window. Samples persist across invocations under STATE_DIR. Unprovable ⇒ 1
# (not stalled ⇒ keep protecting, bounded by the age cap).
_coldbuild_stalled() {
    local name="$1" pid="$2" workdir="$3"
    local stall="${LABSH_BUILD_STALL_SECONDS:-600}"
    local f="$STATE_DIR/service-health/$name.buildprogress"
    local now cur prev_pid prev_ts prev_cur

    [[ "$stall" =~ ^[0-9]+$ ]] && (( stall > 0 )) || return 1
    cur=$(_coldbuild_progress "$pid" "$workdir") || return 1
    now=$(date +%s 2>/dev/null) || return 1
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 1

    # `< "$f"` on a missing file is a REDIRECT failure: bash reports it itself
    # ("No such file or directory") and the `2>/dev/null` on `read` is applied
    # too late to suppress it. On every first-sight refusal that leaked a raw
    # shell error into the operator's face. Test for readability first.
    if [[ -r "$f" ]]; then
        read -r prev_pid prev_ts prev_cur < "$f" || true
    fi

    # A different pid, an unreadable sample, or forward motion ⇒ re-baseline.
    if [[ "${prev_pid:-}" != "$pid" ]] \
       || [[ ! "${prev_ts:-}"  =~ ^[0-9]+$ ]] \
       || [[ ! "${prev_cur:-}" =~ ^[0-9]+$ ]] \
       || (( cur > prev_cur )); then
        printf '%s %s %s\n' "$pid" "$now" "$cur" > "$f" 2>/dev/null || true
        return 1
    fi

    # Same pid, counter has not advanced since prev_ts. Deliberately do NOT
    # refresh the timestamp — the stall is measured from when motion stopped.
    (( now - prev_ts >= stall ))
}

_coldbuild_guard() {
    local name="$1" workdir="$2" launch="$3" ev pid age mins cap stall

    (( SVC_FORCE )) && return 0
    [[ "$launch" == *labsh-supervised.sh* ]] || return 0
    declare -F labsh_build_in_progress >/dev/null || return 0

    ev=$(labsh_build_in_progress "$workdir") || return 0
    pid="${ev%% *}"; age="${ev##* }"
    [[ "$age" =~ ^[0-9]+$ ]] || return 0        # unknown age ⇒ cannot bound ⇒ allow
    mins=$(( age / 60 ))
    cap=$(_coldbuild_cap)
    stall="${LABSH_BUILD_STALL_SECONDS:-600}"

    # cap 0 ⇒ the watcher's cold-build defer is disabled outright. If the layer
    # that owns the policy will not defer, this guard must not defer either.
    (( cap == 0 )) && return 0

    # (1) past the cap it is pathological BY DEFINITION — let it be killed.
    if (( cap > 0 && age >= cap )); then
        echo "svc.sh: '$name' has a labsh build (pid $pid) running ${mins}m (${age}s) — at or past the ${cap}s cold-build ceiling." >&2
        echo "svc.sh: a build this old is presumed WEDGED, not in flight. Allowing the restart so recovery can proceed." >&2
        return 0
    fi

    # (2) alive but not MOVING for the whole stall window ⇒ presumed wedged.
    if _coldbuild_stalled "$name" "$pid" "$workdir"; then
        echo "svc.sh: '$name' has a labsh build (pid $pid, ${mins}m old) that has made NO forward progress" >&2
        echo "svc.sh: (no CPU, no bytes written, no log growth) for >= ${stall}s — presumed wedged. Allowing the restart." >&2
        return 0
    fi

    cat >&2 <<EOF
svc.sh: REFUSING to stop '$name' — a labsh cold build is in flight AND PROGRESSING.

  build pid $pid, running ${mins}m (${age}s); no URL bound yet.
  A cold uvx bring-up takes ~19 min on this NFS cache (measured 2026-07-13:
  15m24s to link 96 packages + ~2min to import and bind).

  Stopping now DISCARDS that build and starts the ~19-minute clock over from
  zero. Repeating it is what turns a slow bring-up into an apparent crash loop.

  This refusal is BOUNDED. It lifts when EITHER:
    - the build stops making progress (no CPU, no bytes written, no log growth)
      for ${stall}s — note this is only re-checked when someone calls svc.sh
      again, so it will not fire on its own while nothing is trying to stop it; or
    - the build is ${cap}s old, at which point it is presumed wedged.

  The watcher (policy auto-restart) forces a restart through this guard once the
  service has been unhealthy past its cold-build ceiling, so a WEDGED build is
  recovered without you. A build that is merely SLOW is what this refusal
  protects — and it will bind on its own.

  Watch it instead:  tail -f $workdir/.jupyter/labsh.bg.log
  Override now:      svc.sh --force restart $name
                     (or SVC_FORCE=1 svc.sh restart $name)
EOF
    return 1
}

cmd_stop() {
    local name="$1"
    case "$name" in
        watcher) _stop_watcher; return ;;
        orchestrator|"$TARGET_WINDOW") _orchestrator_redirect ;;
    esac
    svc_require "$name"
    _coldbuild_guard "${SVC_NAME[$REG_I]}" "${SVC_WORKDIR[$REG_I]}" \
        "${SVC_LAUNCH[$REG_I]}" || return 1
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
    # Run the cold-build guard HERE, before the marker and before the stop.
    # cmd_stop's own `|| true` below is deliberate — a stop of an
    # already-stopped service is benign and must not block the start — but it
    # would also swallow a guard refusal, so the guard cannot live only there.
    svc_require "$name"
    _coldbuild_guard "${SVC_NAME[$REG_I]}" "${SVC_WORKDIR[$REG_I]}" \
        "${SVC_LAUNCH[$REG_I]}" || return 1
    _record_restart_marker "$name"
    # ORPHAN PATH FIRST (your-org/nexus-code#606). The plain stop→start
    # sequence cannot reconcile an orphan: `stop` has no live supervisor to
    # signal, and `start` short-circuits on the daemon's own passing
    # healthcheck — so the bounce this verb promises never happened, and it
    # printed `healthy`. Detect the state up front and do the real work.
    local _n="${SVC_NAME[$REG_I]}" _w="${SVC_WORKDIR[$REG_I]}"
    local _l="${SVC_LAUNCH[$REG_I]}" _h="${SVC_HEALTH[$REG_I]}" _g="${SVC_LOG[$REG_I]}"
    _recover_supervisor_probe "$_n" "$_l"
    if [[ "$_RECOVER_SUP_STATE" != alive:* ]] && _recover_service_healthy "$_w" "$_h"; then
        _svc_reconcile_orphan "$_n" "$_w" "$_l" "$_h" "$_g" \
            "$_RECOVER_SUP_STATE" "$_RECOVER_STALE_REASON"
        return
    fi
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
# --- retire-orphan: the SANCTIONED retirement path (your-org/nexus-code#1034) ----
#
# WHOSE AUTHORISATION THIS IS, stated because it is the whole point. The two
# orphans #1034 found were `setsid`-detached session leaders, so
# `proc-kill-authorized` refused them `not-owned` — CORRECTLY: that guard keys
# on session ownership because a hand-rolled kill list once reaped sibling
# agents' runs (#851), and a detached supervisor is never in anyone's session.
# The workspace could therefore CREATE a supervised daemon from any clone and
# RETIRE it from nowhere. This verb is the missing path, and its authorisation
# is deliberately NOT session ownership. It is two things, both explicit:
#
#   1. THE SCAN'S CLASSIFICATION. `cmd_orphans` is re-run here and the pid
#      must appear in ITS orphan set — ppid 1, a supervisor-shaped script, at
#      a path NO registry row names — with all three of its controls held.
#      A registered supervisor never appears in that set (control C is the
#      independent instrument that refuses when the scan disagrees with the
#      pidfile probe), so a registered service cannot be retired through
#      here even by pid. A scan that REFUSED (rc 3) retires nothing.
#   2. THE OPERATOR'S EXPLICIT `--yes`. Without it the verb prints the plan
#      and exits 4 — not 0 (nothing was retired) and not 2 (nothing was
#      refused): a plan is a third state and it must not read as either.
#
# WHAT IS SIGNALLED, and why not by name. The kill set is the supervisor plus
# its DESCENDANTS as recorded in /proc's PPid chain (depth-bounded), delivered
# to the supervisor's PROCESS GROUP first (a setsid supervisor is its own group
# leader, pid == pgid, exactly as `svc.sh stop` reasons) and to the individual
# pids as a fallback. Nothing here matches a NAME: a sibling agent's argv
# carries every script name in this file verbatim (#1073), and the scan has
# already identified the process by its /proc identity.
#
# THE KILL IS A SEAM. `NEXUS_SVC_KILL_CMD`, when set, receives the exact
# arguments `kill` would and is invoked INSTEAD of it; liveness is read from
# `$SVC_PROCFS` (the scan's own seam). Both exist so the suite can drive the
# refusal arms and the computed kill list against a PLANTED procfs with no
# live processes — a real setsid daemon in a test is unreapable if the suite
# dies mid-run. Nothing in production sets either.
#
# Exit codes:
#   0  retired: every pid in the set is gone from procfs
#   1  signalled (TERM, then KILL after the grace) but still present — inspect
#   2  REFUSED: not an orphan by the scan, the scan itself refused, bad args
#   4  PLAN ONLY (no --yes): printed what it would do, did nothing

# _svc_orphan_descendants <pid> — descendants by recorded PPid, depth <= 3,
# one per line. Reads the same procfs seam the scan reads.
_svc_orphan_descendants() {
    local root="$1" depth=0 d pid ppid f
    local -a frontier=( "$root" ) next=()
    while (( depth < 3 )) && (( ${#frontier[@]} > 0 )); do
        next=()
        for d in "$SVC_PROCFS"/[0-9]*; do
            pid=${d##*/}
            ppid=$(awk '/^PPid:/{print $2}' "$d/status" 2>/dev/null)
            [[ "$ppid" =~ ^[0-9]+$ ]] || continue
            for f in "${frontier[@]}"; do
                [[ "$ppid" == "$f" ]] && { printf '%s\n' "$pid"; next+=( "$pid" ); break; }
            done
        done
        frontier=( "${next[@]}" )
        depth=$(( depth + 1 ))
    done
    return 0
}

_svc_retire_signal() {   # _svc_retire_signal <sig> <target>
    if [[ -n "${NEXUS_SVC_KILL_CMD:-}" ]]; then
        "$NEXUS_SVC_KILL_CMD" "-$1" -- "$2"
    else
        kill "-$1" -- "$2" 2>/dev/null
    fi
}

_svc_retire_alive() {   # sets `alive` from the caller's `kill_set`; rc 0 iff any remain
    local p
    alive=()
    for p in "${kill_set[@]}"; do [[ -d "$SVC_PROCFS/$p" ]] && alive+=( "$p" ); done
    (( ${#alive[@]} > 0 ))
}

cmd_retire_orphan() {
    local pid="" yes=0 a
    for a in "$@"; do
        case "$a" in
            --yes) yes=1 ;;
            -*)    die "retire-orphan: unknown flag $a (usage: svc.sh retire-orphan <pid> [--yes])" ;;
            *)     [[ -z "$pid" ]] || die "retire-orphan: one pid at a time (got '$pid' and '$a')"; pid="$a" ;;
        esac
    done
    [[ "$pid" =~ ^[0-9]+$ ]] || { echo "[svc] retire-orphan: usage: svc.sh retire-orphan <pid> [--yes]" >&2; return 2; }

    # ARM 1 — THE SCAN DECIDES. Its stdout carries the machine-readable ORPHAN
    # rows (SVC_ORPHANS_TSV=1 adds them beside the human report); its rc is
    # the verdict on the SCAN, read before any row is believed.
    local scan_out scan_rc=0
    scan_out=$(SVC_ORPHANS_TSV=1 cmd_orphans 2>&1) || scan_rc=$?
    if (( scan_rc == 3 )); then
        echo "[svc] retire-orphan: REFUSED — the orphans scan itself REFUSED (rc 3), so no classification" >&2
        echo "[svc] retire-orphan:   is available to authorise a retirement. Its reason:" >&2
        # awk, not `grep | head`: an early-exit reader would join the
        # early-exit-reader manifest for a diagnostic whose status nobody reads.
        awk '/REFUSED|CONTROL/ && n++ < 3 { print "[svc] retire-orphan:     " $0 }' <<<"$scan_out" >&2
        return 2
    fi
    if (( scan_rc == 0 )); then
        echo "[svc] retire-orphan: REFUSED — the scan found NO orphans, so pid $pid is not one." >&2
        echo "[svc] retire-orphan:   A registered supervisor is retired with \`svc.sh stop <name>\`, never here." >&2
        return 2
    fi
    if (( scan_rc != 1 )); then
        echo "[svc] retire-orphan: REFUSED — the orphans scan exited $scan_rc, which is not a verdict I know." >&2
        return 2
    fi
    local row src
    row=$(awk -F'\t' -v p="$pid" '$1 == "ORPHAN" && $2 == p { print; exit }' <<<"$scan_out")
    if [[ -z "$row" ]]; then
        echo "[svc] retire-orphan: REFUSED — pid $pid is NOT in the scan's orphan set." >&2
        echo "[svc] retire-orphan:   The scan classifies as orphans ONLY: ppid 1, a supervisor-shaped script, a path" >&2
        echo "[svc] retire-orphan:   no registry row names. A REGISTERED supervisor, a process with a live parent," >&2
        echo "[svc] retire-orphan:   or a non-supervisor never qualifies, whatever its pid. The scan's orphan set:" >&2
        awk -F'\t' '$1 == "ORPHAN" { printf "[svc] retire-orphan:     pid %s  %s\n", $2, $3 }' <<<"$scan_out" >&2
        return 2
    fi
    src=$(cut -f3 <<<"$row")

    # THE KILL SET — recorded relationships, never names.
    local -a kill_set=( "$pid" ) alive=()
    local d
    while IFS= read -r d; do [[ -n "$d" ]] && kill_set+=( "$d" ); done < <(_svc_orphan_descendants "$pid")

    local grace="${NEXUS_SVC_RETIRE_GRACE:-5}"
    echo "[svc] retire-orphan: pid $pid is an orphan by the scan: $src"
    echo "[svc] retire-orphan:   kill set (supervisor + descendants by recorded PPid): ${kill_set[*]}"
    echo "[svc] retire-orphan:   plan: TERM process group $pid (fallback: each pid), wait ${grace}s, KILL survivors"
    if (( ! yes )); then
        echo "[svc] retire-orphan: PLAN ONLY — nothing was signalled. Re-run with --yes to retire (exit 4)."
        return 4
    fi

    # ARM 2 — THE OPERATOR SAID SO. Log FIRST, so the record exists whether or
    # not the signals land (stamp-then-act fails loud; act-then-stamp fails silent).
    local logdir="${NEXUS_STATE_DIR:-$STATE_DIR}"
    mkdir -p "$logdir" 2>/dev/null || true
    printf '%s\tuser=%s\tpid=%s\tsrc=%s\tkill_set=%s\tby=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)" "$(id -un 2>/dev/null || echo '?')" \
        "$pid" "$src" "${kill_set[*]}" "${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-operator}}" \
        >> "$logdir/svc-retire.log" 2>/dev/null \
        || echo "[svc] retire-orphan: WARNING — could not append to $logdir/svc-retire.log" >&2

    local p waited=0
    _svc_retire_signal TERM "-$pid" || for p in "${kill_set[@]}"; do _svc_retire_signal TERM "$p"; done
    while _svc_retire_alive && (( waited < grace )); do sleep 1; waited=$(( waited + 1 )); done
    if _svc_retire_alive; then
        echo "[svc] retire-orphan: still present after TERM + ${grace}s: ${alive[*]} — escalating to KILL"
        _svc_retire_signal KILL "-$pid" || for p in "${alive[@]}"; do _svc_retire_signal KILL "$p"; done
        sleep 1
    fi
    if _svc_retire_alive; then
        echo "[svc] retire-orphan: WARNING — still present after KILL: ${alive[*]}. Inspect: ps -o pid,ppid,pgid,args -p ${alive[*]}" >&2
        return 1
    fi
    echo "[svc] retire-orphan: retired pid $pid (${#kill_set[@]} process(es)); logged to $logdir/svc-retire.log"
    return 0
}

# --- orphans: READ-ONLY enumeration of UNREGISTERED supervisors ------------
#
# A DIFFERENT ORPHAN FROM `_svc_reconcile_orphan` ABOVE, and the distinction is
# the whole reason this verb exists (your-org/nexus-code#1034). That one is a
# REGISTERED service whose healthcheck passes while its supervisor RECORD is
# stale — it is found by name, through the registry, via _recover_pidfile. Its
# domain is exactly the registry.
#
# This one is a supervisor with NO REGISTRY ROW AT ALL: a `*-supervised.sh`
# left running from a retired clone or an ephemeral scratch directory after the
# agent that started it went away. Nothing keyed on a registry name can see it,
# because there is no name to key on. `status`, the cockpit and every existing
# verb iterate `load_services`, i.e. the registry — so an unregistered
# supervisor is outside their domain BY CONSTRUCTION, not by oversight. #1034
# reported three `remote-sshd-supervised.sh` processes of which one was
# registered, one held a LIVE sshd on a port nobody knew about, and concluded
# "enumeration first: today nobody can even LIST the problem". This is that
# enumeration.
#
# STRICTLY READ-ONLY. It signals nothing, writes nothing and starts nothing;
# there is deliberately no `--reap` and no kill path here, so the verb cannot
# become the thing that retires a live service by mistake. Retirement is
# recommendation 2 of #1034 and is NOT implemented here.
#
# ── ppid==1 IS NOT THE DISCRIMINATOR ────────────────────────────────────────
# Every CORRECTLY supervised service is also ppid 1: `recover_service` detaches
# with `setsid`, so re-parenting to init is the NORMAL state, not the anomaly.
# Measured on this nexus 2026-09-02, `ps -eo pid=,ppid=` over supervisor-shaped
# processes: 10 of 10 had ppid 1, and 9 of them were healthy registered
# services. A verb keyed on ppid alone would flag the entire stack.
# The discriminator is the SOURCE PATH: is this the script the registry says
# should be running, at the path the registry says it should run from?
#
# ── THE POPULATION PREDICATE UNDER-COUNTS, AND HERE IS THE DIRECTION ────────
# Candidates are drawn from the UNION of two rules:
#   (1) basename matches the basename of some registry launch command — this
#       is what catches a foreign clone running the SAME script from a
#       DIFFERENT path, which is exactly #1034's two orphans;
#   (2) basename matches the supervisor SHAPE (`*-supervised.sh`, `*-watch.sh`,
#       `watch.sh`) — this catches a supervisor from a clone whose registry row
#       we do not have.
# Rule (2) alone is demonstrably insufficient ON THIS REGISTRY: the
# `myviewer-xiulan` row launches `run-supervised-xiulan.sh`, whose basename
# does NOT end in `-supervised.sh`, so a shape-only predicate misses it. Rule
# (1) alone is insufficient because a retired clone may run a script this
# registry never mentions. The union is still an APPROXIMATION and it errs
# DOWNWARD: a supervisor with a novel name from a clone with no registry row is
# invisible to both rules. That is stated rather than hidden, per this repo's
# rule that a source-text predicate for a runtime property must declare which
# way it is wrong.
#
# ── WHY A ZERO HERE NEEDS TWO POSITIVE CONTROLS ─────────────────────────────
# "No orphans" and "my scan is broken" produce the same empty table, and a
# confident zero it cannot vouch for is this repo's dominant defect class. So
# `none found` is reported ONLY when both controls hold, and REFUSED (rc 3)
# otherwise:
#   CONTROL A (the walk)    — the /proc walk must see this very process. If it
#                             cannot see a pid we KNOW exists, no absence it
#                             reports means anything.
#   CONTROL B (the matcher) — at least one REGISTERED supervisor must have been
#                             matched by the predicate. A matcher that has
#                             never matched anything has not been shown to be
#                             able to match, so its zero is unvouched.
# Control B fails legitimately when the whole stack is down. That is REFUSED,
# not "none" — the honest answer is that this scan cannot tell.
#
# Exit codes:
#   0  scan complete, NO orphans — and both controls held
#   1  scan complete, orphans FOUND (count on stdout)
#   3  REFUSED — could not determine (a control failed, or /proc is unusable).
#      DISTINCT from 0 on purpose: "none found" and "I could not look" are
#      different claims and only one of them is a clearance.

# The process table this verb reads. Overridable ONLY so the test suite can
# plant a synthetic one: creating a REAL ppid-1 process to test a ppid-1
# detector would need `setsid` inside a test, which is both a footgun and
# unreapable if the suite dies mid-run. A planted tree exercises the exact same
# classification code with no live processes at all. Defaults to /proc; nothing
# in production sets it.
SVC_PROCFS="${SVC_PROCFS:-/proc}"

# _svc_proc_argv_script <pid> — the script this pid is running, as invoked:
# argv[0] when executed directly, argv[1] under an interpreter. Empty when the
# cmdline is unreadable or holds neither. Reads /proc directly rather than
# matching `ps` output text, because a sibling agent's PROMPT contains these
# script names verbatim and a text match would return the DESCRIPTION of a
# process instead of the process (your-org/nexus-code#1073).
_svc_proc_argv_script() {
    local pid="$1" a n=0
    local -a args=()
    [[ -r "$SVC_PROCFS/$pid/cmdline" ]] || return 1
    while IFS= read -r -d '' a; do
        args+=( "$a" ); n=$(( n + 1 ))
        (( n >= 3 )) && break
    done < "$SVC_PROCFS/$pid/cmdline"
    (( ${#args[@]} > 0 )) || return 1
    case "${args[0]}" in
        */bash|bash|*/sh|sh|*/dash|dash|*/zsh|zsh|*/env|env)
            [[ ${#args[@]} -gt 1 ]] && { printf '%s' "${args[1]}"; return 0; }
            return 1 ;;
    esac
    printf '%s' "${args[0]}"
    return 0
}

# _svc_abs_path <maybe-relative> <cwd> — absolute form, WITHOUT requiring the
# path to exist. A retired clone's script may have been deleted out from under
# the running process, and `readlink -f` on a vanished path still composes the
# absolute name, which is what we want to REPORT.
_svc_abs_path() {
    local p="$1" cwd="$2"
    [[ "$p" == /* ]] || p="$cwd/$p"
    _svc_norm_path "$p"
}

# _svc_norm_path <abs-path> — collapse `//`, `/./` and `x/..` LEXICALLY.
#
# NOT `readlink -f`, which returns EMPTY for a path that does not exist — and a
# retired clone's script being deleted out from under its still-running process
# is the CENTRAL case here, so resolving would blank exactly the orphan we came
# to report.
#
# THIS IS NOT COSMETIC, and it is the bug the first live run actually had. The
# registry writes workdirs as `$NEXUS_ROOT/work/x` with launch `./serve.sh`,
# composing `/work/x/./serve.sh`, while the running process carries the
# ABSOLUTE `/work/x/serve.sh`. Those are the same file and differ by three
# characters, so a string compare called 8 of 10 healthy registered services
# ORPHANS on this nexus at 2026-09-02T10:06Z. A false positive on this verb is
# a nudge toward killing a live production service, so it is the expensive
# direction.
_svc_norm_path() {
    local p="$1" out="" seg
    local -a parts=() keep=()
    while [[ "$p" == *//* ]]; do p="${p//\/\///}"; done
    local IFSSAVE="$IFS"; IFS='/'; read -r -a parts <<<"$p"; IFS="$IFSSAVE"
    for seg in "${parts[@]}"; do
        case "$seg" in
            ''|'.') continue ;;
            '..')   [[ ${#keep[@]} -gt 0 ]] && unset 'keep[-1]' && keep=( "${keep[@]}" ) ;;
            *)      keep+=( "$seg" ) ;;
        esac
    done
    for seg in "${keep[@]}"; do out="$out/$seg"; done
    printf '%s' "${out:-/}"
}

cmd_orphans() {
    [[ $# -eq 0 ]] || die "usage: svc.sh orphans   (read-only; takes no arguments)"

    # NOTE — there is deliberately no separate `[[ -d "$SVC_PROCFS/$$" ]]` pre-check
    # here. There used to be, and it made CONTROL A below UNREACHABLE AS A
    # DISTINCT FAILURE: both fire on exactly the same condition, so the earlier
    # one always won and the later one could be disarmed with no test noticing.
    # A mutant that pre-set `self_seen=1` left the suite fully green. Two guards
    # for one condition is not defence in depth; it is one guard plus an
    # untested claim. Control A now carries it alone, and is proven live by
    # mutation (M2).

    # Expected supervisor paths + basenames, from the registry.
    local -a expect_path=() expect_name=() expect_base=()
    local line name workdir launch health logfile tok abs
    while IFS=$'\t' read -r name workdir launch health logfile; do
        [[ -n "$name" ]] || continue
        tok=${launch%% *}
        [[ -n "$tok" ]] || continue
        abs=$(_svc_abs_path "$tok" "$workdir")
        expect_path+=( "$abs" ); expect_name+=( "$name" ); expect_base+=( "${tok##*/}" )
    done < <(svc_parse_registry "$SERVICES_REGISTRY")

    if ! svc_registry_readable "$SERVICES_REGISTRY"; then
        echo "[svc] orphans: REFUSED — the registry at $SERVICES_REGISTRY EXISTS and could NOT be READ." >&2
        echo "[svc] orphans:   This is NOT 'no services registered'. No classification is possible." >&2
        return 3
    fi
    if (( ${#expect_path[@]} == 0 )); then
        echo "[svc] orphans: REFUSED — the registry at $SERVICES_REGISTRY yielded no rows, so there is" >&2
        echo "[svc] orphans:   nothing to classify AGAINST. Every supervisor would read as unregistered," >&2
        echo "[svc] orphans:   which is an artefact of the empty registry, not a finding." >&2
        return 3
    fi

    # ---- the scan ---------------------------------------------------------
    local self_seen=0 registered_seen=0 orphan_n=0
    local -a o_pid=() o_src=() o_why=()
    local d pid ppid script cwd src i matched base

    for d in "$SVC_PROCFS"/[0-9]*; do
        pid=${d##*/}
        # CONTROL A is set HERE — before the readability filter below — because
        # it asserts that the WALK ENUMERATED this entry, which is a different
        # claim from "the entry was parseable". A `continue` past an unreadable
        # cmdline must not be able to retract the walk's own positive control.
        (( pid == $$ )) && self_seen=1        # CONTROL A
        [[ -r "$d/cmdline" ]] || continue
        script=$(_svc_proc_argv_script "$pid") || continue
        [[ -n "$script" ]] || continue
        base=${script##*/}

        # population: registry basename OR supervisor shape
        matched=0
        for i in "${!expect_base[@]}"; do
            [[ "$base" == "${expect_base[$i]}" ]] && { matched=1; break; }
        done
        if (( ! matched )); then
            case "$base" in
                *-supervised.sh|*-supervised-*.sh|*-watch.sh|watch.sh|deploy-watch.sh) matched=1 ;;
            esac
        fi
        (( matched )) || continue

        cwd=$(readlink "$d/cwd" 2>/dev/null) || cwd=""
        src=$(_svc_abs_path "$script" "${cwd:-/}")

        ppid=$(awk '/^PPid:/{print $2}' "$d/status" 2>/dev/null)
        [[ "$ppid" =~ ^[0-9]+$ ]] || continue

        # Is this exactly a registry-declared supervisor path?
        local is_reg=0
        for i in "${!expect_path[@]}"; do
            [[ "$src" == "${expect_path[$i]}" ]] && { is_reg=1; break; }
        done
        if (( is_reg )); then
            registered_seen=1                  # CONTROL B
            continue
        fi

        # Not registry-declared. Only ppid 1 is an ORPHAN — a supervisor with a
        # live parent is somebody's child and is being managed by whoever
        # started it; reporting it would be a false positive on, for instance,
        # a test fixture's own supervisor.
        (( ppid == 1 )) || continue

        local why
        case "$src" in
            "$NEXUS_ROOT"/*) why="unregistered: inside NEXUS_ROOT but no registry row names this path" ;;
            *)               why="unregistered: source path is OUTSIDE NEXUS_ROOT ($NEXUS_ROOT)" ;;
        esac
        o_pid+=( "$pid" ); o_src+=( "$src" ); o_why+=( "$why" )
        orphan_n=$(( orphan_n + 1 ))
    done

    # ---- controls ---------------------------------------------------------
    if (( ! self_seen )); then
        echo "[svc] orphans: REFUSED — CONTROL A FAILED: the walk over $SVC_PROCFS did not enumerate" >&2
        echo "[svc] orphans:   this very process (pid $$), so no scan is possible. A scan that cannot see a" >&2
        echo "[svc] orphans:   pid it KNOWS exists cannot vouch for any absence it reports." >&2
        return 3
    fi
    # CONTROL C — AN INDEPENDENT INSTRUMENT MUST NOT DISAGREE.
    #
    # Controls A and B are both self-referential: they ask this scan whether it
    # can see things, using this scan. Neither can catch a matcher that matches
    # the WRONG set, and that is not hypothetical — the first live version of
    # this verb passed BOTH while calling 8 of 10 healthy registered services
    # orphans, because control B only ever needed ONE match and two registry
    # rows happened to use absolute launch paths.
    #
    # So ask a DIFFERENT instrument the same question: `_recover_supervisor_state`
    # resolves a service by NAME through its pidfile, a path with nothing in
    # common with the /proc argv walk above. If it says a registered service's
    # supervisor is alive at pid N, and this scan put pid N in the orphan list,
    # then one of the two is wrong and this verb must not adjudicate its own
    # correctness. Refuse.
    local _cc_i _cc_st _cc_pid _cc_j
    for _cc_i in "${!expect_name[@]}"; do
        _cc_st=$(_recover_supervisor_state "${expect_name[$_cc_i]}" "${expect_path[$_cc_i]}" 2>/dev/null)
        [[ "$_cc_st" == alive:* ]] || continue
        _cc_pid="${_cc_st#alive:}"
        for _cc_j in "${!o_pid[@]}"; do
            [[ "${o_pid[$_cc_j]}" == "$_cc_pid" ]] || continue
            echo "[svc] orphans: REFUSED — CONTROL C FAILED: pid $_cc_pid is flagged as an orphan here," >&2
            echo "[svc] orphans:   but the INDEPENDENT pidfile probe resolves it as the live supervisor of the" >&2
            echo "[svc] orphans:   REGISTERED service '${expect_name[$_cc_i]}'. Two instruments disagree about a" >&2
            echo "[svc] orphans:   registered service, so this scan's classification is not trustworthy and" >&2
            echo "[svc] orphans:   nothing here should be acted on. Source seen: ${o_src[$_cc_j]}" >&2
            echo "[svc] orphans:   Registry expects: ${expect_path[$_cc_i]}" >&2
            return 3
        done
    done

    if (( ! registered_seen )); then
        echo "[svc] orphans: REFUSED — CONTROL B FAILED: the predicate matched NO registered supervisor," >&2
        echo "[svc] orphans:   so it has not been shown able to match one. Either the whole stack is down" >&2
        echo "[svc] orphans:   (check \`svc.sh status\`) or the population predicate is broken; this scan" >&2
        echo "[svc] orphans:   cannot tell those apart, and 'none found' would be a guess." >&2
        if (( orphan_n > 0 )); then
            echo "[svc] orphans:   NOTE: $orphan_n candidate(s) WERE flagged and are printed below — a" >&2
            echo "[svc] orphans:   positive finding does not need control B. The REFUSAL is about the ZERO." >&2
            _svc_orphans_report
        fi
        return 3
    fi

    if (( orphan_n == 0 )); then
        echo "orphans: none found"
        echo "  scanned $SVC_PROCFS; population = registry launch basenames ∪ supervisor shape"
        echo "  CONTROL A (walk saw pid $$): ok"
        echo "  CONTROL B (matched a registered supervisor): ok"
        echo "  registry: $SERVICES_REGISTRY (${#expect_path[@]} rows)"
        return 0
    fi

    _svc_orphans_report
    return 1
}

# Printing is a separate function so the control-B refusal path can show its
# candidates without duplicating the formatter. Reads the o_* arrays from the
# caller's scope (bash dynamic scope on `local`).
_svc_orphans_report() {
    local i pid src ssout have_pid_attr
    printf 'orphans: %s unregistered supervisor(s) with ppid 1\n' "${#o_pid[@]}"
    # Machine-readable rows for `retire-orphan` (SVC_ORPHANS_TSV=1): one per
    # orphan, `ORPHAN<TAB>pid<TAB>source<TAB>descendants`. Emitted from the
    # SAME arrays the human report prints, so the two cannot disagree.
    if [[ "${SVC_ORPHANS_TSV:-0}" == 1 ]]; then
        for i in "${!o_pid[@]}"; do
            printf 'ORPHAN\t%s\t%s\t%s\n' "${o_pid[$i]}" "${o_src[$i]}" \
                "$(_svc_orphan_descendants "${o_pid[$i]}" | tr '\n' ' ' | sed 's/ $//')"
        done
    fi
    ssout=$(ss -lntp 2>/dev/null) || ssout=""
    have_pid_attr=0
    [[ "$ssout" == *"pid="* ]] && have_pid_attr=1
    for i in "${!o_pid[@]}"; do
        pid="${o_pid[$i]}"; src="${o_src[$i]}"
        printf '\n  pid      %s\n' "$pid"
        printf '  source   %s\n' "$src"
        printf '  why      %s\n' "${o_why[$i]}"
        printf '  exists   %s\n' "$( [[ -e "$src" ]] && echo 'yes' || echo 'NO — the script file is GONE (retired clone or cleaned scratch dir)' )"
        printf '  cwd      %s\n' "$(readlink "$SVC_PROCFS/$pid/cwd" 2>/dev/null || echo '<unreadable>')"
        printf '  uptime   %ss\n' "$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ' || echo '?')"
        printf '  started  %s\n' "$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//' || echo '?')"
        _svc_orphan_children "$pid"
        _svc_orphan_sockets  "$pid" "$ssout" "$have_pid_attr"
    done
    printf '\nREAD-ONLY: nothing above was signalled, stopped or restarted. To retire ONE of\n'
    printf 'the pids above (and only one the scan classifies as an orphan), the sanctioned\n'
    printf 'path is: svc.sh retire-orphan <pid>   (plan)   then   --yes   (your-org/nexus-code#1034).\n'
}

# Descendants (one level, plus their own children) — enough to show what a
# supervisor is actually holding open without walking the whole tree.
_svc_orphan_children() {
    local parent="$1" d pid ppid n=0 cl
    printf '  children\n'
    for d in "$SVC_PROCFS"/[0-9]*; do
        pid=${d##*/}
        ppid=$(awk '/^PPid:/{print $2}' "$d/status" 2>/dev/null)
        [[ "$ppid" == "$parent" ]] || continue
        cl=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
        printf '    %-8s %s\n' "$pid" "$(printf '%s' "${cl:0:160}")"
        n=$(( n + 1 ))
    done
    (( n == 0 )) && printf '    (none — supervising nothing)\n'
    return 0
}

# Listening sockets held by the supervisor or any of its children.
# `ss -lntp` attributes a pid directly. When it produces NO pid attribution at
# all we say so rather than printing an empty list: "ss could not tell us" and
# "this process listens on nothing" are different facts, and a live sshd on an
# unknown port is precisely what #1034 was about.
_svc_orphan_sockets() {
    local parent="$1" ssout="$2" have="$3" d pid ppid n=0
    local -a pids=( "$parent" )
    for d in "$SVC_PROCFS"/[0-9]*; do
        pid=${d##*/}
        ppid=$(awk '/^PPid:/{print $2}' "$d/status" 2>/dev/null)
        [[ "$ppid" == "$parent" ]] && pids+=( "$pid" )
    done
    printf '  listening\n'
    if [[ -z "$ssout" ]]; then
        printf '    UNKNOWN — `ss -lntp` produced no output (ss missing or refused); NOT a claim of none\n'
        return 0
    fi
    if (( ! have )); then
        printf '    UNKNOWN — `ss -lntp` returned no pid attribution on this host; NOT a claim of none\n'
        return 0
    fi
    local p line
    for p in "${pids[@]}"; do
        while IFS= read -r line; do
            [[ "$line" == *"pid=$p,"* ]] || continue
            printf '    %s\n' "$line"
            n=$(( n + 1 ))
        done <<<"$ssout"
    done
    (( n == 0 )) && printf '    (none)\n'
    return 0
}

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
    # --force: override the cold-build guard (see _coldbuild_guard). Accepted
    # before the verb so `svc.sh --force restart jupyterlab` reads naturally.
    # Also honoured via the SVC_FORCE env var, for non-interactive callers.
    if [[ "${1:-}" == "--force" ]]; then
        SVC_FORCE=1
        shift
    fi

    case "${1:-}" in
        -h|--help)        usage ;;
        status|--status|-1) cmd_status ;;
        up)               shift; cmd_up "$@" ;;
        orphans)          shift; cmd_orphans "$@" ;;
        retire-orphan)    shift; cmd_retire_orphan "$@" ;;
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
