#!/usr/bin/env bash
# your-org/nexus-code#1281 — NO UNRESOLVABLE WINDOW MAY YIELD A KILL-AUTHORISED
# STATE.
#
# Run: bash monitor/watcher/test-pane-state-resolver-precondition.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE PROPERTY, NOT THE PATCH
# ---------------------------
# `monitor/pane-state.sh` sources `monitor/_tmux-window.sh` CONDITIONALLY, and
# its two consumers used to degrade in opposite directions when the source did
# not take. The NAME arm failed CLOSED (`resolve_window_index` missing ->
# `_ps_resolve_rc=3` -> exit 2). The NUMERIC arm failed OPEN: `_ps_key_rc` was
# initialised to `0`, which is the value that means NOT AMBIGUOUS, so "the
# ambiguity check did not run" and "the ambiguity check passed" were spelled
# identically — and the script then answered about the INDEX-side window.
#
# That is not a wrong-window ANSWER, it is a wrong-window KILL AUTHORISATION.
# `_bookkeeping.sh:bk_pane_kill_authorized` allowlists `absent`, and CLAUDE.md
# calls `absent` "the state that positively asserts a dead agent". A key that
# NAMES a live window, answered on the index side about a DIFFERENT window whose
# pane pid has been reaped, emits `absent` at rc 0 with an EMPTY stderr.
#
# SO THIS SUITE ASSERTS THE PROPERTY AND NOT THE SOURCE TEXT. A regex over
# `pane-state.sh` would be a proxy for the property — the class of guard this
# repo keeps re-committing and then discovering was fitted to one finding. What
# is asserted is: drive the REAL `pane-state.sh`, with the resolver
# unavailable, and require that whatever comes back is NOT a state on the kill
# allowlist. The allowlist itself is READ FROM `_bookkeeping.sh` at run time, so
# a state added there tomorrow is covered without editing this file.
#
# NO REAL tmux, BY DESIGN. The fixture drives a stub `tmux` on a private PATH.
# That is not merely convenient: a suite gated on a binary would `exit 0` on a
# host lacking it, and an exit-0 skip on a KILL-AUTHORISATION guard is
# `your-org/nexus-code#1277` — a green that certifies a surface as tested when
# nothing ran. This suite has no dependency gate and no skip path. Nothing here
# touches a real tmux server, so `tmux kill-server` is not merely avoided, it is
# unreachable.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MON=$(cd "$_test_dir/.." && pwd)
PANE_STATE="$MON/pane-state.sh"
RESOLVER="$MON/_tmux-window.sh"
BOOKKEEPING="$MON/_bookkeeping.sh"

# THE SHARED LEDGER, NOT A HAND-ROLLED TALLY. `th_summary_and_exit` is what
# makes this suite's green certify that SOMETHING was asserted and that no FAIL
# was swallowed in a subshell (your-org/nexus-code#805) — and adopting it is what
# `summary-honesty.manifest` prescribes for a NEWLY ADDED suite, in as many
# words: appending a row for your own new code is opting it out of the standard
# the file exists to hold. Paired with the exact `EXPECTED_ASSERTIONS` guard at
# the foot, this file is `ledger=yes count=exact` and needs no row.
# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

# `assert_ne` is not in the shared set; built on the shared ledger primitives so
# a failure it records survives a subshell exactly like `assert_eq`'s.
assert_ne() {
    local label="$1" got="$2" notwant="$3"
    if [[ "$got" != "$notwant" ]]; then
        printf '  PASS: %s\n' "$label"; _th_pass
    else
        printf '  FAIL: %s — got %q which is exactly what must not happen\n' "$label" "$got" >&2
        _th_fail
    fi
}

for f in "$PANE_STATE" "$RESOLVER" "$BOOKKEEPING"; do
    [[ -r "$f" ]] || { echo "HARNESS: cannot read $f — refusing to report a verdict" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# §0  THE KILL ALLOWLIST, READ FROM ITS OWN DEFINITION
# ---------------------------------------------------------------------------
# Hardcoding `absent idle autosuggest-only idle-orphan-async` here would make
# this guard a SNAPSHOT of the allowlist rather than a test against it: a state
# promoted onto the allowlist tomorrow would be uncovered, silently, and the
# suite would still be green. Source the definition.
# shellcheck disable=SC1090
. "$BOOKKEEPING" >/dev/null 2>&1 || true
if ! declare -p _BK_KILL_OK_STATES >/dev/null 2>&1; then
    echo "HARNESS: _BK_KILL_OK_STATES not defined after sourcing $BOOKKEEPING — the property under test cannot be stated, so no verdict is reported" >&2
    exit 1
fi
KILL_OK=" ${_BK_KILL_OK_STATES[*]} "
assert_ne "the kill allowlist was read and is non-empty" "${KILL_OK// /}" ""
case "$KILL_OK" in
    *" absent "*) printf '  PASS: %s\n' "allowlist self-check: 'absent' is kill-authorising (the premise of this suite)"; _th_pass ;;
    *) printf '  FAIL: %s\n' "allowlist self-check: 'absent' is NOT on _BK_KILL_OK_STATES — this suite's premise has moved; re-read #1281 before editing" >&2; _th_fail ;;
esac

is_kill_authorised() { case "$KILL_OK" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------------------
# §1  FIXTURE
# ---------------------------------------------------------------------------
# Window 0 is NAMED `1` and has a LIVE descendant.
# Window 1 is named `livework` and its pane pid has been REAPED.
# The key `1` is therefore ambiguous by construction: it is window 0's NAME and
# window 1's INDEX, and they are different windows.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/psrp.XXXXXX") || { echo "HARNESS: mktemp failed" >&2; exit 1; }
cleanup() {
    [[ -n "${LIVE_PID:-}" ]] && kill "$LIVE_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/lib" "$WORK/bin"
cp "$PANE_STATE" "$WORK/lib/pane-state.sh"
cp "$RESOLVER"   "$WORK/lib/_tmux-window.sh"

cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
# Stub tmux. Answers ONLY the subcommands pane-state.sh and _tmux-window.sh
# ask, and never contacts a server.
case "${1:-}" in
  list-windows)
    # TWO CALL SHAPES, because the resolver makes two different asks
    # (your-org/nexus-code#1318): the SCOPED question keyed by
    # `#{window_index}|#{window_name}`, and the CROSS-SESSION ambiguity sweep
    # keyed by `#{session_name}|#{window_index}|#{window_name}`. A stub that
    # answers the two-field shape to both makes the sweep's rows fail
    # `_tmux_window_check_row`, which is rc 3 COULD-NOT-LOOK — correct
    # fail-closed behaviour against a tmux that will not answer, and simply
    # wrong as a model of one that would. This fixture has ONE session, so `-a`
    # and the bare form describe the same two windows.
    _fmt=""; for _a in "$@"; do _fmt="$_a"; done
    case "$_fmt" in
      *'#{session_name}'*) printf 'psrp|0|1\npsrp|1|livework\n' ;;
      *)                   printf '0|1\n1|livework\n' ;;
    esac
    exit 0 ;;
  display-message)
    tgt=""; fmt=""
    while [ $# -gt 0 ]; do
      case "$1" in -t) tgt="$2"; shift 2 ;; -p) shift ;; *) fmt="$1"; shift ;; esac
    done
    idx="${tgt##*:}"
    case "$fmt" in
      '#{window_index}')  printf '%s\n' "$idx" ;;
      '#{window_name}')   if [ "$idx" = 0 ]; then printf '1\n'; else printf 'livework\n'; fi ;;
      '#{window_active}') printf '0\n' ;;
      '#{pane_pid}')      if [ "$idx" = 0 ]; then printf '%s\n' "$NX_LIVE_PID"; else printf '%s\n' "$NX_DEAD_PID"; fi ;;
      '#{pane_dead}')     printf '0\n' ;;
      *) printf '\n' ;;
    esac
    exit 0 ;;
  capture-pane) printf '\n'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/tmux"

# A LIVE process with a live child, standing in for a booting/working pane.
setsid bash -c 'sleep 300 & wait' >/dev/null 2>&1 &
LIVE_PID=$!
# A pid that is definitively gone: forked, reaped, then re-checked.
DEAD_PID=""
for _try in 1 2 3 4 5; do
    bash -c 'exit 0' & _d=$!
    wait "$_d" 2>/dev/null
    if ! kill -0 "$_d" 2>/dev/null; then DEAD_PID="$_d"; break; fi
done
if [[ -z "$DEAD_PID" ]]; then
    echo "HARNESS: could not obtain a reaped pid — refusing to report a verdict" >&2
    exit 1
fi
export NX_LIVE_PID="$LIVE_PID" NX_DEAD_PID="$DEAD_PID"

# `probe <script> <key>` -> prints "<rc>|<stdout>"; stderr discarded.
probe() {
    local script="$1" key="$2" out rc
    out=$(PATH="$WORK/bin:$PATH" bash "$script" "$key" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$out"
}
state_of() {  # extract state= from a probe result, or the empty string
    local r="${1#*|}"
    [[ "$r" == *state=* ]] || { printf ''; return; }
    printf '%s' "${r#*state=}" | sed 's/[^A-Za-z-].*//'
}
rc_of() { printf '%s' "${1%%|*}"; }

lib_off() { chmod 000 "$WORK/lib/_tmux-window.sh"; }
lib_on()  { chmod 644 "$WORK/lib/_tmux-window.sh"; }

# ---------------------------------------------------------------------------
# §2  POSITIVE CONTROLS — the instrument is live and CAN produce the bad state
# ---------------------------------------------------------------------------
# Without these, §3's "not kill-authorised" is vacuous: a fixture that answers
# nothing at all would pass it. So first prove (a) the probe classifies, and
# (b) this very fixture is capable of emitting a kill-authorised state — it is
# the emission of that state for the WRONG window that is the defect, not the
# state itself.
lib_on
r_live=$(probe "$WORK/lib/pane-state.sh" 0)
assert_eq "positive control: resolver present, live name-side window classifies at rc 0" \
          "$(rc_of "$r_live")" "0"
assert_ne "positive control: the live window is NOT reported kill-authorised" \
          "$(is_kill_authorised "$(state_of "$r_live")" && echo YES || echo NO)" "YES"

r_dead=$(probe "$WORK/lib/pane-state.sh" livework)
assert_eq "positive control: the reaped-pid window classifies 'absent'" \
          "$(state_of "$r_dead")" "absent"
assert_eq "positive control: 'absent' from this fixture IS kill-authorising — the fixture can produce the bad outcome" \
          "$(is_kill_authorised "$(state_of "$r_dead")" && echo YES || echo NO)" "YES"

r_amb=$(probe "$WORK/lib/pane-state.sh" 1)
assert_eq "resolver present: the ambiguous key is REFUSED, rc 2" "$(rc_of "$r_amb")" "2"
assert_eq "resolver present: a refusal emits NOTHING on stdout" "${r_amb#*|}" ""

# ---------------------------------------------------------------------------
# §3  THE PROPERTY — resolver unavailable, no key may yield a kill-authorised
#     state, in ANY of its spellings
# ---------------------------------------------------------------------------
lib_off
for key in 1 0:1 livework; do
    r=$(probe "$WORK/lib/pane-state.sh" "$key")
    st=$(state_of "$r")
    assert_ne "resolver unavailable, key '$key': emitted state is NOT kill-authorised" \
              "$(is_kill_authorised "$st" && echo "KILL-AUTHORISED:$st" || echo NO)" \
              "KILL-AUTHORISED:$st"
    assert_eq "resolver unavailable, key '$key': nothing on stdout to parse" "${r#*|}" ""
    assert_eq "resolver unavailable, key '$key': refuses with rc 2" "$(rc_of "$r")" "2"
done
lib_on

# ---------------------------------------------------------------------------
# §4  MUTATION — the guard must REACT, and the mutant must be PROVEN APPLIED
#     TO THE REGION
# ---------------------------------------------------------------------------
# An inert mutant and a surviving real mutant give byte-identical output, so
# each mutant below is (a) located by its anchor, (b) proved to have landed
# inside the window-resolution region — between the `gather pane state` banner
# and the `emit()` definition — and (c) proved to have changed the file.
# `grep -m1`, NEVER `grep … | head -1` (your-org/nexus-code#622 family). This
# file runs under `set -o pipefail`, where `head` closing the pipe early makes
# the producer die on SIGPIPE and the PIPELINE report that rc — an early-exit
# reader. `-m1` stops grep itself, so nothing is killed and there is no rc to
# misread. `cut` drains, so it is safe on the right of a pipe.
REGION_START=$(command grep -n -m1 -- '---- gather pane state' "$PANE_STATE" | cut -d: -f1)
REGION_END=$(command grep -n -m1 '^emit() {' "$PANE_STATE" | cut -d: -f1)
ANCHOR_LINE=$(command grep -n -m1 'the window-key resolver (%s) is unavailable' "$PANE_STATE" | cut -d: -f1)
assert_ne "region bounds located in the real pane-state.sh" \
          "${REGION_START:-}:${REGION_END:-}:${ANCHOR_LINE:-}" "::"
if [[ -n "$REGION_START" && -n "$REGION_END" && -n "$ANCHOR_LINE" ]] \
   && (( ANCHOR_LINE > REGION_START && ANCHOR_LINE < REGION_END )); then
    printf '  PASS: %s\n' "the precondition lives INSIDE the window-resolution region (${REGION_START} < ${ANCHOR_LINE} < ${REGION_END})"
    _th_pass
else
    printf '  FAIL: %s\n' "the precondition is not inside the window-resolution region — anchor=${ANCHOR_LINE:-none} region=${REGION_START:-none}..${REGION_END:-none}" >&2
    _th_fail
fi

# run_mutant <label> <sed-program...> — applies to a COPY, proves it landed,
# then requires §3's property to FAIL on the mutant.
run_mutant() {
    local label="$1"; shift
    local m="$WORK/lib/mutant.sh"
    cp "$PANE_STATE" "$m"
    "$@" "$m"
    if cmp -s "$PANE_STATE" "$m"; then
        printf '  FAIL: %s — MUTANT DID NOT APPLY (file byte-identical); this round proves nothing\n' "$label" >&2
        _th_fail
        return
    fi
    printf '  PASS: %s\n' "$label — mutant applied (file differs from pristine)"
    _th_pass
    if ! bash -n "$m" 2>/dev/null; then
        printf '  FAIL: %s — mutant does not parse; a syntax error is not a demonstration\n' "$label" >&2
        _th_fail
        return
    fi
    printf '  PASS: %s\n' "$label — mutant still parses, so any reaction is behavioural"
    _th_pass
    lib_off
    local r st rc reacted=NO
    for key in 1 0:1 livework; do
        r=$(probe "$m" "$key"); st=$(state_of "$r"); rc=$(rc_of "$r")
        if is_kill_authorised "$st" || { [[ "$rc" == 0 ]] && [[ -n "$st" ]]; }; then
            reacted=YES
        fi
    done
    lib_on
    assert_eq "$label — the guard REACTS: mutant classifies with the resolver unavailable" "$reacted" "YES"
}

# M1 — DELETION. Remove the precondition block outright.
mut_delete() {
    python3 - "$1" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
m=re.search(r'\n    if ! declare -F resolve_window_key[\s\S]*?\n        exit 2\n    fi\n', s)
if m: s=s[:m.start()]+'\n'+s[m.end():]
open(p,'w',encoding='utf-8').write(s)
PY
}
run_mutant "M1 precondition DELETED" mut_delete

# M2 — VALUE CHANGE, not deletion. The precondition survives but tests only
# `resolve_window_index`, the function whose absence the NAME arm already
# handles. The numeric arm's fail-open returns while the guard's own text still
# reads correct. This is the mutant a fix fitted to the demonstrated repro
# survives, which is why it is here.
mut_weaken() {
    python3 - "$1" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='''    if ! declare -F resolve_window_key >/dev/null 2>&1 \\
        || ! declare -F resolve_window_index >/dev/null 2>&1; then'''
new='''    if [[ -n "${_PS_NEVER_SET:-}" ]] && ! declare -F resolve_window_index >/dev/null 2>&1; then'''
if old in s: s=s.replace(old,new,1)
open(p,'w',encoding='utf-8').write(s)
PY
}
run_mutant "M2 precondition WEAKENED to a condition that cannot fire" mut_weaken

# M3 — RELOCATION. The precondition is intact and correct, but moved BELOW the
# branch that consumes it, so it can no longer protect the numeric arm. Moving
# a guard is the mutation a presence check cannot see.
mut_reintroduce_failopen() {
    python3 - "$1" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='''        _ps_key_rc=0
        resolve_window_key "$target" >/dev/null 2>&1 || _ps_key_rc=$?'''
new='''        _ps_key_rc=0
        if declare -F resolve_window_key >/dev/null 2>&1; then
            resolve_window_key "$target" >/dev/null 2>&1 || _ps_key_rc=$?
        fi'''
old_pre='''    if ! declare -F resolve_window_key >/dev/null 2>&1 \\
        || ! declare -F resolve_window_index >/dev/null 2>&1; then'''
new_pre='''    if false && ! declare -F resolve_window_key >/dev/null 2>&1; then'''
if old in s: s=s.replace(old,new,1)
if old_pre in s: s=s.replace(old_pre,new_pre,1)
open(p,'w',encoding='utf-8').write(s)
PY
}
run_mutant "M3 the ORIGINAL fail-open restored behind an inert precondition" mut_reintroduce_failopen

# ---------------------------------------------------------------------------
# §5  summary
# ---------------------------------------------------------------------------
# EXACT COUNT, then the SHARED LEDGER. The two protect different things and
# neither implies the other: the count catches an assertion that never ran (a
# fixture that bailed, a helper that vanished at rc 127, which nothing else
# counts), and the ledger catches a FAIL recorded inside a subshell whose
# increment died with it.
EXPECTED_ASSERTIONS=28
echo
if (( PASS + FAIL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. Some assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi
th_summary_and_exit
