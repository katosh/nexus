#!/usr/bin/env bash
# jupyter-kernel-crawl.sh — register every work/<project> venv as a
# kernelspec of the ROOT work-root JupyterLab (see jupyter-up.sh --root).
#
#   monitor/jupyter-kernel-crawl.sh [WORKROOT]      (default: $NEXUS_ROOT/work)
#
# For each immediate child of WORKROOT (shallow — NEVER a recursive find
# over the huge NFS mount) that has a usable venv (./.venv/bin/python),
# ensure a kernelspec named `proj-<dir>` exists in the root session's
# kernel dir (WORKROOT/.jupyter/share/jupyter/kernels/) via
# `labsh kernel register --project DIR`. Idle kernelspecs cost nothing —
# a kernel process only spawns when someone attaches — so registering
# every project is free until used.
#
# Idempotent: a kernelspec whose recorded interpreter already points at
# the project's .venv python is skipped. Re-runs are cheap (one JSON
# parse per project) and safe at any time.
#
# Stale policy: a `proj-*` kernelspec whose recorded interpreter no
# longer exists (project deleted or its venv removed) is PRUNED. Only
# `proj-*` names are ever pruned — kernelspecs registered by hand under
# other names are never touched.
#
# Concurrency: a non-blocking flock on WORKROOT/.jupyter/.crawl.lock —
# if another crawl is mid-flight, this one exits 0 immediately.
#
# Side effect to know about: `labsh kernel register` installs ipykernel
# into a project's .venv when it is missing (additive only, never an
# upgrade).
#
# Lmod-module-python venvs: a venv whose base interpreter is an Lmod
# module Python (`pyvenv.cfg` `home = /app/software/Python/<VER>-GCCcore-<X>/bin`)
# cannot even start during the ipykernel-install step without its module's
# LD_LIBRARY_PATH (the whole dependency stack — libpython, SQLite, OpenSSL,
# libffi, GCCcore — not just `<module>/lib`). For such venvs the crawl loads
# the module in an ISOLATED subshell, captures the resulting LD_LIBRARY_PATH,
# passes it via `labsh kernel register --ld-library-path` (also baked into
# kernel.json for runtime), and clears PYTHONPATH (`env -u`) so the module's
# injected site-packages don't shadow the venv's own. Non-module
# (linuxbrew/system) venvs take the plain path — byte-identical to the
# historical bare invocation. If Lmod is unavailable on this host, an
# Lmod-needing venv is SKIPPED with a clear log line, never a hard failure.
#
# Exit 0 unless WORKROOT is unusable; per-project failures are logged,
# tallied in the summary line, and never abort the sweep.
#
# ENV: NEXUS_ROOT      — as elsewhere (default: this script's own checkout).
#      NEXUS_LMOD_INIT — authoritative override for the Lmod init script.
#                        When set, ONLY this path is sourced (any inherited or
#                        standard-location `module` is disregarded): point it
#                        at your host's init to pin a specific Lmod, or at a
#                        bogus path to force the skip-needs-Lmod degrade.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$_script_dir/.." && pwd)}"

WORKROOT="${1:-$NEXUS_ROOT/work}"
WORKROOT=$(cd "$WORKROOT" 2>/dev/null && pwd) \
    || { echo "kernel-crawl: workroot not found: ${1:-$NEXUS_ROOT/work}" >&2; exit 1; }

KERNELS_DIR="$WORKROOT/.jupyter/share/jupyter/kernels"
LOCK_FILE="$WORKROOT/.jupyter/.crawl.lock"

say() { echo "[kernel-crawl] $*" >&2; }

command -v labsh >/dev/null 2>&1 \
    || { say "labsh not on PATH — nothing to do"; exit 1; }

mkdir -p "$WORKROOT/.jupyter"

# Mirror labsh's sanitize_kernel_name so our existence checks and labsh's
# writes agree on the kernelspec directory name.
_sanitize() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/[^a-z0-9._-]\+/-/g' -e 's/^-\+//' -e 's/-\+$//'
}

# Recorded interpreter (argv[0]) of a kernelspec; empty on parse failure.
_spec_python() {
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    argv = d.get("argv") or []
    print(argv[0] if argv else "")
except Exception:
    print("")' "$1" 2>/dev/null
}

# Make `module` usable in THIS shell if Lmod is installed but not yet
# initialized (the crawl may run from a service/cron context with no Lmod
# init sourced). Returns 0 if a usable `module` results, 1 otherwise —
# NEVER fatal. Idempotent: once the init is sourced, `module` is a function
# and later calls short-circuit. Real Lmod's `module` is a shell function
# (it must eval env mutations into the caller's shell), which is why we
# source an init script rather than expect an executable on PATH.
_ensure_lmod() {
    # An explicit NEXUS_LMOD_INIT is AUTHORITATIVE: source exactly that init
    # (never an ambient or standard-location `module`), so an operator can pin
    # a specific Lmod, or force the skip-needs-Lmod degrade with a bogus path.
    if [[ -n "${NEXUS_LMOD_INIT:-}" ]]; then
        unset -f module ml 2>/dev/null || true      # disregard any inherited module
        if [[ -r "$NEXUS_LMOD_INIT" ]] \
           && . "$NEXUS_LMOD_INIT" >/dev/null 2>&1 \
           && command -v module >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi
    # No override: an already-initialized `module` (Lmod exports it to child
    # shells) wins; otherwise source one of the standard init locations.
    command -v module >/dev/null 2>&1 && return 0
    local init
    for init in "${LMOD_PKG:+$LMOD_PKG/init/bash}" \
                /app/lmod/lmod/init/bash /etc/profile.d/lmod.sh; do
        [[ -n "$init" && -r "$init" ]] || continue
        # shellcheck disable=SC1090
        . "$init" >/dev/null 2>&1 || continue
        command -v module >/dev/null 2>&1 && return 0
    done
    return 1
}

crawl() {
    local registered=0 skipped=0 pruned=0 failed=0
    local d base name spec py want

    # --- register: shallow sweep of WORKROOT/*/ -------------------------
    for d in "$WORKROOT"/*/; do
        [[ -d "$d" ]] || continue
        d="${d%/}"
        base=$(basename "$d")
        py="$d/.venv/bin/python"
        [[ -x "$py" ]] || continue               # not a project venv — skip silently
        name="proj-$(_sanitize "$base")"
        [[ "$name" == proj- ]] && { say "skip $base: empty name after sanitization"; continue; }
        spec="$KERNELS_DIR/$name/kernel.json"
        if [[ -f "$spec" ]]; then
            want=$(readlink -f "$py" 2>/dev/null)
            have=$(readlink -f "$(_spec_python "$spec")" 2>/dev/null)
            if [[ -n "$have" && "$have" == "$want" ]]; then
                skipped=$(( skipped + 1 ))
                continue
            fi
            # Same sanitized name, different interpreter: never clobber.
            say "COLLISION: '$name' already registered for '$(_spec_python "$spec")' — skipping $d"
            failed=$(( failed + 1 ))
            continue
        fi
        # Classify by base interpreter (pyvenv.cfg `home=`). An Lmod-module
        # python needs its module's full LD_LIBRARY_PATH baked in and a
        # cleared PYTHONPATH; everything else takes the plain path, which is
        # byte-equivalent to the historical bare call (`env` with no options
        # just execs the command with the inherited environment).
        local -a reg_env=(env) reg_ld=()
        local home mod ld
        home=$(sed -n 's/^home *= *//p' "$d/.venv/pyvenv.cfg" 2>/dev/null | head -1)
        if [[ "$home" == /app/software/Python/*/bin ]]; then
            if _ensure_lmod; then
                mod="Python/$(basename "$(dirname "$home")")"   # Python/<VER>-GCCcore-<X>
                # Capture the module's full LD_LIBRARY_PATH from an ISOLATED
                # subshell. NOT hand-assembled (the module sets the whole
                # dependency stack), and NOT piped into the capture — a piped
                # `module` would run in its own subshell and discard the
                # env-mutating eval, yielding an empty LD. The `&&` gates the
                # printf on a successful load, so a bad module name → empty ld
                # → degrade below rather than a wrong path.
                ld=$( module purge >/dev/null 2>&1
                      module load "$mod" >/dev/null 2>&1 && printf '%s' "${LD_LIBRARY_PATH:-}" )
                if [[ -n "$ld" ]]; then
                    reg_env=(env -u PYTHONPATH "LD_LIBRARY_PATH=$ld")
                    reg_ld=(--ld-library-path "$ld")
                else
                    say "SKIP $base: module '$mod' yielded no LD_LIBRARY_PATH — needs Lmod (skipped, not failed)"
                    skipped=$(( skipped + 1 ))
                    continue
                fi
            else
                say "SKIP $base: base python is Lmod-managed ($home) but Lmod is unavailable here — needs Lmod (skipped, not failed)"
                skipped=$(( skipped + 1 ))
                continue
            fi
        fi
        say "registering $base -> $name"
        if ( cd "$WORKROOT" && "${reg_env[@]}" labsh kernel register \
                --project "$d" --name "$name" \
                --display-name "Python ($base)" "${reg_ld[@]}" ) >&2; then
            registered=$(( registered + 1 ))
        else
            say "FAILED to register $base (see above) — continuing"
            failed=$(( failed + 1 ))
        fi
    done

    # --- prune: proj-* kernelspecs whose interpreter is gone ------------
    for spec in "$KERNELS_DIR"/proj-*/kernel.json; do
        [[ -f "$spec" ]] || continue
        py=$(_spec_python "$spec")
        if [[ -z "$py" ]]; then
            say "leaving $(dirname "$spec"): kernel.json unparseable (not pruning)"
            continue
        fi
        if [[ ! -x "$py" ]]; then
            say "pruning stale kernelspec $(basename "$(dirname "$spec")") (interpreter gone: $py)"
            rm -rf "$(dirname "$spec")"
            pruned=$(( pruned + 1 ))
        fi
    done

    say "done: registered=$registered skipped=$skipped pruned=$pruned failed=$failed"
}

if command -v flock >/dev/null 2>&1; then
    exec 9>>"$LOCK_FILE"
    flock -n 9 || { say "another crawl holds $LOCK_FILE — exiting"; exit 0; }
fi
crawl
exit 0
