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
# The forge's STORE — what a GET returns after a PATCH has updated it. Kept
# separate from the request capture precisely because #1118 is the case where
# the two disagree (your-org/nexus-code#1123 skeptic pass).
STORE="$WORK/gh-store.txt"
# The last PATCH's REQUEST body, kept where a later call cannot clear it.
# `make_gh_stub` truncates the body capture on any call that sends no `--input`
# (your-org/nexus-code#921 — "this call sent no body" is a real answer), and
# `_patch_issue_body` now issues an independent GET AFTER the PATCH, so the
# request capture is wiped before a test can read it.
PATCH_BODY="$WORK/gh-patch-body.txt"

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
            # your-org/nexus-code#1118 — MODEL THE FORGE AS MEASURED, NOT AS
            # ASSUMED. This arm used to answer an over-cap PATCH with the OLD
            # body, described in a comment as "GitHub's measured over-cap
            # behaviour". That is the OPPOSITE of what GitHub does, and the
            # word "measured" was doing work nothing supported.
            #
            # Measured live on scratch issue your-org/nexus-code#1128 (PATCH,
            # then an INDEPENDENT GET) during the skeptic pass on #1123:
            #   sent 262,144 B -> stored 262,144  LANDED
            #   sent 262,145 B -> stored 262,143  SWALLOWED
            #   sent 300,029 B -> stored     164  SWALLOWED
            # and `response_echoed_sent = YES` in EVERY case, swallows
            # included. The limit is 262,144 BYTES, not characters.
            #
            # So the response ALWAYS echoes the request; what varies is
            # whether the STORE is updated. That is why the store is a
            # separate file here and why the GET arm reads it: a mock whose
            # PATCH response is the only observable cannot express the defect
            # at all, which is how six assertions came to "prove" a fix
            # against a fiction.
            if [[ -n "${MOCK_PATCH_NO_BODY:-}" ]]; then
                printf '%s' '{"html_url":"https://mock.example/issues/37"}'
                return 0 2>/dev/null || exit 0
            fi
            # Echo the request back — always, exactly as the real forge does.
            if [[ -n "${MOCK_BODY_CAPTURE_PATH:-}" && -s "${MOCK_BODY_CAPTURE_PATH:-}" ]]; then
                # SWALLOW mode: echo the sent body but DO NOT update the store.
                if [[ -n "${MOCK_PATCH_MANGLE:-}" ]]; then
                    # CLIENT-SIDE corruption: the bytes that left here were
                    # already wrong, so the forge echoes AND stores the wrong
                    # bytes. Distinct from a swallow, where the echo is right
                    # and only the store is stale.
                    jq -c --arg u "https://mock.example/issues/37" \
                       '{html_url:$u, body:(.body + "MANGLED")}' < "$MOCK_BODY_CAPTURE_PATH"
                    if [[ -n "${MOCK_STORE_PATH:-}" ]]; then
                        { jq -j '.body' < "$MOCK_BODY_CAPTURE_PATH"; printf 'MANGLED'; } \
                          > "$MOCK_STORE_PATH" 2>/dev/null || true
                    fi
                    return 0 2>/dev/null || exit 0
                fi
                if [[ -n "${MOCK_PATCH_BODY_PATH:-}" ]]; then
                    cat "$MOCK_BODY_CAPTURE_PATH" > "$MOCK_PATCH_BODY_PATH" 2>/dev/null || true
                fi
                if [[ -z "${MOCK_PATCH_SWALLOW:-}" && -n "${MOCK_STORE_PATH:-}" ]]; then
                    jq -j '.body' < "$MOCK_BODY_CAPTURE_PATH" > "$MOCK_STORE_PATH" 2>/dev/null || true
                fi
                jq -c --arg u "https://mock.example/issues/37" \
                   '{html_url:$u, body:.body}' < "$MOCK_BODY_CAPTURE_PATH"
            else
                printf '%s' '{"html_url":"https://mock.example/issues/37"}'
            fi
            return 0 2>/dev/null || exit 0
        fi
        # GET: the STORE if a PATCH has updated it, else the fixture. This is
        # what makes an independent read-back meaningful in the harness.
        if [[ -n "${MOCK_STORE_PATH:-}" && -s "${MOCK_STORE_PATH:-}" ]]; then
            jq -Rs --arg u "https://mock.example/issues/37" '{html_url:$u, body:.}' < "$MOCK_STORE_PATH"
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
    # The forge's store and the surviving copy of the last PATCH request.
    # Both are per-invocation: a store left over from a previous run_ng would
    # answer the NEXT test's first GET, which is a fixture leaking across
    # tests — and is exactly what happened when this truncation was missing.
    : > "$STORE"; : > "$PATCH_BODY"
    # Reset the attempt counter per call so MOCK_API_ATTEMPT_FAIL is
    # consistent within a single ng invocation.
    : > "$WORK/gh-attempt"
    ( cd "$NEUTRAL_CWD" && run_hermetic \
        NEXUS_STATE_DIR="$WORK/state" \
        PATH="$STUB_DIR:$PATH" \
        MOCK_BODY_FILE="${MOCK_BODY_FILE:-}" \
        MOCK_API_ATTEMPT_FAIL="${MOCK_API_ATTEMPT_FAIL:-}" \
        MOCK_ATTEMPT_STATE_FILE="$WORK/gh-attempt" \
        MOCK_PATCH_SWALLOW="${MOCK_PATCH_SWALLOW:-}" \
        MOCK_PATCH_NO_BODY="${MOCK_PATCH_NO_BODY:-}" \
        MOCK_BODY_CAPTURE_PATH="$BODY_CAPTURE" \
        MOCK_STORE_PATH="$STORE" \
        MOCK_PATCH_BODY_PATH="$PATCH_BODY" \
        MOCK_PATCH_MANGLE="${MOCK_PATCH_MANGLE:-}" \
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
merged=$(jq -r '.body' < "$PATCH_BODY")
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
# your-org/nexus-code#958 — THIS ASSERTION USED TO PIN THE DEFECT.
# It required the string "empty dashboard body", which is a verdict about THE
# DASHBOARD produced by a command that had only established something about
# ITS OWN INPUT. The message now names the input; the test now checks that it
# does, and — the load-bearing half — that it does NOT blame the subject.
assert_contains     "die names the INPUT (the file it was handed)"  "$err" "--body-file"
assert_contains     "die says the file itself is empty"             "$err" "EMPTY"
assert_not_contains "die does NOT blame the dashboard"              "$err" "empty dashboard body"

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
assert_contains  "die names unknown flag"            "$err" "unknown flag: '--bogus'"

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

# ---- your-org/nexus-code#1010: a content-identical put is not a refresh ----
#
# Measured on 2026-08-25: `ng dashboard get > d.md` then `ng dashboard put
# --body-file d.md` — byte-for-byte what was already on the forge — advanced
# the stamp 09:35:52 -> 11:42:57 and cleared the watcher's staleness warning.
# A put that changed nothing purchased two hours of asserted freshness, and
# the warning's own remedy string (`refresh via monitor/ng dashboard put`) is
# what sends an operator to run exactly that.
#
# ASSERTED ON THE SIDE EFFECTS, NOT THE MESSAGE. `UNCHANGED` on stderr is
# worth nothing if the PATCH still went out and the stamp still moved — that
# is the same "success line as evidence" mistake the composer half of this
# bundle is about.
echo '=== #1010 a content-identical put: no PATCH, no stamp ==='
noop_mid="$WORK/noop-middle.md"
printf 'old middle line 1\nold middle line 2\n' > "$noop_mid"
rm -rf "$WORK/state"
run_ng out err rc dashboard put --body-file "$noop_mid"
assert_eq        "#1010 exit 0 — nothing failed, and nothing was done"  "$rc" "0"
assert_contains  "#1010 stderr says UNCHANGED"                          "$err" "UNCHANGED"
assert_contains  "#1010 …and says the stamp was not advanced"           "$err" "NOT advanced"
calls=$(<"$CAPTURE")
assert_not_contains "#1010 THE PROPERTY: no PATCH was issued"           "$calls" "-X PATCH"
assert_no_file   "#1010 THE PROPERTY: the freshness stamp was NOT written" \
                 "$WORK/state/dashboard-updated.ts"
# THE CONTROL, and it is what stops the fix from being "never stamp": a put
# that genuinely CHANGES the dashboard must still PATCH and still stamp.
# Without this, deleting the stamp write entirely would pass the block above.
echo '=== #1010 CONTROL: a put that DOES change the body still stamps ==='
real_mid="$WORK/real-middle.md"
printf 'old middle line 1\nold middle line 2 CHANGED\n' > "$real_mid"
rm -rf "$WORK/state"
run_ng out err rc dashboard put --body-file "$real_mid"
assert_eq        "#1010 CONTROL exit 0"                                 "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "#1010 CONTROL: the PATCH was issued"                  "$calls" "-X PATCH"
assert_file_exists "#1010 CONTROL: the freshness stamp WAS written" \
                 "$WORK/state/dashboard-updated.ts"
assert_not_contains "#1010 CONTROL: …and it is not announced as UNCHANGED" "$err" "UNCHANGED"

# ---- #1116 skeptic review, F3/F4: the UNCHANGED arm's own hygiene ---------
#
# F3: the arm did `cp "$tmp_new" "$DASH_CACHE"` with no `mkdir -p "$STATE_DIR"`
# (the changed path has one), so with STATE_DIR absent the cp printed
# "No such file or directory" and the verb still exited 0. The #1010 test above
# does `rm -rf "$WORK/state"` immediately before its no-op put and did NOT
# notice, because nothing asserted the cache — so the assertion, not the
# fixture, was missing.
echo '=== #1116 F3: the UNCHANGED arm creates STATE_DIR before writing the cache ==='
noop_mid2="$WORK/noop-middle-2.md"
printf 'old middle line 1\nold middle line 2\n' > "$noop_mid2"
rm -rf "$WORK/state"
run_ng out err rc dashboard put --body-file "$noop_mid2"
assert_eq        "#1116 F3 exit 0"                                  "$rc" "0"
assert_not_contains "#1116 F3 no cp error on stderr"                "$err" "No such file or directory"
assert_file_exists "#1116 F3 THE PROPERTY: the cache was actually written" \
                 "$WORK/state/dashboard.md"
# …and still no stamp: F3 must not be "fixed" by turning the no-op into a put.
assert_no_file   "#1116 F3 …and the freshness stamp is STILL not written" \
                 "$WORK/state/dashboard-updated.ts"

# F4: the arm ended `printf '%s\n' "$(api … | jq -r '.html_url // empty')"`, so
# a GET that fails or returns no html_url printed an EMPTY LINE at rc 0 — the
# emptiness-at-rc-0 shape, on the one path whose whole purpose is to stop
# reporting an achievement it did not make.
echo '=== #1116 F4: the UNCHANGED arm never prints an empty line at rc 0 ==='
rm -rf "$WORK/state"
run_ng out err rc dashboard put --body-file "$noop_mid2"
assert_eq "#1116 F4 exit 0" "$rc" "0"
if [[ -z "${out//[$' \t\n']/}" ]]; then
    # No URL available in this fixture (the stub GET returns no html_url) —
    # then the arm must SAY so rather than print a convincing blank.
    assert_contains "#1116 F4 an unavailable URL is stated on stderr, not printed as a blank line" \
                    "$err" "could not be read back"
else
    assert_contains "#1116 F4 a real URL was printed" "$out" "https://"
fi

# =========================================================================
# your-org/nexus-code#1118 — the 256 KiB cap, and the read-back that is the
# only thing that ever disagreed with it.
#
# Measured on your-org/your-nexus#1, 2026-08-28: an over-cap PATCH returns
# HTTP 200 whose body is THE ONE YOU SENT, while the STORE keeps the old one
# (measured on scratch issue #1128; `response_echoed_sent = YES` in every case,
# swallows included). `put` printed a URL, exited 0, and the
# watcher's freshness emit said "updated" — three independent surfaces
# agreeing about work that did not happen. The fixture below reproduces
# exactly that response shape.
# =========================================================================

# A live body whose markers are real, used both as the GET response and — in
# the swallow scenario — as the OLD body GitHub hands back at 200.
live_body="$WORK/live-body.md"
printf 'prefix line\n<!-- NEXUS_DASHBOARD_START -->\nold middle line 1\nold middle line 2\n<!-- NEXUS_DASHBOARD_END -->\nsuffix line\n' > "$live_body"
changed_mid="$WORK/changed-middle.md"
printf 'THIS IS THE CONTENT THAT MUST LAND\nsecond line\n' > "$changed_mid"

echo '=== #1118 THE DEFECT: PATCH answers 200 with the OLD body → put must NOT report success ==='
rm -rf "$WORK/state"
MOCK_BODY_FILE="$live_body" MOCK_PATCH_SWALLOW=1 \
    run_ng out err rc dashboard put --body-file "$changed_mid"
assert_eq        "#1118 exit 1 — the write is VERIFIED not applied"     "$rc" "1"
assert_contains  "#1118 stderr says the write did not land"             "$err" "THE WRITE DID NOT LAND"
assert_contains  "#1118 stderr names the 200 explicitly"                "$err" "HTTP 200"
# THE PROPERTY. Everything above is the message; these two are the behaviour
# that #1118 is actually about — the freshness stamp and the cache are claims
# about the FORGE, and a swallowed PATCH must buy neither.
assert_no_file   "#1118 THE PROPERTY: NO freshness stamp on a swallowed PATCH" \
                 "$WORK/state/dashboard-updated.ts"
assert_no_file   "#1118 THE PROPERTY: NO cache write on a swallowed PATCH" \
                 "$WORK/state/dashboard.md"
assert_empty     "#1118 no URL on stdout — callers parse stdout"        "$out"

echo '=== #1118 CONTROL: identical put, faithful PATCH → succeeds and DOES stamp ==='
# The negative control must fail for the EXPECTED reason, so the positive
# control has to hold every other variable constant: same body, same fixture,
# same command. MOCK_PATCH_SWALLOW is the only thing that changes.
rm -rf "$WORK/state"
MOCK_BODY_FILE="$live_body" run_ng out err rc dashboard put --body-file "$changed_mid"
assert_eq        "#1118 CONTROL exit 0"                                 "$rc" "0"
assert_contains  "#1118 CONTROL prints the URL"                         "$out" "https://mock.example/issues/37"
assert_file_exists "#1118 CONTROL: the freshness stamp WAS written" \
                 "$WORK/state/dashboard-updated.ts"
assert_file_exists "#1118 CONTROL: the cache WAS written"               "$WORK/state/dashboard.md"

echo '=== #1118 a PATCH response with no body at all is UNVERIFIED (rc 4), not failed ==='
# "Cannot verify" and "did not apply" are different facts and must not share
# an exit code — reporting a successful write as a failure is its own lie.
rm -rf "$WORK/state"
MOCK_BODY_FILE="$live_body" MOCK_PATCH_NO_BODY=1 \
    run_ng out err rc dashboard put --body-file "$changed_mid"
assert_eq        "#1118 exit 4 — UNVERIFIED is not FAILED"              "$rc" "4"
assert_contains  "#1118 stderr says UNVERIFIED"                         "$err" "UNVERIFIED"
assert_no_file   "#1118 THE PROPERTY: an unverified write stamps nothing either" \
                 "$WORK/state/dashboard-updated.ts"

echo '=== #1118 over the 262144-byte cap → REFUSED BEFORE SENDING, no PATCH at all ==='
# The refusal is the half that keeps a genuinely-at-the-cap dashboard from
# ever reaching GitHub's swallow. Note what is asserted: not just the rc, but
# that NO PATCH WAS ISSUED — the verb must not send something it knows will
# be dropped.
over_mid="$WORK/over-cap-middle.md"
python3 -c "import sys; sys.stdout.write('x'*262200 + '\n')" > "$over_mid"
rm -rf "$WORK/state"
MOCK_BODY_FILE="$live_body" run_ng out err rc dashboard put --body-file "$over_mid"
assert_eq        "#1118 over-cap exit 1"                                "$rc" "1"
assert_contains  "#1118 over-cap stderr REFUSES"                        "$err" "REFUSING to PATCH"
assert_contains  "#1118 over-cap stderr names the cap"                  "$err" "262144"
assert_not_contains "#1118 THE PROPERTY: no PATCH was issued at all"    "$(<"$CAPTURE")" "-X PATCH"
assert_no_file   "#1118 over-cap: no freshness stamp"                   "$WORK/state/dashboard-updated.ts"

echo '=== #1118 CONTROL: a body just UNDER the cap goes through ==='
# Holds everything constant but the one variable — size. Without this, "the
# refusal fires" is indistinguishable from "the verb is broken".
under_mid="$WORK/under-cap-middle.md"
python3 -c "import sys; sys.stdout.write('y'*200000 + '\n')" > "$under_mid"
rm -rf "$WORK/state"
MOCK_BODY_FILE="$live_body" run_ng out err rc dashboard put --body-file "$under_mid"
assert_eq        "#1118 CONTROL under-cap exit 0"                       "$rc" "0"
assert_contains  "#1118 CONTROL under-cap: the PATCH WAS issued"        "$(<"$CAPTURE")" "-X PATCH"
assert_file_exists "#1118 CONTROL under-cap: stamped"                   "$WORK/state/dashboard-updated.ts"

echo '=== #1118 approaching the cap warns while there is still room to trim ==='
warn_mid="$WORK/warn-middle.md"
python3 -c "import sys; sys.stdout.write('z'*250000 + '\n')" > "$warn_mid"
rm -rf "$WORK/state"
MOCK_BODY_FILE="$live_body" run_ng out err rc dashboard put --body-file "$warn_mid"
assert_eq        "#1118 warn-band still succeeds"                       "$rc" "0"
assert_contains  "#1118 warn-band warns about the cap"                  "$err" "WARNING"
# The diagnostic that makes the refusal actionable: region vs remainder tells
# the operator whether trimming the dashboard can even help.
assert_contains  "#1118 warn-band reports region vs outside-the-region"  "$err" "outside"

# =========================================================================
# your-org/nexus-code#959 — put takes the INNER region, and used to accept a
# full issue body, nest the markers, and then compound on every later put.
# =========================================================================

echo '=== #959 input containing a dashboard marker is REFUSED, nothing sent ==='
full_body_input="$WORK/full-body-input.md"
cp "$live_body" "$full_body_input"        # exactly the mistake: a FULL body
rm -rf "$WORK/state"
MOCK_BODY_FILE="$live_body" run_ng out err rc dashboard put --body-file "$full_body_input"
assert_eq        "#959 exit 1"                                          "$rc" "1"
assert_contains  "#959 stderr says the body contains a marker"          "$err" "CONTAINS a dashboard marker"
assert_contains  "#959 stderr names the INNER region convention"        "$err" "INNER region"
assert_not_contains "#959 THE PROPERTY: no PATCH was issued"            "$(<"$CAPTURE")" "-X PATCH"

echo '=== #959 CONTROL: the same put without markers in the input goes through ==='
rm -rf "$WORK/state"
MOCK_BODY_FILE="$live_body" run_ng out err rc dashboard put --body-file "$changed_mid"
assert_eq        "#959 CONTROL exit 0"                                  "$rc" "0"
assert_contains  "#959 CONTROL: the PATCH WAS issued"                   "$(<"$CAPTURE")" "-X PATCH"

echo '=== #959 a LIVE body already nested (2 marker pairs) is REFUSED, not built on ==='
nested_live="$WORK/nested-live.md"
printf 'prefix\n<!-- NEXUS_DASHBOARD_START -->\nA\n<!-- NEXUS_DASHBOARD_START -->\nB\n<!-- NEXUS_DASHBOARD_END -->\nC\n<!-- NEXUS_DASHBOARD_END -->\nsuffix\n' > "$nested_live"
rm -rf "$WORK/state"
MOCK_BODY_FILE="$nested_live" run_ng out err rc dashboard put --body-file "$changed_mid"
assert_eq        "#959 nested-live exit 1"                              "$rc" "1"
assert_contains  "#959 nested-live names the marker counts"             "$err" "2 START marker(s)"
assert_not_contains "#959 THE PROPERTY: refuses to splice into damage"  "$(<"$CAPTURE")" "-X PATCH"

echo '=== #959 _splice_body emits AT MOST ONCE (source-level, with a control) ==='
# `cmd_dashboard_put` now refuses a nested live body, so this guard is
# unreachable THROUGH the verb — it is defence in depth, and the only honest
# way to test it is to call the function. The test SOURCES monitor/ng, so it
# exercises the shipped text rather than a transcription of it. (`ng` guards
# `main` on BASH_SOURCE == $0, so sourcing defines without dispatching.)
splice_new="$WORK/splice-new.md"; printf 'NEWMIDDLE\n' > "$splice_new"
splice_run() {   # $1 = live-body file → stdout: spliced result
    ( cd "$NEUTRAL_CWD" && run_hermetic NEXUS_STATE_DIR="$WORK/state" PATH="$STUB_DIR:$PATH" -- \
        bash -c 'source "$1" >/dev/null 2>&1; _splice_body "$2" < "$3"' _ "$NG" "$splice_new" "$1" )
}
ctl_live="$WORK/splice-ctl.md"
printf 'HEAD\n<!-- NEXUS_DASHBOARD_START -->\nOLD\n<!-- NEXUS_DASHBOARD_END -->\nFOOT\n' > "$ctl_live"
ctl_out=$(splice_run "$ctl_live")
assert_eq "#959 CONTROL: a single marker pair emits the middle exactly once" \
          "$(printf '%s\n' "$ctl_out" | grep -c NEWMIDDLE)" "1"
nest_out=$(splice_run "$nested_live")
assert_eq "#959 THE PROPERTY: a NESTED pair still emits exactly once (was 2x)" \
          "$(printf '%s\n' "$nest_out" | grep -c NEWMIDDLE)" "1"

# =========================================================================
# your-org/nexus-code#1058 — validate answered PRESENCE and called it OK.
# =========================================================================

dup_required="$WORK/dup-required.md"
{ "$NG" dashboard scaffold; printf '\n## Infra\nCONTRADICTORY SECOND COPY\n'; } > "$dup_required" 2>/dev/null

echo '=== #1058 validate FAILS on a duplicated required section, naming its lines ==='
run_ng out err rc dashboard validate --body-file "$dup_required"
assert_eq        "#1058 exit 1"                                         "$rc" "1"
assert_contains  "#1058 stderr says DUPLICATED"                         "$err" "DUPLICATED"
assert_contains  "#1058 stderr names the duplicated heading"            "$err" "## Infra"
assert_not_contains "#1058 THE PROPERTY: it no longer reports a bare OK" "$out" "OK (all"

echo '=== #1058 CONTROL: the same body with ONE ## Infra still validates OK ==='
single_required="$WORK/single-required.md"
"$NG" dashboard scaffold > "$single_required" 2>/dev/null
run_ng out err rc dashboard validate --body-file "$single_required"
assert_eq        "#1058 CONTROL exit 0"                                 "$rc" "0"
assert_contains  "#1058 CONTROL says OK"                                "$out" "OK (all"

echo '=== #1058 a near-miss heading is NAMED, not silently reported as missing ==='
# `## 🛑 Infra — …` is that section by intent and invisible to `grep -Fx`. A
# bare "missing" verdict sends the operator to add a section already present.
nearmiss="$WORK/nearmiss.md"
sed 's/^## Infra$/## 🛑 Infra — LIVE HAZARD/' "$single_required" > "$nearmiss"
run_ng out err rc dashboard validate --body-file "$nearmiss"
assert_eq        "#1058 near-miss still exit 1 (the anchor genuinely misses)" "$rc" "1"
assert_contains  "#1058 near-miss is reported as such"                  "$err" "NEAR MISS"
assert_contains  "#1058 near-miss names the line it found"              "$err" "LIVE HAZARD"

echo '=== #1058 the REPORTED instance: two same-named sections differing after the separator ==='
# This is the shape #1058 actually hit. It is NOT failed — failing it would
# also fail a legitimate `## Notes: infra` / `## Notes: services` pair — but
# the verdict must stop being an unqualified OK.
board_dup="$WORK/board-dup.md"
{ cat "$single_required"; printf '\n## Board — QUIESCED. Every PR merged.\n\n## Board — 3 workers active\n'; } > "$board_dup"
run_ng out err rc dashboard validate --body-file "$board_dup"
assert_eq        "#1058 reported-instance rc stays 0 (documented contract)"   "$rc" "0"
assert_contains  "#1058 reported-instance is REPORTED on stderr"        "$err" "differ in text but name"
assert_contains  "#1058 THE PROPERTY: the verdict disclaims itself"     "$out" "NOT an unqualified pass"
assert_contains  "#1058 verdict carries a size/section count"           "$err" "top-level sections"

echo '=== #1058 put WARNS on duplicates but never blocks the push ==='
rm -rf "$WORK/state"
MOCK_BODY_FILE="$live_body" run_ng out err rc dashboard put --body-file "$dup_required"
assert_eq        "#1058 put still exits 0 — warn, never block"          "$rc" "0"
assert_contains  "#1058 put warns about the duplicate"                  "$err" "duplicated section heading"
assert_contains  "#1058 put pushed anyway"                              "$(<"$CAPTURE")" "-X PATCH"

# =========================================================================
# your-org/nexus-code#958 — validate read stdin and blamed the dashboard.
# =========================================================================

echo '=== #958 validate with no --body-file consults the LIVE dashboard, not stdin ==='
rm -rf "$WORK/state"
run_ng out err rc dashboard validate
# THE PROPERTY: it went and looked. The canned live middle has no schema
# sections, so rc 1 is correct here — what must never happen again is a
# verdict about the dashboard derived from an empty pipe.
assert_contains  "#958 THE PROPERTY: a GET was issued for the live body" \
                 "$(<"$CAPTURE")" "/repos/default-org/default-repo/issues/37"
assert_not_contains "#958 THE PROPERTY: it does NOT blame the dashboard for empty stdin" \
                 "$err" "empty dashboard body"

echo '=== #958 CONTROL: with --body-file it does NOT go to the network ==='
run_ng out err rc dashboard validate --body-file "$single_required"
assert_eq        "#958 CONTROL exit 0"                                  "$rc" "0"
assert_not_contains "#958 CONTROL: no live fetch when a body was supplied" \
                 "$(<"$CAPTURE")" "-X"
assert_not_contains "#958 CONTROL: no issue GET when a body was supplied" \
                 "$(<"$CAPTURE")" "issues/37"

echo '=== #958 --body-file - reads stdin — the spelling the docs already promised ==='
# Measured at 7c4ddbb: this died `body file not found: -` while
# docs/reference/ng-cli.md showed it as the worked example.
out_dash=$( ( cd "$NEUTRAL_CWD" && run_hermetic NEXUS_STATE_DIR="$WORK/state" PATH="$STUB_DIR:$PATH" \
              -- "$NG" dashboard validate --body-file - ) < "$single_required" 2>&1 )
rc_dash=$?
assert_eq        "#958 --body-file - exit 0"                            "$rc_dash" "0"
assert_not_contains "#958 --body-file - is not a missing FILE"          "$out_dash" "body file not found"

echo '=== #958 an empty --body-file names the INPUT, never the subject ==='
: > "$WORK/empty-validate.md"
run_ng out err rc dashboard validate --body-file "$WORK/empty-validate.md"
assert_eq        "#958 exit 1"                                          "$rc" "1"
assert_contains  "#958 the diagnostic names the file it was handed"     "$err" "--body-file"
assert_not_contains "#958 THE PROPERTY: it does not call the dashboard empty" \
                 "$err" "empty dashboard body"

# =========================================================================
# THE UNIFYING DEFECT — presence is not uniqueness, at every entry point.
#
# Measured by the operator on the live overview, 2026-08-28: a FULL BODY OF
# 198,236 BYTES — 64 KB UNDER the 262,144 cap — silently no-oped through two
# consecutive puts (rc 0, URL printed, stderr empty, body byte-identical,
# planted marker never present). The body carried TWO `NEXUS_DASHBOARD_END`
# markers, one ~120 blank lines after the real one. Removing the duplicate
# made the very next put land. A direct `gh api -X PATCH -F body=@file` at
# 198,264 bytes landed, so neither the size nor the API was at fault.
#
# `cmd_dashboard_put`'s precondition asserted the markers were PRESENT and
# never that they were UNIQUE — which is verbatim what #1058 says about
# `validate`. One sentence, three surfaces. These tests pin it on all three.
# =========================================================================

# The reported shape, exactly: one START, two ENDs, the second far below.
two_end_live="$WORK/two-end-live.md"
{ printf 'prefix line\n<!-- NEXUS_DASHBOARD_START -->\nreal dashboard content\n<!-- NEXUS_DASHBOARD_END -->\n'
  awk 'BEGIN{for(i=0;i<120;i++) print ""}'
  printf '<!-- NEXUS_DASHBOARD_END -->\nsuffix line\n'; } > "$two_end_live"

echo '=== UNIFYING: put REFUSES a live body with two END markers (the reported shape) ==='
rm -rf "$WORK/state"
MOCK_BODY_FILE="$two_end_live" run_ng out err rc dashboard put --body-file "$changed_mid"
assert_eq        "two-END put exit 1"                                   "$rc" "1"
assert_contains  "two-END put names the END count"                      "$err" "2 END marker(s)"
assert_contains  "two-END put names the marker LINES, not just a count" "$err" "END   @ line"
assert_not_contains "THE PROPERTY: it refuses BEFORE the PATCH"         "$(<"$CAPTURE")" "-X PATCH"
assert_no_file   "THE PROPERTY: no freshness stamp for a refused put"   "$WORK/state/dashboard-updated.ts"

echo '=== UNIFYING CONTROL: the same body with ONE END goes through ==='
# Size, content and command held constant; the duplicate END is the only
# variable. Without this the refusal is indistinguishable from a broken verb.
one_end_live="$WORK/one-end-live.md"
python3 - "$two_end_live" "$one_end_live" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split("\n")
seen = False; out = []
for l in lines:
    if l == "<!-- NEXUS_DASHBOARD_END -->":
        if seen:
            continue
        seen = True
    out.append(l)
open(dst, "w").write("\n".join(out))
PYEOF
rm -rf "$WORK/state"
MOCK_BODY_FILE="$one_end_live" run_ng out err rc dashboard put --body-file "$changed_mid"
assert_eq        "one-END CONTROL exit 0"                               "$rc" "0"
assert_contains  "one-END CONTROL: the PATCH WAS issued"                "$(<"$CAPTURE")" "-X PATCH"
assert_file_exists "one-END CONTROL: stamped"                           "$WORK/state/dashboard-updated.ts"

echo '=== UNIFYING: get refuses the same body — it is what hands you the loaded gun ==='
# #959 compounds one round-trip away: `get` produces what `put` consumes, so
# a `get` that returns a corrupt region arms the next edit-and-put cycle.
rm -rf "$WORK/state"
MOCK_BODY_FILE="$two_end_live" run_ng out err rc dashboard get
assert_eq        "two-END get exit 1"                                   "$rc" "1"
assert_contains  "two-END get names the marker counts"                  "$err" "2 END marker(s)"
assert_no_file   "THE PROPERTY: a refused get caches nothing"           "$WORK/state/dashboard.md"

echo '=== UNIFYING CONTROL: get on a one-END body still returns the region ==='
rm -rf "$WORK/state"
MOCK_BODY_FILE="$one_end_live" run_ng out err rc dashboard get
assert_eq        "one-END get CONTROL exit 0"                           "$rc" "0"
assert_contains  "one-END get CONTROL returns the region"               "$out" "real dashboard content"
assert_file_exists "one-END get CONTROL caches"                         "$WORK/state/dashboard.md"

echo '=== UNIFYING: validate (live, no flags) refuses the same body ==='
rm -rf "$WORK/state"
MOCK_BODY_FILE="$two_end_live" run_ng out err rc dashboard validate
assert_eq        "two-END validate(live) exit 1"                        "$rc" "1"
assert_contains  "two-END validate(live) names the marker counts"       "$err" "2 END marker(s)"

echo '=== UNIFYING: validate --body-file on a WHOLE body applies the same predicate ==='
run_ng out err rc dashboard validate --body-file "$two_end_live"
assert_eq        "two-END validate(file) exit 1"                        "$rc" "1"
assert_contains  "two-END validate(file) names the marker counts"       "$err" "2 END marker(s)"

# =========================================================================
# The permanently-wrong warning: `## Identity` legitimately lives OUTSIDE the
# region, and the section check ran against the region alone.
# =========================================================================

echo '=== put does NOT warn about ## Identity when it sits OUTSIDE the markers ==='
# The scaffold's `## Identity` entry is a POINTER; the generated block sits
# above the START marker. Checking the region alone made this warn on every
# put, forever, about a section three lines above the marker.
ident_outside="$WORK/ident-outside.md"
{ printf '## Identity\nthe generated block lives out here, above the marker\n\n'
  printf '<!-- NEXUS_DASHBOARD_START -->\nplaceholder\n<!-- NEXUS_DASHBOARD_END -->\nsuffix\n'; } > "$ident_outside"
region_no_ident="$WORK/region-no-ident.md"
"$NG" dashboard scaffold 2>/dev/null | grep -v '^## Identity$' > "$region_no_ident"
rm -rf "$WORK/state"
MOCK_BODY_FILE="$ident_outside" run_ng out err rc dashboard put --body-file "$region_no_ident"
assert_eq        "identity-outside put exit 0"                          "$rc" "0"
assert_not_contains "THE PROPERTY: no permanent false warning about ## Identity" \
                 "$err" "## Identity"

echo '=== CONTROL: a section absent from BOTH region and outer body still warns ==='
# Without this, "it stopped warning" is indistinguishable from "the check was
# switched off". The only variable is whether the section exists anywhere.
rm -rf "$WORK/state"
MOCK_BODY_FILE="$one_end_live" run_ng out err rc dashboard put --body-file "$region_no_ident"
assert_eq        "identity-absent CONTROL exit 0 (warn, never block)"   "$rc" "0"
assert_contains  "identity-absent CONTROL: it DOES still warn"          "$err" "## Identity"
assert_contains  "identity-absent CONTROL: warning says BOTH were checked" "$err" "BOTH"

echo '=== validate given only a REGION says what it could not see ==='
run_ng out err rc dashboard validate --body-file "$region_no_ident"
assert_eq        "region-only validate exit 1"                          "$rc" "1"
assert_contains  "region-only validate names its blind spot"            "$err" "only the dashboard REGION was checked"

echo '=== #1118 a payload the encoder could not produce is never SENT ==='
# Added because a mutation SURVIVED here: disabling the producer-rc check
# changed no test outcome, which means the guard was undefended. `jq | api
# --input -` is a pipeline and a pipeline's rc is its LAST command's, so a
# dead producer feeds the PATCH empty stdin — and a body-less PATCH returns
# 200 with the issue unchanged: rc 0, a URL, empty stderr, nothing written.
pib_out=$( ( cd "$NEUTRAL_CWD" && run_hermetic NEXUS_STATE_DIR="$WORK/state" PATH="$STUB_DIR:$PATH" -- \
    bash -c 'source "$1" >/dev/null 2>&1; _patch_issue_body o/r 37 "$2" "probe"' \
    _ "$NG" "$WORK/no-such-body-file.md" ) 2>&1 )
pib_rc=$?
assert_eq        "#1118 encoder failure exits non-zero"                 "$pib_rc" "1"
assert_not_contains "#1118 THE PROPERTY: no URL for a body never sent"  "$pib_out" "https://"
assert_contains  "#1118 encoder failure says nothing was sent"          "$pib_out" "nothing was sent"

echo '=== #1118 CONTROL: a well-formed payload DOES reach the PATCH ==='
: > "$CAPTURE"; : > "$STORE"
pib_ok=$( ( cd "$NEUTRAL_CWD" && run_hermetic NEXUS_STATE_DIR="$WORK/state" PATH="$STUB_DIR:$PATH" \
    MOCK_BODY_CAPTURE_PATH="$BODY_CAPTURE" MOCK_STORE_PATH="$STORE" -- \
    bash -c 'source "$1" >/dev/null 2>&1; _patch_issue_body o/r 37 "$2" "probe"' \
    _ "$NG" "$changed_mid" ) 2>&1 )
pib_ok_rc=$?
assert_eq        "#1118 CONTROL encoder success exits 0"                "$pib_ok_rc" "0"
assert_contains  "#1118 CONTROL prints the URL"                         "$pib_ok" "https://"

echo '=== #1118 GUARD 2: a payload corrupted on OUR side is named as OURS, not as a swallow ==='
# Added because a mutation SURVIVED here: disabling the client-side comparison
# changed no test outcome, so nothing pinned WHICH guard speaks. That matters
# precisely because this PR's error was a guard credited with work it could not
# do — a check must be described by what it actually catches. Here the forge
# echoes AND stores the corrupted bytes (the signature of `jq -Rs` silently
# substituting invalid UTF-8 at rc 0), so the fault is ours and the diagnostic
# must say so rather than blaming the forge for a swallow.
rm -rf "$WORK/state"
MOCK_BODY_FILE="$live_body" MOCK_PATCH_MANGLE=1 \
    run_ng out err rc dashboard put --body-file "$changed_mid"
assert_eq        "#1118 guard2 exit 1"                                  "$rc" "1"
assert_contains  "#1118 guard2 blames OUR side, not the forge"          "$err" "CORRUPTED BEFORE IT LEFT"
assert_not_contains "#1118 guard2 does NOT call it a swallow"           "$err" "THE WRITE DID NOT LAND"
assert_no_file   "#1118 guard2 THE PROPERTY: no freshness stamp"        "$WORK/state/dashboard-updated.ts"


echo '=== B3: the whole-body section search is FENCE-AWARE (a quoted example is not a section) ==='
# The skeptic pass on #1123 measured that `_dashboard_missing_sections` was
# fence-BLIND while `_dashboard_headings` in the same verb was fence-aware, so
# six headings quoted inside a ``` fence in the issue prose satisfied the
# schema. That is worst exactly here, because the whole-body loosening points
# the predicate at the prose where quoted examples live.
b3_region="$WORK/b3-region.md";      printf 'no headings here\n' > "$b3_region"
b3_fenced="$WORK/b3-outer-fenced.md"
b3_fence=$(printf '%s' '```')
{ printf 'prose\n\n%s\n' "$b3_fence"
  for h in Identity Infra Services In-flight "Awaiting operator" "Recent landings"; do printf '## %s\n' "$h"; done
  printf '%s\n' "$b3_fence"; } > "$b3_fenced"
b3_real="$WORK/b3-outer-real.md"
{ for h in Identity Infra Services In-flight "Awaiting operator" "Recent landings"; do printf '## %s\n' "$h"; done; } > "$b3_real"
b3_run() { ( cd "$NEUTRAL_CWD" && run_hermetic NEXUS_STATE_DIR="$WORK/state" PATH="$STUB_DIR:$PATH" -- \
    bash -c 'source "$1" >/dev/null 2>&1; _dashboard_missing_sections "$2" "${3:-}" | wc -l' _ "$NG" "$@" ); }
assert_eq "B3 region alone -> all six missing"                      "$(b3_run "$b3_region")" "6"
assert_eq "B3 THE PROPERTY: headings inside a fence do NOT count"   "$(b3_run "$b3_region" "$b3_fenced")" "6"
assert_eq "B3 CONTROL: real headings in the outer body DO count"    "$(b3_run "$b3_region" "$b3_real")" "0"


# ═══ #1136 — A NETWORK FAULT IS NOT A VERDICT ABOUT THE DASHBOARD ═══════════
#
# `_overview_number`'s `die` fires inside `$( )`, which exits the SUBSHELL and
# cannot abort the caller; `ng` runs `set -uo pipefail` with NO `-e`, so
# `_dashboard_fetch_middle` carried on with an empty number, asked for
# `/repos/R/issues/`, and re-reported the FETCH's failure as `overview #N has
# empty body`. The `2>/dev/null` swallowed the client's own diagnostic and the
# pipeline rc was discarded.
#
# Measured at 989b888: a DNS failure and a genuinely empty body printed the
# BYTE-IDENTICAL line. That is `#958`'s shape one layer out — the failure to
# LOOK and the FINDING rendered the same. Asserted here as "the two states
# differ", not as "the wording is X", because the defect IS the collision.
_d1136="$WORK/d1136"; mkdir -p "$_d1136/bin"
cat > "$_d1136/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "${GH_FAULT:-}" == "net" ]]; then
  echo "error connecting to api.github.com: lookup api.github.com: no such host" >&2
  exit 1
fi
printf '{"body":""}\n'
GHEOF
chmod +x "$_d1136/bin/gh"
_d1136_run() {   # _d1136_run <fault>
    ( cd "$NEUTRAL_CWD" && GH_FAULT="$1" GH_TOKEN=stub PATH="$_d1136/bin:$PATH" \
        timeout 60 bash -c '
            source "$1" >/dev/null 2>&1
            REPO=owner/repo
            _overview_number() { printf 37; }
            _dashboard_fetch_middle "$(mktemp)" 2>&1
        ' _ "$NG" ) 2>&1
}
_d1136_net=$(_d1136_run net)
_d1136_empty=$(_d1136_run "")
# POSITIVE CONTROL: both arms actually reached the function and refused. Without
# this, "the two differ" passes on two different flavours of nothing.
assert_contains "#1136 POSITIVE CONTROL: the network arm produced a diagnostic" \
    "$_d1136_net" "ng:"
assert_contains "#1136 POSITIVE CONTROL: the empty-body arm produced a diagnostic" \
    "$_d1136_empty" "ng:"
# THE PROPERTY.
assert_eq "#1136 THE PROPERTY: a fetch failure and an empty body do NOT render alike" \
    "$( [[ "$_d1136_net" == "$_d1136_empty" ]] && echo IDENTICAL || echo distinct)" "distinct"
assert_contains "#1136 the fetch failure names the FETCH, not the dashboard" \
    "$_d1136_net" "FETCH FAILED"
assert_not_contains "#1136 …and does not blame the body it never read" \
    "$_d1136_net" "has empty body"
# The client's own words are the operator's only route to the real cause, and
# `2>/dev/null` was throwing them away.
assert_contains "#1136 …and RELAYS the client's own diagnostic" \
    "$_d1136_net" "api.github.com"
# CONTROL: a real empty body is still reported as one — the fix must not turn
# every refusal into "network".
assert_contains "#1136 CONTROL: a genuinely empty body is still called that" \
    "$_d1136_empty" "has empty body"


# ---- summary ------------------------------------------------------------

th_summary_and_exit
