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
_respawn_pid_tree_is_orchestrator() {
    local pid="$1" depth="${2:-3}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    if [[ -r "/proc/$pid/environ" ]] \
       && tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
          | grep -qxF 'NEXUS_IS_ORCHESTRATOR=1'; then
        return 0
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
    if [[ -r "/proc/$pid/environ" ]] \
       && tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
          | grep -qxF 'NEXUS_IS_ORCHESTRATOR=1'; then
        local sid
        sid=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
              | sed -n 's/^NEXUS_ORCH_SESSION_ID=//p' | head -n 1)
        if [[ ! "$sid" =~ $uuid_re ]]; then
            sid=""
            local -a argv=()
            local arg
            while IFS= read -r -d '' arg; do argv+=("$arg"); done \
                < "/proc/$pid/cmdline" 2>/dev/null
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
    local pane_pid win_id win_name sid
    local -a orch_pid=() orch_win=() orch_name=() orch_sid=()
    while IFS='|' read -r pane_pid win_id win_name; do
        [[ "$pane_pid" =~ ^[0-9]+$ ]] || continue
        if sid=$(_respawn_pid_tree_orchestrator_sid "$pane_pid"); then
            orch_pid+=("$pane_pid"); orch_win+=("$win_id")
            orch_name+=("$win_name"); orch_sid+=("$sid")
        fi
    done < <(tmux list-panes -a -F '#{pane_pid}|#{window_id}|#{window_name}' 2>/dev/null)

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
        if tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qxF "$target"; then
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
        if [[ -n "$pinned" && -n "${NEXUS_ROOT:-}" ]]; then
            local slug jsonl
            slug="${NEXUS_ROOT//[^a-zA-Z0-9-]/-}"
            jsonl="${HOME}/.claude/projects/${slug}/${pinned}.jsonl"
            if [[ -f "$jsonl" ]]; then
                mtime=$(date +%s -r "$jsonl" 2>/dev/null || echo 0)
                [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
                if (( mtime > streak_start )); then
                    printf 'orchestrator-jsonl-fresh sid=%s mtime=%d streak_start=%d' \
                        "$pinned" "$mtime" "$streak_start"
                    return 1
                fi
            fi
        fi
    fi

    # ---- impostor classification of a reappeared target window ----------
    if tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qxF "$target"; then
        # Re-probe once after a short settle: a freshly-spawned
        # orchestrator window briefly runs the /tmp launcher (no env
        # marker until it execs claude) and must not read as an
        # impostor. 0 disables the sleep (tests).
        local reprobe="${MONITOR_VERIFY_REPROBE_SECONDS:-1}"
        [[ "$reprobe" =~ ^[0-9]+$ ]] || reprobe=1
        (( reprobe > 0 )) && sleep "$reprobe"

        local classified=0 occupant=''
        while IFS='|' read -r pane_pid win_id win_name; do
            [[ "$win_name" == "$target" ]] || continue
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
                occupant=$(tr '\0' ' ' < "/proc/$pane_pid/cmdline" 2>/dev/null | head -c 120)
            fi
        done < <(tmux list-panes -a -F '#{pane_pid}|#{window_id}|#{window_name}' 2>/dev/null)

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
            local slug proj_dir
            slug="${nexus_root//[^a-zA-Z0-9-]/-}"
            proj_dir="$HOME/.claude/projects/${slug}"
            if [[ -f "$proj_dir/$pinned_sid.jsonl" ]]; then
                printf 'resume\t%s\n' "$pinned_sid"
                return 0
            fi
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
    cat > "$launcher" <<LAUNCHER
#!/bin/bash
rm -f "$launcher"
export NEXUS_ROOT="$nexus_root"
export NEXUS_IS_ORCHESTRATOR=1
export NEXUS_ORCHESTRATOR_WINDOW="$target_window"
# Join the nexus-wide toolchain (PATH += locals/bin, UV_* -> locals/) so the
# orchestrator invokes nexus tools by name; guarded silent no-op if absent.
[ -f "\$NEXUS_ROOT/monitor/locals-env.sh" ] && . "\$NEXUS_ROOT/monitor/locals-env.sh" || true
${sid_export}exec "$CLAUDE_BIN" --dangerously-skip-permissions $continue_flag $settings_flag
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
    if tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qxF "$target"; then
        tmux kill-window -t "$target" 2>/dev/null || true
    fi
    tmux new-window -d -n "$target" -c "$nexus_root" "$launcher" 2>/dev/null || return 3
    tmux set-window-option -t "$target" remain-on-exit on 2>/dev/null || true
    # Pin the window name (issue 209). Without both knobs, tmux's own
    # rename loop or an OSC escape from inside the pane can rename the
    # window away from $target, making the watcher's name-based
    # targeting lose the window and respawn until the crash-loop guard
    # trips. Mirrors the worker pin in monitor/spawn-worker.sh:383-384.
    tmux set-window-option -t "$target" automatic-rename off 2>/dev/null || true
    tmux set-window-option -t "$target" allow-rename off 2>/dev/null || true
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
    local target="$1" pane_state_bin="$2"
    [[ -x "$pane_state_bin" ]] || return 1
    local idx
    idx=$(_respawn_resolve_target_index "$target")
    [[ -n "$idx" ]] || return 1
    local out
    out=$("$pane_state_bin" "$idx" 2>/dev/null) || return 1
    sed -n 's/.*state=\([a-z-]*\).*/\1/p' <<<"$out"
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
    local deadline state dismiss_count
    deadline=$(( $(date +%s) + budget_s ))
    dismiss_count=0
    while (( $(date +%s) < deadline )); do
        state=$(_respawn_probe_state "$target" "$pane_state_bin" 2>/dev/null || true)
        case "$state" in
            empty|idle)
                printf '%s' "$state"
                return 0
                ;;
            blocked)
                if (( dismiss_count < max_dismiss )); then
                    "$log_fn" "readiness: state=blocked observed (likely --continue summary prompt or permission overlay); sending Escape to dismiss (attempt $((dismiss_count + 1))/${max_dismiss})"
                    tmux send-keys -t "$target" Escape 2>/dev/null || true
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
# Poll pane-state.sh until <target> reports `busy` or `user-typing`
# (the paste's Enter actually submitted a turn). Polls every 0.5s.
# Returns 0 on success, 1 on budget exhaustion. Stdout: final state.
_respawn_wait_for_submit_evidence() {
    local target="$1" budget_s="$2" pane_state_bin="$3"
    local deadline state
    deadline=$(( $(date +%s) + budget_s ))
    while (( $(date +%s) < deadline )); do
        state=$(_respawn_probe_state "$target" "$pane_state_bin" 2>/dev/null || true)
        case "$state" in
            busy|user-typing)
                printf '%s' "$state"
                return 0
                ;;
        esac
        sleep 0.5
    done
    printf '%s' "${state:-}"
    return 1
}

# _respawn_paste_prompt_file <target> <prompt_file>
#
# VI-mode hardening (send `i` BSpace first), load-buffer the prompt
# file under a unique name, paste-buffer into <target>, send-keys
# Enter, clean up the buffer. Returns 0 on success, 1 on any tmux
# error.
_respawn_paste_prompt_file() {
    local target="$1" prompt_file="$2"
    local buf rc
    buf="nexus-respawn-$$-$(date +%s%N)"
    rc=0
    if ! tmux send-keys -t "$target" i BSpace 2>/dev/null; then
        rc=1
    elif ! tmux load-buffer -b "$buf" "$prompt_file" 2>/dev/null; then
        rc=1
    elif ! tmux paste-buffer -b "$buf" -t "$target" 2>/dev/null; then
        rc=1
        tmux delete-buffer -b "$buf" 2>/dev/null || true
    else
        sleep 0.1
        if ! tmux send-keys -t "$target" Enter 2>/dev/null; then
            rc=1
        fi
        tmux delete-buffer -b "$buf" 2>/dev/null || true
    fi
    return $rc
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

    local pane_state_bin="${PANE_STATE_BIN:-$NEXUS_ROOT/monitor/pane-state.sh}"
    local readiness_budget="${FRESH_SPAWN_READINESS_BUDGET_SECONDS:-30}"
    local readiness_poll="${FRESH_SPAWN_READINESS_POLL_SECONDS:-1}"
    local post_paste_verify="${FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS:-3}"
    local legacy_wait="${FRESH_SPAWN_CLAUDE_WAIT_SECONDS:-5}"
    local max_dismiss="${MAX_DISMISS_ATTEMPTS:-5}"

    # Readiness probe (pane-state-driven) or legacy fixed sleep.
    if [[ -x "$pane_state_bin" ]]; then
        local observed
        if observed=$(_respawn_wait_for_input_ready "$target" "$readiness_budget" "$readiness_poll" "$pane_state_bin" "$max_dismiss" "$log_fn"); then
            "$log_fn" "input-ready probe: state=${observed} (budget=${readiness_budget}s)"
        else
            "$log_fn" "input-ready probe timed out after ${readiness_budget}s (last state='${observed:-unknown}'); attempting paste anyway"
        fi
    else
        "$log_fn" "pane-state.sh not executable at $pane_state_bin; falling back to legacy sleep ${legacy_wait}s"
        sleep "$legacy_wait"
    fi

    local paste_rc=0
    _respawn_paste_prompt_file "$target" "$prompt_file" || paste_rc=1

    # Post-paste verify: state=busy or state=user-typing confirms the
    # Enter submitted. If still empty after the budget, retry Enter
    # once (don't busy-loop — a wedged claude won't be unstuck by
    # hammering Enter).
    if (( paste_rc == 0 )) && [[ -x "$pane_state_bin" ]]; then
        local submit_state
        if submit_state=$(_respawn_wait_for_submit_evidence "$target" "$post_paste_verify" "$pane_state_bin"); then
            "$log_fn" "post-paste verify: state=${submit_state} — turn submitted"
        else
            "$log_fn" "post-paste verify: no submit-evidence after ${post_paste_verify}s (last state='${submit_state:-unknown}'); retrying Enter once"
            if tmux send-keys -t "$target" Enter 2>/dev/null; then
                local retry_state
                if retry_state=$(_respawn_wait_for_submit_evidence "$target" "$post_paste_verify" "$pane_state_bin"); then
                    "$log_fn" "post-paste verify (after retry): state=${retry_state} — turn submitted"
                else
                    "$log_fn" "post-paste verify (after retry): still no submit-evidence (last state='${retry_state:-unknown}')"
                fi
            else
                "$log_fn" "post-paste verify: Enter retry failed (tmux send-keys rc!=0)"
                paste_rc=1
            fi
        fi
    fi

    if (( paste_rc != 0 )); then
        return 4
    fi
    return 0
}
