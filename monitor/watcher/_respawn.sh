#!/usr/bin/env bash
# Shared orchestrator-respawn primitives.
#
# Two sites in the watcher recover the orchestrator by spawning a fresh
# claude in a tmux window:
#
#   - monitor/watcher/main.sh respawn_agent          target window missing
#                                                    for >= AGENT_MISSING_
#                                                    RESPAWN_DELAY polls
#   - monitor/watcher/spawn-fresh-orchestrator.sh    target alive but
#                                                    unresponsive to the
#                                                    watcher's pastes
#
# PR #158 made `claude --continue` the default for the unresponsive
# path; PR #161 unified the two paths through this helper. PR #177
# (issue #176) made the default deterministic via the session-id pin
# (`--resume <pinned-sid>`). Issue #200 (this change) hardens the
# degradation: when the pin can't identify a session the helper now
# spawns COLD instead of falling back to `--continue` (which grabs the
# arbitrary freshest jsonl — the footgun behind the 2026-05-29
# second-death). Single surface for: resume-mode choice, --settings
# handling, dialog dismissal, readiness probe, post-paste verify +
# Enter retry.
#
# Keep this file side-effect-free at source time: only function
# definitions. Callers own logging, cooldowns, action-log writes,
# and any slow-grind / crash-loop counters tied to their trigger axis.

# Bash's `time` builtin in older versions doesn't accept fractional
# sleeps; the readiness probe needs sub-second polling. Both helpers
# below rely on /bin/sleep, which does.

# Temp-file dir for self-deleting `/tmp/nexus-respawn-*` launcher
# files. Override via $RESPAWN_TMPDIR. Production sticks with /tmp
# (single watcher process, no contention). Test harnesses set this
# to a per-test workdir so the parallel CI runner (--jobs 2) can't
# race two tests' glob-inspection of the same prefix — without the
# override, two concurrent invocations both write into /tmp and
# either test's "find my new launcher" diff picks up the other's
# file, producing intermittent assertion failures on the launcher
# body. See PR #166 CI flake; fix tracked in the same commit.
# Directory this file lives in, resolved at SOURCE time. Needed to locate
# monitor/guard-block.sh.in — the shim-guard template shared with
# spawn-worker.sh. An assignment, not an action: the side-effect-free
# contract above is about spawning/logging, not about knowing where you are.
_respawn_dir=${_respawn_dir:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)}

# Dead-pane paste guard (#745). Sourced EXPLICITLY rather than relied on
# transitively from main.sh: this module is also sourced standalone by
# test-respawn.sh and by entry.sh, and a missing function is rc 127 — which
# reads as "not dead" and silently restores a hazard that kills the tmux
# SERVER. Fail LOUD instead.
# shellcheck source=../_pane-live.sh
[[ -r "$_respawn_dir/../_pane-live.sh" ]] && source "$_respawn_dir/../_pane-live.sh"
# Window-selection restore across the respawn (your-org/nexus-code#1528).
# Sourced explicitly for the same reason as `_pane-live.sh`: this module is
# sourced standalone by suites and by entry.sh. UNLIKE the dead-pane guard it
# is COSMETIC, so a missing helper disables the restore rather than refusing
# anything — `_respawn_spawn_window` checks `declare -F` before calling it.
# shellcheck source=../_tmux-window.sh
[[ -r "$_respawn_dir/../_tmux-window.sh" ]] && source "$_respawn_dir/../_tmux-window.sh"
# THE confirmed-delivery primitive (your-org/nexus-code#1591), which holds the
# tree's one `tmux paste-buffer`. Explicit for the same reason as the two above;
# quiet at load, LOUD at use — `_respawn_paste_prompt_file` refuses to paste
# when `pd_paste_file` is not defined, rather than hand-rolling a second site.
# shellcheck source=../_paste-deliver.sh
[[ -r "$_respawn_dir/../_paste-deliver.sh" ]] && source "$_respawn_dir/../_paste-deliver.sh"
# Where Claude Code transcripts live (your-org/nexus-code#1720): the resume
# decider and the target-absent liveness veto look under EVERY root
# `cc_transcript_roots` prints — $CLAUDE_CONFIG_DIR/projects as well as
# $HOME/.claude/projects — never at a hardcoded `$HOME/.claude/projects`.
# shellcheck source=../_cc_transcript_roots.sh
[[ -r "$_respawn_dir/../_cc_transcript_roots.sh" ]] && source "$_respawn_dir/../_cc_transcript_roots.sh"
if ! declare -F cc_transcript_roots >/dev/null 2>&1; then
    # Partial tree (a fixture that copied this file without monitor/): the
    # same roots in the same order, without the realpath dedup — which only
    # saves a repeated stat, since every caller asks "found under ANY root".
    cc_transcript_roots() {
        [[ -n "${NEXUS_CC_HOME:-}" ]]     && printf '%s\n' "$NEXUS_CC_HOME/projects"
        [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] && printf '%s\n' "$CLAUDE_CONFIG_DIR/projects"
        [[ -n "${1:-${HOME:-}}" ]]        && printf '%s\n' "${1:-$HOME}/.claude/projects"
        return 0
    }
fi
if ! declare -F _tmux_pane_is_dead >/dev/null 2>&1; then
    # FAIL-CLOSED FALLBACK (#745). Without the real predicate we cannot
    # tell a live pane from a corpse, and a paste into a corpse kills the
    # tmux SERVER — so every paste refuses, loudly, at the moment it is
    # attempted.
    #
    # Deliberately NOT an `exit`/`return` at load time. The first cut
    # refused to LOAD, and CI showed why that is wrong: several fixtures
    # build partial trees from ENUMERATED copy lists, so the file is
    # simply absent there, and four unrelated suites died on modules
    # they never paste from. A missing paste guard must stop PASTES, not
    # module loading. Quiet at load, loud at use: the noise belongs where
    # the hazard is.
    _tmux_pane_is_dead() {
        printf '%s: _pane-live.sh unavailable — cannot prove %q is a live pane, refusing to paste (your-org/nexus-code#745: a paste into a dead pane kills the tmux server)\n' \
            "${BASH_SOURCE[1]##*/}" "${1:-?}" >&2
        return 0
    }
fi

_respawn_tmpdir() {
    printf '%s' "${RESPAWN_TMPDIR:-/tmp}"
}

# _respawn_pid_tree_is_orchestrator <pid> [<max_depth>]
#
# Returns 0 iff <pid> or any descendant (bounded BFS, default depth 3)
# carries `NEXUS_IS_ORCHESTRATOR=1` in its environment. Every
# orchestrator spawn path (entry.sh cold start, _respawn_compose_launcher,
# spawn-fresh-orchestrator.sh) exports that marker into the claude
# process's environment, so it positively identifies a live
# orchestrator process regardless of what its tmux window is named.
#
# Linux-only mechanism (/proc/<pid>/environ); on hosts where /proc is
# unavailable or unreadable the function returns 1 (no match) and
# callers degrade to their other signals. Child discovery uses
# `pgrep -P <pid>` — PID-scoped, per the no-mass-kill rule
# (monitor/cc-harness/lint-no-mass-kill.sh).
# Capture-then-match, never `tr … | grep -q` (your-org/nexus-code#622).
# When this file is sourced into a shell that has enabled the
# pipe-failure option, `grep -q` exiting on a match before `tr` has
# finished writing makes `tr` take SIGPIPE and inverts the pipeline's
# verdict to a FALSE NEGATIVE at the moment it was true.
#
# FULL explanation — the 4 KB stdio boundary, why it is NOT the 64 KB
# pipe capacity, and the position-dependent rate — lives on
# `_nexus_pid_tree_has_env_marker` in `_lib.sh`, deliberately not
# repeated here (see the inheritance note below).
#
# ---------------------------------------------------------------------
# INHERITANCE, re-examined — the question `test-tmux-lookup-sigpipe.sh`
# asks, answered here so the next person does not have to re-derive it.
#
# That guard greps THIS file for the pipe-failure option's NAME and
# fails if it appears, to assert this helper still INHERITS the caller's
# setting rather than establishing its own. It fired on the #622 fix
# below — not because the fix set anything, but because the explanatory
# comment MENTIONED the option by name. This file sets no shell options
# at all; `grep -n '^[[:space:]]*set -' _respawn.sh` is empty, and it
# was empty before the fix too.
#
# Q: does `_respawn.sh` still inherit the caller's setting?
# A: YES, unchanged. It sets no options; sourcing it into `main.sh` /
#    `svc.sh` leaves their own `set -uo …` options in force, exactly
#    as before. The guard's premise still holds.
#
# Q: is inheriting still CORRECT now that the probes changed?
# A: Yes, and it now matters LESS, which is the point of the change.
#    The old `tr … | grep -q` form was correct ONLY with the option
#    off — inheriting it is what made the probe return false negatives.
#    The capture-then-match form has no pipeline, so it is correct
#    under EITHER setting. This helper therefore no longer depends on
#    which way it inherits, and a future caller that enables the option
#    cannot silently invert these probes.
#
# The token is kept out of this file rather than widening the guard
# (the `#671` precedent: remove the flagged dependency, do not relax
# the check that flagged it). Single-sourcing the explanation in
# `_lib.sh` is better practice anyway.
# ---------------------------------------------------------------------
_respawn_pid_tree_is_orchestrator() {
    local pid="$1" depth="${2:-3}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    local _env_data
    if [[ -r "/proc/$pid/environ" ]]; then
        # `{ …; } 2>/dev/null` — redirection ORDER (your-org/nexus-code#1305).
        _env_data=$( { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null ) || _env_data=""
        if [[ -n "$_env_data" ]] && grep -qxF 'NEXUS_IS_ORCHESTRATOR=1' <<<"$_env_data"; then
            return 0
        fi
    fi
    (( depth <= 0 )) && return 1
    local child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        if _respawn_pid_tree_is_orchestrator "$child" $(( depth - 1 )); then
            return 0
        fi
    done
    return 1
}

# _respawn_pid_tree_orchestrator_sid <pid> [<max_depth>]
#
# For the first process in <pid>'s tree (bounded BFS, default depth 3)
# that carries NEXUS_IS_ORCHESTRATOR=1, print its SESSION ID and
# return 0; return 1 when no orchestrator-marked process exists. The
# sid sources, in order:
#
#   1. NEXUS_ORCH_SESSION_ID in the process environment — exported by
#      _respawn_compose_launcher since the issue-#203 revision, so
#      every watcher-spawned orchestrator self-identifies.
#   2. The argv value following `--session-id` / `--resume` — covers
#      orchestrators spawned before the env marker existed. Exact
#      argv-slot matches only, so prompt text quoting these flags
#      (one big argv element) can never false-positive.
#
# An orchestrator-marked process with NEITHER source prints an empty
# sid (rc still 0): "orchestrator, identity unknown" — callers must
# treat unknown as legitimate (conservative).
_respawn_pid_tree_orchestrator_sid() {
    local pid="$1" depth="${2:-3}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    local uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    # Capture the environ ONCE, then match against it — same #622
    # reasoning as the two probes above. The `sed … | head -n 1` here
    # is the same shape a second time: `head` exits after one line and
    # SIGPIPEs its upstream, so with the caller's pipe-failure option
    # enabled the status is 141 even when the value was extracted fine.
    local _env_data=""
    # `{ …; } 2>/dev/null` — redirection ORDER (your-org/nexus-code#1305). The
    # outer brace here belongs to the `&&` arm, not to the redirection: the
    # `2>/dev/null` still sits INSIDE it and still lands after the `<`. A first
    # pass over this file scored the line CLEAN for exactly that reason and the
    # awk classifier disagreed — which is why the predicate is the artefact and
    # a hand sweep is not.
    [[ -r "/proc/$pid/environ" ]] \
        && { _env_data=$( { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null ) || _env_data=""; }
    if [[ -n "$_env_data" ]] && grep -qxF 'NEXUS_IS_ORCHESTRATOR=1' <<<"$_env_data"; then
        local sid
        sid=$(sed -n 's/^NEXUS_ORCH_SESSION_ID=//p' <<<"$_env_data" | head -n 1)
        if [[ ! "$sid" =~ $uuid_re ]]; then
            sid=""
            local -a argv=()
            local arg
            # `{ …; } 2>/dev/null` — redirection ORDER (your-org/nexus-code#1305).
            { while IFS= read -r -d '' arg; do argv+=("$arg"); done \
                < "/proc/$pid/cmdline"; } 2>/dev/null
            local i
            for (( i = 0; i + 1 < ${#argv[@]}; i++ )); do
                case "${argv[i]}" in
                    --session-id|--resume)
                        if [[ "${argv[i+1]}" =~ $uuid_re ]]; then
                            sid="${argv[i+1]}"
                            break
                        fi
                        ;;
                esac
            done
        fi
        printf '%s' "$sid"
        return 0
    fi
    (( depth <= 0 )) && return 1
    local child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        if _respawn_pid_tree_orchestrator_sid "$child" $(( depth - 1 )); then
            return 0
        fi
    done
    return 1
}

# _respawn_read_pin_sid
#
# Print the pinned orchestrator session-id (uuid-validated) from
# ORCH_PIN_FILE / $NEXUS_ROOT/monitor/.state/orchestrator-session-id,
# or nothing when absent/malformed. Always rc 0.
_respawn_read_pin_sid() {
    local pin="${ORCH_PIN_FILE:-}"
    [[ -z "$pin" && -n "${NEXUS_ROOT:-}" ]] && pin="$NEXUS_ROOT/monitor/.state/orchestrator-session-id"
    [[ -n "$pin" && -s "$pin" ]] || return 0
    local sid
    sid=$(head -n 1 "$pin" 2>/dev/null | tr -d '[:space:]')
    [[ "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
        && printf '%s' "$sid"
    return 0
}

# _respawn_verify_target_absent <target> [<streak_start_epoch>]
#
# Last-moment re-verification before an absent-target respawn commits
# (incident 2026-06-02: one transient absent reading spawned a
# duplicate orchestrator next to a live original; incident 2026-06-11 /
# issue #203: the kill-then-spawn can fire long after the decision).
#
# Refined per operator direction on PR #266: the original "abort if a
# live orchestrator reoccupied the slot" was too absolute — a
# DUPLICATE orchestrator (or a non-orchestrator impostor squatting the
# target window, e.g. a misplaced service cockpit) SHOULD be killable;
# that kill is the intended recovery. The precise rule:
#
#   - ONE live orchestrator-marked pane anywhere ⇒ it is THE single
#     known orchestrator — NEVER killed, regardless of what the
#     session pin says (the pin can lag a resume-fork). Abort; heal
#     the window name back to <target> when it drifted.
#   - TWO OR MORE orchestrator-marked panes ⇒ duplicates exist. A pane
#     is a PROVABLE duplicate only when its spawn session-id is known
#     (env/argv, see _respawn_pid_tree_orchestrator_sid), a pin
#     exists, they differ, AND some other pane matches the pin (the
#     anchor). Provable duplicates' windows are killed here (dedup
#     recovery); the anchored legit pane is healed/protected and the
#     respawn still aborts (it is alive — nothing to spawn). With no
#     pin-matching anchor the situation is unadjudicable: abort, kill
#     nothing, log loudly.
#   - NO orchestrator-marked pane but a window NAMED <target> exists ⇒
#     classify the occupant. A positively-classified non-orchestrator
#     occupant (readable /proc, no marker after a short re-probe to
#     dodge the launcher→exec race) is an IMPOSTOR-IN-SLOT — verify
#     returns 0 and the caller's kill-then-spawn proceeds: killing it
#     un-masks the slot and restores the real orchestrator. An
#     occupant that cannot be classified (unreadable /proc, no pane
#     listing) keeps the conservative abort.
#   - Liveness signals (heartbeat / paste-received / pinned jsonl
#     newer than <streak_start_epoch>) still abort everything: they
#     are evidence of a live orchestrator invisible to the pane scan.
#
# Env knobs: ORCH_HEARTBEAT_FILE / ORCH_PASTE_RECEIVED_FILE /
# ORCH_PIN_FILE + NEXUS_ROOT (missing degrade to "no signal");
# MONITOR_VERIFY_REPROBE_SECONDS (default 1; tests set 0) for the
# impostor re-probe.
#
# Output: a reason string on stdout (always).
# Returns: 0 = proceed with the kill-then-spawn (verified absent, or
#              the slot holds only provable impostors/duplicates).
#          1 = abort — the reason on stdout says why.
_respawn_verify_target_absent() {
    local target="${1:?target required}"
    local streak_start="${2:-0}"
    [[ "$streak_start" =~ ^[0-9]+$ ]] || streak_start=0

    # No tmux ⇒ nothing further to verify against; the caller's own
    # probe already classified the situation.
    if ! command -v tmux >/dev/null 2>&1; then
        printf 'verified-absent (no tmux to re-probe)'
        return 0
    fi

    # ---- enumerate orchestrator-marked panes (one pass) ----------------
    # DEAD PANES ARE SKIPPED (your-org/nexus-code#741). tmux keeps
    # reporting `#{pane_pid}` for a `remain-on-exit` corpse, but that
    # pid names a process that has EXITED — so every /proc answer about
    # it is either nothing or, once the kernel recycles the number,
    # about an unrelated process. Both readings are wrong here, and the
    # second is the dangerous one: a recycled pid whose environ happens
    # to carry the orchestrator marker would register a corpse as a
    # LIVE orchestrator and veto every respawn from then on. A dead
    # pane is evidence of absence, not an unreadable presence.
    local pane_pid win_id win_name pane_dead sid
    local -a orch_pid=() orch_win=() orch_name=() orch_sid=()
    while IFS='|' read -r pane_pid win_id win_name pane_dead; do
        [[ "$pane_dead" == "1" ]] && continue
        [[ "$pane_pid" =~ ^[0-9]+$ ]] || continue
        if sid=$(_respawn_pid_tree_orchestrator_sid "$pane_pid"); then
            orch_pid+=("$pane_pid"); orch_win+=("$win_id")
            orch_name+=("$win_name"); orch_sid+=("$sid")
        fi
    done < <(tmux list-panes -a -F '#{pane_pid}|#{window_id}|#{window_name}|#{pane_dead}' 2>/dev/null)

    local pinned
    pinned=$(_respawn_read_pin_sid)

    if (( ${#orch_pid[@]} >= 1 )); then
        # ---- classify legit vs provable duplicates ----------------------
        local -a legit_idx=() dup_idx=()
        local i
        if (( ${#orch_pid[@]} == 1 )); then
            # The single known orchestrator is legit by definition —
            # the pin may lag a resume-fork, so a sid mismatch with
            # only one candidate proves nothing.
            legit_idx=(0)
        else
            local have_anchor=0
            for (( i = 0; i < ${#orch_pid[@]}; i++ )); do
                [[ -n "$pinned" && "${orch_sid[i]}" == "$pinned" ]] && have_anchor=1
            done
            if (( have_anchor == 0 )); then
                # No pane provably matches the pin: which one is THE
                # orchestrator is unadjudicable (pin lag, unknown sids).
                # Abort, kill nothing, leave dedup to the operator.
                printf 'multiple-orchestrators-unresolvable n=%d pinned=%s — no pane matches the pin; refusing to adjudicate (no kill)' \
                    "${#orch_pid[@]}" "${pinned:-none}"
                return 1
            fi
            for (( i = 0; i < ${#orch_pid[@]}; i++ )); do
                if [[ -n "${orch_sid[i]}" && "${orch_sid[i]}" != "$pinned" ]]; then
                    dup_idx+=("$i")
                else
                    legit_idx+=("$i")
                fi
            done
        fi

        # ---- dedup recovery: kill provable duplicates' windows ----------
        local killed=''
        for i in "${dup_idx[@]}"; do
            tmux kill-window -t "${orch_win[i]}" 2>/dev/null || true
            killed+="${killed:+,}pane_pid=${orch_pid[i]}:sid=${orch_sid[i]}:window=${orch_win[i]}"
        done
        [[ -n "$killed" ]] && killed=" (killed duplicates: $killed; pinned=$pinned)"

        local L="${legit_idx[0]}"
        if [[ "${orch_name[L]}" == "$target" ]]; then
            printf 'window-reappeared-live pane_pid=%s window_id=%s%s' \
                "${orch_pid[L]}" "${orch_win[L]}" "$killed"
            return 1
        fi
        # Legit orchestrator alive under a drifted name. If something
        # ELSE still holds a window named <target> (a non-orchestrator
        # occupant we did not kill), do NOT stack a second window onto
        # the name — abort loudly and leave resolution to the operator
        # (the cockpit/watcher self-close guards make this state
        # self-healing for the known impostor classes).
        if grep -qxF "$target" <<<"$(tmux list-windows -F '#{window_name}' 2>/dev/null)"; then
            printf 'orchestrator-alive-elsewhere pane_pid=%s window_id=%s was_named=%s — slot %s still occupied by a non-orchestrator window; not healing%s' \
                "${orch_pid[L]}" "${orch_win[L]}" "${orch_name[L]}" "$target" "$killed"
            return 1
        fi
        # Heal the rename race: point the window back at the watcher's
        # target and re-pin the name. Best-effort — even if the rename
        # fails, aborting the respawn is correct.
        tmux rename-window -t "${orch_win[L]}" "$target" 2>/dev/null || true
        tmux set-window-option -t "${orch_win[L]}" automatic-rename off 2>/dev/null || true
        tmux set-window-option -t "${orch_win[L]}" allow-rename off 2>/dev/null || true
        printf 'orchestrator-process-alive pane_pid=%s window_id=%s was_named=%s (renamed back to %s)%s' \
            "${orch_pid[L]}" "${orch_win[L]}" "${orch_name[L]}" "$target" "$killed"
        return 1
    fi

    # ---- no orchestrator process anywhere -------------------------------
    # Liveness signals newer than the streak start: evidence of a live
    # orchestrator invisible to the pane scan (e.g. /proc-blind host).
    # Checked BEFORE the impostor classification so fresh signals also
    # veto an impostor kill (killing the slot is safe then, but the
    # SPAWN would duplicate a live agent).
    if (( streak_start > 0 )); then
        local f mtime
        for f in "${ORCH_HEARTBEAT_FILE:-}" "${ORCH_PASTE_RECEIVED_FILE:-}"; do
            [[ -n "$f" && -f "$f" ]] || continue
            mtime=$(date +%s -r "$f" 2>/dev/null || echo 0)
            [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
            if (( mtime > streak_start )); then
                printf 'orchestrator-signal-fresh file=%s mtime=%d streak_start=%d' \
                    "$(basename "$f")" "$mtime" "$streak_start"
                return 1
            fi
        done
        # Pinned-session jsonl: any write after the streak started is
        # positive evidence of a live orchestrator process.
        # Every transcript root is consulted (your-org/nexus-code#1720):
        # with CLAUDE_CONFIG_DIR set Claude Code writes under IT, and a
        # `$HOME`-only lookup lost this veto — the false-dead direction.
        if [[ -n "$pinned" && -n "${NEXUS_ROOT:-}" ]]; then
            local slug jsonl root
            slug="${NEXUS_ROOT//[^a-zA-Z0-9-]/-}"
            while IFS= read -r root; do
                [[ -n "$root" ]] || continue
                jsonl="${root}/${slug}/${pinned}.jsonl"
                [[ -f "$jsonl" ]] || continue
                mtime=$(date +%s -r "$jsonl" 2>/dev/null || echo 0)
                [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
                if (( mtime > streak_start )); then
                    printf 'orchestrator-jsonl-fresh sid=%s mtime=%d streak_start=%d' \
                        "$pinned" "$mtime" "$streak_start"
                    return 1
                fi
            done < <(cc_transcript_roots)
        fi
    fi

    # ---- impostor classification of a reappeared target window ----------
    if grep -qxF "$target" <<<"$(tmux list-windows -F '#{window_name}' 2>/dev/null)"; then
        # Re-probe once after a short settle: a freshly-spawned
        # orchestrator window briefly runs the /tmp launcher (no env
        # marker until it execs claude) and must not read as an
        # impostor. 0 disables the sleep (tests).
        local reprobe="${MONITOR_VERIFY_REPROBE_SECONDS:-1}"
        [[ "$reprobe" =~ ^[0-9]+$ ]] || reprobe=1
        (( reprobe > 0 )) && sleep "$reprobe"

        local classified=0 occupant='' live_panes=0 dead_panes=0
        while IFS='|' read -r pane_pid win_id win_name pane_dead; do
            [[ "$win_name" == "$target" ]] || continue
            # A `remain-on-exit` corpse is not an occupant. Counting it
            # as one is your-org/nexus-code#741 one layer below the
            # probe: the pane's process is gone, so `/proc` cannot
            # classify it, and "unclassified" routed straight to the
            # refuse arm below — an eternal veto on the respawn of an
            # orchestrator that had already died.
            if [[ "$pane_dead" == "1" ]]; then
                dead_panes=$(( dead_panes + 1 ))
                continue
            fi
            live_panes=$(( live_panes + 1 ))
            [[ "$pane_pid" =~ ^[0-9]+$ ]] || continue
            if _respawn_pid_tree_is_orchestrator "$pane_pid"; then
                printf 'window-reappeared-live pane_pid=%s window_id=%s (late marker)' \
                    "$pane_pid" "$win_id"
                return 1
            fi
            # Positive classification requires a readable cmdline —
            # otherwise we cannot rule out an orchestrator hiding from
            # the environ scan.
            if [[ -r "/proc/$pane_pid/cmdline" ]]; then
                classified=1
                # `{ …; } 2>/dev/null` — redirection ORDER (your-org/nexus-code#1305).
                occupant=$( { tr '\0' ' ' < "/proc/$pane_pid/cmdline"; } 2>/dev/null | head -c 120)
            fi
        done < <(tmux list-panes -a -F '#{pane_pid}|#{window_id}|#{window_name}|#{pane_dead}' 2>/dev/null)

        # The slot holds nothing but corpses. Proceeding is what the
        # caller's kill-then-spawn is FOR: the kill clears the dead
        # window, the spawn restores the orchestrator.
        #
        # Both halves of this condition are POSITIVE observations, and
        # that is the safety argument. `dead_panes > 0` requires rows
        # tmux actually returned; a query that failed yields no rows at
        # all, lands on `live_panes == 0 && dead_panes == 0`, and falls
        # through to the refuse arm below. So this branch cannot be
        # reached by failing to look — only by looking and finding a
        # corpse. Same asymmetry the probe is built on: a wrong
        # "proceed" duplicates an orchestrator, a wrong "abort" delays
        # one, and only the first leaves wreckage.
        if (( live_panes == 0 && dead_panes > 0 )); then
            printf 'verified-absent (remain-on-exit corpse: %d dead pane(s) under %s, no live process)' \
                "$dead_panes" "$target"
            return 0
        fi

        if (( classified )); then
            # Killable: a positively non-orchestrator occupant (e.g. a
            # misplaced service cockpit) squatting the target name masks
            # the orchestrator's absence — the kill-then-spawn IS the
            # recovery (operator direction, PR #266 review).
            printf 'impostor-in-slot occupant=%s — non-orchestrator window squatting %s; kill-then-spawn proceeds' \
                "${occupant:-unknown}" "$target"
            return 0
        fi
        printf 'window-reappeared (unclassified occupant; refusing to kill)'
        return 1
    fi

    printf 'verified-absent'
    return 0
}

# _respawn_resolve_settings_flag <nexus_root>
#
# Echo `--settings <path>` if monitor/orchestrator-settings.json
# exists under <nexus_root>, otherwise nothing. Quiet — callers don't
# need to special-case absence.
_respawn_resolve_settings_flag() {
    local nexus_root="$1"
    local p="$nexus_root/monitor/orchestrator-settings.json"
    [[ -f "$p" ]] || return 0
    # Operator-local overlay (your-org/nexus-code#614): prefer the
    # merged `<tracked> * <tracked>.local` result when an untracked
    # `orchestrator-settings.local.json` exists, so the operator's model
    # pin and TUI mode survive a pull instead of being silently
    # discarded when a conflict is resolved in upstream's favour. On
    # resolver failure fall back to the tracked file — this is the
    # RESPAWN path, and an orchestrator that comes back with default
    # settings is strictly better than one that does not come back at
    # all. The failure is not silent: the resolver has already written
    # its reason to stderr, which lands in the watcher log.
    local eff
    if [[ -x "$nexus_root/monitor/resolve-settings.sh" ]]; then
        eff=$("$nexus_root/monitor/resolve-settings.sh" "$p" 2>/dev/null) && [[ -n "$eff" ]] && p="$eff"
    fi
    printf -- '--settings %s' "$p"
}

# _respawn_choose_resume_mode <nexus_root>
#
# Decide HOW to resume the orchestrator. Prints "<mode>\t<sid>" on
# stdout:
#
#   "resume\t<sid>"   — pin file holds a valid UUID AND the
#                       referenced jsonl exists on disk. Caller
#                       should pass `--resume <sid>` to claude. This
#                       is deterministic: it names the EXACT session.
#   "fresh\t"         — no pin / malformed sid / jsonl missing. The
#                       session cannot be identified, so the caller
#                       spawns a COLD claude (no --resume, no
#                       --continue). See the determinism rationale
#                       below.
#
# Issue #176: pre-#176 the respawn paths always used `--continue`,
# which selects the most-recent jsonl in the project dir. When a
# supervisor or other claude session in the SAME project dir was
# writing more recently than the dead orchestrator's jsonl, the
# respawn resurrected the wrong conversation. Reading the pin and
# upgrading to `--resume <sid>` mirrors the watcher boot path
# (`entry.sh:208-236`), which has used the pin since PR #147.
#
# Issue #200 (this change): #176 fixed the pin-PRESENT path but left
# the degradation as plain `--continue`. The 2026-05-29 mass-kill
# postmortem showed why that is unsafe: during crash recovery the pin
# was absent (`previous_sid=none`), so the target-absent respawn fell
# back to `--continue`, which grabbed the FRESHEST jsonl in the
# project dir — a transient "recovery" session whose transcript was
# full of teardown commands. The respawned orchestrator re-enacted
# them and killed the watcher + itself (a second death). The lesson:
# when the session cannot be positively identified, resuming an
# ARBITRARY freshest jsonl is strictly more dangerous than starting
# cold — a transient/worker/recovery session can be freshest. So the
# safe degradation is a FRESH spawn, not `--continue`. (The operator's
# own manual recovery chose `mode=fresh` for exactly this reason; see
# the postmortem's watcher-incident log.)
#
# Pin file: $nexus_root/monitor/.state/orchestrator-session-id
# (written on every UserPromptSubmit via the orchestrator hook in
# monitor/orchestrator-settings.json — see entry.sh comment block).
#
# Project slug encoding mirrors Claude Code's: every character
# outside [a-zA-Z0-9-] in the absolute project path becomes '-'.
# Notably '/', '_', and '.' all collapse to '-', so e.g.
# `/home/operator/my_nexus` → `-home-operator-my-nexus`.
_respawn_choose_resume_mode() {
    local nexus_root="$1"
    local pin_file="$nexus_root/monitor/.state/orchestrator-session-id"
    if [[ -f "$pin_file" ]]; then
        local pinned_sid
        pinned_sid=$(<"$pin_file")
        # Strip whitespace so a trailing newline in the pin file
        # doesn't fail the regex.
        pinned_sid="${pinned_sid//[[:space:]]/}"
        if [[ "$pinned_sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            # Found under ANY transcript root is found
            # (your-org/nexus-code#1720). A `$HOME/.claude/projects`-only
            # lookup answered `fresh` for EVERY boot and respawn of an
            # operator whose `$CLAUDE_CONFIG_DIR/projects` is a real
            # directory rather than a symlink to it — at rc 0, silently.
            # The set is a superset of the old single root, so nothing that
            # resumed before stops resuming.
            local slug root
            slug="${nexus_root//[^a-zA-Z0-9-]/-}"
            while IFS= read -r root; do
                [[ -n "$root" ]] || continue
                if [[ -f "$root/${slug}/$pinned_sid.jsonl" ]]; then
                    printf 'resume\t%s\n' "$pinned_sid"
                    return 0
                fi
            done < <(cc_transcript_roots)
        fi
    fi
    printf 'fresh\t\n'
    return 0
}

# _respawn_new_session_id
#
# Print a fresh random UUID (lowercase 8-4-4-4-12) for a deterministic
# `claude --session-id <uuid>` spawn. Prefers the kernel's UUID source
# (no external dependency); falls back to uuidgen. Returns rc=1 (no
# stdout) if neither is available — callers degrade to a plain fresh
# spawn (claude assigns its own id, and the lazy hook pins it on the
# first turn, i.e. the pre-#203 behaviour).
_respawn_new_session_id() {
    local sid
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        sid=$(</proc/sys/kernel/random/uuid)
    elif command -v uuidgen >/dev/null 2>&1; then
        sid=$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')
    else
        return 1
    fi
    [[ "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1
    printf '%s' "$sid"
}

# _respawn_write_pin <nexus_root> <sid>
#
# Atomically write the orchestrator session-id pin
# (`$nexus_root/monitor/.state/orchestrator-session-id`). Mirrors the
# temp-file + rename discipline of monitor/hooks/orchestrator-session-
# pin.sh so a torn write never leaves a half-baked id in place, and
# refuses to write anything that isn't a canonical UUID (a guard
# against pinning garbage). Returns 0 on success, 1 otherwise.
#
# Issue #203: the watcher calls this IMMEDIATELY after spawning the
# orchestrator with `--session-id <sid>`, so the pin names the real
# orchestrator session from the instant of spawn — closing the lazy-
# hook gap (pre-#203 the pin was written only on the orchestrator's
# first completed UserPromptSubmit turn, leaving a window in which the
# pin held the prior/dead sid or nothing, and fresh/--continue spawns
# were never pinned at all). The hook stays as an idempotent backstop:
# claude reports the same `session_id` we assigned, so the hook
# re-writes an identical value.
#
# Only the orchestrator spawn paths call this, and they pin the exact
# uuid they just handed to `claude --session-id`, so by construction
# the pin can never name a non-orchestrator session.
_respawn_write_pin() {
    local nexus_root="$1" sid="$2"
    [[ "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1
    local dir="$nexus_root/monitor/.state"
    mkdir -p "$dir" 2>/dev/null || return 1
    local tmp="$dir/.orchestrator-session-id.$$.tmp"
    printf '%s\n' "$sid" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv -f "$tmp" "$dir/orchestrator-session-id" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

# _respawn_compose_launcher <launcher_path> <nexus_root> <continue_flag> <settings_flag> [<target_window>] [<session_id>]
#
# Write a self-deleting /tmp launcher script. The launcher execs
# $CLAUDE_BIN with --dangerously-skip-permissions, the continue flag
# ("" or "--continue"), and the settings flag ("" or "--settings
# <path>"). NEXUS_IS_ORCHESTRATOR=1 is exported so downstream hooks
# can distinguish the orchestrator pane; NEXUS_ORCHESTRATOR_WINDOW
# carries the configured target window name so the session-pin
# hook's self-rename agrees with the watcher's targeting (defaults
# to "orchestrator" when the caller doesn't pass one).
# NEXUS_ORCH_SESSION_ID (when the caller knows the sid — fresh
# --session-id spawns and --resume spawns) lets the re-verify guard's
# duplicate adjudication identify the spawned session from
# /proc/<pid>/environ without argv parsing (issue #203 revision).
#
# Caller MUST have $CLAUDE_BIN resolved (via `. _claude-bin.sh`)
# before calling this. The launcher captures the literal value at
# write-time; later changes to $CLAUDE_BIN don't affect spawned
# windows.
_respawn_compose_launcher() {
    local launcher="$1" nexus_root="$2" continue_flag="$3" settings_flag="$4"
    local target_window="${5:-orchestrator}"
    local session_id="${6:-}"
    local sid_export=''
    [[ -n "$session_id" ]] \
        && printf -v sid_export 'export NEXUS_ORCH_SESSION_ID="%s"\n' "$session_id"
    # Session MESSAGING name = the target window name (#1047). THIS is the site
    # that repairs the driving case: #1043's worker->orchestrator escalation is
    # addressed as "orchestrator", but that name was only ever a hand-typed
    # label (measured: no nameSource, nameSince ~9h after startedAt, cwd
    # basename "nexus"). Without this flag a respawned orchestrator returns as
    # the derived "nexus-<xx>" and every escalation to "orchestrator" fails --
    # precisely in the incident where escalation matters.
    #
    # SCOPE: this makes the LIVE orchestrator addressable by the window name the
    # watcher already targets; it is NOT a durable task key, because the session
    # name does NOT follow a later `tmux rename-window` (measured: window
    # renamed, session name unchanged) and a stale name still resolves.
    # If a respawn overlaps the dying session, two sessions briefly share the
    # name; measured, SendMessage then REFUSES and names the refs rather than
    # guessing, so escalation fails loudly instead of landing in the wrong pane.
    #
    # Deliberately NOT emitted into the launcher heredoc: every byte there ships
    # into each generated /tmp launcher, and the literal text "--name" in a
    # comment defeats any grep that asks whether the FLAG was passed.
    #
    # Gated on a capability probe. An
    # unsupported --name is FATAL ("error: unknown option", rc 1), so an
    # unconditional flag would kill the orchestrator respawn path itself on an
    # older pin. Degrade to the derived name, loudly, rather than to no
    # orchestrator. `declare -F` because this function is also called directly
    # by tests, which do not necessarily source _claude-bin.sh first.
    local name_flag=''
    if ! declare -F claude_supports_name_flag >/dev/null 2>&1; then
        # Source from the WATCHER'S OWN tree, not $NEXUS_ROOT: a re-rooted
        # NEXUS_ROOT (#577) must not relocate the probe away from the code that
        # needs it, and callers of this function do not all set NEXUS_ROOT —
        # under `set -u` a bare "$NEXUS_ROOT/..." would abort the caller.
        #
        # Gated on CLAUDE_BIN already being set: _claude-bin.sh calls `exit 1`
        # when it cannot resolve a binary, and `exit` from a SOURCED file kills
        # the CALLER. With CLAUDE_BIN non-empty that branch is unreachable —
        # but this gate is what makes it unreachable, rather than a caller
        # contract we would merely be trusting.
        local _cb="$_respawn_dir/../_claude-bin.sh"
        if [[ -r "$_cb" && -n "${CLAUDE_BIN:-}" && -n "${NEXUS_ROOT:-$nexus_root}" ]]; then
            # shellcheck disable=SC1091
            NEXUS_ROOT="${NEXUS_ROOT:-$nexus_root}" . "$_cb" >/dev/null 2>&1 || true
        fi
    fi
    if declare -F claude_supports_name_flag >/dev/null 2>&1 \
       && claude_supports_name_flag; then
        printf -v name_flag -- '--name %q ' "$target_window"
    fi
    # longjob-watch dispatcher arming (your-org/nexus-code#1535): `--plugin-dir
    # <dir> ` or EMPTY. The helper is FAIL-OPEN by construction — every reason
    # not to arm is one stderr line plus a row in .state/longjob/arming.log and
    # an unchanged launcher — because THIS is the watcher's own revival path:
    # a respawn that could refuse to launch over a plugin is an unrecoverable
    # board. Sourced from the watcher's own tree for the same reason the name
    # probe is (a re-rooted NEXUS_ROOT must not relocate it); absent helper =
    # no flag, said once.
    local plugin_flag=''
    if ! declare -F longjob_plugin_flag >/dev/null 2>&1; then
        local _lp="$_respawn_dir/../_longjob-plugin.sh"
        if [[ -r "$_lp" ]]; then
            # shellcheck disable=SC1090
            . "$_lp" >/dev/null 2>&1 || true
        fi
    fi
    if declare -F longjob_plugin_flag >/dev/null 2>&1; then
        # The state dir THIS respawn resolved — the same expression the
        # selection-restore files use below — so a fixture respawn logs into
        # its fixture, never into the agent shell's inherited NEXUS_ROOT
        # (measured: fixture rows in the operator's live arming.log).
        plugin_flag=$(longjob_plugin_flag "$target_window" "${NEXUS_STATE_DIR:-$nexus_root/monitor/.state}") || plugin_flag=''
        [[ -n "$plugin_flag" ]] && plugin_flag="$plugin_flag "
    else
        echo "_respawn: note: monitor/_longjob-plugin.sh not found beside the watcher, or found and failed to source — NOT passing --plugin-dir; the respawned orchestrator will have no longjob-watch dispatcher (your-org/nexus-code#1535)." >&2
    fi
    # Shim precondition, from the SINGLE SOURCE shared with spawn-worker.sh
    # (monitor/guard-block.sh.in). Read as DATA, never sourced — this file is
    # itself sourced by the watcher, and adding a sourced dependency here is
    # the skew hazard CLAUDE.md documents. Two hand-maintained copies of a
    # guard is how the next divergence lands, and a guard silently diverged
    # from its twin is a cousin of the class this closes.
    local _rs_tpl="$_respawn_dir/../guard-block.sh.in"
    local _respawn_guard_block
    if [ -r "$_rs_tpl" ]; then
        _respawn_guard_block=$(sed -e 's/@@WHO@@/_respawn/g' -e 's/@@ACTION@@/RESPAWN/g' -- "$_rs_tpl")
    else
        # Fail LOUD, never to an empty block: an absent template would emit a
        # launcher with NO guard at all, which is the exact defect (#589).
        _respawn_guard_block=$(printf '%s\n' \
            'echo "_respawn: REFUSING TO RESPAWN — shim guard template missing (guard-block.sh.in); an empty guard block is a guard that does not run (your-org/nexus-code#589)." >&2' \
            'exit 78')
    fi
    cat > "$launcher" <<LAUNCHER
#!/bin/bash
rm -f "$launcher"
export NEXUS_ROOT="$nexus_root"
# The tree the WATCHER itself ships in. The shared guard block searches it as
# a second root so a re-rooted NEXUS_ROOT cannot relocate the guard away from
# the code that requires it (#577 + #589).
export NEXUS_SPAWN_CODE_ROOT="$(cd "$_respawn_dir/../.." 2>/dev/null && pwd)"
export NEXUS_IS_ORCHESTRATOR=1
export NEXUS_ORCHESTRATOR_WINDOW="$target_window"
# Join the nexus-wide toolchain (PATH += locals/bin, UV_* -> locals/) so the
# orchestrator invokes nexus tools by name; guarded silent no-op if absent.
[ -f "\$NEXUS_ROOT/monitor/locals-env.sh" ] && . "\$NEXUS_ROOT/monitor/locals-env.sh" || true
# TMPDIR for the agent process and everything under it (your-org/nexus-code#1628):
# claude does not set one, so \$TMPDIR/x was /x. Here, in the LAUNCHER, not in
# locals-env.sh, which services and helpers also source (a callee with a private
# TMPDIR under a caller without one split the labsh rotation).
[ -z "\${TMPDIR:-}" ] && [ -f "\$NEXUS_ROOT/monitor/shellenv/tmpdir.sh" ] && . "\$NEXUS_ROOT/monitor/shellenv/tmpdir.sh" || true
# The shim precondition, emitted from the SINGLE source monitor/guard-block.sh.in
# (your-org/nexus-code#589). The orchestrator runs the same Bash-tool shells a
# worker does, so every monitor/*wrap shim must be reachable there. No
# NEXUS_ASSERT_NPROC_EXPECT is set here: unlike a worker, the orchestrator
# carries no soft nproc ceiling (it restarts services that must be able to raise
# soft back to hard), so the helper only OBSERVES propagation rather than
# requiring a specific ceiling.
${_respawn_guard_block}
${sid_export}exec "$CLAUDE_BIN" --dangerously-skip-permissions ${name_flag}${plugin_flag}$continue_flag $settings_flag
LAUNCHER
    chmod +x "$launcher"
}

# _respawn_spawn_window <target> <nexus_root> <launcher> [<force_replace>] [<streak_start>]
#
# Best-effort kill of an existing target window, then `tmux new-window`
# with the launcher as the window's command (not a child of an
# interactive shell). Sets `remain-on-exit on` so claude's exit leaves
# the pane in `dead` state (the operator can scroll history; the
# pane-state classifier can surface `state=absent`).
#
# Returns 0 on success, 3 if `tmux new-window` failed, or 5 if the
# load-bearing re-verify guard aborted the kill (see below). The caller
# is responsible for cleaning up the launcher file on failure.
#
# Re-verify-absent guard (issue #203, the catastrophe fix). The
# absent-target respawn path decides "the orchestrator window is gone"
# and then runs the kill-then-spawn from inside a DISOWNED async
# subshell that can execute seconds — or, if it survives a watcher
# restart, far longer — after the decision. By the time the kill fires,
# a live orchestrator may again occupy the slot (window rename heal,
# operator relaunch, a successor watcher's own respawn). Killing it
# would destroy a HEALTHY agent. So unless the caller explicitly forces
# the replace (force_replace=1 — the orchestrator-UNRESPONSIVE path in
# spawn-fresh-orchestrator.sh, whose entire premise is replacing a
# live-but-wedged claude in a PRESENT window), we re-run
# `_respawn_verify_target_absent` IMMEDIATELY before the kill and ABORT
# if the target is no longer absent. A missed respawn (no-op) is
# acceptable; a killed live orchestrator is not.
_respawn_spawn_window() {
    local target="$1" nexus_root="$2" launcher="$3"
    local force_replace="${4:-0}" streak_start="${5:-0}"
    if (( force_replace != 1 )); then
        local _verify_reason
        if ! _verify_reason=$(_respawn_verify_target_absent "$target" "$streak_start"); then
            # Loud, unconditional: this is the guard that stands between a
            # stale streak decision and a destroyed orchestrator.
            printf 'respawn ABORTED before kill: target %q is no longer absent (%s); refusing to kill a live orchestrator (issue #203 guard)\n' \
                "$target" "$_verify_reason" >&2
            return 5
        fi
        # A non-plain pass means the verify classified something it is
        # ABOUT to let the kill remove (impostor-in-slot) — say so in
        # the log so the recovery is auditable post-hoc.
        case "$_verify_reason" in
            verified-absent*) ;;
            *) printf 'respawn pre-kill verify: %s\n' "$_verify_reason" >&2 ;;
        esac
    fi
    # WINDOW SELECTION ACROSS THE RESPAWN (your-org/nexus-code#1528). The kill
    # below moves a session's selection when the target is its ACTIVE window
    # (measured on tmux 2.6), and `new-window -d` never selects, so the
    # operator would be left wherever tmux put them. Capture the selection
    # before the kill, note tmux's choice after it, and restore once the new
    # window's id is in hand (below). When the target is ALREADY absent — the
    # cc-update path, whose `restart-orchestrator` verb did the kill — the
    # capture file was written there and is consumed here; that is what makes
    # this the SINGLE restore site for the crash, version and cc-update paths.
    # Cosmetic and best-effort throughout: nothing in it can change this
    # function's rc or its 3/5 contract. Contract, rules and measurements:
    # `monitor/_tmux-window.sh`, "WINDOW SELECTION ACROSS AN ORCHESTRATOR
    # RESTART".
    local _sel_file=""
    if declare -F tmux_selection_restore >/dev/null 2>&1; then
        _sel_file=$(tmux_selection_capture_file "${NEXUS_STATE_DIR:-$nexus_root/monitor/.state}")
    fi
    if grep -qxF "$target" <<<"$(tmux list-windows -F '#{window_name}' 2>/dev/null)"; then
        if [[ -n "$_sel_file" ]]; then
            # Best-effort, NOT silent (your-org/nexus-code#1562): a failed
            # capture deletes its file, and without this line the only trace
            # is an operator on the wrong window.
            local _cap_rc=0
            tmux_selection_capture "$target" "$_sel_file" >/dev/null 2>&1 || _cap_rc=$?
            (( _cap_rc == 0 )) || printf '_respawn: selection capture before killing %s FAILED rc=%d: %s (non-fatal)\n' \
                "$target" "$_cap_rc" "${TMUX_SELECTION_WHY:-no reason recorded}" >&2
        fi
        tmux kill-window -t "$target" 2>/dev/null || true
        if [[ -n "$_sel_file" ]]; then
            local _post_rc=0
            tmux_selection_note_post_kill "$_sel_file" >/dev/null 2>&1 || _post_rc=$?
            (( _post_rc == 0 || _cap_rc != 0 )) || printf '_respawn: selection post-kill note for %s FAILED rc=%d: %s (non-fatal)\n' \
                "$target" "$_post_rc" "${TMUX_SELECTION_WHY:-no reason recorded}" >&2
        fi
    fi
    # `remain-on-exit` is armed ATOMICALLY WITH CREATION, in ONE tmux command
    # list, not as a follow-up round trip. A launcher that exits IMMEDIATELY —
    # and the #589 shim-precondition refusal is exactly that shape, `exit 78`
    # on the first line it reaches — closes its window before a SEPARATE
    # `set-window-option` can land. The refusal then erases the very pane an
    # operator would post-mortem, `tmux new-window` still returns 0 so the log
    # says `spawned new '<target>' window`, and the next poll re-detects
    # `absent` and respawns again: a loop whose only evidence is an absence.
    #
    # Measured on test-slow-grind-respawn.sh at 703483b5: the watcher logs the
    # successful spawn, while a 200 ms window-list sampler running across the
    # whole phase never observes the window ONCE — and the assertion passed in
    # 2 of 6 runs, which is the race showing through.
    #
    # One tmux command LIST is one server round trip executed in order with no
    # client hop between the commands, so the option is applied before the
    # freshly forked pane process can finish exec'ing and exit.
    #
    # WHICH HALF FAILED IS ANSWERED BY AN OWNED HANDLE, NOT BY A NAME
    # (your-org/nexus-code#1327). The chained form reports ONE status for TWO
    # commands, and the rc=3 contract belongs to `new-window` alone — the
    # caller counts it toward the slow-grind consecutive-failure guard, and
    # `spawn-fresh-orchestrator.sh` marks the cold-boot dropped-worker
    # manifest DELIVERED on helper rc 0, so a manufactured success
    # permanently swallows the record of everything the cold boot dropped
    # (the `#651` finding-2 catastrophe).
    #
    # This used to be answered by asking whether a window NAMED $target is
    # present afterwards. `#1324` narrowed that by first recording whether a
    # same-named window survived the kill — which closes the route where the
    # KILL DID NOT TAKE, and leaves open the route where it did: `new-window`
    # creates nothing, a concurrent creator refills the slot between the
    # post-kill re-check and the final probe, and the name probe answers
    # `present` for a window this call did not create. The concurrent
    # creators are named in this function's own neighbouring comment —
    # "window rename heal, operator relaunch, a successor watcher's own
    # respawn" — so the precondition was documented one line from the defect.
    # A finer name-keyed proxy is still a proxy: measured on this host's tmux
    # 2.6, tmux PERMITS DUPLICATE WINDOW NAMES, so no name predicate can
    # distinguish the thing from a description of it (`#1073`, `#1042`,
    # `#851`).
    #
    # `-P -F '#{window_id}'` emits the id of the window THIS CALL created, on
    # stdout, from the command already being run. Measured on tmux 2.6:
    #
    #   both commands succeed          -> stdout=[@1] rc=0
    #   the OPTION arm fails           -> stdout=[@2] rc=1   (id still emitted)
    #   `new-window` itself fails      -> stdout=[]   rc=1
    #   ids are NOT reused             -> @4,@5 after killing @2,@3
    #
    # So the discriminator is free: non-empty stdout means created, empty
    # means not. No second round trip, no name matching, no probe to race
    # against — and the `_stale_survived` bookkeeping the name probe needed
    # is gone with it, because the handle does not care what survived.
    #
    # The option arm keeps targeting by NAME: tmux does not substitute
    # `#{window_id}` in a later command's `-t` inside the same list (measured:
    # `no such window: #{window_id}`). The id is EVIDENCE, not a target.
    #
    # The SHAPE is validated, not merely the emptiness — an emptiness check is
    # a presence test wearing a validity test's name, and a wedged tmux or a
    # stub emitting garbage must fail CLOSED rather than pass it.
    #
    # This is the established form here rather than a novelty:
    # `monitor/spawn-worker.sh` has used exactly this discriminator on the
    # worker spawn path since `#323`. `_respawn.sh` was the outlier.
    local _wid
    _wid=$(tmux new-window -d -n "$target" -c "$nexus_root" -P -F '#{window_id}' "$launcher" \
               \; set-window-option -t "$target" remain-on-exit on 2>/dev/null)
    if [[ ! "$_wid" =~ ^@[0-9]+$ ]]; then
        return 3
    fi
    # Pin the window name (issue 209). Without both knobs, tmux's own
    # rename loop or an OSC escape from inside the pane can rename the
    # window away from $target, making the watcher's name-based
    # targeting lose the window and respawn until the crash-loop guard
    # trips. Mirrors the worker pin in monitor/spawn-worker.sh:383-384.
    tmux set-window-option -t "$target" automatic-rename off 2>/dev/null || true
    tmux set-window-option -t "$target" allow-rename off 2>/dev/null || true
    # (#1528) Restore the operator's selection now that the new window EXISTS
    # and is addressable by the id this call owns. rc 1 is the NO-CAPTURE
    # POLICY (nothing to do, nothing to say); every other outcome is logged to
    # stderr (the watcher log) so a wrong landing is auditable. The rc of this
    # function is decided above and is not touched here.
    if [[ -n "$_sel_file" ]]; then
        local _sel_out="" _sel_rc=0
        _sel_out=$(tmux_selection_restore "$_wid" "$_sel_file" 2>/dev/null) || _sel_rc=$?
        if (( _sel_rc != 1 )); then
            printf '_respawn: window selection after respawn of %s (%s, rc %d): %s\n' \
                "$target" "$_wid" "$_sel_rc" "${_sel_out//$'\n'/; }" >&2
        fi
        # Rule 4 (#1528, operator decision): no usable capture -> the watcher's
        # last-seen snapshot decides, and with none the orchestrator is the
        # default. rc 1 = no capture; rc 3 = stale/unreadable capture (already
        # consumed) or tmux would not answer — the fallback then fails the
        # same way and moves nothing.
        if (( _sel_rc == 1 || _sel_rc == 3 )) && declare -F tmux_selection_restore_fallback >/dev/null 2>&1; then
            local _snap_file _snap_out="" _snap_rc=0
            _snap_file=$(tmux_selection_snapshot_file "${NEXUS_STATE_DIR:-$nexus_root/monitor/.state}")
            _snap_out=$(tmux_selection_restore_fallback "$_wid" "$_snap_file" 2>/dev/null) || _snap_rc=$?
            printf '_respawn: window selection after respawn of %s (%s, no capture; snapshot arm rc %d): %s\n' \
                "$target" "$_wid" "$_snap_rc" "${_snap_out//$'\n'/; }" >&2
        fi
    fi
    return 0
}

# _respawn_resolve_target_index <target>
#
# Print the tmux window index for <target> (matched by name), or
# nothing if absent. Feeds pane-state.sh, which accepts a bare index.
_respawn_resolve_target_index() {
    local target="$1"
    tmux list-windows -F '#{window_index}|#{window_name}' 2>/dev/null \
        | awk -F'|' -v n="$target" '$2==n {print $1; exit}'
}

# _respawn_probe_state <target> <pane_state_bin>
#
# Run pane-state.sh against <target> and echo the `state=<val>` token.
# Empty stdout (rc=1) on any failure: helper missing/non-executable,
# window absent, or parse failure. Callers treat empty as "unknown".
_respawn_probe_state() {
    local out
    out=$(_respawn_probe_raw "$1" "$2") || return 1
    sed -n 's/.*state=\([a-z-]*\).*/\1/p' <<<"$out"
}

# _respawn_probe_raw <target> <pane_state_bin>
#
# The whole pane-state line for <target>, for a caller that needs more than
# `state=` (the typed-retry below reads `input=`). Same failure contract as
# _respawn_probe_state: empty stdout, rc 1.
_respawn_probe_raw() {
    local target="$1" pane_state_bin="$2"
    [[ -x "$pane_state_bin" ]] || return 1
    local idx
    idx=$(_respawn_resolve_target_index "$target")
    [[ -n "$idx" ]] || return 1
    "$pane_state_bin" "$idx" 2>/dev/null
}

# _respawn_wait_for_input_ready <target> <budget_s> <poll_s> <pane_state_bin> [<max_dismiss>] [<log_fn>]
#
# Poll pane-state.sh until <target> is classified `empty` or `idle`
# (input box wired). Returns 0 on success, 1 on budget exhaustion.
# Stdout: final observed state.
#
# When `state=blocked` is observed (claude --continue's summary
# prompt, permission overlay, AskUserQuestion chip-bar), send Escape
# to dismiss the modal and keep polling. Escape is the canonical
# dismissal verb across Claude Code's modals and is safe for a
# freshly-spawned claude (no in-flight tool call to abort).
#
# `max_dismiss` (default 5) caps the Escape spam so a modal that
# regenerates each cycle can't turn the readiness wait into a
# loop. `log_fn` (default `:` — no-op) names a bash function the
# caller pre-defined; the helper calls it with one string argument
# per significant transition.
_respawn_wait_for_input_ready() {
    local target="$1" budget_s="$2" poll_s="$3" pane_state_bin="$4"
    local max_dismiss="${5:-5}"
    local log_fn="${6:-:}"
    # 7th arg: STABLE READS (your-org/nexus-code#1715, fifth instance). 0 = the
    # legacy gate (`empty|idle` on one read). N > 0 is the RESUME gate: a pane
    # still restoring a transcript is NOT ready, and `empty` ("could not tell")
    # is not evidence that it has finished. Ready = a POSITIVE prompt state
    # (idle, working-background, working-self-paced) with nothing typed in the
    # box (input blank, ghost or absent) on N CONSECUTIVE reads whose
    # content_hash is UNCHANGED — the screen has stopped redrawing, which is the
    # observable sign that the restored transcript has rendered. Measured
    # 2026-10-02 17:19: a paste made on `state=empty` 13 s into a resume was
    # lost (the restore render clearing the box is INFERRED); nothing ran it.
    local stable_n="${7:-0}"
    [[ "$stable_n" =~ ^[0-9]+$ ]] || stable_n=0
    local deadline state dismiss_count raw inp hash prev_hash="" streak=0
    deadline=$(( $(date +%s) + budget_s ))
    dismiss_count=0
    while (( $(date +%s) < deadline )); do
        if (( stable_n > 0 )); then
            raw=$(_respawn_probe_raw "$target" "$pane_state_bin" 2>/dev/null || true)
            state=$(_respawn_field "$raw" state); inp=$(_respawn_field "$raw" input); hash=$(_respawn_field "$raw" content_hash)
            case "$state" in
                idle|working-background|working-self-paced)
                    if [[ "$inp" == blank || "$inp" == ghost || -z "$inp" ]]; then
                        if (( streak > 0 )) && [[ "$hash" == "$prev_hash" ]]; then streak=$(( streak + 1 )); else streak=1; fi
                        prev_hash="$hash"
                        if (( streak >= stable_n )); then printf '%s' "$state"; return 0; fi
                        sleep "$poll_s"; continue
                    fi
                    ;;
            esac
            streak=0; prev_hash=""
            if [[ "$state" != blocked ]]; then sleep "$poll_s"; continue; fi
        else
            state=$(_respawn_probe_state "$target" "$pane_state_bin" 2>/dev/null || true)
        fi
        case "$state" in
            empty|idle)
                printf '%s' "$state"
                return 0
                ;;
            blocked)
                if (( dismiss_count < max_dismiss )); then
                    "$log_fn" "readiness: state=blocked observed (likely --continue summary prompt or permission overlay); sending Escape to dismiss (attempt $((dismiss_count + 1))/${max_dismiss})"
                    tmux send-keys -t ":=${target}" Escape 2>/dev/null || true
                    dismiss_count=$(( dismiss_count + 1 ))
                else
                    "$log_fn" "readiness: state=blocked persists after ${max_dismiss} Escape attempts; giving up dismissal, continuing to wait"
                fi
                ;;
        esac
        sleep "$poll_s"
    done
    printf '%s' "${state:-}"
    return 1
}

# _respawn_wait_for_submit_evidence <target> <budget_s> <pane_state_bin>
#
# Poll pane-state.sh until <target> reports `busy` (the paste's Enter
# actually submitted a turn). Polls every 0.5s. Returns 0 on success, 1 on
# budget exhaustion. Stdout: final state.
#
# `user-typing` IS NOT SUBMIT EVIDENCE, AND IT USED TO BE. It was accepted
# from #158 onward (lifted verbatim into this helper by #166), with no
# rationale recorded anywhere. What it actually means is the OPPOSITE: text is
# in the input box. pane-state gives bright input-row text precedence over
# every other reading ("bright user text supersedes everything"), so after a
# paste it is exactly the signature of a brief that LANDED and was NOT
# submitted. Measured 2026-09-11: watcher.log 04:28:06 logged
# "post-paste verify (after retry): state=user-typing — turn submitted"; the
# pane then read `state=user-typing input=typed` with the recovery brief still
# in the box for ~5.5 minutes, and the transcript holds no user record until
# 04:33:43, when the cc-restart-watchdog sent one Enter by hand. That also made
# #1470's UNDELIVERED arm unreachable for this shape: this predicate passed
# before the exhaustion branch could run.
#
# ERROR DIRECTION of `busy` alone: a brief whose whole turn finishes inside
# one 0.5 s poll gap reads as UNDELIVERED (rc 4 → the caller re-arms delivery).
# That is the recoverable direction; the old predicate's was manufactured
# success.
_respawn_wait_for_submit_evidence() {
    local target="$1" budget_s="$2" pane_state_bin="$3"
    local deadline state
    deadline=$(( $(date +%s) + budget_s ))
    # PROBE FIRST, TEST THE DEADLINE AFTER (#1703). The deadline is in WHOLE
    # seconds, so a 1 s budget is "until the next second boundary": when that
    # boundary passes between the two `date` forks above and below — likelier
    # the slower a fork is — a deadline-first loop ran ZERO probes and returned
    # an empty state. The caller then asked `_respawn_box_is_brief`, which read
    # the pane as `busy` (the turn WAS running) and so "nothing of ours in the
    # box", and reported a delivered brief UNDELIVERED (rc 4). Measured: PR CI
    # run 36840086024, test-spawn-fresh-orchestrator.sh Test 4 at PSI 66%, and
    # deterministically at FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=0. A verify
    # that never looked is not a verify that saw nothing.
    while :; do
        state=$(_respawn_probe_state "$target" "$pane_state_bin" 2>/dev/null || true)
        case "$state" in
            busy)
                printf '%s' "$state"
                return 0
                ;;
        esac
        (( $(date +%s) < deadline )) || break
        sleep 0.5
    done
    printf '%s' "${state:-}"
    return 1
}

# EVERY KEYSTROKE AND PASTE IN THIS FILE TARGETS `:=<name>`, NEVER A BARE NAME
# (your-org/nexus-code#1524). tmux resolves the window part of a bare
# `-t <name>` as id → index → exact name → UNIQUE PREFIX → fnmatch, so when the
# exact window is absent and exactly one longer sibling exists — and worker /
# skeptic names share a stem by convention (`w`, `w-sk`, `w-skeptic`) — the
# keystroke lands in the SIBLING at rc 0: an Escape aborts its turn, an Enter
# submits whatever is in its box (`#1200`'s shape).
#
# Measured on this host's tmux 2.6, one fresh private server per row, 40 rows,
# no rig failures: a bare `w1` and `s:w1` redirect to `w1-sk` for send-keys,
# paste-buffer, display-message and kill-window alike; `=w1` is exact for
# kill-window but is REJECTED (`can't find pane =w1`) by every pane-target verb
# EVEN WHEN `w1` EXISTS, so it is not a drop-in; `:=w1` and `s:=w1` act on
# exactly `w1` when it is present and FAIL (rc 1, `can't find window w1`) when
# it is not, for all four verbs. Every site below already treats a failed send
# as a failed send, so the new outcome is a refusal where there used to be a
# mis-aim. `:=` keeps the bare form's session scope (an empty session part is
# the current session). Re-measure on any tmux the host moves to.

# _respawn_paste_prompt_file <target> <prompt_file>
#
# VI-mode hardening (send `i` BSpace first), load-buffer the prompt
# file under a unique name, paste-buffer into <target>, send-keys
# Enter, clean up the buffer. Returns 0 on success, 1 on any tmux
# error.
_respawn_paste_prompt_file() {
    local target="$1" prompt_file="$2"
    local buf rc
    # #745: never paste into a dead pane — it kills the tmux server
    # (20/20 measured). This site pastes the recovery prompt into a
    # window `_respawn_spawn_window` has just created, so the pane is
    # normally live; the guard covers the case where the spawned
    # launcher died between `new-window` and here, which is exactly the
    # crash-loop this module exists to survive.
    # Message branches on the verdict, refusal does not (#1020). See the
    # matching note in _unstick.sh::_paste_line_to_window.
    if _tmux_pane_is_dead "$target"; then
        if [[ "${NEXUS_PANE_LIVE_VERDICT:-}" == "dead" ]]; then
            printf '_respawn: target %q is a DEAD pane — refusing to paste the recovery prompt (your-org/nexus-code#745: a paste into a dead pane kills the tmux server). Respawn it; a retry is another attempt to kill the server.\n' \
                "$target" >&2
        else
            printf '_respawn: could NOT establish that target %q is a live pane (verdict=%s) — refusing to paste the recovery prompt (your-org/nexus-code#745). Nobody looked successfully; this is RETRYABLE and is NOT a finding that the target is a corpse.\n' \
                "$target" "${NEXUS_PANE_LIVE_VERDICT:-unset}" >&2
        fi
        return 1
    fi
    # THE PASTE GOES THROUGH THE ONE PRIMITIVE (your-org/nexus-code#1591):
    # monitor/_paste-deliver.sh normalises the brief, loads it from a FILE and
    # makes the tree's only `tmux paste-buffer` call — BRACKETED (`-p`), for the
    # reason recorded there (#1516, #1518: unbracketed, a REPL that reads the
    # paste and the Enter in one chunk takes the Enter's CR as a line break, and
    # the brief sits unsubmitted in the input box).
    #
    # WHY THIS SITE WAS THE WORST OF THE THREE, kept because it is still the
    # reason the verify stage in `_respawn_orchestrator` exists: this function's
    # only failure signal is a tmux rc. A strand here is an orchestrator that
    # was respawned, never briefed, and reported respawned — a MANUFACTURED
    # SUCCESS. The SUBMIT is therefore established by the caller's post-paste
    # verify, which presses Enter again only on `state=user-typing input=typed`
    # — the same positive-`held` allowlist `pd_submit` applies everywhere else,
    # with the longer budget a freshly `--resume`d orchestrator was measured to
    # need (2026-09-11: Enter ignored for ~5.5 min).
    #
    # `:=<name>`, never a bare name (#1524, see the block above this function).
    rc=0
    if ! declare -F pd_paste_file >/dev/null 2>&1; then
        printf '_respawn: monitor/_paste-deliver.sh is unavailable — refusing to paste the recovery prompt into %q without the confirmed-delivery primitive (your-org/nexus-code#1591)\n' "$target" >&2
        return 1
    fi
    local norm=""
    norm=$(mktemp "${TMPDIR:-/tmp}/nexus-respawn-brief.XXXXXX" 2>/dev/null) || norm=""
    if [[ -n "$norm" ]] && ! pd_normalise_file "$prompt_file" "$norm"; then
        rm -f "$norm"; norm=""
    fi
    buf="nexus-respawn-$$-$(date +%s%N)"
    if ! pd_paste_file ":=${target}" "${norm:-$prompt_file}" "$buf"; then
        rc=1
    else
        # NO BLIND ENTER ON A RE-PASTE (your-org/nexus-code#1715, skeptic F1):
        # a re-paste happens 30-45 s after an UNDELIVERED — exactly when an
        # operator reacts — and the only clearance before this Enter would be a
        # pane reading seconds stale under load, so text typed in that gap would
        # be submitted WITH the brief. _RESPAWN_NO_BLIND_ENTER=1 skips it; the
        # caller's first Enter is then the pd_box_is_ours equality.
        if [[ "${_RESPAWN_NO_BLIND_ENTER:-0}" != 1 ]]; then
            sleep 0.1
            if ! tmux send-keys -t ":=${target}" Enter 2>/dev/null; then
                rc=1
            fi
        fi
    fi
    # THE VERIFY STAGE NEEDS THE BYTES THAT WERE PASTED (your-org/nexus-code#1596):
    # its retry Enter is an EQUALITY against them (`pd_box_is_ours`). A caller
    # that sets _RESPAWN_KEEP_PASTED=1 takes ownership of the file named in
    # _RESPAWN_PASTED_FILE and removes it (only when _RESPAWN_PASTED_IS_TEMP=1 —
    # when normalisation was unavailable it IS the caller's own prompt file).
    if [[ -n "${_RESPAWN_KEEP_PASTED:-}" ]]; then
        _RESPAWN_PASTED_FILE="${norm:-$prompt_file}"
        _RESPAWN_PASTED_IS_TEMP=0; [[ -n "$norm" ]] && _RESPAWN_PASTED_IS_TEMP=1
    else
        [[ -n "$norm" ]] && rm -f "$norm"
    fi
    return $rc
}

# _respawn_paste_lock_path <target>
#
# The per-target paste lock main.sh's paste_to_target takes (#562). MUST stay
# the same expression as there: the lock only serialises the pasters that agree
# on its path (your-org/nexus-code#1539).
_respawn_paste_lock_path() {
    local target="$1"
    printf '%s\n' "${STATE_DIR:-/tmp}/paste-locks/${target//[^A-Za-z0-9._-]/_}.lock"
}

_respawn_field() {
    printf '%s' "$1" | awk -v k="$2" '{
        for (i = 1; i <= NF; i++) {
            n = index($i, "=")
            if (n > 0 && substr($i, 1, n - 1) == k) { print substr($i, n + 1); exit }
        }
    }'
}

# _respawn_box_is_brief <target> <pane-state-bin> <pasted-file>
#
# rc 0 only when BOTH hold — the two conditions `pd_submit` requires before any
# retry Enter, for the same measured reason (monitor/_paste-deliver.sh, "A RETRY
# ENTER NEEDS AN EQUALITY, NOT A SHAPE"):
#   1. pane-state positively reads `state=user-typing input=typed`, and
#   2. the input box's content IS the brief that was pasted (`pd_box_is_ours`).
# (1) alone is a shape every typed draft has. Everything else — idle, `input=?`,
# no `input=` field, an unreadable pane, a missing primitive, a box holding
# somebody else's text or paste — is rc 1: NO Enter. In `strict` mode an
# INDETERMINATE reading (`empty`, `unknown`, unreadable) is rc 2: NO Enter, and
# the caller keeps looking rather than giving up (your-org/nexus-code#1674).
# Sets _RESPAWN_BOX_WHY for the log line.
# _respawn_box_may_still_render — rc 0 iff the reading _respawn_box_is_brief
# last took (_RESPAWN_BOX_ST / _RESPAWN_BOX_INP) is one where our paste may yet
# render into the box (your-org/nexus-code#1715): a blank or ghost box on a pane
# that is neither running nor showing an overlay, or POSITIVELY typed text that
# the equality did not (yet) accept. `input=?` (undecidable, read as a draft),
# `busy` and `blocked` are not. An ALLOWLIST: anything else stops the wait.
_respawn_box_may_still_render() {
    case "${_RESPAWN_BOX_ST:-}" in busy|blocked|"") return 1 ;; esac
    case "${_RESPAWN_BOX_INP:-}" in
        blank|ghost) return 0 ;;
        typed)       [[ "$_RESPAWN_BOX_ST" == user-typing ]] ;;
        *)           return 1 ;;
    esac
}

# _respawn_box_row <target> — the input row as the log shows it: the LAST row
# starting with the prompt glyph (the row pd_box_is_ours reads), ASCII-projected
# and cut to 80 bytes, quoted; '<unreadable>' when the pane cannot be captured.
# For DIAGNOSIS only (skeptic F2): no decision reads it.
_respawn_box_row() {
    local cap row
    cap=$(tmux capture-pane -p -t ":=${1}" -S -40 2>/dev/null) || { printf "'<unreadable>'"; return 0; }
    row=$(printf '%s\n' "$cap" | LC_ALL=C awk 'index($0, "\342\235\257") == 1 { r = $0 } END { printf "%s", r }' \
        | LC_ALL=C sed -e 's/[\x80-\xff]//g' -e 's/[[:space:]]*$//' | LC_ALL=C cut -c1-80)
    printf "'%s'" "$row"
}

# _respawn_brief_lost <target> <pane_state_bin> — rc 0 iff a FRESH probe shows
# the box POSITIVELY EMPTY (input blank or ghost) on a pane at a prompt state
# that is running nothing of ours (idle, working-background, working-self-paced)
# — the only reading on which a re-paste cannot land on an operator's draft
# (your-org/nexus-code#1715). `empty`/`unknown` ("could not tell"), busy, an
# overlay, typed text and `input=?` are all NO. An allowlist.
_respawn_brief_lost() {
    local raw st inp
    raw=$(_respawn_probe_raw "$1" "$2" 2>/dev/null || true)
    st=$(_respawn_field "$raw" state); inp=$(_respawn_field "$raw" input)
    case "$st" in idle|working-background|working-self-paced) ;; *) return 1 ;; esac
    [[ "$inp" == blank || "$inp" == ghost ]]
}

_respawn_box_is_brief() {
    local target="$1" bin="$2" file="${3:-}" mode="${4:-first}" raw st inp
    _RESPAWN_BOX_WHY=""
    raw=$(_respawn_probe_raw "$target" "$bin" 2>/dev/null || true)
    # FIELD-EXACT, never a greedy `s/.*state=…`: that binds to the LAST `state=`
    # on the line, so a trailing `refined_state=…` would answer for `state`
    # (#1295 review; the same reader as monitor/_paste-deliver.sh:_pd_field).
    st=$(_respawn_field "$raw" state); inp=$(_respawn_field "$raw" input)
    # The reading this verdict rests on, for the caller's late-render wait
    # (your-org/nexus-code#1715). Globals, like _RESPAWN_BOX_WHY.
    _RESPAWN_BOX_ST="$st"; _RESPAWN_BOX_INP="$inp"

    # ORDER IS THE DESIGN. The state token gates FIRST and the equality decides
    # INSIDE it — the same shape `pd_submit` uses, deliberately, because a
    # respawn-path predicate that is MORE PERMISSIVE than the shared primitive
    # would be a divergence with no measurement behind it. The first cut of this
    # function put the CONTENT check first, so it outranked the state entirely;
    # measured, that pressed SIX Enters in four arms whose pane positively
    # reports nothing typed (test-respawn.sh A4, A6, A7, 3b).
    #
    # 1. An overlay is up. An Enter SELECTS ITS HIGHLIGHTED DEFAULT (#1200).
    if [[ "$st" == blocked ]]; then
        _RESPAWN_BOX_WHY="state=blocked: an overlay is up and an Enter would answer IT, not submit the brief"
        return 1
    fi

    # 2. INDETERMINATE — `empty` means "DON'T KNOW YET", never "nothing is
    #    there" (CLAUDE.md, #603), and an unreadable pane is not evidence
    #    either. This is the ONLY arm added to the primitive's contract, and it
    #    exists because refusing here is itself a failure mode: the orchestrator
    #    is the thing being respawned, so nothing supervises the retry, and the
    #    caller stamps its cooldown on rc 4 as well as rc 0
    #    (spawn-fresh-orchestrator.sh, deliberately — it stops the caller looping
    #    every poll), which throttles the re-arm. Treating `empty` as a negative
    #    turns a DROPPED Enter into a silent, un-retried failure: window up,
    #    claude running, brief never delivered — the manufactured-success family.
    #    Measured by test-spawn-fresh-orchestrator.sh Test 7, a suite that
    #    declares no population and is therefore invisible to `guards-for-diff`
    #    (skeptic pastefusk round 1, F1).
    #
    #    `empty` IS DISTINCT FROM `idle`, and that distinction is what makes this
    #    arm safe rather than a widening. Test 7's pane reports `empty` (the
    #    classifier could not tell); test-respawn.sh's R96-draft.late reports
    #    `idle` (a POSITIVE reading) for 1.6 s before a draft is typed. A single
    #    reading separates them, so this arm does not reach the draft case and
    #    R96-draft.late keeps its 1 Enter. The skeptic predicted these two could
    #    not be separated at one instant and that R96-draft.late would have to
    #    flip to 2; measured, the tokens differ and it does not.
    #
    #    ACCEPTED RESIDUAL, stated rather than hidden: with the classifier blind,
    #    an operator draft typed into the freshly respawned window inside the
    #    verify budget would be submitted by this ONE Enter. That was the base
    #    behaviour for EVERY state; here it is narrowed to "nothing is known",
    #    and STRICT mode (the loop) refuses it outright.
    #
    #    STRICT mode returns 2, NOT 1, for this arm (your-org/nexus-code#1674):
    #    "no Enter now" must not mean "stop looking". Measured on the real 2.1.284
    #    with an 839 MB `--resume`: an Enter sent before the resumed TUI has drawn
    #    its input box is LOST, the pasted bytes appear in the box as typed text
    #    ~10 s later, the pane reads `empty` at 3 s and `user-typing input=typed`
    #    from ~12 s on, and nothing submits the brief (340 s observed). The loop
    #    used to treat that `empty` as a refusal and break — seconds before its
    #    own Enter condition would have held (live board, 2026-09-29 13:15:00;
    #    the operator pressed Enter by hand at 13:15:29). rc 2 = keep polling,
    #    press nothing; the Enter still needs the equality below.
    if [[ -z "$st" || "$st" == empty || "$st" == unknown ]]; then
        if [[ "$mode" == strict ]]; then
            _RESPAWN_BOX_WHY="state='${st:-<unreadable>}' is INDETERMINATE (a resumed pane may still be loading) — no Enter on it; waiting for the box to read as the brief"
            return 2
        fi
        _RESPAWN_BOX_WHY="state='${st:-<unreadable>}' is INDETERMINATE (not 'the box is clear') — pressing ONE Enter, the pre-#1596 behaviour narrowed to no-evidence"
        return 0
    fi

    # 3. Typed text is POSITIVELY in the box. Now the equality decides, and this
    #    is the #1596 hazard in full: an Enter on the SHAPE alone submits an
    #    operator's draft. `input=?` is undecidable from bytes and is READ AS A
    #    DRAFT (#626), so it never reaches the equality.
    if [[ "$st" == user-typing && "$inp" == typed ]]; then
        if declare -F pd_box_is_ours >/dev/null 2>&1 && pd_box_is_ours ":=${target}" "$file"; then
            return 0
        fi
        _RESPAWN_BOX_WHY="typed text is in the input box and is not shown to be the brief — it may be an operator draft"
        return 1
    fi

    # 4. Everything else POSITIVELY says there is nothing of ours to submit:
    #    `idle` with a blank box, a ghost, `input=?`, `busy` (a turn is already
    #    running), or `user-typing` with no `input=` field at all.
    _RESPAWN_BOX_WHY="state='${st:-unknown}' input='${inp:-<absent>}': nothing of ours is positively in the input box"
    return 1
}

# _respawn_orchestrator <target> [--no-continue] [--resume-sid SID]
#                                 [--prompt-file PATH] [--log-fn NAME]
#
# High-level orchestrator-respawn. Replaces the target tmux window
# with a fresh `claude` process. By default the resume mode is chosen
# by `_respawn_choose_resume_mode`:
#   - pin valid          → `--resume <pinned-sid>` (deterministic;
#                          names the EXACT prior session — issue #176).
#   - pin missing/stale  → COLD spawn with a freshly-GENERATED
#                          `--session-id <uuid>` (issue #203), whose pin
#                          is written immediately (no --resume / no
#                          --continue). `--continue` would pick the
#                          most-recently-written jsonl in the project
#                          dir, which is the WRONG session whenever
#                          another claude (worker, transient recovery
#                          session) wrote more recently than the dead
#                          orchestrator. That footgun caused the
#                          2026-05-29 second-death; a deterministic fresh
#                          session is the safe degradation, and pinning
#                          it at spawn means the NEXT respawn can
#                          --resume it instead of degrading again.
#
# Required env:
#   NEXUS_ROOT        — nexus root. The helper sources
#                       $NEXUS_ROOT/monitor/_claude-bin.sh, which sets
#                       $CLAUDE_BIN.
#
# Optional env (mirrors spawn-fresh-orchestrator.sh's knobs):
#   PANE_STATE_BIN                          — pane-state.sh location
#                                             (default $NEXUS_ROOT/
#                                             monitor/pane-state.sh)
#   FRESH_SPAWN_READINESS_BUDGET_SECONDS    — readiness budget (30)
#   FRESH_SPAWN_READINESS_POLL_SECONDS      — readiness poll (1)
#   FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS   — post-paste verify (3)
#   FRESH_SPAWN_CLAUDE_WAIT_SECONDS         — legacy fixed sleep used
#                                             only when pane-state.sh is
#                                             missing or non-executable
#                                             (default 5)
#   MAX_DISMISS_ATTEMPTS                    — Escape cap (5)
#
# Options:
#   --no-continue         Spawn claude WITHOUT resuming any prior
#                         session (true emergency: jsonl corrupt / hook
#                         misconfigured / deliberate reset). Still gets a
#                         deterministic generated `--session-id <uuid>`
#                         that is pinned at spawn (issue #203).
#   --resume-sid SID      Caller-supplied pinned session id. When
#                         provided, the helper uses `--resume <sid>`
#                         verbatim and skips the in-helper pin lookup.
#                         Useful for callers that already inspected the
#                         pin to render a recovery prompt (issue #176,
#                         main.sh respawn_agent). Ignored when
#                         --no-continue is also passed.
#   --prompt-file PATH    After spawn, paste this file's contents into
#                         the new window and submit with Enter. Without
#                         this flag, the window comes up empty and the
#                         caller paste a prompt separately.
#   --log-fn NAME         Name of a bash function the helper calls for
#                         significant transitions (one string arg).
#                         Default `:` (no-op).
#   --force-replace       Skip the pre-kill re-verify-absent guard and
#                         replace the target window even if a live
#                         orchestrator occupies it. ONLY the
#                         orchestrator-UNRESPONSIVE path
#                         (spawn-fresh-orchestrator.sh) sets this — its
#                         premise is replacing a live-but-wedged claude.
#                         The absent-target path omits it so a window
#                         that came back to life is never killed (issue
#                         #203).
#   --streak-start EPOCH  Absent-streak start epoch, forwarded to the
#                         pre-kill `_respawn_verify_target_absent` so its
#                         liveness-signal freshness check has an anchor.
#                         Default 0 (signal check skipped).
#
# Exit codes (returned, not exit):
#   0  spawned + (if --prompt-file given) pasted successfully
#   1  bad usage / NEXUS_ROOT not a directory / CLAUDE_BIN
#      unresolvable
#   2  tmux not on PATH
#   3  tmux new-window failed
#   4  paste step failed (window spawned, prompt not delivered)
#   5  re-verify guard aborted the kill — target no longer absent (a
#      live orchestrator occupies it); no window was destroyed (#203)
_respawn_orchestrator() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        echo "_respawn_orchestrator: target window required" >&2
        return 1
    fi
    shift

    local no_continue=0
    local resume_sid_override=""
    local prompt_file=""
    local log_fn=":"
    # Re-verify-absent guard plumbing (issue #203). force_replace=1 opts
    # OUT of the pre-kill re-verify — only the orchestrator-unresponsive
    # path (spawn-fresh-orchestrator.sh) sets it, because replacing a
    # live-but-wedged orchestrator in a PRESENT window is its whole job.
    # The absent-target path leaves it 0 so a window that came back to
    # life is never killed. streak_start anchors the verify's
    # liveness-signal comparison.
    local force_replace=0
    local streak_start=0
    while (( $# > 0 )); do
        case "$1" in
            --no-continue)   no_continue=1; shift ;;
            --resume-sid)    resume_sid_override="${2:-}"; shift 2 ;;
            --prompt-file)   prompt_file="${2:-}"; shift 2 ;;
            --log-fn)        log_fn="${2:-:}"; shift 2 ;;
            --force-replace) force_replace=1; shift ;;
            --streak-start)  streak_start="${2:-0}"; shift 2 ;;
            *) echo "_respawn_orchestrator: unknown flag: $1" >&2; return 1 ;;
        esac
    done

    [[ -n "${NEXUS_ROOT:-}" && -d "$NEXUS_ROOT" ]] \
        || { echo "_respawn_orchestrator: NEXUS_ROOT not set or not a directory" >&2; return 1; }
    command -v tmux >/dev/null 2>&1 \
        || { "$log_fn" "tmux not on PATH; skipping"; return 2; }

    # Resolve $CLAUDE_BIN via the shared helper (env override →
    # project-local install → PATH). A subshell traps the
    # helper's exit-on-failure so we can convert it into a rc=1.
    if ! (
        # shellcheck disable=SC1091
        . "$NEXUS_ROOT/monitor/_claude-bin.sh" >/dev/null
    ); then
        "$log_fn" "no claude binary resolvable via _claude-bin.sh; skipping"
        return 1
    fi
    # shellcheck disable=SC1091
    . "$NEXUS_ROOT/monitor/_claude-bin.sh"

    # Issue #176: resolve the resume flag. Precedence:
    #   1. --no-continue       → empty flag (fresh session)
    #   2. --resume-sid SID    → "--resume <sid>" (caller-validated)
    #   3. (default)           → `_respawn_choose_resume_mode` decides
    #                            "--resume <pinned-sid>" or fallback
    #                            "--continue" based on the pin file.
    local settings_flag continue_flag mode resume_sid session_id
    settings_flag=$(_respawn_resolve_settings_flag "$NEXUS_ROOT")
    continue_flag=""
    mode="fresh"
    resume_sid=""
    session_id=""
    if (( no_continue == 0 )); then
        if [[ -n "$resume_sid_override" ]]; then
            # Caller already validated the sid (e.g. main.sh's
            # respawn_agent rendered a prompt mentioning this exact
            # sid). Trust them; no second pin check here.
            resume_sid="$resume_sid_override"
            continue_flag="--resume $resume_sid"
            mode="resume"
        else
            local choice
            choice=$(_respawn_choose_resume_mode "$NEXUS_ROOT")
            mode="${choice%%$'\t'*}"
            resume_sid="${choice#*$'\t'}"
            case "$mode" in
                resume)
                    continue_flag="--resume $resume_sid"
                    ;;
                continue)
                    # Explicit legacy opt-in only — `_respawn_choose_
                    # resume_mode` no longer returns this by default
                    # (issue #200). Kept reachable for any caller that
                    # deliberately wants the most-recent-jsonl behaviour.
                    continue_flag="--continue"
                    ;;
                fresh|*)
                    # Issue #200: pin missing/stale → cold spawn, NOT
                    # `--continue`. Resuming an unidentifiable freshest
                    # jsonl is the footgun that caused the 2026-05-29
                    # second-death; a fresh orchestrator is the safe
                    # degradation. Unknown modes default here too.
                    continue_flag=""
                    mode="fresh"
                    ;;
            esac
        fi
    fi

    # Issue #203: a cold/fresh spawn gets a deterministic session-id we
    # generate here and pin IMMEDIATELY after the window comes up (see
    # below) — so the watcher knows the orchestrator's session from the
    # instant of spawn instead of waiting for the lazy hook's first
    # turn. `--session-id` applies only to a NEW session, so the resume
    # paths (which already name a known sid) keep their flags untouched.
    # If UUID generation is unavailable the spawn degrades to a plain
    # fresh boot (no --session-id), matching pre-#203 behaviour.
    if [[ "$mode" == "fresh" ]]; then
        session_id=$(_respawn_new_session_id) || session_id=""
        if [[ -n "$session_id" ]]; then
            continue_flag="--session-id $session_id"
        fi
    fi

    local launcher tmpdir
    tmpdir=$(_respawn_tmpdir)
    launcher=$(mktemp --suffix=.sh "$tmpdir/nexus-respawn-launch-XXXXXX") \
        || { "$log_fn" "mktemp launcher failed"; return 1; }
    # The sid the spawned claude will run as — fresh spawns know it from
    # the generated --session-id, resumes from the resumed sid; the
    # legacy --continue path doesn't know it (empty → no env marker).
    local spawn_sid="$session_id"
    [[ -z "$spawn_sid" && "$mode" == "resume" ]] && spawn_sid="$resume_sid"
    _respawn_compose_launcher "$launcher" "$NEXUS_ROOT" "$continue_flag" "$settings_flag" "$target" "$spawn_sid"

    local spawn_rc=0
    _respawn_spawn_window "$target" "$NEXUS_ROOT" "$launcher" "$force_replace" "$streak_start" \
        || spawn_rc=$?
    if (( spawn_rc == 5 )); then
        # Re-verify guard aborted the kill: a live orchestrator now
        # occupies the target window. This is the SAFE outcome — log
        # loudly (the abort reason is already on stderr → the watcher
        # log) and propagate rc=5 so the caller records it distinctly
        # from a spawn failure. Clean up the unused launcher.
        "$log_fn" "respawn re-verify guard aborted the kill for '$target' (live orchestrator present); no window destroyed"
        rm -f "$launcher"
        return 5
    fi
    if (( spawn_rc != 0 )); then
        "$log_fn" "tmux new-window failed for '$target'"
        rm -f "$launcher"
        return 3
    fi
    # Issue #203: pin the orchestrator session-id the moment the window
    # is up. For a fresh spawn we pin the uuid we just handed to
    # `--session-id`; for a resume we re-affirm the sid we're resuming
    # (harmless — it's already the pinned value, but keeps the pin
    # authoritative if a caller-supplied --resume-sid diverged). The
    # legacy `continue` path can't pin (it never learns the resolved
    # session id), which is exactly why it's no longer a default.
    if [[ "$mode" == "fresh" && -n "$session_id" ]]; then
        if _respawn_write_pin "$NEXUS_ROOT" "$session_id"; then
            "$log_fn" "pinned orchestrator session-id $session_id at spawn (deterministic)"
        else
            "$log_fn" "warning: failed to write session-id pin for $session_id"
        fi
    elif [[ "$mode" == "resume" && -n "$resume_sid" ]]; then
        _respawn_write_pin "$NEXUS_ROOT" "$resume_sid" >/dev/null 2>&1 || true
    fi

    # Log line shape kept stable for grep'ers (test-respawn.sh asserts
    # "mode=continue"/"mode=fresh" today). The "resume"/"fresh" values
    # carry the sid suffix so post-mortem can correlate respawns with
    # the surviving jsonl.
    local mode_label="$mode"
    case "$mode" in
        resume) mode_label="resume sid=$resume_sid" ;;
        fresh)  [[ -n "$session_id" ]] && mode_label="fresh sid=$session_id" ;;
    esac
    "$log_fn" "spawned new '$target' window via $launcher (mode=$mode_label)"

    # Without a prompt-file, the spawn IS the whole delivery; caller
    # will handle anything further. Done.
    if [[ -z "$prompt_file" ]]; then
        return 0
    fi
    if [[ ! -f "$prompt_file" ]]; then
        "$log_fn" "prompt-file not found at $prompt_file; skipping paste"
        return 4
    fi

    # THE #562 PASTE LOCK, HELD FROM HERE TO THE END OF THE VERIFY
    # (your-org/nexus-code#1539). main.sh's paste_to_target serialises every
    # watcher paste into a window on a per-target flock, because two pasters
    # interleave their bytes (#562). This path was never enrolled, and it is the
    # one that runs while the pane is least able to take a paste. Measured
    # 2026-09-16 04:30-04:32 (watcher.log + the orchestrator transcript): the
    # async respawn's readiness probe timed out at 04:31:02 and it pasted the
    # brief; compose_emit, which found the new window present, pasted emit ba538f
    # into the same booting pane at 04:31:03 and re-pasted it 0.5 s later; the
    # second copy landed at the cursor INSIDE the first (`… ba538` + a whole
    # ba538f + `f ---`), nothing was submitted, and the next emit's Enter at
    # 04:32:37 delivered the splice. The brief itself never reached the
    # transcript: this function's rc 4 was TRUE.
    #
    # Held across the readiness wait as well as the paste: an emit pasted into a
    # still-booting pane is the defect, not only one racing our own bytes. An
    # emit that meets the lock waits MONITOR_PASTE_LOCK_TIMEOUT_SECONDS, then
    # takes paste_to_target's LOGGED rc 3 (retried once, then counted and alerted
    # by _emit_delivery_fail; the body is archived and re-composes). A deferred
    # emit is recoverable; a spliced one is not.
    #
    # Taken AFTER the window is spawned, never before: a lock fd open at
    # `new-window` time would be inherited by claude and held for its lifetime.
    # Same file, same expression as paste_to_target — a different path would
    # be a lock nobody else takes. Not acquired within the timeout: the brief
    # is pasted WITHOUT it and that is logged — the pre-#1539 behaviour, and
    # losing the brief to a stuck paster is the worse direction.
    local _rpl_fd=""
    if command -v flock >/dev/null 2>&1; then
        local _rpl_file
        _rpl_file=$(_respawn_paste_lock_path "$target")
        mkdir -p "${_rpl_file%/*}" 2>/dev/null || true
        if { exec {_rpl_fd}>"$_rpl_file"; } 2>/dev/null; then
            local _rpl_to="${MONITOR_PASTE_LOCK_TIMEOUT_SECONDS:-20}"
            [[ "$_rpl_to" =~ ^[0-9]+$ ]] || _rpl_to=20
            if ! flock -w "$_rpl_to" "$_rpl_fd" 2>/dev/null; then
                exec {_rpl_fd}>&-
                _rpl_fd=""
                "$log_fn" "paste lock for '${target}' NOT acquired within ${_rpl_to}s (a concurrent paster holds it); pasting the brief WITHOUT it — an emit may interleave with it (your-org/nexus-code#1539, #562)"
            fi
        else
            _rpl_fd=""
            "$log_fn" "paste lock file for '${target}' could not be opened (${_rpl_file}); pasting the brief WITHOUT it (your-org/nexus-code#1539, #562)"
        fi
    fi

    local pane_state_bin="${PANE_STATE_BIN:-$NEXUS_ROOT/monitor/pane-state.sh}"
    # A RESUME restores a transcript before its box is usable, so its default
    # budget is longer (120 s, chosen; skeptic F3: a large restore under load
    # outlasted 60) and its gate needs STABLE reads (#1715).
    local readiness_budget="${FRESH_SPAWN_READINESS_BUDGET_SECONDS:-$([[ "$mode" == resume ]] && echo 120 || echo 30)}"
    local readiness_stable=0
    [[ "$mode" == resume ]] && readiness_stable="${FRESH_SPAWN_RESUME_STABLE_READS:-3}"
    local readiness_poll="${FRESH_SPAWN_READINESS_POLL_SECONDS:-1}"
    local post_paste_verify="${FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS:-3}"
    local legacy_wait="${FRESH_SPAWN_CLAUDE_WAIT_SECONDS:-5}"
    local max_dismiss="${MAX_DISMISS_ATTEMPTS:-5}"

    # Readiness probe (pane-state-driven) or legacy fixed sleep.
    if [[ -x "$pane_state_bin" ]]; then
        local observed
        if observed=$(_respawn_wait_for_input_ready "$target" "$readiness_budget" "$readiness_poll" "$pane_state_bin" "$max_dismiss" "$log_fn" "$readiness_stable"); then
            "$log_fn" "input-ready probe: state=${observed} (budget=${readiness_budget}s$( (( readiness_stable > 0 )) && printf '; resume gate: %s stable reads' "$readiness_stable"))"
        else
            "$log_fn" "input-ready probe timed out after ${readiness_budget}s (last state='${observed:-unknown}'); attempting paste anyway"
        fi
    else
        "$log_fn" "pane-state.sh not executable at $pane_state_bin; falling back to legacy sleep ${legacy_wait}s"
        sleep "$legacy_wait"
    fi

    # BOUNDED RE-PASTE WHEN OUR BYTES ARE GONE (your-org/nexus-code#1715, fifth
    # instance, 2026-10-02 17:19): the brief was pasted into a resume that was
    # still restoring, the box later read empty (the restore render clearing it
    # is INFERRED — the pane was not captured), no turn ever ran, and every path
    # ended UNDELIVERED. When the verify ends UNDELIVERED and a FRESH probe shows
    # the box POSITIVELY empty on a pane running nothing (_respawn_brief_lost),
    # re-gate on stable reads and paste again, up to FRESH_SPAWN_REPASTE_ATTEMPTS
    # pastes in all (3, chosen). Never into a box holding text, so an operator
    # draft is never pasted over or submitted; every Enter stays behind the same
    # equality. STATED RESIDUAL: "no turn started" is read as "no `busy` was ever
    # observed"; a turn that ran AND finished between two probes would be re-sent
    # once — a duplicate brief, the recoverable direction, against a lost one.
    local _rp_attempt=1 _rp_max="${FRESH_SPAWN_REPASTE_ATTEMPTS:-3}"
    [[ "$_rp_max" =~ ^[0-9]+$ ]] && (( _rp_max >= 1 )) || _rp_max=3
    local paste_rc=0
    local _RESPAWN_KEEP_PASTED=1 _RESPAWN_PASTED_FILE="" _RESPAWN_PASTED_IS_TEMP=0 _RESPAWN_BOX_WHY=""
    while :; do
    paste_rc=0
    # Attempt 1 keeps the paste's own Enter (the #1591 contract); a RE-paste does
    # not — its first Enter must be the equality (skeptic F1).
    local _RESPAWN_NO_BLIND_ENTER=0
    (( _rp_attempt > 1 )) && _RESPAWN_NO_BLIND_ENTER=1
    _respawn_paste_prompt_file "$target" "$prompt_file" || paste_rc=1

    # Post-paste verify: state=busy confirms the Enter submitted. If not
    # busy after the budget, retry Enter once (don't busy-loop — a wedged
    # claude won't be unstuck by hammering Enter).
    #
    # The ONE exception is positive evidence that the brief is sitting in the
    # input box unsubmitted: `state=user-typing` with `input=typed`. That is an
    # ALLOWLIST (w234sk F8): `input=?` is undecidable and is read as a draft,
    # and `ghost`, `blank` or a line with no `input=` field at all say nothing
    # typed is there, so none of them gets an Enter. Then Enter is the remedy, not hammering — it submits exactly the
    # text that is there. A freshly `--resume`d orchestrator replaying a large
    # transcript was measured ignoring Enter for longer than the 3 s verify
    # window (2026-09-11: both the first Enter and the retry 2 s later left the
    # brief in the box; an Enter ~5.5 min later submitted it). So while that
    # evidence holds, Enter is re-sent after
    # FRESH_SPAWN_SUBMIT_TYPED_RETRY_INTERVAL_SECONDS (default 5), the interval
    # doubling to FRESH_SPAWN_SUBMIT_TYPED_RETRY_INTERVAL_MAX_SECONDS (30), until
    # FRESH_SPAWN_SUBMIT_TYPED_RETRY_BUDGET_SECONDS (default 120; was 60 before
    # your-org/nexus-code#1715's third instance) runs out. All three defaults
    # are CHOSEN, not measured: the incidents show 2 s and 5 s were too short
    # and give no upper bound, because nobody pressed Enter in between. 0
    # disables the typed-retry.
    #
    # EVERY RETRY ENTER HERE IS AN EQUALITY (your-org/nexus-code#1596). This stage
    # used to press Enter on a SHAPE, twice over: its first retry was
    # unconditional, and the typed-retry keyed on `input=typed` alone — which any
    # typed text has. The residual was written down here ("cannot tell the brief
    # from an operator typing into the freshly respawned window; an Enter then
    # submits both. Stated, not solved"), and PR #1595 then MEASURED that shape
    # going wrong in the shared primitive: a draft appearing 0.3 s after our
    # submit was SUBMITTED by the retry. Here it matters more, not less: the
    # orchestrator is the thing being respawned, so nothing supervises this
    # Enter, and a lost brief is recoverable (rc 4 re-arms) while a submitted
    # draft is not. So BOTH retries go through `_respawn_box_is_brief`:
    # `user-typing input=typed` AND `pd_box_is_ours` against the normalised bytes
    # that were pasted. An idle pane, an unreadable one, `input=?`, a draft, an
    # operator's paste: no Enter, and the refusal is logged with its reason.
    # The long budget is untouched: a held brief still gets an Enter every
    # interval for as long as the box IS the brief.
    #
    # ACCEPTED RESIDUAL, inherited from pd_box_is_ours and stated there: an
    # operator draft that is itself an 8+ character prefix of the brief's first
    # line, or an operator paste with exactly the brief's line-break count.
    #
    # A BLANK BOX AT THE VERIFY IS NOT YET A VERDICT (your-org/nexus-code#1715).
    # A resumed TUI can draw the paste AFTER the 3 s verify: on the live board
    # 2026-10-01 09:00:54 the pane read `working-background input=blank`, the
    # brief was reported UNDELIVERED, and it rendered moments later as
    # `[Pasted text #N +K lines]` — which the #1674 draft gate then read as an
    # OPERATOR's typed text, refusing every later paste behind it. The paste's
    # own Enter had landed on the then-empty box and done nothing. So while the
    # box POSITIVELY reads blank or ghost (nothing typed, nothing running, no
    # overlay), keep looking for up to FRESH_SPAWN_LATE_RENDER_SECONDS (default
    # 30, a value WE CHOSE: the incident's render landed within ~2 s of the
    # verify, and the budget is paid only on the respawn path, where the
    # typed-retry already spends up to 60). NO NEW ENTER CONDITION: the wait
    # ends on `busy` (submitted), on the STRICT box check passing — the same
    # `pd_box_is_ours` equality against the bytes we pasted that every Enter
    # here already requires — or on any refusal that is not "still blank"
    # (typed text that is not ours, `input=?`, an overlay), which is reported
    # UNDELIVERED exactly as before and presses nothing. An operator draft
    # therefore cannot be submitted by this wait; it only changes WHEN the
    # watcher stops looking. Residual, stated: a render later than the verify
    # plus this budget is still UNDELIVERED, and its chip is then deferred by
    # the #1674 gate as before. 0 disables the wait.
    #
    # TYPED-BUT-NOT-OURS IS NOT YET A VERDICT EITHER (#1715, second instance).
    # spawn-fresh-orchestrator's full-stack recovery (2026-10-01 11:31:42, a
    # 101-line situation report) read `user-typing input=typed` at the verify
    # and the equality said "not the brief"; the operator later found the
    # brief's chip in the box and sent it by hand. What the box held at that
    # instant was not captured, so the cause is NOT established — a transient
    # render is the reading this change bets on. The wait therefore also covers
    # a TYPED box that fails the equality: it keeps looking, and the ONLY way
    # out to an Enter is still the equality, so an operator draft is waited on
    # and then reported UNDELIVERED exactly as before — never submitted. Its
    # cost is the budget, paid once per respawn whose box holds a real draft.
    if (( paste_rc == 0 )) && [[ -x "$pane_state_bin" ]]; then
        local submit_state _lr_rc=0 _lr_submitted=0
        if submit_state=$(_respawn_wait_for_submit_evidence "$target" "$post_paste_verify" "$pane_state_bin"); then
            "$log_fn" "post-paste verify: state=${submit_state} — turn submitted"
        else
            _RESPAWN_BOX_ST=""; _RESPAWN_BOX_INP=""
            # On a RE-paste the first check is STRICT: an INDETERMINATE pane gets
            # no Enter (rc 2 waits), so no Enter here rests on anything but the
            # equality (skeptic F1).
            local _first_mode=first _first_rc=0
            (( _rp_attempt > 1 )) && _first_mode=strict
            _respawn_box_is_brief "$target" "$pane_state_bin" "$_RESPAWN_PASTED_FILE" "$_first_mode" || _first_rc=$?
            (( _first_rc != 0 )) && _lr_rc=1
            local late_budget="${FRESH_SPAWN_LATE_RENDER_SECONDS:-30}"
            [[ "$late_budget" =~ ^[0-9]+$ ]] || late_budget=30
            if (( _lr_rc != 0 && late_budget > 0 )) && { (( _first_rc == 2 )) || _respawn_box_may_still_render; }; then
                "$log_fn" "post-paste verify: no submit-evidence after ${post_paste_verify}s and the box reads state='${_RESPAWN_BOX_ST}' input='${_RESPAWN_BOX_INP}' — waiting up to ${late_budget}s for a LATE render of our paste before any verdict (your-org/nexus-code#1715)"
                local _lr_deadline=$(( $(date +%s) + late_budget )) _lr_raw _lr_st _lr_brc
                while (( $(date +%s) < _lr_deadline )); do
                    _lr_raw=$(_respawn_probe_raw "$target" "$pane_state_bin" 2>/dev/null || true)
                    _lr_st=$(_respawn_field "$_lr_raw" state)
                    if [[ "$_lr_st" == busy ]]; then _lr_submitted=1; submit_state=busy; break; fi
                    _respawn_box_is_brief "$target" "$pane_state_bin" "$_RESPAWN_PASTED_FILE" strict; _lr_brc=$?
                    if (( _lr_brc == 0 )); then _lr_rc=0; break; fi
                    if (( _lr_brc == 2 )) || _respawn_box_may_still_render; then
                        sleep 1; continue          # not (yet) the brief, or indeterminate: look again
                    fi
                    break                          # a refusal that is not "still blank": the verdict stands
                done
                if (( _lr_submitted )); then
                    "$log_fn" "post-paste verify: state=busy during the late-render wait — turn submitted (your-org/nexus-code#1715)"
                elif (( _lr_rc == 0 )); then
                    "$log_fn" "post-paste verify: our paste RENDERED late and the box IS the brief (pd_box_is_ours) — proceeding to the guarded Enter (your-org/nexus-code#1715)"
                fi
            fi
            if (( _lr_submitted )); then
                :
            elif (( _lr_rc != 0 )); then
                "$log_fn" "post-paste verify: no submit-evidence after ${post_paste_verify}s (last state='${submit_state:-unknown}'); NO retry Enter — ${_RESPAWN_BOX_WHY}; box: $(_respawn_box_row "$target"); reporting UNDELIVERED (rc 4)"
                paste_rc=1
            elif tmux send-keys -t ":=${target}" Enter 2>/dev/null; then
                # The reason this Enter was allowed, as the check stated it (skeptic
                # F2: this line used to claim "the brief is IN the input box" also
                # when the INDETERMINATE arm allowed it), plus what the box showed.
                "$log_fn" "post-paste verify: no submit-evidence after ${post_paste_verify}s (last state='${submit_state:-unknown}'); ${_RESPAWN_BOX_WHY:-the brief is IN the input box (pd_box_is_ours)}, unsubmitted; box: $(_respawn_box_row "$target"); retrying Enter once"
                local retry_state typed_submitted=0 typed_n=0
                if ! retry_state=$(_respawn_wait_for_submit_evidence "$target" "$post_paste_verify" "$pane_state_bin"); then
                    # BOUNDED BUT PERSISTENT (your-org/nexus-code#1715, third
                    # instance, 2026-10-02 10:56:32): a resumed TUI restoring a
                    # large transcript under load dropped the retry Enter, and a
                    # box that WAS the brief read "not shown to be the brief" five
                    # seconds later — while it redrew — and this loop STOPPED on
                    # that one reading. So: the budget is 120 s (was 60), the
                    # Enter interval BACKS OFF from FRESH_SPAWN_SUBMIT_TYPED_RETRY_
                    # INTERVAL_SECONDS (5) doubling to a 30 s cap, and a reading
                    # that may still become the brief (_respawn_box_may_still_render)
                    # is looked at again rather than final. Every Enter still
                    # needs the equality against the bytes WE pasted, at that
                    # instant; an operator draft is waited on, never submitted.
                    # 120 and 30 are values WE CHOSE: the incident shows 5 s was
                    # too short and gives no upper bound.
                    local typed_budget="${FRESH_SPAWN_SUBMIT_TYPED_RETRY_BUDGET_SECONDS:-120}"
                    local typed_interval="${FRESH_SPAWN_SUBMIT_TYPED_RETRY_INTERVAL_SECONDS:-5}"
                    local typed_interval_max="${FRESH_SPAWN_SUBMIT_TYPED_RETRY_INTERVAL_MAX_SECONDS:-30}"
                    [[ "$typed_budget" =~ ^[0-9]+$ ]] || typed_budget=120
                    [[ "$typed_interval" =~ ^[0-9]+$ ]] && (( typed_interval > 0 )) || typed_interval=5
                    [[ "$typed_interval_max" =~ ^[0-9]+$ ]] && (( typed_interval_max >= typed_interval )) || typed_interval_max=$typed_interval
                    local typed_deadline=$(( $(date +%s) + typed_budget ))
                    local typed_raw typed_input _rb_rc _rb_waited=0 _rb_flicker=0 _rb_blank_since=0
                    # A box that reads EMPTY for this long after our bytes were seen
                    # in it has LOST them (#1715, fifth instance): stop waiting for
                    # them to come back and let the re-paste below decide. 15 s, chosen.
                    local lost_s="${FRESH_SPAWN_LOST_PASTE_SECONDS:-15}"
                    [[ "$lost_s" =~ ^[0-9]+$ ]] || lost_s=15
                    while (( $(date +%s) < typed_deadline )); do
                        typed_raw=$(_respawn_probe_raw "$target" "$pane_state_bin" 2>/dev/null || true)
                        retry_state=$(_respawn_field "$typed_raw" state)
                        [[ "$retry_state" == busy ]] && { typed_submitted=1; break; }
                        # The EQUALITY, re-established before EVERY Enter: a box
                        # that was the brief five seconds ago may be a draft now.
                        _respawn_box_is_brief "$target" "$pane_state_bin" "$_RESPAWN_PASTED_FILE" strict; _rb_rc=$?
                        if (( _rb_rc == 2 )); then
                            # INDETERMINATE: a still-loading resumed pane (#1674).
                            # No Enter; look again. Logged once, not per poll.
                            (( _rb_waited++ == 0 )) && "$log_fn" "post-paste verify: ${_RESPAWN_BOX_WHY} (budget ${typed_budget}s)"
                            sleep 1
                            continue
                        fi
                        if (( _rb_rc != 0 )) && _respawn_box_may_still_render; then
                            # Not the brief at THIS instant, but a reading the brief
                            # may yet return to (a redraw, #1715): no Enter; look
                            # again. Logged once, not per poll.
                            if [[ "$_RESPAWN_BOX_INP" == blank || "$_RESPAWN_BOX_INP" == ghost ]]; then
                                (( _rb_blank_since > 0 )) || _rb_blank_since=$(date +%s)
                                if (( $(date +%s) - _rb_blank_since >= lost_s )); then
                                    "$log_fn" "post-paste verify: the box has read EMPTY for ${lost_s}s after holding our brief — our bytes are GONE; no Enter (your-org/nexus-code#1715)"
                                    break
                                fi
                            else
                                _rb_blank_since=0
                            fi
                            (( _rb_flicker++ == 0 )) && "$log_fn" "post-paste verify: ${_RESPAWN_BOX_WHY} — no Enter on it; looking again within the ${typed_budget}s budget (your-org/nexus-code#1715)"
                            sleep 1
                            continue
                        fi
                        if (( _rb_rc != 0 )); then
                            "$log_fn" "post-paste verify: typed-retry stopped — ${_RESPAWN_BOX_WHY}"
                            break
                        fi
                        typed_input=typed
                        typed_n=$(( typed_n + 1 ))
                        "$log_fn" "post-paste verify: state=user-typing input=${typed_input:-<absent>} — the brief is IN the input box, unsubmitted; re-sending Enter (typed-retry ${typed_n}, budget ${typed_budget}s)"
                        tmux send-keys -t ":=${target}" Enter 2>/dev/null || break
                        if retry_state=$(_respawn_wait_for_submit_evidence "$target" "$typed_interval" "$pane_state_bin"); then
                            typed_submitted=1; break
                        fi
                        typed_interval=$(( typed_interval * 2 )); (( typed_interval > typed_interval_max )) && typed_interval=$typed_interval_max
                    done
                fi
                if [[ "$retry_state" == busy ]] && (( typed_n == 0 )); then
                    "$log_fn" "post-paste verify (after retry): state=${retry_state} — turn submitted"
                elif (( typed_submitted )); then
                    "$log_fn" "post-paste verify (after ${typed_n} typed-retr$( ((typed_n == 1)) && echo y || echo ies )): state=${retry_state} — turn submitted"
                else
                    # your-org/nexus-code#1470: EXHAUSTING THE RETRIES IS A
                    # FAILURE, NOT A STATE TO PASS THROUGH. This used to log
                    # and fall out to `return 0`, so the function reported
                    # success when the TRANSPORT succeeded and the OUTCOME
                    # failed -- it verified that the keystroke was sent, never
                    # that a turn began, and only the second is the thing it
                    # exists to establish. Fired twice (watcher.log 2026-09-03
                    # 12:00:13 and 2026-09-05 04:35:28); on the second the
                    # brief sat unsubmitted in the input buffer, the caller
                    # proceeded to routine polling, and the orchestrator went
                    # idle at 04:37 having never received the instruction it
                    # was respawned to act on. It was recovered only because
                    # the cc-restart-watchdog happened to be watching.
                    #
                    # This is the MANUFACTURED-SUCCESS direction, not the
                    # masked-failure one: every artefact says the brief was
                    # delivered (window exists, claude running, paste
                    # succeeded, rc 0) and the only evidence is an absence --
                    # an idle agent, indistinguishable from one with nothing
                    # to do. Both instances read `last state='unknown'`, the
                    # state that means "could not look at all"; resolving THAT
                    # as delivered is the permissive-default arm CLAUDE.md
                    # singles out for kill decisions, applied to a delivery
                    # decision.
                    #
                    # rc 4 is already the documented code for exactly this --
                    # "paste step failed (window spawned, prompt not
                    # delivered)" -- so no new code is minted. The retry
                    # comment above stays: the fix is not more retries, it is
                    # that exhausting them must be REPORTED. (#1073: verify the
                    # property, not the mechanism.)
                    "$log_fn" "post-paste verify (after retry): still no submit-evidence (last state='${retry_state:-unknown}'); box: $(_respawn_box_row "$target"); reporting UNDELIVERED (rc 4)"
                    paste_rc=1
                fi
            else
                "$log_fn" "post-paste verify: Enter retry failed (tmux send-keys rc!=0)"
                paste_rc=1
            fi
        fi
    fi

    if (( paste_rc != 0 && _rp_attempt < _rp_max )) && [[ -x "$pane_state_bin" ]] && _respawn_brief_lost "$target" "$pane_state_bin"; then
        _rp_attempt=$(( _rp_attempt + 1 ))
        "$log_fn" "post-paste verify: the brief is NOT in the box and no turn ran — RE-PASTING after a stable-prompt gate (attempt ${_rp_attempt}/${_rp_max}; your-org/nexus-code#1715)"
        (( _RESPAWN_PASTED_IS_TEMP )) && [[ -n "$_RESPAWN_PASTED_FILE" ]] && rm -f "$_RESPAWN_PASTED_FILE"
        _RESPAWN_PASTED_FILE=""; _RESPAWN_PASTED_IS_TEMP=0
        local _rp_obs
        if ! _rp_obs=$(_respawn_wait_for_input_ready "$target" "$readiness_budget" "$readiness_poll" "$pane_state_bin" "$max_dismiss" "$log_fn" "${FRESH_SPAWN_RESUME_STABLE_READS:-3}"); then
            "$log_fn" "post-paste verify: no stable empty prompt within ${readiness_budget}s (last state='${_rp_obs:-unknown}') — NOT re-pasting into a pane that is not ready; reporting UNDELIVERED (rc 4)"
            break
        fi
        continue
    fi
    break
    done
    (( _RESPAWN_PASTED_IS_TEMP )) && [[ -n "$_RESPAWN_PASTED_FILE" ]] && rm -f "$_RESPAWN_PASTED_FILE"
    # Released only once the verify has finished with the box (#1539 above).
    [[ -n "$_rpl_fd" ]] && exec {_rpl_fd}>&-
    if (( paste_rc != 0 )); then
        return 4
    fi
    return 0
}
