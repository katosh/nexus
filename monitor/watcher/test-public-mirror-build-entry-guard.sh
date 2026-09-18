#!/usr/bin/env bash
# `public-mirror/build.sh` must not destroy a tree it was pointed at by accident
# (your-org/nexus-code#1001).
#
# Run: bash monitor/watcher/test-public-mirror-build-entry-guard.sh
# Expected: ALL TESTS PASSED, exit 0.
#
# WHAT HAPPENED. `build.sh` rewrites every tracked file of its cwd IN PLACE and
# `rm -rf`s every `exclude` path. It was run in a chain whose earlier `cd` had
# failed (a `git clone --local` hit `Invalid cross-device link`, and `zsh` does
# not abort a `&&`-less chain on a failed `cd`), so the build ran in the LIVE
# WORKING TREE: 513 files rewritten, the redaction dictionary and the whole
# overlay directory deleted. It is self-concealing twice over — the scrub
# rewrites rather than reports, so `git status` afterwards is a wall of
# plausible modifications; and its blast radius includes the dictionary you
# would use to find out what it did.
#
# EVERY FIXTURE HERE IS A THROWAWAY `git init` REPO UNDER `mktemp -d`. This
# suite never invokes `build.sh` anywhere else, and in particular never in the
# repo it lives in. That is not caution, it is the subject matter.
#
# ── THE ASSERTION THAT CARRIES THE SUITE ────────────────────────────────
#
# `exit 6` is not the property. A guard could exit 6 having already scrubbed
# half the tree, and every assertion about the exit code would still pass. So
# each refusal arm is paired with a WHOLE-TREE CHECKSUM taken before and after,
# and the assertion is that the checksum is UNCHANGED. That is the property:
# nothing happened.
#
# ── NON-VACUITY ─────────────────────────────────────────────────────────
#
# A `build.sh` that refused everything would satisfy every refusal assertion
# here for free, and would also be useless. §3 and §4 are the positive
# controls: with the flag, the build must RUN — exit 0, checksum CHANGED, and
# the excluded dictionary really gone. A green in §1/§2 means nothing without
# them.
#
# ── COVERAGE BOUNDARY, on the axis the MECHANISM varies on ──────────────
#
# The mechanism varies on WHICH TREE THE PROCESS IS STANDING IN, and no entry
# check can tell "the tree I meant" from "the tree I am in". What is pinned
# here is that the two shapes the incident actually had — a FLAGLESS
# invocation, and a target with uncommitted work in it — are both refused
# without touching a byte. A deliberate `--yes --allow-dirty` typed in the
# wrong clean tree is exactly as destructive as before, and this suite does not
# claim otherwise.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
TOOLKIT="$REPO_ROOT/monitor/public-mirror"

# --- the `--population` protocol (your-org/nexus-code#803) -----------------
# The guarded script, the scrubber it drives, and every in-tree caller whose
# invocation had to change — enumerated by grep, never hand-listed.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    # What this guard's BYTES actually read: the guarded script (copied into
    # every fixture and executed), the scrubber it drives, and every in-tree
    # caller whose invocation had to change — the callers are declared because
    # §3/§4 assert the exit contract those call sites now depend on, so an edit
    # that drops a `--yes` is exactly the edit this guard should be selected by.
    #
    # THE KEY IS APPLICABILITY, NOT CONFORMANCE (your-org/nexus-code#1197).
    # This enumerated `build\.sh"? +--yes` — it keyed on the COMPLIANT
    # CONSTRUCT. The population was therefore the set of callers that ALREADY
    # PASS `--yes`, so a caller that stops passing it LEAVES the population,
    # and the guard deselects on precisely the edit the comment above says it
    # exists to be selected by. The predicate deleted its own evidence.
    #
    # Measured on a throwaway clone at 50c36efc7ef3, changed-file list held
    # constant at `monitor/public-mirror/sync-base.sh` and the edit
    # (dropping `--yes` at sync-base.sh:104, the one production caller) the
    # only variable: 6 guards SELECTED before, 5 after — this one gone, listed
    # under CONSIDERED AND EXCLUDED with `population 7 files`, exit 0. Note the
    # signature is worse than an empty selection: the report stays FULL and
    # every surviving line is TRUE, so a reader following CLAUDE.md's "read the
    # list, not the count" rule concludes this guard was evaluated and ruled
    # out. It was. The ruling was correct about a population that had just
    # dropped the file in question. None of the five survivors asserts anything
    # about `--yes`; they select `sync-base.sh` for being a shell file.
    #
    # `build\.sh` alone is the applicability key — "names build.sh at all",
    # whether or not it complies. It is bare rather than path-qualified on
    # purpose: `sync-base.sh` invokes it as `bash "$REL_PM/build.sh"`, through a
    # VARIABLE, so a `public-mirror/build\.sh` pattern matches 4 files and drops
    # the one production caller — which is also one of this row's declared
    # sentinels. Exactly one `build.sh` is tracked in this repo
    # (`git ls-files | grep '/build\.sh$'`), so the bare form is unambiguous.
    # Measured across the same two arms: 10 files both times, `sync-base.sh`
    # present both times. A population that does not move when its subject
    # breaks is the property being bought here.
    #
    # `--yes` is now the ASSERTION (§3/§4), never the FILTER. That is the whole
    # correction: a guard may not decide who it watches by asking who is
    # already behaving.
    printf '%s\n' monitor/public-mirror/build.sh monitor/public-mirror/scrub.pl
    ( cd "$REPO_ROOT" && git grep -lE 'build\.sh' -- '*.sh' )
}
gp_handle "$@"

for f in build.sh scrub.pl; do
    [[ -r "$TOOLKIT/$f" ]] || { echo "missing $TOOLKIT/$f" >&2; exit 2; }
done
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl not installed (scrub.pl needs it)"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 77; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pmguard.XXXXXX") || { echo "cannot mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# fixture <name> -> prints the repo path. A committed, CLEAN git repo carrying
# a copy of the toolkit and a synthetic dictionary. Nothing internal: the
# vocabulary below is invented for this file.
fixture() {
    local repo="$WORK/$1"
    mkdir -p "$repo/pm"
    cp "$TOOLKIT/scrub.pl" "$TOOLKIT/build.sh" "$repo/pm/"
    cat > "$repo/pm/mapping.tsv" <<'MAP'
map	fixtureorg/thing	public-org/thing	<public-org>/thing
map	fixtureorg	public-org	<public-org>
deny	fixtureorg
keep	public-org
exclude	pm/mapping.tsv
MAP
    printf 'a reference to fixtureorg lives here\n' > "$repo/payload.txt"
    printf 'see fixtureorg/thing\n'                 > "$repo/doc.md"
    ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
        && git add -A && git commit -qm init ) >/dev/null 2>&1
    printf '%s' "$repo"
}

# Whole-tree fingerprint: every file's path AND content. This is what proves
# "nothing happened" — an exit code alone proves only where the script stopped
# printing, not what it had already done.
fingerprint() {
    ( cd "$1" && find . -path ./.git -prune -o -type f -print0 2>/dev/null \
        | sort -z | xargs -0 cksum 2>/dev/null | cksum )
}

run_build() {   # <repo> <args...> -> "<rc>|<output>"
    local repo="$1"; shift
    local o rc
    o=$( cd "$repo" && bash pm/build.sh "$@" 2>&1 ); rc=$?
    printf '%s|%s' "$rc" "$o"
}

# ── §1  NO FLAG: DRY RUN, EXIT 6, AND NOT ONE BYTE TOUCHED ──────────────
#
# This is the incident's own shape: the documented recipe carried no flags, so
# the command that ran carried none.
echo '=== §1 a flagless invocation reports and changes nothing ==='
r1=$(fixture clean1); before=$(fingerprint "$r1")
out=$(run_build "$r1")
after=$(fingerprint "$r1")
assert_eq       "§1 a flagless build exits 6, not 0"        "${out%%|*}" "6"
assert_eq       "§1 …and the tree is byte-identical after"  "$after" "$before"
assert_contains "§1 …having announced itself as a DRY RUN"  "${out#*|}" "DRY RUN"
assert_contains "§1 …and named the destructive deletion"    "${out#*|}" "rm -rf pm/mapping.tsv"
assert_file_exists "§1 …and the dictionary it would delete is still there" "$r1/pm/mapping.tsv"

# ── §2  DIRTY TREE: EXIT 7, AND NOT ONE BYTE TOUCHED ────────────────────
#
# The version of the incident that is NOT recoverable. `#1001` got its tree
# back with `git reset --hard` because nothing was uncommitted; the same
# accident on a tree with work in it loses that work with no trace, because the
# scrub rewrites rather than reports.
echo '=== §2 a tree with uncommitted work is refused even WITH --yes ==='
r2=$(fixture dirty1)
printf 'work in progress that would be lost\n' >> "$r2/payload.txt"
before=$(fingerprint "$r2")
out=$(run_build "$r2" --yes)
after=$(fingerprint "$r2")
assert_eq       "§2 --yes alone on a dirty tree exits 7"     "${out%%|*}" "7"
assert_eq       "§2 …and the tree is byte-identical after"   "$after" "$before"
assert_contains "§2 …naming the uncommitted changes"         "${out#*|}" "uncommitted change"
assert_contains "§2 …and offering the explicit override"     "${out#*|}" "--yes --allow-dirty"
assert_contains "§2 control: the uncommitted work survived"  "$(cat "$r2/payload.txt")" "work in progress"

# ── §3  POSITIVE CONTROL — WITH THE FLAG, IT STILL WORKS ────────────────
#
# Without this, a `build.sh` that refused unconditionally would pass §1 and §2
# and ship broken.
echo '=== §3 --yes on a clean tree still builds ==='
r3=$(fixture clean2); before=$(fingerprint "$r3")
out=$(run_build "$r3" --yes)
after=$(fingerprint "$r3")
assert_eq          "§3 --yes exits 0"                              "${out%%|*}" "0"
assert_contains    "§3 …and reports the scrub applied"             "${out#*|}" "scrub applied"
[[ "$after" != "$before" ]] && { printf '  PASS: §3 …and the tree really changed\n'; _th_pass; } \
                           || { printf '  FAIL: §3 the tree did NOT change — the build did nothing\n' >&2; _th_fail; }
assert_no_file     "§3 …the excluded dictionary is gone, as designed" "$r3/pm/mapping.tsv"
assert_not_contains "§3 …and the scrub really scrubbed"            "$(cat "$r3/payload.txt")" "fixtureorg"

# ── §4  THE DELIBERATE DIRTY BUILD ──────────────────────────────────────
#
# Two in-tree suites build a throwaway clone carrying the author's UNSTAGED
# working-tree diff on purpose, so this path has to keep working — and has to
# be spelled out loud rather than defaulted.
echo '=== §4 --yes --allow-dirty builds a deliberately dirty tree ==='
r4=$(fixture dirty2)
printf 'carried, unstaged, on purpose\n' >> "$r4/payload.txt"
before=$(fingerprint "$r4")
out=$(run_build "$r4" --yes --allow-dirty)
after=$(fingerprint "$r4")
assert_eq "§4 --yes --allow-dirty exits 0" "${out%%|*}" "0"
[[ "$after" != "$before" ]] && { printf '  PASS: §4 …and the tree really changed\n'; _th_pass; } \
                           || { printf '  FAIL: §4 the tree did NOT change\n' >&2; _th_fail; }

# ── §5  THE ENV FORM, FOR NON-INTERACTIVE CALLERS ───────────────────────
echo '=== §5 NEXUS_MIRROR_BUILD_OK=1 is equivalent to --yes ==='
r5=$(fixture clean3); before=$(fingerprint "$r5")
o=$( cd "$r5" && NEXUS_MIRROR_BUILD_OK=1 bash pm/build.sh 2>&1 ); rc5=$?
after=$(fingerprint "$r5")
assert_eq "§5 the env opt-in exits 0" "$rc5" "0"
[[ "$after" != "$before" ]] && { printf '  PASS: §5 …and the tree really changed\n'; _th_pass; } \
                           || { printf '  FAIL: §5 the tree did NOT change\n' >&2; _th_fail; }

# ── §6  THE POSITIONAL ARGUMENT SURVIVED THE FLAGS ──────────────────────
#
# `build.sh [<mapping.tsv>]` is the documented signature and three in-tree
# callers use it. Adding flag parsing is exactly the change that silently eats
# a positional.
echo '=== §6 the positional <mapping.tsv> still works alongside the flags ==='
r6=$(fixture clean4)
# COMMITTED, not merely created: an untracked file is a dirty tree, and §2's
# refusal would then fire first and mask what §6 is testing. (It did, on this
# suite's first run — which is the dirty-tree guard demonstrating itself.)
cp "$r6/pm/mapping.tsv" "$r6/pm/alt.tsv"
( cd "$r6" && git add -A && git commit -qm alt ) >/dev/null 2>&1
out=$(run_build "$r6" --yes pm/alt.tsv)
assert_eq       "§6 --yes <mapping> exits 0"                  "${out%%|*}" "0"
assert_contains "§6 …and the named mapping was the one used"  "${out#*|}" "scrub applied"
r7=$(fixture clean5)
out=$(run_build "$r7" pm/mapping.tsv)
assert_eq "§6 a positional WITHOUT --yes is still a dry run (exit 6)" "${out%%|*}" "6"
out=$(run_build "$r7" --yes /nonexistent/map.tsv)
assert_eq "§6 an unreadable mapping still exits 2, before any guard" "${out%%|*}" "2"

# ── §7  THE SCRIPT'S OWN FAILED-cd — #1001'S MECHANISM, INSIDE build.sh ──
#
# `build.sh` established its target as
# `root=$(git rev-parse --show-toplevel) && cd "$root"` under `set -uo pipefail`
# with NO `-e`. Outside a work tree that assigns `root` the EMPTY STRING — so
# `set -u` never fires — the `&&` short-circuits, and the script CARRIES ON IN
# THE CALLER'S CWD, resolving every relative path against it.
#
# That is `#1001`'s exact mechanism inside the script `#1001` is about: the
# incident was a failed `cd` in the CALLER's chain, this is a failed `cd` in the
# script's own. All eight call sites guard theirs with `&&` in a subshell; the
# script did not guard its own. And it sits IMMEDIATELY ABOVE the entry guards,
# so a short-circuit would have had them measure and report the caller's tree
# while the scrub rewrote it — a dry run naming the wrong directory is worse
# than no dry run at all.
echo '=== §7 outside a git work tree it refuses (exit 8) and touches nothing ==='
ng="$WORK/notgit"
mkdir -p "$ng"
printf 'work that must survive
' > "$ng/precious.txt"
before=$(fingerprint "$ng")
ng_out=$( cd "$ng" && bash "$TOOLKIT/build.sh" --yes 2>&1 ); ng_rc=$?
after=$(fingerprint "$ng")
assert_eq       "§7 a non-git cwd exits 8, not 0"                "$ng_rc" "8"
assert_eq       "§7 …and the directory is byte-identical after"  "$after" "$before"
assert_contains "§7 …saying it would have scrubbed the caller's cwd" "$ng_out" "caller's cwd"
assert_contains "§7 control: the file that would have been rewritten survives" \
                "$(cat "$ng/precious.txt")" "work that must survive"
# The --yes is deliberate: the refusal must fire even when the destructive path
# was explicitly authorised, because authorising the build says nothing about
# WHICH TREE the process is standing in.

# EXPECTED-COUNT GUARD.
#   §1 5 · §2 5 · §3 5 · §4 2 · §5 2 · §6 4 · §7 4
EXPECTED=$(( 5 + 5 + 5 + 2 + 2 + 4 + 4 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
