#!/usr/bin/env bash
# test-claude-md-repo-walkup.sh — execute CLAUDE.md's REPO-WALKUP block.
#
# WHY THIS SUITE EXISTS. your-org/nexus-code#1196: `git -C <dir>` on a
# directory that is not itself a repository does not fail. Git walks UP and
# answers about the nearest enclosing repository, at rc 0, with nothing on
# stderr. In a nexus the nearest enclosing repository is always the nexus,
# because every analysis tree lives under `work/` — so a provenance probe over
# an un-versioned tree returns the NEXUS's own HEAD, and does so identically
# for every such tree, which reads as consistency rather than as an error.
#
# THE COMPANION SUITE, AND WHY BOTH EXIST. `test-repo-root-provenance.sh`
# guards the CODE — it drives the three real callers (#1196 read, #1080 write,
# #1174 hook) against planted layouts and reverts each fix to require the
# assertion to flip. It does not read CLAUDE.md at all. This suite guards the
# DOCUMENTED BLOCK, which is what an agent doing an ad-hoc cross-tree probe
# actually consults. A correct predicate nobody is told about does not stop the
# next fabricated provenance table.
#
# WHAT IS PINNED:
#
#   (i)  THE TRAP IS REAL AND SILENT. The walk-up form returns the ENCLOSING
#        repository's HEAD at rc 0 for a directory that is not a repository —
#        asserted as the identity `subdir HEAD == root HEAD`, which is what
#        makes the provenance FABRICATED rather than merely absent.
#
#   (ii) `--is-inside-work-tree` RETURNS TRUE THERE. It is the first guard a
#        careful author reaches for and it certifies the wrong thing. Asserting
#        it is what stops someone "simplifying" the block down to that form.
#
#   (iii) BOTH DISCRIMINATORS FIRE, AND — THE LOAD-BEARING HALF — BOTH STAY
#        SILENT AT A REAL REPOSITORY ROOT. A discriminator that always answered
#        "ancestor" would satisfy (iii) and be useless, so every discriminator
#        assertion is PAIRED with a positive control at the root itself.
#
#   (iv) `monitor/repo-root.sh` AGREES IN BOTH DIRECTIONS — `verdict=no` at the
#        subdirectory, `verdict=yes` at the root. Behavioural, not textual: a
#        block naming a tool that had stopped discriminating would still pass a
#        spelling assertion.
#
# Run: bash monitor/watcher/test-claude-md-repo-walkup.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

# ── this suite DECLARES its own population (the --population protocol) ──────
# your-org/nexus-code#1219. CLAUDE.md is the document this suite EXECUTES, so
# an edit to the fenced block it pins is exactly the edit that can change its
# verdict — and until #1219 no such edit could SELECT it: a suite that declares
# no population is INVISIBLE to `guards-for-diff` rather than excluded by it
# (#1078), appearing in neither SELECTED nor CONSIDERED AND EXCLUDED, so its
# absence reads as a considered exclusion. `gp_handle` adds this suite's own
# path and `monitor/_guard_population.sh` for free; everything else is declared
# because this suite READS ITS BYTES to reach a verdict.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        CLAUDE.md \
        monitor/repo-root.sh \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"
th_claude_md_block_coverage REPO-WALKUP   # the entry's UNCHECKED share, in this suite's own output (#1239)
RR="$REPO_ROOT/monitor/repo-root.sh"

WORK=$(mktemp -d) || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# ---- assertion-count guard (your-org/nexus-code#946 F6) ------------------
#   1 readable + 1 Control A + 5 form shapes + 2 trap + 1 false-certification
#   + 4 discriminator (2 fire + 2 positive control) + 2 repo-root.sh = 16
_th_count_guard() {
    local EXPECTED_ASSERTIONS=16
    local TOTAL_ASSERTIONS=$(( PASS + FAIL ))
    assert_eq "assertion TOTAL matches the EXPECTED total" \
              "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"
    th_summary_and_exit
}

echo '=== Extraction: pull the delimited block out of CLAUDE.md ==='
[[ -r "$CLAUDE_MD" ]] || th_abort "CLAUDE.md not readable at $CLAUDE_MD"
assert_file_exists "CLAUDE.md is readable" "$CLAUDE_MD"

FORMS=$(awk -v b='<!-- BEGIN REPO-WALKUP -->' -v e='<!-- END REPO-WALKUP -->' '
    index($0, b) { inb = 1; next }
    index($0, e) { inb = 0 }
    inb' "$CLAUDE_MD" \
    | sed -E 's/^[[:space:]]+//' \
    | grep -vE '^```' \
    | sed -E 's/[[:space:]]{2,}#.*$//' \
    | grep -E '^(git|monitor/) ?')

FORM_COUNT=$(printf '%s\n' "$FORMS" | grep -cE '^(git|monitor/)')
assert_eq "Control A: extracted exactly 5 documented forms" "$FORM_COUNT" "5"
if [[ "$FORM_COUNT" != "5" ]]; then
    th_abort "block malformed — refusing to draw conclusions from it"
fi

# SELECT BY CONTENT, never by position. `-- ` is load-bearing on every pattern
# beginning with `-`: without it grep parses it as an OPTION and the selection
# is EMPTY at rc 1 (CLAUDE.md's DASH-PATTERN-OPTION entry, #1186).
F_HEAD=$(printf   '%s\n' "$FORMS" | grep -F 'rev-parse HEAD'            | sed -n '1p')
F_INSIDE=$(printf '%s\n' "$FORMS" | grep -F -- '--is-inside-work-tree'  | sed -n '1p')
F_TOP=$(printf    '%s\n' "$FORMS" | grep -F -- '--show-toplevel'        | sed -n '1p')
F_PREFIX=$(printf '%s\n' "$FORMS" | grep -F -- '--show-prefix'          | sed -n '1p')
F_RR=$(printf     '%s\n' "$FORMS" | grep -F 'repo-root.sh'              | sed -n '1p')

assert_contains "form 1 is the walk-up itself"           "$F_HEAD"   "rev-parse HEAD"
assert_contains "form 2 is the guard that CERTIFIES WRONG" "$F_INSIDE" "--is-inside-work-tree"
assert_contains "form 3 is the toplevel discriminator"    "$F_TOP"    "--show-toplevel"
assert_contains "form 4 is the prefix discriminator"      "$F_PREFIX" "--show-prefix"
assert_contains "form 5 names the in-repo predicate"      "$F_RR"     "repo-root.sh"

# ---- the planted layout --------------------------------------------------
# A real repository, and inside it a plain directory that is NOT one — the
# `work/<analysis-tree>` shape exactly.
ROOT="$WORK/nexus"
SUB="$ROOT/work/unversioned-tree"
mkdir -p "$SUB" || th_abort "fixture mkdir failed"
git -C "$ROOT" init -q                     >/dev/null 2>&1
git -C "$ROOT" config user.email fixture@local
git -C "$ROOT" config user.name  fixture
printf 'fixture\n' > "$ROOT/file.txt"
git -C "$ROOT" add file.txt                >/dev/null 2>&1
git -C "$ROOT" commit -qm fixture          >/dev/null 2>&1
ROOT_HEAD=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)
[[ -n "$ROOT_HEAD" ]] || th_abort "fixture commit failed — nothing below could be believed"
[[ ! -e "$SUB/.git" ]] || th_abort "fixture subdir unexpectedly IS a repo — the trap could not be shown"

_sub() { printf '%s' "${1//DIR/$2}"; }
_run() { FORM=$(_sub "$1" "$2") REPO_ROOT="$REPO_ROOT" bash -c 'cd "$REPO_ROOT" && eval "$FORM"' 2>/dev/null; }

echo
echo '=== (i) THE TRAP: the walk-up answers, at rc 0, about the ANCESTOR ==='
sub_head=$(_run "$F_HEAD" "$SUB"); rc_head=$?
assert_eq "the non-repo subdirectory reports the ENCLOSING repo's HEAD as its own" \
          "$( [[ -n "$sub_head" && "$sub_head" == "$ROOT_HEAD" ]] && echo fabricated || echo "other:$sub_head" )" \
          "fabricated"
assert_eq "…and it EXITS 0 — nothing errors, which is why it is believed" "$rc_head" "0"

echo
echo '=== (ii) THE GUARD THAT CERTIFIES THE WRONG THING ==='
assert_eq "--is-inside-work-tree says TRUE for a directory that is not a repo" \
          "$(_run "$F_INSIDE" "$SUB" | tr -d '[:space:]')" "true"

echo
echo '=== (iii) BOTH DISCRIMINATORS — each PAIRED with a positive control ==='
# A discriminator that always cried "ancestor" would pass the FIRES half and be
# worthless. The root arm is what makes the subdir arm mean anything.
top_sub=$(_run "$F_TOP" "$SUB" | tr -d '[:space:]')
top_root=$(_run "$F_TOP" "$ROOT" | tr -d '[:space:]')
assert_eq "toplevel at the SUBDIR is NOT the subdir — you are reading an ancestor" \
          "$( [[ -n "$top_sub" && "$top_sub" != "$SUB" ]] && echo FIRES || echo silent )" "FIRES"
assert_eq "POSITIVE CONTROL: toplevel at the ROOT *is* the root — the discriminator is silent there" \
          "$( [[ "$top_root" == "$ROOT" ]] && echo silent || echo "FIRES:$top_root" )" "silent"

pre_sub=$(_run "$F_PREFIX" "$SUB" | tr -d '[:space:]')
pre_root=$(_run "$F_PREFIX" "$ROOT" | tr -d '[:space:]')
assert_eq "prefix at the SUBDIR is NON-EMPTY — you are below the root" \
          "$( [[ -n "$pre_sub" ]] && echo FIRES || echo silent )" "FIRES"
assert_eq "POSITIVE CONTROL: prefix at the ROOT is EMPTY" \
          "$( [[ -z "$pre_root" ]] && echo silent || echo "FIRES:$pre_root" )" "silent"

echo
echo '=== (iv) THE IN-REPO PREDICATE agrees in BOTH directions ==='
# Behavioural: a block naming a tool that had stopped discriminating would
# still satisfy the spelling assertion above.
assert_contains "repo-root.sh says verdict=no for the non-repo subdirectory" \
                "$(bash "$RR" "$SUB" 2>&1)"  "verdict=no"
assert_contains "repo-root.sh says verdict=yes for the repository root" \
                "$(bash "$RR" "$ROOT" 2>&1)" "verdict=yes"

_th_count_guard
