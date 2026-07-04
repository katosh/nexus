#!/usr/bin/env bash
# Build synthetic fixtures for state-classifier states that are awkward
# to capture live (user-typing requires the user to actually be typing;
# blocked overlays only appear when a permission prompt fires).
#
# These fixtures replicate the exact byte sequences Claude Code emits.
# Run from the worktree root: monitor/watcher/fixtures/synthesize.sh

set -euo pipefail
cd "$(dirname "$0")"

ESC=$'\x1b'
NBSP=$'\xc2\xa0'

# --- idle: empty input box, past-tense spinner, no token counter -----------
{
    printf '%s\n\n' "${ESC}[39m● Routine watcher emit acknowledged. Workers queued.${ESC}[0m"
    printf '%s\n\n' "${ESC}[38;5;246m✻ Brewed for 12s${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    # Empty input row: chevron + NBSP + reverse-video space + reset.
    printf '%s\n' "${ESC}[38;5;246m❯${NBSP}${ESC}[7m ${ESC}[0m${ESC}[39m${ESC}[49m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '  ${ESC}[38;5;246m◉ Opus 4.7 (1M context) │ █▎░░░░░░░▓ 124K/1.0M${ESC}[0m\n'
    printf '  ${ESC}[38;5;246m-- INSERT -- ⏵⏵ bypass permissions on${ESC}[0m\n'
} > idle-empty-synthetic.ansi

# --- user-typing: bright-text marker on input row --------------------------
# Per the research-agent's note: typed prefix renders bright (\x1b[38;5;231m)
# with the cursor cell at the end of the typed text.
{
    printf '%s\n\n' "${ESC}[38;5;246m✻ Cogitated for 8s${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    # `❯<NBSP>` then bright "review the diff" then reverse-video cursor at end.
    printf '%s\n' "${ESC}[39m❯${NBSP}${ESC}[38;5;231mreview the diff${ESC}[0m${ESC}[7m ${ESC}[0m${ESC}[39m${ESC}[49m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '  ${ESC}[38;5;246m-- INSERT -- ⏵⏵ bypass permissions on${ESC}[0m\n'
} > user-typing-synthetic.ansi

# --- user-typed prefix + autosuggest tail (cursor between) -----------------
# The orchestrator should classify this as user-typing (bright wins), not
# autosuggest-only — even though the autosuggest dim-marker is present.
{
    printf '%s\n\n' "${ESC}[38;5;246m✻ Brewed for 4s${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    # `❯<NBSP>` then bright "mer" + reverse-video "g" + dim "e the PR".
    printf '%s\n' "${ESC}[39m❯${NBSP}${ESC}[38;5;231mmer${ESC}[7mg${ESC}[0;2m${ESC}[39m${ESC}[49me the PR${ESC}[0m${ESC}[39m${ESC}[49m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '  ${ESC}[38;5;246m-- INSERT -- ⏵⏵ bypass permissions on${ESC}[0m\n'
} > user-typing-with-autosuggest-tail-synthetic.ansi

# --- blocked: permission prompt --------------------------------------------
# Mirrors the exact strings _unstick.sh anchors on.
{
    printf '%s\n' '● Bash(cat /etc/shadow)'
    printf '%s\n' '  Do you want to proceed?'
    printf '%s\n' "${ESC}[7m❯ 1. Yes${ESC}[0m"
    printf '%s\n' '  2. Yes, and allow access to /etc/shadow'
    printf '%s\n' '  3. No'
} > blocked-permission-synthetic.ansi

# --- blocked: rate-limit menu ----------------------------------------------
{
    printf '%s\n' 'Claude usage limit reached.'
    printf '%s\n' 'What do you want to do?'
    printf '%s\n' "${ESC}[7m❯ 1. Stop and wait for limit to reset${ESC}[0m"
    printf '%s\n' '  2. Switch to a different model'
} > blocked-ratelimit-synthetic.ansi

# --- blocked: AskUserQuestion chip-bar dialog (Case D, dialog-guard) -------
# Shape rendered by Claude Code when the agent dispatches the
# `AskUserQuestion` tool. The chip-row at the top carries the
# selectable chips + ✔ Submit; the numbered options below match the
# question's choices, with the always-present penultimate `Type
# something.` and trailing `Chat about this` (separated by a
# horizontal rule). The two literal strings `Type something.` and
# `Chat about this` together form the load-bearing detection
# signature — see `_has_askuq_overlay` in `monitor/pane-state.sh`
# and the matching Case-D branch in `monitor/watcher/_unstick.sh`.
{
    printf '%s\n' "${ESC}[2m←${ESC}[0m  ${ESC}[7m☐ option 1${ESC}[0m  ☐ option 2  ✔ Submit  ${ESC}[2m→${ESC}[0m"
    printf '\n'
    printf 'How should we proceed with the migration?\n'
    printf '\n'
    printf '%s\n' "${ESC}[7m❯ 1. Run the backfill in batches${ESC}[0m"
    printf '%s\n' '  2. Run the backfill in one pass'
    printf '%s\n' '  3. Defer the migration to next sprint'
    printf '%s\n' '  4. Type something.'
    printf '%s\n' "${ESC}[2m─────────────────────────────────────────────${ESC}[0m"
    printf '%s\n' '  5. Chat about this'
} > blocked-askuq-synthetic.ansi

# --- over-limit: canonical notice (issue #87) ------------------------------
# Renders in place of the input box when claude's weekly Opus limit is
# exhausted. The middle-dot separator and the (timezone) parenthetical
# are part of the canonical shape; the second line is the in-app
# "/extra-usage" hint Claude Code prints.
{
    printf '%s\n\n' "${ESC}[38;5;246m✻ Brewed for 1h 12m${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "${ESC}[39mYou've hit your limit · resets 3am (America/Los_Angeles)${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;246m/extra-usage to finish what you're working on.${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '  ${ESC}[38;5;246m◉ Opus 4.7 (1M context) │ █▎░░░░░░░▓ 124K/1.0M${ESC}[0m\n'
} > over-limit-canonical-synthetic.ansi

# --- over-limit: terse variant (no timezone parenthetical) -----------------
# Some Claude Code versions render the bare time without the (tz). Same
# detection key (the "You've hit your limit · resets <time>" pair) but
# tests reset_at extraction on the shorter shape.
{
    printf '%s\n\n' "${ESC}[38;5;246m✻ Cogitated for 22m${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "${ESC}[39mYou've hit your limit · resets 11pm${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;246m/extra-usage to finish what you're working on.${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
} > over-limit-terse-synthetic.ansi

# --- idle pane with the over-limit text in scrollback (false-positive guard)
# The user's last turn referenced the over-limit message verbatim — but
# the current pane is idle (empty input box). pane-state.sh must NOT
# classify this as over-limit because the trigger text scrolled out of
# the bottom-15-row anchor window. We pad with filler lines to push the
# scrollback reference above the anchor.
{
    printf '%s\n' "${ESC}[39m● user pasted: \"You've hit your limit · resets 3am (America/Los_Angeles)\"${ESC}[0m"
    printf '%s\n' "${ESC}[39m● Worker: I see — that's the canonical over-limit shape.${ESC}[0m"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
        printf '%s\n' "${ESC}[38;5;240m  ... padding row $i ...${ESC}[0m"
    done
    printf '%s\n\n' "${ESC}[38;5;246m✻ Brewed for 8s${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    # Empty input row: chevron + NBSP + reverse-video space + reset.
    printf '%s\n' "${ESC}[38;5;246m❯${NBSP}${ESC}[7m ${ESC}[0m${ESC}[39m${ESC}[49m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
} > idle-overlimit-text-in-scrollback-synthetic.ansi

echo "synthesized $(ls -1 *-synthetic.ansi | wc -l) fixtures"
