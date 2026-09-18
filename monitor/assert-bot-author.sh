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
# Exit 2  — could not check (bad URL, mint failure, API error, OR the config
#           reader could not yield the expected bot identity). Treat as
#           unverified, not as OK. NOTE the last one: a failing config reader
#           used to be indistinguishable from an absent key and silently
#           relaxed this to "any [bot] account" (your-org/nexus-code#1267).
#           The rule now is that emptiness never stands in for validity — the
#           reader's EXIT CODE decides.
#
# THE GENERIC "any [bot] account" CHECK IS OPT-IN (your-org/nexus-code#1307).
# `config/load.sh` cannot distinguish a key that is genuinely ABSENT from one
# that is MISTYPED — `bot_logn:` and no `bot_login:` at all are the SAME rc 2,
# the same empty stdout, the same everything. #1267 made the reader's rc decide
# and that was right, but rc 2 was left LICENSING the permissive arm, so one
# transposed character in a config selected "any [bot] passes" and a write
# authored by a DIFFERENT GitHub App printed OK at rc 0. A silent fail-OPEN on
# the workspace's only loud identity check.
#
# No logic here can tell a typo from an absence — that information is not in
# the data. So the permissive mode requires a POSITIVE declaration,
#
#     github:
#       bot_login_absent_ok: true      # this fork genuinely has no bot_login
#
# and without one — key absent, empty, false, misspelled, reader failed — this
# check REFUSES with exit 2. Only the permissive PASS is gated. Every FAIL stays
# a FAIL: an operator-authored write, and any non-App author, are still exit 1
# with the muting diagnosis, whether or not anything is declared.
#
# TWO CLAIMS THAT USED TO SIT HERE WERE FALSE, and both were found by the #1307
# skeptic pass. They are corrected rather than deleted, because the wrong
# versions are the ones a fork operator would have relied on.
#
#   * IT SAID the permissive mode is "no longer reachable by ACCIDENT at all".
#     IT IS, in exactly one shape — and it is the shape this key invites.
#     Declare `bot_login_absent_ok: true` AND mistype `bot_logn:`, and a write
#     by a DIFFERENT App prints OK at rc 0: the unmodified #1307 failure. The
#     polarity argument below is true and does not cover it, because THE TYPO IS
#     IN THE OTHER KEY. The declaration is sticky and load-bearing forever after,
#     so a fork that legitimately declares "I have no bot", later adds one, and
#     mistypes it gets the fail-open back with no warning. The NEAR-MISS GUARD
#     below narrows that: with the opt-in honoured, a `github.*` key whose name
#     carries the `bot_log` stem but is neither `bot_login` nor
#     `bot_login_absent_ok` REFUSES and is NAMED. Its bound, stated because the
#     last absolute sentence here was wrong: it catches misspellings that PRESERVE
#     that stem (`bot_logn`, `bot_loginn`, `bot_log1n`); a misspelling that
#     destroys it (`bto_login`) is still indistinguishable from absence, and the
#     only fix for that class is in config/load.sh (#1307 remedies 2 and 3).
#
#   * IT SAID "only the exact value 'true' opts in — one accepted spelling is one
#     thing to get wrong". MEASURED against the real reader, NINE spellings are
#     accepted: `true True TRUE yes Yes YES on On` and the quoted `"true"`. The
#     reader normalises YAML 1.1 booleans and stringifies them lowercase, so
#     every boolean-true spelling arrives here as `true` and this script cannot
#     see which was written. `y`/`Y`, `1`, and the quoted `"True"`/`"yes"` do NOT
#     normalise and are refused, as are `false`/`no`. So the load-bearing
#     property is intact — a POSITIVE, EXPLICIT declaration is required, and no
#     absence or negation reaches the permissive arm — but the "one spelling"
#     argument was decoration and it was wrong.
#
# The polarity that DOES hold: a typo in the OPT-IN key's own name yields rc 2
# and REFUSES, so misspelling the fix makes this check stricter, never looser.
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

# READ THE RC, NEVER THE EMPTINESS (your-org/nexus-code#1267).
#
# `config/load.sh` distinguishes outcomes that ALL print nothing on stdout,
# and `… 2>/dev/null || true` collapsed every one of them to the empty
# string — then `[[ -z "$bot" ]]` read that emptiness as "the key is absent
# (older forks)" and relaxed this check to "any `[bot]` account". An
# emptiness test standing in for a validity test: a FAILING config reader
# silently downgraded the workspace's ONLY loud identity check, and the
# `2>/dev/null` destroyed the diagnostic that would have said so.
#
#   rc 0  value printed              — configured
#   rc 2  key not found, no default  — genuinely absent
#   rc 1  no config file / usage     — READER FAILED
#   rc 3  python3 / pyyaml missing   — READER FAILED
#   anything else                    — READER FAILED (fail closed on the unknown)
#
# ONLY rc 2 licenses the permissive fallback. "Could not determine the
# expected identity" is exit 2 UNVERIFIED — the arm this script already
# documents and which was unreachable on this path — never a licence to
# relax. Fail CLOSED and LOUD, and carry load.sh's own diagnostic out.
_CFG_VAL=""; _CFG_ERR=""
_cfg_read() {   # <key>; sets _CFG_VAL/_CFG_ERR. rc 0 configured | 2 absent | 3 READER FAILED
    # NOT `_CFG_VAL=$(_cfg_read …)`: a command substitution runs the function
    # in a SUBSHELL, so the diagnostic assigned to _CFG_ERR would never reach
    # the caller — the same silence this block exists to remove. Measured.
    local _k="$1" _rc _errf
    _CFG_VAL=""; _CFG_ERR=""
    _errf=$(mktemp "${TMPDIR:-/tmp}/aba-cfg.XXXXXX") || { _CFG_ERR="mktemp failed"; return 3; }
    _CFG_VAL=$("$_root/config/load.sh" "$_k" 2>"$_errf")
    _rc=$?                       # the VERY next line: anything between is a write to $?
    _CFG_ERR=$(cat "$_errf" 2>/dev/null)
    rm -f "$_errf"
    case "$_rc" in
        0) return 0 ;;
        2) return 2 ;;
        *) _CFG_ERR="${_CFG_ERR:-(no diagnostic)} [config/load.sh exited $_rc]"; return 3 ;;
    esac
}
_unverified() {   # <what> <why> — the exit-2 arm, named so every caller reads alike
    echo "assert-bot-author: cannot determine the expected bot identity — $1" >&2
    [[ -n "$2" ]] && echo "  config/load.sh said: $2" >&2
    echo "  REFUSING to fall back to an 'any [bot] account' check: that would pass a write" >&2
    echo "  authored by a DIFFERENT GitHub App. Treat the write as UNVERIFIED (#1267)." >&2
    exit 2
}

_github_keys() {   # best-effort: the `github.*` key NAMES this config actually has.
    # A DIAGNOSTIC, never a verdict — the verdict is already decided by the
    # time this runs, so an empty result costs a hint and nothing else. Names
    # only: `--dump` prints values too, and those include credential paths.
    "$_root/config/load.sh" --dump 2>/dev/null | sed -n 's/^\(github\.[A-Za-z0-9_]*\)=.*/        \1/p'
}
_generic_not_declared() {   # <why> <load.sh diagnostic>
    echo "assert-bot-author: REFUSING to verify — github.bot_login did not resolve, and the" >&2
    echo "  generic 'any [bot] account' check is OPT-IN (your-org/nexus-code#1307): $1" >&2
    [[ -n "${2:-}" ]] && echo "  config/load.sh said: $2" >&2
    echo "  TWO CAUSES LOOK IDENTICAL HERE and the config reader cannot tell them apart:" >&2
    echo "    (a) github.bot_login is MISSPELLED or nested wrong — the likely one. The keys" >&2
    echo "        this config actually defines under github.:" >&2
    _github_keys >&2
    echo "        Fix the spelling; this check then compares against your real bot." >&2
    echo "    (b) this fork genuinely has no bot_login. Declare that ONCE, in config:" >&2
    echo "            github:" >&2
    echo "              bot_login_absent_ok: true" >&2
    echo "        and the generic '[bot]-suffix, operator excluded' check runs again." >&2
    echo "  Until then the write is UNVERIFIED. The generic check passes ANY GitHub App," >&2
    echo "  so taking it by accident is how a wrong-App write reads as OK (#1307)." >&2
    exit 2
}

_cfg_read github.bot_login
_bot_rc=$?
bot="$_CFG_VAL"; _bot_err="$_CFG_ERR"
# rc 0 with an EMPTY value is a THIRD indeterminate state: the key is present
# and configured to nothing, so there is no identity to compare against. It is
# not "absent (older forks)" and it must not take the permissive arm either.
if (( _bot_rc == 3 )); then
    _unverified "the config reader failed for github.bot_login" "$_bot_err"
elif (( _bot_rc == 0 )) && [[ -z "$bot" ]]; then
    _unverified "github.bot_login is present but empty in the config" ""
fi

_cfg_read github.user_login
_op_rc=$?
operator="$_CFG_VAL"; _op_err="$_CFG_ERR"

# Exact match against the configured bot (with or without the [bot] suffix
# GitHub appends to App identities).
if (( _bot_rc == 0 )); then
    if [[ "$login" == "$bot" || "$login" == "${bot}[bot]" ]]; then
        echo "assert-bot-author: OK — authored by $login (matches configured github.bot_login '$bot')"
        exit 0
    fi
else
    # rc 2 — github.bot_login DID NOT RESOLVE. #1267 read that as "genuinely
    # absent (older forks)"; it is not the same fact. `config/load.sh` reports
    # rc 2 for a key that is missing AND for a key that is MISTYPED, so this
    # branch is reached by an operator who set `bot_logn:` and by a fork that
    # set nothing, indistinguishably (#1307). The generic `[bot]`-suffix check
    # therefore no longer runs on rc 2 alone — see the opt-in gate below.
    #
    # This guard stays where it was and is unchanged: the generic check leans
    # entirely on knowing who the operator is, and an operator we cannot name
    # makes its one discriminator vacuous.
    if (( _op_rc != 0 )) || [[ -z "$operator" ]]; then
        _unverified "github.bot_login is absent AND github.user_login could not be read, so the generic [bot] fallback has no operator to exclude" "$_op_err"
    fi
    if [[ "$login" == *'[bot]' && "$login" != "$operator" ]]; then
        # THE GATE SITS HERE, ON THE PASS, AND NOWHERE ELSE (#1307). Putting it
        # earlier would downgrade a definite FAIL — an operator-authored write,
        # or a plain human author — into "unverified", losing the loudest
        # diagnosis this script has for the case that matters most. The only
        # behaviour a declaration buys is the permissive PASS.
        _cfg_read github.bot_login_absent_ok
        _optin_rc=$?
        _optin="$_CFG_VAL"; _optin_err="$_CFG_ERR"
        if (( _optin_rc == 3 )); then
            _generic_not_declared "the config reader failed for github.bot_login_absent_ok" "$_optin_err"
        elif (( _optin_rc != 0 )); then
            _generic_not_declared "github.bot_login_absent_ok is not set" ""
        elif [[ "$_optin" != "true" ]]; then
            # Anything that does not arrive as `true` refuses, and the value
            # is NAMED so a wrong spelling is diagnosable rather than mysterious.
            # NOTE WHAT THIS DOES AND DOES NOT PIN (#1307 skeptic F1): load.sh
            # normalises YAML 1.1 booleans and stringifies them lowercase, so
            # `true True TRUE yes Yes YES on On` and the quoted `"true"` ALL
            # arrive here as `true` — NINE spellings, measured, not one. What is
            # pinned is that a POSITIVE declaration is required: `y`/`Y`, `1`,
            # the quoted `"True"`/`"yes"`, `false`, `no`, an empty value and an
            # absent key all refuse.
            _generic_not_declared "github.bot_login_absent_ok is '$_optin', and only the exact value 'true' opts in" ""
        fi
        # NEAR-MISS GUARD (your-org/nexus-code#1307 skeptic F2). The opt-in is
        # honoured, so the permissive arm is about to run — and the one thing
        # that must not be true here is that `bot_login` was SET and MISSPELLED.
        # `config/load.sh` cannot tell us; the KEY NAMES can. Refuse on a
        # `github.*` key carrying the `bot_log` stem that is neither the real key
        # nor this opt-in, and NAME it.
        _nearmiss=$(_github_keys | sed 's/^[[:space:]]*//' \
            | grep -E '^github\.[A-Za-z0-9_]*bot_log' \
            | grep -vxE 'github\.bot_login|github\.bot_login_absent_ok' || true)
        if [[ -n "$_nearmiss" ]]; then
            echo "assert-bot-author: REFUSING to verify — the generic 'any [bot]' check is declared" >&2
            echo "  via github.bot_login_absent_ok, but this config ALSO defines a near-miss key:" >&2
            printf '        %s\n' $_nearmiss >&2
            echo "  That reads as a MISSPELLED github.bot_login, and a misspelled bot_login is" >&2
            echo "  indistinguishable from an absent one to config/load.sh (#1307) — so the" >&2
            echo "  declaration would silently license a write by a DIFFERENT GitHub App." >&2
            echo "  Fix the spelling, or delete the stray key if it is genuinely something else." >&2
            exit 2
        fi
        echo "assert-bot-author: OK — authored by $login (github.bot_login unset and github.bot_login_absent_ok declared; generic [bot] check, operator '$operator' excluded)"
        exit 0
    fi
fi

cat >&2 <<MSG
assert-bot-author: FAIL — '$api' is authored by '$login', not the bot${bot:+ ('$bot')}.
$( [[ -n "$operator" && "$login" == "$operator" ]] && echo "That is the OPERATOR: GitHub mutes self-authored notifications, so this write will NEVER notify them." )
Re-post it minted: GH_TOKEN=\$("$_dir/mint-token.sh") gh <write> …  (your-org/nexus-code#497)
MSG
exit 1
