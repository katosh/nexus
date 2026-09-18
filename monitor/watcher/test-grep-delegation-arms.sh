#!/usr/bin/env bash
# test-grep-delegation-arms.sh — your-org/nexus-code#1234.
#
# Run: bash monitor/watcher/test-grep-delegation-arms.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHAT THIS SUITE IS FOR, AND THE LINE IT WILL NOT CROSS. Claude Code's shell
# snapshot installs `grep` as a shell function whose leading `case` DELEGATES
# some arguments to `command grep` instead of the embedded ugrep. Two CLAUDE.md
# entries straddle that split. The arm set is a HARNESS-BUILD property, so a
# suite that asserted THIS host's arms would be green for this operator and red
# for every other one — a defect, not a guard, and the one shape `#1234`
# explicitly warns against.
#
# So: every ASSERTION below is driven against PLANTED snapshots, which are the
# same on every host. The live harness is exercised once, and the only thing
# asserted about it is that no documented dependency is BROKEN — a claim that is
# true wherever the documentation is true, and whose failure means the
# documentation really is invalid on that host. `NOT APPLICABLE` (a plain bash
# host, CI) and `UNREVIEWED` (an unrecorded cc build) both pass, because neither
# says anything is wrong.
#
# WHAT IT CANNOT SEE, stated because a green here is narrower than it looks:
#   * a change in what ugrep DOES with an argument it still accepts — same arms,
#     different behaviour — is invisible;
#   * the tool reads a snapshot FILE, so a harness that stops writing one
#     degrades to NOT APPLICABLE, which is honest and is not a check;
#   * nothing here makes an UNREVIEWED bump red. That belongs at the cc-update
#     gate, where a human is already reading a changelog.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
SUT="$REPO_ROOT/monitor/grep-delegation-arms.sh"
REAL_MANIFEST="$REPO_ROOT/monitor/grep-delegation-arms.manifest"

. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$SUT" "$REAL_MANIFEST" "$REPO_ROOT/CLAUDE.md"; }
gp_handle "$@"

WORK=$(mktemp -d -t nexus-grepdel-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

assert_file_exists "the tool exists" "$SUT"
assert_file_exists "the manifest exists" "$REAL_MANIFEST"

# ---- fixture snapshots ----------------------------------------------------
# A snapshot is only ever read for its `grep` function, so the plants carry
# exactly that, in the shape the real one has.
REAL_ARMS='-*-filter*|-*-pager*|-*-view*|-*-format-open*|-*-config*|---*|-@*|-*-save-config*|-[Zz]*|-[!-]*[Zz]*|--null|--null-data'

plant_snapshot() {   # <path> <arm-set>
    cat > "$1" <<EOF
# planted fixture
function grep {
  local _cc_a
  for _cc_a in \${1+"\$@"}; do
    case "\$_cc_a" in $2) command grep \${1+"\$@"}; return ;; esac
  done
  ARGV0=ugrep "\$_cc_bin" -G --ignore-files \${1+"\$@"}
}
EOF
}

SNAP_OK="$WORK/snap-ok.sh";        plant_snapshot "$SNAP_OK" "$REAL_ARMS"
# `---*` removed: the DASH-PATTERN-OPTION dependency must break.
SNAP_NODASH="$WORK/snap-nodash.sh"
plant_snapshot "$SNAP_NODASH" "${REAL_ARMS/|---\*/}"
# An arm that swallows the GREP-BRE-DIALECT pattern: its REACHES row must break.
SNAP_EATSBRE="$WORK/snap-eatsbre.sh"; plant_snapshot "$SNAP_EATSBRE" "$REAL_ARMS|^*"
# Semantically IDENTICAL, textually different — reordered arms.
SNAP_REWORDED="$WORK/snap-reworded.sh"
plant_snapshot "$SNAP_REWORDED" '--null|--null-data|---*|-@*|-[Zz]*|-[!-]*[Zz]*|-*-filter*|-*-pager*|-*-view*|-*-format-open*|-*-config*|-*-save-config*'
# No `grep` function at all — a plain bash host, or CI.
SNAP_NONE="$WORK/snap-none.sh";     printf '# nothing here\nalias ll=ls\n' > "$SNAP_NONE"
# A `grep` function with no delegation loop.
SNAP_NOCASE="$WORK/snap-nocase.sh"
printf '# planted\nfunction grep {\n  ARGV0=ugrep "$_cc_bin" -G ${1+"$@"}\n}\n' > "$SNAP_NOCASE"

# ---- fixture manifests ----------------------------------------------------
MAN_OK="$WORK/man-ok.tsv"
{
    printf '# fixture\n'
    printf 'ARMS\tfixture-1.0.0\t%s\n' "$REAL_ARMS"
    printf 'DELEGATES\t---\tDASH-PATTERN-OPTION\tMode 1 stops being loud.\n'
    printf 'REACHES\t^\\+\\+\\+\tGREP-BRE-DIALECT\tthe bare call stops being the loud one.\n'
} > "$MAN_OK"
MAN_EMPTY="$WORK/man-empty.tsv"; printf '# only a record, no dependencies\nARMS\tfixture-1.0.0\t%s\n' "$REAL_ARMS" > "$MAN_EMPTY"

# ---- a `claude` stub so the version is a controlled input -----------------
BIN="$WORK/bin"; mkdir -p "$BIN"
mk_claude() { printf '#!/usr/bin/env bash\necho "%s (Claude Code)"\n' "$1" > "$BIN/claude"; chmod +x "$BIN/claude"; }
mk_claude fixture-1.0.0

run_sut() {   # <args…> ; sets rc/out/err
    local o e; o=$(mktemp); e=$(mktemp)
    # `env -u BASH_ENV` is load-bearing, not tidiness. This nexus exports
    # BASH_ENV, bash sources it at the start of every NON-interactive shell, and
    # `locals-env.sh` re-fronts PATH there — so a caller's own prepend LOSES.
    # Measured: `PATH=$BIN:$PATH bash -c 'claude --version'` -> the real 2.1.246;
    # the same with BASH_ENV unset -> the stub. Without this the cc version is
    # not a controlled input and two of the arms below silently test something
    # else (they did, on the first draft).
    env -u BASH_ENV PATH="$BIN:$PATH" bash "$SUT" "$@" >"$o" 2>"$e"
    rc=$?; out=$(<"$o"); err=$(<"$e"); rm -f "$o" "$e"
}
rc=0; out=""; err=""

echo '=== the four outcomes, driven by planted snapshots ==='
run_sut --snapshot "$SNAP_OK" --manifest "$MAN_OK"
assert_eq       "recorded version + matching arms + deps hold -> 0" "$rc" "0"
assert_contains "…and it says so"                                   "$out" "all hold"

run_sut --snapshot "$SNAP_NONE" --manifest "$MAN_OK"
assert_eq       "no grep function -> NOT APPLICABLE (3), never a failure" "$rc" "3"
assert_contains "…and it refuses to read as a clearance"                 "$out" "Not a clearance"

run_sut --snapshot "$SNAP_NOCASE" --manifest "$MAN_OK"
assert_eq "a grep function with no delegation case -> 3" "$rc" "3"

mk_claude unrecorded-9.9.9
run_sut --snapshot "$SNAP_OK" --manifest "$MAN_OK"
assert_eq       "an UNRECORDED cc version -> UNREVIEWED (4), not a failure" "$rc" "4"
assert_contains "…and it points at the cc-update gate"                      "$out" "nexus.cc-update"
mk_claude fixture-1.0.0

echo '=== a BROKEN dependency is the ONE failure, and it names the entry ==='
run_sut --snapshot "$SNAP_NODASH" --manifest "$MAN_OK"
assert_eq       "'---*' removed -> BROKEN (1)"                  "$rc" "1"
assert_contains "…naming the CLAUDE.md block it invalidates"    "$err" "DASH-PATTERN-OPTION"
assert_contains "…and saying which way it moved"                "$err" "live      : REACHES"

run_sut --snapshot "$SNAP_EATSBRE" --manifest "$MAN_OK"
assert_eq       "an arm that swallows the BRE pattern -> BROKEN (1)" "$rc" "1"
assert_contains "…naming the other block"                            "$err" "GREP-BRE-DIALECT"

echo '=== the check EVALUATES the arms; it does not string-compare them ==='
# The whole design rests on this: a reworded but equivalent arm set must NOT be
# a failure, or the tool is a text diff of somebody else's binary and every
# harmless upstream reformatting is a false red.
run_sut --snapshot "$SNAP_REWORDED" --manifest "$MAN_OK"
assert_eq       "reordered but equivalent arms: dependencies still hold" \
    "$( (( rc == 1 )) && echo broken || echo hold )" "hold"
assert_eq       "…reported as UNREVIEWED (4), not BROKEN"       "$rc" "4"
assert_contains "…and the review note shows both arm sets"      "$out" "recorded:"

echo '=== a manifest with no dependencies REFUSES rather than passing vacuously ==='
# "0 dependencies, all hold" and "every dependency holds" print the same thing.
run_sut --snapshot "$SNAP_OK" --manifest "$MAN_EMPTY"
assert_eq       "no DELEGATES/REACHES rows -> usage refusal (2)" "$rc" "2"
assert_contains "…saying a green would assert nothing"           "$err" "would assert nothing"

echo '=== the REAL manifest is well-formed and its citations exist ==='
# A citation that names a CLAUDE.md block which is not there is its own defect,
# and a quieter one than being wrong: the reader finds real prose, does not find
# the shape they were told to look for, and cannot tell which end is at fault.
bad_block=""; dep_rows=0
while IFS=$'\t' read -r kind a b c; do
    case "${kind:-}" in
        DELEGATES|REACHES)
            dep_rows=$(( dep_rows + 1 ))
            grep -qF -e "<!-- BEGIN $b -->" -- "$REPO_ROOT/CLAUDE.md" || bad_block+="$b "
            [[ -n "${c:-}" ]] || bad_block+="$b(no-consequence) "
            ;;
    esac
done < <(awk 'NF && $0 !~ /^#/' "$REAL_MANIFEST")
assert_eq "every cited CLAUDE.md block really exists, and every row states a consequence" \
    "$bad_block" ""
assert_eq "the real manifest declares a non-trivial set of dependencies" \
    "$( (( dep_rows >= 2 )) && echo yes || echo no )" "yes"

echo '=== the LIVE harness — reported always, asserted only where it is portable ==='
# The one live claim: no documented dependency is BROKEN. True wherever the
# documentation is true; its failure means CLAUDE.md is genuinely invalid on
# THIS host, which is a red that host deserves. 3 and 4 pass — neither says
# anything is wrong.
live_rc=0
live_out=$(bash "$SUT" 2>&1) || live_rc=$?
printf '%s\n' "$live_out" | sed 's/^/    /'
assert_eq "live harness: no documented dependency is broken here" \
    "$( (( live_rc == 1 )) && echo broken || echo ok )" "ok"
assert_eq "live harness: the tool did not refuse (usage/manifest error)" \
    "$( (( live_rc == 2 )) && echo refused || echo ran )" "ran"

# ---- assertion-count guard -----------------------------------------------
EXPECTED_ASSERTIONS=23
TOTAL=$(( PASS + FAIL ))
assert_eq "assertion TOTAL matches the expected total" "$TOTAL" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
