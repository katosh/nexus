#!/usr/bin/env bash
# Unit tests for primary-clone deployment-drift detection
# (`_clone_drift.sh`, your-org/nexus-code#614).
#
# Run: bash monitor/watcher/test-clone-drift.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: build REAL git repositories (a local bare "origin" plus
# clones) rather than stubbing `git`. The defect this module exists to
# catch is a disagreement between a local ref and a remote's true tip,
# and a stubbed git cannot exhibit it — the stub would just replay
# whatever the test author believed. Everything is local, so the suite
# is hermetic and offline; only the `gh api compare` fallback is stubbed,
# because it is the one genuinely remote dependency.
#
# NEGATIVE CONTROLS. Every guard here is paired with a case that drives
# it into its failure branch and asserts on the REASON it reports, not
# merely on a non-zero exit. A guard that returns the right code for the
# wrong reason is the defect class this repo keeps rediscovering, and an
# exit-code-only assertion cannot see it. In particular
# `unknown_never_reads_as_up_to_date` exists because that specific
# collapse — a detector reporting green when it cannot see — is the
# failure `#614` was filed to prevent.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# `log` is undefined outside main.sh; _clone_drift_log degrades to a
# no-op, which is what we want for clean test stdout.
source "$_test_dir/_version_restart.sh"
source "$_test_dir/_clone_drift.sh"

git_q() { git "$@" >/dev/null 2>&1; }

# Build: bare origin with branch `dev` carrying <n> commits, plus a
# clone whose HEAD sits at commit <at> (1-based).
build_fixture() {
    local name="$1" total="$2" at="$3"
    local origin="$WORK/$name.git" work="$WORK/$name-seed" clone="$WORK/$name"
    rm -rf "$origin" "$work" "$clone"
    # `git init -b <branch>` needs git >= 2.28; the sandbox hosts ship
    # 2.17. Set the initial branch the portable way instead — otherwise
    # EVERY fixture silently fails to build and the suite degenerates
    # into comparing empty strings against empty strings, which passes.
    git_q init --bare "$origin"
    git_q -C "$origin" symbolic-ref HEAD refs/heads/dev
    git_q init "$work"
    git_q -C "$work" symbolic-ref HEAD refs/heads/dev
    local i
    for (( i = 1; i <= total; i++ )); do
        printf 'commit %s\n' "$i" > "$work/f$i.txt"
        git_q -C "$work" add -A
        # Space the commits an hour apart so the hours threshold has
        # something real to measure.
        GIT_AUTHOR_DATE="$(( 1785000000 + i * 3600 )) +0000" \
        GIT_COMMITTER_DATE="$(( 1785000000 + i * 3600 )) +0000" \
            git_q -C "$work" commit -m "c$i"
    done
    git_q -C "$work" remote add origin "$origin"
    git_q -C "$work" push -u origin dev
    git_q clone "$origin" "$clone"
    local sha
    sha=$(git -C "$work" rev-list --reverse dev | sed -n "${at}p")
    git_q -C "$clone" checkout "$sha"
    # FIXTURE GUARD. A fixture that failed to build yields a path that
    # is not a repo, and `_clone_drift_probe` answers `unknown` for it —
    # which makes half the assertions below compare two empty strings
    # and PASS. That is the same class of defect the module under test
    # exists to catch, so assert the fixture is real before using it.
    if [[ "$(git -C "$clone" rev-parse HEAD 2>/dev/null)" != "$sha" ]] \
       || [[ "$(git -C "$origin" rev-list --count dev 2>/dev/null)" != "$total" ]]; then
        printf '  FAIL: fixture %s did not build (git %s)\n' "$name" "$(git --version)" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    printf '%s' "$clone"
}

verdict_of() { _clone_drift_field "$1" verdict; }

echo "== _clone_drift_probe verdicts =="

C=$(build_fixture uptodate 3 3)
line=$(_clone_drift_probe "$C" dev)
assert_eq "clone at tip -> up-to-date" "$(verdict_of "$line")" "up-to-date"

C=$(build_fixture behind 6 2)
line=$(_clone_drift_probe "$C" dev)
assert_eq "clone 4 commits back -> behind" "$(verdict_of "$line")" "behind"
assert_eq "  margin counted exactly" "$(_clone_drift_field "$line" commits)" "4"
assert_eq "  oldest undeployed commit epoch is c3, not HEAD" \
    "$(_clone_drift_field "$line" oldest_epoch)" "$(( 1785000000 + 3 * 3600 ))"

# A clone AHEAD of the remote is not drift. Without the --is-ancestor
# discriminator this reports "behind" purely because head != tip, which
# would alarm on every unpushed local commit.
C=$(build_fixture ahead 3 3)
printf 'local work\n' > "$C/local.txt"
git_q -C "$C" add -A && git_q -C "$C" commit -m local
line=$(_clone_drift_probe "$C" dev)
assert_eq "clone AHEAD of remote -> up-to-date (not behind)" "$(verdict_of "$line")" "up-to-date"

echo "== negative controls: every unknown reports WHY =="

line=$(_clone_drift_probe "$WORK/definitely-not-a-repo" dev)
assert_eq "non-repo -> unknown" "$(verdict_of "$line")" "unknown"
assert_contains "  reason names the cause" "$line" "reason=not_a_git_repo"

C=$(build_fixture badbranch 3 3)
line=$(_clone_drift_probe "$C" branch-that-does-not-exist)
assert_eq "absent remote branch -> unknown" "$(verdict_of "$line")" "unknown"
assert_contains "  reason names the cause" "$line" "reason=remote_tip_unresolved"

# Unreachable remote: ls-remote must fail, and the failure must NOT be
# read as currency.
C=$(build_fixture goneremote 3 3)
git_q -C "$C" remote set-url origin "$WORK/no-such-origin.git"
line=$(_clone_drift_probe "$C" dev)
assert_eq "unreachable origin -> unknown" "$(verdict_of "$line")" "unknown"
assert_contains "  reason names the cause" "$line" "reason=remote_tip_unresolved"

# THE load-bearing control. Enumerate every failure mode above and
# assert not one of them produced the reassuring answer. This is the
# assertion that would have caught a detector reporting green while
# blind — the precise condition #614 was filed about.
echo "== unknown_never_reads_as_up_to_date =="
_blind_cases=0
for probe in "$WORK/definitely-not-a-repo|dev" "$WORK/badbranch|nope-nope" "$WORK/goneremote|dev"; do
    _p="${probe%%|*}"; _b="${probe##*|}"
    _v=$(verdict_of "$(_clone_drift_probe "$_p" "$_b")")
    if [[ "$_v" == "up-to-date" ]]; then
        printf '  FAIL: blind probe %s reported up-to-date\n' "$_p" >&2
        FAIL=$(( FAIL + 1 ))
    else
        _blind_cases=$(( _blind_cases + 1 ))
    fi
done
assert_eq "all 3 blind probes refused to report currency" "$_blind_cases" "3"

echo "== origin-URL slug parsing (real function, before it is shadowed) =="

C=$(build_fixture slugs 2 2)
git_q -C "$C" remote set-url origin "git@github.com:your-org/nexus-code.git"
assert_eq "SSH form"        "$(_clone_drift_slug "$C")" "your-org/nexus-code"
git_q -C "$C" remote set-url origin "https://github.com/your-org/nexus-code.git"
assert_eq "HTTPS form"      "$(_clone_drift_slug "$C")" "your-org/nexus-code"
git_q -C "$C" remote set-url origin "https://x-access-token:tok@github.com/your-org/nexus-code"
assert_eq "HTTPS with creds" "$(_clone_drift_slug "$C")" "your-org/nexus-code"
git_q -C "$C" remote set-url origin "/tmp/some/bare.git"
_clone_drift_slug "$C" >/dev/null 2>&1
assert_rc "local path yields no slug (rc 1, not a bogus guess)" "$?" "1"

echo "== gh compare fallback (remote tip absent locally) =="

# Drive the branch that runs when the remote tip is NOT an object in the
# clone. Rather than corrupting a real object store (which breaks every
# later git call in ways unrelated to the code under test), make
# `cat-file` — and only `cat-file` — report the object as absent.
cat > "$WORK/gh-stub" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "api" && "\$2" == *"/compare/"* ]]; then
    printf '{"status":"ahead","ahead_by":4,"behind_by":0,"commits":[{"commit":{"committer":{"date":"2026-07-27T01:31:50Z"}}}]}'
    exit 0
fi
exit 1
STUB
chmod +x "$WORK/gh-stub"

C=$(build_fixture fallback2 6 2)

# Two seams, both FLAG-controlled rather than redefined-and-unset:
# `unset -f` deletes a function, it does not restore the one the module
# defined, so an unset override leaves every later call returning 127 —
# which silently poisons the rest of the suite.
_CD_FAIL_CATFILE=0
_CD_FAKE_SLUG=""
_real_git=$(command -v git)
_clone_drift_git() {
    if (( _CD_FAIL_CATFILE )) && [[ "${3:-}" == "cat-file" ]]; then return 1; fi
    "$_real_git" "$@"
}
# The fixture's origin is a local bare path, which legitimately has no
# `owner/repo` to parse — so stub the slug rather than the URL, keeping
# `ls-remote` pointed at the real local origin.
_clone_drift_slug() {
    [[ -n "$_CD_FAKE_SLUG" ]] || return 1
    printf '%s' "$_CD_FAKE_SLUG"
}

_CD_FAIL_CATFILE=1
_CD_FAKE_SLUG="owner/repo"
_CLONE_DRIFT_GH_BIN="$WORK/gh-stub"
line=$(_clone_drift_probe "$C" dev)
assert_eq "API fallback -> behind" "$(verdict_of "$line")" "behind"
assert_eq "  ahead_by is the behind-margin" "$(_clone_drift_field "$line" commits)" "4"
assert_eq "  oldest epoch parsed from ISO" "$(_clone_drift_field "$line" oldest_epoch)" \
    "$(date -d 2026-07-27T01:31:50Z +%s)"

# Negative control for the fallback: when the API ALSO fails we have
# already observed head != tip, so the answer must stay `behind` with an
# unmeasured margin — never `unknown` (we saw the inequality) and never
# `up-to-date`.
cat > "$WORK/gh-fail" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$WORK/gh-fail"
_CLONE_DRIFT_GH_BIN="$WORK/gh-fail"
line=$(_clone_drift_probe "$C" dev)
assert_eq "API fallback fails -> still behind" "$(verdict_of "$line")" "behind"
assert_eq "  margin reported as unknown, not 0" "$(_clone_drift_field "$line" commits)" "unknown"

# A clone whose origin URL yields no owner/repo, with the tip absent
# locally, cannot be judged at all — and must say so.
_CD_FAKE_SLUG=""
line=$(_clone_drift_probe "$C" dev)
assert_eq "no parseable slug + no local tip -> unknown" "$(verdict_of "$line")" "unknown"
assert_contains "  reason names the cause" "$line" "reason=no_origin_slug"

# Release both seams.
_CD_FAIL_CATFILE=0
_CD_FAKE_SLUG=""
_CLONE_DRIFT_GH_BIN=""

echo "== _clone_drift_tick thresholds and record =="

STATE=$WORK/vstate; mkdir -p "$STATE"
export VERSION_STATE_DIR="$STATE"
export MONITOR_CLONE_DRIFT_ENABLED=true MONITOR_CLONE_DRIFT_BRANCH=dev

# Under BOTH thresholds -> no record.
C=$(build_fixture under 6 5)
export NEXUS_ROOT="$C"
export MONITOR_CLONE_DRIFT_COMMITS=5 MONITOR_CLONE_DRIFT_HOURS=100000
export NEXUS_TEST_NOW=$(( 1785000000 + 7 * 3600 ))
_clone_drift_tick
assert_no_file "1 commit behind, both thresholds slack -> no ask record" "$STATE/drift-clone"

# Commit threshold trips.
C=$(build_fixture overc 8 1)
export NEXUS_ROOT="$C"
export MONITOR_CLONE_DRIFT_COMMITS=5 MONITOR_CLONE_DRIFT_HOURS=100000
_clone_drift_tick
assert_file_exists "7 commits behind, commit threshold trips -> record" "$STATE/drift-clone"
assert_contains "  note carries the commit margin" \
    "$(cat "$STATE/drift-clone")" "behind|7|"

# Hour threshold trips on its own, with the commit margin well under.
rm -f "$STATE/drift-clone" "$STATE/drift-clone-surfaced"
C=$(build_fixture overh 6 5)
export NEXUS_ROOT="$C"
export MONITOR_CLONE_DRIFT_COMMITS=50
export MONITOR_CLONE_DRIFT_HOURS=24
# 100 h after the oldest undeployed commit (c6).
export NEXUS_TEST_NOW=$(( 1785000000 + 6 * 3600 + 100 * 3600 ))
_clone_drift_tick
assert_file_exists "1 commit behind but 100h stale -> hour threshold trips" "$STATE/drift-clone"

# Recovery clears the record.
rm -f "$STATE/drift-clone" "$STATE/drift-clone-surfaced"
C=$(build_fixture recovered 4 4)
export NEXUS_ROOT="$C"
export MONITOR_CLONE_DRIFT_COMMITS=1 MONITOR_CLONE_DRIFT_HOURS=1
: > "$STATE/drift-clone"
_clone_drift_tick
assert_no_file "clone caught up -> standing record cleared" "$STATE/drift-clone"

# `unknown` must PERSIST a record. An unseeable deployment state is an
# alarm; staying quiet is the bug.
rm -f "$STATE/drift-clone" "$STATE/drift-clone-surfaced"
export NEXUS_ROOT="$WORK/definitely-not-a-repo"
_clone_drift_tick
assert_file_exists "unknown -> ask record persisted (not silence)" "$STATE/drift-clone"
assert_contains "  record marks it undetermined" \
    "$(cat "$STATE/drift-clone")" "could-not-determine"

echo "== rendered emit text =="

rendered=$(_version_emit_section "$STATE" /some/root)
assert_contains "unknown renders as UNKNOWN, loudly" "$rendered" "DEPLOYMENT STATE UNKNOWN"
assert_not_contains "unknown NEVER renders as up to date" "$rendered" "up to date"

rm -f "$STATE"/drift-clone*
C=$(build_fixture render 8 1)
export NEXUS_ROOT="$C"
export MONITOR_CLONE_DRIFT_COMMITS=5 MONITOR_CLONE_DRIFT_HOURS=100000
unset NEXUS_TEST_NOW
_clone_drift_tick
rendered=$(_version_emit_section "$STATE" "$C")
assert_contains "behind renders the headline" "$rendered" "PRIMARY CLONE is BEHIND origin/dev"
assert_contains "behind names the deploy command for the measured ref (#1529)" "$rendered" "pull --ff-only origin dev"
assert_contains "behind names the branch as the operator's configuration" "$rendered" "monitor.integration_branch"
assert_contains "behind states the human-timed constraint" "$rendered" "human-timed action"

echo "== detection only: the clone is never mutated =="

C=$(build_fixture readonly 8 1)
export NEXUS_ROOT="$C"
before_head=$(git -C "$C" rev-parse HEAD)
before_refs=$(git -C "$C" for-each-ref --format='%(refname) %(objectname)' | sort | md5sum)
before_tree=$(git -C "$C" status --porcelain | md5sum)
rm -f "$STATE"/drift-clone*
_clone_drift_tick
assert_eq "HEAD unchanged by the check" "$(git -C "$C" rev-parse HEAD)" "$before_head"
assert_eq "no ref (incl. remote-tracking) was written" \
    "$(git -C "$C" for-each-ref --format='%(refname) %(objectname)' | sort | md5sum)" "$before_refs"
assert_eq "working tree untouched" "$(git -C "$C" status --porcelain | md5sum)" "$before_tree"

th_summary_and_exit
