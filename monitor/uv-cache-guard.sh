#!/usr/bin/env bash
# monitor/uv-cache-guard.sh — repair a DANGLING `locals/uv/cache` symlink
# before anything tries to run `uv`.
#
# SOURCE it for the function, or EXECUTE it to run the guard once:
#
#     source monitor/uv-cache-guard.sh && nexus_uv_cache_guard
#     monitor/uv-cache-guard.sh [CACHE_PATH]
#
# THE FAULT THIS CLOSES (jacob-greene/nexus#98, incident 2026-08-25)
# -----------------------------------------------------------------
# On a host where the nexus tree is on slow shared storage, `locals/uv/cache`
# is commonly a symlink onto a fast scratch filesystem:
#
#     locals/uv/cache -> <scratch-root>/nexus-uv-cache
#
# Scratch filesystems are purged on a schedule. The purge removes the TARGET.
# The symlink survives and becomes dangling. Every later `uv` call then fails:
#
#     error: Failed to initialize cache at .../locals/uv/cache
#       Caused by: failed to create directory `.../locals/uv/cache`:
#                  File exists (os error 17)
#
# The message is misleading. `uv` reports `File exists` because the SYMLINK
# exists; the real fault is that its target does not. Nothing in the message
# names either the symlink or the missing target. On 2026-08-25 this took a
# registered JupyterLab service down twice (20 min 18 s combined) and surfaced
# three layers from the cause as "nothing listening on the service port".
#
# The failure is not self-healing. `uv` will not create the target, and the
# supervised-restart policy retries the identical command against the identical
# broken symlink, so all three attempts fail the same way.
#
# WHAT THE GUARD DOES
# -------------------
# It repairs ONLY the dangling-symlink state, and it is a no-op everywhere
# else. Five distinct states, four of which it must not touch:
#
#   | State of the cache path        | Action        | Exit |
#   |--------------------------------|---------------|------|
#   | does not exist                 | none          | 0    |
#   | real directory                 | none          | 0    |
#   | symlink, target exists         | none          | 0    |
#   | symlink, target MISSING        | mkdir -p      | 10   |
#   | symlink, target UNSAFE to make | refuse + warn | 2    |
#
# Absent and real-directory are deliberately left alone. Provisioning the
# toolchain is `monitor/bootstrap-venv.sh`'s job, not this guard's; a guard
# that also created a missing cache would silently take over that role and
# would mask a `locals/` tree that was never provisioned.
#
# WHY `readlink -f` IS NOT USED
# -----------------------------
# `readlink -f` resolves every component and requires the final target to be
# resolvable. Here the target is missing — that is the whole defect — so the
# resolving form is the one form that cannot work. `readlink` (no flag) returns
# the link body VERBATIM, which is what we need. A verbatim body may be
# RELATIVE, and a relative body is interpreted against the symlink's OWN
# directory, not against the caller's cwd. Running `mkdir -p "$(readlink …)"`
# from the wrong cwd would create a directory in the wrong place and leave the
# real fault unrepaired. This guard therefore joins a relative body to
# `dirname <link>` before it creates anything.
#
# SAFETY — WHEN THE GUARD REFUSES
# -------------------------------
# A guard that creates directories on a cold-boot path must never invent a tree
# in an unexpected location. It refuses, loudly and without writing, when:
#
#   * the link body is empty;
#   * the resolved target is `/` or has fewer than two path components;
#   * the NEAREST EXISTING ANCESTOR of the target is `/`.
#
# The last rule is the load-bearing one. In the real fault the scratch
# filesystem is still mounted, so the nearest existing ancestor is its
# mountpoint, and the guard recreates only the per-user subtree beneath it.
# If the scratch filesystem were NOT mounted, or if the link were
# simply misconfigured, the nearest existing ancestor would be `/` — and
# creating the tree there would shadow the mountpoint with a directory on the
# root filesystem and hide the real problem. Refusing is the correct answer to
# both, and the warning names the link and the target so an operator can see
# which one it is.
#
# WHY IT WARNS (jacob-greene/nexus#98 review question 2)
# -----------------------------------------------------
# A silent recreate would hide the fact that scratch was purged. The uv cache
# is rebuildable, so losing it costs only rebuild time — but OTHER data under
# the same purged path is not necessarily rebuildable, and the purge is the
# only evidence that it is gone. The guard therefore records the event on three
# LOCAL, NON-BLOCKING surfaces:
#
#   1. a loud `WARNING` line on stderr — the forensic trail in the recovery log
#      and in the service log;
#   2. an append to `$NEXUS_STATE_DIR/uv-cache-purged.log` — durable, timestamped,
#      and it names the target, so the operator can see which scratch path to
#      check for other losses;
#   3. a best-effort `sandbox-notify` — the operator-visible tmux bell.
#
# It deliberately does NOT call `monitor/notify.sh`. That helper fans out to
# Pushover / ntfy / SMTP and needs network and credentials; this guard runs on
# the cold-boot path, where a blocking network call would delay recovery for
# every registered service. The warning cannot become noise: it is emitted only
# on the repair branch, and the repair makes every later call a no-op, so it
# fires at most once per purge.
#
# The `sandbox-notify` call is HARD-BOUNDED by `timeout`, for the same reason.
# It is a bell, not a result: nothing downstream reads it, and the durable
# record in surface 2 is what an operator actually inspects later. Measured on
# this host, an unbounded call hangs indefinitely when no tmux server is
# reachable — which is precisely the cold-boot case this guard runs on, and it
# would stall recovery for every registered service behind a bell nobody is
# waiting for. Surfaces 1 and 2 have already landed before it is attempted, so
# a timeout loses only the bell. Do not remove the bound.

# Resolve the nexus root from this file's own location so the guard works from
# any cwd, clone, or worktree. Honour a pre-set $NEXUS_ROOT.
_ucg_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
: "${NEXUS_ROOT:="$(cd "$_ucg_self_dir/.." 2>/dev/null && pwd)"}"

_ucg_log() { printf '[uv-cache-guard] %s\n' "$*" >&2; }

# Lexically normalise an ABSOLUTE path: collapse `//`, drop `.`, and resolve
# `..` against the accumulated prefix. Pure string work, no filesystem access —
# it must work on a path whose components do not exist.
_ucg_normalise() {
    local path="$1" out="" part
    local IFS=/
    # `set -f` for the split below: an unquoted expansion word-splits on IFS,
    # which is what we want, but it would ALSO glob, and a path component may
    # legitimately contain `*` or `?`.
    local reset_glob=""
    case "$-" in *f*) : ;; *) reset_glob=1; set -f ;; esac
    for part in $path; do
        case "$part" in
            ''|.) continue ;;
            ..)   out="${out%/*}" ;;
            *)    out="$out/$part" ;;
        esac
    done
    [ -n "$reset_glob" ] && set +f
    printf '%s' "${out:-/}"
}

# Print the nearest ancestor of $1 that exists on disk. Walks up until
# something exists; `/` always does, so this terminates.
_ucg_nearest_existing() {
    local p="$1"
    while [ "$p" != "/" ] && [ ! -e "$p" ]; do
        p="${p%/*}"
        [ -n "$p" ] || p="/"
    done
    printf '%s' "$p"
}

# Record a purge on the three local surfaces described in the header.
_ucg_record_purge() {
    local link="$1" target="$2"
    local state_dir="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"
    local msg="uv cache target was purged and has been recreated: $link -> $target"

    _ucg_log "WARNING: $msg"
    _ucg_log "WARNING: scratch storage under $target was purged — OTHER data"
    _ucg_log "WARNING: under the same path may also be gone. The uv cache itself"
    _ucg_log "WARNING: rebuilds on demand; check the path for anything that does not."

    if mkdir -p "$state_dir" 2>/dev/null; then
        printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$link" "$target" \
            >> "$state_dir/uv-cache-purged.log" 2>/dev/null || true
    fi

    # Hard-bounded: a bell must never stall the cold-boot path. See the header.
    if command -v sandbox-notify >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 5 sandbox-notify \
                "uv cache purged — recreated $target (check for other losses)" \
                >/dev/null 2>&1 </dev/null || true
        else
            sandbox-notify "uv cache purged — recreated $target (check for other losses)" \
                >/dev/null 2>&1 </dev/null || true
        fi
    fi
}

# nexus_uv_cache_guard [CACHE_PATH]
#
# CACHE_PATH defaults to $UV_CACHE_DIR, else <locals>/uv/cache. Returns
# 0 (nothing to do), 10 (repaired), 2 (refused — unsafe target),
# 3 (repair attempted and failed).
nexus_uv_cache_guard() {
    local link="${1:-}"
    if [ -z "$link" ]; then
        link="${UV_CACHE_DIR:-${NEXUS_LOCALS:-$NEXUS_ROOT/locals}/uv/cache}"
    fi

    # A non-symlink is never this guard's business: a real directory is
    # healthy, and an absent path is bootstrap-venv's job to provision.
    [ -L "$link" ] || return 0
    # A symlink whose target exists is healthy. `-e` follows the link, so it
    # is false exactly when the link dangles.
    [ -e "$link" ] && return 0

    local body
    body="$(readlink "$link" 2>/dev/null)"
    if [ -z "$body" ]; then
        _ucg_log "REFUSING: $link is a dangling symlink with an empty target"
        return 2
    fi

    # Join a RELATIVE body to the symlink's own directory — never to the
    # caller's cwd. Follow a chain of dangling links, bounded against a cycle.
    # `cur` walks the chain; `link` stays the ORIGINAL path so every message
    # names the link the caller actually asked about.
    local target="$body" cur="$link" hops=0 link_dir
    while :; do
        case "$target" in
            /*) : ;;
            *)
                link_dir="$(cd "$(dirname "$cur")" 2>/dev/null && pwd)" || link_dir=""
                if [ -z "$link_dir" ]; then
                    _ucg_log "REFUSING: cannot resolve the directory of $cur"
                    return 2
                fi
                target="$link_dir/$target"
                ;;
        esac
        target="$(_ucg_normalise "$target")"
        # The chain ends when the target is not itself a symlink.
        [ -L "$target" ] || break
        hops=$(( hops + 1 ))
        if [ "$hops" -ge 8 ]; then
            _ucg_log "REFUSING: symlink chain from $link exceeds 8 hops (cycle?)"
            return 2
        fi
        cur="$target"
        target="$(readlink "$cur" 2>/dev/null)"
        if [ -z "$target" ]; then
            _ucg_log "REFUSING: symlink chain from $link ends in an empty target"
            return 2
        fi
    done

    # Refuse the filesystem root and any single top-level component — neither
    # is a plausible uv cache, and creating one would put a directory
    # somewhere no purge could have removed it from.
    case "$target" in
        /*/*) : ;;
        *)
            _ucg_log "REFUSING: $link points at '$target', which is not a plausible cache path"
            return 2 ;;
    esac

    # Refuse when the whole prefix is missing. See the SAFETY note in the
    # header: an unmounted scratch filesystem and a misconfigured link both
    # land here, and creating the tree would shadow a mountpoint on the root
    # filesystem and hide the real fault.
    local anchor
    anchor="$(_ucg_nearest_existing "$target")"
    if [ "$anchor" = "/" ]; then
        _ucg_log "REFUSING: no existing ancestor of '$target' below /"
        _ucg_log "REFUSING: (the filesystem is probably not mounted, or $link is misconfigured)"
        return 2
    fi
    if [ ! -d "$anchor" ]; then
        _ucg_log "REFUSING: nearest existing ancestor '$anchor' of '$target' is not a directory"
        return 2
    fi

    if ! mkdir -p "$target" 2>/dev/null || [ ! -d "$target" ]; then
        _ucg_log "FAILED: could not create the uv cache target '$target' (from $link)"
        return 3
    fi

    _ucg_record_purge "$link" "$target"
    return 10
}

# Executed directly (not sourced) — run the guard once and exit with its code.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
    nexus_uv_cache_guard "$@"
    exit $?
fi
