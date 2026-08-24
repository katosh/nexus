#!/usr/bin/env bash
# _pane-live.sh — refuse to paste into a DEAD tmux pane
# (your-org/nexus-code#745).
#
# THE DEFECT. `tmux paste-buffer` targeting a pane tmux reports as
# `#{pane_dead}` KILLS THE TMUX SERVER. Measured on the deployed tmux
# 2.6, one fresh private server per trial, corpse confirmed before each
# paste:
#
#   paste-buffer -b B -t <dead>          server DIED 20/20
#   paste-buffer -p -d -b B -t <dead>    server DIED 20/20   (the
#                                        paste-followup.sh form)
#   CONTROL  paste-buffer into a LIVE pane      survived 10/10
#   CONTROL  send-keys   into the DEAD pane     survived 10/10
#
# Deterministic, both call forms. Not a flake, and not a lost message:
# the SERVER dies, which in this workspace means the watcher, every
# worker window, the orchestrator and the sandbox session go with it —
# and the operator cannot restart the nexus from inside.
#
# WHY IT IS REACHABLE EVERY DAY. `remain-on-exit on` is set
# DELIBERATELY, and must stay: it preserves a crashed agent's
# scrollback for diagnosis, and `#741`'s fix depends on the corpse
# being inspectable. `spawn-worker.sh` sets it on EVERY worker window,
# so the highest-frequency trigger is an ordinary RETIRED WORKER, not
# the orchestrator — a follow-up or a skeptic nudge pasted into a
# window whose agent has exited is all it takes.
#
# `send-keys` into the same dead pane is harmless (10/10 above). If a
# caller genuinely must signal a corpse, that is the safe primitive.
#
# THE ACTIVE PANE IS THE ONE THAT MATTERS, and a window-level "does it
# hold any live pane?" test is wrong in BOTH directions. Measured:
#
#   window w/ a live pane + a dead pane, DEAD one active   -> DIED
#   window w/ a live pane + a dead pane, LIVE one active   -> SURVIVED 3/3
#
# `-t <window>` and `-t @id` both land on the window's ACTIVE pane, so
# that is the pane this predicate asks about. `-t %pane` names a pane
# directly and is answered directly.

# WHY NOT `_nexus_window_has_live_agent` (_lib.sh), which already reads
# `#{pane_dead}`. It answers a DIFFERENT question — "does a live AGENT
# live in this window?" — by walking the pane's process tree through
# /proc and pgrep. Three reasons it is the wrong instrument here:
#
#   * it is window-scoped, not ACTIVE-pane-scoped, and the active pane
#     is the only one a `-t <window>` paste can land in (measured both
#     ways: a dead ACTIVE pane with a live sibling still kills the
#     server; a live ACTIVE pane with a dead sibling is safe);
#   * it knows nothing about `@id` / `%pane` targets, which two of the
#     four call sites use;
#   * "no agent" and "dead pane" are not the same thing. A pane running
#     a shell, a launcher, or `sleep` hosts no agent and is perfectly
#     safe to paste into; refusing there would break the wake path.
#
# It is a good neighbour rather than a duplicate, and the agreement is
# deliberate: same `|` delimiter, same `== "1"` allowlist, same
# pid-reuse warning. That function found the pid-reuse hazard first;
# this one inherits the lesson instead of re-learning it.

# _tmux_pane_is_dead <target>
#
# <target> is whatever would be handed to `tmux paste-buffer -t`: a
# window NAME, a window id (`@N`), or a pane id (`%N`).
#
#   rc 0  the pane that paste would land in is PROVABLY dead.
#         REFUSE — pasting would take the server down.
#   rc 1  not provably dead. Proceed.
#
# POLARITY, and why it is the opposite of `_target_window_present`'s.
# There the risky act was RESPAWNING, so "absent" had to be proven.
# Here the risky act is PASTING, so "dead" has to be proven. Both are
# the same rule — require proof before the irreversible thing — and
# proof is available exactly when the hazard exists: tmux sets
# `pane_dead` whenever a pane's child has exited, which is the only
# state that crashes it.
#
# So everything short of a positive `1` proceeds, and that choice is
# deliberate rather than lazy. Refusing on "could not tell" would turn
# a tmux that does not know `#{pane_dead}`, or one transient query
# failure, into a watcher that pastes NOTHING — a silent total outage,
# traded for a hazard that cannot occur without tmux announcing it. A
# query that fails means tmux is unreachable, in which case the paste
# was going to fail anyway and refusing costs nothing.
#
# The one place it errs toward REFUSING is ambiguity: if several
# windows share the target name and any of their active panes is dead,
# this says dead. A missed paste is retried by every caller; a dead
# server is not recoverable from in here.
#
# Prints nothing. Exit code IS the answer.
_tmux_pane_is_dead() {
    local target="${1:-}"
    [[ -n "$target" ]] || return 1
    command -v tmux >/dev/null 2>&1 || return 1

    local rows tmux_rc
    # `|` and not TAB: tmux rewrites a TAB in a format string to `_`
    # when `$TMUX` is unset and the locale is non-UTF-8, and
    # watcher/launcher.sh has a supported `-z $TMUX` path
    # (test-tmux-window-resolver.sh F1). Window names cannot contain
    # `|` (validate_window_name), and ids are `@N` / `%N`.
    rows=$(tmux list-panes -a -F '#{window_name}|#{window_id}|#{pane_id}|#{pane_active}|#{pane_dead}' 2>/dev/null)
    tmux_rc=$?
    (( tmux_rc == 0 )) || return 1

    local _pl_wname _pl_wid _pl_pid _pl_active _pl_dead
    local _pl_found_dead=0
    while IFS='|' read -r _pl_wname _pl_wid _pl_pid _pl_active _pl_dead; do
        if [[ -n "$_pl_pid" && "$target" == "$_pl_pid" ]]; then
            # Target names a pane directly — its own state is the answer,
            # active or not.
            [[ "$_pl_dead" == "1" ]] && _pl_found_dead=1
            continue
        fi
        [[ "$target" == "$_pl_wname" || "$target" == "$_pl_wid" ]] || continue
        # Only the ACTIVE pane can receive a window-targeted paste.
        [[ "$_pl_active" == "1" ]] || continue
        [[ "$_pl_dead" == "1" ]] && _pl_found_dead=1
    done <<<"$rows"

    (( _pl_found_dead == 1 )) && return 0
    return 1
}
