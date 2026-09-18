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
# continuation.
#
# THE "SAFE DIRECTION" IS A PROPERTY OF THE CALLER, NOT OF THIS FILE, AND THIS
# PARAGRAPH USED TO CLAIM OTHERWISE (your-org/nexus-code#1127 skeptic). It read:
# each of those limitations makes the mask "conservative in the safe direction
# for a defect detector — an unterminated quote leaves the rest of the line
# marked quoted for the lint, which can only cost a spurious red, never a silent
# green." That holds for a caller that treats "quoted" as "ignore this". It is
# FALSE, and inverted, for a caller that treats "quoted" as "keep this":
#
#   `shf_strip_comments` (monitor/shell-files.sh) deletes from the first
#   UNQUOTED `#`. There, losing quote state does not mark text quoted — it
#   marks it CODE, so a `#` inside an open string reads as a comment and the
#   line is DELETED. Measured: `msg="hello` / `# world" ; set -o pipefail` is
#   pipefail ON in bash, matched in the raw text, and MISSED after stripping.
#   A silent green, produced by the very limitation this paragraph called safe.
#
# So: a guarantee stated once, at the primitive, goes false the day a caller
# arrives with the opposite polarity — with nobody editing the sentence. Each
# caller must re-derive the direction for itself. The cross-line case is now
# fixable here (pass `inq0`, carry `QM_END`); the other two limitations are not,
# and for them the direction is still the caller's to establish.

# quote_mask(s) -> a string the same length as s: "1" where the character is
# inside a quoted span (the quote characters themselves included), "0" outside.
# `inq0` — the quote state this line STARTS in, for callers that scan a file
# line by line and must not lose an OPEN string at the newline. Omit it and the
# behaviour is exactly as before (awk gives an unsupplied parameter ""), so the
# per-line callers are unaffected. On return, the global `QM_END` holds the
# state the line ENDS in; pass it back in as `inq0` for the next line.
#
# WHY THIS IS A PARAMETER AND NOT A SECOND SCANNER (your-org/nexus-code#1127):
# a caller that needed cross-line state would otherwise write its own loop, and
# a second copy of this state machine is exactly what `#842` did and `#838` is
# about. `shf_strip_comments` deleted a whole line of REAL CODE without it —
# `msg="hello` / `# world" ; set -o pipefail` is a `#` INSIDE an open string,
# and a per-line mask reads it as a comment.
# `sp0`, `stack`, `depth` — the COMMAND-SUBSTITUTION NESTING the line starts in
# (your-org/nexus-code#1227). `inq0`/`QM_END` carried the QUOTE state across the
# newline but not the `$( … )` stack, and the stack is what tells a `)` that it
# closes something. `sp`/`stack`/`depth` were function-locals, so they reset to
# empty on every call and a line beginning inside an open `$(` lost its nesting.
#
# The damage is not the lost `)`; it is what the NEXT quote character then does.
# Measured on `monitor/ng:1129-1130`, which ends a line inside an open `$(`:
# on the following line the `)` that should have popped back into the enclosing
# `"` is read as an ordinary character, so the trailing `"` OPENS a string
# instead of CLOSING one. Every subsequent line is then "inside a string", `#`
# is skipped as quoted, and the stripper EMITS THE REST OF THE FILE'"'"'S COMMENTS
# AS CODE. 567 of `monitor/ng`'"'"'s lines, 2,661 across 81 files, before this fix.
#
# The direction is LEAK TEXT AS CODE — a false POSITIVE for every lint built on
# this helper, never a false negative, because the failure only ever ADDS lines
# to the code stream. Verified by set comparison, not inferred: the post-fix
# surviving-comment set is a strict SUBSET of the pre-fix one, empty difference
# in the "newly surviving" direction.
#
# `stack`/`depth` are declared as PARAMETERS so a caller that wants cross-line
# state owns the arrays and passes them by reference; a caller that does not
# supply them gets awk'"'"'s uninitialized-parameter locals and the previous
# behaviour exactly. `quote_mask(s)` and `quote_mask(s, inq0)` are unchanged.
function quote_mask(s, inq0, sp0, stack, depth,   i, L, c, inq, out, sp) {
    L = length(s); inq = inq0; out = ""; sp = (sp0 == "" ? 0 : sp0 + 0)
    for (i = 1; i <= L; i++) {
        c = substr(s, i, 1)
        if (inq != "") {
            # `$(` REOPENS CODE INSIDE A DOUBLE-QUOTED SPAN, and the shell means
            # it (your-org/nexus-code#1130). Without this the mask calls the
            # whole of `x="$(printf %s "$s" | head -1)"` TEXT, so a caller
            # asking "is this token code?" is told no about a real pipeline. It
            # is not hypothetical and it is not rare: measured on this tree, an
            # early-exit-reader scan keyed on an unquoted pipe lost NINE live
            # `| head` sites to exactly this shape (node-forensics.sh:133,
            # toolchain-bash.sh:170, test-reports-roll.sh:114, …), each of which
            # really does run in this file'"'"'s shell.
            #
            # The three existing callers all move in the CORRECT direction: a
            # `#` inside `"$( … )"` really does start a comment there, a `<<`
            # really would open a heredoc, and a named call really is a call.
            # `${…}` is deliberately NOT treated this way — it is an expansion,
            # not a nested command — so `"${x#y}"` keeps its old answer.
            if (inq == "\"" && c == "$" && substr(s, i + 1, 1) == "(") {
                sp++; stack[sp] = inq; depth[sp] = 1; inq = ""
                out = out "00"; i++
                continue
            }
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
        if (sp > 0) {
            if (c == "(") depth[sp]++
            else if (c == ")") {
                depth[sp]--
                if (depth[sp] == 0) { inq = stack[sp]; sp--; out = out "0"; continue }
            }
        }
        # A BACKSLASH OUTSIDE ANY QUOTE ESCAPES THE NEXT CHARACTER, and the
        # character it most often escapes is a quote (your-org/nexus-code#1227
        # residue). The idiom `'…'\''…'` — close, escaped literal quote,
        # reopen — is how a single-quoted string carries an apostrophe, and it
        # is dense in this repo's printf messages. Read without this rule the
        # scanner closes the string at the first `'`, OPENS a new one at the
        # escaped `'`, and is then inverted for the rest of the file: every
        # comment after it survives stripping as CODE. Measured at 8ba5060e,
        # this one shape at monitor/ng:11436 left the 33 column-0 comment lines
        # after it classified as code. Both bytes are code (mask 0), which is
        # also right for `\$`, `\\` and a line-continuation `\` at end of line.
        if (c == "\\") {
            out = out "0"
            if (i < L) { out = out "0"; i++ }
            continue
        }
        if (c == "'" || c == "\"") { inq = c; out = out "1"; continue }
        out = out "0"
    }
    # A line that ENDS inside an unterminated `$( … )` continues as CODE, not as
    # the string it was nested in; reporting the outer quote would mark the next
    # line'"'"'s real code as text.
    QM_END = (sp > 0) ? "" : inq
    # The END-OF-LINE nesting depth, for callers carrying state across lines.
    # Pass it back as `sp0` together with the same `stack`/`depth` arrays.
    QM_SP = sp
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
