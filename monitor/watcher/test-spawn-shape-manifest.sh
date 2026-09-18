#!/usr/bin/env bash
# your-org/nexus-code#789 — the spawn-shape coverage boundary, enforced.
#
# Run: bash monitor/watcher/test-spawn-shape-manifest.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHAT THIS PROTECTS. `absent` is the ONE kill-authorising pane state, and every
# `absent` decision is a reading of what sits under `pane_pid` and when. That is
# fixed by `tmux new-window`, and production does it two different ways —
# `spawn-worker.sh` leaves a SHELL at the pane root and sends the launcher by
# keys; `_respawn.sh` makes the launcher the pane root itself. The shared
# integration harness modelled only the second, so the boot window `#777`
# misclassified was not merely untested but untestable there, and it survived
# `#55`, `#72`, `#643` and a dedicated regression suite.
#
# The gap was invisible because nothing recorded it. This suite records it as
# DATA and fails on drift, in three directions:
#
#   1. FACTS DRIFT   — a call site whose form/pairing changed, or a new one
#                      nobody classified, or a manifest row whose site is gone.
#   2. VERDICT LIES  — the manifest naming a pane root the classifier can see is
#                      something else.
#   3. UNMODELLED    — a `production-spawn` pane root with no `harness-spawn`
#                      counterpart. This is the `#789` regression itself, and it
#                      is the only one of the three that would have been red
#                      before the fix.
#
# Prose cannot be made to fail; this can.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# THE TWO INPUTS ARE OVERRIDABLE SO THIS SUITE CAN BE POINTED AT A FIXTURE
# (your-org/nexus-code#1483). They default to the real tree and the real
# manifest, so every ordinary run is byte-for-byte what it was; the overrides
# exist ONLY for the positive control at the bottom of this file, which
# re-invokes this suite against a planted tree to prove the `UNCLASSIFIED` arm
# can actually fire. A guard never seen to fail is not evidence, and an inert
# check and a clean tree look identical.
REPO_ROOT="${SSM_REPO_ROOT_OVERRIDE:-$(cd "$_test_dir/../.." && pwd)}"
CLASSIFIER="$_test_dir/spawn-shapes.sh"
MANIFEST="${SSM_MANIFEST_OVERRIDE:-$_test_dir/spawn-shapes.manifest}"

# --- the `--population` protocol (your-org/nexus-code#803) -----------------
#
# Asked of the CLASSIFIER, which greps EVERY tracked file for `new-window`.
# So this guard's population is the whole tracked tree and it selects on
# almost any diff — that is the honest answer, not an over-broad one: a file
# with no call site today is exactly the file a new call site lands in.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    bash "$CLASSIFIER" --population
    printf '%s\n' "$CLASSIFIER" "$MANIFEST"
}
gp_handle "$@"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n         got:  %q\n         want: %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
note_fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
note_pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }

[[ -r "$MANIFEST" ]] || { echo "missing manifest: $MANIFEST" >&2; exit 2; }
[[ -r "$CLASSIFIER" ]] || { echo "missing classifier: $CLASSIFIER" >&2; exit 2; }

facts=$(bash "$CLASSIFIER" "$REPO_ROOT")
classifier_rc=$?

# A classifier that returned NOTHING would make every comparison below vacuously
# agreeable if the manifest were also empty, and would otherwise fail in a way
# that reads as "the manifest is stale". Refuse instead — the `#618`/`#770`
# lesson: a zero you cannot vouch for is not a measurement.
if (( classifier_rc != 0 )) || [[ -z "$facts" ]]; then
    echo "REFUSING: spawn-shapes.sh returned rc=$classifier_rc and $(grep -c . <<<"$facts") rows." >&2
    echo "          An empty enumeration cannot adjudicate a manifest." >&2
    exit 2
fi

echo "=== enumeration ==="
fact_rows=$(grep -c . <<<"$facts")
echo "  classifier reported $fact_rows call sites"

# Sanity-check the total against an independent, cruder count, so a classifier
# that silently stopped walking most of the tree cannot pass by agreeing with a
# manifest that shrank with it.
# `xargs -0 grep`, NOT `xargs -0 command grep` — xargs execs a PROGRAM and
# `command` is a shell BUILTIN, so that form exits 127 having never run grep
# (`#707`). xargs does not go through the shell, so the operator's ugrep-wrapping
# grep FUNCTION (`#618`) is never in play here.
candidate_files=$(cd "$REPO_ROOT" && git ls-files -z 2>/dev/null \
    | xargs -0 grep -lI 'new-window' 2>/dev/null \
    | grep -vE '\.(md|manifest|tsv|ansi|png|jpg|pdf)$' | grep -c .)
echo "  candidate files mentioning new-window: $candidate_files"
if (( fact_rows > 0 && candidate_files > 0 && fact_rows >= 10 )); then
    note_pass "enumeration is non-degenerate ($fact_rows rows across $candidate_files candidate files)"
else
    note_fail "enumeration looks degenerate: $fact_rows rows, $candidate_files candidate files"
fi

# ---- manifest rows --------------------------------------------------------
declare -A M_FORM M_ROOT M_SK M_DISP
man_rows=0
while IFS=$'\t' read -r site form root sk disp reason; do
    [[ -n "${site:-}" ]] || continue
    case "$site" in '#'*) continue ;; esac
    man_rows=$(( man_rows + 1 ))
    M_FORM["$site"]="$form"
    M_ROOT["$site"]="$root"
    M_SK["$site"]="$sk"
    M_DISP["$site"]="$disp"
    case "$disp" in
        production-spawn|harness-spawn|fixture-other|production-other|not-a-spawn) ;;
        *) note_fail "unknown disposition '$disp' for $site" ;;
    esac
    # A reason is not decoration: it is what makes a row REVIEWED rather than
    # merely present, and it is the only thing that stops this file degrading
    # into a rubber stamp that agrees with whatever the classifier says.
    [[ -n "${reason:-}" ]] || note_fail "missing reason for $site"
done < "$MANIFEST"
echo "  manifest carries $man_rows rows"

# ---- 1. facts drift -------------------------------------------------------
echo
echo "=== 1. facts vs manifest ==="
drift=0
seen_sites=""
while IFS=$'\t' read -r site form root sk _lineinfo; do
    [[ -n "$site" ]] || continue
    seen_sites+="$site"$'\n'
    if [[ -z "${M_FORM[$site]+x}" ]]; then
        note_fail "UNCLASSIFIED call site (add a row to spawn-shapes.manifest): $site  [$form/$root/$sk]"
        drift=1; continue
    fi
    [[ "${M_FORM[$site]}" == "$form" ]] \
        || { note_fail "form drift at $site: manifest=${M_FORM[$site]} classifier=$form"; drift=1; }
    [[ "${M_SK[$site]}" == "$sk" ]] \
        || { note_fail "sendkeys drift at $site: manifest=${M_SK[$site]} classifier=$sk"; drift=1; }
    # 2. verdict lies. Where the classifier could DERIVE the root, the manifest
    #    may not contradict it. Where it derived `unknown`, the manifest's
    #    reviewed value stands (a launcher held in a variable is unreadable to a
    #    static scan, and saying so beats guessing).
    if [[ "$root" != unknown && "${M_ROOT[$site]}" != n/a && "${M_ROOT[$site]}" != "$root" ]]; then
        note_fail "root verdict contradicts a derivable fact at $site: manifest=${M_ROOT[$site]} classifier=$root"
        drift=1
    fi
done <<<"$facts"

# Manifest rows whose call site no longer exists — the direction that lets a
# manifest rot into fiction while every other check stays green.
while IFS= read -r site; do
    [[ -n "$site" ]] || continue
    grep -qxF "$site" <<<"$seen_sites" \
        || { note_fail "STALE manifest row — no such call site any more: $site"; drift=1; }
done < <(printf '%s\n' "${!M_FORM[@]}")

(( drift == 0 )) && note_pass "manifest and classifier agree on every call site"

# ---- 3. every production shape is modelled --------------------------------
echo
echo "=== 3. production spawn shapes vs harness coverage ==="
prod_roots=$(for s in "${!M_DISP[@]}"; do
    [[ "${M_DISP[$s]}" == production-spawn ]] && echo "${M_ROOT[$s]}"
done | sort -u)
harness_roots=$(for s in "${!M_DISP[@]}"; do
    [[ "${M_DISP[$s]}" == harness-spawn ]] && echo "${M_ROOT[$s]}"
done | sort -u)
echo "  production spawn roots: $(tr '\n' ' ' <<<"$prod_roots")"
echo "  harness   spawn roots: $(tr '\n' ' ' <<<"$harness_roots")"

if [[ -z "$prod_roots" ]]; then
    note_fail "no production-spawn rows at all — the manifest cannot be right"
fi
while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    if grep -qxF "$r" <<<"$harness_roots"; then
        note_pass "production pane root '$r' is modelled by at least one harness spawn"
    else
        note_fail "UNMODELLED production pane root '$r' — no harness-spawn row creates it."
        printf '         This is your-org/nexus-code#789 reoccurring: a shape production uses that\n' >&2
        printf '         no test fixture can produce. Add a spawn mode to _harness.sh.\n' >&2
    fi
done <<<"$prod_roots"

# Both roots production uses must actually be present. Pinning the SET, not just
# the mapping, is what stops the check passing by the manifest quietly dropping
# a production row (which would empty `prod_roots` for that shape and satisfy
# every "is it modelled" question vacuously).
for expect in shell agent; do
    grep -qxF "$expect" <<<"$prod_roots" \
        && note_pass "production still has a '$expect'-rooted spawn on record" \
        || note_fail "production '$expect'-rooted spawn vanished from the manifest — verify before accepting"
done

# ---- EXPECTED-ASSERTION-COUNT GUARD (your-org/nexus-code#807) -------------
#
# An `assert_*` that never runs — a fixture that bailed early, a helper that
# vanished (rc 127 is counted by nothing) — otherwise reports 0 failures and
# reads as a pass. This repo's dominant defect class is exit-0 for work not
# done; the count is what makes the silence loud. The sibling landed in the
# same PR (test-pane-state-boot-absent.sh) carries this guard and this file
# did not, which is what made the omission an oversight rather than a
# judgement.
#
# WHY THE NUMBER IS DERIVED AND NOT PINNED. This suite's assertion count is NOT
# constant across inputs: section 3 emits one "production pane root is
# modelled" assertion PER DISTINCT PRODUCTION ROOT, so a manifest that grows a
# third root legitimately raises the total. A guard pinned to a literal would
# go red on that ordinary growth, get regenerated reflexively, and become
# exactly the rubber stamp this file's own header warns the manifest against.
#
# So the expectation is arithmetic over data the suite already derived:
#
#     7 fixed  = enumeration-non-degenerate (§1)
#              + manifest/classifier agreement (§2)
#              + the two SET assertions for 'shell' and 'agent' (§3)
#     + one per distinct production root
#
# `prod_roots` is read from the MANIFEST, not from whether the loop ran, so a
# per-root assertion that silently fails to execute still shortens the count and
# still trips this guard. That is the property that matters: the expectation
# must not be derivable from the very thing it is checking.
#
# Checked only when FAIL == 0. On a red run the arithmetic legitimately differs
# — §2's agreement assertion is skipped when drift is detected — and a count
# mismatch reported on top of a real failure would only obscure it.
# ---- 5. POSITIVE CONTROL (your-org/nexus-code#1483) -----------------------
#
# THE ONE `none` ROW IN THE R4 CENSUS. This suite's red arm —
# `UNCLASSIFIED call site (add a row to spawn-shapes.manifest)` — had never
# been shown to fire. Every other check here compares a classifier against a
# manifest and passes when they agree, and an INERT check agreeing with a
# manifest is indistinguishable from a correct one. `#1477` is the standing
# example: a suite green throughout an 18-hour outage caused by the guard it
# tests.
#
# THE PLANT IS IN A FIXTURE TREE, NEVER THE REAL ONE: a scratch git repo with
# one file carrying a spawn call site, and a manifest that does not mention it.
# The suite re-invokes ITSELF against those two overrides — so what is proven
# is that THIS FILE's own arm fires, not that some re-implementation of it
# would.
#
# ASSERTED ON THE MESSAGE, NOT ON THE EXIT CODE. A three-file fixture also
# trips the non-degeneracy floor (`fact_rows >= 10`), so rc 1 alone would be
# satisfied by a suite whose UNCLASSIFIED arm was deleted — the control would
# pass while proving nothing. The NEGATIVE arm is the other half: with a
# manifest row present, that same string must be ABSENT, which is what
# separates "the arm fires on a missing row" from "the arm fires always".
#
# Guarded against recursion by the override itself: the inner run has
# SSM_REPO_ROOT_OVERRIDE set and skips this section.
if [[ -z "${SSM_REPO_ROOT_OVERRIDE:-}" ]]; then
    echo
    echo "=== 5. positive control: the UNCLASSIFIED arm fires on a planted site ==="
    _pc_dir=$(mktemp -d)
    _pc_tree="$_pc_dir/tree"
    mkdir -p "$_pc_tree"
    # `git -c`, never the global config: nothing validates a commit's author and
    # this repo has two commits authored `d@e` from a probe that wrote
    # ~/.gitconfig (your-org/nexus-code#1244). No commit is made here anyway —
    # `git ls-files` reads the INDEX, so `git add` alone is enough.
    git -C "$_pc_tree" init -q 2>/dev/null
    mkdir -p "$_pc_tree/monitor"
    printf '#!/usr/bin/env bash\ntmux new-window -t "$S" -n "$W"\n' > "$_pc_tree/monitor/planted.sh"
    git -C "$_pc_tree" add -A 2>/dev/null
    # A fixture that is not its OWN repository root would send `git ls-files` up
    # to the ENCLOSING repo and enumerate THIS repo's files — a confident wrong
    # answer at rc 0 (CLAUDE.md, `git -C <non-repo>` walks up). Check it before
    # believing anything the inner run says.
    _pc_top=$(git -C "$_pc_tree" rev-parse --show-toplevel 2>/dev/null)
    if [[ "$_pc_top" != "$_pc_tree" ]]; then
        note_fail "positive control PRECONDITION: fixture is not its own repo root (toplevel=$_pc_top) — the plant would be read from the enclosing repo"
        note_fail "positive control: skipped, precondition failed"
        note_fail "positive control NEGATIVE arm: skipped, precondition failed"
    else
        printf '# fixture manifest, deliberately empty of rows\n' > "$_pc_dir/empty.manifest"
        _pc_out=$(SSM_REPO_ROOT_OVERRIDE="$_pc_tree" SSM_MANIFEST_OVERRIDE="$_pc_dir/empty.manifest" \
                    bash "${BASH_SOURCE[0]}" 2>&1)
        if [[ "$_pc_out" == *"UNCLASSIFIED call site"* && "$_pc_out" == *"monitor/planted.sh"* ]]; then
            note_pass "a planted call site absent from the manifest IS reported UNCLASSIFIED"
        else
            note_fail "a planted call site absent from the manifest was NOT reported UNCLASSIFIED — this suite's red arm is inert"
        fi
        # NEGATIVE arm: with the row present the arm must go quiet. Without this
        # the positive above is satisfied by an arm that fires unconditionally.
        # `awk NR==1`, NOT `| head -1`. `head` closes the pipe at its Nth
        # line, the writer learns via EPIPE on its NEXT write, and under
        # `pipefail` that inverts the pipeline's status — your-org/nexus-code#622,
        # and `early-exit-readers.manifest` records every such site so a new
        # one is a decision rather than an accident. This one WAS an accident:
        # the local band caught it as a population change on
        # `test-early-exit-reader-manifest.sh`, which is the guard doing
        # exactly its job. awk reads the stream to EOF, so there is no early
        # close to record.
        _pc_rows=$(SSM_REPO_ROOT_OVERRIDE="$_pc_tree" bash "$CLASSIFIER" "$_pc_tree" 2>/dev/null)
        _pc_site=$(printf '%s\n' "$_pc_rows" | awk -F'\t' 'NR==1 { print $1 }')
        if [[ -n "$_pc_site" ]]; then
            printf '%s\tbare\tshell\tsendkeys\tfixture-other\tplanted by the #1483 positive control\n' \
                "$_pc_site" >> "$_pc_dir/empty.manifest"
            _pc_out2=$(SSM_REPO_ROOT_OVERRIDE="$_pc_tree" SSM_MANIFEST_OVERRIDE="$_pc_dir/empty.manifest" \
                        bash "${BASH_SOURCE[0]}" 2>&1)
            if [[ "$_pc_out2" != *"UNCLASSIFIED call site"* ]]; then
                note_pass "…and goes quiet once the row is added (the arm keys on the ROW, not on the fixture)"
            else
                note_fail "the UNCLASSIFIED arm still fires with a matching manifest row — it is not keyed on the row"
            fi
        else
            note_fail "positive control: the classifier found NO call site in the fixture, so neither arm was exercised"
        fi
        # The plant must be the classifier's own reading of the fixture, not an
        # artefact of reading the real tree through a walk-up.
        if [[ "$_pc_site" == monitor/planted.sh* ]]; then
            note_pass "…and the site the control exercised is the PLANTED one, not one from the real tree"
        else
            note_fail "positive control read site '$_pc_site', which is not the planted file — the fixture was not isolated"
        fi
    fi
    rm -rf "$_pc_dir"
fi

n_prod_roots=$(printf '%s' "$prod_roots" | grep -c . || true)
EXPECTED=$(( 7 + n_prod_roots ))

echo
echo "=== summary: $PASS passed, $FAIL failed ($(( PASS + FAIL )) assertions; expected $EXPECTED) ==="
if (( FAIL > 0 )); then
    echo "SOME TESTS FAILED" >&2
    exit 1
fi
if (( PASS + FAIL != EXPECTED )); then
    printf 'ASSERTION COUNT MISMATCH — %d ran, %d expected (7 fixed + %d production root(s)).\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" "$n_prod_roots" >&2
    printf '  Some assertion did not execute. A green over an assertion that never ran is\n' >&2
    printf '  this suite'"'"'s own defect class, one level up.\n' >&2
    exit 1
fi
echo "ALL TESTS PASSED"
