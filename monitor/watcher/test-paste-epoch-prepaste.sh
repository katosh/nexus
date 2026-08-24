#!/usr/bin/env bash
# The paste epoch must be the PRE-paste instant — your-org/nexus-code#665.
#
# `_idle_unconfirmed_paste_epoch` used to take the MAX of two surfaces:
#
#   machine-input.tsv   stamped BEFORE the keystrokes go out
#                       (paste-followup.sh:418)
#   action-log.jsonl    appended AFTER the paste completes and its
#                       outcome is known (paste-followup.sh step 4)
#
# `max()` deliberately selects the post-paste one — and the target's own
# submission record lands BETWEEN them. So every check on the most recent
# paste compared the submission against an epoch LATER than the
# submission itself, and `>= epoch` rejected the paste's own record:
#
#   submission record   23:53:58.439Z   (transcript)
#   action-log ts       23:53:59Z       (max → chosen)
#                       ^ 0.56s later → paste-unconfirmed fires
#
# Measured live on 2026-08-02: nexus-dashboard-prune -0.56s, nexus-dashsk
# -0.24s, nexuscode-burndown2 -1.2s — all three delivered, all three
# flagged. Older pastes looked confirmed only because some LATER
# submission cleared the bar for them, which is why the false positive
# always lands on the MOST RECENT paste: the one an operator is actually
# waiting on.
#
# The TSV is authoritative for attribution. paste-followup.sh says so at
# its own action-log append — "the TSV stamp above is what the
# attribution rule keys on".
#
# Run: bash monitor/watcher/test-paste-epoch-prepaste.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
ck()   { if [[ "$2" == "$3" ]]; then pass "$1 (got $2)"; else fail "$1 — got '$2' want '$3'"; fi; }

WORK=$(mktemp -d -t nexus-665-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR/heartbeat"
# shellcheck source=monitor/watcher/_idle_probe.sh
source "$_repo_root/monitor/watcher/_idle_probe.sh" || { echo "cannot source _idle_probe.sh" >&2; exit 1; }

WIN=testwin
NOW=2000000000
PRE=1999999000     # TSV: stamped before the paste
POST=1999999002    # action-log: appended 2s later, after the paste

# Hooks must look live, or the detector short-circuits to "cannot confirm".
printf '{"session_id":"deadbeef"}\n' > "$STATE_DIR/heartbeat/$WIN.json"

# The window's spawn predates everything, so lifecycle scope never trims.
_idle_window_spawn_ts() { printf ''; }
# No UserPromptSubmit stamp ever — this is the whole premise of the
# reported incidents: delivered pastes that stamped nothing.
_openg_user_prompt_epoch() { printf '0'; }
# Grace already elapsed.
_paste_confirm_grace_seconds() { printf '180'; }
_machine_input_path() { printf '%s/machine-input.tsv' "$STATE_DIR"; }

# The transcript surface is what the epoch is COMPARED against. Model it
# as: a submission exists at PRE+1 (i.e. during the paste, before the
# action-log row was written). `yes` iff the queried epoch is <= that.
SUBMISSION_AT=$(( PRE + 1 ))
_idle_paste_consumed() {
    local _w="$1" epoch="$2"
    (( SUBMISSION_AT >= epoch )) && { printf 'yes'; return 0; }
    printf 'no'
}

printf '%s\t%s\t%s\n' "$WIN" "$PRE" paste-followup > "$STATE_DIR/machine-input.tsv"
cat > "$STATE_DIR/action-log.jsonl" <<JSON
{"event":"paste-followup","window":"$WIN","ts":"$(date -d "@$POST" --iso-8601=seconds)"}
JSON

# ---------------------------------------------------------------------------
echo "=== case 1: THE DEFECT — both surfaces present, TSV must win ==="
# Under max(), the epoch would be POST, the submission at PRE+1 would be
# "before" it, and the detector would fire on a delivered paste.
got=$(_idle_unconfirmed_paste_epoch "$WIN" "$NOW")
ck "epoch is the PRE-paste stamp, not the post-paste log ts" "$got" 0
if [[ "$got" == "$POST" ]]; then
    fail "epoch is the action-log ts — max() behaviour has returned"
fi

echo "=== case 2: the submission is correctly seen as confirming ==="
# Directly: querying with the TSV epoch finds the submission; querying
# with the action-log epoch does not. This is the entire bug in two lines.
ck "consumed(TSV epoch)        = yes" "$(_idle_paste_consumed "$WIN" "$PRE")"  yes
ck "consumed(action-log epoch) = no"  "$(_idle_paste_consumed "$WIN" "$POST")" no

echo "=== case 3: a GENUINELY lost paste still fires (the detector's reason to exist) ==="
# Same fixture, but no submission at all. If this ever passes silently,
# the fix has traded false positives for false negatives — which is the
# strictly worse direction, since a lost paste is unrecoverable silence.
SUBMISSION_AT=0
got=$(_idle_unconfirmed_paste_epoch "$WIN" "$NOW")
ck "no submission anywhere → still reports the paste epoch" "$got" "$PRE"
SUBMISSION_AT=$(( PRE + 1 ))

echo "=== case 4: fallback — TSV missing, action-log backed off by the lag ==="
# The action-log row is post-paste by construction, so using it raw
# reintroduces the defect. It must be corrected before use, and only
# consulted when the TSV has nothing.
rm -f "$STATE_DIR/machine-input.tsv"
got=$(_idle_unconfirmed_paste_epoch "$WIN" "$NOW")
if [[ "$got" == "0" ]]; then
    pass "fallback epoch is early enough that the submission confirms it"
elif (( got <= SUBMISSION_AT )); then
    pass "fallback epoch ($got) <= submission ($SUBMISSION_AT) — confirms correctly"
else
    fail "fallback epoch $got is LATER than the submission $SUBMISSION_AT — #665 reintroduced on the fallback path"
fi
printf '%s\t%s\t%s\n' "$WIN" "$PRE" paste-followup > "$STATE_DIR/machine-input.tsv"

echo "=== case 5: hooks dead → 'cannot confirm', never 'unconfirmed' ==="
mv "$STATE_DIR/heartbeat/$WIN.json" "$STATE_DIR/heartbeat/.$WIN.json.off"
ck "no heartbeat → 0 (cannot confirm)" "$(_idle_unconfirmed_paste_epoch "$WIN" "$NOW")" 0
mv "$STATE_DIR/heartbeat/.$WIN.json.off" "$STATE_DIR/heartbeat/$WIN.json"

echo "=== case 6: inside the grace window → not yet judged ==="
ck "paste 10s ago → 0 (too recent)" "$(_idle_unconfirmed_paste_epoch "$WIN" "$(( PRE + 10 ))")" 0

# ---------------------------------------------------------------------------
printf '\n=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
exit 1
