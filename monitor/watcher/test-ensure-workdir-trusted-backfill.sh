#!/usr/bin/env bash
# monitor/watcher/test-ensure-workdir-trusted-backfill.sh
#
# Coverage for `ensure-workdir-trusted.sh --backfill`, which had NONE
# (your-org/nexus-code#1015 finding 3): repo-wide, `--backfill` appeared only
# in its own implementation. It is untested code on the workspace-trust
# mitigation's path, and finding 1 established that its failure mode was a
# SILENT non-zero — the worst combination available, because the exit code
# propagates correctly and there is nothing to read.
#
# THE POINT OF THIS SUITE IS THE STDERR, NOT THE EXIT CODE. The exit code was
# always right. What was missing was any way to learn WHICH member failed, and
# a suite that asserted only on `rc` would have been green throughout the bug.
# So §1 is a mutation-style control: it reverts finding 1's fix in a COPY and
# requires the diagnostic to disappear. Without that control, §2's assertions
# cannot distinguish "the fix works" from "this fixture never had anything to
# report".
#
# Run: bash monitor/watcher/test-ensure-workdir-trusted-backfill.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Every assertion runs against an ISOLATED CLAUDE_CONFIG_DIR — this suite must
# never touch the operator's real ~/.claude.json.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EWT_REAL="$_test_dir/../ensure-workdir-trusted.sh"

# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

PASS=0
FAIL=0
EXPECTED_ASSERTIONS=15

command -v jq >/dev/null 2>&1 || { echo "test: jq required" >&2; exit 2; }
[[ -r "$EWT_REAL" ]] || { echo "test: $EWT_REAL unreadable" >&2; exit 2; }

WORK=$(cd "$(mktemp -d)" && pwd -P)
# `chmod 000` members must be restored before rm, or the trap leaks a tree.
cleanup() { chmod -R u+rwX "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# ---- fixture ------------------------------------------------------------
# One planted member of each kind the enumeration has to get right:
#   alpha          plain depth-2 member
#   .hidden        DOTFILE depth-2 member — invisible to the old bare glob
#   beta/assets    depth-3 — the `<clone>/assets/` convention from #1015
#   locked         UN-SEEDABLE (mode 000): the member whose name must reach stderr
mkfixture() {
    local root="$1"
    mkdir -p "$root/work/alpha" "$root/work/.hidden" "$root/work/beta/assets" "$root/work/locked"
    chmod 000 "$root/work/locked"
}
R1="$WORK/n1"; CFG1="$WORK/cfg1"; mkdir -p "$R1" "$CFG1"
mkfixture "$R1"; printf '{}\n' > "$CFG1/.claude.json"

run_backfill() {  # run_backfill <outvar_stderr> <outvar_rc> <root> <cfgdir> [extra args...]
    local __e="$1" __r="$2" root="$3" cfg="$4"; shift 4
    local _tmp; _tmp=$(mktemp)
    CLAUDE_CONFIG_DIR="$cfg" bash "$EWT_REAL" --backfill "$root" "$@" >/dev/null 2>"$_tmp"
    printf -v "$__r" '%s' "$?"
    printf -v "$__e" '%s' "$(cat "$_tmp")"
    rm -f "$_tmp"
}
seeded_keys() { jq -r '.projects // {} | keys[]' "$1/.claude.json" 2>/dev/null | sort; }

# ---------------------------------------------------------------------------
# §1 CONTROL — revert finding 1's fix in a COPY; the diagnostic must VANISH.
#
# `exec` with redirections and NO command applies them to the CURRENT SHELL,
# permanently. So `exec 9>"$lock" 2>/dev/null` does not scope the silence to
# opening the lock — it silences stderr for the rest of the process, and every
# later per-member diagnostic goes to /dev/null. This control reproduces that
# and requires §2's evidence to disappear, so §2 cannot be green vacuously.
# ---------------------------------------------------------------------------
echo '=== §1 control: the pre-fix unscoped `exec` redirect silences the diagnostic ==='
MUT="$WORK/ewt-mutant.sh"
sed -e 's|{ exec 9>"\$lock"; } 2>/dev/null|exec 9>"$lock" 2>/dev/null|' \
    -e 's|{ exec 9>&-; } 2>/dev/null|exec 9>\&- 2>/dev/null|g' "$EWT_REAL" > "$MUT"
if bash -n "$MUT" 2>/dev/null && ! cmp -s "$MUT" "$EWT_REAL"; then
    ok_mut=1
else
    ok_mut=0
fi
assert_eq "the control mutant differs from the real script and still parses" "$ok_mut" "1"

R2="$WORK/n2"; CFG2="$WORK/cfg2"; mkdir -p "$R2" "$CFG2"
mkfixture "$R2"; printf '{}\n' > "$CFG2/.claude.json"
_mt=$(mktemp)
CLAUDE_CONFIG_DIR="$CFG2" bash "$MUT" --backfill "$R2" >/dev/null 2>"$_mt"; MRC=$?
MERR=$(cat "$_mt"); rm -f "$_mt"
assert_eq "control: the pre-fix form still exits non-zero (fail-closed was never the bug)" \
    "$MRC" "2"
assert_not_contains "control: the pre-fix form does NOT name the un-seedable member" \
    "$MERR" "FAILED to seed"

# ---------------------------------------------------------------------------
# §2 The fixed script: same fixture, same exit code, the evidence now present.
# ---------------------------------------------------------------------------
echo '=== §2 the un-seedable member is NAMED on stderr, and the run still fails ==='
run_backfill ERR1 RC1 "$R1" "$CFG1"
assert_eq "backfill exits non-zero when a member cannot be seeded" "$RC1" "2"
assert_contains "the un-seedable member is named on stderr" "$ERR1" "FAILED to seed"
assert_contains "the un-seedable member is named by PATH, not just counted" "$ERR1" "work/locked"

echo '=== §2 the OTHER members were still seeded (one failure is not an abort) ==='
KEYS1=$(seeded_keys "$CFG1")
assert_contains "a plain depth-2 member was seeded"      "$KEYS1" "$R1/work/alpha"
assert_contains "the nexus root itself was seeded"       "$KEYS1" "$R1"
assert_contains "a DOTFILE member was seeded (the bare glob skipped these silently)" \
    "$KEYS1" "$R1/work/.hidden"

# ---------------------------------------------------------------------------
# §3 SCOPE IS REPORTED, not asserted. The default is depth 2 — the behaviour
# this tool has always had — and what it did NOT visit is a counted number in
# the output rather than a sentence in a comment.
# ---------------------------------------------------------------------------
echo '=== §3 the default depth is 2, and the unvisited remainder is COUNTED ==='
assert_contains "the run reports its scope" "$ERR1" "backfill scope: depth=2"
assert_contains "the run counts what it did NOT visit" "$ERR1" "not-visited-deeper="
assert_not_contains "a depth-3 member is NOT seeded at the default depth" \
    "$KEYS1" "$R1/work/beta/assets"

echo '=== §3 --depth N reaches deeper, and rejects a non-numeric argument ==='
R3="$WORK/n3"; CFG3="$WORK/cfg3"; mkdir -p "$R3" "$CFG3"
mkfixture "$R3"; printf '{}\n' > "$CFG3/.claude.json"
run_backfill ERR3 RC3 "$R3" "$CFG3" --depth 3
assert_contains "--depth 3 seeds the depth-3 member" "$(seeded_keys "$CFG3")" "$R3/work/beta/assets"

BADOUT=$(CLAUDE_CONFIG_DIR="$CFG3" bash "$EWT_REAL" --backfill "$R3" --depth abc 2>&1); BADRC=$?
assert_eq "a non-numeric --depth is REFUSED rather than reaching arithmetic evaluation" "$BADRC" "1"
assert_contains "the refusal names the offending value" "$BADOUT" "got 'abc'"

# ---- verdict ------------------------------------------------------------
# The COUNT guard stays (a vanished assertion is counted by nothing), and the
# SUMMARY goes through the ledger — so a failing assertion that ran inside a
# subshell cannot be lost, which a hand-rolled `$PASS + $FAIL` summary permits.
total=$(( PASS + FAIL ))
if [[ "$total" -ne "$EXPECTED_ASSERTIONS" ]]; then
    printf '  FAIL: assertion COUNT drifted — ran %d, expected %d (a helper that vanished is counted by nothing)\n' \
        "$total" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: every declared assertion executed (%d)\n' "$total"
    PASS=$(( PASS + 1 ))
fi

th_summary_and_exit
