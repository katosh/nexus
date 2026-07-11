#!/usr/bin/env bash
# Content-hash emit-dedup gate — the decide/record pair that sits
# between `compose_report > "$emit_body"` and `paste_with_retry` (plus
# their stable-hash and bypass helpers). Extracted verbatim from
# main.sh (your-org/your-nexus#180 seam S3); pure code movement, no
# logic change.
#
# Functions:
#   _compose_emit_stable_hash         — volatile-component-stripped
#                                       sha256 of an emit body
#   _compose_emit_should_bypass_dedup — operator-attention bypass
#                                       (eligible github comments)
#   _compose_emit_should_suppress     — decision half (pre-paste)
#   _compose_emit_record_emit         — record half (post-paste only)
#
# Side-effect-free: only function definitions, no top-level state.
# Caller globals (set by main.sh before the functions are CALLED —
# nothing is read at source time):
#   EMIT_DEDUP_HASH_FILE                  last-emitted stable hash
#   EMIT_DEDUP_TS_FILE                    epoch of that emit
#   EMIT_DEDUP_RING_FILE                  recent-hash ring (epoch<TAB>hash
#                                         per line, newest last); defaults
#                                         to ${EMIT_DEDUP_HASH_FILE}.ring
#   MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS  quiet-window knob (0 = off)
#   MONITOR_EMIT_DEDUP_RING_SIZE          ring depth (default 8; 1 =
#                                         legacy single-slot behavior)
#   log                                   watcher logger (function)
# THE single volatile-token strip (emit-gate-recover). Filter
# (stdin → stdout) that collapses every emit-body component known to
# legitimately change on every poll even when the workspace state has
# not shifted:
#   - the `=== nexus state changed at <iso> (<reason>) ===` header
#     (timestamp out, reason stays — it's content)
#   - the dashboard `last updated: <ts>` line
#   - per-window `idle Ns` / `idle NhNNm` and `idle-too-long …` ages
#   - `operator away Ns` / `away NhNNm` operator-engaged away ages
#     (the volatile token that defeated the full-state canonical gate
#     for weeks: one operator-engaged window made every render unique)
#   - `interrupted Ns` / `interrupted NhNNm` crash ages
#   - the `N awaiting-input` prelude scalar (a since-last-render delta
#     that toggles 1↔0 every cycle a worker re-pings — issue #152)
#   - the trailing `--- nexus-emit-sig <iso> <nonce> ---` footer
# Everything else — workspace counts, eligible-comments rows,
# pending-decisions rows, the local-diff payload, bell entries —
# flows through untouched, so a genuinely new decision / comment /
# count shift still produces a distinct form and surfaces promptly.
#
# This filter is shared by BOTH change-detection layers: the
# content-hash dedup gate below AND main.sh's `full_state_canonical`
# identity check (issue #104). Keeping one strip is load-bearing:
# the original regression happened precisely because renderers grew
# new wall-clock tokens (`operator away Ns`, `interrupted NhNNm`)
# and only some strips learned about them. ANY renderer change that
# adds a time-derived token to an emit row MUST extend this list.
_emit_volatile_strip() {
    sed -E '
        s/^=== nexus state changed at [^()]*\(([^)]*)\) ===$/=== state (\1) ===/
        /^last updated: /d
        s/idle-too-long [0-9]+h[0-9]+m/idle-too-long/g
        s/idle-too-long [0-9]+s/idle-too-long/g
        s/idle [0-9]+h[0-9]+m/idle/g
        s/idle [0-9]+s/idle/g
        s/away [0-9]+h[0-9]+m/away/g
        s/away [0-9]+s/away/g
        s/interrupted [0-9]+h[0-9]+m/interrupted/g
        s/interrupted [0-9]+s/interrupted/g
        s/[0-9]+ awaiting-input/awaiting-input/g
        /^--- nexus-emit-sig /d
    '
}

# Adaptive idle backoff for the full-state heartbeat (emit/exemption
# fidelity). Given how long the canonical full-state snapshot has been
# CONTINUOUSLY unchanged (idle_duration_s, measured by main.sh from the
# idle-streak anchor it resets on every genuine canonical change), return
# the effective safety-floor the suppression check should use this cycle.
#
# Rule: start at the base floor; double it each time sustained idle crosses
# the next power-of-two multiple of the base, capped at the max. With
# base=900 / max=3600 that is 900 (idle < 30m) → 1800 (30m ≤ idle < 60m) →
# 3600 (idle ≥ 60m). A genuine change resets idle_duration to ~0 (the caller
# re-anchors), so the floor snaps back to base and the heartbeat is
# responsive again. Disabled (enabled=false, base<=0, or max<=base) returns
# the base unchanged — exactly the pre-backoff fixed-floor behaviour.
#
# Pure: reads only its arg + the two config knobs; echoes one integer. Kept
# here beside the volatile strip because it is the other half of the
# full-state change-detection contract main.sh consumes.
#   $1  idle_duration_s (seconds the canonical has been unchanged)
_full_state_effective_floor() {
    local idle_s="${1:-0}"
    local base="${MONITOR_FULL_STATE_SAFETY_FLOOR_SECONDS:-900}"
    [[ "$base" =~ ^[0-9]+$ ]] || base=900
    [[ "$idle_s" =~ ^[0-9]+$ ]] || idle_s=0
    local enabled="${MONITOR_FULL_STATE_IDLE_BACKOFF_ENABLED:-true}"
    if [[ "$enabled" != "true" ]] || (( base <= 0 )); then
        printf '%s\n' "$base"; return 0
    fi
    local max="${MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS:-3600}"
    [[ "$max" =~ ^[0-9]+$ ]] || max=3600
    (( max <= base )) && { printf '%s\n' "$base"; return 0; }
    local eff="$base" thresh="$base"
    while (( idle_s >= thresh * 2 && eff * 2 <= max )); do
        eff=$(( eff * 2 )); thresh=$(( thresh * 2 ))
    done
    (( eff > max )) && eff="$max"
    printf '%s\n' "$eff"
}

# Stable-content sha256 of an emit body: the volatile strip above,
# hashed. Used by the dedup gate to decide whether the candidate emit
# duplicates a recently-pasted one.
_compose_emit_stable_hash() {
    local body_file="$1"
    [[ -f "$body_file" ]] || return 1
    _emit_volatile_strip < "$body_file" | sha256sum | awk '{print $1}'
}

# Return 0 (bypass dedup, emit unconditionally) when the body carries
# operator-attention signal that we must never silently drop, even on
# an identical-hash repeat.
#
# TWO surfaces, each cooldown- or dedup-gated AT ITS SOURCE (the #152
# lesson: only source-gated signal may bypass — see below):
#
#   1. Eligible github comments — any `id=<digits>` row inside the
#      `--- eligible github comments ---` section. Deduped at the source
#      (`_gh_filter_dedup_pipeline` marks each comment id seen), so by
#      the time one reaches here it is genuinely new and never floods;
#      the bypass guarantees an operator comment surfaces even in the
#      unlikely event its body hashes identically to a prior emit.
#
#   2. Request-inbox rows — any `request=<id>` row inside the
#      `--- requests ---` section (your-org/nexus-code#483). A request is
#      a worker/remote-client → orchestrator ask, `reply: required` ones
#      by definition operator-attention; suppressing one on an
#      identical-hash match was exactly the 2026-07-02T01:44:10 incident
#      (a `poll-requests` body suppressed after its cooldown had already
#      been stamped — recorded surfaced, never delivered). The bypass is
#      BOUNDED at the source, not here: a request row only renders when
#      DUE (never-delivered, or its per-id cooldown — default 300s,
#      stamped by requests_commit_emitted ONLY on a successful paste —
#      has elapsed), per-emit volume is capped by
#      MONITOR_REQUESTS_MAX_PER_EMIT, and an unacked request goes
#      `.failed` at max-age (default 3 days). Worst case is therefore one
#      paste per request per cooldown until ack or max-age — the designed
#      re-emit-until-acked cadence, not a flood. This does NOT
#      reintroduce the #152 resurface flood: that flood came from an
#      UNGATED source (a parked worker re-firing the same decision every
#      ~5s poll) whose bypass short-circuited the only gate it had;
#      requests are due-gated at the source with the stamp tied to
#      delivery, so a pasted body silences its own source for a full
#      cooldown.
#
# Pending decisions and awaiting-input USED to bypass here too, but
# that unconditional override was the resurface-flood root cause
# (issue #152): a parked worker re-firing the SAME `idle_prompt`
# decision (same fp) every poll — and toggling the `N awaiting-input`
# delta 1↔0 — re-emitted a byte-for-byte-identical body every ~5s,
# because the bypass short-circuited the content-hash gate before it
# could suppress. Both surfaces are now carried INTO the stable hash
# instead: a genuinely new or changed decision (new fp, flipped
# `unresolved`, new row) produces a distinct hash and still surfaces
# promptly, while an identical re-fire (including the acked-and-
# re-fired case, where the orchestrator removed the decision file and
# the worker immediately recreated the same fp) hashes identically and
# is suppressed within the quiet window. `awaiting-input` is stripped
# from the hash entirely — it is always shadowed by a pending-decision
# row (the `Notification` hook writes both, see worker-settings.json),
# so dropping its volatile counter loses no signal the operator wants.
# Returns 1 when neither surface applies (dedup may proceed).
_compose_emit_should_bypass_dedup() {
    local body_file="$1"
    [[ -f "$body_file" ]] || return 1
    if awk '
        /^--- eligible github comments ---$/ { sec = "gh"; next }
        /^--- requests ---$/                 { sec = "req"; next }
        /^--- /                              { sec = "" }
        sec == "gh"  && /id=[0-9]+/  { found = 1; exit }
        sec == "req" && /^request=/  { found = 1; exit }
        END { exit (found ? 0 : 1) }
    ' "$body_file"; then
        return 0
    fi
    return 1
}

# Resolve the ring path + depth. The ring (epoch<TAB>hash per line,
# newest last) remembers the last N distinct emitted bodies, not just
# the single most recent one. Depth 1 degrades to the pre-ring
# single-slot behavior.
#
# Why a ring (emit-gate-recover): the live 2026-07-06 flood was an
# A/B ALTERNATION — a parked worker flapping between two body shapes
# (parked-transition row ↔ pending-decision re-nag). Single-slot
# dedup never converges on an alternation: each body differs from
# the immediately-previous one, so both keep pasting forever. The
# ring collapses any small cycle of repeating shapes.
_emit_dedup_ring_file() {
    printf '%s' "${EMIT_DEDUP_RING_FILE:-${EMIT_DEDUP_HASH_FILE}.ring}"
}
_emit_dedup_ring_size() {
    local n="${MONITOR_EMIT_DEDUP_RING_SIZE:-8}"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 )) || n=8
    printf '%s' "$n"
}

# Decision half of the dedup gate. Called between
# `compose_report > "$emit_body"` and `paste_with_retry`. Returns:
#   0 → emit (caller proceeds to paste; state-record happens AFTER
#         a successful paste via `_compose_emit_record_emit`)
#   1 → suppress the paste (a single `emit-dedup: suppressed ...`
#         line goes to LOGFILE; no state mutation)
# Suppression fires only when ALL of:
#   - knob `MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS` > 0
#   - body does not satisfy `_compose_emit_should_bypass_dedup`
#   - body's stable hash equals ANY hash in the recent-emit ring
#   - time since that ring entry's emit < knob
# Knob = 0 short-circuits before any hash computation, so an
# operator can opt out cleanly without leaving stale state behind.
#
# NOT consulted for full-state cadence emits: the call site in
# main.sh skips this gate when `full_state_due == 1`, because those
# bodies were already adjudicated by the canonical identity check +
# safety-floor (issue #104) — an unchanged canonical suppresses
# there, and what survives is either a genuine state change or the
# safety-floor timeout HEARTBEAT. Running the (much longer,
# default-24h) quiet window on top would swallow the heartbeat and
# starve orchestrator-liveness/paste-channel freshness.
#
# The decision/record split is deliberate: if the paste actually
# fails (orchestrator over-limit, target window missing, tmux API
# glitch), the next compose tick must be allowed to retry the same
# body. Writing state pre-paste would suppress the retry and
# silently drop a real emit.
_compose_emit_should_suppress() {
    local body_file="$1" reason="${2:-unknown}"
    local quiet_max="${MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS:-86400}"
    [[ "$quiet_max" =~ ^[0-9]+$ ]] || quiet_max=86400
    (( quiet_max == 0 )) && return 1
    _compose_emit_should_bypass_dedup "$body_file" && return 1
    local new_hash now_ts ring_file
    new_hash=$(_compose_emit_stable_hash "$body_file") || return 1
    [[ -n "$new_hash" ]] || return 1
    now_ts=$(date +%s)
    ring_file=$(_emit_dedup_ring_file)
    local entry_ts entry_hash
    if [[ -f "$ring_file" ]]; then
        while IFS=$'\t' read -r entry_ts entry_hash; do
            [[ "$entry_ts" =~ ^[0-9]+$ ]] || continue
            [[ -n "$entry_hash" ]] || continue
            if [[ "$entry_hash" == "$new_hash" ]] && (( now_ts - entry_ts < quiet_max )); then
                log "emit-dedup: suppressed identical-hash emit (reason=${reason}, last_emit=${entry_ts}, hash=${new_hash:0:8})"
                return 0
            fi
        done < "$ring_file"
        return 1
    fi
    # No ring yet (first run after upgrade): fall back to the legacy
    # single-slot pair so an in-flight quiet window survives the
    # format migration. The next successful paste writes the ring.
    local last_hash last_ts
    last_hash=""
    last_ts=0
    [[ -f "$EMIT_DEDUP_HASH_FILE" ]] && last_hash=$(head -n 1 "$EMIT_DEDUP_HASH_FILE" 2>/dev/null || true)
    [[ -f "$EMIT_DEDUP_TS_FILE" ]]   && last_ts=$(head -n 1 "$EMIT_DEDUP_TS_FILE"   2>/dev/null || echo 0)
    [[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0
    if [[ "$new_hash" == "$last_hash" ]] && (( now_ts - last_ts < quiet_max )); then
        log "emit-dedup: suppressed identical-hash emit (reason=${reason}, last_emit=${last_ts}, hash=${new_hash:0:8})"
        return 0
    fi
    return 1
}

# Record half of the dedup gate. Called immediately after a
# successful `paste_with_retry`. Appends the body's (epoch, stable
# hash) to the ring — refreshing in place if the hash is already
# present — and trims to the configured depth; also refreshes the
# legacy single-slot pair (newest hash + epoch) for post-mortem
# tooling and the pre-ring fallback path. All writes atomic (tmp +
# rename). Silent no-op when the dedup knob is 0 — the gate is off,
# state is irrelevant, leaving stale files would only confuse a
# future re-enable.
_compose_emit_record_emit() {
    local body_file="$1"
    local quiet_max="${MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS:-86400}"
    [[ "$quiet_max" =~ ^[0-9]+$ ]] || quiet_max=86400
    (( quiet_max == 0 )) && return 0
    local new_hash now_ts ring_file ring_size
    new_hash=$(_compose_emit_stable_hash "$body_file") || return 0
    [[ -n "$new_hash" ]] || return 0
    now_ts=$(date +%s)
    ring_file=$(_emit_dedup_ring_file)
    ring_size=$(_emit_dedup_ring_size)
    {
        if [[ -f "$ring_file" ]]; then
            grep -v $'\t'"${new_hash}\$" "$ring_file" 2>/dev/null || true
        fi
        printf '%s\t%s\n' "$now_ts" "$new_hash"
    } | tail -n "$ring_size" > "${ring_file}.tmp.$$" \
        && mv "${ring_file}.tmp.$$" "$ring_file" 2>/dev/null \
        || true
    printf '%s\n' "$new_hash" > "${EMIT_DEDUP_HASH_FILE}.tmp.$$" \
        && mv "${EMIT_DEDUP_HASH_FILE}.tmp.$$" "$EMIT_DEDUP_HASH_FILE" 2>/dev/null \
        || true
    printf '%s\n' "$now_ts"   > "${EMIT_DEDUP_TS_FILE}.tmp.$$" \
        && mv "${EMIT_DEDUP_TS_FILE}.tmp.$$"   "$EMIT_DEDUP_TS_FILE"   2>/dev/null \
        || true
    return 0
}
