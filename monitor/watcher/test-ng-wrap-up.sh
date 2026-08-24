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
# Libraries `ng` SOURCES. It sources these unconditionally and dies when
# they are missing, deliberately — the behaviour they replace was silent
# coercion (your-org/nexus-code#601/#605) and a fallback would reinstate
# exactly that. So a fixture copying `ng` alone yields an `ng` that
# cannot start at all.
cp "$(dirname "$NG_REAL")/_bookkeeping.sh" "$FAKE_NEXUS/monitor/_bookkeeping.sh"
NG="$FAKE_NEXUS/monitor/ng"
STATE_DIR="$FAKE_NEXUS/monitor/.state"

# The spawn-skeptic request-filing step (your-org/nexus-code#545) shells out
# to $_script_dir/request-channel.sh (+ its libs). Provide the REAL scripts
# in the fake monitor dir so cmd_wrap_up can file a request into $STATE_DIR.
for _dep in request-channel.sh _channel_lib.sh _fm_lib.sh; do
    cp "$_test_dir/../$_dep" "$FAKE_NEXUS/monitor/$_dep"
done
chmod +x "$FAKE_NEXUS/monitor/request-channel.sh"

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
# your-org/nexus-code#771 — the live-skeptic detector enumerates windows as
# \`<session>:<index> <name>\` rows. Default: just the wrap-up's own window,
# which is the truthful baseline (a wrap-up always runs inside one), so the
# ordinary case resolves to a real \`no\` rather than "could not look".
if [[ "\${1:-}" == "list-windows" ]]; then
    # MOCK_TMUX_BLIND=1 → the probe FAILS (no output). A distinct toggle,
    # not \`MOCK_TMUX_WINDOW_ROWS=""\`: an empty value would take the \`:-\`
    # default below and silently give the fixture a window list, so the
    # "could not look" case would test the "looked and found nothing" path
    # instead — the very conflation #771 is about.
    [[ "\${MOCK_TMUX_BLIND:-0}" == "1" ]] && exit 0
    printf '%s\\n' "\${MOCK_TMUX_WINDOW_ROWS:-0:1 \${MOCK_TMUX_WINDOW:-wrapup-worker}}"
    exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

# Stubbed pane-state.sh inside the fake monitor dir. #771's detector queries
# it BY INDEX (it is index-keyed; a window NAME returns nothing at all — the
# Step-5b defect). MOCK_PANE_STATE maps `<index>=<state>` pairs, whitespace
# separated; an index with no entry is left unclassified so the
# "could-not-classify" branch is reachable.
cat > "$FAKE_NEXUS/monitor/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
idx="${1:-}"
# The real script accepts `<index>` or `<session>:<window>`; the detector
# passes the qualified form. Normalise to the bare index.
idx="${idx##*:}"
for pair in ${MOCK_PANE_STATE:-}; do
    if [[ "${pair%%=*}" == "$idx" ]]; then
        printf 'state=%s active=0 window=%s name=stub\n' "${pair#*=}" "$idx"
        exit 0
    fi
done
exit 3
STUB
chmod +x "$FAKE_NEXUS/monitor/pane-state.sh"

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
# NEXUS_WORKER_WINDOW is unset on BOTH branches deliberately. It is exported
# into every spawned worker's environment, and `ng` keys its operator-vs-worker
# guards on exactly that variable (`--skeptic-waive`, `ng skeptic resolve`,
# `report-init`). Left inherited, this suite's verdict depends on WHERE it was
# run from: green in an orchestrator session, and a different code path — the
# refuse-the-operator-override arm — inside any worker window, including CI-like
# harnesses that export it. The suite asserts ORCHESTRATOR-side behaviour, so it
# must state that rather than inherit it. (test-skeptic-channel.sh already
# unsets it explicitly for the same reason; this one did not.)
run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    : > "$GH_CAPTURE"
    : > "$UPLOAD_CAPTURE"
    if [[ "${MOCK_TMUX:-0}" == "1" ]]; then
        # MOCK_TMUX branch deliberately sets TMUX/TMUX_PANE — we are
        # testing the tmux-context code path, so they must be present.
        env -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME -u NEXUS_WORKER_WINDOW \
            NEXUS_STATE_DIR="$STATE_DIR" \
            MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=0 \
            TMUX="${MOCK_TMUX_SOCKET:-/tmp/fake-tmux-sock}" \
            TMUX_PANE="${MOCK_TMUX_PANE:-%42}" \
            PATH="$STUB_DIR:${SK825_PATH:-$PATH}" \
            TMPDIR="${SK825_TMPDIR:-${TMPDIR:-/tmp}}" \
            "$NG" "$@" >"$_out_tmp" 2>"$_err_tmp"
    else
        env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
            -u NEXUS_WORKER_WINDOW \
            NEXUS_STATE_DIR="$STATE_DIR" \
            MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=0 \
            PATH="$STUB_DIR:${SK825_PATH:-$PATH}" \
            TMPDIR="${SK825_TMPDIR:-${TMPDIR:-/tmp}}" \
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
    # #771 — the live-skeptic fixtures. `rm -rf $STATE_DIR` below already
    # drops the provenance records; these two must be cleared explicitly or
    # a window list leaks into the next case and makes it pass for the
    # wrong reason.
    unset MOCK_TMUX_WINDOW_ROWS MOCK_PANE_STATE MOCK_TMUX_BLIND
    rm -rf "$STATE_DIR"
    rm -f "$COMMENT_STORE" "$COMMENT_SEQ"
}

# #771 — write a spawn provenance record, the shape `spawn-worker.sh
# --skeptic-role` writes. This is where a skeptic window is IDENTIFIED;
# the `<target>-skeptic` name never was more than a proxy for it.
write_skeptic_record() {
    local window="$1" target="$2"
    mkdir -p "$STATE_DIR/windows"
    cat > "$STATE_DIR/windows/${window}.json" <<EOF
{
  "window": "$window",
  "session_id": "24d84a4b-606a-41c3-a5a0-957958abe53a",
  "kind": "task",
  "spawned_by": "orchestrator",
  "workdir": "/tmp/clone",
  "prompt_file": "/tmp/p-${window}.md",
  "topic": "$window",
  "spawned_at": "2026-08-07T05:45:35-07:00",
  "skeptic_mode": "auto",
  "skeptic_depth": 1,
  "skeptic_role": true,
  "skeptic_target": "$target",
  "skeptic_orig": "$target",
  "reply_to": ""
}
EOF
}

# The `live-skeptic-window:` value from the filed request body.
# No `| head -1`: that is an early-exit reader, and this repo tracks the
# population of those in `early-exit-readers.manifest` (#622/#682). Take the
# first line with parameter expansion instead — same answer, no pipe.
live_skeptic_field() {
    local all
    all=$(sed -n 's/^live-skeptic-window: //p' <<<"$(spawn_req_body)")
    printf '%s' "${all%%$'\n'*}"
}

# The field's VERDICT — its first token. Asserting on this rather than on a
# substring matters: the pre-fix field was the bare word `no`, so
# `assert_not_contains "$F" "no ("` passed against it VACUOUSLY, for the
# absence of a parenthetical rather than for the absence of the verdict.
# A regression assertion that passes on the pre-fix code is not one.
live_skeptic_verdict() {
    local f; f=$(live_skeptic_field)
    printf '%s' "${f%%[ :]*}"
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
assert_contains "re-run re-points (not blind-reuses) the prior comment" "$stdout" \
                "posted comment: unchanged https://mock.example/issuecomment-1234"
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "re-run does NOT POST a duplicate comment" "$gh_calls" \
                    "/repos/override-org/override-repo/issues/42/comments"

# ---- Test 32: the other-nexus scenario — a partial failure (rocket) makes the
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
assert_contains "retry reports the prior comment as unchanged"     "$stdout" \
                "posted comment: unchanged"
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
assert_contains "stdout reports the re-pointed link comment as unchanged" "$stdout" \
                "posted comment: unchanged https://mock.example/issuecomment-1234"
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

# ---- Test 40+: spawn-skeptic request filing (your-org/nexus-code#545) ----
# A require resolution files a `kind=spawn-skeptic` request into the
# watcher-mediated inbox (Step 2b), carrying pointers; a clean first-pass
# require is auto-spawnable (deliberate=false); --skeptic-contradicted flips
# it to deliberate=true; a deny/undecided resolution files NOTHING; and a
# retry is idempotent (no duplicate request).
REQ_DIR="$STATE_DIR/requests"
count_spawn_reqs() {  # non-terminal spawn-skeptic requests currently in the inbox
    shopt -s nullglob
    local -a f=("$REQ_DIR"/*spawn*skeptic*.new.md "$REQ_DIR"/*-skeptic-d*.new.md \
                "$REQ_DIR"/*-skeptic-d*.claimed.md)
    shopt -u nullglob
    printf '%s' "${#f[@]}"
}
spawn_req_body() {  # concatenated body of every filed spawn-skeptic request
    shopt -s nullglob
    local -a f=("$REQ_DIR"/*-skeptic-d*.md)
    shopt -u nullglob
    (( ${#f[@]} > 0 )) && cat "${f[@]}" 2>/dev/null
}

echo '=== spawn-skeptic: a first-pass require FILES the request with pointers ==='
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-req-worker"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --trigger-comment 4242 \
    --skeptic-decision require --skeptic-rationale "touched shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq       "require wrap-up exits 0"                  "$rc" "0"
assert_contains "stdout reports the filed spawn-skeptic request" "$stdout" \
                "spawn-skeptic request: filed "
assert_eq       "exactly one spawn-skeptic request filed"  "$(count_spawn_reqs)" "1"
body=$(spawn_req_body)
assert_contains "request frontmatter carries kind=spawn-skeptic" "$body" \
                "kind: spawn-skeptic"
assert_contains "request origin is the worker window"      "$body" \
                "origin: sk-req-worker"
assert_contains "body carries the issue pointer"           "$body" \
                "issue: override-org/override-repo#77"
assert_contains "body carries the trigger-comment pointer" "$body" \
                "trigger-comment: 4242"
assert_contains "body carries the report asset URL"        "$body" \
                "report-asset-url: https://github.com/asset-org/"
assert_contains "body carries the target window"           "$body" \
                "target-window: sk-req-worker"
assert_contains "body carries depth 1"                     "$body" \
                "depth: 1"
assert_contains "clean first pass is NOT deliberate"       "$body" \
                "deliberate: false"
# your-org/nexus-code#599 — the request must carry the two facts the
# orchestrator previously had to reconstruct by hand from tmux and from
# reading the report, once per duplicate adjudication.
assert_contains "#599 body reports whether a live skeptic window exists" "$body" \
                "live-skeptic-window:"
assert_contains "#599 body reports the report's own stated disposition" "$body" \
                "report-stated-disposition:"
# A report that states nothing must say so, NOT have a disposition
# guessed for it — and the recommendation must admit that a
# count-derived value is severity-blind rather than presenting itself as
# a conclusion.
# your-org/nexus-code#684 — this used to read `-`, the SAME sentinel the
# request carried when the parser had FAILED to read a disposition that was
# there. The orchestrator could not tell the two apart, and one of them means
# "go read the report's disposition line" while the other means "the author
# had no view". The state is now named, and the source with it.
assert_contains "#684 a report stating no disposition is reported as ABSENT, not as a bare dash" "$body" \
                "report-stated-disposition: absent"
assert_contains "#684 …and the request says where that answer came from" "$body" \
                "source: none"
assert_contains "#599 the derived recommendation flags its own blindness" "$body" \
                "severity-blind"

echo '=== #599: a report stating no-further-pass makes the recommendation DISPUTED ==='
reset_mocks
DISP_REPORT="$FAKE_NEXUS/reports/nexus_2026-05-11_091500_disposition.md"
write_report "$DISP_REPORT"
printf '\nDisposition: no-further-pass\n' >> "$DISP_REPORT"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-disp-worker"
run_ng stdout stderr rc wrap-up 77 "$DISP_REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq       "#599 disposition wrap-up exits 0"         "$rc" "0"
body=$(spawn_req_body)
assert_contains "#599 the stated disposition is READ, not ignored"  "$body" \
                "report-stated-disposition: no-further-pass"
assert_contains "#599 derived-vs-stated disagreement is loud (DISPUTED)" "$body" \
                "recommendation: DISPUTED"
# NEGATIVE CONTROL — the request is still FILED. Refusing to file on a
# disagreement would silently drop a request the orchestrator has to
# adjudicate, trading one silent failure for another.
assert_eq       "#599 CONTROL: a DISPUTED recommendation still FILES the request" \
                "$(count_spawn_reqs)" "1"

echo '=== spawn-skeptic: --skeptic-contradicted → deliberate=true ==='
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-contra-worker"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra" \
    --skeptic-contradicted "overrode the skeptic's retry-loop suggestion"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq       "contradicted require exits 0"             "$rc" "0"
body=$(spawn_req_body)
assert_contains "contradiction flags deliberate=true"      "$body" \
                "deliberate: true"
assert_contains "reasons name the contradiction"           "$body" \
                "worker-contradiction"
assert_contains "the contradiction text rides the body"    "$body" \
                "overrode the skeptic's retry-loop suggestion"

# ---- your-org/nexus-code#815: a RESOLVED require-gate is not re-armed -----
#
# The loop this closes: an orchestrator runs `ng skeptic resolve` (removing
# the marker, appending a rationale beside it), then tells the worker "write
# your remaining findings into a report and wrap up". The worker complies —
# and the require path re-armed the marker unconditionally, so the window
# RE-BLOCKED ITSELF BY COMPLYING and could not record even that fact without
# doing it again.
#
# The resolution state is produced by the REAL `ng skeptic resolve` here, not
# hand-written. The fix keys on an exact filename (`.<safe>.cleared-rationale`)
# owned by a DIFFERENT script; a fixture that writes that name itself would
# keep passing after a rename on the producing side, which is the coupling
# that actually matters.
cp "$_test_dir/../skeptic-channel.sh" "$FAKE_NEXUS/monitor/skeptic-channel.sh"
chmod +x "$FAKE_NEXUS/monitor/skeptic-channel.sh"
SK_PENDING="$STATE_DIR/skeptic/pending"

echo '=== #815: CONTROL — a first-pass require ARMS the marker ==='
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk815"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched shared infra"
assert_eq       "#815 CONTROL: require wrap-up exits 0"   "$rc" "0"
assert_file_exists "#815 CONTROL: marker armed" "$SK_PENDING/sk815"
assert_eq       "#815 CONTROL: one spawn-skeptic request filed" \
                "$(count_spawn_reqs)" "1"

echo '=== #815: the orchestrator resolves the marker (real ng skeptic resolve) ==='
run_ng stdout stderr rc skeptic resolve sk815 \
    --reason "verdict landed in the secondary clone's state dir; see reports/…-skeptic.md"
assert_eq  "#815 resolve exits 0" "$rc" "0"
if [[ -e "$SK_PENDING/sk815" ]]; then
    printf '  FAIL: #815 resolve did not remove the marker\n' >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: #815 resolve removed the marker\n'; PASS=$(( PASS + 1 ))
fi
assert_file_exists "#815 resolve wrote the rationale record beside it" \
                "$SK_PENDING/.sk815.cleared-rationale"

echo '=== #815: THE LOOP — a wrap-up after the resolve does NOT re-arm ==='
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --no-comment --skeptic-decision require --skeptic-rationale "touched shared infra"
assert_eq       "#815 post-resolve wrap-up still exits 0" "$rc" "0"
# The load-bearing assertion: the marker must STILL be gone.
if [[ -e "$SK_PENDING/sk815" ]]; then
    printf '  FAIL: #815 wrap-up RE-ARMED a resolved marker (the loop)\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: #815 wrap-up left the resolved marker cleared\n'
    PASS=$(( PASS + 1 ))
fi
assert_eq       "#815 no NEW spawn-skeptic request filed" \
                "$(count_spawn_reqs)" "1"
# The count alone is a WEAK assertion — Step 2b is idempotent, so it reads
# `1` whether the request-filing step ran and de-duplicated or never ran at
# all. Assert the step did not run: suppression must stop the PUSH signal to
# the orchestrator, not merely avoid a duplicate file on disk.
assert_not_contains "#815 the spawn-skeptic request step did not run at all" \
                "$stdout" "spawn-skeptic request:"
assert_contains "#815 the suppression is LOUD, not silent" "$stdout" \
                "REQUIRE GATE ALREADY RESOLVED"
assert_contains "#815 stdout names the deliberate re-arm escape hatch" "$stdout" \
                "--skeptic-rearm"
assert_contains "#815 the suppression is logged" \
                "$(cat "$STATE_DIR/action-log.jsonl" 2>/dev/null)" \
                "skeptic-rearm-suppressed"
# Incidental defect from the same issue: `--no-comment` used to print
# `SKIPPED (upload failed)` on a run whose upload plainly succeeded.
assert_contains "#815 --no-comment reports the ACTUAL reason" "$stdout" \
                "posted comment: SKIPPED (--no-comment)"
assert_not_contains "#815 …and does not assert a nonexistent upload failure" \
                "$stdout" "SKIPPED (upload failed)"
assert_contains "#815 CONTROL: the upload really did succeed on that run" \
                "$stdout" "uploaded: https://github.com/asset-org/"

echo '=== #815: NEGATIVE CONTROL — --skeptic-rearm DOES re-arm, on the record ==='
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched shared infra" \
    --skeptic-rearm "rewrote the merge gate after the resolution; new surface unvalidated"
assert_eq       "#815 deliberate re-arm exits 0"          "$rc" "0"
assert_file_exists "#815 deliberate re-arm ARMS the marker" "$SK_PENDING/sk815"
assert_contains "#815 deliberate re-arm says so"          "$stdout" \
                "DELIBERATE RE-ARM"
assert_contains "#815 deliberate re-arm is logged with its reason" \
                "$(cat "$STATE_DIR/action-log.jsonl" 2>/dev/null)" \
                "rewrote the merge gate after the resolution"

echo '=== #815: --skeptic-rearm must be substantive, not a keystroke ==='
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra" \
    --skeptic-rearm "changed"
assert_eq       "#815 a one-word re-arm reason is refused" "$rc" "1"
assert_contains "#815 …and says why"                       "$stderr" \
                "must be a substantive explanation"

echo '=== #815: NEGATIVE CONTROL — a window with NO resolution record arms ==='
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk815-clean"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched shared infra"
assert_eq       "#815 CONTROL: clean window exits 0"       "$rc" "0"
assert_file_exists "#815 CONTROL: clean window still ARMS" "$SK_PENDING/sk815-clean"
assert_not_contains "#815 CONTROL: no suppression banner on a clean window" \
                "$stdout" "ALREADY RESOLVED"

echo '=== #815 F6: a resolution SUPERSEDED by a later verdict is not sticky ==='
# Skeptic finding F6. `.cleared-rationale` is append-only and never removed, and
# marker-absence is ALSO the normal terminal state of a healthy round (the
# skeptic-role path rm -f's the marker on a verdict). Without a recency test,
# a window resolved ONCE could never arm a require-gate again for the rest of
# that NAME's life — `require` silently degrading to advisory — and the banner
# asserted an orchestrator action that never happened. Window names are recycled
# in this workspace, so the state outlives the window it described.
reset_state
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk815-f6"
mkdir -p "$SK_PENDING" "$STATE_DIR"
printf 'resolved long ago\n' > "$SK_PENDING/.sk815-f6.cleared-rationale"
touch -d '@1000000000' "$SK_PENDING/.sk815-f6.cleared-rationale"
# A skeptic verdict recorded AFTER that resolution — this is what clears the
# marker in a healthy round, and no orchestrator was involved.
printf '{"ts":"%s","agent":"monitor","event":"skeptic-verdict","window":"sk815-f6-skeptic","target-window":"sk815-f6","orig-window":"sk815-f6","verdict":"credible"}\n' \
    "$(date -Is -d '@1000001000')" > "$STATE_DIR/action-log.jsonl"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "new round after the verdict"
assert_eq       "#815 F6 superseded-resolution wrap-up exits 0" "$rc" "0"
assert_file_exists "#815 F6 a superseded resolution does NOT suppress the re-arm" \
                "$SK_PENDING/sk815-f6"
assert_not_contains "#815 F6 …and no suppression banner is printed" \
                "$stdout" "ALREADY RESOLVED"
# CONTROL: the SAME rationale with NO later chain event still suppresses, so
# F6's fix narrows the state rather than deleting it.
reset_state
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk815-f6b"
mkdir -p "$SK_PENDING"
printf 'resolved long ago\n' > "$SK_PENDING/.sk815-f6b.cleared-rationale"
touch -d '@1000000000' "$SK_PENDING/.sk815-f6b.cleared-rationale"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "no chain event since the resolve"
assert_eq       "#815 F6 CONTROL: unsuperseded resolution still suppresses" "$rc" "0"
assert_contains "#815 F6 CONTROL: …with the banner"  "$stdout" "ALREADY RESOLVED"

# ══ your-org/nexus-code#825: the chain-event probe must FAIL CLOSED ════════
#
# `_skeptic_last_chain_event_epoch` returned 0 on three could-not-determine
# paths — jq missing, action log unreadable, `date -d` failed — and 0 falls
# through to `resolved`, which SUPPRESSES the require-gate. So the probe FAILING
# had the same effect as a positive finding that an orchestrator resolved the
# gate: the exact collapse `_skeptic_resolution_state`'s own header rules out
# for its sibling `unknown` state, reintroduced one level down and in the
# suppressing direction.
#
# For THIS gate the fail-safe direction is to ARM (the act being gated is arming
# validation, so doubt must not reduce it) and to say so loudly. Each mutant
# below breaks one probe dependency and asserts the gate HOLDS.
sk825_fixture() {   # sk825_fixture <window> — old resolution + a later verdict
    local w="$1"
    mkdir -p "$SK_PENDING" "$STATE_DIR"
    printf 'resolved long ago\n' > "$SK_PENDING/.${w}.cleared-rationale"
    touch -d '@1000000000' "$SK_PENDING/.${w}.cleared-rationale"
    printf '{"ts":"%s","agent":"monitor","event":"skeptic-verdict","window":"%s-skeptic","target-window":"%s","orig-window":"%s","verdict":"credible"}\n' \
        "$(date -Is -d '@1000001000')" "$w" "$w" "$w" > "$STATE_DIR/action-log.jsonl"
}

echo '=== #825 CONTROL: with a working probe the superseded case still arms ==='
reset_state
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk825-ok"
sk825_fixture sk825-ok
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "working probe control"
assert_file_exists "#825 CONTROL: working probe arms the gate" "$SK_PENDING/sk825-ok"

echo '=== #825 M1: jq unavailable → gate must HOLD, not be suppressed ==='
reset_state
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk825-nojq"
sk825_fixture sk825-nojq
# A PATH with no `jq`. `ng` itself does not need jq to reach this path.
NOJQ_BIN="$WORK/nojq"; mkdir -p "$NOJQ_BIN"
for _t in bash sh env grep sed awk date stat mkdir rm cat tr head tail sort cut find touch printf git mktemp dirname basename readlink chmod wc uniq; do
    _src=$(command -v "$_t" 2>/dev/null) && ln -sf "$_src" "$NOJQ_BIN/$_t" 2>/dev/null
done
SK825_PATH="$NOJQ_BIN" run_ng stdout stderr rc wrap-up 77 "$REPORT" \
    --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "jq-missing mutant"
assert_file_exists "#825 M1 jq missing → the gate is ARMED, not suppressed" \
                "$SK_PENDING/sk825-nojq"
assert_not_contains "#825 M1 …and it is not reported as a resolution" \
                "$stdout" "ALREADY RESOLVED"

echo '=== #825 M2: action log unreadable → gate must HOLD ==='
reset_state
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk825-nolog"
sk825_fixture sk825-nolog
chmod 000 "$STATE_DIR/action-log.jsonl"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "unreadable-log mutant"
chmod 644 "$STATE_DIR/action-log.jsonl" 2>/dev/null || true
assert_file_exists "#825 M2 unreadable log → the gate is ARMED, not suppressed" \
                "$SK_PENDING/sk825-nolog"
assert_not_contains "#825 M2 …and it is not reported as a resolution" \
                "$stdout" "ALREADY RESOLVED"

echo '=== #825 M3: an unparseable event ts (`date -d` fails) → gate must HOLD ==='
reset_state
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk825-badts"
sk825_fixture sk825-badts
printf '{"ts":"not-a-date-at-all","agent":"monitor","event":"skeptic-verdict","window":"x","target-window":"sk825-badts","orig-window":"sk825-badts","verdict":"credible"}\n' \
    > "$STATE_DIR/action-log.jsonl"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "bad-timestamp mutant"
assert_file_exists "#825 M3 unparseable ts → the gate is ARMED, not suppressed" \
                "$SK_PENDING/sk825-badts"
assert_not_contains "#825 M3 …and it is not reported as a resolution" \
                "$stdout" "ALREADY RESOLVED"

echo '=== #825 M5: a MISSING action log -> gate must HOLD (not a positive negative) ==='
# The finding my own #825 fix INTRODUCED, caught by the skeptic reading the
# JUSTIFICATION rather than the code: the first version answered `none` for a
# missing log, reasoning "nothing was ever recorded, so nothing can have
# superseded". That infers HISTORY from an ARTIFACT'S ABSENCE. A #577 forked
# state dir, or a cleared/re-rooted NEXUS_STATE_DIR, leaves the log absent while
# events did happen -- and `none` falls through to `resolved`, SUPPRESSING the
# gate. That is the #815 F6 fail-open, reinstated by the fix that closes it.
reset_state
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk825-nolog2"
sk825_fixture sk825-nolog2
rm -f "$STATE_DIR/action-log.jsonl"        # the log is simply not there
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "missing-log mutant"
assert_file_exists "#825 M5 missing log -> the gate is ARMED, not suppressed" \
                "$SK_PENDING/sk825-nolog2"
assert_not_contains "#825 M5 ...and a missing log is not read as a resolution" \
                "$stdout" "ALREADY RESOLVED"

echo '=== #825 M6: mktemp FAILS -> the jq-error probe is unavailable -> gate must HOLD ==='
# Found by self-grepping this fix for the rule it enforces. The jq stderr file
# is how `unknown` (parse error) is told from `none` (clean no-match). It read
# `|| jq_err=/dev/null`, and `[[ -s /dev/null ]]` is ALWAYS false -- so a failed
# mktemp made every jq parse error invisible and fell through to `none`, i.e.
# SUPPRESSED the gate. Failing to obtain the INSTRUMENT is itself a
# could-not-look. TMPDIR pointed at a non-existent dir makes mktemp fail.
reset_state
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk825-nomktemp"
sk825_fixture sk825-nomktemp
# The fixture's log must make jq ERROR, or this mutant is INERT: with a valid
# event jq succeeds, `ts` is non-empty, and the gate arms via the `event` arm
# for the right reason whether or not the fix is present. (Measured: the first
# draft of M6 passed against the reverted fix.) A line that matches the grep but
# is malformed JSON drives jq to stderr with no stdout -- which is precisely the
# case the jq_err file exists to distinguish from a clean no-match.
printf '{"event":"skeptic-verdict" THIS IS NOT JSON\n' > "$STATE_DIR/action-log.jsonl"
SK825_TMPDIR="$WORK/no-such-tmpdir-$$" run_ng stdout stderr rc wrap-up 77 "$REPORT" \
    --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "mktemp-fails mutant"
assert_file_exists "#825 M6 mktemp failure -> the gate is ARMED, not suppressed" \
                "$SK_PENDING/sk825-nomktemp"
assert_not_contains "#825 M6 ...and it is not reported as a resolution" \
                "$stdout" "ALREADY RESOLVED"

echo '=== #825 M7: grep FAILS (rc>=2) -> gate must HOLD, not read as no-match ==='
# The TWIN of M6's defect, sitting one line below it and missed by two review
# passes. grep exits 0 on match, 1 on no-match, >=2 on ERROR. Discarding the rc
# made a grep FAILURE indistinguishable from a clean no-match: both give empty
# `ts` -> `none 0` -> `resolved` -> gate SUPPRESSED. A DIRECTORY at the log path
# passes the `[[ -r ]]` check and makes grep exit 2 ('Is a directory').
reset_state
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk825-grepfail"
sk825_fixture sk825-grepfail
rm -f "$STATE_DIR/action-log.jsonl"
mkdir -p "$STATE_DIR/action-log.jsonl"   # readable, but grep rc=2 on it
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "grep-failure mutant"
rmdir "$STATE_DIR/action-log.jsonl" 2>/dev/null || true
assert_file_exists "#825 M7 grep failure -> the gate is ARMED, not suppressed" \
                "$SK_PENDING/sk825-grepfail"
assert_not_contains "#825 M7 ...and a grep ERROR is not read as a resolution" \
                "$stdout" "ALREADY RESOLVED"

echo '=== #825 M4: a RAW window name the log stores unsanitised ==='
# The second half: `$safe` is the marker-filename form, the log stores the raw
# tmux name. They differ for any name outside [A-Za-z0-9_-], the join finds
# nothing, and the miss lands in the same fail-open arm.
reset_state
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk825.dot"
mkdir -p "$SK_PENDING" "$STATE_DIR"
printf 'resolved long ago\n' > "$SK_PENDING/.sk825_dot.cleared-rationale"
touch -d '@1000000000' "$SK_PENDING/.sk825_dot.cleared-rationale"
printf '{"ts":"%s","agent":"monitor","event":"skeptic-verdict","window":"s","target-window":"sk825.dot","orig-window":"sk825.dot","verdict":"credible"}\n' \
    "$(date -Is -d '@1000001000')" > "$STATE_DIR/action-log.jsonl"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "raw-vs-sanitised join"
assert_file_exists "#825 M4 a RAW-named later verdict is seen → gate armed" \
                "$SK_PENDING/sk825_dot"
assert_not_contains "#825 M4 …and the stale resolution does not suppress it" \
                "$stdout" "ALREADY RESOLVED"

echo '=== #815: a marker NEWER than the resolution is a real new round → arms ==='
# spawn-worker.sh re-seeds pending/<target> when it ACTUALLY spawns the next
# skeptic. That marker post-dates the resolution, so the gate is live again
# and a wrap-up re-stamping it is a no-op — not a reversal.
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk815-round2"
mkdir -p "$SK_PENDING"
printf 'resolved earlier\n' > "$SK_PENDING/.sk815-round2.cleared-rationale"
touch -d '@1000000' "$SK_PENDING/.sk815-round2.cleared-rationale"
printf '2' > "$SK_PENDING/sk815-round2"          # re-seeded now ⇒ newer
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched shared infra"
assert_eq       "#815 re-armed round exits 0"              "$rc" "0"
assert_file_exists "#815 re-armed round keeps the live marker" \
                "$SK_PENDING/sk815-round2"
assert_not_contains "#815 a live newer marker is NOT treated as resolved" \
                "$stdout" "ALREADY RESOLVED"
assert_eq       "#815 …and the spawn-skeptic request is still filed" \
                "$(count_spawn_reqs)" "1"
unset MOCK_TMUX MOCK_TMUX_WINDOW

# ---- your-org/nexus-code#771: what makes a skeptic window "live" -----------
#
# The predecessor matched a NAMING CONVENTION — `grep -qxF
# "${target}-skeptic"` against `tmux list-windows`. Skeptic windows are not
# named that way: of 468 `skeptic_role: true` records on the reporting nexus,
# 198 (42%) carry a name the pattern cannot match. `fig4sk`, reviewing
# `fig4rev`, was one of them, and was invisible to this field from the moment
# it was spawned — not, as #771 hypothesised, from the moment it wrapped up.
#
# The cases below fix the definition in both directions. A window is live
# when the SPAWN RECORD says it reviews this target, a tmux window of that
# name exists NOW, and the pane does not positively assert a dead agent.
echo '=== #771: a re-pinned skeptic under a non-conventional name is VISIBLE ==='
reset_mocks
write_skeptic_record fig4sk fig4rev
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="fig4rev"
export MOCK_TMUX_WINDOW_ROWS=$'0:3 fig4rev\n0:5 fig4sk'
export MOCK_PANE_STATE="3=busy 5=idle"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "iterative round"
unset MOCK_TMUX MOCK_TMUX_WINDOW MOCK_TMUX_WINDOW_ROWS MOCK_PANE_STATE
assert_eq "re-pin wrap-up exits 0" "$rc" "0"
F=$(live_skeptic_field)
# THE REGRESSION. Pre-fix this read `no`, and the orchestrator acted on it:
# four duplicate spawn-skeptic requests in twelve minutes.
assert_eq "#771 a live skeptic named \`fig4sk\` for target \`fig4rev\` reads YES" \
          "$(live_skeptic_verdict)" "yes"
assert_contains "#771 …naming the window, so the reader can go look at it" "$F" "fig4sk"
assert_contains "#771 …and naming the action, which is re-pin, not spawn" "$F" "RE-PIN"
# `idle` is the WRAPPED-UP-AND-WAITING shape — precisely what #771 reports as
# mis-read. It is also `bk_pane_kill_authorized`'s allow arm, which is why
# that predicate must not be reused here with its polarity flipped.
assert_contains "#771 an IDLE skeptic is live (that IS the re-pinnable state)" \
                "$F" "state=idle"

echo '=== #771: genuinely no skeptic → a positive, evidenced `no` ==='
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="lonely-worker"
export MOCK_TMUX_WINDOW_ROWS="0:3 lonely-worker"
export MOCK_PANE_STATE="3=busy"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW MOCK_TMUX_WINDOW_ROWS MOCK_PANE_STATE
F=$(live_skeptic_field)
assert_contains "#771 no skeptic anywhere reads \`no\`" "$F" "no ("
assert_contains "#771 …and shows what it checked, not a bare verdict" "$F" "spawn record"

echo '=== #771: a STALE record whose window is gone is not a live skeptic ==='
# The opposite error. Provenance records are never pruned — 1059 of them on
# the reporting nexus, most long retired — so keying on them alone would
# answer "was there ever a skeptic", not "is one live".
reset_mocks
write_skeptic_record oldsk retired-worker
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="retired-worker"
export MOCK_TMUX_WINDOW_ROWS="0:3 retired-worker"
export MOCK_PANE_STATE="3=busy"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW MOCK_TMUX_WINDOW_ROWS MOCK_PANE_STATE
F=$(live_skeptic_field)
assert_contains "#771 a record without a live window is NOT reported live" "$F" "no ("

echo '=== #771: `empty` means "do not know yet", never "finished" ==='
# your-org/nexus-code#603. `empty` on a pane 4m38s into a verification pass
# is the documented false negative; reading it as "gone" here would
# reinstate the duplicate-spawn recommendation for a busy reviewer.
reset_mocks
write_skeptic_record fig4sk fig4rev
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="fig4rev"
export MOCK_TMUX_WINDOW_ROWS=$'0:3 fig4rev\n0:5 fig4sk'
export MOCK_PANE_STATE="3=busy 5=empty"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW MOCK_TMUX_WINDOW_ROWS MOCK_PANE_STATE
assert_eq "#771 \`empty\` does not demote a skeptic to gone" \
          "$(live_skeptic_verdict)" "yes"

echo '=== #771: a state nobody enumerated defaults to ALIVE ==='
# The 2026-06-15 shape, inverted. A denylist of "gone" states with a
# permissive default arm mishandles whatever its author did not think of;
# there are twelve pane states today and pane-state.sh keeps gaining them.
reset_mocks
write_skeptic_record fig4sk fig4rev
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="fig4rev"
export MOCK_TMUX_WINDOW_ROWS=$'0:3 fig4rev\n0:5 fig4sk'
export MOCK_PANE_STATE="3=busy 5=some-state-invented-in-2027"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW MOCK_TMUX_WINDOW_ROWS MOCK_PANE_STATE
assert_eq "#771 an unrecognised pane state resolves to live, not gone" \
          "$(live_skeptic_verdict)" "yes"

echo '=== #771: `absent` is the one state that asserts a dead agent ==='
reset_mocks
write_skeptic_record fig4sk fig4rev
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="fig4rev"
export MOCK_TMUX_WINDOW_ROWS=$'0:3 fig4rev\n0:5 fig4sk'
export MOCK_PANE_STATE="3=busy 5=absent"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW MOCK_TMUX_WINDOW_ROWS MOCK_PANE_STATE
F=$(live_skeptic_field)
assert_contains "#771 an \`absent\` pane is reported as nothing to re-pin" "$F" "no ("
assert_contains "#771 …saying so explicitly rather than as a bare \`no\`" "$F" "DEAD agent"

echo '=== #771: "could not look" is its own answer, not `no` ==='
# The silence-reads-as-absence class #771 names. An empty window list means
# the probe failed — this wrap-up is itself running in a tmux window.
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="blind-worker" MOCK_TMUX_BLIND=1
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW MOCK_TMUX_BLIND
V=$(live_skeptic_verdict)
assert_eq "#771 a blind probe reports \`unknown\`" "$V" "unknown"
assert_eq "#771 …and never launders itself into \`no\` (verdict token, not substring)" \
          "$([[ "$V" == "no" ]] && echo laundered || echo distinct)" "distinct"

echo '=== #771: a MALFORMED record truncates the scan → `unknown`, not `no` ==='
# The rule this fix names, applied to the fix. One `jq` over all records is
# cheap, but a single unparseable file aborts the batch: jq exits non-zero
# having emitted only what it reached, and with stderr suppressed the
# truncation is invisible. A confident `no` on a partial enumeration is
# #771's defect one layer down.
reset_mocks
write_skeptic_record goodsk some-other-target
mkdir -p "$STATE_DIR/windows"
printf '{"window": "broken", "skeptic_role": tru' > "$STATE_DIR/windows/broken.json"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="fig4rev"
export MOCK_TMUX_WINDOW_ROWS="0:3 fig4rev"
export MOCK_PANE_STATE="3=busy"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW MOCK_TMUX_WINDOW_ROWS MOCK_PANE_STATE
V=$(live_skeptic_verdict)
assert_eq "#771 an unreadable record makes the verdict \`unknown\`" "$V" "unknown"
assert_contains "#771 …and says the scan was truncated, not that nothing is there" \
                "$(live_skeptic_field)" "malformed record"

echo '=== #771: the legacy name convention still counts (union, not replacement) ==='
# A window spawned before provenance records existed has no record at all.
# Dropping the name check would have traded one blind spot for another.
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="legacy-worker"
export MOCK_TMUX_WINDOW_ROWS=$'0:3 legacy-worker\n0:7 legacy-worker-skeptic'
export MOCK_PANE_STATE="3=busy 7=busy"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW MOCK_TMUX_WINDOW_ROWS MOCK_PANE_STATE
assert_eq "#771 a conventionally-named skeptic with no record still reads yes" \
          "$(live_skeptic_verdict)" "yes"

# ---- your-org/nexus-code#685 items 2 + 3: the skeptic-decision audit trail --
#
# ITEM 2. The three decision emits had only SOURCE assertions — they read
# `monitor/ng` and checked the emit is present. That cannot distinguish a
# working best-effort emit from a broken one, because `( … ) 2>/dev/null ||
# true` exits 0 either way, which is the whole reason #685 calls a regression
# here SILENT. These read the bytes back OFF DISK instead.
#
# ITEM 3 — the consumer question, taken as a DECISION rather than left open:
# the action log is queried AD HOC for forensics (`jq 'select(.event ==
# "skeptic-disposition-honoured")' monitor/.state/action-log.jsonl`), and these
# behavioural assertions are what make that query's substrate non-regressible.
# A standing consumer is deliberately NOT added: nothing currently needs the
# rate at runtime, and a reader with no caller is the same unowned artifact
# #685 objects to, one level out.
disp_log_events() {  # every action-log event name, one per line
    [[ -r "$STATE_DIR/action-log.jsonl" ]] || return 0
    jq -r '.event // empty' "$STATE_DIR/action-log.jsonl" 2>/dev/null
}
# EXACT membership, not substring. `assert_contains` on the event list is
# defeated by a renamed event: a mutant emitting
# `skeptic-disposition-honoured-XX` still CONTAINS the string it was asserted
# against, so the assertion stayed green while the trace was broken. Found by
# the mutant refusing to redden.
# HERESTRING, not a pipe: `cmd | grep -q` is the #622 early-exit inversion —
# grep exits at the first match, the producer takes EPIPE, and under pipefail
# the pipeline reports FAILURE at the moment the thing it tested turned out
# TRUE. `test-sigpipe-assertion-lint.sh` enforces this and caught the pipe
# version of this very helper.
disp_has_event() { # yes|no — is event $1 present, as a whole line
    local _ev; _ev=$(disp_log_events)
    grep -qxF "$1" <<<"$_ev" && printf 'yes' || printf 'no'
}
disp_log_row() {     # the newest row for event $1, as compact JSON
    [[ -r "$STATE_DIR/action-log.jsonl" ]] || return 0
    jq -c --arg e "$1" 'select(.event == $e)' "$STATE_DIR/action-log.jsonl" \
        2>/dev/null | tail -1
}

echo '=== #685 item 2: the HONOURED decision reaches DISK, with its fields ==='
reset_mocks
HON_REPORT="$FAKE_NEXUS/reports/nexus_2026-05-11_092000_honoured.md"
write_report "$HON_REPORT"
printf '\nDisposition: no-further-pass\n' >> "$HON_REPORT"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-honoured-worker"
# findings >= threshold, verdict NOT suspect/refuted → the count alone WOULD
# have escalated, and the stated disposition suppresses it. That is the
# honoured decision, and it is the one that leaves no request behind — so the
# action log is the ONLY surface it can be audited from.
run_ng stdout stderr rc wrap-up 77 "$HON_REPORT" --repo override-org/override-repo \
    --skeptic-role --skeptic-target sk-reviewed-worker --skeptic-depth 1 \
    --skeptic-verdict check --skeptic-findings 4
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq "#685 honoured wrap-up exits 0" "$rc" "0"
assert_eq "#685 the HONOURED event is ON DISK (not just in the source)" \
    "$(disp_has_event skeptic-disposition-honoured)" "yes"
_hon_row=$(disp_log_row skeptic-disposition-honoured)
# The fields are the point: without them the row records THAT a decision
# happened and not WHAT was traded away, so the counterfactual #685 asks for
# ("was #678's fix right?") stays unanswerable.
assert_contains "#685 …carrying the findings count it suppressed"  "$_hon_row" '"findings":"4"'
assert_contains "#685 …carrying the threshold it was measured against" "$_hon_row" '"threshold":'
assert_contains "#685 …carrying the verdict"                       "$_hon_row" '"verdict":"check"'
# #684 made `source` meaningful: honouring a PROSE-inferred disposition is a
# different event from honouring a stated field, and without this they are
# indistinguishable in the log.
assert_contains "#685 …and WHERE the disposition was read from (#684)" "$_hon_row" '"source":"body"'
# NEGATIVE CONTROL — the honoured path must file NO request. Without this the
# assertions above would also pass on a build that escalated anyway and merely
# logged the word "honoured".
assert_eq "#685 CONTROL: an honoured disposition files NO spawn request" \
    "$(count_spawn_reqs)" "0"

echo '=== #685: the OVERRIDE decision reaches disk too, and names its rule ==='
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-override-worker"
# Same stated no-further-pass, but a `refuted` verdict — a NAMED severity
# signal, which is the only thing allowed to override the author (#678).
run_ng stdout stderr rc wrap-up 77 "$HON_REPORT" --repo override-org/override-repo \
    --skeptic-role --skeptic-target sk-reviewed-worker --skeptic-depth 1 \
    --skeptic-verdict refuted --skeptic-findings 4
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq "#685 override wrap-up exits 0" "$rc" "0"
assert_eq "#685 the OVERRIDE event is ON DISK" \
    "$(disp_has_event skeptic-disposition-overridden)" "yes"
_ovr_row=$(disp_log_row skeptic-disposition-overridden)
assert_contains "#685 …naming WHICH severity rule fired" "$_ovr_row" "verdict-refuted"
# CONTROL — honoured and overridden are the two halves #685 says are asymmetric.
# Asserting they are DISTINCT events on the same surface is the actual claim.
assert_eq "#685 CONTROL: an override does NOT also log 'honoured'" \
    "$(disp_has_event skeptic-disposition-honoured)" "no"

echo '=== #685: the label must not assert a DISPUTE that did not happen ==='
# The recursion-path label was `second-pass-dispute` by definition. #681 F4
# derived three arms from the actual cause; these are the two that were still
# falling through to the default — and BOTH are agreements, not disputes.
reset_mocks
CONC_REPORT="$FAKE_NEXUS/reports/nexus_2026-05-11_092500_concurs.md"
write_report "$CONC_REPORT"
printf '\nDisposition: second-pass\n' >> "$CONC_REPORT"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-concur-worker"
# findings >= threshold makes the DERIVED recommendation substantive, and the
# author independently asked for another pass. Both parties agree. The
# `_sk_author_asked` arm cannot fire here — it only runs when the count did
# NOT derive a second pass — so this is precisely the fall-through case.
run_ng stdout stderr rc wrap-up 77 "$CONC_REPORT" --repo override-org/override-repo \
    --skeptic-role --skeptic-target sk-reviewed-worker --skeptic-depth 1 \
    --skeptic-verdict check --skeptic-findings 4
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq "#685 concur wrap-up exits 0" "$rc" "0"
body=$(spawn_req_body)
assert_contains "#685 both parties asking for a second pass is CONCURRENCE" \
    "$body" "second-pass-author-concurs"
assert_not_contains "#685 …and is NOT labelled a dispute" "$body" "second-pass-dispute"

reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-nodisp-worker"
# $REPORT states no disposition at all. There is no second party, so there is
# nothing to dispute; the recommendation is purely count-derived.
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-role --skeptic-target sk-reviewed-worker --skeptic-depth 1 \
    --skeptic-verdict check --skeptic-findings 4
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq "#685 no-disposition wrap-up exits 0" "$rc" "0"
body=$(spawn_req_body)
assert_contains "#685 a report stating NOTHING cannot be disputing anything" \
    "$body" "second-pass-no-disposition-stated"
assert_not_contains "#685 …and is NOT labelled a dispute either" "$body" "second-pass-dispute"
# CONTROL — a REAL dispute must still be labelled one, or the two assertions
# above are satisfied by a build that simply deleted the word "dispute".
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-realdispute-worker"
run_ng stdout stderr rc wrap-up 77 "$HON_REPORT" --repo override-org/override-repo \
    --skeptic-role --skeptic-target sk-reviewed-worker --skeptic-depth 1 \
    --skeptic-verdict refuted --skeptic-findings 4
unset MOCK_TMUX MOCK_TMUX_WINDOW
body=$(spawn_req_body)
assert_contains "#685 CONTROL: a severity signal overriding the author IS a dispute" \
    "$body" "second-pass-dispute,disposition-overridden"

echo '=== #685 round 10: the request records WHICH ng filed it ==='
# Every other field describes the DECISION. None described the CODE, and in
# this workspace the deployed `ng` and the merged `ng` are routinely different
# vintages — the primary ran 119 commits behind while the fix sat on `dev`.
# Seven consecutive depth-2 requests were filed carrying
# `deliberate-reasons: second-pass-dispute` on reports that correctly stated
# `no-further-pass`, i.e. exactly the defect #681/#685 had already fixed.
# Telling "live regression" from "undeployed fix" took a forensic pass and
# succeeded only because an unrelated reword happened to differ between the
# two revisions. `filed-by-ng:` makes it a one-line read.
#
# Asserted as EXACT EQUALITY against the identity of the file that actually
# ran, not as a "the field is non-empty" presence check: a hardcoded constant
# or a stale value would satisfy presence and defeat the entire purpose.
# Read with an awk accumulator, NOT `grep -m1` / `awk …{exit}`: those are
# the #622/#682 early-exit readers, and writing one here — in the same round
# that classifies them — is the mistake this repo keeps catching itself in.
prov_line=$(printf '%s\n' "$body" | awk '/^filed-by-ng:/ { v = $0 } END { if (v != "") print v }')
# Precondition for the expected value below: the fixture install is NOT a git
# checkout, so _ng_provenance takes its sha1 fallback. State it as an
# assertion — if this ever stops holding, the equality below would be
# comparing against the wrong branch of the helper and would go red for a
# reason that has nothing to do with the property.
if git -C "$FAKE_NEXUS/monitor" rev-parse --short HEAD >/dev/null 2>&1; then
    printf '  FAIL: %s\n' "fixture install is unexpectedly a git checkout" >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: %s\n' "fixture install is not a git checkout (sha1 fallback applies)"; PASS=$(( PASS + 1 ))
fi
exp_sha=$(sha1sum "$NG" | cut -c1-12)
assert_eq "#685 filed-by-ng names the exact ng that ran, by content" \
    "$prov_line" "filed-by-ng: $NG @ sha1:$exp_sha"

echo '=== spawn-skeptic: an auto-deny resolution files NOTHING ==='
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-deny-worker"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision deny --skeptic-rationale "one-line doc typo, trivial"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq       "auto-deny wrap-up exits 0"                "$rc" "0"
assert_eq       "NO spawn-skeptic request filed on deny"   "$(count_spawn_reqs)" "0"
assert_not_contains "stdout says nothing about a spawn-skeptic request" "$stdout" \
                    "spawn-skeptic request:"

echo '=== spawn-skeptic: a retry is idempotent (no duplicate request) ==='
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-retry-worker"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
assert_eq       "first require wrap-up exits 0"            "$rc" "0"
assert_eq       "one request after first wrap-up"          "$(count_spawn_reqs)" "1"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq       "retry require wrap-up exits 0"            "$rc" "0"
assert_contains "retry reports the request already filed"  "$stdout" \
                "spawn-skeptic request: skipped (already filed)"
assert_eq       "still exactly one request after retry"    "$(count_spawn_reqs)" "1"

echo '=== spawn-skeptic: off-tmux wrap-up (no window) files NOTHING ==='
reset_mocks
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
assert_eq       "off-tmux require wrap-up exits 0"         "$rc" "0"
assert_eq       "NO request filed without a source window" "$(count_spawn_reqs)" "0"

# ---- Test 40 (LOAD-BEARING, your-org/nexus-code#605): a repeat wrap-up
#      must not SILENTLY DISCARD --comment-body-file.
#
#      A repeat wrap-up is the NORMAL shape of the skeptic protocol, not
#      an exotic call sequence: skeptic posts a verdict → worker fixes
#      what it found → skeptic verifies and wraps up a SECOND time on the
#      same issue. That second wrap-up is the one that tells the
#      orchestrator whether the PR is mergeable, and it is exactly the
#      one post-once dropped: it found the earlier comment, re-pointed
#      its asset link, exited 0, and printed a line reading `UPDATED`.
#      The verdict was published nowhere. It only surfaced because that
#      skeptic read the comment back; an agent trusting the exit code —
#      the reasonable thing to do — would have reported publishing a
#      verdict it had not published.
#
#      RED on old code: `store_body` still holds the FIRST body and the
#      second is nowhere. -------------------------------------------------
echo '=== #605: a DIFFERING --comment-body-file on a repeat wrap-up is published ==='
reset_mocks
BODY_A="$FAKE_NEXUS/body-a.md"
BODY_B="$FAKE_NEXUS/body-b.md"
printf 'VERDICT ROUND ONE: suspect — three findings, one merge-blocking.\n\nFull report: {{REPORT_URL}}\n' > "$BODY_A"
printf 'VERDICT ROUND TWO: credible — fixes verified, mergeable as it stands.\n\nFull report: {{REPORT_URL}}\n' > "$BODY_B"

run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --repo override-org/override-repo --comment-body-file "$BODY_A"
assert_eq       "#605 first wrap-up exits 0"            "$rc" "0"
assert_contains "#605 round-one verdict IS published"   "$(comment_store_body)" \
                "VERDICT ROUND ONE"

# The second verdict. Different content, same issue + report.
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --repo override-org/override-repo --comment-body-file "$BODY_B"
assert_eq       "#605 repeat wrap-up exits 0"           "$rc" "0"
gh_calls=$(<"$GH_CAPTURE")
assert_contains "#605 the SECOND verdict is POSTed, not dropped" "$gh_calls" \
                "/repos/override-org/override-repo/issues/42/comments"
assert_contains "#605 stdout says a NEW comment was posted, not 'UPDATED'" \
                "$stdout" "posted comment: NEW"
assert_not_contains "#605 stdout does NOT claim UPDATED for a run that published new content" \
                "$stdout" "posted comment: UPDATED"

# NEGATIVE CONTROL — the post-once guarantee must SURVIVE. An identical
# body on a re-run is a genuine idempotent retry and must still take the
# re-point path, or this fix would trade a dropped verdict for a
# duplicate-comment flood on every wrap-up retry.
reset_mocks
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --repo override-org/override-repo --comment-body-file "$BODY_A"
assert_eq       "#605 CONTROL: first run exits 0"       "$rc" "0"
run_ng stdout stderr rc wrap-up 42 "$REPORT" \
    --repo override-org/override-repo --comment-body-file "$BODY_A"
assert_eq       "#605 CONTROL: identical-body re-run exits 0" "$rc" "0"
assert_contains "#605 CONTROL: an IDENTICAL body still takes the re-point path" \
                "$stdout" "posted comment: unchanged"
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "#605 CONTROL: no duplicate comment POSTed on a true retry" \
                "$gh_calls" "/repos/override-org/override-repo/issues/42/comments"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
