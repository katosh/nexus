#!/usr/bin/env bash
# test-textguard-lint.sh — both-directions coverage for
# monitor/watcher/textguard-lint.sh (your-org/nexus-code#1016, #1022, #1024,
# #1026).
#
# A lint is only worth its maintenance if BOTH its directions are checked. One
# that flags nothing passes a clean tree and a broken one identically; one that
# flags everything is muted within a week. So every case plants a fixture and
# states which direction it pins:
#
#   POSITIVE — the defect, in the spelling seen live on `dev`. Each MUST be
#              flagged, or the lint's green is a claim about its regex rather
#              than about the tree.
#   NEGATIVE — the CORRECT forms, plus the near-misses that share the defect's
#              silhouette. Each MUST NOT be flagged. These are the load-bearing
#              half: R1's first draft flagged 14 sites on a clean tree, every
#              one a log or a captured stream where a LINE count is the right
#              unit, and R2's first draft flagged `monitor/issue-ref.sh:100`,
#              which splits a string it has just validated as `owner/repo#N`.
#
# ── WHY THE FIXTURES ARE ASSEMBLED FROM PIECES ──────────────────────────
# The lint scans all of `monitor/`, so a literal `grep -c … "1"` or a literal
# `sed 's/#.*//'` written in THIS file is indistinguishable from a real site
# and would make the lint flag its own test — one hit, forever, in the tree it
# certifies clean. The alternative is an allowlist exempting this path, and a
# lint with an exemption for the file most likely to contain the pattern is a
# lint with a hole shaped like its own author. Keeping the literals out of the
# source keeps the scan uniform and needs no exception. (The device is
# `test-count-fallback-lint.sh`'s; the reasoning is its, too.)
#
# Run: bash monitor/watcher/test-textguard-lint.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LINT="$_dir/textguard-lint.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Assembled literals — see the header. None of the hazardous forms appears
# whole anywhere in this file.
_c='c'; _H='#'; _o='o'
_GC="grep -${_c}"                      # the line-unit census
_GO="grep -${_o}"                      # the occurrence-unit census (correct)
_SEDSTRIP="sed 's/${_H}.*/${_H}${_H}/'" ; _SEDSTRIP="sed 's/${_H}.*//'"
_NUMTOK='745'
_STAR='*'

# _plant <relative-path> <line…> — rebuild a fixture tree rooted at $WORK/tree.
# DECLARED per case, never mutated incrementally: each case rebuilds from
# scratch, so a fixture cannot leak into the next and answer through a path it
# was never written to reach.
_plant() {
    rm -rf "$WORK/tree"; mkdir -p "$WORK/tree/monitor/watcher"
    local rel="$1"; shift
    mkdir -p "$WORK/tree/$(dirname "$rel")"
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$WORK/tree/$rel"
}
# _hits [rule] → number of rows the lint printed (0 when clean).
_hits() {
    local out
    if [[ -n "${1:-}" ]]; then out=$(bash "$LINT" "$WORK/tree" --rule "$1" 2>/dev/null)
    else                        out=$(bash "$LINT" "$WORK/tree" 2>/dev/null); fi
    # `grep -c` prints 0 on no match and exits 1; `|| true` REPLACES nothing and
    # appends nothing. `|| echo 0` here would be this suite committing a defect
    # of the very family it exists to catch (your-org/nexus-code#725).
    printf '%s' "$out" | grep -c ':' || true
}
_rc() { bash "$LINT" "$WORK/tree" >/dev/null 2>&1; printf '%s' "$?"; }

echo '=== R1 POSITIVE: a line-unit census with a nonzero equality ==='

_plant monitor/watcher/t.sh \
  'REPO_ROOT=/x' \
  "assert_eq \"one site\" \"\$($_GC 'PAT' \"\$REPO_ROOT/monitor/a.sh\")\" \"1\""
assert_eq "inline assert_eq over a repo-anchored source"      "$(_hits R1)" "1"
assert_eq "…and the lint exits non-zero"                      "$(_rc)"      "1"

# THE CASE THAT MATTERED. Without joining backslash-continuations this rule
# found ZERO of the seven live sites on `dev` — a confident clean bill from a
# predicate that could not see the population.
_plant monitor/watcher/t.sh \
  'REPO_ROOT=/x' \
  'assert_eq "one site" \' \
  "                 \"\$($_GC 'PAT' \"\$REPO_ROOT/monitor/a.sh\")\" \"1\""
assert_eq "the assertion SPANS a backslash continuation"      "$(_hits R1)" "1"

_plant monitor/watcher/t.sh \
  'MAIN="$_script_dir/main.sh"' \
  "assert_contains \"one site\" \"\$($_GC 'PAT' \"\$MAIN\")\" \"1\""
assert_eq "target reached through a one-hop anchored variable" "$(_hits R1)" "1"

echo '=== R1 NEGATIVE: the immunities, each MEASURED not assumed ==='

_plant monitor/watcher/t.sh 'REPO_ROOT=/x' \
  "assert_eq \"absent\" \"\$($_GC 'PAT' \"\$REPO_ROOT/monitor/a.sh\")\" \"0\""
assert_eq "== 0 is immune (any occurrence yields >= 1 line)"   "$(_hits R1)" "0"

_plant monitor/watcher/t.sh 'REPO_ROOT=/x' \
  "n=\$($_GC 'PAT' \"\$REPO_ROOT/monitor/a.sh\"); if (( n >= 1 )); then :; fi"
assert_eq ">= 1 is a threshold, immune"                        "$(_hits R1)" "0"

_plant monitor/watcher/t.sh 'REPO_ROOT=/x' \
  "n=\$($_GC 'PAT' \"\$REPO_ROOT/monitor/a.sh\"); [ \"\$n\" -ge 1 ] && :"
assert_eq "-ge 1 is a threshold, immune"                       "$(_hits R1)" "0"

_plant monitor/watcher/t.sh 'REPO_ROOT=/x' \
  "assert_eq \"anchored\" \"\$($_GC '^PAT' \"\$REPO_ROOT/monitor/a.sh\")\" \"1\""
assert_eq "^-anchored: at most one match per line, immune"     "$(_hits R1)" "0"

_plant monitor/watcher/t.sh 'REPO_ROOT=/x' \
  "assert_eq \"exact\" \"\$(grep -${_c}xF 'PAT' \"\$REPO_ROOT/monitor/a.sh\")\" \"1\""
assert_eq "grep -cxF is line-exact BY FLAG, immune"            "$(_hits R1)" "0"

_plant monitor/watcher/t.sh 'REPO_ROOT=/x' \
  "assert_eq \"correct unit\" \"\$($_GO 'PAT' \"\$REPO_ROOT/monitor/a.sh\" | wc -l)\" \"1\""
assert_eq "grep -o IS the remedy and must never be flagged"    "$(_hits R1)" "0"

# The 14 false positives that made the first draft unshippable, one of each kind.
_plant monitor/watcher/t.sh \
  "assert_eq \"restarts\" \"\$($_GC 'restart svc' \"\$SVC_CALLS\")\" \"1\""
assert_eq "a captured action log: LINES are the right unit"    "$(_hits R1)" "0"

_plant monitor/watcher/t.sh 'REPO_ROOT=/x' \
  "assert_eq \"rows\" \"\$($_GC 'PAT' \"\$REPO_ROOT/monitor/decisions.tsv\")\" \"1\""
assert_eq "a .tsv under a repo anchor is still line-oriented"  "$(_hits R1)" "0"

_plant monitor/watcher/t.sh \
  "assert_eq \"lines\" \"\$(printf '%s' \"\$out\" | $_GC 'x')\" \"1\""
assert_eq "counting a captured STREAM is not a source census"  "$(_hits R1)" "0"

_plant monitor/watcher/t.sh 'REPO_ROOT=/x' \
  "if grep -${_c}q 'PAT' \"\$REPO_ROOT/monitor/a.sh\"; then :; fi"
assert_eq "grep -q prints nothing: there is no count to get wrong" "$(_hits R1)" "0"

_plant monitor/watcher/t.sh 'REPO_ROOT=/x' \
  "${_H} assert_eq \"x\" \"\$($_GC 'PAT' \"\$REPO_ROOT/monitor/a.sh\")\" \"1\""
assert_eq "a whole-line COMMENT is not a site"                 "$(_hits R1)" "0"

echo '=== R2 POSITIVE: a comment strip that is not shell-aware ==='

_plant monitor/watcher/t.sh "_code=\$($_SEDSTRIP \"\$F\")"
assert_eq "sed substituting ${_H}.* to end-of-line"            "$(_hits R2)" "1"

_plant monitor/watcher/t.sh "awk '{ line = \$0; sub(/${_H}.*/, \"\", line) }' \"\$F\""
assert_eq "awk sub(/${_H}.*/) — invisible to a sed-spelled grep" "$(_hits R2)" "1"

_plant monitor/watcher/t.sh "_code=\$(cut -d'${_H}' -f1 \"\$F\")"
assert_eq "cut -d'${_H}' -f1"                                  "$(_hits R2)" "1"

echo '=== R2 NEGATIVE ==='

_plant monitor/watcher/t.sh "_code=\$(grep -v '^[[:space:]]*${_H}' \"\$F\")"
assert_eq "the SAFE whole-line primitive is never flagged"     "$(_hits R2)" "0"

# Measured false positive from the real tree: monitor/issue-ref.sh:100 uses
# this to SPLIT a string the line above validated as owner/repo${_H}N.
_plant monitor/watcher/t.sh "printf 'REPO=%s\\n' \"\${_value%${_H}*}\""
assert_eq "\${var%${_H}*} is a field split, not a comment strip" "$(_hits R2)" "0"

echo '=== R3 POSITIVE: an assertion matching a token its own fixture mints ==='

_plant monitor/watcher/t.sh \
  "WORK=\$(mktemp -d -t nexus-${_NUMTOK}-XXXXXX)" \
  "case \"\$out\" in ${_STAR}${_NUMTOK}${_STAR}) pass \"named it\" ;; esac"
assert_eq "tempdir mints the token AND a glob matches it"      "$(_hits R3)" "1"

# The second manufacture surface, which `#1022`'s sweep recorded as `:64` only.
# B1/B2 both measured this one to be the LOAD-BEARING channel: the suite's tmux
# PATH stub carries the socket name, so ANY tmux failure puts the token on the
# asserted stream.
_plant monitor/watcher/t.sh \
  "SOCK=\"nexus-${_NUMTOK}-\$\$-\$1\"" \
  "case \"\$out\" in ${_STAR}${_NUMTOK}${_STAR}) pass \"named it\" ;; esac"
assert_eq "a tmux SOCKET name mints it too, not just mktemp"   "$(_hits R3)" "1"

echo '=== R3 NEGATIVE ==='

_plant monitor/watcher/t.sh \
  "WORK=\$(mktemp -d -t nexus-test-XXXXXX)" \
  "case \"\$out\" in ${_STAR}${_NUMTOK}${_STAR}) pass \"named it\" ;; esac"
assert_eq "glob but NO minted token: the cross-product is the finding" "$(_hits R3)" "0"

_plant monitor/watcher/t.sh \
  "WORK=\$(mktemp -d -t nexus-${_NUMTOK}-XXXXXX)" \
  'case "$out" in *"DEAD pane"*) pass "named it" ;; esac'
assert_eq "minted token but the assertion matches a PHRASE"    "$(_hits R3)" "0"

_plant monitor/watcher/t.sh \
  "WORK=\$(mktemp -d -t nexus-${_NUMTOK}-XXXXXX)" \
  "${_H} case \"\$out\" in ${_STAR}${_NUMTOK}${_STAR}) pass \"x\" ;; esac"
assert_eq "a whole-line COMMENT carrying the glob is not a site" "$(_hits R3)" "0"

echo '=== the lint refuses a tree it cannot scan (fail-closed) ==='
rm -rf "$WORK/tree"; mkdir -p "$WORK/tree"
bash "$LINT" "$WORK/tree" >/dev/null 2>&1
assert_eq "no monitor/ under the root => exit 2, not a clean 0" "$?" "2"

echo '=== the repo itself is clean, and that green is non-vacuous ==='
# Asserted TOGETHER with the positives above: "the tree is clean" means
# something only because the cases above proved this lint can go red. The
# potency control that actually matters is recorded in the PR: run this lint
# against `origin/dev` and it returns the four sites this branch fixes.
_repo_root=$(cd "$_dir/../.." && pwd)
bash "$LINT" "$_repo_root" >/dev/null 2>&1
assert_eq "monitor/ + .github/ + skills/ carry no textguard site" "$?" "0"

th_summary_and_exit
