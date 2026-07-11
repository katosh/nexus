#!/usr/bin/env bash
# monitor/link-nexus-tools.sh — provision stable `locals/bin` symlinks for
# the nexus toolchain so it is callable BY NAME (`claude`, `ng`, `nexus`,
# `watcher`) wherever `locals/bin` is on PATH.
#
# WHY (your-org/nexus-code#307 item 4). #307 made `locals/bin` the
# nexus-wide toolchain dir and put `uv`/`uvx` there. This extends it to the
# two tools an operator (or a manually-spawned tmux window — item 3) most
# wants by name:
#   - `claude` — the PROJECT-LOCAL Claude Code install. The real binary
#     lives at `$NEXUS_ROOT/node_modules/.bin/claude` (npm-managed, version
#     -bumped). We expose it via a STABLE indirection `locals/bin/claude`
#     so PATH-based resolution lands on the pinned local binary, never a
#     system/`$HOME` one.
#   - `ng` + the `nexus`/`watcher` entrypoints — the nexus CLI + boot
#     entry, so a manual window can drive the nexus by name.
#
# SURVIVES THE TRASH-ASIDE REINSTALL (#310/#312/#315). The link is a
# RELATIVE symlink that lives in `locals/bin/` and points at the canonical
# in-tree path (`../../node_modules/.bin/claude`). `install-claude-local.sh`
# renames the OLD `node_modules/.bin/claude` into the trash and npm writes a
# FRESH one at the same path — so our `locals/bin/claude` link dangles only
# for the brief reinstall window and resolves again the instant the new
# binary lands. The link itself is never touched by the install. Relative
# (not absolute) so the whole nexus tree stays relocatable.
#
# Idempotent: re-running only ever rewrites the symlinks to their canonical
# targets (`ln -sfn`); safe to call on every launcher/bootstrap start. Pure
# w.r.t. $HOME and Lmod — creates nothing outside `locals/bin`.
#
# Usage:
#   monitor/link-nexus-tools.sh            # provision all links (verbose)
#   monitor/link-nexus-tools.sh --quiet    # same, only warnings to stderr
#   monitor/link-nexus-tools.sh --check    # report status, make no changes
#
# Env: NEXUS_ROOT (default: this script's monitor/..), NEXUS_LOCALS
#      (default: <root>/locals) — honoured so tests can point elsewhere.

set -uo pipefail

_self_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$_self_dir/.." && pwd)}"
NEXUS_LOCALS="${NEXUS_LOCALS:-$NEXUS_ROOT/locals}"

_quiet=0
_check=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet) _quiet=1; shift ;;
        --check) _check=1; shift ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'link-nexus-tools: unknown arg: %s\n' "$1" >&2; exit 2 ;;
    esac
done

_bindir="$NEXUS_LOCALS/bin"

note() { (( _quiet )) || printf 'link-nexus-tools: %s\n' "$*"; }
warn() { printf 'link-nexus-tools: %s\n' "$*" >&2; }

# The toolchain links: <name> <relative-target-from-locals/bin> <abs-target>
# <abs-target> is what we test for existence (claude is only linked once the
# project-local install is present; the entrypoints + ng always exist).
#
# `locals/bin/<name>` -> `../../<path>` resolves to `$NEXUS_ROOT/<path>`
# because `locals/bin/..` is `locals/` and `../..` is `$NEXUS_ROOT`.
_link_specs=(
    "claude ../../node_modules/.bin/claude $NEXUS_ROOT/node_modules/.bin/claude"
    "ng     ../../monitor/ng               $NEXUS_ROOT/monitor/ng"
    "nexus  ../../monitor/watcher/entry.sh $NEXUS_ROOT/monitor/watcher/entry.sh"
    "watcher ../../monitor/watcher/entry.sh $NEXUS_ROOT/monitor/watcher/entry.sh"
)

# --check: report without mutating.
if (( _check )); then
    rc=0
    for spec in "${_link_specs[@]}"; do
        read -r name rel abs <<<"$spec"
        link="$_bindir/$name"
        if [[ -L "$link" ]]; then
            cur=$(readlink "$link")
            if [[ "$cur" == "$rel" ]] && [[ -e "$link" ]]; then
                printf 'OK      %s -> %s\n' "$name" "$cur"
            elif [[ "$cur" == "$rel" ]]; then
                printf 'DANGLE  %s -> %s (target absent: %s)\n' "$name" "$cur" "$abs"; rc=1
            else
                printf 'STALE   %s -> %s (want %s)\n' "$name" "$cur" "$rel"; rc=1
            fi
        else
            printf 'MISSING %s (want -> %s)\n' "$name" "$rel"; rc=1
        fi
    done
    exit "$rc"
fi

mkdir -p "$_bindir" 2>/dev/null || { warn "cannot create $_bindir"; exit 1; }

linked=0
skipped=0
failed=0
for spec in "${_link_specs[@]}"; do
    read -r name rel abs <<<"$spec"
    link="$_bindir/$name"
    # claude: only link when the install actually exists, so we never leave
    # a permanently-dangling link on a host that hasn't installed it yet.
    # The entrypoints + ng are in-repo, so always present.
    if [[ ! -e "$abs" ]]; then
        if [[ "$name" == "claude" ]]; then
            note "claude install absent ($abs) — skipping link (run install-claude-local.sh)"
        else
            warn "expected nexus file missing: $abs — skipping $name link"
        fi
        skipped=$((skipped+1))
        continue
    fi
    # ln -sfn: force-replace, no-deref (don't descend into an existing
    # symlink). Idempotent — a correct link is simply rewritten in place.
    if ln -sfn "$rel" "$link" 2>/dev/null; then
        linked=$((linked+1))
    else
        warn "failed to link $link -> $rel"
        failed=$((failed+1))
    fi
done

if (( skipped > 0 )); then
    note "linked $linked tool(s) into $_bindir (skipped $skipped)"
else
    note "linked $linked tool(s) into $_bindir"
fi

# A failed `ln` means the toolchain this script promises is NOT on PATH by
# name. Returning 0 there tells every caller "provisioned" when nothing was —
# the same defect class as the read-only-mount outage of 2026-07-09, where four
# `failed to link` warnings scrolled past inside a --quiet call and the exit
# status said success. Fail LOUD: the caller decides whether to abort, but it
# must be able to see that the promise was not kept.
if (( failed > 0 )); then
    warn "$failed link(s) FAILED — nexus tools are not on PATH by name"
    exit 1
fi
exit 0
