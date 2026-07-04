#!/usr/bin/env bash
# monitor/install-claude-local.sh — install Claude Code into the nexus
# tree so spawn surfaces can prefer it over the system binary.
#
# Idempotent: re-running when the install is already at the locked
# version is a no-op + exit 0. Re-running with a bumped pin (operator
# edited package.json) re-syncs node_modules to the new version.
#
# THE INVARIANT: a pin bump must NEVER end with the tree lacking a
# working binary. Two consecutive auto-updates (2.1.158, 2.1.159) each
# left `./node_modules/.bin/claude` MISSING on the live NFS clone — once
# because `npm ci` wiped node_modules then failed to reinstall, once
# because `npm install` hit `EBUSY ... unlink .../.nfs000...` on an
# in-use binary and aborted. Everything below exists to make that
# outcome impossible: a failed install leaves the prior binary in place,
# and the script refuses to exit 0 unless the binary is present, runs,
# and reports the pinned version.
#
# Resolution / strategy:
#   1. $NEXUS_ROOT resolves from this script's location, so the helper
#      works from forks and fresh clones without any path hardcoding.
#   2. node + npm presence is required; their versions are surfaced in
#      the success line for triage.
#   3. Installer choice: PREFER `npm install` — it doesn't wipe
#      node_modules, so a mid-install failure leaves the previously
#      installed binary intact. `npm ci` is opt-in only (set
#      CLAUDE_INSTALL_USE_CI=1); it wipes node_modules first, which is
#      exactly the failure mode we are guarding against on NFS.
#   4. Before installing, best-effort remove leftover
#      node_modules/@anthropic-ai/.claude-code-* staging dirs from a
#      prior aborted install. On NFS an in-use file can leave a `.nfs*`
#      lock that refuses unlink (EBUSY) — those are ignored.
#   5. On a transient EBUSY / `.nfs*` install failure, pre-clean again
#      and retry the install exactly once before giving up.
#   6. Post-install verification is MANDATORY and fail-loud: assert
#      ./node_modules/.bin/claude is executable AND `--version` reports
#      the EFFECTIVE version (operator-local pin if present, else the
#      shared package.json FLOOR — see monitor/_cc-version.sh). On any
#      mismatch, exit non-zero with the exact recovery command — never
#      exit 0 on a missing/stale binary.
#
# Floor-plus-local-pin (your-org/nexus-code#226): the package.json pin is
# a maintainer-managed vetted FLOOR for INITIAL SETUP; a successful gated
# cc-update advances the operator-LOCAL pin
# (monitor/.state/cc-version-local, gitignored) WITHOUT touching shared
# package.json. This script installs whichever the resolver names as
# effective. When a local pin is present it installs that exact version
# with `npm install --no-save <pkg>@<ver>` so the shared floor stays put.
#
# Output discipline: one line on success (stdout), one paragraph on
# failure (stderr). Between those, npm's own output streams through
# (via `tee`) so the operator sees per-package fetch progress during a
# cold cache or slow-network install (issue #163) — without this, a
# multi-minute install is visually indistinguishable from a hang.
# `--loglevel=http` is passed to npm because the default `notice` level
# emits nothing until the final "added N packages" line in non-TTY mode.
# The same `tee` capture lets us classify a failure (EBUSY/.nfs) without
# a second run.
#
# The watcher's launcher.sh consumes this script's stderr into a flag
# file that the watcher then surfaces to the orchestrator on its first
# paste — see monitor/watcher/launcher.sh "Self-install Claude Code if
# absent" + the install-failure flag check in main.sh.

set -uo pipefail

_script_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
NEXUS_ROOT=$(cd "$_script_dir/.." && pwd)

# Shared effective-version resolver (floor-plus-local-pin scheme,
# your-org/nexus-code#226). Provides cc_version_effective /
# cc_version_read_local_pin / cc_version_floor. The EFFECTIVE version
# (operator-local pin if present, else the shared package.json FLOOR) is
# what we install and verify.
# shellcheck source=_cc-version.sh
. "$_script_dir/_cc-version.sh"

# Shared Node.js bootstrap (Lmod/Tcl-module HPC hosts where node lives
# behind `module load nodejs`). Provides nexus_ensure_node; also used by
# the cc-harness gate so the bootstrap logic lives in one place.
# shellcheck source=_node-bootstrap.sh
. "$_script_dir/_node-bootstrap.sh"

# Move-aside-before-install helper (your-org/nexus-code#310/#312). Provides
# trash_path: rename the existing target into a gitignored trash dir
# instead of unlinking it — a `rename(2)` succeeds on a held-open inode
# where npm's `unlink` would EBUSY/`.nfs`-lock and abort the swap. Sourced
# (not exec'd) so we call trash_path directly.
# shellcheck source=_trash.sh
. "$_script_dir/_trash.sh"

die() {
    printf 'install-claude-local: %s\n' "$*" >&2
    exit 1
}

# Expose the freshly-verified project-local claude (and the other nexus
# tools) under the stable nexus-wide `locals/bin` so PATH-based resolution —
# spawned workers AND manually-opened tmux windows (your-org/nexus-code#307
# items 3+4) — lands on it by name. Best-effort: a link failure must never
# fail an otherwise-successful install, so we only warn. Called right before
# every success exit (idempotent), so the link self-heals if it was deleted
# even on the idempotency fast-path.
ensure_locals_links() {
    [[ -x "$_script_dir/link-nexus-tools.sh" ]] || return 0
    NEXUS_ROOT="$NEXUS_ROOT" "$_script_dir/link-nexus-tools.sh" --quiet \
        || printf 'install-claude-local: warning: could not provision locals/bin links\n' >&2
}

# Ensure node is on PATH before the npm install. On Lmod/Tcl-module HPC
# hosts node lives behind `module load nodejs`, and the watcher launcher
# runs this script in a NON-LOGIN shell that never loaded the module —
# without the bootstrap the `command -v node` check below would fail,
# the script would fail-loud, and the spawn surfaces would degrade to a
# system `claude` (losing the package.json-pinned upgrade path).
# Diagnosed in your-org/other-nexus#41 (docs-only note: closed
# your-org/nexus-code#212). The bootstrap is shared with the cc-harness
# gate via monitor/_node-bootstrap.sh; it is strictly ADDITIVE (no-op
# when node is already on PATH) and never hard-fails a non-module host —
# the fail-loud check just below owns the hard error.
#
# Node is needed ONLY at install time — `npm install` is the sole node
# consumer. The installed binary (./node_modules/.bin/claude) is a
# self-contained native executable, so spawned `claude` processes do NOT
# need node on PATH at runtime; hence no matching hook is required in
# launcher.sh / _claude-bin.sh.
nexus_ensure_node || true

command -v node >/dev/null 2>&1 \
    || die "node not on PATH; install Node.js >=18 first (no environment module provided it either — if your site's node module isn't named 'nodejs', set NEXUS_NODE_MODULE or nexus.node_module in config/nexus.yml)"
command -v npm  >/dev/null 2>&1 \
    || die "npm not on PATH; install Node.js >=18 first"

node_version=$(node --version 2>/dev/null | sed 's/^v//')
node_major=${node_version%%.*}
if [[ -z "$node_major" ]] || (( node_major < 18 )); then
    die "node $node_version is too old; Claude Code requires Node.js >=18"
fi

cd "$NEXUS_ROOT" \
    || die "cannot cd to nexus root: $NEXUS_ROOT"

[[ -f package.json ]] \
    || die "no package.json at $NEXUS_ROOT; nothing to install"

# Writable npm cache + logs. npm defaults its cache (and, in npm 10/Node
# 20, its _logs) to $HOME/.npm — which is READ-ONLY on sandboxed/HPC hosts
# (e.g. agent-sandbox, or a cluster home mounted ro on compute nodes). The
# default then aborts the install with `EROFS: read-only file system` at
# the first cacache write, before a single package is fetched. Point npm at
# a writable cache under the (always-writable) nexus root — node_modules is
# written here too, so we know this tree is writable. Precedence respects an
# operator-set npm_config_cache / NPM_CONFIG_CACHE before falling back to the
# project-local default; overridable for sites that prefer a TMPDIR cache.
export npm_config_cache="${npm_config_cache:-${NPM_CONFIG_CACHE:-$NEXUS_ROOT/.npm-cache}}"
mkdir -p "$npm_config_cache" 2>/dev/null \
    || die "cannot create npm cache dir: $npm_config_cache (set npm_config_cache/NPM_CONFIG_CACHE to a writable path)"

# Resolve the EFFECTIVE Claude Code version once — used by the fast-path,
# the install command, and the mandatory final verification.
#
#   effective = operator-local pin (monitor/.state/cc-version-local, if
#               present) ELSE the shared package.json FLOOR.
#
# The FLOOR is maintainer-managed (initial-setup-only, advanced
# deliberately). The LOCAL pin is written by the gated cc-update routine
# (skills/nexus.cc-update/GUIDE.md) and lets a per-operator validated
# version advance without ever touching shared package.json. See
# monitor/_cc-version.sh for the full model.
cc_package="@anthropic-ai/claude-code"
floor_version=$(cc_version_floor package.json "$cc_package" 2>/dev/null || true)
effective_version=$(cc_version_effective package.json "$cc_package" "$NEXUS_ROOT" 2>/dev/null || true)
pin_source=$(cc_version_effective_source package.json "$cc_package" "$NEXUS_ROOT" 2>/dev/null || echo unknown)

# Idempotency fast-path: if node_modules/.bin/claude is already
# executable AND matches the EFFECTIVE version, the install is complete —
# exit 0 without touching node_modules. Keeps repeated launcher
# invocations cheap and, crucially, never disturbs a working binary.
if [[ -x ./node_modules/.bin/claude ]] && [[ -n "$effective_version" ]]; then
    installed_version=$(./node_modules/.bin/claude --version 2>/dev/null \
        | awk '{print $1}')
    if [[ "$installed_version" == "$effective_version" ]]; then
        ensure_locals_links
        printf 'install-claude-local: already at %s (source=%s, node %s, npm %s)\n' \
            "$installed_version" "$pin_source" "$node_version" "$(npm --version)"
        exit 0
    fi
fi

# Pick the installer. PREFER `npm install`: it reconciles node_modules
# in place, so a failure leaves the prior binary standing. `npm ci`
# wipes node_modules before reinstalling (no-binary risk on a failed
# NFS reinstall) — opt-in only.
#
# Two cases:
#   - LOCAL PIN present (effective came from the operator-local pin):
#     install that EXACT version explicitly with `--no-save`, so
#     node_modules advances to the validated local version WITHOUT
#     rewriting the shared package.json floor. `npm ci` cannot honour an
#     out-of-lock version, so it is bypassed here (with a note).
#   - NO local pin (effective == the floor): keep the original behaviour
#     bit-for-bit — bare `npm install` (or opt-in `npm ci`) installs the
#     floor from package.json. This is the deterministic, vetted
#     fresh-install path.
if [[ "$pin_source" == "local-pin" && -n "$effective_version" ]]; then
    if [[ "${CLAUDE_INSTALL_USE_CI:-0}" == "1" ]]; then
        printf 'install-claude-local: local pin %s present — bypassing `npm ci` (cannot install out-of-lock version); using `npm install --no-save %s@%s`\n' \
            "$effective_version" "$cc_package" "$effective_version" >&2
    fi
    install_cmd=(npm install --no-save "$cc_package@$effective_version")
elif [[ "${CLAUDE_INSTALL_USE_CI:-0}" == "1" && -f package-lock.json ]]; then
    install_cmd=(npm ci)
else
    install_cmd=(npm install)
fi

# Best-effort sweep of leftover npm staging dirs from a prior aborted
# install (node_modules/@anthropic-ai/.claude-code-<hash>). On NFS an
# in-use file inside one can leave a `.nfs*` lock that refuses unlink
# (EBUSY); we ignore those — `npm install` reconciles around them.
preclean_staging() {
    local d
    shopt -s nullglob
    for d in ./node_modules/@anthropic-ai/.claude-code-*; do
        rm -rf "$d" 2>/dev/null || true
    done
    shopt -u nullglob
}

# Move-aside-before-install (your-org/nexus-code#310/#312). Rather than let
# npm `unlink` the in-use binary/package dir — which EBUSY/`.nfs`-fails on a
# held-open inode over NFS and aborts the swap — RENAME them into the
# gitignored trash dir first, so npm installs into a clean path. `rename(2)`
# succeeds even while running agents hold the old binary open; their inode
# lives on under its trash name and is reaped later by `_trash.sh --clear`.
# Reached only past the idempotency fast-path, i.e. only on a genuine
# (re)install — a no-version-change launcher run never trashes anything.
trashed_pkg=""
trashed_bin=""
trash_aside_old_install() {
    # Order: bin (a symlink into the pkg) then the pkg dir itself.
    trashed_bin=$(trash_path ./node_modules/.bin/claude) || trashed_bin=""
    trashed_pkg=$(trash_path ./node_modules/@anthropic-ai/claude-code) || trashed_pkg=""
    if [[ -n "$trashed_pkg" || -n "$trashed_bin" ]]; then
        printf 'install-claude-local: moved prior install aside to trash (recoverable; clear with monitor/_trash.sh --clear)\n' >&2
    fi
}

# Failure-path safety net upholding THE INVARIANT (a failed install must
# never leave the tree without a working binary): if we trashed the prior
# install and the reinstall then failed, move the prior copies back.
#
# Two correctness traps a naive `-e`-guarded restore falls into (caught by
# the #310/#312 skeptic pass — req-001):
#   1. npm's `.bin/claude` is a RELATIVE symlink
#      (`../@anthropic-ai/claude-code/bin/claude.exe`). Moved into the trash
#      dir it DANGLES (its `../` now points elsewhere), so `-e` is false and
#      a `-e`-only guard silently skips the restore → binary-less tree. We
#      therefore test `-e || -L` so a dangling symlink still restores. Moved
#      BACK to node_modules/.bin (after the pkg is in place, below) the same
#      relative target resolves correctly again — no re-link needed.
#   2. A reinstall that fails MID-EXTRACT can leave a PARTIAL target at the
#      destination; an `! -e dest` guard would then refuse to restore over
#      it. We trash any such partial aside first, then move the known-good
#      prior copy back.
# Order: pkg first, then the bin symlink that resolves into it.
restore_one() {  # $1 = trashed src, $2 = destination path; rc 0 iff moved back
    local src="$1" dest="$2"
    [[ -n "$src" && ( -e "$src" || -L "$src" ) ]] || return 1
    # Aside any partial/failed target occupying the destination.
    if [[ -e "$dest" || -L "$dest" ]]; then
        trash_path "$dest" >/dev/null 2>&1 || return 1
    fi
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    mv "$src" "$dest" 2>/dev/null
}
restore_trashed_install() {
    restore_one "$trashed_pkg" ./node_modules/@anthropic-ai/claude-code \
        && printf 'install-claude-local: restored prior package dir from trash after failed install\n' >&2
    restore_one "$trashed_bin" ./node_modules/.bin/claude \
        && printf 'install-claude-local: restored prior binary from trash after failed install\n' >&2
    return 0
}

# Run the installer once, streaming npm's combined output live to the
# terminal (operator visibility) while capturing it to $install_capture
# for failure classification. `tee` is a full pipeline member, so the
# capture file is complete by the time the pipeline returns — no race.
# PIPESTATUS[0] carries npm's real exit code past the pipe.
install_capture=$(mktemp /tmp/install-claude-local.XXXXXX) || install_capture=""
attempt_install() {
    [[ -n "$install_capture" ]] && : > "$install_capture"
    if [[ -n "$install_capture" ]]; then
        "${install_cmd[@]}" --loglevel=http 2>&1 | tee "$install_capture"
        return "${PIPESTATUS[0]}"
    fi
    "${install_cmd[@]}" --loglevel=http
}

install_started_at=$(date +%s)
printf 'install-claude-local: running %s (per-package fetch lines follow)\n' \
    "${install_cmd[*]}" >&2

preclean_staging

# Always move the prior install aside before swapping it in (the #310
# standing pattern), so the install lands in a clean path and a held-open
# old binary can never block the unlink. On a fresh tree this is a no-op.
trash_aside_old_install

if ! attempt_install; then
    # A transient NFS EBUSY / `.nfs*` lock often clears on a second pass
    # once the holding process releases the file. Pre-clean and retry
    # exactly once; any other failure is fatal immediately. (Having already
    # trashed the prior install aside, a binary-swap EBUSY should not recur;
    # the retry still covers staging-dir `.nfs` remnants.)
    if [[ -n "$install_capture" ]] \
        && grep -qiE 'EBUSY|resource busy|\.nfs[0-9a-fA-F]+' "$install_capture"; then
        printf 'install-claude-local: transient EBUSY/.nfs failure; pre-cleaning and retrying once\n' >&2
        preclean_staging
        if ! attempt_install; then
            rm -f "$install_capture"
            restore_trashed_install
            die "${install_cmd[*]} failed twice (EBUSY/.nfs); a process may be holding the old binary. Rerun manually: cd $NEXUS_ROOT && ${install_cmd[*]}"
        fi
    else
        rm -f "$install_capture"
        restore_trashed_install
        die "${install_cmd[*]} failed; rerun manually: cd $NEXUS_ROOT && ${install_cmd[*]}"
    fi
fi

rm -f "$install_capture"
install_elapsed=$(( $(date +%s) - install_started_at ))

# Mandatory fail-loud verification. The whole point of this script is
# that it must not report success unless the binary actually works.
recovery="cd $NEXUS_ROOT && ${install_cmd[*]}"

if [[ ! -x ./node_modules/.bin/claude ]]; then
    # Binary absent after a "successful" install — restore the prior copy we
    # trashed aside so the tree is never left binary-less (THE INVARIANT).
    restore_trashed_install
    die "${install_cmd[*]} reported success but ./node_modules/.bin/claude is missing or not executable. Recover: $recovery"
fi

if ! installed_raw=$(./node_modules/.bin/claude --version 2>&1); then
    die "./node_modules/.bin/claude --version failed: $installed_raw. Recover: $recovery"
fi

installed_version=$(awk '{print $1}' <<<"$installed_raw")
if [[ -n "$effective_version" && "$installed_version" != "$effective_version" ]]; then
    die "version mismatch after install: binary reports '$installed_version' but the effective pin (source=$pin_source) is '$effective_version'. Recover: $recovery"
fi

ensure_locals_links

printf 'install-claude-local: %s (source=%s, floor=%s, node %s, npm %s, installer=%s, elapsed=%ds)\n' \
    "$installed_raw" "$pin_source" "${floor_version:-?}" "$node_version" "$(npm --version)" "${install_cmd[*]}" "$install_elapsed"
