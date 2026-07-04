#!/usr/bin/env bash
# write-probe.sh — verify a deliverable target is writable BEFORE
# committing compute to it.
#
# The agent-sandbox mounts only the project root + `~/.claude`
# writable; shared lab dirs, `/hpc/temp`, and scratch are read-only
# inside the bwrap re-wrap — and Slurm jobs inherit the same
# re-wrap, so even an `sbatch`-submitted job sees the target dir
# read-only. A worker that stages a multi-hour result to such a
# target discovers the EROFS only at the final write, wasting the
# compute. Worse, some libraries SIGSEGV on a read-only mount
# instead of raising EROFS (observed: `pyBigWig.open(path,"w")` on a
# RO-mounted symlink target), so the failure isn't even a clean
# error you can catch.
#
# Run this at DISPATCH (before compute) on every deliverable target
# that lives OUTSIDE the working tree. It probes the path — or its
# nearest existing ancestor, for a not-yet-created target — with a
# create+remove of a temp file. On failure it prints a remedy and
# exits non-zero, so the worker fails fast before burning cluster
# time. Symlinks are resolved to their real target first, so a
# RO-mounted symlink destination is caught here rather than by a
# downstream library segfault.
#
# The remedy is environment-aware. INSIDE agent-sandbox (canonical
# signal: SANDBOX_ACTIVE=1 plus a set SANDBOX_PROJECT_DIR — the same
# markers monitor/bootstrap-install.sh and monitor/watcher/entry.sh
# gate on) a read-only target almost always means the path simply
# isn't in the operator's writable grant, so we print the
# `EXTRA_WRITABLE_PATHS` recipe for ~/.config/agent-sandbox/sandbox.conf.
# OUTSIDE the sandbox there is no such grant mechanism — the recipe
# would be wrong and confusing — so we degrade to a generic "this path
# is not writable" filesystem-permission message and never mention
# EXTRA_WRITABLE_PATHS / sandbox.conf. A writable target passes
# silently in BOTH modes, so a normal non-sandbox run sees zero new
# friction.
#
# This helper NEVER circumvents the sandbox — it only reports
# writability and points at the sanctioned operator-side grant flow
# (`~/.config/agent-sandbox/sandbox.conf`, edited outside the
# sandbox). The grant itself is the operator's action.
#
# Usage:
#   write-probe.sh <target> [<target> ...]   probe each target
#   write-probe.sh --quiet <target> ...      suppress the OK lines
#                                            (failures still print)
#
# Exit codes:
#   0  every target is writable
#   2  bad usage (no targets)
#   3  at least one target is NOT writable (in-sandbox: grant recipe
#      printed; out-of-sandbox: generic not-writable message)

set -u

# Detect whether we're running inside agent-sandbox. The canonical
# signal is SANDBOX_ACTIVE=1 together with a set SANDBOX_PROJECT_DIR —
# the same markers monitor/bootstrap-install.sh and
# monitor/watcher/entry.sh gate on. Outside the sandbox there is no
# EXTRA_WRITABLE_PATHS / sandbox.conf grant mechanism, so a
# not-writable target is a plain filesystem error, not a missing grant.
in_sandbox() {
    [ "${SANDBOX_ACTIVE:-}" = "1" ] && [ -n "${SANDBOX_PROJECT_DIR:-}" ]
}

usage() {
    cat >&2 <<'EOF'
usage: write-probe.sh [--quiet] <target> [<target> ...]

  Probe each deliverable target for writability BEFORE committing
  compute to it. A not-yet-created target is probed at its nearest
  existing ancestor. On a read-only target, prints the
  EXTRA_WRITABLE_PATHS operator-grant recipe and exits 3.

  See `skills/nexus.worker-defaults/SKILL.md` "Worker floor" and
  `skills/nexus.tmux-spawn/SKILL.md` "Sandbox deliverable-write
  targets" for the contract.
EOF
    exit 2
}

quiet=0
targets=()
while (( $# > 0 )); do
    case "$1" in
        --quiet|-q) quiet=1; shift ;;
        --help|-h)  usage ;;
        --)         shift; targets+=("$@"); break ;;
        -*)         printf 'write-probe.sh: unknown flag %q\n' "$1" >&2; usage ;;
        *)          targets+=("$1"); shift ;;
    esac
done

(( ${#targets[@]} >= 1 )) || usage

# Canonicalize a path without requiring it to exist, resolving every
# symlink in the existing prefix (so a RO-mounted symlink target is
# probed at its real destination). `readlink -m` is GNU coreutils;
# fall back to the raw path if it's unavailable.
canonicalize() {
    local p="$1" c
    if c=$(readlink -m -- "$p" 2>/dev/null) && [[ -n "$c" ]]; then
        printf '%s' "$c"
    else
        printf '%s' "$p"
    fi
}

# Walk up to the nearest existing ancestor directory of a path. The
# input is already canonicalized, so "/" terminates the walk.
nearest_existing_dir() {
    local p="$1"
    while [[ -n "$p" && "$p" != "/" && ! -e "$p" ]]; do
        p="${p%/*}"
        [[ -z "$p" ]] && p="/"
    done
    # If the existing node is a file, the writable unit is its
    # parent directory (we'd replace the file under it).
    if [[ -e "$p" && ! -d "$p" ]]; then
        p="${p%/*}"
        [[ -z "$p" ]] && p="/"
    fi
    printf '%s' "$p"
}

# Attempt an actual write in <dir> via shell redirection (which
# returns a clean EROFS on a RO mount — no buggy-library segfault).
dir_is_writable() {
    local dir="$1"
    local t="$dir/.nexus-write-probe.$$.$RANDOM"
    if ( : > "$t" ) 2>/dev/null; then
        rm -f "$t" 2>/dev/null
        return 0
    fi
    return 1
}

fail=0
for target in "${targets[@]}"; do
    canon=$(canonicalize "$target")
    probe_dir=$(nearest_existing_dir "$canon")

    if [[ -z "$probe_dir" ]]; then
        probe_dir="/"
    fi

    if dir_is_writable "$probe_dir"; then
        (( quiet )) || printf 'write-probe: OK         %s\n' "$target"
    else
        fail=1
        if in_sandbox; then
            cat >&2 <<EOF
write-probe: NOT WRITABLE — $target
  The agent-sandbox mounts only the project root + ~/.claude writable.
  This target is read-only inside the sandbox (probed: $probe_dir).
  To grant write access, the OPERATOR adds it to EXTRA_WRITABLE_PATHS in
  ~/.config/agent-sandbox/sandbox.conf (edited OUTSIDE the sandbox; takes
  effect on next sandbox start):

      EXTRA_WRITABLE_PATHS=(
          "$probe_dir"
      )

  Ask the operator for the grant (sandbox-notify) BEFORE committing
  compute — or stage to the working tree / scratch and hand the
  operator a copy-out path. Do NOT run the heavy job against a
  read-only target: it will fail at the final write, or worse,
  segfault mid-write on some libraries.
EOF
        else
            cat >&2 <<EOF
write-probe: NOT WRITABLE — $target
  This path is not writable (probed: $probe_dir). The nexus is running
  OUTSIDE agent-sandbox, so this is a genuine filesystem permission or
  mount problem, not a missing sandbox grant. Fix the directory's
  ownership/permissions, mount it read-write, or choose a writable
  deliverable target (e.g. stage under the working tree / scratch). Do
  NOT run the heavy job against a read-only target: it will fail at the
  final write, or worse, segfault mid-write on some libraries.
EOF
        fi
    fi
done

(( fail == 0 )) || exit 3
exit 0
