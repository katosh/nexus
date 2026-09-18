# _trap_bare_return.awk — the classifier behind trap-bare-return-lint.sh:
# every function STATICALLY REACHABLE from a trap handler that contains a
# bare `return` (your-org/nexus-code#1513 w234 round 1, the SIGF case).
#
# Loaded together with _shell_quotes.awk (`awk -f _shell_quotes.awk -f this`),
# whose `quote_mask` is the ONE shell-quote state machine in this tree; a second
# copy of it is the #842 mistake.
#
# INPUT. One argument: a TSV map `<id>\t<repo-relative path>\t<stripped file>`.
# Each stripped file is the output of `shf_strip_comments` (heredoc bodies
# blanked, comment text removed, LINE COUNT PRESERVED) so every line number
# below is the source file's own.
#
# THE MECHANISM (bash, builtins/return.def, get_exitstat): a `return` with no
# argument executed while ANY trap handler is running — in the handler string
# itself or in any function the handler calls, however deep — returns
# `trap_saved_exit_value`, the status of the last command before the trap
# fired, NOT the status of the command preceding the `return`. `return N` and
# `return $?` are unaffected (the argument is used). DEBUG traps are the one
# documented exception and are not distinguished here (over-count, stated).
#
# WHAT IS COMPUTED, in order:
#
#   1. FUNCTIONS. `name() {`, `function name {`, `function name() {`, with the
#      body delimited by brace depth counted over the line's CODE (quoted spans
#      removed via the mask, quote state carried ACROSS lines so a multi-line
#      awk program in single quotes contributes neither braces nor `return`s).
#      Nested definitions push a stack; a bare return is attributed to the
#      INNERMOST open function.
#   2. BARE RETURNS. `return` as a complete statement on a CODE line: preceded
#      by start-of-line, whitespace or one of `; { ( | &`, followed by
#      end-of-line, whitespace-then-terminator, or one of `; } ) | &`.
#      So `return`, `return;`, `&& return`, `|| return`, `then return`,
#      `{ …; return; }` are bare; `return 0`, `return $?`, `return "$rc"` are
#      not. A `return` inside a string is not code and is not seen.
#   3. TRAP SITES. The word `trap` in COMMAND POSITION on a code line (start
#      of line or after `; & | ( then else do`), followed by an optional `--`
#      and a HANDLER word: a quoted string (its raw text, continued across
#      lines while the quote is open) or a bare word (a function name). `trap
#      -`, `trap ''`, `trap -p`, `trap -l` install no handler. A handler that
#      is a VARIABLE (`trap "$h" EXIT`) is recorded as DYNAMIC and reaches
#      nothing (under-count, stated). `th_trap_exit <arg>` — this tree's
#      trap-appending wrapper (_test_helpers.sh) — is a trap site too.
#   4. REACHABILITY. Identifier tokens of a handler string, and of each
#      reached function's body, that NAME a function are edges. A name is
#      resolved LOCALLY (same file) first, otherwise in files whose BASENAME
#      the file sources (`. x` / `source x`, textual). Variables are removed
#      before tokenising so `$cleanup` is not a call; a name inside `$( … )`
#      is a call and is kept.
#   5. VERDICT. A function that is REACHED and holds a bare return is a site:
#      one row per bare-return line.
#
# DIRECTION, per axis, so the reader knows what a zero means:
#   * reachability OVER-counts: a function NAME mentioned as text on a code
#     line (an argument, a path segment, a printf %s operand that is unquoted)
#     is an edge; and `th_trap_exit`'s argument may be inert.
#   * reachability UNDER-counts: dynamic dispatch (`"$@"`, `eval`, `$fn`,
#     `trap "$h"`), a handler installed by a SOURCED library that names a
#     function of the SOURCING file, and a file sourced through a path this
#     text scan cannot resolve to a basename.
#   * bare-return detection UNDER-counts only where the quote state desyncs
#     (a `$'…'` string, a quote escaped outside a string) — the same boundary
#     `_shell_quotes.awk` states for itself.
#
# OUTPUT (stdout), one row per line, TAB-separated, first field a record kind:
#   SITE   <file>:<line>  <function>  <chain>
#   REACH  <file>  <function>  <chain>            (when -v mode=reachable)
#   FN     <file>  <function>  <start>-<end>  <bare lines|->   (mode=census)
#   STAT   <key>=<value> …                        (always, last line; trap_files counts
#          files holding at least one trap site, the "trap-bearing files" of the census)
# Chains read `trap@<file>:<line> -> a() -> b()`; a cross-file hop carries
# `@<file>` on the callee.

# masked_code(s, m) -> s with every QUOTED SPAN (mask "1") replaced by ONE
# placeholder `~`. Replaced, not removed: `return "$rc"` with its argument
# deleted reads `return `, which is the bare form this lint exists to flag —
# the first run over this tree reported exactly that false positive at
# bootstrap-install.sh:81. `~` is neither a name character nor a shell
# metacharacter, so brace counting, tokenising and the return test all see a
# word there without seeing its text.
function masked_code(s, m,   i, L, out, inq) {
    L = length(s); out = ""; inq = 0
    for (i = 1; i <= L; i++) {
        if (substr(m, i, 1) == "0") { out = out substr(s, i, 1); inq = 0 }
        else if (!inq) { out = out "~"; inq = 1 }
    }
    return out
}

# tokens(code) -> " t1 t2 … " — identifier tokens of a code string, with
# variables removed first so `$cleanup` and `${cleanup:-}` are not calls.
function tokens(code,   s, n, parts, i, out) {
    s = code
    gsub(/\$\{[^}]*\}/, " ", s)
    gsub(/\$[A-Za-z_][A-Za-z0-9_]*/, " ", s)
    gsub(/[^A-Za-z0-9_.:-]+/, " ", s)
    n = split(s, parts, " ")
    out = " "
    for (i = 1; i <= n; i++) if (parts[i] != "" && index(out, " " parts[i] " ") == 0) out = out parts[i] " "
    return out
}

# shell_words(raw, m, W) -> number of words; W[k] is the raw text of word k
# (quotes kept), split at UNQUOTED whitespace and metacharacters; the
# metacharacters themselves become one-char words so command position can be
# recognised. Only used on lines that mention `trap` in code.
function shell_words(raw, m, W,   i, L, c, q, cur, n) {
    L = length(raw); n = 0; cur = ""
    for (i = 1; i <= L; i++) {
        c = substr(raw, i, 1); q = substr(m, i, 1)
        if (q == "1") { cur = cur c; continue }
        if (c ~ /[ \t]/) { if (cur != "") { W[++n] = cur; cur = "" } ; continue }
        if (c ~ /[;&|()]/) {
            if (cur != "") { W[++n] = cur; cur = "" }
            # `&&` / `||` / `;;` collapse into one word
            if (n > 0 && W[n] == c && (c == "&" || c == "|" || c == ";")) { W[n] = c c; continue }
            W[++n] = c; continue
        }
        cur = cur c
    }
    if (cur != "") W[++n] = cur
    return n
}

function is_cmd_boundary(w) { return (w == ";" || w == ";;" || w == "&" || w == "&&" || w == "|" || w == "||" || w == "(" || w == ")" || w == "{" || w == "then" || w == "else" || w == "do" || w == "elif" || w == "if" || w == "while" || w == "until" || w == "!") }

# record a trap site; handler_raw is the handler word's raw text (quotes kept)
function add_trap(file, line, handler_raw, srcline,   h, kind) {
    nt++
    T_file[nt] = file; T_line[nt] = line; T_src[nt] = srcline
    if (!(file in trap_files)) { trap_files[file] = 1; ntrapfiles++ }
    h = handler_raw
    if (h ~ /^'/) { kind = "quoted"; sub(/^'/, "", h); sub(/'$/, "", h) }
    else if (h ~ /^"/) { kind = "quoted"; sub(/^"/, "", h); sub(/"$/, "", h); if (h ~ /^\$/) kind = "dynamic" }
    else if (h ~ /^\$/) kind = "dynamic"
    else kind = "word"
    T_kind[nt] = kind
    T_handler[nt] = h
    T_tok[nt] = (kind == "dynamic") ? " " : tokens(h)
    if (kind == "dynamic") ndyn++
    return nt
}

function open_fn(name, file, line, depth_before,   id) {
    id = ++nf
    F_name[id] = name; F_file[id] = file; F_start[id] = line; F_end[id] = 0
    F_bare[id] = ""; F_tok[id] = " "; F_open[id] = depth_before
    if (!((file SUBSEP name) in local_fn)) local_fn[file, name] = id
    byname[name] = byname[name] id " "
    fstack[++fsp] = id
    return id
}

function close_fn(id, line) { F_end[id] = line; fsp-- }

# resolve(name, file) -> " id1 id2 " of functions named `name` visible from file
function resolve(name, file,   out, list, n, parts, i, id, g) {
    if ((file SUBSEP name) in local_fn) return " " local_fn[file, name] " "
    out = " "
    list = byname[name]
    if (list == "") return out
    n = split(list, parts, " ")
    for (i = 1; i <= n; i++) {
        id = parts[i]; g = F_file[id]
        if (g != file && index(sources[file], " " (basename(g)) " ") > 0) out = out id " "
    }
    return out
}

function basename(p,   b) { b = p; sub(/.*\//, "", b); return b }

# BFS over the call graph from one trap
function walk_from(t,   queue, head, tail, id, name, cands, n, parts, i, cid, tok, k, m, chain) {
    head = 1; tail = 0
    # seeds: functions named in the handler
    cands = resolve_tokens(T_tok[t], T_file[t])
    n = split(cands, parts, " ")
    for (i = 1; i <= n; i++) {
        id = parts[i]
        if (id == "" || (id in reached)) continue
        reached[id] = 1
        R_chain[id] = "trap@" T_file[t] ":" T_line[t] " -> " F_name[id] "()" (F_file[id] != T_file[t] ? "@" F_file[id] : "")
        queue[++tail] = id
    }
    while (head <= tail) {
        id = queue[head++]
        cands = resolve_tokens(F_tok[id], F_file[id])
        m = split(cands, parts, " ")
        for (k = 1; k <= m; k++) {
            cid = parts[k]
            if (cid == "" || cid == id || (cid in reached)) continue
            reached[cid] = 1
            R_chain[cid] = R_chain[id] " -> " F_name[cid] "()" (F_file[cid] != F_file[id] ? "@" F_file[cid] : "")
            queue[++tail] = cid
        }
    }
}

# every function id a token list resolves to, from `file`
function resolve_tokens(toklist, file,   out, n, parts, i, r) {
    out = " "
    n = split(toklist, parts, " ")
    for (i = 1; i <= n; i++) {
        if (parts[i] == "" || !(parts[i] in byname)) continue
        r = resolve(parts[i], file)
        if (r != " ") out = out substr(r, 2)
    }
    return out
}

BEGIN {
    FS = "\t"; read_error = 0; ntrapfiles = 0
    nf = 0; nt = 0; ndyn = 0; nfiles = 0; nlines = 0
    while ((getline mapline < ARGV[1]) > 0) {
        split(mapline, mf, "\t")
        if (mf[2] == "" || mf[3] == "") continue
        nfiles++
        scan_file(mf[2], mf[3])
    }
    close(ARGV[1])
    if (read_error) { printf("STAT\trefused=read_error\n"); exit 3 }
    if (nfiles == 0) { printf("STAT\trefused=empty_map\n"); exit 3 }
    # reachability from every trap
    for (_t = 1; _t <= nt; _t++) walk_from(_t)
    nreach = 0
    for (fid in reached) nreach++
    nbare = 0; nsite = 0
    for (fid = 1; fid <= nf; fid++) if (F_bare[fid] != "") nbare++
    if (mode == "census")
        for (fid = 1; fid <= nf; fid++)
            printf("FN\t%s\t%s\t%d-%d\t%s\n", F_file[fid], F_name[fid], F_start[fid], F_end[fid], (F_bare[fid] == "" ? "-" : F_bare[fid]))
    for (fid = 1; fid <= nf; fid++) {
        if (!(fid in reached)) continue
        if (mode == "reachable") printf("REACH\t%s\t%s\t%s\n", F_file[fid], F_name[fid], R_chain[fid])
        if (F_bare[fid] == "") continue
        _n = split(F_bare[fid], bl, ";")
        for (_i = 1; _i <= _n; _i++) {
            if (bl[_i] == "") continue
            nsite++
            printf("SITE\t%s:%s\t%s\t%s\n", F_file[fid], bl[_i], F_name[fid], R_chain[fid])
        }
    }
    printf("STAT\tfiles=%d\tlines=%d\tfunctions=%d\ttraps=%d\ttrap_files=%d\tdynamic_traps=%d\treachable_functions=%d\tbare_return_functions=%d\tsites=%d\n",
           nfiles, nlines, nf, nt, ntrapfiles, ndyn, nreach, nbare, nsite)
    exit 0
}

# scan one stripped file, populating the tables above
function scan_file(file, path,   raw, m, code, ln, inq, sp, stack, depth, d, i, L, c, name, rest, nw, W, k, j, hw, pend, id, srcb, rc, s) {
    inq = ""; sp = 0; delete stack; delete depth
    fsp = 0; ln = 0; d = 0
    pend = 0            # a trap handler quote still open from a previous line
    sources[file] = " "
    while ((rc = (getline raw < path)) > 0) {
        ln++; nlines++
        m = quote_mask(raw, inq, sp, stack, depth)
        # a multi-line quoted trap handler: append until the quote closes
        if (pend) {
            T_handler[pend] = T_handler[pend] "\n" raw
            if (QM_END == "") { T_tok[pend] = tokens(T_handler[pend]); pend = 0 }
            inq = QM_END; sp = QM_SP
            continue
        }
        code = masked_code(raw, m)
        # --- sourced files (basenames), for cross-file resolution. The command
        # position is decided on CODE (a `.` or `source` word, so a `.` inside a
        # string is not a source); the BASENAMES are then read off the RAW line:
        # the path is almost always quoted and often carries a `$(dirname …)`
        # prefix whose parentheses defeat any word split, so every `/name` that
        # ends at a quote, a space, a separator or EOL is taken as a candidate
        # (over-count: a resolution candidate, never a verdict).
        if (code ~ /(^|[;&|( \t])(\.|source)([ \t]|$)/) {
            s = raw
            while (match(s, /\/[A-Za-z0-9_.+-]+(["'][ \t;&|)]|["']$|[ \t;&|)]|$)/)) {
                srcb = substr(s, RSTART + 1, RLENGTH - 1)
                sub(/["'].*$/, "", srcb); sub(/[ \t;&|)].*$/, "", srcb)
                if (srcb != "" && srcb != "." && srcb != ".." && srcb !~ /\$/ && index(sources[file], " " srcb " ") == 0)
                    sources[file] = sources[file] srcb " "
                s = substr(s, RSTART + RLENGTH)
            }
        }
        # --- function definition?
        name = ""
        if (match(code, /^[ \t]*function[ \t]+[A-Za-z_][A-Za-z0-9_.:-]*/)) {
            name = substr(code, RSTART, RLENGTH); sub(/^[ \t]*function[ \t]+/, "", name)
            rest = substr(code, RSTART + RLENGTH)
            sub(/^[ \t]*\(\)/, "", rest)
        } else if (match(code, /^[ \t]*[A-Za-z_][A-Za-z0-9_.:-]*[ \t]*\(\)/)) {
            name = substr(code, RSTART, RLENGTH); sub(/^[ \t]*/, "", name); sub(/[ \t]*\(\)$/, "", name)
            rest = substr(code, RSTART + RLENGTH)
        }
        if (name != "" && rest ~ /^[ \t]*(\{|$)/) {
            id = open_fn(name, file, ln, d)
            F_pending_brace[id] = (rest ~ /\{/) ? 0 : 1
        }
        # --- body text of every OPEN function gets this line's tokens, and a
        # bare return is attributed to the INNERMOST open function — BOTH before
        # the brace pass below closes anything. A one-liner `f() { …; return; }`
        # opens and closes on this very line; read after the close, its return
        # belonged to nobody and its callees were never walked (measured: the
        # first census missed test-nullglob-bare-form-manifest.sh:_sd_n).
        for (k = 1; k <= fsp; k++) {
            id = fstack[k]
            F_tok[id] = F_tok[id] substr(tokens(code), 2)
        }
        # --- bare return, attributed to the innermost open function
        if (fsp > 0 && code ~ /(^|[;{(|& \t])return([ \t]*([;})|&]|$))/) {
            id = fstack[fsp]
            F_bare[id] = F_bare[id] ln ";"
        }
        # --- brace depth over CODE; close functions whose body ended
        L = length(code)
        for (i = 1; i <= L; i++) {
            c = substr(code, i, 1)
            if (c == "{") {
                d++
                if (fsp > 0 && F_pending_brace[fstack[fsp]] == 1 && d == F_open[fstack[fsp]] + 1) F_pending_brace[fstack[fsp]] = 0
            } else if (c == "}") {
                d--
                while (fsp > 0 && F_pending_brace[fstack[fsp]] == 0 && d <= F_open[fstack[fsp]]) close_fn(fstack[fsp], ln)
                if (d < 0) d = 0
            }
        }
        # --- trap in command position (raw words, quotes kept)
        if (code ~ /(^|[;&|( \t])(trap|th_trap_exit)([ \t]|$)/) {
            nw = shell_words(raw, m, W)
            for (k = 1; k <= nw; k++) {
                if (W[k] != "trap" && W[k] != "th_trap_exit") continue
                if (k > 1 && !is_cmd_boundary(W[k-1])) continue
                j = k + 1
                if (j <= nw && W[j] == "--") j++
                if (j > nw) continue
                hw = W[j]
                if (W[k] == "trap" && hw ~ /^-/) continue           # trap -, -p, -l
                if (hw == "''" || hw == "\"\"") continue              # trap '' SIG: ignore
                if (is_cmd_boundary(hw)) continue
                id = add_trap(file, ln, hw, raw)
                # an unterminated quote: the handler continues on the next line
                if ((hw ~ /^'/ && hw !~ /'$/) || (hw ~ /^"/ && (length(hw) < 2 || hw !~ /"$/))) {
                    if (QM_END != "") pend = id
                }
            }
            delete W
        }
        inq = QM_END; sp = QM_SP
    }
    if (rc < 0) {
        printf("ERR\tcannot read stripped file %s for %s\n", path, file)
        read_error = 1
    }
    close(path)
    # functions still open at EOF (a brace count that never closed) end here
    while (fsp > 0) close_fn(fstack[fsp], ln)
}
