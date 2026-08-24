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
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing %q\n  in: <<%s>>\n' "$label" "$needle" "$hay" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

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
assert_contains "reason cites pending skeptic" "$OUT" "skeptic-pending marker live"
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

# ---- summary -------------------------------------------------------------
echo
printf 'retire-preflight: %d passed, %d failed\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
