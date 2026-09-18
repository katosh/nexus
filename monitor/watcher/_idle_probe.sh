# shellcheck shell=bash
# monitor/watcher/_idle_probe.sh — detect worker windows that have
# been "really idle" for ≥ threshold seconds, classify each as
# wrapped-up vs missing-wrap-up, and dedupe against the previous
# cycle's classification so the watcher only emits transitions.
#
# Sourced from monitor/watcher/main.sh (alongside _lib.sh,
# _github.sh, _unstick.sh). Pure functions with two append-mostly
# state files under $STATE_DIR:
#
#   - idle-state.tsv       — prior cycle's (window, class) for dedupe
#   - engagement-log.tsv   — last `busy`/`user-typing` epoch per window
#   - operator-engaged.tsv — operator-engagement marks (issues #196,
#                            #201): one row per window the operator
#                            is (or was) driving, plus the last-
#                            processed user-prompt epoch; see the
#                            "operator-engaged" section below
#   - machine-input.tsv    — watcher/orchestrator-side pane-input
#                            stamps (issue #201): rows
#                            `<window>\t<epoch>\t<src>` written by
#                            _unstick.sh nudges and
#                            monitor/paste-followup.sh; consulted to
#                            attribute user-prompt submits
#   - user-prompt/<window> — per-window "last user-prompt submitted"
#                            stamp (`<epoch>\t<session-id>`), written
#                            by monitor/worker-heartbeat.sh from the
#                            UserPromptSubmit hook. THE operator-
#                            engagement trigger: a deterministic
#                            contract event from Claude Code itself,
#                            immune to the TUI character-rewriting
#                            that distorts `tmux capture-pane` reads
#   - pane-change/<window> — per-window pane-content-change stamp
#                            (`<last_hash>\t<last_change_epoch>`),
#                            written by the observe loop each cycle
#                            from pane-state.sh's `content_hash=`
#                            field (your-org/your-nexus#205 follow-up).
#                            `last_change_epoch` is the last cycle the
#                            transcript-region hash actually differed.
#                            THE corroboration substrate: a submit
#                            marks the operator only when change is
#                            observed within the decay TTL, and a mark
#                            stays valid only while change keeps
#                            landing within it — so a static pane's
#                            mark self-expires. Replaces #270's fragile
#                            one-frame bright-marker typing stamp
#   - machine-submit/<window> — per-window "last MACHINE-attributed
#                            user-prompt submit" stamp (`<epoch>`),
#                            written by the observe loop when the
#                            attribution rule claims a submit for the
#                            orchestrator (the #205 state-machine
#                            follow-up). Consulted by the wrap-up
#                            classifier: a machine submit NEWER than
#                            the window's wrap-up supersedes the
#                            wrap-up — the worker was re-tasked, so it
#                            regresses to the normal busy →
#                            no-wrap-up lifecycle instead of staying
#                            "wrapped" on a stale hand-off
#
# Why tmux's window_activity is NOT load-bearing for either the
# idle-pool entry gate OR retain-consume: tmux bumps
# `#{window_activity}` on any output change in the pane —
# autosuggest re-renders, cursor blinks, spinner glyph swaps, the
# status-bar token counter ticking. None of those are engagement.
# Empirical confirmation on `echo-density` (issue #111): retain.ts
# at 12:43:01, no human/agent input for 18 minutes, yet
# `#{window_activity}` advanced to 13:00:50 — pane-state at that
# moment was `autosuggest-only`. So `window_activity > retain.ts`
# alone is too loose a "retain consumed" signal, and
# `now - window_activity < threshold` is too tight a "really idle"
# gate (retained workers oscillate in and out, thrashing the
# `(N retained windows suppressed: …)` footer every minute or two).
#
# The engagement-log fixes both: each cycle we stamp
# `<window>\t<now>` only when `monitor/pane-state.sh` classifies
# the pane as `busy` or `user-typing` (the two states that reflect
# real engagement), AND we backfill `<window>\t<now>` on the very
# first observation of any window (issue #44) so the age
# computation never falls back to tmux's noisy
# `#{window_activity}`. The retain-consume gate compares the
# stored engagement epoch against `retain.ts`. The idle-pool
# entry gate computes age as `now - engagement_epoch`,
# unconditionally — because the backfill guarantees every
# observed window has a row. The displayed idle-age column
# therefore reflects the current idle stretch's true start, not
# the timestamp of the last cursor blink. Trade-off: workers
# that were already idle when the watcher started (or pre-existing
# windows on a fresh watcher process) get stamped at observation
# time, so they sit in "not really idle yet" for the first 60s
# after startup before entering the pool consistently. Cheap
# price for stable footer membership.
#
# Output contract for list_really_idle_workers — one line per
# really-idle worker window:
#
#     <window-name>\t<wrap-up-class>\t<activity-age-seconds>\t<detail>
#
# where <wrap-up-class> ∈ {wrapped, wrapped-but-stub, no-wrap-up,
# idle-too-long, pane-absent, retained, operator-engaged,
# paste-unconfirmed}. Non-idle and non-worker windows (watcher,
# claude/orchestrator, monitor) are never emitted.
#
# `operator-engaged` (issues #196, #201, #205) is a suppression class
# for a window the operator drives, wrapped or never-wrapped: any
# worker whose UserPromptSubmit hook stamped a prompt submit NOT
# attributable to the orchestrator/watcher (no paste-followup /
# machine-input / spawn stamp covering the submit) AND CORROBORATED by
# observed pane-content change within the decay TTL (your-org/your-nexus#205
# follow-up — this replaces #270's fragile one-frame `user-typing`
# read; a submit with no real interaction following it is a redraw
# artifact and must not suppress the nags). While the mark is VALID the
# window classifies as `operator-engaged` instead of
# `wrapped`/`no-wrap-up` — so it does not nag "consider follow-up
# paste", its `idle_prompt` decisions are not surfaced, and it is not
# retire-eligible. The mark is SELF-EXPIRING: the moment the pane goes
# static past MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS (default 600)
# the mark lapses and the window returns to its normal
# retire-eligibility — so a still-wanted window is released (and is
# recoverable by respawn) rather than pinned open forever on a stale or
# false mark. An `engaged-done` finished-signal or a newer spawn (or
# window close) also ends it. A wrap-up does NOT: an interactive
# session that wraps stays engaged by default (the operator may have
# follow-up inquiries — the #205 state-machine follow-up); `ng wrap-up`
# prompts the agent to run `ng engaged-done` when it is finished.
# While a mark is kept valid by sustained change but the operator has
# not submitted for the grace, the away phase emits a once-per-period
# `engaged-close-reminder` (default 24 h). Full lifecycle: the
# "operator-engaged marks" section below.
#
# `pane-absent` fires when `monitor/pane-state.sh` reports
# `state ∈ {absent, blocked}` for a worker window. Inviolable like
# `idle-too-long`: never suppressed by `window-retain`. The whole
# point is to surface a crash that nothing else surfaces.
#
# `empty` is NOT in that set and has not been since the post-rethink
# split — pane-state.sh distinguishes it (alive claude, transient
# render state) from `absent` (no live claude in the pane). This
# comment said `{absent, empty, blocked}` long after the code stopped
# agreeing; corrected with your-org/nexus-code#808, whose whole subject
# is a description of this class drifting from what it does.
#
# ONE CLASS, TWO ADVISORIES (your-org/nexus-code#808). Both member
# states need the operator, which is why they share the surface, but
# they need OPPOSITE actions:
#
#   absent    the inner Claude process is gone (pane fell back to
#             shell / no input chevron)  → "relaunch or close"
#   blocked   the process is ALIVE and rendering a modal it is waiting
#             for a human to answer      → "ANSWER it; do NOT relaunch"
#
# The detail column carries whichever applies and `render_idle_section`
# prints it verbatim. `n_pane_absent` in the summary line still counts
# both into one number — deliberately out of scope here, and called out
# in `#808` as the wider judgement it is; the per-row advisory is what
# an operator acts on.
#
# `retained` is a post-classification override applied when the
# orchestrator has logged a recent `window-retain` event for the
# window via `monitor/ng log-action monitor --event window-retain
# --extra window=<name> --extra reason=<short>`. The override
# converts a base classification of `wrapped` or `no-wrap-up` into
# `retained` (the row is collated into a footer rather than emitted
# as a stand-alone "consider close" line); `wrapped-but-stub`,
# `idle-too-long`, and `pane-absent` are inviolable and never
# suppressed — broken reports, runaway windows, and crashed panes
# must surface regardless of intent. The retain is consumed only by
# *real engagement* recorded in engagement-log.tsv (any `busy` or
# `user-typing` observation since retain.ts) and expires after
# MONITOR_RETAIN_TTL_SECONDS (default 86400 = 24h). Detail for
# `retained` rows carries the retain reason verbatim.
#
# The dedupe state file is line-oriented:
#
#     <window-name>\t<class>
#
# It captures the prior-cycle's "really idle" set. Transitions
# detected by diffing this cycle's set against the prior:
#
#   - NOT_IDLE -> IDLE_*       : emit (worker just went silent)
#   - IDLE_NO_WRAP_UP -> IDLE_WRAPPED : emit (worker landed wrap-up;
#                                       orchestrator can consider close)
#   - IDLE_* -> NOT_IDLE       : no emit (worker is busy again)
#   - IDLE_X -> IDLE_X         : no emit (still in same state)
#   - IDLE_X -> RETAINED       : suppression engaged; footer re-emits
#   - RETAINED -> IDLE_X       : suppression lifted; footer re-emits
#
# Thresholds:
#   MONITOR_IDLE_THRESHOLD_SECONDS  — "really idle" age (default 60)
#   MONITOR_IDLE_CLOSE_HOURS        — idle-too-long cutoff (default 24h)
#   MONITOR_RETAIN_TTL_SECONDS      — window-retain lifetime
#                                     (default 86400 = 24h)

# ---- internals ----------------------------------------------------------

# Emit the set of service window-names declared in the service
# registry, one per line. Consumed by _idle_list_worker_windows to
# exempt registry-declared infra/service windows from the worker
# sweep — a healthy nginx/serve window (e.g. `demo-serve` on
# :8731) is infrastructure, not a dead worker, and must never trip
# the pane-absent "relaunch or close" alarm.
#
# Mirrors bootstrap-recover.sh's `_recover_parse_registry` line
# handling so the two stay in lock-step: skip blank lines and `#`
# comments, require the exact four-field TAB shape, and take field 1
# (name). A malformed line is skipped silently — a single bad entry
# must not break the idle sweep. A missing registry yields no names,
# so the caller degrades to the hardcoded reserved set exactly as
# before. The path resolves the same way the rest of the stack does:
# $NEXUS_SERVICES_REGISTRY override, else $NEXUS_ROOT/monitor/
# services.registry, else this file's sibling monitor dir (mirrors
# the pane-state.sh / ng resolution elsewhere in this module).

# your-org/nexus-code#941 — the window-key encoder lives in ONE place
# (monitor/_bookkeeping.sh). Sourced only if not already present, because the
# usual caller has loaded it long before this file. NO fallback to the lossy
# `${w//[^a-zA-Z0-9_-]/_}` form: a writer and a reader disagreeing about the
# key is the very defect this closes, and a silent fallback would recreate it
# exactly when nobody is watching.

# STATE_DIR UNSET IS NOT "the current directory" (your-org/nexus-code#1478).
# Every state path in this module used to fall back to `.`, so a caller that
# sourced it without STATE_DIR — 22 production scripts source this file, from
# hooks to spawn-worker.sh — wrote `last-prelude.ts`, `engagement-log.tsv`,
# `idle-probe-previous-windows.txt` and `pane-change/` into its CWD. Measured
# 2026-09-06: all four sat at the operator's REPO ROOT with one mtime
# (2026-08-26 18:44), i.e. one invocation, cwd = the checkout. Untracked, so
# nothing shipped; but the default WAS the mechanism, and `.` is the
# permissive default arm of a state-dir resolver (#1451/#1452 family).
# Fail closed toward the checkout: the fallback is a per-user scratch dir,
# announced ONCE on stderr, never the cwd. Returning EMPTY would be worse —
# `${STATE_DIR}/last-prelude.ts` would then be `/last-prelude.ts`.
_ip_nostate_dir() {
    local d="${TMPDIR:-/tmp}/nexus-idle-probe-NOSTATE-$(id -u 2>/dev/null || echo u)"
    mkdir -p "$d" 2>/dev/null || true
    # Once per PROCESS. This runs inside `$(…)` at every call site, so a shell
    # variable set here dies with the subshell — the marker is a file keyed on
    # the parent's pid instead.
    if [[ ! -e "$d/.warned-$$" ]]; then
        : > "$d/.warned-$$" 2>/dev/null || true
        printf '_idle_probe.sh: WARNING: STATE_DIR is unset — state falls back to %s, NOT the current directory (your-org/nexus-code#1478). Set STATE_DIR.\n' "$d" >&2
    fi
    printf '%s' "$d"
}

if ! declare -F wk_encode >/dev/null 2>&1; then
    _wk_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_bookkeeping.sh"
    if [[ -r "$_wk_lib" ]]; then
        # shellcheck source=monitor/_bookkeeping.sh
        source "$_wk_lib"
    else
        printf '%s: cannot load the window-key encoder from %s — refusing\n' \
            "${BASH_SOURCE[0]##*/}" "$_wk_lib" >&2
        return 2 2>/dev/null || exit 2
    fi
fi

# THE NEGATION IS DEFEATED ON A COMPOUND COMMAND, so this predicate is a
# FUNCTION and callers write `if ! <fn>`. Measured, bash 4.4.20:
#     : 2>/dev/null < UNREADABLE        rc 1     ! : … < UNREADABLE        rc 0
#     { : ; } 2>/dev/null < UNREADABLE  rc 1     ! { : ; } … < UNREADABLE  rc 1   <-- ! IGNORED
#     ( : ) 2>/dev/null < UNREADABLE    rc 1     ! ( : ) … < UNREADABLE    rc 1   <-- ! IGNORED
# A failed redirection on a COMPOUND command is a redirection ERROR, and the
# `!` does not invert it; on a SIMPLE command it does. So `! : < f` works,
# `! { :; } < f` silently never fires, and testing the first and generalising
# walks you into the second. `cmd … || arm` is unaffected and is what the body
# below uses. AND ZSH DISAGREES: the same `! { :; } < UNREADABLE` is rc 0 under
# zsh 5.4.2 — so probing this at an interactive zsh prompt CONFIRMS the broken
# form. This nexus is zsh-default, which is exactly how it would arrive.
# A guard that parses, reads correctly, and never fires is the very defect
# class your-org/nexus-code#1266 is about; it was caught here only because the
# suite asserts this function's rc directly.
_idle_registry_readable() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    { : ; } 2>/dev/null < "$f" || return 1
    return 0
}

_idle_registry_service_names() {
    local registry="${NEXUS_SERVICES_REGISTRY:-}"
    if [[ -z "$registry" ]]; then
        if [[ -n "${NEXUS_ROOT:-}" ]]; then
            registry="$NEXUS_ROOT/monitor/services.registry"
        else
            registry="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/services.registry"
        fi
    fi
    # your-org/nexus-code#1266. `[[ -f ]]` is TRUE for a file that exists and
    # cannot be READ, so this guard did not cover the `done < "$registry"`
    # below. The direction here is the SAFE one and the treatment is
    # deliberately different from the other readers: this list is an
    # EXEMPTION set, so losing it makes the sweep see MORE windows, never
    # fewer — it over-reports rather than going silent. Refusing to produce a
    # list would instead disable the worker sweep, which is a real
    # degradation for a fault that costs noise.
    #
    # So: keep the behaviour, remove the SILENCE. rc 79 states "this exemption
    # set is INCOMPLETE, not empty" for any caller that cares, and the log
    # line is the artefact that was missing. The one existing caller captures
    # with $( ), so it CAN see the rc — see _idle_list_worker_windows.
    [[ -n "$registry" && -e "$registry" ]] || return 0
    if ! _idle_registry_readable "$registry"; then
        printf 'idle-probe: services registry at %s exists but is NOT READABLE; the infra-window exemption set is INCOMPLETE, so registered service windows may classify as workers (rc 79)\n' \
            "$registry" >&2
        return 79
    fi
    local line name workdir launch health
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        IFS=$'\t' read -r name workdir launch health <<<"$line"
        [[ -z "$name" || -z "$workdir" || -z "$launch" || -z "$health" ]] && continue
        printf '%s\n' "$name"
    done < "$registry"
}

# List every worker window's (name, activity-epoch, index).
# Excludes the configured target window ($TARGET — the orchestrator's
# window, whatever the operator named it), the cockpit window
# ($SERVICES_WINDOW — the `svc.sh` dashboard, default `services`),
# plus the reserved names watcher / claude / orchestrator / monitor by
# convention, AND any window whose name appears in the service registry
# (field 1). Without the $TARGET exclusion, a non-default
# `monitor.target_window` makes the orchestrator's own window classify
# as a worker — it then leaks into the idle pool, the over-limit worker
# scan (double-stamping the same pane as both orchestrator and worker),
# and every other consumer of this lister. The cockpit exclusion is the
# same generalization for infra windows: the `services` window runs
# `svc.sh` (a bash dashboard loop), NOT `claude`, so the pane-state
# probe finds no inner Claude process and would (wrongly) classify it
# `pane-absent` — "relaunch or close" against a healthy cockpit
# (your-org/your-nexus#204). The registry exemption extends this to
# declared infra/service windows (a long-running nginx viewer, a deploy
# watcher): not workers, not idle-swept — their supervised loop, not the
# orchestrator, owns them. The index is required because
# monitor/pane-state.sh takes `<window-index>` or `<session>:<window>` —
# not a window name — so callers need the index to dispatch state
# classification.
# Output: <name>\t<window_activity_epoch>\t<window_index>
_idle_list_worker_windows() {
    command -v tmux >/dev/null 2>&1 || return 0
    local svc_names
    svc_names=$(_idle_registry_service_names)
    # NO status flag is set here, deliberately. An earlier version of this
    # function set IDLE_SVC_EXEMPTIONS_INCOMPLETE on rc 79. It had ZERO readers,
    # and it could not have worked if it had one: every caller of
    # _idle_list_worker_windows invokes it inside `$( )` (main.sh) or
    # `< <( )` (_over_limit.sh), so an assignment in this scope cannot escape
    # to any of them. That is a flag that LOOKS like a guard and is incapable of
    # being one — the same unobservable-verdict class this file's #1266 work is
    # about, so it is removed rather than left to reassure a future reader.
    # The artefact for the incomplete-exemption case is the LOG LINE emitted by
    # _idle_registry_service_names, which does survive a subshell.
    tmux list-windows -F '#{window_name}|#{window_activity}|#{window_index}' 2>/dev/null \
        | awk -F'|' -v target="${TARGET:-orchestrator}" \
              -v cockpit="${SERVICES_WINDOW:-services}" -v svc_list="$svc_names" '
            BEGIN {
                n = split(svc_list, _svc_arr, "\n")
                for (i = 1; i <= n; i++)
                    if (_svc_arr[i] != "") svc[_svc_arr[i]] = 1
            }
            $1 == "" { next }
            $1 ~ /^•/ { next }   # drop transient sandbox-notify •bell windows (see snapshot_local)
            $1 == target { next }
            $1 == cockpit { next }
            $1 == "watcher" || $1 == "claude" || $1 == "orchestrator" || $1 == "monitor" { next }
            $1 in svc { next }
            { printf "%s\t%s\t%s\n", $1, $2, $3 }
        '
}

# Window-name basename heuristic — true iff `report` (a wrap-up
# `report` basename) could plausibly belong to `window` under the
# project-slot or slug-slot conventions. Used as a fallback when an
# action-log entry has no authoritative `window` field (pre-#109).
_idle_basename_matches() {
    local rep="$1" win="$2"
    [[ "$rep" == "${win}_"*    \
       || "$rep" == *"_${win}"* \
       || "$rep" == *"-${win}"* \
       || "$rep" == *"_${win}."* ]]
}

# Locate the most recent `spawn` event for a window. Spawn events are
# recorded by `monitor/spawn-worker.sh` (issue #72) and define the
# birth ts of the window's CURRENT lifecycle. The classifier uses this
# anchor to scope wrap-up matching: a wrap-up event written before the
# spawn ts belongs to a prior life of the same window-name and must
# not be treated as authoritative. Closes the "stale wrap-up survives
# claude --continue" regression (issue #72 regression 3).
#
# Prints the ISO ts of the most recent spawn event on stdout (the same
# `ts` field jq emits); empty stdout when no spawn event exists for
# the window (legacy worker spawned before this anchor was added).
_idle_window_spawn_ts() {
    local window="$1" log_file="${2:-${STATE_DIR}/action-log.jsonl}"
    [[ -f "$log_file" ]] || return 1
    [[ -n "$window" ]]   || return 1
    if command -v jq >/dev/null 2>&1; then
        grep '"event":"spawn"' "$log_file" 2>/dev/null \
            | tac \
            | jq -r --arg w "$window" \
                'select(.window == $w) | .ts' 2>/dev/null \
            | head -1
    else
        # Pure-sed fallback: walk newest-first, find first line whose
        # window matches, extract its ts.
        local line ts entry_window
        while IFS= read -r line; do
            entry_window=$(printf '%s' "$line" | sed -n 's/.*"window":"\([^"]*\)".*/\1/p')
            [[ "$entry_window" == "$window" ]] || continue
            ts=$(printf '%s' "$line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
            [[ -n "$ts" ]] && printf '%s' "$ts"
            return 0
        done < <(grep '"event":"spawn"' "$log_file" 2>/dev/null | tac)
    fi
}

# Locate the action-log's most recent `wrap-up` event for a window.
# Two matching modes, in priority order:
#
#   1. `window` field on the event matches the target window exactly.
#      Authoritative; recorded by `ng wrap-up` from $TMUX since
#      issue #109. No false positives.
#   2. Basename heuristic against `report` field (back-compat for
#      pre-#109 entries that didn't carry `window`):
#
#         Project-slot pattern:  reports/<window>_<ts>_<slug>.md
#         Slug-slot pattern:     reports/<project>_<ts>_*<window>*.md
#
# A worker that wraps multiple times (write report → wrap → expand
# → wrap again with a fresher entry) supersedes the prior match —
# the watcher cares about the LATEST wrap-up for that window. The
# scan is tac'd to walk newest-first; the first match wins.
#
# Lifecycle scoping (issue #72): when the action-log has a `spawn`
# event for the window, only wrap-up entries with `ts >= spawn.ts`
# are considered. A wrap-up from a previous life of the window-name
# (window closed and a fresh worker reused the name; or
# `claude --continue` extended an already-wrapped session) drops out
# of scope automatically, regardless of whether engagement-log was
# pruned. Pre-spawn-event entries (legacy workers) bypass the scope
# check — preserves back-compat at the cost of leaving the original
# stale-wrap-up case open for pre-#72 windows; new spawns are
# covered.
#
# Prints `<basename>\t<ts>` on stdout and returns 0 (`<ts>` is the
# raw ISO-8601 timestamp of the matched entry, or `_NULL_`/empty for
# pre-#109 entries without one); prints nothing and returns 1 on no
# match. Callers that only want the basename use the
# `_idle_window_wrap_up_report` wrapper below.
_idle_window_wrap_up_entry() {
    local window="$1" log_file="${2:-${STATE_DIR}/action-log.jsonl}"
    [[ -f "$log_file" ]] || return 1
    [[ -n "$window" ]]   || return 1
    # Lifecycle anchor: most-recent spawn ts. Empty when no spawn
    # event exists (legacy window) — scope check is skipped in that
    # case.
    local spawn_ts spawn_epoch
    spawn_ts=$(_idle_window_spawn_ts "$window" "$log_file")
    spawn_epoch=0
    if [[ -n "$spawn_ts" ]]; then
        spawn_epoch=$(_idle_iso_to_epoch "$spawn_ts")
        [[ -n "$spawn_epoch" ]] || spawn_epoch=0
    fi
    local entry_window entry_report entry_ts entry_epoch entry_comment
    if command -v jq >/dev/null 2>&1; then
        # `// "_NULL_"` keeps the tab-separated output three-column
        # even when an entry has no `window` field (pre-#109 entries).
        while IFS=$'\t' read -r entry_window entry_report entry_ts entry_comment; do
            [[ -n "$entry_report" ]] || continue
            # CANDIDACY FIRST, LIFECYCLE SCOPE SECOND (your-org/nexus-code#1063).
            # The two predicates are pure and independent, so swapping them
            # cannot change which entry is returned — but the scope check forks
            # `date -d` once per entry (_idle_iso_to_epoch) while the candidacy
            # check is pure bash. With scope first, an entry belonging to some
            # OTHER window still cost a fork before being discarded, making the
            # walk O(windows x ALL historical wrap-ups) — a cost that grows
            # monotonically with the action log and never falls.
            #
            # Measured on the live log 2026-08-26 (3,853,593 bytes, 2,599
            # `"event":"wrap-up"` entries, 5 worker windows): 7,805 of 7,815
            # `date -d` forks per `list_really_idle_workers` came from this one
            # loop — ~11 s per window, 33 s for the sweep, 44 s per
            # `render_idle_prelude`. That is past compose_report's 20 s bound, so
            # `_run_bounded` returned 124 and every emit carried
            # `workspace: UNAVAILABLE`. Not load: retiring a window did not help,
            # because the term that grew was the log, not the window count.
            #
            # #1063 REMOVED THE PER-ENTRY FORK AND LEFT THE PER-ENTRY WALK
            # (your-org/nexus-code#1329). Candidacy-first made each discarded entry
            # cheap; it did not stop the entry being DELIVERED to this loop. bash
            # `read` from a pipe consumes a byte at a time, so the surviving term is
            # O(windows x ALL historical wrap-ups) in read(2) syscalls, and it grows
            # with the log exactly as the fork term did.
            #
            # Measured at 0b82ffb2 against the live action log (7,746,636 bytes,
            # 3,309 `"event":"wrap-up"` entries, 14 worker windows):
            #
            #   _idle_window_spawn_ts        60- 83 ms   filters IN JQ
            #   _idle_window_retain_event  1510-1714 ms  filtered in BASH (3,278 rows)
            #   _idle_window_wrap_up_entry 2490-2930 ms  filtered in BASH (3,309 rows)
            #
            # Same file, same grep, same tac, same jq, same order of magnitude of
            # rows. The ONLY difference is WHERE the window predicate runs — and
            # `_idle_window_spawn_ts`, defined above, is the positive control that
            # was already doing it right.
            #
            # So the SAME candidacy predicate now also runs in the jq producer
            # below. It is a PREFILTER, not a new rule: candidacy is the FIRST test
            # in this loop (that is #1063's ordering, deliberately preserved), so an
            # entry jq drops is an entry this loop would have `continue`d before
            # running any other predicate. The bash arms below are kept verbatim —
            # the non-jq fallback still needs them, and they re-test for free.
            if [[ "$entry_window" != "_NULL_" ]]; then
                # Post-#109: authoritative window field present.
                # Match only on exact equality; skip otherwise.
                [[ "$entry_window" == "$window" ]] || continue
            else
                # Pre-#109: no window field → fall back to basename heuristic.
                _idle_basename_matches "$entry_report" "$window" || continue
            fi
            # Lifecycle scope: skip wrap-ups recorded before the
            # current spawn. Only enforced when we have a spawn
            # anchor (epoch > 0); otherwise we operate as before.
            if (( spawn_epoch > 0 )) && [[ -n "$entry_ts" && "$entry_ts" != "_NULL_" ]]; then
                entry_epoch=$(_idle_iso_to_epoch "$entry_ts")
                if [[ "$entry_epoch" =~ ^[0-9]+$ ]] \
                   && (( entry_epoch < spawn_epoch )); then
                    continue
                fi
            fi
            # your-org/nexus-code#1116 review, F1 — A WRAP-UP THAT PUBLISHED
            # NOTHING IS NOT A WRAP-UP. `ng wrap-up` records its event
            # unconditionally, INCLUDING on the two paths that deliberately
            # publish nothing and exit 3 (`#1114` degenerate-teaser, `#862`
            # nothing-published). This reader used to accept any wrap-up event,
            # so the watcher classified such a window `wrapped` and the cleanup
            # table sent the orchestrator to retire a worker whose answer never
            # reached the thread — the marker of a delivery without the
            # delivery, one layer up from where `#1114` fixed it.
            #
            # SKIP AND KEEP LOOKING, rather than return not-found. An honest
            # idempotent RE-RUN is the normal shape (`#862`: the asset link
            # moved, the body did not), and its newest event is
            # `nothing-published` while an EARLIER event in the same lifecycle
            # did publish. Returning not-found on the newest entry would
            # un-wrap a window that genuinely handed off. So an unpublished
            # entry is passed over and the walk continues; only a lifecycle
            # containing no published wrap-up at all yields not-found.
            #
            # An ABSENT `.comment` is not unpublished — events predating the
            # field carry none, and the newest-first walk must not reject the
            # entire history on a field that did not exist.
            case "$entry_comment" in
                degenerate-teaser|nothing-published) continue ;;
            esac
            printf '%s\t%s' "$entry_report" "$entry_ts"
            return 0
        done < <(grep '"event":"wrap-up"' "$log_file" \
                    | tac \
                    | jq -r --arg w "$window" '
                          (.window // "_NULL_") as $ew
                          | (.report // "") as $r
                          | select($ew == $w
                                   or ($ew == "_NULL_"
                                       and ($r | (startswith($w + "_")
                                                  or contains("_" + $w)
                                                  or contains("-" + $w)
                                                  or contains("_" + $w + ".")))))
                          | [$ew, $r, (.ts // "_NULL_"), (.comment // "")] | @tsv' 2>/dev/null)
        # THE PRE-#109 ARM IS PREFILTERED TOO (your-org/nexus-code#1406). The
        # producer above used to pass EVERY no-window row through — `$ew ==
        # "_NULL_"` was a blanket accept, and the basename test ran in bash,
        # per row, per window. Profiled against the live log (31,957 rows, 8
        # synthetic windows): `_idle_window_wrap_up_entry` + `_idle_basename_matches`
        # were 3,728 + 3,000 traced lines at the full log against 128 + 0 at a
        # 1% tail — the ENTIRE log-size term of `render_idle_prelude`, and the
        # residual `#1063` left behind (it removed the per-row FORK, `#1329`
        # moved the window predicate into jq for rows that HAVE a window; the
        # rows that do not still reached bash one at a time). The four
        # disjuncts are `_idle_basename_matches` verbatim, so the bash arm
        # below re-tests for free and nothing that matched before stops
        # matching now; what changes is that a legacy row belonging to some
        # OTHER window is dropped in jq instead of in a bash `continue`.
    else
        local line
        while IFS= read -r line; do
            entry_report=$(printf '%s' "$line" \
                | sed -n 's/.*"report":"\([^"]*\)".*/\1/p')
            entry_window=$(printf '%s' "$line" \
                | sed -n 's/.*"window":"\([^"]*\)".*/\1/p')
            entry_ts=$(printf '%s' "$line" \
                | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
            [[ -n "$entry_report" ]] || continue
            # Candidacy first, lifecycle scope second — same reordering, same
            # reason, as the jq branch above (your-org/nexus-code#1063). This
            # arm forks `date -d` too, so it carried the same growth term.
            if [[ -n "$entry_window" ]]; then
                [[ "$entry_window" == "$window" ]] || continue
            else
                _idle_basename_matches "$entry_report" "$window" || continue
            fi
            if (( spawn_epoch > 0 )) && [[ -n "$entry_ts" ]]; then
                entry_epoch=$(_idle_iso_to_epoch "$entry_ts")
                if [[ "$entry_epoch" =~ ^[0-9]+$ ]] \
                   && (( entry_epoch < spawn_epoch )); then
                    continue
                fi
            fi
            # Same rule as the jq arm above (your-org/nexus-code#1116 F1);
            # the two arms must agree or the classification depends on
            # whether jq happens to be installed.
            entry_comment=$(printf '%s' "$line" \
                | sed -n 's/.*"comment":"\([^"]*\)".*/\1/p')
            case "$entry_comment" in
                degenerate-teaser|nothing-published) continue ;;
            esac
            printf '%s\t%s' "$entry_report" "$entry_ts"
            return 0
        done < <(grep '"event":"wrap-up"' "$log_file" | tac)
    fi
    return 1
}

# Basename-only view of `_idle_window_wrap_up_entry` — the historical
# interface most callers want. Prints the matching basename on stdout
# and returns 0; prints nothing and returns 1 on no match.
_idle_window_wrap_up_report() {
    local entry
    entry=$(_idle_window_wrap_up_entry "$@") || return 1
    [[ -n "$entry" ]] || return 1
    printf '%s' "${entry%%$'\t'*}"
}

# Locate the action-log's most recent `window-retain` event for a
# window. The event is recorded by the orchestrator via:
#
#     ng log-action monitor --event window-retain \
#         --extra window=<name> --extra reason=<short>
#
# Only the `window` extra matters for matching; the basename
# heuristic used for wrap-up events is intentionally NOT applied
# here — `window-retain` is a post-#109 verb, so we require an
# explicit `window` extra.
#
# Prints `<ts>\t<reason>` on stdout (tab-separated) and returns 0
# on match; prints nothing and returns 1 otherwise. `<ts>` is the
# raw ISO-8601 timestamp from the log entry; the caller is
# responsible for converting to epoch when needed.
_idle_window_retain_event() {
    local window="$1" log_file="${2:-${STATE_DIR}/action-log.jsonl}"
    [[ -f "$log_file" ]] || return 1
    [[ -n "$window" ]]   || return 1
    local entry_window entry_ts entry_reason
    # The window predicate runs in the jq producer, not here — same reason, same
    # measurement, as the wrap-up walk above (your-org/nexus-code#1329). This walk
    # is the SECOND-largest term in `list_really_idle_workers`: 1510-1714 ms per
    # call at 0b82ffb2 against 3,278 `window-retain` entries, purely because 3,277
    # of them reached bash's `read` before being discarded on one string compare.
    # PREMISE CORRECTED (your-org/nexus-code#1329, skeptic item 6b). An earlier
    # version of this comment said `window-retain` REQUIRES an explicit `window`
    # extra, so there was "no absent-field arm to preserve". That is FALSE:
    # measured on the live action log 2026-09-03, **31 of 3,346** `window-retain`
    # entries carry `"window":null` (the wrap-up walk's figure, for contrast, is
    # 75 of 3,377).
    #
    # The CODE was never wrong — only the reason given for it. There IS an
    # absent-field arm, `(.window // "")`, and it DISCARDS rather than preserves:
    # a null window becomes `""`, which cannot equal a real `$window`. That is
    # exactly what the bash test it replaced did, because the `sed` extractor
    # below does not match `"window":null` either and leaves `entry_window`
    # empty. So the jq `select` is still the bash test verbatim — for a different
    # and measurable reason than the one first written down here.
    if command -v jq >/dev/null 2>&1; then
        while IFS=$'\t' read -r entry_window entry_ts entry_reason; do
            [[ "$entry_window" == "$window" ]] || continue
            printf '%s\t%s' "$entry_ts" "$entry_reason"
            return 0
        done < <(grep '"event":"window-retain"' "$log_file" \
                    | tac \
                    | jq -r --arg w "$window" 'select((.window // "") == $w)
                          | [(.window // ""), (.ts // ""), (.reason // "")] | @tsv' 2>/dev/null)
    else
        local line
        while IFS= read -r line; do
            entry_window=$(printf '%s' "$line" \
                | sed -n 's/.*"window":"\([^"]*\)".*/\1/p')
            [[ "$entry_window" == "$window" ]] || continue
            entry_ts=$(printf '%s' "$line" \
                | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
            entry_reason=$(printf '%s' "$line" \
                | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p')
            printf '%s\t%s' "$entry_ts" "$entry_reason"
            return 0
        done < <(grep '"event":"window-retain"' "$log_file" | tac)
    fi
    return 1
}

# Convert an ISO-8601 timestamp (as written by `ng log-action`,
# i.e. `date -Is` form like `2026-05-11T10:11:00-07:00`) to a unix
# epoch. Prints the epoch on stdout; prints nothing on parse
# failure. GNU date only — the watcher runs on Linux.
_idle_iso_to_epoch() {
    local iso="$1"
    [[ -n "$iso" ]] || return 1
    date -d "$iso" +%s 2>/dev/null
}

# Resolve a wrap-up report basename to an absolute path on disk.
# Prefers $NEXUS_ROOT/reports/<basename>; falls back to walking up
# from the watcher's working directory (mirrors `ng report-init`'s
# `_report_reports_dir` lookup). Empty stdout when no candidate
# resolves.
_idle_resolve_report_path() {
    local basename="$1"
    [[ -n "$basename" ]] || return 1
    if [[ -n "${NEXUS_ROOT:-}" && -f "$NEXUS_ROOT/reports/$basename" ]]; then
        printf '%s' "$NEXUS_ROOT/reports/$basename"
        return 0
    fi
    local d
    d=$(pwd)
    while [[ "$d" != / && -n "$d" ]]; do
        if [[ -f "$d/reports/$basename" ]]; then
            printf '%s' "$d/reports/$basename"
            return 0
        fi
        d=$(dirname "$d")
    done
    return 1
}

# Run `ng report-check <path>` quietly. Returns 0 on pass, 1 on
# fail; prints the failing-fields summary on stdout (single line,
# `;`-joined) so the caller can include it in the emit line.
_idle_run_report_check() {
    local path="$1" ng
    if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/ng" ]]; then
        ng="$NEXUS_ROOT/monitor/ng"
    elif [[ -x "$(dirname "${BASH_SOURCE[0]}")/../ng" ]]; then
        ng=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ng
    else
        return 0  # no ng available → skip (treat as pass)
    fi
    local err
    if err=$("$ng" report-check "$path" 2>&1 >/dev/null); then
        return 0
    fi
    # Collapse the multi-line stderr to a single ;-joined summary;
    # drop the leading "ng report-check: ..." header and the
    # `incomplete:` label.
    printf '%s' "$err" \
        | grep -E '^[[:space:]]*-[[:space:]]' \
        | sed -e 's/^[[:space:]]*-[[:space:]]*//' \
        | tr '\n' ';' \
        | sed 's/;\+$//; s/^;\+//'
    return 1
}

# Read pane-state via monitor/pane-state.sh and print the bare
# `state=` key on stdout (one of {idle, busy, user-typing,
# autosuggest-only, empty, blocked, absent}, or `unknown` if the
# script couldn't run). The helper takes a window INDEX (or
# session:window pair) — not a name — so callers pass the index
# discovered by _idle_list_worker_windows.
#
# NEXUS_ROOT may be unset in tests; resolve pane-state.sh from
# this file's own directory then /monitor.
_idle_pane_state_get() {
    local window_index="$1"
    local line
    line=$(_idle_pane_state_line "$window_index")
    [[ -n "$line" ]] || { printf 'unknown'; return 0; }
    local state
    state=$(printf '%s' "$line" | sed -n 's/.*state=\([a-z-]*\).*/\1/p')
    printf '%s' "${state:-unknown}"
}

# Same call as `_idle_pane_state_get` but returns the FULL emit line
# (state + active + window + name [+ reset_at when over-limit]) so the
# caller can pull additional fields (issue #87: `reset_at` plumbing for
# over-limit classification). Empty stdout on resolver failure.
#
# Shared-recording chokepoint (your-org/nexus-code#562): when
# `_pane_cache.sh` is loaded (main.sh sources it; standalone test
# sourcing may not), a fresh recording of this window from the current
# sweep loop is served instead of re-forking pane-state.sh, and a
# direct fork's result is recorded for the other assessments to reuse.
# Optional $2 is the expected window NAME — guards against a reused
# window index serving another window's recording. Fail-open on every
# cache condition; MONITOR_PANE_CACHE_MODE=record (the authoritative
# idle sweep) always forks fresh.
_idle_pane_state_line() {
    local window_index="$1" expected_name="${2:-}"
    if declare -F _pane_cache_read >/dev/null 2>&1; then
        local _pc_line
        if _pc_line=$(_pane_cache_read "$window_index" "$expected_name"); then
            printf '%s\n' "$_pc_line"
            return 0
        fi
    fi
    local pane_state_script
    if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/pane-state.sh" ]]; then
        pane_state_script="$NEXUS_ROOT/monitor/pane-state.sh"
    elif [[ -x "$(dirname "${BASH_SOURCE[0]}")/../pane-state.sh" ]]; then
        pane_state_script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pane-state.sh
    else
        return 0
    fi
    local hb_args=()
    if [[ -n "${MONITOR_HEARTBEAT_STALENESS_SECONDS:-}" ]] \
        && [[ "$MONITOR_HEARTBEAT_STALENESS_SECONDS" =~ ^[0-9]+$ ]]; then
        hb_args+=(--heartbeat-staleness "$MONITOR_HEARTBEAT_STALENESS_SECONDS")
    fi
    # Tell pane-state.sh WHICH window is the orchestrator, so its §1b
    # over-limit rule can consult the orchestrator activity marker for that
    # pane and no other (your-org/nexus-code#1155 residual 2).
    #
    # WITHOUT THIS THE RULE WORKED BY A DUPLICATED LITERAL, not by a mechanism,
    # and that is measured rather than reasoned (`#1171` skeptic finding 2,
    # re-derived here by a different method than the one that produced it).
    # Every production call site of pane-state.sh builds a FIXED argv — this
    # array had exactly ONE append site, and retire-preflight.sh /
    # cc-auto-update-apply.sh / ng pass a bare positional — so no caller could
    # carry the flag. The env fallbacks were dead too: the RUNNING watcher
    # (pid 15542, 2026-08-28) had BOTH `MONITOR_TARGET` and
    # `NEXUS_ORCHESTRATOR_WINDOW` unset in `/proc/<pid>/environ`. So
    # pane-state.sh fell to its literal default `orchestrator`, which matched
    # the real window only because `_config.sh`'s `monitor.target_window`
    # default is the same word in a different file.
    #
    # Two literals that agree until one moves is the #1143 defect this PR is
    # about, so it does not get to survive inside the fix for it. `$TARGET` is
    # the RESOLVED value (env override, then config, then default) and is in
    # scope here because `_config.sh` is sourced before this file.
    if [[ -n "${TARGET:-}" ]]; then
        hb_args+=(--orchestrator-window "$TARGET")
    fi
    # your-org/nexus-code#1397: an EMPTY read is an INSTRUMENT outcome, not a
    # pane property, and it used to be indistinguishable from pane-state.sh's
    # own `state=unknown` — stderr was discarded and the rc never read, so a
    # renderer that timed out, a probe that failed, and a classifier that
    # genuinely could not decide all rendered `(state=unknown)`. Measured: one
    # pane read `state=unknown` in four consecutive snapshots over an hour
    # while a direct `pane-state.sh` read said `working-background`, with no
    # stderr on either side. When the probe yields NO line, this now prints a
    # DIAGNOSTIC line instead: `probe=failed probe_rc=<n> probe_stderr=<txt>`.
    # It carries NO `state=` key on purpose — every consumer parses `state=`
    # and treats its absence exactly as it treated an empty line (unknown /
    # emit), so nothing downstream changes except that the snapshot can now
    # SAY which of the two happened. The stderr excerpt is sanitised to a
    # charset that cannot spell `=`, so a diagnostic can never forge a field.
    local _ps_line _ps_rc=0 _ps_errf="" _ps_err=""
    _ps_errf=$(mktemp "${TMPDIR:-/tmp}/pane-probe-err.XXXXXX" 2>/dev/null) || _ps_errf=""
    if [[ -n "$_ps_errf" ]]; then
        _ps_line=$("$pane_state_script" "${hb_args[@]}" "$window_index" 2>"$_ps_errf"); _ps_rc=$?
        _ps_err=$(head -c 200 "$_ps_errf" 2>/dev/null | tr '\n' ' ' | tr -c 'A-Za-z0-9 ._:/,()-' '_')
        rm -f "$_ps_errf"
    else
        _ps_line=$("$pane_state_script" "${hb_args[@]}" "$window_index" 2>/dev/null); _ps_rc=$?
    fi
    if [[ -n "$_ps_line" ]] && declare -F _pane_cache_write >/dev/null 2>&1; then
        _pane_cache_write "$window_index" "$_ps_line"
    fi
    if [[ -n "$_ps_line" ]]; then
        printf '%s\n' "$_ps_line"
    else
        _ps_err="${_ps_err#"${_ps_err%%[! ]*}"}"; _ps_err="${_ps_err%"${_ps_err##*[! ]}"}"
        printf 'probe=failed probe_rc=%s probe_stderr=%s\n' "$_ps_rc" "${_ps_err:-none}"
    fi
    return 0
}

# _idle_bg_membership_turnover <window> <digest>
#
# Compare pane-state's `bg_members` digest for <window> with the one recorded
# on the previous tick (your-org/nexus-code#1460). Prints ONE token:
#   changed        the digest differs from the recorded one — a descendant
#                  started or exited; a wedge cannot do that
#   static:<secs>  identical to the recorded one, unchanged for <secs>
#   first          a digest was seen but nothing was recorded yet
#   absent         no digest on the line (older pane-state, or an override)
# State: $STATE_DIR/bg-members/<window> = "<digest>\t<epoch first seen>".
# Cleared when the digest is absent, so a window that stops reporting starts
# fresh rather than inheriting a stale "static" reading.
_idle_bg_membership_turnover() {
    local window="$1" digest="${2:-}" dir="${STATE_DIR:-}/bg-members" f prev prev_at now
    if [[ -z "$digest" || "$digest" == "-" ]]; then
        [[ -n "${STATE_DIR:-}" ]] && rm -f "$dir/$window" 2>/dev/null
        printf 'absent'; return 0
    fi
    [[ -n "${STATE_DIR:-}" ]] || { printf 'first'; return 0; }
    f="$dir/$window"; now=$(date +%s)
    mkdir -p "$dir" 2>/dev/null || { printf 'first'; return 0; }
    if [[ -f "$f" ]]; then
        IFS=$'\t' read -r prev prev_at < "$f" 2>/dev/null || prev=""
        if [[ "$prev" == "$digest" && "$prev_at" =~ ^[0-9]+$ ]]; then
            printf 'static:%d' $(( now - prev_at )); return 0
        fi
        printf '%s\t%s\n' "$digest" "$now" > "$f" 2>/dev/null
        [[ -n "$prev" ]] && { printf 'changed'; return 0; }
        printf 'first'; return 0
    fi
    printf '%s\t%s\n' "$digest" "$now" > "$f" 2>/dev/null
    printf 'first'
}


# Extract `field=<token>` from a pane-state emit line. Empty stdout on
# miss. Used by the over-limit path to pull `reset_at` from the same
# subprocess invocation that produced the state token.
_idle_pane_line_field() {
    local line="$1" field="$2"
    [[ -n "$line" && -n "$field" ]] || return 1
    printf '%s' "$line" | sed -n "s/.*${field}=\\([^ ]*\\).*/\\1/p"
}

# ---- turn-failure (interrupted-mid-turn) marker -------------------------
#
# A worker turn that dies to an API/model error fires the StopFailure
# hook (NOT Stop), and `monitor/hooks/turn-failure-emit.sh` writes
# `$STATE_DIR/turn-failure/<window>.json`. Its presence (and freshness)
# is what separates an *interrupted-mid-turn* worker (process alive,
# empty box, paste resumes) from a *done-but-forgot-to-wrap* worker
# (also idle, also empty box, but a clean Stop fired and no marker
# exists). The classifier reads it to emit `interrupted` with the
# recovery verb instead of nagging "no-wrap-up".
#
# Freshness gate: the Stop hook clears the marker on the next
# successful turn, so a lingering marker normally means the worker is
# still stalled. But a missed clear (jq absent, unwritable dir,
# window-name reuse across a respawn) must not wedge a window forever
# — so we also require the marker's `ts` to be within
# MONITOR_TURN_FAILURE_STALENESS_SECONDS (default 1800 s, matching the
# Stop-anchored heartbeat staleness). An older marker is treated as
# absent; the window falls back to the normal wrap-up classification.
_turn_failure_path() {
    printf '%s/turn-failure/%s.json' "${STATE_DIR:-$(_ip_nostate_dir)}" "$1"
}

# _idle_turn_failure_fresh <window> <now> → exit 0 if a fresh marker
# exists, else 1. "Fresh" = file exists, parseable, and ts within the
# staleness window.
_idle_turn_failure_fresh() {
    local window="$1" now="$2"
    local f staleness ts
    f=$(_turn_failure_path "$window")
    [[ -f "$f" ]] || return 1
    staleness="${MONITOR_TURN_FAILURE_STALENESS_SECONDS:-1800}"
    [[ "$staleness" =~ ^[0-9]+$ ]] || staleness=1800
    if command -v jq >/dev/null 2>&1; then
        ts=$(jq -r '.ts // empty' "$f" 2>/dev/null) || return 1
    else
        ts=$(grep -oE '"ts"[[:space:]]*:[[:space:]]*[0-9]+' "$f" 2>/dev/null \
                | grep -oE '[0-9]+' | tail -1)
    fi
    [[ "$ts" =~ ^[0-9]+$ ]] || return 1
    local age=$(( now - ts ))
    (( age >= 0 )) || age=0
    (( age <= staleness )) || return 1
    return 0
}

# _idle_turn_failure_field <window> <field> → print a scalar field
# (category / recovery / error) from the marker, empty on miss.
_idle_turn_failure_field() {
    local window="$1" field="$2" f
    f=$(_turn_failure_path "$window")
    [[ -f "$f" ]] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$field" '.[$k] // empty' "$f" 2>/dev/null
    else
        grep -oE "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$f" 2>/dev/null \
            | sed -E 's/.*"([^"]*)"$/\1/' | tail -1
    fi
}

# Path of the engagement-log artifact. One row per worker window
# the watcher has ever observed in a `busy` or `user-typing` state
# this session: `<window>\t<last-engagement-epoch>`. Consulted by
# the retain-consume gate; written by the probe inside the main
# loop. Missing file or missing row is meaningful — see
# _engagement_log_lookup.
_engagement_log_path() {
    printf '%s/engagement-log.tsv' "${STATE_DIR:-$(_ip_nostate_dir)}"
}

# Print the last-engagement epoch for `window`. Prints nothing
# (empty stdout, exit 0) when there is no row — the caller treats
# that as "no engagement since beginning of time," i.e. the
# strongest possible retain-survives signal. We deliberately do
# NOT default to `0` inside the helper so the caller can
# distinguish "never engaged" from "engaged at unix epoch 0".
_engagement_log_lookup() {
    local window="$1" path
    path=$(_engagement_log_path)
    [[ -f "$path" ]] || return 0
    awk -F'\t' -v w="$window" '$1 == w { print $2; exit }' "$path"
}

# Stamp `<window>\t<epoch>` into the engagement-log, replacing any
# prior row for the same window so the file stays at-most-one-row-
# per-window. Atomic enough for the watcher's single-threaded poll
# (rewrite to a tmp file, then rename).
_engagement_log_stamp() {
    local window="$1" epoch="$2" path tmp
    path=$(_engagement_log_path)
    [[ -n "$window" && -n "$epoch" ]] || return 1
    mkdir -p "$(dirname "$path")"
    tmp=$(mktemp "${path}.XXXXXX")
    if [[ -f "$path" ]]; then
        awk -F'\t' -v w="$window" '$1 != w' "$path" > "$tmp"
    fi
    printf '%s\t%s\n' "$window" "$epoch" >> "$tmp"
    mv "$tmp" "$path"
}

# Drop any engagement-log row for `window`. Atomic rewrite + rename
# matching _engagement_log_stamp. Silent no-op when the file or the
# row is absent. Used by the per-cycle disappearance pruner so that
# a future resumption of the same window-name takes PR #46's
# fresh-row backfill path (no row → stamp NOW) instead of inheriting
# the prior life's epoch and immediately tripping the idle gate
# (issue #61).
_engagement_log_drop() {
    local window="$1" path tmp
    [[ -n "$window" ]] || return 1
    path=$(_engagement_log_path)
    [[ -f "$path" ]] || return 0
    tmp=$(mktemp "${path}.XXXXXX")
    awk -F'\t' -v w="$window" '$1 != w' "$path" > "$tmp"
    mv "$tmp" "$path"
}

# ---- operator-engaged marks (issues #196, #201) ---------------------------
#
# Detect that the OPERATOR is driving a worker window — wrapped or
# never-wrapped — and hold a per-window "engaged" mark for the rest
# of that window's lifecycle. The consumers:
#
#   - list_really_idle_workers classifies a marked idle window as
#     `operator-engaged` (a single deduped informational row) instead
#     of `wrapped` / `no-wrap-up`, so conversation think-gaps longer
#     than MONITOR_IDLE_THRESHOLD_SECONDS stop re-emitting
#     "idle … WITHOUT wrap-up — consider follow-up paste" every round.
#   - render_pending_decisions withholds `idle_prompt` decision rows
#     for marked windows (the turn-end pings of an operator chat are
#     not decisions the orchestrator must ack).
#   - The window-cleanup policy treats `operator-engaged` as
#     do-not-close, so an operator-driven window can't be retired.
#   - list_idle_transitions emits a low-frequency `engaged-close-
#     reminder` row once the operator has been away for a full
#     reminder period (below) — the only surface a lingering
#     operator window gets.
#
# State file `operator-engaged.tsv`, one row per window:
#
#   <window>\t<since>\t<last>\t<prompt_seen>\t<src>\t<reminded>
#
#   since       — epoch the current engagement episode started
#   last        — epoch of the last engagement-compatible observation
#   prompt_seen — epoch of the last PROCESSED user-prompt stamp
#                 (0 = none yet). The seed below fires only when the
#                 window's user-prompt stamp is newer than this, so
#                 each submit is attributed exactly once. (Pre-
#                 hook-trigger rows stored the idle-stretch start
#                 here; any such epoch predates every post-deploy
#                 stamp, so old rows converge harmlessly.)
#   src         — seed source: submit | submit-after-wrap (legacy
#                 rows may still carry typing | busy-after-wrap |
#                 busy-after-prompt from the pane-transition era)
#   reminded    — epoch of the last close-reminder emit (0 = never).
#                 Missing column (pre-#201 rows) reads as 0.
#
# Seed (CREATE) — hook-driven, the ONLY way a mark is created:
#
#   * user-prompt submit (issues #201 + the hook-trigger revision):
#     the worker's UserPromptSubmit hook stamped
#     `user-prompt/<window>` with an epoch newer than the row's
#     `prompt_seen` — someone SUBMITTED INPUT to this window. The
#     stamp is a contract event from Claude Code itself (fires the
#     instant a prompt is submitted, operator typing+Enter or
#     orchestrator paste alike); no pane content is read, so the
#     tmux-2.6 TUI character-rewriting that distorts capture-pane
#     output cannot distort the trigger. Attribution decides whose
#     submit it was:
#
#       The submit is the ORCHESTRATOR'S (no seed) iff a known
#       machine input for the window — an action-log
#       `paste-followup` event (stamped by monitor/paste-followup.sh
#       or `ng log-action … --event paste-followup --extra
#       window=W`), a machine-input.tsv row (stamped by the
#       watcher's own unstick Enter-nudges), or the window's `spawn`
#       event (launcher prompt / --resume continuation nudge) —
#       carries an epoch ≥ prompt_epoch − MONITOR_OPERATOR_ENGAGED_
#       INPUT_SLACK_SECONDS (default 120; the slack absorbs clock
#       skew between the stamp writers — paste-followup.sh stamps
#       BEFORE pasting, so its epoch normally precedes the hook's
#       by well under a second). A machine-claimed submit REGRESSES
#       the window to busy (the #205 state-machine follow-up): the
#       engagement-log is stamped at the submit epoch (resetting the
#       idle-age anchor and consuming any standing window-retain, so
#       the window reads as working again even if the busy turn falls
#       between probe cycles), and the submit epoch is recorded in
#       machine-submit/<window> so a wrap-up OLDER than it is treated
#       as superseded by the classifier (the worker was re-tasked;
#       it owes a fresh wrap-up, not a stale "wrapped" row).
#
#       Otherwise the submit is the OPERATOR'S iff it is CORROBORATED
#       by observed pane-content change within the decay TTL
#       (your-org/your-nexus#205 follow-up — this REPLACES #270's
#       fragile one-frame `user-typing` corroboration). The per-window
#       pane-change stamp's `last_change_epoch` (the last cycle the
#       transcript-region hash actually differed) must be
#       ≥ prompt_epoch − MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS
#       (default 600). A genuine submit makes the agent answer, which
#       grows the transcript and advances the change epoch within a
#       cycle; the submit may land one probe BEFORE that answer
#       renders, so corroboration is AWAITED up to the TTL.
#
#       An operator-attributed submit with NO corroborating change for
#       the whole TTL — a redraw artifact / phantom — is consumed
#       without marking. Why change instead of a bright-text read:
#       Claude Code's TUI redraws heavily distort `capture-pane`, so a
#       one-frame bright marker is missed when a person really is
#       typing and occasionally fabricated by a redraw; sustained
#       change across the much larger transcript region is far harder
#       to fake or miss. And crucially, even a mis-seeded mark now
#       SELF-EXPIRES (see EXPIRE), so the cost of an over-seed is a
#       transient suppression, never a window pinned open.
#
#     src=submit-after-wrap when the window has a current-lifecycle
#     wrap-up older than the submit (the #196 special case, kept
#     for observability); src=submit otherwise. An orchestrator
#     that pastes without stamping defeats the attribution — its
#     paste still fires the worker's UserPromptSubmit hook —
#     monitor/paste-followup.sh is the canonical paste path for
#     exactly this reason. The stamp is consumed (`prompt_seen` :=
#     stamp epoch) once attribution resolves (marked, machine-claimed,
#     or artifact-timed-out); it stays unconsumed only during the
#     bounded await for corroboration.
#
#   Pane-state's role is REFRESH-ONLY (soft fallback): a busy /
#   working-background / working-self-paced observation can extend an
#   existing fresh mark's `last` (the away-phase clock), never create a
#   mark. `user-typing` is excluded even here — that bright-marker read
#   is the unreliable signal #270 over-trusted. The idle→busy
#   pane-transition seed is long gone for the same reason.
#
#   REFRESH — while the mark is fresh (within the grace): a newer
#     CORROBORATED operator-attributed user-prompt stamp bumps `last`
#     to the stamp epoch; a busy / working-background /
#     working-self-paced pane observation bumps `last` to now (soft
#     liveness, refresh only). The change clock that gates VALIDITY is
#     refreshed separately, every cycle, from the content hash.
#     CRUCIALLY, attribution re-runs on every newer submit, mark present
#     or not: a newer MACHINE-attributed submit (paste-followup /
#     unstick / spawn within slack) REGRESSES an existing mark to busy —
#     it zeroes the mark fields, not merely `prompt_seen` — so a
#     correctly-stamped orchestrator relay landing on an already-marked
#     window can SELF-HEAL a stale/mis-seeded operator mark (bug B; live
#     incident 2026-06-18). Without this, REFRESH bumped `prompt_seen`
#     while leaving `since`/`src` intact, and a properly machine-stamped
#     paste was structurally incapable of clearing the mark.
#   EXPIRE (THE part-A self-expiry; your-org/your-nexus#205 follow-up)
#     — `_openg_marked` holds the mark VALID only while the pane has
#     changed within MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS. Once
#     the pane goes static past the TTL (operator stepped away, or the
#     mark was an artifact), the mark LAPSES and the window returns to
#     its normal retire-eligibility — every suppression surface drops
#     it at once. This is the non-negotiable bias toward RELEASE: a
#     window is never pinned open indefinitely on a stale/false mark.
#   AWAY (close reminder; issue #201) — a SEPARATE soft clock on `last`
#     (last operator submit): when a mark is kept VALID by sustained
#     change but the operator hasn't submitted for
#     MONITOR_OPERATOR_ENGAGED_GRACE_SECONDS (default 1800), the
#     episode is "away". While away < MONITOR_OPERATOR_ENGAGED_CLOSE_
#     REMINDER_SECONDS (default 86400) nothing emits; once away ≥ that
#     period, list_idle_transitions emits ONE "consider closing"
#     reminder per period (`reminded` stamps the cadence). A returning
#     operator-attributed submit re-seeds and resets `reminded`. (With
#     the change-TTL far below the grace, most abandoned windows EXPIRE
#     before they can go away; this reminder is the surface for the
#     narrow case of a window the agent keeps changing on the
#     operator's behalf without fresh submits.)
#   INVALIDATE — an `engaged-done` or spawn event NEWER than `since`
#     kills the mark immediately (regardless of change): `engaged-done`
#     is the agent's explicit finished-signal for an interactive
#     session (`ng engaged-done`, prompted by `ng wrap-up`'s
#     interactive-wrap clarification — the #205 state-machine
#     follow-up), and a fresh spawn is a new lifecycle. A WRAP-UP no
#     longer invalidates: an interactive session that wraps stays
#     engaged by default, because the operator may have follow-up
#     inquiries; the self-expiry (EXPIRE above) still bounds an
#     abandoned mark to the change TTL, so "stay engaged by default"
#     can never pin a window open indefinitely.
#   PRUNE — rows for disappeared windows are dropped alongside the
#     engagement-log rows in the per-cycle disappearance pruner;
#     the window's user-prompt and pane-change stamp files are
#     removed there too.
#
# Note the marked short-circuit runs before the idle-too-long
# override: a VALID (change-corroborated) operator-engaged window does
# not trip the runaway-window alarm; once it expires, idle-too-long
# applies normally again.

_openg_path() {
    printf '%s/operator-engaged.tsv' "${STATE_DIR:-$(_ip_nostate_dir)}"
}

_openg_grace_seconds() {
    local g="${MONITOR_OPERATOR_ENGAGED_GRACE_SECONDS:-}"
    if [[ ! "$g" =~ ^[0-9]+$ ]]; then
        g=""
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
            g=$("$NEXUS_ROOT/config/load.sh" monitor.operator_engaged_grace_seconds 1800 2>/dev/null || echo 1800)
        fi
        [[ "$g" =~ ^[0-9]+$ ]] || g=1800
    fi
    printf '%s' "$g"
}

# Cadence of the "operator away — consider closing" reminder
# (issue #201). Also the away-time floor before the FIRST reminder.
_openg_reminder_seconds() {
    local r="${MONITOR_OPERATOR_ENGAGED_CLOSE_REMINDER_SECONDS:-}"
    if [[ ! "$r" =~ ^[0-9]+$ ]]; then
        r=""
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
            r=$("$NEXUS_ROOT/config/load.sh" monitor.operator_engaged_close_reminder_seconds 86400 2>/dev/null || echo 86400)
        fi
        [[ "$r" =~ ^[0-9]+$ ]] || r=86400
    fi
    printf '%s' "$r"
}

# Attribution slack for the user-prompt-submit seed: a machine-input
# stamp this many seconds OLDER than the submit's hook epoch still
# claims the submit. Absorbs clock skew between the stamp writers;
# over-claiming only delays an operator seed to the operator's next
# message.
_openg_input_slack_seconds() {
    local s="${MONITOR_OPERATOR_ENGAGED_INPUT_SLACK_SECONDS:-120}"
    [[ "$s" =~ ^[0-9]+$ ]] || s=120
    printf '%s' "$s"
}

# Ledger of watcher-side machine inputs into worker panes (unstick
# Enter-nudges and the like): append-only rows `<window>\t<epoch>\t<src>`,
# written by _unstick.sh via the MACHINE_INPUT_TSV global and by
# monitor/paste-followup.sh. Compacted by the per-cycle pruner.
_machine_input_path() {
    printf '%s/machine-input.tsv' "${STATE_DIR:-$(_ip_nostate_dir)}"
}

# Per-window "last user-prompt submitted" stamp, written by
# monitor/worker-heartbeat.sh from the worker's UserPromptSubmit
# hook (`<epoch>\t<session-id>`). THE engagement trigger.
_user_prompt_stamp_path() {
    printf '%s/user-prompt/%s' "${STATE_DIR:-$(_ip_nostate_dir)}" "$1"
}

# Epoch of the newest user-prompt submit stamped for `window`;
# prints `0` when no stamp exists (window never submitted to since
# the hook started stamping, or the stamp was pruned with the
# window). Deterministic contract data — never pane content.
_openg_user_prompt_epoch() {
    local window="$1" path e
    [[ -n "$window" ]] || { printf '0'; return 0; }
    path=$(_user_prompt_stamp_path "$window")
    [[ -f "$path" ]] || { printf '0'; return 0; }
    e=$(awk -F'\t' 'NR == 1 { print $1; exit }' "$path" 2>/dev/null)
    [[ "$e" =~ ^[0-9]+$ ]] || e=0
    printf '%s' "$e"
}

# Session-id column of the newest user-prompt submit stamped for
# `window`. worker-heartbeat.sh writes the stamp as
# `<epoch>\t<session-id>` — the session-id is claude's OWN session
# (the hook fires inside the pane's Claude Code process), so it
# identifies WHICH session submitted the prompt. Empty stdout +
# non-zero when no stamp / no session-id column.
_openg_user_prompt_session() {
    local window="$1" path sid
    [[ -n "$window" ]] || return 1
    path=$(_user_prompt_stamp_path "$window")
    [[ -f "$path" ]] || return 1
    sid=$(awk -F'\t' 'NR == 1 { print $2; exit }' "$path" 2>/dev/null)
    [[ -n "$sid" ]] || return 1
    printf '%s' "$sid"
}

# The window's OWN spawn session-id — the `--session-id` UUID
# spawn-worker.sh generates at birth (your-org/your-nexus#206) and
# records in the provenance record `windows/<window>.json`
# (`.session_id`). Primary source is that record; a spawn action-log
# `session-id=` extra is the fallback for a window whose provenance
# JSON is absent. Empty stdout + non-zero when neither is available
# (loop-wrapper workers take no `--session-id`, so their own session
# is unknowable here — the self-classification simply does not fire,
# falling back to the pre-existing attribution). The window-name is
# sanitized identically to spawn-worker.sh's `_write_provenance_record`.
_openg_window_own_session() {
    local window="$1" f sid=""
    [[ -n "$window" ]] || return 1
    f="${STATE_DIR:-$(_ip_nostate_dir)}/windows/$(wk_encode "$window").json"
    if [[ -f "$f" ]]; then
        if command -v jq >/dev/null 2>&1; then
            sid=$(jq -r '.session_id // empty' "$f" 2>/dev/null) || sid=""
        else
            sid=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)
        fi
    fi
    if [[ -z "$sid" ]]; then
        # Fallback: newest spawn action-log event's `session-id=` extra.
        local log_file="${STATE_DIR:-$(_ip_nostate_dir)}/action-log.jsonl"
        if [[ -f "$log_file" ]] && command -v jq >/dev/null 2>&1; then
            sid=$(grep '"event":"spawn"' "$log_file" 2>/dev/null | tac \
                | jq -r --arg w "$window" \
                    'select(.window == $w) | .["session-id"] // empty' 2>/dev/null \
                | head -1) || sid=""
        fi
    fi
    [[ -n "$sid" ]] || return 1
    printf '%s' "$sid"
}

# TRUE when `window`'s newest user-prompt submit was stamped with the
# window's OWN spawn session-id — provably machine/self input, NOT the
# operator. The operator drives a DIFFERENT Claude Code session and
# never types into a spawned worker's pane, so a submit carrying the
# worker's own session-id is autosuggest / post-wrap typing / the
# worker's own tool loop (the coembed-283-followup false positive,
# 2026-07-17). Requires BOTH ids present AND equal — any doubt (a
# missing stamp session-id, an unknown own session-id) returns FALSE,
# so the pre-existing attribution stays in force and a genuine operator
# submit (a DIFFERENT session-id) is never misclassified as self.
_openg_prompt_is_self() {
    local window="$1" stamp_sid own_sid
    [[ -n "$window" ]] || return 1
    stamp_sid=$(_openg_user_prompt_session "$window") || return 1
    own_sid=$(_openg_window_own_session "$window") || return 1
    [[ -n "$stamp_sid" && -n "$own_sid" && "$stamp_sid" == "$own_sid" ]]
}

# Remove `window`'s user-prompt stamp (disappearance prune). A
# reused window-name then starts from "no submit yet" instead of
# inheriting the prior life's stamp.
_user_prompt_stamp_drop() {
    local window="$1"
    [[ -n "$window" ]] || return 1
    rm -f "$(_user_prompt_stamp_path "$window")" 2>/dev/null || true
}

# Decay TTL for the change-corroboration signal (your-org/your-nexus#205
# follow-up). THE knob that makes the operator-engaged mark
# self-expiring and bias toward RELEASE. A present-mark stays valid
# only while the pane has CHANGED (transcript content) within this many
# seconds; once the pane has been static past the TTL the mark lapses
# and the window returns to its normal retire-eligibility. The same
# TTL bounds create/refresh corroboration: an operator-attributed
# submit not accompanied by observed pane change within the TTL is
# treated as a redraw artifact and never marks.
#
# Must span at least a couple watcher cycles (default cycle 60 s) so a
# normal think-pause — operator reading a long answer, composing the
# next message — doesn't drop a real session. Default 600 (10 min):
# generous for think-pauses (and a real submit re-corroborates the
# instant the agent answers), yet short enough that a stale or false
# mark releases the window within minutes instead of pinning it open
# for the 24 h away-grace. Env: MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS;
# config: monitor.operator_engaged_change_ttl_seconds.
_openg_change_ttl_seconds() {
    local t="${MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS:-}"
    if [[ ! "$t" =~ ^[0-9]+$ ]]; then
        t=""
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
            t=$("$NEXUS_ROOT/config/load.sh" monitor.operator_engaged_change_ttl_seconds 600 2>/dev/null || echo 600)
        fi
        [[ "$t" =~ ^[0-9]+$ ]] || t=600
    fi
    printf '%s' "$t"
}

# Per-window pane-content-change stamp (your-org/your-nexus#205
# follow-up): `<last_hash>\t<last_change_epoch>`. `last_hash` is the
# most recent `content_hash` pane-state.sh reported for the window;
# `last_change_epoch` is the epoch that hash last DIFFERED from the
# prior one (or first-sight). Updated every cycle by _openg_observe
# from the pane-state line's `content_hash=` field. THE corroboration
# substrate: sustained change keeps a mark valid, stasis lets it lapse.
# Replaces #270's fragile one-frame `user-typing` (typing-observed)
# stamp — a screen read distorted by TUI redraws must not be the
# load-bearing signal for holding a window open.
_openg_change_path() {
    printf '%s/pane-change/%s' "${STATE_DIR:-$(_ip_nostate_dir)}" "$1"
}

# Epoch the pane content last changed for `window`; `0` when no stamp
# exists (never observed with a hash, or pruned with the window).
# Callers read 0 as "no corroboration" — which, per the release bias,
# means the mark does NOT hold.
_openg_change_epoch() {
    local window="$1" path e
    [[ -n "$window" ]] || { printf '0'; return 0; }
    path=$(_openg_change_path "$window")
    [[ -f "$path" ]] || { printf '0'; return 0; }
    e=$(awk -F'\t' 'NR == 1 { print $2; exit }' "$path" 2>/dev/null)
    [[ "$e" =~ ^[0-9]+$ ]] || e=0
    printf '%s' "$e"
}

# Record this cycle's pane content hash for `window` at `now`,
# advancing `last_change_epoch` to `now` iff the hash DIFFERS from the
# stored one (or there was no stored one — first sight counts as a
# change so a freshly-observed window starts corroborated). A repeated
# (identical) hash leaves `last_change_epoch` frozen — that frozen
# epoch is exactly what lets a static pane's mark age out. Forgiving:
# any failure skips the stamp, never the caller.
_openg_change_stamp() {
    local window="$1" hash="$2" now="$3" path tmp prev_hash prev_epoch new_epoch
    [[ -n "$window" && -n "$hash" && "$now" =~ ^[0-9]+$ ]] || return 0
    path=$(_openg_change_path "$window")
    prev_hash=""; prev_epoch=0
    if [[ -f "$path" ]]; then
        IFS=$'\t' read -r prev_hash prev_epoch < "$path" 2>/dev/null
        [[ "$prev_epoch" =~ ^[0-9]+$ ]] || prev_epoch=0
    fi
    if [[ "$hash" == "$prev_hash" ]]; then
        new_epoch="$prev_epoch"
    else
        new_epoch="$now"
    fi
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
    tmp="${path}.$$.tmp"
    if printf '%s\t%s\n' "$hash" "$new_epoch" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# Mark `window`'s pane content changed AT `now` without a hash to
# compare — used when pane-state took the heartbeat-authoritative
# busy/working fast path and emitted no `content_hash` (no capture
# taken), yet the agent is demonstrably working (the transcript IS
# streaming). Keeps the change clock fresh through a long busy stretch
# so a genuinely-working window's mark isn't aged out by the absence
# of a hash. Preserves the stored hash so the next real comparison is
# still anchored.
_openg_change_touch() {
    local window="$1" now="$2" path tmp prev_hash prev_epoch
    [[ -n "$window" && "$now" =~ ^[0-9]+$ ]] || return 0
    path=$(_openg_change_path "$window")
    prev_hash=""
    [[ -f "$path" ]] && IFS=$'\t' read -r prev_hash prev_epoch < "$path" 2>/dev/null
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
    tmp="${path}.$$.tmp"
    if printf '%s\t%s\n' "$prev_hash" "$now" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# Remove `window`'s pane-change stamp (disappearance prune),
# mirroring _user_prompt_stamp_drop.
_openg_change_drop() {
    local window="$1"
    [[ -n "$window" ]] || return 1
    rm -f "$(_openg_change_path "$window")" 2>/dev/null || true
}

# Per-window "last MACHINE-attributed user-prompt submit" stamp (the
# #205 state-machine follow-up): bare `<epoch>`, written by
# _openg_observe's machine branch when the attribution rule claims a
# submit for the orchestrator. THE wrap-up supersession substrate: the
# classifier treats a wrap-up OLDER than this epoch as stale — the
# orchestrator re-tasked the worker after its hand-off, so the window
# regresses to the normal busy → no-wrap-up lifecycle.
_machine_submit_stamp_path() {
    printf '%s/machine-submit/%s' "${STATE_DIR:-$(_ip_nostate_dir)}" "$1"
}

# Epoch of the newest machine-attributed submit for `window`; `0`
# when none recorded (window never received an orchestrator-claimed
# submit, or the stamp was pruned with the window).
_openg_machine_submit_epoch() {
    local window="$1" path e
    [[ -n "$window" ]] || { printf '0'; return 0; }
    path=$(_machine_submit_stamp_path "$window")
    [[ -f "$path" ]] || { printf '0'; return 0; }
    e=$(awk 'NR == 1 { print $1; exit }' "$path" 2>/dev/null)
    [[ "$e" =~ ^[0-9]+$ ]] || e=0
    printf '%s' "$e"
}

# Record a machine-attributed submit at `epoch`. Forgiving: any
# failure skips the stamp, never the caller.
_machine_submit_stamp_write() {
    local window="$1" epoch="$2" path tmp
    [[ -n "$window" && "$epoch" =~ ^[0-9]+$ ]] || return 0
    path=$(_machine_submit_stamp_path "$window")
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
    tmp="${path}.$$.tmp"
    if printf '%s\n' "$epoch" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# Remove `window`'s machine-submit stamp (disappearance prune),
# mirroring _user_prompt_stamp_drop.
_machine_submit_stamp_drop() {
    local window="$1"
    [[ -n "$window" ]] || return 1
    rm -f "$(_machine_submit_stamp_path "$window")" 2>/dev/null || true
}

# Epoch of the newest known MACHINE input delivered to `window`'s
# pane, across all three stamp sources:
#   1. action-log `paste-followup` events (orchestrator follow-up
#      pastes via monitor/paste-followup.sh or ng log-action),
#   2. machine-input.tsv rows (watcher-internal sends + the paste
#      helper's authoritative direct stamp),
#   3. the window's `spawn` event (launcher prompt; `--resume`
#      continuation nudges ride the respawn's spawn event).
# Prints `0` when none. A user-prompt submit whose epoch is ≤ this
# epoch + slack is explained as machine input; see the section
# header's attribution rule.
_openg_machine_input_epoch() {
    local window="$1" best=0 e ts
    [[ -n "$window" ]] || { printf '0'; return 0; }
    local log_file="${STATE_DIR:-$(_ip_nostate_dir)}/action-log.jsonl"
    if [[ -f "$log_file" ]]; then
        if command -v jq >/dev/null 2>&1; then
            ts=$(grep '"event":"paste-followup"' "$log_file" 2>/dev/null \
                | tac \
                | jq -r --arg w "$window" \
                    'select(.window == $w) | .ts' 2>/dev/null \
                | head -1)
        else
            ts=""
            local line entry_window
            while IFS= read -r line; do
                entry_window=$(printf '%s' "$line" \
                    | sed -n 's/.*"window":"\([^"]*\)".*/\1/p')
                [[ "$entry_window" == "$window" ]] || continue
                ts=$(printf '%s' "$line" \
                    | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
                break
            done < <(grep '"event":"paste-followup"' "$log_file" 2>/dev/null | tac)
        fi
        if [[ -n "$ts" ]]; then
            e=$(_idle_iso_to_epoch "$ts")
            [[ "$e" =~ ^[0-9]+$ ]] && (( e > best )) && best=$e
        fi
    fi
    local mi
    mi=$(_machine_input_path)
    if [[ -f "$mi" ]]; then
        e=$(awk -F'\t' -v w="$window" \
            '$1 == w && $2 ~ /^[0-9]+$/ && ($2 + 0) > m { m = $2 + 0 } END { print m + 0 }' \
            "$mi" 2>/dev/null)
        # SECONDS. This function is pure comparison — it never keys a
        # sidecar — and it takes a MAX across three sources, the other
        # two of which are ISO timestamps in seconds. Letting a raw
        # microsecond key in would make `best` ~1e6x every clock reading
        # it is mixed with and, at the call site, put EVERY operator
        # submit inside the machine-input window: the attribution rule
        # would silently reclassify the operator's own typing as a
        # machine paste (your-org/nexus-code#679).
        e=$(_paste_epoch_seconds "$e")
        [[ "$e" =~ ^[0-9]+$ ]] && (( e > best )) && best=$e
    fi
    ts=$(_idle_window_spawn_ts "$window")
    if [[ -n "$ts" ]]; then
        e=$(_idle_iso_to_epoch "$ts")
        [[ "$e" =~ ^[0-9]+$ ]] && (( e > best )) && best=$e
    fi
    printf '%s' "$best"
}

# ---- your-org/nexus-code#683: is the newest machine input ADMINISTRATIVE? --
#
# Prints `1` when the machine input covering `epoch_sec` was pasted with
# `--administrative`, else nothing. An administrative follow-up asks for
# no new work, so it must not consume the window's standing
# `window-retain` and must not supersede an older wrap-up.
#
# Keyed off the ledger's column 4, compared at SECONDS granularity
# because that is the unit the caller's `machine` epoch is in (`#679`).
# The `>=` is deliberate: `_openg_machine_input_epoch` takes a MAX
# across three sources and the TSV row that WON that max is the one
# whose marker applies. A row strictly newer than the resolved epoch
# cannot exist (the resolver would have returned it), so `>=` selects
# exactly the winning row and ties resolve to administrative.
#
# FAIL-SAFE DIRECTION. Absence of a marker — a pre-#683 3-column row, a
# row from any other writer, an unreadable ledger — yields nothing, i.e.
# RE-TASK, which is today's behaviour. So this can only ever stop
# consuming a retain that a genuine re-task would have consumed; it can
# never manufacture a superseded wrap-up. Getting it wrong in the other
# direction would HIDE a real re-task, which is the failure `#683`'s own
# test note warns about ("a fix that only suppresses is a fix that hides
# real re-tasks").
_openg_machine_input_administrative() {
    local window="$1" epoch_sec="$2" mi hit
    [[ -n "$window" && "$epoch_sec" =~ ^[0-9]+$ ]] || return 0
    (( epoch_sec > 0 )) || return 0
    mi=$(_machine_input_path)
    [[ -f "$mi" ]] || return 0
    hit=$(awk -F'\t' -v w="$window" -v e="$epoch_sec" \
        '$1 == w && $2 ~ /^[0-9]+$/ && $4 == "admin" {
             v = $2 + 0
             if (v >= 10000000000000) v = int(v / 1000000)
             if (v >= e) { found = 1 }
         }
         END { if (found) print "1" }' \
        "$mi" 2>/dev/null)
    [[ "$hit" == "1" ]] && printf '1'
    return 0
}

# ---- injection ↔ hook pairing validation (the #205 state-machine
# follow-up) ----------------------------------------------------------
#
# The attribution rule above answers "whose was this submit?". The
# inverse defect — an orchestrator paste that never BECAME a submit —
# was previously invisible: paste-followup.sh stamps the ledger, the
# paste lands in the pane, but the Enter is swallowed (VI mode, an
# overlay, a race with a redraw) and the worker's UserPromptSubmit hook
# never fires. The orchestrator believes the worker was nudged; the
# worker sits idle on queued text. The `paste-unconfirmed` class
# surfaces exactly that: a guaranteed-submit paste older than the
# confirm grace with NO user-prompt stamp at-or-after it.
#
# Scope guards (each suppresses the flag, biasing toward silence):
#   - only `paste-followup` stamps count — unstick Enter-nudges submit
#     only IF text is queued, and `--no-enter` pastes (ledger src
#     `paste-followup-no-enter`; action-log `no_enter=1`) deliberately
#     don't submit, so neither implies a hook MUST have fired;
#   - the window must have a live heartbeat file (hooks demonstrably
#     installed) — a hook-less legacy worker can never confirm a paste;
#   - the paste must belong to the current spawn lifecycle.

# Confirm grace: how long after a guaranteed-submit paste the probe
# waits for the UserPromptSubmit stamp before flagging. The hook fires
# sub-second in practice; the grace only needs to absorb a slow cycle.
# Env: MONITOR_PASTE_CONFIRM_GRACE_SECONDS; config:
# monitor.paste_confirm_grace_seconds. Default 180 (3 probe cycles).
_paste_confirm_grace_seconds() {
    local g="${MONITOR_PASTE_CONFIRM_GRACE_SECONDS:-}"
    if [[ ! "$g" =~ ^[0-9]+$ ]]; then
        g=""
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
            g=$("$NEXUS_ROOT/config/load.sh" monitor.paste_confirm_grace_seconds 180 2>/dev/null || echo 180)
        fi
        [[ "$g" =~ ^[0-9]+$ ]] || g=180
    fi
    printf '%s' "$g"
}

# Epoch of the newest UNCONFIRMED guaranteed-submit paste for `window`,
# or `0` when every paste is confirmed (or out of scope per the guards
# above, or simply too recent to judge). `now` is supplied by the
# caller's sweep so one cycle shares one clock.
# How far the action-log `paste-followup` timestamp trails the moment the
# paste actually began (your-org/nexus-code#665). The event is appended
# after the paste completes and its outcome is known; measured at 1-2s on
# this operator. Only used on the fallback path, where the pre-paste TSV
# stamp is unavailable — the TSV needs no correction because it is taken
# before the keystrokes go out.
: "${_PASTE_LOG_LAG_SECONDS:=5}"

# ---- your-org/nexus-code#679: two granularities, one recorded value ---
#
# `machine-input.tsv` column 2 and the `#676` verdict sidecar name are a
# KEY: they must be unique per paste, so since `#679` they are recorded
# in MICROSECONDS. Every other consumer compares the value against a
# different clock reading — the hook stamp, the transcript's submission
# records, the window's spawn timestamp, the "paste NNNs ago" the emit
# renders — and all of those are SECONDS.
#
# So a raw key must never reach an arithmetic comparison. It fails in the
# quiet direction: a microsecond key is ~1e6x any seconds value, so
# `(( best < spawn_epoch ))` goes permanently false and the lifecycle
# scope guard stops rejecting pastes from a prior life of the window
# name, while `(( now >= epoch ))` goes permanently false and the age
# note silently vanishes. Nothing errors; the guards just stop guarding.
#
# Normalising by MAGNITUDE rather than by a format flag is what keeps the
# append-only ledger readable across the change: rows written before
# `#679` are seconds and live in the same file forever. The two ranges
# are five orders of magnitude apart with no plausible overlap — a
# seconds epoch stays under 1e10 until the year 2286, a microseconds
# epoch passed 1e15 in 2001 — so 1e13 sits in empty space between them.
_PASTE_EPOCH_US_FLOOR=10000000000000
_paste_epoch_seconds() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
    if (( v >= _PASTE_EPOCH_US_FLOOR )); then
        printf '%s' "$(( v / 1000000 ))"
    else
        printf '%s' "$v"
    fi
}

_idle_unconfirmed_paste_epoch() {
    local window="$1" now="$2" best=0 e ts
    [[ -n "$window" && "$now" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
    # Hooks must demonstrably work for this window — the heartbeat
    # file is written by the same worker-heartbeat.sh that writes the
    # user-prompt stamp, so its absence means "cannot confirm",
    # not "unconfirmed".
    [[ -f "${STATE_DIR:-$(_ip_nostate_dir)}/heartbeat/$window.json" ]] || { printf '0'; return 0; }
    # Newest guaranteed-submit paste epoch.
    #
    # The TWO surfaces are NOT interchangeable, and treating them as such
    # is your-org/nexus-code#665. `machine-input.tsv` is stamped BEFORE
    # the keystrokes go out (paste-followup.sh:418, immediately before the
    # send-keys); the `action-log.jsonl` event is appended AFTER the paste
    # has completed and its outcome is known (step 4, ~1-2s later).
    #
    # The old code took the MAX of the two, which deliberately selects the
    # post-paste one — and the target's own submission record lands
    # BETWEEN them. So every check on the most recent paste compared the
    # submission against an epoch later than the submission itself:
    #
    #   submission record   2026-08-02T23:53:58.439Z   (transcript)
    #   action-log ts       2026-08-02T23:53:59Z       (max → chosen)
    #                       ^ 0.56s later, so `>= epoch` rejects the
    #                         paste's OWN record and the detector fires
    #
    # Measured that way on 2026-08-02: `nexus-dashboard-prune` -0.56s,
    # `nexus-dashsk` -0.24s, and `nexuscode-burndown2` -1.2s. Older pastes
    # looked confirmed only because some LATER submission cleared the bar
    # for them, which is why the false positive always lands on the most
    # recent paste — the one an operator is most likely to be waiting on.
    #
    # So: the TSV is AUTHORITATIVE for attribution. paste-followup.sh says
    # so in as many words at its own action-log append — "the TSV stamp
    # above is what the attribution rule keys on". The action-log is an
    # audit trail; it is consulted ONLY as a fallback when the TSV has no
    # row for this window, and it can no longer push the epoch later than
    # the moment the paste actually began.
    local mi
    mi=$(_machine_input_path)
    if [[ -f "$mi" ]]; then
        e=$(awk -F'\t' -v w="$window" \
            '$1 == w && $3 == "paste-followup" && $2 ~ /^[0-9]+$/ && ($2 + 0) > m { m = $2 + 0 } END { print m + 0 }' \
            "$mi" 2>/dev/null)
        [[ "$e" =~ ^[0-9]+$ ]] && (( e > best )) && best=$e
    fi
    if (( best == 0 )); then
        local log_file="${STATE_DIR:-$(_ip_nostate_dir)}/action-log.jsonl"
        if [[ -f "$log_file" ]] && command -v jq >/dev/null 2>&1; then
            ts=$(grep '"event":"paste-followup"' "$log_file" 2>/dev/null \
                | tac \
                | jq -r --arg w "$window" \
                    'select(.window == $w) | select((.no_enter // "") != "1") | .ts' 2>/dev/null \
                | head -1)
            if [[ -n "$ts" ]]; then
                e=$(_idle_iso_to_epoch "$ts")
                # POST-paste by construction, so it overstates the start
                # instant. Back it off by the observed paste duration
                # before using it for attribution — an epoch that is too
                # LATE manufactures exactly the false positive above,
                # while one that is slightly too early can only ever
                # accept a submission that really did follow this paste.
                [[ "$e" =~ ^[0-9]+$ ]] && (( e > _PASTE_LOG_LAG_SECONDS )) \
                    && e=$(( e - _PASTE_LOG_LAG_SECONDS ))
                [[ "$e" =~ ^[0-9]+$ ]] && (( e > best )) && best=$e
            fi
        fi
    fi
    (( best > 0 )) || { printf '0'; return 0; }
    # `best` stays the RAW recorded value from here on, because that is
    # the sidecar key and `#676` rests on sender and watcher deriving
    # the name from the same recorded value. `best_sec` is the seconds
    # view for every comparison against another clock. See
    # `_paste_epoch_seconds` above for why both are needed.
    local best_sec
    best_sec=$(_paste_epoch_seconds "$best")
    (( best_sec > 0 )) || { printf '0'; return 0; }
    # Lifecycle scope: a paste older than the current spawn belongs to
    # a prior life of the window-name.
    local spawn_ts spawn_epoch
    spawn_ts=$(_idle_window_spawn_ts "$window")
    if [[ -n "$spawn_ts" ]]; then
        spawn_epoch=$(_idle_iso_to_epoch "$spawn_ts")
        if [[ "$spawn_epoch" =~ ^[0-9]+$ ]] && (( best_sec < spawn_epoch )); then
            printf '0'; return 0
        fi
    fi
    # Confirmed? paste-followup.sh stamps BEFORE pasting, so the hook
    # stamp lands at-or-after the ledger epoch (same host, same clock).
    local prompt_epoch
    prompt_epoch=$(_openg_user_prompt_epoch "$window")
    (( prompt_epoch >= best_sec )) && { printf '0'; return 0; }
    # Too recent to judge — the hook may still be about to fire.
    local grace
    grace=$(_paste_confirm_grace_seconds)
    (( now - best_sec >= grace )) || { printf '0'; return 0; }

    # ---- second evidence surface (your-org/nexus-code#607) ------------
    #
    # Everything above rests on ONE surface: the UserPromptSubmit hook
    # stamp. That surface cannot distinguish "the paste was lost" from
    # "the paste was QUEUED behind an in-flight turn", because a queued
    # message fires no submit event until the running turn drains — and
    # turns here routinely exceed the 180s grace. The emit that follows
    # a false positive advises a RE-PASTE, which duplicates completed
    # work: on 2026-07-29 a four-part verification brief that the target
    # had demonstrably answered in full (four report sections, titled to
    # match, appended after the paste) was flagged `paste-unconfirmed`,
    # and re-pasting would have re-run a finished adversarial pass.
    #
    # `paste-followup.sh` has always judged against a SECOND surface —
    # the target's own transcript, Claude Code's authoritative ledger.
    # Consult it here too, so the sender and the watcher reach the same
    # verdict from the same evidence.
    #
    # Three-valued on purpose. `unknown` (no transcript, no jq, or a
    # file larger than the scan bound) must NOT be read as "not
    # submitted": that would be the same over-claim in a new place. It
    # falls through to the hook-stamp verdict, i.e. today's behaviour,
    # so this can only ever REMOVE false positives — never add one, and
    # never suppress the genuine-loss path that is the reason this
    # detector exists.
    # ---- the SENDER's own recorded verdict (your-org/nexus-code#665) --
    #
    # Consulted BEFORE the transcript re-scan, because it is better
    # evidence and it is free. paste-followup.sh polled the target's
    # transcript at paste time, while the turn was fresh and the
    # session-id was known-current; we are reading the same transcript
    # minutes later through `heartbeat/<window>.json`, whose session-id
    # can have rotated under a resume or a compaction. When the sender
    # says rc 0 it OBSERVED a submission record. Evidence of presence
    # does not expire — a later failure to re-find it is our problem,
    # not proof the submission never happened.
    #
    # This is the fix for the shape #668 left open. On 2026-08-02 the
    # detector fired 11 times with 0 true positives; both fully
    # documented decisive cases (a dashboard rewritten 10s after the
    # paste, a freshness stamp whose four specified corrections all
    # landed) were pastes the sender had recorded as `submitted`.
    #
    # Only rc 0 suppresses. rc 3 ("could not establish either" — the
    # plausibly-QUEUED case) deliberately does NOT: a paste genuinely
    # lost during an in-flight turn must still be catchable, so it
    # falls through to the surfaces below and is reported with hedged
    # wording (see _idle_paste_verdict_note). rc 4 is the established
    # negative this detector exists for and must never suppress.
    #
    # A missing/unreadable sidecar is `unknown` and changes nothing.
    # ---- the CONTENT MARKER (your-org/nexus-code#665 item 1) ----------
    #
    # Every surface above and below asks a question that is ADJACENT to
    # the one being decided. The sender's verdict is about a 20s window;
    # `_idle_paste_consumed` is about an epoch ordering. Neither is about
    # THESE BYTES. So a paste that was genuinely lost, in a window whose
    # worker submitted anything else afterwards, was suppressed — the
    # residual `#665` named, and this issue's own defect class (a check
    # that asserts a proxy rather than the property) living inside its
    # own fix.
    #
    # The sender now stamps the digest of the exact canonical bytes beside
    # the paste record; this resolves consumption by MATCHING it in the
    # target's transcript. Both delivery spellings are searched, because a
    # queued paste writes only the `queue-operation` one — see
    # monitor/_submit_evidence.sh, where both the shapes and the one
    # channel transform (TAB → four spaces) are recorded as measurements.
    #
    # Recorded ON DISK for the emit renderer, NOT in a shell global. The
    # emit site calls this function through `$(…)`, so everything it
    # assigns dies with the command-substitution subshell — a global
    # would have read empty in production while testing green in-process.
    # A file survives the subshell, and the scan reads up to 8 MB of
    # transcript, so recomputing in the renderer would double the cost of
    # every cycle a `paste-unconfirmed` row persists.
    local marker marker_verdict=""
    marker=$(_idle_paste_marker "$window" "$best")
    if [[ -n "$marker" ]]; then
        marker_verdict=$(_idle_paste_content_consumed "$window" "$best_sec" "$marker")
    fi
    _idle_paste_scan_write "$window" "$best" "$marker_verdict" ""
    # PROOF of arrival: sha256 over the canonical bytes cannot be
    # satisfied by unrelated content.
    [[ "$marker_verdict" == "yes" ]] && { printf '0'; return 0; }

    local sender_rc
    sender_rc=$(_idle_paste_verdict "$window" "$best")
    # ORDERING, deliberate: the sender's rc 0 still suppresses even when
    # the marker did not match. It is not the proxy #665 indicts — it is a
    # 20s observation taken at paste time, against a known-current
    # session-id, and `#676`'s argument applies unchanged (evidence of
    # presence does not expire; a later failure to re-find it is our
    # problem). The marker replaces the LOOSE minutes-later temporal scan
    # below, which is where the false negative actually lived. What would
    # change this: a demonstrated case of rc 0 being recorded for a paste
    # whose bytes never arrived.
    [[ "$sender_rc" == "0" ]] && { printf '0'; return 0; }

    # A marker was recorded and the scan COMPLETED without finding it.
    # Do NOT fall through to the temporal proxy: its `yes` on unrelated
    # traffic is precisely the false negative this block exists to
    # remove, and consulting it here would reinstate it. Record what the
    # proxy would have said, because "the window submitted something
    # else, but not this" is the single most informative thing the emit
    # can tell an operator, and it is newly knowable.
    if [[ "$marker_verdict" == "no" ]]; then
        _idle_paste_scan_write "$window" "$best" "$marker_verdict" \
            "$(_idle_paste_consumed "$window" "$best_sec")"
        printf '%s' "$best"
        return 0
    fi

    local consumed
    # SECONDS: se_submission_since compares against `date -d "$ts" +%s`
    # off the transcript, so a raw microsecond key here would make every
    # submission look older than the paste and the surface would answer
    # `no` for a paste that was demonstrably consumed — a false positive
    # manufactured by a unit, in the one surface that exists to remove them.
    consumed=$(_idle_paste_consumed "$window" "$best_sec")
    [[ "$consumed" == "yes" ]] && { printf '0'; return 0; }
    printf '%s' "$best"
}

# The content-scan record `_idle_unconfirmed_paste_epoch` leaves for the
# emit renderer, keyed by the same (window, epoch) as the sidecar so it
# can never be read for a different paste. Lives in `paste-verdicts/` on
# purpose: `_paste_verdict_drop` already sweeps `<window>.*`, so this
# inherits both the disappearance prune and the retention bound rather
# than growing a second unpruned directory.
#
# REWRITTEN EVERY CYCLE the marker block is reached, and DELETED when
# there is no marker — a stale `no` from a previous cycle would render an
# emit clause about a scan nobody ran.
_idle_paste_scan_path() {
    printf '%s/paste-verdicts/%s.%s.scan' "${STATE_DIR:-$(_ip_nostate_dir)}" "$1" "$2"
}

_idle_paste_scan_write() {
    local window="$1" epoch="$2" verdict="$3" other="$4" path tmp
    [[ -n "$window" && "$epoch" =~ ^[0-9]+$ ]] || return 0
    path=$(_idle_paste_scan_path "$window" "$epoch")
    if [[ -z "$verdict" ]]; then
        rm -f "$path" 2>/dev/null
        return 0
    fi
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
    tmp="$path.$$.tmp"
    if printf 'verdict=%s\nother=%s\n' "$verdict" "$other" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

_idle_paste_scan_field() {
    local path
    path=$(_idle_paste_scan_path "$1" "$2")
    [[ -r "$path" ]] || return 0
    awk -F= -v k="$3" '$1 == k { print $2; exit }' "$path" 2>/dev/null
}

# One clause for the emit's detail field, naming what the CONTENT surface
# established. Empty when there is nothing new to say — no marker, or a
# marker whose scan could not complete, in which case the pre-#665 wording
# is still the honest one.
#
# Never asserts non-delivery. `no` means "these bytes are not in the part
# of the transcript we could read", which is a stronger statement than the
# old surface could make and still not proof that the paste was lost.
_idle_paste_marker_note() {
    local window="$1" epoch="$2" verdict other
    verdict=$(_idle_paste_scan_field "$window" "$epoch" verdict)
    case "$verdict" in
        no)
            other=$(_idle_paste_scan_field "$window" "$epoch" other)
            if [[ "$other" == "yes" ]]; then
                printf 'content marker: this window DID submit other content after the paste, but the pasted bytes themselves appear in no delivery record — the two are no longer conflated, and this is the shape a genuinely lost paste takes'
            else
                printf 'content marker: the pasted bytes appear in no delivery record in the scanned transcript, and neither does any other submission'
            fi
            ;;
        *) : ;;
    esac
}

# Sidecar written by paste-followup.sh step 3b, keyed by the same epoch
# it stamped into machine-input.tsv. Prints the recorded exit code
# (0 submitted / 3 unconfirmed / 4 established-negative), or NOTHING
# when there is no verdict to read — absence is `unknown`, never `no`.
_idle_paste_verdict_path() {
    printf '%s/paste-verdicts/%s.%s' "${STATE_DIR:-$(_ip_nostate_dir)}" "$1" "$2"
}

_idle_paste_verdict() {
    local window="$1" epoch="$2" path rc
    [[ -n "$window" && "$epoch" =~ ^[0-9]+$ ]] || return 0
    path=$(_idle_paste_verdict_path "$window" "$epoch")
    [[ -r "$path" ]] || return 0
    rc=$(awk -F= '$1 == "rc" { print $2; exit }' "$path" 2>/dev/null)
    [[ "$rc" =~ ^[0-9]+$ ]] || return 0
    printf '%s' "$rc"
}

# The CONTENT MARKER the sender stamped beside the paste
# (your-org/nexus-code#665 item 1). Same sidecar, same key, written
# BEFORE the paste — so a sender that died mid-poll still leaves one,
# and the `rc` line may legitimately be absent while this is present.
# Prints nothing when there is no marker to read; absence is `unknown`,
# and the caller must fall back rather than conclude anything.
_idle_paste_marker() {
    local window="$1" epoch="$2" path d
    [[ -n "$window" && "$epoch" =~ ^[0-9]+$ ]] || return 0
    path=$(_idle_paste_verdict_path "$window" "$epoch")
    [[ -r "$path" ]] || return 0
    d=$(awk -F= '$1 == "digest" { print $2; exit }' "$path" 2>/dev/null)
    [[ "$d" =~ ^[0-9a-f]{64}$ ]] || return 0
    printf '%s' "$d"
}

# Human-readable provenance for the emit's detail field, so the
# operator sees WHICH surface is uncertain rather than a flat
# assertion. Empty when the sender left no verdict.
#
# TENSE IS LOAD-BEARING (#676 skeptic F1). The argument this whole
# change rests on — evidence of presence does not expire — is
# ASYMMETRIC. Evidence of ABSENCE does expire: it says nothing about
# any later instant. A verdict established at paste time is rendered
# here at ≥ the confirm grace (180s) and usually far later, and in
# between the retry-Enter path, the operator, or a drained turn may
# have submitted the text. So every note is stamped with WHEN the
# sender looked, and says only what it looked at.
#
# The first draft of the rc=4 note read "the text is sitting unsent in
# the input box", appended to an emit reworded specifically to STOP
# asserting a negative — asserting an established non-delivery and
# denying one in the same sentence. It also over-reached: rc=4
# establishes no submission record, no transcript growth and an
# unchanged session-id. It measures the TRANSCRIPT. It never observed
# where the bytes are, and the input box is a claim about pane
# contents that nothing in the verdict looked at.
#
# `now` is optional and supplied by the caller's sweep so one cycle
# shares one clock; when given, the note states how long ago the
# sender's observation was taken.
_idle_paste_verdict_note() {
    local window="$1" epoch="$2" now="${3:-}" rc age="" epoch_sec
    # `epoch` is dual-use in this one function: the RAW key names the
    # sidecar, the SECONDS view drives the age. Reading the raw key as
    # seconds sends `now >= epoch` permanently false and the age note
    # silently disappears — no error, just a quieter message
    # (your-org/nexus-code#679).
    rc=$(_idle_paste_verdict "$window" "$epoch")
    [[ -n "$rc" ]] || return 0
    epoch_sec=$(_paste_epoch_seconds "$epoch")
    if [[ "$now" =~ ^[0-9]+$ ]] && (( now >= epoch_sec )) && (( epoch_sec > 0 )); then
        age=" ($(( now - epoch_sec ))s ago)"
    fi
    case "$rc" in
        3) printf 'sender could not establish either outcome when it pasted%s — the transcript grew with no submission record, so the text was plausibly QUEUED behind an in-flight turn; not re-checked since' "$age" ;;
        4) printf 'sender observed no submission in the transcript when it pasted%s and the session stayed inert; NOT re-checked since, so this says nothing about whether it submitted afterwards' "$age" ;;
        *) : ;;
    esac
}

# Drop paste verdicts for `window` (disappearance prune), and sweep
# entries older than the retention bound so the directory cannot grow
# without limit. Mirrors the other per-window `_*_drop` helpers.
: "${_PASTE_VERDICT_RETAIN_DAYS:=7}"
_paste_verdict_drop() {
    local window="$1" dir="${STATE_DIR:-$(_ip_nostate_dir)}/paste-verdicts"
    [[ -d "$dir" ]] || return 0
    if [[ -n "$window" ]]; then
        rm -f -- "$dir/$window".* 2>/dev/null || true
    fi
    find "$dir" -maxdepth 1 -type f -mtime "+$_PASTE_VERDICT_RETAIN_DAYS" \
        -delete 2>/dev/null || true
}

# Transcript-evidence probe, resolved through the shared
# monitor/_submit_evidence.sh so the watcher and paste-followup.sh
# cannot disagree about what a TUI submission is. Degrades to `unknown`
# (never to `no`) whenever the library or its inputs are unavailable —
# an unreadable surface is not evidence of absence.
_idle_load_submit_evidence() {
    declare -F se_submission_since >/dev/null 2>&1 && return 0
    local se_lib=""
    if [[ -n "${NEXUS_ROOT:-}" && -r "$NEXUS_ROOT/monitor/_submit_evidence.sh" ]]; then
        se_lib="$NEXUS_ROOT/monitor/_submit_evidence.sh"
    elif [[ -r "$(dirname "${BASH_SOURCE[0]}")/../_submit_evidence.sh" ]]; then
        se_lib=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_submit_evidence.sh
    fi
    [[ -n "$se_lib" ]] || return 1
    # shellcheck source=monitor/_submit_evidence.sh
    source "$se_lib" || return 1
    return 0
}

_idle_paste_consumed() {
    local window="$1" epoch="$2"
    _idle_load_submit_evidence || { printf 'unknown'; return 0; }
    se_submission_since "$window" "${STATE_DIR:-$(_ip_nostate_dir)}" "$epoch"
}

# CONTENT-identity probe: are the exact bytes this paste carried present
# in the target's transcript at or after it? `yes` / `no` / `unknown`,
# with the same degrade-never-lie posture as _idle_paste_consumed.
_idle_paste_content_consumed() {
    local window="$1" epoch="$2" digest="$3"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { printf 'unknown'; return 0; }
    _idle_load_submit_evidence || { printf 'unknown'; return 0; }
    declare -F se_submission_with_digest >/dev/null 2>&1 \
        || { printf 'unknown'; return 0; }
    se_submission_with_digest "$window" "${STATE_DIR:-$(_ip_nostate_dir)}" "$epoch" "$digest"
}

# Drop machine-input rows for `window` (disappearance prune), and
# opportunistically compact the append-only ledger to one max-epoch
# row per window once it grows past 200 lines. Single writer (the
# watcher cycle), so the rewrite is race-free in practice; atomic
# rename keeps concurrent readers consistent.
# ---- your-org/nexus-code#677: persist the classification emits ---------
#
# Every classification this probe computes — `paste-unconfirmed`, `no-wrap-up`,
# `wrapped`, `idle-too-long`, `retained`, … — was rendered into the row the
# watcher prints to the orchestrator and then DISCARDED. Nothing wrote it to
# `action-log.jsonl` or to `watcher.log`. So the accuracy of every detector in
# this file was unmeasurable after the fact: the only way to establish a base
# rate was for an operator to watch emits scroll past and tally by hand, which
# is literally how `#665` was found (11 false positives, 0 true, counted live).
# Two agents have since needed emit history to answer a question about a
# detector and neither could get it — the `#676` skeptic could prove that PR's
# mechanism but not its frequency, because the emits it needed left no trace.
#
# TRANSITION-ONLY, and that is load-bearing rather than an optimisation. A
# window sitting `no-wrap-up` for six hours would otherwise write thousands of
# identical rows; the log would then answer "what was the state" while being
# useless for "how often did this FIRE", which is the question both agents
# actually had. One row per state CHANGE makes firings countable.
#
# Cheap and additive by construction: it changes no decision, only makes the
# decisions reviewable.
_idle_class_stamp_path() {
    printf '%s/idle-class/%s' "${STATE_DIR:-$(_ip_nostate_dir)}" "$1"
}

_idle_class_stamp_drop() {
    local window="$1"
    [[ -n "$window" ]] || return 0
    rm -f "$(_idle_class_stamp_path "$window")" 2>/dev/null || true
}

# Record a classification IF it differs from the last one recorded for this
# window. Best-effort: never flips the caller's exit code and never gates the
# row that is being rendered — a probe that stopped emitting rows because its
# audit trail failed would be a far worse defect than the missing trail.
#
# That best-effort posture is exactly what `#685` warns about (a broken emit is
# indistinguishable from a working one), so this is covered by a BEHAVIOURAL
# test that the row reaches disk with its fields — `test-idle-classification.sh`
# — not by a source assertion.
_idle_record_classification() {
    local window="$1" cls="$2" detail="${3:-}"
    [[ -n "$window" && -n "$cls" ]] || return 0
    local log_file="${STATE_DIR:-}/action-log.jsonl"
    [[ -n "${STATE_DIR:-}" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local stamp prev=""
    stamp=$(_idle_class_stamp_path "$window")
    [[ -f "$stamp" ]] && prev=$(cat "$stamp" 2>/dev/null)
    # No transition -> no row. This is the whole point; see the header.
    [[ "$prev" == "$cls" ]] && return 0

    local json
    json=$(jq -cn \
        --arg ts "$(date -Is)" \
        --arg window "$window" \
        --arg cls "$cls" \
        --arg prev "$prev" \
        --arg detail "$detail" \
        '{ts:$ts, agent:"watcher", event:"idle-classification",
          window:$window, cls:$cls,
          prev:(if $prev == "" then "-" else $prev end)}
         + (if $detail != "" then {detail:$detail} else {} end)' 2>/dev/null) || return 0
    [[ -n "$json" ]] || return 0

    mkdir -p "$(dirname "$stamp")" 2>/dev/null || return 0
    # NB the subshell: a REDIRECTION failure is reported by the SHELL, not by
    # `printf`, so a bare `>> "$f" 2>/dev/null` still leaks "Permission denied"
    # to stderr — which in the watcher is operator-visible noise from a path
    # that is supposed to be silent. Caught by the unwritable-log assertion.
    ( printf '%s\n' "$json" >> "$log_file" ) 2>/dev/null || return 0
    # Advance the stamp ONLY after the row is on disk. If the append failed,
    # the next cycle retries rather than silently recording a transition that
    # was never written — the failure mode this issue exists to prevent.
    printf '%s' "$cls" > "$stamp" 2>/dev/null || true
    return 0
}

_machine_input_prune() {
    local window="$1" path tmp
    path=$(_machine_input_path)
    [[ -f "$path" ]] || return 0
    tmp=$(mktemp "${path}.XXXXXX")
    if [[ -n "$window" ]]; then
        awk -F'\t' -v w="$window" '$1 != w' "$path" > "$tmp"
    else
        cat "$path" > "$tmp"
    fi
    if (( $(wc -l < "$tmp") > 200 )); then
        # Column 4 (the your-org/nexus-code#683 administrative marker)
        # MUST survive compaction. Dropping it silently reverts the
        # window to re-task behaviour — the retain gets consumed and the
        # wrap-up reads as superseded — and it would happen only on a
        # BUSY board, past 200 rows, which is both the hardest case to
        # reproduce and the one where a mis-retired window costs most.
        #
        # `#676` declined a fourth column for the verdict sidecar with
        # the argument that compaction "keeps one max-epoch row per
        # window, which would silently drop a verdict row". That
        # reasoning is correct for a VERDICT, which is per-paste and
        # needs history. It does not transfer here: the administrative
        # marker is only ever consulted for the window's NEWEST machine
        # input, and the max-epoch row compaction keeps IS that row. So
        # the marker survives as long as the field is carried, which is
        # what this does and what test D2 asserts.
        awk -F'\t' -v OFS='\t' \
            '$2 ~ /^[0-9]+$/ && ($2 + 0) > m[$1] { m[$1] = $2 + 0; s[$1] = $3; a[$1] = $4 }
             END { for (w in m) print w, m[w], s[w], a[w] }' \
            "$tmp" > "${tmp}.compact" && mv "${tmp}.compact" "$tmp"
    fi
    mv "$tmp" "$path"
}

# Print the row's value fields
# `<since>\t<last>\t<prompt_seen>\t<src>\t<reminded>` for `window`.
# Empty stdout when there is no row. Pre-#201 5-column rows read
# their missing `reminded` as 0.
_openg_lookup() {
    local window="$1" path
    path=$(_openg_path)
    [[ -f "$path" ]] || return 0
    awk -F'\t' -v w="$window" \
        '$1 == w { printf "%s\t%s\t%s\t%s\t%s", $2, $3, $4, $5, ($6 == "" ? 0 : $6); exit }' \
        "$path"
}

# Upsert the row for `window`. Atomic rewrite + rename, mirroring
# _engagement_log_stamp.
_openg_write() {
    local window="$1" since="$2" last="$3" prompt_seen="$4" src="$5" reminded="${6:-0}" path tmp
    [[ -n "$window" ]] || return 1
    path=$(_openg_path)
    mkdir -p "$(dirname "$path")"
    tmp=$(mktemp "${path}.XXXXXX")
    if [[ -f "$path" ]]; then
        awk -F'\t' -v w="$window" '$1 != w' "$path" > "$tmp"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$window" "$since" "$last" "$prompt_seen" "$src" "$reminded" >> "$tmp"
    mv "$tmp" "$path"
}

# Drop any row for `window`. Silent no-op when file or row is absent.
_openg_drop() {
    local window="$1" path tmp
    [[ -n "$window" ]] || return 1
    path=$(_openg_path)
    [[ -f "$path" ]] || return 0
    tmp=$(mktemp "${path}.XXXXXX")
    awk -F'\t' -v w="$window" '$1 != w' "$path" > "$tmp"
    mv "$tmp" "$path"
}

# Epoch of the current-lifecycle wrap-up event for `window`; prints
# `0` when none (or when its ts is unparseable). The underlying
# matcher is already spawn-scoped, so a wrap-up from a prior life of
# the window-name yields 0 here too.
_openg_wrap_epoch() {
    local window="$1" entry ts epoch
    entry=$(_idle_window_wrap_up_entry "$window") || { printf '0'; return 0; }
    ts="${entry#*$'\t'}"
    if [[ -n "$ts" && "$ts" != "_NULL_" ]]; then
        epoch=$(_idle_iso_to_epoch "$ts")
        [[ "$epoch" =~ ^[0-9]+$ ]] && { printf '%s' "$epoch"; return 0; }
    fi
    printf '0'
}

# Epoch of the most recent `engaged-done` action-log event for
# `window` — the agent's explicit interactive-session finished-signal,
# appended by `ng engaged-done` (the #205 state-machine follow-up).
# Prints `0` when none. An engaged-done NEWER than a mark's `since`
# invalidates the mark (see _openg_marked); one older than the current
# episode's seed is inert, so a stale signal from a prior conversation
# (or a prior life of the window-name) can never kill a fresh
# engagement.
_openg_done_epoch() {
    local window="$1" log_file="${2:-${STATE_DIR}/action-log.jsonl}"
    [[ -n "$window" && -f "$log_file" ]] || { printf '0'; return 0; }
    local ts="" e
    if command -v jq >/dev/null 2>&1; then
        ts=$(grep '"event":"engaged-done"' "$log_file" 2>/dev/null \
            | tac \
            | jq -r --arg w "$window" \
                'select(.window == $w) | .ts' 2>/dev/null \
            | head -1)
    else
        local line entry_window
        while IFS= read -r line; do
            entry_window=$(printf '%s' "$line" \
                | sed -n 's/.*"window":"\([^"]*\)".*/\1/p')
            [[ "$entry_window" == "$window" ]] || continue
            ts=$(printf '%s' "$line" \
                | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
            break
        done < <(grep '"event":"engaged-done"' "$log_file" 2>/dev/null | tac)
    fi
    if [[ -n "$ts" ]]; then
        e=$(_idle_iso_to_epoch "$ts")
        [[ "$e" =~ ^[0-9]+$ ]] && { printf '%s' "$e"; return 0; }
    fi
    printf '0'
}

# Pure predicate over already-fetched values: is a mark with this
# (since, last) fresh and not invalidated by the `engaged-done`
# finished-signal at `done_epoch`? (Pre-#205-state-machine this slot
# carried the wrap-up epoch — a wrap-up no longer invalidates a mark;
# interactive sessions stay engaged across their own hand-off.)
# Callers supply `now` and `grace`.
_openg_mark_fresh() {
    local since="$1" last="$2" done_epoch="$3" now="$4" grace="$5"
    [[ "$since" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] || return 1
    (( since > 0 && last > 0 ))   || return 1
    (( now - last <= grace ))     || return 1
    (( since >= done_epoch ))     || return 1
    return 0
}

# Is `window` carrying a VALID engagement mark — seeded, not
# invalidated by a newer `engaged-done` finished-signal or spawn, AND
# still corroborated by RECENT pane-content change? (A wrap-up does
# NOT invalidate — see the INVALIDATE rule in the section header; the
# #205 state-machine follow-up.) This predicate gates every suppression
# surface, so the change-TTL check here is the load-bearing self-expiry
# (your-org/your-nexus#205 follow-up): the moment a marked window's
# pane has been static past MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS,
# this returns 1 everywhere at once and the window drops back to its
# normal retire-eligibility. A window is therefore NEVER pinned open
# indefinitely on a stale or false mark — when the signal is uncertain
# (no change stamp, or change aged out) we fail toward RELEASE, because
# a released-but-wanted window is recoverable (respawn) whereas a
# window held open on a bad mark lingers forever, the worse failure.
#
# Use `_openg_active` when "operator around right now" matters (the
# soft `last`-submit grace for the away-phase close reminder, which
# rides on top of this validity check).
_openg_marked() {
    local window="$1"
    local row since last prompt_seen src reminded
    row=$(_openg_lookup "$window")
    [[ -n "$row" ]] || return 1
    IFS=$'\t' read -r since last prompt_seen src reminded <<<"$row"
    [[ "$since" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] || return 1
    (( since > 0 && last > 0 )) || return 1
    local done_epoch
    done_epoch=$(_openg_done_epoch "$window")
    (( since >= done_epoch )) || return 1
    # Spawn-lifecycle guard: a spawn event newer than the mark means
    # a new worker took over this window-name; the mark is stale.
    local spawn_ts spawn_epoch
    spawn_ts=$(_idle_window_spawn_ts "$window")
    if [[ -n "$spawn_ts" ]]; then
        spawn_epoch=$(_idle_iso_to_epoch "$spawn_ts")
        if [[ "$spawn_epoch" =~ ^[0-9]+$ ]] && (( spawn_epoch > since )); then
            return 1
        fi
    fi
    # Self-expiry (THE part-A fix): the mark holds only while the pane
    # has changed within the decay TTL. A static/abandoned/artifact-only
    # window's change clock froze; once `now - change_epoch` exceeds the
    # TTL the mark lapses and the window becomes retire-eligible again.
    # change_epoch=0 (never observed changing) reads as not-corroborated
    # → released, per the bias above.
    local change_epoch change_ttl now
    change_epoch=$(_openg_change_epoch "$window")
    change_ttl=$(_openg_change_ttl_seconds)
    now=$(date +%s)
    (( change_epoch > 0 )) || return 1
    (( now - change_epoch <= change_ttl )) || return 1
    return 0
}

# Is `window` operator-engaged AND the operator around right now
# (mark refreshed within the grace)? Marked-but-not-active is the
# away phase: suppression continues, refresh-on-busy stops.
_openg_active() {
    local window="$1" now="$2" grace="$3"
    _openg_marked "$window" || return 1
    local row since last rest
    row=$(_openg_lookup "$window")
    IFS=$'\t' read -r since last rest <<<"$row"
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    (( now - last <= grace )) || return 1
    return 0
}

# Per-cycle bookkeeping, called for every worker window with this
# cycle's pane-state AND content hash. Three jobs:
#
#   1. CHANGE TRACKING — record this cycle's `content_hash` so the
#      per-window pane-change stamp advances `last_change_epoch`
#      whenever the transcript actually changed. When pane-state took
#      the heartbeat fast path and emitted NO hash but the agent is
#      demonstrably working (busy / working-background /
#      working-self-paced), the change clock is touched instead — the
#      transcript IS streaming, we just didn't capture it. A
#      `user-typing` read is deliberately NOT treated as change: that
#      bright-marker read is the unreliable signal #270 over-trusted,
#      so it must not on its own refresh the corroboration clock.
#
#   2. CREATE / REFRESH — a UserPromptSubmit stamp newer than
#      `prompt_seen` means someone submitted. The TRIGGER never reads
#      pane content — a distorted / garbled / unknown pane-state
#      processes the submit identically, off the deterministic stamp
#      alone. ATTRIBUTION then decides whose: a machine-input stamp
#      (paste-followup / unstick nudge / spawn) within the slack claims
#      it for the orchestrator (no mark). Otherwise the submit is the
#      operator's — but it marks ONLY when CORROBORATED by observed
#      pane change within the decay TTL (the #205-follow-up swap: a
#      one-frame bright-text read is replaced by sustained change). The
#      submit may land a cycle before the agent's answer renders, so
#      corroboration is awaited up to the TTL; an operator submit with
#      no change at all inside the TTL is a redraw artifact and is
#      consumed WITHOUT marking.
#
# Expiry is NOT handled here — `_openg_marked` lapses a mark the moment
# its pane goes static past the TTL, which is what biases toward
# release.
_openg_observe() {
    local window="$1" pane_state="$2" content_hash="$3" now="$4" grace="$5"

    # (1) Change tracking — advance the corroboration clock from the
    # captured hash, or touch it on a hashless agent-working state.
    if [[ -n "$content_hash" ]]; then
        _openg_change_stamp "$window" "$content_hash" "$now"
    else
        case "$pane_state" in
            busy|working-background|working-self-paced)
                _openg_change_touch "$window" "$now" ;;
        esac
    fi

    local row since=0 last=0 prompt_seen=0 src="" reminded=0
    row=$(_openg_lookup "$window")
    [[ -n "$row" ]] && IFS=$'\t' read -r since last prompt_seen src reminded <<<"$row"
    [[ "$since"       =~ ^[0-9]+$ ]] || since=0
    [[ "$last"        =~ ^[0-9]+$ ]] || last=0
    [[ "$prompt_seen" =~ ^[0-9]+$ ]] || prompt_seen=0
    [[ "$reminded"    =~ ^[0-9]+$ ]] || reminded=0
    local wrap_epoch done_epoch changed=0
    wrap_epoch=$(_openg_wrap_epoch "$window")
    done_epoch=$(_openg_done_epoch "$window")

    # (2) CREATE / REFRESH. A user-prompt stamp newer than
    # `prompt_seen` means someone submitted input since the last check.
    local prompt_epoch
    prompt_epoch=$(_openg_user_prompt_epoch "$window")
    if (( prompt_epoch > prompt_seen )); then
        local machine slack change_epoch change_ttl
        machine=$(_openg_machine_input_epoch "$window")
        slack=$(_openg_input_slack_seconds)
        if (( machine >= prompt_epoch - slack )); then
            # MACHINE-attributed (orchestrator paste / nudge / spawn).
            # Consume the stamp, never mark — a stalled worker the
            # orchestrator just pasted to must keep surfacing. The
            # window REGRESSES TO BUSY (the #205 state-machine
            # follow-up): stamp the engagement-log at the submit
            # epoch — resetting the idle-age anchor and consuming any
            # standing window-retain even when the busy turn falls
            # between probe cycles — and record the machine-submit
            # stamp so a wrap-up older than this follow-up reads as
            # superseded in the classifier.
            # your-org/nexus-code#683: an ADMINISTRATIVE follow-up is
            # machine-attributed but is NOT a re-task, so it must not
            # take the two actions that regress the window to busy —
            # resetting the idle-age anchor (which consumes the standing
            # `window-retain`) and writing the machine-submit stamp
            # (which makes an older wrap-up read as superseded). It still
            # consumes `prompt_seen` and still clears a stale
            # operator-engaged mark below, exactly like the SELF branch:
            # the submit happened and attribution must not re-run.
            #
            # The DEFAULT is re-task. Only a paste that explicitly said
            # so takes this path, so nothing changes for the re-tasks
            # this premise was written for.
            local _mi_admin
            _mi_admin=$(_openg_machine_input_administrative "$window" "$machine")
            if [[ "$_mi_admin" != "1" ]]; then
                local prior_engagement
                prior_engagement=$(_engagement_log_lookup "$window")
                [[ "$prior_engagement" =~ ^[0-9]+$ ]] || prior_engagement=0
                if (( prompt_epoch > prior_engagement )); then
                    _engagement_log_stamp "$window" "$prompt_epoch"
                fi
                _machine_submit_stamp_write "$window" "$prompt_epoch"
            fi
            # REGRESS any PRE-EXISTING operator-engaged mark to busy (bug
            # B; live incident 2026-06-18 watcher-robustness). A
            # machine-attributed submit means the orchestrator (re-)drove
            # this window, so a prior operator-engaged mark is now stale.
            # The CREATE path tore a mark down implicitly — a fresh window
            # reaches here with since/last already 0, so the final write
            # produced a since=0 (unmarked) row. But when a mark ALREADY
            # exists this branch left since/last/src untouched, so the
            # final write PRESERVED the stale mark and the window stayed
            # `operator-engaged` forever (only engaged-done / spawn /
            # change-TTL-expiry could tear it down). A correctly
            # paste-followup-stamped orchestrator relay was therefore
            # structurally unable to self-heal a mis-seeded mark. Zero the
            # mark fields here so the machine submit consumes the stamp AND
            # clears the mark, exactly as the CREATE path does; a later
            # genuine operator submit (no covering machine stamp) re-seeds
            # a fresh episode normally. _openg_marked requires since>0, so
            # the resulting since=0 row reads as unmarked everywhere.
            since=0; last=0; reminded=0; src="machine"
            prompt_seen="$prompt_epoch"; changed=1
        elif _openg_prompt_is_self "$window"; then
            # SELF-attributed (your-org/your-nexus, coembed-283-followup
            # 2026-07-17). No covering machine-input stamp, yet the submit
            # carries the window's OWN spawn session-id — so it is the
            # worker's own pane self-activity (autosuggest, post-wrap
            # typing, its own tool loop) under the operator's stated
            # invariant (they drive a DIFFERENT session and never raw-type
            # into a worker pane; they relay via paste-followup, which
            # machine-stamps). Note the hook fires inside the worker's own
            # session, so a human raw-typing here would stamp the same own
            # session-id — indistinguishable; that path is out of scope by
            # the invariant, and on the retire side check-1 pane-state
            # (`user-typing`/`busy`) is the live backstop. Unlike
            # the MACHINE branch above, we do NOT stamp the engagement-log
            # or machine-submit ledger: this is not the orchestrator
            # (re-)driving the window with new work, it is noise — so it
            # must neither seed an operator-engaged mark NOR reset the
            # idle-age anchor that keeps a wrapped, self-active-only window
            # retire-eligible. Consume the stamp (advance prompt_seen) so
            # attribution doesn't re-run, exactly like the phantom/redraw
            # branch below.
            prompt_seen="$prompt_epoch"; changed=1
        else
            # OPERATOR-attributed by the machine rule. Mark only when
            # corroborated by observed pane change within the TTL.
            # change_epoch advances to ~now once the agent's answer
            # renders, so a recent-enough change (before or after the
            # submit) confirms real interaction.
            change_epoch=$(_openg_change_epoch "$window")
            change_ttl=$(_openg_change_ttl_seconds)
            if (( change_epoch >= prompt_epoch - change_ttl )); then
                # Corroborated. Refresh a fresh mark, else seed a new
                # episode. Epochs come from the stamp — the submit
                # instant is exact, no poll-cycle smear. Freshness is
                # gated on the engaged-done finished-signal, NOT the
                # wrap-up: a post-wrap operator prompt refreshes the
                # surviving mark (interactive sessions span their own
                # hand-off), while a post-done prompt seeds a NEW
                # episode (the operator re-engaged a finished window).
                if _openg_mark_fresh "$since" "$last" "$done_epoch" "$now" "$grace"; then
                    (( prompt_epoch > last )) && last="$prompt_epoch"
                else
                    since="$prompt_epoch"; last="$prompt_epoch"; reminded=0
                    if (( wrap_epoch > 0 )) && (( prompt_epoch > wrap_epoch )); then
                        src="submit-after-wrap"
                    else
                        src="submit"
                    fi
                fi
                prompt_seen="$prompt_epoch"; changed=1
            elif (( now - prompt_epoch > change_ttl )); then
                # Awaited a full TTL with no corroborating change —
                # this submit was a redraw artifact / phantom. Consume
                # without marking so attribution doesn't re-run forever.
                prompt_seen="$prompt_epoch"; changed=1
            fi
            # else: still within the await window — leave the stamp
            # UNCONSUMED so the next cycle re-checks as the agent's
            # answer (and its content change) lands.
        fi
    fi

    # Pane-state soft REFRESH of `last` — never creates a mark, only
    # extends an already-fresh episode's away-phase clock so a long
    # busy turn between operator submits doesn't flap into the away
    # phase mid-conversation. `user-typing` is excluded (unreliable
    # read); mark VALIDITY no longer rides on `last` anyway — it rides
    # on the change-TTL in `_openg_marked` — so this only nudges the
    # close-reminder cadence.
    case "$pane_state" in
        busy|working-background|working-self-paced)
            if _openg_mark_fresh "$since" "$last" "$done_epoch" "$now" "$grace"; then
                last="$now"; changed=1
            fi
            ;;
    esac

    if (( changed )); then
        _openg_write "$window" "$since" "$last" "$prompt_seen" "${src:-}" "$reminded"
    fi
}

# Path of the worker-notifications JSONL log. Workers' default
# Notification hook (see `<!-- worker-hooks-default -->` in
# skills/nexus.worker-defaults/SKILL.md) `>>`-appends one row per
# claude-side notification event:
#
#   {"event":"Notification","notification":{...},"window":"<name>","ts":<epoch>}
#
# Concurrent workers append safely because each `jq -c >> path` opens,
# writes, and closes the fd; there's no long-held writer. The watcher
# reads the file every cycle to count workers awaiting input and
# rotates it when it crosses MONITOR_NOTIFICATIONS_LOG_MAX_BYTES
# (default 10MiB). Path is intentionally NOT under DIFF_DIR — it's
# event data, not a per-cycle archive.
_notifications_log_path() {
    printf '%s/worker-notifications.jsonl' "${STATE_DIR:-$(_ip_nostate_dir)}"
}

# Stamp file marking the epoch of the last `render_idle_prelude` call.
# Used to scope the awaiting-input count to events newer than the
# previous prelude render — i.e., notifications that have arrived
# since the orchestrator last saw the count. Missing file means
# "first render"; we treat that as "no scope yet" and skip the count
# rather than over-reporting every historical row.
_notifications_stamp_path() {
    printf '%s/last-prelude.ts' "${STATE_DIR:-$(_ip_nostate_dir)}"
}

# Count distinct worker windows whose latest notification row is newer
# than the supplied epoch. Pure read, no side effects on the log or
# stamp. Returns "0" on missing log, missing jq, or unparseable rows
# (silent degrade — the prelude line still renders).
#
# Distinct-by-window because two `permission_prompt`s in the same
# cycle from one worker shouldn't double-count toward "awaiting-input";
# the operator's signal is "how many workers want my attention right
# now", not "how many events arrived".
#
# THE ORCHESTRATOR IS NOT A WORKER AWAITING INPUT (your-org/nexus-code#1478).
# It emits `idle_prompt` at the end of essentially every turn — waiting for
# the operator is its RESTING state — so counting its rows inflated this
# scalar by one nearly always: `0` was close to unreachable and a real worker
# rendered as `2`. The observer counting itself (#1073), relocated into the
# operator-facing summary. Excluded by the identity the watcher already uses
# for its paste target (`$TARGET`, config monitor.target_window), never a
# hardcoded name; the window lister above applies the same exclusion. Readers
# of this count (the prelude render, _emit_dedup's strip, the calibrator's
# stub) consume the number, not the population — checked per #1050.
_notifications_count_distinct_since() {
    local since_epoch="${1:-0}" path exclude="${TARGET:-orchestrator}"
    path=$(_notifications_log_path)
    [[ -f "$path" ]] || { printf '0'; return 0; }
    # Accept both integer and fractional epochs (the prelude stamps
    # `date +%s.%N` so the comparison can disambiguate same-second
    # appends from a hook that fires during the prelude render).
    [[ "$since_epoch" =~ ^[0-9]+(\.[0-9]+)?$ ]] || since_epoch=0
    if command -v jq >/dev/null 2>&1; then
        jq -r --argjson since "$since_epoch" --arg excl "$exclude" \
            'select((.ts // 0) > $since) | (.window // "") | select(. != $excl)' \
            "$path" 2>/dev/null \
            | awk 'NF>0' \
            | sort -u \
            | awk 'END {print NR+0}'
    else
        # sed fallback: tolerate the canonical jq-emitted compact form
        # the worker hook produces. Number-typed ts; double-quoted
        # window. Robust enough for the in-house log shape.
        awk -v since="$since_epoch" -v excl="$exclude" '
            { ts=""; win=""
              if (match($0, /"ts":[ ]*[0-9.]+/)) {
                  s = substr($0, RSTART+5, RLENGTH-5); gsub(/[ ]/,"",s); ts = s
              }
              if (match($0, /"window":[ ]*"[^"]*"/)) {
                  w = substr($0, RSTART+9, RLENGTH-9); gsub(/^[ ]*"|"$/,"",w); win = w
              }
              if (ts == "" || win == "") next
              if (win == excl) next
              if (ts+0 > since+0) print win
            }' "$path" 2>/dev/null \
            | sort -u \
            | awk 'END {print NR+0}'
    fi
}

# Atomic-by-rename rotation. When the notifications log exceeds
# `max_bytes`, rename it to `<path>.<epoch>` and let the next worker
# append re-create the live file. Old archives are pruned along the
# same retention window the watcher applies to its diff archive
# (DIFF_RETENTION_DAYS, default 7 days).
#
# Race window: two appends bracketing a `mv` lose at most the second
# append's row (it lands in the rotated file rather than the new live
# file). Acceptable — the next prelude render still sees the rotated
# row's window, just labelled to the prior cycle.
#
# Silent no-op when the file doesn't exist or is below threshold.
_notifications_rotate_if_oversized() {
    local max_bytes="${1:-10485760}" path size
    path=$(_notifications_log_path)
    [[ -f "$path" ]] || return 0
    [[ "$max_bytes" =~ ^[0-9]+$ ]] || return 0
    (( max_bytes > 0 )) || return 0
    size=$(stat -c '%s' "$path" 2>/dev/null || stat -f '%z' "$path" 2>/dev/null || echo 0)
    [[ "$size" =~ ^[0-9]+$ ]] || return 0
    (( size >= max_bytes )) || return 0
    local archive
    archive="${path}.$(date +%s)"
    mv -f "$path" "$archive" 2>/dev/null || return 0
    # Best-effort cleanup of older archives. find with -mtime is the
    # cheap option; matches the pattern the watcher uses for
    # DIFF_DIR pruning.
    local retention="${DIFF_RETENTION_DAYS:-7}"
    [[ "$retention" =~ ^[0-9]+$ ]] || retention=7
    find "$(dirname "$path")" -maxdepth 1 -type f \
        -name 'worker-notifications.jsonl.*' \
        -mtime "+$retention" -delete 2>/dev/null || true
}

# Path of the previous-cycle window-set artifact. Newline-separated
# list of window names that were "tracked" in the prior cycle —
# defined as `(tmux windows the probe saw) ∪ (engagement-log keys
# left after the prior cycle's prune)`. The union is what makes the
# cold-start case (watcher restarted with a stale engagement-log row
# but no previous-windows file) prune in two cycles rather than
# never:
#
#   cycle 1 (file absent): prev=∅, current=∅ → nothing dropped;
#                          persist current ∪ engagement-log keys =
#                          {stale-row}.
#   cycle 2 (file present): prev={stale-row}, current=∅ →
#                          disappeared={stale-row} → drop. Persist ∅.
#
# A window alive across cycles stays in the file via the `current`
# half of the union; a row that's been dropped this cycle drops out
# of the union next cycle naturally because it's no longer in the
# engagement-log when we re-read.
_idle_previous_windows_path() {
    printf '%s/idle-probe-previous-windows.txt' "${STATE_DIR:-$(_ip_nostate_dir)}"
}

# ---- public surface -----------------------------------------------------

# Enumerate worker windows whose tmux activity-age ≥ threshold AND
# whose pane-state warrants surfacing; classify each into one of
# the buckets below (Pieces 1–2, 5, 8 in PR #4; pane-absent added
# in #111-extension):
#
#     wrapped           — wrap-up event exists and the cited report
#                         passes `ng report-check`.
#     wrapped-but-stub  — wrap-up event exists but the cited report
#                         fails the schema/completeness check.
#                         Detail column carries the `;`-joined
#                         missing-fields summary.
#     no-wrap-up        — really idle but no wrap-up event matches
#                         the window (orchestrator should paste the
#                         wrap-up-missing follow-up template).
#     idle-too-long     — really idle for ≥ MONITOR_IDLE_CLOSE_HOURS
#                         (default 24h, config knob
#                         monitor.idle_close_hours). Overrides the
#                         other three — once the hard-close
#                         threshold is hit the orchestrator should
#                         consider close regardless of wrap-up
#                         state. NOT suppressible by `window-retain`
#                         (a runaway window must always surface).
#     pane-absent       — pane-state is absent|empty|blocked: the
#                         inner Claude Code process is gone, the
#                         renderer is in an ambiguous state, or the
#                         pane is sitting on a stalled overlay.
#                         Inviolable like idle-too-long — never
#                         suppressed by `window-retain`.
#     retained          — base class was `wrapped` or `no-wrap-up`
#                         but the orchestrator has logged a recent
#                         `window-retain` event for this window and
#                         no real engagement (busy / user-typing)
#                         has been observed since. Collated into a
#                         `(N retained windows suppressed: …)`
#                         footer by render_idle_section instead of
#                         emitting a per-window row.
#                         `wrapped-but-stub`, `idle-too-long`, and
#                         `pane-absent` are NEVER suppressed.
#     operator-engaged  — the window carries a valid operator-
#                         engagement mark (see the "operator-engaged
#                         marks" section above): the operator drives
#                         this window — right now, or stepped away.
#                         Informational, deduped to one row per
#                         engagement episode; replaces the
#                         wrapped/no-wrap-up classification, the
#                         follow-up-paste nag, the idle-too-long
#                         alarm, and retire eligibility until the
#                         mark is invalidated by a newer wrap-up /
#                         spawn or the window closes. Once the
#                         operator has been away a full reminder
#                         period, list_idle_transitions adds a
#                         once-per-period `engaged-close-reminder`
#                         emit on top. Detail column carries the
#                         seed source (submit | submit-after-wrap;
#                         legacy rows: typing | busy-after-wrap |
#                         busy-after-prompt).
#     paste-unconfirmed — an orchestrator `paste-followup` older than
#                         MONITOR_PASTE_CONFIRM_GRACE_SECONDS
#                         (default 180) fired NO UserPromptSubmit
#                         hook on a window with live hooks — the
#                         nudge MAY have silently failed (Enter
#                         swallowed by VI mode / overlay / redraw
#                         race). Replaces the wrapped/no-wrap-up row.
#                         Never suppressed by `window-retain`;
#                         idle-too-long still overrides it. Detail
#                         carries the paste age.
#
#                         THIS CLASS HAS FALSE POSITIVES, AND ITS
#                         REMEDY IS DESTRUCTIVE (#568 A9). The
#                         `machine-submit/<window>` stamp is written
#                         ONLY by this file's UserPromptSubmit path;
#                         `paste-followup.sh` never writes it. So a
#                         paste delivered via the RETRY-ENTER path is
#                         fully consumed by the worker and still
#                         leaves the stamp at its pre-paste value —
#                         indistinguishable from a lost paste. The
#                         worker then goes idle with no further turn,
#                         so the stamp never self-heals and the emit
#                         persists indefinitely. Observed end-to-end
#                         on 2026-07-26: a 6,448-char correction list
#                         was executed in full and the emit still
#                         fired. Acting on it literally would have
#                         re-pasted that list into a COMPLETED
#                         fix-pass — duplicate comments, duplicate
#                         commits, or a confused re-do. The emit text
#                         therefore leads with VERIFY CONSUMPTION
#                         FIRST; an orchestrator must not treat this
#                         class as an instruction to re-paste.
#
# Side effect: as part of each cycle this function stamps
# engagement-log.tsv twice for each observed window:
#   1. Backfill — if no row exists for the window yet, stamp with
#      `now` (first-observation baseline; closes issue #44).
#   2. Engagement refresh — if pane-state is `busy` or
#      `user-typing`, stamp with `now` (refreshes the row to the
#      current engagement moment).
# Both happen BEFORE the age gate so a worker that's actively busy
# now (low activity-age) still records engagement, and a worker
# the watcher has never seen before still gets a stable age anchor
# rather than falling through to tmux's noisy `#{window_activity}`.
#
# Output: <window>\t<class>\t<age-seconds>\t<detail>
#         (detail is the missing-fields summary for wrapped-but-stub,
#          the retain reason for retained, the pane-absent advisory
#          string for pane-absent; empty otherwise)
# parked-awaiting-skeptic exemption (skills/nexus.skeptic, PR #285).
#
# A worker parked in `skeptic-channel.sh await` is legitimately WAITING
# for a skeptic's next request, not idle and not hung. It would otherwise
# look idle to pane-state during the gaps between the renderer's spinner
# updates, and — once past the close threshold — be misclassified
# `idle-too-long` (→ the orchestrator closes it mid-handshake, killing
# the await) or nagged `no-wrap-up`.
#
# The signal is the EXISTING skeptic-pending marker
# ($STATE_DIR/skeptic/pending/<window>) — the same one ng wrap-up writes
# for a `require` gate and retire-preflight.sh blocks a close on. The
# worker's await loop refreshes the marker's mtime every poll, so a
# "live" marker (exists AND mtime within the hang threshold,
# monitor.skeptic.await_hang_seconds, default 600s) proves the worker is
# actively parked. A marker gone STALE (await died / the worker never
# entered the loop) lapses the exemption so the genuine hang resurfaces
# through normal idle classification — that is the hang-vs-wait boundary.
#
# NOTE (scope, verified PR #285): the watcher AUTO-respawns only the
# orchestrator (TARGET); worker windows are never auto-respawned on
# staleness — they are FLAGGED here and the orchestrator acts. So this
# idle-classification exemption (plus retire-preflight's existing marker
# gate) is the complete worker-side hardening; there is no separate
# worker staleness-respawn path to exempt.
#
# == emit/exemption fidelity: the marker alone is NOT proof of a skeptic ==
#
# The load-bearing correction. The skeptic-pending marker is refreshed by
# the WORKER's own `skeptic-channel await` loop (_await_heartbeat), so a
# FRESH marker proves only that the worker is parked and looping — NOT that
# a skeptic is actually reviewing. When a wrap-up's `require`/`auto` gate
# writes the marker but the orchestrator NEVER spawns the skeptic
# (observed live: `sandbox-issue-sweep --skeptic auto` parked at wrap, no
# skeptic ever dispatched), the worker parks forever, its await loop
# re-touches the marker forever, and the exemption stuck INDEFINITELY — the
# window lingered all night, never flagged idle-too-long. The exemption
# must require an ACTUAL live skeptic, with a bounded grace so the
# orchestrator has time to spawn one before we call the marker orphaned.

# Resolve the await-hang freshness window (marker mtime must be younger
# than this for the worker to count as actively parked). Env > config >
# default 600s.
_idle_skeptic_hang_seconds() {
    local hang="${MONITOR_SKEPTIC_AWAIT_HANG_SECONDS:-}"
    if [[ -z "$hang" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        hang=$("$NEXUS_ROOT/config/load.sh" monitor.skeptic.await_hang_seconds 600 2>/dev/null || echo 600)
    fi
    [[ "$hang" =~ ^[0-9]+$ ]] || hang=600
    printf '%s' "$hang"
}

# Grace window: how long a fresh marker with NO live skeptic may still
# confer the exemption (giving the orchestrator time to spawn the skeptic)
# before the marker is declared orphaned. Env > config > default 600s.
# THE TWO ARE COUPLED, AND THE COUPLING IS LOAD-BEARING (your-org/nexus-code#975).
#
# `_idle_skeptic_orphaned` requires BOTH `age <= hang` AND `now - req > grace`,
# where `req` falls back to the marker mtime when no `skeptic-request` row is
# found. On the path where marker mtime == request ts — which is the NORMAL
# path, because `ng` writes the marker and logs the request in the same instant
# — those two collapse to `age <= hang && age > grace`. That window is EMPTY
# whenever `hang <= grace`, and both default to 600, so at stock config the
# orphan backstop CANNOT FIRE on the equal-ages path. Measured across eleven
# marker ages spanning the boundary, with a potency control that does fire.
#
# The only thing that separates mtime from req is a writer that TOUCHES an
# existing marker without re-logging the request: `_await_heartbeat`
# (skeptic-channel.sh) while a worker sits in `await`, and spawn-worker.sh's
# re-stamp at an actual skeptic spawn. On the never-spawned re-arm path neither
# runs — there is no worker awaiting precisely because no skeptic was spawned —
# so the marker's mtime freezes at write time and crosses `hang` ~10 minutes
# later, after which it is permanently invisible to the backstop built to catch
# it. That is #975's mechanism.
#
# So DO NOT tune either value in isolation. `hang > grace` is what makes the
# orphan window non-empty; raising `await_hang_seconds` to quiet a false
# hang-flag, or lowering `orphan_grace_seconds` for faster nagging, silently
# changes whether this class of stuck park is detectable at all — in opposite
# directions, for reasons unrelated to skeptics.
_idle_skeptic_orphan_grace() {
    local g="${MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS:-}"
    if [[ -z "$g" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        g=$("$NEXUS_ROOT/config/load.sh" monitor.skeptic.orphan_grace_seconds 600 2>/dev/null || echo 600)
    fi
    [[ "$g" =~ ^[0-9]+$ ]] || g=600
    printf '%s' "$g"
}

# Is a LIVE skeptic reviewing window $1? Authoritative signal:
# spawn-worker.sh logs a `skeptic-spawn` action-log event
# (window=<skeptic-window> target-window=<reviewed> orig-window=<chain-root>)
# at the moment a real skeptic is dispatched — the single point tied to an
# ACTUAL spawn. A live skeptic is the most-recent such event naming $1 (as
# target OR orig) whose skeptic window is still alive in tmux. Fallback: a
# live tmux window named `<$1>-skeptic` (the _skeptic_spawn_cmd template
# name), covering an action-log gap. Parsed with awk/sed (no jq dependency
# in the idle path). $2 = live tmux window names (newline-sep; queried if
# empty). Returns 0 (live skeptic present) / 1 (none).
_idle_skeptic_live_window() {
    local name="$1" live="${2:-}"
    [[ -n "$live" ]] || live=$(tmux list-windows -F '#{window_name}' 2>/dev/null)
    local log="${STATE_DIR:-}/action-log.jsonl" sw=""
    if [[ -n "$log" && -r "$log" ]]; then
        sw=$(grep -F '"event":"skeptic-spawn"' "$log" 2>/dev/null \
            | awk -v t="\"target-window\":\"${name}\"" -v o="\"orig-window\":\"${name}\"" \
                'index($0,t) || index($0,o)' \
            | sed -n 's/.*"window":"\([^"]*\)".*/\1/p' \
            | awk 'NF{last=$0} END{if(last!="")print last}')
    fi
    # your-org/nexus-code#845: the resolved NAME is printed on stdout, not
    # discarded. This function computed the exact identifier the deadlock join
    # needs and threw it away one line before use, so the row could never say
    # WHICH skeptic the exemption rests on, let alone how long it has been
    # idle. One authority for "who is reviewing this window"; callers that
    # only want the boolean redirect stdout.
    if [[ -n "$sw" ]] && grep -qxF -- "$sw" <<<"$live"; then
        printf '%s' "$sw"
        return 0
    fi
    if grep -qxF -- "${name}-skeptic" <<<"$live"; then
        printf '%s' "${name}-skeptic"
        return 0
    fi
    return 1
}

# The skeptic WINDOW the most recent `_idle_skeptic_parked` verdict rests on
# (your-org/nexus-code#845), set beside `_IDLE_SKEPTIC_PARK_BASIS`; empty on
# the `grace` basis (no live skeptic yet) and on every non-park verdict.
_IDLE_SKEPTIC_PARK_WINDOW=""

# _idle_window_activity_epoch <window-name> <worker-windows-tsv> — the
# `#{window_activity}` epoch of one window from the sweep's own enumeration
# (`name<TAB>activity<TAB>index` lines); empty when absent or non-numeric.
_idle_window_activity_epoch() {
    local want="$1" tsv="$2"
    # A DRAINING reader (no `exit`): an early-exit awk under pipefail is the
    # #622 shape the early-exit-reader manifest ratchets.
    printf '%s\n' "$tsv" | awk -F'\t' -v w="$want" '!done && $1 == w && $2 ~ /^[0-9]+$/ { print $2; done = 1 }'
}

# Idle age (seconds) above which a parked target's resolved, un-retained,
# idle skeptic is flagged as the #845 deadlock shape. Env > config > 1800.
_idle_skeptic_deadlock_seconds() {
    local s="${MONITOR_SKEPTIC_DEADLOCK_IDLE_SECONDS:-}"
    if [[ -z "$s" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        s=$("$NEXUS_ROOT/config/load.sh" monitor.skeptic.deadlock_idle_seconds 1800 2>/dev/null || echo 1800)
    fi
    [[ "$s" =~ ^[0-9]+$ ]] || s=1800
    printf '%s' "$s"
}

# _idle_window_retained_within_ttl <window> <now> — rc 0 iff a `window-retain`
# event names <window> and is within the retain TTL (env
# MONITOR_RETAIN_TTL_SECONDS, default 86400 — the same window the `retained`
# classification honours). A declared hold older than the TTL has lapsed.
_idle_window_retained_within_ttl() {
    local w="$1" now="$2" row ts reason ep ttl="${MONITOR_RETAIN_TTL_SECONDS:-86400}"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=86400
    row=$(_idle_window_retain_event "$w") || return 1
    IFS=$'\t' read -r ts reason <<<"$row"
    ep=$(_idle_iso_to_epoch "$ts")
    [[ "$ep" =~ ^[0-9]+$ ]] || return 1
    (( now - ep >= 0 && now - ep <= ttl ))
}

# _idle_skeptic_join_detail <now> <worker-windows-tsv> — the JOIN the
# `parked-awaiting-skeptic` row was missing (your-org/nexus-code#845): the
# resolved skeptic's NAME and IDLE AGE, folded into the row where the
# orchestrator already looks. Seven pairs in one session sat deadlocked for
# 30m–4h06m — target parked and exempt, skeptic idle — because the two halves
# lived in the same snapshot and nothing correlated them; #1039 then removed
# the accidental age ceiling that used to bound the pair.
#
# Prints "; skeptic=<w> idle <age>s" (or "idle UNKNOWN" when the reviewer is
# absent from the enumeration — never a guessed number), and appends a
# DEADLOCK flag ONLY on positive evidence, every condition required, the
# allowlist shape the 2026-08-09 objection asked for: a resolved skeptic
# (this row is parked, so the marker is present), a KNOWN idle age, above the
# threshold, and the skeptic NOT `retained` (a declared hold is intent, and no
# predicate over pane state may override it). Anything else: the age alone.
# The flag is a reading aid on a row that already exists; it authorises
# nothing — `bk_pane_kill_authorized` never sees it.
_idle_skeptic_join_detail() {
    local now="$1" tsv="$2" sw="${_IDLE_SKEPTIC_PARK_WINDOW:-}"
    [[ -n "$sw" ]] || return 0
    local ep age
    ep=$(_idle_window_activity_epoch "$sw" "$tsv")
    if [[ ! "$ep" =~ ^[0-9]+$ ]]; then
        printf '; skeptic=%s idle UNKNOWN (reviewer not in the worker-window enumeration)' "$sw"
        return 0
    fi
    age=$(( now - ep )); (( age >= 0 )) || age=0
    printf '; skeptic=%s idle %ds' "$sw" "$age"
    local thr; thr=$(_idle_skeptic_deadlock_seconds)
    if (( age > thr )) && ! _idle_window_retained_within_ttl "$sw" "$now"; then
        printf ' — DEADLOCK SHAPE (#845): the target is parked on this skeptic and the skeptic has been idle longer than %ds; neither side can release the other. Push the delta to the skeptic (skeptic-channel.sh notify-delta / nudge) or resolve the requirement (ng skeptic resolve); if the hold is deliberate, declare it (ng log-action monitor --event window-retain --extra window=%s --extra reason=…) and this flag goes silent' "$thr" "$sw"
    fi
    return 0
}

# Epoch at which a skeptic was last REQUIRED for window $1 — the orphan
# grace clock. Unlike the marker mtime (refreshed by the worker's await
# loop) the `skeptic-request` action-log event's ts is written ONCE at
# wrap-up and never moves, so `now - request_epoch` is the true "how long
# has the orchestrator had to spawn a skeptic." Echoes an epoch, or 0 when
# no such event exists (caller falls back to the marker mtime).
_idle_skeptic_request_epoch() {
    local name="$1"
    local log="${STATE_DIR:-}/action-log.jsonl"
    [[ -n "$log" && -r "$log" ]] || { printf '0'; return; }
    local ts
    ts=$(grep -F '"event":"skeptic-request"' "$log" 2>/dev/null \
        | awk -v t="\"target-window\":\"${name}\"" 'index($0,t)' \
        | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p' \
        | awk 'NF{last=$0} END{if(last!="")print last}')
    [[ -n "$ts" ]] || { printf '0'; return; }
    date -d "$ts" +%s 2>/dev/null || printf '0'
}

# _idle_skeptic_channel_active <target> <since-epoch>
#
# POSITIVE evidence that a skeptic is engaged in THIS round
# (your-org/nexus-code#1153). `_idle_skeptic_live_window` answers from a SPAWN
# LINKAGE RECORD, written only by `spawn-worker.sh --skeptic-role`; a skeptic
# spawned with a bare -n/-c/-p works end to end and writes no linkage at all.
# The CHANNEL is where a skeptic ACTS, so traffic there outranks the absence of
# a spawn row — the detector was advising the operator to clear a LIVE
# obligation because it read the weaker record and never opened the stronger one.
#
# SCOPED TO THE ROUND, AND THAT IS THE WHOLE DESIGN. `close` does NOT remove
# `req-*.md` (measured), so "any request file exists" — the predicate #1153
# itself proposes — is satisfied FOREVER after the first round. That would
# exempt the re-armed never-spawned park this class exists to catch (#975) and
# make retire-preflight's release path unreachable. `$2` is the round start: the
# `skeptic-request` ts, written ONCE and never moved.
#
# NOT the marker mtime, which is the other tempting clock: measured on the
# #1153 episode the channel file is 2.2s OLDER than the marker, because the
# marker is written at wrap-up, AFTER the skeptic has already started asking.
# The request ts is 710s older still, so the channel traffic falls on the right
# side of it.
_idle_skeptic_channel_active() {
    local name="$1" since="$2" f m
    local state_dir="${STATE_DIR:-}"; [[ -n "$state_dir" ]] || return 1
    [[ "$since" =~ ^[0-9]+$ ]] && (( since > 0 )) || return 1
    local safe; safe=$(wk_encode "$name")
    local dir="${state_dir}/skeptic/${safe}"
    [[ -d "$dir" ]] || return 1
    for f in "$dir"/req-*.open.md "$dir"/req-*.ack.md "$dir"/req-*.answered.md; do
        [[ -e "$f" ]] || continue
        m=$(date +%s -r "$f" 2>/dev/null || echo 0)
        [[ "$m" =~ ^[0-9]+$ ]] || continue
        (( m >= since )) && return 0
    done
    return 1
}

# The BASIS on which the most recent `_idle_skeptic_parked` call granted the
# exemption — the evidence the verdict actually rests on, so the emitted label
# can carry it instead of asserting a bare "parked" (your-org/nexus-code#1039).
# One of:
#   await        marker FRESH and a live skeptic window — the ordinary park
#   skeptic-live marker STALE (the worker's own await loop has stopped
#                re-touching it) but a live skeptic window names this target.
#                The exemption is real; what has ended is the WORKER's await,
#                not the skeptic's review. This is the case that used to be
#                mislabelled as an ordinary idle worker.
#   grace        no live skeptic yet, still inside the orphan grace
#   channel      no LINKED skeptic window, but the comms channel holds request
#                traffic newer than this round's `skeptic-request` — a skeptic
#                spawned without `--skeptic-role` is reviewing (#1153)
# Set on every call that returns 0; cleared to empty on a non-park verdict so a
# stale value can never decorate a later row.
_IDLE_SKEPTIC_PARK_BASIS=""

# Returns 0 (parked → exempt) / 1 (not parked → classify normally).
# Exempt when a live skeptic is reviewing (at ANY marker age), or the marker is
# FRESH and we are still within the orphan grace since the skeptic was required.
# $3 = live tmux window names (optional; queried if empty).
#
# LIVENESS IS ASKED BEFORE AGE (your-org/nexus-code#1039), and the order is the
# whole fix. The age gate used to run first and `return 1` on a stale marker,
# discarding `$live` — which already contained the reviewing skeptic's window —
# before the liveness question was ever put. Marker freshness is a PROXY for
# "the worker is still waiting"; the property the exemption exists to express is
# "a skeptic is still reviewing". They agree until the worker's await loop times
# out while the skeptic keeps working, i.e. on LONG skeptic passes — exactly the
# ones where the exemption matters most. Measured: two workers, identical marker
# state and both skeptics alive, got opposite labels (`parked-awaiting-skeptic`
# vs `idle 2254s`); the only difference was whose await loop was still ticking.
#
# The age gate is KEPT for the case it was written for — no live skeptic, stale
# marker — where it correctly declines the exemption and lets the window
# resurface through normal idle classification (the genuine-hang path).
_idle_skeptic_parked() {
    local name="$1" now="$2" live="${3:-}"
    _IDLE_SKEPTIC_PARK_BASIS=""
    _IDLE_SKEPTIC_PARK_WINDOW=""
    local safe; safe=$(wk_encode "$name")
    local state_dir="${STATE_DIR:-}"
    [[ -n "$state_dir" ]] || return 1
    local marker="${state_dir}/skeptic/pending/${safe}"
    [[ -e "$marker" ]] || return 1
    local hang mtime age
    hang=$(_idle_skeptic_hang_seconds)
    mtime=$(date +%s -r "$marker" 2>/dev/null || echo 0)
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    age=$(( now - mtime ))
    # A live skeptic window naming this target is a STRONGER and more direct
    # claim than the freshness of a file the OTHER process happens to touch.
    local _sw=""
    if _sw=$(_idle_skeptic_live_window "$name" "$live"); then
        _IDLE_SKEPTIC_PARK_WINDOW="$_sw"
        if (( age <= hang )); then
            _IDLE_SKEPTIC_PARK_BASIS="await"
        else
            _IDLE_SKEPTIC_PARK_BASIS="skeptic-live"
        fi
        return 0
    fi
    # No live skeptic. Now the marker's freshness matters again: a stale marker
    # with no skeptic is the genuine-hang path and must lapse.
    (( age <= hang )) || return 1
    local req grace
    req=$(_idle_skeptic_request_epoch "$name")
    [[ "$req" =~ ^[0-9]+$ ]] || req=0
    # CHANNEL TRAFFIC THIS ROUND IS POSITIVE EVIDENCE OF A LIVE SKEPTIC
    # (your-org/nexus-code#1153, residual 1 — the PARK half). The orphan
    # detector already reads it; the exemption did not, so a skeptic spawned
    # without `--skeptic-role` (no linkage record) kept its target parked only
    # until the orphan grace lapsed, and then the target proceeded toward
    # retirement WHILE ITS SKEPTIC WAS MID-PASS. The argument for granting the
    # permissive direction here, stated because the orphan-side change
    # deliberately declined to make it:
    #   * the evidence is scoped to THIS round — files newer than the
    #     `skeptic-request` epoch, never "any request file exists", so #975's
    #     re-armed never-spawned park is untouched (a leftover from a prior
    #     round is older than the new request);
    #   * it is gated on a FRESH marker (`age <= hang` above), so a worker
    #     whose own await has died still lapses into the genuine-hang path;
    #   * a request file is written only by a skeptic's `ask` or the target's
    #     `ack`/`answer` on it — there is no other author, so its existence in
    #     this round IS a skeptic, unlinked but real.
    # The basis says so, so the row can name the evidence it rests on.
    if (( req != 0 )) && _idle_skeptic_channel_active "$name" "$req"; then
        _IDLE_SKEPTIC_PARK_BASIS="channel"
        return 0
    fi
    (( req == 0 )) && req="$mtime"
    grace=$(_idle_skeptic_orphan_grace)
    if (( now - req <= grace )); then
        _IDLE_SKEPTIC_PARK_BASIS="grace"
        return 0
    fi
    return 1
}

# Returns 0 (ORPHANED: fresh marker, NO live skeptic, past grace) / 1 (not
# orphaned). The complement of the exemption's failure case that is
# actionable — a marker the orchestrator must resolve by either spawning
# the skeptic or clearing the marker. A STALE marker (await died) is NOT
# orphaned here — it lapses via the hang check and resurfaces through
# normal idle classification (the genuine-hang path). $3 = live windows.
_idle_skeptic_orphaned() {
    local name="$1" now="$2" live="${3:-}"
    local safe; safe=$(wk_encode "$name")
    local state_dir="${STATE_DIR:-}"
    [[ -n "$state_dir" ]] || return 1
    local marker="${state_dir}/skeptic/pending/${safe}"
    [[ -e "$marker" ]] || return 1
    local hang mtime age
    hang=$(_idle_skeptic_hang_seconds)
    mtime=$(date +%s -r "$marker" 2>/dev/null || echo 0)
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    age=$(( now - mtime ))
    (( age <= hang )) || return 1
    _idle_skeptic_live_window "$name" "$live" >/dev/null && return 1
    local req grace
    req=$(_idle_skeptic_request_epoch "$name")
    [[ "$req" =~ ^[0-9]+$ ]] || req=0
    # Channel traffic in THIS round is a live skeptic the linkage record missed
    # (your-org/nexus-code#1153). Asked ONLY when a request epoch exists: with no
    # round clock there is nothing to scope the traffic to, and an unscoped test
    # is the false exemption documented on `_idle_skeptic_channel_active`.
    #
    # SUPPRESSING the orphan class is the safe direction. The same edit is
    # deliberately NOT made in `_idle_skeptic_parked`: granting the PARK
    # exemption on channel traffic is the permissive direction and needs its own
    # argument, which this change does not make.
    (( req != 0 )) && _idle_skeptic_channel_active "$name" "$req" && return 1
    (( req == 0 )) && req="$mtime"
    grace=$(_idle_skeptic_orphan_grace)
    (( now - req > grace ))
}

# ---- background-compute orphan-grace (your-org/nexus-code#445) -----------
#
# A SHELL-driven `working-background` verdict (pane-state.sh emits it
# with a `bg_cpu=<jiffies>` field) normally suppresses the idle probe —
# a worker running background compute (Palantir polling a job in a
# `run_in_background` shell, an `& disown` job) must NEVER be false-
# flagged `idle … WITHOUT wrap-up`. But a background shell is fire-and-
# forget: claude is not woken when it finishes, so a HUNG or
# doing-nothing shell would otherwise exempt the window forever. The
# cap: track the background subtree's CPU jiffies across cycles; while
# they advance the worker is genuinely computing (exempt), but once
# they FREEZE for the orphan grace the shell is doing nothing and the
# window falls back to normal idle classification (reapable). Mirrors
# the skeptic orphan-grace (`_idle_skeptic_orphaned`) and the #205
# pane-change stamp: stamp a token, advance the epoch only on change,
# let stasis age it out. A Monitor-handle working-background carries NO
# `bg_cpu` field (it is self-waking) and is never subjected to this cap.

# Orphan grace: how long a background shell's CPU may stay frozen
# before its `working-background` exemption lapses. Generous by design
# — the CPU-delta test means a live compute worker (any progress) never
# ages out regardless of this value, so the grace only bounds a truly
# frozen shell. Env > config > default 3600s.
_bg_orphan_grace_seconds() {
    local g="${MONITOR_BACKGROUND_ORPHAN_GRACE_SECONDS:-}"
    if [[ -z "$g" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        g=$("$NEXUS_ROOT/config/load.sh" monitor.background_orphan_grace_seconds 3600 2>/dev/null || echo 3600)
    fi
    [[ "$g" =~ ^[0-9]+$ ]] || g=3600
    printf '%s' "$g"
}

# Per-window background-CPU progress stamp: `<bg_cpu>\t<last_progress_epoch>`.
_bg_progress_path() {
    printf '%s/background-progress/%s' "${STATE_DIR:-$(_ip_nostate_dir)}" "$1"
}

# Record this cycle's bg_cpu for `window` at `now`, advancing
# `last_progress_epoch` to `now` iff the jiffy count DIFFERS from the
# stored one (or first sight — a freshly-observed background job starts
# corroborated). A repeated (identical) count leaves the epoch frozen —
# that frozen epoch is what lets a stalled shell age out. Echoes the
# resolved `last_progress_epoch`. Forgiving: any failure echoes `now`
# (treat as progressing — bias toward NOT reaping a live worker).
_bg_progress_check() {
    local window="$1" bg_cpu="$2" now="$3" path tmp prev_cpu prev_epoch new_epoch
    [[ -n "$window" && "$bg_cpu" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || { printf '%s' "$now"; return 0; }
    path=$(_bg_progress_path "$window")
    prev_cpu=""; prev_epoch=0
    if [[ -f "$path" ]]; then
        IFS=$'\t' read -r prev_cpu prev_epoch < "$path" 2>/dev/null
        [[ "$prev_epoch" =~ ^[0-9]+$ ]] || prev_epoch=0
    fi
    if [[ "$bg_cpu" == "$prev_cpu" ]]; then
        new_epoch="$prev_epoch"
        (( new_epoch > 0 )) || new_epoch="$now"
    else
        new_epoch="$now"
    fi
    mkdir -p "$(dirname "$path")" 2>/dev/null || { printf '%s' "$new_epoch"; return 0; }
    tmp="${path}.$$.tmp"
    if printf '%s\t%s\n' "$bg_cpu" "$new_epoch" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    printf '%s' "$new_epoch"
}

# Drop `window`'s background-progress stamp (disappearance prune). A
# reused window-name then starts fresh (first-sight = corroborated).
_bg_progress_drop() {
    local window="$1"
    [[ -n "$window" ]] || return 1
    rm -f "$(_bg_progress_path "$window")" 2>/dev/null || true
}

# ---- idle-with-children long timeout + clarification protocol -----------
# your-org/nexus-code#455 refine.
#
# The #445/#455 detector already tells us when an otherwise-idle worker
# still has ≥1 live background-shell child (state=working-background,
# bg_shells>=1, bg_reliable=1). Two refinements ride on that signal:
#
#   (a) A worker legitimately WAITING on a background job (a Slurm job
#       polled by a shell, a blocking `sbatch --wait`, a long compute)
#       must get a LONG, EXPONENTIALLY-BACKING-OFF grace before any
#       nudge — never reaped just because its child's CPU froze (a
#       blocking wait shows no CPU). The flat #445 orphan-grace reaped
#       such a worker after one hour; a Slurm job can run for many.
#       Instead we escalate a clarification request on a backing-off
#       schedule and only surface as reapable at a bounded hard ceiling.
#
#   (b) A worker that has already WRAPPED UP but STILL has live child
#       processes is in an inconsistent state (leftover/stale children,
#       or a premature wrap while a job runs). Surface it distinctly —
#       EXCEPT when a skeptic is pending, which is case (c).
#
#   (c) A worker parked in `skeptic-channel await` reaches (b)'s exact
#       shape BY DESIGN: `ng wrap-up` writes the skeptic-pending marker,
#       then the worker holds its re-check loop in a background shell.
#       That is `parked-awaiting-skeptic`, not an inconsistency. The
#       marker ($STATE_DIR/skeptic/pending/<window>) is authoritative;
#       when it goes stale the park lapses and (b) resurfaces.
#
# In all cases the orchestrator can inject a clarification prompt (the
# existing paste/nudge channel) instructing the worker to answer via a
# file — `monitor/worker-health.sh` writes
# `$STATE_DIR/worker-health/<window>.json`; the watcher reads it here to
# extend the grace (declared runtime), reap (stuck/done), or keep asking.
#
# DESIGN PRIORITY (your-org/nexus-code#455 follow-up — this INVERTS the
# priority PR #455 originally shipped with, which was "never false-idle a
# live worker"). The operator's ordering is:
#
#   1. Never let a worker linger forever. We would rather misclassify a
#      live worker as a retire CANDIDATE than have it stick around
#      indefinitely. Every exemption is therefore bounded by an absolute
#      ceiling that neither a worker-health declaration nor a
#      CPU-advancing child can postpone.
#   2. Inconsistent states are SURFACED for the orchestrator to
#      investigate — never silently suppressed, never auto-killed.
#
# The safety valve is unchanged and lives elsewhere: this probe only ever
# PROPOSES a class. `monitor/retire-preflight.sh` is the gate that decides
# an actual kill, and it independently refuses (safe=0) on a live worker,
# a pending skeptic, or an engaged operator. Detectors propose; preflight
# disposes.

# Backoff schedule constants (env- and config-overridable).
#
# BASE IS A CPU-FREEZE CLOCK, NOT A PROGRESS CLOCK, AND IT IS NOT THE PRIMARY
# BOUND (your-org/nexus-code#1221). It measures seconds since `bg_cpu` --
# utime+stime summed over the LIVE processes in the background-shell subtrees,
# with cutime/cstime deliberately excluded, so an exited child contributes
# nothing -- last CHANGED (`_bg_progress_check`, above). A single jiffy of
# advance resets it to zero however stale it was, so `bg_stall_age >= bg_base`
# is reachable ONLY while the subtree burns fewer than 1 jiffy (10 ms) per
# `base` seconds: 2.8 parts per million of one CPU at the 3600 s default.
#
# ITS CONSTITUENCY IS A CHILD THAT FORKS NOTHING -- a blocking wait
# (`sbatch --wait`, bare `wait`, `read` on a fifo, `flock`). Measured on this
# host: 0 jiffies over 90 s, so the grace IS the operative bound for that
# shape and fires 47 hours before the ceiling would.
#
# IT IS NOT THE BOUND FOR A POLL LOOP. Measured: ~1 jiffy per 51 fork+exec
# iterations, so `until …; do sleep N; done` advances every ~51*N seconds and
# defeats base for every N below ~70 s -- and by orders of magnitude for any
# loop body doing real work. The bound that binds a polling child is
# `bg_child_age >= bg_ceiling`, the INDEPENDENT `||` disjunct at the call site
# below, which a CPU-advancing child cannot reset.
#
# THE SENTENCE THIS COMMENT MUST NEVER BECOME: "the grace bounds a child that
# has stopped making progress." It bounds a child that has stopped BURNING
# CPU. Those diverge by five orders of magnitude, and that divergence is
# exactly the defect #1221 reports.
_bg_children_grace_base_seconds() {
    local v="${MONITOR_BG_CHILDREN_GRACE_BASE_SECONDS:-}"
    if [[ -z "$v" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        v=$("$NEXUS_ROOT/config/load.sh" monitor.background_children_grace_base_seconds 3600 2>/dev/null || echo 3600)
    fi
    [[ "$v" =~ ^[0-9]+$ ]] || v=3600
    printf '%s' "$v"
}
_bg_children_backoff_mult() {
    local v="${MONITOR_BG_CHILDREN_BACKOFF_MULT:-}"
    if [[ -z "$v" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        v=$("$NEXUS_ROOT/config/load.sh" monitor.background_children_backoff_multiplier 2 2>/dev/null || echo 2)
    fi
    [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 1 )) || v=2
    printf '%s' "$v"
}
_bg_children_interval_cap_seconds() {
    local v="${MONITOR_BG_CHILDREN_INTERVAL_CAP_SECONDS:-}"
    if [[ -z "$v" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        v=$("$NEXUS_ROOT/config/load.sh" monitor.background_children_interval_cap_seconds 21600 2>/dev/null || echo 21600)
    fi
    [[ "$v" =~ ^[0-9]+$ ]] || v=21600
    printf '%s' "$v"
}
_bg_children_grace_ceiling_seconds() {
    local v="${MONITOR_BG_CHILDREN_GRACE_CEILING_SECONDS:-}"
    if [[ -z "$v" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        v=$("$NEXUS_ROOT/config/load.sh" monitor.background_children_grace_ceiling_seconds 172800 2>/dev/null || echo 172800)
    fi
    [[ "$v" =~ ^[0-9]+$ ]] || v=172800
    printf '%s' "$v"
}
_worker_health_slack_seconds() {
    local v="${MONITOR_WORKER_HEALTH_SLACK_SECONDS:-}"
    if [[ -z "$v" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        v=$("$NEXUS_ROOT/config/load.sh" monitor.worker_health_slack_seconds 600 2>/dev/null || echo 600)
    fi
    [[ "$v" =~ ^[0-9]+$ ]] || v=600
    printf '%s' "$v"
}

# Per-window backoff state: `<child_sig>\t<level>\t<last_escalation_epoch>`.
_bg_backoff_path() { printf '%s/bg-backoff/%s' "${STATE_DIR:-$(_ip_nostate_dir)}" "$1"; }

# Read the backoff row; echoes `<sig>\t<level>\t<last_esc>`. `sig` is `-`
# (a sentinel, never a real child count) when the state file is
# absent/malformed — a bare empty first field does NOT round-trip through
# `read` because a leading tab is IFS whitespace and gets stripped.
_bg_backoff_read() {
    local window="$1" path sig level last
    path=$(_bg_backoff_path "$window")
    sig="-"; level=0; last=0
    if [[ -f "$path" ]]; then
        IFS=$'\t' read -r sig level last < "$path" 2>/dev/null
        [[ -n "$sig" ]] || sig="-"
        [[ "$level" =~ ^[0-9]+$ ]] || level=0
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
    fi
    printf '%s\t%s\t%s' "$sig" "$level" "$last"
}
_bg_backoff_write() {
    # No-op in read-only mode so a count-only probe pass never advances the
    # edge-triggered backoff level (see _bg_children_decide).
    [[ -z "${MONITOR_IDLE_PROBE_READONLY:-}" ]] || return 0
    local window="$1" sig="$2" level="$3" last="$4" path tmp
    path=$(_bg_backoff_path "$window")
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
    tmp="${path}.$$.tmp"
    if printf '%s\t%s\t%s\n' "$sig" "$level" "$last" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
}
_bg_backoff_drop() {
    local window="$1"
    [[ -n "$window" ]] || return 1
    rm -f "$(_bg_backoff_path "$window")" 2>/dev/null || true
}

# The with-children EPISODE age is DERIVED, never stored (your-org/nexus-code#455
# follow-up, round-2 skeptic finding). `pane-state.sh` reads the start epoch of
# the oldest background-shell root straight off the process tree and emits it as
# `bg_oldest_start=`; the probe subtracts it from `now`.
#
# The first cut of this stored the episode start in a `bg-firstseen` state file
# and inferred "the episode ended" from the pane state. That shape cannot be
# made correct. Keying the file on the child COUNT let ordinary churn reset the
# ceiling; keying the reset on the pane state traded that for a worse vector,
# because `autosuggest-only` is emitted from the renderer ladder BEFORE the
# process tree is ever walked (`pane-state.sh`, the `_finalize_idle_verdict`
# bypass) — so a single dim autosuggest ghost silently deleted the clock. And
# no assignment of authority to pane states fixes both that and the
# busy-boundary inheritance case: they pull in opposite directions.
#
# Deriving the age removes the entire class. It is immune to child-count churn,
# to a child exiting, to any pane rendering, and to a watcher restart. There is
# no state file to migrate, leak, or go stale.

# Worker-health clarification file, written by monitor/worker-health.sh.
_worker_health_path() { printf '%s/worker-health/%s.json' "${STATE_DIR:-$(_ip_nostate_dir)}" "$1"; }
_worker_health_drop() {
    local window="$1"
    [[ -n "$window" ]] || return 1
    rm -f "$(_worker_health_path "$window")" 2>/dev/null || true
}

# Read + validate the worker-health file for `window`. On a well-formed
# file echoes `<health>\t<expected_runtime_s>\t<written_at>\t<job_kind>\t<job_id>`
# and returns 0; returns 1 (no output) when absent/unparseable. `written_at`
# falls back to the file mtime when the field is missing. `health` is
# normalised to one of running|done|stuck (else treated as absent).
_worker_health_read() {
    local window="$1" path health expected written kind id
    path=$(_worker_health_path "$window")
    [[ -f "$path" && -r "$path" ]] || return 1
    if command -v jq >/dev/null 2>&1; then
        local row
        row=$(jq -r '[(.health // ""),
                      (.expected_runtime_s // 0),
                      (.written_at // 0),
                      (.job_kind // ""),
                      (.job_id // "")] | @tsv' "$path" 2>/dev/null) || return 1
        [[ -n "$row" ]] || return 1
        IFS=$'\t' read -r health expected written kind id <<<"$row"
    else
        # jq-less fallback: crude field extraction.
        local content
        content=$(<"$path") || return 1
        health=$(printf '%s' "$content" | sed -n 's/.*"health"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')
        expected=$(printf '%s' "$content" | sed -n 's/.*"expected_runtime_s"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
        written=$(printf '%s' "$content" | sed -n 's/.*"written_at"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
        kind=$(printf '%s' "$content" | sed -n 's/.*"job_kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        id=$(printf '%s' "$content" | sed -n 's/.*"job_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi
    [[ "$expected" =~ ^[0-9]+$ ]] || expected=0
    if ! [[ "$written" =~ ^[0-9]+$ ]] || (( written == 0 )); then
        written=$(stat -c %Y "$path" 2>/dev/null || echo 0)
        [[ "$written" =~ ^[0-9]+$ ]] || written=0
    fi
    case "$health" in
        running|done|stuck) : ;;
        *) health="" ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s' "$health" "$expected" "$written" "$kind" "$id"
}

# Is this window's most-recent lifecycle event a wrap-up (i.e. wrapped and
# NOT superseded by a newer machine/operator re-task submit)? Used by the
# case-(b) inconsistency detector. Returns 0 (wrapped) / 1 (not wrapped).
_bg_window_is_wrapped() {
    local window="$1" wrap_epoch msub_epoch
    _idle_window_wrap_up_report "$window" >/dev/null 2>&1 || return 1
    wrap_epoch=$(_openg_wrap_epoch "$window")
    [[ "$wrap_epoch" =~ ^[0-9]+$ ]] && (( wrap_epoch > 0 )) || return 1
    msub_epoch=$(_openg_machine_submit_epoch "$window")
    if [[ "$msub_epoch" =~ ^[0-9]+$ ]] && (( msub_epoch > wrap_epoch )); then
        return 1   # re-tasked after wrap-up → not a wrapped state
    fi
    return 0
}

# Case (a): decide what an idle-with-live-children worker (NOT wrapped)
# should surface this cycle. Reads/writes the backoff state and honours a
# worker-health declaration. Args:
#   window now stall_start_epoch child_count oldest_child_start_epoch
# Consults the worker-health file directly. Prints `<class>\t<detail>`.
# Classes: idle-awaiting-job | idle-children-clarify | idle-too-long.
#
# The hard ceiling is ABSOLUTE (your-org/nexus-code#455 follow-up). It is
# tested before the worker-health override and against `bound_age` — the max of
# the CPU-freeze age and the with-children EPISODE age (derived from the oldest
# live background shell's start time) — so neither a `running` declaration, nor
# a child that burns a jiffy per poll, nor background shells coming and going,
# nor an `autosuggest-only` render can suppress the window past the ceiling.
# Past it the window surfaces as a retire CANDIDATE; retire-preflight remains
# the gate that decides an actual kill.
_bg_children_decide() {
    local window="$1" now="$2" stall_start="$3" child_count="$4" oldest_start="${5:-0}"
    # Read-only mode (MONITOR_IDLE_PROBE_READONLY): the prelude/full-state/
    # canonical paths call list_really_idle_workers purely to COUNT, and both
    # they and the authoritative transition emit (render_idle_section) run per
    # cycle. The backoff level-advance is edge-triggered, so if a count-only
    # call committed the escalation first, the authoritative call would see it
    # already advanced and emit `idle-awaiting-job` instead of the due
    # `idle-children-clarify` — the nudge would be lost. In read-only mode we
    # compute the class from current state but persist NOTHING (no level
    # advance, no health-file prune), so only the authoritative emit mutates.
    local ro="${MONITOR_IDLE_PROBE_READONLY:-}"
    local sig level last row
    row=$(_bg_backoff_read "$window")
    IFS=$'\t' read -r sig level last <<<"$row"
    [[ "$level" =~ ^[0-9]+$ ]] || level=0
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [[ "$sig" != "-" && "$sig" != "$child_count" ]]; then
        # The child set CHANGED across cycles → a new job started. Reset the
        # backoff and invalidate the now-stale per-job health declaration (a
        # new job earns a new grace and a fresh declaration). `-` is the
        # no-prior-state sentinel, never a real count, so it is NOT a change.
        [[ -n "$ro" ]] || _worker_health_drop "$window"
        level=0; last="$stall_start"
    elif (( last == 0 )); then
        # First sight (no prior backoff state). Initialise the clock to the
        # stall start — but do NOT drop the health file: a worker may have
        # answered the clarification before we ever wrote backoff state.
        level=0; last="$stall_start"
    fi
    sig="$child_count"
    [[ "$last" =~ ^[0-9]+$ ]] && (( last > 0 )) || last="$now"

    local base mult cap ceiling slack stall_age child_age bound_age
    base=$(_bg_children_grace_base_seconds)
    mult=$(_bg_children_backoff_mult)
    cap=$(_bg_children_interval_cap_seconds)
    ceiling=$(_bg_children_grace_ceiling_seconds)
    slack=$(_worker_health_slack_seconds)
    stall_age=$(( now - stall_start ))
    (( stall_age >= 0 )) || stall_age=0
    # `child_age` is the with-children EPISODE age, derived from the oldest
    # live background-shell's start time. Nothing but that shell exiting can
    # move it: not the child count, not the pane rendering, not a restart.
    child_age=0
    if [[ "$oldest_start" =~ ^[0-9]+$ ]] && (( oldest_start > 0 )) && (( now > oldest_start )); then
        child_age=$(( now - oldest_start ))
    fi
    bound_age="$stall_age"
    (( child_age > bound_age )) && bound_age="$child_age"

    # ABSOLUTE hard ceiling — tested BEFORE the worker-health override and
    # against `bound_age`, so no declaration and no CPU-advancing child can
    # hold the window exempt indefinitely. Past the ceiling the window becomes
    # a retire CANDIDATE (the orchestrator's retire-preflight still gates the
    # kill, and a live declaration is echoed so the investigation has context).
    if (( bound_age >= ceiling )); then
        _bg_backoff_write "$window" "$sig" "$level" "$last"
        local ceil_note="no health decl"
        local c_health c_expected c_written c_kind c_id c_row
        if c_row=$(_worker_health_read "$window"); then
            IFS=$'\t' read -r c_health c_expected c_written c_kind c_id <<<"$c_row"
            [[ -n "$c_health" ]] && ceil_note="worker declared ${c_health}${c_kind:+ (${c_kind}${c_id:+ $c_id})}"
        fi
        printf 'idle-too-long\t%d child(ren) idle %ds past the %ds ceiling; %s — retire candidate (investigate, then retire-preflight)' \
            "$child_count" "$bound_age" "$ceiling" "$ceil_note"
        return 0
    fi

    # Worker-health override. A `running` declaration extends the exemption up
    # to — but never past — the ceiling: the deadline is clamped so a worker
    # cannot declare (or repeatedly re-declare) its way out of ever surfacing.
    local h_health h_expected h_written h_kind h_id health_row
    if health_row=$(_worker_health_read "$window"); then
        IFS=$'\t' read -r h_health h_expected h_written h_kind h_id <<<"$health_row"
        case "$h_health" in
            running)
                local deadline=$(( h_written + h_expected + slack ))
                local ceil_deadline=$(( now + ceiling - bound_age ))
                local clamp_note=""
                if (( deadline > ceil_deadline )); then
                    deadline="$ceil_deadline"
                    clamp_note=", clamped to ceiling"
                fi
                if (( now < deadline )); then
                    _bg_backoff_write "$window" "$sig" "$level" "$last"
                    printf 'idle-awaiting-job\t%d child(ren); declared %s%s ~%ds (running, %ds left%s)' \
                        "$child_count" "${h_kind:-job}" "${h_id:+ $h_id}" "$h_expected" \
                        "$(( deadline - now ))" "$clamp_note"
                    return 0
                fi
                # Declared runtime elapsed → resume nudging (fall through).
                ;;
            stuck)
                _bg_backoff_write "$window" "$sig" "$level" "$last"
                printf 'idle-children-clarify\t%d child(ren); worker reports STUCK — resume or close' \
                    "$child_count"
                return 0
                ;;
            done)
                _bg_backoff_write "$window" "$sig" "$level" "$last"
                printf 'idle-children-clarify\t%d child(ren); worker reports job DONE — leftover children, safe to close' \
                    "$child_count"
                return 0
                ;;
        esac
    fi

    # Exponential-backoff nudge schedule. interval(level) = base * mult^level,
    # capped. A nudge is due when the last escalation is interval-old.
    local interval="$base" i
    for (( i = 0; i < level; i++ )); do
        interval=$(( interval * mult ))
        (( interval >= cap )) && { interval="$cap"; break; }
    done
    (( interval <= cap )) || interval="$cap"

    if (( now - last >= interval )); then
        level=$(( level + 1 ))
        _bg_backoff_write "$window" "$sig" "$level" "$now"
        printf 'idle-children-clarify\t%d child(ren) idle %ds waiting on a background job (nudge L%d) — ask the worker to declare runtime/health via monitor/worker-health.sh' \
            "$child_count" "$bound_age" "$level"
        return 0
    fi

    _bg_backoff_write "$window" "$sig" "$level" "$last"
    printf 'idle-awaiting-job\t%d child(ren) idle %ds; long-timeout backoff active (next check ~%ds, ceiling in %ds)' \
        "$child_count" "$bound_age" "$(( last + interval - now ))" "$(( ceiling - bound_age ))"
    return 0
}

# Case (b): compose the wrapped-with-children detail (health-aware).
#
# $3 NAMES the child (your-org/nexus-code#590). The pre-#590 message reported a
# COUNT and demanded a decision — "1 live child process(es) after wrap-up — ask
# for clarification or close" — which is not enough to act on: identifying the
# process took a manual walk of the pane's tree, and it was misidentified in
# practice (blamed on an MCP server, which is never even counted). Naming it
# lets anyone dismiss or escalate in seconds.
_bg_wrapped_children_detail() {
    local window="$1" child_count="$2" child_name="${3:-}"
    local who=""
    [[ -n "$child_name" && "$child_name" != "-" ]] && who=" [child: $child_name]"
    local h_health h_expected h_written h_kind h_id health_row
    if health_row=$(_worker_health_read "$window"); then
        IFS=$'\t' read -r h_health h_expected h_written h_kind h_id <<<"$health_row"
        case "$h_health" in
            running) printf '%d live child(ren) after wrap-up%s; worker declares job still RUNNING (wrapped prematurely) — extend or close' "$child_count" "$who"; return 0 ;;
            done)    printf '%d live child(ren) after wrap-up%s; worker declares job DONE — leftover, safe to close' "$child_count" "$who"; return 0 ;;
            stuck)   printf '%d live child(ren) after wrap-up%s; worker reports STUCK — resume or close' "$child_count" "$who"; return 0 ;;
        esac
    fi
    printf '%d live child process(es) after wrap-up%s — ask for clarification (monitor/worker-health.sh) or close' "$child_count" "$who"
}

# ---- skeptic-await recognition (your-org/nexus-code#1183) -------------------
#
# Does a RECORDED COMMAND LINE invoke `skeptic-channel.sh await`? Decided by a
# PROPERTY of the argv, not by a substring of it — the distinction #1121 is
# about. The first version required argv[0] to BE the script, which missed the
# form the documentation PRESCRIBES: `skills/nexus.skeptic/SKILL.md` tells every
# worker to run `monitor/skeptic-channel.sh await <task>; rc=$?; …`, a `;`-list
# that async-run.sh records as `bash -c '<list>'`. Measured on the primary's
# live async-run state at the reopen: 20 awaits matched, SEVEN were missed —
# `bash <path>/skeptic-channel.sh await …` (6) and `bash -c '<list>'` (1) — and
# all seven were told to install a second listener, the one action #1178
# forbids.
#
# A substring test (`*skeptic-channel.sh*` and `* await *`, which is what
# skeptic-channel.sh's own `_await_pid_is_ours` uses) would recognise all
# seven — and also `bash -c 'echo skeptic-channel.sh await x is armed'`, a
# `grep` over a log, or any prompt that quotes the phrase. That over-match is
# precisely what the strict predicate was written to prevent, so the fix
# keeps the property and widens the PARSE: strip the interpreter and wrapper
# words that can precede a command, split a `-c` list at its command
# boundaries, and require that some COMMAND POSITION holds the script with
# `await` as its first argument. An `echo`, a `grep` or a prompt puts the
# phrase in an ARGUMENT position, never in a command position.
#
# `_idle_words_are_skeptic_await <word>…` — one simple command, already
# word-split. Prints the awaited TASK (the word after `await`, "" when absent)
# and returns 0 iff word0 is the script and word1 is `await`, after stripping
# leading `VAR=value` assignments and known wrappers (an interpreter, `command`,
# `exec`, `nohup`, `setsid`, `time`, `timeout [opts] DURATION`). An interpreter
# followed by `-c` is NOT a direct invocation and returns 1 here; the caller
# parses that form.
_idle_words_are_skeptic_await() {
    # ONE definition, shared with the await lock (your-org/nexus-code#1426):
    # `monitor/_proc_argv.sh` carries the parser this function used to hold
    # (#1183). The probe's n_await recognition and skeptic-channel.sh's
    # ownership check must agree on what an await IS, or a waiter the probe
    # counts is one the lock refuses to reap, and vice versa. Absent library →
    # rc 1 (not an await): the fail-CLOSED direction for n_await.
    _idle_proc_argv_lib || return 1
    proc_words_are_skeptic_await "$@"
}

# `_idle_argv_skeptic_await_task <nul-separated-argv-file>` — the recorded
# argv of an async-run job (`<token>/argv`) or a live process
# (`/proc/<pid>/cmdline`; same encoding). Prints the awaited task and returns
# 0 iff the command line INVOKES `skeptic-channel.sh await`, in either the
# direct form (optionally behind an interpreter or wrapper) or the
# `<shell> [opts] -c '<list>'` form. Returns 1 for everything else, including
# a `-c` list that merely MENTIONS the script.
_idle_argv_skeptic_await_task() {
    _idle_proc_argv_lib || return 1
    proc_argv_skeptic_await_task "$@"
}

# Source monitor/_proc_argv.sh once, relative to this file. rc 1 (and one
# stderr line, once) when it is missing — the callers treat that as "not an
# await", never as an error that stops the probe.
_IDLE_PROC_ARGV_STATE=""
_idle_proc_argv_lib() {
    case "$_IDLE_PROC_ARGV_STATE" in ok) return 0 ;; missing) return 1 ;; esac
    local lib; lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_proc_argv.sh"
    if [[ -r "$lib" ]] && source "$lib"; then _IDLE_PROC_ARGV_STATE=ok; return 0; fi
    _IDLE_PROC_ARGV_STATE=missing
    echo "_idle_probe: monitor/_proc_argv.sh missing — no process will be recognised as a skeptic await (fail-closed, your-org/nexus-code#1426)" >&2
    return 1
}

# `_idle_orphan_blank_flags <token-dir>` (your-org/nexus-code#1355) — for a
# FINISHED async-run job: prints `b` when rc=0 AND both capture files exist
# and are 0 B (the shape async-run.sh _evidence mode 1 flags), `bx` when in
# addition the recorded argv redirects its own output (a `>` or a `tee`), and
# nothing otherwise. Scoped to rc=0 by the issue: a NON-ZERO rc with empty
# streams is a status. A MISSING capture file is `?` to async-run.sh, not a
# zero, and is not counted here either.
_idle_orphan_blank_flags() {
    local d="$1" rc=""
    rc=$(sed -n 's/^rc=//p' "$d/status" 2>/dev/null); rc="${rc%%$'\n'*}"
    [[ "$rc" == 0 ]] || return 0
    [[ -f "$d/out" && ! -s "$d/out" && -f "$d/err" && ! -s "$d/err" ]] || return 0
    local argv_txt=""
    [[ -r "$d/argv" ]] && { argv_txt=$(tr '\0' ' ' < "$d/argv" 2>/dev/null) || argv_txt=""; }
    if [[ "$argv_txt" == *">"* || "$argv_txt" == *" tee "* || "$argv_txt" == *"/tee "* ]]; then
        printf 'bx'
    else
        printf 'b'
    fi
    return 0
}

# `_idle_skeptic_await_armed <task> [now]` — is the await on channel <task>
# LIVE, by the channel's OWN record? The issue's ask, previously carried only
# as prose inside the advice string: `.await-owner` must name a pid whose
# cmdline is itself a `skeptic-channel.sh await <task>` (the same property,
# read off /proc, so a recycled pid cannot satisfy it), and `.await-heartbeat`
# must be within the await-hang threshold. ANY DOUBT RETURNS 1 — a stale
# await genuinely is an orphan and keeps the running/orphan treatment.
_idle_skeptic_await_armed() {
    local task="$1" now="${2:-}"
    [[ -n "$task" ]] || return 1
    [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
    local enc; enc=$(wk_encode "$task" 2>/dev/null) || return 1
    [[ -n "$enc" ]] || return 1
    local dir="${STATE_DIR:-$(_ip_nostate_dir)}/skeptic/${enc}" owner="" hb="" otask=""
    [[ -r "$dir/.await-owner" && -r "$dir/.await-heartbeat" ]] || return 1
    # `<pid> <starttime>` since your-org/nexus-code#1426 (residual 1b); the
    # first field is the pid either way.
    read -r owner _ < "$dir/.await-owner" 2>/dev/null || owner=""
    owner="${owner//[^0-9]/}"
    [[ "$owner" =~ ^[0-9]+$ ]] || return 1
    [[ -r "/proc/$owner/cmdline" ]] || return 1
    otask=$(_idle_argv_skeptic_await_task "/proc/$owner/cmdline") || return 1
    [[ "$otask" == "$task" ]] || return 1
    IFS= read -r hb < "$dir/.await-heartbeat" 2>/dev/null || hb=""
    hb="${hb//[^0-9]/}"
    [[ "$hb" =~ ^[0-9]+$ ]] || return 1
    local hang; hang=$(_idle_skeptic_hang_seconds)
    (( now - hb <= hang )) || return 1
    return 0
}

# Resolve a window's declared async waits to `terminal` or `unresolved`
# (your-org/nexus-code#1240).
#
# WHY THIS EXISTS. The orchestrator advisory for `idle-orphan-async` says, in
# effect, "a wait you have not confirmed dead must not be cleared". For a
# `died` or `running` job that is correct and stays. For a job that has
# ALREADY FINISHED it inverts: the job is confirmed finished, the correct
# action is precisely to clear the wait, and the sentence forbids it -- the
# reader can never satisfy a "confirmed dead" condition for a job that
# terminated normally, so the text has no exit. Seven instances were recorded
# across two evenings, every one on a job that had exited rc=0, one of them
# stale for sixteen hours and re-flagged on the same token after the worker
# had already published that job's results.
#
# WHY A STAT FIRST, AND THEN `async-run.sh --status-line`. SUPERSEDED IN PART
# by your-org/nexus-code#1333 — this paragraph is kept because its cost argument
# still governs, and CORRECTED because its conclusion no longer does.
#
# STILL TRUE: the `[[ -s status ]]` fast path stays, and it is what keeps the
# cost bounded — the delegated call is reached ONLY for a wait with no status
# file, the minority case (2 of 13 measured).
#
# NO LONGER TRUE, and this is the sentence #1333 refuted: "Two-valued is
# exactly the split the guidance turns on." It is not. A job CANCELLED by its
# owner and one that DIED unattended both land in pid-gone-and-no-status, and
# they have OPPOSITE operator responses. `_verdict` emits SIX states and is the
# only thing that separates them.
#
# AND THE ~580x RATIO COMPARES THE WRONG PAIR. It is `--status-line` against a
# STAT; the call this actually replaced is `proc-exists-authorized`, itself a
# shell-out. Re-measured on this host, 5-run means: `--status-line` 352 ms
# against `proc-exists-authorized` 316 ms — an 11% change on the same bounded
# path, not 580x. Quoted here so the next reader revisiting the budget is not
# stopped by a ratio that was never about this substitution.
#
# FAIL-CLOSED EVERYWHERE. Anything not positively established terminal --
# a truncated list, a non-`asyncrun` kind, a token that is not `ar-*`, an
# unresolvable window, an empty list -- returns `unresolved` and keeps the
# existing text. The truncation arm matters most and is the same reasoning
# `_orphan_async_waits_truncated` records: `orphan_kinds` is capped at 80
# chars, and "the waits I can see are all terminal" says nothing about the
# ones the cap removed. Failing closed here costs a worker one advisory it
# could have been spared; failing open tells a worker its running job is over.
#
# THREE STATES, NOT TWO (your-org/nexus-code#1292). The first cut answered
# `terminal` or `unresolved`, which was enough to fix the guidance text but
# collapsed two genuinely different situations into one word. Measured across
# every window emitting `waits=` on this board: 11 of 13 listed waits had a
# terminal `rc=` on disk, stale from 5 to 304 minutes — and the two that did
# NOT, the genuinely indeterminate ones the warning actually exists for, were
# invisible among them.
#
#   terminal    a `status` file exists: the job has ended, whatever its rc.
#   running     no status, and the recorded (pid, pidstart) still identifies a
#               live process: work really is in flight.
#   unresolved  everything else — including no status with the process gone
#               (the died shape) — and every doubt.
#
# `(pid, pidstart)`, NEVER pid ALONE. The recycled-pid case is not
# hypothetical; it occurred in that sample, a recorded pid still present in
# /proc carrying starttime 911215293 against a recorded 910769323. A liveness
# check on the pid alone reports ALIVE, and a kill on it hits a stranger. That
# is why `pidstart` is written beside `pid`. The identity discipline is
# UNCHANGED and is still not re-derived here — but since #1333 it is
# `async-run.sh`'s own `_pid_alive` that applies it, reached through
# `--status-line`, NOT `monitor/proc-exists-authorized`. `_pid_alive` reads
# /proc field 22 directly with the same (pid, pidstart) pair, so the
# recycled-pid case above is still refused; only the DELEGATE changed.
#
# COST is bounded by construction: the primitive is invoked ONLY for a wait
# with no `status` file, the minority case (2 of 13 measured). An ended job is
# settled by the stat alone.
_idle_orphan_wait_class() {
    local window="$1" kinds="$2" pair kind tok root enc
    local n=0 n_term=0 n_run=0 n_died=0 n_untr=0 n_canc=0 n_await=0 n_blank=0 n_redir=0 _bl=""
    if ! enc=$(wk_encode "$window" 2>/dev/null) || [[ -z "$enc" ]]; then
        printf 'unresolved|-'; return 0
    fi

    # AUTHORITATIVE LIST FIRST (your-org/nexus-code#1295 review). The caller
    # passes pane-state`s `orphan_kinds`, which is capped at 80 chars for
    # DISPLAY. An `asyncrun:ar-xxxxxxxxxxxx` entry is 24 chars plus a comma, so
    # the cap truncates at FOUR waits — and the first cut of this function
    # fail-closed on truncation, which made it INERT for every window with 4 or
    # more. Measured against the population it was written for: it reached 1 of
    # the 4 windows in #1292`s own table, and 0 of the two 13- and 11-wait
    # windows an operator had to sort BY HAND. A guard that does not fire at
    # the cardinality its defect occurs at is not a guard.
    #
    # So read `external_waits` from the heartbeat, which is the same record
    # pane-state derived the capped string FROM and is uncapped. The capped
    # string remains the fallback, still fail-closed on its ellipsis, for the
    # case where the heartbeat cannot be read at all.
    local full="" hb="${STATE_DIR:-$(_ip_nostate_dir)}/heartbeat/${enc}.json"
    if [[ -r "$hb" ]] && command -v jq >/dev/null 2>&1; then
        full=$(jq -r 'if (.external_waits | type) == "array" then
                          (.external_waits | map("\(.kind):\(.id)") | join(","))
                      else empty end' "$hb" 2>/dev/null) || full=""
    fi
    if [[ -z "$full" ]]; then
        # Fallback: the DISPLAY string. Fail closed on truncation — a list we
        # cannot vouch for never satisfies a terminating condition.
        if [[ -z "$kinds" || "$kinds" == unknown || "$kinds" == *…* ]]; then
            printf 'unresolved|-'; return 0
        fi
        full="$kinds"
    fi

    root="${STATE_DIR:-$(_ip_nostate_dir)}/async-run/${enc}"
    # `_pea` is GONE: since #1333 liveness is decided by `async-run.sh`s own
    # `_pid_alive` via `--status-line`, and an assigned-but-unused resolver is
    # the greppable proof that a comment above has gone stale.
    local _ar="" _d
    _d=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || _d=""
    [[ -n "$_d" && -r "$_d/../async-run.sh" ]] && _ar="$_d/../async-run.sh"

    # `tr` rather than IFS word-splitting: zsh does NOT split an unquoted
    # parameter, so `for p in $full` would iterate ONCE over the whole string.
    while IFS= read -r pair; do
        [[ -n "$pair" ]] || continue
        n=$(( n + 1 ))
        kind="${pair%%:*}"
        tok="${pair#*:}"
        # UNTRACKED, the fourth state. A `nohup` or `slurm` wait carries a
        # synthetic id with no async-run directory, no pid, no pidstart and no
        # status — unresolvable BY CONSTRUCTION rather than merely stale, which
        # is a different fact and a different remedy. Measured live: 7 `nohup`
        # waits on one window, 5 on two others. Reported apart so it stops
        # being counted as evidence that something might still be running.
        if [[ "$kind" != asyncrun || "$tok" != ar-* || ! -d "${root}/${tok}" ]]; then
            n_untr=$(( n_untr + 1 )); continue
        fi
        if [[ -s "${root}/${tok}/status" ]]; then
            n_term=$(( n_term + 1 ))
            # your-org/nexus-code#1355: b= finished rc=0 with 0 B/0 B, x= of
            # those, argv redirects its own output. Read by uncorr() in the
            # emit so the empty-streams sentence is SCOPED and FAITHFUL.
            _bl=$(_idle_orphan_blank_flags "${root}/${tok}")
            [[ "$_bl" == b* ]] && n_blank=$(( n_blank + 1 ))
            [[ "$_bl" == bx ]] && n_redir=$(( n_redir + 1 ))
            continue
        fi
        # ASK THE AUTHORITY, DO NOT RESTATE IT (your-org/nexus-code#1333).
        # This used to hand-roll a two-state subset of async-run.sh's `_verdict`,
        # which already emits SIX: terminal | cancelled | cancel-requested |
        # died | running | unknown. The subset FUSED `cancelled` with `died` —
        # measured, a job cancelled by its owner and a job that died unattended
        # produced BYTE-IDENTICAL rows, and those have OPPOSITE operator
        # responses (nothing to do, versus investigate, work may be lost). A
        # second hand-written status list is how that recurs, so there is now
        # one definition and this asks it.
        #
        # `cancel-requested` is the member a naive fix drops: `_verdict` returns
        # it when the marker exists AND THE PID IS STILL ALIVE, so a
        # "marker => settled" rule would mark a LIVE job resolved and retire a
        # working window — strictly worse than the bug it fixes. It counts as
        # RUNNING here.
        #
        # COST: this REPLACES the proc-exists-authorized shell-out, it does not
        # add one — `_verdict` reads /proc itself, with the same (pid, pidstart)
        # identity discipline. The `-s status` gate above still bounds the
        # invocation count to the minority no-status case.
        #
        # DOUBT FAILS CLOSED: an unreadable authority, an empty answer, a
        # timeout and any unrecognised verdict all land in `n_died`, exactly as
        # the else-arm they replace did.
        local _v="" _cls="unknown"
        if [[ -r "$_ar" ]]; then
            _v=$(NEXUS_ASYNC_RUN_WINDOW="$window" NEXUS_STATE_DIR="${STATE_DIR:-$(_ip_nostate_dir)}" \
                 timeout 5 bash "$_ar" --status-line "$tok" 2>/dev/null) || _v=""
            [[ -n "$_v" ]] && _cls="${_v%%|*}"
        fi
        case "$_cls" in
            terminal)         n_term=$(( n_term + 1 ))
                              _bl=$(_idle_orphan_blank_flags "${root}/${tok}")
                              [[ "$_bl" == b* ]] && n_blank=$(( n_blank + 1 ))
                              [[ "$_bl" == bx ]] && n_redir=$(( n_redir + 1 )) ;;
            cancelled)        n_canc=$(( n_canc + 1 )) ;;
            running)          n_run=$((  n_run  + 1 )) ;;
            cancel-requested) n_run=$((  n_run  + 1 )) ;;   # marker set, STILL ALIVE
            died)             n_died=$(( n_died + 1 )) ;;
            *)                n_died=$(( n_died + 1 )) ;;   # unknown/unreadable -> fail CLOSED
        esac
        # your-org/nexus-code#1183. A wait whose RECORDED ARGV is a
        # `skeptic-channel.sh await` IS its own resume mechanism — the loop
        # wakes on the channel. Telling the operator to install a second
        # listener is the one action that must not be taken: a stacked await
        # SIGTERMs the older one (#1178), and the losing direction leaves the
        # window with NONE armed while believing it is parked.
        #
        # Keyed on `argv`, which async-run.sh writes from the REAL command —
        # NOT on `desc`, which is freeform prose. Making a freeform label
        # SELECT is the #1050 hazard.
        #
        # `running` ONLY, deliberately: a cancel-requested await is being torn
        # down, not armed, and must keep the ordinary running advice.
        #
        # NO PIPELINE HERE, and that is not style. `tr … | grep -q` is an
        # EARLY-EXIT READER: `grep -q` closes the pipe on its first match, `tr`
        # takes SIGPIPE (141), and under `pipefail` the pipeline status becomes
        # 141 — so the `if` would read FALSE on the very argv it just matched,
        # and this arm would silently never fire. Caught by
        # `test-sigpipe-assertion-lint.sh` on this exact line; it is a RATCHET,
        # not a repro, because whether `tr` finishes before `grep` exits depends
        # on the argv size. A bash substring test needs no second process.
        local _argv_txt=""
        if [[ "$_cls" == running && -r "${root}/${tok}/argv" ]]; then
            _argv_txt=$(tr '\0' ' ' < "${root}/${tok}/argv" 2>/dev/null) || _argv_txt=""
        fi
        # THE PROPERTY, NOT A SUBSTRING (your-org/nexus-code#1121). A substring
        # test is where "no input matches both" quietly becomes false: ANY
        # async-run job whose argv merely CONTAINS this literal — a prompt, a
        # grep, an echo — would be told it is "correctly ARMED … Do nothing",
        # suppressing the poller advice for real work. `argv` is NUL-separated,
        # so the property is available exactly. The first version demanded
        # argv[0] BE the script and missed the prescribed `bash -c '<list>'`
        # and `bash <path>/skeptic-channel.sh await` forms (#1183 reopen —
        # 7 of 27 live awaits); `_idle_argv_skeptic_await_task` recognises a
        # COMMAND POSITION in any of those shapes and still refuses a list that
        # only mentions the script in an argument.
        #
        # AND THE CHANNEL MUST AGREE. The recorded argv says what was LAUNCHED;
        # `_idle_skeptic_await_armed` asks the channel's own `.await-owner`
        # (a live pid whose cmdline is this await) and `.await-heartbeat`
        # (within the hang threshold) whether it is still ARMED. A stale await
        # is an orphan and keeps the running treatment — fail closed, as the
        # issue asks.
        if [[ "$_cls" == running && -r "${root}/${tok}/argv" ]]; then
            local _await_task=""
            if _await_task=$(_idle_argv_skeptic_await_task "${root}/${tok}/argv") \
               && _idle_skeptic_await_armed "$_await_task"; then
                n_await=$(( n_await + 1 ))
            fi
        fi
    done < <(printf '%s\n' "$full" | tr ',' '\n')

    # ARM ORDER, stated because #1121 requires it. `running` is first among the
    # non-empty arms so any live wait wins outright. The new `cancelled` arm sits
    # AFTER `terminal` and is a CONJUNCTION (n_canc + n_term == n), so it is
    # reachable only when n_term != n, hence only when n_canc > 0. Deliberately
    # an ALL-arm: the fix for #1333 must not reintroduce #1311's existential
    # shape in the arm next door.
    #
    # `skeptic-await` sits ABOVE `running` and is SAFE under #1121 because it is
    # STRICTLY NARROWER than the arm it precedes — `n_await == n_run` accepts a
    # subset of what `n_run > 0` accepts — and it replaces a permissive advice
    # string with a more specific one. It shadows no DENY arm. `== n_run` and
    # not `> 0`: a window with a skeptic await AND a live compute job still
    # needs the poller advice (your-org/nexus-code#1183).
    local counts="t=${n_term} r=${n_run} d=${n_died} u=${n_untr} c=${n_canc} n=${n} b=${n_blank} x=${n_redir}"
    if   (( n == 0 ));                    then printf 'unresolved|-'
    elif (( n_run > 0 && n_await == n_run )); then printf 'skeptic-await|%s' "$counts"
    elif (( n_run > 0 ));                 then printf 'running|%s'    "$counts"
    elif (( n_term == n ));               then printf 'terminal|%s'   "$counts"
    elif (( n_canc + n_term == n ));      then printf 'cancelled|%s'  "$counts"
    elif (( n_died == 0 && n_untr > 0 )); then printf 'untracked|%s'  "$counts"
    else                                       printf 'unresolved|%s' "$counts"
    fi
}

list_really_idle_workers() {
    local threshold="${MONITOR_IDLE_THRESHOLD_SECONDS:-60}"
    local close_hours="${MONITOR_IDLE_CLOSE_HOURS:-24}"
    local retain_ttl="${MONITOR_RETAIN_TTL_SECONDS:-86400}"
    # Spawn grace: newly-spawned windows skip idle-pool classification
    # for their first N seconds. The spawn-time engagement-log stamp
    # already prevents the worst brand-new-window false-positives, but
    # in the window between `tmux new-window` and the launcher running
    # `claude` the pane briefly hosts the launcher shell — pane-state
    # could legitimately classify that as `idle` and surface a
    # "no-wrap-up 60s" emit before the worker has even started.
    # Issue #72 regression 3 sub-case. Anchor: most-recent spawn event
    # ts for the window; gate measures `now - spawn_epoch`.
    local spawn_grace="${MONITOR_IDLE_POOL_SPAWN_GRACE_SECONDS:-120}"
    # Resolve close-hours and retain-ttl from config when the env
    # knob isn't set explicitly. The watcher's launcher already
    # exports MONITOR_IDLE_CLOSE_HOURS where it's wired; this
    # fallback makes the helper usable in tests that source it
    # directly.
    if [[ -z "${MONITOR_IDLE_CLOSE_HOURS:-}" ]]; then
        local cfg_close
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
            cfg_close=$("$NEXUS_ROOT/config/load.sh" monitor.idle_close_hours 24 2>/dev/null || echo 24)
            [[ "$cfg_close" =~ ^[0-9]+$ ]] && close_hours="$cfg_close"
        fi
    fi
    if [[ -z "${MONITOR_RETAIN_TTL_SECONDS:-}" ]]; then
        local cfg_ttl
        if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
            cfg_ttl=$("$NEXUS_ROOT/config/load.sh" monitor.retain_ttl_seconds 86400 2>/dev/null || echo 86400)
            [[ "$cfg_ttl" =~ ^[0-9]+$ ]] && retain_ttl="$cfg_ttl"
        fi
    fi
    local close_threshold=$(( close_hours * 3600 ))
    # Operator-engagement grace (issue #196), resolved once per sweep.
    local engaged_grace
    engaged_grace=$(_openg_grace_seconds)
    local now
    now=$(date +%s)
    # Live tmux window names, captured once per sweep for the skeptic
    # fidelity check (emit/exemption fidelity): the exemption is conferred
    # only when an actual skeptic window is alive, not merely when the
    # skeptic-pending marker exists.
    local live_windows
    live_windows=$(tmux list-windows -F '#{window_name}' 2>/dev/null || true)

    # Disappearance prune (issue #61). Enumerate this cycle's worker
    # windows once, compare against the previous cycle's persisted
    # set, drop engagement-log rows for any window present last
    # cycle but gone now. A resumed window-name then takes PR #46's
    # backfill path (no row → stamp NOW) instead of inheriting the
    # prior life's epoch and tripping the idle-pool gate immediately.
    local worker_windows current_set prev_windows_file prev_set
    worker_windows=$(_idle_list_worker_windows)
    current_set=$(printf '%s\n' "$worker_windows" \
                  | awk -F'\t' 'NF>0 && $1 != "" { print $1 }' \
                  | sort -u)
    prev_windows_file=$(_idle_previous_windows_path)
    prev_set=""
    [[ -f "$prev_windows_file" ]] && prev_set=$(sort -u "$prev_windows_file")
    if [[ -n "$prev_set" ]]; then
        local stale
        while IFS= read -r stale; do
            [[ -n "$stale" ]] || continue
            _engagement_log_drop "$stale"
            _openg_drop "$stale"
            _machine_input_prune "$stale"
            _paste_verdict_drop "$stale"
            _user_prompt_stamp_drop "$stale"
            _openg_change_drop "$stale"
            _machine_submit_stamp_drop "$stale"
            _bg_progress_drop "$stale"
            _idle_class_stamp_drop "$stale"
            _bg_backoff_drop "$stale"
            _worker_health_drop "$stale"
        done < <(comm -23 \
                    <(printf '%s\n' "$prev_set") \
                    <(printf '%s\n' "$current_set"))
    fi

    local name activity_epoch window_index age pane_state pane_line pane_reset_at
    while IFS=$'\t' read -r name activity_epoch window_index; do
        [[ -n "$name" && "$activity_epoch" =~ ^[0-9]+$ ]] || continue

        # Backfill: every observed window gets an engagement-log
        # row at first sight. PR #33 anchored idle-age to the
        # engagement-log epoch but fell back to `now -
        # window_activity` for windows with no row — which
        # re-introduced the autosuggest-bump flap (issue #44) for
        # workers that had been continuously idle since before
        # this watcher's process lifetime began (PR #23 era).
        # Stamping at first observation gives every window a
        # stable, monotone age anchor; the explicit trade-off is a
        # 60s post-restart grace before a previously-idle worker
        # enters the idle pool. Once stamped, the engagement-log
        # is only refreshed by genuine engagement (busy /
        # user-typing below), so the age column grows monotonically
        # and the suppressed-set footer stays stable across the
        # autosuggest re-renders / cursor blinks / status-bar ticks
        # that bump tmux's #{window_activity}.
        local existing_engagement
        existing_engagement=$(_engagement_log_lookup "$name")
        if [[ -z "$existing_engagement" ]]; then
            _engagement_log_stamp "$name" "$now"
        fi

        # pane-state.sh takes a window index. Fall back to name for
        # test stubs that don't enumerate indexes. Capture the full
        # emit line so we can pull reset_at on the over-limit branch
        # and orphan_kinds on the idle-orphan-async branch without
        # spawning a second subprocess.
        local probe_target="${window_index:-$name}"
        local pane_orphan_kinds="" pane_content_hash="" pane_bg_cpu=""
        pane_line=$(_idle_pane_state_line "$probe_target" "$name")
        if [[ -z "$pane_line" ]]; then
            pane_state=unknown
            pane_reset_at=""
        else
            pane_state=$(printf '%s' "$pane_line" \
                | sed -n 's/.*state=\([a-z-]*\).*/\1/p')
            [[ -n "$pane_state" ]] || pane_state=unknown
            pane_reset_at=$(_idle_pane_line_field "$pane_line" reset_at)
            pane_orphan_kinds=$(_idle_pane_line_field "$pane_line" orphan_kinds)
            pane_content_hash=$(_idle_pane_line_field "$pane_line" content_hash)
            pane_bg_cpu=$(_idle_pane_line_field "$pane_line" bg_cpu)
        fi

        # Background-compute orphan-grace (your-org/nexus-code#445).
        # A SHELL-driven `working-background` carries `bg_cpu=<jiffies>`.
        # Stamp its progress EVERY cycle (before the engagement stamp and
        # age gate, both of which the exemption otherwise short-circuits)
        # and decide whether the shell is genuinely computing or has gone
        # stalled/orphaned. bg_stalled=1 only when we have a real CPU
        # reading that has FROZEN past the grace — absent/blank bg_cpu (a
        # Monitor-handle working-background, or any non-shell state) never
        # stalls, preserving the existing exemption. A live compute worker
        # (any CPU delta) resets the clock and is never flagged.
        local bg_stalled=0 bg_progress_epoch=0
        if [[ "$pane_state" == "working-background" && "$pane_bg_cpu" =~ ^[0-9]+$ ]]; then
            local bg_grace
            bg_progress_epoch=$(_bg_progress_check "$name" "$pane_bg_cpu" "$now")
            bg_grace=$(_bg_orphan_grace_seconds)
            if [[ "$bg_progress_epoch" =~ ^[0-9]+$ ]] \
               && (( now - bg_progress_epoch > bg_grace )); then
                bg_stalled=1
            fi
        fi

        # Idle-with-children long timeout + inconsistency detection
        # (your-org/nexus-code#455 refine). Engage ONLY when the process
        # tree reading was AUTHORITATIVE (bg_reliable=1) and it saw ≥1 live
        # background-shell child; the footer-fallback path (bg_reliable=0)
        # keeps the legacy #445 flat-grace behaviour via bg_stalled above.
        #
        #   has_live_children=1 → this idle worker still has a child process.
        #   bg_wrapped=1        → it has ALSO wrapped up (case b: inconsistency).
        #   bg_surface=1        → we WILL surface a row (case b always; case a
        #                         once its child's CPU has frozen ≥ base). A
        #                         CPU-advancing / recently-active child stays
        #                         silently exempt (today's behaviour preserved),
        #                         so bg_surface stays 0 and the engagement stamp
        #                         below fires as before.
        local pane_bg_shells pane_bg_reliable
        pane_bg_shells=$(_idle_pane_line_field "$pane_line" bg_shells)
        pane_bg_reliable=$(_idle_pane_line_field "$pane_line" bg_reliable)
        [[ "$pane_bg_shells" =~ ^[0-9]+$ ]] || pane_bg_shells=0
        [[ "$pane_bg_reliable" =~ ^[0-9]+$ ]] || pane_bg_reliable=0
        local pane_bg_infra=0 pane_bg_cmd="-" pane_bg_task_shells=0
        local has_live_children=0 bg_wrapped=0 bg_surface=0
        local bg_child_class="" bg_child_detail=""
        if [[ "$pane_state" == "working-background" ]] \
           && (( pane_bg_reliable == 1 )) && (( pane_bg_shells >= 1 )); then
            has_live_children=1
            # #590: `bg_infra` counts the roots that are nexus PROTOCOL WAIT
            # loops (skeptic/request `await`), `bg_cmd` names one representative
            # child, and `pane_bg_task_shells` is what remains once the protocol
            # waits are set aside — the children an operator actually has to
            # decide about. Absent fields (an older pane-state.sh, a fixture)
            # leave infra at 0, so task_shells == bg_shells and pre-#590
            # behaviour is preserved exactly.
            #
            # Read HERE, not with bg_shells/bg_reliable above: each field costs a
            # `sed` subshell per window per cycle, and only this branch can use
            # them. Reading them unconditionally added ~50% to the idle probe's
            # per-cycle cost for every window in the session — measured, after it
            # pushed a wall-clock-sensitive fixture in test-idle-probe.sh over its
            # 60s grace.
            pane_bg_infra=$(_idle_pane_line_field "$pane_line" bg_infra)
            pane_bg_cmd=$(_idle_pane_line_field "$pane_line" bg_cmd)
            [[ "$pane_bg_infra" =~ ^[0-9]+$ ]] || pane_bg_infra=0
            [[ -n "$pane_bg_cmd" ]] || pane_bg_cmd="-"
            pane_bg_task_shells=$(( pane_bg_shells - pane_bg_infra ))
            (( pane_bg_task_shells >= 0 )) || pane_bg_task_shells=0
            # Episode age, DERIVED from the process tree (no state file).
            # A missing/zero `bg_oldest_start` means "unknown" — treat the
            # episode as brand new rather than instantly past the ceiling.
            local bg_oldest_start bg_child_age bg_ceiling
            bg_oldest_start=$(_idle_pane_line_field "$pane_line" bg_oldest_start)
            [[ "$bg_oldest_start" =~ ^[0-9]+$ ]] || bg_oldest_start=0
            bg_child_age=0
            if (( bg_oldest_start > 0 )) && (( now > bg_oldest_start )); then
                bg_child_age=$(( now - bg_oldest_start ))
            fi
            bg_ceiling=$(_bg_children_grace_ceiling_seconds)
            if _bg_window_is_wrapped "$name"; then
                # A wrapped worker with live children is NOT automatically an
                # inconsistency — a skeptic-gated worker reaches exactly this
                # shape by design. `ng wrap-up` is what WRITES the skeptic-
                # pending marker, and the worker then holds its
                # `skeptic-channel await` re-check loop in a background shell.
                # So consult the authoritative park signal FIRST, mirroring the
                # ordering render_full_state_snapshot already uses.
                if _idle_skeptic_parked "$name" "$now" "$live_windows"; then
                    # Expected, named state — the PR #285 exemption.
                    bg_surface=1
                    bg_child_class="parked-awaiting-skeptic"
                    if [[ "${_IDLE_SKEPTIC_PARK_BASIS:-}" == "skeptic-live" ]]; then
                        bg_child_detail="live skeptic window, worker await marker STALE — exempt on the skeptic, not on an active await loop (${pane_bg_shells} child(ren))"
                    elif [[ "${_IDLE_SKEPTIC_PARK_BASIS:-}" == "channel" ]]; then
                        bg_child_detail="skeptic reviewing — no linkage record, but the comms channel holds this round's traffic (spawned without --skeptic-role; #1153); exempt from idle/close (${pane_bg_shells} await child(ren))"
                    else
                        bg_child_detail="skeptic reviewing; exempt from idle/close (${pane_bg_shells} await child(ren))"
                    fi
                elif _idle_skeptic_orphaned "$name" "$now" "$live_windows"; then
                    # Fresh marker, no live skeptic past grace — a stuck park,
                    # actionable in its own right rather than mislabelled.
                    bg_surface=1
                    bg_child_class="orphaned-skeptic-pending"
                    bg_child_detail="skeptic-pending marker but no live skeptic past grace — run \`ng skeptic-evidence $name\` FIRST: a DELIVERED verdict the record cannot match looks identical to an absent one (your-org/nexus-code#1156), and clearing the marker also voids a LIVE obligation (#961, #1153)"
                elif (( pane_bg_task_shells <= 0 )) && (( pane_bg_infra >= 1 )) \
                     && (( bg_child_age < bg_ceiling )); then
                    # Case (b0): wrapped, marker already cleared, and EVERY live
                    # child is a nexus PROTOCOL WAIT loop rather than task work
                    # (your-org/nexus-code#590). This is the routine shape, not
                    # an inconsistency: `ng wrap-up` is what tells a
                    # skeptic-gated worker to hold a `skeptic-channel await`
                    # re-check loop in a background shell, and a RETURNED
                    # verdict clears the pending marker while that prescribed
                    # child keeps polling until its own await timeout. So the
                    # `parked-awaiting-skeptic` exemption lapses with the
                    # prescribed child still alive, and the window used to
                    # resurface as `wrapped-with-children` — every skeptic-gated
                    # worker, every time. Firing routinely TRAINS the operator
                    # to dismiss it, and then a genuine orphaned `sbatch`/`nohup`
                    # arrives looking like the twenty false ones before it.
                    # Do NOT surface: fall through to normal wrapped handling,
                    # which correctly treats the window as retire-eligible (the
                    # await loop dies with the window). A NON-protocol child in
                    # the same set still surfaces below, now NAMED.
                    #
                    # BOUNDED, never a permanent mute. The exemption holds only
                    # while the episode is younger than the ABSOLUTE ceiling
                    # (`bg_child_age < bg_ceiling`, the same #455-follow-up
                    # bound case (a) uses). A single `await` is self-limiting —
                    # it returns at its own timeout — but a worker that wraps it
                    # in an `until` loop would otherwise hold the window exempt
                    # forever, silently. Past the ceiling the window falls
                    # through to case (b) below and surfaces WITH the loop named,
                    # so "no child may buy silence indefinitely" still holds.
                    bg_surface=0
                else
                    # Case (b): wrapped, no skeptic pending, and at least one
                    # live child that is NOT a protocol wait loop. Surface
                    # always, regardless of CPU (a wrapped worker whose child is
                    # still computing is the strongest form of the
                    # inconsistency). A STALE marker fails both checks above and
                    # lands here, so a died-mid-await worker still surfaces
                    # rather than staying muted forever.
                    bg_wrapped=1; bg_surface=1
                    bg_child_class="wrapped-with-children"
                    # Report the count of children that need a DECISION (the
                    # non-protocol ones), falling back to the raw count for the
                    # past-the-ceiling protocol-only case reached from (b0) —
                    # where task_shells is 0 but there IS something to report.
                    local bg_report_count="$pane_bg_task_shells"
                    (( bg_report_count > 0 )) || bg_report_count="$pane_bg_shells"
                    bg_child_detail=$(_bg_wrapped_children_detail "$name" \
                        "$bg_report_count" "$pane_bg_cmd")
                fi
            else
                # Case (a): idle worker waiting on a background job. Surface
                # once its child's CPU has frozen for ≥ base seconds (a
                # blocking wait on a Slurm job shows no CPU delta) — OR once
                # the child set has simply existed past the ABSOLUTE ceiling,
                # which a CPU-advancing child cannot reset. The latter is the
                # bound that stops a quiet polling loop from holding the window
                # exempt forever (inverted priority, #455 follow-up).
                local bg_stall_start bg_stall_age bg_base
                bg_stall_start="$bg_progress_epoch"
                [[ "$bg_stall_start" =~ ^[0-9]+$ ]] && (( bg_stall_start > 0 )) || bg_stall_start="$now"
                bg_stall_age=$(( now - bg_stall_start ))
                bg_base=$(_bg_children_grace_base_seconds)
                if (( bg_stall_age >= bg_base )) || (( bg_child_age >= bg_ceiling )); then
                    bg_surface=1
                    local bg_decision
                    bg_decision=$(_bg_children_decide "$name" "$now" "$bg_stall_start" "$pane_bg_shells" "$bg_oldest_start")
                    bg_child_class="${bg_decision%%$'\t'*}"
                    bg_child_detail="${bg_decision#*$'\t'}"
                fi
            fi
        fi

        # Engagement-log stamp comes BEFORE the age gate. A worker
        # that's busy *right now* may have an activity-age below
        # threshold yet still represent real engagement that should
        # consume any standing retain on the next cycle.
        #
        # `working-background` and `working-self-paced` (issue #183)
        # also count as engagement — the worker has an in-flight
        # async tool handle or a scheduled wakeup, which is real
        # ongoing work even though the renderer shows no busy
        # spinner. Stamping engagement here keeps a retained worker
        # from being closed mid-monitor.
        # A STALLED background shell (your-org/nexus-code#445) is NOT
        # engagement — stamping it would reset the idle-age anchor and
        # keep the window below the idle threshold forever, defeating
        # the orphan cap. Withhold the stamp so its age grows and it
        # reaches classification.
        case "$pane_state" in
            busy|user-typing|working-self-paced)
                _engagement_log_stamp "$name" "$now" ;;
            working-background)
                if (( has_live_children == 1 )); then
                    # Withhold the stamp only when we're about to surface a
                    # row (case b, or a frozen case-a child): its age must
                    # grow to cross the idle threshold and reach the
                    # classification below. Otherwise stamp as engagement
                    # (advancing / within-base child → silent exempt).
                    (( bg_surface == 1 )) || _engagement_log_stamp "$name" "$now"
                else
                    (( bg_stalled == 1 )) || _engagement_log_stamp "$name" "$now"
                fi ;;
        esac

        # Operator-engaged bookkeeping (issues #196, #201). Runs on
        # EVERY observed state — before the over-limit short-circuit,
        # the spawn grace, and the age gate — because the seed is
        # hook-driven (the UserPromptSubmit stamp) and must be
        # processed regardless of how (or whether) pane-state
        # classified the window this cycle; the soft refresh also
        # rides on states (busy, user-typing) that exit this loop
        # early below.
        _openg_observe "$name" "$pane_state" "$pane_content_hash" "$now" "$engaged_grace"

        # Over-limit short-circuit (issue #87). Bypasses the spawn
        # grace AND the age gate — a worker hitting the weekly limit
        # was likely busy moments ago, so its engagement-anchored
        # age sits at zero. Surfacing the suspension immediately is
        # the whole point of the state. Inviolable like
        # `pane-absent`; `window-retain` does not suppress it.
        if [[ "$pane_state" == over-limit ]]; then
            printf '%s\t%s\t%s\t%s\n' \
                "$name" "over-limit" "$(( now - activity_epoch ))" \
                "${pane_reset_at:-unknown}"
            continue
        fi

        # Spawn-grace skip. If this window has a recent `spawn` event
        # and we're still within the grace window, drop out — the
        # worker is still booting and any classification at this stage
        # is likely premature (issue #72). Pre-existing windows that
        # never had a spawn event recorded (legacy / observed at
        # watcher startup) pass through; the engagement-log first-sight
        # backfill below covers their idle-anchor.
        if (( spawn_grace > 0 )); then
            local spawn_ts_for_grace spawn_epoch_for_grace spawn_age
            spawn_ts_for_grace=$(_idle_window_spawn_ts "$name")
            if [[ -n "$spawn_ts_for_grace" ]]; then
                spawn_epoch_for_grace=$(_idle_iso_to_epoch "$spawn_ts_for_grace")
                if [[ "$spawn_epoch_for_grace" =~ ^[0-9]+$ ]]; then
                    spawn_age=$(( now - spawn_epoch_for_grace ))
                    if (( spawn_age < spawn_grace )); then
                        continue
                    fi
                fi
            fi
        fi

        # Idle-pool entry gate. Anchor: the engagement-log epoch,
        # always — the backfill above guarantees every observed
        # window has a row. Not `max(engagement, activity)` —
        # activity > engagement is the common case (any cursor
        # blink post-engagement bumps it), and picking the larger
        # would defeat the fix. The engagement-log records only
        # `busy` / `user-typing` observations plus a first-sight
        # baseline, so its epoch is the reliable floor for "when
        # did the current idle stretch begin"; tmux's
        # `#{window_activity}` includes autosuggest re-renders,
        # cursor blinks, and status-bar ticks, so a retained
        # worker rendering its spinner glyph every minute would
        # oscillate in and out of the idle pool under
        # window_activity-only gating, thrashing the suppressed-
        # set footer. The activity_epoch is kept as a defensive
        # fallback for the unlikely case where the engagement-log
        # row is somehow malformed; the backfill guarantees the
        # primary path.
        local age_anchor="$activity_epoch"
        local engagement_epoch_for_age
        engagement_epoch_for_age=$(_engagement_log_lookup "$name")
        if [[ -n "$engagement_epoch_for_age" \
              && "$engagement_epoch_for_age" =~ ^[0-9]+$ ]]; then
            age_anchor="$engagement_epoch_for_age"
        fi
        age=$(( now - age_anchor ))
        (( age >= threshold )) || continue

        local cls detail=""
        case "$pane_state" in
            absent|blocked)
                # `pane-absent` short-circuits the wrap-up
                # classification entirely — the inner Claude
                # process is gone or unresponsive; whether a
                # report exists is moot until it's relaunched.
                # Post-rethink: `empty` is no longer mapped here.
                # pane-state.sh distinguishes `empty` (alive
                # claude, transient render state) from `absent`
                # (no live claude in pane), so only `absent` and
                # `blocked` warrant the inviolable pane-absent
                # surface.
                #
                # ONE CLASS, TWO STATES — SO TWO ADVISORIES
                # (your-org/nexus-code#808). Both states need the
                # operator, which is why they share the inviolable
                # surface; but they need OPPOSITE actions, and the
                # detail used to describe only the `absent` half:
                #
                #   absent   "process gone"  true    "relaunch or close"  right
                #   blocked  "process gone"  FALSE   "relaunch or close"  HARMFUL
                #
                # A `blocked` pane is ALIVE and rendering a modal it is
                # waiting for a human to answer. Observed in production
                # 2026-08-07 22:49 against window `idflake`, which was
                # displaying an AskUserQuestion: the operator probed it
                # five times (`state=blocked active=0 overlay=askuq`,
                # `pane_pid` unchanged throughout) and was told the
                # process was gone and to relaunch it. Relaunching would
                # have destroyed a live agent's context and discarded
                # the question it was asking.
                #
                # The kill gate held — `bk_pane_kill_authorized` refuses
                # `blocked`, and retire-preflight.sh carries an explicit
                # do-not-kill arm for it — so this is a TRUST defect,
                # not a safety one, and it is stated at that severity.
                # The expensive outcome is not the operator acting on it
                # (they get refused); it is the operator learning to
                # discount `pane-absent`, a surface documented as
                # inviolable and never suppressed.
                cls=pane-absent
                if [[ "$pane_state" == blocked ]]; then
                    detail="overlay awaiting the operator (blocked) — ANSWER it in the pane; do NOT relaunch or close"
                else
                    detail="claude process gone or unresponsive; relaunch or close"
                fi
                # #677 — the audit trail. Placed at the render CHOKEPOINT rather than
        # in each `cls=` arm: every classification passes through here exactly
        # once, so no arm can be added later that silently escapes the log.
        _idle_record_classification "$name" "$cls" "$detail" || true

        printf '%s\t%s\t%s\t%s\n' "$name" "$cls" "$age" "$detail"
                continue
                ;;
            idle|autosuggest-only)
                : ;;
            idle-orphan-async)
                # Issue #183: worker declared async external work
                # (slurm, CI, queued task, …) but installed no
                # resume mechanism. Surface as a contract-violation
                # row with the offending job ids. Inviolable like
                # `pane-absent` and `idle-too-long` — `window-retain`
                # does NOT suppress it; the operator needs to see
                # the contract break, not its absence. Detail
                # column carries the `kind:id,…` summary so
                # render_idle_section can interpolate it into the
                # advisory line.
                cls=idle-orphan-async
                detail="${pane_orphan_kinds:-unknown}"
                # Still FOUR columns. `<class>|<kinds>` is read by the render
                # arm alone; no other consumer of this stream looks at $4, and
                # `idle-state.tsv` persists only $1 and $2, so nothing
                # downstream can observe the prefix.
                # `<class>|<counts>|<kinds>` — the classifier emits the first
                # two joined, so this stays one substitution.
                detail="$(_idle_orphan_wait_class "$name" "$detail")|$detail"
                printf '%s\t%s\t%s\t%s\n' "$name" "$cls" "$age" "$detail"
                continue
                ;;
            empty)
                # Renderer in a transient state but claude is
                # alive. Normally skip — re-classify on a future
                # cycle when the renderer has settled. Engagement-log
                # was not stamped above (empty is not engagement)
                # so the worker re-enters the idle pool naturally
                # when classification stabilises.
                #
                # EXCEPTION: a fresh turn-failure marker means the
                # empty box IS the stall — the motivating incident
                # showed `pane-state state=empty active=0` right
                # after the 500 killed the turn. Fall through to the
                # interrupted detection below so a crashed worker
                # surfaces promptly instead of being skipped every
                # cycle. Without a marker, keep the skip.
                if ! _idle_turn_failure_fresh "$name" "$now"; then
                    continue
                fi
                ;;
            working-background)
                # Idle-with-children long timeout + inconsistency detection
                # (your-org/nexus-code#455 refine). When the authoritative
                # process tree saw a live child and we resolved a row to
                # surface (case b: wrapped-with-children; or case a: a
                # frozen child past base → the backoff decision — one of
                # idle-awaiting-job / idle-children-clarify / idle-too-long),
                # emit it directly and skip the wrap-up classification below.
                # This mirrors the idle-orphan-async short-circuit: a
                # working-state row is emitted in place rather than deferred
                # to the interrupted/skeptic/no-wrap-up cascade.
                #
                # Because this short-circuits BEFORE the parked-awaiting-
                # skeptic check further down, `bg_child_class` is resolved
                # skeptic-aware at its assignment site above — a worker parked
                # in `skeptic-channel await` DOES reach here (the await loop is
                # a real background child), so it must already carry the
                # `parked-awaiting-skeptic` class rather than be mislabelled a
                # wrapped-with-children inconsistency (#455 follow-up).
                if (( has_live_children == 1 )) && (( bg_surface == 1 )); then
                    printf '%s\t%s\t%s\t%s\n' \
                        "$name" "$bg_child_class" "$age" "$bg_child_detail"
                    continue
                fi
                # Background-compute orphan-grace (your-org/nexus-code#445).
                # A shell whose CPU is still advancing is genuinely
                # computing → exempt (engagement stamped above kept its
                # age below threshold, so it normally never even reaches
                # here; the explicit continue is the belt-and-suspenders
                # guard). A shell whose CPU has FROZEN past the grace is
                # orphaned — its engagement stamp was withheld above so
                # its age crossed the threshold; fall through to normal
                # idle classification so it becomes reapable.
                (( bg_stalled == 1 )) || continue
                ;;
            *)
                # busy / user-typing / working-self-paced / unknown —
                # not idle enough to surface. Engagement-log was already
                # stamped above (for busy / user-typing /
                # working-self-paced); `unknown` just means pane-state
                # couldn't run, treat as skip.
                continue
                ;;
        esac

        # Interrupted-mid-turn detection (the stall-detection work).
        # A fresh turn-failure marker means the worker's last turn
        # died to an API/model error (StopFailure fired, NOT Stop) —
        # the inner claude process is alive (the `absent` short-
        # circuit above guarantees it), the input box is empty, and
        # no clean Stop ran. This is byte-identical to a forgot-to-
        # wrap worker from the renderer alone, but the correct
        # recovery is resume/respawn, not a wrap-up nag. Surface it as
        # `interrupted` carrying `<category>:<recovery>` so the
        # orchestrator pastes-to-resume (transient) or respawns
        # (config/conversation) correctly.
        #
        # Precedence: above operator-engaged, no-wrap-up, and retain —
        # a crashed turn is actionable and must not be muted by a
        # standing retain or an away-operator mark. BELOW idle-too-long
        # (an abandoned crash that's sat ≥ close_threshold is a close
        # candidate, not a resume candidate), which the inline override
        # preserves. Inviolable w.r.t. window-retain.
        #
        # ALSO above parked-awaiting-skeptic (the PR #285 short-circuit
        # below): a fresh turn-failure marker means the worker's await
        # loop died mid-handshake, so the skeptic-pending marker — though
        # it may still be momentarily fresh — no longer reflects a live
        # park. An interrupted skeptic-parked worker is recoverable, not
        # parked, so the crash must surface for paste/respawn rather than
        # be masked by the park exemption. In the normal clean-park case
        # there is no turn-failure marker, so this check skips and the
        # park short-circuit below fires unchanged — no regression.
        if _idle_turn_failure_fresh "$name" "$now"; then
            local tf_category tf_recovery
            tf_category=$(_idle_turn_failure_field "$name" category)
            tf_recovery=$(_idle_turn_failure_field "$name" recovery)
            cls=interrupted
            detail="${tf_category:-unknown}:${tf_recovery:-paste}"
            if (( age >= close_threshold )); then
                cls=idle-too-long
            fi
            printf '%s\t%s\t%s\t%s\n' "$name" "$cls" "$age" "$detail"
            continue
        fi

        # parked-awaiting-skeptic short-circuit (skills/nexus.skeptic,
        # PR #285). A worker with a LIVE skeptic-pending marker (mtime
        # refreshed by its `skeptic-channel await` loop within the hang
        # threshold) is legitimately parked, not idle. Emit the
        # informational class and skip ALL wrap-up classification below —
        # this is the exemption from idle-too-long / no-wrap-up that
        # keeps the orchestrator from closing the worker mid-handshake.
        # Surfaces ONCE via list_idle_transitions' (window,class) dedupe,
        # so it informs without nagging. A stale marker (await died)
        # fails _idle_skeptic_parked and falls through to normal
        # classification, so a genuine hang still surfaces. Runs before
        # operator-engaged: the skeptic gate is the stronger claim while
        # it's live. Runs AFTER interrupted detection above: a crashed
        # await beats a (momentarily-fresh) park because it's recoverable.
        if _idle_skeptic_parked "$name" "$now" "$live_windows"; then
            local _park_detail="skeptic reviewing; exempt from idle/close"
            # #1039: when the exemption rests on the live skeptic WINDOW rather
            # than on a still-ticking await loop, say so in the row. The
            # exemption is equally valid; the operator-relevant difference is
            # that the worker is no longer polling for the verdict.
            [[ "${_IDLE_SKEPTIC_PARK_BASIS:-}" == "skeptic-live" ]] \
                && _park_detail="skeptic reviewing (live skeptic window); worker await marker STALE — exempt on the skeptic, not on an active await loop"
            [[ "${_IDLE_SKEPTIC_PARK_BASIS:-}" == "channel" ]] \
                && _park_detail="skeptic reviewing — no linkage record, but the comms channel holds this round's traffic (spawned without --skeptic-role; your-org/nexus-code#1153); exempt from idle/close"
            # your-org/nexus-code#845: the JOIN — which skeptic, idle how long.
            _park_detail+=$(_idle_skeptic_join_detail "$now" "$worker_windows")
            printf '%s\t%s\t%s\t%s\n' \
                "$name" "parked-awaiting-skeptic" "$age" "$_park_detail"
            continue
        fi

        # Orphaned skeptic-pending marker (emit/exemption fidelity). A fresh
        # marker with NO live skeptic past the grace window is NOT a park —
        # it is a stuck state the orchestrator must resolve. Surface it as
        # its own actionable class instead of silently exempting forever.
        # Deduped by (window,class) like the park class, so it informs once;
        # the periodic full-state snapshot re-shows it. Once the orchestrator
        # spawns the skeptic (→ live) or clears the marker, the class changes
        # and normal classification resumes.
        if _idle_skeptic_orphaned "$name" "$now" "$live_windows"; then
            printf '%s\t%s\t%s\t%s\n' \
                "$name" "orphaned-skeptic-pending" "$age" "skeptic-pending marker but no live skeptic past grace — run \`ng skeptic-evidence $name\` FIRST: a DELIVERED verdict the record cannot match looks identical to an absent one (your-org/nexus-code#1156), and clearing the marker also voids a LIVE obligation (#961, #1153)"
            continue
        fi

        # Operator-engaged short-circuit (issues #196, #201). An idle
        # window with a valid mark belongs to the operator — engaged
        # right now, or merely stepped away. Emit the informational
        # class instead of the wrap-up classification so the dedupe
        # machinery surfaces ONE row per engagement episode and
        # nothing nags; the away-phase reminder rides on top in
        # list_idle_transitions. Only a newer wrap-up/spawn (or the
        # window closing) re-opens the normal classes.
        if _openg_marked "$name"; then
            local openg_src
            openg_src=$(_openg_lookup "$name" | cut -f4)
            printf '%s\t%s\t%s\t%s\n' \
                "$name" "operator-engaged" "$age" "${openg_src:-engaged}"
            continue
        fi

        cls=no-wrap-up
        local report_basename
        if report_basename=$(_idle_window_wrap_up_report "$name"); then
            # Wrap-up supersession (the #205 state-machine follow-up):
            # a MACHINE-attributed submit NEWER than the wrap-up means
            # the orchestrator re-tasked the worker after its hand-off.
            # The wrap-up is stale — the window regressed to busy at
            # the follow-up and, now idle again without a fresh
            # wrap-up, belongs on the no-wrap-up nag schedule rather
            # than parked on a "wrapped" row. (An OPERATOR submit
            # after a wrap-up takes the operator-engaged short-circuit
            # above instead and never reaches this branch while the
            # mark is valid.)
            local wrap_epoch_cls msub_epoch
            wrap_epoch_cls=$(_openg_wrap_epoch "$name")
            msub_epoch=$(_openg_machine_submit_epoch "$name")
            if (( msub_epoch > 0 && wrap_epoch_cls > 0 \
                  && msub_epoch > wrap_epoch_cls )); then
                cls=no-wrap-up
            else
                cls=wrapped
                local report_path
                if report_path=$(_idle_resolve_report_path "$report_basename"); then
                    local check_summary
                    if ! check_summary=$(_idle_run_report_check "$report_path"); then
                        cls=wrapped-but-stub
                        detail="$check_summary"
                    fi
                fi
            fi
        fi

        # Piece 5: the hard 24h-class overrides everything else.
        # A worker that has been idle for ≥ close_threshold is a
        # default-to-close candidate regardless of whether the
        # cited report passes report-check. `idle-too-long` is
        # inviolable — never suppressed by `window-retain`.
        if (( age >= close_threshold )); then
            cls=idle-too-long
            # Preserve the prior detail (a stub finding) so the
            # orchestrator still has the report-check hint even on
            # the strong-close path.
            :
        fi

        # Injection ↔ hook pairing validation (the #205 state-machine
        # follow-up): an orchestrator paste that never fired the
        # worker's UserPromptSubmit hook means the nudge silently
        # failed — surface it instead of the wrapped/no-wrap-up row so
        # the orchestrator re-pastes. Below idle-too-long (a runaway
        # window must keep alarming) and above retain (a failed paste
        # is actionable; a standing retain must not mute it).
        if [[ "$cls" == "wrapped" || "$cls" == "no-wrap-up" ]]; then
            local unconfirmed_paste
            unconfirmed_paste=$(_idle_unconfirmed_paste_epoch "$name" "$now")
            if (( unconfirmed_paste > 0 )); then
                cls=paste-unconfirmed
                # The RAW key comes back (it names the sidecar that
                # _idle_paste_verdict_note reads); the rendered age needs
                # the seconds view (your-org/nexus-code#679).
                local _up_sec
                _up_sec=$(_paste_epoch_seconds "$unconfirmed_paste")
                detail="paste $(( now - _up_sec ))s ago"
                # Carry the sender's own verdict into the emit so the
                # operator sees WHICH surface is uncertain rather than a
                # flat assertion (your-org/nexus-code#665).
                local _pv_note
                _pv_note=$(_idle_paste_verdict_note "$name" "$unconfirmed_paste" "$now")
                [[ -n "$_pv_note" ]] && detail="$detail; $_pv_note"
                # What the CONTENT surface established, if anything
                # (your-org/nexus-code#665 item 1). Reads the globals the
                # call above published — adjacency is the contract.
                local _pm_note
                _pm_note=$(_idle_paste_marker_note "$name" "$unconfirmed_paste")
                [[ -n "$_pm_note" ]] && detail="$detail; $_pm_note"
            fi
        fi

        # `window-retain` suppression. Only `wrapped` and `no-wrap-up`
        # are eligible — `wrapped-but-stub`, `idle-too-long`, and
        # `pane-absent` are inviolable. The retain is consumed only
        # by *real engagement* (busy / user-typing recorded in
        # engagement-log.tsv since retain.ts), NOT by tmux
        # `#{window_activity}` bumps — autosuggest re-renders /
        # cursor blinks / status-bar ticks bump activity without
        # any human or agent input. Missing engagement-log row
        # means "no engagement since beginning of time" → retain
        # holds. Retain expires after retain_ttl seconds.
        if [[ "$cls" == "wrapped" || "$cls" == "no-wrap-up" ]]; then
            local retain_row retain_ts retain_reason retain_ts_epoch retain_age
            if retain_row=$(_idle_window_retain_event "$name"); then
                IFS=$'\t' read -r retain_ts retain_reason <<<"$retain_row"
                retain_ts_epoch=$(_idle_iso_to_epoch "$retain_ts")
                if [[ -n "$retain_ts_epoch" ]]; then
                    retain_age=$(( now - retain_ts_epoch ))
                    local engagement_epoch
                    engagement_epoch=$(_engagement_log_lookup "$name")
                    # Missing row = "never engaged" — sentinel 0
                    # always passes the `<= retain_ts_epoch` check.
                    [[ -z "$engagement_epoch" ]] && engagement_epoch=0
                    if (( retain_age >= 0 )) \
                       && (( retain_age <= retain_ttl )) \
                       && (( engagement_epoch <= retain_ts_epoch )); then
                        cls=retained
                        detail="$retain_reason"
                    fi
                fi
            fi
        fi

        printf '%s\t%s\t%s\t%s\n' "$name" "$cls" "$age" "$detail"
    done <<<"$worker_windows"

    # Persist `current ∪ engagement-log-keys-after-prune` for the
    # next cycle's disappearance check. The union makes the
    # cold-start-with-stale-row case prune in two cycles (see the
    # header on `_idle_previous_windows_path`); on the steady-state
    # path, the engagement-log half of the union is a no-op because
    # every key with a row is also a currently-alive window.
    local elog_keys persist_payload
    elog_keys=""
    if [[ -f "$(_engagement_log_path)" ]]; then
        elog_keys=$(awk -F'\t' 'NF>0 && $1 != "" { print $1 }' \
                        "$(_engagement_log_path)")
    fi
    persist_payload=$(printf '%s\n%s\n' "$current_set" "$elog_keys" \
                      | awk 'NF>0' | sort -u)
    mkdir -p "$(dirname "$prev_windows_file")"
    if [[ -n "$persist_payload" ]]; then
        printf '%s\n' "$persist_payload" > "$prev_windows_file"
    else
        : > "$prev_windows_file"
    fi
}

# Diff this cycle's idle set against the previous cycle's; emit only
# transitions worth surfacing (per the state machine in the header).
# Reads/writes $STATE_DIR/idle-state.tsv.
#
# Dedupe key is (window, class) — the detail column doesn't gate
# the diff (a wrapped-but-stub finding whose detail string changed
# between cycles is still "the same state" from the orchestrator's
# POV; re-emitting would be noise).
#
# Retained-row handling differs: the suppressed set is treated as
# a single dedupe unit. When the set changes (any window added or
# removed), ALL current retained rows are emitted so the renderer
# can produce a complete footer listing every currently-suppressed
# window. When the set is unchanged, no retained rows surface even
# if other (non-retained) transitions are emitted this cycle.
#
# Output: <window>\t<class>\t<age-seconds>\t<detail>  — only NEW
#         transitions and (conditionally) the current retained set.
# Carry-forward for episode-scoped dedupe rows. A window
# mid-conversation oscillates out of the idle pool on every busy /
# user-typing observation; if its `(window, class)` row left the
# state file each time, every think-gap would re-emit the row —
# recreating the per-round noise these classes exist to stop. Two
# classes are episode-scoped:
#
#   operator-engaged (issue #196) — carried while the engagement
#     mark is still valid.
#   parked-awaiting-skeptic (emit-gate-recover) — carried while the
#     skeptic-pending marker is still live. A worker parked in the
#     `skeptic-channel.sh await` loop flaps busy↔idle on every poll
#     of the loop; without the carry, each idle re-entry re-emitted
#     the parked row (the 2026-07-06 per-minute resurface flood).
#     "Surfaces ONCE per park episode" is the intended contract.
#
# A carried row drains naturally — when the mark/marker is
# invalidated (newer wrap-up/spawn; skeptic verdict retiring the
# park) the window re-enters the pool under its normal class (a
# class change, which emits), and a closed window's mark is pruned.
#
# Args: state_file, newline-separated current window names. Emits
# carried `<window>\t<class>` rows on stdout.
_idle_carry_engaged_rows() {
    local state_file="$1" cur_names="$2"
    [[ -f "$state_file" ]] || return 0
    local w cls now
    now=$(date +%s)
    while IFS=$'\t' read -r w cls; do
        [[ -n "$w" ]] || continue
        grep -qxF -- "$w" <<<"$cur_names" && continue
        case "$cls" in
            operator-engaged)
                _openg_marked "$w" || continue
                printf '%s\toperator-engaged\n' "$w" ;;
            parked-awaiting-skeptic)
                _idle_skeptic_parked "$w" "$now" || continue
                printf '%s\tparked-awaiting-skeptic\n' "$w" ;;
        esac
    done < "$state_file"
}

# Close-reminder pass (issue #201). For each idle operator-engaged
# window in this cycle's set: once the operator has been away
# (now − last) for a full reminder period, emit ONE
# `engaged-close-reminder` row and stamp `reminded`, so the row
# re-fires at most once per period. The row is emit-only — it is
# never persisted into idle-state.tsv, so it cannot perturb the
# (window, class) dedupe; the underlying class stays
# `operator-engaged` throughout. A returning operator re-seeds the
# episode (resetting `reminded`) and the cadence re-arms.
#
# Args: this cycle's full `<window>\t<class>\t<age>\t<detail>` set.
# Emits due `<window>\tengaged-close-reminder\t<away>\t<src>` rows.
_idle_emit_due_close_reminders() {
    local cur_set="$1"
    [[ -n "$cur_set" ]] || return 0
    local now rem_secs w cls age detail
    now=$(date +%s)
    rem_secs=$(_openg_reminder_seconds)
    while IFS=$'\t' read -r w cls age detail; do
        [[ "$cls" == "operator-engaged" ]] || continue
        local row since last prompt_seen src reminded
        row=$(_openg_lookup "$w")
        [[ -n "$row" ]] || continue
        IFS=$'\t' read -r since last prompt_seen src reminded <<<"$row"
        [[ "$last" =~ ^[0-9]+$ ]] || continue
        [[ "$reminded" =~ ^[0-9]+$ ]] || reminded=0
        local away=$(( now - last ))
        (( away >= rem_secs )) || continue
        if (( reminded == 0 )) || (( now - reminded >= rem_secs )); then
            printf '%s\tengaged-close-reminder\t%s\t%s\n' \
                "$w" "$away" "${src:-engaged}"
            _openg_write "$w" "$since" "$last" "$prompt_seen" "${src:-}" "$now"
        fi
    done <<<"$cur_set"
}

list_idle_transitions() {
    local state_file="${STATE_DIR}/idle-state.tsv"
    local cur_set
    cur_set=$(list_really_idle_workers)
    if [[ -z "$cur_set" ]]; then
        # Preserve mid-episode engaged rows even when the pool
        # empties (the engaged window itself being busy/typing is
        # the common cause in small workspaces).
        _idle_carry_engaged_rows "$state_file" "" > "${state_file}.next" 2>/dev/null \
            || : > "${state_file}.next"
        mv "${state_file}.next" "$state_file"
        return 0
    fi
    # `! -s` (missing OR empty), not `! -f`: an EMPTY state file —
    # the normal residue of a cycle where every idle window went
    # busy — must take the emit-everything branch too. Feeding an
    # empty file through the awk dedupe below silently swallows the
    # current set's first row (with zero records in file 1, awk's
    # `FNR == NR` holds for file 2's first record), so a workspace
    # whose ONLY idle worker went busy and idled again never re-saw
    # its row (issue #196 demo regression).
    if [[ ! -s "$state_file" ]]; then
        printf '%s\n' "$cur_set" \
            | awk -F'\t' 'NF>0 { printf "%s\t%s\n", $1, $2 }' > "$state_file"
        printf '%s\n' "$cur_set"
        _idle_emit_due_close_reminders "$cur_set"
        return 0
    fi
    # Split this cycle's set into the non-retained subset (deduped
    # row-by-row) and the retained subset (emitted as a single
    # group when the membership changes).
    local cur_normal cur_retained
    cur_normal=$(printf '%s\n' "$cur_set" \
        | awk -F'\t' '$2 != "retained" && NF>0')
    cur_retained=$(printf '%s\n' "$cur_set" \
        | awk -F'\t' '$2 == "retained" && NF>0')
    # Non-retained dedupe against the prior state file.
    if [[ -n "$cur_normal" ]]; then
        awk -F'\t' '
            FNR == NR { prev[$1 "\t" $2] = 1; next }
            { key = $1 "\t" $2; if (!(key in prev)) print $0 }
        ' "$state_file" <(printf '%s\n' "$cur_normal")
    fi
    # Suppressed-set change detection: compare the prior cycle's
    # retained window names (sorted) against this cycle's.
    local prev_retained_names cur_retained_names
    prev_retained_names=$(awk -F'\t' '$2 == "retained" { print $1 }' "$state_file" | sort -u)
    cur_retained_names=$(printf '%s\n' "$cur_retained" \
        | awk -F'\t' 'NF>0 { print $1 }' | sort -u)
    if [[ "$prev_retained_names" != "$cur_retained_names" ]] \
       && [[ -n "$cur_retained" ]]; then
        printf '%s\n' "$cur_retained"
    fi
    # Persist this cycle's full set for the next dedupe pass, plus
    # the carried operator-engaged rows for windows currently out of
    # the pool mid-episode (see _idle_carry_engaged_rows).
    local carried cur_names
    cur_names=$(printf '%s\n' "$cur_set" | awk -F'\t' 'NF>0 { print $1 }')
    carried=$(_idle_carry_engaged_rows "$state_file" "$cur_names")
    {
        printf '%s\n' "$cur_set" \
            | awk -F'\t' 'NF>0 { printf "%s\t%s\n", $1, $2 }'
        [[ -n "$carried" ]] && printf '%s\n' "$carried"
    } > "${state_file}.next"
    mv "${state_file}.next" "$state_file"
    # Emit-only close reminders for long-away engaged windows — after
    # the persist on purpose (the rows must never enter the dedupe).
    _idle_emit_due_close_reminders "$cur_set"
}

# Render a one-line summary of the workspace state for use as an emit
# prelude. Format:
#
#   N busy | N idle | N retained | N idle-too-long | N pane-absent | N over-limit | N orphan-async | N interrupted | N awaiting-input
#
# The counts reflect THIS cycle's `list_really_idle_workers` output
# (plus a "busy" tally derived from windows the probe didn't classify
# as idle, since those are by definition busy / user-typing / freshly-
# spawned), and an `awaiting-input` count derived from the worker
# notifications log (issue #76) — workers whose `Notification` hook
# has fired since the previous prelude render. Closes issue #72
# regression 6's "operator can't tell what the workspace looks like
# from a single emit" gap and complements `pane-state=blocked`
# heuristics with a structural signal from claude itself. The
# `over-limit` axis (issue #87) counts workers whose pane shows the
# canonical "You've hit your limit · resets <time>" notice — a
# functional suspension the orchestrator should resolve by scheduling
# a resume at the named reset time.
#
# The function ALWAYS prints exactly one line. Empty workspace prints
# `0 busy | 0 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | 0 interrupted | 0 parked-skeptic | 0 awaiting-input`.
#
# `parked-skeptic` (PR #285) counts workers parked on a live
# skeptic-pending marker (`parked-awaiting-skeptic` class) — waiting on an
# independent validation pass, NOT actively working — and is excluded from
# the `busy` residue so "busy" means genuinely-working.
#
# Side effects: rotates the notifications log when oversized
# (default 10MiB; override via MONITOR_NOTIFICATIONS_LOG_MAX_BYTES)
# and stamps the prelude epoch into `last-prelude.ts` so the next
# render scopes its awaiting-input count to events that arrived
# after this emit. The first render after a fresh STATE_DIR sees
# no stamp and reports 0 awaiting-input — accepted trade-off so
# stale historical rows don't inflate the first count after a
# watcher cold-start.
render_idle_prelude() {
    # Total workers (non-reserved) seen this cycle. Reserved windows
    # are excluded by _idle_list_worker_windows.
    local total_workers idle_set
    total_workers=$(_idle_list_worker_windows | awk -F'\t' 'NF>0 && $1!="" {n++} END {print n+0}')
    # Pull the current idle set without persisting transition state —
    # render_idle_section's caller (render_idle_section itself) already
    # advances the dedupe file, so calling list_really_idle_workers
    # again here is read-only with respect to the engagement-log.
    # We rely on the probe being deterministic when invoked twice in
    # the same cycle (no time-dependent side-effects beyond stamping).
    # Read-only: the prelude only COUNTS. The authoritative transition emit
    # (render_idle_section) is the sole cycle-mutator of the idle-with-children
    # backoff state; a count-only pass here must not advance the edge-triggered
    # level and steal a clarification nudge (your-org/nexus-code#455 refine).
    idle_set=$(MONITOR_IDLE_PROBE_READONLY=1 list_really_idle_workers 2>/dev/null)
    local n_idle n_retained n_idle_too_long n_pane_absent n_over_limit n_orphan_async
    # `orphaned-skeptic-pending` (emit/exemption fidelity) folds into the
    # idle tally so it is excluded from the `busy` residue (like the parked
    # class) — it is a stuck-not-working state. Its distinct, actionable row
    # still surfaces in the idle SECTION; only the prelude scalar buckets it.
    n_idle=$(printf '%s\n' "$idle_set" | awk -F'\t' '
        NF>0 && ($2=="no-wrap-up" || $2=="wrapped" || $2=="wrapped-but-stub" || $2=="paste-unconfirmed" || $2=="orphaned-skeptic-pending") {n++}
        END {print n+0}')
    n_retained=$(printf '%s\n' "$idle_set" | awk -F'\t' '$2=="retained" {n++} END {print n+0}')
    n_idle_too_long=$(printf '%s\n' "$idle_set" | awk -F'\t' '$2=="idle-too-long" {n++} END {print n+0}')
    n_pane_absent=$(printf '%s\n' "$idle_set" | awk -F'\t' '$2=="pane-absent" {n++} END {print n+0}')
    n_over_limit=$(printf '%s\n' "$idle_set" | awk -F'\t' '$2=="over-limit" {n++} END {print n+0}')
    # orphan-async (issue #183): workers with self-declared external
    # waits but no resume mechanism. Distinct from `idle` (genuinely
    # nothing to do) and `over-limit` (suspended by Anthropic) — the
    # operator's action is to install a wake mechanism or dismiss
    # the waits.
    n_orphan_async=$(printf '%s\n' "$idle_set" | awk -F'\t' '$2=="idle-orphan-async" {n++} END {print n+0}')
    # interrupted (stall-detection): workers whose last turn died to an
    # API/model error (StopFailure marker fresh, process alive). Distinct
    # from `idle`/`no-wrap-up` (clean finish) — the operator's action is
    # to resume (transient) or respawn (config), not to nag a wrap-up.
    local n_interrupted
    n_interrupted=$(printf '%s\n' "$idle_set" | awk -F'\t' '$2=="interrupted" {n++} END {print n+0}')
    # parked-awaiting-skeptic (skills/nexus.skeptic, PR #285). A worker
    # parked in `skeptic-channel.sh await` (or whose required-skeptic
    # verdict has not yet retired it) is NOT actively working — it is
    # waiting on an independent validation pass. list_really_idle_workers
    # emits it as its own `parked-awaiting-skeptic` class and short-circuits
    # (it is neither idle nor busy). Without its own tally it fell into the
    # `n_busy = total - n_idle_total` residue and inflated "N busy",
    # misleading the operator ("all 11 busy" when their PRs had merged and
    # the workers were merely parked). Give it a distinct axis and exclude
    # it from busy so "busy" means genuinely-working.
    local n_parked
    n_parked=$(printf '%s\n' "$idle_set" | awk -F'\t' '$2=="parked-awaiting-skeptic" {n++} END {print n+0}')
    # idle-with-children (your-org/nexus-code#455 refine): workers idle but
    # holding ≥1 live background child. `idle-awaiting-job` is the exempt
    # long-timeout state; `idle-children-clarify` and `wrapped-with-children`
    # are actionable (inject a clarification prompt / resolve the
    # inconsistency). All three are idle-not-busy — give them a distinct axis
    # and exclude from the busy residue.
    local n_bg_children
    n_bg_children=$(printf '%s\n' "$idle_set" | awk -F'\t' '
        $2=="idle-awaiting-job" || $2=="idle-children-clarify" || $2=="wrapped-with-children" {n++}
        END {print n+0}')
    # Busy ≈ workers not appearing in the idle set. Approximation:
    # spawn-grace skips and `empty`-skip windows count as busy here,
    # which matches the operator's mental model ("not idle = working").
    local n_idle_total=$(( n_idle + n_retained + n_idle_too_long + n_pane_absent + n_over_limit + n_orphan_async + n_interrupted + n_parked + n_bg_children ))
    local n_busy=$(( total_workers - n_idle_total ))
    (( n_busy < 0 )) && n_busy=0

    # awaiting-input counter (issue #76). Rotate first, then count,
    # then stamp — rotation moves the live file out of the way under
    # an archive-suffixed name, so the rotated rows don't double-count
    # on the next cycle. The stamp's purpose is to scope the count to
    # "since the last render" so a notification that's already been
    # surfaced doesn't keep showing up cycle after cycle until it's
    # answered (the operator sees it once, then it's their move).
    #
    # Stamp carries subsecond precision (`date +%s.%N`) so a hook that
    # fires in the same wall-second the prelude finishes is still
    # counted — jq's `now` in the worker hook emits a float, the
    # comparison `ts > since` is float-aware via jq, and the
    # awk fallback uses numeric comparison too.
    local max_bytes="${MONITOR_NOTIFICATIONS_LOG_MAX_BYTES:-10485760}"
    _notifications_rotate_if_oversized "$max_bytes"
    local stamp_path stamp_epoch n_awaiting now
    stamp_path=$(_notifications_stamp_path)
    stamp_epoch=0
    if [[ -f "$stamp_path" ]]; then
        stamp_epoch=$(cat "$stamp_path" 2>/dev/null || echo 0)
        [[ "$stamp_epoch" =~ ^[0-9]+(\.[0-9]+)?$ ]] || stamp_epoch=0
    fi
    n_awaiting=$(_notifications_count_distinct_since "$stamp_epoch")
    now=$(date +%s.%N 2>/dev/null || date +%s)
    # Dry-run (issue #104): caller is computing a canonical-form prelude
    # for the full-state identity check, NOT emitting. Leave the stamp
    # un-advanced so the next real render still sees the same since-
    # window and the operator-facing awaiting-input count is preserved
    # across suppression cycles.
    if [[ -z "${MONITOR_PRELUDE_DRY_RUN:-}" ]]; then
        mkdir -p "$(dirname "$stamp_path")" 2>/dev/null || true
        printf '%s' "$now" > "$stamp_path" 2>/dev/null || true
    fi

    printf '%d busy | %d idle | %d retained | %d idle-too-long | %d pane-absent | %d over-limit | %d orphan-async | %d interrupted | %d parked-skeptic | %d idle-children | %d awaiting-input\n' \
        "$n_busy" "$n_idle" "$n_retained" "$n_idle_too_long" "$n_pane_absent" "$n_over_limit" "$n_orphan_async" "$n_interrupted" "$n_parked" "$n_bg_children" "$n_awaiting"
}

# Render every currently-tracked worker window's full classification
# row for the periodic full-state snapshot emit. Same line shape as
# render_idle_section produces for transitions — but NOT deduped, NOT
# gated on transition. Caller decides when to render (typically every
# Nth cycle). Includes busy / user-typing windows as a "(active)"
# annotation so the operator's full-state snapshot is genuinely full.
render_full_state_snapshot() {
    local raw
    raw=$(_idle_list_worker_windows)
    [[ -n "$raw" ]] || return 0
    local now name activity_epoch window_index pane_state engaged_grace
    now=$(date +%s)
    engaged_grace=$(_openg_grace_seconds)
    # Live windows once, for the skeptic fidelity check (emit/exemption
    # fidelity) — see list_really_idle_workers.
    local live_windows
    live_windows=$(tmux list-windows -F '#{window_name}' 2>/dev/null || true)
    while IFS=$'\t' read -r name activity_epoch window_index; do
        [[ -n "$name" ]] || continue
        local probe_target="${window_index:-$name}"
        local pane_line pane_reset_at
        pane_line=$(_idle_pane_state_line "$probe_target" "$name")
        pane_state=$(printf '%s' "$pane_line" \
            | sed -n 's/.*state=\([a-z-]*\).*/\1/p')
        [[ -n "$pane_state" ]] || pane_state=unknown
        # your-org/nexus-code#1397: `unknown` has TWO sources and they are
        # different facts. pane-state.sh printing `state=unknown` is a
        # CLASSIFIER verdict about the pane; the probe returning NO line is
        # an INSTRUMENT failure (a render timeout, a refused read, a crash)
        # and says nothing about the pane. `pane_state` stays `unknown` for
        # both — that token is not on the kill allowlist, so both fail safe —
        # but the RENDERED label says which one happened, with the rc and the
        # first stderr line, so an operator does not treat a broken probe as
        # an unclassifiable worker. Only the display string differs.
        local pane_state_shown="$pane_state"
        if [[ "$pane_state" == unknown ]]; then
            if [[ "$(_idle_pane_line_field "$pane_line" probe)" == failed ]]; then
                pane_state_shown="unknown; pane-state.sh READ FAILED (rc=$(_idle_pane_line_field "$pane_line" probe_rc), stderr: ${pane_line#*probe_stderr=}) — an INSTRUMENT failure, not a pane classification; a direct \`monitor/pane-state.sh ${name}\` may well classify it"
            else
                pane_state_shown="unknown; classifier verdict — pane-state.sh ran and could not classify this pane"
            fi
        fi
        pane_reset_at=$(_idle_pane_line_field "$pane_line" reset_at)
        # parked-awaiting-skeptic annotation (PR #285): a worker with a
        # live skeptic-pending marker is parked in `await`. It usually
        # renders `busy` (the await tool's spinner), but label it
        # explicitly so the full-state snapshot shows parked workers
        # distinctly from ordinary active work.
        if _idle_skeptic_parked "$name" "$now" "$live_windows"; then
            # your-org/nexus-code#845: the JOIN — which skeptic, idle how long.
            local _snap_join; _snap_join=$(_idle_skeptic_join_detail "$now" "$raw")
            if [[ "${_IDLE_SKEPTIC_PARK_BASIS:-}" == "skeptic-live" ]]; then
                # #1039: stale await marker, live skeptic. Still exempt — and
                # the row says which of the two facts the exemption rests on.
                printf '  - %s parked-awaiting-skeptic (state=%s; live skeptic window, worker await marker STALE — exempt on the skeptic, not on an active await loop%s)\n' \
                    "$name" "$pane_state_shown" "$_snap_join"
            elif [[ "${_IDLE_SKEPTIC_PARK_BASIS:-}" == "channel" ]]; then
                printf "  - %s parked-awaiting-skeptic (state=%s; skeptic reviewing — no linkage record, but the comms channel holds this round's traffic (spawned without --skeptic-role; #1153) — exempt from idle/close%s)\n" \
                    "$name" "$pane_state_shown" "$_snap_join"
            else
                printf '  - %s parked-awaiting-skeptic (state=%s; skeptic reviewing — exempt from idle/close%s)\n' \
                    "$name" "$pane_state_shown" "$_snap_join"
            fi
            continue
        fi
        # Orphaned marker (emit/exemption fidelity): fresh marker, no live
        # skeptic past grace — surface distinctly in the cumulative snapshot
        # so a stuck park is visible at the heartbeat cadence, not masked as
        # ordinary activity.
        if _idle_skeptic_orphaned "$name" "$now" "$live_windows"; then
            printf '  - %s orphaned-skeptic-pending (state=%s; no live skeptic — ask `ng skeptic-evidence %s` whether a verdict EXISTS before you spawn or clear; your-org/nexus-code#1156)\n' \
                "$name" "$pane_state_shown" "$name"
            continue
        fi
        # Idle-with-children (your-org/nexus-code#455 refine): re-show the
        # wrap-up-with-children inconsistency and the long-wait state at the
        # full-state cadence so the operator sees them even after the
        # per-transition row has deduped out.
        if [[ "$pane_state" == "working-background" ]]; then
            local snap_bg_shells snap_bg_reliable snap_bg_infra snap_bg_cmd snap_bg_task
            snap_bg_shells=$(_idle_pane_line_field "$pane_line" bg_shells)
            snap_bg_reliable=$(_idle_pane_line_field "$pane_line" bg_reliable)
            [[ "$snap_bg_shells" =~ ^[0-9]+$ ]] || snap_bg_shells=0
            [[ "$snap_bg_reliable" =~ ^[0-9]+$ ]] || snap_bg_reliable=0
            # #590: this renderer classifies INDEPENDENTLY of
            # list_really_idle_workers, so the protocol-wait exclusion has to be
            # applied here too — otherwise the false positive that was fixed for
            # the per-transition emit simply reappears at the full-state cadence.
            snap_bg_infra=$(_idle_pane_line_field "$pane_line" bg_infra)
            snap_bg_cmd=$(_idle_pane_line_field "$pane_line" bg_cmd)
            [[ "$snap_bg_infra" =~ ^[0-9]+$ ]] || snap_bg_infra=0
            [[ -n "$snap_bg_cmd" && "$snap_bg_cmd" != "-" ]] || snap_bg_cmd=""
            snap_bg_task=$(( snap_bg_shells - snap_bg_infra ))
            (( snap_bg_task >= 0 )) || snap_bg_task=0
            # your-org/nexus-code#1446: a child whose elapsed dwarfs its CPU is
            # BLOCKED, not long-running — three >5h stalls and a 5h36m waiter
            # all read `working-background` here with nothing to tell them from
            # a real compute job. pane-state now measures it (`bg_wedged=1`,
            # with the CPU share in basis points); this renderer NAMES it so
            # the operator sees a stall instead of healthy-with-a-job.
            local snap_bg_wedged snap_bg_cpu_bp snap_wedge_note="" snap_bg_members snap_turnover
            snap_bg_wedged=$(_idle_pane_line_field "$pane_line" bg_wedged)
            snap_bg_cpu_bp=$(_idle_pane_line_field "$pane_line" bg_cpu_bp)
            snap_bg_members=$(_idle_pane_line_field "$pane_line" bg_members)
            # your-org/nexus-code#1460: lifetime CPU cannot tell a wedge from a
            # sequential driver blocked in wait() — three false WEDGED? emits
            # in one night, all on workers running the prescribed pre-push
            # battery. MEMBERSHIP TURNOVER can: a wedge cannot produce an exit.
            # pane-state emits a digest of the walked pid tree; this compares
            # it with the previous tick's and only calls a static tree wedged.
            snap_turnover=$(_idle_bg_membership_turnover "$name" "$snap_bg_members")
            if [[ "$snap_bg_wedged" == "1" ]]; then
                case "$snap_turnover" in
                    changed)
                        snap_wedge_note=" — child at ${snap_bg_cpu_bp:-?} bp CPU over its episode, but its process MEMBERSHIP changed since the last tick: a sequential driver blocked in wait() (guards-for-diff --run, run-ratchets.sh, a runner), not a wedge — a wedge cannot produce an exit (your-org/nexus-code#1460)" ;;
                    first)
                        snap_wedge_note=" — child at ${snap_bg_cpu_bp:-?} bp CPU over its episode; process membership recorded and compared next tick before this is called WEDGED (your-org/nexus-code#1460)" ;;
                    static:*)
                        snap_wedge_note=" — WEDGED? child at ${snap_bg_cpu_bp:-?} bp CPU (0.01%=1) over its whole episode AND its process membership has been STATIC for ${snap_turnover#static:}s (no descendant started or exited): read its wchan, fd/0 and cmdline in /proc; an existence query piped into head, or a wait on a token the producer never writes, looks exactly like this (your-org/nexus-code#1446, #1447, #1460)" ;;
                    *)
                        # No digest on the line (an older pane-state, or an
                        # override): the pre-#1460 reading, stated as such.
                        snap_wedge_note=" — WEDGED? child at ${snap_bg_cpu_bp:-?} bp CPU (0.01%=1) over its whole episode (membership not measured): read its wchan, fd/0 and cmdline in /proc; an existence query piped into head, or a wait on a token the producer never writes, looks exactly like this (your-org/nexus-code#1446, #1447)" ;;
                esac
            fi
            if (( snap_bg_reliable == 1 )) && (( snap_bg_shells >= 1 )); then
                if _bg_window_is_wrapped "$name"; then
                    if (( snap_bg_task <= 0 )) && (( snap_bg_infra >= 1 )); then
                        # Every live child is a nexus protocol wait loop — the
                        # prescribed post-wrap-up shape, not an inconsistency.
                        # Still SHOW it (this is the cumulative snapshot, whose
                        # job is to account for every window) but as the benign
                        # state it is, and without demanding a decision.
                        printf '  - %s wrapped-awaiting-protocol (%d protocol wait child(ren)%s — prescribed by wrap-up; retire-eligible)\n' \
                            "$name" "$snap_bg_infra" "${snap_bg_cmd:+ [child: $snap_bg_cmd]}"
                        continue
                    fi
                    printf '  - %s wrapped-with-children (%d live child(ren) after wrap-up%s — inconsistency; clarify or close)%s\n' \
                        "$name" "$snap_bg_task" "${snap_bg_cmd:+ [child: $snap_bg_cmd]}" "$snap_wedge_note"
                else
                    printf '  - %s idle-awaiting-job (state=working-background; %d live background child(ren) — long-timeout backoff)%s\n' \
                        "$name" "$snap_bg_shells" "$snap_wedge_note"
                fi
                continue
            fi
        fi
        case "$pane_state" in
            busy|user-typing|working-background|working-self-paced)
                printf '  - %s (active, state=%s)\n' "$name" "$pane_state_shown" ;;
            absent|blocked)
                printf '  - %s pane-absent (state=%s)\n' "$name" "$pane_state_shown" ;;
            over-limit)
                printf '  - %s OVER-LIMIT (resets %s)\n' \
                    "$name" "${pane_reset_at:-unknown}" ;;
            *)
                local age_anchor epoch
                epoch=$(_engagement_log_lookup "$name")
                if [[ "$epoch" =~ ^[0-9]+$ ]]; then
                    age_anchor=$epoch
                else
                    age_anchor=$activity_epoch
                fi
                local age=$(( now - age_anchor ))
                # Interrupted-mid-turn (stall-detection): a fresh
                # turn-failure marker reclassifies an otherwise-idle
                # window. Show it in the snapshot so the full-state
                # view matches the transition emit.
                if _idle_turn_failure_fresh "$name" "$now"; then
                    local snap_rec
                    snap_rec=$(_idle_turn_failure_field "$name" recovery)
                    printf '  - %s interrupted (idle %ds; turn crashed, recovery=%s)\n' \
                        "$name" "$age" "${snap_rec:-paste}"
                elif _openg_marked "$name"; then
                    local openg_last away
                    openg_last=$(_openg_lookup "$name" | cut -f2)
                    [[ "$openg_last" =~ ^[0-9]+$ ]] || openg_last="$now"
                    away=$(( now - openg_last ))
                    if (( away > engaged_grace )); then
                        printf '  - %s operator-engaged (operator away %ds; idle %ds, state=%s)\n' \
                            "$name" "$away" "$age" "$pane_state_shown"
                    else
                        printf '  - %s operator-engaged (idle %ds, state=%s)\n' \
                            "$name" "$age" "$pane_state_shown"
                    fi
                else
                    printf '  - %s idle %ds (state=%s)\n' "$name" "$age" "$pane_state_shown"
                fi
                ;;
        esac
    done <<<"$raw"
}

# Re-stat a rendered full-state `--- workspace snapshot ---` body against
# the CURRENT tmux window set, dropping window rows whose window no longer
# exists (watcher-emit-noise, Class 1). The snapshot is served from the
# async-staged full_state_snap.out (600s cadence), so a window killed
# between async renders lingers as a live "idle Ns (state=...)" row until
# the next pass — actively misleading (the 2026-07-21 00:37 emit listed
# two kill-window'd windows as live while its own fresh prelude header
# already counted them gone). Filtering at compose time makes the
# heartbeat snapshot reflect the live window set, and — because the
# canonical is built from the filtered body — a kill promptly changes the
# canonical and the correction emits at the next cadence instead of
# waiting a full async cycle.
#
# Only `^  - <name> …` rows are candidates for dropping; every other line
# (the `(full snapshot; …)` footer, blanks) passes through untouched. The
# window name is the token after the leading `  - `. Pass-through when the
# live set is empty (tmux transient / unavailable) so a real snapshot is
# never nuked by a momentary probe failure.
#   $1  live tmux window names (newline-separated; queried if empty)
# Reads snapshot text on stdin, writes filtered text on stdout.
_full_state_restat_live_windows() {
    local live="${1:-}"
    if [[ -z "$live" ]]; then
        live=$(tmux list-windows -F '#{window_name}' 2>/dev/null || true)
    fi
    # Empty live set ⇒ can't distinguish "no windows" from "tmux failed";
    # pass through unchanged rather than risk dropping a valid snapshot.
    [[ -n "$live" ]] || { cat; return 0; }
    awk -v live="$live" '
        BEGIN {
            n = split(live, a, "\n")
            for (i = 1; i <= n; i++) if (a[i] != "") L[a[i]] = 1
        }
        /^  - / { if (!($2 in L)) next }
        { print }
    '
}

# Re-stat a rendered `--- idle workers ---` body against the CURRENT tmux
# window set, WITHHOLDING rows whose window no longer exists and SAYING SO
# (your-org/nexus-code#1044).
#
# WHY THIS SECTION NEEDS IT AND DID NOT HAVE IT. The idle section is served to
# compose_emit from an ASYNC-STAGED file (`idle_section.out`, 30 s cadence,
# main.sh) exactly as the full-state snapshot is served from `full_state_snap.out`
# (600 s). The full-state path has had `_full_state_restat_live_windows` since
# the 2026-07-21 emit that listed two kill-window'd windows as live. The idle
# path is its SIBLING and was never enrolled — so a window that died between
# async renders lingered here as a live row while the `--- tmux ---` section of
# the SAME message had already dropped it. That is the observed contradiction:
# one emit asserting a window both gone and present.
#
# The harm is not the staleness, it is the INSTRUCTION. The lingering row read
# `pane-absent (overlay awaiting the operator (blocked) — ANSWER it in the pane;
# do NOT relaunch or close)` — an explicit do-not-clean-up directive aimed at a
# window that provably did not exist.
#
# THE TRACKER ITSELF IS NOT THE BUG, and this is worth recording because the
# original report guessed otherwise and then corrected itself. `list_idle_transitions`
# persists the set derived from LIVE tmux, so a vanished window's row is dropped
# on the very next pass — MEASURED: exactly ONE cycle. There is no missing
# reaper. What there is, is a render served from a file up to one cadence old
# and handed to the reader with no reconciliation.
#
# WITHHELD ROWS ARE NAMED, NOT SILENTLY DROPPED. A section that quietly shrinks
# is the same defect wearing the remedy's clothes — the reader cannot tell a
# reconciled section from one that had nothing to say. Deterministic order (the
# order rows appeared), so the output is testable.
#
#   $1  live tmux window names (newline-separated; queried if empty)
# Reads the section text on stdin, writes the reconciled text on stdout.
_idle_restat_live_windows() {
    local live="${1:-}"
    if [[ -z "$live" ]]; then
        live=$(tmux list-windows -F '#{window_name}' 2>/dev/null || true)
    fi
    # Empty live set ⇒ cannot distinguish "no windows" from "tmux failed".
    # Pass through unchanged rather than blank a real section on a transient
    # probe failure — the same fail-open the full-state sibling uses.
    [[ -n "$live" ]] || { cat; return 0; }
    awk -v live="$live" '
        BEGIN {
            n = split(live, a, "\n")
            for (i = 1; i <= n; i++) if (a[i] != "") L[a[i]] = 1
            nd = 0
        }
        /^  - / {
            if (!($2 in L)) {
                if (!($2 in seen)) { seen[$2] = 1; order[++nd] = $2 }
                next
            }
        }
        { print }
        END {
            if (nd > 0) {
                s = ""
                for (i = 1; i <= nd; i++) s = s (i == 1 ? "" : ", ") order[i]
                printf "  (%d row(s) WITHHELD — the window(s) no longer exist in tmux: %s. This section is rendered asynchronously and was reconciled against the live window set at emit time; do NOT act on a withheld window. your-org/nexus-code#1044)\n", nd, s
            }
        }
    '
}

# Render the idle-workers section body for inclusion in the watcher
# emit. Empty stdout if no transitions this cycle. Six shapes:
# five per-row formats (one per non-retained class, matching the
# table in `skills/nexus.window-cleanup` and `monitor/README.md`)
# plus a `(N retained windows suppressed: …)` footer that collates
# all currently-retained rows from this cycle's transitions.
# Reasons over 40 chars are truncated with `…`.
render_idle_section() {
    local transitions
    transitions=$(list_idle_transitions)
    [[ -n "$transitions" ]] || return 0
    # Per-window rows (non-retained classes only).
    printf '%s\n' "$transitions" | awk -F'\t' '
        function fmt_age(s,    h, m) {
            if (s >= 3600) {
                h = int(s / 3600); m = int((s % 3600) / 60)
                return sprintf("%dh%02dm", h, m)
            }
            return sprintf("%ds", s)
        }
        # your-org/nexus-code#1355. The empty-streams sentence, ONCE, and
        # restating monitor/async-run.sh _evidence (mode 1) FAITHFULLY. The
        # previous text appeared at three arms, DROPPED the source redirect
        # clause and ADDED "not a result" — a phrase the source never says.
        # Measured 7 of 7 false alarms on one window whose driver redirected
        # per-suite output to files. Three corrections, all from the issue:
        #   1. the REDIRECT clause is carried, and when the classifier saw a
        #      redirect in the argv (x=) the case is named EMPTY BY DESIGN;
        #   2. SCOPED TO rc=0: b= counts only finished rc=0 with 0 B / 0 B,
        #      so a NON-ZERO rc with empty streams (2 = refused, 124 =
        #      timeout) is reported as the STATUS it is;
        #   3. "not a result" is gone; the source claim — UNCORROBORATED as
        #      a verdict on the WORK — is the one that is true.
        # A legacy counts string without b= (b < 0) gets the full faithful
        # sentence rather than silence. NO APOSTROPHES (single-quoted awk).
        function uncorr(wcnt,    _b, _x) {
            _b = -1; _x = 0
            if (match(wcnt, /b=[0-9]+/)) _b = substr(wcnt, RSTART+2, RLENGTH-2) + 0
            if (match(wcnt, /x=[0-9]+/)) _x = substr(wcnt, RSTART+2, RLENGTH-2) + 0
            if (_b == 0)
                return "no finished job here has an rc=0 with 0 B out and 0 B err, so each rc reads as the status it is (a NON-ZERO rc with empty streams is a STATUS, e.g. 2 = refused, 124 = timeout, not an absence)"
            if (_b < 0)
                return "an rc=0 that arrives with 0 B out and 0 B err is UNCORROBORATED as a verdict on the work — it is the status of the payload LAST command, and a payload that redirects its own output leaves this surface blank by design; find the payload own log before treating rc=0 as a verdict. A NON-ZERO rc with empty streams is a STATUS (2 = refused, 124 = timeout), not an absence"
            if (_x >= _b)
                return sprintf("%d finished rc=0 with 0 B out and 0 B err — EMPTY BY DESIGN: the recorded argv redirects its own output, so find the payload own log rather than reading the empty streams as evidence of anything", _b)
            if (_x > 0)
                return sprintf("%d finished rc=0 with 0 B out and 0 B err: %d of those redirect their own output (EMPTY BY DESIGN — find the payload own log), and the other %d are UNCORROBORATED as a verdict on the work, being only the status of the payload LAST command. A NON-ZERO rc with empty streams is a STATUS, not an absence", _b, _x, _b - _x)
            return sprintf("%d finished rc=0 with 0 B out and 0 B err, so that rc is UNCORROBORATED as a verdict on the work — it is the status of the payload LAST command, and a payload that redirects its own output leaves this surface blank; find the payload own log before treating rc=0 as a verdict. A NON-ZERO rc with empty streams is a STATUS (2 = refused, 124 = timeout), not an absence", _b)
        }
        $2 == "wrapped" {
            printf "  - %s wrapped up (idle %s; wrap-up logged)\n", $1, fmt_age($3)
        }
        $2 == "wrapped-but-stub" {
            detail = ($4 == "" ? "report incomplete" : $4)
            printf "  - %s wrapped-but-stub (%s)\n", $1, detail
        }
        $2 == "no-wrap-up" {
            printf "  - %s idle %s WITHOUT wrap-up — consider follow-up paste\n", $1, fmt_age($3)
        }
        $2 == "operator-engaged" {
            src = ($4 == "" ? "engaged" : $4)
            printf "  - %s operator-engaged (src=%s; idle %s — operator driving; idle/retire handling suppressed while engaged)\n", $1, src, fmt_age($3)
        }
        $2 == "engaged-close-reminder" {
            src = ($4 == "" ? "engaged" : $4)
            printf "  - %s operator-engaged but operator away %s (src=%s) — consider closing this window; reminder re-fires once per period until the operator returns or it closes\n", $1, fmt_age($3), src
        }
        $2 == "paste-unconfirmed" {
            detail = ($4 == "" ? "paste unconfirmed" : $4)
            printf "  - %s paste-unconfirmed (%s; no UserPromptSubmit fired and consumption COULD NOT BE CONFIRMED from the transcript — this is an unresolved question, not an established non-delivery). VERIFY CONSUMPTION FIRST — re-pasting duplicates completed work, so this advice is deliberately not self-executing. A paste whose sender recorded `submitted` no longer reaches you at all; what remains are shapes neither side could settle: a paste that landed via the retry-Enter path is delivered yet stamps nothing, and a paste QUEUED behind an in-flight turn fires no submit until that turn drains (monitor/pane-state.sh %s reporting `queued=1`, or `busy`, means delivered-and-pending — do NOT re-paste). Read the pane and the report filed by that worker for the pasted content having been acted on; re-paste via monitor/paste-followup.sh ONLY if it demonstrably was not.\n", $1, detail, $1
        }
        $2 == "parked-awaiting-skeptic" {
            # #1039: the detail column ($4) names the BASIS of the exemption
            # (an active await loop vs a live skeptic window over a stale
            # marker). Render it when set rather than asserting a bare park.
            if ($4 != "") {
                printf "  - %s parked-awaiting-skeptic (idle %s; %s; see skills/nexus.skeptic)\n", $1, fmt_age($3), $4
                next
            }
            # PR #285: worker is parked in the skeptic-channel await
            # loop, legitimately waiting for the reviewing skeptic next
            # request. Exempt from idle-too-long / no-wrap-up until the
            # skeptic-pending marker clears (verdict returned). Surfaced
            # so the orchestrator sees parked workers; NOT an action item.
            printf "  - %s parked-awaiting-skeptic (idle %s; skeptic reviewing — exempt from idle/close until verdict; see skills/nexus.skeptic)\n", $1, fmt_age($3)
        }
        $2 == "orphaned-skeptic-pending" {
            # emit/exemption fidelity: a fresh skeptic-pending marker with
            # NO live skeptic past the grace window. NOT a park — a stuck
            # state. Actionable: the orchestrator either spawns the skeptic
            # (marker becomes a real park) or clears the marker (window
            # retires normally). Left unhandled it exempted the window from
            # idle/close forever (the bug this fixes).
            # THE ADVICE MUST NOT BE "spawn or clear" (your-org/nexus-code#1153,
            # #1156). Both arms are wrong when the verdict was DELIVERED and the
            # record could not match it — spawning manufactures work against a
            # reviewer that already discharged, and clearing the marker ALSO
            # voids a live obligation derivedly (#961). Those two cases are
            # indistinguishable from here; `ng skeptic-evidence` is the read
            # that separates them, so it goes FIRST.
            printf "  - %s orphaned-skeptic-pending (idle %s; marker but NO live skeptic — run `ng skeptic-evidence %s` FIRST. evidence NO-VERDICT [none]: nobody reviewed, spawn a skeptic per skills/nexus.skeptic. evidence CANNOT-ESTABLISH [? | resolved-only | discharge-without-verdict]: do NOT clear on it. evidence DELIVERED [attributed | unmatched-subject | no-open-arm | verdict-without-arm | unmatched-other | ambiguous-arms | rearm-after-close | superseded-verdict | prior-verdict-other-artefact]: a verdict WAS delivered, repair the record rather than clearing the marker, which also voids a live obligation)\n", $1, fmt_age($3), $1
        }
        $2 == "idle-awaiting-job" {
            # your-org/nexus-code#455 refine, case (a): idle worker with a
            # live background child (a Slurm job / long compute it is waiting
            # on). Exempt from reap under the exponential-backoff long
            # timeout. Informational — surfaces once per episode; NOT an
            # action item.
            detail = ($4 == "" ? "waiting on a background job" : $4)
            printf "  - %s idle-awaiting-job (idle %s; %s — exempt under long-timeout backoff)\n", $1, fmt_age($3), detail
        }
        $2 == "idle-children-clarify" {
            # your-org/nexus-code#455 refine, case (a): a clarification nudge
            # is due (the child CPU has been frozen past the current
            # backoff step, or the worker declared stuck/done). INJECT a
            # clarification prompt asking the worker to declare the job
            # expected runtime + health via monitor/worker-health.sh; the
            # watcher reads monitor/.state/worker-health/<window>.json next
            # cycle to extend the grace, reap, or keep asking.
            detail = ($4 == "" ? "waiting on a background job" : $4)
            printf "  - %s idle-children-clarify (idle %s; %s — paste the worker-health clarification prompt; see skills/nexus.window-cleanup)\n", $1, fmt_age($3), detail
        }
        $2 == "wrapped-with-children" {
            # your-org/nexus-code#455 refine, case (b): the worker wrapped up
            # but STILL has live child processes — an inconsistency (leftover
            # children, or a premature wrap while a job runs). Ask for
            # clarification (worker-health.sh) or close; default is ASK, not
            # auto-reap.
            detail = ($4 == "" ? "live children after wrap-up" : $4)
            printf "  - %s wrapped-with-children (idle %s; %s — inconsistency: paste the worker-health clarification prompt or close; see skills/nexus.window-cleanup)\n", $1, fmt_age($3), detail
        }
        $2 == "idle-too-long" {
            printf "  - %s idle-too-long %s (exceeds close threshold; consider close)\n", $1, fmt_age($3)
        }
        $2 == "pane-absent" {
            # your-org/nexus-code#808 — RENDER THE DETAIL THIS ROW CARRIES.
            # This arm used to print a fixed string and DISCARD $4, so the
            # classifier could compute a per-state advisory (it does, one
            # class covering `absent` and `blocked`) and the operator would
            # never see it: the advisory was decided in one file and
            # overwritten in another. A `blocked` pane — alive, rendering a
            # modal, waiting for a human — was told to relaunch it.
            #
            # NOTE FOR EDITORS: this awk program is SINGLE-QUOTED. An
            # apostrophe anywhere in these comments (the possessive that was
            # here first) terminates the quote and the file stops parsing —
            # a BASH syntax error at this line, which manifests as
            # `render_idle_section: command not found` and every render
            # assertion in test-idle-probe.sh failing at once. Keep the
            # prose apostrophe-free.
            #
            # Every other class in this renderer already reads $4. The
            # fallback keeps the historical text for a row written before this
            # change (or by any producer that leaves the column empty), so an
            # empty detail degrades to the old wording rather than to silence.
            detail = ($4 == "" ? "claude process gone or unresponsive; relaunch or close" : $4)
            printf "  - %s pane-absent (%s)\n", $1, detail
        }
        $2 == "over-limit" {
            # NAME THE LIMIT THE PANE NAMED, and never assert a reset that was
            # not established (your-org/nexus-code#1488). This line said
            # "weekly Opus limit hit" for every over-limit pane, including a
            # worker whose pane said FABLE; the orchestrator then scheduled a
            # resume against an Opus reset and the worker was refused again.
            # `$4` carries reset_at and `$5` the limit flavour; an empty
            # flavour renders as "usage", never as a tier nobody measured.
            reset_at = ($4 == "" ? "unknown" : $4)
            flavour  = ($5 == "" || $5 == "unknown") ? "usage" : $5
            gsub(/_/, " ", flavour)
            if (reset_at == "unknown")
                printf "  - %s OVER-LIMIT (%s limit hit; RESET TIME UNKNOWN — do not schedule a resume against a time nobody read; surface it)\n", $1, flavour
            else
                printf "  - %s OVER-LIMIT (resets %s; %s limit hit — schedule resume)\n", $1, reset_at, flavour
        }
        $2 == "idle-orphan-async" {
            # Issue #183: worker has self-declared external waits
            # but no resume mechanism (no Monitor handle, no
            # background bash, no ScheduleWakeup). The advisory
            # text quotes the offending kind:id list so the
            # operator can see the contract violation at a glance,
            # and points at the worker-defaults skill so a fix is
            # one paste away.
            #
            # `declare-no-wait.sh` USED TO BE OFFERED HERE AS A CO-EQUAL
            # ALTERNATIVE. your-org/nexus-code#1071 removed it from the emit,
            # for a reason that is asymmetric rather than stylistic: RESUMING a
            # worker whose job is genuinely still running costs one wasted
            # turn, whereas CLEARING that wait destroys the only record that
            # work is outstanding. The emit cannot tell those two cases apart,
            # because it reports that the worker HAS NO RESUME MECHANISM, never
            # that the job is over. Offering both at the same level invited the
            # destructive one at exactly the moment the operator had the least
            # information. It remains the right tool occasionally (it was, once,
            # for three `syn-` phantoms verified dead from OUTSIDE the session
            # against an empty `squeue`), so it stays documented in
            # skills/nexus.worker-defaults, WITH its precondition attached —
            # which is the part an emit line cannot carry.
            #
            # The watcher now also resolves these waits itself and pastes the
            # verdict (monitor/watcher/_orphan_async.sh), so this line is an
            # operator NOTIFICATION rather than the only thing standing between
            # the worker and an indefinite wait. Six workers in one session
            # stalled while every advisory control fired correctly: a detection
            # nobody reads is not a control.
            #
            # NB for editors: this awk program is inside a SINGLE-QUOTED bash
            # string, so an apostrophe anywhere in these comments ends the
            # string and breaks the file. Measured, while writing this block.
            # $4 is `<wait-class>|<kinds>` (your-org/nexus-code#1240). The
            # fallback keeps a row written by any producer that leaves the
            # column empty on the UNRESOLVED text, which is the safe arm.
            # $4 is `<class>|<counts>|<kinds>`. Both SHORTER legacy shapes are
            # accepted and degrade to the safe arm WITHOUT losing the job list:
            # a bare `<kinds>` (no pipe) is what a pre-#1240 producer writes, and
            # dropping it here would strip the one thing an operator reads.
            raw = ($4 == "" ? "unresolved|-|unknown" : $4)
            _p = index(raw, "|")
            if (_p == 0) { wcls = "unresolved"; wcnt = "-"; kinds = raw }
            else {
                wcls  = substr(raw, 1, _p - 1)
                _rest = substr(raw, _p + 1)
                _q    = index(_rest, "|")
                if (_q == 0) { wcnt = "-"; kinds = _rest }
                else { wcnt = substr(_rest, 1, _q - 1); kinds = substr(_rest, _q + 1) }
            }
            if (kinds == "") kinds = "unknown"
            if (wcnt == "" ) wcnt  = "-"
            # The COUNTS are the part an operator acts on at high cardinality:
            # a 13-wait window is unreadable as a list and immediate as a tally.
            tally = (wcnt == "-" ? "" : " [" wcnt "]")
            if (wcls == "terminal")
                # The TERMINAL branch. Ordering is deliberate and load-bearing:
                # read the status FIRST, clear the wait only as a consequence of
                # having read it. A terminal rc is not the same claim as "the
                # worker consumed the result" -- one recorded instance was rc=0
                # with 0 B on both streams, which async-run itself flags as
                # UNCORROBORATED -- so the byte counts are named here rather
                # than letting a bare rc read as a green light.
                printf "  - %s idle-orphan-async (waits=%s%s; these async-run jobs have ALREADY FINISHED — a status file exists for each, so this is not an orphan and there is nothing to poll for. Read `monitor/async-run.sh --status-line <token>` first and check the byte counts: %s. Once you have the result, clear the wait with `ng declare-no-wait asyncrun <token>`)\n", $1, kinds, tally, uncorr(wcnt)
            else if (wcls == "running")
                # RUNNING: at least one job is verifiably still alive by its
                # recorded (pid, pidstart). The do-not-clear guidance is exactly
                # right here and is unchanged; the extra clause only says WHY it
                # is right, so this window is distinguishable from one where
                # nothing could be verified at all (your-org/nexus-code#1292).
                printf "  - %s idle-orphan-async (waits=%s%s; a recorded job is still RUNNING — its pid and start-time both still match, so work is genuinely in flight. No resume mechanism — install a Monitor / background poller. The watcher resolves these waits and pastes the verdict; RESUME is the default, and a wait you have not confirmed dead must not be cleared. See skills/nexus.worker-defaults)\n", $1, kinds, tally
            else if (wcls == "skeptic-await")
                # your-org/nexus-code#1183. Every live wait here is a
                # `skeptic-channel.sh await`, which IS its own resume mechanism —
                # the loop wakes on the channel. The running arm below told the
                # operator to install a Monitor for a recorded command that is
                # already a poller, and acting on that is the one thing #1178
                # forbids: a stacked await SIGTERMs the older one, and the loser
                # leaves the window with NONE armed while believing it is parked.
                # NO APOSTROPHES IN THIS BLOCK (single-quoted awk string).
                printf "  - %s idle-orphan-async (waits=%s%s; this is a SKEPTIC AWAIT — `skeptic-channel.sh await` is itself the resume mechanism, so it is correctly ARMED, not orphaned. Do NOT install a second listener: a stacked await SIGTERMs the older one (your-org/nexus-code#1178) and the loser leaves the window with none armed while believing it is parked. Do nothing. To reach this arm the channel own `.await-owner` named a live await process and `.await-heartbeat` was within the hang threshold — a STALE await never lands here, it keeps the running advice)\n", $1, kinds, tally
            else if (wcls == "cancelled") {
                # CANCELLED ON REQUEST (your-org/nexus-code#1333). A cancel
                # marker is on disk and the process is gone — neither a failure
                # nor an unexplained death, and the classifier used to fuse it
                # with `died`, producing a byte-identical row for two states
                # whose operator responses are opposites.
                #
                # THE PROSE SPLITS ON c < n, AND THAT IS THE #1311 LESSON APPLIED
                # HERE RATHER THAN ONLY NEXT DOOR. The gate is an ALL-arm over
                # the UNION (`n_canc + n_term == n`), so it legitimately fires on
                # a MIXED set of terminal + cancelled waits — and a universal
                # sentence over that set is false for the terminal ones. Worse
                # than untidy: "an empty or short out/err is expected and is not
                # evidence of anything" is WRONG for a job that completed with a
                # real rc, and it contradicts the terminal arm own
                # UNCORROBORATED warning three arms up. The first version of this
                # arm shipped that sentence and was caught in review.
                # NO APOSTROPHES IN THIS BLOCK (single-quoted awk string).
                _cc = 0; _ct = 0; _cn = 0
                if (match(wcnt, /c=[0-9]+/)) _cc = substr(wcnt, RSTART+2, RLENGTH-2) + 0
                if (match(wcnt, /t=[0-9]+/)) _ct = substr(wcnt, RSTART+2, RLENGTH-2) + 0
                if (match(wcnt, /n=[0-9]+/)) _cn = substr(wcnt, RSTART+2, RLENGTH-2) + 0
                if (_cn > 0 && _cc > 0 && _cc < _cn)
                    printf "  - %s idle-orphan-async (waits=%s%s; %d of %d were CANCELLED ON REQUEST — a cancel marker is on disk and the process is gone, so for those an empty or short out/err is TRUNCATED BY DESIGN and is not evidence of anything. The other %d COMPLETED and have a real rc: read those with `monitor/async-run.sh --status-line <token>` and check the byte counts: %s. Nothing here is still running. Clear with `ng declare-no-wait asyncrun <token>`)\n", $1, kinds, tally, _cc, _cn, _ct, uncorr(wcnt)
                else
                    printf "  - %s idle-orphan-async (waits=%s%s; these jobs were CANCELLED ON REQUEST — a cancel marker is on disk and the process is gone. This is NOT an unexplained death and NOT a failure: output is TRUNCATED BY DESIGN at the point of the cancel, so an empty or short out/err is expected and is not evidence of anything. There is nothing to poll and nothing to wait for. Read `monitor/async-run.sh --status-line <token>` for who cancelled and when, then clear with `ng declare-no-wait asyncrun <token>`)\n", $1, kinds, tally
            }
            else if (wcls == "untracked") {
                # ANY-vs-EVERY (your-org/nexus-code#1311). The ARM fires on
                # `n_untr > 0`; the sentence asserted ALL. On a MIXED window that
                # told the operator to clear waits whose rc is sitting on disk,
                # unread — converting a readable result into an unread one, BY
                # INSTRUCTION. The counts are already computed and correct, so
                # the prose is now a function of THEM rather than of the arm that
                # fired. The homogeneous emit is unchanged and was always true.
                #
                # PROSE ONLY, and the REASON is the issue own argument, not the
                # existing assertion. #1311 prefers this over sending mixed
                # windows to `unresolved`: a mixed window is the common case, and
                # the generic arm loses the one thing the classifier newly knows.
                # Also `unresolved` prose is itself wrong there — it says "no
                # terminal status on disk" while t>0 waits have one.
                #
                # AN EARLIER DRAFT JUSTIFIED THIS BY CITING THE EXISTING
                # ASSERTION (a mixed list classifies `untracked`), AND THAT WAS
                # CIRCULAR. Provenance, by `git log -G` — `-S` is blind to a flip
                # because the occurrence count does not change:
                #   cbf61b0a 2026-09-01T18:01  +"a MIXED list … -> unresolved"
                #   002f1138 2026-09-01T22:38  -"… -> unresolved"  +"… -> untracked"
                # The assertion was WRITTEN as `unresolved` — exactly what #1311
                # proposes — and flipped 4.5h later by the commit that CREATED the
                # untracked class, in a block edit whose rationale argues only the
                # homogeneous case. It FROZE the behaviour; it did not decide it.
                # So it cannot be the reason, and the issue own argument is.
                #
                # RESOLVABLE = t + c (your-org/nexus-code#1333 coupling). Once
                # `cancelled` became its own state, a mixed window can carry
                # cancelled waits too, and those are just as resolvable as a
                # terminal one — both have positive evidence on disk.
                #
                # NO APOSTROPHES ANYWHERE IN THIS BLOCK: this awk program lives
                # inside a SINGLE-QUOTED bash string, and one apostrophe ends the
                # string and stops the file parsing.
                _nu = 0; _nt = 0; _nc = 0; _nn = 0
                if (match(wcnt, /u=[0-9]+/)) _nu = substr(wcnt, RSTART+2, RLENGTH-2) + 0
                if (match(wcnt, /t=[0-9]+/)) _nt = substr(wcnt, RSTART+2, RLENGTH-2) + 0
                if (match(wcnt, /c=[0-9]+/)) _nc = substr(wcnt, RSTART+2, RLENGTH-2) + 0
                if (match(wcnt, /n=[0-9]+/)) _nn = substr(wcnt, RSTART+2, RLENGTH-2) + 0
                if (_nn > 0 && _nu > 0 && _nu < _nn)
                    printf "  - %s idle-orphan-async (waits=%s%s; %d of %d waits are UNTRACKED — a nohup/slurm synthetic id with no recorded pid, start-time or status, unresolvable from the record by construction. The other %d have POSITIVE EVIDENCE on disk and CAN be resolved: read `monitor/async-run.sh --status-line <token>` for those FIRST and check the byte counts (%s). Only then confirm the untracked ones out-of-band and clear with `ng declare-no-wait <kind> <id>` — clearing a wait asserts only that nothing is still running, never what the job did. See skills/nexus.worker-defaults)\n", $1, kinds, tally, _nu, _nn, _nt + _nc, uncorr(wcnt)
                else
                    printf "  - %s idle-orphan-async (waits=%s%s; every wait here is UNTRACKED — a nohup/slurm synthetic id with no recorded pid, start-time or status, so it cannot be resolved from the record by construction and there is nothing to poll. Confirm out-of-band that the work is over, then clear with `ng declare-no-wait <kind> <id>`. See skills/nexus.worker-defaults)\n", $1, kinds, tally
            }
            else
                # UNRESOLVED: no status file AND no verifiable live process —
                # the `died` shape — plus truncated lists, non-asyncrun kinds and
                # every doubt. THIS is the population the warning exists for, and
                # separating it is the point: when most listed waits are stale,
                # the genuinely indeterminate ones become invisible among them.
                printf "  - %s idle-orphan-async (waits=%s%s; NOT verifiable — no terminal status on disk and no live process matching the recorded pid+start-time. No resume mechanism — install a Monitor / background poller. The watcher resolves these waits and pastes the verdict; RESUME is the default, and a wait you have not confirmed dead must not be cleared. See skills/nexus.worker-defaults)\n", $1, kinds, tally
        }
        $2 == "interrupted" {
            # stall-detection: last turn died to an API/model error
            # (StopFailure fired, NOT Stop) — claude is ALIVE, the box
            # is empty, no clean Stop ran. $4 = "<category>:<recovery>".
            # Recovery verb drives the operator action: paste resumes
            # in place (transient blip); respawn relaunches via
            # `--continue` (a config/conversation error re-fails on a
            # verbatim resend); operator needs a human (auth/model).
            split(($4 == "" ? "unknown:paste" : $4), tf, ":")
            cat = tf[1]; rec = tf[2]
            if (rec == "respawn")
                printf "  - %s interrupted %s — turn crashed (%s); a resume would re-fail, RESPAWN via `claude --continue` or fresh spawn\n", $1, fmt_age($3), cat
            else if (rec == "operator")
                printf "  - %s interrupted %s — turn crashed (%s); needs operator (credentials/model access), not a paste\n", $1, fmt_age($3), cat
            else
                printf "  - %s interrupted %s — turn crashed (%s, transient); process alive, PASTE a resume nudge to continue\n", $1, fmt_age($3), cat
        }
    '
    # Retained footer. Walks all retained rows in the transitions
    # output (list_idle_transitions only includes them when the
    # suppressed-set changed this cycle, so this naturally dedupes).
    printf '%s\n' "$transitions" | awk -F'\t' '
        BEGIN { n = 0; out = "" }
        $2 == "retained" && NF > 0 {
            reason = $4
            # Truncate to 40 chars (39 + …) so footer stays readable.
            if (length(reason) > 40) reason = substr(reason, 1, 39) "…"
            if (reason == "") reason = "(no reason)"
            n++
            entry = sprintf("%s (%s)", $1, reason)
            out = (out == "" ? entry : out ", " entry)
        }
        END {
            if (n > 0) printf "(%d retained windows suppressed: %s)\n", n, out
        }
    '
}

# ---- pending decisions (issue #129) -------------------------------------
#
# Workers spawned with `--settings monitor/worker-settings.json`
# write one JSON file per pending Claude Code notification to
# `$STATE_DIR/decisions/<window>.<fp>.json` via the
# `monitor/hooks/decision-emit.sh` handler. The orchestrator removes
# the file when it has answered the prompt (paste-decided or
# escalated); a sibling `<window>.<fp>.handled.json` is honoured as
# a terminal marker (audit-copy kept after answering).
#
# render_pending_decisions reads that directory each cycle and
# emits one operator-facing line per pending decision:
#
#   window=<W> fp=<FP> kind=<K> unresolved=<true|false>
#               prompt-excerpt=<first non-empty line>
#               file=<absolute path to the JSON>
#               ack=ng decision-ack <W> <FP>
#
# The `ack=` line is not decoration (your-org/nexus-code#790, defect 2).
# The ack this channel documented for a year was "remove the cited file",
# and against `idle_prompt` that is a NO-OP: the fingerprint is
# sha1(window | kind | message) and `idle_prompt`'s message is the
# constant "Claude is waiting for your input", so the fingerprint is a
# function of the window alone. Remove the file, stay idle 60s, and the
# hook writes back a byte-identical name. Measured on the live nexus:
# `civerdict.bb0f332f628a.json` removed at 15:41, present again at
# 16:09:32 with the same fingerprint; `guardgap.672915acaad8` acked three
# times. The reader could not tell "fired again because something
# changed" from "fired again because I deleted a file" — and neither
# could the writer.
#
# The durable ack already existed: `<w>.<fp>.handled.json`, honoured by
# BOTH the hook's write path and this reader. Nothing pointed at it. So
# the row now carries the verb, and `ng decision-ack` performs the
# tombstone move — the fix is to stop asking a human to type the correct
# rename, not to document the rename harder.
#
# Cooldown: re-emit when the fingerprint is new OR when
# DECISION_REEMIT_COOLDOWN_SECONDS (default 300) has elapsed since
# the prior emit of the same (window, fp). The cooldown stamp is a
# TSV at `$STATE_DIR/pending-decisions-emit-state.tsv` with rows
# `<window>\t<fp>\t<last_emit_epoch>`. Pruned in-place each cycle so
# only currently-existing decisions retain a row — once the
# orchestrator removes a file, the next cycle drops its row.
#
# Empty stdout when nothing is pending. Anything we'd return to the
# caller is also gated by the caller's compose_report (it only
# inserts the section when stdout is non-empty).

_decisions_dir() {
    printf '%s/decisions' "${STATE_DIR:-$(_ip_nostate_dir)}"
}

# ---- the pane gate (your-org/nexus-code#790, defect 1) ------------------
#
# A decision file records that a Notification FIRED. It does not record
# that the condition still HOLDS, and nothing rewrites it when the
# condition clears: the operator pastes an answer, the pane goes busy, and
# the file sits there re-surfacing every cooldown. Measured over one
# working session: ten consecutive `idle_prompt` rows, and the panes
# behind them read `working-background` (×3), `busy` (×3), `busy queued=1`
# (×1) and `autosuggest-only` (×3) — i.e. every row said "Claude is
# waiting for your input" about a pane that was not waiting for input.
#
# The discriminator already existed and was not being asked.
# `pane-state.sh` has classified these panes for a year; the emitter's
# only suppressions were `_openg_marked` and `_idle_skeptic_parked`,
# neither of which looks at the pane. So the gate is a READ of the
# existing classifier, not a new heuristic:
#
#   bk_decision_row_actionable <state> <queued>   (monitor/_bookkeeping.sh)
#
# DIRECTION OF ERROR — stated because a guard that silences everything is
# not an improvement over one that cries wolf. This gate errs LOUD at
# every seam:
#   * default-EMIT arm, so an unrecognised state surfaces;
#   * `unknown`/`empty` (the "could not tell" readings) surface;
#   * an unresolvable window index, an unreadable pane-state.sh, an empty
#     emit line — every failure path surfaces;
#   * `blocked` is not in the withhold set at all, so a pane genuinely
#     stuck on a permission modal keeps emitting. That is the negative
#     control, and test-pending-decisions.sh asserts it directly.
# What it buys is the seven of ten rows whose panes POSITIVELY asserted
# they were being driven forward already.
#
# COST, stated accurately (an earlier version of this comment claimed
# "normally zero forks per cycle" and that was optimistic — skeptic
# finding, #790). `pane-state.sh` forks `tmux capture-pane` plus a
# process-tree walk; this renderer runs at 10s. The gate is evaluated ONLY
# for rows that have already passed the cooldown check, which is what
# bounds it — but that is NOT the same as "rarely". A row the gate
# withholds keeps its previous cooldown stamp (see the withhold branch),
# so once past cooldown it is re-evaluated on EVERY 10s cycle for as long
# as its pane stays busy. The real bound is one layer down: the call goes
# through `_idle_pane_state_line`, the shared-recording chokepoint (#562),
# whose recordings are served for MONITOR_PANE_CACHE_TTL_SECONDS (90s by
# default). So the worst case is ~1 fork per window per 90s, not per 10s —
# bounded by the cache, not by the cooldown.
MONITOR_PENDING_PANE_GATE="${MONITOR_PENDING_PANE_GATE:-true}"

# _pd_resolve_window_index <window-name> <live-rows>
#
# THREE-STATE, per the contract `test-tmux-window-resolver.sh` D1 enforces:
#   rc 0  resolved — the index is on stdout
#   rc 1  NOT PRESENT — the snapshot was read and this name is not in it
#   rc 3  COULD NOT LOOK — there was no snapshot to read
#
# The first draft was two-valued (empty stdout for both failure arms) and
# named `_pd_window_index`, which matches NEITHER discovery axis of that
# guard — so a conflating resolver would have sat in this file permanently
# invisible to the manifest. Splitting the arms and renaming to the
# conventional `*resolve*window*` shape is the point: the guard exists to
# stop exactly that, and hiding from it by accident is no better than
# hiding from it on purpose.
#
# Both failure arms currently lead the caller to EMIT, so the split changes
# no behaviour today. It is still worth having: "tmux told me this window
# is gone" and "I never got to ask tmux" are different facts, and the next
# consumer of this helper must not have to rediscover that they were merged.
# <live-rows> holds `<name>|<index>` rows — see the delimiter note above.
_pd_resolve_window_index() {
    local want="$1" live="$2"
    [[ -n "$live" ]] || return 3          # no snapshot: could not look
    [[ -n "$want" ]] || return 1
    local idx
    idx=$(awk -F'|' -v w="$want" '$1 == w { print $2; exit }' <<<"$live")
    [[ -n "$idx" ]] || return 1           # snapshot read, name absent
    printf '%s' "$idx"
    return 0
}

# _pd_row_actionable <window-name> <live-tsv>
#   rc 0 → emit (including every could-not-tell path)
#   rc 1 → withhold; $BK_ERR carries the reason.
# Fail-open is the whole contract here: see the direction note above.
_pd_row_actionable() {
    local win="$1" live="$2"
    [[ "${MONITOR_PENDING_PANE_GATE:-true}" == "true" ]] || return 0
    # The predicate lives in _bookkeeping.sh so the ruling is one
    # default-arm decision shared with the kill/dead gates, and so the
    # manifest test can drive it directly. Not sourced (a test may source
    # this file alone) ⇒ no gate.
    declare -F bk_decision_row_actionable >/dev/null 2>&1 || return 0
    local idx line state queued
    # BOTH failure arms of the three-state resolver lead here to EMIT, and
    # that is deliberate rather than a conflation surviving the split.
    # rc 3 (could not look) is an indeterminate reading, and the whole
    # polarity of this gate is that indeterminacy surfaces. rc 1 (window
    # genuinely absent from tmux) means the decision is unanswerable
    # in-pane — but the dead-window SKIP above already dropped that row on
    # its own authority, so reaching here with rc 1 means the skip is
    # disabled by its knob, and silently re-suppressing what the operator
    # just switched off would be its own defect.
    idx=$(_pd_resolve_window_index "$win" "$live") || return 0
    line=$(_idle_pane_state_line "$idx" "$win")
    [[ -n "$line" ]] || return 0                # probe said nothing → emit
    state=$(_idle_pane_line_field "$line" state)
    [[ -n "$state" ]] || return 0               # malformed line → emit
    queued=""
    [[ "$line" == *" queued=1"* ]] && queued=1
    bk_decision_row_actionable "$state" "$queued"
}

# ---- reaping dead windows' decisions (nexus-code#790, defect 3) ---------
#
# `ng retire-window` already prunes `decisions/<w>.*` — `prefix:decisions/{w}.`
# has been in BK_RETIRE_SURFACES since #602. The leak is every OTHER way a
# window ends: an agent that exits on its own, a window closed by hand, a
# session that churns. None of those runs the teardown, and nothing else
# ever looks. Measured on the live nexus while writing this: 19 decision
# files on disk, 19 for windows absent from tmux, the oldest 11 hours old,
# and not one of their windows carried a `window-close` action-log entry —
# so the filed premise ("nothing removes a window's decisions when it is
# retired") is not quite right, and the accurate one is worse: the
# retirement path is fine and the un-retired path is unbounded.
#
# The dead-window emit SKIP added earlier keeps those rows out of the
# operator's face, which is why this went unnoticed — but skipping is not
# reaping. Two costs remain. The directory grows without bound, so `ls` on
# it (a thing an orchestrator does when reconstructing state) reports
# mostly fiction. And a window name is REUSED: spawn a worker into a name
# a dead one held and its predecessor's decisions become live rows again,
# attributed to an agent that never fired them.
#
# Safety. Reaping is gated on the SAME non-empty live-window snapshot the
# emit skip uses (an empty query is tmux being transient, never evidence
# of death), plus a minimum age so a window that tmux failed to list for
# one cycle cannot lose state it is still using. Decisions are not the
# audit trail — the action log and the reports corpus are, and
# BK_RETIRE_SURFACES already excludes those two by name while including
# this directory. Reaping here therefore applies the policy that already
# governs the retirement path to the deaths that never reach it.
MONITOR_PENDING_REAP_DEAD_WINDOWS="${MONITOR_PENDING_REAP_DEAD_WINDOWS:-true}"
MONITOR_PENDING_REAP_MIN_AGE_SECONDS="${MONITOR_PENDING_REAP_MIN_AGE_SECONDS:-900}"

# _reap_dead_window_decisions <dir> <live-names> <now>
# Prints the number of files removed. No-op on an empty live set.
_reap_dead_window_decisions() {
    local dir="$1" live="$2" now="$3"
    local reaped=0 failed=0
    [[ "${MONITOR_PENDING_REAP_DEAD_WINDOWS:-true}" == "true" ]] || { printf '0'; return 0; }
    [[ -d "$dir" && -n "$live" ]] || { printf '0'; return 0; }
    local min_age="${MONITOR_PENDING_REAP_MIN_AGE_SECONDS:-900}"
    [[ "$min_age" =~ ^[0-9]+$ ]] || min_age=900
    local _reap_restore_nullglob
    _reap_restore_nullglob=$(shopt -p nullglob)
    shopt -s nullglob 2>/dev/null
    local f bn win mtime
    # Both `<w>.<fp>.json` and `<w>.<fp>.handled.json` go: a tombstone for
    # a window that no longer exists suppresses nothing.
    for f in "$dir"/*.json; do
        [[ -e "$f" ]] || continue
        bn=$(basename "$f")
        # Window name = everything before the final `.<12hex>[.handled].json`.
        if [[ "$bn" =~ ^(.+)\.[0-9a-f]{12}(\.handled)?\.json$ ]]; then
            win="${BASH_REMATCH[1]}"
        else
            continue        # malformed name: leave it for a human to look at
        fi
        grep -qxF -- "$win" <<<"$live" && continue      # window is live
        mtime=$(date +%s -r "$f" 2>/dev/null || echo 0)
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        (( mtime > 0 )) || continue
        (( now - mtime >= min_age )) || continue
        # Do NOT swallow the removal's failure (skeptic finding, #790). The
        # first draft was `rm -f … 2>/dev/null && reaped=$(( reaped + 1 ))`
        # with the count discarded by the caller, so a reap that could never
        # remove anything — a read-only state dir, a permissions change, an
        # immutable bit — looked exactly like a reap with nothing to do. That
        # is silence-as-a-proxy-for-success, the defect class this whole
        # change is about, reproduced inside the change. The directory would
        # grow without bound and the only symptom would be its absence of
        # symptoms.
        if rm -f "$f" 2>/dev/null && [[ ! -e "$f" ]]; then
            reaped=$(( reaped + 1 ))
        else
            failed=$(( failed + 1 ))
        fi
    done
    eval "$_reap_restore_nullglob"
    # stderr, never stdout: stdout of the enclosing renderer IS the operator
    # emit channel, and a diagnostic there would be parsed as a decision row.
    # The watcher captures stderr into monitor/.state/watcher.log.
    if (( failed > 0 )); then
        printf 'render_pending_decisions: reap FAILED to remove %d dead-window decision file(s) in %s — the directory will grow without bound; check permissions\n' \
            "$failed" "$dir" >&2
    fi
    printf '%s' "$reaped"
}

_pending_decisions_emit_state_path() {
    printf '%s/pending-decisions-emit-state.tsv' "${STATE_DIR:-$(_ip_nostate_dir)}"
}

# Default cooldown — env overrideable. The 300s figure matches the
# operator's spec; tune only if a specific decision class observably
# needs faster re-pokes.
_decision_reemit_cooldown_seconds() {
    local cd="${DECISION_REEMIT_COOLDOWN_SECONDS:-300}"
    [[ "$cd" =~ ^[0-9]+$ ]] || cd=300
    printf '%s' "$cd"
}

render_pending_decisions() {
    local dir state_file
    dir=$(_decisions_dir)
    state_file=$(_pending_decisions_emit_state_path)
    [[ -d "$dir" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local now cooldown
    now=$(date +%s)
    cooldown=$(_decision_reemit_cooldown_seconds)

    # Dead-window skip (watcher-emit-noise, Class 3). A decision is only
    # actionable in a LIVE window — the operator answers the prompt IN the
    # window. A decision file for a killed window is unactionable garbage
    # that re-nags the orchestrator every cooldown (observed: 2026-07-21
    # 00:33/00:34 pubfork-skills[-skeptic] idle_prompt rows, both windows
    # kill-window'd ~00:34 — the skeptic-park suppression below had already
    # lapsed because the skeptic window was gone). Snapshot the live window
    # set once so rows for absent windows drop from both the emit and the
    # cooldown state. Empty query (tmux transient) ⇒ pass-through so a real
    # decision is never lost. Knob-guarded, default on.
    #
    # One snapshot, three consumers (#790): the dead-window emit skip
    # below, the dead-window REAP, and the pane gate's name→index lookup.
    # `#{window_index}` rides along in a second field so the gate does not
    # need a second tmux call — the emit skip reads field 1 only, exactly
    # as it did when this was a bare name list.
    #
    # Delimiter is `|`, matching `_idle_list_worker_windows` above, and it
    # is NOT a style choice. The first draft used a literal TAB and
    # `test-tmux-window-resolver.sh` F1/F3 caught it: in a non-UTF-8
    # locale with `$TMUX` unset, tmux REWRITES that byte to `_`, the row
    # never splits, and the consumer reads one mangled field instead of
    # two. Here that failure would have been silent AND self-concealing —
    # no index parses, so the pane gate fails open on every row and the
    # channel quietly reverts to the pre-#790 behaviour this whole change
    # exists to fix, in exactly the locales nobody tests. `|` is
    # printable, so no locale rewrites it, and `validate_window_name`
    # forbids it inside a minted window name, so it cannot appear in
    # field 1.
    local _pd_live="" _pd_live_tsv="" _pd_skip_dead="${MONITOR_PENDING_SKIP_DEAD_WINDOWS:-true}"
    if [[ "$_pd_skip_dead" == "true" || "${MONITOR_PENDING_PANE_GATE:-true}" == "true" \
          || "${MONITOR_PENDING_REAP_DEAD_WINDOWS:-true}" == "true" ]]; then
        _pd_live_tsv=$(tmux list-windows -F '#{window_name}|#{window_index}' 2>/dev/null || true)
        [[ -n "$_pd_live_tsv" ]] && _pd_live=$(cut -d'|' -f1 <<<"$_pd_live_tsv")
    fi
    # The emit skip is knob-scoped, but the snapshot above is now shared,
    # so re-blank the name list when only the other two consumers asked
    # for it — otherwise turning skip_dead_windows off would stop
    # suppressing dead rows *and* keep suppressing them.
    [[ "$_pd_skip_dead" == "true" ]] || _pd_live=""

    # Reap before the scan, so a file removed here never produces a row.
    _reap_dead_window_decisions "$dir" "$(cut -d'|' -f1 <<<"$_pd_live_tsv")" "$now" >/dev/null

    # Gather current pending set into a TSV: window\tfp\tfile\tkind\texcerpt\tunresolved
    # We skip *.handled.json tombstones — those are terminal.
    local current=""
    local f bn win_fp win fp kind excerpt unresolved
    # Ambient-shell-state independence (issue #721). Two distinct properties
    # here, both MEASURED rather than argued — see test-pending-decisions.sh
    # "Test 14".
    #
    #  (a) The scan must not enter its body for the UNEXPANDED literal when
    #      `$dir` holds no `*.json`. `nullglob` is one way; `[[ -e "$f" ]]` is
    #      the structural backstop every sibling loop in this repo already
    #      carries (`_requests.sh:180,196`, `remote-enroll.sh:470`,
    #      `paste-followup.sh:415`) and it holds against ANY ambient option,
    #      not `nullglob` in particular. Without either, the loop stats and
    #      jq-forks a nonexistent path twice per cycle; the OUTPUT still came
    #      out right, but only because `[[ -n "$win" ]]` below happens to
    #      reject the phantom row — an emergent guarantee, which is exactly
    #      why the deletion mutant survived the whole suite.
    #
    #  (b) The caller's `nullglob` must survive the call. The tail used to be
    #      an unconditional `shopt -u`, which turns the option OFF for a
    #      caller that had it ON. Inert today — both watcher call sites
    #      isolate in a subshell (`_run_bounded`'s `( … ) &` at main.sh:1177,
    #      and `_v2_task_pending_decisions`' pipeline LHS at main.sh:3243) —
    #      so this closes a latent hazard rather than a live bug. Save and
    #      restore, as `main.sh:2272,2399` already does.
    local _rpd_restore_nullglob
    _rpd_restore_nullglob=$(shopt -p nullglob)
    shopt -s nullglob 2>/dev/null
    for f in "$dir"/*.json; do
        # Structural no-match guard — see (a) above. Also skips a file that
        # vanished between glob expansion and this iteration.
        [[ -e "$f" ]] || continue
        case "$f" in
            *.handled.json) continue ;;
        esac
        # Tombstone SIBLING gate (your-org/nexus-code#790, found while
        # fixing it). `decision-emit.sh` treats `<w>.<fp>.handled.json` as
        # terminal on the WRITE path and has since #129; this reader only
        # ever skipped the tombstone FILE, never a live `<fp>.json`
        # standing next to one. The two halves of one contract disagreed,
        # and the disagreement is load-bearing: the tombstone recipe in
        # `skills/nexus.window-cleanup` ("Tombstone rule — every
        # resurfaced `idle_prompt` decision MUST be acked") writes the
        # `.handled.json` with `jq -n … > …` and leaves the original
        # `.json` in place, so an orchestrator following the documented
        # remedy EXACTLY got no suppression at all — the row kept
        # re-emitting every cooldown and the tombstone did nothing but
        # stop future hook writes. Measured on dev@16728e7 and on this
        # branch before this line existed.
        #
        # `ng decision-ack` renames rather than copies, so it never
        # produces this shape — but every tombstone written by hand over
        # the life of that recipe did, and honouring the sibling here is
        # what makes those acks retroactively real.
        [[ -e "${f%.json}.handled.json" ]] && continue
        # Filename convention: <window>.<fp>.json. Split on the LAST
        # dot before .json to tolerate window names with dots (the
        # CLAUDE.md gotcha says workspace conventions disallow dots
        # in window names, but be defensive — fp is 12 hex chars,
        # window is everything before the final `.fp.json` token).
        bn=$(basename "$f" .json)
        # Split window.fp by removing the final `.<12hex>` segment.
        # Falls through to whole basename + empty fp on malformed names.
        if [[ "$bn" =~ ^(.+)\.([0-9a-f]{12})$ ]]; then
            win="${BASH_REMATCH[1]}"
            fp="${BASH_REMATCH[2]}"
        else
            # Defensive fallback; read window/fp out of the JSON itself.
            win=$(jq -r '.window // ""' "$f" 2>/dev/null)
            fp=$(jq -r '.fingerprint // ""' "$f" 2>/dev/null)
            [[ -n "$win" ]] || continue
            [[ -n "$fp"  ]] || continue
        fi
        # Read kind / excerpt / unresolved from the JSON. The excerpt
        # is the first non-empty line of `prompt_excerpt`.
        kind=$(jq -r '.kind // "unknown"' "$f" 2>/dev/null)
        excerpt=$(jq -r '.prompt_excerpt // ""' "$f" 2>/dev/null \
                  | awk 'NF > 0 { print; exit }')
        # Truncate excerpt at 160 chars to keep the emit line readable.
        if (( ${#excerpt} > 160 )); then
            excerpt="${excerpt:0:157}…"
        fi
        # RESOLVED rows are not pending decisions (your-org/nexus-code#824).
        # The Stop hook stamps `resolved: true` on a `permission_prompt` at
        # turn-end, because a permission modal suspends the turn and so
        # `Stop` is positive evidence the modal is gone. Such a file stays
        # on disk as the audit record that the prompt HAPPENED; it is not an
        # action item, and re-emitting it every cooldown for hours is what
        # `#824` measured (13 firings on one window, byte-identical pane
        # content throughout). A genuine re-fire of the same fingerprint
        # rewrites the file wholesale via `decision-emit.sh`, with no
        # `resolved` key — so this is not permanent suppression.
        if jq -e '.resolved == true' "$f" >/dev/null 2>&1; then
            continue
        fi
        unresolved=$(jq -r 'if .unresolved == true then "true" else "false" end' "$f" 2>/dev/null)
        current+="$win"$'\t'"$fp"$'\t'"$f"$'\t'"$kind"$'\t'"$excerpt"$'\t'"$unresolved"$'\n'
    done
    eval "$_rpd_restore_nullglob"   # NOT `shopt -u` — see (b) above.

    [[ -n "$current" ]] || {
        # No pending decisions — clear stale state so a future row's
        # cooldown starts fresh.
        : > "$state_file"
        return 0
    }

    # Load prior emit state into associative array.
    declare -A prev_emit
    if [[ -f "$state_file" ]]; then
        while IFS=$'\t' read -r pw pfp pts; do
            [[ -n "$pw" ]] || continue
            prev_emit["$pw"$'\t'"$pfp"]="$pts"
        done < "$state_file"
    fi

    # Compute which rows to emit (new fp OR cooldown elapsed) and
    # write the next state file in the same pass.
    local emit_lines=""
    local next_state=""
    while IFS=$'\t' read -r win fp file kind excerpt unresolved; do
        [[ -n "$win" ]] || continue
        # Dead-window skip (watcher-emit-noise, Class 3). Drop the row —
        # from both the emit and the cooldown state — when its window is
        # no longer live in tmux (see the snapshot rationale above). A
        # genuine LIVE parked worker whose verdict posts still resurfaces
        # (window present, marker cleared); only the killed-window tail is
        # suppressed. Pass-through when the live query was empty.
        if [[ -n "$_pd_live" ]] && ! grep -qxF -- "$win" <<<"$_pd_live"; then
            continue
        fi
        # Operator-engaged suppression (issues #196, #201). The
        # `idle_prompt` pings of a window the operator drives are
        # ordinary turn-end notifications, not decisions to ack — drop
        # the row from both the emit AND the cooldown state, leaving
        # the decision FILE in place. Suppression spans the away
        # phase too (the close-reminder is that phase's surface); if
        # the mark is invalidated (newer wrap-up/spawn) with the file
        # still present, the next cycle treats it as brand-new and
        # surfaces it — nothing is permanently muted. Other kinds
        # (permission_prompt, …) surface regardless.
        #
        # Same suppression for a skeptic-parked window
        # (emit-gate-recover): its await loop re-fires the SAME
        # idle_prompt fingerprint on every poll turn-end, and the
        # park is by definition not an action item ("waiting on the
        # skeptic; exempt from idle/close"). Without this, the
        # standing decision re-nagged every cooldown period for the
        # whole park — half of the 2026-07-06 A/B resurface flood.
        # When the park ends with the file still present, the next
        # cycle surfaces it as brand-new — nothing permanently muted.
        if [[ "$kind" == "idle_prompt" ]] \
           && { _openg_marked "$win" || _idle_skeptic_parked "$win" "$now"; }; then
            continue
        fi
        local key="$win"$'\t'"$fp"
        local last="${prev_emit[$key]:-}"
        local should_emit=0 last_emit_ts="$now"
        if [[ -z "$last" ]]; then
            # Brand-new (window, fp): emit.
            should_emit=1
        else
            # Cooldown check. Last emit recorded; re-emit only if
            # cooldown has elapsed.
            if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last >= cooldown )); then
                should_emit=1
            else
                last_emit_ts="$last"
            fi
        fi
        # Pane gate (#790 defect 1). Evaluated LAST, and only for a row
        # that would otherwise print, so the pane-state fork is paid for
        # at most once per emitted row rather than once per file per 10s
        # cycle. `blocked` passes; `busy`/`working-*`/`user-typing` and
        # any `queued=1` pane do not. See the direction-of-error note at
        # `_pd_row_actionable`.
        if (( should_emit == 1 )) && ! _pd_row_actionable "$win" "$_pd_live_tsv"; then
            should_emit=0
            if [[ -z "$last" ]]; then
                # Never emitted before: keep the row OUT of the cooldown
                # state so it fires the instant the pane stops asserting
                # otherwise, instead of being made to wait a full cooldown
                # for a suppression that was never an emit.
                continue
            fi
            # Already emitted once: hold the previous stamp so the clock
            # keeps running. A pane that flips busy/idle every few seconds
            # then re-emits on the cooldown boundary, not on every flip —
            # withholding must not become its own noise source.
            last_emit_ts="$last"
        fi
        if (( should_emit == 1 )); then
            emit_lines+="window=$win fp=$fp kind=$kind unresolved=$unresolved"$'\n'
            emit_lines+="    prompt-excerpt=$excerpt"$'\n'
            emit_lines+="    file=$file"$'\n'
            emit_lines+="    ack=ng decision-ack $win $fp   (durable; \`rm\` does NOT stick)"$'\n'
        fi
        next_state+="$win"$'\t'"$fp"$'\t'"$last_emit_ts"$'\n'
    done <<<"$current"

    # Persist next state (only currently-present (window,fp) pairs).
    printf '%s' "$next_state" > "$state_file"

    # Emit.
    if [[ -n "$emit_lines" ]]; then
        printf '%s' "$emit_lines"
    fi
}
