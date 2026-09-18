#!/usr/bin/env bash
# test-stub-claude-manifest.sh — the stub-`claude` boundary is CHECKED, not
# asserted (your-org/nexus-code#764, follow-up to `#746` / PR `#759`).
#
# Run: bash monitor/watcher/test-stub-claude-manifest.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHAT THIS IS FOR. `#746` found that installing a stub `claude` and putting its
# directory first on PATH does NOT make the stub win: `monitor/locals-env.sh`
# re-fronts `$NEXUS_LOCALS/bin` ahead of whatever the caller prepended, and every
# non-interactive bash reaches it through `BASH_ENV`. A fixture that loses that
# race spawns a REAL, billed Claude Code session into itself and then fails for a
# reason unrelated to what it measures. PR `#759` added `th_require_stub_claude`
# and applied it at the one reported site.
#
# `#764` asks for the rest. Its candidate list of 22 files is a STATIC PROXY
# ("creates an executable named `claude`, never assigns CLAUDE_BIN"), and the
# issue says so. Bolting the guard onto all 22 would be green and wrong: it would
# assert a property at sites that do not have it, which drains the assertion of
# meaning at the site that does.
#
# THE AXIS. `monitor/_claude-bin.sh` resolves in three ORDERED steps — `$CLAUDE_BIN`,
# then `$NEXUS_ROOT/node_modules/.bin/claude`, then PATH. The re-fronting hazard
# can only bite at STEP 3, because steps 1 and 2 are consulted first and are under
# the fixture's own control. Measured in the ambient (hazardous) environment:
#
#     stub at $F/node_modules/.bin/claude, NEXUS_ROOT=$F  -> the fixture's stub
#     stub on PATH only                                   -> locals/bin/claude
#
# So exposure is: REACHES the resolver **and** leaves the choice to step 3. That is
# the axis the MECHANISM varies on, not the axis the original search varied on.
#
# WHAT IS CHECKED HERE. `stub-claude-fixtures.sh` reports the FACTS about each
# fixture's construction; `stub-claude-fixtures.manifest` carries the reviewed
# DISPOSITION and a reason. This suite fails when the two disagree — so a NEWLY
# ADDED fixture that stubs `claude` goes red until somebody classifies it — and
# fails when anything dispositioned `exposed` does not call `th_require_stub_claude`.
#
# NON-VACUITY. The failure mode a manifest test invites is a classifier that
# silently finds nothing agreeing with a manifest regenerated from that nothing:
# two zeros matching perfectly. Guarded four ways — a pinned floor on the total, a
# POSITIVE control (a planted PATH-only fixture must classify `path`), a NEGATIVE
# control (a planted project-local fixture must classify `local`, proving the arms
# are distinguishable), and a NAME control (a file creating `claude-stub.sh` must
# NOT be collected, proving the component match is exact).
#
# The last block is a selftest of `th_require_stub_claude` itself against a
# SIMULATED `#746` hazard: a fake nexus whose `locals/bin` shadows a fixture's own
# PATH stub. Unguarded, that resolves to the wrong binary silently; the helper must
# refuse. This is the assertion that fails before the fix.
#
# COVERAGE BOUNDARY: this checks the POPULATION and the guard rule, not the verdict
# on any individual fixture. Whether a fixture reaches `_claude-bin.sh` at all was
# established by measurement (an instrumented resolver, recorded in the manifest's
# reason column), not by this suite — no static scan can settle it. Fixtures that
# obtain a stub outside a `test-*.sh` file are off the scan's axis; the shared
# `test-integration/_harness.sh` is the one known such site and is carried in the
# manifest explicitly rather than discovered.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLASSIFIER="$_test_dir/stub-claude-fixtures.sh"
MANIFEST="$_test_dir/stub-claude-fixtures.manifest"

# --- the `--population` protocol (your-org/nexus-code#803) -----------------
#
# Asked of the CLASSIFIER so the advertised set is the walked set. Note it
# includes every `test-*.sh` under monitor/ and every shell file under a
# `test-integration/` tree — the second clause is the one a filename-shaped
# guess omits, and `_harness.sh` is its most consequential member.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    bash "$CLASSIFIER" --population
    printf '%s\n' "$CLASSIFIER" "$MANIFEST"
}
gp_handle "$@"

REAL_GREP=$(command -v grep 2>/dev/null || true)
[[ -x "$REAL_GREP" ]] || REAL_GREP=/bin/grep

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s\n           got:  %s\n           want: %s\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_ge() {
    local label="$1" got="$2" floor="$3"
    if (( got >= floor )); then printf '  PASS: %s (%s >= %s)\n' "$label" "$got" "$floor"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %s, floor %s\n' "$label" "$got" "$floor" >&2; FAIL=$(( FAIL + 1 )); fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --------------------------------------------------------------------------
echo '=== classifier and manifest agree (population + classification) ==='
# --------------------------------------------------------------------------
bash "$CLASSIFIER" "$REPO_ROOT" > "$TMP/derived.tsv" 2>"$TMP/derived.err"
assert_eq "classifier ran clean" "$(cat "$TMP/derived.err")" ""

# Manifest carries 6 columns; the first 4 are the classifier's facts.
"$REAL_GREP" -v '^[[:space:]]*#' "$MANIFEST" | "$REAL_GREP" -v '^[[:space:]]*$' \
    | cut -f1-4 | sort > "$TMP/manifest-facts.tsv"

derived_n=$(wc -l < "$TMP/derived.tsv")
manifest_n=$(wc -l < "$TMP/manifest-facts.tsv")

# FLOOR, pinned: an empty classifier cannot agree with an empty manifest.
assert_ge "classifier collects a non-trivial population" "$derived_n" 25

missing=$(comm -23 "$TMP/derived.tsv" "$TMP/manifest-facts.tsv")
stale=$(comm -13 "$TMP/derived.tsv" "$TMP/manifest-facts.tsv")
assert_eq "no fixture missing from the manifest (a NEW stub-claude fixture lands here)" "$missing" ""
assert_eq "no stale manifest row (a fixture that stopped stubbing claude lands here)" "$stale" ""
assert_eq "manifest row count matches derived" "$manifest_n" "$derived_n"

# --------------------------------------------------------------------------
echo '=== the row contract: facts, verdict, and a DATED measurement ==='
# --------------------------------------------------------------------------
# WHAT A ROW MEANS, and what makes it valid. Before your-org/nexus-code#1076 and
# `#1241` this block checked a row's FACTS and left both of its human-authored
# parts effectively unchecked, in the two directions that hide an exposure:
#
#   #1076  the DISPOSITION was checked for MEMBERSHIP in a set but never against
#          the facts that entail it. A recognised-but-WRONG verdict passed. The
#          blind direction was the PERMISSIVE one: relabelling the repo's single
#          genuinely `exposed` site (test-integration/_harness.sh) as `pinned`
#          deletes the only rule the suite enforces about it and still prints
#          ALL TESTS PASSED.
#   #1241  the REASON's `reach=N` — the one hand-maintained number in a row of
#          otherwise regenerated facts — carried no sha, so it silently rotted.
#          A stated `reach=25` measures 29 on a later tree and nothing notices.
#
# So: FACTS (cols 1-4, above) are re-derived by the classifier; the VERDICT
# (col 5) must be ENTAILED by those facts; and any MEASUREMENT stated in the
# reason (col 6) must name the blob it was taken on. A row failing any of the
# three is REFUSED, not reported.

# --- R1: the verdict is entailed by the facts ------------------------------
#
# The manifest's own axis, restated as a closure: `_claude-bin.sh` resolves
# CLAUDE_BIN -> $NEXUS_ROOT/node_modules/.bin/claude -> PATH, and the `#746`
# re-fronting hazard can only bite at the PATH step. So a fixture that decides
# the binary at step 1 or 2 is immune BY CONSTRUCTION, and one that leaves the
# choice to step 3 is not. That is a fact about columns 2 and 3, which means the
# verdict in column 5 is not free-form — it is implied.
#
# ARM ORDER (your-org/nexus-code#1121). The arms below are literal EQUALITY over
# a disjoint set of disposition values, so no input matches two of them and no
# accepting arm can shadow the refusing default. That is why this reads as an
# allowlist and stays one; it would stop being order-independent the day an arm
# became a glob or a substring test.
_verdict_entailed() {   # <path> <step> <pin> <guard> <disposition> -> 0 ok / 1 refuse
    local vp="$1" vstep="$2" vpin="$3" vguard="$4" vdisp="$5"
    case "$vdisp" in
        exposed)
            # step 3 AND reaches the resolver: the hazard can bite, so the
            # fixture MUST assert the resolution it got.
            [[ "$vstep" == path && "$vpin" == no-claude-bin && "$vguard" == guarded ]] ;;
        no-resolver)
            # step 3, but measured never to reach the resolver at all.
            [[ "$vstep" == path && "$vpin" == no-claude-bin ]] ;;
        pinned)
            # decided before PATH is consulted — step 1 (CLAUDE_BIN) or step 2
            # (its own node_modules). Holds with zero exceptions across the
            # manifest; `pinned` is structurally impossible for path+no-claude-bin.
            [[ "$vstep" == local || "$vpin" == claude-bin ]] ;;
        selftest)
            # The ONE declared exemption, and it is pinned to a single path.
            # Without this clause `selftest` is an escape hatch that re-opens
            # `#1076` by another spelling: relabel the exposed harness `selftest`
            # and every entailment arm above is bypassed.
            [[ "$vp" == monitor/watcher/test-stub-claude-manifest.sh ]] ;;
        *)  return 1 ;;   # default DENY: an unrecognised verdict is a refusal
    esac
}

# --- R2: a stated measurement names the blob it was taken on ---------------
#
# `reach` is a property of a BLOB — the manifest header says so — so a bare
# `reach=N` asserts something about a tree nobody named. Required form:
#
#     reach=<N> @blob <sha> @<commit>
#
# THE CITATION CARRIES BOTH, AND THE COMMIT IS NOT DECORATION. A blob sha alone
# can be checked only for EXISTENCE, and an object that exists is not evidence
# it was ever THIS PATH's content — any blob in the repository satisfies that.
# With the commit, the check re-derives `<commit>:<path>` and compares, which is
# the recorded value against a RE-DERIVATION rather than against another
# recorded value (your-org/nexus-code#1163).
#
# AND A LOCAL POSITIVE IS NO MORE PORTABLE THAN A LOCAL NEGATIVE
# (your-org/nexus-code#1173's CI red, and this is where it came from). The first
# version of this check asked `git cat-file -t <blob>` and called anything else
# BROKEN. That passed here and went RED IN CI on 18 rows — because
# `actions/checkout@v6` defaults to `fetch-depth: 1`, and a depth-1 store holds
# the tip tree and nothing else. Reproduced locally in a `--depth 1` clone of
# this very branch: 25 passed, 1 failed, the same 18 rows, byte-identical
# message. Every one of those blobs resolves in a full clone.
#
# git answers "reachable in MY object store", never "exists". So the check must
# distinguish A FABRICATION from AN OBJECT STORE THAT CANNOT ANSWER — a
# distinction the previous version could not make, and whose absence produced a
# confident red about work that was correct.
#
# NOTE WHAT THIS MEANS FOR THE OBVIOUS REMEDY: "cite the ref and resolve through
# it" does NOT restore portability on its own. Measured in the same shallow
# clone, the historical COMMITS are absent too:
#
#     historical blob   a99529a -> Not a valid object name
#     historical commit 127ff1f -> Not a valid object name
#
# The ref is worth citing for the STRENGTH it adds above, not for portability.
# The shallow tier below is what makes the check evaluable everywhere.
#
# FOUR OUTCOMES, and only one of them is a failure:
#   CURRENT      the cited blob IS the file's blob right now. Established with
#                `git hash-object` on the WORKING TREE — no object store at all,
#                so this arm is fully portable and needs no history.
#   HISTORICAL   drifted since the measurement, and `<commit>:<path>` re-derives
#                to exactly the cited blob. Needs a deep store.
#   UNVERIFIABLE drifted, and the store is SHALLOW. Not checkable here, and said
#                so — counted and named, never a silent pass and never a red.
#   BROKEN       the store COULD answer and the citation does not hold. The one
#                failure.
_verify_citation() {   # <repo> <path> <blob> <commit> -> one of the four words
    local r="$1" vp="$2" vb="$3" vc="$4" now at
    now=$(git -C "$r" hash-object -- "$vp" 2>/dev/null) || now=""
    if [[ -n "$now" && "$now" == "$vb"* ]]; then printf CURRENT; return; fi
    if [[ "$(git -C "$r" rev-parse --is-shallow-repository 2>/dev/null)" == true ]]; then
        printf UNVERIFIABLE; return
    fi
    # `git rev-parse <ref>:<path>` POLLUTES STDOUT on a missing path rather than
    # printing nothing, so its output is shape-validated instead of trusted; and
    # the argument is BRACED, because `$vc:$vp` would apply a zsh history
    # modifier in an interactive shell and this idiom gets copied.
    at=$(git -C "$r" rev-parse "${vc}:${vp}" 2>/dev/null) || at=""
    [[ "$at" =~ ^[0-9a-f]{40}$ ]] || at=""
    [[ -n "$at" && "$at" == "$vb"* ]] && printf HISTORICAL || printf BROKEN
}

_undated_reach() {   # echoes each `reach=N` NOT followed by ` @blob <sha> @<commit>`
    printf '%s\n' "$1" | "$REAL_GREP" -oE '[Rr]each=[0-9]+( @blob [0-9a-f]{7,40} @[0-9a-f]{7,40})?' \
        | "$REAL_GREP" -vE ' @blob [0-9a-f]{7,40} @[0-9a-f]{7,40}$' || true
}

bad_exposed=""
bad_exposed=""
bad_disposition=""
bad_reason=""
bad_entailment=""
bad_undated=""
bad_blob=""
stale_rows=""
rows_with_reach=0
rows_current=0
rows_historical=0
rows_unverifiable=0
while IFS=$'\t' read -r path step pin guard disposition reason; do
    [[ -z "${path:-}" ]] && continue
    case "$path" in \#*) continue ;; esac

    case "$disposition" in
        exposed|pinned|no-resolver|selftest) : ;;
        *) bad_disposition+="$path($disposition) " ;;
    esac

    # An exposed fixture MUST call th_require_stub_claude.
    if [[ "$disposition" == exposed && "$guard" != guarded ]]; then
        bad_exposed+="$path "
    fi

    # Every row must justify itself.
    [[ -n "${reason:-}" ]] || bad_reason+="$path "

    # R1 — the verdict must follow from the facts.
    _verdict_entailed "$path" "$step" "$pin" "$guard" "$disposition" \
        || bad_entailment+="$path($step/$pin/$guard->$disposition) "

    # A `no-resolver` verdict rests ENTIRELY on a measured reach of 0; without
    # the number it is an assertion, not a finding.
    if [[ "$disposition" == no-resolver ]] && ! [[ "$reason" == *reach=0\ @blob\ * ]]; then
        bad_entailment+="$path(no-resolver-without-dated-reach=0) "
    fi

    # R2 — every stated measurement is dated, and the date is a real blob.
    undated=$(_undated_reach "$reason")
    [[ -z "$undated" ]] || bad_undated+="$path[$(printf '%s' "$undated" | tr '\n' ',')] "

    while read -r cited_blob cited_commit; do
        [[ -z "$cited_blob" ]] && continue
        rows_with_reach=$(( rows_with_reach + 1 ))
        case "$(_verify_citation "$REPO_ROOT" "$path" "$cited_blob" "$cited_commit")" in
            CURRENT)      rows_current=$(( rows_current + 1 )) ;;
            HISTORICAL)   rows_historical=$(( rows_historical + 1 )); stale_rows+="$path " ;;
            UNVERIFIABLE) rows_unverifiable=$(( rows_unverifiable + 1 )); stale_rows+="$path " ;;
            *)            bad_blob+="$path(@blob $cited_blob @$cited_commit does not re-derive) " ;;
        esac
    done < <(printf '%s\n' "$reason" \
                | "$REAL_GREP" -oE '@blob [0-9a-f]{7,40} @[0-9a-f]{7,40}' \
                | sed -e 's/^@blob //' -e 's/ @/ /')
done < <("$REAL_GREP" -v '^[[:space:]]*#' "$MANIFEST" | "$REAL_GREP" -v '^[[:space:]]*$')

assert_eq "every disposition is from the allowed set" "$bad_disposition" ""
assert_eq "every exposed fixture calls th_require_stub_claude" "$bad_exposed" ""
assert_eq "every manifest row carries a reason" "$bad_reason" ""
assert_eq "#1076: every verdict is ENTAILED by the classifier's facts" "$bad_entailment" ""
assert_eq "#1241: every stated reach names the blob it was measured on" "$bad_undated" ""
assert_eq "#1241: every citation that CAN be checked here re-derives" "$bad_blob" ""

# NON-VACUITY for the two new rules. A rule that evaluates nothing reports the
# same empty string as a rule everything satisfies — the reconciliation that
# agrees with itself. Pin a floor on how many rows each rule actually judged.
assert_ge "R2 judged a non-trivial number of dated measurements" "$rows_with_reach" 25

# NON-VACUITY for R1, driven with PLANTED tuples rather than by hoping the real
# manifest happens to exercise the refusing arms — "no bad rows" and "the rule
# never ran" print the same empty string. These ARE `#1076`'s own plants, kept
# permanent: the suite now carries the corruption it used to pass.
_ve() { _verdict_entailed "$@" && echo accept || echo refuse; }
assert_eq "R1 control: #1076 plant B — the exposed harness relabelled 'pinned' is REFUSED" \
    "$(_ve monitor/watcher/test-integration/_harness.sh path no-claude-bin guarded pinned)" "refuse"
assert_eq "R1 control: …and relabelled 'selftest' — the escape hatch — is REFUSED too" \
    "$(_ve monitor/watcher/test-integration/_harness.sh path no-claude-bin guarded selftest)" "refuse"
assert_eq "R1 control: an exposed row whose fixture does not guard is REFUSED" \
    "$(_ve monitor/watcher/test-planted.sh path no-claude-bin unguarded exposed)" "refuse"
assert_eq "R1 control: an unrecognised verdict is REFUSED by the default arm" \
    "$(_ve monitor/watcher/test-planted.sh local no-claude-bin unguarded probably-fine)" "refuse"
# …and the ACCEPT arms, so the predicate is not satisfied by refusing everything.
assert_eq "R1 control: the harness row as the manifest actually states it is ACCEPTED" \
    "$(_ve monitor/watcher/test-integration/_harness.sh path no-claude-bin guarded exposed)" "accept"
assert_eq "R1 control: a genuine step-2 pinned row is ACCEPTED" \
    "$(_ve monitor/watcher/test-planted.sh local no-claude-bin unguarded pinned)" "accept"

# NON-VACUITY FOR THE ARM THAT NEEDS HISTORY. In a DEEP store the HISTORICAL arm
# must actually have run: "0 broken" and "the arm never executed" print the same
# empty string, and the shallow tier makes that failure mode reachable rather
# than hypothetical — it is precisely how a green would come back from a store
# that checked nothing. In a SHALLOW store the assertion is inverted, because
# there the honest answer is that none of them could be checked.
if [[ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" == true ]]; then
    printf '  NOTE: SHALLOW object store — %d historical citation(s) are UNVERIFIABLE here.\n' \
        "$rows_unverifiable"
    printf '        Not a clearance: a depth-1 checkout holds the tip tree and nothing else,\n'
    printf '        so this arm did not run. Re-run in a full clone to exercise it.\n'
    assert_eq "SHALLOW store: the historical arm is reported unverifiable, not silently passed" \
        "$( (( rows_unverifiable > 0 )) && echo reported || echo silent )" "reported"
else
    assert_eq "DEEP store: the historical arm actually ran (a green from an arm that never executed is not a green)" \
        "$( (( rows_historical > 0 )) && echo ran || echo vacuous )" "ran"
fi

# ---- the four outcomes, driven against PLANTED repositories ---------------
# The real manifest exercises whichever outcomes this host's store allows, which
# is exactly the dependency that produced the CI red. These fixtures exercise
# all four on every host, including the shallow one, by building a real repo and
# a real `--depth 1` clone of it.
_cit="$TMP/cit"; mkdir -p "$_cit/src"
( cd "$_cit/src" && git init -q . \
  && printf 'one\n' > f.sh && git add -A \
  && git -c user.email=t@t -c user.name=t commit -q -m one \
  && printf 'two\n' > f.sh && printf 'sibling\n' > g.sh && git add -A \
  && git -c user.email=t@t -c user.name=t commit -q -m two ) >/dev/null 2>&1
_c1=$(git -C "$_cit/src" rev-parse HEAD~1); _b1=$(git -C "$_cit/src" rev-parse "${_c1}:f.sh")
_c2=$(git -C "$_cit/src" rev-parse HEAD);    _b2=$(git -C "$_cit/src" rev-parse "${_c2}:f.sh")
# A REAL BLOB — a sibling file's content, not a tree. The first draft used
# `${_c2}^{tree}` here and the mutant below SURVIVED: an existence-only check
# (`cat-file -t`) answers `tree`, so it refused for the type rather than for the
# property, and the control passed for the wrong reason. An inert control and a
# live one print the same PASS; only running the mutant separated them.
_other=$(git -C "$_cit/src" rev-parse "${_c2}:g.sh")
git clone -q --depth 1 "file://$_cit/src" "$_cit/shallow" >/dev/null 2>&1

assert_eq "citation control: the cited blob IS the current one -> CURRENT (no object store needed)" \
    "$(_verify_citation "$_cit/src" f.sh "$_b2" "$_c2")" "CURRENT"
assert_eq "citation control: drifted, and <commit>:<path> re-derives -> HISTORICAL" \
    "$(_verify_citation "$_cit/src" f.sh "$_b1" "$_c1")" "HISTORICAL"
assert_eq "citation control: a FABRICATED blob in a deep store -> BROKEN" \
    "$(_verify_citation "$_cit/src" f.sh deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$_c1")" "BROKEN"
# The upgrade over a bare existence test: this object EXISTS in the repository
# and is simply not that path's content at that commit. `cat-file -t` said blob
# and called it verified.
assert_eq "citation control: a REAL BLOB that is not this path's content -> BROKEN" \
    "$(_verify_citation "$_cit/src" f.sh "$_other" "$_c1")" "BROKEN"
assert_eq "citation control: the SAME historical citation in a --depth 1 clone -> UNVERIFIABLE" \
    "$(_verify_citation "$_cit/shallow" f.sh "$_b1" "$_c1")" "UNVERIFIABLE"
# …and the portable arm still answers there, which is what keeps the shallow
# tier from being a blanket exemption.
assert_eq "citation control: a CURRENT citation is still verified in a shallow clone" \
    "$(_verify_citation "$_cit/shallow" f.sh "$_b2" "$_c2")" "CURRENT"

# STALENESS IS REPORTED, NOT RED — and the reason is measured, not a preference.
# All 36 manifested files were touched in the last 90 days (293 commits), and
# this repo ships no instrument that re-derives `reach`. A red on blob drift
# would therefore fire several times a day with no honest way to clear it, and
# its cheapest resolution would be to bump the sha WITHOUT re-measuring — which
# converts a silently stale number into a confidently false one. That is a worse
# defect than the one being fixed, so the guard dates the claim and SAYS which
# rows have drifted; promoting drift to a red belongs with the instrument.
printf '  NOTE: %d of %d dated reach measurements are CURRENT; drifted rows:\n' \
    "$rows_current" "$rows_with_reach"
for _s in $stale_rows; do printf '          STALE  %s\n' "$_s"; done

# --------------------------------------------------------------------------
echo '=== non-vacuity controls (the classifier arms are load-bearing) ==='
# --------------------------------------------------------------------------
CTRL="$TMP/ctrl"
mkdir -p "$CTRL/monitor/watcher"

# POSITIVE control: a PATH-only stub must classify `path`.
cat > "$CTRL/monitor/watcher/test-ctrl-path.sh" <<'CTRLPATH'
mkdir -p "$F/.bin"
cat > "$F/.bin/claude" <<'EOF'
#!/bin/bash
EOF
chmod +x "$F/.bin/claude"
export PATH="$F/.bin:$PATH"
CTRLPATH

# NEGATIVE control: a project-local stub must classify `local`, not `path`.
cat > "$CTRL/monitor/watcher/test-ctrl-local.sh" <<'CTRLLOCAL'
mkdir -p "$F/node_modules/.bin"
printf '#!/bin/bash\n' > "$F/node_modules/.bin/claude"
chmod +x "$F/node_modules/.bin/claude"
CTRLLOCAL

# NAME control: `claude-stub.sh` is NOT a `claude` stub — the component must match
# exactly, or the population inflates with files nobody needs to look at.
cat > "$CTRL/monitor/watcher/test-ctrl-name.sh" <<'CTRLNAME'
printf '#!/bin/bash\n' > "$WORK/claude-stub.sh"
chmod +x "$WORK/claude-stub.sh"
RECORD="$WORK/claude-record.txt"
CTRLNAME

ctrl_out=$(bash "$CLASSIFIER" "$CTRL" 2>/dev/null)
assert_eq "POSITIVE control: PATH-only stub classifies as step 3 (path)" \
    "$("$REAL_GREP" -c 'test-ctrl-path.sh	path	no-claude-bin	unguarded' <<<"$ctrl_out")" "1"
assert_eq "NEGATIVE control: project-local stub classifies as step 2 (local)" \
    "$("$REAL_GREP" -c 'test-ctrl-local.sh	local	no-claude-bin	unguarded' <<<"$ctrl_out")" "1"
assert_eq "NAME control: claude-stub.sh is not collected" \
    "$("$REAL_GREP" -c 'test-ctrl-name.sh' <<<"$ctrl_out")" "0"

# --------------------------------------------------------------------------
echo '=== th_require_stub_claude refuses a stub that LOSES the resolution (#746) ==='
# --------------------------------------------------------------------------
# Simulate the hazard without needing the operator's real environment: a nexus
# whose locals/bin holds a `claude`, fronted ahead of the fixture's own stub —
# exactly what locals-env.sh does on an operator box.
HAZ="$TMP/haz"
mkdir -p "$HAZ/nexus/monitor" "$HAZ/nexus/locals/bin" "$HAZ/fixture/.bin"
cp "$REPO_ROOT/monitor/_claude-bin.sh" "$HAZ/nexus/monitor/_claude-bin.sh"
printf '#!/bin/bash\necho REAL-BINARY\n' > "$HAZ/nexus/locals/bin/claude"
printf '#!/bin/bash\necho FIXTURE-STUB\n'  > "$HAZ/fixture/.bin/claude"
chmod +x "$HAZ/nexus/locals/bin/claude" "$HAZ/fixture/.bin/claude"

# The hazard is NOT PATH order as the fixture leaves it — `th_require_stub_claude`
# prepends the fixture's own bindir, so a naive setup would let the stub win and
# this block would prove nothing. What actually re-fronts locals/bin is
# `monitor/shellenv/bash_env.sh`, sourced by EVERY non-interactive bash via
# BASH_ENV. So drive the REAL re-fronting code against a fake nexus: if someone
# later changes how bash_env.sh fronts, this test notices instead of rotting.
run_helper() {   # <expect-marker> ; echoes combined output, returns helper rc
    BASH_ENV="$REPO_ROOT/monitor/shellenv/bash_env.sh" \
    NEXUS_ROOT="$HAZ/nexus" \
    NEXUS_LOCALS="$HAZ/nexus/locals" \
    bash -c '
        . "'"$_test_dir"'/_test_helpers.sh"
        th_require_stub_claude "'"$HAZ/nexus"'" "'"$HAZ/fixture/.bin"'"
        echo "'"$1"'"
    ' 2>&1
}

# (a) THE PRE-FIX RED. locals/bin holds a `claude` and gets re-fronted ahead of
#     the fixture's stub, so the resolver picks the wrong binary — on a real box
#     that is a live, billed session. The helper must REFUSE (exit 1).
haz_rc=0
haz_out=$(run_helper NOT-REFUSED) || haz_rc=$?
assert_eq "hazard: helper refuses when the stub loses the resolution" "$haz_rc" "1"
assert_eq "hazard: refusal is not a silent pass" \
    "$("$REAL_GREP" -c 'NOT-REFUSED' <<<"$haz_out")" "0"
assert_eq "hazard: refusal names the failure" \
    "$("$REAL_GREP" -c 'ENV-FAIL' <<<"$haz_out")" "1"

# (b) THE CONTROL. Identical setup with the ONE hazardous variable removed — the
#     shadowing binary in locals/bin. The helper must now PASS. A check that
#     fails closed on the good path is worse than none, so this arm is what keeps
#     (a) from being satisfied by a helper that simply always refuses.
rm -f "$HAZ/nexus/locals/bin/claude"
ok_rc=0
ok_out=$(run_helper ACCEPTED) || ok_rc=$?
assert_eq "control: helper accepts when the fixture stub genuinely wins" "$ok_rc" "0"
assert_eq "control: acceptance reached the end" \
    "$("$REAL_GREP" -c 'ACCEPTED' <<<"$ok_out")" "1"

# --------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || { echo 'TESTS FAILED' >&2; exit 1; }
(( PASS >= 33 )) || { echo "TOO FEW ASSERTIONS RAN ($PASS) — a missing assert_* is rc 127 counted by nothing" >&2; exit 1; }
echo 'ALL TESTS PASSED'
