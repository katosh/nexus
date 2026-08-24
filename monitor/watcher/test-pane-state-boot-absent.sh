#!/usr/bin/env bash
# your-org/nexus-code#643 regression: `absent` must not be emitted for a window
# that is still booting.
#
# Run: bash monitor/watcher/test-pane-state-boot-absent.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS MATTERS MORE THAN A NORMAL CLASSIFIER TEST
# ---------------------------------------------------
# `absent` is the ONE kill-authorising state. CLAUDE.md calls it "the state that
# positively asserts a dead agent" and `_bookkeeping.sh:bk_pane_kill_authorized`
# allowlists it. Every other ambiguous state was hardened by making it REFUSE
# (#603, #607, #626) — and that entire default-deny design rests on `absent`
# being true whenever it is asserted, because default-deny cannot help when the
# wrong answer is on the ALLOW side. A false `absent` walks straight through.
#
# The defect: a freshly spawned window runs the generated
# /tmp/spawn-launcher-*.sh preamble (shim precondition, write probe, guard
# block) before `exec claude`. Throughout that window there is no `claude` in
# the pane's process tree, so the hoisted liveness gate emitted `absent` for a
# perfectly healthy spawn — during exactly the interval an orchestrator is most
# likely to ask, right after spawning, to confirm the spawn took. Measured at
# 2.86 s against a fixture carrying the real guards; the reporter observed
# ~20-30 s in production.
#
# THE PROPERTY UNDER TEST is the emitted STATE, not the helper that computes it.
# Asserting `_pane_has_live_descendant` in isolation would be a proxy: it could
# pass while the gate wired the branches backwards. So these tests drive the
# real pane-state.sh against real tmux panes with real process trees.
#
# TMUX ISOLATION. Every tmux call goes to a PRIVATE server via `-L`, and $TMUX
# is unset. Both halves are load-bearing: tmux resolves its socket
# `-L/-S > $TMUX > TMUX_TMPDIR > default`, so TMUX_TMPDIR ALONE does not isolate
# anything when $TMUX is set — and $TMUX is always set for an agent, because it
# runs inside a pane. That misreading destroyed the sandbox five times on
# 2026-07-30 (your-org/nexus-code#644). Containment here is asserted before any
# fixture is built, and the suite REFUSES to run if it cannot prove it.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PANE_STATE="$_test_dir/../pane-state.sh"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }

# ---- containment, proved before anything is created ---------------------
REAL_TMUX=$(type -P tmux) || { echo "SKIP: no tmux binary on PATH"; exit 0; }
# The operator's interactive `grep` is a shell FUNCTION wrapping ugrep
# (your-org/nexus-code#618). Explicit file arguments are not suppressed by it,
# but `-c` semantics differ between implementations and Test 11 turns a COUNT
# into a claim — so bind the real binary rather than inherit whatever `grep`
# resolves to in the caller's shell.
REAL_GREP=$(type -P grep) || REAL_GREP=/bin/grep
SOCK="ps643-test-$$"
SESSION="t643"
TT=$(mktemp -d)
tx() { env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$TT" "$REAL_TMUX" -L "$SOCK" "$@"; }

# A tmux shim pinned to the private socket, front of PATH for pane-state.sh
# (which calls bare `tmux`). Without it pane-state.sh would inspect the LIVE
# server and this suite would assert about the operator's real windows.
SHIMDIR=$(mktemp -d)
cat > "$SHIMDIR/tmux" <<SHIM
#!/bin/bash
exec env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$TT" "$REAL_TMUX" -L "$SOCK" "\$@"
SHIM
chmod +x "$SHIMDIR/tmux"

cleanup() {
    # Scoped by -L: this can only ever reach the private socket.
    tx kill-server 2>/dev/null
    rm -rf "$TT" "$SHIMDIR"
}
trap cleanup EXIT

tx -f /dev/null new-session -d -s "$SESSION" -x 200 -y 50 2>/dev/null \
    || { echo "SKIP: cannot start a private tmux server here"; exit 0; }

priv=$(tx display-message -p '#{socket_path}' 2>/dev/null)
shim=$(PATH="$SHIMDIR:$PATH" tmux display-message -p '#{socket_path}' 2>/dev/null)
default_sock="/tmp/tmux-$(id -u)/default"
if [[ -z "$priv" || "$priv" == "$default_sock" || "$shim" != "$priv" ]]; then
    echo "REFUSING TO RUN: containment unproven (priv='$priv' shim='$shim' default='$default_sock')" >&2
    exit 1
fi
echo "containment proved: private socket $priv, shim agrees, default is $default_sock"
echo

# pane-state.sh resolves a BARE index against session `0` ("0:$target"), so a
# private server whose session is named anything else must be addressed with the
# explicit `<session>:<index>` form the script also accepts. Getting this wrong
# does not misclassify — it exits 3 "no such tmux window" — but it yields an
# EMPTY state that every assertion then compares against, which is why the
# expected-count guard below is not optional decoration.
ps_state() {  # ps_state <window-index> -> the bare state token
    PATH="$SHIMDIR:$PATH" bash "$PANE_STATE" "$SESSION:$1" 2>/dev/null \
        | head -1 | sed -n 's/.*state=\([a-z-]*\).*/\1/p'
}

# Same, with the #777 boot grace pinned to an explicit value.
#
# Grace 0 is how the negative controls stay meaningful. Every "genuinely dead"
# fixture below is a pane only SECONDS old — which, since #777, is also the
# shape of a spawn in progress, so asserting `absent` against it at the default
# grace would be asserting the very confusion the fix removes. Pinning the
# grace to 0 says "ignore the boot window and tell me what the process tree
# says", which is the property these controls were actually written to check.
ps_state_grace() {  # ps_state_grace <grace-seconds> <window-index>
    NEXUS_PANE_BOOT_GRACE_SECONDS="$1" PATH="$SHIMDIR:$PATH" \
        bash "$PANE_STATE" "$SESSION:$2" 2>/dev/null \
        | head -1 | sed -n 's/.*state=\([a-z-]*\).*/\1/p'
}

# Same, with a directory of deliberately blinded process tools in front.
ps_state_blind() {  # ps_state_blind <blind-dir> <window-index>
    PATH="$1:$SHIMDIR:$PATH" bash "$PANE_STATE" "$SESSION:$2" 2>/dev/null \
        | head -1 | sed -n 's/.*state=\([a-z-]*\).*/\1/p'
}
# Wait until a pane shell has no children left, then say whether it worked.
#
# The settle is load-bearing, not padding: "nothing is alive under this pane" is
# the precondition of every `absent` assertion below, and a pane whose rc
# children are still starting has not become that yet. On a loaded host (ambient
# 48 on 36 cores while sibling workers run their own suites) the old flat
# 10 x 1 s budget was observed to lapse, and when it does the assertion fails
# with `unknown` — which reads as a CLASSIFIER REGRESSION when it is really a
# fixture that never set up. That misattribution is the expensive kind: it
# points the next reader at the wrong file.
#
# So: a longer budget, and an explicit line when it is exhausted.
settle_childless() {  # settle_childless <pane-pid> <label>
    local pp="$1" label="$2" i
    for i in $(seq 1 30); do
        [[ -n "$pp" ]] && [[ -z "$(pgrep -P "$pp" 2>/dev/null)" ]] && return 0
        sleep 1
    done
    printf '  NOTE: %s did not settle childless within 30s — a failure just below is the FIXTURE, not the classifier (still alive: %s)\n' \
        "$label" "$(pgrep -P "$pp" 2>/dev/null | tr '\n' ' ')" >&2
    return 1
}

win_index() {
    tx list-windows -a -F '#{window_index} #{window_name}' 2>/dev/null \
        | awk -v w="$1" '$2==w{print $1; exit}'
}

# ---- Test 1: booting pane (live descendant, no claude) → NOT absent -----
#
# Stands in for a window whose spawn launcher is still running its preamble.
# `sleep` is a live non-zombie descendant of the pane shell, and there is no
# `claude` anywhere in the tree — byte for byte the situation #643 describes.

echo '=== a pane with a live descendant but no claude is NOT absent ==='
# `bash -c '"'"'sleep 300; true'"'"'`, not `sleep 300`. tmux runs a new-window command
# via `sh -c`, and a shell handed a SINGLE command exec-optimises itself away —
# so `new-window "sleep 300"` makes `sleep` the PANE PROCESS ITSELF, with no
# descendants, which is the shape of a DEAD pane, not a booting one. The
# trailing `; true` defeats the optimisation so the shell stays as the pane
# process with the long-running child underneath it, which is the real spawn
# shape: a pane shell running the launcher.
tx new-window -d -n boot643 "bash -c 'sleep 300; true'" >/dev/null 2>&1
sleep 1
bidx=$(win_index boot643)
if [[ -z "$bidx" ]]; then
    echo "  FAIL: could not create boot643 window" >&2; FAIL=$(( FAIL + 1 ))
else
    bstate=$(ps_state "$bidx")
    # The decisive assertion: NOT the kill-authorising state.
    assert_eq "booting pane does not report absent" \
              "$([[ "$bstate" == "absent" ]] && echo yes || echo no)" "no"
    # And specifically the honest value for "something runs, no agent yet".
    assert_eq "booting pane reports unknown" "$bstate" "unknown"
fi

# ---- Test 2: genuinely dead pane (no descendants) → still absent --------
#
# NEGATIVE CONTROL, and the one that keeps the fix honest. Downgrading `absent`
# is only safe if `absent` still fires when it should: a fix that simply stopped
# emitting it would pass Test 1 and destroy the state's entire purpose, leaving
# retire-preflight with no way to ever authorise a kill.

echo '=== a pane with nothing alive under it is STILL absent ==='
tx new-window -d -n dead643 >/dev/null 2>&1
sleep 1
didx=$(win_index dead643)
if [[ -z "$didx" ]]; then
    echo "  FAIL: could not create dead643 window" >&2; FAIL=$(( FAIL + 1 ))
else
    # Settle: the window's shell must have finished spawning its own children
    # (rc files etc.) before we assert "nothing alive underneath".
    pp=$(tx list-panes -a -F '#{window_index} #{pane_pid}' 2>/dev/null | awk -v i="$didx" '$1==i{print $2; exit}')
    settle_childless "$pp" "dead643 pane"
    # Grace 0: with the boot window taken out of the picture, the process-tree
    # verdict must still be `absent`. This is the assertion that keeps a dead
    # pane reapable, and the one a fix that merely stopped emitting `absent`
    # would fail.
    assert_eq "idle bare-shell pane still reports absent (grace 0)" \
              "$(ps_state_grace 0 "$didx")" "absent"
    # And the same pane at the DEFAULT grace must NOT be killable, because a
    # seconds-old pane with nothing under it is exactly what a spawn looks like
    # before its launcher is forked. Same window, same instant, opposite
    # verdict — the grace is doing the work, and nothing else is.
    assert_eq "same pane inside the boot grace is not killable" \
              "$(ps_state "$didx")" "unknown"
fi

# ---- Test 3: the transition is observed, not assumed --------------------
#
# Test 1 and 2 are two different windows; a classifier keyed on something
# incidental (window name, index parity, creation order) could satisfy both. So
# watch ONE window cross the boundary: kill its descendant and require the
# verdict to move unknown → absent.

echo '=== one window crossing the boundary: unknown -> absent ==='
# After the child is reaped the pane shell must SURVIVE with no descendants —
# that is the state under test. `; true` would let bash finish and the window
# close, and pane-state.sh then exits 3 on a vanished window, yielding an empty
# string rather than `absent`. A bare `read` blocks on the pane's tty forever
# and spawns nothing, so the shell stays as a childless pane process.
tx new-window -d -n flip643 "bash -c 'sleep 300; read -r _'" >/dev/null 2>&1
sleep 1
fidx=$(win_index flip643)
if [[ -z "$fidx" ]]; then
    echo "  FAIL: could not create flip643 window" >&2; FAIL=$(( FAIL + 1 ))
else
    before=$(ps_state "$fidx")
    fpp=$(tx list-panes -a -F '#{window_index} #{pane_pid}' 2>/dev/null | awk -v i="$fidx" '$1==i{print $2; exit}')
    # Kill by RECORDED PID only — never a cmdline pattern. Every agent on this
    # host runs the same `claude` binary in one PID namespace, so `pkill -f`
    # has already caused a mass-kill incident.
    for p in $(pgrep -P "$fpp" 2>/dev/null); do kill -TERM "$p" 2>/dev/null; done
    settle_childless "$fpp" "flip643 pane (after reaping its descendant)"
    after=$(ps_state_grace 0 "$fidx")
    assert_eq "same window, descendant alive → unknown" "$before" "unknown"
    assert_eq "same window, descendant reaped → absent" "$after" "absent"
fi

# ---- Test 4: the gap BEFORE the launcher exists -------------------------
#
# your-org/nexus-code#777. #643 covers a launcher that is ALREADY a descendant.
# Production never starts there: `spawn-worker.sh` runs `tmux new-window -d`
# with NO command, so tmux execs default-shell AS the pane process (verified on
# the live server: default-shell=/usr/bin/zsh, default-command=""), and the
# launcher becomes a descendant only after that shell finishes its rc chain and
# reads the `send-keys` bytes. In between, pane_pid has no descendants at all
# and descendant-liveness — #643's chosen axis — carries no information.
#
# This window is not hypothetical: reproduced 3 times in 5 spawns at the FIRST
# probe, 1.37-2.05 s in, against a pane with pane_dead=0 and a healthy shell.

echo '=== a pane whose launcher has not been forked yet is NOT absent ==='
tx new-window -d -n gap777 >/dev/null 2>&1
gidx=$(win_index gap777)
if [[ -z "$gidx" ]]; then
    echo "  FAIL: could not create gap777 window" >&2; FAIL=$(( FAIL + 1 ))
else
    # Settle until the shell's own rc children are gone — that is the state
    # under test, and it is also the shape #643's guard cannot see.
    gpp=$(tx list-panes -a -F '#{window_index} #{pane_pid}' 2>/dev/null | awk -v i="$gidx" '$1==i{print $2; exit}')
    settle_childless "$gpp" "gap777 pane"
    assert_eq "pre-launcher pane does not report absent" \
              "$([[ "$(ps_state "$gidx")" == "absent" ]] && echo yes || echo no)" "no"
fi

# ---- Test 5: the grace SELF-CLEARS (anti-leak control) ------------------
#
# The trade #777 makes is a bounded reap DELAY. That is only true if the grace
# actually lapses — a fix that made a dead pane permanently unreapable would
# have traded a kill hazard for a leak, which is not an improvement. Pin the
# grace to 2 s against the same childless pane and require the verdict to move
# on its own, with nothing else changing.

echo '=== the boot grace lapses: unknown -> absent with no other change ==='
if [[ -n "${gidx:-}" ]]; then
    early=$(ps_state_grace 3600 "$gidx")   # a grace this pane cannot be older than
    sleep 3
    late=$(ps_state_grace 2 "$gidx")       # a grace it now certainly exceeds
    assert_eq "inside the grace → unknown" "$early" "unknown"
    assert_eq "past the grace → absent"    "$late"  "absent"
fi

# ---- Tests 6-7: "we could not look" is not "nothing is there" -----------
#
# your-org/nexus-code#777. `_pane_has_live_claude` and
# `_pane_has_live_descendant` answer "no" both when the tree is empty and when
# `ps`/`pgrep` could not tell them — and the gate used to convert the second
# into `absent`. That is `#612`'s "exit 79 NOT CHECKED, never 0" reproduced
# inside this file, thirty lines from a tmux-missing arm that already reasons
# the other way. Measured on this host before the fix: BOTH stubs → state=absent
# against a fixture whose bytes classify alive.
#
# The pane used here has a live descendant, so a sighted classifier says
# `unknown` and a blind one must not say something STRONGER than that.

BLIND=$(mktemp -d)
trap 'tx kill-server 2>/dev/null; rm -rf "$TT" "$SHIMDIR" "$BLIND"' EXIT

echo '=== a blinded process view must not authorise a kill ==='
tx new-window -d -n blind777 "bash -c 'sleep 300; read -r _'" >/dev/null 2>&1
sleep 1
xidx=$(win_index blind777)
if [[ -z "$xidx" ]]; then
    echo "  FAIL: could not create blind777 window" >&2; FAIL=$(( FAIL + 1 )); FAIL=$(( FAIL + 1 ))
else
    printf '#!/bin/sh\nexit 1\n' > "$BLIND/pgrep"; chmod +x "$BLIND/pgrep"
    assert_eq "pgrep blind → not absent" \
              "$([[ "$(ps_state_blind "$BLIND" "$xidx")" == "absent" ]] && echo yes || echo no)" "no"
    rm -f "$BLIND/pgrep"
    printf '#!/bin/sh\nexit 1\n' > "$BLIND/ps"; chmod +x "$BLIND/ps"
    assert_eq "ps blind → not absent" \
              "$([[ "$(ps_state_blind "$BLIND" "$xidx")" == "absent" ]] && echo yes || echo no)" "no"
    rm -f "$BLIND/ps"
fi

# ---- Test 8: tmux's own death signal outranks the grace -----------------
#
# `#{pane_dead}` is tmux asserting first-hand that the pane process exited (the
# pane lingers only because `remain-on-exit on`, which is what production sets).
# That is a positive observation of death, not an inference from an empty tree,
# so it must produce `absent` even inside the boot grace — otherwise the grace
# would delay the reap of a spawn that died on the launch pad, which is a real
# outcome (the shim precondition refuses with 78) and not a rare one.

echo '=== a tmux-confirmed dead pane is absent even inside the grace ==='
tx set-option -g remain-on-exit on >/dev/null 2>&1
tx new-window -d -n rip777 "bash -c 'exit 0'" >/dev/null 2>&1
ridx=$(win_index rip777)
if [[ -z "$ridx" ]]; then
    echo "  FAIL: could not create rip777 window" >&2; FAIL=$(( FAIL + 1 ))
else
    # POLL for pane_dead rather than sleeping a guessed interval. A fixed
    # `sleep 1` raced under load (observed pane_dead=0 at ambient load 48 on 36
    # cores) and a fixture that fails to set up reads as a test failure, which
    # is how a real regression gets mistaken for flakiness and dismissed.
    rdead=
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        rdead=$(tx list-panes -a -F '#{window_index} #{pane_dead}' 2>/dev/null | awk -v i="$ridx" '$1==i{print $2; exit}')
        [[ "$rdead" == 1 ]] && break
        sleep 1
    done
    if [[ "$rdead" != 1 ]]; then
        echo "  FAIL: rip777 pane is not dead (pane_dead=$rdead) — fixture did not set up" >&2
        FAIL=$(( FAIL + 1 ))
    else
        # Default grace, pane seconds old: only the pane_dead arm can produce
        # `absent` here.
        assert_eq "dead pane inside the grace still reports absent" \
                  "$(ps_state "$ridx")" "absent"
    fi
fi
tx set-option -g remain-on-exit off >/dev/null 2>&1

# =========================================================================
# your-org/nexus-code#788 — `absent` must be a DECISION with named evidence
# =========================================================================
#
# `#780` (tests 1-8 above) closed ONE of three sites that reached the
# kill-authorising state by falling through. The two below were closed by
# neither `#780` nor `#776`, and the first of them is LIVE: it sits AFTER the
# liveness gate has already found a live `claude`, and emits `absent` anyway
# because an empty capture short-circuits past everything the classifier just
# established.
#
# A `claude`-comm process is needed for both. `/proc/<pid>/comm` comes from the
# basename of the EXECUTABLE the kernel loads — not argv[0], not the script name
# (`#554`) — so copying a real binary to a file named `claude` is what makes
# `_pane_has_live_claude` match. `sleep` is used because it is deterministic and
# renders nothing.
CLAUDEBIN=$(mktemp -d)
CAPFAIL=$(mktemp -d)
trap 'tx kill-server 2>/dev/null; rm -rf "$TT" "$SHIMDIR" "$BLIND" "$CLAUDEBIN" "$CAPFAIL"' EXIT
cp "$(command -v sleep)" "$CLAUDEBIN/claude"

# A tmux shim identical to $SHIMDIR/tmux except that `capture-pane` fails the
# way a busy server would: rc 1, nothing on stdout. Every other subcommand still
# reaches the private socket, so `display-message` keeps answering and the pane
# really is alive — which is the whole point. This stubs the EXTERNAL TOOL, the
# same idiom tests 6-7 use to blind `ps`/`pgrep`.
cat > "$CAPFAIL/tmux" <<CAPSHIM
#!/bin/bash
for a in "\$@"; do [ "\$a" = capture-pane ] && exit 1; done
exec env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$TT" "$REAL_TMUX" -L "$SOCK" "\$@"
CAPSHIM
chmod +x "$CAPFAIL/tmux"

ps_emit() {  # ps_emit <window-index> -> the whole emit line
    PATH="$SHIMDIR:$PATH" bash "$PANE_STATE" "$SESSION:$1" 2>/dev/null | head -1
}
ps_emit_capfail() {  # ps_emit <window-index>, with capture-pane broken
    PATH="$CAPFAIL:$PATH" bash "$PANE_STATE" "$SESSION:$1" 2>/dev/null | head -1
}
_field() { sed -n "s/.*\\b$2=\\([A-Za-z0-9_-]*\\).*/\\1/p" <<<"$1"; }

# ---- Test 9: THE THIRD SITE. Failed capture on a pane with a LIVE agent --
#
# Measured at 16728e7 on a real private-socket server, same pane, same instant,
# `claude` at the pane root and `pane_dead=0`:
#
#     healthy tmux       -> state=idle
#     capture-pane rc=1  -> state=absent          <-- kill-authorising
#
# One transient failure of one tmux subcommand flipped a healthy worker into the
# one state that authorises killing it. `|| pane_ansi=` discarded the rc, so
# "the capture failed" and "the pane is blank" arrived at the same arm.
echo '=== a FAILED capture must not authorise a kill on a live agent ==='
tx new-window -d -n capfail788 "exec bash -c 'printf \"working\\n\"; exec $CLAUDEBIN/claude 300'" >/dev/null 2>&1
sleep 2
cidx=$(win_index capfail788)
if [[ -z "$cidx" ]]; then
    echo "  FAIL: could not create capfail788 window" >&2
    FAIL=$(( FAIL + 4 ))
else
    # Precondition: the pane really does host a live claude. Without this the
    # assertions below could pass for the wrong reason on a host where the
    # copied binary does not present comm=claude.
    cpp=$(tx list-panes -a -F '#{window_index} #{pane_pid}' 2>/dev/null | awk -v i="$cidx" '$1==i{print $2; exit}')
    ccomm=$(ps -o comm= -p "$cpp" 2>/dev/null | tr -d '[:space:]')
    assert_eq "capfail788 pane really hosts a live claude (precondition)" "$ccomm" "claude"
    cf=$(ps_emit_capfail "$cidx")
    assert_eq "failed capture on a live-agent pane is NOT absent" \
              "$([[ "$(_field "$cf" state)" == "absent" ]] && echo yes || echo no)" "no"
    # And the refusal must be for the RIGHT reason. Asserting only "not absent"
    # would also pass if the pane had simply stopped resolving.
    assert_eq "failed capture refuses because claude is alive" "$(_field "$cf" reason)" "live-claude"
    assert_eq "the capture failure is reported as itself, not as a blank pane" \
              "$(_field "$cf" capture)" "failed"
fi

# ---- Test 10: an EMPTY capture on a pane with a LIVE agent --------------
#
# The other half of the same conflation, and it needs no broken tool: a pane that
# has rendered nothing yet captures as zero bytes at rc 0. The repo had already
# hit this from the other end — `test-integration/test-same-name-recycle.sh:344`
# documents the ~250 ms post-`new-window` window where "capture-pane briefly
# returns nothing — pane-state emits `state=absent` then because the renderer
# signal is empty" — and worked around it with a `wait_for` instead of fixing it.
echo '=== an EMPTY capture must not authorise a kill on a live agent ==='
tx new-window -d -n silent788 "exec $CLAUDEBIN/claude 300" >/dev/null 2>&1
sleep 2
sidx=$(win_index silent788)
if [[ -z "$sidx" ]]; then
    echo "  FAIL: could not create silent788 window" >&2
    FAIL=$(( FAIL + 1 )); FAIL=$(( FAIL + 1 ))
else
    # `$( )` strips trailing newlines, which is EXACTLY what pane-state.sh's own
    # `pane_ansi=$(tmux capture-pane ...)` does — so this measures the string the
    # classifier actually sees. `wc -c` would count one newline per blank row and
    # report 50 for the same pane: the precondition would fail while the very
    # condition it asserts holds perfectly.
    scap=$(tx capture-pane -t "$SESSION:$sidx" -p -e -J -S -25 2>/dev/null)
    assert_eq "silent788 pane captures as zero bytes (precondition)" "${#scap}" "0"
    se=$(ps_emit "$sidx")
    assert_eq "empty capture on a live-agent pane is NOT absent" \
              "$([[ "$(_field "$se" state)" == "absent" ]] && echo yes || echo no)" "no"
fi

# ---- Test 11: ONE DOOR. The structural invariant, asserted on the source -
#
# Tests 9-10 close two sites. This is what stops a fourth from appearing: the
# class regenerated three times (`#643` -> `#777` -> `#788`) precisely because
# every emit site re-derived the verdict for itself, so fixing one bought the
# next. `_emit_absent_or_unknown` is now the only thing permitted to emit
# `absent`, and that is a property of the FILE — checkable here, and cheap.
# NO BACKTICKS IN THE assert LABELS BELOW. A backtick inside a double-quoted
# label is COMMAND SUBSTITUTION: the first draft here read
#     assert_eq "exactly one `emit absent` in pane-state.sh" ...
# which EXECUTED `emit absent` (rc 127, "emit: command not found" on stderr) and
# then compared a label with the words silently deleted. The assertion still
# PASSED, on a mangled label — a confident green from a probe that had partly
# not run, which is the defect class this whole file exists to catch, reproduced
# inside the test written to catch it.
echo '=== absent has exactly one emitter ==='
n_emit=$("$REAL_GREP" -c '^[[:space:]]*emit absent' "$PANE_STATE")
assert_eq "exactly one emit-absent call in pane-state.sh" "$n_emit" "1"
# ...and it is inside the door, not merely unique. A single `emit absent` that
# had drifted out of `_emit_absent_or_unknown` into some other function would
# satisfy the count and defeat the design.
door_body=$(awk '/^_emit_absent_or_unknown\(\)/{f=1} f{print} f&&/^}/{exit}' "$PANE_STATE")
assert_eq "the one emit-absent call lives inside _emit_absent_or_unknown" \
          "$("$REAL_GREP" -c 'emit absent' <<<"$door_body")" "1"
# No hand-rolled `state=absent` printf/echo bypassing `emit` either — that is how
# the `#140` bogus-index arm used to manufacture one.
assert_eq "no raw state=absent emitted outside emit()" \
          "$("$REAL_GREP" -c '\(echo\|printf\).*state=absent' "$PANE_STATE")" "0"

# ---- Test 12: every `absent` names its evidence -------------------------
echo '=== an absent verdict always names its positive evidence ==='
if [[ -n "${didx:-}" ]]; then
    de=$(NEXUS_PANE_BOOT_GRACE_SECONDS=0 PATH="$SHIMDIR:$PATH" \
        bash "$PANE_STATE" "$SESSION:$didx" 2>/dev/null | head -1)
    assert_eq "dead pane's absent carries an evidence token" \
              "$(_field "$de" evidence)" "tree-empty-past-grace"
else
    echo "  FAIL: dead643 window index unavailable — Test 12 could not run" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 13: the deferral LAPSES ---------------------------------------
#
# THE MIRROR-IMAGE FAILURE, and the one a fix like this is most likely to buy by
# accident. Withholding `absent` is only safe if the withholding ENDS: a grace
# that never lapsed would trade `#777`'s kill hazard for an unreapable pane, and
# every assertion above would still pass. So drive the SAME pane at two graces
# and require the verdict to change. Deterministic — no waiting on a clock, and
# it reddens rather than hanging if the deferral ever becomes permanent.
echo '=== the boot-grace deferral lapses with the pane age ==='
if [[ -n "${didx:-}" ]]; then
    assert_eq "inside the grace, a dead-but-young pane defers" \
              "$(ps_state_grace 86400 "$didx")" "unknown"
    assert_eq "past the grace, the SAME pane is absent" \
              "$(ps_state_grace 0 "$didx")" "absent"
else
    echo "  FAIL: dead643 window index unavailable — Test 13 could not run" >&2
    FAIL=$(( FAIL + 1 )); FAIL=$(( FAIL + 1 ))
fi

# ---- summary ------------------------------------------------------------
#
# Expected-count guard. An `assert_*` that never runs — a fixture that bailed
# early, a helper that vanished (rc 127 is counted by nothing) — otherwise
# reports 0 failures and reads as a pass. This suite's own dominant defect class
# is exit-0 for work not done; the count is what makes silence loud.
EXPECTED=24
echo
echo "=== summary: $PASS passed, $FAIL failed ($(( PASS + FAIL )) assertions; expected $EXPECTED) ==="
if (( PASS + FAIL != EXPECTED )); then
    echo "ASSERTION COUNT MISMATCH — $(( PASS + FAIL )) ran, $EXPECTED expected. Some assertion did not execute." >&2
    exit 1
fi
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
