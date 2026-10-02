#!/usr/bin/env bash
# test-realmodel-overlimit.sh — end-to-end over-limit STATUS + RESET-TIME
# detection and hold→flush, against the REAL `claude` binary and a dummy
# Anthropic API (monitor/cc-harness/mock-backend.py).
#
# The motivating incident (2026-07-14): the account hit its weekly usage
# limit for ~23 h; every turn the orchestrator attempted failed with
#
#     "You've hit your weekly limit · resets 3am (America/Los_Angeles)"
#
# (Quoted on purpose. A bare notice in a shell comment carries no
# gutter, no marker and no quote, so a `cat` of this file onto a pane
# could classify over-limit off this header. Phase B3's repository
# sweep holds that property.)
#
# yet the watcher pasted 63 emits into the frozen pane, because BOTH
# detection channels were dead — the StopFailure hook filtered on a
# field (`.error_type`) the real payload doesn't carry (it carries
# `.error` as a string), and the pane-text scrape matched a fixed
# substring ("You've hit your limit") the real notice ("… weekly limit")
# doesn't contain. This scenario pins the REAL signal end to end so the
# next payload / renderer drift is caught by CI, not by a lost day:
#
#   real claude --(ANTHROPIC_BASE_URL)--> mock 429 rate_limit_error
#        |  real turn fails; the notice text is the error message
#        v
#   real StopFailure hook --> real over-limit-emit.sh --> real stamp
#        |  (.error == "rate_limit" mapping + reset_at parsed from
#        |   last_assistant_message — the STATUS + RESET-TIME
#        |   detection this scenario exists to pin)
#        v
#   production pane-state.sh  --> state=over-limit reset_at=<token>
#        |
#        v
#   production _over_limit.sh --> _over_limit_record → emit gate CLOSED
#        |  (_over_limit_orchestrator_paused — the predicate main.sh
#        |   consults before every paste)
#        v
#   mock flips to success --> real TUI turn COMPLETES --> real Stop
#        |  hook clears the stamp
#        v
#   production wake loop  --> resume brief pasted, row dropped,
#                             emit gate REOPENED (the flush)
#
# Honest scope (mirrors test-realmodel-apispoof.sh):
#   - CC's SUBSCRIPTION over-limit flow — the unified rate-limit
#     headers (anthropic-ratelimit-unified-status: rejected) and the
#     client-composed notice — is gated on claude.ai OAuth scopes
#     inside the binary (confirmed empirically AND in the bundle:
#     the 429 handler early-returns unless the OAuth scope check
#     passes) and is UNREACHABLE under this harness's auth-free
#     bearer token; CC soft-retries any 429 instead. The reachable
#     real signal — and the one this test pins — is retry
#     EXHAUSTION (CLAUDE_CODE_MAX_RETRIES=1): a real turn fails, a
#     real StopFailure fires with error="rate_limit", and
#     last_assistant_message carries the API error text. The
#     StopFailure payload SHAPE (error="rate_limit" as a string +
#     last_assistant_message) is identical between this path and the
#     production subscription path — verified against the 2026-07-14
#     production captures — so the hook contract under test is the
#     production contract.
#   - The emit gate is exercised at its predicate seam
#     (_over_limit_orchestrator_paused), not by running the full
#     watcher loop; the surrounding paste/dedup/resurface machinery is
#     covered by test-emit-*.sh and test-over-limit.sh.
#   - The wake loop's PANE PROBE uses a stubbed pane-state pinned to
#     `idle` — in this sandbox the real TUI does not reliably PAINT a
#     frame pane-state's renderer path can read (the documented
#     cc-harness render gap), so live-pane classification there is
#     nondeterministic. The stamp-consumption path of the REAL
#     pane-state (phase B) does not depend on the renderer and runs
#     against the live pane for real. When the pane DOES paint, an
#     opportunistic renderer-scrape sub-check asserts
#     _detect_over_limit on the real bytes (logged as a note when the
#     frame is blank). Wake-probe classification over every pane
#     state is unit-covered in test-over-limit.sh.
#   - Phase B2 asserts the renderer scrape on limit notices that carry
#     NO reset time (jacob-greene/nexus#173). Those run against fixture
#     bytes, never a live pane: the watcher classifies every real window
#     in the workspace on its normal poll, so painting a limit notice
#     onto a live pane to test the detector can arm a real hold against
#     a real worker.
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary).
# Self-skips cleanly (never a silent pass) where the real binary is
# unavailable. See monitor/cc-harness/README.md.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_test_helpers.sh"
# shellcheck source=_renderer_scrape_check.sh
. "$_self_dir/_renderer_scrape_check.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

cch_skip_if_disabled
cch_setup

REPO_ROOT="$CCH_REPO_ROOT"
PASS=0; FAIL=0

# The canonical notice, verbatim from the 2026-07-14 incident captures
# (monitor/.state/stopfailure-raw-captures.jsonl).
NOTICE="You've hit your weekly limit · resets 3am (America/Los_Angeles)"
WANT_TOKEN="3am_America/Los_Angeles"

# Hermetic nexus root for the hook's stamp writes: the REAL hook script
# runs from the repo, but NEXUS_ROOT/NEXUS_STATE_DIR point into the
# harness tmpdir so nothing touches live state.
OL_ROOT="$CCH_DIR/nexus-root"
OL_STATE="$OL_ROOT/monitor/.state"
mkdir -p "$OL_STATE" "$OL_ROOT/monitor"

echo "=== real-binary over-limit: status + reset detection, hold → flush ==="
echo "    claude:  $CLAUDE_BIN"
echo "    mock:    127.0.0.1:$CCH_MOCK_PORT"
echo "    state:   $OL_STATE"

# ---- boot a real claude with the REAL over-limit hooks wired ---------------
# Mirrors production worker-settings.json: StopFailure → over-limit-emit.sh,
# Stop → rm -f of the stamp (the recovery clear).
boot_ol_worker() {
    local win="$1"
    local hooks="$CCH_DIR/hooks-$win.json"
    jq -n \
        --arg ol "$REPO_ROOT/monitor/hooks/over-limit-emit.sh" \
        --arg clear "rm -f $OL_STATE/over-limit/$win.json" \
        '{hooks: {
            StopFailure: [ { hooks: [ {type:"command", command:$ol} ] } ],
            Stop:        [ { hooks: [ {type:"command", command:$clear} ] } ]
        }}' > "$hooks"

    # TZ is pinned to the incident's zone so the notice claude
    # composes from the unified-reset epoch is byte-identical to the
    # production render ("resets 3am (America/Los_Angeles)").
    local launch
    printf -v launch 'env -i HOME=%q PATH=%q CLAUDE_CONFIG_DIR=%q \
ANTHROPIC_BASE_URL=%q ANTHROPIC_AUTH_TOKEN=mock-token \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 \
DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 DISABLE_BUG_COMMAND=1 \
CLAUDE_CODE_MAX_RETRIES=1 \
NEXUS_STATE_DIR=%q NEXUS_WORKER_WINDOW=%q NEXUS_ROOT=%q \
TZ=America/Los_Angeles \
TERM=%q %q --dangerously-skip-permissions --settings %q' \
        "$CCH_CFG" "$PATH" "$CCH_CFG" \
        "http://127.0.0.1:$CCH_MOCK_PORT" \
        "$OL_STATE" "$win" "$OL_ROOT" \
        "${TERM:-xterm-256color}" "$CLAUDE_BIN" "$hooks"

    cch_tmux new-window -d -t "$CCH_SESSION": -n "$win" -c "$CCH_WORKDIR" "$launch"
    local idx
    idx=$(cch_tmux list-windows -t "$CCH_SESSION" -F '#{window_name} #{window_index}' \
        | awk -v n="$win" '$1==n {print $2; exit}')
    [[ -n "$idx" ]] && cch_tmux set-option -t "$CCH_SESSION:$idx" -w remain-on-exit on 2>/dev/null
    printf '%s' "$idx"
}

# Send a prompt and poll for a predicate file, retrying the prompt once
# (a first prompt can be swallowed by REPL boot). Mirrors apispoof's
# drive_failed_turn.
drive_until() {
    local idx="$1" prompt="$2"; shift 2
    local attempt i
    for attempt in 1 2; do
        cch_send "$idx" "$prompt"
        for i in $(seq 1 60); do
            "$@" && return 0
            sleep 0.5
        done
        echo "    (attempt $attempt: predicate not yet true; retrying the prompt)"
    done
    "$@"
}

WIN=olw
STAMP="$OL_STATE/over-limit/$WIN.json"
IDX=$(boot_ol_worker "$WIN")
if [[ -z "$IDX" ]]; then
    echo "FATAL: worker window never appeared" >&2
    exit 1
fi

# ---- phase A: the API says over-limit; the REAL hook must stamp it --------
# 429/rate_limit_error with the canonical notice as the error message;
# CLAUDE_CODE_MAX_RETRIES=1 (worker env) exhausts the soft-retry loop
# after one retry so the real StopFailure fires promptly with
# error="rate_limit" and last_assistant_message =
# "API Error: Request rejected (429) · <notice>". The hook must
# extract the reset time from that text — the STATUS + RESET-TIME
# detection this scenario exists to pin.
echo
echo "--- phase A: mock 429/rate_limit_error → retries exhaust → real StopFailure → real stamp ---"
cch_control "{\"mode\":\"error\",\"status\":429,\"error_type\":\"rate_limit_error\",\"error_text\":\"$NOTICE\"}"

stamped() { [[ -s "$STAMP" ]]; }
if drive_until "$IDX" "hello, are you there?" stamped; then
    echo "  PASS: StopFailure fired and over-limit-emit.sh wrote the stamp"; PASS=$((PASS+1))
    got_et=$(jq -r '.error_type' "$STAMP" 2>/dev/null)
    got_reset=$(jq -r '.reset_at' "$STAMP" 2>/dev/null)
    echo "        stamp: error_type=$got_et reset_at=$got_reset"
    assert_eq "429/rate_limit_error → StopFailure error=rate_limit" \
        "rate_limit" "$got_et"
    assert_eq "reset time detected from the notice text" \
        "$WANT_TOKEN" "$got_reset"
else
    echo "  FAIL: no stamp written — the incident's exact failure mode" >&2
    FAIL=$((FAIL+1))
fi

# ---- phase B: production pane-state consumes the stamp ---------------------
# The stamp path is renderer-independent: pid gate + blocked-overlay
# check + stamp read, all against the LIVE pane hosting the real binary.
echo
echo "--- phase B: production pane-state classifies the live pane over-limit ---"
# Through cch_pane_state, NOT a hand-rolled copy of its body. The copy that
# used to be here predated the socket pins in _lib.sh and therefore queried
# the PRODUCTION tmux server, where this session does not exist — so it
# returned nothing and both assertions below read as renderer drift
# (your-org/nexus-code#1042 A).
ps_out=$(CCH_PANE_STATE_DIR="$OL_STATE" cch_pane_state "$IDX" 2>&1)
ps_state=$(sed -n 's/.*state=\([^ ]*\).*/\1/p' <<<"$ps_out")
ps_reset=$(grep -oE 'reset_at=[^ ]+' <<<"$ps_out" | sed 's/^reset_at=//')
echo "        pane-state: state=${ps_state:-<none>} reset_at=${ps_reset:-<none>}"
assert_eq "live pane classifies over-limit via the stamp" "over-limit" "$ps_state"
assert_eq "pane-state carries the reset token"            "$WANT_TOKEN" "$ps_reset"

# The DISCRIMINATING renderer-scrape sub-check: the REAL painted notice must
# classify over-limit WITHOUT the stamp, which is how production reads it. The
# render gap makes painting nondeterministic in this sandbox, so the capture is
# RETRIED for a bounded time — and a frame that never paints is UNMEASURED, a
# third outcome that cannot finish GREEN (your-org/nexus-code#1530). This block
# used to end in an `else` that printed a `note:` and carried on: "could not
# measure" became "measured and fine", in a scenario `cc-harness/gate.sh` reads.
# The check itself lives in _renderer_scrape_check.sh so its three outcomes are
# driven without a real binary (test-realmodel-overlimit-unmeasured.sh).
UNMEASURED=0
rsc_check "$IDX" "$OL_STATE" "$CCH_DIR/no-such-stamp.json"
pane_text="$RSC_PANE_TEXT"
case "$RSC_VERDICT" in
    pass)
        echo "  PASS: renderer scrape classifies the REAL painted notice (no stamp; frame painted on capture $RSC_ATTEMPTS_USED)"; PASS=$((PASS+1)) ;;
    fail)
        ps2_state="$RSC_STATE"
        echo "  FAIL: real pane paints the notice but renderer scrape says '$ps2_state'" >&2
        FAIL=$((FAIL+1))
        # A renderer-scrape failure is unreadable without the frame it
        # scraped. `_detect_over_limit` bottom-anchors on `tail -n 15`, so
        # show where the notice actually landed relative to that window —
        # a notice pushed above row 15 by extra TUI chrome looks identical
        # to no notice at all from the assertion's side.
        {
            echo "  --- diagnostic: where is the notice relative to the 15-row scan window? ---"
            printf '  total rows captured: %s\n' "$(wc -l <<<"$pane_text")"
            printf '  notice on row(s) (1=bottom): %s\n' \
                "$(printf '%s\n' "$pane_text" | tac | grep -n 'hit your' | cut -d: -f1 | tr '\n' ' ')"
            printf '  "resets" on row(s) (1=bottom): %s\n' \
                "$(printf '%s\n' "$pane_text" | tac | grep -n 'resets' | cut -d: -f1 | tr '\n' ' ')"
            # Same distances counting NON-BLANK rows only. Fullscreen pads the
            # gap between transcript and input box with blank rows, so the raw
            # and non-blank distances diverge sharply — that divergence is the
            # whole diagnosis, and it is invisible in the raw number alone.
            printf '  non-blank rows: %s; notice at non-blank row(s) (1=bottom): %s\n' \
                "$(printf '%s\n' "$pane_text" | grep -cv '^[[:space:]]*$')" \
                "$(printf '%s\n' "$pane_text" | grep -v '^[[:space:]]*$' | tac \
                     | grep -n 'hit your' | cut -d: -f1 | tr '\n' ' ')"
            echo "  --- bottom 20 rows ---"
            printf '%s\n' "$pane_text" | tail -n 20 | cat -v | sed 's/^/  | /'
        } >&2 ;;
    *)
        UNMEASURED=1
        {
            echo "  UNMEASURED: the TUI frame stayed BLANK across $RSC_ATTEMPTS_USED captures (known render gap) — the"
            echo "              renderer-scrape sub-check DID NOT RUN. This is not a pass: the surface this"
            echo "              scenario exists to measure (what production reads WITHOUT a stamp) was not"
            echo "              exercised. The scenario will exit 69 (ENVSKIP) unless something else FAILED;"
            echo "              cc-harness/gate.sh counts that as RED. Fixture coverage of the scrape is in"
            echo "              test-pane-state.sh — against a CAPTURED frame, never this binary's."
        } >&2 ;;
esac

# ---- phase B2: limit notices that carry NO reset time ---------------------
# jacob-greene/nexus#173. Claude Code 2.1.268 ships a budget-exhaustion
# family that the pre-#173 detector missed on BOTH of its halves: the
# headline has no word "limit" and an apostrophe in "team's" that the
# flavor-token class rejected, and the notice carries no reset time at
# all, so the unconditional "resets <time>" companion also failed.
#
# These run against FIXTURE BYTES, not a live pane, on purpose. The
# watcher polls every real window in the workspace on its normal cycle;
# painting a limit notice onto a live pane to test the detector can arm
# a real hold against a real worker.
#
# `--over-limit-file` points at a path that does not exist in every
# case, so the StopFailure-stamp branch can never supply the verdict.
# What passes here passed through the RENDERER scrape.
echo
echo "--- phase B2: renderer scrape on notices with NO reset time (jacob-greene/nexus#173) ---"
B2_DIR="$CCH_DIR/b2"; mkdir -p "$B2_DIR"
B2_ESC=$'\033'
B2_FIXTURES="$REPO_ROOT/monitor/watcher/fixtures"

# Build a pane whose only notice is the given line, wrapped in the same
# chrome the synthetic fixtures use.
b2_make() {
    local name="$1" line="$2"
    {
        printf '%s\n\n' "${B2_ESC}[38;5;246m✻ Brewed for 41m${B2_ESC}[0m"
        printf '%s\n' "${B2_ESC}[38;5;244m─${B2_ESC}[0m"
        printf '%s\n' "${B2_ESC}[39m${line}${B2_ESC}[0m"
        printf '%s\n' "${B2_ESC}[38;5;244m─${B2_ESC}[0m"
    } > "$B2_DIR/$name.ansi"
    printf '%s' "$B2_DIR/$name.ansi"
}

# state= that production pane-state assigns a fixture, stamp branch off.
b2_state() {
    "$CCH_PANE_STATE" --fixture "$1" --window 9 --name b2w --active 0 \
        --over-limit-file "$CCH_DIR/no-such-stamp.json" 2>&1 \
        | sed -n 's/.*state=\([^ ]*\).*/\1/p'
}
b2_reset() {
    "$CCH_PANE_STATE" --fixture "$1" --window 9 --name b2w --active 0 \
        --over-limit-file "$CCH_DIR/no-such-stamp.json" 2>&1 \
        | grep -oE 'reset_at=[^ ]+' | sed 's/^reset_at=//'
}

# (1) The committed fixture for the new shape. Pins the apostrophe in
#     "team's" and the absent word "limit" together.
b2_budget_fixture="$B2_FIXTURES/over-limit-shared-budget-cc2.1.268-synthetic.ansi"
assert_file_exists "2.1.268 budget fixture is committed" "$b2_budget_fixture"
assert_eq "2.1.268 'team's shared budget. Switch to another model…' → over-limit" \
    "$(b2_state "$b2_budget_fixture")" "over-limit"

# (2) The slash-command variant of the same family.
assert_eq "2.1.268 'team's shared budget. /model to switch models.' → over-limit" \
    "$(b2_state "$(b2_make budget-model \
        "You've hit your team's shared budget. /model to switch models.")")" \
    "over-limit"

# (3) The /usage-credits variant. Its line does NOT end in a full stop.
#     This one pins WHERE the waiver looks: at the stop right after the
#     limit/budget noun, not at the end of the line. A condition keyed on
#     the line ending would pass (1) and (2) and fail here.
assert_eq "2.1.268 '…shared budget. Run /usage-credits …' (no trailing stop) → over-limit" \
    "$(b2_state "$(b2_make budget-credits \
        "You've hit your team's shared budget. Run /usage-credits to raise it and keep using Opus 4.7 or switch models")")" \
    "over-limit"

# (4) A waived notice has no reset time to parse, so the emit must say
#     so. reset_at=unknown is what drops the watcher's hold onto its
#     bounded 6h fallback; a fabricated token would mis-time the wake.
assert_eq "budget notice emits reset_at=unknown (6h fallback, not a fabricated token)" \
    "$(b2_reset "$b2_budget_fixture")" "unknown"

# (5) PRE-2.1.268 regression, pinned separately from the family above.
#     "You've hit your monthly spend limit." always matched the headline;
#     it was the unconditional companion that rejected it. It has been
#     undetected on every release, not only on 2.1.268.
assert_eq "'You've hit your monthly spend limit.' → over-limit (predates 2.1.268)" \
    "$(b2_state "$(b2_make monthly-spend \
        "You've hit your monthly spend limit.")")" \
    "over-limit"

# (6) The companion check must still do its job. A canonical headline
#     caught mid-redraw ends with no terminator and no reset time. If
#     the waiver had been a plain deletion of the companion check, this
#     would now classify over-limit off half a frame.
assert_eq "half-rendered canonical headline (no stop, no resets) → NOT over-limit" \
    "$(b2_state "$(b2_make half-render \
        "You've hit your weekly limit")")" \
    "absent"

# (7) Negative control. The widened headline must not be a pattern that
#     matches everything — every positive assertion above would pass
#     under one that did. This line carries "hit", "your", "team",
#     "shared", "budget" and "limit", and must still not classify.
assert_eq "prose carrying hit/your/team/shared/budget/limit → NOT over-limit" \
    "$(b2_state "$(b2_make neg-prose \
        "We hit your team's shared budget target, so the limit discussion can wait.")")" \
    "absent"

#     Two more arbitrary lines, so the negative control is not a single
#     sample. Source code and conversational prose are the two shapes an
#     agent pane carries most of the time.
assert_eq "source code carrying budget/limit identifiers → NOT over-limit" \
    "$(b2_state "$(b2_make neg-code \
        "def compute_limit(team, budget): return team.shared_budget - budget.spent")")" \
    "absent"
assert_eq "conversational prose carrying reached/your/hit/team/shared/budget → NOT over-limit" \
    "$(b2_state "$(b2_make neg-chat \
        "I have reached your file and hit save; the team shared a budget spreadsheet.")")" \
    "absent"

# (8) The canonical path the widening must not disturb, asserted here so
#     this phase stands alone: state AND the parsed reset token.
b2_canon=$(b2_make canon-weekly \
    "You've hit your weekly limit · resets 3am (America/Los_Angeles)")
assert_eq "canonical weekly notice still over-limit" \
    "$(b2_state "$b2_canon")" "over-limit"
assert_eq "canonical weekly notice still parses its reset token" \
    "$(b2_reset "$b2_canon")" "3am_America/Los_Angeles"

# ---- phase B3: provenance — QUOTED SOURCE is not a painted notice ---------
# The live false positive of 2026-09-10 23:15 PDT. The watcher armed a
# real 20.7 h hold against a working window. Nothing was limited. The
# window held an agent editing this detector, and the file-edit tool had
# rendered its own diff onto the pane. The scrape read the diff line as
# a notice.
#
# The stored token was `3am_America/Los_Angeles"`. The trailing double
# quote is the source line's closing quote and is the byte-exact proof
# of provenance — no rendered notice can produce it.
#
# A widened headline raises the false-positive rate on exactly this
# input class, so these assertions carry the evidence that the widening
# is safe. Every line below is copied VERBATIM from a real captured
# pane, not written as prose approximating one.
echo
echo "--- phase B3: quoted source / diff renders must NOT detect ---"

# (9) The committed fixture: five real captured shapes inside the scan
#     window, with an idle input box below them. The positional anchor
#     cannot reject these — they are in the window. Only the provenance
#     filter can.
b3_fixture="$B2_FIXTURES/idle-overlimit-quoted-source-in-window-synthetic.ansi"
assert_file_exists "quoted-source fixture is committed" "$b3_fixture"
assert_eq "pane of quoted source in the scan window → idle, not over-limit" \
    "$(b2_state "$b3_fixture")" "idle"

# (10) The incident's own emit must not appear at all. A `reset_at` on
#      this pane means the detector fired; the empty string means it
#      never did. This is the assertion that pins the 20.7 h hold shut.
assert_eq "quoted-source pane emits no reset_at (the 2026-09-10 token)" \
    "$(b2_reset "$b3_fixture")" ""

# (11) The exact line that caused the latch, alone in a window.
assert_eq "file-edit diff render of a test line → NOT over-limit" \
    "$(b2_state "$(b2_make src-diff \
'      334 +    "You'"'"'ve hit your weekly limit · resets 3am (America/Los_Angeles)")')")" \
    "absent"

# (12) The same render shape with NO quote before the headline — a
#      diff of a COMMENT line. The quote rule alone cannot reject this
#      one; the line-number gutter rule is what does.
assert_eq "file-edit diff render of a comment line (unquoted) → NOT over-limit" \
    "$(b2_state "$(b2_make src-diff-comment \
'      551 +#     You'"'"'ve hit your team'"'"'s shared budget. Switch to another model to continue.')")" \
    "absent"

# (13) The shell-assertion shape, which is what a test for this detector
#      looks like on a pane while it is being written.
assert_eq "shell assertion carrying the notice → NOT over-limit" \
    "$(b2_state "$(b2_make src-shell \
'  ⎿  echo "You'"'"'ve hit your team'"'"'s shared budget. /model to switch models." \')")" \
    "absent"

# (14) `grep -n` output, the other gutter shape.
#
#      The row carries a COMPLETE canonical notice with its reset time
#      and no quote, so the only thing standing between it and an
#      over-limit verdict is the gutter rule. An earlier draft used a
#      real captured `grep -n` row whose notice was truncated at the
#      middle dot; that row has no reset time and no sentence-final
#      stop, so `_detect_over_limit` rejected it at the companion check
#      with or without the filter, and the assertion pinned nothing.
#      The skeptic on jacob-greene/nexus#173 found that. This shape is
#      what a `grep -n` over a fixture file actually emits.
assert_eq "grep -n output carrying a complete notice → NOT over-limit" \
    "$(b2_state "$(b2_make src-grep \
"     557:You've hit your weekly limit · resets 3am (America/Los_Angeles)")")" \
    "absent"

# (15) A markdown bullet quoting the notice in backticks.
assert_eq "markdown backtick quote of the notice → NOT over-limit" \
    "$(b2_state "$(b2_make src-markdown \
'     - `You'"'"'ve hit your team'"'"'s shared budget. /model to switch models.`')")" \
    "absent"

# (16) The filter must not eat a real notice. An INDENTED canonical
#      notice has no gutter, no quote and no marker, so it still
#      classifies. Without this the filter could be tightened into a
#      detector that rejects everything and every assertion above would
#      still pass.
assert_eq "indented canonical notice still over-limit (filter is not a blanket reject)" \
    "$(b2_state "$(b2_make canon-indented \
"        You've hit your weekly limit · resets 3am (America/Los_Angeles)")")" \
    "over-limit"

# (17) The detector must not classify off this REPOSITORY's own source.
#      Every line of every TRACKED file that matches the headline is
#      rendered alone on a pane; none may classify over-limit.
#
#      This is not hypothetical. The doc comment added with the widened
#      pattern first carried its three example notices UNQUOTED. Those
#      rows have no gutter, no quote and no marker, so no provenance
#      rule dropped them, and a `cat` of the file onto a pane
#      classified over-limit off the comment block.
#
#      The sweep was single-file at first, over pane-state.sh only. The
#      depth-1 skeptic on jacob-greene/nexus#173 swept the whole
#      repository and found three more rows the narrow scope had
#      hidden: the header of THIS file, and two rows in
#      docs/reference/dependency-surface.md whose notice sits in SINGLE
#      quotes, a character rule 2's `["`]` class does not carry. All
#      four are now quoted with a character the filter does drop, and
#      the sweep is repository-wide so the next one cannot hide the
#      same way.
#
#      monitor/watcher/fixtures/ is the ONLY exclusion, and it is
#      principled: a fixture that classifies over-limit is the entire
#      point of that fixture.
b3_bad=0 b3_n=0
while IFS= read -r b3_file; do
    [[ -f "$REPO_ROOT/$b3_file" ]] || continue
    while IFS= read -r b3_row; do
        b3_n=$(( b3_n + 1 ))
        if [[ "$(b2_state "$(b2_make "self-$b3_n" "$b3_row")")" == "over-limit" ]]; then
            b3_bad=$(( b3_bad + 1 ))
            echo "        offending row: $b3_file: $b3_row" >&2
        fi
    done < <(grep -IE "You.{0,3}ve (hit|reached) your ([^[:space:]]+ ){0,2}(limit|budget)" \
                "$REPO_ROOT/$b3_file" 2>/dev/null)
done < <(git -C "$REPO_ROOT" ls-files 2>/dev/null | grep -v '^monitor/watcher/fixtures/')

# Positive control on the absence claim above. A mis-scoped grep, or a
# `git ls-files` that returns nothing because this is not a checkout,
# scans zero rows and the offender count is then trivially 0 — which
# reads exactly like a clean pass. This assertion makes that loud.
assert_eq "repository self-source scan actually scanned rows (n=$b3_n)" \
    "$( (( b3_n > 0 )) && echo yes || echo no )" "yes"
assert_eq "no tracked line in this repository classifies over-limit off its own source" \
    "$b3_bad" "0"

# ---- phase C: the watcher's HOLD — gate closes on the detected status ------
# Source the production _over_limit.sh at its unit seam: record what the
# probe saw, exactly as _over_limit_scan_panes would, and assert the
# emit-gate predicate main.sh consults before every paste.
echo
echo "--- phase C: emit gate closes (the hold) ---"
OL_PASTES="$CCH_DIR/ol-pastes.log"; : > "$OL_PASTES"
_ol_test_log()   { printf '%s\n' "$*" >> "$CCH_DIR/ol-log.log"; }
_ol_test_paste() { printf '%s\t%s\n' "$1" "$(cat "$2")" >> "$OL_PASTES"; }
_machine_input_stamp() { :; }   # ledger stub (worker-wake path only)
_OVER_LIMIT_LOG_FN=_ol_test_log
_OVER_LIMIT_PASTE_FN=_ol_test_paste
STATE_DIR="$CCH_DIR/watcher-state"; mkdir -p "$STATE_DIR"
# shellcheck source=../../watcher/_over_limit.sh
. "$REPO_ROOT/monitor/watcher/_over_limit.sh"

_over_limit_record "_orchestrator" "$WIN" "orchestrator" "${ps_reset:-unknown}"
if _over_limit_orchestrator_paused; then
    echo "  PASS: emit gate CLOSED (emits held while over-limit)"; PASS=$((PASS+1))
else
    echo "  FAIL: emit gate did not close after record" >&2; FAIL=$((FAIL+1))
fi
# Off-time log (your-nexus#275): the fresh hold started it; simulate the
# emits main.sh would hold while the gate is closed.
HELD_LOG=$(_over_limit_held_log_path)
if [[ -f "$HELD_LOG" ]]; then
    echo "  PASS: fresh hold started the off-time log ($HELD_LOG)"; PASS=$((PASS+1))
else
    echo "  FAIL: off-time log not started on hold" >&2; FAIL=$((FAIL+1))
fi
_over_limit_record_held "2026-07-15_11-00-00_held1.md" "poll-resurface"
_over_limit_record_held "2026-07-15_11-01-00_held2.md" "poll-full-state"
held_n=$(grep -c $'\theld\t' "$HELD_LOG" 2>/dev/null) || held_n=0
if [[ "$held_n" == "2" ]]; then
    echo "  PASS: held emits recorded in off-time log (n=$held_n)"; PASS=$((PASS+1))
else
    echo "  FAIL: expected 2 held records, got $held_n" >&2; FAIL=$((FAIL+1))
fi
# The hold must carry a bounded wake time (reset_epoch + margin), i.e.
# the reset TIME detection propagated into the schedule.
row=$(_over_limit_load "_orchestrator")
reset_epoch=$(awk -F'\t' '{print $5}' <<<"$row")
now_epoch=$(date +%s)
if [[ "$reset_epoch" =~ ^[0-9]+$ ]] && (( reset_epoch > now_epoch )) \
    && (( reset_epoch <= now_epoch + 86400 )); then
    echo "  PASS: hold is bounded by the parsed reset time (in $(( reset_epoch - now_epoch ))s ≤ 24h)"; PASS=$((PASS+1))
else
    echo "  FAIL: reset_epoch=$reset_epoch not a bounded future time (now=$now_epoch)" >&2; FAIL=$((FAIL+1))
fi

# ---- phase D: recovery — real Stop clears the stamp; wake FLUSHES ----------
echo
echo "--- phase D: mock recovers → real Stop clears stamp → wake flushes ---"
cch_control '{"mode":"text","text":"MOCK_RECOVERED_OK"}'
cleared() { [[ ! -f "$STAMP" ]]; }
if drive_until "$IDX" "and now?" cleared; then
    echo "  PASS: successful TUI turn → real Stop hook cleared the stamp"; PASS=$((PASS+1))
else
    echo "  FAIL: stamp not cleared after the mock recovered" >&2; FAIL=$((FAIL+1))
fi

# Drive the production wake loop with the row's clock rewound past the
# reset (the test can't wait for 3am). The wake probe runs a stubbed
# pane-state pinned to `idle` (render gap — see header); everything on
# the state-machine side is the production code.
cat > "$OL_ROOT/monitor/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
printf 'state=idle active=0 window=0 name=olw\n'
STUB
chmod +x "$OL_ROOT/monitor/pane-state.sh"

row=$(_over_limit_load "_orchestrator")
IFS=$'\t' read -r k w r tok re fs na at <<<"$row"
_over_limit_write_row "$k" "$w" "$r" "$tok" "$re" "$fs" "$(( $(date +%s) - 1 ))" "$at"

# Through cch_with_tmux_env: this function resolves a tmux window index, and
# on the ambient socket that window does not exist. The probe then answers
# "absent" — a well-formed answer to the wrong server — so the gate never
# reopens and nothing is pasted (your-org/nexus-code#1042 A).
NEXUS_ROOT="$OL_ROOT" cch_with_tmux_env _over_limit_process_wakes "$WIN"

if _over_limit_orchestrator_paused; then
    echo "  FAIL: emit gate still closed after wake — held emits would never flush" >&2
    FAIL=$((FAIL+1))
else
    echo "  PASS: emit gate REOPENED after the reset (the flush)"; PASS=$((PASS+1))
fi
if grep -q "USAGE-LIMIT RECOVERY" "$OL_PASTES" 2>/dev/null; then
    echo "  PASS: special first-emit (recovery brief) pasted on wake"; PASS=$((PASS+1))
else
    echo "  FAIL: no recovery brief in paste log ($(cat "$OL_PASTES" 2>/dev/null))" >&2
    FAIL=$((FAIL+1))
fi
# The special first emit must satisfy the operator's three requirements
# (your-nexus#275): what happened, state now, where the off-time log is.
flushed=$(cat "$OL_PASTES" 2>/dev/null)
for want in "WHAT HAPPENED" "STATE NOW" "LOG OF THE OFF-TIME" "over-limit-held.log"; do
    if grep -qF "$want" <<<"$flushed"; then
        echo "  PASS: first emit carries '$want'"; PASS=$((PASS+1))
    else
        echo "  FAIL: first emit missing '$want'" >&2; FAIL=$((FAIL+1))
    fi
done

cch_teardown
# AN UNMEASURED DISCRIMINATING SUB-CHECK CANNOT FINISH GREEN (#1530). A FAIL
# outranks it — `th_summary_and_exit` reports that red as it always has. Only a
# run with no failure and a sub-check that never ran leaves by 69, with the ENV
# line the ENVSKIP contract asks for, so the reader is sent to the MACHINE and
# not into the renderer.
if [[ "$(rsc_exit_code "$FAIL" "$UNMEASURED")" == 69 ]]; then
    printf '=== summary: %d passed, %d failed — and 1 DISCRIMINATING sub-check UNMEASURED ===\n' "$PASS" "$FAIL"
    echo "ENV: the real TUI never painted the failed-turn frame on this host, so the renderer scrape could not be exercised (your-org/nexus-code#1530). Exit 69 — not a pass, not a product failure." >&2
    exit 69
fi
th_summary_and_exit
