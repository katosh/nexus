#!/usr/bin/env bash
# Unit tests for `ng wrap-up` (cmd_wrap_up in monitor/ng).
#
# Run: bash monitor/watcher/test-ng-wrap-up.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy mirrors test-ng-reply-repo.sh:
#   - Build a minimal nexus tree under a temp dir (ng + stubbed
#     config/load.sh + stubbed mint-token.sh + a stubbed
#     upload-asset.sh that records its argv and prints a canned URL
#     unless $MOCK_UPLOAD_FAIL is set).
#   - PATH-shadow `gh` to record the POST/reaction endpoints and
#     return canned JSON, with toggles to simulate per-step failure.
#
# Each test resets the mocks and capture file, runs `ng wrap-up`,
# and asserts both the stdout step-status lines and the captured
# side-effects against the four-step contract:
#   1. upload report
#   2. post templated comment (skipped if upload failed)
#   3. rocket trigger comment (skipped if --trigger-comment absent)
#   4. log-action wrap-up

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"

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
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}
assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing file: %s\n' "$label" "$path" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config" "$FAKE_NEXUS/reports"
cp "$NG_REAL" "$FAKE_NEXUS/monitor/ng"
NG="$FAKE_NEXUS/monitor/ng"
STATE_DIR="$FAKE_NEXUS/monitor/.state"

# Stubbed config — same shape as test-ng-reply-repo.sh.
cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf '%s' "${TEST_DEFAULT_REPO:-default-org/default-repo}" ;;
    github.user_login)  printf '%s' "${TEST_DEFAULT_USER:-test-user}" ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"

cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
printf 'fake-installation-token'
STUB
chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

# Stubbed upload-asset.sh. Records argv to $UPLOAD_CAPTURE and prints
# a canned SHA-pinned URL on stdout (the real script's contract).
# MOCK_UPLOAD_FAIL=1 → exit non-zero with an error on stderr.
UPLOAD_CAPTURE="$WORK/upload-calls.txt"
cat > "$FAKE_NEXUS/monitor/upload-asset.sh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$UPLOAD_CAPTURE"
if [[ "\${MOCK_UPLOAD_FAIL:-0}" == "1" ]]; then
    echo "upload-asset.sh: mock failure (auth or push refused)" >&2
    exit 3
fi
# Strip optional leading args; the local path is the first positional.
LOCAL=""
ISSUE=""
while (( \$# > 0 )); do
    case "\$1" in
        --issue)     ISSUE="\$2"; shift 2 ;;
        --*)         shift 2 ;;
        *)           [[ -z "\$LOCAL" ]] && LOCAL="\$1"; shift ;;
    esac
done
BASENAME="\$(basename "\$LOCAL")"
SHA="\${MOCK_UPLOAD_SHA:-deadbeefcafe1234}"
printf 'https://github.com/asset-org/assets/raw/%s/assets/%s/%s\\n' \
    "\$SHA" "\${ISSUE:-general}" "\$BASENAME"
STUB
chmod +x "$FAKE_NEXUS/monitor/upload-asset.sh"

# PATH-shadow gh. Records every invocation to $GH_CAPTURE. For
# `gh api`, returns canned JSON unless the per-step failure toggle
# matches the endpoint:
#   MOCK_COMMENT_FAIL=1 → /issues/<n>/comments POST returns 1 + error JSON
#   MOCK_ROCKET_FAIL=1  → /issues/comments/<id>/reactions POST returns 1
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
GH_CAPTURE="$WORK/gh-calls.txt"
# Stateful fake comment store for the post-once / re-point tests
# (#524 defect 2): POST to the issue-comments endpoint persists the
# body; GET/PATCH on /issues/comments/1234 read/mutate it.
COMMENT_STORE="$WORK/comment-store.json"
COMMENT_SEQ="$WORK/comment-updated-seq"

# Stubbed tmux. wrap-up calls
#   tmux display-message -p -t "$TMUX_PANE" '#{window_name}'
# when running inside a tmux session (TMUX is non-empty). Without
# `-t`, display-message returns the active window of the session
# — wrong when wrap-up runs in a non-active worker pane. The stub
# enforces this by RECORDING the -t value to $TMUX_CAPTURE and
# REQUIRING `-t %<pane>` for display-message calls; without it the
# stub prints an error to stderr and the assertion in test 16-target
# fails. MOCK_TMUX_WINDOW is the canned return value for the happy
# path.
TMUX_CAPTURE="$WORK/tmux-calls.txt"
cat > "$STUB_DIR/tmux" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$TMUX_CAPTURE"
if [[ "\${1:-}" == "display-message" ]]; then
    # Require -t to be present and to look like a pane id (\$TMUX_PANE
    # is set by tmux to %<digits>). Refuse the default (active-window)
    # targeting so the regression test catches a re-introduction of
    # the pre-fix behaviour.
    saw_target=0
    target_val=""
    shift
    while (( \$# > 0 )); do
        case "\$1" in
            -t) saw_target=1; target_val="\$2"; shift 2 ;;
            -p) shift ;;
            *) shift ;;
        esac
    done
    if (( saw_target == 0 )); then
        echo "stub-tmux: display-message MISSING -t (would return active-window name; bug)" >&2
        exit 1
    fi
    if [[ ! "\$target_val" =~ ^%[0-9]+\$ ]]; then
        echo "stub-tmux: display-message -t '\$target_val' not a pane id" >&2
        exit 1
    fi
    printf '%s' "\${MOCK_TMUX_WINDOW:-}"
    exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"

if [[ "\${1:-}" != "api" ]]; then
    exit 0
fi
# Walk argv to find the endpoint (the first positional that begins with "/").
endpoint=""
shift  # drop "api"
while (( \$# > 0 )); do
    case "\$1" in
        --input)  shift 2 ;;       # drain stdin too
        -X|-H|-f) shift 2 ;;
        --)       shift; break ;;
        /*)       endpoint="\$1"; shift ;;
        *)        shift ;;
    esac
done
# Drain stdin defensively (some calls --input -)
if ! [ -t 0 ]; then cat >/dev/null 2>&1 || true; fi

case "\$endpoint" in
    */issues/*/comments)
        if [[ "\${MOCK_COMMENT_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock comment POST 422"}' >&2
            exit 1
        fi
        printf '{"html_url":"https://mock.example/issuecomment-1234"}'
        ;;
    */issues/comments/*/reactions)
        if [[ "\${MOCK_ROCKET_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock reactions POST 422"}' >&2
            exit 1
        fi
        printf '{"id":99999,"content":"rocket"}'
        ;;
    *)
        printf '{}'
        ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# Run ng with stubs in front of PATH. Captures stdout/stderr/exit.
# By default unsets TMUX so wrap-up sees no tmux context (the
# expected shape for the bulk of these tests, which assert non-tmux
# behaviour). Set MOCK_TMUX=1 + MOCK_TMUX_WINDOW=<name> to opt in
# to a tmux context for issue-#109 tests.
#
# Hermetic STATE_DIR: ng's _resolve_state_dir consults
# NEXUS_STATE_DIR / NEXUS_ROOT / config nexus.root before the
# $_script_dir/.state fallback. Pin NEXUS_STATE_DIR to the
# fixture's state dir and unset NEXUS_ROOT/NEXUS_CONFIG so the
# operator's exported env doesn't redirect the action-log out of
# $FAKE_NEXUS (mirrors the fix applied to test-ng-fetch-asset.sh
# in ce1cffb6).
#
# Skeptic isolation: this suite exercises the GitHub HAND-OFF mechanics
# (upload / comment / rocket / log / retain), not the skeptic step. The
# fixture window has no spawn provenance, so it resolves to `auto` mode;
# with monitor.skeptic.enforce_auto_decision now defaulting TRUE, a bare
# wrap-up (no --skeptic-decision) would fail step 6 and flip the exit
# code, masking the hand-off assertions. The skeptic step has its own
# dedicated suite (test-skeptic-channel.sh, including the enforce-on/off
# + consequence assertions), so pin the env override OFF here to isolate
# the unit under test. (The override-wins contract is itself asserted in
# test-skeptic-channel.sh.)
run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    : > "$GH_CAPTURE"
    : > "$UPLOAD_CAPTURE"
    if [[ "${MOCK_TMUX:-0}" == "1" ]]; then
        # MOCK_TMUX branch deliberately sets TMUX/TMUX_PANE — we are
        # testing the tmux-context code path, so they must be present.
        env -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
            NEXUS_STATE_DIR="$STATE_DIR" \
            MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=0 \
            TMUX="${MOCK_TMUX_SOCKET:-/tmp/fake-tmux-sock}" \
            TMUX_PANE="${MOCK_TMUX_PANE:-%42}" \
            PATH="$STUB_DIR:$PATH" \
            "$NG" "$@" >"$_out_tmp" 2>"$_err_tmp"
    else
        env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
            NEXUS_STATE_DIR="$STATE_DIR" \
            MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=0 \
            PATH="$STUB_DIR:$PATH" \
            "$NG" "$@" >"$_out_tmp" 2>"$_err_tmp"
    fi
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

reset_mocks() {
    unset MOCK_UPLOAD_FAIL MOCK_UPLOAD_SHA MOCK_COMMENT_FAIL MOCK_ROCKET_FAIL
    unset MOCK_COMMENT_MOVING
    rm -rf "$STATE_DIR"
    rm -f "$COMMENT_STORE" "$COMMENT_SEQ"
}

# Standard well-formed report used across the happy-path tests.
# The body is intentionally well above the 500-char default minimum
# so the new pre-flight `report-check` (PR #4 round 4) accepts it
# without `--allow-stub`. Frontmatter carries every required field.
write_report() {
    local path="$1"
    cat > "$path" <<'EOF'
---
project: nexus
date: 2026-05-10
session-id: 4e8f1c2b-3a91-4d77-b9e0-5f2d0a1c7e8a
window: wrap-up-test
trigger: #42 (comment 7777)
status: completed
---

# Wrap-up dogfood: first iteration

## Summary

Implemented ng wrap-up so workers can hand off in one verb. The verb
folds upload + comment + rocket + log into a single call.

## What Was Done

- Added cmd_wrap_up to monitor/ng.
- Added tests under monitor/watcher/.
- Wired upload-asset.sh as the step-1 plumbing.
- Wired ng reply --repo as the step-2 backend.
- Added structured per-step status to stdout and per-step
  failure detail to stderr.

## Current State

- Branch operator/ng-wrap-up-and-friction-fixes, commits 91e1940
  through 80d4715. Tests green across the watcher suite.

## What Remains

- Address review on PR your-org/nexus-code#4.
- Land round-4 expansion once the PR is merged.

## How to Resume

- git checkout operator/ng-wrap-up-and-friction-fixes
- bash monitor/watcher/test-ng-wrap-up.sh
- Read this report for context.
EOF
}

REPORT="$FAKE_NEXUS/reports/nexus_2026-05-10_120000_wrap-up-test.md"
write_report "$REPORT"

# ---- Test 1: happy path with all four steps ----------------------------

echo '=== happy path: all four steps succeed, exit 0 ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
assert_eq        "exit 0 on full happy path"          "$rc" "0"
assert_contains  "stdout reports uploaded URL"        "$stdout" \
                 "uploaded: https://github.com/asset-org/assets/raw/deadbeefcafe1234"
assert_contains  "stdout reports comment URL"        "$stdout" \
                 "posted comment: https://mock.example/issuecomment-1234"
assert_contains  "stdout reports rocketed trigger"   "$stdout" \
                 "rocketed comment 7777"
assert_contains  "stdout reports logged action"      "$stdout" \
                 "logged action: wrap-up issue=42"

# Side-effect: upload-asset.sh called with --issue 42 and the report path.
upload_args=$(<"$UPLOAD_CAPTURE")
assert_contains "upload-asset.sh called with --issue 42" "$upload_args" \
                "--issue 42"
assert_contains "upload-asset.sh called with the report" "$upload_args" \
                "$(basename "$REPORT")"

# Side-effect: gh POSTed the comment to the right repo.
gh_calls=$(<"$GH_CAPTURE")
assert_contains "comment POST hits override-org/override-repo" "$gh_calls" \
                "/repos/override-org/override-repo/issues/42/comments"
assert_contains "rocket POST hits the trigger comment"        "$gh_calls" \
                "/repos/override-org/override-repo/issues/comments/7777/reactions"

# Side-effect: action-log.jsonl has a wrap-up entry.
LOG_FILE="$STATE_DIR/action-log.jsonl"
assert_file_exists "action-log.jsonl created" "$LOG_FILE"
log_line=$(<"$LOG_FILE")
assert_contains "log entry names event=wrap-up"     "$log_line" '"event":"wrap-up"'
assert_contains "log entry names issue=42"          "$log_line" '"issue":"42"'
assert_contains "log entry names upload=ok"         "$log_line" '"upload":"ok"'
assert_contains "log entry names comment=ok"        "$log_line" '"comment":"ok"'
assert_contains "log entry names rocket=ok"         "$log_line" '"rocket":"ok"'

# ---- Test 2: missing arg → exit 1 + usage --------------------------------

echo '=== missing args → exit 1 + usage line ==='
reset_mocks
run_ng stdout stderr rc wrap-up
assert_eq       "exit 1 with no args"                "$rc" "1"
assert_contains "stderr prints usage"                "$stderr" \
                "usage: ng wrap-up"

# ---- Test 3: report path doesn't exist → exit 1 -------------------------

echo '=== missing report file → exit 1 ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$WORK/nope.md" --repo a/b
assert_eq       "exit 1 on missing report"           "$rc" "1"
assert_contains "stderr names the missing report"    "$stderr" \
                "report not found"

# ---- Test 4: upload fails → comment skipped, exit 1, structured stderr -

echo '=== upload fails → comment skipped, exit 1, structured stderr ==='
reset_mocks
export MOCK_UPLOAD_FAIL=1
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
assert_eq       "exit 1 on upload failure"           "$rc" "1"
assert_contains "stdout reports upload FAILED"       "$stdout" \
                "uploaded: FAILED"
assert_contains "stdout reports comment SKIPPED"     "$stdout" \
                "posted comment: SKIPPED"
assert_contains "stderr names upload as the failed step" "$stderr" \
                "upload: upload-asset.sh failed"
# Comment was NOT attempted (no POST to /issues/.../comments).
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "no comment POST attempted when upload failed" "$gh_calls" \
                    "/issues/42/comments"
# Rocket IS still attempted — it's independent of upload.
assert_contains "rocket still POSTed on upload failure" "$gh_calls" \
                "/issues/comments/7777/reactions"
# Log-action still recorded with upload=failed.
LOG_FILE="$STATE_DIR/action-log.jsonl"
assert_file_exists "log file still written on partial failure" "$LOG_FILE"
log_line=$(<"$LOG_FILE")
assert_contains "log entry names upload=failed"      "$log_line" \
                '"upload":"failed"'
assert_contains "log entry names comment=skipped on upload-fail" "$log_line" \
                '"comment":"skipped"'

# ---- Test 5: comment POST fails → exit 1, rocket + log still attempt ---

echo '=== comment fails → exit 1, rocket + log still attempt ==='
reset_mocks
export MOCK_COMMENT_FAIL=1
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
assert_eq       "exit 1 on comment failure"          "$rc" "1"
assert_contains "stdout reports uploaded URL"        "$stdout" "uploaded: "
assert_contains "stdout reports comment FAILED"      "$stdout" \
                "posted comment: FAILED"
assert_contains "stdout reports rocketed"            "$stdout" \
                "rocketed comment 7777"
assert_contains "stderr names comment as the failed step" "$stderr" \
                "comment: POST"
# Log entry records comment=failed but upload=ok.
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_line=$(<"$LOG_FILE")
assert_contains "log entry names upload=ok"          "$log_line" '"upload":"ok"'
assert_contains "log entry names comment=failed"     "$log_line" '"comment":"failed"'

# ---- Test 6: rocket POST fails → exit 1, upload/comment still ok ------

echo '=== rocket fails → exit 1, upload+comment still ok ==='
reset_mocks
export MOCK_ROCKET_FAIL=1
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
assert_eq       "exit 1 on rocket failure"           "$rc" "1"
assert_contains "stdout reports uploaded URL"        "$stdout" "uploaded: "
assert_contains "stdout reports comment ok"          "$stdout" "posted comment: https://"
assert_contains "stdout reports rocketed FAILED"     "$stdout" \
                "rocketed comment 7777: FAILED"
assert_contains "stderr names rocket as the failed step" "$stderr" \
                "rocket: POST"

# ---- Test 7: --trigger-comment omitted → rocket step skipped ----------

echo '=== no --trigger-comment → rocket skipped, exit 0 ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq       "exit 0 without --trigger-comment"   "$rc" "0"
assert_not_contains "no rocket line printed" "$stdout" "rocketed comment"
# And no reactions POST.
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "no reactions POST issued" "$gh_calls" "/reactions"

# ---- Test 8: --trigger-comment 0 treated as skip ----------------------

echo '=== --trigger-comment 0 → rocket skipped ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 0 --repo override-org/override-repo
assert_eq       "exit 0 with --trigger-comment 0"    "$rc" "0"
assert_not_contains "no rocket line printed for 0"   "$stdout" \
                    "rocketed comment"

# ---- Test 9: comment body templates pull title + summary -------------

echo '=== comment body template pulls H1 + Summary section first sentence ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq       "exit 0 on template happy path"      "$rc" "0"

# To verify the body template, peek at the captured gh argv. The body
# JSON arrived via stdin (`--input -`) which our stub drains; we can't
# round-trip it from $GH_CAPTURE alone. Instead, intercept the JSON
# payload via a body-aware stub override for this single test.
BODY_CAPTURE="$WORK/comment-body.txt"
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"
if [[ "\${1:-}" != "api" ]]; then exit 0; fi
endpoint=""
shift
while (( \$# > 0 )); do
    case "\$1" in
        --input)  cat > "$BODY_CAPTURE"; shift 2 ;;
        -X|-H|-f) shift 2 ;;
        --)       shift; break ;;
        /*)       endpoint="\$1"; shift ;;
        *)        shift ;;
    esac
done
case "\$endpoint" in
    */issues/*/comments) printf '{"html_url":"https://mock.example/cmt"}' ;;
    *)                    printf '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
body=$(jq -r '.body // ""' < "$BODY_CAPTURE" 2>/dev/null)
assert_contains "comment body embeds the report's H1 title" "$body" \
                "Wrap-up dogfood: first iteration"
assert_contains "comment body embeds the Summary first sentence" "$body" \
                "Implemented ng wrap-up"
assert_contains "comment body links to the uploaded asset"  "$body" \
                "Full report: https://github.com/asset-org"

# Restore the canonical stub for any later tests below.
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"
if [[ "\${1:-}" != "api" ]]; then exit 0; fi
endpoint=""
shift
while (( \$# > 0 )); do
    case "\$1" in
        --input)  shift 2 ;;
        -X|-H|-f) shift 2 ;;
        --)       shift; break ;;
        /*)       endpoint="\$1"; shift ;;
        *)        shift ;;
    esac
done
if ! [ -t 0 ]; then cat >/dev/null 2>&1 || true; fi
case "\$endpoint" in
    */issues/*/comments)
        if [[ "\${MOCK_COMMENT_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock comment POST 422"}' >&2; exit 1
        fi
        printf '{"html_url":"https://mock.example/issuecomment-1234"}' ;;
    */issues/comments/*/reactions)
        if [[ "\${MOCK_ROCKET_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock reactions POST 422"}' >&2; exit 1
        fi
        printf '{"id":99999,"content":"rocket"}' ;;
    *) printf '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# ---- Test 10: bare report (no frontmatter, no H1) → pre-flight rejects -

echo '=== bare report (no frontmatter) → pre-flight report-check rejects ==='
BARE_REPORT="$FAKE_NEXUS/reports/bare-report.md"
cat > "$BARE_REPORT" <<'EOF'
This file intentionally has no markdown H1 heading.

Just a single paragraph of body text describing the run.
EOF
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$BARE_REPORT" --repo override-org/override-repo
assert_eq        "exit 1 on bare-report pre-flight fail"   "$rc" "1"
assert_contains  "stderr explains the pre-flight"          "$stderr" \
                 "report-check failed"
assert_contains  "stderr names --allow-stub override"      "$stderr" \
                 "--allow-stub"
assert_contains  "stderr names frontmatter as missing"     "$stderr" \
                 "frontmatter"
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "no upload attempted on pre-flight fail" "$gh_calls" \
                    "/issues/42/comments"

# Test 10b: same bare report with a fully-fleshed body but no frontmatter
# still fails the pre-flight (body+sections alone aren't enough).
FAT_NOFRONT="$FAKE_NEXUS/reports/fat-no-front.md"
cat > "$FAT_NOFRONT" <<'EOF'
# Worker delivered substantive content but forgot frontmatter

## Summary
We delivered a meaningful change set but didn't run ng report-init.
The body has all the canonical sections and is well over the
500-character minimum. The pre-flight should still refuse because
the frontmatter is missing entirely, and the worker should be
nudged to re-do the report via ng report-init.

## What Was Done
- Things and things and things and things and things.

## Current State
- All sections present; no frontmatter.

## What Remains
- Re-do the report via ng report-init.

## How to Resume
- Run ng report-init.
EOF
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$FAT_NOFRONT" --repo override-org/override-repo
assert_eq        "exit 1 even with full body + no frontmatter" "$rc" "1"
assert_contains  "stderr names frontmatter"                "$stderr" \
                 "frontmatter"

# ---- Test 11: --comment-body-file with {{REPORT_URL}} → substitution ---

echo '=== --comment-body-file with {{REPORT_URL}} token → substituted ==='
# Reuse the body-capturing stub.
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"
if [[ "\${1:-}" != "api" ]]; then exit 0; fi
endpoint=""
shift
while (( \$# > 0 )); do
    case "\$1" in
        --input)  cat > "$BODY_CAPTURE"; shift 2 ;;
        -X|-H|-f) shift 2 ;;
        --)       shift; break ;;
        /*)       endpoint="\$1"; shift ;;
        *)        shift ;;
    esac
done
case "\$endpoint" in
    */issues/*/comments)              printf '{"html_url":"https://mock.example/cmt"}' ;;
    */issues/comments/*/reactions)    printf '{"id":111,"content":"rocket"}' ;;
    *)                                printf '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

CUSTOM_BODY="$WORK/custom-body.md"
cat > "$CUSTOM_BODY" <<'EOF'
This is bespoke synthesis prose with **bold** and inline `code`.

Findings landed in fig5. See {{REPORT_URL}} for the breakdown.

- Bullet one
- Bullet two
EOF
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --comment-body-file "$CUSTOM_BODY" --repo override-org/override-repo
assert_eq        "exit 0 on custom-body happy path"    "$rc" "0"
body=$(jq -r '.body // ""' < "$BODY_CAPTURE" 2>/dev/null)
assert_contains  "custom body preserved verbatim (bold)"  "$body" "**bold**"
assert_contains  "{{REPORT_URL}} substituted with asset URL" "$body" \
                 "https://github.com/asset-org/assets/raw/deadbeefcafe1234"
assert_not_contains "{{REPORT_URL}} token gone from body" "$body" \
                    "{{REPORT_URL}}"

# ---- Test 12: --comment-body-file without token → footer appended -------

echo '=== --comment-body-file with no token → "Full report: <URL>" footer ==='
NO_TOKEN_BODY="$WORK/no-token-body.md"
cat > "$NO_TOKEN_BODY" <<'EOF'
Custom prose that does not reference the report inline.
EOF
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --comment-body-file "$NO_TOKEN_BODY" --repo override-org/override-repo
assert_eq        "exit 0 with no-token body"           "$rc" "0"
body=$(jq -r '.body // ""' < "$BODY_CAPTURE" 2>/dev/null)
assert_contains  "custom prose preserved"              "$body" \
                 "Custom prose that does not reference"
assert_contains  "footer appended with asset URL"      "$body" \
                 "Full report: https://github.com/asset-org"

# ---- Test 13: --no-comment skips step 2 entirely ------------------------

echo '=== --no-comment → step 2 skipped, upload + rocket + log still run ==='
# Restore the canonical stub (no body capture, since no POST expected).
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"
if [[ "\${1:-}" != "api" ]]; then exit 0; fi
endpoint=""
shift
while (( \$# > 0 )); do
    case "\$1" in
        --input)  shift 2 ;;
        -X|-H|-f) shift 2 ;;
        --)       shift; break ;;
        /*)       endpoint="\$1"; shift ;;
        *)        shift ;;
    esac
done
if ! [ -t 0 ]; then cat >/dev/null 2>&1 || true; fi
case "\$endpoint" in
    */issues/*/comments)              printf '{"html_url":"https://mock.example/cmt"}' ;;
    */issues/comments/*/reactions)    printf '{"id":111,"content":"rocket"}' ;;
    *)                                printf '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo --no-comment
assert_eq        "exit 0 with --no-comment"            "$rc" "0"
assert_contains  "stdout reports uploaded URL"         "$stdout" "uploaded: "
assert_contains  "stdout reports comment SKIPPED"      "$stdout" \
                 "posted comment: SKIPPED"
assert_contains  "stdout reports rocketed"             "$stdout" "rocketed comment 7777"
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "no comment POST attempted"        "$gh_calls" \
                    "/issues/42/comments"
assert_contains  "rocket POST attempted"               "$gh_calls" \
                 "/issues/comments/7777/reactions"
# Log records comment=skipped so the orchestrator can tell apart
# "worker chose --no-comment" from "comment failed".
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_line=$(<"$LOG_FILE")
assert_contains  "log entry names comment=skipped"     "$log_line" \
                 '"comment":"skipped"'

# ---- Test 14: --no-comment + --comment-body-file → exit 1 (conflict) ---

echo '=== --no-comment + --comment-body-file → exit 1 ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --no-comment --comment-body-file "$CUSTOM_BODY" --repo a/b
assert_eq        "exit 1 on conflicting flags"         "$rc" "1"
assert_contains  "stderr names the conflict"           "$stderr" \
                 "mutually exclusive"

# ---- Test 15: --comment-body-file path missing → exit 1 ----------------

echo '=== --comment-body-file path missing → exit 1 ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --comment-body-file "$WORK/nope-body.md" --repo a/b
assert_eq        "exit 1 on missing body file"         "$rc" "1"
assert_contains  "stderr names the missing body file"  "$stderr" \
                 "comment-body-file not found"

# ---- Test 16: under tmux → log entry records window field (#109) -------

echo '=== under tmux → log entry includes "window":"<name>" ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="my-worker-window"
: > "$TMUX_CAPTURE"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq        "exit 0 with tmux context"            "$rc" "0"
LOG_FILE="$STATE_DIR/action-log.jsonl"
assert_file_exists "log file written"                  "$LOG_FILE"
log_line=$(<"$LOG_FILE")
assert_contains  "log entry records source window"     "$log_line" \
                 '"window":"my-worker-window"'

# Regression for the post-#10 bug: without `-t`, display-message
# returns the ACTIVE window of the session, not the calling pane's
# window. The stub-tmux refuses any display-message without `-t`,
# so the assertion above on `"window":"my-worker-window"` ONLY
# passes when ng targets by pane explicitly. Belt-and-suspenders:
# also assert the captured argv literally contains `-t %42`.
tmux_calls=$(<"$TMUX_CAPTURE")
assert_contains "tmux display-message targets pane via -t \$TMUX_PANE" \
                "$tmux_calls" "display-message -p -t %42"

# ---- Test 17: outside tmux → log entry omits window field --------------

echo '=== outside tmux → log entry has no window field ==='
reset_mocks
# Default run_ng path unsets TMUX.
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
assert_eq        "exit 0 without tmux context"         "$rc" "0"
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_line=$(<"$LOG_FILE")
assert_not_contains "log entry omits window field outside tmux" "$log_line" \
                    '"window":'

# ---- Test 18: --trigger-repo routes rocket to a different repo (#108) --

echo '=== --trigger-repo routes rocket-react to a different repo than --repo ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 \
    --repo issue-org/issue-repo \
    --trigger-repo trigger-org/trigger-repo
assert_eq        "exit 0 with --trigger-repo"          "$rc" "0"
gh_calls=$(<"$GH_CAPTURE")
assert_contains "comment POST hits --repo target (issue thread)" "$gh_calls" \
                "/repos/issue-org/issue-repo/issues/42/comments"
assert_contains "rocket POST hits --trigger-repo target"         "$gh_calls" \
                "/repos/trigger-org/trigger-repo/issues/comments/7777/reactions"
assert_not_contains "rocket does NOT post on --repo target"      "$gh_calls" \
                    "/repos/issue-org/issue-repo/issues/comments/7777/reactions"
# Log entry records the trigger-repo when it differs.
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_line=$(<"$LOG_FILE")
assert_contains "log entry records issue-thread repo"  "$log_line" \
                '"repo":"issue-org/issue-repo"'
assert_contains "log entry records cross-repo trigger" "$log_line" \
                '"trigger-repo":"trigger-org/trigger-repo"'

# ---- Test 19: --trigger-repo omitted → defaults to --repo (back-compat)

echo '=== --trigger-repo omitted → rocket falls back to --repo target ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo same-org/same-repo
assert_eq        "exit 0 with --trigger-repo absent"   "$rc" "0"
gh_calls=$(<"$GH_CAPTURE")
assert_contains "rocket POST hits --repo target (default)"  "$gh_calls" \
                "/repos/same-org/same-repo/issues/comments/7777/reactions"
# When trigger-repo == --repo, the log entry omits the trigger-repo
# extra (compact legacy shape).
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_line=$(<"$LOG_FILE")
assert_not_contains "log entry omits trigger-repo when same as --repo" "$log_line" \
                    '"trigger-repo":'

# ---- Test 20: under tmux → wrap-up auto-retains the source window ------

echo '=== under tmux → wrap-up auto-logs window-retain with default tag ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="retainme-worker"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq        "exit 0 on retain happy path"           "$rc" "0"
assert_contains  "stdout reports retained window"        "$stdout" \
                 "retained window: retainme-worker"
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_lines=$(<"$LOG_FILE")
# Two log entries: wrap-up first, then window-retain.
assert_contains  "log has the wrap-up entry"             "$log_lines" \
                 '"event":"wrap-up"'
assert_contains  "log has the window-retain entry"       "$log_lines" \
                 '"event":"window-retain"'
assert_contains  "retain entry names the source window"  "$log_lines" \
                 '"window":"retainme-worker"'
# Default reason is wrap-up-<YYYY-MM-DD>.
today=$(date -u +%Y-%m-%d)
assert_contains  "retain entry uses wrap-up-<date> auto-tag" "$log_lines" \
                 "\"reason\":\"wrap-up-${today}\""
assert_contains  "retain entry records the issue"        "$log_lines" \
                 '"issue":"42"'

# ---- Test 21: --retain <reason> overrides the auto-tag ----------------

echo '=== --retain <reason> overrides the wrap-up-<date> auto-tag ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="customtag-worker"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --repo override-org/override-repo \
    --retain "loaded-kompot-figures-kernel"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq        "exit 0 on --retain happy path"         "$rc" "0"
assert_contains  "stdout reports retained window"        "$stdout" \
                 "retained window: customtag-worker"
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_lines=$(<"$LOG_FILE")
assert_contains  "retain entry uses the custom reason"   "$log_lines" \
                 '"reason":"loaded-kompot-figures-kernel"'
assert_not_contains "retain entry omits the wrap-up-<date> auto-tag" "$log_lines" \
                    "wrap-up-${today}"

# ---- Test 22: --no-retain opts out of auto-retain ----------------------

echo '=== --no-retain opts out → no window-retain event ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="closeme-worker"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --repo override-org/override-repo --no-retain
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq        "exit 0 on --no-retain"                 "$rc" "0"
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_lines=$(<"$LOG_FILE")
assert_contains  "log has the wrap-up entry"             "$log_lines" \
                 '"event":"wrap-up"'
assert_not_contains "log has NO window-retain entry"     "$log_lines" \
                    '"event":"window-retain"'
assert_not_contains "stdout omits retained-window line"  "$stdout" \
                    "retained window:"

# ---- Test 23: outside tmux → no retain logged (no source_window) -------

echo '=== outside tmux → no source_window → no retain logged ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --repo override-org/override-repo
assert_eq        "exit 0 outside tmux"                   "$rc" "0"
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_lines=$(<"$LOG_FILE")
assert_not_contains "no window-retain logged off-tmux"   "$log_lines" \
                    '"event":"window-retain"'

# ---- Test 24: --no-retain + --retain → exit 1 (conflict) ---------------

echo '=== --no-retain + --retain → exit 1 (mutually exclusive) ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --repo a/b --no-retain --retain "irrelevant"
assert_eq        "exit 1 on conflicting retain flags"    "$rc" "1"
assert_contains  "stderr names the conflict"             "$stderr" \
                 "mutually exclusive"

# ---- Tests 25+: interactive-wrap clarification + engaged-done (the
#      #205 state-machine follow-up) ---------------------------------------
#
# A wrap-up from an operator-engaged (interactive) window must emit
# the clarification block telling the agent that staying engaged is
# the default and that `ng engaged-done` is the explicit
# finished-signal. A machine-driven wrap-up (no live mark) keeps
# today's output exactly. The engagement predicate mirrors the
# watcher's `_openg_marked` core: row seeded + pane-change within the
# change TTL + no newer engaged-done.

echo '=== interactive wrap-up → clarification block emitted ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="engaged-worker"
_iw_now=$(date +%s)
mkdir -p "$STATE_DIR/pane-change"
printf 'engaged-worker\t%s\t%s\t%s\tsubmit\t0\n' \
    "$(( _iw_now - 300 ))" "$(( _iw_now - 10 ))" "$(( _iw_now - 200 ))" \
    > "$STATE_DIR/operator-engaged.tsv"
printf 'h\t%s\n' "$_iw_now" > "$STATE_DIR/pane-change/engaged-worker"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq        "exit 0 on interactive wrap"            "$rc" "0"
assert_contains  "clarification block present"           "$stdout" \
                 "operator-engaged (interactive) session detected"
assert_contains  "default is stay-engaged"               "$stdout" \
                 "expecting follow-up user inquiries (the DEFAULT)"
assert_contains  "finished-signal verb named"            "$stdout" \
                 "ng engaged-done"

echo '=== machine wrap-up (no mark) → no clarification, output unchanged ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="machine-worker"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq           "exit 0 on machine wrap"             "$rc" "0"
assert_not_contains "no clarification without a mark"    "$stdout" \
                    "operator-engaged (interactive)"
assert_contains     "normal retain line still present"   "$stdout" \
                    "retained window: machine-worker"

echo '=== expired mark (pane static past change TTL) → no clarification ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="expired-worker"
_iw_now=$(date +%s)
mkdir -p "$STATE_DIR/pane-change"
printf 'expired-worker\t%s\t%s\t%s\tsubmit\t0\n' \
    "$(( _iw_now - 5000 ))" "$(( _iw_now - 4000 ))" "$(( _iw_now - 4500 ))" \
    > "$STATE_DIR/operator-engaged.tsv"
# Change clock frozen 2000 s ago — far past the default 600 s TTL.
printf 'h\t%s\n' "$(( _iw_now - 2000 ))" > "$STATE_DIR/pane-change/expired-worker"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --repo override-org/override-repo
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq           "exit 0 on expired-mark wrap"        "$rc" "0"
assert_not_contains "lapsed mark → no clarification"     "$stdout" \
                    "operator-engaged (interactive)"

echo '=== engaged-done: in-tmux → logs the finished-signal event ==='
reset_mocks
export MOCK_TMUX=1
export MOCK_TMUX_WINDOW="done-worker"
run_ng stdout stderr rc engaged-done
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq        "exit 0 on engaged-done"                "$rc" "0"
assert_contains  "confirmation names the window"         "$stdout" \
                 "engaged-done: done-worker released"
log_lines=$(<"$STATE_DIR/action-log.jsonl")
assert_contains  "log has the engaged-done event"        "$log_lines" \
                 '"event":"engaged-done"'
assert_contains  "event names the window"                "$log_lines" \
                 '"window":"done-worker"'

echo '=== engaged-done: --window override works off-tmux ==='
reset_mocks
run_ng stdout stderr rc engaged-done --window override-worker
assert_eq        "exit 0 with --window"                  "$rc" "0"
log_lines=$(<"$STATE_DIR/action-log.jsonl")
assert_contains  "event names the overridden window"     "$log_lines" \
                 '"window":"override-worker"'

echo '=== engaged-done: off-tmux without --window → loud failure ==='
reset_mocks
run_ng stdout stderr rc engaged-done
assert_eq        "exit 1 with no resolvable window"      "$rc" "1"
assert_contains  "stderr names the fix"                  "$stderr" \
                 "--window"

# ---- Test 30: skeptic gate runs BEFORE the GitHub hand-off (Change 3) ---
# An undecided `auto` worker under enforce_auto_decision must FAIL wrap-up
# WITHOUT uploading the report or posting any comment/rocket — so a
# blocked task never announces "done" and a retry can't double-post. The
# fixture window has no provenance → resolves to `auto`; we flip enforce
# ON for this one run (the rest of the suite pins it off to isolate the
# hand-off). report-check (step 0) still passes on the well-formed REPORT,
# so the skeptic step (step 0b) is genuinely what blocks.
echo '=== skeptic gate precedes hand-off: enforce-on undecided → no GitHub writes ==='
reset_mocks
: > "$GH_CAPTURE"; : > "$UPLOAD_CAPTURE"
_g_out=$(mktemp); _g_err=$(mktemp)
env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
    NEXUS_STATE_DIR="$STATE_DIR" \
    MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=1 \
    PATH="$STUB_DIR:$PATH" \
    "$NG" wrap-up 42 "$REPORT" --trigger-comment 7777 --repo override-org/override-repo \
    >"$_g_out" 2>"$_g_err"
rc=$?
stdout=$(<"$_g_out"); stderr=$(<"$_g_err"); rm -f "$_g_out" "$_g_err"
assert_eq        "enforce-on undecided → exit 1"             "$rc" "1"
assert_contains  "stdout names the decision-required block"  "$stdout" \
                 "SKEPTIC DECISION REQUIRED"
upload_args=$(<"$UPLOAD_CAPTURE")
assert_eq        "NO upload attempted before the gate"       "$upload_args" ""
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "NO comment POST before the gate"        "$gh_calls" \
                    "/issues/42/comments"
assert_not_contains "NO rocket reaction before the gate"     "$gh_calls" \
                    "/reactions"
# And the auto-require decision path DOES proceed to the hand-off (gate
# satisfied) → report uploaded + comment posted, exit 0.
echo '=== skeptic gate satisfied (auto→require) → hand-off proceeds ==='
reset_mocks
: > "$GH_CAPTURE"; : > "$UPLOAD_CAPTURE"
_g_out=$(mktemp); _g_err=$(mktemp)
env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
    NEXUS_STATE_DIR="$STATE_DIR" \
    MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=1 \
    PATH="$STUB_DIR:$PATH" \
    "$NG" wrap-up 42 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched shared infra" \
    >"$_g_out" 2>"$_g_err"
rc=$?
stdout=$(<"$_g_out"); rm -f "$_g_out" "$_g_err"
assert_eq        "auto→require decision → exit 0"            "$rc" "0"
assert_contains  "hand-off ran: report uploaded"            "$stdout" "uploaded: https://"
gh_calls=$(<"$GH_CAPTURE")
assert_contains  "hand-off ran: comment POSTed"             "$gh_calls" \
                 "/issues/42/comments"

# Re-establish the FULL canonical gh stub — now STATEFUL (#524 defect
# 2): tests 11/13 above left a simplified stub in place (returns
# .../cmt, ignores MOCK_*_FAIL). The post-once tests below need the
# issuecomment-1234 URL, the MOCK_ROCKET_FAIL toggle, AND a real
# comment record: POST persists the body to $COMMENT_STORE; GET/PATCH
# on /issues/comments/1234 read/mutate it (PATCH bumps updated_at).
# MOCK_COMMENT_MOVING=1 bumps updated_at on every GET, simulating a
# comment under sustained concurrent edits (the CAS must fail loud).
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"
if [[ "\${1:-}" != "api" ]]; then exit 0; fi
endpoint=""
method="GET"
body_json=""
shift
while (( \$# > 0 )); do
    case "\$1" in
        --input)  body_json=\$(cat); shift 2 ;;
        -X)       method="\$2"; shift 2 ;;
        -H|-f)    shift 2 ;;
        --)       shift; break ;;
        /*)       endpoint="\$1"; shift ;;
        *)        shift ;;
    esac
done
if ! [ -t 0 ]; then cat >/dev/null 2>&1 || true; fi
_bump() {
    n=\$(( \$( cat "$COMMENT_SEQ" 2>/dev/null || echo 0 ) + 1 ))
    printf '%s' "\$n" > "$COMMENT_SEQ"
    printf '2026-07-15T12:00:%02dZ' "\$n"
}
case "\$endpoint" in
    */issues/comments/*/reactions)
        if [[ "\${MOCK_ROCKET_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock reactions POST 422"}' >&2; exit 1
        fi
        printf '{"id":99999,"content":"rocket"}' ;;
    */issues/comments/*)
        if [[ ! -f "$COMMENT_STORE" ]]; then
            echo '{"message":"Not Found"}' >&2; exit 1
        fi
        if [[ "\$method" == "PATCH" ]]; then
            new_body=\$(jq -r '.body' <<<"\$body_json")
            ts=\$(_bump)
            jq --arg b "\$new_body" --arg t "\$ts" \\
               '.body=\$b | .updated_at=\$t' "$COMMENT_STORE" > "$COMMENT_STORE.tmp" \\
               && mv "$COMMENT_STORE.tmp" "$COMMENT_STORE"
        elif [[ "\${MOCK_COMMENT_MOVING:-0}" == "1" ]]; then
            ts=\$(_bump)
            jq --arg t "\$ts" '.updated_at=\$t' "$COMMENT_STORE" > "$COMMENT_STORE.tmp" \\
                && mv "$COMMENT_STORE.tmp" "$COMMENT_STORE"
        fi
        jq '. + {html_url:"https://mock.example/issuecomment-1234"}' "$COMMENT_STORE" ;;
    */issues/*/comments)
        if [[ "\${MOCK_COMMENT_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock comment POST 422"}' >&2; exit 1
        fi
        posted=\$(jq -r '.body' <<<"\$body_json")
        jq -n --arg b "\$posted" --arg t "2026-07-15T12:00:00Z" \\
            '{body:\$b, updated_at:\$t}' > "$COMMENT_STORE"
        printf '{"html_url":"https://mock.example/issuecomment-1234"}' ;;
    *) printf '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

comment_store_body() { jq -r '.body' "$COMMENT_STORE" 2>/dev/null; }

# ---- Test 31: post-once idempotency — a clean re-run does not duplicate
#      the link comment (B15 / your-nexus#236) and, post-#524, re-points
#      it at the fresh upload instead of silently REUSING the stale link.
#      State (the action-log) persists across run_ng; only reset_mocks
#      wipes it, so the two runs below share the log the guard reads. ----
echo '=== post-once: re-running wrap-up updates the prior comment, no duplicate POST ==='
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq       "first wrap-up exits 0"               "$rc" "0"
assert_contains "first run posts the comment"         "$stdout" \
                "posted comment: https://mock.example/issuecomment-1234"
gh_calls=$(<"$GH_CAPTURE")
assert_contains "first run POSTs to the comments endpoint" "$gh_calls" \
                "/repos/override-org/override-repo/issues/42/comments"
# Second wrap-up for the SAME issue+report+repo. Must NOT re-POST.
# (Same MOCK_UPLOAD_SHA → the link already points at this blob → the
# re-point is a no-op UPDATE, still reported as such.)
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq       "re-run exits 0"                      "$rc" "0"
assert_contains "re-run updates (not blind-reuses) the prior comment" "$stdout" \
                "posted comment: UPDATED https://mock.example/issuecomment-1234"
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "re-run does NOT POST a duplicate comment" "$gh_calls" \
                    "/repos/override-org/override-repo/issues/42/comments"

# ---- Test 32: the cailin scenario — a partial failure (rocket) makes the
#      worker re-run the WHOLE verb (the only retry surface); the comment
#      must not double-post while the rocket DOES get re-attempted. -------
echo '=== post-once: retry after a rocket failure does not duplicate the comment ==='
reset_mocks
export MOCK_ROCKET_FAIL=1
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
assert_eq       "partial-failure run exits 1"         "$rc" "1"
assert_contains "first run posted the comment"        "$stdout" \
                "posted comment: https://mock.example/issuecomment-1234"
assert_contains "first run's rocket FAILED"           "$stdout" \
                "rocketed comment 7777: FAILED"
gh_calls=$(<"$GH_CAPTURE")
assert_contains "first run POSTs the comment"         "$gh_calls" \
                "/issues/42/comments"
unset MOCK_ROCKET_FAIL
# Worker retries the whole verb. Rocket now succeeds. The re-uploaded
# blob keeps the same mock SHA, so the link comment needs no PATCH —
# but the retry must still go through the post-once UPDATE path, not
# a blind reuse.
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --trigger-comment 7777 --repo override-org/override-repo
assert_eq       "retry exits 0"                       "$rc" "0"
assert_contains "retry updates the prior comment"     "$stdout" \
                "posted comment: UPDATED"
assert_contains "retry rockets successfully"          "$stdout" \
                "rocketed comment 7777"
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "retry does NOT duplicate the comment" "$gh_calls" \
                    "/issues/42/comments"
assert_contains "retry DID re-attempt the rocket"     "$gh_calls" \
                "/issues/comments/7777/reactions"

# ---- Test 33: the guard is scoped to (issue, report, repo) — a DIFFERENT
#      report under the same issue still posts a fresh comment. Guards
#      against an over-broad dedup that would swallow legitimate posts. --
echo '=== post-once is per-report: a different report still posts fresh ==='
REPORT2="$FAKE_NEXUS/reports/nexus_2026-05-11_090000_second-task.md"
write_report "$REPORT2"
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq       "first report wrap-up exits 0"        "$rc" "0"
run_ng stdout stderr rc wrap-up 42 "$REPORT2" --repo override-org/override-repo
assert_eq       "second report wrap-up exits 0"       "$rc" "0"
assert_contains "second report posts a fresh comment" "$stdout" \
                "posted comment: https://mock.example/issuecomment-1234"
gh_calls=$(<"$GH_CAPTURE")
assert_contains "second report DID POST (not deduped)" "$gh_calls" \
                "/issues/42/comments"

# ---- Test 34 (LOAD-BEARING, #524 defect 2): a re-wrap after correcting
#      the report re-uploads to a NEW blob; the post-once path must
#      re-point the existing link comment's asset URL at that new blob.
#      Pre-#524 behaviour: print "REUSED", never touch the comment —
#      the thread keeps linking the PRE-correction report while the
#      verb reports success (the #523 incident). RED on old code:
#      the UPDATED line is absent and the stored comment still carries
#      the stale SHA. -----------------------------------------------------
echo '=== re-wrap after correction → link comment PATCHed to the NEW blob ==='
reset_mocks
export MOCK_UPLOAD_SHA="aaaa1111beforefix"
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq       "first wrap-up exits 0"                "$rc" "0"
assert_contains "link comment stores the v1 blob URL"  "$(comment_store_body)" \
                "https://github.com/asset-org/assets/raw/aaaa1111beforefix/assets/42/$(basename "$REPORT")"
# The report gets materially corrected; the worker re-wraps. The upload
# step mints a NEW sha for the corrected content.
export MOCK_UPLOAD_SHA="bbbb2222corrected"
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
unset MOCK_UPLOAD_SHA
assert_eq       "re-wrap exits 0"                      "$rc" "0"
assert_contains "stdout reports the UPDATED link comment" "$stdout" \
                "posted comment: UPDATED https://mock.example/issuecomment-1234"
store_body=$(comment_store_body)
assert_contains "link comment NOW points at the corrected blob" "$store_body" \
                "https://github.com/asset-org/assets/raw/bbbb2222corrected/assets/42/$(basename "$REPORT")"
assert_not_contains "STALE blob URL is gone from the link comment" "$store_body" \
                    "aaaa1111beforefix"
gh_calls=$(<"$GH_CAPTURE")
assert_contains "re-point went through PATCH on the comment" "$gh_calls" \
                "-X PATCH /repos/override-org/override-repo/issues/comments/1234"
assert_not_contains "no duplicate link comment POSTed"  "$gh_calls" \
                    "/issues/42/comments"
# The action log records the update so a THIRD wrap-up keys off it.
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_lines=$(<"$LOG_FILE")
assert_contains "log records comment=updated on the re-wrap" "$log_lines" \
                '"comment":"updated"'

# ---- Test 35: re-point under sustained concurrent edits → the CAS
#      refuses and the wrap-up FAILS LOUDLY instead of clobbering
#      (defect 1's fail-loud contract, exercised through the defect-2
#      path that now depends on it). --------------------------------------
echo '=== re-wrap while the comment keeps moving → loud failure, no clobber ==='
reset_mocks
export MOCK_UPLOAD_SHA="cccc3333firstpass"
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq       "first wrap-up exits 0"                "$rc" "0"
export MOCK_UPLOAD_SHA="dddd4444secondpass"
export MOCK_COMMENT_MOVING=1
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
unset MOCK_COMMENT_MOVING MOCK_UPLOAD_SHA
assert_eq       "re-wrap exits 1 when the comment keeps moving" "$rc" "1"
assert_contains "stdout reports the comment step FAILED" "$stdout" \
                "posted comment: FAILED"
assert_contains "stderr names the re-point failure"     "$stderr" \
                "re-point of prior link comment"
store_body=$(comment_store_body)
assert_contains "contended comment NOT clobbered (v1 link intact)" "$store_body" \
                "cccc3333firstpass"
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "no PATCH landed on the moving comment" "$gh_calls" \
                    "-X PATCH /repos/override-org/override-repo/issues/comments/1234"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
