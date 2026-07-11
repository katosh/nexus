#!/usr/bin/env bash
# Concurrency test for `monitor/upload-asset.sh` (your-org/nexus-code#329).
#
# Exercises the lock-free-staging + flock-elected-batch-manager model:
#   A) ~10 concurrent uploads → every printed URL pins a SHA that EXISTS on
#      the remote AND the file is present in that commit (the dangling-SHA
#      invariant from your-org/your-nexus#244), all N files land, and the
#      push count is never worse than serial (regression guard; the burst
#      typically amortises to far fewer than N pushes).
#   B) Deterministic batch drain: 9 pre-staged requests + 1 live upload are
#      drained by a SINGLE manager in ONE push, and all 10 get result URLs.
#   C) Orphaned-marker recovery: a marker left behind by a (simulated) dead
#      manager is picked up and resolved by the next upload — the kernel-
#      backed flock takeover, observed through its effect.
#
# Run: bash monitor/watcher/test-upload-asset-concurrency.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy mirrors test-upload-asset-gitignore.sh: a local bare repo is the
# "asset remote", cloned into a fake nexus root; `git` is PATH-stubbed to
# no-op `set-url` (so the script can't repoint origin at github.com) and to
# count `push` invocations, otherwise pass-through to real git so the actual
# plumbing (fetch/add/commit/push/rev-parse) runs for real.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_real_script="$_test_dir/../upload-asset.sh"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_le() {
    local label="$1" got="$2" ceil="$3"
    if (( got <= ceil )); then
        printf '  PASS: %s (%s <= %s)\n' "$label" "$got" "$ceil"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %s want <= %s\n' "$label" "$got" "$ceil" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

REAL_GIT=$(command -v git)
[[ -x "$REAL_GIT" ]] || { echo "git not on PATH; cannot run test" >&2; exit 2; }
command -v flock >/dev/null || { echo "flock not on PATH; cannot run test" >&2; exit 2; }

WORK=$(mktemp -d -t nexus-test-upload-conc-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

PUSH_COUNT_FILE="$WORK/push-count"

setup_fake_nexus() {
    FAKE_NEXUS="$WORK/nexus"
    BARE="$WORK/asset-repo.git"
    rm -rf "$FAKE_NEXUS" "$BARE"
    mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config"

    "$REAL_GIT" init --quiet --bare "$BARE"
    "$REAL_GIT" --git-dir="$BARE" symbolic-ref HEAD refs/heads/main

    local seed="$WORK/seed"
    rm -rf "$seed"
    "$REAL_GIT" clone --quiet "$BARE" "$seed" 2>/dev/null
    "$REAL_GIT" -C "$seed" \
        -c user.name=test -c user.email=test@example.com \
        commit --quiet --allow-empty -m "seed"
    "$REAL_GIT" -C "$seed" branch -M main 2>/dev/null || true
    "$REAL_GIT" -C "$seed" push --quiet origin HEAD:main
    rm -rf "$seed"

    cp "$_real_script" "$FAKE_NEXUS/monitor/upload-asset.sh"
    chmod +x "$FAKE_NEXUS/monitor/upload-asset.sh"

    cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "fake-token-for-tests"
STUB
    chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

    cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.asset_repo)    printf 'fake-owner/fake-repo' ;;
    github.repo)          printf 'fake-owner/fake-repo' ;;
    github.bot_git_name)  printf 'test-bot[bot]' ;;
    github.bot_git_email) printf 'test-bot[bot]@users.noreply.github.com' ;;
    *)                    printf '%s' "${2-}" ;;
esac
STUB
    chmod +x "$FAKE_NEXUS/config/load.sh"

    "$REAL_GIT" clone --quiet "$BARE" "$FAKE_NEXUS/assets"
    : > "$PUSH_COUNT_FILE"
}

# git stub: no-op `set-url`, count `push`, optionally inject a late-arriving
# marker on the manager's first `add` (Test E), else pass-through.
#
# Late-marker injection (gated on $NEXUS_TEST_INJECT_REQ_DST + a once-only
# sentinel): publishes a NEW .req into the staging dir during the manager's
# first `add` — i.e. strictly AFTER the manager has already snapshotted its
# batch — so the test can deterministically exercise the after-snapshot
# late-arrival path that Test A only hits non-deterministically.
#
# Push fault injection (your-org/nexus-code#… fail-loud + verify-before-return):
#   NEXUS_TEST_PUSH_FAIL=1     count the push then exit NON-zero — the remote
#                             rejects; exercises the fail-loud retry ceiling.
#   NEXUS_TEST_PUSH_SWALLOW=1  count the push then exit 0 WITHOUT pushing — the
#                             commit stays local, SHA never reaches the remote;
#                             exercises verify-before-return (a push that
#                             *reports* success but didn't land, the #261 shape).
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/git" <<STUB
#!/usr/bin/env bash
_is_push=0; _is_seturl=0; _is_add=0
for arg in "\$@"; do
    [[ "\$arg" == "set-url" ]] && _is_seturl=1
    [[ "\$arg" == "push" ]] && _is_push=1
    [[ "\$arg" == "add" ]] && _is_add=1
done
if (( _is_add )) && [[ -n "\${NEXUS_TEST_INJECT_REQ_DST:-}" ]] \\
   && [[ ! -e "\${NEXUS_TEST_INJECT_SENTINEL:-/nonexistent}" ]]; then
    cp "\$NEXUS_TEST_INJECT_REQ_SRC" "\$NEXUS_TEST_INJECT_REQ_DST"
    : > "\$NEXUS_TEST_INJECT_SENTINEL"
fi
(( _is_seturl )) && exit 0
if (( _is_push )); then
    printf 'x' >> "$PUSH_COUNT_FILE"
    [[ -n "\${NEXUS_TEST_PUSH_FAIL:-}" ]] && { echo "stub: simulated push failure" >&2; exit 1; }
    [[ -n "\${NEXUS_TEST_PUSH_SWALLOW:-}" ]] && exit 0
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$STUB_DIR/git"

run_upload() {
    # run_upload <local_file> [extra args...] — sets stdout/stderr/rc globals.
    local _local="$1"; shift
    local _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    env -u NEXUS_ASSET_REPO -u NEXUS_CONFIG -u NEXUS_ROOT \
        PATH="$STUB_DIR:$PATH" \
        "$FAKE_NEXUS/monitor/upload-asset.sh" "$_local" "$@" \
        >"$_out_tmp" 2>"$_err_tmp"
    rc=$?
    stdout=$(<"$_out_tmp"); stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
}

push_count() { wc -c < "$PUSH_COUNT_FILE" | tr -d ' '; }

# Assert a printed URL satisfies the dangling-SHA invariant against the bare:
# its SHA is a real commit on the remote AND the path exists in that commit.
assert_url_resolves() {
    local label="$1" url="$2"
    # https://github.com/<repo>/{raw,blob}/<sha>/<repo_path>
    local rest sha rp
    rest="${url#https://github.com/fake-owner/fake-repo/}"
    rest="${rest#raw/}"; rest="${rest#blob/}"
    sha="${rest%%/*}"
    rp="${rest#*/}"
    if [[ -z "$sha" || -z "$rp" || "$sha" == "$rest" ]]; then
        printf '  FAIL: %s — unparseable URL %q\n' "$label" "$url" >&2
        FAIL=$(( FAIL + 1 )); return
    fi
    if ! "$REAL_GIT" --git-dir="$BARE" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        printf '  FAIL: %s — SHA %s not a commit on remote (DANGLING)\n' "$label" "$sha" >&2
        FAIL=$(( FAIL + 1 )); return
    fi
    if ! "$REAL_GIT" --git-dir="$BARE" cat-file -e "${sha}:${rp}" 2>/dev/null; then
        printf '  FAIL: %s — path %s absent in commit %s\n' "$label" "$rp" "$sha" >&2
        FAIL=$(( FAIL + 1 )); return
    fi
    printf '  PASS: %s (%s @ %s)\n' "$label" "$rp" "${sha:0:8}"; PASS=$(( PASS + 1 ))
}

# =========================================================================
echo '=== Test A: 10 concurrent uploads — no dangling SHA, all land, push count <= N ==='
setup_fake_nexus
N=10
declare -a PIDS=() OUTS=()
for i in $(seq 1 "$N"); do
    payload="$WORK/figA_$i.png"
    printf 'fig-A-%s-bytes\n' "$i" > "$payload"
    out="$WORK/outA_$i.url"
    env -u NEXUS_ASSET_REPO -u NEXUS_CONFIG -u NEXUS_ROOT \
        PATH="$STUB_DIR:$PATH" \
        "$FAKE_NEXUS/monitor/upload-asset.sh" "$payload" --repo-path "conc/figA_$i.png" \
        >"$out" 2>"$WORK/errA_$i.log" &
    PIDS+=("$!"); OUTS+=("$out")
done
all_ok=0
for idx in "${!PIDS[@]}"; do
    if wait "${PIDS[$idx]}"; then :; else all_ok=1; fi
done
assert_eq "all $N concurrent uploads exited 0" "$all_ok" "0"

for i in $(seq 1 "$N"); do
    url=$(<"$WORK/outA_$i.url")
    assert_url_resolves "url[$i] resolves on remote (no dangling SHA)" "$url"
done

# All N files present on the bare's final main?
final_sha=$("$REAL_GIT" --git-dir="$BARE" rev-parse main)
present=0
for i in $(seq 1 "$N"); do
    "$REAL_GIT" --git-dir="$BARE" cat-file -e "${final_sha}:assets/conc/figA_$i.png" 2>/dev/null \
        && present=$(( present + 1 ))
done
assert_eq "all $N files present on final main" "$present" "$N"

pcA=$(push_count)
echo "  (info) push count for $N concurrent uploads: $pcA"
assert_le "push count never worse than serial" "$pcA" "$N"

# =========================================================================
echo '=== Test B: 9 pre-staged + 1 live upload → ONE push drains all 10 ==='
setup_fake_nexus
STAGING="$FAKE_NEXUS/assets.staging"
mkdir -p "$STAGING"
for i in $(seq 1 9); do
    base="$STAGING/req.preB$i"
    printf 'pre-staged-B-%s\n' "$i" > "$base.blob"
    {
        printf 'repo_path\tassets/batch/preB_%s.txt\n' "$i"
        printf 'shape\tpin\n'
        printf 'message\tpre-staged %s\n' "$i"
    } > "$base.req"
done
payload="$WORK/liveB.txt"; printf 'live-B\n' > "$payload"
run_upload "$payload" --repo-path "batch/liveB.txt"
assert_eq "live upload exit 0" "$rc" "0"
pcB=$(push_count)
assert_eq "exactly ONE push drained the whole batch" "$pcB" "1"

# All 10 (9 pre-staged + 1 live) on final main, and each pre-staged marker
# was converted to a result file then cleared.
final_shaB=$("$REAL_GIT" --git-dir="$BARE" rev-parse main)
landed=0
"$REAL_GIT" --git-dir="$BARE" cat-file -e "${final_shaB}:assets/batch/liveB.txt" 2>/dev/null \
    && landed=$(( landed + 1 ))
for i in $(seq 1 9); do
    "$REAL_GIT" --git-dir="$BARE" cat-file -e "${final_shaB}:assets/batch/preB_$i.txt" 2>/dev/null \
        && landed=$(( landed + 1 ))
done
assert_eq "all 10 batch files landed in one push" "$landed" "10"
remaining_markers=$(find "$STAGING" -name '*.req' | wc -l | tr -d ' ')
assert_eq "all markers drained (none left)" "$remaining_markers" "0"
assert_url_resolves "live upload URL resolves" "$stdout"

# =========================================================================
echo '=== Test C: orphaned marker (dead manager) is recovered by next upload ==='
setup_fake_nexus
STAGING="$FAKE_NEXUS/assets.staging"
mkdir -p "$STAGING"
# Simulate a manager that died before draining this marker: blob + marker
# present, NO result file, lock free.
orphan="$STAGING/req.orphanC"
printf 'orphaned-payload\n' > "$orphan.blob"
{
    printf 'repo_path\tassets/recover/orphanC.txt\n'
    printf 'shape\tpin\n'
    printf 'message\torphan recovery\n'
} > "$orphan.req"

payload="$WORK/liveC.txt"; printf 'live-C\n' > "$payload"
run_upload "$payload" --repo-path "recover/liveC.txt"
assert_eq "recovery upload exit 0" "$rc" "0"
final_shaC=$("$REAL_GIT" --git-dir="$BARE" rev-parse main)
recovered=0
"$REAL_GIT" --git-dir="$BARE" cat-file -e "${final_shaC}:assets/recover/orphanC.txt" 2>/dev/null \
    && recovered=$(( recovered + 1 ))
"$REAL_GIT" --git-dir="$BARE" cat-file -e "${final_shaC}:assets/recover/liveC.txt" 2>/dev/null \
    && recovered=$(( recovered + 1 ))
assert_eq "orphaned + live both landed" "$recovered" "2"
assert_url_resolves "recovery upload URL resolves" "$stdout"
remaining_c=$(find "$STAGING" -name '*.req' | wc -l | tr -d ' ')
assert_eq "orphan marker cleared after recovery" "$remaining_c" "0"

# =========================================================================
echo '=== Test D: post-push partial-result death → no duplicate push, orphans resolve ==='
# The hardest interleaving (skeptic-flagged): a manager pushed N requests'
# content, then died BEFORE writing their result files. The next upload must
# NOT re-push the already-landed content (idempotency) yet must still emit
# resolving URLs for the orphaned markers.
setup_fake_nexus
STAGING="$FAKE_NEXUS/assets.staging"
# 1. Land 3 requests for real (their content is now on the bare's main).
for i in $(seq 1 3); do
    p="$WORK/preD_$i.txt"; printf 'pushed-D-%s\n' "$i" > "$p"
    run_upload "$p" --repo-path "deadmgr/preD_$i.txt"
    assert_eq "pre-push upload $i exit 0" "$rc" "0"
done
# 2. Simulate post-push/pre-result death: re-publish their markers (same
#    content + path) with NO result files, as a dead manager would leave them.
mkdir -p "$STAGING"
for i in $(seq 1 3); do
    base="$STAGING/req.deadD$i"
    printf 'pushed-D-%s\n' "$i" > "$base.blob"
    {
        printf 'repo_path\tassets/deadmgr/preD_%s.txt\n' "$i"
        printf 'shape\tpin\n'
        printf 'message\tre-drain orphan %s\n' "$i"
    } > "$base.req"
done
# 3. Reset the push counter; run a fresh live upload that re-drains the orphans.
: > "$PUSH_COUNT_FILE"
payload="$WORK/liveD.txt"; printf 'live-D\n' > "$payload"
run_upload "$payload" --repo-path "deadmgr/liveD.txt"
assert_eq "recovery upload exit 0" "$rc" "0"
pcD=$(push_count)
assert_eq "exactly ONE push (orphans unchanged → not re-pushed)" "$pcD" "1"
# Each orphan got a result URL written, and each resolves on the remote.
for i in $(seq 1 3); do
    url_file=$(find "$STAGING" -name 'req.deadD'"$i"'.url' | head -1)
    if [[ -n "$url_file" && -f "$url_file" ]]; then
        assert_url_resolves "orphan $i URL written & resolves" "$(<"$url_file")"
    else
        printf '  FAIL: orphan %s has no result file after re-drain\n' "$i" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done
remaining_d=$(find "$STAGING" -name '*.req' | wc -l | tr -d ' ')
assert_eq "all orphan markers cleared after re-drain" "$remaining_d" "0"

# =========================================================================
echo '=== Test E: marker arriving AFTER the snapshot is drained by the next election ==='
# Snapshot isolation + no-orphan: a marker published after the manager
# snapshotted its batch is NOT drained by that manager, but IS drained by the
# next election (its own stager, modelled here by a follow-up upload).
setup_fake_nexus
STAGING="$FAKE_NEXUS/assets.staging"
mkdir -p "$STAGING"
LATE_BASE="$STAGING/req.lateE"
printf 'late-arrival-E\n' > "$LATE_BASE.blob"          # blob pre-exists; .req injected on first add
{
    printf 'repo_path\tassets/late/lateE.txt\n'
    printf 'shape\tpin\n'
    printf 'message\tlate arrival\n'
} > "$WORK/lateE.req"
SENTINEL="$WORK/inject-done-E"; rm -f "$SENTINEL"
payload="$WORK/liveE.txt"; printf 'live-E\n' > "$payload"
NEXUS_TEST_INJECT_REQ_SRC="$WORK/lateE.req" \
NEXUS_TEST_INJECT_REQ_DST="$LATE_BASE.req" \
NEXUS_TEST_INJECT_SENTINEL="$SENTINEL" \
    run_upload "$payload" --repo-path "late/liveE.txt"
assert_eq "first upload exit 0 (late marker injected mid-drain)" "$rc" "0"
assert_eq "injection actually fired" "$([ -f "$SENTINEL" ] && echo 1 || echo 0)" "1"
# The late marker was NOT in the first manager's snapshot → survives, unprocessed.
assert_eq "late marker survived first manager (snapshot isolation)" \
    "$(find "$STAGING" -name 'req.lateE.req' | wc -l | tr -d ' ')" "1"
assert_eq "late marker has no result yet" \
    "$([ -f "$LATE_BASE.url" ] && echo 1 || echo 0)" "0"
# The next election drains it — no marker orphaned, no hang.
payload2="$WORK/liveE2.txt"; printf 'live-E2\n' > "$payload2"
run_upload "$payload2" --repo-path "late/liveE2.txt"
assert_eq "second upload exit 0" "$rc" "0"
final_shaE=$("$REAL_GIT" --git-dir="$BARE" rev-parse main)
assert_eq "late marker drained by next election (file on remote)" \
    "$("$REAL_GIT" --git-dir="$BARE" cat-file -e "${final_shaE}:assets/late/lateE.txt" 2>/dev/null && echo 1 || echo 0)" "1"
assert_eq "late marker cleared after next election" \
    "$(find "$STAGING" -name 'req.lateE.req' | wc -l | tr -d ' ')" "0"

# =========================================================================
echo '=== Test F: push failure → fail LOUD, no URL on stdout, marker left staged ==='
# A push the remote rejects must NOT yield a URL. The script retries to the
# ceiling, then exits non-zero with NOTHING on stdout — the caller (ng wrap-up,
# a figure-posting worker) treats a non-zero upload as failure, so a broken
# embed never lands in a GitHub comment. The staged marker+blob survive for a
# later (recovered) drain.
setup_fake_nexus
STAGING="$FAKE_NEXUS/assets.staging"
payload="$WORK/figF.png"; printf 'fig-F-bytes\n' > "$payload"
_out_tmp=$(mktemp); _err_tmp=$(mktemp)
env -u NEXUS_ASSET_REPO -u NEXUS_CONFIG -u NEXUS_ROOT \
    NEXUS_TEST_PUSH_FAIL=1 NEXUS_UPLOAD_PUSH_RETRIES=2 \
    PATH="$STUB_DIR:$PATH" \
    "$FAKE_NEXUS/monitor/upload-asset.sh" "$payload" --repo-path "faults/figF.png" \
    >"$_out_tmp" 2>"$_err_tmp"
rcF=$?
stdoutF=$(<"$_out_tmp"); rm -f "$_out_tmp" "$_err_tmp"
assert_eq "push-failure upload exits non-zero" "$([ "$rcF" -ne 0 ] && echo 1 || echo 0)" "1"
assert_eq "push-failure emits NO URL on stdout" "$stdoutF" ""
# The file must not be on the remote (nothing landed).
final_shaF=$("$REAL_GIT" --git-dir="$BARE" rev-parse main)
assert_eq "nothing landed on remote after push failure" \
    "$("$REAL_GIT" --git-dir="$BARE" cat-file -e "${final_shaF}:assets/faults/figF.png" 2>/dev/null && echo 1 || echo 0)" "0"
# Marker + blob survive for a recovered drain (no result file written).
assert_eq "marker left staged after push failure" \
    "$(find "$STAGING" -name '*.req' | wc -l | tr -d ' ')" "1"
assert_eq "no result URL file written after push failure" \
    "$(find "$STAGING" -name '*.url' | wc -l | tr -d ' ')" "0"

# =========================================================================
echo '=== Test G: verify-before-return catches a push that reported success but did not land ==='
# The #261 shape: `git push` returns 0 yet the commit is absent from the remote
# (swallowed by contention / a lying transport). Without a runtime check the
# script would pin that local-only SHA and emit a dangling URL. verify-before-
# return re-reads the remote tip, finds the SHA is NOT an ancestor, and fails
# LOUD instead — no URL, marker preserved.
setup_fake_nexus
STAGING="$FAKE_NEXUS/assets.staging"
payload="$WORK/figG.png"; printf 'fig-G-bytes\n' > "$payload"
_out_tmp=$(mktemp); _err_tmp=$(mktemp)
env -u NEXUS_ASSET_REPO -u NEXUS_CONFIG -u NEXUS_ROOT \
    NEXUS_TEST_PUSH_SWALLOW=1 \
    PATH="$STUB_DIR:$PATH" \
    "$FAKE_NEXUS/monitor/upload-asset.sh" "$payload" --repo-path "faults/figG.png" \
    >"$_out_tmp" 2>"$_err_tmp"
rcG=$?
stdoutG=$(<"$_out_tmp"); stderrG=$(<"$_err_tmp"); rm -f "$_out_tmp" "$_err_tmp"
assert_eq "swallowed-push upload exits non-zero" "$([ "$rcG" -ne 0 ] && echo 1 || echo 0)" "1"
assert_eq "swallowed-push emits NO URL on stdout (no dangling embed)" "$stdoutG" ""
assert_eq "failure names verify-before-return" \
    "$(printf '%s' "$stderrG" | grep -c 'verify-before-return FAILED')" "1"
assert_eq "swallowed-push wrote no result URL file" \
    "$(find "$STAGING" -name '*.url' | wc -l | tr -d ' ')" "0"

# =========================================================================
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
