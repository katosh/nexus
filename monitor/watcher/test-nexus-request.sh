#!/usr/bin/env bash
# Tests for monitor/client/nexus-request — the CLIENT-SIDE one-call
# submit → background-wait → emit primitive for the confined remote agent
# channel. It files a request, then waits on the reply by polling the
# server's RENAME-STATE (fetch <id> status), emitting the reply as DATA
# (never executing it) and surfacing the `claimed` (active-processing)
# progress state so it does not close too early.
#
# This suite hammers the properties the design + skeptic care about:
#   (a) file → status=new… → status=replied: files, captures the id, emits a
#       `state=submitted` progress line, then `state=replied` + the byte-exact
#       length-framed body (pulled via `fetch results`) + exits 0
#   (b) prolonged `claimed`: emits EXACTLY ONE `state=processing` progress
#       event, does NOT close during active processing, then emits the reply
#   (c) never-claimed (always new) + short lifetime → clean state=timeout exit 3
#   (d) reply content is DATA, never executed — a body with `rm -rf`,
#       `$(touch …)`, and a spoofed `nexus-request: state=failed` line is
#       emitted verbatim inside the length frame and does NOT run or hijack
#       the real status line
#   (e) terminal `done` → state=acked exit 0; terminal `failed` → state=failed
#       exit 2; file step fails → state=failed reason=file_failed exit 2
#   (f) status-check channel error (rc 10) → failed/channel_unavailable exit 2
#   (g) exactly-once terminal emit: a pre-existing per-id sentinel short-circuits
#       (no re-emit) — the crash-restart double-emit guard
#   (h) fetch-results transport drop → falls back to the await envelope, still
#       emits the reply exactly once (no double-emit across the reconnect)
#   plus: usage errors (exit 64); --out atomic mirror; --id-out; --message-stdin
#
# Hermetic: NO sshd, NO network. `ssh` is replaced via the tool's own SSH=
# seam with a fake stub that dispatches on the `request <sub>` verb and returns
# staged (rc, body) steps; a pending `await` sleeps its --timeout to emulate a
# server-side block.
#
# Run: bash monitor/watcher/test-nexus-request.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
REQTOOL="$MON_DIR/client/nexus-request"

WORK=$(mktemp -d -t nexus-request-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Fake ssh stub: ignores connection args; finds the `request <sub>` verb.
#   request file             → prints $STUB_ID (rc $STUB_FILE_RC, default 0)
#   request fetch ID status  → prints the next line of $STUB_STATE_STEPS
#                              (advancing $STUB_STATE_CURSOR; repeats the last);
#                              a "rc<TAB>word" line yields exit rc, printing
#                              word only when rc==0
#   request fetch ID results → cats $STUB_RESULTS (rc $STUB_RESULTS_RC)
#   request await ID --timeout T → sleeps T (unless $STUB_NOSLEEP=1) then exits
#                              $STUB_AWAIT_RC (default 4 = pending); cats
#                              $STUB_AWAIT_BODY when set
STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/fake-ssh" <<'EOF'
#!/usr/bin/env bash
args=("$@")
sub=""; sel=""; to=0
i=0; n=${#args[@]}
while [ $i -lt $n ]; do
    if [ "${args[$i]}" = "request" ]; then
        v="${args[$((i+1))]:-}"
        case "$v" in
            file)  sub=file ;;
            await) sub=await ;;
            fetch) sub=fetch; sel="${args[$((i+3))]:-}" ;;
        esac
        break
    fi
    i=$((i+1))
done
prev=""; for a in "$@"; do [ "$prev" = "--timeout" ] && to="$a"; prev="$a"; done

case "$sub" in
    file)
        rc=${STUB_FILE_RC:-0}
        # Capture the request BODY (our stdin) for byte-fidelity assertions.
        # This is the seam the D1 defect hid behind: the old stub never read
        # stdin, so an empty-body regression (remote() swallowing fd 0) was
        # invisible. Reading it here makes the byte path testable end-to-end.
        if [ -n "${STUB_FILE_BODY_OUT:-}" ]; then
            cat > "$STUB_FILE_BODY_OUT"
        fi
        [ "$rc" = 0 ] && printf '%s\n' "${STUB_ID:-t-req}"
        exit "$rc"
        ;;
    fetch)
        case "$sel" in
            status)
                c=$(cat "$STUB_STATE_CURSOR" 2>/dev/null || echo 1)
                echo $((c + 1)) > "$STUB_STATE_CURSOR"
                line=$(sed -n "${c}p" "$STUB_STATE_STEPS")
                [ -z "$line" ] && line=$(sed -n '$p' "$STUB_STATE_STEPS")
                if printf '%s' "$line" | grep -q $'\t'; then
                    rc=${line%%$'\t'*}; word=${line#*$'\t'}
                else
                    rc=0; word=$line
                fi
                [ "$rc" = 0 ] && printf '%s\n' "$word"
                exit "$rc"
                ;;
            results)
                rc=${STUB_RESULTS_RC:-0}
                [ "$rc" = 0 ] && cat "$STUB_RESULTS" 2>/dev/null
                exit "$rc"
                ;;
        esac
        exit 0
        ;;
    await)
        [ "${STUB_NOSLEEP:-0}" = 1 ] || { [ "$to" -gt 0 ] 2>/dev/null && sleep "$to"; }
        arc=${STUB_AWAIT_RC:-4}
        [ -n "${STUB_AWAIT_BODY:-}" ] && { [ "$arc" = 0 ] || [ "$arc" = 2 ]; } && cat "$STUB_AWAIT_BODY" 2>/dev/null
        exit "$arc"
        ;;
esac
exit 0
EOF
chmod +x "$STUB/fake-ssh"

export SSH="$STUB/fake-ssh"
export NEXUS_REQUEST_STATE="$WORK/state"
export NEXUS_WATCH_BACKOFF_BASE=1
export NEXUS_WATCH_BACKOFF_CAP=2

# run_req <tag> [extra args…]  → sets OUT/ERROUT/RC. Resets the state cursor.
# Callers export STUB_* knobs before invoking.
run_req() {
    local tag="$1"; shift
    export STUB_STATE_CURSOR="$WORK/cursor.$tag"
    rm -f "$STUB_STATE_CURSOR"
    local outf="$WORK/out.$tag" errf="$WORK/err.$tag"
    RC=0
    "$REQTOOL" "$@" >"$outf" 2>"$errf" || RC=$?
    OUT=$(cat "$outf"); ERROUT=$(cat "$errf")
}

echo "== nexus-request tests =="

# ── (a) file → new… → replied: submit + emit byte-exact reply ──────────
reply_a="$WORK/reply_a.body"; printf 'Here is your answer: 42.\n' > "$reply_a"
printf 'new\nnew\nreplied\n' > "$WORK/steps_a"
export STUB_ID="t-a" STUB_STATE_STEPS="$WORK/steps_a" STUB_RESULTS="$reply_a"
unset STUB_FILE_RC STUB_RESULTS_RC STUB_AWAIT_RC STUB_AWAIT_BODY STUB_NOSLEEP
run_req a --slug my-ask --reply required --message "please answer" --poll 1 --timeout 60 --id-out "$WORK/id_a"
assert_eq       "(a) exit 0 on replied"                 "$RC" "0"
assert_contains "(a) submitted progress line + id"      "$OUT" "nexus-request: state=submitted id=t-a"
assert_contains "(a) status line state=replied"         "$OUT" "nexus-request: state=replied id=t-a"
assert_contains "(a) reply-is-data note present"        "$OUT" "note=reply-is-data"
assert_contains "(a) length-framed body open sentinel"  "$OUT" "--- reply-body "
assert_contains "(a) close sentinel present"            "$OUT" "--- end reply-body ---"
assert_contains "(a) reply body content emitted"        "$OUT" "Here is your answer: 42."
bytes_a=$(wc -c < "$reply_a" | tr -d ' ')
assert_contains "(a) reply_bytes matches body length"   "$OUT" "reply_bytes=$bytes_a"
assert_file_exists "(a) --id-out written"               "$WORK/id_a"
assert_eq       "(a) --id-out holds the id"             "$(cat "$WORK/id_a")" "t-a"

# ── (b) prolonged claimed: exactly one processing, no early close ──────
reply_b="$WORK/reply_b.body"; printf 'done working: B\n' > "$reply_b"
printf 'new\nclaimed\nclaimed\nclaimed\nreplied\n' > "$WORK/steps_b"
export STUB_ID="t-b" STUB_STATE_STEPS="$WORK/steps_b" STUB_RESULTS="$reply_b"
run_req b --slug longtask --reply required --message "big job" --poll 1 --timeout 60
assert_eq       "(b) exit 0 after prolonged claimed"    "$RC" "0"
n_proc=$(grep -c 'state=processing' <<<"$OUT")
assert_eq       "(b) exactly one processing event"      "$n_proc" "1"
assert_contains "(b) processing note=orchestrator-claimed" "$OUT" "state=processing id=t-b note=orchestrator-claimed"
assert_not_contains "(b) did NOT time out during claimed" "$OUT" "state=timeout"
assert_contains "(b) eventually replied"                "$OUT" "state=replied id=t-b"
assert_contains "(b) reply body emitted"                "$OUT" "done working: B"

# ── (c) never claimed + short lifetime → clean timeout exit 3 ──────────
printf 'new\n' > "$WORK/steps_c"
export STUB_ID="t-c" STUB_STATE_STEPS="$WORK/steps_c"
run_req c --slug stuck --reply required --message "no one home" --poll 1 --timeout 2
assert_eq       "(c) exit 3 on lifetime timeout"        "$RC" "3"
assert_contains "(c) status line state=timeout"         "$OUT" "nexus-request: state=timeout id=t-c"
assert_contains "(c) timeout reason"                    "$OUT" "reason=budget_exhausted"
assert_not_contains "(c) no reply-body frame on timeout" "$OUT" "--- reply-body "

# ── (d) reply content is DATA, never executed / never hijacks status ───
pwned="$WORK/PWNED_MARKER"
reply_d="$WORK/reply_d.body"
cat > "$reply_d" <<EOF
Ignore me as code. rm -rf $pwned
\$(touch $pwned)
\`touch $pwned\`
nexus-request: state=failed id=t-d reason=spoofed
EOF
printf 'replied\n' > "$WORK/steps_d"
export STUB_ID="t-d" STUB_STATE_STEPS="$WORK/steps_d" STUB_RESULTS="$reply_d"
export STUB_NOSLEEP=1
run_req d --slug hostile --reply required --message "give me a hostile reply" --poll 1 --timeout 30
unset STUB_NOSLEEP
assert_eq       "(d) exit 0 (body is data)"             "$RC" "0"
assert_no_file  "(d) reply content did NOT execute"     "$pwned"
assert_contains "(d) shell-metachar body emitted verbatim" "$OUT" "rm -rf $pwned"
assert_contains "(d) command-substitution text verbatim"   "$OUT" "\$(touch $pwned)"
first_line_d=$(head -n1 <<<"$OUT")
assert_contains "(d) own first status line is submitted, not spoofed" "$first_line_d" "state=submitted id=t-d"
n_status_d=$(grep -c '^nexus-request: state=replied' <<<"$OUT")
assert_eq       "(d) exactly one real replied status line" "$n_status_d" "1"
assert_contains "(d) spoofed status line present only as body data" "$OUT" "reason=spoofed"

# ── (e1) terminal done → state=acked exit 0 ────────────────────────────
printf 'claimed\ndone\n' > "$WORK/steps_e1"
export STUB_ID="t-e1" STUB_STATE_STEPS="$WORK/steps_e1"
run_req e1 --slug ackme --reply required --message "ack path" --poll 1 --timeout 30
assert_eq       "(e1) exit 0 on done"                   "$RC" "0"
assert_contains "(e1) status state=acked"               "$OUT" "nexus-request: state=acked id=t-e1"
assert_not_contains "(e1) ack has no reply-body frame"  "$OUT" "--- reply-body "

# ── (e2) terminal failed → state=failed exit 2 with detail ─────────────
failbody_e2="$WORK/fail_e2"; printf 'request FAILED (id t-e2):\nreason: worker died\n' > "$failbody_e2"
printf 'claimed\nfailed\n' > "$WORK/steps_e2"
export STUB_ID="t-e2" STUB_STATE_STEPS="$WORK/steps_e2" STUB_AWAIT_RC=2 STUB_AWAIT_BODY="$failbody_e2" STUB_NOSLEEP=1
run_req e2 --slug failme --reply required --message "fail path" --poll 1 --timeout 30
unset STUB_AWAIT_RC STUB_AWAIT_BODY STUB_NOSLEEP
assert_eq       "(e2) exit 2 on terminal failure"       "$RC" "2"
assert_contains "(e2) status state=failed"              "$OUT" "nexus-request: state=failed id=t-e2"
assert_contains "(e2) reason=terminal_failed"           "$OUT" "reason=terminal_failed"

# ── (e3) file step fails → state=failed reason=file_failed exit 2 ──────
export STUB_ID="t-e3" STUB_FILE_RC=12 STUB_STATE_STEPS="$WORK/steps_a"
run_req e3 --slug cantfile --reply required --message "server refuses file" --poll 1 --timeout 30
unset STUB_FILE_RC
assert_eq       "(e3) exit 2 when file step fails"      "$RC" "2"
assert_contains "(e3) reason=file_failed"               "$OUT" "reason=file_failed"
assert_not_contains "(e3) no submitted line when file failed" "$OUT" "state=submitted"

# ── (f) status-check channel error (rc 10) → channel_unavailable exit 2 ─
printf '10\tnew\n' > "$WORK/steps_f"     # fetch status exits 10
export STUB_ID="t-f" STUB_STATE_STEPS="$WORK/steps_f"
run_req f --slug chan --reply required --message "channel gone" --poll 1 --timeout 30
assert_eq       "(f) exit 2 on channel-unavailable"     "$RC" "2"
assert_contains "(f) reason=channel_unavailable"        "$OUT" "reason=channel_unavailable"

# ── (f2) status-check id-not-found (rc 2) → not_found exit 2 ───────────
# fetch-status rc 2 is VERB-SPECIFIC (fetch: id not found — distinct from
# await's rc 2 = terminal_failed) and is matched before the shared rc table.
printf '2\tnew\n' > "$WORK/steps_f2"     # fetch status exits 2 (id not found / GC'd)
export STUB_ID="t-f2" STUB_STATE_STEPS="$WORK/steps_f2"
run_req f2 --slug gone --reply required --message "vanished id" --poll 1 --timeout 30
assert_eq       "(f2) exit 2 on not-found"              "$RC" "2"
assert_contains "(f2) status state=failed"             "$OUT" "nexus-request: state=failed id=t-f2"
assert_contains "(f2) reason=not_found"                "$OUT" "reason=not_found"
assert_not_contains "(f2) not-found did NOT time out"  "$OUT" "state=timeout"

# ── (g) exactly-once: a pre-existing sentinel short-circuits the emit ───
mkdir -p "$NEXUS_REQUEST_STATE"
: > "$NEXUS_REQUEST_STATE/t-g.emitted"
printf 'replied\n' > "$WORK/steps_g"
export STUB_ID="t-g" STUB_STATE_STEPS="$WORK/steps_g" STUB_RESULTS="$reply_a" STUB_NOSLEEP=1
run_req g --slug oncetest --reply required --message "should not re-emit" --poll 1 --timeout 30
unset STUB_NOSLEEP
assert_eq       "(g) exit 0 when sentinel present"      "$RC" "0"
assert_not_contains "(g) no reply-body re-emitted"      "$OUT" "--- reply-body "
assert_contains "(g) logs the short-circuit"            "$ERROUT" "already emitted"

# ── (h) fetch-results transport drop → await-envelope fallback, once ───
env_h="$WORK/reply_h.env"
cat > "$env_h" <<'EOF'
---
request: t-h
state: replied
---

## Reply

FALLBACK-BODY-H via await envelope.
EOF
printf 'replied\n' > "$WORK/steps_h"
export STUB_ID="t-h" STUB_STATE_STEPS="$WORK/steps_h" STUB_RESULTS_RC=255 \
       STUB_AWAIT_RC=0 STUB_AWAIT_BODY="$env_h" STUB_NOSLEEP=1
run_req h --slug dropresults --reply required --message "results drop" --poll 1 --timeout 30
unset STUB_RESULTS_RC STUB_AWAIT_RC STUB_AWAIT_BODY STUB_NOSLEEP
assert_eq       "(h) exit 0 via await fallback"         "$RC" "0"
assert_contains "(h) fallback body emitted"             "$OUT" "FALLBACK-BODY-H via await envelope."
n_repl_h=$(grep -c '^nexus-request: state=replied' <<<"$OUT")
assert_eq       "(h) exactly one replied status line"   "$n_repl_h" "1"

# ── (i) --message-stdin streams the body BYTE-EXACT (the D1 regression) ─
# A tricky body: real TAB, literal backslash, an embedded newline, and NO
# trailing newline. The stub captures our stdin to a file; we assert its
# sha256 equals the source. Pre-fix (remote() hard-redirecting </dev/null),
# the captured body was 0 bytes and this FAILS — exactly the regression that
# shipped to main because the old stub never read stdin.
sha_of() {  # sha256 hex of a file, portable across sha256sum / shasum
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum   >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
}
body_fx="$WORK/body_fidelity"
printf 'a\tb\\c\nsecond line, no trailing newline' > "$body_fx"
src_sha=$(sha_of "$body_fx")

printf 'new\nreplied\n' > "$WORK/steps_i"
export STUB_ID="t-i" STUB_STATE_STEPS="$WORK/steps_i" STUB_RESULTS="$reply_a"

# (i-stdin) body delivered via --message-stdin
export STUB_FILE_BODY_OUT="$WORK/captured_stdin_body"
rm -f "$STUB_FILE_BODY_OUT"; export STUB_STATE_CURSOR="$WORK/cursor.i_stdin"; rm -f "$STUB_STATE_CURSOR"
RC=0
"$REQTOOL" --slug streamed --reply required --message-stdin \
    --poll 1 --timeout 30 <"$body_fx" >"$WORK/out.i_stdin" 2>"$WORK/err.i_stdin" || RC=$?
OUT=$(cat "$WORK/out.i_stdin")
assert_eq       "(i-stdin) exit 0 with --message-stdin"      "$RC" "0"
assert_contains "(i-stdin) replied after stdin submit"       "$OUT" "state=replied id=t-i"
assert_file_exists "(i-stdin) server received a body"        "$STUB_FILE_BODY_OUT"
assert_eq       "(i-stdin) body delivered BYTE-EXACT"        "$(sha_of "$STUB_FILE_BODY_OUT")" "$src_sha"

# (i-file) same body delivered via --message-file (distinct id — a shared id
# would trip the exactly-once sentinel from the i-stdin run above)
printf 'new\nreplied\n' > "$WORK/steps_i2"
export STUB_ID="t-i2" STUB_STATE_STEPS="$WORK/steps_i2"
rm -f "$STUB_FILE_BODY_OUT"; export STUB_STATE_CURSOR="$WORK/cursor.i_file"; rm -f "$STUB_STATE_CURSOR"
RC=0
"$REQTOOL" --slug streamedfile --reply required --message-file "$body_fx" \
    --poll 1 --timeout 30 >"$WORK/out.i_file" 2>"$WORK/err.i_file" || RC=$?
OUT=$(cat "$WORK/out.i_file")
assert_eq       "(i-file) exit 0 with --message-file"        "$RC" "0"
assert_contains "(i-file) replied after file submit"         "$OUT" "state=replied id=t-i2"
assert_file_exists "(i-file) server received a body"         "$STUB_FILE_BODY_OUT"
assert_eq       "(i-file) body delivered BYTE-EXACT"         "$(sha_of "$STUB_FILE_BODY_OUT")" "$src_sha"
unset STUB_FILE_BODY_OUT

# ── (j) usage errors → exit 64, nothing on stdout ──────────────────────
RC=0; badout=$("$REQTOOL" --slug 'bad/slug' --message x 2>/dev/null) || RC=$?
assert_eq       "(j) illegal slug → exit 64"            "$RC" "64"
assert_empty    "(j) usage error emits nothing on stdout" "$badout"
RC=0; "$REQTOOL" --message x >/dev/null 2>&1 || RC=$?
assert_eq       "(j) missing --slug → exit 64"          "$RC" "64"
RC=0; "$REQTOOL" --slug s >/dev/null 2>&1 || RC=$?
assert_eq       "(j) missing message → exit 64"         "$RC" "64"
RC=0; "$REQTOOL" --slug s --message x --poll abc >/dev/null 2>&1 || RC=$?
assert_eq       "(j) non-integer --poll → exit 64"      "$RC" "64"

# ── (k) --out atomic mirror carries the terminal emit ──────────────────
outfile="$WORK/reply.out"
printf 'replied\n' > "$WORK/steps_k"
export STUB_ID="t-k" STUB_STATE_STEPS="$WORK/steps_k" STUB_RESULTS="$reply_a" STUB_NOSLEEP=1
run_req k --slug outmirror --reply required --message "mirror me" --poll 1 --timeout 30 --out "$outfile"
unset STUB_NOSLEEP
assert_eq       "(k) exit 0 with --out"                 "$RC" "0"
assert_file_exists "(k) --out file written"             "$outfile"
assert_contains "(k) --out carries the status line"     "$(cat "$outfile")" "state=replied id=t-k"
assert_contains "(k) --out carries the body"            "$(cat "$outfile")" "Here is your answer: 42."
assert_no_file  "(k) no leftover --out temp"            "$outfile.tmp.$$"

th_summary_and_exit
