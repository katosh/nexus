# shellcheck shell=bash
# monitor/longjob-probes.d/asyncrun.sh — longjob-watch subject probe: an
# `monitor/async-run.sh` token. Contract: see slurm.sh.
#
# This is the subject kind that RETAINS an exit status, and therefore the one
# the docs point at for anything local whose rc matters. The meaning is asked
# of the authority, not restated: `async-run.sh --disposition-line <token>`
# returns `<disposition>|<verdict>|<detail>` from ONE definition, and the four
# DISPOSITIONS (live / settled / gone / unresolvable) are a closed set that does
# not grow when a verdict is added (your-org/nexus-code#1333). Mapping:
#
#   live         → running
#   settled      → done  when the retained rc is 0, failed otherwise
#                  (`cancelled` is settled too — rc absent — and reads failed)
#   gone         → failed|died … (the recorded pid is gone and no status was
#                  written: output presumed TRUNCATED, never "finished")
#   anything else→ unknown
#
# `async-run.sh` resolves its state dir from NEXUS_STATE_DIR/NEXUS_ROOT and its
# window from NEXUS_ASYNC_RUN_WINDOW/NEXUS_WORKER_WINDOW; the dispatcher
# inherits all of those from the launcher, so a token minted in this session
# resolves here without extra plumbing.

lj_probe_main() {
    local target="$1" script="" line disp rest rc
    if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/async-run.sh" ]]; then
        script="$NEXUS_ROOT/monitor/async-run.sh"
    elif [[ -x "$(dirname "${BASH_SOURCE[0]}")/../async-run.sh" ]]; then
        script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/async-run.sh
    else
        printf 'unknown|async-run.sh not found — cannot read the retained status'; return 0
    fi
    line=$("$script" --disposition-line "$target" 2>/dev/null) || line=""
    [[ -n "$line" ]] || { printf 'unknown|async-run.sh gave no disposition for token %s (unknown token, old script, or unreadable state)' "$target"; return 0; }
    disp="${line%%|*}"; rest="${line#*|}"
    case "$disp" in
        live)    printf 'running|%s' "${rest#*|}" ;;
        settled)
            rc=""
            [[ "$rest" =~ rc=([0-9]+) ]] && rc="${BASH_REMATCH[1]}"
            if [[ "$rc" == "0" ]]; then printf 'done|%s' "${rest#*|}"
            else printf 'failed|%s' "${rest#*|}"; fi ;;
        gone)    printf 'failed|died: %s' "${rest#*|}" ;;
        *)       printf 'unknown|%s' "${rest#*|}" ;;
    esac
    return 0
}
