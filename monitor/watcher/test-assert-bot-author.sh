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
    if grep -qF -- "$needle" <<<"$hay"; then
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

echo '=== the injected worker floor tells the truth (#497) ==='
floor=$(awk '/^## Worker floor$/{f=1;next} /^## /{f=0} f' "$FLOOR")
assert_contains "floor instructs explicit minting" "$floor" 'mint-token.sh'
assert_contains "floor names the one-command verification" "$floor" 'assert-bot-author.sh'
assert_eq "floor no longer claims bare gh is automatically the bot" \
    "$(grep -c 'post as the bot automatically' <<<"$floor")" "0"
assert_contains "floor pip rule covers python -m pip" "$floor" 'python -m pip'

# --- summary -----------------------------------------------------------------

echo
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "FAILED"
exit 1
