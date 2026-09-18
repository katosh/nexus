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
#      COLD BOOT OVERRIDE (your-org/nexus-code#651): when `entry.sh` has
#      left a `mode=fresh` boot intent at `$STATE_DIR/boot-intent` — the
#      operator started the nexus WITHOUT `--continue` — this entire step
#      is replaced by a deliberate drop: no worker is resurrected, the
#      snapshot they would have come from is ARCHIVED (never deleted), and
#      a manifest of exactly what was dropped is written for delivery into
#      the incoming orchestrator's first turn. The intent is one-shot
#      (archived on read) so the mid-life recoveries that share this
#      script — SessionStart, `bootstrap.sh`, `svc.sh up` — keep resuming
#      workers as they should. See "cold boot" below the worker helpers.
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
#   RECOVER_BOOT_INTENT_TTL— seconds a `boot-intent` record stays
#                            honourable (default:
#                            recover.boot_intent_ttl_seconds, 900). An
#                            older record is archived and ignored.
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

# `_ensure_service_log` — set the service log's mode where the file is
# CREATED (your-org/nexus-code#484). Side-effect-free on source.
# shellcheck source=_log-mode.sh
source "$_script_dir/_log-mode.sh"

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

# Dropped-worker manifest helpers (your-org/nexus-code#651). We WRITE the
# manifest; `spawn-fresh-orchestrator.sh` and `watcher/bootstrap.sh` read
# and deliver it. Shared so the path and the once-only delivery rule have
# exactly one definition. Side-effect-free on source.
# shellcheck source=_dropped_manifest.sh
source "$_script_dir/_dropped_manifest.sh"

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
    BOOT_INTENT_TTL="${RECOVER_BOOT_INTENT_TTL:-$("$_cfg" recover.boot_intent_ttl_seconds 900)}"
else
    INTERVAL="${RECOVER_INTERVAL:-60}"
    MAX_WORKERS="${RECOVER_MAX_WORKERS:-12}"
    TARGET_WINDOW="${RECOVER_TARGET_WINDOW:-orchestrator}"
    SERVICES_WINDOW="${MONITOR_SERVICES_WINDOW:-services}"
    ORCH_WINDOW_INDEX="${RECOVER_ORCH_WINDOW_INDEX:-2}"
    BOOT_INTENT_TTL="${RECOVER_BOOT_INTENT_TTL:-900}"
fi
[[ "$MAX_WORKERS" =~ ^[0-9]+$ ]] || MAX_WORKERS=12
[[ -n "$TARGET_WINDOW" ]] || TARGET_WINDOW=orchestrator
[[ -n "$SERVICES_WINDOW" ]] || SERVICES_WINDOW=services
[[ "$ORCH_WINDOW_INDEX" =~ ^[0-9]+$ ]] || ORCH_WINDOW_INDEX=2
[[ "$BOOT_INTENT_TTL" =~ ^[0-9]+$ ]] || BOOT_INTENT_TTL=900

# Boot-intent handoff (your-org/nexus-code#651). `entry.sh` records the
# operator's fresh-vs-continue intent here; this script is the process
# that actually performs — or refuses — the worker resurrection, so it is
# the one that has to read it. See `_recover_read_boot_intent`.
BOOT_INTENT_FILE="$STATE_DIR/boot-intent"
SNAPSHOT_FILE="$STATE_DIR/last-snapshot.txt"

# Run-mode globals (consumed by the functions below). Defaults here so
# a test that sources this file for its functions sees sane values
# without invoking `_recover_main`. Flags override them in main.
DO_WATCHER=1
DO_ORCHESTRATOR=1
DO_SERVICES=1
DO_WORKERS=1
DRY_RUN=0
LIST_ONLY=0

# 1 ⇒ the operator booted WITHOUT `--continue`: this run resurrects NO
# workers at all. Resolved once from the boot-intent file (see
# `_recover_read_boot_intent`); 0 for every ordinary mid-life recovery.
COLD_BOOT=0

# Operator-engaged windows captured at the very START of recovery
# (before the watcher relaunch, whose first idle-probe cycle prunes
# operator-engaged.tsv rows for windows not yet respawned). Space-
# padded for membership tests, mirroring `registry_names`. Default
# empty so sourcing this file for its functions (tests) is side-
# effect-free.
ENGAGED_WINDOWS=" "

log() { echo "[recover] $*" >&2; }

# --- registry READABILITY: three states, not two --------------------------
#
# your-org/nexus-code#1266. `[[ -f "$file" ]]` is TRUE for a file that exists
# and cannot be READ, so it does not cover the `done < "$file"` redirection
# one line below. An I/O fault (mode, ACL, ESTALE/EIO on the NFS-backed
# tree this nexus lives on) therefore produced the SAME observable as an
# absent registry — zero rows — and `verify-stack.sh` turned that into
# "stack converged: watcher fresh, services healthy" at exit 0. Measured at
# 85458bf8 with the registry BYTES held constant (md5 identical) and the
# file MODE the only variable: mode 0644 -> EXIT=1 naming the unhealthy
# service, mode 0000 -> EXIT=0 "services healthy". A genuinely unhealthy
# service read as a healthy stack. That is MANUFACTURED SUCCESS, not a
# masked failure: every visible artefact says the work was done and the
# only evidence is an absence.
#
# The three states, and the axis that separates them — the same axis
# monitor/assert-shims-wrapped.sh draws its exit-79 bound on, which is
# **could the reader examine its subject at all**:
#
#   ABSENT      no registry -> "there are no services" IS the answer. rc 0,
#               no rows. An ADJUDICATION; it stays rc 0.
#   READABLE    rc 0 and the rows are the answer, zero rows included: an
#               empty or all-comment registry genuinely declares nothing.
#   UNREADABLE  the path EXISTS and could not be read. NO statement about
#               its contents is available. rc 79, NEVER folded into 0.
#
# 79 is NOT-CHECKED, exactly as in assert-shims-wrapped.sh: it does not
# assert a fault in the registry's CONTENT, only that this reader could not
# look. A CONFIRMED failure outranks it — a consumer that has already found
# a real fault reports the fault, not 79.
#
# Why every ordinary shape must stay rc 0, and why that makes 79 precise:
# measured at 85458bf8 across 13 registry shapes (absent, empty, row-last
# with and without a trailing newline, comment-last, blank-last, trailing
# whitespace, malformed 2-field, 5-field, 6-field policy, CRLF, comments
# only) EVERY one returns rc 0. Only the unreadable one returns non-zero.
# So a non-zero rc here means an I/O fault SPECIFICALLY, and `|| return 0`
# at a call site discards exactly and only that signal.
#
# THE PROBE IS NOT `[[ -r ]]`. `-r` reads permission BITS; it does not
# attempt an open, so it passes for a path that will fail with ESTALE/EIO
# — the realistic driver on this filesystem. The probe opens the file. It
# also requires a REGULAR file first, because opening a FIFO BLOCKS, and a
# reader that hangs is worse than one that lies.
#
# THE REPLICA CENSUS, and it is TWO FAMILIES rather than one. The predicate is
# REPLICATED (not sourced) for the same reason `_recover_service_healthy` is:
# the watcher must not source this script.
#
# THE TWO NUMBERS, stated together because they are the same fact on different
# denominators and quoting one alone has already caused a reader to reconcile
# against the other: there are **SEVEN PREDICATES** — this one, plus **SIX
# REPLICAS** in six other files. The sentence this replaced claimed replication
# into THREE files, so the replica undercount is 3 -> 6. Whichever number you
# carry, say which you mean; the suite asserts the SEVEN (predicates), because
# that is the one countable from the tree without deciding what "original"
# means.
#
# They do NOT all share the ABSENT-case behaviour documented above — so "keep in
# step" means keep in step with the family you are in, and a reader who copies
# the nearest one gets the wrong contract half the time:
#
#   FAMILY A — `[[ -e ]] || return 0`, i.e. ABSENT is an ANSWER (rc 0).
#     _recover_registry_readable  (here)
#     _sh_registry_readable       (watcher/_service_health.sh)
#     svc_registry_readable       (svc.sh)
#   These are the ones the contract above describes literally: they are called
#   by PARSERS, whose job is to emit rows, and "no registry" legitimately means
#   "no rows".
#
#   FAMILY B — `[[ -f ]] || return 1`, i.e. ABSENT reports NOT-READABLE.
#     _version_registry_readable  (watcher/_version_restart.sh)
#     _idle_registry_readable     (watcher/_idle_probe.sh)
#     _remote_reg_open_ok         (_remote_lib.sh)
#     _requests_reg_open_ok       (watcher/_requests.sh)
#   These are BARE OPEN TESTS, not adjudicators. Each is SAFE only because its
#   single call site gates it behind `[[ -e "$reg" ]]` FIRST, which supplies the
#   absent case before the predicate is ever asked. Measured: all four return 1
#   for an absent path. THE HAZARD IS THE NEXT CALL SITE, not the current one —
#   call one of these unguarded and an absent registry reports as unreadable,
#   which for `_remote_reg_open_ok` would turn a fresh clone's documented
#   off-by-default state into "the machinery failed".
#
# An earlier version of this block said "three" and named only family A. That
# undercount is this file's own documented hazard — a comment describing the
# matcher its author cared about — sitting in the block that defines the
# contract. `monitor/watcher/test-registry-unreadable-refusal.sh` now asserts
# the census in both directions so it cannot drift again by care alone.
#
# There is deliberately NO shared `NEXUS_REGISTRY_NOT_READABLE` constant. One
# existed here and had ZERO readers while its own comment claimed call sites
# used it; a constant that cannot be shared (the watcher modules do not source
# this file) is dead code wearing a mechanism's clothes.

# _recover_registry_readable <file>
#   0  readable, or genuinely ABSENT (both are adjudications)
#  79  exists and could not be read — no statement about contents available
_recover_registry_readable() {
    local file="$1"
    [[ -e "$file" ]] || return 0
    [[ -f "$file" ]] || return 79
    # `2>/dev/null` FIRST. Redirections are applied left to right, so
    # `{ :; } < "$file" 2>/dev/null` attempts the open BEFORE stderr is
    # silenced and leaks a bare "Permission denied" naming THIS line — a
    # diagnostic that points at the probe rather than at the registry.
    # Measured on bash 4.4.20: order A prints, order B is silent, both rc 1.
    { : ; } 2>/dev/null < "$file" || return 79
    return 0
}

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
    # Three states, not two — see "registry READABILITY" above. ABSENT is an
    # answer (rc 0, no rows); UNREADABLE is not (rc 79).
    if ! _recover_registry_readable "$file"; then
        # ONE honest diagnostic, naming the file and the verdict. The bare
        # bash redirection error this replaces named a line number inside
        # this function, which reads as a bug in the parser rather than as
        # an unreadable registry.
        log "registry: NOT READABLE at $file — refusing to report its contents (rc 79)"
        return 79
    fi
    [[ -e "$file" ]] || return 0
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
    # The probe above and this redirection are two separate opens, so a fault
    # arriving between them (ESTALE on a re-exported mount) would otherwise
    # slip through as a SHORT read — plausible, non-empty, and worse than a
    # zero because nothing looks wrong. The redirection's own rc is the only
    # thing that sees it.
    done < "$file" || return 79
}

# --- per-service primitives ----------------------------------------------

# Run a healthcheck command in the service's workdir. Exit 0 = healthy.
# The healthcheck is arbitrary shell (curl, pgrep, test -f …); we run it
# from a PIPE rather than from argv so the registry author writes it naturally
# AND the health string never becomes process-table content.
#
# WHY NOT `bash -c "$health"` (your-org/nexus-code#891). That form puts the
# ENTIRE health string — pattern included — into a process's argv. Whether that
# process survives long enough to be scanned depends on whether bash EXECs, and
# the safe set is far narrower than "simple commands":
#
#     bash 4.4.20, nothing matching the marker running, rc=1 is correct
#       pgrep -f M                 rc=1  exec'd, safe
#       pgrep -f M >/dev/null      rc=0  FALSE HEALTHY   <- a redirection defeats exec
#       pgrep -f M 2>/dev/null     rc=0  FALSE HEALTHY
#       pgrep -f M && true         rc=0  FALSE HEALTHY
#       ( pgrep -f M )             rc=0  FALSE HEALTHY
#       exec pgrep -f M            rc=1  safe
#
# A redirection is idiomatic in a healthcheck, so "keep it a simple command" is
# not a usable rule. The failure direction is what makes this worse than its
# siblings: it is a BOOLEAN THAT IS ALWAYS TRUE. The service reads `healthy`
# forever, the supervisor never restarts it, and nothing anywhere logs a fault.
# #869 (kill-side ownership) and #871 (the wait-side hook guard) both miss it
# because it is neither a kill nor a wait.
#
# Process substitution passes the script over /dev/fd, so this process's argv is
# `bash /dev/fd/N` and carries no pattern under ANY health-string shape. It
# writes nothing to disk, which matters: a temp-file variant fails closed under
# the read-only-filesystem degraded mode (#473) and would spuriously report
# UNHEALTHY — restarting working services — exactly when the tree is least able
# to cope.
#
# NOT fixed by this, and not a defect of it: a health string whose LAST stage
# masks the status (`pgrep -f X | head -1` returns head's 0) still lies. That is
# ordinary pipeline semantics, owned by the registry author, and measured as
# such — `false | head -1` is rc 0 with no process predicate anywhere. Under
# `set -o pipefail` the same string reports correctly.
#
# A SECOND, IDENTICAL SITE exists at monitor/watcher/_service_health.sh
# (`_sh_service_healthy`), deliberately replicated there to avoid sourcing this
# script into the watcher. Both were fixed together; keep them in step.
_recover_service_healthy() {
    local workdir="$1" health="$2" rc=0
    ( cd "$workdir" 2>/dev/null && bash <(printf '%s' "$health") ) >/dev/null 2>&1 || rc=$?
    # exit 100 == alive, reporting a FINDING about its environment
    # (your-org/nexus-code#1423; the watcher's _service_health.sh owns the
    # vocabulary). Not down: relaunching a monitor for saying what it was
    # registered to say would be the restart-that-changes-nothing this
    # code was sent to by the DOWN wording.
    (( rc == 0 || rc == 100 ))
}

_recover_window_exists() {
    local name="$1"
    command -v tmux >/dev/null 2>&1 || return 1
    grep -qxF "$name" <<<"$(tmux list-windows -F '#{window_name}' 2>/dev/null)"
}

# Path of a service's headless-supervisor pidfile.
_recover_pidfile() { printf '%s/services/%s.pid' "$STATE_DIR" "$1"; }

# Resolve a service's headless-supervisor record into one of three words:
#
#   alive:<pid>  the pidfile names a live PID whose cmdline still mentions
#                the launch wrapper — a real supervisor is running.
#   stale:<pid>  the pidfile is PRESENT but its PID is dead, unreadable, or
#                was recycled into an unrelated process. The RECORD outlived
#                the process it describes.
#   absent       no pidfile at all — unmanaged, legacy-tmux-hosted, or not
#                yet migrated to the headless path. Nothing was ever
#                recorded, so there is nothing to contradict.
#
# The `stale` vs `absent` split is the whole point: only a PRESENT-but-dead
# record PROVES a supervisor died. That is what makes the
# healthy-but-unsupervised inconsistency detectable (a green healthcheck
# next to a dead supervisor record) without false-positiving every
# never-had-a-pidfile service. Callers wanting a plain boolean use
# _recover_service_running below, which is defined in terms of this.
#
# The cmdline guard mirrors `_watcher_pid_is_live_watcher` (the 2026-06-07
# stale-lock lesson): after a reboot a recycled PID could otherwise be
# mistaken for a running supervisor, wedging a dead service permanently
# "leave it alone". If /proc is unreadable we fall back to the liveness
# check alone. The pidfile is per-service-name, which is what lets two
# services that share a wrapper script (e.g. `serve-supervised.sh`) be
# told apart — a bare `pgrep` on the wrapper could not.
#
# IDENTITY (your-org/nexus-code#606): a bare pid is NOT an identity. The
# state dir lives on shared storage but a pid only means something inside
# the pid NAMESPACE that minted it, so after a container restart every
# recorded pid refers to a namespace that no longer exists. The cmdline
# guard alone does not save us: several services share one wrapper
# basename (`serve-supervised.sh` backs four rows here), so a recycled pid
# that happens to run the same wrapper passes it and a DEAD supervisor
# reads as `alive:` — the service is then wedged "leave it alone" forever.
# So the record carries the minting pid namespace (`ns=`) and the
# supervisor's kernel start-time (`start=`), and both are verified here.
# Records written before this change carry neither; they degrade to
# exactly the previous behaviour rather than being declared stale.
_recover_ns_id() { readlink "/proc/$$/ns/pid" 2>/dev/null || true; }

# Kernel start-time of a live pid (jiffies since boot; /proc/<pid>/stat
# field 22). The canonical defeat for pid recycling: a recycled pid
# necessarily carries a LATER start-time than the one we recorded. Field 2
# (comm) may contain spaces, so split only what follows the final ") ".
_recover_starttime() {
    local pid="$1" sr
    sr=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    sr=${sr#*") "}
    # shellcheck disable=SC2086  # deliberate word-splitting of stat fields
    set -- $sr
    printf '%s' "${20:-}"
}

_RECOVER_SUP_STATE=''     # alive:<pid> | stale:<pid> | absent
_RECOVER_SUP_PID=''       # the recorded pid, whatever its state
_RECOVER_STALE_REASON=''  # why a stale record is stale (empty unless stale)

_recover_mark_stale() { _RECOVER_SUP_STATE="stale:$1"; _RECOVER_STALE_REASON="$2"; }

# The probe: same decision as _recover_supervisor_state but WITHOUT a
# subshell, so the caller can read the stale REASON. A reason is not
# cosmetic — `foreign-namespace` (the container-restart signature) and
# `process-gone` demand different operator action, and `svc.sh` prints it.
_recover_supervisor_probe() {
    local name="$1" launch="$2"
    local pf; pf=$(_recover_pidfile "$name")
    _RECOVER_SUP_STATE=''; _RECOVER_SUP_PID=''; _RECOVER_STALE_REASON=''
    [[ -f "$pf" ]] || { _RECOVER_SUP_STATE='absent'; return 0; }
    local pid='' rec_ns='' rec_start='' line n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n+1))
        if (( n == 1 )); then pid="$line"; continue; fi
        case "$line" in
            ns=*)    rec_ns="${line#ns=}" ;;
            start=*) rec_start="${line#start=}" ;;
        esac
    done < "$pf"
    _RECOVER_SUP_PID="$pid"
    [[ "$pid" =~ ^[0-9]+$ ]] || { _recover_mark_stale "${pid:-?}" 'malformed-record'; return 0; }
    # Namespace identity FIRST: a pid minted in a different pid namespace
    # names nothing here, so asking `kill -0` about it is meaningless — it
    # can only produce a false positive.
    local cur_ns; cur_ns=$(_recover_ns_id)
    if [[ -n "$rec_ns" && "$rec_ns" != unknown && -n "$cur_ns" && "$rec_ns" != "$cur_ns" ]]; then
        _recover_mark_stale "$pid" 'foreign-namespace'; return 0
    fi
    kill -0 "$pid" 2>/dev/null || { _recover_mark_stale "$pid" 'process-gone'; return 0; }
    if [[ -n "$rec_start" && "$rec_start" != unknown ]]; then
        local cur_start; cur_start=$(_recover_starttime "$pid")
        if [[ -n "$cur_start" && "$cur_start" != "$rec_start" ]]; then
            _recover_mark_stale "$pid" 'pid-recycled'; return 0
        fi
    fi
    local cmdline_file="/proc/$pid/cmdline"
    if [[ -r "$cmdline_file" ]]; then
        local cmdline tok
        cmdline=$(tr '\0' ' ' < "$cmdline_file" 2>/dev/null)
        tok=${launch%% *}     # first token of the launch cmd
        tok=${tok##*/}        # → its basename, e.g. serve-supervised.sh
        [[ -n "$tok" && "$cmdline" == *"$tok"* ]] || { _recover_mark_stale "$pid" 'cmdline-mismatch'; return 0; }
    fi
    _RECOVER_SUP_STATE="alive:$pid"
}

_recover_supervisor_state() {
    _recover_supervisor_probe "$1" "$2"
    printf '%s' "$_RECOVER_SUP_STATE"
}

# Is the service's headless supervisor still alive? Thin boolean over
# _recover_supervisor_state — `absent` and `stale:*` are both "not running".
_recover_service_running() {
    local st; st=$(_recover_supervisor_state "$1" "$2")
    [[ "$st" == alive:* ]]
}

# Launch a service HEADLESS — detached, no tmux window. `setsid` puts the
# supervisor in its own session (no controlling tty) so it outlives this
# recovery process; stdin is /dev/null and stdout/stderr append to the
# service logfile (the registry's 5th field, else <workdir>/serve.log).
# The inner shell records its OWN pid into the pidfile and then `exec`s
# the wrapper, so the recorded PID is the wrapper's regardless of whether
# setsid forks or execs. Returns nonzero if setsid is unavailable.
# How long `_recover_launch_service` waits for the supervisor's own pidfile to
# appear before declaring the launch failed. Bounded and LOUD by construction —
# see the function for why neither a sleep nor an unbounded wait is acceptable.
: "${NEXUS_RECOVER_PIDFILE_TIMEOUT:=10}"

# Wait for a COMPLETE supervisor record at $1, or fail.
#
# WHY A POLL AND NOT A SLEEP (your-org/nexus-code#918). A `sleep` is not a
# synchronisation primitive: it is a guess that is simultaneously too long on an
# idle box and too short under the load that produces the race in the first
# place. A bounded poll returns as soon as the record is readable and still has
# a hard ceiling.
#
# WHY BOUNDED AND NOT "UNTIL IT APPEARS". An unbounded wait converts a flake
# into a HANG, and this is the SERVICE RECOVERY path — the code that runs when
# something is already wrong. A recovery that never returns is worse than the
# bug it was fixing.
#
# WHAT HAPPENS WHEN THE CHILD NEVER WRITES: this returns non-zero, the caller
# logs `launch FAILED` and emits `launch-failed`. Never a silent `absent` — an
# absent record and a supervisor that failed to start are the same observable,
# and conflating them is exactly the defect being fixed here.
_recover_wait_pidfile() {
    local pf="$1"
    local timeout="${2:-$NEXUS_RECOVER_PIDFILE_TIMEOUT}"
    # Centiseconds, integer: bash cannot compare floats, and `[[ 0.5 -lt 1 ]]`
    # is a syntax error rather than a false — a silent-zero shape.
    local waited=0 step_cs=5 max_cs=$(( timeout * 100 )) line=''
    while (( waited < max_cs )); do
        if [[ -f "$pf" ]]; then
            read -r line < "$pf" 2>/dev/null || line=''
            # `mv` makes the record appear whole, so a readable first line means
            # the whole record landed. Checked anyway: a legacy or hand-written
            # file could pre-date the atomic writer.
            [[ "$line" =~ ^[0-9]+$ ]] && return 0
        fi
        sleep 0.05
        waited=$(( waited + step_cs ))
    done
    return 1
}

_recover_launch_service() {
    local name="$1" workdir="$2" launch="$3" logfile="$4"
    command -v setsid >/dev/null 2>&1 || { log "setsid unavailable; cannot launch $name headless"; return 1; }
    local svcdir="$STATE_DIR/services"
    mkdir -p "$svcdir" 2>/dev/null || true
    local pf lf inner
    pf=$(_recover_pidfile "$name")
    lf="${logfile:-$workdir/serve.log}"
    # The leading ulimit restores the soft RLIMIT_NPROC to the hard limit
    # (fork-storm class, your-org/nexus-code#487): a worker legitimately
    # running recovery would otherwise leak its own soft nproc ceiling
    # (spawn-worker.sh) into the long-lived service supervisor. The worker
    # ceiling is soft-only, so the raise is always permitted.
    # Line 1 is the pid (every legacy reader does `read -r pid < pidfile`, so
    # it must stay first and bare). The `ns=`/`start=` lines below make the
    # record an IDENTITY rather than a bare integer — see
    # _recover_supervisor_probe for why a pid alone cannot be trusted across
    # a container restart. `$$` is the invoking shell's pid even inside a
    # command substitution, so /proc/$$/ reads describe the supervisor, not
    # the substitution's forked subshell. Written before `exec`, which
    # preserves both the pid and the start-time.
    local idrec='_ns=$(readlink /proc/$$/ns/pid 2>/dev/null || printf unknown);'
    idrec+=' _sr=$(cat /proc/$$/stat 2>/dev/null); _sr=${_sr#*") "}; set -- $_sr;'
    idrec+=' printf "%s\nns=%s\nstart=%s\n" "$$" "${_ns:-unknown}" "${20:-unknown}"'
    # ATOMIC WRITE (your-org/nexus-code#918). The record is written to a temp
    # file in the SAME directory and then `mv`'d into place; rename(2) is atomic
    # on POSIX, so a reader sees either the old record or the whole new one,
    # never a half-written one. Before this, `> "$pf"` truncated on open and the
    # `printf` landed later, so a reader between the two got an EMPTY file and
    # reported `malformed-record`. `$$` inside the inner string is the CHILD's
    # pid, so the temp name cannot collide between concurrent launches.
    printf -v inner 'ulimit -Su "$(ulimit -Hu)" 2>/dev/null || true; _tf=%q.tmp.$$; { %s; } > "$_tf" && mv -f "$_tf" %q; cd %q && exec %s' "$pf" "$idrec" "$pf" "$workdir" "$launch"
    # Create the log with an explicit mode BEFORE the redirect opens it.
    # A bare `>>` would create it under the ambient umask (007 here) —
    # 0660, group-writable, in a group-shared tree — and a group-writable
    # log cannot be trusted as evidence (your-org/nexus-code#484). This is
    # the create-by-redirect site for every registry service, so the one
    # call covers the whole fleet. Best-effort by contract: it never fails
    # a launch, and never touches a log owned by another uid (nginx, labsh).
    _ensure_service_log "$lf"
    # MOVE THE OLD RECORD ASIDE FIRST, and this is not tidiness — without it the
    # wait below is a no-op. A relaunch happens precisely when a STALE pidfile
    # exists, so the parent would find that stale file instantly, conclude the
    # child had written, and return before the new record landed: the original
    # race, reintroduced by its own fix. Clearing it makes the wait observe the
    # NEW record or nothing.
    #
    # RENAMED, NOT DELETED (your-org/nexus-code#918, sk890). This step is
    # UNCONDITIONAL and runs BEFORE the launch, so with `rm -f` any launch that
    # then failed to produce a record destroyed the prior one — on exactly the
    # path where an operator most wants it. A failed relaunch is when that file
    # is the only remaining trace of which supervisor died, and the failure log
    # says `Check $lf`, which is useless if the evidence went with it. `#606`
    # built a deliberate culture around `Pid record PRESERVED (evidence)`; this
    # keeps it. The wait still sees no CURRENT record, so the synchronisation
    # property is unchanged — the rename buys the evidence for free.
    #
    # `$pf.superseded` deliberately does not end in `.pid`, so the `services/*.pid`
    # globs elsewhere do not pick it up as a live record.
    mv -f "$pf" "$pf.superseded" 2>/dev/null || true
    setsid bash -c "$inner" </dev/null >>"$lf" 2>&1 &
    # Stamp the launch script's source hash as this service's running
    # version (issue #186) — the comparison anchor for the watcher's
    # version_check drift detection. Best-effort: a service whose
    # launch command has no trackable script file simply isn't
    # version-managed.
    _version_record_service_running "$STATE_DIR/version" "$name" "$workdir" "$launch" \
        2>/dev/null || true
    # SYNCHRONISE before returning. The pidfile is written by the CHILD; every
    # caller (svc.sh's reconcile, jupyter-up, remote-up) reads it immediately
    # after this returns. Returning without waiting is what made a successful
    # restart report `CANNOT RECONCILE` (your-org/nexus-code#918).
    if ! _recover_wait_pidfile "$pf"; then
        log "service '$name': supervisor did not write its pid record within ${NEXUS_RECOVER_PIDFILE_TIMEOUT}s (pidfile $pf) — treating the launch as FAILED. Check $lf."
        return 1
    fi
    return 0
}

# Decide + act for one service. Idempotent: relaunch ONLY when the
# service is unhealthy AND no live supervisor (pidfile) AND no legacy
# tmux window bears its name. A live supervisor or a present window
# (even if the healthcheck is briefly failing) is left to its own
# supervised-restart loop — relaunching it would orphan a duplicate.
# Prints a one-word outcome (healthy | healthy-unsupervised |
# supervisor-alive | window-present | workdir-missing | relaunched |
# launch-failed | dry-run-would-launch) for the caller's tally.
#
# `healthy-unsupervised` is NOT a flavour of healthy (your-org/nexus-code#606).
# A passing healthcheck proves something is SERVING; it says nothing about
# whether we still supervise it. When a PRESENT-but-dead supervisor record
# sits next to a green healthcheck, the daemon outlived its supervisor:
# nothing will restart it when it next dies, and no wrapper self-heal is
# left to defer to. Reporting that as plain `healthy` is the conflation
# that let an orphan sit undetected across a container restart. We still do
# not relaunch — a second supervisor on a bound port just fails EADDRINUSE
# forever — so this is a REPORTING fix; `svc.sh restart` does the bounce.
# Note the deliberate stale-vs-absent asymmetry: `absent` means nothing was
# ever recorded (externally managed, not yet migrated), which contradicts
# nothing and stays plain `healthy`.
recover_service() {
    local name="$1" workdir="$2" launch="$3" health="$4" logfile="${5:-}"
    if _recover_service_healthy "$workdir" "$health"; then
        _recover_supervisor_probe "$name" "$launch"
        if [[ "$_RECOVER_SUP_STATE" == stale:* ]]; then
            log "service '$name': healthcheck PASSES but the supervisor record is STALE (pid $_RECOVER_SUP_PID, $_RECOVER_STALE_REASON) — serving UNSUPERVISED; not relaunching (would collide with the live daemon). Reconcile: monitor/svc.sh restart '$name'"
            echo healthy-unsupervised; return 0
        fi
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
    # Alive states are not recovery's business (nexus-code#491):
    # bucket 1 = BUSY/aging (leave it alone), bucket 4 = WEDGED (the
    # supervisor Monitor + revive-watcher own the kill decision — a
    # cold-boot recovery must never kill a live process). Recovery
    # relaunches only when the watcher is established DEAD; the
    # launcher then also reaps any decapitated orphan group first.
    if (( rc == 1 || rc == 4 )); then
        log "watcher: $reason — alive; not relaunching from recovery"
        return 0
    fi
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
    #
    # Delimiter is '|', never a TAB (your-org/nexus-code#701 item A): in a
    # non-UTF-8 locale tmux rewrites every byte outside printable ASCII in
    # `-F` output to `_`, so a TAB-delimited row never split, `$3` never
    # matched, and this function became a silent no-op — the orchestrator was
    # simply never pinned, with nothing anywhere saying so. Not damage, but
    # not what it claims either. '|' is printable, so no locale rewrites it,
    # and validate_window_name forbids it inside a minted name.
    local line sess cur _name
    line=$(tmux list-windows -a -F '#{session_name}|#{window_index}|#{window_name}' 2>/dev/null \
           | awk -F'|' -v w="$target" '$3 == w { print; exit }')
    [[ -n "$line" ]] || return 0
    IFS='|' read -r sess cur _name <<<"$line"
    if [[ "$cur" == "$ORCH_WINDOW_INDEX" ]]; then
        log "orchestrator: already at canonical window index $ORCH_WINDOW_INDEX"
        return 0
    fi
    # Refuse to clobber a different window occupying the slot.
    local occupant
    # '|', not a TAB — same reason as above (your-org/nexus-code#701 item A).
    # Stated precisely: a locale that defeats THIS delimiter defeats the one
    # above too, and that one returns early, so the locale alone never reaches
    # here. Converted because the shape is wrong, not because a live path was
    # demonstrated — were it reachable, an unsplit row would leave `occupant`
    # empty and report a slot FREE that was never read, skipping the
    # clobber-refusal below.
    occupant=$(tmux list-windows -t "$sess" -F '#{window_index}|#{window_name}' 2>/dev/null \
               | awk -F'|' -v i="$ORCH_WINDOW_INDEX" '$1 == i { print $2; exit }')
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
    # your-org/nexus-code#1266. This set is an EXCLUSION, so an empty one is
    # PERMISSIVE: every registered service window would fall through to the
    # worker arms below and be treated as a dead worker to respawn or close.
    # `while … done < <(cmd)` DISCARDS cmd's rc, so the parser's 79 cannot be
    # seen at the loop — ask the predicate BEFORE it. Refusing the whole
    # worker step is the fail-CLOSED direction: not respawning workers for one
    # recovery pass is recoverable; mistaking eleven live services for dead
    # workers is not.
    if ! _recover_registry_readable "$SERVICES_REGISTRY"; then
        log "workers: REFUSED — registry at $SERVICES_REGISTRY exists and could not be READ."
        log "workers:   The service-name exclusion set would be EMPTY, so every registered"
        log "workers:   service window would classify as a dead worker. Not respawning anything."
        return 0
    fi
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

# --- cold boot: resurrect nothing, report everything ------------------------
#
# your-org/nexus-code#651. `./watcher` without `--continue` must be a cold
# boot of the WHOLE workspace, not just of the orchestrator. Before this,
# `entry.sh` archived the orchestrator session pin and then handed
# bring-up to us — and our worker walk, which knows nothing about the
# operator's flag, faithfully resurrected every worker that had been alive.
#
# That is not a cosmetic gap. On 2026-07-30 the sandbox died roughly every
# three minutes for a quarter of an hour; each death ran recovery, which
# brought back the very worker whose activity was killing the sandbox,
# which killed it again. Unconditional resurrection is an AMPLIFIER: it
# turns a single fault into a self-sustaining outage loop, and the
# operator's only escape hatch (boot cold) did not actually work.
#
# Three obligations on a cold boot, in order:
#   1. Resurrect nothing.
#   2. Lose nothing. The prior worker state is ARCHIVED, never deleted,
#      mirroring the pin's `.archived.<epoch>` convention.
#   3. Tell the orchestrator what it no longer has, in enough detail to
#      make a per-worker re-spawn decision — and put that where it will
#      actually be read (its turn-1 prompt), not only in a log.

# Archive a state file to `<path>.archived.<epoch>` — the pin convention,
# applied to whatever a cold boot has to stop honouring. Never deletes.
# Prints the archived path on stdout; returns 1 if there was nothing to
# archive or the rename failed (both non-fatal to the caller).
_recover_archive_state_file() {
    local path="$1" what="$2"
    [[ -e "$path" ]] || return 1
    local archived="$path.archived.$(date +%s)"
    if mv -f "$path" "$archived" 2>/dev/null; then
        log "$what: archived $(basename "$path") -> $(basename "$archived") (recoverable, never deleted)"
        printf '%s' "$archived"
        return 0
    fi
    log "$what: WARNING failed to archive $path — leaving it in place"
    return 1
}

# Resolve the operator's fresh-vs-continue boot intent. Sets COLD_BOOT and
# prints the verdict word (`fresh` | `continue` | `none` | `stale` |
# `malformed`) for the caller's messaging.
#
# The intent is ONE-SHOT and is consumed here, because we are not only the
# boot path: the SessionStart hook (`boot-recover.sh`), `bootstrap.sh`'s
# per-turn refresh and a manual `svc.sh up` all land in this same script,
# and every one of those is ordinary mid-life crash recovery where
# resuming workers is exactly right. An intent left on disk would convert
# all of them into worker massacres, so honouring it archives it.
#
# The TTL is the guard from the other side: an intent whose boot never
# reached the worker walk (bring-up aborted, instance guard refused) must
# expire rather than fire days later against an unrelated recovery. A
# real cold boot reaches us within seconds — `entry.sh` -> `svc.sh up` ->
# here — so the default 900 s is orders of magnitude of slack, and a
# stale intent degrades to today's resume behaviour, loudly.
#
# `--dry-run` resolves but never consumes: `boot-recover.sh` runs us as a
# pure health probe, and a probe that ate the boot intent would leave the
# real run resurrecting everything.
_recover_read_boot_intent() {
    COLD_BOOT=0
    [[ -f "$BOOT_INTENT_FILE" ]] || { printf none; return 0; }
    local mode='' ts='' line
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            mode=*) mode="${line#mode=}" ;;
            ts=*)   ts="${line#ts=}" ;;
        esac
    done < "$BOOT_INTENT_FILE"
    # A record without a usable timestamp falls back to the file's own
    # mtime rather than being trusted unconditionally.
    [[ "$ts" =~ ^[0-9]+$ ]] || ts=$(stat -c '%Y' "$BOOT_INTENT_FILE" 2>/dev/null \
                                    || stat -f '%m' "$BOOT_INTENT_FILE" 2>/dev/null || echo '')
    local age=-1
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
        age=$(( $(date +%s) - ts ))
    fi
    if (( age < 0 || age > BOOT_INTENT_TTL )); then
        log "boot-intent: IGNORING $BOOT_INTENT_FILE (mode=${mode:-?}, age=${age}s > ttl=${BOOT_INTENT_TTL}s) — a boot intent this old never reached its own worker walk; recovering normally"
        (( DRY_RUN == 0 )) && _recover_archive_state_file "$BOOT_INTENT_FILE" "boot-intent" >/dev/null
        printf stale; return 0
    fi
    case "$mode" in
        fresh)
            COLD_BOOT=1
            log "boot-intent: FRESH boot requested (${age}s ago, no --continue) — this run will resurrect NO worker agents"
            (( DRY_RUN == 0 )) && _recover_archive_state_file "$BOOT_INTENT_FILE" "boot-intent" >/dev/null
            printf fresh ;;
        continue)
            log "boot-intent: --continue boot (${age}s ago) — resuming prior worker agents as usual"
            (( DRY_RUN == 0 )) && _recover_archive_state_file "$BOOT_INTENT_FILE" "boot-intent" >/dev/null
            printf continue ;;
        *)
            log "boot-intent: malformed record at $BOOT_INTENT_FILE (mode='${mode}') — recovering normally"
            (( DRY_RUN == 0 )) && _recover_archive_state_file "$BOOT_INTENT_FILE" "boot-intent" >/dev/null
            printf malformed ;;
    esac
    return 0
}

# Most recent report filed for a window, relative to $NEXUS_ROOT, or empty.
#
# KEYED ON THE FRONTMATTER `window:` FIELD, NOT ON THE FILENAME
# (your-org/nexus-code#1195). An agent has TWO names: the report's filename
# carries a cwd-derived PROJECT SLUG (the first segment after the last
# `/work/` in `$PWD`), while `window:` is resolved from live tmux. On this
# corpus they disagree for 136 of 709 reports, and 21 windows are indexed
# under two or more slugs — so `-name "*${window}*.md"` was a SILENT ZERO on
# the cold-boot resumption surface, printing "(none found under reports/)"
# about a worker that had filed one. It errs the other way too: for one live
# window the name match returns 6 where the frontmatter says 3.
#
# rc 2 (COULD NOT LOOK) is propagated rather than folded into "none" — the
# caller has a third arm for it.
_recover_worker_last_report() {
    local window="$1" ng="$NEXUS_ROOT/monitor/ng" out rc=0
    [[ -x "$ng" ]] || return 2
    out=$("$ng" reports-for-window "$window" --reports-dir "$NEXUS_ROOT/reports" 2>/dev/null) || rc=$?
    (( rc == 0 )) || return "$rc"
    printf 'reports/%s\n' "$(basename -- "$(printf '%s\n' "$out" | head -1)")"
}

# One manifest entry for one dropped worker. Session-id and workdir come
# from the CANONICAL resolver — `spawn-worker.sh --resume <window>
# --dry-run`, which prints exactly what a real resume would have used and
# touches nothing — so the manifest can never disagree with the command it
# tells the orchestrator to run. An unresolvable worker is still listed,
# with the resolver's own diagnostic: "we dropped something we cannot
# describe" is the entry that most needs a human decision, and silently
# omitting it would be the same silence-as-absence failure this whole
# change exists to remove.
_recover_manifest_entry() {
    local window="$1" out rc session='' workdir='' report=''
    out=$("$SPAWN_WORKER_BIN" --resume "$window" --dry-run 2>&1)
    rc=$?
    printf '### `%s`\n\n' "$window"
    if (( rc == 0 )) && [[ "$out" == *"resolved:"* ]]; then
        session=$(sed -n 's/.*[[:space:]]session=\(.*\) workdir=.*/\1/p' <<<"$out" | head -1)
        workdir=$(sed -n 's/.*[[:space:]]workdir=\(.*\) jsonl=.*/\1/p' <<<"$out" | head -1)
        printf -- '- session-id: `%s`\n' "${session:-(unresolved)}"
        printf -- '- workdir: `%s`\n' "${workdir:-(unresolved)}"
    else
        printf -- '- session-id: **UNRESOLVED** (spawn-worker --dry-run exit %d)\n' "$rc"
        printf -- '- resolver said: `%s`\n' "$(tr '\n' ' ' <<<"$out" | cut -c1-300)"
    fi
    local report_rc=0
    report=$(_recover_worker_last_report "$window") || report_rc=$?
    # Deliberately an `if`, not `"${report:+…}${report:-…}"`. `${var:-alt}`
    # expands to the VALUE when the variable is set, so that pair fires BOTH
    # arms on a non-empty report and emits the path twice (your-org/nexus-code#651
    # skeptic, finding 4 — the same two-arm misreading as `#648`). It lands on
    # the one field that tells the orchestrator a dropped worker had already
    # finished, and a doubled path is a path an agent can mis-copy.
    if [[ -n "$report" ]]; then
        printf -- '- last report: `%s`\n' "$report"
    elif (( ${report_rc:-1} == 2 )); then
        # "I could not look" is not "there is none" (#1195, and #813/#618
        # before it). On the resumption surface the difference decides
        # whether an orchestrator re-spawns a worker that had already finished.
        printf -- '- last report: COULD NOT LOOK — the reports corpus was not enumerable\n'
    else
        printf -- '- last report: (none found under reports/)\n'
    fi
    printf -- '- re-spawn with: `monitor/spawn-worker.sh --resume %s`\n\n' "$window"
}

# Write the dropped-worker manifest. `$@` is the worker set the walk WOULD
# have resumed. `$1` of the globals: $2 is the archived snapshot path (may
# be empty) so the manifest names where its own evidence went.
#
# Any manifest already on disk is archived first, even when this boot
# drops nothing: an undelivered manifest from an earlier cold boot must
# never be read as a description of THIS one.
# Write the manifest. `$1` is the archived snapshot path (may be empty); the
# remaining args are the worker set the walk WOULD have resumed.
#
# The set is PARTITIONED by current tmux liveness, because a cold boot no
# longer implies an empty board (your-org/nexus-code#651 skeptic r2, finding 1).
# Before the liveness fix, reaching this code required no orchestrator window at
# all — in practice the tmux server had died and taken every worker with it, so
# "everything in the snapshot is gone" was true by construction. The liveness
# fix deliberately routes the tmux-SURVIVED crash shape here as well, and there
# every worker window is still running. Emitting them under "they are not
# running now" would hand the incoming orchestrator a confident falsehood about
# its own board, on turn 1, in precisely the scenario the fix exists to serve.
#
# Recovery never kills anything: declining to resurrect is not the same as
# terminating, so a live worker is left alone and simply reported as such.
_recover_write_dropped_manifest() {
    local archived_snapshot="$1"; shift
    local manifest; manifest=$(_dropped_manifest_path "$STATE_DIR")
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    [[ -e "$manifest" ]] && _recover_archive_state_file "$manifest" "dropped-manifest" >/dev/null
    (( $# > 0 )) || return 0

    # The SAME predicate entry.sh uses, from `_lib.sh` — not a second one, and
    # not a name check. `_recover_window_exists` would file a `remain-on-exit`
    # CORPSE worker under "still running", which is the exact misreading this
    # whole change exists to remove, just relocated. Composed per the
    # predicate's contract (`exists && has_live_agent`): its fail-safe answer
    # is LIVE, so asking it about a window that is gone would invert the
    # verdict. A corpse therefore lands in `gone`, correctly — dead work that
    # `--resume` can legitimately replace (spawn-worker kills a dead pane).
    local -a gone=() still=()
    local window
    for window in "$@"; do
        if _recover_window_exists "$window" && _nexus_window_has_live_agent "$window"; then
            still+=("$window")
        else
            gone+=("$window")
        fi
    done
    (( ${#gone[@]} + ${#still[@]} > 0 )) || return 0

    {
        if (( ${#gone[@]} > 0 )); then
            printf '# Cold boot dropped %d worker agent(s)\n\n' "${#gone[@]}"
        else
            printf '# Cold boot dropped no worker agents\n\n'
        fi
        printf 'The nexus was started **without `--continue`**, so this boot deliberately\n'
        printf 'resurrected nothing.\n\n'
        printf 'Nothing was deleted. '
        if [[ -n "$archived_snapshot" ]]; then
            printf 'The snapshot this was read from is archived at `%s`.\n\n' "${archived_snapshot#$NEXUS_ROOT/}"
        else
            printf 'The prior worker state is archived alongside it in the state dir.\n\n'
        fi

        if (( ${#gone[@]} > 0 )); then
            printf '## Dropped — these are NOT running\n\n'
            printf 'Alive in the last watcher snapshot, and a `--continue` boot WOULD have\n'
            printf 'resumed them. This is a list of work that stopped, not a list of windows\n'
            printf 'you have.\n\n'
            printf 'Decide per worker whether it should come back. Judge from its last report\n'
            printf 'and the issue it was working: some of this work is finished, some was\n'
            printf 'abandoned mid-task, and at least one of these agents may be why the\n'
            printf 'workspace went down. Resuming all of them is exactly the behaviour the\n'
            printf 'operator opted out of.\n\n'
            for window in "${gone[@]}"; do
                _recover_manifest_entry "$window"
            done
        fi

        if (( ${#still[@]} > 0 )); then
            printf '## Still running — untouched, and NOT dropped\n\n'
            printf 'These were in the snapshot too, but their windows are **alive right now**:\n'
            printf 'the orchestrator died without taking them with it. A cold boot declines to\n'
            printf 'RESURRECT; it never terminates a running agent, so recovery left them\n'
            printf 'exactly as they were.\n\n'
            printf 'Do NOT `--resume` these — `spawn-worker.sh --resume` exits 13 on a window\n'
            printf 'with a live pane. If you want one gone, retire it deliberately (see\n'
            printf '`skills/nexus.window-cleanup`); if you want it driven, paste a follow-up.\n\n'
            for window in "${still[@]}"; do
                printf -- '- `%s` — window alive; last report: %s\n' \
                    "$window" "$(_recover_worker_last_report "$window" || true)"
            done
            printf '\n'
        fi

        printf -- '---\n\n'
        printf 'Generated by `monitor/bootstrap-recover.sh` at %s (your-org/nexus-code#651).\n' "$(date -Is)"
    } > "$manifest" 2>/dev/null || {
        log "dropped-manifest: WARNING could not write $manifest — the orchestrator will not be told what was dropped"
        return 1
    }
    log "dropped-manifest: wrote $manifest (${#gone[@]} dropped, ${#still[@]} still alive) — delivered to the orchestrator on its first turn"
    return 0
}

# The cold-boot action itself: build the manifest from the worker set the
# walk would have resumed, then archive the snapshot that set came from.
#
# Archiving the snapshot is load-bearing, not tidiness. It is the ONLY
# input to `_recover_snapshot_workers`, so removing it closes the window
# between this boot and the watcher's first fresh snapshot (~one poll
# cycle) in which a SessionStart-triggered recovery — the very thing that
# fired every three minutes during the 2026-07-30 loop — could still read
# the pre-boot window list and resurrect the whole board anyway.
_recover_cold_boot_drop() {
    local -a dropped=()
    local name
    while IFS= read -r name; do
        [[ -n "$name" ]] && dropped+=("$name")
    done < <(_recover_snapshot_workers)

    if (( DRY_RUN == 1 )); then
        log "workers: cold boot — would DROP ${#dropped[@]} worker(s) and write the manifest (dry run: nothing archived)"
        return 0
    fi

    local archived=''
    archived=$(_recover_archive_state_file "$SNAPSHOT_FILE" "workers") || archived=''
    _recover_write_dropped_manifest "$archived" "${dropped[@]+"${dropped[@]}"}"

    if (( ${#dropped[@]} == 0 )); then
        log "workers: cold boot — nothing to drop (no qualifying worker in the last snapshot)"
    else
        # "candidate(s)" not "DROPPED": since the liveness fix routed the
        # tmux-survived crash shape here, some of these windows may still be
        # running and were therefore never dropped. The manifest writer logs
        # the authoritative dropped-vs-still-alive split right after this.
        log "workers: cold boot — resurrected none; ${#dropped[@]} snapshot candidate(s): ${dropped[*]}"
    fi
    return 0
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
            -h|--help)       sed -n '2,203p' "$0"; return 0 ;;
            *) echo "bootstrap-recover.sh: unknown flag: $1" >&2; return 1 ;;
        esac
    done

    if (( DO_WATCHER == 0 && DO_SERVICES == 0 )); then
        echo "bootstrap-recover.sh: --services-only combined with --no-services/--watcher-only recovers nothing — pick one" >&2
        return 1
    fi

    if (( LIST_ONLY == 1 )); then
        if ! _recover_registry_readable "$SERVICES_REGISTRY"; then
            # An empty listing at rc 0 is indistinguishable from "nothing is
            # registered" (your-org/nexus-code#1266). Say which, and exit
            # non-zero so a caller that tests the rc is not told "none".
            log "REFUSED: registry at $SERVICES_REGISTRY exists and could not be READ."
            log "  This listing is EMPTY because it could not be read, NOT because"
            log "  nothing is registered."
            return 79
        fi
        if [[ -e "$SERVICES_REGISTRY" ]]; then
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

        # Resolve the operator's boot intent, and on a cold boot do the
        # drop NOW — before the watcher relaunch (which would overwrite
        # the snapshot we are archiving) and before the orchestrator
        # spawn (whose situation report is where the manifest gets
        # delivered; it is composed the moment `recover_orchestrator`
        # runs, so a manifest written any later would miss turn 1).
        _recover_read_boot_intent >/dev/null
        if (( COLD_BOOT == 1 )); then
            _recover_cold_boot_drop
        fi
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
        if ! _recover_registry_readable "$SERVICES_REGISTRY"; then
            # Without this, the loop below saw zero rows and the summary line
            # printed "services: 0 registered — 0 healthy, 0 relaunched" — a
            # sentence that reads as a clean bill of health for a stack whose
            # registry could not be opened (your-org/nexus-code#1266).
            log "services: REFUSED — registry at $SERVICES_REGISTRY exists and could not be READ."
            log "services:   NOT recovering anything, and NOT reporting '0 registered':"
            log "services:   this is 'could not look', not 'nothing to do'."
        elif [[ ! -e "$SERVICES_REGISTRY" ]]; then
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
    elif (( COLD_BOOT == 1 )); then
        # The snapshot archive above already emptied the candidate set, so
        # this branch is belt AND braces: the refusal is stated in code
        # rather than left to depend on a file having been renamed.
        log "workers: cold boot (no --continue) — resurrecting nothing; see the dropped-worker manifest"
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
