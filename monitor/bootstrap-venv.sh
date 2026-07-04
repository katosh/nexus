#!/usr/bin/env bash
# monitor/bootstrap-venv.sh — provision + activate a Python venv backed by the
# NEXUS-WIDE, self-contained, project-local toolchain. ZERO home-dir and ZERO
# Lmod dependency.
#
# SOURCE this (do not execute) so it can set env + activate IN your shell:
#
#     source monitor/bootstrap-venv.sh                  # venv for this project
#     source monitor/bootstrap-venv.sh --python 3.11    # pin a version
#     source monitor/bootstrap-venv.sh --name fig       # name the venv
#     source monitor/bootstrap-venv.sh --dir .venv      # explicit in-tree venv
#
# then `uv pip install ...` / `python ...` as usual.
#
# NEXUS-WIDE MODEL (operator steer on #307):
#   The toolchain — the standalone `uv` binary AND the managed Python
#   interpreters + cache — lives ONCE at the nexus root (`$NEXUS_ROOT/locals/`),
#   shared across every project, NOT downloaded per `work/<project>`. Nexus
#   infra never extends into a work-dir's git repo. Per-project venvs layer on
#   top under `locals/venvs/<name>`, their interpreter symlinking into the
#   shared `locals/uv/python` (so they stay out of the work repos too).
#
# WHAT IT GUARANTEES (and why each matters):
#
#   1. NO home install assumed. `uv` itself is fetched STANDALONE —
#      pinned-by-version + SHA256-verified — into `locals/bin/`. We never rely
#      on a `uv` in `$HOME` (`~/.local/bin`, `~/.linuxbrew`) or a system/Lmod
#      uv. The static musl build is the default target, so it runs on any Linux
#      HPC regardless of host glibc.
#
#   2. NO $HOME writes. Every byte of uv's state is redirected into the nexus
#      tree via monitor/locals-env.sh: managed interpreters
#      (UV_PYTHON_INSTALL_DIR), cache (UV_CACHE_DIR), tool store (UV_TOOL_DIR)
#      all land under `locals/`. uv's defaults otherwise derive from $HOME/XDG.
#
#   3. NO Lmod. The interpreter is provisioned by the project-local uv
#      (`uv python install` → `locals/uv/python/...`); no `module load Python`.
#      Portable to HPC where Lmod is absent. `unset PYTHONPATH` so a pre-existing
#      Lmod Python shadow can't leak into the venv.
#
#   4. Survives the Slurm/bwrap fresh-tmpfs $HOME. The interpreter + toolchain
#      live under `locals/` in the (mounted, writable) nexus tree, so they
#      remain visible on the compute node after the chaperon's bwrap re-wrap
#      hands the job a fresh-tmpfs $HOME. `--python-preference only-managed`
#      forbids a home-resident brew/system python fallback.
#
# First run needs network (downloads the standalone uv + the managed
# interpreter) and builds the venv; do it ONCE on a networked node, then reuse
# (fully offline) on compute — and, because the toolchain is nexus-wide, reuse
# across every other project too.
#
# Flags: --python VER | --name NAME | --dir VENV_DIR | --root NEXUS_ROOT
#        --locals DIR | --dry-run | -h
#   --name  venv name under locals/venvs/ (default: basename of cwd)
#   --dir   explicit venv path (absolute, or relative to cwd) — overrides --name
#   --root  nexus root (default: $NEXUS_ROOT, else this script's monitor/..)
#   --locals  toolchain root (default: <root>/locals); mainly for tests
#   --dry-run sets env + prints the plan WITHOUT any download/build (hermetic).
#
# Env overrides (reproducibility / portability):
#   BV_UV_VERSION   pinned uv release         (default below)
#   BV_UV_TARGET    release target triple     (default: musl for the arch)
#   BV_UV_BASE_URL  release download base URL (default: GitHub releases)

# --- pinned standalone uv ----------------------------------------------
# Bump together: version + the SHA256 of every target's release tarball
# (from https://github.com/astral-sh/uv/releases/download/<ver>/<t>.tar.gz.sha256).
_BV_UV_VERSION_DEFAULT=0.9.25
_bv_uv_sha() {  # $1=target -> echo sha256, or empty if unknown for this pin
    case "${BV_UV_VERSION:-$_BV_UV_VERSION_DEFAULT}:$1" in
        0.9.25:x86_64-unknown-linux-musl)  echo 700776c376ce36ed5b731fcd699e141d897551f5111907987b63897e0c1ad797 ;;
        0.9.25:x86_64-unknown-linux-gnu)   echo fa1f4abfe101d43e820342210c3c6854028703770f81e95b119ed1e65ec81b35 ;;
        0.9.25:aarch64-unknown-linux-musl) echo 11cddffc61826e3b7af02db37bc3ed8e9e6747dad328d45c8b02f89408afbf75 ;;
        0.9.25:aarch64-unknown-linux-gnu)  echo a8f1d71a42c4470251a880348b2d28d530018693324175084fa1749d267c98c6 ;;
        *) echo "" ;;
    esac
}

# --- locate this script (sibling locals-env.sh, monitor/..) ------------
_bv_self="${BASH_SOURCE[0]:-$0}"
_bv_self_dir=$(cd "$(dirname "$_bv_self")" 2>/dev/null && pwd)

# --- argument parse -----------------------------------------------------
_bv_py=3.12
_bv_name=""
_bv_dir=""
_bv_root=""
_bv_locals=""
_bv_dry=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --python) _bv_py="$2"; shift 2 ;;
        --name)   _bv_name="$2"; shift 2 ;;
        --dir)    _bv_dir="$2"; shift 2 ;;
        --root)   _bv_root="$2"; shift 2 ;;
        --locals) _bv_locals="$2"; shift 2 ;;
        --dry-run) _bv_dry=1; shift ;;
        -h|--help)
            sed -n '2,66p' "$_bv_self" | sed 's/^# \{0,1\}//'
            return 0 2>/dev/null || exit 0 ;;
        *) printf 'bootstrap-venv: unknown arg: %s\n' "$1" >&2
           return 2 2>/dev/null || exit 2 ;;
    esac
done

# --- resolve the nexus root + nexus-wide locals -------------------------
[[ -n "$_bv_root" ]] || _bv_root="${NEXUS_ROOT:-$(cd "$_bv_self_dir/.." 2>/dev/null && pwd)}"
_bv_root=$(cd "$_bv_root" 2>/dev/null && pwd) || {
    printf 'bootstrap-venv: cannot resolve nexus root (--root / $NEXUS_ROOT)\n' >&2
    return 2 2>/dev/null || exit 2
}
[[ -n "$_bv_locals" ]] || _bv_locals="$_bv_root/locals"

_bv_version="${BV_UV_VERSION:-$_BV_UV_VERSION_DEFAULT}"

# --- resolve the standalone uv target triple ---------------------------
# Default to the STATIC musl build: no host-glibc dependency, so the same
# binary runs on this sandbox (glibc 2.27) and on any other Linux HPC.
if [[ -n "${BV_UV_TARGET:-}" ]]; then
    _bv_target="$BV_UV_TARGET"
else
    case "$(uname -m)" in
        x86_64|amd64)   _bv_arch=x86_64 ;;
        aarch64|arm64)  _bv_arch=aarch64 ;;
        *) printf 'bootstrap-venv: unsupported arch %s — set BV_UV_TARGET\n' "$(uname -m)" >&2
           return 2 2>/dev/null || exit 2 ;;
    esac
    _bv_target="${_bv_arch}-unknown-linux-musl"
fi
_bv_base_url="${BV_UV_BASE_URL:-https://github.com/astral-sh/uv/releases/download}"

# --- join the nexus-wide toolchain env (PATH + UV_* -> locals/) ---------
# Single source of truth: monitor/locals-env.sh. We pin its target via
# NEXUS_LOCALS so a custom --locals (tests) is honoured; the file is a sibling
# of this script, so it is always present regardless of --root.
export NEXUS_LOCALS="$_bv_locals"
# shellcheck disable=SC1090,SC1091
[[ -f "$_bv_self_dir/locals-env.sh" ]] && . "$_bv_self_dir/locals-env.sh"
unset PYTHONPATH                                         # drop any Lmod shadow

_bv_uvbin="$_bv_locals/bin/uv"

# --- resolve the per-project venv path ---------------------------------
# Default: a named venv under the nexus-wide locals/venvs/ (out of the work
# repo). --dir gives an explicit path (absolute, or relative to cwd).
if [[ -n "$_bv_dir" ]]; then
    case "$_bv_dir" in
        /*) _bv_venv="$_bv_dir" ;;
        *)  _bv_venv="$PWD/$_bv_dir" ;;
    esac
else
    [[ -n "$_bv_name" ]] || _bv_name=$(basename "$PWD")
    _bv_venv="$_bv_locals/venvs/$_bv_name"
fi

_bv_tarurl="$_bv_base_url/$_bv_version/uv-$_bv_target.tar.gz"
_bv_expsha="$(_bv_uv_sha "$_bv_target")"

# The load-bearing recipe. `only-managed` forbids falling back to the
# home-resident brew/system python; combined with UV_PYTHON_INSTALL_DIR the
# interpreter lands under the nexus tree. `--no-bin` skips the ~/.local/bin
# shim that would otherwise EROFS-warn under the sandbox.
_bv_install=("$_bv_uvbin" python install --no-bin "$_bv_py")
_bv_create=("$_bv_uvbin" venv --python "$_bv_py" --python-preference only-managed "$_bv_venv")

if [[ $_bv_dry -eq 1 ]]; then
    printf 'NEXUS_ROOT=%s\n' "$_bv_root"
    printf 'LOCALS=%s\n' "$_bv_locals"
    printf 'VENV=%s\n' "$_bv_venv"
    printf 'UV_PYTHON_INSTALL_DIR=%s\n' "$UV_PYTHON_INSTALL_DIR"
    printf 'UV_CACHE_DIR=%s\n' "$UV_CACHE_DIR"
    printf 'UV_TOOL_DIR=%s\n' "$UV_TOOL_DIR"
    printf 'UV_BIN=%s\n' "$_bv_uvbin"
    printf 'PATH_HAS_LOCALS_BIN=%s\n' "$(case ":$PATH:" in *":$_bv_locals/bin:"*) echo yes;; *) echo no;; esac)"
    printf 'PLAN: fetch standalone uv %s (%s) -> %s\n' "$_bv_version" "$_bv_target" "$_bv_uvbin"
    printf 'PLAN: verify sha256 %s\n' "${_bv_expsha:-<none-for-target>}"
    printf 'PLAN: url %s\n' "$_bv_tarurl"
    printf 'PLAN: %s\n' "${_bv_install[*]}"
    printf 'PLAN: %s\n' "${_bv_create[*]}"
    printf 'PLAN: source %s/bin/activate\n' "$_bv_venv"
    return 0 2>/dev/null || exit 0
fi

# --- fetch the standalone uv (pinned + checksum-verified) --------------
# Reuse an existing project-local uv whose version already matches the pin
# (fully offline). Otherwise download + SHA256-verify into locals/bin/.
# We NEVER fall back to a system/home uv — that is the dependency we are
# eliminating.
_bv_fetch_uv() {
    if [[ -x "$_bv_uvbin" ]] && "$_bv_uvbin" --version 2>/dev/null | grep -qw "$_bv_version"; then
        return 0    # already provisioned at the pinned version
    fi
    if [[ -z "$_bv_expsha" ]]; then
        printf 'bootstrap-venv: no pinned checksum for target %s at uv %s\n' \
            "$_bv_target" "$_bv_version" >&2
        printf '  set BV_UV_TARGET to a pinned triple, or add its sha to _bv_uv_sha.\n' >&2
        return 1
    fi
    command -v curl >/dev/null 2>&1 || {
        printf 'bootstrap-venv: curl not found — cannot fetch standalone uv\n' >&2; return 1; }

    local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/bv-uv.XXXXXX") || return 1
    printf 'bootstrap-venv: fetching standalone uv %s (%s)...\n' "$_bv_version" "$_bv_target" >&2
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/uv.tar.gz" "$_bv_tarurl"; then
        printf 'bootstrap-venv: download failed (%s). Networked node required for first run.\n' \
            "$_bv_tarurl" >&2
        rm -rf "$tmp"; return 1
    fi
    local got; got=$(sha256sum "$tmp/uv.tar.gz" | awk '{print $1}')
    if [[ "$got" != "$_bv_expsha" ]]; then
        printf 'bootstrap-venv: SHA256 MISMATCH for uv tarball\n  expected %s\n  got      %s\n' \
            "$_bv_expsha" "$got" >&2
        rm -rf "$tmp"; return 1
    fi
    if ! tar -xzf "$tmp/uv.tar.gz" -C "$tmp"; then
        printf 'bootstrap-venv: extract failed\n' >&2; rm -rf "$tmp"; return 1
    fi
    # Release tarball unpacks to uv-<target>/{uv,uvx}.
    mkdir -p "$_bv_locals/bin"
    install -m 0755 "$tmp/uv-$_bv_target/uv"  "$_bv_locals/bin/uv"  || { rm -rf "$tmp"; return 1; }
    [[ -f "$tmp/uv-$_bv_target/uvx" ]] && install -m 0755 "$tmp/uv-$_bv_target/uvx" "$_bv_locals/bin/uvx"
    rm -rf "$tmp"
    "$_bv_uvbin" --version 2>/dev/null | grep -qw "$_bv_version" || {
        printf 'bootstrap-venv: fetched uv does not report version %s\n' "$_bv_version" >&2; return 1; }
    return 0
}

if ! _bv_fetch_uv; then
    unset -f _bv_fetch_uv _bv_uv_sha 2>/dev/null
    return 1 2>/dev/null || exit 1
fi
unset -f _bv_fetch_uv _bv_uv_sha 2>/dev/null

# Idempotent reuse: keep an existing venv only if its interpreter already
# resolves inside the nexus tree (a stale home-symlinked venv is rebuilt).
_bv_reuse=0
if [[ -x "$_bv_venv/bin/python" ]]; then
    _bv_real=$(readlink -f "$_bv_venv/bin/python" 2>/dev/null)
    case "$_bv_real" in
        "$_bv_root"/*|"$_bv_locals"/*) _bv_reuse=1 ;;
        *) printf 'bootstrap-venv: %s points outside nexus tree (%s) — rebuilding\n' \
               "$_bv_venv/bin/python" "$_bv_real" >&2
           rm -rf "$_bv_venv" ;;
    esac
fi

if [[ $_bv_reuse -eq 0 ]]; then
    mkdir -p "$(dirname "$_bv_venv")"
    "${_bv_install[@]}" || { printf 'bootstrap-venv: uv python install failed\n' >&2
        return 1 2>/dev/null || exit 1; }
    "${_bv_create[@]}"  || { printf 'bootstrap-venv: uv venv failed\n' >&2
        return 1 2>/dev/null || exit 1; }
fi

# shellcheck disable=SC1090
source "$_bv_venv/bin/activate" || {
    printf 'bootstrap-venv: activate failed (did you `source` this script?)\n' >&2
    return 1 2>/dev/null || exit 1
}
printf 'bootstrap-venv: venv %s active; uv %s; interpreter %s\n' \
    "$_bv_venv" "$_bv_version" "$(readlink -f "$_bv_venv/bin/python")"
