#!/usr/bin/env bash
# Executes every ignore-file-blind search form CLAUDE.md recommends for
# issue #618, against a planted fixture corpus, in a shell that carries
# the operator's ignore-file-aware `grep` wrapper.
#
# Run: bash monitor/watcher/test-claude-md-618-remedies.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS (your-org/nexus-code#707). #618 is the workspace's
# dominant defect class — silence used as a proxy for absence — living in
# the search primitive. CLAUDE.md documents remedies for it. Two of those
# remedies, COMPOSED, reproduce the defect:
#
#     find reports -name '*.md' -print0 | xargs -0 command grep -aIn X
#     → rc 127, zero output, and completely silent under `2>/dev/null`
#
# because `xargs` execs a PROGRAM and `command` is a shell BUILTIN. Both
# halves are correct in isolation; an agent that has internalised each
# will compose them and publish a confident "0 of 2,483".
#
# The durable fix is not a better sentence — it is making the sentence
# EXECUTABLE. CLAUDE.md now carries the remedies in a delimited fenced
# block; this suite extracts that block verbatim and RUNS each line. A
# documented form that does not execute turns the suite red.
#
# NON-VACUITY. Five forms passing proves nothing unless the harness is
# known to reproduce the bug in the first place, so the suite anchors on
# three controls:
#   Control A — plain `grep -r` through the same harness must return a
#               SILENT ZERO. If it does not, the wrapper stand-in is not
#               suppressing and every green below is meaningless.
#   Control B — the #707 composed form must FAIL (rc 127, no hits). This
#               is the defect the suite was written to catch; if the
#               harness cannot catch it, it cannot vouch for the rest.
#   Control C — the extracted form count is PINNED. A botched extraction
#               that yields zero lines would otherwise pass every
#               assertion by having none to run (#618's own shape).
#
# COVERAGE BOUNDARY — name the axes this varies on:
#   (1) WHICH SHELL. The operator's wrapper is a shell FUNCTION, and
#       which forms route around a function is exactly what is under
#       test, so each form is run under bash AND (when present) zsh —
#       zsh being the operator's real interactive shell and the one
#       CLAUDE.md's fence is tagged for. A bash-only green would not
#       cover the shell the trap is actually sprung in.
#   (2) WHICH EXTERNAL TOOLS EXIST. `rg` is not guaranteed on every
#       runner. An absent tool is reported as an explicit SKIP with the
#       reason, never silently counted as a pass, and the executed-form
#       floor (Control C) is asserted against the forms that need no
#       external tool.
# NOT covered: the real ugrep binary's full option surface (the stand-in
# emulates the one behaviour #618 turns on — honouring a bare-`*`
# .gitignore) and the real reports corpus (a fixture is used so the suite
# is hermetic and the expected hit set is known exactly).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
NG_REAL="$_test_dir/../ng"

# The real grep binary, resolved WITHOUT any wrapper.
REAL_GREP=$(command -v grep 2>/dev/null || true)
[[ -x "$REAL_GREP" ]] || REAL_GREP=/bin/grep

PASS=0
FAIL=0
SKIP=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_gt() {
    local label="$1" got="$2" floor="$3"
    if (( got > floor )); then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %q not > %q\n' "$label" "$got" "$floor" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if "$REAL_GREP" -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s\n           expected substring: %s\n           in: %s\n' "$label" "$needle" "$hay" >&2; FAIL=$(( FAIL + 1 )); fi
}
note_skip() { printf '  SKIP: %s\n' "$1"; SKIP=$(( SKIP + 1 )); }

# ---- fixture ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A fixture nexus. NEXUS_ROOT is pinned to it for every form: `ng
# report-grep` needs it, and pinning also scrubs an inherited NEXUS_ROOT
# that would otherwise make this fixture read the PRIMARY's reports dir
# (the #655 leak that hit three suites).
FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config" "$FAKE_NEXUS/reports"
cp "$NG_REAL" "$FAKE_NEXUS/monitor/ng"
# `ng` refuses to start unless _bookkeeping.sh is readable beside it
# (#601 #605 #629 #631).
cp "$_test_dir/../_bookkeeping.sh" "$FAKE_NEXUS/monitor/_bookkeeping.sh"
cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf 'default-org/default-repo' ;;
    github.user_login)  printf 'test-user' ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"
cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
printf 'fake-token'
STUB
chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

# The corpus: report-shaped files carrying the mandatory `## How to
# Resume` heading (report-grep's visibility sentinel), the planted token
# in exactly TWO of them, and the real bare-`*` .gitignore.
REPORTS="$FAKE_NEXUS/reports"
TOKEN='REMEDY_TOKEN_H4Q'
printf '%s\n' '*' > "$REPORTS/.gitignore"
make_report() { printf '# Report\n\n## Summary\ns\n\n## How to Resume\nresume steps\n\n%s\n' "$2" > "$REPORTS/$1"; }
make_report "nexus_2026-01-01_000000_a.md" "nothing special here"
make_report "nexus_2026-01-02_000000_b.md" "this one mentions $TOKEN"
make_report "nexus_2026-01-03_000000_c.md" "also mentions $TOKEN again"

# Fixture sanity: the token IS present and IS findable by the raw binary.
# Without this, a fixture that never got written would make every
# "returns 2 files" assertion below fail for the wrong reason, and every
# "returns 0" control pass for the wrong reason.
raw_hits=$("$REAL_GREP" -raIl -e "$TOKEN" "$REPORTS" | "$REAL_GREP" -c . || true)
assert_eq "fixture: raw grep binary finds the token in exactly 2 files" "$raw_hits" "2"

# ---- the wrapper stand-in ----------------------------------------------
# The operator's interactive `grep` is a shell FUNCTION wrapping
# `ugrep --ignore-files`. That it is a FUNCTION (not an executable) is
# load-bearing: it is why `command grep` and `xargs -0 grep` both escape
# it, and why the composed #707 form does not. The stand-in emulates the
# single behaviour #618 turns on — a directory argument holding a bare-`*`
# .gitignore is fully suppressed — and honours `--no-ignore-files` by
# turning that off, matching the real wrapper's documented escape hatch.
#
# Deliberately written in the POSIX subset common to bash and zsh, since
# it is sourced into both.
read -r -d '' WRAPPER_PREAMBLE <<'PREAMBLE' || true
grep() {
    _ignore=1
    _n=$#
    _i=0
    # Rebuild "$@" without --no-ignore-files, noting whether it was there.
    while [ "$_i" -lt "$_n" ]; do
        _a="$1"; shift; _i=$(( _i + 1 ))
        if [ "$_a" = "--no-ignore-files" ]; then _ignore=0; else set -- "$@" "$_a"; fi
    done
    if [ "$_ignore" -eq 1 ]; then
        # ugrep --ignore-files: a directory holding a bare-`*` .gitignore
        # is suppressed entirely. Silent zero, rc 1 — issue #618.
        for _a in "$@"; do
            if [ -d "$_a" ] && [ -f "$_a/.gitignore" ] && [ "$(cat "$_a/.gitignore")" = '*' ]; then
                return 1
            fi
        done
    fi
    command grep "$@"
}
PREAMBLE

# run_form SHELL FORM  → prints hit-count on line 1, rc on line 2
run_form() {
    local _sh="$1" _form="$2"
    local _o _rc
    _o=$(NEXUS_ROOT="$FAKE_NEXUS" NEXUS_WORKER_WINDOW="" "$_sh" -c "$WRAPPER_PREAMBLE
$_form" 2>/dev/null)
    _rc=$?
    local _n
    if [[ -z "$_o" ]]; then _n=0; else _n=$(printf '%s\n' "$_o" | "$REAL_GREP" -c . || true); fi
    printf '%s\n%s\n' "$_n" "$_rc"
}

# ---- extract the documented forms from CLAUDE.md ------------------------
echo '=== Extraction: pull the delimited remedy block out of CLAUDE.md ==='
BEGIN_MARK='<!-- BEGIN 618-REMEDIES -->'
END_MARK='<!-- END 618-REMEDIES -->'

if [[ -r "$CLAUDE_MD" ]]; then
    printf '  PASS: %s\n' "CLAUDE.md is readable at $CLAUDE_MD"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "CLAUDE.md not readable at $CLAUDE_MD" >&2; FAIL=$(( FAIL + 1 ))
fi

# Lines between the markers, minus fences, blanks and trailing comments.
FORMS_RAW=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  index($0, b) { inblk=1; next }
  index($0, e) { inblk=0; next }
  inblk { print }
' "$CLAUDE_MD" \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | "$REAL_GREP" -v '^```' \
  | "$REAL_GREP" -v '^$' \
  | sed -e 's/[[:space:]]*#[^#]*$//')

FORM_COUNT=$(printf '%s\n' "$FORMS_RAW" | "$REAL_GREP" -c . || true)

# Control C: pin the count. A botched extraction yielding zero lines
# would run zero assertions and pass — #618's own shape inside the test.
assert_eq "exactly 5 remedy forms extracted (pinned; a dropped form goes red)" "$FORM_COUNT" "5"
assert_contains "the ng verb is among them"        "$FORMS_RAW" "ng report-grep"
assert_contains "the command-grep form is present" "$FORMS_RAW" "command grep"
assert_contains "the xargs form is present"        "$FORMS_RAW" "xargs -0 grep"

# ---- shells under test ---------------------------------------------------
SHELLS=("bash")
if command -v zsh >/dev/null 2>&1; then
    SHELLS+=("zsh")
else
    note_skip "zsh not installed — the operator's real shell is UNTESTED on this runner"
fi

# ---- Control A: the harness reproduces #618 -----------------------------
# If a plain `grep -r` does NOT return a silent zero here, the stand-in is
# not suppressing and every green below is worthless.
echo '=== Control A: plain grep -r through the wrapper → SILENT ZERO (#618) ==='
for sh in "${SHELLS[@]}"; do
    res=$(run_form "$sh" "grep -raIl $TOKEN $REPORTS")
    a_n=$(printf '%s\n' "$res" | sed -n 1p)
    a_rc=$(printf '%s\n' "$res" | sed -n 2p)
    assert_eq "[$sh] plain grep -r finds 0 files (bug reproduced)" "$a_n" "0"
    assert_eq "[$sh] plain grep -r exits 1, no error text"         "$a_rc" "1"
done

# ---- Control B: the #707 composed form FAILS ----------------------------
echo '=== Control B: the #707 composed form → rc 127, zero hits ==='
for sh in "${SHELLS[@]}"; do
    res=$(run_form "$sh" "find $REPORTS -name '*.md' -print0 | xargs -0 command grep -aIl $TOKEN")
    b_n=$(printf '%s\n' "$res" | sed -n 1p)
    assert_eq "[$sh] xargs -0 command grep finds 0 files (#707)" "$b_n" "0"
done
# rc is asserted on the xargs stage directly: in a pipeline the shell
# reports the LAST command's status, and `xargs` IS last here, so 127
# propagates — but assert it where it is generated, not inferred.
xrc=$(printf '' | xargs -0 command grep -aIl "$TOKEN" >/dev/null 2>&1; echo $?)
assert_eq "xargs cannot exec the shell builtin \`command\` → rc 127" "$xrc" "127"

# ---- The main event: every documented form must find the token ----------
echo '=== Every documented remedy form executes and finds the planted token ==='
EXECUTED=0
while IFS= read -r form; do
    [[ -n "$form" ]] || continue
    # Substitute the placeholders. `monitor/ng` is written repo-relative in
    # the doc; point it at the fixture install.
    runnable=${form//PATTERN/$TOKEN}
    runnable=${runnable//ROOT/$REPORTS}
    runnable=${runnable//monitor\/ng/$FAKE_NEXUS\/monitor\/ng}

    # An external tool the runner lacks is an explicit SKIP, never a pass.
    tool=${runnable%% *}
    tool=${tool##*/}
    if [[ "$tool" != "find" && "$tool" != "grep" && "$tool" != "command" ]] \
       && ! command -v "$tool" >/dev/null 2>&1 && [[ ! -x "${runnable%% *}" ]]; then
        note_skip "$tool not installed — form NOT executed: $form"
        continue
    fi

    for sh in "${SHELLS[@]}"; do
        res=$(run_form "$sh" "$runnable")
        n=$(printf '%s\n' "$res" | sed -n 1p)
        assert_eq "[$sh] finds both planted files: $form" "$n" "2"
    done
    EXECUTED=$(( EXECUTED + 1 ))
done <<< "$FORMS_RAW"

# The forms needing no external tool: ng, command grep, grep
# --no-ignore-files, find|xargs. `rg` may legitimately be absent.
assert_gt "at least 4 forms actually executed (tool-absence cannot hollow this out)" "$EXECUTED" "3"

# ---- assertion-count guard ----------------------------------------------
# A missing assert_* helper (typo → rc 127) is counted by nothing. The
# count is shell-dependent by construction (zsh doubles the per-form and
# per-control assertions) and tool-dependent (`rg`), so pin it against the
# configuration actually detected rather than a single magic number — an
# unconditional pin would go red on any runner lacking zsh or rg, which is
# a false red, and loosening it to a floor would forfeit the guard.
NSHELL=${#SHELLS[@]}
#   fixture sanity 1 + CLAUDE.md readable 1 + extraction 4  = 6
#   Control A: 2 per shell | Control B: 1 per shell + 1 rc  = 3*NSHELL + 1
#   forms: EXECUTED per shell                               = EXECUTED*NSHELL
#   executed floor                                          = 1
EXPECTED_ASSERTIONS=$(( 6 + 3 * NSHELL + 1 + EXECUTED * NSHELL + 1 ))
TOTAL=$(( PASS + FAIL ))
if (( TOTAL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d (shells=%d executed=%d) — an assertion was silently dropped or added\n' \
        "$TOTAL" "$EXPECTED_ASSERTIONS" "$NSHELL" "$EXECUTED" >&2
    FAIL=$(( FAIL + 1 ))
fi

printf '\n=== summary: %d passed, %d failed, %d skipped (%d assertions; expected %d) ===\n' \
    "$PASS" "$FAIL" "$SKIP" "$TOTAL" "$EXPECTED_ASSERTIONS"
if (( FAIL == 0 )); then echo 'ALL TESTS PASSED'; exit 0; fi
echo 'TESTS FAILED' >&2
exit 1
