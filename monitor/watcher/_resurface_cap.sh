#!/usr/bin/env bash
# Bounded comment resurfacing (issue #3).
#
# THE BUG, PRECISELY. An eligible-but-unprocessed GitHub comment
# re-emits forever. Two gates should have stopped it and neither does:
#
#   1. `_filter_emit_cooldown` (_emit_filters.sh) drops a comment block
#      only while its body-SHA is unchanged AND its last stamp is
#      younger than MONITOR_EMIT_COOLDOWN_SECONDS (default 300). So it
#      is not a cap — it is a *rate*: one re-emit per comment per 300 s,
#      forever. 12/hour. Over the 2026-07-31 observation window that is
#      exactly the 54 emits recorded for id=5147150803.
#
#   2. The content-hash dedup gate WOULD have collapsed those identical
#      bodies — except `_compose_emit_should_bypass_dedup` bypasses it
#      for ANY body carrying an `id=<digits>` row in the
#      `--- eligible github comments ---` section. Its docstring
#      justifies the bypass on the grounds that gh comments are
#      "deduped at the source ... so by the time one reaches here it is
#      genuinely new". That invariant holds for a FIRST emit and is
#      false for every resurface: the resurface path deliberately
#      re-injects an already-seen id. So the one gate that could have
#      collapsed the repeat is switched off by the repeat itself.
#
# The compounding failure mode the issue names — "the harder an item is
# to clear, the more times it is re-billed" — is that interaction. Each
# resurface landing on a live orchestrator is a full-price wake (1-7M
# tokens at the contexts orchestrators actually reach) carrying
# information the orchestrator has already seen.
#
# THE FIX, three parts matching the issue's three proposals:
#
#   1. CAP. Count emits per (id, body-SHA) in the existing
#      `emit-history/comment-<id>.meta`. Past
#      `MONITOR_RESURFACE_MAX_REPEATS` (default 4) the block is dropped
#      and the id recorded to `resurface-dropped.tsv` + logged to
#      `watcher-unstick.log`. Silently dropping is the risk; the log
#      line and the one-shot emit section are what make it safe.
#
#   2. BACKOFF. Between repeats the effective cooldown doubles —
#      300s, 600s, 1200s, ... capped at
#      MONITOR_RESURFACE_BACKOFF_MAX_SECONDS (default 3600). A stuck
#      item therefore costs a geometric, not linear, number of wakes
#      before the cap ends it. Same shape as
#      `_full_state_effective_floor`'s idle backoff.
#
#   3. NO-NEW-INFORMATION. `_resurface_body_is_all_repeats` lets the
#      dedup bypass distinguish a genuinely-new comment from a
#      resurface. Only a first-time id still bypasses; a body whose
#      comment rows are ALL repeats falls through to the content-hash
#      gate, which collapses it if nothing else in the emit changed.
#
# An EDITED comment resets the count — a new body-SHA is new
# information and must resurface promptly. That is the same principle
# `_filter_emit_cooldown` already applies, extended to the counter.
#
# Side-effect-free on source: function definitions only.
#
# Caller globals (read at CALL time):
#   STATE_DIR                              monitor/.state
#   MONITOR_RESURFACE_MAX_REPEATS          cap (0 = uncapped, legacy)
#   MONITOR_RESURFACE_BACKOFF_MAX_SECONDS  backoff ceiling (0 = no backoff)
#   log                                    watcher logger (optional)

_RESURFACE_DROPPED_TSV="resurface-dropped.tsv"

# Effective cooldown for the Nth repeat: base * 2^(emits-1), capped.
#   $1 base cooldown seconds   $2 emits so far (0 = never emitted)
# Returns the base unchanged when backoff is disabled or emits < 1, so
# the pre-#3 cadence is exactly recoverable via config.
_resurface_effective_cooldown() {
    local base="${1:-300}" emits="${2:-0}"
    [[ "$base"  =~ ^[0-9]+$ ]] || base=300
    [[ "$emits" =~ ^[0-9]+$ ]] || emits=0
    local max="${MONITOR_RESURFACE_BACKOFF_MAX_SECONDS:-3600}"
    [[ "$max" =~ ^[0-9]+$ ]] || max=3600
    if (( max <= 0 || base <= 0 || emits < 1 )); then
        printf '%s' "$base"; return 0
    fi
    # Double per repeat, CLAMPING at max rather than stopping at the
    # last value below it — the documented ladder is 300, 600, 1200,
    # 2400, 3600, … and must actually reach the ceiling.
    local eff="$base" i=1
    while (( i < emits )); do
        eff=$(( eff * 2 )); i=$(( i + 1 ))
        if (( eff >= max )); then eff="$max"; break; fi
    done
    printf '%s' "$eff"
}

# True (0) when this id has already been emitted at least
# MONITOR_RESURFACE_MAX_REPEATS times for the SAME body.
#   $1 emits so far
_resurface_is_capped() {
    local emits="${1:-0}"
    local max="${MONITOR_RESURFACE_MAX_REPEATS:-4}"
    [[ "$max"   =~ ^[0-9]+$ ]] || max=4
    [[ "$emits" =~ ^[0-9]+$ ]] || emits=0
    (( max > 0 )) || return 1           # 0 = uncapped (legacy behaviour)
    (( emits >= max ))
}

# Record a dropped id, exactly once, and log it loudly. The TSV is the
# safety net that makes capping acceptable: a dropped item is visible
# to the operator, and `_resurface_dropped_emit_section` surfaces it
# once more in the next full-state emit so it is not lost entirely.
#   $1 id   $2 emits
_resurface_record_dropped() {
    local id="${1:-}" emits="${2:-0}"
    [[ -n "$id" ]] || return 0
    local state="${STATE_DIR:-}"
    [[ -n "$state" && -d "$state" ]] || return 0
    local tsv="$state/$_RESURFACE_DROPPED_TSV"

    # Once per id: a capped item is re-considered on every cycle, but it
    # must only ever be RECORDED (and logged) once.
    if [[ -f "$tsv" ]] && grep -q "^${id}"$'\t' "$tsv" 2>/dev/null; then
        return 0
    fi
    local now; now=$(date +%s)
    # Columns: id, emits, ts, announced. `announced` is what makes the
    # emit section one-shot WITHOUT deleting the durable record — see
    # `_resurface_dropped_emit_section`.
    printf '%s\t%s\t%s\t0\n' "$id" "$emits" "$now" >> "$tsv" 2>/dev/null || return 0

    local msg="resurface-cap: comment id=${id} dropped after ${emits} emits without being processed — it will NOT be re-emitted; see ${tsv}"
    if declare -F log >/dev/null 2>&1; then
        log "$msg"
    fi
    # Also to the unstick log, which is where the operator already
    # looks for "the watcher gave up on something" (issue #3 asks for
    # exactly this file).
    local unstick="$state/watcher-unstick.log"
    printf '[%s] %s\n' "$(date -Is)" "$msg" >> "$unstick" 2>/dev/null || true
    return 0
}

# Has this id already been dropped? Capped items must stay dropped
# across cycles without re-entering the emit stream.
_resurface_is_dropped() {
    local id="${1:-}"
    [[ -n "$id" ]] || return 1
    local state="${STATE_DIR:-}"
    [[ -n "$state" ]] || return 1
    local tsv="$state/$_RESURFACE_DROPPED_TSV"
    [[ -f "$tsv" ]] || return 1
    grep -q "^${id}"$'\t' "$tsv" 2>/dev/null
}

# Clear an id's dropped record — called when its body changes, so an
# operator EDITING a dropped comment revives it. Without this, editing
# a comment the watcher gave up on would have no effect, which would be
# a genuinely bad failure mode: the operator's only recourse would be
# to delete and repost.
_resurface_clear_dropped() {
    local id="${1:-}"
    [[ -n "$id" ]] || return 0
    local state="${STATE_DIR:-}"
    [[ -n "$state" ]] || return 0
    local tsv="$state/$_RESURFACE_DROPPED_TSV"
    [[ -f "$tsv" ]] || return 0
    grep -q "^${id}"$'\t' "$tsv" 2>/dev/null || return 0
    local tmp="$tsv.tmp.$$"
    grep -v "^${id}"$'\t' "$tsv" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$tsv" 2>/dev/null || rm -f "$tmp"
    if declare -F log >/dev/null 2>&1; then
        log "resurface-cap: comment id=${id} edited — dropped record cleared, it will resurface"
    fi
    return 0
}

# POST-PASTE commit of the repeat counter. Call this immediately after
# a successful `paste_with_retry`, beside `_compose_emit_record_emit`.
#
# WHY THIS IS NOT DONE IN THE FILTER. The obvious place to count an
# emit is `_emit_cooldown_flush`, where the block is let through — and
# that is where the first cut of this counted. But that filter runs
# inside `_gh_filter_dedup_pipeline`, which is upstream of
# `_compose_emit_should_suppress`, upstream of
# `_over_limit_orchestrator_paused`, and upstream of the paste itself.
# Nothing rolls the count back when any of those drop the emit.
#
# The consequence was severe and silent: an orchestrator suspended by
# the Anthropic rate limit for ~75 minutes would burn all four repeats
# on emits that were composed and then HELD, and the comment would be
# permanently dropped having been shown to the operator ZERO times.
# (Skeptic req-001 finding 2.)
#
# main.sh already establishes exactly this discipline for
# `_compose_emit_record_emit` and `requests_commit_emitted` —
# "the decision/record split is deliberate: if the paste actually fails
# ... the next compose tick must be allowed to retry the same body".
# The cap must obey it too, and more strictly than they do: they lose a
# cooldown, this loses the comment.
#
# Pre-paste stamping was harmless while the cooldown was only a RATE
# (it always recovered on the next cycle). Turning it into a CAP is
# what made it destructive.
#
#   $1  the emit body that was just pasted
_resurface_commit_emitted() {
    local body_file="${1:-}"
    [[ -f "$body_file" ]] || return 0
    local state="${STATE_DIR:-}"
    [[ -n "$state" ]] || return 0
    local hist="$state/emit-history"
    [[ -d "$hist" ]] || return 0

    local ids id meta emits
    ids=$(awk '
        /^--- eligible github comments ---$/ { sec = 1; next }
        /^--- /                              { sec = 0 }
        sec && match($0, /id=[0-9]+/) {
            print substr($0, RSTART + 3, RLENGTH - 3)
        }
    ' "$body_file" 2>/dev/null)
    [[ -n "$ids" ]] || return 0

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        meta="$hist/comment-$id.meta"
        [[ -f "$meta" ]] || continue
        emits=$(awk -F= '/^emits=/{print $2; exit}' "$meta" 2>/dev/null)
        [[ "$emits" =~ ^[0-9]+$ ]] || emits=0
        emits=$(( emits + 1 ))
        # Rewrite in place, preserving ts/body_sha written by the filter.
        if awk -F= -v n="$emits" '
            /^emits=/ { next }
            { print }
            END { printf "emits=%s\n", n }
        ' "$meta" > "$meta.tmp.$$" 2>/dev/null; then
            mv -f "$meta.tmp.$$" "$meta" 2>/dev/null || rm -f "$meta.tmp.$$"
        else
            rm -f "$meta.tmp.$$"
        fi
    done <<<"$ids"
    return 0
}

# Proposal 3 — "an emit with no new information should not be sent at
# all". Returns 0 when the body's eligible-comments section contains at
# least one row AND every one of those ids is a REPEAT (already emitted
# at least once). The dedup-bypass caller uses this to stop resurfaces
# from switching off the content-hash gate, while leaving the bypass
# intact for genuinely-new comments.
#
# Returns 1 (not-all-repeats) when the section is absent, empty, or
# carries any first-time id — the conservative direction: on any doubt
# the bypass behaves exactly as it did before this change.
_resurface_body_is_all_repeats() {
    local body_file="${1:-}"
    [[ -f "$body_file" ]] || return 1
    local state="${STATE_DIR:-}"
    [[ -n "$state" ]] || return 1
    local hist="$state/emit-history"
    [[ -d "$hist" ]] || return 1

    local ids id meta emits
    ids=$(awk '
        /^--- eligible github comments ---$/ { sec = 1; next }
        /^--- /                              { sec = 0 }
        sec && match($0, /id=[0-9]+/) {
            print substr($0, RSTART + 3, RLENGTH - 3)
        }
    ' "$body_file" 2>/dev/null)
    [[ -n "$ids" ]] || return 1

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        meta="$hist/comment-$id.meta"
        emits=0
        if [[ -f "$meta" ]]; then
            emits=$(awk -F= '/^emits=/{print $2; exit}' "$meta" 2>/dev/null)
            [[ "$emits" =~ ^[0-9]+$ ]] || emits=0
        fi
        # `emits` is now a POST-PASTE delivered count (see
        # `_resurface_commit_emitted`), so emits==0 means "never
        # actually delivered" — this body is its first delivery, and
        # the emit is genuinely new. Any first-timer makes the whole
        # body new.
        (( emits >= 1 )) || return 1
    done <<<"$ids"
    return 0
}

# One-shot `--- resurface dropped ---` body. The issue's note: "a
# dropped item should also surface once in the next full-state emit so
# it is not lost entirely."
#
# ONE-SHOT VIA THE `announced` FLAG, NOT VIA TRUNCATION. The first cut
# of this truncated the TSV to consume the queue — but the SAME file is
# the durable dropped-record that `_resurface_is_dropped` reads. After
# truncation the id was no longer "dropped", so the next
# `_emit_cooldown_flush` re-hit `_resurface_is_capped` and re-recorded
# it: the section re-rendered on EVERY subsequent cycle and
# watcher-unstick.log grew a duplicate line each time. Exactly
# backwards from one-shot. (Caught by skeptic req-001 finding 1; the
# original test called the renderer twice with no intervening filter
# run, so it could not see the interaction.)
#
# So: mark rows announced and rewrite, never delete. The record stays
# durable, the announcement happens once.
_resurface_dropped_emit_section() {
    local state="${1:-${STATE_DIR:-}}"
    [[ -n "$state" ]] || return 0
    local tsv="$state/$_RESURFACE_DROPPED_TSV"
    [[ -s "$tsv" ]] || return 0

    # Only rows not yet announced. A missing 4th column (a TSV written
    # by a pre-fix build) counts as unannounced, so an in-flight upgrade
    # announces once and then settles.
    local rows
    rows=$(awk -F'\t' '$1 != "" && ($4 == "" || $4 == "0") {
        printf "  comment id=%s — %s emits, never processed\n", $1, $2
    }' "$tsv" 2>/dev/null)
    [[ -n "$rows" ]] || return 0

    # Mark announced, preserving every row.
    local tmp="$tsv.tmp.$$"
    if awk -F'\t' 'BEGIN{OFS="\t"} $1 != "" { $4 = 1; print }' "$tsv" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$tsv" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi

    printf 'The watcher stopped re-emitting these comments after\n'
    printf '%s unacknowledged repeats each. They are NOT handled:\n' "${MONITOR_RESURFACE_MAX_REPEATS:-4}"
    printf '%s\n' "$rows"
    printf 'Deal with each one directly, then react to close it out. Editing a\n'
    printf 'comment clears its dropped record and lets it resurface. The durable\n'
    printf 'record is monitor/.state/watcher-unstick.log.\n'
}
