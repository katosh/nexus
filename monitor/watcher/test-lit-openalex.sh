#!/usr/bin/env bash
# Mock-curl unit tests for the OpenAlex backend in monitor/lit.sh (`ng lit`).
#
# Run: bash monitor/watcher/test-lit-openalex.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: monitor/lit.sh is invoked directly as a subprocess (it dispatches
# at the bottom and is not source-able without side effects), with a
# PATH-shadowed `curl` stub that branches on the target URL/query to canned
# OpenAlex (and, for the degradation test, ASTA) responses. NEXUS_CONFIG /
# NEXUS_ROOT are pinned to a per-test $WORK tree so nothing here depends on
# the developer's real config/nexus.yml or touches the real reference
# library.
#
# What is tested: `status` reporting OpenAlex as always-available (never
# "unconfigured"); `search` --source normalization (openalex/both/all),
# dedup + in_library annotation, and graceful degradation when OpenAlex is
# unreachable but another backend still serves; `add` falling back to
# OpenAlex for DOI/work-id lookups when no S2 key is configured, including
# the dedup-refuse path and the abstract_inverted_index reconstruction.
#
# What is NOT tested here: the S2/ASTA code paths themselves (unchanged by
# this PR, and pre-existing behavior with no prior test file to extend) —
# ASTA is mocked only as the "another backend" in the degradation test.

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
# Query pretty-printed JSON with a jq filter and compare — robust against
# jq's default multi-line/spaced formatting (`ng lit` does not pass -c).
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

# Canned payloads live in their own files (quoted heredocs — no shell
# interpolation) so embedded JSON quoting can never corrupt the stub
# script itself; the stub just `cat`s the right file by request shape.
cat > "$WORK/oa_search.json" <<'EOF'
{"results":[{"id":"https://openalex.org/W3203496375","doi":"https://doi.org/10.1038/s41587-021-01033-z","title":"Differential abundance testing on single-cell data using k-nearest neighbor graphs","display_name":"Differential abundance testing on single-cell data using k-nearest neighbor graphs","publication_year":2021,"primary_location":{"source":{"display_name":"Nature Biotechnology"},"landing_page_url":"https://doi.org/10.1038/s41587-021-01033-z"},"authorships":[{"author":{"display_name":"Emma Dann"}},{"author":{"display_name":"Neil C. Henderson"}}],"cited_by_count":960}]}
EOF

cat > "$WORK/oa_entity.json" <<'EOF'
{"id":"https://openalex.org/W3203496375","doi":"https://doi.org/10.1038/s41587-021-01033-z","title":"Differential abundance testing on single-cell data using k-nearest neighbor graphs","display_name":"Differential abundance testing on single-cell data using k-nearest neighbor graphs","publication_year":2021,"primary_location":{"source":{"display_name":"Nature Biotechnology"}},"authorships":[{"author":{"display_name":"Emma Dann"}},{"author":{"display_name":"Neil C. Henderson"}}],"abstract_inverted_index":{"Hello":[0],"world":[1]},"ids":{"pmid":"https://pubmed.ncbi.nlm.nih.gov/34594043","pmcid":null}}
EOF

# The filter=doi: lookup path wraps the same work object in a results array.
jq -c -n --slurpfile w "$WORK/oa_entity.json" '{results: $w}' > "$WORK/oa_filter.json"

cat > "$WORK/asta_sse.txt" <<'EOF'
data: {"result":{"content":[{"type":"text","text":"{\"paperId\":\"asta1\",\"title\":\"Milo: differential abundance testing on single-cell data\",\"year\":2020,\"venue\":\"bioRxiv\",\"externalIds\":{\"DOI\":\"10.1101/2020.11.23.393769\"},\"citationCount\":16,\"url\":\"https://example.org/asta1\",\"authors\":[{\"name\":\"E. Dann\"}]}"}]}}
EOF

# ---- rank-fusion fixtures (MOCK_FUSION=1) -------------------------------
# Built so that ALPHABETICAL-BY-DOI and RANK-FUSED orderings are provably
# different, and the difference is the assertion:
#
#   OpenAlex relevance order   1. 10.9999/zzz-first   (sorts LAST  by DOI)
#                              2. 10.1214/14-ba872    (lowercase twin)
#                              3. 10.0001/aaa-third   (sorts FIRST by DOI)
#   ASTA relevance order       1. 10.1214/14-BA872    (UPPERCASE twin)
#                              2. 10.5555/other-paper
#
# Alphabetical would put "Gamma Ranked Third" first. Rank fusion puts the
# CONSENSUS paper (found by both, RRF 1/62+1/61) first, then "Alpha Ranked
# First". The uppercase/lowercase DOI pair must collapse to ONE record.
cat > "$WORK/oa_search_multi.json" <<'EOF'
{"results":[
 {"id":"https://openalex.org/W900","doi":"https://doi.org/10.9999/zzz-first","title":"Alpha Ranked First","display_name":"Alpha Ranked First","publication_year":2021,"primary_location":{"source":{"display_name":"Journal A"},"landing_page_url":"https://example.org/a"},"authorships":[{"author":{"display_name":"A Author"}}],"cited_by_count":10},
 {"id":"https://openalex.org/W901","doi":"https://doi.org/10.1214/14-ba872","title":"Laplace Approximation Shared Paper","display_name":"Laplace Approximation Shared Paper","publication_year":2015,"primary_location":{"source":{"display_name":"Journal B"},"landing_page_url":"https://example.org/b"},"authorships":[{"author":{"display_name":"B Author"}}],"cited_by_count":20},
 {"id":"https://openalex.org/W902","doi":"https://doi.org/10.0001/aaa-third","title":"Gamma Ranked Third","display_name":"Gamma Ranked Third","publication_year":2019,"primary_location":{"source":{"display_name":"Journal C"},"landing_page_url":"https://example.org/c"},"authorships":[{"author":{"display_name":"C Author"}}],"cited_by_count":30}
]}
EOF

cat > "$WORK/asta_sse_multi.txt" <<'EOF'
data: {"result":{"content":[{"type":"text","text":"{\"paperId\":\"astaB\",\"title\":\"Laplace Approximation Shared Paper\",\"year\":2015,\"venue\":\"Journal B\",\"externalIds\":{\"DOI\":\"10.1214/14-BA872\"},\"citationCount\":20,\"url\":\"https://example.org/b\",\"authors\":[{\"name\":\"B Author\"}]}"},{"type":"text","text":"{\"paperId\":\"astaD\",\"title\":\"Delta Other Paper\",\"year\":2018,\"venue\":\"Journal D\",\"externalIds\":{\"DOI\":\"10.5555/other-paper\"},\"citationCount\":5,\"url\":\"https://example.org/d\",\"authors\":[{\"name\":\"D Author\"}]}"}]}}
EOF

cat > "$STUB_DIR/curl" <<CURLSTUB
#!/usr/bin/env bash
WORK="$WORK"
argv=("\$@")
joined="\${argv[*]}"
url=""
for a in "\${argv[@]}"; do
    case "\$a" in http*://*) url="\$a" ;; esac
done

case "\$url" in
    */api.openalex.org/works/*)
        if [[ "\${MOCK_OPENALEX_FAIL:-0}" == "1" ]]; then
            echo "curl: (6) Could not resolve host: api.openalex.org" >&2
            exit 6
        fi
        cat "\$WORK/oa_entity.json"
        ;;
    */api.openalex.org/works)
        if [[ "\${MOCK_OPENALEX_FAIL:-0}" == "1" ]]; then
            echo "curl: (6) Could not resolve host: api.openalex.org" >&2
            exit 6
        fi
        if [[ "\$joined" == *"filter=doi:"* ]]; then
            cat "\$WORK/oa_filter.json"
        elif [[ "\${MOCK_FUSION:-0}" == "1" ]]; then
            cat "\$WORK/oa_search_multi.json"
        else
            cat "\$WORK/oa_search.json"
        fi
        ;;
    */asta-tools.allen.ai/*)
        if [[ "\${MOCK_FUSION:-0}" == "1" ]]; then
            cat "\$WORK/asta_sse_multi.txt"
        else
            cat "\$WORK/asta_sse.txt"
        fi
        ;;
    *)
        echo "unexpected curl invocation: \$joined" >&2
        exit 7
        ;;
esac
CURLSTUB
chmod +x "$STUB_DIR/curl"

# Hermetic config — a per-test nexus.yml so lit.sh never touches the
# developer's real S2/ASTA keys or reference library.
CFG_UNCONFIGURED="$WORK/cfg-unconfigured.yml"
cat > "$CFG_UNCONFIGURED" <<'EOF'
lit:
  s2_api_key: ""
  asta_api_key: ""
  openalex_mailto: "tester@example.org"
EOF

CFG_ASTA="$WORK/cfg-asta.yml"
cat > "$CFG_ASTA" <<'EOF'
lit:
  s2_api_key: ""
  asta_api_key: "fake-asta-key"
  openalex_mailto: "tester@example.org"
EOF

# Usage: run_lit <out-var> <err-var> <rc-var> <config> <library-dir> <args...>
run_lit() {
    local _out_var="$1" _err_var="$2" _rc_var="$3" _cfg="$4" _libdir="$5"; shift 5
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    env -u S2_API_KEY -u ASTA_API_KEY \
        NEXUS_CONFIG="$_cfg" NEXUS_ROOT="$_libdir" \
        PATH="$STUB_DIR:$PATH" \
        "$LIT" "$@" >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

LIBDIR="$WORK/root"
mkdir -p "$LIBDIR"

# ---- Test 1: status reports OpenAlex as always-available ----------------

echo '=== status: OpenAlex reports available with no key; S2/ASTA report unconfigured ==='
run_lit stdout stderr rc "$CFG_UNCONFIGURED" "$LIBDIR" status --human
assert_eq       "status exits 0 even with S2/ASTA both unconfigured" "$rc" "0"
assert_contains "human output shows OpenAlex as yes/no-key-required" "$stdout" "OpenAlex:    yes (no key required"
assert_contains "human output reports the resolved mailto"          "$stdout" "tester@example.org"
assert_contains "human status line calls out the partial state"     "$stdout" "partial"

run_lit stdout stderr rc "$CFG_UNCONFIGURED" "$LIBDIR" status
assert_eq  "JSON status also exits 0"                          "$rc" "0"
assert_jq  "JSON marks openalex configured:true"    "$stdout" '.openalex.configured'   "true"
assert_jq  "JSON marks openalex key_required:false"  "$stdout" '.openalex.key_required' "false"
assert_jq  "JSON search_available is true"           "$stdout" '.search_available'      "true"
assert_jq  "JSON top-level configured is false (s2/asta only)" "$stdout" '.configured'  "false"

# ---- Test 2: search --source openalex normalizes fields + dedups --------

echo '=== search --source openalex: field normalization ==='
run_lit stdout stderr rc "$CFG_UNCONFIGURED" "$LIBDIR" search "differential abundance" --source openalex --limit 5
assert_eq  "exit 0 on openalex-only search"                    "$rc" "0"
assert_jq  "query_sources reports openalex"           "$stdout" '.query_sources | join(",")'   "openalex"
assert_jq  "doi is stripped of the https://doi.org/ prefix" "$stdout" '.results[0].doi'         "10.1038/s41587-021-01033-z"
assert_jq  "id is stripped of the openalex.org URL prefix"  "$stdout" '.results[0].id'          "W3203496375"
assert_jq  "authors are joined into one string"       "$stdout" '.results[0].authors'           "Emma Dann, Neil C. Henderson"
assert_jq  "source tag is openalex"                   "$stdout" '.results[0].source'            "openalex"

# ---- Test 3: --source both / default all — the config gate -------------

echo '=== --source both with nothing configured -> exit 3 + setup refs (legacy gate unchanged) ==='
run_lit stdout stderr rc "$CFG_UNCONFIGURED" "$LIBDIR" search "test" --source both --limit 1
assert_eq       "exit 3 when both s2 and asta lack keys"             "$rc" "3"
assert_contains "stderr explains OpenAlex needs no key"              "$stderr" "OpenAlex needs no key"

echo '=== default --source (all) with nothing configured -> still succeeds via OpenAlex ==='
run_lit stdout stderr rc "$CFG_UNCONFIGURED" "$LIBDIR" search "test" --limit 1
assert_eq       "default source exits 0 even fully unconfigured"    "$rc" "0"
assert_contains "stderr notes s2 skipped for lack of key"            "$stderr" "skipped: s2"
assert_contains "stderr notes asta skipped for lack of key"          "$stderr" "skipped: asta"
assert_jq       "query_sources is exactly openalex"                  "$stdout" '.query_sources | join(",")' "openalex"

# ---- Test 4: graceful degradation — OpenAlex down, ASTA still serves ----

echo '=== OpenAlex unreachable + ASTA configured -> ASTA still serves, exit 0 ==='
export MOCK_OPENALEX_FAIL=1
run_lit stdout stderr rc "$CFG_ASTA" "$LIBDIR" search "differential abundance" --limit 2
unset MOCK_OPENALEX_FAIL
assert_eq       "exit 0 when one of several backends fails"         "$rc" "0"
assert_contains "stderr notes openalex failed and was skipped"       "$stderr" "skipped: openalex"
assert_jq       "asta results still came through"                    "$stdout" '.query_sources | join(",")' "asta"
assert_jq       "asta paper title present in results"                 "$stdout" '.results[0].title' "Milo: differential abundance testing on single-cell data"

echo '=== every backend fails/unconfigured -> exit 1, not exit 3 (search WAS attempted) ==='
export MOCK_OPENALEX_FAIL=1
run_lit stdout stderr rc "$CFG_UNCONFIGURED" "$LIBDIR" search "test" --limit 1
unset MOCK_OPENALEX_FAIL
# Exit 2, not 1, as of your-org/nexus-code#588: every state where the command
# has NO result to report — query too long, query rejected, nothing searched —
# now emits the same error envelope (no `count`, no `results`) and the same
# exit code, so a caller has one condition to test rather than three. The
# distinction this test exists to protect is still protected: 2 (a search was
# attempted and nothing survived) remains separate from 3 (nothing was
# configured, so no search was ever attempted).
assert_eq       "exit 2 when the only usable backend fails at request time" "$rc" "2"
assert_contains "stderr fails loudly with the reason"                 "$stderr" "no_backend_searched"
# The old body was a well-formed `count: 0` result set — the #588 defect
# verbatim. There must be no count to misread.
assert_jq       "no count key when nothing was searched"              "$stdout" 'has("count")' "false"

# ---- Test 5: add via OpenAlex (no S2 key) --------------------------------

echo '=== add <DOI> with no S2 key falls back to OpenAlex ==='
run_lit stdout stderr rc "$CFG_UNCONFIGURED" "$LIBDIR" add 10.1038/s41587-021-01033-z --human
assert_eq       "add exits 0 via the OpenAlex fallback"              "$rc" "0"
assert_contains "human confirmation names the paper"                  "$stdout" "Differential abundance testing"
LIB_FILE="$LIBDIR/.bipartite/refs.jsonl"
assert_eq       "exactly one record was appended"                    "$(grep -c '' "$LIB_FILE" 2>/dev/null || true)" "1"
REC=$(cat "$LIB_FILE")
assert_contains "record source.type is openalex"                      "$REC" '"type":"openalex"'
assert_contains "record source.id is the bare W-id"                    "$REC" '"id":"W3203496375"'
assert_contains "record pmid is stripped to bare digits"               "$REC" '"pmid":"34594043"'
assert_contains "record abstract is reconstructed from the inverted index" "$REC" '"abstract":"Hello world"'

echo '=== re-adding the same DOI is refused, not duplicated ==='
run_lit stdout stderr rc "$CFG_UNCONFIGURED" "$LIBDIR" add 10.1038/s41587-021-01033-z --human
assert_eq       "re-add exits 0 (idempotent, not an error)"          "$rc" "0"
assert_contains "stdout reports already-present"                      "$stdout" "already present"
assert_eq       "library still has exactly one record"                "$(grep -c '' "$LIB_FILE" 2>/dev/null || true)" "1"

echo '=== add <openalex:Wid> (explicit prefix) uses the entity route ==='
LIBDIR2="$WORK/root2"; mkdir -p "$LIBDIR2"
run_lit stdout stderr rc "$CFG_UNCONFIGURED" "$LIBDIR2" add openalex:W3203496375 --human
assert_eq       "add via explicit openalex: id exits 0"              "$rc" "0"
assert_contains "human confirmation names the paper"                  "$stdout" "Differential abundance testing"

echo '=== add <non-DOI-id> with no S2 key is refused, not silently misrouted ==='
LIBDIR3="$WORK/root3"; mkdir -p "$LIBDIR3"
run_lit stdout stderr rc "$CFG_UNCONFIGURED" "$LIBDIR3" add 649def34f8be52c8b66281af98ae884c09aef38 --human
assert_eq       "exit 3 for a non-DOI id with no S2 key"             "$rc" "3"
assert_contains "stderr explains an S2 key is required for this id shape" "$stderr" "requires an S2 key for non-DOI ids"

echo "=== rank fusion: output is ranked, NOT sorted alphabetically by DOI ==="
LIBDIR4="$WORK/root4"; mkdir -p "$LIBDIR4"
export MOCK_FUSION=1
run_lit stdout stderr rc "$CFG_ASTA" "$LIBDIR4" search "shared" --source all --limit 5
assert_eq  "fused search exits 0"                             "$rc" "0"
# 4 distinct papers from 5 raw hits — the DOI-case twin collapses to one.
assert_jq  "case-differing DOI twin collapsed (4 not 5)"      "$stdout" '.count' "4"
# The consensus paper is rank 2 in OpenAlex and rank 1 in ASTA; RRF
# (1/62 + 1/61) beats the single-backend rank-1 (1/61). Agreement wins.
assert_jq  "consensus paper ranks first"                      "$stdout" '.results[0].title' "Laplace Approximation Shared Paper"
assert_jq  "consensus paper is credited to both backends"     "$stdout" '.results[0].sources | join("+")' "asta+openalex"
assert_jq  "consensus paper records found_by=2"               "$stdout" '.results[0].found_by' "2"
# The representative keeps a DOI-bearing record (either case form is fine).
assert_jq  "merged record keeps the shared DOI"               "$stdout" '.results[0].doi | ascii_downcase' "10.1214/14-ba872"
# OpenAlex rank 1 stays ahead of OpenAlex rank 3 ...
assert_jq  "backend rank order is preserved"                  "$stdout" '.results[1].title' "Alpha Ranked First"
# ... and the DOI that sorts FIRST alphabetically must NOT be first overall.
assert_jq  "alphabetically-first DOI is ranked LAST"          "$stdout" '.results[3].title' "Gamma Ranked Third"
assert_jq  "no duplicate survives the case-folded key"        "$stdout" '[.results[].doi | ascii_downcase] | unique | length' "4"
unset MOCK_FUSION

echo "=== a failed backend is reported IN-BAND on stdout, not only on stderr ==="
export MOCK_FUSION=1 MOCK_OPENALEX_FAIL=1
run_lit stdout stderr rc "$CFG_ASTA" "$LIBDIR4" search "shared" --source all --limit 5
unset MOCK_FUSION MOCK_OPENALEX_FAIL
assert_eq  "exit 0 — ASTA still served results"               "$rc" "0"
assert_jq  "failed_backends names openalex"                   "$stdout" '.failed_backends | join(",")' "openalex"
assert_jq  "partial flag is set"                              "$stdout" '.partial' "true"
assert_jq  "skipped_backends names the keyless s2"            "$stdout" '.skipped_backends | join(",")' "s2"
assert_jq  "surviving backend still reported"                 "$stdout" '.query_sources | join(",")' "asta"

echo "=== a search missing a backend is partial even when nothing FAILED ==="
# This case asks for --source all with no S2 key, so s2 is never searched.
# It used to assert partial:false, on the reasoning that nothing errored.
# That is the wrong assertion: the caller asked for three backends and got
# two, and your-org/nexus-code#588 defines state 2 as "at least one backend
# failed OR WAS SKIPPED — partial; say which, and say the result is
# incomplete". Reporting partial:false here tells the caller it received
# everything it asked for, which is false, and is exactly the over-confidence
# that makes a thin result set read as the whole literature.
# `failed_backends` stays empty — that is what distinguishes an unconfigured
# backend from a broken one, and it is the field to test for breakage.
export MOCK_FUSION=1
run_lit stdout stderr rc "$CFG_ASTA" "$LIBDIR4" search "shared" --source all --limit 5
unset MOCK_FUSION
assert_jq  "partial is true when a backend was skipped"       "$stdout" '.partial' "true"
assert_jq  "status is partial, not ok"                        "$stdout" '.status' "partial"
assert_jq  "failed_backends is empty (skipped != failed)"     "$stdout" '.failed_backends | length' "0"
assert_jq  "skipped_backends names the unconfigured s2"       "$stdout" '.skipped_backends | join(",")' "s2"
# ... and a search that got everything it asked for is clean.
run_lit stdout stderr rc "$CFG_ASTA" "$LIBDIR4" search "shared" --source asta --limit 5
assert_jq  "single requested backend served -> status ok"     "$stdout" '.status'  "ok"
assert_jq  "single requested backend served -> not partial"   "$stdout" '.partial' "false"

echo "=== --human announces an incomplete result set ==="
export MOCK_FUSION=1 MOCK_OPENALEX_FAIL=1
run_lit stdout stderr rc "$CFG_ASTA" "$LIBDIR4" search "shared" --source all --limit 5 --human
unset MOCK_FUSION MOCK_OPENALEX_FAIL
assert_contains "human output warns the results are incomplete" "$stdout" "INCOMPLETE"
assert_contains "human output names the failed backend"         "$stdout" "openalex"

# ---- summary --------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
