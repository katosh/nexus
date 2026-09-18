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
    # A token glued by glue_quoted_space() is a quoted string containing
    # whitespace — a string literal, never a command word. Rejecting it here
    # matters because this test is a SUBSTRING match: glue `"tmux kill-server"`
    # into one token and it trivially "contains tmux", which promoted a hook
    # fixture into a rule2 report. Nothing is lost — before gluing, the same
    # literal split into `"command":"tmux` / `kill-server"` and was rejected
    # too. The one form this cannot see is a tmux binary whose PATH contains a
    # space (`"/opt/my tools/tmux" kill-server`); that was already invisible,
    # for the same reason, so this is not a new blind spot.
    if (w ~ /\003/) return 0
    # Strip shell decoration: quotes, $, {}, (), backticks, path prefix.
    gsub(/["'\''`${}()]/, "", w)
    sub(/^.*\//, "", w)
    return (tolower(w) ~ /tmux/)
}

# --- a quoted string is ONE word, whatever whitespace it contains ------------
#
# WHY. Word-splitting happens BEFORE quote-stripping everywhere downstream, so
# `"tmux kill-server"` arrives as the two tokens `"tmux` and `kill-server"`, and
# `sub_verb`'s decoration-stripper then turns the second into a bare
# `kill-server`. The quote it removed was the DELIMITER of the string literal —
# the very character proving the verb is data. Thirteen lines of
# `monitor/watcher/test-bash-footgun-guard.sh` (hook fixtures of the form
# `run '{"tool_input":{"command":"tmux kill-server"}}'`) were reported as
# unscoped call sites this way, and because `gate.sh` runs this lint as a
# pre-flight the whole gate refused before a single scenario ran.
#
# Deleting the decoration-stripper is NOT the fix: it is what lets
# `"$REAL_TMUX" kill-server` — the real culprit of your-org/nexus-code#644 — be
# recognised as a tmux invocation at all. The defect is that splitting on
# whitespace erases the distinction between a delimiter and decoration.
#
# So glue instead: inside a quoted region, whitespace is not a word boundary.
# `"tmux kill-server"` becomes a SINGLE token, and `is_tmux_word` rejects any
# glued token outright (see there) — so the fragment is never read as a tmux
# invocation and there is no following word for `sub_verb` to promote.
# `"$REAL_TMUX"` holds no whitespace and is untouched, so the incident fixture
# still fires on both rule1 and rule2, byte-for-byte as before.
#
# Ordering is load-bearing: this runs AFTER the trap/eval unwrap, so a
# `trap 'tmux kill-server …'` body — whose opening quote the unwrap has already
# consumed, precisely because it IS deferred code — is not glued and stays
# visible. Same quote bookkeeping as strip_comment().
function glue_quoted_space(s,   i, c, sq, dq, out) {
    sq = 0; dq = 0; out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "'" && !dq) sq = !sq
        else if (c == "\"" && !sq) dq = !dq
        else if ((sq || dq) && c ~ /[[:space:]]/) c = "\003"
        out = out c
    }
    return out
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

# --- tmux's REAL command grammar (your-org/nexus-code#892, skeptic F2/F3) ----
#
# tmux accepts any UNAMBIGUOUS PREFIX of a command name, so `kill-ser` IS
# `kill-server`. Matching full names let every abbreviation of every kill verb
# scan CLEAN; measured, `tmux kill-ser` killed a real server while this lint
# reported nothing. Nothing else in tmux's command set begins with `k`, so
# prefix-matching against the four kill verbs cannot capture a legitimate
# non-kill command. An abbreviation matching SEVERAL kill verbs (`kill-s`) is
# ambiguous to tmux and would be rejected by tmux itself; resolving it to the
# strictest reading costs nothing.
function kill_canon(w,   n, arr, i, hit, cnt) {
    if (w == "") return ""
    # killp / killw are BUILT-IN SHORT FORMS, not command-aliases
    # (`list-commands` prints `kill-pane (killp)`), and they are NOT prefixes of
    # the long names — so a prefix rule over the long names alone misses them.
    n = split("kill-server kill-session kill-window kill-pane killp killw", arr, " ")
    hit = ""; cnt = 0
    for (i = 1; i <= n; i++)
        if (substr(arr[i], 1, length(w)) == w) { hit = arr[i]; cnt++ }
    if (cnt > 1) return "kill-server"
    if (hit == "killp") return "kill-pane"
    if (hit == "killw") return "kill-window"
    return hit
}

# The verb of ONE sub-command. `is_first` says whether this sub-command still
# carries the leading `tmux` word (and any env prefix / global flags) ahead of
# its verb; later sub-commands in a `\;` sequence do not.
function sub_verb(sc, is_first,   n, parts, i, w, seen_cmd, want_val) {
    n = split(sc, parts, /[[:space:]]+/)
    seen_cmd = is_first ? 0 : 1
    want_val = 0
    for (i = 1; i <= n; i++) {
        w = parts[i]
        if (w == "") continue
        if (!seen_cmd) {
            if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
            if (w == "exec" || w == "command" || w == "builtin" || w == "time") continue
            if (w == "env") continue
            if (w ~ /^-/) continue
            if (w == "TMUX" || w == "TMUX_TMPDIR") continue
            if (is_tmux_word(w)) { seen_cmd = 1; continue }
            continue
        }
        if (want_val) { want_val = 0; continue }     # value of -L/-S/-c/-f
        if (w ~ /^-/) {
            if (w ~ /^-[^-]*[cfLS]$/) want_val = 1
            continue
        }
        gsub(/["'\''`${}()]/, "", w)
        return w
    }
    return ""
}

# Split a line into command fragments on shell separators. Deliberately
# includes the bodies of `trap '...'` / `eval '...'` / `$(...)`, because a
# kill inside a trap body is a real deferred invocation — the very form that
# armed the incident.
function fragments(s, out,   tmp, n, i, j, m, sub2, k, cnt) {
    # `\;` is a TMUX COMMAND SEPARATOR, not a shell one (your-org/nexus-code#892,
    # skeptic F3). Splitting on it as if it were shell punctuation tore
    # `tmux list-windows \; kill-server` into two fragments, and the second lost
    # its `tmux` command word — so the kill was invisible and the line scanned
    # CLEAN. Measured: that exact command killed a real server. Protect it here
    # and let the verb scanner treat it as the sub-command separator it is.
    gsub(/\\;/, "\002", s)
    gsub(/\|\||&&|;|\||\$\(|`|\{|\}/, "\001", s)
    # trap 'BODY' / eval 'BODY' — unwrap so BODY is analysed as code.
    gsub(/(^|\001)[[:space:]]*(trap|eval)[[:space:]]+['\''"]/, "\001", s)
    # A quoted string is one word — AFTER the unwrap above, so deferred bodies
    # stay code while string literals stop yielding a bare verb. See
    # glue_quoted_space().
    s = glue_quoted_space(s)
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

        # Split this invocation into its `\;`-separated sub-commands and take
        # the verb of each: a kill in ANY position counts, not just the first.
        nsc = split(f, sc, /\002/)

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

        # --- rules 1 and 3, PER SUB-COMMAND --------------------------------
        # Each `\;`-separated sub-command carries its own verb and its own
        # `-t`; the socket pin is global to the invocation and so is still
        # tested against the whole fragment.
        for (si = 1; si <= nsc; si++) {
            verb = kill_canon(sub_verb(sc[si], si == 1))
            if (verb == "") continue

            # --- rule1: kill-server must be socket-pinned at the call site -
            if (verb == "kill-server" && !has_socket_pin(f) && !pragma) {
                printf "%d:rule1-killserver-unscoped:%s\n", FNR, raw
            }

            # --- rule3: a kill that can end the server must name a target --
            # Untargeted kill-session/window/pane acts on the CURRENT one;
            # when that is the last of its kind the server exits. Proven for
            # kill-window: killing the last window of the last session leaves
            # "no server running".
            if (verb != "kill-server" && !has_targeted(sc[si]) && !pragma) {
                printf "%d:rule3-untargeted-kill:%s\n", FNR, raw
            }
        }
    }
}
