#!/usr/bin/env bash
# Unit tests for the `ng` verb-dispatch usage tap (_usage_tap in monitor/ng)
# and the `ng usage` analyzer facade (monitor/usage-report.py).
#
# Run: bash monitor/watcher/test-ng-usage-tap.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: build a minimal fake nexus tree (real ng + usage-report.py +
# stubbed config/load.sh), point NEXUS_STATE_DIR at a scratch dir, drive a
# handful of verbs, and assert the tap's invariants: it logs one line per
# dispatch, is fail-open (never masks the verb's exit code), is PII-safe
# (never logs arbitrary args), honours the sub-verb allowlist, and respects
# the NG_USAGE_LOG=0 opt-out.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"
USAGE_REAL="$_test_dir/../usage-report.py"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
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
# your-org/nexus-code#1077: `ng` also refuses without the primary-root resolver.
cp "$(dirname "$NG_REAL")/_nexus-root.sh" "$FAKE_NEXUS/monitor/_nexus-root.sh"
cp "$USAGE_REAL" "$FAKE_NEXUS/monitor/usage-report.py"
chmod +x "$FAKE_NEXUS/monitor/usage-report.py"
NG="$FAKE_NEXUS/monitor/ng"
cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf 'default-org/default-repo' ;;
    github.user_login)  printf 'test-user' ;;
    nexus.root)         printf '%s' "${FAKE_NEXUS_ROOT:-}" ;;
    *) [[ $# -ge 2 ]] && { printf '%s' "$2"; exit 0; } ; exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"

STATE="$WORK/state"
mkdir -p "$STATE"
LOG="$STATE/ng-usage.jsonl"
export NEXUS_STATE_DIR="$STATE" NEXUS_ROOT="$FAKE_NEXUS"
# Ensure a clean origin classification: no worker/orch/watcher window vars.
unset NEXUS_WORKER_WINDOW NEXUS_ORCHESTRATOR_WINDOW WATCHER_WINDOW 2>/dev/null || true

# ---- tests --------------------------------------------------------------

echo "test-ng-usage-tap:"

# 1. An arg-less verb that dies still records exactly one invocation, and the
#    tap does NOT mask the verb's non-zero exit code.
: > "$LOG"
"$NG" show >/dev/null 2>&1; rc=$?
assert_eq "arg-less 'show' keeps its own nonzero exit (fail-open, no masking)" "$rc" "1"
assert_eq "one line logged for one dispatch" "$(wc -l < "$LOG")" "1"
assert_contains "logged verb is 'show'" "$(cat "$LOG")" '"verb":"show"'

# 2. PII-safety: 'show' is not an allowlisted sub-dispatch parent, so an
#    arbitrary argument (here a path) must NEVER appear in the log.
: > "$LOG"
"$NG" show /etc/passwd >/dev/null 2>&1 || true
assert_contains "still records the verb" "$(cat "$LOG")" '"verb":"show"'
assert_eq "sub is empty for non-allowlisted parent" \
    "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())["sub"])' < "$LOG")" ""
assert_not_contains "arbitrary path arg is NOT logged (PII-safe)" "$(cat "$LOG")" "/etc/passwd"

# 3. Sub-verb allowlist: an allowlisted parent records a clean sub-verb token.
: > "$LOG"
"$NG" issue view 999999 >/dev/null 2>&1 || true
assert_contains "allowlisted parent 'issue' records sub 'view'" "$(cat "$LOG")" '"verb":"issue","sub":"view"'
assert_not_contains "the numeric arg after the sub-verb is NOT logged" "$(cat "$LOG")" "999999"

# 4. An allowlisted parent with a NON-token sub (a bare number) drops the sub.
: > "$LOG"
"$NG" issue 42 >/dev/null 2>&1 || true
assert_eq "numeric sub is rejected (sub stays empty)" \
    "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())["sub"])' < "$LOG")" ""

# 5. Unknown verbs are still tapped (usage = an ATTEMPT to use a verb).
: > "$LOG"
"$NG" definitely-not-a-verb >/dev/null 2>&1 || true
assert_contains "unknown verb is recorded" "$(cat "$LOG")" '"verb":"definitely-not-a-verb"'

# 6. Opt-out: NG_USAGE_LOG=0 writes nothing.
: > "$LOG"
NG_USAGE_LOG=0 "$NG" show >/dev/null 2>&1 || true
assert_eq "NG_USAGE_LOG=0 logs nothing" "$(wc -c < "$LOG")" "0"

# 7. Fail-open under an unwritable state dir: the verb must still run/exit
#    normally and nothing may crash. (Directory made read-only.)
RO="$WORK/ro-state"; mkdir -p "$RO"; : > "$RO/ng-usage.jsonl"; chmod 000 "$RO/ng-usage.jsonl"
NEXUS_STATE_DIR="$RO" "$NG" show >/dev/null 2>&1; rc=$?
chmod 644 "$RO/ng-usage.jsonl" 2>/dev/null || true
assert_eq "unwritable log does not change the verb's exit code (fail-open)" "$rc" "1"

# 8. Every logged line is valid JSON with the expected key set.
: > "$LOG"
"$NG" verbs >/dev/null 2>&1 || true
"$NG" show  >/dev/null 2>&1 || true
bad=$(python3 - "$LOG" <<'PY'
import json,sys
need={"ts","verb","sub","origin","win","src","pid"}
bad=0
for ln in open(sys.argv[1]):
    ln=ln.strip()
    if not ln: continue
    try: d=json.loads(ln)
    except Exception: bad+=1; continue
    if set(d)!=need: bad+=1
print(bad)
PY
)
assert_eq "all logged lines are valid JSON with the exact key set" "$bad" "0"

# 8b. THE `src` FIELD — a leaked row names its own producing suite (#720).
#
#     WHY IT IS HERE. `win` is EMPTY on every row written on a CI runner (no
#     tmux), and `ts` has one-second resolution while the band runs at
#     `--jobs 4`. So the CI occurrence at `d1cc62b` — 23 rows leaked into the
#     inherited root — could be narrowed to four concurrent `ng`-verb suites
#     and no further, and #720 stayed open on precisely that gap: "ambiguous by
#     concurrency", not "unattributable by population". `src` removes the
#     ambiguity at the source. watcher/run-tests.sh sets NEXUS_TEST_SUITE per
#     child; this asserts the tap carries it, and carries nothing when it is
#     absent.
: > "$LOG"
NEXUS_TEST_SUITE="watcher/test-ng-usage-tap.sh" "$NG" show >/dev/null 2>&1 || true
assert_contains "a row written under a test run NAMES the suite" \
    "$(cat "$LOG")" '"src":"watcher/test-ng-usage-tap.sh"'

: > "$LOG"
# `env -u`, not a bare call: this suite itself runs UNDER watcher/run-tests.sh,
# which now sets NEXUS_TEST_SUITE for every child — so a bare invocation
# inherits it and the "outside a test run" case is unreachable from inside one.
# Asserting the ambient value would make this pass standalone and fail in the
# band, which is a test measuring its own harness rather than the tap.
env -u NEXUS_TEST_SUITE "$NG" show >/dev/null 2>&1 || true
assert_contains "with NEXUS_TEST_SUITE unset, src is EMPTY — the honest value, not a guess" \
    "$(cat "$LOG")" '"src":""'

# Sanitised on the same rule as `win`: the value reaches a printf'd JSON string
# with no escaping, so a quote or a backslash in it would produce a row the
# analyzer cannot parse — and an unparseable row is a lost attribution, which
# is the whole point of the field.
: > "$LOG"
NEXUS_TEST_SUITE='a"b\c$(x) d/e.sh' "$NG" show >/dev/null 2>&1 || true
assert_eq "a hostile NEXUS_TEST_SUITE still yields parseable JSON" \
    "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())["src"])' < "$LOG")" \
    "abcxd/e.sh"

# 9. The `ng usage` analyzer runs and reads the tap it just wrote.
out=$("$NG" usage --state-dir "$STATE" --repo "$FAKE_NEXUS" 2>&1) || true
assert_contains "ng usage renders the report header" "$out" "mechanism-usage assessment"
assert_contains "ng usage --json is valid" \
    "$(python3 -c 'import json,sys; json.load(sys.stdin); print("ok")' <<<"$("$NG" usage --json --state-dir "$STATE" --repo "$FAKE_NEXUS" 2>/dev/null)")" "ok"

# ---- summary ------------------------------------------------------------
echo
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED ($PASS assertions)"
    exit 0
else
    echo "SOME TESTS FAILED ($FAIL failed, $PASS passed)" >&2
    exit 1
fi
