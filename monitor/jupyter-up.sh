#!/usr/bin/env bash
# jupyter-up.sh — one-command, zero-config activation of a project-local
# JupyterLab as a supervised nexus service.
#
#   monitor/jupyter-up.sh [PROJECT_DIR] [OPTIONS]
#   monitor/jupyter-up.sh --root [WORKROOT] [OPTIONS]
#
# ROOT MODE (--root): ONE JupyterLab rooted at the nexus work root
# (default $NEXUS_ROOT/work) as the single service `jupyterlab`,
# with EVERY project's venv registered as its own kernelspec
# (`proj-<project>`) by jupyter-kernel-crawl.sh — run async at
# activation and re-run periodically by the supervisor, so new projects
# appear without re-activation. Idle kernelspecs cost nothing (a kernel
# only spawns on attach). This is the default answer to "give me a
# jupyter session"; per-project mode below remains for isolation.
# Project agents reach the root server via monitor/labsh-root.sh.
#
# Given just a project directory (default: $PWD), the activate path:
#   1. ensures a project kernel exists (`labsh kernel add` — idempotent:
#      reuses an existing ./.venv, creates one otherwise);
#   2. ensures a `jupyter-<project>` row in monitor/services.registry, so
#      bootstrap-recover.sh / svc.sh own the service from now on
#      (auto-revival on boot, cockpit row, start/stop/restart/logs verbs);
#   3. starts the supervisor (labsh-supervised.sh) through the SAME
#      idempotent decision path recovery uses — a healthy or already-
#      supervised service is left alone, never double-launched;
#   4. waits for the healthcheck to go green and prints the access URL
#      plus the agent quickstart (attach / exec / inspect).
# Re-running is always safe; "activate the service" = run this one thing.
#
# OPTIONS
#   --root        root mode (see above). Positional dir = the work root.
#                 Incompatible with --venv/--pkgs (the crawl owns kernels).
#   --port N      preferred port (persisted; labsh auto-increments if taken)
#   --ip ADDR     bind address for labsh start (e.g. 127.0.0.1; persisted)
#   --https       serve TLS with labsh's self-signed cert (persisted)
#   --venv DIR    register DIR/.venv (an EXISTING venv, e.g. Lmod-built)
#                 via `labsh kernel register --project DIR` instead of
#                 creating ./.venv. DIR is the directory CONTAINING
#                 .venv, not the .venv itself.
#   --pkgs "P.."  extra packages for `labsh kernel add` (first creation)
#   --no-start    register only (kernel + registry row); don't launch now
#   --down        deactivate: stop supervisor + server, REMOVE the
#                 registry row (no auto-revival until re-activated)
#   --status      one-line status; exit 0 iff healthy
#
# ENV (production leaves all unset; tests point these at fixtures)
#   NEXUS_ROOT, NEXUS_SERVICES_REGISTRY, NEXUS_STATE_DIR — as in
#       bootstrap-recover.sh (registry + pidfile locations). NEXUS_ROOT
#       defaults to THIS script's own checkout — invoking a secondary
#       clone's copy registers into that clone's registry, whose
#       recovery sweep is not the live one. For live services, run the
#       main clone's jupyter-up.sh.
#   LABSH_UP_TIMEOUT — seconds to wait for green health (default 180;
#       first activation builds venvs, so be patient on a cold cache)

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$_script_dir/.." && pwd)}"
export NEXUS_ROOT

# Recovery's primitives (recover_service, _recover_pidfile,
# _recover_service_running, STATE_DIR, SERVICES_REGISTRY): sourcing is
# side-effect-free, and reusing them is what makes activation and
# recovery one decision path instead of two that drift.
# shellcheck source=bootstrap-recover.sh
source "$_script_dir/bootstrap-recover.sh"

LAUNCH_BIN="$_script_dir/labsh-supervised.sh"
HEALTH_BIN="$_script_dir/jupyter-health.sh"
CRAWL_BIN="$_script_dir/jupyter-kernel-crawl.sh"
LABSH_ROOT_BIN="$_script_dir/labsh-root.sh"
UP_TIMEOUT="${LABSH_UP_TIMEOUT:-180}"
ROOT_SERVICE_NAME="jupyterlab"
# Pre-rename root-service name (PR 255): a registry written by older
# code may still carry this row; --root activation migrates it.
LEGACY_ROOT_SERVICE_NAME="jupyter-workroot"

die() { echo "jupyter-up: $*" >&2; exit 1; }
say() { echo "[jupyter-up] $*" >&2; }

# The whole header comment block is the help text; stopping at the
# first blank line keeps the range correct as the header grows.
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

# --- argument parsing -------------------------------------------------------
PROJECT_DIR=''
VERB=up
ROOT_MODE=0
OPT_PORT='' OPT_IP='' OPT_HTTPS=0 OPT_VENV='' OPT_PKGS='' NO_START=0
while (( $# > 0 )); do
    case "$1" in
        --root)     ROOT_MODE=1; shift ;;
        --port)     OPT_PORT="${2:?--port needs a value}"; shift 2 ;;
        --ip)       OPT_IP="${2:?--ip needs a value}"; shift 2 ;;
        --https)    OPT_HTTPS=1; shift ;;
        --venv)     OPT_VENV="${2:?--venv needs a value}"; shift 2 ;;
        --pkgs)     OPT_PKGS="${2:?--pkgs needs a value}"; shift 2 ;;
        --no-start) NO_START=1; shift ;;
        --down)     VERB=down; shift ;;
        --status)   VERB=status; shift ;;
        -h|--help)  usage; exit 0 ;;
        -*)         die "unknown option: $1 (try --help)" ;;
        *)          [[ -n "$PROJECT_DIR" ]] && die "more than one PROJECT_DIR given"
                    PROJECT_DIR="$1"; shift ;;
    esac
done
if (( ROOT_MODE )); then
    [[ -n "$OPT_VENV$OPT_PKGS" ]] && die "--root is incompatible with --venv/--pkgs (jupyter-kernel-crawl.sh owns root-session kernels)"
    PROJECT_DIR="${PROJECT_DIR:-$NEXUS_ROOT/work}"
else
    PROJECT_DIR="${PROJECT_DIR:-$PWD}"
fi
# Save the argument BEFORE the assignment (your-org/nexus-code#660, the
# rule from #642). A failed command substitution assigns the EMPTY STRING
# and only THEN runs the `||` arm, so reading `$PROJECT_DIR` there printed
# `project dir not found: ` with nothing after the colon — a refusal that
# does not say what it refused. Worse than it sounds: PROJECT_DIR defaults
# to $PWD (or $NEXUS_ROOT/work under --root), so in the common case the
# operator gets no argument on the command line to reconstruct it from.
#
# `CDPATH=` is the same defect one level down: a CDPATH in the operator's
# environment makes `cd <relative>` resolve against a search path nothing
# else consulted, so the directory entered is not the one checked.
#
# NB the `--venv` site in ensure_kernel below is already correct and must
# stay as it is — its `||` arm reports `$OPT_VENV`, a DIFFERENT variable
# the assignment does not touch. That the correct and the broken form sat
# twelve lines apart, looking alike, is why this survived review.
_ju_project_arg="$PROJECT_DIR"
PROJECT_DIR=$(CDPATH= cd "$_ju_project_arg" 2>/dev/null && pwd) \
    || die "project dir not found: $_ju_project_arg"

# --- registry helpers -------------------------------------------------------

# Service name: jupyter-<sanitized basename>, disambiguated with a short
# path hash when another project of the same basename is already
# registered. The name doubles as the registry/pidfile key and a
# potential tmux window name, so keep it to [A-Za-z0-9_.-].
_sanitize() { printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '-' | sed 's/^-*//; s/-*$//'; }
_path_hash() { printf '%s' "$1" | cksum | awk '{printf "%04x", $1 % 65536}'; }

# your-org/nexus-code#1266. Both lookups below read the parser through
# PROCESS SUBSTITUTION, which DISCARDS its rc — so an unreadable registry
# reaches them as ZERO ROWS and they answer "not registered". That answer is
# acted on: `service_name_for` then believes the name is free and registers a
# DUPLICATE, and `--down`/`--status` believe there is nothing to stop. This
# is an interactive operator command, so the honest move is to refuse rather
# than to guess. `_recover_registry_readable` comes from the sourced
# bootstrap-recover.sh; the contract is documented there.
# CALL THIS FROM THE MAIN SHELL, NEVER RELY ON IT INSIDE `$( )`.
#
# `die` is `exit 1`, and every caller of the two lookups below invokes them in
# a COMMAND SUBSTITUTION — `name=$(_registry_name_for_workdir …) || { … }`. An
# `exit` inside `$( )` terminates the SUBSHELL, not the script, so the caller's
# `||` arm simply runs and execution continues. Measured on this file before
# the entry-point gates were added: with an unreadable registry,
# `jupyter-up.sh --down` printed "no jupyter-* registry row … stopping any bare
# labsh server anyway" and exited **0** — i.e. the guard FIRED, wrote its
# refusal to stderr, and the refusal was DISCARDED, leaving exactly the
# your-org/nexus-code#1266 behaviour it was added to prevent.
#
# That is this issue's own defect class one level up: not a check that is
# missing, but a check whose verdict no caller can observe. The in-function
# calls below are retained as defence in depth; the LOAD-BEARING gates are the
# ones at the top of cmd_up / cmd_down / cmd_status, which run in the main
# shell where `die` actually exits.
_registry_must_be_readable() {
    _recover_registry_readable "$SERVICES_REGISTRY" && return 0
    die "registry at $SERVICES_REGISTRY exists and could NOT be READ. Refusing: every lookup would answer 'not registered', which would register a duplicate row or silently skip a running service. Fix its readability and re-run."
}

# Look up the registered workdir for a name ('' if absent).
_registry_workdir_of() {
    local name="$1" n w rest
    _registry_must_be_readable
    while IFS=$'\t' read -r n w rest; do
        [[ "$n" == "$name" ]] && { printf '%s' "$w"; return 0; }
    done < <(_recover_parse_registry "$SERVICES_REGISTRY")
    return 1
}

# Find the jupyter service name registered for a workdir ('' if none).
# Matches jupyter-<project> rows, the root service, and the legacy
# pre-rename root name (so --down/--status keep working on a registry
# written by older code).
_registry_name_for_workdir() {
    local dir="$1" n w rest
    _registry_must_be_readable
    while IFS=$'\t' read -r n w rest; do
        [[ "$w" == "$dir" ]] || continue
        if [[ "$n" == jupyter-* || "$n" == "$ROOT_SERVICE_NAME" ]]; then
            printf '%s' "$n"; return 0
        fi
    done < <(_recover_parse_registry "$SERVICES_REGISTRY")
    return 1
}

service_name_for() {
    local dir="$1" existing name
    if (( ROOT_MODE )); then
        # One root session per registry, under a fixed name.
        local w
        if w=$(_registry_workdir_of "$ROOT_SERVICE_NAME") && [[ "$w" != "$dir" ]]; then
            die "'$ROOT_SERVICE_NAME' is already registered for $w — one root session per registry (clean up $SERVICES_REGISTRY)"
        fi
        printf '%s' "$ROOT_SERVICE_NAME"; return 0
    fi
    # Already registered for this workdir? Reuse that name verbatim.
    if existing=$(_registry_name_for_workdir "$dir"); then
        printf '%s' "$existing"; return 0
    fi
    name="jupyter-$(_sanitize "$(basename "$dir")")"
    if _registry_workdir_of "$name" >/dev/null; then
        name="$name-$(_path_hash "$dir")"
        _registry_workdir_of "$name" >/dev/null \
            && die "service name collision even after hashing: $name (clean up $SERVICES_REGISTRY)"
    fi
    printf '%s' "$name"
}

# Atomically ensure the registry row (replace by name if present, else
# append). Serialized through flock when available so two concurrent
# activations can't interleave the rewrite.
ensure_registry_row() {
    local name="$1" workdir="$2" row
    printf -v row '%s\t%s\t%s\t%s\t%s' \
        "$name" "$workdir" "$LAUNCH_BIN" "$HEALTH_BIN" "$workdir/.jupyter/labsh-service.log"
    mkdir -p "$(dirname "$SERVICES_REGISTRY")"
    [[ -f "$SERVICES_REGISTRY" ]] || : > "$SERVICES_REGISTRY"
    _registry_rewrite() {
        local tmp
        tmp=$(mktemp "$SERVICES_REGISTRY.XXXXXX") || die "mktemp failed"
    # your-org/nexus-code#1266 (rewrite half). `awk … "$REG" > "$tmp"` FAILS
    # OPEN on an unreadable registry — rc 2, `$tmp` EMPTY — and the `mv` two
    # lines down then COMMITS that empty file over the operator's registry.
    # Nothing tests awk's rc (this script is `set -uo pipefail`, no `-e`), so
    # the function prints its success line and returns 0. Measured against an
    # 11-row registry at 85458bf8: `ensure` left 1 row, `remove` left 0, both
    # at rc 0 announcing success. That is strictly worse than the READ half of
    # this issue — it is permanent DATA DESTRUCTION, and afterwards every
    # reader legitimately reports "no services" because there genuinely are
    # none, so the manufactured success becomes self-consistent.
    #
    # The realistic driver is not chmod but a transient ESTALE/EIO on the
    # NFS-backed tree, where the DIRECTORY stays writable while the file read
    # fails — exactly the state in which `mv` succeeds.
    #
    # Read-then-write is not atomic here, so the rc of the READ is the only
    # thing standing between a transient fault and a destroyed registry.
        if ! awk -F'\t' -v name="$name" '$1 != name' "$SERVICES_REGISTRY" > "$tmp"; then
            rm -f "$tmp"
            die "registry at $SERVICES_REGISTRY exists and could not be READ (awk rc!=0) — REFUSING to rewrite it. Rewriting now would replace every existing row with just '$name'. Fix the registry's readability, then re-run."
        fi
        printf '%s\n' "$row" >> "$tmp"
        mv "$tmp" "$SERVICES_REGISTRY"
    }
    if command -v flock >/dev/null 2>&1; then
        ( flock -w 10 9 || exit 9; _registry_rewrite ) 9>>"$SERVICES_REGISTRY.lock" \
            || die "registry update failed (lock timeout or write error)"
    else
        _registry_rewrite
    fi
    say "registry: $name -> $workdir ($SERVICES_REGISTRY)"
}

remove_registry_row() {
    local name="$1" tmp
    [[ -f "$SERVICES_REGISTRY" ]] || return 0
    tmp=$(mktemp "$SERVICES_REGISTRY.XXXXXX") || die "mktemp failed"
    # your-org/nexus-code#1266 (rewrite half). `awk … "$REG" > "$tmp"` FAILS
    # OPEN on an unreadable registry — rc 2, `$tmp` EMPTY — and the `mv` two
    # lines down then COMMITS that empty file over the operator's registry.
    # Nothing tests awk's rc (this script is `set -uo pipefail`, no `-e`), so
    # the function prints its success line and returns 0. Measured against an
    # 11-row registry at 85458bf8: `ensure` left 1 row, `remove` left 0, both
    # at rc 0 announcing success. That is strictly worse than the READ half of
    # this issue — it is permanent DATA DESTRUCTION, and afterwards every
    # reader legitimately reports "no services" because there genuinely are
    # none, so the manufactured success becomes self-consistent.
    #
    # The realistic driver is not chmod but a transient ESTALE/EIO on the
    # NFS-backed tree, where the DIRECTORY stays writable while the file read
    # fails — exactly the state in which `mv` succeeds.
    #
    # Read-then-write is not atomic here, so the rc of the READ is the only
    # thing standing between a transient fault and a destroyed registry.
    if ! awk -F'\t' -v name="$name" '$1 != name' "$SERVICES_REGISTRY" > "$tmp"; then
        rm -f "$tmp"
        die "registry at $SERVICES_REGISTRY exists and could not be READ (awk rc!=0) — REFUSING to rewrite it. Rewriting now would TRUNCATE it to zero rows."
    fi
    mv "$tmp" "$SERVICES_REGISTRY"
    say "registry: removed row '$name'"
}

# --- kernel + opts ----------------------------------------------------------

_has_kernelspec() {
    compgen -G "$PROJECT_DIR/.jupyter/share/jupyter/kernels/*/kernel.json" >/dev/null 2>&1
}

# Root mode: kernels come from the crawl, not `labsh kernel add`.
# Persist the supervisor's periodic hook (re-crawl every
# LABSH_SVC_PERIODIC_EVERY probe intervals) and fire one crawl NOW,
# async — activation never blocks on N projects' venv registrations;
# the server picks up kernelspec files as they appear.
ensure_root_kernels() {
    mkdir -p "$PROJECT_DIR/.jupyter"
    {
        echo "# Auto-written by jupyter-up.sh --root; run async by labsh-supervised.sh."
        echo "# Re-registers new project venvs into the root session. Safe to edit/delete."
        printf 'exec %q %q\n' "$CRAWL_BIN" "$PROJECT_DIR"
    } > "$PROJECT_DIR/.jupyter/labsh-service.periodic"
    # Explicit mode at creation (your-org/nexus-code#484). `_ensure_service_log`
    # arrives with the bootstrap-recover.sh source above.
    _ensure_service_log "$PROJECT_DIR/.jupyter/labsh-periodic.log"
    ( "$CRAWL_BIN" "$PROJECT_DIR" >> "$PROJECT_DIR/.jupyter/labsh-periodic.log" 2>&1 & )
    say "kernel crawl launched (async; log: $PROJECT_DIR/.jupyter/labsh-periodic.log)"
}

ensure_kernel() {
    if [[ -n "$OPT_VENV" ]]; then
        local venv_abs
        venv_abs=$(cd "$OPT_VENV" 2>/dev/null && pwd) || die "--venv dir not found: $OPT_VENV"
        [[ -d "$venv_abs/.venv" ]] \
            || die "--venv: no .venv under $venv_abs — pass the directory CONTAINING .venv, not the .venv itself"
        say "registering existing venv: $venv_abs/.venv"
        ( cd "$PROJECT_DIR" && labsh kernel register --project "$venv_abs" ) \
            || die "labsh kernel register failed"
        return 0
    fi
    if _has_kernelspec; then
        say "kernel: already registered ($(cd "$PROJECT_DIR" && labsh kernel list 2>/dev/null | tr -d ' ' | paste -sd, -))"
        return 0
    fi
    say "kernel: none registered — running 'labsh kernel add'${OPT_PKGS:+ with: $OPT_PKGS}"
    # shellcheck disable=SC2086 — OPT_PKGS is a deliberate word-split list
    ( cd "$PROJECT_DIR" && labsh kernel add "$(basename "$PROJECT_DIR")" $OPT_PKGS ) \
        || die "labsh kernel add failed"
}

persist_opts() {
    local opts_file="$PROJECT_DIR/.jupyter/labsh-service.opts"
    local env_file="$PROJECT_DIR/.jupyter/labsh-service.env"
    mkdir -p "$PROJECT_DIR/.jupyter"
    if [[ -n "$OPT_IP" || "$OPT_HTTPS" == 1 ]]; then
        {
            echo "# extra 'labsh start' args, replayed by labsh-supervised.sh (one per line)"
            [[ -n "$OPT_IP" ]] && printf -- '--ip\n%s\n' "$OPT_IP"
            (( OPT_HTTPS )) && printf -- '--https\n'
        } > "$opts_file"
        say "persisted start opts: $(grep -v '^#' "$opts_file" | paste -sd' ' -)"
    fi
    if [[ -n "$OPT_PORT" ]]; then
        [[ "$OPT_PORT" =~ ^[0-9]+$ ]] || die "--port must be numeric"
        local scheme
        scheme=$(sed -n 's/^SCHEME=//p' "$env_file" 2>/dev/null | head -1)
        printf 'PORT=%s\nSCHEME=%s\n' "$OPT_PORT" "${scheme:-http}" > "$env_file"
        say "persisted preferred port: $OPT_PORT"
    fi
}

# --- supervisor stop (mirrors svc.sh's _stop_service semantics) -------------
stop_supervisor() {
    local name="$1" pf pid i
    pf=$(_recover_pidfile "$name")
    if ! _recover_service_running "$name" "$LAUNCH_BIN"; then
        [[ -f "$pf" ]] && { rm -f "$pf"; say "removed stale pidfile for $name"; }
        return 0
    fi
    # `[[ -r ]]` first: the redirection failure is the SHELL's, so this
    # `2>/dev/null` never reached it (#723). Latent here — the
    # `_recover_service_running` above means the pidfile is present — but the
    # #729 sweep fixed this shape in four readers and left three behind; a
    # rule applied to the sites you happened to touch is not applied.
    pid=""; [[ -r "$pf" ]] && read -r pid < "$pf"
    say "stopping supervisor pid $pid (TERM to its process group)"
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    for i in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        say "supervisor still alive after 5s — KILL"
        kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
        sleep 0.2
    fi
    rm -f "$pf"
}

# Rename migration: absorb a leftover legacy root row (jupyter-workroot)
# pointing at THIS workdir — stop its supervisor (a stale pidfile is
# just cleaned), drop the row, and let the normal activation path
# register + launch under the new name. A legacy row for a DIFFERENT
# workdir is left alone with a warning; never fatal either way.
migrate_legacy_root() {
    local w
    w=$(_registry_workdir_of "$LEGACY_ROOT_SERVICE_NAME") || return 0
    if [[ "$w" != "$PROJECT_DIR" ]]; then
        say "WARNING: legacy '$LEGACY_ROOT_SERVICE_NAME' row points at $w (not $PROJECT_DIR) — leaving it alone"
        return 0
    fi
    say "migrating legacy '$LEGACY_ROOT_SERVICE_NAME' row -> '$ROOT_SERVICE_NAME'"
    stop_supervisor "$LEGACY_ROOT_SERVICE_NAME"
    remove_registry_row "$LEGACY_ROOT_SERVICE_NAME"
}

# --- health wait -------------------------------------------------------------

# Wait for the service to become healthy, tolerating a slow first
# converge. First run on hpc-mount can build the labsh venvs slower than
# UP_TIMEOUT; the supervisor keeps retrying and the server comes up
# moments later. Failing the whole (idempotent) activation on that
# timeout makes the exit code contradict the eventual healthy state
# (your-org/nexus-code#313 item 3). So on timeout we re-probe once, then:
#   - supervisor alive  -> soft-succeed (the caller returns 0 without the
#                          ready banner); the supervisor will converge.
#   - supervisor dead   -> die (a genuine failure).
# Returns: 0 = healthy; 10 = timed out but converging (soft success);
# die()s (exit 1) when the supervisor is not running. Factored out of
# cmd_up so the timeout policy is unit-testable.
_await_health_or_converge() {
    local name="$1"
    say "waiting for healthy (timeout ${UP_TIMEOUT}s; first run builds venvs and can take a while)"
    local waited=0
    while ! "$HEALTH_BIN" "$PROJECT_DIR" >/dev/null 2>&1; do
        if (( waited >= UP_TIMEOUT )); then
            "$HEALTH_BIN" "$PROJECT_DIR" >/dev/null 2>&1 && return 0
            if _recover_service_running "$name" "$LAUNCH_BIN"; then
                # `[[ -r ]]` first — redirection failure is the SHELL's (#723).
                local sup_pid="" _spf; _spf=$(_recover_pidfile "$name")
                [[ -r "$_spf" ]] && read -r sup_pid < "$_spf"
                local recheck="monitor/jupyter-up.sh --status"
                (( ROOT_MODE )) && recheck="monitor/jupyter-up.sh --root --status"
                say "not healthy yet after ${UP_TIMEOUT}s, but the supervisor (pid ${sup_pid:-?}) is alive and still converging."
                say "  it should come up shortly; re-check with: $recheck"
                say "  (service log: $PROJECT_DIR/.jupyter/labsh-service.log)"
                return 10
            fi
            die "not healthy after ${UP_TIMEOUT}s and the supervisor is not running — check $PROJECT_DIR/.jupyter/labsh-service.log and .jupyter/labsh.bg.log"
        fi
        sleep 2; waited=$(( waited + 2 ))
        (( waited % 20 == 0 )) && say "  ...still waiting (${waited}s)"
    done
    return 0
}

# --- verbs -------------------------------------------------------------------

cmd_up() {
    # your-org/nexus-code#1266 — main-shell gate. See _registry_must_be_readable
    # for why the in-function guard cannot carry this on its own.
    _registry_must_be_readable
    command -v labsh >/dev/null 2>&1 \
        || die "labsh not on PATH — install via 'brew install operator/tools/labsh' or monitor/install-labsh.sh"
    command -v uv >/dev/null 2>&1 \
        || die "uv not on PATH — labsh needs it (curl -LsSf https://astral.sh/uv/install.sh | sh)"

    local name
    # service_name_for dies inside the $() subshell on a collision; the
    # || exit makes that fatal out here too instead of registering ''.
    name=$(service_name_for "$PROJECT_DIR") || exit 1
    if (( ROOT_MODE )); then
        migrate_legacy_root
        ensure_root_kernels
    else
        ensure_kernel
    fi
    persist_opts
    ensure_registry_row "$name" "$PROJECT_DIR"

    if (( NO_START )); then
        say "--no-start: registered only. Start later with: monitor/svc.sh start $name"
        return 0
    fi

    local outcome
    outcome=$(recover_service "$name" "$PROJECT_DIR" "$LAUNCH_BIN" \
        "$HEALTH_BIN" "$PROJECT_DIR/.jupyter/labsh-service.log")
    case "$outcome" in
        healthy|supervisor-alive|relaunched|window-present) ;;
        # Serving, but nothing supervises it (your-org/nexus-code#606) —
        # activation cannot claim success, and the fix is a reconcile, not a
        # relaunch on top of the live daemon.
        healthy-unsupervised)
            die "already serving but UNSUPERVISED (stale supervisor record) — reconcile first: monitor/svc.sh restart $name" ;;
        *) die "service launch failed (outcome: $outcome) — see $PROJECT_DIR/.jupyter/labsh-service.log" ;;
    esac

    local _hrc
    _await_health_or_converge "$name"; _hrc=$?
    # rc 10 = timed out but the supervisor is alive and converging — the
    # idempotent activation soft-succeeds rather than contradicting the
    # eventual healthy state with a non-zero exit (#313 item 3). rc 0 =
    # healthy; fall through and print the ready banner.
    (( _hrc == 10 )) && return 0

    local url
    url=$(cd "$PROJECT_DIR" && labsh url 2>/dev/null) || url='(run `labsh url` in the project)'
    if (( ROOT_MODE )); then
        cat <<EOF

  ROOT JupyterLab service '$name' is UP (rooted at $PROJECT_DIR).

  URL (with token):   $url
  Token file:         $PROJECT_DIR/.jupyter/token
  Service log:        $PROJECT_DIR/.jupyter/labsh-service.log
  Kernel crawl log:   $PROJECT_DIR/.jupyter/labsh-periodic.log

  Every project venv under $PROJECT_DIR/<project>/.venv is (being)
  registered as kernelspec 'proj-<project>'. New projects appear on the
  next periodic crawl, or on demand: $CRAWL_BIN $PROJECT_DIR

  Project-agent quickstart (run inside any $PROJECT_DIR/<project>):
    $LABSH_ROOT_BIN notebook attach analysis.ipynb --kernel-name proj-<project>
    $LABSH_ROOT_BIN kernel exec -n analysis.ipynb 'CODE'   # state persists
    $LABSH_ROOT_BIN kernel ps                              # running kernels

  Manage:
    monitor/svc.sh status | logs $name | restart $name
    monitor/jupyter-up.sh --root $PROJECT_DIR --down   # deactivate
EOF
        return 0
    fi
    cat <<EOF

  JupyterLab service '$name' is UP.

  URL (with token):   $url
  Token file:         $PROJECT_DIR/.jupyter/token
  Service log:        $PROJECT_DIR/.jupyter/labsh-service.log

  Agent quickstart (run inside $PROJECT_DIR):
    labsh notebook attach analysis.ipynb        # spawn/ensure a kernel
    labsh kernel exec -n analysis.ipynb 'CODE'  # state persists across calls
    labsh kernel inspect -n analysis.ipynb      # live variables
    labsh kernel ps                             # running kernels

  Manage:
    monitor/svc.sh status | logs $name | restart $name
    monitor/jupyter-up.sh $PROJECT_DIR --down   # deactivate
EOF
}

cmd_down() {
    # your-org/nexus-code#1266 — main-shell gate. Without it, an unreadable
    # registry reached the `||` arm below and exited 0 "no jupyter-* registry row".
    _registry_must_be_readable
    local name
    name=$(_registry_name_for_workdir "$PROJECT_DIR") || {
        say "no jupyter-* registry row for $PROJECT_DIR — stopping any bare labsh server anyway"
        ( cd "$PROJECT_DIR" && labsh stop ) 2>/dev/null || true
        return 0
    }
    stop_supervisor "$name"
    # Belt and braces: the group-TERM normally takes the server down with
    # the supervisor, but an adopted (human-started) server lives outside
    # that group — labsh stop covers it.
    ( cd "$PROJECT_DIR" && labsh stop ) >/dev/null 2>&1 || true
    remove_registry_row "$name"
    say "deactivated '$name' (no auto-revival until re-activated)"
}

cmd_status() {
    # your-org/nexus-code#1266 — main-shell gate. Without it, status reported
    # `(unregistered)` for a service it merely could not look up.
    _registry_must_be_readable
    local name health sup
    name=$(_registry_name_for_workdir "$PROJECT_DIR") || name='(unregistered)'
    if "$HEALTH_BIN" "$PROJECT_DIR" >/dev/null 2>&1; then health=healthy; else health=unhealthy; fi
    if [[ "$name" != '(unregistered)' ]] && _recover_service_running "$name" "$LAUNCH_BIN"; then
        # First line only. The pidfile is a three-line identity record
        # (pid / ns= / start=) since bcf9e3a; `cat` splattered all three into
        # this one-line status, stranding $PROJECT_DIR on a third line
        # (your-org/nexus-code#729, same reader defect as the one found in
        # test-jupyter-service.sh).
        # `[[ -r ]]` first: a redirection failure is the SHELL's, so a
        # `2>/dev/null` on `read` could not suppress it (#723).
        local _sp="" _pf; _pf=$(_recover_pidfile "$name")
        [[ -r "$_pf" ]] && read -r _sp < "$_pf"
        sup="pid:$_sp"
    else
        sup='-'
    fi
    echo "$name  $health  supervisor:$sup  $PROJECT_DIR"
    [[ "$health" == healthy ]]
}

# Dispatch only when executed, not when sourced (the test harness sources
# this file to unit-test _await_health_or_converge without running a verb).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$VERB" in
        up)     cmd_up ;;
        down)   cmd_down ;;
        status) cmd_status ;;
    esac
fi
