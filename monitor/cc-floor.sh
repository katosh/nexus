#!/usr/bin/env bash
# monitor/cc-floor.sh — make the shared Claude Code FLOOR (package.json) track
# the cc version this nexus runs AND has gate-verified (your-org/nexus-code#1657).
#
# Operator, 2026-09-27: "whenever we make an update to dev, we should make the
# current cc the new floor so when an agent updates another users nexus-code,
# they know they can update cc at the next convenience."
#
# THE TWO TIERS (monitor/_cc-version.sh): each operator runs its LOCAL pin
# (gitignored, advanced by the gated routine); package.json carries a shared
# FLOOR for fresh installs. The floor had not moved since 2.1.173 (June) while
# the routine verified two months of releases. This script closes that gap:
#
#   verified   print the version that is (a) this clone's effective pin,
#              (b) what the live binary reports, and (c) was applied by the
#              gated routine (a `safe-bumped*` row for it in decisions.tsv, i.e.
#              it passed the gate). rc 0; rc 3 with a reason when any of the
#              three does not hold — ONLY a gate-verified version is ever
#              proposed.
#   status     verified vs the floor on <base> at the remote (read via the API,
#              never a checkout). rc 0.
#   propose    if verified > floor on <base>, open ONE bot PR against <base>
#              raising the floor to it (branch `cc-floor/<version>`), closing
#              older `cc-floor/*` PRs as superseded. Never lowers; idempotent
#              (an open PR for the same version is reused). rc 0 proposed or
#              already open · 3 nothing to do (floor current / not verified /
#              disabled) · 1 an API step failed (named on stderr).
#              --if-base-moved: only act when <base>'s tip OR the verified
#              version differs from the pair recorded at the last check (the
#              "a change landed on dev / a new cc was verified" hook the
#              watcher tick uses); --dry-run: print, write nothing.
#
# WHAT THIS DOES NOT DO (your-org/nexus-code#1529): it never pulls, checks out,
# clones or executes any nexus-code tree. Every read of the remote is a GitHub
# API GET; every write is a bot-authored API call on a `cc-floor/*` branch and
# a PR, which a human or the orchestrator merges like any other.
#
# Seams (tests): CC_FLOOR_GH (gh), CC_FLOOR_MINT (mint-token.sh),
# CC_FLOOR_CLAUDE_BIN (node_modules/.bin/claude), NEXUS_STATE_DIR.
# Knob: monitor.cc_auto_update.floor_propose (default true) /
# MONITOR_CC_FLOOR_PROPOSE.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$_self_dir/.." && pwd)}"
STATE_DIR="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"
AUTO_DIR="$STATE_DIR/cc-auto-update"
PACKAGE="${MONITOR_CC_UPDATE_PACKAGE:-@anthropic-ai/claude-code}"
REPO="${CC_FLOOR_REPO:-your-org/nexus-code}"
BASE="${CC_FLOOR_BASE:-}"
GH="${CC_FLOOR_GH:-gh}"
MINT="${CC_FLOOR_MINT:-$NEXUS_ROOT/monitor/mint-token.sh}"
CLAUDE_BIN="${CC_FLOOR_CLAUDE_BIN:-$NEXUS_ROOT/node_modules/.bin/claude}"

# shellcheck source=_cc-version.sh
source "$_self_dir/_cc-version.sh"

die()  { printf 'cc-floor: %s\n' "$*" >&2; exit 1; }
say()  { printf 'cc-floor: %s\n' "$*"; }
_row() {  # audit row in the cc-auto-update ledger, same shape as the routine's
    mkdir -p "$AUTO_DIR" 2>/dev/null || return 0
    printf '%s\t%s\t%s\t%s\n' "$(date -Is 2>/dev/null || echo unknown)" "$1" "$2" "$3" \
        >> "$AUTO_DIR/decisions.tsv" 2>/dev/null || true
}

# _ver_gt A B — rc 0 iff A > B (numeric dotted compare; no pre-release tags).
_ver_gt() {
    [[ "$1" == "$2" ]] && return 1
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}
_is_ver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

_base() {
    [[ -n "$BASE" ]] && { printf '%s\n' "$BASE"; return; }
    if [[ -r "$NEXUS_ROOT/monitor/_integration_branch.sh" ]]; then
        # shellcheck source=_integration_branch.sh
        source "$NEXUS_ROOT/monitor/_integration_branch.sh"
        nexus_integration_branch 2>/dev/null && return
    fi
    printf 'dev\n'
}

cmd_verified() {
    local eff src live
    eff=$(cc_version_effective "$NEXUS_ROOT/package.json" "$PACKAGE" "$NEXUS_ROOT" 2>/dev/null) || eff=""
    _is_ver "$eff" || { say "not verified: effective version unresolvable ('$eff')"; return 3; }
    src=$(cc_version_effective_source "$NEXUS_ROOT/package.json" "$PACKAGE" "$NEXUS_ROOT" 2>/dev/null) || src=""
    live=$("$CLAUDE_BIN" --version 2>/dev/null | awk 'NR==1{print $1}')
    [[ "$live" == "$eff" ]] || { say "not verified: live binary reports '${live:-unreadable}', effective pin is $eff"; return 3; }
    if [[ "$src" == "floor" ]]; then
        # Running the floor itself: nothing newer to propose.
        say "not verified beyond the floor: this clone runs the floor ($eff)"; return 3
    fi
    if ! awk -F'\t' -v v="$eff" '$2==v && $3 ~ /^safe-bumped/ {f=1} END{exit !f}' "$AUTO_DIR/decisions.tsv" 2>/dev/null; then
        say "not verified: no gated apply (safe-bumped*) of $eff in $AUTO_DIR/decisions.tsv"; return 3
    fi
    printf '%s\n' "$eff"
}

_token() { "$MINT" 2>/dev/null; }

# _floor_prs_for_branch <branch> <jq> — every PR whose HEAD is <branch>, in any
# state, queried directly rather than read out of a windowed list.
_floor_prs_for_branch() {
    _gh api "repos/$REPO/pulls?state=all&head=${REPO%%/*}:$1&per_page=100" --jq "$2"
}

# _gh <args> — gh with the bot token; stdout is the API response.
_gh() { GH_TOKEN="$_TOK" "$GH" "$@"; }

_remote_floor() {   # <base> → prints "floor<TAB>blob_sha<TAB>content_b64" of package.json
    local b="$1" js
    js=$(_gh api "repos/$REPO/contents/package.json?ref=$b") || return 1
    local sha content
    sha=$(jq -r '.sha' <<<"$js") || return 1
    content=$(jq -r '.content' <<<"$js" | tr -d '\n') || return 1
    local floor
    floor=$(printf '%s' "$content" | base64 -d 2>/dev/null \
        | awk -F'"' -v pkg="$PACKAGE" '!done { for (i=1; i+2<=NF; i++) if ($i==pkg) { print $(i+2); done=1; break } }')
    _is_ver "$floor" || return 1
    printf '%s\t%s\t%s\n' "$floor" "$sha" "$content"
}

cmd_status() {
    local v rc=0 b; b=$(_base)
    v=$(cmd_verified) || rc=$?
    _TOK=$(_token) || _TOK=""
    local rf; rf=$(_remote_floor "$b" 2>/dev/null) || rf=""
    say "verified=${v:-none} floor@$REPO:$b=${rf%%$'\t'*}"
    return 0
}

cmd_propose() {
    local dry=0 if_moved=0
    while (( $# > 0 )); do
        case "$1" in
            --dry-run) dry=1; shift ;;
            --if-base-moved) if_moved=1; shift ;;
            *) die "propose: unknown arg $1" ;;
        esac
    done
    local knob="${MONITOR_CC_FLOOR_PROPOSE:-$("$NEXUS_ROOT/config/load.sh" monitor.cc_auto_update.floor_propose true 2>/dev/null || echo true)}"
    case "$knob" in false|0|no|off|FALSE|NO|OFF) say "disabled (monitor.cc_auto_update.floor_propose=$knob)"; return 3 ;; esac
    command -v jq >/dev/null 2>&1 || die "jq required"

    local v; v=$(cmd_verified) || return 3
    local b; b=$(_base)
    _TOK=$(_token) || die "could not mint the bot token ($MINT)"
    [[ -n "$_TOK" ]] || die "bot token empty"

    local base_sha
    base_sha=$(_gh api "repos/$REPO/git/ref/heads/$b" --jq '.object.sha') || die "could not read $REPO:$b"
    [[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || die "bad base sha for $b: '$base_sha'"
    local stamp="$AUTO_DIR/cc-floor-last-base"
    if (( if_moved )); then
        local last=""; [[ -f "$stamp" ]] && last=$(tr -d '[:space:]' < "$stamp")
        if [[ "$last" == "$b@$base_sha@$v" ]]; then say "neither $b ($base_sha) nor the verified version ($v) changed since the last check"; return 3; fi
    fi
    # Stamped only on an outcome that SETTLES the pair (floor current, PR open
    # or opened); a failed API step leaves it unstamped so the next hourly
    # check retries.
    _settle() { (( dry )) || { mkdir -p "$AUTO_DIR" 2>/dev/null; printf '%s\n' "$b@$base_sha@$v" > "$stamp" 2>/dev/null || true; }; }

    local rf floor blob content
    rf=$(_remote_floor "$b") || die "could not read the floor from $REPO:$b/package.json"
    IFS=$'\t' read -r floor blob content <<<"$rf"
    if ! _ver_gt "$v" "$floor"; then
        say "floor on $b is $floor, verified is $v — nothing to raise (never lowered)"; _settle; return 3
    fi

    local branch="cc-floor/$v" all
    # `merged_at` is carried as `-` when null: `read` with a TAB IFS collapses
    # an EMPTY field, which shifted the URL into it and emptied every list.
    # EVERY cc-floor PR, open AND closed (your-org/nexus-code#1657 round 2, F5):
    # the open ones decide supersede/stand-down; a CLOSED-UNMERGED one for this
    # exact version means a human declined it, and it is never re-opened.
    # BY HEAD BRANCH, never one windowed list (your-org/nexus-code#1657
    # follow-up): `pulls?state=all&per_page=100` is the 100 most recently
    # CREATED PRs, so a declined or closed cc-floor PR ages out of it as dev
    # keeps merging and the never-re-open guard goes blind. THIS version's
    # branch is queried directly, every state; the other floor proposals that
    # matter (supersede / stand-down) are OPEN ones, listed from the open set.
    local jqf='.[] | select(.head.ref | startswith("cc-floor/")) | "\(.number)\t\(.head.ref)\t\(.state)\t\(.merged_at // "-")\t\(.html_url)"'
    local mine openp
    mine=$(_floor_prs_for_branch "$branch" "$jqf") || die "could not list $branch PRs on $REPO"
    openp=$(_gh api "repos/$REPO/pulls?state=open&base=$b&per_page=100" --jq "$jqf") \
        || die "could not list open cc-floor PRs on $REPO"
    all=$(printf '%s\n%s\n' "$mine" "$openp" | awk 'NF && !seen[$1]++')
    local n ref st mg u pv existing="" declined="" higher="" lower=""
    while IFS=$'\t' read -r n ref st mg u; do
        [[ -n "$n" ]] || continue
        pv="${ref#cc-floor/}"; _is_ver "$pv" || continue
        if [[ "$st" == open ]]; then
            if   [[ "$pv" == "$v" ]]; then existing="$u"
            elif _ver_gt "$pv" "$v"; then higher="${higher:+$higher }$u"
            else lower="${lower:+$lower }$n|$u"; fi
        elif [[ "$pv" == "$v" && ( -z "$mg" || "$mg" == - ) ]]; then
            declined="$u"
        fi
    done <<<"$all"
    # A HIGHER proposal is already open: ours is not needed, and we never close
    # it (two operators on different verified versions must not ping-pong).
    if [[ -n "$higher" ]]; then
        say "a HIGHER floor proposal is already open ($higher) — standing down for $v"; _settle; return 3
    fi
    if [[ -n "$existing" ]]; then
        say "already proposed: $existing"; _supersede_lower; _settle; return 0
    fi
    if [[ -n "$declined" ]]; then
        say "a floor PR for $v was CLOSED unmerged ($declined) — a human declined it; not re-opening"; _settle; return 3
    fi
    if (( dry )); then
        say "DRY RUN: would open $branch on $REPO raising the floor $floor -> $v (base $b@${base_sha:0:8}); would supersede (lower only): ${lower:-none}"
        return 0
    fi

    # The branch may exist from a run cut off between the commit and the PR
    # (the watcher bounds this call with a timeout): RESUME it — read
    # package.json AT THE BRANCH and write only if it does not already carry
    # $v, with the BRANCH's blob sha (the base's sha 409s there).
    local br_blob="$blob" br_content="$content" br_floor="$floor"
    if _gh api "repos/$REPO/git/ref/heads/$branch" >/dev/null 2>&1; then
        local brf; brf=$(_remote_floor "$branch") || die "branch $branch exists but its package.json is unreadable"
        IFS=$'\t' read -r br_floor br_blob br_content <<<"$brf"
    else
        _gh api -X POST "repos/$REPO/git/refs" -f ref="refs/heads/$branch" -f sha="$base_sha" >/dev/null \
            || die "could not create branch $branch"
    fi
    local msg="cc floor: $floor -> $v (gate-verified on the operator's nexus)"
    if [[ "$br_floor" != "$v" ]]; then
        local newc
        newc=$(printf '%s' "$br_content" | base64 -d \
            | sed "s|\"$PACKAGE\": \"$br_floor\"|\"$PACKAGE\": \"$v\"|" | base64 -w0) || die "could not rewrite package.json"
        [[ "$newc" != "$br_content" ]] || die "rewrite changed nothing (floor line not found in the expected shape)"
        _gh api -X PUT "repos/$REPO/contents/package.json" -f message="$msg" -f content="$newc" \
            -f sha="$br_blob" -f branch="$branch" >/dev/null || die "could not commit package.json on $branch"
    fi
    local body
    body="Raises the shared Claude Code floor in \`package.json\` from **$floor** to **$v**.

$v is the version this nexus runs and that the gated cc-update routine applied (a \`safe-bumped*\` apply in its decision ledger). That apply may have proceeded on a gate RED the installed version shared, or with a recorded changelog gap; both are rows in the ledger. Per the operator's policy on your-org/nexus-code#1657, the floor tracks the verified cc so that anyone pulling \`$b\` knows $v is safe to update to at their next convenience. The floor is never lowered, and only LOWER floor proposals are superseded.

Opened automatically by \`monitor/cc-floor.sh propose\`. No other file changes."
    local url
    url=$(_gh api -X POST "repos/$REPO/pulls" -f title="$msg" -f head="$branch" -f base="$b" -f body="$body" --jq '.html_url') \
        || die "could not open the PR for $branch"
    say "proposed: $url"
    _row "$v" "cc-floor-proposed" "floor=$floor base=$b@${base_sha:0:12} pr=$url"
    [[ -x "$NEXUS_ROOT/monitor/assert-bot-author.sh" && -z "${CC_FLOOR_GH:-}" ]] \
        && { "$NEXUS_ROOT/monitor/assert-bot-author.sh" "$url" >/dev/null 2>&1 || say "WARN: assert-bot-author did not confirm $url"; }
    existing="$url"
    _supersede_lower
    _settle
    return 0
}

# _supersede_lower — close every open cc-floor PR for a STRICTLY LOWER version
# (parsed from its branch), pointing at $existing. Never a higher or equal one.
# Reads the caller's $lower / $existing / $v (dynamic scope).
_supersede_lower() {
    local item n u
    for item in $lower; do
        n="${item%%|*}"; u="${item#*|}"
        _gh api -X POST "repos/$REPO/issues/$n/comments" -f body="Superseded by $existing (floor -> $v)." >/dev/null 2>&1 || true
        _gh api -X PATCH "repos/$REPO/pulls/$n" -f state=closed >/dev/null 2>&1 || true
        _row "$v" "cc-floor-superseded" "pr=$u by=$existing"
    done
}

verb="${1:-}"; shift || true
case "$verb" in
    verified) cmd_verified "$@" ;;
    status)   cmd_status "$@" ;;
    propose)  cmd_propose "$@" ;;
    -h|--help|"") sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown verb: $verb (verified|status|propose)" ;;
esac
