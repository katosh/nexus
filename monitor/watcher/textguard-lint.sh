#!/usr/bin/env bash
# textguard-lint.sh — flag the text-about-code idioms whose failure mode is a
# GREEN GUARD rather than an error (your-org/nexus-code#1016, #1022, #1024,
# #1026).
#
# Usage:  bash monitor/watcher/textguard-lint.sh [<repo-root>] [--rule R1|R2|R3]
#   prints one `<rule>\t<file>:<line>\t<text>` row per site; exit 1 if any.
#
# ---------------------------------------------------------------------------
# THE THESIS
#
# Text about code is not behaviour of code. Every guard in this family is an
# assertion about source TEXT standing in for a property of EXECUTION. Measured
# on one board in one evening, five such guards were defeated:
#
#   position of the call site   -> moving the call into the `else` arm
#   `grep -c` "exactly once"    -> a `;` (two occurrences, one LINE)
#   `grep -o` occurrences       -> MOVING the single call to another branch
#   `sed 's/#.*$//'` strip      -> a `#` inside a STRING
#   `grep -qxF "$t"` existence  -> an EMPTY `$t`
#
# The corollary is the whole point, and it bounds what this lint can be:
#
#   A CENSUS ASSERTION CAN PIN MEMBERSHIP. IT CAN NEVER PIN PLACEMENT OR
#   CONTROL FLOW.
#
# The ladder position -> count -> occurrences -> comment-aware never reaches the
# property; each rung buys one more mutant and loses to the next. So this lint
# does NOT try to certify that a guard is sound. It flags idioms that are wrong
# in their own UNIT — a line count where occurrences were meant, a strip that
# is not shell-aware, a needle the fixture itself supplies. Those are genuinely
# textual defects, and a text tool can see them. Whether the surviving
# assertion pins the right property is a question for a human, and R1's message
# says so.
#
# ---------------------------------------------------------------------------
# THE AXES, STATED SO THEY CAN BE DISAGREED WITH
#
# R1 — LINE-UNIT CENSUS WITH A NONZERO EQUALITY.
#   `grep -c` counts matching LINES, not matches. `foo; foo` is two occurrences
#   and ONE line, so every `== N` for N >= 1 is defeated by moving a second
#   occurrence onto an existing line.
#   FLAGGED: a `grep -c`/`-cE`/`-cF` (option cluster carrying `c`) whose value
#     is compared for EQUALITY against a nonzero literal — as an `assert_eq` /
#     `assert_contains` third argument, or via `[[ "$v" == "N" ]]` / `-eq N`.
#   NOT FLAGGED, and each is a MEASURED immunity, not an oversight:
#     * `== 0` — any occurrence yields at least one line, so a zero cannot hide.
#     * `>= 1`, `-ge`, `-gt`, `-le`, `-lt` — thresholds, immune for the same
#       reason. A predicate that misses this over-reports badly: an
#       `=`-with-digit regex matches inside `>= 1` and silently converts an
#       immune threshold into an apparent equality.
#     * `^`-anchored patterns — at most one match per line by construction.
#     * `grep -cx` / `-cxF` — line-exact by FLAG, same immunity.
#     * `grep -q…` — prints nothing; there is no count.
#   ON THE AXIS, and the direction was chosen by MEASUREMENT: the target must
#     be PROVABLY a tracked source file. Without that test this rule flagged 14
#     sites on a clean tree and every one was a log, a registry or a captured
#     stream — where a line count is the CORRECT unit. That is the
#     "flags everything, muted within a week" failure, and a muted lint
#     protects nothing. The test is POSITIVE (an in-file, one-hop resolution of
#     the target variable to a repo anchor), so a target it cannot PROVE to be
#     source is NOT flagged. This under-reports on purpose. Recall for the
#     class is carried by the sweep recorded in the issues, not by this regex.
#     Targets with a DATA extension (`.tsv .log .jsonl .json .csv .txt
#     .registry .manifest .out .err`) are excluded for the same measured
#     reason: they are line-oriented by nature, so a line count is right there
#     even when the path resolves through a repo anchor.
#
# R2 — A COMMENT STRIP THAT IS NOT SHELL-AWARE.
#   `sed 's/#.*$//'` cuts from the first `#` on a line whatever the quoting.
#   This repo writes issue refs inside operator strings by convention, so a `#`
#   in a STRING deletes every token to its right from the checker's view. Both
#   directions are live: the strip can hide a call the check must SEE, and it
#   can hide the PROBE that would have counted the site at all.
#   FLAGGED: `sed` substituting `#.*`, `cut -d'#'`, `awk` `sub(/#.*/…)` or
#     `-F'#'`.
#   NOT FLAGGED: `${var%%#*}` / `${var%#*}`. Measured false positive —
#     `monitor/issue-ref.sh:100` uses it to SPLIT a string the line above has
#     just validated as `owner/repo#N`. That is a field split, not a comment
#     strip, and the two are indistinguishable by regex.
#   The safe primitive is whole-line only: `grep -v '^[[:space:]]*#'`.
#   DECLARED LIMIT: whole-line stripping does not remove a TRAILING comment, so
#     prose after code on the same line can still vouch. No line-based idiom
#     closes that; it needs a tokeniser, or the property should be tested
#     behaviourally instead.
#
# R3 — AN ASSERTION MATCHING A TOKEN ITS OWN FIXTURE MANUFACTURES.
#   A suite that names its scratch directory or its tmux socket after an issue
#   (`nexus-745-XXXXXX`) and then asserts `case "$out" in *745*)` is matching
#   the PATH inside the message, not the message. It passes against broken code.
#   FLAGGED: a file that both (a) mints a bare 3-4 digit token into a fixture
#     path, socket, or session name, and (b) matches that SAME token in a glob
#     or grep pattern. The cross-product is what makes it a finding — either
#     half alone is common and harmless.
#   The remedy is either half: match a phrase the fixture cannot supply, or
#     take the number out of the fixture. Both is better; either closes it.
#
# NOT COVERED, named so its absence is not read as a clean bill:
#   * H-POS — a source-line-number comparison standing in for control flow
#     (#1016). Textually detectable, but "does a behavioural counterpart
#     exist?" is not, and the pairing may live in another file. A lint here
#     would flag the good pattern and the bad one identically.
#   * H-EMPTY — an existence check with an empty needle (`grep -qF -- "$n"`).
#     Deciding whether `$n` can be empty needs data flow. Measured population
#     at the time of writing: 11 sites, and `_test_helpers.sh:247`
#     (`assert_contains`) is the highest-blast-radius member at ~4.3k call
#     sites. Left to a dedicated change with CI behind it.
#   * a count that is wrong for any other reason.
#
# "No member found" is a claim about THIS SEARCH, not about the population.
set -uo pipefail

ROOT="${1:-}"; RULE=""
while (( $# > 0 )); do
    case "$1" in
        --rule) RULE="${2:-}"; shift 2 ;;
        -*)     printf 'textguard-lint: unknown option: %s\n' "$1" >&2; exit 2 ;;
        *)      ROOT="$1"; shift ;;
    esac
done
[[ -n "$ROOT" ]] || ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[[ -d "$ROOT/monitor" ]] || { printf 'textguard-lint: no monitor/ under %s\n' "$ROOT" >&2; exit 2; }

want() { [[ -z "$RULE" || "$RULE" == "$1" ]]; }

# `-print0 | xargs`-free enumeration: the operator's interactive `grep` is a
# ugrep wrapper honouring .gitignore and returns a SILENT zero over ignored
# trees (#618). A `while read -d ''` loop over `find` never goes through the
# shell function, and `command grep` must NOT be used with xargs — `command` is
# a builtin and xargs execs a program, so that pipeline exits 127 having never
# run grep (#707).
roots=( "$ROOT/monitor" )
[[ -d "$ROOT/.github" ]] && roots+=( "$ROOT/.github" )
[[ -d "$ROOT/skills"  ]] && roots+=( "$ROOT/skills"  )

hits=0
emit() { printf '%s\t%s:%s\n' "$1" "$2" "$3"; hits=$(( hits + 1 )); }

while IFS= read -r -d '' f; do
    case "$f" in */.git/*) continue ;; esac
    case "${f##*/}" in
        *.sh|ng|sandbox-notify) ;;
        *) continue ;;
    esac

    # ---- R1: line-unit census with a nonzero equality ---------------------
    # The target must be provably a TRACKED SOURCE file. `$SVC_CALLS`,
    # `$ACTIONS`, `decisions.tsv`, a `git log` stream — those are line-oriented
    # by nature and a line count is the CORRECT unit there. Flagging them is
    # how a lint gets muted, and a muted lint protects nothing.
    #
    # LOGICAL lines, not physical ones. This repo's assertions routinely span a
    # backslash continuation:
    #
    #     assert_eq "…" \
    #         "$(grep -c 'PAT' "$REPO_ROOT/monitor/x.sh")" "1"
    #
    # A physical-line regex sees `assert_eq` and the `grep -c` on different
    # lines and matches neither. Measured: without joining, this rule found
    # ZERO of the seven live sites on `dev` — a confident clean bill from a
    # predicate that could not see the population. The join is not a refinement,
    # it is the difference between a guard and a decoration.
    if want R1; then
        anchors=$(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^;]*' "$f" 2>/dev/null \
                   | grep -E 'REPO_ROOT|_script_dir|_test_dir|NEXUS_ROOT|/monitor/|/skills/' \
                   | grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*' | tr -d ' ' | sort -u || true)
        anchor_re='REPO_ROOT|_script_dir|_test_dir|NEXUS_ROOT|monitor/|skills/'
        while IFS= read -r a; do
            [[ -n "$a" ]] && anchor_re="$anchor_re|[$][{]?$a"
        done <<< "$anchors"
        # Join continuations; each logical line keeps the physical line number
        # it STARTED on, which is the line a reader is sent to.
        while IFS= read -r row; do
            emit R1 "$f" "$row"
        done < <(
            awk '
              { line = $0
                start = NR
                while (line ~ /\\[[:space:]]*$/ && (getline nxt) > 0) {
                    sub(/\\[[:space:]]*$/, "", line); line = line " " nxt
                }
                printf "%d:%s\n", start, line
              }' "$f" \
              | grep -vE '^[0-9]+:[[:space:]]*#' \
              | grep -E 'grep([[:space:]]+-[A-Za-z]*c[A-Za-z]*)+' \
              | grep -vE 'grep[[:space:]]+-[A-Za-z]*[qx]' \
              | grep -E '(assert_eq|assert_contains)[^#]*"[1-9][0-9]*"[[:space:]]*$|==[[:space:]]*"?[1-9][0-9]*"?|-eq[[:space:]]+[1-9][0-9]*' \
              | grep -vE '[-][gl][te][[:space:]]|>=|<=|grep[[:space:]]+-[A-Za-z]*c[A-Za-z]*[[:space:]]+.?\^' \
              | grep -E "$anchor_re" \
              | grep -vE '\.(tsv|log|jsonl|json|csv|txt|registry|manifest|out|err)\b' \
              || true
        )
    fi

    # ---- R2: comment strip that is not shell-aware ------------------------
    if want R2; then
        while IFS= read -r row; do
            emit R2 "$f" "$row"
        done < <(
            grep -nE "sed[^|]*s/#\.\*|cut[[:space:]]+-d'?#|awk[^|]*-F'?#|sub\(/#\.\*/" "$f" \
              | grep -vE '^[0-9]+:[[:space:]]*#' \
              || true
        )
    fi

    # ---- R3: assertion matching a token its own fixture manufactures ------
    if want R3; then
        # (a) tokens this file MINTS into a fixture path / socket / session name
        mint=$(grep -hE 'mktemp|SOCK=|SESSION=|SESS=|WINDOW=|new-session' "$f" 2>/dev/null \
                 | grep -oE '[A-Za-z_-][0-9]{3,4}([^0-9]|$)' | grep -oE '[0-9]{3,4}' | sort -u || true)
        if [[ -n "$mint" ]]; then
            while IFS= read -r t; do
                [[ -n "$t" ]] || continue
                # (b) …and MATCHES on that same bare token in a pattern position
                while IFS= read -r row; do
                    emit R3 "$f" "$row"
                done < <(
                    grep -nE "\*${t}\*|grep[^|]*['\"]${t}['\"]" "$f" \
                      | grep -vE '^[0-9]+:[[:space:]]*#' \
                      || true
                )
            done <<< "$mint"
        fi
    fi
done < <(find "${roots[@]}" -type f -print0)

if (( hits > 0 )); then
    printf '\ntextguard-lint: %d site(s).\n' "$hits" >&2
    printf '  R1 `grep -c` counts LINES, not matches — `foo; foo` is ONE line.\n' >&2
    printf '     If the unit should be occurrences: `grep -o PAT F | wc -l`.\n' >&2
    printf '     If LINES are genuinely right (a log, a `git log` stream), say so at the site.\n' >&2
    printf '     And note a census pins MEMBERSHIP only — never PLACEMENT (#1026 half 2).\n' >&2
    printf '  R2 strip WHOLE-LINE comments only: `grep -v %s`.\n' "'^[[:space:]]*#'" >&2
    printf '  R3 match a phrase the FIXTURE cannot supply, or take the number out of the fixture.\n' >&2
    printf '  your-org/nexus-code#1016 #1022 #1024 #1026\n' >&2
    exit 1
fi
exit 0
