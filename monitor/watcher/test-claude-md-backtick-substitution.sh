#!/usr/bin/env bash
# test-claude-md-backtick-substitution.sh — execute CLAUDE.md's
# BACKTICK-SUBSTITUTION block.
#
# WHY THIS SUITE EXISTS. your-org/nexus-code#1157: a backticked identifier
# inside a double-quoted `--message "…"` is command-substituted by the SHELL
# before `ng` ever sees it. Agent prose on this board is dense with backticked
# window names, paths and function names, and `ng request reply` / `ng send` /
# `ng skeptic ask` write durable, machine-read records — so a corrupted
# argument becomes a permanent artefact that reads as prose somebody wrote. It
# already cost one: a reply lost the word `nxmerge`, leaving a double space,
# and was accepted at rc 0.
#
# WHAT IS ACTUALLY PINNED:
#   MODE 1  — an UNKNOWN command is replaced by the EMPTY STRING. The 127 lands
#             on the ASSIGNMENT, which nothing tests.
#   MODE 2  — a KNOWN command is replaced by its STDOUT: rc 0, stderr EMPTY,
#             and the result is grammatical. This is the dangerous one, and the
#             empty-stderr assertion is the point of the arm.
#   the ASYMMETRY — bash behaves IDENTICALLY. This is POSIX substitution, not a
#             member of the zsh-only family (`mapfile`, the `path` tie, the
#             history modifier), so a bash-tested remedy does not exonerate it.
#             Naming it a zsh trap would send the next reader to the wrong
#             reflex, which is why the bash arm is an ASSERTION and not a note.
#   the REMEDIES — a FILE's bytes are never expanded; a heredoc is safe ONLY
#             with a QUOTED delimiter, and the unquoted form is asserted to eat
#             the token, because "use a heredoc" without that clause is wrong.
#
# CONTROLS:
#   A — the extracted form count is PINNED at 6 (#618's shape).
#   B — POSITIVE CONTROL: the remedy arms must SHOW the backticks surviving
#         literally. Every WRONG arm asserts an ABSENCE, and a probe that could
#         not see a backtick at all would satisfy all of them.
#   C — MODE 2 exits 0 with EMPTY stderr. The defect is that it succeeds.
#   D — the mode-1 token is verified NOT to be a real command on this host
#         first. If it ever became one, mode 1 would silently become mode 2 and
#         its arm would measure the wrong thing.
#
# ZSH ABSENCE IS A SKIP, NOT AN ABORT (your-org/nexus-code#946 F7), matching
# the two pre-existing zsh-dependent suites. The bash arm and the extraction
# need no zsh and still run.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

# ── this suite DECLARES its own population (the --population protocol) ──────
# your-org/nexus-code#1219. CLAUDE.md is the document this suite EXECUTES, so
# an edit to the fenced block it pins is exactly the edit that can change its
# verdict — and until #1219 no such edit could SELECT it: a suite that declares
# no population is INVISIBLE to `guards-for-diff` rather than excluded by it
# (#1078), appearing in neither SELECTED nor CONSIDERED AND EXCLUDED, so its
# absence reads as a considered exclusion. `gp_handle` adds this suite's own
# path and `monitor/_guard_population.sh` for free; everything else is declared
# because this suite READS ITS BYTES to reach a verdict.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        CLAUDE.md \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"
th_claude_md_block_coverage BACKTICK-SUBSTITUTION   # the entry's UNCHECKED share, in this suite's own output (#1239)

HAVE_ZSH=no
if command -v zsh >/dev/null 2>&1; then
    HAVE_ZSH=yes
else
    th_skip "every zsh-dependent arm" \
            "zsh is not on PATH — modes 1 and 2, the --file remedy and both heredoc arms could NOT be exercised on this host; only the block extraction and the bash contrast ran"
fi

WORK=$(mktemp -d) || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

_th_count_guard() {
    # COUNT EACH ARM SEPARATELY, NEVER THE SUM (your-org/nexus-code#1165 skeptic
    # F1). The first version shipped `9` with a `+10` bump. The no-zsh arm runs
    # TEN (readable + Control A + 6 form shapes + Control D + the bash contrast)
    # and the zsh arms then added NINE — so it was wrong in BOTH halves and right
    # in their SUM, i.e. green wherever zsh EXISTS, which is the only
    # configuration anyone runs (tests.yml installs zsh on every unit job). Two
    # errors that cancel, inside the guard whose whole job is to catch a wrong
    # total (#946 F1), in a PR about exactly that. It was found by MASKING zsh
    # from PATH and running the branch, which is the only way either half is
    # visible. Do that when you change these numbers.
    #   no-zsh arm : 1 readable + 1 Control A + 6 form shapes + 1 Control D
    #                + 1 bash contrast                                    = 10
    #   zsh arms   : 4 mode-1 + 3 mode-2 + 3 remedies                     = 10
    local EXPECTED_ASSERTIONS=10
    # `=`, NOT `==`, AND THAT IS LOAD-BEARING — do not "normalise" it. This line
    # carries both `EXPECTED` and `ASSERTION`, so summary-honesty's `_count_axis`
    # reads it; written with `==` it satisfies the classifier's exact-guard test
    # ALL BY ITSELF, and the suite reads `count=exact` whether or not it has a
    # guard. Measured: with `==`, weakening the real guard below to a floor is a
    # SURVIVING mutant — the manifest stays green over an unprotected suite,
    # which is its own stated dangerous direction. With `=`, the mutant is
    # killed. Same family as the `UNEXPECTEDLY` false positive that classifier
    # was rebuilt to remove; the pre-existing test-claude-md-zsh-path-tie.sh
    # still has the `==` form (measured survivor), reported separately.
    [[ "$HAVE_ZSH" = yes ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 10 ))
    local TOTAL_ASSERTIONS=$(( PASS + FAIL ))
    assert_eq "assertion TOTAL matches the EXPECTED total for this host (zsh=$HAVE_ZSH)" \
              "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"
    th_summary_and_exit
}

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b='<!-- BEGIN BACKTICK-SUBSTITUTION -->' -v e='<!-- END BACKTICK-SUBSTITUTION -->' '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | grep -E '^(zsh|bash) ')

FORM_COUNT=$(printf '%s\n' "$FORMS" | grep -cE '^(zsh|bash) ')
assert_eq "Control A: extracted exactly 6 documented forms" "$FORM_COUNT" "6"
if [[ "$FORM_COUNT" != "6" ]]; then
    th_abort "block malformed — refusing to draw conclusions from it"
fi

F_MODE1=$(printf  '%s\n' "$FORMS" | sed -n '1p')
F_MODE2=$(printf  '%s\n' "$FORMS" | sed -n '2p')
F_BASH=$(printf   '%s\n' "$FORMS" | sed -n '3p')
F_FILE=$(printf   '%s\n' "$FORMS" | sed -n '4p')
F_HDQ=$(printf    '%s\n' "$FORMS" | sed -n '5p')
F_HDU=$(printf    '%s\n' "$FORMS" | sed -n '6p')

assert_contains "form 1 is the UNKNOWN-command mode"  "$F_MODE1" 'nxmerge'
assert_contains "form 2 is the KNOWN-command mode"    "$F_MODE2" 'basename'
assert_contains "form 3 is the bash contrast"         "$F_BASH"  'bash '
assert_contains "form 4 is the --file remedy"         "$F_FILE"  'MSGFILE'
assert_contains "form 5 is the QUOTED-delimiter heredoc"   "$F_HDQ" "<<\\'EOF"
assert_contains "form 6 is the UNQUOTED-delimiter heredoc" "$F_HDU" '<<EOF'

echo
echo '=== Control D: the mode-1 token really is unknown on this host ==='
# If `nxmerge` ever became a real command here, mode 1 would silently become
# mode 2 and its arm would be measuring something else entirely.
assert_eq "the token in form 1 resolves to no command" \
          "$( command -v nxmerge >/dev/null 2>&1 && echo FOUND || echo absent )" "absent"

echo
echo '=== THE ASYMMETRY: bash does the SAME thing (this is NOT a zsh trap) ==='
out_bash=$(eval "$F_BASH" 2>/dev/null)
assert_eq "bash splices the command STDOUT in, exactly as zsh does" "$out_bash" "[run tmux next]"

if [[ "$HAVE_ZSH" != "yes" ]]; then
    echo
    echo '  (every arm below needs zsh — skipped above with a reason)'
    _th_count_guard
fi

echo
echo '=== MODE 1: an UNKNOWN command becomes the EMPTY STRING ==='
# LOCALE IS PINNED, and that is not decoration. A shell's "command not found"
# is gettext-localised, so an assertion on its TEXT is a claim about the
# runner's LANG — the Control D shape one axis over. #1165's skeptic recorded
# this as UNCHECKED rather than clean, because no second locale is installed
# here to vary it with. So the arm is split: the NON-EMPTY assertion is the
# real property and is locale-INVARIANT by construction, and the text match is
# made sound by pinning the locale rather than by hoping the runner is English.
err1="$WORK/e1"
out1=$( export LC_ALL=C LANG=C LANGUAGE=; eval "$F_MODE1" 2>"$err1" ); rc1=$?
assert_eq       "the backticked token is DELETED, leaving a double space" "$out1" "[expiry  recorded]"
assert_eq       "…and stderr is NON-EMPTY — the diagnostic nobody reads (locale-free)" \
                "$( [[ -s "$err1" ]] && echo yes || echo no )" "yes"
assert_contains "…and under a PINNED C locale it is the not-found text"    "$(cat "$err1")" "not found"
assert_eq       "…while the visible rc of the whole line is 0"             "$rc1" "0"

echo
echo '=== MODE 2: a KNOWN command splices its STDOUT in, silently ==='
err2="$WORK/e2"
out2=$( export LC_ALL=C LANG=C LANGUAGE=; eval "$F_MODE2" 2>"$err2" ); rc2=$?
assert_eq "the substitution produces grammatical, permanently wrong prose" "$out2" "[run tmux next]"
assert_eq "Control C: …at rc 0"                                            "$rc2" "0"
assert_eq "Control C: …with stderr EMPTY — nothing to notice"              "$(wc -c <"$err2" | tr -d ' ')" "0"

echo
echo '=== Control B / REMEDIES: the backticks must SURVIVE, literally ==='
# Every WRONG arm above asserts an ABSENCE. Without these, a probe that could
# not render a backtick at all would satisfy all of them.
MSGFILE="$WORK/msg.txt"
printf 'the window `nxmerge` is idle\n' > "$MSGFILE"
out_file=$(eval "${F_FILE//MSGFILE/$MSGFILE}" 2>/dev/null)
assert_eq "a FILE's bytes are never shell-expanded — what --file buys you" \
          "$out_file" '[the window `nxmerge` is idle]'

out_hdq=$(eval "$F_HDQ" 2>/dev/null)
assert_eq "a QUOTED-delimiter heredoc keeps the backticks literal" \
          "$out_hdq" 'the window `true` is literal'

out_hdu=$(eval "$F_HDU" 2>/dev/null)
assert_eq "…while an UNQUOTED delimiter has IDENTICAL exposure" \
          "$out_hdu" 'the window  is literal'

_th_count_guard
