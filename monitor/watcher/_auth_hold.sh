#!/usr/bin/env bash
# _auth_hold.sh — hold the watcher's emit while the operator is logging in,
# and break out of an ABANDONED login after ~1 h.
# your-org/nexus-code#1518, the paste half of #1517.
#
# ============================================================================
# THE DEFECT THIS CLOSES
# ============================================================================
#
# The watcher's three emit paste sites (`main.sh:3607`, `:4485`, `:4894`) never
# consult `pane-state.sh`. The only thing between them and the orchestrator's
# pane is the `#745` dead-pane guard. `_paste_to_target_unlocked` then sends
# `i BSpace` → `paste-buffer` → **Enter** — and into a select dialog that Enter
# is the CONFIRM. On the `/login` method menu it picks whichever login method
# the cursor is on, and the emit is eaten.
#
# This is the hazard `#1200` already closed ONE LAYER OVER, in
# `monitor/paste-followup.sh:889`, which has refused `state=blocked` since:
#
#   > the trailing Enter would be consumed by the overlay and SELECT ITS
#   > HIGHLIGHTED DEFAULT, not deliver this message
#
# The follow-up path got that guard; the watcher's own emit path did not.
#
# THE ESCAPE THIS MODULE SENDS IS THE FIRST KEYSTROKE THE WATCHER AIMS AT A
# LOGIN SCREEN (skeptic w237sk F5). An earlier write-up of this work claimed
# `_unstick.sh`'s case-D `auto-dismiss` arm already sent `Escape` on a login
# dialog, presenting this one as a second such keystroke. That was false, and
# false in the REASSURING direction. Case D is `_act_askuq`, fingerprinted on
# AskUserQuestion markers, and none of the four arms of `_handle_unstick_window`
# (A chevron menu, B rate-limit cascade, C backoff Enter, D askuq) fires on a
# login frame.
#
# SCOPE OF THAT CORRECTION: those four dispatcher arms are what was read.
# `_unstick.sh` has other entry points that were NOT checked, so "no unstick path
# can touch a login dialog" is NOT established and is not claimed here. What
# follows from what was checked is the thing that matters for this module: the
# threshold and the notification below are a FIRST-of-kind action, not a
# refinement of an existing one, which is why both are operator-visible and why
# the threshold is the operator's own number rather than one we picked.
#
# Operator report, verbatim (2026-09-12):
#
#   > when I am currently trying to login to the orchestrator, this should not
#   > be interrupted by pasting emits from the watcher. Unless stale for ~1h
#   > then the watcher should escape out of the login screen to paste its emit
#
# Measured cost of the two halves together, 2026-09-11 14:30 → 09-12 01:40: the
# orchestrator was logged out, the operator's `/login` was interrupted, and the
# board produced NOTHING for 11 h. Worker `w236` sat parked 3 h on a skeptic
# whose escalations reached nobody.
#
# ============================================================================
# WHY THIS IS `_over_limit.sh`'S HOLD WITH A DIFFERENT SENSOR
# ============================================================================
#
# The hold is wired as a THIRD ARM in the existing `if/elif` ladder beside
# `_over_limit_orchestrator_paused`, and that placement is the design rather
# than a convenience. "Queued, never dropped" is a property of where the arm
# SITS: by landing in that ladder the hold inherits, by construction,
#
#   * the archive write, which happens unconditionally ABOVE the ladder, so the
#     body survives on disk whatever the ladder decides;
#   * skipping `_emit_delivery_ok` — the delivery clock does not advance, so a
#     held emit cannot look delivered to the failure counters;
#   * skipping `_compose_emit_record_emit` — the dedup anchor is not moved, so
#     the SAME body re-composes next cycle instead of being deduped against
#     itself. This is the whole re-delivery mechanism and it needs no queue of
#     its own;
#   * skipping `requests_commit_emitted` — request ids stay DUE (`#483`);
#   * skipping `_oneshot_commit` — one-shot markers stay unconsumed (`#568` A2).
#
# Re-inventing any of those five would be five new chances to drop an emit. A
# hold implemented anywhere else in `main.sh` has to get all five right; a hold
# in that ladder cannot get them wrong. It is also why the escape below does
# NOT paste inline: it sends `Escape`, clears the row, and lets the NEXT cycle
# paste through the already-exercised path. Exactly once, by the same mechanism
# that made over-limit resumption exactly once.
#
# ============================================================================
# TWO SURFACES, TWO DIFFERENT REMEDIES — `auth=login` HOLDS, `auth=expired` DOES NOT
# ============================================================================
#
# The obvious design is "one login detector, one hold". It is wrong, and both
# its error directions are expensive. The surfaces differ in what the DAMAGE is:
#
#   auth=login    A `/login` dialog is UP. A paste's Enter answers it. HOLD the
#                 emit; escape out after `escape_after_seconds`.
#
#   auth=expired  The session is logged out and idle. A paste here is HARMLESS —
#                 the text lands in the input box, or is submitted and errors
#                 again — and the operator NEEDS the board state waiting for
#                 them when they log back in. What `#1517` actually cost was the
#                 RESUBMIT STORM and ten false `recovered` lines: remedies that
#                 cannot work, reported as working. So this surface suppresses
#                 the LIVENESS remedies and notifies, and does not hold.
#
# Keeping them apart is what makes each detector's errors cheap. On the expired
# axis a MISS is `#1517` again and an OVER-FIRE costs one redundant notification
# plus a liveness remedy declined for a cycle — not a silenced board.
#
# ============================================================================
# ACTIVE vs ABANDONED, AND WHY THE CEILING IS NOT NEGOTIABLE
# ============================================================================
#
# The operator asked for two things that pull in opposite directions: do not
# interrupt a login in progress, and do not let a login silence the board for
# ever. Both are honoured, by THREE clocks, and the evidence for each is stated
# because inventing an unmeasurable signal here is how a hold becomes permanent.
#
#   escape_after_seconds (3600, the operator's own number)
#       Aged from `first_seen` — when the emit was FIRST held — never from the
#       last retry or the last observation. A watcher that re-probes every ~50 s
#       must not be able to push its own deadline away.
#
#   active_grace_seconds (300)
#       EVIDENCE: `pane-state.sh` already emits `content_hash` on every line, a
#       digest of the transcript region. An operator driving a login CHANGES the
#       pane — the menu cursor moves, a code is typed. A hash change inside the
#       grace defers the escape by one grace period at a time. This is a real
#       measurement, not an inferred keystroke channel; what it CANNOT tell is
#       the difference between the operator typing and the TUI animating, which
#       is why it may only DEFER and never CANCEL.
#
#   max_hold_seconds (7200) — the ABSOLUTE ceiling, and it FAILS OPEN.
#       Past it the hold releases whatever the pane says. Mirrors
#       `monitor.over_limit.max_hold_seconds`, and for the same reason: an
#       unbounded hold is `#1517` rebuilt with a different sensor — the board
#       silent, the watcher logging its own diligence into a file no human
#       reads. A deferral that never lapses is indistinguishable from a
#       dropped emit, so the deferral is given a lapse it cannot outlive.
#
# The polarity of every refusal here is therefore the opposite of the kill-gate
# doctrine elsewhere in this repo, and deliberately so. There, "I could not
# tell" must REFUSE, because the irreversible act is the kill. Here the
# irreversible act is HOLDING — an emit nobody reads is a board that stops —
# so "I could not tell" must RELEASE. `_auth_hold_active` returns non-zero on
# every form of not-knowing: knob off, no row, unparseable row, stale
# observation, past the ceiling.
#
# ============================================================================
# INJECTION CONTRACTS (mirroring _over_limit.sh)
# ============================================================================
#
#   _AUTH_HOLD_LOG_FN    a function taking one message; defaults to a no-op so
#                        the module is sourceable by a test with no watcher.
#   _AUTH_HOLD_ALERT_FN  a function taking one message, routed by main.sh to
#                        `_watcher_alert` (alerts log + watcher log +
#                        sandbox-notify). Defaults to a no-op.
#
# No paster is injected: this module never pastes. It sends ONE keystroke
# (`Escape`) and hands delivery back to `main.sh`.

_auth_hold_log_noop() { :; }
_auth_hold_alert_noop() { :; }
_AUTH_HOLD_LOG_FN="${_AUTH_HOLD_LOG_FN:-_auth_hold_log_noop}"
_AUTH_HOLD_ALERT_FN="${_AUTH_HOLD_ALERT_FN:-_auth_hold_alert_noop}"

# ---- state substrate ------------------------------------------------------
#
# ONE row, one file. `<kind>\t<first_seen>\t<last_observed>\t<hash>\t<hash_changed>`
#
# A single-row file rather than a column added to an existing state file, for
# the `#1050` reason: a value written into a field something else MATCHES on is
# a behavioural change, not a label. Nothing reads over-limit's rows looking for
# a `kind`, and nothing should have to learn to skip an auth row.

_auth_hold_state_path() {
    printf '%s/auth-hold.tsv' "${STATE_DIR:-.}"
}

_auth_hold_held_log_path() {
    printf '%s/auth-hold-held.log' "${STATE_DIR:-.}"
}

_auth_hold_alert_stamp_path() {
    printf '%s/auth-hold-alert.stamp' "${STATE_DIR:-.}"
}

# ---- knobs ---------------------------------------------------------------
#
# Read through `${VAR:-default}` with a shape check on every one, so a
# mistyped config value degrades to the documented default rather than to
# arithmetic on a string. Each is a value WE CHOSE, not a vendor default, and
# is labelled as such per the workspace rule on chosen parameters.

_auth_hold_enabled() {
    # The OFF switch. `false`/`0`/`no` all disable. When disabled, every
    # predicate in this file answers "not holding" and `main.sh`'s ladder is
    # byte-for-byte the pre-#1518 ladder.
    local v="${MONITOR_AUTH_HOLD_ENABLED:-true}"
    case "$v" in
        false|0|no|off|FALSE|NO|OFF) return 1 ;;
    esac
    return 0
}

_auth_hold_int() {   # <value> <default>
    local v="$1" d="$2"
    [[ "$v" =~ ^[0-9]+$ ]] || v="$d"
    printf '%s' "$v"
}

_auth_hold_escape_after() {
    _auth_hold_int "${MONITOR_AUTH_HOLD_ESCAPE_AFTER_SECONDS:-3600}" 3600
}
_auth_hold_active_grace() {
    _auth_hold_int "${MONITOR_AUTH_HOLD_ACTIVE_GRACE_SECONDS:-300}" 300
}
_auth_hold_max_hold() {
    _auth_hold_int "${MONITOR_AUTH_HOLD_MAX_HOLD_SECONDS:-7200}" 7200
}
_auth_hold_staleness() {
    _auth_hold_int "${MONITOR_AUTH_HOLD_OBSERVATION_STALENESS_SECONDS:-600}" 600
}

# Name -> window index, through the PUBLIC resolver in `monitor/_tmux-window.sh`
# (`main.sh` already sources it) and through nothing else.
#
# The first cut preferred `_over_limit_resolve_window_index`, reaching into
# another module's PRIVATE helper — the leading underscore is the convention
# saying not to. Besides the coupling, it had a measured side effect worth
# recording: `monitor/watcher/undefined-helper-lint.sh` tracks the set of call
# sites it DECLINES to judge, pinned as data in `uhl-unknown-callsites.manifest`,
# and adding a second caller of that private name pushed an existing,
# previously-judged call site in `test-tmux-window-resolver.sh` into the unjudged
# bucket — base 1 row, with the dependency 2. So a coupling choice here SHRANK
# lint coverage somewhere else, silently, and the manifest is what made it
# visible. Depending only on the public resolver restores the base set exactly.
#
# Prints nothing and returns non-zero when the index cannot be determined; the
# callers then degrade to the NAME, which costs a fork and never turns the hold
# off.
_auth_hold_window_index() {
    local name="$1"
    declare -F resolve_window_index >/dev/null 2>&1 || return 1
    resolve_window_index "$name" 2>/dev/null || return 1
}

# ---- probe ---------------------------------------------------------------
#
# Prints `<state> <auth> <content_hash>`; rc 1 when the pane could not be read
# at all. Routed through the shared `_pane_cache` chokepoint (`#562`) exactly as
# `_over_limit_probe_pane` is, so a cycle that has already classified the
# orchestrator does not fork `pane-state.sh` a second time.
#
# `auth` EMPTY is the answer for both "no login surface" and "this pane-state
# predates the field". Both must release the hold, and they do — see the
# polarity note in the header. An OLD `pane-state.sh` therefore cannot hold the
# board; it can only fail to protect a login, which is the pre-#1518 status quo.
_auth_hold_probe() {
    local window_arg="$1" expected_name="${2:-}"
    local line state auth hash
    if declare -F _pane_cache_read >/dev/null 2>&1; then
        line=$(_pane_cache_read "$window_arg" "$expected_name") || line=""
    else
        line=""
    fi
    if [[ -z "$line" ]]; then
        local pane_state_script
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/pane-state.sh" ]]; then
            pane_state_script="$NEXUS_ROOT/monitor/pane-state.sh"
        elif [[ -x "$(dirname "${BASH_SOURCE[0]}")/../pane-state.sh" ]]; then
            pane_state_script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pane-state.sh
        else
            return 1
        fi
        local hb_args=()
        if [[ -n "${MONITOR_HEARTBEAT_STALENESS_SECONDS:-}" ]] \
            && [[ "$MONITOR_HEARTBEAT_STALENESS_SECONDS" =~ ^[0-9]+$ ]]; then
            hb_args+=(--heartbeat-staleness "$MONITOR_HEARTBEAT_STALENESS_SECONDS")
        fi
        line=$("$pane_state_script" "${hb_args[@]}" "$window_arg" 2>/dev/null) || return 1
        if [[ -n "$line" ]] && declare -F _pane_cache_write >/dev/null 2>&1; then
            _pane_cache_write "$window_arg" "$line"
        fi
    fi
    [[ -n "$line" ]] || return 1
    state=$(printf '%s' "$line" | sed -n 's/.*state=\([a-z-]*\).*/\1/p')
    auth=$(printf '%s' "$line" | sed -n 's/.*[ ]auth=\([a-z-]*\).*/\1/p')
    hash=$(printf '%s' "$line" | sed -n 's/.*content_hash=\([0-9]*\).*/\1/p')
    [[ -n "$state" ]] || return 1
    printf '%s %s %s' "$state" "${auth:-none}" "${hash:-0}"
}

# ---- observe -------------------------------------------------------------
#
# Called once per watcher cycle, BEFORE the emit ladder. Creates, refreshes or
# clears the row. Returns 0 always: an observation failure must not fail the
# cycle, and a failure to observe is NOT evidence of a login (the row simply
# goes stale and the hold releases on its own).
#
# THE LOGIN VERDICT REQUIRES BOTH HALVES: `auth=login` AND a `state=` the
# paste would actually be answered by. `blocked` is that state — the dialog has
# replaced the REPL, so the Enter has nowhere else to go. Requiring the pair is
# what stops a pane merely QUOTING a login frame (an agent reading #1518, say)
# from holding the board: such a pane still has its own `❯` input row below the
# quote and classifies `idle`/`user-typing`, never `blocked`. That is the same
# structural live-vs-quoted discriminator `_has_bypass_permissions_modal`
# documents, reused rather than re-derived.
_auth_hold_observe() {
    local target="${1:?target window required}"
    local path probe state auth hash now row kind first last_hash last_change
    _auth_hold_enabled || { _auth_hold_clear_all; return 0; }
    path=$(_auth_hold_state_path)
    now=$(date +%s)
    # RESOLVE THE NAME TO AN INDEX FIRST, and the reason is the shared cache,
    # not tmux (`pane-state.sh` has accepted a NAME since `#905`). The `#562`
    # pane-cache is keyed on the probe TARGET STRING, and the authoritative
    # recorder writes it keyed on `$window_index`
    # (`_idle_probe.sh:864: _pane_cache_write "$window_index"`). A name-keyed
    # read therefore MISSES every time, which at this task's 5 s cadence means
    # forking `pane-state.sh` twelve times a minute on the watcher's hot path —
    # and silently defeating the cache `#562` exists to provide. Passing
    # (index, name) hits it, exactly as `_over_limit_scan_panes` does for this
    # same pane; `expected_name` is the window-index-reuse guard.
    #
    # Failure to resolve degrades to the NAME, which is correct rather than
    # merely tolerable: the probe still works, it just forks. The alternative —
    # refusing to observe — would mean a tmux hiccup silently turns the hold OFF.
    local _ah_key="$target" _ah_idx=""
    _ah_idx=$(_auth_hold_window_index "$target")
    [[ "$_ah_idx" =~ ^[0-9]+$ ]] && _ah_key="$_ah_idx"
    probe=$(_auth_hold_probe "$_ah_key" "$target") || {
        # Could not read the pane. Leave any existing row alone so it ages out
        # through the staleness window rather than being cleared (a transient
        # tmux hiccup must not re-open the paste) and, equally, do not CREATE
        # one (not knowing is not evidence of a login).
        "$_AUTH_HOLD_LOG_FN" "auth-hold: could not read pane-state for '${target}'; leaving any existing hold row to age out (staleness=$(_auth_hold_staleness)s)"
        return 0
    }
    read -r state auth hash <<<"$probe"
    # Record/clear the EXPIRY row on every cycle, independently of the dialog
    # hold: an expired login needs no dialog on screen, and the hold's own row
    # only exists while one is. F3.
    _auth_hold_expiry_observe "$auth" "$now"

    # ════════════════════════════════════════════════════════════════════════
    # THE GATE IS `state=blocked`, STRUCTURALLY — NOT `auth=login`
    # (skeptic w237sk F1; your-org/nexus-code#1518)
    # ════════════════════════════════════════════════════════════════════════
    #
    # THIS LINE IS THE WHOLE SAFETY PROPERTY, AND THE FIRST CUT GOT IT WRONG IN
    # THE MOST EXPENSIVE WAY AVAILABLE: it required `auth == login` AND
    # `state == blocked`, while three documents — this header, the report, and
    # `skills/nexus.cc-update/GUIDE.md`, the one file whose entire job is
    # catching vendor-string rot — all promised that a reword of the three login
    # strings would cost only the LABEL and never the HOLD. It cost the hold.
    # Verified by construction: rewrite `Login` and `Select login method:` in the
    # committed capture and `pane-state.sh` still says `state=blocked
    # overlay=dialog`, `auth=` is ABSENT, the `&&` is false, the row is CLEARED,
    # `_auth_hold_active` returns 1, and the ladder reaches `paste_with_retry`.
    #
    # So the gate is the STRUCTURE: any select dialog. Three reasons, and the
    # second is the one that makes this more correct rather than merely safer:
    #
    #   (1) It is what all three documents already promise. The alternative was
    #       retracting a safety claim in three places.
    #   (2) **PASTING INTO ANY DIALOG IS THE HAZARD — not pasting into a login
    #       dialog specifically.** The trailing `Enter` is the CONFIRM whatever
    #       the frame is asking, which is exactly `#1200`'s finding, and
    #       `paste-followup.sh:889` has refused `state=blocked` generically ever
    #       since. Keying on `login` was a narrower gate than the hazard.
    #   (3) A vendor reword now costs the `auth=` ANNOTATION — the log line and
    #       the `sandbox-notify` wording — and not the protection. That is the
    #       fail-safe direction, and it is now a property of the code rather than
    #       a claim about it.
    #
    # IT ALSO CLOSES F4's LATENT HAZARD as a side effect worth stating: `auth=`
    # is set only on `pane-state.sh`'s RENDERER path (the `_has_blocked_overlay`
    # arm), so the heartbeat route never produced `auth=login` at all. `state=`
    # is produced by BOTH routes — `permission_prompt` classifies `blocked` from
    # the heartbeat — so a structural gate holds on either. The day
    # `#1520` gives the orchestrator a `worker-heartbeat.sh` writer, this hold
    # keeps working; keyed on `auth=login` it would have gone inert for up to
    # 1800 s after every turn end, with every watcher paste refreshing the clock.
    #
    # `auth=` is still READ, and recorded on the row — as the DIAGNOSIS, for the
    # log and the notification. Never as the gate.
    # A DISJUNCTION, and each half covers the other's measured blind spot. This
    # is the F1 + F2 fix together; neither half alone is sufficient:
    #
    #   state=blocked   STRUCTURAL. Survives a vendor reword of every login
    #                   string — the F1 property, and the one three documents
    #                   promise. Covers the method menus.
    #                   BLIND SPOT: the browser-auth / code-paste step is NOT a
    #                   multi-option menu, so `_has_menu_dialog_frame` declines
    #                   and it classifies `state=empty` on the live pane
    #                   (measured, 2.1.268). `empty` can never join this arm —
    #                   it means "don't know yet" and is the commonest
    #                   mid-render reading, so holding on it would mute the
    #                   board constantly.
    #
    #   auth=login      LABELLED. Reaches the code-paste step, which is the
    #                   screen where a stray paste is WORST: the emit body lands
    #                   in the auth-code field and the trailing Enter SUBMITS it,
    #                   failing the login outright. The F2 property.
    #                   BLIND SPOT: it is string-keyed, so a vendor reword drops
    #                   it — which is exactly what the `blocked` arm is for.
    #
    # So the two blind spots are disjoint and each arm is the other's backstop.
    # Stated plainly because the tempting simplification — pick one — was the
    # first cut's error in one direction (F1) and would be its mirror in the
    # other (F2).
    #
    # ORDER IS IMMATERIAL HERE and that is worth one line, because `#1121` is
    # about arm order: both arms are SAFE-side (they hold), there is no DENY arm
    # below them, and the `if` has no permissive early return. A SAFE arm
    # preceding a DENY arm is the hazard; this is two SAFE arms and a default of
    # "do not hold".
    kind=""
    if [[ "$state" == "blocked" ]] || [[ "$auth" == "login" ]]; then
        kind=dialog
    fi

    if [[ -z "$kind" ]]; then
        if [[ -f "$path" ]]; then
            "$_AUTH_HOLD_LOG_FN" "auth-hold: RELEASED — '${target}' no longer shows a dialog (state=${state} auth=${auth:-none}); held emits re-compose and paste on this cycle"
            _auth_hold_clear
        fi
        return 0
    fi

    # `auth=` is the DIAGNOSIS carried alongside, never the gate (F1). `none`
    # when the pane shows a dialog whose login strings did not match — which is
    # precisely the reworded case, and the hold engages anyway.
    local label="${auth:-none}"
    if [[ -f "$path" ]]; then
        IFS=$'\t' read -r _ first _ last_hash last_change _ < "$path" 2>/dev/null
        [[ "$first" =~ ^[0-9]+$ ]] || first="$now"
        [[ "$last_change" =~ ^[0-9]+$ ]] || last_change="$now"
        if [[ "$hash" != "$last_hash" ]]; then
            last_change="$now"
        fi
    else
        first="$now"
        last_change="$now"
        # WHICH ARM FIRED, AND WHAT THAT COSTS IF ITS KEY ROTS (skeptic w237sk
        # D1). This line used to assert, byte-identically in BOTH arms, *"the
        # hold keys on state=blocked, NOT on auth, so a vendor reword costs this
        # label and not the hold."* On the code-paste screen that is false in
        # both clauses — `state` is not `blocked` there, the hold fired via the
        # LABEL, and a reword WOULD cost the hold. w237sk confirmed it by
        # construction: with all four disjuncts reworded, that capture is not
        # held.
        #
        # THIS IS ROUND-1 F1's SHAPE ONE LEVEL DOWN — a claim about the gate that
        # the gate contradicts — and F1 is how a false safety claim reached three
        # documents. A diagnostic is read by whoever is deciding whether to trust
        # the mechanism, so a reassuring sentence in it is not cosmetic.
        #
        # The honest statement is about the SET of screens, not any individual
        # one: the menus have two backstops, the code-paste screen has one and it
        # is textual. So the line names the arm and states that arm's own
        # exposure.
        local _why
        if [[ "$state" == "blocked" && "$label" == "login" ]]; then
            _why="BOTH arms hold this frame (state=blocked AND auth=login), so a vendor reword of the login strings would cost the label and not the hold"
        elif [[ "$state" == "blocked" ]]; then
            _why="the STRUCTURAL arm holds it (state=blocked); auth=${label} did not fire, so the login strings are irrelevant here and a reword cannot reach this hold"
        else
            _why="ONLY the LABELLED arm holds it (auth=${label}; state=${state} is not blocked, so the structural arm does not apply) — this frame has no structural backstop, and a vendor reword of the login strings WOULD drop this hold. That is the browser-auth/code-paste case (your-org/nexus-code#1518 F2/D1)"
        fi
        "$_AUTH_HOLD_LOG_FN" "auth-hold: ENGAGED — '${target}' is sitting on a DIALOG (state=${state} auth=${label} content_hash=${hash}); emits are archived and held, NOT pasted: the paste's trailing Enter is the dialog's CONFIRM and would answer it — selecting a login method on a /login frame, or whatever default is highlighted on any other (your-org/nexus-code#1518, #1200). ${_why}. Escaping out after $(_auth_hold_escape_after)s idle, ceiling $(_auth_hold_max_hold)s."
        _auth_hold_announce "$now" "$hash" "$label"
    fi
    # `last_observed` is stamped `now`, and via the `#562` cache the reading can
    # be up to `monitor.pane_cache.ttl_seconds` (default 90) old — so freshness
    # is OVERSTATED by at most that TTL. Stated rather than corrected: the
    # staleness window it feeds is 600 s, so a 90 s overstatement cannot reach
    # it, and the cache CANNOT serve anything older (a past-TTL entry is a miss
    # and forces a fork). The direction also favours release over hold: an
    # overstated `last_observed` can only keep a hold alive while the dialog is
    # genuinely there, never resurrect one after it is gone, because a cleared
    # dialog takes the `kind` arm above and deletes the row outright.
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' dialog "$first" "$now" "$hash" "$last_change" "$label" \
        > "$path" 2>/dev/null || true
    return 0
}

_auth_hold_clear() {
    rm -f "$(_auth_hold_state_path)" "$(_auth_hold_alert_stamp_path)" 2>/dev/null || true
}

# Everything this module records, for the knob-off path. The expiry row is
# SEPARATE from the hold row (F3) and must be cleared with it, or turning the
# knob off would leave liveness suppressed by a row nothing refreshes.
_auth_hold_clear_all() {
    _auth_hold_clear
    rm -f "$(_auth_hold_expiry_path)" 2>/dev/null || true
}

# ---- the gate ------------------------------------------------------------
#
# rc 0 → HOLD this emit. rc 1 → do not hold, for ANY reason including every
# form of not-knowing. See the polarity note in the header: here the
# irreversible act is holding, so not-knowing releases.
_auth_hold_active() {
    local path row kind first last now
    _auth_hold_enabled || return 1
    path=$(_auth_hold_state_path)
    [[ -f "$path" ]] || return 1
    IFS=$'\t' read -r kind first last _ _ _ < "$path" 2>/dev/null || return 1
    # ONE legal kind, compared by EQUALITY. `dialog` since F1 — the structural
    # gate. Equality rather than a glob deliberately: `#1121`'s arm-ordering
    # lesson is that a pattern arm is where a "no input matches two arms" claim
    # quietly becomes false, and this predicate's wrong answer mutes the board.
    [[ "$kind" == "dialog" ]] || return 1
    [[ "$first" =~ ^[0-9]+$ ]] || return 1
    [[ "$last"  =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s)
    # Stale observation → release. The row is only as good as the last cycle
    # that actually saw the dialog; a watcher that stopped observing must not
    # keep the channel shut on a memory.
    (( now - last <= $(_auth_hold_staleness) )) || return 1
    # Absolute ceiling → release, whatever the pane says.
    (( now - first < $(_auth_hold_max_hold) )) || return 1
    return 0
}

# `auth=expired` on a FRESH observation — the liveness gate (#1517).
#
# Deliberately NOT derived from the hold row: the hold row exists only for
# `login`, and expiry must be answerable while no hold is active at all. Reads
# the pane through the same cached chokepoint.
# your-org/nexus-code#1518, skeptic w237sk F3 — THIS ARM HAS A CEILING NOW.
#
# It did not, and the module's own header promised otherwise: *"an unbounded hold
# is `#1517` rebuilt with a different sensor"* and *"every form of not-knowing
# RELEASES"*. Both were applied to the emit hold and NEITHER to this gate, which
# suppresses the RESPAWN. Unbounded, the failure case is a WEDGED-BUT-PRESENT
# orchestrator: the pane is frozen, so the very text that suppresses the remedy
# can never scroll out, and `_bottom_rows 15` cannot help — it bounds ROWS, not
# TIME. Liveness would report `healthy reason=auth-expired`, with no resubmit and
# no respawn, FOREVER. That is `#1517`'s own shape one layer over, and `healthy`
# in the log is the part that makes it expensive.
#
# So the expiry gets its own `first_seen`, written by `_auth_hold_observe` on the
# same 5 s cadence, and this arm FAILS OPEN past `max_hold_seconds` — exactly as
# the emit hold does. Past the ceiling liveness resumes its ordinary remedies: a
# resubmit and then a respawn still cannot fix an expired credential, but a
# watcher that has told the operator for two hours and been ignored is better
# off behaving normally than silently vouching for a frozen agent.
#
# A dead PANE was always caught independently (the `target_window` absent /
# dead-pane respawn path), so the exposure this closes is specifically
# live-pane-with-wedged-agent.
_auth_hold_expiry_path() {
    printf '%s/auth-expired.tsv' "${STATE_DIR:-.}"
}

# Record or clear the expiry row. Called from `_auth_hold_observe`, which already
# holds a fresh probe — so this costs no extra pane read.
_auth_hold_expiry_observe() {
    local auth="$1" now="$2" path first
    path=$(_auth_hold_expiry_path)
    if [[ "$auth" != "expired" ]]; then
        if [[ -f "$path" ]]; then
            "$_AUTH_HOLD_LOG_FN" "auth-hold: expiry CLEARED — the orchestrator no longer reports a logged-out session; orchestrator-liveness resumes its ordinary remedies"
            rm -f "$path" 2>/dev/null || true
        fi
        return 0
    fi
    if [[ -f "$path" ]]; then
        IFS=$'\t' read -r first _ < "$path" 2>/dev/null
        [[ "$first" =~ ^[0-9]+$ ]] || first="$now"
    else
        first="$now"
        "$_AUTH_HOLD_LOG_FN" "auth-hold: EXPIRY observed — the orchestrator reports a logged-out session (auth=expired). orchestrator-liveness will file NO resubmit and NO respawn while this stands, because neither can fix an expired credential (your-org/nexus-code#1517). Bounded: past $(_auth_hold_max_hold)s this FAILS OPEN and the ordinary remedies resume, so a wedged agent cannot be vouched for indefinitely."
    fi
    printf '%s\t%s\n' "$first" "$now" > "$path" 2>/dev/null || true
}

_auth_hold_auth_expired() {
    local target="${1:?target window required}" probe state auth
    _auth_hold_enabled || return 1
    # THE CEILING, read from the recorded row rather than from a live probe, so
    # the bound is on TIME and not on what the pane happens to render now.
    local _ex_path _ex_first _ex_last _ex_now
    _ex_path=$(_auth_hold_expiry_path)
    if [[ -f "$_ex_path" ]]; then
        IFS=$'\t' read -r _ex_first _ex_last < "$_ex_path" 2>/dev/null
        _ex_now=$(date +%s)
        if [[ "$_ex_first" =~ ^[0-9]+$ ]] && (( _ex_now - _ex_first >= $(_auth_hold_max_hold) )); then
            "$_AUTH_HOLD_LOG_FN" "auth-hold: expiry ceiling REACHED after $(( _ex_now - _ex_first ))s (max_hold=$(_auth_hold_max_hold)s) — FAILING OPEN. orchestrator-liveness resumes resubmit/respawn. Neither fixes an expired credential, so if the board is still silent the answer is still a human /login; what this prevents is vouching for a WEDGED agent indefinitely (your-org/nexus-code#1518 F3)."
            return 1
        fi
        # A stale row releases too, same reason as the hold's staleness window:
        # the row is only as good as the last cycle that actually looked.
        if [[ "$_ex_last" =~ ^[0-9]+$ ]] \
            && (( _ex_now - _ex_last > $(_auth_hold_staleness) )); then
            return 1
        fi
    fi
    # Index-keyed for the cache, same reason as `_auth_hold_observe` — this one
    # is consulted by `orchestrator-liveness` every 5 s, so an un-cached read
    # here would double the forks the note there is about.
    local _ah_key="$target" _ah_idx=""
    _ah_idx=$(_auth_hold_window_index "$target")
    [[ "$_ah_idx" =~ ^[0-9]+$ ]] && _ah_key="$_ah_idx"
    probe=$(_auth_hold_probe "$_ah_key" "$target") || return 1
    read -r state auth _ <<<"$probe"
    [[ "$auth" == "expired" || "$auth" == "login" ]]
}

# ---- the held-emit ledger ------------------------------------------------
#
# Mirrors `_over_limit_record_held`: a hold that mutes the operator's channel
# must leave a record a human can read, because `#592` measured a 15-hour
# blackout pass unnoticed while the watcher logged its own suppression once per
# cycle into `watcher.log`.
_auth_hold_record_held() {
    local archive="$1" reason="$2" path ts
    path=$(_auth_hold_held_log_path)
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    ts=$(date -Is 2>/dev/null || date 2>/dev/null || printf '?')
    printf '%s\theld\tarchive=%s\treason=%s\n' "$ts" "$archive" "$reason" \
        >> "$path" 2>/dev/null || true
}

# ONE announcement per hold (#976's measured lesson: a 5 h over-limit hold used
# to fire 20 critical bells, which is exactly how an operator learns to ignore
# the bell). The stamp file is written here and removed by `_auth_hold_clear`,
# so a new hold announces again and a continuing one does not.
_auth_hold_announce() {
    local now="$1" hash="$2" label="${3:-none}" stamp what
    stamp=$(_auth_hold_alert_stamp_path)
    [[ -f "$stamp" ]] && return 0
    printf '%s' "$now" > "$stamp" 2>/dev/null || true
    # The WORDING branches on the `auth=` label; the HOLD did not (F1). Say
    # which it is so the operator is not sent to the wrong screen — and when the
    # label is absent, say THAT rather than guessing "login", because a reworded
    # login frame and an unrelated dialog are indistinguishable from here.
    case "$label" in
        login)   what="a /login dialog is open on the orchestrator" ;;
        expired) what="the orchestrator is logged out AND a dialog is open" ;;
        *)       what="a dialog is open on the orchestrator (its kind is not one this watcher names — possibly a reworded /login frame)" ;;
    esac
    "$_AUTH_HOLD_ALERT_FN" \
        "${what} — emits are HELD, not pasted. A paste's trailing Enter is the dialog's CONFIRM and would answer it, selecting whatever is highlighted (your-org/nexus-code#1518, #1200). Answer or cancel the dialog and the board resumes on the next cycle; if it is left untouched the watcher sends Escape after $(_auth_hold_escape_after)s and pastes anyway (hard ceiling $(_auth_hold_max_hold)s). Held emits are archived: $(_auth_hold_held_log_path)."
}

# ---- escape --------------------------------------------------------------
#
# rc 0 → the escape is DUE. Two conditions, both required:
#
#   (1) the hold is older than `escape_after_seconds`, aged from `first_seen`;
#   (2) the pane has not CHANGED within `active_grace_seconds` — the
#       actively-driven-login deferral. Bounded by the ceiling in
#       `_auth_hold_active`, which releases the hold entirely, so this
#       deferral cannot compound into a permanent one.
_auth_hold_escape_due() {
    local path kind first last hash change now
    _auth_hold_active || return 1
    path=$(_auth_hold_state_path)
    IFS=$'\t' read -r kind first last hash change _ < "$path" 2>/dev/null || return 1
    [[ "$first"  =~ ^[0-9]+$ ]] || return 1
    [[ "$change" =~ ^[0-9]+$ ]] || change="$first"
    now=$(date +%s)
    (( now - first >= $(_auth_hold_escape_after) )) || return 1
    (( now - change >= $(_auth_hold_active_grace) )) || return 1
    return 0
}

# Send `Escape` to leave the login screen, then clear the row so the NEXT
# cycle's ladder pastes through the ordinary, already-exercised path. Does not
# paste: see the header on why exactly-once is a property of not re-inventing
# delivery.
#
# THE `#745` DEAD-PANE GUARD PRECEDES THE KEYSTROKE, and the refusal is
# UNCONDITIONAL while only the WORDING branches — the `#1020` shape. `rc 0`
# from `_tmux_pane_is_dead` means dead OR could-not-tell, and calling the
# second a corpse is a positive verdict from zero evidence. Either way we do
# not write to the pane: a send into a `remain-on-exit` corpse is measured to
# kill the tmux SERVER, taking the watcher and every worker with it, and a
# corpse sitting on a login dialog needs a respawn, not a keystroke.
_auth_hold_escape() {
    local target="${1:?target window required}" tgt
    if ! declare -F _tmux_pane_is_dead >/dev/null 2>&1; then
        "$_AUTH_HOLD_LOG_FN" "auth-hold: REFUSING to send Escape to '${target}' — _pane-live.sh is unavailable, so the #745 dead-pane guard cannot run. A guard that did not run is not a pass; the hold stays until its ceiling releases it."
        return 1
    fi
    if _tmux_pane_is_dead "$target"; then
        if [[ "${NEXUS_PANE_LIVE_VERDICT:-}" == "dead" ]]; then
            "$_AUTH_HOLD_LOG_FN" "auth-hold: REFUSING to send Escape to '${target}' — it is a DEAD pane (remain-on-exit corpse); a write into one kills the tmux server (your-org/nexus-code#745). It needs a respawn, not a keystroke."
        else
            "$_AUTH_HOLD_LOG_FN" "auth-hold: REFUSING to send Escape to '${target}' — could not establish that it is a live pane (verdict='${NEXUS_PANE_LIVE_VERDICT:-unset}'); your-org/nexus-code#745. NOT a corpse diagnosis: nobody looked successfully, and the refusal is retryable."
        fi
        return 1
    fi
    # Read the age BEFORE the keystroke, and BEFORE `_auth_hold_clear` removes
    # the row it comes from. `$?` discipline one axis over: a value computed
    # from state that a later line deletes is a value you cannot compute later.
    local held_first held_for
    held_first=$(cut -f2 "$(_auth_hold_state_path)" 2>/dev/null) || held_first=""
    [[ "$held_first" =~ ^[0-9]+$ ]] || held_first=0
    if (( held_first > 0 )); then
        held_for=$(( $(date +%s) - held_first ))
    else
        held_for=-1
    fi
    tgt=$(resolve_window_id "$target" 2>/dev/null || true); tgt="${tgt:-$target}"
    if ! tmux send-keys -t "$tgt" Escape 2>/dev/null; then
        "$_AUTH_HOLD_LOG_FN" "auth-hold: Escape to '${target}' FAILED (tmux send-keys error); hold stands, ceiling $(_auth_hold_max_hold)s will release it"
        return 1
    fi
    "$_AUTH_HOLD_LOG_FN" "auth-hold: ESCAPED — sent Escape to '${target}' after ${held_for}s held (aged from first_seen, not from the last retry) with no pane change for $(_auth_hold_active_grace)s+; the login reads ABANDONED, which is the operator's standing instruction to break out (your-org/nexus-code#1518). Held emits paste on the next cycle."
    "$_AUTH_HOLD_ALERT_FN" \
        "login hold EXPIRED on the orchestrator: the /login dialog had been untouched for over $(_auth_hold_escape_after)s, so the watcher sent Escape and is resuming emits. If you still need to log in, run /login again — the board was silent until now."
    _auth_hold_clear
    return 0
}

# One call for main.sh's cycle: observe, then escape if due. Returns 0 always.
_auth_hold_step() {
    local target="${1:?target window required}"
    _auth_hold_enabled || return 0
    _auth_hold_observe "$target"
    if _auth_hold_escape_due; then
        _auth_hold_escape "$target" || true
    fi
    return 0
}
