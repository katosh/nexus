#!/usr/bin/env bash
# Tests for monitor/retire-preflight.sh — the synchronous pre-kill
# go/no-go gate that closes the 2026-06-15 retire-the-just-re-engaged-
# window race (see the script header).
#
# Run: bash monitor/test-retire-preflight.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# The contract under test:
#   GO   (safe=1, exit 0): the window is genuinely wrapped/quiet — no
#        fresh operator submit, no valid engagement mark, pane idle.
#   NO-GO (safe=0, exit 1): ANY of —
#        (a) the pane shows the operator typing right now (user-typing),
#            or work in flight (busy / working-*), or an overlay
#            (blocked), or pane-state could not be read (unknown);
#        (b) a fresh operator-attributed UserPromptSubmit stamp newer
#            than any machine input — read DIRECTLY off the raw stamp so
#            it counts before the watcher poll attributes it (THE
#            incident fix);
#        (c) a valid operator-engaged mark in operator-engaged.tsv.
#   Exit 2 on bad usage; exit 3 on a window absent from tmux.
#
# pane-state is injected via --pane-state so the suite is hermetic (no
# tmux, no real Claude pane). The state-file checks run against the REAL
# monitor/watcher/_idle_probe.sh helpers the script sources, so the test
# exercises the production attribution + mark-validity logic.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFLIGHT="$_test_dir/retire-preflight.sh"

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
# your-org/nexus-code#845 — this helper DID NOT EXIST, and case 15n called it.
# The call printed `assert_not_contains: command not found` to stderr, exited
# 127, and the suite carried on and reported `ALL TESTS PASSED`. Nothing
# counted it, so the assertion total did not move either: the one check
# guarding against `resolve` announcing "no marker was present" on a real
# clear — the exact lie #813 F5 was filed about — was never run, on dev or on
# the branch that added it. A MISSING assert_* helper PASSES.
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly CONTAINS %q\n  in: <<%s>>\n' "$label" "$needle" "$hay" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

# ---- th_* helpers this suite CALLS but never defined ----------------------
# `th_abort`, `th_skip` and `th_kill_own_child` are called in case 15 and are
# defined NOWHERE — this suite does not source `watcher/_test_helpers.sh`. A
# missing helper is rc 127 counted by nothing, which is the exact #845 shape the
# `assert_*` self-check below exists to end, arriving through the other prefix.
# `th_skip` in particular sits on a live branch (no tmux window list ⇒ no LIVE
# creditor), so that arm could silently contribute ZERO assertions to a green.
# Defined only if absent, so sourcing the real helpers later would still win.
declare -F th_abort >/dev/null 2>&1 || th_abort() {
    printf 'FATAL: %s\n' "$*" >&2; exit 2
}
declare -F th_skip >/dev/null 2>&1 || th_skip() {
    printf '  SKIP: %s — %s\n' "${1:-}" "${2:-}" >&2
}
declare -F th_kill_own_child >/dev/null 2>&1 || th_kill_own_child() {
    [[ -n "${1:-}" ]] || return 1
    kill "$1" 2>/dev/null || return 1
}

# ---- self-check: every assert_* this file CALLS must EXIST ----------------
# The structural fix, not the instance. Adding `assert_not_contains` fixes one
# missing helper; a suite whose failure mode for a typo'd or not-yet-written
# helper is a SILENT PASS will grow another. So the suite audits its own
# source before running: any `assert_…` token at the head of a command that
# is not a defined function aborts, loudly, before a single case runs.
#
# Deliberately a `grep -o` over this file's own text rather than a shell trap
# on rc 127 — a trap fires only for the branches a given run reaches, and the
# helper that is missing is by construction the one on the path nobody
# exercised. Reading the source covers calls that never execute.
_selfcheck_assert_helpers() {
    local bad="" name
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        declare -F "$name" >/dev/null 2>&1 || bad="${bad}${bad:+ }$name"
    done < <(grep -oE '(^|[[:space:];&|(])assert_[A-Za-z0-9_]+' "${BASH_SOURCE[0]}" \
             | grep -oE 'assert_[A-Za-z0-9_]+' | sort -u)
    if [[ -n "$bad" ]]; then
        printf 'FATAL: this suite calls assertion helper(s) that do not exist: %s\n' "$bad" >&2
        printf '  A missing assert_* helper exits 127 and is counted by NOTHING — the suite\n' >&2
        printf '  then reports ALL TESTS PASSED having never run that check (#845).\n' >&2
        exit 2
    fi
}
_selfcheck_assert_helpers

# ---- harness -------------------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change"
# …and PIN it for every `ng` this suite starts (your-org/nexus-code#833). The
# suite already builds its own STATE_DIR and passes it where it remembers to;
# the leak is the calls where it does not. `_resolve_state_dir` prefers the
# INHERITED `$NEXUS_ROOT` over the fixture, so from an agent shell this suite
# appended to the OPERATOR'S canonical `ng-usage.jsonl` — 34 rows, measured on
# the primary, and produced by the very band that was measuring the leak.
# Exported because the property has to hold for calls nobody has written yet.
export NEXUS_STATE_DIR="$STATE_DIR"
# your-org/nexus-code#813 — check 1c scans a reports corpus. Every run gets a
# HERMETIC one: without the override `ng` resolves the corpus by walking up
# from cwd (and through the primary-root correction), so the suite would read
# the operator's live ~1000-report corpus — slow, and a verdict that depends
# on which machine it runs on. Empty by default ⇒ `no-report` ⇒ gate does not
# apply, which is the pre-#813 behaviour for every case that predates it.
REPORTS_DIR="$WORK/reports"
mkdir -p "$REPORTS_DIR"

NOW=$(date +%s)

# Run the preflight; capture stdout + rc into named vars.
run_preflight() {
    local _out_var="$1" _rc_var="$2"; shift 2
    local _out _rc
    _out=$(bash "$PREFLIGHT" "$@" --state-dir "$STATE_DIR" --now "$NOW" \
                --reports-dir "${REPORTS_DIR_OVERRIDE:-$REPORTS_DIR}" 2>/dev/null)
    _rc=$?
    printf -v "$_out_var" '%s' "$_out"
    printf -v "$_rc_var" '%s' "$_rc"
}

# Stamp a raw UserPromptSubmit (what worker-heartbeat.sh writes from the
# UserPromptSubmit hook). `epoch<TAB>session-id`.
stamp_user_prompt() {
    local window="$1" epoch="$2"
    printf '%s\ttest-session\n' "$epoch" > "$STATE_DIR/user-prompt/$window"
}
# Stamp a raw UserPromptSubmit with an EXPLICIT session-id — lets a
# test control whether the submit carries the window's own spawn
# session-id (self-activity) or a different one (operator).
stamp_user_prompt_sid() {
    local window="$1" epoch="$2" sid="$3"
    printf '%s\t%s\n' "$epoch" "$sid" > "$STATE_DIR/user-prompt/$window"
}
# Write the provenance record spawn-worker.sh drops at birth
# (windows/<window>.json), carrying the window's own --session-id.
seed_provenance() {
    local window="$1" sid="$2"
    mkdir -p "$STATE_DIR/windows"
    printf '{"window":"%s","session_id":"%s","kind":"task","spawned_by":"orchestrator"}\n' \
        "$window" "$sid" > "$STATE_DIR/windows/${window//[^a-zA-Z0-9_-]/_}.json"
}
# Stamp a machine input (what paste-followup.sh writes BEFORE pasting).
stamp_machine_input() {
    local window="$1" epoch="$2" src="${3:-paste-followup}"
    printf '%s\t%s\t%s\n' "$window" "$epoch" "$src" >> "$STATE_DIR/machine-input.tsv"
}
# Seed a valid operator-engaged mark: tsv row + a recent pane-change stamp
# (so _openg_marked's self-expiry corroboration holds).
seed_engaged_mark() {
    local window="$1" since="$2" last="$3" change_epoch="$4"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$window" "$since" "$last" "$last" "submit" "0" \
        >> "$STATE_DIR/operator-engaged.tsv"
    printf 'deadbeef\t%s\n' "$change_epoch" > "$STATE_DIR/pane-change/$window"
}
reset_state() {
    rm -rf "$STATE_DIR" "$REPORTS_DIR"
    mkdir -p "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change" "$REPORTS_DIR"
    unset REPORTS_DIR_OVERRIDE
}

OUT=""; RC=""

# ── 1. GO: genuinely wrapped + quiet ──────────────────────────────────────
echo "## 1. wrapped + quiet → GO"
reset_state
run_preflight OUT RC quiet-win --pane-state idle
assert_eq      "exit 0 (go)"        "$RC"  "0"
assert_contains "safe=1"            "$OUT" "safe=1"

# ── 2. NO-GO: operator typing in the box right now ────────────────────────
echo "## 2. pane user-typing → NO-GO"
reset_state
run_preflight OUT RC type-win --pane-state user-typing
assert_eq      "exit 1 (no-go)"     "$RC"  "1"
assert_contains "safe=0"            "$OUT" "safe=0"
assert_contains "reason cites typing" "$OUT" "typing"

# ── 3. NO-GO: THE incident — fresh operator submit, no machine paste ──────
#     Mirrors 2026-06-15: wrap logged, then an operator UserPromptSubmit
#     9 s before the kill, no covering paste-followup. The raw stamp is
#     read directly, so it fires even though no poll attributed it.
echo "## 3. fresh operator submit, no machine input → NO-GO (incident)"
reset_state
stamp_user_prompt incident-win "$(( NOW - 9 ))"
run_preflight OUT RC incident-win --pane-state idle
assert_eq      "exit 1 (no-go)"     "$RC"  "1"
assert_contains "safe=0"            "$OUT" "safe=0"
assert_contains "reason cites fresh submit" "$OUT" "fresh operator submit"

# ── 4. GO: submit covered by a recent machine paste (orchestrator nudge) ──
echo "## 4. submit attributable to machine paste → GO"
reset_state
stamp_user_prompt nudge-win   "$(( NOW - 9 ))"
stamp_machine_input nudge-win "$(( NOW - 10 ))" paste-followup
run_preflight OUT RC nudge-win --pane-state idle
assert_eq      "exit 0 (go)"        "$RC"  "0"
assert_contains "safe=1"            "$OUT" "safe=1"

# ── 5. GO: stale operator submit beyond the freshness window ──────────────
#     A 2 h-old, already-handled submit must not pin the window open.
echo "## 5. stale operator submit (beyond freshness) → GO"
reset_state
stamp_user_prompt stale-win "$(( NOW - 7200 ))"
run_preflight OUT RC stale-win --pane-state idle
assert_eq      "exit 0 (go)"        "$RC"  "0"
assert_contains "safe=1"            "$OUT" "safe=1"

# ── 5b. NO-GO: same stale submit but a wider freshness window covers it ───
echo "## 5b. stale submit + --fresh-seconds widened → NO-GO"
reset_state
stamp_user_prompt stale-win "$(( NOW - 7200 ))"
OUT=$(bash "$PREFLIGHT" stale-win --state-dir "$STATE_DIR" --now "$NOW" \
        --reports-dir "$REPORTS_DIR" \
        --pane-state idle --fresh-seconds 99999 2>/dev/null); RC=$?
assert_eq      "exit 1 (no-go)"     "$RC"  "1"
assert_contains "safe=0"            "$OUT" "safe=0"

# ── 6. NO-GO: a valid operator-engaged mark (poll already attributed) ─────
echo "## 6. valid operator-engaged mark → NO-GO"
reset_state
seed_engaged_mark engaged-win "$(( NOW - 300 ))" "$(( NOW - 120 ))" "$(( NOW - 30 ))"
run_preflight OUT RC engaged-win --pane-state idle
assert_eq      "exit 1 (no-go)"     "$RC"  "1"
assert_contains "safe=0"            "$OUT" "safe=0"
assert_contains "reason cites engaged mark" "$OUT" "operator-engaged mark"

# ── 6b. GO: engaged row present but mark self-expired (pane static) ───────
#     change stamp older than the change-TTL (600 s) → mark lapsed →
#     the window is retire-eligible again.
echo "## 6b. engaged row but mark self-expired → GO"
reset_state
seed_engaged_mark expired-win "$(( NOW - 5000 ))" "$(( NOW - 4000 ))" "$(( NOW - 3000 ))"
run_preflight OUT RC expired-win --pane-state idle
assert_eq      "exit 0 (go)"        "$RC"  "0"
assert_contains "safe=1"            "$OUT" "safe=1"

# ── 7. NO-GO: active, suspended, or unverifiable pane states ──────────────
#
# `empty` and `over-limit` MOVED here from case 8 (your-org/nexus-code
# #603). Case 8 used to assert `exit 0 for pane=empty` — i.e. the suite
# PINNED the defect: a green run proved the gate would kill a window on
# the reading pane-state.sh's own header documents as "don't know yet,
# try again next cycle". A pane 4m38s into a verification pass with a
# `git fetch` running and a message queued behind it read `empty`.
#
# `over-limit` was never safe either — skills/nexus.window-cleanup has
# said "Do NOT close" for it since #87 — but it fell through the same
# permissive `*)` arm.
echo "## 7. active / suspended / unverifiable pane states → NO-GO"
reset_state
for st in busy working-background working-self-paced blocked unknown \
          empty over-limit queued; do
    run_preflight OUT RC act-win --pane-state "$st"
    assert_eq      "exit 1 for pane=$st" "$RC" "1"
    assert_contains "safe=0 for pane=$st" "$OUT" "safe=0"
done

# The gate is an ALLOWLIST with a default-DENY arm, so a state nobody
# has enumerated — including one a future pane-state.sh adds — must
# refuse. Under the old denylist shape this input was PERMITTED, which
# is why fixing `empty` alone would not have closed the class.
reset_state
run_preflight OUT RC act-win --pane-state a-state-invented-later
assert_eq      "exit 1 for an UNKNOWN pane state (default-deny)" "$RC" "1"
assert_contains "safe=0 for an unknown pane state"               "$OUT" "safe=0"

# ── 8. GO: pane states that POSITIVELY assert the window is finished ──────
#
# The membership rule: a state qualifies iff it asserts, positively,
# that no turn is in flight and no operator input is pending. This
# control matters as much as case 7 — a gate that refused everything
# would pass every assertion above while making retirement impossible.
echo "## 8. definitely-finished pane states → GO"
reset_state
for st in idle autosuggest-only absent idle-orphan-async; do
    run_preflight OUT RC idle-win --pane-state "$st"
    assert_eq      "exit 0 for pane=$st" "$RC" "0"
    assert_contains "safe=1 for pane=$st" "$OUT" "safe=1"
done

# ── 9. usage / arg handling ───────────────────────────────────────────────
echo "## 9. bad usage → exit 2"
bash "$PREFLIGHT" --state-dir "$STATE_DIR" >/dev/null 2>&1; RC=$?
assert_eq "no window arg → exit 2" "$RC" "2"

# ── 9b. NO-GO: a live required-skeptic pending marker (F2 enforcement) ────
#     skills/nexus.skeptic writes $STATE_DIR/skeptic/pending/<window> when
#     a wrap-up requires an independent skeptic pass. While it persists,
#     the task is NOT done → the kill must be refused even on an otherwise
#     idle, operator-quiet pane. This is what makes `require` a hard gate.
echo "## 9b. live skeptic-pending marker → NO-GO"
reset_state
mkdir -p "$STATE_DIR/skeptic/pending"
echo 1 > "$STATE_DIR/skeptic/pending/pending-skeptic-win"
run_preflight OUT RC pending-skeptic-win --pane-state idle
assert_eq      "exit 1 (no-go)"     "$RC"  "1"
assert_contains "safe=0"            "$OUT" "safe=0"
assert_contains "reason cites the live marker" "$OUT" "required skeptic marker is LIVE"
# your-org/nexus-code#1156 — and it now says WHICH kind of missing this is.
# The old wording asserted "required skeptic has not returned a verdict"
# UNCONDITIONALLY, and that claim was FALSE in all four windows the cluster was
# filed for: the marker is a bit about the MARKER, never about the ledger. This
# window armed nothing, so `none` is the honest answer here. The four
# delivered-but-unmatched classes are exercised in
# monitor/watcher/test-skeptic-verdict-evidence.sh.
assert_contains "…and classifies the absence as a GENUINELY absent verdict" \
    "$OUT" "evidence=none"
# Once the skeptic returns a verdict (marker cleared) the same window is
# retire-eligible again.
rm -f "$STATE_DIR/skeptic/pending/pending-skeptic-win"
run_preflight OUT RC pending-skeptic-win --pane-state idle
assert_eq      "marker cleared -> exit 0 (go)" "$RC"  "0"
assert_contains "marker cleared -> safe=1"     "$OUT" "safe=1"

# ── 10. machine-attributed submit within slack (clock-skew absorption) ────
echo "## 10. submit within attribution slack of machine input → GO"
reset_state
# machine paste 100 s OLDER than the submit, still inside the 120 s slack.
stamp_user_prompt skew-win   "$(( NOW - 9 ))"
stamp_machine_input skew-win "$(( NOW - 109 ))" paste-followup
run_preflight OUT RC skew-win --pane-state idle
assert_eq      "exit 0 (go)"        "$RC"  "0"
assert_contains "safe=1"            "$OUT" "safe=1"

# ── 11. skeptic-channel answer is machine/protocol input, NOT operator ────
#     Bug 1: a worker answering a skeptic question (skeptic-channel.sh
#     stamps machine-input src `skeptic-answer`/`skeptic-await-ack`) must
#     NOT be misread as a fresh operator submit. The submit around the
#     answer is covered by the channel stamp → GO. This is the recurring
#     false `operator-engaged` blocker the fix removes.
echo "## 11. submit covered by a skeptic-channel answer stamp → GO"
reset_state
stamp_user_prompt chan-win   "$(( NOW - 9 ))"
stamp_machine_input chan-win "$(( NOW - 10 ))" skeptic-answer
run_preflight OUT RC chan-win --pane-state idle
assert_eq      "exit 0 (go)"        "$RC"  "0"
assert_contains "safe=1"            "$OUT" "safe=1"
# Same for the await-ack stamp.
reset_state
stamp_user_prompt ack-win   "$(( NOW - 9 ))"
stamp_machine_input ack-win "$(( NOW - 10 ))" skeptic-await-ack
run_preflight OUT RC ack-win --pane-state idle
assert_eq      "ack stamp -> exit 0 (go)" "$RC"  "0"
assert_contains "ack stamp -> safe=1"     "$OUT" "safe=1"

# ── 11b. NO false NEGATIVE: a REAL operator submit during a skeptic ───────
#     exchange (no channel stamp covering THIS submit) STILL registers as
#     engaged. The skeptic mandate: never retire a window the operator is
#     driving. A stale channel stamp (200 s old, beyond the 120 s slack)
#     does NOT explain a fresh operator submit.
echo "## 11b. fresh operator submit beyond a stale channel stamp → NO-GO"
reset_state
stamp_user_prompt opdrive-win   "$(( NOW - 9 ))"
stamp_machine_input opdrive-win "$(( NOW - 200 ))" skeptic-answer
run_preflight OUT RC opdrive-win --pane-state idle
assert_eq      "exit 1 (no-go)"     "$RC"  "1"
assert_contains "safe=0"            "$OUT" "safe=0"
assert_contains "reason cites fresh submit" "$OUT" "fresh operator submit"

# ── 12. GO: self-activity submit — session-id == own spawn session-id ─────
#     The coembed-283-followup false positive (2026-07-17). A fresh
#     user-prompt with NO covering machine input used to read as a fresh
#     operator submit → safe=0, pinning a wrapped window open. But when
#     the submit carries the window's OWN spawn session-id it is provably
#     the worker's pane self-activity (autosuggest / post-wrap typing /
#     its own tool loop), never the operator (who drives a DIFFERENT
#     session and never types into a worker pane) → must GO.
echo "## 12. self-activity submit (session-id == own) → GO"
reset_state
seed_provenance         self-win "sess-self-abc"
stamp_user_prompt_sid   self-win "$(( NOW - 9 ))" "sess-self-abc"
run_preflight OUT RC    self-win --pane-state idle
assert_eq      "self submit -> exit 0 (go)" "$RC"  "0"
assert_contains "self submit -> safe=1"     "$OUT" "safe=1"

# ── 13. NO-GO: submit with a DIFFERENT session-id → conservative block ────
#     A stamp whose session-id differs from the window's own spawn
#     session-id (e.g. the worker's session was replaced by a resume /
#     compaction, so its CURRENT session-id no longer matches provenance)
#     is NOT provably self-activity → the pre-existing attribution stands
#     and, newer than machine input and inside the freshness window, it
#     blocks. This is the retire-SAFETY floor the self fix must not lower:
#     the self branch only ever ADDS a GO for the provably-own-session
#     case; everything else keeps blocking. (NB: a human raw-typing into
#     the pane in steady state carries the SAME own session-id, not a
#     different one — that path is out of scope by the never-raw-type
#     invariant + check-1 pane-state, per the script header.)
echo "## 13. submit with a different session-id → NO-GO (conservative)"
reset_state
seed_provenance         op-win "sess-own-xyz"
stamp_user_prompt_sid   op-win "$(( NOW - 9 ))" "sess-operator-different"
run_preflight OUT RC    op-win --pane-state idle
assert_eq      "operator submit -> exit 1 (no-go)" "$RC"  "1"
assert_contains "operator submit -> safe=0"        "$OUT" "safe=0"
assert_contains "reason cites fresh submit"        "$OUT" "fresh operator submit"

# ── 14. self-activity does NOT override a genuine machine paste path ───────
#     Belt-and-suspenders: an orchestrator paste (machine-input stamp
#     present) with the window's own session-id is already covered by the
#     machine-input rule (test 4). Confirm the two guards compose — a self
#     session-id submit that is ALSO machine-covered still GOes.
echo "## 14. self session-id + covering machine paste → GO"
reset_state
seed_provenance         both-win "sess-both-111"
stamp_user_prompt_sid   both-win "$(( NOW - 9 ))"  "sess-both-111"
stamp_machine_input     both-win "$(( NOW - 10 ))" paste-followup
run_preflight OUT RC    both-win --pane-state idle
assert_eq      "self+machine -> exit 0 (go)" "$RC"  "0"
assert_contains "self+machine -> safe=1"     "$OUT" "safe=1"

# ══ your-org/nexus-code#813: the target's own `disposition:` ══════════════
#
# The gate decided retirement from pane state and operator engagement and
# never read the report the target had just filed. `bench272F-skeptic` said
# `verdict: refuted` / `disposition: second-pass`, was retired on a `safe=1`
# preflight, and stranded TWO windows: its target burned ~75 minutes on five
# `await` exit-4 cycles waiting for a reviewer that no longer existed, and
# the require-marker that never cleared blocked the target's retirement too.
#
# These cases plant REAL report files and let the REAL `ng skeptic-disposition`
# do the corpus lookup and the parse — no stub of either, because the coupling
# between "which report is this window's" and "what does it say" is where the
# defect lived.
plant_report() {   # plant_report <file-slug> <window> [<disposition-line>]
    local slug="$1" window="$2" disp="${3:-}"
    local f="$REPORTS_DIR/${window}_2026-08-07_232325_${slug}.md"
    {
        printf -- '---\n'
        printf 'project: %s\n' "$window"
        printf 'date: 2026-08-07\n'
        printf 'session-id: fe11e4f2-8f2d-444d-bc1c-6111369aadc9\n'
        printf 'window: %s\n' "$window"
        printf 'status: completed\n'
        printf 'skeptic-target: some-target\n'
        printf 'verdict: refuted\n'
        [[ -n "$disp" ]] && printf '%s\n' "$disp"
        printf -- '---\n\n'
        printf '# Skeptic pass\n\n## Summary\n\nBody text.\n'
    } > "$f"
    printf '%s' "$f"
}

echo "## 15. #813 the target's report says \`disposition: second-pass\` → NO-GO"
reset_state
plant_report second-pass-case disp-win "disposition: second-pass" >/dev/null
run_preflight OUT RC disp-win --pane-state idle
assert_eq      "#813 exit 1 (no-go)"  "$RC"  "1"
assert_contains "#813 safe=0"         "$OUT" "safe=0"
assert_contains "#813 reason names the disposition" "$OUT" "disposition: second-pass"
assert_contains "#813 reason names the report"      "$OUT" "disp-win_2026-08-07"

echo "## 15b. #813 CONTROL: \`no-further-pass\` on the SAME pane state → GO"
# The control that matters as much as the case above: a gate that refused
# every window carrying any disposition would pass 15 while making retirement
# impossible. Identical fixture, one token different.
reset_state
plant_report clean-case disp-win "disposition: no-further-pass" >/dev/null
run_preflight OUT RC disp-win --pane-state idle
assert_eq      "#813 CONTROL exit 0 (go)" "$RC"  "0"
assert_contains "#813 CONTROL safe=1"     "$OUT" "safe=1"

echo "## 15c. #813 CONTROL: a report stating NO disposition → GO"
reset_state
plant_report no-disp-case disp-win >/dev/null
run_preflight OUT RC disp-win --pane-state idle
assert_eq      "#813 no-disposition exit 0 (go)" "$RC"  "0"
assert_contains "#813 no-disposition safe=1"     "$OUT" "safe=1"

echo "## 15d. #813 CONTROL: NO report for this window at all → GO"
# `no-report` is a POSITIVE negative — the corpus was enumerable and nothing
# claims this window. It must not be confused with 15e.
reset_state
plant_report other-window-case someone-else "disposition: second-pass" >/dev/null
run_preflight OUT RC disp-win --pane-state idle
assert_eq      "#813 no-report exit 0 (go)" "$RC"  "0"
assert_contains "#813 no-report safe=1"     "$OUT" "safe=1"
# …and the OTHER window's second-pass is still honoured, so 15d passes for
# the right reason (the lookup is window-scoped, not "found nothing anywhere").
run_preflight OUT RC someone-else --pane-state idle
assert_eq      "#813 …while the window that DID ask is still blocked" "$RC" "1"

echo "## 15e. #813 THE DISTINCTION: corpus not enumerable → NO-GO, not GO"
# This is the load-bearing case. "I could not look" must NOT reach the same
# conclusion as 15d's "I looked and found none" — that collapse IS #813.
reset_state
REPORTS_DIR_OVERRIDE="$WORK/no-such-corpus-dir"
run_preflight OUT RC disp-win --pane-state idle
unset REPORTS_DIR_OVERRIDE
assert_eq      "#813 unknown-corpus exit 1 (no-go)" "$RC"  "1"
assert_contains "#813 unknown-corpus safe=0"        "$OUT" "safe=0"
assert_contains "#813 …and says it could not LOOK, not that nothing was found" \
                "$OUT" "could not look"

echo "## 15f. #813 an UNREADABLE disposition → NO-GO, distinctly"
# The author DID state one and the parser could not resolve it (#684). Both
# tokens present ⇒ refuse; the refusal must say "fix the line", not "you
# asked for another pass".
reset_state
plant_report ambiguous-case disp-win "disposition: second-pass or no-further-pass" >/dev/null
run_preflight OUT RC disp-win --pane-state idle
assert_eq      "#813 unreadable exit 1 (no-go)" "$RC"  "1"
assert_contains "#813 unreadable safe=0"        "$OUT" "safe=0"
assert_contains "#813 unreadable is NAMED as unread, not as a request" \
                "$OUT" "could not be READ"

echo "## 15g. #813 RELEASE (a): a verdict reviewing this window, logged after"
reset_state
RPT=$(plant_report released-case disp-win "disposition: second-pass")
touch -d '@1000000000' "$RPT"
printf '{"ts":"%s","agent":"monitor","event":"skeptic-verdict","target-window":"disp-win","verdict":"credible"}\n' \
    "$(date -Is -d '@1000001000')" > "$STATE_DIR/action-log.jsonl"
run_preflight OUT RC disp-win --pane-state idle
assert_eq      "#813 released-by-verdict exit 0 (go)" "$RC"  "0"
assert_contains "#813 released-by-verdict safe=1"     "$OUT" "safe=1"

echo "## 15h. #813 a verdict PREDATING the report does NOT release"
# The release must post-date the request, or the gate is released by the very
# verdict whose report asked for another pass.
reset_state
RPT=$(plant_report stale-verdict-case disp-win "disposition: second-pass")
touch -d '@1000002000' "$RPT"
printf '{"ts":"%s","agent":"monitor","event":"skeptic-verdict","target-window":"disp-win","verdict":"credible"}\n' \
    "$(date -Is -d '@1000001000')" > "$STATE_DIR/action-log.jsonl"
run_preflight OUT RC disp-win --pane-state idle
assert_eq      "#813 stale-verdict exit 1 (no-go)" "$RC"  "1"
assert_contains "#813 stale-verdict safe=0"        "$OUT" "safe=0"

echo "## 15i. #813 RELEASE (b): the audited \`skeptic resolve --disposition\`"
# Driven through the REAL verb, so the release the refusal MESSAGE tells the
# operator to run is the release this gate actually honours. A hand-written
# rationale file would keep passing if either side renamed it.
reset_state
RPT=$(plant_report resolve-case disp-win "disposition: second-pass")
touch -d '@1000000000' "$RPT"
run_preflight OUT RC disp-win --pane-state idle
assert_eq      "#813 CONTROL: blocked before the resolve" "$RC" "1"
env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$STATE_DIR" \
    bash "$_test_dir/skeptic-channel.sh" resolve disp-win --disposition \
    --reason "adjudicated: the second pass is not warranted, findings are cosmetic" \
    >/dev/null 2>&1
RC=$?
assert_eq      "#813 resolve --disposition exits 0 with NO marker present" "$RC" "0"
run_preflight OUT RC disp-win --pane-state idle
assert_eq      "#813 released-by-resolve exit 0 (go)" "$RC"  "0"
assert_contains "#813 released-by-resolve safe=1"     "$OUT" "safe=1"

echo "## 15j. #813 CONTROL: bare \`resolve\` (no --disposition, no marker) still refuses"
# The pre-existing fail-loud contract must survive: a bare resolve with
# nothing to clear is still an error, so `--disposition` is a deliberate act
# rather than the new default.
reset_state
env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$STATE_DIR" \
    bash "$_test_dir/skeptic-channel.sh" resolve nomarker-win \
    --reason "nothing to clear here, this should fail loudly as before" \
    >/dev/null 2>&1
RC=$?
assert_eq      "#813 bare resolve with no marker still exits 1" "$RC" "1"

echo "## 15k. #813 F3: an OLD \$NEXUS_ROOT/monitor/ng must not brick retirement"
# Skeptic finding F3. `skeptic-disposition` is a verb this commit introduces, so
# resolving `ng` from $NEXUS_ROOT first means script and verb come from
# DIFFERENT commits whenever the trees differ — the standard nexus posture
# (secondary clone + inherited NEXUS_ROOT) and the state during any staged
# rollout. Measured before the fix, same commit, changing only the environment:
# 93/0 unset vs 48 pass / 45 FAIL against a primary whose `ng` predates the
# verb, every failure a `go` turned into a refusal. That is safe=0 for EVERY
# window, forever.
#
# This case IS that environment: a $NEXUS_ROOT whose `ng` does not know the
# verb. Sibling-first makes it a non-event.
reset_state
SKEW_ROOT="$WORK/skew-root"
mkdir -p "$SKEW_ROOT/monitor"
cat > "$SKEW_ROOT/monitor/ng" <<'OLDNG'
#!/usr/bin/env bash
# Stands in for an `ng` predating `skeptic-disposition` — the real one exits 1
# with exactly this shape.
echo "ng: unknown subcommand: ${1:-} (see ng --help)" >&2
exit 1
OLDNG
chmod +x "$SKEW_ROOT/monitor/ng"
OUT=$(NEXUS_ROOT="$SKEW_ROOT" bash "$PREFLIGHT" skew-win --state-dir "$STATE_DIR" \
        --now "$NOW" --reports-dir "$REPORTS_DIR" --pane-state idle 2>/dev/null); RC=$?
assert_eq      "#813 F3 skewed NEXUS_ROOT still reaches a verdict" "$RC" "0"
assert_contains "#813 F3 …and it is safe=1, not a permanent brick" "$OUT" "safe=1"
# NEGATIVE CONTROL: the skewed root must not have silently disabled the gate
# either — a second-pass report under the same skewed root must STILL block.
# Without this, "sibling-first" and "gate quietly turned off" look identical.
plant_report skew-blocking skew-win2 "disposition: second-pass" >/dev/null
OUT=$(NEXUS_ROOT="$SKEW_ROOT" bash "$PREFLIGHT" skew-win2 --state-dir "$STATE_DIR" \
        --now "$NOW" --reports-dir "$REPORTS_DIR" --pane-state idle 2>/dev/null); RC=$?
assert_eq      "#813 F3 CONTROL: the gate still FIRES under the skewed root" "$RC" "1"
assert_contains "#813 F3 CONTROL: …for the disposition reason" "$OUT" "second-pass"

echo "## 15l. #813 F4: ONE unreadable report must not brick every window"
# Skeptic finding F4. `awk` is FATAL on the first file it cannot open — it does
# not skip and continue — so a single chmod-000 member, dangling symlink, or
# `*.md` directory in a ~1000-file corpus written by many agents took down
# retirement for EVERY window at once, with the offending path swallowed by
# `2>/dev/null`.
reset_state
plant_report readable-one f4-win "disposition: no-further-pass" >/dev/null
BADF="$REPORTS_DIR/unrelated_2026-08-07_000000_bad.md"
printf -- '---\nwindow: someone-else\n---\n\nbody\n' > "$BADF"
chmod 000 "$BADF"
run_preflight OUT RC f4-win --pane-state idle
chmod 644 "$BADF" 2>/dev/null || true
assert_eq      "#813 F4 one unreadable member does not brick retirement" "$RC" "0"
assert_contains "#813 F4 …the window's own disposition is still read" "$OUT" "safe=1"
# CONTROL: an unreadable member must not silently disable the gate either.
reset_state
plant_report f4-blocking f4-win2 "disposition: second-pass" >/dev/null
BADF="$REPORTS_DIR/unrelated_2026-08-07_000000_bad.md"
printf -- '---\nwindow: someone-else\n---\n\nbody\n' > "$BADF"
chmod 000 "$BADF"
run_preflight OUT RC f4-win2 --pane-state idle
chmod 644 "$BADF" 2>/dev/null || true
assert_eq      "#813 F4 CONTROL: the gate still FIRES alongside an unreadable member" "$RC" "1"

echo "## 15m. #813 F4b: an \`unreadable\` disposition is RELEASABLE, not a brick"
# The PR's own standard: "a gate with no release is a brick". `second-pass` had
# two releases; `unreadable` had none.
reset_state
RPT=$(plant_report f4b-case f4b-win "disposition: second-pass or no-further-pass")
touch -d '@1000000000' "$RPT"
run_preflight OUT RC f4b-win --pane-state idle
assert_eq      "#813 F4b CONTROL: unreadable blocks before the resolve" "$RC" "1"
env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$STATE_DIR" \
    bash "$_test_dir/skeptic-channel.sh" resolve f4b-win --disposition \
    --reason "adjudicated: the disposition line is malformed but the author meant no further pass" \
    >/dev/null 2>&1
run_preflight OUT RC f4b-win --pane-state idle
assert_eq      "#813 F4b an audited resolve releases \`unreadable\` too" "$RC" "0"
assert_contains "#813 F4b …safe=1"                                       "$OUT" "safe=1"

echo "## 15n. #813 F5: \`resolve\` must not report a real clear as \"no marker\""
# Skeptic finding F5. The first draft re-tested `[[ -e "$marker" ]]` AFTER the
# `rm`, so the branch could never be true and a real clear announced "no marker
# was present" — a lie told to an orchestrator who has just invoked the verb
# that exists to REPLACE a hand-`rm`, i.e. the message most likely to send them
# back to `rm`. No suite asserted either string, on dev or on the branch.
reset_state
mkdir -p "$STATE_DIR/skeptic/pending"
echo 1 > "$STATE_DIR/skeptic/pending/f5win"
F5OUT=$(env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$STATE_DIR" \
    bash "$_test_dir/skeptic-channel.sh" resolve f5win \
    --reason "verdict landed in the secondary clone state dir, see the report" 2>&1)
assert_contains "#813 F5 a real marker clear says so"          "$F5OUT" \
                "resolved skeptic-pending marker for f5win"
assert_not_contains "#813 F5 …and does NOT claim no marker was present" "$F5OUT" \
                "no marker was present"
# CONTROL: the disposition-only form must still say the true thing.
F5OUT=$(env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$STATE_DIR" \
    bash "$_test_dir/skeptic-channel.sh" resolve f5nomarker --disposition \
    --reason "adjudicated: no further pass warranted, the findings are cosmetic" 2>&1)
assert_contains "#813 F5 CONTROL: the marker-less form still reports truthfully" \
                "$F5OUT" "no marker was present"

# ---- your-org/nexus-code#962: THE GATE RECORDS WHAT IT READ ---------------
#
# Until this change the disposition gate was a pure read that wrote nothing, so
# after an irreversible `tmux kill-window` nobody could say what it had answered.
# Measured cost of that: asked how many retirements were authorised on a
# disposition belonging to a DIFFERENT TASK, one of two candidate windows was
# UNDETERMINABLE — no record of the decision exists.
#
# These assert the RECORD, and they assert it on BOTH verdicts. A record written
# only when the gate proceeds would be the same blind spot in a smaller costume:
# a refusal that should have been a proceed is exactly as interesting.
echo "== #962: the disposition gate leaves an audit record =="
GATE_REPORTS="$WORK/reports-962"; mkdir -p "$GATE_REPORTS"
printf -- '---\nwindow: g962go\ndisposition: no-further-pass\n---\n\nbody\n' \
    > "$GATE_REPORTS/g962go_2026-01-01_000000_x.md"
printf -- '---\nwindow: g962no\ndisposition: second-pass\n---\n\nbody\n' \
    > "$GATE_REPORTS/g962no_2026-01-01_000000_x.md"
_gate_rows() {  # rows this suite's action log holds for a window
    grep '"event":"skeptic-disposition-gate"' "$STATE_DIR/action-log.jsonl" 2>/dev/null \
        | grep -F "\"window\":\"$1\"" || true
}

REPORTS_DIR_OVERRIDE="$GATE_REPORTS" run_preflight OUT RC g962go --pane-state idle
assert_eq       "#962 the PROCEED verdict is unchanged"        "$RC" "0"
assert_contains "#962 …and the gate recorded the state it read" \
                "$(_gate_rows g962go)" '"state":"no-further-pass"'
assert_contains "#962 …naming the report that governed"        "$(_gate_rows g962go)" \
                'g962go_2026-01-01_000000_x.md'
assert_contains "#962 …with its mtime, so a later report can be told from an earlier one" \
                "$(_gate_rows g962go)" '"report-mtime":'

REPORTS_DIR_OVERRIDE="$GATE_REPORTS" run_preflight OUT RC g962no --pane-state idle
assert_eq       "#962 the REFUSE verdict is unchanged"         "$RC" "1"
assert_contains "#962 …and a refusal is recorded too, not only a proceed" \
                "$(_gate_rows g962no)" '"state":"second-pass"'

# THE COULD-NOT-LOOK CASE. This is why the record is emitted BEFORE the
# probe-failure arm rather than inside the `case`: "the gate could not look" is
# the answer a later audit most needs, and an after-the-arm placement drops it.
# An unreadable corpus dir makes the probe return `state=unknown` (rc 2).
GATE_UNREADABLE="$WORK/reports-962-gone"
REPORTS_DIR_OVERRIDE="$GATE_UNREADABLE" run_preflight OUT RC g962unk --pane-state idle
assert_eq       "#962 CONTROL: an unenumerable corpus still REFUSES the kill" "$RC" "1"
assert_contains "#962 …and the could-not-look answer is recorded, not dropped" \
                "$(_gate_rows g962unk)" 'skeptic-disposition-gate'

# FAIL-OPEN, asserted rather than asserted-about. A logging failure is not
# evidence about the window; if it could block a retirement, a full disk would
# stall the whole board. Broken by making the log path unwritable — the action
# log is a FILE, so a DIRECTORY at that path makes every append fail.
GATE_BROKEN="$WORK/state-962-broken"
mkdir -p "$GATE_BROKEN/action-log.jsonl"
REPORTS_DIR_OVERRIDE="$GATE_REPORTS" \
_out=$(bash "$PREFLIGHT" g962go --pane-state idle --state-dir "$GATE_BROKEN" \
            --now "$NOW" --reports-dir "$GATE_REPORTS" 2>/dev/null); _rc=$?
assert_eq       "#962 FAIL-OPEN: a broken audit log does NOT change the verdict" "$_rc" "0"
assert_contains "#962 …and the gate still reports safe=1"      "$_out" "safe=1"

# ==========================================================================
# your-org/nexus-code#962 — A DISPOSITION IS A PROPERTY OF A TASK
# ==========================================================================
#
# A window was KILLED on this. `argsurf2` held an outstanding `second-pass` on
# #906/#911; `retire-preflight` returned `rc=0 safe=1` and it was retired at
# 2026-08-15T03:01:12. The obligation was extinguished by a report about a
# DIFFERENT issue (#952) — a `no-further-pass` that was a true statement about
# #952 and said nothing whatever about #906. No audit event, no state trace,
# and no intent by anybody.
#
# The lookup selected THE NEWEST report by mtime whose frontmatter `window:`
# matched, and the gate treated that one report as "this window's disposition".
# But a window is not a task: retained windows serve several issues in
# sequence, which is the design.
#
# TWO REPORTS, ONE WINDOW — the fixture #962 asks for by name ("the property to
# test ... a two-task fixture rather than describe"). Note this needs no author
# intent and no role confusion: `argsurf2` fired between two reports by the
# same author in the same role. Two careful reviewers deferred this hole
# because it had been framed as "an author can waive their own review", which
# points at the AUTHORITY axis; the axis it varies on is TASK IDENTITY.
echo "## 16. #962 a newer report about ANOTHER task must not extinguish an older ask"
reset_state
_962_a=$(plant_report t906-asks disp962 "disposition: second-pass")
sleep 1
_962_b=$(plant_report t952-done disp962 "disposition: no-further-pass")
# Guard the guard: B really is newer, or the fixture exercises nothing.
_962_amt=$(stat -c %Y "$_962_a"); _962_bmt=$(stat -c %Y "$_962_b")
assert_eq "#962 fixture: the no-further-pass report really is NEWER" \
    "$( (( _962_bmt > _962_amt )) && echo newer || echo not-newer )" "newer"
run_preflight OUT RC disp962 --pane-state idle
assert_eq       "#962 THE PROPERTY: the older ask still REFUSES the kill" "$RC" "1"
assert_contains "#962 …reported as safe=0"            "$OUT" "safe=0"
assert_contains "#962 …naming the report that ASKS, not the newest one" \
    "$OUT" "t906-asks"
assert_not_contains "#962 …and not citing the no-further-pass report as governing" \
    "$OUT" "t952-done"
# CONTROL — this must narrow the gate, not weld it shut. With nothing asking,
# the very same two-report shape still permits.
reset_state
plant_report t906-done disp962 "disposition: no-further-pass" >/dev/null
sleep 1
plant_report t952-done disp962 "disposition: no-further-pass" >/dev/null
run_preflight OUT RC disp962 --pane-state idle
assert_eq       "#962 CONTROL: two reports, neither asking → still GO" "$RC" "0"
assert_contains "#962 CONTROL: …safe=1"                "$OUT" "safe=1"
# CONTROL 2 — the single-report case, which is 1585 of 1654 windows, is
# BYTE-UNCHANGED in behaviour: one report asking still refuses, naming itself.
reset_state
plant_report lone-ask disp962b "disposition: second-pass" >/dev/null
run_preflight OUT RC disp962b --pane-state idle
assert_eq       "#962 CONTROL: the single-report case is unchanged (NO-GO)" "$RC" "1"
assert_contains "#962 CONTROL: …naming its one report"  "$OUT" "lone-ask"

# ==========================================================================
# your-org/nexus-code#961 — check 1be: A CLEARED MARKER IS NOT CLEARANCE
# ==========================================================================
#
# Check 1b asks a window-keyed BIT. One window took 12 verdicts across 7 issues
# against that one flag, and ANY ONE of them `rm`s it — including for the six
# tasks nobody reviewed. So the absence of a marker cannot mean "nothing is
# owed", and that direction is the silent one.
#
# The fixture is the state the bit cannot express: NO MARKER, and a ledger that
# names two armed artefacts with one UNATTRIBUTED discharge between them. Under
# the old scan that discharge reset the whole outstanding set and the window
# retired owing both.
echo "## 17. #961 outstanding obligations with NO marker → NO-GO, naming them"
reset_state
mkdir -p "$STATE_DIR/skeptic/pending"
_961_A=$(printf 'a%.0s' {1..64}); _961_B=$(printf 'b%.0s' {1..64})
{ printf 'armed\t%s\t2026-08-15T01:00:00\t906\t/reports/a.md\n' "$_961_A"
  printf 'armed\t%s\t2026-08-15T02:00:00\t952\t/reports/b.md\n' "$_961_B"
  printf 'discharged\t-\t2026-08-15T03:00:00\tcredible\t952\tsk961\tambiguous-2-arms-outstanding\n'
} > "$STATE_DIR/skeptic/pending/.owe961.ledger"
# THE MARKER IS DELIBERATELY ABSENT — that is the whole point of this arm.
assert_eq "#961 fixture: no pending marker exists (the bit says 'nothing owed')" \
    "$( [[ -e "$STATE_DIR/skeptic/pending/owe961" ]] && echo present || echo absent )" "absent"
run_preflight OUT RC owe961 --pane-state idle
assert_eq       "#961 THE PROPERTY: an unattributed verdict does NOT authorise the kill" "$RC" "1"
assert_contains "#961 …reported as safe=0"     "$OUT" "safe=0"
assert_contains "#961 …and the refusal counts what is owed" "$OUT" "2"
# CONTROL 1 — an ATTRIBUTED verdict closes exactly its own artefact, and the
# OTHER one still blocks. This is the two-task property, on the kill path.
reset_state
mkdir -p "$STATE_DIR/skeptic/pending"
{ printf 'armed\t%s\t2026-08-15T01:00:00\t906\t/reports/a.md\n' "$_961_A"
  printf 'armed\t%s\t2026-08-15T02:00:00\t952\t/reports/b.md\n' "$_961_B"
  printf 'discharged\t%s\t2026-08-15T03:00:00\tcredible\t906\tsk961\tattributed\n' "$_961_A"
} > "$STATE_DIR/skeptic/pending/.owe961.ledger"
run_preflight OUT RC owe961 --pane-state idle
assert_eq       "#961 CONTROL: a verdict on task A does not clear task B" "$RC" "1"
# CONTROL 2 — an AUDITED operator release closes the whole set and the window
# retires. Without this the gate is a brick, and a brick teaches the `rm`
# bypass `ng skeptic resolve` exists to replace.
reset_state
mkdir -p "$STATE_DIR/skeptic/pending"
{ printf 'armed\t%s\t2026-08-15T01:00:00\t906\t/reports/a.md\n' "$_961_A"
  printf 'armed\t%s\t2026-08-15T02:00:00\t952\t/reports/b.md\n' "$_961_B"
  printf 'resolved\t-\t2026-08-15T04:00:00\toperator\tadjudicated on the record\n'
} > "$STATE_DIR/skeptic/pending/.owe961.ledger"
run_preflight OUT RC owe961 --pane-state idle
assert_eq "#961 CONTROL: an audited resolve releases the whole set → GO" "$RC" "0"
# CONTROL 3 — THE MIGRATION CONTROL, and the one that decides whether this is
# safe to land. 571 of 574 task dirs on the operator's primary have no live
# window and no ledger. A window with NO ledger must be completely unaffected,
# or this check wedges the entire existing state dir on the day it merges.
reset_state
run_preflight OUT RC noledger961 --pane-state idle
assert_eq       "#961 MIGRATION: a window with NO ledger is unaffected → GO" "$RC" "0"
assert_contains "#961 MIGRATION: …safe=1"      "$OUT" "safe=1"

# ==========================================================================
# your-org/nexus-code#1137 F1 — THE RELEASE BAR IS NOT THE SELECTED REPORT'S
# MTIME. ADDING AN ASK MUST NOT MAKE A WINDOW RETIREABLE.
# ==========================================================================
#
# `report_mtime` is what a `.cleared-rationale` must post-date for check 1c to
# count the gate released, i.e. it IS the release bar. It was taken from the
# SELECTED report — the highest-RANK one — and `second-pass` outranks
# `unreadable`, so a promotion could select an OLDER report and LOWER the bar.
# A rationale too old to release ONE ask then became new enough to release TWO.
#
# Measured before the fix, on this exact fixture: one blocking report ->
# `safe=0`; ADD a second blocking ask of the other rank -> `safe=1 safe to
# retire`. **Adding an outstanding obligation made the window retireable**,
# which is #962's own class in the permitting direction, inside #962's fix.
#
# The precondition is all three of: >=2 blocking reports, of DIFFERENT ranks,
# with a release record dated BETWEEN their mtimes. Recorded because the
# obvious two-report fixture does NOT show it — without a release record the
# state is refused either way, and a guard built from the obvious fixture would
# have passed against the defect.
#
# NOTHING IN THIS SUITE ASSERTED `report_mtime` BEFORE THIS BLOCK, and every
# other #962 fixture has at most ONE blocking report. That is how a false
# invariant — stated in the code comment AND in the PR body — survived.
echo "## 18. #1137 F1 the release bar is the MAX over blocking reports, not the selected one's"
reset_state
mkdir -p "$STATE_DIR/skeptic/pending"
# Deterministic mtimes: the ordering IS the defect, so it must not be a race.
_f1_b=$(plant_report un-newest f1w "disposition: second-pass or no-further-pass")   # unreadable
touch -d '@2000' "$_f1_b"
# A release record dated BETWEEN the two reports.
printf 'resolved by hand\n' > "$STATE_DIR/skeptic/pending/.f1w.cleared-rationale"
touch -d '@1500' "$STATE_DIR/skeptic/pending/.f1w.cleared-rationale"
run_preflight OUT RC f1w --pane-state idle
assert_eq "#1137 F1 baseline: ONE blocking ask @2000, rationale @1500 → NO-GO" "$RC" "1"

# THE NEGATIVE CONTROL, and the one that matters: adding a SECOND ask, of the
# other rank and OLDER, must not release anything.
_f1_a=$(plant_report sp-oldest f1w "disposition: second-pass")
touch -d '@1000' "$_f1_a"
run_preflight OUT RC f1w --pane-state idle
assert_eq "#1137 F1 THE PROPERTY: ADDING a blocking ask must NOT make it retireable" "$RC" "1"
assert_contains "#1137 F1 …still safe=0"  "$OUT" "safe=0"

# …and the two fields must be independently correct: the NAMED report is the
# higher-RANK one, while the BAR is the maximum over both. Asserting only the
# state would pass against the defect, which reported the right state with the
# wrong mtime.
_f1_disp=$(env -u NEXUS_ROOT bash "$_test_dir/ng" skeptic-disposition f1w \
    --reports-dir "$REPORTS_DIR" 2>/dev/null)
assert_contains "#1137 F1 …the NAMED report is the second-pass one (rank wins the selection)" \
    "$_f1_disp" "sp-oldest"
assert_contains "#1137 F1 THE PROPERTY: …while report_mtime is the MAX over blocking (2000)" \
    "$_f1_disp" "report_mtime=2000"
assert_contains "#1137 F1 …and both are counted as blocking" "$_f1_disp" "blocking=2"

# CONTROL — THE FIXTURE MUST BE MIXED-RANK, AND THIS IS WHY.
#
# Reports arrive mtime-DESCENDING, so with two reports of the SAME rank the
# first seen already holds the highest mtime and the lowering assignment is a
# no-op. Traced at `1ba67ad`, same two mtimes (300 / 200), max over blocking
# 300:
#
#   mixed rank (unreadable@300, second-pass@200) -> report_mtime=200   BROKEN
#   same  rank (second-pass@300, second-pass@200) -> report_mtime=300  correct
#
# So a fixture built from two same-rank reports PASSES AGAINST THE BROKEN CODE
# and proves nothing. The trigger needs an `unreadable` report with a HIGHER
# mtime than the `second-pass` that outranks it, because only a RANK PROMOTION
# writes a lower mtime over a higher one. This control keeps the next author
# from "simplifying" the fixture into vacuity.
reset_state
_f1c_hi=$(plant_report same-rank-hi f1cw "disposition: second-pass"); touch -d '@300' "$_f1c_hi"
_f1c_lo=$(plant_report same-rank-lo f1cw "disposition: second-pass"); touch -d '@200' "$_f1c_lo"
assert_contains "#1137 F1 CONTROL: two SAME-rank reports report the max even pre-fix (a vacuous fixture)"     "$(env -u NEXUS_ROOT bash "$_test_dir/ng" skeptic-disposition f1cw --reports-dir "$REPORTS_DIR" 2>/dev/null)"     "report_mtime=300"

# Restore the F1 fixture for the release control below.
reset_state
mkdir -p "$STATE_DIR/skeptic/pending"
_f1_b=$(plant_report un-newest f1w "disposition: second-pass or no-further-pass"); touch -d '@2000' "$_f1_b"
_f1_a=$(plant_report sp-oldest f1w "disposition: second-pass");                    touch -d '@1000' "$_f1_a"
printf 'resolved by hand\n' > "$STATE_DIR/skeptic/pending/.f1w.cleared-rationale"

# CONTROL — the bar still RELEASES when a rationale genuinely post-dates every
# ask. Without this, a fix that simply never releases would pass everything
# above.
touch -d '@2500' "$STATE_DIR/skeptic/pending/.f1w.cleared-rationale"
run_preflight OUT RC f1w --pane-state idle
assert_eq "#1137 F1 CONTROL: a rationale newer than EVERY ask does release → GO" "$RC" "0"
assert_contains "#1137 F1 CONTROL: …safe=1" "$OUT" "safe=1"

# ==========================================================================
# your-org/nexus-code#1137 F2 — AN UNREADABLE LEDGER IS NOT AN EMPTY ONE
# ==========================================================================
#
# `_skeptic_open_arms` returns 1 both for "no ledger exists" (legitimate, and
# the whole pre-#984 corpus) and for "a ledger exists but could not be read or
# parsed". Collapsing both printed `outstanding=0` at rc 0 — a confident
# negative asserted without looking, on a kill path.
echo "## 19. #1137 F2 a ledger that EXISTS but cannot be read is REFUSED, not read as zero"
reset_state
mkdir -p "$STATE_DIR/skeptic/pending"
_f2_led="$STATE_DIR/skeptic/pending/.f2w.ledger"
printf 'armed\t%s\t2026-08-28T01:00:00\t961\t/r/a.md\n' "$(printf 'a%.0s' {1..64})" > "$_f2_led"
chmod 000 "$_f2_led"
# Guard the guard: running as root would make the file readable anyway and the
# whole arm would pass vacuously.
if [[ -r "$_f2_led" ]]; then
    echo "  SKIP: #1137 F2 — the fixture file is still readable (running as root?); arm not exercised" >&2
else
    run_preflight OUT RC f2w --pane-state idle
    assert_eq       "#1137 F2 THE PROPERTY: an unreadable ledger REFUSES the kill" "$RC" "1"
    assert_contains "#1137 F2 …and says it could not be established, not that nothing is owed" \
        "$OUT" "cannot be established"
    assert_not_contains "#1137 F2 …never claiming a count it does not have" "$OUT" "0 artefact"
fi
chmod 644 "$_f2_led"
# CONTROL — the same ledger, readable, is a normal refusal naming what is owed.
run_preflight OUT RC f2w --pane-state idle
assert_eq       "#1137 F2 CONTROL: readable + outstanding → NO-GO, on the ordinary arm" "$RC" "1"
assert_contains "#1137 F2 CONTROL: …naming the count"  "$OUT" "1 artefact"
# CONTROL — an ABSENT ledger stays rc 0. This is the migration control again:
# 571 orphaned task dirs have no ledger and must be unaffected.
reset_state
run_preflight OUT RC f2w --pane-state idle
assert_eq "#1137 F2 CONTROL: an ABSENT ledger is still unaffected → GO" "$RC" "0"

# ── #1190: THE REFUSAL NAMES THE AWAIT LOOP IT IS PROTECTING ─────────────
#
# A settled obligation and a closed pairing are different facts in different
# places, and only the second releases the reviewer's await loop. So `vacevidsk`
# sat in `wrapped-awaiting-protocol` with its debt already paid: the watcher
# emitted `retire-eligible`, this gate answered `safe=0 … agent work in flight
# (pane=working-background)`, and BOTH WERE CORRECT — the work in flight was the
# await loop the missing sentinel was causing. Nothing named the cause.
#
# THE NAME IS THE WHOLE POINT, and it is where #1190's own filer had to correct
# its own issue body. A skeptic awaits on ITS OWN channel, not its target's:
# `ng skeptic close <target>` wrote the target's sentinel and left the loop
# running; `ng skeptic close <skeptic>` released it within 8s. So the assertion
# below is not "a clause appears" — it is that the clause names the AWAITING
# window and NOT the target, which is the discriminator between advice that
# works and advice that teaches the reader the mechanism is broken.
#
#   "the refusal names the awaiting window's OWN channel"
#       kill: derive the name from the pairing/target instead of the child argv
#             -> got sk1190-target want sk1190-await
#   "a present DONE suppresses the diagnosis"
#       kill: drop the `-e .../DONE` test -> the clause fires on a closed pairing
#   "an OUTSTANDING obligation suppresses the diagnosis"
#       kill: drop the obligations gate -> the clause fires while the loop is
#             legitimately waiting, telling the operator to close a live round
#   "the verdict is UNCHANGED"
#       kill: any polarity change -> got safe=1
echo "## 15b. #929 — the refusal reports HOW LONG the slot has been held"
# #929: retirement authorization is keyed on pane STATE alone, so a background
# child that can never terminate is indistinguishable from real work and the
# board pays a slot indefinitely. The issue deliberately ships no fix, on the
# correct ground that the converse error destroys a live worker — and suggests
# VISIBILITY instead of authorization. This is that: words on a refusal that
# has already been decided.
#
# THE VERDICT ARMS ARE THE POINT. A clause that could move `safe` would be a
# liveness heuristic in the authorization path, which is exactly what #929
# argues against; every case below re-asserts rc and `safe=` unchanged.
reset_state
# Derive from $NOW, the harness clock `run_preflight` passes as `--now`, NOT
# from `date +%s`: the two differ here and an exact-duration assertion against
# the wrong clock is a flake that reads as a defect. Measured: 5h18m vs 5h20m.
_h929=$(( NOW - 19200 ))                  # 5h20m — #929's own measured incident
RETIRE_PREFLIGHT_PANE_LINE="state=working-background active=1 window=9 name=h929 bg_shells=1 bg_reliable=1 bg_oldest_start=$_h929 bg_infra=0" \
    run_preflight OUT RC h929 --pane-state working-background
assert_contains "#929 the refusal reports the hold duration"        "$OUT" "alive 5h20m"
assert_contains "#929 …and names who may reap it"                   "$OUT" "only authorised reaper"
assert_eq       "#929 …verdict UNCHANGED: still a refusal"          "$RC"  "1"
assert_contains "#929 …still safe=0; this alters WORDS only"        "$OUT" "safe=0"

# NEGATIVE CONTROL 1 — a YOUNG child says nothing. Below an hour the clause
# adds nothing an operator does not already read from `working-background`.
RETIRE_PREFLIGHT_PANE_LINE="state=working-background active=1 window=9 name=h929 bg_shells=1 bg_reliable=1 bg_oldest_start=$(( NOW - 120 )) bg_infra=0" \
    run_preflight OUT RC h929 --pane-state working-background
assert_not_contains "#929 CONTROL: a 2-minute child carries no clause" "$OUT" "alive "
assert_contains     "#929 CONTROL: …and the ordinary refusal still stands" "$OUT" "safe=0"

# NEGATIVE CONTROL 2 — EVERY DOUBT PRINTS NOTHING. `bg_oldest_start=0` is
# pane-state's "not measured", NOT an epoch; reading it as one would report a
# child alive since 1970. A missing field must be equally silent.
RETIRE_PREFLIGHT_PANE_LINE="state=working-background active=1 window=9 name=h929 bg_shells=1 bg_reliable=1 bg_oldest_start=0 bg_infra=0" \
    run_preflight OUT RC h929 --pane-state working-background
assert_not_contains "#929 CONTROL: bg_oldest_start=0 is NOT-MEASURED, not 1970" "$OUT" "alive "
RETIRE_PREFLIGHT_PANE_LINE="state=working-background active=1 window=9 name=h929" \
    run_preflight OUT RC h929 --pane-state working-background
assert_not_contains "#929 CONTROL: a missing bg_oldest_start prints nothing" "$OUT" "alive "

# NEGATIVE CONTROL 3 — the clause must not leak onto a KILL-AUTHORISED state.
# `idle` is in _BK_KILL_OK_STATES; a duration printed there would read as a
# reason to hesitate over a window the gate has just cleared.
RETIRE_PREFLIGHT_PANE_LINE="state=idle active=0 window=9 name=h929 bg_shells=1 bg_reliable=1 bg_oldest_start=$_h929 bg_infra=0" \
    run_preflight OUT RC h929 --pane-state idle
assert_not_contains "#929 CONTROL: an idle (kill-ok) pane never carries the clause" "$OUT" "alive "

echo "## 15. #1190 — the working-background refusal names the await loop"
reset_state
_sk1190_dir="$WORK/sk1190"
mkdir -p "$_sk1190_dir"
# A real process whose argv matches, planted under a root we control, so the
# tree walk is exercised rather than stubbed. Deliberately NOT a global `ps`
# match: a predicate keyed on a string cannot tell the thing from the
# description of the thing, and sibling agents hold these strings in their
# prompts (your-org/nexus-code#1073).
printf '#!/usr/bin/env bash\nsleep 120\n' > "$_sk1190_dir/skeptic-channel.sh"
bash -c 'bash "$1/skeptic-channel.sh" await sk1190-await' _ "$_sk1190_dir" &
_sk1190_root=$!
# The tree must actually contain the child before anything is asserted about
# its absence being meaningful. A race here would make every negative control
# below pass for the wrong reason.
_sk1190_ready=0
for _i in 1 2 3 4 5 6 7 8 9 10; do
    if pgrep -P "$_sk1190_root" >/dev/null 2>&1; then _sk1190_ready=1; break; fi
    sleep 0.2
done
if (( _sk1190_ready == 0 )); then
    kill "$_sk1190_root" 2>/dev/null || true
    th_abort "#1190 fixture: the planted await child never appeared under $_sk1190_root"
fi
# POSITIVE CONTROL FIRST: the fixture really does reach the walker. Without it
# every assertion below is satisfied by a clause that never fires.
_obl="$_test_dir/obligations.sh"
NEXUS_STATE_DIR="$STATE_DIR" bash "$_obl" open --debtor sk1190-target \
    --creditor sk1190-peer --kind skeptic-verdict >/dev/null 2>&1 || true
NEXUS_STATE_DIR="$STATE_DIR" bash "$_obl" settle --debtor sk1190-target \
    --reason "round delivered, pairing not ended" >/dev/null 2>&1 || true
RETIRE_PREFLIGHT_PANE_PID=$_sk1190_root \
    run_preflight OUT RC sk1190-target --pane-state working-background
assert_contains "#1190 the refusal names the await loop as the work in flight" \
    "$OUT" "skeptic-channel.sh await"
assert_contains "#1190 …naming the AWAITING window's own channel" \
    "$OUT" "ng skeptic close sk1190-await"
assert_not_contains "#1190 …and NOT the target's, which releases nothing" \
    "$OUT" "ng skeptic close sk1190-target"
assert_contains "#1190 …stating what was measured, not a property untested" \
    "$OUT" "nothing it owes is outstanding"
assert_eq       "#1190 …and the verdict is UNCHANGED: still a refusal" "$RC" "1"
assert_contains "#1190 …still safe=0; this change alters WORDS only" "$OUT" "safe=0"

# NEGATIVE CONTROL 1 — a DONE sentinel exists, so the pairing is closed and
# there is nothing to diagnose.
mkdir -p "$STATE_DIR/skeptic/sk1190-await"
: > "$STATE_DIR/skeptic/sk1190-await/DONE"
RETIRE_PREFLIGHT_PANE_PID=$_sk1190_root \
    run_preflight OUT RC sk1190-target --pane-state working-background
assert_not_contains "#1190 CONTROL: a present DONE suppresses the diagnosis" \
    "$OUT" "ng skeptic close"
assert_contains "#1190 CONTROL: …and the ordinary refusal still stands" \
    "$OUT" "agent work in flight"
rm -f "$STATE_DIR/skeptic/sk1190-await/DONE"

# NEGATIVE CONTROL 2 — the window still OWES a verdict, so the await loop is
# doing exactly its job. Diagnosing here would tell an operator to close a LIVE
# round, which is the automatic-close #962 forbids arriving as advice.
#
# THE CREDITOR MUST BE A WINDOW THAT ACTUALLY EXISTS. `obl_state` releases an
# edge as `void-creditor-absent` when tmux is readable and the creditor is not
# in the window list — so an invented creditor produces a VOID edge, the gate
# stays clear, and this control passes vacuously while asserting nothing. That
# is what the first draft did, and the control caught it: it FAILED, correctly,
# against a diagnosis that was firing for the right reason on a fixture that
# could not make it stop.
# NOT `| head -1`: that is an early-exit reader, which SIGPIPEs the producer
# under `pipefail` and is enrolled in `early-exit-readers.manifest`. Caught by
# `ng guards-for-diff --run` on this very change. Take the first line by
# parameter expansion instead — no pipe, no truncated producer, no manifest row.
_sk1190_wins=$(tmux list-windows -a -F '#{window_name}' 2>/dev/null || true)
_sk1190_creditor=${_sk1190_wins%%$'\n'*}
if [[ -z "$_sk1190_creditor" ]]; then
    th_skip "#1190 CONTROL: an OUTSTANDING obligation suppresses it" \
        "no tmux window list available, so no creditor can be made LIVE (obl_state would void the edge and the control would pass vacuously)"
else
    NEXUS_STATE_DIR="$STATE_DIR" bash "$_obl" open --debtor sk1190-target \
        --creditor "$_sk1190_creditor" --kind skeptic-verdict >/dev/null 2>&1 || true
    # NON-VACUITY: the edge must really be blocking, or the assertion below is
    # about a gate that was clear anyway.
    NEXUS_STATE_DIR="$STATE_DIR" bash "$_obl" gate sk1190-target >/dev/null 2>&1
    assert_eq "#1190 CONTROL fixture: the obligation really does block" "$?" "1"
    RETIRE_PREFLIGHT_PANE_PID=$_sk1190_root \
        run_preflight OUT RC sk1190-target --pane-state working-background
    assert_not_contains "#1190 CONTROL: an OUTSTANDING obligation suppresses it" \
        "$OUT" "ng skeptic close"
    NEXUS_STATE_DIR="$STATE_DIR" bash "$_obl" settle --debtor sk1190-target \
        --reason "control cleanup" >/dev/null 2>&1 || true
fi

# NEGATIVE CONTROL 3 — no await child in the tree at all. The clause must not
# fire off the obligation state alone.
#
# The root must be CHILDLESS. `$$` is not: this suite backgrounded the planted
# await child from its own shell, so the test process's tree still contains it
# and the walker finds it — correctly. The first draft used `$$` and this
# control FAILED, which is the control doing its job on the fixture rather than
# on the code.
sleep 120 &
_sk1190_bare=$!
RETIRE_PREFLIGHT_PANE_PID=$_sk1190_bare \
    run_preflight OUT RC sk1190-target --pane-state working-background
assert_not_contains "#1190 CONTROL: no await child in the tree -> no diagnosis" \
    "$OUT" "ng skeptic close"
assert_contains "#1190 CONTROL: …and the ordinary refusal is unaffected" \
    "$OUT" "agent work in flight"
th_kill_own_child "$_sk1190_bare" 2>/dev/null || kill "$_sk1190_bare" 2>/dev/null || true
wait "$_sk1190_bare" 2>/dev/null || true

# NEGATIVE CONTROL 4 — an IDLE pane is unaffected. The clause rides one refusal
# arm; it must not leak into a GO.
RETIRE_PREFLIGHT_PANE_PID=$_sk1190_root \
    run_preflight OUT RC sk1190-await --pane-state idle
assert_not_contains "#1190 CONTROL: an idle pane never carries the clause" \
    "$OUT" "skeptic-channel.sh await"

th_kill_own_child "$_sk1190_root" 2>/dev/null || kill "$_sk1190_root" 2>/dev/null || true
wait "$_sk1190_root" 2>/dev/null || true

# ── #1190 ARGV VARIANTS — THE BAND ABOVE PLANTS ONLY THE BARE FORM ───────────
#
# Everything above this line plants exactly one argv, `await sk1190-await`, and
# is GREEN at 989b888 while the derivation is WRONG for every documented flag
# spelling. `_sk_await_child_window` took `"${args##* }"` — THE LAST WORD — and
# `await` documents `[--timeout S] [--interval S] [--once]` in its own usage
# line, with `ng skeptic` a pure passthrough, so all three are legal live argvs.
# Measured at 989b888, same fixture, argv the only variable:
#
#   await sk1190-await                 -> `ng skeptic close sk1190-await`  ok
#   await sk1190-await --timeout 900   -> `ng skeptic close 900`           WRONG
#   await sk1190-await --once          -> `ng skeptic close --once`        WRONG
#
# AND THE MIS-DERIVED NAME DEFEATS THE CLAUSE'S OWN DONE SUPPRESSION, which is
# the assertion that matters most and the one nothing above could make: with
# `skeptic/sk1190-await/DONE` PRESENT — a properly closed pairing, where CONTROL
# 1 above asserts silence — the flagged argv still fired, because it looked for
# `skeptic/900/DONE`. A fabricated diagnosis on a HEALTHY window, whose remedy
# (`skeptic-channel.sh close 900`) exits 0, creates a directory and releases
# nothing. That is the wrong-party failure #1190's own correction comment exists
# to prevent.
#
# THE PROPERTY IS THE TASK-ID `await` RESOLVED, NOT A POSITION. #1190's stated
# close-criterion is "the first token after `await`"; `cmd_await`'s flags are
# ORDER-FREE, and `await --timeout 900 <win>` is measured legal, so a positional
# rule loses a true diagnosis on that spelling. The flags-first case below is
# what pins the difference between mirroring the parser and counting words.
#
#   "a --timeout argv names the WINDOW, not the timeout value"
#       kill: restore `name="${args##* }"` -> got `close 900` want `close sk1190-await`
#   "…with the flags FIRST too"
#       kill: take the first token after `await` -> doubt, clause disappears
#   "FALSE POSITIVE: a present DONE suppresses it on a FLAGGED argv"
#       kill: restore the last-word derivation -> the clause fires on a closed pairing
#   "an UNKNOWN flag is a doubt"
#       kill: drop the `-*) return 1` arm -> a flag of unknown arity is parsed anyway
echo "## 15b. #1190 — the derivation survives every documented await argv"
reset_state
NEXUS_STATE_DIR="$STATE_DIR" bash "$_obl" open --debtor sk1190-target \
    --creditor sk1190-peer --kind skeptic-verdict >/dev/null 2>&1 || true
NEXUS_STATE_DIR="$STATE_DIR" bash "$_obl" settle --debtor sk1190-target \
    --reason "round delivered, pairing not ended" >/dev/null 2>&1 || true

# Plant a live process whose OWN argv is the await invocation (`exec`, so the
# `bash -c` wrapper is replaced rather than sitting above it), and do not return
# until `ps` actually shows that argv — a race here would let every negative
# assertion below pass against a process that is not the one under test.
_sk1190_plant() {
    local _p _i
    bash -c 'exec bash "$1/skeptic-channel.sh" await "${@:2}"' _ "$_sk1190_dir" "$@" \
        >/dev/null 2>&1 </dev/null &
    _p=$!
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        case "$(ps -o args= -p "$_p" 2>/dev/null)" in
            *skeptic-channel.sh*await*) printf '%s' "$_p"; return 0 ;;
        esac
        sleep 0.2
    done
    kill "$_p" 2>/dev/null || true
    wait "$_p" 2>/dev/null || true
    return 1
}
_sk1190_reap() {
    [[ -n "${1:-}" ]] || return 0
    th_kill_own_child "$1" 2>/dev/null || kill "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}

# --- (a) flags LAST: `await <win> --timeout 900` -----------------------------
_sk1190_v=$(_sk1190_plant sk1190-await --timeout 900) \
    || th_abort "#1190 argv fixture: --timeout plant never showed the await argv"
assert_contains "#1190 argv fixture is live and carries the flag (non-vacuity)" \
    "$(ps -o args= -p "$_sk1190_v" 2>/dev/null)" "await sk1190-await --timeout 900"
RETIRE_PREFLIGHT_PANE_PID=$_sk1190_v \
    run_preflight OUT RC sk1190-target --pane-state working-background
assert_contains "#1190 ARGV: a --timeout argv still names the WINDOW" \
    "$OUT" "ng skeptic close sk1190-await"
assert_not_contains "#1190 ARGV: …and NOT the timeout VALUE, which releases nothing" \
    "$OUT" "ng skeptic close 900"
assert_eq       "#1190 ARGV: …verdict unchanged, still a refusal" "$RC" "1"

# --- (b) FALSE POSITIVE: a closed pairing must stay silent on a FLAGGED argv --
# CONTROL 1 above asserts this for the bare form. At 989b888 the flagged form
# looked for `skeptic/900/DONE`, found nothing, and diagnosed a healthy window.
mkdir -p "$STATE_DIR/skeptic/sk1190-await"
: > "$STATE_DIR/skeptic/sk1190-await/DONE"
RETIRE_PREFLIGHT_PANE_PID=$_sk1190_v \
    run_preflight OUT RC sk1190-target --pane-state working-background
assert_not_contains "#1190 ARGV: a present DONE suppresses the diagnosis on a FLAGGED argv too" \
    "$OUT" "ng skeptic close"
assert_contains "#1190 ARGV: …and the ordinary refusal still stands" \
    "$OUT" "agent work in flight"
rm -f "$STATE_DIR/skeptic/sk1190-await/DONE"
_sk1190_reap "$_sk1190_v"

# --- (c) flags FIRST: `await --timeout 900 <win>` ----------------------------
# `cmd_await`'s arg loop is order-free and this spelling is measured to run and
# resolve `<win>`. It is what separates "mirror the parser" from "take the token
# after `await`" — the latter yields `--timeout` and prints nothing.
_sk1190_v=$(_sk1190_plant --timeout 900 sk1190-await) \
    || th_abort "#1190 argv fixture: flags-first plant never showed the await argv"
RETIRE_PREFLIGHT_PANE_PID=$_sk1190_v \
    run_preflight OUT RC sk1190-target --pane-state working-background
assert_contains "#1190 ARGV: flags FIRST resolves the window just as cmd_await does" \
    "$OUT" "ng skeptic close sk1190-await"
_sk1190_reap "$_sk1190_v"

# --- (d) `--once` ------------------------------------------------------------
_sk1190_v=$(_sk1190_plant sk1190-await --once) \
    || th_abort "#1190 argv fixture: --once plant never showed the await argv"
RETIRE_PREFLIGHT_PANE_PID=$_sk1190_v \
    run_preflight OUT RC sk1190-target --pane-state working-background
assert_contains "#1190 ARGV: --once names the window" \
    "$OUT" "ng skeptic close sk1190-await"
assert_not_contains "#1190 ARGV: …and never the flag itself" \
    "$OUT" "ng skeptic close --once"
_sk1190_reap "$_sk1190_v"

# --- (e) an UNKNOWN flag is a DOUBT, and doubt prints nothing ----------------
# A flag this parser has never heard of has unknown arity, so the parse cannot
# continue. `_sk_await_child_window`'s stated contract is that every doubt
# prints nothing, and a fail-CLOSED default arm is what stops a spelling nobody
# has considered from being parsed anyway (your-org/nexus-code#1121).
_sk1190_v=$(_sk1190_plant sk1190-await --future-flag x) \
    || th_abort "#1190 argv fixture: unknown-flag plant never showed the await argv"
assert_contains "#1190 ARGV fixture is live and carries the unknown flag (non-vacuity)" \
    "$(ps -o args= -p "$_sk1190_v" 2>/dev/null)" "await sk1190-await --future-flag x"
RETIRE_PREFLIGHT_PANE_PID=$_sk1190_v \
    run_preflight OUT RC sk1190-target --pane-state working-background
assert_not_contains "#1190 ARGV: an UNKNOWN flag yields no diagnosis at all" \
    "$OUT" "ng skeptic close"
assert_contains "#1190 ARGV: …and the ordinary refusal is unaffected" \
    "$OUT" "agent work in flight"
_sk1190_reap "$_sk1190_v"

# --- (f) an ALL-DIGITS task-id is a doubt -----------------------------------
# `skeptic-channel.sh close 900` exits 0 having created a directory and released
# nothing, so a numeric name is the one spelling whose wrong advice is SILENT —
# and it is a name the window-key vocabulary already refuses as ambiguous with
# an index. There is nowhere safe to send the reader, so nothing is printed.
_sk1190_v=$(_sk1190_plant 900) \
    || th_abort "#1190 argv fixture: numeric plant never showed the await argv"
RETIRE_PREFLIGHT_PANE_PID=$_sk1190_v \
    run_preflight OUT RC sk1190-target --pane-state working-background
assert_not_contains "#1190 ARGV: an all-digits task-id is a doubt, not a name" \
    "$OUT" "ng skeptic close"
_sk1190_reap "$_sk1190_v"

# ── your-org/nexus-code#1282 ─────────────────────────────────────────────
#
# THREE REFUSALS THIS SUITE COULD NOT REACH, INCLUDING ITS OWN DEFAULT-DENY ARM.
#
# Source-aware line coverage over the whole suite found that check 1d's `#845`
# obligation refusal, its `cannot source _obligations.sh` sibling, and the
# `*)` arm whose own comment reads `# DEFAULT-DENY` were never executed by any
# assertion. Mutation confirmed it: both arms flipped to `emit 1 … exit 0`
# ("kill AUTHORISED"), `bash -n` clean, md5 verified changed and verified still
# changed after the run — and the suite reported `184 passed, 0 failed / ALL
# TESTS PASSED`, identical to the clean tree. A default-deny arm that has never
# been taken is an assumption, not a guarantee, and the consequence of a blind
# arm here is an IRREVERSIBLE kill of a window that owes another one a verdict.
#
# WHY THE EXISTING `sk1190` FIXTURE CANNOT REACH THEM, stated precisely because
# the issue's own reasoning was half wrong and the correction is the useful
# part. Every `obligations.sh open` in this suite is paired with
# `--pane-state working-background`, an ACTIVE state, so `bk_pane_kill_authorized`
# vetoes at check 1 and the script exits ~879 lines before the obligation gate.
# But that fixture's assertion is NOT vacuous: the check-1 refusal path itself
# calls `_sk_await_clause`, which shells out to `obligations.sh gate`, so the
# assertion does discriminate — for `_sk_await_clause`. What is true is
# narrower and still damning: nothing in the suite reaches check 1d.
#
# The two fixtures below are `--pane-state idle`, which is what admits them
# past check 1, and each carries a NEGATIVE CONTROL that flips exactly one
# token. Without the control an assertion here would be satisfied by any
# arrangement that refuses for any reason — which is how the fixture they
# replace passed for four months.

echo "## #1282(a). #845: an OUTSTANDING obligation refuses the kill"
reset_state
_obl_bin="$_test_dir/obligations.sh"
if [[ ! -x "$_obl_bin" && ! -r "$_obl_bin" ]]; then
    th_abort "#1282(a): monitor/obligations.sh is missing — the fixture cannot be built"
fi
NEXUS_STATE_DIR="$STATE_DIR" bash "$_obl_bin" open --debtor obl1282 \
    --creditor obl1282-peer --kind skeptic-verdict >/dev/null 2>&1 \
    || th_abort "#1282(a): could not open the obligation edge the fixture rests on"

# `OBL_TMUX_WINDOWS=" "` IS THE SEAM, AND IT IS THE WHOLE REASON THIS FIXTURE
# WORKS WHERE A NAIVE ONE DOES NOT. `_obligations.sh` releases an edge as
# `void-creditor-absent` when the creditor is not in the tmux window list, so a
# plain `--pane-state idle` run STILL returned `safe=1` on the first attempt —
# the obligation was real, reached the gate, and was voided there. A single
# space is the documented "could not look" arm, which yields `live`
# unconditionally, needs no tmux, and removes the `th_skip` the fixture this
# replaces depended on. A fixture that skips on a tmux-less host is a fixture
# CI does not run.
OBL_TMUX_WINDOWS=" " run_preflight OUT RC obl1282 --pane-state idle
assert_eq       "#1282(a) an outstanding obligation REFUSES the kill" "$RC" "1"
assert_contains "#1282(a) …safe=0"                         "$OUT" "safe=0"
assert_contains "#1282(a) …and NAMES what is owed"         "$OUT" "OWES 1 outstanding obligation"
assert_contains "#1282(a) …and names the CREDITOR"         "$OUT" "obl1282-peer"
assert_contains "#1282(a) …citing the issue it enforces"   "$OUT" "845"

# NEGATIVE CONTROL — settling the edge must release the gate, or this is only
# measuring "an idle window with a state dir refuses", which is false anyway.
# `settle` REFUSES a --reason under 20 characters; the fixture this replaces
# passed `"control cleanup"` (15) with a `|| true` that swallowed the refusal,
# so its "cleanup" never happened. Hence both the length here and the rc check.
NEXUS_STATE_DIR="$STATE_DIR" bash "$_obl_bin" settle --debtor obl1282 \
    --reason "fixture teardown: the pairing ended and the verdict is on the record" \
    >/dev/null 2>&1 \
    || th_abort "#1282(a): settle failed — the negative control below would be meaningless"
OBL_TMUX_WINDOWS=" " run_preflight OUT RC obl1282 --pane-state idle
assert_eq       "#1282(a) CONTROL: a SETTLED edge releases the gate → GO" "$RC" "0"
assert_contains "#1282(a) CONTROL: …safe=1"                "$OUT" "safe=1"

echo "## #1282(b). the DEFAULT-DENY arm refuses a disposition state it has never heard of"
reset_state
# `_skeptic_stated_disposition`'s vocabulary is CLOSED — every `printf` in it
# yields one of absent|unreadable|no-further-pass|second-pass, and
# `cmd_skeptic_disposition` adds only no-report|unknown, all six of which the
# arms above handle. So with the real `ng` this arm is unreachable BY
# CONSTRUCTION: it guards a state a FUTURE parser adds, which is exactly what a
# default-deny arm is for and exactly why nothing had ever taken it.
#
# The seam is `$self_dir`, not `NEXUS_ROOT`: `ng_bin`/`_sk_ng_bin` resolve
# SIBLING-FIRST, which case 15k asserts. So the preflight is run from a scratch
# directory of symlinks carrying a stand-in `ng`.
_dd="$WORK/dd-selfdir"; rm -rf "$_dd"; mkdir -p "$_dd"
for _f in _bookkeeping.sh _obligations.sh watcher retire-preflight.sh; do
    ln -s "$_test_dir/$_f" "$_dd/$_f" 2>/dev/null || true
done
cat > "$_dd/ng" <<'DDNG'
#!/usr/bin/env bash
# Stands in for a FUTURE parser that resolves a disposition state this gate
# predates. Nothing else about the run is altered.
case "${1:-}" in
  skeptic-disposition)
    printf 'state=%s source=frontmatter report=/tmp/dd-1282.md report_mtime=0 blocking=1 reports=1 detail=novel-state\n' \
        "${DD_STATE:-harmonised}"; exit 0 ;;
  skeptic-obligations) printf 'window=dd1282 key=dd1282 outstanding=0 ledger=absent\n'; exit 0 ;;
  log-action) exit 0 ;;
  *) exit 1 ;;
esac
DDNG
chmod +x "$_dd/ng"

_dd_run() {   # _dd_run <state>
    DD_STATE="$1" bash "$_dd/retire-preflight.sh" dd1282 \
        --state-dir "$STATE_DIR" --now "$NOW" --reports-dir "$REPORTS_DIR" \
        --pane-state idle 2>/dev/null
}
OUT=$(_dd_run harmonised); RC=$?
assert_eq       "#1282(b) an UNRECOGNISED disposition state REFUSES the kill" "$RC" "1"
assert_contains "#1282(b) …safe=0"                       "$OUT" "safe=0"
assert_contains "#1282(b) …NAMING the state it never heard of" \
                "$OUT" "unrecognised disposition state 'harmonised'"

# NEGATIVE CONTROL — the same substituted `ng` with a RECOGNISED state must GO.
# Without it this fixture measures "a stand-in ng brakes the gate", which would
# pass whether or not the default-deny arm exists at all.
OUT=$(_dd_run no-further-pass); RC=$?
assert_eq       "#1282(b) CONTROL: a RECOGNISED state still goes" "$RC" "0"
assert_contains "#1282(b) CONTROL: …safe=1"              "$OUT" "safe=1"
# ARM-SPECIFICITY (your-org/nexus-code#1391). The two lines above establish
# the arm does not FIRE on a recognised state; they do not establish that its
# DIAGNOSTIC is absent there. A presence-only check is satisfied by an
# implementation that emits the message unconditionally — a wrong explanation
# attached to a right verdict (`#1359`'s shape). Needle deliberately omits the
# state value: an unconditional emit would name `no-further-pass`, not
# `harmonised`, and must still be caught. Mutation proof: printing the message
# unconditionally before the `case` turns THIS line red while the two CONTROL
# lines above stay green.
assert_not_contains "#1282(b) CONTROL: …and says NOTHING about an unrecognised state" \
                "$OUT" "unrecognised disposition state"

echo "## #1282(c). an unreadable obligation ledger is DOUBT, not permission"
reset_state
# The third arm the coverage pass flagged, and free once the scratch-self_dir
# idiom above exists: omit exactly one symlink. Doubt about an IRREVERSIBLE
# kill must refuse — the same direction `bk_pane_kill_authorized` takes one
# layer down, and the direction that makes `absent` the only state that has to
# NAME its evidence.
_nl="$WORK/noobl-selfdir"; rm -rf "$_nl"; mkdir -p "$_nl"
for _f in _bookkeeping.sh watcher retire-preflight.sh ng; do
    ln -s "$_test_dir/$_f" "$_nl/$_f" 2>/dev/null || true
done
OUT=$(bash "$_nl/retire-preflight.sh" noobl1282 \
        --state-dir "$STATE_DIR" --now "$NOW" --reports-dir "$REPORTS_DIR" \
        --pane-state idle 2>/dev/null); RC=$?
assert_eq       "#1282(c) an unreadable obligation ledger REFUSES the kill" "$RC" "1"
assert_contains "#1282(c) …safe=0"                       "$OUT" "safe=0"
assert_contains "#1282(c) …saying it cannot establish what is owed" \
                "$OUT" "cannot source"

# CONTROL for (c): the SAME scratch self_dir WITH the library present must go,
# so the refusal is attributable to the missing library and not to the idiom.
ln -s "$_test_dir/_obligations.sh" "$_nl/_obligations.sh" 2>/dev/null || true
OUT=$(bash "$_nl/retire-preflight.sh" noobl1282 \
        --state-dir "$STATE_DIR" --now "$NOW" --reports-dir "$REPORTS_DIR" \
        --pane-state idle 2>/dev/null); RC=$?
assert_eq       "#1282(c) CONTROL: with the ledger present, the same run goes" "$RC" "0"
assert_contains "#1282(c) CONTROL: …safe=1"              "$OUT" "safe=1"

# ---- summary -------------------------------------------------------------
echo
printf 'retire-preflight: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
