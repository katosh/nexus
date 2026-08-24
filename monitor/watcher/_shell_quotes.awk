# _shell_quotes.awk — ONE shell-quote state machine, shared.
# (your-org/nexus-code#842 skeptic finding; the rule is #838's own)
#
# WHY THIS FILE EXISTS. Two places in this tree need to know whether a token on
# a line is CODE or TEXT INSIDE A STRING:
#
#   * `th_strip_heredocs`'s `scan()` (`_test_helpers.sh`) — so a `<<` inside a
#     quoted argument is not read as a heredoc opener (`#806`);
#   * `uncounted-abort-lint.sh`'s disposition tests — so a diagnostic that
#     NAMES `th_summary_and_exit` or `_th_fail` is not read as calling it
#     (`#838`).
#
# `#842` wrote the second one as a pair of `sed` substitutions:
#
#     sed "s/'[^']*'//g; s/\"[^\"]*\"//g"
#
# and that is CHARACTER MATCHING, not mechanism matching — the exact error
# `#838` and `#821` were both about, committed in the header that names it.
# `s/'[^']*'//g` pairs ANY two apostrophes, so two of them inside double-quoted
# prose form a span and everything between is deleted, INCLUDING a real call:
#
#     raw          echo "don't stop"; th_summary_and_exit; echo "that's all"
#     sed pair     echo                                    <- the call is EATEN
#     this file    echo ; th_summary_and_exit; echo        <- preserved
#
# Direction 2 is what fails: a genuine uncounted abort stops reddening. A lint
# exists to catch something rare, so that is the direction that ships silently.
#
# WHY A MASK AND NOT A "STRIP" FUNCTION. The obvious shared primitive is "give
# me the line with quoted spans removed", and `scan()` cannot use it: a heredoc
# delimiter is usually QUOTED (`<<'EOF'`), so stripping quoted text deletes the
# delimiter `scan()` exists to capture. The mask lets each caller ask the
# question it actually has — "is the character at position i inside quotes?" —
# while the state machine that answers it lives in exactly one place.
#
# SCOPE, stated. This models the two shell quoting forms that matter here:
# single quotes (literal, no escapes inside — POSIX) and double quotes (where
# `\` escapes the next character). It does not model `$'…'` ANSI-C quoting,
# backslash-escaped quotes OUTSIDE a string, or a quote left open across a line
# continuation. Each of those makes the mask *conservative in the safe
# direction* for a defect detector — an unterminated quote leaves the rest of
# the line marked quoted for the lint, which can only cost a spurious red, never
# a silent green.

# quote_mask(s) -> a string the same length as s: "1" where the character is
# inside a quoted span (the quote characters themselves included), "0" outside.
function quote_mask(s,   i, L, c, inq, out) {
    L = length(s); inq = ""; out = ""
    for (i = 1; i <= L; i++) {
        c = substr(s, i, 1)
        if (inq != "") {
            out = out "1"
            # Only double quotes honour backslash escapes; inside single quotes
            # a backslash is a literal character and cannot escape the closer.
            if (c == "\\" && inq == "\"") {
                i++
                if (i <= L) out = out "1"
                continue
            }
            if (c == inq) inq = ""
            continue
        }
        if (c == "'" || c == "\"") { inq = c; out = out "1"; continue }
        out = out "0"
    }
    return out
}

# code_only(s) -> s with every quoted span removed. What a source-text lint
# should test against: the code the line RUNS, not the text it PRINTS.
function code_only(s,   m, i, L, out) {
    m = quote_mask(s); L = length(s); out = ""
    for (i = 1; i <= L; i++)
        if (substr(m, i, 1) == "0") out = out substr(s, i, 1)
    return out
}
