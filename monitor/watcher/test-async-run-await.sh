#!/usr/bin/env bash
# monitor/watcher/test-async-run-await.sh — tests for `async-run.sh --await`,
# the bounded wait that owns BOTH the loop and the predicate
# (your-org/nexus-code#1229).
#
# THE PROBLEM. A hand-rolled waiter carried a STATUS arm and a SHAPE arm in one
# loop. The status arm was correct and never wedged. The shape arm keyed on
# `^(PASS|FAIL|UNVERIFIED|REFUSED)` while the producer emits INDENTED lines
# carrying a COLON — `    PASS: …` — so it matched NOTHING, and the producer
# had ALREADY FINISHED. An audit of every waiter in that session found FOUR OF
# FIVE carrying a predicate that could never match and THREE with no deadline.
#
# SO THE PROPERTY UNDER TEST IS NOT "does it wait". It is: DOES IT REFUSE, AT
# t=0, A PREDICATE THAT CAN NEVER MATCH. A wait whose predicate is unsatisfiable
# is not slow — it is broken — and the difference is invisible after the fact,
# because both produce a timeout. The positive control is what separates them,
# and it costs one grep.
#
# The two delimiter bugs below are pinned because #1229's own controls found
# them, and BOTH failed CLOSED FOR THE WRONG REASON — the shape to fear:
#   - `::` as the record delimiter collides with a predicate ENDING IN A COLON,
#     which is precisely the real-world case. A delimiter that can occur inside
#     the field it delimits is not a delimiter.
#   - TAB is IFS WHITESPACE, so `read` COLLAPSES empty fields and a record with
#     an omitted middle silently shifts the control log into the regex slot.
# US (0x1f) is neither, so empty fields survive and get REFUSED rather than
# guessed.
#
# Run: bash monitor/watcher/test-async-run-await.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
AR="$_repo_root/monitor/async-run.sh"
[[ -x "$AR" ]] || { echo "not executable: $AR" >&2; exit 1; }

. "$_test_dir/_test_helpers.sh"

if ! command -v setsid >/dev/null 2>&1; then
    th_skip "setsid unavailable — async-run.sh cannot detach on this host"
    th_summary_and_exit
fi

WORK=$(mktemp -d)
cleanup() { th_reap_fixture_root "$WORK" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

export NEXUS_ROOT="$_repo_root"
export NEXUS_STATE_DIR="$WORK/.state"
export NEXUS_WORKER_WINDOW="arw"
export CLAUDE_CODE_SESSION_ID="cccccccc-1111-2222-3333-444444444444"

. "$_repo_root/monitor/_bookkeeping.sh" 2>/dev/null || true
ROOT="$WORK/.state/async-run/$(wk_encode arw)"

US=$'\037'
launch() { "$AR" --desc t -- "$@" | sed -n 's/^  token   //p'; }
await()  { "$AR" --await "$@" 2>&1; }
await_rc() { "$AR" --await "$@" >/dev/null 2>&1; printf '%s' "$?"; }

# THE PRODUCER'S REAL SHAPE, reproduced exactly: indented, colon-carrying.
# Getting this wrong would make the whole suite test a strawman.
PROD="$WORK/producer.log"
printf 'starting the sweep\n    PASS: first thing\n    FAIL: second thing\n' > "$PROD"
CTL="$WORK/control.log"
printf '    PASS: a line this predicate is known to match\n' > "$CTL"

echo "== async-run.sh --await =="

# --------------------------------------------------------- t_deadline_req --
# A DEADLINE IS MANDATORY. Three of five audited waiters had none.
assert_rc "no --timeout → REFUSED (2), not an unbounded wait" \
          "$(await_rc --token nope)" 2
assert_rc "a zero --timeout → REFUSED (2)"    "$(await_rc --timeout 0 --token nope)" 2
assert_rc "a non-numeric --timeout → REFUSED (2)" "$(await_rc --timeout soon --token nope)" 2
out=$(await --token nope)
assert_contains "…and it explains why an unbounded wait is not acceptable" "$out" "not yet"

# --------------------------------------------------------- t_empty_set -----
# An EMPTY producer set would complete instantly and report success — the
# manufactured-success direction of #928.
rc=$(await_rc --timeout 5)
assert_rc       "no --token and no --shape → REFUSED (2), never instant success" "$rc" 2
assert_contains "…and it names the hazard" "$(await --timeout 5)" "EMPTY producer set"

# ------------------------------------------------------- t_bad_predicate ---
# THE #1229 DEFECT ITSELF: `^(PASS|…)` against indented output. It must be
# refused AT t=0 — before any waiting — and must name the cause.
BAD='^(PASS|FAIL|UNVERIFIED|REFUSED)'
t_start=$(date +%s)
out=$(await --timeout 30 --shape "${BAD}${US}${PROD}${US}${PROD}"); rc=$?
t_end=$(date +%s)
assert_rc       "an unsatisfiable predicate → REFUSED (2), not a timeout"    "$rc" 2
assert_contains "…naming the positive control it failed"                     "$out" "does NOT match its own positive control"
assert_contains "…and naming INDENTATION as the usual cause"                 "$out" "INDENTED"
# THE POINT OF t=0: refusing after the deadline would be useless.
if (( t_end - t_start < 5 )); then
    assert_eq "…and it refuses IMMEDIATELY, not after the 30s deadline" "fast" "fast"
else
    assert_eq "…and it refuses IMMEDIATELY, not after the 30s deadline" "took $((t_end-t_start))s" "fast"
fi

# ----------------------------------------------------- t_empty_predicate ---
# An EMPTY regex matches every line, so it would complete instantly against any
# non-empty log — a confident success that measured nothing.
out=$(await --timeout 10 --shape "${US}${PROD}${US}${CTL}"); rc=$?
assert_rc       "an EMPTY shape predicate → REFUSED (2)"      "$rc" 2
assert_contains "…and it says an empty regex matches everything" "$out" "matches EVERY line"

# -------------------------------------------------------- t_us_delimiter ---
# A PREDICATE ENDING IN A COLON. Under the `::` delimiter #1229 prototyped,
# this record is mis-split — and it is the SHAPE OF THE REAL CASE.
COLON='    PASS:'
out=$(await --timeout 10 --shape "${COLON}${US}${PROD}${US}${CTL}"); rc=$?
assert_rc "a predicate ENDING IN A COLON parses correctly and completes (rc 0)" "$rc" 0
assert_contains "…having matched in the producer log" "$out" "matched in $PROD"

# EMPTY FIELDS MUST SURVIVE. Under TAB (IFS whitespace) `read` collapses them
# and the control log slides into the regex slot; under US they are preserved
# and can be refused.
out=$(await --timeout 10 --shape "${COLON}${US}${US}${CTL}"); rc=$?
assert_rc       "a record with an EMPTY middle field → REFUSED (2), not collapsed" "$rc" 2
assert_contains "…demanding all three fields"                                      "$out" "THREE US-separated fields"
assert_rc "a record with a MISSING third field → REFUSED (2)" \
          "$(await_rc --timeout 10 --shape "${COLON}${US}${PROD}")" 2

# A control log that cannot be read is an unproven predicate, not a pass.
assert_rc "an unreadable positive control → REFUSED (2)" \
          "$(await_rc --timeout 10 --shape "${COLON}${US}${PROD}${US}$WORK/no-such-control.log")" 2

# ------------------------------------------------------------ t_deadline ---
# A PROVEN predicate that has not matched YET must WAIT and then report a
# DEADLINE — distinct from the refusal above, and explicitly UNDECIDED.
NOTYET='    SUMMARY:'
printf '    SUMMARY: this control proves the predicate is satisfiable\n' > "$WORK/ctl2.log"
t0=$(date +%s)
out=$(await --timeout 3 --interval 1 --shape "${NOTYET}${US}${PROD}${US}$WORK/ctl2.log"); rc=$?
t1=$(date +%s)
assert_rc       "a PROVEN predicate that has not matched yet → DEADLINE (4)" "$rc" 4
assert_contains "…and the deadline is reported as UNDECIDED"                 "$out" "UNDECIDED, NEVER CONFIRMATION"
assert_contains "…carrying the no-growth census"                             "$out" "consecutive polls with no growth"
assert_contains "…and naming the unmatched shape"                            "$out" "NOT yet matched"
if (( t1 - t0 >= 3 )); then
    assert_eq "…having actually waited out the deadline" "waited" "waited"
else
    assert_eq "…having actually waited out the deadline" "returned in $((t1-t0))s" "waited"
fi

# --------------------------------------------------------- t_token_arm ----
# THE PREFERRED ARM. A terminal token completes.
t_ok=$(launch true)
out=$(await --timeout 30 --interval 1 --token "$t_ok"); rc=$?
assert_rc       "a token that reaches terminal → complete (rc 0)" "$rc" 0
assert_contains "…reporting the token as terminal"                "$out" "token $t_ok: terminal"
assert_contains "…and saying it completed"                        "$out" "await: complete"

# AN UNKNOWN TOKEN IS NOT TERMINAL. Reading "could not tell" as "done" is the
# collapse this whole surface exists to prevent — it must wait out the
# deadline and must NOT report complete.
out=$(await --timeout 3 --interval 1 --token "ar-doesnotexist"); rc=$?
assert_rc           "an UNKNOWN token → DEADLINE (4), never complete"     "$rc" 4
assert_contains     "…marked explicitly as NOT terminal"                  "$out" "NOT terminal"
assert_not_contains "…and it must not claim completion"                   "$out" "await: complete"

# A DIED TOKEN resolves the wait but is NOT success — `died` is the value no
# shape predicate can express, and it gets its own exit code.
t_die=$(launch sleep 60)
i=0; while (( i < 40 )) && [[ ! -s "$ROOT/$t_die/pidstart" ]]; do sleep 0.25; i=$(( i + 1 )); done
dpid=$(cat "$ROOT/$t_die/pid" 2>/dev/null)
kill -KILL "$dpid" 2>/dev/null
i=0; while (( i < 40 )) && kill -0 "$dpid" 2>/dev/null; do sleep 0.25; i=$(( i + 1 )); done
v=$("$AR" --status-line "$t_die"); v="${v%%|*}"
if [[ "$v" == "died" ]]; then
    out=$(await --timeout 10 --interval 1 --token "$t_die"); rc=$?
    assert_rc       "a DIED token resolves the wait but is NOT success (rc 5)" "$rc" 5
    assert_contains "…and says so"                                             "$out" "DIED or was CANCELLED"
    assert_contains "…naming the token that died"                              "$out" "token $t_die: died"
    # rc 5 must be DISTINCT from the plain-success 0: a resolved-but-dead wait
    # and a clean completion are different facts, and a caller that cannot tell
    # them apart will consume a TRUNCATED intermediate as a complete one.
    rc_ok=$(await_rc --timeout 30 --interval 1 --token "$t_ok")
    assert_eq "…and rc 5 is distinct from the clean-completion rc" "$rc:$rc_ok" "5:0"
else
    th_skip "could not stage a 'died' token (verdict was '$v')"
fi

# ------------------------------------------------------------- t_mixed ----
# Both arms together: a terminal token AND a matched shape.
out=$(await --timeout 30 --interval 1 --token "$t_ok" \
        --shape "${COLON}${US}${PROD}${US}${CTL}"); rc=$?
assert_rc       "token arm + proven shape arm, both satisfied → rc 0" "$rc" 0
assert_contains "…reporting both"                                     "$out" "token $t_ok: terminal"
assert_contains "…including the shape"                                "$out" "matched in $PROD"

# --------------------------------------------------------- t_one_shell ----
# ONE SHELL, MATCHING THE SHEBANG. #1229's prototype mixed bash `declare -A`
# with zsh `${=VAR}` and crashed with `bad substitution` AT THE DEADLINE ARM —
# a crash in the one arm whose job is to report a wedge.
head1=$(head -1 "$AR")
assert_contains "async-run.sh declares a bash shebang" "$head1" "bash"
awaitregion_raw=$(awk '/^    --await\)/,/^    --cancel\)/' "$AR")
assert_contains "the --await region was located" "$awaitregion_raw" "DEADLINE"
# COMMENTS STRIPPED BEFORE SCANNING. The region's prose necessarily QUOTES the
# zsh constructs it exists to warn about, so a raw scan flags the warning for
# containing the thing it warns about — the assertion would fail on correct
# code. Scan the CODE.
awaitregion=$(grep -v '^[[:space:]]*#' <<<"$awaitregion_raw")
for zshism in '${=' 'setopt' 'typeset -A'; do
    if grep -qF -- "$zshism" <<<"$awaitregion"; then
        printf '  FAIL: --await region contains a zsh-only construct: %q\n' "$zshism" >&2
        _th_fail
    else
        printf '  PASS: --await region is free of the zsh-only %q\n' "$zshism"
        _th_pass
    fi
done

# COUNT GUARD (your-org/nexus-code#821 / #1308). The ledger proves no assertion
# was LOST in a subshell; it cannot prove one was never REACHED. A suite whose
# arms stop running still prints a green summary of whatever did run, so the
# count is declared here and compared EXACTLY. Bump it deliberately when adding
# an arm; a mismatch is a red, not a warning.
EXPECTED_ASSERTIONS=41
_run_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
