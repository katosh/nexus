#!/usr/bin/env bash
# The paste-followup INTERFACE must not lie about what it did —
# your-org/nexus-code#848 (the receipt) and #883 (the synopsis).
#
# Both defects are the same shape: the MECHANISM was correct and the
# SURFACE a caller reads was not.
#
#   #848  `--note` is an action-log annotation, never payload. The
#         receipt carried a char count — the most authoritative-looking
#         thing a paste tool can print — and said nothing about the note,
#         so four calls carrying four DIFFERENT per-worker addenda
#         printed four BYTE-IDENTICAL success lines. The instructions
#         never reached a worker and the receipt was consistent with
#         their having arrived. Caught only by noticing the four counts
#         matched.
#   #883  `--administrative` (the entire remedy for #683) and `--src`
#         were parsed and documented in the header block, and absent
#         from the usage line — the one surface a caller reads. So
#         following the tool's own documentation reproduced a closed bug.
#
# WHY THESE TESTS ARE BEHAVIOURAL, and not the obvious textual ones.
# The obvious test for #883 is `grep -- --administrative` against the
# usage string. That asserts a PROXY: it goes green for the one flag
# somebody remembered, and stays green while the NEXT flag is added
# without one — i.e. it closes this instance and leaves the class open,
# which is precisely the defect. So:
#
#   - The flag population is derived INDEPENDENTLY of the script's own
#     derivation (a plain scan of every `case` arm in the file), and
#     each member is then confirmed to be REALLY accepted by running the
#     parser against it. Only then is the usage line required to name it.
#     If the script's synopsis derivation breaks, this suite still finds
#     the flags and goes red.
#   - The #848 assertions compare the receipt's count against the bytes
#     the tmux stub actually RECEIVED, and assert that two calls
#     differing only in `--note` produce DIFFERENT receipts — which is
#     the reported symptom, stated as a property.
#
# Run: bash monitor/watcher/test-paste-followup-receipt-and-usage.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$_test_dir/../paste-followup.sh"

# The shared ledger (`_test_helpers.sh` + `th_summary_and_exit`) rather
# than local counters: `assert_*` mutates globals, so a FAIL raised
# inside `( … )` or `$( … )` dies with the child and the suite reports
# green. The ledger is a file and survives the subshell.
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

WORK=$(mktemp -d -t nexus-848-883-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"
ACTIONS="$WORK/actions.log"
PAYLOAD="$WORK/payload.txt"     # exactly the bytes handed to set-buffer
CC_HOME="$WORK/cc"
SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
TRANSCRIPT="$CC_HOME/projects/-stub-slug/$SID.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")"

# tmux stub. Same recorder shape as test-paste-followup.sh, with ONE
# addition that is the whole point of Part A: `set-buffer` writes its
# payload argument verbatim to $PAYLOAD, so the suite can measure what
# was DELIVERED rather than trusting the receipt's own arithmetic.
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
cmd="${1:-}"
if [[ "$cmd" == "list-windows" ]]; then
    fmt=""; prev=""
    for a in "$@"; do [[ "$prev" == "-F" ]] && fmt="$a"; prev="$a"; done
    case "$fmt" in
        *window_id*)
            d="${fmt#*'#{window_id}'}"; d="${d%%'#{window_name}'*}"
            for w in ${MOCK_TMUX_WINDOWS:-}; do printf '@3%s%s\n' "$d" "$w"; done ;;
        *) printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    esac
    exit 0
fi
printf '%s\n' "$*" >> "$ACTIONS"
# The delivered payload: `set-buffer -b <buf> -- <MSG>`, last arg.
if [[ "$cmd" == "set-buffer" && -n "${MOCK_PAYLOAD_FILE:-}" ]]; then
    printf '%s' "${!#}" > "$MOCK_PAYLOAD_FILE"
fi
if [[ "$cmd" == "send-keys" && "${!#}" == "Enter" && -n "${MOCK_TRANSCRIPT:-}" ]]; then
    printf '{"type":"user","promptSource":"typed","message":{"role":"user","content":"the follow-up"}}\n' \
        >> "$MOCK_TRANSCRIPT"
fi
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

export ACTIONS MOCK_PAYLOAD_FILE="$PAYLOAD" MOCK_TRANSCRIPT="$TRANSCRIPT"
export PATH="$STUB_DIR:$PATH"
export MOCK_TMUX_WINDOWS='suitehonesty'

seed_session() {
    mkdir -p "$RUN_STATE/heartbeat"
    printf '{"state":"idle_prompt","last_activity":%s,"session_id":"%s","window":"%s"}\n' \
        "$(date +%s)" "$SID" "suitehonesty" > "$RUN_STATE/heartbeat/suitehonesty.json"
    printf '{"type":"user","promptSource":"typed","message":{"role":"user","content":"the ORIGINAL spawn prompt"}}\n' \
        > "$TRANSCRIPT"
}

# Run the helper with a fresh state dir. NG_SHOULD_FAIL=1 makes the
# action-log append fail, which Part A7 needs.
run_helper() {
    RUN_STATE=$(mktemp -d "$WORK/state.XXXXXX")
    seed_session
    : > "$ACTIONS"; : > "$PAYLOAD"
    HELPER_OUT=$(env "NEXUS_STATE_DIR=$RUN_STATE" "NEXUS_CC_HOME=$CC_HOME" \
                     "PASTE_CONFIRM_TIMEOUT_SECONDS=2" "PASTE_CONFIRM_POLL_SECONDS=0.05" \
                     ${NG_BIN_OVERRIDE:+PASTE_NG_BIN="$NG_BIN_OVERRIDE"} \
                     bash "$SCRIPT" "$@" 2>&1)
    HELPER_RC=$?
}

# ===========================================================================
# PART A — your-org/nexus-code#848: the receipt describes what it covers.
# ===========================================================================
echo '=== PART A: the receipt states what it covers (#848) ==='

BRIEF="$WORK/common-brief.md"
printf 'Shared standby brief.\nSecond line of the shared brief.\n' > "$BRIEF"
NOTE_A='Your branch: PR 842 — rebase before you resume.'
NOTE_B='Your branch: PR 826 — different worker, different instruction.'

run_helper suitehonesty --file "$BRIEF" --note "$NOTE_A"
assert_eq "A0 the happy path still exits 0" "$HELPER_RC" "0"

DELIVERED=$(cat "$PAYLOAD")
# A1. The count in the receipt is the count of what tmux actually got.
#     This is the assertion the reported failure needed: a receipt whose
#     number is not a measurement of the delivery is not a receipt.
assert_contains "A1 the receipt's char count equals the DELIVERED payload length" \
    "$HELPER_OUT" "(${#DELIVERED} chars pasted)"

# A2. The note is not payload — established against the delivered bytes,
#     not against the tool's claim about them.
assert_not_contains "A2 the --note text never reaches the window" \
    "$DELIVERED" "$NOTE_A"

# A3. …and the receipt says so, with the destination and the size.
assert_contains "A3 the receipt names --note"            "$HELPER_OUT" '--note'
assert_contains "A3 the receipt names its destination"   "$HELPER_OUT" 'action log'
assert_contains "A3 the receipt says it was NOT pasted"  "$HELPER_OUT" 'NOT pasted'
assert_contains "A3 the receipt sizes the note"          "$HELPER_OUT" "(${#NOTE_A} chars"

RECEIPT_A="$HELPER_OUT"

# A4. THE REPORTED SYMPTOM, as a property. Four dispatches differing only
#     in --note printed four identical lines. Two suffice to state it.
run_helper suitehonesty --file "$BRIEF" --note "$NOTE_B"
RECEIPT_B="$HELPER_OUT"
if [[ "$RECEIPT_A" != "$RECEIPT_B" ]]; then
    pass "A4 two calls differing ONLY in --note print DIFFERENT receipts"
else
    fail "A4 two calls differing only in --note printed IDENTICAL receipts — #848 reproduced"
    printf '         both were: %s\n' "$RECEIPT_A" >&2
fi
# Non-vacuity for A4: they must differ BECAUSE of the note, not because
# some unrelated volatile token (an epoch, a pid) leaked into the line.
assert_contains "A4 receipt B sizes ITS note, not A's" "$RECEIPT_B" "(${#NOTE_B} chars"

# A5. No --note ⇒ no note clause. A receipt that always mentions notes
#     teaches the reader to skip the clause, which re-opens the bug.
run_helper suitehonesty --file "$BRIEF"
assert_eq "A5 exit 0 without --note" "$HELPER_RC" "0"
assert_not_contains "A5 no --note ⇒ no note clause" "$HELPER_OUT" 'NOT pasted'
assert_contains "A5 the pasted count is still reported" "$HELPER_OUT" 'chars pasted'

# A6. Multi-byte payload: the receipt's measure must still be a measure
#     of the delivery, not of some other string.
UTF8="$WORK/utf8.md"
printf 'Rebase auf dev — dann prüfen: αβγ ✅\n' > "$UTF8"
run_helper suitehonesty --file "$UTF8" --note "$NOTE_A"
DELIVERED_U=$(cat "$PAYLOAD")
assert_contains "A6 multi-byte payload: count still equals the delivered length" \
    "$HELPER_OUT" "(${#DELIVERED_U} chars pasted)"

# A7. The note's receipt must track what actually happened to the note.
#     `ng log-action` is best-effort, so "recorded to the action log" is a
#     claim that can be false — and it would be exactly the same lie one
#     level down.
FAILING_NG="$WORK/ng-fail"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAILING_NG"; chmod +x "$FAILING_NG"
NG_BIN_OVERRIDE="$FAILING_NG" run_helper suitehonesty --file "$BRIEF" --note "$NOTE_A"
assert_contains "A7 a failed action-log append is reported as NOT recorded" \
    "$HELPER_OUT" '--note NOT recorded'
assert_not_contains "A7 …and does NOT claim the note was recorded" \
    "$HELPER_OUT" '--note recorded to the action log'

# A8. The other direction: the note must still REACH the action log when
#     the append succeeds. A suite that only checked the disclaimer would
#     pass against a patch that dropped --note entirely.
run_helper suitehonesty --file "$BRIEF" --note "$NOTE_A"
assert_contains "A8 the note is still written to the action log" \
    "$(cat "$RUN_STATE/action-log.jsonl" 2>/dev/null)" "$NOTE_A"

# ===========================================================================
# PART B — your-org/nexus-code#883: every accepted flag is discoverable.
# ===========================================================================
echo '=== PART B: the usage line names every flag the parser accepts (#883) ==='

# The flag population, derived INDEPENDENTLY of the script's own
# derivation: a plain scan of every `case` arm in the file, aliases split.
# If the script's synopsis extractor breaks, this list is unaffected and
# the assertions below go red — which is the point.
# Built in ONE pipeline into a string, then read from a here-string
# rather than nested `< <(...)` process substitutions: the nested form
# was observed to drop an entry once in ~10 runs, and a flaky enumeration
# behind a completeness claim is the same defect this suite is about.
FLAGS_RAW=$(grep -oE '^[[:space:]]+(-[a-zA-Z0-9|_-]*[a-zA-Z0-9])\)' "$SCRIPT" \
            | sed 's/[[:space:]]//g; s/)$//' | tr '|' '\n' | sort -u)
FLAGS=()
while IFS= read -r one; do
    [[ -n "$one" ]] && FLAGS+=("$one")
done <<<"$FLAGS_RAW"

# B0. NON-VACUITY. A zero-length enumeration would make every assertion
#     below pass without running once — the house's dominant failure
#     shape (a silent zero read as "nothing to check"). Sanity-check the
#     count against a floor AND against three flags known to exist.
if (( ${#FLAGS[@]} >= 10 )); then
    pass "B0 flag enumeration is non-vacuous (${#FLAGS[@]} flags found)"
else
    fail "B0 flag enumeration found only ${#FLAGS[@]} flags — the scan is broken, not the script"
fi
for anchor in --file --message --note; do
    # Here-string, never `printf … | grep -q`: `grep -q` exits on first match
    # without draining, the writer takes EPIPE, and `pipefail` promotes that to
    # the pipeline's status — inverting the verdict at the exact moment the
    # thing under test turns out to be TRUE (your-org/nexus-code#622, and
    # test-sigpipe-assertion-lint.sh, which caught this one).
    if grep -qxF -- "$anchor" <<<"$FLAGS_RAW"; then
        pass "B0 enumeration contains the known flag $anchor"
    else
        fail "B0 enumeration MISSED the known flag $anchor — the scan is broken"
    fi
done

USAGE=$(bash "$SCRIPT" 2>&1); USAGE_RC=$?
assert_eq "B1 a no-arg invocation still exits 1" "$USAGE_RC" "1"

# `--help` as the FIRST argument must reach the full reference. It used
# to fall through the window guard to the usage line and exit 1, so the
# reference was reachable only as `<window> --help` — and the usage line
# now tells the caller to run --help, which would have been a circle.
HELP=$(bash "$SCRIPT" --help 2>&1); HELP_RC=$?
assert_eq "B1 --help as the first argument exits 0" "$HELP_RC" "0"
HELP_WINDOWED=$(bash "$SCRIPT" suitehonesty --help 2>&1)
# Compared by digest: these are ~190-line documents, and dumping both on
# failure buries the verdict under 400 lines of prose.
assert_eq "B1 --help is identical whether or not a window precedes it" \
    "$(cksum <<<"$HELP" | cut -d' ' -f1) ($(wc -l <<<"$HELP") lines)" \
    "$(cksum <<<"$HELP_WINDOWED" | cut -d' ' -f1) ($(wc -l <<<"$HELP_WINDOWED") lines)"
# The header block ALONE — the third hand-maintained list of these flags
# (usage line, header reference, parser). Split it off from the appended
# synopsis so B5 cannot be satisfied by the synopsis it is meant to
# cross-check.
HELP_HEADER=$(sed '/^usage: paste-followup\.sh/,$d' <<<"$HELP")
if (( $(wc -l <<<"$HELP_HEADER") > 50 )); then
    pass "B1 the --help header block is non-vacuous ($(wc -l <<<"$HELP_HEADER") lines)"
else
    fail "B1 the --help header block is only $(wc -l <<<"$HELP_HEADER") lines — B5 below would be vacuous"
fi

for flag in "${FLAGS[@]}"; do
    # B2. Establish BEHAVIOURALLY that the parser accepts this flag —
    #     never assume the scan's word is the parser's. A probe with no
    #     value dies on its own arm ("--src needs a label", "message is
    #     empty", …); the only rejection that matters here is the
    #     catch-all's "unknown option".
    probe=$(bash "$SCRIPT" suitehonesty "$flag" 2>&1 </dev/null)
    if grep -qF -- "unknown option: $flag" <<<"$probe"; then
        # Not accepted — nothing to require of the usage line. Recorded
        # as a pass so the count stays honest either way.
        pass "B2 $flag is not accepted by the parser (nothing to advertise)"
        continue
    fi
    pass "B2 $flag is accepted by the parser"
    assert_contains "B3 the usage line names $flag" "$USAGE" "$flag"
    # B4 targets the HEADER alone, not header+synopsis: the header is an
    # independent hand-maintained list of the same flags, and a flag that
    # reached the synopsis but never got documented is the same defect
    # one surface over.
    assert_contains "B4 the --help reference documents $flag" "$HELP_HEADER" "$flag"
done

# B5. The two flags the issue was filed about, called out by name so a
#     future reader can see the regression anchored rather than implied.
assert_contains "B5 --administrative appears in the usage line" "$USAGE" '--administrative'
assert_contains "B5 --no-retask (its alias) appears too"        "$USAGE" '--no-retask'
assert_contains "B5 --src appears in the usage line"            "$USAGE" '--src'

# B6. THE DERIVATION FAILS LOUD. A synopsis that silently omits flags is
#     the defect; one that degrades to a shorter line when its source
#     scan breaks is the defect wearing the fix's clothes. Mutate a copy
#     so the arm block is unfindable and require a NAMED failure.
MUT="$WORK/mutant.sh"
sed 's/ARG-LOOP-BEGIN/ARG_LOOP_GONE/; s/ARG-LOOP-END/ARG_LOOP_GONE/' "$SCRIPT" > "$MUT"
if ! grep -q 'ARG-LOOP-BEGIN' "$MUT"; then
    pass "B6 mutation applied (the arm-block sentinels are gone)"
else
    fail "B6 mutation did NOT apply — B6's verdict below is meaningless"
fi
MUT_OUT=$(bash "$MUT" 2>&1); MUT_RC=$?
assert_eq "B6 the mutant still refuses (non-zero)" "$MUT_RC" "1"
assert_contains "B6 …and the failure NAMES the cause" "$MUT_OUT" 'could not derive the flag synopsis'
assert_contains "B6 …and cites the issue"             "$MUT_OUT" '#883'
assert_not_contains "B6 …and does NOT print a truncated usage line" \
    "$MUT_OUT" 'usage: paste-followup.sh <window>'

# ---------------------------------------------------------------------------
# EXPECTED-COUNT GUARD (required by test-summary-honesty-manifest.sh at the
# `ledger=yes` protection level). An assert_* block that never executes
# reports zero failures and reads as a pass — the shape this whole suite is
# about. DERIVED for the per-flag loop, because the flag population is
# discovered rather than pinned; B0's floor and its three known-flag anchors
# are what stop a shrunken enumeration from shrinking this number with it.
#   16  PART A — the receipt (A0…A8)
# +  8  PART B fixtures — B0 floor + 3 anchors, B1 rc/help-rc/help-identity/
#        header-non-vacuity
# +  3  B5 — the two flags the issue names, plus the alias
# +  5  B6 — the fail-loud derivation
# +  3  per accepted flag: B2 accepted, B3 usage names it, B4 header documents it
EXPECTED=$(( 16 + 8 + 3 + 5 + 3 * ${#FLAGS[@]} ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
