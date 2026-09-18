#!/usr/bin/env bash
# monitor/assert-bot-author.sh — the generic "any [bot] account" check is
# OPT-IN (your-org/nexus-code#1307).
#
# WHAT IS AT RISK. This script is the workspace's ONLY loud check that a
# GitHub write posted as the bot. An operator-authored write SUCCEEDS and
# GitHub mutes the operator's own notification, so a missed one does not
# error — the thread simply goes dark (#497). A silent fail-OPEN here is
# therefore on the one surface that must fail loud.
#
# THE DEFECT. `config/load.sh` cannot distinguish a key that is genuinely
# ABSENT from one that is MISTYPED: `bot_logn:` and no `bot_login:` at all
# are the SAME rc 2, the same empty stdout, the same empty diagnostic
# shape. `#1267` made the reader's EXIT CODE decide — right, and it closed
# rc 1 / rc 3 / rc anything-else — but it left rc 2 LICENSING the
# permissive "any [bot] account" arm. Measured at 5bd6d400, author held
# constant at `some-other-app[bot]` and ONLY the config varying:
#
#     bot_login: your-org-bot   -> FAIL, exit 1   (correct)
#     (no bot_login at all)           -> OK,   exit 0   (the documented arm)
#     bot_logn:  your-org-bot   -> OK,   exit 0   ** one character **
#
# The last two lines are BYTE-IDENTICAL. One transposed character in a
# config selected the permissive mode, and a write authored by a DIFFERENT
# GitHub App printed OK at rc 0.
#
# THE CLASS, and why the fix is shaped this way. "An optional-but-load-
# bearing key's ABSENCE silently selects a permissive mode." No logic
# inside this script can tell a typo from an absence — that information is
# not in the data, so a smarter detector would be fixing the demonstrated
# repro rather than the class. The permissive mode is instead made
# unreachable by ACCIDENT: it requires a POSITIVE declaration,
# `github.bot_login_absent_ok: true`. Anything else refuses.
#
# THE POLARITY IS THE POINT, and D3 is the assertion that pins it: a TYPO
# IN THE OPT-IN KEY makes this check STRICTER, never looser. A fix for a
# fail-open that could itself fail open on a typo would be the same defect
# one level up.
#
# Hermetic: `gh` is a PATH-shadow stub answering a canned author from an
# env var; mint-token.sh is stubbed via MINT_TOKEN_BIN; config comes from
# NEXUS_CONFIG temp yaml. Section F uses a MIRRORED ROOT with a stub
# `config/load.sh`, because rcs the real reader emits only when pyyaml is
# missing (3) or the reader is unexecutable (127) cannot be staged
# hermetically any other way.
#
# Run: bash monitor/watcher/test-assert-bot-author-generic-optin.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK="$_test_dir/../assert-bot-author.sh"
LOAD="$_test_dir/../../config/load.sh"

[[ -x "$CHECK" ]] || { echo "FAIL: monitor/assert-bot-author.sh missing/not executable" >&2; exit 1; }

WORK=$(mktemp -d -t nexus-botauthor-optin-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

printf '#!/bin/bash\necho fake-token\n' > "$WORK/mint-ok.sh"; chmod +x "$WORK/mint-ok.sh"
STUB="$WORK/stub-bin"; mkdir -p "$STUB"
printf '#!/bin/bash\nprintf "%%s\\n" "${STUB_AUTHOR:-}"\n' > "$STUB/gh"; chmod +x "$STUB/gh"

cfg() { cat > "$WORK/$1.yml"; }
cfg good        <<'EOF'
github:
  user_login: the-operator
  bot_login: testbot
EOF
cfg absent      <<'EOF'
github:
  user_login: the-operator
EOF
cfg typo        <<'EOF'
github:
  user_login: the-operator
  bot_logn: testbot
EOF
cfg declared    <<'EOF'
github:
  user_login: the-operator
  bot_login_absent_ok: true
EOF
cfg declared_false <<'EOF'
github:
  user_login: the-operator
  bot_login_absent_ok: false
EOF
cfg declared_typo  <<'EOF'
github:
  user_login: the-operator
  bot_login_absent_okk: true
EOF
cfg declared_True  <<'EOF'
github:
  user_login: the-operator
  bot_login_absent_ok: "True"
EOF
# UNQUOTED YAML booleans. D5 tests the QUOTED "True", which is a YAML STRING and
# genuinely refuses — so it asserts the documented member and is BLIND to the
# non-member. Measured against the real reader: nine spellings normalise to
# `true` and are ACCEPTED (#1307 skeptic F1). These fixtures pin that, so the
# header can no longer claim "one accepted spelling" without a red.
cfg declared_bareTrue <<'EOF'
github:
  user_login: the-operator
  bot_login_absent_ok: True
EOF
cfg declared_yes <<'EOF'
github:
  user_login: the-operator
  bot_login_absent_ok: yes
EOF
cfg declared_y <<'EOF'
github:
  user_login: the-operator
  bot_login_absent_ok: y
EOF
# THE F2 SHAPE: the opt-in DECLARED and `bot_login` MISSPELLED. Before the
# near-miss guard this printed OK at rc 0 for a DIFFERENT App — the unmodified
# #1307 failure, reachable by accident, with the typo in the OTHER key.
cfg declared_nearmiss <<'EOF'
github:
  user_login: the-operator
  bot_logn: testbot
  bot_login_absent_ok: true
EOF
cfg declared_farmiss <<'EOF'
github:
  user_login: the-operator
  bto_login: testbot
  bot_login_absent_ok: true
EOF
cfg declared_empty <<'EOF'
github:
  user_login: the-operator
  bot_login_absent_ok: ""
EOF
# The declaration must not be able to WEAKEN a configured bot_login.
cfg good_declared <<'EOF'
github:
  user_login: the-operator
  bot_login: testbot
  bot_login_absent_ok: true
EOF

run() {   # run <cfg-name> <author>; sets OUT/RC
    OUT=$(PATH="$STUB:/usr/bin:/bin" NEXUS_CONFIG="$WORK/$1.yml" \
          MINT_TOKEN_BIN="$WORK/mint-ok.sh" STUB_AUTHOR="$2" \
          bash "$CHECK" 'repos/your-org/x/issues/1' 2>&1)
    RC=$?
}
rc_of() { run "$1" "$2"; printf '%s' "$RC"; }

# ── A. PRECONDITION: the two configs really are indistinguishable to the reader
# Without this, every assertion below is consistent with a fixture that simply
# never reached the branch under test. Establish the rcs FIRST, and prove the
# instrument can see a PRESENCE before any absence is believed.
echo '=== A. PRECONDITION — load.sh cannot tell a typo from an absence ==='
_rc_good=0;   NEXUS_CONFIG="$WORK/good.yml"   "$LOAD" github.bot_login >/dev/null 2>&1; _rc_good=$?
_rc_absent=0; NEXUS_CONFIG="$WORK/absent.yml" "$LOAD" github.bot_login >/dev/null 2>&1; _rc_absent=$?
_rc_typo=0;   NEXUS_CONFIG="$WORK/typo.yml"   "$LOAD" github.bot_login >/dev/null 2>&1; _rc_typo=$?
assert_eq "A1 POSITIVE CONTROL: a CONFIGURED bot_login reads rc 0 (the reader works)" "$_rc_good" "0"
assert_eq "A2 genuine ABSENCE reads rc 2"                                             "$_rc_absent" "2"
assert_eq "A3 a MISTYPED key reads rc 2 TOO — same rc, so no logic here can tell them apart" \
    "$_rc_typo" "2"
# #1267's arm must stay DISTINCT from #1307's, in both directions: a reader
# FAILURE is not an absence, and an absence is not a reader failure. Asserted
# behaviourally — a grep for the comment that documents it would pass against
# code that had stopped doing it.
printf 'github: [a, b\n  bot_login: "unclosed\n' > "$WORK/malformed.yml"
_rc_mal=0; NEXUS_CONFIG="$WORK/malformed.yml" "$LOAD" github.bot_login >/dev/null 2>&1; _rc_mal=$?
assert_eq "A4 PRECONDITION: the malformed config really fails the reader (rc 1, NOT rc 2 'absent')" \
    "$_rc_mal" "1"
OUT=$(PATH="$STUB:/usr/bin:/bin" NEXUS_CONFIG="$WORK/malformed.yml" \
      MINT_TOKEN_BIN="$WORK/mint-ok.sh" STUB_AUTHOR='some-other-app[bot]' \
      bash "$CHECK" 'repos/your-org/x/issues/1' 2>&1); RC=$?
assert_eq       "A5 a reader FAILURE is still #1267's refusal (exit 2)" "$RC" "2"
assert_contains "A6 …and still carries #1267's wording, not #1307's — the two arms stay distinct" \
    "$OUT" "REFUSING to fall back"

# ── B. LIVE CONTROL: the configured path is untouched
echo '=== B. LIVE CONTROL — the configured-bot path still discriminates ==='
assert_eq "B1 configured bot matches -> exit 0"        "$(rc_of good 'testbot[bot]')"        "0"
assert_eq "B2 configured bot vs another App -> exit 1" "$(rc_of good 'some-other-app[bot]')" "1"
run good_declared 'some-other-app[bot]'
assert_eq "B3 the DECLARATION cannot weaken a configured bot_login (still exit 1)" "$RC" "1"
run good_declared 'testbot[bot]'
assert_eq "B4 …and cannot break it either (still exit 0)" "$RC" "0"

# ── C. THE FINDING: the permissive PASS is no longer reachable by accident
echo '=== C. #1307 — an UNDECLARED generic pass is REFUSED, exit 2 ==='
run typo 'some-other-app[bot]'
assert_eq       "C1 MISTYPED bot_login + another App -> exit 2 (was exit 0 + OK)" "$RC" "2"
assert_eq       "C2 …and NEVER prints an OK line" "$(grep -c 'OK — authored by' <<<"$OUT")" "0"
assert_contains "C3 …and says the generic check is OPT-IN"        "$OUT" "is OPT-IN"
assert_contains "C4 …and names the declaration that would enable it" \
    "$OUT" "bot_login_absent_ok: true"
assert_contains "C5 …and NAMES THE MISSPELLED KEY, so the likelier cause is visible here" \
    "$OUT" "github.bot_logn"
run absent 'some-other-app[bot]'
assert_eq "C6 genuine ABSENCE with no declaration -> exit 2 as well (same fact, same answer)" \
    "$RC" "2"
# C7 EXISTS BECAUSE A MUTANT SURVIVED WITHOUT IT. Changing the `_optin_rc != 0`
# arm to a never-taken constant killed nothing: `_cfg_read` maps every reader
# failure to 3, so rc 2 is the only other non-zero, and rc 2 always carries an
# EMPTY value — which the value check below it already refuses. The arm is
# therefore behaviourally shadowed and only its DIAGNOSTIC distinguishes it, so
# the diagnostic is what has to be pinned. An operator whose key is simply
# missing must be told THAT, not "the value '' is not 'true'", which sends them
# looking for a value they never wrote.
assert_contains "C7 …and says the key is NOT SET, rather than complaining about an empty VALUE" \
    "$OUT" "bot_login_absent_ok is not set"

# ── D. The declaration works, and its own failure direction is CLOSED
echo '=== D. the older-fork fallback survives — but only when DECLARED ==='
run declared 'some-other-app[bot]'
assert_eq       "D1 declared true -> the generic [bot] check runs and passes" "$RC" "0"
assert_contains "D2 …and says which check it ran"  "$OUT" "generic [bot] check"
assert_eq "D3 POLARITY: a TYPO in the OPT-IN key refuses (stricter, never looser)" \
    "$(rc_of declared_typo 'some-other-app[bot]')" "2"
assert_eq "D4 an explicit false refuses"      "$(rc_of declared_false 'some-other-app[bot]')" "2"
assert_eq "D5 'True' is not 'true' — refuses" "$(rc_of declared_True  'some-other-app[bot]')" "2"
assert_eq "D6 present-but-empty refuses"      "$(rc_of declared_empty 'some-other-app[bot]')" "2"
run declared_True 'some-other-app[bot]'
assert_contains "D7 …and the REJECTED VALUE is named, so a wrong spelling is diagnosable" \
    "$OUT" "is 'True'"

# D8-D10 — WHAT THE VALUE CHECK ACTUALLY PINS. D5 above tests the QUOTED "True"
# and is blind to the UNQUOTED one; the reader normalises YAML 1.1 booleans and
# stringifies them lowercase, so `True` and `yes` arrive as `true` and PASS.
# Asserting that keeps the header honest: the load-bearing property is that a
# POSITIVE declaration is required, NOT that one spelling is.
assert_eq "D8 unquoted YAML True normalises to true and is ACCEPTED (not one spelling)" \
    "$(rc_of declared_bareTrue 'some-other-app[bot]')" "0"
assert_eq "D9 unquoted YAML yes likewise ACCEPTED" \
    "$(rc_of declared_yes 'some-other-app[bot]')" "0"
assert_eq "D10 CONTROL — a NON-boolean (y) does NOT normalise and refuses" \
    "$(rc_of declared_y 'some-other-app[bot]')" "2"

# D11-D13 — THE NEAR-MISS GUARD (#1307 skeptic F2). The permissive arm is
# reachable by accident in exactly one shape: opt-in DECLARED plus a MISSPELLED
# bot_login. The guard fires on a misspelling that preserves the `bot_log` stem,
# NAMES it, and — D13 — the honest bound: one that destroys the stem is still
# indistinguishable from absence, which is why #1307 remedies 2 and 3 stay open.
assert_eq "D11 opt-in DECLARED + a near-miss bot_logn REFUSES (was rc 0 OK)" \
    "$(rc_of declared_nearmiss 'some-other-app[bot]')" "2"
run declared_nearmiss 'some-other-app[bot]'
assert_contains "D12 …and the near-miss KEY is named" "$OUT" "github.bot_logn"
assert_eq "D13 DECLARED BOUND — a stem-destroying typo (bto_login) is NOT caught, and passes" \
    "$(rc_of declared_farmiss 'some-other-app[bot]')" "0"

# ── E. Every FAIL stays a FAIL — the gate sits on the PASS and nowhere else
echo '=== E. no definite FAIL is downgraded to "unverified" ==='
run typo 'the-operator'
assert_eq       "E1 operator-authored + mistyped config -> STILL exit 1, not 2" "$RC" "1"
assert_contains "E2 …and still carries the muting diagnosis"  "$OUT" "NEVER notify"
run absent 'the-operator'
assert_eq "E3 operator-authored + genuinely absent, undeclared -> STILL exit 1" "$RC" "1"
assert_eq "E4 a plain HUMAN author is a definite FAIL, never a refusal" \
    "$(rc_of typo 'random-dev')" "1"
assert_eq "E5 …and the same under a genuine absence" "$(rc_of absent 'random-dev')" "1"

# ── F. Classification is by the reader's RC over the WHOLE rc space
# A mirrored root with a STUB config/load.sh: `$_root` is derived from the
# script's own location, so a COPY under $FAKEROOT/monitor consults
# $FAKEROOT/config/load.sh and an arbitrary rc can be produced.
echo '=== F. the OPT-IN read is classified by RC, including rcs a real reader rarely emits ==='
FAKEROOT="$WORK/fakeroot"; mkdir -p "$FAKEROOT/monitor" "$FAKEROOT/config"
cp "$CHECK" "$FAKEROOT/monitor/assert-bot-author.sh"
cat > "$FAKEROOT/config/load.sh" <<'EOF'
#!/bin/bash
case "$1" in
  github.bot_login)            printf '%s\n' "${STUB_BOT_OUT:-}";   exit "${STUB_BOT_RC:-2}" ;;
  github.user_login)           printf '%s\n' "${STUB_OP_OUT:-}";    exit "${STUB_OP_RC:-0}" ;;
  github.bot_login_absent_ok)  printf '%s\n' "${STUB_OPTIN_OUT:-}"; exit "${STUB_OPTIN_RC:-2}" ;;
  --dump)                      exit "${STUB_DUMP_RC:-0}" ;;
esac
exit 2
EOF
chmod +x "$FAKEROOT/config/load.sh"

run_fake() {   # run_fake <optin_rc> <optin_out> <author>
    OUT=$(PATH="$STUB:/usr/bin:/bin" MINT_TOKEN_BIN="$WORK/mint-ok.sh" \
          STUB_BOT_RC=2 STUB_OP_RC=0 STUB_OP_OUT='the-operator' \
          STUB_OPTIN_RC="$1" STUB_OPTIN_OUT="$2" STUB_AUTHOR="$3" \
          bash "$FAKEROOT/monitor/assert-bot-author.sh" 'repos/your-org/x/issues/1' 2>&1)
    RC=$?
}
# LIVE CONTROL FIRST. Without it every refusal below is equally consistent with
# a mirrored root that simply cannot run at all — an inert fixture and a real
# one print the same refusal.
run_fake 0 'true' 'some-other-app[bot]'
assert_eq "F1 LIVE CONTROL: the mirrored root reaches its stub reader and PASSES a real declaration" \
    "$RC" "0"
run_fake 3 '' 'some-other-app[bot]'
assert_eq "F2 opt-in read rc 3 (pyyaml missing) -> exit 2, not a relaxed pass" "$RC" "2"
run_fake 127 '' 'some-other-app[bot]'
assert_eq "F3 opt-in read rc 127 (no such reader) -> exit 2" "$RC" "2"
run_fake 1 '' 'some-other-app[bot]'
assert_eq "F4 opt-in read rc 1 (unreadable config) -> exit 2" "$RC" "2"
run_fake 0 'true' 'the-operator'
assert_eq "F5 …and even a VALID declaration cannot pass an operator-authored write" "$RC" "1"

# ── the assertion COUNT, compared EXACTLY (your-org/nexus-code#821 axis B) ──
# A suite can lose assertions silently — an arm that stops running still
# reports a clean green, and a FLOOR does not catch that. Bump this number
# deliberately when adding an arm; a mismatch is a red, not a warning.
EXPECTED_ASSERTIONS=40
_run_total=$(( PASS + FAIL ))
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
