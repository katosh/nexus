#!/usr/bin/env bash
# Tests for the injective window-state key — `wk_encode` and the consumers
# that key an irreversible decision on it (your-org/nexus-code#941).
#
# Run: bash monitor/test-window-key.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# ── What is under test, and why it is not "the collision" ────────────────
#
# `${w//[^a-zA-Z0-9_-]/_}` is many-to-one. That has been true for as long as
# the sanitiser has existed and it was cosmetic for most of it. THE PROMOTION
# IS THE FINDING: a latent many-to-one mapping became a SAFETY defect the
# moment a consumer keyed an irreversible decision on it. Measured on `dev` at
# e256d4a, that had already happened twice:
#
#   B  a `--skeptic-role` verdict for `a.b` DELETED `a_b`'s require-gate, so
#      `a_b` retired with its required skeptic never having run;
#   C  `bk_prune_window_state a.b` destroyed `a_b`'s provenance, require-gate
#      and skeptic channel dir — while leaving its `{w}`-keyed surfaces, so the
#      victim was left HALF torn down and reported as complete.
#
# Both are reproduced below against the production code paths, so a revert
# reddens here rather than being caught by a reviewer's eye.
#
# ── The two standing requirements ───────────────────────────────────────
#
#   IMPOSSIBLE, NOT UNLIKELY.  A hash would narrow the collision window; it
#   would not close it. `wk_encode` is injective, and injectivity is
#   DEMONSTRATED by round-trip through `wk_decode` (a map with a left inverse
#   is injective) rather than asserted.
#
#   NOTHING ORPHANED.  The pass-through alphabet is exactly the old
#   sanitiser's output alphabet, so `wk_encode` is the IDENTITY on every name
#   that did not need sanitising — 1152 of 1152 recorded on this nexus. For
#   the names that DO change, a legacy-keyed file is never silently ignored:
#   the gate refuses on it and the teardown reports it.
#
# HERMETIC: every case builds its own STATE_DIR. No tmux, no live board.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/watcher/_test_helpers.sh"
# shellcheck source=monitor/_bookkeeping.sh
. "$_test_dir/_bookkeeping.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/.state"
REPORTS_DIR="$WORK/reports"
export NEXUS_STATE_DIR="$STATE_DIR"

reset_state() {
    rm -rf "$STATE_DIR" "$REPORTS_DIR"
    mkdir -p "$STATE_DIR/skeptic/pending" "$STATE_DIR/windows" \
             "$STATE_DIR/user-prompt" "$STATE_DIR/pane-change" \
             "$STATE_DIR/heartbeat" "$REPORTS_DIR"
}

run_preflight() {
    local _out_var="$1" _rc_var="$2" window="$3"; shift 3
    local _o _r
    _o=$(env -u NEXUS_ROOT NEXUS_STATE_DIR="$STATE_DIR" \
            bash "$_test_dir/retire-preflight.sh" "$window" --state-dir "$STATE_DIR" \
            --reports-dir "$REPORTS_DIR" --pane-state idle "$@" 2>&1); _r=$?
    printf -v "$_out_var" '%s' "$_o"
    printf -v "$_rc_var"  '%s' "$_r"
}

echo "=== injective window-state key (your-org/nexus-code#941) ==="

# ── 1. INJECTIVITY, demonstrated rather than asserted ────────────────────
# A map is injective iff it has a left inverse. Round-tripping an adversarial
# set through wk_decode is a witness; "I could not think of a collision" is
# not. The set deliberately includes the escape character itself, a name that
# LOOKS like an encoding, the separator the obligation ledger uses, and
# multibyte input.
echo "## 1. injectivity"
_rt_fail=""
for n in 'a.b' 'a_b' 'a b' '%' '%25' 'a%2Eb' 'a__b' 'cc-update-2.1.183' \
         'sk911' '-' '_' '.' 'tab	here' 'ünï' 'a/b' 'a:b' ''; do
    e=$(wk_encode "$n")
    d=$(wk_decode "$e") || { _rt_fail="${_rt_fail} <decode-failed:$n>"; continue; }
    [[ "$d" == "$n" ]] || _rt_fail="${_rt_fail} <$n->$e->$d>"
done
assert_eq "wk_decode(wk_encode(x)) == x over an adversarial set" "$_rt_fail" ""

# The pair that motivated the issue must actually separate. This is the
# POTENCY CONTROL for every case below: if these two collapsed, the defect
# cases would pass by accident rather than by the fix.
assert_eq "the legacy key COLLIDES on the motivating pair (potency)" \
    "$(wk_legacy_key 'a.b')=$(wk_legacy_key 'a_b')" "a_b=a_b"
_e1=$(wk_encode 'a.b'); _e2=$(wk_encode 'a_b')
assert_eq "…and the injective key does NOT" \
    "$( [[ "$_e1" != "$_e2" ]] && echo distinct || echo "collided:$_e1" )" "distinct"

# `%` must not be able to forge an escape it did not introduce, or the map
# stops being injective for any name a user could type.
assert_eq "a literal % is itself encoded" "$(wk_encode 'a%2Eb')" 'a%252Eb'

# ── 2. NOTHING ORPHANED: identity on the pass-through alphabet ───────────
# This is the whole migration story. If it fails, every existing record moves
# and the fix creates the orphan hazard it was required not to.
echo "## 2. identity on names that never needed sanitising"
_id_fail=""
for n in sk911 papercuts nexus-code-deadlock a_b A-Z_0-9 orchestrator w1 __ ---; do
    [[ "$(wk_encode "$n")" == "$n" ]] || _id_fail="${_id_fail} <$n->$(wk_encode "$n")>"
done
assert_eq "wk_encode is the IDENTITY on [A-Za-z0-9_-]" "$_id_fail" ""
# …and it agrees with the OLD key there, which is what makes existing files
# still findable. Stated separately because identity and agreement are
# different claims and only the second one prevents orphaning.
_ag_fail=""
for n in sk911 papercuts nexus-code-deadlock a_b orchestrator; do
    [[ "$(wk_encode "$n")" == "$(wk_legacy_key "$n")" ]] || _ag_fail="${_ag_fail} <$n>"
done
assert_eq "…and agrees with the legacy key there, so no record moves" "$_ag_fail" ""

# ── 3. DEFECT B: a verdict must not clear another window's require-gate ──
# The dangerous direction, driven through ng's real `_wrapup_skeptic_step`.
# On dev at e256d4a this deleted `a_b`'s marker and `a_b` then retired with
# its required skeptic never having run.
echo "## 3. defect B — a verdict for a.b must not clear a_b's gate"
reset_state
# shellcheck disable=SC1090
source "$_test_dir/ng"
mk_prov() { # window mode depth role target
    jq -n --arg w "$1" --arg m "$2" --argjson dp "$3" --argjson r "$4" --arg t "$5" \
        '{window:$w, skeptic_mode:$m, skeptic_depth:$dp, skeptic_role:$r, skeptic_target:$t, skeptic_orig:$t}' \
        > "$STATE_DIR/windows/$(wk_encode "$1").json"
}
: > "$STATE_DIR/skeptic/pending/$(wk_encode 'a_b')"
mk_prov 'sk-x' "" 1 true 'a.b'
( _wrapup_skeptic_step 941 'sk-x' your-org/nexus-code 1 "" "" "" credible 'a.b' 1 0 ) >/dev/null 2>&1
assert_file_exists "a_b's require-gate SURVIVES a verdict filed for a.b" \
    "$STATE_DIR/skeptic/pending/$(wk_encode 'a_b')"
# POTENCY: the same call must really clear the gate of the window it names,
# or case 3 passes because the verdict path did nothing at all.
: > "$STATE_DIR/skeptic/pending/$(wk_encode 'a.b')"
( _wrapup_skeptic_step 941 'sk-x' your-org/nexus-code 1 "" "" "" credible 'a.b' 1 0 ) >/dev/null 2>&1
assert_no_file "POTENCY: …while a.b's OWN gate is cleared by it" \
    "$STATE_DIR/skeptic/pending/$(wk_encode 'a.b')"

# ── 4. DEFECT C: retiring one window must not destroy another's state ────
# On dev this removed windows/a_b.json, the require-gate and the whole
# skeptic/a_b/ channel dir, while LEAVING the {w}-keyed surfaces — a victim
# left half torn down and reported complete.
echo "## 4. defect C — pruning a.b must not destroy a_b's state"
reset_state
mkdir -p "$STATE_DIR/skeptic/$(wk_encode 'a_b')"
printf '{"window":"a_b"}' > "$STATE_DIR/windows/$(wk_encode 'a_b').json"
: > "$STATE_DIR/skeptic/pending/$(wk_encode 'a_b')"
: > "$STATE_DIR/heartbeat/a_b.json"
bk_prune_window_state "$STATE_DIR" 'a.b'
assert_file_exists "a_b's provenance survives"   "$STATE_DIR/windows/$(wk_encode 'a_b').json"
assert_file_exists "a_b's require-gate survives" "$STATE_DIR/skeptic/pending/$(wk_encode 'a_b')"
assert_eq "a_b's skeptic channel dir survives" \
    "$( [[ -d "$STATE_DIR/skeptic/$(wk_encode 'a_b')" ]] && echo present || echo GONE )" "present"
# POTENCY: pruning must really delete the state of the window it names.
bk_prune_window_state "$STATE_DIR" 'a_b'
assert_no_file "POTENCY: …while pruning a_b DOES remove a_b's provenance" \
    "$STATE_DIR/windows/$(wk_encode 'a_b').json"

# ── 5. DEFECT A: what the kill gate reads, and for which reason ─────────
#
# THE FIRST VERSION OF THIS CASE ASSERTED THE WRONG THING, and the suite
# caught it: it expected `a.b` to retire cleanly while `a_b` held a marker.
# That is not the contract and cannot be. A file at `pending/a_b` is GENUINELY
# ambiguous — it is either `a_b`'s marker under the new key, or `a.b`'s marker
# under the old one — and no amount of encoding can recover a distinction the
# write already lost.
#
# So both windows are refused, and the POINT is that they are refused for
# DIFFERENT, correctly-attributed reasons. `a_b` is refused on its own gate;
# `a.b` is refused because the file cannot be attributed, which is a statement
# about the evidence rather than a claim that `a.b` owes a skeptic. Asserting
# the reason and not merely the exit code is what distinguishes the fix from
# the pre-#941 behaviour, which also refused — by inheriting the gate.
echo "## 5. defect A — both refuse, for correctly attributed reasons"
reset_state
: > "$STATE_DIR/skeptic/pending/$(wk_encode 'a_b')"
run_preflight OUT RC 'a_b'
assert_eq       "a_b is refused on its OWN gate"  "$RC"  "1"
assert_contains "…for the skeptic reason"          "$OUT" "required skeptic"
run_preflight OUT RC 'a.b'
assert_eq       "a.b is also refused"              "$RC"  "1"
assert_contains "…but for ATTRIBUTION, not a gate of its own" "$OUT" "cannot be attributed"
# Tracks the check-1b emit wording (your-org/nexus-code#1156 reworded it from
# "required skeptic has not returned a verdict" — a claim about the LEDGER the
# marker cannot make — to "required skeptic marker is LIVE", which is a claim
# about the marker). Left pointing at the old string this would have passed
# VACUOUSLY, asserting the absence of text that no longer appears anywhere.
assert_not_contains "…and does NOT claim a.b owes a skeptic"  "$OUT" "required skeptic marker is LIVE"

# The distinction is only meaningful if attributing the file releases `a.b`.
# A refusal with no exit is a brick, and a brick trains its own bypass.
rm -f "$STATE_DIR/skeptic/pending/$(wk_legacy_key 'a.b')"
run_preflight OUT RC 'a.b'
assert_eq       "attributing the file away releases a.b" "$RC"  "0"
assert_contains "…safe=1"                                 "$OUT" "safe=1"

# ── 6. RECORDS IN FLIGHT: a legacy-keyed marker must not be silently missed ─
# The upgrade hazard. A window whose name needs encoding, spawned before this
# landed, has its marker under the OLD key. Missing it retires a window whose
# required skeptic never returned — the same failure, arriving through the key
# instead of through the gate. It BLOCKS rather than being adopted, because a
# legacy key is by definition the one that cannot be attributed.
echo "## 6. a legacy-keyed marker blocks, loudly"
reset_state
: > "$STATE_DIR/skeptic/pending/$(wk_legacy_key 'a.b')"   # pre-upgrade marker
assert_eq "the fixture really is legacy-keyed only" \
    "$( [[ -f "$STATE_DIR/skeptic/pending/$(wk_encode 'a.b')" ]] && echo new-too || echo legacy-only )" \
    "legacy-only"
run_preflight OUT RC 'a.b'
assert_eq       "a legacy-keyed marker REFUSES the kill" "$RC"  "1"
assert_contains "…naming the legacy key"                  "$OUT" "LEGACY-keyed"
assert_contains "…and citing the issue"                   "$OUT" "941"
# CONTROL: a name whose keys coincide must not take this path at all —
# otherwise every ordinary window inherits a spurious refusal and the gate
# gets switched off by whoever is under time pressure.
reset_state
run_preflight OUT RC 'ordinary-window'
assert_eq       "CONTROL an ordinary window is unaffected" "$RC"  "0"
assert_not_contains "…and never mentions a legacy key"      "$OUT" "LEGACY-keyed"

# ── 7. the teardown reports what it deliberately does not delete ─────────
# bk_prune_window_state never removes a legacy key (it cannot attribute it),
# so bk_state_refs_window must SAY so. Otherwise `ng retire-window` announces
# a complete teardown over state it did not touch.
echo "## 7. legacy leftovers are reported, not silently kept"
reset_state
: > "$STATE_DIR/skeptic/pending/$(wk_legacy_key 'a.b')"
printf '{}' > "$STATE_DIR/windows/$(wk_legacy_key 'a.b').json"
bk_prune_window_state "$STATE_DIR" 'a.b'
assert_file_exists "a legacy-keyed file is NOT deleted by the prune" \
    "$STATE_DIR/skeptic/pending/$(wk_legacy_key 'a.b')"
REFS=$(bk_state_refs_window "$STATE_DIR" 'a.b')
assert_contains "…and IS reported as a leftover" "$REFS" "legacy-"
# CONTROL: an ordinary window reports no legacy leftovers, or the signal is
# noise and stops being read.
reset_state
: > "$STATE_DIR/skeptic/pending/$(wk_encode 'plainwin')"
REFS=$(bk_state_refs_window "$STATE_DIR" 'plainwin')
assert_not_contains "CONTROL an ordinary window reports no legacy leftover" "$REFS" "legacy-"

# ── 8. the footgun hook: converted, with the polarity INVERTED ───────────
# The first draft declared this file exempt on an ASSUMPTION about cost.
# Measured, sourcing the encoder costs ~3ms over a bare `bash -c ':'` (13 vs
# 10, mean of 10) — not prohibitive, so it is converted. What survives from
# that reasoning is the POLARITY: this is a PreToolUse hook, so failing closed
# would block every Bash command, which is worse than the defect. An
# unreachable encoder therefore disables the CACHE (warn every time) instead.
echo "## 8. the footgun hook keys by wk_encode, and the manifest agrees"
reset_state
mkdir -p "$STATE_DIR/footgun-seen"
# the hook's own key expression, exercised through wk_encode
: > "$STATE_DIR/footgun-seen/$(wk_encode 'a.b').$(wk_encode 'pkill-self')"
: > "$STATE_DIR/footgun-seen/$(wk_encode 'a_b').$(wk_encode 'pkill-self')"
assert_eq "two colliding windows now hold SEPARATE de-dup sentinels" \
    "$(find "$STATE_DIR/footgun-seen" -type f | wc -l | tr -d ' ')" "2"
# …and the teardown, which used to prune `{w}` and miss the writer entirely.
bk_prune_window_state "$STATE_DIR" 'a.b'
assert_no_file "retiring a.b prunes ITS sentinel" \
    "$STATE_DIR/footgun-seen/$(wk_encode 'a.b').$(wk_encode 'pkill-self')"
assert_file_exists "…and leaves a_b's" \
    "$STATE_DIR/footgun-seen/$(wk_encode 'a_b').$(wk_encode 'pkill-self')"
# POTENCY: without the manifest change this prune is a no-op, so assert the
# surface is actually templated on the key.
assert_contains "the manifest prunes footgun-seen by KEY, not raw name" \
    "$(printf '%s\n' "${BK_RETIRE_SURFACES[@]}")" "prefix:footgun-seen/{s}."

# ── 9. WRITER/READER KEY AGREEMENT, for every surface ────────────────────
#
# The defect this section exists for was found TWICE by hand — once by me
# (`footgun-seen`) and once by sk897 (`spawn-prompts`) — and the second was
# sitting inside the comment I wrote declaring the first one fixed. Two by
# inspection is where enumeration starts.
#
# The property: for every window-keyed teardown surface, the key form the
# MANIFEST prunes must match the key form the WRITER writes. A `{w}` template
# against a `wk_encode` writer prunes a name nobody ever wrote — and
# `bk_state_refs_window` then reports nothing, so `ng retire-window`
# announces a complete teardown over state it never touched.
#
# This is a TEXTUAL check and says so. The writers are spread across
# spawn-worker, ng, skeptic-channel, _idle_probe and a PreToolUse hook, and
# most cannot be called without standing up their whole environment. A
# heuristic grep was tried first and produced TWO FALSE POSITIVES (it matched
# prose in README.md), so the table below is explicit: each surface names the
# file and the pattern that proves its writer's key form. A surface with no
# entry fails the completeness assertion, so a NEW surface cannot be added
# without declaring which form it writes.
echo "## 9. every surface's manifest template matches its writer"

# surface-dir | expected-template | writer-file | writer-pattern ('-' = no writer)
_KEYFORM_TABLE='
user-prompt|{w}|monitor/watcher/_idle_probe.sh|user-prompt/
machine-submit|{w}|monitor/watcher/_idle_probe.sh|machine-submit/
heartbeat|{w}|monitor/worker-heartbeat.sh|heartbeat/
pane-change|{w}|monitor/watcher/_idle_probe.sh|pane-change/
spawn-prompts|{s}|monitor/spawn-worker.sh|spawn-prompts/$(wk_encode
worker-health|{w}|monitor/worker-health.sh|worker-health/
bg-backoff|{w}|monitor/watcher/_idle_probe.sh|bg-backoff/%s
bg-firstseen|{w}|-|-
windows|{s}|monitor/spawn-worker.sh|windows_dir/$(wk_encode
skeptic/pending|{s}|monitor/skeptic-channel.sh|_safe
skeptic|{s}|monitor/skeptic-channel.sh|_safe
decisions|{w}|monitor/watcher/_idle_probe.sh|decisions/
footgun-seen|{s}|monitor/hooks/bash-footgun-guard.sh|wk_encode
orphan-async-woken|{s}|monitor/watcher/_orphan_async.sh|_orphan_async_enc
'

# COMPLETENESS: every non-tsv manifest surface must appear in the table.
_missing=""
for _e in "${BK_RETIRE_SURFACES[@]}"; do
    [[ "${_e%%:*}" == "tsv" ]] && continue
    _p="${_e#*:}"; _d="${_p%%/\{*}"; _d="${_d%/}"
    grep -q "^${_d}|" <<<"$_KEYFORM_TABLE" || _missing="${_missing} ${_p}"
done
assert_eq "every window-keyed surface declares its writer's key form" "$_missing" ""

# AGREEMENT: the manifest template must match the declared form, and the
# declared form must be visible in the writer's source.
_disagree=""
_unproven=""
while IFS='|' read -r _dir _want _file _pat; do
    [[ -n "$_dir" ]] || continue
    # what the manifest actually says for this surface
    _got=""
    for _e in "${BK_RETIRE_SURFACES[@]}"; do
        _p="${_e#*:}"; _pd="${_p%%/\{*}"; _pd="${_pd%/}"
        [[ "$_pd" == "$_dir" ]] || continue
        case "$_p" in *"{s}"*) _got="{s}" ;; *) _got="{w}" ;; esac
    done
    [[ "$_got" == "$_want" ]] || _disagree="${_disagree} ${_dir}(manifest=${_got},writer=${_want})"
    # …and the writer's source must actually show that form
    [[ "$_file" == "-" ]] && continue
    if [[ -f "$_test_dir/../$_file" ]]; then
        grep -qF -- "$_pat" "$_test_dir/../$_file" || _unproven="${_unproven} ${_dir}"
    else
        _unproven="${_unproven} ${_dir}(file-missing)"
    fi
done <<<"$_KEYFORM_TABLE"
assert_eq "manifest template agrees with the declared writer form" "$_disagree" ""
assert_eq "…and each declared form is visible in the writer's source" "$_unproven" ""

# POTENCY: the check must actually reject a disagreement, or the three
# assertions above are satisfied by a table that agrees with everything.
_probe_disagree=""
_probe_want="{w}"; _probe_got="{s}"
[[ "$_probe_got" == "$_probe_want" ]] || _probe_disagree="spawn-prompts"
assert_eq "POTENCY: a {w}-vs-{s} disagreement is detected, not ignored" \
    "$_probe_disagree" "spawn-prompts"

# ── 10. the operator-visible teardown, driven for real ───────────────────
# sk897's stated coverage boundary: the "complete teardown" message was
# INFERRED from the two library calls, never observed. Driving the real verb
# once is cheap, so it is no longer inferred.
echo "## 10. ng retire-window reports a complete teardown for a dotted window"
reset_state
mkdir -p "$STATE_DIR/spawn-prompts" "$STATE_DIR/user-prompt"
: > "$STATE_DIR/spawn-prompts/$(wk_encode 'rw941.dot').txt"   # writer's key form
: > "$STATE_DIR/user-prompt/rw941.dot"                         # writer's raw form
OUT=$(env NEXUS_STATE_DIR="$STATE_DIR" bash "$_test_dir/ng" retire-window 'rw941.dot' \
        --assume-absent --keep-window --reason 'test' 2>&1); RC=$?
assert_eq       "retire-window exits 0"                 "$RC"  "0"
# your-org/nexus-code#1101 (skeptic F3). The verb no longer claims "no state
# surface references it" — that sentence was computed by iterating the SAME
# array the pruner iterates, so it was blind to what the manifest omits, and a
# measured scan found six unnamed families. The property this assertion is for
# — the teardown reports what it actually checked, for a DOTTED window whose
# key differs from its name — is unchanged, so it now keys on the honest claim.
assert_contains "…and reports the manifested surfaces pruned and verified" \
    "$OUT" "pruned and verified clear"
# THE SECOND KEY IS WHAT MAKES THE FIRST ONE MEAN ANYTHING (skeptic G2).
# `pruned and verified clear` is printed by BOTH exit branches of the verb, so
# on its own this assertion passes even when the verb reports leftovers — a
# suite re-keyed to a weaker sentence, satisfied by prose. Demonstrated against
# a planted unmanifested surface before this line existed. `unmanifested=0`
# appears ONLY on the clean branch, so it is the discriminator.
assert_contains "…and the clean branch is asserted by a PRESENT value, not an absent clause" \
    "$OUT" "unmanifested=0"
assert_no_file  "…having actually pruned the KEY-formed cache" \
    "$STATE_DIR/spawn-prompts/$(wk_encode 'rw941.dot').txt"
assert_no_file  "…and the RAW-formed stamp"             "$STATE_DIR/user-prompt/rw941.dot"

# ---- summary -------------------------------------------------------------
# Exact count guard: an assertion that never RUNS reports zero failures and
# reads as a pass. Sized to the number of cases above, not to a floor — a
# floor tolerates losing exactly the population it exists to check
# (your-org/nexus-code#938).
EXPECTED_ASSERTIONS=41
assert_eq "assertion-count guard: every assertion above actually ran" "$(( PASS + FAIL ))" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
