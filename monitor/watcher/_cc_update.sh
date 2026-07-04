#!/usr/bin/env bash
# Watcher Claude Code update-detection signal.
#
# The DETECT→INFORM half of the GATED Claude Code self-update loop
# (cc-harness README "Pre-update gate: bump → gate → promote" already
# documents the EVALUATE→DECIDE→APPLY half; automating the detect/inform
# trigger is the future item it calls out). This module is that trigger.
#
# Contract: NEVER auto-bumps. It compares the locally pinned Claude Code
# version against the npm registry's `latest` dist-tag; when a newer
# release exists it writes a small advisory state file
# (`monitor/.state/cc-update-available`). The compose_emit task surfaces
# that file ONCE per candidate into the orchestrator emit, pointing at
# `skills/nexus.cc-update/GUIDE.md` so the orchestrator spawns an
# evaluator agent to run the gate before any pin is promoted.
#
# Why gated, not automatic: a cc release can drift the TUI bytes
# pane-state.sh / _unstick.sh depend on, or change CLI flags / hook /
# settings contracts the nexus relies on. Those collisions only surface
# under the cc-harness gate (monitor/cc-harness/gate.sh). Bumping
# silently would risk wedging the whole control surface. So: detect →
# inform → (human-spawned) evaluate → decide → apply.
#
# Fail-safe by construction: a registry fetch failure (offline, DNS,
# timeout, rate-limit, malformed JSON) leaves any existing signal
# untouched, writes nothing, logs nothing alarming, and returns a
# benign verdict. A version-detection helper must NEVER block or crash
# the watcher loop.
#
# Idempotency has two layers:
#   1. Detection layer — `_cc_update_write_signal` rewrites the state
#      file only when the candidate version changes, so re-running the
#      24h check against the same latest version does not churn the
#      file's mtime.
#   2. Surfacing layer — `_cc_update_emit_section` surfaces the section
#      only when the candidate differs from the last-surfaced version
#      (recorded in `cc-update-surfaced`), so the orchestrator is not
#      re-nagged about the same version on every emit.
#
# All functions are pure-ish (file + network side effects only where
# named) and free of side effects on source. Tests inject the registry
# fetch via the `fetch_cmd` indirection (see test-cc-update.sh).

# ---- double-source guard ------------------------------------------------
if [[ -n "${_NEXUS_CC_UPDATE_LOADED:-}" ]]; then
    return 0
fi
_NEXUS_CC_UPDATE_LOADED=1

# _cc_update_pinned_version <package_json_path> <package_name>
#
# Extract the version pinned for <package_name> in a package.json. This
# is the SAME source of truth `monitor/install-claude-local.sh` reads
# (the dependency pin), so the detection compares like-for-like against
# what a promote would install. Parameterised by package name so it is
# robust to a future rename. Prints the version on stdout; non-zero +
# no output if the file or key is absent.
_cc_update_pinned_version() {
    local package_json="${1:?package_json required}"
    local package="${2:?package required}"
    [[ -f "$package_json" ]] || return 1
    # With -F'"', a `    "<pkg>": "<ver>"` line splits so the key is an
    # even field and the value sits two fields later (the `: ` separator
    # is the field between them). Matching $i==package avoids having to
    # regex-escape the scope slash.
    local out
    out=$(awk -F'"' -v pkg="$package" '
        { for (i=1; i+2<=NF; i++) if ($i==pkg) { print $(i+2); exit } }
    ' "$package_json")
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

# _cc_update_default_fetch <package_name> [timeout_seconds]
#
# Default registry fetch: GET <registry>/<package>/latest, which returns
# the packument for the `latest` dist-tag (a JSON object with a
# `.version` field). Binds nothing, no auth, read-only. Override the
# registry base via $MONITOR_CC_UPDATE_REGISTRY (tests do not use this —
# they inject a shim fetch_cmd directly). Non-zero on any curl failure.
_cc_update_default_fetch() {
    local package="${1:?package required}"
    local timeout="${2:-10}"
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=10
    local registry="${MONITOR_CC_UPDATE_REGISTRY:-https://registry.npmjs.org}"
    command -v curl >/dev/null 2>&1 || return 1
    # -f: fail on HTTP >=400; -sS: quiet but show real errors; bounded
    # by --max-time so a hung registry can never stall the async task.
    curl -fsS --max-time "$timeout" "$registry/$package/latest"
}

# _cc_update_latest_version <package_name> [fetch_cmd] [timeout_seconds]
#
# Fetch the registry packument via <fetch_cmd> (default
# `_cc_update_default_fetch`) and extract `.version` with jq. Returns
# non-zero (no output) on fetch failure or a missing/empty version —
# the caller treats that as "unreachable" and fails safe.
_cc_update_latest_version() {
    local package="${1:?package required}"
    local fetch_cmd="${2:-_cc_update_default_fetch}"
    local timeout="${3:-10}"
    command -v jq >/dev/null 2>&1 || return 1
    local raw ver
    raw=$("$fetch_cmd" "$package" "$timeout") || return 1
    [[ -n "$raw" ]] || return 1
    ver=$(printf '%s' "$raw" | jq -r '.version // empty' 2>/dev/null) || return 1
    [[ -n "$ver" && "$ver" != "null" ]] || return 1
    printf '%s\n' "$ver"
}

# _cc_update_compare <installed> <candidate>
#
# Semver-aware comparison via `sort -V`. Prints one of:
#   same   — installed == candidate
#   newer  — candidate > installed (an update is available)
#   older  — candidate < installed (local is ahead of registry latest;
#            e.g. operator hand-installed a prerelease)
# Always rc 0 (the verdict is on stdout).
_cc_update_compare() {
    local installed="${1:?installed required}"
    local candidate="${2:?candidate required}"
    if [[ "$installed" == "$candidate" ]]; then
        printf 'same\n'
        return 0
    fi
    local highest
    highest=$(printf '%s\n%s\n' "$installed" "$candidate" | sort -V | tail -1)
    if [[ "$highest" == "$candidate" ]]; then
        printf 'newer\n'
    else
        printf 'older\n'
    fi
}

# _cc_update_field <state_file> <key>
#
# Read a single `key=value` field from a state file. Prints the value
# (everything after the first `=`); non-zero if the file or key is
# absent.
_cc_update_field() {
    local file="${1:?file required}"
    local key="${2:?key required}"
    [[ -f "$file" ]] || return 1
    local out
    out=$(awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$file")
    [[ -n "$out" ]] || return 1
    printf '%s\n' "$out"
}

# _cc_update_write_signal <state_file> <package> <installed> <candidate> <skill_path>
#
# Write the advisory signal file. Idempotent: if the file already
# records this exact candidate, it is left untouched (preserving its
# `detected=` timestamp and mtime) so the periodic check does not churn
# state when nothing changed.
_cc_update_write_signal() {
    local state_file="${1:?state_file required}"
    local package="${2:?package required}"
    local installed="${3:?installed required}"
    local candidate="${4:?candidate required}"
    local skill_path="${5:?skill_path required}"
    if [[ -f "$state_file" ]]; then
        local existing
        existing=$(_cc_update_field "$state_file" candidate 2>/dev/null || true)
        [[ "$existing" == "$candidate" ]] && return 0
    fi
    mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
    local now
    now=$(date -Is 2>/dev/null || date 2>/dev/null || echo unknown)
    {
        printf 'candidate=%s\n' "$candidate"
        printf 'installed=%s\n' "$installed"
        printf 'package=%s\n'   "$package"
        printf 'detected=%s\n'  "$now"
        printf 'skill=%s\n'     "$skill_path"
    } > "$state_file" 2>/dev/null || true
}

# _cc_update_decide <state_dir> <package> <pinned> <skill_path> [fetch_cmd] [timeout]
#
# The orchestration entry point the scheduler task calls. Fetches the
# registry latest, compares against the pinned version, and maintains
# the `cc-update-available` state file accordingly.
#
# stdout: a single-line verdict (for the watcher log).
# rc:
#   0  available    — newer release; signal written/refreshed.
#   1  current      — same/older; any stale signal removed (self-heal
#                     after a promote, or local ahead of registry).
#   2  unreachable | unknown — fail-safe: signal left exactly as-is,
#                     nothing written, nothing removed.
_cc_update_decide() {
    local state_dir="${1:?state_dir required}"
    local package="${2:?package required}"
    local pinned="${3:-}"
    local skill_path="${4:?skill_path required}"
    local fetch_cmd="${5:-_cc_update_default_fetch}"
    local timeout="${6:-10}"
    local state_file="$state_dir/cc-update-available"

    local latest
    if ! latest=$(_cc_update_latest_version "$package" "$fetch_cmd" "$timeout"); then
        # Fail-safe: do NOT touch the existing signal on a transient
        # registry failure — a pending update is still pending.
        printf 'unreachable reason=registry-fetch-failed package=%s' "$package"
        return 2
    fi

    if [[ -z "$pinned" ]]; then
        # No local pin to compare against — also fail-safe, leave state.
        printf 'unknown reason=no-pinned-version package=%s latest=%s' "$package" "$latest"
        return 2
    fi

    local cmp
    cmp=$(_cc_update_compare "$pinned" "$latest")
    case "$cmp" in
        newer)
            _cc_update_write_signal "$state_file" "$package" "$pinned" "$latest" "$skill_path"
            printf 'available candidate=%s installed=%s package=%s' "$latest" "$pinned" "$package"
            return 0
            ;;
        same|older)
            # Self-heal: installed has caught up (post-promote) or is
            # ahead of registry latest. Clear any stale signal so the
            # emit stops surfacing it.
            [[ -f "$state_file" ]] && rm -f "$state_file" 2>/dev/null || true
            printf 'current installed=%s latest=%s package=%s' "$pinned" "$latest" "$package"
            return 1
            ;;
        *)
            # Defensive: _cc_update_compare always prints one of the
            # three, but never trust an empty cmp into a destructive path.
            printf 'unknown reason=compare-shape cmp=%q' "$cmp"
            return 2
            ;;
    esac
}

# _cc_update_emit_section <state_dir>
#
# The surfacing entry point the compose paths call. When an UNSURFACED
# update signal exists, prints the emit section (and marks the candidate
# surfaced so it is not re-nagged); otherwise prints nothing.
#
# stdout: the rendered section (empty when nothing to surface).
# rc: 0 when a section was emitted, 1 when nothing to surface.
#
# Re-nag guard: the candidate version last surfaced is recorded in
# `cc-update-surfaced`. A section is emitted only when the current
# candidate differs from it. Marking happens at compose time (mirrors
# the install-failure flag's consume-on-compose model); the rare cost is
# a missed surface if that single emit's paste is then suppressed — cc
# publishes ~daily so a new candidate re-arms quickly, and the state
# file persists for `cat`/introspection regardless.
_cc_update_emit_section() {
    local state_dir="${1:?state_dir required}"
    local state_file="$state_dir/cc-update-available"
    local surfaced_file="$state_dir/cc-update-surfaced"

    # Emit gate (default OFF). The manual "update available" nag exists to
    # trigger the human-driven evaluate→gate→bump loop. When the autonomous
    # daily routine (cc_auto_update, fires ~04:00) is closing that loop on
    # its own — running the SAME cc-harness gate and bumping only on a
    # provably-safe verdict — the manual nag is redundant noise. So this
    # orchestrator-facing surface is silenced by default. Detection still
    # runs and maintains the signal file (cc-update-available), so
    # `cat`/introspection and the autonomous routine's surfacing note are
    # unaffected; only this emit is suppressed. An operator who wants the
    # manual gate back flips monitor.cc_update.emit_enabled=true.
    # CAVEAT: silencing this emit removes the *manual* evaluation trigger
    # but NOT any gate — the gate lives in the autonomous routine
    # (monitor/cc-auto-update-apply.sh), which must be ENABLED separately
    # (monitor.cc_auto_update.enabled=true) for any 04:00 bump to happen.
    [[ "${MONITOR_CC_UPDATE_EMIT_ENABLED:-false}" == "true" ]] || return 1

    [[ -f "$state_file" ]] || return 1
    local candidate
    candidate=$(_cc_update_field "$state_file" candidate 2>/dev/null || true)
    [[ -n "$candidate" ]] || return 1

    if [[ -f "$surfaced_file" ]]; then
        local last
        last=$(cat "$surfaced_file" 2>/dev/null || true)
        [[ "$last" == "$candidate" ]] && return 1
    fi

    local installed skill
    installed=$(_cc_update_field "$state_file" installed 2>/dev/null || echo '?')
    skill=$(_cc_update_field "$state_file" skill 2>/dev/null \
        || echo 'skills/nexus.cc-update/GUIDE.md')

    printf 'A newer Claude Code release is available: %s (installed pin: %s).\n' \
        "$candidate" "$installed"
    printf 'GATED signal — do NOT bump silently. Spawn an evaluator agent\n'
    printf 'pre-briefed with the updater skill:\n'
    printf '  %s\n' "$skill"
    printf 'It drives: changelog review -> collision analysis against\n'
    printf 'cc-version-sensitive surfaces (pane-state _detect_*, _unstick\n'
    printf 'Case A/D, VI-mode, hooks/settings, CLI flags) -> cc-harness gate\n'
    printf '  monitor/cc-harness/gate.sh --version %s\n' "$candidate"
    printf '%s\n' '-> decide safe-to-bump / needs-review / block.'
    # When the autonomous daily routine is enabled, the watcher itself
    # will spawn the evaluator at the configured fire time — the
    # orchestrator must NOT also spawn a manual one (duplicate work,
    # double gate runs). Gated on the config var so operators without
    # the routine see the unchanged manual instruction.
    if [[ "${MONITOR_CC_AUTO_UPDATE_ENABLED:-false}" == "true" ]]; then
        printf 'NOTE: the autonomous daily cc-update routine is ENABLED (fires at %s).\n' \
            "${MONITOR_CC_AUTO_UPDATE_FIRE_TIME:-04:00}"
        printf 'Do NOT spawn a manual evaluator — the watcher will dispatch one\n'
        printf 'automatically; see monitor/.state/cc-auto-update/decisions.tsv.\n'
    fi

    # Mark surfaced last so the same candidate is not re-nagged.
    mkdir -p "$(dirname "$surfaced_file")" 2>/dev/null || true
    printf '%s\n' "$candidate" > "$surfaced_file" 2>/dev/null || true
    return 0
}
