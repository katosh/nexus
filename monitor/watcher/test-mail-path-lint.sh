#!/usr/bin/env bash
# test-mail-path-lint.sh — both directions of monitor/watcher/mail-path-lint.sh
# (your-org/nexus-code#1663): no file but monitor/notify.sh may send mail.
#
#   POSITIVE — one planted file per construct family the lint names. Each MUST
#              be flagged, or its green is a claim about its regex.
#   NEGATIVE — ordinary words that share the silhouette (email, mailbox, a
#              port that merely contains 25). Each MUST NOT be flagged, or the
#              lint gets muted within a week.
#
# Every plant is ASSEMBLED from fragments ("smtp""lib"): the lint scans this
# file too, and a literal would make it flag its own suite forever.
#
# Run: bash monitor/watcher/test-mail-path-lint.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
LINT="$_test_dir/mail-path-lint.sh"

. "$_test_dir/../_guard_population.sh"
gp_population() {
    bash "$LINT" --files "$REPO_ROOT"
}
gp_handle "$@"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
T="$WORK/tree"

# _mktree — a fresh fixture repository with the sanctioned sender and an EMPTY
# exemption list, rebuilt per case so no plant can answer for another.
_mktree() {
    rm -rf "$T"
    mkdir -p "$T/monitor/watcher" "$T/docs"
    git -C "$WORK" init -q tree
    th_require_fixture_repo "$T"
    printf '#!/usr/bin/env bash\npython3 - <<PY\nimport %s\nPY\n' "smtp""lib" > "$T/monitor/notify.sh"
    printf '# exemptions\n' > "$T/monitor/watcher/mail-path-lint.allow"
    git -C "$T" add -A
    git -C "$T" -c user.email=t@t -c user.name=t commit -qm base
}
_plant() {   # <relpath> <line> — tracked
    _mktree
    printf '%s\n' "$2" > "$T/$1"
    git -C "$T" add -- "$1"
}
_scan() { OUT=$(bash "$LINT" "$T" 2>"$WORK/err"); RC=$?; }

# ---- POSITIVE: every construct family is flagged -------------------------
POS=(
    "python module|import smtp""lib"
    "async python module|import aiosmtp""lib"
    "client class call|conn = SMT""P_SSL(relay, 465)"
    "submission binary, by path|/usr/sbin/send""mail -t < msg"
    "the x-suffixed mail client|echo hi | mail""x -s subj a@b.org"
    "one-line mail with a subject flag|echo hi | mai""l -s subj a@b.org"
    "one-line mail, subject flag after another flag|mai""l -r me@b.org -s subj a@b.org"
    "the m-prefixed smtp client|m""smtp a@b.org < msg"
    "the swiss-army smtp tester|swa""ks --to a@b.org"
    "the dog-named terminal client|mut""t -s subj a@b.org"
    "the nail-family client|s-na""il -s subj a@b.org"
    "curl with an SMTP-over-TLS URL|curl smt""ps://relay:465 --mail-rcpt a@b.org"
    "bash dev-tcp to the SMTP port|exec 3<>/dev/tcp/relay/2""5"
    "raw socket, netcat family, submission port|n""c relay 58""7 < dialogue"
    "TLS client to the SMTPS port|openss""l s_client -connect relay:46""5"
    "raw SMTP dialogue|echo MAI""L FROM:a@b.org"
    "raw SMTP dialogue in lowercase|s.send(b'mai""l from:<a@b.org>')"
    "lowercase recipient verb|s.send(b'rcp""t to:<a@b.org>')"
    "perl SMTP class|my \$s = Net::SMT""P->new('relay');"
    "ruby SMTP class|Net::SMT""P.start('relay', 25)"
    "git patch mailer|git send-emai""l --to a@b.org 0001.patch"
    "one-line mail to an address, no subject flag|echo body | mai""l a@b.org"
    "python socket to the submission port|socket.create_connectio""n(('relay', 58""7))"
    "python socket connect to the SMTP port|s.connec""t(('relay', 2""5))"
    "node mailer|const m = require('nodemaile""r')"
)
for row in "${POS[@]}"; do
    IFS='|' read -r label line <<<"$row"
    _plant monitor/a.sh "$line"
    _scan
    assert_rc "POSITIVE $label: rc 1" "$RC" 1
    assert_contains "POSITIVE $label: the site is named" "$OUT" "monitor/a.sh:1:"
done

_plant docs/howto.md "Then run \`echo x | mai""l -s subj a@b.org\`."
_scan
assert_rc "POSITIVE a runnable mail line in DOCUMENTATION is flagged: rc 1" "$RC" 1

_mktree
printf 'import smtp''lib\n' > "$T/monitor/new.py"      # never git-added
_scan
assert_contains "POSITIVE an UNTRACKED new file is in the population" "$OUT" "monitor/new.py:1:"

# ---- NEGATIVE: the silhouette without the construct ----------------------
NEG=(
    "email_status=ok  # the email leg"
    "mail_to=\"\$op\"; mailbox=/var/mail/x"
    "curl -sS https://api.pushover.net/1/messages.json"
    "port=2525; nc -l 8080"
    "echo 'mail sent' >&2"
    "the Gmail smtp relay is configured in nexus.yml"
    "mail_from=nexus; rcpt_to=op  # config keys, not a dialogue"
    "the mailbox at /var/mail holds it"
    "conn.connect(('relay', 8025))"
)
for line in "${NEG[@]}"; do
    _plant monitor/a.sh "$line"
    _scan
    assert_rc "NEGATIVE not flagged: $line" "$RC" 0
done

_mktree
printf 'import smtp''lib  # a second sender inside the sanctioned file\n' >> "$T/monitor/notify.sh"
_scan
assert_rc "the SANCTIONED path (monitor/notify.sh) is not flagged" "$RC" 0

_mktree
printf 'import smtp''lib\n' > "$T/monitor/ignored.py"
printf 'monitor/ignored.py\n' > "$T/.gitignore"
_scan
assert_rc "an IGNORED file is outside the population (the declared boundary)" "$RC" 0

# ---- the exemption list: honoured, and cannot rot ------------------------
_plant monitor/a.sh "WORDS='cat send""mail tee'"
printf 'monitor/a.sh\tWORDS=\x27\ta word list\n' >> "$T/monitor/watcher/mail-path-lint.allow"
_scan
assert_rc "a reviewed exemption row suppresses its line" "$RC" 0

_mktree
printf 'monitor/gone.sh\tX=\ta row for a line that no longer exists\n' >> "$T/monitor/watcher/mail-path-lint.allow"
_scan
assert_rc "a STALE exemption (matches no line) fails with rc 4" "$RC" 4

_mktree
printf 'monitor/a.sh only-one-field\n' >> "$T/monitor/watcher/mail-path-lint.allow"
_scan
assert_rc "a MALFORMED exemption row is a refusal (rc 3), not a green" "$RC" 3

_plant monitor/a.sh "import smtp""lib"
rm -f "$T/monitor/watcher/mail-path-lint.allow"
_scan
assert_rc "with NO exemption file at all, a plant is still flagged (rc 1)" "$RC" 1

# ---- refusals ------------------------------------------------------------
_mktree
OUT=$(bash "$LINT" "$T/monitor" 2>&1); RC=$?
assert_rc "a root that is NOT its own repository's top is refused (rc 3), never scanned as the enclosing repo" "$RC" 3

# ---- the real tree -------------------------------------------------------
OUT=$(bash "$LINT" "$REPO_ROOT" 2>&1); RC=$?
assert_rc "the real tree is clean (rc 0)" "$RC" 0
[[ $RC == 0 ]] || printf '%s\n' "$OUT" >&2
_n_pop=$(bash "$LINT" --files "$REPO_ROOT" | grep -c .)
assert_eq "the real-tree population clears a broken-enumerator floor (got $_n_pop)" \
    "$(( _n_pop >= 800 ? 1 : 0 ))" "1"

EXPECTED_ASSERTIONS=70
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} ))
assert_eq "assertion TOTAL matches the EXPECTED total — no assertion silently dropped or added" \
    "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
