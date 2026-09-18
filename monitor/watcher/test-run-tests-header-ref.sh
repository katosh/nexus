#!/usr/bin/env bash
# THE RUN-LOG HEADER NAMES THE TREE IT IS A CLAIM ABOUT.
# (your-org/nexus-code#1465)
#
# WHY THIS FILE EXISTS. `run-tests.sh`'s header recorded nproc, the test count
# and the interpreter, and NOT the ref — so a suite log carried to another
# checkout silently described a different tree, with nothing in the log to
# say so. A suite result is a property of a tree (CLAUDE.md, count-provenance),
# and the runner now prints one line:
#
#     === tree: ref=<40-hex> branch=<b> dirty=<yes|no> worktree=<linked|main> ===
#
# THE ASSERTION THAT MATTERS IS THE NEGATIVE ONE. `git -C <dir>` on a directory
# that is not its own repository WALKS UP and answers about the enclosing one at
# rc 0 (#1196) — and a runner copied into an un-versioned fixture under some
# checkout is exactly that shape. So beyond "the sha is the fixture's HEAD",
# this suite plants the runner BELOW a repository root and in a plain directory
# and requires `ref=UNKNOWN (…)` with the enclosing sha ABSENT. A header that
# printed a plausible, borrowed sha would pass every positive check here and be
# the defect the line exists to prevent.
#
# THE RUNNER IS COPIED INTO EACH FIXTURE, as test-helper-honesty.sh does: it
# derives its repo root from its own location (`_RT_REPO_ROOT`), never from
# `$PWD`, so a copy inside the fixture reports the FIXTURE's tree. The runner's
# state dir is pinned under the fixture (NEXUS_TEST_STATE_DIR) so nothing lands
# in $HOME.
#
# Run: bash monitor/watcher/test-run-tests-header-ref.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
RUNNER="$_test_dir/run-tests.sh"
RR="$REPO_ROOT/monitor/repo-root.sh"

. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$RUNNER"; }
gp_handle "$@"

[[ -r "$RUNNER" ]] || { echo "missing runner: $RUNNER" >&2; exit 2; }
[[ -r "$RR" ]]     || { echo "missing predicate: $RR" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git is required for this suite" >&2; exit 2; }

WORK=$(mktemp -d) || { echo "FAIL: mktemp for the fixture"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/cwd" "$WORK/state"
export NEXUS_TEST_STATE_DIR="$WORK/state"
export NEXUS_TMUX_SOCKET_CHECK=off

# Fixture identity is passed PER COMMAND (`-c`), never written to any config
# file: the operator's global git config is writable and nothing validates a
# commit's author (your-org/nexus-code#1244).
fgit() { env -u GIT_DIR -u GIT_WORK_TREE git -c user.name=fixture -c user.email=fixture@example.invalid "$@"; }

# mk_tree <dir> — a minimal monitor/ layout: the real runner, the real
# repo-root predicate beside it (the runner looks for `../repo-root.sh`), and
# one trivially passing suite for it to dispatch.
mk_tree() {
    mkdir -p "$1/monitor/watcher" || return 1
    cp "$RUNNER" "$1/monitor/watcher/run-tests.sh" || return 1
    cp "$RR" "$1/monitor/repo-root.sh" || return 1
    cat >"$1/monitor/watcher/test-trivial.sh" <<'T'
#!/usr/bin/env bash
echo "=== summary: 1 passed, 0 failed ==="
echo "ALL TESTS PASSED"
exit 0
T
    chmod +x "$1/monitor/watcher/test-trivial.sh"
}

# tree_line <dir> — run the copied runner over its trivial suite from a
# DEDICATED cwd (never the repo, never the fixture: the line must come from
# the runner's own root, not from where it was invoked) and return the header
# line in TREE_LINE, with RUN_RC and RUN_OUT beside it. Globals, not a `$(…)`
# return: a command substitution runs in a subshell, and the rc read there
# would never reach the caller.
tree_line() {
    RUN_OUT=$( cd "$WORK/cwd" && bash "$1/monitor/watcher/run-tests.sh" --jobs 1 \
                 "$1/monitor/watcher/test-trivial.sh" 2>&1 )
    RUN_RC=$?
    TREE_LINE=$(grep -aE '^=== tree: ' <<<"$RUN_OUT")
}
# _lines_matching <literal> <text> — matching LINES of a literal, 0 on none.
_lines_matching() { grep -acF -- "$1" <<<"$2"; }

# ── A. a clean fixture repository at its own root ───────────────────────
REPO="$WORK/repo"
mkdir -p "$REPO" && fgit init -q "$REPO" && mk_tree "$REPO" \
    && fgit -C "$REPO" add -A && fgit -C "$REPO" commit -q -m 'fixture' \
    || { echo "FAIL: could not build the fixture repository" >&2; exit 1; }
th_require_fixture_repo "$REPO"

HEAD_SHA=$(fgit -C "$REPO" rev-parse HEAD)
[[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] && _th_pass || _th_fail
printf '  %s: CONTROL: the fixture HEAD is a full 40-hex sha (%s)\n' \
    "$( [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] && echo PASS || echo FAIL )" "$HEAD_SHA"
HEAD_BRANCH=$(fgit -C "$REPO" rev-parse --abbrev-ref HEAD)

tree_line "$REPO"; line=$TREE_LINE; rc=$RUN_RC
assert_eq "clean root: the runner itself ran green (rc)" "$rc" "0"
assert_eq "clean root: exactly ONE tree line in the header" \
    "$(_lines_matching '=== tree: ' "$RUN_OUT")" "1"
assert_contains "clean root: the line carries the fixture's FULL HEAD sha" \
    "$line" "ref=$HEAD_SHA"
assert_contains "clean root: branch is the checked-out branch name" \
    "$line" "branch=$HEAD_BRANCH"
assert_contains "clean root: dirty=no on a clean tree"     "$line" "dirty=no"
assert_contains "clean root: worktree=main in the main checkout" "$line" "worktree=main"

# ── B. an UNTRACKED file makes it dirty ─────────────────────────────────
# `--untracked-files=normal` is the whole point: a brand-new suite that has not
# been `git add`ed is in the population the runner just ran and in no commit.
: >"$REPO/monitor/watcher/test-untracked-new-suite.sh"
tree_line "$REPO"; line=$TREE_LINE
assert_contains "untracked file: dirty=yes"                    "$line" "dirty=yes"
assert_contains "untracked file: …and the ref is unchanged"    "$line" "ref=$HEAD_SHA"
rm -f "$REPO/monitor/watcher/test-untracked-new-suite.sh"

# ── C. detached HEAD ─────────────────────────────────────────────────────
fgit -C "$REPO" checkout -q --detach || { echo "FAIL: cannot detach" >&2; exit 1; }
tree_line "$REPO"; line=$TREE_LINE
assert_contains "detached HEAD: branch=detached"               "$line" "branch=detached"
assert_contains "detached HEAD: the ref is still the sha"      "$line" "ref=$HEAD_SHA"

# ── D. a LINKED worktree ─────────────────────────────────────────────────
# NO `-q`: absent at git 2.17.1, the default on this host (CLAUDE.md).
WT="$WORK/wt"
fgit -C "$REPO" worktree add "$WT" -b fixture-wt >/dev/null 2>&1 \
    || { echo "FAIL: git worktree add" >&2; exit 1; }
# The runner and the predicate are TRACKED, so the worktree already holds them.
tree_line "$WT"; line=$TREE_LINE
assert_contains "linked worktree: worktree=linked"             "$line" "worktree=linked"
assert_contains "linked worktree: branch is the worktree's branch" "$line" "branch=fixture-wt"
assert_contains "linked worktree: the ref is the shared HEAD"  "$line" "ref=$HEAD_SHA"

# ── E. BELOW a repository root — the walk-up trap ───────────────────────
# The runner's own root is `$REPO/nested`, which is inside the fixture repo
# but is not a repository. `git -C` here would answer with $HEAD_SHA at rc 0;
# the header must refuse it.
mk_tree "$REPO/nested" || { echo "FAIL: nested fixture" >&2; exit 1; }
tree_line "$REPO/nested"; line=$TREE_LINE
assert_contains "below a root: ref=UNKNOWN, naming the walk-up" \
    "$line" "ref=UNKNOWN (dir is not its own repository root"
assert_not_contains "below a root: the ENCLOSING repository's sha is NOT borrowed" \
    "$line" "$HEAD_SHA"

# ── F. not a repository at all ───────────────────────────────────────────
PLAIN="$WORK/plain"
mk_tree "$PLAIN" || { echo "FAIL: plain fixture" >&2; exit 1; }
env -u GIT_DIR -u GIT_WORK_TREE git -C "$PLAIN" rev-parse --show-toplevel >/dev/null 2>&1; rc=$?
[[ "$rc" -ne 0 ]] && _th_pass || _th_fail
printf '  %s: CONTROL: the plain fixture has NO enclosing repository (git rc=%s)\n' \
    "$( [[ "$rc" -ne 0 ]] && echo PASS || echo FAIL )" "$rc"
tree_line "$PLAIN"; line=$TREE_LINE
assert_eq "not a repo: the line is exactly the UNKNOWN wording" \
    "$line" "=== tree: ref=UNKNOWN (not a git checkout) ==="

# ── G. git not on PATH ───────────────────────────────────────────────────
# A PATH-front `git` that behaves as an absent binary (rc 127, nothing on
# stdout). The runner and repo-root.sh both resolve `git` through PATH, so this
# is the "git unavailable" arm without touching the host.
mkdir -p "$WORK/nogit"
printf '#!/usr/bin/env bash\nexit 127\n' >"$WORK/nogit/git"
chmod +x "$WORK/nogit/git"
RUN_OUT=$( cd "$WORK/cwd" && PATH="$WORK/nogit:$PATH" \
             bash "$REPO/monitor/watcher/run-tests.sh" --jobs 1 \
                  "$REPO/monitor/watcher/test-trivial.sh" 2>&1 )
line=$(grep -aE '^=== tree: ' <<<"$RUN_OUT")
assert_contains "no usable git: ref=UNKNOWN, never a blank line" \
    "$line" "ref=UNKNOWN ("
assert_not_contains "no usable git: no sha is printed" "$line" "$HEAD_SHA"

EXPECTED_ASSERTIONS=20
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
