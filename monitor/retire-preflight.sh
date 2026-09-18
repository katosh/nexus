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
#   1d. A LIVE OBLIGATION on which this window is the DEBTOR
#      (`$STATE_DIR/obligations/`, monitor/_obligations.sh). 1b asks whether
#      somebody still owes THIS window; 1d asks the converse — whether THIS
#      window still owes somebody — and nothing asked it before
#      your-org/nexus-code#845. `sk911` was retired at `safe=1` while it owed
#      `papercuts` a delta re-run, because every gate above answers "is
#      anyone typing", not "is this window's counterpart still waiting on
#      it". Default-DENY over the edge state: `live` and `unknown` refuse;
#      only `settled`, `void-pairing-closed` (the reviewer ran `ng skeptic
#      close` on the creditor's channel), `void-superseded` (a later reviewer
#      is pinned to the same creditor) and `void-creditor-absent` (the
#      creditor window is positively not in tmux) release.
#      A FILED VERDICT IS NOT A RELEASE — it discharges one ROUND, not the
#      PAIRING. Keying the release on the verdict (the first version of this
#      check) closed the edge at the exact instant the hazard began, and the
#      recorded `sk911` timeline replayed through it returns `safe=1`.
#      See monitor/_obligations.sh and the replay in monitor/test-obligations.sh.
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

usage() {
    cat <<'EOF' >&2
usage: retire-preflight.sh <window-name|index|session:window>
                           [--now <epoch>] [--state-dir <path>]
                           [--fresh-seconds <n>] [--pane-state <token>]
                           [--reports-dir <path>]
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
_argloop_prev_1=-1; while (( $# > 0 )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
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
# …AND under the name the CHILDREN read (your-org/nexus-code#1335, #1369).
# `monitor/ng`'s resolver honours `NEXUS_STATE_DIR` at highest precedence and
# never reads `STATE_DIR`, so exporting only the latter scoped this script's
# READS and left every child's WRITES on the inherited root: a `--state-dir`
# fixture run wrote its three gate-audit rows into the operator's live
# `action-log.jsonl` — 10,275 of 30,530 rows (33.7%) measured on #1369, ~121
# suite runs at 24 rows each on #1335. In production this is a no-op: with no
# override, STATE_DIR already equals what the child would have resolved. It
# diverges exactly when a caller overrode it, which is the intent. The three
# `log-action` sites below ALSO carry the prefix explicitly, so a reader of
# any one of them sees the scoping without having to find this line.
export NEXUS_STATE_DIR="$STATE_DIR"

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
# `RETIRE_PREFLIGHT_PANE_LINE` supplies the raw pane-state line on the
# `--pane-state` path, which otherwise never assigns one. Same test seam and
# same safety argument as `RETIRE_PREFLIGHT_PANE_PID`: the line feeds only
# ADVISORY CLAUSE text on a refusal that has already been decided, never the
# verdict — `pane_state` still comes from the override, so nothing here can
# turn a `safe=0` into a `safe=1`.
pane_line="${RETIRE_PREFLIGHT_PANE_LINE:-${pane_line:-}}"
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
# ── #1190: A REFUSAL THAT NAMES THE AWAIT LOOP IT IS PROTECTING ───────────
#
# A settled obligation and a closed pairing are different facts, recorded in
# different places, and only the second releases the reviewer's await loop. So a
# window sits in `wrapped-awaiting-protocol` with its debt already paid, the
# watcher emits `retire-eligible`, this gate answers `safe=0 … agent work in
# flight (pane=working-background)`, and BOTH ARE CORRECT — the work in flight
# IS the await loop that the missing sentinel is causing. Neither component can
# see the cause, and nothing anywhere names it.
#
# THIS DOES NOT CLOSE ANYTHING. Settling a round and ending a pairing are
# legitimately distinct, a pairing can outlive one round's debt, and inferring
# that a pairing ended is the newest-wins rule `#962` forbids. The refusal stays
# a refusal, with the same polarity and the same `safe=0`; only its WORDS change,
# from a bare "work in flight" to an actionable diagnosis.
#
# IT NAMES THE AWAITING WINDOW'S OWN CHANNEL, WHICH IS THE CORRECTION #1190's
# FILER HAD TO ISSUE AGAINST ITS OWN ISSUE BODY. A skeptic awaits on ITS OWN
# channel, not its target's: measured, `ng skeptic close <target>` wrote
# `skeptic/<target>/DONE` and left the loop running, while `ng skeptic close
# <skeptic>` released it within 8s. A diagnosis derived from the PAIRING would
# send the reader to the wrong window, produce no release, and teach them the
# sentinel mechanism is broken rather than that they addressed the wrong party.
# So the name comes from the live child's OWN argv.
#
# AND THE ARGV IS READ FROM THIS PANE'S PROCESS TREE, NEVER FROM A GLOBAL `ps`.
# A predicate keyed on a string cannot tell the thing from the description of
# the thing: `claude`'s argv IS its prompt, agent prompts quote verbatim the
# commands they are about, and a global match therefore grows a false positive
# with every worker spawned. Descending from `pane_pid` scopes the question to
# this window by construction.
#
# EVERY DOUBT PRINTS NOTHING. An unreadable tree, an absent pane pid, an
# obligation ledger that cannot be asked — each yields an empty clause and the
# caller's own wording stands alone, exactly as `_sk_ev_clause` does. A
# diagnosis that might be wrong is worse than none, because it is the part a
# reader acts on without re-deriving.
# _sk_await_task_id — the task-id a `skeptic-channel.sh await …` argv ACTUALLY
# RESOLVES, parsed the way `cmd_await` itself parses it. Prints it and returns 0;
# returns 1 on any doubt.
#
# THE LAST WORD IS NOT THE TASK-ID, and reading it as one manufactured a
# confident wrong diagnosis (your-org/nexus-code#1190). `await` documents
# `[--timeout S] [--interval S] [--once]` in its own usage line and `ng skeptic`
# is a pure passthrough, so `skeptic-channel.sh await <win> --timeout 900` is a
# legal, working invocation whose last word is `900`. Measured at 989b888,
# same fixture, argv the only variable:
#
#   await v1190sk                  ->  `ng skeptic close v1190sk`   correct
#   await v1190sk --timeout 900    ->  `ng skeptic close 900`       WRONG
#   await v1190sk --once           ->  `ng skeptic close --once`    WRONG
#
# And the mis-derived name DEFEATED THE CLAUSE'S OWN DONE SUPPRESSION: with
# `skeptic/v1190sk/DONE` present — a properly closed pairing, where the clause
# must stay silent — the flagged argv still fired, fabricating a diagnosis on a
# healthy window. `skeptic-channel.sh close 900` then prints a path, exits 0,
# creates the directory and releases NOTHING. That is precisely the wrong-party
# failure #1190's own correction comment was written to prevent: advice that
# "produced no release, and left them believing the sentinel mechanism was
# broken." And this workspace's own BOUND EVERY WAIT doctrine actively pushes
# agents toward writing `--timeout`, so the variant gets MORE likely over time.
#
# MIRRORING THE PARSER, NOT TAKING A POSITION. #1190's own close-criterion says
# "take the first token after `await`" — that is a POSITION, and `cmd_await`'s
# flags are ORDER-FREE, so `await --timeout 900 <win>` (measured legal: it runs
# and resolves `<win>`) would yield `--timeout` and lose a true diagnosis. The
# property is the task-id `await` resolved, so the flags are consumed with their
# arities exactly as `cmd_await` consumes them.
#
# EVERY DOUBT RETURNS 1. An unknown `--flag` has unknown arity, so the parse
# cannot continue; a second positional is something `cmd_await` would have died
# on, so the argv is not one a live await can hold. Both yield silence rather
# than a guess.
# `skeptic-channel.sh await`'s own flag grammar, as DATA — see the block inside
# `_sk_await_task_id`. Space-padded so a `*" $w "*` test matches whole words.
_SK_AWAIT_VALUE_FLAGS=" --timeout --interval "   # consume the FOLLOWING word
_SK_AWAIT_BARE_FLAGS=" --once "                  # consume nothing
_sk_await_task_id() {
    local argv="$1" w seen=0 skip=0 task=""
    local -a words=()
    # `read -a` SPLITS ON IFS WITHOUT GLOBBING. A bare `for w in $argv` would
    # pathname-expand any `*`/`?`/`[` the argv happens to carry, and under a
    # `nullglob` inherited through `BASHOPTS`/`BASH_ENV` an unmatched token
    # would VANISH from the word list instead of staying literal — silently
    # shifting which word lands in the positional slot. The base code read one
    # parameter expansion and had no such exposure; splitting is what
    # introduces it, so it is closed here rather than assumed away.
    read -r -a words <<<"$argv"
    (( ${#words[@]} > 0 )) || return 1
    for w in "${words[@]}"; do
        if (( skip )); then skip=0; continue; fi
        if (( ! seen )); then
            [[ "$w" == "await" ]] && seen=1
            continue
        fi
        # THESE ARE `skeptic-channel.sh await`'s FLAGS, NOT THIS SCRIPT'S, and
        # the distinction is load-bearing rather than pedantic. This script
        # accepts exactly five flags from its caller — `--now`, `--state-dir`,
        # `--fresh-seconds`, `--pane-state`, `--reports-dir` (see `usage`) —
        # and `retire-preflight.sh --timeout 5` exits 2. The names below are
        # recognised while SCRAPING A LIVE CHILD'S ARGV, so they belong to the
        # awaited command's grammar; putting them in this script's usage would
        # advertise flags it REJECTS, which is a worse lie than the one it
        # would be silencing.
        #
        # Held as DATA rather than `case` arms so that ownership is stated in
        # one place. A side effect, recorded so nobody "tidies" it back:
        # `monitor/watcher/test-ng-usage-flag-coverage.sh` treats a
        # `case --flag)` arm as evidence of a script's OWN cli surface, which
        # is a sound proxy everywhere else in this repo and is simply not true
        # here. The property that guard protects (#883: a flag a caller can
        # pass must be discoverable in `--help`) genuinely does not apply to a
        # third party's argv, and this form says so instead of asserting it.
        if   [[ "$_SK_AWAIT_VALUE_FLAGS" == *" $w "* ]]; then skip=1
        elif [[ "$_SK_AWAIT_BARE_FLAGS"  == *" $w "* ]]; then :
        elif [[ "$w" == -* ]]; then return 1
        else
            [[ -n "$task" ]] && return 1
            task="$w"
        fi
    done
    (( seen ))      || return 1
    (( skip == 0 )) || return 1   # a flag whose value never arrived
    [[ -n "$task" ]] || return 1
    [[ "$task" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    [[ "$task" == "await" ]] && return 1
    # ALL-DIGITS IS A DOUBT, not a name. `skeptic-channel.sh close 900` exits 0
    # having created a directory and released nothing, so a numeric name is the
    # one spelling whose wrong advice is SILENT. It is also a name the window-key
    # vocabulary already refuses as ambiguous with an index, so there is nowhere
    # safe to send the reader. Cost of the refusal is silence, which is this
    # function's stated contract.
    [[ "$task" =~ ^[0-9]+$ ]] && return 1
    printf '%s' "$task"
}

_sk_await_child_window() {
    # The window name a live `skeptic-channel.sh await <name>` child in THIS
    # pane's tree is waiting on. Prints it and returns 0; returns 1 on any doubt.
    local ppid="" depth queue next pid args name
    command -v pgrep >/dev/null 2>&1 || return 1
    # `RETIRE_PREFLIGHT_PANE_PID` names the tree root directly, so a test can
    # plant a real child process without a tmux server. It is safe as a test
    # seam for the same reason the whole clause is safe: this function feeds
    # only the WORDS of a refusal and authorises nothing, so the worst a wrong
    # root can do is print a diagnosis about the wrong tree — it can never turn
    # a `safe=0` into a `safe=1`. `pane-state.sh --pane-pid` is the precedent.
    if [[ -n "${RETIRE_PREFLIGHT_PANE_PID:-}" ]]; then
        ppid="$RETIRE_PREFLIGHT_PANE_PID"
    else
        command -v tmux >/dev/null 2>&1 || return 1
        [[ -n "$pane_target" ]] || return 1
        ppid=$(tmux display-message -p -t "$pane_target" '#{pane_pid}' 2>/dev/null) || return 1
    fi
    [[ "$ppid" =~ ^[0-9]+$ ]] || return 1
    queue="$ppid"
    for depth in 0 1 2 3 4 5; do
        [[ -n "$queue" ]] || return 1
        for pid in $queue; do
            args=$(ps -o args= -p "$pid" 2>/dev/null) || continue
            case "$args" in
                *skeptic-channel.sh*await*)
                    # The task-id `await` RESOLVED — parsed, not positional and
                    # not the last word (your-org/nexus-code#1190).
                    name=$(_sk_await_task_id "$args") || return 1
                    printf '%s' "$name"; return 0 ;;
            esac
        done
        next=""
        for pid in $queue; do next+=" $(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')"; done
        queue=$(printf '%s' "$next" | tr -s ' ')
    done
    return 1
}

_sk_await_clause() {
    local name obl_bin
    name=$(_sk_await_child_window) || return 0
    # The sentinel that would release it. Absent means EITHER never written OR
    # written and later pruned, and those are different facts — but not
    # different ACTIONS: writing it releases the loop either way, so the
    # ambiguity does not reach the advice.
    [[ -e "$STATE_DIR/skeptic/$name/DONE" ]] && return 0
    obl_bin="$self_dir/obligations.sh"
    [[ -x "$obl_bin" ]] || return 0
    # rc 0 = nothing this window owes blocks it. A NON-zero rc means it still
    # owes somebody, in which case the await loop is doing its job and there is
    # nothing to diagnose.
    NEXUS_STATE_DIR="$STATE_DIR" "$obl_bin" gate "$win_name" >/dev/null 2>&1 || return 0
    # SAY WHAT WAS MEASURED. `gate` answers "nothing this window OWES blocks
    # retiring it" — which is what the diagnosis needs and is NOT the same claim
    # as "every obligation is settled": a settled edge, a voided one and an edge
    # that never existed all clear the gate, and the first draft of this clause
    # printed `SETTLED` for an edge measured `void-creditor-absent`. A refusal
    # that asserts a property it did not test is the defect this whole cluster
    # is made of, arriving inside its own remedy.
    printf ' | %s is in `skeptic-channel.sh await %s`, nothing it owes is outstanding, and there is no `skeptic/%s/DONE` — the work in flight IS an await loop against a round that already closed. `ng skeptic close %s` releases it. Note the NAME: a reviewer awaits on its OWN channel, not its target'"'"'s, so closing the target does nothing (your-org/nexus-code#1190)' \
        "$win_name" "$name" "$name" "$name"
}

# ── HOW LONG HAS THIS WINDOW BEEN HOLDING THE SLOT? (nexus-code#929) ─────
#
# #929 observes that retirement authorization is keyed on pane STATE alone —
# no duration, no progress, no liveness input anywhere in the decision — so a
# background child that can never terminate is indistinguishable from real
# work and the board pays a slot indefinitely (measured: 5h20m, 191 CPU-s).
# It deliberately ships no fix, on the correct ground that the converse error
# is far more expensive: a gate that retires a window with genuine background
# work destroys a live worker and its whole context.
#
# So this reports a FACT and authorises nothing. It appends words to a refusal
# that has already been decided, exactly as `_sk_await_clause` above does, and
# for the same reason that is safe: it feeds only the WORDS of a `safe=0`, so
# the worst a wrong reading can do is print a duration about the wrong tree —
# it can never turn a `safe=0` into a `safe=1`.
#
# WHY ONLY THE DURATION, AND NOT #929's "owning session has exited". That half
# of the proposed signal is not merely expensive, it is very nearly VACUOUS in
# the state it was wanted for, which is a correction to the issue rather than a
# shortcut around it. `working-background` requires `bg_reliable=1`, and
# `bg_reliable` requires A LIVE `claude` NODE FOUND in this pane's process tree
# (pane-state.sh, the reliability contract). If the owning claude has exited,
# the state is `absent` — which is already in `_BK_KILL_OK_STATES` and is the
# sole member of `_BK_DEAD_STATES`. So on a `safe=0 pane=working-background`
# line an honest owner-exited field would read `alive` essentially always:
# "held N hours" and "owner exited" describe the post-mortem orphan, and do not
# co-occur in the surface where the signal was asked for.
#
# EVERY DOUBT PRINTS NOTHING, per the rule stated for `_sk_await_clause`: a
# missing pane line, a missing or non-numeric `bg_oldest_start`, a zero (which
# pane-state uses for "not measured", not for the epoch), or a start in the
# future all yield an empty clause and the caller's own wording stands alone.
_bg_held_clause() {
    local line start age
    # `${pane_line:-}` and not `$pane_line`: `set -u` is on and the
    # `--pane-state` path never assigns it.
    line="${pane_line:-}"
    [[ -n "$line" ]] || return 0
    start=$(printf '%s' "$line" | sed -n 's/.*bg_oldest_start=\([0-9]*\).*/\1/p')
    [[ "$start" =~ ^[0-9]+$ ]] || return 0
    (( start > 0 )) || return 0
    age=$(( now - start ))
    (( age > 0 )) || return 0
    # Below an hour this says nothing an operator does not already assume from
    # `working-background`; the point of the clause is the long tail.
    (( age >= 3600 )) || return 0
    printf ' — the oldest background child has been alive %dh%02dm; if that is a wait that can never be satisfied, the owning agent is the only authorised reaper (see your-org/nexus-code#929)' \
        $(( age / 3600 )) $(( (age % 3600) / 60 ))
}

if ! bk_pane_kill_authorized "$pane_state"; then
    case "$pane_state" in
        user-typing)
            emit 0 "$pane_state" "operator is typing in the input box right now" ;;
        busy|working-background|working-self-paced)
            emit 0 "$pane_state" "agent work in flight (pane=$pane_state) — retire decision was made against a stale idle snapshot$(_sk_await_clause)$(_bg_held_clause)" ;;
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
sk_pending="$STATE_DIR/skeptic/pending/$(wk_encode "$win_name")"
# your-org/nexus-code#941 — a marker written under the OLD lossy key, before
# this window's key became injective, must not be silently missed. Missing it
# retires a window whose required skeptic never returned, which is the exact
# failure check 1b exists to prevent, arriving through the key instead of
# through the gate.
#
# It BLOCKS rather than being adopted. A legacy key is by definition the one
# that cannot be attributed to a single window, so "this marker might be ours"
# is doubt, and doubt refuses an irreversible act. The refusal names the
# migration, because a gate with no exit trains its own bypass.
#
# Reached only when `wk_needs_encoding` is true — false for every name this
# nexus has ever recorded (1152/1152), so the common path is untouched.
if [[ ! -f "$sk_pending" ]] && wk_needs_encoding "$win_name"; then
    _legacy_pending="$STATE_DIR/skeptic/pending/$(wk_legacy_key "$win_name")"
    if [[ -f "$_legacy_pending" ]]; then
        printf 'retire-preflight: %q has NO marker under its injective key, but a marker\n' "$win_name" >&2
        printf '  exists under the LEGACY key %q. That file predates your-org/nexus-code#941\n' \
            "$(wk_legacy_key "$win_name")" >&2
        printf '  and may belong to this window or to another that collided with it — which is\n' >&2
        printf '  what the legacy key could not distinguish. Refusing rather than guessing.\n' >&2
        printf '  Resolve by attributing it: if it is this window'"'"'s, rename it to\n' >&2
        printf '      %s\n' "$sk_pending" >&2
        printf '  if it is not, remove it or attribute it to its true owner.\n' >&2
        emit 0 "$pane_state" "a LEGACY-keyed skeptic-pending marker exists for this window ($_legacy_pending) and cannot be attributed to a single window — refusing kill (your-org/nexus-code#941)"
        exit 1
    fi
fi
# Resolve `ng` ONCE, BEFORE check 1b — both the 1b audit record and check 1be
# need it. It was first written below check 1be, which left the 1b record
# referencing an EMPTY path: the log would simply never be written, silently,
# and the absence would look exactly like a run where the gate was not reached.
# That is the defect this batch is about, one level up in the fix for it.
_sk_ng_bin=""
if [[ -x "$self_dir/ng" ]]; then
    _sk_ng_bin="$self_dir/ng"
elif [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/ng" ]]; then
    _sk_ng_bin="$NEXUS_ROOT/monitor/ng"
fi


# ---- VERDICT EVIDENCE, read ONCE and used by three refusals ---------------
# your-org/nexus-code#1156.
#
# Every gate below can refuse a window because a skeptic verdict is missing.
# None of them could say whether it is missing because NOBODY REVIEWED THE
# WORK or because a DELIVERED verdict could not be matched to what was armed.
# Those need opposite responses — get a review, versus repair the record — and
# on one afternoon four windows hit the second case by four different
# mechanisms and every one printed the first case's wording. Measured cost on
# that board: three duplicate `spawn-skeptic` requests (one for a PR that had
# already merged) and two orchestrator pushes at reviewers that had already
# discharged, one of which refused and filed a correction instead of complying.
#
# THIS CHANGES NO VERDICT. Every `emit`/`exit` polarity below is untouched; it
# changes only the words. That is the safety property, and it is why a
# misclassification here cannot retire a window on a pass that never happened:
# a refusal stays a refusal whatever this says.
#
# DOUBT PRINTS NOTHING. `ng skeptic-evidence` reports `?` for anything it
# cannot classify, and `?` is folded to the empty class here, which selects the
# wording the gate used before this existed — the conservative one.
_SK_EV_LINE=""
_SK_EV_CLASS=""
_SK_EV_SUPERSEDED=""
_SK_EV_STANDING=""
_SK_EV_ATTRIBUTED=""
_SK_EV_ISSUE=""
_SK_EV_UNMATCHED_WHY=""
_SK_EV_LOADED=0

# _sk_ev_load — LAZY, and memoised. Measured on this host, 5-run means, against
# base `f40a538` with `self_dir` resolving `ng` correctly (extracting the base
# script to /tmp makes it find no `ng` at all and skip every subprocess, which
# reads as 14 ms and is not a comparison):
#
#   marker + NO ledger : base 590 ms -> head 603 ms   (+13,  probe skipped)
#   marker + ledger    : base 585 ms -> head 876 ms   (+291, probe runs)
#
# Two mitigations, and the third was rejected. (1) The ledger FILE's absence is
# checked first — that is not an assumption, it is the same observation
# `skeptic-evidence` reports as `ledger=absent evidence=none`, made without
# paying for an interpreter start, and it covers the whole pre-#984 population.
# (2) This is lazy, so a run that never reaches an emit needing the class — the
# ordinary GO — pays nothing even when a ledger exists. (3) NOT inlining the
# classifier here: a second implementation of it is exactly the drift this
# change exists to prevent, and 291 ms on a gate already costing 585 ms, once
# per retirement decision, is not worth buying with two copies of a rule.
_sk_ev_load() {
    (( _SK_EV_LOADED )) && return 0
    _SK_EV_LOADED=1
    local ledger="$STATE_DIR/skeptic/pending/.$(wk_encode "$win_name").ledger"
    # AN ABSENT LEDGER IS `none`, AND MUST SAY SO. The first draft of this skip
    # just returned, leaving the class EMPTY — which selects the same wording as
    # the DOUBT path, making "nobody ever armed this window" indistinguishable
    # from "could not look". That is the exact defect this change exists to fix,
    # reintroduced by its own optimisation, and `test-retire-preflight` case 9b
    # is what caught it.
    #
    # The claim is only made when the absence was POSITIVELY OBSERVED: the
    # pending directory has to exist and be readable, or `-e` returning false is
    # a failure to look rather than a finding, and doubt must stay doubt.
    if [[ ! -e "$ledger" ]]; then
        if [[ -d "$STATE_DIR/skeptic/pending" && -r "$STATE_DIR/skeptic/pending" ]]; then
            _SK_EV_CLASS="none"
            _SK_EV_LINE="window=$win_name ledger=absent evidence=none"
        fi
        return 0
    fi
    [[ -n "${_sk_ng_bin:-}" ]] || return 0
    _SK_EV_LINE=$(timeout "${RETIRE_PREFLIGHT_DISPOSITION_TIMEOUT:-60}" \
        "$_sk_ng_bin" skeptic-evidence "$win_name" --state-dir "$STATE_DIR" 2>/dev/null) \
        || _SK_EV_LINE=""
    [[ -n "$_SK_EV_LINE" ]] || return 0
    _SK_EV_CLASS=$(sed -n '1s/.*[[:space:]]evidence=\([^[:space:]][^[:space:]]*\).*/\1/p' \
        <<<"$_SK_EV_LINE")
    [[ "$_SK_EV_CLASS" == "?" ]] && _SK_EV_CLASS=""
    _sk_ev_field() {
        sed -n "1s/.*[[:space:]]$1=\([^[:space:]][^[:space:]]*\).*/\1/p" <<<"$_SK_EV_LINE"
    }
    _SK_EV_SUPERSEDED=$(_sk_ev_field superseded)
    _SK_EV_STALE=$(_sk_ev_field standing_stale)
    _SK_EV_STALE_WHY=$(_sk_ev_field standing_stale_why)
    _SK_EV_STANDING=$(_sk_ev_field standing_verdict)
    _SK_EV_ATTRIBUTED=$(_sk_ev_field attributed_verdict)
    _SK_EV_ISSUE=$(_sk_ev_field standing_issue)
    _SK_EV_UNMATCHED_WHY=$(_sk_ev_field unmatched_why)
    local _sk_ev_why; _sk_ev_why=$(_sk_ev_field superseded_why)
    # `superseded=?` HAS TWO PRODUCERS and only one of them is a finding.
    #
    #   sup_state 2  the rows were parsed and their ISSUE FIELD is absent, so
    #                the relation genuinely cannot be established. A finding.
    #   the `ev == "?"` doubt-fold  the ledger could not be parsed AT ALL, and
    #                every count on the line becomes `?` with it.
    #
    # Folding only the CLASS let the second reach the `?` clause, which then
    # said "A LATER verdict row exists after the attributed one, but the rows
    # carry no issue field" — asserting a later verdict row for a ledger where
    # nothing was read. A claim where nothing was established, inside the change
    # whose whole thesis is that a refusal's words must be true.
    #
    # So this keys on the POSITIVE REASON rather than on the absence of a class:
    # `superseded_why` is `-` for the doubt-fold and names the relation for a
    # real finding. Keying on presence-of-a-reason is what makes the two
    # producers distinguishable at all.
    case "$_SK_EV_SUPERSEDED" in
        1) ;;
        '?') [[ "$_sk_ev_why" == "issue-field-absent-cannot-establish" ]] \
                 || _SK_EV_SUPERSEDED="" ;;
        *) _SK_EV_SUPERSEDED="" ;;
    esac
    return 0
}

# _sk_ev_clause — the one-sentence tag appended to an emit reason. Empty when
# no claim can be made, so the caller's own wording stands alone.
_sk_ev_clause() {
    _sk_ev_load
    case "${_SK_EV_CLASS:-}" in
        none)
            printf ' | evidence=none: the ledger records NO verdict and NO resolution for this window, so the verdict is GENUINELY ABSENT — a review is what is missing' ;;
        unmatched-subject)
            # THE CAUSE IS NOT ASSERTED ANY MORE (your-org/nexus-code#1252).
            # This clause used to state one — "the report was amended after
            # arming" — and since `#1156` that is the one cause that does NOT
            # land here: an amended report whose reviewer named the PATH is
            # `asserted-path`, which MATCHES. Measured on the live pending dir
            # 2026-09-02, the 58 rows in this class split 5 / 53 across two
            # different causes with opposite remedies, and neither is the one
            # this sentence named. `unmatched_why` carries the split.
            printf ' | evidence=unmatched-subject: a verdict IS ON THE LEDGER but names an artefact that is not on the outstanding set (`asserted-not-armed`). The pass was DELIVERED; the RECORD cannot match it. Do NOT re-spawn a skeptic'
            case "${_SK_EV_UNMATCHED_WHY:-}" in
                ''|-|'?') printf ' — WHY was not recorded (a row written before your-org/nexus-code#1252); read the rows' ;;
                *)        printf ' — why=%s' "$_SK_EV_UNMATCHED_WHY" ;;
            esac ;;
        ambiguous-arms)
            printf ' | evidence=ambiguous-arms: a verdict IS ON THE LEDGER but several arms were open against one report path and one discharge cannot close them. The pass was DELIVERED; the RECORD cannot match it. Do NOT re-spawn a skeptic' ;;
        superseded-verdict)
            printf ' | evidence=superseded-verdict: a LATER verdict exists AFTER the cleanly-matched one, so the row that ATTRIBUTES is NOT the standing verdict. Two discharges for one arm is a LEGITIMATE state — a superseding verdict is not a duplicate. Do NOT re-spawn a skeptic' ;;
        rearm-after-close)
            printf ' | evidence=rearm-after-close: every outstanding arm was armed AFTER the last discharge/resolution — a wrap-up RE-ARMED a chain that had already closed. The pass was DELIVERED. Do NOT re-spawn a skeptic' ;;
        verdict-without-arm)
            printf ' | evidence=verdict-without-arm: a verdict IS ON THE LEDGER and NO arm was ever recorded for this key (`no-arm-on-record`) — the armed state was established by a writer that named no subject. The pass was DELIVERED and the reviewer has nothing to re-do; the repair is to the ARM. Do NOT re-spawn a skeptic (your-org/nexus-code#1191, #1207)' ;;
        no-open-arm)
            printf ' | evidence=no-open-arm: a verdict IS ON THE LEDGER and arrived with NOTHING OUTSTANDING — the ordinary shape of the TERMINAL verdict in a chain whose last round closed cleanly. The pass was DELIVERED and it matched nothing because there was nothing left to match. Do NOT re-spawn a skeptic (your-org/nexus-code#1191)' ;;
        unmatched-other)
            printf ' | evidence=unmatched-other: a verdict IS ON THE LEDGER, with a detail this gate does not recognise — whether it matches the outstanding arm is UNESTABLISHED, which is not the same as absent' ;;
        prior-verdict-other-artefact)
            printf ' | evidence=prior-verdict-other-artefact: verdict(s) are on the ledger but each names a DIFFERENT artefact than the outstanding arm — this arm genuinely has no verdict' ;;
        attributed)
            printf ' | evidence=attributed: the ledger records an ATTRIBUTED verdict and nothing outstanding — the pass COMPLETED and the bookkeeping simply did not clear' ;;
        discharge-without-verdict)
            printf ' | evidence=discharge-without-verdict: a settle row exists naming NO verdict — what was delivered cannot be established' ;;
        resolved-only)
            printf ' | evidence=resolved-only: an operator RESOLUTION is on the ledger and no verdict' ;;
        *) : ;;
    esac
    # Appended REGARDLESS of which class won precedence — see the comment where
    # these are read. Naming both verdicts is the point: the divergence between
    # them is exactly what a reader consulting the attributed row would get
    # wrong.
    case "${_SK_EV_SUPERSEDED:-}" in
        1)
            # Reached ONLY for same-issue, DIFFERING verdicts. "Take the later
            # one" is an instruction that discards a verdict, so it may not be
            # printed on a pair this gate has not established to be about one
            # task — that would be window-keyed newest-wins arriving as prose
            # (#962, #1156).
            printf ' | SUPERSEDED (same issue `%s`): the STANDING verdict is `%s` while the cleanly-attributed row says `%s` — a reader taking the attributed row gets the SUPERSEDED answer. Take the LATER one (your-org/nexus-code#1156)' \
                "${_SK_EV_ISSUE:-?}" "${_SK_EV_STANDING:-?}" "${_SK_EV_ATTRIBUTED:-?}" ;;
        '?')
            printf ' | A LATER verdict row exists after the attributed one, but a ledger row carries NO issue field, so whether it SUPERSEDES the earlier one or belongs to a DIFFERENT TASK CANNOT BE ESTABLISHED. Read both rows before acting on either' ;;
        *) : ;;
    esac
    # ── #1199: the standing verdict predates the current artefact ─────────
    #
    # A re-pinned round can complete, be reported and be acted on while writing
    # nothing here, so the ledger reports itself fully consistent
    # (`superseded=0 unmatched=0`) with its standing verdict pinned to the
    # PRE-correction artefact. Both parties then read the state correctly and
    # reach opposite conclusions: the worker sees a verdict on bytes that
    # predate its own fixes, the reviewer knows it cleared the work, and nothing
    # prompts either to read the report and the ledger together.
    #
    # This says only what the ledger records — a later arm, different sha — and
    # deliberately does NOT guess which of the two situations produced it. They
    # need opposite actions and the ledger cannot tell them apart:
    # a review of the corrected artefact that went unrecorded, or no review of
    # it at all. Naming the ambiguity IS the remedy; resolving it would be a
    # guess printed as a fact.
    case "${_SK_EV_STALE:-}" in
        1)
            printf ' | STANDING VERDICT PREDATES THE CURRENT ARTEFACT: the report was re-armed with a DIFFERENT sha after the standing verdict was recorded, so that verdict is about superseded bytes. Read the REPORT alongside the ledger — a re-pinned round that completed writes nothing here, and "no newer verdict" and "the reviewer never ran" look identical from this side (your-org/nexus-code#1199)' ;;
        *) : ;;
    esac
}

# _sk_ev_explain — the stderr half: the rows themselves, then the remedy that
# fits THIS class. The remedy matters as much as the diagnosis: the only two
# moves the old refusal offered were `clear the marker` — which voids a LIVE
# obligation derivedly (#961, and #1153 is the same shape in the orphan
# detector) — and `push the skeptic`, which manufactures work against somebody
# who already finished. On a delivered-but-unmatched verdict neither is right.
_sk_ev_explain() {
    _sk_ev_load
    [[ -n "${_SK_EV_CLASS:-}" ]] || return 0
    # ── THE ARM WAS DEAD, NOT ALWAYS-LIVE — AND THE FIRST WRITE-UP OF THIS
    #    CLAIMED THE OPPOSITE (your-org/nexus-code#1207 skeptic F3) ──────────
    #
    # This was a five-class allowlist with `*) [[ -n "$_SK_EV_SUPERSEDED" ]] ||
    # return 0`. The correction matters more than the fix, so it is recorded
    # first: an earlier revision of this comment asserted, with quoted output,
    # that the escape "fired on EVERY class including `none`" because
    # `superseded=` is always printed. THAT IS FALSE AND DOES NOT REPRODUCE.
    # `_sk_ev_load` NORMALISES `_SK_EV_SUPERSEDED` to the empty string for every
    # value except `1` and an `issue-field-absent-cannot-establish` `?` — fifty
    # lines above, in the same function, one assignment site. So on
    # `evidence=none` the escape correctly returned 0 and said nothing.
    #
    # The false claim came from a probe that HAND-SET `_SK_EV_SUPERSEDED="0"`, a
    # state that normalisation never produces, whose output was then reported as
    # a live measurement. Asserting a proxy while the prose describes the
    # property is the defect class this whole bundle is about, and it was
    # committed in the write-up OF that bundle.
    #
    # THE REAL DEFECT IS THE OPPOSITE POLARITY, and it is measured. The arm was
    # effectively DEAD, so classes absent from the five-name allowlist were
    # SILENT — a false NEGATIVE, not a false positive. Driving `_sk_ev_explain`
    # against planted ledgers, stderr bytes, base `7151a13` vs this tree:
    #
    #     class                          base    head
    #     no-open-arm                       0     917
    #     unmatched-other                   0     832
    #     prior-verdict-other-artefact      0     835
    #     evidence=none (armed-only)        0       0   <- unchanged, correctly
    #
    # A control class already in the allowlist prints on both trees, so the
    # zeroes are findings rather than a broken probe. `no-open-arm` is the sharp
    # one: it was added to the classifier and to `_skeptic_evidence_sides` by the
    # very change that introduced it, and never reached this arm — so a verdict
    # of that class was delivered, recorded, and then explained to nobody.
    #
    # A permissive default behind an allowlist is the shape this repo bans
    # (`#1119`, `#1121`). Now an allowlist with a default-DENY over the full
    # DELIVERED group of `ng`'s `_skeptic_evidence_sides`, kept in step by
    # `monitor/watcher/test-skeptic-evidence-class-agreement.sh` rather than by
    # hand — three of the four consumers had drifted when it was written.
    #
    # The `superseded` escape below is kept and is DEFENSIVE, not live: after
    # normalisation only `1` and a qualifying `?` survive, and both require
    # `matchedline > 0`, i.e. a verdict, whose class is in the allowlist already.
    # It is retained as a backstop for a future class that is not, and this
    # comment says plainly that it is currently unreachable rather than implying
    # it carries traffic.
    case "$_SK_EV_CLASS" in
        attributed|unmatched-subject|no-open-arm|verdict-without-arm|unmatched-other|ambiguous-arms|rearm-after-close|superseded-verdict|prior-verdict-other-artefact) ;;
        *) case "${_SK_EV_SUPERSEDED:-}" in 1|'?') ;; *) return 0 ;; esac ;;
    esac
    printf 'retire-preflight: A VERDICT IS ON THE RECORD FOR THIS WINDOW (evidence=%s):\n' \
        "$_SK_EV_CLASS" >&2
    printf '%s\n' "$_SK_EV_LINE" | sed -n '2,$p' | sed 's/^/    /' >&2
    printf '  So this is a BOOKKEEPING failure, not an unmet requirement. Do NOT file a\n' >&2
    printf '  spawn-skeptic request and do NOT push the reviewer: it already discharged.\n' >&2
    printf '  Verify the verdict yourself (the rows above name its author and time), then\n' >&2
    printf '  say on the record what actually happened:\n' >&2
    printf '      monitor/ng skeptic resolve %q --reason "<the verdict, where it is, why the arm did not match>"\n' "$win_name" >&2
    printf '  If the pairing is still open — the reviewer is live and expects more rounds —\n' >&2
    printf '  end it deliberately instead, which releases the target'"'"'s await loop too:\n' >&2
    printf '      monitor/ng skeptic close %q\n' "$win_name" >&2
    if [[ "${_SK_EV_SUPERSEDED:-}" == "1" ]]; then
        printf '  AND NOTE THE ORDERING. Two discharges for one arm is a LEGITIMATE state, not a\n' >&2
        printf '  duplicate: a reviewer whose target landed a fix MID-REVIEW must re-derive its\n' >&2
        printf '  findings against the new head and amend its report to publish that, and the\n' >&2
        printf '  amendment moves the content hash off the arm. So the ledger records the WEAKER\n' >&2
        printf '  first verdict as matched (`%s`) and the stronger later one as unmatched (`%s`).\n' \
            "${_SK_EV_ATTRIBUTED:-?}" "${_SK_EV_STANDING:-?}" >&2
        printf '  THE STANDING VERDICT IS THE LATER ONE. Whatever you record must say so.\n' >&2
    fi
}
# ---- check 1b AUDIT RECORD (your-org/nexus-code#975, #962 direction 2) ----
#
# #975: three windows retired owing a RE-ARMED required verdict that was never
# spawned, on work that shipped. The mechanism was never established, and it is
# unknowable BY CONSTRUCTION — which is the finding, not a gap in the
# investigation.
#
# Measured: check 1b was live in the FIRST-PARENT MAINLINE at all three
# retirement dates (`6d72d0e` 2026-07-29 and `4ed5aa1` 2026-08-09 both carry
# it; it was added by `597a111` on 2026-06-15, six to eight weeks earlier), so
# "the gate did not exist" is FALSE. The orphan fall-through cannot explain it
# either: `_idle_skeptic_orphaned` needs the marker fresh within 600s AND the
# request older than 600s, and for these markers `mtime == request epoch` TO
# THE SECOND, which makes the two conditions mutually exclusive. So the gate
# WOULD have refused.
#
# And yet: check 1b emits its refusal to STDOUT and persists nothing, so "the
# preflight was never invoked" and "it refused and the kill happened anyway"
# leave byte-identical traces — namely none. #964 gave check 1c an audit
# record; at HEAD, 1b had none, and all 113 `retire-preflight`-authored rows in
# the operator's log are `skeptic-disposition-gate`.
#
# This does not decide anything and must not: it RECORDS. Same fail-open
# posture as #964's — a broken log must never change a kill verdict — and it
# records on the PERMIT path too, because a gate that only logs its refusals
# cannot answer "how often did this pass?", which is the question #975 needed.
if [[ -n "${_sk_ng_bin:-}" ]]; then
    ( NEXUS_STATE_DIR="$STATE_DIR" timeout "${RETIRE_PREFLIGHT_DISPOSITION_TIMEOUT:-60}" \
        "$_sk_ng_bin" log-action retire-preflight \
        --event skeptic-marker-gate \
        --extra "window=$win_name" \
        --extra "marker=$( [[ -f "$sk_pending" ]] && printf 'present' || printf 'absent' )" \
        --extra "marker-path=$sk_pending" \
        --extra "pane-state=$pane_state" \
        >/dev/null 2>&1 ) || true
fi
if [[ -f "$sk_pending" ]]; then
    _sk_now=$(date +%s)
    if (( have_probe )) && declare -F _idle_skeptic_orphaned >/dev/null 2>&1 \
       && _idle_skeptic_orphaned "$win_name" "$_sk_now"; then
        # Orphaned marker: NOT live validation. Note it (stderr, so the single
        # stdout verdict stays authoritative) and fall through — the marker no
        # longer blocks retirement. Checks 2/3 below still guard operator
        # engagement, so a genuinely-in-use window is still refused.
        # THIS IS THE PATH THAT ALLOWS THE KILL, which is exactly why the note
        # must say what the ledger holds. `evidence=none` here means the
        # required validation is about to be STRANDED; `evidence=attributed`
        # means the pass completed and the marker merely never cleared. The
        # fall-through itself is unchanged — #1153's permissive default arm is
        # a VERDICT change and is deliberately not made here — but an operator
        # watching a kill proceed deserves to know which of the two it is.
        printf 'retire-preflight: skeptic-pending marker for %q is ORPHANED (no live skeptic past grace) — not blocking retirement; ask `ng skeptic-evidence` what the ledger holds before relying on that\n' \
            "$win_name" >&2
        _sk_ev_load
        if [[ -n "${_SK_EV_CLASS:-}" ]]; then
            printf '  ledger evidence: %s — run `monitor/ng skeptic-evidence %q` for the rows.\n' \
                "$_SK_EV_CLASS" "$win_name" >&2
            [[ "$_SK_EV_CLASS" == "none" ]] && printf '  THAT IS `none`: no verdict and no resolution are on record, so this kill strands the required validation.\n' >&2
        else
            printf '  ledger evidence: could not be established — run `monitor/ng skeptic-evidence %q` before relying on this.\n' \
                "$win_name" >&2
        fi
    else
        # Name the SANCTIONED release path in the refusal (your-org/nexus-code#577).
        # When a verdict exists but the marker did not clear — the skeptic ran
        # against a different state dir, or the worker re-armed the gate after the
        # verdict returned — this refusal is permanent, and the operator's only
        # visible move was `rm` on the very marker that exists to prevent
        # hand-clearing. A guard that trains its own bypass is worse than no
        # guard, so the message points at the audited verb instead.
        _sk_ev_explain
        printf 'retire-preflight: if a verdict DOES exist and this marker is stale, release it with an audit trail:\n' >&2
        printf '    monitor/ng skeptic resolve %q --reason "<where the verdict is>"\n' "$win_name" >&2
        printf '  (orchestrator-only; writes a rationale beside the marker and logs the event — do NOT rm it)\n' >&2
        # The claim "has not returned a verdict" was UNCONDITIONAL here, and it is
        # the claim that was FALSE in all four #1156 windows: the marker is a bit
        # about the MARKER, never about the ledger. It now says which it is.
        # THE REMEDY MUST SURVIVE THE DOUBT PATH. The base reason named
        # `ng skeptic resolve`; the first draft replaced it with a clause that
        # is EMPTY whenever the class cannot be established, so the `?` case
        # named no way out at all — a gate with no exit, which trains its own
        # bypass, and a direct contradiction of the stated design that doubt
        # "selects the wording the gate used before this existed".
        emit 0 "$pane_state" "required skeptic marker is LIVE — refusing kill; if a verdict exists, use \`ng skeptic resolve <window> --reason …\`$(_sk_ev_clause)"
        exit 1
    fi
fi

# ---- check 1be: OUTSTANDING OBLIGATIONS, BY TASK -------------------------
# your-org/nexus-code#961, #963, #975.
#
# Check 1b above asks a WINDOW-KEYED BIT: does `skeptic/pending/<key>` exist.
# The obligation it stands for is per-TASK. One window took 12 verdicts across
# 7 issues against that one flag, so its presence proves nothing and its absence
# proves nothing — and BOTH misreadings happened, six hours apart, on the same
# file. The absence direction is the dangerous one and it is silent: any one
# verdict `rm`s the marker, including for the six other tasks nobody reviewed.
#
# So 1b cannot be the whole gate, and it cannot be repaired by a better bit.
# This check asks the ledger the question the bit cannot express — WHICH
# artefacts has this window armed that nobody has discharged — and refuses
# naming them.
#
# ── DIRECTION, AND WHY THIS CANNOT WEDGE A BOARD ──────────────────────────
#
# It is STRICTLY ADDITIVE. It fires only when a ledger POSITIVELY NAMES
# artefacts with no attributed discharge and no recorded resolution. It has no
# permitting arm at all: there is no input on which this block turns a refusal
# from 1b/1c/1d into a go. A window with no ledger (every pre-#984 window, and
# the whole existing state dir) reads `outstanding=0` and is unaffected, which
# is the migration story — nothing to convert, and the old population keeps its
# old behaviour exactly.
#
# Doubt refuses, as everywhere on this path: no `ng`, a timeout, or output this
# gate cannot parse all land on the refusal arm. `ng skeptic-obligations` exits
# 1 when something is outstanding and 0 when nothing is, so an rc this block
# does not recognise is never read as clearance.
#
# ── AND IT LEAVES A RECORD, WHICH IS THE HALF #975 ACTUALLY NEEDS ─────────
#
# #975's three windows retired owing a re-armed require. The mechanism was
# never established, and it is unknowable BY CONSTRUCTION: check 1b was live in
# the mainline at all three retirement dates and WOULD have refused, but it
# emits to stdout and persists nothing, so "the preflight was never invoked"
# and "it refused and the kill happened anyway" leave byte-identical traces —
# namely none. #964 gave check 1c an audit record; 1b still has none at HEAD.
# This block records its own verdict either way, so the class becomes countable
# even on the runs where it permits.
_sk_owed_rc=0
_sk_owed_out=""
if [[ -n "$_sk_ng_bin" ]]; then
    _sk_owed_out=$(timeout "${RETIRE_PREFLIGHT_DISPOSITION_TIMEOUT:-60}" \
        "$_sk_ng_bin" skeptic-obligations "$win_name" --state-dir "$STATE_DIR" 2>/dev/null)
    _sk_owed_rc=$?
    ( NEXUS_STATE_DIR="$STATE_DIR" timeout "${RETIRE_PREFLIGHT_DISPOSITION_TIMEOUT:-60}" \
        "$_sk_ng_bin" log-action retire-preflight \
        --event skeptic-obligation-gate \
        --extra "window=$win_name" \
        --extra "probe-rc=$_sk_owed_rc" \
        --extra "outstanding=$(sed -n 's/.*outstanding=\([0-9]*\).*/\1/p' <<<"$_sk_owed_out" | head -1)" \
        --extra "decision=$( (( _sk_owed_rc == 0 )) && printf 'pass' || printf 'refuse' )" \
        --extra "pane-state=$pane_state" \
        >/dev/null 2>&1 ) || true
fi
if [[ -n "$_sk_ng_bin" ]] && (( _sk_owed_rc != 0 )); then
    if (( _sk_owed_rc == 124 )); then
        emit 0 "$pane_state" "the per-task skeptic-obligation probe TIMED OUT — 'could not look' is not 'nothing to find', refusing kill (your-org/nexus-code#961)"
        exit 1
    fi
    # rc 3 is REFUSED-CANNOT-DETERMINE, not "owes N". Saying "owes 1" here
    # would assert a count the probe explicitly declined to give — the same
    # move as reporting a zero it could not vouch for, in the other direction.
    if (( _sk_owed_rc == 3 )); then
        printf 'retire-preflight: %q has a skeptic ledger that EXISTS but could not be read or parsed:\n' "$win_name" >&2
        printf '%s\n' "$_sk_owed_out" | sed 's/^/    /' >&2
        printf '  So what this window owes is UNKNOWN, which is not the same as nothing.\n' >&2
        emit 0 "$pane_state" "the per-task skeptic-obligation ledger EXISTS but could not be read or parsed — what this window owes cannot be established, refusing kill (your-org/nexus-code#961)"
        exit 1
    fi
    _sk_ev_explain
    printf 'retire-preflight: %q still OWES a skeptic verdict on specific work:\n' "$win_name" >&2
    printf '%s\n' "$_sk_owed_out" | sed 's/^/    /' >&2
    printf '  The pending MARKER cannot say this — its content is `1`, so one verdict clears it\n' >&2
    printf '  for every task nobody reviewed (your-org/nexus-code#961). The ledger names them.\n' >&2
    printf '  EITHER get a verdict that names what it read:\n' >&2
    printf '      monitor/ng wrap-up <issue> <report> --skeptic-role --skeptic-verdict <v> \\\n' >&2
    printf '          --skeptic-target %q --skeptic-subject <the-report-you-reviewed>\n' "$win_name" >&2
    printf '  OR decline the remaining rounds on the record:\n' >&2
    printf '      monitor/ng skeptic resolve %q --reason "<why no further pass>"\n' "$win_name" >&2
    _sk_owed_n=$(sed -n 's/.*outstanding=\([0-9]*\).*/\1/p' <<<"$_sk_owed_out" | head -1)
    emit 0 "$pane_state" "this window has ${_sk_owed_n:-one or more} artefact(s) armed for a skeptic pass with NO attributed verdict and no recorded resolution — a cleared marker is not clearance (your-org/nexus-code#961), refusing kill; see stderr for which$(_sk_ev_clause)"
    exit 1
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

# ---- THE GATE RECORDS WHAT IT READ (your-org/nexus-code#962) ---------------
#
# Until this line, this gate was a PURE READ that wrote nothing. Every other
# check on the kill path leaves a trace — 1b clears a marker, the releases write
# a `.cleared-rationale`, the kill itself logs `window-close`. This one decided
# whether an IRREVERSIBLE `tmux kill-window` may proceed and left no artefact of
# its answer, so after the fact nobody could say what it had said.
#
# That is not hypothetical. Asked "how many retirements were authorised on a
# disposition belonging to a DIFFERENT TASK", the honest answer for one of two
# candidate windows was UNDETERMINABLE — not because nothing happened, but
# because no record of the decision exists (#962 retrospective,
# 2026-08-15T12:34:31Z). The other was answerable only because a `window-close`
# happened to be logged 10 hours later.
#
# THIS DOES NOT CHANGE KILL SEMANTICS, DELIBERATELY. It records; it never
# decides. Placed BEFORE the probe-failure arm so the `unknown` / could-not-run
# case is recorded too — "the gate could not look" is exactly the answer a later
# audit most needs and the one an after-the-arm placement would drop.
#
# FAIL-OPEN, and that is the right direction HERE even though this file's every
# other doubt resolves toward refusing. A logging failure is not evidence about
# the window; letting it block a retirement would convert a full disk into a
# board-wide stall, and letting it *permit* one changes nothing, because the
# decision below is computed from `disp_state` and not from whether the write
# landed. Bounded and detached from this script's exit status on purpose:
# `|| true` plus a `timeout`, mirroring the probe's own bound above.
#
# Best-effort by construction: `ng_bin` may be empty (that is one of the states
# being recorded), in which case there is nothing to log with and the absence of
# a record is itself the accurate account.
if [[ -n "$ng_bin" ]]; then
    ( NEXUS_STATE_DIR="$STATE_DIR" timeout "${RETIRE_PREFLIGHT_DISPOSITION_TIMEOUT:-60}" \
        "$ng_bin" log-action retire-preflight \
        --event skeptic-disposition-gate \
        --extra "window=$win_name" \
        --extra "state=${disp_state:-<empty>}" \
        --extra "probe-rc=$disp_rc" \
        --extra "report=${disp_report:--}" \
        --extra "report-mtime=$disp_mtime" \
        --extra "pane-state=$pane_state" \
        >/dev/null 2>&1 ) || true
fi

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
        _disp_rationale="$STATE_DIR/skeptic/pending/.$(wk_encode "$win_name").cleared-rationale"
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
        _disp_rationale="$STATE_DIR/skeptic/pending/.$(wk_encode "$win_name").cleared-rationale"
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

# ---- check 1d: this window OWES somebody -----------------------------------
# your-org/nexus-code#845. Every gate above asks a question ABOUT THIS WINDOW:
# is its pane busy, did the operator just type into it, does its own report
# ask for another pass. All of them were satisfied — `safe=1` — for `sk911`
# on 2026-08-14, which was retired while it still owed `papercuts` a delta
# re-run. `papercuts` then pushed its fix to a reviewer that no longer
# existed. A `window-retain` had even been logged for sk911; nothing reads it
# as a gate, and it would not have helped, because a retain is a NOTE and not
# a RELATION.
#
# The missing axis is not liveness, it is OBLIGATION: does this window still
# owe, or is it owed, something. Check 1b already covers "is it owed" — a
# live pending marker means a skeptic still owes THIS window a verdict. The
# converse had no representation at all, because the pairing lived only in
# the orchestrator's head. `monitor/_obligations.sh` makes it a record,
# written by `spawn-worker.sh --skeptic-role` at the instant the reviewer
# exists, so nobody has to remember it.
#
# DIRECTION OF ERROR, and it is the opposite of check 1b's. A marker gone
# ORPHANED there ALLOWS the kill, because the harm is a window lingering
# forever. Here the harm is destroying a reviewer somebody is still waiting
# on — an unrecoverable act that strands TWO windows — so doubt REFUSES, and
# `obl_blocks_retirement` is an allowlist of three states that each assert
# POSITIVELY that nobody is waiting. A state this gate has never heard of
# blocks.
#
# WHY IT DOES NOT FIRE ON HEALTHY PAIRS, which is the property that keeps it
# from being disabled by whoever is under time pressure. It fires only when
# somebody is trying to RETIRE a debtor. A parked target with a working
# skeptic never reaches this gate — nobody is retiring either end. And the
# releases are automatic in every ordinary ending: the skeptic's own verdict
# settles the edge explicitly, and clearing the creditor's pending marker by
# ANY path (verdict, waive, `ng skeptic resolve`, retirement) voids it
# derivedly, with no bookkeeping.
#
# Absent library ⇒ doubt ⇒ no-go, same as `_bookkeeping.sh` above.
if [[ -r "$self_dir/_obligations.sh" ]]; then
    # shellcheck source=monitor/_obligations.sh
    source "$self_dir/_obligations.sh"
    _obl_rows=$(obl_blocking_for_debtor "$STATE_DIR" "$win_name" 2>/dev/null)
    if [[ -n "$_obl_rows" ]]; then
        _obl_first_creditor=""
        _obl_n=0
        while IFS=$'\t' read -r _o_id _o_state _o_creditor _o_detail; do
            [[ -n "$_o_id" ]] || continue
            _obl_n=$(( _obl_n + 1 ))
            [[ -n "$_obl_first_creditor" ]] || _obl_first_creditor="$_o_creditor"
            printf 'retire-preflight: %q OWES %q (%s)\n' "$win_name" "$_o_creditor" "$_o_state" >&2
            printf '  %s\n' "$_o_detail" >&2
            printf '  obligation: %s\n' "$_o_id" >&2
        done <<<"$_obl_rows"
        printf 'retire-preflight: retiring this window strands its counterpart — the target pushes\n' >&2
        printf '  its next round to a reviewer that no longer exists, and its own pending marker\n' >&2
        printf '  keeps ITS retirement blocked too. One bad retirement strands two windows\n' >&2
        printf '  (your-org/nexus-code#845).\n' >&2
        printf '  A FILED VERDICT DOES NOT CLEAR THIS. A verdict discharges one ROUND;\n' >&2
        printf '  this is the PAIRING, and a retained reviewer is the designated reviewer\n' >&2
        printf '  for the next round too. `sk911` filed its verdict at 09:19:36 and was\n' >&2
        printf '  retired at 09:21:21; its target was still being worked at 10:55 and a\n' >&2
        printf '  THIRD reviewer had to be spawned. End the pairing deliberately:\n' >&2
        printf '      monitor/ng skeptic close %q      <- the protocol'"'"'s own end-of-pairing\n' "$_obl_first_creditor" >&2
        printf '                                          signal; also releases the target'"'"'s\n' >&2
        printf '                                          await loop (exit 10)\n' >&2
        printf '  OR, if the pairing ended some other way, say so on the record:\n' >&2
        printf '      monitor/ng obligation settle --debtor %q --reason "<why this reviewer is no longer owed>"\n' "$win_name" >&2
        printf '  Inspect it first: monitor/ng obligation list --debtor %q\n' "$win_name" >&2
        # THE TWO-LEDGER DESYNC (your-org/nexus-code#1156, the `annzmerge` /
        # `overlaycontent` case). This edge lives in `$STATE_DIR/obligations`;
        # the skeptic ledger is a SECOND record of the same dependency, and it
        # can be fully settled — matching hash, `attributed`, verdict recorded —
        # while the edge is still live. Then "discharge with a verdict" above is
        # advice to redo work that is already done, and the only way anyone found
        # out was by reading both files by hand. The arms and discharges live on
        # the CREDITOR's ledger (the target this reviewer was paired to), so that
        # is the file to read — read it and say what it holds.
        _obl_ev=""
        if [[ -n "${_sk_ng_bin:-}" && -n "$_obl_first_creditor" ]]; then
            _obl_ev=$(timeout "${RETIRE_PREFLIGHT_DISPOSITION_TIMEOUT:-60}" \
                "$_sk_ng_bin" skeptic-evidence "$_obl_first_creditor" --state-dir "$STATE_DIR" 2>/dev/null) \
                || _obl_ev=""
        fi
        _obl_ev_class=$(sed -n '1s/.*[[:space:]]evidence=\([^[:space:]][^[:space:]]*\).*/\1/p' <<<"$_obl_ev")
        # DELIVERED group of `ng`'s `_skeptic_evidence_sides` — kept in step by
        # `test-skeptic-evidence-class-agreement.sh`. `unmatched-other` and
        # `prior-verdict-other-artefact` were MISSING here while that authority
        # declared both delivered, and `no-open-arm` was added to the classifier
        # and to the authority without reaching this arm. The default below is
        # SILENT, so for those classes the operator was told to "discharge with a
        # verdict or settle" with no mention that the creditor's ledger already
        # records one — the duplicate-review advice `#1156` exists to prevent,
        # missing from the place built to prevent it.
        # NAME THE VERB THAT DISCHARGES BOTH, AND NAME IT FIRST
        # (your-org/nexus-code#1190, #845). This refusal used to name only
        # `ng obligation settle`, which settles the EDGE and nothing else — so
        # an operator following it had to discover `ng skeptic resolve` and
        # `ng skeptic close` on their own, and did the work in THREE writes.
        # Measured on this board: an operator who ran `settle` at 08:08:36 and
        # `skeptic resolve` at 08:23:39 concluded from the sequence that the
        # architecture required three acts. It does not — `skeptic-channel.sh
        # cmd_resolve` calls `obligations.sh settle --creditor` itself
        # (skeptic-channel.sh:1395), so resolve-FIRST discharges the ledger and
        # the edge together. The three writes were a property of the ORDER, and
        # the order came from this message.
        #
        # `settle -> close` remains genuinely advisory and that is deliberate
        # (`#1190`): ending a ROUND and ending a PAIRING are different acts.
        # This changes only which verb is offered, never what any verb does.
        case "$_obl_ev_class" in
            attributed|unmatched-subject|no-open-arm|verdict-without-arm|unmatched-other|ambiguous-arms|rearm-after-close|superseded-verdict|prior-verdict-other-artefact)
                printf '  NOTE — THE OTHER LEDGER DISAGREES. %q'"'"'s skeptic ledger already records a\n' \
                    "$_obl_first_creditor" >&2
                printf '  verdict (evidence=%s). This is the TWO-LEDGER DESYNC, not an unmet\n' \
                    "$_obl_ev_class" >&2
                printf '  requirement: the verdict was delivered and the obligation EDGE was never\n' >&2
                printf '  settled. Discharge it with `ng skeptic resolve %q` — that records the\n' "$_obl_first_creditor" >&2
                printf '  resolution AND settles the edge in ONE act. Do not ask for another verdict.\n' >&2
                printf '%s\n' "$_obl_ev" | sed -n '2,$p' | sed 's/^/      /' >&2
                _obl_ev_tag=" | the CREDITOR skeptic ledger ALREADY records a verdict (evidence=$_obl_ev_class) — TWO-LEDGER DESYNC, settle the edge rather than asking for another review (your-org/nexus-code#1156)"
                ;;
            *) _obl_ev_tag="" ;;
        esac
        emit 0 "$pane_state" "this window OWES $_obl_n outstanding obligation(s) — it still owes \`$_obl_first_creditor\` and retiring it strands that window (your-org/nexus-code#845); discharge with \`ng skeptic resolve $_obl_first_creditor\` (ONE act: it records the resolution and settles the edge), or for a non-skeptic obligation \`ng obligation settle --debtor <window> --reason …\`${_obl_ev_tag:-}"
        exit 1
    fi
else
    printf 'safe=0 window=%s pane=%s reason=%s\n' "$win_name" "$pane_state" \
        "cannot source monitor/_obligations.sh (the obligation ledger) — cannot establish whether this window owes another one a verdict; doubt about an IRREVERSIBLE kill refuses (your-org/nexus-code#845)"
    exit 1
fi

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
        pf_prov="$STATE_DIR/windows/$(wk_encode "$win_name").json"
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
