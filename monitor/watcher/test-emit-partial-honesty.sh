#!/usr/bin/env bash
# test-emit-partial-honesty.sh — a DEGRADED watcher emit must say that it is
# degraded, IN THE EMIT (your-org/nexus-code#1044).
#
# WHAT IS BEING GUARDED. The orchestrator's entire model of the workspace comes
# from these emits. Two ways an emit could look complete while not being:
#
#   HALF A — the workspace prelude blows its wall-clock budget. `_run_bounded`
#   kills the render and preserves what it wrote; `render_idle_prelude` makes
#   exactly ONE stdout write and makes it LAST, so a timeout leaves the file
#   EMPTY. The old `[[ -n "$prelude" ]]` guard then printed nothing and the
#   `workspace:` line SILENTLY VANISHED. An absent line reads as "nothing to
#   report" — silence used as a proxy for absence, this workspace's dominant
#   defect class. The WARN went to watcher.log, which nobody reads mid-turn.
#
#   HALF B — the `--- idle workers ---` body is served from an ASYNC-STAGED
#   file (30 s cadence), so a window that died since it was rendered lingers as
#   a live row while the `--- tmux ---` section of the SAME emit, computed
#   fresh, has already dropped it. One message asserted a window both gone and
#   present, and instructed the orchestrator to "ANSWER it in the pane; do NOT
#   relaunch or close" for a pane that did not exist. The full-state snapshot
#   has been reconciled this way since 2026-07-21; the idle section is its
#   SIBLING and was never enrolled.
#
# BOTH DIRECTIONS ARE ASSERTED THROUGHOUT. A marker that fires on every emit is
# worse than none — it trains the reader to skip it — so every arm below has a
# must-not-fire control on the healthy path.
#
# Run: bash monitor/watcher/test-emit-partial-honesty.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

# Several plucked/sourced helpers read STATE_DIR under `set -u`; give them a
# scratch one for the whole run.
STATE_DIR=$(mktemp -d); export STATE_DIR
trap 'rm -rf "$STATE_DIR"' EXIT

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The SHARED ledger helpers (your-org/nexus-code#805): a FAIL raised inside a
# subshell dies with the counters but survives in the ledger, so the suite still
# reddens. Paired with the exact assertion-count guard at the foot of this file,
# that makes this suite `ledger=yes` + `count=exact` — the only combination the
# summary-honesty manifest treats as fully protected.
. "$_test_dir/_test_helpers.sh"

ok()  { printf '  PASS: %s\n' "$1"; _th_pass; }
bad() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }
has()   { assert_contains     "$1" "$2" "$3"; }
hasnt() { assert_not_contains "$1" "$2" "$3"; }

_pluck_fn() {  # <fn-name> <file>
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { capture=1 }
        capture { print }
        capture && /^\}/ { exit }
    ' "$2"
}

# ===========================================================================
# HALF A — a cut-off prelude declares itself
# ===========================================================================
echo "=== A1. _run_bounded on a late-writing render leaves an EMPTY file ==="
# The premise the whole of Half A rests on, pinned as a measurement rather than
# asserted in prose: if a timeout left a TRUNCATED line instead of nothing, the
# remedy would have to be different.
eval "$(_pluck_fn _run_bounded "$_test_dir/main.sh")"
_close_inherited_locks() { :; }
OUT=$(mktemp)
# BOTH outcomes are reachable and the choice between them is a RACE — measured
# over 8 identical trials (3 s render, 1 s budget): rc 124 every time, 2 runs
# left 0 bytes and 6 left the final line, because `_run_bounded` issues
# `pkill -P` first (killing the render's child) and the render's own shell can
# reach its next write before the following `kill` arrives. So this asserts the
# two outcomes SEPARATELY with renders that make each deterministic, rather than
# pinning whichever one a single trial happened to produce.
_never_writes()      { sleep 5; }                       # cannot leave bytes
_writes_then_hangs() { printf 'busy | idle'; sleep 5; } # always leaves bytes

_run_bounded 1 "$OUT" _never_writes; rc=$?
[[ "$rc" == "124" ]] && ok "budget exceeded reports rc 124" \
                     || bad "expected rc 124, got $rc"
[[ ! -s "$OUT" ]] && ok "…a render that never wrote leaves an EMPTY file" \
                  || bad "expected empty output, got: $(cat "$OUT")"

_run_bounded 1 "$OUT" _writes_then_hangs; rc=$?
[[ "$rc" == "124" ]] && ok "a cut-off render also reports rc 124" \
                     || bad "expected rc 124, got $rc"
[[ -s "$OUT" ]] && ok "…and a render cut off AFTER writing leaves a TRUNCATED file" \
                || bad "expected truncated output, got empty"

# The DISCRIMINATOR the operator-facing text now rests on (your-org/nexus-code#1063):
# `_run_bounded` returns 124 ONLY for a budget overrun and the CHILD'S OWN rc
# otherwise. Without this, "it was a timeout" is a property nothing tested — and
# `#1063` shows what that costs: the emit named a timeout, an investigator
# believed it, then over-corrected to "not a timeout" on a bad measurement.
_fails_fast()             { return 7; }
_fails_fast_after_write() { printf 'busy | idle'; return 7; }

_run_bounded 20 "$OUT" _fails_fast; rc=$?
[[ "$rc" == "7" ]] && ok "a child that CRASHES reports its own rc (7), never 124" \
                   || bad "expected rc 7 from a fast-failing child, got $rc"

_run_bounded 20 "$OUT" _fails_fast_after_write; rc=$?
[[ "$rc" == "7" ]] && ok "…and still its own rc when it wrote before failing" \
                   || bad "expected rc 7 from a write-then-fail child, got $rc"

_control() { printf 'busy | idle | retained\n'; }
_run_bounded 6 "$OUT" _control; rc=$?
[[ "$rc" == "0" && -s "$OUT" ]] && ok "the control completes: rc 0, output present" \
                               || bad "control failed: rc=$rc out=[$(cat "$OUT")]"
rm -f "$OUT"

echo "=== A2. an emit whose prelude was killed SAYS SO where the line would be ==="
# Drive the real _compose_report_body with a render that cannot finish.
tmp_dir=$(mktemp -d)
_ensure_watcher_tmp_dir() { :; }
log() { :; }
_cap_emit_sections() { cat; }
# _compose_report_body now routes its degraded log through the shared helper;
# pluck the PRODUCTION text rather than stubbing it, so this suite exercises the
# real mapping (and so a `command not found` at rc 127 cannot pass unnoticed).
eval "$(_pluck_fn _bounded_failure_log "$_test_dir/main.sh")"
# The budget derivation and the previous-render cache path (#1406) are called
# by _compose_report_body; plucked from production too, for the same reason.
eval "$(_pluck_fn _render_budget_seconds "$_test_dir/main.sh")"
eval "$(_pluck_fn _prelude_cache_path "$_test_dir/main.sh")"
eval "$(_pluck_fn _compose_report_body "$_test_dir/main.sh")"

render_idle_prelude() { sleep 5; }   # never writes → deterministic EMPTY
MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS=1
body=$(_compose_report_body "test" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "")
has "the emit carries a workspace line at all (it no longer vanishes)" "$body" "workspace:"
has "…and names it UNAVAILABLE, not empty"                             "$body" "workspace: UNAVAILABLE"
has "…and forecloses the 'empty workspace' misreading"                 "$body" 'NOT "an empty workspace"'
has "…and scopes the damage to this section"                           "$body" "Other sections are computed separately"
# The literal moved from `#1044` to `#1329` and the INTENT did not
# (your-org/nexus-code#1329). "Cites the issue so a reader can chase it" is not
# satisfied by a CLOSED thread: the emit cited `#1044` and `#1063`, both closed,
# so an operator following the pointer landed on two finished discussions of a
# failure that was still firing. Assert the OPEN tracking issue, and assert the
# closed ones are gone — a citation nobody can chase is the same liability as no
# citation, and keeping both would let the old pointer drift back in silently.
has  "…and cites an OPEN tracking issue a reader can chase"           "$body" "your-org/nexus-code#1329"
hasnt "…and no longer sends the reader to a CLOSED thread"            "$body" "#1044"
# `#1063` is bare in the old text, so it auto-linked to the NEXUS repo rather
# than to nexus-code — a citation that resolved to the wrong repository.
hasnt "…nor to the second, wrong-repo-resolving one"                  "$body" "#1063"
has "…and names the failure mode as a TIMEOUT, not just a failure"     "$body" "UNAVAILABLE (TIMED OUT)"

echo "=== A2b. a prelude cut off AFTER writing is flagged PARTIAL, not served as whole ==="
render_idle_prelude() { printf '2 busy | 1 idle'; sleep 5; }
MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS=1
body=$(_compose_report_body "test" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "")
has "the truncated counts are still shown"            "$body" "workspace: 2 busy | 1 idle"
has "…but flagged as CUT OFF rather than complete"    "$body" "PARTIAL (TIMED OUT) — the render above was CUT OFF"
has "…and says the counts are incomplete"             "$body" "counts on that line are incomplete"

echo "=== A2c. a prelude that CRASHED says so — and does NOT claim a timeout ==="
# The `#1063` arm. Before this, a child that exited non-zero for ANY reason was
# announced to the operator as a budget overrun. The two want different next
# moves — find the slow term vs. read the child's stderr — and the emit is the
# only place the operator sees either.
render_idle_prelude() { return 7; }          # fails immediately, writes nothing
MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS=20
body=$(_compose_report_body "test" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "")
has   "the emit still carries a workspace line"           "$body" "workspace:"
has   "…named UNAVAILABLE for a RENDER FAILURE"           "$body" "UNAVAILABLE (RENDER FAILED)"
has   "…and says explicitly that it is NOT a timeout"     "$body" "This is NOT a timeout"
hasnt "…and does NOT claim the budget was exceeded"       "$body" "exceeded its wall-clock budget"
hasnt "…and does NOT wear the TIMED OUT label"            "$body" "TIMED OUT"

echo "=== A2d. a prelude that wrote, then CRASHED, is PARTIAL — not timed out ==="
render_idle_prelude() { printf '2 busy | 1 idle'; return 7; }
MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS=20
body=$(_compose_report_body "test" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "")
has   "the partial counts are still shown"                "$body" "workspace: 2 busy | 1 idle"
has   "…flagged as a RENDER FAILURE, not a cut-off"       "$body" "PARTIAL (RENDER FAILED)"
hasnt "…and NOT as a timeout"                             "$body" "TIMED OUT"

echo "=== A3. MUST-NOT-FIRE: a healthy prelude carries no marker ==="
render_idle_prelude() { printf '2 busy | 1 idle | 0 retained\n'; }
MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS=20
body=$(_compose_report_body "test" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "")
has   "the healthy emit prints the real counts"        "$body" "workspace: 2 busy | 1 idle | 0 retained"
hasnt "…and NO 'UNAVAILABLE' marker"                   "$body" "UNAVAILABLE"
hasnt "…and NO 'PARTIAL' marker"                       "$body" "PARTIAL"
hasnt "…and NO 'TIMED OUT' label"                      "$body" "TIMED OUT"
hasnt "…and NO 'RENDER FAILED' label"                  "$body" "RENDER FAILED"

echo "=== A6. a render killed AFTER a complete one re-emits the PREVIOUS counts, DATED (#1406) ==="
# `UNAVAILABLE` was honest and unusable: the render fails under load, and load
# is highest when the most workers are live, so the counts were withheld
# exactly when the orchestrator had the most windows to track. A3 above left a
# complete render behind; this cycle's render is killed; the emit must carry
# the PREVIOUS counts labelled STALE with their age and the failure that
# emptied this cycle — never `UNAVAILABLE`, never the counts as if current.
has "the cache holds A3's complete render" "$(cat "$(_prelude_cache_path)" 2>/dev/null)" "2 busy | 1 idle | 0 retained"
render_idle_prelude() { sleep 5; }
MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS=1
body=$(_compose_report_body "test" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "")
has   "the previous complete counts are re-emitted on the workspace line" "$body" "workspace: 2 busy | 1 idle | 0 retained"
has   "…flagged STALE with the TIMED OUT label"                          "$body" "STALE (TIMED OUT)"
# The age is the wall time since A3's render: the killed render ran to its
# 1 s budget, so it is a small integer, never a fixed one.
if [[ "$body" =~ taken\ [0-9]+s\ ago ]]; then ok "…dated in whole seconds (taken Ns ago)"; else bad "…no 'taken Ns ago' age on the stale line: $body"; fi
has   "…and read as 'as of then', not 'now'"                             "$body" 'read them as "as of then"'
hasnt "…and NOT as UNAVAILABLE (the counts exist, they are dated)"       "$body" "UNAVAILABLE"
hasnt "…and NOT as PARTIAL (nothing of THIS render is shown)"            "$body" "PARTIAL"
# The same for a CRASH: stale, dated, and it still denies the timeout.
render_idle_prelude() { return 7; }
MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS=20
body=$(_compose_report_body "test" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "")
has   "a crash after a complete render is STALE (RENDER FAILED)" "$body" "STALE (RENDER FAILED)"
has   "…carrying the previous counts"                             "$body" "workspace: 2 busy | 1 idle | 0 retained"
hasnt "…and NOT claiming a timeout"                               "$body" "TIMED OUT"
# A PARTIAL render must never become tomorrow's "previous counts": a cut-off
# line after A3 leaves A3's line in the cache, and the next kill re-emits A3's.
render_idle_prelude() { printf '9 busy | 9 idle'; sleep 5; }
MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS=1
body=$(_compose_report_body "test" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "")
has   "a partial render is still PARTIAL, not STALE" "$body" "PARTIAL (TIMED OUT)"
render_idle_prelude() { sleep 5; }
body=$(_compose_report_body "test" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "")
has   "…and the next kill re-emits the COMPLETE render, not the partial one" "$body" "workspace: 2 busy | 1 idle | 0 retained"
hasnt "…(the partial counts never entered the cache)"                       "$body" "9 busy | 9 idle"
# CONTROL: with NO previous complete render (fresh state) the arm is unchanged.
rm -f "$(_prelude_cache_path)"
body=$(_compose_report_body "test" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "")
has   "CONTROL: no cache -> UNAVAILABLE (TIMED OUT), exactly as before" "$body" "UNAVAILABLE (TIMED OUT)"
hasnt "…and no STALE line"                                             "$body" "STALE"

echo "=== A7. the render budget is DERIVED from the window count, and says so (#1406) ==="
# Measured ~1.3 s per live window at loadavg ~40; a constant 20 s is exceeded
# near a dozen windows — the days the count matters most. base + N × per.
# `log` writes to a FILE: the function is called inside `$(…)`, so an array
# append in the stub would die with the subshell.
_bl="$tmp_dir/budget.log"; : > "$_bl"; log() { printf '%s\n' "$1" >> "$_bl"; }
_idle_list_worker_windows() { printf 'w1\t0\t1\nw2\t0\t2\nw3\t0\t3\nw4\t0\t4\nw5\t0\t5\n'; }
MONITOR_STARTUP_RENDER_TIMEOUT_SECONDS=20 MONITOR_RENDER_SECONDS_PER_WINDOW=2
assert_eq "5 windows at 2 s each on a 20 s base -> 30 s" "$(_render_budget_seconds)" "30"
has "…and the derivation is logged where a TIMED OUT reader will look" "$(cat "$_bl")" "20s base + 5 windows × 2s = 30s"
_idle_list_worker_windows() { :; }
assert_eq "no windows -> the base, unchanged" "$(_render_budget_seconds)" "20"
_idle_list_worker_windows() { printf 'w1\t0\t1\n'; }
MONITOR_RENDER_SECONDS_PER_WINDOW=0
assert_eq "per-window 0 restores the constant budget" "$(_render_budget_seconds)" "20"
unset -f _idle_list_worker_windows
MONITOR_RENDER_SECONDS_PER_WINDOW=2
assert_eq "no enumerator at all (standalone sourcing) -> the base, never smaller" "$(_render_budget_seconds)" "20"
log() { :; }
rm -rf "$tmp_dir"

echo "=== A4. the rc→text mapping itself, at the ONE place it lives ==="
# `_bounded_failure_log` is the whole class in one function. Assert its three
# arms directly, so a site that routes through it cannot be subtly wrong.
_al=(); log() { _al+=("$1"); }
_bounded_failure_log 0   20 ctx "the render" "nothing blocked"
assert_eq "rc 0 logs NOTHING" "${#_al[@]}" "0"
_al=(); _bounded_failure_log 124 20 ctx "the render" "nothing blocked"
has   "rc 124 names a TIMEOUT and the rc"     "${_al[0]:-}" "exceeded 20s and was killed (rc 124)"
# THE VOCABULARY BRIDGE (your-org/nexus-code#1329). The emit says
# `UNAVAILABLE (TIMED OUT)`; this log line used to say `exceeded 20s and was
# killed (rc 124)` and share not one word with it. An operator carrying the
# emit's label to watcher.log got a confident near-zero about a failure that had
# fired 419 times in five days — this workspace's dominant defect class, arriving
# through wording. The labels below are the emit's, verbatim.
has   "…AND wears the emit's own label, so a grep from the emit lands" "${_al[0]:-}" "TIMED OUT"
_al=(); _bounded_failure_log 7   20 ctx "the render" "nothing blocked"
has   "a crash names the rc AND denies the timeout" "${_al[0]:-}" "FAILED with rc 7 — NOT a timeout"
has   "…and wears the emit's RENDER FAILED label"   "${_al[0]:-}" "RENDER FAILED"
hasnt "…and never claims the budget was reached"    "${_al[0]:-}" "exceeded"
# The two labels stay MUTUALLY EXCLUSIVE: a shared vocabulary must not blur the
# distinction `#1063` exists to carry. This is the arm that would go red if a
# future edit made both lines say "TIMED OUT".
hasnt "…and does NOT also wear the TIMED OUT label" "${_al[0]:-}" "TIMED OUT"
log() { :; }

echo "=== A5. NO call site may bypass the helper — population DERIVED, not named ==="
# THE HISTORY THIS ENCODES, because it is the whole point.
#
#   Pass 1 fixed THREE sites and said "all three". There were SEVEN.
#   Pass 2 fixed all seven and shipped a guard whose predicate was THREE LITERAL
#   CONTEXT NAMES plus one wording. A ninth site with a new context and different
#   wording passed it silently — 53 passed, 0 failed, identical to baseline.
#
# That guard had THE SAME SHAPE AS THE DEFECT IT CLOSED: a check asserting a
# completeness its own predicate never tested. `#1063` exists because a message
# asserted a timeout the code never tested for.
#
# So the population is DERIVED FROM `_run_bounded` ITSELF. Nothing below names a
# context, a function, or a wording. A new call site enters the population by
# EXISTING, and must then be handled — which is the property, not a proxy for it.
#
# `_rb_sites` is deliberately GENEROUS: it excludes only the definition,
# comments, and `declare -F`. Over-matching gives a LOUD false positive the next
# author fixes; under-matching gives a SILENT pass, which is the defect itself.
_rb_sites() {   # <file> -> one line number per _run_bounded SITE
    grep -nE '_run_bounded' "$1" \
      | grep -vE '^[0-9]+:[[:space:]]*#' \
      | grep -vE '^[0-9]+:_run_bounded\(\) \{' \
      | grep -vE '^[0-9]+:.*declare -F _run_bounded' \
      | cut -d: -f1
}
# A site is HANDLED if `_bounded_failure_log` appears between it and the NEXT
# site; INLINE124 if that span tests `== 124` itself; otherwise BYPASS. The span
# is delimited BY THE POPULATION, so there is no window constant to get wrong.
_rb_audit() {   # <file> -> "LINE VERDICT" per site
    local f="$1" line next span; local -a arr=()
    while read -r line; do [[ -n "$line" ]] && arr+=("$line"); done < <(_rb_sites "$f")
    local i n=${#arr[@]}
    for (( i=0; i<n; i++ )); do
        line=${arr[$i]}
        if (( i+1 < n )); then next=$(( ${arr[$((i+1))]} - 1 )); else next=$(wc -l < "$f"); fi
        span=$(sed -n "${line},${next}p" "$f")
        if   grep -qE '(^|[^_[:alnum:]])_bounded_failure_log[[:space:]]' <<<"$span"; then printf '%s HANDLED\n' "$line"
        elif grep -qE '==[[:space:]]*124' <<<"$span"; then printf '%s INLINE124\n' "$line"
        else printf '%s BYPASS\n' "$line"; fi
    done
}

_MAIN="$_test_dir/main.sh"
_n_sites=$(_rb_sites "$_MAIN" | grep -c .)
printf '  (derived population: %s _run_bounded call site(s) in main.sh)\n' "$_n_sites"
# ENUMERATOR NON-VACUITY — the arm the previous guard lacked. A broken
# enumerator returns nothing and every arm below then passes for free.
if (( _n_sites >= 7 )); then
    printf '  PASS: the enumerator finds a real population (%s sites)\n' "$_n_sites"; _th_pass
else
    printf '  FAIL: enumerator found only %s sites — it is broken, and every check below is vacuous\n' "$_n_sites" >&2; _th_fail
fi

assert_empty "no _run_bounded site bypasses the rc→text distinction" \
    "$(_rb_audit "$_MAIN" | awk '$2=="BYPASS"{print $1}')"

# The ONE site that legitimately skips the helper is gh-now's gh-filter, which
# discriminates 124 inline with its own distinct text. Declared AND VERIFIED:
# assert it really is inline-124, rather than merely excused by name.
assert_eq "exactly one site handles the distinction INLINE, and it really tests 124" \
    "$(_rb_audit "$_MAIN" | awk '$2=="INLINE124"{n++} END{print n+0}')" "1"

# POSITIVE CONTROLS, differently shaped from each other AND from anything a
# context/wording predicate could see: (A) new context, the ORIGINAL if/else
# shape, and the word "exceeded" never appears; (B) rc captured but compared
# only to 0, with a message that asserts a timeout anyway.
_pd=$(mktemp -d)
_plant() { awk -v ins="$2" 'index($0,"rm -f \"$_sb_tmp\"") && !d {print ins; d=1} {print}' "$_MAIN" > "$1"; }
_plant "$_pd/A.sh" 'if ! _run_bounded "$_startup_to" "$_sb_tmp" render_heartbeat_probe; then
    log "WARN heartbeat-probe: render_heartbeat_probe blew its wall-clock allowance; continuing"
fi'
_plant "$_pd/B.sh" '_z_rc=0
_run_bounded "$_startup_to" "$_sb_tmp" render_other_thing || _z_rc=$?
(( _z_rc == 0 )) || log "WARN newsurface: render_other_thing timed out after ${_startup_to}s"'
_plant "$_pd/C.sh" '_z_rc=0
_run_bounded "$_startup_to" "$_sb_tmp" render_other_thing || _z_rc=$?
_bounded_failure_log "$_z_rc" "$_startup_to" newsurface render_other_thing "nothing blocked"'

# The plants must actually ENTER the population, or "caught" proves nothing.
assert_eq "a planted site GROWS the derived population" \
    "$(_rb_sites "$_pd/A.sh" | grep -c .)" "$(( _n_sites + 1 ))"

for _f in A B; do
    _by=$(_rb_audit "$_pd/$_f.sh" | awk '$2=="BYPASS"{print $1}')
    if [[ -n "$_by" ]]; then
        printf '  PASS: plant %s (a shape no context/wording predicate can see) is caught at line %s\n' "$_f" "$_by"; _th_pass
    else
        printf '  FAIL: plant %s went UNDETECTED — this guard does not check the property it names\n' "$_f" >&2; _th_fail
    fi
done

# MUST-NOT-FIRE: a NEW site handled CORRECTLY is not a bypass. Without this the
# guard degenerates to "never add a call site", which is not the property.
assert_empty "a correctly-handled NEW site is NOT flagged" \
    "$(_rb_audit "$_pd/C.sh" | awk '$2=="BYPASS"{print $1}')"

# Recorded as DATA rather than prose: the predicate this replaced is blind to A.
assert_eq "…and the NAMED-CONTEXT predicate this replaced sees plant A not at all" \
    "$(grep -cE 'log "WARN (startup-sweep|compose_report|compose_emit):[^"]*exceeded \$\{' "$_pd/A.sh")" "0"
rm -rf "$_pd"

echo "=== A6. the DOC's context-scoped predicate is sound — no OTHER site claims a helper context ==="
# `nexus.watcher` §8 tells the operator to identify the pre-#1066 corpus by
# CONTEXT, and warns off `rc 124` — which misclassifies 1,172 correctly-gated
# lines against 9,407 real ones in the live archive, an 11% false-positive rate
# sourced from #1068's own comment thread.
#
# That instruction holds only while no OTHER `exceeded` emitter hard-codes a
# context `_bounded_failure_log` is called with. Both halves are DERIVED — the
# contexts from the real call sites, the population from the real tree — so a
# new site cannot be added without this noticing.
_bfl_ctx=$(grep -oE '_bounded_failure_log[[:space:]]+"[^"]*"[[:space:]]+"[^"]*"[[:space:]]+[A-Za-z0-9_-]+' \
             "$_MAIN" | awk '{print $NF}' | sort -u | paste -sd'|')
_exc_lines() {
    local f
    for f in "$_test_dir"/*.sh; do
        case "${f##*/}" in test-*) continue;; esac
        grep -nE 'exceeded' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|${f##*/}:|"
    done
    return 0
}
_exc_n=$(_exc_lines | grep -c . || true)
# NON-VACUITY FIRST. `assert_empty` on a broken enumerator is a guaranteed pass,
# which is this repo's dominant defect class arriving inside its own guard.
assert_eq "A6 both enumerators are non-vacuous (contexts + population)" \
    "$( [[ -n "$_bfl_ctx" ]] && (( _exc_n >= 10 )) && echo ok \
        || echo "BROKEN contexts='${_bfl_ctx}' lines=${_exc_n}")" "ok"
assert_eq "A6 no non-helper site hard-codes a _bounded_failure_log context" \
    "$(_exc_lines | grep -E "(${_bfl_ctx})" || true)" ""

# ===========================================================================
# HALF B — the async-staged idle section is reconciled, and says what it withheld
# ===========================================================================
echo "=== B1. a row for a window that no longer exists is WITHHELD and NAMED ==="
# shellcheck source=_idle_probe.sh
source "$_test_dir/_idle_probe.sh" 2>/dev/null

SECTION='  - agentmsg-absent pane-absent (overlay awaiting the operator (blocked) — ANSWER it in the pane; do NOT relaunch or close)
  - livewin idle 300s WITHOUT wrap-up — consider follow-up paste'
LIVE=$'orchestrator\nlivewin\nservices'

out=$(printf '%s\n' "$SECTION" | _idle_restat_live_windows "$LIVE")
hasnt "the phantom row is gone"                        "$out" "agentmsg-absent pane-absent"
hasnt "…and so is its do-not-clean-up INSTRUCTION"     "$out" "ANSWER it in the pane"
has   "the live window's row survives untouched"       "$out" "livewin idle 300s WITHOUT wrap-up"
has   "…and the withholding is DECLARED, not silent"   "$out" "1 row(s) WITHHELD"
has   "…naming which window"                           "$out" "agentmsg-absent"
has   "…and telling the reader not to act on it"       "$out" "do NOT act on a withheld window"

echo "=== B2. MUST-NOT-FIRE: every row live → untouched, no withheld note ==="
LIVE_ALL=$'orchestrator\nagentmsg-absent\nlivewin\nservices'
out=$(printf '%s\n' "$SECTION" | _idle_restat_live_windows "$LIVE_ALL")
has   "both rows pass through"                    "$out" "agentmsg-absent pane-absent"
has   "…including the second"                     "$out" "livewin idle 300s"
hasnt "…and NO withheld note is appended"         "$out" "WITHHELD"

echo "=== B3. an empty live set FAILS OPEN (tmux transient must not blank a section) ==="
# The live set must be empty AND the tmux fallback must also come back empty,
# or this arm silently tests the real tmux server instead of the failure path —
# which is what it did on the first run here, reconciling against the
# operator's actual windows and withholding every planted row.
_b3=$(mktemp -d); printf '#!/usr/bin/env bash\nexit 1\n' > "$_b3/tmux"; chmod +x "$_b3/tmux"
out=$(printf '%s\n' "$SECTION" | PATH="$_b3:$PATH" _idle_restat_live_windows "")
rm -rf "$_b3"
has   "the section survives a failed tmux probe"  "$out" "agentmsg-absent pane-absent"
hasnt "…and claims nothing about what it withheld" "$out" "WITHHELD"

echo "=== B4. several dead windows are ALL named, in deterministic order ==="
SECTION3='  - deadA idle 10s WITHOUT wrap-up — consider follow-up paste
  - livewin idle 300s WITHOUT wrap-up — consider follow-up paste
  - deadB pane-absent (relaunch or close)'
out=$(printf '%s\n' "$SECTION3" | _idle_restat_live_windows "$LIVE")
has "both dead windows named, in row order" "$out" "2 row(s) WITHHELD — the window(s) no longer exist in tmux: deadA, deadB"
has "…and the live row is kept"              "$out" "livewin idle 300s"

echo "=== B5. non-row lines (footers, blanks) are never touched ==="
SECTION4='  - deadA idle 10s WITHOUT wrap-up — consider follow-up paste
  (3 retained windows suppressed: a, b, c)'
out=$(printf '%s\n' "$SECTION4" | _idle_restat_live_windows "$LIVE")
has   "the retained-footer passes through" "$out" "(3 retained windows suppressed: a, b, c)"
hasnt "…and the dead row does not"         "$out" "deadA idle 10s"

echo "=== B6. the tracker itself needs no reaper — a vanished window clears in ONE cycle ==="
# Recorded because the original report guessed the opposite and corrected
# itself. `list_idle_transitions` persists the set derived from LIVE tmux, so
# the row is dropped on the very next pass. If this ever stops holding, the
# remedy above (render-time reconciliation) is treating a lifecycle bug as a
# rendering one and the diagnosis must be revisited.
sf="$STATE_DIR/idle-state.tsv"; : > "$sf"
list_really_idle_workers() { printf '%s' "${CUR:-}"; }
CUR=$'zz-probe\tno-wrap-up\t162\t'; list_idle_transitions >/dev/null
has "cycle 1 records the live window" "$(cat "$sf")" "zz-probe"
CUR=''; list_idle_transitions >/dev/null
if [[ ! -s "$sf" ]]; then ok "cycle 2 (window gone) clears the row — exactly one cycle"
else bad "row survived: [$(cat "$sf")] — the tracker DOES need a reaper; revisit #1044's diagnosis"; fi

# ---- assertion-count guard -------------------------------------------------
# The summary reports assertions that RAN. One that never ran is invisible to
# it: a typo'd helper is `command not found` at rc 127, tallied by nothing, and
# the footer still says ALL TESTS PASSED with a quieter number. This suite has
# no conditional cases, so the count is exact. Bump it deliberately when adding
# a case; a DROP means a case stopped running.
#
# This is the same protection this branch relied on elsewhere, and it is not
# decoration: `test-summary-honesty-manifest` flagged this very file as
# `ledger=no::count=none` when it was first written.
_EXPECTED_ASSERTIONS=85
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' \
        "$_ran" "$_EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
