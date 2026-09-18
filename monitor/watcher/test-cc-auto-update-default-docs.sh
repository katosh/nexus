#!/usr/bin/env bash
# The docs state BOTH defaults of monitor.cc_auto_update.enabled, and the
# statement is derived from the code and the template, not copied
# (your-org/nexus-code#1476).
#
# THE DEFECT. `monitor/watcher/_config.sh` falls back to `false` when the key
# is absent; `config/nexus.example.yml` ships `enabled: true` and called that
# "DEFAULT TRUE"; `monitor/README.md` said "Default **disabled**". Both were
# half right, because `config/load.sh` picks ONE file whole — a tree with no
# `nexus.yml` reads the template's `true`, an existing `nexus.yml` without the
# key reads the code's `false` — and an operator reading either doc alone
# believed the other half. The operator's decision (#1476, 2026-09-10): change
# NEITHER value; make every doc that describes the default state both.
#
# WHAT IS CHECKED. The expected phrase is BUILT from the two live values —
#   "code default <off|on>, shipped template <on|off>"
# — so this suite is a coupling, not a spelling test: flip either value
# without touching the docs and every doc goes red, because the phrase they
# carry no longer matches the phrase the tree implies. The two measured
# contradictions are pinned as absences on top. A planted mutant proves the
# check can fail.
#
# Run: bash monitor/watcher/test-cc-auto-update-default-docs.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)

CODE_FILE="monitor/watcher/_config.sh"
TEMPLATE_FILE="config/nexus.example.yml"
DOCS=(
    config/nexus.example.yml
    monitor/README.md
    monitor/cc-harness/README.md
    skills/nexus.cc-update/GUIDE.md
    docs/reference/watcher-protocol.md
)

# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$CODE_FILE" "${DOCS[@]}"; }
gp_handle "$@"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# code_default <root>  -> true|false|<empty>   (the literal fallback in _config.sh)
code_default() {
    # -m1, not `| head -1`: a `head` reader is an early-exit reader and joins
    # the early-exit-readers.manifest ratchet (your-org/nexus-code#928 family).
    grep -m1 -oE 'monitor\.cc_auto_update\.enabled (true|false)' "$1/$CODE_FILE" 2>/dev/null \
        | awk '{print $2}'
}
# template_default <root> -> true|false|<empty>  (the value under cc_auto_update:)
template_default() {
    awk '/^  cc_auto_update:/{f=1} f && /^    enabled:/{print $2; exit}' "$1/$TEMPLATE_FILE" 2>/dev/null
}
_word() { case "$1" in true) echo on;; false) echo off;; *) echo "";; esac; }
# phrase_for <root> -> the phrase every doc under <root> must carry
phrase_for() {
    local c t; c=$(_word "$(code_default "$1")"); t=$(_word "$(template_default "$1")")
    [[ -n "$c" && -n "$t" ]] || return 1
    printf 'code default %s, shipped template %s\n' "$c" "$t"
}
# missing_docs <root> -> prints each doc under <root> that lacks the phrase; rc = count
missing_docs() {
    local root="$1" phrase d n=0
    phrase=$(phrase_for "$root") || { echo "REFUSED: could not derive both defaults under $root" >&2; return 99; }
    for d in "${DOCS[@]}"; do
        grep -qF -- "$phrase" "$root/$d" 2>/dev/null || { printf '%s\n' "$d"; n=$(( n + 1 )); }
    done
    return "$n"
}

echo "=== the two live values, read from the tree (not assumed) ==="
cd_val=$(code_default "$_repo_root"); td_val=$(template_default "$_repo_root")
assert_eq "the code fallback in $CODE_FILE is a readable literal" "$([[ "$cd_val" =~ ^(true|false)$ ]] && echo readable)" "readable"
assert_eq "the template value under cc_auto_update: is a readable literal" "$([[ "$td_val" =~ ^(true|false)$ ]] && echo readable)" "readable"
# The operator's decision is to change NEITHER. These two pins turn a silent
# flip of either value into a red with the issue number on it.
assert_eq "#1476 decision: the CODE default stays false" "$cd_val" "false"
assert_eq "#1476 decision: the TEMPLATE stays true" "$td_val" "true"
PHRASE=$(phrase_for "$_repo_root")
assert_eq "the phrase derived from the tree" "$PHRASE" "code default off, shipped template on"

echo "=== every doc that describes the default states BOTH ==="
miss=$(missing_docs "$_repo_root"); rc=$?
assert_eq "docs lacking the derived phrase: $(printf '%s' "$miss" | tr '\n' ' ')" "$rc" "0"
for d in "${DOCS[@]}"; do
    assert_contains "$d carries the phrase" "$(cat "$_repo_root/$d")" "$PHRASE"
done

echo "=== the two measured contradictions are gone ==="
# Scoped to the cc_auto_update block: three OTHER keys in the template say
# "Master enable. DEFAULT TRUE" about themselves, and this suite has nothing to
# say about them.
cc_block() { awk '/^  cc_auto_update:/{f=1; print; next} f && /^  [a-z_]+:/{exit} f{print}' "$1"; }
assert_contains "the cc_auto_update block was extracted (positive control)" "$(cc_block "$_repo_root/$TEMPLATE_FILE")" "enabled:"
assert_not_contains "$TEMPLATE_FILE's cc_auto_update block no longer calls the template value the unqualified DEFAULT" \
    "$(cc_block "$_repo_root/$TEMPLATE_FILE")" "DEFAULT TRUE"
assert_not_contains "monitor/README.md no longer says the routine is simply 'Default **disabled**'" \
    "$(cat "$_repo_root/monitor/README.md")" "Default **disabled**"

echo "=== potency: a planted tree where ONE doc lost the phrase must fail ==="
# Copy the population into $WORK, strip the phrase from one doc, and run the
# same checker. Without this the green above is unfalsifiable.
for f in "$CODE_FILE" "${DOCS[@]}"; do mkdir -p "$WORK/mut/$(dirname "$f")"; cp "$_repo_root/$f" "$WORK/mut/$f"; done
sed -i "s/$PHRASE/code default and template default/" "$WORK/mut/monitor/README.md"
miss=$(missing_docs "$WORK/mut"); rc=$?
assert_eq "the mutant is caught: exactly one doc missing" "$rc" "1"
assert_eq "…and it is the doc that was mutated" "$miss" "monitor/README.md"
# And the coupling direction: flip the CODE value in the copy, docs untouched
# -> the derived phrase changes and EVERY doc is now wrong.
for f in "$CODE_FILE" "${DOCS[@]}"; do mkdir -p "$WORK/flip/$(dirname "$f")"; cp "$_repo_root/$f" "$WORK/flip/$f"; done
sed -i 's/monitor\.cc_auto_update\.enabled false/monitor.cc_auto_update.enabled true/' "$WORK/flip/$CODE_FILE"
assert_eq "control: the flipped copy derives a DIFFERENT phrase" "$(phrase_for "$WORK/flip")" "code default on, shipped template on"
missing_docs "$WORK/flip" >/dev/null; rc=$?
assert_eq "a code-default flip with untouched docs reddens EVERY doc (${#DOCS[@]})" "$rc" "${#DOCS[@]}"
# REFUSAL, not a green, when a value cannot be read at all.
mkdir -p "$WORK/none/monitor/watcher" "$WORK/none/config"; : > "$WORK/none/$CODE_FILE"; : > "$WORK/none/$TEMPLATE_FILE"
missing_docs "$WORK/none" >/dev/null 2>&1; rc=$?
assert_eq "an unreadable default is REFUSED (99), never counted as 'no doc missing'" "$rc" "99"

_EXPECTED_ASSERTIONS=19   # count=exact (summary-honesty): every assertion above, once
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2; _th_fail
fi
th_summary_and_exit
