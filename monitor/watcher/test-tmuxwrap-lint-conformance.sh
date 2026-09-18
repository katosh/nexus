#!/usr/bin/env bash
# Conformance: monitor/tmuxwrap/tmux (runtime shim) vs
# monitor/cc-harness/_tmux_kill_scan.awk (corpus lint) — your-org/nexus-code#892.
#
# WHY THIS FILE EXISTS. Two validators disagreeing about the same hazard is the
# defect class this repo spent a week closing (`#836`, `#855`), and a shim that
# drifts from the lint is exactly that shape. The obvious remedy — have the shim
# CALL the awk — does not fit: the awk's hard problem is DATA-VS-CODE over source
# LINES (is `assert_contains "… tmux kill-window …"` a call or a string?), and
# that problem is absent at the shim, which receives an already-parsed argv and
# IS the invocation. Feeding a reconstructed command line back through the awk
# would reintroduce a quoting/whitespace round-trip whose failure mode is a FALSE
# REFUSAL — i.e. wedging the board, the one outcome the shim's header forbids.
#
# So the two share a POLICY, not a parser, and this file is what holds them to
# it: the same command forms are put to BOTH, and their verdicts are compared.
# A behavioural pin is also strictly stronger than textual reuse — it would
# still fail if someone edited one side's regexes to mean something new.
#
# THE CONTRACT, in two directions:
#
#   (1) SUPERSET. On the BOARD socket, every form the lint flags, the shim
#       refuses. The shim may be stricter (it also knows runtime state); it may
#       never be laxer.
#
#   (2) THE DIVERGENCES ARE ENUMERATED. Where the two intentionally disagree it
#       is always the same axis — an ISOLATED socket — and each case is asserted
#       individually below with its reason, so a divergence can never arrive by
#       accident. The lint governs the CORPUS, where an author should be explicit
#       even about a private server; the shim governs RUNTIME BLAST RADIUS, where
#       a private server ending is nobody's problem and refusing it would break
#       cc-harness.
#
# Run: bash monitor/watcher/test-tmuxwrap-lint-conformance.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/.." && pwd)
SHIM_DIR="$REPO_ROOT/tmuxwrap"
AWK_SCAN="$REPO_ROOT/cc-harness/_tmux_kill_scan.awk"

[[ -x "$SHIM_DIR/tmux" ]] || { echo "FAIL: $SHIM_DIR/tmux missing" >&2; echo FAILED; exit 1; }
[[ -r "$AWK_SCAN"      ]] || { echo "FAIL: $AWK_SCAN missing"      >&2; echo FAILED; exit 1; }

# The shared harness supplies assert_eq / th_skip / th_summary_and_exit and,
# critically, a SUBSHELL-DURABLE ledger: a FAIL raised inside `( )` mutates a
# global that dies with the subshell, and a MISSING assert_* helper exits 127
# and is counted by nothing. Both would show up here as a quieter green.
. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-tmux-conf-XXXXXX)
JAIL="$WORK/socketjail"; mkdir -p "$JAIL"
# HERMETIC (your-org/nexus-code#1336): the tmux wrapper's audit logs and the
# notify wrapper's decisions ledger resolve NEXUS_STATE_DIR / NEXUS_NOTIFY_STATE_DIR
# before NEXUS_ROOT; without these pins the decoy band names this suite as a
# writer of tmux-refused.log / tmux-unwrapped.log / notify-decisions.jsonl into
# the INHERITED root.
export NEXUS_STATE_DIR="$WORK/state" NEXUS_NOTIFY_STATE_DIR="$WORK/notify-state"
mkdir -p "$NEXUS_STATE_DIR" "$NEXUS_NOTIFY_STATE_DIR"
trap 'rm -rf "$WORK"' EXIT

# Stub standing in for the real tmux — see test-tmux-shim.sh for the rationale.
STUB_DIR="$WORK/stub"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
last="${!#}"
case "$last" in
    'NXSOCK:#{socket_path}')  printf 'NXSOCK:%s\n' "${STUB_SOCK:-/tmp/board/default}"; exit 0 ;;
    '#{session_windows}|#{window_panes}')
        printf '%s|%s\n' "${STUB_WINDOWS:-9}" "${STUB_PANES:-9}"; exit 0 ;;
esac
# The alias table. The shim now resolves any UNRECOGNISED command word, so this
# query reaches the stub on every sequence containing a non-kill verb. Without
# an arm here it fell through to the passthrough recorder and polluted $TRACE —
# making a correctly-REFUSED command report RUN. A measurement artifact that
# looks exactly like a regression, in the file whose whole job is comparing two
# verdicts.
if [[ "$*" == *"show -s command-alias"* ]]; then
    printf '%s\n' "${STUB_ALIASES:-}"
    exit 0
fi
for a in "$@"; do [[ "$a" == list-sessions ]] && {
    n="${STUB_SESSIONS:-9}"; i=0
    while (( i < n )); do echo "s$i:"; i=$(( i + 1 )); done; exit 0; }; done
printf '%s\n' "$*" >> "$STUB_TRACE"
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

BOARD=/tmp/board/default
TRACE="$WORK/trace"

# --- the two oracles --------------------------------------------------------

# What does the LINT say about this command line? Prints the rule names it
# emits, space-separated, or "CLEAN".
lint_verdict() {   # <command-line>
    local r
    r=$(printf '%s\n' "$1" | awk -f "$AWK_SCAN" 2>/dev/null | cut -d: -f2 | sort -u | tr '\n' ' ')
    r="${r% }"
    printf '%s' "${r:-CLEAN}"
}

# What does the SHIM do with the same argv? "REFUSE" or "RUN".
# $2.. are the argv AFTER the `tmux` word; STUB_SOCK decides which socket the
# command resolves to, which is the axis the divergences live on.
shim_verdict() {   # <stub-socket> <argv...>
    local sock="$1"; shift
    : > "$TRACE"
    env -u TMUX -u NEXUS_TMUX_SOCKET TMUX_TMPDIR="$JAIL" \
        PATH="$SHIM_DIR:$STUB_DIR:/usr/bin:/bin" \
        STUB_TRACE="$TRACE" STUB_SOCK="$sock" NEXUS_TMUX_SOCKET="$BOARD" \
        STUB_SESSIONS="${CONF_SESSIONS:-9}" STUB_WINDOWS="${CONF_WINDOWS:-9}" \
        STUB_PANES="${CONF_PANES:-9}" \
        "$SHIM_DIR/tmux" "$@" >/dev/null 2>&1
    [[ -s "$TRACE" ]] && printf 'RUN' || printf 'REFUSE'
}

echo "=== (1) SUPERSET: on the BOARD socket, everything the lint flags is refused ==="
# The table lives in a .txt fixture, NOT inline: its rows are literal tmux
# command lines, and a shell file carrying them is read by
# lint-no-tmux-server-kill.sh as a corpus of real calls. Same reason the lint
# keeps its own incident fixture out of tree.
ROWS_FIXTURE="$REPO_ROOT/cc-harness/fixtures/tmuxwrap-conformance-rows.txt"
[[ -r "$ROWS_FIXTURE" ]] || { echo "FAIL: missing $ROWS_FIXTURE" >&2; echo FAILED; exit 1; }

# Non-vacuity floor: an empty or unreadable table would make every assertion
# below silently disappear and the suite would still print ALL TESTS PASSED —
# the absence-shaped-assertion trap. Assert the row count positively.
_rows=$(grep -cE '^[^#].*\|.*\|' "$ROWS_FIXTURE")
assert_eq "the conformance table is non-vacuous" "$(( _rows >= 11 ? 1 : 0 ))" 1

while IFS='|' read -r label line argv; do
    [[ -n "${label// }" ]] || continue
    [[ "$label" == \#* ]] && continue
    lv=$(lint_verdict "$line")
    ld=dirty; [[ "$lv" == CLEAN ]] && ld=CLEAN
    # shellcheck disable=SC2086
    sv=$(shim_verdict "$BOARD" $argv)
    # Both halves are asserted in ONE comparison, so a lint that stopped
    # flagging the form reds here too — the precondition cannot go silently
    # vacuous and leave the shim half asserting nothing.
    assert_eq "lint flags [$lv] and shim refuses: $label" \
        "lint=$ld shim=$sv" "lint=dirty shim=REFUSE"
done < "$ROWS_FIXTURE"

echo "=== (1b) the lint's positive controls stay runnable on a healthy board ==="
# These are CLEAN to the lint. On a board with room to spare they must also RUN,
# or the shim is stricter than the corpus rule in the direction that wedges.
CONF_SESSIONS=1 CONF_WINDOWS=12 CONF_PANES=1
lv=$(lint_verdict 'tmux -L iso kill-window -t "live:$idx"')
assert_eq "lint: targeted kill-window on a pinned socket is CLEAN" "$lv" CLEAN
sv=$(CONF_SESSIONS=1 CONF_WINDOWS=12 shim_verdict "$BOARD" kill-window -t 0:7)
assert_eq "shim: the same shape on a healthy board RUNS" "$sv" RUN

echo "=== (2) THE ENUMERATED DIVERGENCES — isolated socket, and only that ==="
PRIV=/tmp/tmux-1/iso

# The lint bans an untargeted kill even on a pinned socket, because in the
# CORPUS an author should say which window they mean. At RUNTIME the blast
# radius is a private server, which is nobody's problem — and refusing it would
# break cc-harness and the tmux-touching suites, which do exactly this.
lv=$(lint_verdict 'tmux -L iso kill-window')
sv=$(shim_verdict "$PRIV" -L iso kill-window)
assert_eq "DIVERGENCE 1 — lint flags untargeted-on-pinned; shim allows it off-board" \
    "lint=$lv shim=$sv" "lint=rule3-untargeted-kill shim=RUN"

# The lint's BRIGHT LINE: kill-server demands -L/-S even when `env -u TMUX` has
# genuinely isolated it, because that form's correctness rests on two things
# being right at once. The shim asks tmux where the socket actually resolved, so
# it can see that this one is not the board.
lv=$(lint_verdict 'env -u TMUX TMUX_TMPDIR="$T" tmux kill-server')
sv=$(shim_verdict "$PRIV" kill-server)
assert_eq "DIVERGENCE 2 — lint's kill-server bright line; shim resolves the socket instead" \
    "lint=$lv shim=$sv" "lint=rule1-killserver-unscoped shim=RUN"

# And the axis is ONLY the socket: the identical argv aimed at the board flips.
sv=$(shim_verdict "$BOARD" kill-server)
assert_eq "  …the same argv on the BOARD socket is refused (the divergence is the socket, nothing else)" \
    "$sv" REFUSE
sv=$(shim_verdict "$BOARD" -L iso kill-window)
assert_eq "  …and untargeted kill-window resolving to the board is refused too" "$sv" REFUSE

echo "=== (3) both agree that a properly-scoped, targeted kill is fine ==="
lv=$(lint_verdict 'tmux -L iso kill-window -t a:1')
sv=$(CONF_SESSIONS=1 CONF_WINDOWS=1 shim_verdict "$PRIV" -L iso kill-window -t a:1)
assert_eq "lint CLEAN and shim RUN on a pinned, targeted kill" "lint=$lv shim=$sv" "lint=CLEAN shim=RUN"

# Pinned assertion total. A count that silently shrinks is a suite quietly
# covering less than it claims, which the summary-honesty manifest exists to
# catch; this is that check at the suite's own boundary.
EXPECTED=19
if (( PASS + FAIL != EXPECTED )); then
    echo "ASSERTION COUNT MISMATCH — $(( PASS + FAIL )) ran, $EXPECTED expected." >&2
    FAIL=$(( FAIL + 1 ))
fi
th_summary_and_exit
