#!/usr/bin/env bash
# monitor/_trash.sh — move-aside-before-install ("trash, don't rm").
#
# WHY THIS EXISTS (your-org/nexus-code#310, #312). On NFS a file that a
# running process holds open CANNOT be unlinked: `unlink(2)` silly-renames
# it to a `.nfs<hex>` lock and the caller sees EBUSY ("resource busy" /
# "Directory not empty"). `npm`/installers swapping a binary that live
# agents are executing trip on exactly this — the install aborts and can
# leave the tree without a working binary (#312). `rename(2)`, by
# contrast, DOES succeed on a held-open inode: the inode keeps living
# under its new name, the holder is undisturbed, and the original path is
# free for a fresh install. No `.nfs` lock is created because nothing was
# unlinked.
#
# So the standing pattern the operator asked for (#310): before any
# install that swaps a binary/package, MOVE the existing target into a
# gitignored trash dir (a `rename`, not an `rm`), then install fresh. The
# trash is cleared periodically — or never — by `clear_trash`; it is NEVER
# auto-cleared on a normal run (safety: keep the prior binary recoverable).
#
# Dual use — source it, or run it:
#   . monitor/_trash.sh           # then call trash_path / clear_trash
#   monitor/_trash.sh trash <target> [<trash-root>]
#   monitor/_trash.sh --clear [--older-than <days>] [--root <dir>]
#   monitor/_trash.sh --list  [--root <dir>]
#
# No sandbox dependency: plain `mv` + a gitignored dir. Works identically
# inside and outside the agent-sandbox. Idempotent: trashing a missing
# target is a silent no-op; every trashed entry gets a unique name so a
# re-run never collides with a prior one.

# Guard against double-sourcing clobbering an outer `set -e` etc. — only
# set our own options when executed directly (see CLI dispatch at bottom).

_trash_self_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# nexus root = parent of monitor/
_TRASH_NEXUS_ROOT=$(cd "$_trash_self_dir/.." && pwd)

# Default trash root: gitignored monitor/.state/.trash (covered by
# monitor/.gitignore's `.state/`). Overridable via NEXUS_TRASH_DIR for a
# site that wants trash elsewhere.
_trash_default_root() {
    printf '%s' "${NEXUS_TRASH_DIR:-$_TRASH_NEXUS_ROOT/monitor/.state/.trash}"
}

# Device id of the nearest EXISTING ancestor of $1 (the dir doesn't have
# to exist yet). Empty on error. Used to keep the move a same-filesystem
# rename — a cross-fs `mv` degrades to copy+unlink, and the unlink would
# reintroduce the very EBUSY/.nfs failure we are avoiding.
_trash_dev() {
    local p="$1"
    while [[ ! -e "$p" && "$p" != "/" && -n "$p" ]]; do
        p=$(dirname "$p")
    done
    stat -c '%d' "$p" 2>/dev/null
}

# trash_path <target> [<trash-root>]
#   If <target> exists (file, dir, or even a dangling symlink), rename it
#   into the trash root under a unique, timestamped name and echo the new
#   path on stdout. If it doesn't exist, no-op (idempotent) and echo
#   nothing. Returns 0 on success or no-op, non-zero only if the move
#   genuinely failed.
#
#   Same-filesystem guarantee: if the chosen trash root is on a DIFFERENT
#   filesystem than the target, fall back to a `.nexus-trash` dir beside
#   the target's parent so the operation stays a pure `rename(2)` (safe on
#   held-open inodes). This is what makes the helper correct for throwaway
#   prefixes under $TMPDIR as well as for node_modules under the repo.
trash_path() {
    local target="$1" trash_root="${2:-$(_trash_default_root)}"
    # Existence check that also catches a dangling symlink (-e follows the
    # link and would be false for a broken one; -L catches the link itself).
    if [[ ! -e "$target" && ! -L "$target" ]]; then
        return 0
    fi

    # Keep it a same-fs rename. Compare the device of the target's PARENT
    # (the dir the rename happens within — robust even when target is a
    # symlink, whose own device stat would follow the link) against the
    # trash root's device.
    local parent target_dev root_dev
    parent=$(cd "$(dirname "$target")" 2>/dev/null && pwd) || parent=$(dirname "$target")
    target_dev=$(_trash_dev "$parent")
    root_dev=$(_trash_dev "$trash_root")
    if [[ -n "$target_dev" && -n "$root_dev" && "$target_dev" != "$root_dev" ]]; then
        trash_root="$parent/.nexus-trash"
    fi

    mkdir -p "$trash_root" 2>/dev/null || {
        printf '_trash: cannot create trash dir: %s\n' "$trash_root" >&2
        return 1
    }

    # Unique destination: <basename>-<utc-ts>-<pid>-<rand>. The ts+pid+rand
    # triple guarantees no collision across concurrent/repeated installs,
    # which is what keeps re-running an install idempotent.
    local base ts dest
    base=$(basename "$target")
    ts=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)
    dest="$trash_root/${base}-${ts}-$$-${RANDOM}"

    if mv "$target" "$dest" 2>/dev/null; then
        printf '%s\n' "$dest"
        return 0
    fi
    printf '_trash: failed to move %s -> %s\n' "$target" "$dest" >&2
    return 1
}

# clear_trash [--older-than <days>] [--root <dir>]
#   Best-effort purge of trash entries. NEVER called automatically on an
#   install — manual / periodic only (operator default: never). An entry a
#   process still holds open can't be fully removed; `rm` silly-renames its
#   open files to `.nfs*` (themselves gitignored) and we leave those for a
#   later sweep once the holder cycles. Reports what it purged / kept /
#   could-not-remove.
clear_trash() {
    local days="" root=""
    while (( $# > 0 )); do
        case "$1" in
            --older-than) days="$2"; shift 2 ;;
            --older-than=*) days="${1#--older-than=}"; shift ;;
            --root) root="$2"; shift 2 ;;
            --root=*) root="${1#--root=}"; shift ;;
            *) printf '_trash: clear_trash: unknown arg: %s\n' "$1" >&2; return 2 ;;
        esac
    done
    root="${root:-$(_trash_default_root)}"
    if [[ ! -d "$root" ]]; then
        printf '_trash: nothing to clear (no trash dir at %s)\n' "$root"
        return 0
    fi

    local purged=0 kept=0 held=0 entry
    shopt -s nullglob dotglob
    for entry in "$root"/*; do
        # Skip the gitkeep / stray .nfs locks themselves — let them age out.
        case "$(basename "$entry")" in
            .nfs*) continue ;;
        esac
        if [[ -n "$days" ]]; then
            # Keep entries modified more recently than <days> ago.
            if [[ -n "$(find "$entry" -maxdepth 0 -mtime +"$days" 2>/dev/null)" ]]; then
                : # old enough — fall through to purge
            else
                kept=$((kept+1)); continue
            fi
        fi
        rm -rf "$entry" 2>/dev/null || true
        if [[ -e "$entry" ]]; then
            held=$((held+1))
            printf '_trash: still held (open elsewhere), left for later: %s\n' "$entry" >&2
        else
            purged=$((purged+1))
        fi
    done
    shopt -u nullglob dotglob
    printf '_trash: cleared %d, kept %d (too new), %d still held in %s\n' \
        "$purged" "$kept" "$held" "$root"
    return 0
}

# list_trash [--root <dir>] — show current trash entries + sizes.
list_trash() {
    local root=""
    while (( $# > 0 )); do
        case "$1" in
            --root) root="$2"; shift 2 ;;
            --root=*) root="${1#--root=}"; shift ;;
            *) printf '_trash: list_trash: unknown arg: %s\n' "$1" >&2; return 2 ;;
        esac
    done
    root="${root:-$(_trash_default_root)}"
    [[ -d "$root" ]] || { printf '(no trash dir at %s)\n' "$root"; return 0; }
    du -sh "$root"/* 2>/dev/null || printf '(trash empty: %s)\n' "$root"
}

# ---- CLI dispatch (only when executed, not when sourced) -----------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -uo pipefail
    cmd="${1:-}"; shift || true
    case "$cmd" in
        trash)        trash_path "$@" ;;
        --clear|clear) clear_trash "$@" ;;
        --list|list)  list_trash "$@" ;;
        -h|--help|"")
            sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            ;;
        *) printf '_trash: unknown command: %s (try --help)\n' "$cmd" >&2; exit 2 ;;
    esac
fi
