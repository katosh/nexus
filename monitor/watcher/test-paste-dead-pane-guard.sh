#!/usr/bin/env bash
# test-paste-dead-pane-guard.sh — your-org/nexus-code#745.
#
# `tmux paste-buffer` into a pane tmux reports as `#{pane_dead}` KILLS
# THE TMUX SERVER. In this workspace that is the watcher, every worker
# window, the orchestrator and the sandbox session, and the operator
# cannot restart the nexus from inside. Measured 20/20 on the deployed
# tmux 2.6, on BOTH call forms in the tree.
#
# Three parts, because three different things can rot:
#
#   A  the PREDICATE — real tmux, not a mock. The claim is about what
#      `#{pane_dead}` and `#{pane_active}` do on the installed tmux, so
#      a mock would assert what we typed into a variable.
#   B  the CALL-SITE MANIFEST — every `tmux paste-buffer` in monitor/
#      must be guarded. A rule applied to the sites somebody happened
#      to be editing is not applied (your-org/nexus-code#735 F5); this
#      is what makes a FIFTH site loud instead of silent.
#   C  END-TO-END — drive the real helpers against a real corpse and
#      assert the server SURVIVES, with an unguarded positive control
#      in the same fixture proving the fixture can still kill it. A
#      "server survived" that cannot fail is not evidence.
#
# Gated behind SLOW_TESTS=1: it stands up real tmux servers (~10 s).
#
# SAFETY. Every server here is private (`env -u TMUX tmux -L <name>` —
# `$TMUX` outranks `TMUX_TMPDIR`, your-org/nexus-code#644) and is torn
# down with `kill-session`, NEVER `kill-server`: bwrap is PID 1 under
# `--die-with-parent`, so a bare `kill-server` ends the sandbox. Part C
# deliberately CRASHES its own private servers; that is the control.
#
# Run: SLOW_TESTS=1 bash monitor/watcher/test-paste-dead-pane-guard.sh

set -uo pipefail

if [ "${SLOW_TESTS:-0}" != "1" ]; then
    echo "skipped: $(basename "$0") (set SLOW_TESTS=1 to enable; ~10s, needs tmux)"
    exit 77   # SKIP, not PASS (your-org/nexus-code#568 A6)
fi

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
MON="$REPO_ROOT/monitor"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s (got %q)\n' "$label" "$got"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s: got %q, want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 ))
    fi
}
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
# env_fail — THE FIXTURE COULD NOT BUILD ITS SUBJECT (your-org/nexus-code#1025).
#
# That is evidence about the MACHINE, not about the guard, and calling `fail`
# for it reports a `#745` regression that did not happen. It has fired: on a
# loaded node a `remain-on-exit` corpse takes longer to form than the poll
# budget allowed, and three part-C legs went red reading exactly like "the
# guard broke". Worse than a wasted hour — a suite that cannot distinguish
# "the guard is broken" from "the fixture could not run" teaches readers to
# discount reds from a safety-critical guard.
#
# So ENV failures get their own counter, their own label, and their own exit
# status: 69 (EX_UNAVAILABLE) -> ledger status ENVSKIP, adopted from
# your-org/nexus-code#1283. They are NOT silent: an ENV-only run still reports
# what it could not do.
#
# WHY 69 AND NOT 77. 77 means SKIP, and this file uses it for exactly one
# thing: the SLOW_TESTS gate not being taken (:38). Both meanings on one code
# is #1283's collision, and this file carried BOTH sides of it 1,059 lines
# apart with OPPOSITE required treatments — :38 must stay loud, this arm must
# stop being red. A code that cannot tell "never ran" from "ran and could not
# conclude" cannot be read by the band, so #1283 gave the second its own.
ENVF=0
env_fail() { printf '  ENV-FAIL: %s\n' "$1" >&2; ENVF=$(( ENVF + 1 )); }

# THIS SITE EXITED 1 — RED — UNTIL your-org/nexus-code#1283, AND THAT WAS THE
# RIGHT CALL AT THE TIME. It is an ENV-FAIL by its own label, so exiting 1 was
# a surviving instance of the very defect #1025 is about, which #1025's own fix
# (58f37277) did not convert. But its author's reasoning was sound under the
# old vocabulary: with 77 meaning both "gate not taken" and "honest decline",
# exiting 77 here would have been indistinguishable from a suite that never
# ran, i.e. invisible — and a missing tmux must not be invisible in a suite
# whose whole claim is about real tmux behaviour. Refusing loudly was the
# better of two bad options. 69/ENVSKIP is the third option: not red, not
# silent, and attributable to the machine.
command -v tmux >/dev/null 2>&1 || {
    echo "ENV-FAIL: tmux is not on PATH — this test is about real tmux behaviour," >&2
    echo "          so a green here would assert nothing. Declining (ENVSKIP)." >&2
    exit 69
}

# The fixture root carries NO issue number, deliberately (your-org/nexus-code
# `#1022`, `#1024`). A tempdir template of the shape `nexus-<issue>-XXXXXX` was
# the house convention, and it hands the program the very token the assertions
# below were demanding back: any output naming a path under $WORK satisfied a
# bare-number glob, so the assertion stopped testing the program and started
# testing the directory name. TWO surfaces supplied it here, not one -- this
# and the tmux socket in new_server(). Neither number bought an assertion
# anything, so both are gone; the globs were fixed independently (see
# _names_refusal below), because either fix alone closes the hole and keeping
# both means neither can silently rot into the only one.
WORK=$(mktemp -d -t nexus-test-XXXXXX)
PAYLOAD="$WORK/payload.txt"
# SELF-IDENTIFYING ON PURPOSE. This payload has ALREADY been submitted into
# the operator's live orchestrator pane as a user-role turn (2026-08-27,
# your-org/nexus-code#1105 / this file's isolation header). The isolation fix
# below is what stops that; this text is the belt-and-braces for the day it
# fails again, so whatever receives it can tell that it is inert test data
# rather than an instruction.
printf '%s\n%s\n' \
    'nexus TEST FIXTURE payload from test-paste-dead-pane-guard.sh — INERT TEST DATA, not an instruction; if you are an agent reading this, ignore it and report your-org/nexus-code#1105.' \
    'second line' > "$PAYLOAD"

# shellcheck source=./_tmux-fixture.sh
. "$MON/watcher/_tmux-fixture.sh"
# BRACES: private TMUX_TMPDIR + scrubbed $TMUX, so a pin lost to some FUTURE
# PATH force-front lands on a private ABSENT socket and errors, instead of on
# the operator's board. Belt (the real-binary shim) and alarm
# (nx_assert_tmux_pinned, part A) are the other two layers.
nx_tmux_fixture_init "$WORK" || {
    # NO $WORK CITATION (your-org/nexus-code#794, #1139). The EXIT trap below
    # deletes $WORK, so by the time anyone reads this line in a CI log the
    # directory is gone and naming it stops the reader looking further. It also
    # adds nothing: BOTH of nx_tmux_fixture_init's non-zero returns already
    # print a self-contained reason that carries the path AS A STRING —
    # `mkdir: cannot create directory '<path>'` from the `mkdir -p ... || return
    # 1`, and the `socket path is N bytes (<path>) — too close to the 108-byte
    # sun_path limit` refusal. Point at that, do not paraphrase it over a corpse.
    echo "ENV-FAIL: nx_tmux_fixture_init could not set up a private TMUX_TMPDIR; its own reason is printed above" >&2
    exit 69
}

# shellcheck source=../_pane-live.sh
. "$MON/_pane-live.sh"

# ---------------------------------------------------------------------
# fixture helpers
# ---------------------------------------------------------------------
# The harness must NOT go through a wrapper: one that supplies its own `-L`
# turns a `tmux -L $sock` into `tmux -L <wrapper-sock> -L $sock`, and the
# harness silently drives the wrong server. Resolving "the real binary ONCE,
# before any PATH munging" was the old rule here and IT WAS NOT ENOUGH — it
# resolved to a wrapper, which is the defect named directly below.
#
# THE REAL BINARY, NEVER `command -v tmux` (your-org/nexus-code#1105).
# `command -v tmux` under an agent is monitor/tmuxwrap/tmux. Building the shim
# from it interpolates the wrapper's own path into the shim's body, tmuxwrap's
# gate-3 then classifies the SHIM as a wrapper and skips it, and a bare `tmux`
# inside any child `bash -c` reaches the real tmux WITH NO -L — i.e. the
# operator's board, because $TMUX outranks $TMUX_TMPDIR (#644). That is not a
# hypothetical: on 2026-08-27 the part-C main.sh leg below pasted AND SUBMITTED
# this fixture's payload into the live orchestrator pane, four times.
TMUX_BIN=$(nx_real_tmux_bin) || {
    echo "ENV-FAIL: no real tmux BINARY on PATH (only wrappers) — this suite" >&2
    echo "          cannot isolate itself, and running it unisolated is how" >&2
    echo "          your-org/nexus-code#1105 happened. Refusing." >&2
    exit 69
}
_SOCKS=()
# Sets $SOCK; deliberately does NOT echo it, and the callers deliberately do
# not use command substitution. Assigning from `$( new_server … )` runs the
# function in a SUBSHELL, so the `_SOCKS+=(…)` bookkeeping never reached the
# parent, the EXIT trap iterated an EMPTY array, and every call leaked one
# private tmux server holding sleeping processes. Measured: ~64 servers left
# behind across one mutation session, on a shared node. Keep the bookkeeping
# in the shell that owns the trap.
# _names_refusal <text> -- did the PROGRAM say why it refused?
#
# The predicate must match on a phrase the FIXTURE cannot supply
# (your-org/nexus-code#1022). The two call sites below used to accept a bare
# `*745*`, and this suite manufactured `745` in both its tempdir and its tmux
# socket name, so any diagnostic quoting a path satisfied the assertion -- a
# successful paste with the guard deleted passed it. Measured: the E3 subject
# on the broken path is `paste-followup: pasted (... no heartbeat at
# /tmp/nexus-745-.../heartbeat/victim.json ...)`, which carries the token and
# no refusal at all.
#
# The phrases below are transcribed from the emit sites, and the set is a
# COVER of every refusal reachable on the two paths asserted here -- checked
# per path rather than assumed:
#
#   paste-followup.sh:784  dead pane      "DEAD pane" / "Refusing to paste"
#   paste-followup.sh:397  resolver rc 3  "refusing to paste"
#   paste-followup.sh:436  resolver rc 3  "refusing to paste"
#   paste-followup.sh:421  no _pane-live  "refusing to paste"
#   _pane-live.sh:196      verdict unknown "REFUSING to paste"
#
# Three casings, because the emit sites genuinely differ; `shopt -s nocasematch`
# would cover them in one line and is deliberately NOT used, since it changes
# every other `case` in this file's scope.
#
# NOT claimed: that a refusal is CORRECT, only that one was NAMED. The potent
# assertions beside each call site ("server SURVIVED", "attempted NO
# paste-buffer") are what hold the safety property; this one holds the
# diagnosability property, which is why it is allowed to be textual at all.
_names_refusal() {
    case "$1" in
        *"DEAD pane"*|*"refusing to paste"*|*"Refusing to paste"*|*"REFUSING to paste"*)
            return 0 ;;
    esac
    return 1
}

new_server() {                      # new_server <suffix> -> sets $SOCK
    SOCK="nexus-test-$$-$1"      # no issue number: see the $WORK note above
    _SOCKS+=("$SOCK")
    env -u TMUX "$TMUX_BIN" -L "$SOCK" new-session -d -s m -n base 'sleep 120' 2>/dev/null
}
tx() { local s="$1"; shift; env -u TMUX "$TMUX_BIN" -L "$s" "$@"; }
server_alive() { tx "$1" list-sessions >/dev/null 2>&1; }
teardown_all() {
    local s sess
    for s in ${_SOCKS[@]+"${_SOCKS[@]}"}; do
        server_alive "$s" || continue
        while IFS= read -r sess; do
            [[ -n "$sess" ]] && tx "$s" kill-session -t "$sess" 2>/dev/null
        done < <(tx "$s" list-sessions -F '#{session_name}' 2>/dev/null)
    done
    rm -rf "$WORK"
}
trap teardown_all EXIT

# CORPSE BUDGET — LOAD-AWARE, not a bare 50 polls (your-org/nexus-code#1025).
#
# A fixed poll count encodes an assumption about scheduler latency that is
# false on a shared node. Measured: the old budget was 5 s (50 x 0.1 s), and at
# load ~40 (7886 threads) a remain-on-exit corpse took ~7.25 s to form — so the
# fixture timed out and three legs reported a `#745` regression that had not
# happened. Scale with the 1-minute load average, floor at the old 5 s, ceiling
# at 60 s so a wedged fixture still terminates. $CORPSE_BUDGET_POLLS overrides
# it outright for anyone who needs a fixed number.
#
# This is the SECOND half of #1025 and NOT the load-bearing one: a longer
# budget still fails eventually, and the point is that when it does it must
# fail as ENV-FAIL rather than FAIL. Classification is the fix; this only makes
# the classification fire less often.
_corpse_budget_polls() {
    if [[ -n "${CORPSE_BUDGET_POLLS:-}" ]]; then printf '%s' "$CORPSE_BUDGET_POLLS"; return; fi
    local load polls
    load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null) || load=0
    # polls = 50 * (1 + load/10), clamped to [50, 600] -> 5 s .. 60 s
    polls=$(awk -v l="${load:-0}" 'BEGIN{p=int(50*(1+l/10)); if(p<50)p=50; if(p>600)p=600; print p}')
    printf '%s' "${polls:-50}"
}

# make_corpse <sock> <winname> — window whose process has exited, kept
# by remain-on-exit. Preset the option so the corpse forms
# deterministically rather than racing the child's exit (#741).
make_corpse() {
    local s="$1" w="$2" i d budget
    budget=$(_corpse_budget_polls)
    tx "$s" set-option -g remain-on-exit on 2>/dev/null
    tx "$s" new-window -d -n "$w" 'exit 1' 2>/dev/null
    for i in $(seq 1 "$budget"); do
        d=$(tx "$s" list-panes -s -F '#{window_name} #{pane_dead}' 2>/dev/null \
              | awk -v w="$w" '$1 == w && !seen { print $2; seen = 1 }')
        [[ "$d" == "1" ]] && return 0
        sleep 0.1
    done
    return 1
}

# route a bare `tmux` (what the helpers call) to a private socket
route_tmux_to() {
    local sock="$1"
    # nx_write_tmux_shim REFUSES to build a shim from a wrapper, which is the
    # whole of your-org/nexus-code#1105 expressed as a precondition rather than
    # as a comment. $ROUTED_SOCK records what the pin is currently supposed to
    # be, so the part-A alarm can check it.
    nx_write_tmux_shim "$WORK/bin" "$TMUX_BIN" "$sock" || {
        echo "ENV-FAIL: could not write the private-tmux shim" >&2
        exit 69
    }
    ROUTED_SOCK="$sock"
    PATH="$WORK/bin:$PATH"; export PATH
}

# =====================================================================
echo '=== A: the predicate, against real tmux ==='
# =====================================================================
new_server a; SA="$SOCK"
route_tmux_to "$SA"

# --- THE ISOLATION ALARM, FIRST (your-org/nexus-code#1105) ------------------
# Before asserting anything about the guard, assert that this suite is talking
# to its OWN tmux server. Everything below drives code that calls a bare
# `tmux`, and if that resolves to anything but the fixture's socket then every
# result in parts A, C, D and E is a measurement of the wrong server — and the
# legs that PASTE are operating on whatever board they landed on.
#
# CHECKED FROM INSIDE A NEW `bash -c`, not from this shell, and the distinction
# is the entire point: $BASH_ENV is sourced at the start of every
# non-interactive shell and force-fronts monitor/tmuxwrap ahead of the PATH
# this suite exported. So the suite's own shell sees the pin while its `bash -c`
# legs did not — which is exactly how this went unnoticed. Measured on
# 2026-08-27: the part-C main.sh leg reached /tmp/tmux-<uid>/default (the
# operator's board, windows `services orchestrator panelive notify`), resolved
# the LIVE window named `orchestrator`, and pasted AND SUBMITTED this fixture's
# payload into it as a user-role turn. Four arrivals in 31 s.
#
# This assertion is a FAIL, not an ENV-FAIL: a displaced pin is a defect in the
# harness, and continuing would produce confident numbers about a foreign
# server. It aborts rather than accumulating them.
_want_sock="${TMUX_TMPDIR}/tmux-$(id -u)/${ROUTED_SOCK}"
if nx_assert_tmux_pinned "$WORK/bin" "$_want_sock"; then
    pass "A: ISOLATION CONTROL — a child \`bash -c\` reaches the FIXTURE socket, not the board (#1105)"
else
    fail "A: ISOLATION CONTROL — the code under test would drive a DIFFERENT tmux server than the fixture's; every result below would be about that server (#1105)"
    echo "=== summary: $PASS passed, $FAIL failed ===" >&2
    echo "SOME TESTS FAILED" >&2
    exit 1
fi

tx "$SA" new-window -d -n livewin 'sleep 120' 2>/dev/null
sleep 0.3
_tmux_pane_is_dead livewin; rc=$?
assert_eq "live window -> rc=1 (not dead, paste allowed)" "$rc" "1"

# EXIT 69, NOT 1 (your-org/nexus-code#1025, code from #1283). This line is the
# one the issue's title is about, and its own body quoted it as the CORRECT
# pattern — wrongly. Labelling a failure `ENV-FAIL` and then exiting 1 still
# hands run-tests.sh a product red: the label said "the machine" while the
# status said "the guard broke", and THE STATUS IS THE HALF THE RUNNER READS.
# The other four environment exits in this file (the fixture init, the
# real-binary probe, the shim writer, the missing-tmux refusal) use 69 too.
make_corpse "$SA" deadwin || {
    echo "ENV-FAIL: no corpse formed (tmux $(tmux -V)) — the fixture could not" >&2
    echo "          build its subject on this machine; not evidence about the guard." >&2
    exit 69
}
_tmux_pane_is_dead deadwin; rc=$?
assert_eq "remain-on-exit corpse -> rc=0 (dead, REFUSE)" "$rc" "0"

# the corpse must not condemn its neighbours
_tmux_pane_is_dead livewin; rc=$?
assert_eq "live sibling of a corpse -> rc=1" "$rc" "1"

# @id form (paste-followup.sh targets by @id)
wid=$(tx "$SA" list-windows -a -F '#{window_name} #{window_id}' 2>/dev/null \
        | awk '$1 == "deadwin" && !seen { print $2; seen = 1 }')
if [[ -n "$wid" ]]; then
    _tmux_pane_is_dead "$wid"; rc=$?
    assert_eq "corpse addressed by @id -> rc=0" "$rc" "0"
else
    fail "could not resolve @id for the corpse"
fi

# %pane form
pid=$(tx "$SA" list-panes -a -F '#{window_name} #{pane_id}' 2>/dev/null \
        | awk '$1 == "deadwin" && !seen { print $2; seen = 1 }')
if [[ -n "$pid" ]]; then
    _tmux_pane_is_dead "$pid"; rc=$?
    assert_eq "corpse addressed by %pane -> rc=0" "$rc" "0"
else
    fail "could not resolve %pane for the corpse"
fi

# a name nobody holds: not provably dead -> proceed (the paste will
# simply fail, harmlessly)
_tmux_pane_is_dead zz-no-such-window; rc=$?
assert_eq "unheld name -> rc=1 (proceed; paste fails harmlessly)" "$rc" "1"
assert_eq "unheld name -> verdict 'absent' (tmux cannot resolve it either)" \
    "${NEXUS_PANE_LIVE_VERDICT:-unset}" "absent"

# EMPTY TARGET -> REFUSE (#1017). This assertion is the REVERSE of what
# it was, and the reason is measured rather than stylistic: on tmux 2.6
# `-t ''` does NOT error, it resolves to the CURRENT pane
# (`display-message -p -t '' '#{pane_id}'` -> `%0`, rc 0). So the old
# rc=1 did not mean "this paste fails harmlessly", it meant "paste into
# an unexamined pane" — and if that pane is a corpse, the server dies.
_tmux_pane_is_dead "" 2>/dev/null; rc=$?
assert_eq "empty target -> rc=0 (REFUSE: tmux would redirect to the CURRENT pane)" "$rc" "0"
assert_eq "empty target -> verdict 'unknown' (retryable, NOT a corpse)" \
    "${NEXUS_PANE_LIVE_VERDICT:-unset}" "unknown"

# THE ACTIVE PANE IS THE ONE THAT MATTERS, both directions. A
# window-level "holds any live pane" test is wrong each way; these two
# assertions are what pin that.
tx "$SA" new-window -d -n splitwin 'sleep 120' 2>/dev/null
tx "$SA" split-window -t splitwin 'exit 1' 2>/dev/null
# POLL for the split pane's death rather than sleeping a guessed second.
# A fixed sleep made this assertion flaky under load — it read
# `panes: 0010` (nothing dead yet) and failed for a reason that had
# nothing to do with the predicate.
act=''
for _i in $(seq 1 50); do
    act=$(tx "$SA" list-panes -t splitwin -F '#{pane_active}#{pane_dead}' 2>/dev/null | tr -d '\n')
    [[ "$act" == *"11"* ]] && break
    sleep 0.1
done
if [[ "$act" == *"11"* ]]; then
    _tmux_pane_is_dead splitwin; rc=$?
    assert_eq "dead pane is ACTIVE (live sibling present) -> rc=0 (REFUSE)" "$rc" "0"
    liveidx=$(tx "$SA" list-panes -t splitwin -F '#{pane_index} #{pane_dead}' 2>/dev/null \
                | awk '$2 == "0" && !seen { print $1; seen = 1 }')
    tx "$SA" select-pane -t "splitwin.$liveidx" 2>/dev/null
    _tmux_pane_is_dead splitwin; rc=$?
    assert_eq "live pane is ACTIVE (dead sibling present) -> rc=1 (allow)" "$rc" "1"
else
    fail "split fixture did not produce an active dead pane (panes: $act)"
fi

# A query that cannot be answered is not "live" either (#1017). The
# hazard is arguably unreachable without tmux — the caller's own bare
# `tmux` resolves through this same PATH — but this is the one branch a
# future caller holding an absolute tmux path would inherit as a false
# negative, and refusing costs only a paste that could not have landed.
PATH_SAVED="$PATH"
EMPTY=$(mktemp -d); PATH="$EMPTY"
_tmux_pane_is_dead deadwin 2>/dev/null; rc=$?
PATH="$PATH_SAVED"; rmdir "$EMPTY"
assert_eq "no tmux on PATH -> rc=0 (REFUSE: no evidence of liveness)" "$rc" "0"
assert_eq "no tmux on PATH -> verdict 'unknown'" "${NEXUS_PANE_LIVE_VERDICT:-unset}" "unknown"

# PREFIX MATCHING (#1017). tmux target resolution is prefix-based:
# measured on 2.6, `-t orch` resolves to window `orchestrator`. So an
# exact-match miss in our own table walk does NOT mean the paste misses
# — it can still be delivered, possibly to a corpse. `deadwin` is a
# corpse in $SA from the fixture above; `deadwi` names no window.
_tmux_pane_is_dead deadwi 2>/dev/null; rc=$?
assert_eq "prefix of a CORPSE's name -> rc=0 (REFUSE; tmux would resolve it)" "$rc" "0"
assert_eq "prefix of a corpse's name -> verdict 'unknown'" \
    "${NEXUS_PANE_LIVE_VERDICT:-unset}" "unknown"

STUB_EMPTY="$WORK/emptybin"; mkdir -p "$STUB_EMPTY"

# =====================================================================
echo '=== B: call-site manifest — every paste-buffer is guarded ==='
# =====================================================================
# Discovered from the HAZARD (every real `tmux paste-buffer`
# invocation), never from a hand-kept list — the list is what rots.
# Comment lines are excluded; a comment mentioning the verb is not a
# call. Test files are out of scope: they drive private fixture servers
# on purpose.
# `tmux paste-buffer` inside a QUOTED STRING is a diagnostic, not a call
# (paste-followup.sh's own `die "tmux paste-buffer failed …"` is one, and
# the first cut of this discovery counted it — 5 sites where the tree has
# 4). Drop lines whose match sits inside double quotes.
paste_sites=$(command grep -rn 'tmux paste-buffer' --include='*.sh' "$MON" 2>/dev/null \
    | command grep -v '/test' \
    | command grep -vE ':[0-9]+:[[:space:]]*#' \
    | command grep -vE '"[^"]*tmux paste-buffer')

if [[ -z "$paste_sites" ]]; then
    fail "B: found ZERO paste-buffer sites — the discovery is broken, and a green here would be vacuous"
else
    nsites=$(printf '%s\n' "$paste_sites" | command grep -c .)
    # The FILE SET is declared, so a fifth site cannot appear silently —
    # a new file goes red until somebody classifies it, which is the
    # whole point (your-org/nexus-code#735 F5, #682's manifest pattern).
    EXPECTED_PASTE_FILES='monitor/paste-followup.sh
monitor/watcher/_respawn.sh
monitor/watcher/_unstick.sh
monitor/watcher/main.sh'
    # Both sides through the SAME `sort -u`: the collation here is
    # locale-dependent (it orders `main.sh` before `_respawn.sh`), so
    # comparing a hand-ordered literal against sorted output fails on
    # ordering alone and says nothing about the set.
    got_files=$(printf '%s\n' "$paste_sites" | sed "s|^$MON|monitor|" | cut -d: -f1 | sort -u)
    want_files=$(printf '%s\n' "$EXPECTED_PASTE_FILES" | sort -u)
    if [[ "$got_files" == "$want_files" ]]; then
        pass "B: paste-buffer file set matches the manifest ($nsites site(s) in 4 files)"
    else
        fail "B: paste-buffer FILE SET changed — classify the new/removed site, do not widen this test."$'\n'"expected:"$'\n'"$want_files"$'\n'"got:"$'\n'"$got_files"
    fi
    unguarded=''
    while IFS= read -r site; do
        [[ -n "$site" ]] || continue
        f="${site%%:*}"
        # A MENTION IS NOT A CALL, and this check used to accept one.
        # Every consumer names `_tmux_pane_is_dead` three times: the
        # `declare -F` probe, the fallback DEFINITION, and the actual
        # call. A bare `grep -q` matches the first two, so DELETING THE
        # CALL from paste-followup.sh (the 20/20 `-p -d` form) or from
        # main.sh left this suite 31/31 GREEN — measured. The fallback
        # added in this very PR is what blinded it: before that, the
        # only mention WAS the call.
        #
        # Require a COMMAND-POSITION call, and require it to precede the
        # paste. `_tmux_pane_is_dead() {` (definition) and
        # `declare -F _tmux_pane_is_dead` (probe) are excluded by shape,
        # not by line number, so moving them cannot re-blind this.
        # `!seen` rather than `head -1`: an early-exit reader on the
        # right of a pipe under `pipefail` enters
        # early-exit-readers.manifest (#682) as a site a reviewer must
        # look at. Second time this manifest has caught this file;
        # draining a handful of lines costs nothing.
        call_line=$(command grep -nE '(^|[;&|]|\bif\b|\bthen\b|\belif\b|!)[[:space:]]*_tmux_pane_is_dead[[:space:]]' "$f" \
            | command grep -vE '_tmux_pane_is_dead[[:space:]]*\(\)' \
            | command grep -v 'declare -F' \
            | awk -F: '!seen { print $1; seen = 1 }')
        paste_line="${site#*:}"; paste_line="${paste_line%%:*}"
        if [[ -z "$call_line" ]]; then
            unguarded+="${unguarded:+$'\n'}$site (no command-position CALL to _tmux_pane_is_dead)"
        elif (( call_line >= paste_line )); then
            unguarded+="${unguarded:+$'\n'}$site (guard called at line $call_line, AFTER the paste at $paste_line)"
        fi
    done <<<"$paste_sites"
    if [[ -z "$unguarded" ]]; then
        pass "B: every paste-buffer call site's file calls _tmux_pane_is_dead"
    else
        fail "B: paste-buffer site(s) with no CALL to the guard before the paste — each can kill the tmux server (#745):"$'\n'"$unguarded"
    fi
    # ...and each of those files must also SOURCE the guard, or the call
    # is an rc-127 no-op.
    unsourced=''
    nofallback=''
    while IFS= read -r site; do
        [[ -n "$site" ]] || continue
        f="${site%%:*}"
        # A MENTION is not a source. `# shellcheck source=../_pane-live.sh`
        # is a comment; requiring a command-position `source`/`.` is what
        # makes deleting the real line red.
        command grep -qE '(^|&&)[[:space:]]*(source|\.)[[:space:]]+[^#]*_pane-live\.sh' "$f" \
            || unsourced+="${unsourced:+$'\n'}$f"
        # ...and the FAIL-CLOSED FALLBACK. The source is conditional (a
        # partial fixture tree legitimately lacks the file), so without a
        # fallback the guard call would be rc 127 — which reads as "not
        # dead" and silently restores the hazard in exactly the trees
        # least likely to be looked at.
        #
        # EXERCISED, NOT GREPPED. `grep -q 'declare -F …'` was the FOURTH
        # instance of the mention-vs-substance class in this file, found
        # by auditing for it rather than by a failure: it passes on a
        # fallback that has been gutted or inverted, and only ONE of the
        # four files had its fallback behaviourally covered. Extract each
        # file's block, run it with the real predicate absent, and demand
        # that it REFUSE.
        fb_block=$(sed -n '/^if ! declare -F _tmux_pane_is_dead/,/^fi$/p' "$f")
        if [[ -z "$fb_block" ]]; then
            nofallback+="${nofallback:+$'\n'}$f (no fallback block)"
        else
            fb_verdict=$(bash -c '
                '"$fb_block"'
                declare -F _tmux_pane_is_dead >/dev/null 2>&1 || { echo NOT-DEFINED; exit 0; }
                _tmux_pane_is_dead somewindow 2>/dev/null && echo REFUSES || echo ALLOWS' 2>/dev/null)
            [[ "$fb_verdict" == "REFUSES" ]] \
                || nofallback+="${nofallback:+$'\n'}$f (fallback verdict: ${fb_verdict:-<none>}, want REFUSES)"
        fi
    done <<<"$paste_sites"
    if [[ -z "$unsourced" ]]; then
        pass "B: every such file sources _pane-live.sh explicitly"
    else
        fail "B: file(s) call the guard without sourcing it (rc 127 reads as 'not dead'):"$'\n'"$unsourced"
    fi
    if [[ -z "$nofallback" ]]; then
        pass "B: every such file's fallback REFUSES when the real predicate is absent (exercised, not grepped)"
    else
        fail "B: file(s) whose fail-closed fallback does not refuse — a missing _pane-live.sh then reads as 'not dead':"$'\n'"$nofallback"
    fi

    # THE FALLBACK ITSELF, exercised rather than asserted. Load a copy of
    # the guard's consumer from a tree where _pane-live.sh does NOT exist
    # and confirm two things at once: the module still LOADS (a partial
    # fixture tree must not be bricked by a missing paste guard — CI
    # proved that the hard way), and the predicate refuses.
    fbtree="$WORK/nofile/monitor/watcher"
    mkdir -p "$fbtree"
    cp "$MON/watcher/_unstick.sh" "$fbtree/_unstick.sh"
    cp "$MON/_log-mode.sh" "$WORK/nofile/monitor/_log-mode.sh"
    fb=$(PATH="$STUB_EMPTY:$PATH" bash -c '
        . "'"$fbtree"'/_unstick.sh" >/dev/null 2>&1 || { echo "LOAD-FAILED"; exit 0; }
        declare -F _tmux_pane_is_dead >/dev/null 2>&1 || { echo "NO-FALLBACK"; exit 0; }
        _tmux_pane_is_dead somewindow 2>/dev/null && echo "REFUSES" || echo "ALLOWS"' 2>/dev/null)
    assert_eq "B: with _pane-live.sh ABSENT the module still loads and the guard REFUSES" "$fb" "REFUSES"
fi

# =====================================================================
echo '=== C: end-to-end — the helpers survive a real corpse ==='
# =====================================================================
# Positive control FIRST, in its own throwaway server: prove this
# fixture still reproduces the crash. Without it, "the server survived"
# below could mean the tmux stopped crashing, not that the guard works.
# WHETHER THIS TMUX HAS THE BUG IS ITSELF A MEASUREMENT, not an
# assumption. It is confirmed 20/20 on the tmux this workspace deploys
# (2.6); a newer tmux may well have fixed it. If it has, that is
# INFORMATION — it must not red the build, and it must not be allowed
# to make the survival assertions below look like evidence when they
# would pass on any tmux at all. So: record it, and gate only the
# claims that actually depend on it. The rc assertions (did the guard
# REFUSE?) are version-independent and always run.
# THE ANCHOR RETRIES (your-org/nexus-code#1027). ONE un-reproduced trial is
# not evidence that this tmux is fixed — it is one trial that did not land.
#
# Measured: on this host the hazard is load-sensitive. At load ~24 an
# instrumented replication killed the server 10/10; at load ~45-65 an
# independent 6-trial run recorded 4 kills, 1 survival, 1 no-corpse. So the
# single-trial control was roughly 1-in-5 to DISARM ITSELF per run — and when
# it disarmed it recorded `pass "this tmux does NOT crash"`, which is a claim
# about TMUX inferred from one miss. That is silence used as proof of absence,
# sitting in the falsifiability anchor itself, and it is contradicted by this
# file's own header (20/20 on this same tmux 2.6).
#
# Arm on ANY kill; conclude "does not crash" only if ALL N trials survive.
# With the measured per-trial kill rate that is ~0.008 for a still-buggy tmux,
# against ~0.2 for the single-trial form.
#
# WHY THIS AND NOT A `P+F+S` ASSERTION CENSUS. Because a SKIP still counts: the
# measured totals were 58 whether the survival assertions RAN or SKIPPED
# (re-derived on this tree — 57P/1F/0S armed vs 53P/1F/4S disarmed, both 58).
# A P+F+S census therefore catches only runs that were already red and misses
# the green one entirely. The census that DOES discriminate is below, and it
# counts the survival assertions specifically.
HAZARD_TRIALS="${HAZARD_TRIALS:-3}"
HAZARD_REPRODUCES=0
_hz_killed=0 _hz_survived=0 _hz_nocorpse=0 _hz_trial=0
while (( _hz_trial < HAZARD_TRIALS )); do
    _hz_trial=$(( _hz_trial + 1 ))
    new_server "c1t$_hz_trial"; SC1="$SOCK"
    if ! make_corpse "$SC1" victim; then
        _hz_nocorpse=$(( _hz_nocorpse + 1 )); continue
    fi
    tx "$SC1" load-buffer -b b1 "$PAYLOAD" 2>/dev/null
    tx "$SC1" paste-buffer -b b1 -t victim >/dev/null 2>&1
    if server_alive "$SC1"; then
        _hz_survived=$(( _hz_survived + 1 ))
    else
        _hz_killed=$(( _hz_killed + 1 )); HAZARD_REPRODUCES=1; break
    fi
done

if (( HAZARD_REPRODUCES == 1 )); then
    pass "C: positive control — an UNGUARDED paste into the corpse killed the server (fixture reproduces #745; armed on trial $_hz_trial of $HAZARD_TRIALS)"
elif (( _hz_killed == 0 && _hz_survived > 0 )); then
    # A GENUINELY FIXED TMUX MUST NOT RED THE BUILD — that requirement is
    # correct and is preserved. What is removed is the inference from a single
    # miss: this is now $_hz_survived independent survivals, not one.
    #
    # It must not present as an ordinary pass either. The four survival
    # assertions below are the entire end-to-end evidence that the guard
    # prevents the server death #745 is about, and they are about to not run.
    # So it is recorded as a SKIPPED anchor, counted in the summary footer, and
    # named in a banner — run-tests.sh scrapes that footer and annotates the
    # run "NOT covered".
    pass "C: ANCHOR DID NOT ARM — $_hz_survived/$HAZARD_TRIALS unguarded pastes into a corpse left the server ALIVE on $(tmux -V). Either this tmux fixed #745, or the hazard did not land; EITHER WAY the four server-survival assertions below do NOT run"
else
    # Every trial failed to build a corpse: evidence about the MACHINE.
    env_fail "C: positive-control corpse never formed in $HAZARD_TRIALS trial(s) — the fixture could not build its subject, so nothing here is evidence about the guard"
fi

# --- THE SURVIVAL-ASSERTION CENSUS (your-org/nexus-code#1027) ----------------
#
# The suite DECLARES how many server-survival assertions it contains and then
# checks itself against that number, so neither a deletion nor a silent skip
# can pass unremarked. Three counters rather than one, because the three causes
# are not the same fact and must not share a verdict:
#
#   _sv_ran      the assertion actually executed (real evidence)
#   _sv_skipped  the anchor did not arm  -> reported, not red (see above)
#   _sv_envskip  the fixture could not build a corpse for that leg -> ENV, not
#                a product defect (#1025). Without this third counter the
#                census would report a product FAIL for a loaded node, which
#                is the exact defect #1025 is about, reintroduced inside
#                #1027's fix.
EXPECTED_SURVIVAL_ASSERTIONS=4
_sv_ran=0 _sv_skipped=0 _sv_envskip=0

# assert_survived <sock> <label> — only meaningful where the positive
# control established that an unguarded paste WOULD have killed it.
assert_survived() {
    local sock="$1" label="$2"
    if (( HAZARD_REPRODUCES == 0 )); then
        _sv_skipped=$(( _sv_skipped + 1 ))
        printf '  SKIP: %s (anchor did not arm; assertion would be vacuous)\n' "$label"
        return 0
    fi
    _sv_ran=$(( _sv_ran + 1 ))
    if server_alive "$sock"; then pass "$label"; else fail "$label"; fi
}

# survival_env_skip <label> — this leg's corpse never formed, so its survival
# assertion cannot run and that is the MACHINE's doing.
survival_env_skip() {
    _sv_envskip=$(( _sv_envskip + 1 ))
    env_fail "$1"
}

# _paste_line_to_window (_unstick.sh) against a corpse
new_server c2; SC2="$SOCK"
route_tmux_to "$SC2"
if make_corpse "$SC2" victim; then
    ( . "$MON/watcher/_unstick.sh" >/dev/null 2>&1
      _paste_line_to_window victim "please continue" ) >/dev/null 2>&1
    rc=$?
    assert_survived "$SC2" "C: _paste_line_to_window refused — server SURVIVED"
    assert_eq "C: _paste_line_to_window returns its paste-failed rc" "$rc" "1"
else
    survival_env_skip "C: corpse never formed for the _unstick leg — the fixture could not build its subject on this machine (not evidence about the guard)"
fi

# _respawn_paste_prompt_file (_respawn.sh) against a corpse
new_server c3; SC3="$SOCK"
route_tmux_to "$SC3"
if make_corpse "$SC3" victim; then
    ( . "$MON/watcher/_respawn.sh" >/dev/null 2>&1
      _respawn_paste_prompt_file victim "$PAYLOAD" ) >/dev/null 2>&1
    rc=$?
    assert_survived "$SC3" "C: _respawn_paste_prompt_file refused — server SURVIVED"
    assert_eq "C: _respawn_paste_prompt_file returns 1" "$rc" "1"
else
    survival_env_skip "C: corpse never formed for the _respawn leg — the fixture could not build its subject on this machine (not evidence about the guard)"
fi

# paste-followup.sh (the -p -d form, 20/20 — the most lethal site) against
# a real corpse. Run the REAL CLI, not an extraction: this leg had NO
# behavioural coverage at all, and deleting its guard left the suite green.
new_server c5; SC5="$SOCK"
route_tmux_to "$SC5"
if make_corpse "$SC5" victim; then
    pf_state=$(mktemp -d "$WORK/pfstate.XXXXXX")
    pf_out=$(env "NEXUS_STATE_DIR=$pf_state" "NEXUS_CC_HOME=$WORK/cc" \
                 "PASTE_CONFIRM_TIMEOUT_SECONDS=2" "PASTE_CONFIRM_POLL_SECONDS=0.05" \
                 bash "$MON/paste-followup.sh" victim --message 'poke the corpse' 2>&1)
    pf_rc=$?
    assert_survived "$SC5" "C: paste-followup.sh refused — server SURVIVED"
    if (( pf_rc != 0 )); then
        pass "C: paste-followup.sh refused with a non-zero rc (got $pf_rc)"
    else
        fail "C: paste-followup.sh returned 0 on a DEAD pane — it pasted, or claimed success"
    fi
    if _names_refusal "$pf_out"; then
        pass "C: paste-followup.sh NAMES the reason (a phrase the fixture cannot supply)"
    else
        fail "C: paste-followup.sh refused without naming the dead pane: ${pf_out:0:160}"
    fi
else
    survival_env_skip "C: corpse never formed for the paste-followup leg — the fixture could not build its subject on this machine (not evidence about the guard)"
fi

# main.sh's _paste_to_target_unlocked against a real corpse. main.sh runs
# its whole loop at source time, so extract the function body — the same
# device test-target-config.sh:244 uses — and drive the REAL code with the
# few globals this path touches stubbed.
new_server c6; SC6="$SOCK"
route_tmux_to "$SC6"
if make_corpse "$SC6" orchestrator; then
    m_body=$(sed -n '/^_paste_to_target_unlocked() {/,/^}/p' "$MON/watcher/main.sh")
    if [[ -z "$m_body" ]]; then
        fail "C: could not extract _paste_to_target_unlocked() from main.sh"
    else
        m_rc=$(
            PATH="$WORK/bin:$PATH" bash -c '
                . "'"$MON"'/_pane-live.sh"
                log() { :; }
                '"$m_body"'
                _paste_to_target_unlocked orchestrator "'"$PAYLOAD"'" >/dev/null 2>&1
                echo $?' 2>/dev/null
        )
        assert_survived "$SC6" "C: main.sh _paste_to_target_unlocked refused — server SURVIVED"
        assert_eq "C: main.sh _paste_to_target_unlocked returns the non-retryable rc 5" "$m_rc" "5"

        # THE COUNTER-RISK (#1017). Making "cannot tell" refuse is only
        # safe if an uncertain refusal stays RETRYABLE. rc 5 is
        # deliberately never retried by paste_with_retry — correct for a
        # corpse, catastrophic for a transient fork failure, which would
        # otherwise drop the emit permanently AND misreport a healthy
        # orchestrator as a corpse to the respawn path. So the two
        # refusals must not share an arm.
        #
        # The window EXISTS here (the name check at the top of the
        # function must pass) but `list-panes` fails, which is exactly
        # the shape of a fork failure under the worker RLIMIT_NPROC
        # ceiling.
        u_stub="$WORK/ustub"; mkdir -p "$u_stub"
        cat > "$u_stub/tmux" <<USTUB
#!/usr/bin/env bash
case "\$1" in
    list-windows) echo orchestrator; exit 0 ;;
    list-panes)   exit 1 ;;
    *)            exit 0 ;;
esac
USTUB
        chmod +x "$u_stub/tmux"
        u_rc=$(
            PATH="$u_stub:$PATH" bash -c '
                . "'"$MON"'/_pane-live.sh"
                log() { :; }
                '"$m_body"'
                _paste_to_target_unlocked orchestrator "'"$PAYLOAD"'" >/dev/null 2>&1
                echo $?' 2>/dev/null
        )
        assert_eq "C: main.sh maps an UNKNOWN verdict to the RETRYABLE rc 3, not the terminal 5" "$u_rc" "3"
        _c_unknown_asserted=1   # E4 below reads this (#1365)
    fi
else
    survival_env_skip "C: corpse never formed for the main.sh leg — the fixture could not build its subject on this machine (not evidence about the guard)"
    _c_unknown_envskipped=1   # E4 below reads this (#1365)
fi

# ...and the guarded helpers must still DELIVER into a live pane.
# A guard that refuses everything would pass every assertion above.
new_server c4; SC4="$SOCK"
route_tmux_to "$SC4"
tx "$SC4" new-window -d -n alive 'sleep 120' 2>/dev/null
sleep 0.3
( . "$MON/watcher/_unstick.sh" >/dev/null 2>&1
  _paste_line_to_window alive "still delivering" ) >/dev/null 2>&1
rc=$?
assert_eq "C: NON-VACUITY — live pane still receives the paste (rc=0)" "$rc" "0"
server_alive "$SC4" && pass "C: live-pane server unharmed" || fail "C: live-pane server died"

# =====================================================================
echo '=== D: the parsing contract, against a STUB tmux ==='
# =====================================================================
# Real tmux only ever emits `0` or `1` for `#{pane_dead}`, so the choice
# between an ALLOWLIST (`== "1"` is dead) and a DENYLIST (`!= "0"` is
# dead) is invisible to parts A-C — measured: that mutant SURVIVED the
# real-tmux suite 20/20. It is not a cosmetic choice. On a tmux that
# does not know the format the field expands EMPTY (measured: an
# unknown `#{...}` expands to the empty string at rc 0), and the two
# readings diverge completely. The original weighing was:
#
#   allowlist  empty -> not dead -> paste proceeds
#   denylist   empty -> dead     -> EVERY paste refused, forever: the
#                                   watcher goes silent, no worker is
#                                   ever woken, and nothing is red
#
# #1017 takes the SECOND branch, because its cost was mis-stated. The
# fear is not "refused" — it is "forever" and "nothing is red", and
# both are now false by construction: the refusal prints one line
# naming the field it could not read, and it reports verdict `unknown`,
# which `_paste_to_target_unlocked` maps to the RETRYABLE rc 3 rather
# than the terminal rc 5. What remains is a LOUD outage instead of a
# silent tmux-server death, and only one of those is recoverable.
#
# A stub is the right instrument here precisely because these rows are
# ones real tmux cannot produce. The semantics stay in parts A-C.
STUB="$WORK/stub"; mkdir -p "$STUB"
stub_rows() {
    cat > "$STUB/tmux" <<STUBEOF
#!/usr/bin/env bash
[[ "\$1" == "list-panes" ]] || exit 0
exit_rc=${2:-0}
(( exit_rc == 0 )) || exit "\$exit_rc"
cat <<'ROWS'
$1
ROWS
STUBEOF
    chmod +x "$STUB/tmux"
}
with_stub() { PATH="$STUB:$PATH" bash -c '. "'"$MON"'/_pane-live.sh"; _tmux_pane_is_dead "$1" 2>/dev/null; echo $?' _ "$1"; }
# The VERDICT is a separate contract from the rc: rc says "refuse",
# the verdict says whether the refusal is terminal or retryable, and
# `_paste_to_target_unlocked` branches on it. An rc-only assertion
# cannot tell `dead` from `unknown`.
with_stub_verdict() { PATH="$STUB:$PATH" bash -c '. "'"$MON"'/_pane-live.sh"; _tmux_pane_is_dead "$1" 2>/dev/null; echo "${NEXUS_PANE_LIVE_VERDICT:-unset}"' _ "$1"; }
# stderr is the only thing an operator sees when the board stalls, so
# assert it is actually emitted rather than trusting the rc.
with_stub_stderr() { PATH="$STUB:$PATH" bash -c '. "'"$MON"'/_pane-live.sh"; _tmux_pane_is_dead "$1" 2>&1 >/dev/null' _ "$1"; }

# --- the branch that had NO test at all: a FAILED query (#1017) -------
# `stub_rows` has always accepted an exit rc; nothing ever passed one,
# so the single most dangerous branch — tmux present, query failed,
# zero information — was never exercised in either direction.
stub_rows 'orchestrator|@1|%1|1|0' 1
assert_eq "D: list-panes FAILS (rc 1) -> rc=0 (REFUSE: no information)" "$(with_stub orchestrator)" "0"
assert_eq "D: list-panes FAILS -> verdict 'unknown' (RETRYABLE, not a corpse)" "$(with_stub_verdict orchestrator)" "unknown"
case "$(with_stub_stderr orchestrator)" in
    *"list-panes failed"*"REFUSING"*) pass "D: a failed query ANNOUNCES itself on stderr" ;;
    *) fail "D: a failed query refused SILENTLY — a stalled board nobody can see" ;;
esac
stub_rows 'orchestrator|@1|%1|1|0' 127
assert_eq "D: list-panes rc 127 (no fork slot) -> rc=0 (REFUSE)" "$(with_stub orchestrator)" "0"

# --- unreadable fields: the allowlist->denylist reversal --------------
stub_rows 'orchestrator|@1|%1|1|'
assert_eq "D: pane_dead EMPTY (tmux too old) -> rc=0 (REFUSE)" "$(with_stub orchestrator)" "0"
assert_eq "D: pane_dead EMPTY -> verdict 'unknown'" "$(with_stub_verdict orchestrator)" "unknown"
stub_rows 'orchestrator|@1|%1|1|yes'
assert_eq "D: pane_dead garbage 'yes' -> rc=0 (REFUSE)" "$(with_stub orchestrator)" "0"
stub_rows 'orchestrator|@1|%1|1|11'
assert_eq "D: pane_dead '11' is not '1' -> rc=0 (REFUSE)" "$(with_stub orchestrator)" "0"
stub_rows 'orchestrator|@1|%1||1'
assert_eq "D: pane_ACTIVE unreadable -> rc=0 (cannot tell which pane receives)" "$(with_stub orchestrator)" "0"
stub_rows 'orchestrator|@1|%1|1|0'
assert_eq "D: pane_dead 0 -> rc=1 (live)" "$(with_stub orchestrator)" "1"
assert_eq "D: pane_dead 0 -> verdict 'live'" "$(with_stub_verdict orchestrator)" "live"
stub_rows 'orchestrator|@1|%1|1|1'
assert_eq "D: pane_dead 1 -> rc=0 (dead, REFUSE)" "$(with_stub orchestrator)" "0"
assert_eq "D: pane_dead 1 -> verdict 'dead' (TERMINAL: respawn, never retry)" "$(with_stub_verdict orchestrator)" "dead"
stub_rows 'orchestrator'
assert_eq "D: malformed row, no delimiters -> rc=0 (REFUSE)" "$(with_stub orchestrator)" "0"
# --- #1021 INVARIANT: RESOLVABLE BUT UNLISTED MUST STILL REFUSE ------
# your-org/nexus-code#1021 records an unimplemented idea: the prefix rescue
# holds $_pl_resolved and could look it up in $rows to publish `dead` instead
# of `unknown`. It was filed RECORD-ONLY and explicitly NOT recommended,
# because the obvious implementation FAILS OPEN — a pane created between the
# `list-panes` and the `display-message` is legitimately absent from $rows, and
# a naive `else -> live; return 1` there pastes blind, reintroducing #1017
# inside the branch that closes it.
#
# This suite is NOT implementing that change. This case exists so that anyone
# who later does cannot do it the fail-open way without going red first: the
# resolved pane is deliberately ABSENT from the table, and the only acceptable
# answer is still REFUSE. #1021's own acceptance criterion, written down as an
# assertion rather than as prose in a closed issue.
cat > "$STUB/tmux" <<'RESOLVESTUB'
#!/usr/bin/env bash
case "$1" in
    list-panes)      printf '%s\n' 'other|@2|%2|1|0' ;;   # target NOT listed
    display-message) printf '%s\n' '%9' ;;                # ...yet tmux resolves it
    *)               exit 0 ;;
esac
RESOLVESTUB
chmod +x "$STUB/tmux"
assert_eq "D/#1021: target ABSENT from list-panes but RESOLVED by tmux -> rc=0 (REFUSE, never 'live')" \
    "$(with_stub orchestrator)" "0"
assert_eq "D/#1021: ...and the verdict is 'unknown' (an upgrade to 'dead' would be allowed; 'live' never is)" \
    "$(with_stub_verdict orchestrator)" "unknown"

# a dead pane in a DIFFERENT window must not condemn the target
stub_rows 'other|@2|%2|1|1
orchestrator|@1|%1|1|0'
assert_eq "D: another window's corpse -> rc=1" "$(with_stub orchestrator)" "1"
# the documented ambiguity rule: duplicate names, one active pane dead
stub_rows 'orchestrator|@1|%1|1|0
orchestrator|@2|%2|1|1'
assert_eq "D: duplicate name, one active pane DEAD -> rc=0 (errs to refuse)" "$(with_stub orchestrator)" "0"
# an INACTIVE dead pane in the target window is not what a paste hits
stub_rows 'orchestrator|@1|%1|1|0
orchestrator|@1|%3|0|1'
assert_eq "D: inactive dead pane in the target window -> rc=1" "$(with_stub orchestrator)" "1"

# =====================================================================
echo '=== E: the UNKNOWN path at EVERY caller (your-org/nexus-code#1017 F1) ==='
# =====================================================================
# Part C drives the three non-main callers against a real CORPSE only —
# verdict `dead`. That leaves the branch this change exists to fix
# asserted end-to-end through main.sh ALONE. Measured by the skeptic:
# gating each caller's refusal on `verdict == "dead"` — the single most
# plausible future edit, and the obvious implementation of the pending
# message-text fix — re-opens the fail-open at `_unstick.sh`,
# `_respawn.sh` and `paste-followup.sh` while this suite stays 50/0.
# A green whose scope is narrower than the claim it is cited for is
# this repo's dominant defect class; these cases close the quantifier.
#
# THE FIXTURE IS A **LIVE** WINDOW WITH A FAILING `list-panes`, not a
# corpse. Three reasons that is the right instrument:
#
#   * it is the real shape of the hazard — a fork failure under the
#     worker RLIMIT_NPROC ceiling fails the query while the server, and
#     everything else tmux does, keep working;
#   * it makes the assertion POTENT rather than vacuous. The pane is
#     healthy, so if the guard does not fire the paste genuinely
#     SUCCEEDS. A refusal here can only have come from the guard;
#   * it needs no corpse, so this part cannot kill a server even by
#     accident.
#
# `list-panes` is the ONLY verb suppressed, and it is surgical: the
# guard is its only consumer on these paths — `resolve_window_id` reads
# `list-windows` (via `_tmux_window_rows`), which still works.
#
# THE RC IS NOT THE LOAD-BEARING ASSERTION, and for `paste-followup.sh`
# it cannot be: that script exits non-zero when it pastes and then fails
# to confirm submission, which is exactly what happens on a stubbed
# server. So rc 1 there would be true under BOTH the fixed and the
# mutated code — a test that passes either way proves nothing. What
# discriminates is whether `paste-buffer` was ever ATTEMPTED, so every
# case below asserts the RECORDER, and rc only where it discriminates.
new_server e1; SE1="$SOCK"
tx "$SE1" new-window -d -n victim 'sleep 120' 2>/dev/null
sleep 0.3
UDIR="$WORK/ubin"; mkdir -p "$UDIR"
PASTE_LOG="$WORK/paste-attempts.log"
: > "$PASTE_LOG"
cat > "$UDIR/tmux" <<UWRAP
#!/usr/bin/env bash
# list-panes FAILS -> the guard has no information -> verdict 'unknown'.
[[ "\$1" == "list-panes" ]] && exit 1
# every real paste attempt is recorded BEFORE it is forwarded, so a
# guard that failed to fire is caught even if the paste itself errors.
[[ "\$1" == "paste-buffer" ]] && printf '%s\n' "\$*" >> "$PASTE_LOG"
exec env -u TMUX $TMUX_BIN -L "$SE1" "\$@"
UWRAP
chmod +x "$UDIR/tmux"

# THE ALARM, AGAIN — AND HERE IT GUARDS A VACUITY, NOT JUST A WRONG SERVER
# (your-org/nexus-code#1115 skeptic F3). Part A's alarm covers $WORK/bin only.
# The three E cases below assert "attempted NO paste-buffer" by counting lines
# in $PASTE_LOG — a log written by THIS shim. If this shim were displaced, the
# paste would go somewhere else, would not be recorded, and the count would be
# 0: the assertions would PASS while proving nothing. A potent assertion whose
# soundness rests on a property nothing asserts is exactly what this file's own
# doctrine forbids, so the property is asserted.
_e_want_sock="${TMUX_TMPDIR}/tmux-$(id -u)/${SE1}"
if nx_assert_tmux_pinned "$UDIR" "$_e_want_sock"; then
    pass "E: ISOLATION CONTROL — the \$UDIR shim is reached, so the paste-attempt log below is a real recorder (#1105)"
else
    fail "E: ISOLATION CONTROL — the \$UDIR shim is DISPLACED; the 'attempted NO paste-buffer' assertions below would pass vacuously (#1105)"
fi

# Sanity: the fixture window really is LIVE, so a paste that is not
# refused would land. Without this the three cases below could pass
# because the target was broken rather than because the guard fired.
_e_dead=$(tx "$SE1" list-panes -a -F '#{window_name}|#{pane_dead}' 2>/dev/null \
            | awk -F'|' '$1 == "victim" && !seen { print $2; seen = 1 }')
assert_eq "E: FIXTURE CONTROL — the target window is LIVE (a refusal cannot be blamed on a corpse)" "$_e_dead" "0"

# --- E1: _unstick.sh::_paste_line_to_window -------------------------
: > "$PASTE_LOG"
e1_err=$( ( PATH="$UDIR:$PATH"; . "$MON/watcher/_unstick.sh" >/dev/null 2>&1
  _paste_line_to_window victim "please continue" ) 2>&1 >/dev/null )
rc=$?
assert_eq "E1: _unstick _paste_line_to_window REFUSES on verdict=unknown (rc 1)" "$rc" "1"
assert_eq "E1: _unstick attempted NO paste-buffer" "$(wc -l < "$PASTE_LOG" | tr -d ' ')" "0"
# #1020 — the refusal must not assert a corpse it did not observe.
case "$e1_err" in
    *"is a DEAD pane"*) fail "E1/#1020: _unstick called an UNKNOWN verdict a DEAD pane: ${e1_err:0:160}" ;;
    *"could NOT establish"*) pass "E1/#1020: _unstick says it could not establish liveness, not that the pane is dead" ;;
    *) fail "E1/#1020: _unstick's unknown-path refusal says neither: ${e1_err:0:160}" ;;
esac

# --- E2: _respawn.sh::_respawn_paste_prompt_file ---------------------
: > "$PASTE_LOG"
e2_err=$( ( PATH="$UDIR:$PATH"; . "$MON/watcher/_respawn.sh" >/dev/null 2>&1
  _respawn_paste_prompt_file victim "$PAYLOAD" ) 2>&1 >/dev/null )
rc=$?
assert_eq "E2: _respawn _respawn_paste_prompt_file REFUSES on verdict=unknown (rc 1)" "$rc" "1"
assert_eq "E2: _respawn attempted NO paste-buffer" "$(wc -l < "$PASTE_LOG" | tr -d ' ')" "0"
case "$e2_err" in
    *"is a DEAD pane"*) fail "E2/#1020: _respawn called an UNKNOWN verdict a DEAD pane: ${e2_err:0:160}" ;;
    *"could NOT establish"*) pass "E2/#1020: _respawn says it could not establish liveness, not that the target is dead" ;;
    *) fail "E2/#1020: _respawn's unknown-path refusal says neither: ${e2_err:0:160}" ;;
esac

# --- E3: paste-followup.sh -------------------------------------------
# rc is deliberately NOT asserted here; see the header above.
: > "$PASTE_LOG"
e3_state=$(mktemp -d "$WORK/e3state.XXXXXX")
e3_out=$(PATH="$UDIR:$PATH" env "NEXUS_STATE_DIR=$e3_state" "NEXUS_CC_HOME=$WORK/cc" \
             "PASTE_CONFIRM_TIMEOUT_SECONDS=2" "PASTE_CONFIRM_POLL_SECONDS=0.05" \
             bash "$MON/paste-followup.sh" victim --message 'poke an unknown' 2>&1)
assert_eq "E3: paste-followup attempted NO paste-buffer on verdict=unknown" "$(wc -l < "$PASTE_LOG" | tr -d ' ')" "0"
# The old predicate here also carried a `*"cannot determine"*` alternative.
# `paste-followup.sh` never says that -- it says "could NOT determine" -- so
# that arm only ever fired via the sourced `_pane-live.sh:196`, and the two
# resolver-path refusals (:397, :436) matched NOTHING but the bare `*745*`.
# The old glob was therefore fail-OPEN on the collision and fail-CLOSED on two
# of the four reachable refusals at once.
if _names_refusal "$e3_out"; then
    pass "E3: paste-followup NAMES its refusal rather than failing silently"
else
    fail "E3: paste-followup neither pasted nor explained itself: ${e3_out:0:200}"
fi
# #1020, THE ONE THAT MATTERS: this is the message a human reads. On an
# UNKNOWN verdict it must not assert the corpse, and above all it must not
# direct the operator to RESPAWN — a destructive act against a window that is
# probably healthy, recommended on the strength of a query that failed.
case "$e3_out" in
    *"Respawn the window"*)
        fail "E3/#1020: paste-followup told the operator to RESPAWN on an UNKNOWN verdict — misdirection toward a destructive action: ${e3_out:0:200}" ;;
    *"NOT A FINDING THAT THE WINDOW IS DEAD"*)
        pass "E3/#1020: paste-followup's operator-facing refusal disclaims the corpse diagnosis and does NOT advise a respawn" ;;
    *)
        fail "E3/#1020: paste-followup's unknown-path message neither advises respawn nor disclaims the diagnosis — check its wording: ${e3_out:0:200}" ;;
esac

# --- E4: main.sh, already covered by C, restated here for the table ---
# The one caller that READS the verdict. C asserts rc 3 vs rc 5; this
# keeps all four callers visible in one place so a future reader can see
# the quantifier is four, not one.
# your-org/nexus-code#1365: E4 used to be a bare `pass` — a string asserting that
# part C's assertion exists, read by nothing. Delete that assertion and this
# line kept printing PASS; skip it (corpse never formed) and this line kept
# printing PASS. Now it reads the flag part C sets when the assertion RAN, and
# says so honestly when part C could not run on this machine.
if [[ "${_c_unknown_asserted:-0}" == 1 ]]; then
    pass "E4: main.sh unknown-path coverage lives in part C (retryable rc 3, not terminal rc 5) — and part C's assertion RAN this run"
elif [[ "${_c_unknown_envskipped:-0}" == 1 ]]; then
    env_fail "E4: part C's unknown-path assertion did NOT run (corpse never formed) — coverage is not evidenced this run"
else
    fail "E4: part C's unknown-path assertion neither ran nor env-skipped — the coverage E4 vouches for has gone missing"
fi

# =====================================================================
echo '=== F: the suite audits ITSELF (your-org/nexus-code#1027) ==='
# =====================================================================
# A green run of this suite used to be able to reach ZERO of the four
# server-survival assertions and still exit 0 — those four being the entire
# end-to-end evidence that the guard prevents the server death #745 is about.
# Re-derived on this tree: 57P/1F/0S with the anchor armed, 53P/1F/4S with it
# disarmed. P+F+S is 58 either way, so a total-assertion census cannot see it.
# What discriminates is counting THESE FOUR specifically, against a number the
# suite declares up front.
_sv_accounted=$(( _sv_ran + _sv_skipped + _sv_envskip ))
assert_eq "F: every declared server-survival assertion is accounted for (ran+skipped+env)" \
    "$_sv_accounted" "$EXPECTED_SURVIVAL_ASSERTIONS"
if (( HAZARD_REPRODUCES == 1 && _sv_envskip == 0 )); then
    # The anchor armed and every fixture built its corpse, so there is no
    # excuse for a survival assertion not to have run.
    assert_eq "F: anchor ARMED and no ENV skips -> all $EXPECTED_SURVIVAL_ASSERTIONS survival assertions RAN" \
        "$_sv_ran" "$EXPECTED_SURVIVAL_ASSERTIONS"
elif (( HAZARD_REPRODUCES == 0 )); then
    pass "F: anchor did NOT arm — $_sv_skipped survival assertion(s) skipped and counted in the footer below; this run is NOT evidence that the guard prevents server death"
else
    pass "F: anchor armed, but $_sv_envskip leg(s) could not build a corpse (ENV) — $_sv_ran survival assertion(s) ran"
fi

echo
# SKIPPED IS A FOOTER FIELD, not just body text (#1027). run-tests.sh scrapes
# this one line for both the assertion count and the skip count, and annotates
# the row `(N CASE(S) SKIPPED — NOT covered)` while echoing every `SKIP:` line.
# That is what stops a disarmed anchor from presenting as an ordinary pass.
_skipped_total=$(( _sv_skipped + _sv_envskip ))
if (( _skipped_total > 0 )); then
    echo "=== summary: $PASS passed, $FAIL failed, $_skipped_total skipped (server-survival assertions that did NOT run) ==="
else
    echo "=== summary: $PASS passed, $FAIL failed ==="
fi

if (( FAIL > 0 )); then echo "SOME TESTS FAILED" >&2; exit 1; fi

# ENVIRONMENT FAILURES ARE NOT PRODUCT FAILURES (your-org/nexus-code#1025).
# The fixture could not build its subject on this machine. That is evidence
# about the node, not about the guard, and reporting it as red teaches readers
# to discount reds from a safety-critical suite. 69 = ENVSKIP (#1283): honest
# "ran, asserted, could not conclude" — not red, and not the SKIP that would
# say this suite never ran.
#
# ORDER IS LOAD-BEARING AND IS NOT STYLE. This arm sits BELOW the `FAIL > 0`
# arm above deliberately: a PRODUCT red must never be laundered by an ENV
# decline in the same run. Hoisting this block above it — changing nothing
# else — makes a real #745 guard regression on a loaded node exit 69 and read
# as an environment skip, which is strictly worse than the bug #1025 fixed.
# Measured: that single reordering flips a 3-ENV + 1-real-FAIL run from rc 1
# to rc 69. This is the repo's ARM-ORDER-SHADOWING doctrine (#1121) arriving
# in an exit cascade; see test-paste-dead-pane-guard-arms.sh, which pins it.
if (( ENVF > 0 )); then
    echo "ENV-INCONCLUSIVE: $ENVF fixture/environment failure(s) — this run is NOT a verdict on the guard." >&2
    echo "                  $PASS assertion(s) did pass; re-run on a quieter node, or raise" >&2
    echo "                  \$CORPSE_BUDGET_POLLS if corpses are slow to form here." >&2
    exit 69
fi

if (( HAZARD_REPRODUCES == 0 )); then
    echo "ALL TESTS PASSED — BUT THE FALSIFIABILITY ANCHOR DID NOT ARM."
    echo "  $_sv_skipped server-survival assertion(s) did not run, so this green does NOT"
    echo "  certify that the guard prevents the tmux-server death your-org/nexus-code#745"
    echo "  is about. It certifies only that the guard REFUSED where it should."
    echo "  Re-run (HAZARD_TRIALS=$HAZARD_TRIALS); if it never arms, this tmux ($(tmux -V)) may genuinely be fixed."
    exit 0
fi

echo "ALL TESTS PASSED"
exit 0
