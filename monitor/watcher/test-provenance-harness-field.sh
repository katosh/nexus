#!/usr/bin/env bash
# test-provenance-harness-field.sh — the descriptor's `harness` field, asserted
# against a record the REAL producer wrote, on BOTH of its writer branches.
#
# Run: bash monitor/watcher/test-provenance-harness-field.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# ---------------------------------------------------------------------------
# WHY THIS SUITE EXISTS — the probe shared a model with the probed.
#
# `skills/nexus.agent-delivery` §6 makes `monitor/.state/windows/<w>.json`'s
# `harness` key THE registration point for a mixed-harness nexus: `ng send`
# reads it to pick an adapter (`send.sh:_harness_for_window`). An absent key
# degrades to `generic-tmux`, so a launcher that never writes it silently
# removes every Claude-Code-specific transport from every window it spawns.
#
# `_write_provenance_record` has TWO writers: a `jq` arm (taken whenever `jq`
# exists — i.e. always, on this host) and a `printf` fallback (taken only when
# `jq` is ABSENT). The field was spelled in the fallback ONLY. So the arm that
# actually runs in production omitted it, and 0 of 1,278 live descriptors
# declared a harness while the contract's reader was fully implemented and its
# own suite was green (your-org/nexus-code#1085).
#
# It survived because the assertion that was supposed to catch it —
# `test-agent-delivery.sh` I5 — was
#
#     grep -c '"harness":"claude-code"' monitor/spawn-worker.sh   == 1
#
# a claim about the launcher's SOURCE TEXT. The dead fallback branch contains
# that literal, so the grep was satisfied by the one arm that never ran. A
# probe that reads the producer's source instead of the producer's OUTPUT
# cannot distinguish "writes the field" from "mentions the field", and those
# are exactly the two states that differed here.
#
# So every assertion below consumes a record PRODUCED by the real function,
# extracted from the real `monitor/spawn-worker.sh` at run time. Nothing here
# greps the launcher for a string, and nothing here hand-writes a descriptor.
#
# DECLARED SCOPE — read this before treating a green here as complete. Because
# PARTS A-D `awk`-extract the FUNCTION, they say nothing about its production
# CALL SITE: rename that call — the sole `^_write_provenance_record \` line in
# the launcher, deliberately not cited by number here, since a line number
# attached to a claim about a tree that the same commit shifts is its own
# defect — and this suite stays 22/0 green while no record is written at all. That gap is covered by
# `monitor/watcher/test-spawn-worker-state-dir.sh`, which drives the launcher
# rather than the function (measured against exactly that mutant: 29/0 -> 9/4).
# PART E is the one part that does assert something about a call site, and it
# does so from source for the reason stated there.
#
# NON-VACUITY. Three things a green run must also establish, or it is asserting
# nothing:
#   Control B1/B2 — each leg is shown to have taken the branch it claims to
#                   test. Without this, masking `jq` could silently fail and
#                   leg 2 would be a second copy of leg 1.
#   Control M1/M2 — POTENCY: a mutant with the field removed from one arm must
#                   FAIL that arm's assertion. This is the property I5 lacked;
#                   I5 passed before the fix and after it.
#   Control A1    — the two arms must AGREE. Divergence between them IS the
#                   defect class, and neither leg alone can see it.
# ---------------------------------------------------------------------------

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
SPAWN_SRC="$_repo_root/monitor/spawn-worker.sh"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
PASS=0; FAIL=0

WORK=$(mktemp -d -t nexus-1085-harness-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

[[ -f "$SPAWN_SRC" ]] || th_abort "launcher not found at $SPAWN_SRC"
command -v python3 >/dev/null 2>&1 || th_abort "python3 required to parse the produced record"

# ---------------------------------------------------------------------------
# Producing a record from a given launcher source.
#
# Same eval-extract mechanism `monitor/test-interactive-sessions.sh` uses, and
# it carries the same prerequisite: since #941 the function keys its output
# file with `wk_encode`, which lives in `_bookkeeping.sh` and is loaded by the
# launcher PREAMBLE the extract deliberately does not run. Without it the
# substitution yields the empty string and every record lands at `<dir>/.json`.
# ---------------------------------------------------------------------------
# shellcheck source=monitor/_bookkeeping.sh
. "$_repo_root/monitor/_bookkeeping.sh"
declare -F wk_encode >/dev/null 2>&1 \
    || th_abort "wk_encode unavailable after sourcing _bookkeeping.sh"

# A PATH with the function's externals but WITHOUT jq, so the fallback arm is
# reachable. Built by resolving each tool on the real PATH — a hand-written
# /bin guess is a confident wrong answer on this host (`/usr/bin/grep` does not
# exist here), and a missing tool would make the fallback fail for a reason
# that has nothing to do with the field under test.
_NOJQ_BIN="$WORK/nojq-bin"
mkdir -p "$_NOJQ_BIN"
# `bash` is in this list deliberately: a prefix assignment CHANGES command
# lookup for the command it prefixes, so `PATH=$_NOJQ_BIN bash …` resolves
# `bash` itself under the mask. Omitting it fails with `bash: command not
# found` inside a subshell whose output the producer discards — a missing
# record that looks exactly like "the arm wrote nothing", which is the
# assertion this leg is trying to make.
for _t in bash mkdir mktemp date sed mv rm cat tr awk grep od \
          dirname basename wc head tail cut sort stat; do
    _p=$(command -v "$_t" 2>/dev/null) \
        || th_abort "cannot build a jq-free PATH: '$_t' not resolvable"
    ln -sf "$_p" "$_NOJQ_BIN/$_t"
done
unset _t _p
PATH="$_NOJQ_BIN" command -v jq >/dev/null 2>&1 \
    && th_abort "jq-free PATH still resolves jq — the fallback arm is unreachable"

# produce <launcher-src> <out-dir> <mode:jq|nojq> [window]
# Emits the produced record's path on stdout; returns non-zero if none appeared.
produce() {
    local src="$1" outroot="$2" mode="$3" win="${4:-w-prov}"
    local script="$WORK/produce-$mode-$RANDOM.sh"
    {
        printf 'set -uo pipefail\n'
        printf '. %q\n' "$_repo_root/monitor/_bookkeeping.sh"
        # Extract the function body verbatim from the launcher under test.
        awk '/^_write_provenance_record\(\)/,/^}$/' "$src"
        printf 'STATE_DIR=%q\n' "$outroot"
        printf '_write_provenance_record %q %q "sid-1" "task" "/wd" "/pf" "topic"\n' \
            "$outroot" "$win"
    } > "$script"
    if [[ "$mode" == nojq ]]; then
        PATH="$_NOJQ_BIN" bash "$script" >/dev/null 2>&1
    else
        bash "$script" >/dev/null 2>&1
    fi
    local f="$outroot/windows/$(wk_encode "$win").json"
    [[ -f "$f" ]] || return 1
    printf '%s' "$f"
}

# Read one key out of a produced record. Prints the value, or the sentinel
# `<ABSENT>` when the key is missing, or `<UNPARSEABLE>` when it is not JSON.
# The sentinels matter: an empty string would make "key missing" and "key
# present but empty" indistinguishable, which is the ambiguity this whole
# suite exists to remove.
field_of() {
    NEXUS_F="$1" NEXUS_K="$2" python3 -c '
import json, os, sys
try:
    d = json.load(open(os.environ["NEXUS_F"]))
except Exception:
    print("<UNPARSEABLE>"); sys.exit(0)
k = os.environ["NEXUS_K"]
print(d[k] if isinstance(d, dict) and k in d else "<ABSENT>")
' 2>/dev/null || printf '<UNPARSEABLE>'
}

# ===========================================================================
echo "=== PART A: the real producer writes the field, on BOTH writer arms ==="
# ===========================================================================
# The two arms are asserted SEPARATELY and then against EACH OTHER. #1085 was
# not "the field is missing" — it was "the two arms disagree", and a suite that
# exercises whichever arm the host happens to select cannot see that at all.

A_ROOT="$WORK/real-jq";   mkdir -p "$A_ROOT/windows"
B_ROOT="$WORK/real-nojq"; mkdir -p "$B_ROOT/windows"

a_rec=$(produce "$SPAWN_SRC" "$A_ROOT" jq)   || th_abort "jq arm produced no record"
b_rec=$(produce "$SPAWN_SRC" "$B_ROOT" nojq) || th_abort "fallback arm produced no record"

a_harness=$(field_of "$a_rec" harness)
b_harness=$(field_of "$b_rec" harness)

assert_eq "A1 jq arm: produced record declares harness=claude-code" \
    "$a_harness" "claude-code"
assert_eq "A2 fallback arm: produced record declares harness=claude-code" \
    "$b_harness" "claude-code"
assert_eq "A3 the two arms AGREE on the field (the #1085 defect was divergence)" \
    "$a_harness" "$b_harness"

# The record must still be well-formed JSON on both arms — the fallback
# hand-rolls its JSON, so a bad format slot is a live failure mode there.
assert_eq "A4 jq arm still emits parseable JSON" \
    "$(field_of "$a_rec" window)" "w-prov"
assert_eq "A5 fallback arm still emits parseable JSON" \
    "$(field_of "$b_rec" window)" "w-prov"

# ===========================================================================
echo "=== PART B: each leg took the branch it claims to test ==="
# ===========================================================================
# Without these, a silently-ineffective jq mask would make PART A's two legs
# one leg run twice — green, and blind to exactly the divergence A3 exists for.
# The discriminator is the SHAPE of the output, which the two writers do not
# share: `jq -n` pretty-prints across multiple lines; the fallback `printf`s a
# single line. That is a property of the arms themselves, not a flag this
# suite sets, so it cannot be satisfied by the wrong arm.
a_lines=$(wc -l < "$a_rec" | tr -d ' ')
b_lines=$(wc -l < "$b_rec" | tr -d ' ')
assert_eq "B1 jq arm emitted multi-line JSON (jq -n pretty-prints)" \
    "$([[ "$a_lines" -gt 1 ]] && echo yes || echo no)" "yes"
assert_eq "B2 fallback arm emitted single-line JSON (hand-rolled printf)" \
    "$b_lines" "1"

# ===========================================================================
echo "=== PART C: POTENCY — a mutant missing the field must FAIL ==="
# ===========================================================================
# This is the control I5 never had. I5 passed identically before and after the
# fix, so it could not tell conformant code from broken code. Each mutant below
# removes the field from exactly ONE arm and the suite must notice — which also
# proves the two legs are independently load-bearing rather than one leg's
# result reported twice.

# M1: strip the jq arm's `--arg harness` binding AND its object key.
MUT1="$WORK/mutant-nojqarg.sh"
sed -e '/--arg harness "\$harness" \\/d' \
    -e 's/spawned_by: \$spawned_by, harness: \$harness, workdir: \$workdir,/spawned_by: $spawned_by, workdir: $workdir,/' \
    "$SPAWN_SRC" > "$MUT1"
M1_ROOT="$WORK/mut1"; mkdir -p "$M1_ROOT/windows"
if m1_rec=$(produce "$MUT1" "$M1_ROOT" jq); then
    assert_eq "M1 jq-arm mutant is DETECTED (field absent from the record)" \
        "$(field_of "$m1_rec" harness)" "<ABSENT>"
else
    assert_eq "M1 jq-arm mutant is DETECTED (field absent from the record)" \
        "<no-record>" "<ABSENT>"
fi
# M1b: the mutation must be POTENT rather than merely different — the mutant
# has to still produce an otherwise-valid record, or M1's "<ABSENT>" could be
# an artefact of a broken launcher rather than of the removed field.
assert_eq "M1b jq-arm mutant still writes an otherwise-valid record" \
    "$(field_of "${m1_rec:-/nonexistent}" window)" "w-prov"

# M2: strip the fallback's harness slot, restoring the pre-#1085 shape where
# only ONE arm carried the field. Under the old source-grep assertion this
# mutant and the fixed tree were indistinguishable.
MUT2="$WORK/mutant-nofallback.sh"
sed -e 's/,"spawned_by":"orchestrator","harness":"%s"/,"spawned_by":"orchestrator"/' \
    -e 's/"\$_e_kind" "\$_e_harness" "\$_e_wd"/"$_e_kind" "$_e_wd"/' \
    "$SPAWN_SRC" > "$MUT2"
M2_ROOT="$WORK/mut2"; mkdir -p "$M2_ROOT/windows"
if m2_rec=$(produce "$MUT2" "$M2_ROOT" nojq); then
    assert_eq "M2 fallback-arm mutant is DETECTED (field absent from the record)" \
        "$(field_of "$m2_rec" harness)" "<ABSENT>"
else
    assert_eq "M2 fallback-arm mutant is DETECTED (field absent from the record)" \
        "<no-record>" "<ABSENT>"
fi
assert_eq "M2b fallback-arm mutant still writes an otherwise-valid record" \
    "$(field_of "${m2_rec:-/nonexistent}" window)" "w-prov"

# M3: the mutants must be distinguishable from the real tree by THIS suite's
# own predicate, on the same arm. Stated as an explicit inequality so a
# future refactor that makes `field_of` always return "<ABSENT>" — which would
# turn M1/M2 green and A1/A2 red — cannot be mistaken for a passing potency
# control.
assert_eq "M3 real tree and mutant differ on the jq arm (predicate discriminates)" \
    "$([[ "$a_harness" != "$(field_of "${m1_rec:-/nonexistent}" harness)" ]] && echo differ || echo same)" \
    "differ"

# ===========================================================================
echo "=== PART D: the reader agrees with the producer, end to end ==="
# ===========================================================================
# PART A proves the producer writes the field. This proves the value it writes
# is one `send.sh` can actually resolve to an adapter — the two halves were
# each individually correct while the pair was broken, which is the whole
# lesson of #1085. An adapter file that does not exist would make every
# spawned window refuse at `send.sh:201` instead of degrading.
assert_eq "D1 the produced value names a real adapter under monitor/harness/" \
    "$([[ -f "$_repo_root/monitor/harness/$a_harness.sh" ]] && echo yes || echo no)" \
    "yes"
# And the floor the contract promises for a record that lacks the key is the
# one §7 documents — asserted here against a record this suite produced with
# the key stripped, not against a hand-written fixture.
assert_eq "D2 a record without the key is what the generic-tmux floor is for" \
    "$(field_of "${m1_rec:-/nonexistent}" harness)" "<ABSENT>"
assert_eq "D3 the generic-tmux floor adapter exists to receive that case" \
    "$([[ -f "$_repo_root/monitor/harness/generic-tmux.sh" ]] && echo yes || echo no)" \
    "yes"

# ===========================================================================
echo "=== PART E: the RESUME path heals a pre-#1085 descriptor in place ==="
# ===========================================================================
# `_write_provenance_record` is reached only on the FRESH spawn path — the
# resume branch exits at its own `exit 0` well before it. So "live windows
# self-heal on their next spawn" is true of short-lived workers and FALSE of
# any window that is only ever resumed: the watcher's crash-recovery path,
# `--replace`, the orchestrator respawn. Those keep a pre-#1085 descriptor
# forever, and the orchestrator is exactly the window a worker is told to
# message. `_ensure_harness_field` closes that, and its two refusals matter as
# much as its action.
eval "$(awk '/^_ensure_harness_field\(\)/,/^}$/' "$SPAWN_SRC")"
declare -F _ensure_harness_field >/dev/null 2>&1 \
    || th_abort "_ensure_harness_field not extractable from the launcher"

E_ROOT="$WORK/resume"; mkdir -p "$E_ROOT/windows"
STATE_DIR="$E_ROOT"

# E1: a pre-#1085 descriptor (no key) gains one, and keeps everything else.
printf '{"window":"w-old","kind":"task","topic":"keep me"}\n' > "$E_ROOT/windows/w-old.json"
_ensure_harness_field "$E_ROOT" "w-old"
assert_eq "E1 a descriptor lacking the key is healed" \
    "$(field_of "$E_ROOT/windows/w-old.json" harness)" "claude-code"
assert_eq "E1b …without disturbing the fields already there" \
    "$(field_of "$E_ROOT/windows/w-old.json" topic)" "keep me"

# E2: NEVER OVERWRITE. A foreign launcher's value is its business.
printf '{"window":"w-foreign","harness":"acme-agent"}\n' > "$E_ROOT/windows/w-foreign.json"
_ensure_harness_field "$E_ROOT" "w-foreign"
assert_eq "E2 an existing harness is NEVER overwritten" \
    "$(field_of "$E_ROOT/windows/w-foreign.json" harness)" "acme-agent"

# E3: NEVER CREATE. The descriptor's ABSENCE is what marks a window as
# operator-manual, so manufacturing one would silently reclassify a hand-made
# window as orchestrator-spawned. This is the invariant most easily lost to a
# later "just make it robust" edit, which is why it is asserted rather than
# left to the comment.
_ensure_harness_field "$E_ROOT" "w-never-spawned"
assert_eq "E3 a window with NO descriptor does not get one invented" \
    "$([[ -e "$E_ROOT/windows/w-never-spawned.json" ]] && echo created || echo absent)" \
    "absent"

# E4: idempotent — a second pass is a no-op, not a rewrite.
_ensure_harness_field "$E_ROOT" "w-old"
assert_eq "E4 healing twice is idempotent" \
    "$(field_of "$E_ROOT/windows/w-old.json" harness)" "claude-code"

# E5: the resume path actually CALLS it — the helper is inert if nothing
# invokes it, and the whole point is that the resume branch exits early. This
# is a source assertion by necessity (the resume path needs a live tmux and a
# real session to run), and it is scoped to that: it asserts the call SITE
# exists inside the resume block, above that block's `exit 0`.
_resume_block=$(awk '/^if \[ -n "\$RESUME_TARGET" \]; then$/,/^fi$/' "$SPAWN_SRC")
# Count CALLS, not mentions: the call site carries an explanatory comment that
# names the helper, so a bare `grep -c` reports 2 and the assertion drifts to
# match the comment rather than the code.
assert_eq "E5 the resume branch invokes the healer before its exit" \
    "$(grep -cE '^[[:space:]]*_ensure_harness_field[[:space:]]' <<<"$_resume_block")" "1"

# ===========================================================================
EXPECTED_ASSERTIONS=21
_run_total=$(( PASS + FAIL ))
# ONE LINE deliberately: summary-honesty's `_count_axis` classifies from
# PHYSICAL lines, so a `\`-continuation between `assert_eq` and
# `$EXPECTED_ASSERTIONS` reads as `count=none` and silently opts this suite
# out of the count guard. Use the documented vocabulary and shape rather than
# widening the classifier.
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
