#!/usr/bin/env bash
# monitor/cc-auto-update-apply.sh — deterministic executor for the
# autonomous cc-update routine's decision branches.
#
# The autonomous evaluator (spawned daily at the configured fire time by
# the watcher's cc_auto_update task — see monitor/watcher/_cc_auto_update.sh)
# does the JUDGMENT work of skills/nexus.cc-update/GUIDE.md Steps 1–4
# (changelog review, collision analysis, running the cc-harness gate).
# This script does the EXECUTION work, so every state-mutating step of
# the bump is deterministic, ordered, auditable, and testable:
#
#   safe            GUIDE Step 5 (operator-local pin bump + local
#                   install + watcher restart) AND Step 5b (the
#                   watchdog-observed orchestrator self-restart) —
#                   refused without gate evidence + the surfaces-clear
#                   attestation. THE ONLY PATH THAT WRITES THE PIN.
#   compat-pr auto  rule 4: check for an existing open compat PR on the
#                   nexus-code repo; comment findings on it (rc 0), or
#                   report none-found (rc 10 — the evaluator then
#                   authors the fix and opens the PR itself) or
#                   ambiguity (rc 11 — the evaluator picks). NEVER
#                   bumps.
#   block           rule 5: record + notify; NEVER bumps.
#   record-outcome  audit-trail writer for outcomes this script cannot
#                   observe (e.g. the evaluator opened a compat PR).
#
# Fail-safe contract: any guard failure, any step failure, any
# uncertainty → the pin is NOT advanced (or is rolled back), the
# orchestrator is NOT killed, and the failure is recorded loudly.
# Distinct exit codes let the evaluator branch precisely:
#
#   0   success (verb-specific)
#   2   usage / unknown verb
#   3   refused: gate evidence missing, stale, or not GREEN; or the
#       --surfaces-clear attestation absent
#   4   install failed (pin rolled back)
#   5   binary verification failed (pin rolled back)
#   6   watcher restart failed (pin + install stand; NO orchestrator kill)
#   7   another apply is already in flight (lock held)
#   10  compat-pr: no existing open compat PR (caller must open one)
#   11  compat-pr: multiple open compat PRs (caller must pick + comment)
#   21  safe: bumped, orchestrator restart NOT handed off (session pin
#       stale/absent — a kill would cold-spawn and lose the conversation
#       context, so we do not even detach the restart). Foreground
#       pre-flight; the bump itself stands.
#
# `safe` no longer BLOCKS on the orchestrator idle-wait: after the bump
# (pin + install + watcher restart, all synchronous) it hands the
# idle-wait → context-preserving kill+respawn to a DETACHED background
# process (the `restart-orchestrator` verb, re-exec'd disowned) and
# RETURNS exit 0 promptly. This decouples the restart from the cc-update
# evaluator's hard 600s Bash-tool ceiling (the old in-foreground idle-wait
# was SIGTERMed mid-loop daily) AND lets the idle cap be raised freely.
# The one exception that stays foreground is the stale-pin pre-flight
# (exit 21) — a doomed restart is never even detached.
#
# The detached `restart-orchestrator` verb owns the bounded wait and the
# kill. Its own exit codes (recorded as audit rows + notify; the disowned
# caller's rc is not observed):
#   0   restart triggered — orchestrator killed for a context-preserving
#       respawn. state=idle → outcome safe-bumped-restarted; idle-cap
#       reached while busy → safe-bumped-restart-FORCED (operator
#       decision: restart a busy orchestrator anyway — the pinned session
#       resumes from its transcript, so a mid-turn kill only re-runs the
#       interrupted turn, repeating some tokens, never losing work).
#   21  ABORT — session pin went stale/absent (or transcript missing)
#       before the kill; a kill now would cold-spawn. No kill.
#   22  ABORT — watchdog template missing / spawn failed / never armed.
#       No kill (never kill the orchestrator unwatched).
#   23  ABORT — orchestrator window unresolved, or pane-state UNREADABLE
#       (no parseable verdict). A confirmed-idle OR the force-on-cap gate
#       is required; an unreadable probe is neither, so fail loud. No kill.
#       (state=empty is a VALID verdict — claude alive, renderer blip —
#       and is treated as not-idle, NOT unreadable: it keeps waiting and
#       force-restarts at the cap.)
#   24  NO-OP — the orchestrator already respawned onto the candidate on
#       its own (a candidate-stamped record exists in the pinned
#       transcript, e.g. the version-aware watcher self-restart). Killing
#       would be needless. No kill.
#
# On any non-0 restart outcome the version bump itself is COMPLETE (new
# workers get the candidate); only the running orchestrator stays on the
# old binary. The evaluator/watchdog surfaces that version-split.
#
# Test injection (all default to the live mechanism):
#   CC_AUTO_INSTALL_CMD           monitor/install-claude-local.sh
#   CC_AUTO_WATCHER_RESTART_CMD   monitor/svc.sh restart watcher
#   CC_AUTO_SPAWN_CMD             monitor/spawn-worker.sh
#   CC_AUTO_PANE_STATE_CMD        monitor/pane-state.sh
#   CC_AUTO_CLAUDE_BIN            node_modules/.bin/claude
#   CC_AUTO_TMUX                  tmux
#   CC_AUTO_GH                    gh
#   CC_AUTO_MINT_CMD              monitor/mint-token.sh
#   CC_AUTO_PROJECTS_DIR          ~/.claude/projects
#   CC_AUTO_RESTART_INLINE        when 1, `safe` runs the restart hand-off
#                                 synchronously in-process (test seam)
#                                 instead of detaching it — so a test can
#                                 assert the full chain deterministically.
#   NEXUS_STATE_DIR / NEXUS_CC_LOCAL_PIN  (the _cc-version.sh overrides)
#
# Never uses pkill -f / pgrep -f / killall (sandbox mass-kill hazard;
# see monitor/cc-harness/lint-no-mass-kill.sh). The only kill issued is
# `tmux kill-window` on the coordinator window, per GUIDE Step 5b.

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Absolute path to THIS script — used for the detached `restart-orchestrator`
# re-exec, which must not depend on $0 being absolute or on cwd.
SELF_PATH="$_self_dir/$(basename "${BASH_SOURCE[0]}")"
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$_self_dir/.." && pwd)}"
STATE_DIR="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"
AUTO_DIR="$STATE_DIR/cc-auto-update"
APPLY_LOG="$AUTO_DIR/apply.log"

# Shared helpers: the effective-version resolver + pin writer, the
# key=value field parser, and the audit-row appender. All three modules
# are side-effect-free on source.
# shellcheck source=_cc-version.sh
source "$_self_dir/_cc-version.sh"
# shellcheck source=watcher/_cc_update.sh
source "$_self_dir/watcher/_cc_update.sh"
# shellcheck source=watcher/_cc_auto_update.sh
source "$_self_dir/watcher/_cc_auto_update.sh"

PACKAGE="${MONITOR_CC_UPDATE_PACKAGE:-@anthropic-ai/claude-code}"
COMPAT_REPO="${CC_AUTO_COMPAT_REPO:-your-org/nexus-code}"
# Resolve the orchestrator window NAME the same way launcher.sh:82 and
# spawn-fresh-orchestrator.sh do: CC_AUTO_TARGET_WINDOW → MONITOR_TARGET env →
# config `monitor.target_window` → literal `orchestrator`. The config leg is
# load-bearing: nexuses that set `monitor.target_window: claude` (the common
# case) name the orchestrator window `claude`, and a bare `orchestrator`
# default never resolves — the detached restart aborts every fire and the
# workspace stays version-split after an otherwise-successful bump (observed on
# 2.1.173 and 2.1.199). MONITOR_TARGET is usually unset in the detached
# restart's env, so consulting the config here is what makes it match.
TARGET_WINDOW="${CC_AUTO_TARGET_WINDOW:-${MONITOR_TARGET:-$("$NEXUS_ROOT/config/load.sh" monitor.target_window orchestrator 2>/dev/null || echo orchestrator)}}"
WATCHDOG_WINDOW="${CC_AUTO_WATCHDOG_WINDOW:-cc-restart-watchdog}"

INSTALL_CMD="${CC_AUTO_INSTALL_CMD:-$NEXUS_ROOT/monitor/install-claude-local.sh}"
SPAWN_CMD="${CC_AUTO_SPAWN_CMD:-$NEXUS_ROOT/monitor/spawn-worker.sh}"
PANE_STATE_CMD="${CC_AUTO_PANE_STATE_CMD:-$NEXUS_ROOT/monitor/pane-state.sh}"
CLAUDE_BIN="${CC_AUTO_CLAUDE_BIN:-$NEXUS_ROOT/node_modules/.bin/claude}"
TMUX_CMD="${CC_AUTO_TMUX:-tmux}"
GH_CMD="${CC_AUTO_GH:-gh}"
MINT_CMD="${CC_AUTO_MINT_CMD:-$NEXUS_ROOT/monitor/mint-token.sh}"
PROJECTS_DIR="${CC_AUTO_PROJECTS_DIR:-$HOME/.claude/projects}"

GATE_EVIDENCE_MAX_AGE="${CC_AUTO_GATE_EVIDENCE_MAX_AGE_SECONDS:-21600}"
IDLE_WAIT="${CC_AUTO_IDLE_WAIT_SECONDS:-900}"
IDLE_POLL="${CC_AUTO_IDLE_POLL_SECONDS:-15}"
ARM_WAIT="${CC_AUTO_ARM_WAIT_SECONDS:-600}"
ARM_POLL="${CC_AUTO_ARM_POLL_SECONDS:-5}"

_UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

note() {
    local ts
    ts=$(date -Is 2>/dev/null || echo unknown)
    printf '%s %s\n' "$ts" "$*"
    mkdir -p "$AUTO_DIR" 2>/dev/null || true
    printf '%s %s\n' "$ts" "$*" >> "$APPLY_LOG" 2>/dev/null || true
}

notify() {
    command -v sandbox-notify >/dev/null 2>&1 && sandbox-notify "$*" || true
}

# record_outcome <candidate> <decision> [detail] — last-eval (the daily
# guard's awaiting-operator input) + the append-only audit row.
record_outcome() {
    local candidate="$1" decision="$2" detail="${3:-}"
    mkdir -p "$AUTO_DIR" 2>/dev/null || true
    local tmp="$AUTO_DIR/last-eval.tmp.$$"
    {
        printf 'candidate=%s\n' "$candidate"
        printf 'decision=%s\n'  "$decision"
        printf 'date=%s\n'      "$(date -Is 2>/dev/null || echo unknown)"
        printf 'detail=%s\n'    "$detail"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$AUTO_DIR/last-eval" 2>/dev/null \
        || rm -f "$tmp" 2>/dev/null || true
    _cc_auto_log_decision "$AUTO_DIR" "$candidate" "$decision" "$detail"
}

usage() {
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

# ---- verb: safe ----------------------------------------------------------

# _slug <path> — Claude Code project-dir slug (every non-alphanumeric
# char → '-'; mirrors spawn-worker.sh's _resume_slug).
_slug() { printf '%s' "$1" | sed 's|[^a-zA-Z0-9]|-|g'; }

# _resolve_target_index <window> — resolve a tmux window NAME to its
# INDEX. `monitor/pane-state.sh` is INDEX-keyed; handing it a window
# *name* (the historical Step 5b bug — TARGET_WINDOW defaults to the
# name "orchestrator") makes it print a usage message to stderr and
# exit 2 with EMPTY stdout. The idle loop then parsed empty, never
# matched "idle", and silently deferred the restart for the full
# IDLE_WAIT — leaving the workspace version-split on EVERY auto-update
# (2026-06-16 live incident). Echoes the index on stdout; empty stdout
# (rc 0) when tmux is unavailable or the name has no live window — the
# caller treats empty as a hard, fail-loud error. A numeric argument
# is already an index and passes through untouched. First match wins;
# mirrors `_over_limit_resolve_window_index` in watcher/_over_limit.sh.
_resolve_target_index() {
    local name="$1"
    [[ "$name" =~ ^[0-9]+$ ]] && { printf '%s' "$name"; return 0; }
    command -v "$TMUX_CMD" >/dev/null 2>&1 || return 0
    "$TMUX_CMD" list-windows -F '#{window_name}|#{window_index}' 2>/dev/null \
        | awk -F'|' -v n="$name" '$1 == n { print $2; exit }'
}

# _check_gate_evidence <file> <candidate> — rc 0 iff the file exists, is
# fresh, names a GREEN gate, and mentions the candidate.
_check_gate_evidence() {
    local file="$1" candidate="$2"
    [[ -f "$file" ]] || { note "REFUSED: gate evidence file missing: $file"; return 1; }
    local age now mtime
    now=$(date +%s)
    mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    if (( age > GATE_EVIDENCE_MAX_AGE )); then
        note "REFUSED: gate evidence is ${age}s old (> ${GATE_EVIDENCE_MAX_AGE}s) — re-run the gate"
        return 1
    fi
    if ! grep -q 'GATE GREEN' "$file"; then
        note "REFUSED: gate evidence does not contain 'GATE GREEN' — a red/absent gate never bumps"
        return 1
    fi
    if ! grep -qF "$candidate" "$file"; then
        note "REFUSED: gate evidence does not mention candidate $candidate — wrong gate run?"
        return 1
    fi
    return 0
}

cmd_safe() {
    local candidate="" gate_evidence="" surfaces_clear=0
    while (( $# > 0 )); do
        case "$1" in
            --candidate)      candidate="$2"; shift 2 ;;
            --gate-evidence)  gate_evidence="$2"; shift 2 ;;
            --surfaces-clear) surfaces_clear=1; shift ;;
            *) note "safe: unknown arg $1"; exit 2 ;;
        esac
    done
    [[ -n "$candidate" ]] || { note "safe: --candidate required"; exit 2; }

    # Guards — every refusal leaves the pin untouched.
    if (( surfaces_clear != 1 )); then
        note "REFUSED: --surfaces-clear attestation missing. Pass it ONLY after the changelog review cleared the non-gate surfaces (GUIDE 2c VI-mode / 2d hooks+settings / 2e CLI flags)."
        record_outcome "$candidate" "safe-refused" "no-surfaces-clear"
        exit 3
    fi
    if [[ -z "$gate_evidence" ]] || ! _check_gate_evidence "$gate_evidence" "$candidate"; then
        record_outcome "$candidate" "safe-refused" "gate-evidence"
        exit 3
    fi

    # Idempotency: already on the candidate → success no-op.
    local effective
    effective=$(cc_version_effective "$NEXUS_ROOT/package.json" "$PACKAGE" "$NEXUS_ROOT" 2>/dev/null || true)
    if [[ "$effective" == "$candidate" ]]; then
        note "safe: effective version is already $candidate — nothing to do"
        exit 0
    fi

    # Single-flight lock (mkdir is atomic; stale-lock recovery is manual
    # by design — a torn apply needs eyes, not a silent re-run).
    mkdir -p "$AUTO_DIR" 2>/dev/null || true
    if ! mkdir "$AUTO_DIR/apply.lock" 2>/dev/null; then
        note "REFUSED: $AUTO_DIR/apply.lock held — another apply in flight (or a crashed one; inspect, then rmdir)"
        exit 7
    fi
    trap 'rmdir "$AUTO_DIR/apply.lock" 2>/dev/null || true' EXIT

    # ---- GUIDE Step 5: pin bump + local install + watcher restart ----
    # Snapshot prior pin for rollback.
    local prior_pin had_prior=0
    if prior_pin=$(cc_version_read_local_pin "$NEXUS_ROOT" 2>/dev/null); then
        had_prior=1
    fi
    rollback_pin() {
        if (( had_prior == 1 )); then
            cc_version_write_local_pin "$prior_pin" "$NEXUS_ROOT" \
                && note "rollback: local pin restored to $prior_pin"
        else
            rm -f "$(cc_version_local_pin_path "$NEXUS_ROOT")" 2>/dev/null \
                && note "rollback: local pin removed (floor resumes)"
        fi
    }

    note "safe: bumping operator-local pin ${effective:-?} -> $candidate (gate evidence: $gate_evidence)"
    if ! cc_version_write_local_pin "$candidate" "$NEXUS_ROOT"; then
        note "FAILED: could not write local pin"
        record_outcome "$candidate" "safe-failed" "pin-write"
        exit 4
    fi

    if ! "$INSTALL_CMD"; then
        note "FAILED: install ($INSTALL_CMD) — rolling back pin; prior binary stands (install never wipes node_modules)"
        rollback_pin
        record_outcome "$candidate" "safe-failed" "install"
        notify "cc-auto-update: install of $candidate FAILED; pin rolled back"
        exit 4
    fi

    local running
    running=$("$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [[ "$running" != "$candidate" ]]; then
        note "FAILED: binary reports '$running', expected $candidate — rolling back pin"
        rollback_pin
        record_outcome "$candidate" "safe-failed" "verify running=$running"
        notify "cc-auto-update: post-install verify FAILED ($running != $candidate); pin rolled back"
        exit 5
    fi
    note "safe: install verified — binary reports $candidate"

    # Watcher restart so FUTURE spawns (and the Step-5b respawn) load
    # the new binary. Ordering per GUIDE: this MUST precede the
    # orchestrator kill so the watcher serving the recovery runs
    # current code.
    local watcher_rc=0
    if [[ -n "${CC_AUTO_WATCHER_RESTART_CMD:-}" ]]; then
        # shellcheck disable=SC2086 — operator/test override is a command line
        $CC_AUTO_WATCHER_RESTART_CMD || watcher_rc=$?
    else
        "$NEXUS_ROOT/monitor/svc.sh" restart watcher || watcher_rc=$?
    fi
    if (( watcher_rc != 0 )); then
        note "FAILED: watcher restart — pin + install stand (new binary active for future spawns), NOT proceeding to orchestrator restart"
        record_outcome "$candidate" "safe-failed" "watcher-restart"
        notify "cc-auto-update: watcher restart FAILED after bump to $candidate — manual: monitor/svc.sh restart watcher"
        exit 6
    fi
    note "safe: watcher restarted onto $candidate"

    # ---- GUIDE Step 5b: orchestrator restart under watchdog ----------
    # Pre-flight: the session pin is the whole seamlessness story. A
    # stale/absent pin degrades the respawn to a COLD spawn (context
    # lost) — never kill in that state.
    local pin_file="$STATE_DIR/orchestrator-session-id" sid="" jsonl=""
    sid=$(tr -d '[:space:]' < "$pin_file" 2>/dev/null || true)
    if ! printf '%s' "$sid" | grep -qE "$_UUID_RE"; then
        note "ABORT restart: orchestrator session pin absent/malformed ($pin_file) — a kill now would COLD-SPAWN (context lost). Bump itself is complete."
        record_outcome "$candidate" "safe-bumped-restart-aborted" "stale-pin"
        notify "cc-auto-update: bumped to $candidate but orchestrator restart aborted (stale session pin) — workspace is version-split"
        exit 21
    fi
    jsonl="$PROJECTS_DIR/$(_slug "$NEXUS_ROOT")/$sid.jsonl"
    if [[ ! -f "$jsonl" ]]; then
        note "ABORT restart: pinned session transcript missing ($jsonl). Bump itself is complete."
        record_outcome "$candidate" "safe-bumped-restart-aborted" "missing-jsonl"
        notify "cc-auto-update: bumped to $candidate but orchestrator restart aborted (pinned transcript missing) — workspace is version-split"
        exit 21
    fi

    # ---- Hand the idle-wait → restart off to a DETACHED process ------
    # The bump (pin + install + watcher restart) is now COMPLETE and
    # stands on its own. What remains — wait for the orchestrator to be
    # idle, then context-preservingly kill+respawn it — must NOT block
    # this foreground call: the whole apply runs inside the cc-update
    # evaluator's Bash tool call, which the harness SIGTERMs at a hard
    # 600s ceiling. A blocking idle-wait there is killed mid-loop before
    # it can restart anything (the daily exit-143 failure). So disown the
    # wait+restart to a fully detached background process and RETURN
    # PROMPTLY. setsid → a new session that survives this evaluator
    # window's retirement; stdio → a log file with stdin from /dev/null
    # so the harness Bash call does not block on an open pipe; the child
    # is NOT harness-tracked. The detached `restart-orchestrator` verb
    # owns the bounded idle-wait, the force-restart-on-cap, and the
    # re-validate-before-kill. Decoupling the wait from the 600s ceiling
    # also lets the operator raise the idle cap freely so a natural idle
    # is caught first (minimizing token-repeat) without risking timeout.
    local detached_log="$AUTO_DIR/detached-restart.log"
    if [[ "${CC_AUTO_RESTART_INLINE:-0}" == "1" ]]; then
        # Test seam: run the restart synchronously in a subshell. `trap -
        # EXIT` clears the inherited apply.lock-cleanup trap so the
        # subshell's own exit does not release the lock out from under
        # this still-running function; the lock is released by the real
        # EXIT trap when `safe` itself returns just below.
        ( trap - EXIT; cmd_restart_orchestrator --candidate "$candidate" --sid "$sid" ) \
            >> "$detached_log" 2>&1 || true
    else
        setsid nohup bash "$SELF_PATH" restart-orchestrator \
            --candidate "$candidate" --sid "$sid" \
            >> "$detached_log" 2>&1 < /dev/null &
        disown 2>/dev/null || true
    fi
    note "safe: bump to $candidate complete; orchestrator restart handed off to a detached watcher (idle-wait → force-restart-on-cap; log: $detached_log)"
    record_outcome "$candidate" "safe-bumped-restart-handoff" "detached sid=$sid"
    notify "cc-auto-update: $candidate applied; orchestrator restart handed off to a detached watcher (workspace version-split until it restarts)"
    exit 0
}

# ---- verb: restart-orchestrator -----------------------------------------
# The DETACHED second half of `safe` — auto-invoked by cmd_safe via a
# disowned `bash "$0" restart-orchestrator` re-exec (and the direct
# unit-test entry point for the restart behaviours). Runs the bounded
# idle-wait and the context-preserving kill+respawn that cmd_safe
# deliberately does NOT run in its 600s-bound foreground call. Re-derives
# everything from the session pin + env, so it is self-contained across
# the re-exec. See the file-header exit-code table (0/21/22/23/24).
#
# The single kill issued anywhere here is `tmux kill-window` — never a
# cmdline-pattern kill (lint-no-mass-kill.sh).
cmd_restart_orchestrator() {
    local candidate="" sid=""
    while (( $# > 0 )); do
        case "$1" in
            --candidate) candidate="$2"; shift 2 ;;
            --sid)       sid="$2"; shift 2 ;;
            *) note "restart-orchestrator: unknown arg $1"; exit 2 ;;
        esac
    done
    [[ -n "$candidate" ]] || { note "restart-orchestrator: --candidate required"; exit 2; }
    [[ -n "$sid" ]]       || { note "restart-orchestrator: --sid required"; exit 2; }

    # Record our own PID so an operator can find/inspect/kill this disowned
    # process (it is deliberately NOT harness-tracked). BASHPID is the live
    # process PID even under the test's inline subshell.
    mkdir -p "$AUTO_DIR" 2>/dev/null || true
    printf '%s\n' "$BASHPID" > "$STATE_DIR/restart-orchestrator.pid" 2>/dev/null || true

    local pin_file="$STATE_DIR/orchestrator-session-id"
    local jsonl="$PROJECTS_DIR/$(_slug "$NEXUS_ROOT")/$sid.jsonl"

    # _pin_still_ours — rc 0 iff the live pin still names OUR sid and its
    # transcript still exists. Re-checked at start AND at fire time: the
    # idle-wait can run for minutes, during which the operator (or a
    # respawn) could re-pin. A kill after the pin moved would cold-spawn a
    # DIFFERENT session — exactly the context loss the gate forbids.
    _pin_still_ours() {
        local cur
        cur=$(tr -d '[:space:]' < "$pin_file" 2>/dev/null || true)
        [[ "$cur" == "$sid" && -f "$jsonl" ]]
    }
    # _already_on_candidate — rc 0 iff the pinned transcript already holds
    # a record stamped with the candidate version. The session earns such
    # a record only once a process running the CANDIDATE binary writes to
    # it; while the orchestrator runs the OLD binary it stamps the old
    # version. So a candidate stamp ⇒ the orchestrator already respawned
    # onto the new binary on its own (e.g. the version-aware watcher
    # self-restart, issue #186) ⇒ a kill would be needless. Forward-only
    # bumps make this unambiguous (the candidate string cannot have been
    # written by an earlier run of this session).
    _already_on_candidate() {
        grep -qF "\"version\":\"$candidate\"" "$jsonl" 2>/dev/null
    }

    # Fire-time pre-flight #1 (start of the detached run): the session pin
    # is the whole seamlessness story; if it is already stale/absent, a
    # kill would COLD-SPAWN (context lost). Never kill in that state.
    if ! _pin_still_ours; then
        note "ABORT restart: session pin no longer names $sid (or transcript $jsonl gone) — a kill now would COLD-SPAWN a different session (context lost). Bump itself is complete."
        record_outcome "$candidate" "safe-bumped-restart-aborted" "pin-stale-pre-wait sid=$sid"
        notify "cc-auto-update: orchestrator restart aborted ($candidate) — session pin stale before the wait; workspace is version-split"
        exit 21
    fi
    if _already_on_candidate; then
        note "NO-OP restart: pinned transcript already holds a \"version\":\"$candidate\" record — the orchestrator respawned onto the new binary on its own. Nothing to kill."
        record_outcome "$candidate" "safe-bumped-restart-noop" "already-on-candidate-pre-wait sid=$sid"
        exit 24
    fi

    # Wait for the orchestrator to be IDLE: killing mid-turn discards the
    # in-flight turn's tokens. monitor/pane-state.sh is the only sanctioned
    # classifier (autosuggest renders identically to typed input) — and it
    # is INDEX-keyed, so resolve the window NAME → index. A name that
    # resolves to no live tmux window is a hard error: we cannot read the
    # idle state, and a kill without a readable state would risk killing a
    # window that isn't the orchestrator. Fail loud (23), do NOT kill blind.
    #
    # On reaching the IDLE_WAIT cap we do NOT defer (the old exit-20 bug:
    # during active drives the orchestrator was never idle, so the restart
    # simply never happened and the workspace stayed version-split). Per
    # the operator decision we FORCE-restart instead: the pinned session
    # resumes from its transcript, so a mid-turn kill only re-runs the
    # interrupted turn (some repeated token generation), never lost work.
    # Force applies ONLY to the readable-but-busy case with a valid pin —
    # the aborts above/below stay aborts.
    #
    # Re-resolve the index INSIDE the loop, every poll — do NOT cache it
    # across the (up to IDLE_WAIT-long) wait. The index is only stable
    # while tmux `renumber-windows` is off (its default, and this nexus's
    # setting): with renumber on, closing a lower-indexed window would
    # shift the orchestrator's index out from under a cached value, and
    # we'd then poll — or ultimately kill the NAME of — a different window
    # than the one we read. Re-resolving costs one extra `tmux
    # list-windows` per poll and removes that coupling entirely. (First
    # match wins on a duplicate name, matching `tmux kill-window -t
    # <name>`'s own lowest-index resolution, so the read pane and the
    # killed pane stay the same window; persistent duplicate orchestrators
    # are in any case reaped by the watcher's _respawn.sh dedup.)
    local waited=0 st="" raw="" target_idx="" forced=0
    while :; do
        target_idx=$(_resolve_target_index "$TARGET_WINDOW")
        if [[ -z "$target_idx" ]]; then
            note "ABORT restart: orchestrator window '$TARGET_WINDOW' did not resolve to a tmux index — cannot read idle state, will not kill blind. Bump itself is complete."
            record_outcome "$candidate" "safe-bumped-restart-aborted" "target-window-unresolved=$TARGET_WINDOW"
            notify "cc-auto-update: orchestrator restart aborted ($candidate) — window '$TARGET_WINDOW' not found in tmux; workspace is version-split"
            exit 23
        fi
        # Query by INDEX (the original bug was querying by name → empty).
        raw=$("$PANE_STATE_CMD" "$target_idx" 2>/dev/null)
        st=$(printf '%s\n' "$raw" | sed -n 's/.*state=\([a-z-]*\).*/\1/p' | head -1)
        if [[ -z "$st" ]]; then
            # NO parseable `state=` verdict. With an already-resolved index
            # this is NOT "busy" — it is a broken probe (helper crashed, or
            # the window vanished). Distinct from `state=empty`, which IS a
            # valid verdict (renderer transient, claude alive) and parses to
            # st=empty → handled as a normal non-idle wait → force-restarts
            # at the cap. An UNREADABLE probe must fail loud, never be
            # misread as "busy" and force-killed against an unknown pane.
            note "ABORT restart: orchestrator pane-state UNREADABLE for window index $target_idx (probe output: '${raw:-<empty>}'). Idle cannot be confirmed and the pane identity is unknown, so we will not force-kill. Bump itself is complete."
            record_outcome "$candidate" "safe-bumped-restart-aborted" "pane-state-unreadable idx=$target_idx"
            notify "cc-auto-update: orchestrator restart aborted ($candidate) — idle-state unreadable (idx=$target_idx); workspace is version-split"
            exit 23
        fi
        [[ "$st" == "idle" ]] && break
        if (( waited >= IDLE_WAIT )); then
            note "FORCE restart: orchestrator never idle within ${IDLE_WAIT}s (last state=$st) — restarting anyway per operator decision. The pinned session resumes from its transcript, so the mid-turn kill only re-runs the interrupted turn (repeated tokens), not lost work."
            forced=1
            break
        fi
        sleep "$IDLE_POLL"
        waited=$(( waited + IDLE_POLL ))
    done
    if (( forced )); then
        note "restart: idle-wait cap (${IDLE_WAIT}s) reached, orchestrator busy — FORCE-restarting (window index $target_idx); arming the restart watchdog"
    else
        note "restart: orchestrator idle (window index $target_idx) — arming the restart watchdog"
    fi

    # Fire-time pre-flight #2 (after the up-to-IDLE_WAIT wait, BEFORE we
    # arm the watchdog or kill): re-validate the pin and the
    # already-respawned gate. Doing it here — not after arming — avoids
    # spawning a watchdog that would then wait out its deadline for a kill
    # that never comes.
    if ! _pin_still_ours; then
        note "ABORT restart: session pin moved during the idle-wait (no longer $sid, or transcript gone) — NOT killing (would cold-spawn). Bump itself is complete."
        record_outcome "$candidate" "safe-bumped-restart-aborted" "pin-stale-at-fire sid=$sid"
        notify "cc-auto-update: orchestrator restart aborted ($candidate) — pin moved at fire time; workspace is version-split"
        exit 21
    fi
    if _already_on_candidate; then
        note "NO-OP restart: orchestrator came up on $candidate on its own during the wait — NOT killing."
        record_outcome "$candidate" "safe-bumped-restart-noop" "already-on-candidate-at-fire sid=$sid"
        exit 24
    fi

    # Watchdog worker (REQUIRED by GUIDE Step 5b — a script can detect,
    # only an agent can FIX). Clear any stale armed marker first: the
    # marker's fresh write by THIS watchdog is the arm signal.
    rm -f "$STATE_DIR/restart-watchdog-armed" "$STATE_DIR/restart-watchdog-failed" 2>/dev/null || true
    if "$TMUX_CMD" list-windows -F '#W' 2>/dev/null | grep -Fxq -- "$WATCHDOG_WINDOW"; then
        "$TMUX_CMD" kill-window -t "$WATCHDOG_WINDOW" 2>/dev/null || true
    fi
    local wd_template="${CC_AUTO_WATCHDOG_PROMPT_TEMPLATE:-$NEXUS_ROOT/monitor/cc-auto-update-watchdog-prompt.md}"
    local wd_prompt="$AUTO_DIR/watchdog-prompt.md"
    if ! _cc_auto_render_prompt "$wd_template" "$wd_prompt" \
            "CANDIDATE=$candidate" "NEXUS_ROOT=$NEXUS_ROOT" \
            "STATE_DIR=$STATE_DIR" "TARGET_WINDOW=$TARGET_WINDOW"; then
        note "ABORT restart: watchdog prompt template missing ($wd_template). Bump itself is complete."
        record_outcome "$candidate" "safe-bumped-restart-aborted" "watchdog-template"
        notify "cc-auto-update: orchestrator restart aborted ($candidate) — watchdog template missing"
        exit 22
    fi
    if ! "$SPAWN_CMD" -n "$WATCHDOG_WINDOW" -c "$NEXUS_ROOT" -p "$wd_prompt" >/dev/null 2>&1; then
        note "ABORT restart: watchdog spawn failed. Bump itself is complete; NOT killing the orchestrator unwatched."
        record_outcome "$candidate" "safe-bumped-restart-aborted" "watchdog-spawn"
        notify "cc-auto-update: orchestrator restart aborted ($candidate) — watchdog spawn failed"
        exit 22
    fi

    # Kill-last ordering: the kill fires ONLY after the watchdog's armed
    # marker appears (it has recorded its baseline and started its watch
    # loop).
    waited=0
    while [[ ! -f "$STATE_DIR/restart-watchdog-armed" ]]; do
        if (( waited >= ARM_WAIT )); then
            note "ABORT restart: watchdog never armed within ${ARM_WAIT}s. NOT killing the orchestrator unwatched. Bump itself is complete."
            record_outcome "$candidate" "safe-bumped-restart-aborted" "watchdog-never-armed"
            notify "cc-auto-update: orchestrator restart aborted ($candidate) — watchdog never armed; inspect window $WATCHDOG_WINDOW"
            exit 22
        fi
        sleep "$ARM_POLL"
        waited=$(( waited + ARM_POLL ))
    done
    note "restart: watchdog armed — killing $TARGET_WINDOW ($( ((forced)) && echo 'forced: busy past idle cap' || echo idle ); the watcher's absent-target recovery resumes the pinned session on the new binary)"
    "$TMUX_CMD" kill-window -t "$TARGET_WINDOW"
    if (( forced )); then
        record_outcome "$candidate" "safe-bumped-restart-forced" "restart-triggered-forced sid=$sid"
        notify "cc-auto-update: $candidate applied; orchestrator FORCE-restarted (busy past idle cap) under watchdog — pinned session resumes"
    else
        record_outcome "$candidate" "safe-bumped-restarted" "restart-triggered sid=$sid"
        notify "cc-auto-update: $candidate applied autonomously; orchestrator restart in progress under watchdog"
    fi
    exit 0
}

# ---- verb: compat-pr ------------------------------------------------------

# Open compat PRs are recognised by the `cc-compat` marker in the title
# (the convention this routine itself follows when opening one:
# `cc-compat <version>: <summary>`).
_compat_list_json() {
    local token
    token=$("$MINT_CMD") || { note "compat-pr: token mint failed"; return 1; }
    [[ -n "$token" ]] || { note "compat-pr: token mint returned empty (fail-loud guard)"; return 1; }
    GH_TOKEN="$token" "$GH_CMD" pr list --repo "$COMPAT_REPO" --state open \
        --search 'cc-compat in:title' --json number,title,url
}

cmd_compat_pr() {
    local mode="${1:-}"; shift || true
    case "$mode" in
        list)
            _compat_list_json
            ;;
        auto)
            local candidate="" findings=""
            while (( $# > 0 )); do
                case "$1" in
                    --candidate) candidate="$2"; shift 2 ;;
                    --findings)  findings="$2"; shift 2 ;;
                    *) note "compat-pr auto: unknown arg $1"; exit 2 ;;
                esac
            done
            [[ -n "$candidate" ]] || { note "compat-pr auto: --candidate required"; exit 2; }
            [[ -f "$findings" ]]  || { note "compat-pr auto: --findings <file> required and must exist"; exit 2; }
            command -v jq >/dev/null 2>&1 || { note "compat-pr auto: jq required"; exit 2; }
            local json n
            json=$(_compat_list_json) || exit 1
            n=$(printf '%s' "$json" | jq 'length' 2>/dev/null || echo 0)
            case "$n" in
                0)
                    note "compat-pr: none-found — open a new PR on $COMPAT_REPO (base dev, title 'cc-compat $candidate: <summary>') and HOLD for operator approval"
                    printf 'none-found\n'
                    exit 10
                    ;;
                1)
                    local num url token
                    num=$(printf '%s' "$json" | jq -r '.[0].number')
                    url=$(printf '%s' "$json" | jq -r '.[0].url')
                    token=$("$MINT_CMD") || exit 1
                    [[ -n "$token" ]] || { note "compat-pr: token mint returned empty"; exit 1; }
                    if GH_TOKEN="$token" "$GH_CMD" pr comment "$num" --repo "$COMPAT_REPO" --body-file "$findings"; then
                        note "compat-pr: commented findings for $candidate on existing $url"
                        record_outcome "$candidate" "compat-pr-commented" "pr=$url"
                        printf 'commented %s\n' "$url"
                        exit 0
                    fi
                    note "compat-pr: comment on $url FAILED"
                    exit 1
                    ;;
                *)
                    note "compat-pr: $n open cc-compat PRs — ambiguous; caller must judge which covers this break and comment via 'compat-pr comment <number> --findings <file>'"
                    printf '%s\n' "$json"
                    exit 11
                    ;;
            esac
            ;;
        comment)
            local num="${1:-}"; shift || true
            local candidate="" findings=""
            while (( $# > 0 )); do
                case "$1" in
                    --candidate) candidate="$2"; shift 2 ;;
                    --findings)  findings="$2"; shift 2 ;;
                    *) note "compat-pr comment: unknown arg $1"; exit 2 ;;
                esac
            done
            [[ "$num" =~ ^[0-9]+$ ]] || { note "compat-pr comment: PR number required"; exit 2; }
            [[ -f "$findings" ]] || { note "compat-pr comment: --findings <file> required"; exit 2; }
            local token
            token=$("$MINT_CMD") || exit 1
            [[ -n "$token" ]] || { note "compat-pr: token mint returned empty"; exit 1; }
            GH_TOKEN="$token" "$GH_CMD" pr comment "$num" --repo "$COMPAT_REPO" --body-file "$findings" || exit 1
            record_outcome "${candidate:-unknown}" "compat-pr-commented" "pr=$COMPAT_REPO#$num"
            ;;
        *)
            note "compat-pr: unknown mode '${mode:-}' (list|auto|comment)"
            exit 2
            ;;
    esac
}

# ---- verb: block ----------------------------------------------------------

cmd_block() {
    local candidate="" reason=""
    while (( $# > 0 )); do
        case "$1" in
            --candidate) candidate="$2"; shift 2 ;;
            --reason)    reason="$2"; shift 2 ;;
            *) note "block: unknown arg $1"; exit 2 ;;
        esac
    done
    [[ -n "$candidate" ]] || { note "block: --candidate required"; exit 2; }
    [[ -n "$reason" ]]    || { note "block: --reason required"; exit 2; }
    note "BLOCK: candidate=$candidate reason=$reason — NOT bumping; surfacing for the operator"
    record_outcome "$candidate" "block" "$reason"
    notify "cc-auto-update: $candidate BLOCKED ($reason) — operator attention needed"
    exit 0
}

# ---- verb: record-outcome ---------------------------------------------------

cmd_record_outcome() {
    local candidate="" decision="" detail=""
    while (( $# > 0 )); do
        case "$1" in
            --candidate) candidate="$2"; shift 2 ;;
            --decision)  decision="$2"; shift 2 ;;
            --detail)    detail="$2"; shift 2 ;;
            *) note "record-outcome: unknown arg $1"; exit 2 ;;
        esac
    done
    [[ -n "$candidate" && -n "$decision" ]] || { note "record-outcome: --candidate and --decision required"; exit 2; }
    record_outcome "$candidate" "$decision" "$detail"
}

# ---- dispatch ---------------------------------------------------------------

verb="${1:-}"; shift || true
case "$verb" in
    safe)                 cmd_safe "$@" ;;
    restart-orchestrator) cmd_restart_orchestrator "$@" ;;
    compat-pr)            cmd_compat_pr "$@" ;;
    block)                cmd_block "$@" ;;
    record-outcome)       cmd_record_outcome "$@" ;;
    *)                    usage ;;
esac
