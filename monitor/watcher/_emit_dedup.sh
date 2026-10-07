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
#   - the `idle` / `idle-too-long` split on the `workspace:` tally line,
#     folded into their sum (your-org/nexus-code#658)
#   - the trailing `--- nexus-emit-sig <iso> <nonce> ---` footer
# Everything else — eligible-comments rows, pending-decisions rows, the
# local-diff payload, bell entries — flows through untouched, so a
# genuinely new decision or comment still produces a distinct form and
# surfaces promptly.
#
# On the tally line specifically (your-org/nexus-code#658): the counts are
# a DERIVED SUMMARY of the per-window snapshot rows, and some of the
# buckets they summarise are functions of the clock alone. A window
# crossing MONITOR_IDLE_CLOSE_HOURS moves one unit from `idle` to
# `idle-too-long` while nothing whatsoever happens on the board — no
# window created, retired, renamed or re-stated. That flipped a canonical
# the change detector treats as a genuine change, so it both emitted
# immediately (bypassing the adaptive idle backoff) and RESET the
# idle-streak anchor, discarding an accumulated floor that had climbed to
# 28800 s and forcing the whole doubling ladder to re-climb. The anchor
# reset is the worse half: one clock crossing does not cost one emit, it
# costs the entire backoff, and several parked windows crossing at
# different times knock the floor back to base repeatedly on a board that
# has been static for days.
#
# Genuinely actionable transitions still punch through, because they
# change the per-window ROWS (`<window> … (state=<s>)`), which carry
# identity and are not stripped. `pane-absent`, `over-limit` and
# `interrupted` all move a row's `state=`; a 24-hour clock crossing moves
# nothing but an age, which was already stripped. The distinguishing
# property is not "did a count change" but "did anything change that is
# not a function of elapsed time alone" — and the rows answer that, while
# the tally cannot.
#
# ONLY the `idle` / `idle-too-long` pair is folded, and only into its
# sum. Every other counter keeps its value, so a counter this filter has
# never heard of lands on the SAFE side by default — where safe means
# "still emits". The asymmetry is the whole point: an unlisted
# clock-derived counter costs a noisy emit, an unlisted event-derived one
# costs a SILENT MISS, and only one of those is recoverable.
#
# `pane-absent` is the case that proves it. A `poll-resurface` body
# carries NO per-window rows — the tally line is the only place that
# count appears — so `pane-absent 1→0`, a worker dying, is visible there
# and nowhere else.
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
        s/taken [0-9]+s ago/taken ago/g
        /^--- nexus-emit-sig /d
    ' | awk '
        # your-org/nexus-code#658 — fold the CLOCK-DRIVEN half of the
        # workspace tally, and ONLY that half.
        #
        # `idle` and `idle-too-long` are one population under two labels.
        # The boundary between them is MONITOR_IDLE_CLOSE_HOURS, so a
        # window crossing it moves one unit from the first to the second
        # while NOTHING happens on the board. Their SUM is invariant under
        # that crossing and changes only when a window genuinely enters or
        # leaves the idle population — which is an event, not a clock tick.
        # So fold the pair into its sum: the crossing becomes invisible,
        # "a worker went idle" stays visible.
        #
        # Every other counter keeps its value. That is the whole design:
        # a counter this filter has never heard of lands on the SAFE side
        # by DEFAULT, where safe means "still emits". The first version of
        # this fix stripped every count on the line generically, which was
        # too broad for exactly the reason #658 named in advance —
        # `pane-absent 1→0` is a worker dying, and in a `poll-resurface`
        # body the tally line is the ONLY place it appears (that shape
        # carries no per-window rows at all, which is what made the
        # "the rows still carry it" argument wrong). Caught by
        # test-emit-dedup.sh, which had asserted it since #152.
        #
        # A denylist of clock-derived labels would be the same mistake
        # rotated: the twelfth counter would be added by someone who never
        # reads this file, and an unlisted clock-derived counter is a
        # NOISY emit, while an unlisted event-derived one is a SILENT
        # miss. Enumerate the pair we can prove is clock-driven; default
        # to keeping everything else.
        /^workspace: / {
            line = $0
            sub(/^workspace: /, "", line)
            # " \\| " — awk treats a multi-char separator as a REGEX, so a
            # bare "|" would be alternation and split on every space.
            n = split(line, f, " \\| ")
            idle = -1; too_long = -1; idle_i = 0; tl_i = 0
            for (i = 1; i <= n; i++) {
                if (f[i] ~ /^[0-9]+ idle$/)                { idle = f[i] + 0; idle_i = i }
                else if (f[i] ~ /^[0-9]+ idle-too-long$/)  { too_long = f[i] + 0; tl_i = i }
            }
            # Both must be present to fold. If a renderer drops or renames
            # either one, leave the line ALONE rather than guess — an
            # unfolded line is noisy, never silent.
            if (idle_i > 0 && tl_i > 0) {
                f[idle_i] = (idle + too_long) " idle-incl-too-long"
                f[tl_i]   = "idle-too-long"
            }
            out = "workspace: "
            for (i = 1; i <= n; i++) out = out f[i] (i < n ? " | " : "")
            print out
            next
        }
        { print }
    '
}

# Adaptive idle backoff for the full-state heartbeat (emit/exemption
# fidelity). Given how long the canonical full-state snapshot has been
# CONTINUOUSLY unchanged (idle_duration_s, measured by main.sh from the
# idle-streak anchor it resets on every genuine canonical change), return
# the effective safety-floor the suppression check should use this cycle.
#
# Rule: start at the base floor; double it each time sustained idle crosses
# the next power-of-two multiple of the base, capped at the max. The
# default max is 86400 (#1736): …→ 57600 (16h ≤ idle < 32h) → 86400
# (idle ≥ 32h). With base=900 / max=7200 that is 900 (idle < 30m) → 1800 (30m ≤ idle < 60m) →
# 3600 (60m ≤ idle < 120m) → 7200 (idle ≥ 120m).
#
# `max` is a TRUE CAP — any positive value is honoured exactly, not only
# the rungs `base * 2^k` (your-org/nexus-code#659). Worked example with a
# max that is deliberately NOT a rung, base=900 / max=43200: 900 → … →
# 28800 (8h ≤ idle < 16h) → 43200 (idle ≥ 16h). The old loop guard
# (`eff * 2 <= max`) refused the step that would overshoot instead of
# taking it and clamping, so `eff` could never exceed `max`, which made
# the trailing clamp — the only line that actually clamps TO max —
# unreachable. `43200` silently delivered `28800` for ever, and the
# worked example above could not exhibit it because 7200 IS a rung of
# 900. The example is kept alongside precisely so the two shapes are
# both pinned.
#
# A genuine change resets
# idle_duration to ~0 (the caller
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
    local max="${MONITOR_FULL_STATE_IDLE_BACKOFF_MAX_SECONDS:-86400}"
    [[ "$max" =~ ^[0-9]+$ ]] || max=86400
    (( max <= base )) && { printf '%s\n' "$base"; return 0; }
    local eff="$base" thresh="$base"
    # `eff < max`, NOT `eff * 2 <= max` (your-org/nexus-code#659). The
    # second form refuses the step that would overshoot; this one takes it
    # and lets the clamp below do its job. That is what makes the clamp
    # LIVE rather than dead code, and it is what makes `max` a cap rather
    # than a ladder terminator.
    while (( idle_s >= thresh * 2 && eff < max )); do
        eff=$(( eff * 2 )); thresh=$(( thresh * 2 ))
    done
    (( eff > max )) && eff="$max"
    printf '%s\n' "$eff"
}

# The ACTIONABLE projection of a full-state canonical
# (your-org/nexus-code#1736). main.sh compares the projection of the
# candidate canonical against the projection of the cached (last-emitted)
# one. Equal projections are "nothing the orchestrator acts on changed":
# the emit waits for the effective floor and the idle-streak anchor is
# NOT reset. Unequal projections emit at once and snap the anchor back.
#
# Why a projection and not the canonical itself: the canonical carries the
# ACTIVITY axis — each row's `(active, state=busy|working-background|…)`
# versus `idle (state=…)`, and the prelude's busy/idle counts. A worker
# woken for a minute by its own longjob watch flips that axis twice. With
# 5–7 self-waking workers the canonical changed every few minutes, every
# change both emitted at once and reset the anchor, and the backoff never
# climbed past its base rung (measured 2026-10-04: 11 non-actionable
# `poll-full-state` emits in 4 h 11 m on a board where every worker was
# waiting on its own Slurm jobs). The orchestrator never acts on an
# activity flip, so a flip must rarefy the heartbeat, not reset it.
#
# The emit BODY is untouched: when a heartbeat does land, it still shows
# who is busy. Only the change detector stops listening to activity.
#
# What is DROPPED, and only this (enumerated; everything else is kept):
#   prelude  `N busy`, `N idle`, `N retained`, `N unprobed`. Busy and idle
#            are the activity axis itself. `retained` is the idle class of
#            an operator-retained window, so it moves 1↔0 exactly when that
#            window flips busy↔idle. `unprobed` is the render-budget's
#            share of the busy residue (#1698): it moves with host load,
#            not with the board.
#   rows     `<w> (active, state=…)`, `<w> idle (state=…)` and
#            `<w> idle-awaiting-job (…)` all project to `<w> live`. These
#            are the three shapes one live worker passes through while it
#            waits on its own job. A `WEDGED?` note on an idle-awaiting-job
#            row survives as `<w> live wedged`: a stall is a finding, its
#            seconds-counter is not.
#   rows     every other RECOGNISED class keeps `<w> <class>` and drops
#            its detail (child counts, `state=` sub-activity, reset times,
#            recovery hints), because the class is what the orchestrator
#            acts on and the detail ticks while the class stands. A parked
#            worker's `state=busy` spinner is the plainest example.
#   order    rows are sorted: a window-set comparison, not a list one.
#
# What is KEPT: the window set (every row's name), every other prelude
# counter (idle-too-long, pane-absent, over-limit, orphan-async,
# interrupted, parked-skeptic, idle-children, awaiting-input), the class
# of every non-activity row, and ANY line or row class this filter does
# not recognise, verbatim. Same asymmetry as the #658 fold above: an
# unrecognised token costs a noisy emit, a wrongly dropped one costs a
# silent miss, so the default is keep.
#
# Requests, pending decisions and service health are not in the canonical
# at all. They emit through their own triggers; main.sh snaps the anchor
# back when a paste DELIVERS one of them.
#
# READ FAILED rows (your-org/nexus-code#1738 F2). A row whose pane-state
# probe FAILED (`state=unknown; pane-state.sh READ FAILED …`) renders through
# the idle arm, so it projects to `<w> live` like any idle worker: one failed
# read under host load is instrument churn, not a board change. But "could
# not determine" that PERSISTS is the state that most needs an operator, and
# at deep idle the heartbeat can be 24 h away. So the caller passes $1, the
# newline-separated names whose READ FAILED has persisted for N consecutive
# full-state polls (`_full_state_read_failed_streak_update`); a READ FAILED
# row named there projects with a ` read-failed` suffix. Without $1 the
# projection is exactly the pre-#1738 one.
#
# Pure: stdin → stdout. Input is the canonical (already volatile-stripped).
_full_state_actionable_projection() {
    # ENVIRON, not `awk -v`: -v processes backslash escapes in its value.
    _FS_RF_SET="${1:-}" awk '
        BEGIN {
            np = split(ENVIRON["_FS_RF_SET"], pa, "\n")
            for (i = 1; i <= np; i++) if (pa[i] != "") RF[pa[i]] = 1
        }
        function tally(line,    pre, rest, n, f, i, out) {
            pre = ""
            rest = line
            if (rest ~ /^workspace: /) { pre = "workspace: "; sub(/^workspace: /, "", rest) }
            n = split(rest, f, " \\| ")
            out = ""
            for (i = 1; i <= n; i++) {
                if (f[i] ~ /^[0-9]+ (busy|idle|retained|unprobed)$/) continue
                out = out (out == "" ? "" : " | ") f[i]
            }
            return pre out
        }
        function row(line,    name) {
            name = line
            sub(/^  - /, "", name); sub(/ .*/, "", name)
            return row_class(line, name) ((name in RF) && index(line, "READ FAILED") ? " read-failed" : "")
        }
        function row_class(line, name,    rest, cls) {
            rest = line
            sub(/^  - /, "", rest)
            rest = substr(rest, length(name) + 2)
            if (rest ~ /^\(active, state=/ || rest ~ /^idle \(state=/ || rest == "idle")
                return name " live"
            if (rest ~ /^idle-awaiting-job( |$)/)
                return name " live" (rest ~ /WEDGED\?/ ? " wedged" : "")
            cls = rest; sub(/ .*/, "", cls)
            if (cls ~ /^(pane-absent|OVER-LIMIT|interrupted|parked-awaiting-skeptic|orphaned-skeptic-pending|wrapped-with-children|wrapped-awaiting-protocol|operator-engaged)$/)
                return name " " cls (rest ~ /WEDGED\?/ ? " wedged" : "")
            return name " " rest
        }
        # The prelude: everything before ---snapshot--- (one tally line in
        # practice). A line that is not a tally passes through.
        !snap && $0 == "---snapshot---" { snap = 1; print; next }
        !snap && / busy( \||$)/ { print tally($0); next }
        !snap { print; next }
        /^  - / { rows[++nr] = row($0); next }
        { other[++no] = $0 }
        END {
            # Sort rows (insertion sort: a board is tens of windows).
            for (i = 2; i <= nr; i++) {
                v = rows[i]; j = i - 1
                while (j >= 1 && rows[j] > v) { rows[j + 1] = rows[j]; j-- }
                rows[j + 1] = v
            }
            for (i = 1; i <= nr; i++) print "  - " rows[i]
            for (i = 1; i <= no; i++) print other[i]
        }
    '
}

# The window names whose full-state row carries a pane-state READ FAILED
# (your-org/nexus-code#1738 F2). Pure: canonical on stdin → sorted names.
_full_state_read_failed_windows() {
    awk '/^  - / && index($0, "READ FAILED") {
            n = $0; sub(/^  - /, "", n); sub(/ .*/, "", n)
            if (n != "") print n
        }' | sort -u
}

# Advance the per-window READ FAILED streak by ONE full-state poll and print
# the names whose streak has reached N (your-org/nexus-code#1738 F2).
#   $1  streak file (`<window>\t<consecutive polls>`), under STATE_DIR
#   $2  N, the persistence threshold (MONITOR_FULL_STATE_READ_FAILED_PERSIST_POLLS)
#   stdin  this poll's READ FAILED names (`_full_state_read_failed_windows`)
# A name absent this poll is DROPPED, so its next failure starts again at 1:
# "persists" means N CONSECUTIVE polls. That is what keeps flicker inert — a
# row failing every other poll never reaches N, and below N the row projects
# as `live`, so it neither emits nor resets the backoff anchor.
# Returns 1 (and prints nothing) when the file cannot be written; the caller
# then projects without the persistent set, i.e. the pre-#1738 behaviour.
_full_state_read_failed_streak_update() {
    local file="$1" n="${2:-3}" cur
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 )) || n=3
    cur=$(cat)
    _FS_RF_CUR="$cur" awk -F'\t' '
        BEGIN { m = split(ENVIRON["_FS_RF_CUR"], c, "\n"); for (i = 1; i <= m; i++) if (c[i] != "") C[c[i]] = 1 }
        NF >= 2 && ($1 in C) && $2 ~ /^[0-9]+$/ { P[$1] = $2 }
        END { for (k in C) printf "%s\t%d\n", k, P[k] + 1 }
    ' "$file" 2>/dev/null < /dev/null > "${file}.tmp" \
        || _FS_RF_CUR="$cur" awk 'BEGIN { m = split(ENVIRON["_FS_RF_CUR"], c, "\n"); for (i = 1; i <= m; i++) if (c[i] != "") printf "%s\t1\n", c[i] }' > "${file}.tmp" \
        || return 1
    mv "${file}.tmp" "$file" 2>/dev/null || return 1
    _FS_RF_N="$n" awk -F'\t' '$2 >= ENVIRON["_FS_RF_N"] + 0 { print $1 }' "$file" | sort
}

# Which lines of a DELIVERED requests / pending-decisions / service-health
# payload are NEW to the full-state backoff (your-org/nexus-code#1738 F3).
#   $1  seen-keys file under STATE_DIR (one volatile-stripped line per key)
#   stdin  the payload; every non-blank line, volatile-stripped, is a key
# Prints the keys not in the file and appends them (the file keeps its
# newest 500 lines). main.sh snaps the heartbeat anchor back only when this
# prints something: a NEW or CHANGED item is a board change, a re-paste of
# an UNCHANGED standing item is not — the item has its own re-nag cadence
# (requests_render's per-id backoff, pending decisions' cooldown), which
# keeps re-surfacing it whatever the heartbeat does, so resetting the
# heartbeat on every re-nag only pinned it near base for as long as the item
# stood (#1736's defect again, on another trigger). A key forgotten past the
# cap, or a lost file, makes an old item count as new once: one extra snap,
# the safe direction. Returns 1 if the file cannot be written.
_full_state_delivery_new_keys() {
    local file="$1" cur new
    cur=$(_emit_volatile_strip | awk 'NF { print }')
    [[ -n "$cur" ]] || return 0
    new=$(_FS_DK_CUR="$cur" awk '
        BEGIN { m = split(ENVIRON["_FS_DK_CUR"], c, "\n") }
        { S[$0] = 1 }
        END { for (i = 1; i <= m; i++) if (c[i] != "" && !(c[i] in S) && !(c[i] in P)) { P[c[i]] = 1; print c[i] } }
    ' "$file" 2>/dev/null < /dev/null) || new="$cur"
    [[ -n "$new" ]] || return 0
    { cat "$file" 2>/dev/null; printf '%s\n' "$new"; } | tail -n 500 > "${file}.tmp" \
        && mv "${file}.tmp" "$file" 2>/dev/null || { printf '%s\n' "$new"; return 1; }
    printf '%s\n' "$new"
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

    # SERIALISE THE READ-MODIFY-WRITE (your-org/nexus-code#568 A1). This
    # function is reached from two tasks the scheduler fires as concurrent
    # `( … ) &` subshells — compose_emit (main.sh:4411 --async) and
    # comment_surface (main.sh:4420 --async), whose in-flight guard is
    # PER-TASK, so they genuinely overlap. The body below is read-modify-write
    # over one file: both subshells read the ring, both append their own hash,
    # and the loser's entry vanishes. Measured on the real function driven from
    # two concurrent subshells: 34 of 40 iterations lost one of the two hashes,
    # with the ring repeatedly collapsing from 8 entries to 1 — which shortens
    # the dedup window and re-creates the duplicate-paste symptom the ring was
    # built to fix.
    #
    # THE LOCK IS THE FIX; unique tmp names are only hygiene. With correctly
    # unique names and no lock, an independent measurement still recorded 23/40
    # lost updates. Bounded fail-open, exactly as `_emit_filters.sh:278-286`
    # does it: a lock we cannot take within 5s falls through to an unlocked
    # write rather than stalling an emit path.
    if command -v flock >/dev/null 2>&1; then
        local _rd_fd
        if { exec {_rd_fd}>"${ring_file}.lock"; } 2>/dev/null; then
            flock -w 5 "$_rd_fd" 2>/dev/null || true
            _compose_emit_record_emit_write "$ring_file" "$ring_size" "$new_hash" "$now_ts"
            exec {_rd_fd}>&-
            return 0
        fi
    fi
    _compose_emit_record_emit_write "$ring_file" "$ring_size" "$new_hash" "$now_ts"
    return 0
}

# The unguarded write core of `_compose_emit_record_emit` — rewrite the ring
# and refresh the legacy single-slot pair. Callers own any locking.
#
# NOTE ON THE TMP SUFFIX, because the obvious fix here is wrong. The names were
# `$$`-based, which is not unique across the async subshells that reach this
# code ($$ stays the parent watcher pid in a subshell). The mechanical remedy —
# substituting `$BASHPID` — SILENTLY DISABLES THE RING: the ring write is a
# PIPELINE, so the redirection is expanded in the last pipeline element's
# subshell while the `mv` on the next line expands a DIFFERENT `$BASHPID` in
# this function's own shell. The `mv` then names a file that does not exist,
# fails, and is swallowed by `|| true` — leaving an orphaned tmp file, no ring,
# and a dedup gate permanently degraded to the legacy single-slot path with no
# error anywhere. (The three sibling call sites cited as models — main.sh:921,
# _emit_filters.sh:313, _pane_cache.sh:148 — are all the non-pipeline
# `printf > f.tmp && mv` form, which is why `$BASHPID` is correct there.)
# So the suffix is computed ONCE, here, before the pipeline, and both the
# redirect and the `mv` observe that one string.
_compose_emit_record_emit_write() {
    local ring_file="$1" ring_size="$2" new_hash="$3" now_ts="$4"
    local _uniq="$$.${BASHPID:-$$}.$RANDOM"
    {
        if [[ -f "$ring_file" ]]; then
            grep -v $'\t'"${new_hash}\$" "$ring_file" 2>/dev/null || true
        fi
        printf '%s\t%s\n' "$now_ts" "$new_hash"
    } | tail -n "$ring_size" > "${ring_file}.tmp.${_uniq}" \
        && mv "${ring_file}.tmp.${_uniq}" "$ring_file" 2>/dev/null \
        || true
    rm -f "${ring_file}.tmp.${_uniq}" 2>/dev/null || true
    printf '%s\n' "$new_hash" > "${EMIT_DEDUP_HASH_FILE}.tmp.${_uniq}" \
        && mv "${EMIT_DEDUP_HASH_FILE}.tmp.${_uniq}" "$EMIT_DEDUP_HASH_FILE" 2>/dev/null \
        || true
    printf '%s\n' "$now_ts"   > "${EMIT_DEDUP_TS_FILE}.tmp.${_uniq}" \
        && mv "${EMIT_DEDUP_TS_FILE}.tmp.${_uniq}"   "$EMIT_DEDUP_TS_FILE"   2>/dev/null \
        || true
    return 0
}
