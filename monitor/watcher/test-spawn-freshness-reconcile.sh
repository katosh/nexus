#!/usr/bin/env bash
# Unit tests for the spawn-prompt freshness banner and the prompt/tree
# reconciliation (your-org/nexus-code#1245, #1260, #1196).
#
# Run: bash monitor/watcher/test-spawn-freshness-reconcile.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHAT IS UNDER TEST, AND WHY IT IS KEYED ON THE PROPERTY
# ======================================================
# Two defects that compound into one delivery that lies:
#
#   #1245 — `_clone_freshness_block` guarded itself with
#           `git -C "$dir" rev-parse --git-dir`, which WALKS UP. For a workdir
#           that is not itself a repository the nearest enclosing repository is
#           the nexus, so the guard passed at rc 0 and every line below reported
#           the NEXUS's branch and HEAD as that clone's own.
#
#   #1260 — a prompt's PROSE names a clone and a ref ("fresh at `dev` @ <sha>")
#           and nothing compared that claim against the tree actually delivered.
#
# The assertions below key on the PROPERTY — does the emitted block describe the
# tree that was delivered, and does a contradicted claim produce a warning —
# never on the SHAPE of the fix. In particular nothing here asserts that a
# banner was PRINTED: a banner is printed in every case, including the broken
# one, which is exactly why "it printed" is not evidence. The discriminating
# question is WHOSE branch and WHOSE HEAD it names.
#
# FOUR MUTANTS, because four distinct delivery failures were measured on this
# board on 2026-09-01 (see #1260's thread):
#   (a) workdir is NOT a repository            -> must not inherit the nexus's ref
#   (b) workdir is a repo on the WRONG BRANCH  -> must warn
#   (c) workdir is a repo N COMMITS BEHIND     -> must warn (sha absent)
#   (d) workdir is a leftover directory a clone FAILED into -> must not report
#       it as a healthy clone
#
# EVERY MUTANT IS PAIRED WITH ITS CORRECT CASE. A guard that cannot be made to
# go green is as uninformative as one that cannot be made to go red.
#
# The functions are EXTRACTED FROM monitor/spawn-worker.sh at run time, never
# copied here, so this suite cannot drift from the source it certifies.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
_repo_root=$(cd "$_test_dir/../.." && pwd)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
# An inherited GIT_DIR is one of the three measured holes in the naive
# discriminators (repo-root.sh HOLE 3); make sure the harness does not carry one.
unset GIT_DIR GIT_WORK_TREE 2>/dev/null || true

SPAWNER="$_repo_root/monitor/spawn-worker.sh"
[ -r "$SPAWNER" ] || { echo "missing spawn-worker.sh at $SPAWNER" >&2; exit 1; }

# ── load the code under test, from the real file ───────────────────────────
. "$_repo_root/monitor/repo-root.sh"

_extract() { awk "/^$1\\(\\) \\{/,/^}\$/" "$SPAWNER"; }

EXTRACTED="$WORK/extracted.sh"
{ _extract _sw_has_own_history_fallback; _extract _clone_freshness_block; _extract _prompt_tree_reconcile; } > "$EXTRACTED"

# POSITIVE CONTROL ON THE EXTRACTOR ITSELF. An awk range that matches nothing
# produces an EMPTY file which sources cleanly and defines no functions, and
# every assertion below would then run against a shell builtin-less no-op and
# report whatever the author expected. That is the silent-zero shape this repo
# keeps filing, arriving inside the instrument.
assert_eq "extractor found _clone_freshness_block" \
    "$(grep -c '^_clone_freshness_block() {' "$EXTRACTED")" "1"
assert_eq "extractor found _prompt_tree_reconcile" \
    "$(grep -c '^_prompt_tree_reconcile() {' "$EXTRACTED")" "1"

# shellcheck disable=SC1090
. "$EXTRACTED"
for _f in _clone_freshness_block _prompt_tree_reconcile; do
    if ! declare -F "$_f" >/dev/null 2>&1; then
        echo "FATAL: $_f not defined after extraction" >&2; exit 1
    fi
done

# spawn-worker.sh sets this after successfully sourcing repo-root.sh. We DID
# source the real one above, so 1 is the honest value; the 0 case gets its own
# assertions at the end.
_SW_RR_OK=1

git_q() { git "$@" >/dev/null 2>&1; }

# Build a repository with <n> commits on branch <branch>.
build_repo() {
    local dir="$1" n="$2" branch="${3:-dev}" i
    rm -rf "$dir"; mkdir -p "$dir"
    git_q init "$dir"
    # `git init -b` needs git >= 2.28 and this host's default is 2.17.1;
    # symbolic-ref is the portable form. Without it every fixture lands on
    # `master`, the branch assertions compare two wrong values, and the suite
    # passes while measuring nothing.
    git_q -C "$dir" symbolic-ref HEAD "refs/heads/$branch"
    for (( i = 1; i <= n; i++ )); do
        printf 'c%s\n' "$i" > "$dir/f$i.txt"
        git_q -C "$dir" add -A
        git_q -C "$dir" commit -m "c$i"
    done
    printf '%s' "$dir"
}

mkprompt() { printf '%s\n' "$2" > "$1"; printf '%s' "$1"; }

# ═══════════════════════════════════════════════════════════════════════════
echo "== #1245: the freshness block must describe THIS tree, not the enclosing one =="

# The mutant: a plain directory nested INSIDE a real repository — the exact
# work/<non-repo> shape. The enclosing repo stands in for the nexus.
ENCLOSING=$(build_repo "$WORK/enclosing" 2 nexusbranch)
NONREPO="$ENCLOSING/work/plain-dir"
mkdir -p "$NONREPO"; echo x > "$NONREPO/data.txt"

enclosing_sha=$(git -C "$ENCLOSING" rev-parse --short HEAD)

# FIRST: prove the mutant is REAL — the naive guard must actually pass here and
# the walked-up values must actually be the enclosing repo's. An inert mutant
# and a live one produce byte-identical output downstream.
git -C "$NONREPO" rev-parse --git-dir >/dev/null 2>&1
assert_eq "MUTANT IS LIVE: the naive git-dir guard passes on a non-repo dir" "$?" "0"
assert_eq "MUTANT IS LIVE: git -C walks up and yields the ENCLOSING branch" \
    "$(git -C "$NONREPO" rev-parse --abbrev-ref HEAD 2>/dev/null)" "nexusbranch"

out=$(_clone_freshness_block "$NONREPO")
assert_not_contains "non-repo workdir does NOT inherit the enclosing branch" \
    "$out" "nexusbranch"
assert_not_contains "non-repo workdir does NOT inherit the enclosing HEAD" \
    "$out" "$enclosing_sha"
# The WORDING is intentionally the pre-#1245 string — `test-spawn-worker-reply-to.sh`
# composes it into a byte-for-byte reference. What #1245 changes is WHICH
# directories reach this arm, which is what the two assertions above measure.
assert_contains "non-repo workdir is named as not a git repository" \
    "$out" "NOT A GIT REPOSITORY"

# GREEN SIDE: a real repository still reports its own values.
OWNREPO=$(build_repo "$WORK/ownrepo" 3 dev)
own_sha=$(git -C "$OWNREPO" rev-parse --short HEAD)
out=$(_clone_freshness_block "$OWNREPO")
assert_contains "a real repo reports ITS OWN branch" "$out" "[branch dev]"
assert_contains "a real repo reports ITS OWN HEAD"   "$out" "$own_sha"

# A LINKED WORKTREE'S HISTORY IS ITS OWN. 131 of the directories under work/ on
# this nexus are linked worktrees; the WRITE predicate (rr_is_own_root) would
# refuse all 131, which is why the READ predicate is the correct one here.
WT="$WORK/linked-wt"
if git -C "$OWNREPO" worktree add --detach "$WT" HEAD >/dev/null 2>&1; then
    out=$(_clone_freshness_block "$WT")
    assert_not_contains "a linked worktree is NOT refused as 'not its own repository'" \
        "$out" "NOT A GIT REPOSITORY OF ITS OWN"
    assert_contains "a linked worktree reports its own HEAD" "$out" "$own_sha"
else
    th_skip "linked-worktree arm" "git worktree add failed on this host"
fi

# UNDETERMINED MUST NOT COLLAPSE INTO A CONFIDENT NEGATIVE. "could not look" and
# "positively is not a repository" are different answers; #1245 says so
# explicitly, because the block's purpose is that a negative claim be trusted.
UNREADABLE="$WORK/unreadable"
mkdir -p "$UNREADABLE"; chmod 000 "$UNREADABLE" 2>/dev/null || true
if [ "$(id -u)" -ne 0 ] && ! ( cd "$UNREADABLE" ) >/dev/null 2>&1; then
    out=$(_clone_freshness_block "$UNREADABLE")
    assert_contains "an unreadable dir reports COULD NOT DETERMINE" "$out" "COULD NOT DETERMINE"
    assert_not_contains "an unreadable dir is NOT called 'not a git repository'" \
        "$out" "NOT A GIT REPOSITORY"
else
    th_skip "undetermined arm" "cannot construct an unreadable directory as this user"
fi
chmod 755 "$UNREADABLE" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════
echo "== #1260: a prompt's prose ref claim is reconciled against the tree =="

BEHIND=$(build_repo "$WORK/behind" 5 dev)
tip_sha=$(git -C "$BEHIND" rev-parse HEAD)
git_q -C "$BEHIND" checkout -q "HEAD~3"
git_q -C "$BEHIND" checkout -q -B dev
behind_sha=$(git -C "$BEHIND" rev-parse --short HEAD)
base=$(basename "$BEHIND")

# --- mutant (c): the prompt names a sha this clone has never seen ---
# The tip sha is genuinely unreachable from HEAD after the reset, so this is the
# real "42 commits behind" shape and not a fabricated string.
UNSEEN="deadbeefcafe1234567890abcdef1234567890ab"
P=$(mkprompt "$WORK/p_behind.txt" "Your clone is \`work/$base\`, fresh at \`dev\` @ \`$UNSEEN\`.")
# NON-ZERO, not `= 1`. `git cat-file -e` exits 128 for an object name that
# resolves to nothing (measured on git 2.17.1 here), and 1 only for some
# well-formed-but-missing forms. The production check is `! git cat-file -e`,
# which is correct for both; an assertion pinned to 1 tests the errno, not the
# property, and reddens on a git that reports absence differently.
git -C "$BEHIND" cat-file -e "${UNSEEN}^{commit}" 2>/dev/null; _cf=$?
assert_eq "MUTANT IS LIVE: the claimed sha really is absent from the clone" \
    "$( [ "$_cf" -ne 0 ] && echo absent || echo present )" "absent"
out=$(_prompt_tree_reconcile "$BEHIND" "$P")
assert_contains "an absent claimed sha is reported as a MISMATCH" "$out" "PROMPT/TREE MISMATCH"
assert_contains "the absent sha is named"                          "$out" "$UNSEEN"
assert_contains "the mismatch states NOT PRESENT"                  "$out" "NOT PRESENT"
assert_contains "the mismatch states the MEASURED head"            "$out" "$behind_sha"

# A sha that IS present but is not an ancestor of HEAD is a different sentence.
P=$(mkprompt "$WORK/p_notanc.txt" "Your clone is \`work/$base\`, fresh at \`dev\` @ \`$tip_sha\`.")
out=$(_prompt_tree_reconcile "$BEHIND" "$P")
assert_contains "a present-but-unreachable sha is reported"    "$out" "NOT AN ANCESTOR"

# --- mutant (b): the prompt names the wrong BRANCH ---
WRONGBR=$(build_repo "$WORK/wrongbr" 2 main)
wb=$(basename "$WRONGBR")
P=$(mkprompt "$WORK/p_branch.txt" "Your clone is \`work/$wb\`, already checked out on \`dev\`.")
assert_eq "MUTANT IS LIVE: the clone really is on main" \
    "$(git -C "$WRONGBR" rev-parse --abbrev-ref HEAD)" "main"
out=$(_prompt_tree_reconcile "$WRONGBR" "$P")
assert_contains "a wrong branch claim is reported as a MISMATCH" "$out" "PROMPT/TREE MISMATCH"
assert_contains "the mismatch names the CLAIMED branch"         "$out" "dev"
assert_contains "the mismatch names the ACTUAL branch"          "$out" "main"

# --- GREEN: a prompt whose claim matches the tree produces NOTHING ---
GOOD=$(build_repo "$WORK/good" 3 dev)
gb=$(basename "$GOOD")
good_sha=$(git -C "$GOOD" rev-parse --short HEAD)
P=$(mkprompt "$WORK/p_good.txt" "Your clone is \`work/$gb\`, already checked out on \`dev\` @ \`$good_sha\`.")
out=$(_prompt_tree_reconcile "$GOOD" "$P")
assert_empty "a correct prompt produces NO warning" "$out"

# An ANCESTOR sha is a correct claim too: naming an older commit that HEAD
# descends from is not a contradiction.
anc_sha=$(git -C "$GOOD" rev-parse --short "HEAD~1")
P=$(mkprompt "$WORK/p_anc.txt" "Your clone is \`work/$gb\`, fresh at \`dev\` @ \`$anc_sha\`.")
out=$(_prompt_tree_reconcile "$GOOD" "$P")
assert_empty "an ancestor sha is not a mismatch" "$out"

# --- mutant (d): the leftover directory a `git clone` FAILED into ---
# `git clone` into an existing non-empty directory fails, and the spawn proceeds
# into whatever the earlier agent left. Two shapes were measured; both must be
# refused as a healthy clone rather than reported as one.
LEFTOVER=$(build_repo "$WORK/leftover" 2 someones-old-branch)
lo=$(basename "$LEFTOVER")
P=$(mkprompt "$WORK/p_leftover.txt" "Your clone is \`work/$lo\`, already checked out on \`dev\`.")
out=$(_prompt_tree_reconcile "$LEFTOVER" "$P")
assert_contains "a leftover tree on another branch is reported" "$out" "PROMPT/TREE MISMATCH"
assert_contains "the leftover's real branch is named" "$out" "someones-old-branch"

# The INTERRUPTED-CLONE signature: a `.git` exists but the directory is not a
# repository root. `[ -d "$dir/.git" ]` passes here, which is why that is not
# the predicate.
STUB="$ENCLOSING/work/interrupted"
mkdir -p "$STUB/.git"
kind=$("$_repo_root/monitor/repo-root.sh" --kind "$STUB" 2>/dev/null)
assert_eq "an interrupted clone is classified gitdir-stub, not a root" "$kind" "gitdir-stub"
out=$(_clone_freshness_block "$STUB")
assert_not_contains "an interrupted clone does NOT inherit the enclosing branch" \
    "$out" "nexusbranch"

# ═══════════════════════════════════════════════════════════════════════════
echo "== the warning channel does not fire on unrelated shas =="

# A brief quotes shas about OTHER repositories constantly. If every one of them
# produced a warning the channel would be noise, and a noisy warning is one
# nobody reads. Anchoring is what buys this, and it is worth an assertion.
P=$(mkprompt "$WORK/p_noise.txt" "See your-org/nexus-code@\`0123456789abcdef0123\` for background on the API change.")
out=$(_prompt_tree_reconcile "$GOOD" "$P")
assert_empty "a sha quoted about another repo does not warn" "$out"

# ...but the SAME sha, on a line that names this workdir, does warn. This is the
# pair that shows the anchor is doing the discriminating rather than the
# function simply being inert.
P=$(mkprompt "$WORK/p_anchored.txt" "Your clone is \`work/$gb\`, fresh at \`dev\` @ \`0123456789abcdef0123\`.")
out=$(_prompt_tree_reconcile "$GOOD" "$P")
assert_contains "the same sha DOES warn when the line names this workdir" \
    "$out" "PROMPT/TREE MISMATCH"

# ═══════════════════════════════════════════════════════════════════════════
echo "== the CORPUS phrasings, not just the ones the code already supported =="

# your-org/nexus-code#1260 skeptic. The eight fixtures above were written from
# the phrasings the implementation handled, so they could not discover the ones
# it did not. Measured over the 1,874 real prompts in
# monitor/.state/spawn-prompts/ on this nexus:
#
#     "Your clone is"           22 prompts   (was a fixture)
#     "fresh at"                12 prompts   (was a fixture)
#     "already checked out on"   3 prompts   (was a fixture)
#     ", on `X`"                60 prompts   <- caught NOTHING
#     "on branch"              110 prompts
#     "Clone: `work/X`"         90 prompts
#     `` at `sha` ``           293 occurrences  <- the sha arm matched only `@`
#     `` @ `sha` ``            174 occurrences
#
# The three fixtures drew from the RAREST forms and missed the common ones. A
# suite written from the implementation measures the implementation.

BR=$(build_repo "$WORK/corpus" 4 dev)
cb=$(basename "$BR")
git_q -C "$BR" checkout -q -B main
git_q -C "$BR" checkout -q -B dev
corpus_unseen="fedcba9876543210fedcba9876543210fedcba98"

# The house shape: bare `, on `X`` with `at `sha`` — the form that was silent
# on BOTH arms for 21 real prompts.
P=$(mkprompt "$WORK/p_house.txt" "Clone: \`work/$cb\`, on \`main\` at \`$corpus_unseen\`.")
out=$(_prompt_tree_reconcile "$BR" "$P")
assert_contains "the house form '\`, on X\` at \`sha\`' is reconciled at all" \
    "$out" "PROMPT/TREE MISMATCH"
assert_contains "…the bare ', on X' branch claim is caught" "$out" "main"
assert_contains "…and the 'at \`sha\`' spelling is caught" "$out" "$corpus_unseen"

# `at `sha`` alone — 293 occurrences against 174 for `@`.
P=$(mkprompt "$WORK/p_atsha.txt" "Clone: \`work/$cb\` at \`$corpus_unseen\`.")
out=$(_prompt_tree_reconcile "$BR" "$P")
assert_contains "'at \`sha\`' is caught without an '@'" "$out" "NOT PRESENT"

# NEGATIVE, and this is why the fix is a GATE and not a wider glob: the corpus
# uses the same `, on \`X\`` shape for things that are NOT branches.
P=$(mkprompt "$WORK/p_repo.txt" "Filed for \`work/$cb\`, on \`your-org/nexus-code\` as agreed.")
out=$(_prompt_tree_reconcile "$BR" "$P")
assert_empty "a REPO name in the ', on X' slot does not manufacture a warning" "$out"

P=$(mkprompt "$WORK/p_file.txt" "Work in \`work/$cb\`, on \`test-erofs-escalation.sh\` first.")
out=$(_prompt_tree_reconcile "$BR" "$P")
assert_empty "a FILENAME in the ', on X' slot does not manufacture a warning" "$out"

# A branch that DOES exist and IS wrong must still warn — or the gate above has
# simply turned the arm off.
P=$(mkprompt "$WORK/p_realbr.txt" "Clone: \`work/$cb\`, on \`main\`.")
out=$(_prompt_tree_reconcile "$BR" "$P")
assert_contains "a REAL branch that is wrong still warns (the gate did not disable the arm)" \
    "$out" "PROMPT/TREE MISMATCH"

# A basename carrying a regex metacharacter must not lose its anchor.
MB=$(build_repo "$WORK/meta+repo" 2 dev)
mb=$(basename "$MB")
P=$(mkprompt "$WORK/p_meta.txt" "Clone: \`work/$mb\` at \`$corpus_unseen\`.")
out=$(_prompt_tree_reconcile "$MB" "$P")
assert_contains "a basename with a regex metacharacter keeps its anchor" \
    "$out" "PROMPT/TREE MISMATCH"

# ═══════════════════════════════════════════════════════════════════════════
echo "== the EXPLICIT arm must not extract ENGLISH from prose =="

# your-org/nexus-code#1260 skeptic round 2, R1. The weak `, on X` arm is gated
# "because an ungated pattern would manufacture confident warnings about claims
# the prompt never made" — and that reasoning applied verbatim to the EXPLICIT
# arm, which was ungated. Measured over all 1,875 real prompts, it produced a
# claim in 123 of them, commonest tokens `the` (15), `disk` (9), `branch` (6),
# `a` (5), `is` (4).
#
# These fixtures are REAL PROSE SHAPES from that corpus, not invented ones.

PR=$(build_repo "$WORK/prose" 3 dev)
pb=$(basename "$PR")

P=$(mkprompt "$WORK/p_prose1.txt" "Clone \`work/$pb\`. Note the tick already on branch the disk was full.")
out=$(_prompt_tree_reconcile "$PR" "$P")
assert_not_contains "an English word after 'on branch' is NOT reported as a branch" "$out" "names branch"

P=$(mkprompt "$WORK/p_prose2.txt" "In \`work/$pb\`, the guard is now on a different path than it is on branch dev.")
out=$(_prompt_tree_reconcile "$PR" "$P")
assert_not_contains "…nor is a prose word after 'now on'" "$out" "\`a\`"

# THE POSITIVE HALF — a BACKTICKED explicit claim is the author marking an
# identifier, and it must still warn. Without this the fix could simply be
# "turn the arm off", which every negative above would also satisfy.
P=$(mkprompt "$WORK/p_backtick.txt" "Clone \`work/$pb\`, already checked out on \`main\`.")
out=$(_prompt_tree_reconcile "$PR" "$P")
assert_contains "a BACKTICKED explicit branch claim still warns" "$out" "PROMPT/TREE MISMATCH"
assert_contains "…and names it" "$out" "main"

# An UNBACKTICKED token that genuinely resolves as a ref is recovered by the
# gate — this is the one real branch a plain backtick requirement would lose
# (measured: `operator/post-recovery-fixes`, unbackticked in one real prompt).
git_q -C "$PR" branch operator/post-recovery-fixes
P=$(mkprompt "$WORK/p_loose.txt" "Clone \`work/$pb\`, already on operator/post-recovery-fixes now.")
out=$(_prompt_tree_reconcile "$PR" "$P")
assert_contains "an UNBACKTICKED token that RESOLVES as a ref is still caught" \
    "$out" "operator/post-recovery-fixes"

# ═══════════════════════════════════════════════════════════════════════════
echo "== reconciliation is READ-ONLY and refuses nothing =="

before_head=$(git -C "$GOOD" rev-parse HEAD)
before_refs=$(git -C "$GOOD" for-each-ref --format='%(refname) %(objectname)' | sort | md5sum)
P=$(mkprompt "$WORK/p_ro.txt" "Your clone is \`work/$gb\`, fresh at \`dev\` @ \`$UNSEEN\`.")
_prompt_tree_reconcile "$GOOD" "$P" >/dev/null 2>&1
rc=$?
assert_eq "reconciliation WARNS, never refuses (rc 0 even on a mismatch)" "$rc" "0"
assert_eq "reconciliation does not move HEAD" "$(git -C "$GOOD" rev-parse HEAD)" "$before_head"
assert_eq "reconciliation writes no ref" \
    "$(git -C "$GOOD" for-each-ref --format='%(refname) %(objectname)' | sort | md5sum)" "$before_refs"

# A missing or unreadable prompt file must not break the spawn.
out=$(_prompt_tree_reconcile "$GOOD" "$WORK/does-not-exist.txt"); rc=$?
assert_eq "an unreadable prompt file is survivable (rc 0)" "$rc" "0"
assert_empty "an unreadable prompt file produces no output" "$out"

# A branch name containing `%` must not be eaten by printf. The data is never
# the format string; `printf -- "$out"` printed "branch -feature" for
# "branch %s-feature" on this host.
PCT=$(build_repo "$WORK/pct" 2 "feat-100%done")
pb=$(basename "$PCT")
P=$(mkprompt "$WORK/p_pct.txt" "Your clone is \`work/$pb\`, already checked out on \`dev\`.")
out=$(_prompt_tree_reconcile "$PCT" "$P")
assert_contains "a % in a branch name survives into the warning" "$out" "feat-100%done"

# ═══════════════════════════════════════════════════════════════════════════
echo "== the predicate's OWN absence is UNDETERMINED, never a guess =="

# spawn-worker.sh degrades rather than refusing the spawn when repo-root.sh is
# unreachable (a fake NEXUS_ROOT built from an explicit helper list is the
# ordinary case in this repo's own test fixtures). The requirement is NOT that
# it keeps working — it is that it never falls back to the walk-up, because a
# confident wrong ref is the whole defect. So the degraded arm must look like
# "could not determine", and must NOT name the enclosing repository.
# A SUBSHELL WOULD PRINT A SECOND SUMMARY. th_summary_and_exit is the suite's
# one closing statement; running it inside `( … )` emits a full tally that is
# not the suite's, which is precisely the shape the summary-honesty guard
# exists to catch. Save and restore the flag instead.
_SW_RR_OK=0
out=$(_clone_freshness_block "$NONREPO")
# The degraded arm FALLS BACK to a narrower self-rooted check rather than
# reporting UNDETERMINED — reporting UNDETERMINED whenever repo-root.sh was
# absent silenced the block for every fake-nexus fixture that vendors this
# script (measured: test-spawn-worker.sh 145/0 -> 136/9). What must survive the
# degradation is the ONE property #1245 is about, and it is asserted here.
assert_contains "predicate unavailable => still answers, and answers about THIS dir" \
    "$out" "NOT A GIT REPOSITORY"
assert_not_contains "predicate unavailable => does NOT fall back to the walk-up" \
    "$out" "nexusbranch"
assert_not_contains "predicate unavailable => does NOT print the enclosing HEAD" \
    "$out" "$enclosing_sha"
out=$(_prompt_tree_reconcile "$BEHIND" "$WORK/p_behind.txt"); rc=$?
assert_eq "predicate unavailable => reconciliation is a no-op, not an error" "$rc" "0"
assert_empty "predicate unavailable => reconciliation claims nothing" "$out"
_SW_RR_OK=1

th_summary_and_exit
