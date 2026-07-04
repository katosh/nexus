# Troubleshooting

The common failure modes, each with the verbatim symptom you see, the cause, the fix, and the prevention path that retires the friction at its source. New failure modes get appended here; resolved infrastructure friction lives in [`monitor/infra-resolved.md`](https://github.com/<your-org>/nexus-code/blob/main/monitor/infra-resolved.md).

When something feels off but doesn't match an entry below, the first three places to look:

1. `tail monitor/.state/watcher-alerts.log` — rate-limit and GraphQL failure surface.
2. `tail monitor/.state/watcher.log` — watcher startup, emits, paste failures, respawns.
3. `monitor/ng watcher-status` — one-shot liveness summary.

---

## `ng wrap-up` rejects the report

**Symptom.**

```text
$ monitor/ng wrap-up 42 reports/nexus_2026-05-11_...md ...
ng: report-check failed: missing section: How to Resume
```

or

```text
ng: report-check failed: body length 320 below threshold 500
```

**Cause.** `ng wrap-up` runs `ng report-check` as a pre-flight (see [Reports](reports.md#ng-report-check)). The report is missing one of the five required sections, contains placeholder text (`TODO`, `FIXME`, `<...>`), or its body is shorter than `monitor.report_min_chars` (default 500).

**Fix.** Open the report file and expand the flagged section. Re-run `ng wrap-up` — it picks up the edited file.

**Prevention.** Start every report via `monitor/ng report-init <slug>`. The skeleton has every required section in the right place; you fill in content, not structure. If you're checkpointing intentionally and the body is legitimately stub-shaped, `ng wrap-up --allow-stub` forwards `--allow-todo` to the check.

---

## Watcher silent; eligible comments aren't surfacing

**Symptom.** You post a comment on the overview issue, GitHub's own push notification doesn't fire (because the bot hasn't reacted), and `monitor/ng watcher-status` says `state=fresh`. The watcher is alive, but nothing is happening.

**Cause.** The bot installation's shared GraphQL bucket has exhausted. Typical trigger: ≥ 4 active workers + orchestrator + watcher all minting installation tokens. The watcher's `_snapshot_*` helpers return `graphql_rate_limit` for each surface.

**Fix.** Check `monitor/.state/watcher-alerts.log`:

```bash
tail monitor/.state/watcher-alerts.log
# WARN issue_comments graphql_rate_limit reset=1715432400
```

The watcher writes a backoff file at `monitor/.state/graphql-backoff-<surface>` and emits a `watcher_alert=rate-limit` sentinel into the orchestrator's pane. Subsequent polls short-circuit until `reset + 30 s`. The deliveries surface (App-JWT, separate bucket) keeps surfacing comments during the backoff window — so if any of the watcher's three surfaces is healthy, eligible comments still flow.

**Prevention.** The detect-and-react path was added after a 2-h-17-min silent stall on 2026-05-01. Older watchers swallowed the error via `2>/dev/null` and stayed silently productive. If you've forked an old branch, pull the current `_github.sh` and the alerts log machinery.

---

## Watcher paste hits the wrong window

**Symptom.** The watcher's structured report appears in some other tmux window — usually a worker — rather than the orchestrator. Worker windows show "=== nexus state changed at ..." lines they shouldn't.

**Cause.** The configured `monitor.target_window` (default `orchestrator`) doesn't match the orchestrator's actual window name. Or the orchestrator's window got renamed (tmux's `automatic-rename` can flip an idle window name based on the running command name; the orchestrator's session-pin hook now sets `automatic-rename off` on first turn to immunize against this).

**Fix.**

```bash
tmux list-windows
# 0: services
# 1: orchestrator*    ← orchestrator should be here
# 2: kompot-fig3
# ...

cat monitor/.state/watcher-target  # what the watcher thinks the target is
```

If they don't match, restart the watcher with the right target:

```bash
monitor/svc.sh stop watcher
monitor/watcher/launcher.sh --target <actual-orchestrator-window>
```

**Prevention.** Don't rename the orchestrator's window. The default name `orchestrator` is what the launcher and the watcher both expect; if you must rename, override consistently via `MONITOR_TARGET` or `monitor.target_window` in `config/nexus.yml`.

---

## Bot returns 403 on asset push

**Symptom.**

```text
$ monitor/ng upload reports/...md --issue 42
ng: upload failed: 403 — Resource not accessible by integration
```

**Cause.** The GitHub App is not installed on the asset repo, or the installation lacks **Contents: Read & write** permission on it. `mint-token.sh` minted a token successfully (the App exists), but the token doesn't authorize the requested write.

**Fix.** Run a preflight to confirm:

```bash
monitor/ng preflight $(config/load.sh github.asset_repo)
# bot installed: yes / no
```

If `no`: install the App on the asset repo at <https://github.com/settings/apps/<your-bot-slug>/installations>. If `yes` but writes still 403: open the App's permissions page and grant **Contents: Read & write**, then accept the permission change on the installation page.

**Prevention.** The asset repo and the issue repo are the same repo by default (`github.asset_repo` defaults to `github.repo`). If you split them, run `ng preflight` on both as part of first-time install verification.

---

## Worker stuck on permission prompt

**Symptom.** A worker's pane shows Claude Code's *Allow / Deny* dialog; no progress for cycles. The watcher's `--- idle workers ---` section emits the window as `no-wrap-up`, then eventually `idle-too-long`.

**Cause.** The worker invoked a tool that needs explicit permission, and the auto-Enter path didn't catch it — usually because `MONITOR_AUTO_UNSTICK=false`, or because the prompt fingerprint diverged from what `_unstick.sh` detects.

**Fix.** Look at the unstick log:

```bash
tail monitor/.state/watcher-unstick.log
# window=worker-foo case=A action=sent-Enter fp=...
```

A line per Enter-send means the watcher tried; check the worker's pane to see if the prompt cleared. If the watcher hasn't logged anything for the window, send Enter manually:

```bash
tmux send-keys -t worker-foo Enter
```

**Prevention.** Default `monitor.watcher.auto_unstick` to `true` (the shipped default). If `_unstick.sh` keeps missing a prompt shape, update `monitor/pane-state.sh`'s detection markers (`_detect_user_typing` / `_detect_busy`) and re-run the unit tests under `monitor/watcher/test-*.sh`.

---

## Orchestrator's `last-ack.txt` is stuck

**Symptom.** The orchestrator's `bootstrap.sh` prints catch-up diffs on every wake — the same diffs each time. `monitor/.state/last-ack.txt` mtime doesn't advance.

**Cause.** Two paths:

1. `bootstrap.sh` was invoked with `--no-update-ack` (a debugging flag).
2. The filesystem refused the `touch` — wrong perms, NFS silly-rename, full disk.

**Fix.**

```bash
ls -la monitor/.state/last-ack.txt
# Verify writable, sensible mtime, not gone.

date -Is > monitor/.state/last-ack.txt   # manual advance
```

Then check perms (`chmod u+w monitor/.state/last-ack.txt` if needed) and disk space (`df -h $(config/load.sh nexus.root)`).

**Prevention.** Don't pass `--no-update-ack` outside a debugging session. The `.gitignore` covers `monitor/.state/`; NFS silly-rename (`.nfs*`) is handled in the workspace `.gitignore`.

---

## Watcher crash-loop guard tripped

**Symptom.** A `sandbox-notify` push fires once: *"watcher: orchestrator crash-loop suspected; halting respawn attempts (...)"*. After that the watcher goes quiet on respawns even when the orchestrator window is missing.

**Cause.** The watcher respawned the orchestrator more than `monitor.respawn_loop_limit` times (default 3) within `monitor.respawn_loop_window_seconds` (default 120 s). A fresh orchestrator keeps wedging on the same condition that killed its predecessor — bad config, missing env var, an unhandled error in the launch path.

**Fix.** Investigate the wedge condition:

```bash
tail -40 monitor/.state/watcher.log
# Look for the respawn target reason, the immediately preceding error.

tmux capture-pane -t claude -p -S -200
# If a fresh claude is still up, see what it's wedged on.
```

Once fixed, the crash-loop guard clears on the next successful paste-to-target — no manual reset needed. The sliding-window also empties by time as old respawn entries age out.

**Prevention.** The guard exists to stop runaway respawns from masking the underlying bug. If the guard trips often, raise the limit only after the bug is fixed; the default `3 within 120 s` is conservative for a healthy system.

---

## Notifications silently no-op

**Symptom.** `monitor/notify.sh "test" "test"` exits 0. No vibration on the phone, no email, no ntfy push.

**Cause.** `notify.sh` is silent-no-op by design when no backend is configured — so the watcher's `notify.sh` call inside a tight loop doesn't error every cycle in a half-configured deployment. The flip side: misconfigured perms or paths look identical to "no backend".

**Fix.** Re-run with `--require-delivery` to make the helper fail loud:

```bash
monitor/notify.sh "probe" "test" --priority routine --require-delivery
echo $?
```

| Exit | Meaning |
|---|---|
| `0` | At least one backend delivered. |
| `2` | No backend is configured. Check `notifications.pushover.*` or `notifications.ntfy.*` keys in `config/nexus.yml`. |
| `3` | At least one backend was configured but every attempt failed. Common cause: credential files exist with the wrong perms (must be `0600` or `0400`). |
| `4` | Missing `curl` or `python3`. |

Most exit-3 cases are perms. `chmod 600` the credential files and re-probe.

**Prevention.** Run the routine + emergency probes once at first-install (see [Notifications](notifications.md#a-probe-and-check-shape)). The silent-no-op only bites you when something rotated since.

---

## `mint-token.sh` returns empty from a worker's cwd

**Symptom.** A worker logs `mint-token: empty token` or sees `GH_TOKEN=` empty in its environment. `monitor/ng <verb>` exits non-zero with a token-related error.

**Cause.** Older `mint-token.sh` was cwd-sensitive — invoked from a non-nexus-root cwd (e.g. a worktree under `work/<project>/.worktrees/...`), it silently fell through to ambient user `gh` auth or returned empty. The fix landed in PR #30 (2026-04-28); older clones are still affected.

**Fix.** From any cwd, call by absolute path or via the workspace `NEXUS_ROOT`:

```bash
"$NEXUS_ROOT/monitor/mint-token.sh"
# Or: cd "$(config/load.sh nexus.root)" && monitor/mint-token.sh
```

**Prevention.** Pull the current `mint-token.sh` and `config/load.sh` from `<your-org>/nexus-code`'s `main`. The current shape resolves `NEXUS_ROOT` from its own `dirname`, so it works regardless of cwd.

---

## `user-attachments` URL kills image fetches for the session

**Symptom.** A worker reads or hands off a `https://github.com/user-attachments/...` URL. Subsequent image fetches in the same conversation return 400 even when the URL is valid.

**Cause.** External fetcher agents 404 on `user-attachments` URLs (they're viewer-session-scoped). Feeding the failure through Read-as-image returns 400, which silently disables every subsequent image fetch in the conversation. The poison sticks for the whole session.

**Fix.** Don't recover in-session — start a fresh session for the next image-bearing turn.

**Prevention.** Never hand a `user-attachments` URL to a sub-agent or to Read directly. Use `monitor/ng fetch-asset <url>` instead, which reads the user's `gh auth token` PAT (the bot's installation token 404s on this surface) and writes the bytes under `monitor/.state/assets/<asset-id>.<ext>` — then `Read` the local file. The skill source is [`skills/nexus.bot/SKILL.md`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.bot/SKILL.md) "Reading user-pasted assets".

---

## `#N` in a comment auto-links to an unrelated issue

**Symptom.** A numbered list in a bot-posted comment renders as a series of cross-references to existing issues. `1. First item` becomes a link to PR `#1`, `2. Second item` to PR `#2`, etc.

**Cause.** `#N` in a GitHub comment body auto-links to the issue or PR with that number in the *current* repo. Numbered-list markers (`#1`, `#2`) are the most common foot-gun.

**Fix.** Edit the comment to use `1.`, bullets, or `(1)` instead of `#N` as list markers. For cross-repo references use `owner/repo#N`. To render `#N` verbatim, wrap in backticks: `` `#11` ``.

**Prevention.** Worker prompts pull this gotcha in via the `## Worker floor` when the worker authors GitHub markdown. The orchestrator's pre-post lint isn't yet wired in; the rule lives in the workspace `CLAUDE.md` "Common gotchas".

---

## Still stuck?

The infrastructure-issues feedback loop ([Reports](reports.md#the-infrastructure-issues-feedback-loop)) is the durable path for friction that doesn't match any entry above. Open or comment on the [overview issue](dashboard.md) describing what you saw; the orchestrator either spawns a fix-worker or queues the theme for the next periodic review.
