#!/usr/bin/env bash
# test-realmodel-apispoof.sh — end-to-end Anthropic-API-spoof test of the
# stall detection + correction chain, against the REAL `claude` binary.
#
# The motivating incident was a worker whose turn died to a random API 529
# mid-turn: Claude Code fired the `StopFailure` hook (NOT `Stop`), no state
# updates ran, and the watcher mis-nagged the idle-alive worker as
# "no-wrap-up." This test reproduces that incident DELIBERATELY and
# hermetically by pointing a throwaway real `claude` at the auth-free mock
# backend (monitor/cc-harness/mock-backend.py) configured to return a real
# HTTP 529 — so a REAL turn fails, a REAL StopFailure fires, the REAL
# `turn-failure-emit.sh` hook writes a REAL marker, and the REAL watcher
# classifier surfaces the window as `interrupted` with the correct recovery
# verb. Then the mock flips to success and a REAL resume completes — proving
# detect -> classify -> correct works end to end, with NO Anthropic auth and
# NO network egress.
#
# Chain exercised (every link is production code, joined by a real marker):
#
#   real claude  --(ANTHROPIC_BASE_URL)-->  mock 529 / 404
#        |  real turn fails
#        v
#   real StopFailure hook  -->  real turn-failure-emit.sh  -->  real marker
#        |
#        v
#   real list_really_idle_workers  -->  `interrupted` + <category>:<recovery>
#        |
#        v
#   mock flips to success  -->  real `claude --continue`  -->  turn COMPLETES
#
# Two error shapes are spoofed:
#   - transient  (529 overloaded_error -> error="server_error")
#                 => category=transient recovery=PASTE; the resumed turn
#                    succeeds once the mock recovers (the incident shape).
#   - non-transient (404 not_found_error -> error="model_not_found")
#                 => category=config recovery=RESPAWN; a paste would just
#                    re-run the doomed turn, so the verb MUST differ.
#
# Environment note (honest scope): in this sandbox the real claude TUI does
# not reliably PAINT into a tmux pane that pane-state.sh can read — the
# baseline cc-harness scenario (test-realmodel-idle-busy) shows the same
# render gap with claude 2.1.x. That render path is independent of this
# change. So the *live-pane classification* sub-step stubs pane-state to the
# post-crash idle shape (exactly as experiments/controlled-stall.sh does),
# while EVERYTHING else here is real: the API error, the failed turn, the
# StopFailure event, the marker the hook writes, the classifier reading it,
# and the resume that completes. The TUI process stays alive long enough for
# the StopFailure hook to run to completion (a headless `claude -p` kills its
# hooks on turn-exit, so the marker write races and is NOT reliable there —
# the TUI path is load-bearing for an honest e2e).
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary). Self-skips
# cleanly (logged SKIP, never a silent pass) where the real binary is
# unavailable, so CI without a claude install stays green. See
# monitor/cc-harness/README.md.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

cch_skip_if_disabled
cch_setup

REPO_ROOT="$CCH_REPO_ROOT"
PASS=0; FAIL=0

echo "=== real-binary API-spoof: detect -> classify -> correct ==="
echo "    claude:  $CLAUDE_BIN"
echo "    mock:    127.0.0.1:$CCH_MOCK_PORT"
echo "    state:   $CCH_STATE_DIR"

# ---- boot a real claude worker with the stall-detection hooks wired -------
# Like cch_boot_worker, but installs the StopFailure handler (real
# turn-failure-emit.sh) + a Stop hook that clears the marker on recovery,
# and exports NEXUS_STATE_DIR / NEXUS_WORKER_WINDOW so the hook writes into
# our hermetic state dir keyed on the window name. Echoes the window index.
boot_spoof_worker() {
    local win="$1"
    local hooks="$CCH_DIR/hooks-$win.json"
    jq -n \
        --arg tf "$REPO_ROOT/monitor/hooks/turn-failure-emit.sh" \
        --arg clear "rm -f $CCH_STATE_DIR/turn-failure/$win.json" \
        '{hooks: {
            StopFailure: [ { hooks: [ {type:"command", command:$tf} ] } ],
            Stop:        [ { hooks: [ {type:"command", command:$clear} ] } ]
        }}' > "$hooks"

    local launch
    printf -v launch 'env -i HOME=%q PATH=%q CLAUDE_CONFIG_DIR=%q \
ANTHROPIC_BASE_URL=%q ANTHROPIC_AUTH_TOKEN=mock-token \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 \
DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 DISABLE_BUG_COMMAND=1 \
NEXUS_STATE_DIR=%q NEXUS_WORKER_WINDOW=%q NEXUS_ROOT=%q \
TERM=%q %q --dangerously-skip-permissions --settings %q' \
        "$CCH_CFG" "$PATH" "$CCH_CFG" \
        "http://127.0.0.1:$CCH_MOCK_PORT" \
        "$CCH_STATE_DIR" "$win" "$REPO_ROOT" \
        "${TERM:-xterm-256color}" "$CLAUDE_BIN" "$hooks"

    cch_tmux new-window -d -t "$CCH_SESSION": -n "$win" -c "$CCH_WORKDIR" "$launch"
    local idx
    idx=$(cch_tmux list-windows -t "$CCH_SESSION" -F '#{window_name} #{window_index}' \
        | awk -v n="$win" '$1==n {print $2; exit}')
    [[ -n "$idx" ]] && cch_tmux set-option -t "$CCH_SESSION:$idx" -w remain-on-exit on 2>/dev/null
    printf '%s' "$idx"
}

# Drive the REAL watcher idle-classifier against the REAL marker. pane-state
# is stubbed to the post-crash idle shape (see header) so the classifier sees
# exactly the incident pane: idle/empty, process alive, fresh marker present.
# Echoes the matching `interrupted` line (empty on miss).
classify_window() {
    local win="$1"
    local stub="$CCH_DIR/classify-bin"; mkdir -p "$stub" "$CCH_DIR/classify-monitor"
    cat > "$stub/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in list-windows) printf '%s\n' "${MOCK_TMUX_WINDOWS:-}";; *) :;; esac
exit 0
STUB
    cat > "$stub/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
printf 'state=idle\n'   # post-crash pane: empty box, claude alive
STUB
    chmod +x "$stub/tmux" "$stub/pane-state.sh"
    cp "$stub/pane-state.sh" "$CCH_DIR/classify-monitor/pane-state.sh"

    local old_ts; old_ts=$(( $(date +%s) - 120 ))   # above the 60s idle gate
    printf '%s\t%s\n' "$win" "$old_ts" > "$CCH_STATE_DIR/engagement-log.tsv"

    PATH="$stub:$PATH" MOCK_TMUX_WINDOWS="$win|$old_ts" bash -c "
        set -uo pipefail
        STATE_DIR='$CCH_STATE_DIR'; NEXUS_ROOT='$CCH_DIR/classify-monitor-root'
        export NEXUS_STATE_DIR='$CCH_STATE_DIR'
        mkdir -p \"\$NEXUS_ROOT/monitor\"
        cp '$stub/pane-state.sh' \"\$NEXUS_ROOT/monitor/pane-state.sh\"
        source '$REPO_ROOT/monitor/watcher/_idle_probe.sh'
        list_really_idle_workers" 2>/dev/null | grep -F $'\tinterrupted\t' || true
}

# Wait for the real hook to write the marker, retrying the prompt once (a
# first turn that no-ops would leave no marker). Returns 0 if the marker
# appears.
drive_failed_turn() {
    local win="$1" idx="$2"
    local marker="$CCH_STATE_DIR/turn-failure/$win.json"
    local attempt
    for attempt in 1 2; do
        cch_send "$idx" "say pong"
        local i
        for i in $(seq 1 60); do
            [[ -f "$marker" ]] && return 0
            sleep 0.5
        done
        echo "    (attempt $attempt: no marker yet; retrying the prompt)"
    done
    [[ -f "$marker" ]]
}

# ===========================================================================
# Scenario A — transient (529 overloaded) -> interrupted/PASTE -> recovery
# ===========================================================================
echo
echo "--- Scenario A: transient API 529 -> interrupted (paste) -> resume completes ---"
winA="apispoofA"
cch_control '{"mode":"error","status":529,"error_type":"overloaded_error","error_text":"Overloaded"}'
idxA=$(boot_spoof_worker "$winA")
if [[ -z "$idxA" ]]; then echo "FAIL: worker A window never appeared" >&2; FAIL=$((FAIL+1)); th_summary_and_exit; fi
markerA="$CCH_STATE_DIR/turn-failure/$winA.json"

if drive_failed_turn "$winA" "$idxA"; then
    echo "  PASS: real StopFailure hook wrote a marker for the spoofed 529"; PASS=$((PASS+1))
    catA=$(jq -r .category  "$markerA"); recA=$(jq -r .recovery "$markerA"); errA=$(jq -r .error "$markerA")
    echo "        marker: error=$errA category=$catA recovery=$recA"
    assert_eq    "529 -> category transient"  "transient" "$catA"
    assert_eq    "529 -> recovery paste"      "paste"     "$recA"
    assert_eq    "529 -> error server_error"  "server_error" "$errA"

    lineA=$(classify_window "$winA")
    echo "        classifier: ${lineA:-<none>}"
    if grep -qF $'\tinterrupted\t' <<<"$lineA" && grep -qF "transient:paste" <<<"$lineA"; then
        echo "  PASS: classifier surfaced winA as interrupted with transient:paste"; PASS=$((PASS+1))
    else
        echo "  FAIL: classifier did not surface interrupted/transient:paste for winA" >&2; FAIL=$((FAIL+1))
    fi

    # --- recovery: kill the crashed worker, flip the mock to success, resume.
    # The live paste-into-pane path can't be observed here (TUI render gap),
    # so the resume is driven headlessly against the SAME session + config +
    # mock — proving the crashed turn resumes to completion once the API
    # recovers. The headless turn fires Stop, which clears the marker.
    cch_kill_claude "$idxA" 2>/dev/null || true
    cch_control '{"mode":"text","text":"RESUMED_OK_PONG"}'
    resume_out="$CCH_DIR/resumeA.out"
    env -i HOME="$CCH_CFG" PATH="$PATH" CLAUDE_CONFIG_DIR="$CCH_CFG" \
        ANTHROPIC_BASE_URL="http://127.0.0.1:$CCH_MOCK_PORT" ANTHROPIC_AUTH_TOKEN=mock-token \
        DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 DISABLE_BUG_COMMAND=1 \
        NEXUS_STATE_DIR="$CCH_STATE_DIR" NEXUS_WORKER_WINDOW="$winA" NEXUS_ROOT="$REPO_ROOT" \
        timeout 90 "$CLAUDE_BIN" -p --continue "continue" \
            --settings "$CCH_DIR/hooks-$winA.json" </dev/null >"$resume_out" 2>/dev/null
    rc=$?
    if [[ $rc -eq 0 ]] && grep -qF "RESUMED_OK_PONG" "$resume_out"; then
        echo "  PASS: resumed turn completed once the mock recovered (rc=0, canned text)"; PASS=$((PASS+1))
    else
        echo "  FAIL: resume did not complete (rc=$rc, out=$(head -1 "$resume_out"))" >&2; FAIL=$((FAIL+1))
    fi
    # Marker-clear on the recovering Stop is best-effort here (headless Stop
    # can race process-exit); report it without gating the suite — the
    # clear-on-Stop contract is covered deterministically by the unit suite.
    if [[ -f "$markerA" ]]; then
        echo "  note: marker still present after resume (headless Stop-clear raced exit; unit-tested separately)"
    else
        echo "  PASS: recovering Stop hook cleared the marker"; PASS=$((PASS+1))
    fi
else
    echo "  FAIL: no turn-failure marker written for the spoofed 529 (TUI never fired StopFailure)" >&2
    FAIL=$((FAIL+1))
fi

# ===========================================================================
# Scenario B — non-transient (404 not_found) -> interrupted/RESPAWN
# ===========================================================================
echo
echo "--- Scenario B: non-transient 404 not_found -> interrupted (RESPAWN, not paste) ---"
winB="apispoofB"
cch_control '{"mode":"error","status":404,"error_type":"not_found_error","error_text":"model not found"}'
idxB=$(boot_spoof_worker "$winB")
markerB="$CCH_STATE_DIR/turn-failure/$winB.json"
if [[ -n "$idxB" ]] && drive_failed_turn "$winB" "$idxB"; then
    catB=$(jq -r .category "$markerB"); recB=$(jq -r .recovery "$markerB"); errB=$(jq -r .error "$markerB")
    echo "  PASS: real StopFailure hook wrote a marker for the spoofed 404"; PASS=$((PASS+1))
    echo "        marker: error=$errB category=$catB recovery=$recB"
    # 404 not_found_error -> CC surfaces model_not_found -> config/respawn.
    assert_eq         "404 -> recovery respawn"         "respawn" "$recB"
    assert_not_contains "404 -> NOT the paste verb"     "$recB"   "paste"

    lineB=$(classify_window "$winB")
    echo "        classifier: ${lineB:-<none>}"
    if grep -qF $'\tinterrupted\t' <<<"$lineB" && grep -qF ":respawn" <<<"$lineB"; then
        echo "  PASS: classifier surfaced winB as interrupted with a respawn verb"; PASS=$((PASS+1))
    else
        echo "  FAIL: classifier did not surface interrupted/respawn for winB" >&2; FAIL=$((FAIL+1))
    fi
else
    echo "  FAIL: no turn-failure marker written for the spoofed 404" >&2
    FAIL=$((FAIL+1))
fi

cch_teardown
th_summary_and_exit
