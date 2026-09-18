#!/usr/bin/env bash
# your-org/nexus-code#1333 (reopen, scoped to the shared-definition clause):
# `_orphan_async_resolve` must derive its class from async-run.sh's OWN verdict
# vocabulary rather than restating it. The four-arm case it used to carry
# (running/terminal/died/*) dropped `cancelled` and `cancel-requested` into
# `unresolvable` — so for one token `async-run.sh --status-line` said
# `cancelled|stopped on request …` while the resolver said
# `unresolvable|stopped on request …`: the class contradicted its own detail.
#
# Driven through the REAL `_orphan_async_resolve` and the REAL async-run.sh
# against a planted state dir — no resolver stub — because the stub in
# test-orphan-async-terminate.sh replaces exactly the function under test.
#
# Negative controls (the issue's, mandatory): a job that died with NO marker
# must NOT resolve terminal, and a token with no record at all must stay
# `unresolvable`. A fix that makes every wait look resolved is worse than the
# bug.
#
# Ratchet: every `<word>|` literal that `_verdict` can print must have a
# non-`doubt` disposition (except `unknown`, which IS doubt), so a seventh
# verdict added to async-run.sh without a disposition goes red here rather
# than silently falling to the resolver's default arm.
#
# Run: bash monitor/watcher/test-orphan-async-resolve-vocabulary.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HELPER="$_test_dir/_orphan_async.sh"
ASYNC_RUN="$_test_dir/../async-run.sh"

. "$_test_dir/_test_helpers.sh"
PASS=0; FAIL=0

WORK=$(mktemp -d -t nexus-1333-vocab-XXXXXX)
trap 'rm -rf "$WORK"; [[ -n "${_live:-}" ]] && kill "$_live" 2>/dev/null; true' EXIT
STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
export STATE_DIR
export NEXUS_STATE_DIR="$STATE_DIR"
# NEXUS_ROOT deliberately UNSET: the resolver then finds async-run.sh relative
# to its own file, i.e. the tree under test, never the primary's.
unset NEXUS_ROOT

# shellcheck source=monitor/watcher/_orphan_async.sh
. "$HELPER"

W=w1333
_enc=$(bash -c "source '$_test_dir/../_bookkeeping.sh' 2>/dev/null; wk_encode $W" 2>/dev/null)
[[ -n "$_enc" ]] || _enc="$W"
ROOT="$STATE_DIR/async-run/$_enc"
mkdir -p "$ROOT"

_starttime() { awk '{n=split($0,a,") "); split(a[n],f," "); print f[20]}' "/proc/$1/stat" 2>/dev/null; }

# A REAL live process we own, with its REAL start-time.
sleep 120 &
_live=$!
_live_st=$(_starttime "$_live")
if [[ "$_live_st" =~ ^[0-9]+$ ]]; then
    printf '  PASS: fixture planted a live pid with a readable start-time\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: fixture could not read a start-time for pid %s\n' "$_live" >&2; FAIL=$(( FAIL + 1 ))
fi

plant() {   # <token> <pid> <pidstart> [marker|status|none]
    local t="$1" pid="$2" st="$3" kind="${4:-none}"
    mkdir -p "$ROOT/$t"
    printf '%s\n' "$pid" > "$ROOT/$t/pid"
    printf '%s\n' "$st"  > "$ROOT/$t/pidstart"
    : > "$ROOT/$t/out"; : > "$ROOT/$t/err"
    printf '%s\n' "$(( $(date +%s) - 30 ))" > "$ROOT/$t/started"
    case "$kind" in
        marker) printf 'by=sess-xyz\nat=1788373387\nsignalled=yes\n' > "$ROOT/$t/cancelled" ;;
        status) printf 'rc=0\nended=%s\n' "$(date +%s)" > "$ROOT/$t/status" ;;
    esac
}
plant ar-canc  999999  1         marker    # cancelled: marker, pid GONE
plant ar-creq  "$_live" "$_live_st" marker # cancel-requested: marker, pid ALIVE
plant ar-dead  999999  1         none      # died: nothing recorded, pid gone
plant ar-term  999999  1         status    # terminal: status file
plant ar-run   "$_live" "$_live_st" none   # running

resolve() { _orphan_async_resolve asyncrun "$1" "$W"; }
cls()     { printf '%s' "${1%%|*}"; }

echo '=== the authority, for reference (what --status-line says) ==='
_sl() { NEXUS_ASYNC_RUN_WINDOW="$W" bash "$ASYNC_RUN" --status-line "$1" 2>/dev/null; }
assert_eq "authority: ar-canc is cancelled"        "$(cls "$(_sl ar-canc)")" cancelled
assert_eq "authority: ar-creq is cancel-requested" "$(cls "$(_sl ar-creq)")" cancel-requested
assert_eq "authority: ar-dead is died"             "$(cls "$(_sl ar-dead)")" died
assert_eq "authority: ar-term is terminal"         "$(cls "$(_sl ar-term)")" terminal
assert_eq "authority: ar-run is running"           "$(cls "$(_sl ar-run)")"  running
assert_eq "authority: ar-none is unknown"          "$(cls "$(_sl ar-none)")" unknown

echo '=== #1333: the resolver agrees with the authority instead of restating it ==='
out=$(resolve ar-canc)
assert_eq       "#1333 cancelled (marker, pid gone) -> terminal, NOT unresolvable" "$(cls "$out")" terminal
assert_contains "#1333 cancelled: the detail says stopped on request"            "$out" "stopped on request"
assert_contains "#1333 cancelled: the detail carries who cancelled"              "$out" "session sess-xyz"
out=$(resolve ar-creq)
assert_eq       "#1333 cancel-requested (marker, pid ALIVE) -> running, NOT unresolvable" "$(cls "$out")" running
assert_contains "#1333 cancel-requested: the detail says STILL ALIVE"                    "$out" "STILL ALIVE"

echo '=== NEGATIVE CONTROLS: nothing on disk still reads as nothing on disk ==='
out=$(resolve ar-dead)
assert_eq       "#1333 NEG: died with NO marker -> died (not terminal)"  "$(cls "$out")" died
assert_contains "#1333 NEG: died detail says NO status file was written" "$out" "NO status file"
out=$(resolve ar-none)
assert_eq       "#1333 NEG: no record at all -> unresolvable"  "$(cls "$out")" unresolvable
# Unchanged members, so the fix is a widening and not a relabel.
assert_eq "terminal stays terminal" "$(cls "$(resolve ar-term)")" terminal
assert_eq "running stays running"   "$(cls "$(resolve ar-run)")"  running
# The disposition is read from the SAME call as the verdict, so an authority
# that cannot be reached is unresolvable — never terminal, never running.
out=$(NEXUS_STATE_DIR="$WORK/nowhere" resolve ar-canc)
assert_eq "unreachable state dir -> unresolvable (fail closed)" "$(cls "$out")" unresolvable

echo '=== the shared definition: --verdict-disposition ==='
# The pure query must answer with NO window and NO state context — CI's
# exported-root band has neither, and the first form of this helper (stderr to
# /dev/null, window inherited from the caller's environment) turned the tool's
# `exit 2 "NEXUS_WORKER_WINDOW unset"` into an EMPTY disposition for every word
# while passing on any host whose shell exports a window (job 100855304683 on
# PR your-org/nexus-code#1437). Strip both window variables so the assertion is
# about the query, and let the tool's stderr through so a refusal is LOUD.
vd() {
    local _o _rc
    _o=$(env -u NEXUS_WORKER_WINDOW -u NEXUS_ASYNC_RUN_WINDOW bash "$ASYNC_RUN" --verdict-disposition "$1" 2>&1); _rc=$?
    if (( _rc != 0 )); then printf 'vd(%s): async-run.sh exited %s: %s\n' "$1" "$_rc" "$_o" >&2; return 1; fi
    printf '%s' "$_o"
}
assert_eq "running -> live"            "$(vd running)"          live
assert_eq "cancel-requested -> live"   "$(vd cancel-requested)" live
assert_eq "terminal -> settled"        "$(vd terminal)"         settled
assert_eq "cancelled -> settled"       "$(vd cancelled)"        settled
assert_eq "died -> gone"               "$(vd died)"             gone
assert_eq "unknown -> doubt"           "$(vd unknown)"          doubt
assert_eq "POSITIVE CONTROL: an unheard-of word -> doubt (default deny)" "$(vd bogus-verdict)" doubt
assert_eq "--disposition-line carries disposition|verdict|detail" \
    "$(NEXUS_ASYNC_RUN_WINDOW="$W" bash "$ASYNC_RUN" --disposition-line ar-canc 2>/dev/null | cut -d'|' -f1,2)" \
    "settled|cancelled"

echo '=== RATCHET: every verdict _verdict can print has a disposition ==='
# Enumerate the `<word>|` literals inside `_verdict` from the SOURCE — the only
# population the disposition must cover — and sanity-check the count against
# the six the function documents (a silent zero here would pass vacuously).
_words=$(sed -n '/^_verdict() {/,/^}/p' "$ASYNC_RUN" \
    | grep -oE "printf '[a-z-]+\|" | sed -E "s/^printf '//; s/\|$//" | sort -u)
_nwords=$(printf '%s\n' "$_words" | grep -c .)
assert_eq "ratchet enumerates the six documented verdicts (not a silent zero)" "$_nwords" 6
# The ratchet must NOT be blind to the tool being broken (orchestrator on
# your-org/nexus-code#1437): with the pre-fix async-run.sh returning '' for
# every word, '' != doubt accumulated NOTHING and the assertion below passed
# vacuously. So first require every word's disposition to be NON-EMPTY and a
# MEMBER of the known set; only then test it against `doubt`.
_undisposed=""; _unmapped=""
while IFS= read -r _w; do
    [[ -n "$_w" ]] || continue
    _d=$(vd "$_w") || _d=""
    case "$_d" in live|settled|gone|doubt) ;; *) _unmapped+="$_w=<${_d}> ";; esac
    [[ "$_w" == unknown ]] && continue
    [[ "$_d" == doubt ]] && _undisposed+="$_w "
done <<<"$_words"
assert_eq "every verdict word maps to a KNOWN, non-empty disposition (unmapped: '${_unmapped}')" "$_unmapped" ""
assert_eq "every non-unknown verdict has a non-doubt disposition (undisposed: '${_undisposed}')" "$_undisposed" ""

# ---- summary ----
# Ledger footer (your-org/nexus-code#805 / #1145): the count is DECLARED so a
# silently-skipped assertion is a red, not a shorter green.
EXPECTED_ASSERTIONS=29
_ran=$(( ${PASS:-0} + ${FAIL:-0} ))
if (( _ran == EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
