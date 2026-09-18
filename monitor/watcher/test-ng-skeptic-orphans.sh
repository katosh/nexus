#!/usr/bin/env bash
# test-ng-skeptic-orphans.sh — `ng skeptic-orphans` classifies every pending
# marker by window PRESENCE, reaps nothing, and refuses to call "could not
# look" an answer (your-org/nexus-code#1204).
#
# Run: bash monitor/watcher/test-ng-skeptic-orphans.sh
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
NG="$REPO_ROOT/monitor/ng"

WORK=$(mktemp -d -t nxorph-XXXXXX); trap 'rm -rf "$WORK"' EXIT
ST="$WORK/state"; mkdir -p "$ST/skeptic/pending" "$WORK/bin"
# A stub tmux: two windows present, one of them a live pairing's worker.
cat > "$WORK/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "$*" in *list-windows*) printf 'orchestrator\nolaysci\n' ;; *) exit 1 ;; esac
STUB
chmod +x "$WORK/bin/tmux"
# Three markers: one live (window present), two orphaned (absent) — one of them
# OLD and one FRESH, so age visibly does not decide the verdict.
echo 1 > "$ST/skeptic/pending/olaysci"
echo 1 > "$ST/skeptic/pending/audit337";  touch -d '30 days ago' "$ST/skeptic/pending/audit337"
echo 1 > "$ST/skeptic/pending/fresh-orphan"
echo 1 > "$ST/skeptic/pending/.hidden-sidecar"
printf '{"ts":"2026-08-27T00:19:34-07:00","agent":"monitor","event":"window-close","window":"audit337","reason":"retire-window"}\n' > "$ST/action-log.jsonl"

echo '=== 1. classification by PRESENCE, not age ==='
out=$(PATH="$WORK/bin:$PATH" NEXUS_STATE_DIR="$ST" bash "$NG" skeptic-orphans 2>"$WORK/err"); rc=$?
assert_eq "exit 0 = looked" "$rc" "0"
assert_contains "the live pairing's marker is live (window present)"      "$out" "marker=olaysci window_present=yes verdict=live"
assert_contains "the 30-day-old marker is orphaned"                        "$out" "marker=audit337 window_present=no verdict=orphaned"
assert_contains "the FRESH absent-window marker is orphaned too (age does not decide)" "$out" "marker=fresh-orphan window_present=no verdict=orphaned"
assert_contains "the action log's last row for the window is carried"     "$out" "marker=audit337 window_present=no verdict=orphaned age_s="
assert_contains "…naming the event"                                        "$out" "last_event=window-close last_event_ts=2026-08-27T00:19:34-07:00"
assert_contains "the summary line counts the split"                        "$out" "markers=3 live=1 orphaned=2 unknown=0 tmux=readable"
assert_not_contains "dot-prefixed sidecars are not markers"                "$out" ".hidden-sidecar"
assert_contains "orphans come with the on-the-record remedy, never an rm"  "$(cat "$WORK/err")" "ng skeptic resolve"

echo '=== 2. REPORT, NEVER REAP ==='
assert_eq "every marker survives the report" "$(ls "$ST/skeptic/pending" | grep -c .)" "3"

echo '=== 3. could-not-look is not an answer ==='
# a tmux that cannot be read (server gone, wrong socket) -> presence is '?', never 'no'
mkdir -p "$WORK/broken"; printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/broken/tmux"; chmod +x "$WORK/broken/tmux"
out=$(PATH="$WORK/broken:$PATH" NEXUS_STATE_DIR="$ST" bash "$NG" skeptic-orphans 2>/dev/null)
assert_contains "tmux unreadable -> window_present=? verdict=? (never orphaned)" "$out" "markers=3 live=0 orphaned=0 unknown=3 tmux=unreadable"
rm -rf "$ST/skeptic/pending"
PATH="$WORK/bin:$PATH" NEXUS_STATE_DIR="$ST" bash "$NG" skeptic-orphans >/dev/null 2>&1
assert_eq "no marker store -> exit 3, not an empty green" "$?" "3"

echo
# ASSERTION-COUNT GUARD. A suite that silently stops running assertions reports
# the same green as one that ran them all (your-org/nexus-code#827, #805).
EXPECTED=12
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
