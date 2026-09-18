#!/usr/bin/env bash
# test-subshell-exit-guards.sh — the guard for your-org/nexus-code#1339: a
# fail-closed guard whose `die`/`exit` is reached ONLY from inside a subshell
# terminates the SUBSHELL, so the guard runs, decides correctly, prints its
# refusal, and DOES NOT GATE.
#
# WHAT THIS SUITE IS ACTUALLY FOR, stated because it is not the obvious thing.
# It is not here to check that the classifier's output has the right shape. It
# is here to pin the ONE property that makes the classifier worth having:
#
#   **THE SAME GUARD, REACHED FROM A SUBSHELL, REDS — AND HOISTED INTO THE
#   MAIN SHELL, PASSES.**
#
# `#1339` states the requirement in one line: "a lint that fires on both, or
# neither, is worse than none." Both arms are therefore PERMANENT assertions
# here, on BYTE-IDENTICAL guard text with one call site moved, not a one-off
# manual check in a commit message. The first cut of the classifier resolved
# function names globally and reddened BOTH arms; nothing but a two-sided
# control could have caught that, because the defect arm was green-for-red and
# the report looked correct.
#
# FIXTURES LIVE UNDER `mktemp -d`, OUTSIDE THE REPO TREE, deliberately: the
# runner's `_rt_path_in_repo` exempts out-of-repo fixtures from other gates,
# and an in-repo plant is the one thing that reddens `run-tests.sh`'s promoted
# `#1185` gate.
#
# ASSERTION SHAPE. Every assertion below is POSITIVE where it can be — it names
# something that must be FOUND — because a guard built out of absences ("X is
# not in the output") is satisfied by a classifier that produced NO OUTPUT AT
# ALL, which is the failure mode of this whole repo. Where an absence IS the
# property (the hoisted arm must not fire), it is paired with its positive twin
# on the same bytes, so the pair can only both pass if the classifier genuinely
# discriminates.
set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/_test_helpers.sh"
# ASSERTION CENSUS (your-org/nexus-code#807). Counted BEFORE the census
# assertion itself. Adopted rather than opted out of: `test-summary-honesty-
# manifest.sh` reddened on this suite the moment it entered the corpus, and its
# own diagnostic is explicit that appending an opt-out line "opts your own new
# code out of the standard".
EXPECTED_ASSERTIONS=26
REPO_ROOT=$(cd "$_self_dir/../.." && pwd)
GEN="$REPO_ROOT/monitor/watcher/subshell-exit-guards.sh"
CORE="$REPO_ROOT/monitor/watcher/_subshell_exit_scan.py"
MANIFEST="$REPO_ROOT/monitor/watcher/subshell-exit-guards.manifest"

[[ -r "$GEN"  ]] || { echo "missing $GEN"  >&2; exit 1; }
[[ -r "$CORE" ]] || { echo "missing $CORE" >&2; exit 1; }

# The live-tree sweep, EXTRACTED INTO A FUNCTION so `gp_population` can CALL
# the generator's own enumerator rather than restate it (`#803`'s one rule for
# an implementor: a second implementation of a population drifts until the
# index reports, with total confidence, that a guard does not read a file it
# does read).
_seg_files() { bash "$GEN" --files "$REPO_ROOT"; }

# ---- the `--population` protocol (your-org/nexus-code#803, #1301) ---------
#
# PLACED HERE — above the first `echo`, and above `mktemp -d` — because
# `gp_handle` EXITS when it handles the flag, so anything printed before it
# lands in the probe's STDOUT and is read as a population row.
. "$_self_dir/../_guard_population.sh"
gp_population() {
    _seg_files
    # The named reads: the classifier, its core, the manifest it ratchets, and
    # the shared file-class predicate the population is DERIVED from. All four
    # can change this guard's verdict without appearing in the sweep -- the
    # predicate above all, since narrowing `shf_is_shell` silently shrinks the
    # corpus this lint sees.
    printf '%s\n' \
        monitor/watcher/subshell-exit-guards.sh \
        monitor/watcher/_subshell_exit_scan.py \
        monitor/watcher/subshell-exit-guards.manifest \
        monitor/shell-files.sh
}
gp_handle "$@"

TMP=$(mktemp -d -t seg-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# ===========================================================================
echo "=== 1. THE TWO-SIDED NEGATIVE CONTROL ==="
# ===========================================================================
#
# ONE guard, TWO call sites. The guard text, the `die`, the lookup helper and
# the verb are byte-identical between the arms; the ONLY difference is WHERE
# `_must_be_readable` is invoked from. This mirrors the measured instance
# exactly, INCLUDING its two levels of indirection — the substituted word is
# `_lookup`, which is neither `die` nor `exit`, so a text predicate aimed at
# either cannot see this and a reachability predicate must.

_ARM_COMMON='#!/usr/bin/env bash
die() { echo "boom: $*" >&2; exit 1; }
_must_be_readable() {
    [[ -r "$REG" ]] && return 0
    die "registry at $REG exists and could NOT be READ. Refusing."
}
'
# ARM A — the DEFECT. The guard is reached only through `_lookup`, and
# `_lookup`'s only caller invokes it in a command substitution whose failure is
# absorbed by a fallback. This is `jupyter-up.sh cmd_status` in miniature.
printf '%s' "$_ARM_COMMON"'_lookup() {
    local n
    _must_be_readable
    printf "%s" "$n"
}
verb_down() {
    local name
    name=$(_lookup "$DIR") || name="(unregistered)"
    echo "stopping $name anyway"
}
' > "$TMP/arm_subshell.sh"

# ARM B — the FIX. Same bytes, with the gate HOISTED into the verb's own main
# shell. `_lookup` is still called in a substitution; the guard no longer is.
printf '%s' "$_ARM_COMMON"'_lookup() {
    local n
    printf "%s" "$n"
}
verb_down() {
    local name
    _must_be_readable
    name=$(_lookup "$DIR") || name="(unregistered)"
    echo "stopping $name anyway"
}
' > "$TMP/arm_hoisted.sh"

printf 'arm_subshell.sh\narm_hoisted.sh\n' > "$TMP/files"
_arm_out=$(cd "$REPO_ROOT" && python3 "$CORE" "$TMP" "$TMP/files" 2>"$TMP/arm.err")
_arm_rc=$?

assert_eq "the classifier ran clean over both arms (rc)" "$_arm_rc" 0
assert_empty "…and said nothing on stderr" "$(cat "$TMP/arm.err")"

# THE RED ARM. Positive: the defect site must be FOUND, and found with the full
# indirection chain, because the chain is the evidence that reachability — not
# text — is what produced it.
assert_contains "ARM A (defect): the subshell-reached guard is REPORTED" \
    "$_arm_out" 'arm_subshell.sh'
assert_contains "ARM A: reported through the two-level chain a grep cannot see" \
    "$_arm_out" '_lookup->_must_be_readable->die->exit'
assert_contains "ARM A: and the fate says the refusal was ABSORBED, not gated" \
    "$_arm_out" 'absorbed:'

# THE GREEN ARM. This is the assertion that stops the lint being useless: the
# SAME guard, hoisted, must NOT be reported. Paired with the positive above on
# byte-identical guard text, so they cannot both pass unless the classifier
# discriminates on the CALL SITE.
assert_not_contains "ARM B (fix): the HOISTED guard is NOT reported" \
    "$_arm_out" 'arm_hoisted.sh'

# And the count, so "not reported" cannot be satisfied by an empty answer.
assert_eq "exactly ONE of the two arms fired" \
    "$(printf '%s\n' "$_arm_out" | grep -c . )" 1

echo
# ===========================================================================
echo "=== 2. THE SAFE FORMS MUST STAY SAFE ==="
# ===========================================================================
#
# The complement of section 1. A lint that reddens every `$( )` is a lint
# everyone turns off, so the four constructs that are CORRECT must be
# classified as such — and each is a real idiom from this tree.

printf '%s' '#!/usr/bin/env bash
die() { echo "boom: $*" >&2; exit 1; }
_guarded() { [[ -r "$REG" ]] || die "unreadable"; printf ok; }
propagated() { local v; v=$(_guarded) || exit 1; echo "$v"; }
flowed()     { local v; v=$(_guarded) || return 0; echo "$v"; }
grouped()    { ( flock -w 10 9 || exit 9; _guarded ) 9>>"$REG.lock"; }
conditioned(){ if v=$(_guarded); then echo "$v"; fi; }
' > "$TMP/safe.sh"
printf 'safe.sh\n' > "$TMP/files2"
_safe_out=$(cd "$REPO_ROOT" && python3 "$CORE" "$TMP" "$TMP/files2" 2>/dev/null)

assert_contains "\`|| exit 1\` is classified PROPAGATED (the status is honoured)" \
    "$_safe_out" 'propagated:'
assert_contains "\`|| return 0\` is its OWN bucket — it hands the CALLER a SUCCESS" \
    "$_safe_out" 'flow:'
assert_contains "an explicit \`( … || exit 9 )\` is GROUP — the subshell IS the unit" \
    "$_safe_out" 'group:'
assert_contains "an \`if v=\$(…)\` condition is COND — the status is consumed" \
    "$_safe_out" 'cond:'
assert_not_contains "and NONE of the four is called absorbed" \
    "$_safe_out" 'absorbed:'
assert_not_contains "…nor discarded" \
    "$_safe_out" 'discarded:'

echo
# ===========================================================================
echo "=== 3. A BRACE GROUP IS NOT A SUBSHELL ==="
# ===========================================================================
#
# The arm whose two directions are both fatal. `{ …; }` runs in the CURRENT
# shell, so an `exit` inside one DOES exit the program — calling it a subshell
# would flag every `|| { die …; }` in the repo, which is the single commonest
# correct spelling of a guard here.

printf '%s' '#!/usr/bin/env bash
die() { echo "boom: $*" >&2; exit 1; }
verb() { [[ -r "$REG" ]] || { die "unreadable"; }; echo fine; }
' > "$TMP/brace.sh"
printf 'brace.sh\n' > "$TMP/files3"
assert_empty "a \`die\` inside a BRACE GROUP is not a site (it exits the program)" \
    "$(cd "$REPO_ROOT" && python3 "$CORE" "$TMP" "$TMP/files3" 2>/dev/null)"

# …and its positive twin on the same shape, so the emptiness above cannot be
# a classifier that simply produced nothing for this file.
printf '%s' '#!/usr/bin/env bash
die() { echo "boom: $*" >&2; exit 1; }
verb() { [[ -r "$REG" ]] || { die "unreadable"; }; echo fine; }
caller() { local v; v=$(verb) || v=fallback; echo "$v"; }
' > "$TMP/brace2.sh"
printf 'brace2.sh\n' > "$TMP/files4"
assert_contains "…and the SAME brace group IS a site once its verb is substituted" \
    "$(cd "$REPO_ROOT" && python3 "$CORE" "$TMP" "$TMP/files4" 2>/dev/null)" \
    'verb->die->exit'

echo
# ===========================================================================
echo "=== 4. THE PARSER FAILS LOUD, NEVER SHORT ==="
# ===========================================================================
#
# Both bugs this classifier has had were parser LEAKS, and both produced a
# large, confident, entirely wrong answer rather than an error: 481 depth-0
# `assert_eq` calls reported as subshell sites the first time, five the second.
# A lint whose parser can fail silently is this repo's dominant defect class
# wearing a lint's clothes. So an unbalanced parse is a REFUSAL at rc 3, and
# that refusal is asserted here rather than assumed.

printf '%s' '#!/usr/bin/env bash
f() { echo "unterminated
' > "$TMP/broken.sh"
printf 'broken.sh\n' > "$TMP/files5"
_broken_out=$(cd "$REPO_ROOT" && python3 "$CORE" "$TMP" "$TMP/files5" 2>"$TMP/broken.err")
_broken_rc=$?
assert_eq "an unparseable file REFUSES (rc 3), it does not report zero sites" \
    "$_broken_rc" 3
assert_contains "…and says which file it could not parse" \
    "$(cat "$TMP/broken.err")" 'broken.sh'
assert_contains "…and says it is refusing rather than answering" \
    "$(cat "$TMP/broken.err")" 'Refusing'

# The here-string regression, kept because it cost the whole tail of a file.
# `<<<` is a here-STRING; parsed as a heredoc, its `"…"` becomes a DELIMITER
# and every line to EOF is blanked waiting for it — including the `)` that
# closed an enclosing subshell.
printf '%s' '#!/usr/bin/env bash
die() { echo "boom: $*" >&2; exit 1; }
_g() { [[ -r "$REG" ]] || die "no"; printf ok; }
probe() {
    grep -qxF x <<<"$(printf y)"
}
caller() { local v; v=$(_g) || v=fallback; echo "$v"; }
' > "$TMP/herestring.sh"
printf 'herestring.sh\n' > "$TMP/files6"
assert_contains "a \`<<<\` here-string does not swallow the rest of the file" \
    "$(cd "$REPO_ROOT" && python3 "$CORE" "$TMP" "$TMP/files6" 2>/dev/null)" \
    '_g->die->exit'

# A `&` that is part of a REDIRECTION is not backgrounding. Reading `2>&1` as
# `&` marked the whole statement a forked subshell and reported a main-shell
# call as a guard that does not gate (skeptic-channel.sh:1052).
printf '%s' '#!/usr/bin/env bash
die() { echo "boom: $*" >&2; exit 1; }
_g() { [[ -r "$REG" ]] || die "no"; printf ok; }
verb() { _g >/dev/null 2>&1 || true; echo done; }
' > "$TMP/redir.sh"
printf 'redir.sh\n' > "$TMP/files7"
assert_empty "\`2>&1\` is a redirection, not a fork — no site in the main shell" \
    "$(cd "$REPO_ROOT" && python3 "$CORE" "$TMP" "$TMP/files7" 2>/dev/null)"

echo
# ===========================================================================
echo "=== 5. THE LIVE TREE, AND THE MANIFEST RATCHET ==="
# ===========================================================================
#
# The floor is a NON-VACUITY ratchet, not a size assertion: an enumerator
# broken into returning nothing makes this lint report a clean sweep, and a
# clean sweep is indistinguishable downstream from a correct one.

_pop=$(_seg_files | grep -c .)
assert_eq "the population is a real corpus, not a silent zero (>400 files)" \
    "$(( _pop > 400 ))" 1
assert_contains "…and it includes the extensionless \`monitor/ng\`, which a \`*.sh\` glob misses" \
    "$(_seg_files)" 'monitor/ng'

_live=$(cd "$REPO_ROOT" && bash "$GEN" "$REPO_ROOT" 2>"$TMP/live.err")
_live_rc=$?
assert_eq "the live sweep completes (rc 0 — every file parsed balanced)" "$_live_rc" 0
assert_empty "…with nothing on stderr" "$(cat "$TMP/live.err")"

# THE RATCHET. Keys are `<file>\t<normalized line>\t<occurrence>` — CONTENT,
# never a line number, for `#1214`'s measured reason: one inserted line
# elsewhere in a file shifted three recorded sites and the guard reported three
# added and three removed for a tree in which nothing changed.
if [[ -r "$MANIFEST" ]]; then
    _live_keys="$TMP/live.keys"
    _man_keys="$TMP/man.keys"
    printf '%s\n' "$_live" | grep -a . | cut -f1-3 | LC_ALL=C sort > "$_live_keys"
    grep -av '^#' "$MANIFEST" | grep -a . | cut -f1-3 | LC_ALL=C sort > "$_man_keys"
    assert_empty "no site in the tree is missing from the manifest" \
        "$(comm -23 "$_live_keys" "$_man_keys")"
    assert_empty "no manifest row names a site that is no longer in the tree" \
        "$(comm -13 "$_live_keys" "$_man_keys")"
    _unrev=$(grep -av '^#' "$MANIFEST" | grep -a . | cut -f6 | grep -c '^unreviewed$')
    echo "    (manifest: $(grep -ac . "$_man_keys") rows, $_unrev unreviewed)"
fi

# A vanished assertion reddens here rather than shrinking the total in silence.
# The section-5 ratchet arm is CONDITIONAL on the manifest being readable, so a
# missing manifest would otherwise quietly cost two assertions and look green.
_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
if [[ "$_total" == "$EXPECTED_ASSERTIONS" ]]; then
    printf '  PASS: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS" >&2; _th_fail
fi

th_summary_and_exit
