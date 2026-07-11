#!/usr/bin/env bash
# Watcher functional-check signal (other-nexus-lessons L1).
#
# Orthogonal to the existing heartbeat / pid / paste-receipt liveness
# state machine in `_orchestrator_liveness.sh`. Those check whether
# the orchestrator's process is alive AND whether it received and
# acknowledged a paste. The functional check answers the harder
# question: did the bot actually *react* (eyes / rocket) to the
# eligible github comments the watcher recently surfaced?
#
# Empirically, a wedged orchestrator can pass all three existing
# signals — Stop hook still fires at idle-turn ends, paste hook still
# fires when the watcher pokes it, sessions don't crash — yet quietly
# fail to dispatch any `gh api reactions` writes against the surfaced
# work. The 24h watcher-health monitor on `other-nexus#9`
# (2026-05-26 → 2026-05-27) demonstrated the gap: a comment surfaced
# in an emit, the orchestrator's paste-received hook fired, no
# reaction landed for hours. The pure heartbeat/pid path was silent.
#
# Decision tree per fire:
#
#   1. If `MONITOR_FUNCTIONAL_SLA_SECONDS` (the knob) is 0, the check
#      is disabled entirely. Returns `bypass disabled` immediately;
#      no network call, no state write.
#
#   2. Otherwise, scan the most recent N emit-archive files under
#      `monitor/.state/diffs/` (default 5). Filter to files whose
#      mtime is newer than `now - SLA`.
#
#   3. Extract `(repo, comment_id)` pairs from header lines inside
#      each emit's `--- eligible github comments ---` section.
#      Supported header shapes:
#
#         issue=<n> id=<id> ...               → (default_repo, id)
#         mention=<repo> ... id=<id> ...      → (repo, id)
#         cross_repo=<repo> ... id=<id> ...   → (repo, id)
#
#      Other shapes (pr=, pr_review=, issue_new=) are ignored for
#      v1 — they're not the dominant operator-asks-bot channel and
#      use a different reactions endpoint we don't want to plumb on
#      the first cut.
#
#   4. For each unique comment_id, hit
#      `gh api repos/<repo>/issues/comments/<id>/reactions` (via the
#      injected `gh_cmd` indirection so tests can shim) and look for
#      a reaction whose `.user.login` matches the bot login AND
#      whose `.content` is `eyes` or `rocket`. Reactions outside
#      `[emit_mtime - SLA, now]` are treated as "no reaction" for
#      this emit's purposes — a reaction from yesterday doesn't
#      prove today's emit got processed. (v1 leniency: we only have
#      the reactions endpoint, which returns the user but not the
#      `created_at` per reaction without an `Accept` preview; treat
#      ANY current bot reaction as evidence that this comment got
#      attention. Refinement to per-reaction-timestamp filtering
#      lives in a future iteration if the false-pass rate matters.)
#
#   5. Per-emit verdict:
#        - At least one surfaced comment has a verified bot reaction
#          → emit is **processed**.
#        - Every surfaced comment is verified unreacted → **stale**.
#        - Anything else (no extractable ids, gh failures across
#          the board) → **unknown** — does not count.
#
#   6. Top-level verdict: if every counted emit is **stale** AND at
#      least one emit was counted → ALARM ("stale"). Otherwise
#      healthy. (Unknown emits don't contribute either way.)
#
#   7. Append a TSV row to the state file recording the decision:
#
#         ts<TAB>n_emits<TAB>n_processed<TAB>n_stale<TAB>decision
#
#      Useful for post-hoc audit ("did the watcher think we were
#      wedged at 03:42?") and for the supervisor cron's "should I
#      escalate" pattern.
#
# Bypass conditions (verdict "bypass ..."):
#
#   - knob = 0 → `bypass disabled`. No state write.
#   - No emit files in the horizon → `bypass no-recent-emits`.
#   - Files in the horizon but none contain extractable comment IDs
#     → `bypass no-eligible-comments`. Treats "workspace had nothing
#     to dispatch" as a healthy null state — the check has no
#     assertion to make.
#
# Loaded by `monitor/watcher/main.sh` and by `test-functional-check.sh`.
# Side-effect-free at load time — function definitions only.

# ---- double-source guard ------------------------------------------------
if [[ -n "${_NEXUS_FUNCTIONAL_CHECK_LOADED:-}" ]]; then
    return 0
fi
_NEXUS_FUNCTIONAL_CHECK_LOADED=1

# _functional_emit_files_in_horizon <diff_dir> <look_back_seconds> <max_count>
#
# Print up to `max_count` most recent emit-archive paths from
# `diff_dir` whose mtime is within `now - look_back`. One path per
# line, newest first. Missing dir + empty dir → no output (rc=0).
#
# `look_back` is the "what's been happening" window — wider than the
# SLA so an emit whose SLA window has already CLOSED (and was never
# reacted to) is still in scope. Callers pass `max(4 * SLA, ...)`.
# Filter is mtime-based via `find -mmin` (ceil seconds → minutes so
# short look-backs don't round down to 0).
_functional_emit_files_in_horizon() {
    local diff_dir="${1:?diff_dir required}"
    local look_back="${2:?look_back required}"
    local max_count="${3:-5}"
    [[ -d "$diff_dir" ]] || return 0
    [[ "$look_back" =~ ^[0-9]+$ ]] || return 0
    [[ "$max_count" =~ ^[0-9]+$ ]] || max_count=5
    local mmin=$(( (look_back + 59) / 60 ))
    (( mmin < 1 )) && mmin=1
    # `-mmin -N` is "modified less than N minutes ago" — i.e. within
    # the look-back. Sort by mtime descending, then take the head.
    find "$diff_dir" -maxdepth 1 -type f -name '*.md' \
        -mmin "-${mmin}" -printf '%T@\t%p\n' 2>/dev/null \
        | LC_ALL=C sort -rn \
        | head -n "$max_count" \
        | awk -F'\t' '{print $2}'
}

# _functional_emit_comment_ids <emit_file> <default_repo>
#
# Extract `(repo<TAB>comment_id)` pairs from the eligible-comments
# section of `emit_file`. Prints one pair per line. Header shapes
# recognised (see header docstring for rationale):
#
#   issue=<n> id=<id> ...                  → default_repo
#   mention=<repo> ... id=<id> ...         → <repo>
#   cross_repo=<repo> ... id=<id> ...      → <repo>
#
# Other headers (pr=, pr_review=, issue_new=) are ignored. Lines
# outside the `--- eligible github comments ---` section are ignored.
# A file with no eligible-comments section yields no output.
_functional_emit_comment_ids() {
    local emit_file="${1:?emit_file required}"
    local default_repo="${2:?default_repo required}"
    [[ -f "$emit_file" ]] || return 0
    awk -v default_repo="$default_repo" '
        BEGIN { in_sec = 0 }
        /^--- eligible github comments ---$/ { in_sec = 1; next }
        /^--- / { in_sec = 0; next }
        !in_sec { next }
        {
            line = $0
            id = ""
            repo = ""
            if (match(line, /id=[0-9]+/)) {
                id = substr(line, RSTART + 3, RLENGTH - 3)
            }
            if (id == "") next
            if (line ~ /^issue=/) {
                repo = default_repo
            } else if (match(line, /^mention=[^[:space:]]+/)) {
                repo = substr(line, RSTART + 8, RLENGTH - 8)
            } else if (match(line, /^cross_repo=[^[:space:]]+/)) {
                repo = substr(line, RSTART + 11, RLENGTH - 11)
            } else {
                next
            }
            if (repo == "") next
            printf "%s\t%s\n", repo, id
        }
    ' "$emit_file"
}

# _functional_bot_reacted <repo> <comment_id> <bot_login> [gh_cmd]
#
# Returns 0 iff `gh api repos/<repo>/issues/comments/<id>/reactions`
# contains a reaction whose `.user.login` matches `bot_login` AND
# whose `.content` is `eyes` or `rocket`. Returns 1 on no-reaction.
# Returns 2 on gh failure (auth / network / 404) — caller treats as
# "unknown" rather than "stale" so a transient outage doesn't false-
# alarm.
#
# `gh_cmd` defaults to `gh`. Tests inject a shim function via the
# 4th arg (passed by name, called via `"$gh_cmd"`).
_functional_bot_reacted() {
    local repo="${1:?repo required}"
    local comment_id="${2:?comment_id required}"
    local bot_login="${3:?bot_login required}"
    local gh_cmd="${4:-gh}"
    local out rc=0
    out=$("$gh_cmd" api "repos/$repo/issues/comments/$comment_id/reactions" 2>/dev/null) || rc=$?
    if (( rc != 0 )); then
        return 2
    fi
    # jq filter: emit `match` when any reaction object has both
    # `.user.login == bot` AND `.content` in {eyes,rocket}. Other
    # reactions (thumbs_up, +1, etc.) don't count — eyes/rocket are
    # the bot's "I see this" / "I acted on this" markers used by
    # `monitor/ng react`.
    local match
    match=$(printf '%s' "$out" \
        | jq -r --arg bot "$bot_login" \
            '[.[] | select(.user.login == $bot)
                  | select(.content == "eyes" or .content == "rocket")]
             | length' 2>/dev/null)
    if [[ "$match" =~ ^[0-9]+$ ]] && (( match > 0 )); then
        return 0
    fi
    return 1
}

# _functional_emit_verdict <emit_file> <default_repo> <bot_login> [gh_cmd]
#
# Per-emit verdict over its surfaced comment IDs. Reaction-only:
# this function does NOT consider emit age — the caller layers age
# vs SLA on top to decide whether a no-reaction verdict is ripe
# (stale) or still in-progress.
#
# Prints one of (no trailing newline):
#
#   processed   n_total=<N> n_reacted=<R> n_failed=<F>
#   no-reaction n_total=<N> n_reacted=0   n_failed=<F>
#   unknown     n_total=<N> n_reacted=0   n_failed=<F>   (gh failed across the board)
#   no-ids      n_total=0   n_reacted=0   n_failed=0     (nothing extractable)
#
# Returns:
#   0 for processed
#   1 for no-reaction
#   2 for unknown
#   3 for no-ids
_functional_emit_verdict() {
    local emit_file="${1:?emit_file required}"
    local default_repo="${2:?default_repo required}"
    local bot_login="${3:?bot_login required}"
    local gh_cmd="${4:-gh}"
    local n_total=0 n_reacted=0 n_failed=0
    local repo id rc
    while IFS=$'\t' read -r repo id; do
        [[ -n "$repo" && -n "$id" ]] || continue
        n_total=$(( n_total + 1 ))
        _functional_bot_reacted "$repo" "$id" "$bot_login" "$gh_cmd"
        rc=$?
        case "$rc" in
            0) n_reacted=$(( n_reacted + 1 )) ;;
            2) n_failed=$(( n_failed + 1 )) ;;
        esac
    done < <(_functional_emit_comment_ids "$emit_file" "$default_repo")
    if (( n_total == 0 )); then
        printf 'no-ids n_total=0 n_reacted=0 n_failed=0'
        return 3
    fi
    if (( n_reacted > 0 )); then
        printf 'processed n_total=%d n_reacted=%d n_failed=%d' \
            "$n_total" "$n_reacted" "$n_failed"
        return 0
    fi
    if (( n_failed >= n_total )); then
        printf 'unknown n_total=%d n_reacted=0 n_failed=%d' "$n_total" "$n_failed"
        return 2
    fi
    printf 'no-reaction n_total=%d n_reacted=0 n_failed=%d' "$n_total" "$n_failed"
    return 1
}

# _functional_check_decide \
#     <diff_dir> <sla_seconds> <max_emits> \
#     <default_repo> <bot_login> <state_file> [gh_cmd]
#
# Top-level functional-check decision. Returns:
#
#   0 + prints `healthy reason=... n_emits=N n_processed=P n_stale=S`
#   1 + prints `stale   reason=all-emits-unprocessed-past-SLA n_emits=N ...`
#   2 + prints `bypass  reason=disabled` / `bypass reason=no-recent-emits`
#         / `bypass reason=no-eligible-comments`
#
# Appends a TSV row to `state_file` unless the bypass is "disabled"
# (knob=0; nothing to record). Other bypasses DO record so the audit
# trail captures every check.
_functional_check_decide() {
    local diff_dir="${1:?diff_dir required}"
    local sla_seconds="${2:?sla_seconds required}"
    local max_emits="${3:-5}"
    local default_repo="${4:?default_repo required}"
    local bot_login="${5:?bot_login required}"
    local state_file="${6:?state_file required}"
    local gh_cmd="${7:-gh}"

    # Knob=0 short-circuits without state writes.
    if [[ "$sla_seconds" == "0" ]]; then
        printf 'bypass reason=disabled'
        return 2
    fi
    [[ "$sla_seconds" =~ ^[0-9]+$ ]] || {
        printf 'bypass reason=sla-non-numeric'
        return 2
    }
    [[ "$max_emits" =~ ^[0-9]+$ ]] || max_emits=5
    [[ "$bot_login" != "" ]] || {
        printf 'bypass reason=no-bot-login'
        return 2
    }

    local now
    now=$(date +%s)

    # Look-back window: how far back we'll scan for emits. Wider
    # than SLA so an emit whose SLA window has CLOSED (and was
    # never reacted to) still shows up in scope. 4*SLA + a 2h
    # floor handles both short SLAs and operator-tuned wide ones.
    local look_back=$(( sla_seconds * 4 ))
    (( look_back < 7200 )) && look_back=7200

    # Collect the recent emit files.
    local emit_paths=()
    mapfile -t emit_paths < <(
        _functional_emit_files_in_horizon "$diff_dir" "$look_back" "$max_emits"
    )
    if (( ${#emit_paths[@]} == 0 )); then
        _functional_check_record_state "$state_file" "$now" 0 0 0 "bypass-no-recent-emits"
        printf 'bypass reason=no-recent-emits'
        return 2
    fi

    # Per-emit bucketing. Age vs SLA decides whether a no-reaction
    # verdict is "ripe" (window closed → stale) or "in-progress"
    # (window still open → don't count, the orchestrator may yet
    # react).
    local n_with_ids=0 n_processed=0 n_stale=0 n_unknown=0 n_in_progress=0
    local emit verdict rc emit_mtime emit_age
    for emit in "${emit_paths[@]}"; do
        verdict=$(_functional_emit_verdict "$emit" "$default_repo" "$bot_login" "$gh_cmd")
        rc=$?
        # rc=3 → emit had no extractable comment IDs; skip.
        (( rc == 3 )) && continue
        n_with_ids=$(( n_with_ids + 1 ))
        emit_mtime=$(date +%s -r "$emit" 2>/dev/null || echo 0)
        [[ "$emit_mtime" =~ ^[0-9]+$ ]] || emit_mtime=0
        emit_age=$(( now - emit_mtime ))
        (( emit_age < 0 )) && emit_age=0
        case "$rc" in
            0) n_processed=$(( n_processed + 1 )) ;;
            2) n_unknown=$(( n_unknown + 1 )) ;;
            1)
                if (( emit_age >= sla_seconds )); then
                    n_stale=$(( n_stale + 1 ))
                else
                    n_in_progress=$(( n_in_progress + 1 ))
                fi
                ;;
        esac
    done

    if (( n_with_ids == 0 )); then
        _functional_check_record_state "$state_file" "$now" 0 0 0 "bypass-no-eligible-comments"
        printf 'bypass reason=no-eligible-comments'
        return 2
    fi

    # Alarm condition: every counted emit is stale AND at least one
    # was counted (no processed, no in-progress, no unknown). Unknown
    # / in-progress emits never push the verdict to alarm — uncertainty
    # is healthy; the next check fires in N seconds.
    if (( n_stale > 0 && n_processed == 0 && n_unknown == 0 && n_in_progress == 0 )); then
        _functional_check_record_state "$state_file" "$now" \
            "$n_with_ids" "$n_processed" "$n_stale" "stale-all-emits-unprocessed-past-SLA"
        printf 'stale reason=all-emits-unprocessed-past-SLA n_emits=%d n_processed=%d n_stale=%d sla=%ds' \
            "$n_with_ids" "$n_processed" "$n_stale" "$sla_seconds"
        return 1
    fi

    local decision_tag="healthy"
    if (( n_processed > 0 )); then
        decision_tag="healthy-with-processed"
    elif (( n_in_progress > 0 && n_stale == 0 )); then
        decision_tag="healthy-in-progress"
    elif (( n_unknown > 0 && n_stale == 0 )); then
        decision_tag="healthy-unknown-no-stale"
    fi
    _functional_check_record_state "$state_file" "$now" \
        "$n_with_ids" "$n_processed" "$n_stale" "$decision_tag"
    printf 'healthy reason=%s n_emits=%d n_processed=%d n_stale=%d n_unknown=%d n_in_progress=%d sla=%ds' \
        "$decision_tag" "$n_with_ids" "$n_processed" "$n_stale" \
        "$n_unknown" "$n_in_progress" "$sla_seconds"
    return 0
}

# _functional_fault_class <loop_alive_rc> <delivery_fail_count> <delivery_age> <sla>
#
# Classify a FIRED functional-check ("stale" — every surfaced comment
# un-acked past the SLA) into the fault DOMAIN that owns recovery.
# Pure: no I/O, no globals, deterministic on its four integer args, so
# the whole quiet-vs-wedge decision is unit-testable without a live
# watcher.
#
# WHY this exists (your-org/nexus-code false-positive): the functional
# check fires whenever surfaced comments go un-reacted past the SLA.
# That is NECESSARY but NOT SUFFICIENT evidence of a watcher fault. On
# a genuinely QUIET workspace the watcher emits nothing, so its
# delivery clock (`watcher-last-emit-delivery.ts`) ages past the SLA
# while the loop is perfectly alive — it bumps its loop-proof heartbeat
# every cycle (see _lib.sh `_watcher_alive` NOTE: "fresh ⇒ the loop
# works, even on a deliberately-silent quiet workspace"). The previous
# gate keyed the revive path on delivery age alone (`delivery_age >
# sla`), so a quiet stretch spuriously REVIVED a healthy watcher
# (~0s downtime, every ~13min). We re-aim it: demand POSITIVE evidence
# of a watcher-side fault before the revive path.
#
#   - loop_alive_rc >= 2  → the loop-proof HEARTBEAT is STALE: the loop
#                           is wedged/dead — the one fault a restart
#                           fixes. Maps to `_watcher_alive`'s DEAD (2)
#                           / no-heartbeat (3) buckets, the same
#                           liveness source `svc.sh status` /
#                           `revive-watcher.sh` judge by. (From inside
#                           the running loop this is ~never true — a
#                           wedged loop wouldn't run this check; the
#                           EXTERNAL supervisor owns loop-dead — but the
#                           clause keeps the verdict honest for a
#                           partial wedge where the scheduler still
#                           ticks while the heartbeat has gone stale.)
#   - delivery_fail_count > 0 → emits were GENERATED but the paste path
#                           is actively FAILING (emits-generated-but-
#                           stuck) — a genuine watcher-side delivery
#                           fault. Read from `_emit_delivery_fail`'s
#                           consecutive-failure counter; a successful
#                           delivery clears it via `_emit_delivery_ok`.
#                           (Note rc=2 — orchestrator window missing —
#                           never increments this counter, so a missing
#                           orchestrator never masquerades as a watcher
#                           fault here.)
#
# EITHER ⇒ `watcher-fault` (caller self-heals). OTHERWISE the loop is
# alive AND the paste path is not failing, so the stale reactions are
# NOT the watcher's fault:
#
#   - delivery fresh (age <= SLA) → `orchestrator-fault`: a paste
#                           landed recently, so the orchestrator merely
#                           failed to react (orchestrator-liveness owns
#                           this).
#   - delivery stale (age > SLA)  → `quiet`: nothing to deliver lately;
#                           the aged delivery clock is normal idle, not
#                           a fault.
#
# Prints `<class> reason=<...>` where class is one of `watcher-fault`
# | `orchestrator-fault` | `quiet`. Returns 0 / 1 / 2 respectively so
# callers can branch on rc instead of parsing.
_functional_fault_class() {
    local loop_alive_rc="${1:?loop_alive_rc required}"
    local fail_count="${2:?fail_count required}"
    local delivery_age="${3:?delivery_age required}"
    local sla="${4:?sla required}"
    [[ "$loop_alive_rc" =~ ^[0-9]+$ ]] || loop_alive_rc=0
    [[ "$fail_count" =~ ^[0-9]+$ ]] || fail_count=0
    [[ "$delivery_age" =~ ^[0-9]+$ ]] || delivery_age=0
    [[ "$sla" =~ ^[0-9]+$ ]] || sla=600
    if (( loop_alive_rc == 4 )); then
        # Bucket 4 (nexus-code#491): the liveness heartbeat is FRESH —
        # the ticker is beating — and the fault is a PROGRESS stall.
        # Recording it as 'loop-heartbeat-stale' would be a lie of the
        # exact class #491 is about (a mislabelled signal).
        printf 'watcher-fault reason=loop-wedged-progress-stalled loop_alive_rc=%d delivery_age=%ds' \
            "$loop_alive_rc" "$delivery_age"
        return 0
    fi
    if (( loop_alive_rc >= 2 )); then
        printf 'watcher-fault reason=loop-heartbeat-stale loop_alive_rc=%d delivery_age=%ds' \
            "$loop_alive_rc" "$delivery_age"
        return 0
    fi
    if (( fail_count > 0 )); then
        printf 'watcher-fault reason=emits-generated-but-stuck deliver_fail=%d delivery_age=%ds' \
            "$fail_count" "$delivery_age"
        return 0
    fi
    if (( delivery_age <= sla )); then
        printf 'orchestrator-fault reason=delivery-fresh delivery_age=%ds sla=%ds' \
            "$delivery_age" "$sla"
        return 1
    fi
    printf 'quiet reason=loop-alive-no-delivery-failures delivery_age=%ds sla=%ds' \
        "$delivery_age" "$sla"
    return 2
}

# _functional_check_record_state <state_file> <ts> <n_emits> <n_processed> <n_stale> <decision>
#
# Append a TSV row to the state file. Best-effort: failures are
# silent (a check that can't write its audit row is still a useful
# liveness signal, and the watcher's own LOGFILE captures the
# decision string).
_functional_check_record_state() {
    local state_file="${1:?state_file required}"
    local ts="${2:?ts required}"
    local n_emits="${3:?n_emits required}"
    local n_processed="${4:?n_processed required}"
    local n_stale="${5:?n_stale required}"
    local decision="${6:?decision required}"
    mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
    printf '%d\t%d\t%d\t%d\t%s\n' \
        "$ts" "$n_emits" "$n_processed" "$n_stale" "$decision" \
        >> "$state_file" 2>/dev/null || true
}
