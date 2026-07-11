#!/usr/bin/env bash
# worker-health.sh — a worker's answer to a watcher/orchestrator
# clarification request about its live background child process(es)
# (your-org/nexus-code#455 refine). Writes
# `$STATE_DIR/worker-health/<window>.json`; the watcher reads it in
# `_idle_probe.sh` to decide whether to extend the long-timeout grace
# (a declared-runtime job still running), reap (the job is done or
# stuck), or keep asking.
#
# WHEN you are asked: the watcher surfaced your window as
# `idle-children-clarify` (case a — you are idle with a live background
# child, e.g. a Slurm job you are waiting on) or `wrapped-with-children`
# (case b — you wrapped up but a child process is still live). The
# orchestrator pasted a clarification prompt pointing you here. Answer by
# running this script — do NOT reply only in the pane; the watcher reads
# the FILE, not your text.
#
# Usage:
#   worker-health.sh --health running --kind slurm --job-id 52527284 \
#                    --runtime 7200 --note "salloc DE sweep, ~2h"
#   worker-health.sh --health done   --note "job finished; children are leftover"
#   worker-health.sh --health stuck  --note "sbatch --wait never returned"
#   worker-health.sh --show                 print the current file (if any)
#   worker-health.sh --clear                 remove the file
#
# Fields:
#   --health   running | done | stuck        REQUIRED (unless --show/--clear)
#              running → the child is a live job you are legitimately
#                        waiting on; pair with --runtime so the watcher
#                        stays quiet until it should reasonably be done.
#              done    → the job has finished; any remaining child is
#                        leftover and the window is safe to close.
#              stuck   → the job / your wait is wedged; you need help.
#   --runtime  <seconds>   expected TOTAL/REMAINING runtime (running only).
#   --kind     slurm | local | remote | other   job kind (free-ish).
#   --job-id   <id>        scheduler job id / pid, for the operator.
#   --note     <text>      free-text context.
#
# Inputs / env (mirrors declare-no-wait.sh):
#   $NEXUS_WORKER_WINDOW   tmux window name. REQUIRED.
#   $NEXUS_STATE_DIR       state-dir override (test escape hatch).
#   $NEXUS_ROOT            fallback root ($NEXUS_ROOT/monitor/.state).
#
# Exit codes: 0 success; 2 bad usage / missing env / jq missing.

set -u

usage() {
    cat >&2 <<'EOF'
usage: worker-health.sh --health running|done|stuck [options]
       worker-health.sh --show
       worker-health.sh --clear

  Answer a watcher/orchestrator clarification about a live background
  child (your-org/nexus-code#455). The watcher reads the FILE, not your
  pane text. Writes $STATE_DIR/worker-health/<window>.json.

  --health   running | done | stuck        REQUIRED
             running → live job you are waiting on; pair with --runtime.
             done    → job finished; remaining child is leftover.
             stuck   → your wait is wedged; you need help.
  --runtime  <seconds>   expected TOTAL/REMAINING runtime (running).
  --kind     slurm | local | remote | other
  --job-id   <id>        scheduler job id / pid.
  --note     <text>      free-text context.
  --show                 print the current file.
  --clear                remove the file.

  Env: NEXUS_WORKER_WINDOW (required), NEXUS_STATE_DIR / NEXUS_ROOT.
EOF
    exit 2
}

window="${NEXUS_WORKER_WINDOW:-}"
if [[ -z "$window" ]]; then
    echo "worker-health.sh: NEXUS_WORKER_WINDOW unset — not in a worker context?" >&2
    exit 2
fi

if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    state_dir="$NEXUS_STATE_DIR"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    state_dir="$NEXUS_ROOT/monitor/.state"
else
    echo "worker-health.sh: neither NEXUS_STATE_DIR nor NEXUS_ROOT set" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "worker-health.sh: jq required" >&2
    exit 2
fi

health_dir="$state_dir/worker-health"
health_file="$health_dir/$window.json"

health=""; runtime=0; kind=""; job_id=""; note=""
action="write"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --health)  health="${2:-}"; shift 2 || usage ;;
        --runtime) runtime="${2:-}"; shift 2 || usage ;;
        --kind)    kind="${2:-}"; shift 2 || usage ;;
        --job-id)  job_id="${2:-}"; shift 2 || usage ;;
        --note)    note="${2:-}"; shift 2 || usage ;;
        --show)    action="show"; shift ;;
        --clear)   action="clear"; shift ;;
        --help|-h) usage ;;
        *)         echo "worker-health.sh: unknown arg: $1" >&2; usage ;;
    esac
done

case "$action" in
    show)
        if [[ -f "$health_file" ]]; then
            cat "$health_file"
        else
            echo "worker-health.sh: no health file at $health_file" >&2
            exit 0
        fi
        exit 0
        ;;
    clear)
        rm -f "$health_file" 2>/dev/null || true
        echo "worker-health.sh: cleared $health_file" >&2
        exit 0
        ;;
esac

case "$health" in
    running|done|stuck) : ;;
    "") echo "worker-health.sh: --health is required (running|done|stuck)" >&2; usage ;;
    *)  echo "worker-health.sh: --health must be running|done|stuck (got '$health')" >&2; usage ;;
esac
[[ "$runtime" =~ ^[0-9]+$ ]] || runtime=0
if [[ "$health" == "running" && "$runtime" -eq 0 ]]; then
    echo "worker-health.sh: WARNING: --health running without --runtime <seconds>; the watcher will keep asking on the backoff schedule instead of honouring a declared deadline." >&2
fi

mkdir -p "$health_dir" 2>/dev/null || {
    echo "worker-health.sh: cannot mkdir $health_dir" >&2
    exit 2
}

now=$(date +%s)
payload=$(jq -nc \
    --arg window "$window" \
    --arg health "$health" \
    --arg kind "$kind" \
    --arg job_id "$job_id" \
    --arg note "$note" \
    --argjson runtime "$runtime" \
    --argjson now "$now" \
    '{window: $window,
      job_kind: $kind,
      job_id: $job_id,
      expected_runtime_s: $runtime,
      health: $health,
      note: $note,
      written_at: $now}')

tmp="$health_file.$$.tmp"
if printf '%s\n' "$payload" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$health_file" 2>/dev/null || {
        rm -f "$tmp"
        echo "worker-health.sh: cannot rename $tmp to $health_file" >&2
        exit 2
    }
else
    rm -f "$tmp" 2>/dev/null
    echo "worker-health.sh: cannot write $tmp" >&2
    exit 2
fi

echo "worker-health.sh: recorded health=$health for window '$window' at $health_file" >&2
exit 0
