#!/usr/bin/env bash
# test-merge-ref-base.sh — the merge-ref base check (your-org/nexus-code#823).
#
# WHAT IS BEING GUARDED. A `pull_request` run does not test your branch: it
# tests `refs/pull/N/merge`, a merge commit GitHub computes AT RUN CREATION. If
# the base branch moves afterwards, every green stays green while describing a
# tree that no longer exists. `#823` merged on exactly that, and the enumeration
# that cleared it was correct about everything it checked — which is the point:
# the recipe checked WHICH runs and WHAT conclusions, and never AGAINST WHAT
# BASE.
#
# WHY THIS SUITE EXISTS SEPARATELY FROM test-ci-head-attempts.sh. The arm that
# matters is STALE, and no live PR can be made to demonstrate it on demand — a
# base moves when it moves. So the answer has to be reachable from a fixture,
# which is why `_merge_ref_base` is a sourced library rather than an inline
# function. Every case below drives the REAL function; nothing is reimplemented.
#
# EVERY ASSERTION MATCHES THE STATE AND THE SENTENCE, not merely one of them. A
# state with a wrong detail line is a check that fired for a reason the reader
# cannot verify.
#
# Run: bash monitor/watcher/test-merge-ref-base.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
LIB="$REPO_ROOT/monitor/_merge_ref_base.sh"

. "$_test_dir/_test_helpers.sh"

[[ -r "$LIB" ]] || { echo "FAIL: missing $LIB" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

BASE_A=1111111111111111111111111111111111111111
BASE_B=2222222222222222222222222222222222222222
HEAD_S=3333333333333333333333333333333333333333

# ---- the gh stub — REAL PAYLOADS, REAL `--jq` -----------------------------
#
# THE STUB EVALUATES `--jq`, AND THAT IS THE WHOLE POINT (your-org/nexus-code#882
# S1, observer finding). The previous stubs returned PRE-DIGESTED lines — a bare
# base ref, a bare list of run ids — and ignored the `--jq` expression entirely.
# The run SELECTION lives in that expression. So the suite was structurally blind
# to the layer the defect lives in: restoring `.[0:8]` in the jq, byte-for-byte
# the diff that shipped as S1, left every assertion green. The fix was correct
# and completely unguarded.
#
# An observer that cannot observe its own predicate is this repo's dominant
# defect class, and this is it inside the guard for the merge gate. So: the stub
# serves GitHub-shaped JSON and pipes it through REAL `jq` with the REAL
# expression the library passed. Case 18 mutates `.[0:8]` back into that
# expression and requires the suite to go red.
#
# Per-case inputs arrive as files so a case cannot silently reuse the previous
# case's answers. Job id == run id, so one log fixture per run is expressible.
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

# The `--jq` expression the CALLER actually passed. Applied for real below.
jqx=""; prev=""
for a in "$@"; do [[ "$prev" == "--jq" ]] && jqx="$a"; prev="$a"; done
emit() { if [[ -n "$jqx" ]]; then jq -r "$jqx"; else cat; fi; }

ids_file="${STUB_RUN_IDS:-/dev/null}"
n_ids=0
# `|| [[ -n "$_i" ]]` — a fixture written with `printf '%s'` has NO trailing
# newline, and a bare `while read` silently DROPS that last line. That is a
# silent-undercount inside a stub whose whole job is to serve a population.
while IFS= read -r _i || [[ -n "$_i" ]]; do [[ -n "$_i" ]] && n_ids=$(( n_ids + 1 )); done < "$ids_file"

runs_json() {
    local first=1 id
    printf '{"total_count":%s,"workflow_runs":[' "${STUB_TOTALCOUNT:-$n_ids}"
    while IFS= read -r id || [[ -n "$id" ]]; do
        [[ -n "$id" ]] || continue
        (( first )) || printf ','
        first=0
        printf '{"id":%s,"event":"pull_request","conclusion":"success"}' "$id"
    done < "$ids_file"
    printf ']}'
}

args="$*"
case "$args" in
  *"/actions/runs?head_sha="*) runs_json | emit ;;
  *"/actions/runs/"*"/jobs"*)
        # Job id == run id: one log fixture per run, which is what every
        # multi-run case needs.
        rid=$(sed 's#.*/actions/runs/##; s#/jobs.*##' <<<"$args" | awk '{print $1}')
        # STUB_JOBS_PER_RUN>1 emits N successful jobs for the run: `<rid>` first,
        # then `<rid>02`, `<rid>03`, … Only the LAST is given a log fixture by
        # the case, which is what makes a JOB-side cap observable at all — with
        # `.[0:6]` restored the scan never reaches it and the run yields nothing.
        _n="${STUB_JOBS_PER_RUN:-1}"; _k=2; _jobs="{\"id\":$rid,\"conclusion\":\"success\"}"
        while (( _k <= _n )); do _jobs="$_jobs,{\"id\":${rid}0$_k,\"conclusion\":\"success\"}"; _k=$(( _k + 1 )); done
        printf '{"total_count":%s,"jobs":[%s]}' "${STUB_JOBS_TOTALCOUNT:-$_n}" "$_jobs" | emit ;;
  *"/actions/jobs/"*"/logs"*)
        # Logs are plain text, not JSON, and carry no --jq.
        jid=$(sed 's#.*/actions/jobs/##; s#/logs.*##' <<<"$args" | awk '{print $1}')
        if [[ -n "${STUB_LOG_DIR:-}" && -r "$STUB_LOG_DIR/$jid.txt" ]]; then
            cat "$STUB_LOG_DIR/$jid.txt"
        else
            cat "${STUB_LOG:-/dev/null}"
        fi ;;
  # The PR object serves only the base BRANCH NAME. The tip comes from the ref.
  *"/pulls/"*)             printf '{"base":{"ref":"dev"}}' | emit ;;
  *"/git/ref/heads/"*)
        sha=$(cat "${STUB_BASE_SHA:-/dev/null}" 2>/dev/null)
        # An EMPTY fixture models an unreadable tip: `.object.sha // ""` yields
        # "" and the library must refuse rather than compare against nothing.
        if [[ -n "$sha" ]]; then printf '{"object":{"sha":"%s"}}' "$sha" | emit
        else printf '{"object":{}}' | emit; fi ;;
  *) exit 1 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/gh"
mkdir -p "$WORK/logs"

# `probe <base-sha> <run-ids> <ignored> <log-body>` — runs the REAL library in a
# subshell with the stub on PATH, and echoes `<state>|<detail>`. The third
# parameter is vestigial (job ids are derived from run ids now) and is kept so
# the call sites below read unchanged.
probe() {
    printf '%s' "$1" > "$WORK/base"; printf '%s' "$2" > "$WORK/runs"
    printf '%s' "$4" > "$WORK/log"
    rm -f "$WORK"/logs/*.txt
    PATH="$WORK/bin:$PATH" \
    STUB_BASE_SHA="$WORK/base" STUB_RUN_IDS="$WORK/runs" STUB_LOG="$WORK/log" \
    bash -c '
        set -uo pipefail
        REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
        . "'"$LIB"'"
        _merge_ref_base
        printf "%s|%s\n" "$_MRB_STATE" "$_MRB_DETAIL"
    '
}

CHECKOUT_A="2026-08-08T12:31:26.9Z HEAD is now at ec3412f Merge $HEAD_S into $BASE_A"

echo "=== 1. CURRENT — the run tested the base that is the tip now ==="
got=$(probe "$BASE_A" "9001" "8001" "$CHECKOUT_A")
assert_eq "a run whose merge ref names the current base is 'current'" \
    "${got%%|*}" "current"
assert_contains "…and the detail names the run, the base it tested, and that the tip was READ" \
    "$got" "run 9001 tested against ${BASE_A:0:12}, which EQUALS the live tip"

echo "=== 2. STALE — the base moved after the run was created ==="
# The arm the whole check exists for, and the one no live PR demonstrates on
# demand: same run, same log, base tip now something else.
got=$(probe "$BASE_B" "9001" "8001" "$CHECKOUT_A")
assert_eq "a run whose merge ref names an OLD base is 'stale'" \
    "${got%%|*}" "stale"
assert_contains "…and the detail names BOTH shas, so the reader can see the gap" \
    "$got" "tested against ${BASE_A:0:12}; the live tip of dev is now ${BASE_B:0:12}"

echo "=== 3. UNREAD is its own state, never folded into either answer ==="
# GitHub expires logs, so 'could not read it' is an ordinary state. It must not
# read as 'current' (a base nobody verified is not a verified base) and must not
# block (that would break the verb on every older head).
got=$(probe "$BASE_A" "9001" "8001" "a log with no checkout line at all")
assert_eq "a log carrying no merge line is 'unread', not 'current'" \
    "${got%%|*}" "unread"
assert_contains "…and says what was looked at" "$got" "logs expired"

got=$(probe "$BASE_A" "" "8001" "$CHECKOUT_A")
assert_eq "no successful pull_request run at this head → 'unread'" \
    "${got%%|*}" "unread"
assert_contains "…and says so in those terms" "$got" "no successful pull_request run"

got=$(probe "" "9001" "8001" "$CHECKOUT_A")
assert_eq "an unreadable base sha → 'unread', never a comparison against nothing" \
    "${got%%|*}" "unread"
# THE DEFECT THIS CHECK SHIPPED WITH, pinned so it cannot come back. The first
# cut read the PR object's `.base.sha` — a FROZEN SNAPSHOT that GitHub does not
# advance as the base moves. Run against `#823`, the incident this check is
# named after, it returned `current`.
# The GROUNDS stated here originally were wrong in the direction that
# understates the hazard, and are corrected with the rest (#837 logic review):
# `.base.sha` and `refs/pull/N/merge` do NOT "move together" — they are
# INDEPENDENT freezes on distinct triggers. Measured: `#670` they agree
# (f0c9510/f0c9510); `#811` they diverge (1973ffc vs a91f82b, after one
# `GET /pulls/811` refreshed the ref and left `.base.sha` behind). So the
# snapshot is UNCORRELATED with the question and errs BOTH ways — false-current
# on the `#670` shape (the unsafe direction, the `#823` failure) and false-stale
# on the `#811` shape.
# So the live-tip read must never fall back to the snapshot. Not because such a
# comparison cannot fail, but because it can fail WRONGLY IN EITHER DIRECTION —
# a verdict over something unmeasured, which is worse than no verdict.
assert_contains "…and says it REFUSED to fall back to the frozen .base.sha" \
    "$got" "refusing to fall back"

echo "=== 4. N/A — a bare sha has no merge ref, and that is not 'unread' ==="
got=$(PATH="$WORK/bin:$PATH" bash -c '
    set -uo pipefail
    REPO=owner/repo; PR_NUM=""; SHA='"$HEAD_S"'
    . "'"$LIB"'"
    _merge_ref_base
    printf "%s|%s\n" "$_MRB_STATE" "$_MRB_DETAIL"')
assert_eq "no PR context is 'n/a' — a distinct answer, not a failure to look" \
    "${got%%|*}" "n/a"

echo "=== 5. THE SCAN REACHES PAST A RUN THAT CHECKED OUT NO MERGE REF ==="
# Measured on `#823`: three of its successful runs check out
# `refs/remotes/origin/dev` directly and print no merge line, while the round
# that actually ran the tests prints it. A scan that reads only the first run
# reports 'unread' on the very head this check exists for — an "I looked in the
# wrong place" dressed as "it cannot be known".
# Expressed as PER-RUN LOG FIXTURES against the shared jq-evaluating stub:
# run 9001's job checked out a branch and prints no merge line; run 9002's does.
printf '%s' "$BASE_A" > "$WORK/base"
printf '9001\n9002\n' > "$WORK/runs"
rm -f "$WORK"/logs/*.txt
printf 'HEAD is now at abc1234 dev branch checkout\n' > "$WORK/logs/9001.txt"
printf '%s\n' "$CHECKOUT_A" > "$WORK/logs/9002.txt"
got=$(PATH="$WORK/bin:$PATH" STUB_BASE_SHA="$WORK/base" STUB_RUN_IDS="$WORK/runs" \
      STUB_LOG_DIR="$WORK/logs" bash -c '
    set -uo pipefail
    REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
    . "'"$LIB"'"
    _merge_ref_base
    printf "%s|%s\n" "$_MRB_STATE" "$_MRB_DETAIL"')
assert_eq "a first run with no merge line does not stop the scan" \
    "${got%%|*}" "current"
assert_contains "…and the answer names the run it actually came from" \
    "$got" "run 9002"

echo "=== 6. NEGATIVE CONTROL: without the comparison, STALE reads as CURRENT ==="
# The library, mutated on a copy so the equality test always holds. If case 2
# still passed against this, it would be asserting a wording rather than the
# comparison.
sed 's/if \[\[ "\$tested" == "\$base_sha" \]\]; then/if true; then  # NEGATIVE-CONTROL MUTANT (#823)/' \
    "$LIB" > "$WORK/mutant.sh"
if ! grep -q 'NEGATIVE-CONTROL MUTANT (#823)' "$WORK/mutant.sh"; then
    printf '  FAIL: %s\n' "the #823 comparison anchor changed; the negative-control sed no longer applies — update it" >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '%s' "$BASE_B" > "$WORK/base"; printf '9001' > "$WORK/runs"
    printf '8001' > "$WORK/jobs"; printf '%s' "$CHECKOUT_A" > "$WORK/log"
    rm -f "$WORK"/logs/*.txt
    mgot=$(PATH="$WORK/bin:$PATH" STUB_BASE_SHA="$WORK/base" STUB_RUN_IDS="$WORK/runs" \
           STUB_LOG="$WORK/log" bash -c '
        set -uo pipefail
        REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
        . "'"$WORK"'/mutant.sh"
        _merge_ref_base
        printf "%s\n" "$_MRB_STATE"')
    assert_eq "the mutant calls a STALE base 'current' — so case 2 is the comparison, not a wording" \
        "$mgot" "current"
fi


# ---- your-org/nexus-code#878 / #882 ---------------------------------------
#
# THE SUITE HAD NO CASE WHERE TWO RUNS YIELD DIFFERENT BASES, which is exactly
# why the LIMIT the library used to name went unexercised for a whole release.
# A named limit with no fixture is a limit nobody can watch change.
#
# The stub is shared by cases 7-9 and serves TWO runs with INDEPENDENT logs, so
# a case can express agreement or disagreement by varying only the logs. Runs
# are served newest-first (9001 then 9002), matching the live ordering verified
# on the `#670` and `#823` heads — the ordering is the hazard, so the fixture
# must reproduce it rather than assume it away.
# `probe2_fixture <base-tip> <log-9001> <log-9002>` — lay the per-run fixture
# down; `probe2` then drives the REAL library against it.
#
# THE LIBRARY PATH IS NOT A PARAMETER, and that is a deliberate second draft.
# The obvious shape — `probe2 <lib> …` with `. "$1"` inside — made the source
# token a POSITIONAL PARAMETER, which `test-ambient-shell-option-scope.sh`'s
# resolver cannot resolve to an edge, so this file would have dropped OFF the
# pipefail axis and the guard's silence about it would have meant "could not
# see it" rather than "clean". That is the identical trap `_merge_ref_base.sh`
# documents on its own `grep -m1` line. The guard caught it and offered a
# manifest regeneration; a token that is STATICALLY RESOLVABLE must not be
# waved into a blind-spot manifest, so the shape changed instead. The mutant
# below therefore gets its own literal `. "$WORK/mutant878.sh"` invocation —
# the same idiom case 6 already uses — rather than a shared parameterised one.
probe2_fixture() {
    printf '%s' "$1" > "$WORK/base"
    printf '9001\n9002\n' > "$WORK/runs"
    rm -f "$WORK"/logs/*.txt
    printf '%s\n' "$2" > "$WORK/logs/9001.txt"
    printf '%s\n' "$3" > "$WORK/logs/9002.txt"
}
probe2() {
    probe2_fixture "$@"
    PATH="$WORK/bin:$PATH" \
    STUB_BASE_SHA="$WORK/base" STUB_RUN_IDS="$WORK/runs" STUB_LOG_DIR="$WORK/logs" \
    bash -c '
        set -uo pipefail
        REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
        . "'"$LIB"'"
        _merge_ref_base
        printf "%s|%s\n" "$_MRB_STATE" "$_MRB_DETAIL"
    '
}

CHECKOUT_B="2026-08-08T14:54:10.1Z HEAD is now at 9fa2210 Merge $HEAD_S into $BASE_B"

echo "=== 7. DIVERGENT — two rounds tested different bases, and neither wins ==="
# THE REPRODUCTION FROM `#878`/`#882`, VERBATIM IN SHAPE. Run 9001 is the NEWEST
# and sits at the LIVE TIP — a cheap workflow (`ci-signal`/`conflict-markers`
# fire unconditionally and do print the checkout line) from a round whose
# `tests` were skipped. Run 9002 is the older round that actually ran the tests,
# at a base that has since moved. Newest-first made 9001 the answer, so the verb
# printed `Merge-ref base: VERIFIED` over a head whose only test green was
# computed against a base that no longer exists.
got=$(probe2 "$BASE_A" "$CHECKOUT_A" "$CHECKOUT_B")
assert_eq "two runs testing DIFFERENT bases is 'divergent', never 'current'" \
    "${got%%|*}" "divergent"
assert_contains "…and the detail names BOTH runs and BOTH bases, so the reader can adjudicate" \
    "$got" "run 9001 tested ${BASE_A:0:12}, run 9002 tested ${BASE_B:0:12}"
assert_contains "…and says it REFUSED to pick, naming the freshest-wins hazard" \
    "$got" "refusing to pick one"

echo "=== 8. NEGATIVE CONTROL: without the disagreement check, case 7 reads CURRENT ==="
# Case 7 asserts a state, and a state assertion passes for free against any build
# where the fixture lands somewhere else entirely — a mis-served endpoint, a
# `return` before the comparison. Disable ONLY the disagreement verdict, leave
# the collection intact, and confirm the same fixture produces the published
# false clear: `current`, attributed to run 9001, the freshest base available.
sed 's/if (( n_bases > 1 )); then/if false; then  # NEGATIVE-CONTROL MUTANT (#878)/' \
    "$LIB" > "$WORK/mutant878.sh"
if ! grep -q 'NEGATIVE-CONTROL MUTANT (#878)' "$WORK/mutant878.sh"; then
    printf '  FAIL: %s\n' "the #878 disagreement anchor changed; the negative-control sed no longer applies — update it" >&2
    FAIL=$(( FAIL + 1 ))
else
    probe2_fixture "$BASE_A" "$CHECKOUT_A" "$CHECKOUT_B"
    mgot=$(PATH="$WORK/bin:$PATH" STUB_BASE_SHA="$WORK/base" \
           STUB_RUN_IDS="$WORK/runs" STUB_LOG_DIR="$WORK/logs" bash -c '
        set -uo pipefail
        REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
        . "'"$WORK"'/mutant878.sh"
        _merge_ref_base
        printf "%s|%s\n" "$_MRB_STATE" "$_MRB_DETAIL"')
    assert_eq "the mutant clears a head whose tests ran at a moved base — the #878/#882 false 'current'" \
        "${mgot%%|*}" "current"
    assert_contains "…attributed to the NEWEST run, which is precisely the reported reproduction" \
        "$mgot" "run 9001 tested against ${BASE_A:0:12}, which EQUALS the live tip"
fi

echo "=== 9. AGREEMENT ACROSS SEVERAL RUNS IS STILL A CLEARANCE ==="
# THE OTHER FAILURE DIRECTION, and it is not the lesser one: a gate that always
# fires gets disabled by whoever is under time pressure, which removes the gate
# entirely. Two runs, one round, same base, base unmoved — the ordinary shape of
# a healthy head, and MEASURED as the shape of both merges audited in #878's
# retrospective (#842 at 2b0bc7f3, #847 at 2a437243: every run at each head
# printed the same checkout line). It must clear, silently and without a caveat.
got=$(probe2 "$BASE_A" "$CHECKOUT_A" "$CHECKOUT_A")
assert_eq "several runs agreeing on the live tip still clears — the check is silent on a correct head" \
    "${got%%|*}" "current"
assert_contains "…and the count carries its DENOMINATOR, so 'all agreeing' cannot be a cap in disguise" \
    "$got" "(2 of 2 successful run(s) read, all testing the same base)"

echo "=== 10. THE CLEARANCE DISPOSITION IS AN ALLOWLIST WITH A DEFAULT-DENY ARM ==="
# The caller used to spell this gate itself as `[[ $_MRB_STATE == stale ]]` — a
# DENYLIST with a permissive default. Under that shape `divergent` would have
# fallen into the else and CLEARED the head. The bug is structural, not a lapse:
# any denylist retires whatever its author did not think of. So the unknown-state
# case below is the load-bearing assertion, not a completeness flourish.
disp=$(bash -c '. "'"$LIB"'"
    for s in current n/a unread stale divergent bogus-state-nobody-has-written-yet ""; do
        printf "%s=%s " "${s:-<empty>}" "$(_mrb_clearance_disposition "$s")"
    done')
assert_contains "'current' permits a clearance"  "$disp" "current=permit"
assert_contains "'n/a' permits — a bare sha has no merge ref to check" "$disp" "n/a=permit"
assert_contains "'unread' permits — GitHub expires logs, and blocking there would break the verb on every older head" \
    "$disp" "unread=permit"
assert_contains "'stale' withholds" "$disp" "stale=withhold"
assert_contains "'divergent' withholds" "$disp" "divergent=withhold"
assert_contains "AN UNKNOWN STATE WITHHOLDS — the default arm is DENY, so the next state added is fail-closed by construction" \
    "$disp" "bogus-state-nobody-has-written-yet=withhold"
assert_contains "…and so is an EMPTY state, which is what a caller sees if it asks before _merge_ref_base ran" \
    "$disp" "<empty>=withhold"

echo "=== 11. THE VERDICT CARRIES ITS OWN EXPIRY TOKEN (your-org/nexus-code#880) ==="
# A `current` verdict is point-in-time and expires the moment the base advances;
# nothing re-checks it between the verdict and the merge. MEASURED, not
# hypothetical: PR `#870` ran its suite against `a74805b5` at 01:44:41Z, `#854`
# merged at 02:31:41Z moving dev to `4ed5aa1e`, and `#870` merged onto
# `4ed5aa1e` at 02:36:41Z — five minutes, a clean merge, no conflict and no red.
# So the base sha is PUBLISHED, in full, and a caller compares rather than
# remembers.
vars=$(PATH="$WORK/bin:$PATH" STUB_BASE_SHA="$WORK/base" \
       STUB_RUN_IDS="$WORK/runs" STUB_LOG_DIR="$WORK/logs" bash -c '
    set -uo pipefail
    REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
    . "'"$LIB"'"
    _merge_ref_base
    printf "state=%s ref=%s base=%s tested=%s\n" \
        "$_MRB_STATE" "$_MRB_BASE_REF" "$_MRB_BASE_SHA" "$_MRB_TESTED"')
assert_contains "the live tip is published IN FULL, not truncated — a 12-char prefix cannot be compared against \`git rev-parse\`" \
    "$vars" "base=$BASE_A"
assert_contains "…and so is the branch it was read from" "$vars" "ref=dev"
assert_contains "…and the base the runs actually tested, for a caller that wants both sides" \
    "$vars" "tested=$BASE_A"
# On the STALE arm too: a caller re-checking after a rebase needs the tip it is
# being measured against, and that is exactly the arm where it moved.
vars=$(probe2_fixture "$BASE_B" "$CHECKOUT_A" "$CHECKOUT_A"; \
       PATH="$WORK/bin:$PATH" STUB_BASE_SHA="$WORK/base" \
       STUB_RUN_IDS="$WORK/runs" STUB_LOG_DIR="$WORK/logs" bash -c '
    set -uo pipefail
    REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
    . "'"$LIB"'"
    _merge_ref_base
    printf "state=%s base=%s\n" "$_MRB_STATE" "$_MRB_BASE_SHA"')
assert_contains "the expiry token is published on the STALE arm as well, not only when the answer is good news" \
    "$vars" "state=stale base=$BASE_B"

# ---- your-org/nexus-code#882 S1: no silent head window --------------------
#
# THE FIX FOR `#882` CONTAINED `#882`. The first cut read "every selected run",
# where "selected" was still a NEWEST-FIRST WINDOW OF EIGHT (`.[0:8]`). Measured
# on this PR's own head: ten successful `pull_request` runs, the window admitting
# eight cheap ones, and BOTH runs that executed tests falling off the end — a base
# resolved from runs whose tests never ran, which is `#882` verbatim.
#
# The cases below are the population the cap could hide. The stub serves an
# arbitrary number of runs (ids from a file, one log per run keyed by id), because
# a fixture that cannot express ten runs cannot exercise a cap that admits eight.

# `probeN <total_count>` — drives the REAL library against $WORK/runs + $WORK/logs.
#
# THE LIBRARY PATH IS NOT A PARAMETER, AND I GOT THIS WRONG TWICE. The first
# draft of case 7's helper took it as `$1` and sourced `. "$1"`;
# `test-ambient-shell-option-scope.sh` failed, the helper was restructured, and a
# comment was written explaining the trap. Then this helper was written the same
# way — with a comment asserting it was "safe here", which it was not — and the
# SAME guard failed again on the SAME shape.
#
# The reasoning that felt safe and is not: "every call site passes a literal, so
# the value is knowable". The resolver does not read call sites; it reads the
# SOURCE TOKEN, and `. "$1"` names no file. The file then drops off the pipefail
# axis and the guard's future silence about it means "could not see it", not
# "clean". A rule that has to be re-derived at each new helper is one I will keep
# getting wrong, so it is now stated as a flat prohibition: in this suite, a
# sourced path is spelled `$LIB` or `$WORK/<literal>` and never a parameter.
probeN() {
    PATH="$WORK/bin:$PATH" STUB_BASE_SHA="$WORK/base" STUB_RUN_IDS="$WORK/runs" \
    STUB_LOG_DIR="$WORK/logs" STUB_TOTALCOUNT="${1:-0}" \
    bash -c '
        set -uo pipefail
        REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
        . "'"$LIB"'"
        _merge_ref_base
        printf "%s|%s\n" "$_MRB_STATE" "$_MRB_DETAIL"
    '
}
mk_head() {   # <n-cheap-runs> <cheap-base> <n-test-runs> <test-base>
    rm -f "$WORK/runs"; rm -f "$WORK"/logs/*.txt
    local i=0
    while (( i < $1 )); do
        i=$(( i + 1 )); echo "90$(printf '%02d' "$i")" >> "$WORK/runs"
        printf 'HEAD is now at ec3412f Merge %s into %s\n' "$HEAD_S" "$2" > "$WORK/logs/90$(printf '%02d' "$i").txt"
    done
    local k=0
    while (( k < $3 )); do
        k=$(( k + 1 )); echo "80$(printf '%02d' "$k")" >> "$WORK/runs"
        printf 'HEAD is now at 9fa2210 Merge %s into %s\n' "$HEAD_S" "$4" > "$WORK/logs/80$(printf '%02d' "$k").txt"
    done
}

echo "=== 12. THE OLDEST RUN STILL COUNTS — a head window cannot hide it ==="
# The measured live shape: 8 cheap runs at the LIVE TIP (newest-first, so they
# occupy every slot a window of 8 would admit) and the 2 test-executing runs at a
# STALE base, last in the list. Under `.[0:8]` this reports `current`. It is
# `divergent`.
printf '%s' "$BASE_A" > "$WORK/base"
mk_head 8 "$BASE_A" 2 "$BASE_B"
got=$(probeN 10)
assert_eq "the 9th and 10th runs are READ, so a stale test round is not hidden by a head window" \
    "${got%%|*}" "divergent"
assert_contains "…and the witness names the base only the EXCLUDED runs tested" \
    "$got" "${BASE_B:0:12}"
assert_contains "…and the coverage line carries its denominator" \
    "$got" "10 of 10 successful run(s) read"

echo "=== 13. NEGATIVE CONTROL: restore the .[0:8] window and case 12 reads CURRENT ==="
# Not a hypothetical regression: this is the diff that shipped in the first cut.
#
# THE MUTATION IS APPLIED WHERE THE STUB CAN HONOUR IT, and getting that wrong
# is how this control was worthless on its first draft. Slicing the `--jq`
# expression is the faithful-LOOKING edit — it is literally what the shipped code
# said — but the stub does not evaluate jq, so the capped mutant received all ten
# ids anyway and reported `divergent`. The control "failed" for a reason that had
# nothing to do with the cap. Truncating `run_ids` in the SHELL models exactly
# what `.[0:8]` did to the real call (only the first eight runs are ever
# consulted) and the stub cannot ignore it.
sed 's@^    # S1-ANCHOR:.*@    run_ids=$(echo "$run_ids" | awk "NR<=8")  # NEGATIVE-CONTROL MUTANT (#882 S1)@' \
    "$LIB" > "$WORK/mutant882.sh"
if ! grep -q 'NEGATIVE-CONTROL MUTANT (#882 S1)' "$WORK/mutant882.sh"; then
    printf '  FAIL: %s\n' "the #882 S1 run-selection anchor changed; this control no longer reverts what it controls for" >&2
    FAIL=$(( FAIL + 1 ))
else
    mgot=$(PATH="$WORK/bin:$PATH" STUB_BASE_SHA="$WORK/base" STUB_RUN_IDS="$WORK/runs" \
           STUB_LOG_DIR="$WORK/logs" STUB_TOTALCOUNT=10 bash -c '
        set -uo pipefail
        REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
        . "'"$WORK"'/mutant882.sh"
        _merge_ref_base
        printf "%s|%s\n" "$_MRB_STATE" "$_MRB_DETAIL"')
    assert_eq "the capped mutant CLEARS a head whose only test runs sat at a stale base — #882 reproduced inside its own fix" \
        "${mgot%%|*}" "current"
    assert_contains "…and reports a bare count of 8, the CAP, with nothing to say it was one" \
        "$mgot" "8 of 8 successful run(s) read"
fi

echo "=== 14. A SHORTFALL IS DECLARED, NOT ABSORBED ==="
# Runs whose logs carry no checkout line: the verdict still stands on what WAS
# read, but the sentence must say how many were not — the bare-count defect one
# layer down.
mk_head 2 "$BASE_A" 0 ""
echo "9099" >> "$WORK/runs"   # a run with no log fixture => no readable line
got=$(probeN 3)
assert_eq "a run with no readable checkout line does not change the verdict" \
    "${got%%|*}" "current"
assert_contains "…but the shortfall is stated as N of M" "$got" "2 of 3 successful run(s) read"
assert_contains "…and says plainly that the unread one is NOT verified" \
    "$got" "their base is NOT verified"

echo "=== 15. A TRUNCATED PAGE IS A POPULATION NOBODY ENUMERATED ==="
# `total_count` above the page size means the id list is short by an unknown
# amount, so agreement among what came back is not agreement among all of them.
mk_head 3 "$BASE_A" 0 ""
got=$(probeN 137)
assert_eq "a head with more runs than one API page is 'unread', never 'current'" \
    "${got%%|*}" "unread"
assert_contains "…and names the truncation and the count that revealed it" \
    "$got" "137 runs, more than the 100-run API page"

echo "=== 16. DISAGREEMENT OUTRANKS TRUNCATION — a positive finding survives missing coverage ==="
mk_head 2 "$BASE_A" 1 "$BASE_B"
got=$(probeN 500)
assert_eq "runs that demonstrably disagree are 'divergent' even on a truncated page" \
    "${got%%|*}" "divergent"

echo "=== 17. THE GATE DISCRIMINATES — all three verdicts from ONE fixture family ==="
# The skeptic's standing worry about any stricter check: a gate that always fires
# gets disabled by whoever is under time pressure, which removes it entirely.
# Measured across the 14 open PRs at one instant: 7 current, 6 stale, 1 divergent.
# Pinned here so a future edit cannot quietly collapse the check onto one answer.
mk_head 4 "$BASE_A" 0 ""
printf '%s' "$BASE_A" > "$WORK/base"; c=$(probeN 4); c=${c%%|*}
printf '%s' "$BASE_B" > "$WORK/base"; t=$(probeN 4); t=${t%%|*}
mk_head 2 "$BASE_A" 2 "$BASE_B"
printf '%s' "$BASE_A" > "$WORK/base"; d=$(probeN 4); d=${d%%|*}
assert_eq "same fixture family, base unmoved  -> current" "$c" "current"
assert_eq "same fixture family, base moved    -> stale"   "$t" "stale"
assert_eq "same fixture family, runs disagree -> divergent" "$d" "divergent"
assert_eq "…and the three verdicts are DISTINCT, so the gate has not collapsed onto one answer" \
    "$(printf '%s\n' "$c" "$t" "$d" | sort -u | wc -l | tr -d ' ')" "3"

echo "=== 17b. THE JOB-SIDE CAP HAS A FIXTURE THAT CROSSES ITS BOUNDARY ==="
# CARRIED, AND NOW MEASURED: the jobs slice was `.[0:6]` and no fixture ever put
# a merge line past the 6th job, so deleting the cap and keeping it were
# indistinguishable to this suite. Same lesson F3 taught one level up — the stub
# seeing the layer is NECESSARY; a fixture straddling the boundary is what makes
# the assertion load-bearing.
#
# One run, EIGHT successful jobs, and the checkout line only on the 8th.
mk_head 0 "" 0 ""
echo "9001" > "$WORK/runs"
rm -f "$WORK"/logs/*.txt
printf '%s\n' "$CHECKOUT_A" > "$WORK/logs/900108.txt"     # the 8th job
printf '%s' "$BASE_A" > "$WORK/base"
got=$(PATH="$WORK/bin:$PATH" STUB_BASE_SHA="$WORK/base" STUB_RUN_IDS="$WORK/runs" \
      STUB_LOG_DIR="$WORK/logs" STUB_TOTALCOUNT=1 STUB_JOBS_PER_RUN=8 \
      bash -c '
        set -uo pipefail
        REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
        . "'"$LIB"'"
        _merge_ref_base
        printf "%s|%s\n" "$_MRB_STATE" "$_MRB_DETAIL"')
assert_eq "a merge line in the 8TH job is still found — no job-side cap hides it" \
    "${got%%|*}" "current"
assert_contains "…and the run counts as read, not as a shortfall" \
    "$got" "1 of 1 successful run(s) read"

echo "=== 18. THE STUB ITSELF EVALUATES --jq — the observer's own predicate ==="
# THE GUARD ON THE GUARD. Every case above is only meaningful because the stub
# applies the REAL `--jq` expression to a REAL payload. When it did not, the run
# SELECTION — which lives entirely in that expression — was invisible: restoring
# `.[0:8]` in the jq left all 95 assertions green, so S1 could have been reverted
# wholesale without a single test noticing.
#
# So the property is asserted directly rather than relied upon. If somebody
# "simplifies" the stub back to pre-digested output, this fails HERE, next to an
# explanation, instead of silently disarming every selection assertion in the file.
jqprobe=$(PATH="$WORK/bin:$PATH" STUB_RUN_IDS="$WORK/runs" STUB_TOTALCOUNT=7 \
    bash -c 'gh api "/repos/o/r/actions/runs?head_sha=x" --jq ".total_count"')
assert_eq "the stub applies the caller's --jq to a real payload, rather than printing a canned line" \
    "$jqprobe" "7"
jqraw=$(PATH="$WORK/bin:$PATH" STUB_RUN_IDS="$WORK/runs" STUB_TOTALCOUNT=7 \
    bash -c 'gh api "/repos/o/r/actions/runs?head_sha=x"')
assert_contains "…and serves GitHub-SHAPED JSON when no --jq is passed, not a digest" \
    "$jqraw" '"workflow_runs":'

echo "=== 19. A TOTAL THE PARSE CANNOT READ IS 'COULD NOT TELL', NOT 'NO TRUNCATION' ==="
# `null` is what jq emits for an absent field. Pre-fix, `(( total_count > 100 ))`
# on that value is FATAL under the caller's own option set — measured on this
# host, naming the shell because the answer depends on it:
#
#   bash 4.4.20 + `set -u`  (ci-head-attempts.sh runs `set -uo pipefail`)
#       -> `bash: null: unbound variable`, rc 127 — the verb DIES mid-check
#   bash 4.4.20, no `set -u`  -> rc 1, treated as 0: silent pass
#   zsh 5.4.2 + `set -u`      -> rc 1, no error:     silent pass
#
# A crash on the live path, a silent pass elsewhere, a verdict in neither. (The
# first version of this note claimed the silent-pass behaviour for the live path;
# it had been measured without `set -u`. Corrected, not replaced — the wrong
# mechanism is the part worth remembering.)
mk_head 2 "$BASE_A" 0 ""
got=$(probeN "null")
assert_eq "a non-numeric total is 'unread', never a silent pass" "${got%%|*}" "unread"
assert_contains "…and says the population could not be sized" \
    "$got" "could not read"
got=$(probeN 2)
assert_eq "…while a numeric total still clears — the arm discriminates" "${got%%|*}" "current"

echo "=== 20. A TRUNCATED JOBS PAGE IS NAMED, NOT ABSORBED ==="
# The jobs endpoint is bounded at 100 exactly as the runs endpoint is. It can
# only LOSE a run's base, never corrupt it — but a lost base is a run whose
# agreement was never established, so the reason is stated rather than left as a
# bare shortfall.
mk_head 2 "$BASE_A" 0 ""
echo "9099" >> "$WORK/runs"          # a run with no log fixture => no readable line
got=$(PATH="$WORK/bin:$PATH" STUB_BASE_SHA="$WORK/base" STUB_RUN_IDS="$WORK/runs" \
      STUB_LOG_DIR="$WORK/logs" STUB_TOTALCOUNT=3 STUB_JOBS_TOTALCOUNT=250 \
      bash -c '
        set -uo pipefail
        REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
        . "'"$LIB"'"
        _merge_ref_base
        printf "%s|%s\n" "$_MRB_STATE" "$_MRB_DETAIL"')
assert_contains "a run whose JOB page truncated is named as such, not merely counted as unread" \
    "$got" "MORE THAN 100 jobs"
assert_contains "…beside the N-of-M that already showed the shortfall" \
    "$got" "2 of 3 successful run(s) read"
# THE COUNT, PINNED. Without this the clause is witnessed but its NUMBER is not,
# and the two runs that DID yield a line could silently start being counted as
# truncated too — the clause would still appear and the suite would still read
# green. `1` is the discriminating value: three runs, a truncated jobs page for
# all of them, and only the ONE that produced no line may be counted.
assert_contains "…and the COUNT is the runs that actually went unread, not every run on a truncated page" \
    "$got" "1 of those had MORE THAN 100 jobs"

echo "=== 20b. CONTROL: an unread run on an UNTRUNCATED jobs page is NOT blamed on truncation ==="
# Same fixture, same missing log, jobs page NOT truncated. The shortfall must
# still be reported and the truncation clause must be ABSENT — otherwise case 20
# is asserting "the clause appears when a run is unread", which is a different
# and much weaker claim than the one it is making.
got=$(PATH="$WORK/bin:$PATH" STUB_BASE_SHA="$WORK/base" STUB_RUN_IDS="$WORK/runs" \
      STUB_LOG_DIR="$WORK/logs" STUB_TOTALCOUNT=3 STUB_JOBS_TOTALCOUNT=1 \
      bash -c '
        set -uo pipefail
        REPO=owner/repo; PR_NUM=42; SHA='"$HEAD_S"'
        . "'"$LIB"'"
        _merge_ref_base
        printf "%s|%s\n" "$_MRB_STATE" "$_MRB_DETAIL"')
assert_contains "the shortfall is still reported on an untruncated page" \
    "$got" "2 of 3 successful run(s) read"
assert_not_contains "…and truncation is NOT invoked to explain it" \
    "$got" "MORE THAN 100 jobs"

# ---- assertion-count guard (your-org/nexus-code#805) ----------------------
# An exact expected total, not just the shared ledger. The ledger stops a
# ZERO-assertion run announcing a pass; it cannot see an assertion silently
# dropped from the middle of a suite — which for this file would mean the STALE
# arm quietly disappearing while the summary still says ALL TESTS PASSED.
# ── your-org/nexus-code#923: the two quantities are DOCUMENTED as separable ──
# `mergeable` recompute and merge-ref REBASE are different computations (#923's
# observation, reproduced at n=2 and recorded in this library's header), and
# the model quoted to the next reader must say so — in the library AND in the
# contributor doc that quotes #859 as settled fact.
_doc923="$_test_dir/../../docs/contributing/development.md"
if grep -q 'exception, not a mechanism' "$_doc923" 2>/dev/null && grep -q 'monitor/_merge_ref_base.sh' "$_doc923" 2>/dev/null; then
    printf '  PASS: #923 development.md states the #859 model has a measured exception and points at the library\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: #923 development.md still quotes the #859 model as settled fact\n' >&2; FAIL=$(( FAIL + 1 ))
fi
if grep -q 'DIFFERENT computation from the rebase' "$_test_dir/../_merge_ref_base.sh" 2>/dev/null \
   && grep -q 'COOLDOWN question is still open' "$_test_dir/../_merge_ref_base.sh" 2>/dev/null; then
    printf '  PASS: #923 the library header records (c) answered and (b) still open, by name\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: #923 the library header no longer records which of the three questions is answered\n' >&2; FAIL=$(( FAIL + 1 ))
fi

EXPECTED_ASSERTIONS=61   # +2: #923 documentation-consistency pins
TOTAL=$(( PASS + FAIL ))
if (( TOTAL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi

th_summary_and_exit
