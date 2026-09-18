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
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
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
# The NEGATIVE of the above, and it must exist HERE rather than be assumed.
# This suite defines its own assertion vocabulary and does NOT source
# monitor/watcher/_test_helpers.sh, so a call to a helper that only exists
# there is `command not found`: rc 127, a line on stderr nobody reads, PASS
# and FAIL both unmoved, and a green summary. Two `assert_no_file` calls in
# the #984 block below were exactly that until a mutant exposed them — the
# mutation flipped the behaviour they were meant to catch and the suite still
# reported them as neither passed nor failed. Same shape as the silent-zero
# family in CLAUDE.md: the error was never lost, it was simply off the path
# that produced the number.
assert_no_file() {
    local label="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — file exists but must not: %s\n' "$label" "$path" >&2
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
# your-org/nexus-code#1077: `ng` also refuses without the primary-root resolver.
cp "$(dirname "$NG_REAL")/_nexus-root.sh" "$FAKE_NEXUS/monitor/_nexus-root.sh"
# …and source it HERE too: this suite computes a marker key itself
# (your-org/nexus-code#941), and a test that hard-codes the key it is checking
# re-creates the coupling the injective key exists to remove.
# shellcheck source=monitor/_bookkeeping.sh
. "$(dirname "$NG_REAL")/_bookkeeping.sh"
NG="$FAKE_NEXUS/monitor/ng"
STATE_DIR="$FAKE_NEXUS/monitor/.state"

# CONTAIN `ng`'s PROCESS-LEVEL STATE DIR (your-org/nexus-code#1306).
#
# `run_ng` below is already correct — it pins `NEXUS_STATE_DIR` and unsets
# `NEXUS_ROOT`. The leak was the two `$NG_REAL` calls in the `#1132` block,
# which bypass that helper: `ng` resolves `STATE_DIR` ONCE at startup and its
# usage tap fires BEFORE dispatch, so a `--state-dir` flag reaches the ledger
# and not the process, and the row lands in the inherited `$NEXUS_ROOT` — the
# operator's canonical state in an agent shell. Measured LEAK at `0b82ffb2`.
# Exported here rather than added to those two call sites, because the defect
# is that a NEW call site inherits the leak by default.
#
# A DEDICATED SINK, not this fixture's `$STATE_DIR`: containment only requires
# "not the inherited root", and routing telemetry into a directory this suite
# COUNTS could perturb one of its 520 assertions.
#
# WRITTEN INLINE, NOT AS `th_pin_ng_state`. That helper lives in
# `_test_helpers.sh`, which this suite deliberately does not source — so the
# call would be `command not found`: rc 127, a line on stderr nobody reads,
# PASS and FAIL both unmoved, and a green summary that still leaks. That is
# the trap the `assert_no_file` comment forty lines above describes, and it
# caught this fix on its first attempt: the probe still said LEAK while the
# suite said 520 passed, 0 failed.
_NG_SINK="$WORK/ng-telemetry"
mkdir -p "$_NG_SINK"
export NEXUS_STATE_DIR="$_NG_SINK"
# FAIL CLOSED, and behaviourally: assert where a real `ng` actually writes,
# not that the variable holds the string we just put in it. The probe runs
# against its OWN throwaway root so a failed pin lands there rather than in the
# operator's tree, and that root doubles as the positive control — the tap is
# `[[ -d "$STATE_DIR" ]]`, so an absent directory would let this pass without
# exercising the write path at all. Both arms are required: "in the sink" alone
# is satisfiable by an `ng` that writes nowhere.
_ng_pin_decoy=$(mktemp -d) || { printf '  FAIL: ng state pin NOT CHECKED — mktemp failed\n' >&2; exit 1; }
mkdir -p "$_ng_pin_decoy/monitor/.state"
env NEXUS_ROOT="$_ng_pin_decoy" NEXUS_STATE_DIR="$_NG_SINK" NG_USAGE_LOG=1 \
    "$NG_REAL" help >/dev/null 2>&1
if [[ -e "$_ng_pin_decoy/monitor/.state/ng-usage.jsonl" ]]; then
    printf '  FAIL: NEXUS_STATE_DIR did not contain ng — this run would write into the inherited NEXUS_ROOT (your-org/nexus-code#1306)\n' >&2
    rm -rf "$_ng_pin_decoy"; exit 1
fi
if [[ ! -s "$_NG_SINK/ng-usage.jsonl" ]]; then
    printf '  FAIL: ng state pin NOT CHECKED — the probe wrote no row into %s, so the pin is unverified in both directions\n' "$_NG_SINK" >&2
    rm -rf "$_ng_pin_decoy"; exit 1
fi
rm -rf "$_ng_pin_decoy"

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
# Drain stdin defensively (some calls --input -) — and KEEP it: the #1352
# disposition arm stores the posted body so a later GET can read it back.
_body=""
if ! [ -t 0 ]; then _body=\$(cat 2>/dev/null || true); fi

case "\$endpoint" in
    */issues/comments/5*)
        # your-org/nexus-code#1352 read-back: GET a disposition comment by id.
        _n="\${endpoint##*/comments/5}"
        if [[ -n "\${MOCK_DISP_DIR:-}" && -r "\$MOCK_DISP_DIR/\$_n.body" ]]; then
            jq -Rs '{body: .}' < "\$MOCK_DISP_DIR/\$_n.body"
        else
            printf '{"body":""}'
        fi
        ;;
    */issues/*/comments)
        if [[ "\${MOCK_COMMENT_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock comment POST 422"}' >&2
            exit 1
        fi
        # #1352: a STATEFUL comment store when MOCK_DISP_DIR is set — the POST
        # records the body, and MOCK_DISP_SWALLOW names issues whose write is
        # ACCEPTED (rc 0, a URL) but NOT STORED: the #1118 shape, the negative
        # control a read-back must fail on.
        if [[ -n "\${MOCK_DISP_DIR:-}" ]]; then
            _n=\$(sed -E 's|.*/issues/([0-9]+)/comments.*|\\1|' <<<"\$endpoint")
            if [[ " \${MOCK_DISP_SWALLOW:-} " == *" \$_n "* ]]; then
                : > "\$MOCK_DISP_DIR/\$_n.body"
            else
                printf '%s' "\$_body" | jq -r '.body // empty' > "\$MOCK_DISP_DIR/\$_n.body" 2>/dev/null \\
                    || printf '%s' "\$_body" > "\$MOCK_DISP_DIR/\$_n.body"
            fi
            printf '{"html_url":"https://mock.example/issues/%s#issuecomment-5%s"}' "\$_n" "\$_n"
            exit 0
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
# run_ng_out — run `ng` and PRINT its stdout, for read-only probes whose value
# is what we assert on. A thin wrapper over run_ng rather than a second copy of
# its env scrubbing: a duplicate would drift, and the scrubbing is what keeps
# the suite off the operator's real state dir (#833).
run_ng_out() {
    local _o _e _r
    run_ng _o _e _r "$@"
    printf '%s' "$_o"
}

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

# your-org/nexus-code#1432: ten call sites below used to call `reset_state`,
# which NO file defines — `command not found` at rc 127, untested, so the
# #815-F6 and #825 fail-closed blocks ran on whatever state the previous case
# left, and the suite was green either way. This suite deliberately does not
# source _test_helpers.sh (see :130), so the runtime `command_not_found_handle`
# never installs here; this precondition is the local equivalent — a helper
# this file calls must exist BEFORE the first case runs, or the run is
# refused at exit 97 rather than tallied as green.
_require_fn() { declare -F "$1" >/dev/null 2>&1 || { printf 'REFUSED: helper %s is called by this suite and defined nowhere (your-org/nexus-code#1432)\n' "$1" >&2; exit 97; }; }
reset_mocks() {
    unset MOCK_UPLOAD_FAIL MOCK_UPLOAD_SHA MOCK_COMMENT_FAIL MOCK_ROCKET_FAIL
    unset MOCK_COMMENT_MOVING MOCK_PATCH_FAIL_MATCH
    # #771 — the live-skeptic fixtures. `rm -rf $STATE_DIR` below already
    # drops the provenance records; these two must be cleared explicitly or
    # a window list leaks into the next case and makes it pass for the
    # wrong reason.
    unset MOCK_TMUX_WINDOW_ROWS MOCK_PANE_STATE MOCK_TMUX_BLIND
    rm -rf "$STATE_DIR"
    rm -f "$COMMENT_STORE" "$COMMENT_SEQ"
}
_require_fn reset_mocks

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
# your-org/nexus-code#1095 — THE DEFAULT FIXTURE IS A **COMPLIANT** REPORT.
#
# `$2` is the frontmatter `disposition:` VALUE, defaulting to `second-pass`.
# Pass an explicit empty string for the cases whose SUBJECT is the absence.
#
# WHY THE DEFAULT MOVED, because a fixture-wide change needs its reason on
# the record. Until #1095 every fixture report here stated NO disposition,
# and `_wrapup_skeptic_step`'s require arm derived a spawn-skeptic request
# from that absence. So the require-path population of this suite — 28 call
# sites on `$REPORT` alone, plus every per-test artefact — asserted rc 0 and
# a filed request for a wrap-up whose recommendation was manufactured from a
# missing field. Measured: with the require-arm refusal in place and the old
# fixture, 121 of 448 assertions go RED. That is not one assertion pinning
# the defect; it is the whole require-path fixture population encoding it as
# the normal case.
#
# `second-pass` and not `no-further-pass`, deliberately: on a `require`
# resolution a worker that AGREES is the ordinary case, and it composes
# `recommendation: require (report agrees: second-pass)` rather than the
# `DISPUTED` that a stated `no-further-pass` correctly produces. Choosing
# the disputing value as the default would have made every unrelated
# pointer assertion run through the dispute arm.
#
# The absence is NOT thereby untested — it is tested on purpose, by the
# #1095 negative controls below and by the role-path cases that pass `""`.
write_report() {
    local path="$1"
    local disp="${2-second-pass}"
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
    # Insert at column 0 INSIDE the frontmatter — the only position the
    # parser treats as governing. `sed` on the closing fence would also hit
    # the `---` a body might contain, so anchor on the `status:` line the
    # skeleton above always writes exactly once.
    if [[ -n "$disp" ]]; then
        awk -v D="disposition: $disp" '
            !done && /^status: completed$/ { print; print D; done=1; next }
            { print }
        ' "$path" > "$path.tmp1095" && mv "$path.tmp1095" "$path"
    fi
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
_body=""
if ! [ -t 0 ]; then _body=\$(cat 2>/dev/null || true); fi
case "\$endpoint" in
    */issues/comments/5*)
        _n="\${endpoint##*/comments/5}"
        if [[ -n "\${MOCK_DISP_DIR:-}" && -r "\$MOCK_DISP_DIR/\$_n.body" ]]; then jq -Rs '{body: .}' < "\$MOCK_DISP_DIR/\$_n.body"; else printf '{"body":""}'; fi ;;
    */issues/*/comments)
        if [[ "\${MOCK_COMMENT_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock comment POST 422"}' >&2; exit 1
        fi
        if [[ -n "\${MOCK_DISP_DIR:-}" ]]; then   # #1352 stateful store — see the first stub
            _n=\$(sed -E 's|.*/issues/([0-9]+)/comments.*|\\1|' <<<"\$endpoint")
            if [[ " \${MOCK_DISP_SWALLOW:-} " == *" \$_n "* ]]; then : > "\$MOCK_DISP_DIR/\$_n.body"
            else printf '%s' "\$_body" | jq -r '.body // empty' > "\$MOCK_DISP_DIR/\$_n.body" 2>/dev/null || printf '%s' "\$_body" > "\$MOCK_DISP_DIR/\$_n.body"; fi
            printf '{"html_url":"https://mock.example/issues/%s#issuecomment-5%s"}' "\$_n" "\$_n"; exit 0
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
            # your-org/nexus-code#940 — fail the PATCH that CARRIES a given
            # string, so a test can target the IN-PLACE EDIT specifically. The
            # edited arm issues two PATCHes: (1) the re-point, which rewrites
            # only the asset link, and (2) the body edit, which carries the new
            # content. Matching on CONTENT rather than on a PATCH ORDINAL is
            # deliberate: an ordinal silently retargets the moment the re-point
            # retries its CAS or an earlier step PATCHes — measured, the ordinal
            # form let the edit succeed and the failure branch went undriven.
            if [[ -n "\${MOCK_PATCH_FAIL_MATCH:-}" ]] \\
               && [[ "\$body_json" == *"\${MOCK_PATCH_FAIL_MATCH}"* ]]; then
                echo '{"message":"mock comment PATCH 422"}' >&2; exit 1
            fi
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
# your-org/nexus-code#862 — this block previously asserted the DEFECT.
# Its own comment four lines up says "the report gets materially
# corrected", and it then required exit 0 and the word `unchanged` — i.e.
# it pinned the behaviour where a corrected report reaches the asset repo
# and never reaches the thread, and pinned it as CORRECT. A test that
# enshrines the defect is worse than no test: it makes the fix look like
# the regression.
#
# The asset sha moves here (aaaa1111 → bbbb2222), so the report bytes
# changed; the composed body is byte-identical because this fixture's
# `## Summary` is untouched — which is exactly what the append-only
# convention produces. Contract now: NOTHING PUBLISHED, exit 3.
assert_eq       "re-wrap exits 3 — report changed, thread did not"  "$rc" "3"
assert_contains "stdout says NOTHING PUBLISHED, not 'unchanged'"    "$stdout" \
                "posted comment: NOTHING PUBLISHED https://mock.example/issuecomment-1234"
assert_not_contains "the misleading 'unchanged' wording is gone"    "$stdout" \
                "posted comment: unchanged https://mock.example/issuecomment-1234"
assert_contains "stderr names the append-only collision as the cause" "$stderr" \
                "NOTHING PUBLISHED — the asset link moved, the thread did not"
# your-org/nexus-code#1116. This used to assert the remedy said "edit
# `## Summary` in place", and that remedy is INCOMPLETE — measured by following
# it: the teaser is the Summary's FIRST SENTENCE capped at 200 chars, so a
# correction added lower in the section leaves the composed body byte-identical
# and lands the author back on this same exit 3. Two consecutive re-wraps of
# this PR's own report did exactly that. Assert the sharper property — that the
# remedy names WHERE in the Summary — rather than the old substring, which a
# misleading message satisfied just as well.
assert_contains "stderr's remedy names the Summary's OPENING, not merely the section" \
                "$stderr" "edit the OPENING of \`## Summary\`"
assert_contains "stderr says editing elsewhere in the section is NOT enough" \
                "$stderr" "is not"
assert_contains "stderr gives the actual bound (the 200-char cap)" \
                "$stderr" "first 200 characters"
# F1 (#873 review): the check keys on the asset link, which pins the asset
# repo HEAD rather than this report's bytes — so a concurrent upload from
# another window can move it and produce a spurious rc 3. The direction is
# deliberate (it can over-speak, never fall silent), but a reader who did not
# change their report must be told that here rather than left hunting. Assert
# the disclosure so it cannot be quietly dropped later.
assert_contains "stderr DISCLOSES the false-alarm mode"              "$stderr" \
                "FALSE ALARM MODE"
assert_contains "stderr names the concurrent-upload cause of a false alarm" "$stderr" \
                "concurrent upload from another"
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
# The action log records the outcome so a THIRD wrap-up keys off it.
# your-org/nexus-code#862: the recorded state is now `nothing-published`
# rather than `updated`. That distinction has to survive into the log, not
# just stdout — the log is what the orchestrator reads when reconstructing
# what a window actually accomplished, and "the thread never heard about
# this correction" is precisely the fact it must not lose. A log saying
# `updated` for this run would reproduce the defect one layer down.
LOG_FILE="$STATE_DIR/action-log.jsonl"
log_lines=$(<"$LOG_FILE")
assert_contains "log records comment=nothing-published on the re-wrap" "$log_lines" \
                '"comment":"nothing-published"'
assert_not_contains "log does NOT record the re-wrap as a plain update" "$log_lines" \
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

# ---- your-org/nexus-code#940: the `comment_st=edited` arm --------------------
#
# #656 added an in-place EDIT for the case where the COMPOSED body itself
# changed (not just the asset link, which Test 34 covers and which normalises
# away). `grep -n 'EDITED|comment_st=edited|composed body changed'` over this
# file returned EMPTY, so the arm was asserted nowhere — and the #656/#873
# "they compose to cover the whole case" claim rested on it.
#
# THESE ASSERT WHAT THE ARM DOES, NOT THAT IT EXISTS. A test that greps `ng`
# for the string `comment_st=edited` would be a PRESENCE test — the same defect
# #885 names on this same PR — and would pass against an arm that PATCHes
# nothing. So: the stored comment must actually CARRY the new content, the
# discriminator must show the arm staying shut when the body is unchanged, and
# the failure direction must be loud.
echo '=== re-wrap whose COMPOSED BODY changed → comment EDITED in place (#940) ==='
reset_mocks
# THE DRIVER IS AN EDIT TO THE REPORT, NOT A DIFFERENT REPORT. The prior-comment
# lookup keys on the report BASENAME (`_wrapup_prior_comment_url "$issue"
# "$basename" "$target"`), so a different filename finds no prior comment and
# takes the fresh-POST path — measured: the first draft of this test did exactly
# that, published the content by POST, and would have been read as the edit arm
# working. The composed body is `## <title>\n\n<summary>\n\nFull report: <url>`
# drawn from the report itself, so CORRECTING THE REPORT is what changes it —
# which is also the real-world case #656 was filed for.
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq "first wrap-up exits 0" "$rc" "0"
# PRECONDITION, checked: `_wrapup_report_summary` joins the section, truncates
# to 200 chars and cuts at the first SAFE sentence boundary, so only the FIRST
# sentence reaches the comment. (This comment used to say "the LAST sentence
# boundary", which was never what the code did — the very doc-vs-rule gap
# your-org/nexus-code#1114 is about. Corrected with that fix.) Correcting any later sentence changes the report
# and NOT the composed body — measured; the first draft did that and the edit
# arm never fired.
assert_contains "the comment carries the ORIGINAL first sentence" "$(comment_store_body)" \
                "Implemented ng wrap-up so workers can hand off in one verb."
# The worker materially corrects the report, same path, same basename.
perl -0pi -e 's/Implemented ng wrap-up so workers can hand off in one verb\./CORRECTED: the earlier summary overstated the scope./' "$REPORT"
grep -q 'CORRECTED: the earlier summary' "$REPORT" \
    || { echo "FAIL: could not stage the report correction" >&2; exit 1; }
: > "$GH_CAPTURE"
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq "re-wrap after correcting the report exits 0" "$rc" "0"
store_body=$(comment_store_body)
assert_contains "#940 the comment now CARRIES the correction — it is published, not dropped" \
                "$store_body" "CORRECTED: the earlier summary overstated the scope."
assert_not_contains "#940 …and the superseded summary is gone from it" \
                    "$store_body" "Implemented ng wrap-up so workers can hand off in one verb."
gh_calls=$(<"$GH_CAPTURE")
assert_contains "#940 the correction went through PATCH on the EXISTING comment" "$gh_calls" \
                "-X PATCH /repos/override-org/override-repo/issues/comments/1234"
assert_not_contains "#940 …and did NOT post a duplicate comment" "$gh_calls" \
                    "/issues/42/comments"
assert_contains "#940 the action log records comment=edited" "$(<"$STATE_DIR/action-log.jsonl")" \
                '"comment":"edited"'

echo '=== DISCRIMINATOR: an unchanged composed body must NOT take the edit arm ==='
# Without this, the assertions above pass just as well against an `ng` that
# edits on EVERY re-wrap — making them a test of "a PATCH happened", not of
# "the body changed, so it was republished".
reset_mocks
write_report "$REPORT"
export MOCK_UPLOAD_SHA="eeee5555firstpass"
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
export MOCK_UPLOAD_SHA="ffff6666secondpass"
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
unset MOCK_UPLOAD_SHA
# RE-SPELLED AT THE B1 BUNDLE SEAM, not weakened. This block's SUBJECT — stated
# in its own heading above — is that an unchanged composed body must not take
# the EDIT arm, and the `assert_not_contains "edited"` below is what carries it.
# It is untouched and still passes.
#
# What changed underneath it is the NAME and EXIT CODE of the state this
# scenario lands in. your-org/nexus-code#862 (in #873) split the old `updated`
# in two, and this fixture drives the new half by construction: it moves
# MOCK_UPLOAD_SHA between the two runs, so the asset link moves while the
# composed body stays byte-identical. #862 calls that `nothing-published` and
# exits 3 ON PURPOSE — its argument is that the old exit-0 `updated` was
# "truthful and useless", because the report moved, the thread did not, and
# nobody was told. `updated`/rc 0 still exists; it is now the case where the
# link did NOT move.
#
# So #940's expectation here was incidental to its purpose and #862 is the
# later, deliberate treatment of the same state. Asserting the state by name
# rather than just the rc, since `3` alone would also match an unrelated
# failure path.
assert_eq "same-report re-wrap exits 3 (#862: the asset link moved, the thread did not)" "$rc" "3"
assert_contains "#940 DISCRIMINATOR: an asset-link-only change logs comment=nothing-published (#862)" \
                "$(<"$STATE_DIR/action-log.jsonl")" '"comment":"nothing-published"'
assert_not_contains "#940 DISCRIMINATOR: …and NOT comment=edited" \
                    "$(<"$STATE_DIR/action-log.jsonl")" '"comment":"edited"'

echo '=== the in-place edit FAILS → loud, non-zero, and no false success (#940) ==='
# The arm's own comment says failure here is loud "because reporting success for
# a correction that did not publish is the defect being fixed". That sentence
# was unasserted. `MOCK_PATCH_FAIL_MATCH` fails the PATCH carrying the new content, while the
# re-point (PATCH 1) succeed — the exact state the branch exists for.
reset_mocks
write_report "$REPORT"
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
assert_eq "first wrap-up exits 0" "$rc" "0"
perl -0pi -e 's/Implemented ng wrap-up so workers can hand off in one verb\./CORRECTED: this correction must not be reported as published./' "$REPORT"
grep -q 'must not be reported as published' "$REPORT" \
    || { echo "FAIL: could not stage the second correction" >&2; exit 1; }
export MOCK_PATCH_FAIL_MATCH="must not be reported as published"
run_ng stdout stderr rc wrap-up 42 "$REPORT" --repo override-org/override-repo
unset MOCK_PATCH_FAIL_MATCH
assert_eq "#940 a failed in-place edit exits NON-ZERO" "$rc" "1"
assert_contains "#940 …and says the correction is NOT published" "$stderr$stdout" \
                "composed body changed but the in-place edit FAILED"
assert_not_contains "#940 …and does not claim the comment was edited" \
                    "$(<"$STATE_DIR/action-log.jsonl")" '"comment":"edited"'
assert_not_contains "#940 …and the unpublished correction is NOT in the comment" \
                    "$(comment_store_body)" "must not be reported as published"
# Leave the fixture as every later test expects to find it.
write_report "$REPORT"

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
assert_contains "#1095 a worker that AGREES is read as agreeing, not as silent" "$body" \
                "report-stated-disposition: second-pass"
assert_contains '#1095 …and the source is named, so `stated` is distinguishable from a guess' \
                "$body" "source: frontmatter"

# ── your-org/nexus-code#1285: a recorded DECLINE is the settlement ──────────
# The #599 guard suppresses a re-file only for the SAME report, UNCHANGED
# since. A worker that re-touches its report and re-wraps re-filed the same
# (window, depth) ten minutes after the orchestrator had DECLINED it. Now a
# declined reply for this (origin, depth) suppresses the re-file unless the
# worker states what is NEW.
echo '=== #1285: a DECLINED prior request suppresses a re-file without a stated delta ==='
# Hold the still-open request from the block above aside: the older #599
# "already filed" guard fires on a `.new.md` for this (origin, depth) BEFORE
# the decline arm is reached, and this block is about the decline arm.
_hold1285=$(mktemp -d); mkdir -p "$REQ_DIR"
mv "$REQ_DIR"/*-sk-req-worker-skeptic-d1.new.md "$_hold1285"/ 2>/dev/null || true
_n1285_before=$(count_spawn_reqs)
cat > "$REQ_DIR/20260101T000000Z-sk-req-worker-skeptic-d1.replied.md" <<'R'
---
kind: spawn-skeptic
origin: sk-req-worker
state: replied
---
spawn-skeptic: validate `sk-req-worker` (issue #77, depth 1)
report-path: /some/OTHER/report.md
target-window: sk-req-worker
depth: 1

## Reply
status: declined
Declined: the prior verdict stands.
R
# The report is touched so the #599 same-report guard cannot be what suppresses.
touch "$REPORT"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-req-worker"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched shared infra"
assert_eq       "#1285 wrap-up still exits 0"                          "$rc" "0"
assert_contains "#1285 the re-file is SKIPPED, naming the decline"     "$stdout" "skipped (DECLINED: 20260101T000000Z-sk-req-worker-skeptic-d1.replied.md"
assert_contains "#1285 …and tells the worker how to re-file"           "$stdout" "--skeptic-delta"
assert_eq       "#1285 no new request was filed"                       "$(count_spawn_reqs)" "$_n1285_before"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched shared infra" \
    --skeptic-delta "re-measured after the decline: the count was 12, not 0"
assert_contains "#1285 with --skeptic-delta the request IS filed"      "$stdout" "spawn-skeptic request: filed "
assert_eq       "#1285 …exactly one more request"                      "$(count_spawn_reqs)" "$(( _n1285_before + 1 ))"
assert_contains "#1285 …and it carries the delta so the round is scoped to it" "$(spawn_req_body)" \
                "delta-since-decline: re-measured after the decline: the count was 12, not 0"
# CONTROL: a SPAWNED reply is not a settlement — that arm belongs to the
# live-skeptic field, and this check must not swallow it.
sed -i 's/^status: declined$/status: spawned/' "$REQ_DIR/20260101T000000Z-sk-req-worker-skeptic-d1.replied.md"
rm -f "$REQ_DIR"/*-sk-req-worker-skeptic-d1.new.md
_n1285_ctl=$(count_spawn_reqs)
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched shared infra"
assert_not_contains "#1285 CONTROL: a spawned reply does NOT trip the decline arm" "$stdout" "skipped (DECLINED"
rm -f "$REQ_DIR/20260101T000000Z-sk-req-worker-skeptic-d1.replied.md"
rm -f "$REQ_DIR"/*-sk-req-worker-skeptic-d1.new.md
mv "$_hold1285"/* "$REQ_DIR"/ 2>/dev/null || true; rmdir "$_hold1285" 2>/dev/null || true
unset MOCK_TMUX MOCK_TMUX_WINDOW

# ── RETARGETED, NOT DELETED (your-org/nexus-code#1095) ───────────────────
#
# Three assertions used to live HERE — `report-stated-disposition: absent`,
# `source: none` and `severity-blind` — driven by a WORKER wrap-up on a
# report with no `disposition:` field. They passed, and what they certified
# was that the worker path still composed a recommendation out of an
# ABSENCE. That is the defect #1095 names, asserted as the expected
# behaviour: the guard PINNED it. `#1137` fixed the skeptic half and left
# this half deliberately, recording the gap with `PASS: #599 the derived
# recommendation flags its own blindness` — an honest marker, but a green
# one over a live defect.
#
# The worker path now REFUSES that wrap-up (see the #1095 negative controls
# below), so this topology cannot produce a request at all and the three
# assertions cannot be satisfied here by any correct build.
#
# They are NOT deleted, because the properties they carry are real and are
# still live — on the ROLE path, where a skeptic that stated a COUNT has
# reported a result, so #881's boundary is satisfied and a missing
# disposition is legitimately not fatal. That is where they now run: see
# `#684/#599 RETARGETED` below, next to the #685 no-disposition case that
# already exercises exactly that topology. Moving them keeps the guard
# pointed at the property (an absence must be NAMED as an absence, and a
# derived recommendation must confess its blindness) on the one path where
# an absence may still legally reach a request.

echo '=== #599: a report stating no-further-pass makes the recommendation DISPUTED ==='
reset_mocks
DISP_REPORT="$FAKE_NEXUS/reports/nexus_2026-05-11_091500_disposition.md"
# your-org/nexus-code#1095 — THE SOURCE MOVED, AND THAT IS THE POINT.
# This fixture used to append `Disposition: no-further-pass` to the BODY.
# Measured at this ref, `_skeptic_stated_disposition` parses that as
# `no-further-pass body stated` — a BODY-sourced disposition — and `ng`'s
# own rule, stated in both refusal blocks, is that "only a frontmatter
# field governs; a body mention is a quotation". So the DISPUTED property
# was being certified through a source that does not govern.
#
# The property under test here is the DISAGREEMENT (derived `require` vs a
# stated `no-further-pass` must be surfaced, not silently resolved), and it
# is unchanged. Only the source moved to the one that governs. The body
# form is not discarded — it is now asserted for what it actually is, in
# the #1095 grammar case below.
write_report "$DISP_REPORT" no-further-pass
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-disp-worker"
run_ng stdout stderr rc wrap-up 77 "$DISP_REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW
# ── RETARGETED AGAIN (your-org/nexus-code#1363) ───────────────────────────
#
# This WORKER topology — a `require` decision beside a stated
# `no-further-pass` — used to proceed and file `recommendation: DISPUTED`.
# That is the exact shape `jcdeck` produced, and the contradiction was
# caught only by the request-body diagnostic in an adjacent subsystem while
# `retire-preflight` read the permissive field as its first gate. The worker
# path now REFUSES it at wrap-up, before anything is armed or filed. The
# disposition is still READ and the disagreement is still LOUD — as a
# refusal the author can act on, not as a request for the orchestrator.
assert_eq       "#599/#1363 disposition wrap-up is REFUSED on the worker path (rc 1)" "$rc" "1"
assert_contains "#599/#1363 the stated disposition is READ, not ignored — and the disagreement is loud" \
                "$stderr" "REFUSED — the report states \`disposition: no-further-pass\`"
assert_eq       "#599/#1363 …and NO request is filed from a refused wrap-up" \
                "$(count_spawn_reqs)" "0"
# The DISPUTED composition and its NEGATIVE CONTROL — the request is still
# FILED on a disagreement, never silently dropped — are live on the ROLE
# path, which #1363 exempts: a reviewer's `no-further-pass` overridden by
# its own `suspect` verdict (#678) composes `second-pass-dispute,
# disposition-overridden`, and the orchestrator must still be handed it.
reset_mocks
write_skeptic_record sk-disp-skeptic victim
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-disp-skeptic"
run_ng stdout stderr rc wrap-up 77 "$DISP_REPORT" --repo override-org/override-repo \
    --skeptic-role --skeptic-verdict suspect --skeptic-findings 2 --skeptic-target victim
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq       "#599 (role path) a skeptic's disputed no-further-pass wraps up (rc 0)" "$rc" "0"
body=$(spawn_req_body)
assert_contains "#599 (role path) the stated disposition is READ, not ignored"  "$body" \
                "report-stated-disposition: no-further-pass"
assert_contains "#599 (role path) derived-vs-stated disagreement is loud (DISPUTED)" "$body" \
                "recommendation: DISPUTED"
# NEGATIVE CONTROL — the request is still FILED. Refusing to file on a
# disagreement would silently drop a request the orchestrator has to
# adjudicate, trading one silent failure for another.
assert_eq       "#599 CONTROL: a DISPUTED recommendation still FILES the request" \
                "$(count_spawn_reqs)" "1"

# ========================================================================
# your-org/nexus-code#1095 — THE WORKER PATH REFUSES AN ABSENT DISPOSITION
# ========================================================================
#
# #1137 shipped this refusal for SKEPTIC reports only; its block lives
# inside `if [[ "$role" == "true" ]]` and says so. The worker path went on
# composing `recommendation: ... derived from ABSENCE ... severity-blind`
# for reports with no field — and five of the nine instances recorded on
# #1095 are worker reports, including `panelive`: five identical
# spawn-skeptic requests in twenty minutes, filed while a discharged
# `credible` verdict sat in the ledger, which took an orchestrator override
# to break.
#
# ITEM 4 OF THE ISSUE, WHICH IT ASKS FOR TWICE AND CALLS NON-NEGOTIABLE:
# "assert that a report with no `disposition:` is REFUSED, and that the
# refusal NAMES THE FIELD. An absence that is unfalsifiable is worse than a
# wrong value, because a missing field and a field that could not be
# written look identical." A guard never seen fail is not evidence.

echo '=== #1095: a WORKER require wrap-up with NO disposition is REFUSED ==='
reset_mocks
NODISP_REPORT="$FAKE_NEXUS/reports/nexus_2026-08-28_143000_nodisp.md"
write_report "$NODISP_REPORT" ""      # "" = the absence IS the subject here
# Assert the FIXTURE before asserting the behaviour. `write_report` now
# defaults to a compliant report, so a fixture that silently regained the
# field would make every assertion below pass for the wrong reason — the
# refusal would simply never be reached and `rc 0` would look like a fix.
assert_eq "#1095 FIXTURE: the report under test really states no disposition" \
    "$(grep -cE '^disposition:' "$NODISP_REPORT")" "0"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="nodisp-worker"
run_ng stdout stderr rc wrap-up 77 "$NODISP_REPORT" --repo override-org/override-repo \
    --trigger-comment 4242 \
    --skeptic-decision require --skeptic-rationale "touched shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq "#1095 THE NEGATIVE CONTROL: an absent disposition is REFUSED (rc 1)" "$rc" "1"
# …AND THE REFUSAL NAMES THE FIELD. The issue is explicit that this is the
# half that matters: an author told only "something is wrong" cannot act,
# and the whole cost of the defect is a person having to open a report to
# learn what a field would have said.
assert_contains "#1095 …and the refusal NAMES THE FIELD" "$stderr" 'disposition:'
assert_contains "#1095 …and names the report it read" "$stderr" "$NODISP_REPORT"
assert_contains '#1095 …and names the parser state, so `absent` is not guessed at' \
    "$stderr" "state=absent source=none"
# Both one-line remedies, spelled out. A refusal that does not name its
# escape hatch leaves only the false way out (#879).
assert_contains "#1095 …and spells out the AGREE remedy"  "$stderr" "disposition: second-pass"
assert_contains "#1095 …and spells out the DISPUTE remedy" "$stderr" "disposition: no-further-pass"
# THE PROPERTY. A refusal that still files the request is the escalation it
# claims not to be — and the refusal's own text promises all four of these.
assert_eq  "#1095 THE PROPERTY: NO spawn-skeptic request is filed by a refusal" \
    "$(count_spawn_reqs)" "0"
assert_no_file "#1095 …and NO pending marker is written" \
    "$STATE_DIR/skeptic/pending/nodisp-worker"
assert_eq  "#1095 …and NOTHING was uploaded (the refusal precedes every side effect)" \
    "$(wc -c < "$UPLOAD_CAPTURE")" "0"
# WAS a byte count on $GH_CAPTURE ("no gh call at all"), which is a PROXY for
# the property and stopped tracking it: since your-org/nexus-code#1491 the
# hand-off asks, BEFORE it arms anything, whether the comment target actually
# contains the issue — one READ, on a refusal path that then posts nothing. A
# byte count cannot tell a read from a write, so it would report this refusal
# as "a comment was posted". Assert the PROPERTY, in both directions: no write
# of any kind was made, and the only call that WAS made is the pre-flight read
# — so this cannot pass by the capture happening to be empty.
assert_eq  "#1095 …and NO comment was posted (no POST / PATCH / comment call captured)" \
    "$(grep -cE -- '-X (POST|PATCH|PUT|DELETE)|/comments' "$GH_CAPTURE" || true)" "0"
assert_eq  "#1095 …and the ONLY gh call was the #1491 comment-target pre-flight READ" \
    "$(grep -vcE -- '-X GET /repos/[^ ]+/issues/[0-9]+' "$GH_CAPTURE" || true)" "0"
# The absence-derived text must be GONE from this path, not merely
# unasserted. This is the inverse of the three assertions retargeted above:
# they asserted this text WAS emitted here.
assert_not_contains "#1095 …and no absence-derived recommendation exists to read" \
    "$(spawn_req_body)" "severity-blind"

echo '=== #1095 item 3 (GRAMMAR): a BODY-only disposition is REFUSED, and SAID so ==='
# The issue asks for the grammar to be validated, not just the presence:
# "a spawn brief once wrote prose into that reserved two-token field, which
# ordinary workers also parse." The three states are NOT interchangeable and
# an author told only "it is missing" edits the wrong line — the whole cost
# of this defect class is a person having to guess what a field would have
# said.
#
# This is also where the pre-#1095 `#599` fixture went. It appended
# `Disposition: no-further-pass` to the BODY and was read as a stated
# disposition by a test whose name claimed it was testing the stated case;
# measured, `_skeptic_stated_disposition` calls that `body`, and `ng`'s own
# rule is that only a frontmatter field governs. So the same bytes are still
# exercised — now asserting what they actually mean.
reset_mocks
BODYDISP_REPORT="$FAKE_NEXUS/reports/nexus_2026-08-28_144500_bodydisp.md"
write_report "$BODYDISP_REPORT" ""
printf '\nDisposition: no-further-pass\n' >> "$BODYDISP_REPORT"
assert_eq "#1095 FIXTURE: the disposition really is in the BODY, not the frontmatter" \
    "$(grep -cE '^disposition:' "$BODYDISP_REPORT")" "0"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="bodydisp-worker"
run_ng stdout stderr rc wrap-up 77 "$BODYDISP_REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq "#1095 GRAMMAR: a BODY-only disposition does NOT govern — refused" "$rc" "1"
assert_contains "#1095 …and the refusal says WHERE it found one, so the author edits the right line" \
    "$stderr" "found in the body"
assert_eq "#1095 …and files no request" "$(count_spawn_reqs)" "0"

echo '=== #1095 item 3 (GRAMMAR): PROSE in the field is REFUSED as UNREADABLE ==='
# Distinct from `absent`: the author DID write something, so telling them
# the field is missing points at the wrong problem entirely.
reset_mocks
PROSE_REPORT="$FAKE_NEXUS/reports/nexus_2026-08-28_145000_prose.md"
write_report "$PROSE_REPORT" "fix at source, then hand back to the orchestrator"
assert_eq "#1095 FIXTURE: prose really is in the frontmatter field" \
    "$(grep -cE '^disposition: fix at source' "$PROSE_REPORT")" "1"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="prose-worker"
run_ng stdout stderr rc wrap-up 77 "$PROSE_REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq "#1095 GRAMMAR: prose in a reserved two-token field is REFUSED" "$rc" "1"
# MEASURED, AND IT IS NOT THE LAYER THIS BLOCK FIRST ASSERTED. Prose is
# caught EARLIER than the skeptic step, by #836's existing value gate
# running as `ng wrap-up`'s `report-check` pre-flight — so it is refused on
# EVERY wrap-up, not merely on the require path, and never reaches
# `_wrapup_skeptic_step` at all. Asserting the skeptic-step wording here
# would have been asserting a message this input cannot produce.
assert_contains "#1095 …by the report-check pre-flight, naming the field" "$stderr" \
    "frontmatter field: disposition"
assert_contains "#1095 …named as UNREADABLE, not as absent" "$stderr" \
    "unreadable in frontmatter"
assert_contains "#1095 …and pointing at the LINE, so the author edits the right one" \
    "$stderr" "disposition: fix at source"
assert_eq "#1095 …and files no request" "$(count_spawn_reqs)" "0"

# `--allow-stub` MUST NOT OPEN A HOLE. It is the documented override for an
# intentional checkpoint and it forwards `--allow-todo` to `report-check` —
# so the question is whether the grammar gate rides on the placeholder gate
# it relaxes. Measured: it does not. Both gates are independent and the
# prose is refused identically with and without the flag.
#
# THE HONEST CONSEQUENCE, recorded because the alternative is a comment
# claiming a coverage this suite does not have: `_wrapup_skeptic_step`'s
# require arm carries an `unreadable` case, and it is NOT REACHABLE from
# `ng wrap-up` for a frontmatter-unreadable value, because report-check
# always refuses first — as the two assertions below establish. That arm is
# defence in depth for the direct callers (`test-skeptic-channel.sh` drives
# `_wrapup_skeptic_step` by sourcing `ng`) and for any future caller that
# does not run the pre-flight. It is not claimed to be exercised here.
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="prose2-worker"
run_ng stdout stderr rc wrap-up 77 "$PROSE_REPORT" --repo override-org/override-repo \
    --allow-stub --skeptic-decision require --skeptic-rationale "touched shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq "#1095 GRAMMAR: --allow-stub does NOT get prose through" "$rc" "1"
assert_contains "#1095 …the grammar gate does not ride on the placeholder gate it relaxes" \
    "$stderr" "unreadable in frontmatter"
assert_eq "#1095 …and still files no request" "$(count_spawn_reqs)" "0"

echo '=== #1095 CONTROL: a stated disposition still FILES the request ==='
# Without this the refusal above is satisfied by a build that refuses
# EVERY require wrap-up — which would be a worse defect than the one being
# fixed, and invisible to a one-sided negative control.
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="disp-worker"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched shared infra"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq "#1095 CONTROL: a stated disposition wrap-up exits 0" "$rc" "0"
assert_eq "#1095 CONTROL: …and the request IS filed" "$(count_spawn_reqs)" "1"

echo '=== #1095 SCOPE CONTROL: a NON-require wrap-up is UNAFFECTED ==='
# The refusal is scoped to the require arm ON PURPOSE. Measured against the
# live corpus (677 reports, 2026-09-01), 256 state no readable frontmatter
# disposition — so a wrap-up-wide requirement would refuse 38% of the
# corpus and every future worker report. Nothing derives anything from an
# absence when no request is being filed, so nothing may refuse.
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="scope-worker"
run_ng stdout stderr rc wrap-up 77 "$NODISP_REPORT" --repo override-org/override-repo
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq "#1095 SCOPE: a plain wrap-up with no disposition still exits 0" "$rc" "0"
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="scope-deny-worker"
run_ng stdout stderr rc wrap-up 77 "$NODISP_REPORT" --repo override-org/override-repo \
    --skeptic-decision deny --skeptic-rationale "trivial docs-only edit"
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq "#1095 SCOPE: a DENY wrap-up with no disposition still exits 0" "$rc" "0"
assert_eq "#1095 SCOPE: …and files no request either way" "$(count_spawn_reqs)" "0"

echo '=== #1095 item 2: report-init EMITS the field, and the sentinel FAILS ==='
# `report-init` MANUFACTURED the absence: it wrote a skeleton with no
# `disposition:`, so every report was in the escalating state from creation
# until its author happened to fill the field in — and one of the depth-2
# escalations on #1095 fired off a bare skeleton. Emitting an explicit
# sentinel makes the omission VISIBLE instead of silent.
reset_mocks
run_ng stdout stderr rc report-init d1095 --reports-dir "$FAKE_NEXUS/reports"
assert_eq "#1095 report-init exits 0" "$rc" "0"
INIT_REPORT="$stdout"
assert_file_exists "#1095 report-init wrote the skeleton" "$INIT_REPORT"
assert_contains "#1095 …and the skeleton now CARRIES the disposition key" \
    "$(<"$INIT_REPORT")" "disposition: TODO"
# The sentinel must FAIL validation, or it is decoration. No new parser was
# added for this: #836's existing write-time gate already refuses a
# non-token value, which is why `TODO` was chosen over a bare empty value.
reset_mocks
run_ng stdout stderr rc report-check "$INIT_REPORT"
assert_eq "#1095 …and the sentinel FAILS report-check" "$rc" "1"
assert_contains "#1095 …with a message naming the field" "$stderr" \
    "frontmatter field: disposition"
# `--allow-todo` is the checkpoint flag workers use on partial reports. It
# must NOT wave this through, or the sentinel is escapable by the exact
# flag an in-progress report is checked with.
reset_mocks
run_ng stdout stderr rc report-check "$INIT_REPORT" --allow-todo
assert_eq "#1095 …and --allow-todo does NOT wave the sentinel through" "$rc" "1"
assert_contains "#1095 …still naming the field under --allow-todo" "$stderr" \
    "frontmatter field: disposition"

echo '=== #1095 item 2: WRAP-UP advises on absence; report-check stays SILENT (#684) ==='
# STAGED, NOT SHIPPED AS A REFUSAL, and the number is the reason: 256 of
# the 677 reports in the live corpus (2026-09-01) state no readable
# frontmatter disposition, and `cmd_report_check` is `ng wrap-up`'s own
# pre-flight — so a hard requirement here would not fail a lint, it would
# block the hand-off verb every worker in this nexus runs. The advisory
# makes the omission visible on the hand-written path (which the
# `report-init` half cannot reach) without that blast radius.
reset_mocks
run_ng stdout stderr rc report-check "$NODISP_REPORT"
assert_eq "#1095 an absent disposition does NOT fail report-check by default" "$rc" "0"
# your-org/nexus-code#684 — AND report-check MUST SAY NOTHING. This assertion is a
# MIRROR of `test-ng-report-check.sh` Test 13, planted here deliberately: an
# earlier cut of #1095 emitted the advisory from `cmd_report_check` and took that
# suite from 105/0 to 103/2 on a test blob that was byte-IDENTICAL at both refs.
# Neither `guards-for-diff` (that suite declares no population, so it is one of
# the 365 of 390 INVISIBLE to the index) nor this suite could see it. Now this
# suite can: re-emitting the advisory from report-check reddens BOTH.
assert_not_contains "#684 …and report-check says NOTHING about disposition on an ABSENT field" \
    "$stderr" "disposition"
# The advisory the worker still needs lives on the HAND-OFF verb, which is where
# #1095's refusal bites and where the author is still present to fix it.
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="adv-nodisp-worker"
run_ng stdout stderr rc wrap-up 77 "$NODISP_REPORT" --repo override-org/override-repo
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq "#1095 a plain wrap-up on a disposition-less report still SUCCEEDS" "$rc" "0"
assert_contains "#1095 …and IT is where the advisory is said, naming the field" "$stderr" \
    "carries no frontmatter \`disposition:\` field"
# The advisory must be FALSIFIABLE rather than decorative: the strict form
# it advertises has to actually exist and actually refuse.
reset_mocks
MONITOR_REPORT_REQUIRE_DISPOSITION=1 run_ng stdout stderr rc report-check "$NODISP_REPORT"
assert_eq "#1095 …and MONITOR_REPORT_REQUIRE_DISPOSITION=1 makes it a REFUSAL" "$rc" "1"
assert_contains "#1095 …naming the field, and naming it as ABSENT" "$stderr" \
    "frontmatter field: disposition (must be no-further-pass|second-pass; absent"
# CONTROL — a compliant report must pass BOTH, or the two assertions above
# are satisfied by a build that refuses everything.
reset_mocks
run_ng stdout stderr rc report-check "$REPORT"
assert_eq "#1095 CONTROL: a compliant report passes report-check" "$rc" "0"
assert_not_contains "#1095 CONTROL: …with no advisory" "$stderr" "ADVISORY"
reset_mocks
MONITOR_REPORT_REQUIRE_DISPOSITION=1 run_ng stdout stderr rc report-check "$REPORT"
assert_eq "#1095 CONTROL: …and passes the STRICT form too" "$rc" "0"

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
reset_mocks
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
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk815-f6b"
mkdir -p "$SK_PENDING" "$STATE_DIR"
# THE #1432 FINDING, recorded where it was found. This control used to run
# on the state the PREVIOUS case left (its `reset_state` was undefined — rc
# 127, untested), so it inherited that case's action log. With a REAL reset
# there is no action log at all, and #825's fail-CLOSED rule then ARMS
# ("could not read the chain" is not "no chain event"), so the banner never
# printed and the control went red: 1 of the 10 fixed call sites changed an
# assertion's outcome. The control's claim is "no chain event SINCE the
# resolve", which needs a readable, EMPTY log — planted here explicitly.
: > "$STATE_DIR/action-log.jsonl"
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
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk825-ok"
sk825_fixture sk825-ok
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "working probe control"
assert_file_exists "#825 CONTROL: working probe arms the gate" "$SK_PENDING/sk825-ok"

echo '=== #825 M1: jq unavailable → gate must HOLD, not be suppressed ==='
reset_mocks
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
reset_mocks
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
reset_mocks
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
reset_mocks
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
reset_mocks
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
reset_mocks
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
reset_mocks
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk825.dot"
mkdir -p "$SK_PENDING" "$STATE_DIR"
# your-org/nexus-code#941 — the marker KEY is now injective, so a dotted name
# no longer collapses to `sk825_dot`. #825's point is untouched: the action log
# still stores the RAW name while the file is keyed, and the code must
# reconcile the two. Computed rather than hard-coded, because a literal key in
# a test is the brittleness that made this update necessary.
_M4_KEY=$(wk_encode 'sk825.dot')
printf 'resolved long ago\n' > "$SK_PENDING/.${_M4_KEY}.cleared-rationale"
touch -d '@1000000000' "$SK_PENDING/.${_M4_KEY}.cleared-rationale"
printf '{"ts":"%s","agent":"monitor","event":"skeptic-verdict","window":"s","target-window":"sk825.dot","orig-window":"sk825.dot","verdict":"credible"}\n' \
    "$(date -Is -d '@1000001000')" > "$STATE_DIR/action-log.jsonl"
run_ng stdout stderr rc wrap-up 77 "$REPORT" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "raw-vs-sanitised join"
assert_file_exists "#825 M4 a RAW-named later verdict is seen → gate armed" \
                "$SK_PENDING/$_M4_KEY"
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
write_report "$HON_REPORT" ""    # #1095: ditto — the BODY line is the fixture
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
# $NODISP_REPORT states no disposition at all. There is no second party, so
# there is nothing to dispute; the recommendation is purely count-derived.
# your-org/nexus-code#1095 — this was `$REPORT` until the default fixture
# became a COMPLIANT report. `$REPORT` now states `second-pass`, which is a
# concurring second party and would have quietly turned this case into the
# `second-pass-author-concurs` case tested immediately above — passing, on
# the wrong arm, with a label that no longer described it.
run_ng stdout stderr rc wrap-up 77 "$NODISP_REPORT" --repo override-org/override-repo \
    --skeptic-role --skeptic-target sk-reviewed-worker --skeptic-depth 1 \
    --skeptic-verdict check --skeptic-findings 4
unset MOCK_TMUX MOCK_TMUX_WINDOW
assert_eq "#685 no-disposition wrap-up exits 0" "$rc" "0"
body=$(spawn_req_body)
assert_contains "#685 a report stating NOTHING cannot be disputing anything" \
    "$body" "second-pass-no-disposition-stated"
assert_not_contains "#685 …and is NOT labelled a dispute either" "$body" "second-pass-dispute"
# ── #684/#599 RETARGETED HERE FROM THE WORKER PATH (#1095) ──────────────
#
# These three ran on a WORKER require wrap-up until #1095, where they
# certified that a request could be composed out of a missing field. That
# path now refuses. This is the topology where an absent disposition may
# still legally reach a request: the skeptic STATED A COUNT
# (`--skeptic-findings 4`), so it has reported a measurement and #881's
# boundary — never read a pass that stated NEITHER as clean — is satisfied.
# The absence that remains is of the author's own view, and the properties
# are unchanged:
#   * #684 — `absent` must be NAMED, never rendered as the bare `-` that
#     was indistinguishable from "the parser failed on a field that WAS
#     there". One means "the author had no view", the other means "go read
#     the disposition line". They are different instructions.
#   * #599 — a recommendation derived from a findings COUNT must confess
#     that a count cannot weigh severity, rather than presenting itself as
#     a conclusion.
assert_contains "#684 (retargeted from the worker path, #1095) an absence is NAMED, not a bare dash" \
    "$body" "report-stated-disposition: absent"
assert_contains "#684 …and the request says where that answer came from" \
    "$body" "source: none"
assert_contains "#599 …and the derived recommendation flags its own blindness" \
    "$body" "severity-blind"
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

# ===========================================================================
# your-org/nexus-code#984 — a re-publication of an ALREADY-VALIDATED report
# must not re-arm the require gate
# ===========================================================================
#
# THE LIVE INSTANCE, not a constructed one. A worker wrapped up three times
# against a report whose verdict was already recorded; each wrap-up re-armed
# the pending marker and filed a fresh `spawn-skeptic` request naming the same
# window, the same issue and the same report path, differing only in the asset
# sha. The reviewer — already live, already returned `no-further-pass` — was
# re-pinned twice and spent a full review cycle establishing that the branch
# and `dev` were BYTE-IDENTICAL, i.e. that there was nothing to review.
#
# WHY #815's FIX DOES NOT COVER THIS, which is the whole diagnosis. #815
# stopped a wrap-up re-arming a gate an ORCHESTRATOR had resolved, and it
# could do that because `ng skeptic resolve` leaves a durable record
# (`.<key>.cleared-rationale`). A VERDICT leaves a `rm -f`. The suppression
# logic is not weaker on the verdict path — it is BLIND there, because a
# deletion is not evidence of anything. The only lifecycle transition with a
# durable record was the only one the re-arm check could see.
#
# So the fix is to give the verdict discharge the same durable treatment, and
# to give the record the field it never carried: WHAT the obligation is about.
# The subject is the report's CONTENT HASH, deliberately — see the block
# header in `ng` for why the ISSUE would be the wrong key (a worker re-wraps
# one issue many times as work progresses, and each of those genuinely needs
# validating; suppressing on the issue would turn `require` into "required
# once per issue", which is a way to DODGE validation — #977 from the other
# side).
#
# Both arms are asserted, because "the second request was not filed" alone is
# not the property: an `ng` that never armed anything would pass that.
SK984_PENDING="$STATE_DIR/skeptic/pending"

echo '=== #984: CONTROL — a first-pass require ARMS, and RECORDS ITS SUBJECT ==='
reset_mocks
R984="$FAKE_NEXUS/reports/nexus_2026-05-12_100000_artefact.md"
write_report "$R984"
R984_SHA=$(sha256sum < "$R984" | awk '{print $1}')
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk984"
run_ng stdout stderr rc wrap-up 984 "$R984" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched the kill path"
assert_eq          "#984 CONTROL: require wrap-up exits 0" "$rc" "0"
assert_file_exists "#984 CONTROL: marker armed"            "$SK984_PENDING/sk984"
assert_file_exists "#984 the arm RECORDS a subject beside the marker" \
                   "$SK984_PENDING/.sk984.ledger"
assert_contains    "#984 …and the subject is the report's CONTENT hash" \
                   "$(grep '^armed' "$SK984_PENDING/.sk984.ledger")" "$R984_SHA"
assert_eq          "#984 CONTROL: one spawn-skeptic request filed" \
                   "$(count_spawn_reqs)" "1"

echo '=== #984: a skeptic returns a verdict — the DISCHARGE is now RECORDED ==='
# Driven through the real role path. The reviewing skeptic wraps up its OWN
# report, which is a DIFFERENT file with a different hash — the subject in the
# ledger must come from the TARGET's arm record, not from whatever the
# reviewer happened to be holding. That is the difference between carrying a
# subject from birth and re-deriving one at the end (#963).
SK984_REV="$FAKE_NEXUS/reports/nexus_2026-05-12_110000_review.md"
write_report "$SK984_REV"
printf '\nreviewer notes, deliberately different bytes\n' >> "$SK984_REV"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-sk984"
run_ng stdout stderr rc wrap-up 984 "$SK984_REV" --repo override-org/override-repo \
    --skeptic-role --skeptic-target sk984 --skeptic-depth 1 \
    --skeptic-verdict credible --skeptic-findings 0
assert_eq "#984 the verdict wrap-up exits 0" "$rc" "0"
assert_no_file "#984 …and the verdict cleared the target's marker" "$SK984_PENDING/sk984"
assert_file_exists "#984 THE MISSING RECORD: the discharge is durable" \
                   "$SK984_PENDING/.sk984.ledger"
assert_contains "#984 …and names the artefact the obligation was armed for" \
                "$(grep '^discharged' "$SK984_PENDING/.sk984.ledger")" "$R984_SHA"
assert_contains "#984 …and the verdict that discharged it" \
                "$(grep '^discharged' "$SK984_PENDING/.sk984.ledger")" "credible"
# #963 suggestion 1 — the verdict EVENT carries a subject, not only a stamp.
assert_contains "#963 the skeptic-verdict event carries the subject it was armed for" \
                "$(disp_log_row skeptic-verdict)" "\"subject-armed-sha\":\"$R984_SHA\""
# The reviewer's own report hash must NOT be what got recorded — that would be
# a subject re-derived at wrap-up time rather than carried from the arm.
SK984_REV_SHA=$(sha256sum < "$SK984_REV" | awk '{print $1}')
assert_not_contains "#963 CONTROL: NOT the reviewer's own report hash" \
                "$(grep '^discharged' "$SK984_PENDING/.sk984.ledger")" "$SK984_REV_SHA"

echo '=== #984: THE FIX — re-wrapping the IDENTICAL report does NOT re-arm ==='
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk984"
run_ng stdout stderr rc wrap-up 984 "$R984" --repo override-org/override-repo \
    --no-comment --skeptic-decision require --skeptic-rationale "touched the kill path"
assert_eq "#984 the re-publication wrap-up still exits 0" "$rc" "0"
assert_no_file "#984 THE PROPERTY: no marker re-armed on identical bytes" \
               "$SK984_PENDING/sk984"
# The count alone is weak — Step 2b de-duplicates, so `1` reads the same
# whether the step ran and de-duped or never ran. Assert the step did not run:
# suppression must stop the PUSH signal to the orchestrator, not merely avoid
# a second file. (The same reasoning #815's block records, and the reason its
# assertion is copied here rather than referenced.)
assert_not_contains "#984 …and the spawn-skeptic request step did not run at all" \
                "$stdout" "spawn-skeptic request:"
assert_contains "#984 the suppression is LOUD, not silent" "$stdout" \
                "ALREADY VALIDATED"
assert_contains "#984 …and names the sha it matched, so a reader can check it" \
                "$stdout" "$R984_SHA"
assert_contains "#984 …and names the escape hatch" "$stdout" "--skeptic-rearm"
assert_contains "#984 …and tells the worker that EDITING the report re-arms" \
                "$stdout" "EDIT THE REPORT"
assert_contains "#984 the suppression is logged with a distinguishable detail" \
                "$(disp_log_row skeptic-rearm-suppressed)" "artefact-already-validated"
assert_contains "#984 …carrying the verdict that discharged it" \
                "$(disp_log_row skeptic-rearm-suppressed)" '"discharged-verdict":"credible"'

echo '=== #984: NEGATIVE CONTROL — a MATERIALLY EDITED report still arms ==='
# This is the arm that makes the fix a fix rather than a hole. Without it,
# `never re-arm again` would pass every assertion above.
printf '\n## Addendum\n\nRewrote the gate after the verdict.\n' >> "$R984"
R984_SHA2=$(sha256sum < "$R984" | awk '{print $1}')
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk984"
run_ng stdout stderr rc wrap-up 984 "$R984" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched the kill path"
assert_eq "#984 CONTROL: the edited-report wrap-up exits 0" "$rc" "0"
assert_file_exists "#984 CONTROL: ONE CHANGED BYTE re-arms the gate" \
                   "$SK984_PENDING/sk984"
assert_not_contains "#984 CONTROL: …and does NOT claim the artefact is validated" \
                "$stdout" "ALREADY VALIDATED"
assert_contains "#984 CONTROL: …and the new subject is recorded" \
                "$(grep '^armed' "$SK984_PENDING/.sk984.ledger")" "$R984_SHA2"
# The mirror of the suppression assertion above, and deliberately NOT a
# request COUNT. Step 2b has its own de-duplication (an UNRESOLVED request for
# this origin+depth already sits in the inbox from the first arm, so a second
# file is correctly not created), which means the count reads `1` both when
# the step ran and de-duped and when it never ran at all — the exact weak
# assertion #815's block warns about. What must be true is that the step RAN:
# suppression withholds the push signal, and an edited artefact must not have
# it withheld.
assert_contains "#984 CONTROL: the spawn-skeptic request step RAN for the new work" \
                "$stdout" "spawn-skeptic request:"

echo '=== #984: --skeptic-rearm overrides the suppression, on the record ==='
# Restore the validated bytes so the suppression WOULD fire, then override.
write_report "$R984"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk984"
run_ng stdout stderr rc wrap-up 984 "$R984" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched the kill path" \
    --skeptic-rearm "the report is unchanged but the branch it describes was force-pushed"
assert_eq "#984 deliberate re-arm exits 0" "$rc" "0"
assert_file_exists "#984 deliberate re-arm ARMS despite the identical artefact" \
                   "$SK984_PENDING/sk984"
assert_not_contains "#984 …and the suppression banner does NOT appear" \
                "$stdout" "ALREADY VALIDATED"
assert_contains "#984 …and the override is on the record with its reason" \
                "$(cat "$STATE_DIR/action-log.jsonl" 2>/dev/null)" \
                "the branch it describes was force-pushed"

echo '=== #984: the banner states the MARKER'"'"'S ACTUAL STATE, it does not assert one ==='
# Reachable and, before this, reported falsely:
#   arm(A) -> verdict discharges A -> arm(B) -> wrap up A again
# (a revert, or a second worker re-publishing the earlier artefact). The
# suppression correctly declines to re-arm and B's marker is STILL LIVE — this
# path never clears a marker. A flat "no marker is armed, so this window can
# retire" would then be the `SKIPPED (upload failed)` false-cause defect in a
# new place: a verb reporting the outcome it usually has rather than the one it
# just produced.
reset_mocks
R984C="$FAKE_NEXUS/reports/nexus_2026-05-12_130000_revert.md"
write_report "$R984C"
R984C_SHA=$(sha256sum < "$R984C" | awk '{print $1}')
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk984c"
# arm(A)
run_ng stdout stderr rc wrap-up 984 "$R984C" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched the kill path"
assert_file_exists "#984 revert: arm(A) armed" "$SK984_PENDING/sk984c"
# a verdict discharges A
SKC_REV="$FAKE_NEXUS/reports/nexus_2026-05-12_131000_revrev.md"
write_report "$SKC_REV"; printf '\nreviewer\n' >> "$SKC_REV"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-sk984c"
run_ng stdout stderr rc wrap-up 984 "$SKC_REV" --repo override-org/override-repo \
    --skeptic-role --skeptic-target sk984c --skeptic-depth 1 \
    --skeptic-verdict credible --skeptic-findings 0
assert_no_file "#984 revert: the verdict cleared A's marker" "$SK984_PENDING/sk984c"
# arm(B) — a materially edited report
printf '\n## B\n\nnew work\n' >> "$R984C"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk984c"
run_ng stdout stderr rc wrap-up 984 "$R984C" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched the kill path"
assert_file_exists "#984 revert: arm(B) re-armed on the edited artefact" "$SK984_PENDING/sk984c"
# revert to A and wrap up again — suppression fires while B's marker is LIVE
write_report "$R984C"
assert_eq "#984 revert: the reverted report really is artefact A again" \
    "$(sha256sum < "$R984C" | awk '{print $1}')" "$R984C_SHA"
run_ng stdout stderr rc wrap-up 984 "$R984C" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched the kill path"
assert_contains "#984 revert: the suppression still fires on artefact A" \
    "$stdout" "ALREADY VALIDATED"
assert_file_exists "#984 revert: THE PROPERTY — B's live marker is UNTOUCHED" \
    "$SK984_PENDING/sk984c"
assert_contains "#984 revert: …and the banner SAYS the marker is live" \
    "$stdout" "PENDING MARKER IS ALREADY LIVE"
assert_not_contains "#984 revert: …and does NOT claim the window can retire" \
    "$stdout" "so this window can retire"
assert_contains "#984 revert: …naming that this path never releases an obligation" \
    "$stdout" "it never"

echo '=== #984: DOUBT ARMS — an unhashable artefact suppresses NOTHING ==='
# The direction-of-caution assertion. Every doubt in this path (no sha256
# tool, an unreadable report, a missing ledger, a malformed line) must yield
# "no match" and arm. A suppression that fired on doubt would be a way to skip
# validation by breaking the probe — the failure this whole batch is about,
# arriving through the fix for it.
reset_mocks
R984B="$FAKE_NEXUS/reports/nexus_2026-05-12_120000_nosubject.md"
write_report "$R984B"
mkdir -p "$SK984_PENDING"
# A ledger whose lines name no artefact — the shape a hand-edit or a
# truncated write would leave.
printf 'discharged\t-\t2026-05-12T00:00:00\tcredible\t984\tsk-x\n' \
    > "$SK984_PENDING/.sk984b.ledger"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk984b"
run_ng stdout stderr rc wrap-up 984 "$R984B" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched the kill path"
assert_eq "#984 doubt: wrap-up exits 0" "$rc" "0"
assert_file_exists "#984 DOUBT ARMS: a subject-less ledger entry suppresses nothing" \
                   "$SK984_PENDING/sk984b"
assert_not_contains "#984 …and claims nothing about validation" \
                "$stdout" "ALREADY VALIDATED"
unset MOCK_TMUX MOCK_TMUX_WINDOW

# ===========================================================================
# F1 / F2 — the two regressions the #1067 skeptic found, which eleven mutants
# and 674 assertions all missed (your-org/nexus-code#977 skeptic pass)
# ===========================================================================
#
# Both are about ATTRIBUTION: which artefact a discharge is a statement ABOUT.
# The first version of this fix inferred it from RECENCY — the last `armed`
# line at the moment the verdict landed — which is `#963`'s own defect ("a
# value read off a stamp long after the thing it stamped stopped being true")
# reintroduced by `#963`'s fix.
#
# THE RULE THAT REPLACES THE INFERENCE: a discharge may name an artefact only
# when exactly ONE was armed since the last discharge on that key. Otherwise
# state cannot say which one the reviewer saw, and the record says so and names
# nothing — so nothing is suppressed later. Doubt arms, as everywhere else on
# this gate.
#
# Deliberately NOT attempted: pinning the subject at SPAWN time. That would
# often resolve the ambiguity, and it is a spawn-time stamp — `#963`'s exact
# subject — which goes stale the moment a reviewer is re-tasked by paste. The
# honest boundary is recorded here rather than guessed at.

echo '=== #977-skeptic F1: a discharge must not be attributed by RECENCY ==='
# 1. W arms for R1 (the skeptic is pinned to R1)
# 2. W re-wraps a LATER artefact R2 while the gate is still live
# 3. the verdict lands — it reviewed R1
# 4. W re-wraps R2 (NEVER reviewed)  -> must ARM; skipping it is validation lost
# 5. W re-wraps R1 (WAS reviewed)    -> must ARM under the ambiguity rule
#
# Step 2 is not exotic: #984's own live instance is a worker re-wrapping while
# a marker is live, and two more happened on this board the same night.
reset_mocks
F1_R1="$FAKE_NEXUS/reports/nexus_2026-05-13_100000_f1-r1.md"
F1_R2="$FAKE_NEXUS/reports/nexus_2026-05-13_110000_f1-r2.md"
write_report "$F1_R1"
write_report "$F1_R2"; printf '\n## R2\n\nmaterially later work.\n' >> "$F1_R2"
F1_R1_SHA=$(sha256sum < "$F1_R1" | awk '{print $1}')
F1_R2_SHA=$(sha256sum < "$F1_R2" | awk '{print $1}')
assert_eq "F1 fixture: R1 and R2 really are different artefacts" \
    "$( [[ "$F1_R1_SHA" != "$F1_R2_SHA" ]] && echo differ || echo same )" "differ"

export MOCK_TMUX=1 MOCK_TMUX_WINDOW="wf1"
run_ng stdout stderr rc wrap-up 977 "$F1_R1" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "arm one, the artefact under review"
assert_file_exists "F1 step 1: armed for R1" "$SK984_PENDING/wf1"
run_ng stdout stderr rc wrap-up 977 "$F1_R2" --repo override-org/override-repo \
    --no-comment --skeptic-decision require --skeptic-rationale "a later artefact, gate still live"
assert_file_exists "F1 step 2: still armed after re-wrapping R2" "$SK984_PENDING/wf1"

# 3. the verdict — it reviewed R1
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-wf1"
F1_REV="$FAKE_NEXUS/reports/nexus_2026-05-13_120000_f1-rev.md"
write_report "$F1_REV"; printf '\nreviewer\n' >> "$F1_REV"
run_ng stdout stderr rc wrap-up 977 "$F1_REV" --repo override-org/override-repo \
    --skeptic-role --skeptic-target wf1 --skeptic-depth 1 \
    --skeptic-verdict credible --skeptic-findings 0
assert_eq "F1 step 3: the verdict wrap-up exits 0" "$rc" "0"
# THE PROPERTY. R2 was never reviewed by anyone; a record naming it is a claim
# nobody made, and it is the claim that later suppresses R2's validation.
_f1_ledger=$(cat "$SK984_PENDING"/.wf1.* 2>/dev/null)
assert_not_contains "F1 THE PROPERTY: the ledger does NOT record R2 as discharged" \
    "$(printf '%s\n' "$_f1_ledger" | grep '^discharged' || true)" "$F1_R2_SHA"

# 4. R2 was never reviewed -> re-wrapping it must ARM.
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="wf1"
run_ng stdout stderr rc wrap-up 977 "$F1_R2" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "R2 has never been reviewed"
assert_file_exists "F1 step 4: an UNREVIEWED artefact ARMS (validation not skipped)" \
    "$SK984_PENDING/wf1"
assert_not_contains "F1 step 4: …and is not announced as validated" \
    "$stdout" "ALREADY VALIDATED"

echo '=== #977-skeptic F1b: the ambiguity counter RESETS at each discharge ==='
# The mutant that defeated the skeptic's first candidate remedy, kept as a
# guard. Counting distinct armed shas WITHOUT resetting at a discharge makes a
# window permanently "ambiguous" from its second DISTINCT artefact onward —
# nothing is attributed again, so nothing is ever suppressed again, which
# re-introduces #984 by the back door.
#
# THE ARTEFACTS MUST DIFFER BETWEEN ROUNDS. A first draft of this guard ran two
# rounds over the SAME report and passed against a mutant with the reset
# removed — the set of distinct open arms is {R} either way, so it exercised
# nothing. Recorded because a vacuous guard beside a real fix is exactly what
# this whole batch is about, and only the mutant found it.
#
# Two rounds, two DIFFERENT artefacts. Round 2 attributes only if the scan
# resets — which is reliable here only because arms and discharges share ONE
# file in EVENT ORDER. Split across two files this needs a clock compare, and a
# lexicographic ISO compare is wrong across a UTC-offset change.
reset_mocks
F1B_A="$FAKE_NEXUS/reports/nexus_2026-05-13_150000_f1b-a.md"
F1B_B="$FAKE_NEXUS/reports/nexus_2026-05-13_152000_f1b-b.md"
F1B_REV="$FAKE_NEXUS/reports/nexus_2026-05-13_151000_f1b-rev.md"
write_report "$F1B_A"
write_report "$F1B_B"; printf '\n## round two\n\ndifferent bytes.\n' >> "$F1B_B"
write_report "$F1B_REV"; printf '\nreviewer\n' >> "$F1B_REV"
F1B_A_SHA=$(sha256sum < "$F1B_A" | awk '{print $1}')
F1B_B_SHA=$(sha256sum < "$F1B_B" | awk '{print $1}')
assert_eq "F1b fixture: the two rounds really use DIFFERENT artefacts" \
    "$( [[ "$F1B_A_SHA" != "$F1B_B_SHA" ]] && echo differ || echo same )" "differ"
f1b_round() {   # f1b_round <report> <n>
    export MOCK_TMUX=1 MOCK_TMUX_WINDOW="wf1b"
    run_ng stdout stderr rc wrap-up 977 "$1" --repo override-org/override-repo \
        --no-comment --skeptic-decision require --skeptic-rationale "round $2 of the repeat case"
    export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-wf1b$2"
    run_ng stdout stderr rc wrap-up 977 "$F1B_REV" --repo override-org/override-repo \
        --skeptic-role --skeptic-target wf1b --skeptic-depth 1 \
        --skeptic-verdict credible --skeptic-findings 0
}
f1b_round "$F1B_A" 1
assert_contains "F1b round 1: the discharge is ATTRIBUTED to artefact A" \
    "$(grep '^discharged' "$SK984_PENDING/.wf1b.ledger" 2>/dev/null)" "$F1B_A_SHA"
f1b_round "$F1B_B" 2
# THE PROPERTY. Without the reset, round 2 sees {A, B} — two distinct open
# arms — and records `ambiguous`, so B is never attributed and can never be
# suppressed. With the reset it sees {B} alone.
assert_contains "F1b THE PROPERTY: round 2 ATTRIBUTES artefact B (the counter reset)" \
    "$(grep '^discharged' "$SK984_PENDING/.wf1b.ledger" 2>/dev/null)" "$F1B_B_SHA"
assert_eq "F1b …and NO discharge was recorded as ambiguous" \
    "$(awk '/ambiguous/ { n++ } END { print n+0 }' "$SK984_PENDING/.wf1b.ledger" 2>/dev/null)" "0"
# `grep -c` prints `0` AND exits 1 on no match, so a `|| echo 0` fallback
# appends a SECOND zero and the comparison sees $'0\n0'. An earlier draft of
# this block did exactly that. `awk` prints one number and exits 0 either way.
assert_eq "F1b CONTROL: exactly two discharges, one per round" \
    "$(awk '/^discharged/ { n++ } END { print n+0 }' "$SK984_PENDING/.wf1b.ledger" 2>/dev/null)" "2"
# …and the consequence: B, having been attributed, now suppresses.
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="wf1b"
run_ng stdout stderr rc wrap-up 977 "$F1B_B" --repo override-org/override-repo \
    --no-comment --skeptic-decision require --skeptic-rationale "B was validated in round 2"
assert_contains "F1b …so re-publishing B is suppressed (#984 still works in round 2)" \
    "$stdout" "ALREADY VALIDATED"

# ===========================================================================
# your-org/nexus-code#961 — ONE WINDOW, TWO TASKS: a verdict on A must not
# clear the obligation for B
# ===========================================================================
#
# THE FIXTURE THE ISSUE ASKS FOR BY NAME: "a verdict on task A must not clear
# the obligation for task B on the same window, and a guard should assert it
# with a two-task fixture rather than describe it." No test in this repo
# planted two tasks on one window before this one — every skeptic fixture used
# a fresh window per case, so the invariant was documented in `ng` and had zero
# coverage.
#
# Measured basis: window `wrapup` took 12 verdicts across 7 distinct issues
# against ONE flag. Any one of them cleared it for the other six.
echo '=== #961: a verdict on task A must NOT clear task B on the same window ==='
reset_mocks
T61_A="$FAKE_NEXUS/reports/nexus_2026-05-14_100000_t61-a.md"
T61_B="$FAKE_NEXUS/reports/nexus_2026-05-14_110000_t61-b.md"
write_report "$T61_A"
write_report "$T61_B"; printf '\n## B\n\na second, unrelated task.\n' >> "$T61_B"
T61_A_SHA=$(sha256sum < "$T61_A" | awk '{print $1}')
T61_B_SHA=$(sha256sum < "$T61_B" | awk '{print $1}')
assert_eq "#961 fixture: the two tasks really are different artefacts" \
    "$( [[ "$T61_A_SHA" != "$T61_B_SHA" ]] && echo differ || echo same )" "differ"

export MOCK_TMUX=1 MOCK_TMUX_WINDOW="w961"
run_ng stdout stderr rc wrap-up 977 "$T61_A" --repo override-org/override-repo \
    --no-comment --skeptic-decision require --skeptic-rationale "task A needs a pass"
run_ng stdout stderr rc wrap-up 977 "$T61_B" --repo override-org/override-repo \
    --no-comment --skeptic-decision require --skeptic-rationale "task B needs a pass too"
# Both armed, one window. The MARKER cannot express this — its content is `1`.
assert_eq "#961 setup: the window owes TWO artefacts" \
    "$(run_ng_out skeptic-obligations w961 | sed -n 's/.*outstanding=\([0-9]*\).*/\1/p')" "2"

# A reviewer returns a verdict and SAYS WHAT IT READ — task A.
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-w961"
T61_REV="$FAKE_NEXUS/reports/nexus_2026-05-14_120000_t61-rev.md"
write_report "$T61_REV"; printf '\nreviewed task A only.\n' >> "$T61_REV"
run_ng stdout stderr rc wrap-up 977 "$T61_REV" --repo override-org/override-repo \
    --skeptic-role --skeptic-target w961 --skeptic-depth 1 \
    --skeptic-verdict credible --skeptic-findings 0 --skeptic-subject "$T61_A"
assert_eq "#961 the verdict wrap-up exits 0" "$rc" "0"

# THE PROPERTY. Task B was reviewed by nobody. It must still be owed.
_t61_owed=$(run_ng_out skeptic-obligations w961)
assert_eq "#961 THE PROPERTY: task B is STILL outstanding after a verdict on A" \
    "$(sed -n 's/.*outstanding=\([0-9]*\).*/\1/p' <<<"$_t61_owed")" "1"
assert_contains "#961 …and it is B that remains, named by its own artefact" \
    "$_t61_owed" "$T61_B_SHA"
# GUARD THE GUARD. `assert_not_contains` against an EMPTY string passes
# vacuously, and an `ng` that refused the whole probe produces exactly that —
# so the absence below would read as the property holding when nothing ran.
# Measured: this arm passed against dev, where the probe emits nothing at all.
assert_contains "#961 …(guard: the probe actually answered)" "$_t61_owed" "outstanding="
assert_not_contains "#961 …while A, which WAS reviewed, is discharged" \
    "$_t61_owed" "$T61_A_SHA"
# …and the operator-visible consequence: re-publishing B still ARMS, because
# nobody validated it. Suppressing it here is validation silently skipped.
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="w961"
run_ng stdout stderr rc wrap-up 977 "$T61_B" --repo override-org/override-repo \
    --no-comment --skeptic-decision require --skeptic-rationale "B was never reviewed"
assert_not_contains "#961 …so re-publishing B is NOT announced as already validated" \
    "$stdout" "ALREADY VALIDATED"
# CONTROL — A *was* validated, so re-publishing A IS suppressed. Without this
# the arm above would also pass against a build that simply never suppresses.
run_ng stdout stderr rc wrap-up 977 "$T61_A" --repo override-org/override-repo \
    --no-comment --skeptic-decision require --skeptic-rationale "A already has a verdict"
assert_contains "#961 CONTROL: re-publishing the VALIDATED artefact A is suppressed" \
    "$stdout" "ALREADY VALIDATED"
unset MOCK_TMUX MOCK_TMUX_WINDOW

# ===========================================================================
# your-org/nexus-code#963 — A STALE SPAWN STAMP MUST BE LOUD
# ===========================================================================
#
# `sk930` was spawned at 12:56:49 to review `procsafe`, was re-tasked by paste,
# and filed 12 verdicts across FOUR issues — every one recording
# `target-window=procsafe`, and every one CLEARING `procsafe`'s gate. One is
# confirmed by its own wrap-up asset URL (`sk930_…_955-recheck-…md` uploaded to
# `assets/895/`); the other 16 such pairs in the corpus cannot be classified
# from state at all, because a skeptic legitimately re-reviewing one target
# across several issues and a re-tasked one filing under a stale stamp produce
# IDENTICAL records.
#
# Nothing prompted for a correction and nothing validated the default, because
# a provenance stamp is always plausible. The cheap discriminator is the issue.
echo '=== #963: a verdict whose issue disagrees with the target'"'"'s last arm REFUSES ==='
reset_mocks
T63_R="$FAKE_NEXUS/reports/nexus_2026-05-14_130000_t63-r.md"
write_report "$T63_R"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="w963"
run_ng stdout stderr rc wrap-up 977 "$T63_R" --repo override-org/override-repo \
    --no-comment --skeptic-decision require --skeptic-rationale "w963 armed on issue 977"
assert_file_exists "#963 setup: w963 is armed" "$SK984_PENDING/w963"

export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-w963"
T63_REV="$FAKE_NEXUS/reports/nexus_2026-05-14_140000_t63-rev.md"
write_report "$T63_REV"; printf '\na verdict about OTHER work.\n' >> "$T63_REV"
run_ng stdout stderr rc wrap-up 999 "$T63_REV" --repo override-org/override-repo \
    --skeptic-role --skeptic-target w963 --skeptic-depth 1 \
    --skeptic-verdict credible --skeptic-findings 0
assert_eq "#963 THE PROPERTY: a verdict on a different issue REFUSES" "$rc" "1"
assert_contains "#963 …naming the disagreement as a stale stamp" \
    "$stderr" "STALE SPAWN STAMP"
assert_contains "#963 …and naming the remedy that carries information" \
    "$stderr" "--skeptic-subject"
# THE SIDE-EFFECT PROPERTY, and the reason the guard had to move ahead of every
# mutation: the refusal claims no marker was touched. Assert it.
assert_file_exists "#963 THE PROPERTY: the target's marker is UNTOUCHED by the refusal" \
    "$SK984_PENDING/w963"
# …and the way through is to say what you read. Same stamp, same disagreement.
run_ng stdout stderr rc wrap-up 999 "$T63_REV" --repo override-org/override-repo \
    --skeptic-role --skeptic-target w963 --skeptic-depth 1 \
    --skeptic-verdict credible --skeptic-findings 0 --skeptic-subject "$T63_R"
assert_eq "#963 …an ASSERTED subject clears the refusal" "$rc" "0"
assert_no_file "#963 …and the verdict then discharges the gate" "$SK984_PENDING/w963"
# CONTROL — the ordinary case must be untouched. A reviewer filing for the
# SAME issue the target armed on is never asked for anything.
reset_mocks
T63_C="$FAKE_NEXUS/reports/nexus_2026-05-14_150000_t63-c.md"
write_report "$T63_C"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="w963c"
run_ng stdout stderr rc wrap-up 977 "$T63_C" --repo override-org/override-repo \
    --no-comment --skeptic-decision require --skeptic-rationale "ordinary round"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="sk-w963c"
T63_CREV="$FAKE_NEXUS/reports/nexus_2026-05-14_160000_t63-crev.md"
write_report "$T63_CREV"; printf '\nsame issue.\n' >> "$T63_CREV"
run_ng stdout stderr rc wrap-up 977 "$T63_CREV" --repo override-org/override-repo \
    --skeptic-role --skeptic-target w963c --skeptic-depth 1 \
    --skeptic-verdict credible --skeptic-findings 0
assert_eq "#963 CONTROL: the same-issue case is unchanged, no flag needed" "$rc" "0"
assert_not_contains "#963 CONTROL: …and is never told about a stale stamp" \
    "$stderr" "STALE SPAWN STAMP"
unset MOCK_TMUX MOCK_TMUX_WINDOW

echo '=== #977-skeptic F2: a window must not sign its OWN artefact off ==='
# W holds a live obligation for its own report RA, then files a verdict ABOUT A
# DIFFERENT WINDOW. The discharge loop used to write a ledger line for the
# FILING window's key, taking the sha from that window's own arm — so W
# recorded `discharged RA` by itself, could never re-arm RA, and the banner
# cited a verdict about somebody else.
reset_mocks
F2_RA="$FAKE_NEXUS/reports/nexus_2026-05-13_130000_f2-ra.md"
write_report "$F2_RA"
F2_RA_SHA=$(sha256sum < "$F2_RA" | awk '{print $1}')
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="wf2"
run_ng stdout stderr rc wrap-up 977 "$F2_RA" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "wf2 owes a verdict on its own work"
assert_file_exists "F2 setup: wf2 armed for its own artefact RA" "$SK984_PENDING/wf2"

# wf2 now files a verdict ABOUT ANOTHER WINDOW.
F2_REV="$FAKE_NEXUS/reports/nexus_2026-05-13_140000_f2-rev.md"
write_report "$F2_REV"; printf '\nreview of otherwin\n' >> "$F2_REV"
run_ng stdout stderr rc wrap-up 977 "$F2_REV" --repo override-org/override-repo \
    --skeptic-role --skeptic-target otherwin --skeptic-depth 1 \
    --skeptic-verdict credible --skeptic-findings 0
assert_eq "F2: filing a verdict about another window exits 0" "$rc" "0"
# THE PROPERTY. Nothing reviewed RA. A discharge for wf2's own key naming RA is
# a self-signed validation.
_f2_ledger=$(cat "$SK984_PENDING"/.wf2.* 2>/dev/null)
assert_not_contains "F2 THE PROPERTY: wf2 did NOT record a discharge of its OWN artefact" \
    "$(printf '%s\n' "$_f2_ledger" | grep '^discharged' || true)" "$F2_RA_SHA"

# …and the consequence the operator would actually see.
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="wf2"
run_ng stdout stderr rc wrap-up 977 "$F2_RA" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "RA still needs an independent pass"
assert_file_exists "F2: RA still ARMS — it was never reviewed by anyone" \
    "$SK984_PENDING/wf2"
assert_not_contains "F2: …and the operator is NOT told it was already validated" \
    "$stdout" "ALREADY VALIDATED"
unset MOCK_TMUX MOCK_TMUX_WINDOW

# ---- your-org/nexus-code#1114: the composer must refuse to publish a teaser
#      that carries no claim --------------------------------------------------
#
# TWO LEVELS, and the first one exists because A REPLICATION IS NOT AN
# INVOCATION. `#1114`'s author found the ABBREVIATION class — `Dr.` `Fig.`
# `e.g.` `v2.` — precisely because they drove the real function instead of
# re-implementing "cut at the first period". A test that re-states the rule
# can only ever confirm the rule it re-states. So the table below BYTE-EXTRACTS
# the real functions out of `monitor/ng`, diff-verifies the extraction, and
# calls them.
echo '=== #1114 the boundary rule, driven by BYTE-EXTRACTING the real function ==='
X_DIR="$WORK/x1114"; mkdir -p "$X_DIR"
X_FN="$X_DIR/fn.sh"
x_start=$(grep -n '^_wrapup_boundary_safe()' "$NG_REAL" | cut -d: -f1)
x_end=$(awk -v s="$x_start" 'NR>=s && /^_wrapup_report_summary\(\)/ {f=1} f && /^}$/ {print NR; exit}' "$NG_REAL")
if [[ -n "$x_start" && -n "$x_end" ]]; then
    sed -n "${x_start},${x_end}p" "$NG_REAL" > "$X_FN"
else
    : > "$X_FN"
fi
# THE EXTRACTION IS ITSELF A CLAIM, so verify it rather than assume it. A
# mis-sliced region would `source` cleanly as a partial function and every row
# below would then measure something that is not in `ng` at all.
if [[ -s "$X_FN" ]] && diff <(sed -n "${x_start},${x_end}p" "$NG_REAL") "$X_FN" >/dev/null; then
    printf '  PASS: #1114 extraction of the real composer is byte-identical to monitor/ng\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: #1114 could not byte-extract the composer from %s (lines %s..%s)\n' \
        "$NG_REAL" "${x_start:-?}" "${x_end:-?}" >&2
    FAIL=$(( FAIL + 1 ))
fi
# shellcheck disable=SC1090
. "$X_FN"

x_report="$X_DIR/r.md"
# Drive the REAL function and report both its stdout and its rc — rc 2 is the
# refusal, and a test that only looked at stdout could not tell a refusal from
# a publish.
x_teaser() {
    printf '# R\n\n## Summary\n\n%s\n\n## What Was Done\n\nx\n' "$1" > "$x_report"
    _wrapup_report_summary "$x_report"
}
x_rc() {
    printf '# R\n\n## Summary\n\n%s\n\n## What Was Done\n\nx\n' "$1" > "$x_report"
    local _o _r=0
    _o=$(_wrapup_report_summary "$x_report") || _r=$?
    printf '%s' "$_r"
}

# Every row of #1114's table. Measured against the OLD rule these composed to
# `**BLOCK.` / `v2.` / `Dr.` / `Fig.` / `The gate drove 7 scenarios, e.g.` /
# `Bumped pandas to 2.1.` respectively — the published-nothing outcome.
R_BLOCK='**BLOCK. 2.1.250 is not safe to promote: the cc-harness gate fails on two of nine scenarios and the pin must stay at 2.1.240.'
assert_eq "#1114 row \`**BLOCK.\` — a bold marker before the period no longer truncates" \
    "$(x_teaser "$R_BLOCK")" "$R_BLOCK"
R_V2='v2. Superseding verdict: the earlier conclusion was wrong; the residual is a mechanism, not a count of four.'
assert_eq "#1114 row \`v2.\` — the #862 workaround shape survives the composer" \
    "$(x_teaser "$R_V2")" "$R_V2"
R_DR="Dr. Smith's pipeline was profiled and the bottleneck is the join, not the sort."
assert_eq "#1114 row \`Dr.\` — a title abbreviation is not a sentence end" \
    "$(x_teaser "$R_DR")" "$R_DR"
R_FIG='Fig. 3 was regenerated after the normaliser changed and the panel now matches the caption.'
assert_eq "#1114 row \`Fig.\` — a figure reference is not a sentence end" \
    "$(x_teaser "$R_FIG")" "$R_FIG"
R_EG='The gate drove 7 scenarios, e.g. idle-busy and autosuggest, and every one passed.'
assert_eq "#1114 row \`e.g.\` — a dotted abbreviation mid-sentence is not a sentence end" \
    "$(x_teaser "$R_EG")" "$R_EG"
R_VER='Bumped pandas to 2.1. 250 rows changed, all in the tail.'
assert_eq "#1114 row \`2.1.\` — a version token is not a sentence end" \
    "$(x_teaser "$R_VER")" "$R_VER"
# THE NO-PERIOD CONTROL. The issue asks for it by name: a summary with no
# `". "` at all must pass through UNMODIFIED. Without it, "never truncate"
# would pass this table just as well as the real rule.
R_NONE='Every scenario passed and the pin advanced cleanly with no outstanding work'
assert_eq "#1114 CONTROL: a summary with no sentence break passes through unmodified" \
    "$(x_teaser "$R_NONE")" "$R_NONE"
# THE OTHER CONTROL, and it is the one that stops the fix from being "never
# cut": a genuine sentence boundary must still cut. Both controls are needed —
# the first forbids over-cutting, this one forbids under-cutting, and a rule
# that fails either is not the rule.
assert_eq "#1114 CONTROL: a genuine sentence boundary DOES still cut" \
    "$(x_teaser 'Implemented ng wrap-up so workers can hand off in one verb. The second sentence must not appear.')" \
    'Implemented ng wrap-up so workers can hand off in one verb.'
assert_eq "#1114 an initial (\`J. Smith\`) is not a sentence end" \
    "$(x_teaser 'J. Smith reviewed the change and found no defects in the boundary rule at all.')" \
    'J. Smith reviewed the change and found no defects in the boundary rule at all.'

echo '=== #1114 the REFUSAL — the half that generalises past the boundary rule ==='
# A sharper boundary is still a heuristic; it can only be right about the cases
# someone thought of. These assert the floor, which is keyed on the OUTPUT
# alone and so does not care how the output was reached.
assert_eq "#1114 a one-word summary is REFUSED (rc 2), not published" "$(x_rc 'Done.')" "2"
assert_eq "#1114 …and the refused bytes are returned so the caller can quote them" \
    "$(x_teaser 'Done.')" "Done."
# THE FALSE-REFUSAL CONTROL. The floor must not second-guess an author's
# brevity: a short but COMPLETE summary lost nothing to the composer and is
# none of its business. Without this the "fix" would be a new way to fail.
assert_eq "#1114 CONTROL: a terse but complete summary is NOT refused" \
    "$(x_rc 'All tests pass.')" "0"
assert_eq "#1114 CONTROL: …and is published verbatim" \
    "$(x_teaser 'All tests pass.')" 'All tests pass.'

# EXTEND BEFORE REFUSE, and this is the control that stops the fix from
# becoming a new failure. `Fixed. …` and `Ok. …` cut at GENUINE sentence
# boundaries onto a single word — an entirely ordinary way to open a summary.
# Refusing there would convert a cosmetic teaser problem into a blocked
# wrap-up. The composer must reach into the next sentence instead, and refuse
# only when there is nothing to extend INTO.
assert_eq "#1114 a degenerate FIRST sentence extends rather than refusing" \
    "$(x_rc 'Fixed. The composer now refuses to publish a teaser that carries no claim, and says so loudly.')" "0"
assert_eq "#1114 …and the teaser carries the sentence that says something" \
    "$(x_teaser 'Fixed. The composer now refuses to publish a teaser that carries no claim, and says so loudly.')" \
    'Fixed. The composer now refuses to publish a teaser that carries no claim, and says so loudly.'
assert_eq "#1114 same for \`Ok.\` — a genuine boundary onto one word" \
    "$(x_rc 'Ok. Everything else in the pipeline is unchanged and the pin advanced cleanly.')" "0"
# …and the refusal still fires when there is nothing to extend into: the
# WHOLE Summary is the fragment. Without this pair, "always extend" and
# "always refuse" would each pass half the block and neither is the rule.
assert_eq "#1114 DISCRIMINATOR: refusal fires when the whole Summary is the fragment" \
    "$(x_rc 'Done.')" "2"

echo '=== #1114 END-TO-END: a degenerate teaser publishes NOTHING and exits 3 ==='
# Asserted against the COMMENT STORE — the mock's API-side record — not against
# ng's own stdout. A tool's success line is not evidence that anything was
# published; that is how #1114 stayed invisible in the first place, and it is
# why its author re-fetched the comment through `gh api` rather than believing
# `post-once`'s `UPDATED`.
reset_mocks
X_REPORT="$WORK/degenerate-report.md"
write_report "$X_REPORT"
perl -0pi -e 's/Implemented ng wrap-up so workers can hand off in one verb\. The verb\nfolds upload \+ comment \+ rocket \+ log into a single call\./Done./' "$X_REPORT"
grep -q '^Done\.$' "$X_REPORT" || { echo "FAIL: could not stage the degenerate summary" >&2; exit 1; }
run_ng stdout stderr rc wrap-up 42 "$X_REPORT" --repo override-org/override-repo --trigger-comment 7777
assert_eq "#1114 a degenerate teaser exits 3 (nothing failed, nothing published)" "$rc" "3"
assert_contains "#1114 stdout says NOTHING PUBLISHED" "$stdout" \
    "posted comment: NOTHING PUBLISHED"
assert_contains "#1114 stderr quotes the exact bytes it refused" "$stderr" "Done."
assert_contains "#1114 stderr names a way out the author can act on" "$stderr" \
    "--comment-body-file"
# THE PROPERTY, not the message: nothing reached the thread.
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "#1114 THE PROPERTY: no comment was POSTed to the issue" \
    "$gh_calls" "/repos/override-org/override-repo/issues/42/comments"
assert_no_file "#1114 THE PROPERTY: the comment store holds nothing" "$COMMENT_STORE"
# The rocket is the "this mention is handled" marker. Rocketing a trigger whose
# answer never published would retire the reminder for an undelivered message.
assert_not_contains "#1114 the trigger was NOT rocketed" "$gh_calls" \
    "/issues/comments/7777/reactions"
assert_contains "#1114 …and stdout says so rather than staying silent" "$stdout" \
    "rocketed comment 7777: SKIPPED"
assert_contains "#1114 the action log records comment=degenerate-teaser" \
    "$(<"$STATE_DIR/action-log.jsonl")" '"comment":"degenerate-teaser"'

echo '=== #1114 END-TO-END: the REAL instance now publishes its reason ==='
# your-org/your-nexus#229, the cc_auto_update BLOCK verdict that published as
# four characters. The fix is only real if this exact shape reaches the thread.
reset_mocks
X_REPORT2="$WORK/block-report.md"
write_report "$X_REPORT2"
perl -0pi -e 's/Implemented ng wrap-up so workers can hand off in one verb\. The verb\nfolds upload \+ comment \+ rocket \+ log into a single call\./**BLOCK. 2.1.250 is not safe to promote: the cc-harness gate fails on two of nine scenarios and the pin must stay at 2.1.240./' "$X_REPORT2"
grep -q 'not safe to promote' "$X_REPORT2" || { echo "FAIL: could not stage the BLOCK summary" >&2; exit 1; }
run_ng stdout stderr rc wrap-up 42 "$X_REPORT2" --repo override-org/override-repo
assert_eq "#1114 the real BLOCK verdict exits 0" "$rc" "0"
x_body=$(comment_store_body)
assert_contains "#1114 the PUBLISHED comment carries the reason, not just \`**BLOCK.\`" \
    "$x_body" "the cc-harness gate fails on two of nine scenarios"
assert_contains "#1114 …and the version the verdict is about" "$x_body" "2.1.250"

# ---- #1116 skeptic review, F1: the refusal must be visible to the RETIREMENT
#      path, not only to the GitHub thread ---------------------------------
#
# The PR's own argument — "rocketing a trigger whose answer never published
# retires the reminder for an undelivered message: the marker of a delivery,
# without the delivery" — was applied to the mention and NOT one layer up,
# where the same marker retires the WORKER. Measured before this fix:
# `ng wrap-up-check` returned `status=ok … rocket=ok` rc 0 for a wrap-up that
# published nothing — BYTE-IDENTICAL to one that published.
echo '=== #1116 F1: wrap-up-check must not call an unpublished wrap-up done ==='
reset_mocks
F1_REPORT="$WORK/f1-degenerate.md"
write_report "$F1_REPORT"
perl -0pi -e 's/Implemented ng wrap-up so workers can hand off in one verb\. The verb\nfolds upload \+ comment \+ rocket \+ log into a single call\./Done./' "$F1_REPORT"
grep -q '^Done\.$' "$F1_REPORT" || { echo "FAIL: could not stage F1 degenerate summary" >&2; exit 1; }
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="f1win"
run_ng stdout stderr rc wrap-up 42 "$F1_REPORT" --repo override-org/override-repo --trigger-comment 7777
assert_eq "#1116 F1 precondition: the degenerate wrap-up exits 3" "$rc" "3"
# `wrap-up-check` resolves the report as `reports/<basename>` relative to ITS
# OWN cwd, so it must run somewhere that has one — otherwise it returns
# `report_check=missing` and the status is `incomplete` for a reason that has
# NOTHING TO DO WITH THIS FIX. The first draft of these tests did exactly that:
# the degenerate assertion passed, and it passed for the wrong reason, which is
# only visible because the CONTROL failed. Right answer, wrong mechanism — the
# thing a control exists to catch.
mkdir -p "$WORK/reports"
f1_check() {   # $1 window, $2 report path -> prints the status line
    cp "$2" "$WORK/reports/$(basename "$2")"
    ( cd "$WORK" && env -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME -u TMUX -u TMUX_PANE \
        NEXUS_STATE_DIR="$STATE_DIR" PATH="$STUB_DIR:$PATH" "$NG" wrap-up-check "$1" 2>&1 )
}
f1_rc() { f1_check "$1" "$2" >/dev/null 2>&1; echo $?; }
stdout=$(f1_check f1win "$F1_REPORT"); rc=$(f1_rc f1win "$F1_REPORT")
assert_eq "#1116 F1 THE PROPERTY: wrap-up-check refuses to call it done (rc 1)" "$rc" "1"
assert_contains "#1116 F1 …status=incomplete, not ok"        "$stdout" "status=incomplete"
# The report IS resolvable here, so `incomplete` is attributable to the
# unpublished comment and not to a missing report.
assert_contains "#1116 F1 …for the RIGHT reason: the report itself checks out" \
                "$stdout" "report_check=ok"
assert_contains "#1116 F1 …and it names the unpublished comment as the reason" \
                "$stdout" "comment=unpublished"
assert_contains "#1116 F1 …and the withheld rocket is not laundered into ok" \
                "$stdout" "rocket=withheld"
unset MOCK_TMUX MOCK_TMUX_WINDOW

# THE CONTROL. Without it, "always incomplete" passes the block above, and the
# gate would block every honest hand-off — a far worse failure than the one
# being fixed.
echo '=== #1116 F1 CONTROL: a wrap-up that DID publish still reads done ==='
reset_mocks
F1_OK="$WORK/f1-normal.md"
write_report "$F1_OK"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="f1okwin"
run_ng stdout stderr rc wrap-up 42 "$F1_OK" --repo override-org/override-repo --trigger-comment 7777
assert_eq "#1116 F1 CONTROL precondition: a normal wrap-up exits 0" "$rc" "0"
stdout=$(f1_check f1okwin "$F1_OK"); rc=$(f1_rc f1okwin "$F1_OK")
assert_eq "#1116 F1 CONTROL: wrap-up-check still says done (rc 0)" "$rc" "0"
assert_contains "#1116 F1 CONTROL: status=ok"      "$stdout" "status=ok"
assert_contains "#1116 F1 CONTROL: comment=ok"     "$stdout" "comment=ok"
unset MOCK_TMUX MOCK_TMUX_WINDOW

# ---- #1116 skeptic review, F2: the THIRD lossy step -----------------------
#
# `grep -v '^\*\*Key:\*\*'` strips metadata lines. A Summary written ENTIRELY
# in that shape — a realistic skeptic verdict — flattened to empty, which used
# to mean "nothing parseable" and routed to the TITLE-ONLY body: published at
# rc 0 with the trigger rocketed, carrying no verdict at all. A one-word
# Summary was refused while a ZERO-word Summary was published as a bare title.
echo '=== #1116 F2: a `**Key:**`-only Summary must REFUSE, not publish a title ==='
reset_mocks
F2_REPORT="$WORK/f2-verdict.md"
write_report "$F2_REPORT"
perl -0pi -e 's/Implemented ng wrap-up so workers can hand off in one verb\. The verb\nfolds upload \+ comment \+ rocket \+ log into a single call\./**Verdict:** BLOCK\n**Confidence:** high\n**Findings:** two of nine cc-harness scenarios regress and the pin must stay at 2.1.240/' "$F2_REPORT"
grep -q '^\*\*Verdict:\*\* BLOCK$' "$F2_REPORT" || { echo "FAIL: could not stage F2 verdict summary" >&2; exit 1; }
run_ng stdout stderr rc wrap-up 42 "$F2_REPORT" --repo override-org/override-repo --trigger-comment 7777
assert_eq "#1116 F2 a Summary the flatten consumes exits 3, not 0" "$rc" "3"
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "#1116 F2 THE PROPERTY: no title-only comment was POSTed" \
                    "$gh_calls" "/repos/override-org/override-repo/issues/42/comments"
assert_no_file "#1116 F2 THE PROPERTY: the comment store holds nothing" "$COMMENT_STORE"
assert_not_contains "#1116 F2 THE PROPERTY: the trigger was NOT rocketed" \
                    "$gh_calls" "/issues/comments/7777/reactions"
assert_contains "#1116 F2 stderr names the CAUSE (the metadata strip), not the first sentence" \
                "$stderr" '`**Key:** value` lines'

# THE CONTROL, and it pins the trigger precisely: the refusal is "every
# surviving line is a `**Key:**` line", not "the Summary mentions a key".
echo '=== #1116 F2 CONTROL: one line of prose alongside the keys still publishes ==='
reset_mocks
F2_OK="$WORK/f2-verdict-plus-prose.md"
write_report "$F2_OK"
perl -0pi -e 's/Implemented ng wrap-up so workers can hand off in one verb\. The verb\nfolds upload \+ comment \+ rocket \+ log into a single call\./**Verdict:** BLOCK\nTwo of nine cc-harness scenarios regress, so the pin must stay at 2.1.240./' "$F2_OK"
run_ng stdout stderr rc wrap-up 42 "$F2_OK" --repo override-org/override-repo --trigger-comment 7777
assert_eq "#1116 F2 CONTROL: a Summary with prose still publishes (rc 0)" "$rc" "0"
assert_contains "#1116 F2 CONTROL: and the PUBLISHED body carries the prose" \
                "$(comment_store_body)" "Two of nine cc-harness scenarios regress"

# ---- #1116 skeptic review, F5: the token count must not depend on cwd -----
#
# `for w in $t` underwent PATHNAME EXPANSION as well as word splitting, so a
# publication gate's answer was a function of the invoking directory. The
# skeptic reported this as hardening, unable to construct a case that flips a
# refusal; holding `teaser == full` (so the length arm cannot fire) IS that
# case, and it flips 0 -> 1.
echo '=== #1116 F5: the degeneracy gate is cwd-independent ==='
F5_GLOB="$WORK/f5-globdir"
mkdir -p "$F5_GLOB" && : > "$F5_GLOB/aa" && : > "$F5_GLOB/bb"
f5_rc() { ( cd "$1" && bash -c 'source "$1"; _wrapup_teaser_degenerate "[ab]?" "[ab]?"; echo $?' _ "$X_FN" ); }
assert_eq "#1116 F5 refuses a one-token teaser in a plain directory" "$(f5_rc "$WORK")" "0"
assert_eq "#1116 F5 …and gives the SAME answer where the teaser globs to two files" \
          "$(f5_rc "$F5_GLOB")" "0"

# ---- summary ------------------------------------------------------------


echo '=== #1148: `nothing-published` must NOT rocket the trigger ==='
reset_mocks
# `nothing-published` (#862) and `degenerate-teaser` are ONE VARIABLE APART and
# both exit 3: the thread learned nothing either way. Only `degenerate-teaser`
# withheld the rocket. So a worker who amended its report OUTSIDE `## Summary`
# and re-ran with the operator's trigger got the mention ROCKETED — and
# `_mark_processed rocket` then evicts it from the #360 re-emit registry, so the
# escalation is marked handled with the correction delivered NOWHERE.
#
# Asserted on the REACTIONS CALL, not on the status word: the status is what a
# reworded arm would keep, the POST is what the operator actually sees.
N1148_REPORT="$FAKE_NEXUS/reports/nexus_2026-05-12_101500_n1148.md"
write_report "$N1148_REPORT"
export MOCK_UPLOAD_SHA=aaaa1111v1
# Run 1 carries NO trigger. That is the issue's shape: the operator posts 8888
# AFTER the first wrap-up, asking for the correction, and the worker answers by
# amending and re-running WITH that trigger. So 8888 has never been answered.
run_ng stdout stderr rc wrap-up 77 "$N1148_REPORT" --repo override-org/override-repo
# POSITIVE CONTROL: run 1 must actually PUBLISH, or run 2's silence is not a
# state change and every assertion below is about a broken fixture.
assert_eq "#1148 POSITIVE CONTROL: the first wrap-up publishes" "$rc" "0"
assert_contains "#1148 POSITIVE CONTROL: …and it posted a comment" \
    "$(<"$GH_CAPTURE")" "issues/77/comments"
# Amend OUTSIDE `## Summary` — the composed body is unchanged, the asset moves.
printf '\n## Correction\n\nthe finding the operator asked for\n' >> "$N1148_REPORT"
export MOCK_UPLOAD_SHA=bbbb2222v2
run_ng stdout stderr rc wrap-up 77 "$N1148_REPORT" --repo override-org/override-repo --trigger-comment 8888
assert_eq "#1148 the re-run publishes nothing (exit 3)" "$rc" "3"
assert_contains "#1148 …and the rocket is WITHHELD" \
    "$stdout" "SKIPPED (nothing was published"
# THE PROPERTY, on the wire.
# GATED on the run having happened at all. Measured while building this: with
# a mis-specified fixture `ng` died before doing anything, GH_CAPTURE was empty,
# and this assertion PASSED — a confident zero meaning "I could not look".
if [[ "$rc" == "3" ]]; then
    assert_eq "#1148 THE PROPERTY: no reactions POST for a run that published nothing" \
        "$(command grep -c '/issues/comments/8888/reactions' "$GH_CAPTURE" || true)" "0"
else
    assert_eq "#1148 THE PROPERTY skipped — the re-run did not reach exit 3" "rc=$rc" "rc=3"
fi

echo '=== #1148 CONTROL: an honest RETRY must still be able to complete ==='
reset_mocks
# `nothing-published` ALSO fires on a retry whose comment LANDED and whose
# rocket FAILED. Withholding there would make the documented retry surface
# unable to ever finish — so the carve-out keys on EVIDENCE (an earlier wrap-up
# that actually published for this same trigger), not on the state name.
# Without this control the fix could simply be "always withhold".
R1148_REPORT="$FAKE_NEXUS/reports/nexus_2026-05-12_101600_r1148.md"
write_report "$R1148_REPORT"
export MOCK_UPLOAD_SHA=cccc3333v1 MOCK_ROCKET_FAIL=1
run_ng stdout stderr rc wrap-up 77 "$R1148_REPORT" --repo override-org/override-repo --trigger-comment 7777
unset MOCK_ROCKET_FAIL
printf '\n## Correction\n\nretrying after the rocket failed\n' >> "$R1148_REPORT"
export MOCK_UPLOAD_SHA=dddd4444v2
run_ng stdout stderr rc wrap-up 77 "$R1148_REPORT" --repo override-org/override-repo --trigger-comment 7777
assert_contains "#1148 CONTROL: the retry's rocket is NOT withheld" \
    "$stdout" "rocketed comment 7777"
assert_eq "#1148 CONTROL: …and the reactions POST really happens" \
    "$(command grep -c '/issues/comments/7777/reactions' "$GH_CAPTURE" || true)" "1"
reset_mocks



echo '=== #1132: `satisfied` is a CHECKED settlement, not a waiver ==='
# Before this, a MET requirement had to be recorded as a WAIVER — a statement
# that the requirement was SET ASIDE. Opposite claims about the same gate, and
# the record kept only the wrong one. `--skeptic-waive` and `ng skeptic resolve`
# are both role-gated and verify NOTHING (measured: `ng skeptic resolve
# ghostwin --reason "a verdict that has never existed anywhere"` succeeds), so
# `satisfied` earns its ungated status by being CHECKED.
_s1132() {   # _s1132 <mode> -> "rc=<n> marker=<PRESENT|cleared>" + stdout/stderr
    local mode="$1" w="$WORK/s1132-$1"
    rm -rf "$w"; mkdir -p "$w/state/skeptic/pending" "$w/reports"
    # `NEXUS_WORKER_WINDOW` is UNSET here and set only by the `worker` mode, so
    # the operator/worker pair actually discriminates. Inheriting the harness's
    # own value would make both arms identical and the pair meaningless.
    env -u NEXUS_WORKER_WINDOW bash -c '
        set -uo pipefail
        NG="$1"; W="$2"; mode="$3"
        export NEXUS_STATE_DIR="$W/state"
        source "$NG" >/dev/null 2>&1
        STATE_DIR="$W/state"; P="$STATE_DIR/skeptic/pending"; K=$(wk_encode w1132)
        printf "the report\n" > "$W/reports/r.md"
        H=$(sha256sum < "$W/reports/r.md" | awk "{print \$1}")
        OTHER=$(printf other | sha256sum | awk "{print \$1}")
        : > "$P/$K"
        if [ "$mode" = armonly ]; then
            printf "armed\t%s\t2026-09-01T01:00:00\t1132\t%s\n" "$H" "$W/reports/r.md" > "$P/.$K.ledger"
        else
            {   printf "armed\t%s\t2026-09-01T01:00:00\t1132\t%s\n" "$H" "$W/reports/r.md"
                printf "discharged\t%s\t2026-09-01T01:30:00\tcredible\t1132\tsk\tattributed\n" "$H"
                if [ "$mode" = twoarms ]; then
                    printf "armed\t%s\t2026-09-01T02:00:00\t1132\t%s\n" "$OTHER" "$W/reports/o.md"
                    printf "armed\t%s\t2026-09-01T02:10:00\t1132\t%s\n" \
                        "$(printf z | sha256sum | awk "{print \$1}")" "$W/reports/z.md"
                fi
            } > "$P/.$K.ledger"
        fi
        cite="$W/reports/r.md"; [ "$mode" = wrongcite ] && cite="$OTHER"
        [ "$mode" = worker ] && export NEXUS_WORKER_WINDOW=w1132
        if [ "$mode" = nocite ]; then cite=""; fi
        out=$(_wrapup_skeptic_step 1132 w1132 owner/repo 0 "" "" "" "" "" "" "" "" "" "" "" 1 "$cite" 2>&1)
        printf "rc=%s marker=%s\n%s\n" "$?" \
            "$([ -e "$P/$K" ] && echo PRESENT || echo cleared)" "$out"
    ' _ "$NG_REAL" "$w" "$mode" 2>/dev/null
}
# POSITIVE CONTROL FIRST: the happy path must actually SUCCEED, or every
# refusal below could be a broken probe refusing uniformly. Measured while
# building this: a bad `sed` made `evidence=` unextractable and ALL SIX cases
# refused identically — a uniform refusal looks exactly like a working gate.
_ok1132=$(_s1132 discharged)
assert_contains "#1132 POSITIVE CONTROL: a real discharge SATISFIES the requirement" \
    "$_ok1132" "rc=0"
assert_contains "#1132 …and the marker is released" "$_ok1132" "marker=cleared"
assert_contains "#1132 …recorded as a SETTLEMENT, not a waiver" "$_ok1132" "SATISFIED"
# THE ROW KIND IS LOAD-BEARING, and asserting the banner does not pin it: a
# mutant writing a NEW `satisfied\t…` row kept every assertion above GREEN.
# A new kind is swallowed TWICE — `_skeptic_open_arms` has an implicit no-match
# arm, so the arm stays open and the window still cannot retire; and
# `_skeptic_verdict_evidence` counts it `malformed`, whose FIRST class arm turns
# the whole record into `?`. So assert what the READERS say afterwards.
_ok1132_dir="$WORK/s1132-discharged/state"
assert_contains "#1132 THE READERS AGREE: obligations reports nothing outstanding" \
    "$(env -u NEXUS_WORKER_WINDOW "$NG_REAL" skeptic-obligations w1132 --state-dir "$_ok1132_dir" 2>/dev/null)" \
    "outstanding=0"
_ok1132_ev=$(env -u NEXUS_WORKER_WINDOW "$NG_REAL" skeptic-evidence w1132 --state-dir "$_ok1132_dir" 2>/dev/null | sed -n 1p)
assert_eq "#1132 …and the evidence class is NOT poisoned to \`?\`" \
    "$( [[ "$_ok1132_ev" == *"evidence=?"* ]] && echo POISONED || echo intact)" "intact"
# AVAILABLE TO THE PARTY THAT OBSERVES THE DISPUTE — the issue's second half.
# `--skeptic-waive` and `ng skeptic resolve` both refuse a worker outright.
# The pair is the point: the OPERATOR case above ran with NEXUS_WORKER_WINDOW
# UNSET, this one with it SET. `--skeptic-waive` and `ng skeptic resolve` both
# refuse the second outright; `satisfied` does not, because it verifies.
assert_contains "#1132 a WORKER may record it — the check is mechanical, so no trust is extended" \
    "$(_s1132 worker)" "rc=0"
# THE FOUR REFUSALS. Retire-gate polarity: every doubt fails toward NOT
# releasing. Without these the change is a rename of `waive`.
_a1132=$(_s1132 armonly)
assert_contains "#1132 REFUSE: no verdict on the ledger" "$_a1132" "rc=1"
assert_contains "#1132 …and the marker is UNTOUCHED" "$_a1132" "marker=PRESENT"
assert_contains "#1132 …naming waive as the honest verb when nothing was reviewed" \
    "$_a1132" "--skeptic-waive is the honest"
assert_contains "#1132 REFUSE: no citation at all" "$(_s1132 nocite)" "rc=1"
assert_contains "#1132 REFUSE: a citation no discharge names" "$(_s1132 wrongcite)" "rc=1"
# A `resolved` row closes EVERY outstanding arm, so one citation may not speak
# for several — it would silently discharge artefacts nobody reviewed.
_t1132=$(_s1132 twoarms)
assert_contains "#1132 REFUSE: more open arms than this citation can close" "$_t1132" "rc=1"
assert_contains "#1132 …and says so, rather than closing them silently" \
    "$_t1132" "arms are outstanding"

echo '=== #1132: waive no longer asserts a clear it did not make ==='
# `sw_safe` keys on the INVOKING PANE, not the report's subject, so an operator
# waiving a WORKER's gate removes `pending/orchestrator` — a file that never
# existed — and `rm -f` is silent on a miss. Measured: markers before
# [panelive], after [panelive], obligations still outstanding=1, while the text
# said the marker was cleared and the window could retire. #813 F5 false-cause.
_w1132() {   # _w1132 <marker-present:0|1>
    local w="$WORK/w1132-$1"; rm -rf "$w"; mkdir -p "$w/state/skeptic/pending" "$w/reports"
    # UNSET: `--skeptic-waive` is an OPERATOR override and refuses outright when
    # `NEXUS_WORKER_WINDOW` is set, so inheriting it never reaches the arm.
    env -u NEXUS_WORKER_WINDOW bash -c '
        set -uo pipefail
        export NEXUS_STATE_DIR="$2/state"
        source "$1" >/dev/null 2>&1
        STATE_DIR="$2/state"; P="$STATE_DIR/skeptic/pending"
        [ "$3" = 1 ] && : > "$P/$(wk_encode wv1132)"
        _wrapup_skeptic_step 1132 wv1132 owner/repo 0 "" "" "operator says so" "" "" "" "" 2>&1
    ' _ "$NG_REAL" "$w" "$1" 2>/dev/null
}
_wn1132=$(_w1132 0)
assert_contains "#1132 waive with NO marker says NOTHING WAS RELEASED" "$_wn1132" "NOTHING WAS RELEASED"
assert_not_contains "#1132 …and does NOT claim the marker is cleared" \
    "$_wn1132" "the pending marker is cleared"
assert_contains "#1132 …and names the key it actually used" "$_wn1132" "INVOKING pane"
# NEGATIVE CONTROL: when a marker really IS present the claim is true and stays.
_wy1132=$(_w1132 1)
assert_contains "#1132 CONTROL: with a marker present it DOES report the clear" \
    "$_wy1132" "is cleared, so THAT window can retire"


echo '=== #1370: the output is PERSISTED, and `--last` re-reads it WITHOUT re-arming ==='
# `ng wrap-up` ARMS on every invocation (Step 0b appends a discharge row keyed
# on the report sha), and until this it offered no way to re-read what a
# previous invocation printed — so the natural recovery for a `| tail`-eaten
# diagnostic was to RUN IT AGAIN, which is a write. `--last` is the read.
reset_mocks
R1370="$FAKE_NEXUS/reports/nexus_2026-09-03_120000_n1370.md"
write_report "$R1370"
# A REQUIRE-stamped window, so the skeptic step really arms (marker + ledger).
mkdir -p "$STATE_DIR/windows"
cat > "$STATE_DIR/windows/n1370w.json" <<EOF
{ "window": "n1370w", "kind": "task", "skeptic_mode": "require", "skeptic_depth": 0, "skeptic_role": false }
EOF
export MOCK_TMUX=1 MOCK_TMUX_WINDOW=n1370w
run_ng stdout stderr rc wrap-up 42 "$R1370" --repo override-org/override-repo
assert_eq "#1370 POSITIVE CONTROL: the require wrap-up succeeds" "$rc" "0"
K1370=$(wk_encode n1370w)
assert_file_exists "#1370 POSITIVE CONTROL: …and ARMED (pending marker present)" \
    "$STATE_DIR/skeptic/pending/$K1370"
assert_file_exists "#1370 POSITIVE CONTROL: …with a ledger" \
    "$STATE_DIR/skeptic/pending/.$K1370.ledger"
REC1370="$STATE_DIR/wrap-up-output/$K1370/last"
assert_file_exists "#1370 a record was persisted for the window" "$REC1370"
assert_contains "#1370 the record carries the verb's stdout" "$(cat "$REC1370")" "uploaded: https://"
assert_contains "#1370 …the argv" "$(cat "$REC1370")" "argv: ng wrap-up 42"
assert_contains "#1370 …and the exit code" "$(cat "$REC1370")" "rc: 0"
# THE PROPERTY: a byte-level snapshot of every state file EXCEPT the record
# store itself and the usage-telemetry tap (which fires on every `ng` verb,
# including `help`, and is not state). If `--last` moved ANY of them — a
# ledger row, a marker, an action-log event — this catches it.
_snap1370() {
    ( cd "$STATE_DIR" && find . -type f ! -path './wrap-up-output/*' ! -name 'ng-usage.jsonl' -print0 \
        | sort -z | xargs -0 sha256sum 2>/dev/null )
}
_before1370=$(_snap1370)
assert_eq "#1370 PRECONDITION: the snapshot sees files (not an empty instrument)" \
    "$( [[ -n "$_before1370" ]] && echo populated || echo EMPTY)" "populated"
run_ng stdout stderr rc wrap-up --last
assert_eq "#1370 --last exits 0" "$rc" "0"
assert_contains "#1370 --last replays the stdout" "$stdout" "uploaded: https://"
assert_contains "#1370 --last replays the rc footer" "$stdout" "rc: 0"
assert_eq "#1370 THE PROPERTY: --last left every state file BYTE-IDENTICAL (ledger, marker, action log)" \
    "$( [[ "$(_snap1370)" == "$_before1370" ]] && echo identical || echo CHANGED)" "identical"
assert_eq "#1370 …no upload was attempted" "$(<"$UPLOAD_CAPTURE")" ""
assert_eq "#1370 …no gh call was made" "$(<"$GH_CAPTURE")" ""
# NEGATIVE CONTROL for the instrument: a REAL re-run must be SEEN to move
# state (the require arm re-records the arm), or the identical-snapshot
# assertion above could pass against an instrument that sees nothing.
run_ng stdout stderr rc wrap-up 42 "$R1370" --repo override-org/override-repo
assert_eq "#1370 NEGATIVE CONTROL: a real re-run DOES move state, and the snapshot sees it" \
    "$( [[ "$(_snap1370)" == "$_before1370" ]] && echo unchanged || echo changed)" "changed"
# --explain: the record plus the ledger evidence, still read-only.
_before1370=$(_snap1370)
run_ng stdout stderr rc wrap-up --explain
assert_eq "#1370 --explain exits 0" "$rc" "0"
assert_contains "#1370 --explain adds the skeptic-evidence line" "$stdout" "skeptic-evidence: evidence="
assert_contains "#1370 …and the marker state" "$stdout" "pending marker : PRESENT"
assert_eq "#1370 --explain is read-only too" \
    "$( [[ "$(_snap1370)" == "$_before1370" ]] && echo identical || echo CHANGED)" "identical"
# The read-only flag combined with a hand-off is REFUSED rather than guessed:
# a caller who types `ng wrap-up 42 r.md --last` must not get a silent replay
# of some other run, nor a silent re-arm.
run_ng stdout stderr rc wrap-up 42 "$R1370" --last
assert_eq "#1370 --last combined with a hand-off is refused" "$rc" "1"
assert_contains "#1370 …and the refusal says why" "$stderr" "READ-ONLY"
# A `die` inside the verb: the record still captures the stderr, and `--last`
# flags the missing footer rather than pretending the run completed.
run_ng stdout stderr rc wrap-up 42 "$FAKE_NEXUS/reports/nexus_2026-09-03_000000_nope.md"
assert_eq "#1370 PRECONDITION: a missing report dies at rc 1" "$rc" "1"
assert_contains "#1370 …and the failure output names where the record is" "$stderr" "persisted at"
run_ng stdout stderr rc wrap-up --last
assert_contains "#1370 a die()'d run's stderr is IN the record" "$stdout" "[stderr] ng: wrap-up: report not found"
assert_contains "#1370 …and its rc footer is present (the EXIT trap closed the record)" "$stdout" "rc: 1"
# --last for a window that never wrapped: exit 1, nothing run.
run_ng stdout stderr rc wrap-up --last no-such-window-1370
assert_eq "#1370 --last on an unknown window exits 1" "$rc" "1"
assert_contains "#1370 …and says nothing was re-run" "$stderr" "Nothing was re-run"
unset MOCK_TMUX MOCK_TMUX_WINDOW
reset_mocks


echo '=== #914 F2: the refusal must not promise a termination it cannot deliver ==='
# `!! YOU STATED NEITHER A COUNT NOR A DISPOSITION` is a MANDATORY refusal, so
# the skeptic is COMPELLED down one of the two remedies it names. At `suspect`
# / `refuted` the verdict alone sets substantive=1 and #678 makes that
# non-overridable by a disposition, so NEITHER remedy terminates the chain —
# and the text used to say "EITHER statement terminates the chain honestly"
# unconditionally. Asserted on the COMPOSED string (no suite did: `git grep -c
# 'EITHER statement terminates' origin/dev -- monitor/watcher/` -> rc 1).
_s914() {   # <verdict> -> the refusal text + "rc=<n>"
    local w="$WORK/s914-$1"; rm -rf "$w"; mkdir -p "$w/state/skeptic/pending" "$w/reports"
    env -u NEXUS_WORKER_WINDOW bash -c '
        set -uo pipefail
        export NEXUS_STATE_DIR="$2/state"
        source "$1" >/dev/null 2>&1
        STATE_DIR="$2/state"
        printf -- "---\nproject: x\nstatus: completed\n---\n\n# r\n\n## Summary\n\nno disposition stated anywhere\n" > "$2/reports/r.md"
        _SK_REPORT_PATH="$2/reports/r.md"
        _wrapup_skeptic_step 914 sk914 owner/repo 1 "" "" "" "$3" victim 1 "" "" "" "" "" 2>&1
        echo "rc=$?"
    ' _ "$NG_REAL" "$w" "$1" 2>/dev/null
}
_o914s=$(_s914 suspect)
assert_contains "#914 POSITIVE CONTROL: the neither-stated refusal fires at suspect" "$_o914s" "YOU STATED NEITHER A COUNT NOR A DISPOSITION"
assert_contains "#914 …and refuses (rc=1)" "$_o914s" "rc=1"
assert_contains "#914 at suspect the text says NEITHER statement will terminate" "$_o914s" "NEITHER STATEMENT WILL TERMINATE THIS CHAIN"
assert_not_contains "#914 …and does NOT promise that either one does" "$_o914s" "EITHER statement terminates the chain honestly"
_o914r=$(_s914 refuted)
assert_contains "#914 at refuted, likewise" "$_o914r" "NEITHER STATEMENT WILL TERMINATE THIS CHAIN"
assert_not_contains "#914 …with no termination promise" "$_o914r" "EITHER statement terminates the chain honestly"
_o914c=$(_s914 check)
# A STATED, MEASURED zero (bundlersk on your-org/nexus-code#1437): the header used
# to say "this pass found substantive new issues (verdict=suspect, findings=0)"
# — a contradiction on one line. The escalation stands (the verdict sets the
# severity signal, #678); its justification must be the verdict, not a discovery.
_s914z() {   # <verdict> <findings> -> the recommendation header
    local w="$WORK/s914z-$1-$2"; rm -rf "$w"; mkdir -p "$w/state/skeptic/pending" "$w/reports"
    env -u NEXUS_WORKER_WINDOW bash -c '
        set -uo pipefail
        export NEXUS_STATE_DIR="$2/state"
        source "$1" >/dev/null 2>&1
        STATE_DIR="$2/state"
        printf -- "---\nproject: x\nstatus: completed\n---\n\n# r\n\n## Summary\n\nno disposition stated anywhere\n" > "$2/reports/r.md"
        _SK_REPORT_PATH="$2/reports/r.md"
        _wrapup_skeptic_step 914 sk914 owner/repo 1 "" "" "" "$3" victim 1 "$4" "" "" "" "" 2>&1
        echo "rc=$?"
    ' _ "$NG_REAL" "$w" "$1" "$2" 2>/dev/null
}
_o914z=$(_s914z suspect 0)
assert_contains     "#914 stated findings=0 at suspect: the header still recommends a second pass" "$_o914z" "SECOND-PASS SKEPTIC RECOMMENDED"
assert_contains     "#914 …justified by the VERDICT"     "$_o914z" "not because this pass found new issues"
assert_contains     "#914 …and it says the zero was stated" "$_o914z" "(it stated findings=0)"
assert_not_contains "#914 …never as substantive new issues over a measured zero" "$_o914z" "found substantive new issues"
_o914n=$(_s914z suspect 3)
assert_contains     "#914 CONTROL: findings=3 IS substantive, and the header says so" "$_o914n" "found substantive new issues"
assert_contains     "#914 CONTROL: …with the count"       "$_o914n" "findings=3"
assert_contains "#914 CONTROL: at check the promise is TRUE and is kept" "$_o914c" "EITHER statement terminates the chain honestly"
assert_not_contains "#914 CONTROL: …and the severity clause is absent" "$_o914c" "NEITHER STATEMENT WILL TERMINATE"

echo '=== #1363 at wrap-up: `no-further-pass` against a gate this run would arm or that is live ==='
reset_mocks
R1363="$FAKE_NEXUS/reports/nexus_2026-09-03_130000_n1363.md"
write_report "$R1363" no-further-pass
export MOCK_TMUX=1 MOCK_TMUX_WINDOW=n1363w
# (a) an auto worker DECIDING require while its report says no skeptic is needed.
#     Only this invocation knows the decision; report-check cannot see it.
run_ng stdout stderr rc wrap-up 42 "$R1363" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched shared infra"
assert_eq       "#1363 --skeptic-decision require + no-further-pass → refused (rc 1)" "$rc" "1"
assert_contains "#1363 …naming the contradiction"        "$stderr" "REFUSED — the report states \`disposition: no-further-pass\`"
assert_contains "#1363 …and the decision as the reason"  "$stderr" "passes --skeptic-decision require"
assert_eq       "#1363 …NO upload before the refusal"    "$(<"$UPLOAD_CAPTURE")" ""
assert_no_file  "#1363 …and NO marker was armed"         "$STATE_DIR/skeptic/pending/$(wk_encode n1363w)"
assert_no_file  "#1363 …and NO ledger was written"       "$STATE_DIR/skeptic/pending/.$(wk_encode n1363w).ledger"
# (b) CONTROL: the same decision with the honest value proceeds and arms.
write_report "$R1363" second-pass
run_ng stdout stderr rc wrap-up 42 "$R1363" --repo override-org/override-repo \
    --skeptic-decision require --skeptic-rationale "touched shared infra"
assert_eq       "#1363 CONTROL: …second-pass with the same decision → rc 0" "$rc" "0"
assert_file_exists "#1363 CONTROL: …and the marker IS armed" "$STATE_DIR/skeptic/pending/$(wk_encode n1363w)"
# (c) a LIVE marker for the INVOKING window (armed by an earlier round or by
#     spawn-worker for a reviewer), report says no-further-pass, no decision
#     flag. The report's own `window:` is the fixture's `wrap-up-test`, so
#     report-check's frontmatter-keyed pass cannot see this; wrap-up's
#     pane-keyed pass must.
reset_mocks
write_report "$R1363" no-further-pass
mkdir -p "$STATE_DIR/skeptic/pending"; : > "$STATE_DIR/skeptic/pending/$(wk_encode n1363w)"
run_ng stdout stderr rc wrap-up 42 "$R1363" --repo override-org/override-repo
assert_eq       "#1363 live marker (invoking window) + no-further-pass → refused" "$rc" "1"
assert_contains "#1363 …naming the marker"               "$stderr" "skeptic-pending marker is LIVE"
assert_eq       "#1363 …NO upload"                       "$(<"$UPLOAD_CAPTURE")" ""
# (d) CONTROL: an operator WAIVE is the settlement of that gate, not a
#     contradiction of it — the check steps aside (both surfaces).
run_ng stdout stderr rc wrap-up 42 "$R1363" --repo override-org/override-repo \
    --skeptic-waive "operator releases the requirement for the #1363 control"
assert_eq       "#1363 CONTROL: --skeptic-waive with the marker live → not refused by this check" "$rc" "0"
assert_not_contains "#1363 CONTROL: …no contradiction text" "$stderr" "CONTRADICTS a skeptic gate"
unset MOCK_TMUX MOCK_TMUX_WINDOW
reset_mocks

echo '=== #1181: unsettled async waits block the hand-off — REFUSE on a real handle, WARN on syn- ==='
reset_mocks
R1181="$FAKE_NEXUS/reports/nexus_2026-09-03_140000_n1181.md"
write_report "$R1181"
export MOCK_TMUX=1 MOCK_TMUX_WINDOW=n1181w
mkdir -p "$STATE_DIR"
_tsv1181="$STATE_DIR/orphan-async-state.tsv"
# (a) one parsed handle + one syn- phantom on the invoking window; another
#     window's row alongside, which must be ignored.
printf 'otherwin\tasyncrun:ar-zzz\t1\t1\t0\nn1181w\tasyncrun:ar-abc123,slurm:syn-deadbeef\t1\t1\t0\n' > "$_tsv1181"
_tsv1181_before=$(sha256sum < "$_tsv1181")
run_ng stdout stderr rc wrap-up 42 "$R1181" --repo override-org/override-repo
assert_eq       "#1181 a wait with a PARSED handle → refused (rc 1)" "$rc" "1"
assert_contains "#1181 …the refusal names the handle"    "$stderr" "asyncrun:ar-abc123"
assert_contains "#1181 …and the count"                   "$stderr" "REFUSED — 1 unsettled async wait(s) with a real handle"
assert_contains "#1181 …the syn- row is WARNED, not refused on" "$stderr" "WARNING — 1 synthetic (\`syn-\`) async wait(s)"
assert_not_contains "#1181 …the other window's wait is not attributed to us" "$stderr" "ar-zzz"
assert_eq       "#1181 …NO upload before the refusal"    "$(<"$UPLOAD_CAPTURE")" ""
assert_eq       "#1181 THE RULE: nothing was auto-cleared (the TSV is byte-identical)" \
    "$(sha256sum < "$_tsv1181")" "$_tsv1181_before"
assert_contains "#1181 …and the way out is the deliberate settle verb" "$stderr" "declare-no-wait.sh <kind> <id>"
# (b) syn- ONLY: warn, and PROCEED — a refusal keyed on existence would deadlock
#     on a phantom that no finishing of anything can clear (the filer's own
#     correction).
: > "$UPLOAD_CAPTURE"
printf 'n1181w\tnohup:syn-0123abcd,slurm:syn-deadbeef\t1\t1\t0\n' > "$_tsv1181"
run_ng stdout stderr rc wrap-up 42 "$R1181" --repo override-org/override-repo
assert_eq       "#1181 syn- rows only → the hand-off PROCEEDS (rc 0)" "$rc" "0"
assert_contains "#1181 …with the warning on stderr"     "$stderr" "WARNING — 2 synthetic (\`syn-\`) async wait(s)"
assert_contains "#1181 …and the upload really ran"       "$stdout" "uploaded: https://"
# (c) a token the pre-flight cannot parse (the truncation ellipsis, or no
#     kind:id) is a list it cannot vouch for → refuse, fail closed.
printf 'n1181w\tasyncrun:ar-1…\t1\t1\t0\n' > "$_tsv1181"
run_ng stdout stderr rc wrap-up 42 "$R1181" --repo override-org/override-repo
assert_eq       "#1181 a TRUNCATED wait list → refused (cannot vouch)" "$rc" "1"
assert_contains "#1181 …saying so"                       "$stderr" "unparseable/truncated"
# (d) CONTROLS: no row for this window, and no TSV at all → proceed silently.
printf 'otherwin\tasyncrun:ar-zzz\t1\t1\t0\n' > "$_tsv1181"
run_ng stdout stderr rc wrap-up 42 "$R1181" --repo override-org/override-repo
assert_eq       "#1181 CONTROL: no row for this window → rc 0" "$rc" "0"
assert_not_contains "#1181 CONTROL: …and no async warning" "$stderr" "async wait"
rm -f "$_tsv1181"
run_ng stdout stderr rc wrap-up 42 "$R1181" --repo override-org/override-repo
assert_eq       "#1181 CONTROL: no TSV at all → rc 0" "$rc" "0"
# (e) THE POPULATION THAT MOTIVATED THE ISSUE (bundlersk on your-org/nexus-code#1437):
#     the watcher DROPS a window's TSV row the moment it stops reading idle
#     ("no longer reads idle-orphan-async (state=busy); dropping the row"),
#     and a worker running wrap-up is busy by definition. So with NO TSV at
#     all, the heartbeat's external_waits — written by the launch hook, lifted
#     only by declare-no-wait — must still refuse.
_hb1181="$STATE_DIR/heartbeat/n1181w.json"; mkdir -p "$STATE_DIR/heartbeat"
printf '{"state":"busy","external_waits":[{"kind":"asyncrun","id":"ar-hb1","desc":"a real launch"}]}\n' > "$_hb1181"
_hb1181_before=$(sha256sum < "$_hb1181")
: > "$UPLOAD_CAPTURE"
run_ng stdout stderr rc wrap-up 42 "$R1181" --repo override-org/override-repo
assert_eq       "#1181 (e) TSV dropped (busy), heartbeat carries a real handle → refused (rc 1)" "$rc" "1"
assert_contains "#1181 (e) …naming the handle"          "$stderr" "asyncrun:ar-hb1"
assert_contains "#1181 (e) …and naming the heartbeat as the source" "$stderr" "heartbeat/n1181w.json"
assert_eq       "#1181 (e) …NO upload before the refusal" "$(<"$UPLOAD_CAPTURE")" ""
assert_eq       "#1181 (e) …and the heartbeat is byte-identical (nothing auto-cleared)" \
    "$(sha256sum < "$_hb1181")" "$_hb1181_before"
printf '{"state":"busy","external_waits":[{"kind":"nohup","id":"syn-0123abcd"}]}\n' > "$_hb1181"
run_ng stdout stderr rc wrap-up 42 "$R1181" --repo override-org/override-repo
assert_eq       "#1181 (e) heartbeat with only a syn- wait → PROCEEDS (rc 0)" "$rc" "0"
assert_contains "#1181 (e) …with the warning"           "$stderr" "WARNING — 1 synthetic (\`syn-\`) async wait(s)"
printf '{"state":"busy","external_waits":[{"kind":"asyncrun","id":"ar-hb2"' > "$_hb1181"
run_ng stdout stderr rc wrap-up 42 "$R1181" --repo override-org/override-repo
assert_eq       "#1181 (e) an UNPARSEABLE heartbeat → refused, fail closed (rc 1)" "$rc" "1"
assert_contains "#1181 (e) …saying so"                  "$stderr" "does not parse"
rm -f "$_hb1181"
run_ng stdout stderr rc wrap-up 42 "$R1181" --repo override-org/override-repo
assert_eq       "#1181 (e) CONTROL: no heartbeat, no TSV → rc 0" "$rc" "0"
unset MOCK_TMUX MOCK_TMUX_WINDOW
reset_mocks


# ── your-org/nexus-code#1352: per-issue dispositions are PUBLISHED and READ BACK ─
echo '=== #1352: wrap-up publishes each `## Dispositions` bullet on its issue and reads it back ==='
reset_mocks
REPORT1352="$FAKE_NEXUS/reports/nexus_2026-05-10_120000_disp-test.md"
write_report "$REPORT1352"
cat >> "$REPORT1352" <<'D'

## Dispositions

- #1125 — VOID-AS-WRITTEN — the shared stub has no PATCH arm; re-derived at bbf8985b
- #1194 — GENUINELY-OPEN — residual R1: the read-back is untested
- #932 — ALREADY-ADDRESSED — criterion 2 satisfied by test-ci-head-attempts.sh:88-101
D
export MOCK_DISP_DIR="$WORK/disp"; mkdir -p "$MOCK_DISP_DIR"
# This block installs its OWN gh stub — the suite rewrites $STUB_DIR/gh six
# times above and the last one is what runs here. STATEFUL: a comment POST
# stores its body under MOCK_DISP_DIR; a GET of that comment reads it back;
# MOCK_DISP_SWALLOW names issues whose write is ACCEPTED but NOT STORED (the
# #1118 shape — the negative control a read-back must fail on).
# jq-blind: the verbs this block drives (a comment POST, a comment GET by id) pass no --jq — ng filters with its own jq, so the stub never contemplates the flag (test-gh-stub-contract.sh, #932)
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NG_WRAPUP_GH_CAPTURE:-/dev/null}"
[[ "${1:-}" == "api" ]] || exit 0
shift
method=GET; endpoint=""
while (( $# > 0 )); do
    case "$1" in
        -X) method="$2"; shift 2 ;;
        -H|-f|-F|--input|--jq) shift 2 ;;
        --) shift; break ;;
        /*) endpoint="$1"; shift ;;
        *) shift ;;
    esac
done
_body=""
if ! [ -t 0 ]; then _body=$(cat 2>/dev/null || true); fi
case "$endpoint" in
    */issues/comments/5*)
        _n="${endpoint##*/comments/5}"
        if [[ -r "$MOCK_DISP_DIR/$_n.body" ]]; then jq -Rs '{body: .}' < "$MOCK_DISP_DIR/$_n.body"; else printf '{"body":""}'; fi ;;
    */issues/*/comments)
        _n=$(sed -E 's|.*/issues/([0-9]+)/comments.*|\1|' <<<"$endpoint")
        if [[ "$_n" == "42" ]]; then printf '{"html_url":"https://mock.example/issuecomment-1234"}'; exit 0; fi
        if [[ " ${MOCK_DISP_SWALLOW:-} " == *" $_n "* ]]; then : > "$MOCK_DISP_DIR/$_n.body"
        else printf '%s' "$_body" | jq -r '.body // empty' > "$MOCK_DISP_DIR/$_n.body" 2>/dev/null || printf '%s' "$_body" > "$MOCK_DISP_DIR/$_n.body"; fi
        printf '{"html_url":"https://mock.example/issues/%s#issuecomment-5%s"}' "$_n" "$_n" ;;
    */issues/comments/*/reactions) printf '{"id":99999,"content":"rocket"}' ;;
    *) printf '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"
run_ng stdout stderr rc wrap-up 42 "$REPORT1352" --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "dispositions test: no shared infra touched"
assert_eq       "#1352 wrap-up exits 0 when every disposition is published" "$rc" "0"
assert_contains "#1352 disposition #1125 published and read back"  "$stdout" "disposition override-org/override-repo#1125: published https://mock.example/issues/1125#issuecomment-51125 (read back OK: VOID-AS-WRITTEN)"
assert_contains "#1352 disposition #932 carries its kind"          "$stdout" "read back OK: ALREADY-ADDRESSED"
assert_contains "#1352 the published SET is printed"               "$stdout" "dispositions: published {override-org/override-repo#1125 override-org/override-repo#1194 override-org/override-repo#932}; NOT published {}"
assert_contains "#1352 the posted body carries the kind and the text" "$(cat "$MOCK_DISP_DIR/1194.body")" "**GENUINELY-OPEN** — residual R1"
assert_contains "#1352 …and the report link"                        "$(cat "$MOCK_DISP_DIR/1194.body")" "Full report: https://github.com/asset-org/"
# RETRY: nothing double-posts — the ledger remembers.
rm -f "$MOCK_DISP_DIR"/*.body
run_ng stdout stderr rc wrap-up 42 "$REPORT1352" --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "dispositions test: no shared infra touched"
assert_contains "#1352 a retry reports the prior publication instead of re-posting" "$stdout" "disposition override-org/override-repo#1125: already published"
assert_eq       "#1352 …and POSTed no disposition comment"          "$(ls "$MOCK_DISP_DIR" | wc -l)" "0"
# NEGATIVE CONTROL: a write the API ACCEPTS but does not STORE is NOT published.
reset_mocks; rm -f "$MOCK_DISP_DIR"/*.body
MOCK_DISP_SWALLOW="1194" run_ng stdout stderr rc wrap-up 42 "$REPORT1352" --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "dispositions test: no shared infra touched"
assert_eq       "#1352 a swallowed disposition write flips the exit" "$rc" "1"
assert_contains "#1352 …and is NAMED as not published"              "$stdout" "NOT published {override-org/override-repo#1194}"
assert_contains "#1352 …with the read-back as the stated reason"    "$stdout" "the read-back did not find this report's marker"
assert_contains "#1352 …while the other two ARE published"          "$stdout" "published {override-org/override-repo#1125 override-org/override-repo#932}"
# report-check refuses a bullet it could never publish.
reset_mocks
printf -- '- #77 — MAYBE-LATER — not a real kind\n' >> "$REPORT1352"
run_ng stdout stderr rc report-check "$REPORT1352"
assert_eq       "#1352 report-check refuses an unknown disposition kind" "$rc" "1"
assert_contains "#1352 …and names the grammar"                      "$(printf '%s\n%s' "$stdout" "$stderr")" "dispositions: bullet does not parse"
unset MOCK_DISP_DIR

# ---- your-org/nexus-code#1140: fan-out completeness gate ----------------
#
# The fixture report's session-id is 4e8f1c2b-…; plant a transcript under a
# private cc-home (NEXUS_CC_HOME) holding THREE top-level `Agent` tool uses
# plus one sidechain (a subagent's own spawn, which must NOT count).
echo '=== #1140: an undeclared fan-out is REFUSED, a declared-short one is STATED ==='
FANOUT_HOME="$WORK/cc-home"; mkdir -p "$FANOUT_HOME/projects/-fake-proj"
FANOUT_TR="$FANOUT_HOME/projects/-fake-proj/4e8f1c2b-3a91-4d77-b9e0-5f2d0a1c7e8a.jsonl"
{
  printf '{"type":"user","message":{"content":"go"}}\n'
  for n in 1 2 3; do
    printf '{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"tool_use","id":"toolu_0%s","name":"Agent","input":{"prompt":"x","name":"leg%s"}}]}}\n' "$n" "$n"
  done
  printf '{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"toolu_09","name":"Agent","input":{"prompt":"nested"}}]}}\n'
  printf '{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"tool_use","id":"toolu_08","name":"Bash","input":{"command":"true"}}]}}\n'
  printf 'not json at all\n'
} > "$FANOUT_TR"
FAN_REPORT="$FAKE_NEXUS/reports/nexus_2026-05-10_120000_fanout-test.md"
write_report "$FAN_REPORT"
# The body-capturing gh stub (the same one Test 11 installs), so the posted
# comment can be read back.
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
reset_mocks; : > "$BODY_CAPTURE"
NEXUS_CC_HOME="$FANOUT_HOME" run_ng stdout stderr rc wrap-up 42 "$FAN_REPORT" --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "fixture"
assert_eq       "#1140 undeclared fan-out: exit 1"                       "$rc" "1"
assert_contains "#1140 undeclared: names the measured spawn count"      "$stderr" "spawned 3 subagent(s)"
assert_contains "#1140 undeclared: prints the line to add"              "$stderr" "fanout: 3 spawned / <returned> returned"
assert_not_contains "#1140 undeclared: nothing was posted"              "$(cat "$GH_CAPTURE" 2>/dev/null)" "/issues/42/comments"
# Declared with the WRONG spawned count -> refused, both numbers named.
sed -i 's/^status: completed$/status: completed\nfanout: 2 spawned \/ 2 returned/' "$FAN_REPORT"
reset_mocks; : > "$BODY_CAPTURE"
NEXUS_CC_HOME="$FANOUT_HOME" run_ng stdout stderr rc wrap-up 42 "$FAN_REPORT" --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "fixture"
assert_eq       "#1140 wrong spawned count: exit 1"                     "$rc" "1"
assert_contains "#1140 wrong spawned count: names both numbers"        "$stderr" "declares 2 spawned but the session transcript records 3"
# Declared SHORT -> published, and the comment CARRIES the incompleteness.
sed -i 's/^fanout: .*$/fanout: 3 spawned \/ 2 returned/' "$FAN_REPORT"
reset_mocks; : > "$BODY_CAPTURE"
NEXUS_CC_HOME="$FANOUT_HOME" run_ng stdout stderr rc wrap-up 42 "$FAN_REPORT" --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "fixture"
assert_eq       "#1140 declared short: exit 0 (publishing a partial fan-out is allowed)" "$rc" "0"
fan_body=$(jq -r '.body // ""' < "$BODY_CAPTURE" 2>/dev/null)
assert_contains "#1140 declared short: the link comment states it"     "$fan_body" "Fan-out INCOMPLETE at wrap-up: 2 of 3 subagents had returned"
assert_contains "#1140 declared short: stderr says so too"              "$stderr" "fan-out INCOMPLETE (2 of 3 returned)"
# Declared complete -> nothing in the comment.
sed -i 's/^fanout: .*$/fanout: 3 spawned \/ 3 returned/' "$FAN_REPORT"
reset_mocks; : > "$BODY_CAPTURE"
NEXUS_CC_HOME="$FANOUT_HOME" run_ng stdout stderr rc wrap-up 42 "$FAN_REPORT" --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "fixture"
assert_eq       "#1140 declared complete: exit 0"                       "$rc" "0"
fan_body=$(jq -r '.body // ""' < "$BODY_CAPTURE" 2>/dev/null)
assert_not_contains "#1140 declared complete: no INCOMPLETE line"      "$fan_body" "Fan-out INCOMPLETE"
# No transcript for the session -> could not look, said on stderr, NOT refused.
sed -i '/^fanout:/d' "$FAN_REPORT"
reset_mocks; : > "$BODY_CAPTURE"
NEXUS_CC_HOME="$WORK/no-such-home" run_ng stdout stderr rc wrap-up 42 "$FAN_REPORT" --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "fixture"
assert_eq       "#1140 no transcript: not refused"                      "$rc" "0"
assert_contains "#1140 no transcript: says the count is UNMEASURED, not zero" "$stderr" "UNMEASURED, not zero"

# ---- your-org/nexus-code#1459: guards-for-diff vs the report ------------
echo '=== #1459: selected guards the report omits are NAMED; --strict-guards refuses ==='
GFD_STUB="$WORK/gfd-stub.sh"
cat > "$GFD_STUB" <<'GFD'
#!/usr/bin/env bash
# a selector stand-in: two selected guards, exit 0
[[ "${1:-}" == --quiet ]] || exit 9
printf 'bash monitor/watcher/test-ng-wrap-up.sh\nbash monitor/watcher/test-never-mentioned-guard.sh\n'
exit "${GFD_STUB_RC:-0}"
GFD
chmod +x "$GFD_STUB"
GUARD_REPORT="$FAKE_NEXUS/reports/nexus_2026-05-10_120000_guards-test.md"
write_report "$GUARD_REPORT"     # its body names test-ng-wrap-up.sh and nothing else
reset_mocks; : > "$BODY_CAPTURE"
NG_GUARDS_FOR_DIFF_BIN="$GFD_STUB" run_ng stdout stderr rc wrap-up 42 "$GUARD_REPORT" --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "fixture" --guards
assert_eq       "#1459 advisory: exit 0 by default"                     "$rc" "0"
assert_contains "#1459 advisory: the omitted guard is NAMED"           "$stderr" "SELECTED BUT NOT REPORTED"
assert_contains "#1459 advisory: …by path"                              "$stderr" "monitor/watcher/test-never-mentioned-guard.sh"
assert_not_contains "#1459 advisory: the guard the report names is not listed" "$stderr" "    monitor/watcher/test-ng-wrap-up.sh"
assert_contains "#1459 advisory: the blind spot is stated beside the answer" "$stderr" "declare no population and are INVISIBLE"
reset_mocks; : > "$BODY_CAPTURE"
NG_GUARDS_FOR_DIFF_BIN="$GFD_STUB" run_ng stdout stderr rc wrap-up 42 "$GUARD_REPORT" --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "fixture" --guards --strict-guards
assert_eq       "#1459 --strict-guards: refused"                        "$rc" "1"
assert_contains "#1459 --strict-guards: says why"                      "$stderr" "REFUSED under --strict-guards"
assert_not_contains "#1459 --strict-guards: nothing was posted"        "$(cat "$GH_CAPTURE" 2>/dev/null)" "/issues/42/comments"
# The selector's exit 3 (nothing reads the diff) is a measured answer, NOT a clearance.
reset_mocks; : > "$BODY_CAPTURE"
GFD_STUB_RC=3 NG_GUARDS_FOR_DIFF_BIN="$GFD_STUB" run_ng stdout stderr rc wrap-up 42 "$GUARD_REPORT" --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "fixture" --guards --strict-guards
assert_eq       "#1459 selector exit 3: not a refusal"                  "$rc" "0"
assert_contains "#1459 selector exit 3: named as NOT a clearance"      "$stderr" "NOT a clearance"
# Not forced and the report is not under the primary corpus: the pre-flight
# does not run at all (a fixture report must never pay the selector).
reset_mocks; : > "$BODY_CAPTURE"
NG_GUARDS_FOR_DIFF_BIN="$GFD_STUB" run_ng stdout stderr rc wrap-up 42 "$GUARD_REPORT" --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "fixture"
assert_not_contains "#1459 automatic arm: a fixture report outside the corpus never runs the selector" "$stderr" "guards pre-flight"

echo '=== #1491: a comment target that does not contain the issue is REFUSED, before anything mutates ==='
# WHAT HAPPENED. A wrap-up passed `--repo <asset-repo>`. That flag selects the
# ISSUE-THREAD target (`--trigger-repo` is the separate knob), so the routing
# behaved as specified — the caller's expectation that it chose the UPLOAD
# destination was the wrong half. The issue lived on another repo, the comment
# POST 404'd, and the run had ALREADY released the skeptic marker and went on
# to write a ledger entry. The thread was never told.
#
# THE RULE THIS RESTORES: order any two-part operation so the failure mode is
# the OBSERVABLE one (#1050). A target this run can prove wrong must stop it
# BEFORE the arming step, not after, where the only remedy is compensation.
#
# THIS SECTION INSTALLS ITS OWN gh STUB, and that is not tidiness.
# `$STUB_DIR/gh` is REWRITTEN a dozen times through this file, each case
# installing the arms it needs; whichever ran last is what a later section
# inherits. The first cut of this section taught its arms to the stub at the
# TOP of the file — long overwritten by the time these cases run — so every
# probe fell through to the `{}` default, `ng` read rc 0, no refusal fired, and
# four assertions reported "the hand-off was not refused". THE MOCK WAS NEVER
# ARMED, and an unarmed mock reads exactly like a working hand-off. A section
# that depends on a mutable global installed elsewhere is testing whatever the
# preceding section left behind.
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"
if [[ "\${1:-}" != "api" ]]; then exit 0; fi
endpoint=""
shift
while (( \$# > 0 )); do
    case "\$1" in
        --input)  cat >/dev/null; shift 2 ;;
        -X|-H|-f) shift 2 ;;
        --)       shift; break ;;
        /*)       endpoint="\$1"; shift ;;
        *)        shift ;;
    esac
done
# ARM ORDER IS LOAD-BEARING. \`*/issues/[0-9]*\` also matches
# \`/repos/O/R/issues/77/comments\`, so the probe arm must come AFTER the
# comment arm or it SHADOWS the POST path this section also exercises — the
# arm-order hazard (#1121), inside a stub written to test a fail-closed
# pre-flight. The probe arm re-anchors on the FULL shape rather than trusting
# position alone, and the third precondition below drives the shadowing case.
case "\$endpoint" in
    */issues/*/comments)           printf '{"html_url":"https://mock.example/cmt-1491"}' ;;
    */issues/comments/*/reactions) printf '{"id":111,"content":"rocket"}' ;;
    */issues/[0-9]*)
        if [[ "\$endpoint" =~ ^/repos/[^/]+/[^/]+/issues/[0-9]+\$ ]]; then
            _pn="\${endpoint##*/}"
            if [[ "\${MOCK_ISSUE_PROBE_ERR:-0}" == "1" ]]; then
                echo 'mock: connection reset' >&2
                exit 1
            fi
            if [[ " \${MOCK_ISSUE_404:-} " == *" \$_pn "* ]]; then
                echo 'gh: Not Found (HTTP 404)' >&2
                exit 1
            fi
            printf '%s' "\$_pn"
        else
            printf '{}'
        fi
        ;;
    *)                             printf '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# PRECONDITIONS on the stub itself, driven directly. Without them every
# "refused / not refused" assertion below rests on a mock nobody checked, which
# is exactly how the first cut passed its controls and failed its positives.
_p1491() { "$STUB_DIR/gh" "$@" >/dev/null 2>&1; printf '%s' "$?"; }
assert_eq "#1491 STUB PRECONDITION: the probe arm 404s the issue it is told to" \
    "$(MOCK_ISSUE_404=4041 _p1491 api -X GET /repos/o/r/issues/4041)" "1"
assert_eq "#1491 STUB PRECONDITION: …and answers 0 for one it is not" \
    "$(MOCK_ISSUE_404=4041 _p1491 api -X GET /repos/o/r/issues/4042)" "0"
assert_eq "#1491 STUB PRECONDITION: …and the comment POST arm is NOT shadowed by it" \
    "$("$STUB_DIR/gh" api -X POST /repos/o/r/issues/4042/comments 2>/dev/null)" \
    '{"html_url":"https://mock.example/cmt-1491"}'

reset_mocks
# EXPORTED, not a command prefix: `run_ng` re-execs `ng` through `env`, and a
# bare `VAR=x run_ng …` sets the variable in this shell without exporting it,
# so the stub never sees it.
export MOCK_TMUX=1 MOCK_TMUX_WINDOW="tgt1491-worker" MOCK_ISSUE_404="4041"
run_ng stdout stderr rc wrap-up 4041 "$REPORT" \
    --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "fixture"
unset MOCK_TMUX MOCK_TMUX_WINDOW MOCK_ISSUE_404
assert_eq       "#1491 a 404 comment target REFUSES (rc 1)"        "$rc" "1"
assert_contains "#1491 …naming the issue and the repo"             "$stderr" \
    'issue #4041 does not exist on `override-org/override-repo`'
assert_contains "#1491 …and correcting the flag that was mis-read" "$stderr" \
    '`--repo` selects the ISSUE-THREAD target'
# THE PROPERTY, and it is the whole issue: nothing mutated. A refusal that had
# already released the marker and written the ledger is the manufactured
# success this check exists to prevent.
assert_eq  "#1491 THE PROPERTY: nothing was uploaded" "$(wc -c < "$UPLOAD_CAPTURE")" "0"
assert_eq  "#1491 …no comment was posted" \
    "$(grep -cE -- '-X (POST|PATCH)|/comments' "$GH_CAPTURE" || true)" "0"
assert_no_file "#1491 …and no pending marker was written" "$STATE_DIR/skeptic/pending/tgt1491-worker"

# CONTROL 1 — the SAME invocation against an issue the target DOES have must
# proceed. Without it the refusal above is satisfied by a check that refuses
# everything.
reset_mocks
run_ng stdout stderr rc wrap-up 4042 "$REPORT" \
    --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "fixture"
assert_eq       "#1491 CONTROL: an issue the target HAS is not refused (rc 0)" "$rc" "0"
assert_contains "#1491 CONTROL: …and the comment really was posted"            "$stdout" "posted comment:"

# CONTROL 2 — "could not look" is NOT a finding. A probe that fails for any
# reason other than a positive 404 (network, rate limit, auth, no gh) must WARN
# and PROCEED: refusing on it would block hand-offs on the strength of a
# question that was never answered — the opposite error, and the more expensive
# one on a board that depends on wrap-up.
reset_mocks
export MOCK_ISSUE_PROBE_ERR=1
run_ng stdout stderr rc wrap-up 4042 "$REPORT" \
    --repo override-org/override-repo --skeptic-decision deny --skeptic-rationale "fixture"
unset MOCK_ISSUE_PROBE_ERR
assert_eq       "#1491 CONTROL: a probe FAILURE (not a 404) does not refuse"  "$rc" "0"
assert_contains "#1491 CONTROL: …it warns, and says it is a failure to LOOK"  "$stderr" "failure to LOOK"

# CONTROL 3 — `--no-comment` posts nothing, so there is no comment target to
# verify and the probe must not run at all. A pre-flight that fires on a path
# it cannot be about is latency and noise, and would refuse a legitimate
# comment-free hand-off.
reset_mocks
export MOCK_ISSUE_404="4041"
run_ng stdout stderr rc wrap-up 4041 "$REPORT" \
    --repo override-org/override-repo --no-comment --skeptic-decision deny --skeptic-rationale "fixture"
unset MOCK_ISSUE_404
assert_eq "#1491 CONTROL: --no-comment skips the target probe entirely" \
    "$(grep -cE -- '-X GET /repos/[^ ]+/issues/4041$' "$GH_CAPTURE" || true)" "0"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
