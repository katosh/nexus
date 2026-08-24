#!/usr/bin/env bash
# remote-port-change-notify.sh — the DURABLE half of the nexus-remote-ssh
# port-change alert (your-org/nexus-code#757, closing #637 item 3's gap).
#
#   monitor/remote-port-change-notify.sh --old 22022 --new 22023 [--reason "…"]
#   monitor/remote-port-change-notify.sh --old 22022 --new 22023 --dry-run
#
# ─── WHY THIS EXISTS ─────────────────────────────────────────────────────────
#
# `remote-up.sh` may MOVE the endpoint when the preferred port is held by a
# listener that is definitively not ours. The client is pinned to `host:port`
# OUT OF BAND, so a move breaks it silently — it simply stops connecting, with
# nothing distinguishing that from the service being down.
#
# #637 item 3 asked for an alert "durable enough that the operator finds it when
# the client next fails". What shipped was a `*** PORT CHANGED ***` stderr
# banner, an append to `principals_dir/port-history.log`, and:
#
#     command -v sandbox-notify >/dev/null 2>&1 \
#         && sandbox-notify "nexus-remote-ssh port CHANGED …" 2>/dev/null || true
#
# Three independent reasons that is not durable, all MEASURED, not reasoned:
#
#   1. A tmux bell is EPHEMERAL. The event this exists for is a reboot-time
#      bring-up; a 04:00 bell has no audience.
#   2. That message classifies as `task` in monitor/notifywrap/sandbox-notify —
#      the CATCH-ALL, highest-traffic class (every worker ready/done ping) — so a
#      300 s cross-window cooldown BATCHES it. Measured: fire any other task-class
#      bell, then this one 1 s later, and the decision log records
#      `"verdict":"suppress-cooldown"` with ZERO bells emitted.
#   3. `|| true` makes a failure to notify indistinguishable from a success.
#
# ─── WHAT THIS DOES INSTEAD ──────────────────────────────────────────────────
#
# Fans the change out over surfaces that OUTLIVE the session, and reports each
# one's outcome by name:
#
#   A. A comment on the operator's endpoint TRACKING ISSUE (their own suggestion
#      on your-org/your-nexus#311). Resolved from `monitor.remote.endpoint_issue`
#      — never hard-coded, because nexus-code is cloned by every operator and a
#      literal number would post one operator's endpoint into another's thread.
#   B. A push notification (monitor/notify.sh, `emergency` ⇒ Pushover priority 1
#      + email) with `--require-delivery`, so a configured-but-failing backend is
#      an error rather than a shrug.
#   C. A durable local copy under principals_dir (0700, survives a sandbox
#      restart) beside the port-history trail.
#
# C is deliberately NOT counted as delivery. It is the artifact an operator finds
# when they already know to look; the whole defect is that nobody was TOLD.
#
# ─── FAILING LOUD ────────────────────────────────────────────────────────────
#
# Every surface — and every marker operation — prints `ok` / `FAILED` /
# `SKIPPED` with a reason. An unset `endpoint_issue` is a FAILED surface, not a
# silent skip: silently skipping is precisely the defect class this file closes.
# If no durable surface accepted the notice we exit 3 AND leave an UNDELIVERED
# marker in principals_dir, which `remote-up.sh --status` surfaces on every run
# thereafter — so the failure is itself durable, not one stderr line at 04:00.
#
# This paragraph used to open "Nothing here is `|| true`-swallowed", and that was
# FALSE of the persistence mechanism itself: three marker operations were exactly
# that, so on an unwritable principals_dir the emitter announced "Marker written"
# with no marker on disk. A skeptic pass measured it. The claim is now true of
# both delivery and marker paths (see mark_undelivered / clear_undelivered), and
# the sentence is kept in corrected form rather than deleted, because a file that
# criticises swallowed failures while swallowing its own is the instructive part.
# What remains best-effort is deliberately only the cosmetic `chmod 644` on files
# whose CONTENT is already written — never anything a claim depends on.
#
# It does NOT block the bring-up (remote-up.sh reports our exit code and
# continues). The port already MOVED and is already RECORDED by the time we run;
# refusing to bring the endpoint up would leave the operator with a stale client
# AND a dead endpoint instead of just a stale client. The alert failure is made
# persistent instead — see cmd_status in remote-up.sh.
#
# ─── IDEMPOTENCE ─────────────────────────────────────────────────────────────
#
# There is none here, by design, and none is needed: the caller fires this only
# when `PORT_CHANGED` is set, which happens only on an ACTUAL recorded move. A
# supervised service restarting in a loop re-runs selection, finds the recorded
# port sticky, and never reaches this script. Explicit --old/--new are required
# so a standalone invocation is always deliberate (re-sending the notice after a
# delivery failure is a legitimate, wanted use).
#
# Env seams (tests point every one of these at a fixture; no network in CI):
#   REMOTE_NOTIFY_NG_BIN     the `ng` used for the GitHub comment (default: sibling)
#   REMOTE_NOTIFY_PUSH_BIN   the push notifier      (default: sibling notify.sh)
#   MONITOR_REMOTE_ENDPOINT_ISSUE[_REPO]  override the configured target
#
# Exit: 0 = at least one DURABLE surface accepted · 1 = usage · 3 = every
#       durable surface failed or none was configured.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$_script_dir/.." && pwd)}"
export NEXUS_ROOT

# shellcheck source=_remote_lib.sh
source "$_script_dir/_remote_lib.sh"

NG_BIN="${REMOTE_NOTIFY_NG_BIN:-$_script_dir/ng}"
PUSH_BIN="${REMOTE_NOTIFY_PUSH_BIN:-$_script_dir/notify.sh}"

say()  { echo "[port-change-notify] $*" >&2; }
die()  { echo "remote-port-change-notify: $*" >&2; exit 1; }

OLD=""; NEW=""; REASON=""; DRY=0
while (( $# > 0 )); do
    case "$1" in
        --old)    OLD="${2:-}";    shift 2 ;;
        --new)    NEW="${2:-}";    shift 2 ;;
        --reason) REASON="${2:-}"; shift 2 ;;
        --dry-run) DRY=1;          shift   ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done
[[ "$OLD" =~ ^[0-9]+$ ]] || die "--old <port> is required and must be numeric (got: ${OLD:-<empty>})"
[[ "$NEW" =~ ^[0-9]+$ ]] || die "--new <port> is required and must be numeric (got: ${NEW:-<empty>})"
[[ "$OLD" != "$NEW" ]]   || die "--old and --new are both $NEW — there is no change to announce"

PDIR=$(_remote_principals_dir)
NOTICE_FILE="$PDIR/port-change-notice.md"
UNDELIVERED="$PDIR/port-change-notice.UNDELIVERED"
STAMP=$(date -Is 2>/dev/null || date)

# ── THE UNDELIVERED MARKER (your-org/nexus-code#757, skeptic req-001) ────────
# The marker is the mechanism by which a delivery failure OUTLIVES this run:
# `remote-up.sh --status` re-announces it on every read until it clears. So a
# marker operation that fails silently is this file's own defect class one layer
# down — the failure stops being persistent while the output claims it is.
#
# It was exactly that. Three marker operations were `>> … 2>/dev/null || true`,
# under a header asserting "Nothing here is `|| true`-swallowed". Measured on a
# `chmod 500` principals_dir with both surfaces failing: rc 3, no marker on disk,
# and the emitter printing "Marker written: …" regardless. The converse was
# worse because it was fully silent: a successful delivery whose `rm -f` failed
# left a STALE marker, so `--status` cries wolf forever with nothing naming it.
#
# Two things to get right, and your-org/nexus-code#723 is why the first is not
# obvious: a REDIRECTION failure is reported by the SHELL, not the command, so
# `>> "$f" 2>/dev/null` cannot suppress it — the raw `line NNN: …: Permission
# denied` bled out UNATTRIBUTED and the very next line contradicted it. Test
# writability first and say it in our own words. Then VERIFY rather than assume:
# the claim is "a marker is on disk", so look.

# rc 0 = the marker is on disk · 1 = it could not be written (said loudly).
mark_undelivered() {
    local reason="${1:-}"
    if ! mkdir -p "$PDIR" 2>/dev/null || [[ ! -w "$PDIR" ]]; then
        say "marker:      FAILED — $PDIR is not writable, so this failure could NOT be"
        say "             made persistent. \`remote-up.sh --status\` will show NOTHING about it;"
        say "             the lines above are the only record it will ever have."
        return 1
    fi
    printf '%s\tundelivered\told=%s\tnew=%s\treason=%s\n' \
        "$STAMP" "$OLD" "$NEW" "$reason" >> "$UNDELIVERED" 2>/dev/null
    if [[ ! -s "$UNDELIVERED" ]]; then
        say "marker:      FAILED — the write to $UNDELIVERED produced no file."
        say "             This failure is NOT persistent; \`--status\` will show nothing about it."
        return 1
    fi
    chmod 644 "$UNDELIVERED" 2>/dev/null || true
    say "marker:      written ($UNDELIVERED) — \`remote-up.sh --status\` surfaces this until it clears"
    return 0
}

# rc 0 = no marker remains · 1 = a STALE marker survived (said loudly). Called
# on the success path: delivery worked, so any marker from a prior run is now
# false and must go, or --status reports an undelivered notice forever.
clear_undelivered() {
    [[ -e "$UNDELIVERED" ]] || return 0
    rm -f "$UNDELIVERED" 2>/dev/null
    if [[ -e "$UNDELIVERED" ]]; then
        say "marker:      STALE — could not remove $UNDELIVERED (is $PDIR writable?)."
        say "             THIS notice was delivered, but \`remote-up.sh --status\` will keep"
        say "             reporting an undelivered notice until that file is removed by hand."
        return 1
    fi
    say "marker:      cleared (a prior undelivered notice is resolved)"
    return 0
}

# ── render ──────────────────────────────────────────────────────────────────
# The COMMENT wraps the client paste; the PASTE is single-sourced from
# _remote_client_repin_notice so it cannot drift from the onboarding notice the
# same client receives over the channel once it reconnects.
BODY=$(mktemp -t nexus-portchange-XXXXXX) || die "mktemp failed (cannot render the notice)"
trap 'rm -f "$BODY"' EXIT

{
    printf '## remote-ssh endpoint MOVED: port %s → %s\n\n' "$OLD" "$NEW"
    printf 'The `nexus-remote-ssh` endpoint could not keep port `%s` at its last\n' "$OLD"
    printf 'bring-up, so it moved to `%s` and recorded that as canonical.\n' "$NEW"
    [[ -n "$REASON" ]] && printf '\nReason: %s\n' "$REASON"
    printf '\n**Your remote client is pinned to the old port out-of-band and will simply\n'
    printf 'fail to connect until you re-inform it.** Send it exactly this:\n\n'
    printf '```\n'
    _remote_client_repin_notice "$OLD" "$NEW"
    printf '```\n\n'
    printf '<sub>Recorded at %s · durable trail: `%s/port-history.log` · ' "$STAMP" "$PDIR"
    printf 'this copy: `%s` · posted by `monitor/remote-port-change-notify.sh`</sub>\n' "$NOTICE_FILE"
} > "$BODY"

# ── surface C: the durable local copy (never counted as delivery) ────────────
local_copy=FAILED
if mkdir -p "$PDIR" 2>/dev/null && cp "$BODY" "$NOTICE_FILE" 2>/dev/null; then
    chmod 644 "$NOTICE_FILE" 2>/dev/null || true
    local_copy=ok
fi
say "local copy:  $local_copy  ($NOTICE_FILE)"

# ── fail-closed secret guard, BEFORE any outbound write ─────────────────────
# The paste is secret-free by construction (a fingerprint hash + an endpoint),
# but this is the one remote surface designed to reach GitHub, so the repo's own
# pre-write guard runs on the real bytes. It fails CLOSED: an unreadable input or
# a grep error refuses just like a match.
#
# This runs BEFORE the --dry-run exit on purpose: a rehearsal that skips the gate
# the real run must pass is not a rehearsal, and --dry-run's whole job is to let
# an operator see exactly what would be published.
if ! _remote_secret_guard "$BODY"; then
    say "REFUSING to publish — the rendered notice tripped the secret guard (above)."
    say "  Nothing was posted. The local copy is at $NOTICE_FILE; inspect it."
    # A REHEARSAL MUST NOT ARM A PERSISTENT ALARM (skeptic req-001 follow-up).
    # --dry-run was never going to deliver anything, so "no durable surface
    # accepted the notice" is not a fact about the endpoint — it is the mode
    # working as asked. Marking here would make `remote-up.sh --status` report an
    # undelivered notice that does not exist, until someone cleared it by hand:
    # the cry-wolf direction of the very failure the marker exists to prevent.
    # The refusal itself is still loud, and still rc 3, in both modes.
    if (( DRY )); then
        say "  (--dry-run: NO undelivered marker armed — a rehearsal that refuses has"
        say "   nothing to deliver, so there is no delivery failure to make persistent.)"
    else
        mark_undelivered "secret-guard refused the rendered body"
    fi
    exit 3
fi

if (( DRY )); then
    say "--dry-run: rendered + secret-guarded; NOTHING was delivered. Body follows on stdout."
    cat "$BODY"
    exit 0
fi

delivered=0

# ── surface A: the operator's endpoint tracking issue ───────────────────────
issue=$(_remote_endpoint_issue)
repo=$(_remote_endpoint_issue_repo)
if [[ -z "$issue" ]]; then
    say "github:      FAILED — no monitor.remote.endpoint_issue configured."
    say "  This is NOT a silent skip: the operator asked to be told on an issue thread,"
    say "  and there is deliberately no default (nexus-code is cloned by every operator;"
    say "  a hard-coded number would post your endpoint into somebody else's thread)."
    say "  Set it in config/nexus.yml:   monitor: { remote: { endpoint_issue: <N> } }"
elif [[ ! "$issue" =~ ^[0-9]+$ ]]; then
    say "github:      FAILED — monitor.remote.endpoint_issue is not a number: '$issue'"
elif [[ ! -x "$NG_BIN" ]]; then
    say "github:      FAILED — ng not executable at $NG_BIN"
else
    ng_args=("$issue")
    [[ -n "$repo" ]] && ng_args+=(--repo "$repo")
    ng_args+=(--body-file "$BODY")
    # `ng comment` mints the bot installation token internally, so the comment is
    # authored by the bot — the operator's own `gh` would post as the operator,
    # and GitHub MUTES self-notifications, which would re-create the silence.
    if ng_out=$("$NG_BIN" comment "${ng_args[@]}" 2>&1); then
        say "github:      ok — $ng_out"
        delivered=1
    else
        say "github:      FAILED — ng comment $issue ${repo:+--repo $repo} exited nonzero:"
        printf '%s\n' "$ng_out" | sed 's/^/    /' >&2
    fi
fi

# ── surface B: push (Pushover priority 1 + email) ───────────────────────────
if [[ ! -x "$PUSH_BIN" ]]; then
    say "push:        FAILED — notifier not executable at $PUSH_BIN"
else
    push_msg="nexus-remote-ssh moved from port $OLD to $NEW. Your remote client is pinned to :$OLD and will not connect until re-informed. The exact text to send it is in $NOTICE_FILE${issue:+ and on issue #$issue}."
    if push_err=$("$PUSH_BIN" "remote-ssh port $OLD -> $NEW" "$push_msg" \
                    --priority emergency --require-delivery 2>&1); then
        say "push:        ok"
        delivered=1
    else
        say "push:        FAILED — $PUSH_BIN exited nonzero (2=no backend configured, 3=all configured backends failed):"
        printf '%s\n' "$push_err" | sed 's/^/    /' >&2
    fi
fi

# ── verdict ─────────────────────────────────────────────────────────────────
if (( delivered )); then
    # A stale marker surviving here is reported, not swallowed — but it does not
    # change the verdict: this notice WAS delivered, and failing the alert over a
    # leftover file would be the wrong answer to the wrong question.
    clear_undelivered || true
    say "delivered on at least one durable surface."
    exit 0
fi

say "NO DURABLE SURFACE ACCEPTED THE NOTICE."
mark_undelivered "no durable surface accepted the notice (see the per-surface reasons in the service log)"
say "  Re-send after fixing the surface above:"
say "    monitor/remote-port-change-notify.sh --old $OLD --new $NEW"
exit 3
