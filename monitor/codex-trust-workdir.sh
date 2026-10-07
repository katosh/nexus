#!/usr/bin/env bash
# monitor/codex-trust-workdir.sh <workdir> [--codex-home DIR]
#
# Persist Codex's folder trust for <workdir> in $CODEX_HOME/config.toml
# (your-org/nexus-code#1640) — the Codex analogue of
# monitor/ensure-workdir-trusted.sh for Claude Code.
#
# WHY IT MUST BE PERSISTED. Measured on codex-cli 0.156.1: a new workdir
# raises a blocking `Trust this folder?` dialog, and neither
# `-c 'projects."<dir>".trust_level="trusted"'` nor
# --dangerously-bypass-approvals-and-sandbox suppresses it; only the table
# Codex itself writes when the operator accepts does:
#
#     [projects."<absolute workdir>"]
#     trust_level = "trusted"
#
# That is exactly what this writes, and nothing else: an existing table for
# the path has its trust_level set (inserted if missing); otherwise the table
# is appended. Every other byte of config.toml is preserved. Idempotent;
# serialised with flock; written via a temp file + rename so a concurrent
# reader never sees half a file.
#
# Exit: 0 trusted (already or now) · 1 could not write · 2 usage
set -uo pipefail

wd="" home="${CODEX_HOME:-$HOME/.codex}"
while (( $# )); do
    case "$1" in
        --codex-home) [[ $# -ge 2 ]] || { echo "codex-trust-workdir: --codex-home needs a value" >&2; exit 2; }; home="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
        -*) echo "codex-trust-workdir: unknown option $1" >&2; exit 2 ;;
        *)  [[ -z "$wd" ]] || { echo "codex-trust-workdir: one workdir only" >&2; exit 2; }; wd="$1"; shift ;;
    esac
done
[[ -n "$wd" ]] || { echo "usage: codex-trust-workdir.sh <workdir> [--codex-home DIR]" >&2; exit 2; }
[[ -d "$wd" ]] || { echo "codex-trust-workdir: not a directory: $wd" >&2; exit 2; }
wd=$(cd "$wd" && pwd -P)
mkdir -p "$home" 2>/dev/null || { echo "codex-trust-workdir: cannot create CODEX_HOME $home" >&2; exit 1; }
cfg="$home/config.toml"

(
    flock -w 20 9 || { echo "codex-trust-workdir: lock busy on $cfg.lock" >&2; exit 1; }
    python3 - "$cfg" "$wd" <<'PY'
import os, sys, tempfile
cfg, wd = sys.argv[1], sys.argv[2]
esc = wd.replace('\\', '\\\\').replace('"', '\\"')
header = '[projects."%s"]' % esc
try:
    with open(cfg) as fh:
        lines = fh.read().splitlines()
except FileNotFoundError:
    lines = []
out, i, found = [], 0, False
while i < len(lines):
    ln = lines[i]
    if ln.strip() == header:
        found = True
        out.append(ln)
        at = len(out)              # first line of this table's body
        i += 1
        wrote = False
        while i < len(lines) and not lines[i].lstrip().startswith('['):
            if lines[i].split('=')[0].strip() == 'trust_level':
                out.append('trust_level = "trusted"')
                wrote = True
            else:
                out.append(lines[i])
            i += 1
        if not wrote:
            out.insert(at, 'trust_level = "trusted"')
        continue
    out.append(ln)
    i += 1
if not found:
    if out and out[-1].strip():
        out.append('')
    out.extend([header, 'trust_level = "trusted"'])
text = '\n'.join(out) + '\n'
try:
    old = open(cfg).read()
except FileNotFoundError:
    old = None
if text == old:
    sys.exit(0)
d = os.path.dirname(cfg) or '.'
fd, tmp = tempfile.mkstemp(prefix='.config.toml.', dir=d)
with os.fdopen(fd, 'w') as fh:
    fh.write(text)
if old is not None:
    os.chmod(tmp, os.stat(cfg).st_mode & 0o7777)
else:
    os.chmod(tmp, 0o600)
os.replace(tmp, cfg)
PY
) 9>"$cfg.lock"
rc=$?
(( rc == 0 )) || { echo "codex-trust-workdir: failed to persist trust for $wd in $cfg (rc $rc)" >&2; exit 1; }
exit 0
