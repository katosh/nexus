#!/usr/bin/env bash
# Read a single dotted key from the nexus config file.
#
# Usage:
#   config/load.sh <dotted.key>                # prints value on stdout
#   config/load.sh --dump                      # prints every resolved key=value
#   config/load.sh <dotted.key> <default>      # falls back to default if missing
#   config/load.sh --check-identity            # exit 4 (loud) if identity keys
#                                              # resolve to nexus.example.yml
#                                              # placeholders; exit 0 if real
#   config/load.sh --validate                  # like --check-identity but over
#                                              # the FULL required-key set
#                                              # (identity + bot credentials);
#                                              # exit 4 (loud) on any placeholder
#                                              # or empty required value
#
# Precedence:
#   1. $NEXUS_CONFIG (explicit env path) — used if set.
#   2. config/nexus.yml — if present.
#   3. config/nexus.example.yml — repo-tracked template.
#
# Callers remain free to override any field via their own scoped env
# vars (e.g. $MONITOR_REPO overrides github.repo in the watcher).
# This helper is just the source-of-truth loader.
#
# `~` in string values is expanded to $HOME. Numeric and null values
# are stringified via Python's str().
#
# Exit codes:
#   0  value printed
#   1  usage error or no config file found
#   2  key not present and no default supplied
#   3  python3 / pyyaml missing
#   4  --check-identity / --validate: a required key resolves to its
#      nexus.example.yml placeholder (or, for --validate, is present but
#      empty)

set -euo pipefail

usage() { sed -n '3,20p' "$0" >&2; exit "${1:-1}"; }

[[ $# -ge 1 ]] || usage 1

KEY="$1"
DEFAULT="${2-__NEXUS_NO_DEFAULT__}"

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
nexus_root="${NEXUS_ROOT:-$(cd "$script_dir/.." && pwd)}"

CFG_CANDIDATES=()
[[ -n "${NEXUS_CONFIG:-}" ]] && CFG_CANDIDATES+=("$NEXUS_CONFIG")
CFG_CANDIDATES+=("$nexus_root/config/nexus.yml" "$nexus_root/config/nexus.example.yml")

pick=""
for c in "${CFG_CANDIDATES[@]}"; do
    [[ -f "$c" ]] || continue
    pick="$c"; break
done
[[ -n "$pick" ]] || { echo "load.sh: no config found; tried: ${CFG_CANDIDATES[*]}" >&2; exit 1; }

command -v python3 >/dev/null || { echo "load.sh: python3 required" >&2; exit 3; }

NEXUS_CFG_PATH="$pick" NEXUS_EXAMPLE_PATH="$nexus_root/config/nexus.example.yml" KEY="$KEY" DEFAULT="$DEFAULT" python3 - <<'PY'
import os, sys
try:
    import yaml
except ImportError:
    print("load.sh: pyyaml required (apt install python3-yaml, or uv run --with pyyaml)", file=sys.stderr)
    sys.exit(3)

path, key, default = os.environ['NEXUS_CFG_PATH'], os.environ['KEY'], os.environ['DEFAULT']
with open(path) as f:
    cfg = yaml.safe_load(f) or {}

def _stringify(v):
    # YAML booleans → lowercase bash-friendly "true"/"false". `str(True)`
    # otherwise gives "True", which silently mismatches every `[[ "$x" ==
    # "true" ]]` gate downstream. The 2026-05-01 incident: `monitor.
    # deliveries_enabled: true` was never honoured because the watcher's
    # `[[ "$del" == "true" ]]` check failed against "True".
    if isinstance(v, bool):
        return 'true' if v else 'false'
    return str(v)

if key == '--dump':
    def walk(d, prefix=''):
        if isinstance(d, dict):
            for k, v in d.items():
                walk(v, f"{prefix}{k}." if prefix == '' else f"{prefix[:-1]}.{k}.")
        else:
            s = _stringify(d)
            if s.startswith('~'):
                s = os.path.expanduser(s)
            print(f"{prefix.rstrip('.')}={s}")
    walk(cfg)
    sys.exit(0)

if key in ('--check-identity', '--validate'):
    # Fail-loud guard for your-org/your-nexus#236 B11 (+ the operator's
    # #311 ask to "explicitly check for some values that should be set to
    # a non-placeholder value"). config/nexus.yml is gitignored, so a
    # worktree or fresh clone that never received it makes the precedence
    # above fall through to the repo-tracked nexus.example.yml, whose
    # required keys hold placeholders (github.repo=your-org/...,
    # nexus.root=/path/to/nexus, github.bot_app_id=0000000, ...) that look
    # real enough that the watcher "starts clean" yet acts against a
    # non-existent repo and cannot mint a bot token. A start-up caller
    # runs this to refuse loudly instead of failing cryptically later
    # (mint-token 401, snapshot_github silently skipped).
    #
    # A value is a placeholder when it equals that key's value in
    # nexus.example.yml — self-maintaining (whatever the template ships is
    # detected) and it also catches the copied-but-unedited nexus.yml
    # case, not just the missing-file fall-through. The documented
    # per-field env overrides (MONITOR_REPO, NEXUS_ROOT, NEXUS_BOT_APP_ID,
    # ...) take precedence, mirroring each consuming script's own
    # resolution, so this checks the EFFECTIVE value rather than only the
    # file.
    #
    # `--check-identity` checks the identity subset only (back-compat with
    # the B11 start-up guards). `--validate` checks the full required set:
    # identity PLUS the bot credentials mint-token.sh needs (a placeholder
    # github.bot_app_id yields a JWT GitHub rejects with 401; a
    # placeholder github.bot_pem_path points at a key file that doesn't
    # exist). Optional/defaulted keys (notifications.*, bot_login,
    # bot_webhook_*, bot_git_*) are NOT required — they degrade gracefully
    # or have documented fallbacks, so demanding real values would be a
    # false positive on a legitimately-minimal nexus.
    #
    # Scope: a required key is bad when it still equals its placeholder OR
    # is present-but-empty (both are "not set to a real value", the #311
    # intent). A key that is entirely ABSENT (None) is left alone — that is
    # the legitimately-absent + defaulted boundary, and flagging it would
    # collide with the no-config exit-1 path; load.sh's own key-missing
    # exit 2 and mint-token.sh's _cfg_required cover genuinely-missing
    # required values downstream.
    example = {}
    expath = os.environ.get('NEXUS_EXAMPLE_PATH', '')
    if expath and os.path.isfile(expath):
        with open(expath) as f:
            example = yaml.safe_load(f) or {}

    def _dig(d, dotted):
        cur = d
        for part in dotted.split('.'):
            if not isinstance(cur, dict) or part not in cur:
                return None
            cur = cur[part]
        return cur

    # (dotted_key, env_override, category, one-line remedy). category
    # 'identity' is the B11 subset; 'bot' is the mint-token credential set
    # added for #311. env_override mirrors the consuming script's own
    # precedence so the EFFECTIVE value is what gets validated.
    required = [
        ('nexus.root',                 'NEXUS_ROOT',                  'identity',
         'absolute path to this nexus checkout'),
        ('github.repo',                'MONITOR_REPO',                'identity',
         'your asset+issue repo, e.g. your-org/yourname-nexus-assets (never your-org/nexus-code)'),
        ('github.user_login',          'MONITOR_USER_LOGIN',          'identity',
         'your GitHub login (the single authorised user)'),
        ('github.bot_app_id',          'NEXUS_BOT_APP_ID',            'bot',
         "your GitHub App's id (App settings page) — a placeholder 401s at mint-token"),
        ('github.bot_installation_id', 'NEXUS_BOT_INSTALLATION_ID',   'bot',
         "the App's installation id on github.repo"),
        ('github.bot_pem_path',        'NEXUS_BOT_PRIVATE_KEY_PATH',  'bot',
         "path to the App's RSA private key file (chmod 600)"),
    ]
    want = {'identity'} if key == '--check-identity' else {'identity', 'bot'}

    bad = []
    for rkey, envvar, cat, remedy in required:
        if cat not in want:
            continue
        override = os.environ.get(envvar)
        effective = override if override else _dig(cfg, rkey)
        # Absent (None) is left to the "legitimately-absent + defaulted"
        # boundary and the no-config exit-1 path — not flagged here. But a
        # key that IS present and resolves empty/whitespace is "set to a
        # non-real value", which is the operator's #311 intent just as much
        # as a leftover placeholder, so flag it too. (A real config never
        # has empty required values, so this carries no false-positive
        # risk; mint-token.sh independently dies on empty bot creds.)
        if effective is None:
            continue
        if str(effective).strip() == '':
            bad.append((rkey, '(empty)', remedy))
            continue
        placeholder = _dig(example, rkey)
        if placeholder is not None and str(effective) == str(placeholder):
            bad.append((rkey, str(effective), remedy))

    if bad:
        what = 'nexus identity' if key == '--check-identity' else 'nexus config'
        print(f"load.sh: REFUSING — {what} is unconfigured "
              "(placeholder or empty required values; placeholders are the "
              "values shipped in config/nexus.example.yml):", file=sys.stderr)
        for rkey, val, remedy in bad:
            print(f"    {rkey} = {val}", file=sys.stderr)
            print(f"        -> set to {remedy}", file=sys.stderr)
        print(f"  resolved config: {path}", file=sys.stderr)
        print("  Copy config/nexus.example.yml to config/nexus.yml (chmod 600) and fill in",
              file=sys.stderr)
        print("  every value — see the example file's header and monitor/BOT_SETUP.md.",
              file=sys.stderr)
        sys.exit(4)
    sys.exit(0)

cur = cfg
for part in key.split('.'):
    if not isinstance(cur, dict) or part not in cur:
        cur = None
        break
    cur = cur[part]

if cur is None:
    if default != '__NEXUS_NO_DEFAULT__':
        print(default)
        sys.exit(0)
    print(f"load.sh: key not found and no default: {key}", file=sys.stderr)
    sys.exit(2)

s = _stringify(cur)
if s.startswith('~'):
    s = os.path.expanduser(s)
print(s)
PY
