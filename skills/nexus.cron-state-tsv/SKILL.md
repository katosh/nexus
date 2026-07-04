---
description: "Durable session-state for harness CronCreate-driven recurring agents: TSV state file + recovery-marker pattern so a respawned orchestrator can re-instantiate a cron without losing fire count."
---

# nexus.cron-state-tsv — durable state for recurring crons

TRIGGER when: orchestrator schedules a long-running recurring task via the Claude Code harness's `CronCreate` (e.g., a watcher-health monitor, a periodic external poll, any agent that fires N times over hours/days); needs to track fire count, deadlines, or recovery semantics across an orchestrator respawn.

## The pattern

A harness-level cron run by `CronCreate` is identified only by an opaque cron ID. The harness doesn't persist user-meaningful state between fires — and on an orchestrator respawn, the cron survives but the orchestrator has no memory of what fire it's on, when it started, or when it should stop.

To make the cron's prompt **fully self-contained**, write a small TSV state file under `monitor/.state/` whose path the prompt itself references. Each fire reads the prior row, updates it, and writes the new row. A respawned orchestrator points at the same file and resumes mid-sequence.

### Schema (minimum)

```
created_at<TAB>fire_count<TAB>cron_id<TAB>target_fires
```

| column | meaning |
|---|---|
| `created_at` | ISO 8601 timestamp the cron was first instantiated. Lets a respawned orchestrator detect a cron whose window has already closed (created_at + duration < now). |
| `fire_count` | Integer, monotonically incremented at the top of each fire's prompt. Bounds the loop; the cron self-cancels when `fire_count >= target_fires`. |
| `cron_id` | The opaque ID returned by `CronCreate`. Needed for `CronDelete` at end-of-window. |
| `target_fires` | The fire count at which the cron should self-cancel. `(end_time - created_at) / interval`. |

Extension columns (add as needed, keep them tab-separated): `last_decision`, `last_check_target_id`, `escalation_count`, etc. Keep the schema documented at the top of the cron's prompt — the file is the single source of truth and the prompt is the only reader.

### File location

```
monitor/.state/<cron-purpose>.state
```

e.g., `monitor/.state/watcher-health-cron.state`. Beside it, the recovery marker (next section): `monitor/.state/<cron-purpose>.state.recreate-note.md`.

## Recovery marker — workaround for `CronCreate durable: true`

The Claude Code harness's `CronCreate` accepts a `durable: true` flag that documents "this cron survives an orchestrator session reset." Empirically (verified on <other-operator>'s 24h watcher-health monitor, 2026-05-26→27) **the flag is silently ignored**: a session that respawns mid-window loses the cron registration and never re-fires.

This is an upstream harness bug, not a nexus issue (see memory rule `[[upstream-quirks-not-nexus]]`). The workaround pattern that does work:

1. **Write a recovery-marker file** alongside the state TSV at instantiation time:

   ```
   monitor/.state/<cron-purpose>.state.recreate-note.md
   ```

   Contents: a literal prompt the respawned orchestrator can read and act on. Include the `CronCreate` invocation it should re-run, the state-file path, and the bookkeeping rule ("read fire_count from row 2; if < target_fires, re-create the cron with the original interval and resume").

2. **Orchestrator bootstrap reads the marker.** On every fresh-spawn, the orchestrator's startup prompt grep's `monitor/.state/` for `*.recreate-note.md` files. For each, it reads the marker, checks the state TSV's `fire_count < target_fires`, and re-issues `CronCreate` if the window is still open.

3. **The recreated cron uses the same state file**, so `fire_count` continues monotonically.

4. **End-of-window cleanup deletes both files** plus runs `CronDelete <cron_id>`.

## Worked example — `watcher-health-cron`

Operator on `<your-org>/<other-nexus>#9` ran a 24h monitoring window over `<other-nexus>` watcher health. State TSV at `monitor/.state/watcher-health-cron.state`:

```
created_at	fire_count	cron_id	target_fires
2026-05-26T14:32:00Z	22	abc123	24
```

Per-fire prompt logic (paraphrased — the literal prompt was the cron's `prompt` arg to `CronCreate`):

1. Read row 2 of the state file.
2. If `fire_count >= target_fires`, delete the cron via `CronDelete cron_id`, remove the state + recovery-marker files, post a wrap-up comment. Exit.
3. Otherwise: do the per-fire work (in their case, "check the watcher's most recent emit and verify the bot reacted within 7 minutes; flag if not").
4. Increment `fire_count`, rewrite row 2 atomically (tmp + rename).

The empirical case study from fire 22 (per the operator's report on `<other-nexus>#9`): the cron's functional check caught a stale comment (`4567434094` on `<other-nexus>#10`) approximately 7 minutes after posting, and the orchestrator forwarded it to its `he-embeddings` worker before the (then-unfixed) staleness regression would have surfaced it via the watcher. That's the load-bearing value of a cron-state TSV: a periodic external check whose own bookkeeping survives the orchestrator's lifecycle.

## When to use this pattern vs. just sticking the cadence in a worker

| You want | Use |
|---|---|
| Recurring fires every M minutes over hours/days, with bounded total count | `CronCreate` + this TSV pattern |
| One-shot delayed reaction (e.g., "in 20 minutes, check X once") | `ScheduleWakeup` from inside a `/loop`, no state file needed |
| Continuous polling while the orchestrator is up, dies when it dies | A registered task in `monitor/watcher/_scheduler.sh`, no harness cron at all |

The cron-state TSV is overkill for anything that fits the second or third row. Reach for it only when the work genuinely needs to outlive the orchestrator's session AND requires per-fire bookkeeping.

## Atomicity & robustness

- **Write the TSV via tmp + rename.** `printf … > file.tmp.$$ && mv file.tmp.$$ file`. A torn write that crashes mid-update leaves the prior row intact and the next fire continues.
- **Treat the file as append-only for audit, mutable only on row 2** if you want both a running count and a history. Append-only-only is simpler if the only invariant you need is "highest fire_count seen wins."
- **Recovery-marker is read-only after instantiation.** The orchestrator never edits it; on bootstrap it either re-creates the cron (window still open) or removes the marker (window closed).
- **A missing state file on a fresh respawn means "first fire" semantics.** Don't crash; treat it as `fire_count=0` and write the schema header.

## Cross-references

- `[[nexus.report]]` — long-running async work (multi-day, multi-fire crons) should leave a final report at end-of-window. The cron's last fire can call `monitor/ng wrap-up` against its tracking issue.
- `monitor/README.md` — overall monitor / watcher architecture. The TSV pattern complements, doesn't replace, the watcher's own state files under `monitor/.state/`.
- Upstream-quirk pointer: the silent-ignore of `CronCreate durable: true` is a Claude Code harness issue. File upstream when you encounter it; don't add nexus-side workarounds beyond this pattern.
