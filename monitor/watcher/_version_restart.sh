#!/usr/bin/env bash
# Watcher version-aware component restart (your-org/your-nexus#186).
#
# Makes `git pull` the entire nexus-code update story: the watcher
# compares, per component, the SOURCE-SET HASH of the code each running
# instance loaded at start against the hash of the same files on disk
# now, and on confirmed drift triggers the restart path appropriate to
# that component. Before this module, a pull left the watcher / services
# cockpit / registered services silently running OLD code until someone
# remembered the manual restart — the footgun behind the whole
# "watcher-isolation / pull-then-restart" caution in CLAUDE.md.
#
# Component model — each component restarts ONLY when ITS files changed
# (a per-component source-set hash, not a coarse HEAD SHA that bumps on
# every pull):
#
#   watcher   source set = main.sh + every file main.sh `source`s
#             (parsed from the on-disk main.sh, so a newly added module
#             is picked up the moment the source line lands). Running
#             version recorded by main.sh at startup — at that moment
#             disk == memory, so the record is exact. Restart path:
#             detached `launcher.sh --replace` (the blessed relaunch
#             primitive; SIGTERM → graceful trap → fresh headless spawn).
#   cockpit   source set = svc.sh + bootstrap-recover.sh + watcher/_lib.sh
#             + this module (svc.sh's source closure). The cockpit is an
#             interactive TUI the ORCHESTRATOR owns; the watcher NEVER
#             kills its window. Drift → an ask record surfaced through
#             the emit (once per candidate hash, cc-update style) telling
#             the orchestrator how to bounce it.
#   service-* one per services.registry row; source set = the launch
#             script (first launch-cmd token that resolves to a file).
#             Running version recorded by `_recover_launch_service` at
#             launch. Drift while the supervisor is alive →
#             `svc.sh restart <name>` (stop + idempotent recover-start).
#             No supervisor → silent re-baseline (the next launch runs
#             new code anyway).
#
# Safety model (the load-bearing part — guard heavily):
#
#   stability window  a changed hash must be observed UNCHANGED for
#                     `settle` seconds before any action. A `git pull`
#                     mid-write produces a hash that keeps moving (or a
#                     torn read, below); the window outwaits it.
#   torn detection    any missing/unreadable file in a source set ⇒
#                     verdict `torn`, NO action, NO state change. A
#                     half-applied pull can never trigger a restart into
#                     a tree that would fail to source.
#   per-component cooldown  after any action, further actions on that
#                     component are suppressed for `cooldown` seconds —
#                     a persistent mismatch retries slowly instead of
#                     tight-looping.
#   self-restart loop guard  at most `loop_limit` watcher self-restarts
#                     per `loop_window` seconds; past that the guard
#                     trips, auto self-restart suspends, and an advisory
#                     record asks the operator/orchestrator to intervene.
#                     Re-arms after a full quiet window. Note the
#                     steady-state already converges: a successful
#                     restart makes running == disk, so re-trigger needs
#                     a NEW disk change — the guard is belt-and-braces
#                     against pathological churn.
#   advise fallback   with the per-channel knob off (self/services), a
#                     confirmed drift degrades to an ask record instead
#                     of an action — never silent.
#   bootstrap caveat  the auto-restart only takes effect once a
#                     version-aware watcher is ITSELF running. The FIRST
#                     deploy of this feature is still the manual
#                     pull-then-restart (`monitor/svc.sh restart watcher`).
#
# State lives under `monitor/.state/version/`:
#   <comp>.running            hash=… recorded=…   (the running version)
#   <comp>.pending            hash=… first_seen=… (stability tracking)
#   <comp>.restart.last       cooldown stamp (mtime)
#   self-restart-history.txt  one epoch per watcher self-restart
#   self-restart-tripped      loop-guard tripped stamp (mtime re-arms)
#   drift-<comp>              ask record (key=value, cc-update style)
#   drift-<comp>-surfaced     re-nag guard (candidate hash last surfaced)
#
# All functions are side-effect-free at source time. Tests inject the
# launcher / svc.sh / tmux probes via the _VERSION_* indirections.

# ---- double-source guard --------------------------------------------------
if [[ -n "${_NEXUS_VERSION_RESTART_LOADED:-}" ]]; then
    return 0
fi
_NEXUS_VERSION_RESTART_LOADED=1

# Module dir, resolved at source time (BASH_SOURCE inside a function
# reports the defining file, but an eager copy is cheaper and clearer).
_VERSION_MODULE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# `_ensure_service_log` (nexus-code#484/#509): the self-restart's
# `>>"$logfile"` redirect must never create watcher.log group-writable.
# shellcheck source=../_log-mode.sh
source "$_VERSION_MODULE_DIR/../_log-mode.sh"

# Log through the host's `log` when one is defined (the watcher's
# stderr logger), else fall back to plain stderr so the module stays
# usable from bootstrap-recover.sh / tests without ceremony.
_version_log() {
    if declare -F log >/dev/null 2>&1; then
        log "version: $*"
    else
        printf '[version] %s\n' "$*" >&2
    fi
}

# _version_field <file> <key> — read one `key=value` field (same shape
# as _cc_update_field; duplicated locally so this module has no load
# order dependency on _cc_update.sh).
_version_field() {
    local file="${1:?file required}" key="${2:?key required}"
    [[ -f "$file" ]] || return 1
    local out
    out=$(awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$file")
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

# ---- hashing primitives ----------------------------------------------------

# _version_hash_files <file...>
#
# Combined sha256 over the given files (per-file `sha256sum` rows,
# sorted, hashed again — so both content and the file LIST are pinned).
# rc 1 with NO output when any file is missing/unreadable: that is the
# torn-pull signal, and the caller must treat it as "do not act".
_version_hash_files() {
    (( $# > 0 )) || return 1
    local f line lines=""
    for f in "$@"; do
        [[ -n "$f" ]] || return 1
        line=$(sha256sum -- "$f" 2>/dev/null) || return 1
        lines+="$line"$'\n'
    done
    printf '%s' "$lines" | sort | sha256sum | awk '{print $1}'
}

# _version_watcher_source_set <main_sh>
#
# The watcher's source set: main.sh itself plus every module it loads
# via the canonical `source "$_script_dir/<rel>"` pattern (including
# `../_cc-version.sh`). Parsed from the ON-DISK main.sh so a pull that
# adds a new module both changes main.sh (hash bump now) and extends
# the set (tracked from then on). rc 1 when main.sh is absent.
_version_watcher_source_set() {
    local main_sh="${1:?main_sh required}"
    [[ -f "$main_sh" ]] || return 1
    local dir
    dir=$(cd "$(dirname "$main_sh")" && pwd) || return 1
    {
        printf '%s\n' "$dir/$(basename "$main_sh")"
        # shellcheck disable=SC2016
        sed -nE 's|^[[:space:]]*source[[:space:]]+"\$_script_dir/([^"]+)".*|\1|p' \
            "$main_sh" \
            | while IFS= read -r rel; do
                  [[ -n "$rel" ]] && printf '%s/%s\n' "$dir" "$rel"
              done
    } | sort -u
}

# _version_cockpit_source_set <monitor_dir>
#
# svc.sh's source closure: svc.sh sources bootstrap-recover.sh, which
# sources watcher/_lib.sh and watcher/_version_restart.sh. Kept as an
# explicit list (the closure is 4 files and changes rarely); revisit if
# svc.sh ever grows a dynamic module loader.
_version_cockpit_source_set() {
    local monitor_dir="${1:?monitor_dir required}"
    printf '%s\n' \
        "$monitor_dir/svc.sh" \
        "$monitor_dir/bootstrap-recover.sh" \
        "$monitor_dir/watcher/_lib.sh" \
        "$monitor_dir/watcher/_version_restart.sh"
}

# _version_service_script <workdir> <launch>
#
# Resolve the registry launch command to the script file it runs: the
# FIRST whitespace token that (workdir-relative for non-absolute paths)
# names an existing regular file. Handles `./serve.sh --flag`,
# `bash serve.sh`, `/abs/wrapper.sh args`. A launch with no file-backed
# token (`python -m http.server`) is untrackable → rc 1, and the
# service is simply not version-managed (documented limitation).
_version_service_script() {
    local workdir="${1:?workdir required}" launch="${2:?launch required}"
    local tok cand
    for tok in $launch; do
        case "$tok" in
            *=*) continue ;;   # leading VAR=val env assignments
        esac
        cand="$tok"
        [[ "$cand" == /* ]] || cand="$workdir/$tok"
        if [[ -f "$cand" ]]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

# ---- running-version records ------------------------------------------------

# _version_record_running <version_state_dir> <comp> <hash>  (atomic)
_version_record_running() {
    local state_dir="${1:?state_dir required}" comp="${2:?comp required}" hash="${3:?hash required}"
    mkdir -p "$state_dir" 2>/dev/null || true
    local f="$state_dir/$comp.running"
    {
        printf 'hash=%s\n' "$hash"
        printf 'recorded=%s\n' "$(date -Is 2>/dev/null || echo unknown)"
    } > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
}

# _version_record_service_running <version_state_dir> <name> <workdir> <launch>
#
# Stamp a service's running version at LAUNCH time — called by
# `_recover_launch_service` in bootstrap-recover.sh, so every start
# path (recovery sweep, `svc.sh start/restart`) records what it ran.
# Best-effort no-op (rc 0) when the launch has no trackable script.
_version_record_service_running() {
    local state_dir="${1:?state_dir required}" name="${2:?name required}"
    local workdir="${3:?workdir required}" launch="${4:?launch required}"
    local script hash
    script=$(_version_service_script "$workdir" "$launch") || return 0
    hash=$(_version_hash_files "$script") || return 0
    _version_record_running "$state_dir" "service-$name" "$hash"
    rm -f "$state_dir/service-$name.pending" 2>/dev/null || true
    return 0
}

# _version_startup_record <version_state_dir> <main_sh>
#
# Called by main.sh at startup, after every `source` completed: at that
# instant the on-disk source set IS what this process is running, so
# the hash is the exact running version. Clears any stale pending so a
# fresh watcher starts with a clean drift state machine.
_version_startup_record() {
    local state_dir="${1:?state_dir required}" main_sh="${2:?main_sh required}"
    local -a files=()
    mapfile -t files < <(_version_watcher_source_set "$main_sh") || return 1
    (( ${#files[@]} > 0 )) || return 1
    local hash
    hash=$(_version_hash_files "${files[@]}") || return 1
    _version_record_running "$state_dir" watcher "$hash" || return 1
    rm -f "$state_dir/watcher.pending" 2>/dev/null || true
    printf '%s\n' "$hash"
}

# ---- drift state machine ------------------------------------------------------

# _version_check_component <version_state_dir> <comp> <current_hash|TORN> <settle_s> <now_epoch>
#
# Pure-ish state step for one component. Verdicts on stdout, rc 0:
#   torn       current unknown (missing file mid-pull) — nothing touched
#   adopted    no running record existed; current adopted as baseline
#              (pre-feature instances get version-managed from now on)
#   unchanged  current == running; pending + stale drift records cleared
#   pending    current != running but not yet stable for settle seconds
#   drift      current != running, stable past the window — caller acts
_version_check_component() {
    local state_dir="${1:?state_dir required}" comp="${2:?comp required}"
    local current="${3:-TORN}" settle="${4:-45}" now="${5:-$(date +%s)}"
    local running_file="$state_dir/$comp.running"
    local pending_file="$state_dir/$comp.pending"

    if [[ -z "$current" || "$current" == "TORN" ]]; then
        printf 'torn\n'
        return 0
    fi
    mkdir -p "$state_dir" 2>/dev/null || true

    local running=""
    running=$(_version_field "$running_file" hash 2>/dev/null || true)
    if [[ -z "$running" ]]; then
        _version_record_running "$state_dir" "$comp" "$current"
        printf 'adopted\n'
        return 0
    fi

    if [[ "$current" == "$running" ]]; then
        rm -f "$pending_file" 2>/dev/null || true
        # Self-heal a stale ask record once running has converged PAST
        # it (the cc-update self-heal model): e.g. the guard-tripped
        # advisory after the operator's manual restart. A record whose
        # candidate EQUALS the running hash is the adopt-at-ask shape
        # (cockpit ask, disabled-channel advisory) — that one must
        # survive until the orchestrator acks (rm) or a newer candidate
        # overwrites it, so only a mismatched candidate is cleared.
        if [[ -f "$state_dir/drift-$comp" ]]; then
            local rec_new
            rec_new=$(_version_field "$state_dir/drift-$comp" new 2>/dev/null || true)
            if [[ "$rec_new" != "$current" ]]; then
                rm -f "$state_dir/drift-$comp" "$state_dir/drift-$comp-surfaced" \
                    2>/dev/null || true
            fi
        fi
        printf 'unchanged\n'
        return 0
    fi

    # Changed vs running — require the candidate to hold still.
    local p_hash p_seen
    p_hash=$(_version_field "$pending_file" hash 2>/dev/null || true)
    p_seen=$(_version_field "$pending_file" first_seen 2>/dev/null || true)
    if [[ "$p_hash" != "$current" || ! "$p_seen" =~ ^[0-9]+$ ]]; then
        {
            printf 'hash=%s\n' "$current"
            printf 'first_seen=%s\n' "$now"
        } > "$pending_file.tmp" 2>/dev/null && mv "$pending_file.tmp" "$pending_file" 2>/dev/null
        printf 'pending\n'
        return 0
    fi
    if (( now - p_seen >= settle )); then
        printf 'drift\n'
        return 0
    fi
    printf 'pending\n'
    return 0
}

# ---- guards -----------------------------------------------------------------

# _version_cooldown_ok <version_state_dir> <comp> <cooldown_s> <now>
# rc 0 = action allowed; rc 1 = inside the cooldown window.
_version_cooldown_ok() {
    local state_dir="${1:?}" comp="${2:?}" cooldown="${3:-600}" now="${4:-$(date +%s)}"
    local stamp="$state_dir/$comp.restart.last" mt
    [[ -f "$stamp" ]] || return 0
    mt=$(date +%s -r "$stamp" 2>/dev/null || echo 0)
    [[ "$mt" =~ ^[0-9]+$ ]] || mt=0
    (( now - mt >= cooldown ))
}

_version_stamp_cooldown() {
    local state_dir="${1:?}" comp="${2:?}"
    mkdir -p "$state_dir" 2>/dev/null || true
    touch "$state_dir/$comp.restart.last" 2>/dev/null || true
}

# _version_self_guard_ok <version_state_dir> <limit> <window_s> <now>
#
# Watcher self-restart loop guard. rc 0 = a self-restart may proceed.
# rc 1 = guard is (or just became) tripped. On the ok→tripped
# transition an advisory drift-watcher record is written so the emit
# surfaces the suspension. A tripped stamp older than a full window
# re-arms (stamp + history cleared).
_version_self_guard_ok() {
    local state_dir="${1:?}" limit="${2:-3}" window="${3:-3600}" now="${4:-$(date +%s)}"
    local tripped="$state_dir/self-restart-tripped"
    local hist="$state_dir/self-restart-history.txt"
    if [[ -f "$tripped" ]]; then
        local mt
        mt=$(date +%s -r "$tripped" 2>/dev/null || echo 0)
        [[ "$mt" =~ ^[0-9]+$ ]] || mt=0
        if (( now - mt < window )); then
            return 1
        fi
        # Quiet for a full window — re-arm.
        rm -f "$tripped" 2>/dev/null || true
        : > "$hist" 2>/dev/null || true
    fi
    local count=0
    if [[ -f "$hist" ]]; then
        count=$(awk -v cutoff="$(( now - window ))" \
            '$1 ~ /^[0-9]+$/ && $1 >= cutoff {n++} END {print n+0}' "$hist" 2>/dev/null || echo 0)
    fi
    if (( count >= limit )); then
        mkdir -p "$state_dir" 2>/dev/null || true
        touch "$tripped" 2>/dev/null || true
        _version_write_drift_record "$state_dir" watcher "" "guard-tripped-$now" \
            "self-restart guard tripped: $count auto-restarts within ${window}s"
        _version_log "self-restart guard TRIPPED ($count restarts in ${window}s); auto self-restart suspended for ${window}s"
        return 1
    fi
    return 0
}

# ---- actions ----------------------------------------------------------------

# _version_restart_self <version_state_dir> <launcher> <target> <logfile>
#
# The watcher self-restart: append to the loop-guard history, stamp the
# cooldown (BOTH before launching, so neither a racing async fire nor
# the successor can double-trigger), then run `launcher.sh --replace`
# DETACHED (setsid). The launcher SIGTERMs this very process; detaching
# lets it outlive us and complete the fresh headless spawn. The
# successor records its own running version at startup, which is what
# closes the loop (running == disk ⇒ unchanged).
_version_restart_self() {
    local state_dir="${1:?}" launcher="${2:?}" target="${3:-orchestrator}" logfile="${4:-/dev/null}"
    [[ -x "$launcher" ]] || { _version_log "self-restart: launcher not executable: $launcher"; return 1; }
    # `mkdir -p` first: on a HEALTHY fresh install the version dir may simply
    # not exist yet, and the probe below treats a missing dir as unwritable.
    # On a read-only FS this mkdir is the no-op it has always been.
    mkdir -p "$state_dir" 2>/dev/null || true
    # NEVER self-restart onto a read-only project FS. This process holds
    # working fds; a successor must open every path afresh and would die in
    # its own log redirect. Both read-only incidents (2026-06-29, 2026-07-09)
    # open with this self-restart firing and end with no watcher at all.
    # A FRESH probe (never a cached fd) is the gate. launcher.sh refuses the
    # --replace as well; refusing here means we never even fork it.
    if declare -F _nexus_dir_writable >/dev/null 2>&1 \
       && ! _nexus_dir_writable "$state_dir"; then
        _version_log "self-restart SUPPRESSED: project FS is READ-ONLY ($state_dir). Replacing this watcher would kill the only working one — its successor could not open a single file. Staying up; the fs-guard escalates."
        return 1
    fi
    printf '%s\n' "$(date +%s)" >> "$state_dir/self-restart-history.txt" 2>/dev/null || true
    _version_stamp_cooldown "$state_dir" watcher
    # Caller attribution for the launcher's spawn audit log
    # (nexus-code#491): callers may pre-set WATCHER_LAUNCH_CALLER
    # (e.g. the self-heal path passes its reason); default to naming
    # this path so a version-drift restart is attributable too.
    _ensure_service_log "$logfile"
    setsid env WATCHER_LAUNCH_CALLER="${WATCHER_LAUNCH_CALLER:-version-restart-self}" \
        "$launcher" --replace --target "$target" </dev/null >>"$logfile" 2>&1 &
    disown 2>/dev/null || true
    return 0
}

# _version_write_drift_record <version_state_dir> <comp> <old> <new> <note> [window]
#
# Persist an ask record at drift-<comp> (key=value, cc-update style).
# Idempotent per candidate `new` hash: an existing record for the same
# candidate is left untouched (mtime preserved, no churn).
_version_write_drift_record() {
    local state_dir="${1:?}" comp="${2:?}" old="${3:-}" new="${4:?new required}"
    local note="${5:-}" window="${6:-}" window_id="${7:-}"
    local f="$state_dir/drift-$comp"
    if [[ -f "$f" ]]; then
        local existing
        existing=$(_version_field "$f" new 2>/dev/null || true)
        [[ "$existing" == "$new" ]] && return 0
    fi
    mkdir -p "$state_dir" 2>/dev/null || true
    {
        printf 'component=%s\n' "$comp"
        printf 'old=%s\n' "$old"
        printf 'new=%s\n' "$new"
        printf 'note=%s\n' "$note"
        printf 'window=%s\n' "$window"
        printf 'window_id=%s\n' "$window_id"
        printf 'detected=%s\n' "$(date -Is 2>/dev/null || echo unknown)"
    } > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
    return 0
}

# _version_window_exists <name> — tmux window presence probe.
# Overridable in tests by redefining after source.
_version_window_exists() {
    local name="${1:?}"
    command -v tmux >/dev/null 2>&1 || return 1
    tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qxF "$name"
}

# _version_window_id <name> — resolve the named window's immutable
# tmux window ID (@N); empty + rc 1 when absent. The 2026-06-11
# incident root cause: the cockpit-drift advisory's restart recipe
# targeted the cockpit BY NAME, and the orchestrator — one window
# index away from the cockpit — executed a kill that destroyed its
# own window instead. Surfacing the ID makes the recipe typo-proof
# (an ID never matches another window) and dangling-safe (a recipe
# whose window was since recreated fails the kill harmlessly, and
# the && stops the duplicate-cockpit spawn). Overridable in tests.
_version_window_id() {
    local name="${1:?}"
    command -v tmux >/dev/null 2>&1 || return 1
    local id
    id=$(tmux list-windows -F '#{window_id}|#{window_name}' 2>/dev/null \
         | awk -F'|' -v n="$name" '$2==n {print $1; exit}')
    [[ -n "$id" ]] || return 1
    printf '%s' "$id"
}

# ---- emit surfacing -----------------------------------------------------------

# _version_emit_section <version_state_dir> [nexus_root]
#
# Render every UNSURFACED drift-<comp> ask record (and mark each
# surfaced, keyed on the candidate hash — the cc-update re-nag model).
# stdout: the section body (empty when nothing new). rc 0 when
# anything was emitted, 1 otherwise.
_version_emit_section() {
    local state_dir="${1:?state_dir required}" nexus_root="${2:-}"
    local emitted=1 f comp old new note window window_id detected last surfaced_file
    for f in "$state_dir"/drift-*; do
        [[ -f "$f" ]] || continue
        [[ "$f" == *-surfaced ]] && continue
        comp=$(_version_field "$f" component 2>/dev/null || true)
        new=$(_version_field "$f" new 2>/dev/null || true)
        [[ -n "$comp" && -n "$new" ]] || continue
        surfaced_file="$state_dir/drift-$comp-surfaced"
        last=$(cat "$surfaced_file" 2>/dev/null || true)
        [[ "$last" == "$new" ]] && continue
        old=$(_version_field "$f" old 2>/dev/null || true)
        note=$(_version_field "$f" note 2>/dev/null || true)
        window=$(_version_field "$f" window 2>/dev/null || true)
        window_id=$(_version_field "$f" window_id 2>/dev/null || true)
        detected=$(_version_field "$f" detected 2>/dev/null || echo '?')
        case "$comp" in
            cockpit)
                printf 'services cockpit (monitor/svc.sh stack) changed on disk: running %.12s -> %.12s (detected %s).\n' \
                    "${old:-?}" "$new" "$detected"
                printf 'The cockpit TUI in tmux window %s is orchestrator-owned; the watcher will NOT touch it.\n' \
                    "'${window:-services}'"
                printf 'Restart it yourself to load the new code:\n'
                # Kill by immutable window ID when known (2026-06-11
                # incident: a name/index-targeted kill executed by the
                # orchestrator destroyed the orchestrator's own window;
                # an ID can never resolve to another window, and a
                # recipe whose window was since recreated fails the
                # kill harmlessly — the && then stops the spawn).
                printf '  tmux kill-window -t %s && tmux new-window -dn %s %q\n' \
                    "${window_id:-${window:-services}}" "${window:-services}" \
                    "${nexus_root:+$nexus_root/}monitor/svc.sh"
                if [[ -n "$window_id" ]]; then
                    printf '(%s is the window ID of %s, resolved at detection — ID-targeted so a mis-aim cannot hit another window.)\n' \
                        "$window_id" "'${window:-services}'"
                fi
                printf 'Ack/clear: rm %s\n' "$f"
                ;;
            watcher)
                printf 'watcher version drift needs MANUAL action: %s.\n' \
                    "${note:-auto self-restart unavailable}"
                printf 'If the on-disk watcher code is newer than the running instance, restart it:\n'
                printf '  %smonitor/svc.sh restart watcher\n' "${nexus_root:+$nexus_root/}"
                printf 'Ack/clear: rm %s\n' "$f"
                ;;
            service-*)
                printf 'service %s launch script changed on disk: running %.12s -> %.12s (detected %s).\n' \
                    "'${comp#service-}'" "${old:-?}" "$new" "$detected"
                printf '%s\n' "${note:-auto service restart is disabled (monitor.version_restart.services=false)}"
                printf 'Restart it to load the new code:\n'
                printf '  %smonitor/svc.sh restart %s\n' \
                    "${nexus_root:+$nexus_root/}" "${comp#service-}"
                printf 'Ack/clear: rm %s\n' "$f"
                ;;
            *)
                printf 'component %s drifted: %.12s -> %.12s (%s). See %s\n' \
                    "'$comp'" "${old:-?}" "$new" "${note:-}" "$f"
                ;;
        esac
        printf '\n'
        mkdir -p "$state_dir" 2>/dev/null || true
        printf '%s\n' "$new" > "$surfaced_file" 2>/dev/null || true
        emitted=0
    done
    return $emitted
}

# ---- per-cycle orchestration ----------------------------------------------------

# _version_check_tick
#
# The scheduler-task entry point — one drift evaluation across all
# components. Consumes globals (all overridable, so tests can aim it at
# a fixture tree):
#
#   VERSION_STATE_DIR   state dir (required)
#   NEXUS_ROOT          live root (registry + svc.sh resolution)
#   TARGET              orchestrator window (self-restart launcher arg)
#   LOGFILE             watcher log (launcher output lands here)
#   MONITOR_VERSION_SETTLE_SECONDS / _RESTART_COOLDOWN_SECONDS
#   MONITOR_VERSION_SELF_RESTART / _SERVICE_RESTART   true|false
#   MONITOR_VERSION_SELF_LOOP_LIMIT / _SELF_LOOP_WINDOW_SECONDS
#   MONITOR_COCKPIT_WINDOW
#   _VERSION_MAIN_SH      (default <module_dir>/main.sh)
#   _VERSION_MONITOR_DIR  (default <module_dir>/..)
#   _VERSION_LAUNCHER_BIN (default <module_dir>/launcher.sh)
#   _VERSION_SVC_BIN      (default <monitor_dir>/svc.sh)
#
# Runs as an --async scheduler task: every mutation is on-disk, so the
# subshell boundary is safe; the detached launcher survives our death.
_version_check_tick() {
    local state_dir="${VERSION_STATE_DIR:?VERSION_STATE_DIR required}"
    local now settle cooldown
    now=$(date +%s)
    settle="${MONITOR_VERSION_SETTLE_SECONDS:-45}"
    cooldown="${MONITOR_VERSION_RESTART_COOLDOWN_SECONDS:-600}"
    local module_dir="$_VERSION_MODULE_DIR"
    local monitor_dir="${_VERSION_MONITOR_DIR:-$(cd "$module_dir/.." && pwd)}"
    local nexus_root="${NEXUS_ROOT:-$(cd "$monitor_dir/.." && pwd)}"
    local main_sh="${_VERSION_MAIN_SH:-$module_dir/main.sh}"
    local launcher="${_VERSION_LAUNCHER_BIN:-$module_dir/launcher.sh}"
    local svc_bin="${_VERSION_SVC_BIN:-$monitor_dir/svc.sh}"
    local cockpit_win="${MONITOR_COCKPIT_WINDOW:-services}"

    # ---- watcher (self) ----------------------------------------------
    local -a files=()
    local hash verdict
    mapfile -t files < <(_version_watcher_source_set "$main_sh" 2>/dev/null)
    hash=$(_version_hash_files "${files[@]}" 2>/dev/null) || hash=TORN
    verdict=$(_version_check_component "$state_dir" watcher "$hash" "$settle" "$now")
    case "$verdict" in
        drift)
            if ! _version_cooldown_ok "$state_dir" watcher "$cooldown" "$now"; then
                _version_log "watcher drift confirmed but inside cooldown; will retry"
            elif [[ "${MONITOR_VERSION_SELF_RESTART:-true}" != "true" ]]; then
                local old
                old=$(_version_field "$state_dir/watcher.running" hash 2>/dev/null || true)
                _version_write_drift_record "$state_dir" watcher "$old" "$hash" \
                    "auto self-restart disabled (monitor.version_restart.self=false)"
                # Advise once per candidate: adopt the candidate so the
                # record (already persisted) is not re-written each tick.
                _version_record_running "$state_dir" watcher "$hash"
                rm -f "$state_dir/watcher.pending" 2>/dev/null || true
                _version_log "watcher drift -> advisory only (self-restart disabled)"
            elif ! _version_self_guard_ok "$state_dir" \
                    "${MONITOR_VERSION_SELF_LOOP_LIMIT:-3}" \
                    "${MONITOR_VERSION_SELF_LOOP_WINDOW_SECONDS:-3600}" "$now"; then
                _version_log "watcher drift confirmed but self-restart guard is tripped; manual restart required"
            else
                _version_log "watcher source set drifted (stable ${settle}s); self-restarting via launcher --replace"
                _version_restart_self "$state_dir" "$launcher" "${TARGET:-orchestrator}" \
                    "${LOGFILE:-/dev/null}" \
                    || _version_log "self-restart launch FAILED; pending kept, cooldown gates retry"
                # Do NOT touch watcher.running / .pending here: the
                # successor's startup record is the source of truth. If
                # the launcher fails to replace us, the kept pending +
                # cooldown produce a slow retry instead of a tight loop.
            fi
            ;;
        adopted)  _version_log "watcher running-version adopted (pre-feature instance)" ;;
        torn)     _version_log "watcher source set torn/unreadable (pull in progress?); no action" ;;
        pending)  _version_log "watcher source change observed; waiting for ${settle}s stability" ;;
    esac

    # ---- cockpit -----------------------------------------------------
    mapfile -t files < <(_version_cockpit_source_set "$monitor_dir")
    hash=$(_version_hash_files "${files[@]}" 2>/dev/null) || hash=TORN
    verdict=$(_version_check_component "$state_dir" cockpit "$hash" "$settle" "$now")
    case "$verdict" in
        drift)
            if ! _version_cooldown_ok "$state_dir" cockpit "$cooldown" "$now"; then
                _version_log "cockpit drift confirmed but inside cooldown; will retry"
            else
                local old
                old=$(_version_field "$state_dir/cockpit.running" hash 2>/dev/null || true)
                if _version_window_exists "$cockpit_win"; then
                    # Resolve the window's immutable ID so the surfaced
                    # restart recipe can't be mis-aimed (2026-06-11:
                    # a name/index-targeted kill from the orchestrator
                    # destroyed the orchestrator's own window).
                    local cockpit_win_id
                    cockpit_win_id=$(_version_window_id "$cockpit_win" 2>/dev/null) || cockpit_win_id=""
                    _version_write_drift_record "$state_dir" cockpit "$old" "$hash" \
                        "cockpit running old code" "$cockpit_win" "$cockpit_win_id"
                    _version_log "cockpit drifted; asked the orchestrator to restart window '$cockpit_win'${cockpit_win_id:+ ($cockpit_win_id)} (no direct kill)"
                else
                    _version_log "cockpit source drifted but no '$cockpit_win' window is running; re-baselined silently"
                fi
                # Either way the candidate becomes the new baseline: the
                # ask is one-shot per change, and an absent cockpit will
                # run new code whenever it is next launched.
                _version_record_running "$state_dir" cockpit "$hash"
                rm -f "$state_dir/cockpit.pending" 2>/dev/null || true
                _version_stamp_cooldown "$state_dir" cockpit
            fi
            ;;
        torn) _version_log "cockpit source set torn/unreadable; no action" ;;
    esac

    # ---- registered services ------------------------------------------
    local registry="${NEXUS_SERVICES_REGISTRY:-$nexus_root/monitor/services.registry}"
    [[ -f "$registry" ]] || return 0
    # Subshell on purpose: bootstrap-recover.sh sets globals (STATE_DIR,
    # INTERVAL, …) on source; isolating it keeps the watcher's own
    # globals pristine. All version state is on-disk, so nothing needs
    # to escape. RECOVER_INTERVAL pinned to skip its config lookup.
    (
        set -uo pipefail
        export NEXUS_ROOT="$nexus_root"
        RECOVER_INTERVAL="${RECOVER_INTERVAL:-60}"
        # shellcheck source=../bootstrap-recover.sh
        source "$monitor_dir/bootstrap-recover.sh" || exit 0
        local_now="$now"
        while IFS=$'\t' read -r name workdir launch health logfile; do
            [[ -n "$name" ]] || continue
            script=$(_version_service_script "$workdir" "$launch" 2>/dev/null) || continue
            comp="service-$name"
            hash=$(_version_hash_files "$script" 2>/dev/null) || hash=TORN
            if [[ "$hash" == "TORN" ]]; then
                _version_log "$comp launch script unreadable; no action"
                continue
            fi
            # No live supervisor ⇒ nothing runs old code; adopt the
            # current hash so a later recovery-launch comparison starts
            # clean (the launch path re-records anyway).
            if ! _recover_service_running "$name" "$launch"; then
                _version_record_running "$state_dir" "$comp" "$hash"
                rm -f "$state_dir/$comp.pending" 2>/dev/null || true
                continue
            fi
            verdict=$(_version_check_component "$state_dir" "$comp" "$hash" "$settle" "$local_now")
            case "$verdict" in
                drift)
                    if ! _version_cooldown_ok "$state_dir" "$comp" "$cooldown" "$local_now"; then
                        _version_log "$comp drift confirmed but inside cooldown; will retry"
                    elif [[ "${MONITOR_VERSION_SERVICE_RESTART:-true}" != "true" ]]; then
                        old=$(_version_field "$state_dir/$comp.running" hash 2>/dev/null || true)
                        _version_write_drift_record "$state_dir" "$comp" "$old" "$hash" \
                            "auto service restart disabled (monitor.version_restart.services=false)"
                        _version_record_running "$state_dir" "$comp" "$hash"
                        rm -f "$state_dir/$comp.pending" 2>/dev/null || true
                        _version_log "$comp drift -> advisory only (service restart disabled)"
                    else
                        _version_stamp_cooldown "$state_dir" "$comp"
                        _version_log "$comp launch script drifted (stable ${settle}s); svc.sh restart $name"
                        # Close the instance-lock fd IN the svc.sh child so the
                        # long-lived service it (re)spawns can't INHERIT the
                        # flock and hold it past the watcher's death — the
                        # FD-inheritance leak behind the 2026-07-07 outage
                        # (jupyter kept nexus-instance.lock open on a leaked fd,
                        # so --instance-status read live-local and every revive
                        # refused). Mirrors launcher.sh's {_RESTART_LOCK_FD}>&-.
                        # The brace-close MUST be a LITERAL redirect word, so
                        # branch on the fd being held (empty on a WARN-degraded
                        # start, or when this module runs outside the watcher,
                        # e.g. under test — where the plain call is correct).
                        svc_rc=0
                        if [[ -n "${INSTANCE_LOCK_FD:-}" ]]; then
                            NEXUS_ROOT="$nexus_root" NEXUS_SERVICES_REGISTRY="$registry" \
                               "$svc_bin" restart "$name" >/dev/null 2>&1 {INSTANCE_LOCK_FD}>&- || svc_rc=$?
                        else
                            NEXUS_ROOT="$nexus_root" NEXUS_SERVICES_REGISTRY="$registry" \
                               "$svc_bin" restart "$name" >/dev/null 2>&1 || svc_rc=$?
                        fi
                        if (( svc_rc == 0 )); then
                            # The launch path stamped the new running
                            # version; record again defensively in case
                            # an older bootstrap-recover.sh (mid-deploy
                            # skew) didn't.
                            _version_record_running "$state_dir" "$comp" "$hash"
                            rm -f "$state_dir/$comp.pending" 2>/dev/null || true
                            _version_log "$comp restarted on new launch script"
                        else
                            _version_log "$comp restart FAILED (svc.sh rc!=0); pending kept, cooldown gates retry"
                        fi
                    fi
                    ;;
                adopted) _version_log "$comp running-version adopted (pre-feature launch)" ;;
                pending) _version_log "$comp launch-script change observed; waiting for stability" ;;
            esac
        done < <(_recover_parse_registry "$registry")
    )
    return 0
}
