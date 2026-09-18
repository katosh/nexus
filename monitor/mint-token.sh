#!/usr/bin/env bash
# Mint (or re-use a cached) installation access token for the GitHub App
# configured in config/nexus.yml (github.bot_*). Prints the token on
# stdout. Tokens are cached for ~55 min.
#
# Usage:
#   GH_TOKEN=$(monitor/mint-token.sh) gh issue list ...
#   monitor/mint-token.sh --jwt-only            # App-level JWT only
#   monitor/mint-token.sh --check-key           # report the key's exposure; mint nothing
#
# The default (no flag) prints an installation access token suitable for
# `GH_TOKEN=...` with `gh`. With `--jwt-only`, the script prints just the
# App-level JWT — used for endpoints that authenticate as the App
# itself, not as an installation. The deliveries endpoint
# (`/app/hook/deliveries`) is the canonical example: it lists every
# webhook event GitHub has fired across the App's installations,
# regardless of which installation the event targeted.
#
# Both modes share the same codepath up to JWT minting; only the
# default mode performs the JWT->installation-token exchange and the
# token-cache write. JWTs are short-lived (10 min ceiling on GitHub's
# side) and not cached locally — re-mint per call.
#
# Config resolution (mirrors monitor/ng's STATE_DIR shape):
#   1. $NEXUS_CONFIG  env override pointing at a specific YAML file.
#   2. $NEXUS_ROOT/config/nexus.yml  (operator-pinned root; set by
#      monitor/spawn-worker.sh so a worker in a worktree resolves to
#      the primary clone's config).
#   3. <script-dir>/../config/nexus.yml  (script-relative fallback).
#
# The script NEVER falls back to config/nexus.example.yml — the
# template's placeholder values would either (a) yield a JWT GitHub
# rejects with 401 or (b) flat-out fail at the missing private-key
# path. In either case, the script previously exited non-zero with an
# empty stdout, and the canonical caller pattern
# `GH_TOKEN=$(./monitor/mint-token.sh) gh ...` substitutes "" into
# GH_TOKEN — which `gh` treats as "no override" and falls through to
# the user's ambient `gh auth token`. That bypassed the bot/user
# identity boundary; PR #25 (closed) on `your-org/nexus-code` shipped
# under @operator as a result. Failing loud at config-resolve time is
# the only way to make that failure mode observable to the caller.
#
# Value precedence per field (highest first):
#   1. explicit env var (below)
#   2. config/nexus.yml resolved above
#
# Env overrides:
#   NEXUS_BOT_APP_ID
#   NEXUS_BOT_INSTALLATION_ID
#   NEXUS_BOT_PRIVATE_KEY_PATH
#   NEXUS_BOT_TOKEN_CACHE
#
# Exit codes:
#   0  token printed on stdout
#   2  bot config unreachable (no nexus.yml found, required key empty,
#      or private key file missing/unreadable)
#   3  token mint failed (response on stderr)
#   4  private key REFUSED: it is world-accessible AND every ancestor
#      directory is world-traversable, so other local users can read it.
#      `chmod 600` the key. Distinct from 2 so a caller can tell a
#      credential-hygiene refusal from a missing/broken config.
#      `--check-key` reports the same analysis without minting.
#
# Note: callers must check the exit code. `GH_TOKEN=$(...)` discards
# it; use `tok=$(./monitor/mint-token.sh) || die ...; GH_TOKEN=$tok gh
# ...` instead, or go through `monitor/ng` which already wraps this.

set -euo pipefail

# ARGUMENT-LOOP PROGRESS GUARD (your-org/nexus-code#924). Each argument loop
# below asserts that every iteration consumes at least one argument. Without it
# a value-taking flag given LAST spins forever — `shift 2` with `$#` == 1 is
# refused, so the arm re-matches — and a hang here is worse than an error
# because nothing on this board surfaces it. Full rationale: monitor/ng.
_argloop_stuck() {
    printf '%s: option %s requires a value (argument loop made no progress)\n' \
        "${0##*/}" "${1-}" >&2
    exit 64
}

die() { printf 'mint-token.sh: %s\n' "$*" >&2; exit "${MINT_DIE_RC:-2}"; }

JWT_ONLY=0
CHECK_KEY=0
_argloop_prev_1=-1; while (( $# > 0 )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
    case "$1" in
        --jwt-only) JWT_ONLY=1; shift ;;
        --check-key) CHECK_KEY=1; shift ;;
        -h|--help)
            # 2,66 — the whole header comment, INCLUDING the exit codes.
            # It was 2,49 and stopped short of them, so `--help` documented
            # every flag and none of the statuses a caller must branch on
            # (your-org/nexus-code#1501 added a fourth). The range ends one
            # line above `set -euo pipefail`; a header that grows past it
            # truncates silently, which is why the last documented line is
            # named here rather than left to be inferred.
            sed -n '2,66p' "$0" >&2
            exit 0 ;;
        *)
            echo "mint-token.sh: unknown flag: $1" >&2
            exit 1 ;;
    esac
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Anchor at the nexus root so any relative paths returned by config/
# (e.g. github.bot_pem_path, github.bot_token_cache) resolve consistently
# regardless of caller cwd. Mirrors monitor/upload-asset.sh:60-62.
cd "$SCRIPT_DIR/.." || die "cannot cd to $SCRIPT_DIR/.."

# Resolve config/nexus.yml strictly. NEVER falls back to
# config/nexus.example.yml — see header for the identity-boundary
# rationale.
_resolve_cfg() {
    if [[ -n "${NEXUS_CONFIG:-}" ]]; then
        [[ -f "$NEXUS_CONFIG" ]] \
            || die "NEXUS_CONFIG=$NEXUS_CONFIG: file does not exist"
        printf '%s' "$NEXUS_CONFIG"
        return 0
    fi
    local p
    if [[ -n "${NEXUS_ROOT:-}" ]]; then
        p="$NEXUS_ROOT/config/nexus.yml"
        [[ -f "$p" ]] \
            || die "NEXUS_ROOT=$NEXUS_ROOT but $p does not exist; copy config/nexus.example.yml -> config/nexus.yml and edit"
        printf '%s' "$p"
        return 0
    fi
    p="$SCRIPT_DIR/../config/nexus.yml"
    if [[ ! -f "$p" ]]; then
        die "config/nexus.yml not found at $(cd "$SCRIPT_DIR/.." && pwd)/config/nexus.yml — set NEXUS_ROOT to the primary clone or NEXUS_CONFIG to a specific file; example.yml fallback is intentionally disabled"
    fi
    printf '%s' "$p"
}

NEXUS_CONFIG="$(_resolve_cfg)"
export NEXUS_CONFIG  # forces config/load.sh to read this file only

_cfg="config/load.sh"
[[ -x "$_cfg" ]] || die "$_cfg missing or not executable"

# Load a required key; die loud if missing or empty. load.sh exits 2
# when a key has no value and no default is supplied — we honour that
# rather than falling through to placeholders.
_cfg_required() {
    local key="$1" v
    v=$("$_cfg" "$key") || die "$key missing from $NEXUS_CONFIG"
    [[ -n "$v" ]] || die "$key resolved to empty in $NEXUS_CONFIG"
    printf '%s' "$v"
}

APP_ID="${NEXUS_BOT_APP_ID:-}"
[[ -n "$APP_ID" ]] || APP_ID=$(_cfg_required github.bot_app_id)
INSTALLATION_ID="${NEXUS_BOT_INSTALLATION_ID:-}"
[[ -n "$INSTALLATION_ID" ]] || INSTALLATION_ID=$(_cfg_required github.bot_installation_id)
KEY_PATH="${NEXUS_BOT_PRIVATE_KEY_PATH:-}"
[[ -n "$KEY_PATH" ]] || KEY_PATH=$(_cfg_required github.bot_pem_path)
CACHE="${NEXUS_BOT_TOKEN_CACHE:-$("$_cfg" github.bot_token_cache "$HOME/.claude/.nexus-bot-token.json")}"
SAFETY_S=300   # mint a fresh token if cached one expires within 5 min

# Cache only applies to installation tokens. JWT mode skips it entirely:
# the JWT is short-lived by design, and one mint per call keeps the
# 10-minute ceiling fresh for callers that hold the JWT briefly.
# THE CACHE IS AN OPTIMISATION. THE TOKEN IS THE PRODUCT.
#
# Every operation on the cache below is ADVISORY: it may fail, warn, and be
# skipped, but it may never cost us a token we already hold or a mint we
# could still perform. This script runs under `set -e`, and it used to let a
# failed cache side-effect abort it AFTER a successful network mint — the
# token was in a variable, the caller got rc 1 and empty stdout, and a
# correct operation was reported as broken (your-org/nexus-code#488).
#
# That matters most in exactly the scenario the cache exists to survive: a
# read-only project FS. The read-only-FS escalation (#473/#482) reaches
# GitHub *because* this cache lives under $HOME, a different mount. If $HOME
# is ALSO read-only or full — a double outage — the old code aborted before
# it even tried the network, with a valid credential one `curl` away.
_cache_warn() { printf 'mint-token.sh: %s\n' "$*" >&2; }

# `CHECK_KEY` joins the guard: the cache arm EXITS 0 with a token, so a
# `--check-key` run that happened to find a warm cache would print a
# credential and never reach its own report (your-org/nexus-code#1501).
if (( JWT_ONLY == 0 && CHECK_KEY == 0 )); then
    # Advisory: a missing cache dir on a read-only/full $HOME must not stop
    # us from minting a fresh token over a perfectly healthy network.
    if ! mkdir -p "$(dirname "$CACHE")" 2>/dev/null; then
        _cache_warn "cannot create cache dir $(dirname "$CACHE") (read-only or full \$HOME?) — continuing without a cache"
    fi
    if [[ -f "$CACHE" ]]; then
        cached_exp=$(jq -r '.expires_at_epoch // 0' "$CACHE" 2>/dev/null || echo 0)
        [[ "$cached_exp" =~ ^[0-9]+$ ]] || cached_exp=0
        # Read the token BEFORE deciding to serve it. A corrupt cache with a
        # parseable epoch but no `.token` used to print the literal string
        # `null` and exit 0 — a caller's `[[ -n "$tok" ]]` guard passes and
        # the write 401s. Require a real token, else fall through and mint.
        cached_tok=$(jq -r '.token // empty' "$CACHE" 2>/dev/null || true)
        if [[ -n "$cached_tok" && "$cached_tok" != "null" ]] \
           && (( cached_exp > $(date +%s) + SAFETY_S )); then
            printf '%s\n' "$cached_tok"
            exit 0
        fi
    fi
fi

[[ -f "$KEY_PATH" ]] || die "private key not found at $KEY_PATH (github.bot_pem_path)"
[[ -r "$KEY_PATH" ]] || die "private key not readable at $KEY_PATH (check perms; should be 600)"

# ---------------------------------------------------------------------------
# KEY EXPOSURE GATE (your-org/nexus-code#1501)
# ---------------------------------------------------------------------------
#
# The two checks above are `-f` and `-r`. For a long time the words
# "should be 600" sat in the SECOND one's failure message and enforced
# nothing, while two documents asserted this script rejects a loose key
# mode. A mode-644 key passed both tests in silence. That is a documented
# guarantee with no enforcing branch, which is worse than a documented gap:
# a gap invites scrutiny, a false guarantee deflects it.
#
# WHAT IS ENFORCED HERE, AND WHY IT IS NOT `mode == 600`.
#
# A file mode is the LAST gate, not the only one. `#1501` was filed as an
# exposure on the strength of `stat` ON THE FILE ALONE — mode 644 — and
# withdrawn when the ancestors were read: `~/.claude` is 700, so
# other-execute is 0 and no other user can TRAVERSE to the path. The file's
# own 644 was inert. `stat` on a file answers "what are this inode's bits",
# never "who can read this file".
#
# So a naive `case $mode in 600|400) ;; *) die` would REFUSE a setup that is
# in fact airtight, on every mint, on the path every GitHub write in this
# nexus takes — a self-inflicted outage in answer to a non-problem. The gate
# refuses only on a POSITIVELY ESTABLISHED exposure: world bits on the key
# AND an unbroken world-traversable path to it. Anything it cannot establish
# it does not assert; see `_key_reachable_by_others`, which is three-valued
# for that reason.
#
# GROUP is deliberately NOT a refusal. Who is in a group is not derivable
# here, and a bot-uid group is a legitimate administered setup (the same
# doc sanctions `0660` for the webhook secret). `--check-key` reports it;
# this gate does not act on it.
#
# The remedy the refusal names is `chmod 600`, which is one command, always
# available, and cannot break anything — which is what makes refusing (as
# opposed to warning) the right severity.

# _key_mode <path> — the octal mode, or empty when it cannot be read.
_key_mode() {
    local m
    m=$(stat -c '%a' -- "$1" 2>/dev/null) || return 1
    [[ "$m" =~ ^[0-7]{3,4}$ ]] || return 1
    printf '%s\n' "$m"
}

# _key_reachable_by_others <path>
#   0  every ancestor directory grants other-execute — another local user can
#      traverse to this path
#   1  some ancestor denies it — containment, positively established
#   3  UNKNOWN — an ancestor could not be stat'd. NEITHER of the above; the
#      caller must not read it as either (this repo's three-valued doctrine:
#      "I could not tell" is not silently "no").
_key_reachable_by_others() {
    local d m up
    d=$(dirname -- "$1")
    # Resolve symlinks when we can: the mode that matters belongs to the
    # directories actually walked, not to the ones spelled in the config.
    if command -v readlink >/dev/null 2>&1; then
        local real; real=$(readlink -f -- "$d" 2>/dev/null) && [[ -n "$real" ]] && d="$real"
    fi
    while :; do
        m=$(stat -c '%a' -- "$d" 2>/dev/null) || return 3
        [[ "$m" =~ ^[0-7]{3,4}$ ]] || return 3
        (( (8#$m & 8#1) != 0 )) || return 1
        [[ "$d" == "/" ]] && break
        up=$(dirname -- "$d")
        [[ "$up" == "$d" ]] && break
        d="$up"
    done
    return 0
}

# _key_exposure_report <path> — prints `verdict=<exposed|contained|group-visible|ok|unknown> mode=<m> reason=<...>`
# on stdout. Never exits; the decision belongs to the caller.
_key_exposure_report() {
    local kp="$1" mode reach
    mode=$(_key_mode "$kp") || {
        printf 'verdict=unknown mode=? reason=stat could not read the mode of %s\n' "$kp"
        return 0
    }
    local world=$(( 8#$mode & 8#7 )) group=$(( 8#$mode & 8#70 ))
    if (( world == 0 && group == 0 )); then
        printf 'verdict=ok mode=%s reason=no group or other bits; only the owner can read or replace the key\n' "$mode"
        return 0
    fi
    if (( world != 0 )); then
        # `set -e` is on: a three-valued probe returning 1 or 3 as a SIMPLE
        # command would abort the script. Read the status into a variable on
        # the very next line, with the `||` that makes the non-zero legal.
        reach=0; _key_reachable_by_others "$kp" || reach=$?
        case "$reach" in
            0) printf 'verdict=exposed mode=%s reason=the key carries other-bits AND every ancestor directory grants other-execute, so any local user can reach it\n' "$mode" ;;
            1) printf 'verdict=contained mode=%s reason=the key carries other-bits but an ancestor directory denies other-execute, so the file mode is inert; still worth tightening\n' "$mode" ;;
            *) printf 'verdict=unknown mode=%s reason=the key carries other-bits and an ancestor directory could not be stat'"'"'d, so reachability is UNDETERMINED — neither established nor ruled out\n' "$mode" ;;
        esac
        return 0
    fi
    printf 'verdict=group-visible mode=%s reason=the key is group-accessible; who is in that group is not derivable here, so this is reported and not acted on\n' "$mode"
}

# `--check-key` REPORTS rather than dies, so the gate is skipped for it — a
# diagnostic verb that exits through the refusal it exists to explain would
# print the refusal and never reach its own report.
if [[ "${NEXUS_SKIP_KEY_EXPOSURE_GATE:-0}" != 1 ]] && (( CHECK_KEY == 0 )); then
    _kx=$(_key_exposure_report "$KEY_PATH")
    case "$_kx" in
        verdict=exposed*)
            printf 'mint-token.sh: REFUSING to sign with %s\n' "$KEY_PATH" >&2
            printf '  %s\n' "$_kx" >&2
            printf '  This is not a mode preference: the ancestors were walked and every one\n' >&2
            printf '  of them grants other-execute, so the bits on the key are the whole of\n' >&2
            printf '  the protection and they are open.\n' >&2
            printf '  Fix:  chmod 600 %q\n' "$KEY_PATH" >&2
            printf '  Then consider ROTATING the key — a mode change does not un-expose a\n' >&2
            printf '  key that was readable (docs/admin/github-app.md, "Rotating the private key").\n' >&2
            MINT_DIE_RC=4 die "private key at $KEY_PATH is reachable and readable by other local users"
            ;;
    esac
    unset _kx
fi

# `--check-key` REPORTS and exits. It is the surface the docs point at for the
# three verdicts the gate deliberately does not act on — `contained`,
# `group-visible` and `unknown` — so that "the gate did not refuse" never has
# to be read as "the mode is fine". Exit 0 = `ok`, 4 = `exposed` (the same code
# the gate dies with), 5 = anything the gate tolerates but a reader should see.
if (( CHECK_KEY == 1 )); then
    _kx=$(_key_exposure_report "$KEY_PATH")
    printf 'key: %s\n' "$KEY_PATH"
    printf '%s\n' "$_kx"
    case "$_kx" in
        verdict=ok*)       exit 0 ;;
        verdict=exposed*)  exit 4 ;;
        *)                 exit 5 ;;
    esac
fi

b64url() { base64 -w 0 | tr -d '=' | tr '+/' '-_'; }

header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
now=$(date +%s)
# exp = now + 600 (GitHub's documented max JWT lifetime against the
# server clock). iat = now - 30 absorbs minor clock skew between this
# host and api.github.com so the JWT isn't rejected as "iat in the
# future". GitHub treats exp loosely relative to its own clock; the 30 s
# backfill on iat doesn't cost validity at the exp boundary in practice.
# Same payload is used for the install-token exchange (one immediate
# POST) and for JWT-only callers (deliveries polling, which re-mints
# per cycle).
payload=$(printf '{"iat":%d,"exp":%d,"iss":%d}' \
            $((now-30)) $((now+600)) "$APP_ID" | b64url)
sig=$(printf '%s' "${header}.${payload}" \
      | openssl dgst -sha256 -sign "$KEY_PATH" -binary | b64url)
app_jwt="${header}.${payload}.${sig}"

if (( JWT_ONLY == 1 )); then
    printf '%s\n' "$app_jwt"
    exit 0
fi

resp=$(curl -sS -X POST \
    -H "Authorization: Bearer $app_jwt" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens")

token=$(printf '%s' "$resp" | jq -r '.token // empty')
expires_at=$(printf '%s' "$resp" | jq -r '.expires_at // empty')

if [[ -z "$token" ]]; then
    MINT_DIE_RC=3 die "failed to mint installation token (POST /app/installations/$INSTALLATION_ID/access_tokens): $resp"
fi

# ---------------------------------------------------------------------------
# From here on we HOLD A VALID TOKEN. Nothing below may be fatal.
#
# Everything that follows is cache bookkeeping. Under `set -e` a bare
# `mktemp` / `mv` / `chmod` / `date` failure would abort the script before the
# final `printf`, discarding a token that was minted successfully — the caller
# sees rc 1 and empty stdout, and reports a correct operation as broken. Warn,
# skip the cache, return the token. (your-org/nexus-code#488)
# ---------------------------------------------------------------------------

# _cache_store <token> <expires_at> — best effort. 0 if cached, 1 if not.
# Never exits, never propagates a failure, never leaves a tmp file behind.
_cache_store() {
    local _tok="$1" _exp="$2" _epoch _tmp

    # `date -d` on a malformed/absent expires_at must not kill us either.
    if ! _epoch=$(date -d "$_exp" +%s 2>/dev/null) || [[ ! "$_epoch" =~ ^[0-9]+$ ]]; then
        _cache_warn "unparseable expires_at ($_exp) — token is valid, skipping the cache"
        return 1
    fi

    if ! _tmp=$(mktemp "${CACHE}.XXXXXX" 2>/dev/null); then
        _cache_warn "cannot create a cache tempfile beside $CACHE (read-only or full \$HOME?) — token is valid, skipping the cache"
        return 1
    fi

    if ! jq -n --arg token "$_tok" --arg expires_at "$_exp" \
            --argjson epoch "$_epoch" \
            '{token:$token, expires_at:$expires_at, expires_at_epoch:$epoch}' \
            > "$_tmp" 2>/dev/null; then
        rm -f "$_tmp" 2>/dev/null || true
        _cache_warn "cannot write the cache payload — token is valid, skipping the cache"
        return 1
    fi

    # chmod BEFORE the rename so the cache is never briefly world-readable
    # at its final name. umask 077 already covers mktemp; this is belt-and-braces.
    chmod 600 "$_tmp" 2>/dev/null || true

    if ! mv "$_tmp" "$CACHE" 2>/dev/null; then
        rm -f "$_tmp" 2>/dev/null || true
        _cache_warn "cannot publish $CACHE — token is valid, skipping the cache"
        return 1
    fi
    return 0
}

umask 077
_cache_store "$token" "$expires_at" || true

printf '%s\n' "$token"
