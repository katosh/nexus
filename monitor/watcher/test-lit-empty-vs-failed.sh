#!/usr/bin/env bash
# Mock-curl unit tests for `ng lit search` RESULT-STATE reporting
# (your-org/nexus-code#588).
#
# Run: bash monitor/watcher/test-lit-empty-vs-failed.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE DEFECT BEING PINNED
# -----------------------
# `ng lit search` could answer `count: 0` with `partial: false`, no failed
# backends and exit 0 for a query that was merely too long. To an agent that
# is a substantive claim about the world — "no prior work addresses X" — and
# it gets believed and cited. An error is visible and gets retried; a
# confident zero gets believed.
#
# Measured live against the real backends on 2026-07-29, which is what these
# stubs reproduce:
#
#   * S2 answers a zero-hit search with `{"total": 0, "offset": 0}` — NO
#     `data` key at all. Identical shape whether the query is nonsense or
#     merely over-long.
#   * Every backend ANDs the query terms, so an on-topic query going from 7
#     to 22 words walked S2's total 8616 -> 136 -> 21 -> 2 -> 0, HTTP 200
#     throughout. The zero is true of the conjunction and false about the
#     literature. NO response field distinguishes the two cases.
#   * OpenAlex hard-rejects a search string over 1500 characters with HTTP
#     400 `{"error":"Search query too long", ...}`.
#
# Because no response field separates "over-constrained" from "genuinely
# empty", lit.sh resolves it by MEASUREMENT: on a zero-result search it re-runs
# the query with ONE content term dropped, once per term, until something hits
# (your-org/nexus-code#600 replaced the original first-6-words prefix, which
# made the verdict depend on the order the terms were typed in). The stub below
# models a length ceiling — a query of <=11 words matches, a longer one does
# not — so a single-term drop off a 12-word query crosses it and the probe path
# is exercised for real rather than simulated.
#
# The ceiling is 11 rather than 6 BECAUSE the probe now drops one term rather
# than most of them: under the old 6-word model no leave-one-out relaxation of
# a realistic query could ever hit, and every over-constrained case in this
# file would have gone quietly untested while still printing PASS. The number
# is a property of the fixture's model, not of the backends.
#
# THE TWO FAILURE DIRECTIONS, both tested:
#   1. an over-constrained / failed / rejected search reported as a clean 0
#      (the filed bug);
#   2. a genuinely empty search dressed up as an alarm (the same defect
#      wearing the opposite mask, and the reason the negative controls below
#      are not optional).
#
# A query containing the token NOTHINGMATCHES or NOMATCHEITHER matches nothing
# at ANY length — that is how the genuinely-empty-at-long-length control is
# expressed. TWO such tokens, not one: with a single one, dropping it is a
# leave-one-out relaxation that hits, so the probe would correctly call the
# query over-constrained and the "genuine zero" case would evaporate. Matched
# case-insensitively, because the probe lowercases the terms it rebuilds a
# query from and every real backend is case-insensitive too.
#
# WHAT THIS FIXTURE CANNOT SHOW (read before extending it)
# --------------------------------------------------------
# Modelling a hit as a word-count ceiling makes "over-constrained" and
# "genuinely empty" perfectly separable BY CONSTRUCTION — the fixture assumes
# the exact discrimination the probe is claimed to perform. So a green run here
# is evidence about the STATE MACHINE (which status, which exit code, which
# keys are emitted), NOT about whether the probe's inference is sound. It is
# not, in general: a relaxation's result set is a superset of the full query's,
# so a probe hit shows the rest of the conjunction is populated and nothing
# more. Nor does this fixture see ORDER — a word-count model is permutation-
# invariant on its own, so it would print PASS against a probe that was
# entirely positional. Both are pinned separately, over a corpus with true
# conjunctive semantics, by test-lit-probe-order-dependence.sh. Keep the two
# fixtures apart — merging them would re-hide the defect.

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
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found: %s\n' "$label" "$needle" >&2
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

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

# S2 hit payload (shape mirrors the real graph/v1 paper/search response).
cat > "$WORK/s2_hits.json" <<'EOF'
{"total":3063,"offset":0,"data":[{"paperId":"s2a","title":"A benchmark of batch-effect correction methods","year":2020,"venue":"Genome Biology","externalIds":{"DOI":"10.1186/s13059-019-1850-9"},"citationCount":900,"url":"https://example.org/s2a","authors":[{"name":"H Tran"}]}]}
EOF

# THE measured zero-hit S2 body: `total`, `offset`, and NO `data` key.
cat > "$WORK/s2_empty.json" <<'EOF'
{"total": 0, "offset": 0}
EOF

cat > "$WORK/oa_hits.json" <<'EOF'
{"meta":{"count":5678},"results":[{"id":"https://openalex.org/W1","doi":"https://doi.org/10.1038/oa-1","title":"Spatial deconvolution benchmark","display_name":"Spatial deconvolution benchmark","publication_year":2022,"primary_location":{"source":{"display_name":"Nature Methods"},"landing_page_url":"https://example.org/oa1"},"authorships":[{"author":{"display_name":"O Author"}}],"cited_by_count":42}]}
EOF

cat > "$WORK/oa_empty.json" <<'EOF'
{"meta":{"count":0},"results":[]}
EOF

# Real OpenAlex 400 body for an over-length search string.
cat > "$WORK/oa_toolong.json" <<'EOF'
{"error":"Search query too long","error_source":"openalex-api-proxy","message":"Your search is too long (2999 characters; the limit is 1500). Very long pasted-text or Boolean searches are disproportionately expensive."}
EOF

cat > "$WORK/asta_hits.txt" <<'EOF'
data: {"result":{"content":[{"type":"text","text":"{\"paperId\":\"astaA\",\"title\":\"ASTA Result Paper\",\"year\":2021,\"venue\":\"bioRxiv\",\"externalIds\":{\"DOI\":\"10.1101/asta-a\"},\"citationCount\":7,\"url\":\"https://example.org/asta-a\",\"authors\":[{\"name\":\"A Sta\"}]}"}]}}
EOF

cat > "$WORK/asta_empty.txt" <<'EOF'
data: {"result":{"content":[]}}
EOF

# Records every curl invocation, so "the pre-flight spent no request" is an
# assertion rather than an assumption.
CURL_LOG="$WORK/curl.log"
: > "$CURL_LOG"

cat > "$STUB_DIR/curl" <<CURLSTUB
#!/usr/bin/env bash
WORK="$WORK"
CURL_LOG="$CURL_LOG"
argv=("\$@")
joined="\${argv[*]}"
url=""
for a in "\${argv[@]}"; do
    case "\$a" in http*://*) url="\$a" ;; esac
done

# Pull the query out of whichever parameter this backend uses.
q=""
for a in "\${argv[@]}"; do
    case "\$a" in
        query=*)  q="\${a#query=}" ;;
        search=*) q="\${a#search=}" ;;
    esac
done
# ASTA carries it in the JSON body after -d.
if [[ -z "\$q" && "\$joined" == *search_papers_by_relevance* ]]; then
    for i in "\${!argv[@]}"; do
        if [[ "\${argv[\$i]}" == "-d" ]]; then
            q=\$(jq -r '.params.arguments.keyword // ""' <<<"\${argv[\$((i+1))]}" 2>/dev/null)
        fi
    done
fi

printf '%s\n' "\$url :: \$q" >> "\$CURL_LOG"

# Model the MEASURED behaviour of every backend: terms are ANDed, so a query
# of more than 11 words is over-constrained and matches nothing — one term
# fewer, and it hits. A query carrying NOTHINGMATCHES or NOMATCHEITHER matches
# nothing at any length; both markers are matched case-INSENSITIVELY, because
# the probe rebuilds its queries from lowercased terms.
nwords=\$(wc -w <<<"\$q")
qlower=\$(printf '%s' "\$q" | tr '[:upper:]' '[:lower:]')
hit=1
[[ \$nwords -gt 11 ]] && hit=0
[[ "\$qlower" == *nothingmatches* ]] && hit=0
[[ "\$qlower" == *nomatcheither* ]] && hit=0

case "\$url" in
    */api.semanticscholar.org/*)
        if [[ "\${MOCK_S2_FAIL:-0}" == "1" ]]; then
            printf '%s' '{"message":"Too Many Requests.","code":"429"}'; exit 0
        fi
        if [[ \$hit -eq 1 ]]; then cat "\$WORK/s2_hits.json"; else cat "\$WORK/s2_empty.json"; fi
        ;;
    */api.openalex.org/works*)
        if [[ "\${MOCK_OA_TOOLONG:-0}" == "1" ]]; then
            cat "\$WORK/oa_toolong.json"; exit 0
        fi
        if [[ "\${MOCK_OA_FAIL:-0}" == "1" ]]; then
            echo "curl: (6) Could not resolve host: api.openalex.org" >&2; exit 6
        fi
        if [[ \$hit -eq 1 ]]; then cat "\$WORK/oa_hits.json"; else cat "\$WORK/oa_empty.json"; fi
        ;;
    */asta-tools.allen.ai/*)
        if [[ "\${MOCK_ASTA_FAIL:-0}" == "1" ]]; then
            echo "curl: (28) Operation timed out" >&2; exit 28
        fi
        if [[ \$hit -eq 1 ]]; then cat "\$WORK/asta_hits.txt"; else cat "\$WORK/asta_empty.txt"; fi
        ;;
    *)
        echo "unexpected curl invocation: \$joined" >&2; exit 7
        ;;
esac
CURLSTUB
chmod +x "$STUB_DIR/curl"

CFG_S2="$WORK/cfg-s2.yml"
cat > "$CFG_S2" <<'EOF'
lit:
  s2_api_key: "fake-s2-key"
  asta_api_key: ""
  openalex_mailto: "tester@example.org"
EOF

CFG_ALL="$WORK/cfg-all.yml"
cat > "$CFG_ALL" <<'EOF'
lit:
  s2_api_key: "fake-s2-key"
  asta_api_key: "fake-asta-key"
  openalex_mailto: "tester@example.org"
EOF

LIBDIR="$WORK/lib"
mkdir -p "$LIBDIR/.bipartite"
: > "$LIBDIR/.bipartite/refs.jsonl"

# Usage: run_lit <out-var> <err-var> <rc-var> <config> <args...>
run_lit() {
    local _out_var="$1" _err_var="$2" _rc_var="$3" _cfg="$4"; shift 4
    local _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    env -u S2_API_KEY -u ASTA_API_KEY \
        NEXUS_CONFIG="$_cfg" NEXUS_ROOT="$LIBDIR" LIT_PROBE_DELAY_SECS=0 \
        PATH="$STUB_DIR:$PATH" \
        "$LIT" "$@" >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    printf -v "$_out_var" '%s' "$(<"$_out_tmp")"
    printf -v "$_err_var" '%s' "$(<"$_err_tmp")"
    printf -v "$_rc_var"  '%s' "$_rc"
    rm -f "$_out_tmp" "$_err_tmp"
}

SHORT="batch effect correction"
# 12 words: over-constrained for the stub (and for the real backends). Drop
# any ONE of them and the stub hits, which is what the probe measures.
LONG="single cell RNA sequencing batch effect correction data integration methods benchmark atlas"
# Same length, but matches nothing at any length — the genuine zero. TWO
# no-match markers, so no single-term drop can recover it either.
LONG_EMPTY="NOTHINGMATCHES NOMATCHEITHER obscure unstudied phenomenon with many additional qualifying descriptive terms appended"

# =========================================================================
printf '\n== state 1: searched successfully, genuinely nothing matched ==\n'
# =========================================================================
# NEGATIVE CONTROL for the whole fix. If this ever reports an error or a
# warning, the fix has become the inverse bug: every empty result screaming.
run_lit out err rc "$CFG_S2" search "$LONG_EMPTY" --source s2 --limit 5
assert_eq   "genuine zero exits 0"                    "$rc" "0"
assert_jq   "genuine zero: status ok"                 "$out" '.status'                "ok"
assert_jq   "genuine zero: count 0"                   "$out" '.count'                 "0"
assert_jq   "genuine zero: complete"                  "$out" '.complete'              "true"
assert_jq   "genuine zero: not partial"               "$out" '.partial'               "false"
assert_jq   "genuine zero: no failed backends"        "$out" '.failed_backends|length' "0"
# It REPORTS the zero and what the probe found; it does not CERTIFY it. The
# probe's prefix is positional, so a re-ordering of the same conjunction can
# land on the other branch — "genuine zero (confirmed: …)" was a claim the
# evidence could not carry (PR #596 skeptic review, F1). Order-dependence
# itself is pinned by test-lit-probe-order-dependence.sh.
assert_contains "empty zero names the probe result"   "$out" "also matched nothing on s2"
assert_contains "empty zero stops short of a verdict" "$out" "not a verified absence"
assert_not_contains "empty zero is not certified"     "$out" "genuine zero"
assert_not_contains "empty zero carries no badge"     "$out" "(confirmed:"
assert_not_contains "genuine zero raises no alarm"    "$out" "INCOMPLETE"
assert_not_contains "genuine zero is not an error"    "$out" '"status": "error"'
# The probe DID run and still found nothing — that is what licenses the clean
# zero. S2 calls: the search, the drop-zero BASELINE (the reduction with
# nothing removed), then one leave-one-out drop per content term up to
# LIT_PROBE_MAX_DROPS (6), none of which hit.
assert_eq   "probe ran on the long empty query"       \
            "$(grep -c 'semanticscholar' "$CURL_LOG")" "8"
assert_jq   "probe state is empty, not a verdict"     "$out" '.probe.state'       "empty"
assert_jq   "probe discloses the coverage it reached" "$out" '.probe.drops_tried' "6"
LONG_EMPTY_OUT="$out"   # kept for the probe-state contrast further down

# A short genuinely-empty query is below the probe threshold: still a clean 0.
: > "$CURL_LOG"
run_lit out err rc "$CFG_S2" search "NOTHINGMATCHES zzqxwv" --source s2 --limit 5
assert_eq   "short genuine zero exits 0"              "$rc" "0"
assert_jq   "short genuine zero: status ok"           "$out" '.status' "ok"
assert_jq   "short genuine zero: count 0"             "$out" '.count'  "0"
assert_eq   "no probe below the word threshold"       \
            "$(grep -c 'semanticscholar' "$CURL_LOG")" "1"

# REGRESSION PIN: S2's zero-hit body has no `data` key. It used to be read as
# a malformed response, so every genuine S2 zero was reported as a BROKEN
# BACKEND — state (1) misreported as state (2), the inverse of #588.
assert_jq   "S2 empty body is not a backend failure"  "$out" '.failed_backends|join(",")' ""
assert_jq   "S2 counted as searched"                  "$out" '.query_sources|join(",")'   "s2"
assert_not_contains "no 'unexpected response' note"   "$err" "unexpected response"

# A zero that could NOT be corroborated must not be sold as a genuine one.
# ASTA's relevance call takes no year filter, so a year-filtered search
# cannot be probed there without varying two things at once — the probe
# declines, and the verdict must degrade to "unverified", never to "genuine".
run_lit out err rc "$CFG_ALL" search "$LONG_EMPTY" --source asta --year 2020:2021 --limit 5
assert_jq   "unprobeable zero is not called genuine"  "$out" '.status' "partial"
assert_jq   "unprobeable zero still reports count 0"  "$out" '.count'  "0"
assert_contains "unprobeable zero says UNVERIFIED"    "$out" "UNVERIFIED"
# "not 'genuine zero'" would now be VACUOUS — no branch says that any more.
# Anchor on what still distinguishes this state: a check that never ran must
# not be described as having run and found nothing.
assert_not_contains "unprobeable zero claims no corroboration" \
                                                      "$out" "also matched nothing"
assert_contains "unprobeable zero says the check could not run" \
                                                      "$out" "could not be run"
# `partial` has two causes and the backend lists witness only one. Here BOTH
# are empty, so a caller written to the documented contract — inspect
# failed_backends ∪ skipped_backends — finds nothing wrong and concludes
# nothing is. `probe.state` is the field that separates them
# (your-org/nexus-code#600 item 3).
assert_jq   "unprobeable zero: no backend failed"     "$out" '.failed_backends|length'  "0"
assert_jq   "unprobeable zero: none was skipped"      "$out" '.skipped_backends|length' "0"
assert_jq   "…so the cause is readable only from probe.state" \
                                                      "$out" '.probe.state' "inconclusive"
# And the probing states are distinguishable from each other, not just from ok.
assert_jq   "a probed zero does NOT read as inconclusive" \
                                                      "$LONG_EMPTY_OUT" '.probe.state' "empty"

# =========================================================================
printf '\n== state 3: over-constrained query (THE #588 REPRODUCTION) ==\n'
# =========================================================================
run_lit out err rc "$CFG_S2" search "$LONG" --source s2 --limit 5
assert_eq   "over-constrained exits non-zero"         "$rc" "2"
assert_jq   "over-constrained: status error"          "$out" '.status'      "error"
assert_jq   "over-constrained: kind"                  "$out" '.error.kind'  "query_over_constrained"
# The heart of it: an error must NOT be a well-formed empty result set.
assert_jq   "NO count key emitted"                    "$out" 'has("count")'   "false"
assert_jq   "NO results key emitted"                  "$out" 'has("results")' "false"
assert_jq   ".count reads null, never 0"              "$out" '.count'         "null"
assert_contains "names the measured evidence"         "$out" "returned 1 hit(s)"
# Read out of `.error.remedy`, NOT grepped off the whole response: the `query`
# field echoes the caller's wording back verbatim, so any substring of the
# original query "passes" a whole-response grep no matter what the remedy says.
# The pre-#600 form of this assertion did exactly that and kept passing after
# the remedy stopped being a prefix of the query.
assert_jq   "names the term that binds the zero"      "$out" '.probe.dropped_term' "atlas"
assert_contains "remedy drops that term"              \
            "$(jq -r '.error.remedy' <<<"$out")" 'Search again without "atlas"'
assert_contains "remedy is the near-query, not a broad topic" \
            "$(jq -r '.error.remedy' <<<"$out")" \
            "batch benchmark cell correction data effect integration methods rna sequencing single"
# HEDGES the absence claim rather than denying it. The prefix's result set is
# a superset of the full query's, so a probe hit shows only that the broad
# topic is populated — a real conjunctive gap inside a populated topic has the
# same signature (PR #596 skeptic review, F2).
assert_contains "hedges rather than denies absence"   "$out" "MAY reflect an over-specific query"
assert_not_contains "does not deny absence outright"  "$out" "NOT an empty literature"
assert_contains "stderr is loud"                      "$err" "SEARCH FAILED"

# The PRISTINE #588 shape, reproduced against a backend whose empty answer is
# well-formed (`{"meta":{"count":0},"results":[]}`) and was therefore handled
# "correctly" by the old code. Measured live before the fix, this returned
# rc=0, partial:false, failed_backends:[], count:0 — a completely clean,
# authoritative-looking "no literature exists" for a query that was merely
# too long. Nothing in the old response distinguished it from a real zero.
run_lit out err rc "$CFG_S2" search "$LONG" --source openalex --limit 5
assert_eq   "openalex over-constrained exits non-zero" "$rc" "2"
assert_jq   "openalex over-constrained: status error"  "$out" '.status'      "error"
assert_jq   "openalex over-constrained: kind"          "$out" '.error.kind'  "query_over_constrained"
assert_jq   "openalex over-constrained: no count key"  "$out" 'has("count")' "false"
assert_jq   "openalex over-constrained: no partial-0"  "$out" '.count'       "null"

# =========================================================================
printf '\n== state 3: query over the hard length limit (pre-flight) ==\n'
# =========================================================================
: > "$CURL_LOG"
HUGE=$(python3 -c "print(' '.join(['cell']*600))")
run_lit out err rc "$CFG_S2" search "$HUGE" --source s2 --limit 5
assert_eq   "too-long query exits non-zero"           "$rc" "2"
assert_jq   "too-long: status error"                  "$out" '.status'     "error"
assert_jq   "too-long: kind"                          "$out" '.error.kind' "query_too_long"
assert_jq   "too-long: no count key"                  "$out" 'has("count")' "false"
assert_eq   "pre-flight spent no request"             "$(grep -c . "$CURL_LOG")" "0"

# =========================================================================
printf '\n== state 3: backend REJECTS the query (OpenAlex 400) ==\n'
# =========================================================================
# A rejected query is not a broken backend: it condemns the whole search,
# because every other backend answered the same bad query.
run_lit out err rc "$CFG_S2" search "$SHORT" --source openalex --limit 5 \
    2>/dev/null || true
MOCK_OA_TOOLONG=1 run_lit out err rc "$CFG_S2" search "$SHORT" --source openalex --limit 5
assert_eq   "rejected query exits non-zero"           "$rc" "2"
assert_jq   "rejected: status error"                  "$out" '.status'     "error"
assert_jq   "rejected: kind"                          "$out" '.error.kind' "query_rejected"
assert_jq   "rejected: names the backend"             "$out" '.rejected_backends|join(",")' "openalex"
assert_jq   "rejected: not filed as a mere failure"   "$out" '.failed_backends|length' "0"
assert_jq   "rejected: no count key"                  "$out" 'has("count")' "false"

# =========================================================================
printf '\n== state 2: partial — a backend failed, others served ==\n'
# =========================================================================
MOCK_OA_FAIL=1 run_lit out err rc "$CFG_ALL" search "$SHORT" --source all --limit 5
assert_eq   "partial-with-hits still exits 0"         "$rc" "0"
assert_jq   "partial: status partial"                 "$out" '.status'    "partial"
assert_jq   "partial: complete false"                 "$out" '.complete'  "false"
assert_jq   "partial: names the failed backend"       "$out" '.failed_backends|join(",")' "openalex"
assert_contains "partial announces incompleteness"    "$out" "INCOMPLETE"
assert_contains "partial says lower bound"            "$out" "lower bound"

# THE KILLER CASE: zero results AND a dead backend. This must never read as
# "no literature exists".
MOCK_OA_FAIL=1 run_lit out err rc "$CFG_ALL" search "$LONG_EMPTY" --source all --limit 5
assert_jq   "partial-zero: status partial"            "$out" '.status' "partial"
assert_jq   "partial-zero: count 0"                   "$out" '.count'  "0"
assert_contains "partial-zero denies absence claim"   "$out" "NOT evidence that no literature exists"
assert_contains "partial-zero names what broke"       "$out" "openalex"
# "never says genuine" is now vacuous — no branch says it. Anchor instead on
# the claim that WOULD be wrong here: an incomplete search must not report
# that every backend was searched successfully.
assert_not_contains "partial-zero claims no clean sweep" \
                                                      "$out" "were searched successfully"

# =========================================================================
printf '\n== state 2: partial — a backend was SKIPPED (no key) ==\n'
# =========================================================================
run_lit out err rc "$CFG_S2" search "$SHORT" --source all --limit 5
assert_jq   "skipped: status partial"                 "$out" '.status' "partial"
assert_jq   "skipped: names the skipped backend"      "$out" '.skipped_backends|join(",")' "asta"
assert_contains "skipped announces incompleteness"    "$out" "INCOMPLETE"

# =========================================================================
printf '\n== state 3: nothing was searched at all ==\n'
# =========================================================================
MOCK_S2_FAIL=1 run_lit out err rc "$CFG_S2" search "$SHORT" --source s2 --limit 5
assert_eq   "all-backends-dead exits non-zero"        "$rc" "2"
assert_jq   "all-dead: status error"                  "$out" '.status'     "error"
assert_jq   "all-dead: kind"                          "$out" '.error.kind' "no_backend_searched"
assert_jq   "all-dead: no count key"                  "$out" 'has("count")' "false"

# =========================================================================
printf '\n== human rendering carries the state too ==\n'
# =========================================================================
# The default rendering is JSON, but --human must not lose the distinction:
# "Found 0 papers" with no qualifier was the original defect verbatim.
run_lit out err rc "$CFG_S2" search "$LONG_EMPTY" --source s2 --limit 5 --human
assert_contains "human zero carries the caveat"       "$out" "not a verified absence"
assert_not_contains "human zero is not certified"     "$out" "genuine zero"
assert_not_contains "human genuine zero: no WARNING"  "$out" "WARNING"

MOCK_OA_FAIL=1 run_lit out err rc "$CFG_ALL" search "$LONG_EMPTY" --source all --limit 5 --human
assert_contains "human partial-zero warns"            "$out" "WARNING"
assert_contains "human partial-zero denies absence"   "$out" "NOT evidence that no literature exists"
assert_contains "human partial headline"              "$out" "INCOMPLETE"

run_lit out err rc "$CFG_S2" search "$LONG" --source s2 --limit 5 --human
assert_contains "human over-constrained fails loud"   "$out" "SEARCH FAILED"
assert_contains "human over-constrained: not a result" "$out" "This is NOT a result"
assert_not_contains "human error prints no 'Found 0'" "$out" "Found 0 papers"

# =========================================================================
printf '\n== success path is untouched ==\n'
# =========================================================================
run_lit out err rc "$CFG_ALL" search "$SHORT" --source all --limit 5
assert_eq   "success exits 0"                         "$rc" "0"
assert_jq   "success: status ok"                      "$out" '.status'   "ok"
assert_jq   "success: complete"                       "$out" '.complete' "true"
assert_jq   "success: has results"                    "$out" '(.count > 0)' "true"
assert_not_contains "success raises no alarm"         "$out" "INCOMPLETE"

# ---- summary ------------------------------------------------------------
printf '\n'
if [[ $FAIL -eq 0 ]]; then
    printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
    exit 0
fi
printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
exit 1
