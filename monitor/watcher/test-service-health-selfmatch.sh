#!/usr/bin/env bash
# monitor/watcher/test-service-health-selfmatch.sh
#
# your-org/nexus-code#891 — a registry healthcheck run via `bash -c "$health"`
# puts the ENTIRE health string, pattern included, into a process's argv. A
# `pgrep -f` / `ps` healthcheck then matches ITSELF and returns 0 with nothing
# running: a BOOLEAN THAT IS ALWAYS TRUE. The service reads `healthy` forever,
# the supervisor never restarts it, and no fault is logged anywhere. #869
# (kill-side ownership) and #871 (the wait-side hook guard) both miss it,
# because it is neither a kill nor a wait.
#
# THE SAFE SET IS NARROWER THAN "SIMPLE COMMANDS" — this is the part the issue
# did not state, and it is why "just keep the healthcheck simple" is not a
# usable rule. bash only sheds the string by EXEC'ing, and it only execs a BARE
# simple command. Measured, bash 4.4.20, nothing matching the marker running,
# rc=1 correct:
#     pgrep -f M              rc=1   exec'd, safe
#     pgrep -f M >/dev/null   rc=0   FALSE HEALTHY  <- a redirection defeats exec
#     pgrep -f M && true      rc=0   FALSE HEALTHY
#     ( pgrep -f M )          rc=0   FALSE HEALTHY
#     exec pgrep -f M         rc=1   safe
# A redirection in a healthcheck is idiomatic, so the shipped registry is one
# `>/dev/null` away from a permanently-green dead service.
#
# TWO SITES, both fixed and both exercised here. `_service_health.sh` keeps a
# deliberate inline replica of `bootstrap-recover.sh`'s function (documented
# there, to avoid sourcing that script into the watcher). The watcher's copy is
# the consequential one — it runs every ~120s and drives auto-restart.
#
# SELF-MATCH DISCIPLINE — THIS SUITE IS ABOUT A SELF-MATCHING PREDICATE AND CAN
# ITSELF SELF-MATCH. The marker is GENERATED AT RUNTIME and never appears in
# this file, in any argv, or in any command line that created this file. An
# earlier probe for this very issue used a literal marker in the heredoc that
# wrote the probe, so the marker sat in the authoring shell's argv and BOTH
# arms reported healthy — the defect reproduced inside its own test.
#
# Run: bash monitor/watcher/test-service-health-selfmatch.sh

set -u
_test_dir=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$_test_dir/../.." && pwd)

# The summary-honesty manifest requires a suite's green to be recorded in the
# harness LEDGER, which survives the subshells plain counters die in. Adopted
# rather than opted out: appending this file to the manifest would opt my own
# new code out of the standard, which that manifest explicitly forbids.
# shellcheck source=/dev/null
. "$_test_dir/_test_helpers.sh"

PASS=0; FAIL=0
ok()   { printf '  PASS: %s\n' "$1"; _th_pass; }
bad()  { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

# assert_rc <desc> <expected-rc-class: zero|nonzero> <actual>
assert_rc() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = zero ]; then
        [ "$got" -eq 0 ] && ok "$desc" || bad "$desc (rc=$got, wanted 0)"
    else
        [ "$got" -ne 0 ] && ok "$desc" || bad "$desc (rc=$got, wanted non-zero)"
    fi
}

newmark() { printf 'hm%s' "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"; }

# Source the REAL implementations — no replica. bootstrap-recover.sh guards its
# entrypoint with [[ ${BASH_SOURCE[0]} == $0 ]], so sourcing is safe and this
# suite exercises the shipped code rather than a copy of it that could drift.
# shellcheck source=/dev/null
source "$ROOT/monitor/bootstrap-recover.sh" >/dev/null 2>&1
# shellcheck source=/dev/null
source "$ROOT/monitor/watcher/_service_health.sh" >/dev/null 2>&1

if ! declare -F _recover_service_healthy >/dev/null; then
    echo "FATAL: _recover_service_healthy not available after sourcing" >&2; exit 1
fi
if ! declare -F _sh_service_healthy >/dev/null; then
    echo "FATAL: _sh_service_healthy not available after sourcing" >&2; exit 1
fi

# ---------------------------------------------------------------------------
echo '=== nothing is running: every health-string shape must report UNHEALTHY ==='
# The shapes are exactly the ones bash does NOT exec. Before the fix, each of
# these returned 0 (healthy) against a process table containing no such service.
for fn in _recover_service_healthy _sh_service_healthy; do
    for shape in 'pgrep -f @M@' \
                 'pgrep -f @M@ >/dev/null' \
                 'pgrep -f @M@ 2>/dev/null' \
                 'pgrep -f @M@ && true' \
                 '( pgrep -f @M@ )'; do
        M=$(newmark)
        "$fn" / "${shape//@M@/$M}"
        assert_rc "$fn: ${shape//@M@/<marker>}" nonzero $?
    done
done

# ---------------------------------------------------------------------------
echo
echo '=== WITNESSING ASSERTIONS: a genuinely running service must read HEALTHY ==='
# Without these, a mutant that simply returns non-zero always would satisfy
# every assertion above. `exec -a` puts the marker in argv[0] of a REAL
# process, so the match is genuine rather than the checker seeing itself.
for fn in _recover_service_healthy _sh_service_healthy; do
    M=$(newmark)
    ( exec -a "$M" sleep 5 ) &
    _bgpid=$!
    sleep 0.2
    "$fn" / "pgrep -f $M"
    assert_rc "$fn: a REALLY running process reads healthy (bare)" zero $?
    "$fn" / "pgrep -f $M >/dev/null && true"
    assert_rc "$fn: …and via a compound string too" zero $?
    kill "$_bgpid" 2>/dev/null; wait "$_bgpid" 2>/dev/null
done

# ---------------------------------------------------------------------------
echo
echo '=== ordinary healthchecks must not regress ==='
for fn in _recover_service_healthy _sh_service_healthy; do
    "$fn" / "true";                      assert_rc "$fn: trivially true" zero $?
    "$fn" / "false";                     assert_rc "$fn: trivially false" nonzero $?
    "$fn" / "true && test -d /tmp";      assert_rc "$fn: healthy COMPOUND still passes" zero $?
    "$fn" / "test -f ./no-such-file-xyz"; assert_rc "$fn: missing file is unhealthy" nonzero $?
    "$fn" /tmp "test -d .";              assert_rc "$fn: workdir cwd is honoured" zero $?
    # An unreachable workdir reports UNHEALTHY: `cd` fails, the `&&` short-
    # circuits, and the subshell carries cd's status. That is PRE-EXISTING and
    # unchanged by the #891 fix — verified by running the ORIGINAL function from
    # `dev`, which also returns 1. Pinned so the fix cannot be blamed for it and
    # so a future change to the `cd` arm is deliberate.
    "$fn" /nonexistent-dir-xyz "test -d /tmp"
    assert_rc "$fn: unreachable workdir is unhealthy (pre-existing cd semantics)" nonzero $?
done

# ---------------------------------------------------------------------------
echo
echo '=== DECLARED OUT OF SCOPE: still-lying shapes that are NOT this mechanism ==='
# The #891 fix removes the health string from ARGV. Two shapes still return 0
# with nothing running, and it would be dishonest to let this suite imply
# otherwise — but neither is the argv mechanism, and each is measured as such by
# a control that contains NO process-table predicate at all.
#
#   (a) STATUS MASKING. `cmd ; true` and `cmd | head` return the LAST stage's
#       status. Nothing to do with self-matching; owned by the registry author.
#       Fix in the health string (`set -o pipefail`, or drop the trailing stage).
#   (b) `ps … | grep PATTERN`. Here the self-match is in GREP's own argv landing
#       in PS's OUTPUT — a different substrate from the health string in bash's
#       argv, and unreachable from this function. That shape is separately
#       guarded at the point of authorship by bash-footgun-guard's
#       `procmatch-self` rule.
#   (c) THE SIBLING MATCH (your-org/nexus-code#1222, mechanism #1073). A
#       `pgrep -f <pattern>` healthcheck is satisfied by ANY process whose argv
#       contains the pattern, including a live agent in another window whose
#       PROMPT quotes it — `claude`s argv is its prompt. Measured on a live
#       board: five processes matched `deploy-watch.sh`, one the service, two
#       live agents. So a dead service still reads HEALTHY.
#
#       THIS SUITE ASSERTS THAT SHAPE AS DESIRED BEHAVIOUR AND MUST KEEP DOING
#       SO. The witnessing assertions above run `pgrep -f $M` against a renamed
#       `sleep` — a process that is in no sense the service — and require it to
#       read healthy. That is structurally the sibling match. It is correct HERE
#       and must not be "fixed": those assertions exist so a mutant that simply
#       returns non-zero always cannot satisfy the suite, and #891 is a claim
#       about the probes OWN argv, not about whose process satisfies a pattern.
#
#       It is recorded as a DECLARED exclusion rather than left implicit because
#       an unstated assumption reads, to the next author, as a property the
#       suite has checked. The control below is the same shape as (a) and (b):
#       a health string with no process predicate at all, so the exclusion is
#       measured rather than asserted.
#
#       AND THE EXECUTOR MUST NOT BE MADE TO REFUSE IT. Returning non-zero for
#       an argv-shaped health string fails RED: unhealthy -> grace -> the
#       default `auto-restart` policy -> a WORKING service bounced repeatedly,
#       climbing to the flap ceiling, on every operator board that has such a
#       row. The sound fixes are at authorship (`services.registry.example`
#       carries the correct forms) and in the WORDING of an emit, never in the
#       boolean.
# (c) control — a health string naming a process that is NOT this service and
# NOT the probe: a third party satisfies the pattern. Asserted HEALTHY, which
# is the declared exclusion, and paired with a no-predicate control so the arm
# cannot pass merely because everything reads healthy.
_sib=$(newmark)
( exec -a "$_sib" sleep 5 ) &
_sibpid=$!
sleep 0.2
_sh_service_healthy / "pgrep -f $_sib"
assert_rc "(c) DECLARED: a THIRD-PARTY process satisfying the pattern reads healthy — the sibling match is out of scope here, and is fixed at authorship (#1222)" zero $?
kill "$_sibpid" 2>/dev/null; wait "$_sibpid" 2>/dev/null
_sh_service_healthy / "pgrep -f $_sib"
assert_rc "(c) CONTROL: with that third party GONE the same string reads unhealthy — so the arm above measured the MATCH, not a blanket green" nonzero $?

M=$(newmark)
_recover_service_healthy / "false ; true"
assert_rc "control: '; true' masks status with NO process predicate at all" zero $?
_recover_service_healthy / "false | head -1"
assert_rc "control: a pipeline masks status likewise" zero $?
_recover_service_healthy / "pgrep -f $M ; true"
assert_rc "so 'pgrep … ; true' still reads healthy — status masking, not argv" zero $?
_recover_service_healthy / "set -o pipefail; pgrep -f $M | head -1"
assert_rc "…and pipefail makes the SAME string report correctly" nonzero $?
M=$(newmark)
# NOTE the plain `grep`, not `grep -q`. These two strings are health-check DATA
# handed to the runner, not pipelines this suite executes — but
# your-org/nexus-code#622's lint is deliberately TEXTUAL (it cannot tell data
# from code, and its history is a chain of proxies that each let a live instance
# through), so a literal `| grep -q` here reds it. Dropping `-q` is
# behaviour-identical for this test: `_recover_service_healthy` already runs the
# string under `>/dev/null 2>&1`, and the property under test — grep's own argv
# appearing in `ps -ef` OUTPUT — does not depend on early exit. The rc is the
# same either way. Do NOT restore `-q` to satisfy idiom; it buys nothing here.
_recover_service_healthy / "ps -ef | grep $M"
assert_rc "'ps | grep' still reads healthy — grep's argv inside ps OUTPUT" zero $?
_recover_service_healthy / "ps -ef | grep '[${M:0:1}]${M:1}'"
assert_rc "…and the bracket idiom fixes it in the health string itself" nonzero $?

# ---------------------------------------------------------------------------
echo
echo '=== stderr capture on the watcher path is preserved (#637) ==='
M=$(newmark)
_sh_service_healthy / "printf 'UNHEALTHY - probe verdict\n' >&2; false"
_rc=$?
if [ "$_rc" -ne 0 ] && [[ "${_SH_HEALTH_DETAIL:-}" == *"probe verdict"* ]]; then
    ok "_sh_service_healthy still captures the failing check's stderr verdict"
else
    bad "_sh_service_healthy lost its stderr capture (rc=$_rc detail=${_SH_HEALTH_DETAIL:-<empty>})"
fi

# ---------------------------------------------------------------------------
echo
echo '=== source-level: neither site may reintroduce the argv-carrying form ==='
# The functional assertions above would catch a regression, but only for the
# shapes enumerated. This closes the class at the source, so a NEW site or a
# revert is caught by shape-independent means.
for f in monitor/bootstrap-recover.sh monitor/watcher/_service_health.sh; do
    # COMMENT LINES ARE STRIPPED FIRST. Both files now DOCUMENT the rejected
    # form in prose (`WHY NOT bash -c "$health"`), and the first version of this
    # check matched that prose and reported the defect present in the very files
    # that had just been fixed — a source check reading documentation as code.
    # Herestring on the comment-stripped body, not a second pipe stage into
    # `grep -q` (your-org/nexus-code#622's lint): the early-exiting reader would
    # EPIPE the upstream `grep -v` and, under pipefail, invert this verdict
    # precisely when the offending line IS present.
    if grep -qE 'bash[[:space:]]+-c[[:space:]]+"\$(\{)?health' \
         <<<"$(grep -vE '^[[:space:]]*#' "$ROOT/$f")"; then
        bad "$f still runs the health string through argv (bash -c \"\$health\")"
    else
        ok "$f does not pass the health string via argv"
    fi
done

echo '=== your-org/nexus-code#1222 — no COPYABLE example row prescribes an argv-shaped healthcheck ==='
# Keyed on the PROPERTY an operator actually exercises: they copy a row out of
# `services.registry.example` and paste it into their registry. So the check
# extracts the ROWS — commented template lines carrying the 4+ TAB-separated
# registry fields — and asserts no rows HEALTHCHECK field (field 4) is a
# process-table match. Prose about the hazard is not enough and is not what is
# asserted here: the file already warned against `pgrep -f` fifty-five lines
# above the row that used it (#1222).
#
# THE SEPARATOR IS RUNS OF 3+ SPACES, NOT TABS, and that is measured rather
# than assumed: the live registry format is TAB-separated, but every template
# row in the `.example` is SPACE-aligned (`grep -cP '\t'` on that file is 0).
# A tab-split predicate parses zero rows there and reports a clean file — which
# is what the first cut of this check did, and what its positive control caught.
# The struck-through negative example uses 2-space separation, so it is not a
# row by this predicate and cannot be pasted into a registry and work.
_reg_ex="$ROOT/monitor/services.registry.example"
if [[ -r "$_reg_ex" ]]; then
    _bad=$(sed 's/^#[[:space:]]\?//' "$_reg_ex" \
            | awk -F'[[:space:]]{3,}' 'NF >= 4 && $1 ~ /^[a-z][a-z0-9-]*$/ && $4 ~ /pgrep|(^|[^a-z])ps([[:space:]]|$)/ { print $1 ": " $4 }')
    _n_rows=$(sed 's/^#[[:space:]]\?//' "$_reg_ex" \
            | awk -F'[[:space:]]{3,}' 'NF >= 4 && $1 ~ /^[a-z][a-z0-9-]*$/' | wc -l)
    # POSITIVE CONTROL FIRST: the extractor must actually find rows. A predicate
    # that parses nothing reports zero offenders and reads exactly like a clean
    # file — this workspace dominant defect class, inside its own guard.
    if (( _n_rows >= 3 )); then
        printf '  PASS: the row extractor sees %d template rows (positive control)\n' "$_n_rows"; _th_pass
    else
        printf '  FAIL: row extractor found only %d rows — every assertion below would be vacuous\n' "$_n_rows" >&2
        _th_fail
    fi
    if [[ -z "$_bad" ]]; then
        printf '  PASS: no copyable example row carries a pgrep/ps healthcheck\n'; _th_pass
    else
        printf '  FAIL: a copyable example row prescribes an argv-shaped healthcheck:\n%s\n' "$_bad" >&2
        _th_fail
    fi
else
    printf '  FAIL: services.registry.example not readable at %s\n' "$_reg_ex" >&2; _th_fail
fi

# ---------------------------------------------------------------------------
# Assertion-count guard. The summary reports assertions that RAN; one that never
# ran is invisible to it (a typo'd helper is `command not found`, tallied by
# nothing, and the footer still says ALL TESTS PASSED with a quieter number).
# Every case here is unconditional, so the count is exact. Bump deliberately.
_EXPECTED_ASSERTIONS=39   # +2 (c) sibling-match exclusion + control, +2 #1222 example-row scan
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

echo
th_summary_and_exit
