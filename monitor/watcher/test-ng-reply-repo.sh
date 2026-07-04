#!/usr/bin/env bash
# Unit tests for `ng reply`'s new --repo override (cmd_reply in monitor/ng).
#
# Run: bash monitor/watcher/test-ng-reply-repo.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: build a minimal nexus tree under a temp dir (a copy of `ng`
# plus stubbed `config/load.sh` and `mint-token.sh`), shadow `gh` on
# PATH to capture the POSTed endpoint and return a fake `html_url`,
# then run the test invocations and assert the captured endpoint
# embeds the right OWNER/REPO. Covers the --repo override and the
# unchanged default-behaviour paths (cwd-derived origin, $REPO
# fallback).

set -uo pipefail

# ---- harness ------------------------------------------------------------

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Minimal fake nexus tree. ng resolves $_script_dir/../config/load.sh
# and $_script_dir/mint-token.sh by relative path, so build the full
# directory shape.
FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config"
cp "$NG_REAL" "$FAKE_NEXUS/monitor/ng"
NG="$FAKE_NEXUS/monitor/ng"

# Stubbed config: only github.repo / github.user_login are read at
# top-level. Other keys yield exit 2 — load.sh's "key not found".
# Honors TEST_DEFAULT_REPO / TEST_DEFAULT_USER overrides; not yet a
# fit for the generic setup_fake_nexus helper (which doesn't expose
# env-var-driven branches). Migration to setup_fake_nexus is a
# separate follow-up.
cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf '%s' "${TEST_DEFAULT_REPO:-default-org/default-repo}" ;;
    github.user_login)  printf '%s' "${TEST_DEFAULT_USER:-test-user}" ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"

# Stubbed mint-token: ng's token() reads stdout, requires non-empty.
cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
printf 'fake-installation-token'
STUB
chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

# PATH-shadow gh. make_gh_stub captures every invocation's argv to
# $CAPTURE_FILE so the tests can assert which /repos/<owner>/<repo>/...
# endpoint was POSTed to. ng pipes the body JSON in via `--input -`;
# the helper drains stdin defensively. `reply` expects an html_url in
# the response body — we return a single canned shape.
STUB_DIR="$WORK/bin"
CAPTURE_FILE="$WORK/gh-calls.txt"
make_gh_stub "$STUB_DIR/gh" "$CAPTURE_FILE" <<'CASES'
    *)
        printf '%s' '{"html_url":"https://mock.example/posted-comment"}' ;;
CASES

# Run ng with stubs in front of PATH. Captures stdout/stderr/exit.
# Usage: run_ng <out-var> <err-var> <rc-var> <cwd> <args...>
run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3" _cwd="$4"; shift 4
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    : > "$CAPTURE_FILE"
    ( cd "$_cwd" && PATH="$STUB_DIR:$PATH" "$NG" "$@" >"$_out_tmp" 2>"$_err_tmp" )
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

# Three cwd shapes for the three default-resolution scenarios:
#   1. non-git dir  → ng falls back to $REPO from config
#   2. git repo with cwd origin == $REPO  → no warning, uses $REPO
#   3. git repo with cwd origin != $REPO  → cwd origin wins (with a warn)
NON_GIT_CWD="$WORK/non-git"
mkdir -p "$NON_GIT_CWD"

CWD_REPO="$WORK/cwd-git"
mkdir -p "$CWD_REPO"
( cd "$CWD_REPO" \
    && git init -q \
    && git remote add origin "git@github.com:cwd-org/cwd-repo.git" )

# ---- Test 1: --repo override is honoured --------------------------------

echo '=== ng reply --repo OWNER/NAME → POST hits /repos/OWNER/NAME ==='
echo "test body" > "$WORK/body.txt"
run_ng stdout stderr rc "$NON_GIT_CWD" \
    reply 42 --repo override-org/override-repo --body-file "$WORK/body.txt"
assert_eq        "exit 0 on happy path"                  "$rc" "0"
gh_args=$(<"$CAPTURE_FILE")
assert_contains  "POST endpoint embeds --repo target"    "$gh_args" \
                 "/repos/override-org/override-repo/issues/42/comments"
assert_not_contains "no fallback to config default"      "$gh_args" \
                    "default-org/default-repo"
assert_not_contains "no fallback to cwd origin"          "$gh_args" \
                    "cwd-org/cwd-repo"

# ---- Test 2: default (no --repo, non-git cwd) → $REPO from config -------

echo '=== ng reply (no --repo, non-git cwd) → POST hits $REPO from config ==='
run_ng stdout stderr rc "$NON_GIT_CWD" \
    reply 7 --body-file "$WORK/body.txt"
assert_eq        "exit 0 on default-fallback path"       "$rc" "0"
gh_args=$(<"$CAPTURE_FILE")
assert_contains  "POST endpoint embeds config \$REPO"    "$gh_args" \
                 "/repos/default-org/default-repo/issues/7/comments"

# ---- Test 3: default (no --repo, cwd origin differs) → STRUCTURED ERROR
#
# Issue #108: write verbs (reply is one) no longer cwd-derive
# silently. A cwd github origin that differs from $REPO with no
# --repo is a structured error, not a silent misroute.

echo '=== ng reply (no --repo, cwd origin != $REPO) → ERRORS with structured message ==='
run_ng stdout stderr rc "$CWD_REPO" \
    reply 9 --body-file "$WORK/body.txt"
assert_eq        "exit 1 on cwd-mismatch write"          "$rc" "1"
assert_contains  "stderr names the config target"        "$stderr" \
                 "writes to default-org/default-repo"
assert_contains  "stderr names the cwd repo"             "$stderr" \
                 "cwd is cwd-org/cwd-repo"
assert_contains  "stderr names --repo as the override"   "$stderr" \
                 "pass --repo explicitly"
gh_args=$(<"$CAPTURE_FILE")
assert_not_contains "no POST attempted on misroute-block" "$gh_args" \
                    "/repos/"

# ---- Test 3b: cwd origin == $REPO (matched) → no error, uses $REPO -----

echo '=== ng reply (no --repo, cwd origin matches $REPO) → uses $REPO silently ==='
MATCH_REPO="$WORK/match-cwd"
mkdir -p "$MATCH_REPO"
( cd "$MATCH_REPO" \
    && git init -q \
    && git remote add origin "git@github.com:default-org/default-repo.git" )
run_ng stdout stderr rc "$MATCH_REPO" \
    reply 13 --body-file "$WORK/body.txt"
assert_eq        "exit 0 when cwd matches \$REPO"        "$rc" "0"
gh_args=$(<"$CAPTURE_FILE")
assert_contains  "POST hits \$REPO from config"          "$gh_args" \
                 "/repos/default-org/default-repo/issues/13/comments"
assert_not_contains "no structured error when cwd matches" "$stderr" \
                    "writes to"

# ---- Test 4: --repo wins even when cwd has a different origin -----------

echo '=== ng reply --repo X, cwd origin Y → POST hits X (cwd ignored) ==='
run_ng stdout stderr rc "$CWD_REPO" \
    reply 11 --repo win-org/win-repo --body-file "$WORK/body.txt"
assert_eq        "exit 0 with --repo overriding cwd"     "$rc" "0"
gh_args=$(<"$CAPTURE_FILE")
assert_contains  "POST endpoint embeds --repo target"    "$gh_args" \
                 "/repos/win-org/win-repo/issues/11/comments"
assert_not_contains "cwd origin suppressed by --repo"    "$gh_args" \
                    "cwd-org/cwd-repo"
assert_not_contains "no structured error when --repo wins" "$stderr" \
                    "writes to default-org/default-repo"

# ---- Test 5: unknown flag → exit 1 --------------------------------------

echo '=== ng reply --bogus → exit 1 ==='
run_ng stdout stderr rc "$NON_GIT_CWD" \
    reply 1 --bogus value --body-file "$WORK/body.txt"
assert_eq        "exit 1 on unknown flag"                "$rc" "1"
assert_contains  "stderr names the unknown flag"         "$stderr" \
                 "--bogus"

# ---- Test 6: load-bearing leak-prevention for `ng issue create` --------
#
# Issue #108: a worker in a `nexus-code` worktree running
# `ng issue create` WITHOUT --repo previously cwd-derived to
# `nexus-code` and silently misrouted. Now it MUST error with the
# structured "writes to <config>; cwd is <cwd>; pass --repo
# explicitly" message — preventing accidental issue creation on
# the wrong repo (load-bearing for the soon-to-be-public
# nexus-code repo).

echo '=== ng issue create (cwd != $REPO, no --repo) → structured error ==='
# Simulate the worker's clone: cwd origin is `nexus-code`, config
# $REPO is `your-nexus`. The verb must refuse to write.
NEXUS_CODE_CWD="$WORK/nexus-code-clone"
mkdir -p "$NEXUS_CODE_CWD"
( cd "$NEXUS_CODE_CWD" \
    && git init -q \
    && git remote add origin "git@github.com:your-org/nexus-code.git" )
echo "test issue body" > "$WORK/issue-body.md"
TEST_DEFAULT_REPO="your-org/your-nexus" \
run_ng stdout stderr rc "$NEXUS_CODE_CWD" \
    issue create --title "test issue" --body-file "$WORK/issue-body.md"
assert_eq        "exit 1 on misroute-block"              "$rc" "1"
assert_contains  "stderr names config target as dest"    "$stderr" \
                 "writes to your-org/your-nexus"
assert_contains  "stderr names cwd repo"                 "$stderr" \
                 "cwd is your-org/nexus-code"
assert_contains  "stderr names --repo override"          "$stderr" \
                 "pass --repo explicitly"
gh_args=$(<"$CAPTURE_FILE")
assert_not_contains "no POST to either repo on misroute-block" "$gh_args" \
                    "/repos/"

# Explicit --repo passes through unchanged (smoke).
TEST_DEFAULT_REPO="your-org/your-nexus" \
run_ng stdout stderr rc "$NEXUS_CODE_CWD" \
    issue create --repo your-org/nexus-code \
                 --title "intentional cross-repo" --body-file "$WORK/issue-body.md"
assert_eq        "exit 0 when --repo explicit overrides" "$rc" "0"
gh_args=$(<"$CAPTURE_FILE")
assert_contains "POST hits the explicit --repo target"  "$gh_args" \
                "/repos/your-org/nexus-code/issues"

# ---- Test 7: read verbs still cwd-derive ergonomically -----------------
#
# The precedence invert applies to WRITE verbs only — read verbs
# (issue view, pr view, show) preserve the cwd-derive default so
# `cd $repo && ng issue view 12` Just Works without --repo.

echo '=== ng issue view (read verb) still cwd-derives without errors ==='
# Reuse CWD_REPO from earlier (origin: cwd-org/cwd-repo, $REPO: default-org/default-repo).
TEST_DEFAULT_REPO="default-org/default-repo" \
run_ng stdout stderr rc "$CWD_REPO" \
    issue 12
# gh stub returns canned JSON without a `.number`; cmd_issue_view
# dies with "fetch failed", but the failure mode isn't the point —
# the assertion is that the cwd-derive path didn't trigger the
# structured-write-error.
assert_not_contains "read verb does NOT trigger write-block error" "$stderr" \
                    "writes to default-org/default-repo"
gh_args=$(<"$CAPTURE_FILE")
assert_contains "read verb hits cwd-origin repo"        "$gh_args" \
                "/repos/cwd-org/cwd-repo/issues/12"

# ---- Test 8: `ng comment` alias posts like `ng reply` (#236 B4) --------
#
# `comment` is a thin alias for `reply` — same endpoint, same flag
# surface. Verify it POSTs to the issue-comments endpoint of the
# explicit --repo target, identically to reply.

echo '=== ng comment --repo OWNER/NAME → POST hits /repos/OWNER/NAME issue comments ==='
run_ng stdout stderr rc "$NON_GIT_CWD" \
    comment 42 --repo override-org/override-repo --body-file "$WORK/body.txt"
assert_eq        "exit 0 on comment alias"               "$rc" "0"
gh_args=$(<"$CAPTURE_FILE")
assert_contains  "comment POSTs to issue-comments endpoint" "$gh_args" \
                 "/repos/override-org/override-repo/issues/42/comments"

# ---- summary ------------------------------------------------------------

th_summary_and_exit
