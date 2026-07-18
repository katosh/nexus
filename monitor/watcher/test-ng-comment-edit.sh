#!/usr/bin/env bash
# Unit tests for `ng comment-edit` + `ng show --meta` — the client-side
# compare-and-swap comment-edit path (your-org/nexus-code#524 defect 1).
#
# Run: bash monitor/watcher/test-ng-comment-edit.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Why client-side CAS: GitHub REST REJECTS conditional request headers
# on this endpoint — PATCH /repos/.../issues/comments/<id> with
# `If-Match` (or `If-Unmodified-Since`) returns HTTP 400 "Conditional
# request headers are not allowed in unsafe requests unless supported
# by the endpoint" (verified live 2026-07-15). So the precondition is
# a re-read + `updated_at` equality check before the PATCH.
#
# Strategy: the `gh` stub is a STATEFUL fake comment store — a JSON
# file holding {body, updated_at} that GET reads and PATCH mutates
# (bumping updated_at). "A concurrent agent edited the comment" is
# simulated by the test mutating the store between the caller's
# `ng show --meta` snapshot and its `ng comment-edit` write — exactly
# the #282 incident shape (correction silently restored ~10 min later
# by a concurrent consolidation pass under the same bot identity).
#
# The load-bearing falsification (test 3): with a STALE snapshot the
# edit must FAIL LOUDLY (exit 4, named stderr) and the store must
# still hold the concurrent agent's text — not ours. The pre-fix
# behaviour (raw `gh api -X PATCH`, last-writer-wins) silently
# clobbers in this scenario; `ng` previously had NO comment-edit verb
# at all, so this suite cannot pass on pre-#524 code by construction.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# NG_UNDER_TEST: path override for RED-on-old verification runs
# (point it at a pre-fix `ng` to demonstrate the suite fails there).
setup_fake_nexus "$WORK/nexus"
if [[ -n "${NG_UNDER_TEST:-}" ]]; then
    cp "$NG_UNDER_TEST" "$FAKE_NEXUS/monitor/ng"
fi
NG="$FAKE_NEXUS/monitor/ng"
STATE_DIR="$FAKE_NEXUS/monitor/.state"

# ---- stateful comment store + gh stub -----------------------------------
#
# STORE is a JSON file: {"body": "...", "updated_at": "..."}.
#   GET   /repos/*/issues/comments/<id>  → the store, plus html_url
#   PATCH /repos/*/issues/comments/<id>  → replace body from the request
#         JSON, bump updated_at (monotonic counter), return the store.
# MOCK_PATCH_TAMPER=1 → PATCH stores the body but RETURNS a tampered
# body, to exercise the post-write verify.
STORE="$WORK/comment-store.json"
SEQ="$WORK/updated-seq"

store_init() {
    local body="$1" ts="${2:-2026-07-15T10:00:00Z}"
    jq -n --arg b "$body" --arg t "$ts" '{body:$b, updated_at:$t}' > "$STORE"
}
store_body()    { jq -r '.body'       "$STORE"; }
store_updated() { jq -r '.updated_at' "$STORE"; }
# Simulate a concurrent agent's write: new body, updated_at moves.
store_concurrent_edit() {
    local body="$1"
    local n
    n=$(( $(cat "$SEQ" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$SEQ"
    jq --arg b "$body" --arg t "2026-07-15T10:30:0${n}Z" \
       '.body=$b | .updated_at=$t' "$STORE" > "$STORE.tmp" && mv "$STORE.tmp" "$STORE"
}

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
GH_CAPTURE="$WORK/gh-calls.txt"

cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$GH_CAPTURE"
if [[ "\${1:-}" != "api" ]]; then exit 0; fi
shift
method="GET"; endpoint=""; body_json=""
while (( \$# > 0 )); do
    case "\$1" in
        -X)       method="\$2"; shift 2 ;;
        --input)  body_json=\$(cat); shift 2 ;;
        -H|-f)    shift 2 ;;
        --)       shift; break ;;
        /*)       endpoint="\$1"; shift ;;
        *)        shift ;;
    esac
done
if ! [ -t 0 ]; then cat >/dev/null 2>&1 || true; fi
case "\$endpoint" in
    */issues/comments/*)
        cid="\${endpoint##*/}"
        if [[ "\$method" == "PATCH" ]]; then
            new_body=\$(jq -r '.body' <<<"\$body_json")
            n=\$(( \$( cat "$SEQ" 2>/dev/null || echo 0 ) + 1 ))
            printf '%s' "\$n" > "$SEQ"
            jq --arg b "\$new_body" --arg t "2026-07-15T11:00:0\${n}Z" \\
               '.body=\$b | .updated_at=\$t' "$STORE" > "$STORE.tmp" \\
               && mv "$STORE.tmp" "$STORE"
            if [[ "\${MOCK_PATCH_TAMPER:-0}" == "1" ]]; then
                jq --arg u "https://mock.example/issues/9#issuecomment-\$cid" \\
                   '.body="TAMPERED BY MIDDLEBOX" | .html_url=\$u' "$STORE"
                exit 0
            fi
        fi
        jq --arg u "https://mock.example/issues/9#issuecomment-\$cid" \\
           '. + {html_url:\$u}' "$STORE"
        ;;
    *) printf '{}' ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    : > "$GH_CAPTURE"
    run_hermetic NEXUS_STATE_DIR="$STATE_DIR" \
        PATH="$(th_hermetic_path "$STUB_DIR:$PATH" "$WORK")" \
        -- "$NG" "$@" >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

CID=4960082155   # the real #282 incident comment id, for verisimilitude

# ---- Test 1: ng show --meta emits the CAS snapshot header ---------------

echo '=== ng show --meta → id/updated_at header + heredoc body ==='
store_init 'original body with the CORRECTED diagnosis' '2026-07-15T10:00:00Z'
run_ng stdout stderr rc show "$CID" --meta --repo o/r
assert_eq       "exit 0 on show --meta"                  "$rc" "0"
assert_contains "meta header carries the comment id"     "$stdout" "id=$CID"
assert_contains "meta header carries updated_at"         "$stdout" \
                "updated_at=2026-07-15T10:00:00Z"
assert_contains "body delivered in the heredoc"          "$stdout" \
                "original body with the CORRECTED diagnosis"
assert_contains "heredoc opener present"                 "$stdout" "body<<EOF"

echo '=== ng show (no --meta) unchanged: bare body only ==='
run_ng stdout stderr rc show "$CID" --repo o/r
assert_eq           "exit 0 on bare show"                "$rc" "0"
assert_contains     "bare body present"                  "$stdout" \
                    "original body with the CORRECTED diagnosis"
assert_not_contains "no meta header without --meta"      "$stdout" "updated_at="

# ---- Test 2: clean CAS edit (snapshot still current) → PATCH lands ------

echo '=== comment-edit with a CURRENT snapshot → exit 0, body replaced ==='
store_init 'stale claim: the watcher was at fault' '2026-07-15T10:00:00Z'
echo "correction: the watcher was NOT at fault; root cause was the shim" > "$WORK/new-body.md"
run_ng stdout stderr rc comment-edit "$CID" --repo o/r \
    --body-file "$WORK/new-body.md" --expect-updated-at '2026-07-15T10:00:00Z'
assert_eq       "exit 0 on clean CAS edit"               "$rc" "0"
assert_contains "prints the comment html_url"            "$stdout" \
                "issuecomment-$CID"
assert_eq       "store now holds the correction"         "$(store_body)" \
                "correction: the watcher was NOT at fault; root cause was the shim"

# ---- Test 3 (LOAD-BEARING): concurrent edit → FAIL LOUD, NO clobber -----
#
# The #282 incident shape: we snapshot, a concurrent agent rewrites the
# comment (same bot identity — unattributable), we write with the stale
# snapshot. Pre-#524 (raw PATCH) our write LANDS and silently destroys
# the concurrent agent's text. The CAS path must refuse: exit 4, a
# stderr message naming the concurrent edit, and the store must still
# hold the CONCURRENT text afterwards.

echo '=== concurrent edit between snapshot and write → exit 4, store NOT clobbered ==='
store_init 'v1: body at snapshot time' '2026-07-15T10:00:00Z'
# Caller snapshots v1 (updated_at 10:00:00Z), prepares an edit...
echo "our edit, spliced against v1" > "$WORK/our-edit.md"
# ...meanwhile a concurrent agent consolidates the comment:
store_concurrent_edit 'v2: CONCURRENT consolidation that restored the old claim'
run_ng stdout stderr rc comment-edit "$CID" --repo o/r \
    --body-file "$WORK/our-edit.md" --expect-updated-at '2026-07-15T10:00:00Z'
assert_eq       "exit 4 on detected concurrent edit"     "$rc" "4"
assert_contains "stderr names the CONCURRENT EDIT"       "$stderr" \
                "CONCURRENT EDIT detected"
assert_contains "stderr shows the updated_at movement"   "$stderr" \
                "2026-07-15T10:00:00Z"
assert_contains "stderr tells the caller to re-read"     "$stderr" \
                "ng show $CID --meta"
assert_eq       "store STILL holds the concurrent text (no clobber)" \
                "$(store_body)" \
                'v2: CONCURRENT consolidation that restored the old claim'
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "no PATCH was issued after the mismatch" "$gh_calls" \
                    " PATCH "
assert_not_contains "html_url NOT printed on refusal"    "$stdout" "issuecomment-"

# ---- Test 4: retry after re-read (fresh snapshot) → succeeds ------------

echo '=== caller re-reads and re-splices → fresh snapshot edit lands ==='
fresh_ts=$(store_updated)
echo "our edit, RE-spliced against v2" > "$WORK/respliced.md"
run_ng stdout stderr rc comment-edit "$CID" --repo o/r \
    --body-file "$WORK/respliced.md" --expect-updated-at "$fresh_ts"
assert_eq       "exit 0 after re-read + re-splice"       "$rc" "0"
assert_eq       "store holds the re-spliced edit"        "$(store_body)" \
                "our edit, RE-spliced against v2"

# ---- Test 5: no --expect-updated-at and no --force → refuse, no write ---

echo '=== bare comment-edit (no CAS token, no --force) → exit 1, no PATCH ==='
store_init 'must not be touched' '2026-07-15T10:00:00Z'
echo "reckless write" > "$WORK/reckless.md"
run_ng stdout stderr rc comment-edit "$CID" --repo o/r --body-file "$WORK/reckless.md"
assert_eq       "exit 1 without a CAS token"             "$rc" "1"
assert_contains "stderr explains the CAS design"         "$stderr" \
                "compare-and-swap by design"
assert_contains "stderr names the append alternative"    "$stderr" "ng reply"
assert_eq       "store untouched"                        "$(store_body)" \
                "must not be touched"
gh_calls=$(<"$GH_CAPTURE")
assert_not_contains "no gh api call at all"              "$gh_calls" " PATCH "

# ---- Test 6: --force → loud last-writer-wins opt-out --------------------

echo '=== --force → PATCH lands with a loud stderr warning ==='
store_init 'body someone else may be editing' '2026-07-15T10:00:00Z'
echo "forced overwrite" > "$WORK/forced.md"
run_ng stdout stderr rc comment-edit "$CID" --repo o/r \
    --body-file "$WORK/forced.md" --force
assert_eq       "exit 0 on --force"                      "$rc" "0"
assert_contains "stderr warns about the missing precondition" "$stderr" \
                "WITHOUT a concurrency precondition"
assert_eq       "store holds the forced body"            "$(store_body)" \
                "forced overwrite"

echo '=== --force + --expect-updated-at → mutually exclusive, exit 1 ==='
run_ng stdout stderr rc comment-edit "$CID" --repo o/r \
    --body-file "$WORK/forced.md" --force --expect-updated-at '2026-07-15T10:00:00Z'
assert_eq       "exit 1 on conflicting flags"            "$rc" "1"
assert_contains "stderr names the conflict"              "$stderr" \
                "mutually exclusive"

# ---- Test 7: post-write verify — stored body differs → fail loud --------

echo '=== PATCH 200 but stored body differs from sent → exit non-zero, loud ==='
store_init 'pre-tamper body' '2026-07-15T10:00:00Z'
echo "what we intended to store" > "$WORK/intended.md"
export MOCK_PATCH_TAMPER=1
run_ng stdout stderr rc comment-edit "$CID" --repo o/r \
    --body-file "$WORK/intended.md" --expect-updated-at '2026-07-15T10:00:00Z'
unset MOCK_PATCH_TAMPER
assert_eq       "non-zero exit on post-write mismatch"   "$rc" "1"
assert_contains "stderr names the stored-body divergence" "$stderr" \
                "stored body differs from what was sent"

# ---- summary ------------------------------------------------------------

th_summary_and_exit
