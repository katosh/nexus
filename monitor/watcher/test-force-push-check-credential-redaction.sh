#!/usr/bin/env bash
# monitor/watcher/test-force-push-check-credential-redaction.sh
#
# force-push-check.sh must never PRINT a credential, on either of its two
# output channels. It legitimately RESOLVES an authentic push URL — that is
# your-org/nexus-code#898's fix, and the fetch needs the credentials — but the
# authentic URL must not reach the report.
#
# THE TWO CHANNELS ARE COMPLEMENTARY, which is why one fixture cannot find
# both, and why an earlier probe reported a clean negative:
#
#   A. the script's OWN verdict print  — fires when the remote IS reachable.
#      Introduced by #898: before it, `_url` came straight from git's `To`
#      line, which git ANONYMISES. After it, `_url` is recovered via
#      `git remote get-url --push` and carries userinfo.
#   B. git's stderr, passed through on the REFUSED path — fires when the
#      remote is NOT reachable. Pre-existing and ref-invariant: git does NOT
#      anonymise `fatal: unable to access '<url>'`.
#
# A probe whose fixture had no server could only ever reach B, which is
# identical at every ref — so it measured "both refs leak, via git's fatal"
# and read that as exonerating #898. A probe that cannot reach the path is a
# dead instrument and its negative is not a refutation. Hence the CONTROLs
# below, which assert the classifier was actually reached.
#
# THIS REPO CONFIGURES EXACTLY THE LEAKING SHAPE: monitor/upload-asset.sh sets
# origin to `https://x-access-token:<TOKEN>@github.com/<repo>.git` (line 685),
# a live GitHub App installation token, and force-push-check.sh is wired into
# monitor/bash-footgun-patterns.conf so it runs before pushes and its verdict
# lands in agent context, reports and issue comments.
#
# EVERY POSITIVE ASSERTION IS PAIRED WITH A MUTANT that removes the redaction
# and is asserted to LEAK. Without that, an assertion that the secret is
# absent passes just as well when the fixture never reached the print at all.

set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK="$_test_dir/../force-push-check.sh"

. "$_test_dir/_test_helpers.sh"

for _th in assert_eq assert_rc assert_contains assert_not_contains th_summary_and_exit; do
    declare -F "$_th" >/dev/null 2>&1 || {
        echo "FATAL: assertion helper '$_th' is not defined by _test_helpers.sh." >&2
        exit 1
    }
done

# SYNTHETIC credential. Never a real token.
SECRET='s3cr3tSYNTHETICNOTAREALTOKEN'
CRED_URL="http://alice:${SECRET}@127.0.0.1:1/remote.git"
SAFE_URL="http://127.0.0.1:1/remote.git"

TMP=$(mktemp -d) || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0

# A real repo with a real, credentialed origin — so `git remote get-url --push`
# answers authentically without being stubbed.
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.name Fixture
git -C "$REPO" config user.email fixture@example.invalid
: > "$REPO/f.txt"; git -C "$REPO" add f.txt
git -C "$REPO" commit -qm seed
git -C "$REPO" remote add origin "$CRED_URL"

# ---- stubs: only `push --dry-run --porcelain` is synthetic ------------------
# forge_push <mode>: PATH-front git stub. Everything else forwards to real git.
forge_push() {
    local mode="$1"
    local dir="$TMP/stub.$mode"
    rm -rf "$dir"; mkdir -p "$dir"
    local realgit; realgit=$(command -v git)
    {
      printf '#!/usr/bin/env bash\n'
      printf 'ispush=; porc=\n'
      printf 'for a in "$@"; do [ "$a" = push ] && ispush=1; [ "$a" = --porcelain ] && porc=1; done\n'
      printf 'if [ -n "$ispush" ] && [ -n "$porc" ]; then\n'
      if [ "$mode" = delete ]; then
        # Reachable remote, a ref DELETION: reaches the verdict print with NO
        # fetch, so channel A is exercised without a live server.
        printf '  printf "To %s\\n"\n' "$SAFE_URL"
        printf '  printf -- "-\\trefs/heads/feature:refs/heads/feature\\t[deleted]\\n"\n'
        printf '  printf "Done\\n"; exit 0\n'
      else
        # Unreachable remote: no refs on stdout, git's own fatal on stderr,
        # carrying the credential verbatim. Exercises channel B.
        printf '  printf "fatal: unable to access '"'"'%s/'"'"': Failed to connect\\n" >&2\n' "$CRED_URL"
        printf '  exit 128\n'
      fi
      printf 'fi\n'
      printf 'exec %s "$@"\n' "$realgit"
    } > "$dir/git"
    chmod +x "$dir/git"
    STUBDIR="$dir"
}

# An UNREDACTED copy of the check: the mutant. Reverting the display variable
# to the authentic one restores exactly the defect under test.
MUTANT="$TMP/mutant.sh"
sed -e 's/on ${_url_show}/on ${_url}/g' \
    -e "s/| _redact_userinfo_stream >&2/>\&2/" "$CHECK" > "$MUTANT"

# PROVE THE MUTATION APPLIED. An inert mutant and a real surviving mutant
# produce byte-identical output, so the mutant must be shown to DIFFER.
_mutdiff=$(diff "$CHECK" "$MUTANT" | grep -c '^[<>]')
assert_eq "the mutant genuinely differs from the shipped check" \
    "$( [ "${_mutdiff:-0}" -ge 2 ] && echo differs || echo identical )" differs

echo '--- channel A: the script'"'"'s OWN verdict print (remote REACHABLE) ---'
forge_push delete
cd "$REPO"

outA=$(PATH="$STUBDIR:$PATH" bash "$CHECK" origin feature 2>&1); rcA=$?
assert_rc "a ref deletion is UNSAFE => rc 1" 1 "$rcA"
assert_contains "CONTROL: the classifier was REACHED (the DELETE line printed)" \
    "$outA" "DELETE"
assert_not_contains "named remote: the verdict does NOT print the credential" \
    "$outA" "$SECRET"
assert_contains "named remote: it still names the destination, anonymised" \
    "$outA" "127.0.0.1:1/remote.git"

outBare=$(PATH="$STUBDIR:$PATH" bash "$CHECK" 2>&1)
assert_contains "CONTROL: the bare-push path was REACHED too" "$outBare" "DELETE"
assert_not_contains "bare push (To-line reconciliation) does NOT print the credential" \
    "$outBare" "$SECRET"

outAM=$(PATH="$STUBDIR:$PATH" bash "$MUTANT" origin feature 2>&1)
assert_contains "MUTANT (channel A): without redaction the credential IS printed" \
    "$outAM" "$SECRET"

echo '--- channel B: git'"'"'s stderr, passed through (remote UNREACHABLE) ---'
forge_push refuse
errB=$(PATH="$STUBDIR:$PATH" bash "$CHECK" origin feature 2>&1 >/dev/null); rcB=$?
assert_rc "an unresolvable push is REFUSED => rc 2" 2 "$rcB"
assert_not_contains "git's diagnostic is passed through WITHOUT the credential" \
    "$errB" "$SECRET"
# Redaction must not become SUPPRESSION. When _redact_userinfo_stream was
# defined AFTER its call site it was `command not found`, the whole diagnostic
# vanished, and the secret count went to zero FOR THE WRONG REASON.
assert_contains "…and the diagnostic SURVIVES (redacted, not swallowed)" \
    "$errB" "unable to access"
assert_not_contains "…and the redactor itself resolved (no 'command not found')" \
    "$errB" "command not found"

errBM=$(PATH="$STUBDIR:$PATH" bash "$MUTANT" origin feature 2>&1 >/dev/null)
assert_contains "MUTANT (channel B): without redaction the credential IS printed" \
    "$errBM" "$SECRET"

# EXACT count, not a floor: a case that stops running is silently absent from
# the tally unless it is compared against a declared total.
_EXPECTED_ASSERTIONS=13
_ran=$(( PASS + FAIL ))
assert_eq "every declared assertion executed ($_EXPECTED_ASSERTIONS)" "$_ran" "$_EXPECTED_ASSERTIONS"

th_summary_and_exit
