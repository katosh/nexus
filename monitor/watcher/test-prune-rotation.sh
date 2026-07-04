#!/usr/bin/env bash
# Tests for the telemetry-file rotation in prune_archive
# (your-org/your-nexus#180 item R2; _prune_rotate_if_oversized in
# main.sh).
#
# Strategy (mirrors test-emit-gate.sh): run `main.sh --once` against a
# temp NEXUS_ROOT with stubbed gh/tmux/mint-token, tiny rotation caps
# via env, and pre-seeded oversized telemetry files. prune_archive is a
# registered scheduler task with next_fire=0, so the --once drain
# pipeline fires it exactly once.
#
# Asserts:
#   - watcher-scheduler.jsonl over its cap → renamed to <name>.<epoch>,
#     content preserved in the archive.
#   - watcher.log over the state cap → copytruncate: the LIVE file
#     keeps its inode (the launcher's O_APPEND redirect depends on it)
#     and ends near-empty; the archive holds the old content.
#   - functional-check.tsv over the cap → renamed.
#   - an under-cap file (action-log.jsonl) is NOT rotated.
#   - a stale rotated archive (mtime 10 days back) is pruned when its
#     live file rotates.
#   - caps = 0 disable rotation entirely.
#
# Run: bash monitor/watcher/test-prune-rotation.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_main_sh="$_test_dir/main.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d -t nexus-prune-rotation-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

mock_bin="$WORK/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/tmux" <<'TMUX'
#!/bin/bash
exit 1
TMUX
cat > "$mock_bin/gh" <<'GH'
#!/bin/bash
echo '{"data":{"search":{"nodes":[]}}}'
exit 0
GH
cat > "$mock_bin/mint-token.sh" <<'MINT'
#!/bin/bash
printf 'fake-test-token\n'
MINT
chmod +x "$mock_bin/tmux" "$mock_bin/gh" "$mock_bin/mint-token.sh"
PATH_STUB="$mock_bin"
for d in /usr/local/bin /usr/bin /bin; do
    [[ -d "$d" ]] && PATH_STUB="${PATH_STUB}:${d}"
done

# seed <path> <n-lines> <marker> — writes ~n recognisable lines.
seed() {
    local path="$1" n="$2" marker="$3" i
    : > "$path"
    for (( i = 0; i < n; i++ )); do
        printf '%s line %04d\n' "$marker" "$i" >> "$path"
    done
}

# run_once <nexus_root> <sched_cap> <state_cap>
run_once() {
    local root="$1" sched_cap="$2" state_cap="$3"
    PATH="$PATH_STUB" \
    MINT_TOKEN_BIN="$mock_bin/mint-token.sh" \
    MINT_JWT_BIN="$mock_bin/mint-token.sh" \
    NEXUS_ROOT="$root" \
    MONITOR_INTERVAL=0 \
    MONITOR_REPO=test/repo \
    MONITOR_USER_LOGIN=operator \
    MONITOR_TARGET=nonexistent-test-target \
    MONITOR_AUTO_UNSTICK=false \
    MONITOR_DELIVERIES_ASSET_ENABLED=false \
    MONITOR_DELIVERIES_BOT_MENTION_ENABLED=false \
    MONITOR_MENTIONS_ENABLED=false \
    MONITOR_RATELIMIT_PROBE=false \
    MONITOR_GRAPHQL_THRESHOLD=0 \
    MONITOR_BOT_LOGIN= \
    MONITOR_CC_UPDATE_INTERVAL_SECONDS=0 \
    AGENT_DEAD_THRESHOLD=999 \
    AGENT_MISSING_RESPAWN_DELAY=999 \
    MONITOR_SCHEDULER_LOG_MAX_BYTES="$sched_cap" \
    MONITOR_STATE_LOG_MAX_BYTES="$state_cap" \
    bash "$_main_sh" --once >>"$WORK/run.log" 2>&1
}

# ---- Scenario 1: oversized files rotate; under-cap file does not ------

echo '=== rotation: oversized telemetry files rotate, under-cap stays ==='
NEXUS_ROOT="$WORK/nexus"
STATE="$NEXUS_ROOT/monitor/.state"
mkdir -p "$STATE" "$NEXUS_ROOT/reports" "$NEXUS_ROOT/work"

seed "$STATE/watcher-scheduler.jsonl" 200 SCHEDROW      # ~3.4 KB
seed "$STATE/watcher.log"             200 OLDLOGLINE
seed "$STATE/functional-check.tsv"    200 FCHECKROW
seed "$STATE/action-log.jsonl"          5 ACTROW        # well under cap
# Stale rotated archive that must be pruned when the live file rotates.
seed "$STATE/watcher-scheduler.jsonl.1700000000" 10 STALEARCH
touch -d '10 days ago' "$STATE/watcher-scheduler.jsonl.1700000000"
# Capture the live watcher.log inode — copytruncate must preserve it.
log_inode_before=$(stat -c '%i' "$STATE/watcher.log")

run_once "$NEXUS_ROOT" 1000 1000

# Scheduler JSONL: renamed away; an archive carries the content. The
# --once run itself re-creates the live file with fresh telemetry rows.
sched_archives=$(find "$STATE" -maxdepth 1 -name 'watcher-scheduler.jsonl.*' \
    ! -name '*.1700000000' | wc -l | tr -d ' ')
if (( sched_archives >= 1 )); then
    pass "scheduler jsonl rotated to an epoch archive"
    arch=$(find "$STATE" -maxdepth 1 -name 'watcher-scheduler.jsonl.*' \
        ! -name '*.1700000000' | head -1)
    grep -q 'SCHEDROW line 0000' "$arch" \
        && pass "archive preserves the rotated content" \
        || fail "archive missing seeded content"
else
    fail "no scheduler jsonl archive created"
fi
if [[ -f "$STATE/watcher-scheduler.jsonl" ]]; then
    grep -q SCHEDROW "$STATE/watcher-scheduler.jsonl" \
        && fail "live scheduler jsonl still holds pre-rotation rows" \
        || pass "live scheduler jsonl is fresh (no pre-rotation rows)"
else
    pass "live scheduler jsonl renamed away (recreated on next write)"
fi

# Stale archive pruned.
[[ ! -f "$STATE/watcher-scheduler.jsonl.1700000000" ]] \
    && pass "stale rotated archive (10d) pruned" \
    || fail "stale rotated archive survived"

# watcher.log: copytruncate — same inode, near-empty live file,
# archive holds old content. (log() is stderr-only since nexus-code
# PR 239, and this test redirects stderr to run.log, so nothing
# re-fills watcher.log after the truncate.)
log_inode_after=$(stat -c '%i' "$STATE/watcher.log" 2>/dev/null || echo MISSING)
[[ "$log_inode_after" == "$log_inode_before" ]] \
    && pass "watcher.log keeps its inode (copytruncate)" \
    || fail "watcher.log inode changed ($log_inode_before -> $log_inode_after)"
log_size_after=$(stat -c '%s' "$STATE/watcher.log" 2>/dev/null || echo 99999)
(( log_size_after < 1000 )) \
    && pass "watcher.log truncated below the cap (size=$log_size_after)" \
    || fail "watcher.log not truncated (size=$log_size_after)"
log_arch=$(find "$STATE" -maxdepth 1 -name 'watcher.log.*' | head -1)
if [[ -n "$log_arch" ]] && grep -q 'OLDLOGLINE line 0000' "$log_arch"; then
    pass "watcher.log archive preserves old content"
else
    fail "watcher.log archive missing or incomplete"
fi

# functional-check.tsv rotated.
fcheck_arch=$(find "$STATE" -maxdepth 1 -name 'functional-check.tsv.*' | wc -l | tr -d ' ')
(( fcheck_arch >= 1 )) \
    && pass "functional-check.tsv rotated" \
    || fail "functional-check.tsv not rotated"

# Under-cap action-log untouched.
act_arch=$(find "$STATE" -maxdepth 1 -name 'action-log.jsonl.*' | wc -l | tr -d ' ')
if (( act_arch == 0 )) && grep -q 'ACTROW line 0000' "$STATE/action-log.jsonl"; then
    pass "under-cap action-log.jsonl not rotated"
else
    fail "under-cap action-log.jsonl was rotated (archives=$act_arch)"
fi

# ---- Scenario 2: caps = 0 disable rotation -----------------------------

echo '=== caps=0: rotation disabled entirely ==='
NEXUS_ROOT2="$WORK/nexus2"
STATE2="$NEXUS_ROOT2/monitor/.state"
mkdir -p "$STATE2" "$NEXUS_ROOT2/reports" "$NEXUS_ROOT2/work"
seed "$STATE2/watcher-scheduler.jsonl" 200 SCHEDROW
seed "$STATE2/watcher.log"             200 OLDLOGLINE

run_once "$NEXUS_ROOT2" 0 0

arch2=$(find "$STATE2" -maxdepth 1 \( -name 'watcher-scheduler.jsonl.*' -o -name 'watcher.log.*' \) | wc -l | tr -d ' ')
(( arch2 == 0 )) \
    && pass "no archives created with caps=0" \
    || fail "rotation fired despite caps=0 (archives=$arch2)"
grep -q 'OLDLOGLINE line 0000' "$STATE2/watcher.log" \
    && pass "watcher.log untouched with caps=0" \
    || fail "watcher.log modified despite caps=0"

# ---- Scenarios 3-5: bounded, name-based DIFF_DIR prune (nexus-code#402) -
#
# The pre-#402 sweep was `find "$DIFF_DIR" ... -mtime "+RETENTION_DAYS"
# -delete`, which stat-scanned EVERY file (O(total files); ~12 min on a
# 13,933-file NFS dir) and — running in the SYNC scheduler phase —
# stalled the heartbeat into a supervisor-driven crash-loop. The fix
# (`_prune_diffs_bounded`) prunes by the sortable-ts FILENAME (one
# readdir, no per-file stat) under two bounds: an age cutoff derived
# from the embedded date, and a hard MONITOR_DIFF_MAX_FILES count cap,
# with at most MONITOR_DIFF_PRUNE_MAX_PER_RUN deletions per run.
#
# Each scenario below is falsifiable against the OLD impl:
#   S3 seeds old-DATED files with RECENT mtime → old `-mtime` keeps them
#      (mtime young), the fix deletes them (name-date old).
#   S4/S5 seed thousands of in-retention files → old impl (no count cap)
#      keeps them all, the fix caps/throttles.

# seed_diffs <dir> <date-prefix YYYY-MM-DD> <n> — n empty archives named
# <prefix>_NNNNNN.md, all with the current (recent) mtime.
seed_diffs() {
    local dir="$1" pfx="$2" n="$3" i
    mkdir -p "$dir"
    for (( i = 0; i < n; i++ )); do
        : > "$dir/${pfx}_$(printf '%06d' "$i").md"
    done
}
count_md() {  # count_md <dir> <glob>
    find "$1" -maxdepth 1 -name "$2" 2>/dev/null | wc -l | tr -d ' '
}

# run_diff_prune <nexus_root> <retention_days> <max_files> <max_per_run>
run_diff_prune() {
    local root="$1" ret="$2" maxf="$3" maxrun="$4"
    DIFF_RETENTION_DAYS="$ret" \
    MONITOR_DIFF_MAX_FILES="$maxf" \
    MONITOR_DIFF_PRUNE_MAX_PER_RUN="$maxrun" \
    run_once "$root" 1000000 1000000
}

# ---- Scenario 3: age prune keys off the FILENAME date, not mtime ------
echo '=== diff-prune: age cutoff uses the embedded filename date ==='
NEXUS_ROOT3="$WORK/nexus3"
DIFF3="$NEXUS_ROOT3/monitor/.state/diffs"
mkdir -p "$NEXUS_ROOT3/monitor/.state" "$NEXUS_ROOT3/reports" "$NEXUS_ROOT3/work"
seed_diffs "$DIFF3" 2020-01-01 50      # ancient date, recent mtime → must go
seed_diffs "$DIFF3" 2099-01-01 10      # far-future date → always in-retention

run_diff_prune "$NEXUS_ROOT3" 7 20000 0

old3=$(count_md "$DIFF3" '2020-01-01_*.md')
keep3=$(count_md "$DIFF3" '2099-01-01_*.md')
(( old3 == 0 )) \
    && pass "old-dated archives pruned despite recent mtime (name-based age)" \
    || fail "old-dated archives survived (remaining=$old3) — sweep still mtime-based?"
(( keep3 == 10 )) \
    && pass "in-retention archives untouched by age prune" \
    || fail "in-retention archives wrongly pruned (remaining=$keep3/10)"

# ---- Scenario 4: MONITOR_DIFF_MAX_FILES count cap bounds growth --------
echo '=== diff-prune: count cap force-deletes the oldest beyond the cap ==='
NEXUS_ROOT4="$WORK/nexus4"
DIFF4="$NEXUS_ROOT4/monitor/.state/diffs"
mkdir -p "$NEXUS_ROOT4/monitor/.state" "$NEXUS_ROOT4/reports" "$NEXUS_ROOT4/work"
# 5000 in-retention (future-dated) files: age prune can NEVER remove
# them, so only the count cap can. Old impl leaves all 5000.
seed_diffs "$DIFF4" 2099-01-01 5000

run_diff_prune "$NEXUS_ROOT4" 7 3000 0     # cap 3000, per-run unbounded

keep4=$(count_md "$DIFF4" '2099-01-01_*.md')
(( keep4 == 3000 )) \
    && pass "count cap trimmed 5000 in-retention archives down to the 3000 cap" \
    || fail "count cap not enforced (2099 survivors=$keep4, expected 3000)"

# ---- Scenario 5: MONITOR_DIFF_PRUNE_MAX_PER_RUN bounds per-run cost ----
echo '=== diff-prune: per-run deletion bound throttles a large backlog ==='
NEXUS_ROOT5="$WORK/nexus5"
DIFF5="$NEXUS_ROOT5/monitor/.state/diffs"
mkdir -p "$NEXUS_ROOT5/monitor/.state" "$NEXUS_ROOT5/reports" "$NEXUS_ROOT5/work"
seed_diffs "$DIFF5" 2099-01-01 3000        # 2000 over the cap below

run_diff_prune "$NEXUS_ROOT5" 7 1000 500   # cap 1000, but ≤500 deletes/run

keep5=$(count_md "$DIFF5" '2099-01-01_*.md')
total5=$(count_md "$DIFF5" '*.md')
# One run deletes at most 500, so ≥2500 of the cohort survive...
(( keep5 >= 2500 )) \
    && pass "per-run bound honoured (≤500 deleted this run; survivors=$keep5)" \
    || fail "per-run bound exceeded (survivors=$keep5, expected ≥2500)"
# ...and the dir is still OVER the cap — a backlog drains over multiple
# 600 s runs, never in one heartbeat-stalling sweep.
(( total5 > 1000 )) \
    && pass "backlog left over-cap after one bounded run (total=$total5 > cap 1000)" \
    || fail "per-run bound failed to throttle (total=$total5 ≤ cap — drained in one run)"

# ---- summary -----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
