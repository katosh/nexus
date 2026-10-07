# shellcheck shell=bash
# monitor/longjob-probes.d/slurm.sh — longjob-watch subject probe: a Slurm job.
#
# THE PROBE CONTRACT (every file in this directory implements it, and adding
# a subject kind means adding ONE file here — the dispatcher never learns the
# kind's name):
#
#   lj_probe_main <target> <spec-json>      → prints  "<state>|<detail>"
#     state ∈ pending | running | done | failed | unknown
#
#   `unknown` is the FIFTH answer and it is not `running`. It means "I could
#   not tell", and the dispatcher's policy for it is a bounded retry and then
#   an EMIT (your-org/nexus-code#1535) — never silence. A probe that cannot
#   answer must say so rather than guess in either direction.
#
# Subject target: a Slurm job id (`123`, `123_4`, `123+1`) — the shape is
# `lj_slurm_jobid_valid` below, and `0` is not one.
#
# STATE VOCABULARY — read from `man sacct` "JOB STATE CODES" on slurm 25.11.5
# (2026-09-15), NOT from memory. `sacct --helpstates` is not whitelisted by the
# sandbox chaperon, so the man page is the enumerable source here:
#   BOOT_FAIL CANCELLED COMPLETED DEADLINE FAILED NODE_FAIL OUT_OF_MEMORY PENDING
#   PREEMPTED RUNNING REQUEUED RESIZING REVOKED SUSPENDED TIMEOUT
# plus the transient states `squeue` and older `sacct` builds surface and this
# workspace's orphan-async resolver already maps: COMPLETING CONFIGURING
# SIGNALING STAGE_OUT RESV_DEL_HOLD SPECIAL_EXIT.
#
# THE DEFAULT ARM IS `failed`, NEVER `running`. A state this file has not
# heard of is EMITTED (as a terminal, so the agent reads it) rather than
# assumed transient — the failure direction of "assume still running" is a
# worker asleep forever, and the cost of the other direction is one wake.
# Slurm appends a reason to some states (`CANCELLED by 1234`), so the match is
# on the leading word.
#
# A job that NEVER APPEARS: `sacct` returns nothing for a job id that was never
# accepted (a failed submission whose id the caller nevertheless recorded), and
# ALSO for a few seconds after a real submission (accounting lag). Both read as
# `unknown|no accounting row`; the dispatcher's bounded unknown-retry turns the
# first into an UNKNOWN emit after `unknown_max` polls and lets the second
# resolve on its own. `squeue` is consulted as a second source before saying
# unknown, because a queued job is visible there before accounting has it.

# AN ARRAY (or het job) IS A SET, NOT A ROW (your-org/nexus-code#1629). For an
# array id `sacct -X` prints ONE ROW PER TASK (plus a collapsed row for tasks
# still pending); this probe used to keep the FIRST line only, so the first
# task's COMPLETED emitted DONE while its siblings ran, and after two of them
# had FAILED. Every row is classified now: any pending/running row -> the set is
# not terminal; all terminal and ANY failed (or unrecognised) -> failed; all
# COMPLETED -> done. A single-row job prints exactly what it printed before.
# Classified inline (no `$(…)` per row): an array can have thousands of tasks.

# THE ONE JOB-ID SHAPE (your-org/nexus-code#1727). `lj_slurm_jobid_valid` is
# the single predicate behind all three places a Slurm id is accepted: this
# probe, `longjob-watch.sh add slurm:<id>`, and the auto-arm loop in
# `monitor/hooks/async-launch-detect.sh` (both SOURCE this file for it, so the
# three cannot drift apart). It used to be three copies of `^[0-9][0-9_.+]*$`,
# which accepts `0`: a `jid=$(sbatch --parsable …); echo $?` call printed `0`,
# the hook armed `auto-slurm-0`, and `sacct -j 0` answered with UNRELATED jobs,
# so the watch never reached a verdict about the job that was submitted — a
# ~9.5 h stall, measured. Slurm never assigns job id 0, and no real id has a
# leading zero.
#
# Accepted: a POSITIVE integer with no leading zero, optionally ONE array
# (`_N`) or het (`+N`) component, optionally ONE numeric step (`.N`) —
# `123456`, `123456_3`, `123456+0`, `123456.0`. The component numbers
# may be 0 (array tasks and het components start at 0). Every accepted string
# was also accepted by the old pattern: this only narrows.
LJ_SLURM_JOBID_ERE='^[1-9][0-9]*([_+][0-9]+)?([.][0-9]+)?$'
lj_slurm_jobid_valid() { [[ "${1:-}" =~ $LJ_SLURM_JOBID_ERE ]]; }

# lj_slurm_squeue_state <id> — the queue state of <id> from `squeue -u`,
# empty when the job is not listed (or squeue failed). `-u` and never `-j`:
# see the call site (your-org/nexus-code#1744). LJ_SQUEUE_USER is a test seam.
lj_slurm_squeue_state() {
    local target="$1" user="${LJ_SQUEUE_USER:-${USER:-$(id -un 2>/dev/null)}}"
    [[ -n "$user" ]] || return 0
    squeue -u "$user" -h -o '%i %T' 2>/dev/null | awk -v t="$target" '
        $1 == t || index($1, t "_") == 1 || index($1, t "+") == 1 { print $2; exit }'
}

lj_probe_main() {
    local target="$1"
    # Refused BEFORE `sacct` runs: `sacct -j 0` is not a question about any job.
    lj_slurm_jobid_valid "$target" || { printf 'unknown|not a Slurm job id: %s (never polled)' "$target"; return 0; }
    command -v sacct >/dev/null 2>&1 || { printf 'unknown|sacct not on PATH'; return 0; }
    local out rc state exit_code
    out=$(sacct -X -n -P -o State,ExitCode -j "$target" 2>/dev/null); rc=$?
    if (( rc != 0 )); then
        printf 'unknown|sacct rc=%s' "$rc"; return 0
    fi
    local rows="$out"
    out="${out%%$'\n'*}"
    if [[ -z "$out" ]]; then
        local sq
        if command -v squeue >/dev/null 2>&1; then
            # NEVER `squeue -j <id>` (your-org/nexus-code#1744): in this
            # sandbox it returns EMPTY at rc 0 for a job that IS queued on
            # ~25% of calls, in bursts, while the unfiltered `squeue -u` lists
            # the job on 40/40. Ask for OUR jobs and filter by id here. The id
            # matches exactly, or as the parent of an array task (`<id>_N`,
            # `<id>_[..]`) or a het component (`<id>+N`). An empty answer
            # still maps to `unknown` below, never to done.
            sq=$(lj_slurm_squeue_state "$target")
            if [[ -n "$sq" ]]; then
                case "${sq%% *}" in
                    PENDING|CONFIGURING|REQUEUED|RESV_DEL_HOLD) printf 'pending|squeue %s (not yet in accounting)' "$sq"; return 0 ;;
                    RUNNING|COMPLETING|SUSPENDED|SIGNALING|STAGE_OUT|RESIZING) printf 'running|squeue %s (not yet in accounting)' "$sq"; return 0 ;;
                    *) printf 'failed|squeue reports unrecognised state %s and sacct has no row' "$sq"; return 0 ;;
                esac
            fi
        fi
        printf 'unknown|no accounting row for job %s (submission failed, accounting lag, or not this cluster)' "$target"
        return 0
    fi
    if [[ "$rows" == *$'\n'* ]]; then
        local line c n=0 np=0 nr=0 nd=0 nf=0 first_bad=''
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            n=$((n + 1))
            c="${line%%|*}"
            case "${c%% *}" in
                PENDING|CONFIGURING|REQUEUED|RESV_DEL_HOLD) np=$((np + 1)) ;;
                RUNNING|COMPLETING|SUSPENDED|SIGNALING|STAGE_OUT|RESIZING) nr=$((nr + 1)) ;;
                COMPLETED) nd=$((nd + 1)) ;;
                *)  # the known failure states AND the unrecognised default arm
                    nf=$((nf + 1)); [[ -n "$first_bad" ]] || first_bad="$c exit=${line#*|}" ;;
            esac
        done <<< "$rows"
        local tally="array/het set of $n rows: $nd completed, $nf failed, $nr running, $np pending"
        if (( nr > 0 )); then
            printf 'running|%s%s' "$tally" "${first_bad:+ (first failure so far: $first_bad)}"
        elif (( np > 0 )); then
            printf 'pending|%s%s' "$tally" "${first_bad:+ (first failure so far: $first_bad)}"
        elif (( nf > 0 )); then
            printf 'failed|%s; first failure: %s' "$tally" "$first_bad"
        else
            printf 'done|COMPLETED %s' "$tally"
        fi
        return 0
    fi
    state="${out%%|*}"; exit_code="${out#*|}"
    case "${state%% *}" in
        PENDING|CONFIGURING|REQUEUED|RESV_DEL_HOLD)
            printf 'pending|%s' "$state" ;;
        RUNNING|COMPLETING|SUSPENDED|SIGNALING|STAGE_OUT|RESIZING)
            printf 'running|%s' "$state" ;;
        COMPLETED)
            printf 'done|COMPLETED exit=%s' "$exit_code" ;;
        FAILED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|BOOT_FAIL|DEADLINE|PREEMPTED|CANCELLED|REVOKED|SPECIAL_EXIT)
            printf 'failed|%s exit=%s' "$state" "$exit_code" ;;
        *)
            printf 'failed|unrecognised Slurm state %s exit=%s (not in this probe'"'"'s table — treated as terminal so it is READ, not slept through)' "$state" "$exit_code" ;;
    esac
    return 0
}
