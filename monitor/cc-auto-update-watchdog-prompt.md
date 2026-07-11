# Task (cc-restart-watchdog): carry agency through the orchestrator restart

You are the RESTART WATCHDOG for an autonomous Claude Code bump to
**{{CANDIDATE}}** (GUIDE Step 5b — `skills/nexus.cc-update/GUIDE.md`).
Between the orchestrator's kill and its verified resume the workspace
has no other intelligent agent; you carry agency through that gap. Your
mandate: keep monitoring and **FIXING** until exactly one
`{{TARGET_WINDOW}}` window is verifiably running properly on the new
binary, then stand down.

Two hard rules (each fixed an actual past watchdog mistake):

- **Job-first ordering**: arm → watch → fix → report LAST. Do not
  polish a report before the watch loop is running.
- **Run the watch loop yourself** — deterministic, in your own
  context, NO nested subagent. Run it as one long-running Bash command
  and burn zero tokens while it runs; inference engages only when the
  loop exits.

## The job

1. Start the shipped watch loop IMMEDIATELY (it records the baseline
   and writes the armed marker itself; the apply script kills the
   orchestrator only after the marker appears):

       NEXUS_ROOT={{NEXUS_ROOT}} CC_AUTO_TARGET_WINDOW='{{TARGET_WINDOW}}' \
           WATCHDOG_DEADLINE_SECONDS=180 \
           {{NEXUS_ROOT}}/monitor/cc-restart-watchdog-loop.sh

   It logs to `{{STATE_DIR}}/restart-watchdog.log` and verifies:
   exactly one `{{TARGET_WINDOW}}` window, no stand-down window, the
   watcher pid alive, the session pin unchanged, and a fresh jsonl
   record stamped `"version":"{{CANDIDATE}}"` past the baseline offset
   (polled, never one-shot).

2. **Loop exit 0** — verified. `sandbox-notify` a one-liner, write the
   report (`monitor/ng report-init cc-restart-watchdog`), stand down.

3. **Loop exit non-zero** — diagnose, FIX, re-run the loop. Playbook:
   - *no respawn by deadline* — read `{{STATE_DIR}}/watcher.log`
     (re-verify abort? crash-loop/slow-grind tripped?); address the
     cause or run `{{NEXUS_ROOT}}/monitor/watcher/spawn-fresh-orchestrator.sh`.
   - *watcher died* — relaunch immediately:
     `{{NEXUS_ROOT}}/monitor/watcher/launcher.sh --target {{TARGET_WINDOW}}`.
   - *duplicate orchestrator windows* — stand down the duplicate per
     the watcher's recovery prompt; NEVER kill the watcher.
   - *cold spawn (pin stale)* — if the prior session's jsonl exists,
     re-pin the correct sid, kill the cold window, let the watcher
     respawn with `--resume`; if truly gone, brief the cold
     orchestrator with the latest `reports/` and the fact it was
     cold-spawned mid-bump.
   - *anything unenumerated* — fix it if confident; otherwise
     `sandbox-notify` LOUDLY and hold the workspace stable.

4. Never exit leaving the workspace agent-less without a loud
   notification. Report LAST, then stand down.

Footguns: never `pkill -f`/`pgrep -f` (sandbox-wide mass-kill); kill
only by recorded PID or exact tmux window target.
