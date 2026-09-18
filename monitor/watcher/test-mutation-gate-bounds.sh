#!/usr/bin/env bash
# The two properties `monitor/mutation-gate.sh` claims, executed
# (your-org/nexus-code#1032).
#
# Run: bash monitor/watcher/test-mutation-gate-bounds.sh
# Expected: ALL TESTS PASSED, exit 0.
#
# WHAT HAPPENED. An ad-hoc mutation gate commented line N of a two-line
# assertion. A trailing backslash inside a COMMENT does not continue the line,
# so line N+1 — the assertion's ARGUMENTS — became a standalone command. At one
# site those arguments began with a command substitution evaluating to `yes`,
# so the mutant ran the literal `yes yes`, wrote ~2 GB/s, and filled a 378 GB
# tmpfs SHARED BY THE WHOLE SANDBOX to 8 KB free. Seven of twenty-five mutants
# in that sweep landed on a continuation.
#
# THE TWO PROPERTIES, AND WHY BOTH ARE TESTED SEPARATELY.
#
#   (1) THE PREDICATE — never mutate a line that is not a complete logical
#       line. Necessary; not sufficient; and the thing a future author gets
#       wrong, because the class is bigger than the backslash that produced the
#       incident. §2 pins that: a trailing `&&` and a trailing `|` promote the
#       next line with no backslash anywhere, and `bash -n` says rc 0 to both.
#
#   (2) THE BOUND — timeout + file-size cap + a free-space floor. §4–§6 drive
#       the REAL `yes yes` through it. This is the property that has to hold
#       WHEN (1) HAS ALREADY FAILED, so it is exercised through the gate's own
#       `--run-bounded` entry point rather than through a mutation the
#       predicate would (correctly) refuse. Testing it any other way would
#       require first defeating (1), which is the one thing this file must not
#       do on a shared host.
#
# NON-VACUITY. A predicate that refuses EVERYTHING satisfies every negative
# assertion here for free, and would be worse than no predicate at all — the
# tool would be unusable and the suite would still be green. §3 is the positive
# control that forbids that reading: a genuinely standalone assertion line must
# be ACCEPTED, and an end-to-end experiment on it must reach a verdict.
#
# NEGATIVE CONTROLS FAIL FOR A NAMED REASON, never merely "non-zero". §4
# asserts rc **153** (128 + SIGXFSZ) and a capture of EXACTLY the cap, not just
# "it stopped": a runaway killed by the timeout instead would mean the
# file-size cap never fired, and the two bounds cover different holes.
#
# COVERAGE BOUNDARY, on the axis the MECHANISM varies on — WHICH SHELL
# CONSTRUCTS CONTINUE A LOGICAL LINE. §2 enumerates the constructs the
# predicate knows; the predicate's default arm is DENY, so an unenumerated
# construct costs a false REFUSAL and never a false ACCEPTANCE. What this file
# therefore does NOT claim is that the enumeration is complete — it cannot be,
# and §4–§6 exist precisely because it cannot be.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
GATE="$_test_dir/../mutation-gate.sh"
VICTIM="$_test_dir/test-claude-md-zsh-path-tie.sh"

# --- the `--population` protocol (your-org/nexus-code#803) -----------------
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' monitor/mutation-gate.sh
    printf '%s\n' "${VICTIM#$REPO_ROOT/}"
}
gp_handle "$@"

[[ -x "$GATE" ]] || { echo "missing or non-executable: $GATE" >&2; exit 2; }

WORK=$(mktemp -d "/tmp/mgb-$$-XXXXXX") || { echo "cannot mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# gate_rc <args...> -> prints "<rc>|<combined output>"
gate_rc() {
    local o rc
    o=$("$GATE" "$@" 2>&1); rc=$?
    printf '%s|%s' "$rc" "$o"
}

# ── §1  THE INCIDENT LINE ITSELF ────────────────────────────────────────
#
# Located by GREP, not pinned to a number. `#1032` reports line 158 at
# `d173c18`; a literal here would silently start measuring a different line the
# next time that file is edited, and would then pass while testing nothing.
echo '=== §1 the exact line that synthesized `yes yes` is refused, and so is its successor ==='
if [[ -r "$VICTIM" ]]; then
    # `grep -m1`, not `| head -1`: a `head` in the middle of a pipeline makes
    # this an early-exit reader whose status nothing consumes, which is a
    # construct `early-exit-readers.sh` enrols repo-wide. `-m1` gets the same
    # first match with grep's own rc still at the end of the pipe.
    L=$(grep -n -m1 'bot gh wrapper is still reachable' "$VICTIM" | cut -d: -f1)
    assert_not_contains "§1 the incident line is still locatable by content" "${L:-MISSING}" "MISSING"
    r=$(gate_rc --suite "$VICTIM" --line "$L")
    assert_eq       "§1 the continuation line is REFUSED (exit 3)"       "${r%%|*}" "3"
    assert_contains "§1 …naming the continuation token as the reason"    "${r#*|}"  "ends with a continuation token"
    r2=$(gate_rc --suite "$VICTIM" --line "$(( L + 1 ))")
    assert_eq       "§1 the line it would PROMOTE is refused too"        "${r2%%|*}" "3"
    assert_contains "§1 …naming the previous line as the reason"         "${r2#*|}"  "continues the previous line"
else
    th_abort "§1 needs $VICTIM; it is unreadable"
fi

# ── §2  THE CLASS IS NOT BACKSLASHES ────────────────────────────────────
echo '=== §2 the class: && and | promote the next line with no backslash, and bash -n says rc 0 ==='
mk() { printf '%s\n' "$@" > "$WORK/f.sh"; }

# 2a. Demonstrate the promotion is REAL for `&&`, then that the gate refuses it.
mk 'true &&' '  echo PROMOTED'
cp "$WORK/f.sh" "$WORK/f_and.sh"; sed -i '1s|^|# |' "$WORK/f_and.sh"
and_out=$(bash "$WORK/f_and.sh" </dev/null 2>&1)
bash -n "$WORK/f_and.sh" 2>/dev/null; and_syntax=$?
assert_contains "§2a a trailing && really promotes line 2 to a command" "$and_out" "PROMOTED"
assert_eq       "§2a …and bash -n calls the mutant VALID (rc 0)"        "$and_syntax" "0"
r=$(gate_rc --suite "$WORK/f.sh" --line 1 --match '.')
assert_eq       "§2a the gate refuses it anyway"                        "${r%%|*}" "3"
assert_contains "§2a …naming &&"                                        "${r#*|}"  "&&"

# 2b. Same with a pipe. Bounded with </dev/null throughout: an unbounded `tr`
#     inheriting a terminal is itself a hang, which is how this measurement was
#     first taken and lost.
mk 'printf "x\n" |' '  tr x Y'
r=$(gate_rc --suite "$WORK/f.sh" --line 1 --match '.')
assert_eq       "§2b a trailing | is refused"    "${r%%|*}" "3"
assert_contains "§2b …naming the pipe"           "${r#*|}"  "continuation token: |"

# 2c. A heredoc BODY is data, not code.
mk 'cat <<EOF' 'assert_eq "this is data" a a' 'EOF'
r=$(gate_rc --suite "$WORK/f.sh" --line 2 --match '.')
assert_eq       "§2c a line inside a heredoc body is refused" "${r%%|*}" "3"
assert_contains "§2c …naming the heredoc"                     "${r#*|}"  "heredoc"

# 2d. An unbalanced quote means the logical line runs past this one.
mk 'assert_eq "label" "a' 'b" "a\nb"'
r=$(gate_rc --suite "$WORK/f.sh" --line 1 --match '.')
assert_eq       "§2d an odd number of unescaped quotes is refused" "${r%%|*}" "3"
assert_contains "§2d …naming the quoting"                          "${r#*|}"  "quote"

# 2e. THE FULLY SILENT ONE — and this is the case to lead with, not the
#     backslash case, because the backslash case announces itself. Commenting
#     the MIDDLE of a continuation does two things at once: it TRUNCATES the
#     argument list of the joined command, and it PROMOTES the line after it.
#     The mechanism is that the backslash joins lines 1-2, the `#` then starts a
#     comment that swallows the rest of the joined line INCLUDING its own
#     trailing backslash (a backslash inside a comment is just text), so line 3
#     is left standing alone.
#
#     Measured: `echo START \` / `  middle \` / `  tail` prints `START middle
#     tail`; comment line 2 and it prints `START`, `tail` runs as a command
#     reading /dev/null, overall rc is 0 and `bash -n` is 0. Two silent failures
#     at once, every artefact well-formed, and the only evidence is an absence —
#     the MANUFACTURED-SUCCESS shape rather than the masked-failure shape.
#     (Contributed by an independent re-derivation asked to refute §2.)
mk 'echo START \' '  middle \' '  tail'
cp "$WORK/f.sh" "$WORK/f_mid.sh"; sed -i '2s|^|#|' "$WORK/f_mid.sh"
mid_unmut=$(timeout 5 bash "$WORK/f.sh"     </dev/null 2>&1)
mid_out=$(  timeout 5 bash "$WORK/f_mid.sh" </dev/null 2>&1); mid_rc=$?
bash -n "$WORK/f_mid.sh" 2>/dev/null; mid_syntax=$?
assert_eq "§2e control: unmutated, the whole argument list is one command" "$mid_unmut" "START middle tail"
assert_eq "§2e commenting the MIDDLE truncates it to just \"START\""       "$mid_out"   "START"
assert_eq "§2e …at rc 0, and bash -n agrees it is valid ($mid_syntax)"      "$mid_rc"    "0"
# All three lines must be refused: 1 and 2 END a continuation, 3 CONTINUES one.
mid_refused=0
for _l in 1 2 3; do
    r=$(gate_rc --suite "$WORK/f.sh" --line "$_l" --match '.')
    [ "${r%%|*}" = 3 ] && mid_refused=$(( mid_refused + 1 ))
done
assert_eq "§2e the gate refuses all THREE lines of that shape" "$mid_refused" "3"

# 2f. THE FALSE ACCEPTANCES A SKEPTIC MEASURED. `cat <<\\TAG` is a real POSIX
#     heredoc — the backslash quotes the delimiter exactly as `<<'TAG'` does —
#     and the opener regex recognised only the quoted and bare forms, so it
#     ACCEPTED it. Commenting that line promotes the heredoc BODY, and the body
#     driven end-to-end was `yes yes`: the #1032 payload, reached through the
#     predicate written to prevent it. The bound caught it (rc 153, 8192 B),
#     which is the layered design working — not a reason to leave the hole.
mk 'cat <<\BSLASHTAG' 'yes yes' 'BSLASHTAG'
r=$(gate_rc --suite "$WORK/f.sh" --line 1 --match '.')
assert_eq       "§2f a backslash-quoted heredoc opener is refused" "${r%%|*}" "3"
assert_contains "§2f …recognised AS a heredoc"                     "${r#*|}"  "opens a heredoc"
r=$(gate_rc --suite "$WORK/f.sh" --line 2 --match '.')
assert_contains "§2f …and its body is inside a heredoc body"       "${r#*|}"  "inside a heredoc body"
# Control: the quoted form must still be recognised, or 2f passes on a regex
# that stopped matching heredocs altogether.
mk "cat <<'QUOTEDTAG'" 'yes yes' 'QUOTEDTAG'
r=$(gate_rc --suite "$WORK/f.sh" --line 1 --match '.')
assert_contains "§2f control: the quoted form is still recognised" "${r#*|}" "opens a heredoc"

# 2g. THE REFUSAL MUST NAME THE TOKEN IT FOUND. Without a `break` the LAST
#     match won, so `&&` was reported as `continuation token: &` — a correct
#     refusal naming a construct that is not there, which sends the reader
#     looking for the wrong thing.
mk 'true &&' '  echo B'
r=$(gate_rc --suite "$WORK/f.sh" --line 1 --match '.')
assert_contains "§2g a trailing && is NAMED as &&, not as &" "${r#*|}" "continuation token: &&"

# ── §3  POSITIVE CONTROL — the predicate is not merely "refuse everything" ──
echo '=== §3 a genuinely standalone assertion IS accepted, and an experiment reaches a verdict ==='
# The fixture carries an EXACT COUNT GUARD, which is what makes the kill
# ATTRIBUTABLE: the suite reddens AND its declared total moves, so the gate can
# name a witness instead of reporting a bare "KILLED". `#1032` round 2 produced
# a red whose total was 16 before and 16 after — a kill for the wrong reason,
# which is exactly what a witness requirement refuses to count.
cat > "$WORK/mini.sh" <<'MINI'
#!/usr/bin/env bash
set -uo pipefail
P=0; F=0
assert_eq() { if [ "$2" = "$3" ]; then P=$((P+1)); echo "  PASS: $1"; else F=$((F+1)); echo "  FAIL: $1"; fi; }
assert_eq "one" a a
assert_eq "two" b b
[ $((P+F)) -eq 2 ] || { echo "  FAIL: ASSERTION COUNT MISMATCH — $((P+F)) ran, 2 expected"; F=$((F+1)); }
echo "=== summary: $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
MINI
chmod +x "$WORK/mini.sh"
lst=$("$GATE" --suite "$WORK/mini.sh" --list 2>&1)
assert_contains "§3 --list offers the standalone assertion lines" "$lst" 'assert_eq "one" a a'
r=$(gate_rc --suite "$WORK/mini.sh" --line 5 --timeout 30 --cap-kb 1024)
assert_eq       "§3a a count-guarded suite yields a KILL (exit 0)" "${r%%|*}" "0"
assert_contains "§3a the kill is ATTRIBUTED, not merely reported"  "${r#*|}"  "killed-by-assertion"
assert_contains "§3a …and the witness names the moving total"      "${r#*|}"  "the declared total moved (2 -> 1)"
# AND it is labelled as the WEAKER witness it is. A count-guarded suite reddens
# on every deletion mutant, so "the total moved" is always available there and
# says nothing about whether line 5 was load-bearing. Reporting it as a plain
# kill would dress the count guard up as evidence about the assertion — the
# exact confusion #1032 round 2 produced from the other direction.
assert_contains "§3a …labelled COUNT GUARD ONLY, not as evidence about that line" \
                "${r#*|}" "COUNT GUARD ONLY"

# §3b THE OTHER VERDICT, and the reason §3a is not vacuous. The SAME mutation
# on a suite with NO count guard leaves it green: nothing else in it asserts
# what line 5 asserts. A gate that called that a kill would be manufacturing
# coverage; a gate that called everything a kill would pass §3a for free.
sed '/ASSERTION COUNT MISMATCH/d' "$WORK/mini.sh" > "$WORK/mini-unguarded.sh"
chmod +x "$WORK/mini-unguarded.sh"
r=$(gate_rc --suite "$WORK/mini-unguarded.sh" --line 5 --timeout 30 --cap-kb 1024)
assert_eq       "§3b the same mutation SURVIVES an unguarded suite (exit 4)" "${r%%|*}" "4"
assert_contains "§3b …reported as survived, with the mutation proven applied" "${r#*|}" "VERDICT: survived"

# ── §4  THE BOUND CONTAINS THE REAL RUNAWAY ─────────────────────────────
echo '=== §4 `yes yes` under the bound: 64 KB, not 223 GB ==='
printf '%s\n' '#!/usr/bin/env bash' 'yes yes' > "$WORK/runaway.sh"; chmod +x "$WORK/runaway.sh"
rb=$("$GATE" --run-bounded "$WORK/runaway.sh" --cap-kb 64 --timeout 20 2>&1); rb_rc=$?
assert_eq       "§4 the runaway is CONTAINED (exit 5)"                    "$rb_rc" "5"
assert_contains "§4 …by the FILE-SIZE CAP specifically, not the timeout"  "$rb" "FILE-SIZE CAP"
assert_contains "§4 …with rc 153, i.e. 128 + SIGXFSZ"                     "$rb" "rc=153"
assert_contains "§4 …and the capture is exactly the cap, 65536 bytes"     "$rb" "bytes=65536"

# ── §5  THE LIMIT IS AN RLIMIT, SO IT REACHES CHILDREN ──────────────────
#
# The #1032 mutant's runaway was not the mutant itself but a command it
# synthesized and exec'd. A cap that applied only to the immediate child would
# have contained nothing.
echo '=== §5 the cap is inherited by a grandchild ==='
printf '%s\n' '#!/usr/bin/env bash' "exec bash $WORK/inner.sh" > "$WORK/outer.sh"
printf '%s\n' '#!/usr/bin/env bash' 'yes yes' > "$WORK/inner.sh"; chmod +x "$WORK/outer.sh" "$WORK/inner.sh"
rb=$("$GATE" --run-bounded "$WORK/outer.sh" --cap-kb 64 --timeout 20 2>&1); rb_rc=$?
assert_eq       "§5 a grandchild runaway is contained too"  "$rb_rc" "5"
assert_contains "§5 …by the same file-size cap"             "$rb" "FILE-SIZE CAP"

# ── §6  THE HOLE THE CAP CANNOT COVER, AND WHAT COVERS IT ───────────────
#
# Recorded because a bound whose hole is undocumented is a bound people
# over-trust. `ulimit -f` limits REGULAR-FILE writes; a mutant streaming into a
# PIPE is unbounded in bytes. The wall clock is what stops it.
echo '=== §6 a pipe is NOT bounded by ulimit -f; the timeout is ==='
printf '%s\n' '#!/usr/bin/env bash' 'yes yes | wc -c' > "$WORK/pipe.sh"; chmod +x "$WORK/pipe.sh"
rb=$("$GATE" --run-bounded "$WORK/pipe.sh" --cap-kb 64 --timeout 6 2>&1); rb_rc=$?
assert_eq       "§6 the piped runaway is still contained"        "$rb_rc" "5"
assert_contains "§6 …by the WALL CLOCK, proving the hole is real" "$rb" "wall-clock timeout"

# 6b. Positive control for the bound itself: a well-behaved script must NOT be
#     contained, or §4–§6 would pass on a runner that stops everything.
printf '%s\n' '#!/usr/bin/env bash' 'echo fine' > "$WORK/fine.sh"; chmod +x "$WORK/fine.sh"
rb=$("$GATE" --run-bounded "$WORK/fine.sh" --cap-kb 64 --timeout 20 2>&1); rb_rc=$?
assert_eq       "§6b control: a well-behaved script is NOT contained" "$rb_rc" "0"
assert_contains "§6b …it completed on its own"                        "$rb" "COMPLETED"

# ── §6c  THE HOLE THAT MATTERS MOST: `ulimit -f` IS PER FILE ────────────
#
# Not a total budget. A mutant that writes MANY files, each inside the cap,
# satisfies `ulimit -f` completely and consumes the filesystem anyway — and
# unlike the pipe case it does not even need to run long, so the wall clock does
# not see it either. This is `#1032` reproduced WITH the cap in place and the cap
# never firing, and the `df` drop check is the only one of the three bounds that
# notices. It is measured rather than argued because "the cap already covers it"
# is exactly the reasoning that would delete the check.
echo '=== §6c ulimit -f is PER FILE — many compliant files still eat the disk ==='
mfd="$WORK/manyout"
cat > "$WORK/many.sh" <<MANY
#!/usr/bin/env bash
mkdir -p "$mfd"
for i in \$(seq 1 64); do dd if=/dev/zero of="$mfd/f\$i" bs=1M count=1 2>/dev/null; done
MANY
chmod +x "$WORK/many.sh"
rb=$("$GATE" --run-bounded "$WORK/many.sh" --cap-kb 1024 --timeout 60 --max-drop-mb 0 2>&1); rb_rc=$?
mf_n=$(ls "$mfd" 2>/dev/null | grep -c .)
assert_eq       "§6c control: all 64 files were written, each within the 1 MB cap" "$mf_n" "64"
assert_eq       "§6c the df DROP check halts (exit 5) where the size cap did not"  "$rb_rc" "5"
assert_contains "§6c …naming what the cap could account for"                       "$rb" "HALTING"
assert_contains "§6c …and saying the writes went where ulimit -f does not reach"   "$rb" "does not reach"
rm -rf "$mfd"
# CONTROL for the control: with the DEFAULT allowance the same run must NOT
# halt, or §6c would pass on a check that fires unconditionally.
rb=$("$GATE" --run-bounded "$WORK/many.sh" --cap-kb 1024 --timeout 60 2>&1); rb_rc=$?
rm -rf "$mfd"
assert_eq "§6c control: the DEFAULT drop allowance does not halt the same run" "$rb_rc" "0"

# ── §7  A MUTATION MUST BE PROVEN TO HAVE APPLIED (#938) ────────────────
#
# An INERT mutant and a genuinely surviving one produce byte-identical output.
# Mutating a line that is already a comment is the cheapest inert mutation
# there is, and the gate must refuse it rather than report SURVIVED.
echo '=== §7 an inert mutation is refused, not reported as SURVIVED ==='
mk '# assert_eq "already a comment" a a' 'true'
r=$(gate_rc --suite "$WORK/f.sh" --line 1 --match '.')
assert_eq       "§7 mutating an existing comment is refused" "${r%%|*}" "3"
assert_contains "§7 …naming it as already a comment"         "${r#*|}"  "already a comment"

# ── §8  A KILL AGAINST A RED BASELINE IS NOT EVIDENCE ───────────────────
echo '=== §8 a suite that is already red cannot be "killed" ==='
cat > "$WORK/red.sh" <<'RED'
#!/usr/bin/env bash
set -uo pipefail
assert_eq() { echo "  FAIL: $1"; }
assert_eq "this suite is red before anything is mutated" a b
exit 1
RED
chmod +x "$WORK/red.sh"
r=$(gate_rc --suite "$WORK/red.sh" --line 4 --timeout 30 --cap-kb 1024 --match '.')
assert_eq       "§8 a red baseline refuses the experiment (exit 3)" "${r%%|*}" "3"
assert_contains "§8 …saying the baseline was not green"             "${r#*|}"  "not green"

# EXPECTED-COUNT GUARD.
#   §1 5 · §2 19 · §3 7 · §4 4 · §5 2 · §6 4 · §6c 5 · §7 2 · §8 2
EXPECTED=$(( 5 + 19 + 7 + 4 + 2 + 4 + 5 + 2 + 2 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
