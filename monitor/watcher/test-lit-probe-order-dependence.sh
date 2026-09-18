#!/usr/bin/env bash
# Regression pin: the relaxation probe MUST NOT certify a zero, and its
# verdict MUST NOT depend on the order the query's terms were typed in
# (your-org/nexus-code#588, PR #596 skeptic review finding F1, #600 item 1).
#
# Run: bash monitor/watcher/test-lit-probe-order-dependence.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE DEFECT BEING PINNED
# -----------------------
# The first draft of the #588 fix decided "genuinely empty" vs
# "over-constrained" with ONE probe: re-run the query's first six WHITESPACE
# TOKENS and see whether they hit. Two structural facts make that a
# corroboration, never a verdict:
#
#   1. Backends AND their terms, so the prefix's result set is a SUPERSET of
#      the full query's. A prefix hit therefore establishes only "the broad
#      topic is populated" — which is also exactly what a genuine, meaningful
#      conjunctive gap inside a populated topic looks like.
#   2. The prefix is POSITIONAL. A conjunction is logically commutative; the
#      probe is not. Re-order the same terms and the verdict flips.
#
# So the same 8-term conjunction, over the same corpus, with the same ground
# truth (a real zero), produced:
#
#   "hedgehog signaling cerebellar granule cell progenitors microgravity spaceflight"
#       -> status error, query_over_constrained, exit 2       (prefix hits)
#   "microgravity spaceflight hedgehog signaling cerebellar granule cell progenitors"
#       -> status ok, count 0, complete true, exit 0, and the literal phrase
#          "this is a genuine zero (confirmed: ...)"          (prefix misses)
#
# The second is the #588 failure mode wearing a badge: a confident, exit-0,
# complete zero on a query the tool cannot actually vouch for — and STRICTLY
# WORSE than the pre-#588 output, which was a bare unlabelled `count: 0`. An
# agent reading "this is a genuine zero (confirmed: ...)" is more likely to
# write "no prior work exists" than one reading a bare zero.
#
# WHAT THIS FILE ASSERTS
# ----------------------
# TWO things, and the second one arrived with the #600 fix:
#
#   1. The honest floor (unchanged, and the reason this file was written):
#      whichever branch a query lands on, the tool states what it OBSERVED and
#      never certifies the zero as genuine / confirmed / verified.
#   2. INVARIANCE: permuting the query's terms changes nothing but the echoed
#      `query` field. Every permutation of a term set produces a byte-identical
#      response, on the zero branch AND on the over-constrained branch, in JSON
#      AND in --human.
#
# Fact 1 in the list above is structural and did NOT go away: the fix replaced
# the positional prefix with LEAVE-ONE-OUT over the query's canonical content-
# term SET (`_probe_terms` in lit.sh), so the relaxation is a set function.
# A drop's result set is still a superset of the full query's, so a probe hit
# still cannot certify anything about the conjunction — it only names the term
# whose removal recovers hits. Assertion group 1 is therefore untouched by the
# redesign, which is exactly why it was written to be independent of it.
#
# COVERAGE BOUNDARY (what "invariant" is established over, and what it is not)
# --------------------------------------------------------------------------
# Established here: invariance under PERMUTATION of a query's whitespace
# tokens, and under case / surrounding ASCII punctuation / stopword decoration
# of those tokens, for the zero-result path (`probe.state` empty | hits |
# not_run) on a single backend. Each axis is pinned where it is OBSERVABLE:
# permutation and punctuation/stopwords on the zero branch, CASE on the hits
# branch, because an `empty` response carries `dropped_term: null, query: null`
# and cannot witness a change in drop ORDER at all. Every axis is
# mutation-checked — revert the mechanism, and the assertion for it fails.
#
# NOT established, in four specific senses:
#   * COMPLETENESS. The probe is capped at `LIT_PROBE_MAX_DROPS`, so a hit
#     reachable only by dropping a term that sorts after the cap is missed.
#     That miss is itself invariant (the cap consumes the same terms whatever
#     the input order) and fails safe (the hedged zero, not a confident one),
#     and `probe.drops_tried` / `probe.content_terms` report the coverage
#     achieved. Proved to be a CAP, not a residual order effect, by raising it.
#   * ATTRIBUTION. `probe.dropped_term` names the term whose removal recovered
#     hits from the query REDUCED to its content terms — not from the query as
#     the caller wrote it. The reduction differs from the caller's query in two
#     ways that can each recover hits ON THEIR OWN, and neither is curable by
#     disclosure, because the disclosed sentence would itself be false:
#       - QUOTES. The reduction un-quotes a phrase, which is strictly broader,
#         so ANY drop hits. A query containing a double quote is refused.
#       - STOPWORDS. When a stopword was binding, the reduction alone already
#         hits and the first drop hits trivially. A DROP-ZERO BASELINE runs
#         first; if it hits, the verdict is `reduction_recovered` and NO term
#         is named. Measured before that existed: `… medulloblastoma without`
#         was blamed on "cell", which is not binding (skeptic delta D2).
#     What remains outside the boundary: the reduction also lowercases and
#     dedupes, and those are not separately probed — they are subsumed by the
#     baseline (if either recovers hits alone, the baseline hits and no term is
#     named), but they are not attributed individually.
#   * NON-ASCII CASE FOLDING. `tolower` in awk is locale-dependent for
#     multi-byte letters, so `Мозг` and `мозг` dedupe under a UTF-8 locale and
#     not under LC_ALL=C. Terms SURVIVE either way (that is what is pinned
#     below); their case folding does not. ASCII case folding is invariant.
#     Non-ASCII punctuation is trimmed only when it stands alone as its own
#     token (`LIT_PROBE_UPUNCT`); `“hedgehog` glued together survives as a term.
#   * RESULT ORDERING of a non-empty result set — the backends' relevance
#     ranking, not this probe's business.
#
# WHY A SECOND FIXTURE
# --------------------
# `test-lit-empty-vs-failed.sh` models a hit as a word-count ceiling, which
# makes "over-constrained" and "genuinely empty" perfectly separable BY
# CONSTRUCTION — the fixture assumes the very discrimination the probe is
# claimed to perform, so it cannot expose F1. A word-count model is also
# permutation-invariant on its own, so it cannot see order either. The stub
# here does true CONJUNCTIVE matching over a corpus (a paper hits iff it
# contains EVERY query term) with no word-count modelling at all. That
# difference is the whole point; do not merge the two files.
#
# NEGATIVE CONTROLS
# -----------------
# A guard never observed to fail is not evidence. Six controls run on every
# invocation, at the bottom of this file, and each is checked for the EXPECTED
# failure MESSAGE, not merely a non-zero exit:
#
#   claim guard (`assert_no_claim`)
#     A. fed the verbatim pre-fix summary; must FAIL;
#     B. a copy of `lit.sh` reverted to the pre-fix WORDING, run end to end;
#        the guard must FAIL on its real output.
#
#   invariance predicate (`assert_same_verdict`)
#     C. fed two responses whose term SETS differ (one word swapped, which
#        moves the query to the over-constrained branch); must FAIL, proving
#        the equality is discriminating and not "everything looks alike now".
#     D. a copy of `lit.sh` with the canonicalising SORT removed, run end to
#        end on a permuted pair; must FAIL — the sort is what produces the
#        invariance, so deleting it must bring the divergence back.
#     E. the same, for the LOWERCASING, on a capitalisation-only pair. Its
#        own control because the sort and the lowercasing are separate
#        mechanisms on separate axes, and D cannot see the case one.
#
#   attribution guard (`assert_no_claim`, the second needle family)
#     F. a copy of `lit.sh` whose scoping clause is replaced by the bare
#        causal claim — "The term X is why your query returned nothing" —
#        run end to end; the guard must FAIL on its real output.
#
# D, E and F are the load-bearing ones. Without D/E, "the two orderings agree"
# is also what you would see from a probe that never fires — and the suite did
# in fact report 135/0 against a copy with the lowercasing deleted before E
# existed. Without F, the softened wording shipped in a string NOTHING
# asserted: the same mutation left the suite at 160/0. Each of the three
# consumes the LIVE binary, not a fixture's copy of a format string; that is
# the property, and re-stating the message format here would be the proxy.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIT="$_test_dir/../lit.sh"

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
        printf '  FAIL: %s — expected to find: %s\n' "$label" "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found: %s\n' "$label" "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}
assert_jq() {
    local label="$1" json="$2" filter="$3" want="$4"
    local got; got=$(jq -r "$filter" <<<"$json" 2>/dev/null)
    assert_eq "$label" "$got" "$want"
}

# ---- the invariance predicate -----------------------------------------
# Two responses are the SAME VERDICT iff they are byte-identical once `query`
# is removed. `query` is the ONE field that legitimately differs between two
# orderings — it echoes the caller's wording back — so deleting it is what
# makes the comparison about the VERDICT rather than about the input. Nothing
# else is normalised away: status, exit-relevant fields, the whole `probe`
# object, and every word of `summary` must match exactly.
_verdict() { jq -S 'del(.query)' <<<"${1:-}" 2>/dev/null; }

assert_same_verdict() {
    local label="$1" a="$2" b="$3"
    local va vb; va=$(_verdict "$a"); vb=$(_verdict "$b")
    # An empty $va means jq could not parse — two unparseable blobs must not
    # compare equal and silently "pass".
    if [[ -n "$va" && "$va" == "$vb" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — verdict differs\n' "$label" >&2
        diff <(printf '%s\n' "$va") <(printf '%s\n' "$vb") | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- the guard --------------------------------------------------------
# Every phrase that turns a REPORTED zero into a CERTIFIED one. Matched
# literally (grep -F), case-sensitively, against the whole rendered response.
#
# Deliberately NOT banned: the bare word "verified" — the softened summary
# says "not a verified absence", and a guard that forbade its own remedy
# would be unfixable. The needles below are the CLAIMS, not their negations.
#
# TWO families, and the second was missing for a whole review round. The
# ZERO-CERTIFICATION family (`#588`) is what this file was written for. The
# ATTRIBUTION family (`#600`/D1) is what the leave-one-out probe made possible:
# a probe that NAMES a term can claim that term CAUSED the zero, which is a
# different over-claim with the same shape. With only the first family present,
# the scoping clause in `lit.sh` was replaceable by the bare causal claim
# — "The term X is why your query returned nothing" — and this suite reported
# 160 passed, 0 failed (skeptic delta D1).
#
# A DENIAL LIST, not an assertion on today's exact sentence. Asserting the
# current wording pins a format string; these pin the class, so a wording
# nobody enumerated is still caught. Negative control F ships the exact
# mutation that exposed the gap.
CLAIM_NEEDLES=(
    # zero-certification
    'genuine zero'
    '(confirmed:'
    'NOT an empty literature'
    'is a genuine'
    'verified absence of'
    # attribution — a named term presented as the CAUSE
    'is why your query'
    'is why you got'
    'is the reason your query'
    'is the reason you got'
    'is what made your query'
    'is responsible for this zero'
    'caused your query to'
)

# assert_no_claim <label-prefix> <text>
assert_no_claim() {
    local label="$1" text="$2" needle
    for needle in "${CLAIM_NEEDLES[@]}"; do
        assert_not_contains "$label makes no \"$needle\" claim" "$text" "$needle"
    done
}

# ---- harness ----------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

# The corpus. Two papers, deliberately DISJOINT in subject: hedgehog /
# cerebellar-progenitor work, and microgravity / spaceflight work. Nothing
# combines them, so every query below has the SAME ground truth — a real,
# scientifically meaningful zero for the conjunction, inside a topic area
# that is demonstrably populated.
cat > "$WORK/corpus.txt" <<'EOF'
hedgehog signaling in cerebellar granule cell progenitors drives medulloblastoma transcriptomics
microgravity spaceflight effects on murine bone density
EOF

# Mock OpenAlex with TRUE CONJUNCTIVE SEMANTICS: a paper hits iff it contains
# EVERY query term. No word-count modelling — that is what separates this
# fixture from test-lit-empty-vs-failed.sh's.
CURL_LOG="$WORK/curl.log"
: > "$CURL_LOG"

cat > "$STUB_DIR/curl" <<CURLSTUB
#!/usr/bin/env bash
WORK="$WORK"
CURL_LOG="$CURL_LOG"
argv=("\$@")
url=""
for a in "\${argv[@]}"; do case "\$a" in http*://*) url="\$a" ;; esac; done
q=""
for a in "\${argv[@]}"; do case "\$a" in search=*) q="\${a#search=}" ;; esac; done
printf '%s :: %s\n' "\$url" "\$q" >> "\$CURL_LOG"

nhit=\$(awk -v q="\$q" '
  BEGIN { n = split(tolower(q), t, /[ ]+/) }
  { l = tolower(\$0); ok = 1
    for (i = 1; i <= n; i++) if (t[i] != "" && index(l, t[i]) == 0) { ok = 0; break }
    if (ok) c++ }
  END { print c + 0 }' "\$WORK/corpus.txt")

if [[ \$nhit -eq 0 ]]; then
    printf '%s' '{"meta":{"count":0},"results":[]}'
else
    printf '{"meta":{"count":%s},"results":[{"id":"https://openalex.org/W1","doi":"https://doi.org/10.1/a","display_name":"a matching paper","title":"a matching paper","publication_year":2022,"primary_location":{"source":{"display_name":"J Test"},"landing_page_url":"https://example.org/1"},"authorships":[{"author":{"display_name":"A Author"}}],"cited_by_count":3}]}' "\$nhit"
fi
CURLSTUB
chmod +x "$STUB_DIR/curl"

CFG="$WORK/cfg.yml"
cat > "$CFG" <<'EOF'
lit:
  s2_api_key: ""
  asta_api_key: ""
  openalex_mailto: "tester@example.org"
EOF

LIBDIR="$WORK/lib"
mkdir -p "$LIBDIR/.bipartite"
: > "$LIBDIR/.bipartite/refs.jsonl"

# Usage: run_lit <out-var> <rc-var> <lit-path> <args...>
# Truncates the curl log first and leaves this run's backend-call count in
# LAST_CALLS, so request cost is a per-run assertion instead of a running
# total nobody can re-derive after the fact.
LAST_CALLS=0
run_lit() {
    local _out_var="$1" _rc_var="$2" _lit="$3"; shift 3
    local _rc _tmp; _tmp=$(mktemp)
    : > "$CURL_LOG"
    env -u S2_API_KEY -u ASTA_API_KEY \
        NEXUS_CONFIG="$CFG" NEXUS_ROOT="$LIBDIR" LIT_PROBE_DELAY_SECS=0 \
        PATH="$STUB_DIR:$PATH" \
        "$_lit" "$@" >"$_tmp" 2>/dev/null
    _rc=$?
    printf -v "$_out_var" '%s' "$(<"$_tmp")"
    printf -v "$_rc_var" '%s' "$_rc"
    LAST_CALLS=$(grep -c 'api.openalex.org' "$CURL_LOG")
    rm -f "$_tmp"
}

# ---- the counter-example, verbatim ------------------------------------
# The SAME EIGHT TERMS in two orders. Lifted unchanged from the PR #596
# skeptic report; do not "tidy" them — the defect is positional, so the exact
# word order is the test. ORDER_A puts the discriminating pair (microgravity
# spaceflight) at positions 7-8, outside the 6-word prefix; ORDER_B puts it
# at 1-2, inside it. Ground truth for both: a genuine zero.
ORDER_A="hedgehog signaling cerebellar granule cell progenitors microgravity spaceflight"
ORDER_B="microgravity spaceflight hedgehog signaling cerebellar granule cell progenitors"
# A third permutation, so "invariant" is pinned over a family rather than over
# the single pair the bug report happened to contain.
ORDER_C="granule progenitors spaceflight signaling cell hedgehog cerebellar microgravity"
# The same eight terms wearing case, punctuation and stopwords. Not an
# ordering — a NORMALISATION axis — and pinned because `_probe_terms` is what
# establishes both, so a regression in it would break both together.
ORDER_D="Hedgehog, signaling in the CEREBELLAR granule cell (progenitors) — microgravity: spaceflight."
# The same scientific question in six content terms — below
# LIT_PROBE_MIN_TERMS, so no probe runs at all and the zero is reported
# entirely uncorroborated.
SHORT_Q="hedgehog cerebellar progenitors microgravity spaceflight transcriptomics"
# Same length as ORDER_A/B/C, but a DIFFERENT term set: `bone` replaces the
# hedgehog-side pair, and dropping it alone recovers paper 1. The verdict here
# SHOULD differ from ORDER_A's — that is what makes the equality assertions
# above it non-vacuous, and it is the fixture for negative control C.
NEG_CTL="bone hedgehog signaling cerebellar granule cell progenitors"
NEG_CTL_PERM="progenitors granule bone cell signaling hedgehog cerebellar"

# =========================================================================
printf '\n== INVARIANCE: permuting the terms changes nothing but the echo ==\n'
# =========================================================================
# This section replaced the one that pinned the order-dependent SPLIT (the
# open defect at the time this file was written; your-org/nexus-code#600).
# Everything below the "no ordering certifies a zero" header is unchanged —
# that group was written to be independent of which branch a query lands on,
# so the redesign did not touch it.
run_lit out rc "$LIT" search "$ORDER_A" --source openalex --limit 5
ORDER_A_OUT="$out"; A_CALLS="$LAST_CALLS"
assert_eq "ordering A exits 0"                         "$rc" "0"
assert_jq "ordering A: status ok"                      "$out" '.status'   "ok"
assert_jq "ordering A: count 0"                        "$out" '.count'    "0"

run_lit out rc "$LIT" search "$ORDER_B" --source openalex --limit 5
ORDER_B_OUT="$out"; B_CALLS="$LAST_CALLS"
assert_eq "ordering B exits 0"                         "$rc" "0"
assert_jq "ordering B: status ok"                      "$out" '.status'   "ok"
assert_jq "ordering B: count 0"                        "$out" '.count'    "0"

run_lit out rc "$LIT" search "$ORDER_C" --source openalex --limit 5
ORDER_C_OUT="$out"; C_CALLS="$LAST_CALLS"
run_lit out rc "$LIT" search "$ORDER_D" --source openalex --limit 5
ORDER_D_OUT="$out"

# THE #600 ASSERTION. Not "both are zeros" — byte equality of the whole
# response object minus the echoed query.
assert_same_verdict "A vs B: same verdict"             "$ORDER_A_OUT" "$ORDER_B_OUT"
assert_same_verdict "A vs C: same verdict"             "$ORDER_A_OUT" "$ORDER_C_OUT"
assert_same_verdict "B vs C: same verdict"             "$ORDER_B_OUT" "$ORDER_C_OUT"
assert_same_verdict "A vs D: case/punctuation/stopwords change nothing" \
                    "$ORDER_A_OUT" "$ORDER_D_OUT"

# Cost is invariant too. A probe count that moved with the ordering would mean
# the probe was still consuming the query positionally even if the verdict
# happened to agree.
assert_eq "ordering A and B cost the same"             "$A_CALLS" "$B_CALLS"
assert_eq "ordering A and C cost the same"             "$A_CALLS" "$C_CALLS"
# 1 search + 1 drop-zero BASELINE + LIT_PROBE_MAX_DROPS leave-one-out probes.
# 8 content terms, so the cap (6) binds — this is the capped path from the
# coverage boundary above, exercised on every run rather than assumed. The
# baseline is what makes any named term trustworthy (skeptic delta D2); it is
# counted here so its cost is visible rather than folded into "the probe".
assert_eq "zero-result search costs 1 + baseline + capped drops"  "$A_CALLS" "8"
assert_jq "probe reports the term count"               "$ORDER_A_OUT" '.probe.content_terms' "8"
assert_jq "probe reports the coverage achieved"        "$ORDER_A_OUT" '.probe.drops_tried'   "6"
assert_jq "probe names its cap"                        "$ORDER_A_OUT" '.probe.max_drops'     "6"
assert_jq "probe state is empty, not a verdict"        "$ORDER_A_OUT" '.probe.state'         "empty"

# --human is a second rendering of the same state and must be invariant too.
run_lit out rc "$LIT" search "$ORDER_A" --source openalex --limit 5 --human
HUMAN_A="$out"
run_lit out rc "$LIT" search "$ORDER_B" --source openalex --limit 5 --human
assert_eq "human rendering is order-invariant"         "$HUMAN_A" "$out"

run_lit out rc "$LIT" search "$SHORT_Q" --source openalex --limit 5
SHORT_OUT="$out"
assert_eq "6-term query exits 0"                       "$rc" "0"
assert_jq "6-term query: status ok"                    "$out" '.status' "ok"
assert_jq "6-term query: count 0"                      "$out" '.count'  "0"

# Below the probe threshold: exactly one backend call, so its zero rests on
# nothing but itself. That is why it must be the most hedged of the three,
# not the least.
assert_eq "6-term query ran no probe"                  "$LAST_CALLS" "1"
assert_jq "6-term query: probe state not_run"          "$out" '.probe.state' "not_run"

# =========================================================================
printf '\n== the over-constrained branch, and it is invariant too ==\n'
# =========================================================================
# A query whose verdict SHOULD differ, and does. Dropping one term — `bone` —
# recovers paper 1, so this lands on the error branch. Without this the
# equality assertions above would be satisfied by a probe that had simply
# stopped discriminating.
run_lit out rc "$LIT" search "$NEG_CTL" --source openalex --limit 5
NEG_CTL_OUT="$out"
assert_eq "over-constrained query exits 2"             "$rc" "2"
assert_jq "over-constrained: status error"             "$out" '.status'     "error"
assert_jq "over-constrained: kind"                     "$out" '.error.kind' "query_over_constrained"
assert_jq "over-constrained: names the binding term"   "$out" '.probe.dropped_term' "bone"
assert_jq "over-constrained: probe state hits"         "$out" '.probe.state'        "hits"
# Early exit: the baseline misses (so a named term is meaningful), then `bone`
# sorts first and ONE drop settles it. A probe that kept going after a hit
# would be spending requests for no additional evidence.
assert_eq "hit ends the probe immediately"             "$LAST_CALLS" "3"
assert_contains "over-constrained hedges the inference" \
                "$out" "MAY reflect an over-specific query"
assert_contains "over-constrained states the evidence" \
                "$out" "returned 1 hit(s) on openalex"
# The remedy is the CLOSEST query to the one asked that hits — every term but
# the binding one — not a broader topic that answers a different question
# (your-org/nexus-code#600 item 4). Read out of the field rather than grepped
# out of the rendered JSON, where the quotes are backslash-escaped.
assert_contains "remedy names the term to drop" \
                "$(jq -r '.error.remedy' <<<"$out")" 'Search again without "bone"'
assert_contains "remedy offers the near-query itself" \
                "$(jq -r '.error.remedy' <<<"$out")" \
                '"cell cerebellar granule hedgehog progenitors signaling"'
assert_no_claim "over-constrained branch" "$out"

run_lit out rc "$LIT" search "$NEG_CTL_PERM" --source openalex --limit 5
assert_same_verdict "the error branch is order-invariant too" \
                    "$NEG_CTL_OUT" "$out"

# CASE lives HERE, not on the zero branch, and the difference is not stylistic.
# An `empty` response carries `dropped_term: null, query: null`, so two
# different DROP ORDERS are byte-identical there — `A vs D` above cannot see a
# case regression at all. Verified by mutation (skeptic req-001 Q1): deleting
# `tolower` from `_probe_terms` passes the ENTIRE suite without the assertion
# below, while flipping a capitalisation-only pair from `ok`/`empty` to
# `error`/`hits` (LC_ALL=C sorts `S` before every lowercase letter, so a
# capitalised term jumps to index 0 and lands inside the cap).
#
# `A vs D` catches the punctuation and stopword axes only INCIDENTALLY, via
# `probe.content_terms` (8 vs 9, 8 vs 10). A case change preserves the count,
# so nothing else in the file witnesses it.
NEG_CTL_CASE="Bone HEDGEHOG signaling Cerebellar granule cell progenitors"
run_lit out rc "$LIT" search "$NEG_CTL_CASE" --source openalex --limit 5
assert_same_verdict "case-only variant: same verdict (hits branch)" \
                    "$NEG_CTL_OUT" "$out"
assert_jq "case-only variant still names the lowercased term" \
          "$out" '.probe.dropped_term' "bone"

run_lit out rc "$LIT" search "$NEG_CTL" --source openalex --limit 5 --human
assert_no_claim "over-constrained (--human)" "$out"
assert_contains "human error is loud" "$out" "SEARCH FAILED"

# =========================================================================
printf '\n== THE INVARIANT: no ordering certifies the zero ==\n'
# =========================================================================
assert_no_claim "ordering A" "$ORDER_A_OUT"
assert_no_claim "ordering B" "$ORDER_B_OUT"
assert_no_claim "ordering C" "$ORDER_C_OUT"
assert_no_claim "6-term unprobed zero" "$SHORT_OUT"

# The hedged wording is present, not merely the confident wording absent —
# otherwise deleting the summary entirely would pass.
assert_contains "ordering A reports the observation, not a verdict" \
                "$ORDER_A_OUT" "treat this as an observation, not a verified absence"
assert_contains "ordering B reports the observation, not a verdict" \
                "$ORDER_B_OUT" "treat this as an observation, not a verified absence"
assert_contains "ordering B names the probe result" \
                "$ORDER_B_OUT" "also matched nothing on openalex"
# The probe is capped, so the zero branch must say how much of the term set it
# actually tried. "Every drop failed" and "the six drops I got to failed" are
# different claims (your-org/nexus-code#600, coverage boundary).
assert_contains "zero branch discloses its coverage" \
                "$ORDER_B_OUT" "(6 of 8 content terms)"
assert_contains "6-term zero discloses that no check ran" \
                "$SHORT_OUT" "no shortened-query check was run"

# --human must not smuggle the claim back in: it is a second rendering of the
# same state, and the original #588 defect lived in the human view.
run_lit out rc "$LIT" search "$ORDER_B" --source openalex --limit 5 --human
assert_no_claim "ordering B (--human)" "$out"
assert_contains "human zero still carries the caveat" "$out" "not a verified absence"
run_lit out rc "$LIT" search "$ORDER_A" --source openalex --limit 5 --human
assert_no_claim "ordering A (--human)" "$out"
assert_contains "human zero discloses the probe" "$out" "also matched nothing on openalex"

# =========================================================================
printf '\n== negative control A: the guard fires on the pre-fix text ==\n'
# =========================================================================
# The exact string the pre-fix tree emitted for ORDER_B (PR #596 skeptic
# report, finding F1). Fed straight to the guard predicate.
PREFIX_SUMMARY='0 results. All requested backends (openalex) were searched successfully and none matched — this is a genuine zero (confirmed: a shortened form of the query, "microgravity spaceflight hedgehog signaling cerebellar granule", also matched nothing on openalex).'

# Run in a SUBSHELL so its PASS/FAIL mutations are discarded and only the
# emitted text is inspected.
NC_A=$( assert_no_claim "control-A" "$PREFIX_SUMMARY" 2>&1 )
assert_contains "control A: guard FAILS on pre-fix text" \
                "$NC_A" 'FAIL: control-A makes no "genuine zero" claim'
assert_contains "control A: fails for the RIGHT reason" \
                "$NC_A" 'unexpectedly found: genuine zero'
assert_contains "control A: also catches the corroboration badge" \
                "$NC_A" 'unexpectedly found: (confirmed:'
assert_not_contains "control A: guard did not merely pass everything" \
                "$NC_A" 'PASS: control-A makes no "genuine zero" claim'

# =========================================================================
printf '\n== negative control B: the guard fires on an UN-SOFTENED lit.sh ==\n'
# =========================================================================
# Control A proves the predicate discriminates. Control B proves it
# discriminates END TO END, against a real binary that re-asserts the claim.
# A copy of lit.sh is reverted to the pre-fix wording and run for real.
UNSOFT="$WORK/lit-unsoftened.sh"
sed 's/\. Every backend ANDs the query terms.*not a verified absence\."/ — this is a genuine zero (confirmed: a shortened form of the query also matched nothing)."/' \
    "$LIT" > "$UNSOFT"
chmod +x "$UNSOFT"

# The revert must have APPLIED. If lit.sh's summary is reworded and this sed
# silently no-ops, the control below would "pass" against softened code and
# prove nothing — so failing here is the correct, loud outcome. Fix: re-anchor
# the sed above on the new wording.
assert_eq "control B: revert applied to the copy" \
          "$(grep -cF 'this is a genuine zero (confirmed: a shortened form of the query also matched nothing)' "$UNSOFT")" \
          "1"

run_lit unsoft_out unsoft_rc "$UNSOFT" search "$ORDER_B" --source openalex --limit 5
# The reverted copy must still be a WORKING script — otherwise the guard
# would be "failing" on a syntax error rather than on the claim.
assert_eq "control B: reverted copy still exits 0"    "$unsoft_rc" "0"
assert_jq "control B: reverted copy still emits JSON" "$unsoft_out" '.status' "ok"
assert_jq "control B: reverted copy still counts 0"   "$unsoft_out" '.count'  "0"
assert_contains "control B: reverted copy re-asserts the claim" \
                "$unsoft_out" "this is a genuine zero"

NC_B=$( assert_no_claim "control-B" "$unsoft_out" 2>&1 )
assert_contains "control B: guard FAILS on the un-softened binary" \
                "$NC_B" 'FAIL: control-B makes no "genuine zero" claim'
assert_contains "control B: fails for the RIGHT reason" \
                "$NC_B" 'unexpectedly found: genuine zero'
assert_not_contains "control B: guard did not merely pass everything" \
                "$NC_B" 'PASS: control-B makes no "genuine zero" claim'

# =========================================================================
printf '\n== negative control C: the invariance predicate discriminates ==\n'
# =========================================================================
# Byte equality is worthless as evidence if everything compares equal. Feed it
# two responses that SHOULD differ — same eight-ish length, one term swapped,
# and therefore the other branch — and it must FAIL, naming the difference.
NC_C=$( assert_same_verdict "control-C" "$ORDER_A_OUT" "$NEG_CTL_OUT" 2>&1 )
assert_contains "control C: predicate FAILS on a different term set" \
                "$NC_C" 'FAIL: control-C — verdict differs'
assert_contains "control C: fails for the RIGHT reason (branch differs)" \
                "$NC_C" '"status": "error"'
assert_contains "control C: the diff names the probe verdict" \
                "$NC_C" '"state": "hits"'
assert_not_contains "control C: did not merely pass everything" \
                "$NC_C" 'PASS: control-C'

# A predicate that only ever sees valid JSON is also untested against the
# shape it will actually meet on a crash: nothing at all.
NC_C2=$( assert_same_verdict "control-C2" "" "" 2>&1 )
assert_contains "control C: two unparseable blobs are NOT equal" \
                "$NC_C2" 'FAIL: control-C2 — verdict differs'

# =========================================================================
printf '\n== negative control D: order-dependence returns without the sort ==\n'
# =========================================================================
# Controls A-C exercise the predicates. This one exercises the FIX: the single
# canonicalising sort in `_probe_terms` is what makes leave-one-out a set
# function. Delete it and the probe consumes the terms in typed order again,
# so a capped probe reaches a different drop depending on the wording.
#
# The pair below is chosen for the CAP, not for the sort's own effect: eight
# content terms, one binding (`spaceflight`, whose removal recovers paper 1),
# and it sorts LAST — past LIT_PROBE_MAX_DROPS. Canonically it is never
# reached, so both orderings agree on the hedged zero (the documented,
# fail-safe coverage limit). Positionally it is reached in one ordering and
# not the other — the #600 defect, reproduced end to end.
CAP_A="cell cerebellar granule hedgehog medulloblastoma progenitors signaling spaceflight"
CAP_B="spaceflight cell cerebellar granule hedgehog medulloblastoma progenitors signaling"

DECANON="$WORK/lit-decanonicalised.sh"
sed 's/| LC_ALL=C sort -u/| cat/' "$LIT" > "$DECANON"
chmod +x "$DECANON"

# Both halves of the revert are asserted. If lit.sh's canonicalisation is
# rewritten and this sed silently no-ops, the control below would compare a
# still-canonical binary against itself, "pass", and prove nothing — so
# failing here is the correct, loud outcome. Fix: re-anchor the sed.
# _occurrences <pattern> <file> — OCCURRENCES, not lines (your-org/nexus-code
# `#1026`). `grep -c` counts matching LINES, so two constructs sharing one line
# read as 1 and an `== N` assertion stays green with the construct duplicated.
# `-F` because every caller passes a LITERAL. On no match grep prints nothing
# and exits 1, yielding 0 — a replacement, never an appended second value, so
# no `|| echo 0` belongs here (your-org/nexus-code#725).
_occurrences() { grep -oF -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }

assert_eq "control D: lit.sh has exactly one canonicalising sort" \
          "$(_occurrences '| LC_ALL=C sort -u' "$LIT")" "1"
assert_eq "control D: the copy has none" \
          "$(grep -cF '| LC_ALL=C sort -u' "$DECANON")" "0"

# The real binary: invariant on this pair (both hedged zeros, cap not reached).
run_lit cap_a_out cap_a_rc "$LIT" search "$CAP_A" --source openalex --limit 5
run_lit cap_b_out cap_b_rc "$LIT" search "$CAP_B" --source openalex --limit 5
assert_same_verdict "control D: lit.sh agrees on the capped pair" \
                    "$cap_a_out" "$cap_b_out"
assert_jq "control D: and it is the fail-safe hedged zero" "$cap_a_out" '.status' "ok"
assert_jq "control D: the missed drop is disclosed as coverage" \
          "$cap_a_out" '.probe.drops_tried' "6"

# The de-canonicalised copy: still a WORKING script, and it diverges.
run_lit dec_a_out dec_a_rc "$DECANON" search "$CAP_A" --source openalex --limit 5
run_lit dec_b_out dec_b_rc "$DECANON" search "$CAP_B" --source openalex --limit 5
assert_eq "control D: de-canonicalised copy still runs (A)"  "$dec_a_rc" "0"
assert_jq "control D: de-canonicalised copy emits JSON (A)"  "$dec_a_out" '.status' "ok"
assert_eq "control D: de-canonicalised copy still runs (B)"  "$dec_b_rc" "2"
assert_jq "control D: and B lands on the OTHER branch"       "$dec_b_out" '.error.kind' \
          "query_over_constrained"

NC_D=$( assert_same_verdict "control-D" "$dec_a_out" "$dec_b_out" 2>&1 )
assert_contains "control D: predicate FAILS without the sort" \
                "$NC_D" 'FAIL: control-D — verdict differs'
assert_contains "control D: fails for the RIGHT reason (the same terms, re-ordered, flip the branch)" \
                "$NC_D" 'query_over_constrained'
assert_not_contains "control D: did not merely pass everything" \
                "$NC_D" 'PASS: control-D'

# =========================================================================
printf '\n== negative control E: the case axis returns without tolower ==\n'
# =========================================================================
# Control D does this for the SORT. The case axis needs its own, and needed it
# badly: the suite once reported 135/0 against a copy of lit.sh with the
# lowercasing deleted, while that copy flipped a capitalisation-only pair from
# `ok`/`empty` to `error`/`hits`. A 135-assertion suite blind to the
# transformation it exists to pin is an instrument reporting green for a
# property it never measures (skeptic req-001 Q1). Verified by hand once is not
# enough — encoded here, it is re-verified on every run.
DECASE="$WORK/lit-decased.sh"
sed 's/t = tolower(\$i)/t = $i/' "$LIT" > "$DECASE"
chmod +x "$DECASE"

assert_eq "control E: lit.sh lowercases exactly once" \
          "$(_occurrences 't = tolower($i)' "$LIT")" "1"
assert_eq "control E: the copy does not" \
          "$(grep -cF 't = tolower($i)' "$DECASE")" "0"

run_lit dc_a_out dc_a_rc "$DECASE" search "$NEG_CTL"      --source openalex --limit 5
run_lit dc_b_out dc_b_rc "$DECASE" search "$NEG_CTL_CASE" --source openalex --limit 5
# Still a WORKING script, so the divergence below is the claim and not a crash.
assert_eq "control E: de-cased copy still runs (lowercase)"  "$dc_a_rc" "2"
assert_eq "control E: de-cased copy still runs (capitalised)" "$dc_b_rc" "2"
assert_jq "control E: and it names the CAPITALISED term"     "$dc_b_out" '.probe.dropped_term' "Bone"

NC_E=$( assert_same_verdict "control-E" "$dc_a_out" "$dc_b_out" 2>&1 )
assert_contains "control E: predicate FAILS without tolower" \
                "$NC_E" 'FAIL: control-E — verdict differs'
assert_contains "control E: fails for the RIGHT reason (case changed the culprit)" \
                "$NC_E" '"dropped_term": "Bone"'
assert_not_contains "control E: did not merely pass everything" \
                "$NC_E" 'PASS: control-E'

# =========================================================================
printf '\n== negative control F: the attribution guard fires end to end ==\n'
# =========================================================================
# The scoping clause in lit.sh's over-constrained message shipped in a string
# NOTHING asserted: replacing it with the bare causal claim left this suite at
# 160 passed, 0 failed (skeptic delta D1). The remedy is not a better sentence
# — it is a control that consumes the LIVE expression rather than a fixture's
# copy of the format string. This is that control, and the mutation below is
# the skeptic's own, taken verbatim over the channel rather than rebuilt from
# its description.
CLAIMY="$WORK/lit-claimy.sh"
sed 's/Two limits on that:.*full conjunction has been studied/The term \\"$probe_dropped\\" is why your query returned nothing./' \
    "$LIT" > "$CLAIMY"
chmod +x "$CLAIMY"

# Both halves asserted: if the message is reworded and this sed no-ops, the
# control would run against the SOFTENED binary, pass, and prove nothing.
assert_eq "control F: lit.sh carries the scoping clause once" \
          "$(_occurrences 'Two limits on that:' "$LIT")" "1"
assert_eq "control F: the mutant carries the bare causal claim" \
          "$(_occurrences 'is why your query returned nothing' "$CLAIMY")" "1"

run_lit claimy_out claimy_rc "$CLAIMY" search "$NEG_CTL" --source openalex --limit 5
assert_eq "control F: mutant still runs"        "$claimy_rc" "2"
assert_jq "control F: mutant still emits JSON"  "$claimy_out" '.error.kind' "query_over_constrained"
assert_contains "control F: mutant asserts the causal claim" \
                "$claimy_out" "is why your query returned nothing"

NC_F=$( assert_no_claim "control-F" "$claimy_out" 2>&1 )
assert_contains "control F: guard FAILS on the causal claim" \
                "$NC_F" 'FAIL: control-F makes no "is why your query" claim'
assert_contains "control F: fails for the RIGHT reason" \
                "$NC_F" 'unexpectedly found: is why your query'
assert_not_contains "control F: did not merely pass everything" \
                "$NC_F" 'PASS: control-F makes no "is why your query" claim'

# The guard is a denial list, so it must be paired with a POSITIVE assertion on
# the live message — otherwise deleting the scoping clause outright (rather than
# replacing it with a claim) passes silently.
assert_contains "the shipped message scopes its attribution" \
                "$(jq -r '.error.message' <<<"$NEG_CTL_OUT")" \
                "the probe searched your query REDUCED to its content terms"
assert_contains "…and says what the named term actually established" \
                "$(jq -r '.error.message' <<<"$NEG_CTL_OUT")" \
                "whose removal recovered hits from that reduction"

# =========================================================================
printf '\n== the coverage boundary is a CAP, not a residual order effect ==\n'
# =========================================================================
# CAP_A/CAP_B come out as hedged zeros above because `spaceflight` sorts PAST
# LIT_PROBE_MAX_DROPS and is never tried. Raise the cap over the term count and
# the same pair reaches it — both orderings, identically. That turns the
# "capped, and the miss fails safe" clause of the coverage boundary into a
# measurement instead of a claim about a path nobody ran.
export LIT_PROBE_MAX_DROPS=8
run_lit full_a_out full_a_rc "$LIT" search "$CAP_A" --source openalex --limit 5
FULL_A_CALLS="$LAST_CALLS"
run_lit full_b_out full_b_rc "$LIT" search "$CAP_B" --source openalex --limit 5
unset LIT_PROBE_MAX_DROPS

assert_eq "uncapped: the skipped drop IS reached (A)"  "$full_a_rc" "2"
assert_eq "uncapped: the skipped drop IS reached (B)"  "$full_b_rc" "2"
assert_jq "uncapped: and it names the binding term"    "$full_a_out" '.probe.dropped_term' "spaceflight"
assert_eq "uncapped: it cost 1 search + baseline + 8 drops" "$FULL_A_CALLS" "10"
assert_same_verdict "uncapped: still order-invariant"  "$full_a_out" "$full_b_out"
# And the capped run is the SAFE side of the trade: a missed hit degrades to
# the hedged zero, never to a confident one.
assert_no_claim "capped run (the missed hit)" "$cap_a_out"

# =========================================================================
printf '\n== when the REDUCTION itself recovers, no term is named ==\n'
# =========================================================================
# The probe searches the query reduced to its content terms, which drops
# stopwords too. When a STOPWORD was the binding constraint, the reduction
# alone already hits — and then the first drop hits trivially and an arbitrary
# content term gets named. Measured before the fix: this query was blamed on
# "cell", while dropping "cell" and keeping "without" still returned 0
# (skeptic delta D2). Disclosure could not cure it: the scoped claim "X is the
# term whose removal recovered hits" is false when nothing needed removing.
REDUCTION_Q="hedgehog signaling cerebellar granule cell progenitors medulloblastoma without"
run_lit out rc "$LIT" search "$REDUCTION_Q" --source openalex --limit 5
assert_eq "reduction-recovered: still an error"   "$rc" "2"
assert_jq "reduction-recovered: over-constrained" "$out" '.error.kind' "query_over_constrained"
assert_jq "reduction-recovered: state hits"       "$out" '.probe.state'  "hits"
assert_jq "reduction-recovered: says which way"   "$out" '.probe.reason' "reduction_recovered"
# THE assertion: no culprit, because there is none to name.
assert_jq "reduction-recovered: names NO term"    "$out" '.probe.dropped_term' "null"
assert_jq "reduction-recovered: no drop was tried" "$out" '.probe.drops_tried' "0"
assert_contains "reduction-recovered: says so in words" \
                "$out" "no single content term accounts for this result"
assert_no_claim "reduction-recovered branch" "$out"
# One request, then it settles: the baseline is the FIRST probe, so a query
# whose reduction hits never reaches the drops that would misattribute it.
assert_eq "reduction-recovered costs 1 search + 1 baseline" "$LAST_CALLS" "2"

# The negative half: a query whose reduction does NOT hit must still name its
# binding term. Otherwise "name no culprit" could be satisfied by never naming
# one at all.
assert_jq "a real single-term binding is still named" "$NEG_CTL_OUT" '.probe.dropped_term' "bone"
assert_jq "…and is not filed as a reduction recovery" "$NEG_CTL_OUT" '.probe.reason' "null"

# =========================================================================
printf '\n== a quoted phrase is not probed at all ==\n'
# =========================================================================
# The probe rebuilds its query from content terms, which STRIPS the quotes.
# An un-quoted phrase is a strictly broader search, so on a phrase query ANY
# drop can hit and the tool would name whichever term it happened to try
# first — a confidently wrong culprit, with a remedy that works for the wrong
# reason (skeptic req-001 Q2, reproduced against a phrase-aware stub). It
# declines instead.
run_lit out rc "$LIT" search "\"hedgehog signaling\" cerebellar granule cell progenitors microgravity spaceflight" \
        --source openalex --limit 5
assert_jq "quoted query: probe declines"          "$out" '.probe.state'  "inconclusive"
assert_jq "quoted query: and says why"            "$out" '.probe.reason' "quoted_phrase"
assert_jq "quoted query: names no culprit"        "$out" '.probe.dropped_term' "null"
assert_jq "quoted query: degrades to partial"     "$out" '.status'       "partial"
assert_contains "quoted query: UNVERIFIED, not a zero" "$out" "UNVERIFIED"
assert_no_claim "quoted query" "$out"
assert_eq "quoted query spent no probe request"   "$LAST_CALLS" "1"

# `inconclusive` must not repeat the sin `partial` committed: one state
# standing for several causes with no field to separate them.
run_lit out rc "$LIT" search "$ORDER_A" --source openalex --limit 5
assert_jq "a probed zero carries no reason"       "$out" '.probe.reason' "null"

# =========================================================================
printf '\n== non-ASCII terms survive, whatever the locale ==\n'
# =========================================================================
# `_probe_terms` trims punctuation against an explicit ASCII list rather than
# `[^[:alnum:]]`, which is locale-dependent: under LC_ALL=C that class treats
# every byte of a multi-byte character as non-alphanumeric, so `γδ` was trimmed
# away entirely and `α-synuclein` became `synuclein` — the term SET, and with
# it the LIT_PROBE_MIN_TERMS gate, depended on the environment the tool ran in
# (skeptic req-001, third finding). Greek letters are common in biology, so
# this is not a corner case.
GREEK_Q="γδ tcells thymic selection butyrophilin α-synuclein spaceflight"
_greek_run() {  # $1 = locale
    local _tmp; _tmp=$(mktemp); : > "$CURL_LOG"
    env -u S2_API_KEY -u ASTA_API_KEY LC_ALL="$1" \
        NEXUS_CONFIG="$CFG" NEXUS_ROOT="$LIBDIR" LIT_PROBE_DELAY_SECS=0 \
        PATH="$STUB_DIR:$PATH" \
        "$LIT" search "$GREEK_Q" --source openalex --limit 5 >"$_tmp" 2>/dev/null
    cat "$_tmp"; rm -f "$_tmp"
}
GREEK_C=$(_greek_run C)
# 7 terms, all of them: `γδ` present and `α-synuclein` unmangled. Under the old
# locale-dependent trim this read 6 under LC_ALL=C — BELOW the probe threshold,
# so the zero went uncorroborated purely because of the ambient locale.
assert_jq "LC_ALL=C keeps every content term"  "$GREEK_C" '.probe.content_terms' "7"
assert_jq "LC_ALL=C still probes"              "$GREEK_C" '.probe.state'         "empty"
assert_same_verdict "the locale does not change the verdict" \
                    "$GREEK_C" "$(_greek_run "${LC_ALL:-${LANG:-C}}")"

# =========================================================================
printf '\n== the probe burst is paced (measured: it trips S2 otherwise) ==\n'
# =========================================================================
# Every run above sets LIT_PROBE_DELAY_SECS=0, because the backend is a stub.
# That would leave the pacing itself untested — and the pacing is not cosmetic:
# fired back-to-back against the REAL S2 (2026-07-30) the six drops earn
# `S2: Too Many Requests`, which degrades a would-be clean zero to
# partial/inconclusive. So run the same query once with the delay ON.
#
# One-sided by construction: sleeping can only ADD wall clock, so a loaded
# machine cannot push this below the bound, and a probe that ignored the delay
# finishes in well under a second against the stub. No upper bound is asserted.
_t0=$SECONDS
env -u S2_API_KEY -u ASTA_API_KEY \
    NEXUS_CONFIG="$CFG" NEXUS_ROOT="$LIBDIR" LIT_PROBE_DELAY_SECS=1 \
    PATH="$STUB_DIR:$PATH" \
    "$LIT" search "$ORDER_A" --source openalex --limit 5 >/dev/null 2>&1
_paced=$(( SECONDS - _t0 ))
# 6 drops => 5 inter-drop waits of 1s; the first drop is never delayed.
assert_eq "6 capped drops waited at least 5s" "$(( _paced >= 5 ? 1 : 0 ))" "1"

# =========================================================================
printf '\n== the fix did not turn every zero into an alarm ==\n'
# =========================================================================
# The inverse defect. A hedged zero is still a REPORTED zero: exit 0, status
# ok, no error, no WARNING. Softening the claim must not have escalated it.
assert_jq "hedged zero is still status ok"       "$ORDER_B_OUT" '.status'  "ok"
assert_jq "hedged zero is still not partial"     "$ORDER_B_OUT" '.partial' "false"
assert_jq "hedged zero reports no failed backend" "$ORDER_B_OUT" '.failed_backends|length' "0"
assert_not_contains "hedged zero raises no INCOMPLETE" "$ORDER_B_OUT" "INCOMPLETE"
assert_not_contains "hedged zero is not an error"      "$ORDER_B_OUT" '"status": "error"'

# A query that DOES match must be untouched by any of this.
run_lit out rc "$LIT" search "hedgehog signaling cerebellar" --source openalex --limit 5
assert_eq "a matching query still exits 0"   "$rc" "0"
assert_jq "a matching query: status ok"      "$out" '.status' "ok"
assert_jq "a matching query returns results" "$out" '.count'  "1"
assert_no_claim "a matching query" "$out"

# =========================================================================
printf '\n== TOTAL: %s passed, %s failed ==\n' "$PASS" "$FAIL"
# =========================================================================
# The COUNT is checked, not just the verdict. An assertion whose helper is
# misspelled or deleted exits rc 127 under `set -uo pipefail` without
# incrementing either counter — it is tallied by NOTHING, so a suite can lose
# assertions and still print ALL TESTS PASSED. Raise this floor when you add
# assertions; a drop is a defect, not a tidy-up.
EXPECTED_MIN_ASSERTIONS=260
_total=$(( PASS + FAIL ))
if [[ $_total -lt $EXPECTED_MIN_ASSERTIONS ]]; then
    printf 'ASSERTION COUNT REGRESSED: ran %s, expected at least %s — an assert_* helper likely vanished (rc 127 is counted by nothing)\n' \
           "$_total" "$EXPECTED_MIN_ASSERTIONS" >&2
    exit 1
fi

if [[ $FAIL -eq 0 ]]; then
    printf 'ALL TESTS PASSED (%s assertions)\n' "$PASS"; exit 0
else
    printf '%s TEST(S) FAILED\n' "$FAIL" >&2; exit 1
fi
