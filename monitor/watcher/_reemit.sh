#!/usr/bin/env bash
# Re-emit-until-acked registry for cross-repo bot-mention comments
# (your-org/nexus-code#236 — the "#310/#311 never surfaced" incident).
#
# WHY THIS EXISTS
# ---------------
# `snapshot_github` (the in-$REPO GraphQL backstop, 600 s cadence) is
# already re-emit-until-acked by construction: every fire re-queries the
# LIVE reaction state of every open issue/PR comment and re-surfaces any
# that lack the bot's 👀, so a transient failure to deliver one emit is
# self-healed on the next tick. That property holds ONLY for $REPO.
#
# Cross-repo bot-mention comments (a comment on your-org/nexus-code that
# @-mentions @your-org-bot, surfaced as a `mention=<repo> …` block
# by the deliveries path) have NO such backstop. The deliveries path is
# cursor-gated emit-ONCE: each webhook delivery is processed a single
# time, the GUID cursor advances past it, and the emit block is
# destructively drained from `deliveries-queue.lines` by compose_emit.
# If that single emit's paste fails — orchestrator over-limit, a tmux
# `load-buffer` glitch (the observed rc=3), a wedged compose_emit — the
# block is gone with no retry. That is exactly how nexus-code#310/#311
# slipped through: they were queued, the sole drainer (compose_emit) was
# wedged, and there was no re-emit to give them a second chance.
#
# WHAT THIS DOES
# --------------
# A durable per-comment registry of UN-ACKED cross-repo bot-mention
# blocks. compose_emit registers every fresh cross-repo block here, then
# re-feeds the registry into the shared `_gh_filter_dedup_pipeline` on
# every fire. Re-emit-until-acked then emerges from machinery that
# already exists:
#
#   * `_filter_processed_comments` drops any block whose `comment:<id>`
#     is in processed-comments.txt — the BOT's 👀-ack cache, written by
#     `ng react <id> eyes` (POSTs the bot reaction AND appends the id).
#     So a re-fed block stops surfacing the instant the bot acks it.
#   * `_filter_emit_cooldown` (MONITOR_EMIT_COOLDOWN_SECONDS, 300 s)
#     throttles the re-emit to at most once per comment per window — the
#     cadence, NOT a per-poll storm.
#   * `_compose_emit_should_bypass_dedup` already exempts eligible-
#     comment bodies from the content-hash dedup, so an unchanged re-emit
#     still surfaces.
#
# So the registry itself is deliberately thin: persist, re-feed, and
# garbage-collect. Ack-suppression and cadence are reused, not
# reinvented.
#
# DURABILITY / RESTART
# --------------------
# The registry file lives under $STATE_DIR (on persistent storage, not
# /tmp), so an un-acked comment survives a watcher `--replace` /
# version-restart. processed-comments.txt (the ack cache) is likewise
# durable. A restart therefore forgets nothing.
#
# BOUNDS
# ------
# GC evicts an entry when ANY of:
#   1. it is acked — `comment:<id>` present in processed-comments.txt;
#   2. (optional, MONITOR_REEMIT_LIVE_RECHECK=true) a live reactions
#      query shows an EYES/ROCKET by a login != USER_LOGIN (i.e. the
#      bot — the same non-self predicate `snapshot_github` uses, so it
#      is robust to the `[bot]` login suffix). This is the ONLY path that
#      catches a bot reaction placed by anything other than `ng react`
#      (a direct `gh api`/MCP react, or a wrap-up rocket) — those never
#      write processed-comments.txt, so without it the bot's 👀/🚀 would
#      not suppress the re-emit. Throttled to ≤ one API call per un-acked
#      comment per cooldown window via a per-entry `last_recheck=` stamp
#      carried on the `# meta` line. Keying the throttle on a DEDICATED
#      recheck stamp (rather than the comment's emit timestamp) decouples
#      ack-detection from emit cadence: a comment that is actively
#      re-emitting can no longer starve its own recheck, and an entry that
#      has never surfaced is no longer rechecked on every pass. So the
#      bot's reaction is honored within one cooldown regardless of how
#      often (or whether) the block re-emits — matching `snapshot_github`'s
#      per-cycle live-reaction suppression for in-$REPO comments.
#   3. it has aged past MONITOR_REEMIT_MAX_AGE_SECONDS (default 3 days,
#      matching GitHub's webhook-delivery retention) — a safety valve so
#      a comment the bot can never ack (deleted, repo uninstalled) does
#      not re-emit forever. Eviction-by-age logs loudly.
#
# Every register / re-emit / eviction is logged so the behaviour is
# observable, never silent.
#
# Side-effect-free at source time: only function definitions. Caller
# globals (set by main.sh before any call):
#   STATE_DIR                       monitor/.state
#   USER_LOGIN                      github.user_login (the operator)
#   MONITOR_REEMIT_ENABLED          master switch (default true)
#   MONITOR_REEMIT_MAX_AGE_SECONDS  age cap (default 259200 = 3 d)
#   MONITOR_REEMIT_LIVE_RECHECK     live-reaction GC recheck (default true)
#   MONITOR_EMIT_COOLDOWN_SECONDS   re-emit cadence (shared, default 300)
#   MONITOR_REEMIT_GH_CMD           gh command name (test-injection hook)
#   log                             watcher logger (function; optional)

_reemit_registry_path() { printf '%s\n' "${STATE_DIR}/unacked-mentions.lines"; }
_reemit_lock_path()     { printf '%s\n' "${STATE_DIR}/unacked-mentions.lock"; }

_reemit_enabled() { [[ "${MONITOR_REEMIT_ENABLED:-true}" == "true" ]]; }

# `log` may be undefined when this file is sourced standalone (tests).
# Degrade to a silent no-op so the registry functions stay usable in
# isolation without dragging in main.sh's logger.
_reemit_log() {
    if declare -F log >/dev/null 2>&1; then
        log "$@"
    fi
}

# _reemit_register  (reads emit blocks on stdin)
#
# Append every FRESH cross-repo (`mention=` / `cross_repo=`) block to the
# registry. A block is fresh when its `id=<N>` is neither already in the
# registry nor already STOPPED (`rocket:<id>` in processed-comments.txt —
# the bot 🚀'd it, i.e. done). A bare 👀 (`comment:<id>`) does NOT bar
# registration anymore: under the two-tier policy (your-org/nexus-code#360)
# an acknowledged-but-not-done mention stays registered so it can re-emit on
# the SLOW (6h) "still on track?" cadence until the 🚀 lands. In-$REPO shapes
# (`issue=`/`pr=`/`pr_review=`/`issue_new=`) are intentionally ignored —
# `snapshot_github` already re-emits those until acked.
#
# Each fresh entry starts in the FAST tier (`tier=fast last_reemit=0`); the
# next `_reemit_gc` pass reclassifies it to `slow` once a 👀 is detected.
#
# DIRECT vs CONTEXT (`direct=yes|no`, your-org/nexus-code#359 round-2). The
# caller pipes the drained stream through `_filter_cross_repo_surface` first,
# so every block reaching here is one the bot is addressed in. An
# operator-authored block is `direct=yes` (the two-tier direct re-emit
# above). A foreign/other-user block that nonetheless involves our bot is
# `direct=no` — PRESERVED in the registry as retained context but NEVER
# re-fed for direct emission (`_reemit_pending` skips it; the operator-author
# chokepoint blocks it on the direct path too). This keeps user-relevant
# cross-tenant content instead of discarding it, without ever leaking it into
# direct emission. Foreign blocks the bot is NOT addressed in are dropped
# upstream by `_filter_cross_repo_surface` (the only blocks actually drained).
#
# Stdin is consumed; callers that also need the same bytes downstream
# must tee/duplicate (compose_emit feeds a captured copy).
_reemit_register() {
    if ! _reemit_enabled; then cat >/dev/null 2>&1 || true; return 0; fi
    local reg lock now processed
    reg=$(_reemit_registry_path); lock=$(_reemit_lock_path)
    now=$(date +%s)
    processed="${STATE_DIR}/processed-comments.txt"
    mkdir -p "$(dirname "$reg")" 2>/dev/null || true
    local input; input=$(cat)
    [[ -n "$input" ]] || return 0
    local added
    added=$(
        (
            flock -x 200
            printf '%s\n' "$input" | awk \
                -v now="$now" -v regfile="$reg" -v procfile="$processed" \
                -v userlogin="${USER_LOGIN:-}" '
                BEGIN {
                    while ((getline l < regfile) > 0)
                        if (match(l, /id=[0-9]+/))
                            seen[substr(l, RSTART+3, RLENGTH-3)] = 1
                    close(regfile)
                    # Only a 🚀 (`rocket:<id>`) bars registration. A bare 👀
                    # (`comment:<id>`) leaves the mention registrable so the
                    # slow tier can keep nudging until done (#360).
                    while ((getline l < procfile) > 0) {
                        gsub(/^[ \t]+|[ \t]+$/, "", l)
                        if (substr(l,1,7) == "rocket:") rocketed[substr(l,8)] = 1
                    }
                    close(procfile)
                    header=""; body=""; hid=""; hrepo=""
                }
                function flush(   ok, hauthor, direct) {
                    if (header == "") { body=""; hid=""; hrepo=""; return }
                    ok = (header ~ /^(mention|cross_repo)=/) && hid != "" \
                         && !(hid in seen) && !(hid in rocketed)
                    if (ok) {
                        # DIRECT vs CONTEXT (your-org/nexus-code#359 round-2).
                        # The upstream `_filter_cross_repo_surface` already
                        # guaranteed every block here is one the bot is
                        # addressed in (mention_only: body @-mentions the bot →
                        # "bot participated"). Classify by author:
                        #   author == operator → DIRECT re-emit (two-tier).
                        #   author != operator → a foreign/other-user comment
                        #     that nonetheless involves our bot → PRESERVE as
                        #     `direct=no` CONTEXT: kept in the registry but NEVER
                        #     re-fed for direct emission (the operator-author
                        #     chokepoint blocks it downstream too). Not lost,
                        #     not direct-emitted. Foreign blocks the bot is NOT
                        #     addressed in were already dropped upstream (drain).
                        hauthor = (match(header, /author=[^[:space:]]+/)) \
                                  ? substr(header, RSTART+7, RLENGTH-7) : ""
                        direct = (userlogin != "" && hauthor == userlogin) ? "yes" : "no"
                        printf "# meta id=%s repo=%s first_seen=%s tier=fast last_reemit=0 direct=%s\n", \
                               hid, hrepo, now, direct
                        print header
                        if (body != "") print body
                        seen[hid] = 1
                    }
                    header=""; body=""; hid=""; hrepo=""
                }
                /^(issue|pr|pr_review|issue_new|mention|cross_repo)=/ {
                    flush()
                    header=$0; body=""
                    hid   = (match($0,/id=[0-9]+/))   ? substr($0,RSTART+3,RLENGTH-3) : ""
                    hrepo = (match($0,/^(mention|cross_repo)=[^ ]+/)) \
                            ? substr($0, index($0,"=")+1, RLENGTH-index($0,"=")) : ""
                    next
                }
                /^[[:space:]]+body:/ {
                    if (header != "" && body == "") body=$0
                    else { flush() }
                    next
                }
                { flush() }
                END { flush() }
            ' | tee -a "$reg" | LC_ALL=C awk '/^(mention|cross_repo)=/{n++} END{print n+0}'
        ) 200>"$lock"
    )
    [[ "$added" =~ ^[0-9]+$ ]] || added=0
    if (( added > 0 )); then
        # awk count (binary-safe; see _reemit_pending) — a grep -c over the
        # emoji/NEL-bearing registry would miscount under binary detection.
        _reemit_log "reemit: registered ${added} un-acked cross-repo block(s) (registry now $(LC_ALL=C awk '/^(mention|cross_repo)=/{n++} END{print n+0}' "$reg" 2>/dev/null || echo '?') pending)"
    fi
    return 0
}

# _reemit_pending  (stdout)
#
# Print the registry's emit blocks (header + body) that are DUE to re-emit
# under the two-tier reaction-gated cadence (your-org/nexus-code#360),
# stripping the internal `# meta` bookkeeping lines, for re-feeding into
# `_gh_filter_dedup_pipeline`.
#
#   * tier=fast (no 👀 yet)  -> due every MONITOR_REEMIT_NOEYES_MINUTES.
#   * tier=slow (👀, no 🚀)  -> due every MONITOR_REEMIT_NOROCKET_HOURS.
#
# (🚀'd entries never reach here — `_reemit_gc` evicts them.) This is the
# SOURCE gate for both tiers: a block is re-fed at most once per its tier's
# cadence regardless of what the downstream filters do, so the policy holds
# even if `_filter_reemit_backoff`/`_filter_emit_cooldown` are disabled. The
# `last_reemit=` stamp on each entry's `# meta` line is advanced (under the
# registry lock) for every block this pass re-feeds; not-yet-due entries are
# left untouched and simply not emitted.
#
# Byte-safety: same LC_ALL=C / awk-not-grep discipline as before — mention
# body previews carry UTF-8 emoji + U+0085 (NEL) bytes that make GNU grep
# misclassify the registry as binary and corrupt the re-feed.
_reemit_pending() {
    _reemit_enabled || return 0
    local reg lock; reg=$(_reemit_registry_path); lock=$(_reemit_lock_path)
    [[ -f "$reg" ]] || return 0
    local now noeyes norocket
    now=$(date +%s)
    noeyes=$(( ${MONITOR_REEMIT_NOEYES_MINUTES:-5} * 60 ))
    norocket=$(( ${MONITOR_REEMIT_NOROCKET_HOURS:-6} * 3600 ))
    (( noeyes  > 0 )) || noeyes=300
    (( norocket > 0 )) || norocket=21600
    (
        flock -x 200
        [[ -f "$reg" ]] || exit 0
        local tmp="${reg}.pending.$$"
        LC_ALL=C awk -v now="$now" -v noeyes="$noeyes" -v norocket="$norocket" \
            -v tmp="$tmp" '
            function decide(   cadence, due, i, m) {
                if (cur_meta == "") return
                # direct=no = retained CONTEXT (foreign/other-user block the
                # bot is involved in, #359 round-2): persist it untouched but
                # NEVER re-feed it for direct emission.
                if (cur_direct == "no") {
                    print cur_meta > tmp
                    for (i = 0; i < nblk; i++) print blk[i] > tmp
                    cur_meta=""; nblk=0; cur_tier="fast"; cur_lre=0; cur_direct="yes"
                    return
                }
                cadence = (cur_tier == "slow") ? norocket : noeyes
                due = (now - cur_lre) >= cadence
                m = cur_meta
                if (due) {
                    for (i = 0; i < nblk; i++) print blk[i]       # re-feed -> stdout
                    if (m ~ /last_reemit=[0-9]+/) sub(/last_reemit=[0-9]+/, "last_reemit=" now, m)
                    else m = m " last_reemit=" now
                }
                print m > tmp                                    # persist (updated if due)
                for (i = 0; i < nblk; i++) print blk[i] > tmp
                cur_meta=""; nblk=0; cur_tier="fast"; cur_lre=0; cur_direct="yes"
            }
            /^# meta / {
                decide()
                cur_meta=$0
                cur_tier = (match($0,/tier=(slow|fast)/)) ? substr($0,RSTART+5,RLENGTH-5) : "fast"
                cur_lre  = (match($0,/last_reemit=[0-9]+/)) ? substr($0,RSTART+12,RLENGTH-12)+0 : 0
                cur_direct = (match($0,/direct=(yes|no)/)) ? substr($0,RSTART+7,RLENGTH-7) : "yes"
                nblk=0
                next
            }
            { if (cur_meta != "") blk[nblk++]=$0; else print > tmp }
            END { decide() }
        ' "$reg" 2>/dev/null
        if [[ -s "$tmp" ]]; then
            mv "$tmp" "$reg" 2>/dev/null || rm -f "$tmp"
        else
            rm -f "$tmp" "$reg" 2>/dev/null || true
        fi
    ) 200>"$lock"
    return 0
}

# _reemit_reaction_state <repo> <comment_id>   (stdout: rocket|eyes|none)
#
# Classifies the live, non-self (i.e. bot) reaction on a comment for the
# two-tier re-emit policy (your-org/nexus-code#360). Prints exactly one of:
#   rocket  — a 🚀 by a login != USER_LOGIN is present  → STOP (evict).
#   eyes    — a 👀 by a login != USER_LOGIN, no such 🚀  → SLOW (6h) tier.
#   none    — neither                                    → FAST (5min) tier.
# 🚀 dominates 👀 (a done mention that was also eyed is still done). Uses the
# same non-self predicate as `snapshot_github`, robust to the `[bot]` login
# suffix. Returns 2 on gh failure WITHOUT printing (caller treats as
# "unknown" — neither evicts nor reclassifies). REST returns lowercase
# `eyes`/`rocket`.
_reemit_reaction_state() {
    local repo="$1" cid="$2"
    local gh_cmd="${MONITOR_REEMIT_GH_CMD:-gh}"
    [[ -n "$repo" && -n "$cid" ]] || return 2
    local out rc=0
    out=$("$gh_cmd" api "repos/$repo/issues/comments/$cid/reactions" 2>/dev/null) || rc=$?
    (( rc == 0 )) || return 2
    printf '%s' "$out" | jq -r --arg u "${USER_LOGIN:-}" '
        [.[] | select((.user.login // "") != $u) | .content] as $r
        | if ($r | index("rocket")) then "rocket"
          elif ($r | index("eyes")) then "eyes"
          else "none" end' 2>/dev/null
    return 0
}

# _reemit_target_state <repo> <number>   (stdout: open|closed; empty on failure)
#
# State of the mention's TARGET issue/PR (your-org/nexus-code#384). Used to
# make a non-operator 👀 terminal on a CLOSED/MERGED target: the slow-tier
# "still on track?" reminder is meaningless once the target is closed, and a
# merged PR reports "closed" here. The `repos/{repo}/issues/{n}` endpoint
# serves BOTH issues and PRs (a PR is an issue), so one path covers every
# `kind=`. Returns 1 WITHOUT printing on gh failure or an unexpected value
# (caller treats as "unknown" — does NOT evict, leaving the entry on its
# normal cadence). Throttled by the same per-entry recheck cadence as
# `_reemit_reaction_state`, so this adds at most one call per 👀'd entry per
# cooldown.
_reemit_target_state() {
    local repo="$1" n="$2"
    local gh_cmd="${MONITOR_REEMIT_GH_CMD:-gh}"
    [[ -n "$repo" && "$n" =~ ^[0-9]+$ ]] || return 1
    local out rc=0
    out=$("$gh_cmd" api "repos/$repo/issues/$n" --jq '.state' 2>/dev/null) || rc=$?
    (( rc == 0 )) || return 1
    out="${out//[$'\n\r\t ']/}"
    [[ "$out" == "open" || "$out" == "closed" ]] || return 1
    printf '%s' "$out"
    return 0
}

# Back-compat shim: 0 = bot acked (👀 or 🚀), 1 = not, 2 = gh failure.
# Retained for any caller/test that only needs the boolean ack.
_reemit_acked_live() {
    local st
    st=$(_reemit_reaction_state "$1" "$2") || return 2
    [[ "$st" == "rocket" || "$st" == "eyes" ]] && return 0
    return 1
}

# _reemit_gc
#
# Two-tier reaction-gated GC (your-org/nexus-code#360). Evicts 🚀'd (done)
# and aged entries, demotes 👀'd (acknowledged) entries to the SLOW tier,
# and rewrites the registry. A 🚀 is the terminal STOP; a bare 👀 no longer
# evicts — it flips `tier=slow` so the entry re-emits on the 6h "still on
# track?" cadence (via `_reemit_pending`) until the 🚀 lands or it ages out.
#
# EXCEPTION — 👀 on a CLOSED/MERGED target is terminal (your-org/nexus-code
# #384). The slow-tier "still on track?" reminder only makes sense while the
# target issue/PR is OPEN. A merged/closed PR has no remaining work, yet
# under the bare two-tier rule a 👀'd mention on it re-surfaced every slow
# cycle for the whole max-age window (the operator re-acked an answered
# merged-PR mention that "never stuck"). When MONITOR_REEMIT_EVICT_EYES_ON_
# CLOSED is true (default), a non-operator 👀 on a closed/merged target
# evicts — parity with `snapshot_github`'s EYES-clear for OPEN in-$REPO
# comments — while OPEN cross-repo work keeps its slow reminder untouched.
# The target-state check (`_reemit_target_state`) rides the live recheck (so
# it is gated by MONITOR_REEMIT_LIVE_RECHECK) and only fires for a 👀'd entry
# that would otherwise persist, throttled per-entry per cooldown.
#
# Reaction source of truth: the bot's reactions. Two detection paths, same
# as the ack cache before — a cheap LOCAL one and a robust LIVE one:
#   * local: `rocket:<id>` in processed-comments.txt → evict; `comment:<id>`
#            → 👀 → slow. (`ng react`/`wrap-up` write these.)
#   * live:  `_reemit_reaction_state` reactions query (rocket|eyes|none),
#            throttled to ≤ one call per un-acked entry per cooldown — the
#            ONLY path that catches a 🚀/👀 placed by something that doesn't
#            write processed-comments (a direct `gh api`/MCP react).
# Safe to call every compose_emit fire (cheap: one file scan; live rechecks
# are throttled and only when MONITOR_REEMIT_LIVE_RECHECK=true).
_reemit_gc() {
    _reemit_enabled || return 0
    local reg lock; reg=$(_reemit_registry_path); lock=$(_reemit_lock_path)
    [[ -f "$reg" ]] || return 0
    local now max_age processed cooldown live_recheck
    now=$(date +%s)
    max_age="${MONITOR_REEMIT_MAX_AGE_SECONDS:-259200}"
    [[ "$max_age" =~ ^[0-9]+$ ]] || max_age=259200
    processed="${STATE_DIR}/processed-comments.txt"
    cooldown="${MONITOR_EMIT_COOLDOWN_SECONDS:-300}"
    [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=300
    live_recheck="${MONITOR_REEMIT_LIVE_RECHECK:-true}"
    local closed_evict="${MONITOR_REEMIT_EVICT_EYES_ON_CLOSED:-true}"

    (
        flock -x 200
        [[ -f "$reg" ]] || exit 0

        # Build the live-recheck eviction set in bash (awk can't call gh).
        # Each un-acked entry is rechecked at most once per cooldown, so the
        # API cost is bounded to ≤ one call per un-acked comment per cooldown
        # window. processed-comments + max-age are handled in awk.
        #
        # THROTTLE KEY = per-entry LAST-RECHECK time, NOT the emit time.
        # (your-org/nexus-code: "bot's 👀/🚀 keeps re-emitting" — operator-
        # confirmed.) The original throttle keyed on `comment-<id>.meta` ts
        # (the EMIT stamp), which the re-emit itself refreshes every time the
        # block surfaces. A comment that re-emits on its cooldown cadence
        # therefore kept its emit stamp perpetually "fresh", so `now -
        # last_emit < cooldown` stayed true and the ack-detecting recheck was
        # STARVED — the bot's reaction (placed by any path that doesn't write
        # processed-comments.txt, e.g. a direct `gh api`/MCP react or a
        # wrap-up rocket) was never seen and the comment re-surfaced for many
        # cooldown windows. Worse, entries that had never surfaced (no emit
        # stamp → last_emit=0) bypassed the throttle entirely and were
        # rechecked EVERY pass, hammering the reactions endpoint for the
        # whole foreign-operator backlog and rate-limiting the legitimate
        # rechecks. Keying on a dedicated `last_recheck=` field (carried on
        # the entry's own `# meta` line, advanced below and persisted by the
        # awk rewrite) decouples ack-detection from emit cadence: every
        # un-acked entry is rechecked once per cooldown regardless of how
        # often it surfaces, so the bot's 👀/🚀 is honored within one
        # cooldown — matching `snapshot_github`'s live-reaction suppression.
        local live_evict="${reg}.live.$$"
        local live_eyes="${reg}.liveeyes.$$"
        local live_eyes_closed="${reg}.liveeyesclosed.$$"
        local rechecked="${reg}.rechecked.$$"
        : > "$live_evict"; : > "$live_eyes"; : > "$live_eyes_closed"; : > "$rechecked"
        if [[ "$live_recheck" == "true" ]]; then
            # Walk meta + its following block TOGETHER: the recheck fires on the
            # entry's `mention=`/`cross_repo=` block line, which carries `n=`
            # (the target issue/PR number) needed for the closed-target check.
            # `mid` is the meta's comment id; it is consumed (set empty) on the
            # first block line so the trailing `  body:` line is skipped.
            local mid mrepo last_recheck mdirect ln st
            mid=""; mrepo=""; last_recheck=0; mdirect="yes"
            while IFS= read -r ln; do
                if [[ "$ln" == \#\ meta\ * ]]; then
                    mid=""; mrepo=""; last_recheck=0; mdirect="yes"
                    [[ "$ln" =~ id=([0-9]+) ]]               && mid="${BASH_REMATCH[1]}"
                    [[ "$ln" =~ repo=([^[:space:]]+) ]]      && mrepo="${BASH_REMATCH[1]}"
                    [[ "$ln" =~ last_recheck=([0-9]+) ]]     && last_recheck="${BASH_REMATCH[1]}"
                    [[ "$ln" == *" direct=no"* ]]            && mdirect="no"
                    continue
                fi
                # Trigger once per entry, on its first emit-block line.
                [[ -n "$mid" ]] || continue
                [[ "$ln" == mention=* || "$ln" == cross_repo=* ]] || continue
                local mnum=""; [[ "$ln" =~ (^|[[:space:]])n=([0-9]+) ]] && mnum="${BASH_REMATCH[2]}"
                local cmid="$mid"; mid=""   # consume — exactly one recheck per entry
                [[ -n "$cmid" && -n "$mrepo" ]] || continue
                # `direct=no` = retained CONTEXT (#359 round-2): never
                # direct-emits, so its reaction state is irrelevant — DON'T
                # spend a (foreign-repo) reactions API call on it. Retained
                # by the awk pass; aged out by max-age only.
                [[ "$mdirect" == "no" ]] && continue
                # Already 🚀'd locally → awk evicts it; no API call needed.
                grep -qxF "rocket:${cmid}" "$processed" 2>/dev/null && continue
                # Throttle on the per-entry LAST-RECHECK time: one reactions
                # call per entry per cooldown, independent of re-emit cadence —
                # so a still-re-emitting mention cannot starve its own
                # reaction detection.
                (( now - last_recheck < cooldown )) && continue
                # Record that this entry was rechecked at `now` so the awk
                # rewrite advances its `last_recheck=` stamp.
                printf '%s\n' "$cmid" >> "$rechecked"
                st=$(_reemit_reaction_state "$mrepo" "$cmid") || st=""
                case "$st" in
                    rocket) printf '%s\n' "$cmid" >> "$live_evict" ;;
                    eyes)
                        printf '%s\n' "$cmid" >> "$live_eyes"
                        # A non-operator 👀 on a CLOSED/MERGED target is
                        # terminal (your-org/nexus-code#384) — one extra,
                        # already-throttled state call, only for an entry that
                        # would otherwise persist on the slow tier forever.
                        if [[ "$closed_evict" == "true" && -n "$mnum" ]] \
                           && [[ "$(_reemit_target_state "$mrepo" "$mnum")" == "closed" ]]; then
                            printf '%s\n' "$cmid" >> "$live_eyes_closed"
                        fi
                        ;;
                esac
            done < "$reg"
        fi

        local tmp="${reg}.gc.$$" iso
        iso=$(date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
        awk -v now="$now" -v maxage="$max_age" -v procfile="$processed" \
            -v liveevict="$live_evict" -v liveeyes="$live_eyes" -v rechecked="$rechecked" \
            -v liveclosed="$live_eyes_closed" \
            -v logfile="${STATE_DIR}/watcher.log" \
            -v iso="$iso" '
            BEGIN {
                # rocket:<id> → STOP (evict). comment:<id> → 👀 → slow tier.
                while ((getline l < procfile) > 0) {
                    gsub(/^[ \t]+|[ \t]+$/, "", l)
                    if (substr(l,1,7) == "rocket:")       rocketed[substr(l,8)] = 1
                    else if (substr(l,1,8) == "comment:")  eyed[substr(l,9)] = 1
                }
                close(procfile)
                while ((getline l < liveevict) > 0) if (l != "") liverocket[l] = 1
                close(liveevict)
                while ((getline l < liveeyes) > 0)  if (l != "") liveeye[l] = 1
                close(liveeyes)
                # 👀 on a CLOSED/MERGED target → terminal STOP (#384).
                while ((getline l < liveclosed) > 0) if (l != "") closedevict[l] = 1
                close(liveclosed)
                while ((getline l < rechecked) > 0) if (l != "") rechecknow[l] = 1
                close(rechecked)
                cur_id=""; cur_fs=0; cur_direct="yes"; rec=""
            }
            function decide(   drop, reason) {
                if (cur_id == "") { rec=""; return }
                drop=0; reason=""
                # direct=no = retained CONTEXT: never 🚀/👀-evicted (it does
                # not direct-emit); aged out by max-age ONLY (bounds growth).
                if (cur_direct == "no") {
                    if (maxage > 0 && cur_fs > 0 && (now - cur_fs) >= maxage) {
                        printf "[%s] reemit-gc: evicted id=%s reason=max-age (retained context, aged out)\n", \
                            iso, cur_id >> logfile
                    } else {
                        printf "%s", rec
                    }
                    cur_id=""; cur_fs=0; cur_direct="yes"; rec=""
                    return
                }
                if (cur_id in rocketed)        { drop=1; reason="rocket" }
                else if (cur_id in liverocket)  { drop=1; reason="rocket-live" }
                else if (cur_id in closedevict) { drop=1; reason="eyes-closed" }
                else if (maxage > 0 && cur_fs > 0 \
                         && (now - cur_fs) >= maxage) { drop=1; reason="max-age" }
                if (drop) {
                    if (reason == "max-age")
                        printf "[%s] reemit-gc: evicted id=%s reason=max-age age=%ds (un-acked past cap; will no longer re-emit)\n", \
                            iso, cur_id, (now - cur_fs) >> logfile
                    else if (reason == "eyes-closed")
                        printf "[%s] reemit-gc: evicted id=%s reason=eyes-closed (👀-acked mention on a closed/merged target — stop re-emit)\n", \
                            iso, cur_id >> logfile
                    else
                        printf "[%s] reemit-gc: evicted id=%s reason=%s (done — stop re-emit)\n", \
                            iso, cur_id, reason >> logfile
                } else {
                    printf "%s", rec
                }
                cur_id=""; cur_fs=0; cur_direct="yes"; rec=""
            }
            /^# meta / {
                decide()
                cur_id = (match($0,/id=[0-9]+/))         ? substr($0,RSTART+3,RLENGTH-3)  : ""
                cur_fs = (match($0,/first_seen=[0-9]+/)) ? substr($0,RSTART+11,RLENGTH-11)+0 : 0
                cur_direct = (match($0,/direct=(yes|no)/)) ? substr($0,RSTART+7,RLENGTH-7) : "yes"
                meta = $0
                # `direct=no` retained context never gets a reaction tier — skip
                # the 👀-demote so a stray comment:<id> cannot flip it to slow.
                # A 👀 (local comment: or live eyes) demotes a DIRECT entry to
                # SLOW; otherwise keep whatever tier the meta carries (fresh =
                # fast). A done/rocket entry is dropped by decide() above.
                if (cur_direct != "no" && cur_id != "" && ((cur_id in eyed) || (cur_id in liveeye))) {
                    if (meta ~ /tier=(slow|fast)/) sub(/tier=(slow|fast)/, "tier=slow", meta)
                    else meta = meta " tier=slow"
                }
                # Advance the per-entry recheck stamp for entries rechecked
                # this cycle (kept ones persist it; evicted ones are dropped).
                if (cur_id != "" && (cur_id in rechecknow)) {
                    if (meta ~ /last_recheck=[0-9]+/)
                        sub(/last_recheck=[0-9]+/, "last_recheck=" now, meta)
                    else
                        meta = meta " last_recheck=" now
                }
                rec = meta "\n"
                next
            }
            { rec = rec $0 "\n" }
            END { decide() }
        ' "$reg" > "$tmp" 2>/dev/null

        if [[ -s "$tmp" ]]; then
            mv "$tmp" "$reg" 2>/dev/null || rm -f "$tmp"
        else
            # Empty result: registry fully drained — remove it so the
            # next register starts clean (and `_reemit_pending` no-ops).
            rm -f "$tmp" "$reg" 2>/dev/null || true
        fi
        rm -f "$live_evict" "$live_eyes" "$live_eyes_closed" "$rechecked" 2>/dev/null || true
    ) 200>"$lock"
    return 0
}
