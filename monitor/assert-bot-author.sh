#!/usr/bin/env bash
# monitor/assert-bot-author.sh <github-url> — one-command identity check for
# a GitHub write you just made (your-org/nexus-code#497).
#
# WHY. GitHub mutes notifications for actions taken by the recipient's own
# account, so a write that authenticates as the OPERATOR succeeds and then
# silently never notifies them — nothing errors, the thread just goes dark.
# The PATH-front gh shim is supposed to make bare `gh` post as the bot, but
# that invariant has been observed broken on a live clone (five
# operator-authored writes in one day, #497/#474). Verification is the
# durable half: it holds whether or not the shim works, and it fails loud
# when the shim regresses. Workers: mint explicitly
# (`GH_TOKEN=$("$NEXUS_ROOT"/monitor/mint-token.sh) gh <write> …`), then run
# this on the write's URL.
#
# Accepts, in one argument:
#   * an issue-comment html URL   …github.com/o/r/(issues|pull)/N#issuecomment-<id>
#   * an issue / PR html URL      https://github.com/o/r/issues/42 | /pull/43
#   * an API URL or path          https://api.github.com/repos/… | repos/…
#
# Exit 0  — the resource's author is the configured bot (prints it).
# Exit 1  — authored by someone else (LOUD: names the author and the
#           operator-muting consequence).
# Exit 2  — could not check (bad URL, mint failure, API error). Treat as
#           unverified, not as OK.
#
# Env seams (tests): MINT_TOKEN_BIN overrides the token minter; NEXUS_CONFIG
# points config/load.sh at an alternate yaml.

set -uo pipefail

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_root=$(cd "$_dir/.." && pwd)

url="${1:?usage: assert-bot-author.sh <github-url-of-your-write>}"

api=""
case "$url" in
    https://api.github.com/*) api="${url#https://api.github.com/}" ;;
    repos/*)  api="$url" ;;
    /repos/*) api="${url#/}" ;;
    *'#issuecomment-'*)
        _base="${url%%#issuecomment-*}"
        _cid="${url##*#issuecomment-}"
        _or=$(sed -E 's#^https://github.com/([^/]+/[^/]+)/.*#\1#' <<<"$_base")
        [[ "$_or" != "$_base" && "$_cid" =~ ^[0-9]+$ ]] \
            && api="repos/$_or/issues/comments/$_cid"
        ;;
    https://github.com/*)
        # /issues/N and /pull/N both answer on the issues endpoint with .user.
        _or=$(sed -nE 's#^https://github.com/([^/]+/[^/]+)/(issues|pull)/([0-9]+).*#\1#p' <<<"$url")
        _n=$(sed -nE 's#^https://github.com/([^/]+/[^/]+)/(issues|pull)/([0-9]+).*#\3#p' <<<"$url")
        [[ -n "$_or" && -n "$_n" ]] && api="repos/$_or/issues/$_n"
        ;;
esac
if [[ -z "$api" ]]; then
    echo "assert-bot-author: cannot map '$url' to an API resource (want an issue/PR/comment URL or an api path)" >&2
    exit 2
fi

_mint="${MINT_TOKEN_BIN:-$_dir/mint-token.sh}"
_tok=$("$_mint" 2>/dev/null) || _tok=""
if [[ -z "$_tok" ]]; then
    echo "assert-bot-author: mint-token.sh produced no token — cannot verify (treat the write as UNVERIFIED)" >&2
    exit 2
fi

login=$(GH_TOKEN="$_tok" gh api "$api" --jq '.user.login // .author.login // empty' 2>/dev/null) || login=""
if [[ -z "$login" ]]; then
    echo "assert-bot-author: could not read author from $api (API error?) — treat the write as UNVERIFIED" >&2
    exit 2
fi

bot=$("$_root/config/load.sh" github.bot_login 2>/dev/null || true)
operator=$("$_root/config/load.sh" github.user_login 2>/dev/null || true)

# Exact match against the configured bot (with or without the [bot] suffix
# GitHub appends to App identities); generic [bot]-suffix fallback when the
# config key is absent (older forks).
if { [[ -n "$bot" ]] && { [[ "$login" == "$bot" ]] || [[ "$login" == "${bot}[bot]" ]]; }; } \
   || { [[ -z "$bot" ]] && [[ "$login" == *'[bot]' && "$login" != "$operator" ]]; }; then
    echo "assert-bot-author: OK — authored by $login"
    exit 0
fi

cat >&2 <<MSG
assert-bot-author: FAIL — '$api' is authored by '$login', not the bot${bot:+ ('$bot')}.
$( [[ -n "$operator" && "$login" == "$operator" ]] && echo "That is the OPERATOR: GitHub mutes self-authored notifications, so this write will NEVER notify them." )
Re-post it minted: GH_TOKEN=\$("$_dir/mint-token.sh") gh <write> …  (your-org/nexus-code#497)
MSG
exit 1
