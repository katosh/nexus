#!/usr/bin/env bash
# `ng nexus-identity` and `ng dashboard validate` must agree about the
# identity heading — your-org/nexus-code#886.
#
# THE DEFECT. `cmd_nexus_identity` emitted `## Nexus Identity`; the
# dashboard schema required `## Identity`. So the AUTO-GENERATED block
# failed the validator that exists to accept it, and the two remedies on
# offer were both wrong: hand-patch a block stamped "auto-generated — do
# not edit by hand", or learn to ignore a validator that cries wolf on
# generated content. A validator routinely overridden stops being read,
# and this one is the surface that would otherwise catch a genuinely
# missing section. The reporter `sed`-patched around it four times.
#
# HOW THIS SUITE IS WRITTEN, and why it is not three greps for a heading.
# Each verb is individually correct; it is the PAIR that was not. So the
# suite types NO heading literal anywhere. It reads the canonical heading
# out of `dashboard scaffold`, reads the generated heading out of
# `nexus-identity`, and then requires the validator to accept the second
# — one verb CONSUMING the other's output, which is the shape the issue
# asks for. A grep for `## Nexus Identity` would go green on today's
# strings and say nothing about tomorrow's rename.
#
# The rename is tested directly (Test 6): the heading literal is mutated
# in a copy of `ng`, and the generator/validator/scaffold-prose triple is
# required to move together. That is the property — "the two verbs
# agree" has to survive the next rename, not merely hold today.
#
# Run: bash monitor/watcher/test-ng-identity-dashboard-sync.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-886-sync-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

setup_fake_nexus "$WORK/nexus" --allow-default --repo 'your-org/example-nexus'
NG="$FAKE_NEXUS/monitor/ng"

# Pin the overview issue number in config. `_overview_number` otherwise
# resolves it live, with retry-and-backoff on an empty answer — which
# turns a stub mismatch into a multi-minute hang instead of a failure,
# and makes this suite's runtime depend on whether an earlier verb
# happened to warm the cache. Pinned, it never asks.
cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)                  printf 'your-org/example-nexus' ;;
    github.user_login)            printf 'test-user' ;;
    github.overview_issue_number) printf '1' ;;
    *) [[ $# -ge 2 ]] && { printf '%s' "$2"; exit 0; }; exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"

STUB_DIR="$WORK/bin"
CAPTURE="$WORK/gh-calls.txt"
BODY_CAPTURE="$WORK/gh-body.txt"

make_gh_stub "$STUB_DIR/gh" "$CAPTURE" --with-body-capture "$BODY_CAPTURE" <<'CASES'
    */issues\?labels=nexus:overview*|*/issues?labels=nexus:overview*)
        printf '[{"number":1,"title":"Nexus"}]'
        ;;
    */issues/[0-9]*)
        if [[ "$method" == "PATCH" ]]; then
            printf '%s' '{"html_url":"https://mock.example/issues/1"}'
            return 0 2>/dev/null || exit 0
        fi
        printf '%s' '{"body":"prefix\n<!-- NEXUS_DASHBOARD_START -->\nold middle\n<!-- NEXUS_DASHBOARD_END -->\nsuffix\n"}'
        ;;
    *)
        printf '%s' '{}'
        ;;
CASES

NEUTRAL_CWD="$WORK/neutral"
mkdir -p "$NEUTRAL_CWD"

# $NG_BIN lets Test 6 point the same driver at a mutated copy of `ng`.
#
# `</dev/null` on the invocation is LOAD-BEARING, not tidiness. The shared
# `gh` stub reads stdin to EOF whenever stdin is not a TTY (`make_gh_stub`'s
# stdin block), so a verb that issues a GET with no piped body — e.g.
# `dashboard put` fetching the current issue body — inherits the harness's
# stdin and the stub's `cat` blocks forever. Whether it hangs then depends
# on what the SUITE's own stdin happens to be, which is an intermittent
# hang keyed on how the file was invoked.
NG_BIN="$NG"
run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    : > "$CAPTURE"; : > "$BODY_CAPTURE"
    ( cd "$NEUTRAL_CWD" && run_hermetic \
        NEXUS_ROOT="$FAKE_NEXUS" \
        NEXUS_STATE_DIR="$WORK/state" \
        PATH="$STUB_DIR:$PATH" \
        -- "$NG_BIN" "$@" </dev/null ) >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

# First `## ` heading of a document — how both headings are discovered,
# so no literal is typed into this suite.
first_h2() { grep -m1 '^## ' <<<"$1"; }

# ---- Test 1: read both headings out of the tools themselves -----------

echo '=== the two headings, read from the two verbs (no literal in this suite) ==='
run_ng scaffold_out err rc dashboard scaffold
assert_eq "scaffold exits 0" "$rc" "0"
CANON=$(first_h2 "$scaffold_out")

run_ng ident_out err rc nexus-identity --dry-run
assert_eq "nexus-identity --dry-run exits 0" "$rc" "0"
IDENT=$(first_h2 "$ident_out")

# NON-VACUITY. Everything below compares these two strings; if either
# discovery returned empty, every later assertion would be comparing
# nothing to nothing and passing. This is the silent-zero shape.
if [[ -n "$CANON" && "$CANON" == '## '* ]]; then
    assert_eq "canonical dashboard heading discovered" "$CANON" "$CANON"
else
    assert_eq "canonical dashboard heading discovered" "${CANON:-<empty>}" '## <something>'
fi
if [[ -n "$IDENT" && "$IDENT" == '## '* ]]; then
    assert_eq "generated identity heading discovered" "$IDENT" "$IDENT"
else
    assert_eq "generated identity heading discovered" "${IDENT:-<empty>}" '## <something>'
fi

# ---- Test 2: the reported repro — an identity-only body ---------------
#
# `ng nexus-identity > body.md` then `ng dashboard validate` reported the
# Identity section MISSING on the one section the operator did not write
# by hand. The other five ARE genuinely missing and must still be named:
# a fix that made validate accept anything would be worse than the bug.

echo '=== an identity-only body: identity satisfied, the other five still missing ==='
IDONLY="$WORK/identity-only.md"
printf '%s\n' "$ident_out" > "$IDONLY"
run_ng out err rc dashboard validate --body-file "$IDONLY"
assert_eq "exit 1 — five sections really are missing" "$rc" "1"
assert_not_contains "the identity section is NOT reported missing" "$err" "  - $CANON"
missing_count=$(grep -c '^  - ## ' <<<"$err")
assert_eq "exactly five sections reported missing" "$missing_count" "5"

# ---- Test 3: NEGATIVE CONTROL ----------------------------------------
#
# Test 2 asserts an absence, and an absence is exactly what a broken
# check produces for free. A body whose only heading is a near-miss must
# still be reported missing, or Test 2 proves nothing.

echo '=== negative control: a near-miss heading is still reported missing ==='
NEARMISS="$WORK/near-miss.md"
printf '%sX\n\nsome prose\n' "$CANON" > "$NEARMISS"
run_ng out err rc dashboard validate --body-file "$NEARMISS"
assert_eq "exit 1" "$rc" "1"
assert_contains "a near-miss heading IS reported missing" "$err" "  - $CANON"

# ---- Test 4: the documented build flow, end to end -------------------
#
# One verb consuming the other's output, which is what the issue asks be
# asserted: identity block + the scaffold's remaining sections must
# validate clean.

echo '=== nexus-identity + the scaffold’s other sections → validate exit 0 ==='
FULL="$WORK/full-body.md"
{
    printf '%s\n\n' "$ident_out"
    # Everything from the scaffold AFTER its own Identity section.
    awk -v h="$CANON" '{ if (!f && $0 ~ /^## / && $0 != h) f = 1; if (f) print }' <<<"$scaffold_out"
} > "$FULL"
run_ng out err rc dashboard validate --body-file "$FULL"
assert_eq "exit 0 — the documented flow validates clean" "$rc" "0"
assert_contains "validate says so" "$out" "required sections present"
# Non-vacuity: the assembled body must really carry the other sections,
# not merely have satisfied a validator that stopped checking.
assert_contains "the assembled body carries the identity heading" "$(<"$FULL")" "$IDENT"
assembled_h2=$(grep -c '^## ' "$FULL")
assert_eq "the assembled body has six H2 sections" "$assembled_h2" "6"

# ---- Test 5: `put`'s warn path agrees with `validate` -----------------
#
# `put` warns rather than blocks, which is why the split survived: the
# warning was easy to step past. Both read the same checker, and this
# asserts they stay that way rather than trusting that they do.

echo '=== dashboard put on an identity-carrying body → no identity warning ==='
run_ng out err rc dashboard put --body-file "$FULL"
assert_eq "put exits 0" "$rc" "0"
assert_not_contains "put does not warn about the identity section" "$err" "  - $CANON"
assert_contains "the PATCH was still issued" "$(<"$CAPTURE")" "-X PATCH"

# ---- Test 6: the pointer prose names the generated heading -----------
#
# The scaffold's Identity section is a POINTER to the generated block, so
# it names it in prose. That is a THIRD copy of the same string, and a
# rename that missed it would leave the dashboard pointing at a heading
# that no longer exists.

echo '=== the scaffold’s pointer prose names the generated heading ==='
assert_contains "scaffold prose names the identity block" \
    "$scaffold_out" "${IDENT#\#\# }"
assert_not_contains "…and still does not COPY the block" \
    "$scaffold_out" "nexus-identity:start"

# ---- Test 7: RENAME RESISTANCE ---------------------------------------
#
# The load-bearing one. Mutate the single heading literal in a copy of
# `ng` and require the generator, the validator and the pointer prose to
# move together. If any of the three still held its own copy, this goes
# red — which is the difference between "the strings match today" and
# "they cannot come apart".

echo '=== renaming the heading literal moves all three consumers together ==='
# The mutant must live BESIDE the real `ng`: it resolves its siblings
# (config/load.sh, the monitor helpers) from its own script dir, so a
# copy parked outside the fake nexus fails for reasons unrelated to the
# rename.
MUT_NG="$FAKE_NEXUS/monitor/ng-renamed"
sed "s/^IDENTITY_HEADING=.*/IDENTITY_HEADING='## Provenance Record'/" "$NG" > "$MUT_NG"
chmod +x "$MUT_NG"
if grep -q "IDENTITY_HEADING='## Provenance Record'" "$MUT_NG"; then
    assert_eq "the rename mutation applied" "applied" "applied"
else
    assert_eq "the rename mutation applied" "NOT applied — Test 7 is meaningless" "applied"
fi

NG_BIN="$MUT_NG"
run_ng mut_ident err rc nexus-identity --dry-run
assert_eq "renamed: nexus-identity exits 0" "$rc" "0"
assert_eq "renamed: the generator emits the NEW heading" \
    "$(first_h2 "$mut_ident")" '## Provenance Record'

MUT_IDONLY="$WORK/renamed-identity-only.md"
printf '%s\n' "$mut_ident" > "$MUT_IDONLY"
run_ng out err rc dashboard validate --body-file "$MUT_IDONLY"
assert_not_contains "renamed: the validator still accepts the identity slot" \
    "$err" "  - $CANON"
run_ng mut_scaffold err rc dashboard scaffold
assert_contains "renamed: the pointer prose follows the rename" \
    "$mut_scaffold" 'Provenance Record'
assert_not_contains "renamed: no stale copy of the old name survives" \
    "$mut_scaffold" "${IDENT#\#\# }"
NG_BIN="$NG"

# ---- summary ----------------------------------------------------------
# EXPECTED-COUNT GUARD (required by test-summary-honesty-manifest.sh at the
# `ledger=yes` protection level). An assertion block that never runs reports
# zero failures and reads as a pass.
#   4  Test 1 — both verbs answer, both headings discovered
# + 3  Test 2 — the reported repro
# + 2  Test 3 — the negative control
# + 4  Test 4 — the documented flow, with its two non-vacuity checks
# + 3  Test 5 — put's warn path agrees
# + 2  Test 6 — the pointer prose
# + 6  Test 7 — rename resistance
EXPECTED=$(( 4 + 3 + 2 + 4 + 3 + 2 + 6 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
