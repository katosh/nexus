#!/usr/bin/env bash
# Mint (or re-use a cached) installation access token for the GitHub App
# configured in config/nexus.yml (github.bot_*). Prints the token on
# stdout. Tokens are cached for ~55 min.
#
# Usage:
#   GH_TOKEN=$(monitor/mint-token.sh) gh issue list ...
#   monitor/mint-token.sh --jwt-only            # App-level JWT only
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
#
# Note: callers must check the exit code. `GH_TOKEN=$(...)` discards
# it; use `tok=$(./monitor/mint-token.sh) || die ...; GH_TOKEN=$tok gh
# ...` instead, or go through `monitor/ng` which already wraps this.

set -euo pipefail

die() { printf 'mint-token.sh: %s\n' "$*" >&2; exit "${MINT_DIE_RC:-2}"; }

JWT_ONLY=0
while (( $# > 0 )); do
    case "$1" in
        --jwt-only) JWT_ONLY=1; shift ;;
        -h|--help)
            sed -n '2,49p' "$0" >&2
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
if (( JWT_ONLY == 0 )); then
    mkdir -p "$(dirname "$CACHE")"
    if [[ -f "$CACHE" ]]; then
        cached_exp=$(jq -r '.expires_at_epoch // 0' "$CACHE" 2>/dev/null || echo 0)
        if (( cached_exp > $(date +%s) + SAFETY_S )); then
            jq -r '.token' "$CACHE"
            exit 0
        fi
    fi
fi

[[ -f "$KEY_PATH" ]] || die "private key not found at $KEY_PATH (github.bot_pem_path)"
[[ -r "$KEY_PATH" ]] || die "private key not readable at $KEY_PATH (check perms; should be 600)"

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

expires_at_epoch=$(date -d "$expires_at" +%s)

umask 077
tmp=$(mktemp "${CACHE}.XXXXXX")
jq -n --arg token "$token" --arg expires_at "$expires_at" \
    --argjson epoch "$expires_at_epoch" \
    '{token:$token, expires_at:$expires_at, expires_at_epoch:$epoch}' \
    > "$tmp"
mv "$tmp" "$CACHE"
chmod 600 "$CACHE"

printf '%s\n' "$token"
