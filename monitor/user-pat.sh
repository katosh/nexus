#!/usr/bin/env bash
# Print the user's GitHub PAT for private-repo reads — `remotes::install_github`,
# `pip install git+https://...`, `git clone` over HTTPS, etc. Prints the token
# on stdout. Paired with monitor/mint-token.sh:
#
#   mint-token.sh  → bot installation token. For GitHub WRITES (issues,
#                    PRs, comments, reactions) as the bot identity.
#   user-pat.sh    → user OAuth PAT. For private-repo READS where the
#                    bot's installation token 404s — install_github,
#                    pip install git+, git clone over HTTPS.
#
# The two are not interchangeable. GitHub App installation tokens lack
# the `contents:read` surface that R/Python install helpers reach for on
# private repos, so they return 404 silently. See
# skills/nexus.bot/SKILL.md for the full reasoning.
#
# Usage:
#   GITHUB_PAT=$(./monitor/user-pat.sh) Rscript -e \
#     'remotes::install_github("your-org/<private-repo>", ref="<sha>")'
#
#   GITHUB_PAT=$(./monitor/user-pat.sh) uv pip install \
#     "git+https://github.com/your-org/<private-repo>@<sha>"
#
#   ./monitor/user-pat.sh --validate           # PAT is alive (hits /user)
#   ./monitor/user-pat.sh --probe owner/repo   # PAT can read this repo
#
# Resolution order (highest first):
#   1. $NEXUS_USER_PAT          explicit override; never confused with bot
#   2. $GITHUB_PAT              passthrough; the conventional var for
#                               remotes::install_github / pip git+
#   3. `gh auth token`          if gh is logged in on this host
#   4. $NEXUS_USER_PAT_FILE     (default: ~/.claude/.nexus-user-pat)
#                               chmod-600 file containing only the PAT
#
# We deliberately do NOT fall back to GH_TOKEN or GITHUB_TOKEN — by
# nexus convention those carry the bot installation token at many call
# sites. Quietly using a bot token in place of a user PAT reproduces
# the exact 404-silent failure mode this script exists to prevent.
#
# The PAT must have `repo` scope to read private your-org repos. Use
# --probe <owner/repo> in CI / install-test setups to catch
# scope-too-narrow errors before running a 10-minute bootstrap.
#
# Exit codes:
#   0  token printed on stdout (or validation/probe succeeded)
#   2  no PAT available — stderr explains how to provision one
#   3  PAT validation/probe failed (401 / 403 / 404)

set -euo pipefail

MODE=print
PROBE_REPO=""
while (( $# > 0 )); do
    case "$1" in
        --validate)         MODE=validate; shift ;;
        --probe)            MODE=probe; PROBE_REPO="${2:-}"; shift 2 ;;
        -h|--help)
            sed -n '2,55p' "$0" >&2
            exit 0 ;;
        *)
            echo "user-pat.sh: unknown flag: $1" >&2
            exit 1 ;;
    esac
done

if [[ "$MODE" == "probe" && -z "$PROBE_REPO" ]]; then
    echo "user-pat.sh: --probe requires <owner/repo>" >&2
    exit 1
fi

PAT_FILE="${NEXUS_USER_PAT_FILE:-$HOME/.claude/.nexus-user-pat}"

resolve_pat() {
    if [[ -n "${NEXUS_USER_PAT:-}" ]]; then
        printf '%s' "$NEXUS_USER_PAT"
        return 0
    fi
    if [[ -n "${GITHUB_PAT:-}" ]]; then
        printf '%s' "$GITHUB_PAT"
        return 0
    fi
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh auth token 2>/dev/null && return 0
    fi
    if [[ -r "$PAT_FILE" ]]; then
        # Strip whitespace; allow trailing newline.
        tr -d '[:space:]' < "$PAT_FILE"
        return 0
    fi
    return 1
}

PAT="$(resolve_pat || true)"
if [[ -z "${PAT:-}" ]]; then
    cat >&2 <<EOF
user-pat.sh: no user PAT available.

This is the USER identity for private-repo reads, not the bot. Pick one:

  1. gh auth login                              (then gh auth refresh -s repo if scopes are narrow)
  2. export NEXUS_USER_PAT=<your-pat>           (one-off, current shell)
  3. echo <your-pat> > $PAT_FILE && chmod 600 $PAT_FILE   (persistent across workers)

PAT must have \`repo\` scope to read private your-org repositories.
EOF
    exit 2
fi

api_probe() {
    local path="$1"
    curl -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${PAT}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/${path}"
}

case "$MODE" in
    print)
        printf '%s\n' "$PAT"
        ;;
    validate)
        code=$(api_probe "user")
        case "$code" in
            200) echo "user-pat.sh: PAT valid" >&2; exit 0 ;;
            401) echo "user-pat.sh: PAT rejected (401). Expired or revoked." >&2; exit 3 ;;
            *)   echo "user-pat.sh: unexpected status $code from /user" >&2; exit 3 ;;
        esac
        ;;
    probe)
        code=$(api_probe "repos/${PROBE_REPO}")
        case "$code" in
            200) echo "user-pat.sh: PAT can read ${PROBE_REPO}" >&2; exit 0 ;;
            404) echo "user-pat.sh: ${PROBE_REPO} → 404. Either PAT lacks \`repo\` scope or the account has no read access." >&2; exit 3 ;;
            401) echo "user-pat.sh: PAT rejected (401). Expired or revoked." >&2; exit 3 ;;
            403) echo "user-pat.sh: ${PROBE_REPO} → 403. Rate-limited or scope insufficient." >&2; exit 3 ;;
            *)   echo "user-pat.sh: unexpected status $code probing ${PROBE_REPO}" >&2; exit 3 ;;
        esac
        ;;
esac
