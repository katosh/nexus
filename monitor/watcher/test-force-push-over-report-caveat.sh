#!/usr/bin/env bash
# test-force-push-over-report-caveat.sh — the worker is TOLD what the checker
# already KNOWS (your-org/nexus-code#835, #898 items 1 and 2).
#
# THE RESIDUAL. `monitor/force-push-check.sh` declares in its own header that
# three routine, destroy-nothing operations are reported UNSAFE — a rebase
# whose replay needed conflict resolution, a content-changing `--amend`, and a
# rebase that flattens a merge — because it matches commits by patch-id and a
# replayed hunk's context differs. Its rc 1 output is BYTE-IDENTICAL to a real
# loss. The three `force-push` rows of `bash-footgun-patterns.conf`, the only
# surface a worker reads at the moment of pushing, said flat "1=UNSAFE and it
# lists the commits you would destroy". Measured at the delivery point on
# fd211309: 1,769 bytes of additionalContext, `patch-id` 0, `over-report` 0,
# `conflict` 0, `amend` 0, `flatten` 0, `multi-URL` 0. The checker knew; the
# worker was not told. And the multi-URL rc 2 (#930) is PERMANENT — a retry
# returns it verbatim — while the conf's "2=REFUSED (could not determine)"
# reads as transient.
#
# WHAT IS PINNED, in order of what it would catch:
#   §1 THE DELIVERED TEXT, not the conf bytes: the hook is fed the real
#      `git push --force` command and its additionalContext must carry the
#      over-report class, the named escape and the permanent rc 2 — and must
#      STILL carry the fail-closed posture (the not-weakened control).
#   §2 THE OVER-REPORT IS REAL (potency): a fixture pair varying ONLY whether
#      the base advanced on the same hunk. Clean replay -> rc 0. Conflict-
#      resolved replay -> rc 1 UNSAFE, with every change present in the tip
#      (witnessed WITHOUT the tool's own predicate). If this ever stops
#      reproducing, the caveat is describing a behaviour that no longer exists
#      and should be removed, not kept.
#   §3 THE PERMANENT rc 2: a two-URL remote is refused, the refusal says
#      PERMANENT, and a second identical run returns the same rc — measured,
#      not asserted from the word.
#
# Run: bash monitor/watcher/test-force-push-over-report-caveat.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
HOOK="$REPO_ROOT/monitor/hooks/bash-footgun-guard.sh"
CONF="$REPO_ROOT/monitor/bash-footgun-patterns.conf"
FPC="$REPO_ROOT/monitor/force-push-check.sh"

# NOT a declaring guard (no `--population`), deliberately: the conf and the
# checker are already enrolled through their own suites, and a declaration
# here needs a guard-populations.manifest row landed in the same change.

WORK=$(mktemp -d -t nexus-fpor-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_NOSYSTEM=1 HOME="$WORK/home"; mkdir -p "$HOME"
git config --global user.email t@t; git config --global user.name t
git config --global init.defaultBranch main 2>/dev/null || true

assert_file_exists "the hook exists"    "$HOOK"
assert_file_exists "the conf exists"    "$CONF"
assert_file_exists "the checker exists" "$FPC"

echo '=== §1 the DELIVERED text at the push, not the conf bytes ==='
if ! command -v jq >/dev/null 2>&1; then
    th_skip "delivered-text arm" "jq is not on PATH — the hook cannot run here"
    _S1=skipped
else
    _S1=ran
    _deliver() {   # <command> -> the additionalContext string
        printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" \
        | NEXUS_ROOT="$REPO_ROOT" NEXUS_STATE_DIR="$WORK/state-$RANDOM$RANDOM" \
          NEXUS_FOOTGUN_PATTERNS="$CONF" NEXUS_WORKER_WINDOW="fpor-test" \
          bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""'
    }
    ctx=$(_deliver 'git push --force origin feat')
    assert_contains "the force-push rule fires on --force"          "$ctx" "bash-footgun-guard [force-push]"
    assert_contains "…names the over-report class"                  "$ctx" "CONFLICT RESOLUTION"
    assert_contains "…the content-changing amend"                   "$ctx" "CONTENT-CHANGING"
    assert_contains "…the merge-flattening rebase"                  "$ctx" "FLATTENS A MERGE"
    assert_contains "…says WHY (patch-id matching)"                 "$ctx" "PATCH-ID"
    assert_contains "…and names the escape"                         "$ctx" "PER-FILE PATCH-ID RECONCILIATION"
    assert_contains "…and marks the multi-URL rc 2 PERMANENT"       "$ctx" "PERMANENT"
    assert_contains "…with its per-URL next step"                   "$ctx" "get-url --push --all"
    # NOT WEAKENED — the control. A caveat that softened the posture would be
    # worse than none; the fail-closed sentences must survive verbatim.
    assert_contains "control: still FAILS CLOSED"                   "$ctx" "FAILS CLOSED"
    assert_contains "control: rc 2 is still NOT a clearance"        "$ctx" "NOT a clearance"
    assert_contains "control: still says a false SAFE is the cost"  "$ctx" "false SAFE costs a sibling"
    # The other two spellings of a force-push share the tag and the text.
    ctx2=$(_deliver 'git push -f origin feat')
    assert_contains "the -f spelling carries the same caveat"       "$ctx2" "PER-FILE PATCH-ID RECONCILIATION"
    ctx3=$(_deliver 'git push origin +feat')
    assert_contains "the +refspec spelling carries the same caveat" "$ctx3" "PER-FILE PATCH-ID RECONCILIATION"
    # A plain push must NOT get the force-push text: the caveat is about rc 1
    # of a force-push check, and a worker doing a fast-forward has no rc 1.
    ctx4=$(_deliver 'git push origin feat')
    assert_not_contains "a plain push does not receive the over-report caveat" "$ctx4" "PER-FILE PATCH-ID RECONCILIATION"
fi

echo
echo '=== §2 POTENCY: the over-report is real — conflict-resolved rebase reads UNSAFE ==='
# _rig <name> <same-hunk:yes|no> — a bare remote, a feature branch pushed to
# it, a base advance, then a rebase of the feature onto the new base. Prints
# the clone path. Only <same-hunk> varies.
_rig() {
    # One assignment per line: `local a="$1" b="$a"` expands `$a` BEFORE the
    # builtin runs, so `b` reads the caller's (unset) `a` under `set -u`.
    local name="$1" same="$2" R C
    R="$WORK/$name.git"; C="$WORK/$name"
    git init -q --bare "$R"
    git init -q "$C"; cd "$C" || return 1
    printf 'l1\nl2\nl3\n' > shared.txt; printf 'x\n' > other.txt
    git add . && git commit -qm base
    git remote add origin "$R"; git push -q origin HEAD:main 2>/dev/null
    git checkout -qb feat
    printf 'l1\nFEAT\nl3\n' > shared.txt; git commit -qam "feat edit"
    git push -q origin feat 2>/dev/null
    git checkout -q main 2>/dev/null || git checkout -q master
    if [[ "$same" == yes ]]; then
        printf 'l1\nBASE\nl3\n' > shared.txt      # the SAME hunk
    else
        printf 'y\n' > other.txt                    # an UNRELATED file
    fi
    git commit -qam "base advance"; git push -q origin HEAD:main 2>/dev/null
    git checkout -q feat
    if [[ "$same" == yes ]]; then
        git rebase -q main >/dev/null 2>&1 || {
            printf 'l1\nFEAT\nl3\n' > shared.txt; git add shared.txt
            GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
        }
    else
        git rebase -q main >/dev/null 2>&1
    fi
    cd "$WORK" || return 1
    printf '%s' "$C"
}
CA=$(_rig clean no); CB=$(_rig conflict yes)
# A TEST THAT RUNS GIT MUST PROVE WHERE IT RUNS. `git -C ""` and `cd ""` are
# no-ops, so an empty rig path would aim every command below — including a
# `remote set-url --add` — at THIS repository. Refuse before the first one.
[[ -d "$CA/.git" && -d "$CB/.git" ]] || th_abort "rig failed to build (CA='$CA' CB='$CB') — refusing to run git against the wrong tree"
# WITNESS, independent of the tool's predicate: in BOTH rigs the feature's
# change is in the tip and the base's change is in the tip's history.
assert_eq "witness A: the feature edit survives the clean rebase"     "$(sed -n 2p "$CA/shared.txt")" "FEAT"
assert_eq "witness B: the feature edit survives the conflicted rebase" "$(sed -n 2p "$CB/shared.txt")" "FEAT"
assert_eq "witness B: …and the base advance is an ancestor of the tip" \
          "$(git -C "$CB" log --format=%s | grep -c '^base advance$')" "1"
_rcA=0; outA=$(cd "$CA" && bash "$FPC" origin feat 2>&1) || _rcA=$?
_rcB=0; outB=$(cd "$CB" && bash "$FPC" origin feat 2>&1) || _rcB=$?
assert_eq "row A (base advanced on an UNRELATED file): clean replay is SAFE, rc 0" "$_rcA" "0"
assert_eq "row B (base advanced on the SAME hunk): conflict-resolved replay is UNSAFE, rc 1" "$_rcB" "1"
assert_contains "…listing the pre-rebase feature commit it could not patch-id-match" "$outB" "feat edit"
# The two rigs differ ONLY in which file the base advanced on; both destroyed
# nothing. That is the over-report the conf now names, reproduced here so the
# caveat is a description of measured behaviour rather than a belief.

echo
echo '=== §3 the multi-URL rc 2 is PERMANENT, and says so ==='
R2="$WORK/second.git"; git init -q --bare "$R2"
# Both as PUSH urls: a lone `--add --push` REPLACES the push destination with
# the new one (get-url --push --all then lists ONE), which is a single-URL
# push that lands rc 3. Two entries make git emit two `To` blocks.
git -C "$CA" remote set-url --add --push origin "$WORK/clean.git"
git -C "$CA" remote set-url --add --push origin "$R2"
assert_eq "precondition: origin has two push URLs" \
          "$(git -C "$CA" remote get-url --push --all origin | grep -c .)" "2"
_rcM1=0; outM1=$(cd "$CA" && bash "$FPC" origin feat 2>&1) || _rcM1=$?
_rcM2=0; outM2=$(cd "$CA" && bash "$FPC" origin feat 2>&1) || _rcM2=$?
assert_eq       "a two-URL remote is REFUSED, rc 2"             "$_rcM1" "2"
assert_contains "…naming the multi-URL cause"                    "$outM1" "multi-URL remote"
assert_contains "…and saying it is PERMANENT"                    "$outM1" "PERMANENT"
assert_contains "…with the per-URL next step"                    "$outM1" "get-url --push --all"
assert_eq       "…and a retry returns the SAME rc (measured permanence)" "$_rcM2" "2"

# ---- assertion-count guard ------------------------------------------------
EXPECTED_ASSERTIONS=3
[[ "$_S1" == ran ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 14 ))
EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 6 + 6 ))
assert_eq "assertion TOTAL matches the EXPECTED total (§1=$_S1)" "$(( PASS + FAIL ))" "$EXPECTED_ASSERTIONS"
th_summary_and_exit
