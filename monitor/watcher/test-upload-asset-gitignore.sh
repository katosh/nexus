#!/usr/bin/env bash
# Regression test for `monitor/upload-asset.sh` option-2 behaviour
# (issue #144): when the asset repo's `.gitignore` matches the upload
# destination, the file must still land in the post-push commit, a
# stderr breadcrumb must explain why, and the printed URL must be the
# github.com shape pinned to the new SHA.
#
# Run: bash monitor/watcher/test-upload-asset-gitignore.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: stand up a local bare repo as the "asset remote", clone it
# into a fake nexus root pre-seeded with a `/assets/` .gitignore, then
# invoke the real upload-asset.sh against that fake root with PATH-
# stubbed `git` (no-ops `remote set-url`, otherwise pass-through), a
# stub `mint-token.sh`, and a stub `config/load.sh`. Everything else
# — fetch, add, commit, push — runs against the local bare for real,
# so the assertions exercise the actual git plumbing.

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

WORK=$(mktemp -d -t nexus-test-upload-asset-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

REAL_GIT=$(command -v git)
[[ -x "$REAL_GIT" ]] || { echo "git not on PATH; cannot run test" >&2; exit 2; }

# ---- build a fake nexus root and a local bare "asset remote" ------------

setup_fake_nexus() {
    # Args: $1 = gitignore body (multi-line OK; empty to skip seed).
    local gitignore_body="${1-}"

    FAKE_NEXUS="$WORK/nexus"
    BARE="$WORK/asset-repo.git"

    rm -rf "$FAKE_NEXUS" "$BARE"
    mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config"

    # Local bare repo as the "remote". Force HEAD to `main` so the
    # script's `git fetch origin main` / `git push origin main` line up.
    "$REAL_GIT" init --quiet --bare "$BARE"
    "$REAL_GIT" --git-dir="$BARE" symbolic-ref HEAD refs/heads/main

    # Seed the bare with an initial commit carrying the test .gitignore.
    local seed="$WORK/seed"
    rm -rf "$seed"
    "$REAL_GIT" clone --quiet "$BARE" "$seed" 2>/dev/null
    if [[ -n "$gitignore_body" ]]; then
        printf '%s\n' "$gitignore_body" > "$seed/.gitignore"
        "$REAL_GIT" -C "$seed" \
            -c user.name=test -c user.email=test@example.com \
            add .gitignore
    fi
    # Always create at least one commit so `main` exists on the bare.
    "$REAL_GIT" -C "$seed" \
        -c user.name=test -c user.email=test@example.com \
        commit --quiet --allow-empty -m "seed: ${gitignore_body:-empty}"
    "$REAL_GIT" -C "$seed" branch -M main 2>/dev/null || true
    "$REAL_GIT" -C "$seed" push --quiet origin HEAD:main
    rm -rf "$seed"

    # Copy upload-asset.sh into the fake nexus so its $_nexus_root
    # resolves to $FAKE_NEXUS rather than the real repo root.
    cp "$_real_script" "$FAKE_NEXUS/monitor/upload-asset.sh"
    chmod +x "$FAKE_NEXUS/monitor/upload-asset.sh"

    # Stub mint-token.sh: prints a deterministic fake token.
    cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "fake-token-for-tests"
STUB
    chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

    # Stub config/load.sh: matches signature `<key> [default]`.
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

    # Pre-clone the bare into $FAKE_NEXUS/assets so upload-asset.sh's
    # `if [[ ! -d "$ASSETS_DIR/.git" ]]` branch skips the github.com
    # clone path. The script will still `remote set-url origin` to a
    # github.com URL — we intercept that via the PATH stub below.
    "$REAL_GIT" clone --quiet "$BARE" "$FAKE_NEXUS/assets"
}

# PATH stub for `git`: no-ops any invocation that mentions `set-url`
# (so the script can't repoint origin at github.com), otherwise passes
# through to the real git binary captured at setup time.
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/git" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
    [[ "\$arg" == "set-url" ]] && exit 0
done
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$STUB_DIR/git"

run_upload() {
    # Args: <local_file> [extra upload-asset.sh args...]
    # Sets stdout, stderr, rc as caller-visible vars.
    local _local="$1"; shift
    local _out _err _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    env -u NEXUS_ASSET_REPO -u NEXUS_CONFIG -u NEXUS_ROOT \
        PATH="$STUB_DIR:$PATH" \
        "$FAKE_NEXUS/monitor/upload-asset.sh" "$_local" "$@" \
        >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _out=$(<"$_out_tmp"); _err=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    stdout="$_out"; stderr="$_err"; rc="$_rc"
}

# ---- Test 1: asset repo .gitignore contains `/assets/` ------------------
#
# This is the #144 regression. With option 2:
#   - file lands in the post-push commit
#   - stderr emits the breadcrumb
#   - printed URL is github.com shape pinned to the new SHA

echo '=== .gitignore=/assets/ → file lands, breadcrumb emitted, github.com URL ==='
setup_fake_nexus "/assets/"

PAYLOAD="$WORK/payload.png"
printf 'fake-png-bytes\n' > "$PAYLOAD"

run_upload "$PAYLOAD" --issue 1
assert_eq "exit 0"                                       "$rc" "0"
assert_contains "breadcrumb names the upload path"       "$stderr" "assets/1/payload.png"
assert_contains "breadcrumb explains the force-add"      "$stderr" "force-adding past it"
assert_contains "breadcrumb hints work/ vs asset-repo"   "$stderr" "work/"

# File landed in the post-push commit on the bare's main?
post_sha=$("$REAL_GIT" --git-dir="$BARE" rev-parse main)
show_stat=$("$REAL_GIT" --git-dir="$BARE" show --stat "$post_sha")
assert_contains "file landed in post-push commit"        "$show_stat" "assets/1/payload.png"

# URL shape + SHA pin.
expected_url="https://github.com/fake-owner/fake-repo/raw/${post_sha}/assets/1/payload.png"
assert_contains "URL is github.com shape (not raw.githubusercontent)" \
                "$stdout" "https://github.com/fake-owner/fake-repo/raw/"
assert_not_contains "URL must not be raw.githubusercontent.com shape" \
                "$stdout" "raw.githubusercontent.com"
assert_contains "URL pins to the new SHA"                "$stdout" "$post_sha"
assert_contains "URL ends at the destination path"       "$stdout" "assets/1/payload.png"
assert_contains "full URL matches expected"              "$stdout" "$expected_url"

# ---- Test 2: empty .gitignore → no breadcrumb, file still lands ---------
#
# Sanity check that the breadcrumb is gated on an actual ignore match —
# we don't want every successful upload to emit a noisy warning.

echo '=== no matching .gitignore → no breadcrumb, file still lands ==='
setup_fake_nexus ""   # empty seed, no ignore rules

PAYLOAD2="$WORK/clean.png"
printf 'clean-bytes\n' > "$PAYLOAD2"

run_upload "$PAYLOAD2" --issue 2
assert_eq "exit 0 on clean repo"                         "$rc" "0"
assert_not_contains "no breadcrumb when nothing ignored" \
                "$stderr" "matches a .gitignore rule"
assert_not_contains "no force-add breadcrumb either"    \
                "$stderr" "force-adding past it"
post_sha2=$("$REAL_GIT" --git-dir="$BARE" rev-parse main)
show_stat2=$("$REAL_GIT" --git-dir="$BARE" show --stat "$post_sha2")
assert_contains "clean upload lands in commit"           "$show_stat2" "assets/2/clean.png"

# ---- Test 3: .gitignore rule matches a sub-path (e.g. /assets/general/)
#
# Edge case: ignore rule narrower than `/assets/`. The fix should still
# detect it and force-add past it.

echo '=== .gitignore=/assets/general/ → file lands when --issue routes elsewhere too ==='
setup_fake_nexus "/assets/general/"

PAYLOAD3="$WORK/in-general.txt"
printf 'general-bucket\n' > "$PAYLOAD3"

# No --issue, no --repo-path: defaults to assets/general/.
run_upload "$PAYLOAD3"
assert_eq "exit 0 on /assets/general/ ignore"            "$rc" "0"
assert_contains "breadcrumb fires for narrow ignore"     "$stderr" "assets/general/in-general.txt"
post_sha3=$("$REAL_GIT" --git-dir="$BARE" rev-parse main)
show_stat3=$("$REAL_GIT" --git-dir="$BARE" show --stat "$post_sha3")
assert_contains "narrow-ignore file lands in commit"     "$show_stat3" "assets/general/in-general.txt"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
