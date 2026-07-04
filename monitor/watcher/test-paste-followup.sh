#!/usr/bin/env bash
# Unit tests for monitor/paste-followup.sh (issue #201).
#
# Run: bash monitor/watcher/test-paste-followup.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: shadow `tmux` on PATH with a recorder stub (window list
# from MOCK_TMUX_WINDOWS, every invocation appended to $ACTIONS), and
# point NEXUS_STATE_DIR at a temp dir so the machine-input stamp and
# the ng action-log land in the sandbox. Covers:
#   - happy path: stamp row written, VI-safe tmux sequence (insert
#     guard → set-buffer → paste-buffer → Enter), action-log event
#   - --no-enter skips the submit key
#   - missing window / empty message / unreadable file fail loudly
#     with NO stamp and NO paste
#   - stamp lands even when ng log-action fails (TSV is authoritative)

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$_test_dir/../paste-followup.sh"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
ACTIONS="$WORK/actions.log"

# Recorder tmux stub. list-windows emits MOCK_TMUX_WINDOWS; every
# other subcommand records argv and succeeds (or fails when
# MOCK_TMUX_FAIL names it).
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
cmd="${1:-}"
if [[ "$cmd" == "list-windows" ]]; then
    # Two callers (#323): the existence check queries `-F
    # '#{window_name}'`; resolve_window_id queries `-F
    # '#{window_id}\t#{window_name}'`. Emit @id<TAB>name for the
    # latter so name→@id resolution succeeds.
    fmt=""; prev=""
    for a in "$@"; do [[ "$prev" == "-F" ]] && fmt="$a"; prev="$a"; done
    case "$fmt" in
        *window_id*) for w in ${MOCK_TMUX_WINDOWS:-}; do printf '@3\t%s\n' "$w"; done ;;
        *)           printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    esac
    exit 0
fi
printf '%s\n' "$*" >> "$ACTIONS"
if [[ -n "${MOCK_TMUX_FAIL:-}" && "$cmd" == "$MOCK_TMUX_FAIL" ]]; then
    exit 1
fi
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

export ACTIONS
export PATH="$STUB_DIR:$PATH"

run_helper() {
    # Fresh per-run state dir so stamp assertions are exact.
    RUN_STATE=$(mktemp -d "$WORK/state.XXXXXX")
    HELPER_OUT=$(NEXUS_STATE_DIR="$RUN_STATE" bash "$SCRIPT" "$@" 2>&1)
    HELPER_RC=$?
    : > /dev/null
}

echo '=== happy path: stamp + VI-safe sequence + submit ==='
export MOCK_TMUX_WINDOWS='demo-rerun-lead'
: > "$ACTIONS"
run_helper demo-rerun-lead --message 'please also plot chrX' --note 'unit test'
assert_eq "exit 0" "$HELPER_RC" "0"
assert_contains "machine-input stamp written" \
    "$(cat "$RUN_STATE/machine-input.tsv" 2>/dev/null)" $'demo-rerun-lead\t'
assert_contains "stamp src is paste-followup" \
    "$(awk -F'\t' '{print $3}' "$RUN_STATE/machine-input.tsv" 2>/dev/null)" 'paste-followup'
seq=$(cat "$ACTIONS")
# Targeting is by the resolved @id (#323), not the dotted-safe name.
assert_contains "insert-mode guard sent"  "$seq" 'send-keys -t @3 i BSpace'
assert_contains "buffer loaded"           "$seq" 'set-buffer -b'
assert_contains "buffer pasted to window" "$seq" '-t @3'
assert_contains "Enter submits"           "$seq" 'send-keys -t @3 Enter'
# Order: the stamp must precede any tmux action is enforced by code
# structure; here assert the paste precedes the Enter.
paste_line=$(grep -n 'paste-buffer' "$ACTIONS" | head -1 | cut -d: -f1)
enter_line=$(grep -n 'Enter' "$ACTIONS" | head -1 | cut -d: -f1)
if (( paste_line < enter_line )); then
    echo '  PASS: paste precedes Enter'; PASS=$((PASS+1))
else
    echo '  FAIL: Enter sent before paste' >&2; FAIL=$((FAIL+1))
fi
assert_contains "action-log audit event appended" \
    "$(cat "$RUN_STATE/action-log.jsonl" 2>/dev/null)" '"event":"paste-followup"'
assert_contains "action-log event carries the window" \
    "$(cat "$RUN_STATE/action-log.jsonl" 2>/dev/null)" 'demo-rerun-lead'

echo '=== --no-enter: paste without submit ==='
: > "$ACTIONS"
run_helper demo-rerun-lead --message 'queued text' --no-enter
assert_eq "exit 0" "$HELPER_RC" "0"
assert_not_contains "no Enter sent" "$(cat "$ACTIONS")" 'Enter'
assert_contains "still stamped" \
    "$(cat "$RUN_STATE/machine-input.tsv" 2>/dev/null)" $'demo-rerun-lead\t'

echo '=== --src: injector-identity hint stamped as the src column (#293) ==='
run_helper demo-rerun-lead --message 'continue' --src skeptic-nudge
assert_eq "--src exit 0" "$HELPER_RC" "0"
assert_eq "--src recorded as the ledger src token" \
    "$(awk -F'\t' '{print $3}' "$RUN_STATE/machine-input.tsv" 2>/dev/null)" \
    "skeptic-nudge"

echo '=== --src + --no-enter: src carries the -no-enter suffix ==='
run_helper demo-rerun-lead --message 'queued' --src skeptic-nudge --no-enter
assert_eq "--src --no-enter exit 0" "$HELPER_RC" "0"
assert_eq "src token carries -no-enter suffix" \
    "$(awk -F'\t' '{print $3}' "$RUN_STATE/machine-input.tsv" 2>/dev/null)" \
    "skeptic-nudge-no-enter"

echo '=== --src absent: default src preserved (back-compat) ==='
run_helper demo-rerun-lead --message 'continue'
assert_eq "default src is paste-followup" \
    "$(awk -F'\t' '{print $3}' "$RUN_STATE/machine-input.tsv" 2>/dev/null)" \
    "paste-followup"

echo '=== message from --file and stdin ==='
printf 'multi\nline\nfollow-up\n' > "$WORK/msg.txt"
: > "$ACTIONS"
run_helper demo-rerun-lead --file "$WORK/msg.txt"
assert_eq "--file exit 0" "$HELPER_RC" "0"
: > "$ACTIONS"
RUN_STATE=$(mktemp -d "$WORK/state.XXXXXX")
HELPER_OUT=$(printf 'from stdin\n' | NEXUS_STATE_DIR="$RUN_STATE" bash "$SCRIPT" demo-rerun-lead 2>&1)
HELPER_RC=$?
assert_eq "stdin exit 0" "$HELPER_RC" "0"
assert_contains "stdin path stamped" \
    "$(cat "$RUN_STATE/machine-input.tsv" 2>/dev/null)" $'demo-rerun-lead\t'

echo '=== failure modes: loud, no stamp, no paste ==='
: > "$ACTIONS"
run_helper no-such-window --message 'hi'
assert_eq "missing window: non-zero exit" "$(( HELPER_RC != 0 ))" "1"
assert_contains "missing window: loud stderr" "$HELPER_OUT" 'window not found'
assert_eq "missing window: no stamp" "$(cat "$RUN_STATE/machine-input.tsv" 2>/dev/null | wc -l)" "0"
assert_eq "missing window: no tmux writes" "$(wc -l < "$ACTIONS")" "0"

run_helper demo-rerun-lead --message '   '
assert_eq "blank message: non-zero exit" "$(( HELPER_RC != 0 ))" "1"
assert_contains "blank message: loud stderr" "$HELPER_OUT" 'message is empty'

run_helper demo-rerun-lead --file "$WORK/does-not-exist.txt"
assert_eq "unreadable file: non-zero exit" "$(( HELPER_RC != 0 ))" "1"

echo '=== paste failure after stamp: loud failure, stamp retained ==='
: > "$ACTIONS"
export MOCK_TMUX_FAIL='paste-buffer'
run_helper demo-rerun-lead --message 'doomed'
assert_eq "paste failure: non-zero exit" "$(( HELPER_RC != 0 ))" "1"
assert_contains "paste failure: loud stderr" "$HELPER_OUT" 'paste-buffer failed'
# The pre-paste stamp stays — over-claiming machine input is the
# safe direction (it can only delay an operator seed one round).
assert_contains "paste failure: stamp retained" \
    "$(cat "$RUN_STATE/machine-input.tsv" 2>/dev/null)" $'demo-rerun-lead\t'
unset MOCK_TMUX_FAIL

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
