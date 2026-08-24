#!/usr/bin/env bash
# `upload-asset.sh` must take exactly ONE positional —
# your-org/nexus-code#858 A.
#
# THE DEFECT. The usage advertises one positional (the local path). A
# second bare positional was nonetheless accepted and bound to
# `--repo-path`. A bare ISSUE NUMBER is the plausible second argument
# here, because `ng wrap-up`, `ng reply`, `ng comment`, `ng react` and
# `ng close` all take one in that slot — so
#
#     ng upload reports/<report>.md 846
#
# wrote `assets/846` (a FILE, where that issue's asset DIRECTORY lives),
# printed a URL that resolves, and exited 0. What it did NOT do was
# update the path an earlier `ng wrap-up` link comment already pointed
# at, so a reader following the issue link read a superseded report
# while the operator's pane said the upload succeeded. This is the one
# failure in this file that SUCCEEDS while doing the wrong thing.
#
# WHY THE ASSERTIONS ARE END-TO-END. "It exits 1 with a message" is a
# proxy: the property is that the WRONG UPLOAD DOES NOT HAPPEN. So the
# suite stands up a real local bare repo as the asset remote and asserts
# against the remote's own commit graph — the refusal must leave it
# byte-for-byte unmoved — with the `--issue 846` form exercised in the
# same harness as a positive control, so a patch that broke uploading
# altogether could not pass.
#
# Run: bash monitor/watcher/test-upload-asset-positional.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_real_script="$_test_dir/../upload-asset.sh"

# The shared, subshell-durable ledger rather than local counters — see
# _test_helpers.sh: `assert_*` mutates globals, and a FAIL raised inside
# `( … )` or `$( … )` dies with the child, leaving the suite green.
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

WORK=$(mktemp -d -t nexus-858-positional-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REAL_GIT=$(command -v git)
[[ -x "$REAL_GIT" ]] || { echo "git not on PATH; cannot run test" >&2; exit 2; }

# ---- a fake nexus root + a local bare repo standing in for the remote --
# Same shape as test-upload-asset-gitignore.sh: everything downstream of
# `remote set-url` runs against the local bare for real, so the commit
# graph below is the actual git plumbing's output, not a stub's.

FAKE_NEXUS="$WORK/nexus"
BARE="$WORK/asset-repo.git"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config"

"$REAL_GIT" init --quiet --bare "$BARE"
"$REAL_GIT" --git-dir="$BARE" symbolic-ref HEAD refs/heads/main
seed="$WORK/seed"
"$REAL_GIT" clone --quiet "$BARE" "$seed" 2>/dev/null
"$REAL_GIT" -C "$seed" -c user.name=test -c user.email=test@example.com \
    commit --quiet --allow-empty -m 'seed'
"$REAL_GIT" -C "$seed" branch -M main 2>/dev/null || true
"$REAL_GIT" -C "$seed" push --quiet origin HEAD:main
rm -rf "$seed"

cp "$_real_script" "$FAKE_NEXUS/monitor/upload-asset.sh"
chmod +x "$FAKE_NEXUS/monitor/upload-asset.sh"
SCRIPT="$FAKE_NEXUS/monitor/upload-asset.sh"

cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "fake-token-for-tests"
STUB
chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.asset_repo)    printf 'fake-owner/fake-repo' ;;
    github.repo)          printf 'fake-owner/fake-repo' ;;
    github.bot_git_name)  printf 'test-bot[bot]' ;;
    github.bot_git_email) printf 'test-bot[bot]@users.noreply.github.com' ;;
    *)                    printf '%s' "${2-}" ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"

"$REAL_GIT" clone --quiet "$BARE" "$FAKE_NEXUS/assets"

# `git` stub: swallow the `remote set-url` to a github.com URL (which
# would otherwise repoint the clone away from the local bare); pass
# everything else through to the real git.
STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
    if [[ "\$a" == "set-url" ]]; then exit 0; fi
done
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$STUB_DIR/git"

SRC="$WORK/report.md"
printf '# A report\n\nbody\n' > "$SRC"

remote_tip() { "$REAL_GIT" --git-dir="$BARE" rev-parse refs/heads/main; }
remote_paths() { "$REAL_GIT" --git-dir="$BARE" ls-tree -r --name-only refs/heads/main; }

run_upload() {
    OUT=$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" "$@" 2>&1)
    RC=$?
}

# ===========================================================================
# PART A — the refusal, and that it really refuses.
# ===========================================================================
echo '=== a bare second positional is refused, and nothing is uploaded ==='

TIP_BEFORE=$(remote_tip)
run_upload "$SRC" 846
assert_eq "exit 1 — bad usage, not exit 0" "$RC" "1"
assert_contains "the diagnostic names the offending argument" "$OUT" 'unexpected second positional argument: 846'
assert_contains "…and names the flag the caller wanted"       "$OUT" '--issue 846'
assert_contains "…and cites the issue"                        "$OUT" '#858'
# THE PROPERTY, not the message: the asset remote must be untouched.
assert_eq "the asset remote did not move" "$(remote_tip)" "$TIP_BEFORE"
assert_not_contains "no assets/846 path was created" "$(remote_paths)" 'assets/846'
assert_not_contains "no URL was printed"             "$OUT" 'https://github.com/'

echo '=== a non-numeric second positional is refused too, naming --repo-path ==='
TIP_BEFORE=$(remote_tip)
run_upload "$SRC" some/where.md
assert_eq "exit 1" "$RC" "1"
assert_contains "the diagnostic names --repo-path" "$OUT" '--repo-path some/where.md'
assert_eq "the asset remote did not move" "$(remote_tip)" "$TIP_BEFORE"

# ===========================================================================
# PART B — POSITIVE CONTROLS. Part A asserts that something does NOT
# happen, and a script that refused everything would pass it outright.
# ===========================================================================
echo '=== --issue 846 still uploads, to the issue directory ==='

TIP_BEFORE=$(remote_tip)
run_upload "$SRC" --issue 846
assert_eq "exit 0" "$RC" "0"
assert_contains "a URL was printed" "$OUT" 'https://github.com/fake-owner/fake-repo/'
if [[ "$(remote_tip)" != "$TIP_BEFORE" ]]; then
    pass "the asset remote advanced (the upload really happened)"
else
    fail "the asset remote did NOT advance — Part A's 'did not move' proves nothing"
fi
assert_contains "the file landed under the issue DIRECTORY" \
    "$(remote_paths)" 'assets/846/report.md'
assert_not_contains "…and not as a file AT assets/846" \
    "$(remote_paths | grep -x 'assets/846' || true)" 'assets/846'

echo '=== --repo-path still overrides placement ==='
TIP_BEFORE=$(remote_tip)
printf '# Another\n\nbody2\n' > "$WORK/other.md"
run_upload "$WORK/other.md" --repo-path 'custom/place.md'
assert_eq "exit 0" "$RC" "0"
assert_contains "the file landed at the explicit repo-path" \
    "$(remote_paths)" 'custom/place.md'

echo '=== a lone positional still uploads (the documented form) ==='
printf '# Third\n\nbody3\n' > "$WORK/third.md"
run_upload "$WORK/third.md"
assert_eq "exit 0" "$RC" "0"
assert_contains "the file landed under assets/general/" \
    "$(remote_paths)" 'assets/general/third.md'

# ---------------------------------------------------------------------------
# EXPECTED-COUNT GUARD (required by test-summary-honesty-manifest.sh at the
# `ledger=yes` protection level). Pinned, not derived: nothing here is
# discovered at runtime, so a literal is exact and a changed number is a
# deliberate edit.
#    7  the numeric second positional is refused and nothing is uploaded
# +  3  the non-numeric second positional
# +  5  positive control: --issue 846 uploads to the issue DIRECTORY
# +  2  positive control: --repo-path still overrides placement
# +  2  positive control: the lone positional still uploads
EXPECTED=$(( 7 + 3 + 5 + 2 + 2 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
