#!/usr/bin/env bash
# declare-no-wait.sh — mark a specific async launch as deliberately
# fire-and-forget. The watcher will NOT classify the worker as
# `idle-orphan-async` for this (kind, id) entry.
#
# Companion to `monitor/declare-wait.sh`. Difference:
#   declare-wait.sh    — manual ADD to external_waits (for kinds the
#                        auto-detect hook can't see).
#   declare-no-wait.sh — sticky DISMISS: removes the (kind, id) from
#                        external_waits AND adds it to
#                        dismissed_waits. The PostToolUse auto-detect
#                        hook (issue #183) consults dismissed_waits
#                        before adding a new entry, so this
#                        dismissal survives re-detection across
#                        future Bash calls.
#
# Usage:
#   declare-no-wait.sh <kind> <id>            mark (kind, id) fire-and-forget
#   declare-no-wait.sh --un-dismiss <kind> <id>
#                                             remove from dismissed_waits
#                                             (auto-detect can re-add).
#   declare-no-wait.sh --list                 print current dismissals.
#
# Use case: you submitted a long-running slurm job whose result
# you'll check tomorrow morning by hand; the watcher would
# otherwise emit `idle-orphan-async` against you. Run
# `declare-no-wait.sh slurm 52527284_4` after the sbatch and the
# watcher will treat the worker as plain `idle` (subject to the
# usual wrap-up rules).
#
# Inputs / env:
#   $NEXUS_WORKER_WINDOW   tmux window name. REQUIRED.
#   $NEXUS_STATE_DIR       override (test escape hatch).
#   $NEXUS_ROOT            fallback root.
#
# Atomicity: read-modify-write with `.tmp` + `mv`. The PostToolUse
# heartbeat hook preserves both `external_waits` and
# `dismissed_waits` across its own writes, so a worker calling
# `declare-no-wait` mid-flow won't have the dismissal clobbered.
#
# Exit codes:
#   0  success
#   2  bad usage / missing env / jq missing

set -u

usage() {
    cat >&2 <<'EOF'
usage: declare-no-wait.sh <kind> <id>
       declare-no-wait.sh --un-dismiss <kind> <id>
       declare-no-wait.sh --list

  Mark an async launch as deliberately fire-and-forget. See
  `skills/nexus.worker-defaults/SKILL.md` "Owning async external
  work" for when to use this.
EOF
    exit 2
}

[[ $# -ge 1 ]] || usage

window="${NEXUS_WORKER_WINDOW:-}"
if [[ -z "$window" ]]; then
    echo "declare-no-wait.sh: NEXUS_WORKER_WINDOW unset — not in a worker context?" >&2
    exit 2
fi

if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    state_dir="$NEXUS_STATE_DIR"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    state_dir="$NEXUS_ROOT/monitor/.state"
else
    echo "declare-no-wait.sh: neither NEXUS_STATE_DIR nor NEXUS_ROOT set" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "declare-no-wait.sh: jq required" >&2
    exit 2
fi

hb_dir="$state_dir/heartbeat"
mkdir -p "$hb_dir" 2>/dev/null || {
    echo "declare-no-wait.sh: cannot mkdir $hb_dir" >&2
    exit 2
}
hb_file="$hb_dir/$window.json"

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

write_atomic() {
    local payload="$1"
    local tmp="$hb_file.$$.tmp"
    printf '%s\n' "$payload" > "$tmp" 2>/dev/null || {
        echo "declare-no-wait.sh: cannot write $tmp" >&2
        return 1
    }
    mv -f "$tmp" "$hb_file" 2>/dev/null || {
        rm -f "$tmp"
        echo "declare-no-wait.sh: cannot rename $tmp to $hb_file" >&2
        return 1
    }
}

seed_skeleton() {
    local now
    now=$(date +%s)
    jq -nc \
        --arg window "$window" \
        --argjson now "$now" \
        '{window: $window, last_activity: $now, external_waits: [], dismissed_waits: []}'
}

case "${1:-}" in
    --list)
        existing=$(read_existing)
        printf '%s' "$existing" | jq -c '.dismissed_waits // []'
        ;;

    --un-dismiss)
        kind="${2:-}"
        id="${3:-}"
        [[ -n "$kind" && -n "$id" ]] || usage
        existing=$(read_existing)
        if [[ "$existing" == '{}' ]]; then
            existing=$(seed_skeleton)
        fi
        updated=$(printf '%s' "$existing" | jq -c \
            --arg k "$kind" --arg i "$id" \
            '.dismissed_waits = ((.dismissed_waits // []) | map(select(.kind != $k or .id != $i)))')
        write_atomic "$updated"
        ;;

    --help|-h)
        usage
        ;;

    -*)
        usage
        ;;

    *)
        # Positional: `declare-no-wait.sh <kind> <id>`. Move the
        # entry from external_waits to dismissed_waits (or add a
        # standalone dismissal if no matching external_waits row
        # exists yet — covers the case where the worker dismisses
        # BEFORE the hook auto-detects).
        kind="$1"
        id="${2:-}"
        [[ -n "$kind" && -n "$id" ]] || usage
        existing=$(read_existing)
        if [[ "$existing" == '{}' ]]; then
            existing=$(seed_skeleton)
        fi
        updated=$(printf '%s' "$existing" | jq -c \
            --arg k "$kind" --arg i "$id" \
            '.external_waits = ((.external_waits // []) | map(select(.kind != $k or .id != $i)))
             | .dismissed_waits = (
                ((.dismissed_waits // []) | map(select(.kind != $k or .id != $i)))
                + [{kind: $k, id: $i}]
            )')
        write_atomic "$updated"
        ;;
esac

exit 0
