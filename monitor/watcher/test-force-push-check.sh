#!/usr/bin/env bash
# monitor/watcher/test-force-push-check.sh
#
# Unit tests for monitor/force-push-check.sh (your-org/nexus-code#835).
#
# The check has produced FOUR false clearances on four distinct axes —
# authorship, failure-vs-clearance, wrong ref, wrong remote — each found only
# by BUILDING the failing case. It no longer models git's push-target
# resolution; it asks git via `push --dry-run --porcelain --force`. These tests
# exist to keep that true.
#
# HARNESS DESIGN, because a table of verdicts is easy to fake:
#   * Every scenario is a REAL repo with REAL remotes. Nothing is simulated —
#     the states being separated are git's own.
#   * Ground truth is THE OUTCOME OF AN ACTUAL PUSH, not the script's
#     reasoning: ask the script, perform the real forced push, then check
#     whether the sibling commit survived. SAFE followed by a lost commit is
#     the defect, and no amount of reading the script would surface it.
#   * In each destructive scenario the ref/remote ACTUALLY pushed is dirty
#     while the plausible WRONG one is clean, so a SAFE verdict can only come
#     from looking at the wrong thing.
#   * A true-negative control (a genuinely clean push) is included, so the
#     table cannot be satisfied by a script that just always says UNSAFE.

set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK="$_test_dir/../force-push-check.sh"

. "$_test_dir/_test_helpers.sh"

# Every assertion helper must EXIST before any is called: an undefined
# `assert_*` is rc 127, tallied by nothing, and the footer would still say
# ALL TESTS PASSED with a quieter number.
for _th in assert_eq th_summary_and_exit; do
    declare -F "$_th" >/dev/null 2>&1 || {
        echo "FATAL: assertion helper '$_th' is not defined by _test_helpers.sh." >&2
        exit 1
    }
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Local ok/bad feed the SHARED counters, so th_summary_and_exit reconciles
# them against the subshell-durable ledger.
ok()  { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL: %s (%s)\n' "$1" "$2" >&2; FAIL=$((FAIL+1)); }
# says_safe <output>: rc 0 iff the output carries the SAFE VERDICT LINE.
# NOT `case $out in *SAFE*` — that also matches "UNSAFE", which is the opposite
# verdict. A substring adjacent to the property is not the property; that is
# the entire theme of this PR, and it bit inside its own test.
says_safe() { grep -q '^SAFE:' <<<"$1"; }
assert_rc() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected rc $2, got $3"; fi; }

# rig <name>: bare `origin` + bare `other`, clone A with both remotes, `feature`
# on both. Callers dirty ONE side so the other stays a plausible wrong answer.
rig() {
    local r="$TMP/$1"; rm -rf "$r"; mkdir -p "$r"
    git init -q --bare "$r/origin.git"; git init -q --bare "$r/other.git"
    git clone -q "$r/origin.git" "$r/A" 2>/dev/null
    git -C "$r/A" config user.name D; git -C "$r/A" config user.email d@e
    git -C "$r/A" remote add other "$r/other.git"
    ( cd "$r/A"
      echo base > base.txt; git add -A; git commit -qm base; git branch -M dev
      git push -q origin dev; git push -q other dev
      git checkout -qb feature; echo a > a.txt; git add -A; git commit -qm mine
      git push -q origin feature; git push -q other feature ) >/dev/null 2>&1
    RIG="$r"
}
# dirty <remote-dir>: a SIBLING commit lands on that remote's `feature`
dirty() {
    local r="$1" which="$2"
    git clone -q "$r/${which}.git" "$r/B_$which" 2>/dev/null
    ( cd "$r/B_$which"; git config user.name D; git config user.email d@e
      git checkout -q feature
      echo sib > sib.txt; git add -A; git commit -qm "SIBLING_$which"
      git push -q origin feature ) >/dev/null 2>&1
}
# ground_truth <desc> <expected-rc> <push-args…>
ground_truth() {
    local desc="$1" exp="$2"; shift 2
    local rc; bash "$CHECK" --quiet "$@" >/dev/null 2>&1; rc=$?
    git push -q --force "$@" >/dev/null 2>&1
    # did ANY sibling commit disappear from the remote it lived on?
    local lost=no
    for w in origin other; do
        [ -d "$RIG/${w}.git" ] || continue
        local sha; sha=$(git ls-remote "$RIG/${w}.git" refs/heads/feature 2>/dev/null | cut -f1)
        [ -n "$sha" ] || continue
        if grep -q "SIBLING_$w" <<<"$(git log --oneline "$sha" 2>/dev/null)"; then :; else
            git log --oneline "$RIG/${w}.git" >/dev/null 2>&1
            # the sibling existed on this remote only if we dirtied it
            [ -d "$RIG/B_$w" ] && lost=yes
        fi
    done
    if [ "$rc" = 0 ] && [ "$lost" = yes ]; then
        bad "$desc" "FALSE SAFE — rc 0 but a sibling commit was DESTROYED"
    elif [ "$rc" = "$exp" ]; then
        ok "$desc (rc $rc; sibling lost by the real push: $lost)"
    else
        bad "$desc" "expected rc $exp, got $rc (sibling lost: $lost)"
    fi
}

echo '=== TRUE NEGATIVE: a genuinely clean push must say SAFE ==='
rig tn; cd "$RIG/A"; echo x > x.txt; git add -A; git commit -qm "my own new work"
ground_truth "clean fast-forward push => rc 0" 0 origin feature

echo '=== the sibling case: remote carries a commit we lack ==='
rig base1; dirty "$RIG" origin; cd "$RIG/A"; git commit -q --allow-empty -m local
ground_truth "sibling on origin/feature => rc 1" 1 origin feature
# CONTROL: the ORIGINAL authorship check would have cleared this.
cd "$RIG/A"
n=$(git log --format='%an' origin/dev..HEAD 2>/dev/null | sort -u | wc -l | tr -d ' ')
[ "$n" = 1 ] && ok "CONTROL: the author check sees ONE name (it would clear this)" \
             || bad "CONTROL author" "expected 1 author, got $n"

echo '=== R3: the wrong REMOTE (explicit, and via remote.pushDefault) ==='
# origin is CLEAN, other is DIRTY. Assuming `origin` is a false SAFE.
rig r3a; dirty "$RIG" other; cd "$RIG/A"; git commit -q --allow-empty -m local
ground_truth "push to OTHER while origin is clean => rc 1" 1 other feature

rig r3b; dirty "$RIG" other; cd "$RIG/A"; git commit -q --allow-empty -m local
git config remote.pushDefault other
ground_truth "bare push with remote.pushDefault=other => rc 1" 1

rig r3c; dirty "$RIG" other; cd "$RIG/A"; git commit -q --allow-empty -m local
git config branch.feature.pushRemote other
ground_truth "bare push with branch.<n>.pushRemote=other => rc 1" 1

echo '=== R1: the ref the push MOVES is not necessarily HEAD ==='
rig r1a; dirty "$RIG" origin; cd "$RIG/A"; git fetch -q origin
git checkout -q -b integration origin/feature      # HEAD contains SIBLING; feature does not
ground_truth "push feature while checked out on integration => rc 1" 1 origin feature

rig r1b; dirty "$RIG" origin; cd "$RIG/A"; git fetch -q origin
git checkout -q --detach origin/feature
ground_truth "push feature while HEAD is DETACHED => rc 1" 1 origin feature

rig r1c; dirty "$RIG" origin; cd "$RIG/A"; git checkout -q -b mywork
ground_truth "explicit refspec mywork:feature (src != dst) => rc 1" 1 origin mywork:feature

rig r1d; dirty "$RIG" origin; cd "$RIG/A"
git checkout -q -b local-name dev
git config push.default upstream
git branch --set-upstream-to=origin/feature local-name >/dev/null 2>&1
ground_truth "bare push, upstream NAME differs from local => rc 1" 1

echo '=== + force marker in the refspec is git'"'"'s, and git parses it ==='
rig plus; dirty "$RIG" origin; cd "$RIG/A"; git commit -q --allow-empty -m local
ground_truth "explicit +feature refspec => rc 1" 1 origin +feature

echo '=== multi-ref pushes are ANSWERED now, not refused ==='
# push.default=matching moves every matching branch. The old hand-rolled
# resolver refused; asking git enumerates them all, so one dirty ref among
# several is caught.
rig multi; dirty "$RIG" origin; cd "$RIG/A"; git commit -q --allow-empty -m local
git config push.default matching
bash "$CHECK" --quiet >/dev/null 2>&1; rc=$?
assert_rc "push.default=matching with a dirty ref => rc 1 (answered, not refused)" 1 "$rc"

echo '=== states that must NOT read as a clearance ==='
rig m2; cd "$RIG/A"; git remote add broken /nonexistent/definitely-not-here.git
bash "$CHECK" --quiet broken feature >/dev/null 2>&1; rc=$?
assert_rc "unreachable remote => rc 2 REFUSED" 2 "$rc"
out=$(bash "$CHECK" --quiet broken feature 2>&1)
if says_safe "$out"; then bad "M2 wording" "a failed resolution carries the SAFE verdict"
elif grep -q REFUSED <<<"$out"; then ok "…and says REFUSED, not SAFE"
else bad "M2 wording" "no REFUSED in output"; fi

rig m1; cd "$RIG/A"; git checkout -qb never-pushed; echo z > z.txt; git add -A; git commit -qm z
bash "$CHECK" --quiet origin never-pushed >/dev/null 2>&1; rc=$?
assert_rc "new remote ref => rc 3, not 0" 3 "$rc"
# NOT --quiet here: --quiet suppresses exactly the sentence being asserted,
# so the quiet form would make this assertion unfalsifiable.
out=$(bash "$CHECK" origin never-pushed 2>&1)
case "$out" in
    *"Not a clearance"*|*"not a clearance"*) ok "…and disclaims being a clearance" ;;
    *) bad "M1 wording" "does not disclaim being a clearance" ;;
esac

rig nothing; cd "$RIG/A"; git config push.default nothing
bash "$CHECK" --quiet >/dev/null 2>&1; rc=$?
assert_rc "push.default=nothing (no refspec resolved) => rc 2" 2 "$rc"

rig det; cd "$RIG/A"; git checkout -q --detach HEAD
bash "$CHECK" --quiet >/dev/null 2>&1; rc=$?
assert_rc "detached HEAD with no ref => rc 2" 2 "$rc"

cd "$TMP"; mkdir -p notarepo; cd notarepo
bash "$CHECK" --quiet origin x >/dev/null 2>&1; rc=$?
assert_rc "outside a git repo => rc 2" 2 "$rc"

echo '=== the FAIL-CLOSED arms themselves (they exist to stop a 5th false clearance) ==='
# These two arms are the whole reason an unexpected porcelain answer cannot
# become a pass. Untested, they are decoration: deleting either would not
# redden the suite — the same shape as the vacuous `\p` assertion earlier in
# this PR. So both are exercised, and each is checked to FAIL CLOSED (rc 2),
# never 0.

# forge_flag <flag> <summary>: PATH-front `git` stub emitting ONE porcelain ref
# line with the given flag, forwarding everything else to the real git — so the
# flag is the only synthetic thing in play.
#
# WHY A STUB FOR THESE TWO. `!` and unknown flags are not reachable through a
# real `--dry-run --force` here, and the reason is itself worth recording:
# receive-side policy (`receive.denyNonFastForwards`, `denyCurrentBranch`,
# pre-receive hooks) is enforced when the remote RECEIVES, not during the
# dry-run negotiation — measured below. So git reports `+ (forced update)` and
# the real push is what fails. That errs conservative for our question, but it
# leaves these arms unreachable in a live rig, and an untested fail-closed arm
# is decoration.
forge_flag() {
    local flag="$1" summary="$2"
    STUBDIR="$TMP/stub.$$"; rm -rf "$STUBDIR"; mkdir -p "$STUBDIR"
    local realgit; realgit=$(command -v git)
    {
      printf '#!/usr/bin/env bash\n'
      printf 'ispush=; porc=\n'
      printf 'for a in "$@"; do [ "$a" = push ] && ispush=1; [ "$a" = --porcelain ] && porc=1; done\n'
      printf 'if [ -n "$ispush" ] && [ -n "$porc" ]; then\n'
      printf '  printf "To %s\\n" "%s"\n' '%s' "$RIG/origin.git"
      printf '  printf "%s\\trefs/heads/feature:refs/heads/feature\\t%s\\n"\n' "$flag" "$summary"
      printf '  printf "Done\\n"; exit 0\n'
      printf 'fi\n'
      printf 'exec %s "$@"\n' "$realgit"
    } > "$STUBDIR/git"
    chmod +x "$STUBDIR/git"
}

# (a) MEASURED FIRST: receive-side policy is invisible to the dry-run.
rig rej; dirty "$RIG" origin; cd "$RIG/A"; git commit -q --allow-empty -m local
git -C "$RIG/origin.git" config receive.denyNonFastForwards true
out=$(bash "$CHECK" origin feature 2>&1); rc=$?
assert_rc "receive.denyNonFastForwards is NOT seen by the dry-run => still rc 1" 1 "$rc"
if says_safe "$out"; then bad "denyNFF" "reported the SAFE verdict"; else ok "…and errs conservative (UNSAFE), never SAFE"; fi

# (b) the '!' arm, forged.
rig rejstub; cd "$RIG/A"; forge_flag '!' '[remote rejected] (pre-receive hook declined)'
out=$(PATH="$STUBDIR:$PATH" bash "$CHECK" origin feature 2>&1); rc=$?
assert_rc "'!' rejected line => rc 2 REFUSED, not 0" 2 "$rc"
case "$out" in
    *REJECTED*|*rejected*) ok "…and says the push was rejected" ;;
    *) bad "'!' arm wording" "no rejection named in: $out" ;;
esac
if says_safe "$out"; then bad "'!' arm" "a rejected push carries the SAFE verdict"; else ok "…and never gives the SAFE verdict"; fi

# (c) the UNRECOGNISED-flag arm. No git emits one today — which is exactly why
#     the arm exists: a future git could, and the default arm must deny.
rig unk; cd "$RIG/A"; forge_flag 'Q' '[something new]'
out=$(PATH="$STUBDIR:$PATH" bash "$CHECK" origin feature 2>&1); rc=$?
assert_rc "unrecognised porcelain flag => rc 2 REFUSED, not 0" 2 "$rc"
case "$out" in
    *unrecognised*|*unrecognized*) ok "…and names the flag it could not classify" ;;
    *) bad "unknown-flag arm" "did not name the unclassifiable flag: $out" ;;
esac
if says_safe "$out"; then bad "unknown-flag arm" "an unclassifiable flag carries the SAFE verdict"; else ok "…and never gives the SAFE verdict"; fi
# CONTROL: the stub really reached the classifier — otherwise the assertions
# above would pass against a script that never saw the forged flag at all.
case "$out" in *"'Q'"*) ok "CONTROL: the forged flag reached the classifier" ;;
                *) bad "stub control" "the forged flag never appeared in the output" ;; esac

echo '=== the dry-run is authoritative: no refs resolved is never a pass ==='
rig auth; cd "$RIG/A"
if grep -q 'push --dry-run --porcelain --force' "$CHECK"; then
    ok "the check asks git (push --dry-run --porcelain --force), not a model of it"
else
    bad "resolution source" "the check no longer asks git for the push target"
fi
# CODE only — the header comment names these configs precisely to explain why
# they are NOT consulted, and grepping the whole file would flag that prose and
# make the assertion fire on its own documentation.
_code=$(sed 's/#.*//' "$CHECK")
if grep -qE 'git config .*(push\.default|pushRemote|pushDefault)|branch\.[^ ]*\.merge' <<<"$_code"; then
    bad "re-implementation" "the check re-derives push-target config by hand"
else
    ok "…and re-derives NO push-target config by hand (that was the defect class)"
fi

echo '=== the remote is sampled ONCE — a moving target observed twice can disagree ==='
# The single-invocation fix was UNTESTED: reverting it to two `git push
# --dry-run` calls left this suite at 30 passed / 0 failed. A guard that cannot
# fail is not a guard, so count the invocations rather than trusting the source.
# The stub is TRANSPARENT — it tallies and forwards to the real git — so the
# count describes the same run the verdict came from, and the control below
# proves that by comparing the stubbed verdict against the unstubbed one.
count_dryruns() {
    COUNTFILE="$TMP/dryruns.$$"; : > "$COUNTFILE"
    STUBDIR="$TMP/countstub.$$"; rm -rf "$STUBDIR"; mkdir -p "$STUBDIR"
    local realgit; realgit=$(command -v git)
    {
      printf '#!/usr/bin/env bash\n'
      printf 'ispush=; isdry=\n'
      printf 'for a in "$@"; do [ "$a" = push ] && ispush=1; [ "$a" = --dry-run ] && isdry=1; done\n'
      printf '[ -n "$ispush" ] && [ -n "$isdry" ] && echo x >> %s\n' "$COUNTFILE"
      printf 'exec %s "$@"\n' "$realgit"
    } > "$STUBDIR/git"
    chmod +x "$STUBDIR/git"
}
rig once; dirty "$RIG" origin; cd "$RIG/A"; git commit -q --allow-empty -m local
plain_rc=0; bash "$CHECK" origin feature >/dev/null 2>&1 || plain_rc=$?
count_dryruns
stub_rc=0; PATH="$STUBDIR:$PATH" bash "$CHECK" origin feature >/dev/null 2>&1 || stub_rc=$?
# Counted with `wc -l <`, NOT `grep -c … || echo 0`: `grep -c` exits 1 on a
# legitimate zero, so that fallback cannot separate "counted none" from "could
# not read the file" — the silent-zero class test-count-fallback-lint.sh exists
# to forbid, and it caught this exact line here. No fallback at all: the file is
# created by count_dryruns, so anything unreadable surfaces as a loud mismatch.
_dryruns=$(wc -l < "$COUNTFILE")
assert_eq "the remote is observed exactly ONCE per check" "$_dryruns" "1"
# CONTROL: without this, a stub that broke the check would still report "1"
# while measuring a run that never reached the classifier.
assert_eq "CONTROL: the counting stub is transparent (same verdict as unstubbed)" \
    "$stub_rc" "$plain_rc"

# EXACT count, not a floor. th_summary_and_exit reports the assertions that
# RAN; a case that stops running is silently absent from that number unless it
# is compared against a declared total. Bump deliberately when adding a case;
# a DROP means a case died.
_EXPECTED_ASSERTIONS=32
_ran=$(( PASS + FAIL ))
assert_eq "every declared assertion executed ($_EXPECTED_ASSERTIONS)" "$_ran" "$_EXPECTED_ASSERTIONS"

th_summary_and_exit
