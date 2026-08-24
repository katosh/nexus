#!/usr/bin/env bash
# Tests for monitor/hooks/notification-record.sh — the extracted Notification
# journal writer (your-org/nexus-code#568 D1 + D10).
#
# It replaces two inline `jq` pipelines in monitor/worker-settings.json and one
# in monitor/orchestrator-settings.json. Two things must hold, and neither was
# testable while the code lived inside a JSON string:
#   * the ROWS are byte-compatible with what the readers expect
#     (`_notifications_count_distinct_since` parses the structured log, and its
#     sed fallback assumes the canonical compact jq shape);
#   * the hook FAILS OPEN — a bookkeeping write must never be able to take out
#     a worker's tool access, the 2026-07-09 read-only-tree incident.
# Plus the D1 half: the raw-capture log is no longer unbounded.
#
# Run: bash monitor/watcher/test-notification-record.sh
# Expected: ALL TESTS PASSED, exit 0. Hermetic — no tmux, no network.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
HOOK="$REPO_ROOT/monitor/hooks/notification-record.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -x "$HOOK" ]] || { echo "missing/non-executable hook: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "skipped: jq not on PATH"; exit 77; }

WORK=$(mktemp -d -t nexus-notif-rec-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/nexus"; mkdir -p "$ROOT/monitor"
STATE="$ROOT/monitor/.state"
RAW="$STATE/notification-raw-captures.jsonl"
STRUCT="$STATE/worker-notifications.jsonl"

EVENT='{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","session_id":"abc123"}'

run_hook() {  # run_hook <window-env-assignments...>
    # Clear the ambient window vars first: this suite may itself run inside a
    # nexus worker, whose NEXUS_WORKER_WINDOW would otherwise leak in and make
    # the orchestrator call-site case indistinguishable from the worker one.
    printf '%s' "$EVENT" \
        | env -u NEXUS_WORKER_WINDOW -u NEXUS_ORCHESTRATOR_WINDOW \
              NEXUS_ROOT="$ROOT" "$@" "$HOOK"
}

echo '=== worker call site: both journals written, one event each ==='
rc=0; run_hook NEXUS_WORKER_WINDOW=w7 >/dev/null 2>&1 || rc=$?
[[ "$rc" == 0 ]] && ok "hook exits 0" || bad "exit code" "rc=$rc"
[[ -s "$STRUCT" ]] && ok "structured row written" || bad "structured row" "missing $STRUCT"
[[ -s "$RAW" ]] && ok "raw capture written for a worker" || bad "raw capture" "missing $RAW"

# The structured row's SHAPE is a contract with the watcher's prelude reader.
got=$(jq -r '[.event, .notification_type, .window, (.ts|type)] | @tsv' "$STRUCT" 2>/dev/null)
want=$(printf 'Notification\tpermission_prompt\tw7\tnumber')
[[ "$got" == "$want" ]] && ok "structured row keys match the reader's contract" \
    || bad "structured row shape" "got [$got] want [$want]"
# Compact: one line per event, or the line-oriented readers (and the sed
# fallback) break.
[[ "$(wc -l < "$STRUCT")" == 1 ]] && ok "structured row is one compact line" \
    || bad "row compactness" "$(wc -l < "$STRUCT") lines"

# The raw capture must preserve the ORIGINAL payload plus the two enrichments —
# that fidelity is the only reason to keep it.
got=$(jq -r '[.session_id, .nexus_window, (.nexus_capture_ts|type), .message] | @tsv' "$RAW" 2>/dev/null)
case "$got" in
    "abc123	w7	number	Claude needs"*) ok "raw capture preserves the payload + adds window/ts" ;;
    *) bad "raw capture shape" "got [$got]" ;;
esac

echo '=== orchestrator call site: NO raw capture (behaviour preserved) ==='
rm -f "$RAW" "$STRUCT"
run_hook NEXUS_ORCHESTRATOR_WINDOW=orchestrator >/dev/null 2>&1
[[ -s "$STRUCT" ]] && ok "orchestrator writes the structured row" || bad "orch structured" "missing"
[[ ! -e "$RAW" ]] && ok "orchestrator writes NO raw capture (as before the extraction)" \
    || bad "orch raw capture" "raw log created where the inline pipeline never made one"
got=$(jq -r '.window' "$STRUCT" 2>/dev/null)
[[ "$got" == "orchestrator" ]] && ok "orchestrator window label preserved" || bad "orch window" "got [$got]"

echo '=== D1: the raw capture is BOUNDED (it was unrotated and unbounded) ==='
rm -f "$RAW" "$STRUCT"
head -c 4096 /dev/zero | tr '\0' 'x' > "$RAW"          # 4 KiB of filler
run_hook NEXUS_WORKER_WINDOW=w7 MONITOR_NOTIFICATIONS_LOG_MAX_BYTES=1024 >/dev/null 2>&1
rotated=$(find "$STATE" -maxdepth 1 -name 'notification-raw-captures.jsonl.*' | wc -l)
[[ "$rotated" == 1 ]] && ok "oversized raw log rotates to an archive" || bad "raw rotation" "$rotated archives"
[[ "$(wc -l < "$RAW")" == 1 ]] && ok "live raw log restarts at one row" || bad "post-rotation live log" "$(wc -l < "$RAW") lines"
# Same treatment for the structured sibling.
rm -f "$STRUCT"; head -c 4096 /dev/zero | tr '\0' 'y' > "$STRUCT"
run_hook NEXUS_WORKER_WINDOW=w7 MONITOR_NOTIFICATIONS_LOG_MAX_BYTES=1024 >/dev/null 2>&1
rotated=$(find "$STATE" -maxdepth 1 -name 'worker-notifications.jsonl.*' | wc -l)
[[ "$rotated" == 1 ]] && ok "oversized structured log rotates too" || bad "structured rotation" "$rotated archives"

echo '=== FAILS OPEN: never propagate a bookkeeping failure into the gate ==='
# Unwritable state tree — the 2026-07-09 shape.
RO="$WORK/ro"; mkdir -p "$RO/monitor/.state"; chmod 500 "$RO/monitor/.state"
rc=0; printf '%s' "$EVENT" | env -u NEXUS_ORCHESTRATOR_WINDOW NEXUS_ROOT="$RO" NEXUS_WORKER_WINDOW=w7 "$HOOK" >/dev/null 2>&1 || rc=$?
chmod 700 "$RO/monitor/.state"
[[ "$rc" == 0 ]] && ok "unwritable state dir → still exits 0" || bad "read-only tree" "rc=$rc"

rc=0; printf '%s' "$EVENT" | env -u NEXUS_ROOT -u NEXUS_WORKER_WINDOW "$HOOK" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 0 ]] && ok "NEXUS_ROOT unset → still exits 0" || bad "no NEXUS_ROOT" "rc=$rc"

rc=0; printf 'not json at all' | env -u NEXUS_ORCHESTRATOR_WINDOW NEXUS_ROOT="$ROOT" NEXUS_WORKER_WINDOW=w7 "$HOOK" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 0 ]] && ok "malformed payload → still exits 0" || bad "malformed payload" "rc=$rc"

rc=0; printf '' | env -u NEXUS_ORCHESTRATOR_WINDOW NEXUS_ROOT="$ROOT" NEXUS_WORKER_WINDOW=w7 "$HOOK" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 0 ]] && ok "empty payload → still exits 0" || bad "empty payload" "rc=$rc"

echo '=== the settings files reference the hook, not an inline pipeline ==='
for f in monitor/worker-settings.json monitor/orchestrator-settings.json; do
    if grep -q 'hooks/notification-record.sh' "$REPO_ROOT/$f"; then
        ok "$f wires the extracted hook"
    else
        bad "$f wiring" "does not reference hooks/notification-record.sh"
    fi
    if grep -q 'notification-raw-captures.jsonl' "$REPO_ROOT/$f"; then
        bad "$f inline pipeline" "still embeds the raw-capture pipeline in JSON"
    else
        ok "$f no longer embeds a raw-capture jq pipeline"
    fi
done

echo
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
echo "FAILED" >&2; exit 1
