#!/usr/bin/env bash
# monitor/link-nexus-tools.sh — provision stable `locals/bin` symlinks for
# the nexus toolchain so it is callable BY NAME (`claude`, `ng`, `nexus`,
# `watcher`) wherever `locals/bin` is on PATH.
#
# WHY (your-org/nexus-code#307 item 4). #307 made `locals/bin` the
# nexus-wide toolchain dir and put `uv`/`uvx` there. This extends it to the
# two tools an operator (or a manually-spawned tmux window — item 3) most
# wants by name:
#   - `claude` — the Claude Code install this nexus runs, as resolved by
#     `monitor/_claude-bin.sh` (CLAUDE_BIN env → config `nexus.claude_bin`
#     → `$NEXUS_ROOT/node_modules/.bin/claude` → PATH). We expose it via a
#     STABLE indirection `locals/bin/claude` so PATH-based resolution
#     lands on the binary the nexus actually spawns, never an unrelated
#     one that happens to sit earlier on someone's PATH.
#   - `ng` + the `nexus`/`watcher` entrypoints — the nexus CLI + boot
#     entry, so a manual window can drive the nexus by name.
#
# SURVIVES THE TRASH-ASIDE REINSTALL (#310/#312/#315). For an IN-TREE
# target the link is a RELATIVE symlink that lives in `locals/bin/` and
# points at the canonical in-tree path (`../../node_modules/.bin/claude`).
# `install-claude-local.sh` renames the OLD `node_modules/.bin/claude` into
# the trash and npm writes a FRESH one at the same path — so our
# `locals/bin/claude` link dangles only for the brief reinstall window and
# resolves again the instant the new binary lands. The link itself is never
# touched by the install. Relative (not absolute) so the whole nexus tree
# stays relocatable.
#
# An OUT-OF-TREE target (a native install pinned via config
# `nexus.claude_bin`) gets an ABSOLUTE symlink instead: a relative path is
# meaningless across the tree boundary, and that install does not relocate
# with the nexus anyway. The trash-aside reasoning does not apply — no npm
# install touches it.
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

# Resolve the claude target through the SHARED resolver rather than
# hard-coding the npm path, so this link follows whatever the nexus
# actually spawns. Soft: the resolver exits 1 when no binary exists
# anywhere, and that is a normal state on a host that has not installed
# one yet — fall back to the npm path so the "install absent, skipping
# link" branch below still names the right thing to run.
# CLAUDE_BIN_NO_PATH: this script WRITES locals/bin/claude, and locals/bin
# leads every agent's PATH — so consuming the resolver's PATH lookup would
# be circular and would point the link at itself.
_claude_abs=$(
    CLAUDE_BIN_NO_PATH=1
    # shellcheck disable=SC1091
    . "$NEXUS_ROOT/monitor/_claude-bin.sh" >/dev/null 2>&1 \
        && printf '%s' "$CLAUDE_BIN"
) || _claude_abs=""
[[ -n "$_claude_abs" ]] || _claude_abs="$NEXUS_ROOT/node_modules/.bin/claude"

# In-tree target → relative link (relocatable, survives the trash-aside
# reinstall). Out-of-tree target → absolute link.
if [[ "$_claude_abs" == "$NEXUS_ROOT/"* ]]; then
    _claude_rel="../../${_claude_abs#"$NEXUS_ROOT/"}"
else
    _claude_rel="$_claude_abs"
fi

# The toolchain links: <name> <target-from-locals/bin> <abs-target>
# <abs-target> is what we test for existence (claude is only linked once
# the install is present; the entrypoints + ng always exist).
#
# `locals/bin/<name>` -> `../../<path>` resolves to `$NEXUS_ROOT/<path>`
# because `locals/bin/..` is `locals/` and `../..` is `$NEXUS_ROOT`.
_link_specs=(
    "claude $_claude_rel $_claude_abs"
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
