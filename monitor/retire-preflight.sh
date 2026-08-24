#!/usr/bin/env bash
# retire-preflight.sh — the SYNCHRONOUS go/no-go gate the orchestrator
# MUST run immediately before any `tmux kill-window` on a worker window.
#
# Why this script exists (the 2026-06-15 incident):
#   The orchestrator killed worker window `pr277-liveness-review` 9 s
#   after the operator typed a directive into it, destroying an
#   in-flight interaction. Forensic timeline:
#     13:29     — worker ran `ng wrap-up` → `window-retain` logged
#                 (wrapped, retire-eligible).
#     13:38:20  — the OPERATOR submitted a prompt into the window
#                 (UserPromptSubmit hook fired → user-prompt stamp
#                 written; jsonl recorded the turn).
#     13:38:29  — the orchestrator ran `tmux kill-window`, having
#                 decided to retire from the 13:37:47 poll snapshot
#                 (`wrapped + idle`). The 13:38:20 submit was not yet
#                 reflected — the watcher poll attributes engagement
#                 with up to ~60 s lag, and no poll ran in the 9 s gap.
#   The load-bearing gap: the retire path did a NO synchronous re-check
#   of fresh operator input before the irreversible kill. This script
#   is that re-check. It reads LIVE state (not the ~60 s-stale poll
#   snapshot), so a just-arrived operator prompt counts even though the
#   poll has not attributed it yet.
#
# Design contract:
#   - Cheap and SIDE-EFFECT-FREE: only reads (pane capture via
#     pane-state.sh + a handful of small state-file reads). Writes
#     nothing, mutates no state.
#   - CONSERVATIVE: any doubt → no-go. A deferred retire costs one wake
#     cycle and is fully recoverable; a wrong-go destroys live operator
#     context (the incident). When the safety check itself cannot run
#     (pane-state unreadable, helper library missing), that is doubt →
#     no-go.
#
# What it checks (any one → no-go):
#   1. LIVE pane-state (monitor/pane-state.sh, the authoritative
#      autosuggest-vs-real-input classifier — never a raw capture-pane
#      grep). `user-typing` means the operator is in the input box
#      right now; `busy` / `working-*` means work is in flight; the
#      retire decision was made against a stale "idle" snapshot.
#      `unknown` (probe could not run) is doubt → no-go.
#   2. FRESH operator submit, attributed SYNCHRONOUSLY off the raw
#      UserPromptSubmit stamp (`$STATE_DIR/user-prompt/<window>`) — the
#      deterministic contract event Claude Code writes the instant a
#      prompt is submitted, immune to the TUI redraw distortion that
#      corrupts capture-pane reads. The stamp is read DIRECTLY so a
#      submit counts even before the watcher poll has attributed it.
#      A submit is the OPERATOR'S (→ no-go) when its epoch is newer
#      than any known machine input (paste-followup / machine-input.tsv
#      / spawn) by more than the attribution slack, it landed within
#      the freshness window, AND its stamped session-id is NOT the
#      window's own spawn session-id. This is the exact gap the incident
#      exposed. The session-id qualifier closes a second false positive
#      (coembed-283-followup, 2026-07-17): a submit carrying the
#      window's OWN session-id is the worker's pane self-activity
#      (autosuggest / post-wrap typing / its own tool loop), never the
#      operator — who drives a DIFFERENT session and never raw-types into
#      a spawned worker's pane — so it must not pin a wrapped window open.
#      SCOPE: a human raw-typing into the pane would stamp the same own
#      session-id (the hook can't tell them apart); that path is out of
#      scope by the never-raw-type invariant, backstopped by check-1
#      (`user-typing`/`busy` veto, which runs first). See check 2's body.
#   1b. A LIVE required-skeptic marker
#      (`$STATE_DIR/skeptic/pending/<window>`, skills/nexus.skeptic). When
#      a wrap-up requires an independent skeptic pass, it writes this
#      marker; it clears only when a skeptic returns a verdict (or an
#      operator waives). While present, the task is not done → no-go.
#      This is the enforcement that makes `require` a hard gate rather
#      than an advisory print.
#   1c. The TARGET'S OWN REPORT asking for another skeptic pass
#      (`disposition: second-pass`, read via `ng skeptic-disposition`).
#      A disposition naming a further pass is a machine-readable request
#      that the window STAY; this gate used to never read it, and retired
#      a reviewer that had asked for another round (your-org/nexus-code
#      #813). `unreadable`, an unrecognised state, and "the probe could
#      not run" all refuse — distinctly, and separately from the states
#      that positively say the gate does not apply. Released by a
#      `skeptic-verdict` for this window logged after the report, or by
#      `ng skeptic resolve <window> --reason "…" --disposition`.
#   3. A VALID operator-engaged mark (`_openg_marked`, the watcher's own
#      self-expiring validity predicate). Catches the case where the
#      poll DID already attribute the engagement.
#
# Inputs:
#   $1   <window-name>            — the tmux window the orchestrator is
#                                   about to kill (state files are keyed
#                                   on the name). Also accepts a window
#                                   <index> or <session>:<window> form,
#                                   in which case the name is resolved
#                                   from tmux.
#        --now <epoch>            — override the clock (tests).
#        --state-dir <path>       — override STATE_DIR (tests).
#        --fresh-seconds <n>      — override the operator-submit
#                                   freshness window (tests).
#        --pane-state <token>     — inject the pane-state verdict instead
#                                   of invoking pane-state.sh (tests).
#        --reports-dir <path>     — override the reports corpus scanned by
#                                   check 1c (tests). Deliberately NOT a
#                                   way to inject the disposition VERDICT:
#                                   the real `ng skeptic-disposition` still
#                                   runs, so a test exercises the corpus
#                                   lookup and the parser, not a stub of
#                                   both.
#
# Output (single line, key=value, machine-parseable):
#   safe=<0|1> window=<name> pane=<state> reason=<free text…>
#   `safe=1` ⇒ go; `safe=0` ⇒ no-go. Grep `safe=0` to abort the kill.
#
# Exit codes (the orchestrator ABORTS the kill on any non-zero):
#   0  go      — no fresh operator signal; safe to proceed.
#   1  no-go   — fresh operator input / engagement detected; ABORT.
#   2  bad usage.
#   3  requested window does not exist in tmux (mirrors pane-state.sh
#      issue #140: a typo'd window must fail loud, not read as "gone").
#
# The orchestrator MUST treat exit 1, 2, AND 3 as "do not kill" — only
# a clean `safe=1` exit 0 authorizes the irreversible `tmux kill-window`.

set -u

usage() {
    cat <<'EOF' >&2
usage: retire-preflight.sh <window-name|index|session:window>
                           [--now <epoch>] [--state-dir <path>]
                           [--fresh-seconds <n>] [--pane-state <token>]
EOF
    exit 2
}

# ---- arg parsing ----------------------------------------------------------
target=
now_override=
state_dir_override=
fresh_override=
pane_state_override=
reports_dir_override=
while (( $# > 0 )); do
    case "$1" in
        --now)           now_override="${2:-}";        shift 2 || usage ;;
        --state-dir)     state_dir_override="${2:-}";   shift 2 || usage ;;
        --fresh-seconds) fresh_override="${2:-}";       shift 2 || usage ;;
        --pane-state)    pane_state_override="${2:-}";  shift 2 || usage ;;
        --reports-dir)   reports_dir_override="${2:-}"; shift 2 || usage ;;
        -h|--help)       usage ;;
        --)              shift; target="${1:-}"; break ;;
        -*)              usage ;;
        *)               target="$1"; shift ;;
    esac
done
[[ -n "$target" ]] || usage

now="${now_override:-$(date +%s)}"
[[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || self_dir="."

# The kill-authorisation allowlist (your-org/nexus-code#603). Sourced,
# not inlined, so the gate this script applies and the one every other
# consumer applies cannot drift apart — a second copy of the state
# vocabulary is how `over-limit` ended up permitted here while
# skills/nexus.window-cleanup said "Do NOT close".
#
# Its absence is doubt, and this script's contract is doubt → no-go.
if [[ -r "$self_dir/_bookkeeping.sh" ]]; then
    # shellcheck source=monitor/_bookkeeping.sh
    source "$self_dir/_bookkeeping.sh"
else
    printf 'safe=0 window=%s pane=unknown reason=%s\n' "$target" \
        "cannot source monitor/_bookkeeping.sh (the kill-authorisation allowlist) — refusing kill"
    exit 1
fi

# ---- resolve STATE_DIR (mirrors pane-state.sh / worker-heartbeat.sh) ------
if [[ -n "$state_dir_override" ]]; then
    STATE_DIR="$state_dir_override"
elif [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    STATE_DIR="$NEXUS_STATE_DIR"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    STATE_DIR="$NEXUS_ROOT/monitor/.state"
else
    STATE_DIR="$self_dir/.state"
fi
export STATE_DIR

# ---- resolve the window NAME and a pane-state target ----------------------
# State files are keyed on the window NAME. pane-state.sh takes an
# index / session:window. Accept either form on input and resolve the
# missing half from tmux.
win_name=""
pane_target=""
have_tmux=0
command -v tmux >/dev/null 2>&1 && have_tmux=1

if [[ "$target" =~ ^[0-9]+$ ]] || [[ "$target" =~ ^[^:]+:[0-9]+$ ]]; then
    # Given an index/target — resolve the name for state-file lookups.
    pane_target="$target"
    if (( have_tmux )); then
        win_name=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null) || win_name=""
    fi
    [[ -n "$win_name" ]] || win_name="$target"
else
    # Given a name — resolve its tmux index for the pane probe.
    win_name="$target"
    if (( have_tmux )); then
        # Exact-match the window name → index. Last match wins (rare dup).
        pane_target=$(tmux list-windows -F '#{window_name}|#{window_index}' 2>/dev/null \
            | awk -F'|' -v w="$win_name" '$1 == w { idx = $2 } END { if (idx != "") print idx }')
        if [[ -z "$pane_target" ]]; then
            # Name not present in tmux. With --pane-state injected (tests,
            # or a caller that already has the verdict) we proceed; else
            # this is a vanished/typo'd window — fail loud (exit 3) so the
            # caller does not read silence as "safe to kill".
            if [[ -z "$pane_state_override" ]]; then
                printf 'retire-preflight.sh: no such tmux window: %s\n' "$win_name" >&2
                exit 3
            fi
        fi
    fi
fi

emit() {
    # emit <safe 0|1> <pane-state> <reason…>
    local safe="$1" pane="$2"; shift 2
    printf 'safe=%s window=%s pane=%s reason=%s\n' \
        "$safe" "$win_name" "$pane" "$*"
}

# ---- check 1: LIVE pane-state --------------------------------------------
# The authoritative classifier — distinguishes operator-typed bright text
# from Claude Code's dim autosuggest ghost text, which a raw capture-pane
# grep cannot. Active states veto the kill; `unknown` (probe failed) is
# doubt and also vetoes.
pane_state="${pane_state_override:-}"
if [[ -z "$pane_state" ]]; then
    pane_script=""
    if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/pane-state.sh" ]]; then
        pane_script="$NEXUS_ROOT/monitor/pane-state.sh"
    elif [[ -x "$self_dir/pane-state.sh" ]]; then
        pane_script="$self_dir/pane-state.sh"
    fi
    if [[ -n "$pane_script" && -n "$pane_target" ]]; then
        # Re-sample past an INDETERMINATE reading (your-org/nexus-code
        # #603). `empty` is a transient renderer state — a paste
        # re-render, a status-bar swap — that settles within a cycle or
        # two. Since the gate now (correctly) refuses to kill on it, a
        # single unlucky sample would defer a legitimate retirement for
        # a whole wake cycle. Sampling a few times costs ~1s and lets
        # the common transient resolve in-place; a reading that stays
        # indeterminate across all samples is a real "don't know" and
        # is reported as such. This is a LIVENESS accommodation only —
        # it can turn indeterminate into a definite verdict, never the
        # reverse, so it cannot manufacture an authorisation.
        for _ps_try in 1 2 3; do
            pane_line=$("$pane_script" "$pane_target" 2>/dev/null) || pane_line=""
            pane_state=$(printf '%s' "$pane_line" | sed -n 's/.*state=\([a-z-]*\).*/\1/p')
            [[ -n "$pane_state" ]] || pane_state="unknown"
            bk_state_is_indeterminate "$pane_state" || break
            (( _ps_try < 3 )) && sleep "${RETIRE_PREFLIGHT_RESAMPLE_SECONDS:-0.4}"
        done
    fi
    [[ -n "$pane_state" ]] || pane_state="unknown"
fi

# your-org/nexus-code#603 — this gate is now an ALLOWLIST with a
# default-DENY arm (monitor/_bookkeeping.sh: bk_pane_kill_authorized),
# not a denylist with a permissive `*)` catch-all.
#
# The old shape enumerated the states that REFUSE and let everything
# else through. `empty` fell through — the state pane-state.sh's own
# header documents as "the renderer is in an ambiguous state … treat as
# don't know yet, try again next cycle". On 2026-07-29 window 0:7 read
# `state=empty` while showing a live spinner 4m38s into a verification
# pass with a `git fetch` running and a message queued behind it.
# Following the documented escalation recipe on that reading would have
# destroyed the work. `over-limit` fell through the same hole, despite
# skills/nexus.window-cleanup saying "Do NOT close" for it since #87.
#
# Enumerating what is SAFE inverts the failure mode: a state nobody has
# considered — including one a future pane-state.sh adds — refuses the
# kill instead of authorising it.
#
# The two refusal reasons are reported distinctly. `active` means the
# window is doing something; `indeterminate` means we could not tell,
# which is a DEFERRAL (retry next cycle, or wait for `absent`), not a
# verdict about the worker.
if ! bk_pane_kill_authorized "$pane_state"; then
    case "$pane_state" in
        user-typing)
            emit 0 "$pane_state" "operator is typing in the input box right now" ;;
        busy|working-background|working-self-paced)
            emit 0 "$pane_state" "agent work in flight (pane=$pane_state) — retire decision was made against a stale idle snapshot" ;;
        queued)
            emit 0 "$pane_state" "a message is queued behind an in-flight turn — killing now destroys both the turn and the unsubmitted input" ;;
        blocked)
            emit 0 "$pane_state" "pane sitting on an overlay (blocked) — surface to operator, do not kill" ;;
        over-limit)
            emit 0 "$pane_state" "pane is suspended on a usage limit, not finished — closing forfeits loaded context and in-flight work; the watcher owns the resume" ;;
        empty)
            emit 0 "$pane_state" "pane-state is INDETERMINATE (empty means \"don't know yet\", not \"finished\") — refusing kill; wait for 'absent' (renderer empty AND no live claude in the tree) or a plain 'idle'" ;;
        unknown)
            emit 0 "$pane_state" "pane-state could not be read — cannot verify safety, refusing kill" ;;
        *)
            emit 0 "$pane_state" "$(printf '%s' "$BK_ERR" | tr '\n' ' ')" ;;
    esac
    exit 1
fi

# ---- source the watcher read-helpers (for checks 1b + 2 + 3) --------------
# Reuse the watcher's OWN attribution + mark-validity primitives so the
# preflight attributes a submit identically to the poll (consistency is
# the point). The library is pure functions (no top-level code), so
# sourcing is side-effect-free. If it cannot be sourced, the core
# incident fix (check 2) still runs via the self-contained fallback
# below; only the richer mark-validity check (3) is skipped. Sourced
# BEFORE check 1b so that check can reuse the watcher's skeptic-fidelity
# helper (`_idle_skeptic_orphaned`) — the same definition the idle probe
# uses, so the preflight and the poll agree on what an orphaned marker is.
probe_lib=""
if [[ -n "${NEXUS_ROOT:-}" && -r "$NEXUS_ROOT/monitor/watcher/_idle_probe.sh" ]]; then
    probe_lib="$NEXUS_ROOT/monitor/watcher/_idle_probe.sh"
elif [[ -r "$self_dir/watcher/_idle_probe.sh" ]]; then
    probe_lib="$self_dir/watcher/_idle_probe.sh"
fi
have_probe=0
if [[ -n "$probe_lib" ]]; then
    # shellcheck disable=SC1090
    source "$probe_lib" 2>/dev/null && have_probe=1
fi

# ---- check 1b: unresolved required-skeptic marker -------------------------
# The skeptic protocol (skills/nexus.skeptic) writes a pending marker at
# $STATE_DIR/skeptic/pending/<window> when a wrap-up REQUIRES an
# independent skeptic validation pass. It is cleared ONLY when a skeptic
# returns a verdict (or an operator waives). While it persists, the task
# is by definition NOT done — retiring the window would strand the
# required validation. This is the gate that makes `require` real.
#
# Fidelity (emit/exemption fidelity): the marker is refreshed by the
# WORKER's own await loop, so its mere presence does NOT prove a skeptic is
# reviewing. A marker with a LIVE skeptic (or still within the spawn grace)
# is a genuine no-go — refuse the kill. But a marker gone ORPHANED (fresh,
# yet NO live skeptic past the grace window) is a stuck state, NOT live
# validation: blocking the kill on it strands the window forever (exactly
# the all-night-linger bug). So on an orphaned marker the preflight ALLOWS
# the kill with a loud note — the orchestrator saw the matching
# `orphaned-skeptic-pending` signal from the poll and is consciously
# retiring it. When the fidelity helper is unavailable (probe lib missing),
# fall back to the original unconditional no-go (conservative: refuse).
sk_pending="$STATE_DIR/skeptic/pending/${win_name//[^a-zA-Z0-9_-]/_}"
if [[ -f "$sk_pending" ]]; then
    _sk_now=$(date +%s)
    if (( have_probe )) && declare -F _idle_skeptic_orphaned >/dev/null 2>&1 \
       && _idle_skeptic_orphaned "$win_name" "$_sk_now"; then
        # Orphaned marker: NOT live validation. Note it (stderr, so the single
        # stdout verdict stays authoritative) and fall through — the marker no
        # longer blocks retirement. Checks 2/3 below still guard operator
        # engagement, so a genuinely-in-use window is still refused.
        printf 'retire-preflight: skeptic-pending marker for %q is ORPHANED (no live skeptic past grace) — not blocking retirement\n' \
            "$win_name" >&2
    else
        # Name the SANCTIONED release path in the refusal (your-org/nexus-code#577).
        # When a verdict exists but the marker did not clear — the skeptic ran
        # against a different state dir, or the worker re-armed the gate after the
        # verdict returned — this refusal is permanent, and the operator's only
        # visible move was `rm` on the very marker that exists to prevent
        # hand-clearing. A guard that trains its own bypass is worse than no
        # guard, so the message points at the audited verb instead.
        printf 'retire-preflight: if a verdict DOES exist and this marker is stale, release it with an audit trail:\n' >&2
        printf '    monitor/ng skeptic resolve %q --reason "<where the verdict is>"\n' "$win_name" >&2
        printf '  (orchestrator-only; writes a rationale beside the marker and logs the event — do NOT rm it)\n' >&2
        emit 0 "$pane_state" "required skeptic has not returned a verdict (skeptic-pending marker live) — task not done, refusing kill; if a verdict exists, use \`ng skeptic resolve <window> --reason …\`"
        exit 1
    fi
fi

# ---- check 1c: an outstanding `disposition: second-pass` ------------------
# your-org/nexus-code#813. This gate decided retirement from PANE STATE and
# OPERATOR ENGAGEMENT and never read the report the target had just filed. On
# 2026-08-08 it returned `safe=1` for `bench272F-skeptic`, whose frontmatter
# said:
#
#     verdict: refuted
#     disposition: second-pass
#
# The preflight was correct on every axis it examined and wrong on the only
# one that mattered. The reviewer was retired; its target then burned ~75
# minutes across five `skeptic-channel.sh await` cycles returning exit 4,
# filed two spawn-skeptic requests that could never be serviced, and kept a
# require-marker live that blocked ITS retirement too. One bad retirement
# stranded two windows, and the failure was silent in both directions.
#
# A `disposition:` naming a further pass is a MACHINE-READABLE REQUEST that
# the window stay. Treating it as advisory defeats the point of writing it
# down. So it is read here, through the ONE parser (`ng skeptic-disposition`,
# which owns both the corpus lookup and the disposition grammar) rather than
# a second copy of the vocabulary living in this file.
#
# The state → verdict table, with `unknown` DISTINCT from every known answer:
#
#   no-report / absent / no-further-pass  → gate does not apply; proceed.
#       All three are POSITIVE findings — the corpus was enumerable, and
#       either nothing claims this window or its author did not ask for
#       another pass.
#   second-pass                           → NO-GO unless released (below).
#   unreadable                            → NO-GO. The author DID state a
#       disposition and we could not resolve it. #684's polarity: doubt about
#       a disposition resolves toward escalate, never toward suppress, and
#       this is the case where the author believes they have communicated and
#       has not. Named distinctly so the refusal says "fix the line", not
#       "you asked for another pass".
#   unknown / probe failed                → NO-GO. "I could not look" is not
#       "I looked and found none". This is the arm whose collapse into the
#       permissive one IS #813 (and #802, and #618/#707/#770).
#
# RELEASE. A gate with no release is a brick, and a brick trains its own
# bypass — the same reasoning that produced `ng skeptic resolve` (#577). Two
# releases, both requiring evidence that POST-DATES the request:
#   (a) a `skeptic-verdict` action-log event naming this window as
#       `target-window` after the report was written — the requested pass
#       actually happened. This is the normal, automatic release.
#   (b) a `skeptic/pending/.<window>.cleared-rationale` record newer than the
#       report — the orchestrator adjudicated and declined, on the record,
#       via `ng skeptic resolve <window> --reason "…" --disposition`.
disp_line=""
disp_rc=1
# SIBLING-FIRST, deliberately — the reverse of how this script resolves
# pane-state.sh, and the reverse of what the first draft did.
#
# `skeptic-disposition` is a verb this script's own commit introduced. Resolving
# `ng` from $NEXUS_ROOT first means the script and the verb it depends on come
# from DIFFERENT commits whenever the two trees differ — which is the standard
# nexus posture (secondary clone + inherited NEXUS_ROOT) and the state during
# any staged rollout. Measured on this suite at one commit, changing only the
# environment: NEXUS_ROOT unset -> 93 pass / 0 fail; NEXUS_ROOT pointed at a
# primary whose `ng` predates the verb -> 48 pass / 45 fail, every failure a
# `go` case turned into a refusal. That is `safe=0` for EVERY window, forever,
# with a reason naming nothing an operator can act on.
#
# The guard is fail-closed, which is right; the COUPLING was the defect.
# Sibling-first makes the script and its verb atomic at no cost:
# `skeptic-disposition` is a pure read, and `_report_corpus_dir` already pins
# the corpus to the primary regardless of which binary runs — so a sibling `ng`
# reads exactly the same reports the primary's would.
#
# General convention this is the first instance of: sibling-first for a pure
# READ, $NEXUS_ROOT-first only for shared STATE.
ng_bin=""
if [[ -x "$self_dir/ng" ]]; then
    ng_bin="$self_dir/ng"
elif [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/ng" ]]; then
    ng_bin="$NEXUS_ROOT/monitor/ng"
fi
if [[ -n "$ng_bin" ]]; then
    # Bounded: this gate is synchronous and pre-kill. A probe that hangs must
    # become a refusal (doubt), never an unbounded stall of the retire loop.
    if [[ -n "$reports_dir_override" ]]; then
        disp_line=$(timeout "${RETIRE_PREFLIGHT_DISPOSITION_TIMEOUT:-60}" \
            "$ng_bin" skeptic-disposition "$win_name" \
            --reports-dir "$reports_dir_override" 2>/dev/null); disp_rc=$?
    else
        disp_line=$(timeout "${RETIRE_PREFLIGHT_DISPOSITION_TIMEOUT:-60}" \
            "$ng_bin" skeptic-disposition "$win_name" 2>/dev/null); disp_rc=$?
    fi
fi
disp_state=$(sed -n 's/.*state=\([a-z-]*\).*/\1/p' <<<"$disp_line")
disp_report=$(sed -n 's/.*report=\([^ ]*\).*/\1/p' <<<"$disp_line")
disp_mtime=$(sed -n 's/.*report_mtime=\([0-9]*\).*/\1/p' <<<"$disp_line")
[[ "$disp_mtime" =~ ^[0-9]+$ ]] || disp_mtime=0

if [[ -z "$ng_bin" ]] || (( disp_rc != 0 )) || [[ -z "$disp_state" ]] \
   || [[ "$disp_state" == "unknown" ]]; then
    _why="disposition probe could not run"
    [[ -z "$ng_bin" ]] && _why="monitor/ng not found (disposition probe unavailable)"
    (( disp_rc == 124 )) && _why="disposition probe TIMED OUT"
    [[ "$disp_state" == "unknown" ]] && _why="reports corpus not enumerable"
    emit 0 "$pane_state" "cannot determine whether this window's report asks for another skeptic pass ($_why) — 'could not look' is not 'nothing to find' (your-org/nexus-code#813), refusing kill"
    exit 1
fi

case "$disp_state" in
    no-report|absent|no-further-pass)
        : ;;   # gate does not apply
    unreadable)
        # your-org/nexus-code#813 skeptic F4 — RELEASABLE. The PR's own standard
        # is "a gate with no release is a brick"; `second-pass` had two releases
        # and this arm had none, so a malformed disposition line made a window
        # un-retirable with no sanctioned way out but the `rm` this whole verb
        # family exists to replace. Same release as `second-pass`'s (b): an
        # audited resolution recorded AFTER the report.
        # `break` would be wrong here — it is loop control, not case control,
        # and inside a bare `case` bash warns and carries on. Use a flag.
        _disp_released=""
        _disp_rationale="$STATE_DIR/skeptic/pending/.${win_name//[^a-zA-Z0-9_-]/_}.cleared-rationale"
        if [[ -r "$_disp_rationale" ]]; then
            _rat_mt=$(stat -c %Y "$_disp_rationale" 2>/dev/null) || _rat_mt=0
            [[ "$_rat_mt" =~ ^[0-9]+$ ]] || _rat_mt=0
            (( _rat_mt > disp_mtime )) \
                && _disp_released="orchestrator recorded a resolution after the report ($_disp_rationale)"
        fi
        if [[ -n "$_disp_released" ]]; then
            printf 'retire-preflight: %q has an unreadable disposition, but %s. Not blocking.\n' \
                "$win_name" "$_disp_released" >&2
        else
            printf 'retire-preflight: %q filed a report with a disposition the parser could not resolve.\n' \
                "$win_name" >&2
            printf '  report: %s\n' "$disp_report" >&2
            printf '  FIX IT AT SOURCE: the frontmatter value must BE exactly `no-further-pass` or\n' >&2
            printf '  `second-pass`, alone after the colon. Then re-run this preflight.\n' >&2
            printf '  Or, if the line is right and the parser is wrong, decline on the record:\n' >&2
            printf '    monitor/ng skeptic resolve %q --reason "<why no further pass>" --disposition\n' "$win_name" >&2
            emit 0 "$pane_state" "the target's report states a disposition that could not be READ (report=$disp_report) — an unresolvable disposition is doubt, not consent; refusing kill"
            exit 1
        fi
        ;;
    second-pass)
        _disp_released=""
        # (b) operator adjudication on the record, newer than the request.
        _disp_rationale="$STATE_DIR/skeptic/pending/.${win_name//[^a-zA-Z0-9_-]/_}.cleared-rationale"
        if [[ -r "$_disp_rationale" ]]; then
            _rat_mt=$(stat -c %Y "$_disp_rationale" 2>/dev/null) || _rat_mt=0
            [[ "$_rat_mt" =~ ^[0-9]+$ ]] || _rat_mt=0
            (( _rat_mt > disp_mtime )) \
                && _disp_released="orchestrator recorded a resolution after the report ($_disp_rationale)"
        fi
        # (a) the requested pass actually ran: a verdict naming this window as
        #     the reviewed target, logged after the report was written.
        if [[ -z "$_disp_released" && -f "$STATE_DIR/action-log.jsonl" ]] \
           && command -v jq >/dev/null 2>&1; then
            _v_ts=$(grep '"event":"skeptic-verdict"' "$STATE_DIR/action-log.jsonl" 2>/dev/null \
                      | jq -r --arg w "$win_name" \
                          'select(.["target-window"] == $w) | .ts' 2>/dev/null \
                      | tail -1)
            if [[ -n "$_v_ts" ]]; then
                _v_epoch=$(date -d "$_v_ts" +%s 2>/dev/null || echo "")
                [[ "$_v_epoch" =~ ^[0-9]+$ ]] && (( _v_epoch > disp_mtime )) \
                    && _disp_released="a skeptic verdict reviewing this window was recorded at $_v_ts, after the report"
            fi
        fi
        if [[ -n "$_disp_released" ]]; then
            printf 'retire-preflight: %q asked for a second pass and it was satisfied — %s. Not blocking.\n' \
                "$win_name" "$_disp_released" >&2
        else
            printf 'retire-preflight: %q filed a report ASKING for another skeptic pass:\n' "$win_name" >&2
            printf '  report: %s\n' "$disp_report" >&2
            printf '  disposition: second-pass\n' >&2
            printf '  Retiring it now strands the reviewer its target is waiting for — the target\n' >&2
            printf '  then loops on `skeptic-channel.sh await` exit 4 forever, indistinguishable\n' >&2
            printf '  from "the skeptic has not started yet" (your-org/nexus-code#813).\n' >&2
            printf '  EITHER spawn the next-pass skeptic (its verdict releases this gate), OR\n' >&2
            printf '  decline on the record:\n' >&2
            printf '    monitor/ng skeptic resolve %q --reason "<why no further pass>" --disposition\n' "$win_name" >&2
            emit 0 "$pane_state" "the target's own report states \`disposition: second-pass\` (report=$disp_report) and no further pass has been recorded — the reviewer is still owed a round, refusing kill; decline on the record with \`ng skeptic resolve <window> --reason … --disposition\`"
            exit 1
        fi
        ;;
    *)
        # DEFAULT-DENY. A disposition state nobody here enumerated — including
        # one a future parser adds — refuses the kill instead of authorising
        # it. This is the shape `bk_pane_kill_authorized` already establishes
        # for pane states, applied to the same decision on a second axis.
        emit 0 "$pane_state" "unrecognised disposition state '$disp_state' from the target's report (report=$disp_report) — a state this gate has never heard of is doubt, refusing kill"
        exit 1
        ;;
esac

# ---- check 2: FRESH, operator-attributed user-prompt submit ---------------
# THE incident fix. Read the raw UserPromptSubmit stamp directly so a
# just-submitted prompt counts even though the poll has not run. Attribute
# it exactly as the watcher does: a submit newer than every known machine
# input by more than the slack is the operator's.
#
# Freshness window: defaults to the operator-engaged change-TTL
# (monitor.operator_engaged_change_ttl_seconds, default 600) so the gate
# stays aligned with how long an engagement is otherwise held. A submit
# older than this — already answered and handled — does not pin the
# window open (the operator-engaged mark would likewise have self-expired).
fresh_seconds="${fresh_override:-${MONITOR_RETIRE_PREFLIGHT_FRESH_SECONDS:-}}"
if [[ ! "$fresh_seconds" =~ ^[0-9]+$ ]]; then
    fresh_seconds=""
    if (( have_probe )) && declare -F _openg_change_ttl_seconds >/dev/null 2>&1; then
        fresh_seconds=$(_openg_change_ttl_seconds 2>/dev/null)
    fi
    [[ "$fresh_seconds" =~ ^[0-9]+$ ]] || fresh_seconds=600
fi

# up_epoch: newest UserPromptSubmit stamp for the window (raw read).
up_epoch=0
if (( have_probe )) && declare -F _openg_user_prompt_epoch >/dev/null 2>&1; then
    up_epoch=$(_openg_user_prompt_epoch "$win_name" 2>/dev/null)
else
    up_stamp="$STATE_DIR/user-prompt/$win_name"
    if [[ -f "$up_stamp" ]]; then
        up_epoch=$(awk -F'\t' 'NR == 1 { print $1; exit }' "$up_stamp" 2>/dev/null)
    fi
fi
[[ "$up_epoch" =~ ^[0-9]+$ ]] || up_epoch=0

if (( up_epoch > 0 )); then
    # machine_epoch: newest known machine input (paste-followup / unstick
    # nudge / spawn). When the probe lib is present use its authoritative
    # multi-source resolver; otherwise fall back to machine-input.tsv only
    # (the dominant signal — paste-followup.sh stamps it BEFORE pasting).
    machine_epoch=0
    if (( have_probe )) && declare -F _openg_machine_input_epoch >/dev/null 2>&1; then
        machine_epoch=$(_openg_machine_input_epoch "$win_name" 2>/dev/null)
    else
        mi="$STATE_DIR/machine-input.tsv"
        if [[ -f "$mi" ]]; then
            # Column 2 is MICROSECONDS since your-org/nexus-code#679 and
            # SECONDS in rows written before it; both live in this
            # append-only file forever. `machine_epoch` is compared
            # against `up_epoch` (seconds) below, so normalise by
            # magnitude — the two ranges are five orders of magnitude
            # apart. Done inside the awk on purpose: this is the branch
            # taken when the probe lib is NOT loaded, so the shared
            # `_paste_epoch_seconds` helper is exactly what is missing here.
            # Getting it wrong biases the RETIREMENT gate: a raw
            # microsecond value always clears `machine_epoch >= up_epoch
            # - slack`, so every operator submit would read as machine
            # input and a window the operator is actively using could be
            # judged safe to retire.
            machine_epoch=$(awk -F'\t' -v w="$win_name" \
                '$1 == w && $2 ~ /^[0-9]+$/ {
                     v = $2 + 0
                     if (v >= 10000000000000) v = int(v / 1000000)
                     if (v > m) m = v
                 }
                 END { print m + 0 }' \
                "$mi" 2>/dev/null)
        fi
    fi
    [[ "$machine_epoch" =~ ^[0-9]+$ ]] || machine_epoch=0

    slack=120
    if (( have_probe )) && declare -F _openg_input_slack_seconds >/dev/null 2>&1; then
        slack=$(_openg_input_slack_seconds 2>/dev/null)
        [[ "$slack" =~ ^[0-9]+$ ]] || slack=120
    fi

    # Self-attribution guard (coembed-283-followup false positive,
    # 2026-07-17). Even with NO covering machine-input stamp, a submit
    # stamped with the window's OWN spawn session-id is machine/self
    # input (autosuggest / post-wrap typing / the worker's own tool
    # loop) UNDER THE OPERATOR'S STATED INVARIANT: the operator drives a
    # DIFFERENT Claude Code session and never raw-types into a spawned
    # worker's pane (they relay via paste-followup, which machine-stamps).
    # Such a submit must NOT read as operator re-engagement, else a
    # wrapped, self-active-only window is pinned open (the recurring
    # engaged-done + force-kill workaround).
    #
    # SCOPE / known limitation. The UserPromptSubmit hook fires INSIDE
    # the worker's own --session-id-pinned process, so a human raw-typing
    # a directive directly into the worker pane would ALSO stamp the
    # window's own session-id — indistinguishable here from self-activity
    # (the hook records no promptSource today). That raw-type path is out
    # of scope by the invariant above; its backstop is check-1, which
    # runs FIRST and vetoes on `user-typing` (live human) or `busy` /
    # `working-*` (the worker still processing the human's submit). The
    # residual exposure is the narrow window "human raw-types → worker
    # FULLY idles → preflight runs in the gap → no machine cover"; a
    # future hardening (record promptSource, treat `typed` as human) can
    # close it if the never-raw-type invariant ever weakens. A DIFFERENT
    # session-id keeps the pre-existing attribution — this is the
    # CONSERVATIVE fallback (e.g. the worker's session was replaced by a
    # resume/compaction), NOT the steady-state operator, who under the
    # invariant carries the same session-id.
    # Prefer the probe lib's shared predicate (identical to the watcher's
    # own attribution); self-contained session-id comparison when it is
    # unavailable.
    up_is_self=0
    if (( have_probe )) && declare -F _openg_prompt_is_self >/dev/null 2>&1; then
        _openg_prompt_is_self "$win_name" 2>/dev/null && up_is_self=1
    else
        pf_stamp_sid=""; pf_own_sid=""
        up_stamp="$STATE_DIR/user-prompt/$win_name"
        [[ -f "$up_stamp" ]] && pf_stamp_sid=$(awk -F'\t' 'NR == 1 { print $2; exit }' "$up_stamp" 2>/dev/null)
        pf_prov="$STATE_DIR/windows/${win_name//[^a-zA-Z0-9_-]/_}.json"
        if [[ -n "$pf_stamp_sid" && -f "$pf_prov" ]]; then
            if command -v jq >/dev/null 2>&1; then
                pf_own_sid=$(jq -r '.session_id // empty' "$pf_prov" 2>/dev/null)
            else
                pf_own_sid=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pf_prov" | head -1)
            fi
        fi
        [[ -n "$pf_stamp_sid" && -n "$pf_own_sid" && "$pf_stamp_sid" == "$pf_own_sid" ]] && up_is_self=1
    fi

    up_age=$(( now - up_epoch ))
    (( up_age < 0 )) && up_age=0
    # Operator-attributed iff newer than machine input by > slack AND not
    # the window's own self-activity.
    if (( up_epoch > machine_epoch + slack )) && (( up_age <= fresh_seconds )) && (( ! up_is_self )); then
        emit 0 "$pane_state" "fresh operator submit ${up_age}s ago not attributable to machine input (up=$up_epoch machine=$machine_epoch) — operator re-engaged since the retire decision"
        exit 1
    fi
fi

# ---- check 3: VALID operator-engaged mark ---------------------------------
# Belt-and-suspenders: the poll may already have attributed the
# engagement. `_openg_marked` is the watcher's self-expiring validity
# predicate (seeded, not invalidated by engaged-done/spawn, AND still
# corroborated by recent pane change). Skipped only if the lib is absent
# — check 2 above is the guaranteed synchronous backstop in that case.
if (( have_probe )) && declare -F _openg_marked >/dev/null 2>&1; then
    if _openg_marked "$win_name" 2>/dev/null; then
        src=""
        if declare -F _openg_lookup >/dev/null 2>&1; then
            src=$(_openg_lookup "$win_name" 2>/dev/null | cut -f4)
        fi
        emit 0 "$pane_state" "valid operator-engaged mark (src=${src:-engaged}) — window belongs to the operator"
        exit 1
    fi
fi

# ---- go -------------------------------------------------------------------
emit 1 "$pane_state" "no fresh operator input or engagement — safe to retire"
exit 0
