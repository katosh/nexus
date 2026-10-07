#!/usr/bin/env bash
# monitor/install-codex-local.sh — install the pinned OpenAI Codex CLI into
# the nexus's ISOLATED codex package root, codex-cli/
# (your-org/nexus-code#1640).
#
# usage: monitor/install-codex-local.sh [--check]
#
#   (no flag)  install the EXPECTED version (monitor/_codex.sh:
#              codex_version_expected — the local pin
#              monitor/.state/codex-version-local if present, else the
#              codex-cli/package.json floor) and verify it.
#   --check    install nothing; exit 0 if the installed binary reports the
#              expected version, 1 if not (with the reason), 3 if the
#              expected version cannot be resolved.
#
# WHY A SEPARATE PACKAGE ROOT. An `npm install` at the nexus root reconciles
# EVERY dependency to the root lockfile, including @anthropic-ai/claude-code.
# On an operator whose gated cc-update advanced the LOCAL cc pin past the
# package.json floor, that silently downgrades Claude Code — measured while
# writing this: adding codex to the root package.json rewrote nine claude
# lock entries in the same `npm install`. install-claude-local.sh exists to
# make "a pin bump never ends without a working claude" impossible to break;
# this script never touches the root node_modules, so it cannot break it.
#
# Idempotent: already at the expected version → no-op, exit 0.
# Fail-loud: exit 0 only when the binary exists, runs, and reports the
# expected version. A failed npm run leaves any previous install in place
# (`npm install`, never `npm ci`, for the same NFS reason as the claude
# installer: ci wipes node_modules first).
#
# Exit: 0 ok · 1 install/verify failed · 2 usage · 3 expected version unresolvable

set -uo pipefail

_sd=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
NEXUS_ROOT=$(cd "$_sd/.." && pwd)
export NEXUS_ROOT
# shellcheck source=monitor/_codex.sh
. "$_sd/_codex.sh"

CHECK=0
case "${1:-}" in
    "") ;;
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "install-codex-local: unknown argument: $1" >&2; exit 2 ;;
esac

PKG_ROOT="$NEXUS_ROOT/codex-cli"
BIN="$PKG_ROOT/node_modules/.bin/codex"

if expected=$(codex_version_expected); then erc=0; else erc=$?; fi
if (( erc != 0 )); then
    echo "install-codex-local: cannot resolve the expected codex version (rc $erc): no readable local pin and no @openai/codex in $PKG_ROOT/package.json" >&2
    exit 3
fi

have=""
[[ -x "$BIN" ]] && have=$(codex_version_installed "$BIN") || true

if [[ "$have" == "$expected" ]]; then
    echo "install-codex-local: ok — codex-cli $have at $BIN"
    exit 0
fi
if (( CHECK )); then
    echo "install-codex-local: MISMATCH — installed '${have:-<none>}', expected '$expected' ($BIN). Run: $0" >&2
    exit 1
fi

command -v npm >/dev/null 2>&1 || { echo "install-codex-local: npm not on PATH" >&2; exit 1; }
: "${npm_config_cache:=${NPM_CONFIG_CACHE:-$NEXUS_ROOT/.npm-cache}}"
export npm_config_cache

floor=$(awk -F'"' '{ for (i=1; i+2<=NF; i++) if ($i=="@openai/codex") { print $(i+2); exit } }' "$PKG_ROOT/package.json")
if [[ "$expected" == "$floor" ]]; then
    ( cd "$PKG_ROOT" && npm install --no-audit --no-fund )
else
    # A local pin: install that exact version WITHOUT rewriting the tracked
    # floor (the cc scheme, #226).
    ( cd "$PKG_ROOT" && npm install --no-audit --no-fund --no-save "@openai/codex@$expected" )
fi
nrc=$?

have=""
[[ -x "$BIN" ]] && have=$(codex_version_installed "$BIN") || true
if [[ "$have" != "$expected" ]]; then
    echo "install-codex-local: FAILED — npm rc $nrc; binary reports '${have:-<none>}', expected '$expected' ($BIN)" >&2
    exit 1
fi
echo "install-codex-local: ok — installed codex-cli $have at $BIN (npm rc $nrc)"
exit 0
