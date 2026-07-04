#!/usr/bin/env bash
# monitor/lit.sh — nexus literature-research tool (backs `ng lit`).
#
# Native, on-demand literature discovery for Claude workers. Finds papers
# by CONTENT relevance across Semantic Scholar (S2) and ASTA (Allen AI),
# deduplicated against the nexus reference library, and can pull a paper's
# metadata into that library. Reimplements the subset of `bipartite` (bip)
# utilities the nexus needs as plain curl+jq — ZERO dependency on the
# operator-local `bip` binary, so it ships in nexus-code and works in any
# operator's clone.
#
# Subcommands:
#   ng lit status                      keys, library, index — and what to fix
#   ng lit search "<query>" [flags]    content-relevance discovery (S2 + ASTA)
#   ng lit add <DOI|S2-id> [flags]     fetch metadata + append to the library
#   ng lit setup                       print the exact setup / key-acquisition refs
#
# search flags:
#   --source s2|asta|both   (default both)   pick discovery backend(s)
#   --limit N               (default 10)      max results per source
#   --year A:B                                publication-year filter (S2)
#   --human                                   human-readable (default: JSON)
#
# add flags:
#   --human                                   human-readable confirmation
#
# Keys are resolved per-source from (first hit wins):
#   1. env            S2_API_KEY            / ASTA_API_KEY
#   2. nexus config   lit.s2_api_key        / lit.asta_api_key   (config/nexus.yml)
#   3. legacy bip     s2_api_key            / asta_api_key       (.config/bip/config.yml)
# An unconfigured source is SKIPPED WITH A NOTE — never a silent hang and
# never a hard failure of the whole command.
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

die() { printf 'lit: %s\n' "$*" >&2; exit 1; }
note() { printf 'lit: %s\n' "$*" >&2; }

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
lit: literature-search setup — obtain and install an API key for at least
one backend (an unconfigured backend is simply skipped):

  Semantic Scholar (S2)  — free key, instant:
      request at  https://www.semanticscholar.org/product/api#api-key-form
  ASTA (Allen AI)        — request via the ASTA program (see the docs page).

Install the key one of three ways (first found wins):
  1. export S2_API_KEY=...      (or ASTA_API_KEY=...)   in the environment
  2. add to config/nexus.yml:
         lit:
           s2_api_key: "..."     # config/nexus.yml is gitignored — safe
           asta_api_key: "..."
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
    local libn=0; [[ -f "$lib" ]] && libn=$(grep -c '' "$lib" 2>/dev/null || echo 0)
    local s2o asta_o
    s2o=$(_lit_key_origin s2); asta_o=$(_lit_key_origin asta)
    local s2_ok=no asta_ok=no
    [[ "$s2o" != none ]] && s2_ok=yes
    [[ "$asta_o" != none ]] && asta_ok=yes
    if [[ $human -eq 1 ]]; then
        printf 'Nexus literature tool\n'
        printf '  library:     %s\n' "$lib"
        printf '  references:  %s\n' "$libn"
        printf '  S2 key:      %s (%s)\n'   "$s2_ok"   "$s2o"
        printf '  ASTA key:    %s (%s)\n'   "$asta_ok" "$asta_o"
        if [[ $s2_ok == no && $asta_ok == no ]]; then
            printf '  status:      NOT CONFIGURED\n'; _setup_refs
        else
            printf '  status:      ready (search uses configured backends; others skipped)\n'
        fi
    else
        jq -n --arg lib "$lib" --argjson n "$libn" \
              --arg s2 "$s2_ok" --arg s2o "$s2o" \
              --arg asta "$asta_ok" --arg astao "$asta_o" \
              '{library:$lib, references:$n,
                s2:{configured:($s2=="yes"), origin:$s2o},
                asta:{configured:($asta=="yes"), origin:$astao},
                configured: ($s2=="yes" or $asta=="yes")}'
        [[ $s2_ok == no && $asta_ok == no ]] && _setup_refs
    fi
    [[ $s2_ok == no && $asta_ok == no ]] && return 3
    return 0
}

# ===========================================================================
# search
# ===========================================================================
# S2 relevance search -> normalized JSON array on stdout.
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
    if ! printf '%s' "$resp" | jq -e '.data' >/dev/null 2>&1; then
        local msg; msg=$(printf '%s' "$resp" | jq -r '.error // .message // "unexpected response"' 2>/dev/null || echo "unexpected response")
        note "S2: $msg"; return 1
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

cmd_search() {
    local q="" source="both" limit=10 year="" human=0
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
    [[ -n "$q" ]] || die "usage: ng lit search \"<query>\" [--source s2|asta|both] [--limit N] [--year A:B] [--human]"
    case "$source" in s2|asta|both) ;; *) die "--source must be s2|asta|both" ;; esac

    local s2key astakey; s2key="$(_lit_key s2)"; astakey="$(_lit_key asta)"
    if [[ -z "$s2key" && -z "$astakey" ]]; then
        note "no literature backend is configured (S2 or ASTA)"; _setup_refs; return 3
    fi

    local results="[]" used=() skipped=()
    if [[ "$source" == "s2" || "$source" == "both" ]]; then
        if [[ -n "$s2key" ]]; then
            local r; if r=$(_s2_search "$q" "$limit" "$year" "$s2key"); then
                results=$(jq -n --argjson a "$results" --argjson b "$r" '$a + $b'); used+=(s2)
            fi
        else
            skipped+=("s2 (no key — set S2_API_KEY or lit.s2_api_key)")
        fi
    fi
    if [[ "$source" == "asta" || "$source" == "both" ]]; then
        if [[ -n "$astakey" ]]; then
            local r; if r=$(_asta_search "$q" "$limit" "$astakey"); then
                results=$(jq -n --argjson a "$results" --argjson b "$r" '$a + $b'); used+=(asta)
            fi
        else
            skipped+=("asta (no key — set ASTA_API_KEY or lit.asta_api_key)")
        fi
    fi

    # Annotate in_library by DOI (jq --arg is portable; --rawfile is 1.6+).
    local doidata; doidata=$(_lib_dois)
    results=$(jq --arg dois "$doidata" '
        ($dois | split("\n") | map(select(length>0)) ) as $have
        | map(. + {in_library: ((.doi // "" | ascii_downcase) as $d
                 | ($d != "" and ($have | index($d) != null)))})
        | unique_by(.doi // .id // .title)' <<<"$results")

    for s in "${skipped[@]:-}"; do [[ -n "$s" ]] && note "skipped: $s"; done

    if [[ $human -eq 1 ]]; then
        local n; n=$(jq 'length' <<<"$results")
        printf 'Found %s papers (sources: %s)\n\n' "$n" "${used[*]:-none}"
        jq -r '.[] | "  [\(if .in_library then "IN-LIB" else "new" end)] \(.title)\n      \(.authors // "")\n      \(.venue // "") (\(.year // "n/a"))  cites:\(.citations // "?")  doi:\(.doi // "n/a")  [\(.source)]\n"' <<<"$results"
    else
        jq -n --argjson r "$results" --arg sources "${used[*]:-}" \
              '{query_sources: ($sources | split(" ") | map(select(length>0))), count: ($r|length), results: $r}' <<<""
    fi
    [[ ${#used[@]} -eq 0 ]] && { note "no backend returned results"; return 1; }
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

cmd_add() {
    local human=0 pid=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --human) human=1; shift ;;
            --*) die "unknown flag: $1" ;;
            *) pid="$1"; shift ;;
        esac
    done
    [[ -n "$pid" ]] || die "usage: ng lit add <DOI|S2-id> [--human]   (e.g. ng lit add 10.1038/s41587-021-01033-z)"
    local s2key; s2key="$(_lit_key s2)"
    [[ -n "$s2key" ]] || { note "add requires an S2 key"; _setup_refs; return 3; }

    # Normalize: bare DOI -> DOI:..., else pass through (S2 id, CorpusId:, etc.)
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

    local lib; lib="$(_lit_library)"
    local doi; doi=$(printf '%s' "$resp" | jq -r '.externalIds.DOI // "" | ascii_downcase')
    if [[ -n "$doi" ]] && _lib_dois | grep -qixF "$doi"; then
        note "already in library (doi:$doi) — not added"
        [[ $human -eq 1 ]] && printf 'already present: %s\n' "$doi"
        return 0
    fi
    local rec; rec=$(printf '%s' "$resp" | _s2_to_ref)
    mkdir -p "$(dirname "$lib")"
    printf '%s\n' "$rec" >>"$lib"
    if [[ $human -eq 1 ]]; then
        printf 'added to %s\n' "$lib"
        printf '%s\n' "$rec" | jq -r '"  \(.title) (\(.published.year // "n/a"))  doi:\(.doi)"'
    else
        printf '%s\n' "$rec" | jq '{added:true, library:"'"$lib"'", ref:.}'
    fi
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
            sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//' ; exit 0 ;;
        *) die "unknown lit subcommand: $sub (status|search|add|setup)" ;;
    esac
}
main "$@"
