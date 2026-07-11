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
_requests_emit_state_lock() { printf '%s.lock' "$(_requests_emit_state)"; }

# Serialize every read-modify-write of the emit-state TSV. Two writers
# exist: requests_render (the sync requests_poll task, every ~10s) and
# requests_commit_emitted (the async compose_emit subshell, post-paste).
# Without the lock a render could read the TSV, lose the CPU to a commit,
# then write back a pruned set missing the just-committed delivery stamp —
# re-emitting a delivered request one cycle later. Same flock-around-RMW
# shape as _append_to_deliveries_queue (_deliveries.sh).
#
# FAIL-OPEN, twice, deliberately: when flock is UNAVAILABLE, and when the
# wait TIMES OUT (both proceed unlocked). The TSV is advisory anti-spam
# state whose worst unlocked outcome is one duplicate paste that the
# delivered-count backoff then dampens; the caller requests_poll is a
# SYNC scheduler task, so blocking here would trade tick liveness for
# that bounded-duplicate property — the wrong trade. The 2s bound is
# generous: both critical sections are a few file reads + one atomic
# rename (ms); a wait that long means the holder is wedged (NFS stall),
# exactly when the tick must not also stall.
_requests_with_state_lock() {
    local lock; lock=$(_requests_emit_state_lock)
    mkdir -p "$(dirname "$lock")" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        (
            flock -x -w 2 200 2>/dev/null || true
            "$@"
        ) 200>"$lock"
    else
        "$@"
    fi
}

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
#
# The cooldown stamp is NOT written here. Render is a candidate, not a
# delivery: the compose layer may still dedup-suppress, over-limit-pause,
# or fail the paste. main.sh calls requests_commit_emitted (below) on the
# successful-paste path to stamp exactly the delivered ids — so an
# undelivered render leaves the request due and it re-surfaces next cycle
# (your-org/nexus-code#483).
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
        # EMPTY-field defense (skeptic on `#483`, attack 6): tab is IFS
        # *whitespace*, so `IFS=$'\t' read` COLLAPSES an empty field and
        # silently shifts every column to its right — an empty summary
        # renders `summary: <file-path>` with a blank `file=`, telling
        # the orchestrator to read a cited file with no path. Same
        # exposure for origin/kind/priority. Latent via `ng request
        # file` (which always writes the `## Request` heading) but one
        # direct-write producer away from live; placeholder every field
        # that can legally be empty.
        [[ -n "$origin"   ]] || origin="unknown"
        [[ -n "$kind"     ]] || kind="unknown"
        [[ -n "$priority" ]] || priority="normal"
        [[ "$priority" == high ]] && prank=0 || prank=1
        ts=${id%%-*}
        summary=$(_requests_summary "$f")
        [[ -n "$summary" ]] || summary="(no summary — read the cited file)"
        stream+="$prank"$'\t'"$ts"$'\t'"$origin"$'\t'"$id"$'\t'"$kind"$'\t'"$priority"$'\t'"$summary"$'\t'"$f"$'\n'
    done
    shopt -u nullglob 2>/dev/null

    if [[ -z "$stream" ]]; then
        : > "$state_file"   # no claimed → clear stale cooldown rows
        return 0
    fi

    # Load prior DELIVERY stamps: id \t epoch \t delivered-count. The
    # count drives the re-nag backoff below; a legacy two-column row
    # (pre-#483 live state) parses with an empty count → treated as 1.
    #
    # Read UNLOCKED, and dueness below is computed from this snapshot —
    # a commit landing mid-render can therefore let this cycle re-select
    # an id delivered microseconds ago (→ at most one duplicate paste,
    # whose second commit doubles that id's backoff — self-penalizing).
    # ACCEPTED RESIDUAL: locking the whole render would only narrow, not
    # close, the window, because the stage file compose reads is itself
    # an unlocked copy of this render — the architecture's guarantee is
    # at-least-once delivery with bounded, backoff-dampened duplicates,
    # never silent loss (#489 skeptic Q2a).
    declare -A prev prevcnt
    if [[ -f "$state_file" ]]; then
        while IFS=$'\t' read -r pid pts pcnt; do
            [[ -n "$pid" ]] || continue
            prev["$pid"]="$pts"
            [[ "$pcnt" =~ ^[0-9]+$ ]] || pcnt=1
            prevcnt["$pid"]="$pcnt"
        done < "$state_file"
    fi

    # Sort by (priority asc-rank, ts asc) → high-priority + oldest first.
    local sorted; sorted=$(printf '%s' "$stream" | sort -t$'\t' -k1,1n -k2,2)

    # Filter to DUE rows (never delivered, OR the per-id backoff'd
    # cooldown elapsed), preserving order. The effective cooldown is the
    # RE-NAG BUDGET the dedup-gate bypass leans on (see
    # _compose_emit_should_bypass_dedup): request bodies are never
    # hash-suppressed, so the only thing bounding a stalled
    # delivered-but-unacked request's re-paste rate is this dueness
    # gate. Base cooldown for the first re-nag, doubling per DELIVERED
    # emit, capped at the backoff max (default 1h) — 288 pastes/day
    # decays to ≤24/day per stalled request, and max-age (default 3d,
    # _requests_claim) terminates it to `.failed` outright.
    local -a d_id=() d_origin=() d_line=()
    while IFS=$'\t' read -r prank ts origin id kind priority summary file; do
        [[ -n "$id" ]] || continue
        local last="${prev[$id]:-}" due=0 eff
        eff=$(_requests_effective_cooldown "$cooldown" "${prevcnt[$id]:-0}")
        if [[ -z "$last" ]]; then
            due=1
        elif [[ "$last" =~ ^[0-9]+$ ]] && (( now - last >= eff )); then
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

    # Render the selected rows. (Which ids were DELIVERED is recorded
    # post-paste by requests_commit_emitted, never here.)
    local out="" idx
    for idx in "${sel_idx[@]}"; do
        out+="${d_line[$idx]}"$'\n'
    done

    # Next state: PRUNE ONLY — every currently-claimed id keeps its prior
    # stamp; acked/GC'd ids drop their rows. Selected ids are deliberately
    # NOT stamped here (your-org/nexus-code#483): the stamp is a DELIVERY
    # record, and render time is three gates upstream of delivery (the
    # emit-dedup suppress, the over-limit pause, and paste_with_retry all
    # sit between this render and the orchestrator's pane). Stamping here
    # recorded requests as surfaced that were never pasted — a
    # `reply: required` request aged silently inside its cooldown while
    # the client waited on a reply no one had been told to write. The
    # stamp is committed by requests_commit_emitted, which main.sh calls
    # ONLY on the successful-paste path (mirroring the emit-dedup
    # state-record discipline). Until a paste lands, every render
    # re-selects the same due set — exactly right, since nothing was
    # delivered. The prune re-reads the TSV fresh under the state lock so
    # a commit that landed mid-render is preserved, not clobbered.
    _requests_with_state_lock _requests_prune_state_locked "$stream"

    [[ -n "$out" ]] && printf '%s' "$out"
    return 0
}

# Effective re-emit cooldown after `n` DELIVERED-but-unacked emits: the
# base for the first re-nag, doubling per further delivery, capped at
# MONITOR_REQUESTS_REEMIT_BACKOFF_MAX_SECONDS (default 3600). This is
# the bounded re-nag budget (skeptic on `#483`): the dedup bypass means
# no hash gate ever rate-limits a request body again, so the dueness
# gate must — same doubling shape as _full_state_effective_floor. The
# count only advances on a successful paste (requests_commit_emitted),
# so undelivered renders can never consume the budget.
#   $1 base cooldown seconds; $2 delivered count so far
_requests_effective_cooldown() {
    local base="$1" n="$2" max eff
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    max=${MONITOR_REQUESTS_REEMIT_BACKOFF_MAX_SECONDS:-3600}
    [[ "$max" =~ ^[0-9]+$ ]] || max=3600
    (( max < base )) && max=$base
    eff=$base
    while (( n > 1 && eff < max )); do
        eff=$(( eff * 2 ))
        (( eff > max )) && eff=$max
        n=$(( n - 1 ))
    done
    printf '%s' "$eff"
}

# Prune the emit-state TSV to the currently-claimed id set, preserving
# each survivor's existing stamp + delivered-count. MUST run under
# _requests_with_state_lock (re-reads the TSV fresh so it cannot clobber
# a concurrent requests_commit_emitted stamp). $1 = the claimed-stream
# TSV from requests_render (only column 4, the id, is consulted).
_requests_prune_state_locked() {
    local stream="$1" state_file
    state_file=$(_requests_emit_state)
    declare -A live=()
    local prank ts origin id kind priority summary file
    while IFS=$'\t' read -r prank ts origin id kind priority summary file; do
        [[ -n "$id" ]] && live["$id"]=1
    done <<< "$stream"
    declare -A cur=()
    if [[ -f "$state_file" ]]; then
        # `rest` keeps the remainder verbatim (epoch, or epoch \t count).
        local pid rest
        while IFS=$'\t' read -r pid rest; do
            [[ -n "$pid" ]] && cur["$pid"]="$rest"
        done < "$state_file"
    fi
    local next=""
    for id in "${!live[@]}"; do
        [[ -n "${cur[$id]:-}" ]] && next+="$id"$'\t'"${cur[$id]}"$'\n'
    done
    printf '%s' "$next" > "${state_file}.tmp.$$" \
        && mv "${state_file}.tmp.$$" "$state_file" 2>/dev/null \
        || rm -f "${state_file}.tmp.$$" 2>/dev/null || true
    return 0
}

# ── delivery-stamp commit (stamp-on-paste, your-org/nexus-code#483) ────
# Parse the request ids actually present in a PASTED emit body and stamp
# their re-emit cooldowns at delivery time. Called by main.sh immediately
# after a successful paste_with_retry (both the startup sweep and the
# steady-state compose path), right beside _compose_emit_record_emit —
# the two post-paste state records share one discipline: a suppressed or
# failed paste writes NOTHING, so the request stays due and re-surfaces
# on the next cycle instead of silently aging inside a cooldown.
#
# Parsing the DELIVERED body (rather than committing a render-time
# staging set) makes the stamp exact by construction: the ids stamped are
# the ids the orchestrator's pane received, even if the requests_poll
# stage file was re-rendered with a different selection between compose
# and paste. Rows are `request=<id> …` at column 0 inside the
# `--- requests ---` section, which _cap_emit_sections exempts from
# truncation, so no delivered id can be sliced out of the parse. No-op
# for bodies without a requests section.
requests_commit_emitted() {
    local body_file="$1"
    [[ -f "$body_file" ]] || return 0
    local ids
    ids=$(awk '
        /^--- requests ---$/ { in_sec = 1; next }
        /^--- /              { in_sec = 0 }
        in_sec && /^request=/ {
            id = $1; sub(/^request=/, "", id)
            if (id ~ /^[A-Za-z0-9_-]+$/) print id
        }
    ' "$body_file" 2>/dev/null)
    [[ -n "$ids" ]] || return 0
    _requests_with_state_lock _requests_commit_ids_locked "$ids"
}

# Merge delivery stamps (id → now, delivered-count += 1) into the
# emit-state TSV. MUST run under _requests_with_state_lock. $1 =
# newline-separated ids. The count feeds the re-nag backoff
# (_requests_effective_cooldown) and only ever advances here — on a
# successful paste — so the budget reflects actual deliveries.
_requests_commit_ids_locked() {
    local ids="$1" state_file now
    state_file=$(_requests_emit_state)
    now=$(date +%s)
    declare -A curts=() curcnt=()
    if [[ -f "$state_file" ]]; then
        local pid pts pcnt
        while IFS=$'\t' read -r pid pts pcnt; do
            [[ -n "$pid" ]] || continue
            curts["$pid"]="$pts"
            [[ "$pcnt" =~ ^[0-9]+$ ]] || pcnt=1
            curcnt["$pid"]="$pcnt"
        done < "$state_file"
    fi
    local id
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        curts["$id"]="$now"
        curcnt["$id"]=$(( ${curcnt[$id]:-0} + 1 ))
    done <<< "$ids"
    local next=""
    for id in "${!curts[@]}"; do
        next+="$id"$'\t'"${curts[$id]}"$'\t'"${curcnt[$id]:-1}"$'\n'
    done
    printf '%s' "$next" > "${state_file}.tmp.$$" \
        && mv "${state_file}.tmp.$$" "$state_file" 2>/dev/null \
        || rm -f "${state_file}.tmp.$$" 2>/dev/null || true
    _requests_log "delivery-stamped $(printf '%s\n' "$ids" | grep -c .) request(s) post-paste"
    return 0
}

# ── delivery-state reset on orchestrator respawn (#489 skeptic C2) ────
# Delivery stamps record pastes into a SPECIFIC orchestrator session.
# When that session is replaced (respawn_agent / fresh-spawn), every
# stamp — including one written by the rescue re-paste, whose delivery
# the liveness probe itself doubted — refers to a pane the new agent
# never saw; left in place, a `reply: required` request could sit
# inside a backed-off cooldown (up to 1h) invisible to the fresh
# orchestrator. Truncating the TSV makes every still-claimed request
# immediately due, so the fresh session receives the live request set
# within one poll (~10s, nudged). Counts reset too — the counted
# deliveries went to the dead session.
requests_reset_delivery_state() {
    _requests_with_state_lock _requests_reset_state_locked
}
_requests_reset_state_locked() {
    local state_file; state_file=$(_requests_emit_state)
    [[ -s "$state_file" ]] || return 0
    : > "$state_file" 2>/dev/null || true
    _requests_log "delivery stamps reset (orchestrator replaced; all claimed requests due again)"
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
