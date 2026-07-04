#!/usr/bin/env bash
# Unit tests for `ng dashboard` and its sub-verbs (cmd_dashboard /
# cmd_dashboard_get / cmd_dashboard_put / _overview_number in
# monitor/ng).
#
# Run: bash monitor/watcher/test-ng-dashboard.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: PATH-shadow `gh` to capture endpoint+method and to return
# canned issue meta. Drive `ng dashboard get|put` and inspect captured
# argv + stdout + the side effects on $STATE_DIR (cache file, freshness
# timestamp).
#
# Coverage map (from your-org/nexus-code#60):
#   cmd_dashboard dispatch — usage on missing / unknown subcommand.
#   _overview_number — config-pinned (github.overview_issue_number)
#     short-circuits cache + live API; cache file short-circuits
#     live API; live API issues label-filtered GET on cold path and
#     writes the cache.
#   cmd_dashboard_get — extracts only middle between
#     <!-- NEXUS_DASHBOARD_START --> and <!-- NEXUS_DASHBOARD_END -->;
#     misses markers → structured die; missing body → die.
#   cmd_dashboard_put — splice-merges new middle into the existing
#     issue body (preserves prefix + suffix); empty body input → die;
#     missing markers → die; cache file mirrors new middle; freshness
#     timestamp file written under $STATE_DIR.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-ng-dashboard-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# --allow-default so the stub falls through to printf "$2" on unknown
# keys (e.g. nexus.root default, monitor.interval_seconds default).
setup_fake_nexus "$WORK/nexus" --allow-default
NG="$FAKE_NEXUS/monitor/ng"

# config/load.sh defaults to no pinned overview number (overview_issue_number
# returns the supplied default ""). Specific tests override this by
# regenerating load.sh inline.
write_pinned_overview() {
    local pinned="${1:-}"   # numeric value, or "" for unset
    cat > "$FAKE_NEXUS/config/load.sh" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    github.repo)                    printf 'default-org/default-repo' ;;
    github.user_login)              printf 'test-user' ;;
    github.overview_issue_number)   printf '%s' '$pinned' ;;
    *) [[ \$# -ge 2 ]] && { printf '%s' "\$2"; exit 0; }; exit 2 ;;
esac
STUB
    chmod +x "$FAKE_NEXUS/config/load.sh"
}
write_pinned_overview ""

STUB_DIR="$WORK/bin"
CAPTURE="$WORK/gh-calls.txt"
BODY_CAPTURE="$WORK/gh-body.txt"

# `gh` stub:
#   GET    /repos/.../issues?labels=nexus:overview... — returns a
#          single-element array carrying number=37 (the "live" overview).
#          MOCK_API_ATTEMPT_FAIL=N: first N calls return [] so we can
#          exercise the retry-with-backoff path.
#   GET    /repos/.../issues/<n>                       — returns canned
#          body with DASH_START..DASH_END markers or honors MOCK_BODY.
#   PATCH  /repos/.../issues/<n>                       — returns the
#          html_url. The piped JSON body is captured for inspection.
#   anything else                                      — empty JSON.
make_gh_stub "$STUB_DIR/gh" "$CAPTURE" --with-body-capture "$BODY_CAPTURE" <<'CASES'
    */issues\?labels=nexus:overview*|*/issues?labels=nexus:overview*)
        # Two patterns: gh sometimes URL-encodes `?` differently, but
        # _overview_number passes the literal `?labels=` in the endpoint
        # path — so the second pattern wins.
        attempt_state="${MOCK_ATTEMPT_STATE_FILE:-/dev/null}"
        attempt=0
        if [[ -f "$attempt_state" ]]; then
            attempt=$(<"$attempt_state")
        fi
        attempt=$(( attempt + 1 ))
        printf '%d' "$attempt" > "$attempt_state"
        if [[ -n "${MOCK_API_ATTEMPT_FAIL:-}" && \
              "$attempt" -le "$MOCK_API_ATTEMPT_FAIL" ]]; then
            printf '[]'
        else
            printf '[{"number":37,"title":"Nexus overview"}]'
        fi
        ;;
    */issues/[0-9]*)
        # Numeric-tail path: GET /repos/.../issues/<n> or PATCH same.
        # `[0-9]*` is load-bearing — if a caller (e.g. _overview_number
        # die-in-subshell) yields an empty issue number, the endpoint
        # becomes `/issues/` (no digit). Refusing to match falls into
        # the catchall `{}` arm so the test surfaces the upstream
        # failure instead of papering over it.
        # Per-test body override lives in $MOCK_BODY_FILE if set; else
        # canned full body with markers + a 3-line dashboard middle.
        if [[ "$method" == "PATCH" ]]; then
            printf '%s' '{"html_url":"https://mock.example/issues/37"}'
            return 0 2>/dev/null || exit 0
        fi
        if [[ -n "${MOCK_BODY_FILE:-}" && -f "${MOCK_BODY_FILE:-}" ]]; then
            jq -Rs '{body: .}' < "$MOCK_BODY_FILE"
        else
            printf '%s' '{"body":"prefix line\n<!-- NEXUS_DASHBOARD_START -->\nold middle line 1\nold middle line 2\n<!-- NEXUS_DASHBOARD_END -->\nsuffix line\n"}'
        fi
        ;;
    *)
        printf '%s' '{}'
        ;;
CASES

NEUTRAL_CWD="$WORK/neutral"
mkdir -p "$NEUTRAL_CWD"

run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    : > "$CAPTURE"; : > "$BODY_CAPTURE"
    # Reset the attempt counter per call so MOCK_API_ATTEMPT_FAIL is
    # consistent within a single ng invocation.
    : > "$WORK/gh-attempt"
    ( cd "$NEUTRAL_CWD" && run_hermetic \
        NEXUS_STATE_DIR="$WORK/state" \
        PATH="$STUB_DIR:$PATH" \
        MOCK_BODY_FILE="${MOCK_BODY_FILE:-}" \
        MOCK_API_ATTEMPT_FAIL="${MOCK_API_ATTEMPT_FAIL:-}" \
        MOCK_ATTEMPT_STATE_FILE="$WORK/gh-attempt" \
        -- "$NG" "$@" ) >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

# ---- Test 1: dispatch — missing / unknown subcommand --------------------

echo '=== ng dashboard (no subcommand) → usage on stderr, exit 1 ==='
run_ng out err rc dashboard
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stderr names get|put"              "$err" "ng dashboard get|put"

echo '=== ng dashboard bogus → usage on stderr, exit 1 ==='
run_ng out err rc dashboard bogus
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stderr names get|put"              "$err" "ng dashboard get|put"

# ---- Test 2: _overview_number — config-pinned short-circuits ----------

echo '=== github.overview_issue_number=99 → no live API call ==='
write_pinned_overview 99
# Pre-populate the cache file with a different number to prove the
# pinned value (99) wins over both cache and live API.
mkdir -p "$WORK/state"
printf '111' > "$WORK/state/overview-number"
run_ng out err rc dashboard get
assert_eq        "exit 0"                            "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "GET hits pinned number 99"         "$calls" "/repos/default-org/default-repo/issues/99"
assert_not_contains "no labels lookup when pinned"   "$calls" "labels=nexus:overview"
assert_not_contains "no fallback to cache=111"       "$calls" "/issues/111"
write_pinned_overview ""

# ---- Test 3: _overview_number — cache file wins over live API --------

echo '=== overview_issue_number unset, cache=88 → no live API call ==='
mkdir -p "$WORK/state"
printf '88' > "$WORK/state/overview-number"
run_ng out err rc dashboard get
assert_eq        "exit 0"                            "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "GET hits cached number 88"         "$calls" "/repos/default-org/default-repo/issues/88"
assert_not_contains "no labels lookup when cached"   "$calls" "labels=nexus:overview"
rm -f "$WORK/state/overview-number"

# ---- Test 4: _overview_number — live API on cold path, then cache ------

echo '=== cold path → labels GET → writes cache file ==='
rm -rf "$WORK/state"
run_ng out err rc dashboard get
assert_eq        "exit 0"                            "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "labels-filtered lookup on cold"    "$calls" "/repos/default-org/default-repo/issues?labels=nexus:overview&state=open"
assert_contains  "GET hits resolved number 37"       "$calls" "/repos/default-org/default-repo/issues/37"
# Side effect: cache file written.
assert_file_exists "overview-number cache file"      "$WORK/state/overview-number"
cached=$(<"$WORK/state/overview-number")
assert_eq        "cache file content = 37"           "$cached" "37"

# ---- Test 5: _overview_number — retry/backoff on transient empty -------
#
# MOCK_API_ATTEMPT_FAIL=2 → first two label-filtered calls return [],
# third returns the canned single-element array. _overview_number
# retries up to 3 times with exponential backoff — so the third
# attempt is the success.

echo '=== labels GET returns [] twice, succeeds on third → exit 0 ==='
rm -rf "$WORK/state"
MOCK_API_ATTEMPT_FAIL=2 run_ng out err rc dashboard get
assert_eq        "exit 0 after retry"                "$rc" "0"
# 3 labels-filter calls captured in argv.
labels_calls=$(grep -c "labels=nexus:overview" <<<"$(<"$CAPTURE")" || true)
assert_eq        "3 labels-filter calls captured"    "$labels_calls" "3"

# ---- Test 6: _overview_number — all retries fail → structured die ------

echo '=== labels GET returns [] all 3 times → exit 1, die message ==='
rm -rf "$WORK/state"
MOCK_API_ATTEMPT_FAIL=99 run_ng out err rc dashboard get
assert_eq        "exit 1 after all retries fail"     "$rc" "1"
assert_contains  "die message names 3 attempts"      "$err" "3 attempts"
assert_contains  "die message names pin escape"      "$err" "github.overview_issue_number"

# ---- Test 7: cmd_dashboard_get — extracts only middle between markers ---

echo '=== ng dashboard get → middle-only output ==='
write_pinned_overview 37
rm -rf "$WORK/state"
run_ng out err rc dashboard get
assert_eq        "exit 0"                            "$rc" "0"
# Canned body's middle has exactly two lines.
assert_contains  "middle line 1 in output"           "$out" "old middle line 1"
assert_contains  "middle line 2 in output"           "$out" "old middle line 2"
# Prefix/suffix lines should NOT appear in the middle-only output.
assert_not_contains "no prefix line"                 "$out" "prefix line"
assert_not_contains "no suffix line"                 "$out" "suffix line"
# Side effect: middle cached at $STATE_DIR/dashboard.md.
assert_file_exists "dashboard.md cache"              "$WORK/state/dashboard.md"
cached_middle=$(<"$WORK/state/dashboard.md")
assert_contains  "cache mirrors middle line 1"       "$cached_middle" "old middle line 1"
assert_not_contains "cache excludes prefix"          "$cached_middle" "prefix line"

# ---- Test 8: cmd_dashboard_get — missing markers → die ----------------

echo '=== overview body lacks markers → exit 1 ==='
no_markers="$WORK/no-markers.body"
printf 'just a body without markers\n' > "$no_markers"
MOCK_BODY_FILE="$no_markers" run_ng out err rc dashboard get
assert_eq        "exit 1 on no markers"              "$rc" "1"
assert_contains  "die mentions markers missing"      "$err" "dashboard markers missing"

# ---- Test 9: cmd_dashboard_get — empty body → die ---------------------

echo '=== overview body empty → exit 1 ==='
empty_body="$WORK/empty.body"
: > "$empty_body"
MOCK_BODY_FILE="$empty_body" run_ng out err rc dashboard get
assert_eq        "exit 1 on empty body"              "$rc" "1"
assert_contains  "die names empty body"              "$err" "empty body"

# ---- Test 10: cmd_dashboard_put — splice merges new middle ------------

echo '=== ng dashboard put → PATCH body preserves prefix/suffix ==='
new_middle="$WORK/new-middle.md"
printf 'NEW DASHBOARD LINE A\nNEW DASHBOARD LINE B\n' > "$new_middle"
rm -rf "$WORK/state"
run_ng out err rc dashboard put --body-file "$new_middle"
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  "stdout prints PATCH html_url"      "$out" "https://mock.example/issues/37"
calls=$(<"$CAPTURE")
assert_contains  "PATCH endpoint hits issue 37"      "$calls" "-X PATCH /repos/default-org/default-repo/issues/37"
# The PATCH body has shape {"body": "<full merged content>"} — extract
# and inspect.
merged=$(jq -r '.body' < "$BODY_CAPTURE")
assert_contains  "merged body keeps prefix line"     "$merged" "prefix line"
assert_contains  "merged body keeps suffix line"     "$merged" "suffix line"
assert_contains  "merged body has new line A"        "$merged" "NEW DASHBOARD LINE A"
assert_contains  "merged body has new line B"        "$merged" "NEW DASHBOARD LINE B"
assert_not_contains "old middle line 1 dropped"      "$merged" "old middle line 1"
assert_not_contains "old middle line 2 dropped"      "$merged" "old middle line 2"
# Markers still in place around the new middle.
assert_contains  "DASH_START preserved"              "$merged" "<!-- NEXUS_DASHBOARD_START -->"
assert_contains  "DASH_END preserved"                "$merged" "<!-- NEXUS_DASHBOARD_END -->"

# Side effects:
#   - dashboard.md cache mirrors the new middle (not the merged body).
#   - dashboard-updated.ts written as a freshness marker.
cached_middle=$(<"$WORK/state/dashboard.md")
assert_contains  "cache reflects new line A"         "$cached_middle" "NEW DASHBOARD LINE A"
assert_not_contains "cache excludes prefix"          "$cached_middle" "prefix line"
assert_file_exists "freshness timestamp written"     "$WORK/state/dashboard-updated.ts"
ts_content=$(<"$WORK/state/dashboard-updated.ts")
# date -Is shape: YYYY-MM-DDThh:mm:ss±HH:MM (or +0000).
if [[ "$ts_content" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
    printf '  PASS: freshness timestamp has ISO-8601 shape\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: freshness timestamp not ISO-8601: %q\n' "$ts_content" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 11: cmd_dashboard_put — empty body → die --------------------

echo '=== ng dashboard put with empty body → exit 1 ==='
: > "$WORK/empty-put.md"
run_ng out err rc dashboard put --body-file "$WORK/empty-put.md"
assert_eq        "exit 1 on empty body"              "$rc" "1"
assert_contains  "die names empty dashboard body"    "$err" "empty dashboard body"

# ---- Test 12: cmd_dashboard_put — body file missing → die ------------

echo '=== ng dashboard put --body-file /nonexistent → exit 1 ==='
run_ng out err rc dashboard put --body-file "$WORK/does-not-exist.md"
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "die names missing body file"       "$err" "body file not found"

# ---- Test 13: cmd_dashboard_put — overview body lacks markers → die ----

echo '=== overview body lacks markers + put → exit 1, no PATCH ==='
MOCK_BODY_FILE="$no_markers" run_ng out err rc dashboard put --body-file "$new_middle"
assert_eq        "exit 1 on no markers"              "$rc" "1"
assert_contains  "die mentions markers missing"      "$err" "dashboard markers missing"
calls=$(<"$CAPTURE")
assert_not_contains "no PATCH on marker failure"     "$calls" "-X PATCH"

# ---- Test 14: cmd_dashboard_put — unknown flag → die ------------------

echo '=== ng dashboard put --bogus → exit 1 ==='
run_ng out err rc dashboard put --bogus value --body-file "$new_middle"
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "die names unknown flag"            "$err" "unknown flag: --bogus"

# ---- Test 15: cmd_dashboard_scaffold — emits all required sections ----

echo '=== ng dashboard scaffold → all six required sections, exit 0 ==='
run_ng out err rc dashboard scaffold
assert_eq        "exit 0"                            "$rc" "0"
for _s in "## Identity" "## Infra" "## Services" "## In-flight" \
          "## Awaiting operator" "## Recent landings"; do
    assert_contains "scaffold has '$_s'"             "$out" "$_s"
done
# Identity section must POINT at the identity block, not duplicate it.
assert_not_contains "scaffold ## Identity is a pointer, not a copy" \
                    "$out" "nexus-identity:start"

# ---- Test 16: cmd_dashboard_validate — complete body → exit 0 ---------

echo '=== ng dashboard validate (complete body) → exit 0 ==='
complete_dash="$WORK/complete-dash.md"
printf '## Identity\nx\n## Infra\nx\n## Services\nx\n## In-flight\nx\n## Awaiting operator\nx\n## Recent landings\nx\n' > "$complete_dash"
run_ng out err rc dashboard validate --body-file "$complete_dash"
assert_eq        "exit 0 on complete body"           "$rc" "0"
assert_contains  "validate reports OK"               "$out" "all 6 required sections present"

# ---- Test 17: cmd_dashboard_validate — incomplete → exit 1, names gaps -

echo '=== ng dashboard validate (incomplete body) → exit 1, lists missing ==='
incomplete_dash="$WORK/incomplete-dash.md"
printf '## Identity\nx\n## Infra\nx\n' > "$incomplete_dash"
run_ng out err rc dashboard validate --body-file "$incomplete_dash"
assert_eq        "exit 1 on incomplete body"         "$rc" "1"
# Multi-word section names must print intact (no word-splitting).
assert_contains  "names '## Awaiting operator'"      "$err" "## Awaiting operator"
assert_contains  "names '## Recent landings'"        "$err" "## Recent landings"

# ---- Test 18: scaffold output passes validate (schema self-consistency) -

echo '=== ng dashboard scaffold | validate → exit 0 (schema is self-consistent) ==='
run_ng out err rc dashboard scaffold
printf '%s\n' "$out" > "$WORK/scaffolded.md"
run_ng out2 err2 rc2 dashboard validate --body-file "$WORK/scaffolded.md"
assert_eq        "scaffold passes its own validate"  "$rc2" "0"

# ---- Test 19: cmd_dashboard_put — warns (not blocks) on missing sections

echo '=== ng dashboard put (missing sections) → WARNS on stderr but still PATCHes ==='
run_ng out err rc dashboard put --body-file "$incomplete_dash"
assert_eq        "exit 0 — warn, never block"        "$rc" "0"
assert_contains  "stderr carries the WARNING"        "$err" "WARNING"
assert_contains  "warn lists a missing section"      "$err" "## Services"
calls=$(<"$CAPTURE")
assert_contains  "PATCH still issued despite warn"   "$calls" "-X PATCH"

# ---- summary ------------------------------------------------------------

th_summary_and_exit
