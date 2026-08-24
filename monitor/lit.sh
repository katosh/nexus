#!/usr/bin/env bash
# monitor/lit.sh — nexus literature-research tool (backs `ng lit`).
#
# Native, on-demand literature discovery for Claude workers. Finds papers
# by CONTENT relevance across Semantic Scholar (S2), ASTA (Allen AI), and
# OpenAlex, deduplicated against the nexus reference library, and can pull
# a paper's metadata into that library. Reimplements the subset of
# `bipartite` (bip) utilities the nexus needs as plain curl+jq — ZERO
# dependency on the operator-local `bip` binary, so it ships in nexus-code
# and works in any operator's clone.
#
# The three backends are COMPLEMENTARY, not redundant: ASTA and S2 rank by
# semantic/citation relevance over the S2 graph; OpenAlex ranks by its own
# `relevance_score` and needs NO KEY (S2 keys in practice require a
# contact-form request with no guaranteed turnaround, and the
# unauthenticated S2 pool 429s under real load), covers a much broader
# corpus, and adds the citation graph plus institution/funder metadata.
# `--source all` (the default) queries every backend that is usable, dedups
# the union, and FUSES the per-backend rankings (see cmd_search) —
# comprehensiveness is the point, so OpenAlex joins S2/ASTA, it never
# replaces them.
#
# The backends' relevance scores are NOT commensurable, so nothing here ever
# compares them; fusion is over RANKS only.
#
# Subcommands:
#   ng lit status                      keys, library, index — and what to fix
#   ng lit search "<query>" [flags]    content-relevance discovery (S2 + ASTA + OpenAlex)
#   ng lit add <DOI|S2-id|openalex:Wid> [flags]   fetch metadata + append to the library
#   ng lit setup                       print the exact setup / key-acquisition refs
#
# search flags:
#   --source s2|asta|openalex|both|all   (default all)   pick discovery backend(s)
#                                                          ("both" = s2+asta, legacy)
#   --limit N               (default 10)      max results per source
#   --year A:B                                publication-year filter
#   --human                                   human-readable (default: JSON)
#
# add flags:
#   --human                                   human-readable confirmation
#
# Keys are resolved per-source from (first hit wins):
#   1. env            S2_API_KEY            / ASTA_API_KEY
#   2. nexus config   lit.s2_api_key        / lit.asta_api_key   (config/nexus.yml)
#   3. legacy bip     s2_api_key            / asta_api_key       (.config/bip/config.yml)
# OpenAlex needs no key — it is queried with a `mailto` (the "polite
# pool"), resolved from `lit.openalex_mailto`, falling back to
# `notifications.email.address` (config/nexus.yml).
#
# An unconfigured KEYED source (s2/asta) is SKIPPED WITH A NOTE — never a
# silent hang and never a hard failure of the whole command. OpenAlex is
# never "unconfigured": it works unauthenticated, so it is always attempted
# when requested.
#
# SEARCH RESULT STATES — `status` is the FIRST field of every response, and
# the three values must never be conflated (your-org/nexus-code#588):
#
#   status    meaning                                  exit   count:0 means
#   ------    ---------------------------------------  ----   -------------------
#   ok        every requested backend was searched      0     nothing matched the
#                                                             query AS ASKED — not
#                                                             a verified absence
#   partial   >=1 backend failed or was skipped, OR     0     NOTHING — incomplete
#             the zero-result probe could not run
#   error     the query itself failed                   2     (no `count` key)
#
# `partial` has TWO causes and the backend lists only witness one of them: an
# unrunnable probe sets `partial` with `failed_backends` AND `skipped_backends`
# both EMPTY. Read `probe.state` (`not_run` | `hits` | `empty` | `inconclusive`)
# to tell them apart — a caller inspecting only the backend sets finds nothing
# wrong and concludes nothing is (your-org/nexus-code#600 item 3).
#
# `ok` + `count: 0` is the strongest thing this command can honestly say, and
# it is still not "the literature is silent". Every backend ANDs the query
# terms, so an empty conjunction and an empty literature are the SAME
# observation; no field, and no probe this file runs, separates them. The
# summary therefore reports what was observed and never certifies the zero
# (your-org/nexus-code#596 review).
#
# On `error` the response carries NO `count` and NO `results` — `.count` reads
# null, never 0. A well-formed empty result set is precisely how a broken
# search gets read as an empty literature, so an error is never dressed as
# one. `summary` states the case in one sentence for an agent to read.
#
# The subtle state is `error.kind: query_over_constrained`. Every backend ANDs
# the query terms, so a long query returns a REAL, well-formed zero — S2's
# total for one on-topic query walked 8616 -> 136 -> 21 -> 2 -> 0 from 7 to 22
# words, HTTP 200 throughout. No response field distinguishes that from a
# silent literature, so it is settled by MEASUREMENT: see _relax_probe. The
# measurement is LEAVE-ONE-OUT over the query's canonical content-term SET, so
# it is invariant under re-ordering the terms (your-org/nexus-code#600); the
# coverage it achieved is reported in `probe`, never assumed.
#
# Secrets: keys are read, never printed. Errors are scrubbed of the key.
# Docs: reference/literature.md (acquisition + setup). Skill: nexus.lit.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_cfg="$_script_dir/../config/load.sh"

DOCS_REF="docs/reference/literature.md"
SKILL_REF="skills/nexus.lit/SKILL.md"
S2_API="https://api.semanticscholar.org/graph/v1"
ASTA_API="https://asta-tools.allen.ai/mcp/v1"
OPENALEX_API="https://api.openalex.org"

# OpenAlex rejects a search string over this many characters with HTTP 400
# ("Your search is too long (N characters; the limit is 1500)"). Measured
# live, 2026-07-29. Used as a PRE-FLIGHT so an over-long query is named as a
# query error before any request is spent; the response-shape check in
# _openalex_search is the backstop if the published limit ever moves.
OPENALEX_MAX_QUERY_CHARS=1500

# A zero-hit search over this many CONTENT TERMS is not trusted as a real
# zero without the relaxation probe below: the backends AND their terms, so a
# long conjunction goes empty because it is over-constrained, not because
# the literature is silent (your-org/nexus-code#588).
#
# Counted over content terms — stopwords dropped, deduplicated — rather than
# whitespace words, because `of`/`in`/`the` constrain nothing and must not
# decide whether a zero gets corroborated (your-org/nexus-code#600 item 2 is
# the remaining half of that: a genuinely short query is still unprobed).
LIT_PROBE_MIN_TERMS=${LIT_PROBE_MIN_TERMS:-7}

# Leave-one-out is O(terms) requests on the zero-result path, so it is
# capped: at most this many single-term drops are tried, taken in canonical
# order, stopping at the first one that hits. Lower it to trade detection for
# latency (your-org/nexus-code#600 item 5); a capped-out probe reports the
# coverage it actually achieved rather than implying it tried everything.
LIT_PROBE_MAX_DROPS=${LIT_PROBE_MAX_DROPS:-6}

# Seconds to wait BETWEEN probes (never before the first, so a query settled by
# its first drop pays nothing). Measured, 2026-07-30: firing the drops
# back-to-back trips S2's per-second limit — `S2: Too Many Requests` — where
# the old one-request probe did not. That fails safe (the search degrades to
# `partial` / probe `inconclusive`, never to a confident zero) but it turns
# clean zeros into unverified ones, so the burst is paced instead. Set to 0 in
# fixtures, where the backend is a stub.
LIT_PROBE_DELAY_SECS=${LIT_PROBE_DELAY_SECS:-1}

# Dropped before the content-term set is built. A stopword inside a
# conjunction is not what makes it too narrow, so spending a probe on
# removing one measures nothing.
LIT_PROBE_STOPWORDS="a an and are as at be been between by during for from
has have how in into is it its of on onto or over than that the their then
there these this to under upon via was were what when where which while with
within without"

die() { printf 'lit: %s\n' "$*" >&2; exit 1; }
note() { printf 'lit: %s\n' "$*" >&2; }

# Both probe tunables are read from the environment, so a typo would otherwise
# surface as a jq parse error deep inside a search. Fail here, by name.
[[ "$LIT_PROBE_MIN_TERMS" =~ ^[0-9]+$ ]] || die "LIT_PROBE_MIN_TERMS must be an integer (got: $LIT_PROBE_MIN_TERMS)"
[[ "$LIT_PROBE_MAX_DROPS" =~ ^[0-9]+$ ]] || die "LIT_PROBE_MAX_DROPS must be an integer (got: $LIT_PROBE_MAX_DROPS)"
[[ "$LIT_PROBE_DELAY_SECS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "LIT_PROBE_DELAY_SECS must be a number (got: $LIT_PROBE_DELAY_SECS)"

# Does a backend's error message indicate the QUERY is at fault (not the
# backend)? A query fault is not retryable and invalidates every backend's
# zero equally, so it is classified apart from a transport/rate failure.
_is_query_error() {
    grep -qiE 'too long|too large|query.*(invalid|exceed)|exceeds.*(limit|length)' <<<"${1:-}"
}

# Canonical CONTENT-TERM SET of a query, one term per line: whitespace tokens
# lowercased, stripped of leading/trailing punctuation, stopwords dropped,
# deduplicated, and LC_ALL=C sorted.
#
# The sort is load-bearing (your-org/nexus-code#600). Every probe query below,
# the order the drops are tried in, and therefore the verdict, are functions of
# THIS list — so they depend on the query's term SET, not on the order the
# caller happened to type the terms in. The relaxation this replaced took the
# query's first six whitespace tokens, which made the verdict positional: the
# same eight terms re-ordered landed on different branches, with the same
# corpus and the same ground truth.
# Punctuation is trimmed against an EXPLICIT ASCII list rather than
# `[^[:alnum:]]`, because that class is locale-dependent and awk here inherits
# the ambient locale: under `LC_ALL=C` it treats every byte of a multi-byte
# character as non-alphanumeric, so `γδ` is trimmed away entirely and
# `α-synuclein` becomes `synuclein`. Greek letters are common enough in
# biological terms that the term SET would then depend on the environment the
# tool happened to run in. No multi-byte character is ever in this list, so the
# trim stops at one and the term survives under any locale.
#
# Non-ASCII punctuation is handled only where it stands ALONE as its own token
# (`— dash —`), by exact whole-token match against LIT_PROBE_UPUNCT. That is
# deliberately narrower than trimming it off word edges: a byte-wise trim would
# alias under LC_ALL=C, where `substr` yields bytes — the trailing byte of the
# Cyrillic `М` (D0 9C) is the trailing byte of `“` (E2 80 9C), so trimming by
# byte would eat letters out of real words. A curly-quoted token glued to a
# word (`“hedgehog`) therefore survives as a content term: deterministic and
# order-invariant, just not trimmed. Declared, not silently assumed.
LIT_PROBE_UPUNCT='— – ‒ ― “ ” ‘ ’ … • · « » ‹ ›'

_probe_terms() {
    printf '%s' "$*" | awk -v stop="$LIT_PROBE_STOPWORDS" -v upunct="$LIT_PROBE_UPUNCT" '
        BEGIN { n = split(stop, s, /[ \n]+/); for (i = 1; i <= n; i++) if (s[i] != "") S[s[i]] = 1
                m = split(upunct, u, /[ \n]+/); for (i = 1; i <= m; i++) if (u[i] != "") U[u[i]] = 1
                punct = "!\"#$%&'"'"'()*+,-./:;<=>?@[\\]^_`{|}~" }
        { for (i = 1; i <= NF; i++) {
              t = tolower($i)
              while (t != "" && index(punct, substr(t, 1, 1)) > 0) t = substr(t, 2)
              while (t != "" && index(punct, substr(t, length(t), 1)) > 0) t = substr(t, 1, length(t) - 1)
              if (t != "" && !(t in S) && !(t in U)) print t
          } }' | LC_ALL=C sort -u
}

# The leave-one-out relaxation: every term in $2.. except $1, space-joined,
# in the canonical order they arrive in.
_probe_query_without() {
    local drop="$1"; shift
    local t out=""
    for t in "$@"; do
        [[ "$t" == "$drop" ]] && continue
        out="${out:+$out }$t"
    done
    printf '%s' "$out"
}

command -v jq  >/dev/null 2>&1 || die "jq not found (required)"
command -v curl >/dev/null 2>&1 || die "curl not found (required)"

# --- nexus root -------------------------------------------------------------
_nexus_root() {
    if [[ -n "${NEXUS_ROOT:-}" ]]; then printf '%s' "$NEXUS_ROOT"; return; fi
    local r; r=$("$_cfg" nexus.root 2>/dev/null) || r=""
    if [[ -n "$r" ]]; then printf '%s' "${r/#\~/$HOME}"; return; fi
    # script lives at <root>/monitor/lit.sh
    printf '%s' "$(cd "$_script_dir/.." && pwd)"
}
ROOT="$(_nexus_root)"

# --- key resolution ---------------------------------------------------------
# $1 = s2|asta  -> prints key (empty if none configured). Never logs it.
_lit_key() {
    local svc="$1" envv cfgk bipk val
    case "$svc" in
        s2)   envv=S2_API_KEY;   cfgk=lit.s2_api_key;   bipk=s2_api_key   ;;
        asta) envv=ASTA_API_KEY; cfgk=lit.asta_api_key; bipk=asta_api_key ;;
        *) return 1 ;;
    esac
    val="${!envv:-}"; [[ -n "$val" ]] && { printf '%s' "$val"; return; }
    val=$("$_cfg" "$cfgk" 2>/dev/null) || val=""
    [[ -n "$val" ]] && { printf '%s' "$val"; return; }
    local bipcfg="$ROOT/.config/bip/config.yml"
    if [[ -f "$bipcfg" ]]; then
        val=$(sed -nE "s/^[[:space:]]*${bipk}:[[:space:]]*(.+)$/\1/p" "$bipcfg" | head -1)
        val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    fi
    printf '%s' "$val"
}

# Where the key came from, for `status` (no value printed).
_lit_key_origin() {
    local svc="$1" envv cfgk bipk
    case "$svc" in
        s2)   envv=S2_API_KEY;   cfgk=lit.s2_api_key;   bipk=s2_api_key   ;;
        asta) envv=ASTA_API_KEY; cfgk=lit.asta_api_key; bipk=asta_api_key ;;
    esac
    [[ -n "${!envv:-}" ]] && { printf 'env:%s' "$envv"; return; }
    local v; v=$("$_cfg" "$cfgk" 2>/dev/null) || v=""
    [[ -n "$v" ]] && { printf 'config:%s' "$cfgk"; return; }
    local bipcfg="$ROOT/.config/bip/config.yml"
    if [[ -f "$bipcfg" ]] && grep -qE "^[[:space:]]*${bipk}:[[:space:]]*\S" "$bipcfg"; then
        printf 'legacy-bip:%s' "$bipk"; return
    fi
    printf 'none'
}

# OpenAlex needs no key, only a polite-pool `mailto`. Resolution order:
# config lit.openalex_mailto -> notifications.email.address -> empty
# (still works, just outside the polite pool).
_lit_openalex_mailto() {
    local v
    v=$("$_cfg" lit.openalex_mailto 2>/dev/null) || v=""
    [[ -n "$v" ]] && { printf '%s' "$v"; return; }
    v=$("$_cfg" notifications.email.address 2>/dev/null) || v=""
    printf '%s' "$v"
}

# --- library ----------------------------------------------------------------
_lit_library() {
    local p; p=$("$_cfg" lit.library_path 2>/dev/null) || p=""
    if [[ -n "$p" ]]; then printf '%s' "${p/#\~/$HOME}"; return; fi
    printf '%s/.bipartite/refs.jsonl' "$ROOT"
}

# DOIs already in the library (lowercased), one per line.
_lib_dois() {
    local lib; lib="$(_lit_library)"
    [[ -f "$lib" ]] || return 0
    jq -r 'select(.doi != null and .doi != "") | .doi | ascii_downcase' "$lib" 2>/dev/null
}

# --- setup / not-configured guidance ---------------------------------------
_setup_refs() {
    cat >&2 <<EOF
lit: literature-search setup — OpenAlex needs no key and always works
(search still runs with zero setup). For S2/ASTA relevance ranking and
citation context, obtain and install an API key for either (an
unconfigured KEYED backend is simply skipped):

  Semantic Scholar (S2)  — free key, instant:
      request at  https://www.semanticscholar.org/product/api#api-key-form
  ASTA (Allen AI)        — request via the ASTA program (see the docs page).

Install the key one of three ways (first found wins):
  1. export S2_API_KEY=...      (or ASTA_API_KEY=...)   in the environment
  2. add to config/nexus.yml:
         lit:
           s2_api_key: "..."     # config/nexus.yml is gitignored — safe
           asta_api_key: "..."
           openalex_mailto: "..."   # optional: polite-pool contact email
  3. legacy: .config/bip/config.yml  s2_api_key: / asta_api_key:

Full instructions, key-acquisition links, and library setup:
  $DOCS_REF
  $SKILL_REF   (when to use the tool; cite findings in scientific reports)
EOF
}

# ===========================================================================
# status
# ===========================================================================
cmd_status() {
    local human=0; [[ "${1:-}" == "--human" ]] && human=1
    local lib; lib="$(_lit_library)"
    # `grep -c` prints `0` on no match AND exits 1 — the old `|| echo 0`
    # made libn "0\n0" for an EMPTY library, which `--json` then fed to
    # `jq --argjson` as invalid JSON (issue #725).
    local libn=0
    [[ -f "$lib" ]] && { libn=$(grep -c '' "$lib" 2>/dev/null) || libn=0; }
    [[ "$libn" =~ ^[0-9]+$ ]] || libn=0
    local s2o asta_o
    s2o=$(_lit_key_origin s2); asta_o=$(_lit_key_origin asta)
    local s2_ok=no asta_ok=no
    [[ "$s2o" != none ]] && s2_ok=yes
    [[ "$asta_o" != none ]] && asta_ok=yes
    local oamailto; oamailto="$(_lit_openalex_mailto)"
    if [[ $human -eq 1 ]]; then
        printf 'Nexus literature tool\n'
        printf '  library:     %s\n' "$lib"
        printf '  references:  %s\n' "$libn"
        printf '  S2 key:      %s (%s)\n'   "$s2_ok"   "$s2o"
        printf '  ASTA key:    %s (%s)\n'   "$asta_ok" "$asta_o"
        printf '  OpenAlex:    yes (no key required; polite-pool mailto: %s)\n' "${oamailto:-none set}"
        if [[ $s2_ok == no && $asta_ok == no ]]; then
            printf '  status:      partial — S2/ASTA unconfigured (relevance ranking + `add` unavailable); search still works via OpenAlex\n'
            _setup_refs
        else
            printf '  status:      ready (search uses S2/ASTA where configured, plus OpenAlex always)\n'
        fi
    else
        jq -n --arg lib "$lib" --argjson n "$libn" \
              --arg s2 "$s2_ok" --arg s2o "$s2o" \
              --arg asta "$asta_ok" --arg astao "$asta_o" \
              --arg oam "$oamailto" \
              '{library:$lib, references:$n,
                s2:{configured:($s2=="yes"), origin:$s2o},
                asta:{configured:($asta=="yes"), origin:$astao},
                openalex:{configured:true, key_required:false, mailto:$oam},
                configured: ($s2=="yes" or $asta=="yes"),
                search_available: true}'
        [[ $s2_ok == no && $asta_ok == no ]] && _setup_refs
    fi
    return 0
}

# ===========================================================================
# search
# ===========================================================================
# S2 relevance search -> normalized JSON array on stdout.
# Exit: 0 = searched (array may legitimately be empty), 1 = backend failed,
#       2 = the QUERY was rejected (see _is_query_error).
_s2_search() {
    local q="$1" limit="$2" year="$3" key="$4"
    local url="$S2_API/paper/search"
    local fields="title,year,venue,authors,externalIds,abstract,citationCount,url"
    local args=(-sS --max-time 40 -G "$url"
        --data-urlencode "query=$q"
        --data-urlencode "limit=$limit"
        --data-urlencode "fields=$fields"
        -H "x-api-key: $key")
    [[ -n "$year" ]] && args+=(--data-urlencode "year=${year/:/-}")
    local resp; resp=$(curl "${args[@]}" 2>/dev/null) || { note "S2: request failed"; return 1; }
    if ! printf '%s' "$resp" | jq -e 'has("data")' >/dev/null 2>&1; then
        # A zero-hit S2 search answers `{"total": 0, "offset": 0}` — with NO
        # `data` key at all (measured live, 2026-07-29). That is a SUCCESSFUL
        # search that matched nothing, and it must not be reported as a broken
        # backend: doing so turned every genuine S2 zero into a phantom
        # `failed_backends: ["s2"]` and made real emptiness indistinguishable
        # from breakage — the inverse of the defect in
        # your-org/nexus-code#588, in the same code path.
        if printf '%s' "$resp" | jq -e '.total == 0' >/dev/null 2>&1; then
            printf '[]'; return 0
        fi
        local msg; msg=$(printf '%s' "$resp" | jq -r '.error // .message // "unexpected response"' 2>/dev/null || echo "unexpected response")
        note "S2: $msg"
        _is_query_error "$msg" && return 2
        return 1
    fi
    printf '%s' "$resp" | jq '[.data[] | {
        source: "s2",
        id: .paperId,
        title: .title,
        year: .year,
        venue: .venue,
        doi: (.externalIds.DOI // null),
        citations: .citationCount,
        url: .url,
        authors: ([.authors[]?.name] | join(", "))
    }]'
}

# ASTA relevance search -> normalized JSON array on stdout.
# MCP JSON-RPC (tools/call search_papers_by_relevance) over an SSE response.
# The result is `.result.content[]`, ONE {type,text} item per paper, each
# `.text` a JSON paper object. A `fields` argument is required to get more
# than {paperId,title}; field names mirror Semantic Scholar's graph API.
_asta_search() {
    local q="$1" limit="$2" key="$3"
    local body
    body=$(jq -n --arg k "$q" --argjson l "$limit" \
        '{jsonrpc:"2.0", id:1, method:"tools/call",
          params:{name:"search_papers_by_relevance",
                  arguments:{keyword:$k, limit:$l,
                             fields:"title,year,venue,authors,externalIds,citationCount,url"}}}')
    local resp
    resp=$(curl -sS --max-time 60 -X POST "$ASTA_API" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -H "x-api-key: $key" \
        -d "$body" 2>/dev/null) || { note "ASTA: request failed"; return 1; }
    # SSE: take the JSON payload of the last `data:` event.
    local data
    data=$(printf '%s\n' "$resp" | sed -nE 's/^data:[[:space:]]*(.+)$/\1/p' | tail -1)
    [[ -z "$data" ]] && { note "ASTA: no result event (heartbeat-only stream — key rejected or empty?)"; return 1; }
    if printf '%s' "$data" | jq -e '.error' >/dev/null 2>&1; then
        note "ASTA: $(printf '%s' "$data" | jq -r '.error.message // "error"')"; return 1
    fi
    printf '%s' "$data" | jq '[ .result.content[]?.text | fromjson ] | [.[] | {
        source: "asta",
        id: .paperId,
        title: .title,
        year: .year,
        venue: .venue,
        doi: (.externalIds.DOI // null),
        citations: .citationCount,
        url: (.url // null),
        authors: ([.authors[]?.name] | join(", "))
    }]' 2>/dev/null || { note "ASTA: could not parse result"; return 1; }
}

# OpenAlex relevance search -> normalized JSON array on stdout. Needs NO
# key; `mailto` is sent for the polite pool (higher, more reliable rate
# limit — OpenAlex's own recommendation, not an auth mechanism).
_openalex_search() {
    local q="$1" limit="$2" year="$3" mailto="$4"
    local select="id,doi,title,display_name,publication_year,primary_location,authorships,cited_by_count"
    local args=(-sS --max-time 40 -G "$OPENALEX_API/works"
        --data-urlencode "search=$q"
        --data-urlencode "per-page=$limit"
        --data-urlencode "select=$select")
    [[ -n "$mailto" ]] && args+=(--data-urlencode "mailto=$mailto")
    if [[ -n "$year" ]]; then
        local ya="${year%%:*}" yb="${year##*:}"
        args+=(--data-urlencode "filter=from_publication_date:${ya}-01-01,to_publication_date:${yb}-12-31")
    fi
    local resp; resp=$(curl "${args[@]}" 2>/dev/null) || { note "OpenAlex: request failed"; return 1; }
    if ! printf '%s' "$resp" | jq -e '.results' >/dev/null 2>&1; then
        # `.message` carries the detail on a 400 ("Your search is too long
        # (N characters; the limit is 1500)"); `.error` is the short form.
        local msg; msg=$(printf '%s' "$resp" | jq -r '[.error, .message] | map(select(. != null)) | join(" — ") | select(length>0) // empty' 2>/dev/null)
        [[ -z "$msg" ]] && msg="unexpected response (rate limited or unreachable)"
        note "OpenAlex: $msg"
        # A rejected query is the CALLER's fault and unretryable — a different
        # state from a backend that merely fell over.
        _is_query_error "$msg" && return 2
        return 1
    fi
    printf '%s' "$resp" | jq '[.results[] | {
        source: "openalex",
        id: (.id // "" | sub("^https://openalex\\.org/"; "")),
        title: (.title // .display_name),
        year: .publication_year,
        venue: (.primary_location.source.display_name // null),
        doi: (if .doi then (.doi | sub("^https://doi\\.org/"; "")) else null end),
        citations: .cited_by_count,
        url: (.primary_location.landing_page_url // .doi // .id),
        authors: ([.authorships[]?.author.display_name] | join(", "))
    }]'
}

# Merge one backend's relevance-ORDERED result array into the accumulator,
# stamping each record with its 1-based rank WITHIN that backend.
#
# Every backend returns its hits best-first but scores them on an
# INCOMPARABLE scale (S2's score, ASTA's, and OpenAlex's `relevance_score`
# are not commensurable), so rank is the only sound cross-backend signal —
# and it is what the fusion step in cmd_search consumes. Capturing it here,
# before concatenation, is what makes that fusion possible at all.
#   $1 = accumulator JSON array   $2 = this backend's JSON array
_merge_ranked() {
    jq -n --argjson a "$1" --argjson b "$2" \
        '$a + ($b | to_entries | map(.value + {rank: (.key + 1)}))'
}

# Relaxation probe — the evidence that separates "genuinely nothing matched"
# from "your query was over-constrained" (your-org/nexus-code#588).
#
# WHY a probe rather than a length threshold: measurement showed there is no
# server-side rejection at the length that triggers the bug. Every backend
# ANDs the query terms, so a long query returns a real, well-formed zero —
# S2 total went 8616 -> 136 -> 21 -> 2 -> 0 as one on-topic query grew from 7
# to 22 words, HTTP 200 throughout. The zero is arithmetically true of the
# conjunction and substantively false about the literature. No response field
# distinguishes the two cases, and any word-count cutoff would be a guess.
#
# So when a search comes back empty, re-run the search RELAXED against a
# backend that already answered. That is exactly the manual retry the reporter
# performed ("retried shorter and returning results — so the literature was
# there"); doing it in-tool turns the guess into a measurement and yields the
# actionable remedy for free.
#
# WHICH relaxation — LEAVE-ONE-OUT, not a prefix (your-org/nexus-code#600).
# The first design re-ran the query's first six WHITESPACE TOKENS. A
# conjunction is commutative; a positional prefix is not, so the same eight
# terms re-ordered landed on opposite branches (error vs. clean zero) with the
# same corpus and the same ground truth. What replaced it drops ONE content
# term at a time from the canonical term SET (`_probe_terms`), which makes
# every probe query, and the verdict, invariant under re-ordering.
#
# Leave-one-out also says something a prefix cannot. A prefix discards most of
# the conjunction, so a hit establishes only "the broad topic is populated" —
# indistinguishable from a real conjunctive gap inside a populated topic, and
# its remedy steers the caller at a broader question than the one they asked.
# A single-term drop is the CLOSEST query to the one asked that still hits, so
# a hit NAMES the binding term and the remedy is that same near-query. When no
# tried drop hits, the honest statement is narrower and still useful: no
# single term explains the zero.
#
# It runs only on the zero-result path, costs at most LIT_PROBE_MAX_DROPS
# requests (early-exit at the first hit), and can only ever ESCALATE a zero to
# an error — never suppress or downgrade a real hit.
#
# The probe holds the ENVIRONMENT fixed — same backend, same moment, same
# `--year` filter — so a hit is attributable to the query and not to the
# conditions. Dropping the year filter here would let a search narrowed by
# year be blamed on its wording.
#
# What it does NOT hold fixed is the query text. The probe searches the
# caller's query REDUCED to its canonical content terms (lowercased,
# punctuation-trimmed, stopwords dropped, deduplicated, re-ordered) minus one
# term — not the caller's query minus one term. The named term is therefore
# the one whose removal recovered hits FROM THAT REDUCTION, and the messages
# say so. The reduction is otherwise benign, with one exception that is not:
# it strips quotes, and an un-quoted phrase is a strictly broader search, so
# on a phrase query ANY drop can hit and the tool would name whichever term it
# tried first — a confidently wrong culprit. So a query containing `"` is not
# probed at all; it reports `probe.state: inconclusive`,
# `probe.reason: quoted_phrase` and claims nothing (skeptic req-001 Q2).
#
#   $1=probe query $2=backend $3=limit $4=year $5=s2key $6=astakey $7=mailto
# Prints the probe's hit count on success; prints nothing and returns 1 if
# the probe itself could not be run (then nothing is claimed either way).
_relax_probe() {
    local pq="$1" backend="$2" limit="$3" year="$4" s2key="$5" astakey="$6" mailto="$7"
    [[ -n "$pq" ]] || return 1
    local out
    case "$backend" in
        openalex) out=$(_openalex_search "$pq" "$limit" "$year" "$mailto" 2>/dev/null) || return 1 ;;
        s2)       out=$(_s2_search       "$pq" "$limit" "$year" "$s2key"  2>/dev/null) || return 1 ;;
        # ASTA's MCP relevance call takes no year filter, so a year-filtered
        # search cannot be probed on ASTA without changing two variables.
        asta)     [[ -n "$year" ]] && return 1
                  out=$(_asta_search      "$pq" "$limit" "$astakey"  2>/dev/null) || return 1 ;;
        *) return 1 ;;
    esac
    jq 'length' <<<"$out" 2>/dev/null || return 1
}

# Emit state (3): the QUERY is at fault, so there is NO result to report.
#
# This deliberately emits NO `count` and NO `results` key. A well-formed
# empty result set is precisely the failure mode of your-org/nexus-code#588 —
# `count: 0` reads as a finding about the world, and an agent will write "to
# our knowledge, no prior work addresses X" on the strength of it. A caller
# that reaches for `.count` here gets `null`, not `0`, and the command exits
# non-zero. Loud beats plausible.
#
#   $1=human $2=kind $3=message $4=remedy $5=query
#   $6=used $7=failed $8=skipped $9=rejected   (space-separated backend names)
#   ${10}=probe object as JSON (optional; `null` when no probe was involved) —
#         the same `probe` key the non-error response carries, so a caller can
#         read the evidence as data instead of parsing `error.message`.
_search_error() {
    local human="$1" kind="$2" msg="$3" remedy="$4" query="$5"
    local used="$6" failed="$7" skipped="$8" rejected="$9" probe="${10:-null}"
    local summary="SEARCH FAILED ($kind): $msg. This is NOT a statement about the literature — no conclusion about what exists may be drawn from it."
    if [[ "$human" -eq 1 ]]; then
        printf 'SEARCH FAILED — %s\n' "$kind"
        printf '  %s\n' "$msg"
        printf '  %s\n' "$remedy"
        printf '  This is NOT a result. No conclusion about the literature may be drawn.\n'
    else
        jq -n --arg st error --arg sum "$summary" --arg k "$kind" --arg m "$msg" \
              --arg rem "$remedy" --arg query "$query" \
              --arg used "$used" --arg failed "$failed" \
              --arg skipped "$skipped" --arg rejected "$rejected" \
              --argjson probe "$probe" \
              'def names: split(" ") | map(select(length>0));
               {status: $st, summary: $sum,
                error: {kind: $k, message: $m, remedy: $rem},
                query: $query,
                query_sources: ($used|names), failed_backends: ($failed|names),
                skipped_backends: ($skipped|names), rejected_backends: ($rejected|names),
                partial: true, probe: $probe}'
    fi
    note "$summary"
}

cmd_search() {
    local q="" source="all" limit=10 year="" human=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) source="$2"; shift 2 ;;
            --limit)  limit="$2";  shift 2 ;;
            --year)   year="$2";   shift 2 ;;
            --human)  human=1; shift ;;
            --*) die "unknown flag: $1" ;;
            *) [[ -z "$q" ]] && q="$1" || q="$q $1"; shift ;;
        esac
    done
    [[ -n "$q" ]] || die "usage: ng lit search \"<query>\" [--source s2|asta|openalex|both|all] [--limit N] [--year A:B] [--human]"
    case "$source" in s2|asta|openalex|both|all) ;; *) die "--source must be s2|asta|openalex|both|all" ;; esac

    # PRE-FLIGHT: a query past OpenAlex's published ceiling is a query error,
    # not a search. Caught before any request is spent, and — critically —
    # reported as an ERROR rather than as an empty result set, so it can never
    # be read as "no literature exists" (your-org/nexus-code#588 state 3).
    if [[ ${#q} -gt $OPENALEX_MAX_QUERY_CHARS ]]; then
        _search_error "$human" "query_too_long" \
            "query is ${#q} characters; the limit is $OPENALEX_MAX_QUERY_CHARS" \
            "Shorten the query to a handful of content terms and search again. NOTHING was established about the literature." \
            "$q" "" "" "" ""
        return 2
    fi

    # "both" is the legacy s2+asta pair (kept for scripts that pin it);
    # "all" (the default) adds OpenAlex on top — additive, never a
    # replacement for the keyed backends.
    local want_s2=0 want_asta=0 want_openalex=0
    case "$source" in
        s2)       want_s2=1 ;;
        asta)     want_asta=1 ;;
        openalex) want_openalex=1 ;;
        both)     want_s2=1; want_asta=1 ;;
        all)      want_s2=1; want_asta=1; want_openalex=1 ;;
    esac

    local s2key astakey oamailto
    s2key="$(_lit_key s2)"; astakey="$(_lit_key asta)"; oamailto="$(_lit_openalex_mailto)"
    # OpenAlex needs no key, so requesting it (directly or via the "all"
    # default) is never a configuration failure — only bail loud when
    # every REQUESTED backend needs a key it doesn't have.
    if [[ $want_openalex -eq 0 && -z "$s2key" && -z "$astakey" ]]; then
        note "no literature backend is configured for --source $source"; _setup_refs; return 3
    fi

    # `skipped` = requested but unusable (no key) — expected, benign.
    # `failed`  = requested, attempted, and the request ERRORED — the caller's
    #             results are incomplete and it must be able to tell. Both are
    #             reported in-band (stdout JSON), not just as stderr notes.
    # `rejected` is the third state: the backend was reached and it refused the
    # QUERY. Unlike `failed` it is not retryable and not backend-specific — it
    # condemns the whole search, so it is tracked separately.
    local results="[]" used=() skipped=() skipped_names=() failed=() rejected=()
    local r rc
    if [[ $want_s2 -eq 1 ]]; then
        if [[ -n "$s2key" ]]; then
            r=$(_s2_search "$q" "$limit" "$year" "$s2key"); rc=$?
            case $rc in
                0) results=$(_merge_ranked "$results" "$r"); used+=(s2) ;;
                2) rejected+=(s2) ;;
                *) failed+=(s2) ;;
            esac
        else
            skipped+=("s2 (no key — set S2_API_KEY or lit.s2_api_key)"); skipped_names+=(s2)
        fi
    fi
    if [[ $want_asta -eq 1 ]]; then
        if [[ -n "$astakey" ]]; then
            r=$(_asta_search "$q" "$limit" "$astakey"); rc=$?
            case $rc in
                0) results=$(_merge_ranked "$results" "$r"); used+=(asta) ;;
                2) rejected+=(asta) ;;
                *) failed+=(asta) ;;
            esac
        else
            skipped+=("asta (no key — set ASTA_API_KEY or lit.asta_api_key)"); skipped_names+=(asta)
        fi
    fi
    if [[ $want_openalex -eq 1 ]]; then
        r=$(_openalex_search "$q" "$limit" "$year" "$oamailto"); rc=$?
        case $rc in
            0) results=$(_merge_ranked "$results" "$r"); used+=(openalex) ;;
            2) rejected+=(openalex) ;;
            *) skipped+=("openalex (request failed — see stderr note)"); failed+=(openalex) ;;
        esac
    fi

    # A rejected query invalidates the whole search: the other backends' zeros
    # were produced from the same bad query, so they establish nothing either.
    if [[ ${#rejected[@]} -gt 0 ]]; then
        _search_error "$human" "query_rejected" \
            "backend(s) ${rejected[*]} rejected the query (${#q} characters, $(wc -w <<<"$q") words)" \
            "Shorten the query to a handful of content terms and search again." \
            "$q" "${used[*]:-}" "${failed[*]:-}" "${skipped_names[*]:-}" "${rejected[*]}"
        return 2
    fi

    # Annotate in_library by DOI (jq --arg is portable; --rawfile is 1.6+),
    # then DEDUPLICATE and FUSE the per-backend rankings into one ordering.
    #
    # This step used to be `unique_by(.doi // .id // .title)`. jq's unique_by
    # SORTS BY THE KEY as a side effect, so the returned list came out ordered
    # alphabetically by DOI string and every backend's relevance ranking was
    # silently discarded — including for a single-backend search. Rank fusion
    # replaces it.
    #
    # Reciprocal-rank fusion (RRF): each backend that returned a paper
    # contributes 1/(k+rank) and the scores are summed. It is the standard
    # remedy here precisely because it consumes RANKS, never scores — which is
    # all that is comparable across backends. Two properties matter:
    #   * agreement wins — a paper returned by two backends outranks one at the
    #     same position in only one. That cross-backend consensus is a real
    #     relevance signal, and a plain mean-of-ranks discards it (a mean would
    #     also *penalise* a paper for being found by a second backend slightly
    #     further down, which is backwards).
    #   * a paper absent from a backend is simply absent from the sum, rather
    #     than being charged a fabricated worst-case rank.
    # k=60 is the constant from the original RRF paper; it damps the very top
    # ranks so no single backend unilaterally owns position 1.
    #
    # The dedup key is the DOI, CASE-FOLDED. OpenAlex lowercases every DOI it
    # returns while S2/ASTA return them as deposited (~1 in 8 carries an
    # uppercase letter), so a case-sensitive key splits one paper into two.
    # Falls back to the backend-local id, then the title, when there is no DOI.
    local doidata; doidata=$(_lib_dois)
    results=$(jq --arg dois "$doidata" '
        def dkey: if ((.doi // "") != "") then (.doi | ascii_downcase)
                  else ((.id // .title // "") | ascii_downcase) end;
        ($dois | split("\n") | map(select(length>0)) ) as $have
        | map(. + {in_library: ((.doi // "" | ascii_downcase) as $d
                 | ($d != "" and ($have | index($d) != null)))})
        | group_by(dkey)
        | map( (sort_by(.rank)) as $g
               # representative record: prefer one carrying a DOI, else best rank
               | ((([$g[] | select((.doi // "") != "")] + $g)[0])
                  + { rrf:       ([$g[] | 1 / (60 + .rank)] | add),
                      rank:      ([$g[] | .rank] | min),
                      mean_rank: (([$g[] | .rank] | add) / ($g | length)),
                      sources:   ([$g[] | .source] | unique),
                      found_by:  ($g | length) }) )
        | sort_by(-.rrf)' <<<"$results")

    for s in "${skipped[@]:-}"; do [[ -n "$s" ]] && note "skipped: $s"; done

    local n; n=$(jq 'length' <<<"$results")

    # No backend contributed at all — nothing was searched, so nothing was
    # established. Previously this still printed `count: 0` alongside a
    # results array, which is the exact shape a caller reads as "no
    # literature exists".
    if [[ ${#used[@]} -eq 0 ]]; then
        _search_error "$human" "no_backend_searched" \
            "every requested backend failed or was skipped (failed: ${failed[*]:-none}; skipped: ${skipped_names[*]:-none})" \
            "Fix or configure a backend and search again." \
            "$q" "" "${failed[*]:-}" "${skipped_names[*]:-}" ""
        return 2
    fi

    # ---- the zero-result fork (your-org/nexus-code#588) --------------------
    # A zero from an over-constrained query is arithmetically true and
    # substantively false. Probe before believing it.
    # probe_state: not_run      short query, or a non-zero result
    #              hits         dropping ONE term recovers papers -> over-constrained
    #              empty        no drop tried recovered anything -> no single term
    #                           explains the zero
    #              inconclusive the probe could not be run -> claim NOTHING
    #
    # Every input to this block is `_probe_terms "$q"` — a SET — so the state
    # it lands in is invariant under re-ordering of the query
    # (your-org/nexus-code#600).
    local probe_hits="" probe_q="" probe_backend="" probe_state=not_run
    local probe_dropped="" probe_tried=0 probe_nterms=0 probe_reason=results_returned
    local -a probe_terms=()
    if [[ $n -eq 0 ]]; then
        mapfile -t probe_terms < <(_probe_terms "$q")
        probe_nterms=${#probe_terms[@]}
        probe_reason=too_few_content_terms
        # A quoted phrase cannot be relaxed faithfully: the probe rebuilds its
        # query from content terms, which un-quotes it, and an un-quoted phrase
        # is a strictly broader search — so ANY drop can hit and the tool would
        # name whichever it tried first. Claim nothing rather than name a wrong
        # culprit (skeptic req-001 Q2).
        if [[ "$q" == *'"'* || "$q" == *'“'* || "$q" == *'”'* ]]; then
            probe_state=inconclusive; probe_reason=quoted_phrase
            probe_nterms=0
        fi
    fi
    if [[ $n -eq 0 && "$probe_state" != inconclusive && $probe_nterms -ge $LIT_PROBE_MIN_TERMS ]]; then
        # Probe on a backend that actually answered; prefer the keyless,
        # rate-tolerant one.
        local b
        for b in openalex s2 asta; do
            if [[ " ${used[*]} " == *" $b "* ]]; then probe_backend="$b"; break; fi
        done
        probe_state=inconclusive; probe_reason=no_backend_available
        if [[ -n "$probe_backend" ]]; then
            local pi pdrop pq phits
            # DROP-ZERO BASELINE, and it must run FIRST. The probe searches the
            # query REDUCED to its content terms, which differs from what the
            # caller wrote by more than the dropped term: stopwords are gone
            # too. When a stopword was the binding constraint, the reduction
            # ALONE already hits — and then the first drop hits trivially and
            # an arbitrary content term gets named as the culprit. Measured:
            # `… medulloblastoma without` was blamed on "cell", while dropping
            # "cell" and keeping "without" still returned 0 (skeptic delta D2).
            # Disclosure cannot cure that one — the scoped claim "X is the term
            # whose removal recovered hits" is FALSE when nothing needed
            # removing. So establish it before attributing anything.
            local baseline probe_settled=0
            baseline=$(printf '%s' "${probe_terms[*]}")
            if ! phits=$(_relax_probe "$baseline" "$probe_backend" "$limit" "$year" \
                                      "$s2key" "$astakey" "$oamailto"); then
                probe_state=inconclusive; probe_reason=backend_error; probe_settled=1
            elif [[ "$phits" -gt 0 ]]; then
                # The reduction itself relieved the constraint. Something the
                # reduction removes — a stopword, punctuation, casing — was
                # binding, NOT any single content term. Name no culprit.
                probe_state=hits; probe_reason=reduction_recovered
                probe_hits="$phits"; probe_q="$baseline"; probe_dropped=""
                probe_settled=1
            fi
            for (( pi = 0; probe_settled == 0 && pi < probe_nterms && probe_tried < LIT_PROBE_MAX_DROPS; pi++ )); do
                # Pace the burst; see LIT_PROBE_DELAY_SECS. Never before the
                # first drop, so the early-exit path is unaffected.
                if [[ $probe_tried -gt 0 && "$LIT_PROBE_DELAY_SECS" != "0" ]]; then
                    sleep "$LIT_PROBE_DELAY_SECS"
                fi
                pdrop="${probe_terms[$pi]}"
                pq=$(_probe_query_without "$pdrop" "${probe_terms[@]}")
                if ! phits=$(_relax_probe "$pq" "$probe_backend" "$limit" "$year" \
                                          "$s2key" "$astakey" "$oamailto"); then
                    # A probe that could not run is not evidence of absence,
                    # and the drops already tried cannot license "no single
                    # term explains it" once the sequence is truncated by a
                    # failure. Stop and claim nothing.
                    probe_state=inconclusive; probe_reason=backend_error
                    break
                fi
                probe_tried=$(( probe_tried + 1 ))
                if [[ "$phits" -gt 0 ]]; then
                    probe_state=hits; probe_hits="$phits"
                    probe_dropped="$pdrop"; probe_q="$pq"; probe_reason=""
                    break
                fi
                probe_state=empty; probe_reason=""
            done
        fi
    fi

    # The machine-readable form of everything above. `probe.state` is what
    # separates a `partial` caused by a dead backend from a `partial` caused
    # by an unrunnable probe — the latter leaves BOTH backend lists empty, so
    # a caller reading only `failed_backends ∪ skipped_backends` would find
    # nothing wrong (your-org/nexus-code#600 item 3).
    local probe_json probe_nterms_json=null
    [[ $n -eq 0 ]] && probe_nterms_json=$probe_nterms
    probe_json=$(jq -n --arg st "$probe_state" --arg be "$probe_backend" \
        --arg dropped "$probe_dropped" --arg pq "$probe_q" --arg why "$probe_reason" \
        --argjson tried "$probe_tried" --argjson terms "$probe_nterms_json" \
        --argjson cap "$LIT_PROBE_MAX_DROPS" \
        'def orn: if . == "" then null else . end;
         {state: $st, reason: ($why|orn), backend: ($be|orn), content_terms: $terms,
          drops_tried: $tried, max_drops: $cap,
          dropped_term: ($dropped|orn), query: ($pq|orn)}')

    if [[ "$probe_state" == hits && "$probe_reason" == reduction_recovered ]]; then
        # The reduction hit with NOTHING dropped, so no content term can be
        # named — "X is the term whose removal recovered hits" would be false
        # here in the plainest way: nothing needed removing. Report what was
        # measured and name no culprit (skeptic delta D2).
        _search_error "$human" "query_over_constrained" \
            "the query ($(wc -w <<<"$q") words) matched nothing, but its content terms alone (\"$probe_q\") returned $probe_hits hit(s) on $probe_backend — the backends AND every term, so this zero MAY reflect an over-specific query rather than an empty literature. What recovered the hits was reducing the query to its content terms — dropping stopwords, punctuation and casing — and NOT the removal of any single term, so no term is named: no single content term accounts for this result" \
            "Search again with just your content terms: \"$probe_q\"." \
            "$q" "${used[*]:-}" "${failed[*]:-}" "${skipped_names[*]:-}" "" "$probe_json"
        return 2
    fi

    if [[ "$probe_state" == hits ]]; then
        # MEASURED: the same backend, the same moment, the same query minus
        # ONE term — hits. That makes the zero SUSPECT and names the term the
        # corpus does not join to the rest. It still does not establish that
        # the full conjunction has been studied: the drop's result set is a
        # SUPERSET of the full query's (the backends AND every term), so a
        # genuine gap in exactly that conjunction produces this signature too.
        # Report the measurement, not a verdict on the literature
        # (your-org/nexus-code#596 review, F2).
        _search_error "$human" "query_over_constrained" \
            "the query ($(wc -w <<<"$q") words) matched nothing, but its content terms minus \"$probe_dropped\" (\"$probe_q\") returned $probe_hits hit(s) on $probe_backend — the backends AND every term, so this zero MAY reflect an over-specific query rather than an empty literature. Two limits on that: the probe searched your query REDUCED to its content terms, so \"$probe_dropped\" is the term whose removal recovered hits from that reduction; and the reduction's result set is a superset of the full query's, so hits show the rest of the conjunction is populated, not that the full conjunction has been studied" \
            "Search again without \"$probe_dropped\", e.g. \"$probe_q\"." \
            "$q" "${used[*]:-}" "${failed[*]:-}" "${skipped_names[*]:-}" "" "$probe_json"
        return 2
    fi

    # ---- classify (1) vs (2) ---------------------------------------------
    # ok      every requested backend was searched — a 0 here is a REAL 0.
    # partial >=1 requested backend did not contribute — any count, and above
    #         all a 0, is a LOWER BOUND and settles nothing.
    local status=ok summary="" incomplete_why=""
    if [[ ${#failed[@]} -gt 0 || ${#skipped_names[@]} -gt 0 ]]; then
        status=partial
        [[ ${#failed[@]}       -gt 0 ]] && incomplete_why="failed: ${failed[*]}"
        [[ ${#skipped_names[@]} -gt 0 ]] && incomplete_why="${incomplete_why:+$incomplete_why; }skipped: ${skipped_names[*]}"
    fi
    if [[ $status == ok ]]; then
        if [[ $n -eq 0 ]]; then
            if [[ "$probe_state" == inconclusive ]]; then
                # The query was long enough that the zero needs corroborating,
                # and the corroborating probe did not run. Saying "genuine
                # zero" here would assert something unverified — the very
                # over-claim this whole state machine exists to prevent.
                status=partial
                local why="the shortened-query check could not be run"
                [[ "$probe_reason" == quoted_phrase ]] && why="the query contains a quoted phrase, which the shortened-query check cannot relax without silently un-quoting it — so it was not run rather than blame a term it cannot identify"
                summary="0 results, UNVERIFIED. The zero may reflect an over-specific query rather than an empty literature, and $why. Re-run with a handful of content terms before concluding anything."
            else
                # A zero is REPORTED here, never CERTIFIED. Every backend ANDs
                # the query terms, so "the literature is silent on X AND Y AND
                # Z" and "you over-specified" are not distinguishable states —
                # and the shortened-query check cannot separate them either.
                # It is now order-invariant (your-org/nexus-code#600), which
                # removes the coin-flip the #596 review found, but not the
                # ceiling: a drop's result set is still a superset of the full
                # query's, so "no single term explains it" is a narrower
                # statement than "the literature is empty". Saying "genuine
                # zero (confirmed: …)" put an endorsement on exactly the #588
                # shape this file exists to eliminate — a stronger claim than
                # the bare `count: 0` it replaced. So: state what was OBSERVED,
                # including how much of the term set was actually probed, and
                # leave the inference to the caller.
                summary="0 results. All requested backends (${used[*]}) were searched successfully and none matched"
                if [[ "$probe_state" == empty ]]; then
                    summary="$summary; its content terms alone, and every one-term-shorter form of them that was tried ($probe_tried of $probe_nterms content terms), also matched nothing on $probe_backend — no single content term accounts for this result"
                else
                    summary="$summary (under $LIT_PROBE_MIN_TERMS content terms, so no shortened-query check was run)"
                fi
                summary="$summary. Every backend ANDs the query terms, so a zero cannot on its own distinguish an empty literature from an over-specific query — treat this as an observation, not a verified absence."
            fi
        else
            summary="$n results from all requested backends (${used[*]})."
        fi
    else
        if [[ $n -eq 0 ]]; then
            summary="INCOMPLETE: 0 results, but not every backend contributed ($incomplete_why). This is NOT evidence that no literature exists — re-run once the backend(s) are available before concluding anything."
        else
            summary="INCOMPLETE: $n results from ${used[*]}, but not every backend contributed ($incomplete_why). Treat this as a lower bound."
        fi
    fi

    if [[ $human -eq 1 ]]; then
        # The headline carries the state. A bare "Found 0 papers" was the
        # whole defect — it reads as a finding regardless of why it is 0.
        # Both renderings are driven by the SAME `summary`, so the human view
        # can never drift from the JSON one and quietly lose the distinction.
        if [[ $status == ok ]]; then
            printf 'Found %s papers (sources: %s)\n' "$n" "${used[*]}"
            [[ $n -eq 0 ]] && printf '%s\n' "$summary"
        else
            printf 'INCOMPLETE — found %s papers (sources: %s)\n' "$n" "${used[*]}"
            printf 'WARNING: %s\n' "$summary"
        fi
        printf '\n'
        jq -r '.[] | "  [\(if .in_library then "IN-LIB" else "new" end)] \(.title)\n      \(.authors // "")\n      \(.venue // "") (\(.year // "n/a"))  cites:\(.citations // "?")  doi:\(.doi // "n/a")  [\(.sources | join("+"))]\n"' <<<"$results"
    else
        # `status` and `summary` lead the object so the state is the first
        # thing read, not a field a caller must know to look for. `partial`,
        # `failed_backends` and `skipped_backends` are retained verbatim for
        # callers written against the previous shape.
        jq -n --argjson r "$results" --arg st "$status" --arg sum "$summary" \
              --arg sources "${used[*]:-}" \
              --arg failed "${failed[*]:-}" --arg skippedn "${skipped_names[*]:-}" \
              --argjson probe "$probe_json" \
              'def names: split(" ") | map(select(length>0));
               ($failed | names) as $f | ($skippedn | names) as $s
             | {status: $st, summary: $sum,
                query_sources: ($sources | names),
                failed_backends: $f,
                skipped_backends: $s,
                partial: ($st != "ok"),
                complete: ($st == "ok"),
                probe: $probe,
                count: ($r|length), results: $r}' <<<""
    fi
    return 0
}

# ===========================================================================
# add
# ===========================================================================
# Build a refs.jsonl record from an S2 paper object (stdin) -> stdout (one line).
_s2_to_ref() {
    jq -c '
        def slug: (.authors[0].name // "anon" | split(" ") | last) + ((.year|tostring) // "");
        {
          id: ((.authors[0].name // "Anon" | split(" ") | last) + ((.year // "") | tostring) + "-s2"),
          doi: (.externalIds.DOI // ""),
          title: (.title // ""),
          authors: [ .authors[]? | (.name // "") | (split(" ")) as $p
                     | {first: ($p[:-1] | join(" ")), last: ($p[-1] // "")} ],
          abstract: (.abstract // ""),
          venue: (.venue // ""),
          published: { year: (.year // null) },
          pdf_path: "",
          source: { type: "s2", id: (.paperId // "") },
          pmid: (.externalIds.PubMed // ""),
          pmcid: (.externalIds.PubMedCentral // "")
        }'
}

# Build a refs.jsonl record from an OpenAlex work object (stdin) -> stdout.
# abstract_inverted_index (word -> [positions]) is reconstructed into plain
# text; OpenAlex omits it entirely for some publishers, in which case the
# abstract is simply empty (same "" convention as a missing S2 abstract).
_openalex_to_ref() {
    jq -c '
        def lastname: (.authorships[0].author.display_name // "Anon" | split(" ") | last);
        (.abstract_inverted_index // {}) as $idx
        | (if ($idx | length) > 0 then
             ($idx | to_entries | map(.key as $w | .value[] as $p | {p:$p, w:$w})
                    | sort_by(.p) | map(.w) | join(" "))
           else "" end) as $abstract
        | {
          id: (lastname + ((.publication_year // "") | tostring) + "-openalex"),
          doi: (if .doi then (.doi | sub("^https://doi\\.org/"; "")) else "" end),
          title: (.title // .display_name // ""),
          authors: [ .authorships[]?.author.display_name // "" | (split(" ")) as $p
                     | {first: ($p[:-1] | join(" ")), last: ($p[-1] // "")} ],
          abstract: $abstract,
          venue: (.primary_location.source.display_name // ""),
          published: { year: (.publication_year // null) },
          pdf_path: "",
          source: { type: "openalex", id: (.id // "" | sub("^https://openalex\\.org/"; "")) },
          pmid: ((.ids.pmid // "") | sub("^https?://pubmed\\.ncbi\\.nlm\\.nih\\.gov/"; "")),
          pmcid: ((.ids.pmcid // "") | sub(".*/"; ""))
        }'
}

# Fetch + normalize a paper via S2 -> a refs.jsonl record on stdout.
# Unchanged from before OpenAlex was added; still requires an S2 key.
_fetch_s2_ref() {
    local pid="$1" s2key="$2"
    local lookup="$pid"
    [[ "$pid" =~ ^10\. ]] && lookup="DOI:$pid"
    local fields="title,year,venue,authors,externalIds,abstract,paperId"
    local resp
    resp=$(curl -sS --max-time 40 -G "$S2_API/paper/$lookup" \
        --data-urlencode "fields=$fields" -H "x-api-key: $s2key" 2>/dev/null) \
        || die "S2 lookup failed"
    if ! printf '%s' "$resp" | jq -e '.paperId' >/dev/null 2>&1; then
        die "S2: $(printf '%s' "$resp" | jq -r '.error // .message // "not found"' 2>/dev/null)"
    fi
    printf '%s' "$resp" | _s2_to_ref
}

# Fetch + normalize a paper via OpenAlex -> a refs.jsonl record on stdout.
# No key needed. Accepts a bare DOI (10.xxx/...) via the filter endpoint
# (which returns clean JSON with an empty `results` on a miss — the direct
# /works/doi:... entity route 404s with an HTML body instead), or an
# OpenAlex work id (bare `Wnnnn` or `openalex:Wnnnn`) via the entity route.
_fetch_openalex_ref() {
    local pid="$1"
    local mailto; mailto="$(_lit_openalex_mailto)"
    local select="id,doi,title,display_name,publication_year,primary_location,authorships,abstract_inverted_index,ids"
    local resp
    if [[ "$pid" =~ ^10\. ]]; then
        local args=(-sS --max-time 40 -G "$OPENALEX_API/works"
            --data-urlencode "filter=doi:$pid"
            --data-urlencode "per-page=1"
            --data-urlencode "select=$select")
        [[ -n "$mailto" ]] && args+=(--data-urlencode "mailto=$mailto")
        resp=$(curl "${args[@]}" 2>/dev/null) || die "OpenAlex lookup failed"
        if ! printf '%s' "$resp" | jq -e '.results[0]' >/dev/null 2>&1; then
            die "OpenAlex: DOI not found"
        fi
        resp=$(printf '%s' "$resp" | jq -c '.results[0]')
    else
        local wid="${pid#openalex:}"
        local args=(-sS --max-time 40 -G "$OPENALEX_API/works/$wid" --data-urlencode "select=$select")
        [[ -n "$mailto" ]] && args+=(--data-urlencode "mailto=$mailto")
        resp=$(curl "${args[@]}" 2>/dev/null) || die "OpenAlex lookup failed"
        if ! printf '%s' "$resp" | jq -e '.id' >/dev/null 2>&1; then
            die "OpenAlex: id not found"
        fi
    fi
    printf '%s' "$resp" | _openalex_to_ref
}

# Dedup-check by DOI + append a ref record to the library; shared tail for
# both the S2 and OpenAlex add paths.
_lit_write_ref() {
    local rec="$1" human="$2"
    local lib; lib="$(_lit_library)"
    local doi; doi=$(printf '%s' "$rec" | jq -r '.doi // "" | ascii_downcase')
    if [[ -n "$doi" ]] && grep -qixF "$doi" <<<"$(_lib_dois)"; then
        note "already in library (doi:$doi) — not added"
        [[ $human -eq 1 ]] && printf 'already present: %s\n' "$doi"
        return 0
    fi
    mkdir -p "$(dirname "$lib")"
    printf '%s\n' "$rec" >>"$lib"
    if [[ $human -eq 1 ]]; then
        printf 'added to %s\n' "$lib"
        printf '%s\n' "$rec" | jq -r '"  \(.title) (\(.published.year // "n/a"))  doi:\(.doi)"'
    else
        printf '%s\n' "$rec" | jq '{added:true, library:"'"$lib"'", ref:.}'
    fi
}

cmd_add() {
    local human=0 pid=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --human) human=1; shift ;;
            --*) die "unknown flag: $1" ;;
            *) pid="$1"; shift ;;
        esac
    done
    [[ -n "$pid" ]] || die "usage: ng lit add <DOI|S2-id|openalex:Wid> [--human]   (e.g. ng lit add 10.1038/s41587-021-01033-z)"

    # S2 stays first-class and unchanged: if a key is configured, use it —
    # it resolves S2 paperIds/CorpusIds that OpenAlex's DOI-only fallback
    # can't. Only fall back to the keyless OpenAlex path when there's no
    # S2 key AND the id is DOI- or OpenAlex-shaped.
    local s2key; s2key="$(_lit_key s2)"
    local rec
    if [[ -n "$s2key" ]]; then
        rec="$(_fetch_s2_ref "$pid" "$s2key")" || return $?
    elif [[ "$pid" =~ ^10\. || "$pid" =~ ^openalex: || "$pid" =~ ^W[0-9]+$ ]]; then
        rec="$(_fetch_openalex_ref "$pid")" || return $?
    else
        note "add requires an S2 key for non-DOI ids (S2 paperId / CorpusId:...)"
        _setup_refs
        return 3
    fi
    _lit_write_ref "$rec" "$human"
}

# ===========================================================================
# dispatch
# ===========================================================================
main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        status)        cmd_status "$@" ;;
        search)        cmd_search "$@" ;;
        add)           cmd_add    "$@" ;;
        setup)         _setup_refs; exit 0 ;;
        ""|-h|--help)
            awk '/^$/{exit} NR>1' "$0" | sed 's/^# \{0,1\}//' ; exit 0 ;;
        *) die "unknown lit subcommand: $sub (status|search|add|setup)" ;;
    esac
}
main "$@"
