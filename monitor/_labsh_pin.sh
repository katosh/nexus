#!/usr/bin/env bash
# _labsh_pin.sh — pin the labsh SERVER environment's resolution so a restart
# reuses the cached env instead of rebuilding it (your-org/nexus-code#1676).
#
# ── Why a restart was a cold build ──────────────────────────────────────────
# labsh starts JupyterLab as `uvx --python 3.12 --from jupyterlab --with … \
# jupyter-lab …`. The spec is UNPINNED, so uv re-resolves it against the live
# index on every start, and the cached env in the persistent uv cache
# (environments-v2, on NFS via locals-env.sh) is keyed by that resolution. A
# release of ANY of its ~100 transitive dependencies therefore yields a new key
# and a full re-materialisation of thousands of files onto NFS — measured: the
# two newest cached envs on 2026-09-29 differed ONLY by fqdn 1.5.1→1.6.0 and
# platformdirs 4.12.0→4.12.1, and new envs were built on Sep 21, 22, 23, 27
# and 28. On a loaded node one such build takes more than 30 minutes.
#
# (NOT /tmp. `.jupyter/.labshvenv -> /tmp/labsh-venv-…` is labsh's small
# HELPER venv — 17 packages, rebuilt in 8.53 s after a restart — and it is
# labsh's own design, left alone here.)
#
# ── The pin ────────────────────────────────────────────────────────────────
# After a server has passed its healthcheck, `labsh-pin.sh capture` freezes
# THAT server's env into <project>/.jupyter/labsh-server.pin. On every later
# start, the `uvx` shim (monitor/labsh-uvx-shim/uvx, PATH-fronted by
# labsh-supervised.sh only) passes it as `--constraints`, so the resolution is
# the same set and uv reuses the cached env. Measured with a hermetic cache: an
# env resolved at an earlier date, frozen, then re-requested with that freeze
# as --constraints against today's index, came back as the SAME cached env
# with no install; unconstrained, the same request built a new env.
#
# SCOPED TO THE SERVER CALL ONLY, never exported as UV_CONSTRAINT: labsh's
# `labsh start` also runs `uv pip install` for its helper venv against its own
# lock (.jupyter/.labshvenv.lock pins platformdirs==4.10.0 while the server env
# has 4.12.1), and a global constraint would make that install unsatisfiable.
#
# ── How an update reaches the lab ──────────────────────────────────────────
# The pin freezes versions, so upgrades are deliberate: `labsh-pin.sh refresh`
# builds the UNCONSTRAINED current resolution in the background (the pinned env
# keeps serving), smoke-tests a throwaway server from the candidate env, and
# only then swaps the pin. The new env is already in the cache, so the next
# restart is warm too. labsh-supervised.sh runs a refresh every
# LABSH_SVC_REPIN_DAYS (default 7) while healthy; `labsh-pin.sh refresh` runs
# one now; deleting the pin (or LABSH_SVC_PIN=0) returns to unpinned starts.
#
# Sourced by the shim and by labsh-pin.sh. Side-effect-free on source.

if [[ -n "${_NEXUS_LABSH_PIN_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_NEXUS_LABSH_PIN_LOADED=1

_LABSH_PIN_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
LABSH_PIN_SHIM_DIR="$_LABSH_PIN_LIB_DIR/labsh-uvx-shim"

# Files, all under <project>/.jupyter (the directory LABSH_PIN_DIR names):
#   labsh-server.spec      the uvx arguments before `jupyter-lab`, one per line,
#                          as labsh last passed them (written by the shim)
#   labsh-server.pin       the frozen requirements (`uv pip freeze` output)
#   labsh-server.pin.spec  the spec the pin was captured UNDER — the pin is
#                          applied only while the current spec still matches
#   labsh-server.pin.prev  the pin a refresh replaced (manual rollback)
#   labsh-server.pin.meta  key=value: captured_at, source, env, refreshed_at
#   labsh-pin.log          capture/refresh log
labsh_pin_file()      { printf '%s/labsh-server.pin' "$1"; }
labsh_pin_spec_file() { printf '%s/labsh-server.spec' "$1"; }

# labsh_pin_real_uvx — the first `uvx` on PATH that is NOT the shim. Prints its
# path; rc 1 if there is none. Compared PHYSICALLY so a symlinked PATH entry
# pointing at the shim directory cannot make the shim exec itself.
labsh_pin_real_uvx() {
    local d phys parts
    IFS=: read -r -a parts <<<"$PATH"
    for d in "${parts[@]}"; do
        [[ -n "$d" ]] || continue
        phys=$(cd "$d" 2>/dev/null && pwd -P) || continue
        [[ "$phys" == "$LABSH_PIN_SHIM_DIR" ]] && continue
        if [[ -x "$d/uvx" && ! -d "$d/uvx" ]]; then
            printf '%s' "$d/uvx"
            return 0
        fi
    done
    return 1
}

# labsh_pin_server_split <args…> — if the argument list is labsh's SERVER call
# (`--from jupyterlab` before a `jupyter-lab` command), print the index of the
# `jupyter-lab` argument and return 0; otherwise return 1. Anything else that
# goes through the shim (an operator typing `uvx` in a Lab terminal inherits
# this PATH) is passed through untouched.
labsh_pin_server_split() {
    local -a a=("$@")
    local i from=0
    for (( i = 0; i < ${#a[@]}; i++ )); do
        if [[ "${a[i]}" == --from && "${a[i+1]:-}" == jupyterlab ]]; then
            from=1
        elif [[ "${a[i]}" == --from=jupyterlab ]]; then
            from=1
        elif [[ "${a[i]}" == jupyter-lab ]]; then
            (( from )) || return 1
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}
