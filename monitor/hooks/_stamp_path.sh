#!/usr/bin/env bash
# monitor/hooks/_stamp_path.sh — the ONE resolution of where a per-window
# stamp lives, shared by the hooks that WRITE one and the hook that CLEARS
# one (your-org/nexus-code#1143).
#
# ---------------------------------------------------------------------------
# THE DEFECT THIS SERVES
# ---------------------------------------------------------------------------
#
# The over-limit stamp's WRITER (`over-limit-emit.sh`) honours
# `NEXUS_STATE_DIR`; its `Stop`-hook CLEAR was a bare `rm -f` inside
# `worker-settings.json` / `orchestrator-settings.json` that hardcoded
# `$NEXUS_ROOT/monitor/.state`. Under any state-dir override the stamp is
# therefore written where the reader looks and cleared where nobody wrote, so
# the documented cleanup contract — "the file persists until a successful Stop
# event clears it" — is UNREACHABLE BY CONSTRUCTION.
#
# The failure is silent in both directions and that is the whole problem:
# `rm -f` on a path that does not exist succeeds and prints nothing, so the
# clear reports success for a stamp it never touched. Downstream,
# `pane-state.sh` §1b short-circuits to `state=over-limit` on the stamp's
# presence and returns BEFORE inspecting the pane — so a stamp that cannot be
# cleared is a PERMANENT false `over-limit` for that pane, read by the
# watcher's scan, the orchestrator emit gate, the wake-paste path and
# `retire-preflight.sh` alike. `#1141` measured what that costs.
#
# `#1143` names the over-limit pair. The SAME shape sat one line below it in
# `worker-settings.json`: `turn-failure-emit.sh` also honours
# `NEXUS_STATE_DIR`, and its clear also hardcoded. Two stamp kinds, three
# clear sites, one defect — which is the argument for a resolver rather than
# three repaired string literals.
#
# ---------------------------------------------------------------------------
# WHY A SOURCED RESOLVER AND NOT A FIXED `rm -f`
# ---------------------------------------------------------------------------
#
# Teaching the JSON a second env var would make the two sides agree TODAY and
# leave two implementations of one path. This repo's dominant defect class is a
# second implementation that drifts and then answers confidently — so the
# property worth buying is not "the clear is correct" but "the clear cannot be
# wrong WITHOUT the writer being wrong in the same way". A function both sides
# call is the only shape that has that property.
#
# ---------------------------------------------------------------------------
# CONTRACT
# ---------------------------------------------------------------------------
#
#   stamp_state_dir        prints the state dir; rc 1 if unresolvable.
#   stamp_window           prints the tmux window name; rc 1 if unresolvable.
#   stamp_file <kind>      prints "<state-dir>/<kind>/<window>.json"; rc 1 if
#                          either component is unresolvable, or <kind> is
#                          missing/unsafe.
#
# EVERY ONE FAILS CLOSED BY PRINTING NOTHING AND RETURNING 1. A caller that
# ignores the rc gets an EMPTY string, never a plausible-but-wrong path — the
# distinction that matters, because `rm -f ""` is a silent no-op whereas
# `rm -f "$dir/over-limit/.json"` is a silent no-op that LOOKS like a path.
# The old worker clear was literally the second one: `$NEXUS_WORKER_WINDOW`
# unquoted and unset expanded to `.../over-limit/.json`, removed nothing, and
# exited 0.
#
# This file is SOURCED, so it MUST NOT impose shell options on its caller
# (your-org/nexus-code#721's leak class, gated by
# `watcher/test-ambient-shell-option-scope.sh`). It therefore sets none.

# The state dir, resolved exactly as `over-limit-emit.sh` and
# `turn-failure-emit.sh` resolve it: the explicit override wins, else the
# root-derived default, else refuse. `${NEXUS_STATE_DIR:-}` with the COLON is
# deliberate — an explicitly EMPTY override is not a directory, and treating it
# as one would put every stamp at `/over-limit/<window>.json`.
stamp_state_dir() {
    if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
        printf '%s' "$NEXUS_STATE_DIR"
        return 0
    fi
    if [[ -n "${NEXUS_ROOT:-}" ]]; then
        printf '%s' "$NEXUS_ROOT/monitor/.state"
        return 0
    fi
    return 1
}

# The window name, resolved exactly as `over-limit-emit.sh` resolves it:
# worker env, then orchestrator env, then a best-effort tmux lookup for
# manually-launched panes.
#
# THE THIRD STEP IS WHY THE CLEAR NEEDED A SCRIPT AT ALL. A pane whose stamp
# was written via the tmux fallback carries a window name the old JSON clear
# could not compute — it knew only `$NEXUS_WORKER_WINDOW` — so that stamp was
# unclearable even with the state dir agreeing. `#1143`'s "second, smaller
# asymmetry"; smaller only in how often it fires.
#
# This resolver is a SUPERSET of `turn-failure-emit.sh`'s (worker env alone),
# and that is safe for a CLEAR in the one direction it can differ: resolving a
# window the writer would not have resolved names a file that does not exist,
# and removing a file that does not exist is a no-op. The converse — a clear
# that resolves NARROWER than its writer — is the bug being fixed.
stamp_window() {
    local w="${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-}}"
    if [[ -z "$w" ]] && [[ -n "${TMUX_PANE:-}" ]] \
        && command -v tmux >/dev/null 2>&1; then
        w=$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null) || w=""
    fi
    [[ -n "$w" ]] || return 1
    printf '%s' "$w"
}

# The full stamp path for one kind.
#
# `<kind>` is validated rather than interpolated blind. It reaches this
# function from a hook COMMAND LINE, and the value is about to be handed to
# `rm -f`; a kind containing `/` or `..` would let a caller name a path outside
# the stamp tree. The allowed shape is the one the two callers use — lowercase,
# digits, `-`, `_` — and anything else refuses rather than sanitising, because
# a silently rewritten kind is a clear that targets the wrong file.
#
# The WINDOW is deliberately NOT validated the same way: it is a tmux window
# name chosen by the operator, it is what the writer already used to compose
# the filename, and a stricter rule here than in the writer would recreate the
# split-brain this file exists to remove. It is quoted at every use instead.
stamp_file() {   # <kind>
    local kind="${1:-}" dir win
    case "$kind" in
        ''|*[!a-z0-9_-]*) return 1 ;;
    esac
    dir=$(stamp_state_dir) || return 1
    win=$(stamp_window)    || return 1
    printf '%s/%s/%s.json' "$dir" "$kind" "$win"
}
