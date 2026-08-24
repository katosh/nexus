#!/usr/bin/env bash
# Unit tests for `ng report-check` (cmd_report_check in monitor/ng).
#
# Run: bash monitor/watcher/test-ng-report-check.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: build a minimal fake nexus tree (ng + stubbed
# config/load.sh), then synthesise reports with controlled defects
# and assert the verb's exit code + stderr against each defect.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s\n           expected: %s\n' "$label" "$needle" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2; FAIL=$(( FAIL + 1 ))
    else printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 )); fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config"
cp "$NG_REAL" "$FAKE_NEXUS/monitor/ng"
# `ng` sources monitor/_bookkeeping.sh and REFUSES TO START without
# it (your-org/nexus-code#601/#605: degrading to the silent-coercion
# behaviour it replaces is worse than refusing). Copy it alongside.
cp "$(dirname "$NG_REAL")/_bookkeeping.sh" "$FAKE_NEXUS/monitor/_bookkeeping.sh"
NG="$FAKE_NEXUS/monitor/ng"

# Pin the state dir into the fixture (your-org/nexus-code#833). Copying `ng`
# here does NOT sandbox it: `_resolve_state_dir` prefers the INHERITED
# `$NEXUS_ROOT` over its own location, so from an agent shell this fixture
# appended to the OPERATOR'S canonical `ng-usage.jsonl` — 39 rows from this
# suite alone, measured on the primary. The directory is CREATED because the
# usage tap no-ops without one, and a fixture that silently stops exercising
# the write path is a green that proves nothing.
mkdir -p "$FAKE_NEXUS/monitor/.state"
export NEXUS_STATE_DIR="$FAKE_NEXUS/monitor/.state"
cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf 'default-org/default-repo' ;;
    github.user_login)  printf 'test-user' ;;
    monitor.report_min_chars) printf '%s' "${2:-500}" ;;
    *) [[ $# -ge 2 ]] && { printf '%s' "$2"; exit 0; } ; exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"

run_check() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    "$NG" report-check "$@" >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

# A complete report (≥500 body chars; all sections; valid frontmatter;
# no placeholders). Used as the baseline; modified per-test for the
# sad-path probes.
write_complete_report() {
    local path="$1"
    cat > "$path" <<'EOF'
---
project: nexus
date: 2026-05-10
session-id: 4e8f1c2b-3a91-4d77-b9e0-5f2d0a1c7e8a
window: foo-window
trigger: #42 (comment 9999)
status: completed
---

# Demonstration report (complete)

## Summary

Shipped the report-check verb and integrated it as a pre-flight in
ng wrap-up. Verb validates frontmatter, sections, body length, and
placeholder absence.

## What Was Done

- Added cmd_report_check to monitor/ng.
- Wired it into cmd_wrap_up at the start, before upload.
- Added 36 test assertions across multiple suites.
- Updated nexus.report skill with the schema.
- Updated nexus.worker-defaults skill with the report-init bullet.

## Current State

- Branch operator/ng-wrap-up-and-friction-fixes, four commits.
- Tests green across all watcher suites except test-emit-gate.sh
  which is a pre-existing failure on origin/main.
- PR your-org/nexus-code#4 carries every change.

## What Remains

- Address any follow-up review feedback on PR #4.
- Land round-4 changes once review clears.

## How to Resume

- git checkout operator/ng-wrap-up-and-friction-fixes
- bash monitor/watcher/test-ng-report-check.sh
- Read this report for context.
EOF
}

# ---- Test 1: complete report → exit 0 ----------------------------------

echo '=== complete report → exit 0 ==='
GOOD="$WORK/good.md"
write_complete_report "$GOOD"
run_check out err rc "$GOOD"
assert_eq        "exit 0 on complete report"          "$rc" "0"
assert_contains  "stdout reports OK"                  "$out" "OK"

# ---- Test 2: file missing → exit 2 ------------------------------------

echo '=== file missing → exit 2 ==='
run_check out err rc "$WORK/nope.md"
assert_eq        "exit 2 on missing file"             "$rc" "2"
assert_contains  "stderr names missing-file"          "$err" "missing"

# ---- Test 3: missing frontmatter → exit 1 -----------------------------

echo '=== missing frontmatter → exit 1 ==='
NOFM="$WORK/no-fm.md"
write_complete_report "$NOFM"
# Strip the frontmatter (first '---' to second '---' inclusive).
awk 'BEGIN{flag=0} /^---$/{flag++; next} flag>=2{print}' "$NOFM" > "$NOFM.tmp" && mv "$NOFM.tmp" "$NOFM"
run_check out err rc "$NOFM"
assert_eq        "exit 1 with no frontmatter"         "$rc" "1"
assert_contains  "stderr complains about frontmatter" "$err" "frontmatter"

# ---- Test 4: missing required field → exit 1 --------------------------

echo '=== frontmatter missing session-id → exit 1 ==='
NOSID="$WORK/no-sid.md"
write_complete_report "$NOSID"
sed -i '/^session-id:/d' "$NOSID"
run_check out err rc "$NOSID"
assert_eq        "exit 1 with missing session-id"     "$rc" "1"
assert_contains  "stderr names session-id"            "$err" "session-id"

# ---- Test 5: session-id = "unknown" → exit 1 --------------------------

echo '=== frontmatter session-id: unknown → exit 1 ==='
SUNK="$WORK/sid-unk.md"
write_complete_report "$SUNK"
sed -i 's/^session-id:.*/session-id: unknown/' "$SUNK"
run_check out err rc "$SUNK"
assert_eq        "exit 1 with session-id=unknown"     "$rc" "1"
assert_contains  "stderr names the unknown sentinel"  "$err" "unknown"

# ---- Test 6: status = invalid value → exit 1 --------------------------

echo '=== frontmatter status: bogus → exit 1 ==='
BAD_STATUS="$WORK/bad-status.md"
write_complete_report "$BAD_STATUS"
sed -i 's/^status:.*/status: half-done/' "$BAD_STATUS"
run_check out err rc "$BAD_STATUS"
assert_eq        "exit 1 with bad status value"       "$rc" "1"
assert_contains  "stderr names the canonical set"     "$err" "completed|partial|blocked"

# ---- Test 7: missing one section → exit 1 -----------------------------

echo '=== missing "## How to Resume" → exit 1 ==='
NOSEC="$WORK/no-section.md"
write_complete_report "$NOSEC"
# Strip from "## How to Resume" to EOF.
awk '/^## How to Resume/{flag=1} !flag{print}' "$NOSEC" > "$NOSEC.tmp" && mv "$NOSEC.tmp" "$NOSEC"
run_check out err rc "$NOSEC"
assert_eq        "exit 1 with missing section"        "$rc" "1"
assert_contains  "stderr names the missing section"   "$err" "How to Resume"

# ---- Test 8: body too short → exit 1 ----------------------------------

echo '=== body < 500 chars → exit 1 (default threshold) ==='
SHORT="$WORK/short.md"
cat > "$SHORT" <<'EOF'
---
project: nexus
date: 2026-05-10
session-id: 4e8f1c2b-3a91-4d77-b9e0-5f2d0a1c7e8a
window: foo
trigger: #1
status: partial
---

# tiny

## Summary

a

## What Was Done

a

## Current State

a

## What Remains

a

## How to Resume

a
EOF
run_check out err rc "$SHORT"
assert_eq        "exit 1 on too-short body"           "$rc" "1"
assert_contains  "stderr names body chars + threshold" "$err" \
                 "body too short"

# ---- Test 9: --allow-todo skips placeholder check, not other checks ---

echo '=== TODO present + --allow-todo → exit 0 ==='
TODO="$WORK/todo.md"
write_complete_report "$TODO"
# Insert a TODO line in body.
sed -i 's/Shipped the report-check verb/TODO: write summary/' "$TODO"
run_check out err rc "$TODO"
assert_eq        "exit 1 on TODO without --allow-todo" "$rc" "1"
assert_contains  "stderr flags TODO/FIXME"             "$err" "TODO"
run_check out err rc "$TODO" --allow-todo
assert_eq        "exit 0 with --allow-todo"           "$rc" "0"

# ---- Test 10: `_(fill in)_` from skeleton flagged ---------------------

echo '=== skeleton `_(fill in)_` placeholder flagged ==='
SKEL="$WORK/skel.md"
write_complete_report "$SKEL"
sed -i 's/Shipped the report-check verb/_(fill in)_/' "$SKEL"
run_check out err rc "$SKEL"
assert_eq        "exit 1 on skeleton placeholder"     "$rc" "1"
assert_contains  "stderr names the skeleton marker"   "$err" "_(fill in)_"

# ---- Test 11: --allow-todo flag accepted as no-op when nothing to skip

echo '=== --allow-todo on a complete report → exit 0 ==='
run_check out err rc "$GOOD" --allow-todo
assert_eq        "exit 0 on complete + --allow-todo"  "$rc" "0"

# ---- Test 12: MONITOR_REPORT_MIN_CHARS overrides config knob ---------

echo '=== MONITOR_REPORT_MIN_CHARS=2000 makes the complete report too short ==='
out=""; err=""; rc=""
out_tmp=$(mktemp); err_tmp=$(mktemp)
MONITOR_REPORT_MIN_CHARS=2000 "$NG" report-check "$GOOD" >"$out_tmp" 2>"$err_tmp"
rc=$?
out=$(<"$out_tmp"); err=$(<"$err_tmp"); rm -f "$out_tmp" "$err_tmp"
assert_eq        "exit 1 when threshold raised"       "$rc" "1"
assert_contains  "stderr names the higher threshold"  "$err" "< 2000"


# ---- Test 13: `disposition:` validated at WRITE time (#836) -------------
#
# The read-time validator in `wrap-up --skeptic-role` is a REACHABILITY
# INVERSION: it sits behind a findings-count arm that short-circuits first, so
# it is unreachable for a skeptic that under-reports or omits
# `--skeptic-findings`, and reachable only for one that reports honestly. It
# checks the passes that need checking least.
#
# `report-check` sees the frontmatter unconditionally, so a check here cannot
# be routed around by which flags `wrap-up` is handed — and it fires while the
# author is present, rather than at hand-off where the failure is fail-OPEN
# into an auto-filed second-pass request.
#
# THE ENUMERATION IS NARROWER THAN PEOPLE BELIEVE, which is the point. Only
# `no-further-pass` and `second-pass` parse. `merge` does NOT — it returns
# `unreadable`, exactly like `credible` and `revise`. All three were believed
# legal by somebody on 2026-08-08, including in guidance issued to skeptics,
# and each cost a hand-off. Every one of them is asserted below, by name.

echo '=== report-check: legal dispositions pass ==='
for _d in no-further-pass second-pass; do
    DISPO="$WORK/dispo-$_d.md"
    write_complete_report "$DISPO"
    # Insert the field INTO the frontmatter (after line 1, which is `---`).
    awk -v d="$_d" 'NR==1{print; print "disposition: " d; next} {print}' \
        "$DISPO" > "$DISPO.tmp" && mv "$DISPO.tmp" "$DISPO"
    run_check out err rc "$DISPO"
    assert_eq "legal disposition '$_d' → exit 0" "$rc" "0"
done

echo '=== report-check: an UNREADABLE disposition is refused, and names the legal set ==='
for _d in merge credible revise "no-futher-pass"; do
    DISPO="$WORK/dispo-bad.md"
    write_complete_report "$DISPO"
    awk -v d="$_d" 'NR==1{print; print "disposition: " d; next} {print}' \
        "$DISPO" > "$DISPO.tmp" && mv "$DISPO.tmp" "$DISPO"
    run_check out err rc "$DISPO"
    assert_eq       "unreadable disposition '$_d' → exit 1"        "$rc" "1"
    assert_contains "…and the message names the field"            "$err" "disposition"
    assert_contains "…and names the legal values for '$_d'"       "$err" "no-further-pass|second-pass"
    assert_contains "…and quotes what the author actually wrote"  "$err" "$_d"
done

echo '=== report-check: --allow-todo does NOT bypass the disposition check ==='
# `wrap-up --allow-stub` forwards `--allow-todo`, and that is precisely the
# flag a pass cutting corners reaches for. If it relaxed this check the
# reachability inversion would reopen for exactly the population #836 is about,
# so the escape hatch is pinned rather than assumed: it relaxes the stub/TODO
# rule and nothing else.
DISPO="$WORK/dispo-stub.md"
write_complete_report "$DISPO"
awk 'NR==1{print; print "disposition: merge"; next} {print}' \
    "$DISPO" > "$DISPO.tmp" && mv "$DISPO.tmp" "$DISPO"
run_check out err rc "$DISPO" --allow-todo
assert_eq       "--allow-todo still refuses an unreadable disposition" "$rc" "1"
assert_contains "…naming the field"                                    "$err" "disposition"
# …and the control: --allow-todo on a LEGAL disposition still passes, so the
# assertion above is about the disposition and not about the flag failing.
DISPO2="$WORK/dispo-stub-ok.md"
write_complete_report "$DISPO2"
awk 'NR==1{print; print "disposition: second-pass"; next} {print}' \
    "$DISPO2" > "$DISPO2.tmp" && mv "$DISPO2.tmp" "$DISPO2"
run_check out err rc "$DISPO2" --allow-todo
assert_eq "--allow-todo + legal disposition → exit 0" "$rc" "0"

echo '=== report-check: a report with NO disposition is untouched ==='
# Most reports are not skeptic reports. An ABSENT field is a different state
# from an UNREADABLE one (#684) and only the latter is an authoring error;
# refusing both would make `report-check` unusable for every ordinary worker.
NODISPO="$WORK/dispo-none.md"
write_complete_report "$NODISPO"
run_check out err rc "$NODISPO"
assert_eq "no disposition field → exit 0" "$rc" "0"
assert_not_contains "…and says nothing about disposition" "$err" "disposition"

# ---- Test 13b: the check's REACHABLE SET is the parser's (#836 residual) ----
#
# Test 13 above pins the VALUE test. This pins the PRESENCE test, which was the
# residual half of the same defect: the check was gated on a hand-rolled
# `grep -qE '^disposition:[[:space:]]'` against the strict frontmatter string,
# in front of a parser that reads a far wider surface. Delegating the value
# question while hand-rolling the presence question leaves two validators
# disagreeing about one field — one level up from where #840 fixed it.
#
# Measured at a91f82b: of 14 spellings of an illegal value, the gate saw 3.
# The other 11 exited 0 at write time and then reproduced #836 verbatim at
# wrap-up (`--skeptic-findings 0` terminates without evaluating the field; an
# honest count escalates with "YOUR DISPOSITION WAS NOT READ").
#
# EVERY assertion below FAILS on pre-fix source, which is the property that
# makes them worth having: restore the frontmatter grep gate and the
# non-canonical and body rows all flip to exit 0.

echo '=== report-check: NON-CANONICAL frontmatter spellings are refused too ==='
# Each of these is read by `_skeptic_stated_disposition` and was invisible to
# the old gate.
#
# NO TAB ROW HERE, and the claim that there was one is retracted (skeptic
# Finding 1 on #855). This comment used to say a `\t` row was "deliberately
# included as the one non-canonical form the old gate DID catch … so the set is
# not all one way". There is no tab row in the heredoc below and this file
# contains zero literal tabs; the claim was also not implementable as written,
# since `<<'SPELLINGS'` is quoted and a typed `\t` would survive as two literal
# characters (it needs `printf` or `$'\t'`). The measurement was real — the tab
# row is in the PR body table — it simply never reached the shipped fixture.
#
# So every row in this block is a pre-fix gate MISS, and the control against a
# blanket-refusal rule lives elsewhere, not here. It is stronger than a single
# fixture set: the suite is unsatisfiable by "refuse everything" TWICE OVER, by
# two independent routes —
#
#   * `CORPUS_OK` is what the CARVE-OUT mutation reddens (make it always-refuse
#     and the legal heading-only report starts failing);
#   * `BODYOK` / `BOLDOK` redden under a DIFFERENT mutation, and the
#     quoted-mentions block guards a third thing again.
#
# Stated this way deliberately. My first version of this comment welded one
# mutation to all four fixture sets and quoted a single figure of 6 — which is a
# coincidence of two different sixes, not one measurement. Replacing a false
# claim about a control with a sloppy one about the same control would have been
# the same defect at lower amplitude: a comment asserting a control that is not
# there is the assertion-that-cannot-fail defect in prose form, and that is
# precisely what this suite exists to catch.
_i=0
while IFS='|' read -r _label _line; do
    [[ -n "$_label" ]] || continue
    _i=$(( _i + 1 ))
    DISPO="$WORK/dispo-spell-$_i.md"
    write_complete_report "$DISPO"
    awk -v l="$_line" 'NR==1{print; print l; next} {print}' \
        "$DISPO" > "$DISPO.tmp" && mv "$DISPO.tmp" "$DISPO"
    run_check out err rc "$DISPO"
    assert_eq       "non-canonical frontmatter '$_label' → exit 1" "$rc" "1"
    assert_contains "…and names the field for '$_label'"          "$err" "disposition"
done <<'SPELLINGS'
capital D|Disposition: merge
no space after colon|disposition:merge
bolded|**Disposition: merge**
indented two|  disposition: merge
italic label|*Disposition*: merge
ALLCAPS|DISPOSITION: merge
space before colon|disposition : merge
SPELLINGS

echo '=== report-check: a disposition stated in the BODY is refused ==='
# The old gate read only the frontmatter string. The parser scans frontmatter
# FIRST and falls back to the BODY, so the entire body surface was unvalidated
# at write time — and the body is not a marginal case: the parser's own source
# records that 6 of 6 real skeptic reports state the field in the same-line
# bolded `**Verdict: … Disposition: …**` shape asserted here.
BODYBAD="$WORK/dispo-body-bad.md"
write_complete_report "$BODYBAD"
printf '\n**Verdict: check. Disposition: merge.**\n' >> "$BODYBAD"
run_check out err rc "$BODYBAD"
assert_eq       "body-stated illegal disposition → exit 1" "$rc" "1"
assert_contains "…and the message says it was found in the body" "$err" "body"

# CONTROL: the same body shape with a LEGAL value still passes. Without this
# the assertion above could be satisfied by refusing every body mention.
BODYOK="$WORK/dispo-body-ok.md"
write_complete_report "$BODYOK"
printf '\n**Verdict: check. Disposition: no-further-pass.**\n' >> "$BODYOK"
run_check out err rc "$BODYOK"
assert_eq "body-stated LEGAL disposition → exit 0" "$rc" "0"

echo '=== report-check: the two REAL corpus shapes, taken verbatim ==='
# Both rows below are the literal lines from the only two files in a 2,614-report
# census that the widened check changes the verdict on. They are kept verbatim
# because the pair is the whole argument for where the boundary sits: one is the
# defect, the other is the false positive, and a rule that cannot tell them apart
# is not shippable in either direction.

# (a) A LEGAL token with same-line commentary. The parser bounds a value only at
#     a closing `**`, never at a period, so this reads as one non-token string
#     and fails OPEN at wrap-up — #836, in the corpus, in a report that shipped.
CORPUS_BAD="$WORK/dispo-corpus-bad.md"
write_complete_report "$CORPUS_BAD"
printf '\nDisposition: no-further-pass. Fixes landed in `ff678db`.\n' >> "$CORPUS_BAD"
run_check out err rc "$CORPUS_BAD"
assert_eq       "legal token + same-line commentary → exit 1" "$rc" "1"
assert_contains "…and quotes the offending line back"        "$err" "Fixes landed in"

# (b) A markdown HEADING using the word in its ordinary-English sense, in a
#     non-skeptic report. `structural_only` strips `#`, so the PARSER reads this
#     as a stated field — but refusing it would tell an ordinary worker to
#     rewrite a section title as `no-further-pass`. report-check must not.
CORPUS_OK="$WORK/dispo-corpus-ok.md"
write_complete_report "$CORPUS_OK"
printf '\n### Disposition: fix at source (one-line surgical change)\n' >> "$CORPUS_OK"
run_check out err rc "$CORPUS_OK"
assert_eq "heading-only disposition-shaped line → exit 0" "$rc" "0"
assert_not_contains "…and says nothing about disposition" "$err" "disposition"

# …and the discriminator is the HEADING, not the value: the same illegal value
# on a bare line in the same report IS refused. Without this control, (b) could
# be satisfied by a rule that had simply stopped reading the body at all.
CORPUS_BOTH="$WORK/dispo-corpus-both.md"
write_complete_report "$CORPUS_BOTH"
printf '\n### Disposition: fix at source (one-line surgical change)\n' >> "$CORPUS_BOTH"
printf '\nDisposition: merge\n' >> "$CORPUS_BOTH"
run_check out err rc "$CORPUS_BOTH"
assert_eq "heading PLUS a bare illegal field → exit 1" "$rc" "1"

echo '=== the heading carve-out is scoped to the BODY, never frontmatter ==='
# Skeptic Finding 2 on #855. The carve-out's justification is "an ordinary-
# English section title in a non-skeptic report". That argument exists only in
# the BODY. Frontmatter is YAML: `###` is not a heading there and the word
# cannot carry its ordinary sense in a key position, so the justification is
# void and the carve-out must not reach it.
#
# Unscoped, this was a live #836 inversion INSIDE the fix for #836 — the same
# line passing at write time and `unreadable` at read time, discriminating on
# one property the authority reports (heading-ness) while ignoring another it
# reports in the same output (the source).
HDFM="$WORK/dispo-heading-frontmatter.md"
write_complete_report "$HDFM"
awk 'NR==1{print; print "### Disposition: merge"; next} {print}' \
    "$HDFM" > "$HDFM.tmp" && mv "$HDFM.tmp" "$HDFM"
run_check out err rc "$HDFM"
assert_eq       "heading-shaped ILLEGAL value in FRONTMATTER → exit 1" "$rc" "1"
assert_contains "…and names the field"                                 "$err" "disposition"

# CONTROL 1 — the BODY half of the carve-out is deliberately UNCHANGED. Without
# this, the assertion above would also be satisfied by having simply deleted the
# carve-out, which is a different (and disclosed-as-unwanted) change.
HDBODY="$WORK/dispo-heading-body.md"
write_complete_report "$HDBODY"
printf '\n### Disposition: merge\n' >> "$HDBODY"
run_check out err rc "$HDBODY"
assert_eq "heading-shaped ILLEGAL value in BODY → exit 0 (carve-out intact)" "$rc" "0"

# CONTROL 2 — a LEGAL token in frontmatter is untouched by the scoping, because
# it never reaches this arm at all: the parser returns it `stated`, not
# `unreadable`. Pins that the fix discriminates on READABILITY, not on `###`.
HDFMOK="$WORK/dispo-heading-frontmatter-ok.md"
write_complete_report "$HDFMOK"
awk 'NR==1{print; print "### Disposition: no-further-pass"; next} {print}' \
    "$HDFMOK" > "$HDFMOK.tmp" && mv "$HDFMOK.tmp" "$HDFMOK"
run_check out err rc "$HDFMOK"
assert_eq "heading-shaped LEGAL value in FRONTMATTER → exit 0" "$rc" "0"

echo '=== the fail-CLOSED empty-locator arm is REACHABLE — and these kill it ==='
# Skeptic Finding 3 on #855, and a correction of my own reasoning rather than a
# concession to it. I argued the arm could not be given a killing assertion
# because it is unreachable. That conflated two different claims:
#
#   * unreachable by DOCUMENT      — true. Post-F1 `_lines` accumulates in the
#     same loop over `_fields` that computes the verdict, so no report can make
#     the real parser return `unreadable` with an empty locator.
#   * unreachable, FULL STOP       — false. The arm does not exist to guard
#     documents. It guards a PARSER REGRESSION, and a regression is simulable.
#
# Stubbing the authority is the seam, and it converts an unfalsifiable guard
# into a killable one — which is the whole point, since a guard no test can kill
# is indistinguishable from one that is wrong.
_stub_parser() {   # $1 = dest ng (must sit beside _bookkeeping.sh); $2 = payload
    awk -v payload="$2" '
        /^_skeptic_stated_disposition\(\) \{/ {
            print; printf "    printf %c%s%c; return 0\n", 39, payload, 39; skip=1; next }
        skip && /^\}/ { print; skip=0; next }
        skip          { next }
                      { print }
    ' "$NG" > "$1"
    chmod +x "$1"
}

ARMFIX="$WORK/dispo-arm-fixture.md"
write_complete_report "$ARMFIX"

# (a) the authority regresses to an unreadable verdict carrying NO locator.
#     Kills M5 (the `[[ -z "$_rc_shown" ]]` arm removed).
NG_NOLOC="$FAKE_NEXUS/monitor/ng-noloc"
_stub_parser "$NG_NOLOC" 'unreadable frontmatter stubbed-parser-regression'
_armout=$("$NG_NOLOC" report-check "$ARMFIX" 2>&1); _armrc=$?
assert_eq       "parser regression, NO locator → still refuses (fail CLOSED)" "$_armrc" "1"
assert_contains "…and says so in the message"  "$_armout" "parser reported no line"

# (b) the authority regresses to a NON-NUMERIC locator, which the `^[0-9]+h?$`
#     filter drops — leaving the same empty `$_rc_shown` by a different route.
#     Kills M7 (the token filter dropped).
NG_BADLOC="$FAKE_NEXUS/monitor/ng-badloc"
_stub_parser "$NG_BADLOC" 'unreadable body stubbed-parser-regression not-a-number'
_armout=$("$NG_BADLOC" report-check "$ARMFIX" 2>&1); _armrc=$?
assert_eq "parser regression, NON-NUMERIC locator → still refuses" "$_armrc" "1"
# …and the rc ALONE does not discriminate here, which is why this second
# assertion exists. Drop the `^[0-9]+h?$` filter and `not-a-number` survives
# into the loop, sets `_rc_nonhead=1`, and the report is refused ANYWAY — so
# `rc 1` holds with the filter present or absent. Measured: asserting only the
# rc left M7 reddening 0, i.e. an assertion that could not fail, planted in the
# test written to stop shipping assertions that cannot fail. The MESSAGE is what
# separates them: filtered → empty locator → "parser reported no line";
# unfiltered → the junk token is echoed back at the author as a line number.
assert_contains "…via the EMPTY-locator path, not by echoing junk back" \
                "$_armout" "parser reported no line"
assert_not_contains "…and the junk token never reaches the author" \
                "$_armout" "not-a-number"

# CONTROL — the stub harness is not simply refusing everything. The same
# stubbing mechanism with a READABLE verdict passes, so (a) and (b) are about
# the locator, not about having stubbed the parser at all.
NG_OKSTUB="$FAKE_NEXUS/monitor/ng-okstub"
_stub_parser "$NG_OKSTUB" 'no-further-pass frontmatter stubbed-legible 12'
_armout=$("$NG_OKSTUB" report-check "$ARMFIX" 2>&1); _armrc=$?
assert_eq "CONTROL: stubbed parser with a legible verdict → exit 0" "$_armrc" "0"

echo '=== report-check: PROSE inference is not second-guessed at write time ==='
# `unreadable` from the `prose` source is the inference fallback, not a field
# the author wrote. Judging it here would refuse reports that merely DISCUSS
# the protocol, and #840's contract is explicit that only a value the author
# actually WROTE is judged. Source-scoping the refusal to the two FIELD scans
# is what keeps this verb usable for ordinary workers.
PROSE="$WORK/dispo-prose.md"
write_complete_report "$PROSE"
printf '\nNo further pass is warranted.\nA second pass is warranted.\n' >> "$PROSE"
run_check out err rc "$PROSE"
assert_eq "contradictory PROSE conclusions → exit 0 (not a write-time error)" "$rc" "0"
assert_not_contains "…and says nothing about disposition" "$err" "disposition"

echo '=== report-check: QUOTED mentions of the idiom are not false positives ==='
# The regression that would make this verb intolerable: reports ABOUT the
# skeptic protocol (this repo writes many) quote illegal values as examples.
# The parser already refuses to read a quotation as a statement — fenced
# blocks, code spans, blockquotes, table cells. Widening report-check's
# reachable set to the parser's must inherit that, not just its permissiveness.
QUOTED="$WORK/dispo-quoted.md"
write_complete_report "$QUOTED"
{
    printf '\nA report discussing the protocol, quoting illegal values:\n\n'
    printf '```\n**Disposition: merge**\n```\n\n'
    printf 'Inline: `Disposition: credible` is not legal.\n\n'
    printf '> Disposition: revise\n\n'
    printf '| field | value |\n|---|---|\n| Disposition | merge |\n'
} >> "$QUOTED"
run_check out err rc "$QUOTED"
assert_eq "fenced/inline/blockquoted/tabled mentions → exit 0" "$rc" "0"
assert_not_contains "…and says nothing about disposition" "$err" "disposition"

echo '=== report-check: the line LOCATOR reports, it does not DECIDE ==='
# Skeptic finding 1 on PR #855. The locator grep scans the RAW file; the parser
# scans a TRANSFORMED one (HTML comments stripped, fences skipped, code spans /
# blockquotes / table cells rejected). Letting the locator gate the refusal
# re-instantiated the very class this change closes — a hand-rolled scanner
# overruling the authority — in the FAIL-OPEN direction.

# (a) The parser reads a field the raw grep cannot see. Refusal must survive
#     the locator finding nothing: fail CLOSED, and say the line was not found.
LOC1="$WORK/dispo-loc-comment.md"
write_complete_report "$LOC1"
printf '\ndisposition<!-- n -->: merge\n' >> "$LOC1"
run_check out err rc "$LOC1"
assert_eq       "mid-line HTML comment → still exit 1 (fail CLOSED)" "$rc" "1"
# STRONGER than "admits it could not find the line", which is what a caller
# running its own raw grep could manage at best. The parser reports the line it
# consumed, so the line is NAMED even though no raw-text search could match it.
assert_contains "…and NAMES the line a raw grep cannot match"        "$err" "disposition<!-- n -->: merge"

LOC2="$WORK/dispo-loc-split.md"
write_complete_report "$LOC2"
printf '\ndispo<!--x-->sition: merge\n' >> "$LOC2"
run_check out err rc "$LOC2"
assert_eq "comment splitting the label → still exit 1 (fail CLOSED)" "$rc" "1"

# (b) A fenced quotation plus a real defective field. The locator cannot tell
#     them apart, so it must list BOTH rather than confidently name the
#     quotation — pointing the author at a line they must not edit while the
#     real field goes unnamed is the failure the write-time check exists to avoid.
LOC3="$WORK/dispo-loc-fenced.md"
write_complete_report "$LOC3"
printf '\n```\n**Disposition: merge**\n```\n\nDisposition: credible\n' >> "$LOC3"
run_check out err rc "$LOC3"
assert_eq       "fenced quote + real bad field → exit 1"    "$rc" "1"
assert_contains "…names the REAL field"                     "$err" "Disposition: credible"
# THE POINT OF THE UNIFICATION, and stronger than listing both as candidates:
# the parser never CONSUMED the fenced line, so it cannot be named at all. A
# caller scanning raw text cannot reach this — it has no way to know the fence
# made that line a quotation. Naming it is what pointed authors at a line they
# must not edit.
assert_not_contains "…and does NOT name the fenced quotation" "$err" "**Disposition: merge**"

# (c) A heading poisons the parser's verdict while being filtered out of the
#     message — so the author was told an ALREADY-CORRECT line was unreadable,
#     with no way to reach a passing state. The heading must be NAMED.
LOC4="$WORK/dispo-loc-heading-named.md"
write_complete_report "$LOC4"
printf '\n### Disposition: fix at source (one-liner)\n\nDisposition: no-further-pass\n' >> "$LOC4"
run_check out err rc "$LOC4"
assert_eq       "heading + canonical LEGAL field → exit 1"        "$rc" "1"
assert_contains "…and the poisoning HEADING is named in the message" "$err" "fix at source"

# …and the carve-out still holds: a heading with no other candidate is allowed.
LOC5="$WORK/dispo-loc-heading-only.md"
write_complete_report "$LOC5"
printf '\n### Disposition: fix at source (one-line surgical change)\n' >> "$LOC5"
run_check out err rc "$LOC5"
assert_eq "heading ONLY → exit 0 (carve-out intact)" "$rc" "0"

echo '=== heading-ness is EXPOSED by the parser, not re-derived from raw bytes ==='
# The predicate must consume the same representation as the verdict. `pre` is a
# slice of the TRANSFORMED line, so the parser emits `<n>h`; `report-check` reads
# the flag. Re-deriving it by re-reading the RAW line — which an earlier revision
# did — puts the predicate back on bytes the parser never classified, and this is
# the fixture where the two disagree: the comment strip leaves `### ` as the
# prefix, so the authority calls it a HEADING, while a raw-byte regex sees
# `<!--c-->###` and does not. Re-derived, the carve-out is lost and an ordinary
# section title is refused.
HDG="$WORK/dispo-heading-exposed.md"
write_complete_report "$HDG"
printf '\n<!--c-->### Disposition: fix at source (one-liner)\n' >> "$HDG"
run_check out err rc "$HDG"
assert_eq "comment-before-heading → exit 0 (authority says heading)" "$rc" "0"
assert_not_contains "…and says nothing about disposition" "$err" "disposition"

# Control: the same comment prefix on a NON-heading line is still refused, so the
# assertion above is about heading-ness and not about comments being ignored.
HDG2="$WORK/dispo-heading-exposed-ctl.md"
write_complete_report "$HDG2"
printf '\n<!--c-->Disposition: merge\n' >> "$HDG2"
run_check out err rc "$HDG2"
assert_eq "comment-before-NON-heading → exit 1" "$rc" "1"

echo '=== monitor/ng parses: no apostrophe inside the single-quoted awk ==='
# The awk program is a single-quoted shell string, so ONE apostrophe anywhere in
# it — a comment included — closes the quote and the file stops parsing, with the
# error reported thousands of lines away inside an unrelated command. That is
# exactly what happened while writing the emit above. `bash -n` is cheap and it
# is the only thing that localises it.
# Uses assert_eq, NOT a bare ok/bad pair: this suite defines only assert_eq,
# assert_contains, assert_not_contains, run_check and write_complete_report.
# The first draft of this guard called `ok`/`bad`, which do not exist here — so
# it exited 127 inside an already-taken `if` branch, counted no assertion, and
# the suite still reported ALL TESTS PASSED. A guard that cannot fail is worse
# than no guard, and it is the same silent-127 shape the guard itself is about.
# Caught by the assertion count rising by 3 where 4 were added.
bash -n "$NG" 2>/dev/null
assert_eq "monitor/ng passes bash -n (no apostrophe in the single-quoted awk)" "$?" "0"

echo '=== a BOLDED PARAGRAPH LABEL is unreadable — CLAIMED, not incidental ==='
# skeptic D1 on #855. `**Disposition:** <prose>` bounds to an EMPTY value at
# rule (5) (the closing `**` immediately follows the colon). Before the field
# scan emitted line numbers an empty value printed a BLANK line, `$(...)`
# stripped it, and the scan fell through to prose -> `absent`. Emitting
# `<lineno>\t<rest>` makes the record non-blank, so it now resolves `unreadable`.
#
# That change is DECLARED here rather than avoided. The author wrote a label, a
# colon and a sentence: they believe they stated a verdict. `absent` ("nobody
# stated one") is false about such a document; `unreadable` ("you stated one and
# we could not read it") is #684 exactly, and is the case that must be loud.
# Both effects are conservative — write-time refuses, retire-preflight reads
# NO-GO. Measured incidence across the corpus: exactly ONE real file changes.
BOLDLBL="$WORK/dispo-bold-label.md"
write_complete_report "$BOLDLBL"
printf '\n**Disposition:** the work is sound but two things must change first.\n' >> "$BOLDLBL"
run_check out err rc "$BOLDLBL"
assert_eq       "bolded paragraph label → exit 1 (unreadable, claimed)" "$rc" "1"
assert_contains "…and the message names the field"                      "$err" "disposition"

# CONTROL 1 — the colon INSIDE the bold with a real value is still legal, so the
# assertion above is about the empty-bounded value and not about bold markup.
BOLDOK="$WORK/dispo-bold-ok.md"
write_complete_report "$BOLDOK"
printf '\n**Disposition: no-further-pass**\n' >> "$BOLDOK"
run_check out err rc "$BOLDOK"
assert_eq "bolded field WITH a legal value → exit 0" "$rc" "0"

# CONTROL 2 — the boundary against the heading carve-out, asserted as a PAIR
# because the pair is the principle: a `###` heading NAMES a section (not a
# statement, carved out); a `**Label:**` ASSERTS a value in prose form (a
# statement we cannot read, refused). Same word, opposite answers, one rule.
HDGCTL="$WORK/dispo-heading-vs-label.md"
write_complete_report "$HDGCTL"
printf '\n### Disposition: fix at source (one-liner)\n' >> "$HDGCTL"
run_check out err rc "$HDGCTL"
assert_eq "…while a HEADING with the same word → exit 0" "$rc" "0"

echo '=== the parser`s 3-field contract is UNCHANGED without the flag ==='
# `--with-lines` is opt-in for one reason: four call sites do `read -r st src
# det`, so an unconditional 4th field would land silently inside `det` and every
# one of them would keep working while reporting a corrupted detail string. That
# is the failure mode this repo keeps paying for, so it is asserted rather than
# reasoned about. Driven through the `ng skeptic-disposition` verb — a real
# 3-field consumer — not through the function in isolation.
CONTRACT_DIR="$WORK/contract"
mkdir -p "$CONTRACT_DIR"
CONTRACT="$CONTRACT_DIR/nexus_2026-01-01_000000_c.md"
write_complete_report "$CONTRACT"
awk 'NR==1{print; print "disposition: merge"; next} {print}' \
    "$CONTRACT" > "$CONTRACT.tmp" && mv "$CONTRACT.tmp" "$CONTRACT"
sed -i 's/^window:.*/window: contract-probe/' "$CONTRACT"
contract_out=$("$NG" skeptic-disposition contract-probe --reports-dir "$CONTRACT_DIR" 2>&1)
assert_contains     "3-field consumer still reads a clean detail" \
    "$contract_out" "detail=value-not-a-token"
# The load-bearing half: no line numbers leaked into the 3-field output.
assert_not_contains "…with NO line numbers appended to detail" \
    "$contract_out" "value-not-a-token "

echo '=== report-check no longer hand-rolls a PRESENCE gate ==='
# Structural, and it is the assertion that actually pins the fix: the
# behavioural rows above would all pass again if somebody reintroduced a
# frontmatter-only grep with a slightly wider regex. The contract is that the
# parser decides BOTH questions, so there is no second copy to drift.
# NEEDLE IS SINGLE-QUOTED ON PURPOSE. Written as "…\[\[:space:\]\]" the
# backslashes survive into the needle (they are not escapes bash recognises in
# a double-quoted string), and `assert_not_contains` greps with -F, so the
# literal is never found and the assertion passes on EVERY input — including
# the pre-fix source it exists to reject. Caught by mutant-testing this suite
# against a91f82b: 16 assertions reddened and this one did not.
assert_not_contains "no frontmatter-only presence gate in front of the parser" \
    "$(sed -n '/^cmd_report_check()/,/^}/p' "$NG")" '^disposition:[[:space:]]'

echo '=== report-check agrees with the READ-time parser, by construction ==='
# The check calls `_skeptic_stated_disposition` — the same function
# `wrap-up --skeptic-role` consults — rather than re-listing the enumeration.
# A hand-rolled copy would drift and then accept a value wrap-up rejects, which
# is two validators disagreeing about one field: the defect class this repo
# keeps paying for. Asserted structurally, since a behavioural assertion here
# would just be the tests above again.
assert_contains "report-check delegates to the shared parser" \
    "$(sed -n '/^cmd_report_check()/,/^}/p' "$NG")" "_skeptic_stated_disposition"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
