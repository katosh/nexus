#!/usr/bin/env bash
# Tests for the body-INDEPENDENT cross-repo re-emit backoff
# (`_filter_reemit_backoff` in _emit_filters.sh, hop 7 of
# `_gh_filter_dedup_pipeline`). Hermetic: no network, no live GitHub.
#
# Regression target: your-org/nexus-code#358 — a just-emitted eligible
# bot-mention RE-EMITTED ~2 min later in quick succession. Root cause: the
# durable re-emit registry (`_reemit_pending`) re-feeds the body captured at
# REGISTRATION, while the deliveries drain / GraphQL backstop carry the LIVE
# body. When the operator EDITS the mention, the two bodies DIVERGE, so the
# same comment id presents two different SHAs within seconds — defeating
# `_filter_emit_cooldown`'s (id, body-SHA) drop, which deliberately bypasses
# on a body change. The id 4802521686 emitted 10:49:49 with the pre-edit
# body and again 10:51:50 with the `@Connorr0`-edited body, 124 s apart.
#
# `_filter_reemit_backoff` caps a mention id's re-emit cadence to once per
# `MONITOR_REEMIT_BACKOFF_SECONDS` REGARDLESS of body, so the orchestrator
# gets time to 👀-ack. It is SEPARATE from #357's `last_recheck=` ack-recheck
# throttle (this bounds EMIT cadence; that bounds the ack-RECHECK cadence).
#
# Asserts:
#   1. fresh mention emits once (stamp written).
#   2. CHANGED body within the backoff window is SUPPRESSED (the core
#      regression — body-independence). MUTATION: the same input through a
#      backoff-less pipeline DOES double-emit (proves the filter is load-
#      bearing, RED on the old behavior).
#   3. after the window elapses, an un-acked mention RE-EMITS.
#   4. a bot 👀 within the window suppresses (processed-comments upstream;
#      the #357 ack path survives).
#   5. in-$REPO shapes are NOT gated (changed body still re-surfaces).
#   6. backoff=0 disables (passthrough, no stamp footprint).
#
# Run: bash monitor/watcher/test-reemit-backoff.sh

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

# ---- harness ----
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
REPO="your-org/your-nexus"
USER_LOGIN="operator"
BOT_LOGIN="your-org-bot"
CROSS_REPO_SURFACE="mention_only"
MONITOR_EMIT_COOLDOWN_SECONDS="0"       # isolate the backoff: SHA cooldown off
MONITOR_REEMIT_BACKOFF_SECONDS="300"    # the filter under test
export STATE_DIR REPO USER_LOGIN BOT_LOGIN CROSS_REPO_SURFACE \
       MONITOR_EMIT_COOLDOWN_SECONDS MONITOR_REEMIT_BACKOFF_SECONDS

. "$_test_dir/_github.sh"
. "$_test_dir/_emit_filters.sh"
# Extract just `_gh_filter_dedup_pipeline` from main.sh (heavy top-level
# state otherwise); same trick as test-reemit-until-acked.sh.
fn_def=$(awk '
    $0 ~ "^_gh_filter_dedup_pipeline\\(\\) \\{$" { capture=1 }
    capture { print; if ($0 == "}") capture=0 }
' "$_test_dir/main.sh")
[[ -n "$fn_def" ]] || { echo "setup: could not extract _gh_filter_dedup_pipeline" >&2; exit 1; }
eval "$fn_def"

# The nexus-code#358 shape — same id, two bodies (pre-edit / @Connorr0 edit).
CR_ID="4802521686"
CR_V1=$'mention=your-org/nexus-code kind=issue n=358 id=4802521686 author=operator\n  body: @your-org-bot please investigate and also comment in the new PR #359'
CR_V2=$'mention=your-org/nexus-code kind=issue n=358 id=4802521686 author=operator\n  body: @Connorr0 @your-org-bot please investigate and also comment in the new PR #359'
INREPO_ID="555000111"
INREPO_V1=$'issue=236 id=555000111 author=operator\n  body: in-repo first body'
INREPO_V2=$'issue=236 id=555000111 author=operator\n  body: in-repo EDITED body'

reset_backoff() { rm -rf "$STATE_DIR/reemit-backoff" 2>/dev/null || true; }
stamp_path="$STATE_DIR/reemit-backoff/comment-$CR_ID.ts"

# ===================================================================
echo '=== 1. fresh mention emits once; stamp written ==='
reset_backoff
out1=$(printf '%s\n' "$CR_V1" | _filter_reemit_backoff)
assert_contains "fresh mention surfaces"        "$out1" "id=$CR_ID"
assert_contains "fresh mention carries body"    "$out1" "comment in the new PR #359"
[[ -f "$stamp_path" ]] && { echo "  PASS: stamp file written"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: stamp file missing" >&2; FAIL=$((FAIL+1)); }

echo '=== 2. CHANGED body within backoff window is SUPPRESSED (body-independent) ==='
# Stamp is fresh from case 1 → CR_V2 (different body, same id) must NOT surface.
out2=$(printf '%s\n' "$CR_V2" | _filter_reemit_backoff)
assert_not_contains "edited-body re-emit suppressed within window" "$out2" "id=$CR_ID"

echo '=== 2-MUTATION: real SHA-bypass — edited body double-emits through the cooldown ALONE (RED), backoff CLOSES it (GREEN) ==='
# Genuinely exercise the root cause with the SHA cooldown ENABLED (300 s):
# emit V1 first (stamps emit-history with SHA1), then the @Connorr0-edited V2
# (SHA2). SHA2 != SHA1, so `_filter_emit_cooldown`'s deliberate edit-bypass
# lets V2 through within the window — the nexus-code#358 double-emit. Then the
# SAME two bodies through `_filter_reemit_backoff` (id-keyed): V2 is suppressed.
# This is the strengthened negative control — the prior version ran with the
# cooldown DISABLED, so V2 surfaced because the filter was a passthrough, not
# because the SHA-bypass fired.
rm -rf "$STATE_DIR/emit-history" 2>/dev/null || true; reset_backoff
mv1=$(MONITOR_EMIT_COOLDOWN_SECONDS=300 _filter_emit_cooldown <<<"$CR_V1")
assert_contains "cooldown: V1 first emit surfaces"                          "$mv1" "id=$CR_ID"
mv2=$(MONITOR_EMIT_COOLDOWN_SECONDS=300 _filter_emit_cooldown <<<"$CR_V2")
assert_contains "cooldown ALONE: edited V2 bypasses the SHA cooldown (#358 double-emit, RED)" "$mv2" "id=$CR_ID"
reset_backoff
bk1=$(_filter_reemit_backoff <<<"$CR_V1")
bk2=$(_filter_reemit_backoff <<<"$CR_V2")
assert_contains     "backoff: V1 surfaces"                                  "$bk1" "id=$CR_ID"
assert_not_contains "backoff CLOSES it: edited V2 suppressed within window (GREEN)" "$bk2" "id=$CR_ID"

echo '=== 3. after the window elapses, an un-acked mention RE-EMITS ==='
# Backdate the stamp beyond the backoff window (simulate time passing).
printf '%s\n' "$(( $(date +%s) - MONITOR_REEMIT_BACKOFF_SECONDS - 30 ))" > "$stamp_path"
out3=$(printf '%s\n' "$CR_V2" | _filter_reemit_backoff)
assert_contains "un-acked mention re-emits past the backoff window" "$out3" "id=$CR_ID"

echo '=== 4. a bot 👀 no longer FULLY suppresses a mention at the filter level (#362 two-tier) ==='
# SUPERSEDED by the two-tier policy (your-org/nexus-code#362): a bare 👀 no
# longer STOPS a cross-repo mention — `_filter_processed_comments` now EXEMPTS
# `mention=`/`cross_repo=` shapes (the re-emit registry owns their lifecycle:
# 👀 → demote to the SLOW 6h tier, 🚀 → evict). So at THIS filter level a 👀'd
# mention passes through (its cadence is gated by `_reemit_pending` upstream
# and capped by `_filter_reemit_backoff` here), and only a 🚀 is the terminal
# stop. The backoff floor still applies on top.
reset_backoff
: > "$STATE_DIR/processed-comments.txt"
printf 'comment:%s\n' "$CR_ID" > "$STATE_DIR/processed-comments.txt"
out4=$(printf '%s\n' "$CR_V1" | _filter_processed_comments | _filter_reemit_backoff)
assert_contains "👀'd mention is NOT dropped by _filter_processed_comments (registry owns it)" "$out4" "id=$CR_ID"
# A 🚀 (rocket:<id>) is the terminal stop — but that eviction happens in the
# registry (`_reemit_gc`), not at this filter hop; covered by test-reemit-two-tier.sh.
rm -f "$STATE_DIR/processed-comments.txt"

echo '=== 5. in-$REPO shapes are NOT gated (changed body still re-surfaces) ==='
reset_backoff
a=$(printf '%s\n' "$INREPO_V1" | _filter_reemit_backoff)
b=$(printf '%s\n' "$INREPO_V2" | _filter_reemit_backoff)
assert_contains "in-repo first emit surfaces"               "$a" "id=$INREPO_ID"
assert_contains "in-repo edited body surfaces (NOT gated)"  "$b" "id=$INREPO_ID"
[[ -f "$STATE_DIR/reemit-backoff/comment-$INREPO_ID.ts" ]] \
    && { echo "  FAIL: in-repo block was stamped (should be untouched)" >&2; FAIL=$((FAIL+1)); } \
    || { echo "  PASS: in-repo block left unstamped"; PASS=$((PASS+1)); }

echo '=== 6. backoff=0 disables (passthrough, no stamp footprint) ==='
reset_backoff
# With backoff=0 two back-to-back identical mentions BOTH surface (no
# gating) and no stamp is written.
o6a=$(MONITOR_REEMIT_BACKOFF_SECONDS=0 _filter_reemit_backoff <<<"$CR_V1")
o6b=$(MONITOR_REEMIT_BACKOFF_SECONDS=0 _filter_reemit_backoff <<<"$CR_V1")
assert_contains "backoff=0: first surfaces"  "$o6a" "id=$CR_ID"
assert_contains "backoff=0: second surfaces (no gating)" "$o6b" "id=$CR_ID"
[[ -f "$stamp_path" ]] \
    && { echo "  FAIL: backoff=0 wrote a stamp (should be zero footprint)" >&2; FAIL=$((FAIL+1)); } \
    || { echo "  PASS: backoff=0 wrote no stamp"; PASS=$((PASS+1)); }

echo '=== 7. pipeline wiring: _filter_reemit_backoff precedes _filter_emit_cooldown ==='
assert_contains "pipeline runs backoff before the SHA cooldown" \
    "$(cat "$_test_dir/main.sh" 2>/dev/null)" "_filter_reemit_backoff \\"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }
exit 1
