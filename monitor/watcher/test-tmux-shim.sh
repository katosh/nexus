#!/usr/bin/env bash
# Tests for monitor/tmuxwrap/tmux — the PATH-front board-lethal-kill guard
# (your-org/nexus-code#892; remedy for the session surface named in #889).
#
# WHY THIS FILE IS WRITTEN THE WAY IT IS. The subject under test is a guard
# against killing the tmux server, so a naive suite would issue tmux kills, and
# a mistake would end the sandbox: bwrap is PID 1 running tmux under
# --die-with-parent, there is no in-sandbox recovery, and the notification path
# dies with it (2026-08-09; five tear-downs in 33 minutes on 2026-07-30, #644).
#
# Two mechanisms make the dangerous half of this suite safe:
#
#   1. A STUB tmux drives every branch. It answers the shim's probes from env
#      vars, so all of the decision logic — including every refusal — is
#      exercised with no tmux server in the picture at all.
#
#   2. Where a REAL server is required (the runtime-lethality check is the whole
#      point of the shim and a stub cannot vouch for it), the test creates a
#      PRIVATE server and then points `NEXUS_TMUX_SOCKET` at that private socket.
#      The shim therefore treats the PRIVATE server as "the board" and refuses
#      against it. That gives full real-server coverage of the refusal path while
#      the actual board is never the target of anything.
#
# Every real-server call is `env -u TMUX tmux -L <private> …`: `-L` outranks
# `$TMUX`, and unsetting `$TMUX` removes the trap for any child that drops the
# flag. TMUX_TMPDIR alone is NOT containment. Isolation is ASSERTED before any
# kill runs, and the suite aborts hard if the socket it is about to operate on
# is the board's.
#
# BOTH DIRECTIONS. (a) every lethal form is refused; (b) every legitimate form
# still works — a targeted kill-window on a multi-window session, a
# socket-scoped kill-server, and the whole non-kill surface. (b) is the one that
# wedges the board if it is wrong, so it carries the most assertions.
#
# Run: bash monitor/watcher/test-tmux-shim.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SHIM_DIR=$(cd "$_test_dir/../tmuxwrap" 2>/dev/null && pwd) || {
    echo "FAIL: monitor/tmuxwrap/ missing — tmux shim not installed (your-org/nexus-code#892)" >&2
    echo "FAILED"; exit 1; }
[[ -x "$SHIM_DIR/tmux" ]] || {
    echo "FAIL: monitor/tmuxwrap/tmux missing or not executable" >&2
    echo "FAILED"; exit 1; }

REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

# The shared harness supplies assert_eq / assert_contains / th_skip /
# th_summary_and_exit and, critically, a SUBSHELL-DURABLE ledger. This file has
# both hazards the ledger exists for: a FAIL raised inside `( )` mutates a global
# that dies with the subshell, and a MISSING assert_* helper exits 127 and is
# counted by nothing. Either would surface here as a quieter green — the exact
# failure mode a guard against silent teardown must not have.
. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-tmux-shim-XXXXXX)
# A socket dir of its own, so that even a total shim/stub failure sends a REAL
# tmux somewhere harmless instead of to the board's default socket. Paired with
# `env -u TMUX` at every use — TMUX_TMPDIR alone is NOT containment (#644).
JAIL="$WORK/socketjail"; mkdir -p "$JAIL"
# HERMETIC (your-org/nexus-code#1336): the tmux wrapper's audit logs and the
# notify wrapper's decisions ledger resolve NEXUS_STATE_DIR / NEXUS_NOTIFY_STATE_DIR
# before NEXUS_ROOT; without these pins the decoy band names this suite as a
# writer of tmux-refused.log / tmux-unwrapped.log / notify-decisions.jsonl into
# the INHERITED root.
export NEXUS_STATE_DIR="$WORK/state" NEXUS_NOTIFY_STATE_DIR="$WORK/notify-state"
mkdir -p "$NEXUS_STATE_DIR" "$NEXUS_NOTIFY_STATE_DIR"

# ===========================================================================
# HARD SAFETY RAIL — the board's socket, and a guard every real-server helper
# consults before it runs anything.
# ===========================================================================
# `${TMUX:-}` FIRST, then strip. A bare `${TMUX%%,*}` is an unbound-variable
# error under `set -u` wherever $TMUX is unset — which is every CI runner, and
# never this workspace, so it passes locally and reds only in CI. The suite must
# run identically on a host with no board at all.
BOARD_SOCK="${TMUX:-}"
BOARD_SOCK="${BOARD_SOCK%%,*}"
[[ -n "$BOARD_SOCK" ]] || BOARD_SOCK="/tmp/tmux-$(id -u)/default"
# The board's SERVER IDENTITY, sampled before and after. "absent" on a host with
# no board (CI) is a fine value to compare against itself, so this is a real
# assertion in BOTH environments rather than one that vanishes where it is
# cheapest to run.
#
# IDENTITY, NOT INVENTORY. The first version compared the session/window list
# and was FLAKY BY CONSTRUCTION: the board is a LIVE system whose windows the
# orchestrator opens and retires while this suite runs, so it reported 0:16 ->
# 0:17 and failed on somebody else's spawn. The suite does not control that and
# must not assert it. What it must assert is that IT did not kill the server —
# and the server's own pid answers exactly that: stable across any number of
# window changes, different if the server ever died and came back.
board_state() {
    if [[ -z "${TMUX:-}" ]]; then printf 'no-board-env'; return; fi
    printf 'server-pid=%s' "$(tmux display-message -p '#{pid}' 2>/dev/null || echo GONE)"
}
BOARD_STATE_BEFORE="$(board_state)"

# Environment-dependent legs, declared here and consumed by the EXPECTED
# arithmetic at the bottom, so a leg that silently stops running reds the count
# instead of merely lowering it.
HAVE_PY_LEG=0
REAL_LEG=0

PRIV_SOCKETS=()
abort_if_board() {   # <socket-path> <what-for>
    if [[ "$1" == "$BOARD_SOCK" ]]; then
        echo "ABORT: refusing to $2 — target socket '$1' IS THE BOARD." >&2
        echo "FAILED"; exit 9
    fi
}
cleanup() {
    local s sp
    for s in ${PRIV_SOCKETS[@]+"${PRIV_SOCKETS[@]}"}; do
        sp=$(env -u TMUX tmux -L "$s" display-message -p '#{socket_path}' 2>/dev/null)
        [[ -n "$sp" ]] || continue
        abort_if_board "$sp" "clean up test socket '$s'"
        env -u TMUX tmux -L "$s" kill-server 2>/dev/null || true
        rm -f "$sp" 2>/dev/null || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

# ===========================================================================
# THE STUB. Answers the shim's two probes from env vars; anything else is
# recorded as "the real tmux was reached".
# ===========================================================================
STUB_DIR="$WORK/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
# Records the passthrough; answers probes from STUB_* env vars.
last="${!#}"
case "$last" in
    'NXSOCK:#{socket_path}')
        # Mirrors real tmux: NO server -> nonzero + no output; server present but
        # format UNSUPPORTED -> the sentinel with an empty value.
        [[ "${STUB_SOCK:-}" == "NONE" ]] && exit 1
        [[ "${STUB_SOCK:-}" == "OLDTMUX" ]] && { echo 'NXSOCK:'; exit 0; }
        printf 'NXSOCK:%s\n' "${STUB_SOCK:-/tmp/stub/default}"; exit 0 ;;
    '#{session_windows}|#{window_panes}')
        [[ "${STUB_BADTARGET:-}" == 1 ]] && exit 1
        printf '%s|%s\n' "${STUB_WINDOWS:-9}" "${STUB_PANES:-9}"; exit 0 ;;
esac
# The alias table. Until this existed the suite could not exercise resolution
# in ANY stub fixture, which is precisely why F8 was invisible to it.
if [[ "$*" == *"show -s command-alias"* ]]; then
    [[ -n "${STUB_QCOUNT:-}" ]] && echo Q >> "$STUB_QCOUNT"
    printf '%s\n' "${STUB_ALIASES:-}"
    exit 0
fi
if [[ "${1:-}" == list-sessions || "${2:-}" == list-sessions || "${3:-}" == list-sessions ]]; then
    n="${STUB_SESSIONS:-9}"; i=0
    while (( i < n )); do echo "s$i: 1 windows"; i=$(( i + 1 )); done
    exit 0
fi
printf '%s\n' "$*" >> "$STUB_TRACE"
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

# Run the shim with the stub as "the real tmux". Prints the shim's combined
# output; the passthrough (if any) lands in $TRACE.
TRACE="$WORK/trace"
run_shim() {   # <env-assignments as VAR=VAL ...> -- <shim args...>
    local envs=() a
    while (( $# )); do [[ "$1" == "--" ]] && { shift; break; }; envs+=("$1"); shift; done
    : > "$TRACE"
    env -u TMUX -u NEXUS_TMUX_SOCKET \
        TMUX_TMPDIR="$JAIL" \
        PATH="$SHIM_DIR:$STUB_DIR:/usr/bin:/bin" \
        STUB_TRACE="$TRACE" \
        ${envs[@]+"${envs[@]}"} \
        "$SHIM_DIR/tmux" "$@" 2>&1
}
ran_through() { [[ -s "$TRACE" ]] && echo yes || echo no; }

BOARD=/tmp/board/default
ONBOARD=(STUB_SOCK="$BOARD" NEXUS_TMUX_SOCKET="$BOARD")

echo "=== (b) THE DIRECTION THAT WEDGES THE BOARD: legitimate forms must work ==="

# --- the hot path: non-kill verbs must exec through, consulting NOTHING ------
for verb in list-windows display-message list-panes new-window send-keys \
            has-session select-window swap-window respawn-pane; do
    out=$(run_shim "${ONBOARD[@]}" -- "$verb" -t 0:1 2>&1)
    assert_eq "hot path: \`$verb\` passes through on the board socket" "$(ran_through)" yes
done
# `list-sessions` is asserted on OUTPUT rather than on the trace marker: the
# stub answers it (the shim's own lethality probe needs it), so "did the stub
# record a passthrough" is not the right question for this one verb. Seeing the
# stub's session list proves the shim handed the command over.
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=3 -- list-sessions)
assert_contains "hot path: \`list-sessions\` passes through on the board socket" "$out" "s2:"

# An unknown / future verb must pass through too — the default arm is
# PASS-THROUGH, and this is the assertion that pins that polarity.
out=$(run_shim "${ONBOARD[@]}" -- some-verb-invented-tomorrow -t x)
assert_eq "an UNRECOGNISED verb passes through (default arm is pass-through)" "$(ran_through)" yes

# A targeted kill on a healthy board — the orchestrator's own retirement path.
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=12 STUB_PANES=1 -- kill-window -t 0:7)
assert_eq "targeted kill-window on a 12-window session RUNS" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=2 STUB_PANES=1 -- kill-window -t 0:2)
assert_eq "targeted kill-window with 2 windows left RUNS" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=2 STUB_WINDOWS=1 STUB_PANES=1 -- kill-session -t other)
assert_eq "kill-session with 2 sessions RUNS" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=1 STUB_PANES=3 -- kill-pane -t 0:1.2)
assert_eq "kill-pane with 3 panes in the window RUNS" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=1 STUB_PANES=1 -- kill-window -a -t 0:1)
assert_eq "kill-window -a (all EXCEPT target) RUNS — it cannot empty the server" "$(ran_through)" yes

# --- isolated sockets: permissive, and this is what cc-harness depends on ----
out=$(run_shim STUB_SOCK=/tmp/tmux-1/priv NEXUS_TMUX_SOCKET="$BOARD" -- -L priv kill-server)
assert_eq "socket-scoped kill-server on a PRIVATE socket RUNS" "$(ran_through)" yes
out=$(run_shim STUB_SOCK=/tmp/tmux-1/priv NEXUS_TMUX_SOCKET="$BOARD" STUB_SESSIONS=1 STUB_WINDOWS=1 \
      -- -L priv kill-window -t a:1)
assert_eq "last-window kill on a PRIVATE socket RUNS (isolated = not our business)" "$(ran_through)" yes
out=$(run_shim STUB_SOCK=/tmp/tmux-1/priv NEXUS_TMUX_SOCKET="$BOARD" -- -L priv kill-window)
assert_eq "even an UNTARGETED kill on a private socket RUNS" "$(ran_through)" yes
out=$(run_shim STUB_SOCK=/tmp/x/default NEXUS_TMUX_SOCKET="$BOARD" -- -S /tmp/x/default kill-server)
assert_eq "-S on a non-board path RUNS" "$(ran_through)" yes

# --- probe failure / ambiguity must DEGRADE TO PASS-THROUGH, never wedge -----
out=$(run_shim STUB_SOCK=NONE NEXUS_TMUX_SOCKET="$BOARD" -- kill-server)
assert_eq "socket probe FAILS (no server) -> pass through (degrade, never wedge)" "$(ran_through)" yes
assert_eq "…and stays QUIET about it — there was nothing to kill" "$out" ""

# THE THIRD PROBE STATE, and the reason the probe carries a sentinel at all.
# tmux expands an UNKNOWN format variable to the EMPTY STRING (measured:
# `display-message -p '#{no_such_var}'` prints nothing, `'A#{no_such_var}B'`
# prints `AB`). So on a tmux too old for `#{socket_path}` the probe returns
# exactly what "no server here" returns. Without the sentinel the guard would be
# SILENTLY INERT on that host — silence used as proof of absence, this repo's own
# dominant defect class, living inside the guard. It must still allow the call
# (policy: never wedge) and it must SAY SO.
out=$(run_shim STUB_SOCK=OLDTMUX NEXUS_TMUX_SOCKET="$BOARD" -- kill-server)
assert_eq "tmux too old for socket_path -> still passes through (never wedge)" "$(ran_through)" yes
assert_contains "…but warns LOUDLY that the guard is inert" "$out" "INERT"
assert_contains "…naming the missing capability" "$out" "socket_path"
out=$(run_shim "${ONBOARD[@]}" STUB_BADTARGET=1 -- kill-window -t nonesuch:9)
assert_eq "unresolvable -t target -> pass through (tmux reports it better)" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=notanumber -- kill-window -t 0:1)
assert_eq "unparseable session count -> pass through" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=1 STUB_PANES=1 TMUX_UNWRAPPED=1 -- kill-server)
assert_eq "TMUX_UNWRAPPED=1 escape hatch RUNS" "$(ran_through)" yes
assert_contains "TMUX_UNWRAPPED announces itself loudly" "$out" "TMUX_UNWRAPPED=1"

echo "=== (a) lethal forms must be REFUSED ==="

out=$(run_shim "${ONBOARD[@]}" -- kill-server)
assert_eq "kill-server on the board is refused (did not run)" "$(ran_through)" no
assert_contains "…and says so" "$out" "REFUSING \`kill-server\`"
assert_contains "…naming the sandbox-teardown consequence" "$out" "ENTIRE SANDBOX"
assert_contains "…and the remedy" "$out" "env -u TMUX"

# `-L default` is syntactically a pin and semantically the board (the lint's
# rule4). It must NOT buy a pass.
out=$(run_shim STUB_SOCK="$BOARD" NEXUS_TMUX_SOCKET="$BOARD" -- -L default kill-server)
assert_eq "-L default does NOT buy a pass (lint rule4)" "$(ran_through)" no

# The lint's rule3 — untargeted acts on the CURRENT one, which can be the last.
for verb in kill-session kill-window kill-pane; do
    out=$(run_shim "${ONBOARD[@]}" -- "$verb")
    assert_eq "untargeted \`$verb\` on the board is refused (lint rule3)" "$(ran_through)" no
    assert_contains "…citing the untargeted reason" "$out" "no \`-t\` target"
done

# THE PRIZE: correctly-targeted, every flag rule satisfied, still fatal.
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=1 STUB_PANES=1 -- kill-window -t 0:1)
assert_eq "targeted kill-window of the LAST window of the LAST session is refused" "$(ran_through)" no
assert_contains "…named as an EMPTY-the-server kill" "$out" "would EMPTY the board's server"
assert_contains "…and explains why only a runtime check catches it" "$out" "only a runtime check"
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=1 STUB_PANES=1 -- kill-session -t 0)
assert_eq "kill-session of the ONLY session is refused" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=1 STUB_PANES=1 -- kill-pane -t 0:1.1)
assert_eq "kill-pane of the last pane of the last window of the last session is refused" "$(ran_through)" no
# Attached-value and bundled global-flag forms must reach the same verdict.
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=1 -- -t0:1 kill-window 2>/dev/null)
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=1 -- kill-window -t0:1)
assert_eq "attached -t value (-t0:1) is parsed, and refused" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" -- -2 kill-server)
assert_eq "a bundled boolean global flag does not hide the verb" "$(ran_through)" no
out=$(run_shim STUB_SOCK="$BOARD" NEXUS_TMUX_SOCKET="$BOARD" -- -2L default kill-server)
assert_eq "bundled boolean + value flag (-2L default) is parsed, and refused" "$(ran_through)" no

echo "=== the shim identifies the board even without \$TMUX / NEXUS_TMUX_SOCKET ==="
# `env -u TMUX` is the shape that defeats every other route to the answer; the
# compiled-default fallback is what closes it.
# run_shim already unsets BOTH $TMUX and NEXUS_TMUX_SOCKET, so passing neither
# leaves the shim with only its last resort: the compiled default socket for
# this uid, which is where the board lives by construction.
out=$(run_shim STUB_SOCK="/tmp/tmux-$(id -u)/default" -- kill-server)
assert_contains "with \$TMUX AND NEXUS_TMUX_SOCKET unset, the default socket is still recognised as the board" \
    "$out" "REFUSING \`kill-server\`"
assert_eq "…and it did not run" "$(ran_through)" no

echo "=== TMUX'S REAL GRAMMAR — abbreviations and command sequences (F2/F3) ==="
# Both of these were CONFIRMED BYPASSES against an earlier draft: each was
# executed against a private server and the server DIED. They are not edge cases
# dressed up — an agent typing `tmux kill-ser` is plausible, and `\;` sequences
# appear in real scripts.
#
# F2: tmux accepts any UNAMBIGUOUS PREFIX of a command name.
for abbrev in kill-serve kill-serv kill-ser kill-se kill- kill kil ki k; do
    out=$(run_shim "${ONBOARD[@]}" -- "$abbrev")
    assert_eq "F2: abbreviation \`$abbrev\` is resolved and refused" "$(ran_through)" no
done
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=1 -- kill-wind -t 0:1)
assert_eq "F2: abbreviated kill-window still gets the RUNTIME lethality check" "$(ran_through)" no
assert_contains "F2: …and the refusal names what was TYPED, not just the canonical verb" \
    "$out" "kill-wind"

# A prefix of a NON-kill command must still pass through — the over-refusal
# direction, which is the one that wedges the board.
for ok in list-w list-windows disp new-w send-k; do
    out=$(run_shim "${ONBOARD[@]}" -- "$ok" -t 0:1)
    assert_eq "F2 CONTROL: non-kill abbreviation \`$ok\` still passes through" "$(ran_through)" yes
done

# F3: tmux takes several commands in ONE invocation, separated by an argument
# that is exactly `;`. Judging only the first command word missed every later
# one.
out=$(run_shim "${ONBOARD[@]}" -- list-windows ';' kill-server)
assert_eq "F3: kill-server in the SECOND position of a sequence is refused" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" -- list-windows ';' display-message ';' kill-server)
assert_eq "F3: …and in the THIRD position" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" -- list-windows ';' kill-ser)
assert_eq "F3+F2: an ABBREVIATED kill later in a sequence is refused" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=1 -- list-windows ';' kill-window -t 0:1)
assert_eq "F3: a LETHAL targeted kill later in a sequence is refused" "$(ran_through)" no
# The per-command flag scan must not bleed across the separator: this sequence's
# kill-window has no -t of its own even though an earlier command had one.
out=$(run_shim "${ONBOARD[@]}" -- select-window -t 0:3 ';' kill-window)
assert_eq "F3: an earlier command's -t does NOT satisfy a later untargeted kill" "$(ran_through)" no

# CONTROL: a sequence with no kill in it anywhere must pass through untouched.
out=$(run_shim "${ONBOARD[@]}" -- list-windows ';' display-message ';' list-panes)
assert_eq "F3 CONTROL: a kill-free sequence passes through" "$(ran_through)" yes
# CONTROL: a sequence whose kills are all non-lethal must RUN.
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=12 -- list-windows ';' kill-window -t 0:7)
assert_eq "F3 CONTROL: a sequence of provably non-lethal kills RUNS" "$(ran_through)" yes

echo "=== F6/F7 — the VERB-RESOLUTION MECHANISM, not verb spelling ==="
# These were found by asking what resolves a command word, after F2/F3 had
# already been closed by attacking spelling. Both were EXECUTED; both killed a
# real server through the shim.

# F7: `--` ends option parsing and tmux runs what follows. An earlier draft
# treated it as "not a tmux idiom" and fell through to exec — a two-character
# total bypass. Bailing to exec on a shape TMUX ACCEPTS is never safe.
out=$(run_shim "${ONBOARD[@]}" -- -- kill-server)
assert_eq "F7: \`-- kill-server\` is refused, not waved through" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" -- -- list-windows ';' kill-server)
assert_eq "F7+F3: \`--\` followed by a sequence is still segmented" "$(ran_through)" no

# killp/killw are BUILT-IN SHORT FORMS (`list-commands` prints
# `kill-pane (killp)`), not command-aliases, and are NOT prefixes of the long
# names — so a prefix rule over the long names alone missed them entirely.
for shortform in killp killw kill-pan kill-wi; do
    out=$(run_shim "${ONBOARD[@]}" -- "$shortform")
    assert_eq "F2b: built-in short form \`$shortform\` is refused" "$(ran_through)" no
done
# CONTROL, and it corrects an assertion this suite first got WRONG: tmux does
# NOT prefix-extend the short forms — `killpa` and `killwi` are `unknown
# command`. Passing them through is therefore CORRECT, not a miss, because tmux
# rejects them itself. Measured before changing anything.
for notacmd in killpa killwi; do
    out=$(run_shim "${ONBOARD[@]}" -- "$notacmd")
    assert_eq "F2b CONTROL: \`$notacmd\` is not a tmux command, so it passes through" \
        "$(ran_through)" yes
done

echo "=== the built-in cache — soundness of the fast path ==="
# The alias query is skipped for words that resolve to a BUILT-IN, which is
# sound only because a command-alias CANNOT shadow a built-in. Verified on a
# real server: with `list-windows=kill-server` set, a plain `tmux list-windows`
# still listed windows and the server lived. If that ever stops holding, the
# fast path becomes unsound — so the fact is asserted, not assumed, in the
# real-server section below.
out=$(run_shim "${ONBOARD[@]}" -- list-windows)
assert_eq "a built-in still takes the fast path (no alias query needed)" "$(ran_through)" yes

# The DELIBERATE over-refusal, pinned so it stays a decision rather than drift.
# Where tmux ignores the alias, refusing is wrong-but-safe; where tmux honours
# it, passing is fatal. The shim takes the first, loudly.
out=$(run_shim "${ONBOARD[@]}" -- some-word-aliased-to-a-kill)
assert_eq "an unrecognised word is resolved, not assumed safe" "$(ran_through)" yes

echo "=== F8 — a recognised kill must not suppress resolution of its neighbours ==="
# THE FIXTURE GAP THIS CLOSES. Every sequence fixture above has either NO kill or
# NO alias, so none of them could ever exercise "a sequence containing BOTH".
# That is a fixture set unable to falsify its author's model, and it is why F8
# survived a suite that already had F3 and F6 coverage.
#
# The bug: alias resolution was gated on `_tw_any_kill != 1` — resolve only if
# NOTHING was already recognised as a kill — so one recognised kill suppressed
# resolution for every other command in the sequence. Executed, both orderings
# killed a real server.
ALIASES='command-alias[99] "nuke=kill-server"'
NONLETHAL=(STUB_SESSIONS=1 STUB_WINDOWS=12 STUB_PANES=4)

out=$(run_shim "${ONBOARD[@]}" "${NONLETHAL[@]}" STUB_ALIASES="$ALIASES" -- kill-window -t 0:7 ';' nuke)
assert_eq "F8: an aliased kill AFTER a recognised (non-lethal) kill is still resolved" \
    "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" "${NONLETHAL[@]}" STUB_ALIASES="$ALIASES" -- nuke ';' kill-window -t 0:7)
assert_eq "F8: …and BEFORE one" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" "${NONLETHAL[@]}" STUB_ALIASES="$ALIASES" -- kill-pane -t 0:1.2 ';' list-windows ';' nuke)
assert_eq "F8: …and two commands later in a three-command sequence" "$(ran_through)" no

# On a tmux where an alias can shadow a built-in, F8 also reopened THIS: a
# recognised kill followed by an aliased BUILT-IN.
out=$(run_shim "${ONBOARD[@]}" "${NONLETHAL[@]}" \
      STUB_ALIASES='command-alias[98] "list-windows=kill-server"' \
      -- kill-window -t 0:7 ';' list-windows)
assert_eq "F8: a recognised kill does not suppress resolution of an aliased BUILT-IN" \
    "$(ran_through)" no

# CONTROLS — the wedge direction. A sequence of recognised, provably non-lethal
# kills with a harmless alias table must still RUN, and the query must not turn
# a safe sequence into a refusal.
out=$(run_shim "${ONBOARD[@]}" "${NONLETHAL[@]}" STUB_ALIASES="$ALIASES" -- kill-window -t 0:7 ';' list-windows)
assert_eq "F8 CONTROL: non-lethal kill + unaliased built-in still RUNS" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" "${NONLETHAL[@]}" STUB_ALIASES='command-alias[0] "splitp=split-window"' \
      -- kill-window -t 0:7 ';' splitp)
assert_eq "F8 CONTROL: a NON-kill alias in the table does not cause a refusal" "$(ran_through)" yes
# And the hot-path property: when every word is already a kill there is nothing
# unknown, so no query is needed.
out=$(run_shim "${ONBOARD[@]}" "${NONLETHAL[@]}" STUB_ALIASES="$ALIASES" -- kill-window -t 0:7)
assert_eq "F8: a fully-recognised sequence still RUNS when non-lethal" "$(ran_through)" yes

echo "=== F9 — the alias-table cache actually caches (counted, not asserted) ==="
# The header claimed "at most ONE round trip, cached behind _tw_alias_done".
# It was false: `_tw_ak=$(_tw_resolve_alias …)` ran the function in a SUBSHELL,
# so the flag and the fetched table died with it — measured 1/2/3/4 queries for
# 1/2/3/4 unknown words. Nothing in monitor/ chains commands, so nothing broke
# operationally; it was a FALSE CLAIM with nothing checking it. This counts.
QC="$WORK/qcount"
qcount() {   # <argv...> -> number of `show -s command-alias` calls made
    : > "$QC"
    run_shim "${ONBOARD[@]}" STUB_QCOUNT="$QC" STUB_SESSIONS=1 STUB_WINDOWS=12 \
        STUB_ALIASES='command-alias[0] "splitp=split-window"' -- "$@" >/dev/null 2>&1
    # `grep -c` exits 1 when the count is ZERO, so a `|| echo 0` fallback fires
    # ALONGSIDE the successful "0" and yields "0\n0". Capture, then default.
    local n
    n=$(grep -c Q "$QC" 2>/dev/null) || n=0
    printf '%s' "${n:-0}"
}
assert_eq "F9: one unknown word costs one alias query" "$(qcount list-windows)" 1
assert_eq "F9: TWO unknown words still cost ONE (the cache works)" \
    "$(qcount list-windows ';' list-panes)" 1
assert_eq "F9: FOUR unknown words still cost ONE" \
    "$(qcount list-windows ';' list-panes ';' display-message ';' has-session)" 1
# The property sk897 measured and confirmed: a fully-recognised sequence asks
# nothing at all. This is the hot-path claim, so it is counted too.
assert_eq "F9: a fully-recognised kill issues ZERO alias queries" "$(qcount kill-server)" 0
assert_eq "F9: …including an abbreviated one" "$(qcount kill-ser)" 0

echo "=== NON-ZSH CHILDREN — the entire reason this is an executable ==="
# A shell FUNCTION would not survive any of these. Assert it; do not assume it.
#
# These legs invoke a BARE `tmux` on purpose — that is the thing being tested.
# Two independent containments make that safe even if the shim or the stub were
# missing entirely: the rigged PATH resolves `tmux` to the shim (whose own
# resolution then finds the stub), and JAIL redirects a hypothetical REAL tmux
# to a socket dir of its own. `env -u TMUX` on the same command is what makes
# the jail effective — $TMUX outranks TMUX_TMPDIR, and it is always set for an
# agent (your-org/nexus-code#644). Each command is kept on ONE line so the
# `env -u TMUX` and the invocation cannot be separated by a continuation.
RIG="PATH=$SHIM_DIR:$STUB_DIR:/usr/bin:/bin STUB_TRACE=$TRACE STUB_SOCK=$BOARD NEXUS_TMUX_SOCKET=$BOARD"

bout=$(bash -c "env -u TMUX TMUX_TMPDIR=$JAIL $RIG tmux kill-server 2>&1")
assert_contains "a kill from \`bash -c\` (bare \`tmux\`) is refused" "$bout" "REFUSING \`kill-server\`"

bout2=$(bash -c "env -u TMUX TMUX_TMPDIR=$JAIL $RIG bash -c 'tmux kill-server' 2>&1")
assert_contains "a kill nested TWO bash levels down is refused" "$bout2" "REFUSING \`kill-server\`"

bout3=$(bash -c "env -u TMUX TMUX_TMPDIR=$JAIL $RIG sh -c 'tmux kill-window' 2>&1")
assert_contains "an untargeted kill from a \`sh -c\` grandchild is refused" "$bout3" "REFUSING \`kill-window\`"

if command -v python3 >/dev/null 2>&1; then
    pout=$(SHIM_DIR="$SHIM_DIR" STUB_DIR="$STUB_DIR" TRACE="$TRACE" BOARD="$BOARD" JAIL="$JAIL" \
        python3 - <<'PY' 2>&1
import os, subprocess
env = dict(os.environ)
env.pop("TMUX", None)
env["PATH"] = env["SHIM_DIR"] + ":" + env["STUB_DIR"] + ":/usr/bin:/bin"
env["STUB_TRACE"] = env["TRACE"]
env["STUB_SOCK"] = env["BOARD"]
env["NEXUS_TMUX_SOCKET"] = env["BOARD"]
env["TMUX_TMPDIR"] = env["JAIL"]      # second containment; see the bash legs above
r = subprocess.run(["tmux", "kill-server"], env=env,
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(r.stdout.decode())
PY
    )
    assert_contains "a kill from \`python subprocess\` is refused" "$pout" "REFUSING \`kill-server\`"
    HAVE_PY_LEG=1
else
    th_skip "python-subprocess leg" "no python3 on this host"
fi

echo "=== SELF-EXCLUSION: the wrapper dir reachable under a SECOND name ==="
# your-org/nexus-code#568 A5: a shim dir reachable as a symlink / bind mount /
# automount alias fails a directory-STRING comparison, so the wrapper resolves
# ITSELF as "the real tmux" and re-execs forever. This shim uses `-ef`
# (same device+inode, no fork) for that gate; assert it actually holds.
ALIAS_DIR="$WORK/aliasdir"
ln -s "$SHIM_DIR" "$ALIAS_DIR"
for order in "$SHIM_DIR:$ALIAS_DIR" "$ALIAS_DIR:$SHIM_DIR"; do
    timeout 20 env -u TMUX -u NEXUS_TMUX_SOCKET TMUX_TMPDIR="$JAIL" \
        PATH="$order:$STUB_DIR:/usr/bin:/bin" STUB_TRACE="$TRACE" \
        STUB_SOCK=/tmp/tmux-1/iso tmux list-windows >/dev/null 2>&1
    rc=$?
    assert_eq "no self-recursion with the shim dir on PATH twice (${order%%:*} first)" "$rc" 0
done

echo "=== TWO DISTINCT WRAPPER FILES on PATH (your-org/nexus-code#1033) ==="
# THE COVERAGE BOUNDARY THIS CLOSES, IN ONE SENTENCE: the SELF-EXCLUSION block
# above plants a SYMLINK, so it only ever exercises the ALIASING case (one file,
# two names) that `-ef` already closes — until this block there was no case with
# two DISTINCT wrapper FILES, which is the inverse and the one that fired.
#
# Why it fired in the NORMAL configuration rather than an exotic one: this file
# derives SHIM_DIR from its OWN location, while locals-env.sh / front-path.zsh
# PATH-front the PRIMARY's copy for every agent process — so running this suite
# from any clone that is not $NEXUS_ROOT puts two distinct copies on PATH at
# once. Workers are REQUIRED to work in a clone. Uncontained on 2026-08-26 that
# reached 7,705 processes, wrapped the PID space and killed an agent.
#
# BOUNDED BY CONSTRUCTION, because a regression here must fail rather than take
# the host down: `ulimit -u` caps the subtree and `timeout` caps the wall clock.
# The cap is computed from the CURRENT thread count, not a constant and not a
# process count — RLIMIT_NPROC is per-UID and Linux charges THREADS against it,
# so a constant cap (or one derived from `ps | wc -l`) can sit BELOW live usage
# and starve at the first fork with rc 254, which reads exactly like a failure.
TWO_A="$WORK/copyA"; TWO_B="$WORK/copyB"
mkdir -p "$TWO_A" "$TWO_B"
cp "$SHIM_DIR/tmux" "$TWO_A/tmux"; cp "$SHIM_DIR/tmux" "$TWO_B/tmux"
chmod +x "$TWO_A/tmux" "$TWO_B/tmux"

# The precondition, asserted rather than assumed: if these ever shared an inode
# this would silently become a second copy of the symlink test above.
if [ "$TWO_A/tmux" -ef "$TWO_B/tmux" ]; then
    assert_eq "the two planted wrapper copies are DISTINCT files" "same-inode" "distinct"
else
    assert_eq "the two planted wrapper copies are DISTINCT files" "distinct" "distinct"
fi

_two_cap=$(( $(ps -u "$(id -un)" -o nlwp= 2>/dev/null | awk '{s+=$1} END{print s+0}') + 400 ))
[ "$_two_cap" -gt 400 ] || _two_cap=2000        # nlwp unavailable: fall back generously
# THE THIRD ORDER IS THE LOAD-BEARING ONE, AND IT IS THE ONE THAT WAS MISSING.
# Two copies of the CURRENT wrapper is the easy half: both carry the content
# signature, so either arm of `_tw_is_nexus_wrapper` catches it and a matcher
# keyed on nothing but the introduced marker still passes. The configuration the
# fix actually exists for is a fixed copy meeting an UNFIXED one — which is what
# every rollout is, and what `BASH_ENV` manufactures automatically by
# re-prepending the PRIMARY's wrapper dir to every non-interactive bash.
#
# This leg was absent, and its absence was demonstrated rather than argued: the
# `#1037` skeptic deleted the path-comment arm from `_tw_is_nexus_wrapper`,
# leaving only the marker arm — precisely the regression that shipped in the
# first draft and failed on first run — and THIS SUITE STAYED GREEN AT 126/0
# while the real rollout pair broke at rc 127. A guard that cannot see the
# defect it was written for is not a guard.
#
# The pre-fix copy comes from git rather than from a hand-written fixture, so it
# is the actual code that actual clones are running. `PREFIX_REF` is the merge
# base with the integration branch; when history is unavailable (CI checks out
# shallow) this SKIPS loudly rather than silently narrowing the suite.
TWO_OLD="$WORK/copyOld"
mkdir -p "$TWO_OLD"
#
# AND A SYNTHESIZED FALLBACK, BECAUSE THE GIT LOOKUP EXPIRES. Once this fix is
# merged, `merge-base origin/dev HEAD` CONTAINS the fix, every fallback ref
# contains it, and the leg would SKIP from then on — loudly, but permanently,
# leaving the gap it was written to close reopened after exactly one merge. So
# when no historical pre-fix blob is reachable, BUILD one: the current wrapper
# with the third-gate call removed is precisely the "unfixed" shape. It keeps
# its own path comment, which is what the FIXED copy must see in order to break
# the cycle — that is the whole property under test, and it does not depend on
# how deep the checkout is.
_two_prefix_ok=0
for _pref in "$(git -C "$REPO_ROOT" merge-base origin/dev HEAD 2>/dev/null)" origin/dev HEAD~1; do
    [ -n "$_pref" ] || continue
    if git -C "$REPO_ROOT" show "${_pref}:monitor/tmuxwrap/tmux" > "$TWO_OLD/tmux" 2>/dev/null \
       && [ -s "$TWO_OLD/tmux" ]; then
        # Only useful if it really is a PRE-fix copy: it must NOT already carry
        # the content gate, or this leg silently becomes a third copy of the
        # easy case above.
        if ! grep -q '_tw_is_nexus_wrapper' "$TWO_OLD/tmux"; then
            chmod +x "$TWO_OLD/tmux"; _two_prefix_ok=1; _two_prefix_ref="$_pref"; break
        fi
    fi
done

if [ "$_two_prefix_ok" != 1 ]; then
    # Synthesize: drop the content-gate CALL, keep everything else (including
    # the path comment the fixed copy keys on).
    if sed '/_tw_is_nexus_wrapper "\$_tw_d\/\$_tw_name" && continue/d' \
           "$SHIM_DIR/tmux" > "$TWO_OLD/tmux" 2>/dev/null \
       && [ -s "$TWO_OLD/tmux" ] \
       && ! grep -q '_tw_is_nexus_wrapper "\$_tw_d' "$TWO_OLD/tmux" \
       && grep -q 'monitor/tmuxwrap/tmux' "$TWO_OLD/tmux"; then
        chmod +x "$TWO_OLD/tmux"; _two_prefix_ok=1; _two_prefix_ref="synthesized-prefix"
    fi
fi

# CLASSIFY THE OUTCOME, AND DO NOT LET THE BACKSTOP MASK THE GATE.
#
# rc 127 is the RE-ENTRY BOUND refusing — which means the pair DID cycle and was
# caught by the backstop, not by the content gate this suite exists to test. An
# earlier version of this leg scored 127 as `bounded` and therefore PASSED the
# planted regression it was written to catch (marker-only matcher, path-comment
# arm deleted): the cycle happened, the bound absorbed it, and the suite called
# it a pass. Resolution that WORKS reaches a real tmux and returns tmux's own
# status, never 127.
#
#   124 -> recursed (unbounded; the timeout fired)     VOID as a test result
#   254 -> fork starvation                             VOID as a test result
#   127 -> cycled and hit the backstop, or found no real tmux at all
#   else -> resolved to a real binary   <- the only pass
_two_verdict() {   # $1 = rc
    case "$1" in
        124) printf 'recursed' ;;
        254) printf 'starved-void' ;;
        127) printf 'cycled-caught-by-backstop-or-unresolved' ;;
        *)   printf 'resolved' ;;
    esac
}

_two_case=0
for order in "$TWO_A:$TWO_B" "$TWO_B:$TWO_A"; do
    _two_case=$((_two_case + 1))
    _two_first="${order%%:*}"; _two_label="copy${_two_case} (${_two_first##*/} first)"
    _two_before=$(ps -eo args= 2>/dev/null | grep -c '[t]muxwrap/tmux')
    ( ulimit -u "$_two_cap" 2>/dev/null
      exec timeout 20 env -u TMUX -u NEXUS_TMUX_SOCKET TMUX_TMPDIR="$JAIL" \
          PATH="$order:$STUB_DIR:/usr/bin:/bin" STUB_TRACE="$TRACE" \
          STUB_SOCK=/tmp/tmux-1/iso "$_two_first/tmux" list-windows ) >/dev/null 2>&1
    rc=$?
    _two_after=$(ps -eo args= 2>/dev/null | grep -c '[t]muxwrap/tmux')
    # rc 124 is the timeout firing, i.e. it never terminated: that IS the bug.
    # rc 254 is fork starvation — a VOID run, not a pass and not a failure — so
    # it is reported as its own outcome rather than folded into either.
    assert_eq "two distinct wrapper copies do NOT mutually re-exec — $_two_label" \
        "$(_two_verdict "$rc")" "resolved"
    assert_eq "no wrapper processes leaked — $_two_label" \
        "$([ "$_two_after" -le "$((_two_before + 5))" ] && echo clean || echo "leaked:$_two_before->$_two_after")" \
        "clean"
done

if [ "$_two_prefix_ok" = 1 ]; then
    for order in "$TWO_A:$TWO_OLD" "$TWO_OLD:$TWO_A"; do
        _two_first="${order%%:*}"
        _two_before=$(ps -eo args= 2>/dev/null | grep -c '[t]muxwrap/tmux')
        ( ulimit -u "$_two_cap" 2>/dev/null
          exec timeout 20 env -u TMUX -u NEXUS_TMUX_SOCKET TMUX_TMPDIR="$JAIL" \
              PATH="$order:$STUB_DIR:/usr/bin:/bin" STUB_TRACE="$TRACE" \
              STUB_SOCK=/tmp/tmux-1/iso "$_two_first/tmux" list-windows ) >/dev/null 2>&1
        rc=$?
        _two_after=$(ps -eo args= 2>/dev/null | grep -c '[t]muxwrap/tmux')
        assert_eq "ROLLOUT: fixed copy vs PRE-FIX copy (${_two_prefix_ref}) resolves to a REAL tmux — ${_two_first##*/} first" \
            "$(_two_verdict "$rc")" "resolved"
        assert_eq "ROLLOUT: no wrapper processes leaked — ${_two_first##*/} first" \
            "$([ "$_two_after" -le "$((_two_before + 5))" ] && echo clean || echo "leaked:$_two_before->$_two_after")" \
            "clean"
    done
else
    th_skip "rollout leg (fixed vs PRE-FIX copy from git)" \
        "no pre-fix monitor/tmuxwrap/tmux reachable in this checkout's history"
fi

echo "=== REAL tmux server — the runtime check a stub cannot vouch for ==="
# The private server is made "the board" via NEXUS_TMUX_SOCKET, so the refusal
# path runs against a real server while the actual board is never a target.
SOCK="nxtest$$"
# your-org/nexus-code#991: measure the socket path BEFORE tmux is asked to
# bind it. A too-long TMUX_TMPDIR is an ENVIRONMENT fault, not a defect in
# the code under test, and without this it presents as one.
th_require_tmux_socket "$SOCK"
PRIV_SOCKETS+=("$SOCK")
# PIN THE FIXTURE'S CONFIG. Window indices are NOT a constant: this workspace's
# ~/.tmux.conf sets `base-index 1`, a bare CI runner has 0. Hard-coding `a:1`
# therefore passes here and reds in CI on a target that does not exist — an
# environment-dependent test dressed as an assertion about the shim.
# th_tmux_fixture_conf pins base-index 0 (among other determinism settings), and
# the indices are DERIVED below regardless, so neither host can drift.
TMUXCONF="$WORK/fixture.tmux.conf"
th_tmux_fixture_conf "$TMUXCONF"
env -u TMUX tmux -f "$TMUXCONF" -L "$SOCK" new-session -d -s a >/dev/null 2>&1
PRIV_PATH=$(env -u TMUX tmux -L "$SOCK" display-message -p '#{socket_path}' 2>/dev/null)

if [[ -z "$PRIV_PATH" ]]; then
    th_skip "real-server legs" "could not create a private tmux server on this host"
else
    # 19 = the assertions BETWEEN this line and the `fi` below; +2 more when this
    # tmux allows alias shadowing (see SHADOWABLE). It is deliberately NOT 20:
    # the `THE BOARD IS UNHARMED` assertion sits AFTER the `fi` and therefore runs
    # on BOTH paths, so it belongs in the base, not in this leg. Counting it here
    # (and docking the base to match) made the two errors cancel on the
    # real-server path while the skip path reported `102 ran, 101 expected`.
    REAL_LEG=19
    # ASSERT ISOLATION BEFORE RELYING ON IT.
    assert_eq "the private test socket is NOT the board's" \
        "$([[ "$PRIV_PATH" != "$BOARD_SOCK" ]] && echo isolated || echo THE_BOARD)" isolated
    abort_if_board "$PRIV_PATH" "run real-server tests"

    real_shim() {   # run the shim against the private server, which it believes is the board
        env -u TMUX PATH="$SHIM_DIR:/usr/bin:/bin:$PATH" \
            NEXUS_TMUX_SOCKET="$PRIV_PATH" \
            "$SHIM_DIR/tmux" -L "$SOCK" "$@" 2>&1
    }
    alive() { env -u TMUX tmux -L "$SOCK" list-sessions >/dev/null 2>&1 && echo alive || echo dead; }

    env -u TMUX tmux -L "$SOCK" new-window -d -t a >/dev/null 2>&1
    nwin=$(env -u TMUX tmux -L "$SOCK" list-windows -t a 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "fixture: the private session has 2 windows" "$nwin" 2
    # DERIVED, never assumed — see the base-index note above.
    WIDX=($(env -u TMUX tmux -L "$SOCK" list-windows -t a -F '#{window_index}' 2>/dev/null | sort -n))
    W_FIRST="${WIDX[0]:-0}"; W_SECOND="${WIDX[1]:-1}"
    assert_eq "fixture: two distinct window indices were derived, not assumed" \
        "$([[ -n "$W_FIRST" && -n "$W_SECOND" && "$W_FIRST" != "$W_SECOND" ]] && echo ok || echo bad)" ok

    # (b) legitimate: one of two windows, on the server the shim thinks is the board.
    out=$(real_shim kill-window -t "a:$W_SECOND")
    nwin=$(env -u TMUX tmux -L "$SOCK" list-windows -t a 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "REAL: targeted kill-window with 2 windows RAN (1 left)" "$nwin" 1
    assert_eq "REAL: …and the server survived" "$(alive)" alive

    # (a) lethal: the LAST window of the LAST session — every flag rule satisfied.
    out=$(real_shim kill-window -t "a:$W_FIRST")
    assert_contains "REAL: last-window kill is REFUSED" "$out" "would EMPTY the board's server"
    assert_eq "REAL: …and the server is STILL ALIVE (the refusal actually saved it)" "$(alive)" alive

    out=$(real_shim kill-session -t a)
    assert_contains "REAL: kill-session of the only session is REFUSED" "$out" "REFUSING"
    assert_eq "REAL: …server still alive" "$(alive)" alive

    out=$(real_shim kill-server)
    assert_contains "REAL: kill-server is REFUSED" "$out" "REFUSING \`kill-server\`"
    assert_eq "REAL: …server still alive" "$(alive)" alive

    # --- F6: command-alias is SERVER STATE, so no argv-only matcher can be
    # complete. Set one and invoke it through the shim.
    env -u TMUX tmux -L "$SOCK" set -s 'command-alias[99]' 'nuke=kill-server' >/dev/null 2>&1
    out=$(real_shim nuke)
    assert_contains "REAL F6: a user command-alias to kill-server is REFUSED" "$out" "REFUSING"
    assert_eq "REAL F6: …and the server survived" "$(alive)" alive

    # CAN AN ALIAS SHADOW A BUILT-IN? This is VERSION-DEPENDENT — measured
    # FALSE on tmux 2.6, TRUE on CI's 3.x, where the identical probe killed the
    # server. An earlier revision built a fast path on the 2.6 answer and was
    # unsound everywhere else; CI caught it precisely because this was asserted
    # against a real server instead of trusted as a comment.
    #
    # So the suite does NOT assert which regime it is in — that would just
    # re-encode one host's answer. It DETECTS the regime, then asserts the
    # property that must hold in EITHER: the shim refuses a shadowed built-in
    # wherever shadowing is possible at all.
    SHADOW_SOCK="shadow$$"
    PRIV_SOCKETS+=("$SHADOW_SOCK")
    env -u TMUX tmux -f "$TMUXCONF" -L "$SHADOW_SOCK" new-session -d -s a >/dev/null 2>&1
    SHADOW_PATH=$(env -u TMUX tmux -L "$SHADOW_SOCK" display-message -p '#{socket_path}' 2>/dev/null)
    if [[ -n "$SHADOW_PATH" ]] && [[ "$SHADOW_PATH" != "$BOARD_SOCK" ]]; then
        abort_if_board "$SHADOW_PATH" "probe alias shadowing"
        env -u TMUX tmux -L "$SHADOW_SOCK" set -s 'command-alias[98]' 'list-windows=kill-server' >/dev/null 2>&1
        env -u TMUX tmux -L "$SHADOW_SOCK" list-windows >/dev/null 2>&1
        if env -u TMUX tmux -L "$SHADOW_SOCK" list-sessions >/dev/null 2>&1; then
            SHADOWABLE=0
            th_skip "shadowed-built-in refusal" \
                "this tmux ($(tmux -V 2>/dev/null)) does not let an alias shadow a built-in, so there is nothing to refuse"
            env -u TMUX tmux -L "$SHADOW_SOCK" kill-server 2>/dev/null || true
        else
            SHADOWABLE=1
        fi
        assert_eq "the alias-shadowing regime was determined (not assumed)" \
            "$([[ "$SHADOWABLE" == 0 || "$SHADOWABLE" == 1 ]] && echo ok || echo undetermined)" ok

        # Where shadowing IS possible, the shim must refuse a shadowed built-in
        # on the board — the case the removed fast path would have waved through.
        if (( SHADOWABLE )); then
            env -u TMUX tmux -f "$TMUXCONF" -L "$SOCK" new-session -d -s shad >/dev/null 2>&1
            env -u TMUX tmux -L "$SOCK" set -s 'command-alias[98]' 'list-windows=kill-server' >/dev/null 2>&1
            out=$(real_shim list-windows)
            assert_contains "REAL: a built-in SHADOWED by an alias is refused" "$out" "REFUSING"
            assert_eq "REAL: …and the server survived it" "$(alive)" alive
            env -u TMUX tmux -L "$SOCK" set -u -s 'command-alias[98]' >/dev/null 2>&1
            env -u TMUX tmux -L "$SOCK" kill-session -t shad >/dev/null 2>&1
        else
            th_skip "shadowed-built-in refusal on the board" "not shadowable on this tmux"
            th_skip "shadowed-built-in server survival" "not shadowable on this tmux"
        fi
    else
        th_skip "alias-shadowing probe" "could not create a second private server"
        SHADOWABLE=0
    fi
    env -u TMUX tmux -L "$SOCK" set -u -s 'command-alias[99]' >/dev/null 2>&1

    # --- Composition: a later command's flags must not license an earlier
    # command. `kill-window -t <last> ; new-window -a` must not have its `-a`
    # read by the kill.
    out=$(real_shim kill-window -t "a:$W_FIRST" ';' new-window -a)
    assert_contains "REAL: a later command's -a does NOT license an earlier lethal kill" \
        "$out" "REFUSING"
    assert_eq "REAL: …and the server survived that composition" "$(alive)" alive

    # And the hot path against a real server, which is what the watcher runs.
    out=$(real_shim list-windows -t a -F '#{window_index}')
    # Assert the DERIVED surviving index, not a literal — the same base-index
    # hazard as the kill targets above.
    assert_contains "REAL: list-windows passes through unchanged" "$out" "$W_FIRST"
    assert_eq "REAL: …server still alive after the hot path" "$(alive)" alive

    # Now prove the shim is the ONLY thing that was keeping it alive: with the
    # private socket no longer masquerading as the board, the identical command
    # is permitted and the server dies exactly as predicted.
    abort_if_board "$PRIV_PATH" "run the not-the-board control"
    env -u TMUX PATH="$SHIM_DIR:/usr/bin:/bin:$PATH" NEXUS_TMUX_SOCKET="$BOARD_SOCK" \
        "$SHIM_DIR/tmux" -L "$SOCK" kill-window -t "a:$W_FIRST" >/dev/null 2>&1
    assert_eq "REAL control: the SAME command on a non-board socket RAN, and the server exited" \
        "$(alive)" dead
fi

echo "=== THE BOARD IS UNHARMED ==="
# Asserted as STATE UNCHANGED rather than "alive", so it is a real assertion on
# a host with no board (CI) as well as on this workspace — and a stronger one:
# it would also catch the suite having *created* something on the board.
assert_eq "the board tmux server is the SAME server this suite started against" \
    "$(board_state)" "$BOARD_STATE_BEFORE"

# SHADOWABLE_ASSERTS: 2 extra assertions run only where an alias can shadow a
# built-in (tmux 3.x yes, 2.6 no) — a REGIME difference, declared here so the
# count reconciles on both instead of being loosened to accommodate them.
SHADOWABLE_ASSERTS=0
(( ${SHADOWABLE:-0} )) && SHADOWABLE_ASSERTS=2

# Pinned assertion total, written as base + per-leg increments so that a leg
# which silently stops running reds instead of just lowering the number. Two
# legs are genuinely environment-dependent (no python3, or no tmux to build a
# private server with), and the arithmetic is where that is declared.
#
# The base is 106 — 101 before your-org/nexus-code#1033 added the five
# TWO-DISTINCT-WRAPPER-FILES assertions (distinct-inode precondition, plus a
# no-mutual-re-exec and a no-leak assertion for each of the two PATH orders).
# The base moves with the suite BY DESIGN: an unchanged base next to new
# assertions is how a count guard gets quietly disabled.
#
# The number is EXACT ON BOTH PATHS — that is the whole
# point of a count guard, and it was not true before. `THE BOARD IS UNHARMED`
# above runs whether or not the real-server leg does, so it is base, not leg.
# It used to be double-counted into REAL_LEG while the base was docked to 100
# to compensate: the two errors cancelled wherever a private tmux server COULD
# be built, and a host that skipped the leg reported `102 ran, 101 expected` —
# a red that was a property of the host, not of the shim. A guard that is only
# right on one path is not a guard.
BASE_ASSERTS=106
# The ROLLOUT leg (fixed copy vs PRE-FIX copy from git) is environment-dependent
# in exactly the way the other two legs are: it needs history, and CI checks out
# shallow. 4 assertions (two PATH orders x re-exec + leak) when it runs, 0 and a
# loud SKIP when the pre-fix blob is unreachable. Declared here rather than
# folded into the base, so a host that cannot run it does not report a mismatch
# that is a property of the host — the exact error this guard was rebuilt to
# stop having.
ROLLOUT_LEG=0
[ "${_two_prefix_ok:-0}" = 1 ] && ROLLOUT_LEG=4
EXPECTED=$(( BASE_ASSERTS + HAVE_PY_LEG + REAL_LEG + ROLLOUT_LEG + (SHADOWABLE_ASSERTS) ))
if (( PASS + FAIL != EXPECTED )); then
    echo "ASSERTION COUNT MISMATCH — $(( PASS + FAIL )) ran, $EXPECTED expected" >&2
    echo "  (base $BASE_ASSERTS + python leg $HAVE_PY_LEG + real-server leg $REAL_LEG" \
         "+ rollout leg $ROLLOUT_LEG + shadowable $SHADOWABLE_ASSERTS)" >&2
    FAIL=$(( FAIL + 1 ))
fi
th_summary_and_exit
