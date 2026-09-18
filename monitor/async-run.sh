#!/usr/bin/env bash
# monitor/async-run.sh — launch background work that RETAINS ITS EXIT
# STATUS, so "the job is gone" and "the job finished cleanly" stay
# distinguishable after the fact (your-org/nexus-code#1071).
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────
#
# On 2026-08-26 six workers across four windows ended a turn holding
# `external_waits` whose jobs had already exited. Five instances shared one
# mechanical property and one did not:
#
#   slurm:2219913        `sacct` retained `COMPLETED … 0:0`  → RECOVERABLE
#   nohup:syn-4119b85d   the process is simply ABSENT        → NOT recoverable
#
# A bare `nohup cmd &` from the Bash tool structurally cannot retain a status:
# the shell that would reap it is itself reaped when the tool call returns. So
# the awaited process is *absent*, and absence is what a successfully finished
# producer and a SIGKILLed one look like ALIKE.
#
# That is not a cosmetic gap. A producer killed mid-write leaves a TRUNCATED,
# PLAUSIBLE intermediate — not an empty one — so it passes every emptiness
# check and silently shortens every number downstream. One of the six producers
# was at 28 GB RSS against a 92.6 GB archive on a shared node, so OOM was live
# and unfalsifiable from inside the worker.
#
# THE RULE IS NOT "don't use nohup". It is "**don't use a launcher that
# discards the exit status**". This script is that launcher.
#
# ── THE THREE-WAY ANSWER ────────────────────────────────────────────────
#
# `--status <token>` returns one of three verdicts, and the third is the
# whole point — a bare `nohup` fuses it into the first:
#
#   running   the recorded pid is still alive (identity-checked, see below)
#   terminal  the runner wrote a status file: rc is KNOWN
#   died      the RECORDED pid is gone AND no status file was written. The
#             usual cause is a process killed before it could report (OOM,
#             node failure, `kill -9`), and its output is presumed TRUNCATED.
#
# `died` is the verdict `nohup` cannot produce and `sacct` spells
# `OUT_OF_MEMORY` / `NODE_FAIL` / `CANCELLED`.
#
# BUT `died` IS A CLASSIFICATION OVER THE RECORDED PID, NOT A FACT ABOUT THE
# WORK, and the distinction is load-bearing rather than pedantic. The recorded
# pid is not guaranteed to BE the runner: the parent writes the `setsid`
# WRAPPER's `$!` and the runner overwrites it with its own `$$` (see the runner
# below), so there is a window in which a live job's recorded pid names a
# corpse. Measured: a corpse recorded pid over a genuinely running job read
# `died`, and that job went `terminal|rc=0` twenty-two seconds later.
#
# This mattered because the verdict TEXT once asserted the absolute — "this
# status file will never appear" — and followed it with an imperative, "stop the
# waiter". Absolute + imperative tells a reader to abandon a job that then
# succeeds: a manufactured WRONG INSTRUCTION on the surface built to stop
# manufactured answers (your-org/nexus-code#1237 F1).
#
# THE FIRST REPAIR SCOPED THE CLAIM AND KEPT THE IMPERATIVE, and that was not
# enough (#1237 F9). It became "RE-READ THIS VERDICT before acting, and stop a
# waiter only once it still says died" — which READS as a safeguard and is not
# one, because re-reading returns `died` in BOTH branches:
#
#     BRANCH A   false `died`, job SUCCEEDS   read#1 died   re-read died
#     BRANCH B   true  `died`                 read#1 died   re-read died
#
# The gate is TRUE in both, so it cannot discriminate the case it exists to
# protect against. Measured across one job's life: `died` at +0s, +1s, +2s, +9s,
# +19s, then `terminal|rc=0` at +22s — the gate was satisfied at second 2.
#
# THE GENERAL SHAPE, because it is not a wording slip: HEDGING A CLAIM DOES NOT
# FIX AN IMPERATIVE THAT RESTS ON IT. A reader does not act on your epistemics;
# they act on your VERB. Either an instruction gets a gate that actually
# discriminates, or it stops being an instruction.
#
# There is no sound discriminator available here — the absence of a status file
# cannot distinguish a dead runner from a live one, and argv matching is barred
# for the reason `#1073` gives — so the imperative is REMOVED rather than
# re-gated. The verdict now reports state, names its own failed gate so it is
# not re-added, and states the ASYMMETRY (waiting costs time; stopping a live
# producer is unrecoverable) leaving the decision with the reader.
# `monitor/watcher/test-async-run.sh` pins all of it and asserts BOTH the
# absolute form and the imperative are ABSENT, so neither returns quietly.
#
# ── THIS LINE HAS A BUDGET. READ THIS BEFORE LENGTHENING IT AGAIN. ──────
#
# Four review rounds each correctly lengthened this single printf, and the
# result is a correct message that can go unread. Source bytes of this arm:
# 310 at the base, then 582, 1037, 1350, and 1344 — only the last delta
# shortened it. Delivered detail went ~150 to ~1230 characters, 8.2x. EVERY
# STEP WAS INDIVIDUALLY JUSTIFIED, which is exactly why no single finding
# could catch the aggregate.
#
# So the ORDER is deliberate and load-bearing: STATE, then the EVIDENCE
# CENSUS, then what the verdict does and does not mean, and the one
# DIRECTIVE last. The directive used to sit at 81% of the line with 228
# characters of census after it; a reader who stops early got the epistemics
# and missed the action. Keep the directive terminal, and if you add
# anything, add it BEFORE `BOUND THE WAIT` — never after.
#
# Moving the census here also repaired an anaphor: "nothing was captured
# EITHER" refers back to "no status file was written", and those two clauses
# were about a thousand characters apart.
#
# ── PID IDENTITY, not just pid liveness ─────────────────────────────────
#
# `kill -0 $pid` answers "is SOME process alive at that number". Pids recycle,
# and a recycled pid would turn a `died` into a confident `running` — the exact
# silent-wrong-answer shape this workspace files most often. So the launch also
# records the kernel's start-time for that pid (`/proc/<pid>/stat` field 22,
# in clock ticks since boot, which is immutable for the life of the process),
# and the resolver requires BOTH the pid to exist AND its start-time to match.
# When the start-time could not be read (a `/proc`-restricted host, or a job so
# short it exited before we looked), the resolver says so in its reason string
# rather than silently degrading to the weaker test.
#
# ── DETACHMENT ──────────────────────────────────────────────────────────
#
# `setsid`, not `nohup`. The Bash tool reaps its process GROUP on return, so
# `nohup … &` dies with the tool call; `setsid` makes the child a session
# leader in a new session, which survives (the same reason the watcher and
# every registered service are setsid-detached — see
# `monitor/proc-kill-authorized`, whose allowlist deliberately refuses them).
#
# ── REGISTRATION ────────────────────────────────────────────────────────
#
# Every launch registers `asyncrun:<token>` in the worker heartbeat via
# `monitor/declare-wait.sh`, so the wait is visible to `pane-state.sh` exactly
# as an `sbatch` is. The difference is that this one is RESOLVABLE: the
# watcher's `_orphan_async.sh` wake loop calls back into `--status <token>`
# and can tell the worker WHICH of the three verdicts it got.
#
# WHAT IT DOES NOT DO: it never RE-INVOKES the launching agent. A retained
# status is not an armed wake, so this is not a parking mechanism
# (your-org/nexus-code#1523) — a wait whose END must wake the agent (the
# skeptic `await` loop is the measured case: rc 4 retained, agent idle 809 s)
# runs in the Bash tool's `run_in_background` or a `Monitor`, and this
# launcher is for work whose STATUS must survive the turn.
#
# Usage:
#   async-run.sh [--desc <text>] [--cwd <dir>] [--allow-concurrent] -- <cmd> [args…]
#   async-run.sh --status <token>
#   async-run.sh --status-line <token>     machine form: <verdict>|<detail>
#   async-run.sh --disposition-line <token>
#                                          <disposition>|<verdict>|<detail> — the
#                                          verdict AND what it means to a
#                                          consumer deciding whether the wait
#                                          is over (see _verdict_disposition)
#   async-run.sh --verdict-disposition <verdict>
#                                          the disposition of one verdict word
#   async-run.sh --dir <token>             print the token's state directory
#   async-run.sh --list                    one `<token> <verdict> <cmd>` per line
#   async-run.sh --cancel <token>          stop a job THIS SESSION launched
#   async-run.sh --await --timeout <s> [--interval <s>]
#                  [--token <t>]... [--shape '<rx>US<log>US<control-log>']...
#                                          bounded wait that owns the loop AND
#                                          the predicate; US = 0x1f
#
# Env:
#   $NEXUS_WORKER_WINDOW   REQUIRED (fail loud — this is a worker tool)
#   $NEXUS_STATE_DIR       override; else $NEXUS_ROOT/monitor/.state
#   $NEXUS_ROOT            fallback root
#   $NEXUS_ASYNC_RUN_WINDOW  read-only override used by the watcher to resolve
#                          ANOTHER window's token (never set by a worker)
#
# Exit codes:
#   0  launched / query answered
#   2  bad usage, missing env, missing dependency
#   3  launch failed (nothing was started; no wait was registered)
#   9  REFUSED — an identical job (same argv) is already RUNNING in this window;
#      its token is printed. `--allow-concurrent` overrides (#1389)
#   --cancel only:
#   4  signalled, but the process is STILL ALIVE after TERM and KILL
#   5  no such token in this window's namespace
#   6  DENIED — the token is owned by a DIFFERENT session
#   7  REFUSED — ownership could not be determined (no session recorded, this
#      caller has no session id, or a cross-window override was in play).
#      DISTINCT FROM 6 ON PURPOSE: "not yours" and "I could not tell" are
#      different facts, and merging them is how a default-deny arm rots into a
#      default-allow one.
#   8  REFUSED — the recorded pid's identity could not be verified; nothing
#      was signalled (pids recycle)

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || _self_dir="."

usage() {
    cat >&2 <<'EOF'
usage: async-run.sh [--desc <text>] [--cwd <dir>] [--allow-concurrent] -- <cmd> [args…]
       async-run.sh --status <token>
       async-run.sh --status-line <token>
       async-run.sh --disposition-line <token>
       async-run.sh --verdict-disposition <verdict>
       async-run.sh --dir <token>
       async-run.sh --list
       async-run.sh --cancel <token>

  Launch background work that retains its exit status, and register it as a
  resolvable `asyncrun:<token>` wait. Use this instead of a bare `nohup … &`,
  which destroys the status the moment the Bash tool returns.

  See skills/nexus.worker-defaults/SKILL.md, `## Worker floor`, "Own your
  async work, and launch it with something that KEEPS THE EXIT STATUS".
EOF
    exit "${1:-2}"
}

[[ $# -ge 1 ]] || usage

# `--help`/`-h` need NO context and answer BEFORE the context gate below
# (your-org/nexus-code#1440). They used to be dispatched after it, so outside a
# worker `async-run.sh --help` printed the window-unset REFUSAL — at the same
# exit code the usage uses, so a caller probing `--help` got the wrong bytes at
# the right status. Help is a successful answer: exit 0, distinct from every
# refusal, so the two are separable by status as well as by text. The sibling
# `--verdict-disposition` hoist (#1333) covers the other context-free query.
case "${1:-}" in --help|-h) usage 0 ;; esac

# _verdict_disposition <verdict> — THE ONE DEFINITION of what each verdict
# MEANS to a consumer that has to decide whether a wait is over
# (your-org/nexus-code#1333). `_verdict` emits six words; a consumer that
# restates them as its own case statement enumerates the members its author
# thought of and drops the rest into a default arm — which is exactly how
# `_orphan_async_resolve` reported a job whose detail string said "stopped on
# request" as `unresolvable`. So consumers ask THIS, and a seventh verdict
# added to `_verdict` must be given a disposition here in the same commit or
# it answers `doubt` — the fail-closed direction, and a loud one, because
# `monitor/watcher/test-orphan-async-resolve-vocabulary.sh` walks every
# `<word>|` literal `_verdict` prints and requires a non-`doubt` answer.
#
#   live     still (or possibly still) running: running | cancel-requested.
#            A cancel marker on a LIVE pid is `cancel-requested`, and it is
#            LIVE — "marker ⇒ settled" would retire a working window.
#   settled  ended, and the ENDING IS RECORDED on disk: terminal | cancelled.
#            A cancel marker with the pid gone is as positive a record as a
#            status file; what differs is the DETAIL, which is carried through.
#   gone     the recorded pid is gone and NOTHING was recorded: died. Output
#            presumed truncated; never rounded to settled.
#   doubt    could not classify: unknown, and every word this function has
#            never heard of.
# Prints the disposition; rc 0 always.
_verdict_disposition() {
    case "${1:-}" in
        running|cancel-requested) printf 'live' ;;
        terminal|cancelled)       printf 'settled' ;;
        died)                     printf 'gone' ;;
        *)                        printf 'doubt' ;;
    esac
    return 0
}

# ---- pure queries answer BEFORE any context is demanded -------------------
#
# `--verdict-disposition <word>` is a lookup on `_verdict_disposition`, the one
# definition of what each verdict means. It reads no state and names no
# window, so it must not be gated on either: CI's exported-root band (no
# NEXUS_WORKER_WINDOW, no tmux) got `exit 2 "NEXUS_WORKER_WINDOW unset"` from
# the window check below, and test-orphan-async-resolve-vocabulary.sh — whose
# helper swallowed stderr — read that as an EMPTY disposition for every word
# (PR your-org/nexus-code#1437, job 100855304683). A consumer that derives its
# vocabulary from this query would have derived NOTHING and fallen to its
# default arm in exactly the environment where nobody is watching.
if [[ "$1" == --verdict-disposition ]]; then
    _verdict_disposition "${2:-}"
    exit $?
fi

# ---- state resolution -----------------------------------------------------

window="${NEXUS_ASYNC_RUN_WINDOW:-${NEXUS_WORKER_WINDOW:-}}"
if [[ -z "$window" ]]; then
    echo "async-run.sh: NEXUS_WORKER_WINDOW unset — not in a worker context?" >&2
    exit 2
fi

if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    state_dir="$NEXUS_STATE_DIR"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    state_dir="$NEXUS_ROOT/monitor/.state"
else
    echo "async-run.sh: neither NEXUS_STATE_DIR nor NEXUS_ROOT set" >&2
    exit 2
fi

# Window directories use the INJECTIVE encoder every other window-keyed surface
# uses (your-org/nexus-code#941), so two windows whose names differ only in a
# character the old sanitiser flattened cannot share a token namespace. Failing
# CLOSED here is right: this is not a hot-path hook, and a collided namespace
# would attribute one worker's job status to another.
if ! declare -F wk_encode >/dev/null 2>&1; then
    # shellcheck source=monitor/_bookkeeping.sh
    [[ -r "$_self_dir/_bookkeeping.sh" ]] && . "$_self_dir/_bookkeeping.sh" 2>/dev/null
fi
if ! declare -F wk_encode >/dev/null 2>&1; then
    echo "async-run.sh: wk_encode unavailable (monitor/_bookkeeping.sh unreadable) — refusing rather than using a lossy key" >&2
    exit 2
fi

root_dir="$state_dir/async-run/$(wk_encode "$window")"

# ---- pid identity ---------------------------------------------------------

# _pid_starttime <pid> — the kernel's start-time for <pid> (field 22 of
# /proc/<pid>/stat, clock ticks since boot). Empty when unreadable.
#
# Field 22 is counted from the CLOSING PAREN of field 2, not by splitting the
# whole line: a process name may contain spaces and parentheses, which would
# shift every later field. `comm` is the only field that can, so cutting at the
# last `)` is exact rather than heuristic.
_pid_starttime() {
    local pid="$1" line rest
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    line=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    [[ -n "$line" ]] || return 1
    rest=${line##*) }
    # $rest now begins at field 3 (state), so start-time (22) is field 20 here.
    awk '{print $20}' <<<"$rest"
}

# _pid_alive <pid> <recorded-starttime> — rc 0 alive, 1 gone, 2 undecidable.
_pid_alive() {
    local pid="$1" want="$2" have
    [[ "$pid" =~ ^[0-9]+$ ]] || return 2
    if [[ -d "/proc/$pid" ]]; then
        have=$(_pid_starttime "$pid") || have=""
        if [[ -n "$want" && -n "$have" ]]; then
            [[ "$want" == "$have" ]] && return 0
            return 1          # same number, DIFFERENT process — pid was recycled
        fi
        return 2              # exists, but identity unverifiable
    fi
    # No /proc entry. On a /proc-less host this is not evidence; check that
    # /proc is usable at all before reading absence as death.
    [[ -d "/proc/$$" ]] || return 2
    return 1
}

# ---- the evidence census --------------------------------------------------

# _evidence <dir> <over> — how many bytes of the job's OWN output this surface
# actually holds. `<over>` is 1 when the job has ENDED.
#
# WHY THIS IS PART OF THE VERDICT (your-org/nexus-code#1201). A 23-minute job
# that left SIX suites red reported `terminal|rc=0` with `out` and `err` both
# ZERO BYTES, and a worker resumed with that reads success. Nothing was
# misreported: the rc was the payload's true rc, and the payload — a sweep
# giving every suite its own log file — exited 0 because its LAST command, a
# summary write, succeeded. Both halves were honest and the pair was useless.
#
# The defect is that the verdict was composed from `rc` and `elapsed` ALONE, so
# it carried no bit at all about whether any evidence existed. Measured on this
# host, four launches, the detail field printed VERBATIM:
#
#   payload                                    out/err   detail
#   bash -c 'exit 0'                           0B/0B     rc=0 elapsed=0s
#   bash -c 'echo hi; echo w >&2; exit 0'      6B/5B     rc=0 elapsed=0s
#
# BYTE-IDENTICAL across the one axis a resumed worker needs. `rc=0` and "I
# captured nothing" are not two readings of one signal; they are two
# independent facts, and only one of them was being reported.
#
# So this does NOT try to guess whether the job succeeded — it cannot, and the
# rc is already the best available answer to that. It reports the ONE thing the
# surface can establish on its own: whether the rc arrives CORROBORATED or
# bare. An empty pair is not evidence of failure; it is the absence of
# evidence, which is a different claim and the one that was missing.
#
# `NO-OUTPUT-CAPTURED` is a stable, greppable marker: a consumer keying on it
# is keying on "this verdict is uncorroborated", not on a prose fragment.
# `<mode>`: 0 = still running (an empty pair is not yet meaningful, so no
#           marker — the job may simply not have written anything YET);
#           1 = ENDED with a known rc (the marker qualifies THAT rc);
#           2 = ENDED with NO rc (`died`/`unknown` — there is no rc to
#           qualify, so the marker must not claim there is one).
_evidence() {
    local d="$1" mode="${2:-0}" ob eb
    ob=$(_bytes "$d/out"); eb=$(_bytes "$d/err")
    if [[ "$ob" == "?" || "$eb" == "?" ]]; then
        # "Could not look" is not "looked and found nothing" — the collapse
        # this repo files most often. Say which one happened.
        printf 'out=%s err=%s STREAMS-UNREADABLE: the capture files could not be sized, so NOTHING here corroborates this verdict' "$ob" "$eb"
        return 0
    fi
    if (( mode != 0 )) && (( ob == 0 )) && (( eb == 0 )); then
        if (( mode == 1 )); then
            # `payload%ss` -> `payload` + `'` + `s`. Written `payload%s` once,
            # which ate the `s` and shipped `payload' LAST command`. And the
            # closing clause used to say `before reading rc=0 as success`,
            # which is WRONG on a failing job: this arm fires for every rc, so
            # naming one is a claim about a number it has not looked at.
            printf 'out=0B err=0B NO-OUTPUT-CAPTURED: the job wrote NOTHING to either stream, so this rc is UNCORROBORATED — it is the status of the payload%ss LAST command, and a payload that redirects its own output leaves this surface blank. Find the payload%ss own log before treating this rc as a verdict on its work' "'" "'"
        else
            # "before it was KILLED" asserted the very thing F1 says this
            # verdict cannot establish. Same overclaim, smaller words.
            printf 'out=0B err=0B NO-OUTPUT-CAPTURED: nothing was captured either, so there is no record here of what the job did'
        fi
        return 0
    fi
    printf 'out=%sB err=%sB' "$ob" "$eb"
    return 0
}

# _bytes <file> — size in bytes, or `?` when it cannot be established.
# `?` is deliberate: a missing or unreadable capture file is not a zero.
_bytes() {
    local f="$1" n
    [[ -f "$f" ]] || { printf '?'; return 0; }
    n=$(wc -c < "$f" 2>/dev/null) || { printf '?'; return 0; }
    n=${n//[[:space:]]/}
    [[ "$n" =~ ^[0-9]+$ ]] || { printf '?'; return 0; }
    printf '%s' "$n"
}

# ---- verdicts -------------------------------------------------------------

# _verdict <token> — prints `<verdict>|<detail>`; always rc 0.
_verdict() {
    local token="$1" d="$root_dir/$1"
    if [[ ! -d "$d" ]]; then
        printf 'unknown|no such token %s under %s\n' "$token" "$root_dir"
        return 0
    fi
    local pid started want rc ended
    pid=$(cat "$d/pid" 2>/dev/null) || pid=""
    started=$(cat "$d/started" 2>/dev/null) || started=""
    want=$(cat "$d/pidstart" 2>/dev/null) || want=""

    if [[ -s "$d/status" ]]; then
        # Capture-then-slice, not `sed … | head -1`: an early-exit reader can
        # EPIPE its writer and, under pipefail, invert the status (the defect
        # monitor/watcher/early-exit-readers.sh tracks). The status file is
        # written atomically by the runner and has exactly one `rc=` line, so
        # slicing the first match off a captured string is both cheaper and
        # free of that hazard.
        local _rcs _ends
        _rcs=$(sed -n 's/^rc=//p'    "$d/status" 2>/dev/null); rc="${_rcs%%$'\n'*}"
        _ends=$(sed -n 's/^ended=//p' "$d/status" 2>/dev/null); ended="${_ends%%$'\n'*}"
        local elapsed="?"
        if [[ "$started" =~ ^[0-9]+$ && "$ended" =~ ^[0-9]+$ ]]; then
            elapsed=$(( ended - started )); (( elapsed >= 0 )) || elapsed=0
        fi
        # A STATUS FILE WINS OVER A CANCEL MARKER, and the order is deliberate.
        # The status file is POSITIVE EVIDENCE OF THE OUTCOME — the payload ran
        # to completion and this is its rc. The cancel marker records an
        # INTENT, which a job can outrun: a payload that traps TERM and exits
        # cleanly, or one that simply finished between the marker write and the
        # signal, has a REAL rc, and reporting `cancelled` would discard it.
        # The cancellation is annotated rather than dropped, so neither fact is
        # lost. (Arm order is the check your-org/nexus-code#1121 is about: this
        # arm returns before the cancel arm below, which is a claim that a
        # status file is the better answer whenever both are present.)
        if [[ -f "$d/cancelled" ]]; then
            printf 'terminal|rc=%s elapsed=%ss %s (a cancellation was requested for this token; the job reported a real rc anyway, so THIS rc is the outcome)\n' \
                "${rc:-?}" "$elapsed" "$(_evidence "$d" 1)"
            return 0
        fi
        printf 'terminal|rc=%s elapsed=%ss %s\n' "${rc:-?}" "$elapsed" "$(_evidence "$d" 1)"
        return 0
    fi

    # CANCELLED IS A FOURTH VERDICT, and it exists so that a deliberate stop
    # does not masquerade as a mysterious death. Without it, `--cancel` would
    # signal the job, no status file would be written, and the token would
    # read `died` — the verdict this whole surface defines as "killed before it
    # could report, output presumed TRUNCATED". A cancellation the operator
    # ORDERED and an OOM kill are different facts, and collapsing them would
    # re-create, from inside the fix, exactly the fusion this script exists to
    # prevent.
    #
    # The marker is written BEFORE any signal is sent (see the cancel verb), so
    # the two failure directions are:
    #   marker, no signal  -> `cancel-requested`, and the pid is still there to
    #                         see. OBSERVABLE.
    #   signal, no marker  -> `died`. Indistinguishable from an OOM. SILENT.
    # Order the pair so the failure you get is the one you can see.
    if [[ -f "$d/cancelled" ]]; then
        local _cby _cat
        _cby=$(sed -n 's/^by=//p'   "$d/cancelled" 2>/dev/null); _cby="${_cby%%$'\n'*}"
        _cat=$(sed -n 's/^at=//p'   "$d/cancelled" 2>/dev/null); _cat="${_cat%%$'\n'*}"
        local _calive=2
        _pid_alive "$pid" "$want"; _calive=$?
        if (( _calive == 0 )); then
            printf 'cancel-requested|pid=%s is STILL ALIVE: a cancellation was recorded at %s by session %s, but the process has not exited. %s\n' \
                "$pid" "${_cat:-?}" "${_cby:-?}" "$(_evidence "$d" 0)"
        else
            printf 'cancelled|stopped on request at %s by session %s — this job did NOT fail and did NOT die unattended; its output is TRUNCATED BY DESIGN, at the point of the cancel. %s\n' \
                "${_cat:-?}" "${_cby:-?}" "$(_evidence "$d" 2)"
        fi
        return 0
    fi


    local alive=2
    _pid_alive "$pid" "$want"; alive=$?
    # RE-TEST THE STATUS FILE ON A GONE PID (skeptic F3 — CONFIRMED).
    # The checks are ordered `status file? -> pid alive?` with no re-read, so a
    # job that writes its status and exits INSIDE that window reads `died`.
    # Demonstrated by widening the window with a `sleep 3` between the two
    # existing checks: `died … treat its output as TRUNCATED` against a ground
    # truth of `rc=0`. In production the window is microseconds and the
    # direction is a false ALARM rather than a false all-clear, which is why
    # this is minor — but the re-read costs one stat and removes it entirely.
    if (( alive == 1 )) && [[ -s "$d/status" ]]; then
        _verdict "$token"
        return 0
    fi
    case "$alive" in
        0) printf 'running|pid=%s %s\n' "$pid" "$(_evidence "$d" 0)" ;;
        1) printf 'died|pid=%s is gone and NO status file was written — treat any output as TRUNCATED, not empty. %s. `died` IS A CLASSIFICATION OVER THE RECORDED PID, NOT A FACT ABOUT THE WORK: the parent records the setsid WRAPPER as $!, and the runner overwrites it with its own $$, so a LIVE job can have a recorded pid that names a corpse. Measured — such a job answered `died` at +0s, +1s, +2s, +9s and +19s, then terminal rc=0 at +22s. RE-READING THIS VERDICT DOES NOT DISCRIMINATE: it answered `died` at every one of those samples, so a gate of the form "re-read, and act if it still says died" is SATISFIED IN EXACTLY THE CASE IT WAS MEANT TO CATCH. The only POSITIVE evidence is the status file APPEARING; its absence is never evidence of death. This verdict therefore does NOT tell you to stop anything. The decision is yours and it is ASYMMETRIC: waiting longer costs time, while stopping a live producer is unrecoverable and destroys the truncated intermediate you would need in order to tell the two cases apart. BOUND THE WAIT: wait for the status with an explicit budget and treat the TIMEOUT as UNDECIDED, never as confirmation.\n' "$pid" "$(_evidence "$d" 2)" ;;
        *) printf 'unknown|cannot decide liveness of pid=%s (start-time unverifiable) and no status file was written %s\n' "${pid:-?}" "$(_evidence "$d" 2)" ;;
    esac
    return 0
}


# ---- query modes ----------------------------------------------------------

case "${1:-}" in
    --help|-h) usage ;;
    --status|--status-line|--disposition-line)
        token="${2:-}"; [[ -n "$token" ]] || usage
        line=$(_verdict "$token")
        if [[ "$1" == "--status-line" ]]; then
            printf '%s\n' "$line"
        elif [[ "$1" == "--disposition-line" ]]; then
            printf '%s|%s\n' "$(_verdict_disposition "${line%%|*}")" "$line"
        else
            printf '%s: %s\n' "${line%%|*}" "${line#*|}"
        fi
        exit 0
        ;;
    --verdict-disposition)
        [[ -n "${2:-}" ]] || usage
        printf '%s\n' "$(_verdict_disposition "$2")"
        exit 0
        ;;
    --dir)
        token="${2:-}"; [[ -n "$token" ]] || usage
        printf '%s\n' "$root_dir/$token"
        exit 0
        ;;
    --await)
        # ── A BOUNDED WAIT THAT OWNS BOTH THE LOOP AND THE PREDICATE ────────
        #
        # your-org/nexus-code#1229. A hand-rolled waiter carried a STATUS arm
        # and a SHAPE arm in one loop. The status arm was correct and never
        # wedged. The shape arm keyed on `grep -qE '^(PASS|FAIL|…)'` while the
        # producer's lines are INDENTED and carry a COLON (`    PASS: …`), so
        # it matched NOTHING — and the producer had ALREADY FINISHED. An audit
        # of every waiter in that session found FOUR OF FIVE carrying a
        # predicate that could never match, and THREE with no deadline at all.
        #
        # `proc-exists-authorized` makes the argument for owning the LOOP: a
        # shell `until` loops on non-zero and a `while` loops on zero, so any
        # two-valued predicate is read backwards by one of them, and the caller
        # who writes the loop is the one who can invert it. Nothing yet owned
        # the PREDICATE. This does.
        #
        # THE ROOT CAUSE IS THE LAUNCH, NOT THE REGEX. Those producers were bare
        # background jobs with no status handle, so completion HAD to be
        # inferred from bytes — and `died` is the value NO SHAPE PREDICATE CAN
        # EXPRESS. A log that stops growing looks identical whether the job
        # finished, was OOM-killed, or never started. So:
        #
        #   --token <t>   THE PREFERRED ARM. Resolves through --status, which
        #                 answers the three-way verdict including `died`.
        #   --shape <rec> EXPLICITLY SECOND-CLASS, for a producer you did not
        #                 launch through this script. It can never establish
        #                 `died`, and it must PROVE ITS PREDICATE FIRST.
        #
        # THE POSITIVE CONTROL IS MANDATORY AND IS CHECKED AT t=0. A shape
        # record must name a log in which the predicate DOES match. A predicate
        # that matches nothing at t=0 is not a wait; it is a wedge with a timer
        # on it, and it will burn the full deadline before telling you the
        # regex was wrong. Checking it costs one grep.
        #
        # FIELD SEPARATOR IS US (0x1f), NOT TAB AND NOT `::`.
        #   `::` — the #1229 prototype used it, and its own controls caught the
        #          bug: a predicate ENDING IN A COLON, which is exactly the
        #          shape of the real-world case, collides with the delimiter. A
        #          DELIMITER THAT CAN OCCUR INSIDE THE FIELD IT DELIMITS IS NOT
        #          A DELIMITER.
        #   TAB  — is IFS WHITESPACE, so `read` COLLAPSES empty fields and a
        #          record with an omitted middle field silently shifts the
        #          control log into the regex slot. US is not whitespace, so
        #          empty fields survive and can be REFUSED instead of guessed.
        #
        # ONE SHELL. The prototype mixed bash `declare -A`/`${!a[@]}` with zsh
        # `${=VAR}` and was invoked with zsh, producing `bad substitution` AT
        # THE DEADLINE ARM — a crash in the one arm whose job is to report a
        # wedge. This file is `#!/usr/bin/env bash` throughout and uses only
        # bash constructs.
        #
        # Exit codes: 0 all complete | 2 REFUSED at t=0 | 4 DEADLINE (UNDECIDED,
        # never confirmation) | 5 resolved, but a producer DIED or was CANCELLED.
        shift
        _timeout=""; _interval=5
        _a_tok=(); _a_shape=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --timeout)  _timeout="${2:-}"; shift 2 || usage ;;
                --interval) _interval="${2:-}"; shift 2 || usage ;;
                --token)    _a_tok+=( "${2:-}" ); shift 2 || usage ;;
                --shape)    _a_shape+=( "${2:-}" ); shift 2 || usage ;;
                *) echo "async-run.sh: --await: unknown argument '$1'" >&2; exit 2 ;;
            esac
        done

        # A DEADLINE IS MANDATORY. Three of the five audited waiters had none,
        # and an unbounded wait cannot distinguish "not yet" from "never".
        if [[ ! "$_timeout" =~ ^[0-9]+$ ]] || (( _timeout <= 0 )); then
            echo "async-run.sh: --await REFUSED — --timeout <seconds> is REQUIRED and must be a positive" >&2
            echo "  integer. An unbounded wait cannot tell 'not yet' from 'never'; three of the five" >&2
            echo "  waiters audited in your-org/nexus-code#1229 had no deadline at all." >&2
            exit 2
        fi
        [[ "$_interval" =~ ^[0-9]+$ ]] && (( _interval > 0 )) || {
            echo "async-run.sh: --await REFUSED — --interval must be a positive integer" >&2; exit 2; }
        if (( ${#_a_tok[@]} + ${#_a_shape[@]} == 0 )); then
            echo "async-run.sh: --await REFUSED — nothing to wait for. Pass at least one --token or" >&2
            echo "  --shape. A waiter with an EMPTY producer set completes instantly and reports" >&2
            echo "  success, which is the manufactured-success direction of your-org/nexus-code#928." >&2
            exit 2
        fi

        # ---- t=0: PROVE EVERY SHAPE PREDICATE BEFORE WAITING ON ANY OF THEM --
        _sh_rx=(); _sh_log=(); _sh_ctl=()
        for _rec in ${_a_shape[@]+"${_a_shape[@]}"}; do
            IFS=$'\037' read -r _rx _log _ctl <<<"$_rec"
            if [[ -z "$_rx" ]]; then
                echo "async-run.sh: --await REFUSED — EMPTY shape predicate in record: $(printf '%q' "$_rec")" >&2
                echo "  An empty regex matches EVERY line, so this wait would 'complete' instantly against" >&2
                echo "  any non-empty log — a confident success that measured nothing." >&2
                exit 2
            fi
            if [[ -z "$_log" || -z "$_ctl" ]]; then
                echo "async-run.sh: --await REFUSED — a shape record needs THREE US-separated fields:" >&2
                echo "  <regex>US<logfile>US<positive-control-log>." >&2
                printf '  got regex=%q log=%q control=%q\n' "$_rx" "$_log" "$_ctl" >&2
                echo "  The control log is not optional: it is the only thing that distinguishes a" >&2
                echo "  predicate that has not matched YET from one that can NEVER match." >&2
                exit 2
            fi
            if [[ ! -r "$_ctl" ]]; then
                echo "async-run.sh: --await REFUSED — positive-control log '$_ctl' is unreadable." >&2
                echo "  Without it this predicate is unproven, and an unproven predicate is a wedge." >&2
                exit 2
            fi
            if ! grep -qE -e "$_rx" -- "$_ctl" 2>/dev/null; then
                echo "async-run.sh: --await REFUSED — the predicate does NOT match its own positive control." >&2
                echo "    predicate : $_rx" >&2
                echo "    control   : $_ctl" >&2
                echo "  This predicate can never complete, so waiting on it would burn the full ${_timeout}s" >&2
                echo "  deadline and then report a timeout that looks like a slow producer." >&2
                echo "  THE USUAL CAUSE IS ANCHORING: your-org/nexus-code#1229's predicate was" >&2
                echo "  '^(PASS|FAIL|UNVERIFIED|REFUSED)' while the producer emits INDENTED lines carrying a" >&2
                echo "  COLON — '    PASS: …' — so '^' could not match. Check leading whitespace and any" >&2
                echo "  trailing punctuation before assuming the producer is at fault." >&2
                exit 2
            fi
            _sh_rx+=( "$_rx" ); _sh_log+=( "$_log" ); _sh_ctl+=( "$_ctl" )
        done

        # ---- the loop, owned here so its polarity cannot be inverted --------
        _t0=$(date +%s); _deadline=$(( _t0 + _timeout ))
        _nogrowth=0; _prevtotal=-1
        while :; do
            _pending=0; _bad=0; _report=""
            for _t in ${_a_tok[@]+"${_a_tok[@]}"}; do
                _vl=$(_verdict "$_t"); _vv="${_vl%%|*}"
                case "$_vv" in
                    terminal)          _report+="  token $_t: terminal"$'\n' ;;
                    died|cancelled)    _report+="  token $_t: $_vv"$'\n'; _bad=1 ;;
                    running|cancel-requested) _report+="  token $_t: $_vv"$'\n'; _pending=1 ;;
                    unknown|*)
                        # NOT terminal. An unresolvable token must NOT be read as
                        # complete: `unknown` means the liveness could not be
                        # decided, and treating "could not tell" as "done" is the
                        # collapse this whole surface exists to prevent. It waits
                        # out the deadline instead, and the deadline is UNDECIDED.
                        _report+="  token $_t: $_vv (NOT terminal)"$'\n'; _pending=1 ;;
                esac
            done
            _total=0
            for _i in ${_sh_rx[@]+"${!_sh_rx[@]}"}; do
                _lg="${_sh_log[$_i]}"
                if [[ -r "$_lg" ]] && grep -qE -e "${_sh_rx[$_i]}" -- "$_lg" 2>/dev/null; then
                    _report+="  shape [${_sh_rx[$_i]}] matched in $_lg"$'\n'
                else
                    _report+="  shape [${_sh_rx[$_i]}] NOT yet matched in $_lg"$'\n'
                    _pending=1
                fi
                if [[ -r "$_lg" ]]; then
                    _sz=$(wc -c < "$_lg" 2>/dev/null) || _sz=0
                    _total=$(( _total + ${_sz//[^0-9]/} ))
                fi
            done
            if (( ${#_sh_rx[@]} > 0 )); then
                if (( _total == _prevtotal )); then _nogrowth=$(( _nogrowth + 1 )); else _nogrowth=0; fi
                _prevtotal=$_total
            fi

            if (( ! _pending )); then
                printf 'await: complete after %ss\n%s' "$(( $(date +%s) - _t0 ))" "$_report"
                (( _bad )) && {
                    echo "await: at least one producer DIED or was CANCELLED — the wait is over, but this" >&2
                    echo "  is NOT success. Its output is truncated; read --status before using it." >&2
                    exit 5; }
                exit 0
            fi
            _now=$(date +%s)
            if (( _now >= _deadline )); then
                printf 'await: DEADLINE — %ss elapsed, still pending\n%s' "$(( _now - _t0 ))" "$_report" >&2
                if (( ${#_sh_rx[@]} > 0 )); then
                    printf 'await: %s consecutive polls with no growth across %s shape log(s)\n' \
                        "$_nogrowth" "${#_sh_rx[@]}" >&2
                fi
                echo "await: A TIMEOUT IS UNDECIDED, NEVER CONFIRMATION. It does not mean the producers" >&2
                echo "  failed, and it does not mean they are still working. Read --status for each token." >&2
                exit 4
            fi
            sleep "$_interval"
        done
        ;;
    --cancel)
        # ── WHY THIS IS NOT A BYPASS OF proc-kill-authorized ────────────────
        #
        # `proc-kill-authorized` refuses every setsid-detached process, and
        # that refusal is CORRECT and is not weakened here. Its authorization
        # primitive is a SESSION-OWNERSHIP SCAN of live processes: it asks the
        # kernel "whose session is this pid in?" and requires the answer to be
        # yours. A setsid job is its OWN session leader, so that question has
        # no answer that names you, and its default-deny arm fires. It is
        # refusing because THE METHOD CANNOT ESTABLISH OWNERSHIP — not because
        # it has established that you are not the owner.
        #
        # This verb answers the SAME question from DIFFERENT evidence: a record
        # the owner wrote at launch, at the one moment ownership was a fact
        # rather than an inference. That is strictly better evidence than a
        # live scan, not a way around it — a durable claim by the owner beats
        # reconstructing intent from process state, which is the argument this
        # repo already makes against ancestry (`ppid` is 1 for a reparented
        # process while its session survives) and against argv matching
        # (`#1073`: a predicate keyed on a string matches sibling agents'
        # PROMPTS, not the thing).
        #
        # Two properties keep that honest, and without BOTH this would be a
        # bypass:
        #   1. It can only ever act on a token in THIS window's namespace and
        #      with THIS session recorded as owner. It is not a general kill
        #      facility; there is no --pid and no --match.
        #   2. It is DEFAULT-DENY on everything it cannot establish, and it
        #      distinguishes "not yours" from "could not determine" with
        #      different exit codes. Collapsing those two is how a default-deny
        #      arm becomes a default-allow arm in practice.
        #
        # WHAT IT DOES NOT FIX, stated plainly: the three tokens in #1308 §3
        # were launched BEFORE any session was recorded, so their `session`
        # file does not exist and this verb REFUSES them (rc 7). The fix is
        # PROSPECTIVE. A verb that guessed an owner for a record that has none
        # would be the bypass this comment says it is not.
        token="${2:-}"; [[ -n "$token" ]] || usage
        d="$root_dir/$token"

        # The cross-window override is a READ-ONLY resolver (the watcher uses
        # it to answer --status about another window). Letting it select the
        # namespace for a verb that SIGNALS would turn a read override into a
        # write capability over any window.
        if [[ -n "${NEXUS_ASYNC_RUN_WINDOW:-}" ]]; then
            echo "async-run.sh: --cancel REFUSED — NEXUS_ASYNC_RUN_WINDOW is set. That override exists" >&2
            echo "  to READ another window's token and must not select the target of a signal." >&2
            exit 7
        fi
        if [[ ! -d "$d" ]]; then
            echo "async-run.sh: --cancel: no such token '$token' under $root_dir" >&2
            exit 5
        fi

        _me="${CLAUDE_CODE_SESSION_ID:-}"
        _owner=$(cat "$d/session" 2>/dev/null) || _owner=""
        _owner="${_owner//[$'\n\r\t ']/}"
        _me="${_me//[$'\n\r\t ']/}"

        if [[ -z "$_owner" ]]; then
            echo "async-run.sh: --cancel REFUSED — no owning session is recorded for '$token'." >&2
            echo "  This token predates session recording (your-org/nexus-code#1308 §3), or the record" >&2
            echo "  was lost. REFUSING is the answer: an unowned record is not evidence that the job is" >&2
            echo "  yours, and guessing an owner is precisely the reasoning this verb refuses to do." >&2
            echo "  Stop it by hand, by recorded pid: $(cat "$d/pid" 2>/dev/null || echo '?') (dir: $d)" >&2
            exit 7
        fi
        if [[ -z "$_me" ]]; then
            echo "async-run.sh: --cancel REFUSED — CLAUDE_CODE_SESSION_ID is unset, so this caller's own" >&2
            echo "  identity cannot be established. 'I do not know who I am' is not 'I am the owner'." >&2
            exit 7
        fi
        if [[ "$_owner" != "$_me" ]]; then
            echo "async-run.sh: --cancel DENIED — token '$token' is owned by session $_owner; you are $_me." >&2
            echo "  A successor agent in the same WINDOW is deliberately denied too: it did not launch this" >&2
            echo "  job, and the session that did may still be running and relying on it." >&2
            exit 6
        fi

        # Already finished? Nothing to signal, and saying so is not a failure.
        _v=$(_verdict "$token")
        case "${_v%%|*}" in
            terminal|cancelled)
                printf 'async-run: nothing to cancel — %s: %s\n' "${_v%%|*}" "${_v#*|}"
                exit 0 ;;
        esac

        _pid=$(cat "$d/pid" 2>/dev/null) || _pid=""
        _want=$(cat "$d/pidstart" 2>/dev/null) || _want=""
        _want="${_want//[$'\n\r\t ']/}"
        _pid_alive "$_pid" "$_want"; _al=$?
        if (( _al == 2 )); then
            # PID IDENTITY, NOT PID LIVENESS. Signalling a pid whose identity
            # cannot be verified is how a cancel becomes a kill of whatever
            # unrelated process inherited that number.
            echo "async-run.sh: --cancel REFUSED — cannot verify the identity of recorded pid ${_pid:-?}" >&2
            echo "  (its start-time could not be read, or was never recorded). Pids are recycled, so" >&2
            echo "  signalling on liveness alone can stop an unrelated process. Nothing was signalled." >&2
            exit 8
        fi
        if (( _al == 1 )); then
            echo "async-run.sh: --cancel — recorded pid ${_pid:-?} is already gone; recording the" >&2
            echo "  cancellation so this token does not read 'died'. Nothing was signalled." >&2
            printf 'by=%s\nat=%s\nsignalled=no\n' "$_me" "$(date +%s)" > "$d/cancelled.tmp" \
                && mv -f "$d/cancelled.tmp" "$d/cancelled"
            exit 0
        fi

        # MARKER FIRST, THEN SIGNAL. Reversing these makes the failure SILENT:
        # a signal whose marker never landed leaves the token reading `died`,
        # indistinguishable from an OOM kill. This order fails toward
        # `cancel-requested` with a live pid, which anyone can see.
        printf 'by=%s\nat=%s\nsignalled=yes\n' "$_me" "$(date +%s)" > "$d/cancelled.tmp" \
            && mv -f "$d/cancelled.tmp" "$d/cancelled" \
            || { echo "async-run.sh: --cancel ABORTED — could not record the cancellation marker;" >&2
                 echo "  refusing to signal, because a kill with no marker reads as 'died'." >&2
                 exit 3; }

        # The runner is a session leader, so its process GROUP is the whole job.
        kill -TERM -- "-$_pid" 2>/dev/null || kill -TERM "$_pid" 2>/dev/null || true
        _i=0
        while (( _i < 20 )); do
            _pid_alive "$_pid" "$_want"; (( $? == 0 )) || break
            sleep 0.5; _i=$(( _i + 1 ))
        done
        _pid_alive "$_pid" "$_want"
        if (( $? == 0 )); then
            echo "async-run.sh: --cancel: pid $_pid still alive after 10s — escalating to KILL" >&2
            kill -KILL -- "-$_pid" 2>/dev/null || kill -KILL "$_pid" 2>/dev/null || true
            sleep 0.5
        fi

        _v2=$(_verdict "$token")
        printf 'async-run: cancel issued for %s\n  verdict %s: %s\n' "$token" "${_v2%%|*}" "${_v2#*|}"
        case "${_v2%%|*}" in
            cancel-requested)
                echo "  NOTE: the process is STILL ALIVE after TERM and KILL. It may be in" >&2
                echo "  uninterruptible sleep (D state, typically NFS I/O). Nothing further to try here." >&2
                exit 4 ;;
        esac
        exit 0
        ;;
    --list)
        # A no-token directory is not an error; print nothing and exit 0.
        [[ -d "$root_dir" ]] || exit 0
        for d in "$root_dir"/*/; do
            [[ -d "$d" ]] || continue
            t=$(basename "$d")
            printf '%s\t%s\t%s\n' "$t" "$(_verdict "$t")" \
                "$(head -c 200 "$d/cmd" 2>/dev/null | tr '\n' ' ')"
        done
        exit 0
        ;;
esac

# ---- launch ---------------------------------------------------------------

desc=""
cwd="$PWD"
allow_concurrent=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --desc) desc="${2:-}"; shift 2 || usage ;;
        --cwd)  cwd="${2:-}";  shift 2 || usage ;;
        --allow-concurrent) allow_concurrent=1; shift ;;
        --)     shift; break ;;
        -*)     usage ;;
        *)      break ;;
    esac
done
[[ $# -ge 1 ]] || usage

command -v setsid >/dev/null 2>&1 || {
    echo "async-run.sh: setsid required (a nohup fallback would reintroduce the defect this closes)" >&2
    exit 2
}
[[ -d "$cwd" ]] || { echo "async-run.sh: --cwd '$cwd' is not a directory" >&2; exit 2; }

# DUPLICATE-LAUNCH GUARD (your-org/nexus-code#1389). Three concurrent copies
# of a mutation driver once raced in one clone — each planting a mutant,
# `git checkout`-ing a suite and copying a variant back — and produced a
# plausible, wrong-provenance measurement that was published before it was
# caught. The launcher had happily started all three. Compared by ARGV (the
# NUL-separated file every job records), never by `--desc`, which a caller
# varies while retrying; a RUNNING job of this window with the same argv
# REFUSES the launch and prints the existing token — which is also the thing
# the retrying caller was looking for. `--allow-concurrent` is the explicit
# opt-in for genuinely parallel fan-out over disjoint inputs (which then has
# a different argv anyway).
_argv_probe=$(mktemp "${TMPDIR:-/tmp}/async-run-argv.XXXXXX" 2>/dev/null) || _argv_probe=""
if [[ -n "$_argv_probe" ]]; then
    : > "$_argv_probe"
    for a in "$@"; do printf '%s\0' "$a" >> "$_argv_probe"; done
    if (( allow_concurrent == 0 )); then
        for _pd in "$root_dir"/ar-*/; do
            [[ -d "$_pd" && -f "$_pd/argv" ]] || continue
            cmp -s "$_pd/argv" "$_argv_probe" || continue
            _pt=$(basename "$_pd")
            _pv=$(_verdict "$_pt"); _pv="${_pv%%|*}"
            case "$_pv" in running|cancel-requested) ;; *) continue ;; esac
            rm -f "$_argv_probe"
            cat >&2 <<EOF
async-run: REFUSED — an identical job is already RUNNING in this window
  token   $_pt
  status  $_self_dir/async-run.sh --status $_pt
  desc    $(head -c 120 "$_pd/desc" 2>/dev/null)
The argv you passed is byte-identical to that job's. If you are retrying
because you lost the token, THIS is the token. If you really want a second
concurrent copy (parallel fan-out over disjoint inputs), pass
--allow-concurrent. A payload that writes into a shared tree — a fixture
builder, a git checkout, a cp of a variant — is unsafe to run twice at once
(your-org/nexus-code#1389: three copies of one mutation driver raced and a
plausible, wrong-provenance number was published).
EOF
            exit 9
        done
    fi
    rm -f "$_argv_probe"
fi

token="ar-$( (printf '%s' "$*"; date +%s%N) | sha1sum 2>/dev/null | cut -c1-12 )"
[[ "$token" == "ar-" ]] && token="ar-$$$(date +%s)"
d="$root_dir/$token"
mkdir -p "$d" || { echo "async-run.sh: cannot mkdir $d" >&2; exit 3; }

# Record the command as an argv-per-line file, not a re-quoted string: the
# runner reads it back with `mapfile`-free `while read`, so an argument
# containing spaces survives the round trip intact.
: > "$d/argv"
for a in "$@"; do printf '%s\0' "$a" >> "$d/argv"; done
printf '%s\n' "$*" > "$d/cmd"
printf '%s\n' "$desc" > "$d/desc"
printf '%s\n' "$cwd"  > "$d/cwd"
date +%s > "$d/started"

# THE OWNING SESSION, recorded at the only moment it is knowable.
#
# WHY THIS FIELD EXISTS (your-org/nexus-code#1308 §3). Three runaway
# `guards-for-diff --run` jobs could not be stopped by the agent that started
# them: this script had no cancel verb, and `proc-kill-authorized` correctly
# REFUSES a setsid-detached job — it is its own session leader, so a
# session-ownership SCAN cannot attribute it to anyone, and its default-deny
# arm fires. That refusal is right and must not be weakened. But it is a
# refusal of one METHOD of establishing ownership, not a ruling that the job
# must never be stopped; the launcher knows who it is, and the only reason
# nothing could act on that was that nobody wrote it down.
#
# Recorded here rather than inferred later because ownership is a fact about
# the LAUNCH, and every after-the-fact proxy for it (ancestry, argv, window
# occupancy) is one this repo has already measured wrong.
printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-}" > "$d/session"
printf '%s\n' "$window"                     > "$d/window"

# The runner. Written to disk rather than passed with `-c` so the argv file is
# read by the child itself — the parent never re-quotes anything.
#
# THE STATUS WRITE IS THE POINT, so it is `.tmp` + `mv` (atomic rename): a
# reader can never see a half-written status and read a partial rc. And it runs
# under a trap-free straight line after the command, so the only way it is
# skipped is the process being KILLED — which is exactly the `died` verdict.
cat > "$d/run.sh" <<'RUNNER'
#!/usr/bin/env bash
d="$1"
cd "$(cat "$d/cwd")" 2>/dev/null || cd / || exit 127
# AUTHORITATIVE PID, written by the process that actually runs the command
# (skeptic F4 — CONFIRMED). The parent records `$!`, which is the `setsid`
# WRAPPER; with job control on (`set -m`) that wrapper forks and exits
# immediately, so the parent's guess names a corpse and a running job reads
# `died`. Measured: job-control OFF -> $! alive=YES; ON -> alive=NO. The parent
# still writes its guess first, so an immediate `--status` before this line runs
# answers something rather than nothing; this OVERWRITES it with the truth.
_st=$(awk '{r=$0; sub(/^.*\) /,"",r); print r}' "/proc/$$/stat" 2>/dev/null | awk '{print $20}')
printf '%s\n' "$$"   > "$d/pid.tmp"      && mv -f "$d/pid.tmp"      "$d/pid"
printf '%s\n' "$_st" > "$d/pidstart.tmp" && mv -f "$d/pidstart.tmp" "$d/pidstart"
args=()
while IFS= read -r -d '' a; do args+=("$a"); done < "$d/argv"
"${args[@]}" < /dev/null > "$d/out" 2> "$d/err"
rc=$?
printf 'rc=%s\nended=%s\n' "$rc" "$(date +%s)" > "$d/status.tmp" \
    && mv -f "$d/status.tmp" "$d/status"
RUNNER
chmod +x "$d/run.sh"

setsid bash "$d/run.sh" "$d" < /dev/null > /dev/null 2>&1 &
launched_pid=$!
disown "$launched_pid" 2>/dev/null || true

# `setsid` forks; `$!` is the setsid wrapper, whose child is the real leader.
# On util-linux setsid the wrapper EXECs into a new session when it is not
# already a group leader, so `$!` usually IS the session leader — but not
# always. Record the pid we can see, and its start-time, and let the resolver
# say `unknown` rather than guess if the identity cannot be established.
printf '%s\n' "$launched_pid" > "$d/pid"
_pid_starttime "$launched_pid" > "$d/pidstart" 2>/dev/null || : > "$d/pidstart"

# Register the wait LAST, so a failed launch never leaves a wait nobody can
# resolve. Best-effort: a missing declare-wait.sh must not fail the launch, but
# it must be LOUD, because an unregistered wait is invisible to the watcher.
if [[ -x "$_self_dir/declare-wait.sh" ]]; then
    NEXUS_WORKER_WINDOW="$window" "$_self_dir/declare-wait.sh" \
        asyncrun "$token" "${desc:-$(head -c 60 "$d/cmd")}" \
        || echo "async-run.sh: WARNING — declare-wait.sh failed; this wait is NOT registered with the watcher" >&2
else
    echo "async-run.sh: WARNING — $_self_dir/declare-wait.sh missing; this wait is NOT registered with the watcher" >&2
fi

# THE HANDLE COMES FIRST (your-org/nexus-code#1389). Callers pipe tool output
# through `head -3` / `tail -6` as a matter of course, and the hook's advisory
# preamble competes with this block for the screen: a launcher whose token
# scrolls out of view reads as "no output, must have failed" and gets
# RETRIED — which for a non-idempotent payload is the destructive direction.
# So the one line the caller must retain is the first line, alone, and it
# survives any truncation: `async-run: launched token=<t>`.
cat <<EOF
async-run: launched token=$token
  token   $token
  pid     $launched_pid
  dir     $d
  status  $_self_dir/async-run.sh --status $token
  stdout  $d/out
  stderr  $d/err
The exit status will be retained in $d/status. You still OWN the wake, and
it needs a DEADLINE (your-org/nexus-code#1250, #1236):

  wait    monitor/proc-exists-authorized --until-gone --token $token --timeout 1800
  then    $_self_dir/async-run.sh --status $token

DO NOT POLL $d/status FOR EXISTENCE. The verdict 'died' is defined as the
recorded pid gone AND NO STATUS FILE WRITTEN, so on exactly that verdict this
file will NEVER APPEAR and an existence-poll cannot terminate -- measured at
28 HOURS in production. --status resolves 'died'; a file test cannot express
it. (Backticks are deliberately absent from this block: it is an INTERPOLATING
heredoc, so a backticked word is command-substituted and silently deleted --
your-org/nexus-code#1157, hit while writing this very text.)
Run the waiting step in a Monitor or a BACKGROUNDED Bash call
(run_in_background), never a foreground one: this launcher RETAINS the
status and never RE-INVOKES you -- it is not a parking mechanism
(your-org/nexus-code#1523). The watcher resolving your wait is a BACKSTOP,
not your resume mechanism.

TWO THINGS THE STATUS ALONE CANNOT TELL YOU (your-org/nexus-code#1201):

  1. out/err above are the ONLY evidence this surface holds, and rc is the
     status of your payload's LAST COMMAND -- not a verdict on its work. A
     payload that redirects its own output (per-item logs, a tee to a results
     file) leaves both EMPTY, and a payload with no rc aggregation exits 0 with
     its work red. Measured: a 23-minute sweep reported rc=0, out 0B, err 0B,
     having left SIX suites failing. --status now says NO-OUTPUT-CAPTURED when
     it holds nothing at all.
     THAT IS A FLOOR, NOT A GUARANTEE, and the threshold is worth knowing: the
     marker fires only when BOTH streams are ENTIRELY EMPTY. Any byte on either
     one suppresses it -- so a payload that prints one startup line and writes
     every real result elsewhere is NOT marked, and 22 bytes of progress
     chatter buys the same silence as 22 MB of results. The census still prints
     the byte counts; read them, do not just look for the marker.
     If your payload writes its own logs, TELL THE READER WHERE: pass the path
     in --desc.

  2. Write that output INSIDE YOUR CLONE, not into shared /tmp. /tmp here is
     cleaned and shared; a 23-minute result that exists only there is one
     cleanup from unrecoverable.
EOF
exit 0
