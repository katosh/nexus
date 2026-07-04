#!/usr/bin/env bash
# Tests for the cross-repo re-emit-until-acked registry (_reemit.sh) and
# its integration with the shared emit pipeline. Hermetic: no live GitHub
# — the only network surface (the GC live-reaction recheck) is exercised
# through an injected `gh` stub via MONITOR_REEMIT_GH_CMD.
#
# Regression target: nexus-code#236 / the "#310/#311 never surfaced"
# incident. A cross-repo `mention=` bot-mention comment surfaced through
# the deliveries path exactly ONCE (emit-once, cursor-gated, destructively
# drained); a single dropped paste lost it with no retry. The registry
# makes such comments re-emit until the bot 👀-acks them, while in-$REPO
# comments are left to github_poll's existing live-reaction backstop.
#
# Asserts:
#   1. register: a fresh cross-repo `mention=` block is recorded; an
#      in-$REPO block is NOT (github_poll covers it).
#   2. re-emit PAST the one-shot drain: with the registry re-fed once its
#      FAST-tier cadence elapses, the block keeps surfacing through
#      `_gh_filter_dedup_pipeline` — and the MUTATION (no registry) does NOT.
#   3. two-tier reaction policy (your-org/nexus-code#360): a `comment:<id>`
#      👀 demotes the entry to the SLOW (6h) tier — it does NOT stop, it
#      re-emits only after the slow window; a `rocket:<id>` 🚀 EVICTS it
#      (the now-meaningful terminal STOP).
#   4. survives restart: the durable registry file re-feeds after the
#      functions are re-sourced (process restart) — STATE_DIR persists.
#   5. no storm: the emit cooldown + fast-tier cadence throttle re-emit.
#   6. GC bounds: max-age eviction (loud log); live-reaction recheck demotes
#      on 👀 and evicts on 🚀; recheck is throttled per cooldown.
#   7. master switch off ⇒ no registry, no re-emit.
#
# Run: bash monitor/watcher/test-reemit-until-acked.sh

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
assert_rc() {
    local label="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — rc got %s want %s\n' "$label" "$got" "$want" >&2; FAIL=$((FAIL+1)); fi
}

# ---- harness ----
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
REPO="your-org/your-nexus"
USER_LOGIN="operator"
BOT_LOGIN="your-org-bot"
CROSS_REPO_SURFACE="mention_only"
MONITOR_REEMIT_ENABLED="true"
MONITOR_REEMIT_LIVE_RECHECK="false"   # default off in tests; flipped in the GC live test
MONITOR_REEMIT_MAX_AGE_SECONDS="259200"
MONITOR_EMIT_COOLDOWN_SECONDS="0"     # most tests want "re-feed surfaces every tick"
export STATE_DIR REPO USER_LOGIN BOT_LOGIN CROSS_REPO_SURFACE \
       MONITOR_REEMIT_ENABLED MONITOR_REEMIT_LIVE_RECHECK \
       MONITOR_REEMIT_MAX_AGE_SECONDS MONITOR_EMIT_COOLDOWN_SECONDS

. "$_test_dir/_github.sh"
. "$_test_dir/_emit_filters.sh"
. "$_test_dir/_reemit.sh"
# `_gh_filter_dedup_pipeline` carries heavy top-level state in main.sh;
# extract just the function body and eval it (same trick as
# test-eligibility-staleness.sh).
fn_def=$(awk '
    $0 ~ "^_gh_filter_dedup_pipeline\\(\\) \\{$" { capture=1 }
    capture { print; if ($0 == "}") capture=0 }
' "$_test_dir/main.sh")
[[ -n "$fn_def" ]] || { echo "setup: could not extract _gh_filter_dedup_pipeline" >&2; exit 1; }
eval "$fn_def"

# A cross-repo bot-mention block (the real nexus-code#310 shape) and an
# in-$REPO block. The cross-repo body @-mentions the bot so the
# mention_only cross-repo gate keeps it.
CR_ID="4746440400"
CR_BLOCK=$'mention=your-org/nexus-code kind=pr n=310 id=4746440400 author=operator\n  body: @your-org-bot could we resolve this without a home-dir install?'
INREPO_ID="555000111"
INREPO_BLOCK=$'issue=236 id=555000111 author=operator\n  body: in-repo comment, github_poll backstops this'

reset_state() {
    rm -f "$STATE_DIR/unacked-mentions.lines" "$STATE_DIR/unacked-mentions.lock" \
          "$STATE_DIR/processed-comments.txt" "$STATE_DIR/emit-suppression.lines" \
          "$STATE_DIR/watcher.log" 2>/dev/null || true
    rm -rf "$STATE_DIR/emit-history" 2>/dev/null || true
}

# Mirror compose_emit's gh_now composition (drained + github_poll + registry).
compose_gh_now() {
    local drained="$1" github_poll="$2"
    {
        printf '%s\n' "$drained"
        printf '%s\n' "$github_poll"
        _reemit_pending
    } | _gh_filter_dedup_pipeline
}

# Two-tier cadence helpers (your-org/nexus-code#360). `_reemit_pending` now
# gates re-feed on a per-entry `last_reemit=` stamp (fast tier =
# MONITOR_REEMIT_NOEYES_MINUTES, slow tier = MONITOR_REEMIT_NOROCKET_HOURS),
# so simulating "a cadence window elapsed" means backdating that stamp.
#   set_last_reemit <seconds-ago>  — every entry last emitted that long ago.
#   expire_reemit                  — last_reemit=0 → due under BOTH tiers.
set_last_reemit() {
    [[ -f "$reg" ]] || return 0
    sed -i "s/last_reemit=[0-9]*/last_reemit=$(( $(date +%s) - ${1:-0} ))/g" "$reg"
}
expire_reemit() {
    [[ -f "$reg" ]] || return 0
    sed -i "s/last_reemit=[0-9]*/last_reemit=0/g" "$reg"
}

# ===================================================================
echo '=== 1. register: cross-repo recorded, in-$REPO ignored ==='
reset_state
printf '%s\n%s\n' "$CR_BLOCK" "$INREPO_BLOCK" | _reemit_register
reg="$STATE_DIR/unacked-mentions.lines"
assert_contains     "registry has cross-repo id"        "$(cat "$reg" 2>/dev/null)" "id=$CR_ID"
assert_not_contains "registry omits in-\$REPO id"        "$(cat "$reg" 2>/dev/null)" "id=$INREPO_ID"
pending=$(_reemit_pending)
assert_contains     "pending re-feeds cross-repo header" "$pending" "mention=your-org/nexus-code"
assert_not_contains "pending strips # meta bookkeeping"  "$pending" "# meta"

echo '=== 1b. register is idempotent (no duplicate on re-register) ==='
printf '%s\n' "$CR_BLOCK" | _reemit_register
cnt=$(grep -cE "^mention=.*id=$CR_ID" "$reg")
assert_rc "single registry entry for id after double register" "1" "$cnt"

# ===================================================================
echo '=== 2. re-emit PAST the one-shot drain (registry re-feeds, FAST tier) ==='
reset_state
printf '%s\n' "$CR_BLOCK" | _reemit_register
# Tick 1: the fresh delivery surfaces AND gets registered.
out=$(compose_gh_now "$CR_BLOCK" "")
assert_contains "tick1 surfaces the cross-repo comment" "$out" "id=$CR_ID"
# Tick 2 + 3: NO fresh delivery, NO github_poll — only the registry. The
# un-👀'd entry is FAST tier, so once its cadence window elapses it re-feeds.
out2=$(expire_reemit; compose_gh_now "" "")
assert_contains "tick2 RE-emits from registry (no fresh delivery)" "$out2" "id=$CR_ID"
out3=$(expire_reemit; compose_gh_now "" "")
assert_contains "tick3 still re-emits (until acked)" "$out3" "id=$CR_ID"

echo '=== 2-MUTATION: without the registry, tick2 loses the comment ==='
# Models the pre-fix emit-once path: drained-once, registry not consulted.
reset_state
mut_tick2=$( { printf '%s\n' ""; printf '%s\n' ""; } | _gh_filter_dedup_pipeline )
assert_not_contains "pre-fix: tick2 has nothing to re-emit" "$mut_tick2" "id=$CR_ID"

# ===================================================================
echo '=== 3. two-tier: 👀 → SLOW (6h, not stop); 🚀 → STOP (evict) ==='
reset_state
MONITOR_REEMIT_NOEYES_MINUTES=5; MONITOR_REEMIT_NOROCKET_HOURS=6
export MONITOR_REEMIT_NOEYES_MINUTES MONITOR_REEMIT_NOROCKET_HOURS
printf '%s\n' "$CR_BLOCK" | _reemit_register
# bot 👀 (comment:<id>) → GC demotes to tier=slow; does NOT evict (#360).
printf 'comment:%s\n' "$CR_ID" > "$STATE_DIR/processed-comments.txt"
_reemit_gc
assert_contains     "👀: entry RETAINED (not evicted)" "$(cat "$reg" 2>/dev/null)" "id=$CR_ID"
assert_contains     "👀: entry demoted to tier=slow"   "$(cat "$reg" 2>/dev/null)" "tier=slow"
# slow entry, last emit 10 min ago → NOT due (6h cadence).
set_last_reemit 600
out=$(compose_gh_now "" "")
assert_not_contains "👀/slow: does NOT re-emit within the 6h window" "$out" "id=$CR_ID"
# slow entry, last emit >6h ago → DUE ("still on track?" nudge).
set_last_reemit 21700
out=$(compose_gh_now "" "")
assert_contains     "👀/slow: re-emits after the 6h window elapses" "$out" "id=$CR_ID"
# bot 🚀 (rocket:<id>) → GC evicts → STOP (the now-meaningful terminal).
printf 'rocket:%s\n' "$CR_ID" >> "$STATE_DIR/processed-comments.txt"
_reemit_gc
assert_not_contains "🚀: entry evicted from registry"  "$(cat "$reg" 2>/dev/null)" "id=$CR_ID"
assert_contains     "🚀: eviction logged (done)"       "$(cat "$STATE_DIR/watcher.log" 2>/dev/null)" "reemit-gc: evicted id=$CR_ID reason=rocket"

# ===================================================================
echo '=== 4. survives a watcher restart (durable file) ==='
reset_state
printf '%s\n' "$CR_BLOCK" | _reemit_register
# Simulate process restart: drop + re-source the functions. STATE_DIR
# (the durable registry) is untouched, exactly as on a --replace.
unset -f _reemit_pending _reemit_register _reemit_gc _reemit_enabled _reemit_registry_path
. "$_test_dir/_reemit.sh"
out=$(compose_gh_now "" "")
assert_contains "post-restart: registry still re-emits" "$out" "id=$CR_ID"

# ===================================================================
echo '=== 5. no storm: emit cooldown throttles re-emit to one/window ==='
reset_state
MONITOR_EMIT_COOLDOWN_SECONDS=300; export MONITOR_EMIT_COOLDOWN_SECONDS
printf '%s\n' "$CR_BLOCK" | _reemit_register
out1=$(compose_gh_now "" ""); assert_contains     "cooldown: first re-emit surfaces"        "$out1" "id=$CR_ID"
out2=$(compose_gh_now "" ""); assert_not_contains "cooldown: immediate second is throttled" "$out2" "id=$CR_ID"
# Expire ALL THREE cadence gates that now coexist → next tick re-emits
# (cadence, not silence): the SHA cooldown (`emit-history`), the #361
# body-independent re-emit backoff (`reemit-backoff`, hop 7), and the #362
# registry fast-tier `last_reemit`. For an UNCHANGED body all gate at the
# same window, so the re-emit surfaces only once every gate has elapsed.
old_ts=$(( $(date +%s) - 3600 ))
meta="$STATE_DIR/emit-history/comment-$CR_ID.meta"
if [[ -f "$meta" ]]; then
    sha=$(awk -F= '/^body_sha=/{sub(/^body_sha=/,"");print;exit}' "$meta")
    printf 'ts=%s\nbody_sha=%s\n' "$old_ts" "$sha" > "$meta"
fi
backoff_stamp="$STATE_DIR/reemit-backoff/comment-$CR_ID.ts"
[[ -f "$backoff_stamp" ]] && printf '%s\n' "$old_ts" > "$backoff_stamp"
expire_reemit
out3=$(compose_gh_now "" ""); assert_contains "cooldown: re-emits after window elapses" "$out3" "id=$CR_ID"
MONITOR_EMIT_COOLDOWN_SECONDS=0; export MONITOR_EMIT_COOLDOWN_SECONDS

# ===================================================================
echo '=== 6a. GC max-age eviction (safety valve, logged) ==='
reset_state
printf '%s\n' "$CR_BLOCK" | _reemit_register
# Backdate first_seen well past a tiny max-age.
sed -i "s/first_seen=[0-9]*/first_seen=$(( $(date +%s) - 100000 ))/" "$reg"
MONITOR_REEMIT_MAX_AGE_SECONDS=10; export MONITOR_REEMIT_MAX_AGE_SECONDS
_reemit_gc
assert_not_contains "max-age: aged entry evicted"  "$(cat "$reg" 2>/dev/null)" "id=$CR_ID"
assert_contains     "max-age: eviction logged loud" "$(cat "$STATE_DIR/watcher.log" 2>/dev/null)" "reason=max-age"
MONITOR_REEMIT_MAX_AGE_SECONDS=259200; export MONITOR_REEMIT_MAX_AGE_SECONDS

echo '=== 6b. GC live-reaction recheck: 👀 → slow (keep), 🚀 → evict ==='
reset_state
printf '%s\n' "$CR_BLOCK" | _reemit_register
# processed-comments empty (cache "lost"), but the bot 👀'd live → the live
# recheck must demote to slow, NOT evict (a 👀 is acked, not done; #360).
ghstub_acked() {
    [[ "$1" == "api" ]] || return 1
    cat <<'JSON'
[ {"content":"eyes","user":{"login":"your-org-bot[bot]"}} ]
JSON
}
export -f ghstub_acked
MONITOR_REEMIT_LIVE_RECHECK=true; MONITOR_REEMIT_GH_CMD=ghstub_acked
export MONITOR_REEMIT_LIVE_RECHECK MONITOR_REEMIT_GH_CMD
_reemit_gc
assert_contains "live 👀: entry KEPT (not evicted)" "$(cat "$reg" 2>/dev/null)" "id=$CR_ID"
assert_contains "live 👀: demoted to tier=slow"     "$(cat "$reg" 2>/dev/null)" "tier=slow"
# A live 🚀 (done) → evict.
reset_state
printf '%s\n' "$CR_BLOCK" | _reemit_register
ghstub_rocket() {
    [[ "$1" == "api" ]] || return 1
    cat <<'JSON'
[ {"content":"rocket","user":{"login":"your-org-bot[bot]"}} ]
JSON
}
export -f ghstub_rocket
MONITOR_REEMIT_GH_CMD=ghstub_rocket; export MONITOR_REEMIT_GH_CMD
_reemit_gc
assert_not_contains "live 🚀: entry evicted"                 "$(cat "$reg" 2>/dev/null)" "id=$CR_ID"
assert_contains     "live 🚀: eviction logged rocket-live"   "$(cat "$STATE_DIR/watcher.log" 2>/dev/null)" "reason=rocket-live"

echo '=== 6c. GC live-recheck KEEPS an entry with only operator self-eyes ==='
reset_state
printf '%s\n' "$CR_BLOCK" | _reemit_register
ghstub_selfonly() {
    [[ "$1" == "api" ]] || return 1
    cat <<'JSON'
[ {"content":"eyes","user":{"login":"operator"}} ]
JSON
}
export -f ghstub_selfonly
MONITOR_REEMIT_GH_CMD=ghstub_selfonly; export MONITOR_REEMIT_GH_CMD
_reemit_gc
assert_contains "live-recheck: operator self-eye does NOT count as ack" "$(cat "$reg" 2>/dev/null)" "id=$CR_ID"
MONITOR_REEMIT_LIVE_RECHECK=false; export MONITOR_REEMIT_LIVE_RECHECK
unset MONITOR_REEMIT_GH_CMD

echo '=== 6d. _reemit_acked_live predicate rcs ==='
MONITOR_REEMIT_GH_CMD=ghstub_acked; export MONITOR_REEMIT_GH_CMD
_reemit_acked_live "your-org/nexus-code" "$CR_ID"; assert_rc "bot reaction ⇒ rc 0" "0" "$?"
MONITOR_REEMIT_GH_CMD=ghstub_selfonly; export MONITOR_REEMIT_GH_CMD
_reemit_acked_live "your-org/nexus-code" "$CR_ID"; assert_rc "only self-eye ⇒ rc 1" "1" "$?"
ghstub_fail() { return 7; }; export -f ghstub_fail
MONITOR_REEMIT_GH_CMD=ghstub_fail; export MONITOR_REEMIT_GH_CMD
_reemit_acked_live "your-org/nexus-code" "$CR_ID"; assert_rc "gh failure ⇒ rc 2 (unknown, don't evict)" "2" "$?"
unset MONITOR_REEMIT_GH_CMD

# ===================================================================
# Regression for the "bot's 👀/🚀 keeps re-emitting" incident
# (your-org/nexus-code): the live-recheck throttle USED to key off the
# comment's emit timestamp (comment-<id>.meta `ts=`), which the re-emit
# itself refreshes. Two failure modes followed, both reproduced below as
# RED-on-old / GREEN-on-new:
#   6e. an actively re-emitting comment (fresh emit stamp) STARVED its own
#       ack-detection — the bot's reaction was never seen, so it re-surfaced
#       for many cooldown windows.
#   6f. an entry that has NEVER surfaced (no emit stamp → last_emit=0)
#       BYPASSED the throttle and was rechecked on EVERY GC pass — hammering
#       the reactions endpoint for the whole foreign-operator backlog and
#       rate-limiting the legitimate rechecks. The fix throttles on a
#       dedicated per-entry `last_recheck=` stamp instead.
echo '=== 6e. live-recheck is NOT starved by an active re-emit (🚀 still detected) ==='
reset_state
printf '%s\n' "$CR_BLOCK" | _reemit_register
# Simulate the comment having JUST re-emitted: a FRESH last_reemit stamp. The
# recheck throttle keys on the SEPARATE `last_recheck=` field (absent here),
# NOT the emit cadence — so an actively re-emitting entry can still detect a
# 🚀 and stop. (Old emit-ts throttle would have skipped the recheck.)
set_last_reemit 0   # last_reemit=now (just re-emitted)
MONITOR_EMIT_COOLDOWN_SECONDS=300; export MONITOR_EMIT_COOLDOWN_SECONDS
MONITOR_REEMIT_LIVE_RECHECK=true; MONITOR_REEMIT_GH_CMD=ghstub_rocket
export MONITOR_REEMIT_LIVE_RECHECK MONITOR_REEMIT_GH_CMD
_reemit_gc
assert_not_contains "active-re-emit: 🚀 still detected + evicted (no starvation)" \
    "$(cat "$reg" 2>/dev/null)" "id=$CR_ID"
assert_contains     "active-re-emit: eviction logged rocket-live" \
    "$(cat "$STATE_DIR/watcher.log" 2>/dev/null)" "reason=rocket-live"

echo '=== 6f. recheck throttled to once/cooldown via last_recheck (no every-pass hammering) ==='
reset_state
printf '%s\n' "$CR_BLOCK" | _reemit_register   # NEVER surfaces → no emit-history meta
# Count reactions-endpoint calls across two back-to-back GC passes (same
# virtual `now`). With the dedicated last_recheck stamp the second pass must
# SKIP the recheck (cost bound); the old emit-ts throttle rechecked every pass.
calls_file="$STATE_DIR/acked_live_calls"; : > "$calls_file"
ghstub_count() { [[ "$1" == "api" ]] || return 1; echo x >> "$calls_file"; echo '[ {"content":"eyes","user":{"login":"operator"}} ]'; }
export -f ghstub_count
MONITOR_EMIT_COOLDOWN_SECONDS=300; export MONITOR_EMIT_COOLDOWN_SECONDS
MONITOR_REEMIT_LIVE_RECHECK=true; MONITOR_REEMIT_GH_CMD=ghstub_count
export MONITOR_REEMIT_LIVE_RECHECK MONITOR_REEMIT_GH_CMD
_reemit_gc            # pass 1: rechecks (not acked → kept), stamps last_recheck
assert_contains "throttle: last_recheck stamp written to the meta line" "$(cat "$reg" 2>/dev/null)" "last_recheck="
_reemit_gc            # pass 2: within cooldown → must NOT recheck again
calls=$(wc -l < "$calls_file" | tr -d ' ')
assert_rc "throttle: exactly ONE reactions call across two passes (no every-pass hammer)" "1" "$calls"
# And a still-unacked entry remains so it keeps re-emitting until acked.
assert_contains "throttle: un-acked entry retained for re-emit" "$(cat "$reg" 2>/dev/null)" "id=$CR_ID"
MONITOR_EMIT_COOLDOWN_SECONDS=0; export MONITOR_EMIT_COOLDOWN_SECONDS
MONITOR_REEMIT_LIVE_RECHECK=false; export MONITOR_REEMIT_LIVE_RECHECK
unset MONITOR_REEMIT_GH_CMD

# ===================================================================
echo '=== 7. master switch off ⇒ no registry, no re-emit ==='
reset_state
MONITOR_REEMIT_ENABLED=false; export MONITOR_REEMIT_ENABLED
printf '%s\n' "$CR_BLOCK" | _reemit_register
assert_rc        "disabled: registry file not created" "1" "$([[ -f "$reg" ]] && echo 0 || echo 1)"
out=$(_reemit_pending)
assert_rc        "disabled: pending is empty"           "0" "$([[ -z "$out" ]] && echo 0 || echo 1)"
MONITOR_REEMIT_ENABLED=true; export MONITOR_REEMIT_ENABLED

# ===================================================================
echo '=== 8. binary-safe re-feed: emoji + NEL (U+0085) body does NOT wedge ==='
# Regression: mention bodies carry UTF-8 emoji and U+0085 (NEL) bytes,
# which make GNU grep classify the registry file as BINARY. The pre-fix
# `_reemit_pending` (grep -vE) then emitted the literal
# "Binary file <path> matches" INSTEAD of the blocks — silently killing
# the re-feed and leaking that garbage into the eligible-comments stream
# (the live emit-gap symptom). awk-based stripping is byte-safe.
reset_state
# Build a cross-repo mention whose body carries a RAW 0x85 byte (lone NEL,
# invalid UTF-8 - exactly the "Non-ISO extended-ASCII ... NEL line
# terminators" shape of the live registry) plus an emoji. This invalid
# byte is what makes GNU grep flag the file binary; valid UTF-8 alone
# would not.
raw_nel=$'\x85'
EMOJI_ID="4790223904"
EMOJI_BLOCK=$'mention=your-org/nexus-code kind=pr n=345 id=4790223904 author=operator\n  body: @your-org-bot implement the full recommendation '"$raw_nel"$' step2 \U0001F680'
printf '%s\n' "$EMOJI_BLOCK" | _reemit_register
# RED demonstration baked in: the pre-fix `grep -vE` path LOSES the block -
# under a UTF-8 locale GNU grep treats the invalid-byte registry as binary,
# stops emitting the real rows, and instead emits the "Binary file ...
# matches" diagnostic. The awk-based fix used by _reemit_pending recovers it.
# Force the locale so binary detection is deterministic regardless of the
# runner's ambient locale.
#
# IMPORTANT — GNU grep changed BOTH the wording AND the stream of its
# binary-detection diagnostic across versions, so assert on neither literally:
#   - grep 3.1 (e.g. an older dev box's /bin/grep): "Binary file <path>
#     matches" on STDOUT.
#   - grep 3.11 (ubuntu-latest CI): "grep: <path>: binary file matches" on
#     STDERR (note: lowercase "binary file", different word order, grep: prefix).
# The pre-fix `_reemit_pending` did `grep ... 2>/dev/null`, so on a modern host
# the diagnostic vanished entirely and the re-feed silently lost the block (the
# live emit-gap). Capture BOTH streams (`2>&1`) and match the only stable token
# — the case-folded substring "binary file" — so the demonstration is
# grep-version-independent while still proving the old path could not faithfully
# re-feed the rows. Pin LC_ALL=C.UTF-8 so binary detection itself is deterministic.
raw_grep=$(LC_ALL=C.UTF-8 grep -vE '^# meta ' "$reg" 2>&1 || true)
assert_contains "pre-fix grep -v path emits a binary-file diagnostic instead of rows" \
    "$(printf '%s' "$raw_grep" | tr 'A-Z' 'a-z')" "binary file"
pend=$(_reemit_pending)
assert_contains     "pending re-feeds the real header (not binary stub)" "$pend" "id=$EMOJI_ID"
assert_not_contains "pending does NOT leak 'Binary file ... matches'"    "$pend" "Binary file"
# End-to-end: the comment surfaces through the full compose pipeline. The
# `_reemit_pending` probe above already stamped last_reemit; expire it so the
# fast-tier cadence is due again for this end-to-end re-feed.
surfaced=$(expire_reemit; compose_gh_now "" "")
assert_contains     "emoji/NEL mention surfaces end-to-end"  "$surfaced" "id=$EMOJI_ID"
assert_not_contains "no 'Binary file' garbage in emit"       "$surfaced" "Binary file"

echo '=== 9. registration scoped by PARTICIPATION; foreign @bot kept as direct=no (#359 round-2) ==='
# The deliveries log is global across every installed repo, so a raw drain
# carries cross-tenant blocks. compose_emit registers the drain THROUGH
# `_filter_cross_repo_surface` (the @bot-mention participation gate) — author
# is NOT a registration filter any more. Operator-authored → direct=yes;
# other-user-authored but bot-involved → direct=no RETAINED CONTEXT (kept,
# never direct-emitted); not-bot-involved → dropped (drained).
reset_state
FOREIGN_ID="4799999001"          # other-user, but @-mentions our bot → context
FOREIGN_BLOCK=$'mention=your-org/other-nexus kind=issue n=5 id=4799999001 author=other-nexus-bot[bot]\n  body: @your-org-bot could you take a look at this?'
NOISE_ID="4799999002"            # other-user, NO @bot mention → drained
NOISE_BLOCK=$'mention=your-org/other-nexus kind=issue n=6 id=4799999002 author=other-nexus-bot[bot]\n  body: internal note, no bot here'
# Mirror compose_emit's round-2 registration hop: drain | cross_repo_surface | register
printf '%s\n%s\n%s\n' "$FOREIGN_BLOCK" "$NOISE_BLOCK" "$CR_BLOCK" \
    | _filter_cross_repo_surface | _reemit_register
reg_after="$(cat "$reg" 2>/dev/null)"
assert_contains     "operator-authored mention registered"             "$reg_after" "id=$CR_ID"
# The operator block's own meta line carries direct=yes (grep isolates its id).
assert_contains     "operator block is direct=yes"                      "$(grep "id=$CR_ID" <<<"$reg_after")" "direct=yes"
assert_contains     "foreign @bot block PRESERVED (not drained)"        "$reg_after" "id=$FOREIGN_ID"
assert_contains     "foreign @bot block is direct=no (context)"         "$reg_after" "direct=no"
assert_not_contains "bot-uninvolved foreign noise DRAINED (dropped)"    "$reg_after" "id=$NOISE_ID"
# direct=no context must NEVER re-feed for direct emission, and the operator
# block must.
pend="$(_reemit_pending)"
assert_contains     "direct=yes operator block re-feeds"                "$pend" "id=$CR_ID"
assert_not_contains "direct=no context block does NOT re-feed"          "$pend" "id=$FOREIGN_ID"
# Guard the round-2 wiring statically: the register pre-pass is
# cross_repo_surface → register, and does NOT author-filter at registration.
main_src="$(cat "$_test_dir/main.sh" 2>/dev/null)"
assert_contains     "register pre-pass scopes by participation (cross_repo_surface)" "$main_src" "_filter_cross_repo_surface \\"
assert_contains     "register pre-pass feeds _reemit_register"                       "$main_src" "| _reemit_register"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }
exit 1
