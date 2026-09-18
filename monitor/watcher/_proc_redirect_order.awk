# _proc_redirect_order.awk — one row per REDIRECTION-ORDER site.
#
# THE AXIS (your-org/nexus-code#1305). Redirections are performed LEFT TO
# RIGHT, so in
#
#     cmd < "/proc/$pid/cmdline" 2>/dev/null
#
# the `<` is attempted while stderr is still the terminal, and the
# `2>/dev/null` takes effect afterwards — on a command that never ran. The
# diagnostic the author believed they had silenced is emitted anyway.
#
# THE PREDICATE IS KEYED ON THE HAZARD, NOT ON THE SHAPE, and that is the whole
# design. `#1305` declines to establish a population precisely because the
# shape alone is not a defect: `< <(…)` cannot fail this way, and `< "$f"` on a
# file the same code just created is fine. What makes it a defect is a target
# that CAN BE ABSENT AT READ TIME — a runtime property, not a syntactic one. So
# this keys on the one family where absence is routine and unavoidable:
#
#   * the target is under /proc, AND
#   * the target carries a shell EXPANSION (a `$`).
#
# A `$` in the path is what makes it a per-PROCESS path, and a process can exit
# between any two instructions. `/proc/stat` and `/proc/sys/...` carry no
# expansion, cannot race, and are deliberately NOT sites — stated as an
# exemption with a reason rather than left to be inferred from a silent pass.
#
# NOT A SITE, and each for a stateable reason:
#   `{ cmd < "/proc/$p/x"; } 2>/dev/null`   the group closes BEFORE the 2>
#   `cmd 2>/dev/null < "/proc/$p/x"`        the silence is established FIRST
#   a comment line                          text, not a redirection
#
# The two correct forms differ in robustness, not in effect: the GROUPED form
# is order-INDEPENDENT and reads as what it means, so it is what this repo
# standardises on. The stderr-first form is accepted here because it is
# genuinely correct, and rejecting a correct form would be a lint teaching a
# superstition.
#
# Emits: <file>\t<line>\t<code>
{
    line = $0
    stripped = line
    sub(/^[ \t]*/, "", stripped)
    if (substr(stripped, 1, 1) == "#") next

    # Locate a `<` redirection whose target is a /proc path with an expansion.
    # `match` finds the FIRST such; one site per line is enough to flag it.
    if (match(line, /<[ \t]*"?\/proc\/[^" \t;)]*\$[^" \t;)]*/) == 0) next
    redir_end = RSTART + RLENGTH

    rest = substr(line, redir_end)
    # Already grouped: the brace closes before anything else on the line.
    if (rest ~ /^"?[ \t]*;[ \t]*\}/) next
    # No later stderr redirection on this line -> nothing was silenced here.
    if (rest !~ /2>/) next

    printf "%s\t%d\t%s\n", FILENAME, FNR, stripped
}
