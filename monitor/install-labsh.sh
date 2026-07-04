#!/usr/bin/env bash
# monitor/install-labsh.sh — clone operator/labsh into the operator's
# sandbox project tree under work/labsh/.
#
# Sandbox-correct path:
#   target = $SANDBOX_PROJECT_DIR/work/labsh
# That's the writable area kernel-enforced by agent-sandbox, and the
# same convention every nexus worker's per-project clone lives under.
#
# Reliability contract (see monitor/_install-lib.sh):
#   * Idempotent  — a healthy clone re-runs as a no-op exit 0.
#   * Atomic      — clone-to-temp + rename; an interrupted clone never leaves
#                   a half-populated target a later run mistakes for installed.
#   * Recoverable — leftover temp clones are cleared; a partial/corrupt/
#                   wrong-remote target is moved ASIDE (never destroyed) to
#                   <target>.broken.<ts> and re-cloned.
#   * Concurrency-safe — advisory flock on a local fs.
#   * Verified    — a final health gate asserts the clone is present + correct;
#                   FAILS LOUD otherwise (also exposed as `--check`).
#
# Fail-loud: refuses to run if SANDBOX_PROJECT_DIR is unset (no defaulting to
# $HOME — labsh outside the sandbox would surprise the operator), and surfaces
# git clone errors verbatim.
#
# Caveat: operator/labsh#3 documents a sandbox-interaction issue with
# `labsh-attach`. The bootstrap surfaces this on success so the operator knows
# to read the upstream issue before relying on the attach flow.
#
# Flags: --check (verify only, no mutation, no lock; nonzero if incomplete)
#        -h|--help

set -uo pipefail

_self_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=monitor/_install-lib.sh
. "$_self_dir/_install-lib.sh"

die()  { printf 'install-labsh: %s\n' "$*" >&2; exit 1; }
warn() { printf 'install-labsh: WARNING: %s\n' "$*" >&2; }
stamp(){ date +%Y%m%d-%H%M%S 2>/dev/null || echo ts; }

REMOTE_URL="${LABSH_REMOTE:-https://github.com/operator/labsh.git}"
REMOTE_ID="operator/labsh"

CHECK_ONLY=0
while (( $# > 0 )); do
    case "$1" in
        --check)   CHECK_ONLY=1; shift ;;
        -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; s/^#$//'; exit 0 ;;
        *) die "unknown flag: $1 (try --help)" ;;
    esac
done

[[ -n "${SANDBOX_PROJECT_DIR:-}" ]] \
    || die "SANDBOX_PROJECT_DIR not set; refusing to install outside the sandbox"

target="$SANDBOX_PROJECT_DIR/work/labsh"

repo_healthy() { install_remote_matches "$target" "$REMOTE_ID"; }

verify() {
    if repo_healthy; then echo "  verify: labsh clone OK ($target)"; return 0; fi
    echo "  verify: labsh clone MISSING/BROKEN ($target)" >&2; return 1
}

if (( CHECK_ONLY )); then
    verify || die "verification FAILED — run without --check to repair."
    echo "labsh: verified."
    exit 0
fi

# ---- concurrency guard ----------------------------------------------------
install_acquire_lock labsh || die "could not acquire install lock"

if repo_healthy; then
    echo "labsh: already cloned at $target"
    echo "labsh: review operator/labsh#3 before running 'labsh-attach'."
    exit 0
fi

# ---- repo: recover + ensure (atomic) -------------------------------------
install_clean_temps "$target"

if [[ -e "$target" ]]; then
    if install_dir_is_repo "$target" && ! install_remote_matches "$target" "$REMOTE_ID"; then
        die "refusing to overwrite $target — git repo with unexpected remote ($(git -C "$target" config --get remote.origin.url 2>/dev/null || echo none)). Move it aside and re-run."
    fi
    bak="${target}.broken.$(stamp)"
    warn "partial/incomplete clone at $target — moving aside to $bak"
    mv "$target" "$bak" || die "could not move aside $target"
fi

if ! install_atomic_clone "$REMOTE_URL" "$target"; then
    die "git clone failed; re-run manually or check network/auth"
fi

verify || die "install finished but verification FAILED — see above."
echo "labsh: cloned at $target"
echo "labsh: review operator/labsh#3 before running 'labsh-attach'."
