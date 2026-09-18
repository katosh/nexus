#!/usr/bin/env bash
# awk-v-escape-lint.sh — every `awk -v NAME=<shell expansion>` in the shell
# corpus, as a CONSTRUCT lint keyed on the HAZARD, not on the tool's role
# (your-org/nexus-code#1420).
#
# THE CLASS. `awk -v VAR="$value"` ESCAPE-PROCESSES `$value`: `\n`, `\t` and a
# backslash-newline continuation are consumed with NOTHING on stderr, while
# `\d` warns at rc 0. So a caller-supplied string — a message body, a tmux
# window name, a path — arrives inside awk with its bytes changed, and the
# change is silent exactly where it destroys data. Three confirmed members in
# three files (`request-channel.sh`, `skeptic-channel.sh`, `_bookkeeping.sh`),
# fixed one at a time, each found by a live client rather than by a sweep.
#
# THE METHODOLOGICAL FINDING IS WHY THIS IS A LINT AND NOT A LIST. The sweep
# that reported "zero further members" scoped its population on the ROLE of
# the enclosing tool ("non-test tools that read a body") — and the second site
# its own author had just fixed was not a body but a window NAME. A predicate
# that cannot see the instance already in hand is answering a narrower
# question than the one asked, and every zero it returns is about that
# narrower question. So this lint keys on the CONSTRUCT and walks EVERY shell
# file the shared predicate accepts, never a role list and never a `*.sh`
# glob (`monitor/ng` has no extension and is the main CLI; `#1214` got a
# count wrong for exactly that reason).
#
# WHAT IS FLAGGED. On a CODE line (comments stripped by `shf_strip_comments`),
# a `-v NAME=VALUE` whose VALUE begins with a shell expansion — `$x`, `"$x"`,
# `"${x…}"`, `'$x'` (a single-quoted `$` is literal to the shell and is NOT
# flagged), `$(…)` — and which is either on a line that invokes `awk` or on a
# continuation line beneath one. A LITERAL value (`-v x=1`, `-v sep=,`) is
# not caller-supplied and is not flagged. `ENVIRON["x"]` and the
# `( export x; awk … )` shape `#1378` used to fix `_bookkeeping.sh` carry no
# `-v` and are the prescribed substitutes, so they are negative controls by
# construction.
#
# A `-v NAME=$x` inside a quoted STRING on a line that also says `awk` (an
# echo ABOUT awk) is flagged too: the predicate is textual and cannot tell an
# invocation from a mention of one. Rare, and the marker covers it.
#
# WHAT IS NOT CLAIMED. A flagged site is a site where the hazard CAN fire,
# not one where it does: `-v b="$bline"` with a line number in `$bline` is
# flagged and is harmless, because a number holds no backslash. Deciding
# harmlessness needs the value's provenance, which a text lint cannot read.
# That is why this ships ADVISORY — it prints the population, the count and
# every site, and exits 0 — and why `--strict` exists as the polarity flip
# for the day the corpus is cleaned or the harmless sites are annotated.
# (A `# awk-v-escape-lint: literal-only — <reason>` comment on the same line
# exempts a site, reason REQUIRED, exempted sites are counted and printed.)
#
# Usage:
#   awk-v-escape-lint.sh                 advisory: report, exit 0
#   awk-v-escape-lint.sh --strict        exit 1 when any UNEXEMPTED site remains
#   awk-v-escape-lint.sh --files         the population, one path per line
#   awk-v-escape-lint.sh --population    the `--population` protocol (#803)
#   awk-v-escape-lint.sh --scan FILE...  scan explicit files (fixtures/tests)
#
# Exit: 0 clean, or advisory; 1 --strict with unexempted sites; 3 the
# population is EMPTY (refusing to report a clean sweep over nothing).

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$_self_dir/../.." && pwd)

# shellcheck disable=SC1091
. "$ROOT/monitor/shell-files.sh" 2>/dev/null || {
    echo "awk-v-escape-lint: cannot source monitor/shell-files.sh — the population predicate is shared, not re-implemented" >&2
    exit 1
}
declare -F shf_is_shell >/dev/null || { echo "shf_is_shell not defined" >&2; exit 1; }
declare -F shf_strip_comments >/dev/null || { echo "shf_strip_comments not defined" >&2; exit 1; }

# THE POPULATION: every tracked file the shared predicate calls shell, over
# the WHOLE tree (the class is repo-wide; `#1420` corrected a monitor/-scoped
# sweep). Emits repo-relative paths.
_avl_population() {
    local f
    while IFS= read -r f; do
        [[ -n "$f" && -f "$ROOT/$f" ]] || continue
        shf_is_shell "$ROOT/$f" || continue
        printf '%s\n' "$f"
    done < <(git -C "$ROOT" ls-files 2>/dev/null)
}

# The `--population` protocol. `gp_handle` EXITS when it handles the flag, so
# it sits above the first scan.
# shellcheck disable=SC1091
. "$ROOT/monitor/_guard_population.sh"
gp_population() {
    _avl_population
    printf '%s\n' monitor/watcher/awk-v-escape-lint.sh monitor/shell-files.sh
}
gp_handle "$@"

# _avl_scan <file> — print `path:line:text` for every flagged site, and
# `path:line:EXEMPT:text` for a site carrying the reason-bearing marker.
#
# The ERE, stated once: `-v` as a word, a NAME, `=`, then an optional `"` and
# a `$`. A single-quoted `'$…'` is excluded because the shell hands awk the
# literal characters and nothing was expanded. The line must invoke `awk`,
# OR follow a line ending in `\` (a continuation of an awk command).
_AVL_RE='(^|[[:space:]])-v[[:space:]]+[A-Za-z_][A-Za-z0-9_]*="?\$'
_avl_scan() {
    local f="$1" rel="${1#"$ROOT"/}" prev_cont=0 n=0 line code raw
    # Comments are stripped ONCE for the whole file so a `#` inside quotes is
    # not a comment (shf_strip_comments is the shared quote machine); the
    # stripped text keeps its line count, so numbers below are real lines.
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$(( n + 1 ))
        code="$line"
        if [[ "$code" =~ $_AVL_RE ]] \
           && { [[ "$code" =~ (^|[^A-Za-z0-9_./-])awk([[:space:]]|$) ]] || (( prev_cont )); }; then
            # The exemption marker lives in a trailing COMMENT, which the
            # stripped text no longer carries — so the RAW line is read back
            # for the marker (only on a hit; the scan itself stays on code).
            raw=$(sed -n "${n}p" -- "$f")
            if [[ "$raw" == *'awk-v-escape-lint: literal-only'* ]] \
               && [[ "$raw" =~ awk-v-escape-lint:\ literal-only[[:space:]]*(—|–|-|:)[[:space:]]*[^[:space:]] ]]; then
                printf '%s:%d:EXEMPT:%s\n' "$rel" "$n" "$raw"
            else
                printf '%s:%d:%s\n' "$rel" "$n" "$raw"
            fi
        fi
        if [[ "$code" =~ \\$ ]]; then prev_cont=1; else prev_cont=0; fi
    done < <(shf_strip_comments "$f" 2>/dev/null)
}

mode=report
files=()
case "${1:-}" in
    --strict) mode=strict; shift ;;
    --files)  _avl_population | LC_ALL=C sort; exit 0 ;;
    --scan)   shift; mode=scan; files=("$@") ;;
    "")       ;;
    *) echo "awk-v-escape-lint: unknown flag $1" >&2; exit 2 ;;
esac

if [[ "$mode" != scan ]]; then
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$ROOT/$f"); done < <(_avl_population)
    if (( ${#files[@]} == 0 )); then
        echo "awk-v-escape-lint: population is EMPTY — refusing to report a clean sweep over a corpus this enumerator did not produce." >&2
        exit 3
    fi
fi

hits=(); exempt=()
for f in "${files[@]}"; do
    [[ -r "$f" ]] || continue
    while IFS= read -r h; do
        [[ -n "$h" ]] || continue
        case "$h" in *:EXEMPT:*) exempt+=("$h") ;; *) hits+=("$h") ;; esac
    done < <(_avl_scan "$f")
done

ref=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')
staged=$(git -C "$ROOT" status --porcelain 2>/dev/null | command grep -c . || true)
printf 'awk-v-escape-lint: population %d shell files (shf_is_shell over git ls-files, ref %s, working tree with %s uncommitted change(s)); mode=%s\n' \
    "${#files[@]}" "$ref" "${staged:-0}" "$mode"
printf 'awk -v <shell expansion> sites: %d flagged, %d exempted by a reason-bearing marker\n' "${#hits[@]}" "${#exempt[@]}"
for h in "${hits[@]}"; do printf '  %s\n' "$h"; done
for h in "${exempt[@]}"; do printf '  (exempt) %s\n' "$h"; done
if (( ${#hits[@]} > 0 )); then
    echo "  ^ each site hands awk a CALLER-SUPPLIED string through -v, which ESCAPE-PROCESSES it"
    echo "    (\\n, \\t, \\-newline consumed SILENTLY). Substitute ENVIRON[\"NAME\"] inside a"
    echo "    ( export NAME=…; awk … ) subshell, or move the value out of awk entirely. A site whose"
    echo "    value is provably literal-only may carry: # awk-v-escape-lint: literal-only — <reason>"
    echo "    (your-org/nexus-code#1420)."
fi
if [[ "$mode" == strict ]] && (( ${#hits[@]} > 0 )); then exit 1; fi
if [[ "$mode" == report ]]; then
    echo "ADVISORY: this lint exits 0 today; --strict flips the polarity once the corpus is annotated or cleaned."
fi
exit 0
