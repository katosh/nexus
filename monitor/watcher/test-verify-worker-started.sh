#!/usr/bin/env bash
# your-org/nexus-code#1334 guard: a spawn that creates a window is not a spawn
# that started a worker. A pane wedged on the workspace-trust dialog satisfies
# every check spawn-worker makes, so `spawned:` over it is a manufactured
# success — this repo's dominant defect class.
#
# The assertions that matter are the ones about NOT-SUCCESS: `empty` means
# "don't know yet" (#603) and `unknown` means "could not look at all", and a
# verifier that counts either as started manufactures what it exists to catch.
#
# Run: bash monitor/watcher/test-verify-worker-started.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Route through the shared harness so every verdict lands in the LEDGER, which
# survives the subshell the plain counters die in (your-org/nexus-code#805/#783).
# This suite in particular MUST be ledger-backed: it exercises a verifier whose
# whole job is to catch a manufactured success, and a suite that could announce
# a green while a FAIL was lost in a `$( )` would be that same defect one level
# up. This file polls pane states through command substitution throughout, so it
# is squarely in that population.
# shellcheck disable=SC1091
. "$_test_dir/_test_helpers.sh"

VWS="$_test_dir/../verify-worker-started.sh"
REAL_PANE_STATE="$_test_dir/../pane-state.sh"

EXPECTED_ASSERTIONS=30

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

# A stub pane-state.sh: $1 is the state line it reports, $2 (optional) the
# vocabulary it declares. Default vocabulary is the REAL one, read from the
# real tool — so this suite cannot drift from it by transcription.
REAL_STATES=$("$REAL_PANE_STATE" --states 2>/dev/null)
mk_stub() {
    local line="$1" states="${2:-$REAL_STATES}"
    # NO heredoc token anywhere in this function, not even inside a quoted
    # format string: mutation-gate.sh's eligibility scanner matches `<<TAG`
    # textually, so a `<<STATES` in a printf format latches its in_heredoc flag
    # and every later line in this file becomes ineligible — the whole suite
    # then reports `0 eligible`, which reads exactly like a suite with nothing
    # worth mutating. Write the states file with printf and a separate cat.
    printf '%s\n' "$states" > "$WORK/states.txt"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'if [ "$1" = "--states" ]; then cat %q; exit 0; fi\n' "$WORK/states.txt"
        printf 'printf %%s\\\\n %q\n' "$line"
    } > "$WORK/ps.sh"
    chmod +x "$WORK/ps.sh"
}
run_vws() {
    PANE_STATE_BIN="$WORK/ps.sh" bash "$VWS" testwin --timeout 2 --interval 1 >"$WORK/o" 2>"$WORK/e"
    echo $?
}

echo '=== states that POSITIVELY mean a REPL was reached → exit 0 ==='
for st in idle busy user-typing autosuggest-only working-background \
          working-self-paced over-limit idle-orphan-async; do
    mk_stub "state=$st active=1"
    assert_eq "started: $st → 0" "$(run_vws)" "0"
done

echo '=== UNDECIDED is never success — the #603 assertion ==='
# `empty` read on a pane 4m38s into real work. If this ever returns 0 the
# verifier is worse than none: it certifies the wedge it exists to find.
mk_stub "state=empty active=0"
assert_eq "empty (do-not-know-yet) -> 3, NOT 0" "$(run_vws)" "3"
mk_stub "state=unknown active=0"
assert_eq "unknown (could-not-look) -> 3, NOT 0" "$(run_vws)" "3"

echo '=== WEDGED is positively established → exit 1, and LOUD ==='
mk_stub "state=blocked active=0 window=1 name=cand overlay=workspace-trust"
assert_eq "blocked → 1" "$(run_vws)" "1"
err=$(cat "$WORK/e")
assert_contains "names the window and the state it OBSERVED" "$err" "is blocked after"
assert_contains "quotes the raw pane-state line as evidence" "$err" "overlay=workspace-trust"
assert_contains "cites the issue" "$err" "your-org/nexus-code#1334"
# #1063: a line that names a CAUSE instead of an OBSERVATION sends two people
# the wrong way. Both hypotheses are open, so it must claim neither.
assert_contains "refuses to assert a cause" "$err" "NAMES THE OBSERVATION, NOT THE CAUSE"
assert_contains "says nothing was killed" "$err" "nothing has been killed"
mk_stub "state=absent active=0"
assert_eq "absent → 1" "$(run_vws)" "1"

echo '=== fail-CLOSED on a vocabulary it does not fully classify ==='
# THE LOAD-BEARING ONE. A state nobody classified would fall to a default arm,
# which is how a denylist retires a live worker (#1214). Note the stub reports
# `idle` — so WITHOUT the partition guard this call exits 0 and looks perfect.
mk_stub "state=idle active=0" "$(printf '%s\nbrand-new-state' "$REAL_STATES")"
assert_eq "vocabulary GREW → 3 (REFUSED), despite the pane reading idle" "$(run_vws)" "3"
assert_contains "names the unclassified state" "$(cat "$WORK/e")" "brand-new-state"

echo '=== cannot ask the tool at all → REFUSED, never a verdict ==='
PANE_STATE_BIN="$WORK/nonexistent" bash "$VWS" testwin --timeout 2 >/dev/null 2>"$WORK/e2"; rc=$?
assert_eq "unreadable pane-state.sh → 3" "$rc" "3"
assert_contains "says it REFUSED rather than passing" "$(cat "$WORK/e2")" "REFUSED"

echo '=== argument SHAPE is validated, not merely non-empty (#1203) ==='
bash "$VWS" testwin --timeout notanumber >/dev/null 2>&1
assert_eq "non-numeric --timeout → 2 (usage)" "$?" "2"


echo '=== the folded-in trust-key read-back (#1334 step 3) ==='
# Taken at the moment the dialog is up, which is the only moment that
# discriminates: after it is answered both hypotheses leave the same state.
RBCFG="$WORK/rbcfg"; mkdir -p "$RBCFG"
RBWD="$WORK/rbwd";   mkdir -p "$RBWD"
RBWD_ABS=$(cd "$RBWD" && pwd -P)
mk_stub "state=blocked active=0 overlay=workspace-trust"
rb() {
    CLAUDE_CONFIG_DIR="$1" PANE_STATE_BIN="$WORK/ps.sh" \
        bash "$VWS" testwin --workdir "$RBWD" --timeout 1 --interval 1 >/dev/null 2>"$WORK/rb"
    cat "$WORK/rb"
}

jq -n '{projects:{}}' > "$RBCFG/.claude.json"
out=$(rb "$RBCFG")
assert_contains "key ABSENT is reported as ABSENT" "$out" "value:  ABSENT"
assert_contains "…and named as the CLOBBER signature" "$out" "Consistent with a"

jq -n --arg d "$RBWD_ABS" '{projects:{($d):{hasTrustDialogAccepted:true}}}' > "$RBCFG/.claude.json"
out=$(rb "$RBCFG")
assert_contains "key true is reported as true" "$out" "value:  true"
assert_contains "…and named as the INSUFFICIENT-KEY signature" "$out" "NOT being the only gating key"

# THE ONE THAT MATTERS MOST. "Could not read" printed as absent would be a
# FABRICATED clobber finding, and this issue already produced one false lead
# from exactly that confusion.
printf 'not json{' > "$RBCFG/.claude.json"
out=$(rb "$RBCFG")
assert_contains "unparseable config says UNKNOWN" "$out" "UNKNOWN (config is not valid JSON)"
assert_eq "…and never prints the word false for it" \
    "$(printf '%s' "$out" | grep -c 'value:  false')" "0"

EMPTYCFG="$WORK/emptycfg"; mkdir -p "$EMPTYCFG"
out=$(rb "$EMPTYCFG")
assert_contains "missing config says UNKNOWN" "$out" "UNKNOWN (config file does not exist)"
# Resolve through CLAUDE_CONFIG_DIR, never $HOME — the trap that produced the
# issue's false lead (~/.claude.json reads ABSENT for every workdir here).
assert_contains "reports the RESOLVED config path, so a reader can re-run it" \
    "$out" "$EMPTYCFG/.claude.json"

# ---- verdict ------------------------------------------------------------
# Reconcile the DECLARED count before handing off. A helper that silently stops
# being called is counted by nothing, so the count guard is what notices — it
# caught a real miscount in this very file (22 ran against 18 declared).
_total=$(( ${PASS:-0} + ${FAIL:-0} ))
if [[ "$_total" -ne "$EXPECTED_ASSERTIONS" ]]; then
    printf '  FAIL: assertion COUNT drifted — ran %d, expected %d\n' "$_total" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( ${FAIL:-0} + 1 ))
else
    printf '  PASS: every declared assertion executed (%d)\n' "$_total"
    PASS=$(( ${PASS:-0} + 1 ))
fi

th_summary_and_exit
