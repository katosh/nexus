#!/usr/bin/env bash
# End-to-end tests for the configurable target-window plumbing.
#
# `monitor.target_window` / `--target` is supposed to make the WHOLE
# watcher control surface point at the configured window; historically
# several live code paths compared window names against the hardcoded
# string "orchestrator" instead, so any non-default target broke in
# subtle ways (the live incident: your-org/nexus-code issue 209, where
# a `claude` target crash-looped because the session-pin hook renamed
# the window to the hardcoded name).
#
# Every section here drives a code path with TARGET set to a
# NON-default window name ("mission-control") and asserts the path
# resolves the configured name, not the literal:
#
#   1. Unstick Case-D scope gate   (_unstick.sh) — fires on the
#      configured window, NOT on a window that merely happens to be
#      named "orchestrator".
#   2. Unstick Case-B heads-up     (_unstick.sh) — pastes into the
#      configured window.
#   3. Worker enumeration          (_idle_probe.sh) — the configured
#      window is excluded from the worker pool; reserved legacy names
#      stay excluded too.
#   4. Bell scan                   (main.sh list_bell_windows) — bells
#      on the configured window are not "worker bells".
#   5. Paste-targeting + liveness  (main.sh paste_to_target) — the
#      liveness stamp is recorded for pastes to the configured window
#      and NOT for pastes to other windows.
#   6. Respawn launcher + window pin (_respawn.sh) — the launcher
#      exports NEXUS_ORCHESTRATOR_WINDOW=<target> and the spawned
#      window gets automatic-rename/allow-rename off.
#   7. Session-pin hook rename     (hooks/orchestrator-session-pin.sh)
#      — renames to $NEXUS_ORCHESTRATOR_WINDOW, falling back to
#      "orchestrator" only when the env var is absent.
#
# Run: bash monitor/watcher/test-target-config.sh

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0

# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

# The non-default target every section exercises.
CUSTOM_TARGET="mission-control"

# ---- shared mock tmux -----------------------------------------------------
# Bash-function shadow recording every invocation to $ACTIONS, plus a
# PATH shim so `command -v tmux` succeeds. Mirrors test-unstick.sh's
# harness; supports the verbs used across all units under test here.

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PANES_DIR="$WORK/panes"
ACTIONS="$WORK/actions.log"
WINDOWS_LIST=""
mkdir -p "$PANES_DIR"
: > "$ACTIONS"

tmux() {
    local sub="$1"; shift
    case "$sub" in
        capture-pane)
            local target=""
            while (( $# > 0 )); do
                case "$1" in
                    -t) target="$2"; shift 2 ;;
                    *)  shift ;;
                esac
            done
            if [[ -n "$target" && -f "$PANES_DIR/$target" ]]; then
                cat "$PANES_DIR/$target"
                return 0
            fi
            return 1
            ;;
        list-windows)
            # Honour the -F format minimally: tests seed WINDOWS_LIST
            # with rows already shaped for the format the unit under
            # test requests. For resolve_window_id's
            # `-F '#{window_id}\t#{window_name}'` (#323), synthesize a
            # deterministic @<lineno> id per window so the resolver
            # yields a stable @id the assertions can pin.
            local F=""
            while (( $# > 0 )); do
                case "$1" in -F) F="$2"; shift 2 ;; *) shift ;; esac
            done
            if [[ "$F" == *'#{window_id}'* ]]; then
                printf '%s\n' "$WINDOWS_LIST" | awk 'NF{printf "@%d\t%s\n", NR, $0}'
            else
                printf '%s\n' "$WINDOWS_LIST"
            fi
            return 0
            ;;
        send-keys|load-buffer|paste-buffer|delete-buffer|rename-window|set-window-option|kill-window|new-window)
            printf '%s %s\n' "$sub" "$*" >> "$ACTIONS"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux

# PATH shim so `command -v tmux` resolves; the bash function above
# still shadows actual invocations inside this process.
SHIM_DIR="$WORK/shim-bin"
mkdir -p "$SHIM_DIR"
printf '#!/bin/bash\nexit 0\n' > "$SHIM_DIR/tmux"
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# AskUserQuestion chip-bar fixture (live overlay shape — the three
# gating literals with the footer bottom-anchored). Copied from
# test-unstick.sh.
askuq_pane() {
    local q="${1:-Which option should I pick?}"
    cat <<EOF
some earlier output

  ${q}

  ❯ 1. Option A
    2. Option B
    Type something.
    Chat about this

  Esc to cancel
EOF
}

# ---- 1 + 2: unstick Case-D scope gate + Case-B paste targeting ------------

echo '=== unstick: Case-D gate + Case-B heads-up follow the configured target ==='

UNSTICK_DIR="$WORK/unstick"
UNSTICK_LOG="$WORK/watcher-unstick.log"
mkdir -p "$UNSTICK_DIR"
: > "$UNSTICK_LOG"
AUTO_UNSTICK="true"
WATCHER_WINDOW="watcher"
TARGET="$CUSTOM_TARGET"
ACTION_LOG="$WORK/action-log.jsonl"
: > "$ACTION_LOG"
RATELIMIT_PROBE="false"
RATELIMIT_HEURISTIC_MIN="30"
RATELIMIT_ACK_TIMEOUT_S="60"
PROBE_MODEL="claude-haiku-4-5-20251001"
API_ERROR_BACKOFF_MIN="30"
ON_DIALOG="auto-dismiss"
export AUTO_UNSTICK WATCHER_WINDOW TARGET UNSTICK_DIR UNSTICK_LOG \
       ACTION_LOG RATELIMIT_PROBE RATELIMIT_HEURISTIC_MIN \
       RATELIMIT_ACK_TIMEOUT_S PROBE_MODEL API_ERROR_BACKOFF_MIN \
       ON_DIALOG

# shellcheck source=_unstick.sh
source "$_test_dir/_unstick.sh"

# Both the configured target AND a window that merely carries the
# legacy name "orchestrator" show a live AskUQ overlay. Only the
# configured target may get the Case-D dismiss.
WINDOWS_LIST=$'watcher\nmission-control\norchestrator\nsome-worker'
askuq_pane > "$PANES_DIR/$CUSTOM_TARGET"
askuq_pane > "$PANES_DIR/orchestrator"

detect_and_unstick

log_content=$(<"$UNSTICK_LOG")
assert_contains "Case D fires on the configured target window" \
    "$log_content" "window=$CUSTOM_TARGET case=D action=dismissed-and-pasted"
assert_not_contains "Case D does NOT fire on a non-target window named 'orchestrator'" \
    "$log_content" "window=orchestrator case=D"
actions_content=$(<"$ACTIONS")
assert_contains "Case D dismissal pastes into the configured target window" \
    "$actions_content" "paste-buffer"
assert_contains "Case D paste-buffer targets the configured window" \
    "$actions_content" "-t $CUSTOM_TARGET"
assert_not_contains "no Case D Escape sent to the 'orchestrator'-named bystander" \
    "$actions_content" "send-keys -t orchestrator Escape"

# Case B heads-up paste: must land in the configured target.
: > "$ACTIONS"
: > "$UNSTICK_LOG"
WINDOWS_LIST=$'watcher\nmission-control\nstuck-worker'
_cascade_heads_up_orchestrator 1 "stuck-worker"
actions_content=$(<"$ACTIONS")
assert_contains "Case B heads-up pastes into the configured target window" \
    "$actions_content" "paste-buffer"
assert_contains "Case B paste targets the configured window, not 'orchestrator'" \
    "$actions_content" "-t $CUSTOM_TARGET"

# ---- 3: idle-probe worker enumeration -------------------------------------

echo '=== idle probe: configured target excluded from the worker pool ==='

# shellcheck source=_idle_probe.sh
source "$_test_dir/_idle_probe.sh"

TARGET="$CUSTOM_TARGET"
export TARGET
WINDOWS_LIST=$(printf '%s|100|0\n%s|100|1\n%s|100|2\n%s|100|3\n%s|100|4\n%s|100|5' \
    "watcher" "$CUSTOM_TARGET" "orchestrator" "claude" "monitor" "real-worker")
workers=$(_idle_list_worker_windows)
assert_not_contains "configured target excluded from worker enumeration" \
    "$workers" "$CUSTOM_TARGET"
assert_not_contains "reserved name 'orchestrator' still excluded" "$workers" "orchestrator"
assert_not_contains "reserved name 'claude' still excluded" "$workers" "claude"
assert_not_contains "reserved name 'watcher' still excluded" "$workers" "watcher"
assert_not_contains "reserved name 'monitor' still excluded" "$workers" "monitor"
assert_contains "real worker still enumerated" "$workers" "real-worker"

# Default-target regression guard: with TARGET unset the lister
# behaves exactly as before (orchestrator excluded by fallback).
unset TARGET
workers=$(_idle_list_worker_windows)
assert_not_contains "TARGET unset → 'orchestrator' excluded via fallback default" \
    "$workers" "orchestrator"
assert_contains "TARGET unset → real worker still enumerated" "$workers" "real-worker"

# ---- 4: main.sh bell scan ---------------------------------------------------

echo '=== main.sh list_bell_windows: bells on the configured target are not worker bells ==='

# Extract just the function body from main.sh (same pattern as
# test-snapshot-tmux-filter.sh) so we exercise the real code without
# triggering main.sh's top-level init.
_main_sh="$_test_dir/main.sh"
fn_body=$(sed -n '/^list_bell_windows() {/,/^}/p' "$_main_sh")
if [[ -z "$fn_body" ]]; then
    echo "FAIL: could not extract list_bell_windows() from $_main_sh" >&2
    FAIL=$(( FAIL + 1 ))
else
    eval "$fn_body"
    TARGET="$CUSTOM_TARGET"
    # Format: index|name|bell_flag — every window is ringing. The `•bell`
    # row is a transient sandbox-notify window (bell_flag=1): a hook
    # subprocess with no tty rings via `tmux new-window -n '•bell'`, which
    # would otherwise surface here as a phantom standing bell. The `^•`
    # drop (matching snapshot_local + _idle_list_worker_windows) excludes it.
    WINDOWS_LIST=$(printf '0|watcher|1\n1|%s|1\n2|orchestrator|1\n3|claude|1\n4|monitor|1\n5|real-worker|1\n6|•bell|1' \
        "$CUSTOM_TARGET")
    bells=$(list_bell_windows)
    assert_not_contains "bell on configured target excluded from worker-bell scan" \
        "$bells" "$CUSTOM_TARGET"
    assert_not_contains "bell on legacy 'orchestrator' name still excluded" "$bells" "orchestrator"
    assert_not_contains "bell on legacy 'claude' name still excluded" "$bells" "claude"
    assert_not_contains "transient •bell window excluded from worker-bell scan" "$bells" "•bell"
    assert_contains "bell on a real worker still reported" "$bells" "real-worker"
fi

# ---- 5: main.sh paste_to_target liveness stamp ------------------------------

echo '=== main.sh paste_to_target: liveness stamp follows the configured target ==='

fn_body=$(sed -n '/^paste_to_target() {/,/^}/p' "$_main_sh")
if [[ -z "$fn_body" ]]; then
    echo "FAIL: could not extract paste_to_target() from $_main_sh" >&2
    FAIL=$(( FAIL + 1 ))
else
    eval "$fn_body"
    # paste_to_target now resolves name→@id (#323); provide the real
    # resolver. It calls the `tmux` shell-function stubbed above, which
    # synthesizes @<lineno> ids for the window_id format.
    # shellcheck source=_tmux-window.sh
    source "$_test_dir/../_tmux-window.sh"
    # Stub the two liveness helpers the function calls; record stamps.
    STAMP_LOG="$WORK/stamp.log"
    : > "$STAMP_LOG"
    _orchestrator_refresh_pin() { :; }
    _orchestrator_record_paste() { printf 'record-paste %s\n' "$1" >> "$STAMP_LOG"; }
    ORCH_PIN_FILE="$WORK/orchestrator-session-id"
    ORCH_LAST_PASTE_FILE="$WORK/orchestrator-last-paste.ts"
    TARGET="$CUSTOM_TARGET"

    body_file="$WORK/emit-body.txt"
    printf 'hello from the watcher\n' > "$body_file"

    # capture-pane against the target must return something for the
    # (skipped, sig-less) verification path; seed pane content.
    printf 'hello from the watcher\n' > "$PANES_DIR/$CUSTOM_TARGET"
    printf 'hello from the watcher\n' > "$PANES_DIR/some-worker"

    # Paste to the configured target → liveness stamp recorded.
    WINDOWS_LIST=$'watcher\nmission-control\nsome-worker'
    : > "$ACTIONS"
    paste_to_target "$CUSTOM_TARGET" "$body_file"
    rc=$?
    assert_eq "paste to configured target succeeds" "$rc" "0"
    assert_contains "paste to configured target records the liveness stamp" \
        "$(<"$STAMP_LOG")" "record-paste $ORCH_LAST_PASTE_FILE"
    # mission-control is line 2 of WINDOWS_LIST → the stub resolves it to
    # @2; paste_to_target must target by that @id, not the name (#323).
    assert_contains "paste-buffer targeted the configured window by @id" \
        "$(<"$ACTIONS")" "-t @2"

    # Paste to a non-target window (over-limit worker WAKE path) →
    # NO liveness stamp, AND targeted by @id (#323): a dotted worker
    # name would dot-parse under `-t name` and the wake would silently
    # never land. some-worker is line 3 → @3.
    : > "$STAMP_LOG"
    : > "$ACTIONS"
    paste_to_target "some-worker" "$body_file"
    rc=$?
    assert_eq "paste to non-target worker window succeeds" "$rc" "0"
    assert_empty "paste to non-target window does NOT record the liveness stamp" \
        "$(<"$STAMP_LOG")"
    assert_contains "worker-wake paste targeted the worker by @id" \
        "$(<"$ACTIONS")" "-t @3"
fi

# ---- 6: respawn launcher env + window-name pin ------------------------------

echo '=== _respawn.sh: launcher exports the configured window + rename pins set ==='

# shellcheck source=_respawn.sh
source "$_test_dir/_respawn.sh"

CLAUDE_BIN="/fake/claude"
launcher="$WORK/launcher.sh"
_respawn_compose_launcher "$launcher" "/fake/nexus-root" "" "" "$CUSTOM_TARGET"
launcher_body=$(<"$launcher")
assert_contains "launcher exports NEXUS_ORCHESTRATOR_WINDOW=<configured target>" \
    "$launcher_body" "export NEXUS_ORCHESTRATOR_WINDOW=\"$CUSTOM_TARGET\""
assert_contains "launcher still exports the role marker" \
    "$launcher_body" "export NEXUS_IS_ORCHESTRATOR=1"

# Omitted target arg → falls back to the default window name (keeps
# pre-existing 4-arg callers working).
_respawn_compose_launcher "$launcher" "/fake/nexus-root" "" ""
launcher_body=$(<"$launcher")
assert_contains "launcher target omitted → defaults to 'orchestrator'" \
    "$launcher_body" 'export NEXUS_ORCHESTRATOR_WINDOW="orchestrator"'

# _respawn_spawn_window pins the window name (issue 209).
: > "$ACTIONS"
WINDOWS_LIST=""
_respawn_spawn_window "$CUSTOM_TARGET" "/fake/nexus-root" "$launcher"
actions_content=$(<"$ACTIONS")
assert_contains "spawn creates the configured window" \
    "$actions_content" "new-window -d -n $CUSTOM_TARGET"
assert_contains "spawn disables automatic-rename on the configured window" \
    "$actions_content" "set-window-option -t $CUSTOM_TARGET automatic-rename off"
assert_contains "spawn disables allow-rename on the configured window" \
    "$actions_content" "set-window-option -t $CUSTOM_TARGET allow-rename off"

# ---- 7: session-pin hook renames to the configured window -------------------

echo '=== orchestrator-session-pin.sh: rename follows NEXUS_ORCHESTRATOR_WINDOW ==='

HOOK="$_test_dir/../hooks/orchestrator-session-pin.sh"
HOOK_ROOT="$WORK/hook-root"
mkdir -p "$HOOK_ROOT/monitor/.state"
SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
PAYLOAD=$(printf '{"session_id":"%s"}' "$SID")

# The hook is a separate bash process; run it under `env -i` so the
# exported `tmux` bash function above (BASH_FUNC_tmux%%) can't leak
# into it and shadow the PATH stub. Give it a recording tmux stub.
HOOK_STUB_DIR="$WORK/hook-stub-bin"
HOOK_TMUX_LOG="$WORK/hook-tmux-calls.log"
mkdir -p "$HOOK_STUB_DIR"
cat > "$HOOK_STUB_DIR/tmux" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$HOOK_TMUX_LOG"
exit 0
STUB
chmod +x "$HOOK_STUB_DIR/tmux"

# With NEXUS_ORCHESTRATOR_WINDOW set → rename to the configured window.
: > "$HOOK_TMUX_LOG"
env -i PATH="$HOOK_STUB_DIR:$PATH" TMUX_PANE="%42" NEXUS_ROOT="$HOOK_ROOT" \
    NEXUS_IS_ORCHESTRATOR=1 NEXUS_ORCHESTRATOR_WINDOW="$CUSTOM_TARGET" \
    bash "$HOOK" <<<"$PAYLOAD"
hook_calls=$(<"$HOOK_TMUX_LOG")
assert_contains "hook renames the pane to the configured window" \
    "$hook_calls" "rename-window -t %42 $CUSTOM_TARGET"
assert_not_contains "hook does NOT rename to the hardcoded 'orchestrator'" \
    "$hook_calls" "rename-window -t %42 orchestrator"
assert_contains "hook disables allow-rename (issue 209 hardening)" \
    "$hook_calls" "set-window-option -t %42 allow-rename off"

# Without NEXUS_ORCHESTRATOR_WINDOW → falls back to "orchestrator"
# (pre-existing sessions launched before the env var existed).
: > "$HOOK_TMUX_LOG"
env -i PATH="$HOOK_STUB_DIR:$PATH" TMUX_PANE="%42" NEXUS_ROOT="$HOOK_ROOT" \
    NEXUS_IS_ORCHESTRATOR=1 \
    bash "$HOOK" <<<"$PAYLOAD"
hook_calls=$(<"$HOOK_TMUX_LOG")
assert_contains "env var absent → hook falls back to renaming to 'orchestrator'" \
    "$hook_calls" "rename-window -t %42 orchestrator"

# ---- summary ----------------------------------------------------------------

th_summary_and_exit
