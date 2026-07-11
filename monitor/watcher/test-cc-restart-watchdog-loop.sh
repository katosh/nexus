#!/usr/bin/env bash
# Unit tests for monitor/cc-restart-watchdog-loop.sh — specifically the
# resolution of the coordinator window the loop watches (your-org/nexus-code#459).
#
# #428 taught cc-auto-update-apply.sh to resolve `monitor.target_window` from
# config, but left the sibling loop hard-coding the literal `orchestrator`.
# The loop reads TARGET at its BASELINE, before the armed marker; on a nexus
# whose window is named anything else the baseline found no pane, the loop
# died, the armed marker was never written, and apply.sh aborted the restart at
# `watchdog-never-armed` after burning its 600 s ARM_WAIT. The bug is invisible
# to any nexus whose window happens to be named `orchestrator` — hence these
# tests pin BOTH directions.
#
# Hermetic: no real tmux server, no real claude binary, no live state. tmux is
# a PATH stub that records the window each `list-panes` asks for; the loop is
# invoked with a restricted PATH so its `sandbox-notify` probe finds nothing
# and no notification escapes. Every run stops a second or two after the
# baseline (the stub pid never dies), which is all these tests need: arming IS
# the discriminator.
#
# Cases:
#   1.  default path preserved: no `monitor.target_window` in config, window
#       named `orchestrator` → arms, and queries `orchestrator`.
#   2.  #459 regression: `monitor.target_window: claude`, window named
#       `claude` → arms, and queries `claude`.
#   3.  fails-on-pre-fix control: the SAME fixture as (2) run against a mutant
#       of the loop carrying the #428-era hardcode → does NOT arm; dies at
#       `baseline incomplete`. Without this, (2) proves nothing.
#   4.  single-variable positive control: the same mutant, same fixture, with
#       CC_AUTO_TARGET_WINDOW=claude the ONLY delta → arms. Isolates the
#       target resolution as the cause, not the fixture.
#   5.  precedence: CC_AUTO_TARGET_WINDOW beats config; MONITOR_TARGET beats
#       config; CC_AUTO_TARGET_WINDOW beats MONITOR_TARGET.
#   6.  no config file at all → falls back to `orchestrator` (does not query
#       an empty window name).
#   7.  wiring: the watchdog prompt template hands the loop the window
#       apply.sh already resolved, so the loop never has to re-derive it.
#
# Run: bash monitor/watcher/test-cc-restart-watchdog-loop.sh

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MONITOR_DIR=$(cd "$_script_dir/.." && pwd)
NEXUS_SRC=$(cd "$MONITOR_DIR/.." && pwd)
LOOP="$MONITOR_DIR/cc-restart-watchdog-loop.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

CANDIDATE="2.1.205"
SID="0f9c1a2b-3d4e-5f60-8712-9a3b4c5d6e7f"

# config/load.sh needs python3 + pyyaml. Without them it exits 3, the loop's
# `|| echo orchestrator` fallback fires, and cases 2/5 would fail for a reason
# that has nothing to do with the code under test. Skip loudly instead.
if ! /usr/bin/python3 -c 'import yaml' 2>/dev/null; then
    echo "skipped: /usr/bin/python3 lacks pyyaml (config/load.sh cannot resolve keys)"
    exit 0
fi

# ---- fixtures -------------------------------------------------------------

# A PATH stub for tmux. Only `list-panes` is reached before the armed marker;
# it prints a pane pid for exactly ONE window name and otherwise fails the way
# real tmux does. Every invocation appends its window argument to a log, so a
# test can assert WHICH window the loop asked about — a more direct claim than
# "it armed".
make_tmux_stub() {
    local bindir="$1"
    mkdir -p "$bindir"
    cat > "$bindir/tmux" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "list-panes" && "${2:-}" == "-t" ]]; then
    printf '%s\n' "$3" >> "$TMUX_STUB_LOG"
    if [[ "$3" == "$TMUX_STUB_WINDOW" ]]; then
        printf '%s\n' "$TMUX_STUB_PID"
        exit 0
    fi
    printf "can't find window %s\n" "$3" >&2
    exit 1
fi
if [[ "${1:-}" == "list-windows" ]]; then
    printf '%s\n' "$TMUX_STUB_WINDOW"
    exit 0
fi
exit 0
STUB
    chmod +x "$bindir/tmux"
}

# A miniature nexus root: config/load.sh, a claude binary that reports
# $CANDIDATE, a pinned session id, and that session's transcript (the loop
# stats its size for the baseline). No nexus.yml — add one with write_cfg.
# nexus.example.yml is deliberately absent too, so load.sh's third precedence
# leg cannot smuggle a value in.
make_root() {
    local root="$1"
    mkdir -p "$root/config" "$root/monitor/.state" "$root/node_modules/.bin"
    cp "$NEXUS_SRC/config/load.sh" "$root/config/load.sh"
    cat > "$root/node_modules/.bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s (Claude Code)\n' "$CANDIDATE"
EOF
    chmod +x "$root/node_modules/.bin/claude"
    printf '%s\n' "$SID" > "$root/monitor/.state/orchestrator-session-id"
    local slug projects
    slug=$(printf '%s' "$root" | sed 's|[^a-zA-Z0-9]|-|g')
    projects="$root/projects/$slug"
    mkdir -p "$projects"
    printf '{"version":"2.1.180"}\n' > "$projects/$SID.jsonl"
}

# write_cfg <root> [<target_window>] — with a window name, writes a nexus.yml
# setting monitor.target_window; with none, writes one that omits the key.
write_cfg() {
    local root="$1"
    if [[ -n "${2-}" ]]; then
        printf 'monitor:\n  target_window: %s\n' "$2" > "$root/config/nexus.yml"
    else
        printf 'monitor:\n  interval_seconds: 60\n' > "$root/config/nexus.yml"
    fi
}

# The #428-era loop: identical but for the TARGET assignment. Built by mutating
# the shipped file so it cannot silently drift out of sync with it.
make_prefix_loop() {
    local dst="$1"
    awk '
        /^TARGET=/ && !done { print "TARGET=\"${CC_AUTO_TARGET_WINDOW:-orchestrator}\""; done=1; next }
        { print }
    ' "$LOOP" > "$dst"
    grep -qxF 'TARGET="${CC_AUTO_TARGET_WINDOW:-orchestrator}"' "$dst"
}

# Run a loop against a root. Prints nothing; sets ARMED=0|1 and QUERIED (the
# newline-joined list of windows tmux was asked about).
#
# PATH is restricted to the stub plus the base system dirs: it keeps
# `sandbox-notify` out of `command -v` range (fail() would otherwise fire a
# real notification) while leaving python3/coreutils reachable.
ARMED=0
QUERIED=""
run_loop() {
    local root="$1" window="$2" script="$3"; shift 3   # remaining: env assignments
    local bindir="$root/stubbin" state="$root/monitor/.state"
    make_tmux_stub "$bindir"
    rm -f "$state/restart-watchdog-armed" "$state/restart-watchdog-failed"
    : > "$root/tmux.log"
    env -i PATH="$bindir:/usr/bin:/bin" HOME="$root" \
        TMUX_STUB_LOG="$root/tmux.log" TMUX_STUB_WINDOW="$window" TMUX_STUB_PID="$$" \
        NEXUS_ROOT="$root" NEXUS_STATE_DIR="$state" \
        CC_AUTO_PROJECTS_DIR="$root/projects" \
        WATCHDOG_DEADLINE_SECONDS=1 \
        "$@" \
        bash "$script" >/dev/null 2>&1
    [[ -f "$state/restart-watchdog-armed" ]] && ARMED=1 || ARMED=0
    QUERIED=$(sort -u "$root/tmux.log" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
}

# ===== 1. default path preserved ===========================================
echo "== default path (no monitor.target_window) =="

R1="$WORK/default"; make_root "$R1"; write_cfg "$R1"
run_loop "$R1" orchestrator "$LOOP"
(( ARMED == 1 )) \
    && pass "config without the key → loop arms on 'orchestrator'" \
    || fail "config without the key → loop did NOT arm (regressed the default path)"
[[ "$QUERIED" == "orchestrator" ]] \
    && pass "config without the key → queries window 'orchestrator'" \
    || fail "config without the key → queried [$QUERIED], want [orchestrator]"

R1b="$WORK/explicit-default"; make_root "$R1b"; write_cfg "$R1b" orchestrator
run_loop "$R1b" orchestrator "$LOOP"
(( ARMED == 1 )) \
    && pass "monitor.target_window: orchestrator → loop arms" \
    || fail "monitor.target_window: orchestrator → loop did NOT arm"

# ===== 2. the #459 regression ==============================================
echo "== #459: non-default monitor.target_window =="

R2="$WORK/claude"; make_root "$R2"; write_cfg "$R2" claude
run_loop "$R2" claude "$LOOP"
(( ARMED == 1 )) \
    && pass "monitor.target_window: claude → loop arms (#459 fixed)" \
    || fail "monitor.target_window: claude → loop did NOT arm (#459 regression)"
[[ "$QUERIED" == "claude" ]] \
    && pass "monitor.target_window: claude → queries window 'claude'" \
    || fail "monitor.target_window: claude → queried [$QUERIED], want [claude]"

# A window name that is neither default nor the historical fallback, so a
# stray hardcode anywhere in the chain cannot pass by coincidence.
R2b="$WORK/mission"; make_root "$R2b"; write_cfg "$R2b" mission-control
run_loop "$R2b" mission-control "$LOOP"
(( ARMED == 1 )) && [[ "$QUERIED" == "mission-control" ]] \
    && pass "monitor.target_window: mission-control → arms, queries it" \
    || fail "mission-control → armed=$ARMED queried=[$QUERIED]"

# ===== 3. fails-on-pre-fix control =========================================
echo "== controls: the pre-fix loop, same fixture =="

PREFIX_LOOP="$WORK/loop-prefix.sh"
if make_prefix_loop "$PREFIX_LOOP"; then
    pass "built the #428-era loop (mutated TARGET= line)"
else
    fail "could NOT rebuild the #428-era loop — the TARGET= line moved; these tests no longer prove the fix DIRECTION. Fix make_prefix_loop."
fi

R3="$WORK/prefix"; make_root "$R3"; write_cfg "$R3" claude
run_loop "$R3" claude "$PREFIX_LOOP"
(( ARMED == 0 )) \
    && pass "pre-fix loop + target_window=claude → does NOT arm (the bug)" \
    || fail "pre-fix loop armed — the fixture does not reproduce #459, so the post-fix pass is meaningless"
[[ "$QUERIED" == "orchestrator" ]] \
    && pass "pre-fix loop queries the hardcoded 'orchestrator'" \
    || fail "pre-fix loop queried [$QUERIED], want [orchestrator]"
[[ -f "$R3/monitor/.state/restart-watchdog-failed" ]] \
    && pass "pre-fix loop writes the failure marker (apply.sh sees watchdog-never-armed)" \
    || fail "pre-fix loop left no failure marker"
grep -q "baseline incomplete" "$R3/monitor/.state/restart-watchdog.log" 2>/dev/null \
    && pass "pre-fix loop dies at 'baseline incomplete'" \
    || fail "pre-fix loop failed for some other reason (log mismatch)"

# ===== 4. single-variable positive control =================================
# Same mutant, same fixture. The ONLY delta is CC_AUTO_TARGET_WINDOW. If this
# arms, the failure in (3) is caused by target resolution and nothing else.
R4="$WORK/prefix-ctl"; make_root "$R4"; write_cfg "$R4" claude
run_loop "$R4" claude "$PREFIX_LOOP" CC_AUTO_TARGET_WINDOW=claude
(( ARMED == 1 )) && [[ "$QUERIED" == "claude" ]] \
    && pass "pre-fix loop + CC_AUTO_TARGET_WINDOW=claude → arms (isolates the cause)" \
    || fail "positive control failed: armed=$ARMED queried=[$QUERIED]"

# ===== 5. precedence =======================================================
echo "== precedence: env → env → config → literal =="

R5="$WORK/prec"; make_root "$R5"; write_cfg "$R5" from-config

run_loop "$R5" from-env "$LOOP" CC_AUTO_TARGET_WINDOW=from-env
(( ARMED == 1 )) && [[ "$QUERIED" == "from-env" ]] \
    && pass "CC_AUTO_TARGET_WINDOW overrides config" \
    || fail "CC_AUTO_TARGET_WINDOW did not override config (queried [$QUERIED])"

run_loop "$R5" from-monitor "$LOOP" MONITOR_TARGET=from-monitor
(( ARMED == 1 )) && [[ "$QUERIED" == "from-monitor" ]] \
    && pass "MONITOR_TARGET overrides config" \
    || fail "MONITOR_TARGET did not override config (queried [$QUERIED])"

run_loop "$R5" from-env "$LOOP" CC_AUTO_TARGET_WINDOW=from-env MONITOR_TARGET=from-monitor
(( ARMED == 1 )) && [[ "$QUERIED" == "from-env" ]] \
    && pass "CC_AUTO_TARGET_WINDOW outranks MONITOR_TARGET" \
    || fail "precedence wrong between the two env vars (queried [$QUERIED])"

run_loop "$R5" from-config "$LOOP"
(( ARMED == 1 )) && [[ "$QUERIED" == "from-config" ]] \
    && pass "config used when neither env var is set" \
    || fail "config leg not consulted (queried [$QUERIED])"

# ===== 6. no config file ===================================================
echo "== fallback: no config file =="

R6="$WORK/nocfg"; make_root "$R6"     # write_cfg deliberately not called
run_loop "$R6" orchestrator "$LOOP"
(( ARMED == 1 )) \
    && pass "no config file → falls back to 'orchestrator'" \
    || fail "no config file → did not fall back (armed=$ARMED)"
[[ "$QUERIED" == "orchestrator" ]] \
    && pass "no config file → never queries an empty window name" \
    || fail "no config file → queried [$QUERIED], want [orchestrator]"

# ===== 7. wiring: apply.sh → watchdog prompt → loop ========================
echo "== wiring: the resolved window reaches the loop =="

WD_PROMPT="$MONITOR_DIR/cc-auto-update-watchdog-prompt.md"
grep -q 'CC_AUTO_TARGET_WINDOW=.\?{{TARGET_WINDOW}}' "$WD_PROMPT" \
    && pass "watchdog prompt passes CC_AUTO_TARGET_WINDOW={{TARGET_WINDOW}} to the loop" \
    || fail "watchdog prompt does not hand the resolved window to the loop"

# apply.sh must actually resolve TARGET_WINDOW from config AND render it into
# that template — the two halves the prompt substitution depends on.
grep -q 'config/load.sh" monitor.target_window orchestrator' "$MONITOR_DIR/cc-auto-update-apply.sh" \
    && pass "apply.sh resolves monitor.target_window from config" \
    || fail "apply.sh lost its config leg for monitor.target_window"
grep -q '"TARGET_WINDOW=\$TARGET_WINDOW"' "$MONITOR_DIR/cc-auto-update-apply.sh" \
    && pass "apply.sh renders TARGET_WINDOW into the watchdog prompt" \
    || fail "apply.sh no longer renders TARGET_WINDOW into the watchdog prompt"

# The loop and apply.sh must resolve identically; a copy-paste drift here is
# exactly what #459 was.
loop_expr=$(grep -m1 '^TARGET=' "$LOOP")
apply_expr=$(grep -m1 '^TARGET_WINDOW=' "$MONITOR_DIR/cc-auto-update-apply.sh")
[[ "${loop_expr#TARGET=}" == "${apply_expr#TARGET_WINDOW=}" ]] \
    && pass "loop and apply.sh share one resolution expression" \
    || fail "loop and apply.sh resolution expressions have drifted apart"

# ---- summary --------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
