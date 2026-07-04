#!/usr/bin/env bash
# Tier 3 — static-analysis tests on monitor/install-prompt.md.
#
# The install prompt is the load-bearing brief the bootstrap agent
# reads at first launch. It cites files, commands, and `ng` verbs by
# name; if any of those drift (file renamed, verb removed, command
# replaced) the prompt silently sends the operator down a dead-end.
# Drift is exactly what this tier catches.
#
# Assertions:
#   1. Markdown phase headers (`## Phase N — …`) form a contiguous
#      sequence 0..N with no gaps and no duplicates.
#   2. Every relative file path cited in the prompt either resolves
#      in the repo OR is in a small allowlist of files the bootstrap
#      itself creates (e.g. `config/nexus.yml`).
#   3. Every `monitor/ng <verb>` cited in the prompt is a real verb
#      in the current `monitor/ng` dispatcher.
#   4. URL regex sanity (no fetches): every http(s)://… that appears
#      in the prompt matches a permissive URL regex (no whitespace
#      mid-URL, hostname has a TLD, etc.).
#   5. No `@`-mentions of GitHub handles in prose. Code blocks and
#      email addresses are exempt; everything else should be ` `bot
#      ``-quoted or rewritten.
#   6. If a YAML frontmatter block is present, it parses cleanly.
#      (Today the prompt has none, so this is a "no surprise"
#      structural check, not a content requirement.)
#
# Run: bash monitor/watcher/test-install-prompt-content.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)
PROMPT="$SRC_ROOT/monitor/install-prompt.md"
NG="$SRC_ROOT/monitor/ng"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$(( FAIL + 1 )); }

if [[ ! -f "$PROMPT" ]]; then
    fail "install-prompt.md not found at $PROMPT"
    echo "=== summary: 0 passed, 1 failed ==="
    exit 1
fi

# --- Case 1: phase numbering --------------------------------------------

echo '=== Case 1: phase headers form contiguous sequence ==='

mapfile -t phase_nums < <(
    grep -oE '^## Phase [0-9]+ —' "$PROMPT" |
        awk '{print $3}'
)

if (( ${#phase_nums[@]} == 0 )); then
    fail "no '## Phase N —' headers found"
else
    pass "found ${#phase_nums[@]} phase headers"

    # Duplicate check
    dup=$(printf '%s\n' "${phase_nums[@]}" | sort | uniq -d | head -1)
    if [[ -z "$dup" ]]; then
        pass "no duplicate phase numbers"
    else
        fail "duplicate phase number: $dup"
    fi

    # Sequential 0..N check
    sorted=$(printf '%s\n' "${phase_nums[@]}" | sort -n | tr '\n' ',' | sed 's/,$//')
    expected_first=0
    expected_last=$(( ${#phase_nums[@]} - 1 ))
    expected_range=$(seq "$expected_first" "$expected_last" | tr '\n' ',' | sed 's/,$//')
    if [[ "$sorted" == "$expected_range" ]]; then
        pass "phase numbers are contiguous $expected_first..$expected_last"
    else
        fail "phase numbers not contiguous: got [$sorted] expected [$expected_range]"
    fi
fi

# --- Case 2: cited file paths resolve -----------------------------------

echo '=== Case 2: cited file paths resolve in the repo ==='

# Paths to exempt from existence check: files bootstrap creates, or
# paths that are template placeholders for user-supplied values.
declare -A ALLOWLIST=(
    ["config/nexus.yml"]=1            # written by Phase 3
)

# Match relative paths to source-y files mentioned in the prompt.
# Strategy:
#   1. Strip http(s)://… substrings first so URL-internal paths like
#      `<sha>/assets/general/README.md` don't masquerade as local
#      file paths.
#   2. Regex requires at least one `/` in the path so bare basenames
#      like `bootstrap-install.sh` (cited in prose without the
#      `./monitor/` prefix) aren't flagged.
#   3. First char must be alphanumeric, `.`, `_`, or `-` — excludes
#      leading-slash absolute paths.
#   4. Suffix limited to .sh|.md|.yml|.yaml|.py — covers everything
#      the prompt cites today; widen if we add new file types.
#   5. Drop any match containing `$` (template substitutions) or `<`
#      (angle-bracket placeholders like `<ORG>/<REPO>`).
# URL strip is deliberately greedy on `<` / `>` so URL TEMPLATES like
# `https://github.com/<ORG>/<REPO>/blob/<sha>/assets/...` are removed
# in one pass — otherwise `<sha>` clips the URL match and the trailing
# `assets/general/README.md` masquerades as a local path.
mapfile -t cited_paths < <(
    sed -E 's#https?://[^[:space:]`)]+##g' "$PROMPT" |
        grep -oE '[a-zA-Z0-9._-]+/[a-zA-Z0-9._/-]+\.(sh|md|yml|yaml|py)' |
        grep -vE '[<$]' |
        sort -u
)

if (( ${#cited_paths[@]} == 0 )); then
    fail "no cited file paths matched the regex (regex broken?)"
else
    pass "scanned ${#cited_paths[@]} unique cited paths"

    missing=()
    for p in "${cited_paths[@]}"; do
        # Strip a leading `./` if present so the test matches the
        # canonical relative path.
        rel="${p#./}"
        if [[ -n "${ALLOWLIST[$rel]:-}" ]]; then continue; fi
        if [[ -e "$SRC_ROOT/$rel" ]]; then continue; fi
        missing+=("$rel")
    done

    if (( ${#missing[@]} == 0 )); then
        pass "every cited path exists (or is in the allowlist)"
    else
        fail "${#missing[@]} cited paths do not resolve:"
        for m in "${missing[@]}"; do
            printf '       - %s\n' "$m" >&2
        done
    fi
fi

# --- Case 3: cited `ng` verbs are real ---------------------------------

echo '=== Case 3: cited ng verbs match the ng dispatcher ==='

# Extract the canonical verb list from ng's case dispatcher. Verbs are
# the bare tokens before a `)` paired with `cmd_<func>` on the same
# line. Grep is more portable than awk's gawk-only match-array form.
mapfile -t ng_verbs < <(
    grep -E '^[[:space:]]+[a-z][a-z0-9-]*\)[[:space:]]+cmd_' "$NG" |
        sed -E 's/^[[:space:]]+([a-z][a-z0-9-]*)\).*/\1/' |
        sort -u
)

if (( ${#ng_verbs[@]} == 0 )); then
    fail "no verbs extracted from ng dispatcher (parser broken)"
else
    pass "extracted ${#ng_verbs[@]} canonical ng verbs"
fi

# Scan the prompt for `ng <verb>` patterns. To avoid `\bng` matching
# inside ordinary words like "running", "spawning", "launching", we
# require `ng` to be preceded by whitespace, backtick, or slash AND
# followed by a single lowercase word that's a candidate verb. Capture
# verbs are dispatched on the last whitespace-separated token of the
# match (the verb itself).
mapfile -t cited_verbs < <(
    grep -oE '([[:space:]`/])ng [a-z][a-z-]+' "$PROMPT" |
        awk '{print $NF}' |
        sort -u
)

# Filter false positives:
#   - `<verb>` literal placeholder.
#   - Filenames that look like verbs when the prompt cites
#     `monitor/ng <file>` as an `ls`/`cp` argument list (the line
#     `ls -la config/nexus.example.yml monitor/ng watcher` is the
#     canonical case — `watcher` is the symlink, not a verb). Heuristic:
#     if the supposed verb resolves as a repo-root file/dir, it's a
#     filename, not a verb.
filtered=()
for v in "${cited_verbs[@]}"; do
    case "$v" in
        '<verb>'|placeholder|name) continue ;;
    esac
    if [[ -e "$SRC_ROOT/$v" ]]; then continue; fi
    filtered+=("$v")
done
cited_verbs=("${filtered[@]}")

if (( ${#cited_verbs[@]} == 0 )); then
    fail "no ng verbs found in prompt (prompt or regex broken)"
else
    pass "found ${#cited_verbs[@]} unique ng verbs cited in prompt"

    # Build a set of valid verbs for O(1) lookup.
    declare -A is_valid_verb=()
    for v in "${ng_verbs[@]}"; do is_valid_verb[$v]=1; done

    bad=()
    for v in "${cited_verbs[@]}"; do
        if [[ -n "${is_valid_verb[$v]:-}" ]]; then continue; fi
        bad+=("$v")
    done

    if (( ${#bad[@]} == 0 )); then
        pass "every cited ng verb is a real dispatcher verb"
    else
        fail "${#bad[@]} cited verbs are not real ng verbs:"
        for b in "${bad[@]}"; do
            printf '       - ng %s (not in dispatcher)\n' "$b" >&2
        done
    fi
fi

# --- Case 4: URL format sanity -----------------------------------------

echo '=== Case 4: URLs match a permissive format ==='

# Match http(s)://… up to the first whitespace, backtick, or paren.
mapfile -t urls < <(
    grep -oE 'https?://[^[:space:]`)<>]+' "$PROMPT" | sort -u
)

if (( ${#urls[@]} == 0 )); then
    fail "no URLs found in prompt (prompt or regex broken)"
else
    pass "scanned ${#urls[@]} unique URLs"

    bad_urls=()
    for u in "${urls[@]}"; do
        # Strip trailing punctuation that markdown reflow can leave.
        clean="${u%[.,;:]}"
        # Drop the path; assert host has at least one dot OR a valid
        # one-segment localhost-like host. Permissive on purpose: we
        # explicitly do NOT do DNS or network probes.
        host="${clean#https://}"; host="${host#http://}"
        host="${host%%/*}"; host="${host%%:*}"
        if [[ ! "$host" =~ ^[a-zA-Z0-9.-]+$ ]]; then
            bad_urls+=("$u (host fails regex: $host)")
            continue
        fi
        if [[ "$host" != *.* && "$host" != "localhost" ]]; then
            bad_urls+=("$u (host has no TLD)")
            continue
        fi
    done

    if (( ${#bad_urls[@]} == 0 )); then
        pass "every URL passes format sanity"
    else
        fail "${#bad_urls[@]} URLs fail format sanity:"
        for b in "${bad_urls[@]}"; do
            printf '       - %s\n' "$b" >&2
        done
    fi
fi

# --- Case 5: no `@`-mentions ------------------------------------------

echo '=== Case 5: no @-mentions in prose ==='

# Strategy: strip fenced code blocks (``` … ```), then look for
# `@<gh-handle>` tokens. Email addresses (something@something.tld)
# don't count because they're not auto-linked as user-mentions on
# GitHub. Indented-code (4+ spaces) is rare in this prompt and
# treated as prose here — we'd rather over-flag than miss a real
# at-mention.
ats=$(awk '
    /^```/ { fenced = !fenced; next }
    fenced { next }
    {
        line = $0
        while (match(line, /@[A-Za-z][A-Za-z0-9_-]*/)) {
            handle = substr(line, RSTART, RLENGTH)
            rest_after = substr(line, RSTART + RLENGTH)
            prefix = substr(line, 1, RSTART - 1)
            # Email if "@" preceded by a non-space + word char AND
            # followed by a `.tld` segment.
            is_email = 0
            if (RSTART > 1) {
                prevch = substr(line, RSTART - 1, 1)
                if (prevch ~ /[A-Za-z0-9._-]/) is_email = 1
            }
            if (rest_after ~ /^\./) is_email = 1
            if (!is_email) print FILENAME ":" NR ": " handle " | " $0
            line = rest_after
        }
    }
' "$PROMPT" || true)

if [[ -z "$ats" ]]; then
    pass "no @-mention candidates in prose"
else
    fail "found @-mention candidates in prose:"
    echo "$ats" | sed 's/^/       - /' >&2
fi

# --- Case 6: YAML frontmatter parses (if present) ---------------------

echo '=== Case 6: YAML frontmatter parses cleanly (if present) ==='

first_line=$(head -1 "$PROMPT")
if [[ "$first_line" == "---" ]]; then
    # Extract the block between the first pair of `---` delimiters.
    fm=$(awk 'NR==1 && $0=="---" { ingest=1; next }
              ingest && $0=="---" { exit }
              ingest { print }' "$PROMPT")
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
        fm_err=$(mktemp -t fm-err-XXXXXX)
        if echo "$fm" | python3 -c '
import sys, yaml
try:
    yaml.safe_load(sys.stdin)
except Exception as e:
    print(f"yaml parse error: {e}", file=sys.stderr)
    sys.exit(1)
' 2>"$fm_err"; then
            pass "frontmatter parses as valid YAML"
        else
            fail "frontmatter does not parse: $(cat "$fm_err" 2>/dev/null || true)"
        fi
        rm -f "$fm_err"
    else
        pass "frontmatter present but python3+PyYAML unavailable; skipping parse"
    fi
else
    pass "no YAML frontmatter (expected for current prompt; structural check satisfied)"
fi

# --- Case 7: label creation uses the portable REST API ----------------

# your-org/nexus-code#313 item 2: the `gh label` subcommand does not
# exist in `gh 1.13.0` (the agent-sandbox base image). The install
# prompt must create the dashboard labels via the REST API
# (`gh api .../labels`), never via `gh label create`. Guard against a
# regression that reintroduces the unportable command.

echo '=== Case 7: dashboard labels created via REST, not `gh label create` ==='

# Match the literal command invocation `gh label create`. Prose
# mentions of the `gh label` subcommand (explaining WHY we avoid it)
# are fine — we match the full command form only.
if grep -qE 'gh label create' "$PROMPT"; then
    fail "install-prompt.md still invokes 'gh label create' (absent in gh 1.13.0; use 'gh api .../labels')"
else
    pass "no 'gh label create' invocation in the prompt"
fi

# The REST upsert must be present: a `gh api` call against the repo
# labels endpoint.
if grep -qE 'gh api .*labels' "$PROMPT"; then
    pass "label creation uses the REST API (gh api .../labels)"
else
    fail "no 'gh api .../labels' REST label-creation call found in the prompt"
fi

# --- summary -----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
