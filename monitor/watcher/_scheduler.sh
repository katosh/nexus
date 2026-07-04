#!/usr/bin/env bash
# Nexus monitor — scheduler (single-loop priority queue).
#
# Per-task priority queue driven from in-memory associative arrays.
# Source loads define the registry + helpers; `main.sh` registers
# tasks and drives the loop.
#
# Design doc: docs/watcher-scheduling-refactor.md §5 (data
# structures, helper API, main-loop pseudocode).
#
# Implementation notes:
#
#   - Bash >=4 associative arrays. The watcher already requires bash
#     5 (see `_lib.sh` patterns like `mapfile` / `local -n`).
#   - No subshells, no FIFOs, no inotify — every task runs serial in
#     the watcher process.
#   - `nexus_clock` is the only wall-clock access; tests inject time
#     via `NEXUS_TEST_NOW`.
#   - Sleep is backgrounded + waited so SIGTERM is observed within
#     `MONITOR_SCHEDULER_MAX_SLEEP` seconds (default 10) regardless
#     of which task is next due.
#   - Back-pressure: a task returning rc=75 (EX_TEMPFAIL) gets its
#     next interval doubled, capped at 4× base. A task can also
#     defer itself via `_schedule_skip_until <name> <epoch>`.
#   - Adaptive cadence: `_schedule_override <name> <new_int> <dur>`
#     applies a shorter/longer interval for `dur` seconds. Aliased
#     as `_reschedule` per the bake-off brief.
#   - Force-fire: `_schedule_fire_now <name>` zeros `next_fire` for
#     the next tick. Used by tests and operator introspection.
#   - Hang watchdog: an async run still in flight past
#     max(4 × interval, MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR) gets
#     its child tree killed and the task re-armed (rc=124,
#     phase="async-timeout" telemetry row). See
#     `_scheduler_check_async_timeout`.

# ---- double-source guard ------------------------------------------------
if [[ -n "${_NEXUS_SCHEDULER_LOADED:-}" ]]; then
    return 0
fi
_NEXUS_SCHEDULER_LOADED=1
# Legacy guard so tests written against the Phase-0 scaffold's
# `_NEXUS_SCHEDULER_SCAFFOLD_LOADED` sentinel can still detect a
# successful source. Both names refer to the same module.
_NEXUS_SCHEDULER_SCAFFOLD_LOADED=1

# ---- task registry ------------------------------------------------------
declare -gA TASK_FN            # name → function symbol
declare -gA TASK_INTERVAL      # name → base interval (seconds)
declare -gA TASK_NEXT_FIRE     # name → epoch of next scheduled fire
declare -gA TASK_LAST_FIRE     # name → epoch of last fire (telemetry)
declare -gA TASK_LAST_RC       # name → last exit code
declare -gA TASK_LAST_ELAPSED  # name → last wall-clock duration (ms)
declare -gA TASK_CLASS         # name → cheap|medium|expensive
declare -gA TASK_OVERRIDE_TIL  # name → epoch override expiry
declare -gA TASK_OVERRIDE_INT  # name → override interval while active
declare -gA TASK_ENABLED       # name → 1 (active) | 0 (suspended)
# --- async-fire state (ported from Impl-B) -------------------------------
# Tasks tagged `--async` run their helper in a backgrounded subshell so
# a multi-second helper does not block the next tick. Re-fires while a
# prior run is in flight are suppressed by the `BG_PID != 0` guard.
# Done-detection is sidecar-file driven (no `/proc/<pid>/status` parse,
# no blocking `wait`): the subshell writes its rc to `<stage>/<name>.rc`
# immediately before exiting; the next tick's reap step uses the rc
# file's presence as the signal "child is done" and `wait`s to harvest
# the (briefly) zombie process.
declare -gA TASK_ASYNC         # name → 1 (async) | 0 (sync, default)
declare -gA TASK_BG_PID        # name → pid of in-flight async run; 0 = none
declare -gA TASK_BG_STARTED    # name → epoch the async run launched (ms-precision unavailable)

# Names that fired during the most recent `_scheduler_tick` call.
# Reset at the top of every tick. Read by callers (and tests) that
# want to observe which tasks ran.
declare -ga _SCHEDULER_FIRED_THIS_TICK=()

# Cooperative-shutdown flag toggled by SIGTERM/SIGINT.
_scheduler_shutdown_requested=0

# Hard cap on a single `_scheduler_sleep_until_next` invocation. Used
# to bound signal-observation latency even when no task is due for
# minutes. Operator-tunable via env / config (`main.sh` resolves the
# config-keyed default).
: "${MONITOR_SCHEDULER_MAX_SLEEP:=10}"

# Async-task hang watchdog floor (your-org/your-nexus#180 R4).
# `_scheduler_fire_async` records TASK_BG_STARTED but, before the
# watchdog, nothing ever consulted it: a hung helper (a `gh api` call
# on a black-holed connection has no client-side timeout) left
# TASK_BG_PID non-zero forever, and the in-flight guard then skipped
# every future fire of that task for the watcher's lifetime —
# silently. That is the exact "eligible comments stop surfacing, no
# log error" incident class.
#
# Per-task budget = max(4 × interval, this floor). The interval
# multiple keeps slow-cadence tasks (github_poll @600 s) from being
# killed mid-legitimate-slow-fetch; the floor keeps fast-cadence
# tasks (deliveries_poll @15 s) from being declared hung after a
# minute of ordinary slowness. 0 disables the watchdog entirely.
# On breach: the child's process tree is killed (PID-scoped pkill -P
# + kill), state resets so the task re-arms on its next due tick, a
# telemetry row with phase="async-timeout" and rc=124 is written,
# and a WARN goes to the watcher log. main.sh resolves the
# config-keyed default (monitor.scheduler.async_timeout_floor_seconds).
: "${MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR:=300}"

# Optional telemetry JSONL path. When set, every fire writes a row.
# `main.sh` typically points this at
# `monitor/.state/watcher-scheduler.jsonl`.
: "${MONITOR_SCHEDULER_LOG:=}"

# ---- nexus_clock --------------------------------------------------------
# Clock indirection. Tests set `NEXUS_TEST_NOW` to a fixed epoch and
# advance it between `_scheduler_tick` calls to simulate elapsed time
# without burning real wall-clock seconds.
nexus_clock() {
    if [[ -n "${NEXUS_TEST_NOW:-}" ]]; then
        printf '%s\n' "$NEXUS_TEST_NOW"
    else
        date +%s
    fi
}

# ---- task registration --------------------------------------------------
# _schedule_task <name> <interval_seconds> <fn> [--class C] [--disabled]
#
# Registers (or overwrites) a task. Idempotent: re-registering with
# the same name updates `interval`/`fn`/`class` and preserves any
# in-flight `next_fire` so a reload doesn't reset cadence.
#
# A fresh registration sets `next_fire` to 0 — the first call to
# `_scheduler_tick` fires the task immediately. This matches the
# watcher's existing startup-sweep semantics (every check runs once
# before the steady-state cadence kicks in).
_schedule_task() {
    local name="$1" interval="$2" fn="$3"
    shift 3
    local class="cheap" enabled=1 async=0
    while (( $# > 0 )); do
        case "$1" in
            --class)     class="${2:-cheap}"; shift 2 ;;
            --class=*)   class="${1#--class=}"; shift ;;
            --disabled)  enabled=0; shift ;;
            --async)     async=1; shift ;;
            *)
                printf '_schedule_task: unknown flag %q (task=%s)\n' "$1" "$name" >&2
                shift
                ;;
        esac
    done
    if [[ -z "$name" || -z "$fn" || -z "$interval" ]]; then
        printf '_schedule_task: missing required arg (name=%q interval=%q fn=%q)\n' \
            "$name" "$interval" "$fn" >&2
        return 64
    fi
    if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
        printf '_schedule_task: interval must be a non-negative integer (task=%s got=%q)\n' \
            "$name" "$interval" >&2
        return 64
    fi
    TASK_FN[$name]=$fn
    TASK_INTERVAL[$name]=$interval
    TASK_CLASS[$name]=$class
    TASK_ENABLED[$name]=$enabled
    TASK_ASYNC[$name]=$async
    # Preserve cadence on re-registration; initialise to 0 on first
    # registration so the next tick fires it.
    : "${TASK_NEXT_FIRE[$name]:=0}"
    : "${TASK_LAST_FIRE[$name]:=0}"
    : "${TASK_LAST_RC[$name]:=0}"
    : "${TASK_LAST_ELAPSED[$name]:=0}"
    : "${TASK_BG_PID[$name]:=0}"
    : "${TASK_BG_STARTED[$name]:=0}"
}

# _schedule_override <name> <override_interval> <duration_seconds>
#
# Apply a temporary cadence override. While `now < now+duration` the
# task fires every `override_interval` seconds instead of its base.
# Pull `next_fire` forward if the override would bring it sooner.
#
# Stacking overrides overwrite each other (latest wins). The override
# auto-clears the first time `_scheduler_next_fire` sees an expired
# window.
_schedule_override() {
    local name="$1" override="$2" duration="$3"
    if [[ -z "${TASK_FN[$name]:-}" ]]; then
        printf '_schedule_override: unknown task %q (register it first)\n' "$name" >&2
        return 64
    fi
    if ! [[ "$override" =~ ^[0-9]+$ && "$duration" =~ ^[0-9]+$ ]]; then
        printf '_schedule_override: interval+duration must be integers (override=%q duration=%q)\n' \
            "$override" "$duration" >&2
        return 64
    fi
    local now
    now=$(nexus_clock)
    TASK_OVERRIDE_INT[$name]=$override
    TASK_OVERRIDE_TIL[$name]=$(( now + duration ))
    # Pull next_fire forward IFF the override would fire sooner than
    # the currently-scheduled slot. Crucial guard against clobbering
    # a force-fire: `_schedule_fire_now` sets `next_fire=0` to mean
    # "fire on the very next tick"; if an `_schedule_override` call
    # follows it, we MUST NOT push that 0 forward to `now+override`.
    # A `next_fire` of 0 is treated as "already due," not as "not
    # yet scheduled" — the only case where an unscheduled task hits
    # this branch is a fresh registration with no preceding force,
    # for which "fire on the next tick" is also the correct
    # behaviour (the override interval then kicks in for subsequent
    # fires via `_scheduler_next_fire`).
    local pulled=$(( now + override ))
    local current=${TASK_NEXT_FIRE[$name]:-0}
    if (( current > 0 && pulled < current )); then
        TASK_NEXT_FIRE[$name]=$pulled
    fi
}

# Alias matching the bake-off brief vocabulary. Identical semantics.
_reschedule() { _schedule_override "$@"; }

# _schedule_skip_until <name> <epoch>
#
# Defer the task until at least `epoch`. Implements the proposal's
# "task marks itself skip-until" back-pressure: the GraphQL task can
# honour its rate-limit reset without involving the loop. Any epoch
# in the past is clamped to `now` so the next tick still fires it.
_schedule_skip_until() {
    local name="$1" target="$2"
    if [[ -z "${TASK_FN[$name]:-}" ]]; then
        printf '_schedule_skip_until: unknown task %q\n' "$name" >&2
        return 64
    fi
    if ! [[ "$target" =~ ^[0-9]+$ ]]; then
        printf '_schedule_skip_until: target must be epoch integer (got %q)\n' "$target" >&2
        return 64
    fi
    local now
    now=$(nexus_clock)
    (( target < now )) && target=$now
    TASK_NEXT_FIRE[$name]=$target
}

# _schedule_fire_now <name>
#
# Force the named task to fire on the next tick regardless of its
# `next_fire`. Used by tests and by hand from operator-introspection
# tools.
_schedule_fire_now() {
    local name="$1"
    if [[ -z "${TASK_FN[$name]:-}" ]]; then
        printf '_schedule_fire_now: unknown task %q\n' "$name" >&2
        return 64
    fi
    TASK_NEXT_FIRE[$name]=0
}

# _schedule_enable / _schedule_disable — gate a task without
# unregistering. Useful for suspending the GraphQL surface while a
# global backoff file says "every surface in cooldown" — keeps the
# registration intact so a future re-enable restores cadence.
_schedule_enable() {
    local name="$1"
    [[ -n "${TASK_FN[$name]:-}" ]] || return 64
    TASK_ENABLED[$name]=1
}
_schedule_disable() {
    local name="$1"
    [[ -n "${TASK_FN[$name]:-}" ]] || return 64
    TASK_ENABLED[$name]=0
}

# ---- next-fire computation ----------------------------------------------
# Returns (on stdout) the epoch at which the named task should fire
# next, given its just-completed exit code. Honours active overrides
# and rc=75 back-pressure.
#
# Catch-up policy (open question §8.1 → resolved (a)): if the candidate
# is already in the past, fire on the next tick — matches v1's
# implicit catch-up. Concretely this means a long-running task whose
# next_fire computes <= now gets clamped to `now + 1` so the loop
# doesn't tight-spin re-firing on the same second.
_scheduler_next_fire() {
    local name="$1" rc="$2"
    local now interval base
    now=$(nexus_clock)
    base=${TASK_INTERVAL[$name]:-0}

    # NB: this function is typically called via `$(...)` command
    # substitution from `_scheduler_tick`, which runs in a subshell.
    # `unset` mutations to the registry would be lost on the
    # subshell's exit. The expired-override CLEAR therefore lives in
    # `_scheduler_tick` (parent shell), not here. This function only
    # READS `TASK_OVERRIDE_*` to compute the candidate epoch.
    if (( ${TASK_OVERRIDE_TIL[$name]:-0} > now )); then
        interval=${TASK_OVERRIDE_INT[$name]}
    else
        interval=$base
    fi

    # Back-pressure on transient failure. rc=75 doubles the interval
    # once for the next fire, capped at 4× base. Asymmetric on
    # purpose: a healthy rc=0 next time restores base cadence
    # without a recovery ramp.
    if (( rc == 75 )); then
        interval=$(( interval * 2 ))
        local capped=$(( base * 4 ))
        (( base > 0 && interval > capped )) && interval=$capped
    fi

    local anchor=${TASK_LAST_FIRE[$name]:-$now}
    local candidate=$(( anchor + interval ))
    if (( candidate <= now )); then
        # Overrun catch-up. The task ran past its own interval — fire
        # again on the next tick (now+1) instead of re-queuing in the
        # past, which would tight-spin until we caught up.
        candidate=$(( now + 1 ))
    fi
    printf '%s\n' "$candidate"
}

# Returns the soonest epoch across all enabled tasks. Floors at
# `now + 1` so the sleep helper never receives a non-positive delay
# (which would either error or spin).
_scheduler_soonest_next_fire() {
    local now=$1
    local soonest=0 name nf
    for name in "${!TASK_FN[@]}"; do
        (( ${TASK_ENABLED[$name]:-1} == 1 )) || continue
        nf=${TASK_NEXT_FIRE[$name]:-0}
        if (( soonest == 0 || nf < soonest )); then
            soonest=$nf
        fi
    done
    if (( soonest == 0 || soonest <= now )); then
        soonest=$(( now + 1 ))
    fi
    printf '%s\n' "$soonest"
}

# ---- telemetry ----------------------------------------------------------
# Append one JSONL row per fire to MONITOR_SCHEDULER_LOG, if set.
# Best-effort: failures here must never crash the watcher.
#
# Optional 5th arg is the fire `phase` — defaults to "sync" for the
# inline path; the async path emits "async-start" at launch and
# "async-done" at reap so operators can see overlap windows in the
# JSONL stream.
_scheduler_log_fire() {
    local name="$1" rc="$2" elapsed_ms="$3" next_fire="$4" phase="${5:-sync}"
    [[ -n "${MONITOR_SCHEDULER_LOG:-}" ]] || return 0
    local ts
    ts=$(date -Is 2>/dev/null) || ts="-"
    printf '{"ts":"%s","task":"%s","rc":%d,"elapsed_ms":%d,"next_fire":%d,"phase":"%s"}\n' \
        "$ts" "$name" "$rc" "$elapsed_ms" "$next_fire" "$phase" \
        >> "$MONITOR_SCHEDULER_LOG" 2>/dev/null || true
}

# ---- async fire / reap (ported from Impl-B) -----------------------------
#
# Sidecar-driven done detection: the subshell writes its rc to a
# per-task `.rc` file IMMEDIATELY before exiting. The next tick's reap
# step uses that file's presence as the "child is done" signal — no
# `/proc/<pid>/status` polling, no blocking `wait` on a still-running
# pid. The bash `wait $pid` after the rc-file check is a millisecond-
# scale wait for the (briefly) zombie process and is tolerant of an
# already-reaped pid (`2>/dev/null || true`).
#
# Staging directory: per-task `<stage_dir>/<name>.out` (helper stdout,
# kept for callers that want to consume it) and `<stage_dir>/<name>.rc`
# (the done sentinel). Default location is
# `${STATE_DIR:-/tmp}/scheduler-staging`; operator-overridable via
# `MONITOR_SCHEDULER_STAGE_DIR`.

_scheduler_stage_dir() {
    printf '%s\n' "${MONITOR_SCHEDULER_STAGE_DIR:-${STATE_DIR:-/tmp}/scheduler-staging}"
}

# _scheduler_fire_async <name>
#
# Launch the named task in a backgrounded subshell. Returns
# immediately; the parent stores the child's pid in TASK_BG_PID so
# subsequent ticks can reap it via the sidecar `.rc` file.
_scheduler_fire_async() {
    local name="$1"
    local stage_dir
    stage_dir=$(_scheduler_stage_dir)
    mkdir -p "$stage_dir" 2>/dev/null || true
    local out_file="$stage_dir/$name.out"
    local tmp_file="$stage_dir/$name.out.tmp.$$"
    local rc_file="$stage_dir/$name.rc"
    local err_file="$stage_dir/$name.err"
    # Clean any stale sidecar from a previous run that died without
    # reaching the rc-write step. If we left it, the next reap would
    # immediately "complete" with whatever rc was in the stale file.
    rm -f "$rc_file" 2>/dev/null || true
    # Atomic staging-file write (issue #172). The subshell writes to a
    # per-pid `.tmp` then renames into place so a concurrent reader
    # (e.g. compose_emit consuming this task's output) never sees a
    # half-written file. `mv` is atomic on the same filesystem; the
    # rc-file write happens AFTER the rename so a reader keying off
    # the rc-file sees a fully-renamed `.out`.
    #
    # stderr goes to a per-task `.err` sidecar (truncated each launch,
    # so it can't grow unbounded) instead of /dev/null — the reap step
    # surfaces its head into the watcher log on a non-zero rc. Before
    # this, a failing async helper's diagnostics vanished entirely
    # (your-org/your-nexus#180 R4 diagnosability gap).
    (
        "${TASK_FN[$name]}" > "$tmp_file" 2> "$err_file"
        local _fire_rc=$?
        mv "$tmp_file" "$out_file" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null
        printf '%s\n' "$_fire_rc" > "$rc_file"
    ) &
    TASK_BG_PID[$name]=$!
    TASK_BG_STARTED[$name]=$(nexus_clock)
}

# _scheduler_stage_write_atomic <name> <content-via-stdin>
#
# Atomic staging-file write for sync tasks. Reads content from stdin,
# writes to `<stage>/<name>.out` via tmp+rename so concurrent readers
# (compose_emit) never observe a half-written file. Returns the
# original task function's rc — kept on stdout via process-substitution
# semantics in the caller. Mirrors `_scheduler_fire_async`'s atomic
# discipline for the synchronous path.
_scheduler_stage_write_atomic() {
    local name="$1"
    local stage_dir
    stage_dir=$(_scheduler_stage_dir)
    mkdir -p "$stage_dir" 2>/dev/null || true
    local out_file="$stage_dir/$name.out"
    local tmp_file="$stage_dir/$name.out.tmp.$$"
    cat > "$tmp_file" 2>/dev/null
    mv "$tmp_file" "$out_file" 2>/dev/null || { rm -f "$tmp_file" 2>/dev/null; return 1; }
    return 0
}

# _scheduler_drain_async [max_wait_seconds]
#
# Wait for every in-flight async task to complete its sidecar write,
# up to `max_wait_seconds` (default 30). Used by the `--once` path to
# guarantee staging files are populated before a downstream consumer
# (compose_emit) reads them. Returns 0 if all in-flight tasks reaped
# within the budget, 1 otherwise (best-effort; the watcher is on the
# way out).
_scheduler_drain_async() {
    local budget="${1:-30}"
    local deadline
    deadline=$(( $(nexus_clock) + budget ))
    local pending=1 name
    while (( pending == 1 )) && (( $(nexus_clock) < deadline )); do
        pending=0
        for name in "${!TASK_BG_PID[@]}"; do
            if (( ${TASK_BG_PID[$name]:-0} != 0 )); then
                _scheduler_reap_async "$name" || pending=1
            fi
        done
        (( pending == 1 )) && sleep 0.1 2>/dev/null
    done
    (( pending == 0 ))
}

# _scheduler_reap_async <name>
#
# Check whether the named task's in-flight async run has completed.
# If the sidecar `.rc` file is absent: still running, return rc=1.
# If present: harvest rc + elapsed, clear TASK_BG_PID, return rc=0.
# A task with no in-flight run is a fast no-op (returns rc=1).
_scheduler_reap_async() {
    local name="$1"
    local pid=${TASK_BG_PID[$name]:-0}
    (( pid == 0 )) && return 1
    local stage_dir
    stage_dir=$(_scheduler_stage_dir)
    local rc_file="$stage_dir/$name.rc"
    [[ -f "$rc_file" ]] || return 1
    # Sidecar present ⇒ child has reached the line right before exit.
    # Brief `wait` to harvest the zombie; tolerate already-reaped.
    wait "$pid" 2>/dev/null || true
    local rc
    rc=$(cat "$rc_file" 2>/dev/null || echo 0)
    [[ "$rc" =~ ^[0-9]+$ ]] || rc=0
    rm -f "$rc_file" 2>/dev/null || true
    local now started elapsed_ms
    now=$(nexus_clock)
    started=${TASK_BG_STARTED[$name]:-$now}
    elapsed_ms=$(( (now - started) * 1000 ))
    (( elapsed_ms < 0 )) && elapsed_ms=0
    TASK_LAST_RC[$name]=$rc
    TASK_LAST_ELAPSED[$name]=$elapsed_ms
    TASK_BG_PID[$name]=0
    TASK_BG_STARTED[$name]=0
    _scheduler_log_fire "$name" "$rc" "$elapsed_ms" "${TASK_NEXT_FIRE[$name]:-0}" "async-done"
    # Replay the helper's stderr into the watcher log at EVERY reap
    # (issue #203 follow-up / observability gap). Async helpers log
    # through `log`/`_version_log`, but the subshell's stderr is
    # redirected to the .err sidecar — so a SUCCESSFUL async action
    # (e.g. version_check writing a cockpit drift advisory at
    # 2026-06-11T10:33:47) left NO in-band watcher.log line and the
    # incident was undiagnosable from the log alone. Pre-#203 only the
    # rc!=0 head line surfaced (#180 R4). Bounded (20 lines, 300 chars
    # each) so a chatty helper can't flood the log; the .err sidecar
    # still holds the full text. `log` is main.sh's; absent when
    # sourced standalone in tests — degrade to silence.
    if [[ -s "$stage_dir/$name.err" ]] && declare -F log >/dev/null 2>&1; then
        local _err_tag="$name" _err_line _err_count=0
        (( rc != 0 )) && _err_tag="$name rc=$rc"
        while IFS= read -r _err_line; do
            [[ -n "$_err_line" ]] || continue
            if (( _err_count >= 20 )); then
                log "scheduler[$_err_tag]: ... stderr truncated (full text: $stage_dir/$name.err)"
                break
            fi
            log "scheduler[$_err_tag]: ${_err_line:0:300}"
            _err_count=$(( _err_count + 1 ))
        done < "$stage_dir/$name.err"
    fi
    return 0
}

# ---- async hang watchdog (#180 R4) ---------------------------------------

# Per-task watchdog budget in seconds; 0 = watchdog disabled. See the
# MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR block above for the rationale
# behind max(4 × interval, floor).
_scheduler_async_timeout_budget() {
    local name="$1"
    local floor="${MONITOR_SCHEDULER_ASYNC_TIMEOUT_FLOOR:-300}"
    [[ "$floor" =~ ^[0-9]+$ ]] || floor=300
    if (( floor == 0 )); then
        printf '0\n'
        return 0
    fi
    local interval="${TASK_INTERVAL[$name]:-60}"
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=60
    local by_interval=$(( interval * 4 ))
    if (( by_interval > floor )); then
        printf '%s\n' "$by_interval"
    else
        printf '%s\n' "$floor"
    fi
}

# _scheduler_check_async_timeout <name> <now>
#
# Called from `_scheduler_tick` for every still-in-flight async task
# AFTER the opportunistic reap declined (no rc sidecar yet — a
# completed-but-unreaped run always harvests normally, even past
# budget). When the in-flight age exceeds the budget: kill the
# child's process tree (PID-scoped `pkill -P` for grandchildren —
# the hung `gh`/`curl` — then the subshell itself), clear the
# in-flight state so the task re-arms on its next due tick, record
# rc=124 (the `timeout(1)` convention) with a phase="async-timeout"
# telemetry row, and WARN loudly. The kill is deliberately scoped to
# this one child tree — never a name- or pattern-based kill.
_scheduler_check_async_timeout() {
    local name="$1" now="$2"
    local pid=${TASK_BG_PID[$name]:-0}
    (( pid == 0 )) && return 0
    local budget
    budget=$(_scheduler_async_timeout_budget "$name")
    (( budget == 0 )) && return 0
    local started=${TASK_BG_STARTED[$name]:-$now}
    [[ "$started" =~ ^[0-9]+$ ]] || started=$now
    local age=$(( now - started ))
    (( age < budget )) && return 0

    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    local stage_dir
    stage_dir=$(_scheduler_stage_dir)
    rm -f "$stage_dir/$name.rc" 2>/dev/null || true
    TASK_BG_PID[$name]=0
    TASK_BG_STARTED[$name]=0
    TASK_LAST_RC[$name]=124
    TASK_LAST_ELAPSED[$name]=$(( age * 1000 ))
    _scheduler_log_fire "$name" 124 $(( age * 1000 )) "${TASK_NEXT_FIRE[$name]:-0}" "async-timeout"
    if declare -F log >/dev/null 2>&1; then
        log "WARN scheduler: async task '$name' exceeded its ${budget}s watchdog budget (in-flight ${age}s); killed pid=$pid and its children. Task re-arms on its next due tick."
    fi
    return 0
}

# ---- main iterator ------------------------------------------------------
# Run every enabled task whose `next_fire <= now`. Returns rc=99 if
# a shutdown was requested mid-tick (signal arrived); rc=0 otherwise.
# Iteration order is sorted by task name so observed cadence is
# reproducible across runs (Bash associative-array iteration order
# is implementation-defined).
_scheduler_tick() {
    local now name nf rc start_ns end_ns elapsed_ms fired_at next
    now=$(nexus_clock)
    _SCHEDULER_FIRED_THIS_TICK=()

    local names
    mapfile -t names < <(printf '%s\n' "${!TASK_FN[@]}" | LC_ALL=C sort)

    for name in "${names[@]}"; do
        # A shutdown that arrived mid-tick should still let in-flight
        # state settle, but we stop firing further tasks immediately.
        (( _scheduler_shutdown_requested == 1 )) && break
        [[ -n "${TASK_FN[$name]:-}" ]] || continue
        (( ${TASK_ENABLED[$name]:-1} == 1 )) || continue

        # Async reap: every tick, opportunistically harvest any
        # completed async run before checking due/in-flight. Cheap —
        # one stat() on the sidecar `.rc` file for tasks not in
        # flight. Done BEFORE the due-check so a just-completed async
        # task that's now due again can re-fire in the same tick.
        # A run that's still in flight after the reap attempt gets
        # the hang-watchdog check (#180 R4) — past its budget the
        # child tree is killed and the task re-arms.
        if (( ${TASK_ASYNC[$name]:-0} == 1 )) && (( ${TASK_BG_PID[$name]:-0} != 0 )); then
            _scheduler_reap_async "$name" || true
            if (( ${TASK_BG_PID[$name]:-0} != 0 )); then
                _scheduler_check_async_timeout "$name" "$now"
            fi
        fi

        nf=${TASK_NEXT_FIRE[$name]:-0}
        (( nf > now )) && continue

        # Async in-flight guard: a task whose previous run hasn't
        # reaped yet skips this tick. next_fire is left untouched —
        # we'll keep checking each tick until the reap path clears
        # TASK_BG_PID, then the next due check fires a fresh launch.
        if (( ${TASK_ASYNC[$name]:-0} == 1 )) && (( ${TASK_BG_PID[$name]:-0} != 0 )); then
            continue
        fi

        # Auto-clear an expired override before firing (parent-shell
        # mutation; see _scheduler_next_fire for why this can't live
        # inside the subshell-running helper).
        if (( ${TASK_OVERRIDE_TIL[$name]:-0} > 0 && ${TASK_OVERRIDE_TIL[$name]:-0} <= now )); then
            unset "TASK_OVERRIDE_TIL[$name]"
            unset "TASK_OVERRIDE_INT[$name]"
        fi

        if (( ${TASK_ASYNC[$name]:-0} == 1 )); then
            # Async launch. Schedule next_fire at LAUNCH time (not at
            # completion) so an async task whose runtime exceeds its
            # interval doesn't pin itself to "due immediately on every
            # tick after completion" — the in-flight guard above
            # already covers the still-running case.
            _scheduler_fire_async "$name"
            fired_at=$(nexus_clock)
            TASK_LAST_FIRE[$name]=$fired_at
            # last_rc / last_elapsed are placeholder zeros until the
            # reap path overwrites them; document the contract in
            # _scheduler_introspect.
            TASK_LAST_RC[$name]=0
            TASK_LAST_ELAPSED[$name]=0
            next=$(_scheduler_next_fire "$name" 0)
            TASK_NEXT_FIRE[$name]=$next
            _scheduler_log_fire "$name" 0 0 "$next" "async-start"
            _SCHEDULER_FIRED_THIS_TICK+=("$name")
            continue
        fi

        # Sync fire. Measure wall-clock duration in ms. `date +%s%N`
        # is GNU-only but present on every Linux box the watcher runs
        # on; fall back to seconds if the nanosecond field reads
        # literally as `%N` (a non-GNU date that doesn't expand it).
        start_ns=$(date +%s%N 2>/dev/null)
        [[ "$start_ns" == *N ]] && start_ns=$(( $(date +%s) * 1000000000 ))

        "${TASK_FN[$name]}"
        rc=$?

        end_ns=$(date +%s%N 2>/dev/null)
        [[ "$end_ns" == *N ]] && end_ns=$(( $(date +%s) * 1000000000 ))
        elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
        (( elapsed_ms < 0 )) && elapsed_ms=0

        # Re-read the clock so next_fire computations use the time
        # AFTER the task ran. Critical for the drift catch-up case: a
        # long task that advanced NEXUS_TEST_NOW or burned real wall
        # time must have its `now` reflect post-fire time, otherwise
        # the next_fire candidate looks artificially early.
        fired_at=$(nexus_clock)
        TASK_LAST_FIRE[$name]=$fired_at
        TASK_LAST_RC[$name]=$rc
        TASK_LAST_ELAPSED[$name]=$elapsed_ms
        next=$(_scheduler_next_fire "$name" "$rc")
        TASK_NEXT_FIRE[$name]=$next
        _scheduler_log_fire "$name" "$rc" "$elapsed_ms" "$next" "sync"
        _SCHEDULER_FIRED_THIS_TICK+=("$name")
    done

    # Optional post-tick hook for callers that want to compose-and-
    # paste once after every batch of fires. Registered by `main.sh`
    # when running in v2 mode; absent in unit tests.
    if declare -F _scheduler_post_tick_hook >/dev/null 2>&1; then
        _scheduler_post_tick_hook
    fi

    (( _scheduler_shutdown_requested == 1 )) && return 99
    return 0
}

# ---- signal-aware sleep -------------------------------------------------
# Sleep until the soonest next_fire, capped at MONITOR_SCHEDULER_MAX_SLEEP
# so a SIGTERM is observed within that interval even on a long-idle
# workspace. Returns 99 if a shutdown signal arrived during the sleep.
#
# Backgrounded `sleep` + `wait` is the canonical Bash idiom for an
# interruptible sleep — a bare `sleep` ignores SIGTERM until it
# returns normally.
_scheduler_sleep_until_next() {
    local now soonest delay
    now=$(nexus_clock)
    soonest=$(_scheduler_soonest_next_fire "$now")
    delay=$(( soonest - now ))
    (( delay < 1 )) && delay=1
    (( delay > MONITOR_SCHEDULER_MAX_SLEEP )) && delay=$MONITOR_SCHEDULER_MAX_SLEEP

    # Test mode: when NEXUS_TEST_NOW is set, tests drive ticks
    # back-to-back without burning wall-clock seconds. Short-circuit
    # so the test suite stays fast.
    if [[ -n "${NEXUS_TEST_NOW:-}" ]]; then
        return 0
    fi

    sleep "$delay" &
    local pid=$!
    wait "$pid" 2>/dev/null
    (( _scheduler_shutdown_requested == 1 )) && return 99
    return 0
}

# Install cooperative-shutdown handlers. Idempotent. Callers (i.e.
# `main.sh` v2 path) invoke this once at startup. Test fixtures
# reset state via `_scheduler_reset_for_tests` and re-install when
# needed.
_scheduler_install_signal_handlers() {
    _scheduler_shutdown_requested=0
    trap '_scheduler_shutdown_requested=1' SIGTERM SIGINT
}

# ---- introspection ------------------------------------------------------
# Dump the registry to stdout in a stable shape for the ng
# watcher-status sub-command and ad-hoc operator debugging.
_scheduler_introspect() {
    local now
    now=$(nexus_clock)
    printf 'scheduler now=%d max_sleep=%ds tasks=%d\n' \
        "$now" "$MONITOR_SCHEDULER_MAX_SLEEP" "${#TASK_FN[@]}"
    local name interval class enabled next last rc elapsed override_til override_int
    local names
    mapfile -t names < <(printf '%s\n' "${!TASK_FN[@]}" | LC_ALL=C sort)
    for name in "${names[@]}"; do
        interval=${TASK_INTERVAL[$name]:-0}
        class=${TASK_CLASS[$name]:-cheap}
        enabled=${TASK_ENABLED[$name]:-1}
        next=${TASK_NEXT_FIRE[$name]:-0}
        last=${TASK_LAST_FIRE[$name]:-0}
        rc=${TASK_LAST_RC[$name]:-0}
        elapsed=${TASK_LAST_ELAPSED[$name]:-0}
        override_til=${TASK_OVERRIDE_TIL[$name]:-0}
        override_int=${TASK_OVERRIDE_INT[$name]:-0}
        printf '  %-24s interval=%ds class=%-9s enabled=%d next=%d last_fire=%d last_rc=%d last_ms=%d override_int=%d override_til=%d\n' \
            "$name" "$interval" "$class" "$enabled" "$next" "$last" "$rc" "$elapsed" \
            "$override_int" "$override_til"
    done
}

# ---- test-only state reset ----------------------------------------------
# Wipe the registry without unsetting the helper functions. Tests
# call this between scenarios to guarantee a clean slate.
_scheduler_reset_for_tests() {
    TASK_FN=()
    TASK_INTERVAL=()
    TASK_NEXT_FIRE=()
    TASK_LAST_FIRE=()
    TASK_LAST_RC=()
    TASK_LAST_ELAPSED=()
    TASK_CLASS=()
    TASK_OVERRIDE_TIL=()
    TASK_OVERRIDE_INT=()
    TASK_ENABLED=()
    TASK_ASYNC=()
    TASK_BG_PID=()
    TASK_BG_STARTED=()
    _SCHEDULER_FIRED_THIS_TICK=()
    _scheduler_shutdown_requested=0
}
