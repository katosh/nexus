#!/usr/bin/env bash
# `ng send --check` and the QUEUED delivery path (your-org/nexus-code#1099).
#
# Run: bash monitor/watcher/test-send-check-queued-receipt.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE DEFECT. `--check` re-probes `_submit_stamp_epoch`, which reads
# <state>/user-prompt/<window> — written by the receiver's `UserPromptSubmit`
# hook. A paste consumed out of the QUEUE by an already-running turn does not
# fire that hook, so for the most common non-trivial case the only receipt
# `--check` knew how to read was NEVER WRITTEN. rc 3 `unknown` was therefore
# TERMINAL, not transient: measured on two independent sends the same hour,
# each window's stamp still read its SPAWN time hours later while one
# receiver had quoted the pasted text back in its own report.
#
# WHAT THIS SUITE HAS TO PROVE, AND THE TRAP IT AVOIDS. A suite that asserts
# only "rc 0 for a delivered queued send" would pass against an implementation
# that simply reports 0 whenever a digest is recorded. So every rc-0 case here
# is run with the submit-stamp surface PINNED IN THE PAST (Q0 asserts it), and
# is paired with a case differing in ONE variable — whether the receiver's
# transcript holds the bytes. If the content receipt is not what answered, Q1
# and Q2 cannot both pass.
#
# NO TMUX, NO CLAUDE, NO NETWORK. The receiver's transcript is a fixture jsonl
# under a pinned NEXUS_CC_HOME; the harness is a scripted adapter.
#
# jq / base64 / sha256sum are REQUIRED by the surface under test — without them
# `se_submission_with_digest` answers `unknown` by design. A run that cannot
# provide them SKIPS rather than passing, because a green earned by the
# degraded path would certify nothing.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
SEND="$_repo_root/monitor/send.sh"

. "$_test_dir/_test_helpers.sh"
PASS=0; FAIL=0
ck()  { assert_eq "$1" "$2" "$3"; }
ckc() { assert_contains "$1" "$2" "$3"; }
ckn() { assert_not_contains "$1" "$2" "$3"; }

for _t in jq base64 sha256sum; do
    command -v "$_t" >/dev/null 2>&1 || th_abort "required tool '$_t' is absent; the content receipt cannot be exercised"
done

WORK=$(mktemp -d -t nexus-1099-queued-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

ST="$WORK/state"; HD="$WORK/harness"; CC="$WORK/cchome"
W=queued7
SID="11111111-2222-3333-4444-555555555555"
mkdir -p "$ST/windows" "$ST/user-prompt" "$ST/heartbeat" "$ST/paste-verdicts" \
         "$HD" "$CC/projects/some-slug"

printf '{"window":"%s","harness":"fake"}\n' "$W" > "$ST/windows/$W.json"
printf '{"session_id":"%s"}\n' "$SID" > "$ST/heartbeat/$W.json"

cat > "$HD/fake.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
verb="${1:-}"; shift || true
case "$verb" in
transports) printf 'tmux-paste\tshell\tsubmit-stamp\tself\n' ;;
liveness)   n="${2:-}"; eval "rc=\${FAKE_LIVE_${n//-/_}:-0}"; exit "$rc" ;;
send)       exit 0 ;;
esac
exit 2
FAKE
chmod +x "$HD/fake.sh"

run() { NEXUS_STATE_DIR="$ST" NEXUS_HARNESS_DIR="$HD" NEXUS_CC_HOME="$CC" \
        bash "$SEND" "$@" 2>&1; }

# ---- the fixture the defect is about ------------------------------------
#
# `paste-followup.sh` writes this sidecar: the digest BEFORE the paste, the
# rc/outcome after. The `outcome=` string is the one measured in production,
# verbatim — the suite must recognise the real text, not a paraphrase of it.
MSG='Orchestrator input on your item 5: the CI lead is confirmed.'
DIGEST=$(printf '%s' "$MSG" | sha256sum); DIGEST="${DIGEST%% *}"
NONCE="e39b443ac174bc20990ba75b279b50f6"
SEND_EPOCH_S=$(date +%s)
SEND_EPOCH=$(( SEND_EPOCH_S * 1000000 ))

write_sidecar() {   # <outcome-text>
    cat > "$ST/paste-verdicts/$W.$SEND_EPOCH" <<EOF
rc=3
window=$W
epoch=$SEND_EPOCH
digest=$DIGEST
nonce=$NONCE
transport=tmux-paste
outcome=$1
EOF
}
QUEUED_OUTCOME='pasted (submission unconfirmed: a turn is in flight — the transcript grew by 3285 bytes with no submission record, so the text is plausibly QUEUED behind it; re-check)'
write_sidecar "$QUEUED_OUTCOME"

TRANSCRIPT="$CC/projects/some-slug/$SID.jsonl"

# The transcript record the QUEUED path actually produces. Measured on this
# board: a paste landing mid-turn yields `queue-operation`/`enqueue` and NO
# `type:"user"` record whatsoever, which is why the temporal surface is silent.
# Written THREE times, because that is what was measured — the predicate must
# count >= 1, never exactly 1.
enqueue_record() {   # <iso-ts> <content>
    jq -cn --arg ts "$1" --arg c "$2" \
       '{type:"queue-operation",operation:"enqueue",content:$c,timestamp:$ts}'
}
TS_AFTER=$(date -u -d "@$(( SEND_EPOCH_S + 5 ))" +%Y-%m-%dT%H:%M:%S.000Z)

# The submit-stamp surface is PINNED IN THE PAST for every case below: the
# window's stamp reads its SPAWN time and is never rewritten, exactly as
# measured. Any rc 0 in this suite is therefore attributable to the content
# receipt and to nothing else.
printf '%s\t%s\n' "$(( SEND_EPOCH_S - 3600 ))" "$SID" > "$ST/user-prompt/$W"

echo '=== Q0: the premise — the submit-stamp NEVER advances on the queued path ==='
stamp=$(cut -f1 < "$ST/user-prompt/$W")
if (( stamp < SEND_EPOCH_S )); then
    assert_eq "Q0 stamp predates the send, so it cannot license any rc 0 below" "ok" "ok"
else
    assert_eq "Q0 stamp predates the send" "$stamp" "<$SEND_EPOCH_S"
fi

echo '=== Q1: bytes present in an enqueue record -> DELIVERED (rc 0) ==='
: > "$TRANSCRIPT"
for _i in 1 2 3; do enqueue_record "$TS_AFTER" "$MSG" >> "$TRANSCRIPT"; done
out=$(run "$W" --check --nonce "$NONCE"; echo "rc=$?")
ck  "Q1 exit code is 0"                       "$(sed -n 's/^rc=//p' <<<"$out")" "0"
ckc "Q1 names the CONTENT receipt"            "$out" "content receipt"
ckc "Q1 says the receipt is MESSAGE-scoped"   "$out" "MESSAGE-scoped"
ckc "Q1 names the window whose transcript answered" "$out" "$W"

echo '=== Q2: THE PAIRED NEGATIVE — same everything, bytes absent -> rc 3 ==='
# One variable differs from Q1: the transcript holds a DIFFERENT message. If
# the implementation were reporting 0 merely because a digest exists, Q1 and
# Q2 would agree; they must not.
: > "$TRANSCRIPT"
enqueue_record "$TS_AFTER" "an entirely unrelated instruction" >> "$TRANSCRIPT"
out=$(run "$W" --check --nonce "$NONCE"; echo "rc=$?")
ck  "Q2 exit code is 3 (unknown), NOT 0"      "$(sed -n 's/^rc=//p' <<<"$out")" "3"
ckn "Q2 does not claim delivery"              "$out" "delivered"
ckc "Q2 reports the content receipt answered NO" "$out" "content receipt was consulted and answered NO"
ckc "Q2 states it is NOT an established negative" "$out" "NOT an established non-delivery"

echo '=== Q3: rc 3 NAMES the queued case and says no stamp will ever arrive ==='
ckc "Q3 quotes the recorded queued outcome"   "$out" "QUEUED"
ckc "Q3 states the terminal fact"             "$out" "NO submit-stamp will ever arrive"
ckc "Q3 cites the issue"                      "$out" "your-org/nexus-code#1099"
ckc "Q3 says polling that surface cannot terminate" "$out" "cannot terminate"

echo '=== Q4: a digest NO must NEVER escalate to rc 4 (the exclusivity rule) ==='
# The send-side polarity is untouched: rc 4 is reserved for a carrier PROVEN
# unreachable. A bounded-scan `no` is not that, and #1049 is the failure that
# rule exists to prevent. Asserted with the carrier ALIVE — the only reading
# under which a wrongly-escalating implementation would be caught here.
rc4=$(FAKE_LIVE_tmux_paste=0 run "$W" --check --nonce "$NONCE" >/dev/null 2>&1; echo $?)
ck  "Q4 carrier alive + content receipt NO ⇒ 3, never 4" "$rc4" "3"
# The positive control for the same code path: a carrier PROVEN dead must
# still reach rc 4, or "always return 3" would pass Q4 and destroy the
# fallback entirely.
rc4b=$(FAKE_LIVE_tmux_paste=1 run "$W" --check --nonce "$NONCE" >/dev/null 2>&1; echo $?)
ck  "Q4b CONTROL carrier proven dead ⇒ 4 is still reachable" "$rc4b" "4"

echo '=== Q5: a send with NO digest (any non-paste transport) still explains itself ==='
grep -v '^digest=' "$ST/paste-verdicts/$W.$SEND_EPOCH" > "$WORK/nd" \
    && mv "$WORK/nd" "$ST/paste-verdicts/$W.$SEND_EPOCH"
out5=$(run "$W" --check --nonce "$NONCE"; echo "rc=$?")
ck  "Q5 exit code is 3"                       "$(sed -n 's/^rc=//p' <<<"$out5")" "3"
ckc "Q5 says why no content receipt exists"   "$out5" "recorded no content marker"
ckc "Q5 still names the queued case"          "$out5" "NO submit-stamp will ever arrive"
write_sidecar "$QUEUED_OUTCOME"

echo '=== Q6: a NON-queued outcome must NOT get the queued note ==='
# The note asserts something specific and terminal; attaching it to an
# unqueued send would be a confident wrong answer about a surface that will
# in fact answer.
write_sidecar 'pasted (NOT submitted)'
: > "$TRANSCRIPT"
out6=$(run "$W" --check --nonce "$NONCE"; echo "rc=$?")
ck  "Q6 exit code is 3"                       "$(sed -n 's/^rc=//p' <<<"$out6")" "3"
ckn "Q6 carries no queued note"               "$out6" "NO submit-stamp will ever arrive"
write_sidecar "$QUEUED_OUTCOME"

echo '=== Q7: the submit-stamp path still works, and now flags a DISAGREEMENT ==='
# The stamp is WINDOW-scoped. When it advances but the content receipt says the
# bytes are absent, the exit code stays 0 — rc 0's licence ("stop; do not fall
# back") is correct under either reading — but the disagreement is surfaced.
: > "$TRANSCRIPT"
enqueue_record "$TS_AFTER" "somebody else's message" >> "$TRANSCRIPT"
printf '%s\t%s\n' "$(( SEND_EPOCH_S + 30 ))" "$SID" > "$ST/user-prompt/$W"
out7=$(run "$W" --check --nonce "$NONCE"; echo "rc=$?")
ck  "Q7 exit code is 0 (the stamp advanced)"  "$(sed -n 's/^rc=//p' <<<"$out7")" "0"
ckc "Q7 warns that the stamp is window-scoped" "$out7" "WINDOW-scoped"
ckc "Q7 names the disagreement"               "$out7" "may have been a different message"
# Restore the pinned-past stamp for the mutants below.
printf '%s\t%s\n' "$(( SEND_EPOCH_S - 3600 ))" "$SID" > "$ST/user-prompt/$W"

echo '=== Q8: #1287 — the VERDICT and its QUALIFIER must share a STREAM ==='
# THE DEFECT THIS SUITE COULD NOT SEE. Q7 above asserts the disagreement is
# surfaced, and it PASSED throughout #1287's lifetime — because `run()` merges
# `2>&1`, and the merged stream cannot distinguish "the caution is on stdout
# beside the verdict" from "the caution is on stderr while stdout says only
# `delivered`". A guard that collapses the two streams is blind to a defect
# whose entire content is WHICH STREAM carried what.
#
# `out=$(ng send … --check)` is the natural capture and takes STDOUT ALONE, so
# the reported caller saw exactly one line: `delivered`. The message had never
# arrived. Measured into a still-booting window, where the window-scoped stamp
# advances on the spawned agent's OWN prompt submission — guaranteed in that
# interval, which makes the false positive MOST reliable exactly when it is
# least visible.
#
# rc is deliberately NOT changed: SKILL §5 pins verdict `delivered` <-> rc 0
# and §5.1 declares this case rc 0 on purpose. These assertions therefore pin
# the STREAM, not the code.
run_out() { NEXUS_STATE_DIR="$ST" NEXUS_HARNESS_DIR="$HD" NEXUS_CC_HOME="$CC" \
            bash "$SEND" "$@" 2>/dev/null; }
run_err() { NEXUS_STATE_DIR="$ST" NEXUS_HARNESS_DIR="$HD" NEXUS_CC_HOME="$CC" \
            bash "$SEND" "$@" 2>&1 >/dev/null; }

# Scenario: stamp ADVANCED, content receipt says the bytes are ABSENT.
: > "$TRANSCRIPT"
enqueue_record "$TS_AFTER" "somebody else's message" >> "$TRANSCRIPT"
printf '%s\t%s\n' "$(( SEND_EPOCH_S + 30 ))" "$SID" > "$ST/user-prompt/$W"
q8_out=$(run_out "$W" --check --nonce "$NONCE"); q8_rc=$?
q8_err=$(run_err "$W" --check --nonce "$NONCE")

# POSITIVE CONTROL for the instrument itself: a stdout-only capture that came
# back EMPTY would satisfy every `does not contain` assertion vacuously, and
# would look exactly like a defect-free run.
ck  "Q8 CONTROL: the stdout-only capture is non-empty" \
    "$([[ -n "$q8_out" ]] && echo non-empty || echo EMPTY)" "non-empty"
ck  "Q8 rc is still 0 — the SKILL §5 verdict/rc pairing is UNCHANGED" "$q8_rc" "0"
ckc "Q8 stdout still carries the §5 verdict token" "$q8_out" "delivered"
ckc "Q8 STDOUT ALONE carries the machine-readable content verdict" "$q8_out" "content=no"
ckc "Q8 STDOUT ALONE names the surface that answered"              "$q8_out" "receipt=submit-stamp"
ckc "Q8 STDOUT ALONE names what that surface can speak for"        "$q8_out" "scope=window"
ckc "Q8 STDOUT ALONE explains the disagreement in prose"           "$q8_out" \
    "may have been a different message"
ckc "Q8 STDOUT ALONE says rc 0 still forbids a fallback"           "$q8_out" "forbids a fallback"
# The stderr narrative is RETAINED, not relocated: SKILL §5.1 states this case
# "says so on stderr", and a human reading a terminal should not have to parse
# a field list. Asserting it separately is what proves the fix ADDED a channel
# rather than moving one.
ckc "Q8 STDERR ALONE still carries the say() CAUTION (added, not moved)" "$q8_err" "CAUTION"

echo '=== Q9: #1287 — the two rc-0 verdicts are DISTINGUISHABLE from stdout alone ==='
# Before #1287 both arms printed the bare token `delivered` and differed only
# in prose, so a caller could not tell a MESSAGE-scoped confirmation from a
# WINDOW-scoped one without matching sentences. That is the same defect one
# door along, and it is why the field is added to BOTH arms rather than only
# to the failing one.
: > "$TRANSCRIPT"
for _i in 1 2 3; do enqueue_record "$TS_AFTER" "$MSG" >> "$TRANSCRIPT"; done
q9_out=$(run_out "$W" --check --nonce "$NONCE"); q9_rc=$?
ck  "Q9 rc is 0 (content receipt answered yes)"      "$q9_rc" "0"
ckc "Q9 stdout names the MESSAGE-scoped surface"     "$q9_out" "receipt=content-digest"
ckc "Q9 stdout says scope=message"                   "$q9_out" "scope=message"
ckc "Q9 stdout says content=yes"                     "$q9_out" "content=yes"
# NEGATIVE CONTROL. Without this, every Q8 assertion above would also pass on
# an implementation that printed the disagreement clause unconditionally.
ckn "Q9 NEGATIVE CONTROL: a corroborated delivery carries NO disagreement clause" \
    "$q9_out" "may have been a different message"
# The discriminator is a real difference, not two spellings of one string.
ck  "Q9 the two rc-0 stdout lines differ in receipt=" \
    "$([[ "$q9_out" != "$q8_out" ]] && echo differ || echo IDENTICAL)" "differ"

echo '=== Q10: #1287 — a stamp-advanced send with NO content marker says so ==='
# `content=` must be a total function over the verdict space: `yes|no|unknown`
# from the helper, `none` when the send recorded no digest at all (every
# transport but tmux-paste), `unavailable` when the helper could not be loaded.
# A field that is silently absent for a whole class of sends is not
# machine-readable.
grep -v '^digest=' "$ST/paste-verdicts/$W.$SEND_EPOCH" > "$WORK/nd10" \
    && mv "$WORK/nd10" "$ST/paste-verdicts/$W.$SEND_EPOCH"
q10_out=$(run_out "$W" --check --nonce "$NONCE"); q10_rc=$?
ck  "Q10 rc is 0 (the stamp advanced)"          "$q10_rc" "0"
ckc "Q10 stdout says content=none, not nothing" "$q10_out" "content=none"
write_sidecar "$QUEUED_OUTCOME"

# Restore the pinned-past stamp for the mutants below.
printf '%s\t%s\n' "$(( SEND_EPOCH_S - 3600 ))" "$SID" > "$ST/user-prompt/$W"

echo '=== M0-M2: MUTANT POTENCY — applied, and in a fixture that can tell ==='
# TWO independent ways a mutant verdict can be meaningless, and both are
# checked here because the first draft of this suite fell into the second:
#
#   1. THE EDIT DID NOT LAND. An inert mutant and a real surviving mutant give
#      byte-identical output, so `mutate` refuses to report a verdict for a sed
#      that changed nothing.
#   2. THE FIXTURE COULD NOT TELL. A mutant copied to a bare directory cannot
#      source `monitor/_submit_evidence.sh` — so it reports rc 3 for EVERY
#      input, and "M1 killed" is then true of an implementation that was never
#      exercised. M0 is the positive control that catches it: an UNMUTATED copy
#      in the same directory must still reproduce Q1's rc 0. Without M0 this
#      suite scored 27/27 while measuring nothing.
MUT="$WORK/mutants"; mkdir -p "$MUT"
cp "$_repo_root/monitor/_submit_evidence.sh" "$MUT/"
mutate() {   # <name> <sed-expr> -> 0 when the file actually changed
    local name="$1"
    local expr="$2"
    local dst="$MUT/send-$name.sh"
    cp "$SEND" "$dst"
    [[ -n "$expr" ]] && sed -i "$expr" "$dst"
    if [[ -n "$expr" ]] && cmp -s "$SEND" "$dst"; then
        assert_eq "mutant $name APPLIED (inert mutants make every verdict meaningless)" "inert" "applied"
        return 1
    fi
    [[ -n "$expr" ]] && assert_eq "mutant $name APPLIED" "applied" "applied"
    return 0
}
run_mut() { NEXUS_STATE_DIR="$ST" NEXUS_HARNESS_DIR="$HD" NEXUS_CC_HOME="$CC" \
            bash "$MUT/send-$1.sh" "${@:2}" 2>&1; }

: > "$TRANSCRIPT"
for _i in 1 2 3; do enqueue_record "$TS_AFTER" "$MSG" >> "$TRANSCRIPT"; done

# M0 — the fixture-validity control. An UNMUTATED copy, run the way the
# mutants are run, must reproduce Q1.
mutate control ""
ck "M0 CONTROL: an unmutated copy in the mutant dir still reports delivered (0)" \
   "$(run_mut control "$W" --check --nonce "$NONCE" >/dev/null 2>&1; echo $?)" "0"

# M1 — never consult the content receipt. Q1 must revert to rc 3.
if mutate nocontent 's/^    _digest=$(_sc_field digest)/    _digest=""/'; then
    ck "M1 killed: content receipt removed ⇒ Q1 reverts to unknown (3)" \
       "$(run_mut nocontent "$W" --check --nonce "$NONCE" >/dev/null 2>&1; echo $?)" "3"
fi

# M2 — accept any verdict, not just `yes`. Q2's negative must break.
if mutate anyverdict 's/if \[\[ "$_content_verdict" == "yes" \]\]; then/if [[ -n "$_content_verdict" ]]; then/'; then
    : > "$TRANSCRIPT"
    enqueue_record "$TS_AFTER" "an entirely unrelated instruction" >> "$TRANSCRIPT"
    ck "M2 killed: 'any verdict' ⇒ Q2's absent bytes wrongly report delivered (0)" \
       "$(run_mut anyverdict "$W" --check --nonce "$NONCE" >/dev/null 2>&1; echo $?)" "0"
fi

# ---- the assertion COUNT, compared EXACTLY (#821 axis B) -----------------
# A suite can lose assertions silently: an arm that stops running still reports
# a clean green, and a FLOOR cannot catch that. Update this number DELIBERATELY
# when adding an arm; a mismatch is a red, not a warning.
EXPECTED_ASSERTIONS=45
_run_total=$(( PASS + FAIL ))
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
