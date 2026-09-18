#!/usr/bin/env bash
# monitor/watcher/test-ng-stranded-branches.sh — `ng stranded-branches`
# (your-org/nexus-code#1399): validated work pushed to a branch and never
# PR'd is invisible to every surface an orchestrator reads. The verb
# enumerates remote branches NOT merged into the integration branch, after a
# fetch, with no false negatives. Driven against a planted bare origin.
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG="$_test_dir/../ng"
PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
WORK=$(mktemp -d -t nexus-sb-XXXXXX); trap 'rm -rf "$WORK"' EXIT
# HERMETIC (your-org/nexus-code#1455). `ng` resolves its state dir through
# NEXUS_STATE_DIR -> NEXUS_ROOT -> config nexus.root -> script-relative, and its
# usage tap appends a row to whatever that resolves to. Pinning NEXUS_ROOT on
# ONE of four invocations (the first cut did) left the other three writing
# `monitor/.state/ng-usage.jsonl` into the INHERITED root — measured LEAK rc=0
# under `nexus-root-sensitivity.sh probe`, i.e. green while writing into the
# operator's live state. Both arms are pinned ONCE, for every child.
export NEXUS_ROOT="$WORK/nowhere"
export NEXUS_STATE_DIR="$WORK/state"; mkdir -p "$NEXUS_STATE_DIR"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
g() { git -c user.name=t -c user.email=t@e "$@"; }
# origin with dev + one merged branch + two unmerged (one old, one recent)
g init -q "$WORK/src"; cd "$WORK/src"
echo a > a; g add a; g commit -qm 'base'; g branch -M dev
g checkout -qb merged-work; echo m > m; g add m; g commit -qm 'merged work'; g checkout -q dev; g merge -q --no-ff merged-work -m 'merge merged-work'
g checkout -qb operator/w2-14-ccgate; echo c > c; g add c; g commit -qm 'the #1320 fix, skeptic-reviewed'; g checkout -q dev
g checkout -qb old/ancient; echo o > o; g add o; GIT_AUTHOR_DATE='2026-01-01T00:00:00' GIT_COMMITTER_DATE='2026-01-01T00:00:00' g commit -qm 'ancient'; g checkout -q dev
g clone -q --bare "$WORK/src" "$WORK/origin.git"
g clone -q "$WORK/origin.git" "$WORK/clone"; cd "$WORK/clone"
echo "=== enumerates unmerged remote branches after a fetch ==="
out=$(cd "$WORK/clone" && bash "$NG" stranded-branches --base dev 2>&1); rc=$?
grep -q '^operator/w2-14-ccgate' <<<"$out" && ok "the un-PR'd, unmerged branch is listed" || bad "unmerged branch missing: $out"
grep -q '^old/ancient' <<<"$out" && ok "an old unmerged branch is listed too (no date filter by default)" || bad "old branch missing"
! grep -q '^merged-work' <<<"$out" && ok "a MERGED branch is NOT listed (ancestor of dev)" || bad "merged branch listed"
grep -q 'stranded: 2 branch' <<<"$out" && ok "the total names the set size (2)" || bad "total wrong: $(grep stranded <<<"$out")"
grep -q 'skeptic-reviewed' <<<"$out" && ok "each row carries the last-commit subject" || bad "subject missing"
echo "=== --since filters by last-commit date ==="
out=$(cd "$WORK/clone" && bash "$NG" stranded-branches --base dev --since 2026-06-01 2>&1)
grep -q '^operator/w2-14-ccgate' <<<"$out" && ! grep -q '^old/ancient' <<<"$out" && ok "--since keeps the recent branch and drops the ancient one" || bad "--since filter wrong: $out"
echo "=== POTENCY: a branch pushed AFTER the clone's last fetch is seen (the verb fetches) ==="
( cd "$WORK/src" && g checkout -qb late/pushed-after && echo l > l && g add l && g commit -qm 'pushed after the clone fetched' && g push -q "$WORK/origin.git" late/pushed-after ) >/dev/null 2>&1
out=$(cd "$WORK/clone" && bash "$NG" stranded-branches --base dev 2>&1)
grep -q '^late/pushed-after' <<<"$out" && ok "a branch pushed after the last fetch is listed — the verb fetched first" || bad "stale: the verb did not fetch ($out)"
echo "=== a bad base is refused, not read as 'nothing stranded' ==="
out=$(cd "$WORK/clone" && bash "$NG" stranded-branches --base no-such 2>&1); rc=$?
(( rc != 0 )) && grep -q 'no such ref' <<<"$out" && ok "an unknown base ref exits non-zero and says so" || bad "bad base not refused (rc=$rc)"
echo; echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }; exit 1
