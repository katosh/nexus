#!/usr/bin/env bash
# Tests for the CLIENT-CONVERGENCE refactor (#405 P4) of the two confined
# remote-channel client tools, nexus-request and nexus-reply-watch. After
# convergence they share ONE watch-loop core (monitor/client/_nexus_watch_lib.sh)
# and one ssh-rc classification table, and both emit the SAME terminal payload
# — the RAW reply body (the #401 byte-exact contract).
#
# This suite pins the two convergence PROPERTIES directly (each tool's own
# behavioral contract is covered by test-nexus-request.sh / test-nexus-reply-
# watch.sh):
#
#   (A) SAME BODY BYTES — for the same replied request, both tools emit a
#       byte-identical reply body (same reply_bytes + reply_sha256), because
#       both now pull it via `fetch <id> results`.
#
#   (B) ONE RC TABLE — the shared classifier maps each ssh/forced-command exit
#       code to the SAME terminal reason for both tools. We pin the two
#       previously-divergent codes:
#         * rc 1 (usage/bad-arg): PRE-convergence, nexus-reply-watch treated it
#           as terminal `refused` while nexus-request's `fetch status` handler
#           left it unlisted → it fell through to the transient arm and
#           retried until the wall-clock budget (state=timeout). Server rc 1 is
#           STATIC (retrying the identical bad command loops forever), so the
#           unified behavior is terminal `refused` for BOTH. This test asserts
#           nexus-request now terminates on rc 1 (exit 2 / refused), matching
#           nexus-reply-watch.
#         * rc 2 (verb-overloaded): the server returns rc 2 for BOTH `await`
#           terminal-failed AND `fetch` id-not-found. The shared table
#           deliberately does NOT own rc 2 (each tool matches its verb's rc 2
#           first) — pinned here as fatal_reason_for 2 == empty so a future
#           refactor cannot "unify" the two meanings into one wrong arm.
#       Plus a unit assertion of the whole verb-independent map.
#
# Hermetic: NO sshd, NO network. A single fake `ssh` stub (superset of both
# tools' seams) dispatches on the `request <sub>` verb.
#
# Run: bash monitor/watcher/test-nexus-client-convergence.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
REQTOOL="$MON_DIR/client/nexus-request"
WATCH="$MON_DIR/client/nexus-reply-watch"
LIB="$MON_DIR/client/_nexus_watch_lib.sh"

WORK=$(mktemp -d -t nexus-conv-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Fake ssh stub (superset of both tools' seams):
#   request file             → prints $STUB_ID (rc $STUB_FILE_RC, default 0)
#   request fetch ID status  → next line of $STUB_STATE_STEPS ("rc<TAB>word";
#                              a bare word means rc 0), advancing $STUB_STATE_CURSOR
#   request fetch ID results → cats $STUB_RESULTS (rc $STUB_RESULTS_RC)
#   request await ID …       → exits $STUB_AWAIT_RC (default 4 = pending),
#                              cat-ing $STUB_AWAIT_BODY on rc 0/2; sleeps its
#                              --timeout unless $STUB_NOSLEEP=1
STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/fake-ssh" <<'EOF'
#!/usr/bin/env bash
args=("$@"); sub=""; sel=""; to=0
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
export NEXUS_REQUEST_STATE="$WORK/state-req"
export NEXUS_REPLY_WATCH_STATE="$WORK/state-watch"
export NEXUS_WATCH_BACKOFF_BASE=1
export NEXUS_WATCH_BACKOFF_CAP=2
export NEXUS_REPLY_WATCH_BACKOFF_BASE=1
export NEXUS_REPLY_WATCH_BACKOFF_CAP=2

echo "== nexus-client convergence tests =="

# ── (A) SAME BODY BYTES for the same replied request ───────────────────
# One raw reply body, served by `fetch results` to BOTH tools. The .replied.md
# envelope only DISCRIMINATES replied vs acked for reply-watch; the emitted
# body is the raw bytes for both.
raw="$WORK/raw.body"
printf 'The convergence answer.\nLine two, no trailing newline.' > "$raw"
env_repl="$WORK/env.replied"
cat > "$env_repl" <<'EOF'
---
request: t-conv
state: replied
---

## Reply

(raw body served via fetch results)
EOF
export STUB_RESULTS="$raw"

# nexus-request: file → status new→replied → fetch results.
printf 'new\nreplied\n' > "$WORK/steps_req"
export STUB_ID="t-conv-req" STUB_STATE_STEPS="$WORK/steps_req" STUB_STATE_CURSOR="$WORK/cur_req"
rm -f "$STUB_STATE_CURSOR"
unset STUB_FILE_RC STUB_AWAIT_RC STUB_AWAIT_BODY STUB_RESULTS_RC STUB_NOSLEEP
RC=0
"$REQTOOL" --slug conv --reply required --message "converge" --poll 1 --timeout 30 \
    >"$WORK/out_req" 2>/dev/null || RC=$?
assert_eq "(A) nexus-request exit 0" "$RC" "0"
req_line=$(grep '^nexus-request: state=replied' "$WORK/out_req")
req_bytes=$(sed -n 's/.* reply_bytes=\([0-9]*\).*/\1/p' <<<"$req_line")
req_sha=$(sed -n 's/.* reply_sha256=\([^ ]*\).*/\1/p' <<<"$req_line")

# nexus-reply-watch: await rc 0 (envelope, state:replied) → fetch results.
export STUB_AWAIT_RC=0 STUB_AWAIT_BODY="$env_repl" STUB_NOSLEEP=1
export STUB_STATE_STEPS="$WORK/steps_req"   # unused by reply-watch; keep set
RC=0
"$WATCH" t-conv-watch --poll 1 --timeout 30 \
    >"$WORK/out_watch" 2>/dev/null || RC=$?
unset STUB_AWAIT_RC STUB_AWAIT_BODY STUB_NOSLEEP
assert_eq "(A) nexus-reply-watch exit 0" "$RC" "0"
watch_line=$(grep '^nexus-reply-watch: state=replied' "$WORK/out_watch")
watch_bytes=$(sed -n 's/.* reply_bytes=\([0-9]*\).*/\1/p' <<<"$watch_line")
watch_sha=$(sed -n 's/.* reply_sha256=\([^ ]*\).*/\1/p' <<<"$watch_line")

want_bytes=$(wc -c < "$raw" | tr -d ' ')
assert_eq "(A) reply_bytes equal across tools"      "$req_bytes" "$watch_bytes"
assert_eq "(A) reply_bytes matches the raw body"    "$req_bytes" "$want_bytes"
assert_eq "(A) reply_sha256 equal across tools"     "$req_sha"   "$watch_sha"
# The sha must be a REAL digest (this host has sha256sum), else equality is a
# vacuous 'none==none'.
assert_not_contains "(A) sha256 is a real digest, not 'none'" "$req_sha" "none"

# ── (B) ONE RC TABLE: unit map + the two divergent codes ───────────────
# Verb-independent fatal map (fatal_reason_for is a pure function; source the
# lib in a subshell so its emit-side globals stay untouched).
map_check() {  # <rc> <expected-reason-or-empty>
    local got
    got=$( . "$LIB"; fatal_reason_for "$1" )
    assert_eq "(B) fatal_reason_for $1 → '${2:-<empty>}'" "$got" "$2"
}
map_check 5  confinement_reject
map_check 10 channel_unavailable
map_check 11 enroll_auth_lost
map_check 1  refused        # unified: was transient in nexus-request's status handler
map_check 12 refused
map_check 13 refused
map_check 2  ''             # verb-overloaded → NOT in the shared table
map_check 0  ''             # verb-specific (ok/terminal)
map_check 4  ''             # verb-specific (await pending)
map_check 255 ''            # transient (reconnect)

# End-to-end rc 1: nexus-request's `fetch status` returns rc 1. PRE-fix this
# retried until timeout (exit 3); unified it terminates as refused (exit 2),
# matching nexus-reply-watch's await-rc-1 behavior.
printf '1\tnew\n' > "$WORK/steps_rc1"
export STUB_ID="t-rc1" STUB_STATE_STEPS="$WORK/steps_rc1" STUB_STATE_CURSOR="$WORK/cur_rc1"
rm -f "$STUB_STATE_CURSOR"
RC=0
"$REQTOOL" --slug rc1 --reply required --message "bad arg" --poll 1 --timeout 3 \
    >"$WORK/out_rc1" 2>/dev/null || RC=$?
assert_eq       "(B) nexus-request rc 1 → exit 2 (terminal, not timeout)" "$RC" "2"
assert_contains "(B) nexus-request rc 1 → reason=refused" "$(cat "$WORK/out_rc1")" "reason=refused"
assert_not_contains "(B) nexus-request rc 1 did NOT time out" "$(cat "$WORK/out_rc1")" "state=timeout"

# nexus-reply-watch's await returns rc 1 → same terminal reason.
export STUB_AWAIT_RC=1 STUB_NOSLEEP=1
RC=0
"$WATCH" t-rc1w --poll 1 --timeout 3 >"$WORK/out_rc1w" 2>/dev/null || RC=$?
unset STUB_AWAIT_RC STUB_NOSLEEP
watch_rc1=$RC
assert_eq       "(B) nexus-reply-watch rc 1 → exit 2" "$watch_rc1" "2"
assert_contains "(B) nexus-reply-watch rc 1 → reason=refused" "$(cat "$WORK/out_rc1w")" "reason=refused"
# The convergence property itself: identical classification (exit + reason).
assert_eq "(B) both tools classify rc 1 identically (exit code)" "$RC" "2"

th_summary_and_exit
