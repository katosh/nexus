#!/usr/bin/env bash
# Nexus push notifier — tiered fan-out to Pushover, ntfy.sh, and SMTP.
#
# Channel policy (set by the --priority flag):
#
#   routine     (default)  -> Pushover priority 0
#                            (or ntfy.sh fallback if no Pushover creds)
#   emergency              -> Pushover priority 1 + email to the user
#                            (or ntfy.sh priority 5 + email if no Pushover)
#
# Normal GitHub activity (comments, mentions, assignee) is already covered
# by GitHub's own push channel — do NOT call this helper for those events.
#
# Config files (all 0600, outside the repo):
#
#   ~/.claude/.nexus-pushover-user-key     single-line Pushover user key
#   ~/.claude/.nexus-pushover-app-token    single-line Pushover app API token
#                                          BOTH must exist for Pushover to fire;
#                                          if either is missing, Pushover is
#                                          disabled and ntfy.sh is used.
#
#   ~/.claude/.nexus-notify-token     single-line ntfy topic URL:
#                                       https://ntfy.sh/<topic>
#                                     Missing file = ntfy disabled.
#
# Email settings (address + SMTP relay) are read from config/nexus.yml
# (fallback: config/nexus.example.yml). Env vars NEXUS_EMAIL_TO,
# NEXUS_SMTP_HOST, NEXUS_SMTP_PORT override.
#
# AN EMPTY OVERRIDE MEANS NO EMAIL (your-org/nexus-code#1653 G3). A SET-but-
# EMPTY NEXUS_EMAIL_TO or NEXUS_SMTP_HOST disables the email leg — it is
# refused LOUDLY (stderr, even under --quiet) and reported `unconfigured`. It
# never falls back to the configured address: `${VAR:-…}` did exactly that, and
# a probe meaning "no mailer" sent a real email to the operator. UNSET still
# means "use the config". And NEXUS_NOTIFY_QUIET=1 — the test harness's hard
# off (run-tests.sh exports it) — makes this script send NOTHING on any
# backend, exit 0, and say so on stderr.
#
# Env overrides (each wins over config/nexus.yml):
#   NEXUS_PUSHOVER_USER_KEY_FILE   path to Pushover user-key file
#   NEXUS_PUSHOVER_APP_TOKEN_FILE  path to Pushover app-token file
#   NEXUS_NOTIFY_TOKEN             path to ntfy topic-url file
#   NEXUS_EMAIL_TO                 NARROWING ONLY: equal to the configured
#                                  address, or empty (no email). It can
#                                  never REDIRECT — see THE MAIL POLICY.
#   NEXUS_SMTP_HOST                SMTP relay hostname
#   NEXUS_SMTP_PORT                SMTP relay port
#
# Usage:
#   notify.sh <title> <message>
#             [--priority routine|emergency]
#             [--url <click-url>]
#             [--image <path-to-png>]            (inlined for email, attached for
#                                                 Pushover + ntfy.sh)
#             [--tag <ntfy-tag>]...              (ntfy-only; ignored by Pushover)
#             [--require-delivery]               (nonzero exit if ALL backends fail)
#             [--email-status-file <path>]       write the EMAIL leg's own outcome
#                                                 there: ok | failed | unconfigured | refused |
#                                                 skipped (not emergency) | quiet
#                                                 (NEXUS_NOTIFY_QUIET=1). The exit
#                                                 code folds every backend together,
#                                                 so a caller that must know the
#                                                 EMAIL arrived reads this, never rc
#                                                 (your-org/nexus-code#1653 F3).
#             [--email-only]                     skip Pushover/ntfy; email alone
#                                                 (a RETRY of a failed email must not
#                                                 re-ring an emergency push that
#                                                 already landed)
#             [--quiet]
#
# Exit codes:
#   0  at least one backend accepted the message, or skipped silently
#      when no config is present and --require-delivery was NOT given
#   1  usage error
#   2  --require-delivery set and no backend is configured
#   0  also: NEXUS_NOTIFY_QUIET=1 — NOTHING was sent (email status `quiet`)
#   3  --require-delivery set and every configured backend failed
#   4  curl / python3 missing
#   5  the email leg was REFUSED by the mail policy: the recipient is not
#      exactly the operator (other backends may still have delivered)
#   6  the email leg was REFUSED by the mail policy: the sender would carry
#      the operator's address or name
#
# THE MAIL POLICY (operator rule, 2026-09-28 — your-org/nexus-code#1663):
#   "the nexus can send emails without impersonating the operator, and
#    exclusively to the operator."
#   * RECIPIENT — exactly one bare address, equal (case-insensitively) to
#     `notifications.email.address` in the PRIMARY nexus's OWN
#     config/nexus.yml, the root chosen by the one-tree rule
#     (monitor/_nexus-root.sh, #1651). NEXUS_CONFIG and NEXUS_EMAIL_TO are
#     checked against it, never trusted: a NEXUS_CONFIG naming another
#     recipient, a NEXUS_ROOT conflict, an override naming another address, a
#     list, a display name, Cc/Bcc, a malformed address, a placeholder or list
#     in the config are all refused at rc 5 before any connection opens.
#     The SMTP envelope is set explicitly to that one address.
#   * RESIDUAL (the one-tree rule, #1651, by design): a config-less checkout
#     OUTSIDE any primary's work/, run with NEXUS_ROOT naming another nexus,
#     acts for THAT nexus and mails its operator. That is running that nexus's
#     code; a checkout with its own config/nexus.yml refuses the conflict.
#   * NO EMAIL is not a refusal: no address configured, or NEXUS_EMAIL_TO set
#     but EMPTY, sends nothing and leaves the exit code to the other backends.
#   * SENDER — a fixed nexus identity, `nexus monitor <nexus-monitor@<fqdn>>`,
#     for the From header AND the envelope MAIL FROM (set explicitly, never
#     derived from headers). No Reply-To, Sender or Resent-* header is ever
#     set. It must not equal or contain the operator's address, local part or
#     GitHub login; if it would, rc 6. There is no override for it.
#   * ONE PATH — this file is the only place in the repo allowed to open an
#     SMTP connection; monitor/watcher/mail-path-lint.sh enforces that.

set -uo pipefail

TITLE=""; MESSAGE=""
CLICK_URL=""
PRIORITY_LEVEL="routine"
IMAGE=""
TAGS=()
REQUIRE=0
QUIET=0
EMAIL_STATUS_FILE=""
EMAIL_ONLY=0

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1' "$0" >&2; exit "${1:-1}"; }   # the whole header, however long
log() { (( QUIET )) || echo "notify: $*" >&2; }

while (( $# > 0 )); do
    case "$1" in
        --priority)         PRIORITY_LEVEL="$2"; shift 2 ;;
        --url)              CLICK_URL="$2"; shift 2 ;;
        --image)            IMAGE="$2"; shift 2 ;;
        --tag)              TAGS+=("$2"); shift 2 ;;
        --require-delivery) REQUIRE=1; shift ;;
        --email-status-file) EMAIL_STATUS_FILE="$2"; shift 2 ;;
        --email-only)       EMAIL_ONLY=1; shift ;;
        --quiet)            QUIET=1; shift ;;
        -h|--help)          usage 0 ;;
        --)                 shift; break ;;
        -*)                 echo "unknown flag: $1" >&2; usage 1 ;;
        *)
            if   [[ -z "$TITLE" ]]; then TITLE="$1"
            elif [[ -z "$MESSAGE" ]]; then MESSAGE="$1"
            else echo "extra positional arg: $1" >&2; usage 1
            fi
            shift ;;
    esac
done

if [[ -n "$IMAGE" && ! -f "$IMAGE" ]]; then
    echo "--image path not found: $IMAGE" >&2
    exit 1
fi

[[ -n "$TITLE" && -n "$MESSAGE" ]] || usage 1
case "$PRIORITY_LEVEL" in
    routine|emergency) ;;
    *) echo "--priority must be routine|emergency, got: $PRIORITY_LEVEL" >&2; usage 1 ;;
esac

# THE TEST HARNESS'S HARD OFF (G3). Before any backend and before config is
# read: nothing is sent, the email leg reports `quiet`, and it is said aloud.
if [[ "${NEXUS_NOTIFY_QUIET:-0}" == "1" ]]; then
    echo "notify: NEXUS_NOTIFY_QUIET=1 — nothing sent on any backend (title: $TITLE)" >&2
    [[ -n "$EMAIL_STATUS_FILE" ]] && { printf 'quiet\n' > "$EMAIL_STATUS_FILE"; } 2>/dev/null
    exit 0
fi

command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; exit 4; }

# Resolve paths and defaults from config/nexus.yml (falls back to
# nexus.example.yml). Explicit env vars listed in the header still win.
_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_cfg="$_script_dir/../config/load.sh"

PUSHOVER_USER_FILE="${NEXUS_PUSHOVER_USER_KEY_FILE:-$("$_cfg" notifications.pushover.user_key_path "$HOME/.claude/.nexus-pushover-user-key")}"
PUSHOVER_APP_FILE="${NEXUS_PUSHOVER_APP_TOKEN_FILE:-$("$_cfg" notifications.pushover.app_token_path "$HOME/.claude/.nexus-pushover-app-token")}"
NTFY_FILE="${NEXUS_NOTIFY_TOKEN:-$("$_cfg" notifications.ntfy.topic_url_path "$HOME/.claude/.nexus-notify-token")}"
# An override that is SET — even to EMPTY — wins over the config; EMPTY then
# means no email (G3). `+set`, never `:+set`: the colon form reads empty as
# unset and falls back to the configured relay/address.
SMTP_HOST="$("$_cfg" notifications.email.smtp_host)"
[[ -n "${NEXUS_SMTP_HOST+set}" ]] && SMTP_HOST="$NEXUS_SMTP_HOST"
SMTP_PORT="${NEXUS_SMTP_PORT:-$("$_cfg" notifications.email.smtp_port 25)}"
# Production emergency email target; env var wins if set.
EMAIL_DEFAULT_TO="$("$_cfg" notifications.email.address)"
[[ -n "${NEXUS_EMAIL_TO+set}" ]] && EMAIL_DEFAULT_TO="$NEXUS_EMAIL_TO"

# ---- perms check: mode 600 or 400 only ----
perms_ok() {
    local f="$1"
    [[ -r "$f" ]] || return 1
    local p
    p=$(stat -c '%a' "$f" 2>/dev/null || echo "")
    [[ "$p" == "600" || "$p" == "400" ]]
}

# ---- backend: Pushover ----
try_pushover() {
    perms_ok "$PUSHOVER_USER_FILE" || return 2
    perms_ok "$PUSHOVER_APP_FILE"  || return 2
    local user app
    user=$(sed -n '1p' "$PUSHOVER_USER_FILE" | tr -d '[:space:]')
    app=$(sed  -n '1p' "$PUSHOVER_APP_FILE"  | tr -d '[:space:]')
    [[ -n "$user" && -n "$app" ]] || return 2

    local pri sound
    case "$PRIORITY_LEVEL" in
        routine)   pri=0; sound="pushover" ;;
        emergency) pri=1; sound="siren" ;;
    esac

    local form=(-F "token=$app" -F "user=$user" -F "title=$TITLE"
                -F "message=$MESSAGE" -F "priority=$pri" -F "sound=$sound")
    [[ -n "$CLICK_URL" ]] && form+=(-F "url=$CLICK_URL" -F "url_title=open in GitHub")
    [[ -n "$IMAGE"     ]] && form+=(-F "attachment=@$IMAGE;type=image/png")

    local http
    http=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
           "${form[@]}" https://api.pushover.net/1/messages.json 2>/dev/null || echo "000")
    if [[ "$http" =~ ^2 ]]; then
        log "pushover ok ($PRIORITY_LEVEL → priority=$pri)"
        return 0
    fi
    log "pushover FAILED (HTTP $http)"
    return 3
}

# ---- backend: ntfy.sh ----
try_ntfy() {
    perms_ok "$NTFY_FILE" || return 2
    local topic_url
    topic_url=$(sed -n '1p' "$NTFY_FILE" | tr -d '[:space:]')
    case "$topic_url" in https://*|http://*) ;; *) return 2 ;; esac

    local ntfy_pri
    case "$PRIORITY_LEVEL" in routine) ntfy_pri=3 ;; emergency) ntfy_pri=5 ;; esac

    local hdrs=(-H "Title: $TITLE" -H "Priority: $ntfy_pri" -H "Message: $MESSAGE")
    [[ -n "$CLICK_URL" ]] && hdrs+=(-H "Click: $CLICK_URL")
    if (( ${#TAGS[@]} > 0 )); then
        local IFS=,
        hdrs+=(-H "Tags: ${TAGS[*]}")
    fi

    local http
    if [[ -n "$IMAGE" ]]; then
        # ntfy.sh hosts the uploaded file and shows it as a thumbnail in the
        # notification. Title/message come from headers in this mode.
        hdrs+=(-H "Filename: $(basename "$IMAGE")")
        http=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
               -T "$IMAGE" "${hdrs[@]}" "$topic_url" 2>/dev/null || echo "000")
    else
        # Body holds the message; headers still carry title/priority.
        http=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
               "${hdrs[@]}" -d "$MESSAGE" "$topic_url" 2>/dev/null || echo "000")
    fi
    if [[ "$http" =~ ^2 ]]; then
        log "ntfy ok ($PRIORITY_LEVEL → priority=$ntfy_pri)"
        return 0
    fi
    log "ntfy FAILED (HTTP $http)"
    return 3
}

# Set by try_email to 5|6 when THE MAIL POLICY refuses; read at exit.
EMAIL_POLICY_REFUSED=0

# ---- backend: email (emergency only) ----
try_email() {
    [[ "$PRIORITY_LEVEL" == "emergency" ]] || return 2

    local to="$EMAIL_DEFAULT_TO"

    # THE MAIL POLICY'S INPUTS (header). The operator is whoever the PRIMARY
    # nexus's OWN config names: the root is resolved by the one-tree rule
    # (monitor/_nexus-root.sh, your-org/nexus-code#1651), and its
    # config/nexus.yml is read with NEXUS_CONFIG pinned to it. Neither
    # NEXUS_CONFIG nor NEXUS_EMAIL_TO can choose the operator; each can only be
    # CHECKED against it (your-org/nexus-code#1663 skeptic F1).
    local root rrc operator="" placeholder="" login="" env_op prc
    # shellcheck source=/dev/null
    . "$_script_dir/_nexus-root.sh"
    root=$(nexus_config_root "$_script_dir/..")
    rrc=$?
    if (( rrc != 0 )); then
        echo "notify: email REFUSED by the mail policy (rc 5): cannot tell which nexus's operator to mail — ${root:-the nexus root does not resolve}. Nothing was sent." >&2
        EMAIL_POLICY_REFUSED=5
        return 2
    fi
    # Reads the ROOT's own config file, with the file pinned: never the
    # env-selectable $_cfg.
    _root_cfg() { NEXUS_CONFIG="$root/config/nexus.yml" NEXUS_ROOT="$root" "$root/config/load.sh" "$@" 2>/dev/null; }
    if [[ -f "$root/config/nexus.yml" ]]; then
        operator=$(_root_cfg notifications.email.address) || operator=""
        login=$(_root_cfg github.user_login "") || login=""
    fi
    placeholder=$(NEXUS_CONFIG="$root/config/nexus.example.yml" NEXUS_ROOT="$root" \
        "$root/config/load.sh" notifications.email.address 2>/dev/null) || placeholder=""

    # A NEXUS_CONFIG naming a different recipient is a redirect: refused, even
    # when the root names no operator at all.
    if [[ -n "${NEXUS_CONFIG:-}" ]]; then
        env_op=$("$_cfg" notifications.email.address 2>/dev/null) || env_op=""
        if [[ "${env_op,,}" != "${operator,,}" ]]; then
            echo "notify: email REFUSED by the mail policy (rc 5): NEXUS_CONFIG names the recipient '${env_op}', but the nexus's own config names '${operator}'. NEXUS_CONFIG cannot redirect mail. Nothing was sent." >&2
            EMAIL_POLICY_REFUSED=5
            return 2
        fi
    fi
    # NO EMAIL CONFIGURED is not a violation: no email, rc 0, pushes unaffected
    # (skeptic F2). A configured value that is not one valid address is still
    # refused loudly by the policy below.
    if [[ -z "$operator" ]]; then
        log "email not configured (notifications.email.address is unset in $root/config) — no email sent"
        return 2
    fi
    # rc 2 = UNCONFIGURED, distinct from a failed send: retrying cannot fix it.
    # A SET-but-EMPTY override lands here too, and is refused LOUDLY (G3).
    if [[ -z "$to" || -z "$SMTP_HOST" ]]; then
        local why="no address or SMTP host configured"
        if [[ -n "${NEXUS_EMAIL_TO+set}" && -z "${NEXUS_EMAIL_TO}" ]]; then why="NEXUS_EMAIL_TO is set but EMPTY"
        elif [[ -n "${NEXUS_SMTP_HOST+set}" && -z "${NEXUS_SMTP_HOST}" ]]; then why="NEXUS_SMTP_HOST is set but EMPTY"; fi
        echo "notify: email REFUSED — ${why}; no email is sent (an empty override never falls back to the configured address)" >&2
        return 2
    fi

    command -v python3 >/dev/null 2>&1 || { log "email skipped: python3 missing"; return 3; }

    TITLE="$TITLE" MESSAGE="$MESSAGE" CLICK_URL="$CLICK_URL" \
    IMAGE_PATH="$IMAGE" \
    SMTP_HOST="$SMTP_HOST" SMTP_PORT="$SMTP_PORT" TO_ADDR="$to" \
    OPERATOR_ADDR="$operator" OPERATOR_PLACEHOLDER="$placeholder" OPERATOR_LOGIN="$login" \
    python3 - <<'PY' && { log "email ok (→ $to)"; return 0; }
import os, re, socket, smtplib, sys
from email.message import EmailMessage
from email.utils import formataddr

# ---- THE MAIL POLICY (see the header). Checked BEFORE any connection. ----
_ATOM = r"[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+"
_LABEL = r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?"
ADDR = re.compile(_ATOM + r"(?:\." + _ATOM + r")*@" + _LABEL + r"(?:\." + _LABEL + r")+")
HOST = re.compile(_LABEL + r"(?:\." + _LABEL + r")*")

def refuse(rc, why):
    print(f"notify: email REFUSED by the mail policy (rc {rc}): {why}. "
          f"Nothing was sent; the nexus emails the operator only, and never as the operator.",
          file=sys.stderr)
    sys.exit(rc)

operator    = os.environ.get('OPERATOR_ADDR', '')
placeholder = os.environ.get('OPERATOR_PLACEHOLDER', '')
login       = os.environ.get('OPERATOR_LOGIN', '').strip()
to_raw      = os.environ.get('TO_ADDR', '')

# RECIPIENT: exactly the operator. fullmatch, never match: `$` would accept a
# trailing newline, and a list / display name / Cc smuggled into the value
# fails the single-bare-address shape.
if not ADDR.fullmatch(operator):
    refuse(5, f"the operator address (notifications.email.address) is unresolved or malformed: {operator!r}")
if not placeholder:
    refuse(5, "could not read the example config's placeholder address to rule it out")
if operator.casefold() == placeholder.casefold():
    refuse(5, f"notifications.email.address is still the example placeholder {operator!r}, which is not the operator")
if not ADDR.fullmatch(to_raw):
    refuse(5, f"the recipient {to_raw!r} is not a single bare address")
if to_raw.casefold() != operator.casefold():
    refuse(5, f"the recipient {to_raw!r} is not the operator; NEXUS_EMAIL_TO may only narrow, never redirect")
RECIPIENT = operator

# SENDER: a fixed nexus identity, never the operator.
host = socket.getfqdn()
if not HOST.fullmatch(host):
    refuse(6, f"this host's name {host!r} cannot form a sender address")
SENDER_NAME = "nexus monitor"
SENDER = f"nexus-monitor@{host}"
# The operator's identifiers: the address, its local part, the GitHub login.
# Compared as whole TOKENS of the sender's name and local part, never as
# substrings — a substring rule would refuse an operator called `us@…`.
op_cf, op_local = operator.casefold(), operator.split('@', 1)[0].casefold()
sender_local = SENDER.split('@', 1)[0].casefold()
names = {SENDER_NAME.casefold(), sender_local}
names |= {t for t in re.split(r"[^a-z0-9]+", SENDER_NAME.casefold() + ' ' + sender_local) if t}
idents = {op_local, login.casefold()} - {''}
if op_cf in SENDER.casefold() or idents & names:
    refuse(6, f"the sender {SENDER!r} would carry the operator's address or name")

def one_line(v):
    return re.sub(r"[\r\n]+", " ", v)

msg = EmailMessage()
msg['Subject'] = f"[nexus] {one_line(os.environ['TITLE'])}"
msg['From']    = formataddr((SENDER_NAME, SENDER))
msg['To']      = RECIPIENT
msg['Auto-Submitted'] = 'auto-generated'

footer = f"Sent automatically by the nexus monitor on {host}; not written by a person."
url = os.environ.get('CLICK_URL') or '(no link)'
plain = (
    f"Event: {os.environ['TITLE']}\n"
    f"Issue: {url}\n"
    f"\n"
    f"{os.environ['MESSAGE']}\n"
    f"\n"
    f"-- \n"
    f"{footer}\n"
)
msg.set_content(plain)

img_path = os.environ.get('IMAGE_PATH') or ''
if img_path and os.path.isfile(img_path):
    with open(img_path, 'rb') as f:
        img_bytes = f.read()
    html = (
        '<!DOCTYPE html><html><body '
        'style="font-family:-apple-system,sans-serif;font-size:14px">'
        f'<p><b>Event:</b> {os.environ["TITLE"]}<br>'
        f'<b>Issue:</b> <a href="{url}">{url}</a></p>'
        f'<p>{os.environ["MESSAGE"]}</p>'
        '<p><img src="cid:nexus-notify-img" alt="attached image" '
        'style="max-width:600px;border:1px solid #ddd"></p>'
        f'<p style="color:#777;font-size:12px">{footer}</p>'
        '</body></html>'
    )
    msg.add_alternative(html, subtype='html')
    # Attach the image to the HTML alt so mail clients render it inline.
    msg.get_payload()[-1].add_related(
        img_bytes, maintype='image', subtype='png',
        cid='<nexus-notify-img>',
        filename=os.path.basename(img_path),
    )

# The last look before the wire: nothing but the one recipient and the fixed
# sender may be addressed, whatever the code above grows into.
for h in ('Cc', 'Bcc', 'Reply-To', 'Sender', 'Resent-From', 'Resent-Sender',
          'Resent-To', 'Resent-Cc', 'Resent-Bcc'):
    if msg.get_all(h):
        refuse(5, f"the message carries a {h} header")
if msg.get_all('To') != [RECIPIENT] or msg.get_all('From') != [formataddr((SENDER_NAME, SENDER))]:
    refuse(5, "the To/From headers are not exactly the operator and the nexus sender")

try:
    with smtplib.SMTP(os.environ['SMTP_HOST'], int(os.environ['SMTP_PORT']), timeout=10) as s:
        # The ENVELOPE, explicitly: MAIL FROM is the nexus, RCPT TO is the
        # operator alone. Never derived from the headers.
        s.send_message(msg, from_addr=SENDER, to_addrs=[RECIPIENT])
except Exception as e:
    print(f"smtp: {e}", file=sys.stderr)
    sys.exit(1)
PY
    prc=$?
    if (( prc == 5 || prc == 6 )); then
        # Refused, not failed: retrying cannot fix it. Said on stderr by the
        # policy itself (even under --quiet); recorded for the exit code.
        EMAIL_POLICY_REFUSED=$prc
        return 2
    fi
    log "email FAILED"
    return 3
}

# ---- fan out ----
push_ok=0
skipped_all=1

if (( ! EMAIL_ONLY )); then
    if try_pushover; then push_ok=1; skipped_all=0
    else
        rc=$?
        (( rc == 2 )) || skipped_all=0
        # If Pushover unavailable or failed, fall through to ntfy as alt push.
        if try_ntfy; then push_ok=1; skipped_all=0
        else
            rc=$?; (( rc == 2 )) || skipped_all=0
        fi
    fi
fi

email_ok=0
email_status=skipped
if [[ "$PRIORITY_LEVEL" == "emergency" ]]; then
    if try_email; then email_ok=1; skipped_all=0; email_status=ok
    else
        rc=$?
        if (( EMAIL_POLICY_REFUSED )); then email_status=refused      # the mail policy said no (rc 5/6)
        elif (( rc == 2 )); then email_status=unconfigured; else email_status=failed; skipped_all=0; fi
    fi
fi
if [[ -n "$EMAIL_STATUS_FILE" ]]; then
    { printf '%s\n' "$email_status" > "$EMAIL_STATUS_FILE"; } 2>/dev/null || log "could not write --email-status-file $EMAIL_STATUS_FILE"
fi

# A policy refusal outranks every other outcome: it is a configuration or
# code defect, and a push that landed must not make it read as success.
(( EMAIL_POLICY_REFUSED )) && exit "$EMAIL_POLICY_REFUSED"

if (( push_ok || email_ok )); then
    exit 0
fi

if (( REQUIRE )); then
    if (( skipped_all )); then
        log "no backend configured (want both of: $PUSHOVER_USER_FILE + $PUSHOVER_APP_FILE, or: $NTFY_FILE)"
        exit 2
    fi
    exit 3
fi

(( skipped_all )) && log "no backend configured; silent skip"
exit 0
