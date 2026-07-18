#!/usr/bin/env bash
# test-realmodel-overlimit.sh — end-to-end over-limit STATUS + RESET-TIME
# detection and hold→flush, against the REAL `claude` binary and a dummy
# Anthropic API (monitor/cc-harness/mock-backend.py).
#
# The motivating incident (2026-07-14): the account hit its weekly usage
# limit for ~23 h; every turn the orchestrator attempted failed with
#
#     You've hit your weekly limit · resets 3am (America/Los_Angeles)
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
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary).
# Self-skips cleanly (never a silent pass) where the real binary is
# unavailable. See monitor/cc-harness/README.md.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_test_helpers.sh"
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
ps_out=$(PATH="$CCH_DIR/.bin:$PATH" NEXUS_STATE_DIR="$OL_STATE" \
    "$CCH_PANE_STATE" "$CCH_SESSION:$IDX" 2>&1)
ps_state=$(sed -n 's/.*state=\([^ ]*\).*/\1/p' <<<"$ps_out")
ps_reset=$(grep -oE 'reset_at=[^ ]+' <<<"$ps_out" | sed 's/^reset_at=//')
echo "        pane-state: state=${ps_state:-<none>} reset_at=${ps_reset:-<none>}"
assert_eq "live pane classifies over-limit via the stamp" "over-limit" "$ps_state"
assert_eq "pane-state carries the reset token"            "$WANT_TOKEN" "$ps_reset"

# Opportunistic renderer-scrape sub-check: when the real TUI painted
# the failed-turn frame (it renders the API error text, i.e. the
# notice), _detect_over_limit must classify it WITHOUT the stamp.
# The render gap makes painting nondeterministic in this sandbox, so
# a blank frame downgrades to a loud note, never a silent pass.
pane_text=$(cch_capture "$IDX")
if grep -q "hit your" <<<"$pane_text"; then
    ps2_out=$(PATH="$CCH_DIR/.bin:$PATH" NEXUS_STATE_DIR="$OL_STATE" \
        "$CCH_PANE_STATE" --over-limit-file "$CCH_DIR/no-such-stamp.json" \
        "$CCH_SESSION:$IDX" 2>&1)
    ps2_state=$(sed -n 's/.*state=\([^ ]*\).*/\1/p' <<<"$ps2_out")
    if [[ "$ps2_state" == "over-limit" ]]; then
        echo "  PASS: renderer scrape classifies the REAL painted notice (no stamp)"; PASS=$((PASS+1))
    else
        echo "  FAIL: real pane paints the notice but renderer scrape says '$ps2_state'" >&2
        FAIL=$((FAIL+1))
    fi
else
    echo "  note: TUI frame blank (known render gap) — renderer-scrape sub-check not exercisable this run; fixture coverage in test-pane-state.sh"
fi

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
held_n=$(grep -c $'\theld\t' "$HELD_LOG" 2>/dev/null || echo 0)
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

NEXUS_ROOT="$OL_ROOT" PATH="$CCH_DIR/.bin:$PATH" \
    _over_limit_process_wakes "$WIN"

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
th_summary_and_exit
