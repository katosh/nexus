#!/usr/bin/env bash
# Unit tests for the watcher's functional-check signal
# (`monitor/watcher/_functional_check.sh`, other-nexus-lessons L1).
#
# The functional check is orthogonal to the heartbeat / pid / paste
# liveness model: it asks "did the bot actually REACT to a comment
# the watcher recently surfaced?" Empirically, a wedged orchestrator
# can pass the heartbeat/pid/paste-receipt signals (Stop hook still
# firing, paste hook still firing, no crash) while quietly failing
# to issue any `gh api reactions` writes against surfaced eligible
# comments. The 24h monitor on other-nexus#9 demonstrated the
# gap; this check closes it.
#
# Inputs:
#
#   - Recent emit-archive files in `monitor/.state/diffs/` containing
#     an `--- eligible github comments ---` section. The check
#     extracts (repo, comment_id) pairs from header lines matching
#     `issue=<n> id=<id>` (in-repo) and `mention=<repo> ... id=<id>`
#     (cross-repo). Other emit headers (pr_review, issue_new, pr,
#     cross_repo) are ignored for v1.
#
#   - Per-comment reaction state via `gh api repos/<repo>/issues/
#     comments/<id>/reactions`. The check asks "did the bot react
#     with eyes or rocket within MONITOR_FUNCTIONAL_SLA_SECONDS of
#     the emit's mtime?" Tests inject a `gh`-shim that consults a
#     fixture map.
#
# Per-emit verdict:
#
#   - At least one surfaced comment has a bot reaction within SLA
#     of the emit's mtime → emit is "processed."
#   - Every surfaced comment is verified unprocessed (no reaction,
#     or reaction outside SLA) → emit is "stale."
#   - Otherwise (no comment IDs extractable, gh failures) → emit is
#     "unknown" and does not count toward either bucket.
#
# Top-level verdict (alarm condition):
#
#   - Count emits within `now - SLA` whose verdict is processed vs
#     stale. If every counted emit is stale AND at least one emit
#     was counted → ALARM. Otherwise healthy.
#
# Bypass cases:
#
#   - `MONITOR_FUNCTIONAL_SLA_SECONDS=0` → check disabled entirely.
#   - No emit files within the horizon contain extractable comment
#     IDs → no signal to assert against, bypass.
#
# Cases covered:
#
#   1. all emits have reactions within SLA → no alarm.
#   2. all emits have NO reaction (over SLA) → alarm fires.
#   3. mixed: at least one processed → no alarm.
#   4. empty emit history → bypass (no signal).
#   5. workspace-empty + no eligible-comments-in-SLA → bypass.
#   6. knob=0 → check short-circuits with bypass; no state write.
#   7. cross-repo `mention=` parses correctly into (repo, id).
#   8. state file written: append-only TSV row per check.
#
# Fault-domain classification (`_functional_fault_class`) — the
# revive-decision gate that turns a FIRED "stale" verdict into one of
# watcher-fault (self-heal) / orchestrator-fault / quiet (no restart):
#
#   F1. QUIET (loop alive, delivery aged past SLA, no delivery
#       failures) → `quiet`, NOT watcher-fault. This is the
#       false-positive the re-aim kills: a quiet workspace must not
#       trigger a spurious watcher revive.
#   F2. delivery fresh, loop alive, no failures → `orchestrator-fault`.
#   F3. REAL WEDGE — loop-proof heartbeat STALE (rc=2 DEAD / rc=3
#       no-heartbeat) → `watcher-fault` (still alarms).
#   F4. REAL WEDGE — emits generated-but-stuck (delivery-fail count
#       > 0) → `watcher-fault` (still alarms), even with a fresh
#       delivery clock (fail counter wins).
#   F5. AGING-but-alive loop (rc=1) with delivery aged + no failures →
#       `quiet`, NOT watcher-fault (only DEAD/no-hb, rc>=2, revives).
#
# Run: bash monitor/watcher/test-functional-check.sh

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_functional_check.sh
source "$_script_dir/_functional_check.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

DIFF_DIR="$WORK/diffs"
STATE_FILE="$WORK/functional-check.tsv"
REACTIONS_DIR="$WORK/reactions"
mkdir -p "$DIFF_DIR" "$REACTIONS_DIR"

BOT_LOGIN="your-org-bot"
DEFAULT_REPO="your-org/your-nexus"
SLA=600
MAX_EMITS=5

# ---- fixture helpers ------------------------------------------------

# Plant an emit-archive file with the given comment-id rows + mtime.
# Arg shape: <relative-name> <age_seconds> <header1> [header2 ...]
plant_emit() {
    local name="$1" age="$2"
    shift 2
    local path="$DIFF_DIR/$name"
    {
        printf '=== nexus state changed at fake (signal) ===\n'
        printf '%s\n' '--- eligible github comments ---'
        local h
        for h in "$@"; do
            printf '%s\n' "$h"
            printf '  body: (preview)\n'
        done
        printf '%s\n' '--- dashboard ---'
    } > "$path"
    touch -d "$age seconds ago" "$path"
}

# Plant a `gh api` reaction response under the fixture dir. The shim
# reads `$REACTIONS_DIR/<id>.json` and prints it to stdout (so the
# check sees the same shape `gh api` returns). Reactions JSON is an
# array of `{user.login, content}` objects.
plant_reaction() {
    local id="$1" reactor_login="$2" content="$3"
    printf '[{"user":{"login":"%s"},"content":"%s"}]\n' \
        "$reactor_login" "$content" > "$REACTIONS_DIR/$id.json"
}

# Plant an empty-reactions response (the bot did not react).
plant_no_reaction() {
    local id="$1"
    printf '[]\n' > "$REACTIONS_DIR/$id.json"
}

# Shim that the check invokes via $gh_cmd indirection. Recognises the
# single endpoint shape we care about and prints the fixture file's
# contents.
gh_shim() {
    if [[ "$1" == "api" && "$2" =~ ^repos/.*/issues/comments/([0-9]+)/reactions$ ]]; then
        local id="${BASH_REMATCH[1]}"
        local fixture="$REACTIONS_DIR/$id.json"
        if [[ -f "$fixture" ]]; then
            cat "$fixture"
            return 0
        fi
        # Missing fixture = simulate a 404 (gh returns non-zero +
        # error on stderr). The check treats this as "unknown."
        echo "gh-shim: no fixture for id=$id" >&2
        return 1
    fi
    echo "gh-shim: unrecognised invocation: $*" >&2
    return 2
}
export -f gh_shim

reset_world() {
    rm -rf "$DIFF_DIR" "$REACTIONS_DIR"
    rm -f "$STATE_FILE"
    mkdir -p "$DIFF_DIR" "$REACTIONS_DIR"
}

# Drive the check and capture verdict + rc.
run_check() {
    local sla="${1:-$SLA}"
    local verdict rc=0
    verdict=$(_functional_check_decide \
        "$DIFF_DIR" "$sla" "$MAX_EMITS" \
        "$DEFAULT_REPO" "$BOT_LOGIN" "$STATE_FILE" \
        gh_shim) || rc=$?
    printf '%s\n' "$verdict"
    return $rc
}

# ---- 1: all emits processed within SLA -----------------------------
reset_world
plant_emit "a.md"  30  "issue=128 id=1001 author=operator"
plant_emit "b.md" 120  "issue=128 id=1002 author=operator"
plant_reaction 1001 "$BOT_LOGIN" "eyes"
plant_reaction 1002 "$BOT_LOGIN" "rocket"
verdict=$(run_check); rc=$?
if (( rc == 0 )) && [[ "$verdict" == healthy* ]]; then
    pass "all-processed → healthy verdict"
else
    fail "all-processed: expected healthy rc=0, got rc=$rc verdict=$verdict"
fi

# ---- 2: all emits stale (no reactions) -----------------------------
reset_world
plant_emit "a.md" 900  "issue=128 id=2001 author=operator"
plant_emit "b.md" 800  "issue=128 id=2002 author=operator"
plant_no_reaction 2001
plant_no_reaction 2002
verdict=$(run_check); rc=$?
if (( rc == 1 )) && [[ "$verdict" == stale* ]]; then
    pass "all-stale (over SLA) → alarm/stale verdict"
else
    fail "all-stale: expected stale rc=1, got rc=$rc verdict=$verdict"
fi

# ---- 3: mixed — at least one processed → healthy -------------------
reset_world
plant_emit "a.md" 700  "issue=128 id=3001 author=operator"
plant_emit "b.md"  60  "issue=128 id=3002 author=operator"
plant_no_reaction 3001
plant_reaction 3002 "$BOT_LOGIN" "eyes"
verdict=$(run_check); rc=$?
if (( rc == 0 )) && [[ "$verdict" == healthy* ]]; then
    pass "mixed (one processed) → healthy verdict"
else
    fail "mixed: expected healthy rc=0, got rc=$rc verdict=$verdict"
fi

# ---- 4: empty emit history → bypass --------------------------------
reset_world
verdict=$(run_check); rc=$?
if (( rc == 2 )) && [[ "$verdict" == bypass* ]]; then
    pass "empty-emit-history → bypass verdict"
else
    fail "empty: expected bypass rc=2, got rc=$rc verdict=$verdict"
fi

# ---- 5: no eligible-comments in horizon → bypass -------------------
# Plant emit files with NO comment-id rows. They count as "no signal
# to assert" — same as workspace-empty.
reset_world
{
    printf '=== nexus state changed ===\n'
    printf '%s\n' '--- dashboard ---'
} > "$DIFF_DIR/no-comments.md"
touch -d "30 seconds ago" "$DIFF_DIR/no-comments.md"
verdict=$(run_check); rc=$?
if (( rc == 2 )) && [[ "$verdict" == bypass* ]]; then
    pass "no-eligible-comments-in-SLA → bypass verdict"
else
    fail "no-eligible: expected bypass rc=2, got rc=$rc verdict=$verdict"
fi

# ---- 6: knob=0 short-circuits with bypass + no state write ---------
reset_world
plant_emit "a.md" 900  "issue=128 id=6001 author=operator"
plant_no_reaction 6001
# Pre-existing TSV state should not be touched on a knob-zero call.
echo "pre-existing-row" > "$STATE_FILE"
verdict=$(run_check 0); rc=$?
if (( rc == 2 )) && [[ "$verdict" == *"reason=disabled"* ]]; then
    pass "knob=0 → bypass disabled verdict"
else
    fail "knob=0: expected bypass+reason=disabled rc=2, got rc=$rc verdict=$verdict"
fi
state_content=$(cat "$STATE_FILE" 2>/dev/null || true)
if [[ "$state_content" == "pre-existing-row" ]]; then
    pass "knob=0 → state file untouched"
else
    fail "knob=0: state file was modified (content=$state_content)"
fi

# ---- 7: cross-repo `mention=` parses correctly ---------------------
reset_world
plant_emit "a.md"  60 \
    "mention=your-org/other-nexus kind=issue n=9 id=7001 author=operator"
plant_reaction 7001 "$BOT_LOGIN" "rocket"
verdict=$(run_check); rc=$?
if (( rc == 0 )) && [[ "$verdict" == healthy* ]]; then
    pass "cross-repo mention= → parses + verifies reaction → healthy"
else
    fail "cross-repo: expected healthy rc=0, got rc=$rc verdict=$verdict"
fi

# Confirm the shim was actually invoked against the cross-repo path.
# The fixture key is the comment id alone, so verifying healthy on a
# planted reaction proves the routing.

# ---- 8: state file written — append-only TSV row -------------------
# After the previous cases, $STATE_FILE should contain rows of the
# shape `ts<TAB>n_emits_checked<TAB>n_processed<TAB>n_stale<TAB>decision`.
# Verify the most recent case (case 7) appended a row that records
# the healthy decision.
reset_world
plant_emit "a.md"  60  "issue=128 id=8001 author=operator"
plant_reaction 8001 "$BOT_LOGIN" "eyes"
: > "$STATE_FILE"
verdict=$(run_check); rc=$?
if [[ -s "$STATE_FILE" ]]; then
    line=$(tail -n 1 "$STATE_FILE")
    cols=$(awk -F'\t' '{print NF}' <<<"$line")
    if (( cols >= 5 )); then
        pass "state-file: appended TSV row (cols=$cols)"
    else
        fail "state-file: row has too few columns (cols=$cols, line=$line)"
    fi
    if grep -q "healthy" <<<"$line"; then
        pass "state-file: row records healthy decision"
    else
        fail "state-file: row does not record healthy (line=$line)"
    fi
else
    fail "state-file: not written after successful check"
fi

# ---- 9: bypass case does NOT alarm even with stale fixtures --------
# Defense-in-depth: confirm the bypass path absolutely cannot return
# the stale verdict. An empty diff dir with no SLA-window emits must
# yield bypass even if a stale-fixture state file pre-exists.
reset_world
echo -e "0\t0\t0\t0\tstale-historical" > "$STATE_FILE"
verdict=$(run_check); rc=$?
if (( rc == 2 )); then
    pass "bypass cannot escalate to stale (rc=$rc)"
else
    fail "bypass escalation: expected rc=2, got rc=$rc verdict=$verdict"
fi

# ---- fault-domain classification (the revive-decision gate) --------
# `_functional_fault_class <loop_alive_rc> <fail_count> <delivery_age> <sla>`
# is PURE — no globals, no I/O — so we exercise the full quiet-vs-wedge
# matrix directly. rc: 0=watcher-fault 1=orchestrator-fault 2=quiet.
assert_fault() {
    local desc="$1" exp_class="$2" exp_rc="$3"
    shift 3
    local out rc=0
    out=$(_functional_fault_class "$@") || rc=$?
    if [[ "$out" == "$exp_class"* ]] && (( rc == exp_rc )); then
        pass "$desc → $exp_class (rc=$rc)"
    else
        fail "$desc: expected $exp_class rc=$exp_rc, got rc=$rc out=$out"
    fi
}

# F1: QUIET — loop fresh (rc=0), no delivery failures, delivery aged
# PAST the SLA. The pre-fix gate revived here; the re-aim must NOT.
assert_fault "F1 quiet (loop fresh, deliver aged, no fails)" \
    "quiet" 2   0 0 900 600
# F2: delivery FRESH, loop alive, no failures → orchestrator's job.
assert_fault "F2 delivery-fresh (un-acked but delivered)" \
    "orchestrator-fault" 1   0 0 120 600
# F3: REAL WEDGE — loop-proof heartbeat STALE (DEAD bucket rc=2) → revive.
assert_fault "F3 wedge: loop heartbeat DEAD (rc=2)" \
    "watcher-fault" 0   2 0 900 600
# F3b: REAL WEDGE — no heartbeat file at all (rc=3) → revive.
assert_fault "F3b wedge: no loop heartbeat (rc=3)" \
    "watcher-fault" 0   3 0 900 600
# F4: REAL WEDGE — emits generated-but-stuck (delivery-fail>0) → revive,
# even though the loop heartbeat is fresh (rc=0).
assert_fault "F4 wedge: emits-generated-but-stuck (fail=3)" \
    "watcher-fault" 0   0 3 900 600
# F4b: fail counter WINS even when the delivery clock looks fresh.
assert_fault "F4b emits-stuck dominates fresh delivery clock" \
    "watcher-fault" 0   0 1 100 600
# F5: AGING-but-alive loop (rc=1) + delivery aged + no failures → quiet.
# Only DEAD/no-hb (rc>=2) is a watcher fault; a merely-aging loop is not.
assert_fault "F5 aging loop (rc=1), no fails, deliver aged → quiet" \
    "quiet" 2   1 0 900 600

# ---- summary -------------------------------------------------------
total=$(( PASS + FAIL ))
printf '\nfunctional-check tests: %d/%d passed\n' "$PASS" "$total"
(( FAIL == 0 ))
