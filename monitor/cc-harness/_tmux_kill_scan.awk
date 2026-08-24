# monitor/cc-harness/_tmux_kill_scan.awk — scanner for lint-no-tmux-server-kill.sh
#
# Emits "line:rule:text" for each violation. Split out of the lint so the
# data-vs-code analysis is testable on its own and readable as one thing.
#
# WHY A PARSER AND NOT A REGEX. The first version of this lint decided
# "is this an invocation?" by requiring whitespace on both sides of the verb.
# That silently misreads `assert_contains "…" "tmux kill-window -t @42"` as a
# CALL — the verb is whitespace-delimited inside a quoted string. Under the
# original kill-server-only ruleset that mistake was invisible; the moment the
# verb family widened to kill-window it would have produced a wave of false
# positives on assertion strings, and the fix for those is always a pragma,
# which is precisely how a counted escape hatch erodes into noise.
#
# So: split each line into COMMAND FRAGMENTS, and treat a verb as an
# invocation only when its fragment's command word is a tmux reference.

function strip_comment(s,   i, c, sq, dq, out) {
    # Remove a trailing comment. A '#' only opens a comment when it is
    # unquoted AND at a word boundary. tmux format strings (`#{window_index}`,
    # `#S`) must survive, hence the word-boundary requirement rather than a
    # naive index($0,"#").
    sq = 0; dq = 0; out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "'" && !dq) sq = !sq
        else if (c == "\"" && !sq) dq = !dq
        else if (c == "#" && !sq && !dq) {
            # word boundary = start of line or preceded by whitespace
            if (i == 1 || substr(s, i-1, 1) ~ /[[:space:]]/) return out
        }
        out = out c
    }
    return out
}

function is_tmux_word(w) {
    # Strip shell decoration: quotes, $, {}, (), backticks, path prefix.
    gsub(/["'\''`${}()]/, "", w)
    sub(/^.*\//, "", w)
    return (tolower(w) ~ /tmux/)
}

function unbalanced_quote(w,   i, c, sq, dq) {
    # Does this token end inside a quote? Same quote bookkeeping as
    # strip_comment above.
    sq = 0; dq = 0
    for (i = 1; i <= length(w); i++) {
        c = substr(w, i, 1)
        if (c == "'" && !dq) sq = !sq
        else if (c == "\"" && !sq) dq = !dq
    }
    return (sq || dq)
}

function first_command_word(frag,   n, i, parts, w) {
    # Drop leading VAR=value environment assignments, then return the command
    # word. `TMUX_TMPDIR="$TSOCK" "$REAL_TMUX" kill-server` -> `"$REAL_TMUX"`.
    sub(/^[[:space:]]+/, "", frag)
    n = split(frag, parts, /[[:space:]]+/)
    for (i = 1; i <= n; i++) {
        w = parts[i]
        if (w == "") continue
        # env-assignment prefix (VAR=..., possibly quoted value)
        if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
            # The VALUE may be quoted and contain whitespace, so the split
            # above cut it in half: `IFS=" " tmux kill-server` arrives as
            # `IFS="`, `"`, `tmux`, … The prefix arm swallowed `IFS="` and the
            # loop then returned `"` as the command word, `is_tmux_word("")`
            # said no, and an UNSCOPED kill-server was reported clean. That is
            # the same assignment-prefix blind spot as your-org/nexus-code#775,
            # but fail-OPEN rather than fail-closed: #775 cries wolf on a
            # correct doc snippet, this one waves a real server-killer through.
            # Rejoin tokens until the quote balances.
            while (unbalanced_quote(w) && i < n) { i++; w = w parts[i] }
            continue
        }
        # command modifiers that precede the real command word
        if (w == "exec" || w == "command" || w == "builtin" || w == "time") continue
        if (w == "env") continue
        if (w ~ /^-/) continue          # env's -u FLAG etc.
        if (w == "TMUX" || w == "TMUX_TMPDIR") continue   # `env -u TMUX <cmd>`
        return w
    }
    return ""
}

# Split a line into command fragments on shell separators. Deliberately
# includes the bodies of `trap '...'` / `eval '...'` / `$(...)`, because a
# kill inside a trap body is a real deferred invocation — the very form that
# armed the incident.
function fragments(s, out,   tmp, n, i, j, m, sub2, k, cnt) {
    gsub(/\|\||&&|;|\||\$\(|`|\{|\}/, "\001", s)
    # trap 'BODY' / eval 'BODY' — unwrap so BODY is analysed as code.
    gsub(/(^|\001)[[:space:]]*(trap|eval)[[:space:]]+['\''"]/, "\001", s)
    n = split(s, tmp, /\001/)
    cnt = 0
    for (i = 1; i <= n; i++) if (tmp[i] ~ /[^[:space:]]/) out[++cnt] = tmp[i]
    return cnt
}

function has_socket_pin(frag) {
    return (frag ~ /(^|[^[:alnum:]_-])-(L|S)([[:space:]]|=)/)
}
function pins_default_socket(frag) {
    # -L default / -S <path>/default is syntactically a pin and semantically
    # the operator's own server. Fatal, and it satisfies has_socket_pin().
    return (frag ~ /(^|[^[:alnum:]_-])-L[[:space:]]+["'\'']?default["'\'']?([[:space:]]|$)/ \
         || frag ~ /(^|[^[:alnum:]_-])-S[[:space:]]+[^[:space:]]*\/default([[:space:]]|$)/)
}
function has_targeted(frag) {
    return (frag ~ /(^|[^[:alnum:]_-])-t([[:space:]]|=)/)
}
function neutralises_tmux(frag) {
    # LOCAL neutralisation only — on THIS command. A file-scoped search was the
    # original design and it was wrong twice over: it fired on zero lines of the
    # file that caused the incident (which carries `unset TMUX` inside a heredoc
    # at line 277), and a single `unset TMUX` in a COMMENT silenced the rule for
    # a whole file. Both are self-service hatches; neither is counted.
    return (frag ~ /env[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-u[[:space:]]+TMUX([[:space:]]|$)/)
}

{
    raw = $0
    line = strip_comment(raw)
    pragma = (raw ~ /#[[:space:]]*tmux-scoped:/)

    nf = fragments(line, frag)
    for (fi = 1; fi <= nf; fi++) {
        f = frag[fi]
        cw = first_command_word(f)
        if (cw == "" || !is_tmux_word(cw)) continue     # not a tmux invocation

        verb = ""
        if (f ~ /(^|[[:space:]])kill-server([[:space:]]|$)/)  verb = "kill-server"
        else if (f ~ /(^|[[:space:]])kill-session([[:space:]]|$)/) verb = "kill-session"
        else if (f ~ /(^|[[:space:]])kill-window([[:space:]]|$)/)  verb = "kill-window"
        else if (f ~ /(^|[[:space:]])kill-pane([[:space:]]|$)/)    verb = "kill-pane"

        # --- rule4: a pin that names the DEFAULT socket is not isolation ----
        if (pins_default_socket(f)) {
            printf "%d:rule4-pins-default-socket:%s\n", FNR, raw
            continue
        }

        # --- rule2: TMUX_TMPDIR is never sufficient on its own --------------
        # Fires on ANY tmux invocation, not only destructive ones: an
        # unisolated `new-session` pollutes the operator's server and an
        # unisolated `kill-window` can end it. The defect is the SCOPING
        # IDIOM, not the verb, so keying on the idiom closes the class.
        if (f ~ /TMUX_TMPDIR=/ && !has_socket_pin(f) && !neutralises_tmux(f)) {
            printf "%d:rule2-tmux-tmpdir-insufficient:%s\n", FNR, raw
        }

        if (verb == "") continue

        # --- rule1: kill-server must be socket-pinned at the call site -----
        if (verb == "kill-server" && !has_socket_pin(f) && !pragma) {
            printf "%d:rule1-killserver-unscoped:%s\n", FNR, raw
        }

        # --- rule3: a kill that can end the server must name a target ------
        # Untargeted kill-session/window/pane acts on the CURRENT one; when
        # that is the last of its kind the server exits. Proven for
        # kill-window: killing the last window of the last session leaves
        # "no server running".
        if (verb != "kill-server" && !has_targeted(f) && !pragma) {
            printf "%d:rule3-untargeted-kill:%s\n", FNR, raw
        }
    }
}
