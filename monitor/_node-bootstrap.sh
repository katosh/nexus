#!/usr/bin/env bash
# monitor/_node-bootstrap.sh — shared Node.js bootstrap for nexus
# tooling that needs `node`/`npm` at run time but may run on an
# Lmod/Tcl-module HPC host where node lives behind `module load nodejs`
# rather than on the default PATH.
#
# Sourced by:
#   - monitor/install-claude-local.sh  (npm install of the pinned binary)
#   - monitor/cc-harness/gate.sh       (candidate install + real-binary
#                                        scenarios, both node consumers)
#
# Public entrypoint: nexus_ensure_node — best-effort, additive. Call it
# once before any node/npm use; it is a no-op (success) when node>=18 is
# already on PATH. It NEVER hard-fails a non-module host; the CALLER owns
# the fail-loud check afterwards (so each caller can phrase its own error).
#
# --- Node bootstrap via environment modules (Lmod / Tcl) -------------
#
# On Lmod-based HPC (e.g. your-institution cluster) `node` is provided by an
# environment module (`module load nodejs/...`), NOT on the default
# PATH. A non-login shell (the watcher launcher, a gate run) never
# loaded the module, so a bare `command -v node` check would fail and
# the caller would degrade or fail. Diagnosed in
# your-org/other-nexus#41; the docs-only upstream note is the closed
# your-org/nexus-code#212. This block makes the bootstrap itself robust
# so ANY site whose node lives behind a module bootstraps automatically,
# no manual ~/.bashrc edit.
#
# Strictly ADDITIVE: the bootstrap only runs when node is NOT already
# resolvable (no behavior change on hosts where node is on PATH), and it
# never hard-fails a non-module host — if no module system or no usable
# node module is found, the caller falls through to its own fail-loud +
# degrade path unchanged.
#
# Requires (best-effort, all guarded): NEXUS_ROOT may be set by the
# caller so the nexus.node_module config key can be consulted; if unset
# the bootstrap still works against env-var/default module names.

node_ok() {
    # node present AND major version >= 18 (Claude Code's floor).
    command -v node >/dev/null 2>&1 || return 1
    local v major
    v=$(node --version 2>/dev/null | sed 's/^v//')
    major=${v%%.*}
    [[ -n "$major" ]] && (( major >= 18 ))
}

ensure_module_function() {
    # `module` is a shell function injected by the modules init script;
    # non-login shells often lack it even when Lmod is installed. Detect
    # via the function itself or the env vars Lmod exports, then source
    # the first init script we find to make `module` callable. Returns 0
    # iff `module` is callable afterwards. Supports both Lmod and classic
    # Tcl environment-modules (their init/bash live in the same spots).
    if declare -F module >/dev/null 2>&1 || command -v module >/dev/null 2>&1; then
        return 0
    fi
    local inits=()
    if [[ -n "${NEXUS_MODULE_INIT:-}" ]]; then
        # Explicit init-script override, used EXCLUSIVELY when set: for a
        # site whose modules init lives somewhere non-standard, and the
        # hook the hermetic tests use to stand up a fake module system.
        inits=("$NEXUS_MODULE_INIT")
    else
        # Only worth sourcing if there's a hint a module system exists.
        [[ -n "${LMOD_CMD:-}" || -n "${MODULESHOME:-}" || -n "${LMOD_PKG:-}" \
            || -f /etc/profile.d/modules.sh ]] || return 1
        inits=(
            /etc/profile.d/modules.sh
            "${MODULESHOME:-}/init/bash"
            "${LMOD_PKG:-}/init/bash"
            "${LMOD_DIR:-}/../init/bash"
        )
    fi
    local init
    for init in "${inits[@]}"; do
        [[ -n "$init" && -f "$init" ]] || continue
        # shellcheck disable=SC1090
        . "$init" 2>/dev/null || continue
        if declare -F module >/dev/null 2>&1 || command -v module >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

module_load_quiet() {
    # CRITICAL: never PIPE `module load`. It mutates the CURRENT shell's
    # environment (PATH, LOADEDMODULES, …); a pipe runs it in a subshell
    # and the mutation is silently discarded. Redirect output to a temp
    # file instead so the env change persists in this process.
    local mod="$1" out rc
    out=$(mktemp /tmp/nexus-module-load.XXXXXX 2>/dev/null) || out=/dev/null
    module load "$mod" >"$out" 2>&1
    rc=$?
    [[ "$out" != /dev/null ]] && rm -f "$out"
    return "$rc"
}

discover_node_module() {
    # Highest-versioned `<base>/<ver>...` entry with major >= 18 from
    # `module -t avail <base>`. Terse (-t) output is one module per line;
    # the directory-header line ("/app/modules/all:") carries no
    # `<base>/<digit>` prefix and is filtered out. Sort by major (numeric)
    # then full string (version sort) and take the top — picks 20.13.1
    # over 20.9.0 and over any < 18. Empty stdout ⇒ no suitable module.
    local base="$1"
    module -t avail "$base" 2>&1 \
        | grep -iE "^${base}/[0-9]" \
        | awk -F/ '{
            n = split($2, a, /[.-]/); major = a[1] + 0;
            if (major >= 18) print major, $0;
        }' \
        | sort -k1,1n -k2,2V \
        | tail -n1 \
        | awk '{print $2}'
}

bootstrap_node_via_module() {
    # Module init scripts (/etc/profile.d/modules.sh, $MODULESHOME/init/
    # bash) and the `module` function itself routinely reference unbound
    # variables. A caller's `set -u` turns that into a FATAL exit
    # mid-source — NOT a catchable nonzero return — so the whole run would
    # die silently. Disable nounset for the module interaction and restore
    # the caller's setting at the single exit point below.
    local _had_u=0
    [[ $- == *u* ]] && _had_u=1
    set +u
    _bootstrap_node_via_module_impl
    local _rc=$?
    (( _had_u )) && set -u
    return "$_rc"
}

_bootstrap_node_via_module_impl() {
    # Returns 0 iff node>=18 is on PATH afterwards. No-op (success) when
    # node is already good — keeps the no-regression contract.
    node_ok && return 0
    ensure_module_function || return 1

    # Module name is configurable for sites whose node module isn't
    # named `nodejs`: env var NEXUS_NODE_MODULE wins; else the
    # nexus.node_module key from config/nexus.yml (best-effort — the
    # loader needs python3+pyyaml; any failure falls back); default
    # `nodejs`.
    local mod="${NEXUS_NODE_MODULE:-}"
    if [[ -z "$mod" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        mod=$(NEXUS_ROOT="$NEXUS_ROOT" "$NEXUS_ROOT/config/load.sh" \
            nexus.node_module nodejs 2>/dev/null) || mod=""
    fi
    [[ -n "$mod" ]] || mod=nodejs

    printf 'node-bootstrap: node not on PATH; attempting `module load %s` (module-based host, e.g. Lmod)\n' \
        "$mod" >&2
    module_load_quiet "$mod" || true
    if node_ok; then
        printf 'node-bootstrap: node provided by module %s (%s)\n' \
            "$mod" "$(node --version 2>/dev/null)" >&2
        return 0
    fi

    # Bare `module load <base>` yielded no node>=18 — either the site has
    # no default version for <base>, or its default is < 18. Discover the
    # highest >=18 versioned module and load it explicitly.
    local discovered
    discovered=$(discover_node_module "$mod") || discovered=""
    if [[ -n "$discovered" ]]; then
        printf 'node-bootstrap: module %s did not yield node>=18; loading discovered %s\n' \
            "$mod" "$discovered" >&2
        module_load_quiet "$discovered" || true
        if node_ok; then
            printf 'node-bootstrap: node provided by module %s (%s)\n' \
                "$discovered" "$(node --version 2>/dev/null)" >&2
            return 0
        fi
    fi
    return 1
}

nexus_ensure_node() {
    # Public entrypoint. Only bootstrap when node is absent — purely
    # additive, never invoked on a host that already has node on PATH.
    # Best-effort: returns 0 if node is (now) on PATH, non-zero otherwise;
    # callers own the fail-loud check so each can phrase its own error.
    if ! command -v node >/dev/null 2>&1; then
        bootstrap_node_via_module || true
    fi
    command -v node >/dev/null 2>&1
}
