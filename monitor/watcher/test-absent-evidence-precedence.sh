#!/usr/bin/env bash
# THE `_absent_evidence` ARM ORDER, MEASURED RATHER THAN REASONED.
# (your-org/nexus-code#807 finding 2)
#
# WHAT #798 CHANGED. Lifting `pane-state.sh`'s inline decision ladder into
# `_absent_evidence` reordered two arms:
#
#     dev 16728e7 (inline gate)      PR 36a6d4a (_absent_evidence)
#     first  _pane_has_live_descendant     pane_dead == 1              (arm 1)
#     then   pane_dead == 1                … live-descendant           (arm 4)
#
# The `#798` skeptic judged the reorder behaviourally inert — a pane tmux
# reports dead has no live descendants of `pane_pid` by construction, because
# the children of an exited process are reparented away — but reached that BY
# REASONING, NOT BY MEASUREMENT, and said so. Nothing pinned the precedence.
#
# That left an unverified equivalence sitting under the one KILL-AUTHORISING
# state (`absent` is on `bk_pane_kill_authorized`'s allowlist), which is the
# worst possible place for "we think this is fine".
#
# WHAT THIS FILE DOES. Both remedies `#807` offered, because they answer
# different questions:
#
#   PART A — MEASURES the claim. It builds the state the skeptic said cannot
#     exist: a pane whose process EXITS while a child it started is still
#     running. If a live descendant of `pane_pid` survived that, the two arm
#     orders would disagree and the reorder would be a live defect. The
#     assertion is that the descendant probe answers NO even though the child
#     is demonstrably alive — i.e. the impossibility is real, and it is real
#     because of reparenting, which is now observed rather than asserted.
#
#   PART B — PINS the order on the source, so a future reorder has to be
#     deliberate. Part A proves today's tree is safe; it cannot stop someone
#     moving the arms tomorrow, and the equivalence Part A establishes is
#     contingent on facts (reparenting, pid non-reuse within the probe window)
#     that a reordering author should have to think about again.
#
# A NOTE ON WHY ARM 1 FIRST IS ALSO THE BETTER ORDER, not merely an equivalent
# one. Under PID REUSE — `pane_pid` recycled by an unrelated new process that
# has children — the descendant probe answers YES about a process tree that has
# nothing to do with this pane. Checking tmux's own first-party `pane_dead`
# BEFORE any pid-based probe is what makes that misattribution unreachable.
#
# TMUX ISOLATION. Every tmux call goes to a PRIVATE server via `-L`, with $TMUX
# unset. Both halves are load-bearing: tmux resolves its socket
# `-L/-S > $TMUX > TMUX_TMPDIR > default`, so TMUX_TMPDIR alone isolates
# nothing when $TMUX is set — and $TMUX is always set for an agent. That
# misreading destroyed the sandbox five times on 2026-07-30 (#644). Containment
# is proved before any fixture is built and the suite REFUSES to run without it.
#
# Run: bash monitor/watcher/test-absent-evidence-precedence.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
PANE_STATE="$_test_dir/../pane-state.sh"

[[ -r "$PANE_STATE" ]] || { echo "missing pane-state.sh: $PANE_STATE" >&2; exit 2; }
command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 77; }
REAL_TMUX=$(type -P tmux) || { echo "SKIP: no tmux binary on PATH"; exit 77; }

# ── PART B FIRST — the source-order pin ─────────────────────────────────
# Deliberately before the tmux fixture: it needs no server, so it still runs on
# a host where Part A must skip. A file that could only check the cheap half on
# CI and silently checked nothing there would be this repo's own defect class.
# Fixed-string matching, deliberately. The first draft passed regexes through
# `awk -v`, where the backslashes are consumed twice — awk warned
# `escape sequence \$ treated as plain $`, every arm "went missing", and the
# order assertions all failed for a reason that had nothing to do with the
# ladder. A lint whose pattern silently stops matching reports the same thing as
# a lint whose subject vanished; `grep -F` on the extracted body has no escaping
# layer to get wrong, and the presence assertions below are what catch it if the
# body ever stops being extractable.
_fn_body() {
    awk '/^_absent_evidence\(\) \{/ { inf = 1 } inf { print NR ":" $0 } inf && /^\}$/ { exit }' \
        "$PANE_STATE"
}
_arm_line() {   # _arm_line <fixed-string> -> line number of its first occurrence
    _fn_body | grep -F -- "$1" | head -1 | cut -d: -f1
}
dead_ln=$(_arm_line '"$pane_dead" == 1')
desc_ln=$(_arm_line '_pane_has_live_descendant "$pid"')
claude_ln=$(_arm_line '_pane_has_live_claude "$pid"')

assert_eq "the pane_dead arm is present in _absent_evidence" \
    "$([[ -n "$dead_ln" ]] && echo yes || echo no)" "yes"
assert_eq "the live-descendant arm is present in _absent_evidence" \
    "$([[ -n "$desc_ln" ]] && echo yes || echo no)" "yes"
assert_eq "the live-claude arm is present in _absent_evidence" \
    "$([[ -n "$claude_ln" ]] && echo yes || echo no)" "yes"

# The ORDER, asserted as intent. If you are reading this because you reordered
# the ladder: Part A below is the argument for why pane_dead may precede the
# process probes. Re-run it, and re-read the pid-reuse note in the header,
# before changing this expectation.
assert_eq "pane_dead is checked BEFORE the live-claude probe (intent, #798)" \
    "$([[ "$dead_ln" -lt "$claude_ln" ]] && echo yes || echo no)" "yes"
assert_eq "pane_dead is checked BEFORE the live-descendant probe (intent, #798)" \
    "$([[ "$dead_ln" -lt "$desc_ln" ]] && echo yes || echo no)" "yes"
assert_eq "live-claude is still checked before live-descendant" \
    "$([[ "$claude_ln" -lt "$desc_ln" ]] && echo yes || echo no)" "yes"

# ── PART A — the measurement ────────────────────────────────────────────
SOCK="ps807-test-$$"
SESSION="t807"
TT=$(mktemp -d)
WORK=$(mktemp -d)
tx() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$TT" "$REAL_TMUX" -L "$SOCK" "$@"; }

SHIMDIR=$(mktemp -d)
cat > "$SHIMDIR/tmux" <<SHIM
#!/bin/bash
exec env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$TT" "$REAL_TMUX" -L "$SOCK" "\$@"
SHIM
chmod +x "$SHIMDIR/tmux"

_kid=""
cleanup() {
    [[ -n "$_kid" ]] && kill "$_kid" 2>/dev/null
    tx kill-server 2>/dev/null      # scoped by -L: can only reach the private socket
    rm -rf "$TT" "$SHIMDIR" "$WORK"
}
trap cleanup EXIT

tx -f /dev/null new-session -d -s "$SESSION" -x 200 -y 50 2>/dev/null \
    || { echo "SKIP: cannot start a private tmux server here" >&2
         th_skip "Part A (live tmux fixture)" "no private tmux server available on this host"
         th_summary_and_exit; }

priv=$(tx display-message -p '#{socket_path}' 2>/dev/null)
shim=$(PATH="$SHIMDIR:$PATH" tmux display-message -p '#{socket_path}' 2>/dev/null)
default_sock="/tmp/tmux-$(id -u)/default"
if [[ -z "$priv" || "$priv" == "$default_sock" || "$shim" != "$priv" ]]; then
    echo "REFUSING TO RUN: containment unproven (priv='$priv' shim='$shim' default='$default_sock')" >&2
    exit 1
fi
echo "containment proved: private socket $priv, shim agrees, default is $default_sock"

# THE FIXTURE. `remain-on-exit on` is what leaves the pane addressable after its
# process exits — without it tmux destroys the pane and there is no `pane_dead=1`
# to observe. The pane process starts a long-lived child, records both pids, and
# then EXITS. That is the strongest available approximation of "a pane tmux calls
# dead, with something still running that it started".
tx set-option -g remain-on-exit on 2>/dev/null
tx new-window -t "$SESSION" -n dead807 \
    "bash -c 'trap \"\" HUP; sleep 600 & echo \$! > $WORK/kid.pid; echo \$\$ > $WORK/pane.pid; sleep 0.5; exit 0'" \
    2>/dev/null

idx=""
for _ in $(seq 1 60); do
    idx=$(tx list-windows -t "$SESSION" -F '#{window_index} #{window_name}' 2>/dev/null \
          | awk '$2=="dead807"{print $1; exit}')
    [[ -n "$idx" ]] && break
    sleep 0.2
done
if [[ -z "$idx" ]]; then
    th_skip "Part A (live tmux fixture)" "the dead807 window never materialised"
    th_summary_and_exit
fi

# Wait for tmux to report the pane process as exited.
pane_dead=""
for _ in $(seq 1 100); do
    pane_dead=$(tx list-panes -a -F '#{window_index} #{pane_dead}' 2>/dev/null \
                | awk -v i="$idx" '$1==i{print $2; exit}')
    [[ "$pane_dead" == 1 ]] && break
    sleep 0.2
done
pane_pid=$(tx list-panes -a -F '#{window_index} #{pane_pid}' 2>/dev/null \
           | awk -v i="$idx" '$1==i{print $2; exit}')
_kid=$(cat "$WORK/kid.pid" 2>/dev/null || echo "")

assert_eq "the fixture reached pane_dead=1 (the state under test)" "$pane_dead" "1"

# THE CHILD IS ALIVE. Without this the measurement below is vacuous: "no live
# descendant" would be trivially true because nothing was alive at all. This is
# the assertion that makes the next one mean something.
assert_eq "…while the child the pane started is STILL RUNNING" \
    "$([[ -n "$_kid" ]] && kill -0 "$_kid" 2>/dev/null && echo alive || echo gone)" "alive"

# THE IMPOSSIBILITY, OBSERVED. The child outlived the pane process, so it was
# reparented away and its ppid chain no longer reaches pane_pid. This is the
# fact the `#798` skeptic asserted from first principles; here it is measured.
kid_ppid=$(ps -o ppid= -p "$_kid" 2>/dev/null | tr -d ' ')
assert_eq "the surviving child was REPARENTED off pane_pid (not its child any more)" \
    "$([[ -n "$kid_ppid" && "$kid_ppid" != "$pane_pid" ]] && echo reparented || echo "still-child")" \
    "reparented"

# THE VERDICT ITSELF, through the real script. `absent` is the kill-authorising
# state, and it is what BOTH arm orders must produce here — the descendant probe
# has nothing to find, so moving it ahead of `pane_dead` could not change this.
# Boot grace pinned to 0: the pane is seconds old, which since #777 is also the
# shape of a spawn in progress, so the default grace would defer and this
# assertion would be checking the grace rather than the ladder.
state=$(NEXUS_PANE_BOOT_GRACE_SECONDS=0 PATH="$SHIMDIR:$PATH" \
        bash "$PANE_STATE" "$SESSION:$idx" 2>/dev/null \
        | head -1 | sed -n 's/.*state=\([a-z-]*\).*/\1/p')
assert_eq "a dead pane with a reparented survivor still classifies absent" "$state" "absent"

# EXPECTED-COUNT GUARD (your-org/nexus-code#807 finding 1, applied here too).
# Part A can legitimately skip, so the count is the fixed 6 of Part B plus the 5
# of Part A when it ran. Derived, not pinned to a literal that would drift.
# 6 source-order assertions in Part B + 4 measurement assertions in Part A.
# The skip paths above exit through th_summary_and_exit before reaching this,
# so by here both parts have run. (The first draft said 5 for Part A and this
# guard is what caught the miscount — which is the argument for having it.)
EXPECTED=$(( 6 + 4 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
