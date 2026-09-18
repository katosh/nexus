#!/usr/bin/env bash
# monitor/watcher/test-longjob-plugin-arming.sh — the launch-path arming of the
# longjob-watch dispatcher is FAIL-OPEN BY CONSTRUCTION (your-org/nexus-code#1535).
#
# `monitor/_longjob-plugin.sh:longjob_plugin_flag` decides, for every launch
# surface, whether `--plugin-dir <dir>` is spliced into the `claude` command
# line. This suite drives it against a STUB claude whose `--help` and
# `plugin validate` answers are set per case, and asserts that every reason
# not to arm yields (a) an EMPTY flag, never a partial one, (b) rc 1 with a
# stderr line that names the reason, and (c) a row in arming.log — while the
# one good case yields the flag, rc 0, and an `armed` row. It then asserts the
# shipped manifest validates under the REAL binary when one is resolvable.
#
# POTENCY CONTROL: the good case is the control that proves the stub, the
# helper and the assertion are wired — every negative case below reuses the
# same stub with one axis varied (help text, validate rc, validate hang,
# manifest presence, the kill switch), so a "no flag" that came from a broken
# rig rather than from the gate under test would fail the control first.
#
# Also pinned here: the three launcher composers splice the flag (spawn-worker
# fresh + resume + loop-wrapper, claude-loop.sh's own args, _respawn's
# launcher) — by grepping each for the `PLUGIN_ARG`/`plugin_flag`/`PLUGIN_DIR`
# token at the `claude` invocation, so the wiring cannot silently drop out of
# one surface while the other four keep it.
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
WORK=$(mktemp -d -t lj-arm-XXXXXX); trap 'rm -rf "$WORK"' EXIT

# A code root with the helper, a manifest, and a stub claude.
ROOT="$WORK/root"; mkdir -p "$ROOT/monitor/longjob-plugin/.claude-plugin" "$ROOT/config" "$ROOT/monitor/.state"
cp "$REPO_ROOT/monitor/_longjob-plugin.sh" "$ROOT/monitor/"
cp "$REPO_ROOT/monitor/_claude-bin.sh" "$ROOT/monitor/"
cp "$REPO_ROOT/monitor/longjob-plugin/.claude-plugin/plugin.json" "$ROOT/monitor/longjob-plugin/.claude-plugin/"
STUB="$WORK/claude-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
# LJ_HELP: "full" (advertises --plugin-dir <path>), "old" (no such flag), "hang"
# LJ_VALIDATE_RC: exit code for `plugin validate`; "hang" sleeps
case "${1:-}" in
  --help)
    case "${LJ_HELP:-full}" in
      full) printf 'Usage: claude [options]\n  --name <name>   Set a display name\n  --plugin-dir <path>   Load a plugin from a directory\n' ;;
      old)  printf 'Usage: claude [options]\n  --name <name>   Set a display name\n' ;;
      hang) sleep 60 ;;
    esac; exit 0 ;;
  plugin)
    [[ "${2:-}" == validate ]] || exit 2
    [[ "${LJ_VALIDATE_RC:-0}" == hang ]] && sleep 60
    exit "${LJ_VALIDATE_RC:-0}" ;;
  --version) echo "0.0.0-stub"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$STUB"

# run_case <name> → prints "rc|flag|stderr|logrow"
run_case() {
    local name="$1" out err rc row
    mkdir -p "$ROOT/monitor/.state/longjob"; : > "$ROOT/monitor/.state/longjob/arming.log"
    out=$(bash -c '
        set -uo pipefail
        export NEXUS_ROOT="$1" NEXUS_STATE_DIR="$1/monitor/.state" CLAUDE_BIN="$2" NEXUS_CLAUDE_HELP_TIMEOUT=2 NEXUS_LONGJOB_VALIDATE_TIMEOUT=2
        . "$1/monitor/_claude-bin.sh" >/dev/null 2>&1
        . "$1/monitor/_longjob-plugin.sh"
        longjob_plugin_flag "'"$name"'"; rc=$?
        printf "\n__RC__=%s\n" "$rc"' _ "$ROOT" "$STUB" 2>"$WORK/err.$name")
    rc=$(sed -n 's/^__RC__=//p' <<<"$out"); out=$(sed '/^__RC__=/d' <<<"$out" | tr -d '\n')
    err=$(tr '\n' ' ' < "$WORK/err.$name")
    row=$(tail -n1 "$ROOT/monitor/.state/longjob/arming.log" 2>/dev/null | cut -f3-)
    printf '%s|%s|%s|%s' "$rc" "$out" "$err" "$row"
}

echo "=== control: everything in order → the flag, rc 0, an armed row ==="
r=$(LJ_HELP=full LJ_VALIDATE_RC=0 run_case good)
rc="${r%%|*}"; rest="${r#*|}"; flag="${rest%%|*}"; rest="${rest#*|}"; err="${rest%%|*}"; row="${rest#*|}"
(( rc == 0 )) && [[ "$flag" == "--plugin-dir $ROOT/monitor/longjob-plugin" ]] && ok "control: rc 0 and the exact flag ($flag)" || bad "control: rc=$rc flag='$flag' err='$err'"
[[ "$row" == armed* ]] && ok "control: arming.log row 'armed'" || bad "control row: '$row'"
[[ -z "$err" ]] && ok "control: nothing on stderr" || bad "control stderr: $err"

neg() {   # <name> <expect-reason-substr> <expect-stderr-substr>
    local r rc flag err row
    r=$(run_case "$1"); rc="${r%%|*}"; rest="${r#*|}"; flag="${rest%%|*}"; rest="${rest#*|}"; err="${rest%%|*}"; row="${rest#*|}"
    (( rc == 1 )) && [[ -z "$flag" ]] && ok "$1: rc 1 and an EMPTY flag (never partial)" || bad "$1: rc=$rc flag='$flag'"
    [[ "$row" == skipped*"$2"* ]] && ok "$1: arming.log row 'skipped … $2'" || bad "$1 row: '$row'"
    [[ "$err" == *"$3"* ]] && ok "$1: stderr names the reason" || bad "$1 stderr: '$err'"
}
echo "=== kill switch ==="
MONITOR_LONGJOB_ENABLED=false neg killswitch "disabled" "DISABLED"
echo "=== binary without --plugin-dir ==="
LJ_HELP=old neg oldbinary "does not advertise" "does not support '--plugin-dir'"
echo "=== --help hangs (bounded probe) ==="
LJ_HELP=hang neg helphang "does not advertise" "TIMED OUT"
echo "=== validate fails ==="
LJ_HELP=full LJ_VALIDATE_RC=1 neg badmanifest "validate failed rc=1" "FAILED (rc 1)"
echo "=== validate hangs (bounded; a timeout is NOT a pass) ==="
LJ_HELP=full LJ_VALIDATE_RC=hang neg validatehang "validate timed out" "TIMED OUT"
echo "=== manifest missing ==="
mv "$ROOT/monitor/longjob-plugin/.claude-plugin/plugin.json" "$WORK/plugin.json.bak"
LJ_HELP=full neg nomanifest "manifest unreadable" "manifest missing"
mv "$WORK/plugin.json.bak" "$ROOT/monitor/longjob-plugin/.claude-plugin/plugin.json"
echo "=== CLAUDE_BIN unset ==="
r=$(bash -c 'export NEXUS_ROOT="$1" NEXUS_STATE_DIR="$1/monitor/.state"; unset CLAUDE_BIN; . "$1/monitor/_longjob-plugin.sh"; longjob_plugin_flag w; echo "|rc=$?"' _ "$ROOT" 2>&1)
[[ "$r" == *"CLAUDE_BIN unset"*"|rc=1" ]] && ok "no CLAUDE_BIN: rc 1, says so, no flag" || bad "no CLAUDE_BIN: $r"

echo "=== the row lands in the CALLER's state dir, never the inherited NEXUS_ROOT (bundle-2609 soak) ==="
# Measured on the operator's live primary, 2026-09-16: 17 `skipped … does not
# advertise` rows for `orchestrator` and `mission-control` that no launch
# wrote — suites respawning against a FIXTURE root while the helper resolved
# its log from the agent shell's inherited NEXUS_ROOT. Pre-fix every case
# below lands its row in the DECOY (measured before the second argument
# existed); the bare-call case is the documented fallback and stays so.
DECOY="$WORK/decoy"; mkdir -p "$DECOY/monitor/.state"
_decoy_case() {   # <window> <state-dir-arg or ''> <NEXUS_TEST_SUITE or ''> → "rc|verdict-in-ROOT|decoy-rows|src"
    mkdir -p "$ROOT/monitor/.state/longjob"; : > "$ROOT/monitor/.state/longjob/arming.log"
    rm -rf "$DECOY/monitor/.state/longjob"
    LJ_HELP=old bash -c '
        set -uo pipefail
        export NEXUS_ROOT="$3" CLAUDE_BIN="$2" NEXUS_CLAUDE_HELP_TIMEOUT=2; unset NEXUS_STATE_DIR
        if [[ -n "$6" ]]; then export NEXUS_TEST_SUITE="$6"; else unset NEXUS_TEST_SUITE; fi
        . "$1/monitor/_claude-bin.sh" >/dev/null 2>&1
        . "$1/monitor/_longjob-plugin.sh"
        if [[ -n "$5" ]]; then longjob_plugin_flag "$4" "$5"; else longjob_plugin_flag "$4"; fi' \
        _ "$ROOT" "$STUB" "$DECOY" "$1" "$2" "$3" >/dev/null 2>&1
    local rc=$? verdict='' drows=0 src='-'
    verdict=$(tail -n1 "$ROOT/monitor/.state/longjob/arming.log" 2>/dev/null | cut -f3)
    [[ -f "$DECOY/monitor/.state/longjob/arming.log" ]] && drows=$(wc -l < "$DECOY/monitor/.state/longjob/arming.log")
    [[ -n "$verdict" ]] && src=$(tail -n1 "$ROOT/monitor/.state/longjob/arming.log" | cut -f5)
    printf '%s|%s|%s|%s' "$rc" "$verdict" "$((drows))" "$src"
}
r=$(_decoy_case w "$ROOT/monitor/.state" watcher/test-zz-fixture.sh)
[[ "$r" == "1|skipped|0|watcher/test-zz-fixture.sh" ]] && ok "caller's state dir wins over an inherited NEXUS_ROOT: row in the fixture, NOTHING in the decoy, src = the suite" || bad "caller state dir: got '$r' (want 1|skipped|0|watcher/test-zz-fixture.sh)"
r=$(_decoy_case w "$ROOT/monitor/.state" '')
[[ "$r" == "1|skipped|0|" ]] && ok "outside run-tests.sh the src column is EMPTY (a real launch's row)" || bad "empty src: got '$r'"
r=$(_decoy_case w '' '')
[[ "$r" == "1||1|-" ]] && ok "bare call (no state dir, no NEXUS_STATE_DIR) falls back to the inherited NEXUS_ROOT — the documented production chain, unchanged" || bad "bare call: got '$r' (want 1||1|-)"
grep -qF 'longjob_plugin_flag "$target_window" "${NEXUS_STATE_DIR:-$nexus_root/monitor/.state}"' "$REPO_ROOT/monitor/watcher/_respawn.sh" && ok "_respawn.sh passes the state dir it resolved" || bad "_respawn.sh: the plugin call does not pass its state dir"
grep -qF 'longjob_plugin_flag "$w" "$STATE_DIR"' "$REPO_ROOT/monitor/spawn-worker.sh" && ok "spawn-worker.sh passes its resolved STATE_DIR" || bad "spawn-worker.sh: the plugin call does not pass STATE_DIR"

echo "=== the shipped manifest validates under the real binary (when resolvable) ==="
REAL=$(bash -c "cd '$REPO_ROOT' && . monitor/_claude-bin.sh >/dev/null 2>&1; echo \"\$CLAUDE_BIN\"" 2>/dev/null)
if [[ -n "$REAL" && -x "$REAL" ]]; then
    timeout 60 "$REAL" plugin validate "$REPO_ROOT/monitor/longjob-plugin" >"$WORK/v.out" 2>&1; rc=$?
    (( rc == 0 )) && ok "real 'claude plugin validate monitor/longjob-plugin' → rc 0" || bad "real validate rc=$rc: $(cat "$WORK/v.out")"
    grep -q 'experimental' "$REPO_ROOT/monitor/longjob-plugin/.claude-plugin/plugin.json" && ok "manifest declares experimental.monitors (the supported form; top-level is announced for removal)" || bad "manifest not under experimental"
else
    printf '  SKIP: no real claude resolvable; the shipped-manifest check is unmeasured here\n'
fi
jq -e '.experimental.monitors | length == 1 and .[0].command != "" and .[0].when == "always"' "$REPO_ROOT/monitor/longjob-plugin/.claude-plugin/plugin.json" >/dev/null && ok "manifest: exactly one monitor, a command, when=always" || bad "manifest shape"
[[ -x "$REPO_ROOT/monitor/longjob-plugin/dispatch.sh" ]] && grep -q 'longjob-watch.sh" dispatch' "$REPO_ROOT/monitor/longjob-plugin/dispatch.sh" && ok "dispatch.sh execs longjob-watch.sh dispatch" || bad "dispatch.sh"

echo "=== every launch surface splices the flag ==="
sw="$REPO_ROOT/monitor/spawn-worker.sh"
n=$(grep -o 'PLUGIN_ARG:+ \$PLUGIN_ARG' "$sw" | wc -l); (( n == 3 )) && ok "spawn-worker.sh: 3 launcher lines carry \${PLUGIN_ARG:+ …} (fresh, resume, loop)" || bad "spawn-worker.sh PLUGIN_ARG splice count $n (want 3)"
grep -q '^PLUGIN_ARG=\$(_spawn_plugin_arg "\$WINDOW_NAME")' "$sw" && grep -q '^    PLUGIN_ARG=\$(_spawn_plugin_arg "\$WINDOW_NAME")' "$sw" && ok "spawn-worker.sh: PLUGIN_ARG computed on both the fresh and the resume path" || bad "spawn-worker.sh PLUGIN_ARG assignment"
grep -q -- '--plugin-dir)          PLUGIN_DIR=' "$REPO_ROOT/monitor/claude-loop.sh" && grep -q 'args+=( --plugin-dir "\$PLUGIN_DIR" )' "$REPO_ROOT/monitor/claude-loop.sh" && ok "claude-loop.sh parses --plugin-dir and re-passes it on every (re)invocation" || bad "claude-loop.sh plugin-dir"
grep -q '\${name_flag}\${plugin_flag}\$continue_flag' "$REPO_ROOT/monitor/watcher/_respawn.sh" && ok "_respawn.sh: the orchestrator launcher carries \${plugin_flag}" || bad "_respawn.sh splice"
# The loop wrapper must ACCEPT the flag the spawner passes: an unknown arg is fatal there.
out=$(bash "$REPO_ROOT/monitor/claude-loop.sh" --window w --prompt-file /dev/null --plugin-dir /x --no-such-flag 2>&1); rc=$?
[[ "$out" == *"unknown arg: --no-such-flag"* ]] && ok "claude-loop.sh: --plugin-dir accepted (the NEXT unknown flag is what it rejects)" || bad "claude-loop.sh arg parse: $out"

echo; echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }; exit 1
