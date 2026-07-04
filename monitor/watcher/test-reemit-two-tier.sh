#!/usr/bin/env bash
# Tests for the TWO-TIER reaction-gated re-emission policy
# (your-org/nexus-code#360) and the processed-comments.txt bound. Hermetic:
# no live GitHub — the GC live-reaction recheck is exercised via an injected
# `gh` stub (MONITOR_REEMIT_GH_CMD).
#
# The policy (the bot's reaction IS the re-emit state machine):
#   * NO 👀 yet (un-acknowledged)        -> FAST re-emit, _noeyes_minutes.
#   * 👀 but no 🚀 (acked / in progress) -> SLOW re-emit, _norocket_hours.
#   * 🚀 present (done)                  -> STOP (registry eviction).
# This makes the previously-inert 🚀 the terminal signal and the 👀 the
# fast-loop ack. It composes with #361's `_filter_reemit_backoff` (a body-
# independent minimum-gap FLOOR for the no-👀 case); here the registry gates
# both tiers at the SOURCE (`_reemit_pending`) so the policy holds standalone.
#
# Asserts (the three transitions + the supporting machinery):
#   1. no 👀  -> FAST: re-feeds after _noeyes_minutes, not before.
#   2. 👀     -> SLOW: re-feeds after _norocket_hours, not within; and the
#                fast window alone is NOT enough.
#   3. 🚀     -> STOP: GC evicts; never re-feeds again.
#   4. `_reemit_reaction_state` classifier: rocket|eyes|none + self-eye + gh-fail.
#   5. `_filter_processed_comments` exemption: a 👀'd MENTION is NOT dropped
#      (registry owns it) while a 👀'd IN-$REPO comment still IS.
#   6. cadences are CONFIG-driven (env overrides honored; nothing hardcoded).
#   7. processed-comments.txt bound: `_prune_processed_comments` retains the
#      most-recent N entries, format-preserving (newest kept).
#
# Run: bash monitor/watcher/test-reemit-two-tier.sh

set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0; FAIL=0
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s\n         expected: %s\n         in:\n%s\n' "$label" "$needle" "$hay" >&2; FAIL=$((FAIL+1)); fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if ! grep -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s\n         did NOT expect: %s\n         in:\n%s\n' "$label" "$needle" "$hay" >&2; FAIL=$((FAIL+1)); fi
}
assert_eq() {
    local label="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — got [%s] want [%s]\n' "$label" "$got" "$want" >&2; FAIL=$((FAIL+1)); fi
}

# ---- harness ----
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
REPO="your-org/your-nexus"
USER_LOGIN="operator"
BOT_LOGIN="your-org-bot"
CROSS_REPO_SURFACE="mention_only"
MONITOR_REEMIT_ENABLED="true"
MONITOR_REEMIT_LIVE_RECHECK="false"
MONITOR_REEMIT_MAX_AGE_SECONDS="259200"
MONITOR_EMIT_COOLDOWN_SECONDS="0"
# The cadences under test — deliberately NON-default so the assertions also
# prove the config knobs are honored (no hardcoded values).
MONITOR_REEMIT_NOEYES_MINUTES="5"
MONITOR_REEMIT_NOROCKET_HOURS="6"
MONITOR_PROCESSED_COMMENTS_MAX_ENTRIES="3"
export STATE_DIR REPO USER_LOGIN BOT_LOGIN CROSS_REPO_SURFACE \
       MONITOR_REEMIT_ENABLED MONITOR_REEMIT_LIVE_RECHECK \
       MONITOR_REEMIT_MAX_AGE_SECONDS MONITOR_EMIT_COOLDOWN_SECONDS \
       MONITOR_REEMIT_NOEYES_MINUTES MONITOR_REEMIT_NOROCKET_HOURS \
       MONITOR_PROCESSED_COMMENTS_MAX_ENTRIES

. "$_test_dir/_github.sh"
. "$_test_dir/_emit_filters.sh"
. "$_test_dir/_reemit.sh"
# Extract `_gh_filter_dedup_pipeline` + `_prune_processed_comments` from
# main.sh (heavy top-level state otherwise) — same trick as the sibling tests.
for fn in _gh_filter_dedup_pipeline _prune_processed_comments; do
    fn_def=$(awk -v f="$fn" '
        $0 ~ "^" f "\\(\\) \\{$" { capture=1 }
        capture { print; if ($0 == "}") capture=0 }
    ' "$_test_dir/main.sh")
    [[ -n "$fn_def" ]] || { echo "setup: could not extract $fn" >&2; exit 1; }
    eval "$fn_def"
done
# `log` is undefined here (main.sh owns it); _prune_processed_comments calls
# it. Stub to a no-op so the extracted function runs standalone.
log() { :; }

reg="$STATE_DIR/unacked-mentions.lines"
CR_ID="4746440400"
CR_BLOCK=$'mention=your-org/nexus-code kind=pr n=310 id=4746440400 author=operator\n  body: @your-org-bot could we resolve this without a home-dir install?'

reset_state() {
    rm -f "$STATE_DIR/unacked-mentions.lines" "$STATE_DIR/unacked-mentions.lock" \
          "$STATE_DIR/processed-comments.txt" "$STATE_DIR/watcher.log" 2>/dev/null || true
}
# Backdate every entry's last_reemit so the next _reemit_pending sees the
# stated number of seconds as elapsed since the last re-feed.
set_last_reemit() {
    [[ -f "$reg" ]] || return 0
    sed -i "s/last_reemit=[0-9]*/last_reemit=$(( $(date +%s) - ${1:-0} ))/g" "$reg"
}
pending() { _reemit_pending; }

NOEYES_SEC=$(( MONITOR_REEMIT_NOEYES_MINUTES * 60 ))      # 300
NOROCKET_SEC=$(( MONITOR_REEMIT_NOROCKET_HOURS * 3600 ))  # 21600

# ===================================================================
echo '=== 1. NO 👀 → FAST tier: re-feeds after _noeyes_minutes, not before ==='
reset_state
printf '%s\n' "$CR_BLOCK" | _reemit_register
assert_contains "fresh entry starts tier=fast" "$(cat "$reg")" "tier=fast"
# Just under the fast window → NOT due.
set_last_reemit $(( NOEYES_SEC - 30 ))
assert_not_contains "fast: NOT due 30s before the 5min window" "$(pending)" "id=$CR_ID"
# Just past the fast window → due.
set_last_reemit $(( NOEYES_SEC + 30 ))
assert_contains "fast: DUE just past the 5min window" "$(pending)" "id=$CR_ID"

echo '=== 2. 👀 (no 🚀) → SLOW tier: the 5min window is NOT enough; 6h is ==='
reset_state
printf '%s\n' "$CR_BLOCK" | _reemit_register
printf 'comment:%s\n' "$CR_ID" > "$STATE_DIR/processed-comments.txt"   # bot 👀
_reemit_gc
assert_contains "👀: entry demoted to tier=slow" "$(cat "$reg")" "tier=slow"
assert_contains "👀: entry NOT evicted"          "$(cat "$reg")" "id=$CR_ID"
# Past the FAST window but well under the SLOW window → still NOT due.
set_last_reemit $(( NOEYES_SEC + 600 ))
assert_not_contains "slow: a fast-window gap does NOT re-emit a 👀'd entry" "$(pending)" "id=$CR_ID"
# Past the SLOW window → due (the "still on track?" nudge).
set_last_reemit $(( NOROCKET_SEC + 60 ))
assert_contains "slow: DUE past the 6h window" "$(pending)" "id=$CR_ID"

echo '=== 3. 🚀 → STOP: GC evicts; never re-feeds ==='
reset_state
printf '%s\n' "$CR_BLOCK" | _reemit_register
printf 'comment:%s\nrocket:%s\n' "$CR_ID" "$CR_ID" > "$STATE_DIR/processed-comments.txt"  # 👀 + 🚀
_reemit_gc
assert_not_contains "🚀: entry evicted from registry" "$(cat "$reg" 2>/dev/null)" "id=$CR_ID"
assert_contains     "🚀: eviction logged reason=rocket" "$(cat "$STATE_DIR/watcher.log")" "reason=rocket"
# Even forcing the cadence wide open, an evicted id cannot re-feed.
set_last_reemit "$(( NOROCKET_SEC + 10000 ))"
assert_not_contains "🚀: nothing left to re-feed" "$(pending)" "id=$CR_ID"

echo '=== 4. _reemit_reaction_state classifier ==='
mk_stub() { eval "$1() { [[ \"\$1\" == api ]] || return 1; printf '%s' '$2'; }"; export -f "$1"; }
mk_stub st_rocket '[{"content":"rocket","user":{"login":"your-org-bot[bot]"}},{"content":"eyes","user":{"login":"your-org-bot[bot]"}}]'
mk_stub st_eyes   '[{"content":"eyes","user":{"login":"your-org-bot[bot]"}}]'
mk_stub st_none   '[]'
mk_stub st_self   '[{"content":"eyes","user":{"login":"operator"}}]'
st_fail() { return 7; }; export -f st_fail
assert_eq "rocket dominates eyes → rocket" "rocket" "$(MONITOR_REEMIT_GH_CMD=st_rocket _reemit_reaction_state x/y 1)"
assert_eq "bot eyes only → eyes"           "eyes"   "$(MONITOR_REEMIT_GH_CMD=st_eyes   _reemit_reaction_state x/y 1)"
assert_eq "no bot reaction → none"         "none"   "$(MONITOR_REEMIT_GH_CMD=st_none   _reemit_reaction_state x/y 1)"
assert_eq "operator self-eye → none"       "none"   "$(MONITOR_REEMIT_GH_CMD=st_self   _reemit_reaction_state x/y 1)"
out=$(MONITOR_REEMIT_GH_CMD=st_fail _reemit_reaction_state x/y 1); rc=$?
assert_eq "gh failure → rc 2, no output (unknown)" "2|" "${rc}|${out}"

echo '=== 5. _filter_processed_comments: mention exempt, in-$REPO still dropped ==='
: > "$STATE_DIR/processed-comments.txt"
printf 'comment:%s\n' "$CR_ID" > "$STATE_DIR/processed-comments.txt"
MENTION=$'mention=your-org/nexus-code kind=pr n=310 id=4746440400 author=operator\n  body: @your-org-bot ping'
INREPO=$'issue=236 id=4746440400 author=operator\n  body: in-repo comment same id'
assert_contains     "👀'd MENTION is NOT dropped (registry owns it)" \
    "$(printf '%s\n' "$MENTION" | _filter_processed_comments)" "mention=your-org/nexus-code"
assert_not_contains "👀'd IN-\$REPO comment IS still dropped (propagation guard)" \
    "$(printf '%s\n' "$INREPO" | _filter_processed_comments)" "issue=236"
rm -f "$STATE_DIR/processed-comments.txt"

echo '=== 6. cadence config knobs honored (re-feed timing tracks the env values) ==='
# Re-run the boundary with a DIFFERENT noeyes value: a 2-min window must gate
# at 120s, not the 300s of case 1 — proving the value is read, not hardcoded.
reset_state
printf '%s\n' "$CR_BLOCK" | _reemit_register
set_last_reemit 150   # 150s elapsed
assert_not_contains "noeyes=5 (300s): 150s elapsed is NOT due" "$(pending)" "id=$CR_ID"
set_last_reemit 150
assert_contains "noeyes=2 (120s): 150s elapsed IS due" \
    "$(MONITOR_REEMIT_NOEYES_MINUTES=2 pending)" "id=$CR_ID"

echo '=== 7. processed-comments.txt bound: retain most-recent N, newest kept ==='
f="$STATE_DIR/processed-comments.txt"
printf 'comment:1\ncomment:2\ncomment:3\ncomment:4\ncomment:5\n' > "$f"   # 5 entries, cap=3
_prune_processed_comments
assert_eq           "pruned to exactly cap entries"     "3" "$(wc -l < "$f" | tr -d ' ')"
assert_contains     "newest entry retained"             "$(cat "$f")" "comment:5"
assert_contains     "second-newest retained"            "$(cat "$f")" "comment:3"
assert_not_contains "oldest entry dropped"              "$(cat "$f")" "comment:1"
# Under the cap → untouched (no spurious rewrite).
printf 'comment:9\ncomment:8\n' > "$f"
_prune_processed_comments
assert_eq "under cap → left intact" "2" "$(wc -l < "$f" | tr -d ' ')"
# Disabled (cap=0) → never prunes.
printf 'comment:1\ncomment:2\ncomment:3\ncomment:4\n' > "$f"
MONITOR_PROCESSED_COMMENTS_MAX_ENTRIES=0 _prune_processed_comments
assert_eq "cap=0 disables pruning" "4" "$(wc -l < "$f" | tr -d ' ')"

echo '=== 8. round-2: foreign content — preserve if bot involved, never direct-emit (#359) ==='
# The conservative rule: a cross-tenant block is DRAINED only if the bot was
# never involved; a block the bot is addressed in is PRESERVED as direct=no
# context and never direct-emitted.
reset_state
rm -f "$STATE_DIR/processed-comments.txt" 2>/dev/null || true
FID="888777666"   # other-user author, @-mentions OUR bot → preserve as context
FBLOCK=$'mention=your-org/other-nexus kind=issue n=9 id=888777666 author=other-nexus-bot[bot]\n  body: @your-org-bot can you look at this cross-tenant thread?'
NID="888777000"   # other-user author, NO @bot mention → bot never involved → drain
NBLOCK=$'mention=your-org/other-nexus kind=issue n=10 id=888777000 author=other-nexus-bot[bot]\n  body: purely internal other-operator note, no bot'
# Round-2 register pre-pass: drain | _filter_cross_repo_surface | _reemit_register
printf '%s\n%s\n%s\n' "$FBLOCK" "$NBLOCK" "$CR_BLOCK" | _filter_cross_repo_surface | _reemit_register
regc="$(cat "$reg" 2>/dev/null)"
assert_contains     "bot-involved foreign block PRESERVED (not drained)" "$regc" "id=$FID"
assert_contains     "preserved foreign block is direct=no context"       "$(grep "id=$FID" <<<"$regc")" "direct=no"
assert_not_contains "bot-uninvolved foreign noise DRAINED (dropped)"     "$regc" "id=$NID"
assert_contains     "operator block registered (direct=yes)"            "$regc" "id=$CR_ID"
assert_contains     "operator block is direct=yes"                       "$(grep "id=$CR_ID" <<<"$regc")" "direct=yes"
# End-to-end DIRECT path: raw drain (incl. the foreign block) + registry
# re-feed, through the FULL pipeline (operator-author chokepoint first).
set_last_reemit 1000   # operator block past its fast window → due
direct_out="$( { printf '%s\n%s\n' "$FBLOCK" "$CR_BLOCK"; _reemit_pending; } | _gh_filter_dedup_pipeline )"
assert_not_contains "foreign block NEVER enters direct emission" "$direct_out" "id=$FID"
assert_contains     "operator block DOES direct-emit"            "$direct_out" "id=$CR_ID"
# The context block is still retained after the pending pass (not consumed).
assert_contains     "context block still retained post-pending"  "$(cat "$reg" 2>/dev/null)" "id=$FID"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }
exit 1
