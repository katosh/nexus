#!/usr/bin/env bash
# test-claude-md-tmux-socket-selection.sh — execute CLAUDE.md's
# TMUX-SOCKET-SELECTION block (your-org/nexus-code#1550).
#
# WHY THIS SUITE EXISTS. Inside a tmux pane `TMUX_TMPDIR` is INERT: `$TMUX`
# sits above it in tmux's socket precedence, so a command scoped only by
# `TMUX_TMPDIR` addresses the AMBIENT server — at rc 0, with EMPTY stderr, and
# with a well-formed answer about a server the caller did not mean. The
# `cc_auto_update` evaluator asked five throwaway socket dirs whether anything
# was left behind, got five confident answers about PRODUCTION, and its next
# step was a `kill-session` against the board. Only `monitor/tmuxwrap` stopped
# it. Nothing errored at any point; the only tell was that five independent
# servers agreed to the character.
#
# WHAT IS ACTUALLY PINNED:
#   the PRECEDENCE — `-S` beats `$TMUX`; `$TMUX` beats `TMUX_TMPDIR`.
#   the DEFECT     — the WRONG form answers about the AMBIENT socket, rc 0,
#                    stderr EMPTY, while a real server DOES exist under the
#                    dir it was given (control B: so the answer is a
#                    misdirection, not an "it was not there").
#   the REMEDIES   — both documented forms address the socket they name.
#
# CONTAINMENT, stated first: every server this suite creates lives on a socket
# UNDER ITS OWN $WORK, addressed by `-S` or by a `TMUX_TMPDIR` rooted there.
# Isolation is ASSERTED before any kill-server runs, and the suite aborts hard
# if a socket it is about to tear down resolves to the board's. No command here
# ever kills anything the suite did not create.
#
# CONTROLS:
#   A — extracted form count PINNED at 3 (#618's shape: a block that silently
#       loses a line must red, not quietly narrow what is checked).
#   B — POSITIVE control on the TMUX_TMPDIR server: it exists and IS
#       addressable, so the WRONG form's answer is a misdirection and not an
#       absence. Without B the whole defect reads as "nothing was there".
#   C — NEGATIVE control on stderr: the WRONG form's stderr is EMPTY. A defect
#       that complained would not be this defect.
#
# Run: bash monitor/watcher/test-claude-md-tmux-socket-selection.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

# ── this suite DECLARES its own population (the --population protocol) ──────
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        CLAUDE.md \
        monitor/tmuxwrap/tmux \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"
th_claude_md_block_coverage TMUX-SOCKET-SELECTION

HAVE_TMUX=no
if command -v tmux >/dev/null 2>&1; then HAVE_TMUX=yes
else th_skip "every server arm" "tmux is not on PATH — only extraction ran"
fi
IN_PANE=no
if [[ -n "${TMUX:-}" ]]; then IN_PANE=yes
else th_skip "the DEFECT arm" "\$TMUX is unset, so the precedence rung this entry is about (\$TMUX above TMUX_TMPDIR) does not exist here; the remedies still ran"
fi

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

_extract() {   # $1 = a markdown file carrying the block
    awk -v b='<!-- BEGIN TMUX-SOCKET-SELECTION -->' -v e='<!-- END TMUX-SOCKET-SELECTION -->' '
        index($0, b) { inb = 1; next }
        index($0, e) { inb = 0 }
        inb' "$1" \
        | sed -E 's/^[[:space:]]+//' \
        | grep -vE '^```' \
        | sed -E 's/[[:space:]]{2,}#.*$//' \
        | grep -E '(^|[[:space:]])tmux '
}

FORMS=$(_extract "$CLAUDE_MD")
FORM_COUNT=$(printf '%s\n' "$FORMS" | grep -cE '(^|[[:space:]])tmux ')
assert_eq "extracted exactly 3 documented forms (control A)" "$FORM_COUNT" "3"
[[ "$FORM_COUNT" == "3" ]] || th_abort "block malformed — refusing to draw conclusions from it"

FORM_S=$(printf '%s\n'    "$FORMS" | sed -n '1p')
FORM_ENV=$(printf '%s\n'  "$FORMS" | sed -n '2p')
FORM_WRONG=$(printf '%s\n' "$FORMS" | sed -n '3p')
assert_contains     "form 1 is the explicit-socket remedy"        "$FORM_S"     '-S '
assert_contains     "form 2 is the \$TMUX-removed remedy"         "$FORM_ENV"   'env -u TMUX'
assert_not_contains "form 3 carries NO -S"                        "$FORM_WRONG" '-S '
assert_not_contains "form 3 does NOT remove \$TMUX — that is the whole defect" \
                    "$FORM_WRONG" 'env -u TMUX'
assert_contains     "form 3 is scoped by TMUX_TMPDIR alone"       "$FORM_WRONG" 'TMUX_TMPDIR='

echo
echo '=== POSITIVE CONTROLS: the checks above are asserted to FIRE on a planted block ==='
# The doctrine (guard-positive-controls.manifest): a guard that cannot be shown
# firing is not a guard. Both plants are DOCUMENTATION regressions, which is the
# only kind a CLAUDE.md marker suite can suffer — the block stops saying what it
# is for, silently, while every form in it still runs.
_PLANT=$(mktemp -t nxtss-plant-XXXXXX) || th_abort "cannot allocate a plant file"
trap 'rm -f "$_PLANT"' RETURN 2>/dev/null || true
# P1 — somebody "fixes" the WRONG form by adding `env -u TMUX`, so the block no
# longer documents the defect at all. The shape check must catch it.
sed -e 's|^  TMUX_TMPDIR="$dir" tmux <cmd>|  env -u TMUX TMUX_TMPDIR="$dir" tmux <cmd>|' \
    "$CLAUDE_MD" > "$_PLANT"
_p3=$(_extract "$_PLANT" | sed -n '3p')
assert_eq "P1: a WRONG form silently 'fixed' to env -u TMUX IS detected (the block would stop documenting the defect)" \
    "$(case "$_p3" in *'env -u TMUX'*) echo detected ;; *) echo MISSED ;; esac)" detected
# P2 — a form is lost to an edit. The count pin must catch it.
grep -v '^  tmux -S "\$sock" <cmd>' "$CLAUDE_MD" > "$_PLANT"
assert_eq "P2: a block that LOST a form IS detected by the count pin" \
    "$(_extract "$_PLANT" | grep -cE '(^|[[:space:]])tmux ')" 2
rm -f "$_PLANT"

_th_count_guard() {
    local EXPECTED_ASSERTIONS=9                       # extraction (7) + plants (2)
    [[ "$HAVE_TMUX" == yes ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 9 ))
    [[ "$HAVE_TMUX" == yes && "$IN_PANE" == yes ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 4 ))
    # + the `env -u TMUX` self-run (#1577): only a run that HAS a `$TMUX` to
    # remove spawns it, and the spawned run does not spawn another.
    [[ "$HAVE_TMUX" == yes && "$IN_PANE" == yes && -z "${_TSS_NESTED:-}" ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 3 ))
    assert_eq "assertion TOTAL matches the EXPECTED total (tmux=$HAVE_TMUX pane=$IN_PANE)" \
              "$(( PASS + FAIL ))" "$EXPECTED_ASSERTIONS"
    th_summary_and_exit
}

if [[ "$HAVE_TMUX" != yes ]]; then _th_count_guard; fi

# A SHORT work dir: a tmux socket path holds 107 bytes (sun_path is 108 with
# the NUL), and the session scratchpad is over that before any suffix (#991).
WORK=$(mktemp -d /tmp/nxtss-XXXXXX) || th_abort "cannot allocate a short work dir"
SOCK="$WORK/s"
TDIR="$WORK/t"
# THE PRECONDITION, CALLED rather than assumed (#991, the §8 wiring ratchet in
# test-tmux-socket-ceiling.sh): a short $WORK is a belief about the path, and a
# socket path the kernel truncates is a SILENT mis-address, the very class this
# suite exists to pin. The TMUX_TMPDIR server's socket, $TDIR/tmux-<uid>/default,
# is the LONGER of the two; the -S socket $WORK/s is strictly shorter in the
# same $WORK, so this one measurement bounds both.
th_require_tmux_socket default "$TDIR"
# `${TMUX:-}`, NOT `${TMUX%%,*}` (your-org/nexus-code#1577). Under `set -u` the
# bare form ABORTED this suite — `TMUX: unbound variable`, rc 1 after ~0.25 s,
# before any positive control ran — in exactly the environment the SKIP a few
# lines up says it supports: CI has no `$TMUX`, and neither does a band launched
# `env -u TMUX`. The suite announced "the remedies still ran" and then died.
#
# With no board there is nothing to collide with, so BOARD becomes a SENTINEL
# that no socket path can equal, rather than the empty string: an EMPTY `$got`
# from a failed tmux call would otherwise compare EQUAL to an empty BOARD, and
# the isolation rows below would then be decided by a failure, not by isolation.
BOARD="${TMUX:-}"; BOARD="${BOARD%%,*}"
[[ -n "$BOARD" ]] || BOARD='<no-board: $TMUX is unset>'

_alive() { env -u TMUX tmux -S "$SOCK" has-session -t p1 >/dev/null 2>&1 && echo yes || echo no; }
_cleanup() {
    # ISOLATION ASSERT, before any teardown: both sockets must be under $WORK.
    case "$SOCK" in "$WORK"/*) env -u TMUX tmux -S "$SOCK" kill-server >/dev/null 2>&1 || true ;; esac
    # By its SOCKET, -S "$TSOCK" — the path the dir-scoped server itself reported
    # and the case guard just proved is under $WORK. `env -u TMUX TMUX_TMPDIR=`
    # was isolated but broke the tmux lint's rule-1 bright line (kill-server
    # carries -L/-S on the same command), which the lint could not see inside a
    # case arm until your-org/nexus-code#1652.
    if [[ -n "${TSOCK:-}" ]]; then
        case "$TSOCK" in "$WORK"/*) env -u TMUX tmux -S "$TSOCK" kill-server >/dev/null 2>&1 || true ;; esac
    fi
    rm -rf "$WORK"
}
trap _cleanup EXIT

mkdir -p "$TDIR"
env -u TMUX tmux -S "$SOCK" new-session -d -s p1 'sleep 600' 2>/dev/null \
    || th_abort "could not start the -S private server at $SOCK"
env -u TMUX TMUX_TMPDIR="$TDIR" tmux new-session -d -s p2 'sleep 600' 2>/dev/null \
    || th_abort "could not start the TMUX_TMPDIR private server under $TDIR"
TSOCK=$(env -u TMUX TMUX_TMPDIR="$TDIR" tmux display-message -p '#{socket_path}' 2>/dev/null)

echo
echo '=== CONTROL B: the TMUX_TMPDIR server EXISTS and is addressable ==='
assert_contains "the dir-scoped server reports a socket UNDER the dir we gave it (control B)" \
                "${TSOCK:-<none>}" "$TDIR"
assert_eq "…and its session is there, so a wrong answer below is a MISDIRECTION, not an absence" \
          "$(env -u TMUX TMUX_TMPDIR="$TDIR" tmux has-session -t p2 >/dev/null 2>&1 && echo yes || echo no)" "yes"
[[ -n "$TSOCK" && "$TSOCK" != "$BOARD" ]] || th_abort "the dir-scoped socket is the BOARD ($TSOCK) — aborting before anything is torn down"
[[ "$SOCK" != "$BOARD" ]] || th_abort "the -S socket is the BOARD — aborting"

# ── THE FORMS ARE EXECUTED, NOT RETYPED (your-org/nexus-code#1553 skeptic F6) ──
# An earlier revision extracted the three forms, SHAPE-checked them, and then
# ran hand-typed equivalents. That is a suite which cannot see the block saying
# the wrong thing: the skeptic's M8 rewrote remedy 2's TMUX_TMPDIR="$dir" to
# TMUX_TMPDIR="$sock" — a socket path where a DIRECTORY is meant, precisely the
# confusion this entry exists to prevent — and the suite stayed 21/21 green.
#
# So each form is now run VERBATIM. `sock` and `dir` are the fixtures the forms
# already name, and `<cmd>` is substituted with a socket-reporting read, so the
# text in CLAUDE.md is the text that executes and its ANSWER is the assertion.
# P3 below is the standing proof that this is not ceremony.
# The replacement lives in a VARIABLE, not inline: `#{socket_path}` carries a
# `}` that would close a `${var//pat/repl}` expansion early, and the symptom is
# an empty answer rather than a syntax error — the silent-zero shape, inside the
# fix for a suite that could not see a wrong block. Measured: inline gave '' for
# every form while the servers were up and addressable.
_RDCMD="display-message -p '#{socket_path}'"
_subst() { printf '%s' "${1//<cmd>/$_RDCMD}"; }
_run_form() {   # $1 = an extracted form; echoes the socket it actually addressed
    eval "$(_subst "$1")" 2>/dev/null
}
sock="$SOCK"; dir="$TDIR"      # the names the documented forms use

echo
echo '=== REMEDY 1, EXECUTED: an explicit -S always wins, even with $TMUX set ==='
got=$(_run_form "$FORM_S")
assert_eq "the EXTRACTED \`tmux -S \$sock\` form addresses the socket it names" "$got" "$SOCK"
assert_eq "…and it is the private server, not the ambient one" \
          "$( [[ "$got" == "$BOARD" ]] && echo board || echo private )" "private"

echo
echo '=== REMEDY 2, EXECUTED: with $TMUX removed, TMUX_TMPDIR is honoured ==='
got=$(_run_form "$FORM_ENV")
assert_eq "the EXTRACTED \`env -u TMUX TMUX_TMPDIR=\$dir tmux\` form addresses the dir's socket" "$got" "$TSOCK"
assert_eq "…which is not the ambient one" \
          "$( [[ "$got" == "$BOARD" ]] && echo board || echo private )" "private"
assert_eq "the private -S server is still alive after both remedies" "$(_alive)" "yes"

echo
echo '=== P3: the EXECUTION is load-bearing — the skeptic'"'"'s M8 mutation must RED ==='
# M8: remedy 2 with "$dir" rewritten to "$sock" — a socket path where a
# directory is meant. Shape-checking cannot see it; executing it must.
_m8="${FORM_ENV//\$dir/\$sock}"
assert_eq "P3 CONTROL: the M8 mutation really did change the form" \
          "$( [[ "$_m8" != "$FORM_ENV" ]] && echo mutated || echo UNCHANGED )" mutated
assert_eq "P3: the M8-mutated remedy 2 NO LONGER reports the dir's socket (so a wrong block REDS)" \
          "$( [[ "$(_run_form "$_m8")" == "$TSOCK" ]] && echo MISSED || echo detected )" detected

if [[ "$IN_PANE" == yes ]]; then
echo
echo '=== THE DEFECT, EXECUTED: TMUX_TMPDIR alone, in a pane, answers about the AMBIENT server ==='
    err="$WORK/wrong.err"
    got=$(eval "$(_subst "$FORM_WRONG")" 2>"$err"); rc=$?
    assert_eq "the EXTRACTED TMUX_TMPDIR-only form exits 0 — it does not complain" "$rc" "0"
    assert_eq "…its stderr is EMPTY (control C)" "$(wc -c < "$err" | tr -d ' ')" "0"
    assert_eq "…and it addressed the AMBIENT socket, NOT the dir it was given" "$got" "$BOARD"
    assert_eq "…so the dir-scoped server it was aimed at was never consulted" \
              "$( [[ "$got" == "$TSOCK" ]] && echo consulted || echo bypassed )" "bypassed"
fi

# THE POSITIVE CONTROL FOR #1577. Every run anybody WATCHES happens inside a
# pane, where `$TMUX` is set and the unguarded expansion was harmless — which is
# how an abort on the first tmux-less host survived review. So a pane run now
# re-runs this suite with `$TMUX` removed and requires it to reach its FOOTER.
# Asserted on the footer and the count-guard row, not on rc alone: `set -u`
# kills the script mid-way, and a suite killed mid-way has asserted nothing.
if [[ "$IN_PANE" == yes && -z "${_TSS_NESTED:-}" ]]; then
    echo
    echo '=== #1577: this suite reaches its footer with $TMUX UNSET (CI, and any `env -u TMUX` band) ==='
    _nested=$(env -u TMUX _TSS_NESTED=1 bash "${BASH_SOURCE[0]}" 2>&1); _nested_rc=$?
    assert_eq       "the \$TMUX-less run exits 0 — not \`TMUX: unbound variable\`" "$_nested_rc" "0"
    assert_contains "…and reached its footer"                                       "$_nested" "ALL TESTS PASSED"
    assert_contains "…having taken the no-pane count (the DEFECT arm skipped, the remedies run)" \
                    "$_nested" "(tmux=yes pane=no)"
    (( _nested_rc == 0 )) || printf '%s\n' "$_nested" | sed -n '1,40s/^/    nested: /p' >&2
fi

echo
_th_count_guard
