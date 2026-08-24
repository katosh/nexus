#!/usr/bin/env bash
# test-target-window-live.sh — REAL-tmux verification of
# `_target_window_present` (your-org/nexus-code#741).
#
# WHY THIS EXISTS ALONGSIDE test-lib.sh. test-lib.sh mocks tmux as a
# bash function, which is the right harness for the rc contract but
# structurally CANNOT check the two claims #741 actually rests on:
#
#   1. that `#{pane_dead}` is 1 for a `remain-on-exit` corpse and 0 for
#      a live pane, on the tmux that is actually installed. The mock
#      asserts what we typed into a variable — a proxy for tmux, not
#      tmux.
#   2. that `list-panes -s` scopes to the SAME session `list-windows`
#      did. `-a` would widen the probe to the whole server and let a
#      same-named window in an unrelated session read as present; no
#      mock that ignores flags can tell the two apart.
#
# The bug being guarded is the one that made #738 deterministic: the
# respawn path sets `remain-on-exit on` (deliberately — a crashed
# orchestrator's scrollback is the diagnosis), so a dead agent leaves
# the window LISTED. A name-only probe answers PRESENT forever, the
# absent branch never fires a second time, and the crash-loop guard —
# which needs three respawns — sees one.
#
# Gated behind SLOW_TESTS=1: it drives a real tmux server (~3 s).
# Discovered automatically by the SLOW band, which greps test-*.sh for
# SLOW_TESTS rather than enumerating a list.
#
# Run directly: SLOW_TESTS=1 bash monitor/watcher/test-target-window-live.sh

set -uo pipefail

if [ "${SLOW_TESTS:-0}" != "1" ]; then
    echo "skipped: $(basename "$0") (set SLOW_TESTS=1 to enable; ~3s wall-clock, needs tmux)"
    exit 77   # SKIP, not PASS (your-org/nexus-code#568 A6)
fi

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=/dev/null
. "$_test_dir/_test_helpers.sh"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s (got %q)\n' "$label" "$got"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s: got %q, want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

if ! command -v tmux >/dev/null 2>&1; then
    echo "ENV-FAIL: tmux is not on PATH — this test is about real tmux behaviour," >&2
    echo "          so skipping it would assert nothing. Refusing instead." >&2
    exit 1
fi

WORK=$(mktemp -d -t nexus-twp-live-XXXXXX)
SOCK="nexus-twp-live-$$"
th_tmux_fixture_conf "$WORK/tmux.conf"

# `$TMUX` OUTRANKS `TMUX_TMPDIR` (your-org/nexus-code#644): every agent
# runs inside a pane, so an un-scrubbed tmux call lands on the LIVE
# nexus server. `env -u TMUX` + an explicit `-L` is the only form proven
# to isolate. Never `kill-server` — bwrap is PID 1 under
# `--die-with-parent`, so a bare one takes the whole sandbox down;
# `kill-session` on each session is targeted, and the server exits on
# its own when the last one goes.
FTMUX=( env -u TMUX tmux -L "$SOCK" -f "$WORK/tmux.conf" )
cleanup() {
    local s
    while IFS= read -r s; do
        [[ -n "$s" ]] && "${FTMUX[@]}" kill-session -t "$s" 2>/dev/null || true
    done < <("${FTMUX[@]}" list-sessions -F '#{session_name}' 2>/dev/null)
    rm -rf "$WORK"
}
trap cleanup EXIT

# `_target_window_present` calls a bare `tmux`, so route it to the
# fixture socket with a PATH-front wrapper — the same device the
# respawn integration test uses.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<WRAP
#!/usr/bin/env bash
exec env -u TMUX $(command -v tmux) -L "$SOCK" -f "$WORK/tmux.conf" "\$@"
WRAP
chmod +x "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"; export PATH

# shellcheck source=_lib.sh
. "$_test_dir/_lib.sh"

# th_wait_pane_dead <window> — poll until tmux reports the window's
# pane dead. Returns 1 on timeout so a slow host produces a NAMED
# environment failure rather than a mystery assertion failure.
wait_pane_dead() {
    local win="$1" i dead
    for i in $(seq 1 50); do
        # `!seen` rather than `exit`: an early-exit reader on the right
        # of a pipe under `pipefail` puts SIGPIPE (141) into the
        # pipeline's status, and it would enter
        # early-exit-readers.manifest as a site a reviewer must look at.
        # Draining a handful of rows costs nothing and adds no site.
        dead=$("${FTMUX[@]}" list-panes -s -F '#{window_name} #{pane_dead}' 2>/dev/null \
                 | awk -v w="$win" '$1 == w && !seen { print $2; seen = 1 }')
        [[ "$dead" == "1" ]] && return 0
        sleep 0.1
    done
    return 1
}

"${FTMUX[@]}" new-session -d -s main -n base 'sleep 300'

# ---- 1. a live window reads PRESENT -------------------------------
echo '=== real tmux: live window ==='
"${FTMUX[@]}" new-window -d -n orchestrator 'sleep 300'
sleep 0.3
_target_window_present orchestrator; rc=$?
assert_eq "live orchestrator pane -> rc=0 (present)" "$rc" "0"

# ---- 2. THE #741 REGRESSION: a remain-on-exit corpse --------------
# Exactly what _respawn.sh produces: `remain-on-exit on`, then the
# spawned process exits. The window stays listed; the agent is gone.
#
# THE CORPSE IS BUILT WITH remain-on-exit ALREADY IN EFFECT, and that
# is load-bearing rather than incidental. MEASURED on this host, 12
# trials per arm, deterministic in every arm: the corpse forms if and
# only if `remain-on-exit` is in effect at the instant the child
# exits.
#
#   fast pane + option set AFTER new-window, child exits at once
#                                            -> VANISHED 12/12
#   fast pane + option set BEFORE            -> corpse    12/12
#   fast pane + option set AFTER, child sleeps 1s
#                                            -> corpse    12/12
#   slow pane (a login-shell rc chain delays pane startup past the
#   option) + option set AFTER               -> corpse    12/12
#
# `_respawn.sh` uses the AFTER order, and in production that is safe
# by a wide margin: the launcher it spawns execs claude, which outlives
# the `set-window-option` call by orders of magnitude, so the option
# always lands first. A FIXTURE has no such margin — the same order
# with a fast-failing child is a coin-flip on pane-startup latency, and
# a test that flips between "corpse" and "no window" is testing the
# harness. Presetting removes the race from the test without weakening
# what it asserts: the probe's input is a real tmux corpse either way.
echo '=== real tmux: remain-on-exit corpse (the #741 regression) ==='
"${FTMUX[@]}" kill-window -t orchestrator 2>/dev/null || true
"${FTMUX[@]}" set-option -g remain-on-exit on 2>/dev/null || true
"${FTMUX[@]}" new-window -d -n orchestrator 'exit 1'
if ! wait_pane_dead orchestrator; then
    echo "ENV-FAIL: pane never reported #{pane_dead}=1 within 5s —" >&2
    echo "          either remain-on-exit did not take or this tmux does not" >&2
    echo "          support pane_dead. Both invalidate the premise, so this" >&2
    echo "          test refuses rather than asserting on an unknown state." >&2
    echo "          tmux $(tmux -V 2>&1)" >&2
    exit 1
fi
# Precondition, stated so a future reader can see the corpse is real:
# the window IS still listed. A name-only probe answers PRESENT here.
listed=$("${FTMUX[@]}" list-windows -F '#{window_name}' 2>/dev/null | grep -cx orchestrator)
assert_eq "corpse window is still LISTED (name-only probe would say present)" "$listed" "1"
_target_window_present orchestrator; rc=$?
assert_eq "dead pane behind a listed name -> rc=2 (absent, respawn may fire)" "$rc" "2"

# A second window that is alive must be unaffected by the corpse.
_target_window_present base; rc=$?
assert_eq "live sibling window of a corpse -> rc=0" "$rc" "0"

# ---- 3. a name nobody holds ---------------------------------------
echo '=== real tmux: name absent ==='
_target_window_present zz-no-such-window; rc=$?
assert_eq "unheld name -> rc=2" "$rc" "2"

# ---- 4. SCOPE: the probe must not widen from -s to -a -------------
# `_target_window_present` replaced `list-windows` with `list-panes`.
# `-a` would have silently WIDENED it from one session to the whole
# server, letting a same-named window in an unrelated session read as
# present — a missed respawn with no symptom. The assertion has to run
# THROUGH the function: comparing `list-panes -s` against
# `list-windows` by hand tests tmux, not the probe, and an `-s`->`-a`
# mutant sails straight past it (measured — that is why this is
# written the way it is).
#
# Fixture: a LIVE window named `orchestrator` parked in a session that
# is NOT the current one. Scoped to the session, the probe must call
# it absent; scoped to the server, present.
echo '=== real tmux: session scope preserved (-s, not -a) ==='
"${FTMUX[@]}" kill-window -t orchestrator 2>/dev/null || true
"${FTMUX[@]}" set-option -g remain-on-exit off 2>/dev/null || true
"${FTMUX[@]}" new-window -d -n orchestrator 'sleep 300'      # live, in session `main`
"${FTMUX[@]}" new-session -d -s elsewhere -n zz-other-session-only 'sleep 300'
sleep 0.3
# Precondition, asserted rather than assumed: tmux's notion of the
# CURRENT session must be `elsewhere` (the one without the decoy). If a
# future tmux picks differently the fixture stops discriminating, and
# that must surface as a named environment failure, not as a green.
cur=$("${FTMUX[@]}" list-windows -F '#{window_name}' 2>/dev/null | sort -u | tr '\n' ',')
all=$("${FTMUX[@]}" list-panes -a -F '#{window_name}' 2>/dev/null | sort -u | tr '\n' ',')
if [[ "$cur" == *orchestrator* || "$all" != *orchestrator* ]]; then
    echo "ENV-FAIL: scope fixture is not discriminating on this tmux —" >&2
    echo "          current session sees: $cur" >&2
    echo "          whole server sees:    $all" >&2
    echo "          The decoy must be OUTSIDE the current session for this" >&2
    echo "          assertion to mean anything. Refusing to assert." >&2
    exit 1
fi
printf '  PASS: fixture discriminates: server sees %q, current session sees %q\n' "$all" "$cur"
PASS=$(( PASS + 1 ))
_target_window_present orchestrator; rc=$?
assert_eq "live same-named window in ANOTHER session -> rc=2 (probe is session-scoped)" "$rc" "2"

# ---- 5. no server at all -> rc=1, "can't classify", never absent --
# The U1 respawn-storm invariant, on real tmux this time: a query that
# CANNOT be answered must not be read as "absent", which main.sh would
# count toward the fast-respawn streak.
echo '=== real tmux: server gone -> rc=1 (fail closed) ==='
while IFS= read -r s; do
    [[ -n "$s" ]] && "${FTMUX[@]}" kill-session -t "$s" 2>/dev/null || true
done < <("${FTMUX[@]}" list-sessions -F '#{session_name}' 2>/dev/null)
sleep 0.5
if "${FTMUX[@]}" list-sessions >/dev/null 2>&1; then
    echo "  SKIP-FAIL: fixture server outlived its sessions; cannot test the no-server arm" >&2
    FAIL=$(( FAIL + 1 ))
else
    _target_window_present orchestrator; rc=$?
    assert_eq "no tmux server -> rc=1 (can't classify), NOT rc=2" "$rc" "1"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    echo "SOME TESTS FAILED" >&2
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
