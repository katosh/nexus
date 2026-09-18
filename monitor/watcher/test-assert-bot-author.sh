#!/usr/bin/env bash
# Tests for monitor/assert-bot-author.sh (the one-command write-identity
# check) and for the worker floor's identity instruction being truthful
# (your-org/nexus-code#497).
#
# #497: the auto-injected worker floor claimed a bare `gh <write>` posts
# as the bot via the PATH-front shim; on the live main clone that was
# false, and five operator-authored writes in one day silently failed to
# notify the operator (GitHub mutes self-notifications). The durable fix
# is (a) the floor instructs EXPLICIT minting unconditionally, and (b) a
# worker can assert the identity of its own write in one command — which
# holds whether or not the shim works and fails loud when it regresses.
#
# Hermetic: `gh` is a PATH-shadow stub answering canned author JSON keyed
# on an env var and capturing the endpoint it was asked for;
# mint-token.sh is stubbed via MINT_TOKEN_BIN; config comes from a
# NEXUS_CONFIG temp yaml.
#
# Run: bash monitor/watcher/test-assert-bot-author.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK="$_test_dir/../assert-bot-author.sh"
FLOOR="$_test_dir/../../skills/nexus.worker-defaults/SKILL.md"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

[[ -x "$CHECK" ]] || { echo "FAIL: monitor/assert-bot-author.sh missing/not executable (#497)" >&2; echo FAILED; exit 1; }

WORK=$(mktemp -d -t nexus-botauthor-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Config: a bot and an operator.
cat > "$WORK/nexus.yml" <<'EOF'
github:
  user_login: the-operator
  bot_login: testbot
EOF

# Token minter stub.
printf '#!/bin/bash\necho fake-token\n' > "$WORK/mint-ok.sh"
printf '#!/bin/bash\nexit 1\n'          > "$WORK/mint-fail.sh"
chmod +x "$WORK/mint-ok.sh" "$WORK/mint-fail.sh"

# gh stub: answers `gh api <endpoint> --jq …` with an author from
# $STUB_AUTHOR and records the endpoint.
STUB="$WORK/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$2" >> "$WORK/endpoints.log"
printf '%s\n' "\${STUB_AUTHOR:-}"
EOF
chmod +x "$STUB/gh"

run_check() {  # run_check <author> <url> [mint]
    local author="$1" url="$2" mint="${3:-$WORK/mint-ok.sh}"
    OUT=$(PATH="$STUB:/usr/bin:/bin" NEXUS_CONFIG="$WORK/nexus.yml" \
          MINT_TOKEN_BIN="$mint" STUB_AUTHOR="$author" \
          bash "$CHECK" "$url" 2>&1)
    RC=$?
}

echo '=== bot-authored write passes ==='
run_check 'testbot[bot]' 'https://github.com/your-org/x/issues/42#issuecomment-777'
assert_eq       "bot author -> exit 0"            "$RC" "0"
assert_contains "names the author"                "$OUT" "testbot[bot]"
assert_eq       "comment URL mapped to the comments endpoint" \
    "$(tail -1 "$WORK/endpoints.log")" "repos/your-org/x/issues/comments/777"

echo '=== operator-authored write fails loud, naming the muting consequence ==='
run_check 'the-operator' 'https://github.com/your-org/x/issues/42#issuecomment-778'
assert_eq       "operator author -> exit 1"       "$RC" "1"
assert_contains "names the wrong author"          "$OUT" "the-operator"
assert_contains "explains the muted notification" "$OUT" "NEVER notify"
assert_contains "prescribes the minted re-post"   "$OUT" "mint-token.sh"

echo '=== other-human write fails; issue/PR html URLs map to the issues endpoint ==='
run_check 'random-dev' 'https://github.com/your-org/x/pull/9'
assert_eq "other human -> exit 1" "$RC" "1"
assert_eq "PR URL mapped to issues endpoint" \
    "$(tail -1 "$WORK/endpoints.log")" "repos/your-org/x/issues/9"
run_check 'testbot[bot]' 'repos/your-org/x/issues/comments/12'
assert_eq "bare api path accepted" "$RC" "0"

echo '=== unverifiable states are exit 2, never a silent pass ==='
run_check 'testbot[bot]' 'https://example.com/not-github'
assert_eq "unmappable URL -> exit 2" "$RC" "2"
run_check 'testbot[bot]' 'https://github.com/your-org/x/issues/42' "$WORK/mint-fail.sh"
assert_eq "mint failure -> exit 2" "$RC" "2"
assert_contains "mint failure says UNVERIFIED" "$OUT" "UNVERIFIED"
run_check '' 'https://github.com/your-org/x/issues/42'
assert_eq "empty author from API -> exit 2" "$RC" "2"

# =============================================================================
# your-org/nexus-code#1267 — A FAILING CONFIG READER MUST NOT RELAX THE CHECK
# =============================================================================
# This script is the workspace's ONLY loud check that a write posted as the
# bot. It used to read `config/load.sh` as
# `bot=$(… 2>/dev/null || true)` and then branch on `[[ -z "$bot" ]]`, which
# CANNOT distinguish "the key is genuinely absent (older forks)" from "the
# reader FAILED" — and the `2>/dev/null` destroyed the diagnostic that would
# have. On the failing path the check silently degraded to "any `[bot]`
# account" and printed OK. An emptiness test standing in for a validity test.
#
# MEASURED on the pre-fix blob 5aa6715a72390, author held constant at
# `github-actions[bot]`, only the config varying:
#   config intact     -> FAIL, exit 1     (correct)
#   config unreadable -> OK,   exit 0, and ZERO BYTES on stderr
#
# The rc contract these tests rely on, measured against the real
# `config/config.load.sh` reader (see config/load.sh's own header):
#   configured        -> rc 0 + value
#   present-but-empty -> rc 0 + EMPTY      (a THIRD state, neither of the two
#                                           the old code imagined)
#   key absent        -> rc 2
#   malformed/unreadable yaml -> rc 1
# Malformed YAML is used rather than `chmod 000` deliberately: a root CI
# runner reads a mode-000 file and the fixture would go inert, whereas a
# parse error is uid-independent.

# Config fixtures for the four reader states.
# `bot_login_absent_ok` is what an older fork must now DECLARE to keep the
# generic `[bot]` arm (your-org/nexus-code#1307). Before that key existed, a
# MISTYPED `bot_logn:` and a genuinely absent key were the same load.sh rc 2,
# so the typo silently selected the permissive arm. The declaration is the
# discriminator the config reader cannot supply.
cat > "$WORK/cfg-nobot.yml" <<'EOF'
github:
  user_login: the-operator
  bot_login_absent_ok: true
EOF
cat > "$WORK/cfg-emptybot.yml" <<'EOF'
github:
  user_login: the-operator
  bot_login: ""
EOF
cat > "$WORK/cfg-neither.yml" <<'EOF'
github:
  repo: your-org/x
EOF
printf 'github: [a, b\n  bot_login: "unclosed\n' > "$WORK/cfg-malformed.yml"

run_check_cfg() {  # run_check_cfg <cfg-path> <author> <url>
    local cfg="$1" author="$2" url="$3"
    OUT=$(PATH="$STUB:/usr/bin:/bin" NEXUS_CONFIG="$cfg" \
          MINT_TOKEN_BIN="$WORK/mint-ok.sh" STUB_AUTHOR="$author" \
          bash "$CHECK" "$url" 2>&1)
    RC=$?
}

echo '=== #1267: the config reader FAILING is UNVERIFIED (exit 2), never a relaxed pass ==='
# PRECONDITION / POSITIVE CONTROL. If the malformed yaml did not actually make
# the reader fail, every assertion below would pass for the wrong reason — the
# script would simply be reading a fine config. Establish the rc FIRST.
_mal_rc=0
NEXUS_CONFIG="$WORK/cfg-malformed.yml" "$_test_dir/../../config/load.sh" github.bot_login >/dev/null 2>&1
_mal_rc=$?
assert_eq "PRECONDITION: the malformed config really does make load.sh fail (rc 1, not 2 'absent')" \
    "$_mal_rc" "1"

run_check_cfg "$WORK/cfg-malformed.yml" 'other-app[bot]' 'repos/your-org/x/issues/1'
assert_eq       "failing config reader -> exit 2 (was exit 0 + OK)" "$RC" "2"
assert_contains "…and says UNVERIFIED"          "$OUT" "UNVERIFIED"
assert_contains "…and names the refusal to relax to 'any [bot]'" "$OUT" "REFUSING to fall back"
assert_contains "…and surfaces load.sh's own diagnostic (the 2>/dev/null used to eat it)" \
    "$OUT" "config/load.sh said:"
assert_eq       "…and NEVER prints an OK line" \
    "$(grep -c 'OK — authored by' <<<"$OUT")" "0"

echo '=== #1267: a present-but-EMPTY bot_login is indeterminate too, not "absent" ==='
run_check_cfg "$WORK/cfg-emptybot.yml" 'other-app[bot]' 'repos/your-org/x/issues/1'
assert_eq "bot_login present-but-empty -> exit 2" "$RC" "2"
assert_eq "…and NEVER prints an OK line" "$(grep -c 'OK — authored by' <<<"$OUT")" "0"

echo '=== #1267/#1307: the older-fork fallback SURVIVES, but only when DECLARED ==='
run_check_cfg "$WORK/cfg-nobot.yml" 'other-app[bot]' 'repos/your-org/x/issues/1'
assert_eq       "bot_login absent AND bot_login_absent_ok DECLARED -> generic [bot] arm still passes (#1307)" "$RC" "0"
assert_contains "…and says which check it ran"  "$OUT" "generic [bot] check"
run_check_cfg "$WORK/cfg-nobot.yml" 'the-operator' 'repos/your-org/x/issues/1'
assert_eq "…and the fallback still catches the OPERATOR" "$RC" "1"

echo '=== #1267: the fallback needs an operator to exclude; without one it refuses ==='
run_check_cfg "$WORK/cfg-neither.yml" 'other-app[bot]' 'repos/your-org/x/issues/1'
assert_eq       "neither key readable -> exit 2" "$RC" "2"
assert_contains "…and names user_login as the missing discriminator" "$OUT" "github.user_login"

echo '=== #1267: classification is by load.sh RC, over the whole rc space ==='
# A mirrored root with a STUB config/load.sh, so an arbitrary rc can be
# produced — including rcs the real reader emits only under conditions a
# hermetic test cannot stage (pyyaml missing = 3, unexecutable reader = 127).
# `$_root` is derived from the script's own location, so a COPY under
# $FAKEROOT/monitor makes $FAKEROOT/config/load.sh the reader it consults.
FAKEROOT="$WORK/fakeroot"; mkdir -p "$FAKEROOT/monitor" "$FAKEROOT/config"
cp "$CHECK" "$FAKEROOT/monitor/assert-bot-author.sh"
cat > "$FAKEROOT/config/load.sh" <<'EOF'
#!/bin/bash
case "$1" in
  github.bot_login)  printf '%s\n' "${STUB_BOT_OUT:-}"; exit "${STUB_BOT_RC:-0}" ;;
  github.bot_login_absent_ok) printf 'true\n'; exit 0 ;;
  github.user_login) printf '%s\n' "${STUB_OP_OUT:-}";  exit "${STUB_OP_RC:-0}" ;;
esac
exit 2
EOF
chmod +x "$FAKEROOT/config/load.sh"

run_fake() {  # run_fake <bot_rc> <bot_out> <op_rc> <op_out> <author>
    OUT=$(PATH="$STUB:/usr/bin:/bin" MINT_TOKEN_BIN="$WORK/mint-ok.sh" \
          STUB_BOT_RC="$1" STUB_BOT_OUT="$2" STUB_OP_RC="$3" STUB_OP_OUT="$4" \
          STUB_AUTHOR="$5" \
          bash "$FAKEROOT/monitor/assert-bot-author.sh" 'repos/your-org/x/issues/1' 2>&1)
    RC=$?
}

# LIVE CONTROL FIRST. Without it, every refusal below is consistent with a
# mirrored root that simply cannot work at all — an inert fixture and a real
# one print the same refusal.
run_fake 0 'testbot' 0 'the-operator' 'testbot'
assert_eq "LIVE CONTROL: the mirrored root reaches its stub reader and PASSES a real match" "$RC" "0"

run_fake 3 '' 0 'the-operator' 'other-app[bot]'
assert_eq "reader rc 3 (pyyaml missing) -> exit 2, not a relaxed pass" "$RC" "2"
run_fake 127 '' 0 'the-operator' 'other-app[bot]'
assert_eq "reader rc 127 (no such reader) -> exit 2" "$RC" "2"
run_fake 2 '' 1 '' 'other-app[bot]'
assert_eq "bot absent + operator UNREADABLE -> exit 2 (fallback has nothing to exclude)" "$RC" "2"
run_fake 2 '' 0 'the-operator' 'other-app[bot]'
assert_eq "bot absent + operator readable + absence DECLARED -> passes (rc 2 alone no longer licenses it, #1307)" "$RC" "0"

echo '=== the injected worker floor tells the truth (#497) ==='
# THE EXTRACTOR MUST BE spawn-worker.sh'S, BYTE FOR BYTE (your-org/nexus-code#1237 F7).
# This used to read `/^## Worker floor$/{f=1;next} /^## /{f=0} f`, which DISAGREES
# with the one that actually composes a prompt, and it disagreed in the INERT
# direction: `f=0` merely stops printing and KEEPS SCANNING, so a second
# `## Worker floor` heading later in the file re-enables it, while spawn-worker
# `exit`s at the first H2 and never sees that body. Measured on a planted
# fixture: a bullet smuggled under a second heading is found by the old test
# extractor (1) and NOT by spawn-worker's (0) — guard GREEN, fix reaching ZERO
# spawns. It also lacked the `[[:space:]]*` tolerance, so a heading with one
# trailing space made the test blind (safe direction, but a confusing red).
#
# Same shape as `#1238` and the CLAUDE.md suites the same night: a guard
# asserting a block CONTAINS a construct while the PROPERTY goes unchecked.
floor=$(awk '/^## Worker floor[[:space:]]*$/ { in_floor=1; next }
             in_floor && /^## /              { exit }
             in_floor                        { print }' "$FLOOR")
# A non-empty extraction is a PRECONDITION, not a result: every assertion below
# is vacuously satisfiable against an empty string by an assert_not_contains,
# and a silent empty floor is how this guard would go quiet altogether.
assert_eq "the floor section extracted non-empty (assertions below are not vacuous)" \
    "$([[ -n "${floor//[[:space:]]/}" ]] && echo non-empty || echo EMPTY)" "non-empty"
# EXACTLY ONE heading, which removes the divergence case rather than tolerating
# it: with one heading, `exit` and `keep scanning` cannot differ.
_nfloor=$(grep -cE '^## Worker floor[[:space:]]*$' "$FLOOR")
assert_eq "exactly one '## Worker floor' heading — so the extractors CANNOT diverge" \
    "$_nfloor" "1"
# COUPLING GUARD: if spawn-worker's extractor changes, this must be re-synced.
# Without it the two drift apart again silently, which is the whole defect.
_sw="$_test_dir/../spawn-worker.sh"
assert_eq "spawn-worker.sh still uses the extractor this test MIRRORS (re-sync if this reddens)" \
    "$(grep -cF 'in_floor && /^## /              { exit }' "$_sw")" "1"
assert_contains "floor instructs explicit minting" "$floor" 'mint-token.sh'
assert_contains "floor names the one-command verification" "$floor" 'assert-bot-author.sh'
assert_eq "floor no longer claims bare gh is automatically the bot" \
    "$(grep -c 'post as the bot automatically' <<<"$floor")" "0"
assert_contains "floor pip rule covers python -m pip" "$floor" 'python -m pip'
# your-org/nexus-code#1235: the floor documented two escapes for a process you
# cannot kill (`svc.sh`, `proc-kill-authorized`) and NEITHER applies to an
# orphan your own backgrounded tool call left, so an agent following the floor
# exactly reached a dead end on its own orphan. `TaskStop` appeared exactly
# ONCE in this repo and not in the floor. Guarded here so it cannot quietly
# leave again.
assert_contains "floor names the sanctioned stop for a backgrounded orphan" \
    "$floor" 'TaskStop'
assert_contains "…and the marker that tells you the refusal is yours" \
    "$floor" 'NOT-A-SIBLING'

# --- assertion-count guard ---------------------------------------------------
# ADDED BECAUSE ITS ABSENCE HID A REAL BREAKAGE (your-org/nexus-code#1237 F7).
# Three checks were added here calling `pass`/`fail`, which this suite does not
# define and does not inherit — it sources no shared helpers. bash printed
# `pass: command not found` on stderr, the checks did not run, PASS/FAIL were
# untouched, and the suite reported `20 passed, 0 failed / ALL TESTS PASSED`.
# A check that does not run is invisible to a pass/fail summary; only a pinned
# TOTAL makes a truncated run a failure. The two sibling suites this change
# touches both had such a guard, and this one did not — which is why the
# breakage landed here and not there.
_EXPECTED_ASSERTIONS=42
_ran=$(( PASS + FAIL + 1 ))          # + 1 counts this assertion itself
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d. A check that stopped running is invisible to the pass/fail counts; bump this deliberately when adding one.\n' \
        "$_ran" "$_EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi

# --- summary -----------------------------------------------------------------

echo
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "FAILED"
exit 1
