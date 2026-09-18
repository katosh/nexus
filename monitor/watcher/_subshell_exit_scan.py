#!/usr/bin/env python3
# _subshell_exit_scan.py -- the REACHABILITY core of the subshell-exit-guard
# lint (your-org/nexus-code#1339).  Driven by subshell-exit-guards.sh; not
# meant to be run bare.
#
# THE DEFECT.  A fail-closed guard whose `die`/`exit` is reached ONLY from
# inside `$( )`, a backtick, a process substitution or a pipeline segment
# terminates the SUBSHELL.  The guard runs, decides correctly, prints its
# refusal -- and does not gate.  It is invisible to `bash -n` (valid syntax),
# to a unit test that calls the function directly (it exits correctly in
# isolation), and to review (it reads exactly like a guard).  It fails OPEN
# with a reassuring diagnostic.
#
# WHY THIS IS NOT A grep.  `grep 'die' | grep '\$('` over-counts wildly (most
# `die` calls are not in substitutions) and under-counts SILENTLY: the measured
# instance's `die` is TWO levels down --
#
#     name=$(_registry_name_for_workdir "$d")   # <- the substitution
#       _registry_name_for_workdir() { _registry_must_be_readable; ... }
#         _registry_must_be_readable() { ... || die "..."; }
#           die() { echo ... >&2; exit 1; }
#
# -- so the substituted word is not `die`, is not `exit`, and matches no text
# predicate aimed at either.  What follows is therefore a CALL GRAPH with a
# fixpoint over "can terminate the shell", and a separate, quote-aware,
# nesting-aware notion of "is this command word evaluated in a subshell".
#
# Python 3.6-safe on purpose (this host is 3.6.9): no `fromisoformat`, no
# dataclasses, no walrus.
import os
import re
import sys

# --------------------------------------------------------------------------
# 1. LEXICAL PREPARATION
# --------------------------------------------------------------------------
# Three things must be neutralised before any token means what it looks like:
# comments, heredoc BODIES, and single-quoted spans.
#
# SINGLE quotes only.  A `$( )` inside DOUBLE quotes is still a command
# substitution -- `x="$(f)"` is the single most common spelling of the defect --
# so blanking double-quoted text would blind the scanner to the majority of its
# own population.  Double-quoted spans are therefore left intact, which costs
# some false positives on PROSE that happens to name a terminator inside a
# double-quoted diagnostic.  That direction is declared, not hidden: it can
# only add a red for a human to disposition, never remove one.

_WORD = r'[A-Za-z_][A-Za-z0-9_.:-]*'


class ParseUnbalanced(Exception):
    pass


def _find_matching(text, i, open_tok, close_tok):
    """Index just past the matching close of a two-char bracket at i."""
    depth = 0
    j = i
    n = len(text)
    while j < n:
        if text[j:j + len(open_tok)] == open_tok:
            depth += 1
            j += len(open_tok)
            continue
        if text[j:j + len(close_tok)] == close_tok:
            depth -= 1
            j += len(close_tok)
            if depth == 0:
                return j
            continue
        j += 1
    return n


def prepare(text):
    """-> list of (lineno, prepared_text).

    ONE state machine, with a CONTEXT STACK, because a flat pair of in_sq /
    in_dq flags cannot represent shell quoting and gets STUCK. That is not a
    hypothetical: the first cut of this file used two flags plus a counter, and
    on `monitor/watcher/test-shell-files.sh` the double-quote flag latched ON
    at line 187 and never cleared, so every `#` after it stopped being a
    comment, `||` and `;` inside real code were blanked, and 481 `assert_eq`
    calls at depth 0 were reported as subshell sites. A leak in the QUOTE
    machine reads downstream as a finding, and it reads as a big one.

    The stack exists because QUOTING RESETS INSIDE A SUBSTITUTION:
    `"$(f "$x")"` has a double-quoted context, a fresh NORMAL context inside
    `$(`, and another double-quoted context inside that. A flag cannot nest.

    What comes out the other side needs NO further quote awareness:
      * single-quoted spans      -> spaces (inert; length preserved)
      * double-quoted spans      -> operators blanked, `$( )` PRESERVED,
                                    because `x="$(f)"` is the commonest
                                    spelling of this whole defect
      * backticks                -> NORMALIZED to `$(` / `)`, so the walker
                                    has one substitution shape, not two
      * `$(( ))` and `(( ))`     -> blanked entirely: arithmetic, no commands
      * `${ }`                   -> braces blanked, contents kept (a `$(` can
                                    live in a `:-` default)
      * comments, heredoc bodies -> removed
    """
    NORMAL, SQ, DQ = 0, 1, 2
    out = []
    # each entry: [kind, mode] ; kind 'file' | 'subst' | 'bq'
    # third slot: PAREN DEPTH inside this context. Without it, the `()` of a
    # function HEADER defined inside a substitution -- `"$(grep() { return 1;
    # }; f)"`, a real and common fixture shape in this repo -- pops the
    # substitution context, the real `)` is then blanked as prose, and the
    # walker's subshell frame LEAKS to the end of the file. Measured:
    # test-cpu-pressure-note.sh:79 leaked and 5 depth-0 `assert_eq` calls
    # below it were reported as subshell sites.
    ctx = [['file', NORMAL, 0]]
    pending_heredocs = []
    in_heredoc = None
    for i, raw in enumerate(text.split('\n'), start=1):
        if in_heredoc is not None:
            probe = raw.lstrip('\t') if in_heredoc[1] else raw
            if probe.strip() == in_heredoc[0]:
                in_heredoc = None
            out.append((i, ''))
            continue
        buf = []
        j = 0
        n = len(raw)
        while j < n:
            c = raw[j]
            mode = ctx[-1][1]
            two = raw[j:j + 2]

            if mode == SQ:
                if c == "'":
                    ctx[-1][1] = NORMAL
                buf.append(' ')
                j += 1
                continue

            # A COMMENT IS CHECKED BEFORE THE SUBSTITUTION OPENERS, and the
            # order is load-bearing: this repo's comments are dense with
            # BACKTICKED identifiers, and a backtick handled first opens a
            # substitution context that never closes. Measured with the
            # openers first: `# states out of `main()`; it used to be …` in
            # test-ci-trigger-audit.sh put a comment's prose into the walker as
            # code and reported an `assert_eq` inside it as a subshell site.
            if mode == NORMAL and c == '#':
                prev = raw[j - 1] if j else ''
                if prev == '' or prev.isspace() or prev in ';|&(){':
                    break

            # ---- substitution openers: live in NORMAL *and* in DQ --------
            if two == '$(' and raw[j:j + 3] != '$((':
                ctx.append(['subst', NORMAL, 0])
                buf.append('$(')
                j += 2
                continue
            if raw[j:j + 3] == '$((':
                k = _find_matching(raw, j + 1, '(', ')')
                buf.append(' ' * (k - j))
                j = k
                continue
            if c == '`':
                if ctx[-1][0] == 'bq':
                    ctx.pop()
                    buf.append(')')
                else:
                    ctx.append(['bq', NORMAL, 0])
                    buf.append('$(')
                j += 1
                continue

            if mode == DQ:
                if c == '"':
                    ctx[-1][1] = NORMAL
                    buf.append(' ')
                    j += 1
                    continue
                if c == '\\' and j + 1 < n:
                    buf.append('  ')
                    j += 2
                    continue
                # NO `)` ARM HERE, DELIBERATELY. Inside double quotes a `)`
                # is prose: the `)` that closes a `$(` is seen in the
                # SUBSTITUTION's own NORMAL context, never in a quoted one.
                # An arm here popped the substitution on
                # `sed -n "s/… CASE(S) SKIPPED…/\1/p"` -- parentheses in an
                # English word inside a sed script -- and the file stopped
                # parsing from line 196 onward.
                buf.append(' ' if c in '|;&{}()<>!' else c)
                j += 1
                continue

            # ---- NORMAL --------------------------------------------------
            if c == "'":
                ctx[-1][1] = SQ
                buf.append(' ')
                j += 1
                continue
            if c == '"':
                ctx[-1][1] = DQ
                buf.append(' ')
                j += 1
                continue
            if two == '((':
                k = _find_matching(raw, j, '(', ')')
                buf.append(' ' * (k - j))
                j = k
                continue
            if two == '${':
                k = _find_matching(raw, j + 1, '{', '}')
                inner = raw[j + 2:k - 1]
                buf.append('  ' + inner + ' ')
                j = k
                continue
            if c == '(':
                ctx[-1][2] += 1
                buf.append(c)
                j += 1
                continue
            if c == ')':
                if ctx[-1][2] > 0:
                    ctx[-1][2] -= 1
                elif ctx[-1][0] in ('subst', 'bq'):
                    ctx.pop()
                buf.append(')')
                j += 1
                continue
            if c == '\\' and j + 1 < n:
                buf.append(' ')
                buf.append(raw[j + 1] if raw[j + 1] in '\\' else ' ')
                j += 2
                continue
            if c == '#':
                prev = raw[j - 1] if j else ''
                if prev == '' or prev.isspace() or prev in ';|&(){':
                    break
                buf.append(c)
                j += 1
                continue
            # `<<<` IS A HERE-STRING, NOT A HEREDOC, and it must be consumed
            # EXPLICITLY rather than merely excluded from the heredoc arm.
            # Excluding it only moves the failure one character right: at the
            # SECOND `<` the text reads `<<"…"`, so
            # `grep -qxF "$t" <<<"$(tmux list-windows …)"` registered
            # `$(tmux list-windows -F '#{window_name}' 2>/dev/null)` as a
            # heredoc DELIMITER and blanked every line to EOF waiting for it.
            # The `)` that closed an enclosing subshell was among them.
            if raw[j:j + 3] == '<<<':
                buf.append('   ')
                j += 3
                continue
            if two == '<<':
                # A delimiter is a WORD. Anything else is not a heredoc, and
                # guessing that it is costs the remainder of the file.
                m = re.match(r'<<(-?)\s*(?:"([A-Za-z0-9_.-]+)"'
                             r'|\'([A-Za-z0-9_.-]+)\'|([A-Za-z0-9_.-]+))',
                             raw[j:])
                if m:
                    delim = m.group(2) or m.group(3) or m.group(4)
                    if delim:
                        pending_heredocs.append((delim, bool(m.group(1))))
                    buf.append(' ' * len(m.group(0)))
                    j += len(m.group(0))
                    continue
            buf.append(c)
            j += 1
        line = ''.join(buf)
        # A LINE CONTINUATION MUST SURVIVE, because the walker decides
        # statement boundaries on it.
        if raw.rstrip().endswith('\\') and not line.rstrip().endswith('\\'):
            line = line.rstrip() + ' \\'
        out.append((i, line))
        if pending_heredocs and not raw.rstrip().endswith('\\'):
            in_heredoc = pending_heredocs.pop(0)
            pending_heredocs = []
    # THE PARSE BALANCE IS A POST-CONDITION, NOT AN ASSUMPTION.
    #
    # Both bugs this machine has had were LEAKS -- a context or a frame that
    # opened and never closed -- and both produced a large, confident,
    # entirely wrong finding rather than an error: 481 depth-0 `assert_eq`
    # calls reported as subshell sites the first time, 5 the second. A lint
    # whose parser can fail silently is this repo's dominant defect class
    # wearing a lint's clothes, so an unbalanced parse is a REFUSAL. The
    # caller must treat GP_PARSE_UNBALANCED as fatal, never as zero sites.
    if len(ctx) != 1 or ctx[0][1] != NORMAL or ctx[0][2] != 0:
        raise ParseUnbalanced(
            'quote/substitution context did not return to the top level '
            '(depth %d, mode %d, paren %d)' % (len(ctx), ctx[0][1], ctx[0][2]))
    return out


# --------------------------------------------------------------------------
# 2. THE SUBSHELL MACHINE
# --------------------------------------------------------------------------
# One walk over the prepared text produces, for every COMMAND WORD, whether it
# is evaluated in a subshell.  Four bracket-shaped openers and one that is not
# bracket-shaped at all:
#
#     $( ... )    command substitution
#     ` ... `     the same thing, older spelling
#     <( ... )    process substitution -- a subshell, and the form #1266 was
#     >( ... )    about, so it must not be omitted
#     ( ... )     an explicit subshell, at a command position only (so
#                 `x=(a b)` and `f() (...)` do not both mean the same thing)
#     a | b       EVERY segment of a pipeline runs in a subshell in bash
#                 without `lastpipe`, INCLUDING the last one.  Not
#                 bracket-shaped, so it is tracked as a property of the
#                 statement and of any compound the statement opens.
#
# `{ ...; }` is deliberately NOT a subshell: it is a brace group in the
# current shell, and an `exit` inside one DOES exit the program.  Getting that
# arm wrong in either direction is what makes a lint "fires on both, or
# neither".

_CMDPOS_AFTER = set(';|&\n(){}')
_KEYWORDS_CMDPOS = ('then', 'else', 'elif', 'do', 'in', 'time')
_COMPOUND_OPEN = ('do', 'then')
_COMPOUND_CLOSE = ('done', 'fi', 'esac')


class Frame(object):
    __slots__ = ('kind', 'in_pipe', 'stmt_pipe', 'words', 'fname',
                 'in_cond', 'or_carry', 'after_or', 'sub')

    def __init__(self, kind, in_pipe=False, fname=None, sub=None):
        self.sub = sub            # 'cmdsub' | 'procsub' | 'group'
        self.fname = fname        # set on the brace group that IS a body
        self.in_cond = False      # inside an if/while/until CONDITION
        self.or_carry = []        # sites of the statement a `||` just ended
        self.after_or = False     # the next command word follows that `||`
        self.kind = kind          # 'file' | 'sub' | 'group' | 'compound'
        self.in_pipe = in_pipe    # this frame is INSIDE a pipeline segment
        self.stmt_pipe = False    # the statement being scanned has a `|`
        self.words = []           # words of the current statement (for
                                  # retroactive pipeline marking)


def _resolve_or(frame, fate):
    for cw in frame.or_carry:
        if cw['fate'] == 'discarded':
            cw['fate'] = fate
    frame.or_carry = []
    frame.after_or = False


def _initial_fate(stack):
    """The fate a site starts with, before a `||` can revise it.

    Ordered most-specific first, and the order is the classification:
      group    -- the site is in an EXPLICIT `( … )` subshell, so the exit IS
                  that group's exit status and the caller reads it. The
                  `( flock -w 10 9 || exit 9; … )` idiom lives here, and
                  calling it `discarded` would bury the real signal.
      pipe     -- a pipeline segment. bash without `lastpipe` runs EVERY
                  segment in a subshell, so an `exit` here is a segment's rc
                  and `pipefail` (or its absence) decides what happens next.
      cond     -- the substitution sits in an `if`/`while`/`until` CONDITION,
                  so its status is CONSUMED as a boolean.
      discarded-- default. Revised to `propagated` or `absorbed` by the `||`
                  arm at the call site.
    """
    for f in reversed(stack):
        if f.kind == 'sub':
            if f.sub == 'group':
                return 'group'
            break
    if any(f.in_pipe for f in stack) or stack[-1].stmt_pipe:
        return 'pipe'
    if any(f.in_cond for f in stack):
        return 'cond'
    return 'discarded'


def walk(prepared):
    """-> (words, brace_events)

    words: list of dicts {name, line, sub, depth} where `sub` is True iff the
    word is a command word evaluated in a subshell.
    brace_events: list of (lineno, offset, kind) for '{' and '}' at the top
    frame, used by the function-body extractor.
    """
    buf_parts = []
    linemap = []
    for lineno, line in prepared:
        for _ in range(len(line) + 1):
            linemap.append(lineno)
        buf_parts.append(line)
    buf = '\n'.join(buf_parts)
    # linemap was built one-per-char-plus-newline; rebuild exactly.
    linemap = []
    for lineno, line in prepared:
        linemap.extend([lineno] * len(line))
        linemap.append(lineno)
    if linemap:
        linemap.pop()

    words = []
    braces = []
    stack = [Frame('file')]
    # closers[i] tells how the frame at that index must be closed
    closer = ['EOF']
    i = 0
    n = len(buf)
    cmdpos = True
    pending_fn = [None]

    def enclosing_pipe():
        return any(f.in_pipe for f in stack)

    def in_subshell():
        return (any(f.kind == 'sub' for f in stack)
                or enclosing_pipe()
                or stack[-1].stmt_pipe)

    def end_statement():
        stack[-1].stmt_pipe = False
        stack[-1].words = []
        stack[-1].or_carry = []
        stack[-1].after_or = False

    while i < n:
        c = buf[i]
        two = buf[i:i + 2]

        # ---- subshell openers -------------------------------------------
        if two == '$(':
            stack.append(Frame('sub', in_pipe=False, sub='cmdsub'))
            closer.append(')')
            i += 2
            cmdpos = True
            continue
        if c == '`':
            if stack[-1].kind == 'sub' and closer[-1] == '`':
                stack.pop()
                closer.pop()
                i += 1
                cmdpos = False
                continue
            stack.append(Frame('sub'))
            closer.append('`')
            i += 1
            cmdpos = True
            continue
        if two in ('<(', '>('):
            stack.append(Frame('sub', sub='procsub'))
            closer.append(')')
            i += 2
            cmdpos = True
            continue
        if c == '(' and cmdpos:
            stack.append(Frame('sub', sub='group'))
            closer.append(')')
            i += 1
            cmdpos = True
            continue
        if c == '(':
            # `name()` -- a function header; or an array assignment.  Neither
            # is a subshell.  Consumed without a frame.
            i += 1
            cmdpos = False
            continue
        if c == ')':
            if len(stack) > 1 and closer[-1] == ')':
                gone = stack.pop()
                closer.pop()
                # THE PARENT STATEMENT OWNS THE FATE. A site inside `$( )` is
                # recorded on the SUBSTITUTION's frame, but the `||` that
                # decides whether its status is absorbed is in the ENCLOSING
                # statement -- so the words must be handed up on the pop or
                # every site reads `discarded`. Measured on the instance
                # before this line existed: all 8 rows `discarded`, including
                # `… || exit 1`, which is the one correct site in the file.
                stack[-1].words.extend(gone.words)
            i += 1
            cmdpos = False
            continue

        # ---- brace groups ------------------------------------------------
        if c == '{' and cmdpos:
            if stack[-1].after_or:
                # `x=$(f) || { …; }` -- a recovery BLOCK. `{` is not a word,
                # so without this arm the `||` is never resolved and the site
                # reads `discarded`. That is the exact spelling of one of the
                # two measured sites (jupyter-up.sh cmd_down).
                _resolve_or(stack[-1], 'absorbed')
            braces.append((linemap[i] if i < len(linemap) else 0, i, '{'))
            stack.append(Frame('group', in_pipe=(stack[-1].stmt_pipe
                                                 or enclosing_pipe()),
                               fname=pending_fn[0]))
            pending_fn[0] = None
            closer.append('}')
            i += 1
            cmdpos = True
            continue
        if c == '}':
            braces.append((linemap[i] if i < len(linemap) else 0, i, '}'))
            if len(stack) > 1 and closer[-1] == '}':
                stack.pop()
                closer.pop()
            i += 1
            cmdpos = True
            continue

        # ---- pipelines ---------------------------------------------------
        if c == '|':
            if two == '||':
                carry = list(stack[-1].words)
                i += 2
                cmdpos = True
                end_statement()
                stack[-1].or_carry = carry
                stack[-1].after_or = True
                continue
            # A real pipe.  Everything in this statement -- already scanned
            # or not -- is a pipeline segment.
            stack[-1].stmt_pipe = True
            for w in stack[-1].words:
                w['sub'] = True
            i += 1
            cmdpos = True
            continue

        # ---- statement separators ---------------------------------------
        if c == ';':
            i += 1
            cmdpos = True
            end_statement()
            continue
        if two == '&&':
            i += 2
            cmdpos = True
            end_statement()
            continue
        if c == '&':
            # A `&` IS ONLY BACKGROUNDING WHEN IT IS NOT PART OF A
            # REDIRECTION. `2>&1` and `>&2` are the two commonest tokens in
            # this repo's diagnostics, and reading them as `&` marked the
            # WHOLE STATEMENT as a forked subshell -- retroactively, through
            # the pipeline-marking loop -- so `cmd_nudge … >/dev/null 2>&1 ||
            # true` at skeptic-channel.sh:1052 was reported as a guard that
            # does not gate while sitting in the main shell.
            prev = buf[i - 1] if i else ''
            nxt = buf[i + 1] if i + 1 < n else ''
            if prev in '<>' or nxt == '>':
                i += 1
                cmdpos = False
                continue
            # Real backgrounding forks; treat the statement as a subshell.
            for w in stack[-1].words:
                w['sub'] = True
            i += 1
            cmdpos = True
            end_statement()
            continue
        if c == '\n':
            # A trailing `|`, `&&`, `||` or `\` continues the statement; the
            # prepared text keeps them, so look back.
            tail = buf[:i].rstrip()
            cont = tail.endswith('|') or tail.endswith('&&') or \
                tail.endswith('||') or tail.endswith('\\')
            i += 1
            cmdpos = True
            if not cont:
                end_statement()
            continue
        if c.isspace():
            i += 1
            continue

        # ---- a word ------------------------------------------------------
        m = re.match(_WORD, buf[i:])
        if m:
            name = m.group(0)
            if cmdpos:
                rest = buf[i + len(name):]
                mh = re.match(r'\s*\(\s*\)\s*', rest)
                if mh:
                    # A function HEADER, not a call.  The `()` is consumed
                    # here so the body's `{` is still at a command position --
                    # without that the body gets no frame and every word in
                    # every function is attributed to NO function, which makes
                    # the whole fixpoint return the empty set.  A silent zero,
                    # and it was the first bug this scanner had.
                    pending_fn[0] = name
                    i += len(name) + len(mh.group(0))
                    cmdpos = True
                    continue
                elif re.match(r'=', rest):
                    # `x=$(f) || name='(unregistered)'` -- a recovery
                    # ASSIGNMENT. Also not a command word, and also one of the
                    # two measured sites (jupyter-up.sh cmd_status).
                    if stack[-1].after_or:
                        _resolve_or(stack[-1], 'absorbed')
                else:
                    fn = None
                    for f in reversed(stack):
                        if f.fname:
                            fn = f.fname
                            break
                    w = {'name': name, 'line': linemap[i] if i < len(linemap) else 0,
                         'sub': in_subshell(), 'off': i, 'fn': fn,
                         'fate': _initial_fate(stack)}
                    words.append(w)
                    stack[-1].words.append(w)
                    # ---- THE FATE OF THE STATUS -------------------------
                    # A subshell `exit` is a DEFECT only when the non-zero
                    # status it produces is then DISCARDED or ABSORBED. The
                    # measured instance is `absorbed`:
                    #     name=$(_registry_name_for_workdir …) || name='(unregistered)'
                    # while the correct site four lines up in the same file is
                    # `propagated`:
                    #     name=$(service_name_for …) || exit 1
                    # Same construct, same guard, opposite verdicts -- so a
                    # predicate WITHOUT this column cannot tell them apart and
                    # the report is unreadable. It is an EXTRACTION column, not
                    # part of the key: the human verdict lives in the manifest.
                    if stack[-1].after_or:
                        if name in _BUILTIN_TERMINATORS:
                            _resolve_or(stack[-1], 'propagated')
                        elif name in ('return', 'continue', 'break'):
                            # NOT `propagated`, and the distinction is real:
                            # `|| return 0` hands the CALLER a SUCCESS. The
                            # refusal is honoured locally and erased globally.
                            # A separate bucket, because it needs a human.
                            _resolve_or(stack[-1], 'flow')
                        else:
                            _resolve_or(stack[-1], 'absorbed')
                    if name in ('if', 'while', 'until', 'elif'):
                        stack[-1].in_cond = True
                    if name in ('then', 'do'):
                        stack[-1].in_cond = False
                    # NO FRAME FOR `do` / `then`, DELIBERATELY, AND IT IS A
                    # DECLARED BLIND SPOT RATHER THAN AN OVERSIGHT.
                    #
                    # A frame here would let a MULTI-LINE compound body inherit
                    # the pipeline-ness of the statement that opened it, so
                    # `f | while read x; do die …; done` would be seen. It also
                    # requires balanced `if/elif/then/fi` and `case/)/esac`
                    # bookkeeping, and getting THAT wrong leaks a frame to the
                    # end of the file -- measured on 85 of 602 files, and a
                    # leaked frame is a FALSE FINDING, which is strictly worse
                    # than a missed one for a lint nobody has a reason to
                    # trust yet.
                    #
                    # So: a terminator inside a multi-line compound body that
                    # is itself a pipeline segment is NOT SEEN. Single-line
                    # pipelines and every bracket-shaped subshell ARE. The
                    # direction of this omission is UNDER-count, and it is
                    # recorded in the coverage boundary in the manifest header.
                    if name in _COMPOUND_OPEN or name in _COMPOUND_CLOSE:
                        i += len(name)
                        cmdpos = True
                        end_statement()
                        continue
                    if name == 'function':
                        m2 = re.match(r'\s+(' + _WORD + r')', rest)
                        if m2:
                            pending_fn[0] = m2.group(1)
                            i += len(name) + len(m2.group(0))
                            cmdpos = True
                            continue
                    if name in _KEYWORDS_CMDPOS:
                        i += len(name)
                        cmdpos = True
                        continue
            i += len(name)
            cmdpos = False
            continue
        # any other character
        if c == '!':
            i += 1
            continue
        i += 1
        cmdpos = False
    # SAME POST-CONDITION AS `prepare`, ON THE OTHER MACHINE. A leaked
    # SUBSHELL frame marks every command word after it as `sub`, which is a
    # confident, large, wrong finding -- 481 rows the first time it happened.
    # An unbalanced walk is therefore a REFUSAL, never a result.
    if len(stack) != 1:
        raise ParseUnbalanced(
            'walker frames did not close (%d open: %s)'
            % (len(stack) - 1, ','.join(closer[1:][:6])))
    return words, braces


# --------------------------------------------------------------------------
# 3. THE CALL GRAPH AND THE FIXPOINT
# --------------------------------------------------------------------------
# A function TERMINATES THE SHELL if, at subshell depth 0 within its own body,
# it runs `exit` or calls a function that terminates the shell.  The depth-0
# qualifier is not decoration: `f() { x=$(exit 1); }` does NOT terminate its
# caller, and a fixpoint that ignored depth would call every such wrapper a
# terminator and drown the report.
#
# The table is GLOBAL across the corpus, because a guard's `die` almost always
# lives in a SOURCED library (the measured instance's `_recover_registry_
# readable` comes from `bootstrap-recover.sh`, sourced by `jupyter-up.sh`).
# Resolving by NAME across the whole corpus is an OVER-approximation: two files
# may define the same name and only one of them exit.  The direction is stated
# in the coverage boundary -- it can add a site for a human to disposition, and
# cannot remove one.

_BUILTIN_TERMINATORS = ('exit',)
_UNPARSED = []


def scan_files(paths, root):
    """-> (per_file_words, per_file_defs, global_defs)

    per_file_defs[rel][name] = {'direct': bool, 'calls': set}
    global_defs[name]        = list of those dicts, across the corpus
    """
    per_file = {}
    per_file_defs = {}
    global_defs = {}
    sources = {}
    for rel in paths:
        full = os.path.join(root, rel)
        try:
            with open(full, 'r', errors='replace') as fh:
                text = fh.read()
        except (IOError, OSError):
            continue
        try:
            words, _ = walk(prepare(text))
        except ParseUnbalanced as e:
            # FAIL LOUD, AND FAIL THE WHOLE RUN. A per-file `continue` here
            # would be the #935 mode-1 shape: an exception written to tolerate
            # bad rows also swallows "my parser is broken", and the report
            # comes back short rather than empty -- which is worse, because a
            # zero is at least suspicious.
            _UNPARSED.append((rel, str(e)))
            continue
        per_file[rel] = words
        bodies = {}
        for w in words:
            if w['fn'] is None:
                continue
            bodies.setdefault(w['fn'], []).append(w)
        defs = {}
        for name, ws in bodies.items():
            defs[name] = {
                'file': rel,
                'direct': any(w['name'] in _BUILTIN_TERMINATORS and not w['sub']
                              for w in ws),
                'calls': set(w['name'] for w in ws if not w['sub']),
            }
            global_defs.setdefault(name, []).append(defs[name])
        per_file_defs[rel] = defs
        sources[rel] = _sourced_basenames(text)
    return per_file, per_file_defs, global_defs, sources


_SOURCE_RE = re.compile(r'^\s*(?:\.|source)\s+([^\s;&|]+)')


def _sourced_basenames(text):
    """The BASENAMES this file sources.

    Almost every `.` in this repo sources through a variable --
    `. "$_self_dir/../_guard_population.sh"` -- so the literal path is not
    resolvable statically and the BASENAME is what can be recovered. That is
    an approximation in the WIDE direction (any corpus file with that
    basename counts), and it is the right direction: a missed source edge
    would silently drop a terminator, which is the defect this lint exists to
    find.
    """
    out = set()
    for line in text.split('\n'):
        m = _SOURCE_RE.match(line)
        if not m:
            continue
        tok = m.group(1).strip('\'"')
        base = tok.rsplit('/', 1)[-1].strip('\'"')
        if base and '$' not in base:
            out.add(base)
    return out


def _visible_files(rel, sources, by_base, depth=6):
    """The transitive source closure of `rel`, as a set of corpus paths."""
    seen = {rel}
    frontier = [rel]
    for _ in range(depth):
        nxt = []
        for f in frontier:
            for base in sources.get(f, ()):
                for cand in by_base.get(base, ()):
                    if cand not in seen:
                        seen.add(cand)
                        nxt.append(cand)
        if not nxt:
            break
        frontier = nxt
    return seen


def resolve_table(local_defs, global_defs, visible=None):
    """A LOCAL definition SHADOWS every other definition of the same name.

    This is not a refinement, it is the difference between a lint and noise.
    Resolving purely globally makes a name a terminator if ANY file's
    definition of it exits -- and the mandatory two-arm negative control plants
    the SAME function names in both arms, so a global resolver flags the
    HOISTED arm too and the control cannot distinguish the defect from its own
    fix.  Measured on the first cut of this scanner: both arms red.

    Names NOT defined in the file fall back to the corpus, because a guard's
    `die` normally lives in a SOURCED library -- the measured instance's
    `_recover_registry_readable` is in `bootstrap-recover.sh`.  That fallback
    is the OVER-approximating half, and its direction is declared in the
    coverage boundary.
    """
    table = {}
    for name, d in local_defs.items():
        table[name] = [d]
    # THE FALLBACK IS SCOPED TO THE SOURCE GRAPH, NOT TO THE CORPUS.
    #
    # An unscoped fallback made the name `gh` a terminator everywhere, because
    # `monitor/gh-shim.sh:156` defines a `gh()` function that exits -- so 19
    # of 93 production sites were calls to the real `gh` BINARY inside `$( )`,
    # reported as guards that do not gate. That is one fifth of the report,
    # and a report a reader learns to discount is worse than no report.
    #
    # A name that resolves to NOTHING in the closure is NOT a terminator. It
    # is an external command, and an external command's `exit` is its own
    # process exiting, which is not this defect at all.
    for name, ds in global_defs.items():
        if name in table:
            continue
        if visible is None:
            table[name] = ds
            continue
        keep = [d for d in ds if d['file'] in visible]
        if keep:
            table[name] = keep
    return table


def terminators(fn_defs):
    """Least fixpoint of 'can terminate the shell'.  -> (set of names, rounds)."""
    term = set(_BUILTIN_TERMINATORS)
    for name, defs in fn_defs.items():
        if any(d['direct'] for d in defs):
            term.add(name)
    changed = True
    rounds = 0
    while changed:
        changed = False
        rounds += 1
        for name, defs in fn_defs.items():
            if name in term:
                continue
            for d in defs:
                if d['calls'] & term:
                    term.add(name)
                    changed = True
                    break
    return term, rounds


def explain(name, fn_defs, term, seen=None):
    """A shortest call chain from `name` down to a bare `exit`, for the
    diagnostic.  A reader of a red must be told WHY the word terminates, or the
    lint is a number nobody can check."""
    if name in _BUILTIN_TERMINATORS:
        return [name]
    seen = seen or set()
    if name in seen or name not in fn_defs:
        return [name]
    seen = seen | {name}
    best = None
    for d in fn_defs[name]:
        if d['direct']:
            return [name, 'exit']
        for callee in sorted(d['calls']):
            if callee in term and callee != name:
                chain = explain(callee, fn_defs, term, seen)
                if chain and (best is None or len(chain) < len(best) - 1):
                    best = [name] + chain
    return best or [name]


# --------------------------------------------------------------------------
# 4. SITES
# --------------------------------------------------------------------------

def sites(per_file, per_file_defs, global_defs, sources):
    """-> (rows, per_file_terms)"""
    out = []
    per_file_terms = {}
    by_base = {}
    for rel in per_file:
        by_base.setdefault(rel.rsplit('/', 1)[-1], []).append(rel)
    for rel in sorted(per_file):
        visible = _visible_files(rel, sources, by_base)
        table = resolve_table(per_file_defs.get(rel, {}), global_defs, visible)
        term, _ = terminators(table)
        per_file_terms[rel] = (term, table)
        for w in per_file[rel]:
            if not w['sub']:
                continue
            if w['name'] not in term:
                continue
            # A `die` inside a function that is ITSELF only ever called in a
            # subshell is the SAME defect one level up; both are reported, and
            # the chain column says which is which.
            out.append({
                'file': rel,
                'line': w['line'],
                'word': w['name'],
                'in_fn': w['fn'] or '-',
                'chain': '->'.join(explain(w['name'], table, term)),
                'fate': w['fate'],
            })
    return out, per_file_terms


# --------------------------------------------------------------------------
# 5. CLI
# --------------------------------------------------------------------------
# The KEY is CONTENT, never a line number.  your-org/nexus-code#1214's
# manifest learned this the expensive way: one inserted line elsewhere in a
# file shifted three recorded sites and the guard reported three added and
# three removed for a tree in which nothing changed.  So:
#     <file> \t <normalized source line> \t <occurrence> \t <word> \t <chain>
# Fields 1-3 are the key; 4-5 are this scanner's extraction.

def normalize(s):
    return re.sub(r'\s+', ' ', s).strip()


def main(argv):
    if len(argv) < 3:
        sys.stderr.write('usage: _subshell_exit_scan.py <root> <filelist>\n')
        return 2
    root, filelist = argv[1], argv[2]
    with open(filelist) as fh:
        paths = [l.strip() for l in fh if l.strip()]
    per_file, per_file_defs, global_defs, sources = scan_files(paths, root)
    if _UNPARSED:
        sys.stderr.write(
            '_subshell_exit_scan: %d of %d files did not PARSE to a balanced\n'
            % (len(_UNPARSED), len(paths)))
        sys.stderr.write(
            '  top-level context. Refusing to report a population that is\n'
            '  short by an unknown amount:\n')
        for rel, why in _UNPARSED:
            sys.stderr.write('    %s: %s\n' % (rel, why))
        return 3
    rows, per_file_terms = sites(per_file, per_file_defs, global_defs, sources)

    # occurrence ordinal within (file, normalized line)
    raw_cache = {}
    counts = {}
    out = []
    for r in rows:
        if r['file'] not in raw_cache:
            try:
                with open(os.path.join(root, r['file']), 'r',
                          errors='replace') as fh:
                    raw_cache[r['file']] = fh.read().split('\n')
            except (IOError, OSError):
                raw_cache[r['file']] = []
        lines = raw_cache[r['file']]
        text = normalize(lines[r['line'] - 1]) if 0 < r['line'] <= len(lines) else ''
        k = (r['file'], text)
        counts[k] = counts.get(k, 0) + 1
        out.append((r['file'], text, counts[k], r['word'],
                    r['fate'] + ':' + r['chain'], r['line'], r['in_fn']))
    mode = os.environ.get('SEG_MODE', 'sites')
    if mode == 'terminators':
        seen = set()
        for rel in sorted(per_file_terms):
            term, table = per_file_terms[rel]
            for name in sorted(term):
                if name in _BUILTIN_TERMINATORS:
                    continue
                if name not in per_file_defs.get(rel, {}):
                    continue
                if (rel, name) in seen:
                    continue
                seen.add((rel, name))
                sys.stdout.write('%s\t%s\t%s\n' % (
                    rel, name, '->'.join(explain(name, table, term))))
        return 0
    if mode == 'locate':
        for f, t, occ, w, ch, ln, infn in out:
            sys.stdout.write('%s\t%s\t%d\t%d\t%s\n' % (f, t, occ, ln, infn))
        return 0
    for f, t, occ, w, ch, ln, infn in out:
        sys.stdout.write('%s\t%s\t%d\t%s\t%s\n' % (f, t, occ, w, ch))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
