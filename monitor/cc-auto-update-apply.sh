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
#   hold            write the durable restart-hold marker (nexus-code#513):
#                   the RUNNING watcher's reconcile honours it every tick,
#                   so a refused orchestrator restart STAYS refused.
#                   --reason required; --ttl-seconds / --until-version
#                   bound it. (The config `enabled` flag is read once at
#                   watcher startup and is NOT a hold.)
#   unhold          release the hold.
#   hold-status     print the hold and whether it is active (rc 0/1).
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
#   30  safe: DEFERRED by the deployment gate (nexus-code#512) — an open
#       PR touches the watcher restart path, or too many live agent
#       windows. NOTHING was applied; the safe-to-bump verdict is
#       recorded and the next daily fire retries. A recorded, unapplied
#       safe-to-bump is a complete result.
#   31  safe: bumped + watcher restarted, but the POST-RESTART INVARIANT
#       was violated (survivors of the old watcher group, or duplicate
#       watcher groups). The orchestrator restart is NOT handed off into
#       a duplicated-watcher world; operator inspection required.
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
#       respawn. Turn-boundary verdict (idle / autosuggest-only /
#       Monitor-handle working-background / working-self-paced /
#       idle-orphan-async — see _restart_eligible, nexus-code#514) →
#       outcome safe-bumped-restarted; idle-cap reached while POSITIVELY
#       busy → safe-bumped-restart-FORCED (operator decision: restart a
#       busy orchestrator anyway — the pinned session resumes from its
#       transcript, so a mid-turn kill only re-runs the interrupted turn,
#       repeating some tokens, never losing work).
#   21  ABORT — session pin went stale/absent (or transcript missing)
#       before the kill; a kill now would cold-spawn. No kill.
#   22  ABORT — watchdog template missing / spawn failed / never armed.
#       No kill (never kill the orchestrator unwatched).
#   23  ABORT — orchestrator window unresolved, or pane-state UNREADABLE
#       (no parseable verdict), or the wait hit its cap having seen
#       NOTHING but `state=empty` (the classifier never positively
#       resolved the pane — force-killing on a verdict that was never
#       established would kill an unknown; nexus-code#514). No kill.
#       (state=empty remains a VALID not-idle verdict — claude alive,
#       renderer blip — it keeps waiting; only an ALL-empty wait refuses
#       the force at the cap.)
#   25  ABORT — restart-hold active (nexus-code#513), or this detached
#       restart was SIGTERMed and wrote the hold itself so the reconcile
#       does not auto-refire the abort. No kill. Release: `unhold`.
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
# `_ensure_service_log` (your-org/nexus-code#484).
# shellcheck source=_log-mode.sh
source "$_self_dir/_log-mode.sh"

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

# ---- deployment-gate knobs (your-org/nexus-code#512) ----------------------
# The release gate asks "is this Claude Code binary safe?"; the deployment
# gate asks "is this nexus in a state where restarting the watcher is safe
# RIGHT NOW?" — the question the 2026-07-10 incident showed nobody asking.
# Live agent windows above this threshold defer the apply (0 disables the
# window gate; the count is still logged in the apply record either way).
GATE_MAX_LIVE_WINDOWS="${CC_AUTO_MAX_LIVE_WINDOWS:-$("$NEXUS_ROOT/config/load.sh" monitor.cc_auto_update.max_live_windows 8 2>/dev/null || echo 8)}"
# Window names that are infrastructure, not agents-at-risk (CSV; the
# orchestrator TARGET_WINDOW, the evaluator window and the restart
# watchdog are always exempt on top of these).
GATE_WINDOW_EXEMPT="${CC_AUTO_GATE_WINDOW_EXEMPT:-services}"
# Repo whose open PRs are checked for restart-path collisions, and the
# restart-path file set (CSV). An open PR touching any of these means the
# restart mechanics are KNOWN to be under repair — defer the apply.
GATE_REPO="${CC_AUTO_GATE_REPO:-${CC_AUTO_COMPAT_REPO:-your-org/nexus-code}}"
GATE_RESTART_PATHS="${CC_AUTO_GATE_RESTART_PATHS:-monitor/watcher/launcher.sh,monitor/watcher/main.sh,monitor/revive-watcher.sh,monitor/svc.sh,monitor/watcher/_version_restart.sh}"

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
    # Explicit mode at creation (your-org/nexus-code#484). Idempotent, and
    # cheap enough to sit on the log path: two syscalls once the file exists.
    _ensure_service_log "$APPLY_LOG"
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

# _restart_eligible <state> <raw_probe_line> — rc 0 iff the verdict is a
# TURN BOUNDARY, i.e. safe to kill for a context-preserving respawn.
#
# pane-state.sh can never emit a literal `idle` for an orchestrator that
# holds a Monitor handle (your-org/nexus-code#514): its refinement
# promotes an idle base verdict to `working-background` whenever mon>0,
# and the orchestrator permanently holds one (the watcher supervisor).
# Keying strictly on `idle` made the interlock structurally
# unsatisfiable — 7/7 recorded fires force-killed mid-turn at the cap.
#
# Every state below is a refinement of an IDLE BASE VERDICT (empty input
# row, no spinner — the turn has ended); what varies is only the pending
# WAKE mechanism, which any restart loses and the respawn + watcher
# nudge restore:
#   idle                nothing pending at all
#   autosuggest-only    idle; the input row is drawing a ghost
#   working-self-paced  between turns; a self-scheduled wakeup pends
#   idle-orphan-async   between turns; an EXTERNAL job (slurm, CI)
#                       pends — the job itself survives the kill
#   working-background  between turns — eligible ONLY in its
#                       Monitor-handle flavour (self-waking, no live
#                       child). The SHELL-driven flavour carries
#                       `bg_cpu=` on the emit line and has an in-flight
#                       fire-and-forget child process the kill would
#                       destroy: NOT eligible, keep waiting.
_restart_eligible() {
    local st="$1" raw="$2"
    case "$st" in
        idle|autosuggest-only|working-self-paced|idle-orphan-async)
            return 0 ;;
        working-background)
            [[ "$raw" != *"bg_cpu="* ]]
            return $? ;;
    esac
    return 1
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

# ---- deployment gate (your-org/nexus-code#512) -----------------------------

# _gate_default_pr_probe — print "number<TAB>path" lines, one per file of
# every open PR on $GATE_REPO. rc non-zero on any query failure (mint,
# network, gh) — the caller treats that as "cannot establish the restart
# path is unclaimed" and DEFERS, per the fail-safe contract. Overridable
# via CC_AUTO_GATE_PR_CMD (tests; also lets an operator wire a cache).
_gate_default_pr_probe() {
    local token
    token=$("$MINT_CMD") || return 1
    [[ -n "$token" ]] || return 1
    GH_TOKEN="$token" "$GH_CMD" pr list --repo "$GATE_REPO" --state open \
        --json number,files \
        --jq '.[] | .number as $n | .files[].path | "\($n)\t\(.)"'
}

# _gate_live_agent_windows — print the live tmux window names that count
# as agents-at-risk (everything except the orchestrator, this routine's
# own evaluator + watchdog windows, and the GATE_WINDOW_EXEMPT set).
_gate_live_agent_windows() {
    local names w e keep
    names=$("$TMUX_CMD" list-windows -F '#{window_name}' 2>/dev/null) || return 0
    while IFS= read -r w; do
        [[ -n "$w" ]] || continue
        keep=1
        for e in "$TARGET_WINDOW" "$WATCHDOG_WINDOW" "$CC_AUTO_WINDOW"; do
            [[ "$w" == "$e" ]] && { keep=0; break; }
        done
        if (( keep )); then
            local IFS=','
            for e in $GATE_WINDOW_EXEMPT; do
                [[ "$w" == "$e" ]] && { keep=0; break; }
            done
        fi
        (( keep )) && printf '%s\n' "$w"
    done <<<"$names"
    return 0
}

# _deployment_gate <candidate> — rc 0: proceed. rc 1: DEFER the apply
# (nothing bumped; the caller records + exits 30). Every deferral is a
# complete result — the verdict stands recorded and the next daily fire
# retries once conditions clear.
#
# Also records clone staleness vs origin/main (nexus-code#511's actual
# gap): `decisions.tsv` used to read `target-window-unresolved=…` as if
# it were a code bug while the live clone was 114 commits behind the fix.
# One `behind_main=N` field collapses that whole misdiagnosis class.
# Staleness is WARN-only, deliberately: a stale clone runs the stale
# apply.sh regardless, so a defer here could never have protected the
# incident tree — surfacing is what was missing.
_deployment_gate() {
    local candidate="$1"

    # 1. Clone staleness (warn + record, never defer).
    local behind="unknown"
    if [[ -d "$NEXUS_ROOT/.git" ]] && command -v git >/dev/null 2>&1; then
        timeout 10 git -C "$NEXUS_ROOT" fetch --quiet origin main >/dev/null 2>&1 || true
        behind=$(git -C "$NEXUS_ROOT" rev-list --count HEAD..origin/main 2>/dev/null) || behind="unknown"
    fi
    if [[ "$behind" =~ ^[0-9]+$ ]] && (( behind > 0 )); then
        note "WARN deployment-gate: this clone is $behind commits behind origin/main — the apply.sh executing right now may predate merged fixes. Deploy: git -C $NEXUS_ROOT pull --ff-only origin main"
        notify "cc-auto-update: clone is $behind commits behind origin/main — merged fixes are not deployed"
    fi

    # 2. Open PRs touching the watcher restart path. The restart being
    #    under repair is EXACTLY when an autonomous restart must not fire
    #    (2026-07-10: the evaluator restarted the watcher while PR #503 —
    #    open precisely because that restart path decapitates — sat
    #    unmerged with 15 agents mid-flight).
    local pr_lines
    if ! pr_lines=$("${CC_AUTO_GATE_PR_CMD:-_gate_default_pr_probe}" 2>/dev/null); then
        note "DEFER: deployment-gate could not query open PRs on $GATE_REPO — cannot establish the restart path is unclaimed; deferring the apply (retried at the next daily fire)"
        record_outcome "$candidate" "safe-deferred" "restart-path-pr-query-failed behind_main=$behind"
        return 1
    fi
    local hits="" prn path gp
    while IFS=$'\t' read -r prn path; do
        [[ -n "$prn" && -n "$path" ]] || continue
        local IFS=','
        for gp in $GATE_RESTART_PATHS; do
            if [[ "$path" == "$gp" ]]; then
                case " $hits " in *" PR$prn "*) ;; *) hits="${hits:+$hits }PR$prn" ;; esac
            fi
        done
    done <<<"$pr_lines"
    if [[ -n "$hits" ]]; then
        note "DEFER: open PR(s) touch the watcher restart path ($hits on $GATE_REPO) — the restart mechanics are under repair; deferring the apply. A recorded, unapplied safe-to-bump is a complete result."
        record_outcome "$candidate" "safe-deferred" "deferred-pending-${hits// /,} behind_main=$behind"
        notify "cc-auto-update: $candidate is safe but the apply is DEFERRED — $hits touches the watcher restart path"
        return 1
    fi

    # 3. Live agent windows. Restarting the watcher under N mid-flight
    #    agents is a different risk from restarting an idle nexus; the
    #    threshold is explicit and the count is always in the record.
    local windows count
    windows=$(_gate_live_agent_windows)
    count=$(awk 'NF { n++ } END { print n+0 }' <<<"$windows")
    note "deployment-gate: live agent windows=$count (max=$GATE_MAX_LIVE_WINDOWS) behind_main=$behind restart-path PRs: none"
    _cc_auto_log_decision "$AUTO_DIR" "$candidate" "deployment-gate" \
        "live_windows=$count behind_main=$behind restart_path_prs=none"
    if (( GATE_MAX_LIVE_WINDOWS > 0 )) && (( count > GATE_MAX_LIVE_WINDOWS )); then
        note "DEFER: $count live agent windows > max $GATE_MAX_LIVE_WINDOWS ($(tr '\n' ' ' <<<"$windows")) — deferring the apply to a quieter fire"
        record_outcome "$candidate" "safe-deferred" "live-windows=$count>max=$GATE_MAX_LIVE_WINDOWS behind_main=$behind"
        notify "cc-auto-update: $candidate is safe but the apply is DEFERRED — $count agent windows in flight (max $GATE_MAX_LIVE_WINDOWS)"
        return 1
    fi
    return 0
}

# _watcher_restart_invariant <old_pid> <old_pgid> — post-restart invariant
# (nexus-code#512 item 3): survivors of the OLD watcher's process group
# must be 0, and at most one live watcher group may exist for this root.
# "The restart happened to be clean" is not evidence that it is safe —
# emit the invariant and fail LOUD when violated, instead of discovering
# a duplicate-emit storm later. Read-only (ps); never kills anything.
# rc 0 = holds (or unobservable — WARNed, not failed); rc 1 = violated.
_watcher_restart_invariant() {
    local old_pid="$1" old_pgid="$2"
    command -v ps >/dev/null 2>&1 || {
        note "WARN restart-invariant: ps unavailable — invariant unobservable"
        return 0
    }
    # Give TERM'd stragglers of the old group a bounded settle window
    # (tries tunable for tests via CC_AUTO_INVARIANT_TRIES).
    local tries=0 survivors=0 ps_out
    local max_tries="${CC_AUTO_INVARIANT_TRIES:-5}"
    while :; do
        ps_out=$(ps -eo pgid=,pid=,args= 2>/dev/null || true)
        survivors=0
        if [[ "$old_pgid" =~ ^[0-9]+$ ]]; then
            survivors=$(awk -v g="$old_pgid" '$1 == g { n++ } END { print n+0 }' <<<"$ps_out")
        fi
        (( survivors == 0 )) && break
        (( tries >= max_tries )) && break
        tries=$(( tries + 1 ))
        sleep 2
    done
    # Distinct live watcher groups for THIS root — absolute-path match on
    # the args column (never a suffix: /tmp test fixtures stay invisible).
    local groups
    groups=$(awk -v p="$NEXUS_ROOT/monitor/watcher/main.sh" \
        'index($0, p) { print $1 }' <<<"$ps_out" | sort -u | grep -c . || true)
    [[ "$groups" =~ ^[0-9]+$ ]] || groups=0
    if (( survivors > 0 )) || (( groups > 1 )); then
        note "restart-invariant VIOLATED: old-pgid(${old_pgid:-?}) survivors=$survivors, live watcher groups=$groups (want 0 and exactly 1) — two watchers racing monitor/.state is the #491/#503 decapitation class"
        return 1
    fi
    if (( groups == 0 )); then
        # The launcher's own post-spawn verification owns "did it come
        # up"; an empty match here is a fixture/probe limitation, not a
        # duplicate hazard — WARN, do not fail.
        note "WARN restart-invariant: no live watcher group matched $NEXUS_ROOT/monitor/watcher/main.sh (unobservable in this environment); survivors=0 held"
    else
        note "restart-invariant holds: old-group survivors=0, exactly one live watcher group"
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

    # ---- deployment gate (nexus-code#512): is restarting SAFE right now?
    # Runs before any state mutation, so a deferral leaves nothing
    # half-applied. Distinct from the release gate above: that one vetted
    # the BINARY; this one vets the ACT of deploying it.
    if ! _deployment_gate "$candidate"; then
        exit 30
    fi

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
    # current code. Snapshot the OLD watcher's identity first — the
    # post-restart invariant below needs it.
    local old_wpid="" old_wpgid=""
    old_wpid=$(tr -d '[:space:]' < "$STATE_DIR/watcher.pid" 2>/dev/null || true)
    [[ "$old_wpid" =~ ^[0-9]+$ ]] \
        && old_wpgid=$(ps -o pgid= -p "$old_wpid" 2>/dev/null | tr -d '[:space:]')
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

    # Post-restart invariant (nexus-code#512): do not TREAT a restart as
    # clean — OBSERVE that it was. A violation means two watcher trees
    # may be racing monitor/.state; handing the orchestrator restart off
    # into that world would compound it.
    if ! _watcher_restart_invariant "$old_wpid" "$old_wpgid"; then
        record_outcome "$candidate" "safe-bumped-restart-invariant-violated" \
            "old_pid=${old_wpid:-?} old_pgid=${old_wpgid:-?}"
        notify "cc-auto-update: $candidate applied but the watcher restart VIOLATED the post-restart invariant (old-group survivors or duplicate groups) — inspect before anything else restarts"
        exit 31
    fi

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
    # Explicit mode at creation (your-org/nexus-code#484) — both branches
    # below open this log with a bare `>>`.
    _ensure_service_log "$detached_log"
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

    # A SIGTERM to this detached process is a DELIBERATE abort — it is
    # setsid-disowned, so nothing routine signals it. Pre-#513, dying
    # silently was indistinguishable from a crash, and the dead pid is
    # precisely what re-opens the reconcile's single-flight guard: the
    # abort CAUSED the refire (2026-07-10: SIGTERM at 04:08, auto-refire
    # at 04:09:55, and again every cooldown until a pin revert). Write
    # the durable hold for THIS candidate before dying — "stopped on
    # purpose" stays stopped; a NEWER candidate re-arms (until_version).
    _restart_abort_to_hold() {
        if _cc_auto_write_restart_hold "$AUTO_DIR" \
                "sigterm-detached-restart pid=$BASHPID" "" "$candidate"; then
            note "SIGTERM: detached restart deliberately aborted — restart-hold written (until_version=$candidate); the reconcile will NOT re-fire for this candidate. Release: $SELF_PATH unhold"
        else
            note "SIGTERM: detached restart aborted but the restart-hold could NOT be written — the reconcile WILL re-fire after its cooldown; write the hold manually ($SELF_PATH hold --reason …)"
        fi
        record_outcome "$candidate" "safe-bumped-restart-aborted" "sigterm-hold-written"
        notify "cc-auto-update: detached orchestrator restart SIGTERMed — hold set for $candidate (release: unhold)"
        exit 25
    }
    trap '_restart_abort_to_hold' TERM

    # Hold pre-flight (nexus-code#513): a held restart does not wait,
    # does not arm, does not kill.
    if _cc_auto_restart_hold_active "$AUTO_DIR" "$candidate"; then
        note "ABORT restart: restart-hold active ($(_cc_update_field "$AUTO_DIR/restart-hold" reason 2>/dev/null || echo '?')) — not waiting, not killing. Bump itself is complete. Release: $SELF_PATH unhold"
        record_outcome "$candidate" "safe-bumped-restart-held" "hold-pre-wait"
        exit 25
    fi

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

    # Wait for the orchestrator to reach a TURN BOUNDARY: killing
    # mid-turn discards the in-flight turn's tokens. monitor/pane-state.sh
    # is the only sanctioned classifier (autosuggest renders identically
    # to typed input) — and it is INDEX-keyed, so resolve the window NAME
    # → index. A name that resolves to no live tmux window is a hard
    # error: we cannot read the idle state, and a kill without a readable
    # state would risk killing a window that isn't the orchestrator. Fail
    # loud (23), do NOT kill blind.
    #
    # The gate accepts every turn-boundary verdict, not just the literal
    # `idle` — which a Monitor-holding orchestrator can NEVER produce
    # (nexus-code#514; see _restart_eligible above).
    #
    # On reaching the IDLE_WAIT cap we do NOT defer (the old exit-20 bug:
    # during active drives the orchestrator was never idle, so the restart
    # simply never happened and the workspace stayed version-split). Per
    # the operator decision we FORCE-restart instead: the pinned session
    # resumes from its transcript, so a mid-turn kill only re-runs the
    # interrupted turn (some repeated token generation), never lost work.
    # Force applies ONLY when the classifier POSITIVELY resolved the pane
    # at least once during the wait (busy, user-typing, a shell-driven
    # working-background, …). A wait that saw NOTHING but `state=empty`
    # never established what the pane is doing — force-killing on a
    # verdict that never resolved would kill an unknown, so it aborts
    # loud (23) instead and the reconcile retries after its cooldown
    # (nexus-code#514 item 3). The aborts above/below stay aborts.
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
    local waited=0 st="" raw="" target_idx="" forced=0 resolved_seen=0
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
        [[ "$st" != "empty" ]] && resolved_seen=1
        _restart_eligible "$st" "$raw" && break
        if (( waited >= IDLE_WAIT )); then
            if (( resolved_seen == 0 )); then
                note "ABORT restart: state=empty for the ENTIRE ${IDLE_WAIT}s wait — the classifier never positively resolved this pane to busy OR to a turn boundary. Refusing to force-kill on a verdict that was never established; the reconcile retries after its cooldown, and a turn boundary now satisfies the eligibility gate. Bump itself is complete."
                record_outcome "$candidate" "safe-bumped-restart-aborted" "never-resolved-empty-at-cap idx=$target_idx"
                notify "cc-auto-update: orchestrator restart aborted ($candidate) — pane never positively resolved within ${IDLE_WAIT}s; will retry"
                exit 23
            fi
            note "FORCE restart: orchestrator not at a turn boundary within ${IDLE_WAIT}s (last state=$st) — restarting anyway per operator decision. The pinned session resumes from its transcript, so the mid-turn kill only re-runs the interrupted turn (repeated tokens), not lost work."
            forced=1
            break
        fi
        sleep "$IDLE_POLL"
        waited=$(( waited + IDLE_POLL ))
    done
    if (( forced )); then
        note "restart: idle-wait cap (${IDLE_WAIT}s) reached, orchestrator busy — FORCE-restarting (window index $target_idx); arming the restart watchdog"
    else
        note "restart: orchestrator at a turn boundary (state=$st, window index $target_idx) — arming the restart watchdog"
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
    # A hold can arrive DURING the (up to IDLE_WAIT-long) wait — an
    # operator writing it is precisely how "do not kill what you are
    # about to kill" is said to a detached process (nexus-code#513).
    if _cc_auto_restart_hold_active "$AUTO_DIR" "$candidate"; then
        note "ABORT restart: restart-hold arrived during the wait — NOT killing. Bump itself is complete. Release: $SELF_PATH unhold"
        record_outcome "$candidate" "safe-bumped-restart-held" "hold-at-fire"
        exit 25
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

# ---- verbs: hold / unhold / hold-status (your-org/nexus-code#513) ----------
# The durable, tick-checked representation of "this restart is
# deliberately held". The RUNNING watcher's reconcile honours it every
# pass, and the detached restart re-checks it before the kill — unlike
# `monitor.cc_auto_update.enabled`, which is read ONCE at watcher startup
# and is inert on a live watcher. Shell-portable by design: the
# 2026-07-10 workaround (hand-sourcing _cc-version.sh for a pin revert)
# silently no-op'd under zsh.

cmd_hold() {
    local reason="" ttl="" until_version=""
    while (( $# > 0 )); do
        case "$1" in
            --reason)        reason="$2"; shift 2 ;;
            --ttl-seconds)   ttl="$2"; shift 2 ;;
            --until-version) until_version="$2"; shift 2 ;;
            *) note "hold: unknown arg $1"; exit 2 ;;
        esac
    done
    [[ -n "$reason" ]] || { note "hold: --reason required (the hold is read by humans and audit rows)"; exit 2; }
    local expires=""
    if [[ -n "$ttl" ]]; then
        [[ "$ttl" =~ ^[0-9]+$ ]] || { note "hold: --ttl-seconds must be an integer"; exit 2; }
        expires=$(( $(date +%s) + ttl ))
    fi
    if ! _cc_auto_write_restart_hold "$AUTO_DIR" "$reason" "$expires" "$until_version"; then
        note "hold: FAILED to write $AUTO_DIR/restart-hold"
        exit 1
    fi
    note "hold: restart-hold set (reason=$reason${expires:+ expires=$(date -d "@$expires" -Is 2>/dev/null || echo "$expires")}${until_version:+ until_version=$until_version}). The reconcile will log 'reconcile-held' once and stay silent; release with: $SELF_PATH unhold"
    notify "cc-auto-update: orchestrator restart HELD ($reason)"
    exit 0
}

cmd_unhold() {
    if [[ ! -f "$AUTO_DIR/restart-hold" ]]; then
        note "unhold: no restart-hold present — nothing to release"
        exit 0
    fi
    rm -f "$AUTO_DIR/restart-hold" "$AUTO_DIR/reconcile-held.acked" 2>/dev/null || true
    _cc_auto_log_decision "$AUTO_DIR" "-" "restart-hold-released" "by=unhold"
    note "unhold: restart-hold released — the reconcile may fire again after its cooldown"
    notify "cc-auto-update: restart-hold released"
    exit 0
}

cmd_hold_status() {
    local f="$AUTO_DIR/restart-hold"
    if [[ ! -f "$f" ]]; then
        printf 'no hold\n'
        exit 1
    fi
    cat "$f"
    local effective
    effective=$(cc_version_effective "$NEXUS_ROOT/package.json" "$PACKAGE" "$NEXUS_ROOT" 2>/dev/null || true)
    if [[ -n "$effective" ]] && _cc_auto_restart_hold_active "$AUTO_DIR" "$effective"; then
        printf 'status=ACTIVE (effective=%s)\n' "$effective"
        exit 0
    fi
    printf 'status=EXPIRED/inactive (effective=%s)\n' "${effective:-unresolvable}"
    exit 1
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
    hold)                 cmd_hold "$@" ;;
    unhold)               cmd_unhold "$@" ;;
    hold-status)          cmd_hold_status "$@" ;;
    *)                    usage ;;
esac
