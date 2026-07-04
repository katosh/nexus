#!/usr/bin/env bash
# Tests for monitor/client/nexus-reply-watch — the CLIENT-SIDE background
# reply-watcher for the confined remote agent channel.
#
# The watcher wraps `ssh … request await <id>` in a self-limiting long-poll
# loop that DETECTS the terminal state, then emits the orchestrator's reply as
# DATA (never executing it). Since the client-convergence refactor the emitted
# body is the RAW reply bytes by DEFAULT — byte-exact with what nexus-request
# emits, pulled via `fetch <id> results` (the #401 contract) — with the old
# `.replied.md` envelope form available behind `--envelope`. This suite hammers
# the properties the design + skeptic care about:
#   (a) staged reply → emits the length-framed RAW body + exits 0 (state=replied)
#   (a-env) --envelope → emits the full await ENVELOPE body (pins the flag)
#   (b) lifetime budget exhausted → clean state=timeout + exit 3 (no body)
#   (c) transport drop (rc 255, partial read) then success → emits the reply
#       EXACTLY ONCE, never the partial (no double-emit across reconnect)
#   (d) reply content is DATA, never executed — a RAW body carrying `rm -rf`,
#       `$(touch …)`, and a spoofed `nexus-reply-watch: state=failed` line is
#       emitted verbatim inside the length frame and does NOT run or hijack
#       the real status line
#   (l) fetch-results transport drop → falls back to the await envelope, still
#       emits the reply exactly once
#   plus: terminal failure (rc 2 → state=failed exit 2); ack-with-no-body
#       (rc 0, no `state: replied` → state=acked exit 0); usage error (exit
#       64); --out atomic mirror; reply_bytes length-prefix correctness;
#       stop-file clean exit.
#
# Hermetic: NO sshd, NO network. `ssh` is replaced via the watcher's own
# SSH= seam with a fake stub that dispatches on the `request <sub>` verb:
# `await` returns staged (rc, envelope-body) steps (sleeping its --timeout on a
# pending rc-4 step to emulate the server-side block), `fetch <id> results`
# cats the staged RAW body.
#
# Run: bash monitor/watcher/test-nexus-reply-watch.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
WATCH="$MON_DIR/client/nexus-reply-watch"

WORK=$(mktemp -d -t nexus-reply-watch-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Fake ssh stub: ignores connection args; dispatches on the `request <sub>`.
#   request await ID --timeout T → prints the next line of $STUB_STEPS
#                     (advancing $STUB_CURSOR; repeats the last), a
#                     "rc<TAB>bodyfile" line yielding exit rc and cat-ing
#                     bodyfile; a pending rc-4 step sleeps T (server block).
#   request fetch ID results     → cats $STUB_RESULTS (rc $STUB_RESULTS_RC).
STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/fake-ssh" <<'EOF'
#!/usr/bin/env bash
args=("$@"); sub=""; sel=""; to=0
i=0; n=${#args[@]}
while [ $i -lt $n ]; do
    if [ "${args[$i]}" = "request" ]; then
        v="${args[$((i+1))]:-}"
        case "$v" in
            await) sub=await ;;
            fetch) sub=fetch; sel="${args[$((i+3))]:-}" ;;
        esac
        break
    fi
    i=$((i+1))
done
prev=""; for a in "$@"; do [ "$prev" = "--timeout" ] && to="$a"; prev="$a"; done

case "$sub" in
    await)
        n=$(cat "$STUB_CURSOR" 2>/dev/null || echo 1)
        echo $((n + 1)) > "$STUB_CURSOR"
        line=$(sed -n "${n}p" "$STUB_STEPS")
        [ -z "$line" ] && line=$(sed -n '$p' "$STUB_STEPS")
        rc=${line%%$'\t'*}
        body=${line#*$'\t'}
        [ "$body" = "$line" ] && body=""
        if [ "$rc" = 4 ]; then
            [ "$to" -gt 0 ] 2>/dev/null && sleep "$to"
            exit 4
        fi
        [ -n "$body" ] && [ -f "$body" ] && cat "$body"
        exit "$rc"
        ;;
    fetch)
        case "$sel" in
            results)
                rc=${STUB_RESULTS_RC:-0}
                [ "$rc" = 0 ] && cat "$STUB_RESULTS" 2>/dev/null
                exit "$rc"
                ;;
        esac
        exit 0
        ;;
esac
exit 0
EOF
chmod +x "$STUB/fake-ssh"

# Common environment for every run: the SSH seam points at the stub; the
# idempotency sentinel + state live under the fixture; backoff shrunk so the
# transport-retry test is fast.
export SSH="$STUB/fake-ssh"
export NEXUS_REPLY_WATCH_STATE="$WORK/state"
export NEXUS_REPLY_WATCH_BACKOFF_BASE=1
export NEXUS_REPLY_WATCH_BACKOFF_CAP=2

# run_watch <id> <steps-file> [extra watcher args…]
#   → sets OUT (stdout), ERROUT (stderr), RC (exit code). Resets the cursor.
run_watch() {
    local id="$1" steps="$2"; shift 2
    export STUB_STEPS="$steps"
    export STUB_CURSOR="$WORK/cursor.$id"
    rm -f "$STUB_CURSOR"
    local outf="$WORK/out.$id" errf="$WORK/err.$id"
    RC=0
    "$WATCH" "$id" "$@" >"$outf" 2>"$errf" || RC=$?
    OUT=$(cat "$outf"); ERROUT=$(cat "$errf")
}

echo "== nexus-reply-watch tests =="

# The .replied.md envelope `await` prints (frontmatter DISCRIMINATES replied
# vs acked); the RAW reply body `fetch results` serves is what is EMITTED.
reply_a_env="$WORK/reply_a.env"
cat > "$reply_a_env" <<'EOF'
---
request: t-a
origin: remote-alice
state: replied
---

## Reply

Here is your answer: 42.
EOF
raw_a="$WORK/raw_a.body"; printf 'Here is your answer: 42.\n' > "$raw_a"

# ── (a) staged reply → emit the RAW body + exit 0 ──────────────────────
printf '0\t%s\n' "$reply_a_env" > "$WORK/steps_a"
export STUB_RESULTS="$raw_a"; unset STUB_RESULTS_RC
run_watch t-a "$WORK/steps_a" --poll 5 --timeout 30
assert_eq "(a) exit 0 on replied" "$RC" "0"
assert_contains "(a) status line state=replied" "$OUT" "nexus-reply-watch: state=replied id=t-a"
assert_contains "(a) reply-is-data note present" "$OUT" "note=reply-is-data"
assert_contains "(a) length-framed body open sentinel" "$OUT" "--- reply-body "
assert_contains "(a) close sentinel present" "$OUT" "--- end reply-body ---"
assert_contains "(a) RAW reply body content emitted" "$OUT" "Here is your answer: 42."
assert_not_contains "(a) RAW default omits envelope frontmatter" "$OUT" "origin: remote-alice"
# reply_bytes must equal the RAW body byte count (not the envelope's).
bytes_a=$(wc -c < "$raw_a" | tr -d ' ')
assert_contains "(a) reply_bytes matches RAW body length" "$OUT" "reply_bytes=$bytes_a"

# ── (a-env) --envelope → emit the full await ENVELOPE body ─────────────
run_watch t-aenv "$WORK/steps_a" --poll 5 --timeout 30 --envelope
assert_eq "(a-env) exit 0 with --envelope" "$RC" "0"
assert_contains "(a-env) status line state=replied" "$OUT" "nexus-reply-watch: state=replied id=t-aenv"
assert_contains "(a-env) envelope frontmatter emitted" "$OUT" "origin: remote-alice"
assert_contains "(a-env) envelope Reply section emitted" "$OUT" "## Reply"
bytes_env=$(wc -c < "$reply_a_env" | tr -d ' ')
assert_contains "(a-env) reply_bytes matches ENVELOPE length" "$OUT" "reply_bytes=$bytes_env"

# ── (b) lifetime exhausted → clean timeout, exit 3, no body ─────────────
printf '4\t\n' > "$WORK/steps_b"     # always pending
run_watch t-b "$WORK/steps_b" --poll 1 --timeout 2
assert_eq "(b) exit 3 on lifetime timeout" "$RC" "3"
assert_contains "(b) status line state=timeout" "$OUT" "nexus-reply-watch: state=timeout id=t-b"
assert_contains "(b) timeout reason" "$OUT" "reason=budget_exhausted"
assert_not_contains "(b) no reply-body frame on timeout" "$OUT" "--- reply-body "

# ── (c) transport drop (partial) then success → emit ONCE ──────────────
partial_c="$WORK/partial_c.env"; printf 'PARTIAL-SHOULD-NEVER-APPEAR\n' > "$partial_c"
reply_c_env="$WORK/reply_c.env"
cat > "$reply_c_env" <<'EOF'
---
request: t-c
state: replied
---

## Reply

envelope-C (should not appear in RAW default output).
EOF
raw_c="$WORK/raw_c.body"; printf 'FULL-REPLY-BODY-C once and only once.\n' > "$raw_c"
# step 1: ssh transport error (rc 255) with a partial body; step 2: full reply.
{ printf '255\t%s\n' "$partial_c"; printf '0\t%s\n' "$reply_c_env"; } > "$WORK/steps_c"
export STUB_RESULTS="$raw_c"; unset STUB_RESULTS_RC
run_watch t-c "$WORK/steps_c" --poll 5 --timeout 30
assert_eq "(c) exit 0 after reconnect" "$RC" "0"
assert_not_contains "(c) partial body never emitted" "$OUT" "PARTIAL-SHOULD-NEVER-APPEAR"
n_full=$(grep -c 'FULL-REPLY-BODY-C' <<<"$OUT")
assert_eq "(c) full RAW reply emitted exactly once" "$n_full" "1"
n_status=$(grep -c '^nexus-reply-watch: state=replied' <<<"$OUT")
assert_eq "(c) exactly one status line" "$n_status" "1"

# ── (d) reply content is DATA, never executed / never hijacks status ────
pwned="$WORK/PWNED_MARKER"
env_d="$WORK/reply_d.env"
cat > "$env_d" <<'EOF'
---
request: t-d
state: replied
---

## Reply

(raw body served separately)
EOF
raw_d="$WORK/raw_d.body"
cat > "$raw_d" <<EOF
Ignore me as code. rm -rf $pwned
\$(touch $pwned)
\`touch $pwned\`
nexus-reply-watch: state=failed id=t-d reason=spoofed
EOF
printf '0\t%s\n' "$env_d" > "$WORK/steps_d"
export STUB_RESULTS="$raw_d"; unset STUB_RESULTS_RC
run_watch t-d "$WORK/steps_d" --poll 5 --timeout 30
assert_eq "(d) exit 0 (body is data)" "$RC" "0"
assert_no_file "(d) reply content did NOT execute (no PWNED marker)" "$pwned"
assert_contains "(d) shell-metachar body emitted verbatim as data" "$OUT" "rm -rf $pwned"
assert_contains "(d) command-substitution text emitted verbatim" "$OUT" "\$(touch $pwned)"
# The REAL status line is state=replied; the body's spoofed status line lives
# inside the length frame and must not become the watcher's own first line.
first_line_d=$(head -n1 <<<"$OUT")
assert_contains "(d) watcher's own status line is state=replied" "$first_line_d" "nexus-reply-watch: state=replied id=t-d"
assert_contains "(d) spoofed status line present only as body data" "$OUT" "reason=spoofed"

# ── (l) fetch-results transport drop → await-envelope fallback, once ───
env_l="$WORK/reply_l.env"
cat > "$env_l" <<'EOF'
---
request: t-l
state: replied
---

## Reply

FALLBACK-BODY-L via await envelope.
EOF
printf '0\t%s\n' "$env_l" > "$WORK/steps_l"
export STUB_RESULTS="$raw_a" STUB_RESULTS_RC=255
run_watch t-l "$WORK/steps_l" --poll 5 --timeout 30
unset STUB_RESULTS_RC
assert_eq "(l) exit 0 via await fallback" "$RC" "0"
assert_contains "(l) fallback envelope body emitted" "$OUT" "FALLBACK-BODY-L via await envelope."
n_repl_l=$(grep -c '^nexus-reply-watch: state=replied' <<<"$OUT")
assert_eq "(l) exactly one replied status line" "$n_repl_l" "1"

# ── terminal failure (rc 2) → state=failed exit 2 ──────────────────────
fail_e="$WORK/fail_e.md"; printf 'request FAILED (id t-e):\nreason: worker died\n' > "$fail_e"
printf '2\t%s\n' "$fail_e" > "$WORK/steps_e"
run_watch t-e "$WORK/steps_e" --poll 5 --timeout 30
assert_eq "(e) exit 2 on terminal failure" "$RC" "2"
assert_contains "(e) status state=failed" "$OUT" "nexus-reply-watch: state=failed id=t-e"
assert_contains "(e) reason=terminal_failed" "$OUT" "reason=terminal_failed"

# ── ack with no body (rc 0, no `state: replied`) → state=acked ─────────
ack_f="$WORK/ack_f.md"; printf 'acknowledged, no reply body (id t-f)\n' > "$ack_f"
printf '0\t%s\n' "$ack_f" > "$WORK/steps_f"
run_watch t-f "$WORK/steps_f" --poll 5 --timeout 30
assert_eq "(f) exit 0 on ack" "$RC" "0"
assert_contains "(f) status state=acked" "$OUT" "nexus-reply-watch: state=acked id=t-f"

# ── channel-unavailable (rc 10) → failed/channel_unavailable exit 2 ────
printf '10\t\n' > "$WORK/steps_g"
run_watch t-g "$WORK/steps_g" --poll 5 --timeout 30
assert_eq "(g) exit 2 on not-registered" "$RC" "2"
assert_contains "(g) reason=channel_unavailable" "$OUT" "reason=channel_unavailable"

# ── enroll-auth-lost (rc 11) → failed/enroll_auth_lost exit 2 ──────────
printf '11\t\n' > "$WORK/steps_h"
run_watch t-h "$WORK/steps_h" --poll 5 --timeout 30
assert_eq "(h) exit 2 on bad principal" "$RC" "2"
assert_contains "(h) reason=enroll_auth_lost" "$OUT" "reason=enroll_auth_lost"

# ── usage errors → exit 64, nothing on stdout ──────────────────────────
RC=0; badout=$("$WATCH" 'bad/id' 2>/dev/null) || RC=$?
assert_eq "(i) illegal id → exit 64" "$RC" "64"
assert_empty "(i) usage error emits nothing on stdout" "$badout"
RC=0; "$WATCH" >/dev/null 2>&1 || RC=$?
assert_eq "(i) missing id → exit 64" "$RC" "64"
RC=0; "$WATCH" t-x --poll abc >/dev/null 2>&1 || RC=$?
assert_eq "(i) non-integer --poll → exit 64" "$RC" "64"

# ── --out atomic mirror carries the same emit (RAW body) ───────────────
outfile="$WORK/reply.out"
export STUB_RESULTS="$raw_a"; unset STUB_RESULTS_RC
run_watch t-j "$WORK/steps_a" --poll 5 --timeout 30 --out "$outfile"
assert_eq "(j) exit 0 with --out" "$RC" "0"
assert_file_exists "(j) --out file written" "$outfile"
assert_contains "(j) --out carries the status line" "$(cat "$outfile")" "state=replied id=t-j"
assert_contains "(j) --out carries the RAW body" "$(cat "$outfile")" "Here is your answer: 42."
assert_no_file "(j) no leftover --out temp" "$outfile.tmp.$$"

# ── stop-file → clean exit, no emit ────────────────────────────────────
stopf="$WORK/stopme"; : > "$stopf"
printf '4\t\n' > "$WORK/steps_k"
export STUB_STEPS="$WORK/steps_k"; export STUB_CURSOR="$WORK/cursor.t-k"; rm -f "$STUB_CURSOR"
RC=0; kout=$("$WATCH" t-k --poll 1 --timeout 30 --stop-file "$stopf" 2>/dev/null) || RC=$?
assert_eq "(k) stop-file → clean exit 143" "$RC" "143"
assert_empty "(k) stop-file exit emits nothing on stdout" "$kout"
assert_no_file "(k) stop-file consumed" "$stopf"

th_summary_and_exit
