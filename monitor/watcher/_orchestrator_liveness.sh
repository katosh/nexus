#!/usr/bin/env bash
# Orchestrator-liveness state machine (issue #164).
#
# Replaces the binary `unresponsive_age > threshold` check inherited
# from issue #157 (paste-driven liveness, PR #159). That check
# conflated "orchestrator stuck" with "orchestrator idle but
# healthy" — three issues filed in rapid succession on 2026-05-21
# tripped the 120 s threshold while the orchestrator was simply
# waiting on a user-side go signal, causing a wasted restart cycle.
#
# The model uses three independent signals from the orchestrator
# side plus one trigger from the watcher side:
#
#   1. **Heartbeat** — `monitor/.state/orchestrator-heartbeat`.
#      `touch`ed by a `Stop` hook in
#      `monitor/orchestrator-settings.json` at every turn-end. The
#      file's mtime tracks "the orchestrator finished a turn at
#      this moment." Strongest evidence of liveness.
#
#   2. **Paste-received** — `monitor/.state/orchestrator-paste-received`.
#      `touch`ed by a `UserPromptSubmit` hook on every paste-receipt
#      (the orchestrator's input queue picked up the watcher's
#      paste). Fresher than the heartbeat during a long tool turn —
#      the orchestrator received the paste but Stop hasn't fired yet
#      because the turn is still cooking. Without this signal a
#      multi-step tool turn looks identical to a wedge from the
#      watcher's vantage point. Both touches run asynchronously via
#      `(... &) >/dev/null 2>&1` so the hook returns instantly —
#      see `monitor/orchestrator-settings.json` for the exact
#      backgrounded form.
#
#   3. **Pinned-session jsonl mtime** — backward-compat fallback for
#      sessions whose `orchestrator-settings.json` predates the
#      hooks (the install only takes effect on next spawn). Fragile:
#      depends on Claude Code's session-log format and write
#      cadence; will be dropped after the deprecation window.
#
#   4. **Last-paste timestamp** — `monitor/.state/orchestrator-last-paste.ts`,
#      stamped by main.sh on every successful paste-to-target. The
#      epoch in the file is the moment we poked the orchestrator.
#      If none of (1)–(3) advanced past this epoch, the orchestrator
#      was poked but is not demonstrably reacting — wedge signal.
#
# Decision tree per cycle:
#
#   - No last-paste yet (first watcher lifetime, or torn write) →
#     healthy. Nothing to react to.
#
#   - `age_since_paste = now - last_paste_ts <= paste_response_grace`
#     → healthy. Within the grace window even a real wedge wouldn't
#     have manifested yet; multi-step tool turns can legitimately
#     take this long before firing Stop.
#
#   - Any of `heartbeat_mtime`, `paste_received_mtime`,
#     `jsonl_mtime`, or the session `tool-results/` dir mtime >
#     `last_paste_ts` → healthy. The signals are checked in that
#     order of strength (turn-ended > paste-received > jsonl-write
#     > tool-results-offload); whichever fires first short-
#     circuits. Paste-received covers the long-tool-turn case
#     where heartbeat is stale because Stop hasn't fired yet but
#     the orchestrator is demonstrably processing the paste.
#     jsonl is the deprecation-window fallback for sessions whose
#     settings predate the new hooks; remove after one release.
#     The tool-results dir mtime (issue: operator-blind-spot) is
#     an INDEPENDENT, hook-free witness: it advances whenever a
#     live turn offloads a large tool output, so it catches an
#     orchestrator the operator is driving directly (manual pane
#     paste, invisible to watcher paste-tracking) even when every
#     paste-keyed signal lags. Its absence let a live orchestrator
#     get respawned mid-turn on 2026-06-05.
#
#   - Otherwise the orchestrator is **pasted-without-response**.
#     The state machine stamps an `unresponsive-since` marker on
#     first entry and lets the watcher's standard
#     `detect_and_unstick` loop probe cases A–D each cycle. Cases
#     A (permission prompt Enter), C (api-error chip Enter), and
#     D (AskUserQuestion chip-bar Escape + meta-paste) all
#     terminate a stuck-but-alive orchestrator's wedge, after
#     which the Stop hook fires and the heartbeat advances past
#     the marker — state resets to healthy on the next cycle.
#
#   - If `now - unresponsive_since >= unstick_window_seconds` —
#     unstick has had its chance. Before escalating to a respawn,
#     the state machine requests ONE bounded **re-submit**: the
#     watcher re-pastes the most recent emit body to the target
#     pane (a dropped / un-submitted Enter on an otherwise-alive
#     pane is rescued by a re-paste, not a respawn — substantiated
#     by the 2026-05-29..31 unstick-window-exhausted incidents).
#     The attempt is tracked via a marker file alongside
#     `unresponsive_since`; exactly one re-submit per wedge
#     episode. The re-paste deliberately does NOT advance the
#     last-paste timestamp, so it cannot reset the dead-threshold
#     clock. After the re-submit the re-paste gets one grace
#     window to produce a response signal; failing that the
#     verdict escalates to respawn (`reason=resubmit-failed`).
#
#   - If `age_since_paste >= orchestrator_dead_threshold_seconds` —
#     the absolute deadline. Respawn unconditionally (subject to
#     cooldown); the re-submit path never defeats this ceiling.
#
# Four knobs (all `monitor.watcher.*`):
#
#   paste_response_grace_seconds (120) — grace window before
#       declaring pasted-without-response. Also the response
#       window granted to a re-submit attempt.
#   unstick_window_seconds (150) — budget for the unstick cycle to
#       resolve the wedge before the re-submit fires.
#   orchestrator_dead_threshold_seconds (300) — hard floor on
#       "no heartbeat at all post-paste, including through unstick
#       and the re-submit." Must exceed grace + unstick_window so
#       the re-submit retains a verification window before the
#       deadline (defaults: 120 + 150 = 270 < 300).
#   stale_paste_ceiling_seconds (1800) — upper bound on how old a
#       last-paste timestamp may be and still serve as evidence of
#       wedging. Once `age_since_paste >= stale_paste_ceiling`, the
#       state machine treats the paste as too old to be a wedge
#       signal and returns healthy `paste-too-stale`. Without this
#       cap, a quiet workspace (no eligible pastes for hours) trips
#       the dead-threshold check on the orchestrator's first idle
#       cycle past 300 s and respawns a healthy session that simply
#       had nothing to react to. Constraint:
#       `dead_threshold_s < stale_paste_ceiling_s` (otherwise the
#       ceiling masks the dead-threshold check inside the window
#       and the wedge detector never fires).
#
# Pure side-effect-free decisions live in
# `_orchestrator_liveness_decide`. State-file management (the
# unresponsive-since marker) lives in
# `_orchestrator_liveness_step` so the main loop can call one
# function and get a complete verdict.
#
# Loaded by `monitor/watcher/main.sh` and by
# `monitor/watcher/test-orchestrator-liveness.sh`. Side-effect-free
# at load time — function definitions only.

# _orchestrator_heartbeat_age <heartbeat_file>
#
# Seconds since the heartbeat file was last touched. Missing file
# yields a sentinel large number (1e9) so callers treat "no hook
# ever fired" as "very stale." Always prints a non-negative integer
# and returns 0.
_orchestrator_heartbeat_age() {
    local heartbeat_file="${1:?heartbeat file required}"
    if [[ ! -f "$heartbeat_file" ]]; then
        printf '%d' 1000000000
        return 0
    fi
    local mtime now age
    mtime=$(date +%s -r "$heartbeat_file" 2>/dev/null || echo 0)
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    now=$(date +%s)
    age=$(( now - mtime ))
    (( age < 0 )) && age=0
    printf '%d' "$age"
}

# _orchestrator_pasted_without_response \
#     <heartbeat_file> <paste_received_file> <last_paste_file> \
#     <pin_file> <nexus_root> [home_dir] [last_paste_ts_override]
#
# Returns 0 (yes, pasted-without-response) iff:
#   - last_paste_file exists with a parseable positive epoch
#     (or a valid `last_paste_ts_override` integer is supplied);
#   - heartbeat_mtime (or 0 if absent) <= last_paste_ts;
#   - paste_received_mtime (or 0 if absent) <= last_paste_ts;
#   - jsonl_mtime (resolved via pin) <= last_paste_ts (fallback,
#     covers sessions without the new hooks installed yet); AND
#   - tool-results dir mtime (resolved via pin) <= last_paste_ts
#     (the operator-blind-spot witness — see Signal 4 below).
#
# Signals are checked in descending order of strength — heartbeat
# (turn-ended), paste-received (input queue picked it up), jsonl
# (session log advanced), tool-results dir (a tool turn offloaded
# output). The paste-received signal distinguishes "mid-tool-turn"
# from "wedged" without depending on Claude Code's log format; the
# tool-results witness (Signal 4) is the watcher-side, hook-
# INDEPENDENT signal that catches a live orchestrator driven
# directly by the operator (manual pane paste, invisible to the
# watcher's paste-tracking) — the 2026-06-05 false-positive
# respawn's missing safeguard.
#
# `last_paste_ts_override` (arg 7, optional) is the CALLER'S
# already-parsed epoch integer. When set, it is used verbatim
# and the file is NOT re-read. This closes the TOCTOU race with a
# concurrent `_orchestrator_record_paste` (async `compose_emit`
# subshell running in the same scheduler tick): without it, the
# caller's `age = now - read1(last_paste_file)` can be computed
# against the OLD epoch while THIS function's `read2` snapshot
# picks up the NEW epoch (stamped in between), so all signals get
# compared against a NEW `last_paste_ts` and appear stale — the
# caller then trips the dead-threshold branch with a huge OLD-based
# `age`. Empirically this fires the silent-wedge respawn pattern
# (`elapsed_unstick=0s`, age ≈ compose_emit cadence ~660s) that
# recurred five times in 2026-06-22..07-01. Passing the override
# from the caller pins both reads to the same snapshot.
#
# Returns 1 (orchestrator responded post-paste, or no paste to
# react to) otherwise. Prints nothing on either path — caller uses
# the rc to branch.
#
# This is a pure decision; no side effects. Tested directly by
# `test-orchestrator-liveness.sh`.
_orchestrator_pasted_without_response() {
    local heartbeat_file="${1:?heartbeat file required}"
    local paste_received_file="${2:?paste-received file required}"
    local last_paste_file="${3:?last paste file required}"
    local pin_file="${4:?pin file required}"
    local nexus_root="${5:?nexus_root required}"
    local home_dir="${6:-$HOME}"
    local last_paste_ts_override="${7:-}"

    local last_paste_ts
    if [[ -n "$last_paste_ts_override" ]] \
       && [[ "$last_paste_ts_override" =~ ^[0-9]+$ ]] \
       && (( last_paste_ts_override > 0 )); then
        # Caller's already-parsed snapshot — bypasses the TOCTOU
        # race documented above.
        last_paste_ts=$last_paste_ts_override
    else
        [[ -f "$last_paste_file" ]] || return 1
        last_paste_ts=$(head -n 1 "$last_paste_file" 2>/dev/null | tr -d '[:space:]')
        [[ "$last_paste_ts" =~ ^[0-9]+$ ]] || return 1
        (( last_paste_ts > 0 )) || return 1
    fi

    # Signal 1: Stop-hook heartbeat (turn-ended after the paste).
    local hb_mtime=0
    if [[ -f "$heartbeat_file" ]]; then
        hb_mtime=$(date +%s -r "$heartbeat_file" 2>/dev/null || echo 0)
        [[ "$hb_mtime" =~ ^[0-9]+$ ]] || hb_mtime=0
    fi
    if (( hb_mtime > last_paste_ts )); then
        return 1
    fi

    # Signal 2: UserPromptSubmit-hook paste-received (the orch's
    # input queue picked up the paste — proves the watcher's poke
    # got delivered and the agent is processing). Strictly weaker
    # than the heartbeat — paste-received fires the moment the
    # input lands; Stop fires at turn-end — so order matters: a
    # turn-end after this paste always supersedes a paste-receipt.
    local pr_mtime=0
    if [[ -f "$paste_received_file" ]]; then
        pr_mtime=$(date +%s -r "$paste_received_file" 2>/dev/null || echo 0)
        [[ "$pr_mtime" =~ ^[0-9]+$ ]] || pr_mtime=0
    fi
    if (( pr_mtime > last_paste_ts )); then
        return 1
    fi

    # Signals 3 & 4 both live under the pinned session directory, so
    # resolve the session id + project dir once and reuse it.
    local sid
    if [[ -s "$pin_file" ]]; then
        sid=$(head -n 1 "$pin_file" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "${sid:-}" ]] \
           && [[ "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            local slug proj_dir jsonl jsonl_mtime
            slug=$(printf '%s' "$nexus_root" | sed 's|[^a-zA-Z0-9]|-|g')
            proj_dir="$home_dir/.claude/projects/$slug"

            # Signal 3: pinned session's jsonl mtime — fragile, fallback
            # only. A session whose orchestrator-settings.json predates
            # the new hooks will never bump either heartbeat or paste-
            # received; any session log write post-paste is also positive
            # evidence. Removed after the deprecation window — see the
            # file header.
            jsonl="$proj_dir/$sid.jsonl"
            if [[ -f "$jsonl" ]]; then
                jsonl_mtime=$(date +%s -r "$jsonl" 2>/dev/null || echo 0)
                if [[ "$jsonl_mtime" =~ ^[0-9]+$ ]] && (( jsonl_mtime > last_paste_ts )); then
                    return 1
                fi
            fi

            # Signal 4: the session's tool-results/ dir mtime — an
            # INDEPENDENT, watcher-side liveness witness that does NOT
            # depend on any orchestrator-side hook being installed.
            # Claude Code persists a file under
            # `<projects>/<slug>/<sid>/tool-results/` for every tool
            # call whose output is large enough to offload; the dir's
            # mtime therefore advances the instant a live turn produces
            # such output — regardless of WHO drove the orchestrator
            # (operator-direct pane paste, bypassing watcher paste-
            # tracking, or a watcher paste). This is precisely the
            # witness the 2026-06-05 false-positive respawn ignored: a
            # 1.6 MB tool-result landed 28 s before the kill while all
            # of {heartbeat, paste-received, jsonl} lagged
            # `last_paste_ts`. Strictly additive — a post-paste write
            # here is positive evidence of life and short-circuits to
            # healthy before the dead-threshold floor.
            local tool_results_dir tr_mtime
            tool_results_dir="$proj_dir/$sid/tool-results"
            if [[ -d "$tool_results_dir" ]]; then
                tr_mtime=$(date +%s -r "$tool_results_dir" 2>/dev/null || echo 0)
                if [[ "$tr_mtime" =~ ^[0-9]+$ ]] && (( tr_mtime > last_paste_ts )); then
                    return 1
                fi
            fi
        fi
    fi

    return 0
}

# _orchestrator_liveness_decide \
#     <heartbeat_file> <paste_received_file> <last_paste_file> \
#     <pin_file> <unresponsive_since_file> <resubmit_marker_file> \
#     <paste_response_grace_s> <unstick_window_s> <dead_threshold_s> \
#     <stale_paste_ceiling_s> <nexus_root> [home_dir]
#
# Pure decision over the state-machine inputs. Returns:
#
#   0 + prints "respawn ..." — the verdict is "respawn now."
#   1 + prints "healthy"     — no signal to act on.
#   1 + prints "waiting reason=... elapsed=Ns/Ns"
#                            — pasted-without-response, but still
#                              inside the unstick budget. Detect-
#                              and-unstick is given another cycle.
#   1 + prints "resubmit reason=unstick-window-exhausted ..."
#                            — unstick budget exhausted and no
#                              re-submit attempted yet. The caller
#                              must re-paste the pending emit body
#                              and stamp the resubmit marker; the
#                              next cycles re-evaluate liveness.
#
# The resubmit marker file is the one-shot cap: present means a
# re-submit has already been attempted for this wedge episode.
# Its mtime anchors the post-resubmit response window (one
# grace_s); past that window the verdict escalates to
# "respawn reason=resubmit-failed". The dead-threshold check runs
# FIRST and unconditionally — the re-submit path cannot defeat
# the absolute deadline.
#
# Stateful pieces (the unresponsive-since file's mtime, the
# resubmit marker) are managed by the caller / by
# `_orchestrator_liveness_step`.
_orchestrator_liveness_decide() {
    local heartbeat_file="${1:?heartbeat file required}"
    local paste_received_file="${2:?paste-received file required}"
    local last_paste_file="${3:?last paste file required}"
    local pin_file="${4:?pin file required}"
    local unresponsive_since_file="${5:?unresponsive-since file required}"
    local resubmit_marker_file="${6:?resubmit-marker file required}"
    local grace_s="${7:-120}"
    local unstick_window_s="${8:-150}"
    local dead_threshold_s="${9:-300}"
    local stale_paste_ceiling_s="${10:-1800}"
    local nexus_root="${11:?nexus_root required}"
    local home_dir="${12:-$HOME}"

    # No last-paste recorded yet → first-cycle grace; nothing to act on.
    if [[ ! -f "$last_paste_file" ]]; then
        printf 'healthy reason=no-paste-yet'
        return 1
    fi
    local last_paste_ts now age
    last_paste_ts=$(head -n 1 "$last_paste_file" 2>/dev/null | tr -d '[:space:]')
    [[ "$last_paste_ts" =~ ^[0-9]+$ ]] || { printf 'healthy reason=paste-ts-invalid'; return 1; }
    (( last_paste_ts > 0 )) || { printf 'healthy reason=paste-ts-zero'; return 1; }
    now=$(date +%s)
    age=$(( now - last_paste_ts ))

    # Inside the grace window. Even a real wedge can't have
    # manifested yet — turn machinery legitimately takes this long.
    if (( age <= grace_s )); then
        printf 'healthy reason=within-grace age=%ds grace=%ds' "$age" "$grace_s"
        return 1
    fi

    # Past the stale-paste ceiling. The paste is too old to be
    # evidence of wedging — a quiet workspace with no eligible
    # pastes for hours is not the same as a wedged orchestrator.
    # Any fresh paste resets `last_paste_ts` and the wedge detector
    # re-engages within the in-window range.
    if (( age >= stale_paste_ceiling_s )); then
        printf 'healthy reason=paste-too-stale age=%ds ceiling=%ds' \
            "$age" "$stale_paste_ceiling_s"
        return 1
    fi

    # Past grace, inside ceiling — has the orchestrator responded?
    # Pin both reads of `last_paste_file` to the SAME snapshot by
    # forwarding our already-parsed epoch. `compose_emit`'s async
    # subshell can be mid-stamp on the same file during this tick;
    # letting the callee re-read the file opens a TOCTOU race that
    # falsely trips dead-threshold with an OLD-based `age` and a
    # NEW-based signal comparison — see the silent-wedge respawn
    # incidents (`elapsed_unstick=0s`, age ≈ compose_emit cadence)
    # documented in `_orchestrator_pasted_without_response`'s header.
    if ! _orchestrator_pasted_without_response \
            "$heartbeat_file" "$paste_received_file" "$last_paste_file" \
            "$pin_file" "$nexus_root" "$home_dir" "$last_paste_ts"; then
        printf 'healthy reason=signal-past-paste age=%ds' "$age"
        return 1
    fi

    # Pasted-without-response. Determine elapsed time in the
    # unstick window from the marker file's mtime; absent means
    # "first observation, will be stamped by the step wrapper."
    local since_ts=0 elapsed=0
    if [[ -f "$unresponsive_since_file" ]]; then
        since_ts=$(date +%s -r "$unresponsive_since_file" 2>/dev/null || echo 0)
        [[ "$since_ts" =~ ^[0-9]+$ ]] || since_ts=0
        if (( since_ts > 0 )); then
            elapsed=$(( now - since_ts ))
            (( elapsed < 0 )) && elapsed=0
        fi
    fi

    # Absolute deadline FIRST and unconditional. No re-submit
    # bookkeeping can defer this — a paste with zero response
    # signals for dead_threshold_s means respawn, full stop.
    if (( age >= dead_threshold_s )); then
        printf 'respawn reason=dead-threshold age=%ds dead_threshold=%ds elapsed_unstick=%ds last_paste_ts=%d' \
            "$age" "$dead_threshold_s" "$elapsed" "$last_paste_ts"
        return 0
    fi

    # Re-submit already attempted for this wedge episode? The
    # marker's mtime anchors the post-resubmit response window:
    # one grace_s for the re-paste to produce any response signal
    # (the re-paste lands fresh content — an alive orchestrator's
    # UserPromptSubmit hook fires within seconds). Past that
    # window, the rescue failed; escalate.
    if [[ -f "$resubmit_marker_file" ]]; then
        local resubmit_ts=0 resubmit_age=0
        resubmit_ts=$(date +%s -r "$resubmit_marker_file" 2>/dev/null || echo 0)
        [[ "$resubmit_ts" =~ ^[0-9]+$ ]] || resubmit_ts=0
        if (( resubmit_ts > 0 )); then
            resubmit_age=$(( now - resubmit_ts ))
            (( resubmit_age < 0 )) && resubmit_age=0
        fi
        if (( resubmit_age > grace_s )); then
            printf 'respawn reason=resubmit-failed age=%ds resubmit_age=%ds/%ds elapsed_unstick=%ds last_paste_ts=%d' \
                "$age" "$resubmit_age" "$grace_s" "$elapsed" "$last_paste_ts"
            return 0
        fi
        printf 'waiting reason=resubmit-pending age=%ds resubmit_age=%ds/%ds dead_threshold=%ds' \
            "$age" "$resubmit_age" "$grace_s" "$dead_threshold_s"
        return 1
    fi

    # Unstick budget exhausted, no re-submit attempted yet —
    # request the one-shot re-paste rescue before any respawn.
    if (( since_ts > 0 )) && (( elapsed >= unstick_window_s )); then
        printf 'resubmit reason=unstick-window-exhausted age=%ds unstick_window=%ds elapsed_unstick=%ds last_paste_ts=%d' \
            "$age" "$unstick_window_s" "$elapsed" "$last_paste_ts"
        return 1
    fi

    # Inside the unstick window — let detect_and_unstick try.
    printf 'waiting reason=unstick-window age=%ds elapsed_unstick=%ds/%ds dead_threshold=%ds' \
        "$age" "$elapsed" "$unstick_window_s" "$dead_threshold_s"
    return 1
}

# _orchestrator_liveness_step \
#     <heartbeat_file> <paste_received_file> <last_paste_file> \
#     <pin_file> <unresponsive_since_file> <resubmit_marker_file> \
#     <cooldown_file> \
#     <paste_response_grace_s> <unstick_window_s> <dead_threshold_s> \
#     <cooldown_s> <stale_paste_ceiling_s> <nexus_root> [home_dir]
#
# State-machine step. Wraps `_orchestrator_liveness_decide` with:
#
#   - Stamping the `unresponsive_since` marker on first detection.
#   - Clearing the marker AND the resubmit marker on any healthy
#     decision (so the next wedge episode gets a fresh unstick
#     budget and a fresh one-shot re-submit allowance).
#   - Cooldown gate on the respawn verdict (mtime-based, like the
#     pre-existing fresh-spawn cooldown).
#
# Returns:
#   0 + prints reason — caller should respawn.
#   1 + prints reason — healthy / waiting / resubmit / blocked by
#       cooldown. A `resubmit ...` verdict instructs the caller to
#       re-paste the pending emit body and stamp the resubmit
#       marker (the step does NOT stamp it — only the caller knows
#       whether the re-paste was actually attempted).
#
# Side effects:
#   - Touches / creates / removes $unresponsive_since_file and
#     removes $resubmit_marker_file depending on the decision.
#   - Does NOT touch the cooldown file; the caller (spawn helper)
#     stamps it as part of the respawn event log.
#   - Does NOT stamp the resubmit marker; the caller does, after
#     attempting the re-paste.
_orchestrator_liveness_step() {
    local heartbeat_file="${1:?heartbeat file required}"
    local paste_received_file="${2:?paste-received file required}"
    local last_paste_file="${3:?last paste file required}"
    local pin_file="${4:?pin file required}"
    local unresponsive_since_file="${5:?unresponsive-since file required}"
    local resubmit_marker_file="${6:?resubmit-marker file required}"
    local cooldown_file="${7:?cooldown file required}"
    local grace_s="${8:-120}"
    local unstick_window_s="${9:-150}"
    local dead_threshold_s="${10:-300}"
    local cooldown_s="${11:-1800}"
    local stale_paste_ceiling_s="${12:-1800}"
    local nexus_root="${13:?nexus_root required}"
    local home_dir="${14:-$HOME}"

    local verdict
    verdict=$(_orchestrator_liveness_decide \
        "$heartbeat_file" "$paste_received_file" \
        "$last_paste_file" "$pin_file" \
        "$unresponsive_since_file" "$resubmit_marker_file" \
        "$grace_s" "$unstick_window_s" "$dead_threshold_s" \
        "$stale_paste_ceiling_s" \
        "$nexus_root" "$home_dir") && decide_rc=0 || decide_rc=$?

    case "$verdict" in
        respawn*)
            # Cooldown gate. Identical mtime-based protocol to the
            # pre-existing _orchestrator_should_fresh_spawn —
            # cooldown file is touched by spawn-fresh-orchestrator.sh
            # on each respawn, so its mtime acts as the "last
            # respawn attempt" clock.
            local cooldown_mtime=0 now
            if [[ -f "$cooldown_file" ]]; then
                cooldown_mtime=$(date +%s -r "$cooldown_file" 2>/dev/null || echo 0)
                [[ "$cooldown_mtime" =~ ^[0-9]+$ ]] || cooldown_mtime=0
            fi
            now=$(date +%s)
            if (( cooldown_mtime > 0 )) && (( now - cooldown_mtime < cooldown_s )); then
                printf 'blocked-by-cooldown %s cooldown_age=%ds/%ds' \
                    "$verdict" \
                    "$(( now - cooldown_mtime ))" "$cooldown_s"
                return 1
            fi
            printf '%s cooldown_age=%ds/%ds' \
                "$verdict" \
                "$(( cooldown_mtime > 0 ? now - cooldown_mtime : 0 ))" \
                "$cooldown_s"
            return 0
            ;;
        waiting*)
            # First entry into the unstick window — stamp the marker
            # so the next cycle can compute elapsed correctly.
            if [[ ! -f "$unresponsive_since_file" ]]; then
                mkdir -p "$(dirname "$unresponsive_since_file")" 2>/dev/null || true
                : > "$unresponsive_since_file" 2>/dev/null || true
                # Touch to "now" explicitly so a filesystem with
                # imprecise create-time mtime semantics still gets
                # a deterministic anchor.
                touch -c "$unresponsive_since_file" 2>/dev/null || true
            fi
            printf '%s' "$verdict"
            return 1
            ;;
        resubmit*)
            # Pass through verbatim. The caller performs the
            # re-paste and stamps the resubmit marker — stamping
            # here would record an attempt that may never happen.
            printf '%s' "$verdict"
            return 1
            ;;
        healthy*)
            # Any healthy decision clears both markers so the next
            # wedge starts a fresh unstick window and a fresh
            # one-shot re-submit allowance.
            rm -f "$unresponsive_since_file" 2>/dev/null || true
            rm -f "$resubmit_marker_file" 2>/dev/null || true
            printf '%s' "$verdict"
            return 1
            ;;
        *)
            # Unreachable; fall through as healthy to avoid
            # firing a spawn on an unexpected verdict shape.
            printf 'healthy reason=unknown-verdict verdict=%q' "$verdict"
            return 1
            ;;
    esac
}

# ---- structural-coherence clamp (eliminate the FP race at the source) -----
#
# _orchestrator_effective_dead_threshold \
#     <configured_dead_threshold_s> <full_state_emit_interval_s> \
#     <loop_interval_s> <floor_margin_s> <stale_paste_ceiling_s>
#
# Pure. Returns (on stdout) the EFFECTIVE orchestrator dead_threshold after
# the 2026-06-15 structural-coherence clamp. In a fully-static workspace the
# only pastes are the full-state cadence, so the maximum gap between
# compose_emit fires is full_state_emit_interval + one loop tick. If
# dead_threshold sits at or below that gap, last_paste_ts can age past the
# deadline before the next paste resets it — a false-positive respawn of a
# healthy idle orchestrator. The clamp lifts the effective threshold to
# (gap + margin) so a paste always resets the clock first, eliminating the
# race at the source (not via the runtime guard).
#
# The clamp is DECLINED (configured value returned unchanged) when it would
# push dead_threshold to or past stale_paste_ceiling — `dead_threshold <
# stale_paste_ceiling` is a load-bearing invariant (otherwise the ceiling
# masks the dead-threshold check and the wedge detector never fires). The
# caller compares input vs output to decide whether to log a clamp, and
# re-checks the gap to log the decline.
#
# Always returns 0. PURE — arithmetic only, no side effects.
_orchestrator_effective_dead_threshold() {
    local dead="${1:?dead_threshold required}"
    local full="${2:?full_state_emit_interval required}"
    local interval="${3:?loop_interval required}"
    local margin="${4:-60}"
    local ceiling="${5:?stale_paste_ceiling required}"

    [[ "$dead"     =~ ^[0-9]+$ ]] || { printf '%s' "$dead"; return 0; }
    [[ "$full"     =~ ^[0-9]+$ ]] || { printf '%d' "$dead"; return 0; }
    [[ "$interval" =~ ^[0-9]+$ ]] || { printf '%d' "$dead"; return 0; }
    [[ "$margin"   =~ ^[0-9]+$ ]] || margin=60
    [[ "$ceiling"  =~ ^[0-9]+$ ]] || { printf '%d' "$dead"; return 0; }

    local gap=$(( full + interval ))
    if (( gap >= dead )); then
        local floor=$(( gap + margin ))
        if (( floor < ceiling )); then
            dead=$floor
        fi
    fi
    printf '%d' "$dead"
    return 0
}

# ---- idle-pane guard (runtime override of a respawn verdict) --------------
#
# The dead-threshold respawn is a coarse, last-resort backstop. In a
# fully-static workspace `last_paste_ts` can age past dead_threshold
# between compose_emit fires (when
# full_state_emit_interval + loop_tick > dead_threshold) and produce a
# `respawn reason=dead-threshold` verdict for an orchestrator that is
# provably alive at its `>` prompt — the 2026-06-15T12:14:39 incident
# (age=641s, dead_threshold=300s, fired one second before the resurfacing
# full-state paste would have reset the clock). Before HONORING a respawn
# verdict, `_v2_task_orchestrator_liveness` (main.sh) consults
# `monitor/pane-state.sh`; this pure function turns the tuple
# (verdict, pane_state, how-many-times-already-overridden, budget) into a
# decision.
#
# Why pane-state is the only available disambiguator: by the time the
# state machine reaches a respawn verdict, every paste-keyed liveness
# signal (heartbeat / paste-received / jsonl / tool-results) is stale by
# definition — that staleness is *why* the verdict is respawn. A healthy
# IDLE orchestrator and a wedged-but-alive one are indistinguishable from
# those signals (both produce no fresh signal while idle). pane-state adds
# an orthogonal observation: is the process alive, and what is the TUI
# showing right now?
#
# Echoes exactly one token on stdout:
#   suppress  — pane shows the orchestrator alive and not visibly wedged
#               (state idle or empty) AND the override budget is not yet
#               spent. Override the respawn; let the next compose_emit
#               paste reset the clock. `empty` is included because it is
#               process-anchored to "claude alive, renderer transient"
#               (pane-state emits `absent`, never `empty`, when the
#               process is gone) and is the documented fresh-resume quirk
#               that the 2026-06-15 incident's own post-respawn probes
#               exhibited.
#   escalate  — pane looks alive (idle/empty) BUT we have already
#               overridden `max_overrides` consecutive times without the
#               orchestrator ever recovering. An alive pane that is
#               PERMANENTLY parked at an idle prompt, never advancing a
#               single liveness signal across many cycles, is itself a
#               wedge. Honor the respawn. THIS BOUND is the safety floor:
#               without it a hung-but-idle-rendering TUI could suppress
#               its own respawn forever and stay dead — the dangerous
#               false-negative.
#   proceed   — pane does NOT look alive-and-idle: busy / blocked /
#               user-typing / absent / over-limit / working-* / unknown,
#               OR pane-state errored and produced no state token. Honor
#               the respawn. A genuine wedge manifests as one of these
#               (frozen spinner=busy, overlay=blocked, dropped-Enter text
#               in the box=user-typing, dead process=absent); "unknown"
#               deliberately fails TOWARD respawn (recoverable, mode=resume
#               preserves the session) rather than suppression (risk: dead
#               forever).
#
# SCOPE — only `respawn reason=dead-threshold` is gated. That is the sole
# verdict the static-workspace false positive can produce (the clock aged
# past the absolute deadline with no rescue). A `resubmit reason=...-failed`
# respawn has ALREADY proven non-responsiveness via the one-shot re-paste
# probe — a healthy orchestrator would have gone `busy` processing the
# re-paste — so it is NEVER suppressed, regardless of pane state. Any other
# respawn reason likewise passes through. This keeps the suppression
# surface as narrow as possible: the guard can only ever defer the one
# verdict that is demonstrably prone to false positives, bounding the
# false-negative to a near-empty set even before the override budget.
#
# Always returns 0. PURE — no file/process/tmux access, no side effects.
# The caller owns the override-count state file, the pane-state call, and
# the respawn action.
_orchestrator_idle_pane_guard() {
    local verdict="${1:?verdict required}"
    local pane_state="${2-}"
    local override_count="${3:-0}"
    local max_overrides="${4:-5}"

    # Gate ONLY the dead-threshold respawn (see SCOPE above); every other
    # verdict — including resubmit-failed respawns — passes through.
    [[ "$verdict" == "respawn reason=dead-threshold"* ]] || { printf 'proceed'; return 0; }

    [[ "$override_count" =~ ^[0-9]+$ ]] || override_count=0
    [[ "$max_overrides" =~ ^[0-9]+$ ]] || max_overrides=5

    case "$pane_state" in
        idle|empty)
            if (( max_overrides > 0 )) && (( override_count >= max_overrides )); then
                printf 'escalate'
            else
                printf 'suppress'
            fi
            ;;
        *)
            printf 'proceed'
            ;;
    esac
    return 0
}

# ---- verdict log throttling ----------------------------------------------
#
# The liveness task runs every ~5 s; logging the `waiting` verdict on
# every poll produced ~40-line bursts per slow orchestrator turn
# (2026-05-29..31 incidents). The throttle reduces that to:
#
#   - one line on STATE ENTRY (first waiting observation past grace),
#   - at most one line per `throttle_s` (default 30) while waiting,
#   - one line on every state TRANSITION (waiting → healthy/resubmit/
#     respawn), carrying a duration summary on exit from waiting,
#   - resubmit / respawn / unknown verdicts always logged.
#
# State lives in per-process globals (the watcher main loop is a
# single bash process). The decision CANNOT run in a command
# substitution — `$( )` forks a subshell and the state updates would
# be lost. Call it in the current shell; the line to log (empty =
# suppress) is returned via the _ORCH_LIVENESS_LOG_LINE global.

# _orchestrator_liveness_log_decide <verdict> [now_epoch] [throttle_s]
#
# Updates throttle state and sets _ORCH_LIVENESS_LOG_LINE to the
# line the caller should log, or to the empty string when the
# verdict is suppressed. Always returns 0.
_orchestrator_liveness_log_decide() {
    local verdict="${1:?verdict required}"
    local now="${2:-$(date +%s)}"
    local throttle_s="${3:-30}"

    # Classify the verdict into a state for transition tracking.
    local state
    case "$verdict" in
        waiting*|blocked-by-cooldown*) state=waiting ;;
        resubmit*)                     state=resubmit ;;
        respawn*)                      state=respawn ;;
        healthy*)                      state=healthy ;;
        *)                             state=unknown ;;
    esac

    local prev="${_ORCH_LIVENESS_LOG_STATE:-healthy}"
    _ORCH_LIVENESS_LOG_LINE=""

    case "$state" in
        waiting)
            if [[ "$prev" != waiting ]]; then
                # State entry — always log, and note the throttle so a
                # reader knows why subsequent polls go quiet. The
                # episode anchor is preserved across the resubmit
                # detour (waiting → resubmit → waiting) so duration
                # summaries span the whole wedge episode.
                if [[ "$prev" != resubmit || -z "${_ORCH_LIVENESS_LOG_ENTERED_TS:-}" ]]; then
                    _ORCH_LIVENESS_LOG_ENTERED_TS=$now
                fi
                _ORCH_LIVENESS_LOG_LAST_TS=$now
                _ORCH_LIVENESS_LOG_SUPPRESSED=0
                _ORCH_LIVENESS_LOG_LINE="$verdict (entered waiting; updates every ${throttle_s}s)"
            elif (( now - ${_ORCH_LIVENESS_LOG_LAST_TS:-0} >= throttle_s )); then
                local waited=$(( now - ${_ORCH_LIVENESS_LOG_ENTERED_TS:-$now} ))
                _ORCH_LIVENESS_LOG_LINE="$verdict (waiting ${waited}s; ${_ORCH_LIVENESS_LOG_SUPPRESSED:-0} polls suppressed)"
                _ORCH_LIVENESS_LOG_LAST_TS=$now
                _ORCH_LIVENESS_LOG_SUPPRESSED=0
            else
                _ORCH_LIVENESS_LOG_SUPPRESSED=$(( ${_ORCH_LIVENESS_LOG_SUPPRESSED:-0} + 1 ))
            fi
            ;;
        healthy)
            # Steady state is silent. The one exception: exiting the
            # waiting/resubmit phase — emit the recovery summary so
            # the episode has a closing breadcrumb.
            if [[ "$prev" == waiting || "$prev" == resubmit ]]; then
                local dur=$(( now - ${_ORCH_LIVENESS_LOG_ENTERED_TS:-$now} ))
                _ORCH_LIVENESS_LOG_LINE="recovered after ${dur}s ($verdict)"
            fi
            ;;
        respawn)
            # The caller's respawn path logs the firing details
            # itself; here we only emit the waiting-exit summary.
            if [[ "$prev" == waiting || "$prev" == resubmit ]]; then
                local dur=$(( now - ${_ORCH_LIVENESS_LOG_ENTERED_TS:-$now} ))
                _ORCH_LIVENESS_LOG_LINE="waiting escalated to respawn after ${dur}s ($verdict)"
            else
                _ORCH_LIVENESS_LOG_LINE="$verdict"
            fi
            ;;
        resubmit|unknown)
            # One-shot events — always logged verbatim.
            _ORCH_LIVENESS_LOG_LINE="$verdict"
            ;;
    esac

    _ORCH_LIVENESS_LOG_STATE="$state"
    return 0
}
