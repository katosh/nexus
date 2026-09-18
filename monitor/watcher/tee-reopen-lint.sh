#!/usr/bin/env bash
# tee-reopen-lint.sh — flag every construct that REOPENS an already-open
# standard stream by PATH, because an open of a regular file TRUNCATES it
# (your-org/nexus-code#1490).
#
# Usage:  bash monitor/watcher/tee-reopen-lint.sh [--files] [<repo-root>]
#   default   one row per site:  <file>:<line>\t<code>;  exit 1 if any, 0 if none
#   --files   the POPULATION — one path per line, every file this lint reads.
#             The guard's `gp_population` calls THIS rather than keeping a
#             second copy: a second implementation of a population drifts until
#             the index reports, with total confidence, that a guard does not
#             read a file it does read.
#
# ---------------------------------------------------------------------------
# THE DEFECT
# ---------------------------------------------------------------------------
#
# `/dev/stderr` is a PATH that resolves to whatever fd 2 currently points at.
# Writing to it through a construct that OPENS a path — `tee <path>`, or a
# truncating `> <path>` — performs a fresh `open(O_TRUNC)`, and the `>>` a
# service was launched with governs the ORIGINAL open, not this one. So a
# service started `>>"$log" 2>&1` loses its whole history on the FIRST line it
# emits, at rc 0, with nothing on stderr to say so.
#
# `tmpfs-guard` was the measured host: a guard whose entire job is to describe
# an ACCUMULATING condition over time, destroying its own evidence on every
# finding. A seeded 40-line log came back as 1 line.
#
# ---------------------------------------------------------------------------
# THE AXIS — MEASURED, not assumed. Each row below was run on this host.
# ---------------------------------------------------------------------------
#
#   echo new | tee /dev/stderr >/dev/null     40 -> 1    TRUNCATES
#   echo new | tee /dev/fd/2   >/dev/null     40 -> 1    TRUNCATES
#   echo new >/dev/stderr                     40 -> 1    TRUNCATES  <- a plain
#                                                                      redirect,
#                                                                      not tee
#   echo new >>/dev/stderr                    40 -> 41   safe (append open)
#   echo new | tee -a /dev/stderr >/dev/null  40 -> 41   safe (append open)
#   echo new >&2                              40 -> 41   safe (DUPs the fd —
#                                                        no open at all)
#
# The third row is why this lint is not spelled "no `tee /dev/stderr`". The
# issue that prompted it named `tee`; the same truncation is one character of
# redirection away, and a lint keyed on the tool would certify the redirect
# form clean. The property is REOPENING BY PATH, and `tee` is one way to do it.
#
# `>&2` is the remedy in almost every case: it DUPLICATES the descriptor and
# opens nothing, so no truncation is possible. `tee -a` / `>>` are the remedy
# when a path really must be opened.
#
# ---------------------------------------------------------------------------
# THE POPULATION is EVERY SHELL FILE, decided by the shared predicate
# `monitor/shell-files.sh:shf_is_shell` and never by a filename glob — a
# `*.sh` pathspec cannot see `monitor/ng`, a shell file by SHEBANG with no
# extension, and the most important member of a population is exactly the one
# a glob misses.
#
# COMMENTS AND HEREDOC BODIES ARE STRIPPED before scanning, because this very
# file documents the defect in its own prose and a lint that flags its own
# explanation is a lint with a hole shaped like its author. Both strippers
# preserve LINE COUNT, so the reported line numbers are the file's own.
set -uo pipefail

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT="${2:-${1:-}}"
[[ "${ROOT:-}" == --* ]] && ROOT=""
ROOT="${ROOT:-$(cd "$_dir/../.." && pwd)}"

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
    printf 'tee-reopen-lint: the shell-file population is EMPTY — refusing to report zero sites from a population I could not build.\n' >&2
    exit 3
fi

# CHEAP PRE-FILTER, and it is sound in the only direction that matters: the
# strippers can only REMOVE text, never introduce a match, so a file holding
# none of the four fd-path spellings ANYWHERE — comments included — cannot
# yield a hit after stripping. Skipping it changes no verdict. Measured on
# this tree: 43.2 s over the whole population against 1.4 s with the filter,
# and a lint slow enough to be skipped is a lint that does not run.
#
# The filter runs `grep` through `xargs`, NEVER a recursive grep and never the
# shell's `grep` function: `xargs` execs a program, so the ugrep wrapper that
# honours .gitignore is not in play (CLAUDE.md / #618, #707).
_candidates=$(
    printf '%s\n' "$_pop" \
      | tr '\n' '\0' \
      | xargs -0 -r grep -lF -e '/dev/stderr' -e '/dev/stdout' -e '/dev/fd/' -e '/proc/self/fd/' 2>/dev/null \
      | sort -u
)

_hits=0
_scratch=$(mktemp -d) || {
    printf 'tee-reopen-lint: could not allocate a scratch dir — refusing to report zero.\n' >&2
    exit 3
}
trap 'rm -rf "$_scratch"' EXIT

# TEST THE PRODUCER'S RC, and do it for BOTH strippers.
#
# This was a measured silent zero in this very file's first draft. Run against
# a fixture tree lacking `monitor/watcher/_shell_quotes.awk`, `shf_strip_comments`
# REFUSED — correctly, loudly, exit non-zero — the diagnostic went to a
# `2>/dev/null`, the stripped text was EMPTY, and the lint reported a clean
# sweep over a tree containing two known violations. Nothing errored. The
# refusal was not lost; it was merely OFF THE PATH that produced the answer,
# which is all a silent zero needs.
# ONE stripper, not two. `shf_strip_comments` BLANKS HEREDOC BODIES FIRST
# (your-org/nexus-code#1227) and then removes comment text, so a preceding
# `shf_strip_heredocs` pass is redundant — and worse than redundant: re-running
# the heredoc scanner over already-blanked source made it report `heredoc
# unterminated at EOF` and emit the file UNSTRIPPED, i.e. the belt-and-braces
# pass DEFEATED the stripping it was added to reinforce.
_strip() {   # <file> -> stripped text on stdout; non-zero (and a diagnostic) on failure
    shf_strip_comments "$1"
}

while IFS= read -r f; do
    [[ -n "$f" && -f "$f" ]] || continue
    if ! _strip "$f" > "$_scratch/s"; then
        printf 'tee-reopen-lint: REFUSED — could not strip %s (see the stripper diagnostic above).\n' "$f" >&2
        printf '  A file this lint cannot read is NOT a file it can certify clean.\n' >&2
        exit 3
    fi
    while IFS= read -r row; do
        printf '%s:%s\n' "$f" "$row"
        _hits=$(( _hits + 1 ))
    done < <(
        awk '
            # An fd PATH: the three spellings that name an already-open stream.
            function is_fd_path(s) {
                return (s ~ /^\/dev\/(stderr|stdout)$/ \
                     || s ~ /^\/dev\/fd\/[0-9]+$/ \
                     || s ~ /^\/proc\/self\/fd\/[0-9]+$/)
            }
            {
                line = $0
                # --- form 1: tee, WITHOUT an append flag, given an fd path.
                # Scan token-wise so `tee -a` and `tee --append` are excluded
                # by what they ARE rather than by a regex lookahead, which BRE
                # and ERE both lack. A denylist of spellings would have a
                # permissive default arm; this reads the flags it is given.
                n = split(line, tok, /[ \t]+/)
                for (i = 1; i <= n; i++) {
                    t = tok[i]
                    sub(/^[|;&(]+/, "", t)
                    if (t != "tee") continue
                    append = 0
                    for (j = i + 1; j <= n; j++) {
                        a = tok[j]
                        gsub(/["\x27]/, "", a)
                        # Shell punctuation rides on the last token of a
                        # command: `tee /dev/stderr; return 3` splits to
                        # `/dev/stderr;`, which is not equal to any fd path.
                        # THE FIRST DRAFT MISSED ONE OF THE TWO REAL SITES
                        # FOR EXACTLY THIS REASON, and the miss was invisible
                        # because the other site matched — a SHORT COUNT, not
                        # a zero, so nothing looked wrong.
                        sub(/[;)&|}]+$/, "", a)
                        if (a ~ /^--append$/) { append = 1; continue }
                        if (a ~ /^-[A-Za-z]*a[A-Za-z]*$/) { append = 1; continue }
                        if (a ~ /^-/) continue
                        if (is_fd_path(a) && !append) { print NR ":" line; next }
                        # KEEP SCANNING PAST AN ORDINARY FILE ARGUMENT.
                        # `tee` takes MANY files, and `tee "$LOG" /dev/stderr`
                        # — log it and echo it — is the idiom a reader reaches
                        # for; it truncates exactly like the one-argument form.
                        # An earlier draft stopped at the first non-flag word
                        # that was not an fd path and could not see it: a
                        # silent zero in a lint written to catch silent zeros.
                        # Measured on this tree when the gap was closed: the
                        # wider predicate finds the SAME zero hits, so nothing
                        # here changes today and the coverage is for the next
                        # site rather than a current one.
                        #
                        # The scan stops at a SHELL SEPARATOR, so a `/dev/stderr`
                        # belonging to a LATER command on the same line is not
                        # attributed to this `tee`.
                        if (a ~ /[|;&]/ || a ~ /^[0-9]*[<>]/) break
                    }
                }
                # --- form 2: a TRUNCATING redirect to an fd path. `>>` and
                # `>&` are excluded by the character AFTER the `>`; a leading
                # digit (`2>`) is still a truncating open and IS in scope.
                s = line
                while (match(s, />[ \t]*\/(dev\/(stderr|stdout)|dev\/fd\/[0-9]+|proc\/self\/fd\/[0-9]+)/)) {
                    pre = substr(s, 1, RSTART - 1)
                    # `>>` : the character before the matched `>` is another `>`
                    if (pre ~ />$/) { s = substr(s, RSTART + RLENGTH); continue }
                    print NR ":" line
                    next
                }
            }' "$_scratch/s"
    )
done <<<"$_candidates"

if (( _hits > 0 )); then
    printf '\ntee-reopen-lint: %d site(s) REOPEN an already-open stream BY PATH.\n' "$_hits" >&2
    printf '  An open of a regular file TRUNCATES it, so a service launched\n' >&2
    printf '  `>>"$log" 2>&1` loses its whole history on the first line emitted\n' >&2
    printf '  (your-org/nexus-code#1490 — measured: 40 lines -> 1).\n' >&2
    printf '  Fix: `>&2` DUPLICATES the descriptor and opens nothing. Where a path\n' >&2
    printf '  genuinely must be opened, use the APPEND form (`tee -a`, `>>`).\n' >&2
    exit 1
fi
exit 0
