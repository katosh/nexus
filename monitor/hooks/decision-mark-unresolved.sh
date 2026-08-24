#!/usr/bin/env bash
# monitor/hooks/decision-mark-unresolved.sh
#
# Claude Code Stop-hook handler. Walks every decision file for this
# worker's tmux window and rules on each one at turn-end.
#
# ── WHAT `Stop` IS EVIDENCE OF (your-org/nexus-code#824) ─────────────
#
# This hook used to add `unresolved: true` to EVERY file still present,
# on the reasoning that "a file lingering past the worker's Stop event
# means the prompt was never acted on". That inference is false in
# general and INVERTED for the one kind where it costs the most.
#
# It is false in general because the only thing that removes a decision
# file is an explicit orchestrator-side `ng decision-ack` / `rm` / `mv`.
# Answering a permission prompt IN THE PANE — which is how a human
# answers one — does not touch the file. So "still present" means
# "nobody ran the orchestrator-side ack", not "unanswered".
#
# It is INVERTED for `permission_prompt` because a permission modal
# SUSPENDS the turn. `Stop` cannot fire while it is on screen. So the
# arrival of `Stop` is positive evidence the prompt is GONE — answered,
# dismissed, or interrupted — and the hook was consuming exactly that
# event to declare it unanswered.
#
# Measured on the production board, window `spawnpath`:
#
#     emitted  (Notification hook, .ts)   2026-08-08T11:50:39Z
#     stamped  (this hook, file mtime)    2026-08-08T11:54:56Z   +4m17s
#
# The turn ran four minutes seventeen seconds PAST the permission prompt
# and then reached `Stop`. It could not have done that with the modal up.
# The row then re-fired every `DECISION_REEMIT_COOLDOWN_SECONDS` (300)
# for ~5 h, on byte-identical pane content, while `pane-state.sh` read
# `autosuggest-only input=ghost` throughout. Thirteen firings on that one
# window; `unresolved=true` was the only reliable discriminator among ~35
# `idle_prompt` emits that night, so each false positive cost a hand-read
# of the pane and degraded the one signal that worked.
#
# ── THE RULING, BY KIND ─────────────────────────────────────────────
#
#   permission_prompt   Stop ⇒ the modal is gone. Mark RESOLVED.
#   everything else     Stop ⇒ no information either way. Mark unresolved,
#                       exactly as before.
#
# `idle_prompt` ("Claude is waiting for your input") is the kind the old
# inference was written for and it genuinely does linger past turn-end —
# its behaviour is unchanged. An UNRECOGNISED kind keeps the old
# behaviour too: this is an operator-ATTENTION channel, and the harm it
# must never do is go quiet, so anything we cannot rule on stays loud.
#
# RESOLVED, NOT DELETED. The file is stamped `resolved: true` +
# `resolved_at`, never removed: it is the audit record that the prompt
# HAPPENED, and the orchestrator's ack channel stays the only thing that
# retires a fingerprint. `render_pending_decisions` skips resolved rows.
# Resolution is also not permanent suppression — `decision-emit.sh`
# rewrites `<fp>.json` wholesale on a genuine re-fire, so the same
# fingerprint surfacing again produces a fresh, unresolved record.
#
# Skipped:
#   - already-ruled files (idempotent across multiple turn-ends)
#   - `*.handled.json` tombstones (orchestrator opted to keep a
#     historical audit copy after answering)
#
# Required env (exported by spawn-worker.sh):
#   NEXUS_ROOT           absolute path to the primary nexus clone
#   NEXUS_WORKER_WINDOW  tmux window name this worker was spawned into
#
# Stop fires per agent turn-end. Hot-path discipline: the loop is
# bounded by the number of pending decisions for this one window
# (typically 0 or 1), each iteration is one jq + one mv.

set -u

window="${NEXUS_WORKER_WINDOW:-}"
root="${NEXUS_ROOT:-}"

if [[ -z "$window" ]] || [[ -z "$root" ]]; then
    exit 0
fi

dest_dir="$root/monitor/.state/decisions"
[[ -d "$dest_dir" ]] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

shopt -s nullglob
for f in "$dest_dir/$window".*.json; do
    # Skip handled tombstones — they're already terminal.
    case "$f" in
        *.handled.json) continue ;;
    esac
    # Idempotent: don't re-rule a file already ruled either way.
    if jq -e '.unresolved == true or .resolved == true' "$f" >/dev/null 2>&1; then
        continue
    fi
    # The kind decides which way `Stop` cuts. Read defensively: a file we
    # cannot parse a kind out of falls to the default arm and stays LOUD,
    # which is the safe direction for an attention channel.
    kind=$(jq -r '.kind // ""' "$f" 2>/dev/null) || kind=""
    tmp="$f.tmp.$$"
    case "$kind" in
        permission_prompt)
            # Stop fired, so the modal is not on screen. Do NOT claim it is
            # unanswered using the very event that proves otherwise.
            filter='. + {resolved: true, resolved_at: $ts, resolved_by: "stop-hook: a permission modal suspends the turn, so Stop implies it is no longer displayed"}'
            ;;
        *)
            filter='. + {unresolved: true}'
            ;;
    esac
    if jq -c --arg ts "$now" "$filter" "$f" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
done
exit 0
