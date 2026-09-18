#!/usr/bin/env bash
# your-org/nexus-code#1404: the watcher's `--- requests ---` emit appended a
# `reply: required` caveat UNCONDITIONALLY, glued to the last request's
# `file=` path, so it read as a claim about a request that did not carry the
# field. Twice in one session the operator ran `ng request reply` on a
# spawn-skeptic request (no `reply:` field; the launcher acks it on spawn) and
# was refused.
#
# Fix under test: (1) each rendered request carries a `handling:` line decided
# from its PARSED `reply:` field, then its kind; (2) the main.sh footer starts
# on its own line and makes no per-kind claim.
#
# The footer is tested by EXTRACTING main.sh's `if [[ -n "$requests_lines" ]]`
# block and evaluating it against a real render — not by grepping main.sh for
# a sentence — so the assertion is about what the emit prints.
#
# Run: bash monitor/watcher/test-requests-emit-handling.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_monitor_dir=$(cd "$_test_dir/.." && pwd)
RC="$_monitor_dir/request-channel.sh"

. "$_test_dir/_test_helpers.sh"
PASS=0; FAIL=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export NEXUS_STATE_DIR="$WORK/state"
export STATE_DIR="$NEXUS_STATE_DIR"
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
mkdir -p "$NEXUS_STATE_DIR"
REQ="$NEXUS_STATE_DIR/requests"

# shellcheck source=_requests.sh
source "$_test_dir/_requests.sh"
export MONITOR_REQUESTS_ENABLED=true MONITOR_REQUESTS_MAX_PER_EMIT=10 MONITOR_REQUESTS_FAIRNESS=false

_file() { "$RC" file "$@"; }
# The block of the rendered emit belonging to ONE request id.
block_of() {   # <emit> <id>
    printf '%s\n' "$1" | awk -v id="request=$2 " '
        index($0, "request=") == 1 { on = (index($0, id) == 1) }
        on { print }'
}

echo '=== the three shapes, rendered by the real requests_poll_emit ==='
id_req=$(_file --origin wA --kind question      --reply required --slug needs-answer --message "please answer this")
id_sk=$( _file --origin wB --kind spawn-skeptic                  --slug skeptic-d1   --message "spawn-skeptic: validate wB (issue #1, depth 1, required)")
id_plain=$(_file --origin wC --kind question                     --slug fyi          --message "just so you know")
[[ -n "$id_req" && -n "$id_sk" && -n "$id_plain" ]] || th_abort "request-channel.sh file did not return ids"
out=$(requests_poll_emit)
assert_contains "all three requests were claimed and rendered (req)"   "$out" "request=$id_req"
assert_contains "all three requests were claimed and rendered (sk)"    "$out" "request=$id_sk"
assert_contains "all three requests were claimed and rendered (plain)" "$out" "request=$id_plain"

b_req=$(block_of "$out" "$id_req")
b_sk=$(block_of "$out" "$id_sk")
b_plain=$(block_of "$out" "$id_plain")
assert_contains "reply:required -> handling says reply REQUIRED"        "$b_req"   "handling: reply REQUIRED"
assert_contains "reply:required -> names the reply verb with THIS id"  "$b_req"   "ng request reply $id_req"
assert_contains "reply:required -> says ack refuses it"                "$b_req"   "ack\` refuses"
assert_contains "spawn-skeptic -> handling names the kind"             "$b_sk"    "handling: spawn-skeptic"
assert_contains "spawn-skeptic -> the launcher acks on spawn"          "$b_sk"    "launcher acks this request on spawn"
assert_not_contains "spawn-skeptic -> does NOT say reply REQUIRED (the #1404 trap)" "$b_sk" "reply REQUIRED"
assert_contains "plain -> handling says no reply required"             "$b_plain" "handling: no reply required"
assert_contains "plain -> names the ack verb with THIS id"             "$b_plain" "ng request ack $id_plain"
assert_not_contains "plain -> does NOT say reply REQUIRED"             "$b_plain" "reply REQUIRED"
# The summary line of the spawn-skeptic request says `required` (the SKEPTIC
# mode) — the word the issue notes compounds the misread. The handling line
# is where the reply mode lives, and it must not echo that word.
assert_contains "spawn-skeptic summary still carries the skeptic mode word" "$b_sk" "depth 1, required"
sk_handling=$(printf '%s\n' "$b_sk" | grep -F 'handling:')
assert_not_contains "…but its handling line never says REQUIRED"        "$sk_handling" "REQUIRED"

echo '=== the parsed field decides, not the kind: a spawn-skeptic WITH reply:required ==='
: > "$NEXUS_STATE_DIR/requests-emit-state.tsv"
id_sk_req=$(_file --origin wD --kind spawn-skeptic --reply required --slug sk-req --message "spawn and tell me")
out2=$(requests_poll_emit)
b_sk_req=$(block_of "$out2" "$id_sk_req")
assert_contains "spawn-skeptic + reply:required -> reply REQUIRED wins" "$b_sk_req" "handling: reply REQUIRED"

echo '=== the main.sh footer: on its own line, no per-kind claim ==='
# Extract the real block from main.sh and evaluate it against the real render.
main_block=$(sed -n '/^    if \[\[ -n "\$requests_lines" \]\]; then$/,/^    fi$/p' "$_test_dir/main.sh")
assert_contains "extracted the requests block from main.sh (positive control)" "$main_block" "--- requests ---"
render_footer() {
    local requests_lines="$1"
    eval "$main_block"
}
emit=$(render_footer "$out")
# The line that follows the LAST `file=` line must be the handling line, and
# the footer must start at column 0 — never glued to a path.
after_file=$(printf '%s\n' "$emit" | awk 'want { print; want = 0; done = 1 } /^    file=/ && !done { want = 1 }')
assert_contains "the line after file= is the handling line, not a caveat" "$after_file" "    handling:"
glued=$(printf '%s\n' "$emit" | grep -E '^    file=.*\(' || true)
assert_eq "no file= line has a parenthetical glued to its path" "$glued" ""
footer=$(printf '%s\n' "$emit" | grep -E '^\(read the cited file' || true)
assert_contains "footer exists on its own line"                     "$footer" "(read the cited file"
assert_not_contains "footer no longer asserts reply:required for every request" "$emit" "MUST be answered via"
assert_contains "footer points at the per-request handling line"    "$footer" "handling:"
# NEGATIVE CONTROL on the extraction: a render with NO requests prints no
# section at all (the block is gated on a non-empty string).
empty_emit=$(render_footer "")
assert_eq "empty requests_lines -> no requests section" "$empty_emit" ""

# Ledger footer (your-org/nexus-code#805 / #1145): the count is DECLARED so a
# silently-skipped assertion is a red, not a shorter green.
EXPECTED_ASSERTIONS=22
_ran=$(( ${PASS:-0} + ${FAIL:-0} ))
if (( _ran == EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
