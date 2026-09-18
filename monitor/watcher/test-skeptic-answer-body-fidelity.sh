#!/usr/bin/env bash
# Unit tests for ANSWER-BODY FIDELITY on the worker↔skeptic channel
# (your-org/nexus-code#1405).
#
# THE DEFECT. `monitor/skeptic-channel.sh:cmd_answer` composed the permanent
# `*.answered.md` record with `awk -v ans="$body"`, and `awk -v x=VAL`
# ESCAPE-PROCESSES VAL. Every backslash sequence in a worker's answer was
# interpreted before it reached the record, at rc 0.
#
# THE LOUD/SILENT SPLIT IS THE DEFECT, not the escaping. Measured, GNU awk
# 4.1.4 on this host:
#
#     sent=A\dB   landed=AdB           stderr=56 B   <- warns
#     sent=A\nB   landed=A<newline>B   stderr=0  B   <- SILENT
#     sent=A\tB   landed=A<tab>B       stderr=0  B   <- SILENT
#     sent=A\<nl>B landed=A\B          stderr=0  B   <- SILENT (newline EATEN,
#                                                       backslash SURVIVES)
#
# The escapes that merely ALTER A TOKEN complain. The ones that DESTROY
# STRUCTURE — `\n`, `\t`, and a trailing `\` line continuation — are consumed
# with nothing on stderr. That is the shape CLAUDE.md's PYTHON-BACKREF-ESCAPE
# entry names: the tooling built for the class cannot see the member that
# destroys data.
#
# WHY IT MATTERS ON *THIS* PATH. `cmd_ask` writes the skeptic's QUESTION with
# `printf '%s\n\n' "$body"` and has always been faithful. So the channel was
# lossless exactly where a mistake gets caught in conversation, and lossy
# exactly where it becomes the durable, machine-read record that `reconcile`
# and the orphan detectors consult. Two live artefacts: `grep -vP '^\d+:\s*#'`
# landed as `^d+:s*#`, a STRICTLY WEAKER predicate than the one that ran — a
# corruption that self-deprecates reads as an honest admission and is accepted
# as written — and a three-line `find … \ | xargs … | sort …` landed as one
# unrunnable line, breaking the re-runnable half of this workspace's
# evidentiary contract while leaving the claim looking fully sourced.
#
# `--file` does NOT protect. #1157's remedy defeats a SHELL layer; this
# corruption is downstream of the file read, inside the tool.
#
# WHAT THIS SUITE ASSERTS. Byte-identity between what was sent and what
# landed, for every input class, over all three body transports
# (`--file`, `--message`, stdin) — plus stderr silence, since the fixed path
# must not emit awk's escape warnings either.
#
# SECTION 4 IS THE POSITIVE CONTROL AND IT IS NOT OPTIONAL. A byte-identity
# assertion is exactly the kind that can be placed where it cannot fail, and a
# test written after a fix tends to agree with the fix. So the suite reverts
# `cmd_answer` to its pre-fix form in a COPY of the real script and requires
# every silent class to be caught. The revert is anchor-checked: if the anchor
# is missing the suite dies loudly rather than passing a vacuous control.
#
# Run: bash monitor/watcher/test-skeptic-answer-body-fidelity.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_monitor_dir=$(cd "$_test_dir/.." && pwd)
CH="$_monitor_dir/skeptic-channel.sh"

. "$_test_dir/_test_helpers.sh"
EXPECTED_ASSERTIONS=34   # counted BEFORE the census assertion itself

# Routed through the shared ledger (`_th_pass`/`_th_fail`) rather than bare
# counters: the ledger survives the subshell a counter dies in, so a FAILING
# assertion inside `$( … )` cannot be lost and let this suite exit 0 over it
# (your-org/nexus-code#805). That matters here more than usual — several
# assertions below run inside command substitutions.
ok()  { printf '  PASS: %s\n' "$1"; _th_pass; }
bad() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

[[ -x "$CH" ]] || { printf 'skeptic-channel.sh not executable at %s\n' "$CH" >&2; exit 2; }

WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT

export NEXUS_STATE_DIR="$WORK/state"
mkdir -p "$NEXUS_STATE_DIR"
# Keep the tool off any real config: NEXUS_STATE_DIR is _resolve_state_dir's
# first and only unconditional arm, so no other arm is ever consulted.
unset NEXUS_ROOT 2>/dev/null || true

# ---- the planted corpus -------------------------------------------------
#
# Each entry is a body class. The name is the task-id (also the channel dir),
# so every case gets its own channel and cannot contaminate another.
#
# Written with printf and SINGLE-quoted operands: a heredoc with an unquoted
# delimiter, or a double-quoted string, would let the SHELL eat these
# sequences before the fixture exists (#1157) and the suite would be testing
# nothing. Every source ends with exactly one newline and starts with a
# non-blank line — a precondition the extractor below relies on and section 0
# asserts.
plant_body() {   # <name> -> writes $WORK/src/<name>.md
    local name="$1"; shift
    mkdir -p "$WORK/src"
    local f="$WORK/src/$name.md"
    printf '%s\n' "$@" > "$f"
    printf '%s' "$f"
}

# The LOUD class: awk warns on stderr but still eats the backslash. This is
# the live artefact from #1405 — a regex made strictly weaker.
SRC_warn=$(plant_body warn \
    'the sweep ran:' \
    "grep -vP '^\\d+:\\s*#' monitor/ng | wc -l" \
    'and \w \b \( \+ \. survive as themselves')

# The SILENT classes. These are the ones that destroy structure.
SRC_nl=$(plant_body nl \
    'the literal two characters backslash-n:' \
    'sed -e '"'"'s/A\nB/x/'"'"' file')

SRC_tab=$(plant_body tab \
    'the literal two characters backslash-t:' \
    "awk -F'\\t' '{print \$2}' rows.tsv")

# A trailing backslash line CONTINUATION across three lines. Pre-fix this
# landed as one unrunnable line with the backslashes left behind.
SRC_cont=$(plant_body cont \
    'find monitor -name "test-*.sh" -print0 \' \
    '  | xargs -0 grep -l pipefail \' \
    '  | sort')

# printf FORMAT-position hazards, in case a fix reached for `printf "$body"`
# instead of `printf %s "$body"`. A body carrying %s/%d/%% must survive.
SRC_fmt=$(plant_body fmt \
    'coverage was 100%s of 100%d, i.e. 100%% — and %n is not a directive here')

# Kitchen sink: every class at once, plus non-ASCII (a byte-identity check
# that only ever sees ASCII cannot see a multi-byte mangling) and a line whose
# ONLY content is a backslash.
SRC_mix=$(plant_body mix \
    'ré-run — μ=0.5, naïve:' \
    "printf 'A\\tB\\nC' | grep -P '\\d\\s\\w'" \
    'continued \' \
    '  and finished' \
    '\' \
    'done')

# ---- extraction ---------------------------------------------------------
#
# Take the composed record's bytes AFTER the `## Worker response` marker line
# and strip the leading blank-line separator. `tail -n +N` is byte-faithful;
# `sed '/./,$!d'` deletes leading blank lines only. Neither interprets the
# body. Doing this with a pattern that had to escape the body would be this
# suite reproducing the defect it tests.
extract_body() {   # <answered-file> -> body bytes on stdout
    local f="$1" ln
    # No `| head`: an early-exit reader closes the pipe and, under this file's
    # `pipefail`, the writer's EPIPE can invert the status (#622). Parameter
    # expansion takes the first line with no pipeline and no reader.
    ln=$(command grep -n '^## Worker response$' -- "$f"); ln="${ln%%$'\n'*}"; ln="${ln%%:*}"
    [[ -n "$ln" ]] || return 1
    tail -n +$(( ln + 1 )) -- "$f" | sed '/./,$!d'
}

# ---- one round: ask, answer, compare ------------------------------------
#
# `chan` is the script under test for this round — the real one in sections
# 1-3, the reverted MUTANT in section 4.
round() {   # <chan> <task> <src-file> <transport: file|message|stdin>
    local chan="$1" task="$2" src="$3" transport="$4"
    local dir errf out
    errf="$WORK/err.$task.$transport"
    "$chan" ask "$task" probe --message 'why this default?' >/dev/null 2>&1 || return 90
    case "$transport" in
        file)    out=$("$chan" answer "$task" 1 --file "$src" 2>"$errf") ;;
        message) out=$("$chan" answer "$task" 1 --message "$(cat -- "$src")" 2>"$errf") ;;
        stdin)   out=$("$chan" answer "$task" 1 - <"$src" 2>"$errf") ;;
        *) return 91 ;;
    esac
    local rc=$?
    (( rc == 0 )) || return 92
    printf '%s' "$out"
}

assert_faithful() {   # <label> <src> <answered-file>
    local label="$1" src="$2" ans="$3" got="$WORK/got.$$.$RANDOM"
    if ! extract_body "$ans" > "$got"; then
        bad "$label — no '## Worker response' marker in $ans"; return
    fi
    if cmp -s -- "$src" "$got"; then
        ok "$label"
    else
        bad "$label — landed bytes differ from source"
        printf '    --- first differing byte ---\n' >&2
        cmp -- "$src" "$got" >&2 || true
        local _os _og
        _os=$(od -c -- "$src" | tr '\n' '|'); _og=$(od -c -- "$got" | tr '\n' '|')
        printf '    sent  : %s\n' "${_os:0:400}" >&2
        printf '    landed: %s\n' "${_og:0:400}" >&2
    fi
    rm -f "$got"
}

assert_corrupted() {   # <label> <src> <answered-file>   [POSITIVE CONTROL]
    local label="$1" src="$2" ans="$3" got="$WORK/got.$$.$RANDOM"
    if ! extract_body "$ans" > "$got"; then
        bad "$label — no marker (control could not run)"; return
    fi
    if cmp -s -- "$src" "$got"; then
        bad "$label — control is VACUOUS: the pre-fix path did NOT corrupt this input, so a green here proves nothing"
    else
        ok "$label"
    fi
    rm -f "$got"
}

assert_empty_stderr() {   # <label> <errfile>
    local label="$1" f="$2" n
    n=$(wc -c < "$f")
    if (( n == 0 )); then ok "$label"
    else local _x; _x=$(tr '\n' ' ' < "$f"); bad "$label — ${n} bytes on stderr: ${_x:0:200}"; fi
}

# ---- 0. corpus preconditions -------------------------------------------
#
# The extractor strips LEADING blank lines, so a source that began with one
# would be compared against a stripped copy of itself and the comparison would
# be blind to a corruption in that position. Assert the precondition rather
# than assume it.
echo "=== 0. corpus preconditions ==="
_pre_bad=0
for f in "$WORK"/src/*.md; do
    [[ -s "$f" ]] || { printf '    empty fixture: %s\n' "$f" >&2; _pre_bad=1; }
    if [[ -z "$(head -1 -- "$f")" ]]; then
        printf '    fixture starts with a blank line: %s\n' "$f" >&2; _pre_bad=1
    fi
done
if (( _pre_bad == 0 )); then ok "every fixture is non-empty and starts non-blank"
else bad "corpus precondition violated — comparisons below would be blind"; fi

# The fixtures must actually CONTAIN backslashes, or the whole suite is
# vacuous by construction. This is the counterpart of #1405's own lesson: a
# body with no backslashes is unaffected and proves nothing.
_bs=$(command grep -c '\\' -- "$WORK"/src/warn.md "$WORK"/src/nl.md "$WORK"/src/tab.md "$WORK"/src/cont.md "$WORK"/src/mix.md 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
if (( _bs >= 5 )); then ok "fixtures carry backslashes ($_bs lines) — the suite is not vacuous"
else bad "fixtures carry only $_bs backslash lines — the shell ate them before the tool ran"; fi

# ---- 1. every input class survives, --file transport --------------------
echo "=== 1. byte-identity, --file ==="
for c in warn nl tab cont fmt mix; do
    eval "src=\$SRC_$c"
    if out=$(round "$CH" "f-$c" "$src" file); then
        assert_faithful "--file / $c class lands byte-identical" "$src" "$out"
    else
        bad "--file / $c class — round failed (rc $?)"
    fi
done

# ---- 2. stderr silence --------------------------------------------------
#
# Pre-fix, the `warn` class put 56+ bytes of awk escape warnings on stderr of
# a call that exited 0. The fixed path routes the body nowhere near awk, so
# there is nothing to warn about. This is a SECOND observable and it is the
# one that would have caught the defect had anyone read it.
echo "=== 2. no diagnostics on a successful answer ==="
for c in warn mix; do
    assert_empty_stderr "--file / $c class writes nothing to stderr" "$WORK/err.f-$c.file"
done

# ---- 3. the other two body transports -----------------------------------
#
# `--message` and stdin reach the same writer. #1157's shell hazard is a
# DIFFERENT layer and is not what is under test here — the fixture bytes are
# handed over without re-quoting, so a failure here is the tool's.
echo "=== 3. byte-identity, --message and stdin ==="
for c in warn nl tab cont mix; do
    eval "src=\$SRC_$c"
    if out=$(round "$CH" "m-$c" "$src" message); then
        assert_faithful "--message / $c class lands byte-identical" "$src" "$out"
    else
        bad "--message / $c class — round failed"
    fi
    if out=$(round "$CH" "s-$c" "$src" stdin); then
        assert_faithful "stdin / $c class lands byte-identical" "$src" "$out"
    else
        bad "stdin / $c class — round failed"
    fi
done

# ---- 4. POSITIVE CONTROL: the assertion must FAIL pre-fix ---------------
#
# Revert cmd_answer's body write to its pre-fix `awk -v ans="$body"` form in a
# COPY of the real script and re-run the same corpus. Every silent class must
# now be caught. If this section were to pass silently, sections 1 and 3 would
# be assertions placed where they cannot fail.
echo "=== 4. positive control: the pre-fix write path is CAUGHT ==="
MUT_DIR="$WORK/mutant"
mkdir -p "$MUT_DIR"
cp -- "$CH" "$MUT_DIR/skeptic-channel.sh"
# The script sources its window-key encoder from its own directory and
# REFUSES to run without it (#941). Link, do not copy: a copy is a second
# transcription, which is the defect that rule exists to prevent.
ln -s "$_monitor_dir/_bookkeeping.sh" "$MUT_DIR/_bookkeeping.sh"

python3 - "$MUT_DIR/skeptic-channel.sh" <<'PY'
import io, sys
# r-strings throughout: `"\1"` and `"\t"` are VALID Python escapes and would be
# consumed silently here, which is #1203 — the authoring-side twin of the very
# defect under test. Nothing below may be a non-raw literal.
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
fixed = r"""        ' "$src" && printf '\n%s\n' "$body"
    } > "$tmp" || { rm -f "$tmp"; die "answer: failed to compose response"; }"""
prefix = r"""    local ts; ts=$(_now_iso)
    {
        awk -v ts="$ts" '"""
if s.count(fixed) != 1 or s.count(prefix) != 1:
    sys.stderr.write(
        "REFUSED: revert anchors not found exactly once "
        "(fixed=%d prefix=%d). The control cannot be trusted; "
        "update this revert alongside cmd_answer.\n" % (s.count(fixed), s.count(prefix)))
    sys.exit(3)
s = s.replace(prefix, r"""    awk -v ans="$body" -v ts="$(_now_iso)" '""")
s = s.replace(fixed, r"""        END { print ""; print ans }
    ' "$src" > "$tmp" || { rm -f "$tmp"; die "answer: failed to compose response"; }""")
io.open(p, "w", encoding="utf-8").write(s)
PY
_revert_rc=$?
if (( _revert_rc != 0 )); then
    printf '  FAIL: could not build the pre-fix mutant (rc %d) — the positive control did not run\n' "$_revert_rc" >&2
    FAIL=$(( FAIL + 1 ))
else
    chmod +x "$MUT_DIR/skeptic-channel.sh"
    if bash -n "$MUT_DIR/skeptic-channel.sh"; then
        ok "pre-fix mutant builds and parses"
    else
        bad "pre-fix mutant does not parse — the control did not run"
    fi
    # Each silent class must be CAUGHT by the same assertion that passes above.
    for c in nl tab cont mix; do
        eval "src=\$SRC_$c"
        if out=$(round "$MUT_DIR/skeptic-channel.sh" "x-$c" "$src" file); then
            assert_corrupted "pre-fix / $c class is DETECTED as corrupted" "$src" "$out"
        else
            bad "pre-fix / $c class — mutant round failed to run"
        fi
    done
    # The LOUD class must be caught too, and must additionally be shown to
    # have been loud: 56 bytes of awk warning at rc 0 is what nobody read.
    if out=$(round "$MUT_DIR/skeptic-channel.sh" "x-warn" "$SRC_warn" file); then
        assert_corrupted "pre-fix / warn class is DETECTED as corrupted" "$SRC_warn" "$out"
        _n=$(wc -c < "$WORK/err.x-warn.file")
        if (( _n > 0 )); then ok "pre-fix / warn class emitted ${_n} bytes of awk warning at rc 0 (the loud half)"
        else bad "pre-fix / warn class was SILENT — the loud/silent split this suite documents does not hold on this awk"; fi
    else
        bad "pre-fix / warn class — mutant round failed to run"
    fi
    # …and the comparator must not be a rubber stamp in the other direction:
    # the pre-fix path is faithful to a body with NO backslashes, so a green
    # `assert_faithful` there is a real green, not a broken instrument.
    SRC_plain=$(plant_body plain 'a body with no backslashes at all' 'two plain lines')
    if out=$(round "$MUT_DIR/skeptic-channel.sh" "x-plain" "$SRC_plain" file); then
        assert_faithful "pre-fix / backslash-free body is faithful (comparator is not a rubber stamp)" "$SRC_plain" "$out"
    else
        bad "pre-fix / plain class — mutant round failed to run"
    fi
fi

# ---- 5. the REQUEST path stays faithful ---------------------------------
#
# cmd_ask was never affected. Asserted anyway, because the fix's stated
# rationale is that both body writes are now the SAME SHAPE — a regression
# that broke `ask` while `answer` stayed green would falsify that claim
# without failing anything above.
echo "=== 5. the ask path (never affected) stays faithful ==="
"$CH" ask ask-fid probe --file "$SRC_mix" >/dev/null 2>&1
_askfile=$(command ls "$NEXUS_STATE_DIR"/skeptic/ask-fid/req-001-probe.open.md 2>/dev/null)
if [[ -n "$_askfile" ]]; then
    _ln=$(command grep -n '^## Skeptic request$' -- "$_askfile"); _ln="${_ln%%$'\n'*}"; _ln="${_ln%%:*}"
    _end=$(command grep -n '^## Worker response$' -- "$_askfile"); _end="${_end%%$'\n'*}"; _end="${_end%%:*}"
    if [[ -n "$_ln" && -n "$_end" ]]; then
        sed -n "$(( _ln + 1 )),$(( _end - 1 ))p" -- "$_askfile" | sed '/./,$!d' \
            | sed -e :a -e '/^\n*$/{$d;N;};/\n$/ba' > "$WORK/askgot"
        if cmp -s -- "$SRC_mix" "$WORK/askgot"; then ok "ask body lands byte-identical"
        else bad "ask body differs — cmd_ask regressed"; fi
    else
        bad "ask record missing its section markers"
    fi
else
    bad "ask did not produce a request file"
fi

# ---- 6. the SECOND awk -v site: the window-NAME resolver ----------------
#
# `_resolve_window_index` looked the name up with `awk -v n="$name"`, and the
# name is NOT internal: it arrives unvalidated from `nudge <worker-window>`,
# `notify-delta <skeptic-window>` and `reconcile --window W`. #1405 records
# this site as "a NAME lookup, not body text" and stops there. Measured, the
# lookup is escape-processed exactly as the body was.
#
# TWO DIRECTIONS, and only one is benign. A MISS makes the resolver return 1
# and the caller FAILS SAFE — documented and deliberate. A WRONG MATCH does
# not: `_wake_gate` reads pane state of the index this returns while
# `paste-followup.sh` is handed the window NAME, so a mis-resolution evaluates
# one window's guard and pastes into another. That is the inert-guard defect
# the resolver exists to prevent, and it can steamroll a `user-typing`
# operator.
#
# Driven end to end through `nudge` rather than by calling the function: the
# claim is about which window the GUARD probed, and only the caller shows it.
echo "=== 6. window-name resolution is not escape-processed ==="
RES_DIR="$WORK/res"
mkdir -p "$RES_DIR/bin"
# Two windows whose names differ ONLY in backslash count.
cat > "$RES_DIR/bin/tmux" <<'STUB'
#!/usr/bin/env bash
# Honour the FORMAT the resolver asks for (your-org/nexus-code#1410 changed the
# delimiter to `|`; the pre-fix mutant still asks for a space), so both the
# fixed resolver and its mutant read rows in the shape they expect.
if [[ "${1:-}" == list-windows ]]; then
    # Emit rows in the delimiter the caller's -F asked for. No parameter
    # substitution of the names: a backslash in a `${var//pat/rep}` replacement
    # is escape-processed by bash and the rows came out mangled.
    case "${3:-}" in
        *'|'*) printf '3|a\\b\n7|a\\\\b\n' ;;
        *)     printf '3 a\\b\n7 a\\\\b\n' ;;
    esac
fi
exit 0
STUB
chmod +x "$RES_DIR/bin/tmux"
# pane-state stub: RECORDS the key it was probed with, then reports idle so
# the gate proceeds. That recorded key is the whole measurement.
cat > "$RES_DIR/bin/ps-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" > "$PS_PROBE_LOG"
echo 'state=idle active=0'
STUB
chmod +x "$RES_DIR/bin/ps-stub"
# paste stub: fails, so `nudge` exits 3 before reaching `ng log-action`. The
# paste is not under test; the probed index is.
printf '#!/usr/bin/env bash\nexit 1\n' > "$RES_DIR/bin/paste-stub"
chmod +x "$RES_DIR/bin/paste-stub"

probe_index_for() {   # <chan> <task> <window> -> key pane-state was probed with
    local chan="$1" task="$2" window="$3"
    export PS_PROBE_LOG="$WORK/psprobe.$task"
    : > "$PS_PROBE_LOG"
    "$chan" ask "$task" probe --message 'why?' >/dev/null 2>&1
    # The WINDOW carries the backslash; --task keeps the channel key clean.
    # No --force: --force skips the pane-state guard, which is the thing
    # being measured.
    PATH="$RES_DIR/bin:$PATH" \
    SKEPTIC_PANESTATE_BIN="$RES_DIR/bin/ps-stub" \
    SKEPTIC_PASTE_BIN="$RES_DIR/bin/paste-stub" \
    "$chan" nudge "$window" --task "$task" >/dev/null 2>&1
    cat "$PS_PROBE_LOG" 2>/dev/null
}

# Precondition: the seam that short-circuits the resolver must be unset, or
# this section measures the seam instead of the resolver.
if [[ -z "${SKEPTIC_WINDOW_INDEX:-}" ]]; then
    ok "SKEPTIC_WINDOW_INDEX is unset — the resolver, not its test seam, is under test"
else
    bad "SKEPTIC_WINDOW_INDEX is set — section 6 would measure the seam"
fi

# W1 is the one-backslash name at index 3; W2 is the two-backslash name at
# index 7. Both are probed, because the two names fail in OPPOSITE directions
# pre-fix and only one of those directions is dangerous.
W1='a\b'
W2='a\\b'

_got=$(probe_index_for "$CH" res-fixed-1 "$W1")
if [[ "$_got" == "3" ]]; then
    ok "one-backslash window name resolves to its OWN index (3)"
elif [[ -z "$_got" ]]; then
    bad "one-backslash window name did not resolve at all (fail-safe miss, not the fixed behaviour)"
else
    bad "one-backslash window name resolved to index $_got — the guard probed a DIFFERENT window"
fi

_gotb=$(probe_index_for "$CH" res-fixed-2 "$W2")
if [[ "$_gotb" == "7" ]]; then
    ok "two-backslash window name resolves to its OWN index (7)"
else
    bad "two-backslash window name resolved to '${_gotb:-<none>}', expected 7"
fi

# POSITIVE CONTROL for this site, anchor-checked exactly as section 4 is.
# Without it the assertion above is one that cannot fail.
MUT2="$WORK/mutant2"
mkdir -p "$MUT2"
cp -- "$CH" "$MUT2/skeptic-channel.sh"
ln -s "$_monitor_dir/_bookkeeping.sh" "$MUT2/_bookkeeping.sh"
python3 - "$MUT2/skeptic-channel.sh" <<'PY'
import io, sys
# r-strings only — see section 4's revert note (#1203).
p = sys.argv[1]
lines = io.open(p, encoding="utf-8").read().split("\n")
fixed = r"""            | awk 'BEGIN { FS = sprintf("%c", 124); n = ENVIRON["_SKC_WNAME"] } $2 == n { print $1; exit }'   # 124 is `|`: NO literal pipe in the program text, so early-exit-readers.sh still sees ONE awk-exit element (#1415)"""
pre   = r"""            | awk -v n="$name" '$2 == n { print $1; exit }'"""
hits = [i for i, l in enumerate(lines) if l == fixed]
if len(hits) != 1:
    sys.stderr.write("REFUSED: resolver revert anchor found %d times; "
                     "the control cannot be trusted.\n" % len(hits))
    sys.exit(3)
lines[hits[0]] = pre
# The pre-fix resolver also asked tmux for SPACE-joined rows (#1410 moved the
# delimiter to `|`); a mutant that keeps the `|` format under default awk
# splitting reads an empty $2 and misses — a fail-safe miss, not the pre-fix
# wrong-window collision this control exists to reproduce.
fmt_fixed = "        tmux list-windows -F '#{window_index}|#{window_name}' 2>/dev/null \\"
fmt_pre   = "        tmux list-windows -F '#{window_index} #{window_name}' 2>/dev/null \\"
fhits = [i for i, l in enumerate(lines) if l == fmt_fixed]
if len(fhits) != 1:
    sys.stderr.write("REFUSED: resolver format anchor found %d times.\n" % len(fhits))
    sys.exit(3)
lines[fhits[0]] = fmt_pre
io.open(p, "w", encoding="utf-8").write("\n".join(lines))
PY
_rev2_rc=$?
if (( _rev2_rc != 0 )); then
    printf '  FAIL: could not build the pre-fix resolver mutant (rc %d) — control did not run\n' "$_rev2_rc" >&2
    FAIL=$(( FAIL + 1 ))
else
    chmod +x "$MUT2/skeptic-channel.sh"
    # Direction 1 — the BENIGN one. awk reads `a\b` as a-BACKSPACE-b, which
    # matches nothing, so the resolver returns 1 and the caller fails safe.
    _got2=$(probe_index_for "$MUT2/skeptic-channel.sh" res-prefix-1 "$W1")
    if [[ "$_got2" == "3" ]]; then
        bad "pre-fix resolver control is VACUOUS on W1 — it resolved correctly, so nothing above is proven"
    elif [[ -z "$_got2" ]]; then
        ok "pre-fix resolver MISSED the one-backslash window (rc 1 -> nudge skipped: the benign direction)"
    else
        ok "pre-fix resolver returned index $_got2 for the one-backslash window — wrong, but not window 3"
    fi
    # Direction 2 — the DANGEROUS one, and the reason this site is fixed
    # rather than merely noted. awk collapses `a\\b` to `a\b`, which matches
    # the OTHER window: the gate reads index 3's pane state while
    # paste-followup.sh is handed the name of window 7.
    _got3=$(probe_index_for "$MUT2/skeptic-channel.sh" res-prefix-2 "$W2")
    if [[ "$_got3" == "3" ]]; then
        ok "pre-fix resolver returned index 3 for the window at index 7 — the guard probed the WRONG window"
    elif [[ "$_got3" == "7" ]]; then
        bad "pre-fix resolver control is VACUOUS on W2 — it resolved correctly, so nothing above is proven"
    else
        bad "pre-fix resolver returned '${_got3:-<none>}' for W2 — expected the wrong-window collision (3)"
    fi
fi

# ASSERTION CENSUS — a vanished assertion reddens here rather than shrinking
# the total in silence (your-org/nexus-code#807). A byte-identity suite is
# exactly the kind whose coverage can quietly evaporate: drop a class from the
# loop and every remaining assertion still passes.
_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
if [[ "$_total" == "$EXPECTED_ASSERTIONS" ]]; then
    printf '  PASS: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS" >&2; _th_fail
fi

th_summary_and_exit
