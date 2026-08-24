#!/usr/bin/env bash
# Unit tests for `ng wrap-up --reply-to <request-id>` — the channel
# delivery variant of the universal hand-off (agent-channel RFC B+D).
#
# Run: bash monitor/watcher/test-ng-wrap-up-reply-to.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# The three claims under test:
#   (a) channel-ONLY mode creates NO GitHub artifact — asserted by a
#       zero-length `gh` capture AND a zero-length upload-asset capture,
#       not by reading the code;
#   (b) the answer genuinely lands on the channel — asserted by reading
#       the resulting `.replied.md` and the byte-exact
#       `replies/<id>/results.md` back through the REAL request-channel.sh;
#   (c) `--reply-to <id> --issue <n>` does BOTH.
#
# Plus: report-check still gates, a failed delivery flips the exit code
# (the requester is blocked on it, so silence would be the worst outcome),
# and the default two-positional form is untouched.
#
# Harness mirrors test-ng-wrap-up.sh: a minimal fake nexus with stubbed
# config/mint-token/upload-asset and a PATH-shadowed `gh` that RECORDS
# every invocation. The request channel is the REAL script — the whole
# point is that wrap-up rides it rather than reimplementing it.
#
# Env robustness (sandbox-masks-CI, skills/nexus.self-fix): every ng
# invocation runs under `env -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME` with
# NEXUS_STATE_DIR pinned to the fixture, and no fixture heredoc
# dereferences a nexus-exported variable.

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
# `ng` sources monitor/_bookkeeping.sh and REFUSES TO START without
# it (your-org/nexus-code#601/#605: degrading to the silent-coercion
# behaviour it replaces is worse than refusing). Copy it alongside.
cp "$(dirname "$NG_REAL")/_bookkeeping.sh" "$FAKE_NEXUS/monitor/_bookkeeping.sh"
NG="$FAKE_NEXUS/monitor/ng"
STATE_DIR="$FAKE_NEXUS/monitor/.state"
REQ_DIR="$STATE_DIR/requests"

# The REAL channel scripts — wrap-up must ride them, not reimplement them.
for _dep in request-channel.sh _channel_lib.sh _fm_lib.sh; do
    cp "$_test_dir/../$_dep" "$FAKE_NEXUS/monitor/$_dep"
done
chmod +x "$FAKE_NEXUS/monitor/request-channel.sh"
CHAN="$FAKE_NEXUS/monitor/request-channel.sh"

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

UPLOAD_CAPTURE="$WORK/upload-calls.txt"
cat > "$FAKE_NEXUS/monitor/upload-asset.sh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$UPLOAD_CAPTURE"
LOCAL=""; ISSUE=""
while (( \$# > 0 )); do
    case "\$1" in
        --issue) ISSUE="\$2"; shift 2 ;;
        --*)     shift 2 ;;
        *)       [[ -z "\$LOCAL" ]] && LOCAL="\$1"; shift ;;
    esac
done
printf 'https://github.com/asset-org/assets/raw/deadbeefcafe1234/assets/%s/%s\\n' \
    "\${ISSUE:-general}" "\$(basename "\$LOCAL")"
STUB
chmod +x "$FAKE_NEXUS/monitor/upload-asset.sh"

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
GH_CAPTURE="$WORK/gh-calls.txt"
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"
[[ "\${1:-}" == "api" ]] || exit 0
endpoint=""; shift
while (( \$# > 0 )); do
    case "\$1" in
        --input) shift 2 ;;
        -X|-H|-f) shift 2 ;;
        --) shift; break ;;
        /*) endpoint="\$1"; shift ;;
        *)  shift ;;
    esac
done
if ! [ -t 0 ]; then cat >/dev/null 2>&1 || true; fi
case "\$endpoint" in
    */issues/*/comments)          printf '{"html_url":"https://mock.example/issuecomment-1234"}' ;;
    */issues/comments/*/reactions) printf '{"id":99999,"content":"rocket"}' ;;
    *)                            printf '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# Run ng hermetically, with the capture files reset per call. TMUX is
# unset: the retain step and the tmux window resolution are covered by
# test-ng-wrap-up.sh; this suite is about the delivery surface.
run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    local _out_tmp _err_tmp _rc
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    : > "$GH_CAPTURE"
    : > "$UPLOAD_CAPTURE"
    env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
        NEXUS_STATE_DIR="$STATE_DIR" \
        MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=0 \
        PATH="$STUB_DIR:$PATH" \
        "$NG" "$@" >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    printf -v "$_out_var" '%s' "$(<"$_out_tmp")"
    printf -v "$_err_var" '%s' "$(<"$_err_tmp")"
    printf -v "$_rc_var"  '%s' "$_rc"
    rm -f "$_out_tmp" "$_err_tmp"
}

# File + claim a request; print its id. The claim is what the watcher does.
new_claimed_request() {
    local slug="$1" id
    id=$(printf 'How many FOXP3+ cells are in the V6 object?\n' \
        | env -u NEXUS_ROOT NEXUS_STATE_DIR="$STATE_DIR" "$CHAN" file \
              --origin remote-operator-client --kind question \
              --reply required --slug "$slug" -) || return 1
    mv "$REQ_DIR/$id.new.md" "$REQ_DIR/$id.claimed.md"
    printf '%s' "$id"
}

chan() { env -u NEXUS_ROOT NEXUS_STATE_DIR="$STATE_DIR" "$CHAN" "$@"; }

REPORT="$FAKE_NEXUS/reports/nexus_2026-07-23_120000_channel-answer.md"
write_report() {
    cat > "$1" <<'EOF'
---
project: nexus
date: 2026-07-23
session-id: 4e8f1c2b-3a91-4d77-b9e0-5f2d0a1c7e8a
window: channel-worker
trigger: request 20260723T000000Z-remote-operator-client-demo
status: completed
---

# Channel answer: FOXP3+ counts in the V6 object

## Summary

ANSWER_TOKEN_9f3c: there are 7 FOXP3+ regulatory T cells in the V6
object. FOXP3 is on the measured panel, so this is a measured count
rather than an imputed one, and the number is directly comparable
across the cohort.

## What Was Done

- Loaded the V6 store and subset to FOXP3-positive cells.
- Confirmed FOXP3 is panel-measured rather than imputed.
- Cross-checked the count against the within-sample layer.
- Recorded the query so the number is reproducible.
- Verified no duplicate cell ids inflate the count.

## Current State

The count is final; the notebook cell is committed.

## What Remains

Nothing for this request.

## How to Resume

Re-run the notebook cell tagged foxp3-count.
EOF
}
write_report "$REPORT"

# ---- W1: channel-only wrap-up creates NO GitHub artifact ---------------

echo '=== W1: --reply-to alone delivers to the channel and touches no GitHub ==='

ID1=$(new_claimed_request "w1-question")
run_ng stdout stderr rc wrap-up --reply-to "$ID1" "$REPORT"
assert_eq       "channel-only wrap-up exits 0"            "$rc" "0"
assert_contains "stdout reports the channel delivery"     "$stdout" "channel reply: $ID1"
assert_contains "stdout marks the upload skipped"         "$stdout" "uploaded: SKIPPED (channel-only"
assert_contains "stdout marks the comment skipped"        "$stdout" "posted comment: SKIPPED (channel-only"
assert_contains "stdout logs reply-to, not an issue"      "$stdout" "logged action: wrap-up reply-to=$ID1"

# (a) NO GitHub artifact — the capture files are the evidence.
assert_eq "NO gh invocation at all"            "$(wc -c < "$GH_CAPTURE" | tr -d ' ')"     "0"
assert_eq "NO upload-asset invocation at all"  "$(wc -c < "$UPLOAD_CAPTURE" | tr -d ' ')" "0"

# (b) the answer really landed on the channel.
assert_file_exists "request transitioned to .replied" "$REQ_DIR/$ID1.replied.md"
assert_eq       "channel status word is replied"      "$(chan fetch "$ID1" status)" "replied"
results=$(chan fetch "$ID1" results)
assert_contains "results carry the report's Summary"  "$results" "ANSWER_TOKEN_9f3c"
assert_contains "results carry the full Summary body" "$results" "comparable"
assert_contains "results footer names the report"     "$results" "report: $REPORT"
assert_not_contains "results do NOT leak other report sections" "$results" "How to Resume"
assert_not_contains "results carry no asset url (none was minted)" "$results" "report-asset:"

replied=$(cat "$REQ_DIR/$ID1.replied.md")
assert_contains "reply frontmatter status is answered" "$replied" "status: answered"
assert_not_contains "reply frontmatter has no github_issue" "$replied" "github_issue"

# (c) the wrap-up event is on the action log with the channel outcome.
log=$(cat "$STATE_DIR/action-log.jsonl")
assert_contains "action log records reply-to"  "$log" "\"reply-to\":\"$ID1\""
assert_contains "action log records channel=ok" "$log" "\"channel\":\"ok\""

# ---- W2: --answer-file supplies the body verbatim ----------------------

echo '=== W2: --answer-file replaces the Summary as the reply body ==='

ID2=$(new_claimed_request "w2-question")
ANSWER="$WORK/answer.tsv"
printf 'sample\tfoxp3_cells\nMH1\t7\nBE_2306\t41\n' > "$ANSWER"
run_ng stdout stderr rc wrap-up --reply-to "$ID2" "$REPORT" --answer-file "$ANSWER"
assert_eq       "--answer-file wrap-up exits 0"       "$rc" "0"
results=$(chan fetch "$ID2" results)
assert_contains "results carry the answer file bytes" "$results" "BE_2306	41"
assert_not_contains "results do NOT carry the Summary" "$results" "ANSWER_TOKEN_9f3c"
assert_contains "results still carry the report footer" "$results" "report: $REPORT"
assert_eq "still NO gh invocation" "$(wc -c < "$GH_CAPTURE" | tr -d ' ')" "0"

# ---- W3: --reply-to --issue does BOTH ----------------------------------

echo '=== W3: --reply-to --issue posts to GitHub AND replies on the channel ==='

ID3=$(new_claimed_request "w3-question")
run_ng stdout stderr rc wrap-up --reply-to "$ID3" "$REPORT" --issue 297 \
    --repo override-org/override-repo
assert_eq       "both-mode wrap-up exits 0"           "$rc" "0"
assert_contains "both-mode uploaded the report"       "$stdout" "uploaded: https://github.com/asset-org"
assert_contains "both-mode posted the link comment"   "$stdout" "posted comment: https://mock.example"
assert_contains "both-mode delivered on the channel"  "$stdout" "channel reply: $ID3"
assert_contains "upload targeted issue 297"           "$(cat "$UPLOAD_CAPTURE")" "--issue 297"
assert_contains "comment POSTed to the override repo" "$(cat "$GH_CAPTURE")" \
                "/repos/override-org/override-repo/issues/297/comments"
results=$(chan fetch "$ID3" results)
assert_contains "channel reply carries the asset url"   "$results" "report-asset: https://github.com/asset-org"
assert_contains "channel reply carries the comment url" "$results" "issue-comment: https://mock.example"
assert_contains "reply frontmatter names the issue" \
    "$(cat "$REQ_DIR/$ID3.replied.md")" "github_issue: override-org/override-repo#297"

# The legacy two-positional shape also works alongside --reply-to.
ID3b=$(new_claimed_request "w3b-question")
run_ng stdout stderr rc wrap-up 298 "$REPORT" --reply-to "$ID3b" \
    --repo override-org/override-repo
assert_eq       "positional issue + --reply-to exits 0" "$rc" "0"
assert_contains "positional issue reached the upload"   "$(cat "$UPLOAD_CAPTURE")" "--issue 298"
assert_contains "positional issue also replied"         "$stdout" "channel reply: $ID3b"

# ---- W4: report-check still gates the channel path ---------------------

echo '=== W4: a stub report is refused BEFORE anything is delivered ==='

ID4=$(new_claimed_request "w4-question")
STUB_REPORT="$WORK/stub-report.md"
printf '# Stub\n\n## Summary\n\nTODO\n' > "$STUB_REPORT"
run_ng stdout stderr rc wrap-up --reply-to "$ID4" "$STUB_REPORT"
assert_eq       "stub report fails the wrap-up"       "$rc" "1"
assert_contains "failure names report-check"          "$stderr" "report-check failed"
assert_eq       "request is still claimed (no reply)" "$(chan fetch "$ID4" status)" "claimed"

# ---- W5: an empty answer body FAILS rather than delivering nothing -----

echo '=== W5: an empty answer body fails the wrap-up ==='

ID5=$(new_claimed_request "w5-question")
EMPTY_ANSWER="$WORK/empty-answer.txt"
: > "$EMPTY_ANSWER"
run_ng stdout stderr rc wrap-up --reply-to "$ID5" "$REPORT" --answer-file "$EMPTY_ANSWER"
assert_eq       "empty answer fails the wrap-up"      "$rc" "1"
assert_contains "failure explains the empty answer"   "$stderr" "answer body is EMPTY"
assert_eq       "request is still claimed (no reply)" "$(chan fetch "$ID5" status)" "claimed"

# A fenced code block whose content starts with `## ` must NOT truncate the
# answer — the requester has no way to notice a half-delivered reply.
echo '=== W5b: a ```-fenced `## ` line does not truncate the answer ==='

ID5b=$(new_claimed_request "w5b-question")
FENCE_REPORT="$WORK/fence-report.md"
{
    sed -n '1,/^## Summary$/p' "$REPORT"
    cat <<'FENCE'

Answer line one.

```bash
## a comment inside a fence, not a heading
echo FENCE_TAIL_TOKEN
```

Answer line two.
FENCE
    sed -n '/^## What Was Done$/,$p' "$REPORT"
} > "$FENCE_REPORT"
run_ng stdout stderr rc wrap-up --reply-to "$ID5b" "$FENCE_REPORT"
assert_eq       "fenced-Summary wrap-up exits 0"        "$rc" "0"
results=$(chan fetch "$ID5b" results)
assert_contains "answer survives past the fenced ## line" "$results" "Answer line two."
assert_contains "the fence content is delivered intact"   "$results" "FENCE_TAIL_TOKEN"
assert_not_contains "the next section is still excluded"  "$results" "How to Resume"

# ---- W6: a failed channel delivery flips the exit code -----------------

echo '=== W6: replying twice fails loudly instead of reporting success ==='

ID6=$(new_claimed_request "w6-question")
run_ng stdout stderr rc wrap-up --reply-to "$ID6" "$REPORT"
assert_eq "first delivery exits 0" "$rc" "0"
run_ng stdout stderr rc wrap-up --reply-to "$ID6" "$REPORT"
assert_eq       "second delivery FAILS the wrap-up"   "$rc" "1"
assert_contains "stdout marks the channel FAILED"     "$stdout" "channel reply: FAILED"
assert_contains "stderr names the channel step"       "$stderr" "channel: ng request reply"

# ---- W7: flag-shape guards ---------------------------------------------

echo '=== W7: the channel flags are refused where they would be inert ==='

run_ng stdout stderr rc wrap-up 42 "$REPORT" --issue 43
assert_eq       "--issue without --reply-to dies"     "$rc" "1"
assert_contains "…and says why"                       "$stderr" "only valid with --reply-to"

run_ng stdout stderr rc wrap-up 42 "$REPORT" --answer-file "$ANSWER"
assert_eq       "--answer-file without --reply-to dies" "$rc" "1"
assert_contains "…and says why"                         "$stderr" "supplies the CHANNEL reply body"

ID7=$(new_claimed_request "w7-question")
run_ng stdout stderr rc wrap-up --reply-to "$ID7" "$REPORT" --trigger-comment 7777
assert_eq       "--trigger-comment without an issue dies" "$rc" "1"
assert_contains "…and points at --issue"                  "$stderr" "needs a GitHub thread"
assert_eq       "…leaving the request untouched"          "$(chan fetch "$ID7" status)" "claimed"

run_ng stdout stderr rc wrap-up --reply-to 'bad/../id' "$REPORT"
assert_eq       "malformed request id dies"           "$rc" "1"
assert_contains "…on the id charset"                  "$stderr" "[A-Za-z0-9_-]"

run_ng stdout stderr rc wrap-up --reply-to "$ID7"
assert_eq       "--reply-to with no report dies"      "$rc" "1"
assert_contains "…with the channel usage line"        "$stderr" "--reply-to <request-id> <report-path>"

# ---- W8: the DEFAULT two-positional form is untouched ------------------

echo '=== W8: the default <issue> <report> form behaves exactly as before ==='

run_ng stdout stderr rc wrap-up 42 "$REPORT" --trigger-comment 7777 \
    --repo override-org/override-repo
assert_eq       "default wrap-up exits 0"             "$rc" "0"
assert_contains "default uploads"                     "$stdout" "uploaded: https://github.com/asset-org"
assert_contains "default posts the comment"           "$stdout" "posted comment: https://mock.example"
assert_contains "default rockets the trigger"         "$stdout" "rocketed comment 7777"
assert_contains "default logs issue=, not reply-to="  "$stdout" "logged action: wrap-up issue=42"
assert_not_contains "default prints no channel line"  "$stdout" "channel reply:"
last_wrapup=$(grep '"event":"wrap-up"' "$STATE_DIR/action-log.jsonl" | tail -1)
assert_not_contains "default logs no channel field"   "$last_wrapup" "\"channel\":"
assert_not_contains "default logs no reply-to field"  "$last_wrapup" "\"reply-to\":"
assert_contains "default still records issue="        "$last_wrapup" "\"issue\":\"42\""
assert_contains "default still records repo="         "$last_wrapup" \
                "\"repo\":\"override-org/override-repo\""

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
