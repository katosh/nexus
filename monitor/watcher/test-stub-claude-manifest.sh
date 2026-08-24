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
echo '=== the guard rule: anything dispositioned `exposed` asserts the resolution ==='
# --------------------------------------------------------------------------
bad_exposed=""
bad_disposition=""
bad_reason=""
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
done < <("$REAL_GREP" -v '^[[:space:]]*#' "$MANIFEST" | "$REAL_GREP" -v '^[[:space:]]*$')

assert_eq "every disposition is from the allowed set" "$bad_disposition" ""
assert_eq "every exposed fixture calls th_require_stub_claude" "$bad_exposed" ""
assert_eq "every manifest row carries a reason" "$bad_reason" ""

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
(( PASS >= 16 )) || { echo "TOO FEW ASSERTIONS RAN ($PASS) — a missing assert_* is rc 127 counted by nothing" >&2; exit 1; }
echo 'ALL TESTS PASSED'
