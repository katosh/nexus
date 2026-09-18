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
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
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
# `log` is undefined here (main.sh owns it); _prune_processed_comments and
# `_reemit_log` call it. Production's `log` prints to stderr, which the
# launcher redirects into watcher.log — so append there, mirroring the
# effective destination. A no-op stub (what this was) makes every
# `_reemit_log` line UNOBSERVABLE, which is how a warning can be asserted
# green while reaching nobody.
log() { printf '[%s] %s\n' "$(date -Is)" "$*" >> "$STATE_DIR/watcher.log"; }

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

echo '=== 9. ISSUE-keyed mention (your-org/nexus-code#1500): the reaction target is the ISSUE, not a comment ==='
# WHAT THIS COVERS AND WHY IT WAS MISSING. Sections 1-8 above all use a
# COMMENT-keyed block (`kind=pr` + a comment database id), and the classifier
# was correct for exactly that shape — so the whole suite stayed green while
# every `issue_new=` mention (i.e. every new issue the operator opens in a
# cross-repo) re-emitted on the 5-minute FAST tier and could be evicted by
# neither a rocket nor eyes. A test asserting only the comment path is what
# let it through; this section asserts the ISSUE path.
#
# The `gh` stub emulates GitHub's real 404 surface rather than a generic
# failure: reactions exist ONLY at `repos/<r>/issues/<n>/reactions`, and the
# issue-COMMENT endpoint answers `HTTP 404` on stderr at rc 1, exactly as
# `gh api` does for an issue NUMBER fed to the comment endpoint. Before the
# fix the classifier asked the comment endpoint, got that 404, returned
# "unknown", and the entry was never evicted.
ISSUE_ID="1499"
ISSUE_BLOCK=$'mention=your-org/nexus-code kind=issue_new n=1499 id=1499 author=operator src=body\n  body: @your-org-bot ensure full consistency of the documentation'
# The block as it is ALREADY PERSISTED in a live registry — registered before
# `_deliveries.sh` learned to stamp `src=body`. The fix must classify this one
# too, or the live noise does not stop without hand-editing watcher state.
LEGACY_BLOCK=$'mention=your-org/nexus-code kind=issue_new n=1499 id=1499 author=operator\n  body: @your-org-bot ensure full consistency of the documentation'

gh_issue_only() {
    [[ "$1" == api ]] || return 1
    case "$2" in
        repos/*/issues/1499/reactions)
            printf '%s' '[{"content":"rocket","user":{"login":"your-org-bot[bot]"}},{"content":"eyes","user":{"login":"your-org-bot[bot]"}}]' ;;
        repos/*/issues/1499)
            printf 'open' ;;
        *)  printf 'gh: Not Found (HTTP 404)\n' >&2; return 1 ;;
    esac
}
export -f gh_issue_only

for label in "src=body (current emitter)" "legacy entry, no src= (already on disk)"; do
    case "$label" in
        src=body*) blk="$ISSUE_BLOCK" ;;
        *)         blk="$LEGACY_BLOCK" ;;
    esac
    reset_state
    printf '%s\n' "$blk" | _reemit_register
    assert_contains "issue-keyed entry registered — $label" "$(cat "$reg")" "id=$ISSUE_ID"
    MONITOR_REEMIT_LIVE_RECHECK=true MONITOR_REEMIT_GH_CMD=gh_issue_only _reemit_gc
    assert_not_contains "🚀 on the ISSUE evicts the issue-keyed entry — $label" \
        "$(cat "$reg" 2>/dev/null)" "id=$ISSUE_ID"
    assert_contains "eviction logged reason=rocket-live — $label" \
        "$(cat "$STATE_DIR/watcher.log" 2>/dev/null)" "reason=rocket-live"
done

echo '=== 10. _mention_target_key: which object carries the reaction (#1500) ==='
assert_eq "issue_new → the ISSUE, keyed on n (NOT on id)" "issue:1499" \
    "$(_mention_target_key 'mention=your-org/nexus-code kind=issue_new n=1499 id=1499 author=operator src=body')"
assert_eq "legacy issue_new without src= still resolves to the issue" "issue:1499" \
    "$(_mention_target_key 'mention=your-org/nexus-code kind=issue_new n=1499 id=1499 author=operator')"
assert_eq "body mention: id is the issue databaseId, n is the key" "issue:33" \
    "$(_mention_target_key 'cross_repo=external/repo-c kind=issue n=33 id=5003 author=operator src=body')"
assert_eq "PR OPEN marked src=body → the PR itself" "issue:12" \
    "$(_mention_target_key 'mention=your-org/nexus-code kind=pr n=12 id=987654321 author=operator src=body')"
assert_eq "conversation comment → the comment id" "comment:4746440400" \
    "$(_mention_target_key 'mention=your-org/nexus-code kind=pr n=310 id=4746440400 author=operator')"
assert_eq "PR review COMMENT (has path=) → the pulls/comments endpoint" "review_comment:555" \
    "$(_mention_target_key 'mention=your-org/nexus-code kind=pr_review n=9 id=555 author=operator path=monitor/x.sh')"
assert_eq "top-level PR review (no path=) → no reactable object" "none:9" \
    "$(_mention_target_key 'mention=your-org/nexus-code kind=pr_review n=9 id=555 author=operator')"
assert_eq "no identity at all → none:0 (fail closed)" "none:0" \
    "$(_mention_target_key 'mention=your-org/nexus-code kind=issue author=operator')"

echo '=== 11. permanent 404 vs TRANSIENT gh failure are DIFFERENT answers (#1500) ==='
# The constraint this fix had to respect: a 404 must become loud WITHOUT the
# transient arm losing its fail-soft behaviour. Asserted as two separate
# facts — the return codes, and that neither one evicts.
gh_404() { [[ "$1" == api ]] || return 1; printf 'gh: Not Found (HTTP 404)\n' >&2; return 1; }
gh_flaky() { return 7; }   # network/5xx shape: non-zero, nothing about 404
export -f gh_404 gh_flaky
out=$(MONITOR_REEMIT_GH_CMD=gh_404 _reemit_reaction_state x/y 1 'comment:1'); rc=$?
assert_eq "permanent 404 → rc 4, no output" "4|" "${rc}|${out}"
out=$(MONITOR_REEMIT_GH_CMD=gh_flaky _reemit_reaction_state x/y 1 'comment:1'); rc=$?
assert_eq "transient failure → rc 2, no output (unchanged fail-soft)" "2|" "${rc}|${out}"
out=$(MONITOR_REEMIT_GH_CMD=gh_404 _reemit_reaction_state x/y 9 'none:9'); rc=$?
assert_eq "no reactable object → rc 3, no call, no output" "3|" "${rc}|${out}"
# Endpoint selection is observable: capture the path the classifier asks for.
ASKED_FILE="$STATE_DIR/asked.txt"
gh_echo() { [[ "$1" == api ]] || return 1; printf 'ASKED %s\n' "$2" >> "$ASKED_FILE"; printf '[]'; }
export -f gh_echo; export ASKED_FILE
ask() { : > "$ASKED_FILE"; MONITOR_REEMIT_GH_CMD=gh_echo _reemit_reaction_state your-org/nexus-code "$1" "$2" >/dev/null; cat "$ASKED_FILE"; }
assert_contains "issue target asks the ISSUE endpoint" "$(ask 1499 issue:1499)" \
    "ASKED repos/your-org/nexus-code/issues/1499/reactions"
assert_contains "comment target asks the issue-COMMENT endpoint" "$(ask 4746440400 comment:4746440400)" \
    "ASKED repos/your-org/nexus-code/issues/comments/4746440400/reactions"
assert_contains "review-comment target asks the pulls/comments endpoint" "$(ask 555 review_comment:555)" \
    "ASKED repos/your-org/nexus-code/pulls/comments/555/reactions"
assert_contains "omitted target keeps the historical comment contract" "$(ask 4746440400 '')" \
    "ASKED repos/your-org/nexus-code/issues/comments/4746440400/reactions"

echo '=== 12. a TRANSIENT gh failure must NEVER evict a live mention (#1500 constraint) ==='
# The failure direction that would be WORSE than the bug. Same registry, same
# GC, only the stub differs: 404 and flaky both leave the entry standing.
for stub in gh_404 gh_flaky; do
    reset_state
    printf '%s\n' "$ISSUE_BLOCK" | _reemit_register
    MONITOR_REEMIT_LIVE_RECHECK=true MONITOR_REEMIT_GH_CMD="$stub" _reemit_gc
    assert_contains "$stub: entry RETAINED (no eviction on an unclassifiable probe)" \
        "$(cat "$reg" 2>/dev/null)" "id=$ISSUE_ID"
    assert_contains "$stub: entry stays tier=fast (not spuriously demoted)" \
        "$(cat "$reg" 2>/dev/null)" "tier=fast"
    # …and the two are told APART in the log: the permanent one is named, the
    # transient one stays quiet (a WARN on every flaky poll is noise that
    # trains the operator to ignore the line that matters).
    if [[ "$stub" == "gh_404" ]]; then
        assert_contains "$stub: permanent 404 is LOGGED, not silent" \
            "$(cat "$STATE_DIR/watcher.log" 2>/dev/null)" "HTTP 404"
    else
        assert_not_contains "$stub: transient failure logs NO 404 warning" \
            "$(cat "$STATE_DIR/watcher.log" 2>/dev/null)" "HTTP 404"
    fi
done

echo '=== 13. backoff stamp names its target kind and repo-scopes issue numbers (#1500) ==='
# `comment-1499.ts` for what was actually ISSUE #1499 is the artefact that
# made #1500 cost twenty minutes to localize, and an issue NUMBER is
# repo-LOCAL, so two repos' #1499 shared one stamp.
bdir="$STATE_DIR/reemit-backoff"; rm -rf "$bdir"
MONITOR_REEMIT_BACKOFF_SECONDS=300 _filter_reemit_backoff <<<"$ISSUE_BLOCK" >/dev/null
[[ -f "$bdir/issue-your-org_nexus-code-1499.ts" ]] \
    && { echo "  PASS: issue-keyed stamp is kind-qualified and repo-scoped"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: expected $bdir/issue-your-org_nexus-code-1499.ts; got: $(ls "$bdir" 2>/dev/null)" >&2; FAIL=$((FAIL+1)); }
[[ -f "$bdir/comment-1499.ts" ]] \
    && { echo "  FAIL: an ISSUE was stamped as a comment (the #1500 naming defect)" >&2; FAIL=$((FAIL+1)); } \
    || { echo "  PASS: no misleading comment-1499.ts"; PASS=$((PASS+1)); }
# Another repo's #1499 must NOT collide with the one above.
OTHER_BLOCK=$'mention=your-org/other-repo kind=issue_new n=1499 id=1499 author=operator src=body\n  body: @your-org-bot different repo, same number'
o13=$(MONITOR_REEMIT_BACKOFF_SECONDS=300 _filter_reemit_backoff <<<"$OTHER_BLOCK")
assert_contains "another repo's #1499 is NOT suppressed by the first repo's stamp" "$o13" "your-org/other-repo"
# And the comment spelling is byte-identical to the pre-change one, so stamps
# already on disk keep working with no migration.
rm -rf "$bdir"
MONITOR_REEMIT_BACKOFF_SECONDS=300 _filter_reemit_backoff <<<"$CR_BLOCK" >/dev/null
[[ -f "$bdir/comment-$CR_ID.ts" ]] \
    && { echo "  PASS: comment stamps keep the pre-change filename (no migration)"; PASS=$((PASS+1)); } \
    || { echo "  FAIL: comment stamp filename changed; existing stamps invalidated" >&2; FAIL=$((FAIL+1)); }
rm -rf "$bdir"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }
exit 1
