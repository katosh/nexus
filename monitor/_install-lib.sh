#!/usr/bin/env bash
# monitor/_install-lib.sh — shared primitives for the bootstrap-side
# component installers (install-hpc-skills.sh, install-labsh.sh).
#
# Sourced, not executed. These make the bootstrap reliable, idempotent,
# interruption-safe, and concurrency-safe:
#
#   install_acquire_lock <name>   advisory flock on a LOCAL fs (flock over
#                                 NFS is unreliable, and ~/.claude is NFS on
#                                 the cluster). Two simultaneous bootstrap
#                                 opens → one sets up, the other waits then
#                                 sees it complete. Kernel releases the lock
#                                 when the holder dies, so a crashed run never
#                                 deadlocks a later one.
#   install_atomic_clone <url> <target>
#                                 clone into a temp sibling then rename into
#                                 place — an interrupted clone leaves only the
#                                 temp dir, never a half-populated <target> a
#                                 later run mistakes for "installed".
#   install_clean_temps <target>  remove temp dirs left by a crashed clone
#                                 (caller must hold the lock).
#   install_dir_is_repo <dir>     cheap structural "<dir> is a git checkout".
#   install_remote_matches <dir> <substr>
#                                 <dir>'s origin URL contains <substr>.
#
# All functions are namespaced install_* and safe under `set -uo pipefail`.

# Local filesystem only for the lock (NFS flock is unreliable).
install_lock_dir() {
    printf '%s\n' "${NEXUS_INSTALL_LOCK_DIR:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}}"
}

# install_acquire_lock <name>
#   Take an exclusive advisory lock on fd 9. Non-blocking first; if held,
#   print a notice and block up to 300s. No-ops (with a warning) if flock is
#   unavailable. Returns nonzero only on a wait-timeout.
install_acquire_lock() {
    local name="$1" dir lockfile
    dir="$(install_lock_dir)"
    mkdir -p "$dir" 2>/dev/null || true
    lockfile="$dir/nexus-install-${name}.$(id -u).lock"
    # flock-fd: fd 9 is DELIBERATELY held across the caller's whole
    # install, including its git/clone children — the lock's job is to
    # serialize the entire install, and those children are foreground
    # and die with it. A child that daemonized (e.g. a git credential
    # helper) would hold the lock; installers clone anonymous public
    # URLs, so none is spawned. Class: your-org/nexus-code#494.
    if ! exec 9>"$lockfile"; then
        printf 'install-lib: WARNING: cannot open lock %s — proceeding without concurrency guard\n' "$lockfile" >&2
        return 0
    fi
    if ! command -v flock >/dev/null 2>&1; then
        printf 'install-lib: WARNING: flock unavailable — proceeding without concurrency guard\n' >&2
        return 0
    fi
    if ! flock -n 9; then
        printf 'install-lib: another install is in progress, waiting (up to 300s)…\n' >&2
        flock -w 300 9 || {
            printf 'install-lib: timed out waiting for a concurrent install (lock: %s). If stale, remove it and retry.\n' "$lockfile" >&2
            return 1
        }
    fi
    return 0
}

# install_dir_is_repo <dir> — true if <dir> looks like a git checkout.
install_dir_is_repo() { [ -d "$1/.git" ]; }

# install_remote_matches <dir> <substr> — true if <dir>'s origin URL matches.
install_remote_matches() {
    local dir="$1" want="$2" url
    install_dir_is_repo "$dir" || return 1
    url="$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)"
    case "$url" in *"$want"*) return 0 ;; *) return 1 ;; esac
}

# install_clean_temps <target> — remove leftover atomic-clone temp dirs.
install_clean_temps() {
    local target="$1" t
    for t in "${target}.clone-tmp."*; do
        [ -e "$t" ] || continue
        printf 'install-lib: removing leftover temp clone %s\n' "$t" >&2
        rm -rf "$t"
    done
}

# install_atomic_clone <url> <target>
#   Clone into a temp sibling of <target>, then rename into place. On clone
#   failure, leaves nothing behind and returns nonzero. Caller ensures
#   <target> does not already exist.
install_atomic_clone() {
    local url="$1" target="$2" tmp
    tmp="${target}.clone-tmp.$$"
    rm -rf "$tmp"
    mkdir -p "$(dirname "$target")" || return 1
    if ! git clone "$url" "$tmp"; then
        rm -rf "$tmp"
        return 1
    fi
    if ! mv -T "$tmp" "$target" 2>/dev/null && ! mv "$tmp" "$target" 2>/dev/null; then
        rm -rf "$tmp"
        return 1
    fi
    return 0
}
