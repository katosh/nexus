#!/usr/bin/env bash
# Tests for _pane_mcp_shell_risk and the shared is-a-shell predicate
# (your-org/nexus-code#590 follow-up).
#
# The claim being downgraded: monitor/pane-state.sh asserted that MCP servers
# are "spawned by claude directly as `node`/`python`/`uv`, NEVER through a
# shell", and `#590`'s rationale called the exclusion STRUCTURALLY IMPOSSIBLE
# to defeat. It is not. An `mcpServers` entry's `command` is an arbitrary
# executable; `command: "sh"` is legal and is the ordinary idiom for env setup
# or a pipeline. A skeptic built exactly that entry and watched it enter the
# background-shell count as non-infra — reopening the false positive.
#
# Two agents reached opposite conclusions and each was right about a different
# question: one enumerated the configuration that EXISTS (`npx`/`uvx`/http —
# excluded, correctly), the other tested the configuration that is PERMITTED.
# A fix has to satisfy the permitted space, so the claim is now scoped to what
# is true and the gap is guarded by a probe.
#
# The teeth:
#   - The permitted-but-unobserved configuration is DETECTED (`shell:<name>`),
#     including the exact `command: "sh"` counterexample.
#   - The configuration that actually exists is NOT flagged — an always-on
#     warning would be worthless.
#   - NEGATIVE CONTROL, and the reason this file exists: when the probe cannot
#     read the configuration it reports `unknown`, NEVER `none`. A probe that
#     answers "clean" because it failed to look is the same defect as a guard
#     that does not execute.
#   - The walk and the probe ask ONE predicate, so they cannot drift into
#     disagreeing about what a shell is.
#
# Hermetic: synthetic config files in a tmpdir; no live MCP server, no network.
#
# Run: bash monitor/watcher/test-mcp-shell-risk.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
PS="$REPO_ROOT/monitor/pane-state.sh"

. "$_test_dir/_test_helpers.sh"

[[ -x "$PS" ]] || { echo "missing pane-state.sh" >&2; exit 1; }

SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT

risk() { NEXUS_MCP_CONFIGS="$1" bash "$PS" --mcp-shell-risk 2>/dev/null; }

echo "=== 1. THE COUNTEREXAMPLE — a legal shell-command MCP entry is caught ==="
cat > "$SB/shellcmd.json" <<'EOF'
{ "mcpServers": {
    "envwrap": { "command": "sh", "args": ["-c", "X=1 exec real-server"] }
} }
EOF
assert_eq "command: \"sh\" is reported as a risk, not excluded" \
    "$(risk "$SB/shellcmd.json")" "shell:envwrap"

cat > "$SB/abs.json" <<'EOF'
{ "mcpServers": {
    "piped": { "command": "/bin/bash", "args": ["-lc", "server | tee log"] }
} }
EOF
assert_eq "an absolute path to a shell is caught too (basename, not literal)" \
    "$(risk "$SB/abs.json")" "shell:piped"

cat > "$SB/proj.json" <<'EOF'
{ "projects": { "/some/project": { "mcpServers": {
    "scoped": { "command": "zsh", "args": ["-c", "server"] }
} } } }
EOF
assert_eq "a PROJECT-scoped entry is enumerated, not just the global map" \
    "$(risk "$SB/proj.json")" "shell:scoped"

echo
echo "=== 2. WHAT ACTUALLY EXISTS — must NOT be flagged ==="
# The live configuration on this workspace's host, reproduced: npx, uvx, and
# an HTTP entry carrying no `command` at all. If these tripped the probe the
# warning would be permanent and therefore ignored.
cat > "$SB/live.json" <<'EOF'
{ "mcpServers": {
    "notion": { "command": "npx",  "args": ["-y", "@notionhq/notion-mcp-server"] },
    "zotero": { "command": "uvx",  "args": ["--from", "zotero-mcp-server", "zotero-mcp"] },
    "github": { "type": "http", "url": "https://api.example/mcp" }
} }
EOF
assert_eq "npx / uvx / http entries are correctly excluded" \
    "$(risk "$SB/live.json")" "none"
printf '{ "mcpServers": {} }\n' > "$SB/empty.json"
assert_eq "an empty mcpServers map is none" "$(risk "$SB/empty.json")" "none"
# And the REAL host config, whatever it is, must at least produce a legal verdict.
live=$(bash "$PS" --mcp-shell-risk 2>/dev/null)
assert_contains "the live host yields a well-formed verdict" \
    "$(grep -qE '^(none|shell:.+|unknown:.+)$' <<<"$live" && echo WELLFORMED)" "WELLFORMED"

echo
echo "=== 3. NEGATIVE CONTROL — 'could not look' is NOT 'nothing there' ==="
# This is the whole point of the file. Each case must yield `unknown`, and the
# reason must name WHY, so an operator can act on it.
printf 'this is not json {{{\n' > "$SB/broken.json"
out=$(risk "$SB/broken.json")
assert_contains "an unparsable config yields unknown, never none" "$out" "unknown:unparsable"
assert_contains "…naming the file that could not be parsed" "$out" "broken.json"
assert_not_contains "…and it does not fall back to a clean answer" "$out" "none"

cp "$SB/live.json" "$SB/noperm.json"; chmod 000 "$SB/noperm.json"
out=$(risk "$SB/noperm.json")
if [[ $(id -u) -eq 0 ]]; then
    th_skip "unreadable-config case" "running as uid 0, which can read a chmod 000 file"
else
    assert_contains "an unreadable config yields unknown, never none" "$out" "unknown:unreadable"
    assert_not_contains "…and does not silently skip the file" "$out" "none"
fi
chmod 644 "$SB/noperm.json"

# jq absent: the probe cannot answer, and must say so rather than assume.
JQLESS="$SB/jqless"; mkdir -p "$JQLESS"
for b in bash sed grep awk cat id printf realpath tmux ps pgrep basename dirname date stat tr head tail sort; do
    p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$JQLESS/$b"
done
out=$(NEXUS_MCP_CONFIGS="$SB/live.json" PATH="$JQLESS" bash "$PS" --mcp-shell-risk 2>/dev/null)
assert_eq "with jq unavailable the verdict is unknown:no-jq, not none" "$out" "unknown:no-jq"

echo
echo "=== 4. GENUINELY ABSENT vs UNREADABLE — these must differ ==="
# `none` is still the right answer when there is demonstrably nothing to read.
# If this collapsed into `unknown` the probe would be as useless as one that
# always says `none`.
assert_eq "no config file present at all → none" \
    "$(risk "$SB/does-not-exist.json")" "none"

echo
echo "=== 5. ONE PREDICATE — the walk and the probe cannot drift apart ==="
# The /proc walk classifies by `comm`; the probe classifies a configured
# `command` basename. If those lists diverged, the probe could certify a
# configuration the walk would then count — re-opening the gap through the
# back door. They must call the same function.
n_pred=$(grep -c '^_pane_comm_is_shell() {' "$PS")
assert_eq "the predicate is defined exactly once" "$n_pred" "1"
# Exactly ONE occurrence of the allow-list in the whole file — the one inside
# the predicate. A second copy is how the walk and the probe would drift.
n_lists=$(grep -c 'bash|sh|zsh|dash|ksh|fish' "$PS")
assert_eq "the allow-list literal appears exactly once (no inline copy)" "$n_lists" "1"
assert_contains "the /proc walk asks through the shared predicate" \
    "$(grep -c '_pane_comm_is_shell "\$comm"' "$PS")" "1"
# And the predicate itself still recognises the login-shell comm forms that
# only the /proc side ever sees.
for c in bash sh zsh dash ksh fish -bash -zsh -sh; do
    cat > "$SB/p-$$.json" <<EOF
{ "mcpServers": { "s": { "command": "$c" } } }
EOF
    got=$(risk "$SB/p-$$.json")
    assert_eq "predicate recognises '$c' as a shell" "$got" "shell:s"
done
for c in npx uvx node python python3 uv deno docker; do
    cat > "$SB/n-$$.json" <<EOF
{ "mcpServers": { "s": { "command": "$c" } } }
EOF
    got=$(risk "$SB/n-$$.json")
    assert_eq "predicate does NOT flag '$c'" "$got" "none"
done

echo
echo "=== 6. THE COMMENT NO LONGER MAKES THE REFUTED CLAIM ==="
# A comment enshrining a wrong mechanism is worse than none: it is trusted
# later. Pin the retraction so it cannot silently regress.
mcp_comment=$(sed -n '/^# MCP servers: excluded by/,/^# Verified against/p' "$PS")
assert_contains "the exclusion is scoped to the configuration, not asserted structural" \
    "$mcp_comment" "NOT a structural invariant"
assert_contains "…and the permitted counterexample is named concretely" \
    "$mcp_comment" 'command: "sh"'
assert_contains "…and the gap is pointed at its guard" \
    "$mcp_comment" "_pane_mcp_shell_risk"
# The refuted phrasing may survive ONLY as a quotation being retracted —
# never as a claim the file still makes. Pin both halves.
n_claim=$(grep -ci 'never through a shell' "$PS")
assert_eq "the refuted phrase survives at most once (as a quotation)" "$n_claim" "1"
assert_contains "…and that one occurrence is explicitly labelled false" \
    "$mcp_comment" "which is false as written"
assert_empty "the 'structurally impossible' framing is gone entirely" \
    "$(grep -ni 'structurally impossible' "$PS" || true)"

th_summary_and_exit
