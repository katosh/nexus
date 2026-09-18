#!/usr/bin/env bash
# monitor/boot-recover-hook-check.sh — is the cold-boot recovery hook ARMED?
#
# WHY THIS EXISTS AND WHY IT IS NOT CEREMONY (your-org/nexus-code#1174).
#
# `monitor/boot-recover.session-start-hook.json` is a template every operator
# copies into their own `settings.json`. It used to ship one operator's
# absolute path; on any other host that path does not exist and the cold-boot
# recovery trigger simply never fires. The consequence is an ABSENCE — the
# nexus stack is not checked when the orchestrator session is brought back —
# and the operator's evidence that the hook works is that their session
# started normally, which it would either way.
#
# `#1174` guessed that a PLACEHOLDER would make a verbatim copy fail visibly at
# the first fire, and left the question open. Measured on Claude Code 2.1.246
# (mock backend, throwaway CLAUDE_CONFIG_DIR, a positive control that fired):
#
#   SILENT on every channel a `-p` caller or a human sees by default —
#     stdout 3 B, stderr 157 B (an unrelated stdin warning), rc 0, all
#     byte-identical to running with no hooks at all.
#   RECORDED on three channels nobody looks at:
#     * the session transcript, with NO flags: one extra `attachment` of
#       subtype `async_hook_response` carrying hookName, hookEvent, stderr and
#       exitCode 127. `async: false` is louder still — `hook_non_blocking_error`,
#       and it carries the `command` verbatim.
#     * `--output-format stream-json --verbose`: `hook_started` + `hook_response`
#       with `"outcome":"error"`.
#     * `--debug-file <path>`: an explicit
#       `Hook SessionStart:startup (SessionStart) error:`.
#
# So the honest scope is "silent where anyone looks", NOT "completely silent" —
# and an earlier version of this header said the latter on the strength of a
# `--debug` arm that was an EMPTY INSTRUMENT: `--debug` routes nothing in `-p`
# mode, so its 160 bytes name no hook in EVERY arm INCLUDING THE WORKING ONE.
# The positive control proved the HOOK fired; it could not prove the INSTRUMENT
# reported, because it was read through the same dead channel.
#
#   A POSITIVE CONTROL ON THE SUBJECT IS NOT A POSITIVE CONTROL ON THE
#   OBSERVER. A negative scoped to one output channel is not a negative.
#
# A check outside the session is still the right mechanism, because none of the
# three recording channels is on by default and none is a stable contract. This
# is it. It reads settings files READ-ONLY and never edits them.
#
# WHAT IT ASSERTS IS IDENTITY, NOT EXECUTABILITY. An earlier version asked only
# "is some SessionStart command executable?", so `/bin/true` as the only hook
# reported ARMED rc 0 while `boot-recover.sh` was wired nowhere — `#1174`
# regenerated inside its own remedy, and a checker that says ARMED when nothing
# is armed is worse than no checker. The question is "is COLD-BOOT RECOVERY
# armed", so the wired command must actually BE `boot-recover.sh`.
#
# USAGE
#   monitor/boot-recover-hook-check.sh                 # check $CLAUDE_CONFIG_DIR
#   monitor/boot-recover-hook-check.sh --settings <f>  # check one settings file
#   monitor/boot-recover-hook-check.sh --quiet
#
# EXIT CODES — and 1 vs 4 is the distinction that matters, because they are
# repaired in different places:
#   0  ARMED       — a SessionStart hook runs an existing, executable
#                    `boot-recover.sh`
#   1  NOT ARMED   — hooks are wired, but none of them arms `boot-recover.sh`:
#                    the command is missing / not executable / still the
#                    un-replaced <YOUR_NEXUS_ROOT> placeholder / is some
#                    OTHER command entirely
#   3  UNDETERMINED— could not read the settings (no file, unreadable, not
#                    JSON, no python3). NOT the same as "not armed": an
#                    unreadable settings file says nothing about the hook.
#   5  ARMED ELSEWHERE — a hook runs a script that carries the nexus cold-boot
#                    marker, so recovery IS armed — for a DIFFERENT nexus, not
#                    this checkout. Its own code, and said on STDERR, because
#                    this used to be an rc-0 NOTE on stdout that `--quiet`
#                    suppressed and an rc-reading caller never saw
#                    (your-org/nexus-code#1247 (b)).
#   4  ABSENT      — settings read fine and declare no SessionStart hook at
#                    all. Distinct from 1 on purpose: 1 means you wired it and
#                    the path is wrong; 4 means you never wired it.
#   2  usage

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# WHICH nexus root the repair text should name. Run from a secondary clone
# (`<primary>/work/<project>-<task>/`, the prescribed shape for watcher work),
# a bare `$_self_dir/..` names THE THROWAWAY CLONE — so the advice would be
# "wire your cold-boot recovery to a directory that is about to be deleted".
# `nexus_primary_root` is the repo's one resolver for this (your-org/nexus-code#577,
# #1077); using a second copy of the logic is the defect those issues are about.
# shellcheck source=_nexus-root.sh
. "$_self_dir/_nexus-root.sh"
_NEXUS_PRIMARY=$(nexus_primary_root "$(cd "$_self_dir/.." && pwd)")
_EXPECT_BIN="$_NEXUS_PRIMARY/monitor/boot-recover.sh"
_EXPECT_NAME=boot-recover.sh
# The OWNED marker `monitor/boot-recover.sh` carries. Assembled rather than
# written whole so this file does not itself match a grep for it.
_MARKER='NEXUS-COLD-BOOT-RECOVERY''-MARKER'

# `realpath` is not on every host and `readlink -f` is GNU; fall back to the
# literal string rather than silently comparing nothing.
_realpath() {
    if command -v realpath >/dev/null 2>&1; then realpath -- "$1" 2>/dev/null || printf '%s' "$1"
    elif readlink -f -- "$1" >/dev/null 2>&1;  then readlink -f -- "$1"
    else printf '%s' "$1"; fi
}

QUIET=0
SETTINGS=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --quiet)    QUIET=1; shift ;;
        --settings) SETTINGS="${2-}"; shift 2 || { echo "--settings needs a path" >&2; exit 2; } ;;
        -h|--help)  sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
        *)          echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

if [ -z "$SETTINGS" ]; then
    _cfg_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    SETTINGS="$_cfg_dir/settings.json"
fi

command -v python3 >/dev/null 2>&1 || {
    err "boot-recover-hook-check: no python3 — cannot parse $SETTINGS. UNDETERMINED, not 'not armed'."
    exit 3
}
[ -r "$SETTINGS" ] || {
    err "boot-recover-hook-check: cannot read $SETTINGS. UNDETERMINED, not 'not armed'."
    exit 3
}

# The parse prints one `key<TAB>value` record per wired SessionStart command,
# or a single `PARSE_ERROR` line. ITS EXIT STATUS IS TESTED (#926 mode 2): a
# producer whose rc is never consulted leaves an empty intermediate, and the
# count that follows is then produced by later steps that each succeed on
# their own terms — a plausible zero meaning "no hook found" when what
# happened is that nothing was ever read.
_records=$(python3 - "$SETTINGS" <<'PY'
import json, os, shlex, sys

EXPECT_NAME = "boot-recover.sh"

def resolve_bin(cmd):
    """The executable a shell would actually run, and the boot-recover.sh
    inside it if there is one.

    `${cmd%% *}` — what this used to do in bash — truncates at the first
    SPACE, so a QUOTED path containing one names a truncated path, and an
    `sh -c 'exec .../boot-recover.sh'` wrapper names `sh`
    (your-org/nexus-code#1247 (a); the same class `#1243` fixed in
    repo-root.sh). shlex.split applies the shell's OWN quoting rules.

    The `-c` ARGUMENT is re-split and is NOT itself a candidate. Both halves
    of that matter, and each was measured wrong on its own:
      * without the re-split, `sh -c 'exec X'` resolves to `sh`;
      * with the argument left in as a candidate, `os.path.basename` — which
        splits on "/" ONLY — reports `boot-recover.sh` for the whole STRING
        "exec /a/boot-recover.sh", so the resolved "path" is a command line
        and the -e test then reports a correctly wired hook as missing.
    Scoping the re-split to `-c` also leaves a legitimately SPACE-BEARING
    quoted path intact, which a blanket "re-split any token with whitespace"
    rule shreds into two non-existent paths."""
    try:
        toks = shlex.split(cmd)
    except ValueError:
        toks = cmd.split()
    cands, i = [], 0
    while i < len(toks):
        if toks[i] in ("-c", "-lc", "-cl") and i + 1 < len(toks):
            try:
                cands.extend(shlex.split(toks[i + 1]))
            except ValueError:
                cands.extend(toks[i + 1].split())
            i += 2
            continue
        cands.append(toks[i])
        i += 1
    for c in cands:
        if os.path.basename(c) == EXPECT_NAME:
            return c
    return toks[0] if toks else ""

try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception as e:
    print("PARSE_ERROR\x1f%s" % e)
    sys.exit(0)
if not isinstance(d, dict):
    print("PARSE_ERROR\x1ftop level is not an object")
    sys.exit(0)
for group in (d.get("hooks") or {}).get("SessionStart") or []:
    matcher = group.get("matcher", "")
    for h in group.get("hooks") or []:
        if h.get("type") != "command":
            continue
        cmd = h.get("command", "")
        # \x1f (UNIT SEPARATOR), not TAB. Tab is IFS *whitespace*, so bash
        # COLLAPSES a run of them and drops empty fields: a hook with no
        # `matcher` — which Claude Code permits, the field is optional —
        # emitted `CMD\t\tFalse\t<cmd>`, and `IFS=$'\t' read` shifted every
        # field left, leaving the COMMAND in `_async` and `_cmd` EMPTY. The
        # tool then reported OTHER / NOT ARMED for a correctly wired hook, and
        # could not report ARMED for ANY matcher-less configuration. Fail-safe
        # in direction, total as a blind spot. \x1f is not IFS whitespace, so
        # empty fields survive.
        print("CMD\x1f%s\x1f%s\x1f%s\x1f%s"
              % (matcher, h.get("async", False), cmd, resolve_bin(cmd)))
PY
)
_rc=$?
if [ "$_rc" -ne 0 ]; then
    err "boot-recover-hook-check: settings parse exited $_rc — UNDETERMINED."
    exit 3
fi

case "$_records" in
    PARSE_ERROR*)
        err "boot-recover-hook-check: $SETTINGS is not usable JSON: ${_records#PARSE_ERROR}"
        err "  UNDETERMINED — this says nothing about whether the hook is armed."
        exit 3 ;;
esac

if [ -z "$_records" ]; then
    err "boot-recover-hook-check: NO SessionStart command hook in $SETTINGS."
    err "  Nothing will run when the orchestrator session is brought back."
    err "  Wire monitor/boot-recover.session-start-hook.json, replacing"
    err "  <YOUR_NEXUS_ROOT> with $_NEXUS_PRIMARY."
    exit 4
fi

_n=0 _bad=0 _good=0 _other=0 _elsewhere=0
while IFS=$'\x1f' read -r _tag _matcher _async _cmd _bin; do
    [ "$_tag" = CMD ] || continue
    _n=$(( _n + 1 ))
    # $_bin was resolved by the parser with the shell's own quoting rules —
    # see resolve_bin() above. Nothing here splits a command string.

    # IDENTITY FIRST. A hook that is not about cold-boot recovery is neither
    # armed nor broken — it is somebody else's hook, and counting it as ARMED
    # is the false clearance this tool was rebuilt to remove. The placeholder
    # is checked before the identity test because an unreplaced placeholder DOES
    # name boot-recover.sh and IS this tool's business.
    case "$_cmd" in
        *'<YOUR_NEXUS_ROOT>'*)
            _bad=$(( _bad + 1 ))
            err "  NOT ARMED  matcher=${_matcher:-<any>} async=$_async"
            err "             the <YOUR_NEXUS_ROOT> placeholder was never replaced:"
            err "             $_cmd"
            err "             Claude Code will run it, fail to find it, and say"
            err "             nothing on any channel you are looking at."
            continue ;;
    esac
    if [ "$(basename -- "$_bin")" != "$_EXPECT_NAME" ]; then
        _other=$(( _other + 1 ))
        say "  OTHER      matcher=${_matcher:-<any>} async=$_async  ->  $_bin"
        say "             not $_EXPECT_NAME; this tool has nothing to say about it"
        continue
    fi
    if [ ! -e "$_bin" ]; then
        _bad=$(( _bad + 1 ))
        err "  NOT ARMED  matcher=${_matcher:-<any>} async=$_async"
        err "             command does not exist: $_bin"
        err "             Claude Code will run it, fail to find it, and say"
        err "             nothing on any channel you are looking at."
    elif [ ! -x "$_bin" ]; then
        _bad=$(( _bad + 1 ))
        err "  NOT ARMED  matcher=${_matcher:-<any>} async=$_async"
        err "             command exists but is NOT EXECUTABLE: $_bin"
    elif [ "$(_realpath "$_bin")" = "$(_realpath "$_EXPECT_BIN")" ]; then
        _good=$(( _good + 1 ))
        say "  ARMED      matcher=${_matcher:-<any>} async=$_async  ->  $_bin"
    elif grep -qa -e "$_MARKER" -- "$_bin" 2>/dev/null; then
        # `-e` declares the PATTERN and `--` ends option parsing: a pattern or a
        # path beginning with `-` is otherwise consumed as a flag, silently
        # (CLAUDE.md, DASH-PATTERN-OPTION).
        # A DIFFERENT nexus's boot-recover.sh. Legitimate — more than one nexus
        # on a host — but it does NOT arm THIS checkout, and the commonest way
        # to get one is to have wired a throwaway clone. Its own exit code, and
        # on STDERR: this used to be a NOTE on stdout, which `--quiet`
        # suppresses and a caller reading only the exit code never sees, so the
        # documented contract ("treat its exit code as the evidence that
        # recovery is armed") was satisfied by another nexus's script.
        _elsewhere=$(( _elsewhere + 1 ))
        err "  ELSEWHERE  matcher=${_matcher:-<any>} async=$_async  ->  $_bin"
        err "             carries the nexus cold-boot marker, so it IS a"
        err "             recovery trigger — but not THIS checkout's."
        err "             Expected: $_EXPECT_BIN"
    else
        # IDENTITY BY OWNED MARKER, NOT BY BASENAME (your-org/nexus-code#1247 (b)).
        # A two-line `#!/bin/sh\nexit 0` named boot-recover.sh, anywhere on the
        # host, used to report ARMED rc 0 — a predicate keyed on a NAME standing
        # in for the PROPERTY, which is the shape this tool was rebuilt to
        # remove, one level in. A copy predating the marker reads as an impostor
        # here; that is deliberate fail-closed, and the message says so, because
        # a checker that says ARMED when nothing is armed is worse than none.
        _bad=$(( _bad + 1 ))
        err "  NOT ARMED  matcher=${_matcher:-<any>} async=$_async  ->  $_bin"
        err "             named $_EXPECT_NAME but does NOT carry the nexus"
        err "             cold-boot marker, so it is not a recovery trigger:"
        err "             this tool cannot vouch for what it would run."
        err "             Expected: $_EXPECT_BIN"
    fi
done <<EOF
$_records
EOF

# A COUNT THAT COULD NOT HAVE BEEN PRODUCED BY THE RECORDS IS NOT A VERDICT.
# `$_records` was non-empty above, so at least one CMD line must have been
# consumed; zero here means the loop never ran and every branch below would be
# vacuously satisfied.
if [ "$_n" -eq 0 ]; then
    err "boot-recover-hook-check: records were present but none parsed as CMD — UNDETERMINED."
    exit 3
fi

say "boot-recover-hook-check: $SETTINGS — $_good armed, $_bad not armed, $_elsewhere elsewhere, $_other other, $_n SessionStart command hook(s)"

# ARMED requires a hook that actually RUNS boot-recover.sh. "No broken ones"
# is not the same statement and was the false clearance: with `/bin/true` as
# the only hook, `_bad` is 0 and nothing is armed.
if [ "$_good" -gt 0 ] && [ "$_bad" -eq 0 ]; then
    exit 0
fi
if [ "$_good" -gt 0 ]; then
    err "boot-recover-hook-check: $_good armed but $_bad BROKEN — treating as NOT ARMED."
    exit 1
fi
if [ "$_bad" -eq 0 ] && [ "$_elsewhere" -gt 0 ]; then
    err "boot-recover-hook-check: ARMED ELSEWHERE — $_elsewhere hook(s) run a nexus"
    err "  cold-boot trigger, but none of them is this checkout's."
    err "  Expected command: $_EXPECT_BIN"
    exit 5
fi
err "boot-recover-hook-check: NOT ARMED — no SessionStart hook runs $_EXPECT_NAME."
if [ "$_other" -gt 0 ]; then
    err "  $_other SessionStart hook(s) are wired, but none of them is cold-boot recovery."
    err "  A hook running SOMETHING is not this hook running: splice"
    err "  monitor/boot-recover.session-start-hook.json in ALONGSIDE them."
fi
err "  Expected command: $_EXPECT_BIN"
exit 1
