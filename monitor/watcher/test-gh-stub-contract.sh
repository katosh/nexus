#!/usr/bin/env bash
# The `gh` test double answers as much as the real client does — the contract
# for _gh_stub.sh, and the guard that keeps hand-rolled stubs honest
# (your-org/nexus-code#932, #1125).
#
# Run: bash monitor/watcher/test-gh-stub-contract.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# ---------------------------------------------------------------------------
# WHY THIS SUITE EXISTS
# ---------------------------------------------------------------------------
#
# Two filed defects, one shape: A STUB THAT ACCEPTS A FLAG AND IGNORES IT. The
# call shape is right and the answer is unrelated to what was asked, so nothing
# errors and the suite goes green for a reason that has nothing to do with the
# property under test.
#
#   #932   `make_gh_stub` CAPTURES `--jq` into `jq_expr` and never APPLIES it.
#          The repo's run/job SELECTION lives entirely inside those
#          expressions. Restoring `.[0:8]` to `_merge_ref_base.sh`'s runs
#          `--jq` — byte-for-byte the diff that shipped as `#882` — left 95
#          assertions green across two suites.
#   #1125  the write arms return no body and the stub has no MEMORY, so "did
#          my write land?" is undecidable: `#1118` (accept, rc 0, print a URL,
#          change nothing) and a successful write produce the same response.
#
# ---------------------------------------------------------------------------
# WHAT IS ASSERTED, AND WHAT IS NOT
# ---------------------------------------------------------------------------
#
# BEHAVIOUR (§1, §4, §5): properties of `_gh_stub.sh`, exercised by running the
# generated stub for real. §5 is the one that carries weight — a read-back
# post-condition is written here and OBSERVED TO FAIL against two different
# swallowed-write modes. A check never seen to fail is not evidence, so the
# controls build the offending input, run the check, and watch it react.
#
# STRUCTURE (§2, §3): the tree-wide guard. Its predicate is deliberately the
# TIGHT one #932 argues for, not the broad one:
#
#     a stub that NAMES `--jq` in its argv walker — a `--jq)` arm, a
#     `== "--jq"` comparison, a `--jq=*` arm — proving its author knew the
#     flag exists and is reachable on this endpoint, AND never pipes a
#     captured expression through `jq`.
#
# NOT "the stub does not mention jq". Measured at `5bd6d400`: 40 files create a
# `gh` stub and only 4 name `--jq` at all. The other 36 legitimately pre-digest,
# because the verb they exercise passes no `--jq`; a guard that reddened on
# those would be suppressed and then deleted.
#
# THE RESIDUAL, STATED RATHER THAN HIDDEN. This predicate cannot see a stub
# that is blind because it never contemplated `--jq`, on an endpoint where the
# production code passes one. Deciding that mechanically needs a stub->callee
# map the repo does not have. The guard catches REGRESSION (a stub that knew
# and stopped applying) and not ORIGINAL OMISSION. That is strictly more than
# the zero enforced before it, and it is what would have reddened had `#903`'s
# stub been simplified back.
#
# THE RATCHET, and why it is a table rather than a red. Exactly one file was
# BLIND at `5bd6d400`: `monitor/watcher/_test_helpers.sh`, which was `#932`
# itself. A guard that is red on the day it lands gets suppressed, so the known
# member was RECORDED — and the record is checked in BOTH directions. A NEW
# blind file reds. A recorded file that stops being blind ALSO reds, so the row
# had to be deleted when `#932` landed rather than left to rot into a licence —
# and it was: `make_gh_stub` now DELEGATES to `ghs_make_stub` (W2-22), the
# shared builder carries no walker of its own, and the ratchet table is EMPTY.
# The two-way check stays, so the first file to go blind again lands RED.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

# ---------------------------------------------------------------------------
# THE PREDICATES, as data. One place, so the guard, the population and the
# positive controls cannot drift apart.
# ---------------------------------------------------------------------------

# APPLICABILITY, never conformance (your-org/nexus-code#1197): a file is in the
# population because it CREATES a gh test double, not because it currently
# passes. Keying on `--jq` here would make the population the set of
# already-compliant files, and a stub that stopped naming `--jq` would leave
# the population and DESELECT this guard — the narrowing no size bound can see.
_GHSG_STUBMAKER='make_gh_stub|ghs_make_stub|> *"?\$[A-Za-z_{}/]*/gh"?( |$)'

# AWARE — the author knew the flag exists. A `--jq` inside a COMMENT does not
# match, which is the point: two files in this tree mention `--jq` only in
# prose and are correctly out of scope.
_GHSG_AWARE='(^|[^-])--jq\)|[=!]= *"--jq"|--jq=\*'

# APPLIED — a `jq` invocation whose argument is a shell VARIABLE. The optional
# backslash is load-bearing: `test-ci-head-attempts.sh` builds its stub in an
# UNQUOTED heredoc, so the bytes on disk are `jq -r "\$mrb_jq"`. Without it
# that file classifies BLIND, and the guard's single most important true
# negative becomes a false positive.
_GHSG_APPLIED='jq +(-r +)?"\\?\$[A-Za-z_]'

# The sanctioned escape hatch #932 asks for, so a deliberate pre-digest is DATA
# rather than an absence.
_GHSG_OPTOUT='# jq-blind:'

_ghsg_population_files() {
    ( cd "$REPO_ROOT" && git ls-files -- monitor ) | while IFS= read -r f; do
        [ -f "$REPO_ROOT/$f" ] || continue
        if grep -qE "$_GHSG_STUBMAKER" "$REPO_ROOT/$f" 2>/dev/null; then
            printf '%s\n' "$f"
        fi
    done
}

# _ghsg_classify <absolute-path> -> OK | BLIND | EXEMPT | NA
_ghsg_classify() {
    local f="$1"
    grep -qE "$_GHSG_AWARE" "$f" 2>/dev/null || { printf 'NA\n'; return 0; }
    if grep -qE "$_GHSG_APPLIED" "$f" 2>/dev/null; then printf 'OK\n'; return 0; fi
    if grep -qF "$_GHSG_OPTOUT" "$f" 2>/dev/null; then printf 'EXEMPT\n'; return 0; fi
    printf 'BLIND\n'
}

. "$_test_dir/../_guard_population.sh"
gp_population() {
    _ghsg_population_files
    printf '%s\n' \
        'monitor/watcher/_gh_stub.sh' \
        'monitor/watcher/_test_helpers.sh'
}
gp_handle "$@"

. "$_test_dir/_test_helpers.sh"
. "$_test_dir/_gh_stub.sh"

EXPECTED_ASSERTIONS=51   # counted BEFORE the census assertion itself

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s (got %q)\n' "$label" "$got"; _th_pass
    else printf '  FAIL: %s — got %q, want %q\n' "$label" "$got" "$want" >&2; _th_fail; fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ghstub.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

if ! command -v jq >/dev/null 2>&1; then
    printf 'ENV-FAIL: jq is not on PATH; this suite is ABOUT jq evaluation and cannot\n' >&2
    printf '          be run without it. Refusing rather than skipping: a SKIP here\n' >&2
    printf '          would read as "the property holds", which is the defect class\n' >&2
    printf '          this whole suite is about.\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# THE FIXTURE. Ten runs, so a `.[0:8]` slice — the exact `#882` mutation — is
# EXPRESSIBLE. A fixture with eight or fewer runs cannot tell an applied slice
# from an ignored one, and that indistinguishability is `#932` in miniature.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin"
ghs_make_stub "$WORK/bin/gh" "$WORK/calls.txt" --state-dir "$WORK/state" <<'CASES'
    */actions/runs*)
        ghs_emit <<'JSON'
{"total_count":10,"workflow_runs":[
 {"id":101,"event":"pull_request","conclusion":"success"},
 {"id":102,"event":"pull_request","conclusion":"success"},
 {"id":103,"event":"pull_request","conclusion":"success"},
 {"id":104,"event":"pull_request","conclusion":"success"},
 {"id":105,"event":"pull_request","conclusion":"success"},
 {"id":106,"event":"pull_request","conclusion":"success"},
 {"id":107,"event":"pull_request","conclusion":"success"},
 {"id":108,"event":"pull_request","conclusion":"success"},
 {"id":109,"event":"pull_request","conclusion":"success"},
 {"id":110,"event":"pull_request","conclusion":"success"}]}
JSON
        ;;
    */dashboard)  ghs_emit <<< '{"body":"OLD BODY"}' ;;
    *)            ghs_emit <<< '{}' ;;
CASES
GHPATH="$WORK/bin:$PATH"

echo '=== 1. #932 — the stub APPLIES the caller`s --jq, and a SLICE selects ==='

n_all=$(PATH="$GHPATH" gh api "/repos/o/r/actions/runs?head_sha=x" \
        --jq '[.workflow_runs[] | select(.event=="pull_request" and .conclusion=="success") | .id] | length')
assert_eq "the unsliced expression reads all ten runs" "$n_all" "10"

# THE #882 MUTATION, EXPRESSED IN THE CALLER'S OWN --jq. This is the assertion
# a pre-digesting stub cannot make: it would answer 10 to both, because the
# expression never runs and the digest is fixed.
n_cut=$(PATH="$GHPATH" gh api "/repos/o/r/actions/runs?head_sha=x" \
        --jq '[.workflow_runs[] | select(.event=="pull_request" and .conclusion=="success") | .id] | .[0:8] | length')
assert_eq "…and a .[0:8] window selects EIGHT — the expression really evaluates" "$n_cut" "8"
assert_eq "…so the two expressions DISAGREE, which is the whole property" \
    "$([[ "$n_all" != "$n_cut" ]] && echo differ || echo same)" "differ"

raw=$(PATH="$GHPATH" gh api "/repos/o/r/actions/runs?head_sha=x")
assert_eq "with NO --jq the stub serves GitHub-SHAPED JSON, not a digest" \
    "$(printf '%s' "$raw" | grep -c '"workflow_runs"')" "1"

# A scalar `--jq` on a header field: the discriminator shape `#823` and `#882`
# both rely on, and the one a digest most easily fakes.
assert_eq "a scalar --jq reads the header field" \
    "$(PATH="$GHPATH" gh api "/repos/o/r/actions/runs?head_sha=x" --jq '.total_count')" "10"

echo '=== 2. #932 GUARD — the tree, classified, against a two-way ratchet ==='

# EMPTY since #932 landed (W2-22): `_test_helpers.sh` was the one recorded
# blind file, and its `make_gh_stub` now delegates to `ghs_make_stub`. A row
# added here is a licence with a reason; a file that goes blind with no row
# reds in §2 by name. Whitespace-separated paths if one ever has to return.
_GHSG_RATCHET=''

pop=$(_ghsg_population_files)
pop_n=$(printf '%s\n' "$pop" | grep -c . || true)
assert_eq "the population is non-vacuous (>= 25 stub-creating files)" \
    "$([[ "$pop_n" -ge 25 ]] && echo yes || echo no)" "yes"

blind_list=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [[ "$(_ghsg_classify "$REPO_ROOT/$f")" == "BLIND" ]] && blind_list="$blind_list$f"$'\n'
done <<< "$pop"
blind_list=$(printf '%s' "$blind_list" | sort)

assert_eq "no jq-AWARE stub is blind except the recorded ones (the ratchet is EMPTY since #932)" \
    "$blind_list" "$( [[ -n "$_GHSG_RATCHET" ]] && printf '%s\n' $_GHSG_RATCHET | sort || printf '' )"
# THE OTHER DIRECTION OF THE RATCHET, kept live on the file that used to be its
# only row: the shared builder must NOT be blind any more — and must not be
# absent from the population either, which would be the #1197 narrowing (a
# fixed file leaving the set it was ratcheted in).
assert_eq "the shared builder _test_helpers.sh is no longer BLIND (its walker is gone — it delegates; #932)" \
    "$(_ghsg_classify "$REPO_ROOT/monitor/watcher/_test_helpers.sh")" "NA"
assert_eq "…and it is STILL in the population (it creates stubs by delegation; no #1197 narrowing)" \
    "$(printf '%s\n' "$pop" | grep -cx 'monitor/watcher/_test_helpers.sh')" "1"
assert_eq "…and the library it delegates to applies the expression (OK)" \
    "$(_ghsg_classify "$REPO_ROOT/monitor/watcher/_gh_stub.sh")" "OK"

# THE OTHER DIRECTION. A recorded file that has been FIXED must lose its row,
# or the ratchet stops describing the tree.
for r in $_GHSG_RATCHET; do
    assert_eq "the recorded file $r still EXISTS" \
        "$([[ -f "$REPO_ROOT/$r" ]] && echo yes || echo no)" "yes"
    assert_eq "…and is still BLIND — delete its row when #932 lands" \
        "$(_ghsg_classify "$REPO_ROOT/$r")" "BLIND"
done

# The true negatives, named. These are the three files that PROVE the predicate
# is not simply "nobody applies jq" — if the classifier broke open, they would
# join the blind list and §2's set comparison would red on them by name.
for good in monitor/watcher/test-merge-ref-base.sh \
            monitor/test-ci-head-attempts.sh \
            monitor/test-ci-trigger-audit.sh; do
    assert_eq "$good applies the caller's --jq (a true NEGATIVE, not an absence)" \
        "$(_ghsg_classify "$REPO_ROOT/$good")" "OK"
done

echo '=== 3. #932 GUARD positive controls — the instrument sees a PRESENCE ==='

# An absence is worthless without proof the instrument could have seen a
# presence. Three planted files, one per verdict, each the MINIMAL expression
# of its case.
mkdir -p "$WORK/plant"
cat > "$WORK/plant/blind.sh" <<'PLANT'
cat > "$D/gh" <<'S'
while (( $# > 0 )); do case "$1" in --jq) jq_expr="$2"; shift 2 ;; *) shift ;; esac; done
printf '{}'
S
PLANT
cat > "$WORK/plant/applying.sh" <<'PLANT'
cat > "$D/gh" <<'S'
while (( $# > 0 )); do case "$1" in --jq) jq_expr="$2"; shift 2 ;; *) shift ;; esac; done
printf '{}' | jq -r "$jq_expr"
S
PLANT
cat > "$WORK/plant/exempt.sh" <<'PLANT'
# jq-blind: this endpoint's caller passes no --jq; the digest IS the answer
cat > "$D/gh" <<'S'
while (( $# > 0 )); do case "$1" in --jq) jq_expr="$2"; shift 2 ;; *) shift ;; esac; done
printf '{}'
S
PLANT
cat > "$WORK/plant/unaware.sh" <<'PLANT'
cat > "$D/gh" <<'S'
while (( $# > 0 )); do case "$1" in -*) shift ;; *) shift ;; esac; done
printf '{}'
S
PLANT

assert_eq "PLANT: a stub that captures --jq and never applies it is BLIND" \
    "$(_ghsg_classify "$WORK/plant/blind.sh")" "BLIND"
assert_eq "PLANT: the same stub piping through jq is OK" \
    "$(_ghsg_classify "$WORK/plant/applying.sh")" "OK"
assert_eq "PLANT: the '# jq-blind:' marker converts the red into recorded DATA" \
    "$(_ghsg_classify "$WORK/plant/exempt.sh")" "EXEMPT"
assert_eq "PLANT: a stub that never names --jq is out of scope (the stated residual)" \
    "$(_ghsg_classify "$WORK/plant/unaware.sh")" "NA"
assert_eq "PLANT: all four plants are visible to the STUB-MAKER predicate" \
    "$(grep -lE "$_GHSG_STUBMAKER" "$WORK"/plant/*.sh | wc -l)" "4"

echo '=== 4. #1125 — the write is REMEMBERED, so a read-back can see it ==='

NEW='{"body":"NEW BODY"}'
patch_resp=$(printf '%s' "$NEW" | PATH="$GHPATH" gh api -X PATCH /repos/o/r/dashboard --input - --jq '.body')
assert_eq "PATCH echoes the request back, the way the API does" "$patch_resp" "NEW BODY"
assert_eq "…and a SUBSEQUENT GET serves what was written, not the canned body" \
    "$(PATH="$GHPATH" gh api /repos/o/r/dashboard --jq '.body')" "NEW BODY"

echo '=== 5. #1125 NEGATIVE CONTROL — a read-back post-condition, FAILING ==='

# The check under test: EXACTLY the fix #1118 wants. Write, then FETCH, then
# compare. Written here rather than imported so the control is self-contained
# and so what is being observed to fail is visible at the point of the claim.
verify_write() {
    local ep="$1" want="$2"
    printf '{"body":"%s"}' "$want" | PATH="$GHPATH" gh api -X PATCH "$ep" --input - >/dev/null 2>&1
    local back
    back=$(PATH="$GHPATH" gh api "$ep" --jq '.body' 2>/dev/null)
    [[ "$back" == "$want" ]]
}

rm -rf "$WORK/state"
verify_write /repos/o/r/dashboard 'ROUND TRIP'; rc_honest=$?
assert_eq "the read-back PASSES against an honest stub (rc 0)" "$rc_honest" "0"

# CONTROL A — the #1118 failure verbatim: accepted, rc 0, nothing changed.
rm -rf "$WORK/state"
( export GHS_MODE=swallow; verify_write /repos/o/r/dashboard 'ROUND TRIP' ); rc_swallow=$?
assert_eq "…and FAILS CLOSED when the write is swallowed (#1118)" \
    "$([[ "$rc_swallow" -ne 0 ]] && echo failed-closed || echo passed-anyway)" "failed-closed"

# CONTROL B — the NASTIER swallow, and the reason A alone is not enough. The
# PATCH response is byte-identical to a successful one; only the separate GET
# separates them. A "verification" that reads its own write's response passes
# here and is still broken.
rm -rf "$WORK/state"
( export GHS_MODE=swallow-echo; verify_write /repos/o/r/dashboard 'ROUND TRIP' ); rc_echo=$?
assert_eq "…and FAILS CLOSED when the swallowed write ECHOES a perfect response" \
    "$([[ "$rc_echo" -ne 0 ]] && echo failed-closed || echo passed-anyway)" "failed-closed"

# CONTROL C — the WRONG check, shown to be wrong. Reading the PATCH's own
# response is the verification an author reaches for first, and it is exactly
# what swallow-echo defeats. Asserting that it PASSES here is what makes
# Control B's failure attributable to the read-back rather than to the mode.
rm -rf "$WORK/state"
echo_resp=$(printf '{"body":"ROUND TRIP"}' | \
    GHS_MODE=swallow-echo PATH="$GHPATH" gh api -X PATCH /repos/o/r/dashboard --input - --jq '.body' 2>/dev/null)
assert_eq "the WRONG check — trusting the PATCH response — is fooled by swallow-echo" \
    "$echo_resp" "ROUND TRIP"
assert_eq "…while the resource itself is still OLD, which is what makes it wrong" \
    "$(GHS_MODE=swallow-echo PATH="$GHPATH" gh api /repos/o/r/dashboard --jq '.body' 2>/dev/null)" \
    "OLD BODY"

# CONTROL D — the endpoint filter, so a suite can swallow ONE write in a
# sequence. Without it "the read-back failed" could mean "every write in this
# fixture is disabled", which is a weaker claim than the one being made.
rm -rf "$WORK/state"
( export GHS_MODE=swallow GHS_SWALLOW_ENDPOINT='*/other'
  verify_write /repos/o/r/dashboard 'ROUND TRIP' ); rc_narrow=$?
assert_eq "a swallow narrowed to ANOTHER endpoint leaves this write landing" "$rc_narrow" "0"

echo '=== 6. the refusal — a missing jq is never a silent pass-through ==='

# Degrading to `cat` when jq is absent would restore pre-digested behaviour
# exactly, and the suite would go green for the reason this file exists to
# catch. Asserted by running the stub with an empty PATH.
# A PATH holding everything the stub needs AND NOT jq. Symlinks rather than an
# empty PATH: an empty one makes the stub die at rc 127 on its own shebang,
# which is a DIFFERENT failure that would pass an `rc != 0` assertion for the
# wrong reason — the control has to isolate the jq axis and nothing else.
rm -rf "$WORK/state"
mkdir -p "$WORK/nojq/bin"
for _t in bash cat od tr mkdir sed; do
    _p=$(command -v "$_t" 2>/dev/null) && ln -sf "$_p" "$WORK/nojq/bin/$_t"
done
cp "$WORK/bin/gh" "$WORK/nojq/gh"
assert_eq "the jq-free PATH can still run the stub at all (isolating the axis)" \
    "$(PATH="$WORK/nojq/bin" "$WORK/nojq/gh" api /repos/o/r/dashboard 2>/dev/null)" \
    '{"body":"OLD BODY"}'
nojq_rc=0
PATH="$WORK/nojq/bin" "$WORK/nojq/gh" api /repos/o/r/dashboard --jq '.body' >/dev/null 2>&1 || nojq_rc=$?
assert_eq "with --jq passed and jq unreachable the stub REFUSES (rc 3)" "$nojq_rc" "3"

# THE SECOND ROUTE, AND IT IS THE ONE THAT MATTERS. A stored body is served
# through a PIPELINE (`printf | ghs_emit`), and a refusal on a pipeline's
# right-hand side dies with the subshell — the stub's own status then comes
# from the `exit 0` below it. So a guard placed only inside `ghs_emit` is
# unreachable on exactly this route. MEASURED: with the library's TOP-LEVEL
# refusal deleted, this suite stayed GREEN at 28/0 until this assertion
# existed, because the CASES arm happens to call `ghs_emit` outside a pipeline.
# The check that could not fail was not protection.
printf '{"body":"STORED"}' | PATH="$GHPATH" gh api -X PATCH /repos/o/r/dashboard --input - >/dev/null 2>&1
nojq_stored_rc=0
PATH="$WORK/nojq/bin" "$WORK/nojq/gh" api /repos/o/r/dashboard --jq '.body' >/dev/null 2>&1 || nojq_stored_rc=$?
assert_eq "…and REFUSES on the STORED-body route too, which is a PIPELINE" "$nojq_stored_rc" "3"

echo '=== 7. #1125 — a write with NO BODY records NOTHING, and a DELETE forgets ==='

# THE EMPTY-RECORD POISONING. `-f`/`-F` fields are consumed by the argv walker
# and never reach $GHS_BODY; a DELETE has no body at all. Both used to write a
# 0-byte record that a presence-gated `ghs_stored` then served, so EVERY later
# GET on that endpoint answered empty at rc 0 — the confident-empty class, inside
# the library built to make read-backs decidable. Ordinary `ng` call shapes.
rm -rf "$WORK/state"
f_rc=0
PATH="$GHPATH" gh api -X PATCH /repos/o/r/dashboard -f state=closed >/dev/null 2>&1 || f_rc=$?
assert_eq "a -f field write is accepted (rc 0)" "$f_rc" "0"
assert_eq "…and a later GET serves the CANNED body, not an empty record" \
    "$(PATH="$GHPATH" gh api /repos/o/r/dashboard 2>/dev/null)" '{"body":"OLD BODY"}'
assert_eq "…because NOTHING was recorded (no 0-byte file in the store)" \
    "$(find "$WORK/state" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
printf '{"body":"KEPT"}' | PATH="$GHPATH" gh api -X PATCH /repos/o/r/dashboard --input - >/dev/null 2>&1
assert_eq "CONTROL: a write WITH a body is still recorded and served" \
    "$(PATH="$GHPATH" gh api /repos/o/r/dashboard --jq '.body' 2>/dev/null)" "KEPT"
d_rc=0; d_out=$(PATH="$GHPATH" gh api -X DELETE /repos/o/r/dashboard 2>/dev/null) || d_rc=$?
assert_eq "a DELETE is accepted (rc 0) with an EMPTY body — the API's 204" "$d_rc:$d_out" "0:"
assert_eq "…and the record is GONE: the next GET falls through to the CASES" \
    "$(PATH="$GHPATH" gh api /repos/o/r/dashboard --jq '.body' 2>/dev/null)" "OLD BODY"
assert_eq "…with nothing left in the store" \
    "$(find "$WORK/state" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
# The swallow mode still swallows a DELETE: nothing forgotten, old body stands.
printf '{"body":"STANDS"}' | PATH="$GHPATH" gh api -X PATCH /repos/o/r/dashboard --input - >/dev/null 2>&1
GHS_MODE=swallow PATH="$GHPATH" gh api -X DELETE /repos/o/r/dashboard >/dev/null 2>&1
assert_eq "under GHS_MODE=swallow a DELETE is accepted and forgets NOTHING" \
    "$(PATH="$GHPATH" gh api /repos/o/r/dashboard --jq '.body' 2>/dev/null)" "STANDS"

echo '=== 8. a jq FAILURE is as loud as a jq ABSENCE — never stdout=[] rc=0 ==='

# The residual both issues left open: `ghs_emit` refused when jq was ABSENT and
# stayed silent when jq FAILED. Measured before this section existed: a
# non-JSON arm behind `--jq` answered `stdout=[] rc=0` with the parse error on
# a stderr every production call site discards. Now it is rc 3 on BOTH routes
# — the CASES arm and the stored-body PIPELINE — with a diagnostic naming the
# expression, and a valid-JSON arm beside it still answers.
rm -rf "$WORK/state"
ghs_make_stub "$WORK/bin2/gh" "$WORK/calls2.txt" --state-dir "$WORK/state2" <<'CASES'
    */plain)     ghs_emit <<< 'not json at all' ;;
    */dashboard) ghs_emit <<< '{"body":"OLD BODY"}' ;;
    *)           ghs_emit <<< '{}' ;;
CASES
G2="$WORK/bin2/gh"
nj_rc=0; nj_out=$("$G2" api /repos/o/r/plain --jq '.x' 2>"$WORK/nj.err") || nj_rc=$?
assert_eq "a NON-JSON arm behind --jq is rc 3 with EMPTY stdout (the CASES route)" "$nj_rc:$nj_out" "3:"
assert_eq "…and the diagnostic names the expression and the defect" \
    "$(grep -c -- '--jq .x was passed but the arm served NON-JSON' "$WORK/nj.err")" "1"
be_rc=0; be_out=$("$G2" api /repos/o/r/dashboard --jq '.body |' 2>"$WORK/be.err") || be_rc=$?
assert_eq "a BAD EXPRESSION on valid JSON is rc 3 with empty stdout, not a silent []" "$be_rc:$be_out" "3:"
assert_eq "…and the diagnostic carries jq's own error" \
    "$(grep -c 'FAILED on the arm output: jq: error' "$WORK/be.err")" "1"
pc_rc=0; pc_out=$("$G2" api /repos/o/r/dashboard --jq '.body' 2>/dev/null) || pc_rc=$?
assert_eq "POSITIVE CONTROL: a valid-JSON arm with --jq still answers (rc 0)" "$pc_rc:$pc_out" "0:OLD BODY"
# THE STORED-BODY ROUTE IS A PIPELINE (`printf | ghs_emit`), so the refusal
# cannot exit the stub by itself — it signals the top level. Record NON-JSON
# through `--input -` and read it back through `--jq`.
printf 'raw text' | "$G2" api -X PATCH /repos/o/r/dashboard --input - >/dev/null 2>&1
sb_rc=0; sb_out=$("$G2" api /repos/o/r/dashboard --jq '.body' 2>"$WORK/sb.err") || sb_rc=$?
assert_eq "…and on the STORED-body PIPELINE route the failure is rc 3 too, stdout empty" "$sb_rc:$sb_out" "3:"
assert_eq "…with the same diagnostic" \
    "$(grep -c 'served NON-JSON' "$WORK/sb.err")" "1"

echo '=== 9. #932 — make_gh_stub DELEGATES: behaviour-preserving for its callers ==='

# The shared builder is one line over `ghs_make_stub --no-autostate`. What its
# 10 pre-digesting callers relied on must hold: the state layer is OFF (a PATCH
# then GET serves the CASES, never a recorded body), `--with-body-capture`
# captures on `--input -` and TRUNCATES on a bodyless call, a bodyless GET
# never touches an open stdin (#921) — and what they GAIN: an arm that calls
# `ghs_emit` has the caller's --jq evaluated, so the #882 slice is expressible.
make_gh_stub "$WORK/bin3/gh" "$WORK/calls3.txt" --with-body-capture "$WORK/body3" <<'CASES'
    */runs*)      ghs_emit <<< '{"workflow_runs":[1,2,3,4,5,6,7,8,9,10]}' ;;
    */dashboard)  printf '%s' '{"body":"CANNED"}' ;;
    *)            printf '{}' ;;
CASES
G3="$WORK/bin3/gh"
assert_eq "the delegated stub pins the state layer OFF in the file (GHS_NO_AUTOSTATE=1, by construction)" \
    "$(grep -cx 'GHS_NO_AUTOSTATE=1' "$G3")" "1"
printf '{"body":"X"}' | "$G3" api -X PATCH /repos/o/r/dashboard --input - >/dev/null 2>&1
assert_eq "…--with-body-capture captured the piped body" "$(cat "$WORK/body3")" '{"body":"X"}'
assert_eq "…and a GET after the PATCH serves the CASES arm (no autostate for delegated callers)" \
    "$("$G3" api /repos/o/r/dashboard </dev/null 2>/dev/null)" '{"body":"CANNED"}'
assert_eq "…which TRUNCATED the capture (a bodyless call records 'no body')" "$(cat "$WORK/body3")" ""
assert_eq "…the caller's --jq is EVALUATED on a ghs_emit arm: unsliced" \
    "$("$G3" api /repos/o/r/actions/runs --jq '.workflow_runs|length' </dev/null 2>/dev/null)" "10"
assert_eq "…and the #882 slice selects EIGHT through the shared builder" \
    "$("$G3" api /repos/o/r/actions/runs --jq '.workflow_runs|.[0:8]|length' </dev/null 2>/dev/null)" "8"
timeout 10 "$G3" api /repos/o/r/dashboard < <(sleep 30) >/dev/null 2>&1; os_rc=$?
assert_eq "…and a bodyless GET does not block on an open stdin (#921 preserved)" "$os_rc" "0"

# ASSERTION CENSUS — the exact-count guard that makes this suite's green mean
# something, and the reason summary-honesty.manifest carries no row for it. A
# vanished assertion reddens here rather than shrinking the total in silence.
_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
if [[ "$_total" == "$EXPECTED_ASSERTIONS" ]]; then
    printf '  PASS: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS" >&2; _th_fail
fi

th_summary_and_exit
