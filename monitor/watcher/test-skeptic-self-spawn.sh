#!/usr/bin/env bash
# Unit tests for the self-spawned-skeptic refusal in monitor/spawn-worker.sh
# (your-org/nexus-code#1098).
#
# Run: bash monitor/watcher/test-skeptic-self-spawn.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY BOTH DIRECTIONS ARE ASSERTED, EVERY TIME. A guard that refuses
# EVERYTHING passes every refusal test ever written for it, and the guard this
# suite covers sits on the path the ORCHESTRATOR takes for every skeptic on the
# board. So each REFUSE case is paired with an ALLOW case that differs in
# exactly one variable — the same target window, the same flags, a different
# spawning identity — and the ALLOW case asserts a composed prompt on stdout,
# not merely exit 0.
#
# NO TMUX IS TOUCHED. Every invocation carries `--print-prompt`, which composes
# and exits before any tmux operation; the refusal fires earlier still, so the
# two directions are distinguished by exit code and stderr alone. This suite
# cannot affect a live tmux server.
#
# Env robustness: every invocation runs under `env -u NEXUS_ROOT
# -u NEXUS_STATE_DIR -u CLAUDE_SESSION_ID -u NEXUS_WORKER_WINDOW`, then sets
# only what the case under test needs. Without the two unsets a worker running
# this suite would leak its OWN session and window into the fixture — and this
# suite is about exactly those two variables, so the leak would be
# indistinguishable from the behaviour under test.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_REAL="$_test_dir/../spawn-worker.sh"
SKILL_REAL="$_test_dir/../../skills/nexus.worker-defaults/SKILL.md"

# The SHARED ledger, not hand-rolled counters (your-org/nexus-code#805/#821).
# A hand-rolled summary prints from in-memory counters a subshell can silently
# discard — a FAIL that never reddens the suite. `th_summary_and_exit`
# reconciles from an append-only ledger that survives the subshell, so this
# suite's green certifies that something was actually asserted.
. "$_test_dir/_test_helpers.sh"
PASS=0
FAIL=0

# ---- fixture ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SPAWN_TMP="$WORK/spawn-tmp"; mkdir -p "$SPAWN_TMP"; export TMPDIR="$SPAWN_TMP"

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" \
         "$FAKE_NEXUS/skills/nexus.worker-defaults" \
         "$FAKE_NEXUS/reports"

cp "$SCRIPT_REAL" "$FAKE_NEXUS/monitor/spawn-worker.sh"
chmod +x "$FAKE_NEXUS/monitor/spawn-worker.sh"
cp "$_test_dir/../guard-block.sh.in" "$FAKE_NEXUS/monitor/guard-block.sh.in"
for _dep in _claude-bin.sh _tmux-window.sh _fm_lib.sh _channel_lib.sh _bookkeeping.sh; do
    cp "$_test_dir/../$_dep" "$FAKE_NEXUS/monitor/$_dep"
done
cp "$_test_dir/../request-channel.sh" "$FAKE_NEXUS/monitor/request-channel.sh"
chmod +x "$FAKE_NEXUS/monitor/request-channel.sh"
cp "$SKILL_REAL" "$FAKE_NEXUS/skills/nexus.worker-defaults/SKILL.md"

mkdir -p "$FAKE_NEXUS/node_modules/.bin"
printf '#!/bin/bash\necho "stub-claude: $*"\n' > "$FAKE_NEXUS/node_modules/.bin/claude"
chmod +x "$FAKE_NEXUS/node_modules/.bin/claude"
cat > "$FAKE_NEXUS/monitor/worker-settings.json" <<'EOF'
{ "skipDangerousModePermissionPrompt": true, "hooks": {} }
EOF

SCRIPT="$FAKE_NEXUS/monitor/spawn-worker.sh"
STATE="$FAKE_NEXUS/monitor/.state"
WORKDIR="$WORK/worker-tree"; mkdir -p "$WORKDIR"
PROMPT_FILE="$WORK/task-prompt.txt"
printf 'TASK_PROMPT_TOKEN_1098\n\nValidate the thing.\n' > "$PROMPT_FILE"

# The reviewed worker. Its provenance record is what the SESSION key reads;
# jq writes it pretty-printed in production, so the fixture is pretty-printed
# too — a single-line fixture would not exercise the parser that ships.
TARGET_WIN="reviewed"
TARGET_SID="9ab46d79-03f1-4591-825c-4e6c72d20373"
mkdir -p "$STATE/windows"
cat > "$STATE/windows/$TARGET_WIN.json" <<EOF
{
  "window": "$TARGET_WIN",
  "session_id": "$TARGET_SID",
  "kind": "task",
  "spawned_by": "orchestrator",
  "harness": "claude-code",
  "skeptic_role": false,
  "skeptic_target": ""
}
EOF

# The CHAIN ROOT of a depth-2 spawn. A second-or-later skeptic reviews its
# immediate target AND the original worker, and `spawn-worker.sh` records that
# formally: :2445 opens a second `skeptic-verdict` obligation with the ORIG as
# creditor, :2495 inits a channel to it, :2522 writes a pending marker under its
# key. So the orig is a REVIEWED PARTY, not a label.
ORIG_WIN="rootworker"
ORIG_SID="aaaaaaaa-1111-2222-3333-444444444444"
cat > "$STATE/windows/$ORIG_WIN.json" <<EOF
{
  "window": "$ORIG_WIN",
  "session_id": "$ORIG_SID",
  "kind": "task",
  "spawned_by": "orchestrator"
}
EOF

# <self-session> <self-window> <extra args...>
# Runs the launcher with a controlled spawning identity. NEXUS_ROOT is pinned
# so the script's helpers and state dir come from the fixture, never the host.
run_as() {
    local sid="$1" win="$2"; shift 2
    local -a envv=(env -u CLAUDE_SESSION_ID -u NEXUS_WORKER_WINDOW
                   -u NEXUS_SKEPTIC_SELF_SPAWN -u NEXUS_SKEPTIC_SELF_SPAWN_REASON
                   NEXUS_ROOT="$FAKE_NEXUS" NEXUS_STATE_DIR="$STATE")
    [[ -n "$sid" ]] && envv+=("CLAUDE_SESSION_ID=$sid")
    [[ -n "$win" ]] && envv+=("NEXUS_WORKER_WINDOW=$win")
    "${envv[@]}" "$SCRIPT" "$@"
}

skeptic_args=(-n "${TARGET_WIN}-sk" -c "$WORKDIR" -p "$PROMPT_FILE"
              --skeptic-role --skeptic-target "$TARGET_WIN" --print-prompt)

# ---- R1: the SESSION key refuses a genuine self-spawn -------------------

echo '=== R1: spawning session IS the target'"'"'s session -> REFUSED (exit 20) ==='

out=$(run_as "$TARGET_SID" "$TARGET_WIN" "${skeptic_args[@]}" 2>&1); rc=$?
assert_eq       "R1 exit code is 20"                "$rc" "20"
assert_contains "R1 names the issue"                "$out" "your-org/nexus-code#1098"
assert_contains "R1 cites the SESSION as evidence"  "$out" "session id $TARGET_SID"
assert_contains "R1 points at the legitimate path"  "$out" "ng request file --origin"
# your-org/nexus-code#1124: the refusal used to point at `ng skeptic request`, a
# verb that does not exist, and this assertion pinned the STRING. Now the
# remedy is EXECUTED: the printed command shape, run hermetically, must file.
_r1124_st=$(mktemp -d "${TMPDIR:-/tmp}/r1124.XXXXXX")
_r1124_out=$(env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$_r1124_st" bash "$_test_dir/../request-channel.sh" file \
    --origin "$TARGET_WIN" --kind spawn-skeptic --slug "review-$TARGET_WIN" --message 'review the deliverable' 2>&1); _r1124_rc=$?
assert_eq "#1124 the remedy the refusal names actually FILES (rc 0)" "$_r1124_rc" "0"
assert_eq "#1124 …and a .new.md request exists for it" "$(find "$_r1124_st" -name '*.new.md' 2>/dev/null | grep -c .)" "1"
assert_not_contains "#1124 no live site still names the dead verb" \
    "$(grep -rnE '(^|[^a-z])ng skeptic request' "$_test_dir/.." "$_test_dir/../../skills" 2>/dev/null | grep -v '/test-\|#1124' || true)" "ng skeptic request"
rm -rf "$_r1124_st"
assert_not_contains "R1 composed no prompt"         "$out" "TASK_PROMPT_TOKEN_1098"

# ---- R2: the WINDOW key refuses when the record carries no session ------
#
# The blind spot the second key exists for: a target spawned before provenance
# carried `session_id`, or one whose record cannot be parsed. Session evidence
# is unavailable BY CONSTRUCTION here (the spawning session is a different
# UUID), so a pass can only come from the window key.

echo '=== R2: record has no session_id; NEXUS_WORKER_WINDOW == target -> REFUSED ==='

mkdir -p "$STATE/windows-r2"
cat > "$STATE/windows/nosid.json" <<'EOF'
{
  "window": "nosid",
  "kind": "task",
  "spawned_by": "orchestrator"
}
EOF
out=$(run_as "aaaaaaaa-0000-0000-0000-000000000000" "nosid" \
      -n nosid-sk -c "$WORKDIR" -p "$PROMPT_FILE" \
      --skeptic-role --skeptic-target nosid --print-prompt 2>&1); rc=$?
assert_eq       "R2 exit code is 20"                 "$rc" "20"
assert_contains "R2 cites the WINDOW as evidence"    "$out" "NEXUS_WORKER_WINDOW"
assert_not_contains "R2 did not claim session evidence" "$out" "session id"

# ---- A1: THE PAIRED ALLOW — the orchestrator, SAME target, SAME flags ---
#
# The one variable that differs from R1 is the spawning identity. If this
# refuses, the guard has taken the fleet down; if R1 passes and this does not,
# the suite is measuring nothing.

echo '=== A1: orchestrator spawning a skeptic for the SAME target -> ALLOWED ==='

out=$(run_as "11111111-2222-3333-4444-555555555555" "monitor" "${skeptic_args[@]}" 2>&1); rc=$?
assert_eq       "A1 exit code is 0"                  "$rc" "0"
assert_contains "A1 composed the task prompt"        "$out" "TASK_PROMPT_TOKEN_1098"
assert_not_contains "A1 did not refuse"              "$out" "REFUSING"

# ---- A2: a THIRD-PARTY worker spawning a skeptic for another worker -----

echo '=== A2: an unrelated worker window spawning for the same target -> ALLOWED ==='

out=$(run_as "77777777-8888-9999-aaaa-bbbbbbbbbbbb" "someone-else" "${skeptic_args[@]}" 2>&1); rc=$?
assert_eq       "A2 exit code is 0"                  "$rc" "0"
assert_contains "A2 composed the task prompt"        "$out" "TASK_PROMPT_TOKEN_1098"

# ---- A3: no identity available at all -> ALLOWED (positive-ID only) -----
#
# Pins the DECLARED polarity rather than leaving it to be inferred. This guard
# does not default-deny; a caller it cannot identify proceeds.

echo '=== A3: neither key available -> ALLOWED (the guard is positive-ID only) ==='

out=$(run_as "" "" "${skeptic_args[@]}" 2>&1); rc=$?
assert_eq       "A3 exit code is 0"                  "$rc" "0"
assert_contains "A3 composed the task prompt"        "$out" "TASK_PROMPT_TOKEN_1098"

# ---- A4: a NON-skeptic spawn from the target's own session -> ALLOWED ---
#
# The guard is scoped to `--skeptic-role`. A worker spawning an ordinary
# helper worker is not what #1098 is about and must be untouched.

echo '=== A4: same session, but NOT a skeptic spawn -> ALLOWED ==='

out=$(run_as "$TARGET_SID" "$TARGET_WIN" \
      -n helper -c "$WORKDIR" -p "$PROMPT_FILE" --print-prompt 2>&1); rc=$?
assert_eq       "A4 exit code is 0"                  "$rc" "0"
assert_contains "A4 composed the task prompt"        "$out" "TASK_PROMPT_TOKEN_1098"

# ---- G1-G3: --skeptic-orig is a REVIEWED WINDOW TOO ---------------------
#
# The first version of this guard compared only against `--skeptic-target`, so a
# ROOT worker could spawn a depth-2 skeptic formally obligated to review its own
# work, with a brief it wrote — `#1098` exactly, one level removed. Reproduced
# before the fix: I refused (20), J and K were ALLOWED (0).
#
# The general lesson, which is why this block exists rather than one more
# assertion: **a guard complete in the branch it was written against and absent
# on the neighbouring one.** Same shape as `#1085`, and same shape as this
# suite's own `$CLAUDE_SESSION_ID` finding.

echo '=== G1: I am --skeptic-orig (window key), target is another window -> REFUSED ==='

depth2_args=(-n "${ORIG_WIN}-sk2" -c "$WORKDIR" -p "$PROMPT_FILE"
             --skeptic-role --skeptic-target "${ORIG_WIN}-sk"
             --skeptic-orig "$ORIG_WIN" --print-prompt)

out=$(run_as "" "$ORIG_WIN" "${depth2_args[@]}" 2>&1); rc=$?
assert_eq       "G1 exit code is 20"                  "$rc" "20"
assert_contains "G1 cites --skeptic-orig"             "$out" "IS --skeptic-orig"
assert_contains "G1 explains why orig is reviewed"    "$out" "CHAIN ROOT"
assert_not_contains "G1 composed no prompt"           "$out" "TASK_PROMPT_TOKEN_1098"

echo '=== G2: same, identified by the SESSION key -> REFUSED ==='

out=$(run_as "$ORIG_SID" "" "${depth2_args[@]}" 2>&1); rc=$?
assert_eq       "G2 exit code is 20"                  "$rc" "20"
assert_contains "G2 cites the recorded session of the orig" "$out" "--skeptic-orig"

echo '=== G3: THE PAIRED ALLOWS — a depth-2 spawn is legitimate work ==='

# The orchestrator, same flags, same chain root. If this refuses, every
# second-pass skeptic on the board is now unspawnable.
out=$(run_as "bbbbbbbb-0000-0000-0000-000000000000" "monitor" "${depth2_args[@]}" 2>&1); rc=$?
assert_eq       "G3a orchestrator depth-2 spawn -> ALLOWED"  "$rc" "0"
assert_contains "G3a composed the task prompt"               "$out" "TASK_PROMPT_TOKEN_1098"

# The FIRST skeptic spawning the second one. It is not a reviewed party of this
# spawn: the target is itself... which the TARGET key already refuses. So the
# legitimate variant is a third party, and the orig-defaults-to-target case must
# not fire the orig arm at all.
out=$(run_as "cccccccc-0000-0000-0000-000000000000" "someone-else" \
      -n "${ORIG_WIN}-sk" -c "$WORKDIR" -p "$PROMPT_FILE" \
      --skeptic-role --skeptic-target "$ORIG_WIN" --print-prompt 2>&1); rc=$?
assert_eq       "G3b first-pass spawn (orig DEFAULTS to target) -> ALLOWED" "$rc" "0"
assert_not_contains "G3b the orig arm did not fire on the default" "$out" "IS --skeptic-orig"

# ---- O1/O2: the audited override -----------------------------------------

echo '=== O1: NEXUS_SKEPTIC_SELF_SPAWN=1 WITHOUT a reason -> still REFUSED ==='

out=$(env -u CLAUDE_SESSION_ID -u NEXUS_WORKER_WINDOW \
        NEXUS_ROOT="$FAKE_NEXUS" NEXUS_STATE_DIR="$STATE" \
        CLAUDE_SESSION_ID="$TARGET_SID" NEXUS_SKEPTIC_SELF_SPAWN=1 \
        "$SCRIPT" "${skeptic_args[@]}" 2>&1); rc=$?
assert_eq       "O1 exit code is 20"                 "$rc" "20"
assert_contains "O1 says a reason is required"       "$out" "NEXUS_SKEPTIC_SELF_SPAWN_REASON"

echo '=== O2: flag AND reason -> ALLOWED, and the call is audited ==='

rm -f "$STATE/skeptic-self-spawn.log"
out=$(env -u NEXUS_WORKER_WINDOW \
        NEXUS_ROOT="$FAKE_NEXUS" NEXUS_STATE_DIR="$STATE" \
        CLAUDE_SESSION_ID="$TARGET_SID" NEXUS_SKEPTIC_SELF_SPAWN=1 \
        NEXUS_SKEPTIC_SELF_SPAWN_REASON="fixture: deliberate self-review" \
        "$SCRIPT" "${skeptic_args[@]}" 2>&1); rc=$?
assert_eq       "O2 exit code is 0"                  "$rc" "0"
assert_contains "O2 composed the task prompt"        "$out" "TASK_PROMPT_TOKEN_1098"
assert_contains "O2 announced the override"          "$out" "SELF-SPAWNED SKEPTIC, audited"
if [[ -s "$STATE/skeptic-self-spawn.log" ]]; then
    printf '  PASS: O2 wrote an audit row\n'; PASS=$(( PASS + 1 ))
    assert_contains "O2 audit row carries the reason" \
        "$(cat "$STATE/skeptic-self-spawn.log")" "fixture: deliberate self-review"
    assert_contains "O2 audit row names the target" \
        "$(cat "$STATE/skeptic-self-spawn.log")" "$TARGET_WIN"
else
    printf '  FAIL: O2 wrote no audit row at %s\n' "$STATE/skeptic-self-spawn.log" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- M1/M2: MUTANT POTENCY ----------------------------------------------
#
# An inert mutant and a real surviving mutant produce byte-identical output, so
# each mutant is ASSERTED APPLIED (the edit changed the file) before its
# verdict is read. Without that assertion "the mutant survived" and "the sed
# never matched" are the same observation.

echo '=== M1/M2: mutant potency — each mutant is asserted applied ==='

mutate() {   # <name> <sed-expr>  -> 0 when the file actually changed
    # NOT one `local` statement: bash declares every name in a `local` FIRST
    # and assigns after, so `mdir="$WORK/mut-$name"` would expand $name while
    # it is still unset — which under `set -u` aborts the function. This suite
    # hit that trap on its first run; it is the same one monitor/send.sh
    # documents at _harness_for_window.
    local name="$1"
    local expr="$2"
    local mdir="$WORK/mut-$name"
    rm -rf "$mdir"; cp -a "$FAKE_NEXUS" "$mdir"
    sed -i "$expr" "$mdir/monitor/spawn-worker.sh"
    local changed
    changed=$(diff "$FAKE_NEXUS/monitor/spawn-worker.sh" "$mdir/monitor/spawn-worker.sh" \
                | grep -c '^<' ) || true
    if [[ "$changed" == "0" ]]; then
        assert_eq "mutant $name APPLIED (an inert mutant makes its verdict meaningless)" "inert" "applied"
        return 1
    fi
    # EXACTLY ONE LINE, and this is the structural half of "one mutant per arm"
    # (skeptic G3). A sed anchored too loosely mutes several arms at once and
    # every fixture still goes green, because each fixture withholds the other
    # arms' inputs anyway — so the isolation would rest on a fixture detail
    # rather than on the mutant. Counting the changed lines makes it rest on the
    # mutant.
    assert_eq "mutant $name changed EXACTLY one line (isolates ONE arm)" "$changed" "1"
    return 0
}
run_mutant() {   # <name> <self-session> <self-window> <args...>
    local name="$1"
    local sid="$2"
    local win="$3"
    shift 3
    local -a envv=(env -u CLAUDE_SESSION_ID -u NEXUS_WORKER_WINDOW
                   -u NEXUS_SKEPTIC_SELF_SPAWN -u NEXUS_SKEPTIC_SELF_SPAWN_REASON
                   NEXUS_ROOT="$WORK/mut-$name" NEXUS_STATE_DIR="$STATE")
    [[ -n "$sid" ]] && envv+=("CLAUDE_SESSION_ID=$sid")
    [[ -n "$win" ]] && envv+=("NEXUS_WORKER_WINDOW=$win")
    "${envv[@]}" "$WORK/mut-$name/monitor/spawn-worker.sh" "$@" >/dev/null 2>&1
}

# EACH SED IS ANCHORED ON THE ARM'S OWN WINDOW-ROLE TOKEN (skeptic G3).
#
# The first version anchored M1 on `_ss_evidence="session id`, which matches
# BOTH session arms once `--skeptic-orig` was added — so M1 muted two arms while
# claiming to isolate one. "No arm is decoration" was still TRUE, but it was
# carried by each fixture WITHHOLDING the other arm's input (M1 passes no
# NEXUS_WORKER_WINDOW, M2 no CLAUDE_SESSION_ID), not by the mutants isolating
# arms. That is a real property resting on a fixture detail, and a future
# fixture that supplied both inputs would have made every one of these vacuous
# without turning anything red. Anchoring on `--skeptic-target` /
# `--skeptic-orig` makes the isolation structural.

# M1 — disable the TARGET SESSION arm only. R1 must go from REFUSED to allowed.
if mutate sess 's/_ss_evidence="session id \(.*\)--skeptic-target/_ss_MUTED="session id \1--skeptic-target/'; then
    run_mutant sess "$TARGET_SID" "" -n "${TARGET_WIN}-sk" -c "$WORKDIR" \
        -p "$PROMPT_FILE" --skeptic-role --skeptic-target "$TARGET_WIN" --print-prompt
    assert_eq "M1 killed: session key muted -> R1 no longer refuses" "$?" "0"
fi

# M2 — disable the TARGET WINDOW arm only. R2 must go from REFUSED to allowed.
if mutate win 's/_ss_evidence="\\\$NEXUS_WORKER_WINDOW \(.*\)--skeptic-target/_ss_MUTED="x \1--skeptic-target/'; then
    run_mutant win "aaaaaaaa-0000-0000-0000-000000000000" "nosid" \
        -n nosid-sk -c "$WORKDIR" -p "$PROMPT_FILE" \
        --skeptic-role --skeptic-target nosid --print-prompt
    assert_eq "M2 killed: window key muted -> R2 no longer refuses" "$?" "0"
fi

# M3/M4 — the two ORIG arms. Each must be independently load-bearing, or the
# fix is one arm doing the work of two and the other is decoration.
if mutate origsess 's/_ss_evidence="session id $_ss_self_session is the session recorded for --skeptic-orig/_ss_MUTED="session id $_ss_self_session is the session recorded for --skeptic-orig/'; then
    run_mutant origsess "$ORIG_SID" "" -n "${ORIG_WIN}-sk2" -c "$WORKDIR" -p "$PROMPT_FILE" \
        --skeptic-role --skeptic-target "${ORIG_WIN}-sk" --skeptic-orig "$ORIG_WIN" --print-prompt
    assert_eq "M3 killed: orig SESSION arm muted -> G2 no longer refuses" "$?" "0"
fi
if mutate origwin 's/_ss_evidence="\\\$NEXUS_WORKER_WINDOW is .\$_ss_self_window., which IS --skeptic-orig/_ss_MUTED="x/'; then
    run_mutant origwin "" "$ORIG_WIN" -n "${ORIG_WIN}-sk2" -c "$WORKDIR" -p "$PROMPT_FILE" \
        --skeptic-role --skeptic-target "${ORIG_WIN}-sk" --skeptic-orig "$ORIG_WIN" --print-prompt
    assert_eq "M4 killed: orig WINDOW arm muted -> G1 no longer refuses" "$?" "0"
fi

# ---- SKILL/prose coupling ------------------------------------------------
#
# The refusal exists because the skill's rule had no enforcement. If the rule
# is ever deleted from the skill, this guard becomes an unexplained refusal —
# so the two are pinned to each other.

echo '=== S1: the skill still states the rule this guard enforces ==='
SKEPTIC_SKILL="$_test_dir/../../skills/nexus.skeptic/SKILL.md"
if [[ -r "$SKEPTIC_SKILL" ]]; then
    assert_contains "S1 skill assigns the spawn to the orchestrator" \
        "$(cat "$SKEPTIC_SKILL")" "the orchestrator composes the brief and spawns"
else
    printf '  FAIL: S1 cannot read %s\n' "$SKEPTIC_SKILL" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- the assertion COUNT, compared EXACTLY (#821 axis B) -----------------
# A suite can lose assertions silently: an arm that stops running still reports
# a clean green, and a FLOOR cannot catch that. Update this number DELIBERATELY
# when adding an arm; a mismatch is a red, not a warning.
EXPECTED_ASSERTIONS=47
_run_total=$(( PASS + FAIL ))
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
