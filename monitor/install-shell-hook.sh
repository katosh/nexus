#!/usr/bin/env bash
# monitor/install-shell-hook.sh — install an idempotent, PATH-only drop-in
# into the operator's shell rc files so a MANUALLY-spawned tmux window (or
# any new login/SSH shell) resolves the nexus toolchain by name —
# `claude` lands on the project-local install, not a system/$HOME one.
#
# WHY (your-org/nexus-code#307 item 3). The spawn-worker launcher puts
# `locals/bin` on PATH for the workers IT spawns. But a user who runs
# `tmux new-window` by hand and types `claude` gets a plain shell with NO
# `locals/bin` on PATH → the wrong (or no) claude. This hook closes that
# gap at the only layer that is reliably re-evaluated for EVERY new
# interactive shell: the user's rc.
#
# WHY THE RC HOOK, NOT `tmux set-environment -g PATH` (the operator floated
# the latter). Pushing PATH through the tmux server's global environment is
# fragile on three counts, so we DON'T rely on it:
#   1. A login shell's profile (/etc/profile, ~/.profile) routinely REBUILDS
#      PATH from scratch, dropping whatever tmux injected.
#   2. It bakes a SNAPSHOT of the watcher's PATH (possibly module-loaded /
#      venv-activated) into the server global env, leaking that into every
#      manual pane.
#   3. It is lost on a tmux server restart and only affects panes created
#      AFTER it is set.
# The rc hook runs AFTER the profile PATH reset, carries no snapshot (it
# re-derives `locals/bin` from the nexus root every time), survives server
# restarts, and also covers shells started OUTSIDE tmux. It is the robust
# floor; that is why it is the chosen mechanism.
#
# PATH-ONLY. The drop-in sources monitor/locals-env.sh with
# NEXUS_LOCALS_PATH_ONLY=1 — it prepends `locals/bin` but does NOT redirect
# the user's uv state into the nexus tree (that belongs to nexus-scoped
# workers, not the operator's global shell). See locals-env.sh.
#
# Idempotent + reversible: the block lives between unique markers; a re-run
# REPLACES it (so a moved nexus root self-heals), `--uninstall` removes it.
# POSIX-sh body so it is safe under both bash and zsh rc files.
#
# Usage:
#   monitor/install-shell-hook.sh                 # install into ~/.bashrc + ~/.zshrc
#   monitor/install-shell-hook.sh --target FILE   # a specific rc file (repeatable)
#   monitor/install-shell-hook.sh --uninstall     # remove the block
#   monitor/install-shell-hook.sh --print         # print the block, change nothing
#   monitor/install-shell-hook.sh --quiet
#
# Read-only $HOME (e.g. a sandboxed/compute shell): NEVER fails the caller —
# prints the block + a one-line manual instruction and exits 0, so wiring it
# into the bootstrap can't break a fresh install.
#
# Env: NEXUS_ROOT (default: this script's monitor/..), HOME.

set -uo pipefail

_self_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$_self_dir/.." && pwd)}"

_BEGIN='# >>> nexus locals/bin (managed by monitor/install-shell-hook.sh) >>>'
_END='# <<< nexus locals/bin <<<'

_quiet=0
_mode=install
_targets=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall) _mode=uninstall; shift ;;
        --print)     _mode=print; shift ;;
        --target)    _targets+=("$2"); shift 2 ;;
        --quiet)     _quiet=1; shift ;;
        -h|--help)   sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'install-shell-hook: unknown arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# Default targets: the two interactive rc files. We touch rc (per-shell,
# re-sourced every new interactive shell), NOT profile (login-only) — a
# manual `tmux new-window` starts an interactive non-login shell, which
# reads .bashrc / .zshrc.
if [[ ${#_targets[@]} -eq 0 ]]; then
    _targets=("$HOME/.bashrc" "$HOME/.zshrc")
fi

note() { (( _quiet )) || printf 'install-shell-hook: %s\n' "$*"; }
warn() { printf 'install-shell-hook: %s\n' "$*" >&2; }

# The drop-in block. POSIX-sh so it is valid in bash AND zsh. Re-derives
# locals/bin from the (absolute, baked) nexus root each shell start.
gen_block() {
    cat <<BLOCK
$_BEGIN
# Adds the nexus project-local toolchain (claude, ng, uv, …) to PATH so a
# manually-opened shell or tmux window resolves them BY NAME. PATH-only: it
# does NOT redirect your uv state into the nexus tree. Idempotent. Opt out:
# delete this block, or run
#   $NEXUS_ROOT/monitor/install-shell-hook.sh --uninstall
if [ -f "$NEXUS_ROOT/monitor/locals-env.sh" ]; then
    NEXUS_LOCALS_PATH_ONLY=1 . "$NEXUS_ROOT/monitor/locals-env.sh"
fi
$_END
BLOCK
}

if [[ "$_mode" == print ]]; then
    gen_block
    exit 0
fi

# Strip any existing block (between markers, inclusive) from $1 -> stdout.
strip_block() {
    awk -v s="$_BEGIN" -v e="$_END" '
        $0==s {skip=1; next}
        skip && $0==e {skip=0; next}
        skip {next}
        {print}
    ' "$1"
}

# Write $2 as the new full contents of rc file $1, preserving the inode +
# perms when the file already exists (cat-redirect, not mv). Returns 1 if
# the file/dir is not writable.
write_rc() {
    local rc="$1" content="$2" dir
    dir=$(dirname "$rc")
    if [[ -e "$rc" ]]; then
        [[ -w "$rc" ]] || return 1
        printf '%s' "$content" > "$rc" || return 1
    else
        [[ -d "$dir" && -w "$dir" ]] || return 1
        printf '%s' "$content" > "$rc" || return 1
    fi
    return 0
}

block=$(gen_block)
ro_targets=()
changed=0

for rc in "${_targets[@]}"; do
    # Current contents minus any prior block.
    if [[ -e "$rc" ]]; then
        stripped=$(strip_block "$rc")
    else
        stripped=""
    fi

    if [[ "$_mode" == uninstall ]]; then
        if [[ ! -e "$rc" ]]; then
            note "no $rc — nothing to uninstall"
            continue
        fi
        # Already absent?
        if ! grep -qF "$_BEGIN" "$rc" 2>/dev/null; then
            note "no nexus block in $rc — nothing to uninstall"
            continue
        fi
        # Trim a trailing blank that we may have introduced.
        new="${stripped%$'\n'}"
        if write_rc "$rc" "${new}${new:+$'\n'}"; then
            note "removed nexus block from $rc"; changed=1
        else
            warn "cannot write $rc (read-only) — remove the block manually"
        fi
        continue
    fi

    # install: rebuild = stripped contents + a separating blank + the block.
    base="${stripped%$'\n'}"
    if [[ -n "$base" ]]; then
        new="${base}"$'\n\n'"${block}"$'\n'
    else
        new="${block}"$'\n'
    fi
    if write_rc "$rc" "$new"; then
        note "installed nexus PATH hook into $rc"; changed=1
    else
        ro_targets+=("$rc")
    fi
done

# Read-only HOME / rc: surface the manual path, never fail the caller.
if [[ ${#ro_targets[@]} -gt 0 ]]; then
    warn "could not write: ${ro_targets[*]} (read-only). Add this block by hand to enable \`claude\`-by-name in manual windows:"
    gen_block >&2
fi

if [[ "$_mode" == install && $changed -eq 0 && ${#ro_targets[@]} -eq 0 ]]; then
    note "no rc files written"
fi

# Reminder: an already-open shell won't pick the block up until re-sourced.
if [[ "$_mode" == install && $changed -eq 1 ]]; then
    note "open a new shell (or \`source\` your rc) to use the nexus toolchain by name"
fi

exit 0
