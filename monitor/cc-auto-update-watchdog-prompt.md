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
  **YOU ARE ON A CLOCK AND IT STARTED WHEN YOU SPAWNED.** The apply
  script waits `CC_AUTO_ARM_WAIT_SECONDS` — **600 s by default** — for
  the armed marker to appear, then ABORTS the whole orchestrator
  restart. Nothing warns you as it drains. Reading logs, checking
  state, orienting — exactly what a careful agent does first — spends
  that budget, and on 2026-09-03 a watchdog arrived with **60 seconds
  left** (<your-org>/nexus-code#1400). Arming takes one command and is
  reversible; orienting before it is not.
- **Run the watch loop yourself** — deterministic, in your own
  context, NO nested subagent. Run it as one long-running Bash command
  and burn zero tokens while it runs; inference engages only when the
  loop exits.

## The job

1. Start the shipped watch loop IMMEDIATELY (it records the baseline
   and writes the armed marker itself; the apply script kills the
   orchestrator only after the marker appears):

       NEXUS_ROOT={{NEXUS_ROOT}} CC_AUTO_TARGET_WINDOW='{{TARGET_WINDOW}}' \
           WATCHDOG_ATTEMPT='{{ATTEMPT}}' WATCHDOG_DEADLINE_SECONDS=180 \
           {{NEXUS_ROOT}}/monitor/cc-restart-watchdog-loop.sh

   It logs to `{{STATE_DIR}}/restart-watchdog.log` and verifies:
   exactly one `{{TARGET_WINDOW}}` window, no stand-down window, the
   watcher pid alive, the session pin unchanged, and a fresh jsonl
   record stamped `"version":"{{CANDIDATE}}"` past the baseline offset
   (polled, never one-shot).

2. **Loop exit 0** — verified. `sandbox-notify` a one-liner, write the
   report (`monitor/ng report-init cc-restart-watchdog`), stand down.

3. **Loop exit non-zero** — diagnose, FIX, re-run the loop.
   **Once the kill has happened, re-run it as a verify, exactly this:**

       NEXUS_ROOT={{NEXUS_ROOT}} CC_AUTO_TARGET_WINDOW='{{TARGET_WINDOW}}' \
           WATCHDOG_DEADLINE_SECONDS=180 \
           {{NEXUS_ROOT}}/monitor/cc-restart-watchdog-loop.sh --verify-only --attempt '{{ATTEMPT}}'

   The attempt is THIS restart's own, minted by the apply script and
   handed to you here. Do not look it up in `restart-watchdog.log`: that
   log is append-only across days, and on a day of repeated attempts an
   earlier attempt's line is what a search returns.
   You know the kill has happened when the loop you just ran printed
   `old orchestrator pid … gone` in its own output.
   - `--verify-only` verifies against the baseline that attempt
     persisted. A plain re-run after the kill baselines the REPLACEMENT
     orchestrator, and reports `orchestrator was never killed` about a
     healthy respawn.
   - **Exit 2:** no `--attempt` was given.
   - **Exit 10:** the baseline orchestrator is still alive, so nothing
     was killed.
   - **Exit 13:** the persisted baseline is not your run's: another
     attempt's, stale, or naming another candidate. Override it only
     with `--base-size N` taken from your own run's `armed:` line.

   Playbook:
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

4. **ROLLBACK is available, and it is a last resort, not a first one**
   (`<your-org>/nexus-code#1492`). If the workspace cannot be brought
   back to health ON the new binary, you may restore the previous pin:

       {{NEXUS_ROOT}}/monitor/cc-auto-update-apply.sh rollback \
           --reason "<what you observed, specifically>"

   It restores the pin, reinstalls, VERIFIES the binary reports the
   restored version, and writes a restart-hold so the reconcile cannot
   re-apply behind you. Exit 3 is a REFUSAL (no breadcrumb, or a torn
   one) — it is not a finding that the pin is already fine; read the
   message and do not retry blind.

   **Try forward repair FIRST.** Your mandate is to reach a healthy
   board on the new binary, and most of the playbook above gets there.
   Roll back when you have a *named* reason the new binary cannot work
   — and say what it was, because that reason is the next issue to
   file. **Rolling back does NOT restore a killed agent's context**;
   nothing does. If a worker was lost, say so loudly rather than
   letting the restored pin read as a clean recovery.

5. Never exit leaving the workspace agent-less without a loud
   notification. Report LAST, then stand down.

Footguns: never `pkill -f`/`pgrep -f` (sandbox-wide mass-kill); kill
only by recorded PID or exact tmux window target.
