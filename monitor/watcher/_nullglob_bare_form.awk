# _nullglob_bare_form.awk — classify one shell file's lines for the
# NULLGLOB + BARE-FORM pairing. your-org/nexus-code#1214 S1.
#
# Emits: <line>\t<command>\t<glob-token>\t<normalized-source-line>
#
# The FOURTH field is the CONTENT KEY (your-org/nexus-code#1214, #1238
# collision). The manifest used to key each site by `<file>:<LINE>`, which is
# load-bearing on a number that MOVES: one line inserted anywhere above a
# recorded site rekeys it, and the guard then reports the same site as both
# ADDED and REMOVED. That fired across two PRs with NO textual overlap --
# `#1238` inserted one line at `monitor/ng:548` and shifted three rows
# recorded at 1316/1326/1329 -- so there was no diff-level trace of the
# dependency at all. The normalized line is the source text with whitespace
# runs collapsed to one space and the ends trimmed: it survives insertion
# elsewhere in the file and it survives reindentation, and it CHANGES when the
# site's own text changes, which is exactly when a recorded disposition should
# stop being trusted.
#
# Normalization is whitespace-only ON PURPOSE. Blanking quoted spans (which
# this file does before CLASSIFYING) would make two sites with different
# paths share a key -- `cat "$D"/.wf1.*` and `cat "$D"/.wf2.*`, both recorded
# `defect`, differ only inside the quotes' neighbourhood. So the key is the
# RAW text; the blanking is a classification step, not a keying one.
#
# THE PAIRING IS THE AXIS, not `ls ` and not a glob spelling. A glob that can
# match nothing is harmless next to a command that ERRORS without arguments
# (`stat`, `rm`, `chmod`) — an unmatched glob under nullglob then yields no
# argument and the command complains. It is a defect next to a command that does
# something MEANINGFUL with no arguments: `ls`/`du` act on the CWD, and
# `cat`/`grep`/`wc`/`sort` read STDIN. Only the second kind converts a vanished
# glob into a confident wrong answer instead of a loud failure.
#
# Quoted spans are blanked before matching, because a `*` inside a `sed`/`grep`
# PATTERN is not a pathname glob — that distinction is 33 raw hits down to the
# real ones, and getting it wrong would bury the signal.
BEGIN {
    # Commands with a meaningful BARE form. `-v BARE=` overrides for the tests.
    if (BARE == "") BARE = "ls|cat|du|wc|head|tail|sort|uniq|nl|md5sum|sha256sum|grep|egrep|fgrep|cksum|paste|column"
}
{
    line = $0
    # ---- the CONTENT KEY: raw text, whitespace normalized ------------------
    # Computed from $0 BEFORE any blanking, so two sites differing only inside
    # quotes keep distinct keys.
    nl = $0
    gsub(/[[:space:]]+/, " ", nl)
    sub(/^ /, "", nl); sub(/ $/, "", nl)
    # ---- blank out quoted spans and strip a trailing comment ----------------
    out = ""; q = ""; n = length(line)
    for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (q == "") {
            if (c == "#") break                       # comment: rest is prose
            if (c == "'" || c == "\"") { q = c; out = out " "; continue }
            out = out c
        } else {
            if (c == "\\" && q == "\"") { i++; out = out " "; continue }
            if (c == q) { q = "" }
            out = out " "
        }
    }
    if (out ~ /^[[:space:]]*$/) next

    # ---- a bare-form command at a COMMAND position -------------------------
    # Command position: start of line, or after a separator / opener / operator.
    if (out !~ ("(^|[;&|(){}]|\\$\\(|&&|\\|\\||[[:space:]]then[[:space:]]|[[:space:]]do[[:space:]])[[:space:]]*(" BARE ")[[:space:]]")) next
    rest = out
    if (!match(rest, "(" BARE ")[[:space:]]")) next
    cmd = substr(rest, RSTART, RLENGTH - 1)
    sub(/[[:space:]]+$/, "", cmd)
    rest = substr(rest, RSTART + RLENGTH)
    # stop at the first pipe/redirect/terminator: later stages are not this
    # command's file arguments
    if (match(rest, /[|;&<>]/)) rest = substr(rest, 1, RSTART - 1)

    # ---- a GLOB in a file-argument position --------------------------------
    nf = split(rest, a, /[[:space:]]+/)
    for (j = 1; j <= nf; j++) {
        t = a[j]
        if (t == "" ) continue
        if (t ~ /^-/) continue                        # an option, not a path
        if (t !~ /[*?]/) continue                     # no glob
        if (t !~ /[\/.]/) continue                    # not path-like
        printf "%d\t%s\t%s\t%s\n", FNR, cmd, t, nl
        break
    }
}
