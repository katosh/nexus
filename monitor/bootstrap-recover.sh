#!/usr/bin/env bash
# Idempotent full-stack recovery for the nexus monitor.
#
# Background — the incident this closes (2026-06-07): a machine/tmux
# restart killed the entire nexus stack. Only the orchestrator window
# came back (via the chaperon's `claude --resume`); the watcher and
# every infra service stayed dead, and the orchestrator had to
# re-establish them by hand. The watcher's own death was compounded by
# a stale-PID-file deadlock (see `_watcher_pid_is_live_watcher` in
# `watcher/_lib.sh`); this script closes the *other* half — nothing
# brought the services back on boot.
#
# What it does, idempotently and safe to run anytime. ORDER MATTERS —
# the orchestrator is the supervisor that owns worker continuations, so
# it is brought up BEFORE workers (and pinned to its canonical window
# slot) so a respawned worker can never steal its position and so it
# exists to drive the workers the moment they come back (your-org/
# your-nexus#202):
#   1. Watcher  — if the watcher isn't healthy (per `_watcher_alive`),
#      relaunch it via `watcher/launcher.sh`. With the PID-identity fix
#      a recycled-PID stale lock no longer blocks the relaunch.
#   1b. Orchestrator — bring the orchestrator up FIRST, before any
#      worker respawn (your-org/your-nexus#202). Pre-#202 recovery
#      left the orchestrator to the watcher's absent-target liveness
#      machinery (~4 poll cycles, ~8-10 s AFTER the watcher came up),
#      so a worker respawned by step 3 grabbed the orchestrator's
#      canonical tmux slot (window 2) and the supervisor came up late
#      at a higher index. Now: iff the target window
#      (`monitor.target_window`, default `orchestrator`) is ABSENT,
#      spawn it directly via `watcher/spawn-fresh-orchestrator.sh`,
#      which resolves the session-id pin (valid pin → `--resume <sid>`
#      deterministic resume; missing/stale pin → loud cold spawn — it
#      never deadlocks on a stale pin). Then PIN the window to the
#      canonical index (`monitor.target_window_index`, default 2):
#      already-correct → no-op; slot free → `tmux move-window`; slot
#      held by a DIFFERENT window → leave the orchestrator where it is
#      and log loudly (never clobber). Idempotent: an already-alive
#      orchestrator window is NEVER killed/respawned (only re-pinned) —
#      spawn-fresh-orchestrator kills-then-spawns, so the window-exists
#      guard is what protects a live orchestrator. The watcher's
#      absent-target machinery remains the backstop if this direct
#      spawn fails. Skipped under `--services-only` (the per-turn
#      `bootstrap.sh` refresh — the orchestrator IS the caller there;
#      respawning/repinning it every turn would fight the operator) and
#      under the new `--no-orchestrator`.
#   2. Services — walk a declarative registry (`monitor/services.registry`,
#      one service per line) and relaunch each registered infra service
#      that is unhealthy AND has no live supervisor. Services run HEADLESS
#      (detached via `setsid`, no tmux window) — the supervised-restart
#      wrapper that each registry row launches is the crash-survival
#      mechanism; the window was only ever a host for it. "Live supervisor"
#      is keyed off a per-service pidfile under
#      `$NEXUS_STATE_DIR/services/<name>.pid` (verified alive AND matching
#      the wrapper's cmdline, so a recycled PID after a reboot is not
#      mistaken for a running service). A legacy tmux window of the
#      service's name is still honoured as a second "leave it alone"
#      signal, so a not-yet-migrated windowed service is never
#      double-launched. Healthy / live-supervisor / windowed services are
#      left untouched: never double-launch.
#   3. Workers  — respawn the worker agents that were ACTIVE in the last
#      watcher snapshot (`$STATE_DIR/last-snapshot.txt`, `--- tmux ---`
#      section), via the canonical resume surface
#      `monitor/spawn-worker.sh --resume <window>` (issue #197) — never a
#      hand-rolled `claude --resume`, which loses the env exports every
#      worker hook needs. A snapshot window counts as an active worker
#      iff ALL of:
#        - it is not infra: the orchestrator window
#          (`monitor.target_window`), the cockpit window
#          (`monitor.services_window`), `watcher` (legacy windowed
#          watcher), and any name matching a `services.registry` row
#          (legacy windowed service) are excluded;
#        - the action log (`$STATE_DIR/action-log.jsonl`) has a `spawn`
#          event for it — recovery only owns nexus-spawned workers, so a
#          window with no spawn record (operator shell, externally
#          created) is skipped with a log line;
#        - EITHER its LATEST lifecycle event is that `spawn` (active —
#          abruptly interrupted, never handed off), OR the window is
#          OPERATOR-ENGAGED (your-org/your-nexus#202). A later
#          `wrap-up` (incl. its `window-retain` `reason=wrap-up-*`
#          companion) or `window-close` normally retires a window —
#          the orchestrator's dispatch loop owns continuations of
#          wrapped work, recovery only owns ABRUPT interruptions — BUT
#          a window the OPERATOR is driving must survive a restart even
#          if it wrapped. The operator-engaged signal is the watcher's
#          own authoritative mark (`_openg_marked`, issues #196/#201/
#          #263/#264 in operator-engaged.tsv): a valid hook-driven
#          engagement mark NOT superseded by a newer wrap-up/spawn. So
#          a wrapped-then-re-driven window (operator submitted a prompt
#          after wrapping → mark's `since` > wrap epoch → mark valid)
#          is RESPAWNED; a wrapped-and-abandoned window (no re-engage →
#          wrap epoch > mark `since` → `_openg_marked` false) is still
#          skipped, so genuinely-done work is never resurrected. The
#          precise predicate: respawn iff (NOT infra/registry) AND
#          (lifecycle==active OR operator-engaged). The engaged set is
#          CAPTURED at the very start of recovery — before the watcher
#          relaunch — because the watcher's first idle-probe cycle
#          prunes operator-engaged.tsv rows for windows not yet
#          respawned. A `no-record` window (no spawn event) stays
#          skipped even if it somehow carries a mark: `--resume` can't
#          resolve its session/workdir, so it would only fail loudly.
#      Idle-but-unwrapped workers ARE included: the snapshot carries no
#      busy/idle signal, an idle unwrapped worker may be awaiting
#      follow-ups or mid-task, and resume is cheap + idempotent (the
#      orchestrator's window-cleanup re-closes truly-done ones).
#      Idempotent: a window that already exists live is skipped. Bounded:
#      at most `recover.max_workers` (config, default 12) respawns per
#      run, the excess skipped with a loud notice. A worker whose session
#      or workdir cannot be resolved (spawn-worker exit 11/12) is skipped
#      loudly, never fatal.
#
# The registry is operator-local (gitignored) so each deployment lists
# its own services without forking this script. Format + an annotated
# example live in `monitor/services.registry.example`. A missing
# registry is benign — recovery degrades to watcher-only and says so.
#
# Usage:
#   monitor/bootstrap-recover.sh                 # watcher + orchestrator
#                                                #   + services + workers
#   monitor/bootstrap-recover.sh --services-only # skip watcher AND
#                                                #   orchestrator
#                                                #   (bootstrap.sh's
#                                                #    per-turn refresh — the
#                                                #    orchestrator is the
#                                                #    caller); services +
#                                                #   workers still recover
#   monitor/bootstrap-recover.sh --no-services   # nexus core only:
#                                                #   watcher + orchestrator
#                                                #   (brought up directly,
#                                                #   orchestrator-first);
#                                                #   every registered
#                                                #   service AND every
#                                                #   worker respawn is
#                                                #   skipped
#   monitor/bootstrap-recover.sh --watcher-only  # synonym of
#                                                #   --no-services (still
#                                                #   brings up the
#                                                #   orchestrator — it is
#                                                #   core, not a service)
#   monitor/bootstrap-recover.sh --no-orchestrator # skip ONLY the direct
#                                                #   orchestrator bring-up
#                                                #   (rare: leave it to the
#                                                #   watcher's absent-target
#                                                #   machinery)
#   monitor/bootstrap-recover.sh --no-workers    # skip ONLY the worker
#                                                #   respawn (watcher +
#                                                #   orchestrator + services
#                                                #   still recover)
#   monitor/bootstrap-recover.sh --dry-run       # decide + log, launch
#                                                #   nothing
#   monitor/bootstrap-recover.sh --list          # parse + print the
#                                                #   registry, then exit
#
# Flag matrix (watcher / orchestrator / services / workers):
#   (none)                        ✓ ✓ ✓ ✓
#   --services-only               ✗ ✗ ✓ ✓
#   --no-services|--watcher-only  ✓ ✓ ✗ ✗   (core: watcher+orchestrator)
#   --no-orchestrator             ✓ ✗ ✓ ✓
#   --no-workers                  ✓ ✓ ✓ ✗
#   --services-only --no-workers  ✗ ✗ ✓ ✗
#   --no-services --no-workers    ✓ ✓ ✗ ✗   (redundant, accepted)
#   --services-only --no-services rejected (exit 1) — contradictory;
#                                 together they would recover nothing.
#
# Status lines go to stderr (`[recover] …`); they double as the
# evidence trail when the orchestrator runs this on wake. Exit code is
# 0 unless a flag is malformed — a service that fails to launch is
# logged, not fatal (one wedged service must not abort recovery of the
# rest).
#
# Env overrides (production leaves all unset):
#   NEXUS_ROOT             — repo root (default: script-relative).
#   NEXUS_STATE_DIR        — state dir (default: $NEXUS_ROOT/monitor/.state).
#   NEXUS_SERVICES_REGISTRY— registry path (default:
#                            $NEXUS_ROOT/monitor/services.registry).
#   RECOVER_LAUNCHER_BIN   — watcher launcher (tests stub it).
#   RECOVER_SPAWN_WORKER_BIN — worker resume surface, monitor/
#                            spawn-worker.sh (tests stub it).
#   RECOVER_SPAWN_ORCH_BIN — orchestrator bring-up surface, monitor/
#                            watcher/spawn-fresh-orchestrator.sh (tests
#                            stub it).
#   RECOVER_TARGET_WINDOW  — orchestrator window name (default:
#                            monitor.target_window, `orchestrator`).
#   RECOVER_ORCH_WINDOW_INDEX — canonical tmux index the orchestrator
#                            window is pinned to (default:
#                            monitor.target_window_index, 2).
#   RECOVER_MAX_WORKERS    — worker-respawn sanity cap (default:
#                            recover.max_workers, 12).
#   RECOVER_INTERVAL       — poll interval for the watcher liveness
#                            bucket (default: monitor.interval_seconds).

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Public-template disable switch (defines nexus_public_guard; no side
# effects at source time). The guard itself is called inside
# _recover_main, so sourcing this file as a library stays inert.
# shellcheck source=_public-guard.sh
source "$_script_dir/_public-guard.sh"
_nexus_root_default=$(cd "$_script_dir/.." && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$_nexus_root_default}"
_cfg="$NEXUS_ROOT/config/load.sh"

# Shared liveness helpers (`_watcher_alive`). Side-effect-free; safe to
# source under `set -uo pipefail`.
# shellcheck source=watcher/_lib.sh
source "$_script_dir/watcher/_lib.sh"

# Version-stamp helpers (issue #186). `_recover_launch_service` records
# the launch script's source hash at every launch so the watcher's
# version_check task can detect a later on-disk drift and restart the
# service. Side-effect-free on source.
# shellcheck source=watcher/_version_restart.sh
source "$_script_dir/watcher/_version_restart.sh"

# Operator-engagement predicate (`_openg_marked`) + its action-log
# helpers (your-org/your-nexus#202). The worker-inclusion criteria
# consult the watcher's OWN authoritative engagement mark so recovery
# and the watcher agree on "operator-engaged" — no reimplementation, no
# drift. `_idle_probe.sh` is a pure function library (no top-level
# execution, side-effect-free on source); we use only the `_openg_*` /
# `_idle_window_*` subset. A failed source (e.g. a stripped test tree)
# is non-fatal under `set -uo pipefail` — the engaged-capture then finds
# `_openg_marked` undefined and degrades to the pre-#202 active-only
# predicate.
# shellcheck source=watcher/_idle_probe.sh
source "$_script_dir/watcher/_idle_probe.sh" 2>/dev/null || true

STATE_DIR="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"
SERVICES_REGISTRY="${NEXUS_SERVICES_REGISTRY:-$NEXUS_ROOT/monitor/services.registry}"
LAUNCHER_BIN="${RECOVER_LAUNCHER_BIN:-$_script_dir/watcher/launcher.sh}"
SPAWN_WORKER_BIN="${RECOVER_SPAWN_WORKER_BIN:-$_script_dir/spawn-worker.sh}"
SPAWN_ORCH_BIN="${RECOVER_SPAWN_ORCH_BIN:-$_script_dir/watcher/spawn-fresh-orchestrator.sh}"

if [[ -x "$_cfg" ]]; then
    INTERVAL="${RECOVER_INTERVAL:-$("$_cfg" monitor.interval_seconds 60)}"
    MAX_WORKERS="${RECOVER_MAX_WORKERS:-$("$_cfg" recover.max_workers 12)}"
    TARGET_WINDOW="${RECOVER_TARGET_WINDOW:-$("$_cfg" monitor.target_window orchestrator)}"
    SERVICES_WINDOW="${MONITOR_SERVICES_WINDOW:-$("$_cfg" monitor.services_window services)}"
    ORCH_WINDOW_INDEX="${RECOVER_ORCH_WINDOW_INDEX:-$("$_cfg" monitor.target_window_index 2)}"
else
    INTERVAL="${RECOVER_INTERVAL:-60}"
    MAX_WORKERS="${RECOVER_MAX_WORKERS:-12}"
    TARGET_WINDOW="${RECOVER_TARGET_WINDOW:-orchestrator}"
    SERVICES_WINDOW="${MONITOR_SERVICES_WINDOW:-services}"
    ORCH_WINDOW_INDEX="${RECOVER_ORCH_WINDOW_INDEX:-2}"
fi
[[ "$MAX_WORKERS" =~ ^[0-9]+$ ]] || MAX_WORKERS=12
[[ -n "$TARGET_WINDOW" ]] || TARGET_WINDOW=orchestrator
[[ -n "$SERVICES_WINDOW" ]] || SERVICES_WINDOW=services
[[ "$ORCH_WINDOW_INDEX" =~ ^[0-9]+$ ]] || ORCH_WINDOW_INDEX=2

# Run-mode globals (consumed by the functions below). Defaults here so
# a test that sources this file for its functions sees sane values
# without invoking `_recover_main`. Flags override them in main.
DO_WATCHER=1
DO_ORCHESTRATOR=1
DO_SERVICES=1
DO_WORKERS=1
DRY_RUN=0
LIST_ONLY=0

# Operator-engaged windows captured at the very START of recovery
# (before the watcher relaunch, whose first idle-probe cycle prunes
# operator-engaged.tsv rows for windows not yet respawned). Space-
# padded for membership tests, mirroring `registry_names`. Default
# empty so sourcing this file for its functions (tests) is side-
# effect-free.
ENGAGED_WINDOWS=" "

log() { echo "[recover] $*" >&2; }

# --- registry parsing -----------------------------------------------------
#
# Emit one validated `name<TAB>workdir<TAB>launch<TAB>health<TAB>logfile`
# record per stdout line. Skips blank lines and `#` comments. A line
# without at least four TAB-separated fields is skipped with a warning
# rather than aborting the run — a single malformed entry must not
# strand the rest of the stack. `~` and `$NEXUS_ROOT` are expanded in
# both `$workdir` and `$logfile` so the registry can stay path-portable.
#
# The 5th field (`<logfile>`) is OPTIONAL and, when present, is where a
# HEADLESS launch appends stdout/stderr (and what the read-only cockpit
# `monitor/svc.sh` tails). It is captured into its OWN field — never
# folded into `$health` — so the healthcheck string stays clean even on
# a 5-field row. 4-field rows leave `$logfile` empty; the launcher then
# falls back to `<workdir>/serve.log`.
_recover_parse_registry() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    # `policy` is the OPTIONAL 6th column consumed only by the watcher's
    # service-health task (monitor/watcher/_service_health.sh). bootstrap-
    # recover does not use it, but it MUST read it into its own variable so
    # a present 6th field can't bleed into `logfile` (read assigns the
    # trailing remainder — delimiters and all — to the last variable). This
    # keeps every registry parser lock-step.
    local line name workdir launch health logfile policy
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip a leading comment / blank.
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        IFS=$'\t' read -r name workdir launch health logfile policy <<<"$line"
        if [[ -z "$name" || -z "$workdir" || -z "$launch" || -z "$health" ]]; then
            log "registry: skipping malformed line (need 4 TAB fields): $line"
            continue
        fi
        # Expand ~ and $NEXUS_ROOT in workdir + logfile for portability.
        workdir="${workdir/#\~/$HOME}"
        workdir="${workdir//\$NEXUS_ROOT/$NEXUS_ROOT}"
        logfile="${logfile/#\~/$HOME}"
        logfile="${logfile//\$NEXUS_ROOT/$NEXUS_ROOT}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$workdir" "$launch" "$health" "$logfile"
    done < "$file"
}

# --- per-service primitives ----------------------------------------------

# Run a healthcheck command in the service's workdir. Exit 0 = healthy.
# The healthcheck is arbitrary shell (curl, pgrep, test -f …); we run it
# under `bash -c` so the registry author writes it naturally.
_recover_service_healthy() {
    local workdir="$1" health="$2"
    ( cd "$workdir" 2>/dev/null && bash -c "$health" ) >/dev/null 2>&1
}

_recover_window_exists() {
    local name="$1"
    command -v tmux >/dev/null 2>&1 || return 1
    tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qxF "$name"
}

# Path of a service's headless-supervisor pidfile.
_recover_pidfile() { printf '%s/services/%s.pid' "$STATE_DIR" "$1"; }

# Is the service's headless supervisor still alive? True iff the pidfile
# names a live PID whose cmdline still mentions the launch wrapper. The
# cmdline guard mirrors `_watcher_pid_is_live_watcher` (the 2026-06-07
# stale-lock lesson): after a reboot a recycled PID could otherwise be
# mistaken for a running supervisor, wedging a dead service permanently
# "leave it alone". If /proc is unreadable we fall back to the liveness
# check alone. The pidfile is per-service-name, which is what lets two
# services that share a wrapper script (e.g. `serve-supervised.sh`) be
# told apart — a bare `pgrep` on the wrapper could not.
_recover_service_running() {
    local name="$1" launch="$2"
    local pf; pf=$(_recover_pidfile "$name")
    [[ -f "$pf" ]] || return 1
    local pid; read -r pid < "$pf" 2>/dev/null
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    local cmdline_file="/proc/$pid/cmdline"
    if [[ -r "$cmdline_file" ]]; then
        local cmdline tok
        cmdline=$(tr '\0' ' ' < "$cmdline_file" 2>/dev/null)
        tok=${launch%% *}     # first token of the launch cmd
        tok=${tok##*/}        # → its basename, e.g. serve-supervised.sh
        [[ -n "$tok" && "$cmdline" == *"$tok"* ]] || return 1
    fi
    return 0
}

# Launch a service HEADLESS — detached, no tmux window. `setsid` puts the
# supervisor in its own session (no controlling tty) so it outlives this
# recovery process; stdin is /dev/null and stdout/stderr append to the
# service logfile (the registry's 5th field, else <workdir>/serve.log).
# The inner shell records its OWN pid into the pidfile and then `exec`s
# the wrapper, so the recorded PID is the wrapper's regardless of whether
# setsid forks or execs. Returns nonzero if setsid is unavailable.
_recover_launch_service() {
    local name="$1" workdir="$2" launch="$3" logfile="$4"
    command -v setsid >/dev/null 2>&1 || { log "setsid unavailable; cannot launch $name headless"; return 1; }
    local svcdir="$STATE_DIR/services"
    mkdir -p "$svcdir" 2>/dev/null || true
    local pf lf inner
    pf=$(_recover_pidfile "$name")
    lf="${logfile:-$workdir/serve.log}"
    printf -v inner 'echo $$ > %q; cd %q && exec %s' "$pf" "$workdir" "$launch"
    setsid bash -c "$inner" </dev/null >>"$lf" 2>&1 &
    # Stamp the launch script's source hash as this service's running
    # version (issue #186) — the comparison anchor for the watcher's
    # version_check drift detection. Best-effort: a service whose
    # launch command has no trackable script file simply isn't
    # version-managed.
    _version_record_service_running "$STATE_DIR/version" "$name" "$workdir" "$launch" \
        2>/dev/null || true
    return 0
}

# Decide + act for one service. Idempotent: relaunch ONLY when the
# service is unhealthy AND no live supervisor (pidfile) AND no legacy
# tmux window bears its name. A live supervisor or a present window
# (even if the healthcheck is briefly failing) is left to its own
# supervised-restart loop — relaunching it would orphan a duplicate.
# Prints a one-word outcome (healthy | supervisor-alive | window-present
# | workdir-missing | relaunched | launch-failed | dry-run-would-launch)
# for the caller's tally.
recover_service() {
    local name="$1" workdir="$2" launch="$3" health="$4" logfile="${5:-}"
    if _recover_service_healthy "$workdir" "$health"; then
        log "service '$name': healthy"
        echo healthy; return 0
    fi
    if _recover_service_running "$name" "$launch"; then
        log "service '$name': unhealthy but supervisor pid alive — leaving to it"
        echo supervisor-alive; return 0
    fi
    # Legacy: a tmux window of this name still hosts a not-yet-migrated
    # service. Honour it as a second leave-it-alone signal so the lazy
    # window→headless migration never double-launches.
    if _recover_window_exists "$name"; then
        log "service '$name': unhealthy but window present — leaving to its supervisor"
        echo window-present; return 0
    fi
    if [[ ! -d "$workdir" ]]; then
        log "service '$name': workdir missing ($workdir) — skipping"
        echo workdir-missing; return 0
    fi
    if (( DRY_RUN == 1 )); then
        log "service '$name': would relaunch headless (cwd=$workdir): $launch"
        echo dry-run-would-launch; return 0
    fi
    if _recover_launch_service "$name" "$workdir" "$launch" "$logfile"; then
        log "service '$name': relaunched headless (pidfile $(_recover_pidfile "$name"))"
        echo relaunched; return 0
    fi
    log "service '$name': launch FAILED"
    echo launch-failed; return 0
}

# --- watcher recovery -----------------------------------------------------

recover_watcher() {
    _watcher_alive "$STATE_DIR" "$INTERVAL"
    local rc=$?
    if (( rc == 0 )); then
        log "watcher: healthy"
        return 0
    fi
    local reason
    reason=$(_watcher_reason "$STATE_DIR" 2>/dev/null || echo "not healthy (bucket=$rc)")
    log "watcher: $reason — relaunching"
    if (( DRY_RUN == 1 )); then
        log "watcher: would run $LAUNCHER_BIN"
        return 0
    fi
    if "$LAUNCHER_BIN" >&2; then
        log "watcher: launcher exited OK"
    else
        log "watcher: launcher exited nonzero (rc=$?)"
    fi
}

# --- orchestrator recovery --------------------------------------------------
#
# Bring the orchestrator up FIRST — before workers — and pin it to its
# canonical window slot (your-org/your-nexus#202). The orchestrator is
# the supervisor that owns worker continuations, so it must exist before
# step 3 respawns workers; pinning its window guarantees a worker can't
# steal its slot.

# Pin the orchestrator window to the canonical tmux index. Safe + non-
# destructive:
#   - already at the index               → no-op
#   - index free                          → `tmux move-window`
#   - index held by a DIFFERENT window    → leave the orchestrator put,
#                                           log loudly (NEVER clobber)
# `move-window -d` so we don't yank the active-window selection. tmux
# absent or window gone → silent no-op.
_recover_pin_orchestrator_window() {
    local target="$1"
    command -v tmux >/dev/null 2>&1 || return 0
    [[ "$ORCH_WINDOW_INDEX" =~ ^[0-9]+$ ]] || return 0
    _recover_window_exists "$target" || return 0
    # Resolve the target window's current session + index.
    local line sess cur _name
    line=$(tmux list-windows -a -F '#{session_name}'$'\t''#{window_index}'$'\t''#{window_name}' 2>/dev/null \
           | awk -F'\t' -v w="$target" '$3 == w { print; exit }')
    [[ -n "$line" ]] || return 0
    IFS=$'\t' read -r sess cur _name <<<"$line"
    if [[ "$cur" == "$ORCH_WINDOW_INDEX" ]]; then
        log "orchestrator: already at canonical window index $ORCH_WINDOW_INDEX"
        return 0
    fi
    # Refuse to clobber a different window occupying the slot.
    local occupant
    occupant=$(tmux list-windows -t "$sess" -F '#{window_index}'$'\t''#{window_name}' 2>/dev/null \
               | awk -F'\t' -v i="$ORCH_WINDOW_INDEX" '$1 == i { print $2; exit }')
    if [[ -n "$occupant" && "$occupant" != "$target" ]]; then
        log "orchestrator: canonical index $ORCH_WINDOW_INDEX held by '$occupant' — NOT moving (orchestrator stays at $cur); free the slot to re-pin"
        return 0
    fi
    if tmux move-window -d -s "$sess:$cur" -t "$sess:$ORCH_WINDOW_INDEX" 2>/dev/null; then
        log "orchestrator: pinned to canonical window index $ORCH_WINDOW_INDEX (was $cur)"
    else
        log "orchestrator: move-window to index $ORCH_WINDOW_INDEX failed — left at $cur"
    fi
}

# Decide + act for the orchestrator. Idempotent: an already-alive
# orchestrator window is NEVER killed/respawned (spawn-fresh-
# orchestrator.sh kills-then-spawns, so the window-exists guard is what
# protects a live orchestrator from a destructive recovery) — it is only
# re-pinned. An absent window is spawned directly; spawn-fresh-
# orchestrator resolves the session-id pin (valid → deterministic
# `--resume`; missing/stale → loud cold spawn, never a deadlock). On
# spawn failure the watcher's absent-target machinery is the backstop, so
# a failure is logged, never fatal.
recover_orchestrator() {
    local target="$TARGET_WINDOW"
    if _recover_window_exists "$target"; then
        log "orchestrator: window '$target' already alive — not respawning (idempotent)"
        _recover_pin_orchestrator_window "$target"
        return 0
    fi
    if (( DRY_RUN == 1 )); then
        log "orchestrator: window '$target' absent — would spawn FIRST via $SPAWN_ORCH_BIN, then pin to index $ORCH_WINDOW_INDEX"
        return 0
    fi
    log "orchestrator: window '$target' absent — spawning FIRST (before workers) via $SPAWN_ORCH_BIN"
    if "$SPAWN_ORCH_BIN" --target "$target" --reason "full-stack recovery (orchestrator-first, your-org/your-nexus#202)" >&2; then
        log "orchestrator: spawned"
    else
        log "orchestrator: spawn-fresh-orchestrator exited nonzero (rc=$?) — the watcher's absent-target machinery remains the backstop"
    fi
    _recover_pin_orchestrator_window "$target"
    return 0
}

# --- worker recovery --------------------------------------------------------
#
# Respawn the worker agents that were active in the last watcher
# snapshot, via the canonical resume surface (spawn-worker.sh --resume,
# issue #197). Inclusion criteria + the flag matrix are documented in
# the header; the functions below implement them piecewise so each is
# testable on its own.

# Capture the OPERATOR-ENGAGED window set into ENGAGED_WINDOWS, ONCE, at
# the very start of recovery (your-org/your-nexus#202). Read here and
# not lazily per-window because the watcher's first idle-probe cycle
# prunes operator-engaged.tsv rows for windows that aren't currently in
# tmux — at a cold restart that is every not-yet-respawned worker. We
# must read the marks BEFORE recover_watcher relaunches the watcher.
#
# A window counts as engaged iff the watcher's OWN authoritative
# predicate `_openg_marked` says so (valid hook-driven mark not
# superseded by a newer wrap-up/spawn) — single source of truth with the
# watcher's idle probe. If `_openg_marked` is unavailable (the
# `_idle_probe.sh` source failed in a stripped tree) the set stays empty
# and the predicate degrades to active-only — the pre-#202 behaviour.
_recover_capture_engaged_windows() {
    ENGAGED_WINDOWS=" "
    declare -F _openg_marked >/dev/null 2>&1 || return 0
    local path name _rest
    path=$(_openg_path 2>/dev/null) || return 0
    [[ -n "$path" && -f "$path" ]] || return 0
    while IFS=$'\t' read -r name _rest; do
        [[ -n "$name" ]] || continue
        if _openg_marked "$name"; then
            ENGAGED_WINDOWS+="$name "
        fi
    done < "$path"
}

# Membership test against the captured engaged set.
_recover_window_operator_engaged() {
    [[ "$ENGAGED_WINDOWS" == *" $1 "* ]]
}

# Window names from the snapshot's `--- tmux ---` section, ` bell=N`
# suffix stripped. Defensive `^•` filter mirrors snapshot_local's
# dead-pane-artifact guard. Missing/empty snapshot emits nothing.
_recover_snapshot_tmux_windows() {
    local snap="$1"
    [[ -f "$snap" ]] || return 0
    awk '/^--- tmux ---$/ { in_tmux = 1; next }
         /^--- /          { in_tmux = 0 }
         in_tmux && $1 !~ /^•/ && NF { print $1 }' "$snap" | sort -u
}

# Lifecycle state of one window per the action log. Prints exactly one
# word:
#   active     — latest lifecycle event is `spawn`
#   retired    — latest is `wrap-up` / `window-close` / the wrap-up
#                companion `window-retain` with reason=wrap-up-* (the
#                companion matters because an orchestrator-side
#                `ng wrap-up` may lack the `window=` extra on the
#                wrap-up event itself)
#   no-record  — no `spawn` event for this window (not nexus-spawned;
#                recovery does not own it), or no action log at all
_recover_worker_lifecycle_state() {
    local name="$1" log="$2"
    [[ -f "$log" ]] || { echo no-record; return 0; }
    local last
    last=$(grep -F "\"window\":\"$name\"" "$log" 2>/dev/null \
        | grep -E '"event":"(spawn|wrap-up|window-close)"|"event":"window-retain".*"reason":"wrap-up-' \
        | tail -n 1)
    if [[ -z "$last" ]]; then
        echo no-record
    elif [[ "$last" == *'"event":"spawn"'* ]]; then
        echo active
    else
        echo retired
    fi
}

# Emit the snapshot windows that qualify for respawn, one name per
# line. Non-qualifying windows are logged with the exclusion reason —
# the loud-on-skip evidence trail.
_recover_snapshot_workers() {
    local snap="$STATE_DIR/last-snapshot.txt"
    local actionlog="$STATE_DIR/action-log.jsonl"
    if [[ ! -f "$snap" ]]; then
        log "workers: no snapshot at $snap — nothing to respawn"
        return 0
    fi
    # Registry service names (legacy windowed services keep their
    # window name): one exclusion set alongside the fixed infra names.
    local registry_names=" "
    local rn _rest
    while IFS=$'\t' read -r rn _rest; do
        [[ -n "$rn" ]] && registry_names+="$rn "
    done < <(_recover_parse_registry "$SERVICES_REGISTRY")
    local name state
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        # Infra windows are not workers: the orchestrator ($TARGET_WINDOW)
        # and the cockpit ($SERVICES_WINDOW) are config-resolved so a
        # renamed window is still excluded (your-nexus#204); `watcher` is
        # the fixed legacy windowed-watcher name.
        if [[ "$name" == "$TARGET_WINDOW" || "$name" == "$SERVICES_WINDOW" || "$name" == "watcher" ]]; then
            log "worker '$name': infra window — not a worker, skipping"
            continue
        fi
        if [[ "$registry_names" == *" $name "* ]]; then
            log "worker '$name': registered service window — not a worker, skipping"
            continue
        fi
        state=$(_recover_worker_lifecycle_state "$name" "$actionlog")
        case "$state" in
            active)
                printf '%s\n' "$name" ;;
            retired)
                # Wrapped/closed normally retires a window — BUT a
                # window the OPERATOR is driving must survive a restart
                # even if it wrapped (your-org/your-nexus#202). The
                # engaged set was captured before the watcher relaunch.
                if _recover_window_operator_engaged "$name"; then
                    log "worker '$name': wrapped/closed BUT operator-engaged — continuing the operator's interactive session"
                    printf '%s\n' "$name"
                else
                    log "worker '$name': already wrapped/closed per action log — skipping"
                fi ;;
            no-record)
                # No spawn event → `--resume` can't resolve session/
                # workdir; skip even if a stray mark exists.
                log "worker '$name': no spawn record in action log — not nexus-spawned, skipping" ;;
        esac
    done < <(_recover_snapshot_tmux_windows "$snap")
}

# Decide + act for one qualifying worker. Idempotent: a window that is
# already alive is never double-spawned. Prints a one-word outcome
# (already-alive | dry-run-would-resume | resumed | session-unresolvable
# | workdir-unresolvable | resume-failed) for the caller's tally.
recover_worker() {
    local name="$1"
    if _recover_window_exists "$name"; then
        log "worker '$name': window already alive — skipping"
        echo already-alive; return 0
    fi
    if (( DRY_RUN == 1 )); then
        # `would resume` is a stable marker boot-recover.sh's health
        # gate greps for — keep it verbatim.
        log "worker '$name': would resume via $SPAWN_WORKER_BIN --resume"
        echo dry-run-would-resume; return 0
    fi
    "$SPAWN_WORKER_BIN" --resume "$name" >&2
    local rc=$?
    case "$rc" in
        0)  log "worker '$name': resumed"
            echo resumed ;;
        11) log "worker '$name': SKIPPED — session-id unresolvable (spawn-worker exit 11); resume by hand via spawn-worker.sh --resume <session-id> -n $name"
            echo session-unresolvable ;;
        12) log "worker '$name': SKIPPED — workdir unresolvable (spawn-worker exit 12)"
            echo workdir-unresolvable ;;
        13) log "worker '$name': window came alive concurrently (spawn-worker exit 13) — leaving it"
            echo already-alive ;;
        *)  log "worker '$name': resume FAILED (spawn-worker exit $rc)"
            echo resume-failed ;;
    esac
    return 0
}

# Walk every qualifying worker, bounded by MAX_WORKERS. One wedged
# resume is logged, never fatal — recovery of the rest must proceed.
recover_workers() {
    local -a candidates=()
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] && candidates+=("$name")
    done < <(_recover_snapshot_workers)
    if (( ${#candidates[@]} == 0 )); then
        log "workers: none to respawn"
        return 0
    fi
    local n_resumed=0 n_alive=0 n_skipped=0 n_capped=0 n_done=0 outcome
    for name in "${candidates[@]}"; do
        if (( n_done >= MAX_WORKERS )); then
            log "worker '$name': NOT respawned — sanity cap recover.max_workers=$MAX_WORKERS reached"
            n_capped=$(( n_capped + 1 ))
            continue
        fi
        n_done=$(( n_done + 1 ))
        outcome=$(recover_worker "$name")
        case "$outcome" in
            resumed|dry-run-would-resume) n_resumed=$(( n_resumed + 1 )) ;;
            already-alive)                n_alive=$(( n_alive + 1 )) ;;
            *)                            n_skipped=$(( n_skipped + 1 )) ;;
        esac
    done
    log "workers: ${#candidates[@]} candidate(s) — $n_resumed resumed, $n_alive already alive, $n_skipped skipped, $n_capped over cap"
    return 0
}

# --- main -----------------------------------------------------------------

_recover_main() {
    # Public-template disable switch: this is the deep chokepoint every
    # bring-up route funnels through (entry.sh -> svc.sh up -> here,
    # boot-recover, watcher-supervise-tick, remote-up). Refuse unless
    # NEXUS_PUBLIC_ENABLED=1. See monitor/_public-guard.sh.
    nexus_public_guard
    while (( $# > 0 )); do
        case "$1" in
            # Per-turn refresh from bootstrap.sh: the watcher is already
            # handled AND the orchestrator IS the caller — respawning /
            # repinning it every turn would fight the operator, so skip
            # both. Services + workers still recover.
            --services-only) DO_WATCHER=0; DO_ORCHESTRATOR=0; shift ;;
            # Core-only: the deliberately-minimal stack is watcher +
            # orchestrator (brought up directly, orchestrator-first), so
            # skipping services also skips worker respawn but KEEPS the
            # orchestrator — it is core, not a service (see the flag
            # matrix in the header).
            --no-services|--watcher-only) DO_SERVICES=0; DO_WORKERS=0; shift ;;
            --no-orchestrator) DO_ORCHESTRATOR=0; shift ;;
            --no-workers)    DO_WORKERS=0; shift ;;
            --dry-run)       DRY_RUN=1; shift ;;
            --list)          LIST_ONLY=1; shift ;;
            -h|--help)       sed -n '2,187p' "$0"; return 0 ;;
            *) echo "bootstrap-recover.sh: unknown flag: $1" >&2; return 1 ;;
        esac
    done

    if (( DO_WATCHER == 0 && DO_SERVICES == 0 )); then
        echo "bootstrap-recover.sh: --services-only combined with --no-services/--watcher-only recovers nothing — pick one" >&2
        return 1
    fi

    if (( LIST_ONLY == 1 )); then
        if [[ -f "$SERVICES_REGISTRY" ]]; then
            _recover_parse_registry "$SERVICES_REGISTRY"
        else
            log "no registry at $SERVICES_REGISTRY"
        fi
        return 0
    fi

    # Single-nexus-instance gate. This recovery path spawns the orchestrator +
    # services (and, unless --no-workers, workers) — a second co-located
    # cockpit invoking it (boot-recover SessionStart hook, a manual `svc.sh
    # up`) must NOT bring up a parallel stack racing the live instance's
    # shared state. The guard's self-exemption (same host + pid namespace)
    # lets our OWN within-instance recovery proceed even while our watcher
    # holds the flock; a DIFFERENT cockpit (co-located sandbox or another
    # host, via the cross-host heartbeat) refuses. Skipped under --dry-run:
    # boot-recover.sh runs `--dry-run` purely as a health probe and must not
    # be blocked from assessing state.
    if (( DRY_RUN == 0 )); then
        if ! _nexus_instance_preflight "$STATE_DIR" "$NEXUS_ROOT"; then
            log "REFUSING recovery — another nexus instance owns this NEXUS_ROOT (see refusal above)."
            return 3
        fi
    fi

    # Capture the operator-engaged marks BEFORE relaunching the watcher
    # (whose first idle-probe cycle prunes operator-engaged.tsv rows for
    # not-yet-respawned windows). Only needed for the worker step.
    if (( DO_WORKERS == 1 )); then
        _recover_capture_engaged_windows
        [[ "$ENGAGED_WINDOWS" != " " ]] && \
            log "workers: operator-engaged windows captured:${ENGAGED_WINDOWS%" "}"
    fi

    if (( DO_WATCHER == 1 )); then
        recover_watcher
        # Watcher-supervision is mutual-liveness: the ORCHESTRATOR arms the
        # supervisor Monitor (it comes up just below / at SessionStart),
        # and the watcher's `--- arm watcher supervisor ---` emit reminder
        # nudges it if unarmed. Nothing to launch here.
    fi

    # Orchestrator FIRST — before services and workers (the supervisor
    # must exist to own worker continuations, and pinning its window
    # keeps a respawned worker from stealing its slot).
    if (( DO_ORCHESTRATOR == 0 )); then
        log "orchestrator: skipped (--no-orchestrator / --services-only)"
    else
        recover_orchestrator
    fi

    if (( DO_SERVICES == 0 )); then
        log "services: skipped (--no-services / --watcher-only — nexus core only)"
    else
        if [[ ! -f "$SERVICES_REGISTRY" ]]; then
            log "no service registry at $SERVICES_REGISTRY — watcher-only recovery"
            log "  (copy monitor/services.registry.example to enable service recovery)"
        else
            local n_total=0 n_healthy=0 n_relaunched=0 n_skipped=0
            local name workdir launch health logfile outcome
            while IFS=$'\t' read -r name workdir launch health logfile; do
                [[ -n "$name" ]] || continue
                n_total=$(( n_total + 1 ))
                outcome=$(recover_service "$name" "$workdir" "$launch" "$health" "$logfile")
                case "$outcome" in
                    healthy)    n_healthy=$(( n_healthy + 1 )) ;;
                    relaunched) n_relaunched=$(( n_relaunched + 1 )) ;;
                    *)          n_skipped=$(( n_skipped + 1 )) ;;
                esac
            done < <(_recover_parse_registry "$SERVICES_REGISTRY")
            log "services: $n_total registered — $n_healthy healthy, $n_relaunched relaunched, $n_skipped left/skipped"
        fi
    fi

    if (( DO_WORKERS == 0 )); then
        log "workers: skipped (--no-workers / core-only)"
    else
        recover_workers
    fi
    return 0
}

# Run main only when executed directly — sourcing (e.g. from the test
# suite) gets the functions without side effects.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _recover_main "$@"
    exit $?
fi
