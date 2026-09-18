#!/usr/bin/env bash
# obligations.sh — CLI over the obligation ledger (your-org/nexus-code#845).
#
# An OBLIGATION is a directed edge `DEBTOR owes(kind) CREDITOR` between two
# worker windows. It is the record that a pinned skeptic and its parked
# target have a LIVE DEPENDENCY — the fact that lived only in the
# orchestrator's head until it forgot it twice in one session. See
# monitor/_obligations.sh for the full rationale and the storage contract.
#
# Nothing here asks an agent to REMEMBER anything. The edges that matter are
# opened by the mechanisms that already know the linkage:
#
#   * `spawn-worker.sh --skeptic-role --skeptic-target T` opens
#     `<new skeptic> owes(skeptic-verdict) T` at the instant the reviewer
#     exists;
#   * `ng wrap-up` re-arming a require round REOPENS that edge against a
#     LIVE pinned skeptic and notifies it, so the target's push is
#     observable to its reviewer without either window pasting into the
#     other;
#   * `ng wrap-up --skeptic-role --skeptic-verdict …` settles it.
#
# and it is read by the mechanism that can act on it:
#
#   * `retire-preflight.sh` check 1d refuses to retire a window that is a
#     live DEBTOR.
#
# Subcommands:
#   open   --debtor W --creditor W --kind K [--round N] [--by TEXT] [--detail TEXT]
#          [--at <epoch>]          stamp opened_at with a supplied time —
#                                  for incident REPLAY and for BACKFILL of
#                                  pairs already live when this shipped
#   settle <id> --reason "<why>" [--by TEXT]
#   settle (--debtor W | --creditor W) [--kind K] --reason "<why>" [--by TEXT]
#          --debtor  discharges what W owes;  --creditor discharges every
#          reviewer of W (what `ng skeptic resolve W` means)
#   note   <id>|--debtor W --text "<what happened>"
#                                  append a ROUND event to the audit trail.
#                                  Records a delivered round WITHOUT ending
#                                  the pairing — the #845 correction.
#   state  <id>                    print the derived state + detail
#   show   <id>                    the full record, audit trail included
#   list   [--live|--all] [--debtor W] [--creditor W] [--kind K]
#   gate   <window>                rc 0 = nothing this window owes blocks
#                                  retiring it; rc 1 = it owes somebody
#   pairs                          every LIVE edge (who waits on whom)
#   preserve-closures --creditor W [--by TEXT]
#          settle every edge this creditor's DONE sentinel is ALREADY
#          releasing, so a teardown that destroys the sentinel cannot
#          silently revoke the release (#1270). Prints the ids it settled.
#
# Exit codes:
#   0  ok / gate clear
#   1  usage error, or `gate` found a blocking obligation
#   2  the ledger could not be read (state dir unusable) — DISTINCT from
#      "no obligations", because a gate that cannot read its ledger has not
#      established anything.
#
# State dir resolution mirrors ng / skeptic-channel.sh:
#   NEXUS_STATE_DIR → NEXUS_ROOT/monitor/.state → config nexus.root →
#   script-relative fallback.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die()  { printf 'obligations: %s\n' "$*" >&2; exit 1; }

# ARGUMENT-LOOP PROGRESS GUARD (your-org/nexus-code#924). Every argument loop
# below asserts that every iteration consumes at least one argument. Without it
# a value-taking flag given LAST spins forever — `shift 2` with `$#` == 1 is
# refused, so the arm re-matches — and a hang here is worse than an error
# because nothing on this board surfaces it. Full rationale: monitor/ng.
#
# Added at the B1 bundle seam: this file is NEW in `#845`, which branched before
# `#924`, so it joined the `ng` dispatch population unguarded. Its arms all use
# `shift 2 || die`, so none of them can spin TODAY — the guard is here because
# the invariant is structural, and the arm that regresses this is the next one
# somebody writes WITHOUT the `||`. Defined in-file rather than sourced, per
# `#924`'s design: a new mandatory `source` across the population turns one
# absent optional file into a total outage (the `#646` lesson).
_argloop_stuck() {
    printf '%s: option %s requires a value (argument loop made no progress)\n' \
        "${0##*/}" "${1-}" >&2
    exit 64
}
warn() { printf 'obligations: %s\n' "$*" >&2; }

if [[ -r "$_script_dir/_obligations.sh" ]]; then
    # shellcheck source=monitor/_obligations.sh
    source "$_script_dir/_obligations.sh"
else
    printf 'obligations: cannot source %s/_obligations.sh — refusing to answer\n' \
        "$_script_dir" >&2
    exit 2
fi

_resolve_state_dir() {
    if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then printf '%s' "$NEXUS_STATE_DIR"; return 0; fi
    if [[ -n "${NEXUS_ROOT:-}" ]]; then printf '%s/monitor/.state' "$NEXUS_ROOT"; return 0; fi
    local cfg_root=""
    if [[ -x "$_script_dir/../config/load.sh" ]]; then
        cfg_root=$("$_script_dir/../config/load.sh" nexus.root 2>/dev/null) || cfg_root=""
    fi
    if [[ -n "$cfg_root" ]]; then printf '%s/monitor/.state' "$cfg_root"; return 0; fi
    printf '%s/.state' "$_script_dir"
}
STATE_DIR="$(_resolve_state_dir)"
# HANDED DOWN (your-org/nexus-code#1335): `ng log-action` below reads
# NEXUS_STATE_DIR, not STATE_DIR, so a caller's --state-dir/NEXUS_STATE_DIR
# must reach it or the audit row lands in the PRIMARY's log.
export NEXUS_STATE_DIR="$STATE_DIR"

# Best-effort audit event. Never fatal: the ledger write is the record that
# matters and a missing `ng` must not turn a settlement into a failure.
_log() {
    [[ -x "$_script_dir/ng" ]] || return 0
    "$_script_dir/ng" log-action monitor "$@" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------

cmd_open() {
    local debtor="" creditor="" kind="skeptic-verdict" round="" by="" detail="" at=""
    _argloop_prev_1=-1; while (( $# > 0 )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
        case "$1" in
            --debtor)   debtor="${2:-}";   shift 2 || die "--debtor needs a value" ;;
            --creditor) creditor="${2:-}"; shift 2 || die "--creditor needs a value" ;;
            --kind)     kind="${2:-}";     shift 2 || die "--kind needs a value" ;;
            --round)    round="${2:-}";    shift 2 || die "--round needs a value" ;;
            --by)       by="${2:-}";       shift 2 || die "--by needs a value" ;;
            --detail)   detail="${2:-}";   shift 2 || die "--detail needs a value" ;;
            --at)       at="${2:-}";       shift 2 || die "--at needs an epoch" ;;
            *) die "unknown flag: $1" ;;
        esac
    done
    [[ -n "$debtor" && -n "$creditor" ]] \
        || die "usage: obligations.sh open --debtor <window> --creditor <window> [--kind K] [--round N] [--by T] [--detail T]"
    [[ -n "$by" ]] || by="obligations.sh open"
    local id
    # obl_open has already printed its refusal on stderr (see its header on
    # why it cannot use $OBL_ERR); do not print a second, emptier one over it.
    id=$(obl_open "$STATE_DIR" "$debtor" "$creditor" "$kind" "${round:-0}" "$by" "$detail" "$at") \
        || exit 1
    _log --event obligation-open \
        --extra "id=$id" --extra "debtor=$debtor" --extra "creditor=$creditor" \
        --extra "kind=$kind" --extra "round=${round:-0}" --extra "by=$by"
    printf '%s\n' "$id"
}

cmd_settle() {
    local id="" debtor="" creditor="" kind="" reason="" by=""
    _argloop_prev_2=-1; while (( $# > 0 )); do (( $# != _argloop_prev_2 )) || _argloop_stuck "$1"; _argloop_prev_2=$#
        case "$1" in
            --debtor)   debtor="${2:-}";   shift 2 || die "--debtor needs a value" ;;
            --creditor) creditor="${2:-}"; shift 2 || die "--creditor needs a value" ;;
            --kind)     kind="${2:-}";     shift 2 || die "--kind needs a value" ;;
            --reason)   reason="${2:-}";   shift 2 || die "--reason needs a value" ;;
            --by)       by="${2:-}";       shift 2 || die "--by needs a value" ;;
            -*) die "unknown flag: $1" ;;
            *)  [[ -z "$id" ]] || die "unexpected extra positional: $1"
                id="$1"; shift ;;
        esac
    done
    # The reason floor matches every other audited override in this repo
    # (`--skeptic-rearm`, `--not-a-skeptic-verdict`, `GH_IMPERSONATE_REASON`).
    # This settlement is the release valve on a gate that refuses
    # irreversible kills; an unexplained release is the `rm` the gate exists
    # to replace, wearing a verb.
    (( ${#reason} >= 20 )) \
        || die "settle requires --reason with a substantive explanation (>=20 chars) naming WHERE the owed work landed or WHY it is no longer owed. It is written to the audit trail and it releases a retirement gate."
    [[ -n "$by" ]] || by="obligations.sh settle"

    local -a ids=()
    if [[ -n "$id" ]]; then
        ids=("$id")
    else
        # EITHER end of the edge selects. `--debtor W` discharges what W
        # owes; `--creditor W` discharges every reviewer of W, which is what
        # an orchestrator `ng skeptic resolve W` means (#926 F5).
        [[ -n "$debtor" || -n "$creditor" ]] \
            || die "usage: obligations.sh settle <id> --reason \"…\"  |  settle (--debtor W | --creditor W) [--kind K] --reason \"…\""
        local _id _d _c _k
        while IFS= read -r _id; do
            [[ -n "$_id" ]] || continue
            if [[ -n "$debtor" ]]; then
                _d=$(obl_get "$STATE_DIR" "$_id" debtor)
                [[ "$_d" == "$debtor" ]] || continue
            fi
            if [[ -n "$creditor" ]]; then
                _c=$(obl_get "$STATE_DIR" "$_id" creditor)
                [[ "$_c" == "$creditor" ]] || continue
            fi
            if [[ -n "$kind" ]]; then
                _k=$(obl_get "$STATE_DIR" "$_id" kind)
                [[ "$_k" == "$kind" ]] || continue
            fi
            # Only settle what is still open. Re-settling a settled edge
            # would append a second, later settlement whose reason
            # overwrites the true one in the last-wins read.
            [[ -n "$(obl_get "$STATE_DIR" "$_id" settled_at)" ]] && continue
            ids+=("$_id")
        done < <(obl_ids "$STATE_DIR")
        if (( ${#ids[@]} == 0 )); then
            printf 'obligations: no OPEN obligation with %s%s%s\n' \
                "${debtor:+debtor=$debtor}" "${creditor:+ creditor=$creditor}" "${kind:+ kind=$kind}"
            return 0
        fi
    fi
    local one
    for one in "${ids[@]}"; do
        obl_settle "$STATE_DIR" "$one" "$by" "$reason" || die "$OBL_ERR"
        _log --event obligation-settle \
            --extra "id=$one" --extra "by=$by" --extra "reason=$reason"
        printf 'settled %s\n' "$one"
        _settle_channel_notice "$one"
    done
}

# ── SETTLING THE EDGE DOES NOT RELEASE THE COUNTERPART'S `await`
#    (your-org/nexus-code#1190) ─────────────────────────────────────────────
#
# `skeptic-channel.sh close` is the SOLE writer of the DONE sentinel — its own
# source says so ("`close` is the only writer of DONE") and a census of every
# use of the `_done_sentinel` accessor in production code finds exactly two
# sites, the writer in `close` and the reader in `await`. This file writes
# nothing under `skeptic/<task>/` at all.
#
# So `settle` cannot release a counterpart that is sitting in `await`, and the
# question "would settle alone have written the sentinel?" has one answer: no,
# by construction. That is worth stating in the output because the two verbs
# read as interchangeable at the point of use — both end an obligation, in
# different ledgers — and the operator who settles and walks away leaves the
# target looping until its timeout.
#
# `await` has one other release: the pending marker going from present to
# ABSENT gives exit 11 COUNTERPART-FINISHED. Settling does not touch that
# marker either. So this notice fires when the pairing still has a live release path
# waiting on somebody, and stays silent when it does not.
_settle_channel_notice() {
    local id="${1:-}" creditor="" chan="" marker=""
    [[ -n "$id" ]] || return 0
    creditor=$(obl_get "$STATE_DIR" "$id" creditor 2>/dev/null) || creditor=""
    [[ -n "$creditor" ]] || return 0
    # THE SKEPTIC STORE'S OWN ENCODER, not this file's (your-org/nexus-code#941,
    # missed site). `obl_safe` is lossy and `wk_encode` is injective; they agree
    # only inside `[A-Za-z0-9_-]`. Addressing another store with the wrong one
    # silently reads a directory that store never created — see `obl_chan_key`
    # in _obligations.sh for the measured disagreement and the consequence.
    chan="$STATE_DIR/skeptic/$(obl_chan_key "$creditor")"
    marker="$STATE_DIR/skeptic/pending/$(obl_chan_key "$creditor")"
    # Only claim the channel is open when the absence was POSITIVELY OBSERVED:
    # an unreadable channel dir is a failure to look, not a finding.
    [[ -d "$chan" && -r "$chan" ]] || return 0
    [[ -e "$chan/DONE" ]] && return 0
    printf 'obligations: NOTE — the EDGE is settled; %s'"'"'s CHANNEL is not.\n' "$creditor" >&2
    printf '  `skeptic-channel.sh close` is the only writer of the DONE sentinel, and this\n' >&2
    printf '  verb writes nothing under skeptic/%s/ — so if %s is sitting in\n' \
        "$(obl_chan_key "$creditor")" "$creditor" >&2
    printf '  `ng skeptic await`, settling the edge did NOT release it and it will loop to\n' >&2
    printf '  its timeout. End the pairing deliberately when the review is over:\n' >&2
    printf '      monitor/ng skeptic close %q\n' "$creditor" >&2
    if [[ -e "$marker" ]]; then
        printf '  (the skeptic-pending marker for %q is also still LIVE, so the retirement\n' "$creditor" >&2
        printf '   gate stays shut until a verdict clears it or `ng skeptic resolve` releases it)\n' >&2
    fi
    printf '  See your-org/nexus-code#1190.\n' >&2
}

cmd_note() {
    local id="" debtor="" creditor="" text=""
    _argloop_prev_3=-1; while (( $# > 0 )); do (( $# != _argloop_prev_3 )) || _argloop_stuck "$1"; _argloop_prev_3=$#
        case "$1" in
            --debtor)   debtor="${2:-}";   shift 2 || die "--debtor needs a value" ;;
            --creditor) creditor="${2:-}"; shift 2 || die "--creditor needs a value" ;;
            --text)     text="${2:-}";     shift 2 || die "--text needs a value" ;;
            -*) die "unknown flag: $1" ;;
            *)  [[ -z "$id" ]] || die "unexpected extra positional: $1"
                id="$1"; shift ;;
        esac
    done
    [[ -n "$text" ]] || die "note requires --text"
    local -a ids=()
    if [[ -n "$id" ]]; then
        ids=("$id")
    else
        [[ -n "$debtor" ]] || die "usage: obligations.sh note <id> --text \"…\"  |  note --debtor W [--creditor W] --text \"…\""
        local _id _d _c
        while IFS= read -r _id; do
            [[ -n "$_id" ]] || continue
            _d=$(obl_get "$STATE_DIR" "$_id" debtor)
            [[ "$_d" == "$debtor" ]] || continue
            if [[ -n "$creditor" ]]; then
                _c=$(obl_get "$STATE_DIR" "$_id" creditor)
                [[ "$_c" == "$creditor" ]] || continue
            fi
            ids+=("$_id")
        done < <(obl_ids "$STATE_DIR")
        (( ${#ids[@]} )) || { printf 'obligations: no obligation with debtor=%s\n' "$debtor"; return 0; }
    fi
    local one
    for one in "${ids[@]}"; do
        obl_note "$STATE_DIR" "$one" "$text" || die "$OBL_ERR"
        printf 'noted on %s\n' "$one"
    done
}

cmd_state() {
    local id="${1:-}"; [[ -n "$id" ]] || die "usage: obligations.sh state <id>"
    local st detail
    IFS=$'\t' read -r st detail <<<"$(obl_state "$STATE_DIR" "$id")"
    printf 'id=%s state=%s detail=%s\n' "$id" "$st" "$detail"
}

cmd_show() {
    local id="${1:-}"; [[ -n "$id" ]] || die "usage: obligations.sh show <id>"
    local f; f=$(obl_path "$STATE_DIR" "$id")
    [[ -r "$f" ]] || die "no such obligation: $id (looked at $f)"
    local st detail
    IFS=$'\t' read -r st detail <<<"$(obl_state "$STATE_DIR" "$id")"
    printf 'id       : %s\n' "$id"
    printf 'debtor   : %s  (owes)\n'   "$(obl_get "$STATE_DIR" "$id" debtor)"
    printf 'creditor : %s  (is owed)\n' "$(obl_get "$STATE_DIR" "$id" creditor)"
    printf 'kind     : %s\n' "$(obl_get "$STATE_DIR" "$id" kind)"
    printf 'round    : %s\n' "$(obl_get "$STATE_DIR" "$id" round)"
    printf 'state    : %s\n' "$st"
    printf 'detail   : %s\n' "$detail"
    printf -- '--- record (append-only; last value of a key wins) ---\n'
    sed 's/^/  /' "$f"
}

cmd_list() {
    local want_live=0 want_all=0 debtor="" creditor="" kind=""
    _argloop_prev_4=-1; while (( $# > 0 )); do (( $# != _argloop_prev_4 )) || _argloop_stuck "$1"; _argloop_prev_4=$#
        case "$1" in
            --live)     want_live=1; shift ;;
            --all)      want_all=1;  shift ;;
            --debtor)   debtor="${2:-}";   shift 2 || die "--debtor needs a value" ;;
            --creditor) creditor="${2:-}"; shift 2 || die "--creditor needs a value" ;;
            --kind)     kind="${2:-}";     shift 2 || die "--kind needs a value" ;;
            *) die "unknown flag: $1" ;;
        esac
    done
    (( want_all == 1 )) && want_live=0
    local id st _d_ignored d c k n=0
    printf '%-11s  %-18s  %-18s  %-16s  %s\n' STATE DEBTOR CREDITOR KIND ID
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        d=$(obl_get "$STATE_DIR" "$id" debtor)
        c=$(obl_get "$STATE_DIR" "$id" creditor)
        k=$(obl_get "$STATE_DIR" "$id" kind)
        [[ -n "$debtor"   && "$d" != "$debtor"   ]] && continue
        [[ -n "$creditor" && "$c" != "$creditor" ]] && continue
        [[ -n "$kind"     && "$k" != "$kind"     ]] && continue
        st=$(obl_state "$STATE_DIR" "$id" | cut -f1)
        (( want_live == 1 )) && [[ "$st" != "live" ]] && continue
        printf '%-11s  %-18s  %-18s  %-16s  %s\n' "$st" "$d" "$c" "$k" "$id"
        n=$(( n + 1 ))
    done < <(obl_ids "$STATE_DIR")
    printf '(%d row(s); ledger %s)\n' "$n" "$(obl_dir "$STATE_DIR")"
}

# gate <window> — the predicate retire-preflight consumes.
#
# rc 0: nothing this window OWES blocks retiring it.
# rc 1: it owes somebody. Every blocking edge is printed, with the state
#       that produced the block and the named release.
cmd_gate() {
    local window="${1:-}"; [[ -n "$window" ]] || die "usage: obligations.sh gate <window>"
    local rows; rows=$(obl_blocking_for_debtor "$STATE_DIR" "$window")
    if [[ -z "$rows" ]]; then
        printf 'gate=clear window=%s reason=no live obligation names this window as a debtor\n' "$window"
        return 0
    fi
    local id st creditor detail
    while IFS=$'\t' read -r id st creditor detail; do
        [[ -n "$id" ]] || continue
        printf 'gate=blocked window=%s owes=%s state=%s id=%s detail=%s\n' \
            "$window" "$creditor" "$st" "$id" "$detail"
    done <<<"$rows"
    return 1
}

# pairs — the operator-facing "who is waiting on whom" view.
cmd_pairs() {
    local rows; rows=$(obl_live_pairs "$STATE_DIR")
    if [[ -z "$rows" ]]; then
        printf 'no live obligations (ledger %s)\n' "$(obl_dir "$STATE_DIR")"
        return 0
    fi
    local id d c k r o now age
    now=$(date +%s)
    printf '%-18s  %-18s  %-16s  %-5s  %s\n' DEBTOR CREDITOR KIND ROUND AGE
    while IFS=$'\t' read -r id d c k r o; do
        [[ -n "$id" ]] || continue
        age="?"
        [[ "$o" =~ ^[0-9]+$ ]] && age="$(( (now - o) / 60 ))m"
        printf '%-18s  %-18s  %-16s  %-5s  %s\n' "$d" "$c" "$k" "$r" "$age"
    done <<<"$rows"
}

# preserve-closures --creditor W [--by T]
#
# Settle, DURABLY, every edge this creditor's DONE sentinel is currently
# releasing — so a teardown that destroys the sentinel cannot revoke the
# release. See obl_preserve_pairing_closures in _obligations.sh for the
# measured failure it prevents (your-org/nexus-code#1270 residual A).
#
# READS NOTHING IT DOES NOT ACT ON and acts on nothing that is not ALREADY
# releasing: an edge is touched only while `obl_state` says
# `void-pairing-closed` right now. Prints one settled id per line; prints
# nothing and exits 0 when there is nothing to preserve, because "this
# teardown revoked no release" is the common case and deserves no noise.
cmd_preserve_closures() {
    local creditor="" by="preserve-closures"
    _argloop_prev_9=-1; while (( $# > 0 )); do (( $# != _argloop_prev_9 )) || _argloop_stuck "$1"; _argloop_prev_9=$#
        case "$1" in
            --creditor) creditor="${2:-}"; shift 2 || die "--creditor needs a value" ;;
            --by)       by="${2:-}";       shift 2 || die "--by needs a value" ;;
            *) die "unknown flag: $1" ;;
        esac
    done
    [[ -n "$creditor" ]] \
        || die "usage: obligations.sh preserve-closures --creditor <window> [--by TEXT]"
    local ids; ids=$(obl_preserve_pairing_closures "$STATE_DIR" "$creditor" "$by") \
        || die "${OBL_ERR:-preserve-closures failed}"
    [[ -n "$ids" ]] || return 0
    printf '%s\n' "$ids"
    # `_log`, not a second logger: it is already the file's best-effort audit
    # helper and is already never-fatal. A teardown must not fail because a log
    # could not be written, and a second copy of that rule is how the two drift.
    local _pid
    while IFS= read -r _pid; do
        [[ -n "$_pid" ]] || continue
        _log --event skeptic-pairing-closure-preserved \
            --extra "id=$_pid" --extra "creditor=$creditor" --extra "by=$by"
    done <<<"$ids"
}

main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        open)   cmd_open   "$@" ;;
        settle) cmd_settle "$@" ;;
        note)   cmd_note   "$@" ;;
        state)  cmd_state  "$@" ;;
        show)   cmd_show   "$@" ;;
        list)   cmd_list   "$@" ;;
        gate)   cmd_gate   "$@" ;;
        pairs)  cmd_pairs  "$@" ;;
        preserve-closures) cmd_preserve_closures "$@" ;;
        -h|--help|"")
            awk '/^$/{exit} NR>1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            [[ -z "$sub" ]] && exit 1 || exit 0
            ;;
        *) die "unknown subcommand: $sub (run with --help)" ;;
    esac
}

main "$@"
