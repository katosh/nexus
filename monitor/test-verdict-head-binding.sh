#!/usr/bin/env bash
# Tests for the skeptic-verdict head binding in monitor/ng
# (jacob-greene/nexus#155).
#
# Run: bash monitor/test-verdict-head-binding.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Terms used below:
#   Verdict        the skeptic's ruling on a worker's result.
#   Head           the tip commit of a pull request's branch.
#   Validated head the exact commit a verdict states it covers.
#   Trailer        the `Skeptic-Verdict: <v> head=<sha> ...` line in a
#                  pull-request body. One parser finds it.
#
# The contract under test:
#   1. `_verdict_parse` finds the trailer in a pull-request body, takes the
#      LAST one, ignores fenced code blocks, and rejects a record with no
#      `head=`.
#   2. `ng pr merge` compares the validated head against the head it is
#      about to merge, and REFUSES (exit 5) on a mismatch. No merge PUT is
#      sent on a refusal.
#   3. `--verdict-override "<reason>"` merges past the gate, requires a
#      non-empty reason, and writes an audit line to
#      `monitor/.state/verdict-override.log`.
#   4. `ng wrap-up --skeptic-role` records the validated head in the
#      `skeptic-verdict` action-log event.
#
# The worked example is `#175` on 2026-09-11: validated at `ab2fd5f`, head
# moved to `4a284a6`, and the merge landed the unreviewed commit. Those two
# shas are used verbatim below so the suite fails if the gate stops
# catching that case.
#
# Hermetic: `ng` is SOURCED (it guards main() behind a BASH_SOURCE test) and
# its `api` / `token` / `_resolve_repo` helpers are replaced with fixtures.
# No network, no gh, no real repository.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG="$_test_dir/ng"

PASS=0
FAIL=0
ok()   { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad()  { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then ok "$label"
    else bad "$label" "got $(printf %q "$got") want $(printf %q "$want")"; fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    # An empty needle matches everything, so it could only pass vacuously.
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then ok "$label"
    else bad "$label" "missing $(printf %q "$needle") in <<$hay>>"; fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        bad "$label" "unexpectedly found $(printf %q "$needle")"
    else ok "$label"; fi
}

# ---- harness -------------------------------------------------------------
# Pin state to a temp dir. An ambient NEXUS_ROOT (every nexus agent has one,
# pointing at the primary clone) would otherwise send this suite's action-log
# writes and override audit into the operator's real state directory — and
# make its assertions read ANOTHER tree's files.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ng-verdict-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export NEXUS_STATE_DIR="$TMP/state"
mkdir -p "$NEXUS_STATE_DIR"
unset NEXUS_ROOT

# shellcheck source=ng
source "$NG" || { echo "could not source $NG" >&2; exit 1; }

# Fixture state, re-set per case.
FX_BODY=""          # pull-request body the stub serves
FX_HEAD_SHA=""      # head.sha the stub serves
FX_MERGE_SHA="deadbee0000000000000000000000000000beef"
CALLS="$TMP/api-calls.log"
PATCH_BODY="$TMP/patch-body.json"

token() { printf 'fixture-token'; }
_resolve_repo() { printf 'example-org/nexus'; }

# Stand-in for `api`. Records every call, serves the pull object, and
# answers the merge PUT. Anything else returns empty, which surfaces as a
# loud failure rather than a silent pass.
api() {
    printf '%s\n' "$*" >> "$CALLS"
    local a method="GET" path=""
    local -a argv=("$@")
    local i=0
    while (( i < ${#argv[@]} )); do
        a="${argv[$i]}"
        case "$a" in
            -X) method="${argv[$((i+1))]}"; i=$(( i + 2 )) ;;
            --input) i=$(( i + 2 )) ;;
            -*) i=$(( i + 1 )) ;;
            *) [[ -z "$path" ]] && path="$a"; i=$(( i + 1 )) ;;
        esac
    done
    # Capture the request body rather than discarding it. The first version
    # of this stub drained stdin to /dev/null and answered a PATCH with a
    # fixed html_url. That left the PUBLISH path unpinned: a mutation that
    # dropped the trailer from the patched body kept the suite green,
    # because nothing ever looked at what was published. The stub now
    # ECHOES the patched body back, exactly as the REST API does, so the
    # assertions can read the published artefact.
    local req=""
    [[ "$method" == "PUT" || "$method" == "PATCH" ]] && req=$(cat)
    [[ -n "$req" ]] && printf '%s' "$req" > "$PATCH_BODY"
    case "$method:$path" in
        PUT:*/merge)
            jq -n --arg s "$FX_MERGE_SHA" '{sha:$s}' ;;
        PATCH:*/pulls/*)
            jq -c --arg u "https://github.com/example-org/nexus/pull/175" \
                '{html_url:$u, body:(.body // "")}' <<<"$req" ;;
        GET:*/pulls/*)
            jq -n --arg b "$FX_BODY" --arg s "$FX_HEAD_SHA" \
                '{number:175, body:$b, head:{ref:"topic", sha:$s}}' ;;
        *) printf '' ;;
    esac
}

reset_calls() { : > "$CALLS"; : > "$PATCH_BODY"; }
# The body actually published by the last PATCH.
published_body() { jq -r '.body // ""' < "$PATCH_BODY" 2>/dev/null; }
# `grep -c` prints 0 AND exits 1 on no match, so a `|| printf 0` fallback
# would emit two zeros. Count with grep -c alone and normalise the exit.
merge_put_count() { local c; c=$(grep -c -- '-X PUT' "$CALLS" 2>/dev/null); printf '%s' "${c:-0}"; }

# The two shas from the 2026-09-11 incident on `#175`.
VALIDATED="ab2fd5f"
VALIDATED_FULL="ab2fd5f1111111111111111111111111111aaaa"
MERGED_FULL="4a284a62222222222222222222222222222bbbb0"

BODY_OK=$'Implements the thing.\n\nCloses #155\n\nSkeptic-Verdict: credible head='"$VALIDATED"$' depth=1 findings=0 skeptic=w7 issue=155\n'
BODY_NONE=$'Implements the thing.\n\nCloses #155\n'

# =========================================================================
printf '\n--- 1. the parser ---\n'
# =========================================================================

# T1.1 finds a trailer, and a NEGATIVE control on the same parser.
got=$(printf '%s' "$BODY_OK" | _verdict_parse); rc=$?
assert_eq "T1.1a parser exit 0 on a body that carries a trailer" "$rc" "0"
assert_eq "T1.1b parser extracts verdict + head" \
    "$(cut -f1,2 <<<"$got")" "$(printf 'credible\t%s' "$VALIDATED")"
got=$(printf '%s' "$BODY_NONE" | _verdict_parse); rc=$?
assert_eq "T1.1c parser exit 3 on a body with no trailer (control)" "$rc" "3"
assert_eq "T1.1d parser prints nothing on that body" "$got" ""

# T1.2 provenance fields.
got=$(printf '%s' "$BODY_OK" | _verdict_parse)
IFS=$'\t' read -r v h d f s i <<<"$got"
assert_eq "T1.2a depth parsed"    "$d" "1"
assert_eq "T1.2b findings parsed" "$f" "0"
assert_eq "T1.2c skeptic parsed"  "$s" "w7"
assert_eq "T1.2d issue parsed"    "$i" "155"

# T1.3 the LAST trailer wins. Re-validating after a push appends a second
# record; the newest is authoritative.
two=$'Skeptic-Verdict: check head=1111111 depth=0\n\ntext\n\nSkeptic-Verdict: credible head=2222222 depth=1\n'
got=$(printf '%s' "$two" | _verdict_parse)
assert_eq "T1.3 last trailer wins" "$(cut -f1,2 <<<"$got")" "$(printf 'credible\t2222222')"

# T1.4 a fenced code block is NOT a record. This pull request's own body
# documents the format inside a fence; without this rule the gate would read
# the documentation as a verdict.
fenced=$'How to record one:\n\n```\nSkeptic-Verdict: credible head=9999999\n```\n\nNothing else.\n'
got=$(printf '%s' "$fenced" | _verdict_parse); rc=$?
assert_eq "T1.4a a trailer inside a fence is ignored" "$rc" "3"
# Positive control: the same line OUTSIDE the fence is found.
unfenced=$'How to record one:\n\nSkeptic-Verdict: credible head=9999999\n\nNothing else.\n'
got=$(printf '%s' "$unfenced" | _verdict_parse); rc=$?
assert_eq "T1.4b control — the same line outside the fence is found" "$rc" "0"
assert_eq "T1.4c control — and it yields the head" "$(cut -f2 <<<"$got")" "9999999"

# T1.4e-j FENCE TRACKING. The naive "toggle on any fence-looking line"
# version desynchronised, and BOTH directions of that failure are
# fail-open: a documented example could read as a real verdict, and a real
# verdict could be hidden. Fence open/close now matches on character and
# length, CommonMark-style.
nested=$'````\n```\nSkeptic-Verdict: credible head=9999999\n````\n'
got=$(printf '%s' "$nested" | _verdict_parse); rc=$?
assert_eq 'T1.4e a nested ``` inside a ```` block does not close it' "$rc" "3"
nested_t=$'~~~~\n~~~\nSkeptic-Verdict: credible head=9999999\n~~~~\n'
got=$(printf '%s' "$nested_t" | _verdict_parse); rc=$?
assert_eq "T1.4f same for a nested ~~~ inside a ~~~~ block" "$rc" "3"
# A tilde line does not close a backtick fence.
mixed=$'```\n~~~\nSkeptic-Verdict: credible head=9999999\n```\n'
got=$(printf '%s' "$mixed" | _verdict_parse); rc=$?
assert_eq 'T1.4g a ~~~ line does not close a ``` fence' "$rc" "3"
# Positive control: a same-character, same-length fence DOES close, so the
# trailer after it is found. Without this the three 3s above could all come
# from a parser that never finds anything.
closed=$'````\n```\ncode\n````\n\nSkeptic-Verdict: credible head=9999999\n'
got=$(printf '%s' "$closed" | _verdict_parse); rc=$?
assert_eq "T1.4h control — a properly closed fence releases the scan" "$rc" "0"
assert_eq "T1.4i control — and the trailer after it is read" "$(cut -f2 <<<"$got")" "9999999"
# An HTML comment is invisible to every human reader of the pull request.
# A record nobody can see must not be able to assert a verdict.
commented=$'<!--\nSkeptic-Verdict: credible head=9999999\n-->\n'
got=$(printf '%s' "$commented" | _verdict_parse); rc=$?
assert_eq "T1.4j a trailer inside an HTML comment is not a verdict" "$rc" "3"
# The comment may open AFTER other text on the line. Anchoring the open to
# the start of a line missed that, and the miss is the `#155` inversion in
# the other direction: a reader sees nothing, the gate reads `credible`.
midline=$'text <!--\nSkeptic-Verdict: credible head=9999999\n-->\n'
got=$(printf '%s' "$midline" | _verdict_parse); rc=$?
assert_eq "T1.4j2 a comment opened mid-line also hides the trailer" "$rc" "3"
# A comment that opens AND closes on one line opens no block, so a trailer
# after it is still read. Without this the rule above could over-reach.
sameline=$'text <!-- aside --> more\n\nSkeptic-Verdict: credible head=9999999\n'
got=$(printf '%s' "$sameline" | _verdict_parse); rc=$?
assert_eq "T1.4j3 control — a one-line comment opens no block" "$rc" "0"
assert_eq "T1.4j4 control — and the later trailer is read" "$(cut -f2 <<<"$got")" "9999999"

# T1.4v THE COLUMN-ZERO ANCHOR IS LOAD-BEARING IN THE SCAN, not only in the
# validator. The awk anchor decides WHICH line is selected; the bash regex
# only validates the line already selected, and cannot recover a line awk
# never picked.
#
# A real trailer followed LATER by an indented mention of the format is the
# case that separates them. Without the awk anchor, `last` lands on the
# indented line because it comes later, the validator rejects it, and the
# real trailer above is never seen. The direction is fail-open.
#
# An earlier version of this suite tested a body containing ONLY an indented
# line. Both anchors reject that, so they agreed and the test proved nothing.
anchored=$'Skeptic-Verdict: credible head=9999999\n\nFormat note:\n\n    Skeptic-Verdict: credible head=1111111\n'
got=$(printf '%s' "$anchored" | _verdict_parse); rc=$?
assert_eq "T1.4v a real trailer survives a later indented mention" "$rc" "0"
assert_eq "T1.4w and the head is the real one, not the indented one" \
    "$(cut -f2 <<<"$got")" "9999999"

# T1.4x the FIRST head= wins. Trailing prose carrying a `head=` token must
# not rebind the record to another commit.
twoheads=$'Skeptic-Verdict: credible head=aaaaaaa note head=bbbbbbb\n'
got=$(printf '%s' "$twoheads" | _verdict_parse); rc=$?
assert_eq "T1.4x a line with two head= tokens still parses" "$rc" "0"
assert_eq "T1.4y and binds to the FIRST, the canonical position" \
    "$(cut -f2 <<<"$got")" "aaaaaaa"

# T1.4q-t the fence rule must cover BOTH fence characters and an indented
# fence. These close mutations that survived the first round: dropping
# `~~~` from the fence match, and requiring a fence to start at column 0.
tilde=$'x\n~~~\nSkeptic-Verdict: credible head=9999999\n~~~\n'
got=$(printf '%s' "$tilde" | _verdict_parse); rc=$?
assert_eq "T1.4q a plain ~~~ fence hides a trailer" "$rc" "3"
indented=$'x\n  ```\n  code\nSkeptic-Verdict: credible head=9999999\n  ```\n'
got=$(printf '%s' "$indented" | _verdict_parse); rc=$?
assert_eq "T1.4r a fence indented up to 3 spaces still opens a block" "$rc" "3"
indented_t=$'x\n   ~~~\nSkeptic-Verdict: credible head=9999999\n   ~~~\n'
got=$(printf '%s' "$indented_t" | _verdict_parse); rc=$?
assert_eq "T1.4s same for an indented ~~~ fence" "$rc" "3"
# Positive control for the three above: without a fence, the same line is
# found. Three 3s from a parser that never matches would prove nothing.
got=$(printf '%s' $'x\nSkeptic-Verdict: credible head=9999999\n' | _verdict_parse); rc=$?
assert_eq "T1.4t control — unfenced, the same line is found" "$rc" "0"

# T1.4u a head longer than 40 hex characters is not a commit.
toolong=$'Skeptic-Verdict: credible head=abcdef01234567890123456789012345678901234\n'
got=$(printf '%s' "$toolong" | _verdict_parse); rc=$?
assert_eq "T1.4u a 41-character head is rejected" "$rc" "3"

# T1.4k CRLF. A body fetched from the API can carry CRLF line endings; the
# trailing \r would otherwise break the sha match and read as "no verdict".
crlf=$'a description\r\n\r\nSkeptic-Verdict: credible head=9999999\r\n'
got=$(printf '%s' "$crlf" | _verdict_parse); rc=$?
assert_eq "T1.4k a CRLF body still parses" "$rc" "0"
assert_eq "T1.4l and yields a clean head with no carriage return" \
    "$(cut -f2 <<<"$got")" "9999999"

# T1.4m FIELD ORDER. `head=` used to be positional, so a record that put
# depth first parsed as nothing and the gate silently switched off. A
# field-order mistake must not be a fail-open.
reordered=$'Skeptic-Verdict: credible depth=1 findings=0 head=9999999 issue=155\n'
got=$(printf '%s' "$reordered" | _verdict_parse); rc=$?
assert_eq "T1.4m head= is read from anywhere on the line" "$rc" "0"
assert_eq "T1.4n and yields the head" "$(cut -f2 <<<"$got")" "9999999"
assert_eq "T1.4o with the other fields still parsed" "$(cut -f3 <<<"$got")" "1"

# T1.4p a glob in a provenance value must not expand against the cwd.
# The pattern only bites when a matching FILE exists, so plant one. Without
# it the token stays unexpanded for the wrong reason and the assertion
# passes against an unquoted split too.
mkdir -p "$TMP/globdir" && : > "$TMP/globdir/skeptic=PLANTED"
globby=$'Skeptic-Verdict: credible head=9999999 skeptic=*\n'
got=$( cd "$TMP/globdir" && printf '%s' "$globby" | _verdict_parse )
assert_eq "T1.4p an unquoted split would glob; skeptic= stays literal" \
    "$(cut -f5 <<<"$got")" "*"

# T1.5 a verdict with no head is NOT well-formed. Binding the head is the
# point; a headless record must not read as a valid verdict.
headless=$'Skeptic-Verdict: credible\n'
got=$(printf '%s' "$headless" | _verdict_parse); rc=$?
assert_eq "T1.5a a headless record is rejected" "$rc" "3"
got=$(printf '%s' $'Skeptic-Verdict: credible head=abc\n' | _verdict_parse); rc=$?
assert_eq "T1.5b a head under 7 characters is rejected" "$rc" "3"
got=$(printf '%s' $'Skeptic-Verdict: excellent head=1234567\n' | _verdict_parse); rc=$?
assert_eq "T1.5c an unknown verdict word is rejected" "$rc" "3"
got=$(printf '%s' $'  Skeptic-Verdict: credible head=1234567\n' | _verdict_parse); rc=$?
assert_eq "T1.5d an indented line is not a trailer" "$rc" "3"

# T1.6 head comparison: an abbreviated record must match the full sha.
_verdict_head_match "$VALIDATED" "$VALIDATED_FULL"
assert_eq "T1.6a short record matches the full head" "$?" "0"
_verdict_head_match "$VALIDATED_FULL" "$VALIDATED"
assert_eq "T1.6b and the comparison is symmetric" "$?" "0"
_verdict_head_match "$VALIDATED" "$MERGED_FULL"
assert_eq "T1.6c a different commit does not match" "$?" "1"
_verdict_head_match "AB2FD5F" "$VALIDATED_FULL"
assert_eq "T1.6d case-insensitive" "$?" "0"
_verdict_head_match "ab2fd" "$VALIDATED_FULL"
assert_eq "T1.6e a token under the 7-character floor never matches" "$?" "1"
_verdict_head_match "" "$VALIDATED_FULL"
assert_eq "T1.6f an empty recorded head never matches" "$?" "1"
# The floor is exactly 7. A 6-character prefix is too weak to identify a
# commit, so it must never match even when it IS a true prefix.
_verdict_head_match "ab2fd5" "$VALIDATED_FULL"
assert_eq "T1.6g a 6-character true prefix is below the floor" "$?" "1"
_verdict_head_match "ab2fd5f" "$VALIDATED_FULL"
assert_eq "T1.6h control — 7 characters is at the floor and matches" "$?" "0"

# =========================================================================
printf '\n--- 2. ng pr merge, through cmd_pr_merge ---\n'
# =========================================================================

# T2.1 THE WORKED EXAMPLE. Verdict covers ab2fd5f; the head is 4a284a6.
FX_BODY="$BODY_OK"; FX_HEAD_SHA="$MERGED_FULL"; reset_calls
out=$( cmd_pr_merge 175 2>&1 ); rc=$?
assert_eq "T2.1a refuses a head the verdict does not cover (exit 5)" "$rc" "5"
assert_contains "T2.1b names the validated head" "$out" "$VALIDATED"
assert_contains "T2.1c names the head it would have merged" "$out" "$MERGED_FULL"
assert_contains "T2.1d says REFUSED" "$out" "REFUSED"
assert_eq "T2.1e no merge PUT was sent" "$(merge_put_count)" "0"
assert_not_contains "T2.1f the merge sha was not printed" "$out" "$FX_MERGE_SHA"

# T2.2 the matching case still merges.
FX_BODY="$BODY_OK"; FX_HEAD_SHA="$VALIDATED_FULL"; reset_calls
out=$( cmd_pr_merge 175 2>/dev/null ); rc=$?
assert_eq "T2.2a merges when the validated head is the head (exit 0)" "$rc" "0"
assert_eq "T2.2b prints the merge sha" "$out" "$FX_MERGE_SHA"
assert_eq "T2.2c exactly one merge PUT was sent" "$(merge_put_count)" "1"

# T2.3 no trailer: warn, proceed. Most pull requests never had a skeptic.
FX_BODY="$BODY_NONE"; FX_HEAD_SHA="$MERGED_FULL"; reset_calls
out=$( cmd_pr_merge 175 2>"$TMP/err" ); rc=$?
err=$(cat "$TMP/err")
assert_eq "T2.3a merges when no verdict is recorded" "$rc" "0"
assert_contains "T2.3b and says the head was not checked" "$err" "head not checked"

# T2.4 --require-verdict turns that into a hard stop.
FX_BODY="$BODY_NONE"; FX_HEAD_SHA="$MERGED_FULL"; reset_calls
out=$( cmd_pr_merge 175 --require-verdict 2>&1 ); rc=$?
assert_eq "T2.4a --require-verdict refuses a PR with no trailer" "$rc" "5"
assert_eq "T2.4b and sends no merge PUT" "$(merge_put_count)" "0"

# T2.5 a non-credible verdict at the right head warns but merges. The gate
# this issue asks for binds the HEAD; ruling on the verdict word is a
# separate decision and is deliberately left to the operator.
FX_BODY=$'Skeptic-Verdict: check head='"$VALIDATED"$'\n'
FX_HEAD_SHA="$VALIDATED_FULL"; reset_calls
out=$( cmd_pr_merge 175 2>"$TMP/err" ); rc=$?
err=$(cat "$TMP/err")
assert_eq "T2.5a a 'check' verdict at the right head still merges" "$rc" "0"
assert_contains "T2.5b but the mismatch in verdict word is stated" "$err" "not 'credible'"

# T2.6 a pull request whose head sha cannot be resolved is not merged blind.
# The upstream merge verb falls back to an UNPINNED merge when no head
# resolves; with a verdict recorded, the gate refuses first (exit 5),
# because no recorded head can match an unknown one.
FX_BODY="$BODY_OK"; FX_HEAD_SHA=""; reset_calls
out=$( cmd_pr_merge 175 2>&1 ); rc=$?
assert_eq "T2.6a refuses when the head sha does not resolve" "$rc" "5"
assert_eq "T2.6b and sends no merge PUT" "$(merge_put_count)" "0"

# =========================================================================
printf '\n--- 3. the override ---\n'
# =========================================================================

# T3.1 an override with a reason merges past a mismatch AND is audited.
FX_BODY="$BODY_OK"; FX_HEAD_SHA="$MERGED_FULL"; reset_calls
rm -f "$NEXUS_STATE_DIR/verdict-override.log"
out=$( cmd_pr_merge 175 --verdict-override "rejoins one wrapped line, changes no word" 2>"$TMP/err" ); rc=$?
err=$(cat "$TMP/err")
assert_eq "T3.1a the override merges (exit 0)" "$rc" "0"
assert_eq "T3.1b and one merge PUT was sent" "$(merge_put_count)" "1"
assert_contains "T3.1c stderr says OVERRIDE" "$err" "OVERRIDE"
audit=$(cat "$NEXUS_STATE_DIR/verdict-override.log" 2>/dev/null)
assert_contains "T3.1d an audit line was written" "$audit" "rejoins one wrapped line"
assert_contains "T3.1e the audit names the recorded head" "$audit" "recorded-head=$VALIDATED"
assert_contains "T3.1f the audit names the merged head" "$audit" "merged-head=$MERGED_FULL"
assert_contains "T3.1g the audit names the kind" "$audit" "kind=head-mismatch"
alog=$(cat "$NEXUS_STATE_DIR/action-log.jsonl" 2>/dev/null)
assert_contains "T3.1h and a verdict-override event was logged" "$alog" '"event":"verdict-override"'
# An audit trail anybody in the unix group can rewrite is not an audit
# trail. Same rule the impersonate log follows (monitor/_log-mode.sh).
mode=$(stat -c '%a' "$NEXUS_STATE_DIR/verdict-override.log" 2>/dev/null)
assert_eq "T3.1i the audit log is created 0640, not group-writable" "$mode" "640"

# T3.1j-m the OTHER override path: no verdict recorded, --require-verdict
# passed, override supplied. It must audit too, and under its own kind, so
# the log distinguishes "merged past a stale verdict" from "merged with no
# verdict at all".
FX_BODY="$BODY_NONE"; FX_HEAD_SHA="$MERGED_FULL"; reset_calls
: > "$NEXUS_STATE_DIR/verdict-override.log"
out=$( cmd_pr_merge 175 --require-verdict --verdict-override "no skeptic was required for this change" 2>/dev/null ); rc=$?
audit=$(cat "$NEXUS_STATE_DIR/verdict-override.log" 2>/dev/null)
assert_eq "T3.1j the missing-verdict override merges" "$rc" "0"
assert_contains "T3.1k and writes an audit line" "$audit" "no skeptic was required"
assert_contains "T3.1l under its own kind" "$audit" "kind=missing-verdict"
assert_contains "T3.1m recording that no head was on record" "$audit" "recorded-head=none"

# T3.2 a silent override is refused. An override with no reason is a
# disabled gate, not an override.
FX_BODY="$BODY_OK"; FX_HEAD_SHA="$MERGED_FULL"; reset_calls
out=$( cmd_pr_merge 175 --verdict-override "" 2>&1 ); rc=$?
# An EMPTY value is a usage error (exit 64, EX_USAGE) via `_need_val`.
assert_eq "T3.2a an empty reason is refused" "$rc" "64"
assert_eq "T3.2b and no merge PUT was sent" "$(merge_put_count)" "0"
reset_calls
out=$( cmd_pr_merge 175 --verdict-override "   " 2>&1 ); rc=$?
assert_eq "T3.2c a whitespace-only reason is refused" "$rc" "1"
reset_calls
out=$( cmd_pr_merge 175 --verdict-override --squash 2>&1 ); rc=$?
assert_eq "T3.2d a bare flag that swallowed the next flag is refused" "$rc" "1"
assert_eq "T3.2e and no merge PUT was sent" "$(merge_put_count)" "0"

# T3.3 the override does NOT fire when there is nothing to override — the
# audit log must only record merges that actually went past the gate.
FX_BODY="$BODY_OK"; FX_HEAD_SHA="$VALIDATED_FULL"; reset_calls
: > "$NEXUS_STATE_DIR/verdict-override.log"
out=$( cmd_pr_merge 175 --verdict-override "not needed here" 2>/dev/null ); rc=$?
audit=$(cat "$NEXUS_STATE_DIR/verdict-override.log" 2>/dev/null)
assert_eq "T3.3a a matching head merges normally" "$rc" "0"
assert_eq "T3.3b and writes no audit line" "$audit" ""

# =========================================================================
printf '\n--- 4. ng pr verdict set|get ---\n'
# =========================================================================

# T4.1 set with no --head binds the PR's CURRENT head.
FX_BODY="$BODY_NONE"; FX_HEAD_SHA="$VALIDATED_FULL"; reset_calls
out=$( cmd_pr_verdict_set 175 --verdict credible --depth 1 --findings 0 --skeptic w7 --issue 155 2>&1 ); rc=$?
assert_eq "T4.1a set exits 0" "$rc" "0"
assert_contains "T4.1b the trailer carries the current head" "$out" "head=$VALIDATED_FULL"
assert_contains "T4.1c and the verdict" "$out" "Skeptic-Verdict: credible"
assert_contains "T4.1d and the provenance fields" "$out" "depth=1 findings=0 skeptic=w7 issue=155"

# T4.1k a window name containing whitespace must not break the single-line
# field split. The render squashes it; without that, everything after the
# space parses as a separate token and the record is malformed.
FX_BODY="$BODY_NONE"; reset_calls
spaced=$( cmd_pr_verdict_set 175 --verdict credible --skeptic "two words" 2>&1 | head -1 )
assert_contains "T4.1k whitespace in skeptic= is squashed" "$spaced" "skeptic=two_words"
rt=$(printf '%s\n' "$spaced" | _verdict_parse)
assert_eq "T4.1l so the record still parses to one skeptic field" \
    "$(cut -f5 <<<"$rt")" "two_words"
FX_BODY="$BODY_NONE"; reset_calls
out=$( cmd_pr_verdict_set 175 --verdict credible --depth 1 --findings 0 --skeptic w7 --issue 155 2>&1 )

# T4.1e-h THE PUBLISH PATH. Assert on the body that was actually PATCHed,
# not on the string the function printed. Without these, a mutation that
# drops the trailer from the patched body leaves the whole feature a no-op
# and the suite green — `set` still exits 0, still prints the trailer, and
# still sends the PATCH. Only the published artefact distinguishes them.
pub=$(published_body)
assert_contains "T4.1e the PUBLISHED body carries the trailer" \
    "$pub" "Skeptic-Verdict: credible head=$VALIDATED_FULL"
assert_contains "T4.1f the published body keeps the original description" \
    "$pub" "Implements the thing."
# The record must be readable by the same parser the gate uses.
pubparse=$(printf '%s' "$pub" | _verdict_parse); rc=$?
assert_eq "T4.1g the published body parses" "$rc" "0"
assert_eq "T4.1h and parses to the head that was set" \
    "$(cut -f2 <<<"$pubparse")" "$VALIDATED_FULL"
# The trailer is APPENDED, not prepended: the parser takes the last one, so
# a prepend would let a stale earlier record win.
assert_eq "T4.1i the trailer is the LAST line of the published body" \
    "$(printf '%s' "$pub" | grep -c '^Skeptic-Verdict:')" "1"
tailline=$(printf '%s' "$pub" | grep -v '^[[:space:]]*$' | tail -1)
assert_contains "T4.1j and it sits after the description, not before" \
    "$tailline" "Skeptic-Verdict: credible"

# T4.2 round trip: what `set` renders, `_verdict_parse` reads back.
trailer=$(head -1 <<<"$out")
rt=$(printf '%s\n' "$trailer" | _verdict_parse); rc=$?
assert_eq "T4.2a the rendered trailer parses" "$rc" "0"
assert_eq "T4.2b and yields the same head" "$(cut -f2 <<<"$rt")" "$VALIDATED_FULL"

# T4.3 get reads it back, and exits 3 when absent.
FX_BODY="$BODY_OK"; FX_HEAD_SHA="$VALIDATED_FULL"
out=$( cmd_pr_verdict_get 175 --field head 2>&1 ); rc=$?
assert_eq "T4.3a get --field head exits 0" "$rc" "0"
assert_eq "T4.3b and prints the recorded head" "$out" "$VALIDATED"
FX_BODY="$BODY_NONE"
out=$( cmd_pr_verdict_get 175 2>&1 ); rc=$?
assert_eq "T4.3c get exits 3 when the PR carries no trailer" "$rc" "3"

# T4.4 set refuses a verdict word outside the ladder, and a bad head.
FX_BODY="$BODY_NONE"; FX_HEAD_SHA="$VALIDATED_FULL"
out=$( cmd_pr_verdict_set 175 --verdict excellent 2>&1 ); rc=$?
assert_eq "T4.4a an unknown verdict word is refused" "$rc" "1"
out=$( cmd_pr_verdict_set 175 --verdict credible --head zzzz 2>&1 ); rc=$?
assert_eq "T4.4b a non-sha --head is refused" "$rc" "1"

# T4.5 an appended trailer supersedes an earlier one. `set` must not have to
# rewrite history for the gate to read the newest record.
FX_BODY="$BODY_OK"; FX_HEAD_SHA="$MERGED_FULL"
out=$( cmd_pr_verdict_set 175 --verdict credible 2>&1 )
combined="$BODY_OK"$'\n\n'"$(head -1 <<<"$out")"$'\n'
rt=$(printf '%s' "$combined" | _verdict_parse)
assert_eq "T4.5 after re-recording, the parser reads the NEW head" \
    "$(cut -f2 <<<"$rt")" "$MERGED_FULL"
# ... and the gate then lets the merge through.
FX_BODY="$combined"; reset_calls
out=$( cmd_pr_merge 175 2>/dev/null ); rc=$?
assert_eq "T4.5b re-recording at the new head unblocks the merge" "$rc" "0"

# T4.6 THE READ-BACK. An unclosed code fence anywhere before the append
# swallows the trailer: the parser sees it inside a code block and reports
# no verdict, so the gate switches off. Nothing about that is visible at
# record time unless `set` reads back what it published.
FX_BODY=$'a description\n```\nan unclosed code fence\n'
FX_HEAD_SHA="$VALIDATED_FULL"; reset_calls
out=$( cmd_pr_verdict_set 175 --verdict credible 2>&1 ); rc=$?
assert_eq "T4.6a set FAILS when the published trailer does not parse back" "$rc" "1"
assert_contains "T4.6b and says the gate is off" "$out" "gate is OFF"
assert_contains "T4.6c and names the likely cause" "$out" "unclosed code fence"
# Positive control: the same call on a body with no unclosed fence succeeds.
FX_BODY=$'a description\n```\na CLOSED code fence\n```\n'; reset_calls
out=$( cmd_pr_verdict_set 175 --verdict credible 2>&1 ); rc=$?
assert_eq "T4.6d control — a closed fence records normally" "$rc" "0"

# T4.6e-h the read-back must read the PATCH RESPONSE, not the string the
# function built. Reading the response is the whole reason the check works:
# it pins the published artefact rather than the intent. A read-back that
# re-parsed its own `new_body` would pass on a publish that never landed.
#
# Drive it by making the RESPONSE disagree with what was sent. The stub
# echoes a body naming a DIFFERENT head; a response-reading check must
# refuse, an intent-reading one would not notice.
_FX_PATCH_ECHO=$'a description\n\nSkeptic-Verdict: credible head=7777777\n'
api() {
    printf '%s\n' "$*" >> "$CALLS"
    local m=GET a prev=""
    for a in "$@"; do [[ "$prev" == "-X" ]] && m="$a"; prev="$a"; done
    local req=""
    [[ "$m" == "PUT" || "$m" == "PATCH" ]] && req=$(cat)
    [[ -n "$req" ]] && printf '%s' "$req" > "$PATCH_BODY"
    case "$m" in
        PATCH) jq -cn --arg u "https://x/pull/175" --arg b "$_FX_PATCH_ECHO" \
                   '{html_url:$u, body:$b}' ;;
        *)     jq -n --arg b "$FX_BODY" --arg s "$FX_HEAD_SHA" \
                   '{number:175, body:$b, head:{ref:"topic", sha:$s}}' ;;
    esac
}
FX_BODY="$BODY_NONE"; FX_HEAD_SHA="$VALIDATED_FULL"; reset_calls
out=$( cmd_pr_verdict_set 175 --verdict credible 2>&1 ); rc=$?
assert_eq "T4.6e set FAILS when the response names a different head" "$rc" "1"
assert_contains "T4.6f and names the head that came back" "$out" "7777777"
assert_contains "T4.6g and says the gate would compare the wrong commit" \
    "$out" "wrong commit"
# Control: when the response agrees, the same call succeeds. Without this,
# T4.6e could pass against a check that refuses everything.
_FX_PATCH_ECHO=$'a description\n\nSkeptic-Verdict: credible head='"$VALIDATED_FULL"$'\n'
reset_calls
out=$( cmd_pr_verdict_set 175 --verdict credible 2>&1 ); rc=$?
assert_eq "T4.6h control — an agreeing response records normally" "$rc" "0"
# Restore the standard stub for the cases that follow.
api() {
    printf '%s\n' "$*" >> "$CALLS"
    local m=GET a prev=""
    for a in "$@"; do [[ "$prev" == "-X" ]] && m="$a"; prev="$a"; done
    local req=""
    [[ "$m" == "PUT" || "$m" == "PATCH" ]] && req=$(cat)
    [[ -n "$req" ]] && printf '%s' "$req" > "$PATCH_BODY"
    case "$m" in
        PUT)   jq -n --arg s "$FX_MERGE_SHA" '{sha:$s}' ;;
        PATCH) jq -c --arg u "https://github.com/example-org/nexus/pull/175" \
                   '{html_url:$u, body:(.body // "")}' <<<"$req" ;;
        *)     jq -n --arg b "$FX_BODY" --arg s "$FX_HEAD_SHA" \
                   '{number:175, body:$b, head:{ref:"topic", sha:$s}}' ;;
    esac
}

# T4.7 a stale earlier record must not be left winning. If the append lands
# but an earlier trailer still parses last, the gate compares the wrong
# commit, so `set` refuses rather than reporting success.
FX_BODY="$BODY_NONE"; FX_HEAD_SHA="$VALIDATED_FULL"; reset_calls
out=$( cmd_pr_verdict_set 175 --verdict credible 2>&1 ); rc=$?
pubparse=$(published_body | _verdict_parse)
assert_eq "T4.7 the published record is the one just set" \
    "$(cut -f2 <<<"$pubparse")" "$VALIDATED_FULL"

# T4.8 a value-taking flag at the END of the argument list must not hang.
# `shift 2` with one argument left FAILS and shifts nothing, so the parse
# loop spins forever. Each case runs under a hard timeout; exit 124 is the
# hang and is a FAILURE, never a pass.
FX_BODY="$BODY_OK"; FX_HEAD_SHA="$MERGED_FULL"
for flag in --verdict-override --repo; do
    ( timeout 10 bash -c '
        export NEXUS_STATE_DIR="$1"; cd "$2"
        source ./monitor/ng >/dev/null 2>&1
        api() { printf ""; }; token() { printf t; }; _resolve_repo() { printf o/r; }
        cmd_pr_merge 42 "$3"' _ "$NEXUS_STATE_DIR" "$_test_dir/.." "$flag" ) >/dev/null 2>&1
    rc=$?
    if (( rc == 124 )); then
        bad "T4.8 \`pr merge 42 $flag\` (trailing) hangs" "timed out — shift 2 spin"
    else
        ok "T4.8 \`pr merge 42 $flag\` (trailing) fails fast, no hang (exit $rc)"
    fi
done

# =========================================================================
printf '\n--- 5. the verdict record carries the head ---\n'
# =========================================================================

# T5.1 the skeptic-role wrap-up path records `head=` in its action-log event.
ALOG="$NEXUS_STATE_DIR/action-log.jsonl"
: > "$ALOG"
out=$( _wrapup_skeptic_step 155 "" "example-org/nexus" \
        1 "" "" "" credible "worker-w3" 1 0 "" "" "" "" 0 "" "$VALIDATED_FULL" "" 2>&1 ); rc=$?
assert_eq "T5.1a the role path returns 0" "$rc" "0"
ev=$(grep '"event":"skeptic-verdict"' "$ALOG" | tail -1)
assert_contains "T5.1b the event carries the head" "$ev" "\"head\":\"$VALIDATED_FULL\""
assert_contains "T5.1c and names where the head came from" "$ev" '"head-source":"flag"'
assert_contains "T5.1d and still carries the verdict" "$ev" '"verdict":"credible"'
assert_contains "T5.1e the printed block states the validated head" "$out" "validated head"

# Negative control on the same assertion: the pre-change event shape had no
# head field at all, so confirm the grep is capable of failing.
assert_not_contains "T5.1f control — no bogus head leaks in" "$ev" '"head":"0000000"'

# T5.2 a malformed --skeptic-head is refused rather than recorded.
: > "$ALOG"
out=$( _wrapup_skeptic_step 155 "" "example-org/nexus" \
        1 "" "" "" credible "worker-w3" 1 0 "" "" "" "" 0 "" "not-a-sha" "" 2>&1 ); rc=$?
assert_eq "T5.2a a malformed head fails the wrap-up" "$rc" "1"
assert_contains "T5.2b with a message naming the flag" "$out" "--skeptic-head"

# T5.3 with no head available anywhere, the block says so loudly instead of
# recording a verdict that cannot gate anything.
: > "$ALOG"
out=$( cd "$TMP" && _wrapup_skeptic_step 155 "" "example-org/nexus" \
        1 "" "" "" credible "worker-w3" 1 0 "" "" "" "" 0 "" "" "" 2>&1 ); rc=$?
assert_eq "T5.3a still returns 0 (a missing head does not fail a wrap-up)" "$rc" "0"
assert_contains "T5.3b but the block warns the head is UNKNOWN" "$out" "UNKNOWN"

# T5.4 --skeptic-pr resolves the head from the pull request and publishes
# the trailer, so the record travels with the pull request.
: > "$ALOG"; reset_calls
FX_BODY="$BODY_NONE"; FX_HEAD_SHA="$VALIDATED_FULL"
out=$( _wrapup_skeptic_step 155 "skeptic-w9" "example-org/nexus" \
        1 "" "" "" credible "worker-w3" 1 0 "" "" "" "" 0 "" "" 175 2>&1 ); rc=$?
ev=$(grep '"event":"skeptic-verdict"' "$ALOG" | tail -1)
assert_eq "T5.4a the role path returns 0" "$rc" "0"
assert_contains "T5.4b the head came from the pull request" "$ev" '"head-source":"pr-175"'
assert_contains "T5.4c and is the PR's current head" "$ev" "\"head\":\"$VALIDATED_FULL\""
assert_contains "T5.4d the event names the pull request" "$ev" '"pr":"175"'
assert_contains "T5.4e a body PATCH was sent to publish the trailer" \
    "$(cat "$CALLS")" "PATCH"
assert_contains "T5.4f and the operator is told it was published" "$out" "trailer published"

# =========================================================================
printf '\n--- results ---\n'
# =========================================================================
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED\n'
    exit 0
fi
printf 'SUITE FAILED\n' >&2
exit 1
