#!/usr/bin/env bash
# monitor/window-session-id.sh — resolve a worker window's Claude Code
# session-id, WITHOUT deriving a project slug from its workdir.
#
# your-org/nexus-code#647. `skills/nexus.window-cleanup/SKILL.md` told the
# orchestrator to derive the slug by hand:
#
#     SLUG=$(printf '%s' "$WORKDIR" | sed 's|/|-|g')
#     JSONL=$(ls -t "$HOME/.claude/projects/$SLUG/"*.jsonl 2>/dev/null | head -1)
#
# Claude Code maps `_` to `-` as well as `/`. EVERY workdir on this host
# contains `your-lab-m`, so that derivation named a directory that does not
# exist — for every window, always. `ls` failed, `2>/dev/null` hid it,
# SESSION_ID came out empty, and the `window-close` log recorded
# `session-id=unknown`. That log entry is what `ng respawn` reads, and the
# skill calls it "the only way to reconstruct them later" — so the
# documented last-resort resume surface was silently unavailable for every
# window ever retired by the documented procedure.
#
# THE FIX IS NOT A BETTER SED. Adding `_` to the transform would work
# today and break on the next character Claude Code decides to map — the
# same fork-fragile derivation as #638, one character further along. The
# session-id is RECORDED at spawn time; read it.
#
# Sources, in order, each a recorded fact rather than a reconstruction:
#   1. monitor/.state/windows/<window>.json  .session_id
#      Written by spawn-worker.sh at spawn. Authoritative for this
#      window's current life, and survives the agent exiting — which is
#      exactly the retirement case this exists for.
#   2. monitor/.state/heartbeat/<window>.json  .session_id
#      Written by the live agent's hooks. Fallback for a window whose
#      spawn record predates this field or was pruned.
#
# FAILS LOUD (exit 3), never prints `unknown`. A caller that cannot get a
# session-id must find out at the call site, not discover a plausible
# placeholder in a log three days later. That silent-`unknown` shape is
# the whole defect.
#
# Usage:
#   monitor/window-session-id.sh <window> [--verify]
#     --verify  additionally require that a transcript file exists for the
#               resolved id, located by GLOB across the Claude Code homes
#               (projects/*/<sid>.jsonl) — no slug derivation anywhere.
#
# Exit: 0 resolved (id on stdout) | 2 usage | 3 not resolvable

set -uo pipefail

_wsi_say() { printf 'window-session-id: %s\n' "$*" >&2; }

WINDOW="${1:-}"
VERIFY=0
[ "${2:-}" = "--verify" ] && VERIFY=1
if [ -z "$WINDOW" ] || [ "$WINDOW" = "-h" ] || [ "$WINDOW" = "--help" ]; then
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    [ -z "$WINDOW" ] && exit 2 || exit 0
fi

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$_script_dir/.." && pwd)}"
STATE_DIR="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"

# NO HARD jq DEPENDENCY — and that is a decision, not an oversight
# (your-org/nexus-code#671 review). `test-guard-closure-boundary.sh` keeps a
# manifest of sites where an absent jq silently changes behaviour, and it
# caught the first version of this file joining them. The guard was right:
# a new jq dependency must be a conscious choice.
#
# The choice made here is to REMOVE it rather than to widen the manifest,
# because this is a RETIREMENT-path helper: it runs when a window is being
# closed, which is exactly when a degraded host is least able to absorb a
# tool that stops working. jq is used when present (correct parsing of the
# JSON these files really are) and a plain-text extraction is used when it
# is not.
#
# What makes the fallback SAFE rather than a fragile hand-rolled parse is
# the uuid gate below, which was already here for a different reason: any
# mis-parse yields something that is not a uuid, and a non-uuid is
# REFUSED, never echoed. So the failure mode of the fallback is exit 3
# with a diagnostic — the same fail-loud shape as no record at all — and
# never a wrong id laundered into a respawn.
_wsi_read() {  # <file> -> prints .session_id if it looks like one
    local f="$1" v
    [ -r "$f" ] || return 1
    v=""
    if command -v jq >/dev/null 2>&1; then
        v=$(jq -r '.session_id // empty' "$f" 2>/dev/null) || v=""
    fi
    # Fall back on an EMPTY RESULT, not merely on jq being absent: a jq
    # that is present but broken (wrong build, exec failure) otherwise
    # yields nothing and takes the whole lookup down with it, which is the
    # silent-degradation shape this file is trying not to have.
    if [ -z "$v" ]; then
        # First "session_id": "<value>". These files are machine-written
        # one-liners; anything this misreads fails the uuid gate below.
        v=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1) || v=""
    fi
    [ -n "$v" ] || return 1
    # A session-id is a uuid; anything else is a placeholder we must not
    # launder into an answer (`unknown` has been written into these files).
    case "$v" in
        [0-9a-fA-F]*-*-*-*-*) printf '%s' "$v"; return 0 ;;
    esac
    return 1
}

SID=""
SRC=""
if SID=$(_wsi_read "$STATE_DIR/windows/$WINDOW.json"); then
    SRC="windows/$WINDOW.json (spawn record)"
elif SID=$(_wsi_read "$STATE_DIR/heartbeat/$WINDOW.json"); then
    SRC="heartbeat/$WINDOW.json (live agent)"
fi

if [ -z "$SID" ]; then
    _wsi_say "no recorded session-id for window '$WINDOW'."
    _wsi_say "  looked in: $STATE_DIR/windows/$WINDOW.json, $STATE_DIR/heartbeat/$WINDOW.json"
    _wsi_say "  NOT falling back to a workdir-derived project slug: that derivation is what #647 is about."
    exit 3
fi

if [ "$VERIFY" = 1 ]; then
    # Locate the transcript by GLOB on the session-id, never by rebuilding
    # the slug. Same approach _submit_evidence.sh uses, and the reason it
    # works for a worker in work/<clone>, whose project dir differs from
    # the primary's.
    _found=""
    for _home in ${NEXUS_CC_HOME:+"$NEXUS_CC_HOME"} ${CLAUDE_CONFIG_DIR:+"$CLAUDE_CONFIG_DIR"} "$HOME/.claude"; do
        [ -d "$_home/projects" ] || continue
        for _p in "$_home"/projects/*/"$SID.jsonl"; do
            [ -f "$_p" ] || continue
            _found="$_p"; break
        done
        [ -n "$_found" ] && break
    done
    if [ -z "$_found" ]; then
        _wsi_say "session-id '$SID' resolved from $SRC, but NO transcript exists for it."
        _wsi_say "  searched projects/*/$SID.jsonl across the Claude Code homes (glob, not a derived slug)."
        exit 3
    fi
fi

printf '%s\n' "$SID"
