#!/usr/bin/env bash
# declare-wait.sh — worker self-declares async external work it's
# waiting on (slurm job, CI run, queued task, long curl, etc.).
#
# Edits the per-window heartbeat at
# `$NEXUS_STATE_DIR/heartbeat/$NEXUS_WORKER_WINDOW.json` (resolved
# the same way `monitor/worker-heartbeat.sh` resolves it: respects
# NEXUS_STATE_DIR override, else $NEXUS_ROOT/monitor/.state) by
# adding / removing entries in the `external_waits` array. The
# watcher's classifier (`monitor/pane-state.sh`) reads that array
# to distinguish a worker that's genuinely idle from one that's
# stranded waiting for an external job it has no resume mechanism
# for — `idle-orphan-async` in the new four-way classifier (issue
# #183).
#
# Usage:
#   declare-wait.sh <kind> <id> [<desc>]      add or update an entry
#                                             keyed on (kind, id);
#                                             idempotent.
#   declare-wait.sh --remove <kind> <id>      remove entry by key
#                                             (silent no-op if
#                                             missing).
#   declare-wait.sh --clear                   drop all entries.
#   declare-wait.sh --list                    print current entries
#                                             as one-line JSON.
#
# Examples (from a worker):
#   monitor/declare-wait.sh slurm 52527284_4 "bulk-edger retry"
#   monitor/declare-wait.sh ci    "your-org/nexus-code/runs/26304173692" "PR #182"
#   monitor/declare-wait.sh --remove slurm 52527284_4
#
# Schema of an entry:
#   {"kind": "slurm|ci|http|mail|...", "id": "<unique-id>", "desc": "<freeform>"}
#
# `kind` is intentionally open (no enum) so future wait shapes
# don't need a watcher change. The classifier only counts entries.
#
# Atomicity: read existing heartbeat → mutate `external_waits` →
# write to `<file>.$$.tmp` → rename. Other heartbeat fields
# (state, last_activity, monitor_handles, scheduled_wakeup_at,
# session_id, window) are preserved verbatim across the rewrite —
# this script never touches them. The matching guarantee on the
# PostToolUse hook side: `monitor/worker-heartbeat.sh` preserves
# `external_waits` across its own writes the same way.
#
# Inputs / env:
#   $NEXUS_WORKER_WINDOW   tmux window name. REQUIRED — fail loud
#                          if unset; this script is a worker tool,
#                          not a hook, so silent no-op would mask
#                          the contract violation.
#   $NEXUS_STATE_DIR       override (test escape hatch).
#   $NEXUS_ROOT            fallback root; resolves to
#                          $NEXUS_ROOT/monitor/.state.
#
# Exit codes:
#   0  success (mutation applied or list emitted)
#   2  bad usage / missing required env / jq missing

set -u

usage() {
    cat >&2 <<'EOF'
usage: declare-wait.sh <kind> <id> [<desc>]
       declare-wait.sh --remove <kind> <id>
       declare-wait.sh --clear
       declare-wait.sh --list

  Add a self-declared external wait to the worker heartbeat so the
  watcher can distinguish working-background / working-self-paced /
  idle-orphan-async from plain idle.

  See `skills/nexus.worker-defaults/SKILL.md` "Owning async
  external work" for the contract.
EOF
    exit 2
}

[[ $# -ge 1 ]] || usage

window="${NEXUS_WORKER_WINDOW:-}"
if [[ -z "$window" ]]; then
    echo "declare-wait.sh: NEXUS_WORKER_WINDOW unset — not in a worker context?" >&2
    exit 2
fi

if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    state_dir="$NEXUS_STATE_DIR"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    state_dir="$NEXUS_ROOT/monitor/.state"
else
    echo "declare-wait.sh: neither NEXUS_STATE_DIR nor NEXUS_ROOT set" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "declare-wait.sh: jq required" >&2
    exit 2
fi

hb_dir="$state_dir/heartbeat"
mkdir -p "$hb_dir" 2>/dev/null || {
    echo "declare-wait.sh: cannot mkdir $hb_dir" >&2
    exit 2
}
hb_file="$hb_dir/$window.json"

# Read existing content (if any) into a jq-parseable string; absent
# file ⇒ minimal seed object so the first declare-wait call doesn't
# race a missing PostToolUse hook (a worker can declare a wait
# before any tool has fired).
read_existing() {
    if [[ -f "$hb_file" ]] && [[ -r "$hb_file" ]]; then
        local content
        content=$(<"$hb_file") || content=""
        [[ -n "$content" ]] || content='{}'
        # Validate JSON shape; if corrupt, fall back to a fresh
        # object so a malformed prior write doesn't strand a worker
        # unable to declare a wait. The corrupted file is then
        # overwritten by this call's atomic rename.
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
        echo "declare-wait.sh: cannot write $tmp" >&2
        return 1
    }
    mv -f "$tmp" "$hb_file" 2>/dev/null || {
        rm -f "$tmp"
        echo "declare-wait.sh: cannot rename $tmp to $hb_file" >&2
        return 1
    }
}

# Seed the minimal field set the classifier needs when this is the
# first writer to touch the file. The PostToolUse hook will fill in
# `state` / `last_activity` / etc. on its next firing; until then,
# the classifier's heartbeat-fresh gate rejects this row (no
# `last_activity`), but `external_waits` is still available to the
# read-only consumers (e.g. `--list`).
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
        printf '%s' "$existing" | jq -c '.external_waits // []'
        ;;

    --clear)
        existing=$(read_existing)
        if [[ "$existing" == '{}' ]]; then
            existing=$(seed_skeleton)
        fi
        updated=$(printf '%s' "$existing" | jq -c '.external_waits = []')
        write_atomic "$updated"
        ;;

    --remove)
        # `declare-wait.sh --remove <kind> <id>`
        kind="${2:-}"
        id="${3:-}"
        [[ -n "$kind" && -n "$id" ]] || usage
        existing=$(read_existing)
        if [[ "$existing" == '{}' ]]; then
            existing=$(seed_skeleton)
        fi
        updated=$(printf '%s' "$existing" | jq -c \
            --arg k "$kind" --arg i "$id" \
            '.external_waits = ((.external_waits // []) | map(select(.kind != $k or .id != $i)))')
        write_atomic "$updated"
        ;;

    --help|-h)
        usage
        ;;

    -*)
        usage
        ;;

    *)
        # Positional: `declare-wait.sh <kind> <id> [<desc>]`. Add
        # or update the entry; matched on (kind, id) so a worker
        # calling twice with the same key updates the desc rather
        # than duplicating.
        kind="$1"
        id="${2:-}"
        desc="${3:-}"
        [[ -n "$kind" && -n "$id" ]] || usage
        existing=$(read_existing)
        if [[ "$existing" == '{}' ]]; then
            existing=$(seed_skeleton)
        fi
        updated=$(printf '%s' "$existing" | jq -c \
            --arg k "$kind" --arg i "$id" --arg d "$desc" \
            '.external_waits = (
                ((.external_waits // []) | map(select(.kind != $k or .id != $i)))
                + [{kind: $k, id: $i, desc: $d}]
            )')
        write_atomic "$updated"
        ;;
esac

exit 0
