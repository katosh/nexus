#!/usr/bin/env bash
# Regression test for `monitor/upload-asset.sh` B8 fixes
# (your-org/your-nexus#236):
#   1. default-branch — a freshly-created (empty) asset remote must not
#      strand the first commit on the host's `init.defaultBranch`
#      (often `master`); the script pins HEAD to `main` so the first
#      `push origin main` succeeds (the new-operator bootstrap trap).
#   2. basename clobber — two distinct sources sharing a basename route
#      to the same REPO_PATH; the second upload must WARN about the
#      silent overwrite and point at `--repo-path`.
#   3. URL-on-no-op — a no-op upload (identical content already at the
#      path) must still emit the SHA-pinned URL on stdout (already the
#      behaviour; this locks it as a regression guard for scrapers).
#
# Run: bash monitor/watcher/test-upload-asset-bootstrap.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy mirrors test-upload-asset-gitignore.sh: stand up a local bare
# repo as the "asset remote", a fake nexus root, PATH-stubbed `git`
# (no-ops `remote set-url`, rewrites a github.com `clone` target to the
# local bare), a stub `mint-token.sh`, and a stub `config/load.sh`.
# fetch / add / commit / push run against the local bare for real.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_real_script="$_test_dir/../upload-asset.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if ! grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — unexpected substring %q in output\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d -t nexus-test-upload-bootstrap-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REAL_GIT=$(command -v git)
[[ -x "$REAL_GIT" ]] || { echo "git not on PATH; cannot run test" >&2; exit 2; }

FAKE_NEXUS="$WORK/nexus"
BARE="$WORK/asset-repo.git"

# Stub the auxiliary scripts the real upload-asset.sh shells out to.
write_fake_nexus_stubs() {
    mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config"
    cp "$_real_script" "$FAKE_NEXUS/monitor/upload-asset.sh"
    chmod +x "$FAKE_NEXUS/monitor/upload-asset.sh"

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
}

# PATH stub for `git`:
#   - no-ops any invocation that mentions `set-url` (origin stays local),
#   - rewrites a `clone <github-url> <dst>` so the URL becomes the local
#     bare (lets us exercise upload-asset.sh's own fresh-clone branch),
#   - otherwise passes through to the real git binary.
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/git" <<STUB
#!/usr/bin/env bash
args=("\$@")
is_clone=0
for a in "\${args[@]}"; do
    [[ "\$a" == "set-url" ]] && exit 0
    [[ "\$a" == "clone" ]] && is_clone=1
done
if (( is_clone )); then
    for i in "\${!args[@]}"; do
        case "\${args[\$i]}" in
            https://*github.com/*) args[\$i]="$BARE" ;;
        esac
    done
fi
exec "$REAL_GIT" "\${args[@]}"
STUB
chmod +x "$STUB_DIR/git"

run_upload() {
    local _local="$1"; shift
    local _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    env -u NEXUS_ASSET_REPO -u NEXUS_CONFIG -u NEXUS_ROOT \
        PATH="$STUB_DIR:$PATH" \
        "$FAKE_NEXUS/monitor/upload-asset.sh" "$_local" "$@" \
        >"$_out_tmp" 2>"$_err_tmp"
    rc=$?
    stdout=$(<"$_out_tmp"); stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
}

# ---- Test 1: fresh EMPTY asset remote, host default branch = master -----
#
# Pre-fix: clone of the empty bare leaves the local clone on `master`
# (the bare advertises master); first commit lands on master; the
# script's `push origin main` fails with "src refspec main does not
# match any" → exit 3. Post-fix: HEAD is pinned to `main` on the unborn
# clone, the commit lands on main, push succeeds.

echo '=== fresh empty asset remote (host default=master) → push origin main succeeds ==='
rm -rf "$FAKE_NEXUS" "$BARE"
# Empty bare whose HEAD points at master, simulating a host with an
# un-configured / legacy init.defaultBranch=master.
"$REAL_GIT" -c init.defaultBranch=master init --quiet --bare "$BARE"
"$REAL_GIT" --git-dir="$BARE" symbolic-ref HEAD refs/heads/master
write_fake_nexus_stubs
# Note: $FAKE_NEXUS/assets does NOT exist → upload-asset.sh takes its own
# fresh-clone branch (the one carrying the B8 default-branch fix).

PAYLOAD="$WORK/firstfig.png"
printf 'first-asset-bytes\n' > "$PAYLOAD"

run_upload "$PAYLOAD" --issue 7
assert_eq "exit 0 on fresh empty remote"            "$rc" "0"
# The push must have created `main` on the bare (not `master`).
main_sha=$("$REAL_GIT" --git-dir="$BARE" rev-parse --verify -q main || true)
assert_eq "remote has a main branch after push"     "$([[ -n "$main_sha" ]] && echo yes || echo no)" "yes"
master_after=$("$REAL_GIT" --git-dir="$BARE" rev-parse --verify -q master || true)
assert_eq "no stray master branch was pushed"       "$([[ -z "$master_after" ]] && echo yes || echo no)" "yes"
show_stat=$("$REAL_GIT" --git-dir="$BARE" show --stat "$main_sha")
assert_contains "uploaded file landed on main"      "$show_stat" "assets/7/firstfig.png"
assert_contains "URL pins to the pushed main SHA"   "$stdout" "$main_sha"

# ---- Test 2: basename clobber across distinct sources → WARN ------------
#
# Two distinct source files sharing a basename route to the same
# REPO_PATH. The first upload must NOT warn; the second (different
# content at the same dest) MUST warn and name the escape hatch.

echo '=== distinct sources, same basename → second upload warns about clobber ==='
# Test 1 already left $FAKE_NEXUS/assets as a populated clone on main, so
# the script now takes its existing-repo branch (reset --hard origin/main).

SRC_A="$WORK/dirA/02_heatmap.png"; mkdir -p "$(dirname "$SRC_A")"
SRC_B="$WORK/dirB/02_heatmap.png"; mkdir -p "$(dirname "$SRC_B")"
printf 'AAAA-content\n' > "$SRC_A"
printf 'BBBB-content\n' > "$SRC_B"

run_upload "$SRC_A" --repo-path assets/general/02_heatmap.png
assert_eq "exit 0 on first upload"                  "$rc" "0"
assert_not_contains "first upload does not warn"    "$stderr" "WARNING"

run_upload "$SRC_B" --repo-path assets/general/02_heatmap.png
assert_eq "exit 0 on clobbering upload"             "$rc" "0"
assert_contains "second upload warns about clobber" "$stderr" "WARNING"
assert_contains "warning names the basename"        "$stderr" "02_heatmap.png"
assert_contains "warning points at --repo-path"     "$stderr" "--repo-path"

# ---- Test 3: no-op upload still emits the SHA-pinned URL ----------------
#
# Uploading identical content already present at the path is a no-op
# commit; the script must still print the URL on stdout (scrapers read
# stdout). The "unchanged; skipping commit" note belongs on stderr only.

echo '=== no-op upload (identical content) → URL still emitted on stdout ==='
SRC_C="$WORK/stable.txt"
printf 'stable-content\n' > "$SRC_C"

run_upload "$SRC_C" --repo-path assets/general/stable.txt
assert_eq "exit 0 on first stable upload"           "$rc" "0"
url_first="$stdout"
assert_contains "first upload emits a URL"          "$url_first" "https://github.com/fake-owner/fake-repo/raw/"

run_upload "$SRC_C" --repo-path assets/general/stable.txt
assert_eq "exit 0 on no-op upload"                  "$rc" "0"
assert_contains "no-op note is on stderr"           "$stderr" "unchanged; skipping commit"
assert_contains "no-op STILL emits a URL on stdout" "$stdout" "https://github.com/fake-owner/fake-repo/raw/"
assert_contains "no-op URL ends at the dest path"   "$stdout" "assets/general/stable.txt"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
