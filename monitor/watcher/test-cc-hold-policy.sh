#!/usr/bin/env bash
# Tests for the cc auto-update HOLD POLICY (your-org/nexus-code#1657):
# only a COMPAT outcome — candidate-attributed evidence that nexus-code breaks,
# with a passing control and a tracked fix — holds an update; every other
# non-apply schedules a retry within hours and nothing waits for an operator.
#
# Sections:
#   A  cc_hold_class — the classifier over the decision vocabulary
#   B  cc_hold_block_contract — the shape of a COMPAT block
#   C  the retry schedule — due / not yet / exhausted / manual / COMPAT head
#   D  Guard 4 narrowed — skips only a same-day COMPAT hold at an unchanged HEAD
#   E  apply.sh block / retry-now, end to end on a fixture root
#   F  the watcher tick fires on a due retry, and consumes it once
#   G  gate.sh routes the exemption ratchet: outside the executed set is
#      hygiene (scenarios run), inside it still refuses
#   H  the deployment gate has no deferring arm left
#   R  REPLAY of 2026-08-27..09-27 through the new policy — the five real
#      compat holds still hold, everything else proceeds or retries
#
# Hermetic: fixture roots under mktemp, stub claude/spawn/gh, no network, no
# live state. Run: bash monitor/watcher/test-cc-hold-policy.sh

set -uo pipefail
_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MONITOR_DIR=$(cd "$_script_dir/.." && pwd)
export NEXUS_NOTIFY_QUIET=1

. "$MONITOR_DIR/_guard_population.sh"
gp_population() {
    printf '%s\n' \
        "$MONITOR_DIR/_cc-hold-policy.sh" \
        "$MONITOR_DIR/cc-auto-update-apply.sh" \
        "$MONITOR_DIR/cc-auto-update-prompt.md" \
        "$MONITOR_DIR/cc-harness/gate.sh" \
        "$MONITOR_DIR/cc-harness/lint-no-tmux-server-kill.sh" \
        "$_script_dir/_cc_auto_update.sh" \
        "$_script_dir/_cc_update.sh" \
        "$MONITOR_DIR/_cc-version.sh" \
        "$MONITOR_DIR/cc-floor.sh" \
        "$_script_dir/fixtures/cc-hold-replay-2026-08-27_09-27.tsv"
}
gp_handle "$@"

# The SHARED harness: its _th_pass/_th_fail write the subshell-durable ledger
# `th_summary_and_exit` reconciles, so a failure lost in a subshell still reds
# the suite (your-org/nexus-code#805) — and test-summary-honesty-manifest.sh
# records a new suite as protected only on that footing.
. "$_script_dir/_test_helpers.sh"
PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

WORK=$(mktemp -d)
th_trap_exit 'rm -rf "$WORK"'
. "$MONITOR_DIR/_cc-hold-policy.sh"

# ===== A. classifier ========================================================
echo "== A. cc_hold_class =="
a_expect() {  # decision detail want
    local got; got=$(cc_hold_class "$1" "$2")
    [[ "$got" == "$3" ]] && pass "class($1${2:+ ${2:0:24}}) = $3" || fail "class($1 $2) = $got, want $3"
}
a_expect block "class=compat evidence=gate:x issue=o/r#1" COMPAT
a_expect block "compat fix needed: https://x" COMPAT            # legacy row: conservative
a_expect block "class=not-compat missing=issue" NOT-COMPAT
a_expect compat-pr-opened "" COMPAT
a_expect compat-pr-commented "" COMPAT
for d in safe-deferred safe-refused block-unattributable block-not-compat \
         eval-safe-unapplyable skipped-awaiting-operator safe-failed spawn-failed \
         live-tree-drift some-word-nobody-wrote; do
    a_expect "$d" "" NOT-COMPAT
done
for d in safe-bumped-restart-handoff safe-bumped-restarted safe-bumped-restart-forced \
         safe-bumped-no-restart reconcile-fired; do
    a_expect "$d" "" APPLIED
done
for d in spawned surface-evidence changelog-completeness changelog-gap deployment-gate \
         retry-scheduled retry-fired gate-red-preexisting gated-tree-dirty-accepted \
         pr-under-active-review-noted skipped-compat-hold-same-day cc-floor-proposed; do
    a_expect "$d" "" AUDIT
done

# ===== B. block contract ===================================================
echo "== B. cc_hold_block_contract =="
probe="$WORK/findings.md"; printf 'measured\n' > "$probe"
check "gate evidence + url issue + control → COMPAT contract" \
    'cc_hold_block_contract gate:test-realmodel-x https://github.com/o/r/issues/12 "2.1.1 passes" >/dev/null'
check "probe evidence + owner/repo#N issue → COMPAT contract" \
    'cc_hold_block_contract "probe:$probe" o/r#12 "2.1.1 passes" >/dev/null'
b_missing() { local m; m=$(cc_hold_block_contract "$1" "$2" "$3") && return 1; [[ "$m" == *"$4"* ]]; }
check "no evidence → missing evidence"       'b_missing "" o/r#1 ctl evidence'
check "no issue → missing issue"             'b_missing gate:x "" ctl issue'
check "bare #N issue is not a reference"     'b_missing gate:x "#1591" ctl issue'
check "whitespace control → missing control" 'b_missing gate:x o/r#1 "   " control'
check "absent probe file → refused"          'b_missing probe:/nonexistent/f o/r#1 ctl probe-file-missing'
check "empty probe file → refused"           ': > "$WORK/empty"; b_missing "probe:$WORK/empty" o/r#1 ctl probe-file-missing'
check "free-text evidence → refused"         'b_missing "gate RED 6/7" o/r#1 ctl evidence'

# ===== C. retry schedule ===================================================
echo "== C. retry schedule =="
D="$WORK/c"; mkdir -p "$D"; T0=$(date -d '2026-09-27 12:00' +%s)
out=$(cc_hold_schedule_retry "$D" 2.1.9 safe-deferred "x" "$T0" unknown)
check "NOT-COMPAT outcome schedules a retry" '[[ "$out" == retry-scheduled* && -f "$D/retry-at" ]]'
check "retry is not due before CC_AUTO_RETRY_SECONDS" \
    '! cc_hold_retry_due "$D" $(( T0 + CC_AUTO_RETRY_SECONDS - 1 )) unknown >/dev/null'
check "retry is due at CC_AUTO_RETRY_SECONDS" \
    'cc_hold_retry_due "$D" $(( T0 + CC_AUTO_RETRY_SECONDS )) unknown >/dev/null'
check "retry delay is hours, not a day (<= 6h)" '(( CC_AUTO_RETRY_SECONDS <= 21600 ))'
cc_hold_schedule_retry "$D" 2.1.9 safe-bumped-restart-handoff "" "$T0" >/dev/null
check "an applied outcome clears the schedule" '[[ ! -f "$D/retry-at" ]]'
cc_hold_schedule_retry "$D" 2.1.9 safe-refused "x" "$T0" >/dev/null
cc_hold_schedule_retry "$D" 2.1.9 surface-evidence "x" "$T0" >/dev/null
check "an AUDIT row leaves the schedule alone" '[[ -f "$D/retry-at" ]]'
# exhaustion
for i in $(seq 1 "$CC_AUTO_RETRY_MAX_PER_DAY"); do cc_hold_retry_consume "$D" "$T0"; done
cc_hold_schedule_retry "$D" 2.1.9 safe-refused "x" "$T0" >/dev/null
rc=0; cc_hold_retry_due "$D" $(( T0 + CC_AUTO_RETRY_SECONDS )) unknown >/dev/null || rc=$?
check "per-day retry cap → rc 3 (exhausted)" '(( rc == 3 ))'
rc=0; cc_hold_retry_due "$D" $(( T0 + 86400 + CC_AUTO_RETRY_SECONDS )) unknown >/dev/null || rc=$?
check "the cap is per DAY: the next day is due again" '(( rc == 0 ))'
cc_hold_request_retry "$D" 2.1.9 "operator asked" "$T0"
check "a manual retry-now is due immediately, past the cap" 'cc_hold_retry_due "$D" "$T0" unknown >/dev/null'
# COMPAT: head-moved only
E="$WORK/c2"; mkdir -p "$E"
H1=1111111111111111111111111111111111111111; H2=2222222222222222222222222222222222222222
cc_hold_schedule_retry "$E" 2.1.9 block "class=compat x" "$T0" "$H1" >/dev/null
late=$(( T0 + CC_AUTO_COMPAT_RECHECK_MIN_SECONDS ))
check "COMPAT re-check does NOT fire at an unchanged HEAD" '! cc_hold_retry_due "$E" "$late" "$H1" >/dev/null'
check "COMPAT re-check does NOT fire when the HEAD is unreadable" '! cc_hold_retry_due "$E" "$late" unknown >/dev/null'
check "COMPAT re-check fires once the HEAD moved (the fix landed)" 'cc_hold_retry_due "$E" "$late" "$H2" >/dev/null'
check "COMPAT re-check waits the minimum interval even if HEAD moved" \
    '! cc_hold_retry_due "$E" $(( late - 1 )) "$H2" >/dev/null'
printf 'at=garbage\n' > "$E/retry-at"
check "a MALFORMED schedule is due now, never 'wait forever'" 'cc_hold_retry_due "$E" "$T0" unknown >/dev/null'

# ===== D. Guard 4 narrowed ==================================================
echo "== D. Guard 4 =="
log() { :; }
. "$_script_dir/_cc_update.sh"
. "$MONITOR_DIR/_cc-version.sh"
. "$_script_dir/_cc_auto_update.sh"
G="$WORK/d"; mkdir -p "$G"
mk_last_eval() {  # decision detail date
    printf 'candidate=2.1.278\ndecision=%s\ndate=%s\ndetail=%s\n' "$1" "$3" "$2" > "$G/last-eval"
}
NOW=$(date -d '2026-09-20 04:02' +%s)
mk_last_eval block "class=compat evidence=probe:f issue=o/r#1591 | x | live_head=$H1 live_ref=dev" "2026-09-19T04:21:47-07:00"
check "a COMPAT hold from YESTERDAY is re-evaluated (the old code skipped it for 3 days)" \
    '! _cc_auto_last_eval_skip "$G" 2.1.278 "$NOW" "$H1"'
NOW_SAME=$(date -d '2026-09-19 12:00' +%s)
check "a COMPAT hold from TODAY at the same HEAD is skipped" \
    '_cc_auto_last_eval_skip "$G" 2.1.278 "$NOW_SAME" "$H1"'
check "a COMPAT hold from TODAY with the HEAD moved is re-evaluated" \
    '! _cc_auto_last_eval_skip "$G" 2.1.278 "$NOW_SAME" "$H2"'
mk_last_eval block-not-compat "class=not-compat missing=control" "2026-09-19T04:21:47-07:00"
check "a NOT-COMPAT block is never skipped, even the same day" \
    '! _cc_auto_last_eval_skip "$G" 2.1.278 "$NOW_SAME" "$H1"'
mk_last_eval block-unattributable "gate-tree-stamp-missing" "2026-09-19T04:21:47-07:00"
check "block-unattributable is never skipped" '! _cc_auto_last_eval_skip "$G" 2.1.278 "$NOW_SAME" "$H1"'

# ===== E. apply.sh block / retry-now on a fixture root ======================
echo "== E. apply.sh block contract, end to end =="
make_root() {
    local root="$1" floor="$2"
    mkdir -p "$root/monitor/.state/cc-auto-update" "$root/node_modules/.bin"
    cat > "$root/node_modules/.bin/claude" <<EOF
#!/usr/bin/env bash
v=\$(cat "$root/monitor/.state/cc-version-local" 2>/dev/null); [[ -n "\$v" ]] || v="$floor"
echo "\$v (Claude Code)"
EOF
    chmod +x "$root/node_modules/.bin/claude"
    printf '{ "dependencies": { "@anthropic-ai/claude-code": "%s" } }\n' "$floor" > "$root/package.json"
}
APPLY="$MONITOR_DIR/cc-auto-update-apply.sh"
run_apply() {  # root args...
    local root="$1"; shift
    NEXUS_ROOT="$root" NEXUS_STATE_DIR="$root/monitor/.state" \
    CC_AUTO_CLAUDE_BIN="$root/node_modules/.bin/claude" \
    CC_AUTO_MINT_CMD=/nonexistent/mint CC_AUTO_GATE_ISSUE_CMD=true \
        bash "$APPLY" "$@" >> "$root/producer.log" 2>&1
}
R="$WORK/e1"; make_root "$R" 2.1.280
rc=0; run_apply "$R" block --candidate 2.1.283 --reason "residual uncertainty" || rc=$?
check "block with no evidence → rc 12 (not a hold)" '(( rc == 12 ))'
check "  … last-eval decision=block-not-compat" 'grep -qx "decision=block-not-compat" "$R/monitor/.state/cc-auto-update/last-eval"'
check "  … a NOT-COMPAT retry is scheduled" 'grep -qx "class=NOT-COMPAT" "$R/monitor/.state/cc-auto-update/retry-at"'
check "  … the ledger names what was missing" 'grep -q "block-not-compat.*missing=evidence,issue,control" "$R/monitor/.state/cc-auto-update/decisions.tsv"'

R="$WORK/e2"; make_root "$R" 2.1.280
GL="$R/monitor/.state/cc-auto-update/gate-2.1.283.log"
printf 'gating 2.1.283\n=== tally: 6 passed / 1 failed / 0 skipped (of 7) ===\n    failed:  test-realmodel-trust-dialog.sh\n=== GATE RED (6 passed / 1 failed / 0 skipped) ===\n' > "$GL"
rc=0; run_apply "$R" block --candidate 2.1.283 --reason "trust dialog" --gate-evidence "$GL" \
    --evidence gate:test-realmodel-trust-dialog --issue your-org/nexus-code#1112 \
    --control "2.1.280 GREEN on the same tree" || rc=$?
# the tree stamp is absent in this synthetic log → the existing #1259 arm refuses attribution
check "block on a gate log with no tree stamp → unattributable (rc 3), NOT a hold" '(( rc == 3 ))'
check "  … and it schedules a retry" 'grep -qx "class=NOT-COMPAT" "$R/monitor/.state/cc-auto-update/retry-at"'

R="$WORK/e3"; make_root "$R" 2.1.280
FIND="$R/findings.md"; printf 'measured on 2.1.283; 2.1.280 passes\n' > "$FIND"
rc=0; run_apply "$R" block --candidate 2.1.283 --reason "paste held" \
    --evidence "probe:$FIND" --issue https://github.com/your-org/nexus-code/issues/1591 \
    --control "2.1.280: 27/27 arms pass" || rc=$?
check "block with probe evidence + issue + control → rc 0 (COMPAT hold)" '(( rc == 0 ))'
check "  … last-eval decision=block, detail class=compat" \
    'grep -qx "decision=block" "$R/monitor/.state/cc-auto-update/last-eval" && grep -q "^detail=class=compat evidence=probe:" "$R/monitor/.state/cc-auto-update/last-eval"'
check "  … a COMPAT re-check is scheduled" 'grep -qx "class=COMPAT" "$R/monitor/.state/cc-auto-update/retry-at"'

R="$WORK/e4"; make_root "$R" 2.1.280
GL="$R/monitor/.state/cc-auto-update/gate-2.1.283.log"
# A TREE STAMP, so the block reaches the scenario cross-check (without one it
# exits 3 at the #1259 unattributable arm and never tests the claim).
printf 'gating 2.1.283\n=== gated-tree: head=%s ref=dev dirty=0 dirty_tracked=0 untracked=0 dirty_digest=none subject_path=monitor/pane-state.sh subject_blob=%s ===\n    failed:  test-realmodel-paste-held.sh\n=== GATE RED ===\n' \
    "$H1" "$H2" > "$GL"
rc=0; out=$(NEXUS_ROOT="$R" NEXUS_STATE_DIR="$R/monitor/.state" CC_AUTO_CLAUDE_BIN="$R/node_modules/.bin/claude" \
    CC_AUTO_MINT_CMD=/nonexistent/mint CC_AUTO_GATE_ISSUE_CMD=true bash "$APPLY" block --candidate 2.1.283 --reason x \
    --gate-evidence "$GL" --evidence gate:test-realmodel-trust-dialog --issue o/r#1 --control "c" 2>&1) || rc=$?
check "a gate:<scenario> claim the gate log does not bear out HOLDS (rc 12, contract=incomplete) — a malformed hold never applies" \
    '(( rc == 12 )) && grep -qx "decision=block" "$R/monitor/.state/cc-auto-update/last-eval" && grep -q "^detail=class=compat contract=incomplete missing=evidence(scenario-not-failed-in-gate-log)" "$R/monitor/.state/cc-auto-update/last-eval"'
check "  … and it reached the scenario cross-check (not the #1259 unattributable exit)" \
    '! grep -q "block-unattributable" "$R/monitor/.state/cc-auto-update/decisions.tsv"'
check "  … and the note never advises safe" '! grep -q "run \`safe\` now" <<<"$out" && grep -q "do NOT run \`safe\`" <<<"$out"'

R="$WORK/e5"; make_root "$R" 2.1.280
rc=0; run_apply "$R" retry-now --candidate 2.1.283 --reason "operator asked" || rc=$?
check "retry-now → rc 0, manual retry due now, audit row" \
    '(( rc == 0 )) && grep -qx "manual=1" "$R/monitor/.state/cc-auto-update/retry-at" && grep -q "retry-requested" "$R/monitor/.state/cc-auto-update/decisions.tsv"'
rc=0; run_apply "$R" retry-now --candidate 2.1.283 || rc=$?
check "retry-now without --reason → rc 2" '(( rc == 2 ))'

# ===== F. watcher tick fires on a due retry ================================
echo "== F. watcher tick retry path =="
R="$WORK/f1"; make_root "$R" 2.1.280
cp "$MONITOR_DIR/cc-auto-update-prompt.md" "$R/monitor/"
cp "$MONITOR_DIR/issue-ref.sh" "$R/monitor/"
SPAWN_LOG="$R/spawned.log"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$SPAWN_LOG" > "$R/spawn"; chmod +x "$R/spawn"
export CC_AUTO_SPAWN_CMD="$R/spawn"
_cc_auto_window_alive() { return 1; }
tmux() { return 1; }
_cc_auto_reconcile_pending_restart() { :; }
fetch_newer() { printf '{"name":"%s","version":"2.1.283"}\n' "$1"; }
DAYT=$(date -d '2026-09-27 04:05' +%s)
AD="$R/monitor/.state/cc-auto-update"
NEXUS_TEST_NOW=$DAYT _cc_auto_update_tick "$R" "$R/monitor/.state" @anthropic-ai/claude-code 04:00 fetch_newer 5
check "the daily fire spawns" '[[ $(wc -l < "$SPAWN_LOG") -eq 1 ]]'
cc_hold_schedule_retry "$AD" 2.1.283 block-unattributable "gate-tree-stamp-missing" "$DAYT" >/dev/null
NEXUS_TEST_NOW=$(( DAYT + 600 )) _cc_auto_update_tick "$R" "$R/monitor/.state" @anthropic-ai/claude-code 04:00 fetch_newer 5
check "a retry that is not yet due does not fire (still 1 spawn)" '[[ $(wc -l < "$SPAWN_LOG") -eq 1 ]]'
NEXUS_TEST_NOW=$(( DAYT + CC_AUTO_RETRY_SECONDS )) _cc_auto_update_tick "$R" "$R/monitor/.state" @anthropic-ai/claude-code 04:00 fetch_newer 5
check "a due NOT-COMPAT retry re-fires the SAME DAY (2 spawns)" '[[ $(wc -l < "$SPAWN_LOG") -eq 2 ]]'
check "  … recorded as retry-fired, and consumed" 'grep -q "retry-fired" "$AD/decisions.tsv" && [[ ! -f "$AD/retry-at" ]]'
NEXUS_TEST_NOW=$(( DAYT + CC_AUTO_RETRY_SECONDS + 300 )) _cc_auto_update_tick "$R" "$R/monitor/.state" @anthropic-ai/claude-code 04:00 fetch_newer 5
check "a consumed retry does not fire twice" '[[ $(wc -l < "$SPAWN_LOG") -eq 2 ]]'
# live evaluator postpones a retry instead of eating it
cc_hold_schedule_retry "$AD" 2.1.283 safe-refused "x" "$DAYT" >/dev/null
_cc_auto_window_alive() { return 0; }
_cc_auto_evaluator_stale() { CC_AUTO_EVAL_CLASS=working CC_AUTO_EVAL_STATE=busy CC_AUTO_EVAL_STALL_AGE=0; return 1; }
NEXUS_TEST_NOW=$(( DAYT + CC_AUTO_RETRY_SECONDS + 600 )) _cc_auto_update_tick "$R" "$R/monitor/.state" @anthropic-ai/claude-code 04:00 fetch_newer 5
check "a live evaluator POSTPONES a due retry (schedule kept)" '[[ -f "$AD/retry-at" && $(wc -l < "$SPAWN_LOG") -eq 2 ]]'
_cc_auto_window_alive() { return 1; }

# ===== G. gate.sh exemption ratchet routing =================================
echo "== G. gate.sh: manifest ratchet is hygiene outside the executed set =="
S_PASS="$WORK/s-pass.sh"; printf '#!/usr/bin/env bash\necho "  PASS: stub"\nexit 0\n' > "$S_PASS"; chmod +x "$S_PASS"
gout=$(LINT_TMUX_EXPECTED_PRAGMAS=3 CCH_GATE_SCENARIOS="$S_PASS" \
       bash "$MONITOR_DIR/cc-harness/gate.sh" --claude-bin "$(command -v bash)" 2>&1); grc=$?
check "a manifest count that moved OUTSIDE the executed set does not refuse (scenarios run)" \
    'grep -q "=== gate-hygiene: FAIL lint=lint-no-tmux-server-kill" <<<"$gout" && grep -q "=== tally:" <<<"$gout"'
check "  … and no refusal came from the ratchet (the rc is the scenarios' / tree's)" \
    '! grep -q "CHANGED INSIDE the files this gate executes" <<<"$gout"'
gout=$(LINT_TMUX_EXPECTED_PRAGMAS=3 LINT_TMUX_EXPECTED_EXECUTED_PRAGMAS=1 CCH_GATE_SCENARIOS="$S_PASS" \
       bash "$MONITOR_DIR/cc-harness/gate.sh" --claude-bin "$(command -v bash)" 2>&1); grc=$?
check "a count that moved INSIDE the executed set still REFUSES (rc 1, no scenario ran)" \
    '(( grc == 1 )) && ! grep -q "=== tally:" <<<"$gout" && grep -q "CHANGED INSIDE" <<<"$gout"'
gout=$(CCH_GATE_SCENARIOS="$S_PASS" bash "$MONITOR_DIR/cc-harness/gate.sh" --claude-bin "$(command -v bash)" 2>&1)
check "negative control: an unchanged manifest prints no hygiene line" '! grep -q "gate-hygiene" <<<"$gout"'

# ===== H. deployment gate: no deferring arm =================================
echo "== H. deployment gate =="
n=$(grep -cE '^\s*(if ! )?_gate_defer "' "$APPLY" || true)
check "no _gate_defer call site remains in apply.sh (was 1: active review)" '[[ "$n" == 0 ]]'
check "active review is RECORDED (pr-under-active-review-noted)" 'grep -qF "\"pr-under-active-review-noted\"" "$APPLY"'

# ===== I. F1 — a pre-existing RED needs a REAL control =======================
# your-org/nexus-code#1657 round 2 (skeptic F1): `_gate_red_preexisting`
# accepted the candidate's OWN red log as the installed-version control. The
# functions are extracted from the apply script under test and driven directly:
# the full `safe` path needs a changelog and a registry, and the question here
# is the predicate alone.
echo "== I. F1: control gate evidence =="
I_ROOT="$WORK/i"; make_root "$I_ROOT" 2.1.281
I_FNS="$WORK/i-fns.sh"
{
    printf 'NEXUS_ROOT=%q\nPACKAGE=@anthropic-ai/claude-code\nGATE_EVIDENCE_MAX_AGE=21600\n' "$I_ROOT"
    printf 'note() { printf "%%s\\n" "$*" >&2; }\n'
    printf '. %q\n' "$MONITOR_DIR/_cc-version.sh"
    for fn in _gate_log_tree_field _gate_log_red_set _gate_log_versions _gate_log_fail_sigs _gate_red_preexisting; do
        awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$APPLY"
    done
} > "$I_FNS"
check "fixture: all five F1 functions were extracted from the apply script" \
    '[[ "$(grep -cE "^_gate_(log_tree_field|log_red_set|log_versions|log_fail_sigs|red_preexisting)\(\) \{" "$I_FNS")" == 5 ]]'
# i_log <file> <version> <prose> — a gate log that RAN <version>: tree stamp,
# per-scenario blocks read from stdin as `scenario|FAIL label` lines (a label
# of `-` means the scenario is red with no FAIL line), and the tally.
i_log() {
    local f="$1" v="$2" prose="$3" sc lab reds=""
    {
        printf '=== gating candidate ===\n    binary:  /x/claude\n    version: %s (Claude Code)\n' "$v"
        printf '%s\n' "$prose"
        printf '=== gated-tree: head=%s ref=dev dirty=0 dirty_tracked=0 untracked=0 dirty_digest=none subject_path=monitor/pane-state.sh subject_blob=%s ===\n' "$H1" "$H2"
        while IFS='|' read -r sc lab; do
            [[ -n "$sc" ]] || continue
            printf -- '--- %s.sh ---\n' "$sc"
            [[ "$lab" == - ]] || printf '  FAIL: %s — got x want y\n' "$lab"
            case " $reds " in *" $sc.sh "*) ;; *) reds="$reds $sc.sh" ;; esac
        done
        printf '=== tally: 3 passed / 1 failed / 0 skipped (of 4) ===\n    failed: %s\n=== GATE RED (3 passed / 1 failed / 0 skipped) ===\n' "$reds"
    } > "$f"
}
i_run() {  # candidate-log control-log candidate → echoes "rc=<n> pre=<set>"
    bash -c ". '$I_FNS'; _gate_red_preexisting '$1' '$2' '$3'; echo \"rc=\$? pre=\$GATE_RED_PREEXISTING\"" 2>/dev/null
}
CAND="$WORK/i-cand.log"; CTL="$WORK/i-ctl.log"
printf 'test-realmodel-idle-busy|busy pane reads state=busy within #s\n' | i_log "$CAND" 2.1.283 "a class added in 2.1.281 renders here"
out=$(i_run "$CAND" "$CAND" 2.1.283)
check "F1 REPRODUCTION: the candidate's own RED log as its control is REFUSED (was: accepted, 'class added in 2.1.281' satisfied a substring match)" '[[ "$out" == rc=1* ]]'
cp "$CAND" "$WORK/i-copy.log"
out=$(i_run "$CAND" "$WORK/i-copy.log" 2.1.283)
check "F1: a byte-identical COPY of the candidate log is refused as its control" '[[ "$out" == rc=1* ]]'
printf 'test-realmodel-idle-busy|busy pane reads state=busy within #s\n' | i_log "$CTL" 2.1.281 ""
out=$(i_run "$CAND" "$CTL" 2.1.283)
check "F1 control: a real installed-version run, same tree, same failing assertion → pre-existing (accepted)" '[[ "$out" == "rc=0 pre=test-realmodel-idle-busy" ]]'
printf 'test-realmodel-idle-busy|busy pane reads state=busy within 30s (41 polls)\n' | i_log "$CAND" 2.1.283 ""
printf 'test-realmodel-idle-busy|busy pane reads state=busy within 30s (38 polls)\n' | i_log "$CTL" 2.1.281 ""
out=$(i_run "$CAND" "$CTL" 2.1.283)
check "F1: the same assertion with different poll counts is the SAME failure (digits folded)" '[[ "$out" == rc=0* ]]'
printf 'test-realmodel-idle-busy|busy pane reads state=busy\ntest-realmodel-idle-busy|the chevron is painted\n' | i_log "$CAND" 2.1.283 ""
printf 'test-realmodel-idle-busy|busy pane reads state=busy\n' | i_log "$CTL" 2.1.281 ""
out=$(i_run "$CAND" "$CTL" 2.1.283)
check "F1: a NEW failing assertion inside an already-red scenario HOLDS (refused, not pre-existing)" '[[ "$out" == rc=1* ]]'
printf 'test-realmodel-idle-busy|busy pane reads state=busy\ntest-realmodel-autosuggest|ghost text is faint\n' | i_log "$CAND" 2.1.283 ""
out=$(i_run "$CAND" "$CTL" 2.1.283)
check "F1: a red scenario the installed version PASSES is candidate-attributed (refused)" '[[ "$out" == rc=1* ]]'
printf 'test-realmodel-idle-busy|-\n' | i_log "$CAND" 2.1.283 ""
out=$(i_run "$CAND" "$CTL" 2.1.283)
check "F1: an rc-only red on the candidate against assertion-level reds on the control is not the same failure (refused)" '[[ "$out" == rc=1* ]]'
printf 'test-realmodel-idle-busy|busy pane reads state=busy\n' | i_log "$CAND" 2.1.283 ""
{ cat "$CTL"; printf '    version: 2.1.283 (Claude Code)\n'; } > "$WORK/i-mixed.log"
out=$(i_run "$CAND" "$WORK/i-mixed.log" 2.1.283)
check "F1: a control whose version stamps include the CANDIDATE is refused" '[[ "$out" == rc=1* ]]'

# ===== J. F2 — the documented COMPAT hold, executed as written ===============
echo "== J. F2: the prompt's block examples, run literally =="
PROMPT="$MONITOR_DIR/cc-auto-update-prompt.md"
# j_extract <literal-line-suffix> — the command whose FIRST line ends with the
# given literal text, running while lines end in a backslash, from the prompt
# AS SHIPPED. A literal suffix (not a regex) so the two examples cannot be
# confused and no escaping can quietly widen the match.
# The suffix goes in through ENVIRON, never `-v`: a -v value is escape-
# processed, and gawk 5.2 (Ubuntu 24.04, the CI runner) DROPS the trailing
# backslash both suffixes end in, so nothing matched and the extract was
# empty, while gawk 4.1 and mawk keep it (#1703).
j_extract() {
    J_SFX="$1" awk '
        BEGIN { sfx = ENVIRON["J_SFX"] }
        !p && length($0) >= length(sfx) && substr($0, length($0) - length(sfx) + 1) == sfx { p = 1 }
        p { print; if (substr($0, length($0)) != "\\") exit }' "$PROMPT"
}
# j_fill — the template's placeholders, filled the way an evaluator fills them.
j_fill() {
    sed -e "s|{{NEXUS_ROOT}}/monitor/cc-auto-update-apply.sh|bash $APPLY|" \
        -e 's|{{CANDIDATE}}|2.1.283|g' \
        -e 's|<failing-scenario>|test-realmodel-paste-held|g' -e 's|<scenario>|test-realmodel-paste-held|g' \
        -e 's|<issue-url>|https://github.com/your-org/nexus-code/issues/1591|g' \
        -e "s|<installed version>: <the same check passed>|2.1.280: the paste is sent on the first Enter|g" \
        -e "s|<installed>: passed|2.1.280: passed|g" -e 's|<one-line reason>|paste held|g'
}
for ex in COMPAT BLOCK; do
    case "$ex" in
        COMPAT) re='cc-auto-update-apply.sh block --candidate {{CANDIDATE}} \' ;;
        BLOCK)  re='cc-auto-update-apply.sh block \' ;;
    esac
    cmd=$(j_extract "$re" | j_fill)
    R="$WORK/j-$ex"; make_root "$R" 2.1.280
    GL="$R/monitor/.state/cc-auto-update/gate-2.1.283.log"
    printf 'gating 2.1.283\n=== gated-tree: head=%s ref=dev dirty=0 dirty_tracked=0 untracked=0 dirty_digest=none subject_path=monitor/pane-state.sh subject_blob=%s ===\n    failed:  test-realmodel-paste-held.sh\n=== GATE RED ===\n' "$H1" "$H2" > "$GL"
    check "F2 fixture: the prompt's $ex example was extracted (>= 4 lines, ends at --reason)" \
        '[[ $(wc -l <<<"$cmd") -ge 4 && "$(tail -n1 <<<"$cmd")" == *"--reason"* ]]'
    rc=0; ( cd "$R" && NEXUS_ROOT="$R" NEXUS_STATE_DIR="$R/monitor/.state" CC_AUTO_CLAUDE_BIN="$R/node_modules/.bin/claude" \
        CC_AUTO_MINT_CMD=/nonexistent/mint CC_AUTO_GATE_ISSUE_CMD=true bash -c "$cmd" >"$R/j.out" 2>&1 ) || rc=$?
    check "F2: the prompt's $ex example, executed literally, records a COMPLETE COMPAT hold (rc 0, issue+control present)" \
        '(( rc == 0 )) && grep -q "^detail=class=compat evidence=gate:test-realmodel-paste-held issue=https://github.com/your-org/nexus-code/issues/1591 control=2.1.280" "$R/monitor/.state/cc-auto-update/last-eval"'
done
# The first cut's shape: a `# comment` inside the command ate the continuation,
# so block saw only --candidate and --evidence. That must still HOLD.
R="$WORK/j-copied"; make_root "$R" 2.1.280
FIND="$R/findings.md"; printf 'paste held on the first Enter on 2.1.283\n' > "$FIND"
rc=0; out=$(NEXUS_ROOT="$R" NEXUS_STATE_DIR="$R/monitor/.state" CC_AUTO_CLAUDE_BIN="$R/node_modules/.bin/claude" \
    CC_AUTO_MINT_CMD=/nonexistent/mint CC_AUTO_GATE_ISSUE_CMD=true bash "$APPLY" block --candidate 2.1.283 \
    --reason "paste held" --evidence "probe:$FIND" 2>&1) || rc=$?
check "F2: a probe-found block that LOST --issue/--control still HOLDS (rc 12, decision=block, contract=incomplete)" \
    '(( rc == 12 )) && grep -qx "decision=block" "$R/monitor/.state/cc-auto-update/last-eval" && grep -q "contract=incomplete" "$R/monitor/.state/cc-auto-update/last-eval"'
check "  … its note never advises safe, and a defect is filed" \
    '! grep -q "run \`safe\` now" <<<"$out" && grep -q "do NOT run \`safe\`" <<<"$out" && grep -q "block-contract-incomplete-2.1.283" "$R/monitor/.state/cc-auto-update/decisions.tsv"'
rc=0; NEXUS_ROOT="$R" NEXUS_STATE_DIR="$R/monitor/.state" CC_AUTO_CLAUDE_BIN="$R/node_modules/.bin/claude" \
    bash "$APPLY" safe --candidate 2.1.283 >"$R/safe.out" 2>&1 || rc=$?
check "F2: \`safe\` right after a hold of the same candidate is REFUSED (rc 13), pin untouched" \
    '(( rc == 13 )) && [[ ! -f "$R/monitor/.state/cc-version-local" ]] && grep -q $'"'"'\tsafe-refused-held\t'"'"' "$R/monitor/.state/cc-auto-update/decisions.tsv"'
R="$WORK/j-malformed"; make_root "$R" 2.1.280
rc=0; run_apply "$R" block --candidate 2.1.283 --reason x --evidence "gate RED 6/7" --issue o/r#1 --control "c" || rc=$?
check "F2: MALFORMED evidence with issue+control HOLDS (rc 12, contract=incomplete), never block-not-compat" \
    '(( rc == 12 )) && grep -qx "decision=block" "$R/monitor/.state/cc-auto-update/last-eval"'
R="$WORK/j-none"; make_root "$R" 2.1.280
rc=0; out=$(NEXUS_ROOT="$R" NEXUS_STATE_DIR="$R/monitor/.state" CC_AUTO_CLAUDE_BIN="$R/node_modules/.bin/claude" \
    CC_AUTO_MINT_CMD=/nonexistent/mint CC_AUTO_GATE_ISSUE_CMD=true bash "$APPLY" block --candidate 2.1.283 --reason "gate refused: pre-flight" 2>&1) || rc=$?
check "F2 control: a block with NO evidence field stays block-not-compat (rc 12, no hold), and still never says 'run safe now'" \
    '(( rc == 12 )) && grep -qx "decision=block-not-compat" "$R/monitor/.state/cc-auto-update/last-eval" && ! grep -q "run \`safe\` now" <<<"$out"'

# ===== K. F3 — the executed set is DERIVED, default inside ===================
echo "== K. F3: ratchet routing in a planted tree =="
# A fake root: the real gate.sh, the real libraries it sources, and a STUB
# tmux lint whose manifest check fails and whose --pragma-files lists the
# plants below. Every plant sits at a path the real predicate classifies.
KF="$WORK/k-root"
mkdir -p "$KF/monitor/cc-harness" "$KF/monitor/watcher/test-integration" "$KF/monitor/hooks"
cp "$MONITOR_DIR/cc-harness/gate.sh" "$KF/monitor/cc-harness/gate.sh"
cp "$MONITOR_DIR/_node-bootstrap.sh" "$MONITOR_DIR/_trash.sh" "$MONITOR_DIR/_cc-hold-policy.sh" "$KF/monitor/"
printf '#!/usr/bin/env bash\necho "  PASS: stub mass-kill"\nexit 0\n' > "$KF/monitor/cc-harness/lint-no-mass-kill.sh"
cat > "$KF/monitor/cc-harness/lint-no-tmux-server-kill.sh" <<'LINT'
#!/usr/bin/env bash
case "${1:-}" in
    --selftest) echo "  PASS: stub detector"; exit 0 ;;
    --manifest-check) echo "  FAIL: pragma count moved (stub)"; exit 1 ;;
    --pragma-files) cat "$(dirname "$0")/../../pragmas.tsv"; exit 0 ;;
esac
exit 0
LINT
chmod +x "$KF/monitor/cc-harness/"*.sh
: > "$KF/monitor/cc-harness/_lib.sh"; : > "$KF/monitor/watcher/test-integration/_harness.sh"
k_run() {  # pragma rows (path-relative-to-root<TAB>kill<TAB>shimw) on stdin → gate output
    local rel k w
    : > "$KF/pragmas.tsv"
    while IFS=$'\t' read -r rel k w; do
        [[ -n "$rel" ]] && printf '%s\t%s\t%s\n' "$KF/$rel" "$k" "$w" >> "$KF/pragmas.tsv"
    done
    CCH_GATE_SCENARIOS="$S_PASS" timeout 120 bash "$KF/monitor/cc-harness/gate.sh" --claude-bin "$(command -v bash)" 2>&1
}
K_BASE=$'monitor/cc-harness/_lib.sh\t1\t0\nmonitor/watcher/test-integration/_harness.sh\t1\t0'
: > "$KF/monitor/watcher/test-integration/test-zz-codex.sh"
out=$(printf '%s\nmonitor/watcher/test-integration/test-zz-codex.sh\t1\t1\n' "$K_BASE" | k_run)
check "F3: a pragma in a suite no non-suite names → HYGIENE, the scenarios run" \
    'grep -q "gate-hygiene: FAIL" <<<"$out" && grep -q "=== tally:" <<<"$out"'
printf '#!/usr/bin/env bash\n# kill-server  # tmux-socket-scoped: pane-state plant\n' > "$KF/monitor/pane-state.sh"
out=$(printf '%s\nmonitor/pane-state.sh\t1\t0\n' "$K_BASE" | k_run); rc=$?
check "F3: a pragma planted in pane-state.sh (a non-suite the gate runs) REFUSES — the first cut called it outside" \
    'grep -q "CHANGED INSIDE" <<<"$out" && ! grep -q "=== tally:" <<<"$out"'
printf '#!/usr/bin/env bash\nbash "$d/test-zz-codex.sh"\n' > "$KF/monitor/spawn-worker.sh"
out=$(printf '%s\nmonitor/watcher/test-integration/test-zz-codex.sh\t1\t0\n' "$K_BASE" | k_run)
check "F3: a suite that spawn-worker.sh NAMES on a code line is INSIDE (refused)" 'grep -q "CHANGED INSIDE" <<<"$out"'
printf '#!/usr/bin/env bash\n# see test-zz-codex.sh for the shape\n' > "$KF/monitor/spawn-worker.sh"
out=$(printf '%s\nmonitor/watcher/test-integration/test-zz-codex.sh\t1\t0\n' "$K_BASE" | k_run)
check "F3: a suite named only in a COMMENT of a non-suite stays outside (hygiene)" 'grep -q "gate-hygiene: FAIL" <<<"$out"'
out=$(printf '%s\nmonitor/ng\t0\t1\n' "$K_BASE" | k_run)
check "F3: a SHIM-WRITER pragma in a non-suite (ng) is counted and REFUSES" 'grep -q "CHANGED INSIDE" <<<"$out"'
printf '#!/usr/bin/env bash\nfor t in "$d"/test-*.sh; do bash "$t"; done\n' > "$KF/monitor/cc-harness/runall.sh"
out=$(printf '%s\nmonitor/watcher/test-integration/test-zz-codex.sh\t1\t0\n' "$K_BASE" | k_run)
check "F3: when a harness file GLOBS test-*, even an unnamed suite is inside (refused)" 'grep -q "CHANGED INSIDE" <<<"$out"'
rm -f "$KF/monitor/cc-harness/runall.sh"

# ===== L. F5 — floor proposals supersede only LOWER, never re-open, resume ===
echo "== L. F5: cc-floor propose =="
L_ROOT="$WORK/l"; make_root "$L_ROOT" 2.1.173
printf '2.1.283\n' > "$L_ROOT/monitor/.state/cc-version-local"
printf '2026-09-27T12:21:40-07:00\t2.1.283\tsafe-bumped-restart-handoff\tdetached\n' > "$L_ROOT/monitor/.state/cc-auto-update/decisions.tsv"
LS="$WORK/l-stub"; mkdir -p "$LS"
printf '#!/usr/bin/env bash\necho tok\n' > "$LS/mint"; chmod +x "$LS/mint"
# The gh stub: answers from files in $LS, logs every call.
cat > "$LS/gh" <<'GH'
#!/usr/bin/env bash
d="$(dirname "$0")"; printf '%s\n' "$*" >> "$d/calls.log"
pj() { printf '{"sha":"%s","content":"%s"}\n' "$1" "$(printf '{ "dependencies": { "@anthropic-ai/claude-code": "%s" } }\n' "$2" | base64 -w0)"; }
args="$*"
case "$args" in
    *"git/ref/heads/dev"*)            echo 1111111111111111111111111111111111111111 ;;
    *"contents/package.json?ref=dev"*) pj baseblob 2.1.173 ;;
    *"contents/package.json?ref=cc-floor/"*) pj branchblob "$(cat "$d/branch-floor")" ;;
    # GitHub's listing semantics, emulated (#1657 follow-up): pulls.tsv is
    # every PR, NEWEST FIRST; a `head=` query returns that branch's PRs in any
    # state; `state=open` the open ones; a windowed `state=all` list only the
    # 100 newest. Each then passes through the caller's jq filter (floor refs).
    *"pulls?state=all&head="*)        h="${args#*head=}"; h="${h%%&*}"; h="${h#*:}"
                                      awk -F'\t' -v r="$h" '$2 == r' "$d/pulls.tsv" ;;
    *"pulls?state=open"*)             awk -F'\t' '$3 == "open" && ++n <= 100 && $2 ~ /^cc-floor\//' "$d/pulls.tsv" ;;
    *"pulls?state=all"*)              awk -F'\t' 'NR <= 100 && $2 ~ /^cc-floor\//' "$d/pulls.tsv" ;;
    *"git/ref/heads/cc-floor/"*)      [[ -f "$d/branch-floor" ]] ;;
    *"-X POST repos/"*"/git/refs"*)   echo '{}' ;;
    *"-X PUT repos/"*"/contents/package.json"*) echo '{}' ;;
    *"-X POST repos/"*"/pulls "*|*"-X POST repos/"*"/pulls") echo "https://github.com/o/r/pull/900" ;;
    *) echo '{}' ;;
esac
GH
chmod +x "$LS/gh"
l_run() {
    : > "$LS/calls.log"
    NEXUS_ROOT="$L_ROOT" NEXUS_STATE_DIR="$L_ROOT/monitor/.state" CC_FLOOR_GH="$LS/gh" CC_FLOOR_MINT="$LS/mint" \
    CC_FLOOR_CLAUDE_BIN="$L_ROOT/node_modules/.bin/claude" CC_FLOOR_BASE=dev CC_FLOOR_REPO=o/r MONITOR_CC_FLOOR_PROPOSE=true \
        bash "$MONITOR_DIR/cc-floor.sh" propose "$@" 2>&1
}
l_prs() { printf '%s\n' "$@" > "$LS/pulls.tsv"; }   # rows: n<TAB>ref<TAB>state<TAB>merged_at|-<TAB>url (the real jq emits `-` for null)
rm -f "$LS/branch-floor"
l_prs $'701\tcc-floor/2.1.280\topen\t-\thttps://github.com/o/r/pull/701'
out=$(l_run); rc=$?
check "F5: with a LOWER open proposal: ours is opened and the LOWER one is closed" \
    '(( rc == 0 )) && grep -q "X POST repos/o/r/pulls" "$LS/calls.log" && grep -q "X PATCH repos/o/r/pulls/701" "$LS/calls.log"'
l_prs $'702\tcc-floor/2.1.290\topen\t-\thttps://github.com/o/r/pull/702' $'701\tcc-floor/2.1.280\topen\t-\thttps://github.com/o/r/pull/701'
out=$(l_run); rc=$?
check "F5: with a HIGHER open proposal: stand down (rc 3), open nothing, CLOSE NOTHING (the higher one never)" \
    '(( rc == 3 )) && ! grep -q "X POST repos/o/r/pulls" "$LS/calls.log" && ! grep -q "X PATCH" "$LS/calls.log"'
l_prs $'900\tcc-floor/2.1.283\topen\t-\thttps://github.com/o/r/pull/900' $'701\tcc-floor/2.1.280\topen\t-\thttps://github.com/o/r/pull/701'
out=$(l_run); rc=$?
check "F5 IDEMPOTENT: our version already open → rc 0, no second PR, the lower one superseded" \
    '(( rc == 0 )) && ! grep -q "X POST repos/o/r/pulls " "$LS/calls.log" && ! grep -qE "X POST repos/o/r/pulls$" "$LS/calls.log" && grep -q "X PATCH repos/o/r/pulls/701" "$LS/calls.log" && ! grep -q "X PATCH repos/o/r/pulls/900" "$LS/calls.log"'
l_prs $'899\tcc-floor/2.1.283\tclosed\t-\thttps://github.com/o/r/pull/899'
out=$(l_run); rc=$?
check "F5: a floor PR for this version that a human CLOSED unmerged is never re-opened (rc 3, no PR, no branch write)" \
    '(( rc == 3 )) && ! grep -q "X POST" "$LS/calls.log" && ! grep -q "X PUT" "$LS/calls.log"'
l_prs $'898\tcc-floor/2.1.283\tclosed\t2026-09-27T20:00:00Z\thttps://github.com/o/r/pull/898'
printf '2.1.283\n' > "$LS/branch-floor"
out=$(l_run); rc=$?
check "F5 RESUME: branch already carries the new floor (a run cut off before the PR) → no PUT, the PR is opened" \
    '(( rc == 0 )) && ! grep -q "X PUT" "$LS/calls.log" && grep -q "X POST repos/o/r/pulls" "$LS/calls.log"'
l_prs ''
printf '2.1.173\n' > "$LS/branch-floor"
out=$(l_run); rc=$?
check "F5 RESUME: branch exists with the OLD floor → the PUT carries the BRANCH blob sha, not the base's (no 409)" \
    '(( rc == 0 )) && grep -q "X PUT.*sha=branchblob" "$LS/calls.log" && ! grep -q "sha=baseblob" "$LS/calls.log"'
rm -f "$LS/branch-floor"

# (#1657 follow-up) MORE THAN 100 NEWER PRs: the declined floor PR for this
# version is older than the 100 most recent, so a windowed list cannot see it.
{ for i in $(seq 1 150); do printf '%s\tfeature/x%s\tclosed\t2026-09-27T10:00:00Z\thttps://github.com/o/r/pull/%s\n' $((2000 - i)) "$i" $((2000 - i)); done
  printf '899\tcc-floor/2.1.283\tclosed\t-\thttps://github.com/o/r/pull/899\n'; } > "$LS/pulls.tsv"
out=$(l_run); rc=$?
check "F5 follow-up: with >100 NEWER unrelated PRs, a declined floor PR for this version is still found (by head branch) and NOT re-opened" \
    '(( rc == 3 )) && grep -q "CLOSED unmerged" <<<"$out" && ! grep -q "X POST" "$LS/calls.log" && ! grep -q "X PUT" "$LS/calls.log"'
check "F5 follow-up: the lookup is BY HEAD (head=o:cc-floor/2.1.283, any state) plus the OPEN list — never the windowed state=all list" \
    'grep -q "pulls?state=all&head=o:cc-floor/2.1.283" "$LS/calls.log" && grep -q "pulls?state=open&base=dev" "$LS/calls.log" && ! grep -qE "pulls[?]state=all&base=" "$LS/calls.log"'

# ===== M. the dirty digest ignores diff drivers (#1657 follow-up) ============
echo "== M. cc_tree_dirty_digest vs a user diff driver =="
MR="$WORK/m-repo"; mkdir -p "$MR"
git -C "$MR" init -q && th_require_fixture_repo "$MR"
printf 'alpha\n' > "$MR/a.txt"
git -C "$MR" add a.txt && git -C "$MR" -c user.email=t@t -c user.name=t commit -qm init
# A textconv filter and an external diff driver that both erase content: every
# edit renders identically through them.
printf '*.txt diff=blind\n' > "$MR/.gitattributes"
git -C "$MR" config diff.blind.textconv "sed s/.*/SAME/"
printf '#!/bin/sh\necho SAME\n' > "$WORK/m-extdiff"; chmod +x "$WORK/m-extdiff"
git -C "$MR" config diff.external "$WORK/m-extdiff"
check "M control: the configured driver really does erase the difference (plain git diff renders two edits identically)" \
    '[[ "$(printf "beta\n" > "$MR/a.txt"; git -C "$MR" diff HEAD -- a.txt)" == "$(printf "gamma\n" > "$MR/a.txt"; git -C "$MR" diff HEAD -- a.txt)" ]]'
printf 'beta\n' > "$MR/a.txt";  dg1=$(cc_tree_dirty_digest "$MR")
printf 'gamma\n' > "$MR/a.txt"; dg2=$(cc_tree_dirty_digest "$MR")
check "M: two different tracked edits give DIFFERENT digests despite a user diff driver / textconv (--no-ext-diff --no-textconv)" \
    '[[ "$dg1" =~ ^[0-9a-f]{40}$ && "$dg2" =~ ^[0-9a-f]{40}$ && "$dg1" != "$dg2" ]]'
printf 'beta\n' > "$MR/a.txt";  dg3=$(cc_tree_dirty_digest "$MR")
check "M: the same edit gives the SAME digest (the digest is a function of the bytes)" '[[ "$dg1" == "$dg3" ]]'


# ===== R. REPLAY ============================================================
echo "== R. replay 2026-08-27..09-27 through the new policy =="
FIX="$_script_dir/fixtures/cc-hold-replay-2026-08-27_09-27.tsv"
mkdir -p "$WORK/replay"
# new_outcome <facts> — the NEW policy's outcome for a day, derived through the
# real functions: block rows through cc_hold_block_contract (COMPAT ⇔ contract
# holds), a NOT-COMPAT block that the installed version shares proceeds via
# --control-gate-evidence, Guard 4 through _cc_auto_last_eval_skip on a
# next-day last-eval, deferrals through section H (no arm left).
new_outcome() {
    local facts="$1" kind rest
    kind="${facts%%:*}"; rest="${facts#*:}"
    case "$kind" in
        block)
            # THE REAL VERB, with ONLY the fields the history carries (F4): a
            # fixture root, the evidence materialised (a gate log naming the
            # failed scenario, or the cited findings file), and `apply.sh
            # block` run end to end. Classified by what it RECORDED.
            local ev issue ctl rr grc=0 args=()
            IFS='|' read -r ev issue ctl <<<"$rest"
            rr="$WORK/replay/root-$RANDOM$RANDOM"; make_root "$rr" 2.1.150
            if [[ "$ev" == gate:* ]]; then
                printf 'gating X\n=== gated-tree: head=%s ref=dev dirty=0 dirty_tracked=0 untracked=0 dirty_digest=none subject_path=monitor/pane-state.sh subject_blob=%s ===\n    failed:  %s.sh\n=== GATE RED ===\n' \
                    "$H1" "$H2" "${ev#gate:}" > "$rr/monitor/.state/cc-auto-update/gate-2.1.999.log"
                args+=(--evidence "$ev")
            elif [[ "$ev" == probe:* ]]; then
                printf 'findings (replayed: the historical file %s existed)\n' "${ev#probe:}" > "$rr/${ev#probe:}"
                args+=(--evidence "probe:$rr/${ev#probe:}")
            fi
            [[ "$issue" != - && -n "$issue" ]] && args+=(--issue "$issue")
            [[ "$ctl"   != - && -n "$ctl"   ]] && args+=(--control "$ctl")
            run_apply "$rr" block --candidate 2.1.999 --reason replay "${args[@]}" || grc=$?
            local dec det
            dec=$(sed -n 's/^decision=//p' "$rr/monitor/.state/cc-auto-update/last-eval" 2>/dev/null)
            det=$(sed -n 's/^detail=//p' "$rr/monitor/.state/cc-auto-update/last-eval" 2>/dev/null)
            if   [[ "$dec" == block && "$det" == class=compat\ evidence=* && $grc == 0 ]]; then echo hold
            elif [[ "$dec" == block && "$det" == *contract=incomplete* && $grc == 12 ]]; then echo hold-incomplete
            elif [[ "$dec" == block-not-compat ]]; then echo retry
            else echo "?rc=$grc:$dec"; fi ;;
        control-shared)
            # The evaluator's verdict that day: the installed version fails
            # identically. Driven through the REAL predicate with a control run
            # of the installed version on the same tree, same failing assertion.
            printf 'test-realmodel-trust-dialog|the live dialog names itself\n' | i_log "$WORK/replay/c.log" 2.1.283 ""
            printf 'test-realmodel-trust-dialog|the live dialog names itself\n' | i_log "$WORK/replay/k.log" 2.1.281 ""
            if [[ "$(i_run "$WORK/replay/c.log" "$WORK/replay/k.log" 2.1.283)" == rc=0* ]]; then echo apply; else echo held; fi ;;
        deferred)  echo apply ;;   # section H: no deferring arm remains
        refused)   echo retry ;;
        skipped-after)
            printf 'candidate=X\ndecision=block\ndate=2026-09-01T04:00:00-07:00\ndetail=class=compat live_head=%s\n' "$H1" > "$WORK/replay/last-eval"
            if _cc_auto_last_eval_skip "$WORK/replay" X "$(date -d '2026-09-02 04:05' +%s)" "$H1"; then echo skipped; else echo reeval-hold; fi ;;
        unattributable) echo apply ;;   # section K: hygiene outside the executed set runs the scenarios
        applied)   echo apply ;;
        no-fire)   echo no-fire ;;
        *)         echo "?" ;;
    esac
}
printf '\n  %-10s %-8s %-26s %-12s\n' day cand old new
held_new=""; REPLAY_BAD=0; nhold_old=0; nhold_new=0; napply_old=0; napply_new=0
while IFS=$'\t' read -r day cand old facts expect _src; do
    [[ -z "$day" || "$day" == \#* ]] && continue
    got=$(new_outcome "$facts")
    printf '  %-10s %-8s %-26s %-12s\n' "$day" "$cand" "$old" "$got"
    [[ "$got" == "$expect" ]] || { REPLAY_BAD=$(( REPLAY_BAD + 1 )); printf '    MISMATCH %s %s: new=%s want=%s (%s)\n' "$day" "$cand" "$got" "$expect" "$facts" >&2; }
    [[ "$got" == hold || "$got" == hold-incomplete ]] && held_new="$held_new $cand"
    case "$old" in block|skipped-awaiting-operator|safe-deferred|safe-refused|block-unattributable) nhold_old=$((nhold_old+1));; applied) napply_old=$((napply_old+1));; esac
    case "$got" in hold|hold-incomplete|reeval-hold|retry) nhold_new=$((nhold_new+1));; apply) napply_new=$((napply_new+1));; esac
done < "$FIX"
echo
check "replay: 2.1.250/251/252/278/281 — and ONLY those — still HOLD" \
    '[[ "$(tr " " "\n" <<<"$held_new" | sed "/^$/d" | sort -u | tr "\n" " ")" == "2.1.250 2.1.251 2.1.252 2.1.278 2.1.281 " ]]'
check "replay: every day's new outcome matched its expectation" '(( REPLAY_BAD == 0 ))'
check "replay (F4): exactly ONE hold rests on a complete contract (2.1.278); the other four hold through the fail direction" \
    '[[ "$(awk -F"\t" "\$5==\"hold\"" "$FIX" | wc -l)" == 1 && "$(awk -F"\t" "\$5==\"hold-incomplete\"" "$FIX" | wc -l)" == 4 ]]'
printf '  replay tally: non-apply fire-days old=%d new=%d (of which retry=%s) · apply days old=%d new=%d\n' \
    "$nhold_old" "$nhold_new" "$(awk -F'\t' '$5=="retry"' "$FIX" | wc -l)" "$napply_old" "$napply_new"

# THE ASSERTION TOTAL IS EXACT: an assertion that silently stops running (a
# section that aborted, a loop over an empty set) is a red, not a smaller green.
EXPECTED=124
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: assertion census %d != EXPECTED %d — an assertion did not run, or one was added without updating EXPECTED\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
