#!/usr/bin/env bash
# monitor/cc-harness/lint-no-mass-kill.sh — safety lint for the cc-harness.
#
# Forbids cmdline-pattern process kills in harness code. Every nexus agent
# (orchestrator, every worker, the mock-lab) runs the SAME project-local
# claude binary inside ONE shared sandbox PID namespace. A `pkill -f
# <pattern>` whose pattern matches that binary's command line therefore
# SIGTERMs EVERY agent at once — a full control-plane wipe. That exact line,
# `pkill -f "node_modules/.bin/claude"`, run from the harness absent-state
# test, killed all five live agents on 2026-05-29; see
# reports/nexus_2026-05-29_142117_crash-postmortem-pkill-mass-kill.md.
#
# Rule: harness process kills MUST be PID-scoped — `kill <pid>`, `pkill -P
# <ppid>`, or the recursive descendant-tree walk in cch_kill_claude(). Kills
# that select by command line (`pkill -f` / `pkill --full`, `pgrep -f`,
# `killall`) are banned outright; the harness has no legitimate use for them.
#
# This file excludes ITSELF from the scan, so the patterns named above in its
# own comments/regex do not self-trip the lint.
#
# WHICH FILES (your-org/nexus-code#792). This lint used to enumerate
# `*.sh -o *.py`, which cannot see an extensionless executable — `monitor/ng`,
# `ghwrap/gh`, `pipwrap/pip`, `notifywrap/sandbox-notify` — nor a zsh startup
# file, nor `public-mirror/scrub.pl`. The population is now DERIVED by
# `monitor/shell-files.sh`, shared with `lint-no-tmux-server-kill.sh` and the
# watcher's scope guard, so that one question has one answer.
#
#   The class is `script`, not `shell`, and deliberately so: the ban here is on
#   a TEXT pattern, and `killall` mass-kills identically from perl or python.
#   Its sibling scans `shell` only because that one PARSES shell syntax.
#
#   The exposure that this closed is narrower than the tmux lint's, and saying
#   so is part of the report: as INVOKED (`gate.sh:83`, `cc-harness.yml:194`)
#   the target defaults to `monitor/cc-harness/`, which today holds no
#   extensionless file at all. The hole was therefore latent here and live in
#   the sibling. It is closed anyway, because the reason it was latent is an
#   accident of the current inventory, and `--selftest` now plants the file
#   that makes it live.
#
# Usage:  lint-no-mass-kill.sh [target-dir]   (default: this script's dir)
#         lint-no-mass-kill.sh --selftest     negative control on the file list
# Exit:   0 = clean, 1 = a banned pattern was found (offending lines on stderr).
set -uo pipefail

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
self_base=$(basename "${BASH_SOURCE[0]}")
repo_root=$(cd "$self_dir/../.." && pwd)

SHELL_FILES_LIB="$repo_root/monitor/shell-files.sh"
[[ -r "$SHELL_FILES_LIB" ]] || {
    echo "missing shell-file enumerator: $SHELL_FILES_LIB" >&2; exit 2; }
. "$SHELL_FILES_LIB"

files0() {   # <root> -> NUL-separated script files, minus this lint itself
    local f
    shf_find0 "$1" script | while IFS= read -r -d '' f; do
        [[ "${f##*/}" == "$self_base" ]] && continue
        printf '%s\0' "$f"
    done
}

target="${1:-$self_dir}"

# Banned: pkill/pgrep carrying a command-line-match flag (-f / --full), or
# any `killall`. PID-scoped `pkill -P` / `pgrep -P` are deliberately allowed.
banned_re='(pkill|pgrep)([[:space:]]+[^|&;#]*)?[[:space:]](-f|--full)([[:space:]]|$)|(^|[^[:alnum:]_])killall([[:space:]]|$)'

scan() {   # <root> -> "<file>:<line>:<text>" per violation
  files0 "$1" \
    | while IFS= read -r -d '' f; do
        # Drop full-line comments (leading-whitespace then #) before matching
        # so the ban fires only on real command usage, not documentation.
        grep -nE "$banned_re" "$f" 2>/dev/null \
          | grep -vE '^[0-9]+:[[:space:]]*#' \
          | sed "s|^|$f:|"
      done
}

# ---------------------------------------------------------------------------
# --selftest — NEGATIVE CONTROL ON THE FILE LIST (your-org/nexus-code#792).
#
# The lint's REGEX was already exercised by the tree it runs against. Its FILE
# LIST was not exercised by anything, which is precisely how it stayed blind to
# every extensionless executable in the repo without a single test going red.
#
# Both assertions are POSITIVE — each names a file that must be READ. An
# enumerator broken into returning nothing fails them, where an
# absence-shaped assertion ("no violations found") would sail through. That is
# `#793`(b)'s lesson applied at the site where it was learned.
# ---------------------------------------------------------------------------
selftest() {
    local tmp d out fails=0 passes=0
    tmp=$(mktemp -d) || { echo "selftest: mktemp failed" >&2; return 1; }
    trap 'rm -rf "$tmp"' RETURN

    _ck() { if (( $2 == 0 )); then printf '  PASS: %s\n' "$1"; passes=$((passes+1))
            else printf '  FAIL: %s%s\n' "$1" "${3:+ — $3}" >&2; fails=$((fails+1)); fi; }

    # An extensionless executable, named nothing in this repo enumerates.
    d=$(mktemp -d "$tmp/p.XXXXXX")
    printf '#!/usr/bin/env bash\npkill -f "node_modules/.bin/claude"\n' > "$d/brand-new-tool"
    out=$(scan "$d")
    _ck 'an EXTENSIONLESS shebang executable is scanned (the #792 hole)' \
        $([[ -n "$out" ]] && echo 0 || echo 1) \
        'clean — THE FILE WAS NOT READ AT ALL'

    # perl: the ban is on a text pattern, and `killall` is `killall` in perl.
    d=$(mktemp -d "$tmp/p.XXXXXX")
    printf '#!/usr/bin/env perl\nsystem("killall claude");\n' > "$d/scrub.pl"
    out=$(scan "$d")
    _ck 'a perl script is scanned (class is `script`, not `shell`)' \
        $([[ -n "$out" ]] && echo 0 || echo 1) 'clean — perl not in the population'

    # DISCRIMINATION: same bytes, no shebang, no extension => not a script.
    d=$(mktemp -d "$tmp/p.XXXXXX")
    printf 'pkill -f "node_modules/.bin/claude"\n' > "$d/notes"
    out=$(scan "$d")
    _ck 'a NON-script file with the same bytes is NOT scanned' \
        $([[ -z "$out" ]] && echo 0 || echo 1) "expected unscanned, got: $out"

    # Non-vacuity on the real tree.
    _ck 'the population clears its non-vacuity floor' \
        $(shf_require_floor "$repo_root/monitor" script 300 'lint-no-mass-kill' \
          && echo 0 || echo 1)

    printf '\n  %d pass / %d fail\n' "$passes" "$fails"
    (( fails == 0 )) || return 1
    echo "lint-no-mass-kill: SELFTEST OK"
    return 0
}

if [[ "${1:-}" == --selftest ]]; then selftest; exit $?; fi

hits=$(scan "$target")

if [[ -n "$hits" ]]; then
    {
        echo "LINT FAIL — cmdline-pattern process kill in harness code."
        echo "  This can mass-kill every agent in the shared PID namespace"
        echo "  (crash postmortem 2026-05-29). Use a PID-scoped kill instead:"
        echo "  kill <pid> / pkill -P <ppid> / cch_kill_claude()."
        echo "  Offending lines:"
        echo "$hits"
    } >&2
    exit 1
fi
echo "lint-no-mass-kill: clean ($target)"
