#!/usr/bin/env bash
# _requests.sh — the WATCHER side of the request inbox (agent-channel RFC
# Part B §2.4). Sourced by main.sh. Defines functions only; no side
# effects at source time.
#
# The producer/orchestrator facade is monitor/request-channel.sh (the
# `ng request` verbs). This module is the watcher's internal
# watch→claim→emit→re-emit→ack loop — there is no `ng` verb for it (the
# claim/emit is the watcher's exclusive job, RFC §2.7). It is the
# generalization of render_pending_decisions (_idle_probe.sh): same
# per-(key) cooldown re-emit, same "the cited file's rename stops the
# emit" self-clearing ack, extended with a per-emit cap + origin fairness
# for backlog stability (RFC §2.6).
#
# ── The discrete-request source contract (Part C §3.3) ────────────────
# This module is the reference implementation of the standardized
# discrete-request shape: a source (a) PRODUCES ack-gated emit blocks
# keyed by a stable id, and (b) lets the registry decide when an id is
# acked (here: acked == the file is no longer `.claimed.md`, because the
# orchestrator renamed it to `.done`/`.replied`/`.failed`). Pending
# decisions and cross-repo mentions are the other two discrete-request
# sources; migrating THEM onto a single shared registry (so this cooldown
# bookkeeping lives once) is RFC rows C1/C2 — parity-gated and explicitly
# deferred out of Phase 1 to avoid destabilizing the live emit loop. The
# contract is documented here so that migration is a mechanical later step.
#
# Lifecycle (filename suffix is the state):
#   .new.md      producer wrote it           → watcher claims: → .claimed.md
#   .claimed.md  watcher owns it, surfacing   → re-emit until acked
#   .replied.md  orchestrator replied (Part D)→ stop emitting; retain
#   .done.md     orchestrator acked, no body  → stop emitting; retain
#   .failed.md   malformed / max-age / fail   → stop emitting; retain
# Self-clearing: a `.claimed.md` the orchestrator renamed simply no longer
# matches the glob, so emission stops next poll — exactly like a removed
# decision file.

# Shared "rename is the signal" primitives (_chan_frontmatter_field etc.).
# Guarded so a double-source (main.sh + a test) is harmless.
if ! declare -f _chan_frontmatter_field >/dev/null 2>&1; then
    _requests_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    # shellcheck source=../_channel_lib.sh
    source "$_requests_self_dir/../_channel_lib.sh"
fi

# STATE_DIR is set by main.sh. For standalone (test) sourcing, derive it.
_requests_state_dir() {
    if [[ -n "${STATE_DIR:-}" ]]; then printf '%s' "$STATE_DIR"; return; fi
    if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then printf '%s' "$NEXUS_STATE_DIR"; return; fi
    if [[ -n "${NEXUS_ROOT:-}" ]]; then printf '%s/monitor/.state' "$NEXUS_ROOT"; return; fi
    printf '.state'
}

_requests_dir()        { printf '%s/requests' "$(_requests_state_dir)"; }
_requests_emit_state() { printf '%s/requests-emit-state.tsv' "$(_requests_state_dir)"; }

# Use the watcher's `log` when sourced into main.sh; else stderr.
_requests_log() {
    if declare -f log >/dev/null 2>&1; then log "requests: $*"; else printf 'requests: %s\n' "$*" >&2; fi
}

# Services registry path — mirrors _idle_probe.sh / _service_health.sh so
# the resolution never drifts. NEXUS_SERVICES_REGISTRY override, else
# $NEXUS_ROOT/monitor/services.registry, else this file's sibling monitor dir.
_requests_services_registry() {
    if [[ -n "${NEXUS_SERVICES_REGISTRY:-}" ]]; then printf '%s' "$NEXUS_SERVICES_REGISTRY"; return; fi
    if [[ -n "${NEXUS_ROOT:-}" ]]; then printf '%s/monitor/services.registry' "$NEXUS_ROOT"; return; fi
    printf '%s/services.registry' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
}

# True iff the confined remote channel is registered (its `nexus-remote-ssh`
# row exists in the services registry — the channel's single enable signal,
# see remote-up.sh). Reproduces _remote_lib.sh:_remote_registered WITHOUT a
# dependency on _remote_lib.sh, which main.sh does not source. Read live so
# bringing the channel up or down takes effect on the next poll.
_requests_remote_registered() {
    local reg; reg=$(_requests_services_registry)
    [[ -f "$reg" ]] || return 1
    awk -F'\t' '$1=="nexus-remote-ssh"{f=1} END{exit !f}' "$reg" 2>/dev/null
}

# Truthiness for the master switch. Enabled when the explicit flag is on
# OR the confined remote channel is registered. RATIONALE: a remote client's
# ONLY path to the orchestrator IS a filed request, so a live remote channel
# whose inbox does not drain is silently broken — exactly the failure that
# left 4 client requests rotting as `.new` (remote-up.sh enables the SSH
# transport; it does not touch this inbox, whose master switch defaults off
# for a fresh clone). Coupling the two here means enabling the channel makes
# the request path work end-to-end with no second switch and no watcher
# restart. Local-only use (no remote channel) still needs the explicit flag.
_requests_enabled() {
    case "${MONITOR_REQUESTS_ENABLED:-false}" in
        true|TRUE|1|yes|on) return 0 ;;
    esac
    _requests_remote_registered
}

# First non-empty line of the `## Request` section, ≤160 chars — the
# summary the watcher surfaces verbatim (RFC §2.4 step 2).
_requests_summary() {
    local f="$1" s
    s=$(awk '
        seen && NF>0 { print; exit }
        /^##[[:space:]]+Request[[:space:]]*$/ { seen=1 }
    ' "$f" 2>/dev/null)
    s=${s//$'\t'/ }
    if (( ${#s} > 160 )); then s="${s:0:157}…"; fi
    printf '%s' "$s"
}

# ── claim + GC + max-age (state mutations) ────────────────────────────
# Claim every .new.md (atomic rename → .claimed.md). A malformed file (no
# `request:` frontmatter) is renamed .failed.md and logged once. A
# .claimed.md older than max-age is given up (→ .failed.md + loud log) so
# a never-acked request cannot re-emit forever. Terminal files past
# retention (plus their reply dir + id marker) are GC'd — .done/.failed
# on the general retention, .replied on its own knob (the reply is the
# client's fetch surface; see step 3).
_requests_claim() {
    local dir; dir=$(_requests_dir)
    [[ -d "$dir" ]] || return 0
    local now maxage ret imaxage rret f id
    now=$(date +%s)
    maxage=${MONITOR_REQUESTS_MAX_AGE_SECONDS:-259200}
    ret=${MONITOR_REQUESTS_RETENTION_SECONDS:-259200}
    # A SEPARATE, short recovery threshold for content-transition intermediates
    # (.replying/.failing). A live transition is a few filesystem renames (ms);
    # the reaper polls every ~10s. 60s therefore has a ~6000x margin over any
    # live transition yet shrinks the crashed-reply pending window from the 3-day
    # max-age to ~1 min. It also normalizes an mtime asymmetry: a MIDGAP-crashed
    # `.replying` INHERITS the request's mtime (rename preserves it, so it can be
    # "old" the instant it is created), while a FINALIZE-crashed one is fresh
    # (the content mv just touched it) — a short uniform threshold recovers both
    # promptly without a special case.
    imaxage=${MONITOR_REQUESTS_INTERMEDIATE_MAX_AGE_SECONDS:-60}
    [[ "$maxage"  =~ ^[0-9]+$ ]] || maxage=259200
    [[ "$ret"     =~ ^[0-9]+$ ]] || ret=259200
    [[ "$imaxage" =~ ^[0-9]+$ ]] || imaxage=60
    # A SEPARATE retention for `.replied` files: they are the CLIENT's fetch
    # surface (fetch → rc 2, await → rc 4 once GC'd), so a deployment with
    # slow-fetching clients can hold replies longer than the general terminal
    # retention without also hoarding .done/.failed. Defaults to the general
    # retention (resolved + validated above): clients fetch within seconds —
    # the await/fetch loop polls — so 3 days already dwarfs any real fetch
    # window, and a uniform default keeps GC behavior predictable.
    rret=${MONITOR_REQUESTS_REPLIED_RETENTION_SECONDS:-$ret}
    [[ "$rret" =~ ^[0-9]+$ ]] || rret=$ret

    shopt -s nullglob 2>/dev/null
    # 1) claim new → claimed (or mark malformed failed). Route every rename
    # through the shared single-winner primitive `_chan_claim_rename` (the
    # channel's "rename is the claim" core in _channel_lib.sh) rather than an
    # open-coded `mv -f` — one place decides what a claim IS across both
    # channels and the watcher.
    for f in "$dir"/*.new.md; do
        [[ -e "$f" ]] || continue
        if [[ -z "$(_chan_frontmatter_field "$f" request)" ]]; then
            local bad="${f%.new.md}.failed.md"
            if _chan_claim_rename "$f" "$bad"; then
                _requests_log "malformed request file (no 'request:' frontmatter): $(basename -- "$bad") — marked failed"
            fi
            continue
        fi
        _chan_claim_rename "$f" "${f%.new.md}.claimed.md" || true
    done
    # 2) max-age: a claimed request unacked past the cap → failed
    for f in "$dir"/*.claimed.md; do
        [[ -e "$f" ]] || continue
        local mtime; mtime=$(date +%s -r "$f" 2>/dev/null || echo "$now")
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="$now"
        if (( now - mtime >= maxage )); then
            local bad="${f%.claimed.md}.failed.md"
            if _chan_claim_rename "$f" "$bad"; then
                _requests_log "request exceeded max-age (${maxage}s) without an ack: $(basename -- "$bad") — marked failed"
            fi
        fi
    done
    # 2b) recover crashed CONTENT-TRANSITION intermediates. A reply/fail claims
    # a non-authoritative `.replying`/`.failing` slot, writes content there, then
    # finalizes to the terminal name (request-channel.sh _chan_transition, the F1
    # crash-safety fix). If the facade process died mid-transition, an
    # intermediate is left on disk — a pending state readers never treat as
    # terminal. Recover it here after the short intermediate max-age.
    #
    # COMPLETENESS keys on BUILDER-CONTROLLED FRONTMATTER, never body text: a
    # complete `.replying` carries `state: replied` in its leading YAML (written
    # by _build_reply_content BEFORE the content mv); an incomplete one (crashed
    # before the content mv) still holds the ORIGINAL request content with its
    # pre-transition `state:` and no `reply:` block. A `## Reply` grep would be
    # FORGEABLE — a request whose `## Details` quotes a `## Reply` line would be
    # mis-finalized to a `.replied` file with `state: new` and no reply (the
    # round-3 BLOCKER-1 exploit). The frontmatter reader only parses the fenced
    # YAML, so request/reply BODY text cannot forge the decision.
    # A complete `.replying` → `.replied` byte-exact (pure rename, reply not
    # lost); an incomplete `.replying`, and ANY `.failing`, → `.failed`.
    for f in "$dir"/*.replying.md "$dir"/*.failing.md; do
        [[ -e "$f" ]] || continue
        local mtime; mtime=$(date +%s -r "$f" 2>/dev/null || echo "$now")
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="$now"
        (( now - mtime >= imaxage )) || continue
        local dst why
        case "$f" in
            *.replying.md)
                if [[ "$(_chan_frontmatter_field "$f" state)" == replied ]]; then
                    dst="${f%.replying.md}.replied.md"; why="finalized a crashed, complete reply transition (frontmatter state: replied)"
                else
                    dst="${f%.replying.md}.failed.md";  why="failed an incomplete reply transition (crashed before content; frontmatter not state: replied)"
                fi ;;
            *.failing.md)
                dst="${f%.failing.md}.failed.md";       why="finalized a crashed fail transition" ;;
        esac
        if _chan_claim_rename "$f" "$dst"; then
            _requests_log "recovered stale intermediate: $(basename -- "$f") → $(basename -- "$dst") — $why"
        fi
    done
    # 3) GC terminal files + their reply dir + id marker past retention.
    # `.replied` is terminal too (its mtime is the reply-finalize rename) but
    # ages against its own knob — see rret above.
    for f in "$dir"/*.done.md "$dir"/*.failed.md "$dir"/*.replied.md; do
        [[ -e "$f" ]] || continue
        local thr="$ret"
        [[ "$f" == *.replied.md ]] && thr="$rret"
        local mtime; mtime=$(date +%s -r "$f" 2>/dev/null || echo "$now")
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime="$now"
        if (( now - mtime >= thr )); then
            id=$(basename -- "$f"); id=${id%.md}; id=${id%.*}
            rm -f "$f" 2>/dev/null || true
            # Targeted removals only — id is a concrete on-disk stem, never
            # a glob (NEVER broad-glob rm under .state).
            [[ -n "$id" ]] && rm -rf "$dir/replies/$id" 2>/dev/null || true
            [[ -n "$id" ]] && rmdir "$dir/.ids/$id" 2>/dev/null || true
        fi
    done
    shopt -u nullglob 2>/dev/null
    return 0
}

# ── render (read claimed + cooldown → emit body) ──────────────────────
# Mirrors render_pending_decisions: emit a block per due request (new id
# OR cooldown elapsed), prune the cooldown TSV to currently-claimed ids,
# capped at max_per_emit and ordered by (priority, ts) with origin
# round-robin fairness. The compose layer wraps the output in a
# `--- requests ---` header (like `--- pending decisions ---`). Empty
# stdout when nothing is due.
requests_render() {
    local dir state_file now cooldown cap fairness
    dir=$(_requests_dir); state_file=$(_requests_emit_state)
    now=$(date +%s)
    cooldown=${MONITOR_REQUESTS_REEMIT_COOLDOWN_SECONDS:-300}
    cap=${MONITOR_REQUESTS_MAX_PER_EMIT:-10}
    fairness=${MONITOR_REQUESTS_FAIRNESS:-true}
    [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=300
    [[ "$cap" =~ ^[0-9]+$ && "$cap" -gt 0 ]] || cap=10
    [[ -d "$dir" ]] || return 0

    # Gather claimed → a TSV stream: prank \t ts \t origin \t id \t kind \t priority \t summary \t file
    local stream="" f id origin kind priority prank ts summary
    shopt -s nullglob 2>/dev/null
    for f in "$dir"/*.claimed.md; do
        [[ -e "$f" ]] || continue
        id=$(basename -- "$f"); id=${id%.claimed.md}
        origin=$(_chan_frontmatter_field "$f" origin)
        kind=$(_chan_frontmatter_field "$f" kind)
        priority=$(_chan_frontmatter_field "$f" priority)
        # Tab-sanitize every field that feeds the internal TSV stream
        # below — a literal tab in a frontmatter value would otherwise
        # shift the TSV columns on read-back and scramble the
        # request=/origin=/kind= attribution. The validated `ng request
        # file` verb already charset-gates these (origin `[A-Za-z0-9_-]`,
        # kind kebab, priority enum), so this is defense-in-depth for a
        # direct-write or future producer — mirroring the `summary`
        # sanitization in _requests_summary (skeptic #378 criterion-3 nit).
        origin=${origin//$'\t'/ }; kind=${kind//$'\t'/ }; priority=${priority//$'\t'/ }
        [[ "$priority" == high ]] && prank=0 || prank=1
        ts=${id%%-*}
        summary=$(_requests_summary "$f")
        stream+="$prank"$'\t'"$ts"$'\t'"$origin"$'\t'"$id"$'\t'"$kind"$'\t'"$priority"$'\t'"$summary"$'\t'"$f"$'\n'
    done
    shopt -u nullglob 2>/dev/null

    if [[ -z "$stream" ]]; then
        : > "$state_file"   # no claimed → clear stale cooldown rows
        return 0
    fi

    # Load prior emit stamps.
    declare -A prev
    if [[ -f "$state_file" ]]; then
        while IFS=$'\t' read -r pid pts; do
            [[ -n "$pid" ]] && prev["$pid"]="$pts"
        done < "$state_file"
    fi

    # Sort by (priority asc-rank, ts asc) → high-priority + oldest first.
    local sorted; sorted=$(printf '%s' "$stream" | sort -t$'\t' -k1,1n -k2,2)

    # Filter to DUE rows (new id OR cooldown elapsed), preserving order.
    local -a d_id=() d_origin=() d_line=()
    while IFS=$'\t' read -r prank ts origin id kind priority summary file; do
        [[ -n "$id" ]] || continue
        local last="${prev[$id]:-}" due=0
        if [[ -z "$last" ]]; then
            due=1
        elif [[ "$last" =~ ^[0-9]+$ ]] && (( now - last >= cooldown )); then
            due=1
        fi
        if (( due == 1 )); then
            d_id+=("$id"); d_origin+=("$origin")
            d_line+=("request=$id origin=$origin kind=$kind priority=$priority"$'\n'"    summary: $summary"$'\n'"    file=$file")
        fi
    done <<< "$sorted"

    # Select up to cap. Fairness = round-robin across origins (preserving
    # within-origin order); else strict FIFO over the sorted/due list.
    local -a sel_idx=()
    if [[ "$fairness" == true || "$fairness" == 1 ]]; then
        declare -A buckets origin_seen bpos
        local -a origin_order=()
        local i o
        for i in "${!d_id[@]}"; do
            o="${d_origin[$i]}"
            if [[ -z "${origin_seen[$o]:-}" ]]; then origin_seen[$o]=1; origin_order+=("$o"); fi
            buckets[$o]+="$i "
        done
        local picked=0 progressed
        while (( picked < cap )); do
            progressed=0
            for o in "${origin_order[@]}"; do
                local -a ids=(${buckets[$o]})
                local pos=${bpos[$o]:-0}
                if (( pos < ${#ids[@]} )); then
                    sel_idx+=("${ids[$pos]}")
                    bpos[$o]=$((pos + 1))
                    picked=$((picked + 1)); progressed=1
                    (( picked >= cap )) && break
                fi
            done
            (( progressed == 0 )) && break
        done
    else
        local i
        for i in "${!d_id[@]}"; do
            sel_idx+=("$i")
            (( ${#sel_idx[@]} >= cap )) && break
        done
    fi

    # Render selected + record which ids emitted this cycle.
    declare -A selected
    local out="" idx
    for idx in "${sel_idx[@]}"; do
        selected["${d_id[$idx]}"]=1
        out+="${d_line[$idx]}"$'\n'
    done

    # Next state: every currently-claimed id keeps a row so the TSV is
    # pruned to the live set. selected → now (cooldown restarts);
    # not-selected-but-previously-stamped → keep prior (stays due if it
    # was due-but-over-cap); never-stamped-and-not-selected → no row (so it
    # is "new/due" again next cycle and surfaces ASAP). This drains a
    # backlog at the cap rate without losing anyone.
    local next=""
    while IFS=$'\t' read -r prank ts origin id kind priority summary file; do
        [[ -n "$id" ]] || continue
        if [[ -n "${selected[$id]:-}" ]]; then
            next+="$id"$'\t'"$now"$'\n'
        elif [[ -n "${prev[$id]:-}" ]]; then
            next+="$id"$'\t'"${prev[$id]}"$'\n'
        fi
    done <<< "$stream"
    printf '%s' "$next" > "$state_file"

    [[ -n "$out" ]] && printf '%s' "$out"
    return 0
}

# ── task entry: claim then render (gated by the master switch) ────────
# Called by the watcher's requests_poll scheduler task. When disabled it
# is a strict no-op (no claim, no emit) so a fresh clone ships inert.
requests_poll_emit() {
    _requests_enabled || return 0
    _requests_claim
    requests_render
}
