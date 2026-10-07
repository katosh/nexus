#!/usr/bin/env bash
# monitor/longjob-watch.sh — wake THIS session when a long computation ends,
# fails, or does anything else you asked to be told about
# (your-org/nexus-code#1535; alias `ng longjob`).
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────
#
# The nexus is built for analyses whose computations run for hours, and the
# harness gives an agent nothing that survives that long: the model-armed
# `Monitor` is capped at 30 min (enforced at arm AND at runtime), `CronCreate`
# waits for an idle REPL (measured 18m35s late), and `async-run.sh` RETAINS an
# exit status but never re-invokes anybody (#1523: a skeptic `await` expired
# cleanly and the agent sat idle 809 s). A worker that starts a four-hour
# Slurm job has had no way to be told it finished.
#
# Claude Code has exactly one wake mechanism that is armed WITHOUT a model
# turn and is not bound by the 30-minute cap: a PLUGIN-DECLARED monitor
# (`experimental.monitors` in a plugin manifest, loaded with
# `claude --plugin-dir`). Measured on 2.1.272 (your-org/your-nexus#375):
# armed at session start with zero turns; command still running at 41 min;
# a stdout line emitted at T0+32m delivered the same minute; keeps ticking
# while the REPL is blocked on a modal. And one hard constraint, also
# measured: A MONITOR COMMAND THAT EXITS IS NOT RELAUNCHED, and its exit is
# delivered as a "script failed" notice that costs a turn.
#
# So the design is a DISPATCHER, not a monitor per job: ONE host-armed
# command per session (`dispatch`, below) that never returns, polling a
# per-session SPOOL of watch specs that the agent drops in at any time with
# `add`, and printing ONE line per meaningful transition. Each printed line
# is delivered to the model as a <task_notification>.
#
# ── THE SPOOL IS THE DURABLE PART, NOT THE PROCESS ───────────────────────
#
#   $NEXUS_STATE_DIR/longjob/<session-key>/
#       watches/<id>.json     one spec + its live state, jq-managed
#       events.log            every transition, printed or not (TSV)
#       dispatcher.json       the LEDGER: pid + start-time, armed_at,
#                             last_poll, active count, written (NOT delivered —
#                             see _emit), emit_failures,
#                             muted — written every poll; the thing every
#                             "is this session armed?" question reads
#       emit-failures.log     each stdout write that FAILED (see below)
#
# ── THE LEDGER CONTRACT (written down after two rounds of writer/reader
#    violations, skeptic D1/D2; every reader and writer is bound by THIS) ──
#
#   writer   `dispatch` only. It writes the WHOLE file atomically:
#            (a) once when armed, (b) after every poll pass, and (c) INSIDE a
#            pass, ON TIME rather than on events: before every probe once
#            poll_seconds have elapsed since the last write, and before
#            every paced wait in `_emit`. A heartbeat that only beat when
#            something was emitted was the third-round defect (R1: a pass
#            of slow probes with no transitions aged last_poll past the
#            window). The honest bound: `last_poll` never ages by more than
#            poll_seconds + probe_timeout_seconds (one probe is
#            uninterruptible) while the dispatcher is alive — whatever the
#            pass is doing. Relation guard: that bound must sit inside the
#            freshness window 3 × poll_seconds + 30, i.e.
#            probe_timeout_seconds ≤ 2 × poll_seconds + 30, which holds at
#            every shipped default (30 ≤ 70) and at the probe rig's 5 s
#            cadence (30 ≤ 40); `dispatch` refuses to start otherwise.
#   fields   EVERY field below has a named reader; an unread field is a
#            promise the next author will believe (independent contract pass,
#            skeptic C-fields). version (schema; _ledger_verdict REFUSES any
#            other value as `absent`, which is the migration gate), pid +
#            pid_start (identity, read by the verdict), armed_at (status),
#            born_ticks (the dispatcher's BIRTH as `dispatch` in /proc start
#            ticks; read by pane-state.sh:_pane_longjob_root, which refuses to
#            exclude a root whose dispatcher has a child OLDER than this —
#            your-org/nexus-code#1565; see cmd_dispatch),
#            owner_pid + owner_start (the claude this dispatcher prints INTO,
#            pid + start ticks captured at arm, both "" when there is none —
#            your-org/nexus-code#1623; read by _ledger_verdict, which reads a
#            live pid whose owner is gone as `dead`, and by
#            _ledger_foreign_owner, which ranks writers by owner; a ledger
#            WITHOUT the keys predates them and its owner is derived live),
#            last_poll (the LIVENESS field: epoch of the last write; verdict),
#            poll_seconds (THE WRITER'S cadence; the verdict judges freshness
#            against it, never against a reader's config), service — the
#            SERVICE predicate, `polling` | `disabled` | `unscoped`: whether
#            this process is actually observing the spool and probing
#            watches (verdict: anything but `polling` is `disabled`, never
#            `armed`); `stdout-closed` (#1623) is the fourth value: a terminal
#            write failed, the spool is RELEASED, and _ledger_foreign_owner
#            reads it as no owner; active (status, display only — a KILL decision counts
#            the spool itself, see `ledger-verdict`), written (lines handed
#            to the host; NOT delivered; status), emit_failures (status),
#            muted (verdict), window (the window this ledger speaks for;
#            pane-state's discount), note (human text; status prints it —
#            it is never a predicate, which is what C1 was).
#            REMOVED: retired, session_key, session_id — they had no reader.
#   PROCESS vs SERVICE (the root cause the independent pass named): `armed`
#            used to mean "pid alive, ledger fresh" while every consumer read
#            it as "your watch will be polled and you will be woken". They
#            are different predicates. `armed` now REQUIRES service=polling,
#            so the kill switch (C1), an unscoped launch, and any future
#            not-serving branch all read `disabled`, and `add` says so.
#   readers  `_ledger_verdict` is the ONE reader of liveness AND service;
#            `status`, `add`, `ledger-verdict` and pane-state.sh's discount
#            all go through it. Its rule: version == 2 → else `absent`;
#            pid alive AND pid_start matches → else `dead`;
#            `now - last_poll <= 3 × poll_seconds + 30` → else `stale`;
#            service == polling → else `disabled`; muted → `muted`; else
#            `armed`. `ledger-verdict` additionally prints `active=<n>`
#            COUNTED FROM THE SPOOL (non-retired specs), never the cached
#            field, because `active` is published only by a completed pass
#            and a kill decision must not depend on pass timing (C2).
#   relation guards, both pinned by the suite: last_poll advances during a
#            paced burst (D1), and the verdict flips with the ledger's own
#            poll_seconds in BOTH directions (D2). The constants that must
#            agree — EMIT_MIN_GAP_MS and the freshness window — agree by
#            construction of (c), not by choice of values.
#
# <session-key> is `$CLAUDE_CODE_SESSION_ID` (the harness exports it to the
# monitor command and to every Bash-tool shell alike — measured, both) and
# falls back to the tmux window name. Keying on the session id is what gives
# per-session scoping without a pattern (#1073: a predicate keyed on a NAME
# matches sibling agents): `--resume`/`--continue` keep the id, so a respawned
# session re-arms its own watches from its own spool on the first poll; a
# NEW session has a new id and an empty spool, so a dead session's watches
# cannot leak into it.
#
# What survives what: the SPOOL survives a respawn, a crash, and a sandbox
# restart (it is a directory). The DISPATCHER PROCESS is session-scoped — it
# dies with the `claude` that armed it and comes back only when a session
# is launched with the plugin present. Nothing here outlives the sandbox;
# the watcher is the sandbox's init payload and revives the board, not this.
#
# ── SILENCE IS NOT SUCCESS ───────────────────────────────────────────────
#
# A watch emits on EVERY terminal state. The probe contract has FIVE answers,
# pending | running | done | failed | unknown, and `unknown` is not
# `running`: a probe that cannot tell says so, the dispatcher retries it a
# bounded number of polls (`unknown_max`), and then EMITS an UNKNOWN event
# and parks the watch — never silence. Probes live in
# monitor/longjob-probes.d/<kind>.sh; adding a subject kind is one file.
#
# ── EVENTS COST MONEY AND COMMISSION WORK ────────────────────────────────
#
# Measured: one delivered line cost the receiving session 3m26s and $1.53 —
# not the wake, the work the turn then decided to do. Therefore: one event
# per TRANSITION (dedup by state), a per-watch cap (`max_events`), a
# per-session cap (`session_max_events`, after which ONE final line says the
# dispatcher is muted and how to unmute; `unmute` grants a fresh budget),
# and progress ticks are never
# printed unless a watch asks for `--notify transitions`. The default watch
# prints its terminal state and nothing else.
#
# ── AN EMIT PATH THAT CANNOT REPORT ITS OWN FAILURE IS INDISTINGUISHABLE
#    FROM A DISPATCHER WITH NOTHING TO SAY ───────────────────────────────
#
# (#1533/#1535.) So every printf to stdout is checked; a failed write is
# appended to emit-failures.log and counted in the ledger, SIGPIPE is
# ignored so a closed stdout cannot kill the loop, and the ledger itself is
# written on every poll whether or not anything was printed. "How would we
# notice the day the host stops arming them?" is answered by detectors that
# are NOT the emit path: `status` reads the ledger's freshness and the
# pid's identity; `add` warns on stdout when the ledger is not fresh; every
# `add` also registers an `external_waits` entry via declare-wait.sh, so a
# session whose dispatcher is absent reads `idle-orphan-async` in
# pane-state.sh and the watcher's orphan-async loop resolves the wait
# through `resolve` — the pre-existing backstop, now reachable for this kind.
#
# ── NEVER EXIT ───────────────────────────────────────────────────────────
#
# `dispatch` treats its own return as a fault: the poll loop runs under a
# supervisor loop that logs and restarts it, an empty spool is a loop that
# sleeps, an unreadable spool is a loop that logs once and sleeps, and the
# last watch retiring is a loop that sleeps. The suite asserts the process
# is alive after every watch has completed.
#
# …WITH TWO EXITS, BOTH WHEN NOBODY IS LEFT TO NOTIFY (your-org/nexus-code
# #1623). The rule exists because an exit costs the SESSION a turn. So the
# dispatcher exits when the claude it was armed for is gone (an orphan
# reparented to init ate 7 terminal wakes on lsc2, printing into a dead
# pipe), and when a dispatcher serving a NEWER claude — a `--resume` of the
# same session id — has taken the ledger. A failed terminal write is not an
# exit: the watch is restored un-retired (undoing only this dispatcher's own
# write — a retirement another dispatcher made meanwhile stands) and the spool
# released.
#
# Usage:
#   longjob-watch.sh add <kind>:<target> [--desc TEXT] [--id ID] [--interval S]
#                        [--ttl S] [--notify terminal|transitions] [--persistent]
#                        [--max-events N] [--unknown-max N]
#                        [--when exists|grew|match] [--pattern ERE]      (file:)
#                        [--no-declare] [--no-first-probe]   (hook use: the launch
#                        hook already declared the wait; skip the sync probe)
#   longjob-watch.sh run [--desc TEXT] [--id ID] [--notify …] -- <cmd…>
#                        launch a LOCAL command via async-run.sh (rc retained)
#                        AND watch its token — the one-liner for a long local job
#   longjob-watch.sh list | show <id> | rm <id> | events [N] | status
#   longjob-watch.sh ledger-verdict <dispatcher.json> [--now EPOCH]   → armed|stale|dead|absent|muted
#                                                  (the ONE liveness reader; pane-state.sh calls it)
#   longjob-watch.sh resolve <id>                  → "<class>|<detail>" for the
#                                                   orphan-async resolver
#   longjob-watch.sh probe <kind>:<target> [--when W] [--pattern ERE] [--size0 N]
#                                                  → "<state>|<detail>", one shot
#   longjob-watch.sh await <id> [--timeout S]      block until terminal; for
#                                                   `run_in_background` when the
#                                                   dispatcher is NOT armed. S
#                                                   defaults to fit the default
#                                                   Bash timeout; > ~2 h → rc 2
#   longjob-watch.sh unmute | reset
#   longjob-watch.sh dispatch                      the host-armed loop (never returns).
#                                                   NEVER BY HAND IN A LIVE SESSION: a second
#                                                   writer of the session ledger makes
#                                                   pane-state exclude real work from the
#                                                   census (bundle-2609sk3 F1); tests use a
#                                                   hermetic NEXUS_STATE_DIR. NOT ARMED →
#                                                   use `await`, which writes no ledger.
#
# Subject kinds:  slurm:<jobid>  asyncrun:<token>  pid:<pid>[:<starttime>]
#                 file:<path>    cmd:<shell command line>
#
# Exit codes (every verb but dispatch, which never exits — a missing jq keeps
# it alive polling nothing, and a fatal error inside a poll pass is isolated
# in a subshell; see cmd_dispatch):
#   0  ok              2  usage / no such watch / unresolvable session key
#   3  add: registered but the dispatcher is NOT ARMED in this session — the
#      watch is recorded and will NOT wake you; stdout names the fallback
#   await: 0 done · 1 failed · 3 unknown/parked/expired · 4 timeout
#   5  a required tool (jq) is missing

set -uo pipefail

_lj_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$_lj_dir/.." && pwd)}"
STATE_DIR="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"
PROBES_DIR="${NEXUS_LONGJOB_PROBES_DIR:-$_lj_dir/longjob-probes.d}"
LJ_VERSION=2   # v2: service field; retired/session_key/session_id removed

die() { printf 'longjob-watch: %s\n' "$*" >&2; exit "${2:-2}"; }
# Argument-loop progress guard (your-org/nexus-code#924): a value-taking flag
# given LAST makes `shift 2` fail and the loop spin forever; every `while
# (( $# ))` below records $# and refuses when it did not move. Exits 64.
_argloop_stuck() {
    printf '%s: option %s requires a value (argument loop made no progress)\n' "${0##*/}" "${1-}" >&2
    exit 64
}
# The help IS this file's header, up to the first code line, so the two
# cannot drift (test-ng-usage-flag-coverage.sh walks every parsed flag
# against what --help prints).
_usage() { sed -n '2,/^set -uo pipefail/{/^set -uo pipefail/d;s/^# \{0,1\}//;p}' "$0" >&2; }

if ! command -v jq >/dev/null 2>&1; then
    if [[ "${1:-}" == dispatch ]]; then
        # The dispatcher NEVER exits — not even here: an exit is a delivered
        # "script failed" notice that costs a turn (measured), and the host would
        # not relaunch it. Say why once on stderr and stay alive, polling nothing.
        printf 'longjob-watch dispatch: jq is not on PATH — staying alive but polling NOTHING; every add in this session will report NOT ARMED\n' >&2
        while :; do sleep 60; done
    fi
    die "jq is required and not on PATH" 5
fi

# ---- config (env > config/load.sh > default) --------------------------------
_cfg() {   # <env-name> <config-key> <default>
    local v="${!1:-}"
    if [[ -z "$v" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        v=$("$NEXUS_ROOT/config/load.sh" "$2" "$3" 2>/dev/null) || v=""
    fi
    [[ "$v" =~ ^[0-9]+$ ]] || v="$3"
    printf '%s' "$v"
}
POLL_SECONDS=$(_cfg MONITOR_LONGJOB_POLL_SECONDS monitor.longjob.poll_seconds 20)
DEFAULT_INTERVAL=$(_cfg MONITOR_LONGJOB_DEFAULT_INTERVAL_SECONDS monitor.longjob.default_interval_seconds 60)
SESSION_MAX_EVENTS=$(_cfg MONITOR_LONGJOB_SESSION_MAX_EVENTS monitor.longjob.session_max_events 60)
WATCH_MAX_EVENTS=$(_cfg MONITOR_LONGJOB_WATCH_MAX_EVENTS monitor.longjob.watch_max_events 8)
UNKNOWN_MAX=$(_cfg MONITOR_LONGJOB_UNKNOWN_MAX monitor.longjob.unknown_max 5)
TTL_SECONDS=$(_cfg MONITOR_LONGJOB_TTL_SECONDS monitor.longjob.ttl_seconds 604800)
PROBE_TIMEOUT=$(_cfg MONITOR_LONGJOB_PROBE_TIMEOUT_SECONDS monitor.longjob.probe_timeout_seconds 30)
(( POLL_SECONDS < 5 )) && POLL_SECONDS=5
# `await` runs under the Bash tool's run_in_background, and since Claude Code
# 2.1.285 the harness STOPS that call at the call's own `timeout` (default
# max(30 min, BASH_DEFAULT_TIMEOUT_MS), ceiling max(2 h, BASH_MAX_TIMEOUT_MS))
# and re-invokes the agent with a stop notice instead of await's typed rc
# (your-org/nexus-code#1685). So await's DEFAULT fits the default Bash timeout,
# the NOT-ARMED fallback prints the Bash `timeout` its --timeout needs, and a
# --timeout no single background call can hold is refused. BG_SLACK_S covers
# await's overshoot past its deadline: at most one probe (timeout -k 5).
_bg_s() { local v="${1:-}" floor="$2"; [[ "$v" =~ ^[0-9]+$ ]] && (( v / 1000 > floor )) && floor=$(( v / 1000 )); printf '%s' "$floor"; }
BG_DEFAULT_S=$(_bg_s "${BASH_DEFAULT_TIMEOUT_MS:-}" 1800)
BG_CEIL_S=$(_bg_s "${BASH_MAX_TIMEOUT_MS:-}" 7200)
BG_SLACK_S=$(( PROBE_TIMEOUT + 30 ))
AWAIT_DEFAULT_S=$(( BG_DEFAULT_S - BG_SLACK_S ))
AWAIT_MAX_S=$(( BG_CEIL_S - BG_SLACK_S ))
# The runnable fallback for <id>: the await line AND the Bash `timeout` (ms) it
# needs, plus how to read a harness stop. One place, so the two NOT-ARMED arms
# cannot drift apart.
_await_fallback() {   # <id> [await-seconds]
    local s="${2:-$AWAIT_DEFAULT_S}"
    printf 'Fallback that DOES re-invoke you — ONE Bash call with run_in_background: true AND timeout: %s (ms; it must exceed --timeout, or the harness stops the wait first):\n    monitor/longjob-watch.sh await %s --timeout %s\n' \
        "$(( (s + BG_SLACK_S) * 1000 ))" "$1" "$s"
    printf 'It re-invokes you with rc 0 done, 1 failed, 3 unknown, 4 timeout (4: re-enter the same call). A harness STOP notice (<status>killed</status>, "background time limit") is not a verdict on the job either: re-run the call above. --timeout is capped at %ss (one background Bash call cannot outlive %ss); a job longer than that belongs to an ARMED ng longjob watch.\n' \
        "$AWAIT_MAX_S" "$BG_CEIL_S"
}
# A ledger is FRESH while its last_poll is younger than 3 × the poll cadence
# the ledger ITSELF records + 30 s (see _ledger_verdict) — the reader's own
# config never decides another process's cadence (skeptic D2).

# ---- session key --------------------------------------------------------------
# `$CLAUDE_CODE_SESSION_ID` first (per-session, survives resume), else the
# window (per-window, the launcher exports it), else nothing — and "nothing"
# is a refusal for every verb except dispatch, which stays alive unscoped so
# the host never sees an exit.
SESSION_KEY=""
_resolve_key() {
    # NEXUS_LONGJOB_SESSION_ID lets a process OUTSIDE the session (the
    # watcher's orphan-async resolver, which has no CLAUDE_CODE_SESSION_ID of
    # its own) address a session's spool by the id its heartbeat records.
    local sid="${NEXUS_LONGJOB_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}" win="${NEXUS_LONGJOB_WINDOW:-${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-}}}"
    if [[ -n "${NEXUS_LONGJOB_KEY:-}" ]]; then SESSION_KEY="$NEXUS_LONGJOB_KEY"
    elif [[ "$sid" =~ ^[0-9a-fA-F-]{8,}$ ]]; then SESSION_KEY="sid-$sid"
    elif [[ -n "$win" ]]; then SESSION_KEY="win-$(_wk_encode "$win")"
    fi
}
_wk_encode() {   # local copy of _bookkeeping.sh:wk_encode's alphabet (no sourcing on the hot path)
    local LC_ALL=C s="${1-}" out="" i c
    case "$s" in *[!A-Za-z0-9_-]*) ;; *) printf '%s' "$s"; return 0 ;; esac
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in [A-Za-z0-9_-]) out+="$c" ;; *) printf -v out '%s%%%02X' "$out" "'$c" ;; esac
    done
    printf '%s' "$out"
}
_resolve_key
SPOOL=""
[[ -n "$SESSION_KEY" ]] && SPOOL="$STATE_DIR/longjob/$SESSION_KEY"
WINDOW_NAME="${NEXUS_LONGJOB_WINDOW:-${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-}}}"

_require_spool() {
    [[ -n "$SPOOL" ]] || die "cannot resolve a session key: neither CLAUDE_CODE_SESSION_ID nor NEXUS_WORKER_WINDOW/NEXUS_ORCHESTRATOR_WINDOW is set (run from an agent's tool shell, or set NEXUS_LONGJOB_KEY)"
    mkdir -p "$SPOOL/watches" 2>/dev/null || die "cannot create spool $SPOOL"
}

# LJ_NOW_OVERRIDE lets a caller pin the clock (pane-state.sh passes its own
# `--now` through `ledger-verdict`), so the kill-decision reader and this
# reader never disagree about what "fresh" means because they read two clocks.
_now() {
    if [[ "${LJ_NOW_OVERRIDE:-}" =~ ^[0-9]{9,11}$ ]]; then printf '%s' "$LJ_NOW_OVERRIDE"; else date -u +%s; fi
}
_pid_start() {   # <pid> → /proc stat field 22 or empty
    local stat; stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
    stat="${stat##*) }"
    # shellcheck disable=SC2086
    set -- $stat; printf '%s' "${20-}"
}
# _find_owner <pid> → "<claude_pid> <claude_start>" of the NEAREST `claude`
# STRICTLY ABOVE <pid>, or nothing (your-org/nexus-code#1623).
#
# THE OWNER is the session process a dispatcher serves: the host launches the
# monitor as claude → `zsh -c …` → `bash longjob-watch.sh dispatch`, and the
# dispatcher's stdout is a pipe INTO that claude. When the claude dies the
# pipe has no reader, and a dispatcher that keeps polling is an orphan
# (reparented to init) that consumes watches and prints them into nothing —
# measured on lsc2: 7 terminal wakes `write-failed`, among them a 2335 s suite.
#
# IDENTITY IS pid + /proc START TICKS (stat field 22), captured ONCE, at arm.
# Never ppid: a reparented process has ppid 1 while its pid is fine, and a
# recycled owner pid would read alive by pid alone. The comm set is the one
# pane-state.sh:_pane_longjob_root walks to. NOTHING printed = no claude within
# 16 hops before init (a hermetic test, CI, a hand-run under something else):
# such a dispatcher has no owner to outlive and never self-exits on this
# ground — the pre-#1623 behaviour, stated as the boundary.
_find_owner() {
    local cur="$1" hop stat after comm ppid
    local -a f=()
    for (( hop = 0; hop < 16; hop++ )); do
        { IFS= read -r stat < "/proc/$cur/stat"; } 2>/dev/null || return 0
        after="${stat##*) }"; f=($after); ppid="${f[1]:-}"
        [[ "$ppid" =~ ^[0-9]+$ ]] && (( ppid > 1 )) || return 0
        cur="$ppid"
        { IFS= read -r stat < "/proc/$cur/stat"; } 2>/dev/null || return 0
        comm="${stat%) *}"; comm="${comm#*(}"
        case "$comm" in
            claude|claude.exe|claude-code)
                after="${stat##*) }"; f=($after)
                [[ "${f[19]:-}" =~ ^[0-9]+$ ]] && printf '%s %s' "$cur" "${f[19]}"
                return 0 ;;
        esac
    done
    return 0
}
# _owner_gone <pid> <start> → rc 0 when an owner was RECORDED and is no longer
# that process (pid gone, or its start ticks differ: recycled). An empty record
# is "no owner", never "gone".
_owner_gone() {
    [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] || return 1
    [[ "$(_pid_start "$1")" != "$2" ]]
}

# ---- spec helpers -------------------------------------------------------------
_spec_path() { printf '%s/watches/%s.json' "$SPOOL" "$1"; }
_spec_get()  { jq -r "$2 // empty" "$1" 2>/dev/null; }
_spec_write() {   # <path> <json>  atomic
    local tmp="$1.$$.tmp"
    printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1"
}
_new_id() {
    local r
    r=$(head -c 6 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n') || r=$(( RANDOM * RANDOM ))
    printf 'lj-%s' "$r"
}

# ---- probe dispatch -----------------------------------------------------------
# _probe <kind> <target> <spec-json> → "<state>|<detail>" ALWAYS (rc 0). Runs
# the kind's file in a subshell under `timeout`, so a probe that hangs, dies,
# or prints garbage still yields an answer in the five-word vocabulary — and
# the answer for every failure of the probe ITSELF is `unknown`, never
# `running`.
_probe() {
    local kind="$1" target="$2" spec="$3" file="$PROBES_DIR/$kind.sh" out rc state detail
    [[ "$kind" =~ ^[a-z][a-z0-9-]*$ ]] || { printf 'unknown|invalid kind %s' "$kind"; return 0; }
    [[ -r "$file" ]] || { printf 'unknown|no probe for kind %s (expected %s)' "$kind" "$file"; return 0; }
    out=$(timeout -k 5 "$PROBE_TIMEOUT" bash -c '
        set -uo pipefail
        # shellcheck disable=SC1090
        . "$1" || exit 90
        declare -F lj_probe_main >/dev/null 2>&1 || exit 91
        lj_probe_main "$2" "$3"' _ "$file" "$target" "$spec" 2>/dev/null); rc=$?
    case "$rc" in
        0) ;;
        90)  printf 'unknown|probe file %s failed to source' "$file"; return 0 ;;
        91)  printf 'unknown|probe file %s defines no lj_probe_main' "$file"; return 0 ;;
        124|137) printf 'unknown|probe timed out after %ss' "$PROBE_TIMEOUT"; return 0 ;;
        *)   printf 'unknown|probe rc=%s' "$rc"; return 0 ;;
    esac
    state="${out%%|*}"; detail="${out#*|}"; [[ "$out" == *"|"* ]] || detail=""
    detail="${detail//$'\n'/ }"; detail="${detail//$'\t'/ }"
    case "$state" in
        pending|running|done|failed|unknown) printf '%s|%s' "$state" "${detail:0:400}" ;;
        *) printf 'unknown|probe answered outside the vocabulary: %s' "${out:0:200}" ;;
    esac
    return 0
}

# ---- ledger -------------------------------------------------------------------
_ledger_path() { printf '%s/dispatcher.json' "$SPOOL"; }
# _ledger_write <note> — the ONE writer. Everything else comes from the
# dispatcher's globals (DISPATCH_PID, DISPATCH_PS, ARMED_AT, ACTIVE, EMITTED,
# EMIT_FAILURES, MUTED, SERVICE) so no call site can pass fields in the wrong
# order or forget one.
_ledger_write() {
    local tmp; tmp="$(_ledger_path).$$.tmp"
    jq -n --arg pid "${DISPATCH_PID:-$$}" --arg ps "${DISPATCH_PS:-}" --arg bt "${DISPATCH_BORN_TICKS:-}" --arg armed "${ARMED_AT:-0}" --arg now "$(_now)" \
          --arg active "${ACTIVE:-0}" --arg emitted "${EMITTED:-0}" --arg ef "${EMIT_FAILURES:-0}" --arg muted "${MUTED:-0}" \
          --arg note "${1:-}" --arg win "$WINDOW_NAME" --arg poll "$POLL_SECONDS" --arg svc "${SERVICE:-unscoped}" --arg v "$LJ_VERSION" \
          --arg op "${OWNER_PID:-}" --arg os "${OWNER_PS:-}" \
          '{version:($v|tonumber), pid:($pid|tonumber), pid_start:$ps, born_ticks:$bt, owner_pid:$op, owner_start:$os, armed_at:($armed|tonumber),
            last_poll:($now|tonumber), poll_seconds:($poll|tonumber), service:$svc, active:($active|tonumber),
            written:($emitted|tonumber), emit_failures:($ef|tonumber), muted:($muted|tonumber), window:$win, note:$note}' \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "$(_ledger_path)" && LAST_LEDGER_WRITE=$(_now)
}
# _ledger_verdict → prints one of  armed|stale|dead|absent|muted  and a reason
_ledger_verdict() {
    local l; l=$(_ledger_path)
    [[ -f "$l" ]] || { printf 'absent|no dispatcher ledger in %s — no dispatcher has ever polled this session'"'"'s spool' "$SPOOL"; return 0; }
    local pid ps last muted now age live=0 lpoll fresh ver svc
    ver=$(jq -r '.version // "none"' "$l" 2>/dev/null)
    if [[ "$ver" != "$LJ_VERSION" ]]; then
        # The schema version's reader, and the migration gate: an older or
        # newer ledger is not read as anything — least of all as armed.
        printf 'absent|ledger schema version %s is not this reader'"'"'s %s — not read (the dispatcher that wrote it is a different build; respawn the session)' "$ver" "$LJ_VERSION"; return 0
    fi
    svc=$(jq -r '.service // "unscoped"' "$l" 2>/dev/null)
    pid=$(jq -r '.pid // 0' "$l" 2>/dev/null); ps=$(jq -r '.pid_start // ""' "$l" 2>/dev/null)
    last=$(jq -r '.last_poll // 0' "$l" 2>/dev/null); muted=$(jq -r '.muted // 0' "$l" 2>/dev/null)
    # Freshness is judged against the DISPATCHER's recorded cadence, never the
    # reader's own config (skeptic D2): a reader defaulting to 20 s read a
    # 5 s-cadence ledger as armed at 57 s and a 120 s-cadence ledger as stale
    # at 200 s — the second direction freezes the board.
    lpoll=$(jq -r '.poll_seconds // empty' "$l" 2>/dev/null)
    [[ "$lpoll" =~ ^[0-9]+$ ]] || lpoll="$POLL_SECONDS"
    fresh=$(( lpoll * 3 + 30 ))
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    now=$(_now); age=$(( now - last ))
    if [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 0 )) && [[ -d "/proc/$pid" ]]; then
        [[ -z "$ps" || "$(_pid_start "$pid")" == "$ps" ]] && live=1
    fi
    # ALIVE IS NOT OWNED (your-org/nexus-code#1623): a dispatcher whose
    # recorded owner — the claude it prints INTO — is gone is an orphan. Its
    # pid and polls are real and it reads `armed` by every other test here,
    # while every line it prints goes to a pipe with no reader. It exits on its
    # own within one poll; this reads it `dead` in that window (and for a
    # dispatcher wedged in it). An absent or empty owner is not consulted.
    local opid ops
    opid=$(jq -r '.owner_pid // ""' "$l" 2>/dev/null); ops=$(jq -r '.owner_start // ""' "$l" 2>/dev/null)
    if (( live == 1 )) && _owner_gone "$opid" "$ops"; then
        printf 'dead|dispatcher pid %s is alive but ORPHANED: its session (claude pid %s) is gone, so nothing reads what it prints — this session is NOT armed' "$pid" "$opid"
    elif (( live == 0 )); then
        printf 'dead|dispatcher pid %s is gone (last poll %ss ago) — this session is NOT armed; the host will not relaunch a monitor command that exited' "$pid" "$age"
    elif (( age > fresh )); then
        printf 'stale|dispatcher pid %s is alive but its last poll was %ss ago (> %ss = 3×its own poll_seconds %s + 30): wedged, or the host stopped scheduling it' "$pid" "$age" "$fresh" "$lpoll"
    elif [[ "$svc" != polling ]]; then
        # ALIVE IS NOT SERVING (skeptic C1): the kill switch's branch writes a
        # fresh ledger with a live pid and polls nothing. Reading that as
        # `armed` told an agent "safe to end your turn" from the feature's
        # own off switch. The service field is the predicate; `note` is prose.
        printf 'disabled|dispatcher pid %s alive (polled %ss ago) but NOT SERVING (service=%s): the spool is not polled and no watch will wake you — %s' "$pid" "$age" "$svc" "$(jq -r '.note // ""' "$l" 2>/dev/null)"
    elif [[ "$muted" == "1" ]]; then
        printf 'muted|dispatcher alive (pid %s, polled %ss ago) but MUTED: the session event cap (%s) was reached; `longjob-watch.sh unmute` to resume' "$pid" "$age" "$SESSION_MAX_EVENTS"
    else
        printf 'armed|dispatcher pid %s alive, polled %ss ago' "$pid" "$age"
    fi
}

# _ledger_foreign_owner → prints "<pid> <rel>", rc 0, when the ledger names a
# DIFFERENT dispatcher that is ALIVE (pid + start ticks), whose polls are FRESH
# by its own recorded cadence, and that still SERVES A SESSION; rc 1 otherwise —
# no ledger, unreadable, names THIS dispatcher, names a dead or recycled pid,
# has gone stale, its recorded owner is gone, or it declared its stdout closed.
# <rel> is the foreign dispatcher's OWNER relative to THIS one's:
#   newer   its claude started after mine (or it has one and I have none)
#   same    the same claude, or neither has one — the #1544 case
#   older   its claude started before mine, or it has none and I have one
#
# THE SINGLE-WRITER RULE (your-org/nexus-code#1544 — KILL DIRECTION). The header
# of `_ledger_write` says "the ONE writer", and nothing enforced it: `dispatch`
# started a second time with the inherited CLAUDE_CODE_SESSION_ID wrote
# `sid-<session>/dispatcher.json` naming ITSELF, the two then alternated writes
# every poll, and `pane-state.sh` — which excludes the ledger pid's ROOT from
# the background-shell census WHOLE — read `state=idle` over a live `sleep 600`
# that shared the hand-run dispatcher's tool shell (sk3 rig 4). `idle` is on
# the kill allowlist.
#
# …AND WHO THE ONE WRITER IS (your-org/nexus-code#1623). #1544 answered "the
# incumbent", which is right for its case — a hand-run dispatcher under the
# SAME claude as the host's — and exactly wrong for a `--resume`: the resumed
# session keeps the session id, so its host-armed dispatcher found the DEAD
# incarnation's dispatcher (reparented to init, still polling) holding the
# ledger and refused to arm, for as long as the orphan lived (measured on lsc2:
# `refused pid=6414 … owned by live dispatcher pid=12201`, 7 wakes then printed
# into a broken pipe). So the rule is now keyed on the OWNER: the dispatcher
# serving the NEWEST live claude holds the ledger; with the same owner the
# incumbent keeps it (#1544 unchanged). A ledger written before #1623 records no
# owner; for it the owner is DERIVED live by the same ancestry walk, so a
# pre-#1623 orphan — no claude above it — ranks below any dispatcher that has
# one, and yields when it next sees the newcomer's write (its own #1544 check).
#
# Identity is pid + start ticks, never argv: a sibling session's dispatcher is
# byte-identical. An EMPTY `pid_start` with a live pid and fresh polls still
# counts as an owner — something is writing those polls, and the expensive
# error here is a second writer, not a session left to its `await` fallback.
# The schema version is deliberately NOT consulted: a dispatcher from another
# build is still a second writer.
_ledger_foreign_owner() {
    local l pid ps last lpoll now svc fo fop fos
    l=$(_ledger_path); [[ -f "$l" ]] || return 1
    pid=$(jq -r '.pid // 0' "$l" 2>/dev/null) || return 1
    ps=$(jq -r '.pid_start // ""' "$l" 2>/dev/null) || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 0 )) || return 1
    [[ "$pid" == "${DISPATCH_PID:-$$}" && "$ps" == "${DISPATCH_PS:-}" ]] && return 1
    [[ -d "/proc/$pid" ]] || return 1
    [[ -z "$ps" || "$(_pid_start "$pid")" == "$ps" ]] || return 1
    last=$(jq -r '.last_poll // 0' "$l" 2>/dev/null); [[ "$last" =~ ^[0-9]+$ ]] || return 1
    lpoll=$(jq -r '.poll_seconds // empty' "$l" 2>/dev/null); [[ "$lpoll" =~ ^[0-9]+$ ]] || lpoll="$POLL_SECONDS"
    now=$(_now)
    (( now - last <= lpoll * 3 + 30 )) || return 1
    # A dispatcher whose stdout is gone has RELEASED the spool (see _poll_once):
    # it polls and writes nothing more, so it is not a writer to defer to.
    svc=$(jq -r '.service // ""' "$l" 2>/dev/null)
    [[ "$svc" == stdout-closed ]] && return 1
    # THE OWNER: recorded (a #1623+ ledger carries the key, possibly empty) or,
    # for an older ledger, derived live from the foreign pid's ancestry.
    if [[ "$(jq -r 'has("owner_pid")' "$l" 2>/dev/null)" == true ]]; then
        fop=$(jq -r '.owner_pid // ""' "$l" 2>/dev/null); fos=$(jq -r '.owner_start // ""' "$l" 2>/dev/null)
        _owner_gone "$fop" "$fos" && return 1      # an orphan: it exits on its own within a poll
    else
        fo=$(_find_owner "$pid"); fop="${fo% *}"; fos="${fo#* }"; [[ -n "$fo" ]] || { fop=""; fos=""; }
    fi
    local rel=same mop="${OWNER_PID:-}" mos="${OWNER_PS:-}"
    if [[ -z "$fos" && -n "$mos" ]]; then rel=older
    elif [[ -n "$fos" && -z "$mos" ]]; then rel=newer
    elif [[ -n "$fos" && -n "$mos" && "$fop:$fos" != "$mop:$mos" ]]; then
        if (( fos > mos )); then rel=newer; elif (( fos < mos )); then rel=older; fi
    fi
    printf '%s %s' "$pid" "$rel"
}

# _owner_exit_if_gone — THIS dispatcher's own owner check (your-org/nexus-code
# #1623): when the claude it was armed for is no longer that process, exit.
# The NEVER-EXIT rule exists because an exit is a "script failed" notice that
# costs the session a turn; with the session gone there is nobody to notify, and
# staying is exactly the orphan that ate lsc2's wakes. Called at the top of every
# loop this process can sit in, so it is bounded by one poll_seconds sleep.
_owner_exit_if_gone() {
    _owner_gone "${OWNER_PID:-}" "${OWNER_PS:-}" || return 0
    [[ -n "$SPOOL" ]] && _log_event dispatcher orphaned not-printed "pid=$$ exits: the claude it serves (pid ${OWNER_PID} start ${OWNER_PS}) is gone — nothing reads its stdout (#1623)"
    exit 0
}

# _dispatch_wait_for_ledger → returns once NO dispatcher this one must defer to
# owns the ledger — one serving the SAME or a NEWER claude (see
# _ledger_foreign_owner). While one does, this process stays ALIVE (an exit is a
# delivered failure notice), polls NOTHING and WRITES NOTHING — the owner's
# ledger is left byte-identical — and says why once, on stderr and in the events
# log. The refusal lasts exactly as long as the condition that justifies it: an
# owner that dies, goes stale, is orphaned or closes its stdout releases it on
# the next tick. A foreign dispatcher serving an OLDER claude (or none, while
# this one has one) is SUPERSEDED instead: this one arms at once, and the older
# sees the write and stops (#1623).
_dispatch_wait_for_ledger() {
    local owner said=0
    while owner=$(_ledger_foreign_owner); do
        if [[ "${owner#* }" == older ]]; then
            _log_event dispatcher supersedes not-printed "pid=$$ supersedes pid=${owner% *}: that dispatcher serves an older session (or none) — the newest live claude owns the spool (#1623)"
            break
        fi
        if (( said == 0 )); then
            printf 'longjob-watch dispatch: REFUSING TO ARM — the session ledger %s already names a DIFFERENT live dispatcher (pid %s) with fresh polls, serving the same or a newer session. The ledger has ONE writer: a second one makes pane-state.sh exclude the wrong process subtree, which has read `idle` over live work (your-org/nexus-code#1544). Staying alive, polling NOTHING, writing NOTHING; this re-checks every %ss and arms only if that dispatcher stops. NEVER run `dispatch` by hand in a live session — to be woken without the host dispatcher use `longjob-watch.sh await <id> --timeout <s>` under run_in_background.\n' \
                "$(_ledger_path)" "${owner% *}" "$POLL_SECONDS" >&2
            _log_event dispatcher refused not-printed "pid=$$ NOT armed: ledger owned by live dispatcher pid=${owner% *} (single writer, #1544)"
            said=1
        fi
        sleep "$POLL_SECONDS"
        _owner_exit_if_gone
    done
    (( said == 1 )) && _log_event dispatcher released not-printed "pid=$$ the ledger's previous owner stopped; arming"
    return 0
}

# ---- declare-wait bridge -------------------------------------------------------
# Best-effort, never fatal: the wait entry is the BACKSTOP that makes an
# unarmed session visible to pane-state.sh (`idle-orphan-async`) and to the
# watcher's orphan-async loop. It needs a window name; without one there is
# no heartbeat to edit and nothing to register against.
_declare_wait()    { [[ -n "$WINDOW_NAME" && -x "$_lj_dir/declare-wait.sh" ]] && NEXUS_WORKER_WINDOW="$WINDOW_NAME" NEXUS_STATE_DIR="$STATE_DIR" "$_lj_dir/declare-wait.sh" longjob "$1" "${2:-longjob watch}" >/dev/null 2>&1 || true; }
_undeclare_wait()  { [[ -n "$WINDOW_NAME" && -x "$_lj_dir/declare-wait.sh" ]] && NEXUS_WORKER_WINDOW="$WINDOW_NAME" NEXUS_STATE_DIR="$STATE_DIR" "$_lj_dir/declare-wait.sh" --remove longjob "$1" >/dev/null 2>&1 || true; }

# ---- verbs --------------------------------------------------------------------
cmd_add() {
    _require_spool
    local subject="" desc="" id="" interval="$DEFAULT_INTERVAL" ttl="$TTL_SECONDS" notify=terminal persistent=0
    local max_events="$WATCH_MAX_EVENTS" unknown_max="$UNKNOWN_MAX" when="" pattern="" no_declare=0 no_first_probe=0
    _argloop_prev_1=-1; while (( $# )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
        case "$1" in
            --desc) desc="${2:-}"; shift 2 ;;
            --no-declare) no_declare=1; shift ;;          # the caller already declared the wait (the launch hook)
            --no-first-probe) no_first_probe=1; shift ;;  # hot path (a hook): skip the synchronous probe
            --id) id="${2:-}"; shift 2 ;;
            --interval) interval="${2:-}"; shift 2 ;;
            --ttl) ttl="${2:-}"; shift 2 ;;
            --notify) notify="${2:-}"; shift 2 ;;
            --persistent) persistent=1; shift ;;
            --max-events) max_events="${2:-}"; shift 2 ;;
            --unknown-max) unknown_max="${2:-}"; shift 2 ;;
            --when) when="${2:-}"; shift 2 ;;
            --pattern) pattern="${2:-}"; shift 2 ;;
            -h|--help) _usage; exit 0 ;;
            --*) die "add: unknown option $1" ;;
            *) [[ -z "$subject" ]] || die "add: one subject only (got '$subject' and '$1')"; subject="$1"; shift ;;
        esac
    done
    [[ -n "$subject" ]] || die "add: a subject is required (kind:target)"
    [[ "$subject" == *:* ]] || die "add: subject must be <kind>:<target>, got '$subject'"
    local kind="${subject%%:*}" target="${subject#*:}"
    [[ "$kind" =~ ^[a-z][a-z0-9-]*$ ]] || die "add: bad kind '$kind'"
    [[ -r "$PROBES_DIR/$kind.sh" ]] || die "add: no probe for kind '$kind' — known kinds: $(ls "$PROBES_DIR" 2>/dev/null | sed 's/\.sh$//' | tr '\n' ' ')"
    [[ -n "$target" ]] || die "add: empty target"
    for n in interval ttl max_events unknown_max; do [[ "${!n}" =~ ^[0-9]+$ ]] || die "add: --${n//_/-} must be an integer"; done
    (( interval < 5 )) && interval=5
    case "$notify" in terminal|transitions) ;; *) die "add: --notify must be terminal or transitions" ;; esac
    if [[ -z "$id" ]]; then id=$(_new_id); fi
    [[ "$id" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "add: --id must match [A-Za-z0-9._-]{1,64}"
    [[ -e "$(_spec_path "$id")" ]] && die "add: watch $id already exists (rm it first)"

    # Kind-specific normalisation at ADD time, where the information exists.
    local size0=0
    case "$kind" in
        pid)
            if [[ "$target" != *:* ]]; then
                [[ -d "/proc/$target" ]] || die "add: pid $target is not alive now — nothing to watch (and a pid that is gone retains no exit status; use async-run.sh + asyncrun:<token>)"
                local st; st=$(_pid_start "$target")
                [[ -n "$st" ]] || die "add: cannot read /proc/$target/stat to pin the pid's identity"
                target="$target:$st"
            fi ;;
        file)
            when="${when:-exists}"
            case "$when" in exists|grew|match) ;; *) die "add: --when must be exists|grew|match" ;; esac
            [[ "$when" == match && -z "$pattern" ]] && die "add: --when match needs --pattern ERE"
            [[ "$when" == grew && -e "$target" ]] && { size0=$(stat -c %s -- "$target" 2>/dev/null) || size0=0; } ;;
        slurm)
            # The job-id shape is the PROBE's predicate, sourced, never a copy
            # here (your-org/nexus-code#1727): `0` passed the old copy, and a
            # watch on `slurm:0` polls `sacct -j 0`, which answers about
            # unrelated jobs and never about yours. A probe file that cannot be
            # sourced or lacks the predicate REFUSES the add (fail closed).
            local _jv_rc=0
            # shellcheck disable=SC1090,SC1091
            ( . "$PROBES_DIR/slurm.sh" >/dev/null 2>&1 || exit 90
              declare -F lj_slurm_jobid_valid >/dev/null 2>&1 || exit 91
              lj_slurm_jobid_valid "$target" ) || _jv_rc=$?
            case "$_jv_rc" in
                0) ;;
                90|91) die "add: cannot load the Slurm job-id predicate from $PROBES_DIR/slurm.sh — refusing to watch an unvalidated id" ;;
                *) die "add: slurm target must be a positive Slurm job id (e.g. 123456, 123456_3), got '$target' — job id 0 does not exist, and 'sacct -j 0' answers about OTHER jobs; read the real id from sbatch's output" ;;
            esac ;;
    esac
    local now; now=$(_now)
    local spec
    spec=$(jq -n --arg id "$id" --arg kind "$kind" --arg target "$target" --arg desc "$desc" \
                 --arg now "$now" --arg interval "$interval" --arg ttl "$ttl" --arg notify "$notify" \
                 --arg persistent "$persistent" --arg max "$max_events" --arg umax "$unknown_max" \
                 --arg when "$when" --arg pattern "$pattern" --arg size0 "$size0" --arg key "$SESSION_KEY" \
           '{id:$id, kind:$kind, target:$target, desc:$desc, session_key:$key,
             added_at:($now|tonumber), interval:($interval|tonumber), ttl:($ttl|tonumber),
             notify:$notify, persistent:($persistent=="1"), max_events:($max|tonumber),
             unknown_max:($umax|tonumber), when:$when, pattern:$pattern, size0:($size0|tonumber),
             state:"pending", detail:"registered, not yet probed", last_probe:0, unknown_streak:0,
             events:0, retired:false, retired_reason:"", retired_at:0}')
    _spec_write "$(_spec_path "$id")" "$spec" || die "add: cannot write spec"
    (( no_declare )) || _declare_wait "$id" "${desc:-$kind:$target}"
    printf 'added %s  %s:%s  interval=%ss notify=%s%s\n' "$id" "$kind" "$target" "$interval" "$notify" "$( (( persistent )) && printf ' persistent')"
    # A synchronous first probe so the caller sees what the dispatcher will
    # see — and so a subject that is ALREADY terminal is visible now rather
    # than on the first poll.
    if (( no_first_probe == 0 )); then
        local first; first=$(_probe "$kind" "$target" "$spec")
        printf 'first probe: %s\n' "$first"
    fi
    [[ "$kind" == pid ]] && printf 'note: a pid: subject cannot report an EXIT STATUS (the parent reaps it); for a status, launch via monitor/async-run.sh and watch asyncrun:<token>\n'
    local v; v=$(_ledger_verdict)
    case "${v%%|*}" in
        armed)
            printf 'dispatcher: ARMED — %s. The next poll (≤ %ss) picks this watch up; you will be woken by a task notification on its terminal state. It is safe to end your turn.\n' "${v#*|}" "$POLL_SECONDS"
            return 0 ;;
        muted)
            printf 'dispatcher: MUTED — %s\n' "${v#*|}"
            return 3 ;;
        disabled)
            printf 'dispatcher: NOT ARMED (disabled) — %s\n' "${v#*|}"
            printf 'THIS WATCH WILL NOT WAKE YOU: the dispatcher process is alive but NOT SERVING (the kill switch monitor.longjob.enabled / MONITOR_LONGJOB_ENABLED, or an unscoped launch). The watch is recorded and declared as an external wait.\n'
            _await_fallback "$id"
            return 3 ;;
        *)
            printf 'dispatcher: NOT ARMED (%s) — %s\n' "${v%%|*}" "${v#*|}"
            printf 'THIS WATCH WILL NOT WAKE YOU. It is recorded (and declared as an external wait, so the watcher'"'"'s orphan-async loop can resolve it later), but nothing in this session is polling the spool.\n'
            _await_fallback "$id"
            printf 'Then report the unarmed session: monitor/longjob-watch.sh status.\n'
            return 3 ;;
    esac
}

cmd_list() {
    _require_spool
    local f n=0
    printf '%-18s %-9s %-8s %-40s %s\n' ID STATE KIND TARGET DETAIL
    for f in "$SPOOL"/watches/*.json; do
        [[ -f "$f" ]] || continue
        n=$(( n + 1 ))
        jq -r '[.id, (if .retired then "retired:"+.retired_reason else .state end), .kind, (.target|.[0:40]), (.detail|.[0:80])] | @tsv' "$f" 2>/dev/null \
            | awk -F'\t' '{printf "%-18s %-9s %-8s %-40s %s\n",$1,$2,$3,$4,$5}'
    done
    printf -- '-- %s watch(es) in %s; dispatcher: %s\n' "$n" "$SPOOL" "$(_ledger_verdict)"
}

cmd_show()   { _require_spool; [[ -n "${1:-}" ]] || die "show: id required"; [[ -f "$(_spec_path "$1")" ]] || die "show: no such watch $1"; jq . "$(_spec_path "$1")"; }
cmd_rm()     { _require_spool; [[ -n "${1:-}" ]] || die "rm: id required"; [[ -f "$(_spec_path "$1")" ]] || die "rm: no such watch $1"; rm -f "$(_spec_path "$1")"; _undeclare_wait "$1"; printf 'removed %s\n' "$1"; }
cmd_events() { _require_spool; local n="${1:-20}"; [[ -f "$SPOOL/events.log" ]] || { printf '(no events)\n'; return 0; }; tail -n "$n" "$SPOOL/events.log"; }
cmd_unmute() { _require_spool; local l; l=$(_ledger_path); [[ -f "$l" ]] || die "unmute: no ledger"; touch "$SPOOL/unmute.flag"; printf 'unmute requested; the dispatcher clears its mute on the next poll (≤ %ss)\n' "$POLL_SECONDS"; }
cmd_reset()  { _require_spool; rm -rf "$SPOOL/watches"; mkdir -p "$SPOOL/watches"; : > "$SPOOL/events.log"; printf 'spool reset: %s\n' "$SPOOL"; }

# ledger-verdict <ledger-path> → "<armed|stale|dead|absent|muted>|<reason>"
# The ONE liveness reader (skeptic F2): pane-state.sh's kill-relevant discount
# calls THIS instead of re-deriving a weaker freshness test beside it, so the
# reader that authorizes a kill can never verify less than the one that
# merely reports. Read-only; no session key needed.
cmd_ledger_verdict() {
    local l="${1:-}"; shift || true
    _argloop_prev_5=-1; while (( $# )); do (( $# != _argloop_prev_5 )) || _argloop_stuck "$1"; _argloop_prev_5=$#
        case "$1" in --now) LJ_NOW_OVERRIDE="${2:-}"; [[ "$LJ_NOW_OVERRIDE" =~ ^[0-9]+$ ]] || die "ledger-verdict: --now must be an epoch"; shift 2 ;; *) die "ledger-verdict: unknown option $1" ;; esac
    done
    [[ -n "$l" ]] || die "ledger-verdict: path required"
    SPOOL="$(dirname "$l")"
    # `active=` is COUNTED from the spool here and now — the ledger's own
    # `active` is published only by a completed pass, and between an `add`
    # and the next write it still says 0, which read as `idle`, which is
    # kill-authorised, over a worker parked on a 4-hour job (skeptic C2).
    local f n=0
    for f in "$SPOOL"/watches/*.json; do [[ -f "$f" ]] || continue; [[ "$(jq -r 'if .retired == false then "live" else "x" end' "$f" 2>/dev/null)" == live ]] && n=$(( n + 1 )); done
    printf '%s|active=%s\n' "$(_ledger_verdict)" "$n"
}

cmd_status() {
    _require_spool
    local v; v=$(_ledger_verdict)
    local active=0 f
    for f in "$SPOOL"/watches/*.json; do [[ -f "$f" ]] || continue; [[ "$(jq -r .retired "$f" 2>/dev/null)" == "false" ]] && active=$(( active + 1 )); done
    printf 'session_key=%s spool=%s\n' "$SESSION_KEY" "$SPOOL"
    printf 'dispatcher=%s  %s\n' "${v%%|*}" "${v#*|}"
    printf 'active_watches=%s\n' "$active"
    # THE HOST'S OWN GATE, read from a file the emit path never touches. On
    # 2.1.272 plugin monitors are armed only when the GrowthBook rollout flag
    # `tengu_amber_sentinel` is served TRUE (default false); the value the
    # last first-party session cached is in the global config. `false` or
    # `absent` here means the host will not arm the dispatcher for anyone,
    # whatever the launcher passes — cc-version-sensitive (flag NAME from the
    # 2.1.272 binary), so a rename reads `absent`, never `true`.
    local gcfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.claude.json" flag
    flag=$(jq -r '.cachedGrowthBookFeatures.tengu_amber_sentinel // "absent"' "$gcfg" 2>/dev/null) || flag="unreadable"
    # The value's AGE comes from the adjacent cachedGrowthBookFeaturesAt (epoch
    # ms), never from the file's mtime: .claude.json is session state rewritten
    # constantly (measured: mtime 41 s while the cache was 855 s old), and the
    # cache is refreshed only by first-party sessions, so a `true` can outlive
    # the host's decision indefinitely. The age is what makes the value readable.
    local at age="unknown"
    at=$(jq -r '.cachedGrowthBookFeaturesAt // empty' "$gcfg" 2>/dev/null)
    [[ "$at" =~ ^[0-9]{10,}$ ]] && age="$(( $(_now) - at / 1000 ))s"
    printf 'host_rollout_flag tengu_amber_sentinel=%s age=%s (cached in %s; the host arms plugin monitors only when this is true — an old value is not a current one)\n' "$flag" "$age" "$gcfg"
    if [[ -f "$(_ledger_path)" ]]; then
        jq -r '"ledger: pid=\(.pid) service=\(.service) armed_at=\(.armed_at) last_poll=\(.last_poll) written=\(.written) (lines handed to the host — delivery is NOT observable from here: the host drops bursts above 10 batches/20 s and reports only a count) emit_failures=\(.emit_failures) muted=\(.muted) note=\(.note)"' "$(_ledger_path)" 2>/dev/null
    fi
    if [[ -s "$SPOOL/emit-failures.log" ]]; then
        printf 'EMIT FAILURES (%s lines, last 3):\n' "$(wc -l < "$SPOOL/emit-failures.log")"; tail -n 3 "$SPOOL/emit-failures.log"
    fi
    case "${v%%|*}" in armed) return 0 ;; *) return 3 ;; esac
}

# resolve <id> → "<class>|<detail>" in the orphan-async resolver's vocabulary
# (running | terminal | died | unresolvable). Never exits non-zero on a
# classification; only on usage.
cmd_resolve() {
    _require_spool
    [[ -n "${1:-}" ]] || die "resolve: id required"
    local p; p=$(_spec_path "$1")
    [[ -f "$p" ]] || { printf 'unresolvable|no such longjob watch %s in %s' "$1" "$SPOOL"; return 0; }
    local kind target spec out
    kind=$(_spec_get "$p" .kind); target=$(_spec_get "$p" .target); spec=$(cat "$p")
    # A watch retired for a TERMINAL reason is terminal. One retired for any
    # other reason (expired / unknown park / event cap) is exactly the case the
    # backstop exists for: probe the SUBJECT live rather than echo the park.
    if [[ "$(jq -r .retired "$p")" == "true" && "$(_spec_get "$p" .retired_reason)" == terminal ]]; then
        printf 'terminal|%s %s' "$(_spec_get "$p" .state)" "$(_spec_get "$p" .detail)"; return 0
    fi
    out=$(_probe "$kind" "$target" "$spec")
    # Say when the WATCH is dead even though the SUBJECT is alive: `running`
    # must never read as "you are still being watched" (skeptic, F3 wording).
    local wnote=""
    [[ "$(jq -r .retired "$p")" == "true" ]] && wnote="watch retired ($(_spec_get "$p" .retired_reason)) — NOT being watched; subject: "
    case "${out%%|*}" in
        pending|running) printf 'running|%s%s' "$wnote" "${out#*|}" ;;
        done|failed)     printf 'terminal|%s%s %s' "$wnote" "${out%%|*}" "${out#*|}" ;;
        *)               printf 'unresolvable|%s%s' "$wnote" "${out#*|}" ;;
    esac
}

cmd_probe() {
    local subject="${1:-}"; shift || true
    [[ "$subject" == *:* ]] || die "probe: <kind>:<target> required"
    local kind="${subject%%:*}" target="${subject#*:}" when="" pattern="" size0=0
    _argloop_prev_2=-1; while (( $# )); do (( $# != _argloop_prev_2 )) || _argloop_stuck "$1"; _argloop_prev_2=$#
        case "$1" in --when) when="${2:-}"; shift 2 ;; --pattern) pattern="${2:-}"; shift 2 ;; --size0) size0="${2:-}"; shift 2 ;; *) die "probe: unknown option $1" ;; esac
    done
    local spec; spec=$(jq -n --arg when "${when:-exists}" --arg pattern "$pattern" --arg size0 "$size0" '{when:$when, pattern:$pattern, size0:($size0|tonumber)}')
    _probe "$kind" "$target" "$spec"; printf '\n'
}

# await <id> [--timeout S] — the FALLBACK wake for an unarmed session, meant
# for `run_in_background`. Probes the subject itself (it does not depend on
# the dispatcher), so it works with no ledger at all.
cmd_await() {
    _require_spool
    local id="${1:-}"; shift || true
    [[ -n "$id" ]] || die "await: id required"
    local timeout_s="$AWAIT_DEFAULT_S"
    _argloop_prev_3=-1; while (( $# )); do (( $# != _argloop_prev_3 )) || _argloop_stuck "$1"; _argloop_prev_3=$#
        case "$1" in --timeout) timeout_s="${2:-}"; shift 2 ;; *) die "await: unknown option $1" ;; esac
    done
    [[ "$timeout_s" =~ ^[0-9]+$ ]] || die "await: --timeout must be an integer"
    (( timeout_s <= AWAIT_MAX_S )) || die "await: --timeout $timeout_s exceeds ${AWAIT_MAX_S}s, the longest wait one run_in_background Bash call can hold (ceiling ${BG_CEIL_S}s less ${BG_SLACK_S}s slack; your-org/nexus-code#1685) — the harness would STOP it with no verdict. Use --timeout <= $AWAIT_MAX_S with Bash timeout: $(( BG_CEIL_S * 1000 )) and re-enter on rc 4, or leave the job to an ARMED ng longjob watch."
    local p; p=$(_spec_path "$id"); [[ -f "$p" ]] || die "await: no such watch $id"
    local kind target spec interval deadline out state streak=0 umax
    kind=$(_spec_get "$p" .kind); target=$(_spec_get "$p" .target); interval=$(_spec_get "$p" .interval); umax=$(_spec_get "$p" .unknown_max)
    [[ "$interval" =~ ^[0-9]+$ ]] || interval="$DEFAULT_INTERVAL"; [[ "$umax" =~ ^[0-9]+$ ]] || umax="$UNKNOWN_MAX"
    deadline=$(( $(_now) + timeout_s ))
    while :; do
        [[ -f "$p" ]] || { printf 'await: watch %s was removed\n' "$id"; return 3; }
        if [[ "$(jq -r .retired "$p")" == "true" ]]; then
            state=$(_spec_get "$p" .state)
            printf 'await: %s retired (%s): %s %s\n' "$id" "$(_spec_get "$p" .retired_reason)" "$state" "$(_spec_get "$p" .detail)"
            case "$state" in done) return 0 ;; failed) return 1 ;; *) return 3 ;; esac
        fi
        spec=$(cat "$p"); out=$(_probe "$kind" "$target" "$spec"); state="${out%%|*}"
        case "$state" in
            done)   printf 'await: %s done — %s\n' "$id" "${out#*|}"; return 0 ;;
            failed) printf 'await: %s FAILED — %s\n' "$id" "${out#*|}"; return 1 ;;
            unknown) streak=$(( streak + 1 )); if (( streak >= umax )); then printf 'await: %s UNKNOWN after %s probes — %s\n' "$id" "$streak" "${out#*|}"; return 3; fi ;;
            *) streak=0 ;;
        esac
        (( $(_now) >= deadline )) && { printf 'await: TIMEOUT after %ss; last: %s\n' "$timeout_s" "$out"; return 4; }
        # Never sleep past the deadline: the Bash `timeout` printed by
        # _await_fallback leaves slack for one probe, not for a whole interval.
        local left=$(( deadline - $(_now) ))
        if (( left < interval )); then sleep "$left"; else sleep "$interval"; fi
    done
}

# run [--desc D] [--id ID] [--notify …] [--interval S] -- <cmd…>
#
# THE ONE-LINER for a long LOCAL command (a 40-minute test suite, a
# multi-hour Python script): launch it through monitor/async-run.sh — the
# launcher that RETAINS the exit status — and watch its token in one step, so
# nothing has to be remembered between "start it" and "be told when it ends".
# async-run.sh's own output (token, status path) is passed through; the watch
# id defaults to the token so `show`/`await`/`rm` need no second lookup.
cmd_run() {
    _require_spool
    local desc="" id="" extra=() ar="$_lj_dir/async-run.sh"
    _argloop_prev_4=-1; while (( $# )); do (( $# != _argloop_prev_4 )) || _argloop_stuck "$1"; _argloop_prev_4=$#
        case "$1" in
            --desc) desc="${2:-}"; shift 2 ;;
            --id) id="${2:-}"; shift 2 ;;
            --notify|--interval|--ttl|--max-events|--unknown-max) extra+=("$1" "${2:-}"); shift 2 ;;
            --) shift; break ;;
            --*) die "run: unknown option $1 (options go before --, the command after)" ;;
            *) break ;;
        esac
    done
    (( $# )) || die "run: a command is required after --"
    [[ -x "$ar" ]] || die "run: $ar not found"
    [[ -n "$desc" ]] || desc="$*"
    local out rc token
    out=$("$ar" --desc "$desc" -- "$@" 2>&1); rc=$?
    printf '%s\n' "$out"
    (( rc == 0 )) || die "run: async-run.sh failed (rc $rc); nothing to watch" "$rc"
    token=$(printf '%s\n' "$out" | sed -n 's/^async-run: launched token=\([^ ]*\).*/\1/p'); token="${token%%$'\n'*}"
    [[ -n "$token" ]] || die "run: could not read the token from async-run.sh's output — the job IS running (see above) but no watch was added; add one by hand: longjob-watch.sh add asyncrun:<token>"
    cmd_add "asyncrun:$token" --desc "$desc" --id "${id:-$token}" "${extra[@]}"
}

# ---- the dispatcher ---------------------------------------------------------------
# THE HOST'S RATE LIMITER IS INVISIBLE FROM HERE (skeptic F1). On 2.1.272 the
# monitor's stdout goes through a token bucket of capacity 10 refilling one
# token per 2000 ms, consumed per 200 ms batch; a batch that finds it empty is
# DISCARDED and only a "suppressed N events" count is delivered later. printf
# still returns 0, so no record on this side can see the loss. The one defence
# is to never present the host with a burst: emits are PACED at
# EMIT_MIN_GAP_MS apart (default 2500 > the 2000 ms refill), so the bucket can
# never drain however many watches go terminal in one pass. The cost is
# latency (N events take ~2.5·N s), never content.
EMIT_MIN_GAP_MS=$(_cfg MONITOR_LONGJOB_EMIT_MIN_GAP_MS monitor.longjob.emit_min_gap_ms 2500)
LAST_EMIT_MS=0
_now_ms() {   # `date +%s%3N` returns rc 0 with a LITERAL on a date without %N — validate the shape, never the rc (skeptic D5)
    local ms; ms=$(date +%s%3N 2>/dev/null)
    [[ "$ms" =~ ^[0-9]{13}$ ]] && printf '%s' "$ms" || printf '%s000' "$(_now)"
}
_emit() {   # <line> → 0 printed, 1 write failed (recorded)
    local now_ms gap
    now_ms=$(_now_ms); gap=$(( now_ms - LAST_EMIT_MS ))
    if (( LAST_EMIT_MS > 0 && gap < EMIT_MIN_GAP_MS )); then
        # Pacing makes a pass LONG, and the ledger is written between passes —
        # so a healthy dispatcher mid-burst read `stale` and a fresh `add` was
        # told NOT ARMED (skeptic D1). Touch the ledger's liveness before every
        # paced wait; the counters are the pass's running values, which is
        # what a reader at that moment should see.
        _ledger_write "ok (mid-pass, paced emit)" || true
        sleep "$(awk -v ms=$(( EMIT_MIN_GAP_MS - gap )) 'BEGIN{printf "%.3f", ms/1000}')"
    fi
    LAST_EMIT_MS=$(_now_ms)
    if printf '%s\n' "$1" 2>>"$SPOOL/emit-failures.log"; then return 0; fi
    printf '%s\tEMIT-FAILED\t%s\n' "$(_now)" "$1" >> "$SPOOL/emit-failures.log" 2>/dev/null
    return 1
}
# THE HOST TRUNCATES A LINE AT 500 CHARS (bVe=500 on 2.1.272, skeptic F4), and
# the tail is where the action clause and the record pointer used to live. So
# a line is composed HEAD-FIRST — state, id, subject, the record pointer, the
# clause — and the DETAIL is what gets trimmed to fit LINE_MAX (480, under the
# host's cap with margin). Nothing that tells the agent what to DO is ever
# past the cut.
LINE_MAX=480
_compose_line() {   # <STATE> <id> <kind:target> <clause> <detail> <desc>
    # Every element of the head is BOUNDED (skeptic D3: an unbounded `cmd:`
    # target grew the line to 1232 chars and the clamp below was no bound):
    # subject ≤ 100, clause ≤ 120, desc ≤ 120. The ID IS NOT BOUNDED HERE and
    # appears TWICE (the state word's id and the record pointer), at up to 64
    # chars each, so the worst head is ~548 chars, not the "~390" this comment
    # used to claim (bundle-2609sk2 N2, measured: with a 64-char id the line is
    # cut inside the desc and carries no detail). What holds in EVERY case is
    # the order and the final hard cap: state, id, the record pointer, the
    # subject and the action clause all end by char ~419, under LINE_MAX, so
    # nothing that tells the agent what to DO is ever past the cut; with an
    # ordinary id the detail keeps ≥ 90 chars.
    #
    # desc was 60 (bundle-2609 soak, 2026-09-16): async-run.sh's own advice is
    # "if your payload writes its own logs, TELL THE READER WHERE: pass the
    # path in --desc", and at 60 the path — at the END of a sentence-shaped
    # desc — was cut off on 5 of 5 wakes. 120 holds a sentence plus a path
    # and still leaves the detail ≥ 90 chars under LINE_MAX.
    local subj="$3" clause="$4" dsc="$6"
    # ONE wake is ONE line (bundle-2609sk2 N1): a newline in the desc split the
    # wake in two and the second line arrived UNPREFIXED — free text that can
    # spell `longjob-watch: DONE …` for a job that never ran. `ng longjob run`
    # defaults the desc to the command, so a multi-line `bash -c` payload did
    # this unprompted. Same for the subject and the clause.
    dsc="${dsc//$'\n'/ }"; dsc="${dsc//$'\r'/ }"
    subj="${subj//$'\n'/ }"; subj="${subj//$'\r'/ }"
    clause="${clause//$'\n'/ }"; clause="${clause//$'\r'/ }"
    (( ${#subj} > 100 )) && subj="${subj:0:99}…"
    (( ${#clause} > 120 )) && clause="${clause:0:119}…"
    (( ${#dsc} > 120 )) && dsc="${dsc:0:119}…"
    local head="longjob-watch: $1 $2 | record: monitor/longjob-watch.sh show $2 | $subj"
    # AN ALERT GOES FIRST (ncbundle4sk on #1635). A probe whose detail begins
    # `!! ` (after cmd.sh's `rc=N ` prefix) is saying "act on this", and at the
    # tail of a line whose state word is DONE it read as a success ~250 chars
    # in. So the alert text leads the line, bounded to 160 chars, and the state,
    # id and record pointer follow it.
    local _alert="$5"
    [[ "$_alert" =~ ^(rc=[0-9]+\ )?'!! '(.*)$ ]] && _alert="${BASH_REMATCH[2]}" || _alert=""
    if [[ -n "$_alert" ]]; then
        _alert="${_alert//$'\n'/ }"; _alert="${_alert//$'\r'/ }"
        (( ${#_alert} > 160 )) && _alert="${_alert:0:159}…"
        local _al="longjob-watch: $_alert | $1 $2 | record: monitor/longjob-watch.sh show $2 | $subj"
        [[ -n "$clause" ]] && _al="$_al | $clause"
        (( ${#_al} > LINE_MAX )) && _al="${_al:0:$(( LINE_MAX - 1 ))}…"
        printf '%s' "$_al"
        return 0
    fi
    [[ -n "$clause" ]] && head="$head | $clause"
    [[ -n "$dsc" ]] && head="$head [desc: $dsc]"
    local room=$(( LINE_MAX - ${#head} - 3 )) detail="$5" line
    # async-run's NO-OUTPUT-CAPTURED caveat is 316 chars of explanation that
    # belongs to `--status`; on this line it was trimmed mid-sentence on
    # every payload that logs to a file — the common, well-behaved shape
    # (bundle-2609 soak: 5 of 5 wakes) — while its CONDITION was right (one of
    # the five was rc 0 from a trailing echo around a red probe). Keep the
    # greppable marker and the instruction; the full text stays in the record
    # and in events.log (`show <id>`). Only the settled-with-rc form is
    # shortened: the cancelled/died form is short already and says something
    # different (no rc to qualify).
    case "$detail" in
        *'NO-OUTPUT-CAPTURED: the job wrote NOTHING'*)
            detail="${detail%%NO-OUTPUT-CAPTURED: the job wrote NOTHING*}NO-OUTPUT-CAPTURED (this rc is UNCORROBORATED by any captured stream — read the payload's own log, named in desc; full text: show $2)" ;;
    esac
    (( room < 20 )) && room=20
    (( ${#detail} > room )) && detail="${detail:0:$(( room - 1 ))}…"
    line="$head — $detail"
    (( ${#line} > LINE_MAX )) && line="${line:0:$(( LINE_MAX - 1 ))}…"
    printf '%s' "$line"
}
# events.log third column — a WORD, never a boolean, because the one thing
# this side cannot observe is delivery: `written` means printf returned 0 and
# the host MAY have dropped the batch (its rate limiter keeps only a count);
# `write-failed` means printf failed (recorded in emit-failures.log); `muted`
# and `capped` mean this side chose not to print; `not-printed` means the
# transition was tracked and no line was due. No value here says "delivered".
_log_event() { printf '%s\t%s\t%s\t%s\t%s\n' "$(_now)" "$1" "$2" "$3" "${4//$'\n'/ }" >> "$SPOOL/events.log" 2>/dev/null; }

# One pass over the spool. Globals it advances: EMITTED, EMIT_FAILURES, MUTED.
_poll_once() {
    local f id kind target spec state prev detail now last interval persistent notify events maxev ttl added umax streak
    local active=0 retired=0 out new_state line printed resolve pre mine cur
    now=$(_now)
    # `unmute` grants a FRESH budget of session_max_events; without the
    # reset the very next event would re-trip the cap (measured: a second
    # MUTED line and nothing else).
    [[ -f "$SPOOL/unmute.flag" ]] && { MUTED=0; EMITTED=0; rm -f "$SPOOL/unmute.flag"; _log_event dispatcher unmute not-printed "unmute flag consumed; session event budget reset"; }
    # Agent-added watches are polled (and therefore emitted) BEFORE the launch
    # hook's `auto-*` ones, so a session budget is never spent by machine-made
    # watches ahead of the one the agent deliberately asked for (skeptic F7).
    local -a files=() autos=()
    for f in "$SPOOL"/watches/*.json; do
        [[ -f "$f" ]] || continue
        case "${f##*/}" in auto-*) autos+=("$f") ;; *) files+=("$f") ;; esac
    done
    files+=("${autos[@]}")
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        spec=$(cat "$f" 2>/dev/null) || continue
        # `//` in jq treats false as ABSENT, so `.retired // "true"` reads a live
        # watch as retired (measured on the first smoke test: 2 retired, 0 polled).
        if [[ "$(printf '%s' "$spec" | jq -r 'if .retired == false then "false" else "true" end' 2>/dev/null)" == "true" ]]; then retired=$(( retired + 1 )); continue; fi
        active=$(( active + 1 ))
        id=$(printf '%s' "$spec" | jq -r .id); kind=$(printf '%s' "$spec" | jq -r .kind); target=$(printf '%s' "$spec" | jq -r .target)
        prev=$(printf '%s' "$spec" | jq -r .state); last=$(printf '%s' "$spec" | jq -r '.last_probe // 0')
        interval=$(printf '%s' "$spec" | jq -r '.interval // 60'); persistent=$(printf '%s' "$spec" | jq -r '.persistent // false')
        notify=$(printf '%s' "$spec" | jq -r '.notify // "terminal"'); events=$(printf '%s' "$spec" | jq -r '.events // 0')
        maxev=$(printf '%s' "$spec" | jq -r '.max_events // 8'); ttl=$(printf '%s' "$spec" | jq -r '.ttl // 604800')
        added=$(printf '%s' "$spec" | jq -r '.added_at // 0'); umax=$(printf '%s' "$spec" | jq -r '.unknown_max // 5')
        streak=$(printf '%s' "$spec" | jq -r '.unknown_streak // 0')
        [[ "$id" == "$(basename "$f" .json)" ]] || { _log_event "$(basename "$f" .json)" corrupt not-printed "id mismatch in spec; skipped"; continue; }
        # Validate every numeric BEFORE the first (( )): a non-numeric value in a
        # spec is a bash-FATAL unbound-variable error inside arithmetic, which
        # no rc check can catch (skeptic F6). A bad field falls back to its
        # default and is logged, never trusted.
        local _bad=""
        [[ "$last" =~ ^[0-9]+$ ]] || { last=0; _bad="$_bad last_probe"; }
        [[ "$interval" =~ ^[0-9]+$ ]] || { interval="$DEFAULT_INTERVAL"; _bad="$_bad interval"; }
        [[ "$events" =~ ^[0-9]+$ ]] || { events=0; _bad="$_bad events"; }
        [[ "$maxev" =~ ^[0-9]+$ ]] || { maxev="$WATCH_MAX_EVENTS"; _bad="$_bad max_events"; }
        [[ "$ttl" =~ ^[0-9]+$ ]] || { ttl="$TTL_SECONDS"; _bad="$_bad ttl"; }
        [[ "$added" =~ ^[0-9]+$ ]] || { added="$now"; _bad="$_bad added_at"; }
        [[ "$umax" =~ ^[0-9]+$ ]] || { umax="$UNKNOWN_MAX"; _bad="$_bad unknown_max"; }
        [[ "$streak" =~ ^[0-9]+$ ]] || { streak=0; _bad="$_bad unknown_streak"; }
        [[ -n "$_bad" ]] && _log_event "$id" corrupt not-printed "non-numeric field(s):$_bad — defaults used"
        (( now - last < interval )) && continue
        # ON-TIME HEARTBEAT (R1): a probe can block for probe_timeout_seconds
        # and a pass of them emits nothing; touch the ledger before a probe
        # whenever poll_seconds have elapsed since the last write.
        if (( $(_now) - LAST_LEDGER_WRITE >= POLL_SECONDS )); then
            _ledger_write "ok (mid-pass, before a probe)" || true
        fi

        new_state=""; detail=""; line=""; printed=not-printed; resolve=0; pre=""; mine=""
        if (( ttl > 0 && now - added > ttl )); then
            pre=$(cat "$f" 2>/dev/null)
            new_state=failed; detail="watch EXPIRED after ${ttl}s without a terminal state (TTL); the subject may still be running — re-add to keep watching"
            _retire "$f" "$id" expired "$new_state" "$detail" "$now"; retired=$(( retired + 1 )); active=$(( active - 1 ))
            line=$(_compose_line EXPIRED "$id" "$kind:$target" "TTL reached; the wait stays declared — re-add to keep watching" "$detail" "$(printf '%s' "$spec" | jq -r '.desc // empty')")
        else
            out=$(_probe "$kind" "$target" "$spec"); new_state="${out%%|*}"; detail="${out#*|}"
            # `pre` is the spec as it stands AFTER the probe and BEFORE this
            # pass writes it — see the write-failed restore below for why the
            # restore must use this and not `spec` (read before the probe).
            pre=$(cat "$f" 2>/dev/null)
            if [[ "$new_state" == unknown ]]; then
                streak=$(( streak + 1 ))
                if (( streak >= umax )); then
                    _retire "$f" "$id" unknown unknown "$detail" "$now"; retired=$(( retired + 1 )); active=$(( active - 1 ))
                    line=$(_compose_line UNKNOWN "$id" "$kind:$target" "PARKED after $streak consecutive unknown probes (not probed again): check the subject yourself, then re-add or rm" "$detail" "$(printf '%s' "$spec" | jq -r '.desc // empty')")
                    streak=0
                else
                    _update "$f" "$new_state" "$detail" "$now" "$streak" 0
                fi
            else
                streak=0
                case "$new_state" in
                    done|failed)
                        if [[ "$persistent" == "true" ]]; then
                            _update "$f" "$new_state" "$detail" "$now" 0 0
                            [[ "$new_state" != "$prev" ]] && line=$(_compose_line "${new_state^^}" "$id" "$kind:$target" "persistent: $prev → $new_state" "$detail" "$(printf '%s' "$spec" | jq -r '.desc // empty')")
                        else
                            _retire "$f" "$id" terminal "$new_state" "$detail" "$now"; retired=$(( retired + 1 )); active=$(( active - 1 ))
                            resolve=1
                            line=$(_compose_line "${new_state^^}" "$id" "$kind:$target" "" "$detail" "$(printf '%s' "$spec" | jq -r '.desc // empty')")
                        fi ;;
                    pending|running)
                        _update "$f" "$new_state" "$detail" "$now" 0 0
                        # A persistent watch announces the RECOVERY from either
                        # non-running state: `failed`, and `done`, which the
                        # watcher supervisor answers while LATCHED (ncbundle4sk
                        # on #1635: latched → UP was silent).
                        if [[ "$new_state" != "$prev" ]] && { [[ "$notify" == transitions ]] || { [[ "$persistent" == "true" && ( "$prev" == failed || "$prev" == done ) ]]; }; }; then
                            line=$(_compose_line "${new_state^^}" "$id" "$kind:$target" "transition $prev → $new_state" "$detail" "$(printf '%s' "$spec" | jq -r '.desc // empty')")
                        fi ;;
                esac
            fi
        fi
        [[ -n "$line" ]] || { (( resolve )) && _resolve_waits "$id" "$kind" "$target"; continue; }
        # Caps, then print. A capped or muted line is NOT printed ON PURPOSE, so
        # its terminal wait resolves as it always did; only a FAILED write
        # (below) keeps it.
        if (( events >= maxev )); then
            _log_event "$id" "$new_state" capped "watch event cap $maxev reached — $detail"
            _retire "$f" "$id" "event-cap" "$new_state" "$detail" "$now"
            (( resolve )) && _resolve_waits "$id" "$kind" "$target"
            continue
        fi
        if (( MUTED )); then _log_event "$id" "$new_state" muted "$detail"; (( resolve )) && _resolve_waits "$id" "$kind" "$target"; continue; fi
        if (( EMITTED >= SESSION_MAX_EVENTS )); then
            MUTED=1
            # The event that TRIPPED the cap is itself undelivered: log it as
            # MUTED so events.log holds every transition, printed or not.
            _log_event "$id" "$new_state" muted "$detail"
            (( resolve )) && _resolve_waits "$id" "$kind" "$target"
            _log_event dispatcher muted not-printed "session event cap $SESSION_MAX_EVENTS reached"
            _emit "longjob-watch: MUTED — this session's event cap ($SESSION_MAX_EVENTS) is reached; further transitions are logged to $SPOOL/events.log but NOT delivered. Run monitor/longjob-watch.sh unmute to resume." || { EMIT_FAILURES=$(( EMIT_FAILURES + 1 )); STDOUT_CLOSED=1; }
            EMITTED=$(( EMITTED + 1 ))
            (( STDOUT_CLOSED )) && break
            continue
        fi
        mine=$(cat "$f" 2>/dev/null)
        if _emit "$line"; then printed=written; EMITTED=$(( EMITTED + 1 ))
        else printed=write-failed; EMIT_FAILURES=$(( EMIT_FAILURES + 1 )); fi
        _log_event "$id" "$new_state" "$printed" "$detail"
        if [[ "$printed" == write-failed ]]; then
            # A FAILED WRITE IS NOT A DELIVERY (your-org/nexus-code#1623). The
            # line went nowhere — measured on lsc2, 7 terminal wakes into a pipe
            # whose claude was dead — so the watch must not stay retired as if
            # it had been told. Restore the spec EXACTLY as this pass read it
            # (un-retired, the previous state, the old last_probe, so the next
            # pass by ANY dispatcher probes it at once and prints it again), and
            # leave its waits declared (resolve is skipped). And then STOP: a
            # write to the host's pipe fails only when its reader is gone, so
            # every later line from this process would fail too — retrying here
            # is the forever-loop, and retiring the next watch would lose it.
            # _poll_once's caller marks the spool released (service
            # stdout-closed) so a live dispatcher arms at once; this one never
            # re-delivers anything, and nothing that was WRITTEN is restored.
            #
            # …AND THE RESTORE UNDOES ONLY THIS PASS'S OWN WRITE (skeptic item
            # 3 on the #1623 bundle). `spec` was read BEFORE the probe, and a
            # probe takes up to probe_timeout_seconds — long enough for a NEWER
            # dispatcher to supersede this one (#1623), probe the same watch,
            # retire it and DELIVER it. Restoring `spec` then un-retired a
            # delivered watch and the newer dispatcher printed it AGAIN
            # (measured: two `DONE w1` at d110c584, test-longjob-watch #1623e).
            # So the restore writes back `pre` — the file as it stood after the
            # probe, immediately before this pass's own _retire/_update — and
            # only while the file still holds exactly what this pass wrote
            # (`mine`). A retirement another dispatcher made mid-probe is
            # therefore put BACK, not erased; a live watch (the single-
            # dispatcher case: pre == spec) comes back un-retired as before; a
            # write by anyone AFTER ours, or a watch `rm`'d meanwhile, is left
            # alone. Not keyed on ledger ownership: a newer owner that has not
            # yet probed this watch would then never see it — a silent drop,
            # the direction this restore exists to close.
            # BOUNDARY: no flock (the spool is on NFS), so this is a compare
            # then an atomic rename, not a compare-and-swap. The residual
            # windows are the few ms between the `pre` read and our write and
            # between the `cur` read and the restore — not the probe's seconds.
            cur=$(cat "$f" 2>/dev/null)
            if [[ -n "$pre" && -n "$cur" && "$cur" == "$mine" ]]; then
                _spec_write "$f" "$pre" || _log_event "$id" "$new_state" not-printed "write-failed AND the restore write failed: the spec may read retired over an undelivered line (#1623)"
                if [[ "$(printf '%s' "$pre" | jq -r '.retired' 2>/dev/null)" == true ]]; then
                    _log_event "$id" "$new_state" not-printed "write-failed; NOT restored un-retired: another dispatcher retired it during this probe — its retirement is put back (#1623)"
                else
                    _log_event "$id" "$new_state" not-printed "restored un-retired after write-failed: a live dispatcher will deliver it (#1623)"
                fi
            else
                _log_event "$id" "$new_state" not-printed "write-failed; NOT restored: the spec was changed or removed by another writer after this pass wrote it (#1623)"
            fi
            STDOUT_CLOSED=1
            break
        fi
        (( resolve )) && _resolve_waits "$id" "$kind" "$target"
        _bump_events "$f"
    done
    ACTIVE="$active"; RETIRED="$retired"
}
_update() {   # <file> <state> <detail> <now> <streak> <_unused>
    local j; j=$(jq --arg s "$2" --arg d "$3" --arg n "$4" --arg k "$5" '.state=$s | .detail=$d | .last_probe=($n|tonumber) | .unknown_streak=($k|tonumber)' "$1" 2>/dev/null) && _spec_write "$1" "$j"
}
_retire() {   # <file> <id> <reason> <state> <detail> <now>   (the spec only; waits: _resolve_waits)
    local j
    j=$(jq --arg r "$3" --arg s "$4" --arg d "$5" --arg n "$6" '.retired=true | .retired_reason=$r | .state=$s | .detail=$d | .last_probe=($n|tonumber) | .retired_at=($n|tonumber)' "$1" 2>/dev/null) && _spec_write "$1" "$j"
    return 0
}
# _resolve_waits <id> <kind> <target> — the external-wait side of a TERMINAL
# retirement, split out of _retire (your-org/nexus-code#1623) because it must
# happen only once the line has been HANDED OVER (or deliberately not printed:
# muted, capped). A terminal line whose write FAILED is restored un-retired
# for a live dispatcher to deliver, and a wait resolved before that would
# leave the session reading "nothing outstanding" over a result it never got.
_resolve_waits() {
    local kind="$2" target="$3"
    # ONLY a TERMINAL retirement resolves the external wait. An `expired` watch
    # says itself "the subject may still be running", an `unknown` park could
    # not tell, and `event-cap` is a budget, not a verdict — for those the wait
    # STAYS declared, so the session reads `idle-orphan-async` and the watcher's
    # orphan-async loop still has something to resolve (skeptic F3).
    _undeclare_wait "$1"
    # The launch hook (hooks/async-launch-detect.sh) declares its OWN wait for
    # a detected sbatch/srun/async-run — `slurm <jobid>` / `asyncrun <token>`.
    # The subject is terminal and the agent has been told, so that wait is
    # resolved too; leaving it would read `idle-orphan-async` for a job the
    # worker already heard about. Best-effort, and only for the kinds the
    # hook produces (a `pid:` or `file:` watch has no hook twin).
    case "$kind" in
        slurm)    [[ -n "$WINDOW_NAME" && -x "$_lj_dir/declare-wait.sh" ]] && for k in slurm slurm-srun-async; do NEXUS_WORKER_WINDOW="$WINDOW_NAME" NEXUS_STATE_DIR="$STATE_DIR" "$_lj_dir/declare-wait.sh" --remove "$k" "$target" >/dev/null 2>&1 || true; done ;;
        asyncrun) [[ -n "$WINDOW_NAME" && -x "$_lj_dir/declare-wait.sh" ]] && NEXUS_WORKER_WINDOW="$WINDOW_NAME" NEXUS_STATE_DIR="$STATE_DIR" "$_lj_dir/declare-wait.sh" --remove asyncrun "$target" >/dev/null 2>&1 || true ;;
    esac
    return 0
}
_bump_events() { local j; j=$(jq '.events=((.events // 0)+1)' "$1" 2>/dev/null) && _spec_write "$1" "$j"; }

cmd_dispatch() {
    # No arguments, ever: the plugin execs `longjob-watch.sh dispatch` bare,
    # and a dispatcher that accepted-and-ignored a stray token ran FOREVER
    # under the `ng` flag-order sweep (test-ng-flag-order.sh probes every
    # sub-verb with a flag it does not own and waits for it to exit —
    # 2400 s ceiling reached, bundle-2609). Refuse at once, rc 2.
    (( $# == 0 )) || die "dispatch: takes no arguments (got: $*)"
    # BORN_TICKS — the FIRST thing a dispatcher does, before it forks anything
    # that lives (your-org/nexus-code#1565 — KILL DIRECTION).
    #
    # `zsh -c 'sleep 600 & exec bash longjob-watch.sh dispatch'` makes the
    # `sleep 600` THIS process's child: `exec` keeps the pid, so work forked
    # before it is re-parented under the dispatcher, and pane-state.sh — which
    # excludes the dispatcher's root from the background-shell census WHOLE —
    # read `state=idle` over it (measured: idle, bk_pane_kill_authorized rc 0,
    # three reads, real `dispatch`). The census cannot tell such a child from
    # the per-poll `sleep` by NAME, and it cannot tell it by the ledger's
    # `pid_start` either: `exec` keeps the START TICKS too, so a pre-exec child
    # is YOUNGER than `pid_start` (measured: parent 1051329988, its pre-exec
    # child 1051330058), exactly like every child the dispatcher forks itself.
    # What does separate them is the moment this process BECAME a dispatcher.
    # That moment is recorded here as the start ticks of a process forked NOW
    # (`cat`, reading its own /proc/self/stat): everything forked before the
    # `exec` is older than it, everything the poll loop forks is younger.
    # EMPTY when /proc cannot be read — and an empty marker is a ledger the
    # census reads as it did before this field existed, never as a clearance.
    local _bt; _bt=$(cat /proc/self/stat 2>/dev/null) || _bt=""
    _bt="${_bt##*) }"
    # shellcheck disable=SC2086
    set -- $_bt; DISPATCH_BORN_TICKS="${20-}"; set --
    [[ "$DISPATCH_BORN_TICKS" =~ ^[0-9]+$ ]] || DISPATCH_BORN_TICKS=""
    # A closed stdout must not kill the loop: ignore SIGPIPE and let printf's
    # rc carry the failure into the ledger instead.
    trap '' PIPE
    local armed_at pid ps note="" enabled
    armed_at=$(_now); pid=$$; ps=$(_pid_start "$pid")
    DISPATCH_PID="$pid"; DISPATCH_PS="$ps"; ARMED_AT="$armed_at"   # the ledger writer reads these
    EMITTED=0; EMIT_FAILURES=0; MUTED=0; ACTIVE=0; RETIRED=0; SERVICE=unscoped; LAST_LEDGER_WRITE=0; STDOUT_CLOSED=0
    # THE OWNER, captured ONCE, here (your-org/nexus-code#1623): the nearest
    # `claude` above this process, as pid + start ticks. Recorded in the ledger
    # (owner_pid / owner_start) and checked at the top of every loop below —
    # this process exits when that claude is gone. Empty when there is none
    # (hermetic tests, CI): then nothing here ever exits on this ground.
    local _own; _own=$(_find_owner "$$")
    OWNER_PID=""; OWNER_PS=""
    [[ -n "$_own" ]] && { OWNER_PID="${_own% *}"; OWNER_PS="${_own#* }"; }

    enabled="${MONITOR_LONGJOB_ENABLED:-}"
    [[ -z "$enabled" && -x "$NEXUS_ROOT/config/load.sh" ]] && enabled=$("$NEXUS_ROOT/config/load.sh" monitor.longjob.enabled true 2>/dev/null || echo true)
    # An ABSENT answer (no config/load.sh, an empty value) is ENABLED. The
    # first cut read "" as disabled, so a tree with no config — every
    # hermetic fixture root — armed a dispatcher that polled nothing and
    # said so only in a ledger note nobody reads. The kill switch is an
    # explicit false, never an absence.
    enabled="${enabled:-true}"
    if [[ -z "$SPOOL" ]]; then
        # Unscoped: nothing to poll and nowhere to write a ledger. Stay alive
        # (an exit would be a delivered failure notice) and say why, once.
        printf 'longjob-watch dispatch: no session key (CLAUDE_CODE_SESSION_ID / NEXUS_WORKER_WINDOW unset) — running unscoped, polling nothing\n' >&2
        while :; do sleep "$POLL_SECONDS"; _owner_exit_if_gone; done
    fi
    if ! mkdir -p "$SPOOL/watches" 2>/dev/null; then
        printf 'longjob-watch dispatch: cannot create %s — staying alive, polling nothing\n' "$SPOOL" >&2
        while :; do sleep "$POLL_SECONDS"; _owner_exit_if_gone; done
    fi
    # ONE WRITER (#1544): before ANY branch below writes the ledger — the kill
    # switch and the config refusal write one too.
    _dispatch_wait_for_ledger
    case "$enabled" in 1|true|yes|on) ;; *)
        # ALIVE BUT NOT SERVING — said in the service FIELD, which the verdict
        # reads, not only in the note, which nothing reads (skeptic C1).
        SERVICE=disabled
        note="DISABLED by monitor.longjob.enabled / MONITOR_LONGJOB_ENABLED=$enabled; ledger written, spool NOT polled"
        while :; do _owner_exit_if_gone; _ledger_write "$note"; sleep "$POLL_SECONDS"; done ;;
    esac
    # The relation guard on the contract's own bound (see the header): a probe
    # timeout that can outlast the freshness window would make a healthy
    # dispatcher read stale. Refusing is a delivered failure notice — which is
    # why the check is against the CONFIG, before anything is armed.
    if (( PROBE_TIMEOUT > 2 * POLL_SECONDS + 30 )); then
        printf 'longjob-watch dispatch: probe_timeout_seconds (%s) exceeds 2×poll_seconds+30 (%s): a slow pass would read stale — fix the config; staying alive polling NOTHING\n' "$PROBE_TIMEOUT" "$(( 2 * POLL_SECONDS + 30 ))" >&2
        SERVICE=disabled
        while :; do _owner_exit_if_gone; _ledger_write "config: probe_timeout_seconds $PROBE_TIMEOUT > 2×poll_seconds+30; not polling"; sleep "$POLL_SECONDS"; done
    fi
    SERVICE=polling
    _log_event dispatcher armed not-printed "pid=$pid poll=${POLL_SECONDS}s key=$SESSION_KEY owner=${OWNER_PID:-none}"
    _ledger_write "armed"
    # SUPERVISOR LOOP: the poll pass is a subshell-free function call, but a
    # bug in it (a jq that starts failing, a probe file that traps) must
    # never propagate to an exit. Every iteration is guarded and any error
    # is logged to the ledger note and the events log, then the loop goes on.
    local rc st="$SPOOL/.poll-state" _sup
    while :; do
        # …AND THE RULE HOLDS AFTER ARMING (#1544). The arm-time check is a
        # check-then-write, so two dispatchers started together can both pass
        # it, and a predecessor that was merely WEDGED when this one armed can
        # resume. Whichever of the two next finds the OTHER's fresh write
        # yields: it stops polling and writing, waits as a refused dispatcher
        # does, and re-arms only if the other stops. Both cannot yield — a
        # yielding dispatcher has, by construction, not written since the
        # other's last write, so the other finds its OWN name and continues.
        #
        # WHO YIELDS IS DECIDED BY THE OWNER (your-org/nexus-code#1623): a
        # foreign writer serving a NEWER claude has superseded this one, which
        # EXITS — "the older sees it and exits instead of competing"; waiting
        # would leave it alive to re-arm the moment the newer one stops, which
        # is how the lsc2 orphan came to hold the ledger. The SAME owner is the
        # #1544 race and yields as before. An OLDER foreign writer is ignored:
        # this pass's own write reclaims the ledger, and that writer yields on
        # seeing it (by this rule, or by its pre-#1623 #1544 check).
        _owner_exit_if_gone
        if _sup=$(_ledger_foreign_owner); then
            case "${_sup#* }" in
                newer)
                    _log_event dispatcher superseded not-printed "pid=$$ exits: ledger now owned by pid=${_sup% *}, which serves a NEWER session (#1623)"
                    exit 0 ;;
                same)
                    _log_event dispatcher superseded not-printed "pid=$$ yields: ledger now owned by live dispatcher pid=${_sup% *} (single writer, #1544)"
                    _dispatch_wait_for_ledger
                    _log_event dispatcher armed not-printed "pid=$pid poll=${POLL_SECONDS}s key=$SESSION_KEY (re-armed)"
                    _ledger_write "armed" ;;
            esac
        fi
        # The pass runs in a SUBSHELL: a bash-FATAL error (an unbound variable
        # in arithmetic, a syntax error a future writer introduces) kills the
        # subshell, not this loop — `rc=$?` can only ever see returns, and the
        # skeptic measured a fatal killing the dispatcher on its first poll
        # (F6). Counters come back through a file; on a fatal they are simply
        # carried over from the last good pass.
        ( _poll_once; printf '%s %s %s %s %s %s %s %s\n' "$ACTIVE" "$RETIRED" "$EMITTED" "$EMIT_FAILURES" "$MUTED" "$LAST_EMIT_MS" "$LAST_LEDGER_WRITE" "$STDOUT_CLOSED" > "$st" ); rc=$?
        if (( rc == 0 )) && read -r ACTIVE RETIRED EMITTED EMIT_FAILURES MUTED LAST_EMIT_MS LAST_LEDGER_WRITE STDOUT_CLOSED < "$st" 2>/dev/null; then
            note="ok"
        else
            note="poll pass died rc=$rc at $(_now) (fatal error in the pass; counters carried over; dispatcher continues)"
            _log_event dispatcher error not-printed "$note"
        fi
        if [[ "$STDOUT_CLOSED" == 1 ]]; then
            # RELEASE THE SPOOL (your-org/nexus-code#1623). This process's stdout
            # has no reader, so it can wake nobody: it writes ONE last ledger
            # saying so — service `stdout-closed`, which the verdict reads as
            # not-armed (anything but `polling` is `disabled`) and which
            # _ledger_foreign_owner reads as NOT an owner, so a live dispatcher
            # waiting under #1544 arms on its next tick — then polls nothing and
            # writes nothing more (a second writer would be #1544 again), and
            # stays alive until its owner goes, the one exit that costs nobody.
            SERVICE=stdout-closed
            _ledger_write "stdout closed (a terminal write failed; the watch was restored un-retired): released the spool to a live dispatcher; polling nothing" \
                || _log_event dispatcher error not-printed "ledger write failed"
            _log_event dispatcher stdout-closed not-printed "pid=$$ stdout has no reader — released the spool; polls nothing more (#1623)"
            while :; do sleep "$POLL_SECONDS"; _owner_exit_if_gone; done
        fi
        _ledger_write "$note" || _log_event dispatcher error not-printed "ledger write failed"
        sleep "$POLL_SECONDS"
    done
}

# ---- main -----------------------------------------------------------------------
verb="${1:-}"; shift || true
# One sub-verb per arm and an `unknown … subcommand` catch-all: the shape every
# `ng` delegate shares, because test-ng-flag-order.sh enumerates a delegate's
# sub-verbs TWICE — forward from single-name `arm) cmd_x` lines, backward from
# the `unknown subcommand` die up to this `case` — and reads any disagreement
# as a defect. `list|ls)` and `rm|remove)` were invisible to the forward walk
# and `unknown verb` to the backward one (bundle-2609).
case "$verb" in
    add)      cmd_add "$@" ;;
    run)      cmd_run "$@" ;;
    list)     cmd_list "$@" ;;
    ls)       cmd_list "$@" ;;
    show)     cmd_show "$@" ;;
    rm)       cmd_rm "$@" ;;
    remove)   cmd_rm "$@" ;;
    events)   cmd_events "$@" ;;
    status)   cmd_status "$@" ;;
    ledger-verdict) cmd_ledger_verdict "$@" ;;
    resolve)  cmd_resolve "$@" ;;
    probe)    cmd_probe "$@" ;;
    await)    cmd_await "$@" ;;
    unmute)   cmd_unmute "$@" ;;
    reset)    cmd_reset "$@" ;;
    dispatch) cmd_dispatch "$@" ;;
    -h|--help|help|'') _usage; [[ "$verb" == "" ]] && exit 2; exit 0 ;;
    *) die "unknown longjob subcommand '$verb' (add|run|list|ls|show|rm|remove|events|status|ledger-verdict|resolve|probe|await|unmute|reset|dispatch)" ;;
esac
