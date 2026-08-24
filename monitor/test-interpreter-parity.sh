#!/usr/bin/env bash
# test-interpreter-parity.sh — the suite must not claim coverage of a shell it
# did not run (your-org/nexus-code#610).
#
# THE BLIND SPOT. No host in this workspace runs bash 5.x; CI runs only 5.2.
# A local "all tests passed" therefore cannot see a 5.2-only failure class *even
# in principle*, and CI cannot see a 4.4-only one — while 4.4 is what the live
# watcher actually executes. Two 5.2-only defects have already been paid for in
# CI after the fact: the fork-floor probe that collapsed to its lower bound
# (#597: cap 87 against a real floor of 566, every test then dying of EAGAIN)
# and `patsub_replacement` corrupting generated gh stubs.
#
# WHAT IS ASSERTED HERE. Two independent properties, because either alone is
# insufficient:
#   (a) NEXUS_TEST_SHELL genuinely dispatches the tests to the named
#       interpreter — the ABILITY to falsify a 5.2 claim locally; and
#   (b) when the interpreter differs from CI's pin, the run SAYS SO in its
#       verdict — so a green run under 4.4 cannot be read as covering 5.2.
# (a) without (b) leaves the false green intact for anyone who forgets the env
# var; (b) without (a) is a warning with no remedy behind it.
#
# COVERAGE BOUNDARY (one sentence). These assertions cover the runner's
# interpreter SELECTION and its DECLARATION — that the chosen bash is the one
# that executes each test, and that a divergence from monitor/ci-bash-version
# is stated rather than implied — and not whether any particular bash version
# is actually installed here, which monitor/toolchain-bash.sh provides on
# demand and which CI's bash-legacy job exercises end to end.
#
# Run: bash monitor/test-interpreter-parity.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/.." && pwd)
RUNNER="$REPO_ROOT/monitor/watcher/run-tests.sh"
TOOLCHAIN="$REPO_ROOT/monitor/toolchain-bash.sh"
PIN_FILE="$REPO_ROOT/monitor/ci-bash-version"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# A trivial passing test for the runner to dispatch.
cat > "$TMP/test-noop.sh" <<'EOF'
#!/usr/bin/env bash
echo "noop ok"
exit 0
EOF

# ===========================================================================
# 1. THE PIN IS PRESENT AND WELL-FORMED. Everything else reads it.
# ===========================================================================
echo "--- 1. monitor/ci-bash-version declares a major.minor ---"
if [[ -r "$PIN_FILE" ]]; then
    pin=$(grep -v '^[[:space:]]*#' "$PIN_FILE" | grep -v '^[[:space:]]*$' \
          | head -1 | tr -d '[:space:]')
    if [[ "$pin" =~ ^[0-9]+\.[0-9]+$ ]]; then
        ok "pin file declares '$pin'"
    else
        bad "pin format" "expected major.minor, got '$pin'"
    fi
else
    bad "pin file" "$PIN_FILE is missing or unreadable"
fi

# ===========================================================================
# 2. NEXUS_TEST_SHELL ACTUALLY LAUNCHES THE TESTS.
#
#    Asserted via a shim that execs the real bash after stamping a sentinel,
#    and a test that records what it saw. Checking only that the runner PRINTS
#    an interpreter banner would be the proxy; what matters is which process
#    the test file was handed to. The shim makes that observable on any host,
#    with or without a second bash installed.
# ===========================================================================
echo "--- 2. NEXUS_TEST_SHELL is the process that runs each test ---"
cat > "$TMP/shim-bash" <<EOF
#!/usr/bin/env bash
export NEXUS_PARITY_SENTINEL=via-shim
exec $(command -v bash) "\$@"
EOF
chmod +x "$TMP/shim-bash"
cat > "$TMP/test-sentinel.sh" <<'EOF'
#!/usr/bin/env bash
printf 'sentinel=%s version=%s\n' "${NEXUS_PARITY_SENTINEL:-unset}" "$BASH_VERSION"
[[ "${NEXUS_PARITY_SENTINEL:-unset}" == via-shim ]]
EOF
out=$(NEXUS_TEST_SHELL="$TMP/shim-bash" NEXUS_TEST_NPROC_GUARD=off \
      bash "$RUNNER" --jobs 1 "$TMP/test-sentinel.sh" 2>&1); rc=$?
if (( rc == 0 )) && grep -q 'PASS  test-sentinel.sh' <<<"$out"; then
    ok "the test observed the shim's sentinel — NEXUS_TEST_SHELL is the launcher"
else
    bad "dispatch" "the sentinel test did not pass under the shim (rc=$rc):
$out"
fi

# Negative control: the SAME test must FAIL without the shim. Otherwise case 2
# would pass for a runner that ignores NEXUS_TEST_SHELL entirely.
#
# `env -u` rather than merely omitting the assignment: under the bash-legacy CI
# job an ambient NEXUS_TEST_SHELL is EXPORTED for the whole suite, so "without
# the shim" would silently have meant "with the job's 4.4.18" — the assertion
# would still have passed, while testing something other than what it says.
out=$(env -u NEXUS_TEST_SHELL NEXUS_TEST_NPROC_GUARD=off \
      bash "$RUNNER" --jobs 1 "$TMP/test-sentinel.sh" 2>&1); rc=$?
if (( rc != 0 )) && grep -q 'FAIL  test-sentinel.sh' <<<"$out"; then
    ok "without NEXUS_TEST_SHELL the same test FAILS — case 2 is not vacuous"
else
    bad "dispatch control" "expected a FAIL without the shim, got rc=$rc:
$out"
fi

# ===========================================================================
# 3. A NON-EXECUTABLE NEXUS_TEST_SHELL IS REFUSED, NOT SILENTLY REPLACED.
#
#    Falling back to the system bash is the precise substitution #610 is
#    about: a worker who asked for 5.2, got 4.4, and read the green as
#    covering 5.2.
# ===========================================================================
echo "--- 3. an unusable interpreter is refused (exit 2), never substituted ---"
out=$(NEXUS_TEST_SHELL="$TMP/does-not-exist-bash" \
      bash "$RUNNER" --jobs 1 "$TMP/test-noop.sh" 2>&1); rc=$?
if (( rc == 2 )) \
   && grep -q 'is not executable' <<<"$out" \
   && grep -q 'Refusing to silently fall back' <<<"$out"; then
    ok "missing interpreter → exit 2 naming the refusal to fall back"
else
    bad "refusal" "expected exit 2 + the fall-back refusal message, got rc=$rc:
$out"
fi

echo "--- 3b. an interpreter that is not bash is refused ---"
printf '#!/bin/sh\nexit 0\n' > "$TMP/not-bash"; chmod +x "$TMP/not-bash"
out=$(NEXUS_TEST_SHELL="$TMP/not-bash" \
      bash "$RUNNER" --jobs 1 "$TMP/test-noop.sh" 2>&1); rc=$?
if (( rc == 2 )) && grep -q 'did not report a BASH_VERSINFO' <<<"$out"; then
    ok "a non-bash interpreter → exit 2 ('did not report a BASH_VERSINFO')"
else
    bad "non-bash refusal" "expected exit 2 + the BASH_VERSINFO message, got rc=$rc:
$out"
fi

# ===========================================================================
# 4. THE DECLARATION. A run whose interpreter differs from the pin must SAY SO.
# ===========================================================================
echo "--- 4. a mismatched interpreter prints a COVERAGE BOUNDARY ---"
# The interpreter these cases run under, pinned explicitly rather than
# inherited — see the note in 4b for what inheriting it cost.
PIN_BASH=$(command -v bash)
here_ver=$("$PIN_BASH" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')
printf '99.9\n' > "$TMP/pin-mismatch"
out=$(NEXUS_CI_BASH_VERSION_FILE="$TMP/pin-mismatch" NEXUS_TEST_NPROC_GUARD=off \
      NEXUS_TEST_SHELL="$PIN_BASH" \
      bash "$RUNNER" --jobs 1 "$TMP/test-noop.sh" 2>&1); rc=$?
if (( rc == 0 )) \
   && grep -q 'COVERAGE BOUNDARY' <<<"$out" \
   && grep -q 'CI runs bash 99.9' <<<"$out" \
   && grep -q 'a pass above is not a claim about it' <<<"$out" \
   && grep -q 'toolchain-bash.sh --print-path' <<<"$out"; then
    ok "mismatch → green run STILL declares the boundary and names the remedy"
else
    bad "boundary declaration" "expected a COVERAGE BOUNDARY naming 99.9 (rc=$rc):
$out"
fi

echo "--- 4b. a matching interpreter says so instead ---"
# PIN_BASH is set above, and every nested run below passes NEXUS_TEST_SHELL
# EXPLICITLY. Deriving the pin from `bash` on PATH while letting the nested
# runner INHERIT an ambient NEXUS_TEST_SHELL compares two different binaries:
# that is exactly how this test failed on its first run under the bash-legacy
# CI job (which exports NEXUS_TEST_SHELL=<built 4.4.18> for the whole suite,
# so the pin said 5.2 and the interpreter was 4.4). A test about which
# interpreter is in use must not itself inherit one.
printf '%s\n' "$here_ver" > "$TMP/pin-match"
out=$(NEXUS_CI_BASH_VERSION_FILE="$TMP/pin-match" NEXUS_TEST_NPROC_GUARD=off \
      NEXUS_TEST_SHELL="$PIN_BASH" \
      bash "$RUNNER" --jobs 1 "$TMP/test-noop.sh" 2>&1); rc=$?
if (( rc == 0 )) \
   && grep -q "interpreter parity: bash $here_ver" <<<"$out" \
   && ! grep -q 'COVERAGE BOUNDARY' <<<"$out"; then
    ok "match → 'interpreter parity' and NO boundary warning (the two are exclusive)"
else
    bad "parity declaration" "expected a parity line and no boundary (rc=$rc):
$out"
fi

# ===========================================================================
# 5. --require-ci-parity CONVERTS THE DECLARATION INTO A REFUSAL.
# ===========================================================================
echo "--- 5. --require-ci-parity fails a mismatched run outright ---"
out=$(NEXUS_CI_BASH_VERSION_FILE="$TMP/pin-mismatch" NEXUS_TEST_SHELL="$PIN_BASH" \
      bash "$RUNNER" --require-ci-parity --jobs 1 "$TMP/test-noop.sh" 2>&1); rc=$?
if (( rc == 2 )) && grep -q 'require-ci-parity' <<<"$out" \
   && grep -q 'CI runs bash 99.9' <<<"$out"; then
    ok "mismatch + --require-ci-parity → exit 2 before any test runs"
else
    bad "require-ci-parity" "expected exit 2 naming the versions, got rc=$rc:
$out"
fi

out=$(NEXUS_CI_BASH_VERSION_FILE="$TMP/pin-match" NEXUS_TEST_NPROC_GUARD=off \
      NEXUS_TEST_SHELL="$PIN_BASH" \
      bash "$RUNNER" --require-ci-parity --jobs 1 "$TMP/test-noop.sh" 2>&1); rc=$?
if (( rc == 0 )); then
    ok "match + --require-ci-parity → runs normally (the flag is not a blanket refusal)"
else
    bad "require-ci-parity control" "expected 0 on a matching pin, got rc=$rc:
$out"
fi

# ===========================================================================
# 6. THE TOOLCHAIN BUILDER'S CONTRACT (no network needed for these).
# ===========================================================================
echo "--- 6. toolchain-bash.sh refuses an unpinned version ---"
out=$(bash "$TOOLCHAIN" --version 9.9 2>&1); rc=$?
if (( rc != 0 )) && grep -q 'no pinned sha256 for bash-9.9' <<<"$out" \
   && grep -q 'unpinned toolchain is not a reproducible one' <<<"$out"; then
    ok "an unpinned version is refused with the reproducibility rationale"
else
    bad "toolchain pin" "expected a refusal naming bash-9.9, got rc=$rc:
$out"
fi

echo "--- 6b. --check reports build state without building ---"
out=$(NEXUS_TOOLCHAIN_DIR="$TMP/empty-toolchain" bash "$TOOLCHAIN" \
      --version 5.2 --check 2>&1); rc=$?
if (( rc == 1 )) && [[ -z "$out" ]]; then
    ok "--check on an unbuilt toolchain exits 1 silently (no build attempted)"
else
    bad "--check" "expected a silent exit 1, got rc=$rc: '$out'"
fi

echo "--- 6c. a built toolchain is detected by ASKING THE BINARY ---"
built=$(bash "$TOOLCHAIN" --version 5.2 --check --print-path 2>/dev/null); crc=$?
if (( crc == 0 )) && [[ -x "$built" ]]; then
    got=$("$built" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')
    if [[ "$got" == 5.2 ]]; then
        ok "the built toolchain reports bash $got when interrogated ($built)"
    else
        bad "toolchain version" "built binary reports '$got', not 5.2"
    fi
    # The payoff: the suite can now actually run under CI's interpreter.
    out=$(NEXUS_TEST_SHELL="$built" NEXUS_TEST_NPROC_GUARD=off \
          bash "$RUNNER" --jobs 1 "$TMP/test-noop.sh" 2>&1); rc=$?
    if (( rc == 0 )) && grep -q 'interpreter parity: bash 5.2' <<<"$out"; then
        ok "the suite runs under the built 5.2 and declares PARITY, not a boundary"
    else
        bad "toolchain run" "expected a parity declaration under the built 5.2 (rc=$rc):
$out"
    fi
else
    echo "  SKIP: no bash-5.2 toolchain built on this host — the end-to-end"
    echo "        'run the suite under CI's interpreter' case was NOT asserted."
    echo "        Build it with: monitor/toolchain-bash.sh --version 5.2"
fi

# ===========================================================================
# 7. HERMETICITY. Every nested run-tests.sh invocation in THIS file must pin
#    NEXUS_TEST_SHELL explicitly.
#
#    This is a regression guard for a real failure, not a hypothetical: on its
#    first run under the new bash-legacy CI job — which exports
#    NEXUS_TEST_SHELL=<built 4.4.18> for the whole suite — cases 4b and 5
#    derived their pin from `bash` on PATH (5.2) while the nested runner
#    INHERITED 4.4.18, so a test about interpreter parity compared two
#    different binaries and failed. 217 of 218 tests passed under 4.4 in that
#    run; the only casualty was this file.
#
#    A static check rather than a behavioural one, deliberately: reproducing it
#    needs a SECOND bash of a different version present, which is true in the
#    bash-legacy job and false in every other cell. The bash-legacy job passing
#    is the behavioural proof; this keeps the invariant checkable everywhere.
# ===========================================================================
echo "--- 7. every nested runner invocation pins its interpreter ---"
# `hermeticity-lint-self` marks the matcher's OWN lines and the control probe
# below, which necessarily contain the pattern — the same self-exclusion the
# other lints in this repo use, kept to exactly the lines that need it.
# "Pinned" means EITHER an explicit NEXUS_TEST_SHELL= assignment OR an explicit
# `env -u NEXUS_TEST_SHELL`; both are deliberate control of the interpreter,
# which is the property. Only silent inheritance is the defect.
mapfile -t unpinned < <(
    grep -n 'bash "$RUNNER"' "${BASH_SOURCE[0]}" | grep -v 'hermeticity-lint-self' \
        | while IFS=: read -r n _; do
            # Env assignments may sit on continuation lines above the call.
            start=$(( n > 6 ? n - 6 : 1 ))
            block=$(sed -n "${start},${n}p" "${BASH_SOURCE[0]}")
            grep -qE 'NEXUS_TEST_SHELL=|env -u NEXUS_TEST_SHELL' <<<"$block" || echo "$n"
          done
)   # hermeticity-lint-self
if (( ${#unpinned[@]} == 0 )); then
    ok "all nested run-tests.sh invocations set NEXUS_TEST_SHELL explicitly"
else
    bad "hermeticity" "these lines invoke the runner without pinning NEXUS_TEST_SHELL,
so they inherit whatever the OUTER suite set (the bash-legacy job sets it):
  line(s): ${unpinned[*]}"
fi

# And the control: the check must be able to see an unpinned call at all.
probe=$(printf '%s\n' 'out=$(NEXUS_TEST_NPROC_GUARD=off \' '      bash "$RUNNER" --jobs 1 x 2>&1)')  # hermeticity-lint-self
probe_matched=0; probe_pinned=0   # hermeticity-lint-self
grep -q 'bash "$RUNNER"' <<<"$probe" && probe_matched=1   # hermeticity-lint-self
grep -qE 'NEXUS_TEST_SHELL=|env -u NEXUS_TEST_SHELL' <<<"$probe" && probe_pinned=1
if (( probe_matched == 1 && probe_pinned == 0 )); then
    ok "the hermeticity check's matcher does detect an unpinned invocation"
else
    bad "hermeticity control" "the matcher cannot see an unpinned call — case 7 is vacuous"
fi

# ===========================================================================
echo
if (( FAIL > 0 )); then
    printf '%d passed, %d FAILED\n' "$PASS" "$FAIL"
    exit 1
fi
printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
exit 0
