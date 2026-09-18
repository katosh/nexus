#!/usr/bin/env bash
# monitor/cc-restart-watchdog-loop.sh — the deterministic watch loop the
# cc-update restart watchdog runs (GUIDE Step 5b, shipped as a repo file
# so the autonomous routine and manual evaluators run the SAME audited
# loop instead of re-adapting the skill's inline listing each time).
#
# Usage: NEXUS_ROOT=<abs-path> [CC_AUTO_TARGET_WINDOW=<name>] \
#            [WATCHDOG_DEADLINE_SECONDS=180] \
#            monitor/cc-restart-watchdog-loop.sh [--verify-only --attempt ID [--base-size N]]
#        (or pass the root as the last positional argument)
#
# The coordinator window this loop watches is resolved exactly as
# cc-auto-update-apply.sh resolves its TARGET_WINDOW. apply.sh also passes the
# window it already resolved via CC_AUTO_TARGET_WINDOW (rendered into the
# watchdog prompt), so the two can never disagree.
#
# Contract (see skills/nexus.cc-update/GUIDE.md "The restart watchdog"):
#   - records the baseline (candidate, orchestrator pid, watcher pid,
#     pinned sid, jsonl byte offset), THEN writes the armed marker —
#     the orchestrator-kill fires only after that marker exists — and
#     persists that baseline to $STATE/restart-watchdog-baseline;
#   - waits for the old pane to die and a new orchestrator window;
#   - verifies: exactly ONE orchestrator window, no stand-down window,
#     the watcher survived, the session pin unchanged, and a FRESH
#     jsonl record (past the baseline offset) stamped with the
#     candidate version — POLLED to the deadline, never one-shot (the
#     dying orchestrator keeps writing old-binary records for ~30s;
#     the 2026-06-03 cc-2.1.161 false negative);
#   - exit 0 on verified success (marker removed), exit 1 on failure
#     (failure marker written, and the armed marker THIS run wrote is
#     released; the supervising agent diagnoses and FIXES, then re-runs).
#
# --verify-only (the POST-KILL re-run). A plain re-run after the kill cannot
# verify anything: it baselines the REPLACEMENT orchestrator's pid, waits for
# that healthy process to die, and reports "orchestrator was never killed";
# and its jsonl offset is taken AFTER the new binary's records, so they are
# not "fresh" to it. Measured 2026-09-11 (2.1.268). This mode arms nothing and
# waits for no kill: it reads the baseline the first run persisted (or takes
# the jsonl offset from --base-size), refuses with exit 10 if that baseline's
# orchestrator is still ALIVE (nothing was killed, so there is nothing to
# verify), and runs the same step-4 verification against the ORIGINAL offset.
# Exit 2 when there is no baseline offset to verify against.
#
# IDENTITY FIRST (w234sk F1). The armed run writes a per-arm nonce,
# `attempt=<epoch>-<pid>-<random>`, into the baseline and prints it on its
# `armed:` line, and --verify-only requires `--attempt <that value>`. Age and
# candidate cannot tell two armings of the SAME bump apart: on 2026-07-21 one
# candidate was re-attempted about every 35 minutes, 16 times, so a baseline
# that is fresh and names the right candidate can still be another run's.
# Without --attempt, and without --base-size, the loop exits 2.
#
# Exit 13 when the persisted baseline is not THIS run's. That covers:
#   * its attempt is not the --attempt given (the discriminator);
#   * it is older than WATCHDOG_VERIFY_MAX_AGE_SECONDS (default 3600, CHOSEN:
#     a backstop only; long enough for a diagnose-and-fix cycle after a FAIL,
#     far shorter than the daily bump cadence);
#   * it records no armed_epoch;
#   * its candidate is not what the installed binary reports.
# A stale baseline's orchestrator pid is always dead, so exit 10 can never
# catch one. Measured before this guard: a baseline left by an earlier bump
# returned SUCCESS about a restart that did not happen. A SUCCESS now removes
# the baseline so it cannot go stale. An explicit --base-size still verifies
# on its own, ignoring a stale file.
#
# WHERE THE CANDIDATE COMES FROM when no baseline is used (--base-size with no
# file, or a file ignored as not this run's): the INSTALLED binary's version,
# never the ignored file's. SUCCESS still requires a jsonl record stamped with
# that version past the given offset. If no restart onto it happened, no such
# record exists and the verify fails.
#
# One case this does NOT distinguish, stated rather than hidden: an
# orchestrator ALREADY running the candidate before the offset keeps writing
# records stamped with it. So a --base-size verify reports the true END STATE
# (pinned session live on the candidate, single window, watcher alive), not
# that a restart EVENT happened. Only the attempt-bound baseline path speaks to
# the event.
#
# Deliberately contains NO pattern-based process kill (and no kill at
# all): observation only. See monitor/cc-harness/lint-no-mass-kill.sh.

set -uo pipefail
VERIFY_ONLY=0
VERIFY_BASE_SIZE=""
VERIFY_ATTEMPT=""
while (( $# > 0 )); do
    case "$1" in
        --verify-only) VERIFY_ONLY=1; shift ;;
        --base-size)
            (( $# >= 2 )) || { echo "cc-restart-watchdog-loop: --base-size needs a value" >&2; exit 2; }
            VERIFY_BASE_SIZE="$2"; shift 2 ;;
        --attempt)
            (( $# >= 2 )) || { echo "cc-restart-watchdog-loop: --attempt needs a value" >&2; exit 2; }
            VERIFY_ATTEMPT="$2"; shift 2 ;;
        --*) echo "cc-restart-watchdog-loop: unknown flag: $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
NEXUS_ROOT="${NEXUS_ROOT:-${1:-}}"
[[ -n "$NEXUS_ROOT" && -d "$NEXUS_ROOT" ]] || {
    echo "cc-restart-watchdog-loop: NEXUS_ROOT required (env or \$1)" >&2
    exit 2
}
STATE="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"
# Resolve the coordinator window NAME exactly as cc-auto-update-apply.sh's
# TARGET_WINDOW does: CC_AUTO_TARGET_WINDOW → MONITOR_TARGET env → config
# `monitor.target_window` → literal `orchestrator`. The config leg is
# load-bearing: #428 added it to apply.sh but left this sibling hard-coded, so
# on a nexus that sets `monitor.target_window: claude` the baseline's
# `tmux list-panes -t orchestrator` found nothing, the loop died before writing
# the armed marker, and apply.sh aborted the whole restart at
# `watchdog-never-armed` after burning its 600s ARM_WAIT (#459). The bug is
# invisible to any nexus whose window happens to be named `orchestrator`.
TARGET="${CC_AUTO_TARGET_WINDOW:-${MONITOR_TARGET:-$("$NEXUS_ROOT/config/load.sh" monitor.target_window orchestrator 2>/dev/null || echo orchestrator)}}"
SLUG=$(printf '%s' "$NEXUS_ROOT" | sed 's|[^a-zA-Z0-9]|-|g')
PROJECTS_DIR="${CC_AUTO_PROJECTS_DIR:-$HOME/.claude/projects}"
DEADLINE=$(( $(date +%s) + ${WATCHDOG_DEADLINE_SECONDS:-180} ))
LOG="$STATE/restart-watchdog.log"
BASELINE_FILE="$STATE/restart-watchdog-baseline"

# `_ensure_service_log` (your-org/nexus-code#484): `tee -a` creates the
# log under the ambient umask (0660 — group-writable) exactly as a bare
# `>>` would. Set the mode once, here, before the first note() lands.
# shellcheck source=_log-mode.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_log-mode.sh"
mkdir -p "$STATE" 2>/dev/null || true
_ensure_service_log "$LOG"

# THE ARMED MARKER IS RELEASED BY IDENTITY, NEVER BY A FLAG (w234sk F6).
#
# Left behind, the marker made every re-run the playbook prescribes exit 9, and
# held the reconcile single-flight (watcher/_cc_auto_update.sh,
# `[[ -f restart-watchdog-armed ]] && return 0`) shut until the next day's
# apply cleared it. So fail(), a signal and SUCCESS all release it.
#
# But the marker exists to hold that single-flight, and deleting ANOTHER
# claimant's marker silently reopens it to a concurrent restart. A flag
# ("I wrote it") cannot be kept right across a signal. Set AFTER the write, a
# signal handled at the end of the write saw 0 and stranded ours: measured on
# the old order, TERM sent the instant the marker file appeared, 10 of 10 runs.
# Set BEFORE the write, a signal between flag and write would delete whatever
# marker is at the path, possibly a live claimant's.
#
# So the marker is created EXCLUSIVELY (O_EXCL via noclobber) and carries this
# run's attempt nonce, and a release compares the marker's CONTENT against that
# nonce at release time. A signal before our create finds no marker, or a
# foreign one, and removes nothing. A signal after it finds ours and removes it.
# RESIDUALS, stated rather than hidden:
#   * The read-then-remove is not atomic, so a claimant that replaces the
#     marker in the microseconds between them is not protected.
#   * The exclusive create is only as atomic as the filesystem makes it.
#     `monitor/.state` sits on NFS (measured 2026-09-11: `stat -f` says nfs;
#     `findmnt` says `silver:/ifs/…`, vers=3), and O_EXCL there depends on the
#     NFS version, server and client, so local-filesystem atomicity is NOT
#     asserted. It is no weaker than the check-then-write it replaced.
_marker_is_mine() {
    [[ -n "${attempt:-}" && -f "$STATE/restart-watchdog-armed" ]] || return 1
    local l
    # EXPLICIT return codes only. This function is called from the TERM/INT/HUP
    # trap, and a bare `return` inside a function a trap handler calls reports
    # the status of the command that ran BEFORE the trap, not of the comparison
    # it follows. Measured on bash 4.4.20: the identical helper answered "not
    # mine" called directly and "MINE" called from a TERM trap, and the handler
    # deleted a foreign claimant's marker. This is the suite's SIGF case.
    while IFS= read -r l; do
        if [[ "$l" == attempt=* ]]; then
            if [[ "${l#attempt=}" == "$attempt" ]]; then
                return 0
            fi
            return 1
        fi
    done < "$STATE/restart-watchdog-armed"
    return 1
}
_release_marker_if_mine() {
    _marker_is_mine || return 1
    rm -f "$STATE/restart-watchdog-armed"
}
note() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }
fail() {
    note "FAIL: $*"
    command -v sandbox-notify >/dev/null 2>&1 \
        && sandbox-notify "cc-update self-restart FAILED: $*"
    date -Is > "$STATE/restart-watchdog-failed"
    if _release_marker_if_mine; then
        note "released the armed marker this run wrote. After a kill, re-verify with: $0 --verify-only --attempt ${attempt:-} (a plain re-run baselines the REPLACEMENT and false-negatives)"
    fi
    exit 1
}
# A SIGNAL is an exit fail() never sees (w234sk F6). Measured: SIGTERM while
# waiting for the kill left the marker behind, exactly as fail() used to.
# Release it by the same identity test as fail() and exit 128+N. A signalled
# watchdog is not a verify failure, so no failure marker is written.
_on_signal() {
    local sig="$1" code="$2"
    if _release_marker_if_mine; then
        note "SIGNAL $sig: stopping; released the armed marker this run wrote"
    else
        note "SIGNAL $sig: stopping"
    fi
    exit "$code"
}
trap '_on_signal TERM 143' TERM
trap '_on_signal INT 130' INT
trap '_on_signal HUP 129' HUP

# The version the installed binary reports. ONE definition: both modes derive
# it, and a second copy of the pipeline would be a second early-closing reader
# for test-early-exit-reader-manifest.sh to account for. Its status is not
# consumed; each caller checks the value is non-empty.
_binary_candidate() {
    "$NEXUS_ROOT/node_modules/.bin/claude" --version \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

if (( VERIFY_ONLY == 0 )); then
    # 1. baseline
    candidate=$(_binary_candidate)
    orch_pid=$(tmux list-panes -t "$TARGET" -F '#{pane_pid}' | head -1)
    watcher_pid=$(cat "$STATE/watcher.pid" 2>/dev/null || true)
    sid=$(tr -d '[:space:]' < "$STATE/orchestrator-session-id")
    jsonl="$PROJECTS_DIR/$SLUG/$sid.jsonl"
    base_size=$(stat -c%s "$jsonl") || fail "pinned jsonl missing — pin stale, ABORT (do not kill)"
    [[ -n "$candidate" && -n "$orch_pid" ]] || fail "baseline incomplete (candidate=$candidate orch_pid=$orch_pid)"
    # The per-arm nonce --verify-only binds to (w234sk F1). cc-auto-update-apply.sh
    # mints it when it renders the watchdog prompt and hands it in as
    # WATCHDOG_ATTEMPT, writing the same literal into the prompt's --verify-only
    # command. So the agent that later verifies holds this value by
    # construction, and never has to find it in the append-only log, where an
    # EARLIER attempt's `armed:` line is exactly what it would pick up on a day
    # of repeated attempts. The loop mints its own only when run by hand.
    attempt="${WATCHDOG_ATTEMPT:-}"
    if ! [[ "$attempt" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
        [[ -n "$attempt" ]] && note "WARN: WATCHDOG_ATTEMPT is not a usable nonce (want [A-Za-z0-9._-], at most 64 chars); minting one"
        attempt="$(date +%s)-$$-${RANDOM}${RANDOM}"
    fi
    note "armed: candidate=$candidate orch_pid=$orch_pid watcher_pid=${watcher_pid:-?} sid=$sid jsonl=$base_size bytes watchdog_pid=$$ attempt=$attempt"

    # 2. armed — the kill may fire once this file exists.
    #
    # REFUSE A SECOND ARM (your-org/nexus-code#1400, ccwatch item 4). The marker is
    # workspace-GLOBAL; the baseline above (`orch_pid`, read from tmux) is
    # PER-WATCHDOG. So a watchdog arming while another's marker already stands
    # records the REPLACEMENT's pid as its baseline and then waits for a process
    # that will never die. It goes on to report "orchestrator was never killed" —
    # which asserts a property of the BUMP when the true property is that THIS
    # WATCHDOG ARRIVED LATE.
    #
    # SEVERITY, STATED ACCURATELY — an earlier draft of this comment overstated it
    # and was corrected. `FAIL: orchestrator was never killed` is a DIFFERENT
    # string from `no respawn before deadline`, and only the latter is keyed
    # in the watchdog prompt's playbook. So this verdict falls to the
    # prompt's UNENUMERATED arm, whose instruction is "notify LOUDLY and
    # hold the workspace stable" — which is SAFE. The real prescribed-wrong-remedy
    # was milder: the prompt told EVERY non-zero exit to "re-run the loop", which
    # re-runs a watchdog that reaches the same false negative. After a kill the
    # prompt now points at --verify-only instead.
    #
    # EXIT 9 IS DISTINCT ON PURPOSE: it separates "I arrived late" from every real
    # failure, so the blanket re-run instruction does not apply to it. It is also
    # why the baseline file below is written only AFTER this check: a late
    # watchdog must not overwrite the armed one's baseline.
    # EXCLUSIVE CREATE (w234sk F6). A check-then-write left a window in which
    # two watchdogs could both see no marker and both arm. noclobber makes the
    # redirection open with O_EXCL, so exactly one create succeeds. It runs in a
    # subshell so noclobber does not leak into the loop's later redirections.
    # The content is the attempt nonce every release is checked against.
    if ! ( set -o noclobber
           printf 'attempt=%s\narmed_at=%s\n' "$attempt" "$(date -Is)" > "$STATE/restart-watchdog-armed"
         ) 2>/dev/null; then
        note "REFUSED to arm: $STATE/restart-watchdog-armed already exists (written $(tr '\n' ' ' < "$STATE/restart-watchdog-armed" 2>/dev/null || echo '?')). Another watchdog is armed and its baseline is NOT mine. My baseline orch_pid=$orch_pid would be the REPLACEMENT's pid, and I would then report 'orchestrator was never killed' about a healthy respawn."
        note "DO NOT re-run this loop plainly. A re-run reaches the same false negative. The bump is not implicated; this watchdog arrived late and another watchdog holds the arm. If the kill has already happened, verify with --verify-only --attempt <that watchdog's attempt>."
        exit 9
    fi
    printf 'attempt=%s\ncandidate=%s\norch_pid=%s\nwatcher_pid=%s\nsid=%s\nbase_size=%s\narmed_at=%s\narmed_epoch=%s\nwatchdog_pid=%s\n' \
        "$attempt" "$candidate" "$orch_pid" "${watcher_pid:-}" "$sid" "$base_size" "$(date -Is)" "$(date +%s)" "$$" \
        > "$BASELINE_FILE.tmp.$$" 2>/dev/null \
        && mv -f "$BASELINE_FILE.tmp.$$" "$BASELINE_FILE" 2>/dev/null \
        || { rm -f "$BASELINE_FILE.tmp.$$" 2>/dev/null; note "WARN: could not persist $BASELINE_FILE — a post-kill --verify-only will need --base-size $base_size"; }

    # 3. wait: old pane dies, then a new orchestrator window appears
    while kill -0 "$orch_pid" 2>/dev/null; do
        (( $(date +%s) > DEADLINE )) && fail "orchestrator was never killed"
        sleep 2
    done
    note "old orchestrator pid $orch_pid gone; waiting for the watcher respawn"
else
    # 1'. baseline from the FIRST run, never from the live board: the live board
    # is the replacement, which is the whole defect this mode exists for.
    b_candidate="" orch_pid="" watcher_pid="" b_sid="" base_size="" b_armed_epoch="" b_attempt=""
    baseline_src="none"
    if [[ -f "$BASELINE_FILE" ]]; then
        baseline_src="$BASELINE_FILE"
        while IFS='=' read -r _k _v; do
            case "$_k" in
                candidate)   b_candidate="$_v" ;;
                orch_pid)    orch_pid="$_v" ;;
                watcher_pid) watcher_pid="$_v" ;;
                sid)         b_sid="$_v" ;;
                base_size)   base_size="$_v" ;;
                armed_epoch) b_armed_epoch="$_v" ;;
                attempt)     b_attempt="$_v" ;;
            esac
        done < "$BASELINE_FILE"
        # IS THIS BASELINE THIS BUMP'S? (w234sk F1) The exit-10 guard cannot
        # answer it: a baseline left behind by an EARLIER restart names an
        # orchestrator pid that is always dead, and its jsonl offset precedes
        # whatever version records have been written since. So before trusting
        # a single field, establish that the file is fresh and names the binary
        # that is actually installed.
        _installed=$(_binary_candidate)
        _max_age="${WATCHDOG_VERIFY_MAX_AGE_SECONDS:-3600}"
        [[ "$_max_age" =~ ^[0-9]+$ ]] || _max_age=3600
        _stale="" _no_attempt=0
        if [[ -z "$VERIFY_ATTEMPT" ]]; then
            _no_attempt=1
            _stale="no --attempt was given, so nothing binds this baseline to THIS run"
        elif [[ "$b_attempt" != "$VERIFY_ATTEMPT" ]]; then
            _stale="it belongs to attempt ${b_attempt:-<none recorded>}, not --attempt $VERIFY_ATTEMPT (another arming, possibly of the same bump)"
        elif ! [[ "$b_armed_epoch" =~ ^[0-9]+$ ]]; then
            _stale="it records no armed_epoch (written by an older loop, or torn)"
        elif (( $(date +%s) - b_armed_epoch > _max_age )); then
            _stale="it was armed $(( $(date +%s) - b_armed_epoch ))s ago, past WATCHDOG_VERIFY_MAX_AGE_SECONDS=${_max_age}"
        elif [[ -n "$b_candidate" && -n "$_installed" && "$b_candidate" != "$_installed" ]]; then
            _stale="its candidate $b_candidate is not the installed binary's $_installed"
        fi
        if [[ -n "$_stale" ]]; then
            if [[ -n "$VERIFY_BASE_SIZE" ]]; then
                note "verify-only: IGNORING $BASELINE_FILE: $_stale. Proceeding on --base-size alone, against the installed binary."
                b_candidate="" orch_pid="" watcher_pid="" b_sid="" base_size=""
                baseline_src="none"
            elif (( _no_attempt )); then
                note "REFUSED --verify-only: $_stale. Pass --attempt with the attempt= value from THIS run's 'armed:' line, or --base-size N from the same line."
                exit 2
            else
                note "REFUSED --verify-only: $BASELINE_FILE is not this run's baseline: $_stale. Another run's orchestrator is always dead by now, so verifying against its baseline would certify a restart that did not happen. To override, pass --base-size N from THIS run's 'armed: … jsonl=<N> bytes' line."
                exit 13
            fi
        fi
    fi
    if [[ -n "$VERIFY_BASE_SIZE" ]]; then
        base_size="$VERIFY_BASE_SIZE"
        baseline_src="${baseline_src/#none/--base-size} (base_size from --base-size)"
    fi
    if ! [[ "$base_size" =~ ^[0-9]+$ ]]; then
        note "REFUSED --verify-only: no baseline jsonl offset — $BASELINE_FILE is absent or has no base_size, and no --base-size was given. Take the offset from the FIRST run's 'armed: … jsonl=<N> bytes' line in $LOG."
        exit 2
    fi
    [[ "$orch_pid" =~ ^[0-9]+$ ]] || orch_pid=""
    if [[ -n "$orch_pid" ]] && kill -0 "$orch_pid" 2>/dev/null; then
        note "REFUSED --verify-only: the baseline orchestrator pid $orch_pid is still ALIVE — nothing has been killed, so there is no restart to verify. This mode is for AFTER the kill; run the loop without --verify-only to arm."
        exit 10
    fi
    candidate="$b_candidate"
    if [[ -z "$candidate" ]]; then
        candidate=$(_binary_candidate)
    fi
    [[ -n "$watcher_pid" ]] || watcher_pid=$(cat "$STATE/watcher.pid" 2>/dev/null || true)
    sid=$(tr -d '[:space:]' < "$STATE/orchestrator-session-id")
    [[ -n "$candidate" ]] || fail "verify-only: no candidate version (baseline has none and the binary did not report one)"
    if [[ -n "$b_sid" && "$b_sid" != "$sid" ]]; then
        fail "session pin changed since the baseline ($b_sid → $sid) — cold spawn, context LOST; point the new orchestrator at the latest reports/"
    fi
    jsonl="$PROJECTS_DIR/$SLUG/$sid.jsonl"
    [[ -f "$jsonl" ]] || fail "verify-only: pinned jsonl $jsonl missing"
    note "verify-only: candidate=$candidate baseline_orch_pid=${orch_pid:-?} (gone) watcher_pid=${watcher_pid:-?} sid=$sid jsonl_offset=$base_size bytes source=$baseline_src watchdog_pid=$$"
fi

while :; do
    (( $(date +%s) > DEADLINE )) && fail "no respawn before deadline — read $STATE/watcher.log (re-verify abort? crash-loop?); manual recovery: monitor/watcher/spawn-fresh-orchestrator.sh"
    new_pid=$(tmux list-panes -t "$TARGET" -F '#{pane_pid}' 2>/dev/null | head -1)
    [[ -n "${new_pid:-}" && "$new_pid" != "$orch_pid" ]] && break
    sleep 2
done
note "new orchestrator pane pid $new_pid"

# 4. verify
n=$(tmux list-windows -F '#{window_name}' | grep -cx "$TARGET")
(( n == 1 )) || fail "$n $TARGET windows — duplicate respawn (PR 214 class)"
grep -qi standdown <<<"$(tmux list-windows -F '#{window_name}')" \
    && fail "stand-down window present — duplicate respawn occurred"
if [[ -n "${watcher_pid:-}" ]]; then
    kill -0 "$watcher_pid" 2>/dev/null \
        || fail "watcher died — relaunch: monitor/watcher/launcher.sh --target $TARGET"
fi
[[ "$(tr -d '[:space:]' < "$STATE/orchestrator-session-id")" == "$sid" ]] \
    || fail "session pin changed — cold spawn, context LOST; point the new orchestrator at the latest reports/"
# Grow-gate + new-binary check collapsed into ONE race-free poll: a
# FRESH record (past the baseline offset) stamped with the candidate
# version proves BOTH a context-preserving resume AND the new binary.
#
# Hardened against jsonl flush-visibility lag (your-org/nexus-code#532).
# On a large session jsonl (~1.1 GB), `--resume` replays a big context and
# the append is not durably visible to THIS independent poller until well
# after the records' internal event-timestamps. The old fixed-deadline poll
# false-negatived the 2.1.212 bump: the version records were on disk
# ~90-120 s before the 180 s deadline yet the poll declared FAIL, which is
# the trigger for a diagnose-and-fix path — burning attention on a healthy
# bump and inviting a "fix" against a workspace that needs none. Three
# hardenings, none of which weaken the success criterion (a fresh
# candidate-version record is still required to declare success):
#   1. GRACE window — keep polling for WATCHDOG_GRACE_SECONDS past the
#      deadline, so a flush that lands seconds late still counts. A single
#      grace read would have flipped 2.1.212 to SUCCESS. We are already
#      past the respawn gate here, so a new orchestrator pane provably
#      exists and the sid is unchanged — the only open question is whether
#      the candidate-version stamp has become visible yet, which makes a
#      generous grace low-risk.
#   2. Per-poll diagnostics to the log (size, growth-past-baseline, time
#      left) so the NEXT occurrence is diagnosable from the log instead of
#      requiring live forensics.
#   3. Growth-aware verdict — file grew past baseline but no candidate
#      stamp within grace ⇒ "resumed on the OLD binary / wedged resume";
#      never grew ⇒ "never resumed". The old message conflated the two.
GRACE_SECONDS="${WATCHDOG_GRACE_SECONDS:-60}"
VDEADLINE=$(( DEADLINE + GRACE_SECONDS ))
last_size=$base_size
diag() { printf '%s poll: %s\n' "$(date -Is)" "$*" >> "$LOG" 2>/dev/null || true; }
while :; do
    grep -qF "\"version\":\"$candidate\"" \
        <<<"$(tail -c +$(( base_size + 1 )) "$jsonl" 2>/dev/null)" && break
    now=$(date +%s)
    cur_size=$(stat -c%s "$jsonl" 2>/dev/null || echo "$last_size")
    (( cur_size > last_size )) && last_size=$cur_size
    diag "size=$cur_size (+$(( last_size - base_size )) past baseline) version=$candidate not-yet-visible; $(( VDEADLINE - now ))s to deadline"
    if (( now > VDEADLINE )); then
        if (( last_size > base_size )); then
            fail "jsonl grew +$(( last_size - base_size )) bytes past baseline but no \"version\":\"$candidate\" record became visible within ${GRACE_SECONDS}s grace past the deadline — resumed on the OLD binary, or a wedged resume writing non-version records (size=$last_size)"
        else
            fail "no fresh jsonl record and the file never grew past baseline ($base_size bytes) after deadline+${GRACE_SECONDS}s grace — the orchestrator never resumed (cold spawn, or wedged before its first write)"
        fi
    fi
    sleep 2
done

note "SUCCESS: sid=$sid resumed on $candidate; single window; watcher alive$( ((VERIFY_ONLY)) && echo ' (verify-only)')"
command -v sandbox-notify >/dev/null 2>&1 \
    && sandbox-notify "cc-update self-restart verified: orchestrator on $candidate"
_release_marker_if_mine || true
# A verified baseline has done its job. Left behind, it is the stale baseline
# w234sk F1 measured a false SUCCESS against, so it is removed in BOTH modes.
rm -f "$BASELINE_FILE"
exit 0
