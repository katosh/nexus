#!/usr/bin/env bash
# Tests for monitor/watcher/_resurface_cap.sh and its two integration
# points — `_emit_cooldown_flush` (_emit_filters.sh) and
# `_compose_emit_should_bypass_dedup` (_emit_dedup.sh). Issue #3.
#
# Coverage:
#   backoff        - doubling per repeat, capped, disabled cases
#   cap            - trips at max, 0 = uncapped
#   drop record    - written once, logged to watcher-unstick.log,
#                    cleared by an edit
#   all-repeats    - the no-new-information predicate, incl. every
#                    conservative fallback
#   dropped emit   - one-shot section, consumed on read
#   INTEGRATION    - the 54-repeat flood is actually bounded end-to-end
#                    through _filter_emit_cooldown, and an edited
#                    comment still resurfaces immediately
#   INTEGRATION    - a repeat no longer bypasses the dedup gate, while
#                    a first-time comment still does
#
# Run: bash monitor/watcher/test-resurface-cap.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
CAP="$_repo_root/monitor/watcher/_resurface_cap.sh"
FILTERS="$_repo_root/monitor/watcher/_emit_filters.sh"
DEDUP="$_repo_root/monitor/watcher/_emit_dedup.sh"
for f in "$CAP" "$FILTERS" "$DEDUP"; do
    [[ -f "$f" ]] || { echo "not found: $f" >&2; exit 1; }
done

. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR/emit-history"

# shellcheck disable=SC1090
. "$CAP"
# shellcheck disable=SC1090
. "$FILTERS"
# shellcheck disable=SC1090
. "$DEDUP"

export MONITOR_RESURFACE_MAX_REPEATS=4
export MONITOR_RESURFACE_BACKOFF_MAX_SECONDS=3600
export MONITOR_EMIT_COOLDOWN_SECONDS=300

# ---------------------------------------------------------------- 1
# Backoff: base * 2^(emits-1), capped.
assert_eq "backoff: never emitted → base"  "$(_resurface_effective_cooldown 300 0)" "300"
assert_eq "backoff: 1st repeat → base"     "$(_resurface_effective_cooldown 300 1)" "300"
assert_eq "backoff: 2nd repeat → 2x"       "$(_resurface_effective_cooldown 300 2)" "600"
assert_eq "backoff: 3rd repeat → 4x"       "$(_resurface_effective_cooldown 300 3)" "1200"
assert_eq "backoff: 4th repeat → 8x"       "$(_resurface_effective_cooldown 300 4)" "2400"
assert_eq "backoff: capped at max"         "$(_resurface_effective_cooldown 300 9)" "3600"
assert_eq "backoff: max 0 disables"        "$(MONITOR_RESURFACE_BACKOFF_MAX_SECONDS=0 _resurface_effective_cooldown 300 5)" "300"
assert_eq "backoff: non-numeric emits → base" "$(_resurface_effective_cooldown 300 xx)" "300"

# ---------------------------------------------------------------- 2
# Cap predicate.
_resurface_is_capped 3 && r=capped || r=under
assert_eq "cap: 3 emits under a max of 4" "$r" "under"
_resurface_is_capped 4 && r=capped || r=under
assert_eq "cap: 4 emits trips a max of 4" "$r" "capped"
MONITOR_RESURFACE_MAX_REPEATS=0 _resurface_is_capped 99 && r=capped || r=under
assert_eq "cap: max 0 is uncapped (legacy)" "$r" "under"

# ---------------------------------------------------------------- 3
# Drop record: written once, logged, cleared by an edit.
_resurface_record_dropped 5147150803 4
_resurface_record_dropped 5147150803 4      # idempotent
assert_eq "drop recorded exactly once" \
    "$(grep -c '^5147150803' "$STATE_DIR/resurface-dropped.tsv")" "1"
assert_file_exists "drop logged to watcher-unstick.log" "$STATE_DIR/watcher-unstick.log"
assert_contains "unstick log names the id" \
    "$(cat "$STATE_DIR/watcher-unstick.log")" "5147150803"
_resurface_is_dropped 5147150803 && r=yes || r=no
assert_eq "dropped id stays dropped" "$r" "yes"
_resurface_is_dropped 9999999999 && r=yes || r=no
assert_eq "unrelated id not dropped" "$r" "no"
_resurface_clear_dropped 5147150803
_resurface_is_dropped 5147150803 && r=yes || r=no
assert_eq "an edit clears the dropped record" "$r" "no"

# ---------------------------------------------------------------- 4
# The one-shot dropped section, consumed on read.
_resurface_record_dropped 5147150803 4
body=$(_resurface_dropped_emit_section "$STATE_DIR")
assert_contains "dropped section names the id"       "$body" "5147150803"
assert_contains "dropped section says not handled"   "$body" "NOT handled"
assert_contains "dropped section names the revival"  "$body" "Editing a"
body2=$(_resurface_dropped_emit_section "$STATE_DIR")
assert_empty "dropped section is one-shot (consumed)" "$body2"

# REGRESSION (skeptic req-001 finding 1): announcing must NOT destroy
# the durable dropped-record. The first cut truncated the TSV to
# consume the queue, but `_resurface_is_dropped` reads that same file —
# so after announcing, the id stopped counting as dropped, the next
# filter pass re-recorded it, and the "one-shot" section re-rendered on
# every cycle forever while watcher-unstick.log grew a line each time.
_resurface_is_dropped 5147150803 && r=yes || r=no
assert_eq "announcing preserves the durable dropped record" "$r" "yes"

# ---------------------------------------------------------------- 5
# The no-new-information predicate.
mk_body() {   # $1 dest, $2... id list
    local dest="$1"; shift
    {
        echo "=== nexus state changed ==="
        echo '--- eligible github comments ---'
        for i in "$@"; do echo "issue=7 id=$i user=operator"; done
        echo '--- dashboard ---'
        echo 'last updated: whenever'
    } > "$dest"
}
rm -f "$STATE_DIR/emit-history"/*.meta
mk_body "$WORK/b1" 111
_resurface_body_is_all_repeats "$WORK/b1" && r=all || r=notall
assert_eq "unseen id ⇒ not-all-repeats" "$r" "notall"

# `emits` is a POST-PASTE delivered count, so 0 = never actually
# delivered = this emit is its first delivery = genuinely new.
printf 'ts=1\nbody_sha=x\nemits=0\n' > "$STATE_DIR/emit-history/comment-111.meta"
_resurface_body_is_all_repeats "$WORK/b1" && r=all || r=notall
assert_eq "emits=0 (never delivered) ⇒ not-all-repeats" "$r" "notall"

printf 'ts=1\nbody_sha=x\nemits=1\n' > "$STATE_DIR/emit-history/comment-111.meta"
_resurface_body_is_all_repeats "$WORK/b1" && r=all || r=notall
assert_eq "emits=1 (already delivered once) ⇒ all-repeats" "$r" "all"

mk_body "$WORK/b2" 111 222
_resurface_body_is_all_repeats "$WORK/b2" && r=all || r=notall
assert_eq "one repeat + one new ⇒ not-all-repeats" "$r" "notall"

mk_body "$WORK/b3"
_resurface_body_is_all_repeats "$WORK/b3" && r=all || r=notall
assert_eq "no comment rows ⇒ not-all-repeats" "$r" "notall"

_resurface_body_is_all_repeats "$WORK/nonexistent" && r=all || r=notall
assert_eq "missing body ⇒ not-all-repeats" "$r" "notall"

# ---------------------------------------------------------------- 6
# INTEGRATION: the dedup bypass. A repeat must NOT bypass; a
# first-timer must still bypass exactly as before.
printf 'ts=1\nbody_sha=x\nemits=1\n' > "$STATE_DIR/emit-history/comment-111.meta"
_compose_emit_should_bypass_dedup "$WORK/b1" && r=bypass || r=gated
assert_eq "all-repeat body no longer bypasses the dedup gate" "$r" "gated"

rm -f "$STATE_DIR/emit-history/comment-222.meta"
_compose_emit_should_bypass_dedup "$WORK/b2" && r=bypass || r=gated
assert_eq "body with a genuinely new comment still bypasses" "$r" "bypass"

# ---------------------------------------------------------------- 7
# INTEGRATION: end-to-end through _filter_emit_cooldown. This is the
# regression test for the actual incident — feed the SAME comment block
# repeatedly with the clock advanced past each (backed-off) cooldown and
# assert the stream stops instead of running forever.
rm -f "$STATE_DIR/emit-history"/*.meta "$STATE_DIR/resurface-dropped.tsv" "$STATE_DIR/watcher-unstick.log"
BLOCK=$'issue=7 id=5147150803 user=operator\n  body: please look at this'

# Simulate the REAL per-cycle order — filter, then (on a successful
# paste) commit, then render the dropped section — rather than calling
# the pieces in isolation. The isolated version of this test is what
# let finding 1 through.
#   $1 = number of cycles, $2 = 1 if the paste succeeds each cycle
# Sets: EMITTED, SECTIONS_RENDERED
_replay_cycles() {
    local n="$1" paste_ok="$2" i out sec meta
    EMITTED=0; SECTIONS_RENDERED=0
    for i in $(seq 1 "$n"); do
        # Age the stamp past any backed-off cooldown so the ONLY thing
        # that can stop the stream is the cap.
        meta="$STATE_DIR/emit-history/comment-5147150803.meta"
        [[ -f "$meta" ]] && sed -i "s/^ts=.*/ts=1/" "$meta"
        out=$(printf '%s\n' "$BLOCK" | _filter_emit_cooldown)
        if [[ -n "$out" ]]; then
            EMITTED=$(( EMITTED + 1 ))
            if (( paste_ok == 1 )); then
                printf '%s\n%s\n' '--- eligible github comments ---' "$out" > "$STATE_DIR/body.$$"
                _resurface_commit_emitted "$STATE_DIR/body.$$"
                rm -f "$STATE_DIR/body.$$"
            fi
        fi
        sec=$(_resurface_dropped_emit_section "$STATE_DIR")
        [[ -n "$sec" ]] && SECTIONS_RENDERED=$(( SECTIONS_RENDERED + 1 ))
    done
}

_replay_cycles 12 1
assert_eq "unprocessed comment emits at most max_repeats times, then stops" \
    "$EMITTED" "4"
# REGRESSION (finding 1): across 12 real cycles the dropped section must
# be announced exactly ONCE, not on every cycle after the cap.
assert_eq "dropped section announced exactly once across 12 cycles" \
    "$SECTIONS_RENDERED" "1"
assert_eq "unstick log written exactly once" \
    "$(grep -c '5147150803' "$STATE_DIR/watcher-unstick.log" 2>/dev/null || true)" "1"
assert_contains "capped comment recorded as dropped" \
    "$(cat "$STATE_DIR/resurface-dropped.tsv" 2>/dev/null)" "5147150803"

# REGRESSION (skeptic req-001 finding 2): emits that are NEVER PASTED
# must not burn the cap's budget. The counter used to be stamped in the
# filter — upstream of the dedup gate, the over-limit hold and the
# paste — so an orchestrator suspended by the rate limit for ~75 min
# would exhaust all four repeats on emits that were composed and then
# HELD, permanently dropping a comment shown to the operator zero
# times. With the count committed post-paste, a run of held cycles
# costs nothing.
rm -f "$STATE_DIR/emit-history"/*.meta "$STATE_DIR/resurface-dropped.tsv" "$STATE_DIR/watcher-unstick.log"
_replay_cycles 12 0        # paste never succeeds (orchestrator held)
assert_eq "held emits never burn a repeat — comment survives" \
    "$(awk -F= '/^emits=/{print $2}' "$STATE_DIR/emit-history/comment-5147150803.meta")" "0"
_resurface_is_dropped 5147150803 && r=yes || r=no
assert_eq "a comment never delivered is never dropped" "$r" "no"
assert_eq "no dropped section rendered while held" "$SECTIONS_RENDERED" "0"

# ...and once pastes start succeeding it gets its FULL budget.
_replay_cycles 12 1
assert_eq "after the hold clears, the full repeat budget is available" \
    "$EMITTED" "4"

# Uncapped config reproduces the OLD unbounded behaviour — proving the
# cap is the thing doing the bounding, not some incidental change.
rm -f "$STATE_DIR/emit-history"/*.meta "$STATE_DIR/resurface-dropped.tsv"
emitted=0
for attempt in $(seq 1 12); do
    meta="$STATE_DIR/emit-history/comment-5147150803.meta"
    [[ -f "$meta" ]] && sed -i "s/^ts=.*/ts=1/" "$meta"
    out=$(printf '%s\n' "$BLOCK" | MONITOR_RESURFACE_MAX_REPEATS=0 _filter_emit_cooldown)
    if [[ -n "$out" ]]; then
        emitted=$(( emitted + 1 ))
        printf '%s\n%s\n' '--- eligible github comments ---' "$out" > "$STATE_DIR/body.$$"
        MONITOR_RESURFACE_MAX_REPEATS=0 _resurface_commit_emitted "$STATE_DIR/body.$$"
        rm -f "$STATE_DIR/body.$$"
    fi
done
assert_eq "max_repeats=0 restores unbounded resurfacing" "$emitted" "12"

# ---------------------------------------------------------------- 8
# INTEGRATION: an EDITED comment revives a dropped id and resurfaces
# immediately. Without this an operator's only recourse for a dropped
# comment would be delete-and-repost.
rm -f "$STATE_DIR/emit-history"/*.meta "$STATE_DIR/resurface-dropped.tsv"
for attempt in $(seq 1 6); do
    meta="$STATE_DIR/emit-history/comment-777.meta"
    [[ -f "$meta" ]] && sed -i "s/^ts=.*/ts=1/" "$meta"
    out=$(printf 'issue=7 id=777 user=operator\n  body: original\n' | _filter_emit_cooldown)
    if [[ -n "$out" ]]; then
        printf '%s\n%s\n' '--- eligible github comments ---' "$out" > "$STATE_DIR/b777"
        _resurface_commit_emitted "$STATE_DIR/b777"; rm -f "$STATE_DIR/b777"
    fi
done
_resurface_is_dropped 777 && r=yes || r=no
assert_eq "id 777 dropped after the cap" "$r" "yes"

out=$(printf 'issue=7 id=777 user=operator\n  body: EDITED text\n' | _filter_emit_cooldown)
assert_contains "edited comment resurfaces despite the cap" "$out" "id=777"
_resurface_is_dropped 777 && r=yes || r=no
assert_eq "edit cleared the dropped record" "$r" "no"

# And the counter restarted at ZERO — the edited body has been let
# through the filter but not yet committed as delivered, so it gets its
# own full budget.
assert_eq "edit resets the repeat counter to 0 (undelivered)" \
    "$(awk -F= '/^emits=/{print $2}' "$STATE_DIR/emit-history/comment-777.meta")" "0"

# ---------------------------------------------------------------- 9
# A comment that is never repeated must be entirely unaffected.
rm -f "$STATE_DIR/emit-history"/*.meta "$STATE_DIR/resurface-dropped.tsv"
out=$(printf 'issue=7 id=888 user=operator\n  body: first sighting\n' | _filter_emit_cooldown)
assert_contains "a first-time comment passes through untouched" "$out" "id=888"
assert_contains "its body preview survives" "$out" "first sighting"

th_summary_and_exit
