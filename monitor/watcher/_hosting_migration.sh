#!/usr/bin/env bash
# Legacy-hosting detection + one-shot migration notice (issue 182).
#
# Since the headless-services cutover (your-org/nexus-code#238) the
# watcher's canonical host is a setsid-detached service: launcher.sh
# spawns `main.sh` with `WATCHER_WINDOW=headless` in its environment,
# and that marker is the launcher's contract — nothing else sets it
# to that value. A watcher started any other way (the pre-cutover
# entry.sh exported `WATCHER_WINDOW=watcher` and exec'd main.sh in a
# tmux window; a manual foreground `bash main.sh` leaves it unset)
# is running legacy-hosted.
#
# The upgrade is self-delivering through the normal
# watcher→orchestrator channel: when new code starts under legacy
# hosting, the startup sweep includes a `--- watcher hosting
# migration ---` section telling the orchestrator exactly how to
# converge (pull BEFORE restart, then `monitor/svc.sh restart
# watcher`). The watcher then continues working normally — no
# refusal, no degraded mode. The notice is computed once at startup
# and rides only the startup-sweep emit, so it fires at most once
# per watcher lifecycle by construction (a still-legacy watcher that
# restarts gets one fresh notice per start, which is the intended
# re-delivery cadence).
#
# Side-effect-free at source time: function definitions only.

# _hosting_is_legacy <watcher_window_value>
#
# Returns 0 (legacy) unless the value is exactly `headless` — the
# marker launcher.sh injects into the environment of every headless
# spawn. Pass "${WATCHER_WINDOW:-}" so an unset var reads as legacy.
_hosting_is_legacy() {
    [[ "${1:-}" != "headless" ]]
}

# _hosting_render_migration_notice <nexus_root> <watcher_window_value>
#
# Print the migration-notice body (the emit section's content; the
# caller owns the `--- watcher hosting migration ---` header). Written
# to be actionable by the orchestrator in one turn and safe to relay
# to the operator verbatim.
_hosting_render_migration_notice() {
    local nexus_root="$1" www="${2:-}"
    cat <<NOTICE
This watcher is running LEGACY window-hosted (WATCHER_WINDOW='${www:-<unset>}').
The nexus stack moved to headless service hosting: the watcher runs
setsid-detached (no tmux window), logs to monitor/.state/watcher.log,
and is supervised via monitor/svc.sh.

To finish the migration (safe to do now; one command):
1. Ensure the live clone is current: \`git -C ${nexus_root} pull\`.
   Always pull BEFORE restarting — main.sh sources module files that
   must already exist on disk.
2. Run \`${nexus_root}/monitor/svc.sh restart watcher\` — the launcher
   respawns the watcher headless and sweeps the legacy 'watcher'
   window automatically (self-converging; no manual window cleanup).
3. Verify: \`${nexus_root}/monitor/ng watcher-status\` reports
   \`hosting: headless\`, and \`monitor/svc.sh status\` shows the
   watcher row UP.

This watcher keeps working normally in the meantime; the notice is
emitted once per watcher start. Full guide: docs/operating/upgrading.md
(https://your-org.github.io/nexus-code/operating/upgrading/).
NOTICE
}
