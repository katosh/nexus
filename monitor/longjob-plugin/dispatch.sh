#!/usr/bin/env bash
# monitor/longjob-plugin/dispatch.sh — the ONE command Claude Code arms at
# session start from this plugin's manifest. It never returns on purpose: a
# plugin-monitor command that exits is NOT relaunched for the rest of the
# session (measured, your-org/your-nexus#375 §S1), and its exit is delivered
# to the model as a "script failed" notice that costs a turn (measured
# 2026-09-15: ~16–21 s and ~$0.11 per session for a probe that exited at
# once). So even "nothing to do" is a loop, and a crash inside the dispatcher
# is caught by the supervisor loop in longjob-watch.sh rather than reaching
# the host.
#
# The dispatcher itself lives one directory up so it can be TESTED without a
# plugin — against a HERMETIC state dir (a private NEXUS_STATE_DIR), as
# monitor/watcher/test-longjob-watch.sh does.
#
# NEVER RUN `dispatch` BY HAND INSIDE A LIVE SESSION (bundle-2609sk3 F1,
# your-org/nexus-code#1541). The session ledger has ONE writer by assumption
# and nothing enforces it: a second `longjob-watch.sh dispatch` started from a
# tool shell rewrites `sid-<session>/dispatcher.json` to name ITSELF, and
# pane-state.sh then excludes THAT process's root from the background-shell
# census — together with whatever real work shares the root. Measured: `idle`
# (kill-authorised) over a `sleep 600` started in the same Bash call. If a
# session is NOT ARMED, the fallback is `longjob-watch.sh await`, which writes
# no ledger.
exec bash "$(cd "$(dirname "$0")/.." && pwd)/longjob-watch.sh" dispatch
