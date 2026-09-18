#!/usr/bin/env bash
# skeptic-channel.sh — the worker↔skeptic communication channel and
# nudge mechanism for the nexus skeptic protocol
# (skills/nexus.skeptic/SKILL.md).
#
# A skeptic agent independently, adversarially validates a worker's
# result. While doing so it needs to ASK the original worker questions
# (why this default? where is this claim verified? rerun this on a
# trivial known-answer case) and read the answers. This script is the
# transport: a per-task shared directory under
#   $STATE_DIR/skeptic/<task-id>/
# where <task-id> is the original worker's tmux window name (sanitized).
#
# ── The redesign (PR #285, tracking your-org/your-nexus#223) ──────────
# The PRIMARY wake mechanism is now a WORKER-RUN blocking ack-loop, not a
# PostToolUse hook. The hook only fired while the worker was *issuing
# tool calls*, but a worker is effectively DONE (idle, no tool calls)
# exactly when a skeptic begins probing its finished result — so in the
# common case the hook never fired. The hook is removed; the loop below
# replaces it.
#
# The lifecycle — "the rename is the signal" at every transition:
#
#   1. skeptic:  ask       → writes  req-NNN-<slug>.open.md   (a challenge,
#                            written via a temp file + atomic rename so the
#                            worker never observes a half-written request).
#   2. worker:   await     → a blocking loop of SHORT polls. On seeing one
#                            or more *.open.md it ACKS each by renaming
#                            req-NNN-<slug>.open.md → req-NNN-<slug>.ack.md
#                            (the rename IS the "I have seen it" signal the
#                            skeptic's reconcile loop watches for) and
#                            EXITS 0 so the worker AGENT regains control.
#   3. worker:   answer    → appends its reply under the response marker
#                            and renames *.ack.md → *.answered.md, then
#                            RE-ENTERS await.
#   4. skeptic:  await-answer → blocks until *.answered.md appears, reads it.
#   5. skeptic:  reconcile → at the skeptic's wrap: loops ensuring every
#                            request it filed has progressed past .open.md
#                            (acked or answered); NUDGES any still-.open.md
#                            past a grace period; returns when all are
#                            acked/answered; fails loud (exit 6) if a worker
#                            never acks (the skeptic reports it, never hangs).
#   6. skeptic:  close     → drops a DONE sentinel; the worker's await
#                            detects it and EXITS 10 so the worker stops
#                            looping and proceeds to retire.
#
# State machine (per request):   open ──ack──▶ ack ──answer──▶ answered
#                                  └──────── answer (direct) ───────┘
# Channel sentinel:               (close) ──▶ DONE   →   worker await exit 10
#
# Round scoping (issue #469): DONE is per-CHANNEL, not per-round, and a
# channel is reused across rounds — a worker re-wraps precisely because a
# skeptic found defects. `ng wrap-up --skeptic-decision require` opens a
# new round by writing a fresh pending marker; `close` ends one by writing
# DONE and removing the marker. Therefore a DONE OLDER than the pending
# marker belongs to a previous round, and `await` must NOT treat it as
# terminal — doing so retires a worker that believes it was validated when
# no second skeptic ever spawned. await compares the two mtimes and keeps
# waiting on a stale DONE (fail closed). wrap-up also clears a prior round
# when it opens a new one (fail fast) — via `reset`, which ARCHIVES the
# prior DONE and its .answered.md verdicts into <channel>/.stale-archive-*
# (your-org/nexus-code#511, upgrading the original bare `rm` so the trail
# survives and stale verdicts do not pollute the next round). Either guard
# alone would suffice for the observed bug, but await's is the one that
# holds if a future caller writes a pending marker without resetting the
# channel.
#
# That caller already exists: spawn-worker.sh (~:1457) writes a pending
# marker DIRECTLY when the orchestrator spawns a skeptic, with no wrap-up
# in the loop and no DONE reset. wrap-up's guard cannot see that path;
# only this mtime comparison closes it. Do not remove it on the grounds
# that wrap-up "already handles" the reset.
#
# Race-safety: every state-producing write (ask, answer, close) builds
# into a temp file in the same directory and `mv -f`s it into place — an
# atomic rename on one filesystem. A reader (await / await-answer /
# reconcile) only ever acts on a fully-renamed terminal name; it never
# sees a partial. The ack rename (open→ack) is itself the atomic op, so a
# request is acked exactly once even under a racing poll.
#
# Heartbeat (watcher integration): while a worker is parked in `await` it
# is legitimately waiting, not hung. Each poll refreshes the worker's
# skeptic-pending marker mtime ($STATE_DIR/skeptic/pending/<window>) and a
# per-task .await-heartbeat. The watcher treats a FRESH pending marker as
# `parked-awaiting-skeptic` and exempts the worker from idle-too-long /
# no-wrap-up flagging; a marker gone STALE (await died) lapses the
# exemption so a genuine hang resurfaces. See skills/nexus.skeptic and the
# _idle_probe.sh exemption (monitor.skeptic.await_hang_seconds).
#
# When the worker has gone idle and stops re-entering await, the skeptic
# wakes it:
#   nudge → reuses monitor/paste-followup.sh to drop a "you have N pending
#           skeptic requests" line into the worker's tmux pane (the
#           battle-tested machine-input-stamped paste path; never a raw
#           tmux send-keys — see paste-followup.sh header for why an
#           unstamped paste corrupts operator attribution).
#
# Subcommands:
#   init    <task-id>                         create the channel dir
#   ask     <task-id> <slug> [--file f|--message t|-]   skeptic → req
#   poll    <task-id> [--state open|ack|answered|all]   list requests
#   await   <task-id> [--timeout S] [--interval S] [--once]   WORKER → block
#                                             for *.open.md, ack, exit 0;
#                                             DONE → exit 10; timeout → exit 4;
#                                             deferred → exit 13 (re-enter)
#   answer  <task-id> <req> [--file f|--message t|-]    worker → reply+rename
#   await-answer <task-id> <req> [--timeout S] [--interval S]  skeptic → block
#                                             until *.answered.md
#   reconcile <task-id> [--window W] [--grace S] [--interval S] [--max-iter N]
#                                             [--min-interval S] [--no-nudge]
#                                             skeptic → ensure all acked
#   close   <task-id>                         skeptic → drop DONE sentinel
#   resolve <task-id> --reason "<why>" [--disposition]
#                                             ORCHESTRATOR-ONLY: clear a
#                                             skeptic-pending marker that a
#                                             returned verdict failed to clear,
#                                             with a mandatory rationale written
#                                             beside it + an audit event. The
#                                             sanctioned replacement for a
#                                             hand-`rm` (your-org/nexus-code#577).
#                                             --disposition additionally
#                                             releases retire-preflight check
#                                             1c's `disposition: second-pass`
#                                             gate, and is the ONE form that
#                                             succeeds with NO marker present
#                                             (your-org/nexus-code#813)
#   defer   <task-id> --reason "<why>" [--until "<condition>"]
#                                             skeptic/orchestrator → release the
#                                             worker's CURRENT await (exit 13,
#                                             DEFERRED) while the requirement
#                                             STANDS: the pending marker is not
#                                             touched, retire-preflight keeps
#                                             gating (your-org/nexus-code#845 H)
#   reset   <task-id>                         open a new round: archive the
#                                             prior DONE + .answered.md into
#                                             skeptic/.archive/<task>.reset-<ts>/
#                                             (no-op rc 0)
#   list    <task-id>                         human-readable status table
#   status  <task-id>                         machine: "open=N ack=A answered=M total=T done=0|1"
#   nudge   <worker-window> [--task <id>] [--force] [--min-interval S]
#   notify-delta <skeptic-window> --target <window> [--round N] [--detail T]
#                [--why changed|unchanged-rearm|first-round|indeterminate|no-record]
#                [--subject-sha SHA] [--prior-sha SHA]
#                                 [--force] [--min-interval S]
#                                             TARGET-side → wake a PINNED
#                                             skeptic that a new round exists.
#                                             The reverse of `nudge`; the half
#                                             that was missing, and the reason a
#                                             parked target and its idle skeptic
#                                             could each wait on the other for
#                                             hours (your-org/nexus-code#845).
#   dir     <task-id>                         print the channel dir path
#   reqfile <task-id> <req>                   resolve a req id/name → path
#
# <req> accepts a bare number (3 / 003), the stem (req-003-foo), or a
# full filename in any state.
#
# Exit codes:
#   0   ok / await acked an open request (worker should answer it next)
#   1   usage / bad argument
#   2   channel dir or request file not found
#   3   tmux / paste failure (nudge)
#   4   await / await-answer timed out (no request / no answer in time)
#   5   nudge skipped (worker busy / typing / unresolvable; or rate-limited)
#   6   reconcile gave up: a worker never acked within the bound (a finding)
#  12   await: DISPLACED — a NEWER await claimed this channel and reaped
#       this one (#615's one-live-waiter lock, your-org/nexus-code#1178).
#       Your listener is gone; the newer one is LIVE. Do NOT re-arm — that
#       would displace it in turn. The reaper also appends a line to
#       <channel>/.await-displaced naming victim and displacer. A TERM that
#       is NOT a displacement (an operator `kill`, a `timeout` wrapper)
#       still exits 143 with the default disposition, unchanged.
#  13   await: DEFERRED — a `defer` released THIS wait without discharging
#       the requirement (your-org/nexus-code#845 claim H). The pending
#       marker is untouched, so retirement stays gated; the reason and the
#       condition are printed verbatim on stderr. Act on them and RE-ENTER
#       await. Not 11 (11 = the requirement is DISCHARGED, proceed to retire).
#  11   await: COUNTERPART-FINISHED — the skeptic-pending marker was
#       observed live and has since been removed, which `ng wrap-up
#       --skeptic-role` does the instant it records a verdict. The
#       reviewer is done but never ran `close`, so no DONE will ever
#       arrive. Distinct from 4 (timed out — the wait may still be
#       meaningful) and from 10 (the skeptic closed the channel
#       deliberately). Read the verdict from the skeptic's report and
#       proceed; do NOT re-enter await (your-org/nexus-code#615).
#  10   await: DONE sentinel present AND newer than the task's pending
#       marker (or no marker) — the skeptic closed the channel for THIS
#       round; stop looping and proceed to retire. A DONE older than the
#       marker is a prior round's and is ignored (await keeps waiting).
#
# State dir resolution mirrors monitor/ng + paste-followup.sh:
#   NEXUS_STATE_DIR → NEXUS_ROOT/monitor/.state → config nexus.root →
#   script-relative fallback.

set -uo pipefail

# ARGUMENT-LOOP PROGRESS GUARD (your-org/nexus-code#924). Each argument loop
# below asserts that every iteration consumes at least one argument. Without it
# a value-taking flag given LAST spins forever — `shift 2` with `$#` == 1 is
# refused, so the arm re-matches — and a hang here is worse than an error
# because nothing on this board surfaces it. Full rationale: monitor/ng.
_argloop_stuck() {
    printf '%s: option %s requires a value (argument loop made no progress)\n' \
        "${0##*/}" "${1-}" >&2
    exit 64
}

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# The argv-property parser the await lock's ownership check needs
# (your-org/nexus-code#1426). SOFT at load, HARD at use: fixtures across the
# suite copy this script alone into a bare directory, and a start-time refusal
# broke every verb for them; what must never run without the parser is the
# KILL, so `_await_pid_is_ours` refuses to vouch for any pid when the library
# is absent (default-deny — nothing is reaped) and says why.
_PROC_ARGV_MISSING=0
if [[ -r "$_script_dir/_proc_argv.sh" ]]; then
    # shellcheck source=monitor/_proc_argv.sh
    . "$_script_dir/_proc_argv.sh" || _PROC_ARGV_MISSING=1
else
    _PROC_ARGV_MISSING=1
fi

# your-org/nexus-code#941 — the window-key encoder lives in ONE place. A
# second transcription of a key function is how `a.b` and `a_b` came to share
# a state file; a writer and a reader disagreeing about the key is the same
# defect wearing a different hat. Absence is fatal rather than silently
# falling back to the lossy form: a fallback would put the two spellings back
# in the tree at exactly the moment nobody is watching.
if [[ -r "$_script_dir/_bookkeeping.sh" ]]; then
    # shellcheck source=monitor/_bookkeeping.sh
    source "$_script_dir/_bookkeeping.sh"
else
    printf '%s: cannot source %s/_bookkeeping.sh (the window-key encoder) — refusing\n' \
        "${BASH_SOURCE[0]##*/}" "$_script_dir" >&2
    exit 2
fi

die()  { printf 'skeptic-channel: %s\n' "$*" >&2; exit 1; }

# ---- your-org/nexus-code#906 R1 (diagnostic axis) -------------------------
#
# A bare token that does not start with `-` is NOT an unknown flag — it is an
# unexpected POSITIONAL, and saying "unknown flag" sends the reader hunting a
# flag name that was never the problem, at the exact moment they got the call
# shape wrong and most needed to be told what was actually wrong.
#
# It must also not ECHO THE WHOLE TOKEN. Measured in ordinary orchestration:
# `ng request reply <id> "<900-char message>"` printed the entire message back
# as a flag name. Same family as #858 C, where a multi-line body embedded in a
# diagnostic survived a `| tail -1` and read as a plausible value.
_arg_excerpt() {   # <token> → first line, excerpted, dropped-line count named
    local v="${1-}" first nl bytes
    first="${v%%$'\n'*}"
    # BYTE-capped, trimmed on a CHARACTER boundary (your-org/nexus-code#906).
    # Three axes, and only the third is the property:
    #   #858 C capped LINES   → a 900-char SINGLE-line token walked through
    #   the first #906 cut capped CHARACTERS → still a proxy; 72 multi-byte
    #                                          characters is 219 bytes
    #   this caps BYTES       → what "do not swamp the diagnostic" means
    # Character-boundary trimming is why the char cap comes first: slicing at
    # a byte offset would split a multi-byte character into mojibake, so the
    # loop removes whole characters until the byte budget is met.
    (( ${#first} > 72 )) && first="${first:0:72}"
    while (( ${#first} > 1 )); do
        bytes=$(LC_ALL=C printf '%s' "$first" | wc -c)
        (( bytes <= 96 )) && break
        first="${first:0:$(( ${#first} - 4 ))}"
    done
    # Ellipsis iff the excerpt is shorter than the line it came from. One
    # condition, because the two-clause version this replaced could in
    # principle append twice and only testing showed it did not.
    [[ "$first" != "${v%%$'\n'*}" ]] && first="${first}…"
    nl="${v//[^$'\n']/}"
    if (( ${#nl} > 0 )); then
        printf "'%s' (+%d more line(s))" "$first" "${#nl}"
    else
        printf "'%s'" "$first"
    fi
}

# <verb> <token> [<what they probably wanted>]
_die_positional() {
    local verb="$1" tok="$2" hint="${3:-}"
    local msg="$verb: unexpected POSITIONAL argument $(_arg_excerpt "$tok")"
    if [[ -n "$hint" ]]; then msg+=" — did you mean $hint?"; else msg+="."; fi
    die "$msg Flags must start with --; positionals are matched in order."
}
warn() { printf 'skeptic-channel: %s\n' "$*" >&2; }

_resolve_state_dir() {
    if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
        printf '%s' "$NEXUS_STATE_DIR"; return 0
    fi
    if [[ -n "${NEXUS_ROOT:-}" ]]; then
        printf '%s/monitor/.state' "$NEXUS_ROOT"; return 0
    fi
    local cfg_root=""
    if [[ -x "$_script_dir/../config/load.sh" ]]; then
        cfg_root=$("$_script_dir/../config/load.sh" nexus.root 2>/dev/null) || cfg_root=""
    fi
    if [[ -n "$cfg_root" ]]; then
        printf '%s/monitor/.state' "$cfg_root"; return 0
    fi
    printf '%s/.state' "$_script_dir"
}

STATE_DIR="$(_resolve_state_dir)"
# HANDED DOWN (your-org/nexus-code#1335): every `ng log-action` this file
# spawns reads NEXUS_STATE_DIR, so the resolved dir must reach the child or
# a correctly scoped test writes its audit rows into the operator's live log.
export NEXUS_STATE_DIR="$STATE_DIR"
SKEPTIC_ROOT="$STATE_DIR/skeptic"
PENDING_DIR="$SKEPTIC_ROOT/pending"

# Sanitize a task-id / window name into a safe directory component.
# Same rule spawn-worker.sh uses for window-keyed state files.
_safe() { wk_encode "${1-}"; }

_now_iso() { date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }

# Read a config int with an env override. $1=config-key $2=env-name
# $3=default. Mirrors ng's _skeptic_cfg_int so the knobs stay in sync.
_cfg_int() {
    local key="$1" env_name="$2" def="$3" val=""
    val="${!env_name:-}"
    if [[ -z "$val" && -x "$_script_dir/../config/load.sh" ]]; then
        val=$("$_script_dir/../config/load.sh" "$key" "$def" 2>/dev/null) || val=""
    fi
    [[ "$val" =~ ^[0-9]+$ ]] || val="$def"
    printf '%s' "$val"
}

# Resolve a tmux window NAME to its window index. pane-state.sh is
# INDEX-keyed (it takes `<window-index|session:window>`, never a name);
# handing it a name makes it exit non-zero with an empty `state=`, which
# silently disables the nudge's busy/user-typing guard — the inert-guard
# defect this resolves. Prints the index on stdout (rc 0); rc 1 when the
# name cannot be resolved (no tmux, or no matching window) so the caller
# FAILS SAFE and skips the nudge rather than pasting blind into a pane
# whose state it cannot read.
#
# SKEPTIC_WINDOW_INDEX is a test seam: the hermetic suite has no live
# tmux window matching its synthetic task names, so it injects the index
# directly to exercise the name→index contract against the stub.
_resolve_window_index() {
    local name="$1"
    if [[ -n "${SKEPTIC_WINDOW_INDEX:-}" ]]; then
        printf '%s' "$SKEPTIC_WINDOW_INDEX"; return 0
    fi
    command -v tmux >/dev/null 2>&1 || return 1
    local idx
    # ENVIRON[], not `awk -v n=…`: `awk -v x=VAL` ESCAPE-PROCESSES VAL
    # (your-org/nexus-code#1405). This is the SECOND site of that class in this
    # file, and it is not body text — it is a tmux window NAME arriving
    # unvalidated from `nudge <worker-window>`, `notify-delta <skeptic-window>`
    # and `reconcile --window W`. Measured on this host against a two-window
    # fixture (`a\b` at index 3, `a\\b` at index 7):
    #
    #   awk -v n='a\b'   -> NO MATCH  (rc 0, empty)  -> resolver rc 1 -> nudge SKIPPED
    #   awk -v n='a\\b'  -> index 3   (the OTHER window)
    #   ENVIRON form     -> 3 and 7 respectively — correct both ways
    #
    # The miss direction is benign by construction: the caller FAILS SAFE and
    # skips. The MATCH direction is not. `_wake_gate` reads pane state of the
    # index this returns, but `paste-followup.sh` is handed the window NAME —
    # so a mis-resolution evaluates one window's guard and pastes into
    # another, re-creating the inert-guard defect this resolver exists to
    # prevent, and it can steamroll a `user-typing` operator.
    #
    # `|`-separated on BOTH sides (your-org/nexus-code#1410): under awk's
    # DEFAULT field splitting a window name containing a SPACE compared only
    # its first word against `$2`, so `foo bar` matched a window named `foo`
    # — the same wrong-window outcome by a different mechanism (field
    # splitting, not escape interpretation). `|`, not a tab: in a non-UTF-8
    # locale with $TMUX unset tmux rewrites a tab to `_` and the row never
    # splits (test-tmux-window-resolver F1); `|` is printable, and
    # `validate_window_name` forbids it inside a minted name — the same
    # delimiter `_tmux-window.sh` uses (`_TMUX_WINDOW_DELIM`).
    # The export sits in a SUBSHELL rather than as an inline `VAR=… awk` prefix
    # on the pipeline element, and that is not style. `early-exit-readers.sh`
    # classifies this site as an `awk-exit` reader by matching the pipeline
    # element, so an inline prefix takes the element out of its view: the first
    # cut of this fix silently DROPPED
    # `monitor/skeptic-channel.sh awk-exit prod 1` from
    # `early-exit-readers.manifest` while the early-exit reader was still there.
    # A fix that makes a live site invisible to its own guard is worse than no
    # fix; `test-early-exit-reader-manifest.sh` is what caught it.
    idx=$(
        export _SKC_WNAME="$name"
        tmux list-windows -F '#{window_index}|#{window_name}' 2>/dev/null \
            | awk 'BEGIN { FS = sprintf("%c", 124); n = ENVIRON["_SKC_WNAME"] } $2 == n { print $1; exit }'   # 124 is `|`: NO literal pipe in the program text, so early-exit-readers.sh still sees ONE awk-exit element (#1415)
    )
    [[ -n "$idx" ]] || return 1
    printf '%s' "$idx"
}

# ===========================================================================
# THE TASK KEY IS MINTED HERE, SO IT IS VALIDATED HERE
# (your-org/nexus-code#961; measured on the primary 2026-08-28)
# ===========================================================================
#
# `wk_encode` is an ENCODER, not a validator, and it does its job perfectly:
# it is injective and it contains traversal (`../escape` becomes the literal
# `%2E%2E%2Fescape`, measured — nothing escapes `$SKEPTIC_ROOT`). What it will
# also do, just as faithfully, is encode GARBAGE into a brand-new task key.
#
# Measured on the operator's live state dir: of 578 task directories, four are
# not window names at all — `--help` (a DIRECTORY, created 2026-08-07, carrying
# a live `.await-heartbeat`), the bare integer `272` (an ISSUE number in a
# window-name slot), and two stray `.await.log` / `.await.out` FILES sitting at
# task-dir level. Reproduced against this code: `init --help`, `init --target`,
# `init 272` and `init pending` all exit 0 and mint a directory.
#
# WHY THIS IS #961 AND NOT A SEPARATE TIDINESS BUG. #961 is "presence and
# absence are both uninformative". A key minted from whatever argv happened to
# contain is that failure with the corpus POLLUTED rather than merely
# ambiguous: a typo or a shifted argument silently forks a task's state into a
# key nothing will ever read, and its absence from the real key is
# indistinguishable from "no obligation exists". No amount of correct re-keying
# repairs that while the key is still unvalidated — which is why the fix has to
# be at the mint, not at the read.
#
# `pending` is the sharpest of them and is not in the issue: `PENDING_DIR` IS
# `$SKEPTIC_ROOT/pending`, so a task by that name mints its channel directory
# ON TOP OF THE MARKER STORE (measured: identical paths). Its `DONE` sentinel
# then sits in `pending/` where a marker lookup reads it as the live obligation
# of a window called `DONE`.
#
# ── THE GRAMMAR, AND WHAT IT DELIBERATELY STILL ADMITS ────────────────────
#
# REFUSED, because none of these can be a tmux window name in this workspace:
#   leading `-`   a flag leaked into a positional slot   (`--help`, `--target`)
#   leading `.`   collides with the reserved `.<label>` wake-stamp directories
#                 and the `.<key>.ledger` / `.cleared-rationale` sidecars
#   contains `/`  a path fragment, i.e. a shifted argument
#   `pending`     IS the marker store
#
# ADMITTED, and named rather than silently covered: an ALL-NUMERIC key. `272`
# is an issue number in the wrong slot, but a tmux window may legitimately be
# named `272`, and this grammar cannot separate the two from bytes alone. So it
# is not refused, and the coverage boundary is that one word: this stops keys
# that are not window-shaped, not keys that are the wrong window.
#
# Enforced in `_channel_dir` and `_pending_marker` — the two choke points every
# read and every write goes through — so a polluted key already on disk becomes
# a LOUD refusal naming itself, rather than something the verbs keep quietly
# operating on.
_valid_task_key() {
    local t="${1-}"
    case "$t" in
        "")        printf 'empty';                              return 1 ;;
        -*)        printf 'starts with `-` (a FLAG in a task-id slot)'; return 1 ;;
        */*)       printf 'contains `/` (a path fragment, not a window name)'; return 1 ;;
        .*)        printf 'starts with `.` (reserved for wake-stamp dirs and ledger sidecars)'; return 1 ;;
        pending)   printf '`pending` IS the skeptic marker store, not a task';  return 1 ;;
    esac
    return 0
}

# _die_bad_task_key <verb-context> <task-id>
_die_bad_task_key() {
    local why; why=$(_valid_task_key "$2")
    die "refusing to use $(_arg_excerpt "$2") as a task-id — it $why.
  A task-id is a TMUX WINDOW NAME. This is refused at the point the key is minted
  because an accepted one creates state under a key nothing will ever read, and its
  absence from the REAL key is indistinguishable from \"no obligation exists\"
  (your-org/nexus-code#961). Four such keys are on the operator's live state dir,
  one of them a directory literally named \`--help\` carrying an await heartbeat.
  If this came from a flag, the flag is in the wrong position."
}

# _require_valid_task_key <task-id> — THE GATE, IN THE MAIN SHELL
# (your-org/nexus-code#1371). `_channel_dir` and `_pending_marker` validate
# too, and that validation GATES NOTHING: every caller captures them with
# `dir=$(_channel_dir "$task")`, so their `die` exits the SUBSTITUTION's
# subshell, the refusal lands on stderr, and the verb carries on with an empty
# string — a refused key is byte-identical to an empty channel at rc 0.
# Measured at bbf8985b: 20 capture sites, 6 refused keys live on the store.
# This is the #1339 class (a fail-closed guard reachable only from inside
# `$( )`), and the fix is the one that file prescribes: hoist the gate into
# the verb's main shell and keep the in-function check as defence in depth.
# Called immediately before each capture below, so the gate and the capture
# sit on adjacent lines and a future site copied from any of them carries it.
_require_valid_task_key() {
    _valid_task_key "${1-}" >/dev/null || _die_bad_task_key main-shell "${1-}"
}

_channel_dir() {
    _valid_task_key "$1" >/dev/null || _die_bad_task_key _channel_dir "$1"
    local task; task=$(_safe "$1")
    printf '%s/%s' "$SKEPTIC_ROOT" "$task"
}

_done_sentinel() { printf '%s/DONE' "$(_channel_dir "$1")"; }

_pending_marker() {
    _valid_task_key "$1" >/dev/null || _die_bad_task_key _pending_marker "$1"
    printf '%s/%s' "$PENDING_DIR" "$(_safe "$1")"
}

# Read a --file / --message / stdin body into stdout. Shared by ask
# and answer. Args after the positional ones are passed in.
_read_body() {
    local file="" text="" have_dash=0
    _argloop_prev_1=-1; while (( $# > 0 )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
        case "$1" in
            --file)    file="${2:-}";    shift 2 || die "--file needs a path" ;;
            --message) text="${2:-}";    shift 2 || die "--message needs text" ;;
            -)         have_dash=1;      shift ;;
            *)         die "unexpected argument: $(_arg_excerpt "$1")" ;;
        esac
    done
    if [[ -n "$file" && -n "$text" ]]; then
        die "--file and --message are mutually exclusive"
    fi
    if [[ -n "$file" ]]; then
        [[ -r "$file" ]] || die "cannot read --file: $file"
        cat -- "$file"
    elif [[ -n "$text" ]]; then
        printf '%s' "$text"
    elif (( have_dash )) || [[ ! -t 0 ]]; then
        cat
    else
        die "no body: pass --file <p>, --message <t>, or pipe to stdin"
    fi
}

# Resolve a <req> token (number / stem / filename) to an absolute path
# under the channel dir. Prefers the EARLIEST-lifecycle match so an
# `answer` of a request that the worker has acked targets the .ack.md
# (then .open.md as a fallback for a direct answer), and a generic
# lookup still finds an already-answered request. Prints path on stdout,
# rc 0; rc 2 if nothing matches.
# _require_safe_req <req> — a <req> is a NUMBER, a STEM or a FILENAME inside
# the channel; never a path (your-org/nexus-code#1411). `_resolve_reqfile`
# joins it to the channel dir with `[[ -f "$dir/$req" ]]`, so a `../<other>/
# req-001-x.ack.md` resolved — and `answer` then RENAMED — a request under a
# DIFFERENT worker's channel. The task key is guarded by `_valid_task_key`;
# this is the same guard for the second positional, in the main shell.
_require_safe_req() {
    case "${1-}" in
        */*)  die "refusing <req> $(_arg_excerpt "$1") — it contains \`/\`: a <req> names a request INSIDE the channel (a number, a stem or a filename), never a path" ;;
        ..*)  die "refusing <req> $(_arg_excerpt "$1") — it starts with \`..\`" ;;
        -*)   die "refusing <req> $(_arg_excerpt "$1") — it starts with \`-\` (a FLAG in the <req> slot)" ;;
    esac
}

_resolve_reqfile() {
    local dir="$1" req="$2" hit=""
    [[ -d "$dir" ]] || return 2
    # Exact filename (caller passed req-003-foo.<state>.md).
    if [[ -f "$dir/$req" ]]; then printf '%s' "$dir/$req"; return 0; fi
    # Bare number → zero-pad to NNN and glob the prefix.
    local stem="$req"
    if [[ "$req" =~ ^[0-9]+$ ]]; then
        stem=$(printf 'req-%03d-' "$((10#$req))")
    fi
    # Prefer .ack (the canonical answer source) then .open (direct
    # answer) then .answered (read), then any.
    local f
    for f in "$dir/${stem}"*.ack.md "$dir/${stem}".ack.md \
             "$dir/${stem}"*.open.md "$dir/${stem}".open.md \
             "$dir/${stem}"*.answered.md "$dir/${stem}".answered.md \
             "$dir/${stem}"*.md "$dir/${stem}"*; do
        [[ -e "$f" ]] || continue
        hit="$f"; break
    done
    [[ -n "$hit" ]] || return 2
    printf '%s' "$hit"
}

# Next zero-padded request number for a channel dir (max existing + 1).
_next_req_num() {
    local dir="$1" max=0 n base
    local f
    for f in "$dir"/req-*.md; do
        [[ -e "$f" ]] || continue
        base=$(basename -- "$f")
        n=${base#req-}; n=${n%%-*}
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        n=$((10#$n))
        (( n > max )) && max=$n
    done
    printf '%03d' "$((max + 1))"
}

# Refresh the parked-awaiting-skeptic heartbeat for a task: touch the
# worker's skeptic-pending marker (the signal the watcher keys on) and a
# per-task .await-heartbeat. Best-effort; never fails the caller. The
# marker is only TOUCHED, never created — its creation is ng wrap-up's
# job (the require gate), its deletion is the verdict's. `touch -c`
# (--no-create) is load-bearing: the verdict's `rm -f` of the marker can
# land while this heartbeat is mid-flight (the worker is still in `await`
# — the skeptic's `close`/DONE comes only AFTER the verdict rm), so a
# plain `touch` would lose the `[[ -e ]]` TOCTOU race and RECREATE the
# just-cleared marker. A recreated marker would then block retirement
# indefinitely (retire-preflight check 1b tests existence, not mtime).
# `-c` makes the recreate impossible regardless of the race outcome; the
# `[[ -e ]]` guard is kept only to skip the syscall in the common case.
_await_heartbeat() {
    local task="$1" dir="$2"
    _require_valid_task_key "$task"
    local marker; marker=$(_pending_marker "$task")
    [[ -e "$marker" ]] && touch -c "$marker" 2>/dev/null || true
    date +%s > "$dir/.await-heartbeat" 2>/dev/null || true
}

# ---- await singleton: reap the prior waiter before arming a new one ------
#
# your-org/nexus-code#615. `await` is bounded by --timeout, but a worker
# re-enters it on every turn (the worker floor instructs exactly that),
# and nothing reaped the PREVIOUS still-blocked waiter. Observed on
# `kompot-spikeguard`: FIVE concurrent `skeptic-channel.sh await` on one
# channel, arriving ~1/min, none exited, all `S`. Unbounded in principle
# — one per worker turn, ~60/hour — and the stacked shells are counted
# by `bg_shells`, so a leak volume was being read as worker liveness
# (it drove a spurious `wrapped-with-children` whose advice was to close
# the window).
#
# The invariant: ONE live waiter per (worker, channel), enforced rather
# than assumed.
#
# HOW THE PRIOR WAITER IS IDENTIFIED — and why not by pattern. A pkill /
# pgrep by script basename is the wrong instrument here: a read-only
# pgrep on a script basename once matched, and a companion pkill then
# killed, four unrelated production services. So we never search for
# processes. We kill ONLY a pid this script itself recorded in
# `<channel>/.await-owner`, and only after re-reading /proc to confirm
# that pid is still an `await` for THIS task. If /proc is unreadable, or
# the cmdline does not match, we leave it alone and simply take
# ownership — a stale record must never authorise a kill.
_await_owner_file() { printf '%s/.await-owner' "$1"; }

# True iff <pid> is, right now, a `skeptic-channel.sh await <task>`.
# Reads /proc/<pid>/cmdline (NUL-separated). Any doubt → false.
# BY ARGV POSITION, NEVER BY SUBSTRING (your-org/nexus-code#1426). The first
# form accepted any pid whose whole cmdline CONTAINED "skeptic-channel.sh",
# " await " and " <task>" anywhere — and a `claude` process's argv IS its
# prompt, so a sibling agent briefed about this await satisfied all three and
# `_await_claim_singleton` would have sent it `kill -TERM`. The shared parser
# asks the question of word POSITIONS (monitor/_proc_argv.sh, the same
# definition the idle probe's n_await uses), so a mention in an argument
# position never matches and an await for a DIFFERENT task never matches.
# THE RECORD CARRIES AN IDENTITY, NOT JUST A NAME (your-org/nexus-code#1426,
# residual 1b). `.await-owner` holds `<pid> <starttime>` — field 22 of
# /proc/<pid>/stat, written by the claiming process about ITSELF — and the
# ownership question is answered by pid AND start-time AND argv position. A
# recycled pid carries a different start-time and is refused outright; a
# record with no start-time (a pre-#1426 file, or a hand-edited one) has no
# identity and is refused too, because a pid alone is a name.
_await_pid_is_ours() {
    local pid="$1" task="$2" want="${3-}"
    # `${_PROC_ARGV_MISSING:-1}`: extracted alone (test-bookkeeping-contract.sh
    # evals this function by its sed range under `set -u`), the load-time flag
    # is unset — and unset means the parser was never sourced, so the answer is
    # the default-deny one, not an unbound-variable abort.
    if (( ${_PROC_ARGV_MISSING:-1} )) || ! declare -F proc_pid_is_skeptic_await >/dev/null 2>&1; then
        printf 'skeptic-channel: await: monitor/_proc_argv.sh is not loaded — cannot establish that pid %s is an await for %s, so it is NOT treated as ours and nothing is reaped (your-org/nexus-code#1426)\n' "${pid:-?}" "${task:-?}" >&2
        return 1
    fi
    if ! declare -F proc_pid_is_skeptic_await_identity >/dev/null 2>&1; then
        printf 'skeptic-channel: await: monitor/_proc_argv.sh predates the identity check — pid %s is NOT treated as ours (your-org/nexus-code#1426)\n' "${pid:-?}" >&2
        return 1
    fi
    proc_pid_is_skeptic_await_identity "$pid" "$task" "$want"
}

# _await_read_owner <owner-file> — prints `<pid> <starttime>`; either may be
# empty. Tolerates the pre-#1426 one-field form (start-time then empty, so the
# identity check refuses it rather than guessing).
_await_read_owner() {
    local line pid st
    line=$(head -1 "$1" 2>/dev/null) || line=""
    read -r pid st _ <<<"$line"
    pid="${pid//[!0-9]/}"; st="${st//[!0-9]/}"
    printf '%s %s' "$pid" "$st"
}

# _await_write_owner <owner-file> — record OURSELVES with our identity.
_await_write_owner() {
    local st=""
    declare -F proc_pid_starttime >/dev/null 2>&1 && st=$(proc_pid_starttime "$$" 2>/dev/null)
    printf '%s %s\n' "$$" "$st" > "$1" 2>/dev/null || true
}

# Reap the recorded prior waiter (if any, if still ours), then record
# ourselves as the owner. Best-effort throughout: failing to reap must
# never stop this await from running, or a transient /proc hiccup would
# strand the worker.
_await_claim_singleton() {
    local task="$1" dir="$2"
    local owner_file prior
    owner_file=$(_await_owner_file "$dir")
    local prior_st="" pka="" pka_rc=""
    if [[ -r "$owner_file" ]]; then
        read -r prior prior_st <<<"$(_await_read_owner "$owner_file")"
        if [[ -n "$prior" ]] && (( prior != $$ )) && _await_pid_is_ours "$prior" "$task" "$prior_st"; then
            # THE KILL IS ROUTED THROUGH `proc-kill-authorized` (#1426 residual
            # 3) and its verdict is RECORDED beside the displacement. It is an
            # advisory here rather than a veto, for a reason measured on this
            # board: the prescribed way to run an await is a Monitor or a
            # BACKGROUNDED Bash call, which makes the waiter its own SESSION
            # LEADER — so a session-ownership scan refuses precisely the normal
            # case (`not-owned` is ambiguous between "a sibling's" and "yours,
            # but it left your session"; worker floor). What authorises the
            # signal is the channel's OWN record: the victim wrote its pid AND
            # start-time into `.await-owner` about itself, and both — plus argv
            # position — were just re-verified against /proc. That is identity,
            # not a name. The verdict still travels with the row so an operator
            # reading `.await-displaced` sees which authority spoke.
            if [[ -x "$_script_dir/proc-kill-authorized" ]]; then
                pka=$("$_script_dir/proc-kill-authorized" "$prior" 2>&1 | tr '\n' ' '); pka_rc=$?
                pka="pka=${pka_rc}:${pka:0:80}"
            else
                pka="pka=absent"
            fi
            # ORDER IS LOAD-BEARING (your-org/nexus-code#1178): claim the owner
            # record and leave the durable note BEFORE the signal, so the
            # victim's TERM handler can NAME us, and so the channel keeps an
            # artefact on the DISPLACED party's side rather than only in the
            # survivor's stderr.
            _await_write_owner "$owner_file"
            printf 'ts=%s victim=%s displacer=%s task=%s victim-start=%s authority=await-owner-record %s\n' \
                "$(date +%s)" "$prior" "$$" "$task" "$prior_st" "$pka" >> "$dir/.await-displaced" 2>/dev/null || true
            kill -TERM "$prior" 2>/dev/null || true
            warn "reaped prior await (pid $prior, start-time $prior_st) on task $task before arming a new one (#615: one live waiter per channel; $pka)"
        elif [[ -n "$prior" ]] && (( prior != $$ )) && [[ -z "$prior_st" ]] && [[ -r "/proc/$prior/cmdline" ]]; then
            warn "prior owner record for task $task names pid $prior WITHOUT a start-time (pre-#1426 record) — identity cannot be established, so it is NOT reaped; taking ownership alongside it"
        fi
    fi
    _await_write_owner "$owner_file"
}

# TERM handler for a live `await` (your-org/nexus-code#1178). A DISPLACED
# waiter used to die of an UNTRAPPED SIGTERM: exit 143 — a code the await
# contract does not document — with an EMPTY output file, the explanation
# landing only in the SURVIVOR's stderr, read up to `--timeout` (default 900s)
# later. Here the victim reports on its OWN stderr and exits 12 (DISPLACED,
# documented).
#
# A TERM that is NOT a displacement — an operator `kill`, a `timeout` wrapper —
# must still behave exactly as before, so the handler re-raises the default
# disposition and keeps 143. Measured both ways: displacement 12 with 153 bytes
# naming the displacer; operator TERM 143 with 0 bytes.
#
# THE DURABLE RECORD DECIDES, THE LIVENESS PROBE ONLY STRENGTHENS IT
# (your-org/nexus-code#1360). The first cut gated `exit 12` on
# `_await_pid_is_ours "$owner"`, which begins `[[ -r /proc/<pid>/cmdline ]]` —
# a LIVENESS probe. The displacer writes `.await-owner` and the
# `.await-displaced` row BEFORE it signals, in an order the reaper's own
# comment calls load-bearing "so the victim's TERM handler can NAME us" — and
# then the handler consulted neither, re-deriving displacement from a process
# the fixture explicitly permits to have exited (its displacer is `--timeout
# 3`). Any handler latency past that — trap deferral behind a foreground
# child, a stall under load — and the probe returned 1, the fallback arm ran,
# and the victim died at 143 with an EMPTY stderr: the exact outcome #1178
# was filed to abolish, 3 in 40 CI bands, always the same three assertions.
# Displacement needs the displacer to have CLAIMED, not to still be alive:
# an owner record naming a pid that is not us, corroborated by a
# `.await-displaced` row naming US as the victim, is that claim. The
# discriminating control is untouched — an operator `kill` or a `timeout`
# wrapper writes neither record and still reaches the default 143.
_await_term_handler() {
    local dir="${_AWAIT_DIR:-}" owner="" owner_st="" displaced=0
    if [[ -n "$dir" && -r "$dir/.await-owner" ]]; then
        read -r owner owner_st <<<"$(_await_read_owner "$dir/.await-owner")"
    fi
    if [[ -n "$owner" ]] && (( owner != $$ )); then
        if _await_pid_is_ours "$owner" "${_AWAIT_TASK:-}" "$owner_st"; then
            displaced=1
        elif [[ -r "$dir/.await-displaced" ]] \
             && grep -q -- " victim=$$ displacer=$owner " <<<"$(cat "$dir/.await-displaced" 2>/dev/null)"; then
            displaced=1
        fi
    fi
    if (( displaced )); then
        warn "DISPLACED: a newer await (pid $owner) claimed task ${_AWAIT_TASK:-} on this channel; that one is live — do NOT re-arm (your-org/nexus-code#1178)"
        exit 12
    fi
    trap - TERM
    kill -TERM $$
}

# Release ownership on the way out, but ONLY if we still hold it — a
# successor that already claimed the channel must not have its record
# deleted by our exit.
_await_release_singleton() {
    local dir="${1:-}" owner_file cur
    [[ -n "$dir" ]] || return 0
    owner_file=$(_await_owner_file "$dir")
    [[ -r "$owner_file" ]] || return 0
    read -r cur _ <<<"$(_await_read_owner "$owner_file")"
    [[ "$cur" == "$$" ]] && rm -f "$owner_file" 2>/dev/null
    return 0
}

# Stamp a WORKER-side skeptic-channel action (ack / answer) into the
# machine-input ledger ($STATE_DIR/machine-input.tsv), the SAME ledger
# paste-followup.sh writes and the watcher's attribution + retire-preflight
# read. Why: when a worker ANSWERS a skeptic question (or acks a request),
# its pane activity around that moment must not be misread as a fresh
# OPERATOR submit. retire-preflight.sh check 2 flags a UserPromptSubmit as
# operator-engaged only when it is newer than every known machine input by
# more than the attribution slack; an unstamped channel exchange therefore
# looked like a human submit and falsely pinned the window open for the
# full ~600s freshness window (the recurring `operator-engaged` blocker on
# parked workers/skeptics). Stamping the channel action as machine input
# closes that gap through the EXISTING reader — no attribution-rule change.
#
# Scope is deliberately a DISCRETE per-action stamp (one row per ack/answer),
# never a continuous refresh: a continuous machine-input stamp while parked
# would also swallow a genuine operator submit (a false NEGATIVE — never
# retire a worker the operator is driving). A real operator submit lands
# with NO nearby channel action, so it still trips the gate.
#
# The window column is the RAW task-id (the worker's tmux window name), so
# it matches retire-preflight's `$1 == w` lookup (w = the raw window name);
# the `_safe` sanitization governs DIRECTORY names only, not this column.
_stamp_machine_input() {
    local window="$1" src="$2"
    [[ -n "$window" && -n "$src" ]] || return 0
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    # Column 2 is MICROSECONDS since your-org/nexus-code#679, matching
    # paste-followup.sh and _lib.sh's _machine_input_stamp. This writer's
    # rows feed retire-preflight's `$1 == w` lookup, which takes a MAX
    # across every src token, so a seconds row here mixed with
    # microsecond rows elsewhere would make this writer's stamps
    # permanently lose that max — silently disabling exactly the
    # retirement gate the comment above says these rows exist to trip.
    local _mi_epoch
    _mi_epoch=$(date +%s%6N 2>/dev/null)
    [[ "$_mi_epoch" =~ ^[0-9]{16,}$ ]] || _mi_epoch=$(( $(date +%s) * 1000000 ))
    printf '%s\t%s\t%s\n' "$window" "$_mi_epoch" "$src" \
        >> "$STATE_DIR/machine-input.tsv" 2>/dev/null || true
}

cmd_init() {
    local task="${1:-}"; [[ -n "$task" ]] || die "usage: init <task-id>"
    _require_valid_task_key "$task"
    local dir; dir=$(_channel_dir "$task")
    mkdir -p "$dir" || die "cannot create channel dir: $dir"
    printf '%s\n' "$dir"
}

cmd_dir() {
    local task="${1:-}"; [[ -n "$task" ]] || die "usage: dir <task-id>"
    _require_valid_task_key "$task"
    printf '%s\n' "$(_channel_dir "$task")"
}

cmd_reqfile() {
    local task="${1:-}" req="${2:-}"
    [[ -n "$task" && -n "$req" ]] || die "usage: reqfile <task-id> <req>"
    _require_safe_req "$req"
    _require_valid_task_key "$task"
    local dir path; dir=$(_channel_dir "$task")
    if ! path=$(_resolve_reqfile "$dir" "$req"); then
        printf 'skeptic-channel: no request matching %q in %s\n' "$req" "$dir" >&2
        exit 2
    fi
    printf '%s\n' "$path"
}

cmd_ask() {
    local task="${1:-}" slug="${2:-}"
    [[ -n "$task" && -n "$slug" ]] || die "usage: ask <task-id> <slug> [--file f|--message t|-]"
    shift 2
    local body; body=$(_read_body "$@") || exit 1
    [[ -n "${body//[[:space:]]/}" ]] || die "ask: request body is empty"
    local safe_slug; safe_slug=$(_safe "$slug")
    _require_valid_task_key "$task"
    local dir; dir=$(_channel_dir "$task")
    mkdir -p "$dir" || die "cannot create channel dir: $dir"
    local num; num=$(_next_req_num "$dir")
    local path="$dir/req-${num}-${safe_slug}.open.md"
    # Atomic publish: write a temp in the same dir, then rename into the
    # terminal .open.md name. The worker's await only ever sees a fully
    # written request — never a partial mid-write.
    local tmp; tmp=$(mktemp "$dir/.req-${num}.XXXXXX") || die "ask: mktemp failed"
    {
        printf -- '---\n'
        printf 'skeptic-request: %s\n' "$num"
        printf 'task-id: %s\n' "$task"
        printf 'slug: %s\n' "$safe_slug"
        printf 'state: open\n'
        printf 'created: %s\n' "$(_now_iso)"
        printf -- '---\n\n'
        printf '## Skeptic request\n\n'
        printf '%s\n\n' "$body"
        printf '## Worker response\n\n'
        printf '_(awaiting — the worker acks via `await` (rename to `.ack.md`), then appends its answer here and renames to `.answered.md`)_\n'
    } > "$tmp" || { rm -f "$tmp"; die "ask: cannot write request file"; }
    mv -f "$tmp" "$path" || { rm -f "$tmp"; die "ask: publish rename failed: $path"; }
    printf '%s\n' "$path"
}

cmd_poll() {
    local task=""
    local state=open
    _argloop_prev_2=-1; while (( $# > 0 )); do (( $# != _argloop_prev_2 )) || _argloop_stuck "$1"; _argloop_prev_2=$#
        case "$1" in
            --state) state="${2:-}"; shift 2 || die "--state needs a value" ;;
            --*) die "unknown flag: $(_arg_excerpt "$1")" ;;
            *)  if [[ -z "$task" ]]; then task="$1"
                else _die_positional "poll" "$1"; fi
                shift ;;
        esac
    done
    [[ -n "$task" ]] || die "usage: poll <task-id> [--state open|ack|answered|all]"
    _require_valid_task_key "$task"
    local dir; dir=$(_channel_dir "$task")
    [[ -d "$dir" ]] || return 0   # no channel yet → nothing pending
    local -a globs=()
    case "$state" in
        open)     globs=("$dir"/*.open.md) ;;
        ack)      globs=("$dir"/*.ack.md) ;;
        answered) globs=("$dir"/*.answered.md) ;;
        all)      globs=("$dir"/req-*.md) ;;
        *) die "--state must be open|ack|answered|all" ;;
    esac
    local f
    for f in "${globs[@]}"; do
        [[ -e "$f" ]] || continue
        printf '%s\n' "$f"
    done
}

cmd_status() {
    local task="${1:-}"; [[ -n "$task" ]] || die "usage: status <task-id>"
    _require_valid_task_key "$task"
    local dir; dir=$(_channel_dir "$task")
    local open=0 ack=0 answered=0 done=0 f
    if [[ -d "$dir" ]]; then
        for f in "$dir"/*.open.md;     do [[ -e "$f" ]] && open=$((open+1)); done
        for f in "$dir"/*.ack.md;      do [[ -e "$f" ]] && ack=$((ack+1)); done
        for f in "$dir"/*.answered.md; do [[ -e "$f" ]] && answered=$((answered+1)); done
        [[ -e "$dir/DONE" ]] && done=1
    fi
    printf 'open=%d ack=%d answered=%d total=%d done=%d\n' \
        "$open" "$ack" "$answered" "$((open+ack+answered))" "$done"
}

cmd_list() {
    local task="${1:-}"; [[ -n "$task" ]] || die "usage: list <task-id>"
    _require_valid_task_key "$task"
    local dir; dir=$(_channel_dir "$task")
    if [[ ! -d "$dir" ]]; then
        printf 'no channel for task %q (%s)\n' "$task" "$dir"
        return 0
    fi
    printf 'channel: %s\n' "$dir"
    [[ -e "$dir/DONE" ]] && printf '  [%-8s] %s\n' "DONE" "(skeptic closed the channel)"
    local f base state
    for f in "$dir"/req-*.md; do
        [[ -e "$f" ]] || continue
        base=$(basename -- "$f")
        case "$base" in
            *.open.md)     state="OPEN" ;;
            *.ack.md)      state="ack" ;;
            *.answered.md) state="answered" ;;
            *)             state="?" ;;
        esac
        printf '  [%-8s] %s\n' "$state" "$base"
    done
    # your-org/nexus-code#1434 remedy 1 — say it where it is read: this tree is
    # PRUNED at retirement. A count over live channels is a count of survivors.
    printf '  (channels move to %s/.archive/<task>.<reason>-<ts>/ when their window is retired or the round is reset; a survey over live channels is a survey of survivors)\n' "$SKEPTIC_ROOT"
}

# await — WORKER-side blocking ack-loop. Polls the channel on a short
# interval. On the first poll that finds one or more *.open.md, it ACKS
# each (atomic rename .open.md → .ack.md) — the rename is the signal the
# skeptic's reconcile watches for — prints the acked paths, and EXITS 0
# so the worker agent regains control to answer them. A DONE sentinel
# (dropped by the skeptic's `close`) exits 10: stop looping, retire.
# Times out (exit 4) after --timeout so a single call is bounded; the
# worker re-enters await (the floor instructs this) which re-heartbeats.
# The re-entry presumes the worker is RE-INVOKED when this call exits —
# true under the Bash tool's `run_in_background`, false under
# `monitor/async-run.sh`, which retains the rc and wakes nobody
# (your-org/nexus-code#1523). Every site that prescribes the loop names
# that launch; the canonical statement is the worker floor's "A retained
# exit status is not an armed wake".
cmd_await() {
    local task=""
    local timeout interval once=0
    timeout=$(_cfg_int monitor.skeptic.await_timeout_seconds MONITOR_SKEPTIC_AWAIT_TIMEOUT_SECONDS 900)
    interval=$(_cfg_int monitor.skeptic.await_interval_seconds MONITOR_SKEPTIC_AWAIT_INTERVAL_SECONDS 5)
    _argloop_prev_3=-1; while (( $# > 0 )); do (( $# != _argloop_prev_3 )) || _argloop_stuck "$1"; _argloop_prev_3=$#
        case "$1" in
            --timeout)  timeout="${2:-}";  shift 2 || die "--timeout needs seconds" ;;
            --interval) interval="${2:-}"; shift 2 || die "--interval needs seconds" ;;
            --once)     once=1;            shift ;;
            --*) die "unknown flag: $(_arg_excerpt "$1")" ;;
            *)  if [[ -z "$task" ]]; then task="$1"
                else _die_positional "await" "$1"; fi
                shift ;;
        esac
    done
    [[ -n "$task" ]] || die "usage: await <task-id> [--timeout S] [--interval S] [--once]"
    [[ "$timeout"  =~ ^[0-9]+$ ]] || die "--timeout must be an integer"
    [[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || die "--interval must be a positive integer"
    _require_valid_task_key "$task"
    local dir; dir=$(_channel_dir "$task")
    mkdir -p "$dir" 2>/dev/null || true
    local sentinel; sentinel=$(_done_sentinel "$task")
    _require_valid_task_key "$task"
    local marker;   marker=$(_pending_marker "$task")
    # #615: one live waiter per (worker, channel). Reap the prior one
    # before arming, and drop our record on every exit path.
    _await_claim_singleton "$task" "$dir"
    # The trap body runs at SCRIPT exit, in the top-level scope — `dir`
    # is `local` to this function and is long gone by then, so a naive
    # `"$dir"` there is an unbound-variable error under `set -u`. Stash
    # it in a global the trap can actually see.
    _AWAIT_DIR="$dir"
    _AWAIT_TASK="$task"
    trap '_await_release_singleton "${_AWAIT_DIR:-}"' EXIT
    trap '_await_term_handler' TERM
    # Did the pending marker EXIST while we were waiting? Its later
    # disappearance is the signal that the verdict returned (see the
    # counterpart-finished check below) — but only if we ever saw it.
    # A worker that enters await with no marker at all was never parked
    # on anything, and must not read that absence as a resolution.
    local marker_seen=0
    [[ -e "$marker" ]] && marker_seen=1
    local waited=0 f acked stale_warned=0
    while :; do
        # Terminal: THE COUNTERPART FINISHED (your-org/nexus-code#615).
        #
        # `ng wrap-up --skeptic-role` removes the pending marker the
        # instant a verdict is recorded — that removal IS the gate's own
        # statement that the required validation happened. The skeptic's
        # `close` (which drops DONE) is a SEPARATE, later, and entirely
        # optional act, so a skeptic that delivers a verdict and goes
        # idle without closing left the worker blocked forever.
        #
        # Observed: `kompot-sg3-skeptic` delivered its verdict at
        # 20:50:53 and went idle; `kompot-spikeguard` was still stacking
        # awaits at 23:32 on a channel holding nothing but a
        # `.await-heartbeat` it was refreshing itself. The heartbeat
        # proved THE WAITER was alive and was then read as evidence THE
        # WAIT was meaningful — different properties. This check makes
        # the wait's validity depend on the counterpart, which is the
        # only thing that can actually end it.
        #
        # Distinct, loud exit code (11) so a caller can tell "your
        # reviewer finished" apart from "timed out" (4) and from "the
        # reviewer closed the channel" (10).
        if (( marker_seen == 1 )) && [[ ! -e "$marker" ]]; then
            printf 'COUNTERPART-FINISHED\n'
            printf 'skeptic-channel: the skeptic-pending marker for task %s is gone — the reviewing skeptic recorded its verdict (confirm with `ng skeptic-evidence`; marker absence alone is not proof) (ng wrap-up --skeptic-role clears the marker) without closing the channel. Ending the wait: nothing further can arrive on it. Read the verdict in the skeptic'"'"'s report, then proceed to retire.\n' \
            "$task" >&2
            printf '  Marker ABSENCE is not by itself proof a verdict was recorded for THIS task —\n' >&2
            printf '  any one verdict clears the one marker (your-org/nexus-code#961). Confirm with\n' >&2
            printf '  `monitor/ng skeptic-evidence %s` before treating the pass as done.\n' "$task" >&2
            return 11
        fi
        [[ -e "$marker" ]] && marker_seen=1
        # Terminal: DEFERRED (your-org/nexus-code#845 claim H). The skeptic
        # (or orchestrator) released THIS WAIT without discharging the
        # requirement: the pending marker is untouched, so retirement stays
        # gated; the worker reads reason/until, acts, and re-enters await.
        # The record is consumed here so one defer releases exactly one wait.
        if [[ -e "$dir/.await-deferred" ]]; then
            local _defer_rec; _defer_rec=$(cat "$dir/.await-deferred" 2>/dev/null)
            rm -f "$dir/.await-deferred" 2>/dev/null || true
            printf 'DEFERRED\n'
            printf 'skeptic-channel: the wait on task %s was DEFERRED — the review is NOT done and the pending marker %s. Act on the reason, then RE-ENTER await.\n  %s\n' \
                "$task" "$([[ -e "$marker" ]] && echo 'still gates your retirement' || echo 'is absent')" "$_defer_rec" >&2
            return 13
        fi
        # Terminal: the skeptic closed the channel FOR THIS ROUND.
        #
        # `close` is the only writer of DONE, and it also removes the
        # pending marker. `ng wrap-up --skeptic-decision require` is the
        # only writer of the marker, and it opens a NEW round. So a DONE
        # that is OLDER than the marker is a prior round's verdict, and
        # accepting it retires a worker that no skeptic ever revalidated
        # — the gate reporting success without having run (issue #469).
        # Treat a stale DONE as absent and keep waiting: fail CLOSED.
        #
        # `-nt` is true when the sentinel exists and the marker does not,
        # which is the normal terminal shape (close removed the marker),
        # so the ordinary first-round path is unchanged. Checking before
        # _await_heartbeat is load-bearing: the heartbeat touches the
        # marker, and doing that first would push the marker's mtime past
        # a just-written DONE during close's create-then-unlink window.
        if [[ -e "$sentinel" ]]; then
            if [[ "$sentinel" -nt "$marker" ]]; then
                printf 'DONE\n'
                return 10
            fi
            if (( stale_warned == 0 )); then
                printf 'skeptic-channel: DONE for task %s is older than its pending marker — a prior round'"'"'s verdict, not this one'"'"'s. Ignoring it and waiting for a real close.\n' \
                    "$task" >&2
                stale_warned=1
            fi
        fi
        _await_heartbeat "$task" "$dir"
        # Ack every currently-open request atomically.
        acked=0
        for f in "$dir"/*.open.md; do
            [[ -e "$f" ]] || continue
            local ack="${f%.open.md}.ack.md"
            if mv -f "$f" "$ack" 2>/dev/null; then
                printf '%s\n' "$ack"
                acked=$((acked+1))
            fi
        done
        if (( acked > 0 )); then
            # Protocol activity, not operator engagement: stamp the ledger
            # so a UserPromptSubmit around this ack is attributed to the
            # skeptic exchange, not misread as a fresh operator submit
            # (retire-preflight check 2). See _stamp_machine_input.
            _stamp_machine_input "$task" "skeptic-await-ack"
            return 0
        fi
        (( once )) && return 4
        (( waited >= timeout )) && break
        # `sleep & wait` rather than a bare sleep (your-org/nexus-code#1178):
        # bash defers a trapped signal until the FOREGROUND child returns, so a
        # bare sleep delays the TERM handler by up to `--interval` — measured
        # 2.788s of a 5s sleep. That is a window in which #615's ONE-live-waiter
        # invariant is violated and the dying waiter could still ack a request.
        # Interrupting a `wait` fires the trap in ~13ms (measured).
        # `|| true` because an interrupted `wait` returns non-zero under
        # `set -uo pipefail`.
        sleep "$interval" & wait $! || true
        waited=$((waited + interval))
    done
    printf 'skeptic-channel: await timed out after %ds with no open request and no DONE (task %s); re-enter await — launched through the Bash tool'\''s run_in_background, which re-invokes you when it exits; async-run.sh retains the rc and wakes nobody (your-org/nexus-code#1523)\n' \
        "$timeout" "$(_arg_excerpt "$task")" >&2
    return 4
}

cmd_answer() {
    local task="${1:-}" req="${2:-}"
    [[ -n "$task" && -n "$req" ]] || die "usage: answer <task-id> <req> [--file f|--message t|-]"
    _require_safe_req "$req"
    shift 2
    local body; body=$(_read_body "$@") || exit 1
    [[ -n "${body//[[:space:]]/}" ]] || die "answer: response body is empty"
    _require_valid_task_key "$task"
    local dir; dir=$(_channel_dir "$task")
    local src
    if ! src=$(_resolve_reqfile "$dir" "$req"); then
        printf 'skeptic-channel: no request matching %q in %s\n' "$req" "$dir" >&2
        exit 2
    fi
    # Canonical source is .ack.md (the worker acked via await). A direct
    # answer of an un-acked .open.md is also accepted (it implicitly acks
    # — both transition to .answered.md).
    local src_state=""
    case "$src" in
        *.answered.md) die "answer: request already answered: $(basename -- "$src") (one answer per request; ask a follow-up with a new slug)" ;;
        *.ack.md)  src_state=ack ;;
        *.open.md) src_state=open ;;
        *) die "answer: not an answerable request file: $src" ;;
    esac
    # Append the response: strip the awaiting placeholder line, flip the
    # frontmatter state, stamp answered, then drop the worker's reply
    # under the response marker. Build into a temp then rename .ack.md /
    # .open.md → .answered.md (the rename is the completion signal).
    local dst="${src%.${src_state}.md}.answered.md"
    local tmp; tmp=$(mktemp "${dst}.XXXXXX") || die "answer: mktemp failed"
    # The BODY is appended by `printf '%s'` in OPERAND position and never
    # reaches awk (your-org/nexus-code#1405). `awk -v x=VAL` ESCAPE-PROCESSES
    # VAL, and the loud/silent split is the worst available one: `\d` warns on
    # stderr while `\n`, `\t` and a `\`-newline line continuation are consumed
    # SILENTLY at rc 0 — so the escapes that merely alter a token complain and
    # the ones that destroy STRUCTURE do not. A worker's answer is the durable,
    # machine-read record `reconcile` and the orphan detectors consult; nothing
    # ever re-reads it against a source, so the corruption is terminal. Two
    # measured artefacts: `grep -vP '^\d+:\s*#'` landed as `^d+:s*#` (a
    # STRICTLY WEAKER predicate — a corruption that self-deprecates reads as an
    # honest admission and is accepted as written), and a three-line
    # `find … \` / `| xargs …` pipeline landed as one unrunnable line with the
    # backslashes left behind. `--file` does NOT protect: this is downstream of
    # the file read, inside the tool, not the shell layer #1157 is about.
    #
    # Shape, deliberately: this is now byte-for-byte the same construction
    # `cmd_ask` has always used for the REQUEST body (`printf '%s\n\n'`), so a
    # reader can see at a glance that BOTH body writes are operand-position and
    # neither interpolates. `ts` stays in `-v` because it is an internal ISO
    # timestamp from `_now_iso`, not user text — the hazard is the VALUE's
    # provenance, not the flag.
    local ts; ts=$(_now_iso)
    {
        awk -v ts="$ts" '
            BEGIN { in_fm=0 }
            NR==1 && $0=="---" { in_fm=1; print; next }
            in_fm && $0=="---" { in_fm=0; print "answered: " ts; print; next }
            in_fm && /^state:[[:space:]]/ { print "state: answered"; next }
            # Drop the awaiting placeholder; the appended answer replaces it.
            /^_\(awaiting/ { next }
            { print }
        ' "$src" && printf '\n%s\n' "$body"
    } > "$tmp" || { rm -f "$tmp"; die "answer: failed to compose response"; }
    mv -f "$tmp" "$dst" || { rm -f "$tmp"; die "answer: rename to $dst failed"; }
    rm -f "$src" 2>/dev/null || true
    # Worker answering a skeptic question is protocol activity, not operator
    # engagement: stamp the machine-input ledger so retire-preflight check 2
    # does not misattribute a nearby UserPromptSubmit to the operator.
    _stamp_machine_input "$task" "skeptic-answer"
    printf '%s\n' "$dst"
}

# await-answer — SKEPTIC-side: block until a specific request lands its
# *.answered.md, then print the path. Distinct from the worker's `await`
# (which waits for *.open.md to ack). Timeout → exit 4.
cmd_await_answer() {
    local task=""
    local req=""
    local timeout=600 interval=5
    _argloop_prev_4=-1; while (( $# > 0 )); do (( $# != _argloop_prev_4 )) || _argloop_stuck "$1"; _argloop_prev_4=$#
        case "$1" in
            --timeout)  timeout="${2:-}";  shift 2 || die "--timeout needs seconds" ;;
            --interval) interval="${2:-}"; shift 2 || die "--interval needs seconds" ;;
            --*) die "unknown flag: $(_arg_excerpt "$1")" ;;
            *)  if [[ -z "$task" ]]; then task="$1"
                elif [[ -z "$req" ]]; then req="$1"
                else _die_positional "await-answer" "$1"; fi
                shift ;;
        esac
    done
    [[ -n "$task" && -n "$req" ]] || die "usage: await-answer <task-id> <req> [--timeout S] [--interval S]"
    [[ "$timeout"  =~ ^[0-9]+$ ]] || die "--timeout must be an integer"
    [[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || die "--interval must be a positive integer"
    _require_valid_task_key "$task"
    local dir; dir=$(_channel_dir "$task")
    local stem="$req"
    if [[ "$req" =~ ^[0-9]+$ ]]; then stem=$(printf 'req-%03d-' "$((10#$req))"); fi
    local waited=0 f
    while :; do
        for f in "$dir/${stem}"*.answered.md "$dir/$req"; do
            [[ -e "$f" && "$f" == *.answered.md ]] && { printf '%s\n' "$f"; return 0; }
        done
        (( waited >= timeout )) && break
        sleep "$interval"
        waited=$((waited + interval))
    done
    printf 'skeptic-channel: await-answer timed out after %ds waiting for an answer to %q (task %s)\n' \
        "$timeout" "$req" "$task" >&2
    return 4
}

# reconcile — SKEPTIC-side wrap loop. Ensures every request the skeptic
# filed has progressed past .open.md (acked or answered). For any still
# .open.md past a grace period it NUDGES the worker (reusing the fixed
# name→index pane-state guard in cmd_nudge — a busy/user-typing pane is
# never steamrolled; a gone window fails safe). Returns 0 when all are
# acked/answered. Bounded: after --max-iter iterations it FAILS LOUD
# (exit 6) listing the un-acked requests so the skeptic reports an
# orphaned worker as a finding rather than hanging forever.
cmd_reconcile() {
    local task=""
    local window="" grace=30 interval=15 max_iter=20 min_interval=120 do_nudge=1
    _argloop_prev_5=-1; while (( $# > 0 )); do (( $# != _argloop_prev_5 )) || _argloop_stuck "$1"; _argloop_prev_5=$#
        case "$1" in
            --window)       window="${2:-}";       shift 2 || die "--window needs a value" ;;
            --grace)        grace="${2:-}";         shift 2 || die "--grace needs seconds" ;;
            --interval)     interval="${2:-}";      shift 2 || die "--interval needs seconds" ;;
            --max-iter)     max_iter="${2:-}";      shift 2 || die "--max-iter needs a count" ;;
            --min-interval) min_interval="${2:-}";  shift 2 || die "--min-interval needs seconds" ;;
            --no-nudge)     do_nudge=0;             shift ;;
            --*) die "unknown flag: $(_arg_excerpt "$1")" ;;
            *)  if [[ -z "$task" ]]; then task="$1"
                else _die_positional "reconcile" "$1"; fi
                shift ;;
        esac
    done
    [[ -n "$task" ]] || die "usage: reconcile <task-id> [--window W] [--grace S] [--interval S] [--max-iter N] [--min-interval S] [--no-nudge]"
    [[ -n "$window" ]] || window="$task"
    local v
    for v in grace interval max_iter min_interval; do
        [[ "${!v}" =~ ^[0-9]+$ ]] || die "--$v must be an integer"
    done
    [[ "$interval" -gt 0 ]] || die "--interval must be positive"
    _require_valid_task_key "$task"
    local dir; dir=$(_channel_dir "$task")
    if [[ ! -d "$dir" ]]; then
        printf 'reconcile: no channel for task %q — nothing filed, nothing to reconcile\n' "$task"
        return 0
    fi
    local iter=0 elapsed=0 open_count f
    while (( iter < max_iter )); do
        sleep "$interval"
        elapsed=$((elapsed + interval))
        open_count=0
        for f in "$dir"/*.open.md; do [[ -e "$f" ]] && open_count=$((open_count+1)); done
        if (( open_count == 0 )); then
            printf 'reconcile: all requests for task %s are acked/answered\n' "$task"
            return 0
        fi
        # Some still .open.md. Past the grace, nudge the worker.
        if (( do_nudge )) && (( elapsed >= grace )); then
            cmd_nudge "$window" --task "$task" --min-interval "$min_interval" >/dev/null 2>&1 || true
        fi
        iter=$((iter+1))
    done
    # Bound exhausted with requests still un-acked — fail loud.
    printf 'skeptic-channel: reconcile gave up after %d iterations (~%ds); task %s has %d un-acked request(s):\n' \
        "$max_iter" "$elapsed" "$task" "$open_count" >&2
    for f in "$dir"/*.open.md; do
        [[ -e "$f" ]] && printf '  - %s\n' "$(basename -- "$f")" >&2
    done
    printf 'skeptic-channel: the worker never acked — report this as a finding (do NOT block on it).\n' >&2
    return 6
}

# close — SKEPTIC-side: drop the DONE sentinel so the worker's await
# loop exits 10 and the worker can retire. Atomic temp+rename;
# idempotent.
#
# ALSO clears the worker's skeptic-pending marker. The gate's purpose
# (an independent verdict exists) is satisfied the instant the skeptic
# closes the channel — closure is the terminal "validation complete"
# signal (the recursion path explicitly does NOT close mid-chain; only
# the FINAL skeptic closes). Previously the marker's removal depended on
# the worker still being live in its await loop OR on the verdict-posting
# wrap-up running with a matching --skeptic-target; if the worker had
# stalled/idled, or the channel was closed after it moved on, the marker
# persisted forever → the window showed `parked-awaiting-skeptic` (exempt
# + counted busy) indefinitely, even after its PR merged. Clearing it
# here makes closure sufficient, independent of the worker's liveness.
# `touch -c` in _await_heartbeat guarantees a racing await poll cannot
# recreate the just-removed marker.
cmd_close() {
    local task="${1:-}"; [[ -n "$task" ]] || die "usage: close <task-id>"
    _require_valid_task_key "$task"
    local dir; dir=$(_channel_dir "$task")
    mkdir -p "$dir" || die "close: cannot create channel dir: $dir"
    local sentinel="$dir/DONE"
    local tmp; tmp=$(mktemp "$dir/.DONE.XXXXXX") || die "close: mktemp failed"
    {
        printf 'skeptic-channel: closed by reconcile/close\n'
        printf 'task-id: %s\n' "$task"
        printf 'closed: %s\n' "$(_now_iso)"
    } > "$tmp" || { rm -f "$tmp"; die "close: cannot write sentinel"; }
    mv -f "$tmp" "$sentinel" || { rm -f "$tmp"; die "close: publish rename failed: $sentinel"; }
    # Clear the pending marker — closure means a verdict exists, so the
    # require-gate is satisfied regardless of whether the worker is still
    # in its await loop to process the DONE sentinel.
    #
    # ORDER IS LOAD-BEARING (issue #469): publish DONE first, unlink the
    # marker second. await treats DONE-newer-than-marker as terminal, so
    # this order leaves the channel terminal at every instant in between.
    # Reversed, a crash after the unlink would leave no marker and no DONE
    # — retire-preflight would see no pending gate and let the worker
    # retire unvalidated. Fail closed on a partial close, not open.
    # AND RELEASE THE LEDGER, OR `close` BECOMES A BRICK
    # (your-org/nexus-code#961, operator report 2026-08-28).
    #
    # `close` already removes the pending MARKER — it is the protocol's own
    # end-of-pairing signal and under the pre-#961 contract that WAS the
    # release. Since the ledger became authoritative for what a window owes by
    # task, a `close` that touched only the marker would leave the two records
    # of one obligation DISAGREEING: marker gone, artefact still outstanding,
    # `retire-preflight` refusing forever with nothing left to clear it.
    #
    # Measured before this line existed: marker absent, DONE present,
    # `retire-preflight` still `safe=0 … 1 artefact(s) armed … no recorded
    # resolution`, rc 1. That is precisely the operator-reported shape — two
    # window-keyed records of one obligation, and the verb named `close`
    # leaving the gating one untouched — reproduced INSIDE the fix for it.
    #
    # So the ledger is released here for exactly the same reason and with
    # exactly the same authority the marker is. Written BEFORE the unlink, on
    # #469's ordering logic: an interruption must never leave the marker gone
    # and the release unrecorded, which is the fail-OPEN direction.
    local _cl_ledger="$PENDING_DIR/.$(_safe "$task").ledger"
    if [[ -e "$_cl_ledger" ]]; then
        printf 'resolved\t-\t%s\t%s\t%s\n' "$(_now_iso)" \
            "skeptic-channel.sh close" "channel closed by the reviewer (end of pairing)" \
            >> "$_cl_ledger" 2>/dev/null \
            || warn "close: could not append the release to $_cl_ledger"
    fi
    _require_valid_task_key "$task"
    rm -f "$(_pending_marker "$task")" 2>/dev/null || true
    printf '%s\n' "$sentinel"
}


# _res_evidence_note <task> — say so when the ledger holds a SUPERSEDED verdict.
#
# `ng skeptic resolve` used to contemplate exactly two situations: declining a
# report's `disposition: second-pass`, or clearing a marker. An orchestrator
# resolving the `clmd` case (your-org/nexus-code#1156) is doing NEITHER — the
# ledger holds TWO real verdicts from one reviewer on one target, and the later,
# stronger one could not attach because publishing it moved the report's content
# hash off the arm. Recording that as "declined" or "no marker" puts a false
# statement on the audit trail, which is the same objection `#1132` makes about
# recording a COMPLETED pass as declined.
#
# Purely advisory: it prints, it never decides, and every way of failing to look
# prints nothing rather than a guess.
_res_evidence_note() {
    local _task="${1:-}" _ng="$_script_dir/ng" _line="" _sup="" _st="" _at=""
    [[ -n "$_task" && -x "$_ng" ]] || return 0
    # `--state-dir "$STATE_DIR"` explicitly: this script resolves its own state
    # dir (`_resolve_state_dir`), and letting `ng` resolve a DIFFERENT one would
    # read some other tree's ledger for a task of the same name — an advisory
    # note about the wrong file. The sibling `skeptic-obligations` call omits it
    # and is a latent instance of the same thing.
    _line=$(timeout "${SKEPTIC_RESOLVE_DISPOSITION_TIMEOUT:-60}" \
        "$_ng" skeptic-evidence "$_task" --state-dir "$STATE_DIR" 2>/dev/null \
        | sed -n '1p') || return 0
    [[ -n "$_line" ]] || return 0
    _sup=$(sed -n 's/.*[[:space:]]superseded=\([^[:space:]][^[:space:]]*\).*/\1/p' <<<"$_line")
    [[ "$_sup" == "1" ]] || return 0
    _st=$(sed -n 's/.*[[:space:]]standing_verdict=\([^[:space:]][^[:space:]]*\).*/\1/p' <<<"$_line")
    _at=$(sed -n 's/.*[[:space:]]attributed_verdict=\([^[:space:]][^[:space:]]*\).*/\1/p' <<<"$_line")
    printf '\n' >&2
    printf 'NOTE — this ledger holds a SUPERSEDED verdict (ng skeptic-evidence %s):\n' "$_task" >&2
    printf '  standing (LATER)  : %s\n' "${_st:-?}" >&2
    printf '  cleanly attributed: %s   <- SUPERSEDED; a reader taking this row gets it WRONG\n' "${_at:-?}" >&2
    printf '  Two discharges for one arm is a LEGITIMATE state, not a duplicate: a reviewer\n' >&2
    printf '  whose target landed a fix MID-REVIEW must re-derive against the new head and\n' >&2
    printf '  amend its report to publish that, which moves the hash off the arm. Neither\n' >&2
    printf '  "declined" nor "no marker" describes it — say the standing verdict in --reason.\n' >&2
}

# resolve <task-id> --reason "<why>" — the SANCTIONED way to clear a
# skeptic-pending marker that a returned verdict failed to clear
# (your-org/nexus-code#577).
#
# WHY THIS VERB EXISTS. The require-gate marker is cleared by exactly two
# writers: a skeptic's `--skeptic-role` wrap-up, and `close`. When a verdict
# exists but neither ran against THIS state dir, the marker is immortal:
# `retire-preflight` reports `safe=0 … required skeptic has not returned a
# verdict` forever, and the window can never be retired by the sanctioned path.
# The #577 incident is the canonical case (a skeptic spawned from a secondary
# clone logged its verdict into that clone's state dir), and the marker can also
# outlive its round when a worker re-runs `wrap-up --skeptic-decision require`
# after a verdict has already come back.
#
# The operator's only remaining move was `rm` — a hand-clear of the very marker
# that exists to prevent hand-clearing. That is worse than no guard: it teaches
# the bypass. Four such hand-clears exist in this workspace's state dir, each
# with a hand-written `.<window>.cleared-rationale` file beside it. This verb
# adopts that convention as the mechanism: same file, same place, but with the
# authority check, the mandatory rationale, and the audit event that a bare `rm`
# cannot give.
#
# It is NOT `--skeptic-waive`. A waive says "no skeptic is required after all"
# and is recorded as a decision about the REQUIREMENT; `resolve` says "the
# required validation HAPPENED and here is where it landed" and is recorded as a
# statement about the EVIDENCE. Waive is also structurally unavailable here: it
# only ever clears the marker of the window whose wrap-up invokes it, so it can
# never release another window's gate.
#
# ORCHESTRATOR-ONLY, mirroring the waive guard: a worker must not be able to
# release its own required validation, so a set NEXUS_WORKER_WINDOW refuses.
cmd_resolve() {
    local task=""
    local reason="" disposition=0
    _argloop_prev_6=-1; while (( $# > 0 )); do (( $# != _argloop_prev_6 )) || _argloop_stuck "$1"; _argloop_prev_6=$#
        case "$1" in
            --reason) reason="${2:-}"; shift 2 || die "--reason needs text" ;;
            # your-org/nexus-code#813 — also release retire-preflight check
            # 1c's `disposition: second-pass` gate. That gate is armed by the
            # REPORT, not by a marker, so this is the one form of `resolve`
            # that must succeed with no marker on disk: the orchestrator has
            # adjudicated the request and declined it, and needs somewhere on
            # the record to say so. Without it the gate is a brick, and a
            # brick teaches the `rm` bypass this verb exists to replace.
            --disposition) disposition=1; shift ;;
            --*) die "unknown flag: $(_arg_excerpt "$1")" ;;
            *)  if [[ -z "$task" ]]; then task="$1"
                else _die_positional "resolve" "$1" "--reason"; fi
                shift ;;
        esac
    done
    [[ -n "$task" ]] || die "usage: resolve <task-id> --reason \"<why>\""
    if [[ -n "${NEXUS_WORKER_WINDOW:-}" ]]; then
        cat >&2 <<EOF
skeptic-channel: resolve is an OPERATOR/ORCHESTRATOR override and was invoked from
  inside a worker session (NEXUS_WORKER_WINDOW=$NEXUS_WORKER_WINDOW). A worker may
  not release its own required validation. If a verdict exists but the marker did
  not clear, file it for the orchestrator:
      ng request file --origin "$NEXUS_WORKER_WINDOW" --kind correction \\
          --slug skeptic-marker-stuck --reply required
EOF
        return 1
    fi
    # A rationale is the point of the verb: the whole failure mode is an
    # unaudited clear. Require something substantive, not a keystroke.
    if (( ${#reason} < 20 )); then
        die "resolve: --reason must be a substantive explanation (>=20 chars) naming WHERE the verdict is — it is written to the audit trail beside the marker"
    fi
    _require_valid_task_key "$task"
    local marker; marker=$(_pending_marker "$task")
    # LOOK AT THE THIRD GATE TOO (your-org/nexus-code#961). Since the ledger
    # became authoritative for what a window OWES BY TASK, "no marker" is no
    # longer even two-thirds of the question: a verdict that could not be
    # attributed clears the marker and leaves the artefact outstanding, which is
    # precisely the state an operator invokes this verb to adjudicate. Asking
    # `ng` rather than re-implementing the scan here is deliberate — a second
    # copy of this vocabulary is how `over-limit` once ended up permitted in the
    # kill gate while the skill said "do NOT close" (#603).
    local _res_owed=0 _res_ng_bin="$_script_dir/ng"
    if [[ -x "$_res_ng_bin" ]]; then
        timeout "${SKEPTIC_RESOLVE_DISPOSITION_TIMEOUT:-60}" \
            "$_res_ng_bin" skeptic-obligations "$task" >/dev/null 2>&1 || _res_owed=1
    fi
    if [[ ! -e "$marker" && $disposition -eq 0 && $_res_owed -eq 0 ]]; then
        # Nothing to clear. Fail loud rather than reporting success: a silent
        # no-op here would let `resolve` become a reflex incantation.
        #
        # BUT LOOK BEFORE ASSERTING (your-org/nexus-code#984, operator report
        # 2026-08-26). "nothing to resolve" is a NEGATIVE CLAIM ABOUT THE
        # OBLIGATION, and this arm used to make it having checked only ONE of
        # the two things that can arm a gate. The other is retire-preflight
        # check 1c, armed by the REPORT's `disposition: second-pass`
        # frontmatter and cleared by `--disposition` — so an orchestrator
        # holding a live, report-armed obligation was told, as the FIRST and
        # loudest line, that there was none. The correct invocation was named
        # two lines below, and the headline had already answered the question.
        #
        # A hint under a wrong headline is the wrong shape for a gate: the
        # reader who acts on the first line stops reading, and this workspace's
        # dominant defect class is exactly a confident negative asserted
        # without looking. So ASK. `ng skeptic-disposition` is the one parser
        # that owns this vocabulary (a second copy here is how `over-limit`
        # once ended up permitted in the kill gate while the skill said "do NOT
        # close", #603), it is a pure read, and it is bounded so a hung probe
        # cannot stall an interactive verb.
        #
        # Direction of doubt: a probe that could not run must NOT manufacture
        # the reassuring answer. `unknown`, a timeout and a missing `ng` all
        # fall to the same arm as `second-pass` — say that a gate MAY be armed
        # and name `--disposition`. This verb only ever RECORDS a release an
        # operator asked for; over-suggesting `--disposition` costs a rationale
        # nobody needed, under-suggesting it is what happened tonight.
        # The VALUE is read, never the pipeline's STATUS — deliberately.
        # `skeptic-disposition` exits 2 for `state=unknown`, which is a real
        # answer this arm handles, and under `pipefail` the status would be
        # `sed`'s anyway (CLAUDE.md's pipeline-status entry). Every way this
        # can fail — non-zero rc, no output, no `ng` — lands on the empty
        # string, which is in the doubt arm below.
        local _res_disp_state="" _res_ng="$_script_dir/ng"
        if [[ -x "$_res_ng" ]]; then
            _res_disp_state=$(timeout "${SKEPTIC_RESOLVE_DISPOSITION_TIMEOUT:-60}" \
                "$_res_ng" skeptic-disposition "$task" 2>/dev/null \
                | sed -n 's/.*state=\([a-z-]*\).*/\1/p')
        fi
        case "$_res_disp_state" in
            second-pass|unreadable|unknown|"")
                printf 'skeptic-channel: task %s has NO skeptic-pending marker (%s), but that is only\n' \
                    "$task" "$marker" >&2
                printf '  ONE of the two gates. The other is retire-preflight check 1c, armed by the\n' >&2
                printf '  REPORT frontmatter, and for %s it currently reads: state=%s\n' \
                    "$task" "${_res_disp_state:-<probe did not run>}" >&2
                case "$_res_disp_state" in
                    second-pass) printf '  That gate IS ARMED — this window is asking for another pass.\n' >&2 ;;
                    unreadable)  printf '  That gate is armed by a disposition the parser could not resolve.\n' >&2 ;;
                    *)           printf '  The probe could not answer, which is doubt, not "no gate".\n' >&2 ;;
                esac
                printf '  Re-run with --disposition to decline it on the record:\n' >&2
                printf '      ng skeptic resolve %q --reason "<why no further pass>" --disposition\n' "$task" >&2
                printf '  (this run recorded NOTHING).\n' >&2
                return 1
                ;;
        esac
        printf 'skeptic-channel: no skeptic-pending marker for task %s (%s) — nothing to resolve (see `ng skeptic-evidence` for what the ledger holds).\n' \
            "$task" "$marker" >&2
        printf '  The report-armed gate (retire-preflight check 1c) was also checked and reads\n' >&2
        printf '  state=%s, so no obligation is outstanding for this task by either route.\n' "$_res_disp_state" >&2
        printf '  (if you are declining a report'"'"'s `disposition: second-pass` rather than\n' >&2
        printf '   clearing a marker, that gate is armed by the REPORT — pass --disposition.)\n' >&2
        # THOSE TWO ARE NOT EXHAUSTIVE, and saying so mattered: an orchestrator
        # resolving a SUPERSEDED-VERDICT case is doing neither, and this hint
        # implied it must be doing one of them (your-org/nexus-code#1156, the
        # `clmd` case). The third situation is the ledger holding TWO real
        # verdicts where the later one could not attach — a legitimate state,
        # not a duplicate.
        _res_evidence_note "$task"
        return 1
    fi
    mkdir -p "$PENDING_DIR" 2>/dev/null || true
    # your-org/nexus-code#813 skeptic F5 — capture this BEFORE the `rm` below.
    # The first draft re-tested `[[ -e "$marker" ]]` AFTER removing it, so the
    # branch could never be true and a real marker clear reported "no marker was
    # present". That lies to an orchestrator who has just invoked the verb that
    # exists to REPLACE a hand-`rm` — the single message most likely to send
    # them back to `rm`. Same false-cause class as the `SKIPPED (upload failed)`
    # line the sibling PR fixes in this same batch.
    local had_marker=0
    [[ -e "$marker" ]] && had_marker=1
    local rationale="$PENDING_DIR/.$(_safe "$task").cleared-rationale"
    {
        printf '# skeptic-pending marker resolved via `skeptic-channel resolve` (your-org/nexus-code#577)\n'
        printf 'task-id  : %s\n' "$task"
        printf 'resolved : %s\n' "$(_now_iso)"
        if (( had_marker )); then
            printf 'marker   : mtime %s\n' \
                "$(date -Is -r "$marker" 2>/dev/null || echo unknown)"
        else
            printf 'marker   : none (disposition-only release)\n'
        fi
        (( disposition )) && printf 'scope    : also releases retire-preflight check 1c (disposition: second-pass)\n'
        printf '\n%s\n' "$reason"
    } >> "$rationale" 2>/dev/null || warn "resolve: could not write rationale to $rationale"
    # AND RECORD IT WHERE THE KILL PATH LOOKS (your-org/nexus-code#961).
    #
    # `.cleared-rationale` is prose for a human and an mtime for check 1c. The
    # ledger is what `retire-preflight`'s per-task check reads, and before this
    # line `resolve` wrote nothing it could see — so an operator release would
    # have cleared the marker and left every outstanding artefact outstanding
    # FOREVER. That is a brick, and a brick teaches the `rm` bypass this verb
    # exists to replace. A `resolved` line closes the whole outstanding set,
    # which is the one window-keyed transition that is legitimate precisely
    # because a person signed it and had to type a reason to do so.
    local _res_ledger="$PENDING_DIR/.$(_safe "$task").ledger"
    if [[ -e "$_res_ledger" ]]; then
        printf 'resolved\t-\t%s\t%s\t%s\n' "$(_now_iso)" \
            "skeptic-channel.sh resolve" "${reason//[$'\t\n']/ }" \
            >> "$_res_ledger" 2>/dev/null \
            || warn "resolve: could not append the release to $_res_ledger"
    fi
    if (( had_marker )); then
        rm -f "$marker" 2>/dev/null || die "resolve: could not remove marker: $marker"
    fi
    # The rationale's MTIME is what retire-preflight check 1c compares against
    # the report's, so it must post-date the report for the release to count.
    # `>>` already stamps now; this is stated because the comparison is remote
    # from the write and a future refactor to an atomic-rename write would
    # silently preserve an OLD mtime and make every release a no-op.
    # END THE PAIRING TOO (your-org/nexus-code#926 F5). `resolve` is an
    # ORCHESTRATOR saying, on the record, that this window's validation is
    # done — which is a statement about the PAIRING, not only about the
    # marker. Before #845 the obligation ledger did not exist; after it, a
    # release keyed on the marker (`void-creditor-clear`) voided such edges
    # promptly, and removing that release is what widened this exposure: a
    # resolved target would leave its reviewer blocked with no signal that
    # anything remained to do.
    #
    # Settling here keeps the release POSITIVE — an audited operator decision,
    # never an inference from an absent file — which is the property the #845
    # correction rests on. Every reviewer of THIS window is discharged; the
    # reason is carried through verbatim so the ledger and the rationale
    # record agree.
    if [[ -x "$_script_dir/obligations.sh" ]]; then
        ( "$_script_dir/obligations.sh" settle --creditor "$task" \
            --by "skeptic-channel.sh resolve" \
            --reason "orchestrator resolved $task's skeptic gate on the record: $reason" \
            ) >/dev/null 2>&1 || true
    fi
    "$_script_dir/ng" log-action monitor \
        --event skeptic-resolve \
        --extra "task=$task" \
        --extra "scope=$( (( disposition )) && printf 'marker+disposition' || printf 'marker' )" \
        --extra "reason=$reason" >/dev/null 2>&1 || true
    if (( had_marker )); then
        printf 'resolved skeptic-pending marker for %s\n' "$task"
    else
        printf 'recorded a disposition-only resolution for %s (no marker was present)\n' "$task"
    fi
    printf 'rationale appended: %s\n' "$rationale"
    _res_evidence_note "$task"
    (( disposition )) && printf 'retire-preflight check 1c (disposition: second-pass) is released for %s\n' "$task"
    printf 'the window can now be retired by the sanctioned path (retire-preflight).\n'
}

# reset <task-id> — open a NEW skeptic round cleanly by ARCHIVING the
# previous round's terminal sentinels (the DONE close-marker and every
# *.answered.md verdict) into <channel>/.stale-archive-<ts>/, rather than
# leaving them where a fresh `require` round could mistake them for its
# own. This is the archive-instead-of-rm upgrade of issue #469's guard 2
# (ng wrap-up's `required` branch previously just `rm`-ed the DONE): a
# clone that missed the fix let a prior fire's DONE survive and the retire
# gate then failed OPEN on the re-validation round — precisely the
# 2026-07 cc-auto-update incident (your-org/nexus-code#511). Archiving
# preserves the forensic trail that incident was reconstructed from, and
# sweeping the stale .answered.md verdicts too keeps `poll`/`status` and
# the next skeptic's view of the channel honest. It NEVER touches the
# pending marker or any open/ack request — those belong to the current
# round. Idempotent: a no-op (rc 0) when there is nothing stale to archive
# (fresh channel, or one already reset).
# defer <task-id> --reason "<why>" [--until "<condition>"]   SKEPTIC/ORCHESTRATOR
#
# your-org/nexus-code#845 claim H — SPLIT THE BIT. A parked worker and its
# idle skeptic each wait for the other; the only releases were `close` (DONE,
# exit 10) and a recorded verdict (marker gone, exit 11), and BOTH mean "the
# requirement is discharged, proceed to retire". There was no way to say "stop
# waiting, the review is NOT done, here is what still stands" — so a skeptic
# that needed the worker to do something first could only leave it parked.
# `defer` writes <channel>/.await-deferred and touches NOTHING else: the
# pending marker stays, so retire-preflight gate 1b keeps refusing (that is
# the point), and the worker's await exits 13 (DEFERRED) printing the reason
# and condition verbatim. The worker acts on them and RE-ENTERS await; the
# next `defer`, `close` or verdict decides again. Re-entering CONSUMES the
# record (await removes it on exit 13), so one defer releases one wait.
cmd_defer() {
    local task="${1:-}"; [[ -n "$task" ]] || die "usage: defer <task-id> --reason \"<why>\" [--until \"<condition>\"]"
    shift
    local reason="" until=""
    _argloop_prev_9=-1; while (( $# > 0 )); do (( $# != _argloop_prev_9 )) || _argloop_stuck "$1"; _argloop_prev_9=$#
        case "$1" in
            --reason) reason="${2:-}"; shift 2 || die "--reason needs text" ;;
            --until)  until="${2:-}";  shift 2 || die "--until needs text" ;;
            *) die "defer: unexpected argument: $(_arg_excerpt "$1")" ;;
        esac
    done
    [[ -n "${reason//[[:space:]]/}" ]] || die "defer: --reason is required — the worker is told WHY its wait is released while the requirement stands"
    case "$reason$until" in *$'\n'*) die "defer: --reason/--until are single-line" ;; esac
    _require_valid_task_key "$task"
    local dir; dir=$(_channel_dir "$task")
    [[ -d "$dir" ]] || die "defer: no channel for task $task (run: init $task)"
    _require_valid_task_key "$task"
    local marker; marker=$(_pending_marker "$task")
    printf 'ts=%s by=%s reason=%s until=%s\n' "$(_now_iso)" "${NEXUS_WORKER_WINDOW:-orchestrator}" "$reason" "${until:-unspecified}" \
        > "$dir/.await-deferred.tmp" && mv -f "$dir/.await-deferred.tmp" "$dir/.await-deferred" \
        || die "defer: cannot write $dir/.await-deferred"
    "$_script_dir/ng" log-action monitor \
        --event skeptic-defer \
        --extra "task=$task" \
        --extra "reason=$reason" \
        --extra "until=${until:-unspecified}" \
        --extra "marker=$([[ -e "$marker" ]] && printf present || printf absent)" >/dev/null 2>&1 || true
    printf 'deferred %s: the await will exit 13 (DEFERRED) with this reason; the pending marker is %s and retire-preflight keeps gating on it\n' \
        "$task" "$([[ -e "$marker" ]] && echo 'still present' || echo 'absent (nothing gates retirement; defer only releases the wait)')"
}

cmd_reset() {
    local task="${1:-}"; [[ -n "$task" ]] || die "usage: reset <task-id>"
    _require_valid_task_key "$task"
    local dir; dir=$(_channel_dir "$task")
    [[ -d "$dir" ]] || return 0
    # Terminal sentinels of a completed prior round: the DONE close-marker
    # and any answered verdicts. Same nullglob-safe pattern cmd_status uses.
    local -a stale=()
    [[ -e "$dir/DONE" ]] && stale+=("$dir/DONE")
    local f
    for f in "$dir"/*.answered.md; do [[ -e "$f" ]] && stale+=("$f"); done
    (( ${#stale[@]} )) || return 0
    local ts archive
    ts=$(date +%Y-%m-%dT%H%M%S 2>/dev/null || _now_iso)
    # OUTSIDE THE CHANNEL (your-org/nexus-code#1434). This used to archive into
    # `$dir/.stale-archive-<ts>`, i.e. INSIDE the directory `ng retire-window`
    # removes wholesale, so the archive died with the channel and the corpus
    # under skeptic/ was a corpus of SURVIVORS: a survey filed at 10:19 had
    # lost 2 of its 6 cited artefacts by 12:05. The sibling `.archive/` tree
    # is what retirement moves a channel INTO as well (bk_prune_window_state),
    # so nothing under skeptic/ is destroyed by ordinary operation any more.
    archive="$SKEPTIC_ROOT/.archive/$(_safe "$task").reset-$ts"
    mkdir -p "$archive" || die "reset: cannot create archive dir: $archive"
    for f in "${stale[@]}"; do
        mv -f "$f" "$archive/" 2>/dev/null || true
    done
    printf 'reset %s: archived %d stale sentinel(s) → %s\n' \
        "$task" "${#stale[@]}" "$archive"
}

# _wake_gate <window> <force> <min-interval> <label>
#
# The shared precondition for ANY machine paste into another agent's pane:
# rate-limit, then pane state. rc 0 → clear to paste; rc 1 → skip (the
# caller exits 5; the warn has already been printed here).
#
# EXTRACTED, not copied (your-org/nexus-code#845). There are now two wake
# directions — `nudge` (skeptic → target: you have open requests) and
# `notify-delta` (target → skeptic: I pushed a new round) — and a second
# transcription of this guard is precisely how `over-limit` ended up
# permitted in one copy of a state vocabulary and refused in the other
# (_bookkeeping.sh's opening argument). One gate, two callers.
#
# `label` only colours the diagnostics and the busy-skip machine-input
# stamp; the RULES are identical for both directions, deliberately. A
# reviewer's pane is not more interruptible than a worker's.
_wake_gate() {
    local window="$1" force="$2" min_interval="$3" label="$4"

    # Rate-limit. Per (label, window): the two directions are separate
    # conversations and one must not consume the other's budget.
    local stamp_dir="$SKEPTIC_ROOT/.$label"
    local stamp; stamp="$stamp_dir/$(_safe "$window")"
    mkdir -p "$stamp_dir" 2>/dev/null || true
    if (( force == 0 )) && [[ -f "$stamp" ]]; then
        local last now age
        last=$(cat "$stamp" 2>/dev/null || echo 0)
        now=$(date +%s)
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        age=$((now - last))
        if (( age < min_interval )); then
            warn "$label: last $label to $window was ${age}s ago (< ${min_interval}s); skipping (use --force to override)"
            return 1
        fi
    fi

    # Pane-state guard: only paste into an idle/absent pane. A busy agent
    # re-enters its own loop on its own turn; a user-typing pane belongs to
    # the operator. pane-state.sh emits `state=<...>`.
    # SKEPTIC_PANESTATE_BIN is a test seam (hermetic suite injects a stub).
    local ps_bin="${SKEPTIC_PANESTATE_BIN:-$_script_dir/pane-state.sh}" ps_state=""
    if (( force == 0 )) && [[ -x "$ps_bin" ]]; then
        # pane-state.sh is INDEX-keyed; resolve the window NAME → index
        # before probing. A name leaks through as an unresolved arg →
        # empty state → no skip → the guard is inert (the F1 defect).
        # If the index can't be resolved, FAIL SAFE: skip
        # rather than paste blind into a pane whose state is unknowable.
        local idx
        if ! idx=$(_resolve_window_index "$window"); then
            warn "$label: cannot resolve a tmux index for window $window — skipping (fail-safe; the pane state is unknowable; use --force to override)"
            return 1
        fi
        local ps_out; ps_out=$("$ps_bin" "$idx" 2>/dev/null || true)
        ps_state=$(sed -n 's/.*state=\([a-z-]*\).*/\1/p' <<<"$ps_out")
        case "$ps_state" in
            user-typing)
                # The OPERATOR is in the input box right now — never
                # steamroll, and never stamp (a stamp here would mask the
                # operator's own submit → false NEGATIVE).
                warn "$label: window $window is 'user-typing' — skipping (operator active; use --force to override)"
                return 1
                ;;
            busy|working-*)
                # The agent is doing work — almost always the protocol
                # itself. We DEFER delivery (it re-enters its own loop on
                # its own turn), but STAMP machine-input first (bug A;
                # live incident 2026-06-18). Under load the pane churns
                # and its UserPromptSubmit hook can fire while no paste
                # stamp covers it → the watcher mis-seeds a false
                # `operator-engaged` mark. Stamping on the busy-skip closes
                # that attribution gap so channel-driven pane I/O is
                # machine-attributed even when delivery is deferred.
                # user-typing is excluded above — that submit IS the
                # operator's and must still register.
                _stamp_machine_input "$window" "skeptic-$label-busy-skip"
                warn "$label: window $window is '$ps_state' — deferring delivery (agent active; stamped machine-input so the protocol churn is not mis-seeded as operator; use --force to override)"
                return 1
                ;;
        esac
    fi
    return 0
}

# _wake_stamp <window> <label> — record a successful delivery for the
# rate-limiter. Split from _wake_gate so a caller cannot accidentally stamp
# a delivery that never landed.
_wake_stamp() {
    local stamp_dir="$SKEPTIC_ROOT/.$2"
    mkdir -p "$stamp_dir" 2>/dev/null || true
    date +%s > "$stamp_dir/$(_safe "$1")" 2>/dev/null || true
}

# nudge: wake an idle worker that has pending requests. Reuses
# paste-followup.sh (the only correct way to inject machine input into
# a worker pane). Guards:
#   - resolves the worker's pane-state; skips a busy / user-typing pane
#     (the worker is active and will re-enter await on its own turn, or
#     the operator is typing — never steamroll either) unless --force.
#   - rate-limits per-window via a last-nudge stamp (default 120s).
cmd_nudge() {
    # Positionals and flags interleave (your-org/nexus-code#906 C). The
    # window is captured INSIDE the loop, so `nudge --task t <window>` parses
    # the same as `nudge <window> --task t`; `task` therefore defaults to the
    # window AFTER the loop, not before it.
    local window=""
    local task="" force=0 min_interval=120
    _argloop_prev_7=-1; while (( $# > 0 )); do (( $# != _argloop_prev_7 )) || _argloop_stuck "$1"; _argloop_prev_7=$#
        case "$1" in
            --task)         task="${2:-}";         shift 2 || die "--task needs a value" ;;
            --force)        force=1;               shift ;;
            --min-interval) min_interval="${2:-}"; shift 2 || die "--min-interval needs seconds" ;;
            --*) die "unknown flag: $(_arg_excerpt "$1")" ;;
            *)  if [[ -z "$window" ]]; then window="$1"
                else _die_positional "nudge" "$1" "--task"; fi
                shift ;;
        esac
    done
    [[ -n "$window" ]] || die "usage: nudge <worker-window> [--task <id>] [--force] [--min-interval S]"
    [[ -n "$task" ]] || task="$window"
    [[ "$min_interval" =~ ^[0-9]+$ ]] || die "--min-interval must be an integer"

    local st; st=$(cmd_status "$task")
    local open; open=$(sed -n 's/^open=\([0-9]*\) .*/\1/p' <<<"$st")
    [[ "$open" =~ ^[0-9]+$ ]] || open=0
    if (( open == 0 )); then
        warn "nudge: no open requests for task $(_arg_excerpt "$task") — nothing to nudge about"
        exit 0
    fi

    _wake_gate "$window" "$force" "$min_interval" nudge || exit 5

    _require_valid_task_key "$task"
    local dir; dir=$(_channel_dir "$task")
    local msg
    msg=$(printf '%s' \
"SKEPTIC CHECK: you have ${open} pending skeptic request(s) awaiting your response. \
Re-enter the await loop with \`monitor/skeptic-channel.sh await ${task}; rc=\$?; echo \"AWAIT_RC=\$rc\"; exit \$rc\` \
— run it BACKGROUNDED and ending in \`exit \$rc\`: a \`;\`-list reports its LAST statement's status, so a \
trailing \`echo\`, or even a bare trailing \`rc=\$?\`, makes 0/4/10/11 all arrive as 0 \
(your-org/nexus-code#1161). BACKGROUNDED means the Bash tool's \`run_in_background\` option, which \
re-invokes you when the job exits — NOT \`monitor/async-run.sh\`, which retains the rc and re-invokes \
nobody (your-org/nexus-code#1523). It acks each \
\`*.open.md\` in ${dir} (rename to \`*.ack.md\`) and exits so you can answer with \
\`monitor/skeptic-channel.sh answer ${task} <req> --file <reply>\` (rename to \
\`*.answered.md\`). Then re-enter await until it exits 10 (the skeptic closed the channel) or 11 \
(COUNTERPART-FINISHED — the skeptic recorded its verdict without closing; nothing more can arrive, \
so stop re-entering and proceed to retire).")

    # SKEPTIC_PASTE_BIN is a test seam (hermetic suite injects a stub).
    local paste_bin="${SKEPTIC_PASTE_BIN:-$_script_dir/paste-followup.sh}"
    local paste_out paste_rc
    # NB: no --src override. The watcher's paste-unconfirmed detector only
    # counts ledger rows whose src is exactly `paste-followup`; relabelling
    # this paste would quietly exempt every skeptic nudge from that check.
    paste_out=$("$paste_bin" "$window" --message "$msg" \
            --note "skeptic-nudge: $open pending request(s) for task $task" 2>&1)
    paste_rc=$?
    if (( paste_rc != 0 )); then
        # Relay paste-followup's own verdict verbatim. It distinguishes a
        # hard tmux failure (rc 1) from a paste that landed but never
        # submitted (rc 4) or one it could not confirm (rc 3) — see
        # your-org/nexus-code#507. Guessing "window absent? tmux down?" here
        # would substitute a wrong cause for a diagnosed one.
        warn "nudge: paste-followup.sh rc=$paste_rc for window $window — ${paste_out##*$'\n'}"
        exit 3
    fi
    _wake_stamp "$window" nudge
    # Best-effort audit event.
    "$_script_dir/ng" log-action monitor \
        --event skeptic-nudge \
        --extra "window=$window" \
        --extra "task=$task" \
        --extra "open=$open" >/dev/null 2>&1 || true
    printf 'nudged %s: %d pending skeptic request(s) for task %s\n' "$window" "$open" "$task"
}

# notify-delta: the REVERSE wake (your-org/nexus-code#845). The target has
# pushed a new round and re-armed its require gate; tell the PINNED SKEPTIC
# that a delta exists.
#
# WHY THIS IS THE MISSING HALF. `nudge` wakes a target that owes its
# reviewer an answer. Nothing woke a REVIEWER that was owed a delta — so a
# pinned skeptic sat idle under an explicit "wait for the new head"
# instruction while its target sat parked awaiting a verdict, and only an
# orchestrator noticing the pair in a poll emit could break it. Measured:
# 2h 18m (`tmuxwrap`/`sk897`), and seven such pairs in one prior session,
# the longest 4h 6m.
#
# WHY IT IS NOT A WORKER PASTING INTO A WINDOW IT DID NOT CREATE. It is the
# TOOLING pasting, on the same sanctioned path `nudge` has always used — and
# `nudge` already crosses this boundary in the other direction (a skeptic
# nudges a worker whose window it did not create). The invariant that
# matters is "no ad-hoc `tmux send-keys` between agents", and this honours
# it: same `_wake_gate`, same `paste-followup.sh`, same machine-input stamp,
# same audit event.
#
# It is a NOTIFICATION, not an instruction. The message names the delta and
# points at the obligation record; it does not tell the skeptic what to
# conclude.
cmd_notify_delta() {
    # your-org/nexus-code#906 C, applied at the merge seam. This verb is NEW in
    # `#845` and was written in the pre-`#906` shape because `#845` branched
    # before `#906` landed — the positional was bound from `$1` ahead of the
    # loop, so `notify-delta --target t <skeptic>` called the skeptic window an
    # unknown flag. It sits in the population `#906`'s order-sensitivity sweep
    # scans, so it carries the same surface as every other verb here.
    local skeptic=""
    local target="" round="" detail="" force=0 min_interval=120
    # your-org/nexus-code#1062 — the notice's REFS. `--detail` already carries
    # the human sentence; these three carry the same answer as DATA, so the log
    # can be asked afterwards how often a notice fired over unchanged bytes.
    local why="" subject_sha="" prior_sha=""
    _argloop_prev_8=-1; while (( $# > 0 )); do (( $# != _argloop_prev_8 )) || _argloop_stuck "$1"; _argloop_prev_8=$#
        case "$1" in
            --target)       target="${2:-}";       shift 2 || die "--target needs a value" ;;
            --round)        round="${2:-}";        shift 2 || die "--round needs a value" ;;
            --detail)       detail="${2:-}";       shift 2 || die "--detail needs a value" ;;
            --why)          why="${2:-}";          shift 2 || die "--why needs a value" ;;
            --subject-sha)  subject_sha="${2:-}";  shift 2 || die "--subject-sha needs a value" ;;
            --prior-sha)    prior_sha="${2:-}";    shift 2 || die "--prior-sha needs a value" ;;
            --force)        force=1;               shift ;;
            --min-interval) min_interval="${2:-}"; shift 2 || die "--min-interval needs seconds" ;;
            --*) die "unknown flag: $(_arg_excerpt "$1")" ;;
            *)  if [[ -z "$skeptic" ]]; then skeptic="$1"
                else _die_positional "notify-delta" "$1" "--target"; fi
                shift ;;
        esac
    done
    [[ -n "$skeptic" ]] || die "usage: notify-delta <skeptic-window> --target <window> [--round N] [--detail T] [--why changed|unchanged-rearm|first-round|indeterminate|no-record] [--subject-sha S] [--prior-sha S] [--force] [--min-interval S]"
    [[ -n "$target" ]] || die "notify-delta requires --target <the window that pushed the delta>"
    [[ "$min_interval" =~ ^[0-9]+$ ]] || die "--min-interval must be an integer"
    [[ "$round" =~ ^[0-9]+$ ]] || round=""
    # A token this verb has never heard of is recorded as `unclassified`, never
    # silently dropped: an absent field and a field nobody set must not look the
    # same, which is this workspace's dominant defect class.
    case "$why" in
        changed|unchanged-rearm|first-round|indeterminate|no-record) : ;;
        "") why=unstated ;;
        *)  why=unclassified ;;
    esac

    _wake_gate "$skeptic" "$force" "$min_interval" notify-delta || exit 5

    _require_valid_task_key "$target"
    local dir; dir=$(_channel_dir "$target")
    local msg
    msg=$(printf '%s' \
"SKEPTIC DELTA: \`${target}\` — the window you are reviewing — has filed a new round\
${round:+ (round ${round})} and is now PARKED awaiting your verdict. \
${detail:+${detail} }\
It cannot tell you this itself and you cannot see it from an idle pane, which is \
exactly the deadlock your-org/nexus-code#845 records. Re-read its report and its \
pushed head, run your delta pass, and file the verdict with \
\`monitor/ng wrap-up <issue> <report> --skeptic-role --skeptic-verdict <v> --skeptic-target ${target}\` \
— that is what releases its pending marker AND settles the obligation edge \
naming you as debtor. Its channel is ${dir}; ask with \
\`monitor/skeptic-channel.sh ask ${target} <slug> --message '<question>'\`. \
If you judge no further pass is warranted, say so on the record with \
\`monitor/ng obligation settle --debtor ${skeptic} --creditor ${target} --reason '<why>'\` \
so it is not left waiting on you.")

    local paste_bin="${SKEPTIC_PASTE_BIN:-$_script_dir/paste-followup.sh}"
    local paste_out paste_rc
    # NB: no --src override, for the reason cmd_nudge states — the watcher's
    # paste-unconfirmed detector only counts rows whose src is exactly
    # `paste-followup`, and relabelling would exempt this paste from it.
    paste_out=$("$paste_bin" "$skeptic" --message "$msg" \
            --note "skeptic-delta: $target ${round:+round $round }why=$why${subject_sha:+ sha=${subject_sha:0:12}}" 2>&1)
    paste_rc=$?
    if (( paste_rc != 0 )); then
        warn "notify-delta: paste-followup.sh rc=$paste_rc for window $skeptic — ${paste_out##*$'\n'}"
        exit 3
    fi
    _wake_stamp "$skeptic" notify-delta
    "$_script_dir/ng" log-action monitor \
        --event skeptic-delta-notify \
        --extra "window=$skeptic" \
        --extra "target-window=$target" \
        --extra "why=$why" \
        --extra "subject-sha=${subject_sha:--}" \
        --extra "prior-sha=${prior_sha:--}" \
        --extra "round=${round:-}" >/dev/null 2>&1 || true
    printf 'notified %s: %s re-armed%s (why=%s)\n' "$skeptic" "$target" "${round:+ (round $round)}" "$why"
}

main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        init)         cmd_init         "$@" ;;
        dir)          cmd_dir          "$@" ;;
        reqfile)      cmd_reqfile      "$@" ;;
        ask)          cmd_ask          "$@" ;;
        poll)         cmd_poll         "$@" ;;
        status)       cmd_status       "$@" ;;
        list)         cmd_list         "$@" ;;
        await)        cmd_await        "$@" ;;
        answer)       cmd_answer       "$@" ;;
        await-answer) cmd_await_answer "$@" ;;
        reconcile)    cmd_reconcile    "$@" ;;
        close)        cmd_close        "$@" ;;
        resolve)      cmd_resolve      "$@" ;;
        reset)        cmd_reset        "$@" ;;
        defer)        cmd_defer        "$@" ;;
        nudge)        cmd_nudge        "$@" ;;
        notify-delta) cmd_notify_delta "$@" ;;
        -h|--help|"")
            awk '/^$/{exit} NR>1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            [[ -z "$sub" ]] && exit 1 || exit 0
            ;;
        *) die "unknown subcommand: $(_arg_excerpt "$sub") (run with --help)" ;;
    esac
}

main "$@"
