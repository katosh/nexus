#!/usr/bin/env bash
# Deliveries-based GitHub event source for the watcher.
#
# Polls /app/hook/deliveries — the App's own webhook delivery log,
# JWT-authenticated — and folds new events into the watcher's existing
# line-shape vocabulary. Replaces snapshot_github's per-repo GraphQL
# fan-out for cross-repo discovery: the App's install scope IS the
# discovery surface; no manual repo enumeration.
#
# Loaded by monitor/watcher/main.sh when monitor.deliveries.asset_enabled
# or monitor.deliveries.bot_mention_enabled is true; not invoked
# otherwise. Side-effect-free: only function
# definitions, no top-level state.
#
# Caller globals (set by main.sh before sourcing):
#   STATE_DIR           monitor/.state
#   REPO                github.repo (the configured nexus repo)
#   USER_LOGIN          github.user_login — the only author that
#                       surfaces; enforced authoritatively by
#                       `_filter_to_user_author` downstream
#   MINT_JWT_BIN        path to executable that prints an App-level JWT
#                       on stdout (typically monitor/mint-token.sh
#                       --jwt-only, wrapped by main.sh)
#
# Cursor file: monitor/.state/last-delivery-cursor.txt. Stores the GUID
# of the newest delivery seen on the previous poll. On each cycle we
# walk pages newest-first until we hit that GUID (or run out of pages /
# hit the page cap), then persist the newest GUID seen this run.
#
# Page cap: MAX_PAGES (default 5 * 100 = 500 deliveries) bounds the
# walk after a long outage. Anything older than the 3-day server-side
# retention is unrecoverable anyway; the cap protects against runaway
# polling on fresh installs where the cursor is empty.
#
# 404 handling: GitHub returns 404 from /app/hook/deliveries when the
# App has no webhook URL configured. Treated as "no events" rather than
# an error — the watcher logs once and continues. Operator action
# (configure the webhook URL on the App settings page) is the only
# remediation; no value in spamming the log.
#
# Eligibility filter (per delivery, applied in this order):
#   1. event type is one we care about: issue_comment,
#      pull_request_review_comment, pull_request_review, issues,
#      pull_request. Otherwise skip silently.
#   2. action is "created" / "submitted" / "opened" (not edited /
#      deleted / dismissed). Edits and deletes don't surface as new
#      directives; ignore.
#   3. comment id is not in monitor/.state/processed-comments.txt
#      (cross-source dedup: same file the GraphQL path writes).
#   4. EYES/ROCKET reactions: NOT checked here. Webhook payloads don't
#      carry reactions; rechecking would cost an extra API call per
#      event. Instead we trust:
#        - the cursor advances past every delivery we've emitted,
#        - downstream `ng process` re-checks reactions on the comment
#          before posting EYES (already does),
#        - the existing snapshot_github GraphQL path runs in parallel
#          and surfaces the live reaction state for the configured
#          $REPO, so any race-condition double-emission is short-lived.
#      Operator must accept that a comment self-rocketed AFTER delivery
#      will still surface once before being filtered out by ng process.
#
# Author filter: NOT enforced here. `_filter_to_user_author` is the
# single chokepoint (issue #86); this source emits every event the
# previous filters pass, and the chokepoint drops anything whose
# author isn't $USER_LOGIN. Previously this file applied a configurable
# MENTION_ELIGIBILITY tier that could surface non-user-authored content
# via a `mention=` shape — that knob is retired.
#
# Line shapes emitted (folded with snapshot_github's vocabulary):
#   - Within $REPO:
#       issue=<n> id=<cid> author=<login>     (with body preview line)
#       pr=<n> id=<cid> author=<login>
#       pr_review=<n> id=<cid> author=<login> path=<file>
#       issue_new=<n> id=<n> author=<login>
#   - Outside $REPO (the App is installed in the source repo, e.g.
#     operator/labsh, and the user posted there):
#       mention=<owner>/<repo> kind=<issue|pr|pr_review|issue_new>
#         n=<n> id=<id> author=<login> [path=<file>]
#         (with body preview line)
#
# The mention= shape is the ONLY one that carries explicit `repo=`
# provenance, so it's used unconditionally for cross-repo events. The
# orchestrator can rely on the absence of an explicit repo on
# issue=/pr=/etc to mean "same as $REPO" (matches snapshot_github's
# implicit-repo convention).
#
# Durable queue (issue #186). Each emit block is also appended to
# `$STATE_DIR/deliveries-queue.lines` under flock. `compose_emit` drains
# the queue via `_drain_deliveries_queue` (locked rename + read + rm).
# Without the queue, the scheduler's atomic-replace write of this
# function's stdout to `<stage>/deliveries_poll.out` would wipe each
# 15 s tick's emit on the next tick — and `compose_emit`'s 60 s read
# cadence would miss three of every four ticks, losing the event to the
# 600 s GraphQL backstop. The queue is the durable persistence layer
# between fires; stdout remains for legacy callers (startup sweep,
# tests).

# Path helpers for the durable deliveries queue.
_deliveries_queue_path() {
    printf '%s\n' "${STATE_DIR}/deliveries-queue.lines"
}
_deliveries_queue_lock_path() {
    printf '%s\n' "${STATE_DIR}/deliveries-queue.lock"
}

# Append one emit block (header + body lines, including the trailing
# newline) to the queue file under an exclusive flock. The whole block
# is one append so header and body never interleave with a concurrent
# appender. The lock also serializes with `_drain_deliveries_queue`'s
# rename, guaranteeing no append lands in a renamed-then-unlinked tmp.
_append_to_deliveries_queue() {
    local block="$1"
    [[ -n "$block" ]] || return 0
    local qf qlock
    qf=$(_deliveries_queue_path)
    qlock=$(_deliveries_queue_lock_path)
    mkdir -p "$(dirname "$qf")" 2>/dev/null || true
    (
        flock -x 200
        printf '%s' "$block" >> "$qf"
    ) 200>"$qlock"
}

# Drain the deliveries queue. Locks, rename-to-tmp, prints tmp to
# stdout, removes tmp. The rename is atomic under POSIX; concurrent
# appenders that acquire the lock after the rename write to a fresh
# file. Returns 0 always; a missing queue file is treated as empty.
_drain_deliveries_queue() {
    local qf qlock qtmp
    qf=$(_deliveries_queue_path)
    qlock=$(_deliveries_queue_lock_path)
    qtmp="${qf}.draining.$$"
    [[ -f "$qf" ]] || return 0
    (
        flock -x 200
        if [[ -f "$qf" ]]; then
            mv "$qf" "$qtmp" 2>/dev/null
        fi
    ) 200>"$qlock"
    [[ -f "$qtmp" ]] || return 0
    cat "$qtmp"
    rm -f "$qtmp" 2>/dev/null || true
}

# Atomic cursor write (tmp + rename). A bare `printf > cursor` can be
# torn by a watchdog kill mid-write, leaving a corrupt guid that the
# next walk never matches → silent re-walk-from-scratch. tmp+mv makes a
# half-written cursor impossible; every step best-effort so an FS hiccup
# can't abort the caller.
_write_delivery_cursor() {
    local cursor_file="$1" guid="$2"
    [[ -n "$guid" ]] || return 0
    printf '%s\n' "$guid" > "${cursor_file}.tmp" 2>/dev/null \
        && mv "${cursor_file}.tmp" "$cursor_file" 2>/dev/null || true
}

# Phase-1 listing pre-filter (latency fix — your-org/nexus-code emit-gap).
#
# The `/app/hook/deliveries` log is GLOBAL across every repo the App is
# installed on (115+ for this operator). In a live sample ~46% of recent
# deliveries are events that can NEVER surface — `push`, `security_advisory`,
# `create`, … — yet the pre-fix phase 2 spent a payload fetch (a bounded
# curl) on EACH of them only for `_process_delivery` to classify emit_ok=false
# and drop it. With the per-cycle fetch cap (DELIVERIES_MAX_FETCH_PER_CYCLE,
# default 25) that wasted budget is exactly what starves a fresh, real
# @bot-mention / asset comment behind a multi-day backlog — the observed
# "takes very long / never surfaced via the fast path".
#
# The listing response already carries `event` + `action` per delivery
# (no extra request), so we can cheaply skip non-surfacing deliveries
# DURING collection. The set kept here is exactly the set `_process_delivery`
# would emit (created/submitted/opened of the five care events), so this is
# pure efficiency: it drops NOTHING that would have surfaced. Skipped
# deliveries still get the cursor advanced past them (via
# `newest_guid_this_run` / the belt-and-suspenders pin), so they are never
# re-walked. `_process_delivery` remains the authoritative emit gate
# (re-checks `emit_ok` on the fetched payload) — this is a conservative
# pre-filter in front of it, defence in depth.
_delivery_event_eligible() {
    local event="$1" action="$2"
    case "$event" in
        issue_comment|pull_request_review_comment) [[ "$action" == "created" ]] ;;
        pull_request_review)                        [[ "$action" == "submitted" ]] ;;
        issues|pull_request)                        [[ "$action" == "opened" ]] ;;
        *) return 1 ;;
    esac
}

# Public entry point. Prints emitted lines on stdout, also appends each
# block to the durable queue (drained by compose_emit), and side-effects
# to the cursor file. Logs errors to stderr.
#
# WEDGE-SAFETY (load-bearing — this path took the live watcher down 3× in
# 20 min on 2026-06-20). Three structural guards, all proven by
# test-deliveries-mention.sh:
#
#   1. BOUNDED curls. EVERY curl (listing + per-delivery) carries
#      `--connect-timeout DELIVERIES_CONNECT_TIMEOUT` (default 5s) and
#      `--max-time DELIVERIES_MAX_TIME` (default 15s). A slow / hung /
#      black-holed endpoint can no longer block a curl indefinitely; it
#      exits non-zero within the budget and the whole cycle returns 0
#      (NON-FATAL skip — never blocks the main loop or snapshot_github).
#      Before this fix a single un-timed-out curl could hang until the
#      scheduler's async hang-watchdog (300s) reaped the child — the
#      original wedge.
#
#   2. TWO-PHASE walk + INCREMENTAL cursor. Phase 1 collects only the
#      delivery (guid,id) summaries newer than the cursor — listing curls
#      only, cheap, page-capped. Phase 2 fetches their payloads
#      OLDEST-first, advancing the cursor after each one. So a kill at any
#      point leaves the cursor at the last fully-processed delivery: the
#      next cycle resumes at the remaining newer ones — never re-walks
#      from scratch, never loses an event. The pre-fix code persisted the
#      cursor ONLY at the very end of a newest-first inline walk, so a
#      watchdog-kill mid-walk never advanced it and EVERY subsequent poll
#      re-walked the same backlog and re-wedged ("failed every poll").
#
#   3. PER-CYCLE fetch cap. At most DELIVERIES_MAX_FETCH_PER_CYCLE
#      (default 25) payload fetches per cycle; a larger backlog drains
#      over successive cycles (cursor advances each time). Bounds the
#      first-enable / post-outage catch-up cost to a fixed, fast budget.
#
# DELIVERIES_SEED_ON_FIRST_RUN (default false): when the cursor is empty
# (first enable / wiped state), `true` seeds the cursor to the newest
# delivery and processes NOTHING — operators who only want events from
# enablement onward. Default `false` deliberately WALKS the recent
# backlog (bounded by guards 1–3) so freshly-arrived, un-acted @bot
# mentions surface on enable — the whole point of the feature.
snapshot_deliveries() {
    local cursor_file="${STATE_DIR}/last-delivery-cursor.txt"
    local last_seen_guid=""
    [[ -f "$cursor_file" ]] && last_seen_guid=$(<"$cursor_file")

    local jwt
    jwt=$("$MINT_JWT_BIN" --jwt-only 2>/dev/null) || {
        echo "snapshot_deliveries: jwt mint failed; skipping cycle" >&2
        return 0
    }
    [[ -n "$jwt" ]] || {
        echo "snapshot_deliveries: empty jwt; skipping cycle" >&2
        return 0
    }

    local processed_file="${STATE_DIR}/processed-comments.txt"
    local processed_content=""
    [[ -f "$processed_file" ]] && processed_content=$(<"$processed_file")

    local max_pages="${DELIVERIES_MAX_PAGES:-5}"
    local max_fetch="${DELIVERIES_MAX_FETCH_PER_CYCLE:-25}"
    local connect_to="${DELIVERIES_CONNECT_TIMEOUT:-5}"
    local max_time="${DELIVERIES_MAX_TIME:-15}"
    local seed_first="${DELIVERIES_SEED_ON_FIRST_RUN:-false}"
    [[ "$max_pages"   =~ ^[0-9]+$ ]] || max_pages=5
    [[ "$max_fetch"   =~ ^[0-9]+$ ]] || max_fetch=25
    [[ "$connect_to"  =~ ^[0-9]+$ ]] || connect_to=5
    [[ "$max_time"    =~ ^[0-9]+$ ]] || max_time=15
    local per_page=100
    local url="https://api.github.com/app/hook/deliveries?per_page=${per_page}"
    local pages=0
    local newest_guid_this_run=""
    local hit_cursor=0
    # Phase-1 collection: (guid<TAB>id) for each delivery NEWER than the
    # cursor, in listing (newest-first) order.
    local collect_file; collect_file=$(mktemp)

    while [[ -n "$url" && $pages -lt $max_pages ]]; do
        local hdr_file body_file
        hdr_file=$(mktemp); body_file=$(mktemp)
        local code
        # GUARD 1: --connect-timeout + --max-time bound this curl. A hung
        # endpoint exits non-zero within the budget; we skip the cycle.
        code=$(curl -sS -o "$body_file" -D "$hdr_file" \
            -w '%{http_code}' \
            --connect-timeout "$connect_to" --max-time "$max_time" \
            -H "Authorization: Bearer $jwt" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$url" 2>/dev/null) || {
            rm -f "$hdr_file" "$body_file" "$collect_file"
            echo "snapshot_deliveries: listing curl failed/timed out (connect=${connect_to}s max=${max_time}s) for $url — skipping cycle (non-fatal)" >&2
            return 0
        }

        if [[ "$code" == "404" ]]; then
            # No webhook URL on the App → empty deliveries log. Log
            # once per day at most so the operator notices; the marker
            # file mtime gates the rate.
            local marker="${STATE_DIR}/.deliveries-404-warned"
            local age=999999
            [[ -f "$marker" ]] && age=$(( $(date +%s) - $(stat -c %Y "$marker" 2>/dev/null || echo 0) ))
            if (( age > 86400 )); then
                echo "snapshot_deliveries: /app/hook/deliveries returned 404 — App has no webhook URL configured (one-time warning per day)" >&2
                touch "$marker"
            fi
            rm -f "$hdr_file" "$body_file" "$collect_file"
            return 0
        fi
        if [[ "$code" != "200" ]]; then
            echo "snapshot_deliveries: unexpected HTTP $code on $url — skipping cycle (non-fatal)" >&2
            rm -f "$hdr_file" "$body_file" "$collect_file"
            return 0
        fi

        # Each delivery: { id, guid, delivered_at, redelivery, duration,
        #                  status, status_code, event, action, ... }
        #
        # GitHub returns delivery `id` as a 64-bit integer (currently
        # ~3.8e18, comfortably above 2^53). jq 1.5 parses numbers as
        # IEEE 754 doubles, which silently truncate the low ~3 digits
        # for any integer above the 53-bit mantissa range. The
        # corrupted id then 404s on `/app/hook/deliveries/<id>`,
        # `_process_delivery` bails without emitting, and the comment
        # never surfaces — even though the cursor advances past it on
        # the listing pass (the guid IS preserved as a string). Extract
        # ids via grep on the raw JSON text so the digits never round-
        # trip through a numeric type. The deliveries listing has no
        # nested `id`; `installation_id` / `repository_id` are excluded
        # because they're prefixed by `_` rather than `"`.
        # Per-delivery metadata (guid<TAB>event<TAB>action) extracted via
        # jq — all short, encoding-safe strings — paired with the delivery
        # id grepped from the raw text (the 64-bit-id truncation guard
        # above). jq `.[]` and the `"id"` grep both walk deliveries in
        # array order, one row each, so `paste` aligns them 1:1.
        local meta ids
        meta=$(jq -r '.[] | [(.guid // ""), (.event // ""), (.action // "")] | @tsv' "$body_file")
        ids=$(grep -oE '"id"[[:space:]]*:[[:space:]]*[0-9]+' "$body_file" \
              | grep -oE '[0-9]+$')
        # Pair up via paste so we can iterate in order.
        local pair_file; pair_file=$(mktemp)
        paste <(printf '%s\n' "$meta") <(printf '%s\n' "$ids") > "$pair_file"

        while IFS=$'\t' read -r guid event action id; do
            [[ -z "$guid" || -z "$id" ]] && continue
            [[ -z "$newest_guid_this_run" ]] && newest_guid_this_run="$guid"

            if [[ -n "$last_seen_guid" && "$guid" == "$last_seen_guid" ]]; then
                hit_cursor=1
                break
            fi

            # Skip deliveries that can never surface (push, security_advisory,
            # …) so the per-cycle payload-fetch budget is reserved for events
            # that might actually emit. The cursor still advances past these
            # (newest_guid_this_run pin), so they are not re-walked.
            _delivery_event_eligible "$event" "$action" || continue

            # Phase 1 only COLLECTS — no per-delivery fetch yet. Payloads
            # are fetched oldest-first in phase 2 with the cap + cursor.
            printf '%s\t%s\n' "$guid" "$id" >> "$collect_file"
        done < "$pair_file"

        rm -f "$pair_file"

        if (( hit_cursor == 1 )); then
            rm -f "$hdr_file" "$body_file"
            break
        fi

        # Parse Link: <url>; rel="next"
        url=$(awk 'BEGIN{IGNORECASE=1} /^link:/{print}' "$hdr_file" \
              | sed -nE 's/.*<([^>]+)>;[[:space:]]*rel="next".*/\1/p' \
              | head -1)

        rm -f "$hdr_file" "$body_file"
        pages=$(( pages + 1 ))
    done

    if (( pages == max_pages && hit_cursor == 0 )) && [[ -n "$last_seen_guid" ]]; then
        echo "snapshot_deliveries: page cap (${max_pages}) hit before reaching cursor; possibly missed events from before this run" >&2
    fi

    # First-enable seeding (opt-in). Empty cursor + seed_first=true: skip
    # the backlog entirely, record the newest delivery as the cursor.
    if [[ -z "$last_seen_guid" && "$seed_first" == "true" ]]; then
        rm -f "$collect_file"
        if [[ -n "$newest_guid_this_run" ]]; then
            _write_delivery_cursor "$cursor_file" "$newest_guid_this_run"
            echo "snapshot_deliveries: first run — seeded cursor to ${newest_guid_this_run}; backlog NOT walked (DELIVERIES_SEED_ON_FIRST_RUN=true). Deliveries after this point will surface." >&2
        fi
        return 0
    fi

    # Nothing newer than the cursor: persist the newest (idempotent) and
    # return. No payload fetches.
    if [[ ! -s "$collect_file" ]]; then
        rm -f "$collect_file"
        [[ -n "$newest_guid_this_run" ]] && _write_delivery_cursor "$cursor_file" "$newest_guid_this_run"
        return 0
    fi

    # Phase 2: process OLDEST-first (reverse the newest-first collection),
    # capped at max_fetch, advancing the cursor after each fully-processed
    # delivery (GUARD 2 + GUARD 3). `tac` reverses; tail is read line by
    # line so a partial process leaves a consistent cursor.
    local fetched=0
    local capped=0
    while IFS=$'\t' read -r guid id; do
        [[ -z "$guid" || -z "$id" ]] && continue
        if (( fetched >= max_fetch )); then
            capped=1
            break
        fi
        _process_delivery "$jwt" "$id" "$processed_content" "$connect_to" "$max_time"
        fetched=$(( fetched + 1 ))
        # Incremental cursor: this delivery is now done. A kill here leaves
        # the cursor exactly at the last finished delivery.
        _write_delivery_cursor "$cursor_file" "$guid"
    done < <(tac "$collect_file" 2>/dev/null || tail -r "$collect_file" 2>/dev/null)

    rm -f "$collect_file"

    if (( capped == 1 )); then
        echo "snapshot_deliveries: per-cycle fetch cap (${max_fetch}) reached; cursor advanced to the last processed delivery, remaining newer deliveries surface next cycle" >&2
    elif [[ -n "$newest_guid_this_run" ]]; then
        # Processed the whole collected set: the last one was the newest.
        # Belt-and-suspenders cursor pin to the absolute newest seen.
        _write_delivery_cursor "$cursor_file" "$newest_guid_this_run"
    fi
}

# Fetch one delivery's payload, classify, filter, emit. Internal.
# connect_to / max_time bound the curl (GUARD 1); default to the same
# 5s/15s as the listing call when the caller omits them (older callers /
# direct unit invocation).
_process_delivery() {
    local jwt="$1" id="$2" processed_content="$3"
    local connect_to="${4:-${DELIVERIES_CONNECT_TIMEOUT:-5}}"
    local max_time="${5:-${DELIVERIES_MAX_TIME:-15}}"
    local body_file; body_file=$(mktemp)
    local code
    code=$(curl -sS -o "$body_file" \
        -w '%{http_code}' \
        --connect-timeout "$connect_to" --max-time "$max_time" \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/app/hook/deliveries/${id}" 2>/dev/null) || {
        rm -f "$body_file"
        return 0
    }
    if [[ "$code" != "200" ]]; then
        rm -f "$body_file"
        return 0
    fi

    # The single-delivery response is { id, guid, ..., event, action,
    # request: { headers, payload }, response: {...} }.
    # The webhook event payload lives at .request.payload (object).
    # We extract once via jq, then run a single Python-style awk-emit.
    local extracted
    extracted=$(jq -r --arg event_default "" '
        . as $top
        | .event as $event
        | (.request.payload // {}) as $p
        | $p.action as $action
        | (
            # Repo full name (always present in webhook payloads except
            # `installation`-scoped events which we ignore).
            ($p.repository.full_name // "") as $repo |
            (
              if $event == "issue_comment" then
                {
                  kind:    (if ($p.issue.pull_request != null) then "pr" else "issue" end),
                  n:       ($p.issue.number | tostring),
                  id:      ($p.comment.id | tostring),
                  author:  ($p.comment.user.login // ""),
                  body:    ($p.comment.body // ""),
                  path:    "",
                  action:  $action,
                  emit_ok: ($action == "created"),
                }
              elif $event == "pull_request_review_comment" then
                {
                  kind:    "pr_review",
                  n:       ($p.pull_request.number | tostring),
                  id:      ($p.comment.id | tostring),
                  author:  ($p.comment.user.login // ""),
                  body:    ($p.comment.body // ""),
                  path:    ($p.comment.path // ""),
                  action:  $action,
                  emit_ok: ($action == "created"),
                }
              elif $event == "pull_request_review" then
                {
                  kind:    "pr_review",
                  n:       ($p.pull_request.number | tostring),
                  id:      ($p.review.id | tostring),
                  author:  ($p.review.user.login // ""),
                  body:    ($p.review.body // ""),
                  path:    "",
                  action:  $action,
                  # GitHub sends `submitted` for new top-level reviews;
                  # `edited` when the body is updated. Surface only the
                  # initial submission to match the directive-once rule.
                  emit_ok: ($action == "submitted"),
                }
              elif $event == "issues" then
                {
                  kind:    "issue_new",
                  n:       ($p.issue.number | tostring),
                  id:      ($p.issue.number | tostring),
                  author:  ($p.issue.user.login // ""),
                  body:    ($p.issue.body // ""),
                  path:    "",
                  action:  $action,
                  emit_ok: ($action == "opened"),
                }
              elif $event == "pull_request" then
                {
                  # PR opens deliberately surface as `pr=` (a comment-like
                  # entry pointing at the PR conversation), not a new
                  # shape — keeps the orchestrator routing surface small.
                  # The watcher gets one entry per PR open, then any
                  # follow-up comments arrive via issue_comment events.
                  kind:    "pr",
                  n:       ($p.pull_request.number | tostring),
                  id:      ($p.pull_request.id | tostring),
                  author:  ($p.pull_request.user.login // ""),
                  body:    ($p.pull_request.body // ""),
                  path:    "",
                  action:  $action,
                  emit_ok: ($action == "opened"),
                }
              else
                {emit_ok: false}
              end
            ) + {repo: $repo, event: $event}
          )
        | @json
    ' "$body_file" 2>/dev/null)

    rm -f "$body_file"
    [[ -n "$extracted" && "$extracted" != "null" ]] || return 0

    local emit_ok kind n id author body path repo event
    emit_ok=$(jq -r '.emit_ok // false' <<<"$extracted")
    [[ "$emit_ok" == "true" ]] || return 0
    kind=$(jq -r '.kind   // ""' <<<"$extracted")
    n=$(jq -r    '.n      // ""' <<<"$extracted")
    id=$(jq -r   '.id     // ""' <<<"$extracted")
    author=$(jq -r '.author // ""' <<<"$extracted")
    body=$(jq -r   '.body   // ""' <<<"$extracted")
    path=$(jq -r   '.path   // ""' <<<"$extracted")
    repo=$(jq -r   '.repo   // ""' <<<"$extracted")
    event=$(jq -r  '.event  // ""' <<<"$extracted")
    [[ -n "$kind" && -n "$n" && -n "$id" ]] || return 0

    local is_in_repo=0
    [[ "$repo" == "$REPO" ]] && is_in_repo=1

    # Deliveries flag SPLIT (#244 follow-up). The in-$REPO asset-surfacing
    # emit and the cross-repo @bot-mention emit are independently gated:
    #   DELIVERIES_ASSET_ENABLED        → in-$REPO `issue=`/`pr=`/… shapes
    #   DELIVERIES_BOT_MENTION_ENABLED  → cross-repo `mention=` shape
    # A delivery whose concern is disabled is CONSUMED (the caller's cursor
    # still advances in snapshot_deliveries — no re-walk, no loss) but NOT
    # surfaced. Unset → emit: preserves the surface-everything behaviour for
    # legacy direct callers / tests that never set the flags. See the gate
    # header in _config.sh for the two flags + their defaults.
    if (( is_in_repo == 1 )); then
        [[ "${DELIVERIES_ASSET_ENABLED:-true}" == "true" ]] || return 0
    else
        [[ "${DELIVERIES_BOT_MENTION_ENABLED:-true}" == "true" ]] || return 0
    fi

    # processed-comments dedup keys.
    #
    #   IN-$REPO: comment:<id> / issue:<n> — the SAME scheme snapshot_github
    #     writes, so the two sources dedup cleanly against each other. A
    #     comment <id> is a GLOBAL GitHub database id (unique across repos);
    #     issue <n> is only unique within $REPO, which is fine here because
    #     these keys only ever describe $REPO.
    #
    #   CROSS-REPO (mention=): REPO-SCOPED — comment:<repo>:<id> /
    #     issue:<repo>:<n>. The issue NUMBER is not globally unique, so a
    #     bare issue:<n> would collide across repos (e.g. nexus-code#5 vs
    #     some-other-repo#5 — surfacing one would suppress the other). The
    #     delivery cursor (guid, globally unique) already prevents re-walking
    #     the same delivery; this repo-scoped key prevents a cross-repo
    #     issue-number COLLISION from wrongly deduping a distinct event. The
    #     comment-id case is already collision-free (global id) but is
    #     repo-scoped too for uniformity and to keep cross-repo keys in their
    #     own namespace, never colliding with snapshot_github's $REPO keys.
    local processed_key=""
    if (( is_in_repo == 1 )); then
        case "$kind" in
            issue_new) processed_key="issue:${n}" ;;
            *)         processed_key="comment:${id}" ;;
        esac
    else
        case "$kind" in
            issue_new) processed_key="issue:${repo}:${n}" ;;
            *)         processed_key="comment:${repo}:${id}" ;;
        esac
    fi
    if [[ -n "$processed_content" ]] \
        && grep -qxF "$processed_key" <<<"$processed_content"; then
        return 0
    fi

    # One-line body preview (snapshot_github uses 400 chars; mirror).
    local body_preview
    body_preview=$(printf '%s' "$body" \
        | tr '\n\r\t' '   ' \
        | head -c 400)
    if (( ${#body} > 400 )); then
        body_preview="${body_preview}…"
    fi

    # Emit-shape decision: existing `issue=`/`pr=`/`pr_review=`/
    # `issue_new=` shape for in-$REPO events; `mention=<repo>` shape
    # (with explicit `repo=` provenance) for cross-repo events. The
    # author rule itself (must equal $USER_LOGIN) is enforced by
    # `_filter_to_user_author` downstream — this function emits every
    # event that passes the event-type/action/dedup gates above and
    # the chokepoint drops the non-user-authored survivors.
    # (`is_in_repo` computed above for the dedup-key scoping.)

    # Compose the emit block into a single variable so the same bytes
    # land on stdout (legacy callers) AND in the durable queue (drained
    # by compose_emit). `printf -v` preserves the trailing newline that
    # command-substitution would otherwise strip.
    local block=""
    if (( is_in_repo == 0 )); then
        local extra=""
        [[ -n "$path" ]] && extra=" path=${path}"
        printf -v block 'mention=%s kind=%s n=%s id=%s author=%s%s\n  body: %s\n' \
            "$repo" "$kind" "$n" "$id" "$author" "$extra" "$body_preview"
    else
        case "$kind" in
            issue)
                printf -v block 'issue=%s id=%s author=%s\n  body: %s\n' \
                    "$n" "$id" "$author" "$body_preview"
                ;;
            pr)
                printf -v block 'pr=%s id=%s author=%s\n  body: %s\n' \
                    "$n" "$id" "$author" "$body_preview"
                ;;
            pr_review)
                printf -v block 'pr_review=%s id=%s author=%s path=%s\n  body: %s\n' \
                    "$n" "$id" "$author" "${path:-?}" "$body_preview"
                ;;
            issue_new)
                printf -v block 'issue_new=%s id=%s author=%s\n  body: %s\n' \
                    "$n" "$n" "$author" "$body_preview"
                ;;
        esac
    fi
    [[ -n "$block" ]] || return 0
    printf '%s' "$block"
    _append_to_deliveries_queue "$block"
}
