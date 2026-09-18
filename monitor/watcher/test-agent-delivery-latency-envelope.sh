#!/usr/bin/env bash
# The `invoke: agent` LATENCY ENVELOPE, and the two readings it inverts.
# (your-org/nexus-code#1272)
#
# Run: bash monitor/watcher/test-agent-delivery-latency-envelope.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHAT THIS GUARDS, AND WHY A TEXT GUARD IS THE RIGHT INSTRUMENT HERE. `#1272`
# has no code fix available in this repo: the transport is an in-process harness
# tool (`invoke: agent`, §2), no script can call it, and its receipt class is
# already correctly declared `none`. What was missing is the LATENCY ENVELOPE
# beside that class — the fact that `none` means "no evidence of arrival" and
# NOT "prompt", so a sender who waits, sees nothing and concludes `dropped` is
# wrong with total confidence, because an in-flight message and a lost one are
# the same absence.
#
# Prose cannot be made to fail. So the four properties that make this section
# HONEST are asserted rather than trusted, and each one is a direction the text
# could plausibly drift in:
#
#   P1  the statement exists at all, attached to the `none` receipt class —
#       an annotation must not outlive the thing it annotates;
#   P2  it claims NO upper bound. The five-minute observation is the whole
#       measurement, and the failure mode of writing it down is that a later
#       reader promotes it to a ceiling and a later editor writes the ceiling
#       into the contract. A guaranteed-delivery-within-N sentence here would
#       be an unsupported bound in a document agents act on;
#   P3  the UNMEASURED regime is still marked unmeasured. "14 of 14 delivered"
#       over shorter, smaller probes is a claim about the population measured;
#       the ~20-concurrent many-minute regime the loss claim describes was not
#       tested, and the moment that caveat is dropped the section reads as a
#       refutation it never was;
#   P4  both corrections survive IN THE DIRECTION THAT INVERTS THE NATURAL
#       READING. `success:true` DOES discriminate a reachable recipient, and
#       the reachable set IS wider than the system-reminder roster. Half-copied
#       — the token present, the polarity gone — either one becomes advice that
#       is worse than silence.
#
# NON-VACUITY. §3 below is a POTENCY CONTROL that mutates a COPY of the contract
# and requires each assertion to flip. Without it every check here is satisfied
# by a `grep` against a file nobody changed, which is the inert-control shape
# this repo keeps finding — an assertion that has only ever been shown to say
# yes is not an assertion.
#
# COVERAGE BOUNDARY, stated rather than implied. This guards the TEXT of
# `skills/nexus.agent-delivery/SKILL.md` and its internal consistency with the
# receipt table. It measures NO latency and can measure none: the transport is
# reachable only from inside an agent's tool loop, which is the same reason
# `#1272` is a documentation fix. It therefore certifies that the envelope is
# RECORDED, never that it is CURRENT.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CONTRACT="$REPO_ROOT/skills/nexus.agent-delivery/SKILL.md"

. "$_test_dir/_test_helpers.sh"
EXPECTED_ASSERTIONS=30   # counted BEFORE the census assertion itself
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s (got %q)\n' "$label" "$got"; _th_pass
    else printf '  FAIL: %s — got %q, want %q\n' "$label" "$got" "$want" >&2; _th_fail; fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    # An EMPTY needle matches every haystack, so this assertion could only pass
    # VACUOUSLY — the shape `monitor/watcher/test-empty-needle-local-copies.sh`
    # enrols every local copy against (your-org/nexus-code#1092). Fail CLOSED
    # and blame the CALLER, whose expected value came back empty.
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" && "$hay" == *"$needle"* ]]; then printf '  PASS: %s\n' "$label"; _th_pass
    else printf '  FAIL: %s — %q not found\n' "$label" "$needle" >&2; _th_fail; fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if [[ "$hay" != *"$needle"* ]]; then printf '  PASS: %s\n' "$label"; _th_pass
    else printf '  FAIL: %s — %q WAS found\n' "$label" "$needle" >&2; _th_fail; fi
}

[[ -r "$CONTRACT" ]] || { echo "missing: $CONTRACT" >&2; exit 2; }
doc=$(cat "$CONTRACT")

WORK=$(mktemp -d "/tmp/adle-$$-XXXXXX") || { echo "cannot mktemp" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ── §0  THE ANNOTATION AND THE THING IT ANNOTATES ───────────────────────
echo '=== §0 the `none` receipt class still exists, so the annotation has a subject ==='
assert_contains "the receipt table still declares \`none\`" "$doc" \
    '| `none` | the transport can produce no evidence of arrival |'
assert_contains "…and \`invoke: agent\` is still the class that carries it" "$doc" \
    "**Claude Code's \`SendMessage\` is \`invoke: agent\`.**"

# ── §1  P1/P2/P3 — THE ENVELOPE, AND WHAT IT REFUSES TO CLAIM ───────────
echo '=== §1 the measurement is recorded, and its limits are recorded with it ==='
assert_contains "P1 the section exists, keyed to the receipt class" "$doc" \
    '### `none` is not "fast and silent" — it is ASYNCHRONOUS'
assert_contains "P1 …carrying the measured observation"            "$doc" "**arrived at 14:21**"
assert_contains "P1 …and naming the sender-side indistinguishability" "$doc" \
    "an in-flight message and a lost one are the same absence"
assert_contains "P2 no upper bound is claimed, and it says so"     "$doc" \
    "**NO UPPER BOUND IS CLAIMED, and the five minutes must not be read as one.**"
assert_contains "P2 …and it forbids the read that would follow"    "$doc" \
    "not a timeout to wait out"
assert_contains "P3 the reproduction result is stated with its population" "$doc" \
    "**14 of 14 subagent final"
assert_contains "P3 …bounded to the duration actually probed"      "$doc" "**at 80 s**"
assert_contains "P3 …and the reported regime is marked UNTESTED"   "$doc" \
    "roughly 20 concurrent, many-minute subagents — is
UNTESTED"
assert_contains "P3 …explicitly NOT a refutation"                  "$doc" \
    "This is not a refutation of the loss claim"
assert_contains "P3 …and recorded in the file's own unknowns list" "$doc" \
    "no upper bound on delivery latency has been established"

# The bound the section must NEVER acquire. A guaranteed-delivery sentence is
# the specific drift P2 exists to prevent, and a presence check cannot see it.
assert_not_contains "P2 CONTROL: the contract promises no delivery guarantee" "$doc" \
    "delivery is guaranteed within"
assert_not_contains "P2 CONTROL: …nor a maximum latency"                      "$doc" \
    "maximum latency"

# ── §2  P4 — THE TWO CORRECTIONS, IN THE INVERTING DIRECTION ────────────
#
# Each is asserted on the AFFIRMATIVE clause, not on the token. `success:true`
# appears in the section either way; what must survive is the sentence saying it
# DOES discriminate, because the reading it corrects is the opposite one.
echo '=== §2 the two corrections keep their polarity ==='
assert_contains "P4a success:true DOES discriminate, stated affirmatively" "$doc" \
    "**\`success:true\` DOES discriminate a reachable recipient.**"
assert_contains "P4a …with the mechanism that makes it checkable"          "$doc" \
    "no silent-accept path"
assert_contains "P4a …and the retraction it corrects"                      "$doc" \
    "manufactured success was wrong"
assert_contains "P4b the reachable set is WIDER than the roster"           "$doc" \
    "**The reachable set is WIDER than the system-reminder roster.**"
assert_contains "P4b …so roster absence is not non-existence"              "$doc" \
    "is **not** evidence of non-existence"
assert_contains "P4c existence is separated from arrival"                  "$doc" \
    "**Existence validation at send time is NOT a delivery receipt.**"

# ── §3  POTENCY — every assertion above must be able to FAIL ────────────
#
# Mutate a COPY of the contract and re-run the SAME predicate. A control that
# never invokes the check is not a control (three inert ones were found on this
# board, one in a test named `is_POTENT`), so each arm below builds the
# offending document, runs the assertion's own comparison, and observes it react.
echo '=== §3 potency: the checks react to a contract that lost the property ==='

_probe() {   # <mutated-doc> <needle> -> hit|miss
    [[ "$1" == *"$2"* ]] && printf hit || printf miss
}

# 3a — the section deleted outright.
_m_gone=$(printf '%s\n' "$doc" | sed '/^### `none` is not "fast and silent"/,/^## 3\. The common ledger/d')
assert_eq "POTENCY 3a: deleting the section is DETECTED" \
    "$(_probe "$_m_gone" '### `none` is not "fast and silent" — it is ASYNCHRONOUS')" "miss"
# …and the same mutant must leave the receipt table alone, or 3a would be
# passing because it deleted the whole file.
assert_eq "POTENCY 3a CONTROL: the receipt table survives that deletion" \
    "$(_probe "$_m_gone" '| `none` | the transport can produce no evidence of arrival |')" "hit"

# 3b — the no-upper-bound caveat softened away, everything else intact. This is
# the realistic edit: a later author tightening prose, not deleting a section.
_m_bound=${doc//"**NO UPPER BOUND IS CLAIMED, and the five minutes must not be read as one.**"/"Delivery is guaranteed within ten minutes."}
assert_eq "POTENCY 3b: losing the no-upper-bound caveat is DETECTED" \
    "$(_probe "$_m_bound" '**NO UPPER BOUND IS CLAIMED, and the five minutes must not be read as one.**')" "miss"
assert_eq "POTENCY 3b: …and the forbidden guarantee is caught by the NEGATIVE check" \
    "$(_probe "$_m_bound" 'delivery is guaranteed within')" "miss"
# The negative check is CASE-SENSITIVE, which is a real limit of a substring
# guard and is recorded rather than papered over: the mutant above writes
# "Delivery is guaranteed within" and the assertion in §1 greps for the
# lower-case spelling. Asserted BOTH ways so nobody reads §1's negative check
# as broader than it is.
assert_eq "POTENCY 3b KNOWN LIMIT: the negative check is case-sensitive" \
    "$(_probe "$_m_bound" 'Delivery is guaranteed within')" "hit"

# 3c — the UNTESTED marking dropped, turning the section into a refutation.
_m_untested=${doc//"UNTESTED. This is not a refutation of the loss claim"/"tested and clean"}
assert_eq "POTENCY 3c: dropping the UNTESTED marking is DETECTED" \
    "$(_probe "$_m_untested" 'This is not a refutation of the loss claim')" "miss"

# 3d — a correction half-copied: the token kept, the polarity gone. The nastiest
# realistic drift, and the one a presence check on `success:true` alone misses.
_m_polarity=${doc//"**\`success:true\` DOES discriminate a reachable recipient.**"/"\`success:true\` says nothing about the recipient."}
assert_eq "POTENCY 3d: an INVERTED correction is DETECTED" \
    "$(_probe "$_m_polarity" '**`success:true` DOES discriminate a reachable recipient.**')" "miss"
assert_eq "POTENCY 3d CONTROL: …and the bare token still appears, so a token check would MISS it" \
    "$(_probe "$_m_polarity" 'success:true')" "hit"

# 3e — the instrument itself. `_probe` decides every arm above; one that always
# said `miss` would certify all four mutants without reading anything.
assert_eq "POTENCY 3e: _probe says hit for text that IS present" \
    "$(_probe "$doc" '### `none` is not "fast and silent" — it is ASYNCHRONOUS')" "hit"
assert_eq "POTENCY 3e: …and miss for text that is not" \
    "$(_probe "$doc" 'this sentence appears nowhere in the contract')" "miss"

# ASSERTION CENSUS — a vanished assertion reddens here rather than shrinking the
# total in silence (your-org/nexus-code#807).
_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
if [[ "$_total" == "$EXPECTED_ASSERTIONS" ]]; then
    printf '  PASS: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS" >&2; _th_fail
fi

th_summary_and_exit
