#!/usr/bin/env bash
# Guard: the per-window stamp's CLEAR resolves the SAME path its WRITER wrote
# (your-org/nexus-code#1143).
#
# Run: bash monitor/watcher/test-stamp-clear-splitbrain.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# ===========================================================================
# THE DEFECT
# ===========================================================================
#
# Both stamp writers honour `NEXUS_STATE_DIR`:
#
#   over-limit-emit.sh    state_dir="${NEXUS_STATE_DIR:-$root/monitor/.state}"
#   turn-failure-emit.sh  if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then state_dir=…
#
# Their `Stop`-hook CLEARS did not. All three were bare `rm -f` string literals
# inside the settings JSON hardcoding `$NEXUS_ROOT/monitor/.state`:
#
#   worker-settings.json        over-limit    (…and `$NEXUS_WORKER_WINDOW` UNQUOTED)
#   worker-settings.json        turn-failure  (…same)
#   orchestrator-settings.json  over-limit
#
# So under ANY state-dir override the stamp is written where `pane-state.sh`
# reads it and cleared where nobody wrote, and the cleanup contract both
# writers document — "the file persists until a successful Stop event clears
# it" — is unreachable by construction.
#
# WHY IT NEEDED A GUARD RATHER THAN A CAREFUL READ. Every failure mode here is
# SILENT AND SUCCESSFUL. `rm -f` on a path that does not exist prints nothing
# and exits 0, so the clear reports success for a stamp it never touched; the
# unquoted-window form expands to `…/over-limit/.json` and does the same. That
# is this workspace's dominant defect class — a manufactured success whose only
# evidence is an absence — and no amount of reading the JSON surfaces it,
# because the JSON is not wrong on its face. It is wrong RELATIVE TO A SECOND
# FILE.
#
# WHY IT IS EXPENSIVE. `pane-state.sh` §1b short-circuits to
# `state=over-limit` on the stamp's presence and returns BEFORE inspecting the
# pane. An unclearable stamp is therefore a PERMANENT false `over-limit` for
# that pane — read by the watcher's scan, the orchestrator emit gate, the
# wake-paste path and `retire-preflight.sh` alike. `#1141` measured what a
# stamp that merely cleared LATE cost; one that cannot clear at all is strictly
# worse, which is why `#1143` is sequenced ahead of `#1155`.
#
# ===========================================================================
# WHAT THIS SUITE ASSERTS, AND WHY IT IS A ROUND TRIP
# ===========================================================================
#
# The property is a RELATION between two programs, so neither program can be
# tested alone. Asserting that the clear removes a file the TEST planted would
# pass with the writer resolving somewhere else entirely — it would test the
# clear against the test's belief about the path, which is precisely the second
# implementation whose drift caused this. So every functional assertion below
# runs the REAL writer to create the stamp and the REAL clear to remove it, and
# the test never names the path itself.
#
# The POTENCY control runs the OLD hardcoded form against the same fixture and
# requires it to FAIL. Without that, "the clear removed the stamp" is a green
# from an instrument nobody has seen fire — the override could be inert, the
# fixture could be misbuilt, and the assertion would pass anyway.
#
# ===========================================================================
# HERMETICITY: THE AMBIENT WORKER ENV CONTAMINATES THIS SUITE
# ===========================================================================
#
# Measured while writing it. A nexus worker runs with `NEXUS_WORKER_WINDOW` and
# `TMUX_PANE` exported, and `env FOO=bar cmd` INHERITS them. Two fixture cases
# built with `env NEXUS_STATE_DIR=… NEXUS_ORCHESTRATOR_WINDOW=…` silently
# resolved to the RUNNING AGENT'S OWN window (`olimit2`) rather than the
# fixture's: one case then "passed" while clearing a file the fixture never
# created, and the window-unresolvable case never reached its unresolvable
# branch at all.
#
# That is the `#1117` shape — a suite reading the live environment instead of
# its fixture — and it fails in the direction that reads as success. Every
# invocation below therefore goes through `_sc_env`, which `env -u`s all three
# window inputs before setting the ones the case means to set. It is not
# optional politeness: without it this suite tests the operator's board.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
. "$_test_dir/_test_helpers.sh"

HOOKS="$REPO_ROOT/monitor/hooks"
WRITER_OL="$HOOKS/over-limit-emit.sh"
WRITER_TF="$HOOKS/turn-failure-emit.sh"
CLEAR="$HOOKS/stamp-clear.sh"
RESOLVER="$HOOKS/_stamp_path.sh"
SETTINGS=( "$REPO_ROOT/monitor/worker-settings.json"
           "$REPO_ROOT/monitor/orchestrator-settings.json" )

# --- the `--population` protocol (your-org/nexus-code#803) -----------------
# Declared so this guard is not one of the ~353 suites INVISIBLE to
# `guards-for-diff` — the blind spot that let `#1164` reach `dev`. An edit to
# either writer, the resolver, the clear, or either settings JSON must select
# this suite.
_sc_population_files() {
    printf '%s\n' "$WRITER_OL" "$WRITER_TF" "$CLEAR" "$RESOLVER" \
        "${SETTINGS[@]}" "$_test_dir/_test_helpers.sh"
}
. "$_test_dir/../_guard_population.sh"
gp_population() { _sc_population_files; }
gp_handle "$@"

command -v jq >/dev/null 2>&1 || th_abort "jq is required to drive the real writers"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/stampclear.XXXXXX") || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# A real rate_limit StopFailure payload, in the shape 17 production captures
# confirmed (`.error` is a STRING; the reset time rides inside
# `last_assistant_message`).
PAYLOAD_RL='{"hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"You'"'"'ve hit your weekly limit · resets 3am (America/Los_Angeles)","session_id":"sess-fixture","transcript_path":"/dev/null","cwd":"/tmp"}'
# A non-rate-limit failure, which is `turn-failure-emit.sh`'s territory.
PAYLOAD_TF='{"hook_event_name":"StopFailure","error":"server_error","last_assistant_message":"API Error: 500 Internal server error","session_id":"sess-fixture","transcript_path":"/dev/null","cwd":"/tmp"}'

# Every hook invocation goes through here. The `env -u`s are the hermeticity
# fix described in the header — without them this suite reads the running
# agent's own window and tests the operator's board.
_sc_env() {   # <VAR=VAL>… -- <cmd>…
    local -a assigns=()
    while (( $# )) && [[ "$1" != "--" ]]; do assigns+=( "$1" ); shift; done
    shift || true
    env -u NEXUS_WORKER_WINDOW -u NEXUS_ORCHESTRATOR_WINDOW -u TMUX_PANE \
        -u NEXUS_STATE_DIR -u NEXUS_STAMP_CLEAR_DEBUG \
        "${assigns[@]}" "$@"
}

# ===========================================================================
# 1. THE CORE PROPERTY: writer and clear agree under a state-dir OVERRIDE
# ===========================================================================
# This is the case `#1143` is about, and the one the old form could not pass.

C1="$WORK/c1"; mkdir -p "$C1/state" "$C1/root/monitor/.state"
_sc_env NEXUS_ROOT="$C1/root" NEXUS_STATE_DIR="$C1/state" NEXUS_WORKER_WINDOW=wkA \
    -- bash "$WRITER_OL" <<<"$PAYLOAD_RL"
assert_file_exists "override: the REAL writer stamps under NEXUS_STATE_DIR" \
    "$C1/state/over-limit/wkA.json"

_sc_env NEXUS_ROOT="$C1/root" NEXUS_STATE_DIR="$C1/state" NEXUS_WORKER_WINDOW=wkA \
    -- bash "$CLEAR" over-limit
assert_no_file "override: …and the REAL clear removes THAT file" \
    "$C1/state/over-limit/wkA.json"

# ---- POTENCY. The old form, same fixture, must FAIL to clear. -------------
# Run as the JSON spelled it, `$NEXUS_WORKER_WINDOW` unquoted and all. Without
# this the assertion above is a green from an instrument nobody has seen fire.
C2="$WORK/c2"; mkdir -p "$C2/state" "$C2/root/monitor/.state"
_sc_env NEXUS_ROOT="$C2/root" NEXUS_STATE_DIR="$C2/state" NEXUS_WORKER_WINDOW=wkA \
    -- bash "$WRITER_OL" <<<"$PAYLOAD_RL"
_sc_env NEXUS_ROOT="$C2/root" NEXUS_STATE_DIR="$C2/state" NEXUS_WORKER_WINDOW=wkA \
    -- bash -c 'rm -f $NEXUS_ROOT/monitor/.state/over-limit/$NEXUS_WORKER_WINDOW.json'
assert_file_exists "POTENCY: the OLD hardcoded clear leaves the stamp behind (the defect)" \
    "$C2/state/over-limit/wkA.json"
assert_eq "POTENCY: …and it exits 0 while doing so — the silence that hid this" \
    "$( _sc_env NEXUS_ROOT="$C2/root" NEXUS_STATE_DIR="$C2/state" NEXUS_WORKER_WINDOW=wkA \
          -- bash -c 'rm -f $NEXUS_ROOT/monitor/.state/over-limit/$NEXUS_WORKER_WINDOW.json; echo $?' )" \
    "0"

# ===========================================================================
# 2. THE PRODUCTION PATH IS UNCHANGED
# ===========================================================================
# On the live board `NEXUS_STATE_DIR` is unset, so both forms resolve
# identically. Asserted because this change touches three live hook entries and
# "it is correct under the override" is worth nothing if it regressed the case
# that actually runs.

C3="$WORK/c3"; mkdir -p "$C3/root/monitor/.state"
_sc_env NEXUS_ROOT="$C3/root" NEXUS_WORKER_WINDOW=wkB \
    -- bash "$WRITER_OL" <<<"$PAYLOAD_RL"
assert_file_exists "no override: the writer stamps under \$NEXUS_ROOT/monitor/.state" \
    "$C3/root/monitor/.state/over-limit/wkB.json"
_sc_env NEXUS_ROOT="$C3/root" NEXUS_WORKER_WINDOW=wkB \
    -- bash "$CLEAR" over-limit
assert_no_file "no override: …and the clear removes it, exactly as the old form did" \
    "$C3/root/monitor/.state/over-limit/wkB.json"

# ===========================================================================
# 3. THE SECOND STAMP KIND — the instance `#1143` does not name
# ===========================================================================
# `turn-failure-emit.sh` honours the override too, and its clear sat one line
# below the over-limit one in `worker-settings.json` with the identical defect.
# A fix that repaired only the named instance would leave this one live.

C4="$WORK/c4"; mkdir -p "$C4/state" "$C4/root/monitor/.state"
_sc_env NEXUS_ROOT="$C4/root" NEXUS_STATE_DIR="$C4/state" NEXUS_WORKER_WINDOW=wkC \
    -- bash "$WRITER_TF" <<<"$PAYLOAD_TF"
assert_file_exists "turn-failure: the REAL writer stamps under NEXUS_STATE_DIR" \
    "$C4/state/turn-failure/wkC.json"
_sc_env NEXUS_ROOT="$C4/root" NEXUS_STATE_DIR="$C4/state" NEXUS_WORKER_WINDOW=wkC \
    -- bash "$CLEAR" turn-failure
assert_no_file "turn-failure: …and the REAL clear removes THAT file" \
    "$C4/state/turn-failure/wkC.json"

# ===========================================================================
# 4. THE ORCHESTRATOR PANE
# ===========================================================================
# Its stamp is written under `NEXUS_ORCHESTRATOR_WINDOW`. The worker clear
# could never have addressed it; the orchestrator's own clear hardcoded the
# state dir. Both are the same resolver now.

C5="$WORK/c5"; mkdir -p "$C5/state" "$C5/root/monitor/.state"
_sc_env NEXUS_ROOT="$C5/root" NEXUS_STATE_DIR="$C5/state" NEXUS_ORCHESTRATOR_WINDOW=orchestrator \
    -- bash "$WRITER_OL" <<<"$PAYLOAD_RL"
assert_file_exists "orchestrator: the writer stamps under NEXUS_ORCHESTRATOR_WINDOW" \
    "$C5/state/over-limit/orchestrator.json"
_sc_env NEXUS_ROOT="$C5/root" NEXUS_STATE_DIR="$C5/state" NEXUS_ORCHESTRATOR_WINDOW=orchestrator \
    -- bash "$CLEAR" over-limit
assert_no_file "orchestrator: …and the clear removes it" \
    "$C5/state/over-limit/orchestrator.json"

# ===========================================================================
# 5. FAIL-CLOSED: an unresolvable window clears NOTHING
# ===========================================================================
# The old worker form expanded to `…/over-limit/.json` with the window unset —
# a real path, silently removed if it ever existed. The resolver refuses to
# compose a path it cannot fully resolve, and the clear tests the result rather
# than interpolating it.

C6="$WORK/c6"; mkdir -p "$C6/state/over-limit" "$C6/root/monitor/.state"
: > "$C6/state/over-limit/.json"
_sc_env NEXUS_ROOT="$C6/root" NEXUS_STATE_DIR="$C6/state" -- bash "$CLEAR" over-limit
assert_file_exists "no window: the bare \`.json\` landmine is NOT removed" \
    "$C6/state/over-limit/.json"
assert_eq "no window: …and the clear still exits 0 (a Stop hook must never fail a turn)" \
    "$( _sc_env NEXUS_ROOT="$C6/root" NEXUS_STATE_DIR="$C6/state" -- bash "$CLEAR" over-limit; echo $? )" \
    "0"

# A traversing kind must refuse rather than sanitise: the value reaches the
# clear from a hook command line and is about to be handed to `rm -f`.
C7="$WORK/c7"; mkdir -p "$C7/state/evil" "$C7/root/monitor/.state"
: > "$C7/state/evil/wkD.json"
_sc_env NEXUS_ROOT="$C7/root" NEXUS_STATE_DIR="$C7/state" NEXUS_WORKER_WINDOW=wkD \
    -- bash "$CLEAR" ../evil
assert_file_exists "unsafe kind: a traversing <kind> is REFUSED, not sanitised" \
    "$C7/state/evil/wkD.json"

# ===========================================================================
# 6. THE STATIC RATCHET: no settings JSON may hand-roll a clear again
# ===========================================================================
# The functional assertions above pin the behaviour of the code that exists.
# This one pins the SHAPE, so the next person editing a Stop block cannot
# reintroduce a bare `rm -f` that silently disagrees with the writer.

_sc_hardcoded_clears() {   # reads the settings JSONs; emits offending lines
    LC_ALL=C grep -nE 'rm -f[^"]*monitor/\.state/(over-limit|turn-failure)/' \
        "${SETTINGS[@]}" 2>/dev/null || true
}
_offenders=$(_sc_hardcoded_clears)
assert_empty "ratchet: no settings JSON hardcodes a stamp path in an \`rm -f\` clear" \
    "$_offenders"

# ---- POTENCY for the ratchet ---------------------------------------------
# Varying the axis the MECHANISM varies on — the JSON — with the predicate held
# constant. A ratchet that has never been shown to fire is prose.
C8="$WORK/c8"; mkdir -p "$C8"
cp "${SETTINGS[0]}" "$C8/planted.json"
# The plant APPENDS an offending entry rather than REPLACING the stamp-clear
# line. Replacing it anchors this control on the very line the wiring mutations
# above delete, so deleting that clear made this control fail for a reason that
# had nothing to do with the ratchet — a coupling that makes a mutation
# experiment ambiguous exactly when it is being relied on. Appending is
# independent of every other site.
jq '.hooks.Stop[0].hooks += [{"type":"command",
      "command":"rm -f $NEXUS_ROOT/monitor/.state/over-limit/$NEXUS_WORKER_WINDOW.json"}]' \
    "${SETTINGS[0]}" > "$C8/planted.json" 2>/dev/null || th_abort "jq plant failed"
_planted=$(LC_ALL=C grep -nE 'rm -f[^"]*monitor/\.state/(over-limit|turn-failure)/' \
    "$C8/planted.json" 2>/dev/null || true)
assert_contains "ratchet POTENCY: the same predicate REJECTS a planted old-form clear" \
    "$_planted" "monitor/.state/over-limit/"

# ===========================================================================
# 7. THE STRUCTURAL PROPERTY: one resolver, not two agreeing literals
# ===========================================================================
# The point of the fix is not that the two sides agree today — two string
# literals agreed today, before `NEXUS_STATE_DIR` was ever set. It is that they
# CANNOT disagree, because they call the same function. Asserted directly, so a
# future "simplification" that inlines the path back into either side is caught
# by something other than a reviewer's memory.

for _f in "$WRITER_OL" "$WRITER_TF" "$CLEAR"; do
    assert_eq "structure: $(basename "$_f") resolves its state dir via _stamp_path.sh" \
        "$( LC_ALL=C grep -cE '\. "\$_self_dir/_stamp_path\.sh"' "$_f" )" "1"
done

# ===========================================================================
# 7. THE CLEAR MUST BE WIRED AT ALL — absence is a defect, not a clean state
# ===========================================================================
# your-org/nexus-code#1171 skeptic finding 1, reproduced before being accepted:
# DELETING the orchestrator's over-limit clear outright left this suite at
# 18/0 and `test-settings-json` at 12/0. Both green, and the stamp would then
# never be cleared on any board — the permanent false `over-limit` this whole
# change exists to prevent, arrived at by removal rather than by divergence.
#
# WHY THE EARLIER ASSERTIONS DO NOT COVER IT, which is the instructive part.
# Section 1-5 drive `stamp-clear.sh` DIRECTLY, so they measure the script and
# say nothing about whether anything INVOKES it. Section 6 is a ratchet on
# `rm -f` shapes, and a deleted entry satisfies it vacuously — there is no
# hand-rolled clear precisely because there is no clear. A guard whose subject
# can be removed without it noticing is not guarding; it is describing.
#
# So the pair is: the clear must EXIST (here) and must not be HAND-ROLLED
# (section 6). Neither implies the other.

echo '=== 7. every stamp kind that is WRITTEN has a clear wired to Stop ==='

_sc_stop_clears() {   # <settings.json> -> the <kind> of each stamp-clear Stop hook
    jq -r '.hooks.Stop[]?.hooks[]?.command
           | select(. != null and test("stamp-clear\\.sh"))
           | sub("^.*stamp-clear\\.sh[[:space:]]+"; "")
           | split(" ")[0]' "$1" 2>/dev/null | LC_ALL=C sort -u
}

# ONE ASSERTION PER CLEAR SITE, deliberately, rather than one per file. A
# bundled "the worker clears both kinds" is satisfied-or-not as a unit, so
# deleting ONE of the two worker entries names the same assertion as deleting
# the other and the witness does not identify the site. Three sites, three
# assertions, three distinguishable reds.
#
# Each asserts the entry EXISTS **and routes through the resolver** — a Stop
# entry that ran some other command would satisfy mere presence while restoring
# exactly the split-brain this file is about.
_sc_site_wired() {   # <settings.json> <kind> -> `wired` | `MISSING`
    jq -r --arg k "$2" '[.hooks.Stop[]?.hooks[]?.command
                         | select(. != null)
                         | select(test("monitor/hooks/stamp-clear\\.sh[[:space:]]+" + $k + "$"))]
                        | if length > 0 then "wired" else "MISSING" end' "$1" 2>/dev/null
}

assert_eq "wiring W1: worker Stop -> stamp-clear.sh over-limit is PRESENT" \
    "$(_sc_site_wired "${SETTINGS[0]}" over-limit)" "wired"
assert_eq "wiring W2: worker Stop -> stamp-clear.sh turn-failure is PRESENT" \
    "$(_sc_site_wired "${SETTINGS[0]}" turn-failure)" "wired"
assert_eq "wiring W3: orchestrator Stop -> stamp-clear.sh over-limit is PRESENT" \
    "$(_sc_site_wired "${SETTINGS[1]}" over-limit)" "wired"

# Every kind WRITTEN by a hook registered in a settings file must have a clear
# in that same file. Derived rather than listed, so a third stamp kind added
# tomorrow is covered without editing this assertion.
# BOTH SIDES DERIVED (your-org/nexus-code#1171 R2-B). The clear side was already
# read from the JSON; the writer side used to be a hardcoded two-arm `case`,
# while this function's own docstring claimed a third stamp kind would be
# covered unedited. Measured: a planted third writer with no clear scored
# 23 passed / 0 failed. Coverage of today's tree was fine; the CLAIM was false,
# and a false claim is what the next author acts on — #1170's class, inside the
# guard written to close it.
#
# Derived instead from the hook SCRIPT each settings entry invokes: a stamp
# writer declares `dest_dir="$state_dir/<kind>"`, which names the kind at the
# only place that cannot drift from where the file actually lands.
_sc_written_kinds() {   # <settings.json> -> stamp kinds its hooks WRITE
    local f="$1" cmd script kind
    jq -r '.hooks | to_entries[] | .value[]?.hooks[]?.command // empty' "$f" 2>/dev/null \
      | while IFS= read -r cmd; do
            # the hook script path, if this entry invokes one under monitor/hooks
            # `sed -n 1p`, NOT `| head -1`: `head` closes the pipe early and so
            # joins the tracked early-exit-reader population
            # (early-exit-readers.manifest). These inputs are one short string
            # and one small file, so there is nothing to gain by exiting early
            # and no reason to enlarge that population.
            script=$(printf '%s' "$cmd" | grep -oE '[^ "]*monitor/hooks/[A-Za-z0-9_-]+\.sh' | sed -n '1p')
            [[ -n "$script" ]] || continue
            script="$REPO_ROOT/${script#*monitor/hooks/}"
            script="$REPO_ROOT/monitor/hooks/$(basename "$script")"
            [[ -r "$script" ]] || continue
            kind=$(grep -oE 'dest_dir="\$state_dir/[A-Za-z0-9_-]+"' "$script" 2>/dev/null \
                     | sed -n '1p' | sed -E 's|.*/([A-Za-z0-9_-]+)"$|\1|')
            [[ -n "$kind" ]] && printf '%s\n' "$kind"
        done | LC_ALL=C sort -u
}
_unclearable=""
for _f in "${SETTINGS[@]}"; do
    while IFS= read -r _k; do
        [[ -n "$_k" ]] || continue
        # `grep -qxF … <<<"$( … )"`, NOT `_sc_stop_clears … | grep -qxF`:
        # `grep -q` exits on its first match without draining, so under this
        # file's `set -o pipefail` the producer's EPIPE becomes the PIPELINE's
        # status and a kind that IS clearable reports rc 141 — a red on a true
        # membership (test-sigpipe-assertion-lint.sh, your-org/nexus-code#622).
        #
        # The rewrite is sound here because this is a pure EXISTENCE test, and
        # discarding the producer's status therefore costs nothing: a failing
        # `_sc_stop_clears` yields the EMPTY set, an empty set is a
        # non-membership, and a non-membership reddens at this very line. The
        # loud direction is preserved by the OUTPUT, not by the rc.
        grep -qxF "$_k" <<<"$(_sc_stop_clears "$_f")" \
            || _unclearable="$_unclearable $(basename "$_f"):$_k"
    done < <( _sc_written_kinds "$_f" )
done
assert_empty "wiring W4: no settings file WRITES a stamp kind it cannot CLEAR (derived, so a third kind is covered unedited)" "$_unclearable"

# ---- POTENCY. Delete the orchestrator clear and the wiring check must fire.
# This is the exact mutation the skeptic ran; without it, the three assertions
# above are a green from an instrument nobody has seen fire.
C9="$WORK/c9"; mkdir -p "$C9"
# `map(select(… | not))`, NOT `del(.[] | select(…))` — jq 1.5 (this host)
# rejects the latter, and a control that ABORTS is a control that never ran.
jq '.hooks.Stop[0].hooks |= map(select(.command | test("stamp-clear") | not))' \
    "${SETTINGS[1]}" > "$C9/orch-noclear.json" 2>/dev/null || th_abort "jq delete failed"
assert_eq "wiring W5 POTENCY: a DELETED clear reads MISSING (not a vacuously clean ratchet)" \
    "$(_sc_site_wired "$C9/orch-noclear.json" over-limit)" "MISSING"

# ---- assertion-count guard ----------------------------------------------
# `test-summary-honesty-manifest.sh` requires a ledger-carrying suite to pin its
# total. Rightly here above most places: every failure this suite is about is a
# silent success, so a version of it that quietly ran a subset would be the
# same defect wearing its name.
#   2 override round-trip + 2 potency + 2 production + 2 turn-failure
# + 2 orchestrator + 3 fail-closed + 2 ratchet + 3 structure + 5 wiring
EXPECTED_ASSERTIONS=23
TOTAL=$(( PASS + FAIL ))
if (( TOTAL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi

th_summary_and_exit
