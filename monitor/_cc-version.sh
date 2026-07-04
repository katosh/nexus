#!/usr/bin/env bash
# monitor/_cc-version.sh — shared resolver for the EFFECTIVE Claude Code
# version under the floor-plus-local-pin scheme (your-org/nexus-code#226).
#
# Two-tier version model:
#
#   - The shared `package.json` pin is a maintainer-managed, VETTED
#     FLOOR. It is used for INITIAL SETUP ONLY — a fresh install / fresh
#     clone with no local pin yet lands on this exact, gated version. The
#     maintainer advances the floor DELIBERATELY (something that has run
#     stably on their end for ≥1 day, bundled with other updates), so the
#     floor lags the bleeding edge by design and does NOT track each
#     ~daily Claude Code release.
#
#   - The OPERATOR-LOCAL pin (`monitor/.state/cc-version-local`, which is
#     gitignored via `monitor/.gitignore` `.state/`) holds the version
#     THIS operator has validated through the gated cc-update routine
#     (`skills/nexus.cc-update/GUIDE.md`). A successful gated bump writes
#     THIS file and NEVER touches the shared `package.json`. This retires
#     the old "unpushed local bump commit" divergence workaround: the
#     working tree stays clean, the per-operator version lives in
#     uncommitted state.
#
# Effective-version resolution (the one rule every caller obeys):
#
#     effective = local-pin (if present and non-empty) else package.json floor
#
# `monitor/install-claude-local.sh` installs + verifies the EFFECTIVE
# version. The watcher's gate baseline (`_v2_task_cc_version_check`)
# compares the npm `latest` dist-tag against the EFFECTIVE version, so
# the gate fires when a release newer than what the operator ACTUALLY
# runs exists — independent of the (lagging) floor.
#
# Pure-ish: functions read/write files only where named, and have no
# side effects on source. Callers either set NEXUS_ROOT or pass explicit
# paths. The local-pin path honours NEXUS_STATE_DIR (the same override
# the watcher uses) so tests and alternate state dirs resolve correctly.

# ---- double-source guard ------------------------------------------------
if [[ -n "${_NEXUS_CC_VERSION_LOADED:-}" ]]; then
    return 0
fi
_NEXUS_CC_VERSION_LOADED=1

# cc_version_local_pin_path [nexus_root]
#
# Resolve the operator-local pin file path. Precedence:
#   1. $NEXUS_CC_LOCAL_PIN  — explicit override (tests, unusual layouts).
#   2. ${NEXUS_STATE_DIR:-<root>/monitor/.state}/cc-version-local — the
#      standard location, tracking the watcher's STATE_DIR override.
# <nexus_root> defaults to $NEXUS_ROOT. Always prints a path (rc 0).
cc_version_local_pin_path() {
    local nexus_root="${1:-${NEXUS_ROOT:-}}"
    if [[ -n "${NEXUS_CC_LOCAL_PIN:-}" ]]; then
        printf '%s\n' "$NEXUS_CC_LOCAL_PIN"
        return 0
    fi
    local state_dir="${NEXUS_STATE_DIR:-$nexus_root/monitor/.state}"
    printf '%s\n' "$state_dir/cc-version-local"
}

# cc_version_read_local_pin [nexus_root]
#
# Print the operator-local pin (whitespace-trimmed) if the file exists
# and is non-empty; rc 0. Returns non-zero with no output when the file
# is absent or blank — the signal that "no local pin → use the floor".
cc_version_read_local_pin() {
    local nexus_root="${1:-${NEXUS_ROOT:-}}"
    local path
    path=$(cc_version_local_pin_path "$nexus_root")
    [[ -f "$path" ]] || return 1
    local raw
    raw=$(<"$path")
    # Trim leading/trailing whitespace (incl. a trailing newline).
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    [[ -n "$raw" ]] || return 1
    printf '%s\n' "$raw"
}

# cc_version_floor <package_json> <package>
#
# Extract the FLOOR — the version pinned for <package> in <package_json>.
# Same parse as install-claude-local.sh / _cc_update_pinned_version: with
# -F'"' a `    "<pkg>": "<ver>"` line splits so the key is field $i and
# the value sits two fields later. Matching $i==package sidesteps having
# to regex-escape the scope slash. Prints the version (rc 0); non-zero +
# no output if the file or key is absent.
cc_version_floor() {
    local package_json="${1:?package_json required}"
    local package="${2:?package required}"
    [[ -f "$package_json" ]] || return 1
    local out
    out=$(awk -F'"' -v pkg="$package" '
        { for (i=1; i+2<=NF; i++) if ($i==pkg) { print $(i+2); exit } }
    ' "$package_json")
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

# cc_version_effective <package_json> <package> [nexus_root]
#
# The load-bearing resolver: local-pin if present, else the floor.
# Prints the effective version (rc 0). Returns non-zero only when NEITHER
# a local pin NOR a floor can be resolved (a malformed/absent
# package.json with no local pin) — callers treat that as a hard error.
cc_version_effective() {
    local package_json="${1:?package_json required}"
    local package="${2:?package required}"
    local nexus_root="${3:-${NEXUS_ROOT:-}}"
    local pin
    if pin=$(cc_version_read_local_pin "$nexus_root"); then
        printf '%s\n' "$pin"
        return 0
    fi
    cc_version_floor "$package_json" "$package"
}

# cc_version_effective_source <package_json> <package> [nexus_root]
#
# Like cc_version_effective but prints the SOURCE tag (`local-pin` or
# `floor`) instead of the version — for triage/logging so callers can
# report which tier resolved. rc mirrors cc_version_effective.
cc_version_effective_source() {
    local package_json="${1:?package_json required}"
    local package="${2:?package required}"
    local nexus_root="${3:-${NEXUS_ROOT:-}}"
    if cc_version_read_local_pin "$nexus_root" >/dev/null 2>&1; then
        printf 'local-pin\n'
        return 0
    fi
    if cc_version_floor "$package_json" "$package" >/dev/null 2>&1; then
        printf 'floor\n'
        return 0
    fi
    return 1
}

# cc_version_write_local_pin <version> [nexus_root]
#
# Write the operator-local pin atomically (write to a temp sibling, then
# rename) so a concurrent reader never sees a half-written value. Creates
# the state dir if needed. This is what the gated cc-update APPLY step
# calls to advance the LOCAL version without touching shared package.json.
# rc 0 on success; non-zero (with a message on stderr) on failure.
cc_version_write_local_pin() {
    local version="${1:?version required}"
    local nexus_root="${2:-${NEXUS_ROOT:-}}"
    local path dir
    path=$(cc_version_local_pin_path "$nexus_root")
    dir=$(dirname "$path")
    mkdir -p "$dir" 2>/dev/null || {
        printf 'cc_version_write_local_pin: cannot create %s\n' "$dir" >&2
        return 1
    }
    local tmp="$path.tmp.$$"
    if ! printf '%s\n' "$version" > "$tmp" 2>/dev/null; then
        printf 'cc_version_write_local_pin: cannot write %s\n' "$tmp" >&2
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    if ! mv -f "$tmp" "$path" 2>/dev/null; then
        printf 'cc_version_write_local_pin: cannot install %s\n' "$path" >&2
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}
