#!/usr/bin/env bash
# Operator-local settings overlay (your-org/nexus-code#614, second defect).
#
# THE PROBLEM. `monitor/worker-settings.json` and
# `monitor/orchestrator-settings.json` are TRACKED files that every
# operator must edit to carry operator-LOCAL configuration — the case
# that motivated this overlay was a nexus carrying `"model":
# "claude-opus-5"` and `"tui": "fullscreen"` in those tracked files,
# neither of which exists upstream. (Both have since left the tracked
# files: `tui` was reverted in b37bb68 / your-org/nexus-code#570, and a
# model pin belongs in the `.local.json` described below. They are named
# here as the worked example, not as keys the tracked files carry
# today.) Two consequences follow, and the second is the dangerous one:
#
#   1. Every `git pull` conflicts on both files, forever.
#   2. The obvious conflict resolution — discard local, take upstream —
#      SILENTLY DOWNGRADES every worker and skeptic off the operator's
#      chosen model. No error, no warning; the next worker simply runs
#      on a weaker model and nobody can tell from the outside.
#
# (2) is a live footgun in a repo whose whole update story is "pull and
# the watcher restarts itself". Documentation cannot fix a file layout
# that puts local and shared configuration in the same bytes.
#
# THE FIX. Keep the tracked file as the DEFAULTS, and let an UNTRACKED
# sibling `<name>.local.json` override keys on top of it. The merged
# result is materialised under `monitor/.state/settings/` (gitignored)
# and that path is what gets passed to `claude --settings`. A pull can
# now never touch the operator's model pin, because the pin does not
# live in a tracked file any more.
#
#   monitor/worker-settings.json          tracked   — hooks, defaults
#   monitor/worker-settings.local.json    UNTRACKED — operator's keys
#   monitor/.state/settings/worker-settings.effective.json   generated
#
# MERGE SEMANTICS: recursive object merge, local wins on conflicts
# (jq's `*`). Objects merge key-by-key so a local file setting only
# `model` inherits the entire tracked `hooks` block; ARRAYS REPLACE
# wholesale, which is what you want for a hook list — a local file that
# defines `hooks.Stop` replaces that event's hooks rather than appending
# to them.
#
# FAILURE POSTURE — FAIL LOUD, NEVER SILENTLY DEGRADE. The bug being
# fixed is a silent downgrade, so every failure path here must be
# noisier than the bug. Malformed local JSON, a jq that is missing, an
# unwritable state dir: each returns non-zero with a message on stderr.
# Callers treat that as a spawn-blocker. Falling back to the tracked
# defaults would reintroduce the exact silent-downgrade this exists to
# prevent — the operator asked for opus and would get sonnet because a
# comma was missing.
#
# Usage:
#   eff=$(monitor/resolve-settings.sh <path-to-tracked-settings.json>) || exit
#   claude --settings "$eff" ...
#
# With no `.local.json` present the tracked path is echoed unchanged —
# zero new files, zero behaviour change, so this is a no-op for every
# operator who has not opted in.

set -uo pipefail

base="${1:-}"
if [[ -z "$base" ]]; then
    printf 'resolve-settings: usage: resolve-settings.sh <settings.json>\n' >&2
    exit 2
fi
if [[ ! -f "$base" ]]; then
    printf 'resolve-settings: base settings file missing: %s\n' "$base" >&2
    exit 3
fi

dir="${base%/*}"
file="${base##*/}"
stem="${file%.json}"
local_file="$dir/${stem}.local.json"

# No overlay — the common case, and a pure pass-through.
if [[ ! -f "$local_file" ]]; then
    printf '%s' "$base"
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    printf 'resolve-settings: %s exists but jq is unavailable — refusing to spawn with the operator overlay SILENTLY DROPPED (that is the #614 downgrade). Install jq or remove the overlay.\n' \
        "$local_file" >&2
    exit 4
fi
# Validate by asking for the PROPERTY (this parses to a JSON object),
# not the proxy (jq exited 0). jq 1.5 — which ships on the sandbox
# hosts — exits 0 on a TRUNCATED document while emitting nothing at
# all, so `jq -e . file >/dev/null` waves through exactly the malformed
# overlay this guard exists to catch. Require the type name on stdout.
_json_type() {
    local t
    t=$(jq -r 'type' "$1" 2>/dev/null) || return 1
    [[ -n "$t" ]] || return 1
    printf '%s' "$t"
}
lt=$(_json_type "$local_file") || lt=""
if [[ "$lt" != "object" ]]; then
    printf 'resolve-settings: %s is not a valid JSON object (parsed as %s) — refusing to spawn rather than silently ignoring the operator overlay.\n' \
        "$local_file" "${lt:-unparseable}" >&2
    exit 5
fi
bt=$(_json_type "$base") || bt=""
if [[ "$bt" != "object" ]]; then
    printf 'resolve-settings: %s is not a valid JSON object (parsed as %s).\n' \
        "$base" "${bt:-unparseable}" >&2
    exit 6
fi

state_dir="${NEXUS_STATE_DIR:-$dir/.state}/settings"
if ! mkdir -p "$state_dir" 2>/dev/null; then
    printf 'resolve-settings: cannot create %s — refusing to spawn without the operator overlay.\n' \
        "$state_dir" >&2
    exit 7
fi

out="$state_dir/${stem}.effective.json"
tmp="$out.$$.tmp"
if ! jq -s '.[0] * .[1]' "$base" "$local_file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    printf 'resolve-settings: merge of %s over %s failed — refusing to spawn.\n' \
        "$local_file" "$base" >&2
    exit 8
fi
# Verify the PROPERTY (the merged file is usable settings), not the
# proxy (jq exited 0). A merge can succeed into something that is not
# an object — e.g. if either input is a top-level array.
if ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    printf 'resolve-settings: merged settings are not a JSON object — refusing to spawn.\n' >&2
    exit 9
fi
if ! mv "$tmp" "$out" 2>/dev/null; then
    rm -f "$tmp"
    printf 'resolve-settings: cannot write %s — refusing to spawn.\n' "$out" >&2
    exit 10
fi
chmod 600 "$out" 2>/dev/null || true
printf '%s' "$out"
exit 0
