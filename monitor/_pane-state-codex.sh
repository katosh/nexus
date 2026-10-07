#!/usr/bin/env bash
# monitor/_pane-state-codex.sh — classify an OpenAI Codex TUI pane
# (your-org/nexus-code#1640, layer 2). Sourced by monitor/pane-state.sh.
#
# WHY A SEPARATE CLASSIFIER, AND WHY IT RUNS BEFORE THE CLAUDE LADDER.
# Every Claude-Code screen predicate in pane-state.sh anchors on Claude's
# chrome: the `❯<NBSP>` input row, the `↓ N tokens` counter, Claude's dialog
# wording. A Codex pane matches none of them, and before this file the ladder
# answered for it in the DANGEROUS direction: a Codex process at the pane root
# failed `_pid_runs_claude`, and the liveness gate reported
# `state=absent evidence=tree-empty-past-grace` — on the kill allowlist — for
# a Codex worker that was mid-turn. So a Codex pane is classified HERE, from
# Codex's own measured chrome, and never falls through to a ladder that cannot
# read it.
#
# THE VOCABULARY IS pane-state.sh's OWN. This file adds no state token (a new
# token is exactly what a permissive default arm drops, CLAUDE.md), only the
# existing ones: busy, blocked, working-background, user-typing, idle,
# unknown — plus the existing
# `queued=1` field and a `harness=codex` field (a FIELD, so no consumer that
# parses the state token needs an audit).
#
# ARM ORDER IS DENY-FIRST (CLAUDE.md, ARM-ORDER-SHADOWING): every arm that
# yields a never-kill state (busy, blocked, user-typing, unknown) is decided
# BEFORE the one arm that yields a kill-allowlisted state (idle), and idle
# requires a POSITIVE match on the idle composer. Anything unrecognised is
# `unknown` — off the allowlist — never idle.
#
# MEASURED CHROME (codex-cli 0.156.1, real captures in
# monitor/watcher/fixtures/codex-*.ansi, taken 2026-09-26 from real TUIs on a
# private tmux server, against the real API and against
# monitor/codex-harness/mock-responses.py):
#
#   composer        ESC[1m›ESC[0m… then EITHER ESC[2m<placeholder> (blank)
#                   OR plain typed text. Chat-history user lines are
#                   ESC[1;2m› (bold+DIM) and dialog selectors ESC[1;7m›
#                   (bold+REVERSE), so neither can pass for the composer.
#   busy            `• Working (Ns • esc to interrupt)` / `◦ Working (…)`,
#                   the bullet alternating as a spinner; `· Running hook`,
#                   `· N background terminal running` may follow. And while
#                   the final answer STREAMS: no Working line at all, only a
#                   braille spinner on the status line (arm 4b).
#   background      `N background terminal(s) running` with no spinner: the
#                   turn ended, a job it started did not (arm 2b).
#   queued          `Messages to be submitted after next tool call`
#   dialogs         `Trust this folder?`, `Hooks need review`,
#                   `Update available`, `Meet GPT-… / Use existing model`,
#                   the login chooser (`Sign in with ChatGPT`,
#                   `Provide your own API key`), and any ESC[1;7m› selector
#                   or `enter continue|confirm · esc …` footer.
#
# COVERAGE BOUNDARY, stated rather than implied: the approval and
# request_user_input dialogs were NOT captured (workers run with approvals
# bypassed, and no scenario produced a question). They are covered only by
# the GENERIC selector/footer arms, which fire on any Codex menu; a dialog
# with neither a reverse-video selector nor that footer would read `unknown`
# (safe), not `blocked`.

# _codex_last_composer_ansi <ansi> — the LAST composer row (bold `›`, not
# bold+dim, not bold+reverse), or nothing. The composer is at the bottom of
# the screen; the last match is the live one.
_codex_last_composer_ansi() {
    printf '%s\n' "$1" | awk '
        index($0, "\033[1m\342\200\272") { row = $0 }
        END { if (row != "") print row }'
}

# _classify_codex_pane <ansi> <plain> [hb_state] [hb_fresh] [hb_open]
#   prints: <state>[<TAB><extra fields>]
#   hb_state/hb_fresh: the worker heartbeat's state and 1 if it is fresh
#   (codex workers write it through monitor/codex-hook.sh). hb_open: 1 if the
#   heartbeat says a turn is OPEN — UserPromptSubmit/PostToolUse seen, no Stop
#   after it — however old (bounded by the caller). Heartbeat evidence can
#   only move a verdict AWAY from idle, never toward it.
_classify_codex_pane() {
    local ansi="$1" plain="$2" hb_state="${3:-}" hb_fresh="${4:-0}" hb_open="${5:-0}"
    local tail
    tail=$(printf '%s\n' "$plain" | tail -n 30)

    if [[ -z "$(printf '%s' "$plain" | tr -d '[:space:]')" ]]; then
        printf 'unknown\treason=codex-blank-screen harness=codex'
        return 0
    fi

    # (1) BUSY — the turn spinner. Checked first: a working pane may ALSO show
    #     a composer with typed text (the operator typing ahead), and that is
    #     still a live turn.
    if grep -qE '(^|[[:space:]])[•◦] Working \(' <<<"$tail" \
       || grep -qF 'esc to interrupt)' <<<"$tail"; then
        if grep -qF 'Messages to be submitted after next tool call' <<<"$tail"; then
            printf 'busy\tqueued=1 harness=codex'
        else
            printf 'busy\tharness=codex'
        fi
        return 0
    fi
    if grep -qF 'Messages to be submitted after next tool call' <<<"$tail"; then
        printf 'busy\tqueued=1 harness=codex'
        return 0
    fi

    # (2) BLOCKED — a dialog owns the screen. Named dialogs first, for the
    #     reason field; then the generic menu arms.
    local reason=""
    if grep -qF 'Trust this folder?' <<<"$tail"; then reason=codex-folder-trust
    elif grep -qF 'Hooks need review' <<<"$tail"; then reason=codex-hooks-review
    elif grep -qF 'Update available' <<<"$tail"; then reason=codex-update-prompt
    elif grep -qF 'Sign in with ChatGPT' <<<"$tail" || grep -qF 'Provide your own API key' <<<"$tail"; then reason=codex-login
    elif grep -qF 'Use existing model' <<<"$tail"; then reason=codex-model-migration
    elif grep -qF $'\e[1;7m\xe2\x80\xba' <<<"$ansi"; then reason=codex-menu
    elif grep -qE 'enter (continue|confirm)|enter/esc confirm' <<<"$tail"; then reason=codex-menu-footer
    fi
    # `overlay=`, not `reason=`: pane-state.sh's contract is that every
    # blocked verdict names its overlay (test-pane-state.sh's overlay sweep).
    # And `overlay=` SELECTS: spawn-worker.sh's trust recovery matches
    # `overlay=workspace-trust` exactly and then SENDS KEYSTROKES. Every Codex
    # kind is therefore `codex-`-prefixed, so no existing matcher can select
    # it and no Claude recovery path can type into a Codex dialog.
    if [[ -n "$reason" ]]; then
        if [[ "$reason" == codex-login ]]; then
            printf 'blocked\toverlay=%s auth=login harness=codex' "$reason"
        else
            printf 'blocked\toverlay=%s harness=codex' "$reason"
        fi
        return 0
    fi

    # (2b) A BACKGROUND TERMINAL outlives the turn (skeptic F2, #1640):
    #     Codex yields a long command to the background, ends the turn, and
    #     the footer keeps `N background terminal(s) running`. The job runs
    #     OUTSIDE the pane's session, so neither the process walk nor the
    #     Stop-fed heartbeat can see it, and retiring the window kills it.
    #     `working-background` is the existing never-kill token the Claude
    #     ladder emits for the same situation. Decided before the composer,
    #     because the composer under that footer IS the idle one.
    local bgn
    bgn=$(grep -oE '[0-9]+ background terminals? running' <<<"$tail" | tail -n1 | grep -oE '^[0-9]+')
    if [[ -n "$bgn" && "$bgn" -gt 0 ]]; then
        printf 'working-background\tbg=%s reason=codex-background-terminal harness=codex' "$bgn"
        return 0
    fi

    # (3) The composer decides typed vs idle. No composer at all: unknown.
    local comp rest
    comp=$(_codex_last_composer_ansi "$ansi")
    if [[ -z "$comp" ]]; then
        printf 'unknown\treason=codex-no-composer harness=codex'
        return 0
    fi
    # Everything after the bold `›` and its reset codes.
    rest="${comp#*$'\xe2\x80\xba'}"
    # A dim run right after the `›` is the placeholder; strip SGR to test for
    # remaining typed text.
    local rest_plain
    rest_plain=$(printf '%s' "$rest" | sed -e $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g')
    if [[ -n "$(printf '%s' "$rest_plain" | tr -d '[:space:]')" ]] \
       && ! grep -qE $'^(\e\\[[0-9;]*m)* *\e\\[2m' <<<"$rest"; then
        printf 'user-typing\tinput=typed harness=codex'
        return 0
    fi

    # (4) A fresh busy heartbeat outranks an idle-looking screen (the hook
    #     fires before the spinner paints).
    if [[ "$hb_fresh" == 1 ]] && [[ "$hb_state" == busy || "$hb_state" == user_prompt ]]; then
        printf 'busy\treason=codex-heartbeat harness=codex'
        return 0
    fi

    # (4b) THE STREAMING PHASE (skeptic F1, #1640). While Codex streams its
    #      final answer it draws NO `Working (…)` line, only the answer's words
    #      over an idle-looking composer — and no hook fires during a stream,
    #      so a stream starting >30 s after the last hook outlived the fresh
    #      heartbeat above. Two independent signals, MEASURED on the real TUI:
    #
    #   * the STATUS LINE under the composer carries a braille spinner,
    #     `… · <path> · ⠋`, for the whole turn — streaming included — and none
    #     at rest. After an Esc it lingers ≥10 s and is gone by 30 s (measured),
    #     so it errs toward busy briefly and clears itself;
    #   * the heartbeat says the turn is OPEN (hb_open). Esc and a failed turn
    #     never fire Stop (measured: the heartbeat stays `user_prompt`
    #     forever), so an open turn alone would wedge `busy`; it counts only
    #     while NO `■` terminal line (`■ Conversation interrupted…`,
    #     `■ Quota exceeded…`, `■ exceeded retry limit…`) follows the last user
    #     message on screen.
    local status
    status=$(printf '%s\n' "$plain" | awk '/^› /{c=NR} {l[NR]=$0} END {for (i=c+1;i<=NR;i++) if (l[i] ~ /[^[:space:]]/) {print l[i]; break}}')
    # BYTES, not a character range: a `[⠀-⣿]` range depends on the locale
    # (measured: it matched nothing in a C-locale probe). U+2800-U+28FF is
    # E2 A0-A3 xx in UTF-8; `·` is C2 B7.
    if LC_ALL=C grep -qE $'\xc2\xb7 \xe2[\xa0-\xa3]' <<<"$status"; then
        printf 'busy\treason=codex-status-spinner harness=codex'
        return 0
    fi
    if [[ "$hb_open" == 1 ]]; then
        # Lines after the LAST user message (the second-to-last `› ` row; the
        # last is the composer): a `■` among them means the turn ENDED.
        local ended
        ended=$(printf '%s\n' "$plain" | awk '/^› /{p=q; q=NR} {l[NR]=$0} END {e=0; for (i=p+1;i<q;i++) if (l[i] ~ /^■ /) e=1; print e}')
        if [[ "$ended" != 1 ]]; then
            printf 'busy\treason=codex-turn-open harness=codex'
            return 0
        fi
    fi

    # (5) IDLE — only now, and only on a positive idle composer.
    if [[ -z "$(printf '%s' "$rest_plain" | tr -d '[:space:]')" ]]; then
        printf 'idle\tinput=blank harness=codex'
    else
        printf 'idle\tinput=blank placeholder=1 harness=codex'
    fi
    return 0
}
