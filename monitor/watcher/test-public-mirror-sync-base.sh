#!/usr/bin/env bash
# test-public-mirror-sync-base.sh — pin the MERGE-BASE trap in the mirror sync
# recipe, and the behaviour of the script that closes it.
#
# THE TRAP (your-org/nexus-code#979 §5). Reconstructing the mirror as a
# three-way merge is sound. The merge BASE decides whether it is correct, and it
# fails SILENTLY, in the leakier direction. Take a file unchanged between two
# source commits and a dictionary rule that improved between them — leaky value
# L, good value G:
#
#   CORRECT base = scrub_old(source_old)    WRONG base = scrub_now(source_old)
#     base   L                                base   G  (improvement IS the base)
#     ours   L   (what the mirror carries)    ours   L
#     theirs G   (today's scrub)              theirs G
#     -> only theirs moved; take G  ✓         -> ours reads as a deliberate
#                                                public-side revert G->L and
#                                                theirs as unchanged; take L  ✗
#
# No error. No conflict. The loss is exactly proportional to how much the
# dictionary has improved, so the better the scrub gets the more the wrong base
# throws away. §1 below builds that scenario end to end and asserts BOTH
# outcomes — the wrong one included, because a test that only pins the right
# answer cannot tell you the trap is still there.
#
# WHY IT IS CHEAP TO GET RIGHT, and therefore easy to get wrong: the dictionary
# is versioned in the same repository as the source, so `scrub_old(source_old)`
# is just "check out source_old — dictionary and all — and build". There is no
# old dictionary to reconstruct. The whole trap is accidentally using the
# CURRENT checkout's dictionary against an OLD source tree, which is the default
# if you build the base any other way.
#
# Hermetic: a purpose-built two-commit fixture repo with a SYNTHETIC dictionary
# (`qzcorp`, never a real internal identifier — this suite ships to the public
# mirror and must itself be leak-clean). Only the real toolkit scripts under
# test are copied in.
#
# Run: bash monitor/watcher/test-public-mirror-sync-base.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Exit 77 = declined to run.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)
TOOLKIT="$SRC_ROOT/monitor/public-mirror"

PASS=0; FAIL=0
pass(){ printf '  PASS: %s\n' "$1"; _th_pass; }
fail(){ printf '  FAIL: %s\n' "$1" >&2; _th_fail; }
decline(){ printf 'DECLINED (exit 77): %s\n' "$1" >&2; exit 77; }

for f in scrub.pl build.sh leak-gate.sh sync-base.sh; do
    [ -r "$TOOLKIT/$f" ] || decline "missing toolkit file $TOOLKIT/$f"
done
command -v git >/dev/null 2>&1 || decline "git not on PATH"
command -v perl >/dev/null 2>&1 || decline "perl not on PATH"

SHORTTMP="/tmp/tt-$$"
mkdir -p "$SHORTTMP" || decline "cannot create short temp dir $SHORTTMP"
WORK=$(mktemp -d "$SHORTTMP/syncbase.XXXXXX") || decline "mktemp failed under $SHORTTMP"
cleanup(){ rm -rf "$WORK" "$SHORTTMP"; }
trap cleanup EXIT

# --- fixture: two source commits, dictionary improved between them ----------
#
# `prose.txt` is BYTE-IDENTICAL at both commits. Only the dictionary moves: at
# `old` it has no rule for `qzhost`, at `new` it does. That is the whole
# scenario — a file nobody touched, and a scrub that got better.

REPO="$WORK/repo"
mkdir -p "$REPO/pm"
cp "$TOOLKIT/scrub.pl" "$TOOLKIT/build.sh" "$TOOLKIT/leak-gate.sh" "$TOOLKIT/sync-base.sh" "$REPO/pm/"

cat > "$REPO/pm/mapping.tsv" <<'MAP'
map	qzcorp	your-org	<your-org>
deny	qzcorp
exclude	pm/mapping.tsv
MAP
printf 'owner qzcorp runs the box named qzhost daily\n' > "$REPO/prose.txt"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm old ) >/dev/null 2>&1
OLD=$( cd "$REPO" && git rev-parse HEAD )

# The dictionary improves. `prose.txt` is not touched.
cat > "$REPO/pm/mapping.tsv" <<'MAP'
map	qzcorp	your-org	<your-org>
map	qzhost	genericnode	genericnode
deny	qzcorp
deny	\bqzhost\b
exclude	pm/mapping.tsv
MAP
( cd "$REPO" && git add -A && git commit -qm 'dictionary: cover the hostname' ) >/dev/null 2>&1
NEW=$( cd "$REPO" && git rev-parse HEAD )

if [[ "$OLD" != "$NEW" ]] && \
   [[ "$( cd "$REPO" && git rev-parse "${OLD}:prose.txt" )" == "$( cd "$REPO" && git rev-parse "${NEW}:prose.txt" )" ]]; then
    pass "fixture: two commits, prose.txt byte-identical, only the dictionary moved"
else
    fail "fixture is not the scenario under test (prose.txt differs, or the commits do not)"
fi

# --- build the three inputs -------------------------------------------------

build_at(){  # <sha> <outdir> [<override-mapping-from-sha>]
    local sha="$1" out="$2" mapfrom="${3:-}"
    git clone -q --no-hardlinks "$REPO" "$out" 2>/dev/null || return 1
    git -C "$out" checkout -q --detach "$sha" || return 1
    if [ -n "$mapfrom" ]; then
        git -C "$REPO" show "${mapfrom}:pm/mapping.tsv" > "$out/pm/mapping.tsv" || return 1
    fi
    # --allow-dirty: the wrong-base leg deliberately overwrites pm/mapping.tsv in
    # the checkout without staging it, so this fixture builds a DIRTY tree on
    # purpose (your-org/nexus-code#1001).
    ( cd "$out" && bash pm/build.sh --yes --allow-dirty pm/mapping.tsv >/dev/null 2>&1 ) || return 1
}

build_at "$OLD" "$WORK/correct"              || fail "could not build scrub_old(old)"
build_at "$OLD" "$WORK/wrong"      "$NEW"    || fail "could not build scrub_now(old)"
build_at "$NEW" "$WORK/theirs"               || fail "could not build scrub_now(new)"

L=$(cat "$WORK/correct/prose.txt" 2>/dev/null)
G=$(cat "$WORK/theirs/prose.txt" 2>/dev/null)
Wb=$(cat "$WORK/wrong/prose.txt" 2>/dev/null)

# The premise, asserted rather than assumed: the two candidate bases must
# actually DIFFER, or §1 below proves nothing.
if [[ "$L" == *qzhost* ]] && [[ "$G" != *qzhost* ]] && [[ "$Wb" == "$G" ]]; then
    pass "the two candidate bases differ: scrub_old keeps the leaky token, scrub_now does not"
else
    fail "premise failed — correct=[$L] wrong=[$Wb] theirs=[$G]"
fi

# --- 1. the trap, both outcomes --------------------------------------------
#
# `ours` is the mirror: it carries what the previous sync shipped, i.e. L.

printf '%s\n' "$L"  > "$WORK/ours.txt"
printf '%s\n' "$L"  > "$WORK/base-correct.txt"
printf '%s\n' "$Wb" > "$WORK/base-wrong.txt"
printf '%s\n' "$G"  > "$WORK/theirs.txt"

merged_ok=$(git merge-file -p "$WORK/ours.txt" "$WORK/base-correct.txt" "$WORK/theirs.txt" 2>/dev/null); rc_ok=$?
merged_bad=$(git merge-file -p "$WORK/ours.txt" "$WORK/base-wrong.txt" "$WORK/theirs.txt" 2>/dev/null); rc_bad=$?

if (( rc_ok == 0 )) && [[ "$merged_ok" != *qzhost* ]]; then
    pass "CORRECT base scrub_old(old): the merge takes the improved value, no conflict"
else
    fail "correct base did not yield the improved value (rc=$rc_ok): $merged_ok"
fi

if (( rc_bad == 0 )) && [[ "$merged_bad" == *qzhost* ]]; then
    pass "WRONG base scrub_now(old): the merge silently keeps the LEAKY value, no conflict"
else
    fail "wrong base did not reproduce the trap (rc=$rc_bad): $merged_bad — if this stops reproducing, the trap changed shape; do not just delete the assertion"
fi

# The silence is the defect, so name it separately: a conflict would at least
# have asked a human.
if (( rc_bad == 0 )); then
    pass "the wrong base produces NO conflict — nothing asks a human"
else
    fail "expected the wrong base to merge cleanly (that silence is the defect); got rc=$rc_bad"
fi

# --- 2. sync-base.sh builds the CORRECT base --------------------------------
#
# The load-bearing and counter-intuitive assertion: its output must CONTAIN the
# leaky value, because it reproduces the artifact the previous sync shipped. A
# base that looks clean is the wrong base.

LEDGER="$REPO/pm/sync-log.tsv"
printf 'sync\t2026-01-01\t%s\t0000000\tfixture\n' "$OLD" > "$LEDGER"
( cd "$REPO" && git add -A && git commit -qm 'ledger' ) >/dev/null 2>&1

sb_out=$( cd "$REPO" && bash pm/sync-base.sh "$WORK/sb-out" 2>/dev/null ); sb_rc=$?
sb_sha=$(awk -F= '$1=="base_source_sha"{print $2}' <<<"$sb_out")
sb_gate=$(awk -F= '$1=="gate"{print $2}' <<<"$sb_out")

if (( sb_rc == 0 )) && [[ "$sb_sha" == "$OLD" ]]; then
    pass "sync-base.sh takes the source sha from the ledger's last row"
else
    fail "sync-base.sh did not resolve the ledger sha (rc=$sb_rc, got '$sb_sha', want '$OLD')"
fi
if [[ -f "$WORK/sb-out/prose.txt" ]] && grep -q 'qzhost' "$WORK/sb-out/prose.txt"; then
    pass "sync-base.sh reproduces the OLD artifact — the leaky token is present, which is correct"
else
    fail "sync-base.sh built a base without the old value; it used today's dictionary and is the WRONG base"
fi
[[ "$sb_gate" == clean ]] && pass "sync-base.sh gates the base it built" \
                          || fail "sync-base.sh reported gate=$sb_gate (expected clean)"
# It stages, so the tree it reports is the tree that would be published.
if [[ -n "$(git -C "$WORK/sb-out" write-tree 2>/dev/null)" ]] \
   && ! git -C "$WORK/sb-out" diff --quiet 2>/dev/null; then
    fail "sync-base.sh left unstaged changes — git write-tree would record the UNSCRUBBED tree"
else
    pass "sync-base.sh stages its output (git write-tree records the scrubbed tree, not the source)"
fi

# --- 3. refusals ------------------------------------------------------------
#
# Each refusal is asserted on its EXIT CODE, not on a message: a script that
# refuses for the wrong reason still refuses, and a test that reads only the
# text cannot tell the two apart.

( cd "$REPO" && bash pm/sync-base.sh >/dev/null 2>&1 ); rc=$?
(( rc == 2 )) && pass "refuses with no outdir (exit 2)" || fail "no-outdir gave rc=$rc, want 2"

( cd "$REPO" && bash pm/sync-base.sh "$WORK/sb-out" >/dev/null 2>&1 ); rc=$?
(( rc == 2 )) && pass "refuses to build over an existing outdir (exit 2)" \
              || fail "existing-outdir gave rc=$rc, want 2"

( cd "$REPO" && bash pm/sync-base.sh "$WORK/sb-nope" deadbeefdeadbeef >/dev/null 2>&1 ); rc=$?
(( rc == 2 )) && pass "refuses an unresolvable sha (exit 2)" || fail "bad-sha gave rc=$rc, want 2"

# A ledger with no rows must REFUSE, not silently fall back to HEAD — falling
# back would build scrub_now(source_now), which is not a base at all.
printf '# comments only, no rows\n' > "$LEDGER"
( cd "$REPO" && git add -A && git commit -qm 'empty ledger' ) >/dev/null 2>&1
( cd "$REPO" && bash pm/sync-base.sh "$WORK/sb-empty" >/dev/null 2>&1 ); rc=$?
(( rc == 2 )) && pass "refuses a ledger with no sync rows (exit 2, never a silent HEAD fallback)" \
              || fail "empty-ledger gave rc=$rc, want 2"

# --- 4. a base it could not gate is never reported as a base ----------------
#
# "I could not check this" and "I checked it and it was clean" must not share a
# spelling — that equivalence is the defect class this whole batch is about.
# The REACHABLE form of it here is a commit carrying no dictionary: build.sh
# refuses (it has no rules to apply), so sync-base must exit non-zero and print
# no base at all, rather than emitting a tree nobody gated.
#
# `sync-base.sh` also carries a `gate=UNCHECKED` spelling for the case where the
# build succeeds but the dictionary cannot be recovered from the commit. That
# arm is defence in depth and is NOT reachable through build.sh's own
# precondition, so it is deliberately not asserted here — an assertion that
# cannot fail is the thing this suite is about.
NODICT="$WORK/nodict"
mkdir -p "$NODICT/pm"
cp "$TOOLKIT/scrub.pl" "$TOOLKIT/build.sh" "$TOOLKIT/leak-gate.sh" "$TOOLKIT/sync-base.sh" "$NODICT/pm/"
printf 'plain\n' > "$NODICT/f.txt"
( cd "$NODICT" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm init ) >/dev/null 2>&1
ND=$( cd "$NODICT" && git rev-parse HEAD )
nd_out=$( cd "$NODICT" && bash pm/sync-base.sh "$WORK/nd-out" "$ND" 2>/dev/null ); nd_rc=$?
if (( nd_rc != 0 )); then
    pass "a commit with no dictionary refuses (exit $nd_rc) rather than emitting an ungated base"
else
    fail "sync-base exited 0 for a commit with no dictionary — it reported a base nobody gated"
fi
if ! grep -q 'gate=clean' <<<"$nd_out"; then
    pass "…and prints no gate=clean it cannot stand behind"
else
    fail "sync-base printed gate=clean for a commit whose dictionary it never read"
fi

# --- assertion-count guard ---------------------------------------------------
EXPECTED_ASSERTIONS=16
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} + 1 ))
if (( TOTAL_ASSERTIONS == EXPECTED_ASSERTIONS )); then
    pass "assertion total is exactly $EXPECTED_ASSERTIONS"
else
    fail "assertion total $TOTAL_ASSERTIONS != expected $EXPECTED_ASSERTIONS — a branch was skipped or ran short"
fi

th_summary_and_exit
