#!/usr/bin/env bash
# Controllable `claude` shim for the watcher integration harness.
# Renders enough of the Claude Code REPL surface that
# `monitor/pane-state.sh` can classify the pane through the busy →
# idle transition without launching a real claude binary.
#
# The shim runs inside a tmux pane (or any TTY); the bytes it prints
# are what the watcher's `tmux capture-pane -e` will read. Match the
# exact escape sequences `pane-state.sh` greps for — see the comments
# at the top of that file for the wire format.
#
# Scrollback discipline: every redraw clears both the visible screen
# AND the scrollback (`\x1b[3J`) and re-homes the cursor before
# emitting the frame. Without the scrollback clear, tmux retains
# previous frames in the -25-line capture window so the busy
# spinner's `↑ N tokens` substring stays visible after the stub has
# transitioned to idle, and `_detect_busy` keeps reporting `busy`.
# This is why the stub looks more elaborate than a naive
# `printf <frame>` loop.
#
# Env knobs:
#   STUB_CLAUDE_BUSY_SECONDS   (default 0)   — render the spinner
#                                              row with `↑ N tokens`
#                                              for this many seconds.
#                                              Detected by
#                                              `_detect_busy`.
#   STUB_CLAUDE_HOLD_SECONDS   (default 30)  — hold the idle
#                                              empty-input render
#                                              this long before
#                                              exiting. Long enough
#                                              that a scenario can
#                                              assert on `state=idle`
#                                              without racing the
#                                              exit.
#   STUB_CLAUDE_EXIT_AFTER_BUSY (default 0)  — when non-zero, exit
#                                              (rc=0) immediately
#                                              after the busy phase
#                                              instead of going idle.
#                                              Pairs with tmux
#                                              `remain-on-exit on`
#                                              for the "claude
#                                              exited gracefully"
#                                              scenario.
#   STUB_CLAUDE_TICK_SECONDS   (default 1)   — spinner tick cadence.
#                                              Lower values render
#                                              faster at the cost of
#                                              terminal jitter.

set -u

BUSY_SECONDS="${STUB_CLAUDE_BUSY_SECONDS:-0}"
HOLD_SECONDS="${STUB_CLAUDE_HOLD_SECONDS:-30}"
EXIT_AFTER_BUSY="${STUB_CLAUDE_EXIT_AFTER_BUSY:-0}"
TICK_SECONDS="${STUB_CLAUDE_TICK_SECONDS:-1}"

# ANSI building blocks pinned to the regexes pane-state.sh greps for.
# Edit-with-caution: if pane-state.sh changes its renderer detection,
# the stub must change in lockstep so scenarios stay honest.
ESC=$'\x1b'
NBSP=$'\xc2\xa0'
DIM="${ESC}[2m"
RESET="${ESC}[0m"
REVERSE="${ESC}[7m"
HOME="${ESC}[H"
CLEAR_VISIBLE="${ESC}[2J"
CLEAR_SCROLLBACK="${ESC}[3J"
CLEAR_LINE_REST="${ESC}[K"

# Compose a full-pane clear. CSI 2J clears the visible screen; CSI H
# homes the cursor. CSI 3J would clear scrollback too, but tmux <= 2.6
# does not honour it, so we offset the actual frame content below
# (see `render_idle_frame`) instead of relying on scrollback being
# clean.
clear_pane() {
    printf '%b' "${CLEAR_SCROLLBACK}${CLEAR_VISIBLE}${HOME}"
}

# Render N blank padding rows so the next content sits N rows below
# the top of the visible screen. Pushes any scrollback residue out of
# `_detect_busy`'s 10-row look-back window when transitioning busy →
# idle, since tmux 2.6 doesn't clear scrollback on CSI 2J.
emit_padding_rows() {
    local rows="$1"
    local i
    for (( i = 0; i < rows; i++ )); do
        printf '%s\n' "${CLEAR_LINE_REST}"
    done
}

# Idle input row pattern: `❯<NBSP>` followed by the reverse-video
# cursor cell `\x1b[7m \x1b[0m` that `_detect_empty_input` matches.
# The frame sits 12 rows below the top of the visible screen so the
# input row's 10-row preceding window (scanned by `_detect_busy`)
# falls entirely within the freshly-cleared visible area, never
# reaching into the scrollback residue from a prior busy phase.
render_idle_frame() {
    clear_pane
    emit_padding_rows 12
    printf '%s%s%s\n' \
        "$DIM" "╭─────────────────────────────────────────────────╮" "$RESET"
    printf '%s│%s ❯%s%s %s                                               %s│%s\n' \
        "$DIM" "$RESET" "$NBSP" "$REVERSE" "$RESET" "$DIM" "$RESET"
    printf '%s%s%s\n' \
        "$DIM" "╰─────────────────────────────────────────────────╯" "$RESET"
}

# Busy frame: the `↑ <N> tokens` substring on a row immediately above
# the input chevron. `_detect_busy` scans the 10 lines preceding the
# input row, so the spinner just needs to be within that window.
# Same 12-row top offset as the idle frame so the box sits at a
# steady row count and the busy → idle transition doesn't shift the
# input row's screen position.
render_busy_frame() {
    local seconds_elapsed="$1"
    local tokens=$(( 100 + seconds_elapsed * 47 ))
    clear_pane
    emit_padding_rows 11
    printf '%s✻ Whisking… (esc to interrupt)  ↑ %d tokens%s\n' \
        "$DIM" "$tokens" "$RESET"
    printf '%s%s%s\n' \
        "$DIM" "╭─────────────────────────────────────────────────╮" "$RESET"
    printf '%s│%s ❯%s%s %s                                               %s│%s\n' \
        "$DIM" "$RESET" "$NBSP" "$REVERSE" "$RESET" "$DIM" "$RESET"
    printf '%s%s%s\n' \
        "$DIM" "╰─────────────────────────────────────────────────╯" "$RESET"
}

# Quiet sigterm: clean up the cursor and exit. Without this the
# trailing dim escape can bleed into the captured bytes when the
# harness kills the window mid-render.
on_signal() {
    printf '%b' "${RESET}"
    exit 0
}
trap on_signal INT TERM

# Initial draw: idle frame. If BUSY_SECONDS > 0 we'll overwrite with
# the spinner frame each tick; otherwise the idle frame is the
# steady state.
render_idle_frame

if (( BUSY_SECONDS > 0 )); then
    start_ts=$(date +%s)
    while :; do
        now=$(date +%s)
        elapsed=$(( now - start_ts ))
        (( elapsed >= BUSY_SECONDS )) && break
        render_busy_frame "$elapsed"
        sleep "$TICK_SECONDS"
    done
    if [[ "$EXIT_AFTER_BUSY" != "0" ]]; then
        # Clean exit. tmux `remain-on-exit on` keeps the window; the
        # watcher's `_pane_has_live_claude` check should observe no
        # `claude` in the tree → `state=absent`. CSI 3J alone is not
        # enough — tmux ≤ 2.6 ignores it, so the spinner + chevron
        # from the last busy frame stay in scrollback and
        # `pane-state.sh::_detect_busy` keeps reporting `state=busy`
        # against a process that has already exited. After the clear
        # we emit 80 blank padding rows so the chevron is scrolled
        # past the `-S -25` capture window (24 visible + 25 scrollback
        # ≈ 49 lines): no chevron in capture → input-row search fails
        # → falls through to the live-claude pid check → `absent`.
        # Real claude renders an exit prompt / blank frame before
        # returning; matching that here keeps the scenario honest
        # across tmux versions.
        clear_pane
        emit_padding_rows 80
        printf '%b' "${RESET}"
        exit 0
    fi
    # Transition to idle: clear scrollback + redraw the empty box.
    render_idle_frame
fi

# Idle hold. `read -t` would wake on tty input; we want the stub to
# stay rendered while the scenario polls, so plain sleep.
sleep "$HOLD_SECONDS"
printf '%b' "${RESET}"
exit 0
