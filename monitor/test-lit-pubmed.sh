#!/usr/bin/env bash
# Tests for the PubMed backend of monitor/lit.sh (`ng lit`).
#
# Run: bash monitor/test-lit-pubmed.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# PubMed is an OPT-IN backend (`--source pubmed`, a comma list such as
# `all,pubmed`, or `lit.default_source`), so every search below names it.
#
# Offline by default: a PATH-front `curl` stub serves recorded NCBI
# E-utilities responses and logs every call, so the suite pins what
# lit.sh SENDS (api_key, email, tool, pacing) as well as what it parses.
#
# One live check runs when eutils.ncbi.nlm.nih.gov is reachable (set
# LIT_LIVE=0 to skip it). It queries a term that must have hits and FAILS
# on zero results — a backend that silently returns [] is the defect a
# parse-only suite cannot see, because a fixture never drifts.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIT="$HERE/lit.sh"
REAL_CURL="$(command -v curl)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail + 1)); }
expect() {  # expect <name> <condition-exit> [detail]
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}

# --- fixtures (recorded from E-utilities, trimmed) ---------------------------
mkdir -p "$TMP/fx" "$TMP/bin"
cat >"$TMP/fx/esearch.json" <<'EOF'
{"header":{"type":"esearch","version":"0.3"},"esearchresult":{"count":"16","retmax":"2","retstart":"0","idlist":["37248244","36420896"],"translationset":[],"querytranslation":"\"GENCODE\"[All Fields] AND \"2023\"[All Fields]"}}
EOF
cat >"$TMP/fx/esearch-empty.json" <<'EOF'
{"header":{"type":"esearch","version":"0.3"},"esearchresult":{"count":"0","retmax":"0","retstart":"0","idlist":[],"translationset":[],"querytranslation":"zzqq","warninglist":{"outputmessages":["No items found."]}}}
EOF
# Dropped terms: PubMed still returns hits for the rest of the query.
cat >"$TMP/fx/esearch-warn.json" <<'EOF'
{"header":{"type":"esearch","version":"0.3"},"esearchresult":{"count":"2","retmax":"2","retstart":"0","idlist":["37248244","36420896"],"errorlist":{"phrasesnotfound":["zqxjv"],"fieldsnotfound":[]},"warninglist":{"phrasesignored":["the"],"quotedphrasesnotfound":[],"outputmessages":["[badfield"]},"querytranslation":"\"GENCODE\"[All Fields]"}}
EOF
cat >"$TMP/fx/esearch-one.json" <<'EOF'
{"header":{"type":"esearch","version":"0.3"},"esearchresult":{"count":"1","retmax":"1","retstart":"0","idlist":["36420896"],"translationset":[]}}
EOF
cat >"$TMP/fx/esummary.json" <<'EOF'
{"header":{"type":"esummary","version":"0.3"},"result":{"uids":["36420896","37248244"],
"36420896":{"uid":"36420896","pubdate":"2023 Jan 6","source":"Nucleic Acids Res","fulljournalname":"Nucleic acids research","title":"GENCODE: reference annotation for the human and mouse genomes in 2023.","authors":[{"name":"Frankish A","authtype":"Author"},{"name":"Carbonell-Sala S","authtype":"Author"},{"name":"GENCODE Consortium","authtype":"CollectiveName"}],"articleids":[{"idtype":"pubmed","value":"36420896"},{"idtype":"pmc","value":"PMC9825462"},{"idtype":"doi","value":"10.1093/nar/gkac1071"}]},
"37248244":{"uid":"37248244","pubdate":"2023 May 29","source":"Nat Commun","fulljournalname":"Nature communications","title":"Cochlear transcript diversity and its role in auditory functions implied by an otoferlin short isoform.","authors":[{"name":"Liu H","authtype":"Author"}],"articleids":[{"idtype":"pubmed","value":"37248244"},{"idtype":"doi","value":"10.1038/s41467-023-38621-3"}]}}}
EOF
cat >"$TMP/fx/efetch.xml" <<'EOF'
<?xml version="1.0" ?>
<PubmedArticleSet><PubmedArticle><MedlineCitation><PMID Version="1">36420896</PMID><Article><Abstract><AbstractText Label="BACKGROUND" NlmCategory="BACKGROUND">GENCODE produces &lt;high&gt; quality
annotation.</AbstractText><AbstractText Label="RESULTS">Genes &amp; transcripts.</AbstractText></Abstract></Article></MedlineCitation></PubmedArticle></PubmedArticleSet>
EOF
cat >"$TMP/fx/s2.json" <<'EOF'
{"total":2,"data":[{"paperId":"s2aaa","title":"GENCODE 2023 (S2 copy)","year":2023,"venue":"NAR","authors":[{"name":"A. Frankish"}],"externalIds":{"DOI":"10.1093/NAR/GKAC1071","PubMed":"36420896"},"citationCount":900,"url":"https://s2/aaa"},{"paperId":"s2bbb","title":"Only in S2","year":2020,"venue":"X","authors":[{"name":"B. Other"}],"externalIds":{"DOI":"10.1/only-s2"},"citationCount":1,"url":"https://s2/bbb"},{"paperId":"s2ccc","title":"Cochlear (S2 copy, no DOI)","year":2023,"venue":"NC","authors":[{"name":"H. Liu"}],"externalIds":{"PubMed":"37248244"},"citationCount":5,"url":"https://s2/ccc"}]}
EOF

# Keyless DOI lookups go to OpenAlex (the upstream keyless `add` path).
cat >"$TMP/fx/oa-doi.json" <<'EOF'
{"results":[{"id":"https://openalex.org/W4309","doi":"https://doi.org/10.1093/nar/gkac1071","title":"GENCODE: reference annotation for the human and mouse genomes in 2023.","publication_year":2023,"primary_location":{"source":{"display_name":"Nucleic Acids Research"}},"authorships":[{"author":{"display_name":"Adam Frankish"}}],"ids":{"pmid":"https://pubmed.ncbi.nlm.nih.gov/36420896"}}]}
EOF

# The stub. SHIM_MODE picks the scenario; every call is logged with a
# millisecond timestamp and its full argv (one line per call).
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(( $(date +%s%N) / 1000000 ))" "$*" >>"$CURL_LOG"
url="" w=0
for a in "$@"; do
  case "$a" in http*) url="$a" ;; -w) w=1 ;; esac
done
code=200 body=""
mode="${SHIM_MODE:-ok}"
case "$url" in
  *esearch.fcgi)
    case "$mode" in
      empty) body=$(cat "$FX/esearch-empty.json") ;;
      # NCBI echoes a rejected key in "api-key"; the stub also puts it in
      # "error", the field lit.sh prints, so the scrub is what is tested.
      badkey) code=400; body='{"error":"API key invalid: '"${NCBI_API_KEY:-}"'","api-key":"'"${NCBI_API_KEY:-}"'","type":"invalid"}' ;;
      429once)
        if [ ! -e "$FX/.tripped" ]; then : >"$FX/.tripped"; code=429; body='{"error":"API rate limit exceeded"}'
        else body=$(cat "$FX/esearch.json"); fi ;;
      doi) body=$(cat "$FX/esearch-one.json") ;;
      warn) body=$(cat "$FX/esearch-warn.json") ;;
      429always) code=429; body='{"error":"API rate limit exceeded"}' ;;
      *) body=$(cat "$FX/esearch.json") ;;
    esac ;;
  *esummary.fcgi)
    case "$mode" in
      badsummary) body='<html>proxy error</html>' ;;
      *) body=$(cat "$FX/esummary.json") ;;
    esac ;;
  *efetch.fcgi) body=$(cat "$FX/efetch.xml") ;;
  *semanticscholar*) body=$(cat "$FX/s2.json") ;;
  *api.openalex.org/works)
    case "$*" in
      *filter=doi:*) body=$(cat "$FX/oa-doi.json") ;;
      *) code=503; body='{}' ;;
    esac ;;
  *) code=404; body='{}' ;;
esac
printf '%s' "$body"
[ "$w" -eq 1 ] && printf '\n%s' "$code"
exit 0
EOF
chmod +x "$TMP/bin/curl"

export FX="$TMP/fx" CURL_LOG="$TMP/curl.log"
export NEXUS_ROOT="$TMP/root" LIT_NCBI_PACE_FILE="$TMP/pace"
mkdir -p "$NEXUS_ROOT"
printf 'lit:\n  s2_api_key: ""\n' >"$TMP/empty.yml"
export NEXUS_CONFIG="$TMP/empty.yml"
unset S2_API_KEY ASTA_API_KEY NCBI_API_KEY NCBI_EMAIL NCBI_TOOL

# config/load.sh reads YAML with python3 + PyYAML. Put one on PATH if the
# default python3 lacks it but another interpreter has it.
have_yaml=0
mkdir -p "$TMP/pybin"
for py in "$(command -v python3)" /usr/bin/python3 /usr/local/bin/python3; do
  [ -x "$py" ] && "$py" -c 'import yaml' 2>/dev/null || continue
  ln -sf "$py" "$TMP/pybin/python3"; have_yaml=1; break
done

run() {  # run <args...>  -> $OUT, $ERR, $RC (offline, stubbed curl)
  : >"$CURL_LOG"; rm -f "$FX/.tripped"
  OUT=$(PATH="$TMP/bin:$TMP/pybin:$PATH" bash "$LIT" "$@" 2>"$TMP/err"); RC=$?
  ERR=$(cat "$TMP/err")
}
calls() { grep -c "$1" "$CURL_LOG" || true; }

echo "-- search: default (no --source) leaves PubMed out: it is opt-in --"
run search "GENCODE 2023"
[ "$(calls eutils)" -eq 0 ]; expect "no --source -> default all, no E-utilities request" $?
jq -e '.query_sources | index("pubmed") | not' <<<"$OUT" >/dev/null; expect "no --source -> pubmed not in query_sources" $?

echo "-- search: --source pubmed returns hits --"
run search "GENCODE 2023" --source pubmed --limit 2
expect "exit 0" "$RC" "rc=$RC err=$ERR"
[ "$(jq -c '.query_sources' <<<"$OUT")" = '["pubmed"]' ]; expect "query_sources == [pubmed]" $?
n=$(jq '.count' <<<"$OUT"); [ "${n:-0}" -gt 0 ]; expect "count > 0 on a query that must have hits (got ${n:-none})" $?
# esearch's relevance order (37248244 first) is the reverse of numeric order
# and of esummary's uids order, so a sort anywhere turns this red.
[ "$(jq -c '[.results[].pmid]' <<<"$OUT")" = '["37248244","36420896"]' ]; expect "relevance order kept: PMIDs in esearch's order, not numeric or esummary's" $?
jq -e '.results[] | select(.pmid == "36420896") | (.pmid != "" and .doi == "10.1093/nar/gkac1071" and (.title|length) > 0
        and (.authors|test("Frankish A")) and .year == 2023 and .venue == "Nucleic acids research"
        and .source == "pubmed" and .url == "https://pubmed.ncbi.nlm.nih.gov/36420896/")' <<<"$OUT" >/dev/null
expect "result carries pmid, doi, title, authors, year, journal" $?

echo "-- search: what is SENT to NCBI --"
run search "GENCODE 2023" --source pubmed
grep -q 'tool=nexus-lit' "$CURL_LOG"; expect "tool= sent (default nexus-lit)" $?
! grep -q 'email=' "$CURL_LOG"; expect "no email= when none configured (never hard-coded)" $?
! grep -q 'api_key=' "$CURL_LOG"; expect "no api_key= when keyless" $?
NCBI_EMAIL=env@example.org NCBI_TOOL=envtool run search "GENCODE 2023" --source pubmed
grep -q 'email=env@example.org' "$CURL_LOG"; expect "email= from NCBI_EMAIL" $?
grep -q 'tool=envtool' "$CURL_LOG"; expect "tool= from NCBI_TOOL" $?
# config/load.sh needs a python3 with PyYAML. Skip (loudly) where none is.
if [ "$have_yaml" -eq 1 ]; then
  printf 'lit:\n  ncbi_email: "ops@example.org"\n  ncbi_tool: "mytool"\n  ncbi_api_key: "cfgKEY"\n' >"$TMP/mail.yml"
  NEXUS_CONFIG="$TMP/mail.yml" run search "GENCODE 2023" --source pubmed
  grep -q 'email=ops@example.org' "$CURL_LOG"; expect "email= from lit.ncbi_email" $?
  grep -q 'tool=mytool' "$CURL_LOG"; expect "tool= from lit.ncbi_tool" $?
  grep -q 'api_key=cfgKEY' "$CURL_LOG"; expect "api_key= from lit.ncbi_api_key" $?
  NEXUS_CONFIG="$TMP/mail.yml" NCBI_API_KEY=envKEY run search "GENCODE 2023" --source pubmed
  grep -q 'api_key=envKEY' "$CURL_LOG" && ! grep -q 'cfgKEY' "$CURL_LOG"; expect "env NCBI_API_KEY wins over config" $?
else
  echo "  SKIP config-file assertions: no python3 with PyYAML (config/load.sh needs it)"
fi
NCBI_API_KEY=k3y-SECRET run search "GENCODE 2023" --source pubmed
grep -q 'api_key=k3y-SECRET' "$CURL_LOG"; expect "api_key= from NCBI_API_KEY" $?
! grep -q 'k3y-SECRET' <<<"$OUT$ERR"; expect "key never printed" $?
run search "GENCODE 2023" --source pubmed --year 2020:2023
grep -q 'mindate=2020' "$CURL_LOG" && grep -q 'maxdate=2023' "$CURL_LOG"; expect "--year maps to mindate/maxdate" $?

echo "-- search: pacing to the NCBI limit (3 req/s keyless, 10 req/s keyed) --"
# Wall-clock gaps cannot pin pacing: process start-up alone can exceed the
# 350 ms gap, so a suite measuring them stays green with pacing deleted.
# Instead freeze the clock (a `date` stub) and log what `sleep` is asked
# for: with zero elapsed time, every request after the first must sleep
# exactly one full gap.
mkdir -p "$TMP/clock"
printf '#!/usr/bin/env bash\necho 1700000000000000000\n' >"$TMP/clock/date"
printf '#!/usr/bin/env bash\necho "$1" >>"$SLEEP_LOG"\n' >"$TMP/clock/sleep"
chmod +x "$TMP/clock/date" "$TMP/clock/sleep"
export SLEEP_LOG="$TMP/sleep.log"
paced() {  # paced [env...] -> $SLEEPS: the sleep arguments, space-joined
  : >"$SLEEP_LOG"; rm -f "$LIT_NCBI_PACE_FILE"
  env "$@" PATH="$TMP/clock:$TMP/bin:$TMP/pybin:$PATH" bash "$LIT" search "GENCODE 2023" --source pubmed >/dev/null 2>&1; RC=$?
  SLEEPS=$(tr '\n' ' ' <"$SLEEP_LOG")
}
paced
[ "$SLEEPS" = "0.350 " ]; expect "keyless: esummary waits 350 ms after esearch (sleeps: '$SLEEPS')" $?
paced NCBI_API_KEY=k
[ "$SLEEPS" = "0.110 " ]; expect "keyed: esummary waits 110 ms after esearch (sleeps: '$SLEEPS')" $?
rm -f "$FX/.tripped"
paced SHIM_MODE=429once
[ "$SLEEPS" = "1 0.350 0.350 " ]; expect "429 once: backs off 1 s, then paces the retry and esummary (sleeps: '$SLEEPS')" $?
: >"$CURL_LOG"
paced SHIM_MODE=429always
[ "$SLEEPS" = "1 0.350 2 0.350 " ] && [ "$(calls esearch.fcgi)" -eq 3 ] && [ "$RC" != 0 ]
expect "429 always: exactly 3 attempts, backoff 1 s then 2 s, no wait after the last (sleeps: '$SLEEPS')" $?
# Clock skew: a pace file stamped far in the future must cost one gap, not
# the whole distance (and never a malformed sleep argument).
: >"$SLEEP_LOG"; echo 1800000000000 >"$LIT_NCBI_PACE_FILE"
PATH="$TMP/clock:$TMP/bin:$TMP/pybin:$PATH" bash "$LIT" search "GENCODE 2023" --source pubmed >/dev/null 2>&1
SLEEPS=$(tr '\n' ' ' <"$SLEEP_LOG")
[ "$SLEEPS" = "0.350 0.350 " ]; expect "future-stamped pace file: waits one gap, not the skew (sleeps: '$SLEEPS')" $?

# Cross-process pacing: while another process holds the pace lock, no
# request may go out. Real clock here; hold the lock for 3 s (start-up
# alone can take ~0.8 s, so the threshold leaves a wide margin).
if command -v flock >/dev/null 2>&1; then
  rm -f "$LIT_NCBI_PACE_FILE"; : >"$CURL_LOG"
  ( flock 9; sleep 3 ) 9>>"$LIT_NCBI_PACE_FILE.lock" &
  holder=$!; sleep 0.2
  start=$(( $(date +%s%N) / 1000000 ))
  PATH="$TMP/bin:$TMP/pybin:$PATH" bash "$LIT" search "GENCODE 2023" --source pubmed >/dev/null 2>&1
  wait "$holder"
  first=$(awk 'NR==1{print $1}' "$CURL_LOG")
  [ -n "$first" ] && [ $(( first - start )) -ge 2000 ]
  expect "pace lock held by another process -> first request waits for it ($(( ${first:-0} - start )) ms)" $?
else
  echo "  SKIP cross-process lock check: no flock on this host"
fi

echo "-- search: failures are loud, never a silent empty success --"
SHIM_MODE=badsummary run search "GENCODE 2023" --source pubmed
[ "$RC" -ne 0 ]; expect "malformed esummary -> non-zero exit (rc=$RC)" $?
grep -q 'PubMed' <<<"$ERR"; expect "malformed esummary -> PubMed note on stderr" $?
NCBI_API_KEY=k3y-SECRET SHIM_MODE=badkey run search "GENCODE 2023" --source pubmed
[ "$RC" -ne 0 ]; expect "HTTP 400 -> non-zero exit (rc=$RC)" $?
grep -q 'API key invalid' <<<"$ERR"; expect "HTTP 400 -> NCBI's error message surfaced" $?
! grep -q 'k3y-SECRET' <<<"$OUT$ERR"; expect "rejected key (echoed by NCBI) is not printed" $?
SHIM_MODE=429once run search "GENCODE 2023" --source pubmed
expect "HTTP 429 once -> retried and succeeded" "$RC" "rc=$RC err=$ERR"
[ "$(calls esearch.fcgi)" -eq 2 ]; expect "HTTP 429 once -> exactly 2 esearch calls" $?
SHIM_MODE=warn run search "zqxjv the GENCODE[badfield" --source pubmed
expect "dropped terms -> still exit 0 with hits" "$RC" "rc=$RC"
jq -e '.warnings == ["pubmed: phrase not found: zqxjv","pubmed: phrase ignored: the","pubmed: message: [badfield"]
       and .pubmed_query_translation == "\"GENCODE\"[All Fields]"' <<<"$OUT" >/dev/null
expect "dropped terms -> warnings + pubmed_query_translation in JSON" $?
grep -q 'phrase not found: zqxjv' <<<"$ERR" && grep -q 'query ran as: "GENCODE"\[All Fields\]' <<<"$ERR"
expect "dropped terms -> stderr note names the term and the translated query" $?
run search "GENCODE 2023" --source pubmed
[ "$(jq -c '.warnings' <<<"$OUT")" = '[]' ]; expect "clean query -> warnings []" $?
SHIM_MODE=empty run search "zzqq" --source pubmed
expect "genuinely empty query -> exit 0" "$RC" "rc=$RC"
[ "$(jq '.count' <<<"$OUT")" -eq 0 ] && [ "$(calls esummary.fcgi)" -eq 0 ]
expect "genuinely empty query -> count 0, no esummary call" $?

echo "-- search: backend selection --"
S2_API_KEY=x run search "GENCODE 2023"
[ "$(calls eutils)" -eq 0 ] && [ "$(jq -c '.query_sources' <<<"$OUT")" = '["s2"]' ]
expect "S2 key configured, no --source -> default all, PubMed not queried" $?
S2_API_KEY=x run search "GENCODE 2023" --source pubmed,s2
[ "$(jq -c '.query_sources' <<<"$OUT")" = '["pubmed","s2"]' ]; expect "--source pubmed,s2 -> pubmed + s2" $?
[ "$(jq '.count' <<<"$OUT")" -eq 3 ]; expect "cross-source dedupe: 2 pubmed + 3 s2 (1 same DOI, 1 same PMID only) -> 3" $?
[ "$(jq -c '[.results[] | select(.pmid=="36420896")][0].sources' <<<"$OUT")" = '["pubmed","s2"]' ]
expect "same DOI (case differs) -> one record found by pubmed + s2" $?
[ "$(jq -c '[.results[] | select(.pmid=="37248244")][0] | [.sources, .found_by]' <<<"$OUT")" = '[["pubmed","s2"],2]' ]
expect "same PMID, one side has no DOI -> one record found by pubmed + s2" $?
S2_API_KEY=x run search "GENCODE 2023" --source all,pubmed
jq -e '.query_sources | index("pubmed") and index("s2")' <<<"$OUT" >/dev/null; expect "--source all,pubmed -> pubmed joins the default set" $?
if [ "$have_yaml" -eq 1 ]; then
  printf 'lit:\n  default_source: "pubmed"\n' >"$TMP/dflt.yml"
  NEXUS_CONFIG="$TMP/dflt.yml" run search "GENCODE 2023"
  [ "$(jq -c '.query_sources' <<<"$OUT")" = '["pubmed"]' ]; expect "lit.default_source: pubmed -> no --source searches PubMed" $?
else
  echo "  SKIP lit.default_source assertion: no python3 with PyYAML (config/load.sh needs it)"
fi
run search "GENCODE 2023" --source s2
[ "$RC" -eq 3 ]; expect "--source s2 without a key -> exit 3 (rc=$RC)" $?
run search "GENCODE 2023" --source bogus
[ "$RC" -ne 0 ]; expect "--source bogus rejected" $?
run search "GENCODE 2023" --source pubmed --limit 0
[ "$RC" -ne 0 ] && [ "$(calls eutils)" -eq 0 ]; expect "--limit 0 rejected before any request" $?

echo "-- library dedupe --"
mkdir -p "$NEXUS_ROOT/.bipartite"
printf '%s\n' '{"id":"x","doi":"","pmid":"37248244","title":"t"}' >"$NEXUS_ROOT/.bipartite/refs.jsonl"
run search "GENCODE 2023" --source pubmed
[ "$(jq -r '.results[] | select(.pmid=="37248244") | .in_library' <<<"$OUT")" = true ]
expect "in_library by PMID (library record has no DOI)" $?
[ "$(jq -r '.results[] | select(.pmid=="36420896") | .in_library' <<<"$OUT")" = false ]
expect "not in library -> in_library false" $?
rm -f "$NEXUS_ROOT/.bipartite/refs.jsonl"

echo "-- add --"
LIB="$NEXUS_ROOT/.bipartite/refs.jsonl"
run add 36420896
expect "add PMID -> exit 0" "$RC" "rc=$RC err=$ERR"
jq -e 'select(.pmid=="36420896" and .doi=="10.1093/nar/gkac1071" and .pmcid=="PMC9825462"
        and .source.type=="pubmed" and .id=="Frankish2023-pubmed" and .published.year==2023
        and .authors[0]=={"first":"A","last":"Frankish"}
        and .authors[2]=={"first":"","last":"GENCODE Consortium"})' "$LIB" >/dev/null
expect "record: pmid, doi, pmcid, id, year, parsed + collective authors" $?
jq -e 'select(.abstract=="BACKGROUND: GENCODE produces <high> quality annotation. RESULTS: Genes & transcripts.")' "$LIB" >/dev/null
expect "abstract: labelled sections, entities decoded, whitespace squeezed" $?
run add 10.1093/nar/gkac1071
[ "$RC" -eq 0 ] && [ "$(jq -s length "$LIB")" -eq 1 ] && grep -q 'already in library' <<<"$ERR"
expect "add same paper by DOI (no S2 key, via OpenAlex) -> not duplicated" $?
grep -q 'filter=doi:10.1093/nar/gkac1071' "$CURL_LOG"; expect "keyless DOI resolved through OpenAlex" $?
run add PMID:36420896
[ "$(jq -s length "$LIB")" -eq 1 ]; expect "add PMID:<n> form -> dedupe by PMID" $?
printf '%s\n' '{"id":"y","doi":"","pmid":"37248244","title":"t"}' >>"$LIB"
run add 37248244
[ "$(jq -s length "$LIB")" -eq 2 ] && grep -q 'already in library (pmid:37248244)' <<<"$ERR"
expect "add PMID already in library by PMID only (no DOI on record) -> refused" $?
run add CorpusId:123
[ "$RC" -eq 3 ]; expect "S2 id without S2 key -> exit 3 with guidance (rc=$RC)" $?

echo "-- status --"
run status
expect "status exit 0 with no key (PubMed is keyless)" "$RC" "rc=$RC"
jq -e '.pubmed.configured and .default_source=="all" and .pubmed.rate_limit=="3/s" and .search_available' <<<"$OUT" >/dev/null
expect "status JSON: pubmed configured, default all, 3/s" $?
NCBI_API_KEY=k3y-SECRET run status
jq -e '.pubmed.api_key and .pubmed.origin=="env:NCBI_API_KEY" and .pubmed.rate_limit=="10/s"' <<<"$OUT" >/dev/null
expect "status with NCBI_API_KEY: origin env, 10/s" $?
! grep -q 'k3y-SECRET' <<<"$OUT$ERR"; expect "status never prints the key" $?

echo "-- live E-utilities (LIT_LIVE=0 to skip) --"
if [ "${LIT_LIVE:-1}" = 0 ]; then
  echo "  skip live check (LIT_LIVE=0)"
elif ! "$REAL_CURL" -sS --max-time 10 -o /dev/null 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/einfo.fcgi?retmode=json' 2>/dev/null; then
  echo "  SKIP live check: eutils.ncbi.nlm.nih.gov unreachable from this host"
else
  OUT=$(bash "$LIT" search "GENCODE reference annotation human mouse genomes" --source pubmed --limit 3 2>"$TMP/err"); RC=$?
  n=$(jq '.count' <<<"$OUT" 2>/dev/null)
  [ "$RC" -eq 0 ] && [ "${n:-0}" -gt 0 ]
  expect "live PubMed search returns hits (rc=$RC count=${n:-none})" $? "$(head -c 300 "$TMP/err")"
  jq -e '.results[0].pmid | test("^[0-9]+$")' <<<"$OUT" >/dev/null 2>&1
  expect "live result carries a numeric PMID" $?
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL TESTS PASSED ($pass assertions)"
  exit 0
fi
echo "$fail FAILED, $pass passed"
exit 1
