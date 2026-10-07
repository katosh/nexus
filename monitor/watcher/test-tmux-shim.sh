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
    # An EMPTY path is a private server that could not be created or queried —
    # still a refusal (a target nobody resolved cannot be proven not to be the
    # board), but NOT "IS THE BOARD". Callers once passed `${P:-$BOARD_SOCK}`,
    # so a lost tmux race on CI, where no board exists, read as the board (#1703).
    if [[ -z "$1" ]]; then
        echo "ABORT: refusing to $2 — the private server's socket path is UNRESOLVED (server not created or not answering)." >&2
        echo "FAILED"; exit 9
    fi
    if [[ "$1" == "$BOARD_SOCK" ]]; then
        echo "ABORT: refusing to $2 — target socket '$1' IS THE BOARD." >&2
        echo "FAILED"; exit 9
    fi
}
# start_server <cmd…> — start a PRIVATE server, retrying a bounded number of
# times. A server killed one line earlier can still be EXITING when the next
# client connects; tmux 3.4 (the CI runner's) then fails `server exited
# unexpectedly` instead of starting a fresh one. Measured under CPU load on 3.4,
# never seen on 2.6; on CI it aborted the suite (#1703). The caller still reads
# the socket path back and hands it to abort_if_board, so a retry that never
# succeeds stays a refusal.
start_server() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        "$@" && return 0
        sleep 0.2
    done
    return 1
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
        # CONTROL MODE frames every reply (measured on 2.6: `%begin <t> <n> 0`
        # first), so a probe that replays `-C` never sees `NXSOCK:` (#1582
        # skeptic F3). STUB_SOCK=FRAMED stages a server answering in some
        # OTHER unparsed framing.
        for _sa in "$@"; do
            [[ "$_sa" =~ ^-[2luvV]*C ]] && { printf '%%begin 1 1 0\nNXSOCK:%s\n%%end 1 1 0\n' "${STUB_SOCK:-/tmp/stub/default}"; exit 0; }
            [[ "$_sa" == -* ]] || break
        done
        [[ "${STUB_SOCK:-}" == "FRAMED" ]] && { echo '%begin 1 1 0'; exit 0; }
        printf 'NXSOCK:%s\n' "${STUB_SOCK:-/tmp/stub/default}"; exit 0 ;;
    '#{session_windows}|#{window_panes}|#{window_index}|#{window_name}')
        [[ "${STUB_BADTARGET:-}" == 1 ]] && exit 1
        # The RESOLVED window (your-org/nexus-code#1524). By default the stub
        # resolves a target to ITSELF — the window part of `-t`, as its name and,
        # when numeric, its index — which is what an exact match looks like and
        # keeps every pre-#1524 case meaning what it meant. STUB_RNAME /
        # STUB_RINDEX override that to stage a PREFIX REDIRECT.
        _st=""; _sp=""
        for _sa in "$@"; do [[ "$_sp" == "-t" ]] && _st="$_sa"; _sp="$_sa"; done
        _sw="${_st#*:}"; _sw="${_sw%%.*}"
        _si=0; [[ "$_sw" =~ ^[0-9]+$ ]] && _si="$_sw"
        printf '%s|%s|%s|%s\n' "${STUB_WINDOWS:-9}" "${STUB_PANES:-9}" "${STUB_RINDEX:-$_si}" "${STUB_RNAME-$_sw}"; exit 0 ;;
    '#{window_index}|#{window_name}')
        # The `-a` mis-aim probe (shape-skip sweep on #1568): index, then name.
        [[ "${STUB_BADTARGET:-}" == 1 ]] && exit 1
        _st=""; _sp=""
        for _sa in "$@"; do [[ "$_sp" == "-t" ]] && _st="$_sa"; _sp="$_sa"; done
        _sw="${_st#*:}"; _sw="${_sw%%.*}"
        _si=0; [[ "$_sw" =~ ^[0-9]+$ ]] && _si="$_sw"
        printf '%s|%s\n' "${STUB_RINDEX:-$_si}" "${STUB_RNAME-$_sw}"; exit 0 ;;
    '#{session_windows}|#{window_panes}|#{pane_index}|#{window_id}|#{window_index}|#{window_name}'|'#{pane_index}|#{window_id}|#{window_index}|#{window_name}')
        # The #1583 kill and act probes: the resolved PANE's index and its window's
        # ID lead (semisplitsk F6, then semisplitsk2 F2). Staged by STUB_RPANE /
        # STUB_RWID; the defaults (pane 0, window @R, while the CURRENT window —
        # the untargeted probe below — is @C) can never satisfy the exemption, so
        # every older row keeps meaning what it meant.
        [[ "${STUB_BADTARGET:-}" == 1 ]] && exit 1
        _st=""; _sp=""
        for _sa in "$@"; do [[ "$_sp" == "-t" ]] && _st="$_sa"; _sp="$_sa"; done
        [[ -n "${STUB_PROBE_LOG:-}" ]] && printf '%s\n' "$_st" >> "$STUB_PROBE_LOG"
        _sw="${_st#*:}"; _sw="${_sw#=}"; _sw="${_sw%%.*}"
        _si=0; [[ "$_sw" =~ ^[0-9]+$ ]] && _si="$_sw"
        _pf="${STUB_RPANE:-0}|${STUB_RWID:-@R}|${STUB_RINDEX:-$_si}|${STUB_RNAME-$_sw}"
        case "$last" in
            '#{session_windows}'*) printf '%s|%s|%s\n' "${STUB_WINDOWS:-9}" "${STUB_PANES:-9}" "$_pf" ;;
            *)                     printf '%s\n' "$_pf" ;;
        esac
        exit 0 ;;
    '#{window_id}')
        # The UNTARGETED current-window probe (semisplitsk2 F2): asked only after a
        # mis-aim is established, to prove the pane tier answered.
        [[ -n "${STUB_CWID_LOG:-}" ]] && echo Q >> "$STUB_CWID_LOG"
        printf '%s\n' "${STUB_CWID-@C}"; exit 0 ;;   # `-`, not `:-`: an EMPTY answer must be stageable
    '#{session_windows}|#{window_panes}|#{pane_index}|#{window_active}|#{window_index}|#{window_name}'|'#{pane_index}|#{window_active}|#{window_index}|#{window_name}')
        # The ff9f8a55..8c9c3aa9 kill and act probes, keyed on #{window_active}.
        # The shim no longer sends them; the arm is KEPT (as the pre-#1578 arm
        # below is) so this suite run against THAT shim answers its protocol.
        [[ "${STUB_BADTARGET:-}" == 1 ]] && exit 1
        _st=""; _sp=""
        for _sa in "$@"; do [[ "$_sp" == "-t" ]] && _st="$_sa"; _sp="$_sa"; done
        [[ -n "${STUB_PROBE_LOG:-}" ]] && printf '%s\n' "$_st" >> "$STUB_PROBE_LOG"
        _sw="${_st#*:}"; _sw="${_sw#=}"; _sw="${_sw%%.*}"
        _si=0; [[ "$_sw" =~ ^[0-9]+$ ]] && _si="$_sw"
        _pf="${STUB_RPANE:-0}|${STUB_RACTIVE:-0}|${STUB_RINDEX:-$_si}|${STUB_RNAME-$_sw}"
        case "$last" in
            '#{session_windows}'*) printf '%s|%s|%s\n' "${STUB_WINDOWS:-9}" "${STUB_PANES:-9}" "$_pf" ;;
            *)                     printf '%s\n' "$_pf" ;;
        esac
        exit 0 ;;
    '#{window_index}|#{session_name}|#{window_name}')
        # The PRE-#1578 act probe. The shim no longer sends it; the arm is KEPT so
        # this suite, run against an OLDER shim, answers that shim's protocol and
        # its flip set measures BEHAVIOUR rather than a missing stub arm (#1582
        # skeptic F8: without it, ~27 unchanged rows flipped against f13cfb74 for
        # that reason alone, and the published flip count was not reproducible).
        [[ "${STUB_BADTARGET:-}" == 1 ]] && exit 1
        _st=""; _sp=""
        for _sa in "$@"; do [[ "$_sp" == "-t" ]] && _st="$_sa"; _sp="$_sa"; done
        _sw="${_st#*:}"; _sw="${_sw%%.*}"
        _si=0; [[ "$_sw" =~ ^[0-9]+$ ]] && _si="$_sw"
        printf '%s|%s|%s\n' "${STUB_RINDEX:-$_si}" "${STUB_RSESSION:-a}" "${STUB_RNAME-$_sw}"; exit 0 ;;
    '#{session_name}')
        # The SESSION probe (#1578 bundle: merge4sk G2/G3). Its own call, because
        # a session name and a window name are both free text and no separator
        # splits one line holding both with certainty. By default it resolves a
        # target to ITSELF — the part before the first `:` (a `<word>:` probe
        # for a bare kill-session target lands here too) — and to `a` for a bare
        # act target, which is the G2 session-reading question. STUB_RSESSION
        # overrides it, to stage a session PREFIX redirect.
        [[ "${STUB_BADTARGET:-}" == 1 ]] && exit 1
        _st=""; _sp=""
        for _sa in "$@"; do [[ "$_sp" == "-t" ]] && _st="$_sa"; _sp="$_sa"; done
        _ss=a; [[ "$_st" == *:* ]] && _ss="${_st%%:*}"
        printf '%s\n' "${STUB_RSESSION-$_ss}"; exit 0 ;;
esac
# The alias table. Until this existed the suite could not exercise resolution
# in ANY stub fixture, which is precisely why F8 was invisible to it.
# The SERVER's global environment (#1583 D3): `show-environment -g NAME` answers
# `NAME=value` from STUB_SENV (one NAME=value per line), else `-NAME`, as tmux does.
if [[ "$*" == *"show-environment -g "* ]]; then
    _sn="${!#}"
    _sv=$(printf '%s\n' "${STUB_SENV:-}" | grep -F -m1 -e "${_sn}=" || true)
    if [[ "$_sv" == "${_sn}="* ]]; then printf '%s\n' "$_sv"; else printf -- '-%s\n' "$_sn"; fi
    exit 0
fi
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
        CLAUDECODE=1 \
        ${envs[@]+"${envs[@]}"} \
        "$SHIM_DIR/tmux" "$@" 2>&1
}
# CLAUDECODE=1 IS SET EXPLICITLY, on purpose (#1583): carriers are refused for an
# AGENT caller only, and Claude Code marks its tool subprocesses with it. Left to
# inheritance, this suite would model an agent when an agent runs it and the
# operator when CI does — two different suites under one name. A row models the
# operator by passing CLAUDECODE= (empty), which the shim reads as "not an agent".
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

echo "=== #1524 — a NAMED target that tmux resolved by PREFIX to a DIFFERENT window ==="
# tmux resolves the window part of `-t <name>` as id -> index -> exact name ->
# UNIQUE PREFIX -> fnmatch. With `w1` already closed and its skeptic `w1-sk`
# alive, `kill-window -t w1` kills `w1-sk` at rc 0 — measured on this host's
# tmux 2.6 THROUGH this shim, which passed it along (the issue's row N).
#
# PREDICTED FLIP SET for "delete the Rule 4 block" (written before the mutation
# round): the four REFUSED rows here and the two REAL row-A rows go red; every
# pass-through row below stays green, because a pass-through is what the shim
# does without the rule.
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_RINDEX=3 -- kill-window -t w1)
assert_eq "#1524 kill-window -t w1 resolved to 'w1-sk' is REFUSED (did not run)" "$(ran_through)" no
assert_contains "#1524 …names BOTH windows and the exact-match remedy" "$out" "resolved the name by PREFIX to a DIFFERENT window, 'w1-sk'"
assert_contains "#1524 …and prescribes the measured exact form" "$out" "-t :=w1"
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_RINDEX=3 -- kill-window -t s:w1)
assert_eq "#1524 the session:name spelling redirects too, and is REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_RINDEX=3 -- kill-pane -t w1)
assert_eq "#1524 kill-pane -t w1 resolved to 'w1-sk' is REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=123 STUB_RINDEX=4 -- kill-window -t 12)
assert_eq "#1524 an all-digit word '12' that tmux resolved to index 4 named '123' matched NEITHER as an index NOR as a name — REFUSED" "$(ran_through)" no
# THE DIRECTION THAT WEDGES THE BOARD: everything that is not provably a mis-aim passes.
out=$(run_shim "${ONBOARD[@]}" -- kill-window -t w1)
assert_eq "#1524 an EXACT name (resolved == requested) passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=anything STUB_RINDEX=7 -- kill-window -t 7)
assert_eq "#1524 an INDEX target whose resolved index matches passes, whatever the window is called" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=7 STUB_RINDEX=2 -- kill-window -t 7)
assert_eq "#1524 an all-digit target that is a window's NAME passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_RINDEX=3 -- kill-window -t @12)
assert_eq "#1524 an @id target is never judged by name" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_RINDEX=3 -- kill-window -t :=w1)
assert_eq "#1524 an already-exact ':=name' target is left to tmux" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_RINDEX=3 -- kill-window -t 'w1*')
assert_eq "#1524 a glob target is a DELIBERATE pattern, not a mis-aim — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=a.b-sk STUB_RINDEX=3 -- kill-window -t s:a.b)
# WAS "cannot be parsed with certainty — passes". It CAN be parsed, and that was
# measured (delta skeptic G4): tmux 2.6 splits at the FIRST '.', so `s:a.b` names
# window `a`, which here resolved by prefix to `a.b-sk` — neither reading matches.
assert_eq "#1524/G4 'a.b' names window 'a' (tmux splits at the first '.'); resolved to 'a.b-sk' it matches NEITHER reading — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME= -- kill-window -t w1)
assert_eq "#1524 an EMPTY resolved name (a tmux that does not expand the format) establishes nothing — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=other -- kill-session -t w1)
assert_eq "#1524 kill-session takes a SESSION target — the window rule does not apply" "$(ran_through)" yes
out=$(run_shim STUB_SOCK=/tmp/tmux-1/priv NEXUS_TMUX_SOCKET="$BOARD" STUB_RNAME=w1-sk -- -L priv kill-window -t w1)
assert_eq "#1524 a PRIVATE socket is not our business, mis-aim or not" "$(ran_through)" yes

echo "=== #1524 — the same refusal for every verb that ACTS on a named window ==="
# A redirected paste delivers an instruction to the wrong agent; a redirected
# Enter submits whatever that agent has drafted (#1200). PREDICTED FLIP SET for
# "drop the act arm from the per-command loop": the six REFUSED rows here and the
# two REAL act rows go red; every pass-through row stays green — a pass-through
# is what the shim does without the rule — and so does every kill row above.
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_RINDEX=3 -- send-keys -t w1 Enter)
assert_eq "#1524 send-keys -t w1 resolved to 'w1-sk' is REFUSED (did not run)" "$(ran_through)" no
assert_contains "#1524 …the refusal names both windows and says what would have happened" "$out" "DIFFERENT window, 'w1-sk' (index 3),"$'\n'"and would have ACTED ON THAT"
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- paste-buffer -d -b buf7 -t a:w1)
assert_eq "#1524 paste-buffer -b <buf> -t session:w1 is REFUSED (the value of -b is not mistaken for a word)" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- respawn-window -k -t w1 'sleep 5')
assert_eq "#1524 respawn-window -k -t w1 is REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- send -t w1 Escape)
assert_eq "#1524 the built-in short form 'send' is the same verb — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- select-w -t w1)
assert_eq "#1524 an ABBREVIATION (select-w) is the same verb — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- list-windows \; send-keys -t w1 Enter)
assert_eq "#1524 an act LATER in a command sequence is judged too — REFUSED" "$(ran_through)" no
# …and everything not PROVABLY a mis-aim passes.
out=$(run_shim "${ONBOARD[@]}" -- send-keys -t w1 Enter)
assert_eq "#1524 act: an EXACT name (resolved == requested) passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=zsh STUB_RSESSION=nexus -- send-keys -t nexus Enter)
assert_eq "#1524 act: a word naming the resolved SESSION is a session target, not a mis-aimed window — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- send-keys -t :=w1 Enter)
assert_eq "#1524 act: an already-exact ':=name' is left to tmux (it fails closed by itself)" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- paste-buffer -t @12)
assert_eq "#1524 act: an @id target is never judged by name" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- send-keys -l hello -t w1)
assert_eq "#1524 act: a '-t' AFTER the first key is DATA to tmux, not a target — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_BADTARGET=1 -- send-keys -t w1 Enter)
assert_eq "#1524 act: an UNRESOLVABLE target establishes nothing — passes (tmux refuses it itself)" "$(ran_through)" yes
out=$(run_shim STUB_SOCK=/tmp/tmux-1/priv NEXUS_TMUX_SOCKET="$BOARD" STUB_RNAME=w1-sk -- -L priv send-keys -t w1 Enter)
assert_eq "#1524 act: a PRIVATE socket is not our business, mis-aim or not" "$(ran_through)" yes
# --- skeptic F3/F4 on #1568: two spellings that walked past the first cut ------
# F3, measured through the head shim on a real server: `kill-pane -t w1.0`,
# `respawn-window -k -t w1.0` and `send-keys -t w1.0` all hit the sibling at rc 0
# — a trailing `.<digits>` is a PANE suffix and the window part before it
# prefix-redirects like any bare name. F4: a flag CLUSTER ending in `t`
# (`-kt w1`) and select-pane's value-taking `-T <title>` hid the target from the
# walk, so the check never ran. MEASURED against the pre-fix shim (d664d09b): the
# two F3 refusals, `-kt` and `select-pane -T` go red, plus the two REAL F3 rows —
# and three LATER real rows with them, because the pre-fix `kill-pane -t w1.0`
# really kills `w1-sk` and the fixture is gone. The two F3 controls and the
# `select-window -T` row do NOT move: that last one is a must-not-flip CONTROL
# (a bare toggle never hid the target), not a fix row — predicted wrongly first.
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_RINDEX=3 -- kill-pane -t w1.0)
assert_eq "F3 kill-pane -t w1.0 resolved to 'w1-sk' is REFUSED — the '.0' is a pane suffix, 'w1' is the name" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- send-keys -t a:w1.0 Enter)
assert_eq "F3 send-keys -t session:w1.0 resolved to 'w1-sk' is REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" -- send-keys -t w1.0 Enter)
assert_eq "F3 control: 'w1.0' resolved to the window 'w1' is an EXACT name plus a pane — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1.0 -- kill-window -t w1.0)
assert_eq "F3 control: a window really NAMED 'w1.0' matches the OTHER reading — passes (never refuse on a guess)" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- respawn-window -kt w1 'sleep 5')
assert_eq "F4 a flag CLUSTER ending in t (-kt w1) names a target exactly as -t does — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- select-pane -T 'a title' -t w1)
assert_eq "F4 select-pane -T <title> takes a VALUE: the title does not end the walk before -t — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- select-window -T -t w1)
assert_eq "F4 control: select-window -T is a bare TOGGLE, and the -t after it is found (as it was before the fix) — REFUSED" "$(ran_through)" no

# --- delta skeptic G1-G4 on #1568 ------------------------------------------------
# G1 IS A REGRESSION THE F4 FIX INTRODUCED: its arm `-t|-[!-]*t)` sat above `-t*)`
# and `[!-]` admits `t`, so a GLUED target ending in t (`-tbot`) was read as a flag
# cluster and the NEXT word became the target — `send-keys -tbot X` was refused at
# d664d09b and LANDED IN THE SIBLING at d18510ca. The walk is now getopt's, letter
# by letter. The stub resolves whatever target it is handed, so G1/G2 assert on the
# NAME the refusal reports (which word was judged); the REAL rows below measure it.
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=botsk -- send-keys -tbot X Enter)
assert_contains "G1 a GLUED target ending in t (-tbot) is judged as 'bot' — not the NEXT word 'X'" "$out" "there is NO window named 'bot'"
out=$(run_shim "${ONBOARD[@]}" -- send-keys -tbotsk X Enter)
assert_eq "G1 control: -tbotsk, an exact name, passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- respawn-window -k -t other -t w1 'sleep 5')
assert_contains "G2 -t given twice: the LAST one is the target (tmux's rule), so 'w1' is what is judged" "$out" "there is NO window named 'w1'"
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- select-pane -e -t w1)
assert_eq "G3 select-pane -e is a BARE flag on tmux 2.6: it must not swallow '-t' as its value — REFUSED" "$(ran_through)" no
# G4: tmux splits at the FIRST '.', whatever follows it.
for _sfx in '.' '.+' '.{top}'; do
    out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- kill-pane -t "w1$_sfx")
    assert_eq "G4 kill-pane -t 'w1$_sfx' resolved to 'w1-sk' is REFUSED — the window is the part before the first '.'" "$(ran_through)" no
done
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- send-keys -t 'w1.+' Enter)
assert_eq "G4 send-keys -t 'w1.+' resolved to 'w1-sk' is REFUSED" "$(ran_through)" no

# --- delta skeptic H1 on #1568: a table keyed on the verb AS TYPED ----------------
# The G3 per-verb value letters were selected by a pattern over the typed word
# (`paste-*`), while the shim admits — as tmux does — any unambiguous PREFIX. So
# `pa`/`pas`/`past`/`paste` got the empty set, `-b` read as bare, `nxb` ended the
# walk, and the paste LANDED IN THE SIBLING (refused one commit earlier). The set
# is now keyed by EQUALITY on the canonical name from _tw_act_canon. MEASURED
# against the ca7310aa shim: the six paste rows and the two REAL rows flip; the
# `send-k` and `select-p` rows do NOT (the old patterns happened to cover those
# spellings) and neither does the control — they are must-not-flip rows.
for _v in pa pas past paste; do
    out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1sk -- "$_v" -b nxb -t w1)
    assert_eq "H1 '$_v -b nxb -t w1' is paste-buffer to tmux: -b takes a VALUE, the target is found — REFUSED" "$(ran_through)" no
done
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1sk -- paste -s x -b nxb -t w1)
assert_eq "H1 two value flags before -t (paste -s x -b nxb -t w1) — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1sk -- list-windows \; pa -b nxb -t w1)
assert_eq "H1 the abbreviated form LATER in a command sequence — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1sk -- send-k -N 2 -t w1 X)
assert_eq "H1 control: an abbreviation of send-keys with its value flag -N — REFUSED (before the fix too)" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1sk -- select-p -T 'a title' -t w1)
assert_eq "H1 control: an abbreviation of select-pane with -T <title> — REFUSED (before the fix too)" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" -- paste -b nxb -t w1sk)
assert_eq "H1 control: 'paste -b nxb -t w1sk', an EXACT name, passes" "$(ran_through)" yes

# --- merge4's finding on #1568: an ALL-DIGIT word is not "an index, so safe" --------
# The act path skipped all-digit words ("an index never redirects"). True only
# when that index EXISTS: tmux falls through index -> exact name -> PREFIX, and
# worker windows ARE named by issue number, so `send-keys -t p:1566` landed in
# `1566-sk`. Kills and acts now share ONE rule (_tw_target_word + _tw_is_misaim):
# judge the RESOLVED target by equality, skip on shape only what provably cannot
# redirect. The sweep that followed found two more, both measured first:
# `kill-pane -t p:1566.0` KILLED the sibling (the KILL path never judged an
# all-digit base with a pane suffix), and a name holding a character outside
# [A-Za-z0-9_-] (`a+b`) was skipped on shape. MEASURED against the 17b00ef0 shim:
# the three REFUSED rows and the two REAL rows flip; the three pass rows do not.
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=1566-sk STUB_RINDEX=1 -- send-keys -t p:1566 HIT Enter)
assert_eq "DIGITS send-keys -t p:1566 resolved to '1566-sk' at index 1 — neither that index nor that name — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=1566-sk STUB_RINDEX=1 -- send-keys -t p:1 HIT Enter)
assert_eq "DIGITS control: an EXISTING index (p:1) still passes, whatever that window is called" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=1566 STUB_RINDEX=4 -- send-keys -t p:1566 HIT Enter)
assert_eq "DIGITS control: a window literally NAMED '1566' still passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=1566-sk STUB_RINDEX=1 -- kill-pane -t p:1566.0)
assert_eq "DIGITS sweep, KILL path: kill-pane -t p:1566.0 resolved to '1566-sk' — REFUSED (was judged by nothing)" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=x STUB_RINDEX=1 -- send-keys -t p:1.0 HIT Enter)
assert_eq "DIGITS control: an existing index WITH a pane suffix (p:1.0) still passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=a+b-sk -- send-keys -t p:a+b HIT Enter)
assert_eq "SHAPE sweep: a name holding a char outside [A-Za-z0-9_-] ('a+b') is JUDGED, not skipped — REFUSED" "$(ran_through)" no

# --- the shape-skip sweep's worst find: `-a` was never judged --------------------
# `kill-window -a` cannot empty the server, so the loop `continue`d BEFORE Rule 4.
# MEASURED at 17b00ef0 on a real server: with `w1` gone, `kill-window -a -t p:w1`
# killed `base` AND `other` and kept only the sibling `w1-sk`, rc 0.
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_RINDEX=1 -- kill-window -a -t p:w1)
assert_eq "ALL kill-window -a -t p:w1 resolved to 'w1-sk' is REFUSED — it would have killed every OTHER window" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_RINDEX=1 -- kill-window -at p:w1)
assert_eq "ALL the clustered spelling -at is the same command — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" -- kill-window -a -t p:w1)
assert_eq "ALL control: -a with an EXACT target still RUNS (the orchestrator's keep-only-this form)" "$(ran_through)" yes

# READS ARE NOT REFUSED, on purpose: rc 1 + empty stdout is what 'absent' looks
# like, and _pane-live.sh depends on seeing the prefix resolution to answer
# CANNOT-TELL. A read feeding a decision is fixed at its call site (':=').
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- display-message -p -t w1 '#{pane_id}')
assert_eq "#1524 a READ (display-message) by bare name still passes through — reads are fixed at the call site" "$(ran_through)" yes

echo "=== #1578 — an argument ENDING in ';' is a command separator ==="
# tmux 2.6's cmd_list_parse ends a command at ANY argument whose last character
# is `;` (unless it is `\;`), stripping the `;`. The shim split only on an
# argument that WAS `;`, so `display-message 'hi;' kill-server` killed a
# board-pinned server through it at rc 0 — measured at f0809ada, efd4e3a8 and
# f13cfb74 — and every per-command rule was blind to the second command.
# PREDICTED FLIP SET for "revert to the exact-`;` rule" (written before the
# mutation round): every REFUSED row in this block and the two REAL #1578 rows
# flip; the six LITERAL controls and every row outside this block do not.
for _sep in 'hi;' 'hi ;' ';;'; do
    out=$(run_shim "${ONBOARD[@]}" -- display-message "$_sep" kill-server)
    assert_eq "#1578 display-message '$_sep' kill-server — the ';'-ENDED argument separates: REFUSED" "$(ran_through)" no
done
out=$(run_shim "${ONBOARD[@]}" -- display-message -p 'x;' kill-server)
assert_eq "#1578 after flags (-p 'x;') the separator still separates — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" -- 'list-windows;' kill-server)
assert_eq "#1578 the VERB slot itself ending in ';' ('list-windows;') — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" -- send-keys -t 0:1 'ls;' kill-server)
assert_eq "#1578 send-keys key text ending in ';' — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" -- set-option -g @x 'v;' kill-server)
assert_eq "#1578 an option VALUE ending in ';' — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- display-message 'hi;' kill-window -t w1)
assert_eq "#1578 a mis-aimed kill-window behind 'hi;' is seen and REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- kill-window -t 'w1;')
assert_eq "#1578 a -t value CARRYING the separator ('w1;') is judged — REFUSED" "$(ran_through)" no
assert_contains "#1578 …as 'w1', the word tmux will act on, not 'w1;'" "$out" "there is NO window named 'w1';"
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- display-message 'hi;' send-keys -t w1 X)
assert_eq "#1578 a mis-aimed ACT behind 'hi;' is REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=1 -- kill-window -t '0:1;')
assert_eq "#1578 a LETHAL target carrying the separator ('0:1;') gets the runtime check — REFUSED" "$(ran_through)" no
assert_contains "#1578 …as the empty-the-server kill it is" "$out" "would EMPTY the board's server"
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES='command-alias[99] "nuke=kill-server"' -- display-message 'hi;' nuke)
assert_eq "#1578 an ALIASED kill behind 'hi;' is resolved and REFUSED" "$(ran_through)" no
# LITERAL controls — the wedge direction. Each is data to tmux, measured on 2.6.
out=$(run_shim "${ONBOARD[@]}" -- display-message 'hi\;' kill-server)
assert_eq "#1578 control: 'hi\\;' is a LITERAL ';' — kill-server is an ARGUMENT, passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" -- display-message 'hi\\;' kill-server)
assert_eq "#1578 control: 'hi\\\\;' is literal too — tmux counts no backslash parity, passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" -- display-message 'a;b' kill-server)
assert_eq "#1578 control: a MID-word ';' is data — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" -- display-message 'x; kill-server')
assert_eq "#1578 control: tmux does not re-split INSIDE one argument — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" -- send-keys -t 0:1 'ls;' Enter)
assert_eq "#1578 control: 'ls;' Enter reaches tmux unchanged (tmux rejects 'Enter' itself) — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" -- display-message 'hi\;' ';' display-message ok)
assert_eq "#1578 control: 'hi\\;' then an exact ';' then a harmless command — passes" "$(ran_through)" yes

echo "=== merge4sk G3 — the SESSION part of a target prefix-redirects too ==="
# Measured on 2.6, sessions p and s1x with s1 gone: `kill-window -t s1:w1` killed
# s1x:w1, `kill-window -t s1:` killed s1x's current window, `kill-session -t s1`
# killed s1x — all at rc 0. The stub stages the redirect with STUB_RSESSION.
out=$(run_shim "${ONBOARD[@]}" STUB_RSESSION=s1x -- kill-window -t s1:w1)
assert_eq "G3 kill-window -t s1:w1 whose session resolved to 's1x' is REFUSED" "$(ran_through)" no
assert_contains "G3 …naming the session redirect" "$out" "there is NO session named 's1'"
out=$(run_shim "${ONBOARD[@]}" STUB_RSESSION=s1x -- kill-window -t s1:)
assert_eq "G3 kill-window -t s1: (the session's current window) is REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RSESSION=s1x STUB_SESSIONS=2 -- kill-session -t s1)
assert_eq "G3 kill-session -t s1 resolved to 's1x' is REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RSESSION=s1x STUB_SESSIONS=2 -- kill-session -t s1.0)
assert_eq "G3 kill-session -t s1.0 (a window.pane word falls back to the session tier) is REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RSESSION=s1x -- send-keys -t s1: X)
assert_eq "G3 an ACT aimed at a session only (send-keys -t s1:) is judged — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RSESSION=s1x -- kill-window -a -t s1:keep)
assert_eq "G3 kill-window -a -t s1:keep is REFUSED — it would clear the WRONG session" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RSESSION=s1x STUB_SESSIONS=2 -- kill-session -a -t s1)
assert_eq "G3 kill-session -a -t s1 is REFUSED — it would kill EVERY OTHER session, the board's included" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=2 -- kill-session -a -t s1x)
assert_eq "G3 control: kill-session -a with an EXACT session still RUNS" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RSESSION=s1x -- kill-window -t '=s1:w1')
assert_eq "G3 control: '=s1:' is exact by construction — left to tmux, passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RSESSION=s1x -- kill-window -t '$3:w1')
assert_eq "G3 control: a \$id session is exact — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=2 -- kill-session -t s1x)
assert_eq "G3 control: an EXACT session name passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RSESSION=zz -- send-keys -t :=w1 X)
assert_eq "G3 control: an EMPTY session part (':=w1', the current session) is not judged — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RSESSION=s1x -- kill-window -t 's1*:w1')
assert_eq "G3 control: a glob session is a DELIBERATE pattern — passes" "$(ran_through)" yes

echo "=== merge4sk G2 — the session reading of a bare act target must PROVE itself ==="
# The old arm let any word naming the resolved SESSION through, BEFORE the
# mis-aim test. tmux tries the word as a WINDOW first, so with session `nx`
# holding `nx-fix`, `send-keys -t nx X` landed in `nx-fix` at rc 0.
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=nx-fix STUB_RSESSION=nx -- send-keys -t nx X)
assert_eq "G2 send-keys -t nx resolved to window 'nx-fix' (the WINDOW prefix tier won) is REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=nx-fix STUB_RSESSION=nx -- send-keys -t nx:nx X)
assert_eq "G2 send-keys -t nx:nx — a session:window word has no session reading — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=zsh STUB_RSESSION=nx -- send-keys -t nx.0 X)
assert_eq "G2 control: 'nx.0' resolved to session nx's window 'zsh' is the session reading (measured) — passes" "$(ran_through)" yes

echo "=== #1575 — an alias to an ACT verb is an act, and its CARRIED flags count ==="
# The resolver answered only "is this a KILL", so `nxs=send-keys` was never
# judged and its keys landed in the prefix-sibling at rc 0 (killsafe, 17b00ef0).
# PREDICTED FLIP SET for "an expansion is never classified as an act": the four
# REFUSED act-alias rows here and the three REAL alias rows flip; the kill-alias
# rows (F6/F8, and #1578's aliased kill) and the controls do not.
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_ALIASES='command-alias[99] "nxs=send-keys"' -- nxs -t w1 X)
assert_eq "#1575 nxs -t w1 (nxs=send-keys) resolved to 'w1-sk' is REFUSED" "$(ran_through)" no
assert_contains "#1575 …and the refusal names the alias as TYPED" "$out" "REFUSING \`nxs -t w1\`"
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_ALIASES='command-alias[98] "nxt=send-keys -t w1"' -- nxt X)
assert_eq "#1575 an alias that CARRIES its own -t (nxt=send-keys -t w1) is REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_ALIASES='command-alias[97] "nxp=paste-buffer -b nxb"' -- nxp -t w1)
assert_eq "#1575 an alias-carried VALUE flag (-b nxb) does not hide the caller's -t — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_ALIASES='command-alias[99] "nxs=send"' -- list-windows ';' nxs -t w1 X)
assert_eq "#1575 an alias to an act SHORT FORM, later in a sequence — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES='command-alias[99] "nxs=send-keys"' -- nxs -t w1 X)
assert_eq "#1575 control: the alias with an EXACT target passes" "$(ran_through)" yes
# THE NAME IS COMPARED BY EQUALITY. The old lookup was a sed regex `.*"?WORD=`,
# so `nxz` matched `anxz=list-windows` (listed first) and the kill alias PASSED —
# measured on a real server: the aliased `kill-window -t w1` killed `w1-sk`.
_eqtbl='command-alias[90] "anxz=list-windows"'$'\n''command-alias[91] "nxz=kill-server"'
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES="$_eqtbl" -- nxz)
assert_eq "ALIAS-EQ nxz (=kill-server) is not shadowed by an earlier 'anxz=' — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES="$_eqtbl" -- anxz)
assert_eq "ALIAS-EQ control: anxz (=list-windows) passes" "$(ran_through)" yes

echo "=== #1582 skeptic F1/F2 — the alias table is DECODED and its values TOKENISED as tmux does ==="
# Tables below are exactly how 2.6's `show -s command-alias` RENDERS them
# (measured): indexed, double-quoted, `"` as `\"`. F1: the first cut split
# values on whitespace, so a QUOTED verb was the word `"kill-server"` and the
# server DIED through it. F2: it split the table on every comma, which forged
# an entry out of another alias's value. PREDICTED FLIP SET against 63945c85:
# every REFUSED row in this block; the controls do not move.
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES='command-alias[50] "zq=\"kill-server\""' -- zq)
assert_eq "SK-F1 zq=\"kill-server\" (a double-QUOTED verb) is kill-server — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES="command-alias[50] \"zq='kill-server'\"" -- zq)
assert_eq "SK-F1 zq='kill-server' (a single-QUOTED verb) — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES='command-alias[50] "zq=kill-\"server\""' -- zq)
assert_eq "SK-F1 zq=kill-\"server\" (quoted pieces CONCATENATE) — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_ALIASES='command-alias[50] "zq=kill-window -t \"w1\""' -- zq)
assert_eq "SK-F1 a QUOTED alias-carried target (-t \"w1\") is judged — REFUSED" "$(ran_through)" no
assert_contains "SK-F1 …as w1, its quotes removed" "$out" "there is NO window named 'w1';"
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES="command-alias[50] \"zq=display-message -p 'a b'\"" -- zq)
assert_eq "SK-F1 control: a quoted NON-kill alias passes" "$(ran_through)" yes
_f2tbl='command-alias[40] "za=display -p x,zq=list-windows"'$'\n''command-alias[50] "zq=kill-server"'
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES="$_f2tbl" -- zq)
assert_eq "SK-F2 a comma in an EARLIER alias's value does not forge 'zq=list-windows' — zq (=kill-server) REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES="$_f2tbl" -- za)
assert_eq "SK-F2 control: za itself (=display …) passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES='command-alias "splitp=split-window,zq=kill-server"' -- zq)
assert_eq "SK-F2 an UNINDEXED one-string rendering is still split on commas — zq REFUSED" "$(ran_through)" no

echo "=== #1582 skeptic F3 — control mode must not blind the socket probe ==="
# `tmux -C kill-server` killed the board at rc 0 at f0809ada, f13cfb74 and
# 63945c85: the probe replayed -C, got `%begin …` first, and took the silent
# no-server arm. -C is no longer replayed, and an unparsed answer is LOUD.
# Asked as a NON-agent (CLAUDECODE=): an agent's -C is refused on the flag alone
# since #1583 F1, which would stop these rows reaching the probe they pin.
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- -C kill-server)
assert_eq "SK-F3 -C kill-server on the board — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- -2C kill-server)
assert_eq "SK-F3 -C bundled with another flag (-2C) — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- -C list-windows)
assert_eq "SK-F3 control: -C with a non-kill verb passes" "$(ran_through)" yes
out=$(run_shim STUB_SOCK=FRAMED NEXUS_TMUX_SOCKET="$BOARD" -- kill-server)
assert_eq "SK-F3 a server answering in an UNPARSED framing: still passes (never wedge)…" "$(ran_through)" yes
assert_contains "SK-F3 …but LOUDLY, as INERT — no longer the silent no-server arm" "$out" "cannot parse"

echo "=== #1583 F5 — COMMAND CARRIERS are refused on the board outright ==="
# Each of these was measured ending a board-pinned server at rc 0 through a shim
# that judged only argv (if-shell, source-file, set-hook + a later list-windows,
# -C attach fed kill-server on stdin), or carries tmux command text the same way.
# The nexus uses none of them (git grep over the tracked corpus). PREDICTED FLIP
# SET against 4bbfe878: every CARRIER row here; the controls do not move.
for _cv in 'if-shell true kill-server' 'if -F 1 kill-server' "run-shell 'tmux kill-server'" 'run true' \
           'source-file /tmp/x.conf' 'source /tmp/x.conf' 'set-hook -g after-list-windows kill-server' \
           'bind-key -n F12 kill-server' 'bind F12 kill-server' 'confirm-before kill-server' \
           'command-prompt' 'choose-tree' 'displayp' 'display-panes' 'menu x' 'popup'; do
    read -r -a _cva <<< "$_cv"
    out=$(run_shim "${ONBOARD[@]}" -- "${_cva[@]}")
    assert_eq "F5 carrier '$_cv' on the board is REFUSED" "$(ran_through)" no
done
assert_contains "F5 …and the refusal says it CARRIES commands the guard cannot see" "$out" "CARRIES tmux commands"
out=$(run_shim "${ONBOARD[@]}" -- -C attach -t p)
assert_eq "F5 -C attach (control mode reads commands from STDIN) is REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" -- set-hook -u -g after-list-windows)
assert_eq "F5 control: set-hook -u (UNSET) carries nothing — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" -- set -g status on)
assert_eq "F5 control: 'set' is set-option's ALIAS, not a prefix of set-hook — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" -- display -p ok)
assert_eq "F5 control: 'display' is display-message's ALIAS, not display-panes — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" -- attach -t p)
assert_eq "F5 control: attach WITHOUT -C reads no commands from stdin — passes" "$(ran_through)" yes
out=$(run_shim STUB_SOCK=/tmp/tmux-1/priv NEXUS_TMUX_SOCKET="$BOARD" -- -L priv if-shell true kill-server)
assert_eq "F5 control: a carrier on a PRIVATE socket is not our business" "$(ran_through)" yes

echo "=== #1583 F5 — carriers are an AGENT's accident: the operator and server jobs pass ==="
# Measured on the live board: every pane's ROOT process fronts this shim on PATH
# and none carries CLAUDECODE; nor does the server's global environment, which
# run-shell jobs, #() and new panes inherit. So without this carve-out, the
# operator's `tmux source-file` reload in any board pane — and, after
# tmux-server-path.sh --apply, a plugin job's `tmux bind-key` — were refused.
for _cv in 'source-file /home/op/.tmux.conf' 'bind-key -n F12 display ok' "run-shell /home/op/plugin.tmux" 'set-hook -g after-new-window display ok' '-C attach -t p'; do
    read -r -a _cva <<< "$_cv"
    out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- "${_cva[@]}")
    assert_eq "F5 carve-out: a NON-agent caller's '$_cv' passes (operator reload / plugin job)" "$(ran_through)" yes
done
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- set -s exit-unattached on)
assert_eq "F5 carve-out control: a LETHAL option is refused for EVERY caller, operator included" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= STUB_ALIASES='command-alias[50] "zz="' -- zz)
assert_eq "F5 carve-out control: the alias CRASH is refused for every caller" "$(ran_through)" no

echo "=== #1583 F5 — LETHAL NON-KILLS: exit-/destroy-unattached, unlink-window -k, move/link -k ==="
for _ov in 'set -s exit-unattached on' 'set -s exit-un on' 'set -s exit-unattached' \
           'set-option -g destroy-unattached on' 'set -gq destroy-unattached 1' 'set -t p destroy-unattached yes'; do
    read -r -a _ova <<< "$_ov"
    out=$(run_shim "${ONBOARD[@]}" -- "${_ova[@]}")
    assert_eq "F5 '$_ov' ENDS the server — REFUSED" "$(ran_through)" no
done
for _ov in 'set -s exit-unattached off' 'set -u -g destroy-unattached' 'set -g @exit-unattached on' 'set -s exit-empty on'; do
    read -r -a _ova <<< "$_ov"
    out=$(run_shim "${ONBOARD[@]}" -- "${_ova[@]}")
    assert_eq "F5 control: '$_ov' passes" "$(ran_through)" yes
done
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=1 -- unlink-window -k -t 0:1)
assert_eq "F5 unlink-window -k of the LAST window is a kill-window — Rule 3 REFUSES" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- unlinkw -kt w1)
assert_eq "F5 unlinkw -kt w1 resolved to 'w1-sk' — Rule 4 REFUSES (the getopt walk reads -kt)" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=1 -- unlink-window -t 0:1)
assert_eq "F5 control: unlink-window WITHOUT -k kills nothing — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- move-window -k -s a:src -t w1)
assert_eq "F5 move-window -k: the DESTINATION prefix-redirects to 'w1-sk' — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- linkw -k -s q:qq -t a:w1)
assert_eq "F5 linkw -k onto a prefix-redirected destination — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk -- move-window -d -s a:src -t w1)
assert_eq "F5 control: move-window WITHOUT -k (bootstrap-recover.sh's shape) is not judged — passes" "$(ran_through)" yes

echo "=== #1583 F4 — an =name target gets Rule 3 (the probe is respelled) ==="
PL="$WORK/probelog"
: > "$PL"; out=$(run_shim "${ONBOARD[@]}" STUB_PROBE_LOG="$PL" STUB_SESSIONS=1 STUB_WINDOWS=1 -- kill-window -t =base)
assert_eq "F4 kill-window -t =base, the LAST window — REFUSED (display-message rejects bare =name)" "$(ran_through)" no
assert_contains "F4 …the probe asked ':=base', a spelling display-message accepts" "$(cat "$PL")" ":=base"
: > "$PL"; out=$(run_shim "${ONBOARD[@]}" STUB_PROBE_LOG="$PL" STUB_SESSIONS=1 STUB_WINDOWS=1 -- kill-session -t =p)
assert_eq "F4 kill-session -t =p, the ONLY session — REFUSED" "$(ran_through)" no
assert_contains "F4 …the probe asked '=p:'" "$(cat "$PL")" "=p:"
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=12 -- kill-window -t =other)
assert_eq "F4 control: kill-window -t =other with 12 windows RUNS" "$(ran_through)" yes

echo "=== #1583 F6 — a bare digit on a PANE-type verb names a pane of the current window ==="
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=base STUB_RINDEX=0 STUB_RPANE=1 STUB_RACTIVE=1 STUB_RWID=@5 STUB_CWID=@5 -- select-pane -t 1)
assert_eq "F6 select-pane -t 1 resolved to PANE 1 of the CURRENT window — passes (was over-refused)" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_SESSIONS=1 STUB_WINDOWS=3 STUB_PANES=2 STUB_RNAME=base STUB_RINDEX=0 STUB_RPANE=1 STUB_RACTIVE=1 STUB_RWID=@5 STUB_CWID=@5 -- kill-pane -t 1)
assert_eq "F6 kill-pane -t 1 on pane 1 of the current window RUNS" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=1-sk STUB_RINDEX=5 STUB_RPANE=0 STUB_RACTIVE=0 -- send-keys -t 1 X)
assert_eq "F6 control: send-keys -t 1 that prefix-redirected to '1-sk' is still REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=1-sk STUB_RINDEX=5 STUB_RPANE=1 STUB_RACTIVE=0 STUB_RWID=@9 STUB_CWID=@5 -- send-keys -t 1 X)
assert_eq "F6 control: pane index 1 in a window that is NOT the current one proves nothing — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=base STUB_RINDEX=0 STUB_RPANE=1 STUB_RACTIVE=1 STUB_RWID=@5 STUB_CWID=@5 -- kill-window -t 1)
assert_eq "F6 control: kill-window is WINDOW-type (no pane tier) — the exemption does not apply, REFUSED" "$(ran_through)" no

echo "=== #1583 D1-D3 — the alias tokeniser (semisplitsk delta on #1582) ==="
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES='command-alias[50] "zq=X=1 kill-server"' -- zq)
assert_eq "D1 a leading NAME=value word is an ENV assignment: zq=X=1 kill-server — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES='command-alias[50] "zq=\"X=1\" kill-server"' -- zq)
assert_eq "D1 …quoted, \"X=1\" — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=w1-sk STUB_ALIASES='command-alias[50] "zq=A=b C=d kill-window -t w1"' -- zq)
assert_eq "D1 …two of them before a mis-aimed kill-window — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES='command-alias[50] "zq=\"X Y=1\" kill-server"' -- zq)
assert_eq "D1 control: \"X Y=1\" has a space BEFORE its '=' — not dropped, the verb is unknown — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES='command-alias[50] "zq=X=1 display-message -p ok"' -- zq)
assert_eq "D1 control: zq=X=1 display-message — passes" "$(ran_through)" yes
for _zv in 'zz=' 'zz=X=1' 'zz=#c'; do
    out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES="command-alias[50] \"$_zv\"" -- zz)
    assert_eq "CRASH alias '$_zv' invoked bare expands to NOTHING — tmux 2.6 crashes — REFUSED" "$(ran_through)" no
done
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES='command-alias[50] "zz="' -- zz list-windows)
assert_eq "CRASH control: the same alias WITH an argument runs that argument — passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" STUB_ALIASES='command-alias[50] "z\011q=kill-server"' -- "z	q")
assert_eq "D2 an alias NAME holding a TAB (rendered \\011) is decoded before any skip — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_SENV='NXV=kill-server' STUB_ALIASES='command-alias[50] "zq=$NXV"' -- zq)
assert_eq "D3 \$NXV expands from the SERVER's global environment (=kill-server) — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" NXV=kill-server STUB_SENV='NXV=list-windows' STUB_ALIASES='command-alias[50] "zq=$NXV"' -- zq)
assert_eq "D3 control: the CALLER's \$NXV (=kill-server) is not what tmux reads — the server's (=list-windows) is — passes" "$(ran_through)" yes

echo "=== #1583 delta (semisplitsk2 F1) — an AGENT's control mode is refused on the flag, before the no-command exit ==="
# Each of the first three read `kill-server` from stdin and ended a board-pinned
# server at rc 0 through 4bbfe878, ff9f8a55 and 8c9c3aa9; the bare `-C` never
# reached a rule at all (it left through the no-command exec). PREDICTED FLIP SET
# against 8c9c3aa9: the five agent refusals. The controls do not move.
for _cv in '-C' '-CC' '-C new-session -s q' '-C new -A -s p' '-2C list-windows'; do
    read -r -a _cva <<< "$_cv"
    out=$(run_shim "${ONBOARD[@]}" -- "${_cva[@]}")
    assert_eq "F1 an AGENT's '$_cv' on the board is REFUSED (control mode reads commands from stdin)" "$(ran_through)" no
done
assert_contains "F1 …and the refusal names control mode" "$out" "control mode"
# Claude Code's own `--tmux` launcher runs `tmux -CC attach-session -t <s>` from
# its MAIN process for a human in iTerm2 (measured in the 2.1.273 binary), and
# that process carries no CLAUDECODE. It must keep working.
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- -CC attach-session -t p)
assert_eq "F1 control: Claude Code's --tmux launcher shape (-CC attach-session, NO CLAUDECODE) passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- -C)
assert_eq "F1 control: a non-agent's bare -C passes (the human's control client)" "$(ran_through)" yes
out=$(run_shim STUB_SOCK=/tmp/tmux-1/priv NEXUS_TMUX_SOCKET="$BOARD" -- -L priv -C)
assert_eq "F1 control: an agent's -C on a PRIVATE socket is not our business" "$(ran_through)" yes

echo "=== #1583 delta (semisplitsk2 F2) — the pane-digit exemption is proved by window_id EQUALITY ==="
# tmux 2.6's LAST tier is the SESSION fallback, which lands on ANOTHER session's
# current window — an ACTIVE window with pane N. The #{window_active} proof passed
# it (8c9c3aa9 killed `1s:far.1` via `kill-pane -t 1`); 4bbfe878 refused it.
# PREDICTED FLIP SET against 8c9c3aa9: these two refusals (they carry
# STUB_RACTIVE=1, the only fact that shim reads).
CW="$WORK/cwid-count"
: > "$CW"; out=$(run_shim "${ONBOARD[@]}" STUB_CWID_LOG="$CW" STUB_SESSIONS=2 STUB_WINDOWS=1 STUB_PANES=2 STUB_RNAME=far STUB_RINDEX=0 STUB_RPANE=1 STUB_RACTIVE=1 STUB_RWID=@9 STUB_CWID=@5 -- kill-pane -t 1)
assert_eq "F2 kill-pane -t 1 resolved to pane 1 of an ACTIVE window that is NOT the current one (@9 vs @5) — REFUSED" "$(ran_through)" no
assert_eq "F2 …the untargeted current-window probe was asked exactly once" "$(wc -l < "$CW" | tr -d ' ')" 1
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=far STUB_RINDEX=0 STUB_RPANE=1 STUB_RACTIVE=1 STUB_RWID=@9 STUB_CWID=@5 -- send-keys -t 1 X)
assert_eq "F2 send-keys -t 1 into another session's current window — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" STUB_RNAME=far STUB_RINDEX=0 STUB_RPANE=1 STUB_RACTIVE=1 STUB_RWID=@9 STUB_CWID= -- send-keys -t 1 X)
assert_eq "F2 control: an EMPTY current-window answer proves nothing — REFUSED" "$(ran_through)" no

echo "=== #1583 delta (semisplitsk2 F3) — set-window-option sets the lethal options too ==="
# PREDICTED FLIP SET against 8c9c3aa9: the four refusals.
for _ov in 'setw -g exit-unattached on' 'set-window-option exit-unattached on' 'setw -g destroy-unattached on' 'setw -g exit-un'; do
    read -r -a _ova <<< "$_ov"
    out=$(run_shim "${ONBOARD[@]}" -- "${_ova[@]}")
    assert_eq "F3 '$_ov' ENDS the server — REFUSED" "$(ran_through)" no
done
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- setw -g exit-unattached on)
assert_eq "F3 …and for a NON-agent caller too" "$(ran_through)" no
for _ov in 'setw -g exit-unattached off' 'setw -g mode-keys vi' 'setw -u -g destroy-unattached'; do
    read -r -a _ova <<< "$_ov"
    out=$(run_shim "${ONBOARD[@]}" -- "${_ova[@]}")
    assert_eq "F3 control: '$_ov' passes" "$(ran_through)" yes
done

echo "=== #1583 delta (semisplitsk2 F4) — the CARRIED text is judged for EVERY caller ==="
# The carve-out (8c9c3aa9) refused carriers for agents only, and every carrier but
# run-shell runs its payload INSIDE the server, so a caller without CLAUDECODE was
# unguarded for them before AND after tmux-server-path.sh --apply. MEASURED at
# 8c9c3aa9 as a non-agent on a hermetic board-pinned server: if-shell, if -F,
# source-file (incl. a continued line), set-hook + a later list-windows, a nested
# if-shell, a carried lethal option and an alias-carried kill-server each ENDED
# it. PREDICTED FLIP SET against 8c9c3aa9: every refusal row in this block; every
# control holds.
printf 'set -g @nxok loaded\nkill-server\n' > "$WORK/kill.conf"
printf 'set -g @nxok a \\\n  ; kill-server\n' > "$WORK/cont.conf"
printf 'set -g @nxok loaded\nbind-key x confirm-before kill-pane\nset-hook -g after-new-window "display-message ok"\n' > "$WORK/benign.conf"
printf 'source-file %s\n' "$WORK/self.conf" > "$WORK/self.conf"
printf 'set -g @a 1\nsource-file %s\n' "$WORK/cyc-b.conf" > "$WORK/cyc-a.conf"
printf 'source-file %s\n' "$WORK/cyc-a.conf" > "$WORK/cyc-b.conf"
# 12 nested if-shell payloads under a typed one: 13 carriers, past the depth cap of 8.
_n=0; _deep=kill-server; while (( _n < 12 )); do _deep="if-shell true \"$(printf '%s' "$_deep" | sed 's/\\/\\\\/g; s/"/\\"/g')\""; _n=$(( _n + 1 )); done
for _cv in 'if-shell true kill-server' 'if -F 1 kill-server' 'if-shell false list-windows kill-server' \
           "source-file $WORK/kill.conf" "source $WORK/cont.conf" 'set-hook -g after-list-windows kill-server' \
           'bind-key -T nxt x kill-server' 'confirm-before kill-server' 'command-prompt kill-server' \
           'choose-tree kill-server' 'display-panes kill-server' "if-shell true 'kill-window'"; do
    eval "_cva=( $_cv )"
    out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- "${_cva[@]}")
    assert_eq "F4 a NON-agent's '$_cv' — the carried command is judged — REFUSED" "$(ran_through)" no
done
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- if-shell true 'if-shell true kill-server')
assert_eq "F4 a NESTED carrier unfolds too — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- if-shell true 'set -g @x 1 ; kill-server')
assert_eq "F4 the carried string is split at ' ; ' as tmux splits it — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- bind-key -T nxt x display ok '\;' kill-server)
assert_eq "F4 bind-key's ARGV payload split at a literal ';' — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- if-shell true 'setw -g exit-unattached on')
assert_eq "F4 a carried LETHAL OPTION — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= STUB_ALIASES='command-alias[50] "zq=kill-server"' -- if-shell true zq)
assert_eq "F4 a carried word is ALIAS-resolved like a typed one (zq=kill-server) — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= STUB_SENV='NXV=kill-server' -- if-shell true '$NXV')
assert_eq "F4 a carried \$VAR expands from the SERVER's environment — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= STUB_RNAME=w1-sk -- if-shell true 'kill-window -t w1')
assert_eq "F4 a carried kill that prefix-redirects (Rule 4) — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= STUB_SESSIONS=1 STUB_WINDOWS=1 -- if-shell true 'kill-window -t 0:1')
assert_eq "F4 a carried kill of the LAST window (Rule 3) — REFUSED" "$(ran_through)" no
# A source-file CYCLE: tmux 2.6 loops for ever (measured: 99% CPU, deaf to every
# tmux command and to SIGTERM; it took a SIGKILL). Refused for EVERY caller.
# Stub rows ONLY, deliberately: a fail-open here would WEDGE a real server.
for _cc in 1 ''; do
    out=$(run_shim "${ONBOARD[@]}" CLAUDECODE="$_cc" -- source-file "$WORK/self.conf")
    assert_eq "F4 CYCLE: a self-sourcing file (CLAUDECODE='$_cc') — REFUSED" "$(ran_through)" no
done
assert_contains "F4 CYCLE …named as the loop it is" "$out" "own source chain"
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- source-file "$WORK/cyc-a.conf")
assert_eq "F4 CYCLE: a -> b -> a — REFUSED" "$(ran_through)" no
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- if-shell true "source-file $WORK/self.conf")
assert_eq "F4 CYCLE: reached through if-shell — REFUSED" "$(ran_through)" no
# Controls: the operator's ordinary reloads, bindings and hooks keep working.
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- source-file "$WORK/benign.conf")
assert_eq "F4 control: a NON-agent's config reload holding 'bind x confirm-before kill-pane' passes (a human presses x)" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- bind-key x kill-pane)
assert_eq "F4 control: an INTERACTIVE carried kill-pane (untargeted) passes — Rules 2-4 are the human's aim" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= STUB_SESSIONS=1 STUB_WINDOWS=12 -- if-shell true 'kill-window -t 0:7')
assert_eq "F4 control: a carried targeted kill-window on a 12-window session RUNS" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- if-shell true 'display-message ok')
assert_eq "F4 control: a carried display-message passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- source-file "$WORK/no-such.conf")
assert_eq "F4 control: an UNREADABLE file passes (tmux, same uid and path, cannot read it either)" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- set-hook -g after-new-window 'display-message ok')
assert_eq "F4 control: a benign hook passes" "$(ran_through)" yes
out=$(run_shim "${ONBOARD[@]}" CLAUDECODE= -- if-shell true "$_deep")
assert_eq "F4 BOUND: 13 nested carriers exceed the depth cap — passes (policy: never wedge)…" "$(ran_through)" yes
assert_contains "F4 BOUND …but LOUDLY, as INERT for what was not judged" "$out" "NOT judged"
out=$(run_shim "${ONBOARD[@]}" -- if-shell true 'display-message ok')
assert_eq "F4 control: an AGENT's carrier is still refused OUTRIGHT, payload or not" "$(ran_through)" no

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
    # +5 for the #1524 row-A block (premise, refusal, survival, control, exact form).
    # MERGED (#1554 onto #1553): base 19, #1553 +9 -> 28, #1554 +5 -> 24; the two
    # legs are disjoint blocks, so 19 + 9 + 5 = 33 — confirmed by this suite's
    # own ran-vs-expected check on the merged tree.
    # +4 for the #1524 ACT rows (refusal, keys-did-not-land, premise, control) -> 37.
    # +2 for skeptic F3 on the real server (kill-pane -t w1.0: refusal, survival) -> 39.
    # +2 for delta skeptic G1 on the real server (-tbot: refusal, keys-did-not-land) -> 41.
    # +2 for delta skeptic H1 on the real server (pa -b nxb -t w1: refusal, not pasted) -> 43.
    # +2 for merge4's all-digit finding on the real server (refusal, keys-did-not-land) -> 45.
    # +11 for #1578 and its bundle on a second private server (separator x2, G3 x2,
    # G2 x2 + premise, #1575 x2 + control, separator mis-aim x2) -> 57.
    # +7 for #1582 skeptic F1/F2/F3 on fresh servers (F1 x2, F2 x2, F3 x2 + control) -> 64.
    # +18 for #1583 on real servers (F5 x6, F4 x2, D1 x2, crash x2, F6 x1, server-path x5) -> 82.
    # +3 for the carve-out on real servers (agent reload refused, operator reload acts, plugin bind-key after --apply) -> 85.
    # +10 for the semisplitsk2 delta on real servers (F1 x2, F2 x2, F3 x2, F4 x4) -> 95.
    REAL_LEG=95
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

    # --- your-org/nexus-code#1550: the refusal must STOP the caller, and the
    # orchestrator must learn of it. #1550's evaluator was refused FIVE TIMES
    # in 33 seconds and kept going, so both halves are pinned here:
    #   (i)  the message states plainly that this cannot be attempted, and says
    #        so BEFORE it mentions any escape hatch. Ordering is the fix — the
    #        old text closed on two recipes and read as a syntax correction.
    #   (ii) one request per un-acked incident reaches the inbox, and the
    #        SECOND refusal adds a LOG row without adding a second request.
    # The inbox is the fixture's ($NEXUS_STATE_DIR is pinned at the top of this
    # file), so nothing here reaches the live orchestrator.
    rm -rf "$NEXUS_STATE_DIR/requests" "$NEXUS_STATE_DIR/tmux-refused.log"
    out=$(real_shim kill-server)
    assert_contains "#1550: the refusal says plainly that this CANNOT be attempted" \
        "$out" "THIS CANNOT BE ATTEMPTED"
    # ONE awk pass, and deliberately NO `head`/`grep -m`/`awk exit`: an
    # early-exit reader in a TEST joins `early-exit-readers.manifest`, whose
    # guard then asks whether the writer's EPIPE can invert a consumed pipeline
    # status (#622). Not answering that question at all is cheaper than
    # answering it, and one pass computes both line numbers anyway.
    _v_ord=$(printf '%s\n' "$out" | awk '
        /THIS CANNOT BE ATTEMPTED/ && !s { s = NR }
        /TMUX_UNWRAPPED=1/         && !h { h = NR }
        END { print (s && h && s < h) ? "ordered" : "stop=" s " hatch=" h }')
    assert_eq "#1550: …and it says it BEFORE naming any escape hatch (ordering IS the fix)" \
        "$_v_ord" ordered
    # A COUNT THAT CANNOT GO BARE (test-nullglob-bare-form-manifest.sh): this glob
    # is EMPTY by design until the refusal files its request, and under nullglob
    # an `ls <glob>` that matches nothing lists the CWD instead — a wrong count at
    # rc 0. nullglob can reach this shell through BASH_ENV's operator-supplied
    # NEXUS_PREV_BASH_ENV chain, which no reading of this repo can rule out, so
    # the site is removed rather than argued safe: find takes the pattern as DATA.
    _v_req() { find "$NEXUS_STATE_DIR/requests" -maxdepth 1 -name '*board-kill-refused*.md' 2>/dev/null | wc -l | tr -d ' '; }
    assert_eq "#1550: the refusal filed ONE orchestrator request" "$(_v_req)" 1
    out=$(real_shim kill-server)
    assert_eq "#1550: a SECOND refusal files NO second request (the flood guard)" "$(_v_req)" 1
    assert_contains "#1550: …and says so, rather than silently dropping it" \
        "$out" "already holds an un-acked board-kill report"
    assert_eq "#1550: …while the LOG carries both, so the count is not lost" \
        "$(wc -l < "$NEXUS_STATE_DIR/tmux-refused.log" | tr -d ' ')" 2
    # THE ORDERING ASSERTION ABOVE PINS *BEFORE*, NEVER *NOT-AT-THE-TAIL*
    # (#1553 skeptic F3), and those are different claims: in a DEGRADED
    # configuration the reporting line used to be skipped, so the message fell
    # back to ending on `Override: TMUX_UNWRAPPED=1` — exactly the shape the
    # rewrite exists to remove — while the line-index comparison stayed green.
    # Both the healthy and a degraded tail are pinned here.
    _v_tail() { printf '%s\n' "$1" | awk 'NF{l=$0} END{print (l ~ /TMUX_UNWRAPPED=1/) ? "ENDS-ON-HATCH" : "ok"}'; }
    assert_eq "#1550: the refusal never ENDS on the escape hatch (healthy path)" "$(_v_tail "$out")" ok
    # Degraded: the inbox cannot be WRITTEN, so the channel fails and the
    # reporting line must SAY so rather than be omitted. The pending request
    # from above is cleared first — otherwise the dedup arm answers and this
    # case never reaches the failure path it exists to pin.
    rm -f "$NEXUS_STATE_DIR/requests"/*board-kill-refused*.md 2>/dev/null || true
    chmod a-w "$NEXUS_STATE_DIR/requests" 2>/dev/null || true
    _v_deg=$(real_shim kill-server)
    chmod u+w "$NEXUS_STATE_DIR/requests" 2>/dev/null || true
    assert_eq "#1550: …and does not end on it when the request channel FAILS either" "$(_v_tail "$_v_deg")" ok
    assert_contains "#1550: …the degraded tail says the orchestrator could not be told" \
        "$_v_deg" "could NOT be told"

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

    # --- #1524 row A, on a REAL server: `w1` absent, `w1-sk` present. ---------
    # FIRST the premise, measured here rather than assumed: with NO shim, tmux
    # itself resolves `w1` to `w1-sk` — if this host's tmux ever stops doing
    # that, the refusal below is unexercised and this row says so.
    env -u TMUX tmux -L "$SOCK" new-window -d -t a -n w1-sk >/dev/null 2>&1
    env -u TMUX tmux -L "$SOCK" new-window -d -t a -n bystander >/dev/null 2>&1
    assert_eq "REAL #1524 premise: bare tmux resolves '-t w1' to the sibling 'w1-sk' (the redirect exists on this tmux)" \
        "$(env -u TMUX tmux -L "$SOCK" display-message -p -t w1 '#{window_name}' 2>/dev/null)" w1-sk
    # The ACT verbs first, while `w1-sk` is still pristine: a refused send-keys
    # must leave NOTHING in the sibling's pane.
    out=$(real_shim send-keys -t w1 -l NXREFUSEDKEYS)
    assert_contains "REAL #1524: send-keys -t w1 with only 'w1-sk' present is REFUSED" "$out" "would have ACTED ON THAT"
    sleep 0.5
    assert_eq "REAL #1524: …and the keys did NOT land in 'w1-sk'" \
        "$(env -u TMUX tmux -L "$SOCK" capture-pane -p -t :=w1-sk 2>/dev/null | grep -c NXREFUSEDKEYS)" 0
    # PREMISE for the two rows above, measured with NO shim: the same keys DO
    # land in the sibling. Without this the refusal could be guarding nothing.
    env -u TMUX tmux -L "$SOCK" send-keys -t w1 -l NXPREMISEKEYS >/dev/null 2>&1
    _landed=0; for _i in 1 2 3 4 5 6 7 8; do
        _landed=$(env -u TMUX tmux -L "$SOCK" capture-pane -p -t :=w1-sk 2>/dev/null | grep -c NXPREMISEKEYS); (( _landed > 0 )) && break; sleep 0.25
    done
    assert_eq "REAL #1524 premise: bare tmux send-keys -t w1 types into the sibling 'w1-sk'" "$(( _landed > 0 ))" 1
    # delta skeptic G1, on the REAL server: a glued target ending in t. `botsk` is
    # present, `bot` is not. At d18510ca these keys LANDED in botsk at rc 0.
    env -u TMUX tmux -L "$SOCK" new-window -d -t a -n botsk >/dev/null 2>&1
    out=$(real_shim send-keys -tbot -l NXGLUEDKEYS)
    assert_contains "REAL G1: send-keys -tbot with only 'botsk' present is REFUSED" "$out" "DIFFERENT window, 'botsk'"
    sleep 0.5
    assert_eq "REAL G1: …and the keys did NOT land in 'botsk'" \
        "$(env -u TMUX tmux -L "$SOCK" capture-pane -p -t :=botsk 2>/dev/null | grep -c NXGLUEDKEYS)" 0
    env -u TMUX tmux -L "$SOCK" kill-window -t :=botsk >/dev/null 2>&1
    # delta skeptic H1, on the REAL server: an ABBREVIATED paste-buffer with its -b
    # value. `w1-sk` present, `w1` absent. At ca7310aa this paste LANDED at rc 0.
    env -u TMUX tmux -L "$SOCK" set-buffer -b nxb NXH1PASTE >/dev/null 2>&1
    out=$(real_shim pa -b nxb -t w1)
    assert_contains "REAL H1: 'pa -b nxb -t w1' with only 'w1-sk' present is REFUSED" "$out" "DIFFERENT window, 'w1-sk'"
    sleep 0.5
    assert_eq "REAL H1: …and the buffer was NOT pasted into 'w1-sk'" \
        "$(env -u TMUX tmux -L "$SOCK" capture-pane -p -t :=w1-sk 2>/dev/null | grep -c NXH1PASTE)" 0
    # merge4's finding, on the REAL server: an all-digit word with NO such index.
    # `1566-sk` present; nothing named or indexed 1566. At 17b00ef0 these keys LANDED.
    env -u TMUX tmux -L "$SOCK" new-window -d -t a -n 1566-sk >/dev/null 2>&1
    out=$(real_shim send-keys -t 1566 -l NXDIGITKEYS)
    assert_contains "REAL DIGITS: send-keys -t 1566 with only '1566-sk' present is REFUSED" "$out" "DIFFERENT window, '1566-sk'"
    sleep 0.5
    assert_eq "REAL DIGITS: …and the keys did NOT land in '1566-sk'" \
        "$(env -u TMUX tmux -L "$SOCK" capture-pane -p -t :=1566-sk 2>/dev/null | grep -c NXDIGITKEYS)" 0
    env -u TMUX tmux -L "$SOCK" kill-window -t :=1566-sk >/dev/null 2>&1
    # skeptic F3, on the REAL server: the `name.N` spelling.
    out=$(real_shim kill-pane -t w1.0)
    assert_contains "REAL F3: kill-pane -t w1.0 with only 'w1-sk' present is REFUSED" "$out" "DIFFERENT window, 'w1-sk'"
    assert_eq "REAL F3: …and 'w1-sk' is STILL THERE" \
        "$(env -u TMUX tmux -L "$SOCK" list-windows -t a -F '#{window_name}' 2>/dev/null | grep -cx 'w1-sk')" 1
    out=$(real_shim kill-window -t w1)
    assert_contains "REAL #1524: kill-window -t w1 with only 'w1-sk' present is REFUSED" "$out" "DIFFERENT window, 'w1-sk'"
    assert_eq "REAL #1524: …and 'w1-sk' is STILL THERE (the refusal actually saved it)" \
        "$(env -u TMUX tmux -L "$SOCK" list-windows -t a -F '#{window_name}' 2>/dev/null | grep -cx 'w1-sk')" 1
    # POSITIVE CONTROL: the same command ACTS when the exact window exists.
    env -u TMUX tmux -L "$SOCK" new-window -d -t a -n w1 >/dev/null 2>&1
    out=$(real_shim send-keys -t w1 -l NXCONTROLKEYS)
    _landed=0; for _i in 1 2 3 4 5 6 7 8; do
        _landed=$(env -u TMUX tmux -L "$SOCK" capture-pane -p -t :=w1 2>/dev/null | grep -c NXCONTROLKEYS); (( _landed > 0 )) && break; sleep 0.25
    done
    assert_eq "REAL #1524 act control: with 'w1' present the same send-keys RUNS and lands in 'w1'" "$(( _landed > 0 ))" 1
    out=$(real_shim kill-window -t w1)
    # Asserted on the two names the case is ABOUT, not on the whole listing: the
    # session's first window is named after whatever shell the host started it
    # with (`sh` here, something else in CI), which is not this case's business.
    _names=$(env -u TMUX tmux -L "$SOCK" list-windows -t a -F '#{window_name}' 2>/dev/null)
    assert_eq "REAL #1524 control: with 'w1' present the same command kills exactly 'w1' and leaves 'w1-sk'" \
        "w1=$(grep -cx 'w1' <<<"$_names") w1-sk=$(grep -cx 'w1-sk' <<<"$_names")" "w1=0 w1-sk=1"
    # …and the prescribed exact form, through the shim, kills the sibling when
    # the sibling is what is NAMED. Leaves the fixture as the legs below expect.
    out=$(real_shim kill-window -t :=w1-sk); out=$(real_shim kill-window -t :=bystander)
    assert_eq "REAL #1524: ':=name' through the shim acts on exactly the named window" \
        "$(env -u TMUX tmux -L "$SOCK" list-windows -t a 2>/dev/null | wc -l | tr -d ' ')" 1

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

    # --- #1578 and its bundle, on a REAL server of their own ----------------
    # A second private server, so these rows neither depend on nor disturb the
    # fixture state the rows above and below share. Fixture: session `p` with
    # `base`, `w1-sk`, `nx-fix`; session `s1x`; NO window `w1`, NO session `s1`.
    SEMI_SOCK="semi$$"
    th_require_tmux_socket "$SEMI_SOCK"
    PRIV_SOCKETS+=("$SEMI_SOCK")
    start_server env -u TMUX tmux -f "$TMUXCONF" -L "$SEMI_SOCK" new-session -d -s p -n base >/dev/null 2>&1
    SEMI_PATH=$(env -u TMUX tmux -L "$SEMI_SOCK" display-message -p '#{socket_path}' 2>/dev/null)
    abort_if_board "$SEMI_PATH" "run the #1578 real-server rows"
    semi() { env -u TMUX tmux -L "$SEMI_SOCK" "$@"; }
    semi_shim() {   # an AGENT caller (CLAUDECODE=1), like run_shim; SEMI_AS_OPERATOR=1 drops it
        env -u TMUX PATH="$SHIM_DIR:/usr/bin:/bin:$PATH" NEXUS_TMUX_SOCKET="$SEMI_PATH" \
            CLAUDECODE="$([ "${SEMI_AS_OPERATOR:-0}" = 1 ] || echo 1)" \
            "$SHIM_DIR/tmux" -L "$SEMI_SOCK" "$@" 2>&1
    }
    semi_alive() { semi list-sessions >/dev/null 2>&1 && echo alive || echo dead; }
    semi_has() { semi list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep -cxF "$1"; }
    semi_keys() {   # <pane-target> <marker> -> count after a bounded wait
        local n=0 i; for i in 1 2 3 4; do
            n=$(semi capture-pane -p -t "$1" 2>/dev/null | grep -c "$2"); (( n > 0 )) && break; sleep 0.25
        done; printf '%s' "$n"
    }
    semi new-window -d -t p -n w1-sk >/dev/null 2>&1
    semi new-window -d -t p -n nx-fix >/dev/null 2>&1
    semi new-session -d -s s1x -n keep >/dev/null 2>&1
    semi set -s 'command-alias[99]' 'nxs=send-keys' >/dev/null 2>&1

    semi new-session -d -s nx -n nx >/dev/null 2>&1
    semi rename-window -t nx:nx base >/dev/null 2>&1
    semi new-window -d -t nx -n nx-fix2 >/dev/null 2>&1
    assert_eq "REAL G2 premise: bare tmux resolves '-t nx' to the WINDOW 'nx-fix2', not to session nx" \
        "$(semi display-message -p -t nx '#{window_name}' 2>/dev/null)" nx-fix2
    out=$(semi_shim send-keys -t nx -l NXG2KEYS)
    assert_contains "REAL G2: send-keys -t nx with window 'nx-fix2' in session nx is REFUSED" "$out" "REFUSING"
    assert_eq "REAL G2: …and the keys did NOT land in 'nx-fix2'" "$(semi_keys nx:nx-fix2 NXG2KEYS)" 0
    out=$(semi_shim nxs -t p:w1 -l NXALIASKEYS)
    assert_contains "REAL #1575: nxs -t p:w1 (nxs=send-keys) is REFUSED" "$out" "DIFFERENT window, 'w1-sk'"
    assert_eq "REAL #1575: …and the keys did NOT land in 'w1-sk'" "$(semi_keys p:w1-sk NXALIASKEYS)" 0
    out=$(semi_shim nxs -t p:base -l NXALIASOK)
    assert_eq "REAL #1575 control: the alias with an EXACT target ACTS" "$(semi_keys p:base NXALIASOK)" 1
    # THE DESTRUCTIVE ROWS COME LAST, in this order: against the pre-fix shim each
    # of them really kills its target (measured), so any row placed after one
    # would pass or fail for THAT reason instead of its own.
    out=$(semi_shim kill-session -t s1)
    assert_contains "REAL G3: kill-session -t s1 with only 's1x' present is REFUSED" "$out" "DIFFERENT session, 's1x'"
    assert_eq "REAL G3: …and 's1x' is STILL THERE" "$(semi_has s1x:keep)" 1
    out=$(semi_shim display-message 'hi;' kill-window -t p:w1)
    assert_contains "REAL #1578: a mis-aimed kill-window behind 'hi;' is REFUSED" "$out" "DIFFERENT window, 'w1-sk'"
    assert_eq "REAL #1578: …and 'w1-sk' is STILL THERE" "$(semi_has p:w1-sk)" 1
    # LAST, because against the pre-fix shim it KILLS this server (measured) and
    # every row after it would then fail for that reason instead of its own.
    out=$(semi_shim display-message 'hi;' kill-server)
    assert_contains "REAL #1578: display-message 'hi;' kill-server is REFUSED" "$out" "REFUSING \`kill-server\`"
    assert_eq "REAL #1578: …and the server is STILL ALIVE (at f13cfb74 it died, rc 0)" "$(semi_alive)" alive
    # #1582 skeptic F1/F2/F3, each on a FRESH server of its own: against
    # 63945c85 every one of them kills it (measured), so a shared server would
    # make every row after the first fail for that reason instead of its own.
    semi_fresh() {
        semi kill-server >/dev/null 2>&1 || true
        start_server env -u TMUX tmux -f "$TMUXCONF" -L "$SEMI_SOCK" new-session -d -s p -n base >/dev/null 2>&1
        SEMI_PATH=$(semi display-message -p '#{socket_path}' 2>/dev/null)
        abort_if_board "$SEMI_PATH" "run the #1582 skeptic rows"
    }
    semi_fresh; semi set -s 'command-alias[50]' 'zq="kill-server"' >/dev/null 2>&1
    out=$(semi_shim zq)
    assert_contains "REAL SK-F1: an alias to a QUOTED \"kill-server\" is REFUSED" "$out" "REFUSING"
    assert_eq "REAL SK-F1: …and the server is STILL ALIVE (at 63945c85 it died, rc 0)" "$(semi_alive)" alive
    semi_fresh; semi set -s 'command-alias[40]' 'za=display -p x,zq=list-windows' >/dev/null 2>&1
    semi set -s 'command-alias[50]' 'zq=kill-server' >/dev/null 2>&1
    out=$(semi_shim zq)
    assert_contains "REAL SK-F2: zq=kill-server behind a comma-forged 'zq=list-windows' is REFUSED" "$out" "REFUSING"
    assert_eq "REAL SK-F2: …and the server is STILL ALIVE" "$(semi_alive)" alive
    semi_fresh
    out=$(SEMI_AS_OPERATOR=1 semi_shim -C list-windows < /dev/null)
    assert_contains "REAL SK-F3 control: -C list-windows passes (control-mode framing)" "$out" "%begin"
    out=$(SEMI_AS_OPERATOR=1 semi_shim -C kill-server < /dev/null)
    assert_contains "REAL SK-F3: -C kill-server is REFUSED" "$out" "REFUSING \`kill-server\`"
    assert_eq "REAL SK-F3: …and the server is STILL ALIVE (dead at f0809ada, f13cfb74, 63945c85)" "$(semi_alive)" alive
    # --- #1583 on real servers, each destructive row on a FRESH server --------
    semi_fresh; out=$(semi_shim if-shell true kill-server)
    assert_contains "REAL #1583 F5: if-shell true kill-server is REFUSED as a carrier" "$out" "CARRIES tmux commands"
    assert_eq "REAL #1583 F5: …and the server is STILL ALIVE (dead at 4bbfe878)" "$(semi_alive)" alive
    semi_fresh; out=$(semi_shim set-hook -g after-list-windows kill-server); semi list-windows >/dev/null 2>&1; sleep 0.3
    assert_contains "REAL #1583 F5: set-hook -g after-list-windows kill-server is REFUSED" "$out" "REFUSING"
    assert_eq "REAL #1583 F5: …and a later list-windows detonates nothing" "$(semi_alive)" alive
    semi_fresh; out=$(semi_shim set -s exit-unattached on); sleep 1
    assert_contains "REAL #1583 F5: set -s exit-unattached on is REFUSED" "$out" "REFUSING"
    assert_eq "REAL #1583 F5: …and the server is STILL ALIVE" "$(semi_alive)" alive
    semi_fresh; out=$(semi_shim kill-window -t =base)
    assert_contains "REAL #1583 F4: kill-window -t =base on the LAST window is REFUSED" "$out" "would EMPTY the board's server"
    assert_eq "REAL #1583 F4: …and the server is STILL ALIVE" "$(semi_alive)" alive
    semi_fresh; semi set -s 'command-alias[50]' 'zq=X=1 kill-server' >/dev/null 2>&1; out=$(semi_shim zq)
    assert_contains "REAL #1583 D1: zq=X=1 kill-server is REFUSED" "$out" "REFUSING"
    assert_eq "REAL #1583 D1: …and the server is STILL ALIVE" "$(semi_alive)" alive
    semi_fresh; semi set -s 'command-alias[50]' 'zz=' >/dev/null 2>&1; out=$(semi_shim zz)
    assert_contains "REAL #1583 CRASH: an alias expanding to nothing, invoked bare, is REFUSED" "$out" "CRASHES"
    assert_eq "REAL #1583 CRASH: …and the server is STILL ALIVE (\"lost server\" at 4bbfe878)" "$(semi_alive)" alive
    semi_fresh; semi split-window -d -t p:base >/dev/null 2>&1; out=$(semi_shim select-pane -t 1)
    assert_eq "REAL #1583 F6: select-pane -t 1 in a 2-pane window ACTS (pane 1 is now active)" \
        "$(semi display-message -p -t p:base '#{pane_index}' 2>/dev/null)" 1
    # The carve-out, on a real server: the OPERATOR's config reload passes, an
    # AGENT's is refused — the file only sets a user option, so its effect is
    # observable and harmless.
    printf 'set -g @nxreload loaded\n' > "$WORK/reload.conf"
    semi_fresh; out=$(semi_shim source-file "$WORK/reload.conf")
    assert_eq "REAL #1583 carve-out: an AGENT's source-file on the board is refused (the option stays unset)" \
        "$(semi show -gv @nxreload 2>/dev/null)" ""
    semi_fresh; out=$(SEMI_AS_OPERATOR=1 semi_shim source-file "$WORK/reload.conf")
    assert_eq "REAL #1583 carve-out: the OPERATOR's source-file reload on the board ACTS" \
        "$(semi show -gv @nxreload 2>/dev/null)" loaded

    # --- #1583 delta (semisplitsk2 F1-F4), each destructive row on a FRESH server.
    # F1: an agent's bare `-C`, fed kill-server on stdin — DEAD at 8c9c3aa9.
    semi_fresh; out=$( { sleep 1; printf 'kill-server\n' 2>/dev/null; sleep 1; } | timeout 8 env -u TMUX PATH="$SHIM_DIR:/usr/bin:/bin:$PATH" \
        NEXUS_TMUX_SOCKET="$SEMI_PATH" CLAUDECODE=1 "$SHIM_DIR/tmux" -L "$SEMI_SOCK" -C 2>&1 ); sleep 0.5
    assert_contains "REAL #1583 F1: an AGENT's bare -C on the board is REFUSED" "$out" "control mode"
    assert_eq "REAL #1583 F1: …and the server is STILL ALIVE (dead at 4bbfe878, ff9f8a55, 8c9c3aa9)" "$(semi_alive)" alive
    # F2: session `1s` (created FIRST) whose active pane is index 1; `p` is current
    # and holds nothing matching `1`. 8c9c3aa9 killed 1s:far.1; 4bbfe878 refused.
    semi kill-server >/dev/null 2>&1 || true
    start_server env -u TMUX tmux -f "$TMUXCONF" -L "$SEMI_SOCK" new-session -d -s 1s -n far >/dev/null 2>&1
    SEMI_PATH=$(semi display-message -p '#{socket_path}' 2>/dev/null)
    abort_if_board "$SEMI_PATH" "run the F2 row"
    semi split-window -d -t 1s:far >/dev/null 2>&1; semi select-pane -t 1s:far.1 >/dev/null 2>&1
    sleep 1.1; semi new-session -d -s p -n base >/dev/null 2>&1; semi new-window -d -t p:2 -n other >/dev/null 2>&1
    out=$(semi_shim kill-pane -t 1)
    assert_contains "REAL #1583 F2: kill-pane -t 1 landing in ANOTHER session's current window is REFUSED" "$out" "REFUSING"
    assert_eq "REAL #1583 F2: …and 1s:far still has BOTH panes" "$(semi list-panes -t 1s:far 2>/dev/null | wc -l | tr -d ' ')" 2
    # F3: set-window-option of a lethal option — DEAD at 8c9c3aa9.
    semi_fresh; out=$(semi_shim setw -g exit-unattached on); sleep 1
    assert_contains "REAL #1583 F3: setw -g exit-unattached on is REFUSED" "$out" "REFUSING"
    assert_eq "REAL #1583 F3: …and the server is STILL ALIVE" "$(semi_alive)" alive
    # F4: the carried text, for a caller WITHOUT CLAUDECODE — each DEAD at 8c9c3aa9.
    semi_fresh; out=$(SEMI_AS_OPERATOR=1 semi_shim if-shell true kill-server); sleep 0.3
    assert_eq "REAL #1583 F4: a NON-agent's if-shell true kill-server — the server is STILL ALIVE" "$(semi_alive)" alive
    printf 'set -g @nxok loaded\nkill-server\n' > "$WORK/kill.conf"
    semi_fresh; out=$(SEMI_AS_OPERATOR=1 semi_shim source-file "$WORK/kill.conf"); sleep 0.3
    assert_eq "REAL #1583 F4: a NON-agent's source-file of a file holding kill-server — STILL ALIVE" "$(semi_alive)" alive
    assert_eq "REAL #1583 F4: …and NOTHING in it ran (the whole invocation is refused)" "$(semi show -gv @nxok 2>/dev/null)" ""
    semi_fresh; out=$(SEMI_AS_OPERATOR=1 semi_shim set-hook -g after-list-windows kill-server); semi list-windows >/dev/null 2>&1; sleep 0.3
    assert_eq "REAL #1583 F4: a NON-agent's set-hook after-list-windows kill-server — a later list-windows detonates nothing" "$(semi_alive)" alive

    # --- the ENVIRONMENT fix for server-run shell text (tmux-server-path.sh) ---
    # A server whose PATH does NOT hold the shim, like the live board's (measured).
    # NEXUS_TMUX_SOCKET is REMOVED from its environment, so a job-side shim knows
    # the board only by the job's own $TMUX; NEXUS_STATE_DIR is the fixture's, so
    # a job-side refusal files into the fixture and never into a real inbox.
    SP_REAL=""; _sp_r="$PATH:"
    while [ -n "$_sp_r" ]; do
        _sp_d="${_sp_r%%:*}"; _sp_r="${_sp_r#*:}"
        [ -n "$_sp_d" ] && [ -x "$_sp_d/tmux" ] && [ ! -d "$_sp_d/tmux" ] || continue
        [ "$(head -c 2 -- "$_sp_d/tmux" 2>/dev/null)" = '#!' ] || { SP_REAL="$_sp_d/tmux"; break; }
    done
    SP_SOCK="sp$$"; PRIV_SOCKETS+=("$SP_SOCK")
    sp() { env -u TMUX -u NEXUS_TMUX_SOCKET "$SP_REAL" -L "$SP_SOCK" "$@"; }
    sp_fresh() {
        sp kill-server >/dev/null 2>&1 || true
        start_server env -u TMUX -u NEXUS_TMUX_SOCKET -u CLAUDECODE PATH="${SP_REAL%/*}:/usr/bin:/bin" NEXUS_STATE_DIR="$NEXUS_STATE_DIR" \
            "$SP_REAL" -f "$TMUXCONF" -L "$SP_SOCK" new-session -d -s p >/dev/null 2>&1
        SP_PATH=$(sp display-message -p '#{socket_path}' 2>/dev/null)
        abort_if_board "$SP_PATH" "run the server-path rows"
    }
    sp_alive() { sp list-sessions >/dev/null 2>&1 && echo alive || echo dead; }
    sp_fresh; sp run-shell 'tmux kill-server' >/dev/null 2>&1; sleep 1
    assert_eq "REAL server-path premise: with the shim OFF the server's PATH, a server-run 'tmux kill-server' KILLS it" "$(sp_alive)" dead
    sp_fresh; bash "$REPO_ROOT/monitor/tmux-server-path.sh" --check -L "$SP_SOCK" >/dev/null 2>&1; _sp_rc=$?
    assert_eq "REAL server-path: --check says NOT FRONTED (rc 1)" "$_sp_rc" 1
    bash "$REPO_ROOT/monitor/tmux-server-path.sh" --apply -L "$SP_SOCK" >/dev/null 2>&1; _sp_rc=$?
    assert_eq "REAL server-path: --apply fronts the shim, verified by re-reading (rc 0)" "$_sp_rc" 0
    sp run-shell 'tmux kill-server' >/dev/null 2>&1; sleep 1
    assert_eq "REAL server-path: after --apply the SAME server-run 'tmux kill-server' is refused — STILL ALIVE" "$(sp_alive)" alive
    # The job reports through a FILE, not run-shell's stdout: tmux 3.4 (the CI
    # runner's) does not return a job's output to a detached command-line client
    # — `run-shell 'echo hi'` prints nothing at rc 0 there, with or without the
    # shim (measured; 2.6 prints `hi`) — so the stdout form read '' on every CI
    # cell while the job itself had succeeded (#1703). Waited on, bounded.
    rm -f "$WORK/spjob.out"
    sp run-shell "tmux list-windows >/dev/null && echo SPJOBOK > '$WORK/spjob.out'" >/dev/null 2>&1
    for _sp_i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WORK/spjob.out" ] && break; sleep 0.2; done
    assert_eq "REAL server-path: control — a server-run 'tmux list-windows' still works through the shim" \
        "$(cat "$WORK/spjob.out" 2>/dev/null)" SPJOBOK
    # A PLUGIN-STYLE server job after --apply: `run-shell <plugin>.tmux` scripts
    # call `tmux bind-key`/`set-option`. The job inherits the server's environment,
    # which carries no CLAUDECODE, so the carrier rule must not break it.
    sp run-shell 'tmux bind-key -n F11 display-message plugin-ok' >/dev/null 2>&1
    assert_eq "REAL server-path: a plugin-style job's 'tmux bind-key' still WORKS after --apply (not an agent)" \
        "$(sp list-keys 2>/dev/null | grep -c 'F11.*plugin-ok')" 1
    abort_if_board "$SP_PATH" "tear down the server-path server"
    sp kill-server >/dev/null 2>&1 || true

    abort_if_board "$SEMI_PATH" "tear down the #1578 server"
    semi kill-server >/dev/null 2>&1 || true

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
# 106 -> 122 with your-org/nexus-code#1524's sixteen stub assertions: six on the
# four refusals (the first carries its two message rows) and ten pass-throughs.
# 122 -> 137 with the fifteen #1524 ACT-verb stub assertions: seven on the six
# refusals (the first carries its message row) and eight pass-throughs.
# 137 -> 144: skeptic F3/F4 on #1568, seven stub rows (five refusals, two controls).
# 144 -> 152: delta skeptic G1-G4, eight stub rows.
# 152 -> 161: delta skeptic H1, nine stub rows (six refusals that flip, three must-not-flip).
# 161 -> 167: merge4's all-digit finding and its sweep, six stub rows (three refusals, three controls).
# 167 -> 170: the `-a` mis-aim, three stub rows (two refusals, one control).
# 170 -> 213: #1578 and its bundle — the ';'-ended separator (14 refusal-side,
# 6 literal controls), merge4sk G3 session part (8 refusal-side, 6 controls —
# kill-session -a included), G2 session reading (2 refusals, 1 control), #1575
# act aliases (5 refusal-side, 1 control) and alias-name equality (1 refusal,
# 1 control).
# 215 -> 229: #1582 skeptic F1/F2 (alias table decoded + values tokenised: 6
# refusal-side, 2 controls) and F3 (control mode: 2 refusals, 1 control, and the
# loud-INERT unparsed-answer row x2) — 9 refusal-side, 5 controls/other.
# 229 -> 290: #1583 — F5 carriers (18 refusal-side, 5 controls), F5 lethal
# non-kills (11 refusal-side, 5 controls), F4 =name (4 refusal-side, 1 control),
# F6 pane digits (2 now-passing, 3 still-refused controls), D1/crash/D2/D3
# (8 refusal-side, 4 controls).
# 290 -> 297: the AGENT-only carrier carve-out (5 non-agent passes, 2 lethal
# controls that stay refused for every caller).
# 297 -> 352: the semisplitsk2 delta — F1 agent control mode (6 refusal-side,
# 3 controls incl. Claude Code's -CC launcher), F2 window_id equality (3
# refusals, 1 probe count), F3 set-window-option (5 refusal-side, 3 controls),
# F4 carried text for every caller (26 refusal-side incl. 5 cycle rows, 6
# controls, the depth bound x2).
BASE_ASSERTS=352
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
