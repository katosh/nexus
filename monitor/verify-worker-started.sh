#!/usr/bin/env bash
# monitor/verify-worker-started.sh — after a spawn creates a window, establish
# that the worker actually REACHED A REPL, and say so loudly when it did not.
#
# WHY (your-org/nexus-code#1334): a worker blocked on Claude Code's
# workspace-trust dialog is a SILENT failure by construction. The seed reports
# success, the config reads `hasTrustDialogAccepted: true`, `tmux new-window`
# succeeds, and the pane sits on a prompt no automated caller can see. Every
# artefact says the spawn worked; the only evidence is an absence. This repo
# has a name for that — a manufactured success — and it is its dominant defect
# class.
#
# THREE DESIGN CONSTRAINTS, each of which this repo has already paid for:
#
#   1. ASK `pane-state.sh`, NEVER `tmux capture-pane`. Claude Code's autosuggest
#      renders identically to typed input in plain text, so eyeballing a capture
#      cannot tell a ghost from a person (#626).
#   2. `empty` MEANS "DON'T KNOW YET", NOT "FINE". A pane 4m38s into real work
#      read `empty` (#603); `unknown` is worse still — it means the pane could
#      not be READ AT ALL. A verifier that counts either as success manufactures
#      exactly the thing it exists to catch. So the decision is an ALLOWLIST of
#      states that POSITIVELY mean a REPL was reached, with a default-DENY arm.
#   3. A SLOW-BUT-HEALTHY SPAWN MUST NOT BECOME A FAILURE. On expiry this
#      reports what it OBSERVED (`state=… at Ns`) and never asserts a cause —
#      #1063: a line naming a cause instead of an observation sends two people
#      the wrong way.
#
# Exit: 0 started (positively established); 1 positively WEDGED (a state that
# asserts the worker is not going to proceed unaided); 2 usage; 3 REFUSED —
# could not establish either, which is NOT a failure claim. Three-valued on
# purpose: a two-valued predicate is read backwards by one of `until`/`while`.
set -uo pipefail

_vws_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PANE_STATE="${PANE_STATE_BIN:-$_vws_dir/pane-state.sh}"

TIMEOUT="${NEXUS_SPAWN_VERIFY_TIMEOUT:-90}"
INTERVAL="${NEXUS_SPAWN_VERIFY_INTERVAL:-3}"
WINDOW=""
WORKDIR_ARG=""

usage() {
    echo "usage: monitor/verify-worker-started.sh <window-key> [--workdir DIR] [--timeout N] [--interval S]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout)  TIMEOUT="${2:-}"; shift 2 || usage ;;
        --interval) INTERVAL="${2:-}"; shift 2 || usage ;;
        --workdir)  WORKDIR_ARG="${2:-}"; shift 2 || usage ;;
        -h|--help)  usage ;;
        -*)         echo "verify-worker-started: unknown option: $1" >&2; usage ;;
        *)          [ -z "$WINDOW" ] || usage; WINDOW="$1"; shift ;;
    esac
done
[ -n "$WINDOW" ] || usage
# Validate SHAPE, never emptiness: an emptiness check is a presence test
# wearing a validity test's name (#1203).
[[ "$TIMEOUT"  =~ ^[0-9]+$ ]] || { echo "verify-worker-started: --timeout must be an integer: $TIMEOUT" >&2; exit 2; }
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || { echo "verify-worker-started: --interval must be an integer: $INTERVAL" >&2; exit 2; }
[ "$INTERVAL" -gt 0 ] || { echo "verify-worker-started: --interval must be > 0" >&2; exit 2; }

# --- the vocabulary, PARTITIONED --------------------------------------------
# Equality over DISJOINT sets, so no arm can shadow another and the order of
# the tests below is irrelevant (#1121: the hazard lives where arms are
# PATTERNS; these are literal `==`).
# NOTE ON THROTTLING (your-org/nexus-code#1340, as `dev` solves it): a worker
# retrying under Claude Code's /low-priority mode is reported as `busy` with a
# `throttled=1` MODIFIER, not as a distinct state token — so `busy` below
# already covers it and no member is needed here. An earlier draft of this file
# carried a `working-throttled` member from a competing design that did not
# land; the partition check below REFUSED (rc 3) until it was removed, which is
# the arm working correctly in the opposite direction to the one it was written
# for.
_VWS_STARTED=(idle busy user-typing autosuggest-only
              working-background working-self-paced
              over-limit idle-orphan-async)
_VWS_WEDGED=(blocked absent)
_VWS_UNDECIDED=(empty unknown)

# A hand-written list beside a vocabulary that can GROW is two things to keep in
# sync, and this file forbids deciding from a hand-enumerated state list. So do
# not trust these three: ASK the tool and refuse if they no longer partition it.
_vws_assert_partition() {
    local declared mine s
    declared=$("$PANE_STATE" --states 2>/dev/null) || {
        echo "verify-worker-started: REFUSED — cannot read the state vocabulary from $PANE_STATE" >&2
        return 3; }
    [ -n "$declared" ] || {
        echo "verify-worker-started: REFUSED — $PANE_STATE --states returned nothing" >&2
        return 3; }
    mine=$(printf '%s\n' "${_VWS_STARTED[@]}" "${_VWS_WEDGED[@]}" "${_VWS_UNDECIDED[@]}" | sort -u)
    declared=$(printf '%s\n' "$declared" | sort -u)
    if [ "$mine" != "$declared" ]; then
        echo "verify-worker-started: REFUSED — the pane-state vocabulary has changed." >&2
        echo "  A state this script does not classify would fall to a default arm, which is" >&2
        echo "  how a denylist retires a live worker (your-org/nexus-code#1214). Classify it." >&2
        comm -3 <(printf '%s\n' "$mine") <(printf '%s\n' "$declared") \
            | sed 's/^\t/  ONLY IN pane-state.sh: /; s/^\([^ ]\)/  ONLY IN this script: \1/' >&2
        return 3
    fi
    return 0
}

# THE DISCRIMINATING MEASUREMENT, taken on the failure path where it is free
# (your-org/nexus-code#1334). The issue asks for the trust key read back BEFORE
# anything answers the dialog — which is exactly this moment. A forced
# reproduction would need ~17 spawns to see one blocked event at the observed
# 1-in-6 rate; this costs a healthy spawn nothing and answers on the next
# genuine occurrence:
#
#   ABSENT / false  => the key was CLOBBERED between seed and read.
#   true            => hasTrustDialogAccepted is not the only gating key.
#
# UNKNOWN IS A THIRD ANSWER AND MUST NEVER COLLAPSE INTO `false`. "Could not
# read" reported as absent is a fabricated clobber finding, and this whole
# issue already produced one false lead from exactly that confusion — querying
# ~/.claude.json while CLAUDE_CONFIG_DIR was set returns ABSENT for every
# workdir and reads like a seed that never wrote. So resolve the config the way
# ensure-workdir-trusted.sh's _ewt_config_file() does, and print the resolved
# PATH beside the value so a reader can re-run it.
_vws_trust_readback() {
    local dir="$1" cfg abs val
    cfg="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
    printf '  trust key read back BEFORE anything answered the dialog:\n' >&2
    printf '    config: %s\n' "$cfg" >&2
    if [ ! -e "$cfg" ]; then
        printf '    value:  UNKNOWN (config file does not exist)\n' >&2; return 0; fi
    if [ ! -r "$cfg" ]; then
        printf '    value:  UNKNOWN (config file not readable)\n' >&2; return 0; fi
    if ! command -v jq >/dev/null 2>&1; then
        printf '    value:  UNKNOWN (jq not on PATH — cannot parse)\n' >&2; return 0; fi
    if ! jq -e . "$cfg" >/dev/null 2>&1; then
        printf '    value:  UNKNOWN (config is not valid JSON)\n' >&2; return 0; fi
    # The seeder keys on the CANONICAL path (`cd … && pwd -P`); match it, or a
    # symlinked workdir reads ABSENT for a key that is really there.
    abs=$(CDPATH= cd "$dir" 2>/dev/null && pwd -P) || abs="$dir"
    val=$(jq -r --arg d "$abs" '.projects[$d].hasTrustDialogAccepted // "ABSENT"' "$cfg" 2>/dev/null)
    [ -n "$val" ] || val="UNKNOWN (jq produced no output)"
    printf '    key:    %s\n' "$abs" >&2
    printf '    value:  %s\n' "$val" >&2
    case "$val" in
        ABSENT|false)
            printf '    => the key is NOT set at the moment the dialog is up. Consistent with a\n' >&2
            printf '       CLOBBER between seed and read. RECORD THIS on your-org/nexus-code#1334.\n' >&2 ;;
        true)
            printf '    => the key IS set and the dialog appeared anyway. Consistent with\n' >&2
            printf '       hasTrustDialogAccepted NOT being the only gating key. RECORD THIS on #1334.\n' >&2 ;;
        *)
            printf '    => UNDETERMINED. This is NOT evidence either way; it means the read failed.\n' >&2 ;;
    esac
    return 0
}

_vws_in() {
    local needle="$1"; shift
    local s
    for s in "$@"; do [ "$s" = "$needle" ] && return 0; done
    return 1
}

_vws_assert_partition || exit 3

deadline=$(( SECONDS + TIMEOUT ))
last_line=""
last_state=""
while :; do
    last_line=$("$PANE_STATE" "$WINDOW" 2>/dev/null)
    last_state=$(printf '%s\n' "$last_line" | tr ' ' '\n' | sed -n 's/^state=//p' | head -1)
    [ -n "$last_state" ] || last_state="unknown"

    if _vws_in "$last_state" "${_VWS_STARTED[@]}"; then
        exit 0
    fi
    if _vws_in "$last_state" "${_VWS_WEDGED[@]}"; then
        # POSITIVELY established: this pane is not going to proceed unaided.
        echo "spawn-worker: WORKER DID NOT START — window '$WINDOW' is $last_state after $(( SECONDS - (deadline - TIMEOUT) ))s." >&2
        echo "  observed: $last_line" >&2
        case "$last_line" in
            *workspace-trust*)
                echo "  The pane is on Claude Code's workspace-trust dialog. The trust entry was" >&2
                echo "  seeded and reported success, so this is your-org/nexus-code#1334: either the" >&2
                echo "  key was clobbered by a concurrent writer of .claude.json, or" >&2
                echo "  hasTrustDialogAccepted is not the only key gating the dialog. THIS LINE" >&2
                echo "  NAMES THE OBSERVATION, NOT THE CAUSE — both remain open on #1334." >&2
                [ -n "$WORKDIR_ARG" ] && _vws_trust_readback "$WORKDIR_ARG" ;;
        esac
        echo "  The window still exists; nothing has been killed." >&2
        exit 1
    fi
    # Anything else — including `empty`/`unknown` and any state a future
    # pane-state.sh adds — is UNDECIDED. Keep waiting; never call it success.
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep "$INTERVAL"
done

echo "spawn-worker: could not establish that the worker in '$WINDOW' started within ${TIMEOUT}s." >&2
echo "  observed: ${last_line:-<no output from pane-state.sh>}" >&2
echo "  state=$last_state is NOT a failure — it means UNDECIDED ('empty' is \"don't know yet\"," >&2
echo "  'unknown' is \"could not look\"). A slow-but-healthy boot reads exactly like this." >&2
echo "  Check the window before acting; nothing has been killed." >&2
exit 3
