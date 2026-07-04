# shellcheck shell=bash
# monitor/hooks/_cause_classify.sh — pure cause-classifier for a
# Claude Code StopFailure event.
#
# A worker turn that dies to an API/model/auth error fires the
# `StopFailure` hook *instead of* `Stop` (empirically verified — see
# the stall-detection report). The turn ends, the inner `claude`
# process stays alive, the input box is empty, and NO `Stop` event
# clears the worker's state markers. From the renderer alone this is
# indistinguishable from a worker that finished cleanly but forgot to
# `ng wrap-up`. The structured `error` token (and the human-readable
# `last_assistant_message`) carried by the StopFailure payload is what
# lets us tell the two apart — and, crucially, lets us pick the right
# recovery (paste-to-resume vs respawn vs operator escalation).
#
# This file holds ONLY the pure mapping so it can be unit-tested in
# isolation (no stdin, no filesystem, no env). The hook wrapper that
# reads the payload and writes the marker is `turn-failure-emit.sh`.
#
#   cause_classify_error <error_token> <last_assistant_message>
#       → prints "<category>\t<recovery>" on stdout, exit 0.
#
# Categories (the *why*):
#   transient     server-side hiccup; the same turn will likely
#                 succeed on a retry (HTTP 500 / 529 / overloaded /
#                 generic api_error).
#   config        the worker's configuration is broken in a way a
#                 retry of the SAME turn cannot fix — a bad model pin
#                 (`model_not_found`). Re-pasting just re-runs the
#                 doomed turn.
#   conversation  the transcript itself is malformed (e.g. a 400
#                 `thinking`/`redacted_thinking` ordering error). A
#                 paste re-sends into the same broken transcript and
#                 re-fails; the conversation must be rebuilt.
#   auth          credentials/permission failure; no in-band recovery.
#   rate_limit    weekly/usage limit — owned by over-limit-emit.sh;
#                 we never write a turn-failure marker for it.
#   unknown       unrecognised; default to the least-destructive
#                 recovery (paste) and let the operator see it.
#
# Recovery (the *what to do*), assuming the process is ALIVE (the
# pane-state pid gate independently downgrades any dead pane to
# `absent` → respawn, so a `paste` verdict here is always conditioned
# on liveness downstream):
#   paste     resume the worker in place — paste a "continue" nudge.
#   respawn   the live turn will re-fail; relaunch via `--continue`
#             (rebuilds context) or a fresh spawn.
#   operator  needs a human (credentials, model access revoked).
#   none      not our marker to write (rate_limit).
#
# Matching is on the structured `error` token first (i18n-stable),
# falling back to substring probes of the message text only when the
# token is empty/unknown — the token is the contract field, the
# message is human copy that can drift between releases.

cause_classify_error() {
    local err="${1:-}" msg="${2:-}"
    # Normalise to lowercase for robust matching; the token has been
    # observed lowercase (`server_error`, `model_not_found`) but we
    # don't want a future capitalised variant to slip through.
    local errl msgl
    errl=$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')
    msgl=$(printf '%s' "$msg" | tr '[:upper:]' '[:lower:]')

    case "$errl" in
        rate_limit|rate_limit_error)
            printf 'rate_limit\tnone'; return 0 ;;
        server_error|overloaded_error|overloaded|api_error|timeout|connection_error)
            printf 'transient\tpaste'; return 0 ;;
        model_not_found|not_found_error)
            printf 'config\trespawn'; return 0 ;;
        authentication_error|permission_error|auth_error|forbidden)
            printf 'auth\toperator'; return 0 ;;
    esac

    # Token absent or unrecognised → probe the human message. The
    # status code in "API Error: <NNN> ..." is the most reliable
    # secondary signal.
    case "$msgl" in
        *"rate limit"*|*"usage limit"*|*"hit your limit"*)
            printf 'rate_limit\tnone'; return 0 ;;
        *"api error: 5"*|*overloaded*|*"server-side issue"*|*"internal server error"*)
            printf 'transient\tpaste'; return 0 ;;
        *"thinking"*|*"redacted_thinking"*|*"api error: 400"*|*"api error: 422"*)
            # A malformed-transcript 4xx recurs on a verbatim resend.
            printf 'conversation\trespawn'; return 0 ;;
        *"may not exist"*|*"access to it"*|*"selected model"*)
            printf 'config\trespawn'; return 0 ;;
        *"authentic"*|*"credential"*|*"unauthorized"*|*"forbidden"*)
            printf 'auth\toperator'; return 0 ;;
    esac

    # Nothing matched. Optimistic default: most unclassified turn
    # failures are transient blips, and `paste` is the least
    # destructive recovery. The operator still sees the row.
    printf 'unknown\tpaste'
    return 0
}
