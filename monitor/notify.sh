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
# Env overrides (each wins over config/nexus.yml):
#   NEXUS_PUSHOVER_USER_KEY_FILE   path to Pushover user-key file
#   NEXUS_PUSHOVER_APP_TOKEN_FILE  path to Pushover app-token file
#   NEXUS_NOTIFY_TOKEN             path to ntfy topic-url file
#   NEXUS_EMAIL_TO                 literal recipient address
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
#             [--quiet]
#
# Exit codes:
#   0  at least one backend accepted the message, or skipped silently
#      when no config is present and --require-delivery was NOT given
#   1  usage error
#   2  --require-delivery set and no backend is configured
#   3  --require-delivery set and every configured backend failed
#   4  curl / python3 missing

set -uo pipefail

TITLE=""; MESSAGE=""
CLICK_URL=""
PRIORITY_LEVEL="routine"
IMAGE=""
TAGS=()
REQUIRE=0
QUIET=0

usage() { sed -n '2,50p' "$0" >&2; exit "${1:-1}"; }
log() { (( QUIET )) || echo "notify: $*" >&2; }

while (( $# > 0 )); do
    case "$1" in
        --priority)         PRIORITY_LEVEL="$2"; shift 2 ;;
        --url)              CLICK_URL="$2"; shift 2 ;;
        --image)            IMAGE="$2"; shift 2 ;;
        --tag)              TAGS+=("$2"); shift 2 ;;
        --require-delivery) REQUIRE=1; shift ;;
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

command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; exit 4; }

# Resolve paths and defaults from config/nexus.yml (falls back to
# nexus.example.yml). Explicit env vars listed in the header still win.
_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_cfg="$_script_dir/../config/load.sh"

PUSHOVER_USER_FILE="${NEXUS_PUSHOVER_USER_KEY_FILE:-$("$_cfg" notifications.pushover.user_key_path "$HOME/.claude/.nexus-pushover-user-key")}"
PUSHOVER_APP_FILE="${NEXUS_PUSHOVER_APP_TOKEN_FILE:-$("$_cfg" notifications.pushover.app_token_path "$HOME/.claude/.nexus-pushover-app-token")}"
NTFY_FILE="${NEXUS_NOTIFY_TOKEN:-$("$_cfg" notifications.ntfy.topic_url_path "$HOME/.claude/.nexus-notify-token")}"
SMTP_HOST="${NEXUS_SMTP_HOST:-$("$_cfg" notifications.email.smtp_host)}"
SMTP_PORT="${NEXUS_SMTP_PORT:-$("$_cfg" notifications.email.smtp_port 25)}"
# Production emergency email target; env var wins if set.
EMAIL_DEFAULT_TO="${NEXUS_EMAIL_TO:-$("$_cfg" notifications.email.address)}"

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

# ---- backend: email (emergency only) ----
try_email() {
    [[ "$PRIORITY_LEVEL" == "emergency" ]] || return 2

    local to="$EMAIL_DEFAULT_TO"

    command -v python3 >/dev/null 2>&1 || { log "email skipped: python3 missing"; return 3; }

    TITLE="$TITLE" MESSAGE="$MESSAGE" CLICK_URL="$CLICK_URL" \
    IMAGE_PATH="$IMAGE" \
    SMTP_HOST="$SMTP_HOST" SMTP_PORT="$SMTP_PORT" TO_ADDR="$to" \
    python3 - <<'PY' && { log "email ok (→ $to)"; return 0; }
import os, socket, smtplib, sys
from email.message import EmailMessage

msg = EmailMessage()
msg['Subject'] = f"[nexus] {os.environ['TITLE']}"
msg['From']    = f"nexus-monitor@{socket.getfqdn()}"
msg['To']      = os.environ['TO_ADDR']

url = os.environ.get('CLICK_URL') or '(no link)'
plain = (
    f"Event: {os.environ['TITLE']}\n"
    f"Issue: {url}\n"
    f"\n"
    f"{os.environ['MESSAGE']}\n"
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
        '</body></html>'
    )
    msg.add_alternative(html, subtype='html')
    # Attach the image to the HTML alt so mail clients render it inline.
    msg.get_payload()[-1].add_related(
        img_bytes, maintype='image', subtype='png',
        cid='<nexus-notify-img>',
        filename=os.path.basename(img_path),
    )

try:
    with smtplib.SMTP(os.environ['SMTP_HOST'], int(os.environ['SMTP_PORT']), timeout=10) as s:
        s.send_message(msg)
except Exception as e:
    print(f"smtp: {e}", file=sys.stderr)
    sys.exit(1)
PY
    log "email FAILED"
    return 3
}

# ---- fan out ----
push_ok=0
skipped_all=1

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

email_ok=0
if [[ "$PRIORITY_LEVEL" == "emergency" ]]; then
    if try_email; then email_ok=1; skipped_all=0; fi
fi

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
