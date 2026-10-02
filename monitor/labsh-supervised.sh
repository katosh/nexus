#!/usr/bin/env bash
# labsh-supervised.sh — self-healing foreground supervisor for a
# project-local labsh JupyterLab. The jupyter-* analogue of
# serve-supervised.sh: this is what a services.registry row launches
# (headless, via bootstrap-recover.sh's setsid path) and what
# `monitor/svc.sh stop` TERMs.
#
#   Usage: labsh-supervised.sh [PROJECT_DIR]      (default: $PWD)
#
# Unlike serve-supervised.sh, the payload here daemonizes itself
# (`labsh start` backgrounds jupyter-lab), so this is a WATCHDOG rather
# than a restart-loop parent: probe jupyter-health.sh every INTERVAL
# seconds; after MAX_FAILS consecutive failures, bounce the server
# (`labsh stop` + `labsh start`). Because `labsh start` refuses to run
# when a live server already owns the project, the watchdog can never
# stack a second server — re-supervising a running project is a no-op,
# and a server the human started by hand is simply adopted.
#
# Port contract: the preferred port persists in
# <project>/.jupyter/labsh-service.env (PORT=/SCHEME=). labsh
# auto-increments when the preferred port is taken, so after every
# successful start the ACTUAL port is parsed from `labsh url` and
# written back — the healthcheck always probes where the server really
# listens. First-ever start with no env file picks a deterministic
# per-project default in 9700-9949 (path-hash spread, clear of 8888 and
# this operator's live 8765/8766/8731).
#
# Extra `labsh start` arguments (e.g. --https, --ip 127.0.0.1) persist
# one-per-line in <project>/.jupyter/labsh-service.opts; jupyter-up.sh
# writes that file, this wrapper replays it on every (re)start.
#
# Periodic hook: if <project>/.jupyter/labsh-service.periodic exists, it
# is run (as a bash script, ASYNC — never blocking the probe loop) once
# after the initial bring-up and again every LABSH_SVC_PERIODIC_EVERY
# probe intervals, with output to .jupyter/labsh-periodic.log. A still-
# running previous invocation is never overlapped. jupyter-up.sh --root
# writes this file to point at jupyter-kernel-crawl.sh; any service can
# use it for its own housekeeping.
#
# On SIGTERM/SIGINT (svc.sh stop sends TERM to the whole process
# group): run `labsh stop` so kernels and the server shut down
# gracefully, then exit 0.
#
# Env knobs (production leaves unset):
#   LABSH_SVC_INTERVAL  seconds between health probes      (default 15)
#   LABSH_SVC_FAILS     consecutive failures before bounce (default 3)
#   LABSH_SVC_PORT_BASE first-start port range base        (default 9700)
#   LABSH_SVC_PERIODIC_EVERY  probe intervals between periodic-hook
#                       runs (default 40 — every ~10 min at the
#                       default 15 s interval)

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HEALTH="$SCRIPT_DIR/jupyter-health.sh"

# `_ensure_service_log` (your-org/nexus-code#484). Side-effect-free on source.
# shellcheck source=_log-mode.sh
source "$SCRIPT_DIR/_log-mode.sh"

# Join the nexus-wide persistent uv toolchain. The registry launches this
# wrapper HEADLESS via bootstrap-recover's setsid path, with a bare env that
# sources neither ~/.bashrc nor locals-env.sh — so without this, uvx falls
# back to its tmpfs defaults (~/.local/share/uv, ~/.cache/uv). The sandbox
# masks $HOME as tmpfs, so every restart wipes that cache and forces a full
# CPython-3.12 + jupyterlab + extensions cold rebuild (minutes) that the
# supervisor's short start grace below then kills mid-flight — the recovery
# kill-loop. Sourcing locals-env.sh repoints UV_PYTHON_INSTALL_DIR /
# UV_CACHE_DIR / UV_TOOL_DIR at the persistent NFS tree under locals/uv, so a
# warm cache survives restarts and the cold rebuild happens at most once.
# Pure env, no side effects, safe + idempotent to source; self-locates
# NEXUS_ROOT from its own path, so our cwd (the project dir) is irrelevant.
[[ -f "$SCRIPT_DIR/locals-env.sh" ]] && . "$SCRIPT_DIR/locals-env.sh"

# Dangling-uv-cache repair (jacob-greene/nexus#98). `locals/uv/cache` — the
# cache the source above just pointed uv at — is a symlink into purgeable
# scratch. A purge removes the target, leaves the symlink dangling, and every
# uvx build then fails with a misleading `File exists (os error 17)`. That is
# exactly the 2026-08-25 JupyterLab service outage.
#
# The repair belongs HERE as well as in bootstrap-recover, because the two
# cover different paths. bootstrap-recover runs at COLD BOOT; this supervisor
# also restarts warm, on its own, long after any recovery sweep — and a purge
# can land in between. Without the guard on this path the restart policy
# retries the identical `labsh start` against the identical broken symlink and
# burns all three attempts, which is what happened in the incident.
#
# Sourcing only defines the function; the call site is in `_start_cycle`,
# beside the other pre-start self-heals.
# shellcheck source=uv-cache-guard.sh
[[ -f "$SCRIPT_DIR/uv-cache-guard.sh" ]] && . "$SCRIPT_DIR/uv-cache-guard.sh"

# ── in-UI Extension Manager + baseline labextensions (LABSH_WITH) ──────────
# JupyterLab 4's Extension Manager (the puzzle-piece panel) shells out to `pip`
# in the SERVER env to install extensions; a uvx-built server env has no pip, so
# the panel is disabled out of the box. labsh's server-env build honours two
# levers (katosh/labsh: `pip` in its baseline + the LABSH_WITH seam):
#   * `pip` in labsh's baseline WITH_ARGS → the Extension Manager UI works.
#   * LABSH_WITH → extra `--with` packages baked into the build. We use it to
#     pre-install the code-formatter stack so it is available out of the box.
# labsh adds these to its OWN `uvx --from jupyterlab … jupyter-lab` call, so the
# mechanism is immune to nexus PATH ordering (the BASH_ENV/ZDOTDIR force-front
# that re-asserts locals/bin can't defeat an argument labsh itself supplies).
#
# Requires a labsh that carries the pip-baseline + LABSH_WITH seam. On an older
# labsh that predates it, this export is simply ignored (harmless, forward-
# compatible) and the packages appear once the live labsh is updated.
#
# AI assistant: the Claude Code CLI is reachable from the Lab **Terminal** (it
# is on the inherited PATH) — the no-API-key in-Lab Claude assistant. jupyter-ai
# is intentionally NOT in the default list: its current (v3) release hijacks core
# JupyterLab 4.6 plugins with an incompatible RTC stack. To opt in to the
# graphical chat, append a pinned 2.x and provide a key, e.g.
#   LABSH_WITH="jupyterlab-code-formatter black isort jupyter-ai>=2.31,<3 langchain-anthropic"
# plus ANTHROPIC_API_KEY in the service environment (never commit a key).
export LABSH_WITH="${LABSH_WITH:-jupyterlab-code-formatter black isort}"

PROJECT_DIR="${1:-$PWD}"
PROJECT_DIR=$(cd "$PROJECT_DIR" 2>/dev/null && pwd) || {
    echo "[$(date -Is)] labsh-svc: FATAL: project dir not found: ${1:-$PWD}" >&2
    exit 1
}
cd "$PROJECT_DIR"

ENV_FILE=".jupyter/labsh-service.env"
OPTS_FILE=".jupyter/labsh-service.opts"
PERIODIC_FILE=".jupyter/labsh-service.periodic"
PERIODIC_LOG=".jupyter/labsh-periodic.log"
# Where `labsh start` records the pid of the backgrounded `uvx … jupyter-lab`
# build (labsh's own BG_PID_FILE = <project>/.jupyter/labsh.bg.pid). We read
# it in reap_stale_builds to kill a build that never bound.
BG_PID_FILE=".jupyter/labsh.bg.pid"
INTERVAL="${LABSH_SVC_INTERVAL:-15}"
MAX_FAILS="${LABSH_SVC_FAILS:-3}"
PORT_BASE="${LABSH_SVC_PORT_BASE:-9700}"
PERIODIC_EVERY="${LABSH_SVC_PERIODIC_EVERY:-40}"
# THE PERIODIC HOOK IS BOUNDED. It ran ASYNC behind an overlap guard and nothing
# else, so a hook that genuinely HANGS would disable itself for good and say so
# only as one quiet line per round.
#
# CORRECTED: this bound was first written as the fix for "a hook that hung ~14 h"
# on the live service. THERE WAS NO HANG — see `_periodic_in_flight` below: the
# hook had finished, its pid was recycled as a THREAD id, and the old `kill -0`
# overlap guard skipped every round after. The bound stays because a hang is
# still possible and an unbounded async child is still wrong; it is NOT what
# fixes the incident that prompted it.
#
# WE CHOSE 3600 s. The hook fires every PERIODIC_EVERY x INTERVAL (40 x 15 s =
# 10 min) and is a kernel crawl that may build a venv, so minutes are
# legitimate and an hour is not. (It was first justified as "small beside the
# 14 h it replaces"; there was no 14 h hang — see the correction above.)
# `LABSH_SVC_PERIODIC_TIMEOUT=0` disables the bound.
PERIODIC_TIMEOUT="${LABSH_SVC_PERIODIC_TIMEOUT:-3600}"
[[ "$PERIODIC_TIMEOUT" =~ ^[0-9]+$ ]] || PERIODIC_TIMEOUT=3600
# Seconds to wait for the server to become HEALTHY after `labsh start`
# (NOT merely to expose a URL — see start_server). This window must cover a
# *cold* ephemeral `uvx` build on the first start after a version drift or a
# cache/page-cache wipe: uv re-resolves the unpinned jupyterlab set (a network
# index revalidation, ~40s) and then MATERIALISES ~96 packages / thousands of
# files into a fresh env on the NFS-backed uv cache. Even with UV_LINK_MODE=
# hardlink (locals-env.sh — no data copy, metadata only) that materialisation
# is minutes of NFS metadata ops on a loaded node; once the env lands in
# uv/cache/environments-v2 the NEXT boot reuses it in seconds. This grace must
# outlast that ONE-TIME rebuild so the watchdog can't bounce an in-progress
# bring-up (the kill-loop that fed incident #33). 900s (15 min) covers a slow
# loaded-node rebuild with margin; steady-state warm boots finish in seconds
# and never approach it. Pair with monitor.service_health.restart_cooldown_
# seconds (config/nexus.yml) ≥ this so the WATCHER can't interrupt either.
# Old value was 300s — too short for the reflink→copy fallback that caused #33.
START_GRACE="${LABSH_SVC_START_GRACE:-900}"
# A TOKEN ROTATED DURING THE START WAIT IS NOT "STILL COMING UP"
# (your-org/nexus-code#1584). `start_server` waits up to START_GRACE for a
# PASSING healthcheck and counts no strikes while it waits. That is right for a
# warming server — and a warming server may legitimately answer 403 while it
# imports extensions, which is the restart-flap test-jupyter-service.sh pins:
# such a server is WAITED OUT, never bounced. This change does not touch that.
#
# What it adds is the one case where waiting can never help. jupyter-health.sh
# re-reads `.jupyter/token` on every probe and exits 22 when the server answers
# 4xx. If the token FILE has changed since this start began, the running server
# holds the OLD token: the mismatch is certain, it is permanent, and the
# watchdog that would fix it is not running because this loop has not returned.
#
# Measured 2026-09-19: a token rotated just after a bounce left the service
# unhealthy for the whole wait — 403 on every probe for 300 s (the test's
# ceiling; this loop would have held for 900), the supervisor log SILENT after
# "serving at", where an ordinary server kill healed in 17 s. It is a RACE:
# whoever polls the fresh server first wins, and if that is a caller who then
# rotates the token, this loop never sees a green. It reddened
# test-jupyter-service-real.sh in two consecutive full bands and ~1 isolated run
# in 4, and was filed as a deadline that was too short.
#
# THE DISCRIMINATOR IS THE TOKEN, NOT THE STATUS CODE. rc 22 ALONE was the
# first design and would have bounced the warming server above. rc 22 AND a
# token that differs from the one this start began with cannot be a warm-up.
#
# BOTH NUMBERS ARE CHOSEN, not inherited:
#   REJECT_PROBES  4 consecutive qualifying probes at the loop's 0.5 s step,
#       ~2 s: enough that a rotation caught mid-write is not acted on.
#   REJECT_BAILS   3, a backstop. A rotation cannot loop by itself — the
#       bounced server reads the new token and the comparison resets — but a
#       bound that costs one integer is cheaper than being wrong about that.
#       After 3 fast bails in a row the loop waits the FULL grace, as before;
#       any healthy probe restores the budget.
REJECT_PROBES="${LABSH_SVC_REJECT_PROBES:-4}"
REJECT_BAILS_MAX="${LABSH_SVC_REJECT_BAILS:-3}"
# VALIDATED, with a FLOOR OF 1 (skeptic testinfra2sk F3 on PR 1593). `0` or a
# non-number made `rejected >= REJECT_PROBES` true on the FIRST probe, and an
# unset-looking knob then bounced a warming server at once — the restart flap,
# reached through a typo. PERIODIC_TIMEOUT was validated and these were not.
[[ "$REJECT_PROBES" =~ ^[0-9]+$ ]] && (( REJECT_PROBES >= 1 )) || REJECT_PROBES=4
[[ "$REJECT_BAILS_MAX" =~ ^[0-9]+$ ]] || REJECT_BAILS_MAX=3
REJECT_BAILS=0

log() { echo "[$(date -Is)] labsh-svc: $*"; }

# ── labsh self-heal (incident your-org/other-nexus#103, extended) ──────────
# labsh's runtime (binary + helper venv) and its shim can both disappear from
# under the running supervisor. The #103 fix targeted the FIRST of two disjoint
# wipe surfaces; this extension covers the second.
#
#   * dangling-shim wipe (#103):
#     shim ~/.local/bin/labsh persists (bind-mounted from outside the sandbox)
#     while lib target ~/.local/lib/labsh/bin/labsh rides the ephemeral
#     --tmpfs HOME overlay and gets wiped on every sandbox restart.
#     `labsh_dangling` catches this; `reinstall_labsh` used to write into
#     ~/.local/lib via `make install-lib`.
#   * shim-missing wipe (this fix):
#     if the outside operator's ~/.local/bin/labsh is itself gone (never
#     installed there, removed by a ~/.local cleanup between sandbox runs, or
#     ~/.local shadowed at bwrap-mount time), `command -v labsh` returns
#     empty at supervisor startup. There is no shim to dangle-detect, and
#     the pre-#103 hard FATAL then killed the supervisor before any self-heal
#     could run. Additionally, ~/.local/bin AND ~/.local/lib are both
#     read-only from inside this sandbox (bwrap --ro-bind on ~/.local/bin, no
#     writable overlay on ~/.local/lib), so `make install-lib` cannot repair
#     either surface from in-sandbox — the #103 heal target itself is unreachable.
#
# `reinstall_labsh` therefore installs into $NEXUS_LOCALS/{bin,lib}/labsh
# instead of ~/.local — the nexus-managed tool tree that is
# WRITABLE from inside the sandbox, PERSISTENT across restarts (lives on
# /shared, not $HOME), and already on PATH via monitor/locals-env.sh (which
# this wrapper sources up top). Ephemeral-HOME wipes cannot touch it, so a
# healed labsh survives the next sandbox restart without re-healing.
#
# We also force-front $NEXUS_LOCALS/bin in PATH so a stale dangling shim
# lingering in ~/.local/bin (from a previous outside-sandbox install) cannot
# shadow the fresh nexus copy — the sandbox typically has ~/.local/bin ahead
# of $NEXUS_LOCALS/bin in PATH, and locals-env.sh's idempotent prepend is a
# no-op when locals/bin already appears anywhere in PATH.
#
# Same #103 contract: non-degrading (reinstalls the SAME pinned source; never
# vendors or bumps labsh), reversible (git revert of this commit removes only
# the self-heal), loop-guarded (at most one reinstall attempt per start cycle).

# NEXUS_ROOT = the parent of monitor/ (this wrapper is $NEXUS_ROOT/monitor/…).
# locals-env.sh resolves but does not export it, so derive it from SCRIPT_DIR.
NEXUS_ROOT=$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)
NEXUS_LOCALS_DIR="${NEXUS_LOCALS:-$NEXUS_ROOT/locals}"

# Force-front NEXUS_LOCALS/bin so a stale ~/.local/bin/labsh shim (bind-mounted
# read-only from outside the sandbox and pointing at a wiped ~/.local/lib
# target) cannot shadow the fresh nexus install. locals-env.sh's own prepend
# is idempotent — it no-ops when NEXUS_LOCALS/bin is already anywhere in PATH,
# even if buried behind ~/.local/bin. This re-assertion is scoped to the
# supervisor process; it does not leak into the operator's shells. Called
# again by reinstall_labsh() after a fresh install so a first-time-created
# NEXUS_LOCALS/bin (absent at supervisor startup) still front-loads.
front_locals_bin() {
    [[ -d "$NEXUS_LOCALS_DIR/bin" ]] || return 0
    case ":$PATH:" in
        ":$NEXUS_LOCALS_DIR/bin:"*) : ;;   # already at front
        *)
            local pruned=":${PATH}:"
            pruned="${pruned//:$NEXUS_LOCALS_DIR\/bin:/:}"
            pruned="${pruned#:}"
            pruned="${pruned%:}"
            export PATH="$NEXUS_LOCALS_DIR/bin:$pruned"
            ;;
    esac
    hash -r 2>/dev/null || true
}
front_locals_bin

# First labsh source tree (a katosh/labsh checkout whose Makefile has the
# install-lib target we replay inline) among the operator's known locations.
# repos/labsh is where this operator's manual clone + the incident recovery
# lived; work/labsh is where monitor/install-labsh.sh clones, so it is the
# portable default for operators without a repos/labsh. Prints the path;
# empty (rc 1) if none found.
labsh_src_dir() {
    local d
    for d in "$NEXUS_ROOT/repos/labsh" \
             "${SANDBOX_PROJECT_DIR:-$NEXUS_ROOT}/work/labsh" \
             "$NEXUS_ROOT/work/labsh"; do
        if [[ -f "$d/Makefile" ]] && grep -q '^install-lib:' "$d/Makefile" 2>/dev/null; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    return 1
}

# Resolve the lib target the `labsh` shim execs to (an ~/.local/lib/labsh/bin
# or $NEXUS_LOCALS/lib/labsh/bin path). Empty when labsh is not a thin
# exec-shim (e.g. a brew-installed real binary) — in that case we never
# second-guess its presence.
labsh_lib_target() {
    local shim
    shim=$(command -v labsh 2>/dev/null) || return 1
    [[ -r "$shim" ]] || return 1
    sed -nE 's/^[[:space:]]*exec[[:space:]]+"?([^"[:space:]]+)"?.*/\1/p' "$shim" | head -1
}

# True iff labsh is entirely absent from PATH (no shim, no binary).
labsh_missing() { ! command -v labsh >/dev/null 2>&1; }

# True iff labsh is a DANGLING shim: the shim resolves on PATH but the lib
# target it execs is gone (the #103 wipe). A non-shim labsh (no parseable
# target) is never treated as dangling.
labsh_dangling() {
    local tgt
    tgt=$(labsh_lib_target) || return 1
    [[ -n "$tgt" && ! -x "$tgt" ]]
}

# True iff labsh needs a self-heal reinstall this cycle — either entirely
# missing or a dangling shim. Distinct from labsh_dangling so start_server can
# still log the two conditions separately.
labsh_needs_install() { labsh_missing || labsh_dangling; }

# Reinstall the pinned labsh from source into $NEXUS_LOCALS/{bin,lib}/labsh.
# Replays the Makefile's install-lib + install-bin targets inline so the
# destination is nexus-controlled (writable from inside the sandbox, on PATH,
# persistent across HOME overlay resets) rather than the ~/.local prefix the
# Makefile bakes in via PREFIX. Guarded to at most one attempt per start
# cycle (REINSTALL_ATTEMPTED, reset in start_server) so a persistently-failing
# reinstall can never spin. Returns 0 on success.
REINSTALL_ATTEMPTED=0
reinstall_labsh() {
    if (( REINSTALL_ATTEMPTED )); then
        log "labsh reinstall already attempted this start cycle — not retrying (loop guard)"
        return 1
    fi
    REINSTALL_ATTEMPTED=1
    local src out rc _l lib bin
    src=$(labsh_src_dir) || {
        log "ERROR: cannot self-heal labsh — no labsh source tree found (looked under $NEXUS_ROOT/repos/labsh, work/labsh)"
        return 1
    }
    lib="$NEXUS_LOCALS_DIR/lib/labsh"
    bin="$NEXUS_LOCALS_DIR/bin"
    log "self-heal: reinstalling labsh from $src into $NEXUS_LOCALS_DIR (bin+lib)"
    out=$(
        set -e
        install -d "$lib/bin" "$bin"
        install -m 755 "$src/bin/labsh"           "$lib/bin/labsh"
        install -m 755 "$src/bin/_labsh_kernel.py" "$lib/bin/_labsh_kernel.py"
        install -m 644 "$src/VERSION"             "$lib/VERSION"
        # Shim mirrors the Makefile's install-bin: exec into the lib target so
        # SCRIPT_DIR resolves to $lib/bin, independent of how the shim was found.
        printf '#!/bin/sh\nexec "%s/bin/labsh" "$@"\n' "$lib" > "$bin/labsh"
        chmod 755 "$bin/labsh"
    ) 2>&1
    rc=$?
    while IFS= read -r _l; do [[ -n "$_l" ]] && log "  install: $_l"; done <<<"$out"
    # Ensure the freshly-created $NEXUS_LOCALS/bin fronts PATH — supervisor
    # startup may have skipped that when the dir did not yet exist.
    front_locals_bin
    if (( rc == 0 )) && command -v labsh >/dev/null 2>&1; then
        log "self-heal: labsh reinstall OK ($(command -v labsh))"
        return 0
    fi
    log "ERROR: self-heal labsh reinstall FAILED rc=$rc"
    return 1
}

# If labsh isn't on PATH at supervisor startup, try the self-heal ONCE before
# FATAL'ing. Covers the shim-missing wipe (see block comment above) — the
# pre-#103 hard FATAL here killed the supervisor before the pre-start
# dangle-check in start_server got a chance to run, so a missing shim was
# unrecoverable without a human. Post-heal, re-check PATH so a self-heal that
# claimed success but did not actually produce a callable labsh still fails
# loud instead of silently proceeding to a broken start_server.
if labsh_missing; then
    log "labsh not on PATH — self-healing before supervisor start (extends your-org/other-nexus#103)"
    reinstall_labsh || true
fi
command -v labsh >/dev/null 2>&1 || {
    log "FATAL: labsh not on PATH — self-heal did not produce a callable binary; install via 'brew install katosh/tools/labsh' or monitor/install-labsh.sh"
    exit 1
}

# THE PERIODIC HOOK'S PROCESS GROUP IS REAPED ON TERM (skeptic testinfra2sk F1
# on PR 1593, MEASURED). `svc.sh stop` — and so every restart, including the
# source-drift one — TERMs THIS supervisor's process group. But `timeout` makes
# ITSELF a process-group leader, so a bounded hook LEAVES that group: measured,
# after a group TERM the old unbounded form's hook died and the bounded form's
# `timeout` + hook SURVIVED, reparented to init, for up to the whole bound —
# holding `.crawl.lock`, so the NEW supervisor's crawls exit "another crawl
# holds". The bound then also stopped a restart from curing the very hang it
# exists for. It is your-org/nexus-code#1585's defect, reintroduced by the fix
# for a neighbouring one.
#
# IDENTITY BEFORE SIGNAL. The pid comes from a file, and pids recycle: it must
# still be a `timeout`, still lead its OWN group, and still sit in THIS project
# directory. Not its ppid — the group TERM kills the wrapping subshell first, so
# by the time this runs the `timeout` is already reparented to init.
PERIODIC_PGID_FILE=".jupyter/labsh-periodic.pgid"
_reap_periodic_group() {
    local t st pg
    t=$(cat "$PERIODIC_PGID_FILE" 2>/dev/null) || return 0
    [[ "$t" =~ ^[0-9]+$ ]] || return 0
    [[ "$(cat "/proc/$t/comm" 2>/dev/null)" == timeout ]] || return 0
    # PHYSICAL against PHYSICAL: /proc/<pid>/cwd is always resolved, while
    # $PROJECT_DIR came from a logical `pwd`. Compared as written, a project
    # reached through a symlink would fail this check and the hook would
    # survive — fail-safe, and a silent defeat of the fix on exactly such hosts.
    [[ "$(readlink "/proc/$t/cwd" 2>/dev/null)" == "$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)" ]] || return 0
    { IFS= read -r st < "/proc/$t/stat"; } 2>/dev/null || return 0
    st=${st##*) }; read -r _ _ pg _ <<<"$st"
    [[ "$pg" == "$t" ]] || return 0
    log "stopping ${1:-the in-flight periodic hook} (process group $t) — it is outside this supervisor's group and would outlive it"
    kill -TERM -- "-$t" 2>/dev/null || true
    rm -f "$PERIODIC_PGID_FILE"
}
on_term() {
    log "signal received — stopping labsh server, exiting"
    _reap_periodic_group
    labsh stop >/dev/null 2>&1 || true
    exit 0
}
trap on_term TERM INT

# Deterministic per-project first-start port: spread projects across
# PORT_BASE..PORT_BASE+249 by path hash so two activated projects rarely
# even ask for the same port (labsh auto-increment covers the rest).
default_port() {
    local crc
    crc=$(printf '%s' "$PROJECT_DIR" | cksum | awk '{print $1}')
    echo $(( PORT_BASE + crc % 250 ))
}

# Replay persisted extra `labsh start` args. One arg per line; blank
# lines and #-comments skipped.
read_opts() {
    OPTS=()
    [[ -f "$OPTS_FILE" ]] || return 0
    local l
    while IFS= read -r l || [[ -n "$l" ]]; do
        [[ "$l" =~ ^[[:space:]]*(#|$) ]] && continue
        OPTS+=("$l")
    done < "$OPTS_FILE"
}

# Persist the RUNNING server's scheme+port from `labsh url` (which reads
# the live jpserver-*.json). Returns nonzero while no live server is up.
persist_env_from_url() {
    local url scheme port
    url=$(labsh url 2>/dev/null) || return 1
    scheme="${url%%://*}"
    port=$(sed -E 's#^[a-z]+://[^/:]+:([0-9]+)/.*#\1#' <<<"$url")
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    case "$scheme" in http|https) ;; *) return 1 ;; esac
    mkdir -p .jupyter
    printf 'PORT=%s\nSCHEME=%s\n' "$port" "$scheme" > "$ENV_FILE"
    # Never log the tokenized URL (this log may be world-readable).
    log "serving at $scheme://127.0.0.1:$port (token: $PROJECT_DIR/.jupyter/token)"
}

# Reap a stray jupyter server squatting our preferred port. The recovery
# path can leave an orphan: when a supervisor is replaced but its child uvx
# jupyter survives (reparented to init), it keeps the port — the next
# `labsh start` then collides, auto-increments to a different port, and we
# end up with two servers on drifted ports (the idempotency gap that turned
# this incident's restart into port contention). Surgical: only a process
# WE can see listening on $port (ss shows process info for own-uid sockets
# only) AND whose cmdline is a jupyter process is killed — never a foreign
# listener. Best-effort; absence of ss is not fatal.
reap_port_orphan() {
    local port="$1" line pid cmd
    command -v ss >/dev/null 2>&1 || return 0
    while IFS= read -r line; do
        pid=$(grep -oE 'pid=[0-9]+' <<<"$line" | head -1 | cut -d= -f2)
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        # `{ …; } 2>/dev/null` — redirection ORDER (your-org/nexus-code#1305).
        cmd=$( { tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null )
        case "$cmd" in
            *jupyter*)
                log "reaping orphan jupyter (pid $pid) squatting port $port before start"
                kill "$pid" 2>/dev/null || true
                ;;
        esac
    done < <(ss -ltnpH 2>/dev/null | awk -v p=":$port\$" '$4 ~ p')
}

# Reap an unfinished labsh *build* left holding the persistent NFS uv lock.
# labsh backgrounds `uvx --from jupyterlab … jupyter-lab` and records its pid
# in .jupyter/labsh.bg.pid, but that uvx reparents to init the instant
# `labsh start` returns — so `labsh stop`, which only shuts down a *bound*
# jupyter server, never reaps a build that was TERM'd or bounced BEFORE it
# bound the port (a restart-storm mid-cold-boot, or our own MAX_FAILS
# bounce). Such an orphan keeps an exclusive lock on the uv cache/tool tree
# under locals/uv; the NEXT uvx then blocks silently on that lock, writes
# NOTHING to labsh.bg.log, and never binds within START_GRACE — orphans pile
# up and the service flaps forever (incident your-org/other-nexus#33). So
# before every (re)start, kill our own not-yet-bound build(s) that are PAST
# THEIR BUDGET.
#
# The original predicate (#450) claimed to be "surgical: only OUR uid, only a
# cmdline that is a uvx/jupyter-lab on OUR preferred port". It was not. It
# matched on argv substrings, so it selected any process whose command line
# merely MENTIONED `jupyter-lab` — including other agents' shells — and its
# bg.pid branch accepted a bare `*uvx*` with no port and no age, so a recycled
# pid landing on an unrelated `uv tool uvx …` (the zotero MCP server, here)
# was killed too. It also had no age gate at all, so a build that started
# seconds ago was indistinguishable from a genuine orphan. It decided a build
# was stale without ever establishing that it was (nexus-code#467).
#
# It never fired in practice — zero occurrences of its log lines across a month
# of labsh-service.log — so this was a latent hazard, not the cause of any
# incident. It is fixed as such.
#
# Now: reap only on POSITIVE EVIDENCE (uid + /proc/<pid>/exe + our port + age
# past budget), and fail closed on anything unestablished. See
# `_labsh_build_age` below for the enumerated live counter-examples. The
# original intent of #450 — clearing a true orphan that holds the uv lock — is
# preserved: an orphan past the budget is still reaped. start_server only ever
# runs while the service is already unhealthy (no live healthy server on this
# port to hit). Reversible: `git revert` drops only this reaper. Best-effort;
# missing tools are not fatal.
# How long one of OUR cold builds may run before it counts as an orphan.
# Mirrors the watcher's monitor.service_health.cold_build_ceiling_seconds
# (default 1800) so the two layers agree on when a build stops being in-flight.
# Must exceed START_GRACE (900) or the supervisor's own MAX_FAILS bounce would
# reap builds that are still legitimately materialising.
COLD_BUILD_BUDGET="${LABSH_COLD_BUILD_BUDGET:-1800}"

# The shared evidence predicate. Sourced, not reimplemented: the watcher's
# `_sh_labsh_build_in_progress` asks the SAME question with opposite polarity,
# and the two must never drift. If it is missing we fail closed by reaping
# nothing at all — a delayed reap is survivable, a wrong kill is not.
_LABSH_EVIDENCE="$SCRIPT_DIR/_labsh_build_evidence.sh"
# shellcheck source=_labsh_build_evidence.sh
[[ -r "$_LABSH_EVIDENCE" ]] && source "$_LABSH_EVIDENCE"

_REAP_KILLED=0
_reap_if_stale() {
    local pid="$1" port="$2" src="$3" age
    declare -F labsh_build_is_ours >/dev/null || return 1   # helper absent → reap nothing
    labsh_build_is_ours "$pid" "$PROJECT_DIR" "$port" || return 1   # not ours → silent
    age=$(labsh_build_age "$pid") || return 1
    if (( age < COLD_BUILD_BUDGET )); then
        log "NOT reaping pid $pid ($src): our labsh build for port $port, but only ${age}s old (< ${COLD_BUILD_BUDGET}s budget) — a build in flight, not an orphan"
        return 1
    fi
    log "reaping stale labsh build (pid $pid, ${age}s >= ${COLD_BUILD_BUDGET}s budget, $src) before start — releases the uv lock"
    kill "$pid" 2>/dev/null && _REAP_KILLED=1
    return 0
}

reap_stale_builds() {
    local port="$1" pid
    _REAP_KILLED=0
    if ! declare -F labsh_build_is_ours >/dev/null; then
        log "WARNING: $_LABSH_EVIDENCE unavailable — skipping the stale-build reap entirely (fail closed)"
        return 0
    fi

    # (1) the pid labsh recorded for the last background build. Still gated:
    # a recorded pid can be RECYCLED onto an unrelated process.
    pid=$(cat "$BG_PID_FILE" 2>/dev/null)
    [[ -n "$pid" ]] && _reap_if_stale "$pid" "$port" "$BG_PID_FILE" || true

    # (2) builds for THIS service from prior supervisor generations whose
    # bg.pid we no longer hold. `labsh_build_scan` is a /proc scan under the
    # same identity gates — never `pgrep -f`, which matches the full argv and
    # so selects any process that merely MENTIONS jupyter-lab.
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        _reap_if_stale "$pid" "$port" "/proc scan" || true
    done < <(labsh_build_scan "$PROJECT_DIR" "$port")

    # Give the kernel a moment to release the flock the dead build held, so
    # the fresh uvx below doesn't briefly queue behind a dying process.
    (( _REAP_KILLED )) && sleep 1
    return 0
}

# ── labsh phantom-adopt self-heal (jupyterlab outage 2026-07-01) ─────────────
# labsh's start-guard decides "a server is already running" by scanning
# $JUPYTER_DATA_DIR/runtime/jpserver-*.json and adopting the first record whose
# recorded pid answers `kill -0`. That guard cannot tell a live JupyterLab from
# a DEAD server's record whose pid has since been recycled to an unrelated
# process (or is a not-yet-reaped zombie) — both pass `kill -0`. When that
# happens `labsh start` prints "server is already running (pid …)", returns
# rc=1, the supervisor adopts the phantom, and the healthcheck fails forever
# because nothing is actually listening — the 2026-07-01 outage, where a stale
# jpserver-6105.json wedged three watcher restarts. These helpers let the
# supervisor detect and heal it on its own. Reversible: `git revert` removes
# only this self-heal. Non-degrading: a genuinely-serving record is proven live
# (it answers /api/status) and is NEVER pruned, so a real already-running
# server is still adopted normally.

# Runtime dir labsh scans, derived the SAME way labsh does — respect
# JUPYTER_DATA_DIR, default to the project's .jupyter tree. Never hardcoded.
runtime_dir() {
    printf '%s\n' "${JUPYTER_DATA_DIR:-$PROJECT_DIR/.jupyter/share/jupyter}/runtime"
}

# Parse a scalar field from a (flat, one-key-per-line) jpserver-*.json record
# WITHOUT sourcing or running python — the record lives in a possibly-foreign
# project tree and must never execute code in the supervisor. $1=file $2=key.
record_field() {
    sed -nE "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"?([^\",}]*)\"?.*/\1/p" "$1" 2>/dev/null | head -1
}

# True iff the server a jpserver record describes is ACTUALLY serving: it
# answers /api/status on its recorded port with its recorded token (the
# jupyter-health.sh contract, keyed off the record rather than the service env
# file). This is the authoritative "is this a live server" test — it cannot be
# fooled by pid reuse or a zombie, and it can never misfire against a healthy
# server. No curl / no port / no token → cannot prove serving → not serving.
record_is_serving() {
    local jf="$1" port token scheme
    command -v curl >/dev/null 2>&1 || return 1
    port=$(record_field "$jf" port)
    token=$(record_field "$jf" token)
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$token" ]] || return 1
    if grep -qE '"secure"[[:space:]]*:[[:space:]]*true' "$jf" 2>/dev/null; then
        scheme=https
    else
        scheme=http
    fi
    curl -fsSk -o /dev/null --max-time "${LABSH_HEALTH_TIMEOUT:-3}" \
        -H "Authorization: token $token" \
        "$scheme://127.0.0.1:$port/api/status"
}

# _token_mismatch_proven <file-token> — rc 0 iff some runtime record's server
# answers /api/status WITH ITS OWN RECORDED TOKEN while that token differs from
# the one in `.jupyter/token`. That is the mismatch proven from the SERVER's
# side, and it is the sound discriminator for your-org/nexus-code#1584.
#
# WHY IT EXISTS BESIDE THE `tok0` SNAPSHOT (skeptic testinfra2sk F2, PR 1593).
# `tok0` is read after `labsh start` RETURNS, but the server is measurably green
# 40-205 ms BEFORE that (3 of 3). A rotation landing in that window makes
# tok0 == the rotated token, the snapshot sees no change, and the 900 s wedge is
# back. The snapshot can MISS; it can never false-fire, so it stays as a second
# arm (it is also the only arm a record-less server offers). This one cannot
# miss, because it asks the server rather than remembering the file.
#
# AND IT CANNOT FIRE ON A WARMING SERVER: that server answers 403 to EVERYTHING,
# so `record_is_serving` is false for it and the restart-flap pin holds.
#
# ONLY OUR PORT'S RECORD (skeptic testinfra2sk F5, your-org/nexus-code#1594).
# The runtime dir can hold a FOREIGN serving record — an operator-exported
# JUPYTER_DATA_DIR, or a second server labsh's start guard missed. Unbound, that
# record answered 200 with its own token while OUR server was merely warming
# (403), every rc-22 probe counted, and the fast bail fired on a warming server:
# the restart flap, through another door. So a record is consulted only when its
# `port` is the PORT= this start persisted (the port our health probe asks). No
# env file or no PORT = cannot tell, and cannot-tell never bails.
_token_mismatch_proven() {
    local ftok="$1" rt jf rtok ours
    [[ -n "$ftok" ]] || return 1
    # First PORT= only, with no `head` reader (the early-exit-reader ratchet, #622).
    ours=$(sed -n '/^PORT=/{s///p;q;}' "$ENV_FILE" 2>/dev/null)
    [[ "$ours" =~ ^[0-9]+$ ]] || return 1
    rt=$(runtime_dir); [[ -d "$rt" ]] || return 1
    for jf in "$rt"/jpserver-*.json; do
        [[ -e "$jf" ]] || continue
        [[ "$(record_field "$jf" port)" == "$ours" ]] || continue
        rtok=$(record_field "$jf" token)
        [[ -n "$rtok" && "$rtok" != "$ftok" ]] || continue
        record_is_serving "$jf" && return 0
    done
    return 1
}

# Conservative pre-start prune: remove runtime records whose recorded pid is
# VERIFIABLY DEAD (kill -0 fails). Never touches a pid that is alive — including
# a warming server that has not yet answered the healthcheck — so it can only
# ever remove a record a crashed/killed server left behind. Sets PRUNED_DEAD.
PRUNED_DEAD=0
prune_dead_runtime_records() {
    PRUNED_DEAD=0
    local rt jf pid; rt=$(runtime_dir)
    [[ -d "$rt" ]] || return 0
    for jf in "$rt"/jpserver-*.json; do
        [[ -e "$jf" ]] || continue
        pid=$(record_field "$jf" pid)
        [[ "$pid" =~ ^[0-9]+$ ]] || continue       # unparseable → can't prove dead → leave
        kill -0 "$pid" 2>/dev/null && continue      # pid alive → never touch (conservative)
        rm -f "$jf" && { PRUNED_DEAD=$((PRUNED_DEAD+1)); log "pruned stale runtime record for dead pid $pid ($(basename "$jf"))"; }
    done
    return 0
}

# Proven-phantom prune: remove runtime records that are NOT actually serving
# (their recorded server does not answer /api/status). Called ONLY after a
# confirmed phantom-adopt — labsh returned rc=1 (adopted a record) yet the
# healthcheck failed for the entire START_GRACE window — so we have already
# proven, over minutes, that no healthy server owns this project. Only then is
# it safe to prune a record whose pid happens to be alive (pid reuse / zombie),
# which the conservative kill-0 prune deliberately leaves. A record that DOES
# answer /api/status is a real live server and is never pruned. Sets
# PRUNED_PHANTOM.
PRUNED_PHANTOM=0
prune_phantom_runtime_records() {
    PRUNED_PHANTOM=0
    local rt jf pid; rt=$(runtime_dir)
    [[ -d "$rt" ]] || return 0
    for jf in "$rt"/jpserver-*.json; do
        [[ -e "$jf" ]] || continue
        record_is_serving "$jf" && continue         # real live server — never touch
        pid=$(record_field "$jf" pid)
        rm -f "$jf" && { PRUNED_PHANTOM=$((PRUNED_PHANTOM+1)); log "pruned phantom runtime record (pid ${pid:-?}, not serving) ($(basename "$jf"))"; }
    done
    return 0
}

# Repair a purged uv cache target before starting (jacob-greene/nexus#98).
#
# Same class as the `labsh_dangling` self-heal just below it: a precondition
# the start needs has been destroyed by something outside this supervisor, and
# retrying the start without repairing it cannot succeed. A no-op (two stat
# calls) in every healthy case, so it costs nothing per restart. It never
# blocks the start: if the guard refuses or fails, it has already said why on
# stderr, and we let `labsh start` run and fail with its own message rather
# than invent a second failure path here.
repair_uv_cache() {
    declare -F nexus_uv_cache_guard >/dev/null 2>&1 || return 0
    local cache="${UV_CACHE_DIR:-}" rc=0
    [[ -n "$cache" ]] || return 0
    nexus_uv_cache_guard "$cache" || rc=$?
    case "$rc" in
        10) log "repaired dangling uv cache symlink $cache (scratch was purged) before start" ;;
        2)  log "REFUSED to repair uv cache $cache — see stderr; the start below will likely fail" ;;
        3)  log "FAILED to repair uv cache $cache — see stderr; the start below will likely fail" ;;
    esac
    return 0
}

# Loop guard for the phantom-adopt retry (reset per start_server entry, NOT per
# _start_cycle, so the single retry can never spin).
PHANTOM_RETRY_ATTEMPTED=0

start_server() {
    REINSTALL_ATTEMPTED=0          # fresh loop guard for this start cycle (#103 self-heal)
    PHANTOM_RETRY_ATTEMPTED=0      # fresh loop guard for the phantom-adopt self-heal
    _start_cycle
}

_start_cycle() {
    local port rc i tries url_seen=0 hrc=0 rejected=0 tok0='' tok1=''
    # Prune runtime records for verifiably-dead pids BEFORE start so labsh's
    # start-guard can't adopt a stale dead-pid record. Conservative (kill -0
    # only): a live pid, even a still-warming server, is never touched here.
    prune_dead_runtime_records
    port=$(sed -n 's/^PORT=//p' "$ENV_FILE" 2>/dev/null | head -1)
    [[ "$port" =~ ^[0-9]+$ ]] || port=$(default_port)
    reap_port_orphan "$port"
    reap_stale_builds "$port"       # kill unfinished builds holding the uv lock (#33)
    repair_uv_cache                 # recreate a purged uv cache target (jacob-greene/nexus#98)
    read_opts
    # Self-heal a wiped labsh binary BEFORE starting (incident #103, extended):
    # cover both the persistent-shim-with-missing-lib-target dangle case (#103)
    # AND the entirely-missing case (shim itself gone after a HOME overlay
    # reset that leaves no ~/.local/bin/labsh in place). Either way, reinstall
    # into $NEXUS_LOCALS so the start below can actually succeed.
    if labsh_missing; then
        log "labsh not on PATH — self-healing before start (see your-org/other-nexus#103, extended)"
        reinstall_labsh || true
    elif labsh_dangling; then
        log "labsh shim dangles (lib target missing) — self-healing before start (see your-org/other-nexus#103)"
        reinstall_labsh || true
    fi
    log "starting labsh server (preferred port $port${OPTS[*]:+, opts: ${OPTS[*]}})"
    labsh start --port "$port" ${OPTS[@]+"${OPTS[@]}"}
    rc=$?
    # rc=127 == the shell could not exec the shim's lib target (binary wiped) —
    # the same #103 failure, catching a wipe that raced in after the pre-start
    # check. Reinstall once and retry the start.
    if (( rc == 127 )); then
        log "labsh start rc=127 (binary missing) — self-healing and retrying start once"
        if reinstall_labsh; then
            labsh start --port "$port" ${OPTS[@]+"${OPTS[@]}"}
            rc=$?
        fi
    fi
    (( rc != 0 )) && log "labsh start rc=$rc (already-running server is adopted; else see .jupyter/labsh.bg.log)"
    # Poll up to START_GRACE seconds (0.5s steps) for the server to become
    # genuinely HEALTHY — not merely to expose a URL. labsh writes the
    # jpserver JSON (so `labsh url` resolves) the instant jupyter-lab is
    # launched, and stale JSONs from prior crashed servers can make it resolve
    # even earlier; but the process then needs to import jupyterlab + its
    # extensions off the NFS uv cache and bind the port before /api/status
    # answers. On the first start after a sandbox restart (page cache cold,
    # restart-storm load) that post-URL gap routinely exceeds the steady-state
    # 3-strike bounce window (~45s). Returning success on URL-present alone
    # therefore armed that bounce against a server still legitimately coming
    # up — restarting the cold-import cost and re-arming the same too-eager
    # window: the observed restart flap. So persist the port as soon as a URL
    # appears (once, to avoid log spam), but gate success on a PASSING
    # healthcheck against that port.
    # The token THIS start began with, read after `labsh start` has written it.
    # Empty (no file yet) means "cannot tell", and cannot-tell never bails.
    tok0=$(cat .jupyter/token 2>/dev/null) || tok0=''
    tries=$(( START_GRACE * 2 ))
    for (( i = 0; i < tries; i++ )); do
        if (( ! url_seen )) && persist_env_from_url; then
            url_seen=1
        fi
        if (( url_seen )); then
            # rc captured on the same line as the probe (#1202).
            hrc=0; "$HEALTH" "$PROJECT_DIR" >/dev/null 2>&1 || hrc=$?
            if (( hrc == 0 )); then
                REJECT_BAILS=0
                return 0
            fi
            # 22 = answered and REJECTED our token — which a WARMING server may
            # also do, so 22 alone proves nothing. 22 with a token that is no
            # longer the one this start began with is a rotation: certain,
            # permanent, and not curable by waiting.
            tok1=$(cat .jupyter/token 2>/dev/null) || tok1=''
            if (( hrc == 22 )) && { _token_mismatch_proven "$tok1" || [[ -n "$tok0" && -n "$tok1" && "$tok1" != "$tok0" ]]; }; then
                rejected=$(( rejected + 1 ))
            else
                rejected=0
            fi
            if (( rejected >= REJECT_PROBES && REJECT_BAILS < REJECT_BAILS_MAX )); then
                REJECT_BAILS=$(( REJECT_BAILS + 1 ))
                log "the auth token was ROTATED during the start wait and the server REJECTS the new one ($rejected consecutive probes) — a certain mismatch, not a slow start; leaving the wait so the watchdog can bounce it (fast bail $REJECT_BAILS/$REJECT_BAILS_MAX, your-org/nexus-code#1584)"
                return 1
            fi
        fi
        sleep 0.5
    done
    # Phantom-adopt self-heal: labsh reported "already running" (rc=1 → it
    # adopted an existing jpserver record) but no healthy server materialised
    # within START_GRACE. The adopted record is a phantom — a dead server's
    # record whose recorded pid was recycled to another process or is a zombie,
    # which labsh's kill-0 start-guard cannot tell from a live server. Having
    # proven over the whole START_GRACE window that nothing is serving, prune
    # the non-serving record(s) (record_is_serving keeps a genuinely-live one)
    # and retry the start ONCE — guarded by PHANTOM_RETRY_ATTEMPTED so it can
    # never spin.
    if (( rc == 1 && ! PHANTOM_RETRY_ATTEMPTED )); then
        PHANTOM_RETRY_ATTEMPTED=1
        prune_phantom_runtime_records
        if (( PRUNED_PHANTOM > 0 )); then
            log "phantom-adopt: labsh adopted an already-running record (rc=1) but no healthy server appeared within ${START_GRACE}s; pruned $PRUNED_PHANTOM non-serving record(s) — retrying start once"
            _start_cycle
            return $?
        fi
        log "phantom-adopt suspected (rc=1, unhealthy after ${START_GRACE}s) but every runtime record is serving or already gone — not retrying (will retry on the next unhealthy streak)"
    fi
    if (( url_seen )); then
        log "WARNING: server exposed a URL but did not pass the healthcheck within ${START_GRACE}s — will retry on the next unhealthy streak"
    else
        log "WARNING: no live server URL after ${START_GRACE}s — will retry on the next unhealthy streak"
    fi
    return 1
}

# Run the optional periodic hook ASYNC so a slow hook can never stall
# the probe loop. Overlap guard: skip while a previous invocation is
# still running.
PERIODIC_PID=''
# _periodic_in_flight — rc 0 iff the hook THIS supervisor launched is still
# running. Asked of bash's OWN JOB TABLE, never of the kernel about a number.
#
# THE OVERLAP GUARD USED TO BE `kill -0 "$PERIODIC_PID"`, AND THAT IS A QUESTION
# ABOUT A NUMBER. Once the hook ends and bash reaps it, the number is free, and
# `kill -0` succeeds for WHATEVER holds it next — including a THREAD, since a
# thread id is a valid `kill` target. Found on the LIVE service, 2026-09-19: the
# log said "periodic hook still running (pid 10994) — skipping this round" 84
# times over ~14 h and was read, by me too, as a hook that had HUNG. It had not.
# /proc/10994 was `Bun Pool 35`, Tgid 36836 != Pid 10994 — a thread of an
# unrelated process; `ps -p` does not list threads, so the pid looked gone while
# `kill -0` kept answering 0. The hook had finished long before and was never
# run again: a MISSED-RUN bug wearing a hang's log line. The 3600 s bound above
# is still worth having and does nothing for this.
#
# The job table cannot be fooled that way: it lists only this shell's own
# un-reaped children, so a recycled number that is not our job is not in it.
# Measured: own live child -> in flight; the same child once ended -> not; an
# UNRELATED live pid -> `kill -0` says alive, this says not in flight.
_periodic_in_flight() {
    local p
    [[ -n "$PERIODIC_PID" ]] || return 1
    for p in $(jobs -pr); do
        if [[ "$p" == "$PERIODIC_PID" ]]; then
            return 0
        fi
    done
    return 1
}
run_periodic() {
    [[ -f "$PERIODIC_FILE" ]] || return 0
    if _periodic_in_flight; then
        log "periodic hook still running (pid $PERIODIC_PID) — skipping this round"
        return 0
    fi
    # Explicit mode at creation (your-org/nexus-code#484).
    _ensure_service_log "$PERIODIC_LOG"
    # A SUBSHELL, so the outcome can be LOGGED: the hook is async, and a bare
    # `timeout … &` would kill a hang in silence — the round after it would
    # simply stop saying "still running", which reads as the hook having
    # finished. `$!` is the subshell, so the overlap guard above still covers
    # the whole attempt. GNU `timeout` makes itself a process-group leader and
    # signals the GROUP, so a hook's children (uv, a crawl) go with it.
    #
    # THE SET, NOT 124: `-k` escalates to KILL, which reports 137 (#1248).
    (
        _prc=0
        if (( PERIODIC_TIMEOUT > 0 )); then
            # Backgrounded + `wait`, so its pid — which IS its process group —
            # can be recorded for `on_term` (see `_reap_periodic_group`).
            timeout -k 30 "$PERIODIC_TIMEOUT" bash "$PERIODIC_FILE" >> "$PERIODIC_LOG" 2>&1 &
            _pt=$!
            printf '%s\n' "$_pt" > "$PERIODIC_PGID_FILE.tmp" && mv -f "$PERIODIC_PGID_FILE.tmp" "$PERIODIC_PGID_FILE"
            wait "$_pt" || _prc=$?
            rm -f "$PERIODIC_PGID_FILE"
        else
            bash "$PERIODIC_FILE" >> "$PERIODIC_LOG" 2>&1 || _prc=$?
        fi
        case "$_prc" in
            124|137) log "periodic hook KILLED after ${PERIODIC_TIMEOUT}s (rc $_prc) — it did not return; the next round will launch it again (log $PROJECT_DIR/$PERIODIC_LOG)" ;;
        esac
    ) &
    PERIODIC_PID=$!
    log "periodic hook launched (pid $PERIODIC_PID, log $PROJECT_DIR/$PERIODIC_LOG, bound ${PERIODIC_TIMEOUT}s)"
}

log "supervisor up: project=$PROJECT_DIR interval=${INTERVAL}s threshold=$MAX_FAILS"

# A PREDECESSOR'S ORPHANED HOOK IS REAPED BEFORE THE FIRST ROUND (skeptic
# testinfra2sk F6, your-org/nexus-code#1594). `on_term` cannot cover two paths:
# a TERM landing between `timeout … &` and the `mv` that publishes the pgid
# file, and a supervisor KILLed (or OOM-killed), whose trap never runs. In both
# the old hook survives, reparented to init, and our first `run_periodic` would
# OVERWRITE its pgid file — losing the last handle on it. Same identity check as
# on TERM, so a recycled or garbage pid is left alone. ITS STATED LIMIT: it
# WOULD kill a foreign, self-grouped `timeout` whose cwd is this same project
# directory. Nothing starts one today; it is the price of reaping by file.
_reap_periodic_group "an orphaned periodic hook left by a previous supervisor"

# Immediate bring-up: don't make first activation wait out a failure
# streak. Adopt-or-start covers both cold boot and an already-live
# server whose env file is missing/stale.
"$HEALTH" "$PROJECT_DIR" >/dev/null 2>&1 || start_server
run_periodic

fails=0
ticks=0
while true; do
    # Interruptible sleep: TERM during the nap must run the trap now,
    # not after INTERVAL elapses.
    sleep "$INTERVAL" & wait $! 2>/dev/null
    ticks=$(( ticks + 1 ))
    (( ticks % PERIODIC_EVERY == 0 )) && run_periodic
    if "$HEALTH" "$PROJECT_DIR" >/dev/null 2>&1; then
        fails=0
        REJECT_BAILS=0      # a healthy probe restores the fast-bail budget (#1584)
        continue
    fi
    fails=$(( fails + 1 ))
    log "healthcheck failed ($fails/$MAX_FAILS)"
    if (( fails >= MAX_FAILS )); then
        log "restarting labsh server"
        labsh stop >/dev/null 2>&1 || true
        sleep 1
        start_server || true
        fails=0
    fi
done
