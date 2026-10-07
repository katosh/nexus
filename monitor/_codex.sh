#!/usr/bin/env bash
# monitor/_codex.sh — shared resolvers for the OpenAI Codex CLI
# (your-org/nexus-code#1640). Sourced, never executed.
#
# One file for every Codex fact the nexus depends on, so a version bump or a
# config rename lands in one place instead of drifting across codex-run.sh,
# spawn surfaces and tests. The Claude Code equivalents are split across
# _claude-bin.sh and _cc-version.sh; this is deliberately one smaller file.
#
# Functions (all NON-destructive: they return a status, they never `exit`,
# because a co-worker helper that dies inside a sourced resolver takes its
# caller's shell with it):
#
#   codex_bin                 → absolute path of the codex binary; rc 1 if none
#   codex_version_expected    → the version the nexus expects; rc 1 none, rc 3
#                               the local pin file EXISTS but is blank/garbage
#   codex_version_installed   → `codex --version` parsed; rc 1 if it cannot run
#   codex_model_default       → config monitor.codex.model, else the built-in
#   codex_auth_env            → prints ONE env assignment to inject (or nothing)
#
# Measured facts this file encodes (codex-cli 0.156.1, 2026-09-26):
#
#   * `codex exec` does NOT read OPENAI_API_KEY. With only OPENAI_API_KEY set
#     it gets `401 Missing bearer`; with CODEX_API_KEY set to the same value
#     the key is accepted. The agent-sandbox provisions OPENAI_API_KEY (its
#     codex overlay lists both names as credential vars), so exec needs the
#     mapping. The interactive TUI reads NEITHER: it needs $CODEX_HOME/auth.json
#     (`codex login --with-api-key` reading the key on STDIN). codex_auth_env
#     only serves the exec path, and it never puts the key in argv.
#   * The default model of the bundled catalogue is `gpt-6-astra`
#     ("Frontier intelligence for the most demanding work"). `gpt-6-sol`
#     is the catalogue's "workhorse model for coding". We CHOSE astra as the
#     default because the operator asked for the best coding model the CLI
#     supports; it is a config value (monitor.codex.model), not a constant
#     scattered through callers.

if [[ -n "${_NEXUS_CODEX_LOADED:-}" ]]; then
    return 0
fi
_NEXUS_CODEX_LOADED=1

_codex_root() {
    local r="${NEXUS_ROOT:-}"
    if [[ -z "$r" ]]; then
        r=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    fi
    printf '%s' "$r"
}

# The model used when config says nothing. CHOSEN, not upstream convention:
# see the header. Callers read codex_model_default, never this literal.
_NEXUS_CODEX_BUILTIN_MODEL="gpt-6-astra"

# codex_bin — resolution order mirrors _claude-bin.sh:
#   1. $CODEX_BIN (operator override / test seam)
#   2. <nexus_root>/codex-cli/node_modules/.bin/codex — the
#      project-local, pinned install (monitor/install-codex-local.sh). NOT the
#      root node_modules: see codex-cli/package.json for why.
#   3. `codex` on PATH
codex_bin() {
    local root; root=$(_codex_root)
    if [[ -n "${CODEX_BIN:-}" ]]; then
        [[ -x "$CODEX_BIN" ]] || { printf '_codex.sh: CODEX_BIN=%s is not executable\n' "$CODEX_BIN" >&2; return 1; }
        printf '%s\n' "$CODEX_BIN"; return 0
    fi
    if [[ -x "$root/codex-cli/node_modules/.bin/codex" ]]; then
        printf '%s\n' "$root/codex-cli/node_modules/.bin/codex"; return 0
    fi
    local p
    if p=$(command -v codex 2>/dev/null) && [[ -n "$p" ]]; then
        printf '%s\n' "$p"; return 0
    fi
    return 1
}

# codex_version_local_pin_path — mirror of the cc scheme (#226): a gitignored
# operator-local pin OVERRIDES the package.json floor.
codex_version_local_pin_path() {
    if [[ -n "${NEXUS_CODEX_LOCAL_PIN:-}" ]]; then
        printf '%s\n' "$NEXUS_CODEX_LOCAL_PIN"; return 0
    fi
    printf '%s\n' "${NEXUS_STATE_DIR:-$(_codex_root)/monitor/.state}/codex-version-local"
}

# codex_version_expected — local pin, else the codex-cli/package.json
# floor.
#
# Unlike cc_version_read_local_pin, a pin file that EXISTS but holds no
# version is NOT folded into "no pin" (CLAUDE.md, the FALLBACK-COLLAPSE
# entry: a torn write and an absent file are different worlds). It is rc 3,
# and the caller must not silently fall back to the floor.
codex_version_expected() {
    local root pin_path raw
    root=$(_codex_root)
    pin_path=$(codex_version_local_pin_path)
    if [[ -e "$pin_path" ]]; then
        raw=$(<"$pin_path") || return 3
        raw="${raw#"${raw%%[![:space:]]*}"}"
        raw="${raw%"${raw##*[![:space:]]}"}"
        if [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
            printf '%s\n' "$raw"; return 0
        fi
        printf '_codex.sh: local pin %s exists but holds no version (%q)\n' "$pin_path" "$raw" >&2
        return 3
    fi
    local pj="$root/codex-cli/package.json" out
    [[ -f "$pj" ]] || return 1
    out=$(awk -F'"' '{ for (i=1; i+2<=NF; i++) if ($i=="@openai/codex") { print $(i+2); exit } }' "$pj")
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

# codex_version_installed [bin] — parse `codex-cli X.Y.Z` from --version.
# stdin is /dev/null: codex reads stdin when it is not a tty (measured for
# exec) and an inherited agent stdin would block.
codex_version_installed() {
    local bin="${1:-}"
    [[ -n "$bin" ]] || bin=$(codex_bin) || return 1
    local out
    out=$(timeout 30 "$bin" --version </dev/null 2>/dev/null) || return 1
    # Full read + END, not `{print; exit}`: an early-exit reader on a pipe is
    # the #1446 shape, and there is nothing to gain by stopping early here.
    out=$(printf '%s\n' "$out" | awk '/^codex-cli / && v=="" {v=$2} END {print v}')
    [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1
    printf '%s\n' "$out"
}

# codex_model_default — config monitor.codex.model, else the built-in.
codex_model_default() {
    local root cfg m=""
    root=$(_codex_root)
    cfg="$root/config/load.sh"
    if [[ -x "$cfg" ]]; then
        m=$("$cfg" monitor.codex.model "" 2>/dev/null) || m=""
    fi
    [[ -n "$m" ]] || m="$_NEXUS_CODEX_BUILTIN_MODEL"
    printf '%s\n' "$m"
}

# codex_auth_env — the ONE env assignment `codex exec` needs, printed as
# NAME (the caller exports NAME from the variable of the same value). We
# print only the NAME of the source variable, never its value, so nothing
# that logs this function's output can leak the key.
#
#   prints "CODEX_API_KEY<-OPENAI_API_KEY"  when mapping is needed
#   prints ""                               when CODEX_API_KEY is already set,
#                                           or no key is present (auth.json
#                                           may still carry a login)
codex_auth_env() {
    if [[ -n "${CODEX_API_KEY:-}" ]]; then
        return 0
    fi
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        printf 'CODEX_API_KEY<-OPENAI_API_KEY\n'
    fi
    return 0
}

# codex_auth_state — presence only, never a value.
#   api-key-env | auth-json | none
codex_auth_state() {
    if [[ -n "${CODEX_API_KEY:-}" || -n "${OPENAI_API_KEY:-}" ]]; then
        printf 'api-key-env\n'; return 0
    fi
    local home="${CODEX_HOME:-$HOME/.codex}"
    if [[ -s "$home/auth.json" ]]; then
        printf 'auth-json\n'; return 0
    fi
    printf 'none\n'
}
