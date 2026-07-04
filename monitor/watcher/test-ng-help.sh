#!/usr/bin/env bash
# Unit tests for `ng <verb> --help` / `-h` short-circuit and the
# structured rejection of `ng report-init --repo`.
#
# Run: bash monitor/watcher/test-ng-help.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: build a minimal fake nexus tree (ng + stubbed
# config/load.sh + stubbed mint-token.sh) then run each verb with
# --help and -h. Help should print a `usage: ng <verb>` line, exit 0,
# and produce no side effects on disk or the network. The
# report-init --repo rejection has a dedicated block at the bottom.

set -uo pipefail

# ---- harness ------------------------------------------------------------

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

# Test-local assertion not provided by _test_helpers.sh.
assert_no_file_matching() {
    local label="$1" dir="$2" pattern="$3"
    if compgen -G "$dir/$pattern" >/dev/null; then
        printf '  FAIL: %s — unexpected match for %s in %s\n' "$label" "$pattern" "$dir" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# setup_fake_nexus sets $FAKE_NEXUS to the populated dir.
# --allow-default mirrors the load.sh stub used by `ng help`.
setup_fake_nexus "$WORK/nexus" --allow-default
NG="$FAKE_NEXUS/monitor/ng"

# Override the default mint-token stub: help paths should never
# invoke mint-token, so we error loudly if any verb does.
cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
echo "test stub mint-token.sh must not be called in help-only tests" >&2
exit 99
STUB
chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    ( cd "$FAKE_NEXUS" && NEXUS_ROOT="$FAKE_NEXUS" "$NG" "$@" >"$_out_tmp" 2>"$_err_tmp" )
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

# ---- Test 1: --help on every covered verb -------------------------------

# Each entry: "<verb-tokens-with-spaces>|<expected-needle-in-usage>".
# The verb-tokens are word-split via the unquoted expansion below;
# the expected needle just has to appear somewhere in stdout+stderr.
declare -a HELP_VERBS=(
    "report-init|usage: ng report-init"
    "report-check|usage: ng report-check"
    "wrap-up|usage: ng wrap-up"
    "upload|usage: ng upload"
    "reply|usage: ng reply"
    "react|usage: ng react"
    "react-issue|usage: ng react-issue"
    "process|usage: ng process"
    "process-issue|usage: ng process-issue"
    "close|usage: ng close"
    "show|usage: ng show"
    "fetch-asset|usage: ng fetch-asset"
    "issue|usage: ng issue"
    "issue create|usage: ng issue create"
    "issue comment|usage: ng issue comment"
    "pr|usage: ng pr"
    "pr create|usage: ng pr create"
    "pr edit|usage: ng pr edit"
    "pr merge|usage: ng pr merge"
    "pr view|usage: ng pr view"
    "preflight|usage: ng preflight"
    "dashboard|usage: ng dashboard"
    "dashboard get|usage: ng dashboard get"
    "dashboard put|usage: ng dashboard put"
    "dashboard scaffold|usage: ng dashboard scaffold"
    "dashboard validate|usage: ng dashboard validate"
    "nexus-identity|usage: ng nexus-identity"
    "log-action|usage: ng log-action"
    "watcher-status|usage: ng watcher-status"
    "mint-jwt|usage: ng mint-jwt"
)

echo '=== --help short-circuit on every covered verb ==='
for entry in "${HELP_VERBS[@]}"; do
    verb="${entry%%|*}"
    needle="${entry#*|}"
    # shellcheck disable=SC2086 — intentional word split for verb tokens.
    run_ng out err rc $verb --help
    assert_eq       "exit 0: ng $verb --help"     "$rc" "0"
    assert_contains "usage line: ng $verb --help" "${out}${err}" "$needle"
done

# ---- Test 2: -h shortcut on the same set --------------------------------

echo '=== -h shortcut (equivalent to --help) ==='
for entry in "${HELP_VERBS[@]}"; do
    verb="${entry%%|*}"
    needle="${entry#*|}"
    # shellcheck disable=SC2086
    run_ng out err rc $verb -h
    assert_eq       "exit 0: ng $verb -h"     "$rc" "0"
    assert_contains "usage line: ng $verb -h" "${out}${err}" "$needle"
done

# ---- Test 3: --help on a leaf verb after a positional -------------------
#
# `_help_check` scans all args, not just $1. `ng reply 5 --help` should
# still short-circuit cleanly without trying to POST anything.

echo '=== --help anywhere in args (positional + flag) ==='
run_ng out err rc reply 5 --help
assert_eq       "exit 0: ng reply 5 --help"     "$rc" "0"
assert_contains "usage line: ng reply 5 --help" "${out}${err}" "usage: ng reply"

run_ng out err rc report-init slug --issue 7 --help
assert_eq       "exit 0: ng report-init slug --issue 7 --help" "$rc" "0"
assert_contains "usage line"                                   "${out}${err}" \
                "usage: ng report-init"

# ---- Test 4: no side effects from --help on report-init -----------------
#
# Regression test for the original bug: `ng report-init --help` used
# to treat `--help` as the slug and write a `<project>_<ts>_--help.md`
# skeleton into reports/. Help must not touch the filesystem.

echo '=== report-init --help leaves no skeleton on disk (regression) ==='
SAFE_REPORTS="$WORK/safe-reports"
mkdir -p "$SAFE_REPORTS"
run_ng out err rc report-init --help --reports-dir "$SAFE_REPORTS"
assert_eq       "exit 0"                              "$rc" "0"
assert_contains "stdout has usage line"               "$out" "usage: ng report-init"
assert_no_file_matching "no --help.md skeleton in reports-dir" \
                        "$SAFE_REPORTS" "*--help.md"
# Belt-and-suspenders: the default reports dir under NEXUS_ROOT
# must also stay clean.
assert_no_file_matching "no --help.md skeleton in NEXUS_ROOT/reports" \
                        "$FAKE_NEXUS/reports" "*--help.md"

# ---- Test 5: -h regression on report-init -------------------------------

echo '=== report-init -h also no skeleton ==='
SAFE_REPORTS2="$WORK/safe-reports-2"
mkdir -p "$SAFE_REPORTS2"
run_ng out err rc report-init -h --reports-dir "$SAFE_REPORTS2"
assert_eq       "exit 0"                              "$rc" "0"
assert_no_file_matching "no -h.md skeleton (short flag too)" \
                        "$SAFE_REPORTS2" "*-h.md"

# ---- Test 6: report-init --repo structured rejection --------------------

echo '=== report-init --repo → structured error, non-zero exit ==='
run_ng out err rc report-init demo --repo your-org/your-nexus --reports-dir "$SAFE_REPORTS"
assert_eq       "non-zero exit"                       "$rc" "1"
assert_contains "stderr names the verb"               "$err" \
                "report-init does not accept --repo"
assert_contains "stderr explains centralization"      "$err" \
                "reports/ is always written under \$NEXUS_ROOT"
assert_contains "stderr mentions worktree rationale"  "$err" \
                "worktree or secondary clone"
# And no file should have been created.
assert_no_file_matching "no skeleton written despite --repo" \
                        "$SAFE_REPORTS" "*demo*"

# ---- Test 7: report-init --repo at end of args still rejected -----------
#
# Argument-order independence: --repo anywhere in the loop triggers
# the rejection. Confirms the case-arm isn't position-dependent.

echo '=== report-init <slug> ... --repo X also rejected ==='
run_ng out err rc report-init demo --project p --repo a/b --reports-dir "$SAFE_REPORTS"
assert_eq       "non-zero exit (late --repo)"         "$rc" "1"
assert_contains "stderr explains centralization"      "$err" \
                "reports/ is always written under \$NEXUS_ROOT"

# ---- summary ------------------------------------------------------------

th_summary_and_exit
