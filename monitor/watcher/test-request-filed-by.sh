#!/usr/bin/env bash
# test-request-filed-by.sh — a filed request carries a PROCESS-DERIVED
# `filed-by:` line beside its argv-supplied `origin:` (your-org/nexus-code#1341).
# Run: bash monitor/watcher/test-request-filed-by.sh
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
RC="$_test_dir/../request-channel.sh"
ST=$(mktemp -d -t nxfiledby-XXXXXX); trap 'rm -rf "$ST"' EXIT

id=$(env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$ST" NEXUS_WORKER_WINDOW=w-filer TMUX_PANE=%42 \
     bash "$RC" file --origin spoofed-origin --kind question --slug q --message 'who filed this?' 2>"$ST/err"); rc=$?
assert_eq "file exits 0" "$rc" "0"
f=$(find "$ST" -name "*.new.md" -print -quit 2>/dev/null)
assert_eq "one .new.md exists" "$([[ -n "$f" ]] && echo yes || echo no)" "yes"
hdr=$(sed -n '1,/^---$/p' "$f" 2>/dev/null | sed '1d')
assert_contains "the header still carries the argv origin" "$hdr" "origin: spoofed-origin"
assert_contains "#1341 …and a filed-by line naming the filing uid" "$hdr" "filed-by: uid=$(id -un)"
assert_contains "#1341 …the tmux window the PROCESS ran in (not the argv origin)" "$hdr" "window=w-filer"
assert_contains "#1341 …its pane" "$hdr" "pane=%42"
assert_eq "#1341 pid= and ppid= are numeric" "$(grep -oE 'pid=[0-9]+ ppid=[0-9]+' <<<"$hdr" | grep -c .)" "1"
# NEGATIVE CONTROL: outside any worker the line still exists and says so
id2=$(env -u NEXUS_WORKER_WINDOW -u TMUX_PANE NEXUS_STATE_DIR="$ST" bash "$RC" file --origin x --kind question --slug q2 --message 'again' 2>/dev/null)
f2=$(find "$ST" -name "*q2*.new.md" -print -quit 2>/dev/null)
assert_contains "#1341 CONTROL: no worker context -> window=<unset>, never a fabricated name" "$(sed -n '1,/^---$/p' "$f2" | sed '1d')" "window=<unset>"

echo
EXPECTED=8
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$(( PASS + FAIL ))" "$EXPECTED" >&2; _th_fail
fi
th_summary_and_exit
