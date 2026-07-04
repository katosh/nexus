#!/usr/bin/env bash
# monitor/hooks/async-launch-detect.sh
#
# Claude Code PostToolUse hook for the `Bash` matcher. Inspects the
# command the worker just ran and the stdout it produced; when one
# of the patterns in `monitor/async-launch-patterns.conf` fires,
# adds a (kind, id, desc) entry to the per-window heartbeat's
# `external_waits` array. The watcher's `pane-state.sh` classifier
# uses that array to emit `idle-orphan-async` against workers that
# launched async work but installed no resume mechanism (issue
# #183).
#
# Dismissed-launch escape hatch: if `(kind, id)` is already in the
# worker's `dismissed_waits` (set via `monitor/declare-no-wait.sh`),
# the launch is treated as deliberately fire-and-forget — no
# external_waits entry, no orphan-async signal. This lets a worker
# legitimately submit "set it and forget it" jobs without the
# watcher noising the operator.
#
# Data-driven: `monitor/async-launch-patterns.conf` is the pattern
# source. Adding a new launch class is a data edit, not a code
# change. See the conf file for the row format.
#
# Atomic write: read the heartbeat → mutate `external_waits` →
# write to `<file>.$$.tmp` → rename. The PostToolUse heartbeat
# hook (`monitor/worker-heartbeat.sh`) preserves `external_waits`
# and `dismissed_waits` across its own writes, so the two hooks
# can fire in either order within the same PostToolUse cycle.
#
# Hot-path discipline: every failure path exits 0 silently. A
# wedged hook would block claude's turn — degraded silently is
# better than blocking. The classifier's pane-footer fallback
# still works even without this hook.
#
# Inputs / env:
#   $NEXUS_WORKER_WINDOW   tmux window name (exported by
#                          spawn-worker.sh).
#   $NEXUS_STATE_DIR       override (test escape hatch).
#   $NEXUS_ROOT            fallback root; also the source of
#                          async-launch-patterns.conf.
#   $NEXUS_ASYNC_PATTERNS  optional override for the conf path
#                          (test escape hatch).
#
# Stdin: PostToolUse payload JSON. We read `.tool_input.command`
# and `.tool_response.stdout`. Cap reads at 64 KiB each (claude's
# stdout can be large; we only need the launcher's success line).

set -u

# Guard rails — these don't fire stderr; missing env on a hook
# means we silently no-op. The hook is best-effort.
window="${NEXUS_WORKER_WINDOW:-}"
[[ -n "$window" ]] || exit 0

if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    state_dir="$NEXUS_STATE_DIR"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    state_dir="$NEXUS_ROOT/monitor/.state"
else
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

# Resolve pattern conf path. Prefer the env override; else fall
# back to NEXUS_ROOT or a script-relative location.
if [[ -n "${NEXUS_ASYNC_PATTERNS:-}" ]]; then
    pattern_file="$NEXUS_ASYNC_PATTERNS"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    pattern_file="$NEXUS_ROOT/monitor/async-launch-patterns.conf"
else
    self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || self_dir="."
    pattern_file="$self_dir/../async-launch-patterns.conf"
fi
[[ -f "$pattern_file" ]] || exit 0

# Cap stdin at 64 KiB. claude's payloads are small (<2 KiB
# typical) but Bash tool_response.stdout can be arbitrary.
payload=$(head -c 65536 2>/dev/null || true)
[[ -n "$payload" ]] || exit 0

# Confirm this is a PostToolUse on Bash. The hook is configured
# with matcher="Bash" in worker-settings.json but a misconfigured
# install might funnel other tool calls here — defensively skip.
tool_name=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || tool_name=""
[[ "$tool_name" == "Bash" ]] || exit 0

command_str=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || command_str=""
[[ -n "$command_str" ]] || exit 0

# Cap stdout at 16 KiB. The launcher's "Submitted batch job N"
# line is in the first few hundred bytes; we don't need the tail.
stdout_str=$(printf '%s' "$payload" | jq -r '.tool_response.stdout // empty' 2>/dev/null | head -c 16384) || stdout_str=""

hb_dir="$state_dir/heartbeat"
mkdir -p "$hb_dir" 2>/dev/null || exit 0
hb_file="$hb_dir/$window.json"

# Read prior heartbeat for dismissed-waits filtering AND for
# preserving the rest of the fields across our atomic rewrite. A
# missing / corrupt file falls back to an empty skeleton — the
# next worker-heartbeat.sh tick will fill in the missing tick
# fields.
read_existing() {
    if [[ -f "$hb_file" ]] && [[ -r "$hb_file" ]]; then
        local content
        content=$(<"$hb_file") || content=""
        [[ -n "$content" ]] || content='{}'
        if printf '%s' "$content" | jq empty >/dev/null 2>&1; then
            printf '%s' "$content"
        else
            printf '{}'
        fi
    else
        printf '{}'
    fi
}

# Iterate pattern rows. First command_regex that matches the
# worker's command wins (a typical worker command matches at most
# one launch class anyway; deterministic ordering avoids
# surprises). We emit zero or one new external_waits entry per
# hook fire.
matched_kind=""
matched_id=""
matched_desc=""

while IFS='|' read -r kind cmd_re id_re desc; do
    # Skip blank and comment lines.
    [[ -z "${kind// /}" ]] && continue
    case "$kind" in
        '#'*) continue ;;
    esac
    [[ -n "$cmd_re" ]] || continue
    # Match command. Bash =~ uses POSIX ERE.
    if [[ "$command_str" =~ $cmd_re ]]; then
        matched_kind="$kind"
        matched_desc="$desc"
        # Extract id from stdout if id_regex was provided. The
        # first capture group is the id. Otherwise synthesize a
        # short stable id from sha1(command_str)[0:12] so dismissal
        # by (kind, id) remains feasible.
        if [[ -n "$id_re" ]] && [[ -n "$stdout_str" ]]; then
            if [[ "$stdout_str" =~ $id_re ]]; then
                matched_id="${BASH_REMATCH[1]}"
            fi
        fi
        if [[ -z "$matched_id" ]]; then
            if command -v sha1sum >/dev/null 2>&1; then
                matched_id=$(printf '%s' "$command_str" \
                    | sha1sum 2>/dev/null | cut -c1-12)
            fi
            # Final fallback: epoch-anchored synthetic.
            [[ -n "$matched_id" ]] || matched_id="syn-$(date +%s)"
            # Prefix synthetic ids so the operator can tell them
            # apart from real launcher ids on sight.
            matched_id="syn-${matched_id}"
        fi
        break
    fi
done < "$pattern_file"

# No match → no work. Fast path for the common case of a
# non-launching Bash call (cd, ls, grep, …).
[[ -n "$matched_kind" ]] || exit 0

# Read existing heartbeat once, then check dismissed_waits BEFORE
# mutating. Saves a write when (kind, id) was already dismissed.
existing=$(read_existing)

dismissed_hit=$(printf '%s' "$existing" | jq -r \
    --arg k "$matched_kind" --arg i "$matched_id" \
    '((.dismissed_waits // []) | map(select(.kind == $k and .id == $i)) | length)' \
    2>/dev/null) || dismissed_hit=0
if [[ "$dismissed_hit" =~ ^[1-9][0-9]*$ ]]; then
    exit 0
fi

# Idempotent insert: drop any prior row with the same (kind, id),
# then append. Workers often re-submit the same job during a
# retry; we want the latest desc and a single entry, not a stack
# of duplicates.
if [[ "$existing" == '{}' ]]; then
    now=$(date +%s)
    existing=$(jq -nc \
        --arg window "$window" \
        --argjson now "$now" \
        '{window: $window, last_activity: $now, external_waits: [], dismissed_waits: []}')
fi

updated=$(printf '%s' "$existing" | jq -c \
    --arg k "$matched_kind" \
    --arg i "$matched_id" \
    --arg d "$matched_desc" \
    '.external_waits = (
        ((.external_waits // []) | map(select(.kind != $k or .id != $i)))
        + [{kind: $k, id: $i, desc: $d}]
    )') || exit 0

tmp="$hb_file.$$.tmp"
printf '%s\n' "$updated" > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }
mv -f "$tmp" "$hb_file" 2>/dev/null || rm -f "$tmp"
exit 0
