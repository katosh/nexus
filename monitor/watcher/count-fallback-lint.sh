#!/usr/bin/env bash
# count-fallback-lint.sh — flag `grep -c … || <prints a value>`, the idiom
# whose failure mode is a plausible wrong NUMBER rather than an error
# (your-org/nexus-code#725).
#
# Usage:  bash monitor/watcher/count-fallback-lint.sh [<repo-root>]
#   prints one `<file>:<line>\t<text>` row per site; exit 1 if any, 0 if none.
#
# Usage:  bash monitor/watcher/count-fallback-lint.sh --files [<repo-root>]
#   prints the POPULATION — one repo-relative path per line, every file the
#   scan above reads. Same selection predicate, one implementation.
#
# ---------------------------------------------------------------------------
# THE DEFECT
#
# `grep -c` on NO MATCH prints `0` **and** exits 1. So the defensive-looking
#
#     n=$(grep -c PATTERN "$f" 2>/dev/null || echo 0)
#
# emits TWO lines — `grep`'s own `0`, then the fallback's — and `n` becomes
# `"0\n0"`. The `|| echo 0` was added to make the no-match case safe and is
# exactly what makes it unsafe: `grep -c` had already handled it.
#
# Measured consequences at the 26 sites this found on `dev`@`fc74b2d`:
#   * `[[ "$n" -eq 1 ]]` → bash "syntax error in expression", BOTH branches
#     false (request-channel.sh's reply-header route fell through silently).
#   * `jq --argjson n "$n"` → invalid JSON (`ng lit status --json` on an
#     empty library).
#   * an assertion expecting `"0"` compares against `"0\n0"` and fails for a
#     reason that reads as a real defect.
# Latent wherever the only comparison is `>= 1`, which is why it survived.
#
# THE REMEDY, AND ITS PRECONDITION (your-org/nexus-code#730)
#
# The general remedy is a one-token edit, and the repo already uses it in nine
# places:
#
#     n=$(grep -c PATTERN "$f" 2>/dev/null) || n=0    # replace, don't append
#
# `|| true` inside the expansion is ALSO clean — but ONLY when the file is
# guaranteed to exist. The two are not interchangeable, and this text used to
# offer them as if they were:
#
#     n=$(grep -c PATTERN "$f" 2>/dev/null || true)   # ONLY if $f must exist
#
# On a MISSING file `grep -c` prints NOTHING (its diagnostic goes to stderr) and
# exits 2. So `|| true` yields the EMPTY STRING where `) || n=0` yields `0`.
# Measured, both remedies against an absent path:
#
#                        `) || n=0`     `|| true`
#     [[ "$n" -eq 1 ]]      false         false      (bash coerces "" to 0)
#     [[ "$n" == "0" ]]     true          FALSE
#     printf '%d' "$n"      0             0          (bash coerces "" to 0)
#     jq --argjson c "$n"   ok            ERROR      (empty is not JSON)
#
# Two of the three consequences measured at the top of this header therefore
# RECUR under `|| true` on a may-be-absent file — in a new spelling this lint
# does not flag, because nothing is double-printed. Arithmetic is the one that
# survives, which is precisely why it stays hidden: the `-eq` sites keep
# working and the `jq`/string-compare sites break somewhere else.
#
# So: `|| true` when the file cannot be absent; `) || var=0` otherwise. When in
# doubt, `) || var=0` is correct in both cases and costs nothing.
#
# ---------------------------------------------------------------------------
# THE AXIS, STATED SO IT CAN BE DISAGREED WITH
#
#   1. FILES — under `monitor/` OR `.github/`, and shell:
#        * a `*.sh` name, or `ng`, or `sandbox-notify` (the extensionless
#          executables this repo ships);
#        * plus `*.yml`/`*.yaml` UNDER `.github/` ONLY, because CI shell lives
#          inside `run:` blocks there and nowhere else in this tree.
#      `.github/` joined in #730. It was omitted while the one-time search that
#      found the 26 sites DID cover it — a boundary the standing guard did not
#      inherit from the sweep that motivated it. The population there was, and
#      at the time of writing still is, EMPTY (`.github/` holds exactly one
#      `grep -c`, in `tests-slow-integration.yml`, with no `||` arm), so this
#      widening fixes a drift rather than a live miss. Widening the find root
#      alone would NOT have done it: every `.github/` file is YAML, which the
#      name filter rejected — the reason the file rule moves too.
#   2. COMMAND — `grep` carrying a `-c` in its option cluster, WITHOUT `-q`
#      (`-q` suppresses stdout, so no second value is ever printed).
#   3. FALLBACK — a `||` whose right arm is `echo` or `printf`, i.e. one that
#      PRINTS. `|| true` and `|| return`/`|| continue` do not print and are
#      deliberately NOT flagged. Note that NOT-FLAGGED is not the same as
#      CORRECT: `|| true` on a may-be-absent file yields the empty string, a
#      different member of the same wrong-value class, and this lint does not
#      see it (see THE REMEDY above). That gap is declared, not closed —
#      detecting it needs file-existence reasoning this line-regex cannot do.
#   4. ADJACENCY — no `&&`, `;` or further `|` between the `grep -c` and the
#      `||`, so the fallback provably belongs to THIS command rather than to a
#      later one on the same line. This is what keeps `fail "…$(grep -c X
#      "$L") …$(f "$P" && echo yes || echo no)"` off the list: its `||` is a
#      different command's.
#   5. Comment lines are excluded.
#
# NOT ON THE AXIS, and therefore NOT claimed about:
#   * `wc -l < missing` + `|| echo 0`. It looks identical and is NOT this
#     defect: the redirection fails, `wc` never runs, and nothing is printed
#     before the fallback — so the fallback REPLACES rather than appends. (It
#     has its own, separate defect — the shell reports the redirection error
#     past any `2>/dev/null` on the command — which is `#723`, not this.)
#   * `grep -c` whose fallback spans a `\`-continuation onto the next line.
#   * a count that is wrong for any other reason.
#   * shell outside `monitor/` and `.github/`, and non-shell files.
#   * `|| true` on a file that may be absent — the #730 sibling above. Off the
#     axis because it prints nothing; named so its absence is not read as a
#     clean bill.
#
# "No member found" is a claim about THIS SEARCH, not about the population.
set -uo pipefail

# `--files` prints the POPULATION — one path per line, every file this lint
# reads — so the guard's `gp_population` can forward to it instead of keeping a
# second copy (your-org/nexus-code#1494, #1301 item 2). A copy is a second
# implementation of the population and it drifts, at which point the index
# reports with total confidence that this lint does not read a file it does
# read.
_CFL_FILES=0
if [[ "${1:-}" == --files ]]; then _CFL_FILES=1; shift; fi

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[[ -d "$ROOT/monitor" ]] || { printf 'count-fallback-lint: no monitor/ under %s\n' "$ROOT" >&2; exit 2; }

# `-print0 | xargs -0` rather than a recursive `grep`: the operator's
# interactive `grep` is a ugrep wrapper that honours .gitignore and returns a
# SILENT zero over ignored trees (CLAUDE.md / #618). `xargs` does not go
# through the shell, so the wrapper is not in play — and `command grep` must
# NOT be used here, because `command` is a shell builtin and `xargs` execs a
# program (`#707`: that pipeline exits 127 having never run grep).
#
# Roots: `monitor/` is REQUIRED (it is what identifies a nexus tree, and its
# absence is the exit-2 above). `.github/` is scanned when present — a fixture
# tree that plants only `monitor/` is a legitimate caller, so its absence is not
# an error. It is never SILENTLY skipped in the tree that matters: the suite
# plants a `.github/` positive and asserts it is flagged, so a regression that
# dropped this root reddens rather than reporting a clean `.github/`.
roots=( "$ROOT/monitor" )
[[ -d "$ROOT/.github" ]] && roots+=( "$ROOT/.github" )

# THE SELECTION, factored out so `--files` and the scan cannot disagree. It is
# ONE predicate with two consumers, which is the whole point: a `gp_population`
# that re-stated this `case` would be a second implementation.
_cfl_selected0() {   # -> NUL-separated selected paths
    local f
    while IFS= read -r -d '' f; do
        case "$f" in
            */.git/*) continue ;;
        esac
        # A shell file: by name for the `*.sh` + extensionless executables this
        # repo ships, plus workflow YAML under `.github/`, whose `run:` blocks
        # are shell. The YAML arm is scoped to `.github/` deliberately — see
        # axis item 1.
        case "${f##*/}" in
            *.sh|ng|sandbox-notify) ;;
            *.yml|*.yaml)
                case "$f" in
                    "$ROOT"/.github/*) ;;
                    *) continue ;;
                esac
                ;;
            *) continue ;;
        esac
        printf '%s\0' "$f"
    done < <(find "${roots[@]}" -type f -print0)
}

if (( _CFL_FILES )); then
    _cfl_selected0 | while IFS= read -r -d '' f; do printf '%s\n' "${f#"$ROOT"/}"; done
    exit 0
fi

hits=0
while IFS= read -r -d '' f; do
    while IFS= read -r row; do
        printf '%s:%s\n' "$f" "$row"
        hits=$(( hits + 1 ))
    done < <(
        grep -nE 'grep([[:space:]]+-[A-Za-z]*c[A-Za-z]*)+[^&;|]*\|\|[[:space:]]*(echo|printf)[[:space:]]' "$f" \
            | grep -vE '^[0-9]+:[[:space:]]*#' \
            | grep -vE 'grep[[:space:]]+-[A-Za-z]*q' \
            || true
    )
done < <(_cfl_selected0)

if (( hits > 0 )); then
    printf '\ncount-fallback-lint: %d site(s). `grep -c` already prints 0 on no match —\n' "$hits" >&2
    printf '  the `|| echo 0` appends a SECOND value.\n' >&2
    printf '  Fix with `n=$(grep -c … 2>/dev/null) || n=0`.\n' >&2
    printf '  `|| true` is also clean, but ONLY if the file cannot be absent:\n' >&2
    printf '  on a missing file it yields the EMPTY STRING, not 0 (#730).\n' >&2
    printf '  your-org/nexus-code#725\n' >&2
    exit 1
fi
exit 0
