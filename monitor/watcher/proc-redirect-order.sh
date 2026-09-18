#!/usr/bin/env bash
# proc-redirect-order.sh — enumerate every REDIRECTION-ORDER site in this repo
# (your-org/nexus-code#1305), so the boundary is CHECKABLE rather than asserted
# in a commit message.
#
# Usage:  bash monitor/watcher/proc-redirect-order.sh [--files] [<repo-root>]
#   default   one row per site:  <file>\t<line>\t<code>
#   --files   the POPULATION — one path per line, every file this classifier
#             reads. The guard's `gp_population` calls THIS rather than keeping
#             a second copy: a second implementation of a population drifts
#             until the index reports, with total confidence, that a guard does
#             not read a file it does read.
#
# The population is EVERY SHELL FILE, decided by the shared predicate
# `monitor/shell-files.sh:shf_is_shell` and never by a filename glob. That is
# the rule `#1214` had to learn twice: a `*.sh` pathspec cannot see
# `monitor/ng`, a shell file by SHEBANG with no extension, and the most
# important member of a population is exactly the one a glob misses.
set -uo pipefail

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT="${2:-${1:-}}"
[[ "${ROOT:-}" == --* ]] && ROOT=""
ROOT="${ROOT:-$(cd "$_dir/../.." && pwd)}"
AWKF="$_dir/_proc_redirect_order.awk"

# shellcheck source=/dev/null
. "$ROOT/monitor/shell-files.sh"

_population() {
    local f
    while IFS= read -r -d '' f; do
        printf '%s\n' "${f#"$ROOT"/}"
    done < <(shf_find0 "$ROOT" shell)
}

if [[ "${1:-}" == --files ]]; then
    _population
    exit 0
fi

cd "$ROOT" || exit 1
_pop=$(_population)
# A vacuous population is a REFUSAL, not a green (your-org/nexus-code#1268):
# an empty file list produces zero sites, which reads exactly like a clean tree.
if [[ -z "$_pop" ]]; then
    printf 'proc-redirect-order: the shell-file population is EMPTY — refusing to report zero sites from a population I could not build.\n' >&2
    exit 3
fi
# ONE awk invocation over the whole population, not one per file. `awk` sets
# FILENAME per input, so batching costs nothing in accuracy and is the
# difference between ~1s and ~2min over 600 files — a guard slow enough to be
# skipped is a guard that does not run.
_files=()
while IFS= read -r f; do [[ -f "$f" ]] && _files+=("$f"); done <<<"$_pop"
(( ${#_files[@]} > 0 )) || {
    printf 'proc-redirect-order: no readable file in the population — refusing to report zero.\n' >&2
    exit 3
}
# `xargs` bounds the argument list on a large tree; `-print0`-style NUL framing
# is not available from an array, so chunk explicitly.
_i=0
while (( _i < ${#_files[@]} )); do
    awk -f "$AWKF" "${_files[@]:_i:400}"
    _i=$(( _i + 400 ))
done
