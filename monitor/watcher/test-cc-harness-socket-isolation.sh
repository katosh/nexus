#!/usr/bin/env bash
# Tests that monitor/cc-harness CANNOT reach a tmux server other than its own
# (your-org/nexus-code#1042 A).
#
# THE PROPERTY. Every tmux call the harness makes — including the BARE `tmux`
# calls inside monitor/pane-state.sh, which the harness does not control —
# must land on the harness's private socket. Not "usually". A harness that can
# see the live board can also act on it, and the live board is the watcher,
# every worker and every registered service: bwrap is PID 1 under
# `--die-with-parent`, so losing that server tears down the whole sandbox with
# no in-sandbox recovery and no surviving notification path (`#892`, `#644`).
#
# WHAT WENT WRONG, because the shape is the reason this file exists. Isolation
# used to be a PATH bet: cch_setup wrote a shadow `tmux` into $CCH_DIR/.bin
# that injected `-L $CCH_SOCKET`, and prepended that dir to PATH. The harness
# LOSES that bet on any agent process. pane-state.sh is a `#!/usr/bin/env bash`
# script, so it sources $BASH_ENV (monitor/shellenv/bash_env.sh), which
# force-fronts monitor/tmuxwrap AHEAD of the shadow on every invocation. The
# shadow's contents were never consulted at all.
#
# It nevertheless WORKED, by accident, through a two-hop chain nobody designed:
# tmuxwrap resolved "the first PATH hit that is not me", which was the shadow,
# and exec'd it — so `-L` arrived on the second hop. `#1033` then taught
# tmuxwrap to reject any candidate carrying the string `monitor/tmuxwrap/tmux`
# in its first 40 lines. The shadow's own body is
# `exec .../monitor/tmuxwrap/tmux -L <sock> "$@"` — because `_cch_real_tmux`
# resolved `tmux` to the shim — so tmuxwrap began rejecting the harness's OWN
# injector, resolved past it to a real tmux with no `-L`, and every
# pane-state.sh call the harness made landed on the PRODUCTION socket.
#
# So the fix is not a better PATH bet. Isolation is now by DIRECTORY —
# TMUX_TMPDIR, which no PATH shim can redirect — plus `env -u TMUX`, because
# $TMUX overrides TMUX_TMPDIR and the harness always runs inside a production
# pane. The tests below assert the property, not the implementation: they ask
# whether a decoy server is reachable, which is the question that matters
# regardless of how the next shim rearranges PATH.
#
# HERMETIC. Two throwaway tmux servers of this test's own making, both under
# private TMUX_TMPDIRs; one plays "production". The live server is never
# addressed, never enumerated and never killed. No claude binary, no node, no
# mock backend, no network: the real `cch_tmux` / `cch_pane_state` functions
# are driven by setting the CCH_* globals directly.
#
# Run: bash monitor/watcher/test-cc-harness-socket-isolation.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

# shellcheck source=/dev/null
. "$REPO_ROOT/monitor/watcher/_test_helpers.sh"
# shellcheck source=/dev/null
. "$REPO_ROOT/monitor/cc-harness/_lib.sh"

PASS=${PASS:-0}; FAIL=${FAIL:-0}; SKIP=${SKIP:-0}

# Through the shared LEDGER (`_th_pass`/`_th_fail`), not bare counters: the
# ledger survives a subshell the in-memory counters die in, so a FAIL raised
# inside `$(...)` still reddens the suite. Paired with the exact assertion
# count at the bottom, that is `ledger=yes`+`count=exact` — the tier
# summary-honesty.manifest omits rather than records, which is the point of
# doing it this way instead of adding a line declaring this suite unprotected.
ok()  { printf '  PASS: %s\n' "$1"; _th_pass; }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; _th_fail; }

# A real tmux binary is needed to stand up the two fixture servers. Resolve it
# WITHOUT _cch_real_tmux — that is one of the things under test, and a test
# that builds its fixture with the code it is auditing cannot fail.
FIXTURE_TMUX=""
for _c in /usr/bin/tmux /usr/local/bin/tmux /bin/tmux; do
    [[ -x "$_c" ]] || continue
    IFS= read -r -N 2 _m < "$_c" 2>/dev/null || _m=""
    [[ "$_m" == '#!' ]] && continue
    [[ "$("$_c" -V 2>/dev/null)" == tmux\ * ]] || continue
    FIXTURE_TMUX="$_c"; break
done
[[ -n "$FIXTURE_TMUX" ]] || th_skip "no real tmux binary to build fixtures with"

TROOT=$(mktemp -d -t cchiso-XXXXXX)
PROD_TMPDIR="$TROOT/prod"     # stands in for the live board
HARN_TMPDIR="$TROOT/harness"
# THE SOCKET NAME IS HELD CONSTANT; THE DIRECTORY IS THE ONLY VARIABLE.
# Both servers use the SAME -L name, so `-L "$CCH_SOCKET"` alone cannot tell
# them apart and only TMUX_TMPDIR decides which one a call reaches. That is
# what makes the negative controls discriminating: give the decoy a different
# name and a pre-fix cch_tmux misses `prodsess` by accident, the control
# passes, and the leak it exists to catch goes unreported. Vary the axis the
# mechanism varies on.
CCH_SOCKET="cchiso-sock-$$"
PROD_SOCKET="$CCH_SOCKET"
mkdir -p "$PROD_TMPDIR" "$HARN_TMPDIR"

# your-org/nexus-code#991 — and this suite fell through EVERY layer of it until
# a skeptic measured it. Its socket root comes from `mktemp -d -t`, i.e. from
# `$TMPDIR`, NOT from `$TMUX_TMPDIR` — so `run-tests.sh`'s pre-flight (which
# keys on `TMUX_TMPDIR`) passes while the real path is over the ceiling. It
# drives its servers directly rather than through `cch_setup`, so that check
# never runs either. Measured with a short `TMUX_TMPDIR` (24 B) and a long
# `TMPDIR` (127 B): worst-case run-level path 76/107 PASSES, this suite's real
# path is 169/107 and it exits rc 1 with false FAILs.
#
# Both directories are checked because the socket NAME is deliberately held
# constant here and only the DIRECTORY varies — `$HARN_TMPDIR` is the longer of
# the two, so checking only one would measure the wrong side.
th_require_tmux_socket "$PROD_SOCKET" "$PROD_TMPDIR"
th_require_tmux_socket "$CCH_SOCKET"  "$HARN_TMPDIR"

CONF="$TROOT/tmux.conf"; th_tmux_fixture_conf "$CONF"

_cleanup() {
    env -u TMUX TMUX_TMPDIR="$PROD_TMPDIR" "$FIXTURE_TMUX" -L "$PROD_SOCKET" \
        kill-session -t prodsess >/dev/null 2>&1 || true
    env -u TMUX TMUX_TMPDIR="$PROD_TMPDIR" "$FIXTURE_TMUX" -L "$PROD_SOCKET" \
        kill-session -t "${CCH_SESSION:-nosuch}" >/dev/null 2>&1 || true
    env -u TMUX TMUX_TMPDIR="$HARN_TMPDIR" "$FIXTURE_TMUX" -L "${CCH_SOCKET:-nosuch}" \
        kill-session -t "${CCH_SESSION:-nosuch}" >/dev/null 2>&1 || true
    rm -rf "$TROOT" 2>/dev/null || true
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------
echo "=== _cch_real_tmux selects by capability, not by identity ==="
# ---------------------------------------------------------------------------
# The pre-fix resolver was `type -P tmux`, which on any agent process is
# monitor/tmuxwrap/tmux. Both assertions below fail on that resolver.
sel=$(_cch_real_tmux) || sel=""
if [[ -n "$sel" ]]; then
    ok "resolver returns a candidate"
else
    bad "resolver returns a candidate" "_cch_real_tmux produced nothing"
fi

if [[ -n "${sel:-}" ]]; then
    IFS= read -r -N 2 magic < "$sel" 2>/dev/null || magic=""
    if [[ "$magic" == '#!' ]]; then
        bad "selected tmux is not a shim script" "selected $sel, which is a #! script"
    else
        ok "selected tmux is a real binary, not a #! shim ($sel)"
    fi

    if [[ "$("$sel" -V 2>/dev/null)" == tmux\ * ]]; then
        ok "selected tmux answers -V as tmux"
    else
        bad "selected tmux answers -V as tmux" "got '$("$sel" -V 2>&1)'"
    fi

    case "$sel" in
        */monitor/tmuxwrap/tmux) bad "selected tmux is not the nexus PATH-front shim" "selected the shim itself" ;;
        *)                       ok  "selected tmux is not the nexus PATH-front shim" ;;
    esac
fi

# The structural predicate itself, both arms. Guarded on the function
# EXISTING first: an undefined function returns 127, which lands in the
# `else` arm and reads as a pass for the negative case — a test that reports
# green because the code under test is absent.
if ! declare -F _cch_is_script >/dev/null 2>&1; then
    # TWO failures, matching the two assertions the `else` arm makes, so the
    # exact-count check at the bottom stays satisfiable in both arms.
    bad "_cch_is_script: recognises the nexus tmux shim as a script" "no such function in _lib.sh"
    bad "_cch_is_script: a real tmux binary is not a script"        "no such function in _lib.sh"
else
if _cch_is_script "$REPO_ROOT/monitor/tmuxwrap/tmux"; then
    ok "_cch_is_script: recognises the nexus tmux shim as a script"
else
    bad "_cch_is_script: recognises the nexus tmux shim as a script" "returned false"
fi
if _cch_is_script "$FIXTURE_TMUX"; then
    bad "_cch_is_script: a real tmux binary is not a script" "returned true for $FIXTURE_TMUX"
else
    ok "_cch_is_script: a real tmux binary is not a script"
fi
fi

# ---------------------------------------------------------------------------
echo "=== the harness cannot reach a server that is not its own ==="
# ---------------------------------------------------------------------------
# Hand-wire the CCH_* globals the real functions read, rather than running
# cch_setup (which needs node + a claude binary + the mock backend). The
# functions under test are the shipped ones.
CCH_DIR="$TROOT/cch"
CCH_STATE_DIR="$CCH_DIR/state"
CCH_TMUX_TMPDIR="$HARN_TMPDIR"
# CCH_SOCKET was set above, deliberately equal to the decoy's — see there.
CCH_SESSION="cchiso-$$"
mkdir -p "$CCH_DIR/.bin" "$CCH_STATE_DIR"

# Decoy "production". TWO sessions, for two different assertions:
#
#   prodsess          — a name the harness has no business seeing at all;
#                       `cch_tmux list-sessions` is asked about it directly.
#
#   $CCH_SESSION      — DELIBERATELY the same session name the harness will
#                       use, with a differently-NAMED window. This is what
#                       makes the pane-state control discriminating.
#                       `cch_pane_state` can only ever ask about
#                       "$CCH_SESSION:<idx>", so a decoy-only session name is
#                       unreachable by it and a "cannot see it" result would
#                       prove nothing. Colliding the session name and varying
#                       the WINDOW name instead means the same call resolves on
#                       whichever server it actually reached, and the answer
#                       says which one that was.
env -u TMUX TMUX_TMPDIR="$PROD_TMPDIR" "$FIXTURE_TMUX" -L "$PROD_SOCKET" -f "$CONF" \
    new-session -d -s prodsess -n orchestrator -x 80 -y 24 'sleep 120' \
    >/dev/null 2>&1 \
    || th_skip "could not stand up the decoy production server"
env -u TMUX TMUX_TMPDIR="$PROD_TMPDIR" "$FIXTURE_TMUX" -L "$PROD_SOCKET" -f "$CONF" \
    new-session -d -s "$CCH_SESSION" -n decoy-w0 -x 80 -y 24 'sleep 120' \
    >/dev/null 2>&1 \
    || th_skip "could not stand up the decoy same-name session"
# Reachable as the AMBIENT default, the same way cch_setup aliases its own —
# a leaking call computes <tmpdir>/tmux-$UID/default, so that has to BE the
# decoy for the negative controls to discriminate.
ln -sfn "$PROD_SOCKET" "$PROD_TMPDIR/tmux-$(id -u)/default" 2>/dev/null \
    || th_skip "could not alias the decoy default socket"

# Reproduce the hostile ambient environment the harness actually runs in:
#   * $TMUX pointing at the decoy — the harness runs inside a live pane;
#   * a PATH-front shim ahead of everything, as $BASH_ENV arranges.
SHIMDIR="$TROOT/shim"; mkdir -p "$SHIMDIR"
{
    printf '#!/usr/bin/env bash\n'
    printf '# NEXUS-PATH-FRONT-WRAPPER-MARKER — stands in for monitor/tmuxwrap/tmux.\n'
    printf 'exec %q "$@"\n' "$FIXTURE_TMUX"
} > "$SHIMDIR/tmux"
chmod +x "$SHIMDIR/tmux"
export PATH="$SHIMDIR:$PATH"

# REDIRECT THE AMBIENT DEFAULT AT THE DECOY. Both of these are load-bearing,
# and for two different reasons.
#
# Discrimination: a leaking call is one that fails to OVERRIDE the ambient
# environment, so the decoy has to be exactly where an un-overridden call
# lands. With the ambient pointing somewhere the harness would reach anyway,
# a "cannot see it" result proves nothing — and this test's negative controls
# passed against the pre-fix tree until this block existed.
#
# Safety: it also makes the LIVE server unreachable from this test by
# construction. Without it, running these assertions against a pre-fix
# _lib.sh — which is exactly what a mutation check does — resolves
# `-L default` with no TMUX_TMPDIR to /tmp/tmux-$UID/default and creates a
# session ON THE LIVE BOARD. Measured, not hypothesised: an earlier revision
# of this file did precisely that, leaving a stray `cchiso-<pid>` session on
# the production server. A test for socket isolation must not be the thing
# that breaks it.
export TMUX_TMPDIR="$PROD_TMPDIR"
export TMUX="$PROD_TMPDIR/tmux-$(id -u)/default,1,0"

# Sanity: the decoy IS reachable from this shell — and reachable as the
# AMBIENT default, which is the property that makes the negative controls
# discriminating. A later "cannot see it" is then a statement about the
# harness overriding its environment, not about a server that never booted.
if env -u TMUX TMUX_TMPDIR="$PROD_TMPDIR" "$FIXTURE_TMUX" \
        has-session -t prodsess >/dev/null 2>&1; then
    ok "positive control: the decoy production server is up and addressable"
else
    bad "positive control: the decoy production server is up and addressable" "has-session failed"
fi

# Harness brings up its own server through the REAL cch_tmux.
#
# UNCONDITIONAL: this used to emit an assertion only on FAILURE, which made the
# exact-count check below exact on the green path alone — a red run reported
# "count is 20, expected 19" and could not distinguish "an assertion vanished"
# from "the conditional one fired" (skeptic F3). A count guard that only counts
# correctly when nothing is wrong is not a count guard.
if cch_tmux -f "$CONF" new-session -d -s "$CCH_SESSION" -n w0 -x 80 -y 24 'sleep 120' \
        >/dev/null 2>&1; then
    ok "cch_tmux can create its own session"
else
    bad "cch_tmux can create its own session" "new-session failed"
fi

# Mirror cch_setup's alias step — this test drives the shipped functions
# directly rather than through cch_setup, so it must reproduce the one piece
# of setup that lives there.
ln -sfn "$CCH_SOCKET" "$HARN_TMPDIR/tmux-$(id -u)/default" 2>/dev/null || true

# POSITIVE CONTROL — the harness sees its own window.
# EXACT match, not a substring: the decoy's window is `decoy-w0`, which
# CONTAINS `w0`, so `== *w0*` passes on the leaking tree. It did.
own=$(cch_tmux list-windows -t "$CCH_SESSION" -F '#{window_name}' 2>/dev/null)
if [[ "$own" == "w0" ]]; then
    ok "positive control: cch_tmux sees its own window (w0)"
else
    bad "positive control: cch_tmux sees its own window (w0)" "list-windows gave '$own'"
fi

# NEGATIVE CONTROL — and this is the assertion that fails on the pre-fix tree.
seen=$(cch_tmux list-sessions -F '#{session_name}' 2>/dev/null)
if [[ "$seen" == *prodsess* ]]; then
    bad "negative control: cch_tmux cannot see the decoy production session" \
        "list-sessions returned '$seen'"
else
    ok "negative control: cch_tmux cannot see the decoy production session"
fi

# ---------------------------------------------------------------------------
echo "=== pane-state.sh, invoked as the harness invokes it, is bound too ==="
# ---------------------------------------------------------------------------
# pane-state.sh calls tmux BARE. This is the call the harness does not control
# and the one that actually leaked: pre-fix it resolved through the PATH-front
# shim to the ambient $TMUX, i.e. production.
CCH_PANE_STATE="$REPO_ROOT/monitor/pane-state.sh"

# ONE call, through the SHIPPED cch_pane_state, by INDEX — the form
# cch_boot_worker hands to callers. Window 0 is named `w0` on the harness
# server and `decoy-w0` on the decoy, so the answer names the server it
# reached. Asserting through the shipped function is the point: an earlier
# revision of this file hand-wrote the post-fix environment at the call site,
# which made the control unfailable — it passed against the pre-fix tree.
out=$(cch_pane_state 0 2>/dev/null)
if [[ "$out" == *name=w0* ]]; then
    ok "positive control: cch_pane_state classifies the HARNESS's window 0"
else
    bad "positive control: cch_pane_state classifies the HARNESS's window 0" \
        "got '$out'"
fi
if [[ "$out" == *decoy-w0* ]]; then
    bad "negative control: cch_pane_state did not resolve on the decoy server" \
        "leaked to the decoy: '$out'"
else
    ok "negative control: cch_pane_state did not resolve on the decoy server"
fi

# The socket the harness uses must live inside its own tmpdir. Stated as a
# path fact so a future change that keeps the tests green by widening the
# boundary is visible in the diff.
_sd="$CCH_TMUX_TMPDIR/tmux-$(id -u)"
if [[ -S "$_sd/$CCH_SOCKET" ]]; then
    ok "harness socket lives under CCH_TMUX_TMPDIR"
else
    bad "harness socket lives under CCH_TMUX_TMPDIR" "no socket at $_sd/$CCH_SOCKET"
fi
# The alias is what pane-state's BARE `tmux` follows; without it that call has
# nowhere to land and the classifier goes dark instead of leaking. Asserted so
# the seam is pinned rather than incidental.
if [[ -L "$_sd/default" && -S "$_sd/default" ]]; then
    ok "default socket name is aliased to ours INSIDE the private tmpdir"
else
    bad "default socket name is aliased to ours INSIDE the private tmpdir" \
        "no such link at $_sd/default"
fi
# SOURCE-LEVEL: cch_setup must not name its socket `default`. Asserted
# against the shipped file, not against $CCH_SOCKET — this test sets that
# variable itself, so a check on it would pin the test's own wiring while
# reading as though it pinned _lib.sh. `-L default` at a call site is what
# lint-no-tmux-server-kill rule4 rejects, unexemptably, as indistinguishable
# from the operator's own server; the alias inside the private tmpdir is the
# supported way to reach the default NAME, and both halves are pinned here.
_lib="$REPO_ROOT/monitor/cc-harness/_lib.sh"
if grep -qE '^[[:space:]]*CCH_SOCKET=("|'"'"')?default' "$_lib"; then
    bad "cch_setup does not name its socket 'default'" "found the assignment in _lib.sh"
else
    ok "cch_setup does not name its socket 'default'"
fi
if grep -q 'ln -sfn "$CCH_SOCKET"' "$_lib"; then
    ok "cch_setup aliases the default socket name inside its private tmpdir"
else
    bad "cch_setup aliases the default socket name inside its private tmpdir" \
        "no such link step in _lib.sh"
fi

# ---------------------------------------------------------------------------
echo "=== an unset boundary REFUSES, it does not fall back ==="
# ---------------------------------------------------------------------------
# An empty TMUX_TMPDIR is not "no preference": tmux falls back to
# /tmp/tmux-$UID, the LIVE server's directory. So the one state in which these
# functions do not know where they are pointing is the one in which they must
# refuse. Reachable by calling them before cch_setup, or after a setup that
# failed partway.
# rc CAPTURED before anything else runs — `$?` inside the else arm would
# report the rc of the `((…))` test, not of the call being asserted.
( CCH_TMUX_TMPDIR=""; cch_tmux list-sessions >/dev/null 2>&1 ); _rc=$?
if (( _rc == 78 )); then
    ok "cch_tmux refuses (78) when CCH_TMUX_TMPDIR is unset"
else
    bad "cch_tmux refuses (78) when CCH_TMUX_TMPDIR is unset" "rc was $_rc"
fi
( CCH_TMUX_TMPDIR=""; cch_pane_state 0 >/dev/null 2>&1 ); _rc=$?
if (( _rc == 78 )); then
    ok "cch_pane_state refuses (78) when CCH_TMUX_TMPDIR is unset"
else
    bad "cch_pane_state refuses (78) when CCH_TMUX_TMPDIR is unset" "rc was $_rc"
fi

# ---------------------------------------------------------------------------
echo "=== no scenario re-rolls cch_pane_state's body ==="
# ---------------------------------------------------------------------------
# THE STRUCTURAL HALF. The env pins above are only as good as the number of
# places that carry them, and a scenario needing one variation (a different
# NEXUS_STATE_DIR) copied the body instead of extending the function. The copy
# then missed the pins and queried the PRODUCTION server; because pane-state
# answers an unknown window with SILENCE, the result read as renderer drift
# and cost a gate scenario. So: a LIVE-pane invocation of pane-state.sh from a
# harness scenario must go through cch_pane_state.
#
# `--fixture` invocations are exempt and deliberately so — they read a
# captured file and never open a socket, so they cannot leak.
offenders=""
while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    case "$hit" in
        *--fixture*) continue ;;                       # file-backed, no socket
        */cc-harness/_lib.sh:*) continue ;;            # the definition itself
        */test-cc-harness-socket-isolation.sh:*) continue ;;  # this file
    esac
    offenders+="    $hit"$'\n'
# The INVOCATION form specifically, `"$CCH_PANE_STATE"` — not the assignment
# and not $CCH_PANE_STATE_DIR, both of which merely NAME the variable.
done < <(grep -rn '"\$CCH_PANE_STATE"' \
            "$REPO_ROOT/monitor/cc-harness" \
            "$REPO_ROOT/monitor/watcher/test-integration" 2>/dev/null)

if [[ -z "$offenders" ]]; then
    ok "no harness scenario invokes pane-state.sh directly for a live pane"
else
    bad "no harness scenario invokes pane-state.sh directly for a live pane" \
        $'these must call cch_pane_state instead:\n'"$offenders"
fi

# Positive control: the scan CAN see an offender, so a clean result means
# "looked and found none" rather than "the grep matched nothing".
_probe="$TROOT/probe-scenario.sh"
mkdir -p "$TROOT/probe"; _probe="$TROOT/probe/test-realmodel-probe.sh"
printf '%s\n' 'out=$(PATH="$CCH_DIR/.bin:$PATH" "$CCH_PANE_STATE" "$CCH_SESSION:$IDX")' > "$_probe"
if grep -rqn '"\$CCH_PANE_STATE"' "$TROOT/probe" 2>/dev/null; then
    ok "positive control: the scan detects a planted direct invocation"
else
    bad "positive control: the scan detects a planted direct invocation" \
        "planted offender was not seen — a clean scan above proves nothing"
fi

# ---------------------------------------------------------------------------
# EXACT count, not a floor. A floor catches a collapse; only an exact
# comparison catches ONE assertion quietly vanishing, which is the failure
# this suite would be least able to notice about itself — its whole subject is
# a leak that presents as silence.
EXPECTED_ASSERTIONS=20
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count is %d, expected %d — an assertion was added or lost\n' \
        "$_total" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
