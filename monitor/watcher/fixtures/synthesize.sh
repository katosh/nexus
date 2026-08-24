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

# --- blocked: Bypass Permissions warning modal (your-org/nexus-code#768) ---
# What a boot renders when `skipDangerousModePermissionPrompt` is absent from
# `$CLAUDE_CONFIG_DIR/settings.json`. The binary MIGRATES the older
# `.claude.json` key into that file on first boot and DELETES the original, so
# any between-boot rewrite of settings.json that does not re-supply the key
# wedges the next boot here.
#
# Detection (`_has_bypass_permissions_modal` in monitor/pane-state.sh) needs
# `Bypass Permissions mode` + `Yes, I accept` for the SHAPE and a
# bottom-anchored `Enter to confirm` for LIVE-ness. The footer must therefore
# stay in the last three non-blank lines of this fixture — that is the
# property, not decoration.
{
    printf '%s\n' '  WARNING: Claude Code running in Bypass Permissions mode'
    printf '\n'
    printf '%s\n' "${ESC}[7m❯ 1. No, exit${ESC}[0m"
    printf '%s\n' '    2. Yes, I accept'
    printf '\n'
    printf '%s\n' '  Enter to confirm · Esc to cancel'
} > blocked-bypass-permissions-synthetic.ansi

# --- idle: a pane merely QUOTING the bypass modal (negative control) -------
# The #768 text is quoted in the issue, in pane-state.sh's own comment, and in
# this file — so an agent reading any of them has every literal on screen. The
# shape literals alone would fire; what keeps this pane `idle` is that its REPL
# chrome (`❯<NBSP>` input row + status line) sits BELOW the quoted footer,
# pushing `Enter to confirm` out of the bottom slice. Deleting the two trailing
# rows here turns this fixture into a false positive, which is exactly the
# regression the live-ness guard exists to prevent.
{
    printf '%s\n' '● Read(reports/nexus_2026-08-07_probe.md)'
    printf '%s\n' '  The worker wedged on this dialog:'
    printf '%s\n' '    WARNING: Claude Code running in Bypass Permissions mode'
    printf '%s\n' '    ❯ 1. No, exit'
    printf '%s\n' '      2. Yes, I accept'
    printf '%s\n' '    Enter to confirm · Esc to cancel'
    printf '%s\n' '  Re-supplying skipDangerousModePermissionPrompt fixes it.'
    printf '\n'
    printf '%s\n' "${ESC}[39m❯${NBSP}${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '  ${ESC}[38;5;246m⏵⏵ bypass permissions on${ESC}[0m\n'
} > idle-bypass-modal-quoted-synthetic.ansi

# --- idle: the BOUNDARY pane, constructed by the #776 skeptic ---------------
# The attack that defeated the first version of the live-ness guard. Identical
# in kind to the fixture above, but with only TWO non-blank chrome rows below
# the quoted footer instead of four — so the footer lands inside a `tail -n 3`
# window and the bottom-slice margin alone classifies it `blocked`.
#
# Kept as a fixture rather than fixed-and-forgotten because it marks the
# BOUNDARY, which the non-vacuity mutation does not probe: the mutation proves
# the guard does something, this proves it does the right thing at the edge
# where it was shown to fail. What rejects it now is structural, not a margin —
# a REPL input row (`❯<NBSP>`) below the footer means the pane is a running
# agent quoting the modal, not a boot replaced by it.
{
    printf '%s\n' '● Read(reports/nexus_2026-08-07_probe.md)'
    printf '%s\n' '    WARNING: Claude Code running in Bypass Permissions mode'
    printf '%s\n' '    ❯ 1. No, exit'
    printf '%s\n' '      2. Yes, I accept'
    printf '%s\n' '    Enter to confirm · Esc to cancel'
    printf '%s\n' "${ESC}[39m❯${NBSP}${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
} > idle-bypass-modal-quoted-boundary-synthetic.ansi

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

# --- over-limit: retry-exhaustion API-error render (your-org/nexus-code#571) --
# The OTHER genuine over-limit render. When retries on a weekly-limit 429 are
# exhausted, Claude Code paints the notice as an `● API Error` message line, so
# the headline sits MID-LINE behind `● API Error: Request rejected (429) · `
# (row captured from cc-harness CI run 30567702742). A bare `^[[:space:]]*`
# line-start anchor (the reverted #591) MISSES this — an invisible miss on the
# render the repo's own real-binary test pins. This fix's clean-lead-in gate
# whitelists the client's `API Error` decoration, so it parks.
{
    printf '%s\n\n' "${ESC}[38;5;246m✻ Brewed for 2h 4m${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "${ESC}[31m●${ESC}[0m API Error: Request rejected (429) · You've hit your weekly limit · resets 3am (America/Los_Angeles)"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;246m❯${NBSP}${ESC}[7m ${ESC}[0m"
    printf '  ${ESC}[38;5;246m◉ Opus 4.8${ESC}[0m\n'
} > over-limit-apierror-midline-synthetic.ansi

# --- idle pane QUOTING the notice, INSIDE the bottom-15 window ---------------
# Companion negative control to the scrollback guard above, but the quote is
# NOT pushed out of the anchor window — so POSITION alone does not reject it.
# The bulleted `● user pasted: "…"` line reproduces the notice as message
# content; the CLEAN-LEAD-IN gate is what must reject it. The OLD two-grep
# detector (headline anywhere + resets anywhere) WOULD have false-parked this
# healthy idle worker (your-org/nexus-code#571).
{
    printf '%s\n' "${ESC}[39m● user pasted: \"You've hit your weekly limit · resets 3am (America/Los_Angeles)\"${ESC}[0m"
    printf '%s\n' "${ESC}[39m● Worker: right, that's the canonical over-limit shape; keeping on task.${ESC}[0m"
    printf '%s\n\n' "${ESC}[38;5;246m✻ Brewed for 12s${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;246m❯${NBSP}${ESC}[7m ${ESC}[0m${ESC}[39m${ESC}[49m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '  ${ESC}[38;5;246m◉ Opus 4.8${ESC}[0m\n'
} > idle-overlimit-quoted-relay-bottomrows-synthetic.ansi

# --- OSC 8 hyperlinks in the status-line footer (cc-update rigor fix) ------
# Claude Code's footer can render clickable badges via OSC 8 hyperlinks:
#   ESC ] 8 ; ; <url> ESC \  <anchor text>  ESC ] 8 ; ; ESC \
# pane-state.sh's _strip_ansi was CSI-only, so those bytes survived into
# the plain text that _footer_handle_counts parses — landing exactly on
# the ` · N shell[s] · ` boundary the handle-count regex anchors on.
#
# These two fixtures are the differential pair for that fix, and they
# exercise it INDEPENDENTLY of the local tmux version (the live-pane path
# is version-gated: tmux < 3.2 swallows OSC 8 and never re-emits it from
# `capture-pane -e`; tmux >= 3.2 does re-emit it).
OSC_PR="${ESC}]8;;https://github.com/your-org/nexus-code/pull/512${ESC}\\PR #512${ESC}]8;;${ESC}\\"
OSC_SHELLS="${ESC}]8;;file:///proc/self/task${ESC}\\2 shells${ESC}]8;;${ESC}\\"

# (A) POSITIVE: the handle count itself is wrapped in a hyperlink. With a
#     CSI-only strip the `·`→digit boundary is broken by the raw escape
#     bytes and the count is MISSED (classified idle); with OSC stripping
#     it reads `· 2 shells ·` and classifies working-background.
{
    printf '%s\n\n' "${ESC}[39m● Started the build pipeline. Logs streaming to ./build.log.${ESC}[0m"
    printf '%s\n\n' "${ESC}[38;5;246m✻ Cooked for 32s${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;246m❯${NBSP}${ESC}[7m ${ESC}[0m${ESC}[39m${ESC}[49m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m◉ Opus 4.7 (1M context) │ █▋░░░░░░░▓ 78K/1.0M │ ⚡100% │ \$4.12 +18/-3${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m⏵⏵ bypass permissions on · ${OSC_PR} · ${OSC_SHELLS} · ← for agents${ESC}[0m"
} > working-background-osc8-prbadge-synthetic.ansi

# (B) NEGATIVE CONTROL: the SAME PR badge, but no handle count anywhere.
#     Stripping OSC must not manufacture one out of the URL's digits —
#     this pane is genuinely idle and must stay idle. Without this, fix
#     (A) could be "passing" by making _footer_handle_counts fire on
#     anything containing a hyperlink.
{
    printf '%s\n\n' "${ESC}[39m● Opened the PR and linked it from the tracking issue.${ESC}[0m"
    printf '%s\n\n' "${ESC}[38;5;246m✻ Brewed for 11s${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;246m❯${NBSP}${ESC}[7m ${ESC}[0m${ESC}[39m${ESC}[49m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m◉ Opus 4.7 (1M context) │ █▎░░░░░░░▓ 124K/1.0M${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m⏵⏵ bypass permissions on · ${OSC_PR} · ← for agents${ESC}[0m"
} > idle-osc8-prbadge-nocounts-synthetic.ansi


# ── your-org/nexus-code#801 — DIM BOX CHROME on the input row ──────────────
# The renderer property `_detect_dim_run` rests on and nothing checked: that
# Claude Code does not draw a dim border INSIDE the captured input row. It
# does not today (9 of 9 idle captures here carry no dim run after the
# chevron; the rules it draws are `\x1b[38;5;244m`, not a whole-parameter 2).
# These three fixtures pin the behaviour for the day it does, so the guard
# stops depending on somebody else's cosmetic choice.
#
# The border glyph is `│` in a DIM (SGR 2) run at BOTH ends of the row —
# left border before the chevron, closing border after it. That is the exact
# shape that made the integration stub classify `autosuggest-only` forever
# (`#798`), where `state=idle` was UNREACHABLE.

# (A) NEGATIVE CONTROL — an EMPTY input box that happens to be drawn with a
#     dim closing border MUST read `idle` / `input=blank`. This is the case
#     no fixture covered, which is how the defect went unnoticed. `-- INSERT --`
#     is present deliberately: it routes the row through the SECOND dim-keyed
#     reader (`_input_row_typed_text`) as well as through `_detect_dim_run`.
{
    printf '%s\n\n' "${ESC}[39m● Verdict landed. Holding for the skeptic delta.${ESC}[0m"
    printf '%s\n\n' "${ESC}[38;5;246m✻ Brewed for 19s${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "${ESC}[2m│${ESC}[0m ${ESC}[38;5;246m❯${NBSP}${ESC}[7m ${ESC}[0m${ESC}[39m${ESC}[49m                    ${ESC}[2m│${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m◉ Opus 5 │ █▎░░░░░░░▓ 124K/1.0M${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m-- INSERT -- ⏵⏵ bypass permissions on${ESC}[0m"
} > idle-empty-dim-box-border-synthetic.ansi

# (B) POSITIVE CONTROL — REAL ghost text (the verbatim bytes captured from
#     window `spawnpath` on 2026-08-08: a bare-dim run with no reverse-video
#     cursor, the `#626` arm-(b) rendering) inside the SAME dim-bordered box
#     MUST still read `autosuggest-only` / `input=ghost`. Without this, a fix
#     that simply stopped detecting dim runs would pass fixture (A).
{
    printf '%s\n\n' "${ESC}[39m● Four PRs merged, issues closed.${ESC}[0m"
    printf '%s\n\n' "${ESC}[38;5;246m✻ Brewed for 22s${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "${ESC}[2m│${ESC}[0m ${ESC}[39m❯${NBSP}${ESC}[2mverdict landed — merge all four and close the issues${ESC}[0m${ESC}[39m${ESC}[49m   ${ESC}[2m│${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m◉ Opus 5 │ █▎░░░░░░░▓ 488K/1.0M${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m-- INSERT -- ⏵⏵ bypass permissions on${ESC}[0m"
} > autosuggest-dim-box-border-synthetic.ansi

# (C) THE KILL-AXIS CONTROL — vim INSERT mode, REAL OPERATOR TEXT, no
#     bright-white marker (which is the whole reason `#603` added the
#     `-- INSERT --` refinement), inside a dim-bordered box. MUST read
#     `user-typing`.
#
#     This is the dangerous half of `#801` and the reason the fix touches
#     `_input_row_typed_text` too: that reader cuts the row at its FIRST dim
#     run, and a dim LEFT border sits BEFORE the chevron — so the cut takes
#     the chevron with it, the tail reads empty, and the refinement never
#     fires. MEASURED pre-fix verdict on this exact fixture:
#
#         state=autosuggest-only  input=ghost
#
#     — the border satisfies `_detect_dim_run`, and that branch is tested
#     BEFORE `empty_input`, so the row never reaches the empty-box arm. Both
#     halves of that answer are wrong in the expensive direction:
#     `autosuggest-only` is on `bk_pane_kill_authorized`'s allowlist, and
#     `input=ghost` is the token that tells an orchestrator this text is
#     model-generated and safe to paste over. It is the operator's.
{
    printf '%s\n\n' "${ESC}[39m● Ready for your call on the merge order.${ESC}[0m"
    printf '%s\n\n' "${ESC}[38;5;246m✻ Brewed for 7s${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "${ESC}[2m│${ESC}[0m ${ESC}[39m❯${NBSP}merge the PR${ESC}[7m ${ESC}[0m${ESC}[39m${ESC}[49m           ${ESC}[2m│${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m◉ Opus 5 │ █▎░░░░░░░▓ 210K/1.0M${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m-- INSERT -- ⏵⏵ bypass permissions on${ESC}[0m"
} > user-typing-vim-dim-box-border-synthetic.ansi


# ── #801 skeptic F1 — ADJACENT dim runs (the RUN-STRUCTURE axis) ───────────
# The first `#801` fix stripped chrome with a single `s///g` pass, and branch 1
# consumes the terminating ESC. `g` resumes AFTER the emitted byte, so when a
# dim run's terminator is the NEXT dim introducer, that run is never
# re-examined — adjacent runs are stripped alternately and ONE SURVIVES. A
# survivor is a dim run carrying a visible character, i.e. `#801` intact.
#
# The glyph manifest could not catch this: it varies WHICH glyph, and the
# mechanism also varies HOW MANY SGR introducers the renderer emits across the
# border. Both fixtures below are DOUBLED (`$DIM│$DIM│`), which is the minimum
# reproduction, and they mirror (A) and (C) above one-for-one so the pair
# isolates run-structure with the glyph held constant.

# (D) doubled border, EMPTY box → must read `idle`. The `#801` harm restated on
#     the second axis: pre-loop this read `autosuggest-only input=ghost`.
{
    printf '%s\n\n' "${ESC}[39m● Verdict landed. Holding for the skeptic delta.${ESC}[0m"
    printf '%s\n\n' "${ESC}[38;5;246m✻ Brewed for 19s${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "${ESC}[2m│${ESC}[2m│${ESC}[0m ${ESC}[38;5;246m❯${NBSP}${ESC}[7m ${ESC}[0m${ESC}[39m${ESC}[49m              ${ESC}[2m│${ESC}[2m│${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m◉ Opus 5 │ █▎░░░░░░░▓ 124K/1.0M${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m-- INSERT -- ⏵⏵ bypass permissions on${ESC}[0m"
} > idle-empty-adjacent-dim-border-synthetic.ansi

# (E) doubled LEFT border, vim INSERT, REAL OPERATOR TEXT → must read
#     `user-typing`. This is the dangerous half: pre-loop it read
#     `state=empty input=?`, which is exactly the reading `#603` added
#     `_input_row_typed_text` to prevent and which `#657` names as an
#     absorbing board-stall. Not a kill (`empty` is refused by
#     `bk_pane_kill_authorized`, and `input=?` is treated as an operator
#     draft) — both readings fail SAFE, and the cost is the stall.
{
    printf '%s\n\n' "${ESC}[39m● Ready for your call on the merge order.${ESC}[0m"
    printf '%s\n\n' "${ESC}[38;5;246m✻ Brewed for 7s${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "${ESC}[2m│${ESC}[2m│${ESC}[0m ${ESC}[39m❯${NBSP}git status is what I typed${ESC}[7m ${ESC}[0m${ESC}[39m${ESC}[49m   ${ESC}[2m│${ESC}[2m│${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m◉ Opus 5 │ █▎░░░░░░░▓ 210K/1.0M${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m-- INSERT -- ⏵⏵ bypass permissions on${ESC}[0m"
} > user-typing-vim-adjacent-dim-border-synthetic.ansi


# (F) THE KILL-AXIS WORST CASE — a TRIPLED dim left border, vim INSERT, real
#     operator text. Measured against the pre-loop classifier (92b394b):
#
#         doubled  ->  state=empty  input=?          refused by the kill gate
#         TRIPLED  ->  state=idle   input=blank      AUTHORISED by the kill gate
#
#     The skeptic that found the adjacent-run gap assessed it "not a kill
#     hazard", having probed the `empty`/`?` readings — which do fail safe.
#     That is true for TWO introducers and false for THREE: the third
#     survivor lands the row on the empty-box arm instead of the dim-run arm,
#     and `idle` is on `bk_pane_kill_authorized`'s allowlist while `empty` is
#     not. `input=blank` compounds it — that token says "nothing pending,
#     safe to paste" about a live operator's typed draft.
#
#     Same lesson one turn further: the severity was measured on the axis the
#     PROBE varied on (which reading) rather than the axis the MECHANISM
#     varies on (how many introducers). Pinned here so it cannot regress
#     quietly to a kill-authorising state.
{
    printf '%s\n\n' "${ESC}[39m● Ready for your call on the merge order.${ESC}[0m"
    printf '%s\n\n' "${ESC}[38;5;246m✻ Brewed for 7s${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "${ESC}[2m│${ESC}[2m│${ESC}[2m│${ESC}[0m ${ESC}[39m❯${NBSP}git status is what I typed${ESC}[7m ${ESC}[0m${ESC}[39m${ESC}[49m  ${ESC}[2m│${ESC}[2m│${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m◉ Opus 5 │ █▎░░░░░░░▓ 210K/1.0M${ESC}[0m"
    printf '%s\n' "  ${ESC}[38;5;246m-- INSERT -- ⏵⏵ bypass permissions on${ESC}[0m"
} > user-typing-vim-tripled-dim-border-synthetic.ansi

# =========================================================================
# your-org/nexus-code#896 — the STRUCTURAL select-dialog arm
# (`pane-state.sh:_has_menu_dialog_frame`).
#
# The live instance that motivated it — Claude Code's workspace-trust dialog —
# is NOT synthesized: it is captured from the real binary into
# `blocked-workspace-trust-realmodel.ansi` by
# `monitor/watcher/test-integration/test-realmodel-trust-dialog.sh`, which also
# re-derives it live on every gate run so the committed copy cannot drift into
# fiction. A fixture hand-transcribed from a PR description is a copy, and a
# control that consumes a copy validates its own transcription error.
#
# What IS synthesized here is the surrounding evidence the live capture cannot
# supply: one dialog whose WORDING appears nowhere (proving detection is
# structural, not text-keyed), and four near-miss panes — each failing exactly
# ONE of the arm's three conditions — that must STAY unblocked. Each near-miss
# doubles as the mutation target proving its condition is load-bearing.

# --- blocked: a dialog nobody has enumerated (the CLASS, not the instance) --
# Deliberately invented wording that appears in no Claude Code release, no
# issue, and nowhere else in this repo. If the arm ever regresses to
# text-keying, THIS is the fixture that goes red first — the real trust capture
# would keep passing on its literals long after the class stopped being covered.
# Expected: state=blocked overlay=dialog (the honest generic kind).
{
    printf '\n'
    printf '%s\n' ' Reticulating splines requires elevated access.'
    printf '\n'
    printf '%s\n' ' ❯ 1. Grant access for this session'
    printf '%s\n' '   2. Run without splines'
    printf '%s\n' '   3. Quit'
    printf '\n'
    printf '%s\n' ' Enter to confirm · Esc to cancel'
} > blocked-unnamed-dialog-synthetic.ansi

# --- idle: a running agent QUOTING the trust dialog (negative control) ------
# Fails condition (c): the REPL input row (`❯<NBSP>`) sits BELOW the quoted
# footer, so the pane is an agent DISCUSSING the dialog, not a boot replaced by
# one. Every literal of the real thing is on screen — the wording is quoted in
# the issue, in pane-state.sh's comment, and in this file — so the shape alone
# would fire. Mutation target for condition (c).
{
    printf '%s\n' '● Read(reports/nexus_2026-08-14_trust.md)'
    printf '%s\n' '  Every nested-repo worker booted into this instead of a REPL:'
    printf '%s\n' '    Accessing workspace:'
    printf '%s\n' '    /shared/lab/user/nexus/work/proj'
    printf '%s\n' '    ❯ 1. Yes, I trust this folder'
    printf '%s\n' '      2. No, exit'
    printf '%s\n' '    Enter to confirm · Esc to cancel'
    printf '%s\n' '  pane-state read it as `empty`, so nothing unstuck it.'
    printf '\n'
    printf '%s\n' "${ESC}[39m❯${NBSP}${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
    printf '  ${ESC}[38;5;246m⏵⏵ bypass permissions on${ESC}[0m\n'
} > idle-trust-dialog-quoted-synthetic.ansi

# --- idle: the BOUNDARY quote — footer INSIDE the bottom slice -------------
# The pane above is rejected by the bottom-slice test (its footer sits four
# non-blank rows from the end), so it cannot prove the REPL-row test does
# anything. This one trims the chrome until the footer lands INSIDE the slice,
# leaving the REPL row as the only thing standing between an agent quoting the
# dialog and a phantom `blocked`. Same construction the #776 skeptic used
# against the bypass arm, applied to the arm that inherited its guard.
{
    printf '%s\n' '● Read(reports/nexus_2026-08-14_trust.md)'
    printf '%s\n' '    ❯ 1. Yes, I trust this folder'
    printf '%s\n' '      2. No, exit'
    printf '%s\n' '    Enter to confirm · Esc to cancel'
    printf '%s\n' "${ESC}[39m❯${NBSP}${ESC}[0m"
    printf '%s\n' "${ESC}[38;5;244m─${ESC}[0m"
} > idle-trust-dialog-quoted-boundary-synthetic.ansi

# --- busy: a menu-shaped list with NO navigation footer --------------------
# Fails condition (a). A mid-render busy pane (issue #47 shape: token-counter
# spinner, chevron not yet repainted) whose transcript happens to end on a
# numbered list with a `❯` bullet. No Enter/Esc affordance ⇒ nothing is waiting
# on a keypress. Mutation target for condition (a): drop the footer test and
# this pane becomes a phantom `blocked`.
{
    printf '%s\n' "${ESC}[39m● Ranking the candidate fixes:${ESC}[0m"
    printf '\n'
    printf '%s\n' ' ❯ 1. Seed the trust entry at spawn time'
    printf '%s\n' '   2. Detect the frame in pane-state'
    printf '%s\n' '   3. Both'
    printf '\n'
    printf '%s\n' "${ESC}[38;5;246m✻ Deliberating… (↑ 4.1k tokens · esc to interrupt)${ESC}[0m"
} > busy-menu-no-footer-synthetic.ansi

# --- busy: a navigation footer over a PLAIN numbered list (no `❯` cursor) ---
# Fails the chevron half of condition (b). A list with no highlighted choice is
# a rendering of options, not a pending selection — there is nothing for Enter
# to land on. Mutation target: drop the `❯ N.` requirement and this fires.
{
    printf '%s\n' "${ESC}[39m● The dialog offers three ways out:${ESC}[0m"
    printf '\n'
    printf '%s\n' '   1. Accept and continue'
    printf '%s\n' '   2. Decline and exit'
    printf '\n'
    printf '%s\n' '   Enter to confirm · Esc to cancel'
    printf '%s\n' "${ESC}[38;5;246m✻ Drafting… (↑ 2.2k tokens · esc to interrupt)${ESC}[0m"
} > busy-footer-plain-list-synthetic.ansi

# --- busy: a navigation footer over a SINGLE highlighted option ------------
# Fails the sibling half of condition (b). One option is not a choice; the
# two-option floor is what separates a menu from a decorated line of prose.
# Mutation target: drop the `>= 2` requirement and this fires.
{
    printf '%s\n' "${ESC}[39m● Quoting the tail of the wedged pane:${ESC}[0m"
    printf '\n'
    printf '%s\n' ' ❯ 1. Yes, I trust this folder'
    printf '\n'
    printf '%s\n' ' Enter to confirm · Esc to cancel'
    printf '%s\n' "${ESC}[38;5;246m✻ Summarising… (↑ 8.7k tokens · esc to interrupt)${ESC}[0m"
} > busy-footer-single-option-synthetic.ansi

# --- busy: a lowercase `esc to interrupt` is NOT a dialog footer -----------
# The case-sensitivity probe. This pane pairs a lowercase interrupt hint with a
# real two-option menu above and no REPL row below — i.e. it satisfies
# conditions (b) and (c) outright, and only the footer's CASE keeps it out.
# Mutation target: make the footer match case-insensitively and this fires.
#
# CONSTRUCTED, not captured, and the difference is stated because the four
# `busy-*` near-misses in this block are the one place #896 used synthetic text
# where a live capture was available. Measured against the real 2.1.224 binary
# over a 30 s hang: a live busy pane paints `✻ Smooshing… (16s · ↓ 3 tokens)`
# and contains ZERO occurrences of `esc to …`. The lowercase hint below is drawn
# from `test-integration/stub-claude.sh` and `test-engage-long-exchange.sh`,
# which paint it — so some rendering does — but it is not what 2.1.224 shows.
# These four therefore probe the DETECTOR's conditions in isolation, which is
# what a near-miss is for; they are not evidence about what the binary renders,
# and nothing in the suite treats them as such.
{
    printf '%s\n' "${ESC}[39m● Comparing the two remedies:${ESC}[0m"
    printf '\n'
    printf '%s\n' ' ❯ 1. Structural detection'
    printf '%s\n' '   2. Text-keyed detection'
    printf '\n'
    printf '%s\n' "${ESC}[38;5;246m✻ Weighing… (↓ 12.4k tokens · esc to interrupt)${ESC}[0m"
} > busy-esc-to-interrupt-menu-synthetic.ansi

# --- the panes that fail NO condition: the #896 skeptic's attack -----------
# The four near-misses above each fail EXACTLY ONE condition, which is the right
# design for proving each condition load-bearing — and a structural blind spot,
# because a FALSE POSITIVE needs a pane that fails NONE. There was no such pane
# in the set, so the suite ran 188 pass / 0 fail with a live regression in it.
#
# These two fail none of (a)/(b)/(c) while the agent is demonstrably WORKING.
# Both are panes this workspace renders constantly: the trust dialog's text
# lives in the issue, in `pane-state.sh`'s comment, in this file and in the test
# file, so an agent reading any of them QUOTES it — and `_has_blocked_overlay`
# runs FIRST in the classifier, ahead of every busy signal downstream.
#
# Measured before condition (d) existed:
#   busy, quoting the dialog   →  `busy`            became `blocked overlay=workspace-trust`
#   busy, with a queued msg    →  `busy queued=1`   became `blocked overlay=workspace-trust`
# The second is the one that matters: `queued=1` is what CLAUDE.md cites as
# "input already waiting behind a running turn — do not paste into it again".

# (i) the #47 mid-render regime: a live REPL painting NO chevron at all, which
#     is why condition (c) is inert here. The spinner text is the one MEASURED
#     from the real 2.1.224 binary (30 s hang), not invented.
{
    printf '%s\n' "${ESC}[39m● Read(reports/nexus_2026-08-14_trust.md)${ESC}[0m"
    printf '%s\n' '    ❯ 1. Yes, I trust this folder'
    printf '%s\n' '      2. No, exit'
    printf '%s\n' '    Enter to confirm · Esc to cancel'
    printf '%s\n' "${ESC}[38;5;246m✻ Smooshing… (16s · ↓ 3 tokens)${ESC}[0m"
} > busy-dialog-quoted-midrender-synthetic.ansi

# (ii) the queued-message regime: the placeholder uses `❯` + ASCII space, NOT
#      `❯<NBSP>`, so condition (c) sees no REPL row and is inert. This fixture
#      must classify `busy` AND still carry `queued=1`; test-pane-state.sh
#      asserts the field explicitly, because the filename prefix cannot.
{
    printf '%s\n' "${ESC}[39m● Read(reports/nexus_2026-08-14_trust.md)${ESC}[0m"
    printf '%s\n' '  Every nested-repo worker booted into this instead of a REPL:'
    printf '%s\n' '    ❯ 1. Yes, I trust this folder'
    printf '%s\n' '      2. No, exit'
    printf '%s\n' '    Enter to confirm · Esc to cancel'
    printf '%s\n' "${ESC}[38;5;246m❯ Press up to edit queued messages${ESC}[0m"
} > busy-dialog-quoted-queued-synthetic.ansi

echo "synthesized $(ls -1 *-synthetic.ansi | wc -l) fixtures"
