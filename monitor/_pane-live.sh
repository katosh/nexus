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
#   rc 0  REFUSE. Either the pane is provably dead, or this predicate
#         could not establish that it is live. Pasting would risk
#         taking the server down.
#   rc 1  PROCEED. Either the receiving pane was positively observed
#         with `pane_dead=0`, or tmux itself cannot resolve <target>
#         at all (measured: `paste-buffer -t <no-such-window>` errors
#         rc 1 and the server SURVIVES, so there is nothing to guard).
#
# $NEXUS_PANE_LIVE_VERDICT says WHICH, and callers whose refusal is
# terminal must read it (rc alone conflates two opposite recoveries):
#
#   dead     rc 0  proven corpse. Do NOT retry — retrying is another
#                  attempt to kill the server. Respawn the window.
#   unknown  rc 0  no information. DO retry: the causes (a failed
#                  fork, a busy socket) are transient by nature.
#   live     rc 1  observed `pane_dead=0`.
#   absent   rc 1  tmux cannot resolve <target>; the paste will error.
#
# POLARITY, and why it is the opposite of `_target_window_present`'s.
# There the risky act was RESPAWNING, so "absent" had to be proven.
# Here the risky act is PASTING, so LIVENESS has to be proven.
#
# THAT IS A REVERSAL (your-org/nexus-code#1017), and the argument it
# replaces is preserved here because it was not silly. The first cut
# proved DEADNESS and let everything else through, reasoning that
# refusing on "could not tell" would turn one transient query failure,
# or a tmux that does not know `#{pane_dead}`, into a watcher that
# pastes NOTHING — a silent total outage traded for a hazard tmux
# always announces. Two things were wrong with it:
#
#   * "a query that fails means tmux is unreachable, so the paste was
#     going to fail anyway" is an UNPROVEN equivalence. `rows=$(tmux
#     …)` also fails when the SHELL cannot fork — and workers here run
#     under an RLIMIT_NPROC ceiling by design. The server is alive, the
#     corpse is real, and the paste that follows is delivered.
#   * the outage it feared is only unrecoverable while it is SILENT.
#     A refusal that names itself is a stalled board the operator can
#     see and fix; a dead tmux server is not recoverable from in here
#     at all. The two costs are not commensurate, so the tie does not
#     go to whichever is more likely — it goes to whichever is
#     survivable.
#
# So the fear is answered by making the refusal LOUD and RETRYABLE
# rather than by pasting blind: every "cannot tell" prints one line
# naming what it could not determine, and the caller learns from
# $NEXUS_PANE_LIVE_VERDICT whether it is holding a corpse (terminal —
# respawn it) or an unknown (retryable — a fork failure heals).
#
# WHAT THIS PREDICATE CAN ESTABLISH — FOUR STATES, AND EVERY CALLER'S WORDING
# MUST MATCH THEM (your-org/nexus-code#1020, #1021 settled together).
#
# #1020 and #1021 are the same question asked from opposite sides: #1020 is
# this probe claiming MORE than it knows (three callers said "is a dead pane"
# when the verdict was `unknown`), #1021 is it claiming LESS than it could (the
# prefix rescue publishes `unknown` where a lookup might prove `dead`). The
# resolution is one decision, so it is recorded once, here:
#
#   THE FOUR VERDICTS ARE CORRECT AS THEY STAND. What was wrong is that three
#   callers COLLAPSED them into two on the way out. So: the vocabulary is
#   unchanged, #1021 is NOT implemented, and every caller's message is now
#   verdict-aware while every caller's REFUSAL stays unconditional on rc 0.
#
# The load-bearing distinction is between a POSITIVE observation and an
# INDETERMINATE reading:
#
#   dead    POSITIVE. `pane_dead=1` was observed on the pane a paste would
#           land in. Terminal: respawn, never retry.
#   live    POSITIVE. `pane_dead=0` was observed on that same pane.
#   absent  POSITIVE. tmux itself cannot resolve <target>, so no pane can
#           receive the paste and there is nothing to guard.
#   unknown INDETERMINATE — "nobody looked successfully". NOT a finding about
#           the pane. It must never be spoken as one, and in particular must
#           never be the basis for advising a destructive remedy.
#
# WHY #1021 IS NOT IMPLEMENTED. Upgrading `unknown` -> `dead` in the prefix
# rescue is only ever a precision gain on a refusal that already happens, and
# the obvious implementation FAILS OPEN: a pane created between the
# `list-panes` and the `display-message` is legitimately absent from `$rows`,
# and a naive `else -> live` there pastes blind — reintroducing #1017 inside
# the branch that closes it. The invariant is now ASSERTED rather than merely
# argued: `test-paste-dead-pane-guard.sh` part D case `#1021` drives a target
# that is absent from `list-panes` yet resolved by `display-message` and
# demands a REFUSAL. Any future implementation must keep that green.
#
# CONSISTENCY WITH `_bookkeeping.sh::bk_pane_kill_authorized`, which is the
# local precedent for this shape. Both are default-REFUSE, and both separate a
# positive verdict from an indeterminate reading — that file names the
# distinction explicitly (`BK_REFUSE_KIND=active` vs `indeterminate`) and its
# prose forbids treating "don't know yet" as a liveness verdict. This file now
# enforces the same rule at the point where it had been violated: the message.
#
# ONE DELIBERATE NAMING COLLISION, stated so nobody reconciles it by mistake.
# `absent` means opposite-sounding things in the two vocabularies because the
# two ask different questions. There it is the state that POSITIVELY ASSERTS a
# dead agent (renderer empty AND no live claude), so it AUTHORISES a kill. Here
# it means tmux cannot resolve the target at all, so there is no pane to hit
# and the paste may PROCEED (it will simply error). Both readings are "there is
# nothing there"; only the consequence differs. Do not unify them.
#
# Ambiguity still errs to REFUSING: if several windows share the target
# name and any of their active panes is dead, this says dead.
#
# Sets $NEXUS_PANE_LIVE_VERDICT on every path (see below). Prints only
# on "cannot tell". Exit code IS the answer.

# THE EMPTY-TARGET WARRANT, stated PER ROUTE — and then disclaimed.
#
# An earlier revision of the empty-target arm said "there is no
# legitimate caller: all four resolve a window id or name first".
# Measured at 91cecfd, ONE of the four does. All four take the target
# as `$1`; only paste-followup.sh derives its argument through the
# resolver. That was a warrant asserted over a population its mechanism
# does not cover — the exact defect your-org/nexus-code#1017 is about,
# sitting in #1017's own prose — and a reviewer inherited it from here
# and built an unreachability argument on a resolver that two of the
# surviving routes never touch. What actually blocks an empty target,
# each established by reading that route:
#
#   paste-followup.sh  the resolver, plus `die` on EVERY non-zero rc
#                      (:418-423). No row shape yields rc 0 with an
#                      empty id: the `@[0-9]*` check needs at least
#                      `@0`.
#   _unstick.sh        a bare $1. Empty is filtered far upstream, in a
#                      DIFFERENT function — `[[ -z "$w" ]] && continue`
#                      inside detect_and_unstick (:1000) — plus
#                      `${TARGET:-orchestrator}` at :832 and :936.
#   _respawn.sh        a bare $1, blocked one frame up by
#                      _respawn_orchestrator's own
#                      `[[ -z "$target" ]] -> return 1` (:996).
#   main.sh            a bare $1, and NOTHING IN main.sh BLOCKS IT.
#                      There is no non-empty check on $TARGET anywhere
#                      in that file, and its `grep -qxF "$target"`
#                      existence check (:2044) does NOT block an empty
#                      target when the window listing comes back empty:
#                      `<<<""` is one empty line and `grep -qxF ""`
#                      matches it (measured; a non-empty bogus target
#                      IS still blocked). The guard lives in another
#                      file entirely — launcher.sh's `_require_arg`
#                      refuses an empty `--target` with exit 2
#                      (nexus-code#459). So in that degraded state the
#                      arm below is the only thing standing.
#
# AND ALL OF THAT IS UNENFORCED. A comment enforces nothing: delete
# _unstick.sh:1000 and no test reds, at which point the paragraph above
# documents a guard that no longer exists — a STALE warrant, worse than
# a wrong one because it reads as verified. The obvious remedy is
# known-bad too: a test pinning :1000 textually is defeated by moving
# the filter into _act_ratelimit (safe code, spurious red), the
# position-assertion failure filed as nexus-code#1016. So the gap is
# recorded rather than papered over — and the arm below is written NOT
# TO DEPEND ON ANY OF IT. That is the point: it stays correct when
# every line above goes stale.
#
# (Kept in the header, not beside the arm, deliberately: naming the
# window-listing verb inside the function body enrols this file in
# test-tmux-window-resolver's D1 resolver manifest, which tracks
# functions that RESOLVE windows. This one does not.)

# Set by every _tmux_pane_is_dead return path; see the contract above.
# Seeded here so a `set -u` caller can read it even before the first
# call.
NEXUS_PANE_LIVE_VERDICT="${NEXUS_PANE_LIVE_VERDICT:-unknown}"

# _pane_live_cannot_tell <reason> <target> — record + announce an
# uncertain refusal. ONE line, on stderr, every time, because an
# operator who has to notice a stalled board needs the stall to say its
# own name. WHERE that line lands differs by route, and an earlier
# revision claimed "all four callers route stderr into the watcher log"
# — measured, THREE do: _unstick.sh, _respawn.sh and main.sh run inside
# the watcher process, whose launcher appends stdout/stderr to
# monitor/.state/watcher.log. paste-followup.sh is an operator/agent
# CLI — no watcher module invokes it — so its stderr goes to the
# invoking pane. Both surfaces are seen by a human; the claim was still
# wider than its mechanism. Deliberately NOT
# rate-limited and deliberately NOT counted in a state file — this is
# sourced by paste-followup.sh and three watcher modules, and giving it
# a writable-state dependency would add a failure mode to the one file
# that must never have one.
_pane_live_cannot_tell() {
    NEXUS_PANE_LIVE_VERDICT=unknown
    printf '_pane-live: cannot determine whether %q is a live pane (%s) — REFUSING to paste (your-org/nexus-code#745: a paste into a dead pane kills the tmux server). This refusal is RETRYABLE.\n' \
        "${2:-?}" "$1" >&2
}

_tmux_pane_is_dead() {
    local target="${1:-}"

    # An EMPTY target is not merely unknown, it is MIS-DIRECTED.
    # Measured on tmux 2.6: `-t ''` does not error — it resolves to the
    # CURRENT pane (`display-message -p -t '' '#{window_name}/#{pane_id}'`
    # -> `base/%0`, rc 0). So the old `return 1` here did not mean "this
    # paste will harmlessly fail", it meant "paste into whatever pane
    # tmux picks, unchecked" — and if that pane is a corpse the server
    # dies. This arm does NOT rely on callers passing a non-empty
    # target; see "THE EMPTY-TARGET WARRANT" in the header for what
    # actually blocks each route, and why that paragraph is unenforced.
    if [[ -z "$target" ]]; then
        _pane_live_cannot_tell "empty target — tmux would redirect the paste to the CURRENT pane" "$target"
        return 0
    fi

    # tmux not on PATH. The hazard is arguably impossible here (the
    # caller's own bare `tmux` resolves through the same PATH, so its
    # paste cannot reach a server either) — but "no tmux" is still an
    # absence of evidence about a pane, and this is the branch a future
    # caller holding an absolute tmux path would inherit as a false
    # negative. Refusing costs a paste that could not have landed.
    if ! command -v tmux >/dev/null 2>&1; then
        _pane_live_cannot_tell "tmux is not on PATH" "$target"
        return 0
    fi

    local rows tmux_rc
    # `|` and not TAB: tmux rewrites a TAB in a format string to `_`
    # when `$TMUX` is unset and the locale is non-UTF-8, and
    # watcher/launcher.sh has a supported `-z $TMUX` path
    # (test-tmux-window-resolver.sh F1). Window names cannot contain
    # `|` (validate_window_name), and ids are `@N` / `%N`.
    rows=$(tmux list-panes -a -F '#{window_name}|#{window_id}|#{pane_id}|#{pane_active}|#{pane_dead}' 2>/dev/null)
    tmux_rc=$?
    # THE LIVE HAZARD (#1017). tmux is present, the query failed, and
    # this function now knows NOTHING — the old `return 1` reported
    # "not dead" from zero evidence. `$( )` failing does not imply the
    # server is unreachable: a fork failure under the worker
    # RLIMIT_NPROC ceiling, or a busy socket, fails the query while the
    # server, the corpse and the paste that follows are all real.
    if (( tmux_rc != 0 )); then
        _pane_live_cannot_tell "tmux list-panes failed (rc $tmux_rc) — the server may still be alive and holding a corpse" "$target"
        return 0
    fi

    local _pl_wname _pl_wid _pl_pid _pl_active _pl_dead
    local _pl_found_dead=0 _pl_found_live=0 _pl_unreadable=""
    while IFS='|' read -r _pl_wname _pl_wid _pl_pid _pl_active _pl_dead; do
        if [[ -n "$_pl_pid" && "$target" == "$_pl_pid" ]]; then
            # Target names a pane directly — its own state is the answer,
            # active or not.
            case "$_pl_dead" in
                1) _pl_found_dead=1 ;;
                0) _pl_found_live=1 ;;
                *) _pl_unreadable="pane_dead=${_pl_dead}" ;;
            esac
            continue
        fi
        [[ "$target" == "$_pl_wname" || "$target" == "$_pl_wid" ]] || continue
        # Only the ACTIVE pane can receive a window-targeted paste — so
        # an unreadable `pane_active` means we cannot tell WHICH pane
        # the paste lands in, which is as disqualifying as not knowing
        # whether it is dead.
        case "$_pl_active" in
            1) ;;
            0) continue ;;
            *) _pl_unreadable="pane_active=${_pl_active}"; continue ;;
        esac
        case "$_pl_dead" in
            1) _pl_found_dead=1 ;;
            0) _pl_found_live=1 ;;
            *) _pl_unreadable="pane_dead=${_pl_dead}" ;;
        esac
    done <<<"$rows"

    # Proven deadness outranks everything: the documented ambiguity rule.
    if (( _pl_found_dead == 1 )); then
        NEXUS_PANE_LIVE_VERDICT=dead
        return 0
    fi

    # A field that is neither `0` nor `1`. Real tmux 2.6 emits only
    # those (asserted against the live binary in part A), but an
    # UNKNOWN format expands EMPTY at rc 0 — measured — so a tmux blind
    # to `#{pane_dead}` produces a table that parses cleanly and says
    # nothing. Reading that as "not dead" is the fail-open in its
    # purest form: the guard is switched off by the very condition that
    # makes it necessary.
    if [[ -n "$_pl_unreadable" ]]; then
        # Message text is deliberately plain ASCII and deliberately does
        # NOT spell the format literally: test-tmux-window-resolver F1
        # flags any non-comment line carrying a format opener together
        # with a non-ASCII byte, and it is right to — a delimiter this
        # file cannot see is exactly how the row-splitting breaks.
        _pane_live_cannot_tell "tmux returned an unusable ${_pl_unreadable} (this tmux may not support the pane_dead format)" "$target"
        return 0
    fi

    if (( _pl_found_live == 1 )); then
        NEXUS_PANE_LIVE_VERDICT=live
        return 1
    fi

    # No row matched — and an exact-match miss is NOT the same as "tmux
    # cannot find it". tmux target resolution does PREFIX matching:
    # measured on 2.6, `-t orch` resolves to window `orchestrator`. So
    # this walk can miss a target that `paste-buffer -t` will happily
    # deliver to — possibly to a corpse. Ask tmux itself, which is the
    # only matcher guaranteed to agree with the one the paste uses.
    local _pl_resolved _pl_rrc
    _pl_resolved=$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null)
    _pl_rrc=$?
    if (( _pl_rrc == 0 )) && [[ -n "$_pl_resolved" ]]; then
        _pane_live_cannot_tell "no row matched, yet tmux resolves it to pane ${_pl_resolved} (target matching is prefix-based)" "$target"
        return 0
    fi

    # tmux cannot resolve it either. `paste-buffer -t <no-such-window>`
    # errors rc 1 with the server intact (measured), so there is no
    # hazard to guard against and refusing would only break a
    # paste-failure path each route already has — measured, not
    # assumed: rc 1 at _unstick.sh and _respawn.sh (their existing
    # "paste failed" contract), `die` at paste-followup.sh, rc 3 at
    # main.sh (retried once by paste_with_retry).
    NEXUS_PANE_LIVE_VERDICT=absent
    return 1
}
