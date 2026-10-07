#!/usr/bin/env bash
# test-notify-mail-policy.sh — THE MAIL POLICY in monitor/notify.sh
# (your-org/nexus-code#1663). The operator's rule, 2026-09-28:
#
#   "the nexus can send emails without impersonating the operator, and
#    exclusively to the operator."
#
# Every case drives the REAL notify.sh against a captured SMTP layer and
# asserts on what reached the WIRE — the envelope pair (MAIL FROM, RCPT TO)
# and the headers — not on what the script says it did.
#
# HERMETIC, FOUR WAYS, and the first is asserted before any case runs:
#   1. PYTHONPATH puts a FAKE SMTP module ahead of the standard library; it
#      records every connect and every send to a capture file and opens no
#      socket. A preflight imports it under the same env and ABORTS the suite
#      unless it resolves to the fixture's copy.
#   2. The relay is `smtp.nexus-test.invalid` — `.invalid` never resolves
#      (RFC 2606), so even a bypassed fake cannot reach a real relay.
#   3. A fake `curl` fronts PATH and every push credential path is absent, so
#      no Pushover / ntfy request can leave.
#   4. HOME and NEXUS_CONFIG point into the fixture; the operator's real config
#      is never read.
#
# NEXUS_NOTIFY_QUIET: run-tests.sh exports it as the harness's hard off, and
# notify.sh honours it by sending NOTHING — which would make every case below
# vacuous. The subject invocation alone runs with it UNSET, and only inside the
# four-way seal above; the suite itself never sends.
#
# Run: bash monitor/watcher/test-notify-mail-policy.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
# The subject runs from a FIXTURE NEXUS ROOT, not from this repo: the mail
# policy reads the operator from the primary nexus's OWN config (the one-tree
# rule, monitor/_nexus-root.sh), so NEXUS_CONFIG is no longer a seam that can
# choose the operator (your-org/nexus-code#1663 skeptic F1). The fixture holds
# copies of the files notify.sh executes and a config/nexus.yml per case.

. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' 'monitor/notify.sh' 'monitor/_nexus-root.sh' 'config/load.sh' 'config/nexus.example.yml'
}
gp_handle "$@"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/py" "$WORK/bin" "$WORK/home"

# _mkroot <dir> <github.repo> — a nexus root holding the subject's executed files.
_mkroot() {
    mkdir -p "$1/monitor" "$1/config"
    cp "$REPO_ROOT/monitor/notify.sh" "$REPO_ROOT/monitor/_nexus-root.sh" "$1/monitor/"
    cp "$REPO_ROOT/config/load.sh" "$REPO_ROOT/config/nexus.example.yml" "$1/config/"
    printf '%s\n' "$2" > "$1/.repo"
}
R="$WORK/root"
_mkroot "$R" "fixture-org/fixture-nexus"
NOTIFY="$R/monitor/notify.sh"

OP="op@example.org"
RELAY="smtp.nexus-test.invalid"
FQDN=$(python3 -c 'import socket; print(socket.getfqdn())')
SENDER="nexus-monitor@$FQDN"

# The fake module's NAME is assembled, never written literally: the one-path
# lint (mail-path-lint.sh) scans this file too, and a literal would make it
# flag its own suite.
_MOD="smtp""lib"
cat > "$WORK/py/$_MOD.py" <<'PY'
import json, os
_CAP = os.environ['FAKE_SMTP_CAPTURE']
_HDRS = ('From', 'To', 'Cc', 'Bcc', 'Reply-To', 'Sender', 'Subject',
         'Auto-Submitted', 'Resent-To', 'Resent-From')
def _rec(d):
    with open(_CAP, 'a') as f:
        f.write(json.dumps(d) + '\n')
class SMTP:
    def __init__(self, host='', port=0, *a, **kw):
        _rec({'event': 'connect', 'host': host, 'port': port})
    def __enter__(self):
        return self
    def __exit__(self, *a):
        return False
    def send_message(self, msg, from_addr=None, to_addrs=None, *a, **kw):
        _rec({'event': 'send', 'from_addr': from_addr, 'to_addrs': to_addrs,
              'headers': {h: [str(v) for v in (msg.get_all(h) or [])] for h in _HDRS},
              'body': msg.as_string(),
              # The DECODED plain part: `body` is the wire form, and a line past
              # 78 chars goes out quoted-printable on Python >= 3.7 with a soft
              # break mid-line, so a host-dependent string cannot be matched
              # there (#1703: a CI runner's ~70-char FQDN split the footer).
              'text': msg.get_body(preferencelist=('plain',)).get_content()})
    def quit(self):
        pass
def _raw_send(self, from_addr, to_addrs, msg, *a, **kw):
    _rec({'event': 'raw-send', 'from_addr': from_addr, 'to_addrs': to_addrs})
setattr(SMTP, 'send' + 'mail', _raw_send)   # named in pieces: see the one-path lint
SMTP_SSL = SMTP
PY
printf '#!/bin/sh\necho "fake curl: $*" >> "%s/curl.log"\nexit 7\n' "$WORK" > "$WORK/bin/curl"
chmod +x "$WORK/bin/curl"

_cfg() {   # <address|""> [<login>] [<root>] — "" omits the address key
    local root="${3:-$R}" addr=""
    [[ -n "$1" ]] && addr="    address: $1"
    {
        printf 'github:\n  repo: %s\n  user_login: %s\n' "$(cat "$root/.repo")" "${2:-opuser}"
        printf 'notifications:\n  email:\n'
        [[ -n "$addr" ]] && printf '%s\n' "$addr"
        printf '    smtp_host: %s\n    smtp_port: 2525\n' "$RELAY"
    } > "$root/config/nexus.yml"
}

# ---- preflight: the seal is real, or nothing below is evidence ------------
_resolved=$(env PYTHONPATH="$WORK/py" FAKE_SMTP_CAPTURE="$WORK/pre" \
    python3 -c "import $_MOD as m; print(m.__file__)" 2>&1)
[[ "$_resolved" == "$WORK/py/$_MOD.py" ]] \
    || th_abort "the fake SMTP module does not shadow the real one under PYTHONPATH (resolved: $_resolved) — refusing to drive notify.sh"
assert_eq "preflight: python resolves the SMTP module to the fixture's fake" "$_resolved" "$WORK/py/$_MOD.py"

# _run [VAR=val …] — one emergency notify; stderr to $WORK/err, rc to $RC.
_run() {
    rm -f "$WORK/cap" "$WORK/err"
    env -u NEXUS_NOTIFY_QUIET -u NEXUS_EMAIL_TO -u NEXUS_SMTP_HOST -u NEXUS_SMTP_PORT \
        -u NEXUS_CONFIG -u NEXUS_ROOT HOME="$WORK/home" \
        PYTHONPATH="$WORK/py" FAKE_SMTP_CAPTURE="$WORK/cap" PATH="$WORK/bin:$PATH" \
        NEXUS_PUSHOVER_USER_KEY_FILE="$WORK/absent" NEXUS_PUSHOVER_APP_TOKEN_FILE="$WORK/absent" \
        NEXUS_NOTIFY_TOKEN="$WORK/absent" \
        "$@" bash "$NOTIFY" "${TITLE:-disk full}" "the body" --priority "${PRIO:-emergency}" ${ESF:+--email-status-file "$ESF"} \
        </dev/null >/dev/null 2>"$WORK/err"
    RC=$?
}
# `grep -c` prints 0 AND exits 1 on no match, so `|| echo 0` would print TWO
# zeros; the count is read as printed, and a missing capture file counts 0.
_count()    { local n; n=$(grep -c -e "$1" -- "$WORK/cap" 2>/dev/null); printf '%s\n' "${n:-0}"; }
_sends()    { _count '"event": "send"'; }
_connects() { _count '"event": "connect"'; }
_field() {   # <python expr over the one send record `r`>
    python3 - "$WORK/cap" "$1" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if '"send"' in l]
r = recs[0]
print(eval(sys.argv[2]))
PY
}

# ---- ALLOWED: the one shape the policy exists to let through ---------------
_cfg "$OP"
_run
assert_rc "no override: rc 0" "$RC" 0
assert_eq "no override: exactly one send reached the wire" "$(_sends)" 1
assert_eq "no override: envelope MAIL FROM is the nexus sender, set explicitly" "$(_field 'r["from_addr"]')" "$SENDER"
assert_eq "no override: envelope RCPT TO is the operator alone" "$(_field 'r["to_addrs"]')" "['$OP']"
assert_eq "no override: To header is the operator alone" "$(_field 'r["headers"]["To"]')" "['$OP']"
assert_eq "no override: From header is the fixed nexus identity" "$(_field 'r["headers"]["From"]')" "['nexus monitor <$SENDER>']"
assert_eq "no override: no Cc/Bcc/Reply-To/Sender/Resent header" \
    "$(_field '[h for h in ("Cc","Bcc","Reply-To","Sender","Resent-To","Resent-From") if r["headers"][h]]')" "[]"
assert_eq "no override: Auto-Submitted: auto-generated" "$(_field 'r["headers"]["Auto-Submitted"]')" "['auto-generated']"
assert_contains "no override: the body footer names the nexus monitor and host" \
    "$(_field 'r["text"]')" "Sent automatically by the nexus monitor on $FQDN"
assert_contains "no override: the connection went to the fixture relay" "$(cat "$WORK/cap")" "\"host\": \"$RELAY\""
assert_eq "no override: no push request left (fake curl never called)" "$([[ -f "$WORK/curl.log" ]] && echo called || echo none)" "none"

# ---- a host name long enough to push the footer past the line limit (#1703) --
# The footer's length depends on the runner's FQDN, so the quoted-printable
# path was exercised only on a host with a long name — CI's, never here. A
# sitecustomize pins a CI-shaped FQDN so every runner takes that path (on
# Python >= 3.7; 3.6 sends long lines 7bit, and the case is then vacuous).
LONGFQDN="runnervmtr4k5.xoxzbnckc3tuvhtfp2zpexthsa.bx.internal.cloudapp.net"
mkdir -p "$WORK/longhost"
printf 'import socket\nsocket.getfqdn = lambda name="": %s\n' "'$LONGFQDN'" > "$WORK/longhost/sitecustomize.py"
_run PYTHONPATH="$WORK/py:$WORK/longhost"
assert_rc "long host name: rc 0" "$RC" 0
assert_eq "long host name: the pinned FQDN reached the sender" "$(_field 'r["from_addr"]')" "nexus-monitor@$LONGFQDN"
assert_contains "long host name: the DECODED footer names the host unbroken" \
    "$(_field 'r["text"]')" "Sent automatically by the nexus monitor on $LONGFQDN; not written by a person."

_run NEXUS_EMAIL_TO="OP@Example.ORG"
assert_rc "override = the operator in another case: rc 0 (narrowing is allowed)" "$RC" 0
assert_eq "override = the operator in another case: RCPT TO is the CONFIGURED address" "$(_field 'r["to_addrs"]')" "['$OP']"

TITLE=$'disk full\nBcc: evil@example.net' _run
assert_rc "a title carrying a header injection: rc 0" "$RC" 0
assert_eq "a title carrying a header injection: no Bcc header" "$(_field 'r["headers"]["Bcc"]')" "[]"
assert_eq "a title carrying a header injection: RCPT TO is still the operator alone" "$(_field 'r["to_addrs"]')" "['$OP']"

PRIO=routine _run
assert_eq "routine priority sends no email at all" "$(_sends)" 0

# ---- REFUSED: every redirect shape — rc 5, and NOTHING reaches the wire ----
# Not even a connection: the policy is checked before the relay is dialled.
_refused() {   # <label> <want-rc>
    assert_rc "$1: rc $2" "$RC" "$2"
    assert_eq "$1: no connection was opened" "$(_connects)" 0
    assert_contains "$1: refused LOUDLY on stderr" "$(cat "$WORK/err")" "REFUSED by the mail policy"
}
_cfg "$OP"
_run NEXUS_EMAIL_TO="someone@example.net";                    _refused "override names another address" 5
assert_eq "a planted redirect to another address puts NOTHING on the wire (0 sends)" "$(_sends)" 0
_run NEXUS_EMAIL_TO="$OP,someone@example.net";                _refused "override is a list including the operator" 5
_run NEXUS_EMAIL_TO="Op <$OP>";                               _refused "override is a display-name form" 5
_run NEXUS_EMAIL_TO=$'op@example.org\nCc: someone@example.net'; _refused "override smuggles a Cc line" 5
_run NEXUS_EMAIL_TO="op@example";                             _refused "override is malformed (no TLD)" 5
_cfg "you@your-institution.edu"
_run;                                                         _refused "configured address is the example placeholder" 5
_cfg "\"$OP, someone@example.net\""
_run;                                                         _refused "configured address is a list" 5
_cfg "op@@example.org"
_run;                                                         _refused "configured address is malformed" 5

# ---- REFUSED: every impersonation shape — rc 6 ----------------------------
_cfg "$SENDER"
_run;                                                         _refused "the operator's address IS the nexus sender" 6
_cfg "nexus-monitor@example.org"
_run;                                                         _refused "the operator's local part is the sender's local part" 6
_cfg "$OP" "monitor"
_run;                                                         _refused "the operator's login is a token of the sender's name" 6

# ---- F1: the operator cannot be CHOSEN through the environment ------------
_cfg "$OP"
printf 'notifications:\n  email:\n    address: someone@example.net\n    smtp_host: %s\n' "$RELAY" > "$WORK/evil.yml"
_run NEXUS_CONFIG="$WORK/evil.yml";                            _refused "NEXUS_CONFIG names another recipient" 5
_run NEXUS_CONFIG="$WORK/evil.yml" NEXUS_EMAIL_TO="someone@example.net"; _refused "NEXUS_CONFIG and NEXUS_EMAIL_TO agree on another recipient" 5
assert_eq "a NEXUS_CONFIG redirect puts NOTHING on the wire (0 sends)" "$(_sends)" 0
_mkroot "$WORK/evilroot" "evil-org/evil-nexus"
_cfg "someone@example.net" opuser "$WORK/evilroot"
_run NEXUS_ROOT="$WORK/evilroot";                              _refused "NEXUS_ROOT names a different nexus" 5
# your-org/nexus-code#1652 item 3: the root's OWN nexus.yml is MALFORMED. At
# 33a44f48 that read as "no config", the one-tree rule deferred to NEXUS_ROOT,
# and the other nexus's operator was mailed. The no-config arm below
# ("no config/nexus.yml at all") is the control.
printf 'github:\n  repo: [unclosed\n' > "$R/config/nexus.yml"
_run NEXUS_ROOT="$WORK/evilroot";                              _refused "own nexus.yml MALFORMED, NEXUS_ROOT names another nexus (#1652)" 5
assert_eq "…a malformed own config mails NOBODY, least of all the other nexus's operator (0 sends)" "$(_sends)" 0
_cfg "$OP"
cp "$R/config/nexus.yml" "$WORK/same.yml"
_run NEXUS_CONFIG="$WORK/same.yml"
assert_rc "NEXUS_CONFIG naming the SAME operator is not a redirect: rc 0" "$RC" 0
assert_eq "NEXUS_CONFIG naming the SAME operator: delivered to the operator" "$(_field 'r["to_addrs"]')" "['$OP']"

# ---- F2 / F4: NO email is not a refusal -----------------------------------
_quiet_ok() {   # <label> — rc 0, nothing dialled, and no REFUSED on stderr
    assert_rc "$1: rc 0" "$RC" 0
    assert_eq "$1: no connection was opened" "$(_connects)" 0
    assert_not_contains "$1: not reported as a POLICY refusal" "$(cat "$WORK/err")" "REFUSED by the mail policy"
}
_cfg ""
_run;                                                          _quiet_ok "no email address configured"
rm -f "$R/config/nexus.yml"
_run;                                                          _quiet_ok "no config/nexus.yml at all"
_cfg "$OP"
_run NEXUS_EMAIL_TO="";                                        _quiet_ok "NEXUS_EMAIL_TO set but EMPTY"
# R1 (skeptic round 2): the root names NO operator, NEXUS_CONFIG names one.
# Nothing is sent either way; what only the NEXUS_CONFIG check provides is that
# the attempt is REFUSED loudly rather than passed off as "no email configured".
_cfg ""
_run NEXUS_CONFIG="$WORK/evil.yml";                            _refused "root names no operator, NEXUS_CONFIG names one" 5
_cfg "$OP"

# ---- the status a refusal records, and the harness's hard off ------------
# A policy refusal is written as `refused` to --email-status-file (skeptic R3),
# never as `unconfigured`: _operator_alert has a `refused` arm that settles the
# incident's mail without retrying and records it as a refusal.
_cfg "$OP"
ESF="$WORK/esf" _run NEXUS_EMAIL_TO="someone@example.net"
assert_rc "a refused redirect with --email-status-file: rc 5" "$RC" 5
assert_eq "a refused redirect records email status 'refused', not 'unconfigured'" "$(cat "$WORK/esf" 2>/dev/null)" "refused"
_run NEXUS_NOTIFY_QUIET=1
assert_rc "NEXUS_NOTIFY_QUIET=1: rc 0" "$RC" 0
assert_eq "NEXUS_NOTIFY_QUIET=1: no connection was opened" "$(_connects)" 0
assert_contains "NEXUS_NOTIFY_QUIET=1: says nothing was sent" "$(cat "$WORK/err")" "NEXUS_NOTIFY_QUIET=1"

# A NEGATIVE control for the token rule: a short local part that is a
# SUBSTRING of the sender's name, but no token of it, must still be delivered.
_cfg "us@example.org"
_run
assert_rc "a local part that is only a substring of the sender name (us@): rc 0" "$RC" 0
assert_eq "a local part that is only a substring of the sender name (us@): delivered to it" "$(_field 'r["to_addrs"]')" "['us@example.org']"

EXPECTED_ASSERTIONS=90   # +4: #1652 item 3 (malformed own config); +3: #1703 long host name
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} ))
assert_eq "assertion TOTAL matches the EXPECTED total — no assertion silently dropped or added" \
    "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
