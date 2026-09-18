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
#   0  success — and, for a dismissal, the (kind, id) WAS in
#      `external_waits`, so a real wait was lifted.
#   2  bad usage / missing env / jq missing / REFUSED on shape
#      (your-org/nexus-code#1326 — see `monitor/_wait_id.sh`)
#   4  the write happened and MATCHED NOTHING. The dismissal is
#      recorded (the sticky pre-detection path below is legitimate and
#      is preserved), but no `external_waits` entry was lifted, so the
#      caller must not read this as "the wait is now dismissed".
#      **rc 4 IS THE EXPECTED STATUS FOR A DELIBERATE PRE-ARM** — a
#      dismissal filed before the auto-detect hook has seen the launch
#      matches nothing by construction. It is reported because a pre-arm
#      and a mistyped id are INDISTINGUISHABLE from the record, so the
#      only honest thing is to flag both and let the caller tell them
#      apart. Consequence for callers: do NOT chain this verb with `&&`
#      and do NOT run it under `set -e` without handling 4.
#      Before `#1326` this case was indistinguishable from a real
#      dismissal: both were rc 0 and silent. That is the
#      manufactured-success direction — the operator believes the wait
#      is gone, the next watcher emit still names it, and the natural
#      next move is something blunter.
#   5  REFUSED — the heartbeat file EXISTS but does not parse (or is
#      empty / unreadable). NOTHING was written (your-org/nexus-code#1390).
#      This verb LIFTS a hold; seeding a fresh skeleton over a file it
#      cannot read would silently discard every outstanding wait the
#      file held, for every id — and the rc-4 text would then describe
#      the opposite of what happened. `declare-wait.sh` (which ADDS)
#      keeps its reseed fallback on purpose: the two verbs want
#      opposite defaults. The diagnostic names the file; inspect it
#      with `jq empty <file>`, repair or move it aside, then re-run.

set -u

# Shared (kind, id) shape floor, so the DECLARE side and the DISMISS
# side accept exactly the same language. See `monitor/_wait_id.sh` for
# why this is a character class and not a per-kind grammar.
_dnw_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$_dnw_dir/_wait_id.sh"
_wait_id_prog='declare-no-wait.sh'

usage() {
    cat >&2 <<'EOF'
usage: declare-no-wait.sh <kind> <id>
       declare-no-wait.sh --un-dismiss <kind> <id>
       declare-no-wait.sh --list

  Mark an async launch as deliberately fire-and-forget. See
  `skills/nexus.worker-defaults/SKILL.md`, `## Worker floor`, "Own
  your async work …" for when to use this.

  Exit 4 means the dismissal was RECORDED but lifted no outstanding
  wait — the id is not the one on record (your-org/nexus-code#1326).
  Exit 5 means the heartbeat EXISTS but does not parse; NOTHING was
  written — inspect the named file (your-org/nexus-code#1390).
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

# FAIL CLOSED on a heartbeat that EXISTS but does not parse
# (your-org/nexus-code#1390). This used to be byte-identical to
# `declare-wait.sh`'s `read_existing`, which falls back to `{}` on a
# corrupt file — deliberately there, with a comment: a worker unable to
# DECLARE a wait is the worse outcome for a verb that ADDS. Here the
# fallback was inherited without the reasoning, in a verb whose job is to
# LIFT a hold: `{}` becomes `seed_skeleton()` (`external_waits: []`), the
# atomic rename lands it, and every outstanding wait is gone — for ANY
# id, valid or not. Measured on #1390: three real waits + a truncated
# heartbeat + one well-formed dismissal -> rc 4, `external_waits = []`,
# and the rc-4 text saying "no outstanding wait was lifted". A wrong
# story is harder to recover from than no story.
#
# Absent file: still seeded (the pre-arm path is legitimate — a worker
# may dismiss before any hook has written a heartbeat). Present but
# empty, unparseable, or unreadable: REFUSE before touching it. Called
# as a statement (not inside `$(…)`) so the `exit` reaches the caller —
# `read_existing` runs in a command substitution, where an exit would be
# swallowed and the seeding would proceed anyway.
_dnw_refuse_unparseable() {
    [[ -e "$hb_file" ]] || return 0
    local why=""
    if [[ ! -r "$hb_file" ]]; then
        why="exists but is not readable"
    elif [[ ! -s "$hb_file" ]]; then
        why="exists but is EMPTY (0 bytes) — no in-repo writer produces this; all three use tmp+rename"
    elif ! jq empty "$hb_file" >/dev/null 2>&1; then
        why="exists but does not parse as JSON (jq empty failed)"
    fi
    [[ -n "$why" ]] || return 0
    printf 'declare-no-wait.sh: REFUSED — the heartbeat %s:
    %s
' "$why" "$hb_file" >&2
    printf '  Nothing was written. This verb lifts ONE wait; reinitialising an unreadable
' >&2
    printf '  heartbeat would silently discard EVERY outstanding wait it held, for every
' >&2
    printf '  id (your-org/nexus-code#1390). Inspect it (`jq empty %q`), repair or move it
' "$hb_file" >&2
    printf '  aside, then re-run. rc 5.
' >&2
    exit 5
}

read_existing() {
    if [[ -f "$hb_file" ]] && [[ -r "$hb_file" ]]; then
        local content
        content=$(<"$hb_file") || content=""
        [[ -n "$content" ]] || content='{}'
        if printf '%s' "$content" | jq empty >/dev/null 2>&1; then
            printf '%s' "$content"
        else
            # Unreachable on the write paths (the refusal above exits first);
            # kept so a future read-only path degrades the same way as before.
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

# Print the authoritative record so a caller whose (kind, id) matched
# nothing can SEE the real ids rather than guess at them. This is the
# recovery step for a truncated id, which no character class can catch
# (`syn-` is well-formed and short).
_dnw_show_ledger() {
    local field="$1" json="$2" rows
    rows=$(printf '%s' "$json" | jq -r --arg f "$field" \
        '(.[$f] // []) | if length == 0 then "    (none)"
                         else map("    \(.kind):\(.id)") | join("\n") end' 2>/dev/null)
    printf '  %s on record for this window:\n%s\n' "$field" "${rows:-    (unreadable)}" >&2
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
        _dnw_refuse_unparseable
        existing=$(read_existing)
        printf '%s' "$existing" | jq -c '.dismissed_waits // []'
        ;;

    --un-dismiss)
        kind="${2:-}"
        id="${3:-}"
        [[ -n "$kind" && -n "$id" ]] || usage
        # NO SHAPE GATE ON THE REMOVE PATH (your-org/nexus-code#1373 skeptic
        # finding 2). Gating removal is the one place the floor can only
        # STRAND: a malformed row written by the PRE-FIX code is exactly what
        # an operator needs to delete, and refusing the delete leaves it
        # permanently — with no `--clear` on this verb, the only way out is
        # hand-edited JSON. That is the state `_wait_id.sh`'s own header warns
        # against, arriving through the UPGRADE path. All four hazard inputs
        # arrive on the CREATE path and are still refused there; removal can
        # only ever shrink the record, so an unvalidated id here is harmless.
        _dnw_refuse_unparseable
        existing=$(read_existing)
        if [[ "$existing" == '{}' ]]; then
            existing=$(seed_skeleton)
        fi
        had=$(printf '%s' "$existing" | jq -r \
            --arg k "$kind" --arg i "$id" \
            '[(.dismissed_waits // [])[] | select(.kind == $k and .id == $i)] | length')
        [[ "$had" =~ ^[0-9]+$ ]] || had=0
        updated=$(printf '%s' "$existing" | jq -c \
            --arg k "$kind" --arg i "$id" \
            '.dismissed_waits = ((.dismissed_waits // []) | map(select(.kind != $k or .id != $i)))')
        write_atomic "$updated" || exit 2
        if (( had == 0 )); then
            printf 'declare-no-wait.sh: MATCHED NOTHING — no dismissal for (%s, %s) was on record for window %s.\n' \
                "$kind" "$id" "$window" >&2
            _dnw_show_ledger dismissed_waits "$existing"
            exit 4
        fi
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
        wait_id_check "$kind" "$id" || exit 2
        _dnw_refuse_unparseable
        existing=$(read_existing)
        if [[ "$existing" == '{}' ]]; then
            existing=$(seed_skeleton)
        fi
        # Count the entry BEFORE mutating. This is the difference
        # between "a wait was lifted" and "a row was appended to a
        # ledger nothing will ever match", and it is the only thing
        # that distinguishes them — the write itself succeeds either
        # way.
        had=$(printf '%s' "$existing" | jq -r \
            --arg k "$kind" --arg i "$id" \
            '[(.external_waits // [])[] | select(.kind == $k and .id == $i)] | length')
        [[ "$had" =~ ^[0-9]+$ ]] || had=0
        updated=$(printf '%s' "$existing" | jq -c \
            --arg k "$kind" --arg i "$id" \
            '.external_waits = ((.external_waits // []) | map(select(.kind != $k or .id != $i)))
             | .dismissed_waits = (
                ((.dismissed_waits // []) | map(select(.kind != $k or .id != $i)))
                + [{kind: $k, id: $i}]
            )')
        write_atomic "$updated" || exit 2
        if (( had == 0 )); then
            printf 'declare-no-wait.sh: RECORDED (pre-arm) — nothing to lift. (%s, %s) was not in external_waits for window %s.\n' \
                "$kind" "$id" "$window" >&2
            printf '  This is the EXPECTED result when you dismiss BEFORE the auto-detect hook\n' >&2
            printf '  has seen the launch. The dismissal is on record and is sticky, so the\n' >&2
            printf '  later detection of this exact (kind, id) will be skipped.\n' >&2
            printf '  It is ALSO what a truncated or mistyped id produces, and the two are\n' >&2
            printf '  indistinguishable from the record — which is why both are reported. If\n' >&2
            printf '  you meant to clear an OUTSTANDING wait, the id below is not the one on\n' >&2
            printf '  record and the next emit will name the real one again.\n' >&2
            printf '  rc 4 is NOT a failure. Do not chain this verb with `&&`, and do not run\n' >&2
            printf '  it under `set -e` without handling 4 — the pre-arm path is normal use.\n' >&2
            _dnw_show_ledger external_waits "$existing"
            exit 4
        fi
        ;;
esac

exit 0
