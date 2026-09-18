#!/usr/bin/env bash
# Tests for the decision-event channel groundwork (issue #129):
#
#   1. monitor/hooks/decision-emit.sh, given a Notification payload
#      on stdin, writes a well-formed per-decision JSON event to
#      $NEXUS_ROOT/monitor/.state/decisions/<window>.<fp>.json.
#   2. Re-firing the same prompt yields the same fingerprint
#      (file gets overwritten, not duplicated).
#   3. monitor/hooks/decision-mark-unresolved.sh marks lingering
#      files with unresolved=true (Stop-hook surface).
#   4. render_pending_decisions in monitor/watcher/_idle_probe.sh
#      emits the operator's expected line shape, cites the file
#      path, dedupes against the cooldown TSV, and re-emits after
#      DECISION_REEMIT_COOLDOWN_SECONDS elapses.
#   5. File-removal ack drops the entry on the next cycle.
#   6. *.handled.json tombstones are honoured (silently skipped).
#   7. decision-emit.sh honours the tombstone on the write path:
#      a sibling `<window>.<fp>.handled.json` makes a same-fingerprint
#      re-fire a silent no-op, while a different fingerprint still
#      writes its own `<fp>.json`.
#
# Run: bash monitor/watcher/test-pending-decisions.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_monitor_dir=$(cd "$_test_dir/.." && pwd)
EMIT_SCRIPT="$_monitor_dir/hooks/decision-emit.sh"
MARK_SCRIPT="$_monitor_dir/hooks/decision-mark-unresolved.sh"

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
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing %q\n  in: <<%s>>\n' "$label" "$needle" "$hay" >&2
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
assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        printf '  PASS: %s (%s)\n' "$label" "$path"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — file missing: %s\n' "$label" "$path" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_no_file() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        printf '  FAIL: %s — file unexpectedly present: %s\n' "$label" "$path" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

command -v jq >/dev/null 2>&1 || {
    echo "test-pending-decisions: jq missing — decision handler requires it" >&2
    exit 2
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export NEXUS_ROOT="$WORK"
export NEXUS_WORKER_WINDOW="worker-A"
mkdir -p "$NEXUS_ROOT/monitor/.state"
mkdir -p "$NEXUS_ROOT/monitor"
# Copy handler scripts into the fake nexus root so their absolute
# self-references resolve.
mkdir -p "$NEXUS_ROOT/monitor/hooks"
cp "$EMIT_SCRIPT" "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
cp "$MARK_SCRIPT" "$NEXUS_ROOT/monitor/hooks/decision-mark-unresolved.sh"
chmod +x "$NEXUS_ROOT/monitor/hooks/"*.sh

DECISIONS_DIR="$NEXUS_ROOT/monitor/.state/decisions"

# tmux stub (watcher-emit-noise, Class 3). render_pending_decisions now
# re-stats each decision's window against the live tmux set and drops rows
# for windows that no longer exist. Shadow tmux so `list-windows` reports
# exactly the windows this test treats as live (via MOCK_TMUX_WINDOWS);
# the render tests below reference worker-A / worker-B / worker-E, so the
# default set lists all three. A later test overrides the var to exercise
# the dead-window drop. Front of PATH so the in-process render picks it up.
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
#
# Since #790 the renderer asks for `#{window_name}|#{window_index}` in ONE
# query (three consumers: the dead-window emit skip, the dead-window reap,
# and the pane gate's name→index lookup). The stub honours the requested
# format so a test can control indexes; a bare name list still parses as
# name-with-no-index, which is what the pre-#790 tests below exercise and
# what the gate must fail OPEN on.
#
# The delimiter is `|`, not a TAB, and the stub keys on that deliberately:
# `test-tmux-window-resolver.sh` F1/F3 forbids a non-printable delimiter
# because tmux rewrites it to `_` in a non-UTF-8 locale with $TMUX unset.
# A stub that accepted either would let the production format regress to a
# TAB with this suite still green.
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows)
        fmt=""; prev=""
        for a in "$@"; do [[ "$prev" == "-F" ]] && fmt="$a"; prev="$a"; done
        i=1
        for w in ${MOCK_TMUX_WINDOWS:-}; do          # unquoted: word-split into rows
            if [[ "$fmt" == *'window_index'* && "$fmt" == *'|'* ]]; then
                printf '%s|%s\n' "$w" "$i"
            else
                printf '%s\n' "$w"
            fi
            i=$(( i + 1 ))
        done ;;
    *)            : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"
PATH="$STUB_DIR:$PATH"
export MOCK_TMUX_WINDOWS="worker-A worker-B worker-E"

# pane-state stub (#790). `_idle_pane_state_line` resolves
# `$NEXUS_ROOT/monitor/pane-state.sh` first, so a stub there is what the
# renderer's gate will call. Per-index canned lines via
# MOCK_PANE_STATE_<index>; every call is logged so a test can assert the
# gate ran AT ALL (a gate that is never invoked passes every
# "row suppressed" assertion by accident if the row was suppressed for
# some other reason).
export PANE_STATE_LOG="$WORK/pane-state-calls.log"
: > "$PANE_STATE_LOG"
cat > "$NEXUS_ROOT/monitor/pane-state.sh" <<'PSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PANE_STATE_LOG:-/dev/null}"
idx="${!#}"
var="MOCK_PANE_STATE_${idx}"
printf '%s\n' "${!var:-state=unknown active=0 window=$idx name=}"
PSTUB
chmod +x "$NEXUS_ROOT/monitor/pane-state.sh"

# ---- Test 1: emit handler writes per-decision JSON -----

echo '=== decision-emit: writes per-decision JSON event ==='
payload='{"hook_event_name":"Notification","notification":{"type":"permission_prompt","message":"Allow Bash to run git push --force?"},"session_id":"sess-abc"}'
printf '%s' "$payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
shopt -s nullglob
files=( "$DECISIONS_DIR/worker-A".*.json )
shopt -u nullglob
if (( ${#files[@]} == 1 )); then
    printf '  PASS: exactly one decision file written (%s)\n' "$(basename "${files[0]}")"; PASS=$(( PASS + 1 ))
    f="${files[0]}"
    body=$(<"$f")
    assert_contains "carries kind=permission_prompt"  "$body" '"kind":"permission_prompt"'
    assert_contains "carries window=worker-A"          "$body" '"window":"worker-A"'
    assert_contains "carries session_id=sess-abc"      "$body" '"session_id":"sess-abc"'
    assert_contains "carries prompt_excerpt"           "$body" 'Allow Bash to run git push --force'
    assert_contains "carries 12-hex fingerprint"       "$body" '"fingerprint":"'
    # Verify ts is ISO 8601 UTC (Z suffix).
    ts=$(jq -r '.ts' "$f")
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        && { printf '  PASS: ts is ISO 8601 UTC (got %s)\n' "$ts"; PASS=$(( PASS + 1 )); } \
        || { printf '  FAIL: ts not ISO 8601 UTC (got %s)\n' "$ts" >&2; FAIL=$(( FAIL + 1 )); }
    # Filename matches <window>.<12hex>.json convention.
    bn=$(basename "$f" .json)
    [[ "$bn" =~ ^worker-A\.[0-9a-f]{12}$ ]] \
        && { printf '  PASS: filename matches <window>.<12hex>.json (%s)\n' "$bn"; PASS=$(( PASS + 1 )); } \
        || { printf '  FAIL: filename malformed (%s)\n' "$bn" >&2; FAIL=$(( FAIL + 1 )); }
else
    printf '  FAIL: expected exactly one decision file, got %d\n' "${#files[@]}" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 1b: empirically-observed payload shape (top-level fields) ----

echo '=== decision-emit: top-level notification_type + message (PR #132 shape) ==='
# Real payload shape Claude Code emits (captured in PR #132):
#   {"hook_event_name":"Notification","notification_type":"idle_prompt",
#    "message":"Claude is waiting for your input","session_id":"..."}
# The handler MUST read kind from .notification_type (not .notification.type)
# and prompt_excerpt from .message (not .notification.message), or the
# decision file silently records kind:"Notification" / prompt_excerpt:""
# regardless of the actual notification type — the bug PR #132 surfaced.
export NEXUS_WORKER_WINDOW="worker-B"
payload_topfield='{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input","session_id":"sess-xyz"}'
printf '%s' "$payload_topfield" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
shopt -s nullglob
files_b=( "$DECISIONS_DIR/worker-B".*.json )
shopt -u nullglob
if (( ${#files_b[@]} == 1 )); then
    printf '  PASS: top-level shape — exactly one decision file written (%s)\n' "$(basename "${files_b[0]}")"; PASS=$(( PASS + 1 ))
    body_b=$(<"${files_b[0]}")
    assert_contains "top-level shape → kind=idle_prompt"        "$body_b" '"kind":"idle_prompt"'
    assert_contains "top-level shape → message in prompt_excerpt" "$body_b" 'Claude is waiting for your input'
    assert_contains "top-level shape → session_id=sess-xyz"      "$body_b" '"session_id":"sess-xyz"'
    assert_not_contains "kind is NOT raw hook_event_name"       "$body_b" '"kind":"Notification"'
else
    printf '  FAIL: top-level shape — expected exactly one decision file, got %d\n' "${#files_b[@]}" >&2
    FAIL=$(( FAIL + 1 ))
fi
export NEXUS_WORKER_WINDOW="worker-A"

# ---- Test 2: re-firing same prompt keeps the same file (fp stable) -----

echo '=== decision-emit: same payload → same fingerprint → file overwritten ==='
shopt -s nullglob
files_before=( "$DECISIONS_DIR/worker-A".*.json )
shopt -u nullglob
fp_before=$(basename "${files_before[0]}" .json | awk -F. '{print $NF}')
printf '%s' "$payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
shopt -s nullglob
files_after=( "$DECISIONS_DIR/worker-A".*.json )
shopt -u nullglob
assert_eq "still exactly one file after re-emit" "${#files_after[@]}" "1"
fp_after=$(basename "${files_after[0]}" .json | awk -F. '{print $NF}')
assert_eq "fingerprint stable across re-fires" "$fp_after" "$fp_before"

# ---- Test 3: different prompt → different fingerprint → second file ----

echo '=== decision-emit: different message → distinct fingerprint ==='
payload2='{"hook_event_name":"Notification","notification":{"type":"permission_prompt","message":"Allow Write to /etc/passwd?"},"session_id":"sess-abc"}'
printf '%s' "$payload2" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
shopt -s nullglob
files_two=( "$DECISIONS_DIR/worker-A".*.json )
shopt -u nullglob
assert_eq "two distinct decision files now present" "${#files_two[@]}" "2"

# ---- Test 4: tool_context embeds the pending-tool snapshot -------------

echo '=== decision-emit: embeds pending-tool snapshot into tool_context ==='
rm -f "$DECISIONS_DIR/"*.json
mkdir -p "$NEXUS_ROOT/monitor/.state/pending-tool"
printf '%s\n' '{"tool":"Bash","input_summary":"git push --force origin main","ts":1700000000}' \
    > "$NEXUS_ROOT/monitor/.state/pending-tool/$NEXUS_WORKER_WINDOW.json"
printf '%s' "$payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
shopt -s nullglob
files_tc=( "$DECISIONS_DIR/worker-A".*.json )
shopt -u nullglob
if (( ${#files_tc[@]} == 1 )); then
    body=$(<"${files_tc[0]}")
    assert_contains "tool_context carries tool name"          "$body" 'Bash'
    assert_contains "tool_context carries input summary"       "$body" 'git push --force'
else
    printf '  FAIL: tool_context test — expected 1 decision file, got %d\n' "${#files_tc[@]}" >&2
    FAIL=$(( FAIL + 1 ))
fi
rm -f "$NEXUS_ROOT/monitor/.state/pending-tool/$NEXUS_WORKER_WINDOW.json"

# ---- Test 5: the Stop hook rules BY KIND (your-org/nexus-code#824) ------
#
# `Stop` is not uniform evidence. A permission modal SUSPENDS the turn, so
# `Stop` cannot fire while it is on screen — its arrival proves the modal is
# GONE. This hook used to consume exactly that event to stamp
# `unresolved: true`, i.e. to declare the prompt unanswered using the one
# signal that proves it was answered.
#
# Measured on the production board (window `spawnpath`): emitted 11:50:39Z,
# stamped 11:54:56Z — the turn ran 4m17s PAST the prompt and then reached
# `Stop`. The row then re-fired every 300 s cooldown for ~5 h on
# byte-identical pane content.
#
# The old Test 5 asserted the defect (`files_tc[0]` is a permission_prompt),
# so it is rewritten rather than extended. Both directions are asserted:
# a fix that simply stopped stamping everything would pass the first
# assertion and fail the `idle_prompt` control.

echo '=== decision-mark-unresolved: permission_prompt → RESOLVED, not unresolved ==='
"$NEXUS_ROOT/monitor/hooks/decision-mark-unresolved.sh"
body=$(<"${files_tc[0]}")
assert_contains "permission_prompt marked resolved=true"       "$body" '"resolved":true'
assert_not_contains "permission_prompt NOT marked unresolved"  "$body" '"unresolved":true'
assert_contains "resolution records WHY, not just that"        "$body" 'suspends the turn'
# `assert_*` only — this suite defines no ok()/bad(), and a missing helper is
# rc 127 counted by nothing (the failure mode _test_helpers.sh exists to catch).
resolved_at=$(jq -r '.resolved_at // ""' "${files_tc[0]}")
resolved_at_shape=no
[[ "$resolved_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && resolved_at_shape=yes
assert_eq "resolved_at is an ISO-8601 UTC stamp (got '$resolved_at')" "$resolved_at_shape" "yes"

# THE CONTROL, and it is what stops "fix it by never stamping anything".
# `idle_prompt` genuinely lingers past turn-end — that is the kind the old
# inference was written for — so its behaviour must be unchanged.
echo '=== decision-mark-unresolved: idle_prompt still → unresolved=true ==='
idle_payload='{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input","session_id":"sess-abc"}'
printf '%s' "$idle_payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
shopt -s nullglob
idle_files=( $(grep -l '"kind":"idle_prompt"' "$DECISIONS_DIR/worker-A".*.json 2>/dev/null) )
shopt -u nullglob
if (( ${#idle_files[@]} == 1 )); then
    "$NEXUS_ROOT/monitor/hooks/decision-mark-unresolved.sh"
    ibody=$(<"${idle_files[0]}")
    assert_contains "idle_prompt marked unresolved=true"      "$ibody" '"unresolved":true'
    assert_not_contains "idle_prompt NOT marked resolved"     "$ibody" '"resolved":true'
else
    assert_eq "idle_prompt control: exactly one idle_prompt file" "${#idle_files[@]}" "1"
fi

# An UNRECOGNISED kind keeps the old, LOUD behaviour. This is an operator
# attention channel: the harm it must never do is go quiet, so a kind we
# cannot rule on is not silently treated as resolved.
echo '=== decision-mark-unresolved: unknown kind falls to the LOUD default ==='
unk="$DECISIONS_DIR/worker-A.abcdef123456.json"
printf '%s\n' '{"window":"worker-A","fingerprint":"abcdef123456","kind":"elicitation_request","prompt_excerpt":"?"}' > "$unk"
"$NEXUS_ROOT/monitor/hooks/decision-mark-unresolved.sh"
ubody=$(<"$unk")
assert_contains "unknown kind marked unresolved=true"        "$ubody" '"unresolved":true'
assert_not_contains "unknown kind NOT marked resolved"       "$ubody" '"resolved":true'
# …and a file with NO kind at all, which is the malformed-payload shape
# decision-emit.sh deliberately still writes.
nok="$DECISIONS_DIR/worker-A.fedcba654321.json"
printf '%s\n' '{"window":"worker-A","fingerprint":"fedcba654321"}' > "$nok"
"$NEXUS_ROOT/monitor/hooks/decision-mark-unresolved.sh"
assert_contains "kindless file marked unresolved=true"       "$(<"$nok")" '"unresolved":true'

# Idempotent in BOTH directions: re-running must not flip a ruling or
# double-stamp a key.
echo '=== decision-mark-unresolved: idempotent across turn-ends ==='
"$NEXUS_ROOT/monitor/hooks/decision-mark-unresolved.sh"
"$NEXUS_ROOT/monitor/hooks/decision-mark-unresolved.sh"
rbody=$(<"${files_tc[0]}")
assert_contains "permission_prompt still resolved after re-runs"    "$rbody" '"resolved":true'
assert_not_contains "…and never acquired unresolved"                "$rbody" '"unresolved":true'
res_count=$(jq -r 'paths | select(.[-1] == "resolved") | length' "${files_tc[0]}" | wc -l)
assert_eq "resolved key present exactly once after re-mark" "$res_count" "1"
unresolved_count=$(jq -r 'paths | select(.[-1] == "unresolved") | length' "$unk" | wc -l)
assert_eq "unresolved key present exactly once after re-mark" "$unresolved_count" "1"

# Tombstone sibling should NOT be touched, either way.
tombstone="$DECISIONS_DIR/worker-A.deadbeefcafe.handled.json"
printf '{"window":"worker-A","fingerprint":"deadbeefcafe","kind":"permission_prompt","handled":true}\n' > "$tombstone"
"$NEXUS_ROOT/monitor/hooks/decision-mark-unresolved.sh"
body3=$(<"$tombstone")
assert_not_contains "tombstone NOT marked unresolved" "$body3" '"unresolved":true'
assert_not_contains "tombstone NOT marked resolved"   "$body3" '"resolved":true'
rm -f "$unk" "$nok"
for _f in "${idle_files[@]:-}"; do [[ -n "$_f" ]] && rm -f "$_f"; done

# ---- Test 6: render_pending_decisions emits the operator line shape ----

echo '=== render_pending_decisions: emits operator-spec line shape ==='
rm -f "$DECISIONS_DIR/"*.json
# Seed two decisions: one with tool_context, one without.
cat > "$DECISIONS_DIR/worker-A.aaaa11112222.json" <<'EOF'
{
  "ts": "2026-05-18T20:55:00Z",
  "window": "worker-A",
  "session_id": "sess-1",
  "kind": "permission_prompt",
  "prompt_excerpt": "Allow Bash to run git push?",
  "tool_context": "{\"tool\":\"Bash\",\"input_summary\":\"git push origin main\"}",
  "fingerprint": "aaaa11112222"
}
EOF
cat > "$DECISIONS_DIR/worker-B.bbbb33334444.json" <<'EOF'
{
  "ts": "2026-05-18T20:56:00Z",
  "window": "worker-B",
  "session_id": "sess-2",
  "kind": "idle_prompt",
  "prompt_excerpt": "Awaiting your input",
  "tool_context": "",
  "fingerprint": "bbbb33334444"
}
EOF

# Source the renderer.
export STATE_DIR="$NEXUS_ROOT/monitor/.state"
# Reset cooldown state.
rm -f "$STATE_DIR/pending-decisions-emit-state.tsv"
# shellcheck disable=SC1091
. "$_test_dir/_idle_probe.sh" >/dev/null 2>&1
out=$(render_pending_decisions 2>/dev/null)
assert_contains "emits operator-spec line for worker-A"     "$out" 'window=worker-A fp=aaaa11112222 kind=permission_prompt'
assert_contains "cites file path for worker-A"               "$out" "file=$DECISIONS_DIR/worker-A.aaaa11112222.json"
assert_contains "emits operator-spec line for worker-B"     "$out" 'window=worker-B fp=bbbb33334444 kind=idle_prompt'
assert_contains "emits prompt-excerpt for worker-A"          "$out" 'prompt-excerpt=Allow Bash'
# unresolved=false by default (Stop hasn't fired).
assert_contains "unresolved=false on fresh decisions"        "$out" 'unresolved=false'

# ---- Test 7: cooldown — second cycle within cooldown emits nothing -----

echo '=== render_pending_decisions: cooldown dedupes within DECISION_REEMIT_COOLDOWN_SECONDS ==='
export DECISION_REEMIT_COOLDOWN_SECONDS=300
out2=$(render_pending_decisions 2>/dev/null)
assert_eq "second cycle within cooldown emits nothing" "$out2" ""

# ---- Test 8: cooldown — past cooldown, re-emits ------------------------

echo '=== render_pending_decisions: re-emits after cooldown elapses ==='
# Backdate the state file by 1000s so the cooldown is exceeded.
state_file="$STATE_DIR/pending-decisions-emit-state.tsv"
now=$(date +%s)
old=$(( now - 1000 ))
awk -F'\t' -v old="$old" 'BEGIN { OFS="\t" } { $3 = old; print }' "$state_file" > "$state_file.bak"
mv "$state_file.bak" "$state_file"
out3=$(render_pending_decisions 2>/dev/null)
assert_contains "re-emits worker-A after cooldown" "$out3" 'window=worker-A'
assert_contains "re-emits worker-B after cooldown" "$out3" 'window=worker-B'


# ---- Test 8b: a RESOLVED row does not re-fire on unchanged bytes -------
#
# your-org/nexus-code#824. THE DEFECT'S SIGNATURE IS REPETITION ON IDENTICAL
# CONTENT, so a first-fire assertion cannot detect it. On the production board
# the answered `permission_prompt` re-fired every 300 s cooldown for ~5 h — 13
# firings on one window — while the pane's `content_hash` was UNCHANGED across
# firings minutes apart. Nothing about the pane re-armed it; the cooldown
# expiring on a permanently-`unresolved` file did.
#
# So this drives the row across THREE cooldown boundaries and requires silence
# at each, with an unresolved control in the same output proving the renderer
# is still alive and the silence is about this row.

echo '=== #824: a resolved permission_prompt never re-fires, across repeated cooldowns ==='
# HERMETIC: snapshot the fixture and restore it at the end. This block needs an
# empty decisions dir, and the tests after it depend on the set Test 6 seeded —
# a first draft just deleted the files and reddened Test 9, which is the
# ordinary shape of a test that treats shared fixture state as its own.
_824_save=$(mktemp -d)
cp -a "$DECISIONS_DIR/." "$_824_save/" 2>/dev/null || true
[[ -f "$STATE_DIR/pending-decisions-emit-state.tsv" ]] \
    && cp "$STATE_DIR/pending-decisions-emit-state.tsv" "$_824_save/.emitstate" 2>/dev/null
rm -f "$DECISIONS_DIR/"*.json "$STATE_DIR/pending-decisions-emit-state.tsv"

# The shape the Stop hook produces for an ANSWERED permission prompt…
cat > "$DECISIONS_DIR/worker-A.5555aaaa6666.json" <<'EOF'
{
  "ts": "2026-08-08T11:50:39Z",
  "window": "worker-A",
  "session_id": "sess-824",
  "kind": "permission_prompt",
  "prompt_excerpt": "Claude needs your permission",
  "tool_context": "",
  "fingerprint": "5555aaaa6666",
  "resolved": true,
  "resolved_at": "2026-08-08T11:54:56Z",
  "resolved_by": "stop-hook: a permission modal suspends the turn, so Stop implies it is no longer displayed"
}
EOF
# …and a genuinely pending row beside it, so "no output" can never be mistaken
# for "the renderer stopped working".
cat > "$DECISIONS_DIR/worker-B.7777bbbb8888.json" <<'EOF'
{
  "ts": "2026-08-08T11:50:39Z",
  "window": "worker-B",
  "session_id": "sess-824",
  "kind": "permission_prompt",
  "prompt_excerpt": "Allow Bash to run rm -rf /?",
  "tool_context": "",
  "fingerprint": "7777bbbb8888"
}
EOF

export DECISION_REEMIT_COOLDOWN_SECONDS=300
state_file="$STATE_DIR/pending-decisions-emit-state.tsv"
r824_fired=0
for _cycle in 1 2 3; do
    out824=$(render_pending_decisions 2>/dev/null)
    grep -q 'fp=5555aaaa6666' <<<"$out824" && r824_fired=$(( r824_fired + 1 ))
    if (( _cycle == 1 )); then
        assert_contains "cycle 1: the UNRESOLVED row does fire (renderer is alive)" \
                        "$out824" 'fp=7777bbbb8888'
    fi
    # Age the cooldown state past the window, exactly as Test 8 does — this is
    # what "the cooldown expired again" looks like with nothing else changed.
    if [[ -f "$state_file" ]]; then
        now824=$(date +%s); old824=$(( now824 - 1000 ))
        awk -F'\t' -v old="$old824" 'BEGIN { OFS="\t" } { $3 = old; print }' \
            "$state_file" > "$state_file.bak" && mv "$state_file.bak" "$state_file"
    fi
done
assert_eq "resolved row fired ZERO times across 3 cooldown boundaries" "$r824_fired" "0"

# The control that keeps the above from being satisfied by a renderer that
# went silent: the unresolved sibling re-fires every time, same bytes, same
# cooldown ageing.
rm -f "$STATE_DIR/pending-decisions-emit-state.tsv"
b824_fired=0
for _cycle in 1 2 3; do
    outb=$(render_pending_decisions 2>/dev/null)
    grep -q 'fp=7777bbbb8888' <<<"$outb" && b824_fired=$(( b824_fired + 1 ))
    if [[ -f "$state_file" ]]; then
        now824=$(date +%s); old824=$(( now824 - 1000 ))
        awk -F'\t' -v old="$old824" 'BEGIN { OFS="\t" } { $3 = old; print }' \
            "$state_file" > "$state_file.bak" && mv "$state_file.bak" "$state_file"
    fi
done
assert_eq "unresolved row fired on ALL 3 cycles (silence is row-specific)" "$b824_fired" "3"

# RESOLUTION IS NOT PERMANENT SUPPRESSION. A genuine re-fire of the same
# fingerprint rewrites the file wholesale through decision-emit.sh, with no
# `resolved` key — and must surface again. Without this, "stop nagging" would
# be indistinguishable from "never report this prompt again", which is the
# failure mode a tombstone is for and this is not.
echo '=== #824: a genuine re-fire of a resolved fingerprint surfaces again ==='
cat > "$DECISIONS_DIR/worker-A.5555aaaa6666.json" <<'EOF'
{
  "ts": "2026-08-08T16:00:00Z",
  "window": "worker-A",
  "session_id": "sess-824",
  "kind": "permission_prompt",
  "prompt_excerpt": "Claude needs your permission",
  "tool_context": "",
  "fingerprint": "5555aaaa6666"
}
EOF
rm -f "$STATE_DIR/pending-decisions-emit-state.tsv"
out_refire=$(render_pending_decisions 2>/dev/null)
assert_contains "a re-fired (unresolved) fingerprint surfaces again" "$out_refire" 'fp=5555aaaa6666'
# Restore the fixture exactly as found, so the tests after this one see the set
# Test 6 seeded rather than whatever this block last wrote.
rm -f "$DECISIONS_DIR/"*.json "$STATE_DIR/pending-decisions-emit-state.tsv"
cp -a "$_824_save/." "$DECISIONS_DIR/" 2>/dev/null || true
rm -f "$DECISIONS_DIR/.emitstate"
[[ -f "$_824_save/.emitstate" ]] \
    && cp "$_824_save/.emitstate" "$STATE_DIR/pending-decisions-emit-state.tsv" 2>/dev/null
rm -rf "$_824_save"

# ---- Test 9: file removal (ack) → drops on next cycle -------------------

echo '=== render_pending_decisions: file removal acks the decision ==='
rm -f "$DECISIONS_DIR/worker-A.aaaa11112222.json"
# Reset cooldown so the worker-B reemit isn't gated.
awk -F'\t' -v old="$old" 'BEGIN { OFS="\t" } { $3 = old; print }' "$state_file" > "$state_file.bak"
mv "$state_file.bak" "$state_file"
out4=$(render_pending_decisions 2>/dev/null)
assert_not_contains "worker-A no longer surfaces" "$out4" 'worker-A'
assert_contains    "worker-B still surfaces"      "$out4" 'window=worker-B'

# ---- Test 10: handled.json tombstones are silently skipped --------------

echo '=== render_pending_decisions: *.handled.json tombstones are skipped ==='
rm -f "$DECISIONS_DIR/"*.json "$state_file"
printf '{"window":"worker-A","fingerprint":"cccccccc1234"}\n' > "$DECISIONS_DIR/worker-A.cccccccc1234.handled.json"
out5=$(render_pending_decisions 2>/dev/null)
assert_eq "tombstones produce no output" "$out5" ""

# ---- Test 11: empty decisions dir → empty output ------------------------

echo '=== render_pending_decisions: empty directory → no output ==='
rm -f "$DECISIONS_DIR/"*.json
out6=$(render_pending_decisions 2>/dev/null)
assert_eq "empty dir → empty stdout" "$out6" ""

# ---- Test 12: decision-emit honours tombstone on the write path ---------
#
# Regression for the operator's observation: a retained-idle worker
# repeatedly fires `idle_prompt`, the orchestrator tombstones the
# decision file, and the next hook fire re-writes `<fp>.json` over
# the tombstone — the watcher then re-emits. The tombstone is
# documented as ack-and-suppress; the hook must silently no-op when
# a sibling `<fp>.handled.json` exists.

echo '=== decision-emit: tombstone suppresses same-fingerprint re-fires ==='
rm -f "$DECISIONS_DIR/"*.json "$DECISIONS_DIR/"*.handled.json
export NEXUS_WORKER_WINDOW="worker-A"
emit_payload='{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input","session_id":"sess-tomb"}'

# First fire writes the .json.
printf '%s' "$emit_payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
shopt -s nullglob
seed_files=( "$DECISIONS_DIR/worker-A".*.json )
shopt -u nullglob
assert_eq "seed fire wrote exactly one .json" "${#seed_files[@]}" "1"
seed_fp=$(basename "${seed_files[0]}" .json | awk -F. '{print $NF}')

# Tombstone it (orchestrator's ack-and-suppress move).
mv "${seed_files[0]}" "$DECISIONS_DIR/worker-A.$seed_fp.handled.json"

# Re-fire the SAME payload. Capture stderr to assert no noise.
stderr_capture=$(mktemp)
trap 'rm -f "$stderr_capture"; rm -rf "$WORK"' EXIT
printf '%s' "$emit_payload" \
    | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh" 2>"$stderr_capture"
rc=$?
assert_eq "re-fire over tombstone exits 0" "$rc" "0"

stderr_body=$(<"$stderr_capture")
assert_eq "re-fire over tombstone writes no stderr" "$stderr_body" ""

assert_no_file "no <fp>.json resurrected over tombstone" \
    "$DECISIONS_DIR/worker-A.$seed_fp.json"
assert_file_exists "tombstone still present" \
    "$DECISIONS_DIR/worker-A.$seed_fp.handled.json"

# Different payload (different fp) writes a fresh .json; the tombstone
# is unaffected.
echo '=== decision-emit: tombstone only gates the matching fingerprint ==='
other_payload='{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow Bash to run git push?","session_id":"sess-tomb"}'
printf '%s' "$other_payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
# Glob for ACTIVE .json files only (exclude *.handled.json siblings).
new_files=()
shopt -s nullglob
for f in "$DECISIONS_DIR/worker-A".*.json; do
    [[ "$f" == *.handled.json ]] && continue
    new_files+=( "$f" )
done
shopt -u nullglob
assert_eq "different fp wrote a fresh .json (active count)" "${#new_files[@]}" "1"
new_fp=$(basename "${new_files[0]}" .json | awk -F. '{print $NF}')
[[ "$new_fp" != "$seed_fp" ]] \
    && { printf '  PASS: distinct fingerprint (%s != %s)\n' "$new_fp" "$seed_fp"; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: expected distinct fingerprints, both %s\n' "$new_fp" >&2; FAIL=$(( FAIL + 1 )); }
assert_file_exists "prior tombstone still present" \
    "$DECISIONS_DIR/worker-A.$seed_fp.handled.json"

# ---- Test 12: operator-engaged suppresses idle_prompt (#196, #201) ------
#
# The turn-end `idle_prompt` pings of a window the operator drives
# are not decisions to ack. While the window carries a VALID
# operator-engaged mark, the renderer withholds idle_prompt rows
# (file kept on disk, no cooldown state) and other kinds still
# surface. Since issue #201 the suppression spans the away phase too
# (a mark aged past the grace still withholds); only invalidation —
# a newer `engaged-done` finished-signal or spawn (the #205
# state-machine follow-up moved invalidation off the wrap-up event:
# interactive sessions stay engaged across their own hand-off) —
# lets the lingering file surface as brand-new. Nothing is
# permanently muted: invalidation or window close always reopens
# the path.

echo '=== render_pending_decisions: operator-engaged suppresses idle_prompt (issues #196/#201) ==='
rm -f "$DECISIONS_DIR/"*.json "$STATE_DIR/pending-decisions-emit-state.tsv"
_oe_now=$(date +%s)
printf 'worker-E\t%s\t%s\t0\tsubmit\t0\n' "$(( _oe_now - 60 ))" "$(( _oe_now - 5 ))" \
    > "$STATE_DIR/operator-engaged.tsv"
# Mark validity now requires a recent pane-content change (the
# your-org/your-nexus#205 follow-up self-expiry); stamp one so
# `_openg_marked` accepts the mark as VALID.
mkdir -p "$STATE_DIR/pane-change"
printf 'h\t%s\n' "$_oe_now" > "$STATE_DIR/pane-change/worker-E"
cat > "$DECISIONS_DIR/worker-E.eeee55556666.json" <<'EOF'
{"ts":"2026-06-10T22:00:00Z","window":"worker-E","session_id":"sess-e","kind":"idle_prompt","prompt_excerpt":"Awaiting your input","tool_context":"","fingerprint":"eeee55556666"}
EOF
cat > "$DECISIONS_DIR/worker-E.ffff77778888.json" <<'EOF'
{"ts":"2026-06-10T22:00:01Z","window":"worker-E","session_id":"sess-e","kind":"permission_prompt","prompt_excerpt":"Allow Bash to run rm?","tool_context":"","fingerprint":"ffff77778888"}
EOF
out=$(render_pending_decisions 2>/dev/null)
assert_not_contains "engaged window: idle_prompt withheld"      "$out" 'kind=idle_prompt'
assert_contains     "engaged window: permission_prompt surfaces" "$out" 'kind=permission_prompt'
assert_file_exists  "withheld decision file kept on disk" \
    "$DECISIONS_DIR/worker-E.eeee55556666.json"

# Walk-away (issue #201): the operator hasn't SUBMITTED for hours
# (`last` 2 h old) but the pane is STILL changing (the agent is
# working on the operator's behalf), so the mark stays valid and the
# idle_prompt remains withheld — the away phase's surface is the
# engaged-close-reminder, not a decision row. (Once the pane goes
# static past the change TTL the mark self-expires and the path
# reopens — exercised in test-idle-probe's part-A block.)
printf 'worker-E\t%s\t%s\t0\tsubmit\t0\n' "$(( _oe_now - 7200 ))" "$(( _oe_now - 7000 ))" \
    > "$STATE_DIR/operator-engaged.tsv"
printf 'h\t%s\n' "$_oe_now" > "$STATE_DIR/pane-change/worker-E"   # still changing → valid
out=$(render_pending_decisions 2>/dev/null)
assert_not_contains "away phase (still changing): idle_prompt withheld" "$out" 'kind=idle_prompt'

# A wrap-up NEWER than the mark's `since` does NOT invalidate (the
# #205 state-machine follow-up): the interactive session stays
# engaged across its own hand-off, so the idle_prompt stays withheld.
WRAP_TS=$(date -Is -d "@$(( _oe_now - 3600 ))")
printf '{"ts":"%s","agent":"monitor","event":"wrap-up","window":"worker-E","report":"worker-E_2026-06-11_000000_done.md"}\n' \
    "$WRAP_TS" >> "$STATE_DIR/action-log.jsonl"
out=$(render_pending_decisions 2>/dev/null)
assert_not_contains "newer wrap-up does NOT invalidate: idle_prompt stays withheld" "$out" 'kind=idle_prompt'

# Invalidation: an `engaged-done` finished-signal (ng engaged-done)
# NEWER than the mark's `since` kills it; the lingering idle_prompt
# surfaces as a brand-new row.
DONE_TS=$(date -Is -d "@$(( _oe_now - 1800 ))")
printf '{"ts":"%s","agent":"monitor","event":"engaged-done","window":"worker-E"}\n' \
    "$DONE_TS" >> "$STATE_DIR/action-log.jsonl"
out=$(render_pending_decisions 2>/dev/null)
assert_contains "after engaged-done invalidation: idle_prompt resurfaces" "$out" 'kind=idle_prompt'
rm -f "$STATE_DIR/operator-engaged.tsv"

# ---- Test 13: dead-window skip (watcher-emit-noise, Class 3) ------------
#
# A decision file whose window is no longer live in tmux is unactionable
# (the operator answers the prompt IN the window) — it must NOT re-nag the
# orchestrator. Reproduces the 2026-07-21 00:33/00:34 pubfork-skills
# re-nags: a skeptic-parked worker + its skeptic were kill-window'd, their
# decision files lingered, and the (now-lapsed) skeptic-park suppression no
# longer withheld them. The live-window re-stat drops the dead row while a
# still-live window's decision continues to surface.
echo '=== render_pending_decisions: dead-window decision is skipped (Class 3) ==='
rm -f "$DECISIONS_DIR/"*.json "$DECISIONS_DIR/"*.handled.json "$STATE_DIR/pending-decisions-emit-state.tsv"
cat > "$DECISIONS_DIR/worker-A.aaaa11112222.json" <<'EOF'
{"ts":"2026-07-21T07:34:00Z","window":"worker-A","session_id":"s-a","kind":"idle_prompt","prompt_excerpt":"Claude is waiting for your input","tool_context":"","fingerprint":"aaaa11112222"}
EOF
cat > "$DECISIONS_DIR/worker-DEAD.dddd99990000.json" <<'EOF'
{"ts":"2026-07-21T07:33:00Z","window":"worker-DEAD","session_id":"s-d","kind":"idle_prompt","prompt_excerpt":"Claude is waiting for your input","tool_context":"","fingerprint":"dddd99990000"}
EOF
# tmux reports worker-A live but NOT worker-DEAD.
MOCK_TMUX_WINDOWS="worker-A worker-B worker-E"
out=$(render_pending_decisions 2>/dev/null)
assert_contains     "live window worker-A still surfaces"        "$out" 'window=worker-A'
assert_not_contains "dead window worker-DEAD is skipped"         "$out" 'worker-DEAD'
# The skip drops the dead row from the cooldown state too (no accumulation).
state_row_dead=$(grep -c 'worker-DEAD' "$STATE_DIR/pending-decisions-emit-state.tsv" 2>/dev/null)
[[ "$state_row_dead" =~ ^[0-9]+$ ]] || state_row_dead=0
assert_eq "dead window absent from cooldown state" "$state_row_dead" 0

# Pass-through guard: an EMPTY live set (tmux transient/unavailable) must
# NOT nuke a real decision — better to surface than to silently swallow.
echo '=== render_pending_decisions: empty live set → pass-through (Class 3 guard) ==='
rm -f "$STATE_DIR/pending-decisions-emit-state.tsv"
MOCK_TMUX_WINDOWS=""
out=$(render_pending_decisions 2>/dev/null)
assert_contains "empty live set: worker-A still surfaces (pass-through)"    "$out" 'window=worker-A'
assert_contains "empty live set: worker-DEAD also surfaces (pass-through)"  "$out" 'window=worker-DEAD'
MOCK_TMUX_WINDOWS="worker-A worker-B worker-E"

# Knob off restores pre-fix behaviour (dead window surfaces).
echo '=== render_pending_decisions: skip_dead_windows=false disables the drop ==='
rm -f "$STATE_DIR/pending-decisions-emit-state.tsv"
export MONITOR_PENDING_SKIP_DEAD_WINDOWS=false
out=$(render_pending_decisions 2>/dev/null)
unset MONITOR_PENDING_SKIP_DEAD_WINDOWS
assert_contains "knob off: dead window worker-DEAD surfaces" "$out" 'worker-DEAD'

# ---- Test 14: the caller's ambient shell state must not decide the scan --
#
# Issue #721. `render_pending_decisions` sets `nullglob` for its `*.json`
# scan. A library must not depend on its caller's shell options for a
# correctness property, and it must not hand its caller back a different
# option set than it was given. NEITHER half was checked before this:
# deleting the library's `shopt -s nullglob` left all 53 prior assertions
# green (measured on dev@fc74b2d, rc=0, ALL TESTS PASSED).
#
# The reason it survived is worth stating, because it is NOT the reason the
# issue assumed. The suite is not blind to a wrong pending-decision set —
# there isn't one. With `nullglob` off and an empty dir the loop takes the
# unexpanded literal as `$f`, but `[[ -n "$win" ]]` below rejects the
# phantom row, so stdout, rc and the cooldown state are byte-identical
# either way (measured). The correctness was EMERGENT — a property nothing
# declared, resting on a fallback written for a different purpose.
#
# So the assertion has to measure the thing that DOES differ: the work the
# loop does on the phantom path. A logging `jq` shim sees it (two forks
# against a filename containing `*`); every answer-level assertion in this
# file is blind to it by construction. Same counting-shim idiom as #718's
# B6d, for the same reason — the observable the answer cannot carry.
echo '=== render_pending_decisions: independent of the caller ambient nullglob (issue #721) ==='

NG_SHIM="$WORK/ngshim"; NG_JQLOG="$WORK/ng-jq.log"; NG_OUT="$WORK/ng-out.txt"
mkdir -p "$NG_SHIM"
_ng_real_jq=$(command -v jq)
cat > "$NG_SHIM/jq" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NG_JQLOG"
exec $_ng_real_jq "\$@"
SHIM
chmod +x "$NG_SHIM/jq"

# DECLARE the fixture per case; never mutate it incrementally. #718's B6c
# lost an assertion to exactly that — a stub leaked from the previous case
# and the third assertion answered through a guard it was never written to
# reach. Rebuilding the decisions dir and the shim log from scratch makes
# the leak unrepresentable rather than merely undone.
_ng_case() {            # _ng_case <ambient:on|off> <fixture:empty|seeded>
    local ambient="$1" fixture="$2"
    rm -rf "$DECISIONS_DIR"; mkdir -p "$DECISIONS_DIR"
    rm -f "$STATE_DIR/pending-decisions-emit-state.tsv"
    : > "$NG_JQLOG"; : > "$NG_OUT"
    if [[ "$fixture" == seeded ]]; then
        cat > "$DECISIONS_DIR/worker-A.aaaa11112222.json" <<'EOF'
{"ts":"2026-08-06T05:00:00Z","window":"worker-A","session_id":"s-a","kind":"permission_prompt","prompt_excerpt":"Allow Bash to run git push?","tool_context":"","fingerprint":"aaaa11112222"}
EOF
    fi
    # Observations are computed inside the subshell and PRINTED; the
    # `assert_*` calls run in the parent. An assert inside `( )` bumps a
    # counter the summary never sees, so it can never fail this suite.
    (
        PATH="$NG_SHIM:$PATH"
        MOCK_TMUX_WINDOWS="worker-A"
        local before after
        if [[ "$ambient" == on ]]; then shopt -s nullglob; else shopt -u nullglob; fi
        before=$(shopt -p nullglob)
        # Direct call with a REDIRECT, not `$( … )`. A command substitution
        # forks, and an option change inside the fork is not observable in
        # `after` — which is also precisely why the old unconditional
        # `shopt -u` tail was inert at both watcher call sites.
        render_pending_decisions > "$NG_OUT" 2>/dev/null
        after=$(shopt -p nullglob)
        printf 'preserved=%s\n' "$([[ "$before" == "$after" ]] && echo yes || echo no)"
        # `grep -c` already prints 0 and exits 1 on no match. NO `|| echo 0`
        # here: that appends a SECOND 0 and the value becomes "0\n0" — the
        # defect this branch also fixes at test-realmodel-idle-busy.sh:50
        # (issue #725). The files are created above, so there is nothing to
        # be defensive about.
        printf 'phantom=%s\n' "$(grep -c '[*]' "$NG_JQLOG")"
        printf 'emitted=%s\n'  "$(grep -c 'window=worker-A' "$NG_OUT")"
    )
}
_ng_field() { grep -m1 "^$2=" <<<"$1" | cut -d= -f2; }

# (1) Ambient OFF — the caller the library actually has. The watcher sources
# this file; nothing in that path turns nullglob on.
ng_off_empty=$(_ng_case off empty)
assert_eq "ambient OFF + empty dir: scan never enters the body for the literal" \
    "$(_ng_field "$ng_off_empty" phantom)" "0"
assert_eq "ambient OFF + empty dir: emits nothing" \
    "$(_ng_field "$ng_off_empty" emitted)" "0"
assert_eq "ambient OFF + empty dir: caller nullglob unchanged" \
    "$(_ng_field "$ng_off_empty" preserved)" "yes"

# (2) Ambient ON — the caller that HAS the option. Pins the restore half:
# under the old unconditional `shopt -u` tail, `preserved` here is `no`.
ng_on_empty=$(_ng_case on empty)
assert_eq "ambient ON + empty dir: scan never enters the body for the literal" \
    "$(_ng_field "$ng_on_empty" phantom)" "0"
assert_eq "ambient ON + empty dir: caller nullglob RESTORED, not forced off" \
    "$(_ng_field "$ng_on_empty" preserved)" "yes"

# (3) The happy path must survive both ambient states, or the guards above
# would be muting the renderer rather than hardening it.
ng_off_seed=$(_ng_case off seeded)
assert_eq "ambient OFF + seeded dir: real decision still emits" \
    "$(_ng_field "$ng_off_seed" emitted)" "1"
assert_eq "ambient OFF + seeded dir: caller nullglob unchanged" \
    "$(_ng_field "$ng_off_seed" preserved)" "yes"
ng_on_seed=$(_ng_case on seeded)
assert_eq "ambient ON + seeded dir: real decision still emits" \
    "$(_ng_field "$ng_on_seed" emitted)" "1"
assert_eq "ambient ON + seeded dir: caller nullglob RESTORED, not forced off" \
    "$(_ng_field "$ng_on_seed" preserved)" "yes"

# ========================================================================
# your-org/nexus-code#790 — the channel must be about NOW, its ack must
# stick, and dead windows must not accumulate.
# ========================================================================

# Reset the world: the #721 block above leaves a shimmed PATH-in-subshell
# and a rebuilt decisions dir. Declare the fixture fresh rather than
# inheriting it (the #718 B6c lesson this file already carries).
_pd790_reset() {                # _pd790_reset <live-windows>
    rm -rf "$DECISIONS_DIR"; mkdir -p "$DECISIONS_DIR"
    rm -f "$STATE_DIR/pending-decisions-emit-state.tsv"
    rm -f "$STATE_DIR/operator-engaged.tsv"
    : > "$PANE_STATE_LOG"
    export MOCK_TMUX_WINDOWS="$1"
    unset MONITOR_PENDING_PANE_GATE MONITOR_PENDING_REAP_DEAD_WINDOWS
    unset MONITOR_PENDING_REAP_MIN_AGE_SECONDS
    unset "${!MOCK_PANE_STATE_@}"
}
_pd790_seed() {                 # _pd790_seed <window> <fp> [kind]
    printf '{"ts":"2026-08-07T23:00:00Z","window":"%s","session_id":"s","kind":"%s","prompt_excerpt":"Claude is waiting for your input","tool_context":"","fingerprint":"%s"}\n' \
        "$1" "${3:-idle_prompt}" "$2" > "$DECISIONS_DIR/$1.$2.json"
}

# The renderer only consults the gate when `bk_decision_row_actionable`
# is defined. This suite sources `_idle_probe.sh` directly, so load the
# predicate the same way main.sh does.
# shellcheck disable=SC1091
. "$_monitor_dir/_bookkeeping.sh"

# ---- Test 15: the pane gate — moot rows withheld, `blocked` survives ----
#
# The measured incident: ten consecutive `idle_prompt` rows whose panes
# were NOT waiting for input. Four panes here, one decision each,
# identical in every respect except what the pane is doing. Three assert
# they are being driven forward already; the fourth is stuck on a
# permission modal and is the NEGATIVE CONTROL — a fix that silences it
# has not improved the channel, it has broken it.
echo '=== render_pending_decisions: pane gate withholds moot rows, `blocked` still emits (#790) ==='
_pd790_reset "w-busy w-bg w-queued w-blocked"
export MOCK_PANE_STATE_1="state=busy active=1 window=1 name=w-busy input=ghost"
export MOCK_PANE_STATE_2="state=working-background active=1 window=2 name=w-bg input=ghost bg_shells=3 bg_cpu=60"
export MOCK_PANE_STATE_3="state=busy active=1 window=3 name=w-queued input=ghost queued=1"
export MOCK_PANE_STATE_4="state=blocked active=1 window=4 name=w-blocked overlay=permission input=blank"
_pd790_seed w-busy    aaaa00000001
_pd790_seed w-bg      aaaa00000002
_pd790_seed w-queued  aaaa00000003
_pd790_seed w-blocked aaaa00000004
out=$(render_pending_decisions 2>/dev/null)
assert_not_contains "busy pane: row withheld"                "$out" 'window=w-busy'
assert_not_contains "working-background pane: row withheld"  "$out" 'window=w-bg'
assert_not_contains "queued=1 pane: row withheld (#607)"     "$out" 'window=w-queued'
assert_contains     "NEGATIVE CONTROL: blocked pane STILL emits" "$out" 'window=w-blocked'
# The gate must have actually run. Without this the three "withheld"
# assertions above would also pass if the rows vanished for an unrelated
# reason — the assertion that the suppression came from the right place.
gate_calls=$(grep -c . "$PANE_STATE_LOG")
[[ "$gate_calls" -ge 4 ]] \
    && { printf '  PASS: gate consulted pane-state for every candidate row (%d calls)\n' "$gate_calls"; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: gate made %d pane-state calls, expected >= 4 — it did not run\n' "$gate_calls" >&2; FAIL=$(( FAIL + 1 )); }
# The FILES stay. Withholding is "not right now", never an ack.
assert_file_exists "withheld row's decision file kept on disk" \
    "$DECISIONS_DIR/w-busy.aaaa00000001.json"

# ---- Test 16: a withheld row that never emitted fires the moment the
#               pane frees, with no cooldown penalty --------------------
echo '=== render_pending_decisions: withheld-before-first-emit fires immediately once the pane frees (#790) ==='
_pd790_reset "w-turn"
export MOCK_PANE_STATE_1="state=busy active=1 window=1 name=w-turn"
_pd790_seed w-turn bbbb00000001
out=$(render_pending_decisions 2>/dev/null)
assert_eq "busy: nothing emitted" "$out" ""
state_rows=$(grep -c 'w-turn' "$STATE_DIR/pending-decisions-emit-state.tsv" 2>/dev/null || true)
assert_eq "withheld-and-never-emitted row is NOT stamped into the cooldown state" "$state_rows" "0"
# Pane frees on the very next cycle — no cooldown wait.
export MOCK_PANE_STATE_1="state=idle active=0 window=1 name=w-turn"
out=$(render_pending_decisions 2>/dev/null)
assert_contains "pane now idle: row emits on the NEXT cycle" "$out" 'window=w-turn'

# ---- Test 17: a withheld row that HAS emitted keeps its cooldown clock --
#
# Otherwise a pane flipping busy/idle re-emits on every flip and the
# guard becomes its own noise source — the failure mode being fixed,
# reintroduced by the fix.
echo '=== render_pending_decisions: withholding preserves, but does not RESTART, the cooldown clock (#790) ==='
# The gate is only consulted for a row that has ALREADY passed the
# cooldown check. So the interesting path — "cooldown elapsed, and the
# gate withholds anyway" — is only reachable with the stamp backdated.
# Testing it without that is testing the cooldown branch and calling it
# the gate: measured, two mutants of the stamp-preservation line
# (`continue`, and `last_emit_ts="$now"`) both survived that version.
#
# (continues from Test 16: w-turn emitted, so it carries a stamp.)
pd_state="$STATE_DIR/pending-decisions-emit-state.tsv"
pd_old=$(( $(date +%s) - 1000 ))          # cooldown (300s) comfortably elapsed
awk -F'\t' -v o="$pd_old" 'BEGIN { OFS="\t" } { $3 = o; print }' "$pd_state" > "$pd_state.bak"
mv "$pd_state.bak" "$pd_state"
export MOCK_PANE_STATE_1="state=busy active=1 window=1 name=w-turn"
out=$(render_pending_decisions 2>/dev/null)
assert_eq "cooldown elapsed but pane busy: withheld by the GATE" "$out" ""
pd_stamp=$(awk -F'\t' '$1 == "w-turn" { print $3; exit }' "$pd_state" 2>/dev/null)
assert_eq "row still present in the cooldown state (not dropped)" "${pd_stamp:-MISSING}" "$pd_old"
# …and because the stamp was preserved rather than refreshed, the row
# fires the moment the pane frees — a withhold must not buy the pane
# another full cooldown of silence.
export MOCK_PANE_STATE_1="state=idle active=0 window=1 name=w-turn"
out=$(render_pending_decisions 2>/dev/null)
assert_contains "pane frees: emits immediately, no fresh cooldown served" "$out" 'window=w-turn'
# The complement: a withhold INSIDE the cooldown leaves the clock alone
# too (this is the cooldown branch, asserted so a change there is caught).
export MOCK_PANE_STATE_1="state=busy active=1 window=1 name=w-turn"
out=$(render_pending_decisions 2>/dev/null)
assert_eq "flip to busy inside the fresh cooldown: still nothing" "$out" ""

# ---- Test 18: fail-open at every seam ----------------------------------
#
# The declared direction of error. Each of these is a way the gate can
# fail to reach a verdict; every one must EMIT.
echo '=== render_pending_decisions: pane gate fails OPEN on every could-not-tell path (#790) ==='
_pd790_reset "w-open"
export MOCK_PANE_STATE_1="state=unknown active=0 window=1 name=w-open"
_pd790_seed w-open cccc00000001
out=$(render_pending_decisions 2>/dev/null)
assert_contains "state=unknown → emits" "$out" 'window=w-open'

_pd790_reset "w-open"
export MOCK_PANE_STATE_1="state=empty active=0 window=1 name=w-open"
_pd790_seed w-open cccc00000001
out=$(render_pending_decisions 2>/dev/null)
assert_contains "state=empty (\"don't know yet\", #603) → emits" "$out" 'window=w-open'

_pd790_reset "w-open"
export MOCK_PANE_STATE_1=""      # probe returns an empty line
_pd790_seed w-open cccc00000001
out=$(render_pending_decisions 2>/dev/null)
assert_contains "empty pane-state line → emits" "$out" 'window=w-open'

# Predicate undefined (a build where _bookkeeping.sh never loaded): the
# gate must be inert, not silently suppressive. Run in a subshell so the
# unset does not leak into later cases.
_pd790_reset "w-open"
export MOCK_PANE_STATE_1="state=busy active=1 window=1 name=w-open"
_pd790_seed w-open cccc00000001
out=$( unset -f bk_decision_row_actionable; render_pending_decisions 2>/dev/null )
assert_contains "predicate undefined → gate inert, row emits (busy notwithstanding)" \
    "$out" 'window=w-open'

# Knob off restores pre-fix behaviour exactly.
_pd790_reset "w-open"
export MOCK_PANE_STATE_1="state=busy active=1 window=1 name=w-open"
_pd790_seed w-open cccc00000001
MONITOR_PENDING_PANE_GATE=false out=$(MONITOR_PENDING_PANE_GATE=false render_pending_decisions 2>/dev/null)
assert_contains "MONITOR_PENDING_PANE_GATE=false → busy row surfaces (pre-fix behaviour)" \
    "$out" 'window=w-open'

# ---- Test 19: the emit row names the DURABLE ack -----------------------
echo '=== render_pending_decisions: the row cites `ng decision-ack`, not `rm` (#790) ==='
_pd790_reset "w-ack"
export MOCK_PANE_STATE_1="state=idle active=0 window=1 name=w-ack"
_pd790_seed w-ack dddd00000001
out=$(render_pending_decisions 2>/dev/null)
assert_contains "row carries the ack verb"        "$out" 'ack=ng decision-ack w-ack dddd00000001'
assert_contains "row still cites the file path"   "$out" "file=$DECISIONS_DIR/w-ack.dddd00000001.json"

# ---- Test 20: the durable ack actually sticks, end to end --------------
#
# The defect: `rm` is the documented ack and it is a no-op, because
# `idle_prompt`'s fingerprint is sha1(window|kind|constant-message) — a
# pure function of the window. Both halves are asserted: `rm` does NOT
# stick, and `ng decision-ack` DOES.
echo '=== decision ack: `rm` does not stick, `ng decision-ack` does (#790) ==='
_pd790_reset "w-dur"
export NEXUS_WORKER_WINDOW="w-dur"
dur_payload='{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input","session_id":"s-dur"}'
printf '%s' "$dur_payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
shopt -s nullglob; dur_files=( "$DECISIONS_DIR/w-dur".*.json ); shopt -u nullglob
assert_eq "hook wrote one decision" "${#dur_files[@]}" "1"
dur_first="${dur_files[0]}"
dur_fp=$(basename "$dur_first" .json | awk -F. '{print $NF}')

# (a) the DOCUMENTED ack.
rm -f "$dur_first"
printf '%s' "$dur_payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
assert_file_exists "REGRESSION WITNESS: \`rm\` ack is undone by the next re-fire" "$dur_first"

# (b) the durable ack, through the real verb.
( set +u; . "$_monitor_dir/ng" ) >/dev/null 2>&1 || true
ack_out=$( STATE_DIR="$STATE_DIR" bash -c '
    set +u
    . "$1/ng" >/dev/null 2>&1
    STATE_DIR="$2"
    cmd_decision_ack "$3" "$4"
' _ "$_monitor_dir" "$STATE_DIR" w-dur "$dur_fp" 2>&1 )
ack_rc=$?
assert_eq "ng decision-ack exits 0" "$ack_rc" "0"
assert_no_file    "live decision file is gone after the ack"  "$dur_first"
assert_file_exists "tombstone written" "$DECISIONS_DIR/w-dur.$dur_fp.handled.json"

# The re-fire the `rm` ack could not survive.
printf '%s' "$dur_payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
assert_no_file "re-fire after a durable ack does NOT resurrect the decision" "$dur_first"
export MOCK_PANE_STATE_1="state=idle active=0 window=1 name=w-dur"
out=$(render_pending_decisions 2>/dev/null)
assert_not_contains "acked decision no longer surfaces in the emit" "$out" 'window=w-dur'
unset NEXUS_WORKER_WINDOW

# ---- Test 20b: a tombstone SIBLING suppresses the live .json -----------
#
# Found while fixing #790, and present on dev@16728e7 too — this is not a
# regression of that work, it is a fourth defect in the same channel.
#
# `decision-emit.sh` has treated `<w>.<fp>.handled.json` as terminal on
# the WRITE path since #129. This reader only ever skipped the tombstone
# FILE, never a live `<fp>.json` sitting next to one. The two halves of
# the same contract disagreed — and the disagreement lands exactly on the
# documented remedy: the "Tombstone recipe" in skills/nexus.window-cleanup
# writes the `.handled.json` with `jq -n … > …` and leaves the original
# `.json` in place. An orchestrator following that recipe verbatim got NO
# suppression: the row kept re-emitting every cooldown, and the tombstone
# only ever stopped future hook writes.
#
# So the shape under test is the recipe's shape — tombstone CREATED
# alongside, not renamed — not `ng decision-ack`'s (which renames and
# was never exposed to this).
echo '=== render_pending_decisions: a tombstone SIBLING suppresses the live decision (#790, 4th defect) ==='
_pd790_reset "w-sib"
export MOCK_PANE_STATE_1="state=idle active=0 window=1 name=w-sib"
_pd790_seed w-sib 1111aaaabbbb
out=$(render_pending_decisions 2>/dev/null)
assert_contains "control: un-tombstoned decision emits" "$out" 'window=w-sib'
# Now the hand-written tombstone, exactly as the skill's recipe produces
# it: a NEW file, original left in place.
printf '{"window":"w-sib","fp":"1111aaaabbbb","reason":"user-owned-idle"}\n' \
    > "$DECISIONS_DIR/w-sib.1111aaaabbbb.handled.json"
rm -f "$STATE_DIR/pending-decisions-emit-state.tsv"
out=$(render_pending_decisions 2>/dev/null)
assert_not_contains "tombstone sibling → row suppressed even with the .json present" \
    "$out" 'window=w-sib'
assert_file_exists "the live .json is NOT deleted by the reader (ack ≠ reap)" \
    "$DECISIONS_DIR/w-sib.1111aaaabbbb.json"
# And the write path agrees, as it always did — asserted here so the two
# halves of the contract are pinned together rather than separately.
export NEXUS_WORKER_WINDOW="w-sib"
sib_payload='{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input","session_id":"s-sib"}'
sib_before=$(cat "$DECISIONS_DIR/w-sib.1111aaaabbbb.json")
printf '%s' "$sib_payload" | "$NEXUS_ROOT/monitor/hooks/decision-emit.sh"
# (the hook's own fingerprint differs from our synthetic one; what
# matters is that the reader and writer now agree on what terminal means)
unset NEXUS_WORKER_WINDOW
assert_eq "reader did not rewrite the tombstoned decision" \
    "$(cat "$DECISIONS_DIR/w-sib.1111aaaabbbb.json")" "$sib_before"

# ---- Test 21: dead-window decisions are reaped -------------------------
echo '=== render_pending_decisions: dead-window decisions are reaped, not merely skipped (#790) ==='
_pd790_reset "w-live"
export MOCK_PANE_STATE_1="state=idle active=0 window=1 name=w-live"
_pd790_seed w-live  eeee00000001
_pd790_seed w-dead1 eeee00000002
_pd790_seed w-dead2 eeee00000003
printf '{"window":"w-dead2","fingerprint":"eeee00000004"}\n' \
    > "$DECISIONS_DIR/w-dead2.eeee00000004.handled.json"
# Fresh files must NOT be reaped — a window tmux failed to list for one
# cycle keeps its state.
render_pending_decisions >/dev/null 2>&1
assert_file_exists "fresh dead-window decision survives (min-age guard)" \
    "$DECISIONS_DIR/w-dead1.eeee00000002.json"
# Age them past the floor.
for f in w-dead1.eeee00000002.json w-dead2.eeee00000003.json w-dead2.eeee00000004.handled.json; do
    touch -d '2 hours ago' "$DECISIONS_DIR/$f"
done
render_pending_decisions >/dev/null 2>&1
assert_no_file "aged dead-window decision reaped"            "$DECISIONS_DIR/w-dead1.eeee00000002.json"
assert_no_file "second dead window's decision reaped"        "$DECISIONS_DIR/w-dead2.eeee00000003.json"
assert_no_file "dead window's TOMBSTONE reaped too (it suppresses nothing now)" \
    "$DECISIONS_DIR/w-dead2.eeee00000004.handled.json"
assert_file_exists "LIVE window's decision untouched"        "$DECISIONS_DIR/w-live.eeee00000001.json"

# Empty live set (tmux transient) must reap NOTHING — same pass-through
# guard the emit skip carries. This is the one that could delete a real
# worker's pending permission prompt.
echo '=== render_pending_decisions: empty live set reaps nothing (#790 guard) ==='
_pd790_reset ""
_pd790_seed w-orphan ffff00000001
touch -d '2 hours ago' "$DECISIONS_DIR/w-orphan.ffff00000001.json"
render_pending_decisions >/dev/null 2>&1
assert_file_exists "tmux returned nothing: decision NOT reaped" \
    "$DECISIONS_DIR/w-orphan.ffff00000001.json"

# Knob off disables the reap.
_pd790_reset "w-live"
_pd790_seed w-dead9 ffff00000002
touch -d '2 hours ago' "$DECISIONS_DIR/w-dead9.ffff00000002.json"
MONITOR_PENDING_REAP_DEAD_WINDOWS=false render_pending_decisions >/dev/null 2>&1
assert_file_exists "MONITOR_PENDING_REAP_DEAD_WINDOWS=false → nothing reaped" \
    "$DECISIONS_DIR/w-dead9.ffff00000002.json"

# A filename that does not match the convention is left alone: it is
# evidence of something else being wrong, and deleting it destroys the
# only trace.
_pd790_reset "w-live"
printf '{}\n' > "$DECISIONS_DIR/not-a-decision-file.json"
touch -d '2 hours ago' "$DECISIONS_DIR/not-a-decision-file.json"
render_pending_decisions >/dev/null 2>&1
assert_file_exists "malformed filename is NOT reaped" "$DECISIONS_DIR/not-a-decision-file.json"
rm -f "$DECISIONS_DIR/not-a-decision-file.json"

# ---- Test 21a: a reap that CANNOT reap says so -------------------------
#
# Skeptic finding. The first draft was
#   `rm -f "$f" 2>/dev/null && reaped=$(( reaped + 1 ))`
# with the count discarded by the caller — so a reap that could never
# remove anything (read-only state dir, permissions change, immutable bit)
# was byte-identical, in every observable, to a reap with nothing to do.
# Silence as a proxy for success: the defect class #790 is about,
# reproduced inside #790's own fix. The directory would grow without bound
# and the only symptom would be the absence of symptoms.
echo '=== _reap_dead_window_decisions: a failing reap is LOUD, not silent (#790 skeptic) ==='
_pd790_reset "w-live"
_pd790_seed w-dead-ro 1234abcd5678
touch -d '2 hours ago' "$DECISIONS_DIR/w-dead-ro.1234abcd5678.json"
# Make removal impossible without making the file unreadable: `rm` needs
# WRITE on the directory, not on the file.
chmod a-w "$DECISIONS_DIR"
reap_err=$(_reap_dead_window_decisions "$DECISIONS_DIR" "w-live" "$(date +%s)" 2>&1 >/dev/null)
chmod u+w "$DECISIONS_DIR"
assert_file_exists "control: the file really did survive (so the reap really did fail)" \
    "$DECISIONS_DIR/w-dead-ro.1234abcd5678.json"
assert_contains "a reap that removed nothing it meant to remove reports on stderr" \
    "$reap_err" "reap FAILED"
# …and the diagnostic must not land on stdout, which IS the operator emit
# channel — a diagnostic there parses as a decision row.
chmod a-w "$DECISIONS_DIR"
reap_out=$(_reap_dead_window_decisions "$DECISIONS_DIR" "w-live" "$(date +%s)" 2>/dev/null)
chmod u+w "$DECISIONS_DIR"
assert_not_contains "the diagnostic does NOT go to stdout (that is the emit channel)" \
    "$reap_out" "reap FAILED"
# The happy path stays quiet — otherwise the loud arm is just noise.
reap_err_ok=$(_reap_dead_window_decisions "$DECISIONS_DIR" "w-live" "$(date +%s)" 2>&1 >/dev/null)
assert_eq "a reap that succeeds says nothing" "$reap_err_ok" ""
assert_no_file "…and it did remove the file" "$DECISIONS_DIR/w-dead-ro.1234abcd5678.json"

# ---- Test 21b: the resolver's THREE-STATE contract ---------------------
#
# `test-tmux-window-resolver.sh`'s D1 manifest now carries
# `_pd_resolve_window_index|…|3state`. That is a CLAIM, and the manifest
# checks only that a declaration exists — not that it is true. Pin the
# behaviour here so the two cannot drift: a resolver declared three-state
# while conflating its failure arms is worse than one honestly declared
# `2state-failclosed`, because the manifest then certifies the conflation.
echo '=== _pd_resolve_window_index: three-state contract (rc 0 / 1 / 3) ==='
_pd_resolve_window_index "w-a" "w-a|7"$'\n'"w-b|9" >/dev/null; assert_eq "present → rc 0" "$?" "0"
assert_eq "present → prints the index" "$(_pd_resolve_window_index "w-b" "w-a|7"$'\n'"w-b|9")" "9"
_pd_resolve_window_index "w-gone" "w-a|7" >/dev/null
assert_eq "snapshot read, name ABSENT → rc 1 (not present)" "$?" "1"
_pd_resolve_window_index "w-a" "" >/dev/null
assert_eq "no snapshot → rc 3 (COULD NOT LOOK, distinct from absent)" "$?" "3"
# The distinction is the whole point of the split; assert the two arms are
# not the same number.
_pd_resolve_window_index "w-gone" "w-a|7" >/dev/null; _rc_absent=$?
_pd_resolve_window_index "w-a" ""        >/dev/null; _rc_blind=$?
[[ "$_rc_absent" != "$_rc_blind" ]] \
    && { printf '  PASS: absent (%s) and could-not-look (%s) are DISTINCT arms\n' "$_rc_absent" "$_rc_blind"; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: both failure arms return rc %s — the resolver conflates, and the D1 manifest calls it 3state\n' "$_rc_absent" >&2; FAIL=$(( FAIL + 1 )); }
# A `|` delimiter is load-bearing: a TAB would be rewritten to `_` by tmux
# in a non-UTF-8 locale with $TMUX unset (test-tmux-window-resolver F1/F3),
# the row would never split, and this resolver would answer rc 1 for a LIVE
# window — failing open forever and silently reverting #790's whole point.
assert_eq "parses the pipe-delimited row shape the tmux query emits" \
    "$(_pd_resolve_window_index "win" "win|3")" "3"
assert_eq "a TAB-delimited row does NOT parse as a resolution (regression witness)" \
    "$(_pd_resolve_window_index "win" "win"$'\t'"3" 2>/dev/null)" ""

# ---- Test 22: the gate is reachable from the watcher's REAL load path --
#
# The gate fails open when `bk_decision_row_actionable` is undefined, so
# a watcher that never sourced `_bookkeeping.sh` would behave EXACTLY as
# it did before this fix, silently. Every assertion above would still
# pass — they source the predicate themselves. This is the assertion that
# catches a dead fix, and it is deliberately about main.sh's tracked
# `source "$_script_dir/…"` lines, because that is both how the watcher
# loads and how `_version_watcher_source_set` decides what a self-restart
# watches.
echo '=== the pane gate is reachable from the watcher load path (#790) ==='
main_sh="$_test_dir/main.sh"
tracked=$(sed -nE 's|^[[:space:]]*source[[:space:]]+"\$_script_dir/([^"]+)".*|\1|p' "$main_sh")
if grep -qx -- '\.\./_bookkeeping\.sh' <<<"$tracked"; then
    printf '  PASS: main.sh sources ../_bookkeeping.sh via the version-tracked pattern\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: main.sh has no tracked `source "$_script_dir/../_bookkeeping.sh"` — the gate would be inert in production\n' >&2
    FAIL=$(( FAIL + 1 ))
fi
# …and the file it names really defines the predicate. Loading the name
# is not the property; having the function is.
if bash -c '. "$1" >/dev/null 2>&1; declare -F bk_decision_row_actionable >/dev/null' _ "$_monitor_dir/_bookkeeping.sh"; then
    printf '  PASS: that file defines bk_decision_row_actionable\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: _bookkeeping.sh does not define bk_decision_row_actionable\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- summary -----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
