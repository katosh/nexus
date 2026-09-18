# _tmux_shim_scan.awk — classify every planted `tmux` shim in one shell file.
# your-org/nexus-code#1105, #1115, #1117.
#
# Emits one record per creation site:   <lineno>|<verdict>|<detail>
#
#   SAFE-WRITER   built by nx_write_tmux_shim, which REFUSES a wrapper at
#                 runtime by reading the candidate's magic bytes. That refusal
#                 cannot be spelled around, which is why it is the strongest
#                 verdict here and why routing through it is the recommended fix.
#   SAFE-STUB     the planted body never invokes another tmux at all (a mock
#                 that answers by itself is not a routing shim and cannot be
#                 displaced onto anything).
#   SAFE-REALBIN  the body's tmux target is a variable assigned from
#                 nx_real_tmux_bin.
#   SAFE-LITERAL  the body execs an absolute literal path that is not a wrapper.
#   UNSAFE        everything else.
#
# THE ARM THAT MATTERS IS THE LAST ONE. This is an ALLOWLIST WITH A
# DEFAULT-DENY ARM, the shape `_bookkeeping.sh::bk_pane_kill_authorized`
# prescribes and for the same reason: the previous version of this check was a
# DENYLIST of two source spellings, and a skeptic planted EIGHT idiomatic
# alternatives that all reached the operator's board and all passed. A denylist
# of spellings inherits the blind spot of whoever wrote it; an allowlist has to
# be argued past. A body this file cannot PROVE safe is reported UNSAFE, not
# ignored.
#
# DECLARED BOUNDARY — READ BEFORE TRUSTING A GREEN. This is a static scan of
# shell source, and it is not a proof:
#   * DISCOVERY is POSITIONAL since `#1184`, not a creation-shape denylist: a
#     site is any line that WRITES a path ending `/tmux` (literally, or via a
#     variable assigned such a path in the same file) — a redirection operand
#     anywhere on the line, a heredoc attached to such a write, or a write
#     utility carrying such a path as an argument. It does not key on what the
#     command is CALLED, which is what the previous four arms did.
#   * THE RESIDUAL IS SMALLER, NOT GONE. Enumeration is still SYNTACTIC: a
#     target assembled at runtime (`t=$D/$n; printf … > "$t"`, `$n` not
#     literal), a write through a variable holding the operator, or a path this
#     file never spells is NOT SEEN AT ALL, and its absence still looks exactly
#     like a pass. What changed is that an unreadable BODY at a DISCOVERED site
#     now reaches the default-deny arm instead of being silently not-a-site.
#     That residual is why the runtime refusal in nx_write_tmux_shim exists and
#     why routing through it — rather than passing this lint — is the actual fix.
#   * ENUMERATION is now PER SIMPLE COMMAND (your-org/nexus-code#1313). It used
#     to return on the LINE'S FIRST write route, so a line carrying two plants
#     reported one — and the residual that leaves is narrower but real: two
#     heredocs attached to ONE simple command (`cmd <<A <<B`) still share the
#     first delimiter, and a target assembled across commands is still unseen.
#   * Variable provenance is followed one level, within one file.
#   * AND THE DISTRIBUTION QUALIFIES THE VERDICT. A COUNT IS A PROPERTY OF A
#     TREE, so the ref is stated beside it. Measured on `703483b5` PLUS the
#     `#1184` commit this comment ships in, over the files the guard is not
#     exempt from — 115 sites across 82 files, against 110 across 79 at
#     `703483b5` itself (working tree clean there, so that baseline reads
#     exactly that ref).
#
#                       #1313   5bd6d400   #1184   703483b5
#         SAFE-STUB        92        92        91       90     <- PROVEN mock (#1119)
#         SAFE-REALBIN      9         9         9        9
#         SAFE-WRITER       4         4         4        7     <- 3 of the 7 were COMMENTS
#         UNSAFE           13        12        11        4     <- named + argued in EXEMPT_SITES
#
#     THE #1313 COLUMN IS THIS FILE AFTER PER-COMMAND ENUMERATION, against the
#     SAME ref (`5bd6d400`) in the column beside it, so the delta is the CHANGE
#     and nothing else. +1 UNSAFE is ONE RECORD, and it is a LIVE second plant,
#     not a latent one: `test-tmux-shim.sh:534` is
#     `cp "$SHIM_DIR/tmux" "$TWO_A/tmux"; cp "$SHIM_DIR/tmux" "$TWO_B/tmux"`,
#     and no version of this scanner had ever reported the SECOND copy.
#     `#1313` filed this as having ZERO live instances; re-measured here it has
#     one, which is why it was worth fixing rather than watching.
#     One record also CHANGED ITS DETAIL without changing its verdict:
#     `test-tmux-shim.sh:595` read `body names the wrapper LITERALLY` on a body
#     that was the WHOLE LOGICAL LINE — the `tmuxwrap` it named belongs to a
#     `grep -q` ASSERTION four commands later, not to the `sed` that writes. Red
#     for the right reason by accident, naming the wrong statement (`#1210`); the
#     copy body is now scoped to its own simple command and it reads
#     `source not resolved`. The copy arm is default-DENY, so scoping a copy body
#     can never produce a SAFE — the verdict is structurally unable to move.
#
#     READ THE TWO DELTAS TOGETHER OR EACH IS MISLEADING ON ITS OWN.
#     +7 UNSAFE is NOT seven new hazards. Inverting discovery made SEVEN
#     PRE-EXISTING planting sites visible that no arm of the old denylist could
#     reach — three of them the `{ printf …; } > "$D/tmux"` compound-group shape,
#     which is the most idiomatic in this tree and was in none of the four arms.
#     Every one is argued per-site in test-tmux-shim-gate3-safety.sh.
#     -3 SAFE-WRITER is a CORRECTION, not a loss of coverage: the old arm was a
#     bare SUBSTRING search, and three of its seven records were COMMENT LINES
#     (`_harness.sh:172`, `test-pane-state.sh:1905`,
#     `test-paste-dead-pane-guard.sh:253`) — prose ABOUT the writer, sitting
#     above the real call. That is the standing, unplanted proof of the
#     arm-order defect fixed in Pass 2; see the comment there.
#
#         for f in $(find monitor -name '*.sh' -type f | sort); do
#             case "$f" in */test-tmux-shim-gate3-safety.sh|*/_tmux-fixture.sh) continue;; esac
#             awk -f monitor/watcher/_tmux_shim_scan.awk "$f"
#         done | cut -d'|' -f2 | sort | uniq -c
#
#     A GREEN HERE IS STILL CARRIED BY THE SAFE ARMS — but SAFE-STUB now means
#     something it did not mean before `#1119`. It used to be a hand-off
#     DENYLIST with a permissive default ("I could not find an `exec`"), which
#     is the same shape as the spelling denylist this scanner replaced, one
#     level in; it is now POSITIVE PROOF that every simple command in the body
#     is a keyword, a builtin, a body-local function, or a named external that
#     cannot execute another program. The four default-deny sites are named and
#     argued in `test-tmux-shim-gate3-safety.sh`'s `EXEMPT_SITES`: one
#     deliberate wrapper copy, and three mocks that use `awk` on literal
#     single-quoted programs.
#     Do not read "no unexempted UNSAFE offenders" as "the classifier proved the
#     corpus safe" — DISCOVERY is still by creation shape, and a shim planted
#     some other way is not seen at all.
# The classification arms are allowlisted; the DISCOVERY is not, and that
# asymmetry is the honest statement of what a green here means.

{ line[NR] = $0 }

function is_tmux_target(t,   n) {
    gsub(/["\047\[ \t]/, "", t)
    if (t ~ /\/tmux$/) return 1
    n = t; sub(/^\$\{?/, "", n); sub(/\}?$/, "", n)
    return (n in target_var)
}
function mentions_target_var(s,   n) {
    for (n in target_var) if (index(s, "$" n) || index(s, "${" n "}")) return 1
    return 0
}
# A COMMENT IS NOT CODE, and reading one as code produces a FALSE POSITIVE that
# is indistinguishable from a real finding. Measured: this file's own `#1021`
# stub carries the comment `# ...yet tmux resolves it`, which made a pure mock
# classify UNSAFE. A lint that cries wolf on its own fixtures gets disabled,
# which is how a guard dies. `#{` is NOT a comment — it opens a tmux FORMAT
# string (`-F '#{window_name}'`), and stripping those would silently blind the
# scan to the very bodies it exists to read.
# A `#` INSIDE A QUOTED SPAN IS NOT A COMMENT, and the `#[^{]` exception was too
# narrow (your-org/nexus-code#1119). It was written to protect `#{window_name}`
# and does not cover tmux's SHORT format aliases, so the case pattern
#
#     '#I #W')   printf '%d %s\n' "$idx" "$n" ;;
#
# was truncated at ` #W')` — leaving an UNTERMINATED single quote that swallowed
# every following line of the body. Harmless while quoted text was discarded
# wholesale; the moment a quoted word counts as a command word it produced a
# confident wrong offender. Measured on test-respawn.sh:101, :713 and
# test-spawn-fresh-orchestrator.sh:154.
#
# The scan is a local six-line loop rather than `_shell_quotes.awk`: this file
# is loaded as a standalone `awk -f` library by three callers and has no way to
# pull a second file in. That is a real cost — `#842` is about exactly this kind
# of duplication — but the alternative here was CHARACTER MATCHING, which is
# what `#842` actually objects to, and this replaces it with the mechanism.
function strip_comment(s,   i, L, c, inq, cut) {
    if (s ~ /^[ \t]*#/) return ""
    L = length(s); inq = ""; cut = 0
    for (i = 1; i <= L; i++) {
        c = substr(s, i, 1)
        if (inq != "") {
            if (c == "\\" && inq == "\"") { i++; continue }
            if (c == inq) inq = ""
            continue
        }
        if (c == "'" || c == "\"") { inq = c; continue }
        if (c != "#") continue
        # `#{` opens a tmux FORMAT string, never a comment, and stripping those
        # would blind the scan to the very bodies it exists to read.
        if (substr(s, i + 1, 1) == "{") continue
        # A comment starts at the start of a WORD.
        if (i > 1 && substr(s, i - 1, 1) !~ /[ \t]/) continue
        cut = i; break
    }
    if (cut > 1) return substr(s, 1, cut - 2)
    if (cut == 1) return ""
    return s
}
# IS THIS BODY PROVABLY A MOCK? (your-org/nexus-code#1119)
#
# THIS USED TO BE `is_routing_body()`, AND IT WAS A DENYLIST WITH A PERMISSIVE
# DEFAULT sitting inside an allowlist — as its highest-traffic verdict. It asked
# "can I find a hand-off?" (an `exec`, a line-leading absolute `/…/tmux`, a
# mention of a registered variable) and answered SAFE-STUB whenever it could
# not. 86% of this corpus was decided by that "I could not find a problem"
# test, which is the same shape as the spelling denylist the scanner replaced,
# one level in. Two escapes were MEASURED reaching the operator's live board
# through it, both merely by defeating its one-level `^[ \t]*NAME=` provenance:
#
#     export TMUX_BIN=$(command -v tmux)      + a body with no `exec`
#     read -r TMUX_BIN < <(command -v tmux)   + a body with no `exec`
#
# The terminal arm was never the problem — with no signature and no registered
# variable both fall to default-deny and are correctly UNSAFE. The default-deny
# arm worked; it was never reached.
#
# SO THE QUESTION IS INVERTED. `is_mock_body` demands POSITIVE PROOF: every
# simple command in the body is a shell keyword, a shell builtin, or a function
# DEFINED IN THE BODY ITSELF. Nothing else is proof — an external utility, a
# variable in command position, a command substitution and a backquote all fall
# through to default-deny, and a body this scanner cannot tokenise at all
# (empty extracted text) is denied rather than defaulted.
#
# WHY THE NAIVE FIX (`body ~ /"\$@"/` added to the denylist) WAS REJECTED: it
# cost 15 new UNSAFE across 14 files, one of which — `test-paste-followup.sh:94`
# — is a genuine self-answering mock whose `for a in "$@"` is argv INSPECTION,
# not forwarding. A lint that cries wolf on its own fixtures gets disabled.
# Measured on this corpus, the inversion classifies that exact site MOCK, and
# every site it does flag is flagged for a NAMED external invocation. The
# residual is recorded per-site, with its argument, in EXEMPT_SITES in
# test-tmux-shim-gate3-safety.sh — not defaulted. (That is a CORRECTED CITATION:
# both mentions here named `tmux-shim-unproven.manifest`, which exists nowhere in
# this repo — not tracked, not on disk. A reader who follows a dead pointer
# cannot tell whether the CLAIM or the POINTER is at fault, which is the quieter
# defect; the claim was true and its evidence was unreachable.)
#
# The earlier cut before either of these asked "does the body mention tmux?",
# which is not the same question and produced FALSE POSITIVES on three distinct
# shapes measured in this tree: a stub logging `"tmux \$*"` to a file, a
# `printf … > "$D/tmux"` whose only tmux is in the TARGET PATH rather than the
# body, and a stub whose case arms name tmux subcommands.
function _mock_init(   i, a) {
    if (MOCK_INIT) return
    MOCK_INIT = 1
    split("if then else elif fi for while until do done case esac in select " \
          "function time coproc", a, " "); for (i in a) MOCK_OK[a[i]] = 1
    # Builtins only. `eval` and `exec` are DELIBERATELY ABSENT: both invoke.
    split(": true false echo printf exit return shift local export unset " \
          "declare typeset readonly read set shopt break continue let " \
          "test cd pwd trap wait umask type builtin " \
          "getopts alias unalias jobs kill ulimit", a, " ")
    for (i in a) MOCK_OK[a[i]] = 1
    # TIER 2 — EXTERNAL utilities that CANNOT EXECUTE ANOTHER PROGRAM. This is
    # still an allowlist: a word absent from it is denied, and the claim behind
    # each member is checkable — none of these has any facility for running a
    # command. The EXCLUSIONS are the load-bearing half and are deliberate:
    #
    #   awk        `system()`, and `print | "cmd"`
    #   sed        GNU `e` / `s///e`
    #   find       `-exec` / `-execdir`
    #   xargs      its entire purpose
    #   env sh bash zsh timeout nohup setsid stdbuf nice ionice sudo ssh
    #              all take a command to run
    #   perl python ruby       arbitrary code
    #   watch parallel script  spawn
    #
    # A mock that needs one of those is not proven, falls to default-deny, and
    # is recorded per-site in EXEMPT_SITES (test-tmux-shim-gate3-safety.sh) with
    # its reason — data a reviewer can dispute, not a permissive arm nobody can
    # see. Corrected citation; see the note above the tier-2 list.
    split("cat cp mv rm mkdir rmdir touch chmod chown ln tr sleep date wc " \
          "head tail sort uniq cut paste comm join tee grep fgrep egrep " \
          "basename dirname mktemp stat readlink realpath id hostname " \
          "seq expr cmp diff od hexdump md5sum sha256sum sync", a, " ")
    for (i in a) MOCK_OK[a[i]] = 1
}
function _mock_word_ok(w) {
    if (w == "")                                   return 1
    if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/)            return 1   # assignment prefix
    if (w ~ /^[0-9]*[<>]/)                         return 1   # redirection
    if (w ~ /^[!({}\[\]]+$/)                       return 1   # grouping / negation
    if (w ~ /^[0-9]+$/)                            return 1   # fd number
    if (w in MOCK_OK)                              return 1
    if (w in MOCK_FN)                              return 1   # defined IN this body
    return 0
}
# THE FIRST offending word, kept as a SCALAR rather than an array on purpose:
# awk's `for (k in arr)` order is unspecified, so joining an array would make
# the detail string — which a human reads to decide what to do — differ between
# runs on the same input. A failing lint must name its offender (CLAUDE.md), and
# a name that moves is worse than none.
function _mock_hit(w) {
    if (_mock_word_ok(w)) return
    MOCK_BAD = 1
    if (MOCK_BADW == "") MOCK_BADW = w
}
function is_mock_body(body,   L, i, c, c2, d, t, brace, hdelim, inq, inbrk, qsp, qstack, qdepth, qarith, arr, k, expect, word, sawword, prevword, arith, nl, lines, j, m, n) {
    # MOCK_BADW is an OUT parameter: classify() reads it to name the offender.
    _mock_init()
    delete MOCK_FN; MOCK_BADW = ""; MOCK_BAD = 0
    # AN UNREADABLE BODY IS NOT A MOCK. An empty extracted body means this
    # scanner could not see the shim's text at all, and "I found no command" is
    # exactly the absence-as-evidence answer the inversion exists to refuse.
    if (body ~ /^[ \t\n]*$/) return 0
    # A registered variable in the body is POSITIVE evidence of a hand-off and
    # outranks any tokenisation: `printf '…exec %s…' "$REAL" > "$D/tmux"` must
    # not read as a mock because `printf` is a builtin.
    for (n in target_var) if (index(body, "$" n) || index(body, "${" n "}")) return 0
    for (n in safe_bin)   if (index(body, "$" n) || index(body, "${" n "}")) return 0
    for (n in unsafe_bin) if (index(body, "$" n) || index(body, "${" n "}")) return 0
    # An UNQUOTED heredoc delimiter leaves `\$` in the SOURCE that becomes a bare
    # `$` in the WRITTEN shim, so the scan must read the text the shim will RUN.
    # Applied unconditionally: on a quoted-delimiter body it can only read a
    # literal `\$` as an expansion, which is the conservative direction.
    gsub(/\\\$/, "$", body)
    gsub(/\\`/, "`", body)
    # A NESTED HEREDOC IS DATA, NOT CODE. `cat <<'ROWS' … ROWS` inside a shim
    # body is the idiomatic way a mock emits fixed output, and reading its text
    # as commands flags a genuine mock — the "cries wolf on its own fixtures"
    # failure that gets a lint disabled (measured: test-paste-dead-pane-guard.sh
    # :804, whose payload lines `$1` and the delimiter `ROWS` were both read as
    # command words). The OPENER stays and is checked; only the payload goes.
    nl = split(body, lines, "\n"); body = ""
    for (j = 1; j <= nl; j++) {
        m = lines[j]
        body = body "\n" m
        if (!match(m, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) continue
        hdelim = substr(m, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", hdelim); gsub(/["\047]/, "", hdelim)
        # ONLY SKIP WHEN THE DELIMITER IS ACTUALLY THERE. `<<` also occurs
        # inside strings (`echo "a << b"`) and this match is not quote-aware, so
        # a naive skip-until-delimiter drops EVERY REMAINING LINE when the
        # delimiter never arrives — turning a routing shim into a proven mock on
        # the strength of text it never executed. That is the absence-as-evidence
        # direction, so the lookahead is required rather than tidy: no closing
        # delimiter, no skip, and the opener line is read as ordinary code.
        for (k = j + 1; k <= nl; k++) {
            t = lines[k]; gsub(/^[ \t]+|[ \t]+$/, "", t)
            if (t == hdelim) break
        }
        if (k <= nl) j = k                                # payload skipped
    }
    # Pass 0 — shell functions DEFINED in this body are not external programs.
    nl = split(body, lines, "\n")
    for (j = 1; j <= nl; j++) {
        m = lines[j]
        if (match(m, /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_-]*[ \t]*\(\)/)) {
            sub(/^[ \t]*(function[ \t]+)?/, "", m); sub(/[ \t]*\(\).*$/, "", m)
            MOCK_FN[m] = 1
        }
    }
    L = length(body); inq = ""; inbrk = ""; qsp = 0; expect = "cmd"
    word = ""; sawword = 0; prevword = ""; arith = 0
    for (i = 1; i <= L; i++) {
        c = substr(body, i, 1); c2 = substr(body, i + 1, 1)
        if (inq != "") {                                  # inside a quoted span
            # A QUOTED SPAN IN COMMAND POSITION IS STILL A COMMAND, and skipping
            # it wholesale was a hole in exactly the shape `#1119` is about:
            # `"$TMUX" "$@"` has no UNQUOTED word at all, so a scanner that
            # discards quoted text finds no commands and answers PROVEN MOCK.
            # The two escapes `#1119` measured are caught by the registered-
            # variable test above only because their variable is registered; an
            # unregistered `"$TMUX"` reached SAFE-STUB. Quoted characters are
            # therefore APPENDED to the current word — harmless for arguments,
            # since a word is only tested at command position — so `"echo" hi`
            # still reads as `echo` while `"$TMUX"` reads as `$TMUX` and is
            # denied. Caught by the adversarial probe, not by review.
            if (c == "\\" && inq == "\"") { i++; word = word substr(body, i, 1); continue }
            # `$(` REOPENS CODE INSIDE A DOUBLE-QUOTED SPAN, and the shell means
            # it: `printf "%s" "$(tmux -V)"` INVOKES tmux. Same fact
            # `_shell_quotes.awk` had to learn for `#1130`, and the same hole
            # here — it read as a proven mock.
            # `$((` FIRST — arithmetic is not a command substitution, and
            # testing `$(` before it read `n + 1` as three commands.
            if (inq == "\"" && c == "$" && substr(body, i + 1, 2) == "((") {
                qsp++; qstack[qsp] = inq; qdepth[qsp] = 2; qarith[qsp] = 1; inq = ""
                word = ""; i += 2
                continue
            }
            if (inq == "\"" && c == "$" && substr(body, i + 1, 1) == "(") {
                qsp++; qstack[qsp] = inq; qdepth[qsp] = 1; qarith[qsp] = 0; inq = ""
                if (!sawword) _mock_hit(word)
                word = ""; sawword = 0; i++
                continue
            }
            if (c == inq) inq = ""
            else word = word c
            continue
        }
        if (qsp > 0) {                                    # inside "$( … )"
            if (c == "(") qdepth[qsp]++
            else if (c == ")") {
                qdepth[qsp]--
                if (qdepth[qsp] == 0) {
                    if (!qarith[qsp] && !sawword) _mock_hit(word)
                    inq = qstack[qsp]; qsp--; word = ""; sawword = 1
                    continue
                }
            }
            if (qarith[qsp]) continue                     # arithmetic: no commands
        }
        if (arith > 0) {                                  # inside (( … )) / $(( … ))
            if (c == "(") arith++; else if (c == ")") arith--
            continue
        }
        if (inbrk != "") {                                # inside [[ … ]] or [ … ]
            if (c == "'" || c == "\"") { inq = c; continue }
            if (inbrk == "]]" && c == "]" && c2 == "]") { inbrk = ""; i++; continue }
            if (inbrk == "]"  && c == "]") { inbrk = ""; continue }
            continue
        }
        if (c == "'" || c == "\"") { inq = c; continue }
        if (c == "\\") { i++; continue }
        if (c == "$" && c2 == "{") {                      # ${…} — opaque expansion
            i += 2; brace = 1
            while (i <= L && brace > 0) { d = substr(body, i, 1)
                if (d == "{") brace++; else if (d == "}") brace--; i++ }
            i--; word = word "$"; continue
        }
        if (c == "$" && c2 == "(" && substr(body, i + 2, 1) == "(") { arith = 2; i += 2; continue }
        if (c == "(" && c2 == "(" && word == "" &&
            (!sawword || prevword == "while" || prevword == "until" ||
             prevword == "if" || prevword == "for")) { arith = 2; i++; continue }
        if (c == "$" && c2 == "(") {                      # $( … ) — a NEW command position
            if (!sawword) _mock_hit(word)
            word = ""; sawword = 0; i++; continue
        }
        if (c == "`") { if (!sawword) _mock_hit(word); word = ""; sawword = 0; continue }
        if (c == "#" && word == "" && !sawword) {         # comment to end of line
            while (i <= L && substr(body, i, 1) != "\n") i++
            word = ""; sawword = 0; continue
        }
        if (c == "&" && (substr(body, i - 1, 1) == ">" || substr(body, i - 1, 1) == "<")) continue
        if (c == ";" || c == "\n" || c == "&" || c == "|") {
            if (c == "|" && expect == "pat") { word = ""; continue }   # case alternation
            if (!sawword) _mock_hit(word)
            if (c == ";" && c2 == ";") { expect = "pat"; i++ }
            word = ""; sawword = 0; continue
        }
        if (c == ")") {
            if (expect == "pat") expect = "cmd"
            else if (!sawword) _mock_hit(word)
            word = ""; sawword = 0; continue
        }
        if (c == "(" && word ~ /=$/) {
            # AN ARRAY LITERAL IS DATA, NOT A COMMAND LIST. `names=("watcher")`
            # has no command position inside it, and reading one there flagged
            # three genuine mocks the moment quoted words started counting.
            arr = 1
            while (i <= L && arr > 0) {
                i++; d = substr(body, i, 1)
                if (d == "(") arr++; else if (d == ")") arr--
            }
            word = ""; sawword = 0; continue
        }
        if (c == "(" || c == "{" || c == "}") {
            if (word != "" && c == "(") { word = ""; sawword = 0; continue }   # fn definition
            if (!sawword) _mock_hit(word)
            word = ""; sawword = 0; continue
        }
        if (c == " " || c == "\t") {
            if (!sawword && word != "") {
                if (word ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || word ~ /^[0-9]*[<>]/) { word = ""; continue }
                _mock_hit(word)
                prevword = word
                if (word == "[[")                      { inbrk = "]]"; word = ""; sawword = 1; continue }
                if (word == "[" || word == "test")     { inbrk = "]";  word = ""; sawword = 1; continue }
                if (word == "case") expect = "pat"
                if (word == "esac") expect = "cmd"
                if (word == "then" || word == "do" || word == "else" || word == "elif" ||
                    word == "if"   || word == "while" || word == "until" ||
                    word == "!" || word == "time" || word == "command") { word = ""; continue }
                sawword = 1
            }
            word = ""
            continue
        }
        word = word c
    }
    if (!sawword) _mock_hit(word)
    return MOCK_BAD ? 0 : 1
}
# ── ENUMERATION IS POSITIONAL, NOT A SHAPE DENYLIST (your-org/nexus-code#1184).
#
# `#1119` inverted the BODY question — "is this a mock?" became positive proof
# with a default-deny arm — and left the SITE question exactly as it found it: a
# FOUR-ARM SHAPE DENYLIST WITH A PERMISSIVE DEFAULT. `nx_write_tmux_shim`,
# `cat > … <<`, line-leading `printf|echo` with `>`, line-leading `cp|install|ln`
# — and a line matching none of them was NOT A SITE, silently. An allowlist
# satisfied at the body level and violated one level above it: a body the
# scanner never reaches cannot be denied by any arm, however sound.
#
# Five semantics-preserving respellings were MEASURED invisible at `703483b5`,
# against a live positive control (`printf … > "$D/tmux"` scores UNSAFE):
#
#     printf … \ <newline> > "$D/tmux"    redirect on a CONTINUATION line
#     tee "$D/tmux" <<EOF                 a write utility that is not `cat`
#     > "$D/tmux" printf …                LEADING redirection
#     cp … "$D/tmux"  # trailing comment  the `$`-anchored target, un-anchored
#     cat <<EOF > "$D/tmux"               redirect AFTER the heredoc opener
#
# The last is the sharpest: same utility, same two operators, order swapped —
# one is caught and the other does not exist as far as the scanner is concerned.
#
# SO THE QUESTION IS INVERTED HERE TOO. A site is any line that WRITES a path
# ending `/tmux` (literally, or via a variable assigned such a path in this
# file), by ANY route, resolved POSITIONALLY rather than by line-leading command
# name: a redirection operand anywhere on the line, a heredoc attached to such a
# write, or a write utility carrying such a path as an argument. The tokeniser
# is quote-aware, folds backslash continuations, and does not care what the
# command is called.
#
# THE RESIDUAL IS SMALLER, NOT GONE, and it is the honest half. Enumeration is
# still SYNTACTIC: a target assembled at runtime (`t=$D/$n; printf … > "$t"`
# where `$n` is not literal), a write through a variable holding the operator
# (`$REDIR`), or a path this file never spells cannot be resolved by any static
# read. Those are NOT SEEN, and their absence still looks exactly like a pass.
# The load-bearing defence remains `nx_write_tmux_shim`'s RUNTIME magic-byte
# refusal; this lint exists to push planting sites onto it.

# Tokenise ONE logical line, quote-aware. The words carry two texts: TK_W is the
# raw word (what a target test reads) and TK_QT is its QUOTED-ONLY text (what a
# redirect would actually put in the file). Unquoted text is deliberately not
# collected into TK_QT — it is a variable or a glob this scanner cannot resolve,
# and dropping it leaves a body that is DENIED rather than defaulted.
function tk_word(   r) {
    if (!TK_HAS) return            # nothing accumulated: keep TK_PEND for the real word
    TK_N++
    TK_W[TK_N] = TK_RAW; TK_QT[TK_N] = TK_Q; TK_C[TK_N] = TK_SC
    if (TK_PEND != "") r = TK_PEND
    else if (!TK_CMDPOS) r = "arg"
    else if (TK_RAW ~ /^[A-Za-z_][A-Za-z0-9_]*=/) r = "assign"        # prefix: still cmd position
    else if (TK_RAW == "command" || TK_RAW == "builtin" || TK_RAW == "exec" ||
             TK_RAW == "env" || TK_RAW == "time" || TK_RAW == "nice") r = "cmdmod"
    else { r = "cmd"; TK_CMDPOS = 0 }
    TK_ROLE[TK_N] = r
    TK_PEND = ""; TK_RAW = ""; TK_Q = ""; TK_HAS = 0
}
function tokenize(l,   L, i, c, c2, c3) {
    TK_N = 0; TK_HDELIM = ""; TK_RAW = ""; TK_Q = ""; TK_HAS = 0
    TK_PEND = ""; TK_CMDPOS = 1; TK_SC = 1
    delete TK_W; delete TK_QT; delete TK_ROLE; delete TK_C
    L = length(l)
    for (i = 1; i <= L; i++) {
        c = substr(l, i, 1)
        if (c == "\047") {                                   # '…' — verbatim
            TK_HAS = 1
            for (i++; i <= L; i++) {
                c = substr(l, i, 1); if (c == "\047") break
                TK_RAW = TK_RAW c; TK_Q = TK_Q c
            }
            continue
        }
        if (c == "\"") {                                     # "…"
            TK_HAS = 1
            for (i++; i <= L; i++) {
                c = substr(l, i, 1)
                if (c == "\\") { i++; TK_RAW = TK_RAW substr(l, i, 1)
                                 TK_Q = TK_Q "\\" substr(l, i, 1); continue }
                if (c == "\"") break
                TK_RAW = TK_RAW c; TK_Q = TK_Q c
            }
            continue
        }
        if (c == "\\") { i++; TK_RAW = TK_RAW substr(l, i, 1); TK_HAS = 1; continue }
        if (c == " " || c == "\t") { tk_word(); continue }
        c2 = substr(l, i + 1, 1); c3 = substr(l, i + 2, 1)
        # `<<<` is a here-STRING, not a heredoc: testing `<<` first read its
        # operand as a delimiter and then swallowed the rest of the file.
        if (c == "<" && c2 == "<" && c3 == "<") { tk_word(); i += 2; continue }
        if (c == "<" && c2 == "<") {
            tk_word(); i++
            if (substr(l, i + 1, 1) == "-") i++
            TK_PEND = "hdelim"; continue
        }
        if (c == "<") { tk_word(); TK_PEND = "redirin"; continue }
        if (c == ">") {
            # `2>` / `&>`: the fd (or `&`) belongs to the OPERATOR, not to a word.
            if (TK_RAW ~ /^[0-9]+$/ || TK_RAW == "&") { TK_RAW = ""; TK_Q = ""; TK_HAS = 0 }
            tk_word()
            if (c2 == ">") { i++; TK_PEND = "redir"; continue }
            if (c2 == "&") { i++; TK_PEND = "redirdup"; continue }   # `>&2` is a dup, not a file
            TK_PEND = "redir"; continue
        }
        if (c == ";" || c == "|" || c == "&" || c == "(" || c == ")" || c == "\n") {
            tk_word(); TK_CMDPOS = 1; TK_SC++; TK_PEND = ""
            if (c2 == c && (c == ";" || c == "|" || c == "&")) i++
            continue
        }
        TK_RAW = TK_RAW c; TK_HAS = 1                        # unquoted: raw only
    }
    tk_word()
    for (i = 1; i <= TK_N; i++) if (TK_ROLE[i] == "hdelim" && TK_HDELIM == "") {
        TK_HDELIM = TK_W[i]; gsub(/["\047]/, "", TK_HDELIM)
    }
}
# Net UNQUOTED brace depth of one line, `}` positive. `${…}` is an EXPANSION,
# not a group, and is consumed whole — counting its braces walks the search past
# the real opener and yields a body assembled from unrelated lines.
function brace_net(s,   L, i, c, inq, n, d) {
    L = length(s); inq = ""; n = 0
    for (i = 1; i <= L; i++) {
        c = substr(s, i, 1)
        if (inq != "") {
            if (c == "\\" && inq == "\"") { i++; continue }
            if (c == inq) inq = ""
            continue
        }
        if (c == "\047" || c == "\"") { inq = c; continue }
        if (c == "\\") { i++; continue }
        if (c == "$" && substr(s, i + 1, 1) == "{") {
            i += 2; d = 1
            while (i <= L && d > 0) { c = substr(s, i, 1)
                if (c == "{") d++; else if (c == "}") d--; i++ }
            i--; continue
        }
        if (c == "{") n--; else if (c == "}") n++
    }
    return n
}
# The delimiter of the heredoc attached to ONE simple command, "" if none.
# TK_HDELIM is the LINE's first delimiter and was read as every command's, which
# on a two-plant line hands one command's heredoc body to another command's site.
function sc_hdelim(sc,   i, d) {
    for (i = 1; i <= TK_N; i++)
        if (TK_C[i] == sc && TK_ROLE[i] == "hdelim") {
            d = TK_W[i]; gsub(/["\047]/, "", d); return d
        }
    return ""
}
# EVERY WRITE ROUTE ON THE LINE, ONE RECORD PER SIMPLE COMMAND PER ROUTE
# (your-org/nexus-code#1313). This function used to RETURN on the line's first
# match, which is #1121's defect one level further out again — in ENUMERATION,
# where #1184 had just fixed it in CLASSIFICATION:
#
#     cp "$W/tmuxwrap/tmux" "$D/tmux"; printf 'exit 0\n' > "$D/tmux"
#
# The `>` belonging to the SECOND simple command was found first, the route
# returned `redirect`, that body really is a proven mock, and the `cp` of a
# literal wrapper in the FIRST simple command was never examined. The verdict was
# individually sound and about the wrong statement.
#
# MEASURED BROADER THAN #1313 STATES, and the broader form is the reason to fix
# the enumeration rather than the ordering. Both loops returned early, so:
#   * reversing the two commands does NOT report both — the redirect is still
#     found first and the `cp` is still never reached;
#   * two `cp`s on one line reported ONE record;
#   * `cp "$S/tmux" "$E/tmux"; cp "$W/tmuxwrap/tmux" "$D/tmux"` scored UNSAFE for
#     the FIRST cp, on a body that was the WHOLE LINE — i.e. red for the right
#     reason by accident, naming the wrong statement (#1210).
# So ordering the routes differently would only move which plant is invisible.
# The fix is to stop choosing.
#
# BOTH ROUTES FIRE FOR ONE SIMPLE COMMAND that matches both, deliberately. Route
# A (a redirect operand) can reach a SAFE verdict; route B (`cp` and friends) is
# default-DENY by construction. Letting A return first would be, exactly, a SAFE
# arm shadowing a DENY arm that fires on the same input — the rule this file has
# now broken three times (#1115 r3 H1a, #1121, #1313). A duplicate record is
# harmless: Pass 2 already emits a second record per line for SAFE-WRITER, so the
# caller tolerates more than one, and a redundant UNSAFE is not a false green.
function site_routes(   i, k, cmd, hd) {
    SITE_N = 0
    delete SITE_KIND; delete SITE_SC; delete SITE_CMD; delete SITE_HD
    for (k = 1; k <= TK_SC; k++) {
        hd = sc_hdelim(k)
        cmd = ""
        for (i = 1; i <= TK_N; i++) if (TK_C[i] == k && TK_ROLE[i] == "cmd") { cmd = TK_W[i]; break }
        # Route A — a REDIRECT operand naming a tmux target.
        for (i = 1; i <= TK_N; i++) {
            if (TK_C[i] != k || TK_ROLE[i] != "redir") continue
            if (!is_tmux_target(TK_W[i])) continue
            SITE_N++
            SITE_SC[SITE_N] = k; SITE_CMD[SITE_N] = cmd; SITE_HD[SITE_N] = hd
            SITE_KIND[SITE_N] = (hd != "" ? "heredoc" : "redirect")
            break                      # one redirect route per simple command
        }
        # Route B — a WRITE UTILITY carrying the target as an ARGUMENT.
        # Allowlisted by name because the claim behind each is checkable — every
        # one of these writes the file it is handed. `cat` is absent on purpose:
        # it writes only through a redirection, which route A already resolves.
        if (cmd !~ /^(cp|install|ln|mv|tee|dd|rsync)$/) continue
        for (i = 1; i <= TK_N; i++) {
            if (TK_C[i] != k || TK_ROLE[i] != "arg") continue
            if (!is_tmux_target(TK_W[i])) continue
            # `tee` is fed by the line's own text (a pipe or a here-doc); the
            # others copy a SOURCE FILE this scanner cannot resolve.
            SITE_N++
            SITE_SC[SITE_N] = k; SITE_CMD[SITE_N] = cmd; SITE_HD[SITE_N] = hd
            SITE_KIND[SITE_N] = (hd != "" ? "heredoc" : (cmd == "tee" ? "redirect" : "copy"))
            break
        }
    }
}
# The text of ONE simple command, for the arms that read a whole statement rather
# than a body (`copy`). Passing the LINE made every verdict on a multi-command
# line a claim about the line: a `tmuxwrap` in a NEIGHBOUR command convicted this
# one, and a clean neighbour could not acquit it only because the copy arm is
# default-deny anyway. A record must be about the statement it names.
function sc_text(sc,   i, out) {
    out = ""
    for (i = 1; i <= TK_N; i++) {
        if (TK_C[i] != sc) continue
        out = out " " TK_W[i]
    }
    return out
}
# The text a redirect/tee will PUT IN THE FILE — every word's QUOTED text except
# the ones naming a destination or a delimiter. Excluding the redirect operand is
# what stops SAFE-LITERAL pronouncing a shim safe on the strength of WHERE IT IS
# BEING PUT (H1c), and it now holds for a leading redirection too.
function redirect_body(sc,   i, out) {
    # SCOPED TO ONE SIMPLE COMMAND. Collecting the whole LINE reaches across `;`
    # into a neighbour: `_b3=$(mktemp -d); printf ... > "$_b3/tmux"; chmod +x
    # "$_b3/tmux"` pulled `$_b3` in from the trailing `chmod`, and a registered
    # target variable anywhere in a body is (correctly) positive evidence of a
    # hand-off — so a genuine `exit 1` mock read as a routing shim. A false
    # positive on a fixture is how a lint gets disabled (#1119).
    out = ""
    for (i = 1; i <= TK_N; i++) {
        if (sc && TK_C[i] != sc) continue
        if (TK_ROLE[i] == "redir" || TK_ROLE[i] == "redirin" ||
            TK_ROLE[i] == "redirdup" || TK_ROLE[i] == "hdelim") continue
        out = out " " TK_QT[i]
    }
    gsub(/\\n/, "\n", out); gsub(/\\t/, "\t", out)
    return out
}
function classify(ln, body, kind,   n) {
    # ---- ARM ORDER IS LOAD-BEARING (your-org/nexus-code#1115 skeptic r3, H1a).
    # The two gate-3 SIGNATURE arms run FIRST, before any SAFE arm. They used to
    # sit below SAFE-STUB, and that ordering PROVED SAFE the single most direct
    # expression of the hazard there is: a body containing the literal string
    # `tmuxwrap`, in a shim with no `exec` and no absolute-path line start, was
    # reported `SAFE-STUB` and measured reaching /tmp/tmux-<uid>/default. A
    # dedicated UNSAFE arm existed for exactly that text and was never reached.
    #
    # An allowlist whose deny arms are shadowed by its allow arms is not an
    # allowlist. Signatures first, always: they are POSITIVE evidence of the
    # hazard, and positive evidence must outrank every "I could not find a
    # problem" test. Corpus cost measured at zero new UNSAFE across the 77
    # non-exempt files; `strip_comment` runs before this, so the #1021 mock's
    # comment cannot reintroduce the old false positive.
    if (body ~ /tmuxwrap/ || body ~ /NEXUS-PATH-FRONT-WRAPPER-MARKER/) {
        printf "%d|UNSAFE|%s: body names the wrapper LITERALLY\n", ln, kind; return }
    if (body ~ /(command -v|type -[pP]|which|whence -p)[ \t]+tmux/) {
        printf "%d|UNSAFE|%s: body resolves tmux through PATH at write time\n", ln, kind; return }
    for (n in unsafe_bin) if (index(body, "$" n) || index(body, "${" n "}")) {
        printf "%d|UNSAFE|%s: body uses $%s, assigned from a PATH lookup of tmux\n", ln, kind, n; return }

    # ---- now the SAFE arms.
    # A `cp`/`ln` has NO BODY — its safety is a property of the SOURCE, so the
    # routing-body question is the wrong one to ask of it.
    if (kind != "copy" && is_mock_body(body)) {
        printf "%d|SAFE-STUB|%s: PROVEN mock — every command is a builtin or body-local\n", ln, kind; return }
    for (n in safe_bin) if (index(body, "$" n) || index(body, "${" n "}")) {
        printf "%d|SAFE-REALBIN|%s: body uses $%s, from nx_real_tmux_bin\n", ln, kind, n; return }
    # SAFE-LITERAL must NOT match a copy's DESTINATION (H1c). The destination is
    # the file being WRITTEN — `cp <src> "$W/bin/tmux"` — and matching it
    # pronounced a copy of the wrapper safe on the strength of where it was
    # being put. Only a body that is not a copy can earn this verdict.
    if (kind != "copy" && body ~ /\/[A-Za-z0-9_.\/-]*\/tmux/) {
        printf "%d|SAFE-LITERAL|%s: body execs an absolute literal tmux path\n", ln, kind; return }

    # ---- DEFAULT: DENY. Including copies (H1c): `SAFE-COPY` was a default-ALLOW
    # arm sitting inside an allowlist, and its own detail string admitted "source
    # file itself NOT resolved" while returning SAFE anyway. An unresolved source
    # is precisely what this arm exists for.
    if (kind == "copy") {
        printf "%d|UNSAFE|copy: source not resolved — cannot PROVE it is not a wrapper (default-deny)\n", ln
        return
    }
    # NAME THE OFFENDER. "could not PROVE it" tells a reviewer nothing to act
    # on, and three of this corpus' four default-deny sites are exempted for a
    # reason (`awk`) that this line is the natural place to state. `MOCK_BADW`
    # is empty only when the body was rejected before tokenisation — an
    # unreadable body or a registered routing variable — and the message says so
    # rather than naming nothing.
    if (MOCK_BADW != "")
        printf "%d|UNSAFE|%s: not a proven mock — `%s` in command position is not a builtin, a body-local function, or a named non-executing external (default-deny)\n", ln, kind, MOCK_BADW
    else
        printf "%d|UNSAFE|%s: could not PROVE the body reaches a real tmux BINARY (default-deny)\n", ln, kind
}

END {
    # Pass 0 — FOLD BACKSLASH CONTINUATIONS into logical lines. A redirect on a
    # continuation line was one of `#1184`'s five measured invisibles, and it is
    # invisible to any per-physical-line rule by construction. The FIRST physical
    # line number stays the site key (that is where a reader looks); the LAST is
    # where a heredoc payload begins.
    nlog = 0
    for (i = 1; i <= NR; i++) {
        s = line[i]
        if (nlog == 0 || !cont) { nlog++; lstart[nlog] = i; ltext[nlog] = s }
        else ltext[nlog] = ltext[nlog] " " s
        lend[nlog] = i
        # A trailing ODD number of backslashes continues the line.
        cont = 0; t = ltext[nlog]
        if (s ~ /\\$/) { n = 0
            for (j = length(s); j >= 1 && substr(s, j, 1) == "\\"; j--) n++
            if (n % 2 == 1) { cont = 1; sub(/\\$/, "", ltext[nlog]) }
        }
    }
    # Pass 1 — variable provenance, one level, within this file.
    for (k = 1; k <= nlog; k++) {
        l = ltext[k]
        if (match(l, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=/)) {
            name = substr(l, RSTART, RLENGTH - 1); gsub(/^[ \t]+/, "", name)
            val  = substr(l, RSTART + RLENGTH)
            if (val ~ /\/tmux\"?[ \t]*$/)                                  target_var[name] = 1
            if (val ~ /nx_real_tmux_bin/)                                  safe_bin[name]   = 1
            # A lookup done against an EXPLICIT CLEAN PATH resolves the real
            # binary by construction — the wrapper is not on that PATH. This is
            # a deliberate, correct idiom in this tree
            # (test-slow-grind-respawn.sh:76) and flagging it would be a false
            # positive on the one file that got it right the hard way.
            if (val ~ /PATH=[^ \t]*[ \t]+(command -v|type -[pP]|which)[ \t]+tmux/) safe_bin[name] = 1
            else if (val ~ /(command -v|type -[pP]|which|whence -p)[ \t]+tmux/)      unsafe_bin[name] = 1
            if (val ~ /tmuxwrap\/tmux/)                                    unsafe_bin[name] = 1
        }
    }
    # Pass 2 — creation sites, resolved POSITIONALLY (your-org/nexus-code#1184).
    for (k = 1; k <= nlog; k++) {
        raw = ltext[k]
        # A COMMENT IS NOT CODE, and it must be stripped BEFORE the site question
        # is asked, not after it. Stripping it afterwards is what made
        # `cp … "$D/tmux"  # trailing comment` invisible: the old copy arm
        # anchored the target at END OF LINE, so a comment displaced it.
        l = strip_comment(raw)
        if (l ~ /^[ \t]*$/) continue
        tokenize(l)

        # ---- ARM ORDER IS LOAD-BEARING HERE TOO (your-org/nexus-code#1121,
        # #1184). This arm used to be a bare `l ~ /nx_write_tmux_shim/` SUBSTRING
        # search that `continue`d the line — a permissive SAFE arm returning
        # before every DENY arm, which is #1121's defect one pass up, in
        # ENUMERATION rather than in classification. Two consequences, both
        # MEASURED at `703483b5`:
        #
        #   * a single-variable A/B — identical `cp "$WRAP/tmuxwrap/tmux"
        #     "$D/tmux"`, adding ONLY the comment `# nx_write_tmux_shim` — flips
        #     `UNSAFE|copy: body names the wrapper LITERALLY` to `SAFE-WRITER`.
        #     The single most direct expression of the hazard, pronounced safe by
        #     a comment. That is exactly the shape #1121 fixed in classify().
        #   * THREE OF THE SEVEN SAFE-WRITER RECORDS IN THE LIVE CORPUS WERE
        #     COMMENT LINES (`_harness.sh:172`, `test-pane-state.sh:1905`,
        #     `test-paste-dead-pane-guard.sh:253`), each merely PROSE about the
        #     writer sitting above the real call. Harmless as duplicates, and
        #     the standing proof that the arm keyed on a substring of prose.
        #
        # So: the comment is stripped first, the call must be a real COMMAND
        # (line-leading or after a separator), and the arm NO LONGER SHORT-
        # CIRCUITS — a line that both calls the writer AND plants a shim some
        # other way now reports BOTH records.
        if (l ~ /(^|[;&|(])[ \t]*nx_write_tmux_shim([ \t]|$)/)
            printf "%d|SAFE-WRITER|routed through nx_write_tmux_shim\n", lstart[k]

        # CONSUME EVERY HEREDOC PAYLOAD ON THE LINE, SITE OR NOT, IN DELIMITER
        # ORDER (your-org/nexus-code#1313 F3). The first form of this walk
        # advanced its cursor only when a SITE consumed a payload, so a heredoc
        # attached to a NON-site command on the same line was never consumed and
        # a later site began reading at the wrong offset — somebody else's
        # payload. **It failed toward a FALSE SAFE**, which is the one direction
        # the downstream gate cannot catch, because that gate reads only
        # `|UNSAFE|`. Measured, before the fix:
        #
        #     cat <<'A' > "$D/notmux"; cat <<'B' > "$D/tmux"
        #     exit 0
        #     B
        #     A
        #     exec "$W/tmuxwrap/tmux" "$@"
        #     B
        #
        #   -> SAFE-STUB|heredoc: PROVEN mock
        #
        # while the bytes the shell actually writes to `$D/tmux` are
        # `exec "$W/tmuxwrap/tmux" "$@"` — verified by RUNNING it and reading
        # the file back, not by reading the scanner. The site took the FIRST
        # heredoc's benign payload, truncated at its own delimiter appearing
        # inside it, and never saw its own.
        #
        # Payload extents are therefore a property of the LINE, resolved once,
        # before any site is classified. A site then takes the payload of the
        # delimiter belonging to its own simple command.
        nhd = 0
        delete hd_sc; delete hd_d; delete hd_body
        for (i = 1; i <= TK_N; i++)
            if (TK_ROLE[i] == "hdelim") {
                nhd++; hd_sc[nhd] = TK_C[i]
                hdd = TK_W[i]; gsub(/["\047]/, "", hdd); hd_d[nhd] = hdd
            }
        hcur = lend[k] + 1
        for (h = 1; h <= nhd; h++) {
            hd_body[h] = ""
            j = hcur
            while (j <= NR) {
                b = line[j]; t = b; gsub(/^[ \t]+|[ \t]+$/, "", t)
                j++
                if (t == hd_d[h]) break
                hd_body[h] = hd_body[h] "\n" strip_comment(b)
            }
            hcur = j
        }

        # EVERY site on the line, in simple-command order (#1313).
        site_routes()
        for (s2 = 1; s2 <= SITE_N; s2++) {
        kind2 = SITE_KIND[s2]; sc2 = SITE_SC[s2]; cmd2 = SITE_CMD[s2]

        if (kind2 == "heredoc") {
            # The payload of THIS simple command's delimiter. A site whose
            # delimiter cannot be located gets an EMPTY body, which reaches the
            # default-deny arm rather than being dropped.
            body = ""
            for (h = 1; h <= nhd; h++)
                if (hd_sc[h] == sc2) { body = hd_body[h]; break }
            classify(lstart[k], body, "heredoc")
            continue
        }
        if (kind2 == "redirect") {
            # A COMPOUND GROUP REDIRECTED AS A WHOLE — `{ printf …; printf …; }
            # > "$D/tmux"` — is the most idiomatic planting shape in this tree
            # and was invisible to every one of the old four arms: it is not a
            # `cat <<`, its `printf`s are not line-leading with a `>`, and it is
            # not a `cp`. THREE live sites use it (test-cc-harness-socket-
            # isolation.sh, test-pane-state.sh twice). Positional discovery finds
            # the write; the body is then the QUOTED text the group emits, which
            # is what the file will actually contain.
            if (cmd2 == "}") {
                depth = 0; opener = 0
                for (j = k; j >= 1; j--) {
                    depth += brace_net(strip_comment(ltext[j]))
                    if (depth == 0) { opener = j; break }
                }
                body = ""
                if (opener) {
                    for (j = opener; j < k; j++) {
                        tokenize(strip_comment(ltext[j]))
                        body = body " " redirect_body(0)
                    }
                    # RE-TOKENISE: the group walk above clobbered the token
                    # arrays this loop's remaining sites read from.
                    tokenize(l)
                    classify(lstart[k], body, "group")
                    continue
                }
                # NO MATCHING OPENER: the body is UNREADABLE, so the site is
                # DENIED, never dropped. That is the whole point of inverting
                # discovery — an unreadable body reaches the default-deny arm
                # instead of being silently not-a-site.
                tokenize(l)
                classify(lstart[k], "", "group")
                continue
            }
            # THE WRITTEN BYTES MUST COME FROM TEXT ON THIS LINE, or the body is
            # not the body. `sed 's|…|…' "$STUB/tmux" > "$FAILING/tmux"` derives
            # its content from ANOTHER FILE this scan cannot resolve; reading the
            # sed PROGRAM as the shim named `s` as an offending command, which is
            # a confident, wrong offender name — and CLAUDE.md is explicit that a
            # failing lint is read by its offender list. Anything that is not a
            # text emitter is a copy from an unresolved source, and says so.
            if (cmd2 == "" || cmd2 ~ /^(printf|echo|cat|tee|:)$/) {
                classify(lstart[k], redirect_body(sc2), "redirect"); continue
            }
            classify(lstart[k], sc_text(sc2), "copy"); continue
        }
        classify(lstart[k], sc_text(sc2), "copy")
        }
    }
}
