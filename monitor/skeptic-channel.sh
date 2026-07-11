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
# waiting on a stale DONE (fail closed). wrap-up also clears a prior DONE
# when it opens a round (fail fast); either guard alone would suffice for
# the observed bug, but await's is the one that holds if a future caller
# writes a pending marker without resetting the channel.
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
#                                             DONE → exit 10; timeout → exit 4
#   answer  <task-id> <req> [--file f|--message t|-]    worker → reply+rename
#   await-answer <task-id> <req> [--timeout S] [--interval S]  skeptic → block
#                                             until *.answered.md
#   reconcile <task-id> [--window W] [--grace S] [--interval S] [--max-iter N]
#                                             [--min-interval S] [--no-nudge]
#                                             skeptic → ensure all acked
#   close   <task-id>                         skeptic → drop DONE sentinel
#   list    <task-id>                         human-readable status table
#   status  <task-id>                         machine: "open=N ack=A answered=M total=T done=0|1"
#   nudge   <worker-window> [--task <id>] [--force] [--min-interval S]
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
#  10   await: DONE sentinel present AND newer than the task's pending
#       marker (or no marker) — the skeptic closed the channel for THIS
#       round; stop looping and proceed to retire. A DONE older than the
#       marker is a prior round's and is ignored (await keeps waiting).
#
# State dir resolution mirrors monitor/ng + paste-followup.sh:
#   NEXUS_STATE_DIR → NEXUS_ROOT/monitor/.state → config nexus.root →
#   script-relative fallback.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die()  { printf 'skeptic-channel: %s\n' "$*" >&2; exit 1; }
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
SKEPTIC_ROOT="$STATE_DIR/skeptic"
PENDING_DIR="$SKEPTIC_ROOT/pending"

# Sanitize a task-id / window name into a safe directory component.
# Same rule spawn-worker.sh uses for window-keyed state files.
_safe() { printf '%s' "${1//[^a-zA-Z0-9_-]/_}"; }

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
    idx=$(tmux list-windows -F '#{window_index} #{window_name}' 2>/dev/null \
            | awk -v n="$name" '$2 == n { print $1; exit }')
    [[ -n "$idx" ]] || return 1
    printf '%s' "$idx"
}

_channel_dir() {
    local task; task=$(_safe "$1")
    printf '%s/%s' "$SKEPTIC_ROOT" "$task"
}

_done_sentinel() { printf '%s/DONE' "$(_channel_dir "$1")"; }

_pending_marker() { printf '%s/%s' "$PENDING_DIR" "$(_safe "$1")"; }

# Read a --file / --message / stdin body into stdout. Shared by ask
# and answer. Args after the positional ones are passed in.
_read_body() {
    local file="" text="" have_dash=0
    while (( $# > 0 )); do
        case "$1" in
            --file)    file="${2:-}";    shift 2 || die "--file needs a path" ;;
            --message) text="${2:-}";    shift 2 || die "--message needs text" ;;
            -)         have_dash=1;      shift ;;
            *)         die "unexpected argument: $1" ;;
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
    local marker; marker=$(_pending_marker "$task")
    [[ -e "$marker" ]] && touch -c "$marker" 2>/dev/null || true
    date +%s > "$dir/.await-heartbeat" 2>/dev/null || true
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
    printf '%s\t%s\t%s\n' "$window" "$(date +%s)" "$src" \
        >> "$STATE_DIR/machine-input.tsv" 2>/dev/null || true
}

cmd_init() {
    local task="${1:-}"; [[ -n "$task" ]] || die "usage: init <task-id>"
    local dir; dir=$(_channel_dir "$task")
    mkdir -p "$dir" || die "cannot create channel dir: $dir"
    printf '%s\n' "$dir"
}

cmd_dir() {
    local task="${1:-}"; [[ -n "$task" ]] || die "usage: dir <task-id>"
    printf '%s\n' "$(_channel_dir "$task")"
}

cmd_reqfile() {
    local task="${1:-}" req="${2:-}"
    [[ -n "$task" && -n "$req" ]] || die "usage: reqfile <task-id> <req>"
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
    local task="${1:-}"; [[ -n "$task" ]] || die "usage: poll <task-id> [--state open|ack|answered|all]"
    shift || true
    local state=open
    while (( $# > 0 )); do
        case "$1" in
            --state) state="${2:-}"; shift 2 || die "--state needs a value" ;;
            *) die "unknown flag: $1" ;;
        esac
    done
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
}

# await — WORKER-side blocking ack-loop. Polls the channel on a short
# interval. On the first poll that finds one or more *.open.md, it ACKS
# each (atomic rename .open.md → .ack.md) — the rename is the signal the
# skeptic's reconcile watches for — prints the acked paths, and EXITS 0
# so the worker agent regains control to answer them. A DONE sentinel
# (dropped by the skeptic's `close`) exits 10: stop looping, retire.
# Times out (exit 4) after --timeout so a single call is bounded; the
# worker re-enters await (the floor instructs this) which re-heartbeats.
cmd_await() {
    local task="${1:-}"; [[ -n "$task" ]] || die "usage: await <task-id> [--timeout S] [--interval S] [--once]"
    shift || true
    local timeout interval once=0
    timeout=$(_cfg_int monitor.skeptic.await_timeout_seconds MONITOR_SKEPTIC_AWAIT_TIMEOUT_SECONDS 900)
    interval=$(_cfg_int monitor.skeptic.await_interval_seconds MONITOR_SKEPTIC_AWAIT_INTERVAL_SECONDS 5)
    while (( $# > 0 )); do
        case "$1" in
            --timeout)  timeout="${2:-}";  shift 2 || die "--timeout needs seconds" ;;
            --interval) interval="${2:-}"; shift 2 || die "--interval needs seconds" ;;
            --once)     once=1;            shift ;;
            *) die "unknown flag: $1" ;;
        esac
    done
    [[ "$timeout"  =~ ^[0-9]+$ ]] || die "--timeout must be an integer"
    [[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || die "--interval must be a positive integer"
    local dir; dir=$(_channel_dir "$task")
    mkdir -p "$dir" 2>/dev/null || true
    local sentinel; sentinel=$(_done_sentinel "$task")
    local marker;   marker=$(_pending_marker "$task")
    local waited=0 f acked stale_warned=0
    while :; do
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
        sleep "$interval"
        waited=$((waited + interval))
    done
    printf 'skeptic-channel: await timed out after %ds with no open request and no DONE (task %s); re-enter await\n' \
        "$timeout" "$task" >&2
    return 4
}

cmd_answer() {
    local task="${1:-}" req="${2:-}"
    [[ -n "$task" && -n "$req" ]] || die "usage: answer <task-id> <req> [--file f|--message t|-]"
    shift 2
    local body; body=$(_read_body "$@") || exit 1
    [[ -n "${body//[[:space:]]/}" ]] || die "answer: response body is empty"
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
    awk -v ans="$body" -v ts="$(_now_iso)" '
        BEGIN { in_fm=0 }
        NR==1 && $0=="---" { in_fm=1; print; next }
        in_fm && $0=="---" { in_fm=0; print "answered: " ts; print; next }
        in_fm && /^state:[[:space:]]/ { print "state: answered"; next }
        # Drop the awaiting placeholder; the appended answer replaces it.
        /^_\(awaiting/ { next }
        { print }
        END { print ""; print ans }
    ' "$src" > "$tmp" || { rm -f "$tmp"; die "answer: failed to compose response"; }
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
    local task="${1:-}" req="${2:-}"
    [[ -n "$task" && -n "$req" ]] || die "usage: await-answer <task-id> <req> [--timeout S] [--interval S]"
    shift 2
    local timeout=600 interval=5
    while (( $# > 0 )); do
        case "$1" in
            --timeout)  timeout="${2:-}";  shift 2 || die "--timeout needs seconds" ;;
            --interval) interval="${2:-}"; shift 2 || die "--interval needs seconds" ;;
            *) die "unknown flag: $1" ;;
        esac
    done
    [[ "$timeout"  =~ ^[0-9]+$ ]] || die "--timeout must be an integer"
    [[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || die "--interval must be a positive integer"
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
    local task="${1:-}"; [[ -n "$task" ]] || die "usage: reconcile <task-id> [--window W] [--grace S] [--interval S] [--max-iter N] [--min-interval S] [--no-nudge]"
    shift || true
    local window="$task" grace=30 interval=15 max_iter=20 min_interval=120 do_nudge=1
    while (( $# > 0 )); do
        case "$1" in
            --window)       window="${2:-}";       shift 2 || die "--window needs a value" ;;
            --grace)        grace="${2:-}";         shift 2 || die "--grace needs seconds" ;;
            --interval)     interval="${2:-}";      shift 2 || die "--interval needs seconds" ;;
            --max-iter)     max_iter="${2:-}";      shift 2 || die "--max-iter needs a count" ;;
            --min-interval) min_interval="${2:-}";  shift 2 || die "--min-interval needs seconds" ;;
            --no-nudge)     do_nudge=0;             shift ;;
            *) die "unknown flag: $1" ;;
        esac
    done
    local v
    for v in grace interval max_iter min_interval; do
        [[ "${!v}" =~ ^[0-9]+$ ]] || die "--$v must be an integer"
    done
    [[ "$interval" -gt 0 ]] || die "--interval must be positive"
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
    rm -f "$(_pending_marker "$task")" 2>/dev/null || true
    printf '%s\n' "$sentinel"
}

# nudge: wake an idle worker that has pending requests. Reuses
# paste-followup.sh (the only correct way to inject machine input into
# a worker pane). Guards:
#   - resolves the worker's pane-state; skips a busy / user-typing pane
#     (the worker is active and will re-enter await on its own turn, or
#     the operator is typing — never steamroll either) unless --force.
#   - rate-limits per-window via a last-nudge stamp (default 120s).
cmd_nudge() {
    local window="${1:-}"; [[ -n "$window" ]] || die "usage: nudge <worker-window> [--task <id>] [--force] [--min-interval S]"
    shift || true
    local task="$window" force=0 min_interval=120
    while (( $# > 0 )); do
        case "$1" in
            --task)         task="${2:-}";         shift 2 || die "--task needs a value" ;;
            --force)        force=1;               shift ;;
            --min-interval) min_interval="${2:-}"; shift 2 || die "--min-interval needs seconds" ;;
            *) die "unknown flag: $1" ;;
        esac
    done
    [[ "$min_interval" =~ ^[0-9]+$ ]] || die "--min-interval must be an integer"

    local st; st=$(cmd_status "$task")
    local open; open=$(sed -n 's/^open=\([0-9]*\) .*/\1/p' <<<"$st")
    [[ "$open" =~ ^[0-9]+$ ]] || open=0
    if (( open == 0 )); then
        warn "nudge: no open requests for task $task — nothing to nudge about"
        exit 0
    fi

    # Rate-limit.
    local stamp_dir="$SKEPTIC_ROOT/.nudge"
    local stamp; stamp="$stamp_dir/$(_safe "$window")"
    mkdir -p "$stamp_dir" 2>/dev/null || true
    if (( force == 0 )) && [[ -f "$stamp" ]]; then
        local last now age
        last=$(cat "$stamp" 2>/dev/null || echo 0)
        now=$(date +%s)
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        age=$((now - last))
        if (( age < min_interval )); then
            warn "nudge: last nudge to $window was ${age}s ago (< ${min_interval}s); skipping (use --force to override)"
            exit 5
        fi
    fi

    # Pane-state guard: only nudge an idle/absent worker. A busy worker
    # re-enters await on its own turn; a user-typing pane belongs to the
    # operator. pane-state.sh emits `state=<...>`.
    # SKEPTIC_PANESTATE_BIN is a test seam (hermetic suite injects a stub).
    local ps_bin="${SKEPTIC_PANESTATE_BIN:-$_script_dir/pane-state.sh}" ps_state=""
    if (( force == 0 )) && [[ -x "$ps_bin" ]]; then
        # pane-state.sh is INDEX-keyed; resolve the window NAME → index
        # before probing. A name leaks through as an unresolved arg →
        # empty state → no skip → the guard is inert (the F1 defect).
        # If the index can't be resolved, FAIL SAFE: skip the nudge
        # rather than paste blind into a pane whose state is unknowable.
        local idx
        if ! idx=$(_resolve_window_index "$window"); then
            warn "nudge: cannot resolve a tmux index for window $window — skipping (fail-safe; the pane state is unknowable; use --force to override)"
            exit 5
        fi
        local ps_out; ps_out=$("$ps_bin" "$idx" 2>/dev/null || true)
        ps_state=$(sed -n 's/.*state=\([a-z-]*\).*/\1/p' <<<"$ps_out")
        case "$ps_state" in
            user-typing)
                # The OPERATOR is in the input box right now — never
                # steamroll, and never stamp (a stamp here would mask the
                # operator's own submit → false NEGATIVE).
                warn "nudge: window $window is 'user-typing' — skipping (operator active; use --force to override)"
                exit 5
                ;;
            busy|working-*)
                # The worker is doing agent work — almost always the
                # protocol itself (this path only runs with open>0 pending
                # requests). We DEFER delivery (the worker re-enters await
                # on its own turn), but STAMP machine-input first (bug A;
                # live incident 2026-06-18). Under load the worker's pane
                # churns and its UserPromptSubmit hook can fire while no
                # paste stamp covers it → the watcher mis-seeds a false
                # `operator-engaged` mark. Stamping on the busy-skip closes
                # that attribution gap so channel-driven pane I/O is
                # machine-attributed even when delivery is deferred.
                # user-typing is excluded above — that submit IS the
                # operator's and must still register.
                _stamp_machine_input "$window" "skeptic-nudge-busy-skip"
                warn "nudge: window $window is '$ps_state' — deferring delivery (worker active; stamped machine-input so the protocol churn is not mis-seeded as operator; use --force to override)"
                exit 5
                ;;
        esac
    fi

    local dir; dir=$(_channel_dir "$task")
    local msg
    msg=$(printf '%s' \
"SKEPTIC CHECK: you have ${open} pending skeptic request(s) awaiting your response. \
Re-enter the await loop with \`monitor/skeptic-channel.sh await ${task}\` — it acks each \
\`*.open.md\` in ${dir} (rename to \`*.ack.md\`) and exits so you can answer with \
\`monitor/skeptic-channel.sh answer ${task} <req> --file <reply>\` (rename to \
\`*.answered.md\`). Then re-enter await until it exits 10 (the skeptic closed the channel).")

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
    date +%s > "$stamp" 2>/dev/null || true
    # Best-effort audit event.
    "$_script_dir/ng" log-action monitor \
        --event skeptic-nudge \
        --extra "window=$window" \
        --extra "task=$task" \
        --extra "open=$open" >/dev/null 2>&1 || true
    printf 'nudged %s: %d pending skeptic request(s) for task %s\n' "$window" "$open" "$task"
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
        nudge)        cmd_nudge        "$@" ;;
        -h|--help|"")
            awk '/^$/{exit} NR>1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            [[ -z "$sub" ]] && exit 1 || exit 0
            ;;
        *) die "unknown subcommand: $sub (run with --help)" ;;
    esac
}

main "$@"
