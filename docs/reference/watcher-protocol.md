# Watcher protocol

The watcher (`monitor/watcher/main.sh`) is a long-running bash loop,
hosted as a headless service (no tmux window; see
[Architecture](architecture.md)), that converts a snapshot of local +
GitHub state into a one-shot report pasted into the orchestrator's
tmux window. This page is the protocol spec: what it polls, what it
emits, when it short-circuits, and how it recovers from rate limits
and stuck panes.

For the operator-facing view (how to read its output, when to
restart it, how to debug a silent watcher) see
[`docs/operating/watcher.md`](../operating/watcher.md). For the
architectural framing see [Architecture](architecture.md).

## Poll cycle

There is no single-cadence loop. `main.sh` drives **only** the
per-task priority queue in `_scheduler.sh` (issue
[`#169`](https://github.com/<your-org>/nexus-code/issues/169), now
landed). Each check is a registered task with its own interval; the
scheduler fires every task whose `next_fire` epoch has arrived, then
sleeps until the soonest remaining `next_fire` — capped at
`monitor.scheduler.max_sleep_seconds` (default 10 s) so a
process-level signal is observed within a bounded interval even when
nothing is due. No `sleep INTERVAL`, no fixed 1..N ordering; tasks at
different cadences run independently.

### The scheduler model

`_scheduler_tick` walks the registered task set, fires the due ones,
records `last_fire`/`last_rc`/`elapsed_ms` per task, and recomputes
each fired task's `next_fire`. Cheap tasks run **synchronously** in
the tick; tasks marked `--async` launch a subshell whose stdout is
captured atomically to `<name>.out` under the v2 staging dir, so a
slow GitHub round-trip never holds the sync slot. A task may pull a
peer forward out of band: a missing target window (rc=2) force-fires
`compose_emit`, and new deliveries / a non-empty GraphQL fire nudge
`compose_emit` via `_schedule_fire_now` + a temporary cadence
override. Per-task back-pressure: a task that returns rc=75
(EX_TEMPFAIL) doubles its own interval once.

### Registered tasks and cadences

Intervals as registered in `main.sh` (`_schedule_task` calls). The
last four rows register only when their feature is enabled and the
interval is `> 0`.

| Task | Cadence | Class | Role |
|---|---|---|---|
| `target_window` | 2 s | cheap | `_target_window_present`; orchestrator-absence detection + respawn trigger. Force-fires `compose_emit` on rc=2. |
| `heartbeat` | 5 s | cheap | Bump `monitor/.state/watcher-heartbeat` (pid + ISO ts). |
| `orchestrator_liveness` | 5 s | cheap | `_orchestrator_liveness_step`: pid / pin / last-paste wedge detection. |
| `over_limit_wakes` | 5 s | cheap | `_over_limit_process_wakes`: act on due over-limit wake epochs. |
| `pending_decisions` | 10 s | cheap | Scan `monitor/.state/decisions/*.json`. |
| `detect_unstick` | 10 s | medium | `detect_and_unstick`: per-pane wedge fingerprinting (see [Auto-unstick](#auto-unstick)). |
| `deliveries_poll` | 15 s | medium | `_snapshot_deliveries_raw`: **primary** real-time event source (webhook deliveries, App-JWT bucket). |
| `bell_windows` | 30 s | cheap | List standing bells on non-orchestrator/non-monitor windows. |
| `snapshot_local` | 30 s | medium | `snapshot_local`: `--- reports --- / --- tmux --- / --- git ---`. |
| `idle_section` | 30 s | expensive | `render_idle_section`: idle-worker transitions (see [Idle classifier](#idle-classifier)). |
| `over_limit_scan` | 60 s | expensive | `_over_limit_scan_panes`: probe every pane for the usage-limit footer. |
| `compose_emit` | `monitor.interval_seconds` (default 60 s) | medium | Compose + paste the report if any task staged a signal. |
| `prune_archive` | 600 s | cheap | Delete archived emits older than `monitor.diff_retention_days` (default 7). |
| `github_poll` | 600 s | expensive | `_snapshot_github_raw`: GraphQL **backstop** (bucket-floor gated). |
| `full_state_snap` | 600 s | expensive | `render_full_state_snapshot`: periodic cumulative snapshot. |
| `functional_check` | 600 s | expensive | Bot-reaction wedge detector (see [Functional check](#functional-check)). |
| `cc_version_check` | `monitor.cc_update.interval_seconds` (default 86400 s) | expensive | Detect a newer Claude Code release than the local pin. |
| `version_check` | `monitor.version_restart.interval_seconds` (default 60 s) | medium | Component-drift / restart detection (issue `#186`). |
| `service_health` | `monitor.service_health.interval_seconds` (default 120 s) | medium | Registry-healthcheck watch (see [`--- service health ---`](#startup-sweep)). |

`compose_emit` registers at `monitor.interval_seconds` so the
**steady-state emit cadence** remains the one operator-tunable knob;
the data-gathering tasks above feed it asynchronously, and any of
them can pull it forward when a fresh signal lands.

### What compose_emit does each fire

When `compose_emit` runs it reads the staged task outputs, decides
whether to emit (a signal local diff, OR a non-empty
GitHub/bell/idle/decisions list — the latter re-emits while the
condition holds, the **resurface** mechanism), composes the report,
archives it to `monitor/.state/diffs/<ts>_<shortid>.md`, and pastes
into the target with content-level verification (see
[Paste protocol](#paste-protocol)). The local-state baseline
(`last-snapshot.txt`) is overwritten **only** when there was an
actual local change to absorb — comment-only resurfaces leave the
baseline alone so a fresh local change can't be masked (see
[Resurface and the baseline asymmetry](#resurface-and-the-baseline-asymmetry)).

## Event surfaces

The watcher draws on up to three GitHub-event sources, each its own
scheduled task. **Deliveries (`deliveries_poll`, ~15 s) is the
primary real-time source; GraphQL (`github_poll`, ~600 s) is the
backstop**, and mentions covers the cross-repo gap deliveries can't
reach. Each is gated independently; the same comment surfacing
through multiple paths emits once thanks to the `_dedup_emit_lines`
awk pass that runs when `compose_emit` merges the staged outputs.

### 1. Deliveries (`snapshot_deliveries` in `_deliveries.sh`) — primary

The webhook-delivery path is the **real-time** event surface: it
fires on its own 15 s `deliveries_poll` task, on a **separate**
rate-limit bucket (App-level JWT), so it keeps surfacing comments
while the GraphQL installation bucket is exhausted. Gated by
`monitor.deliveries.asset_enabled` / `monitor.deliveries.bot_mention_enabled`
(both default true); surfaces once the App's webhook URL is configured.

It polls `/app/hook/deliveries` — the App's own webhook delivery
log. The cursor file `monitor/.state/last-delivery-cursor.txt`
stores the newest GUID seen on the previous poll. Each poll walks
pages newest-first until that GUID is reached (or
`DELIVERIES_MAX_PAGES` pages have been visited; default 5 × 100 =
500 deliveries). A 404 from `/app/hook/deliveries` means the App has
no webhook URL configured — logged once per day, then silent.

Eligibility (per delivery):

1. Event type ∈ {`issue_comment`, `pull_request_review_comment`,
   `pull_request_review`, `issues`, `pull_request`}.
2. Action ∈ {`created` for comment events, `submitted` for review,
   `opened` for issues/PRs}. Edits and deletes are ignored.
3. Comment id not in `monitor/.state/processed-comments.txt`
   (cross-source dedup).
4. Author is `github.user_login`. Enforced by the
   `_filter_to_user_author` chokepoint downstream (issue #86) — the
   source itself emits every delivery that passes the event-type and
   dedup gates and the chokepoint drops everything not authored by
   the user.
5. EYES/ROCKET reactions are **not** checked here — webhook payloads
   don't carry them. The downstream `ng process` re-checks reactions
   before posting EYES, and the parallel GraphQL path surfaces the
   live reaction state. A self-rocket landing after delivery will
   surface once before being filtered out.

In-repo deliveries emit the same shapes as the GraphQL path
(`issue=`, `pr=`, etc.). Cross-repo deliveries (user posted in
another repo where the App is installed) emit the
`mention=<owner>/<repo> kind=... n=... id=... author=...` shape —
the only one carrying explicit repo provenance.

### 2. GraphQL polling (`snapshot_github` in `_github.sh`) — backstop

Authenticated with the bot **installation token** (one-hour-lived,
cached at `github.bot_token_cache`). Three sub-queries against the
GraphQL `search` endpoint, all scoped to the configured repo:

| Helper | Line shape |
|---|---|
| `_snapshot_issue_comments` | `issue=<n> id=<cid> author=<login>` |
| `_snapshot_pr_comments` | `pr=<n> id=<cid> author=<login>` |
| `_snapshot_pr_comments` (review threads) | `pr_review=<n> id=<cid> author=<login> path=<file>` |
| `_snapshot_new_issues` | `issue_new=<n> id=<n> author=<login>` |

Each header line is followed by a `  body: <preview, ≤ 400 chars>`
line. The four shapes share the same `id=` dedup key, so a parser
that only looks for `id=<x>` works across all of them.

The backstop runs on its own 600 s `github_poll` task, so the
schedule interval — not a `cycle % cadence` counter — sets the
GraphQL cadence. Before any call goes out the task consults
`_graphql_polling_gate`, now a single **bucket-floor** check: probe
`gh api /rate_limit` (free, REST core) and skip the fire if
`graphql.remaining < monitor.graphql_threshold` (default 200),
leaving headroom for orchestrator + worker writes. The legacy
`monitor.graphql_cadence` knob is gone — the deliveries path
(separate App-JWT bucket) carries real-time surfacing, so GraphQL
needs only the slow backstop interval.

Probe failure (network glitch, malformed JSON) prefers skip plus one
throttled line in `watcher-alerts.log` (once per 10 min per
failure-class) — better to lose a backstop poll than to churn against
an unhealthy bucket.

### 3. Mentions (`snapshot_mentions` in `_mentions.sh`)

Surfaces cross-repo activity that mentions `github.user_login` in
repos where the App is NOT installed — the gap deliveries can't
reach. Enabled by `monitor.mentions_enabled: true`.

Uses GraphQL `search` with the `mentions:<user_login>` qualifier
(`mentions:<bot_login>` does not index `[bot]` accounts — confirmed
by direct probe). Skips `github.repo` and any repo in the
bot-installed-repos cache (`monitor/.state/bot-installed-repos.txt`,
refreshed at most once per 24 h via `/installation/repositories`).

Emits a distinct `cross_repo=<owner>/<repo> kind=<issue|pr> n=<n>
id=<id> author=<login> [src=body]` shape so the orchestrator can
treat these as read-only context (the bot cannot reply without
installation on the source repo). `src=body` distinguishes the rare
issue-body mention from the common comment mention.

## Eligibility filter

A comment surfaces only when **all** of:

- `comment.author.login == github.user_login` — account-based author
  match. Bot-authored comments are excluded by the same filter, so
  no body-prefix convention is needed or honoured.
- No `EYES` (👀) reaction by a login other than the user. The bot's
  EYES means "processing"; once placed by `ng process`, the comment
  stops resurfacing.
- No `ROCKET` (🚀) reaction from any login. The bot's ROCKET means
  "action taken"; a self-ROCKET by the user is the mobile-friendly
  one-tap "skip this".

The filter is enforced inside `_github.sh`'s GraphQL queries via a
jq filter on the reactions array, so ineligible comments never
reach the awk dedup pass. Bot-side reactions are observed regardless
of who placed them, but the user's own EYES is benign (the user
might double-tap on mobile) — only EYES placed by a login other
than the user excludes the comment.

Eight reaction types exist on GitHub; three carry meaning in this
protocol:

| Reaction | From bot | From user (on their own comment) |
|---|---|---|
| `eyes` (👀) | "processing" — excludes from future polls | benign; user might double-tap |
| `rocket` (🚀) | "action taken" — excludes from future polls | "skip this" — one-tap opt-out |
| (anything else) | no semantic effect | no semantic effect |

## Signal vs noise

Not every local-state diff warrants paging the orchestrator.
`_classify_diff` in `_lib.sh` walks the unified-diff body and
classifies each line by shape, falling back to the section marker
when the diff context window dropped the header. Two noise kinds
are blanket-suppressed:

- **`--- git ---` section changes.** Clean↔dirty flips, SHA bumps
  on clean-clean (post-push, post-merge), mid-dirty hash bumps,
  project add/remove. None are actionable in isolation — the
  orchestrator gets git provenance via reports anyway.
- **`*-interim*.md` additions/removals** under `--- reports ---`.
  Interim reports are progress breadcrumbs; they archive but don't
  page. Final reports (no `-interim` in the basename) remain
  signal.

Everything else is signal:

- `--- tmux ---` lines (window add/remove, bell flag flip).
- Final `reports/*.md` additions, removals, and renames.
- Unknown sections, malformed lines, parse failures — the classifier
  fails open toward signal. Losing a real emit is worse than pasting
  a borderline one.

Pure-noise cycles advance the baseline (`last-snapshot.txt`) so the
same noise doesn't recur, write one log line, and **do not paste**.
Comment-only resurfaces and bell-only emits bypass the classifier —
the GitHub list and standing-bell list are always signal.

## Emit classes

`compose_report` renders a named section for each non-empty input,
in a fixed top-to-bottom order. Most are scoped to the per-cycle
observation; a few are **standing** conditions (self-clearing the
instant the condition resolves) pinned high because they describe
infrastructure health the operator must not miss.

| Section | When | Notes |
|---|---|---|
| `--- watcher revived (was down) ---` | the supervisor revived a crashed watcher | Self-failure report. The watcher can't report its own death, so its first emit after revival surfaces the `watcher-revived` marker, then clears it. Pinned at the very top. |
| `--- arm watcher supervisor ---` | the supervisor heartbeat is stale/absent | Standing reminder (`_supervisor_arm_emit_section`): an unarmed supervisor means a watcher crash has no turn-independent revival. Body is intentionally stable so emit-dedup collapses repeats; self-clears the instant the Monitor is armed. |
| `--- install failure ---` | project-local Claude Code install failed at startup | Startup sweep only; flag file consumed on first emit. |
| `--- watcher hosting migration ---` | watcher started legacy window-hosted | Startup sweep only; at most once per watcher lifecycle. |
| `--- component drift (restart needed) ---` | a nexus-code component changed on disk and its restart needs the orchestrator | Every cycle; only the *asks* surface (automated restarts don't). Re-nag-guarded per candidate hash. |
| `--- service health ---` | a registered infra service failed its healthcheck | Every cycle; full state always reported. See [Startup sweep](#startup-sweep). |
| `--- claude code update available ---` | a newer release than the local pin | GATED advisory; surfaced once per candidate. |
| `<local diff>` | a signal local-state diff | Unified diff, ≤ 120 lines. |
| `--- eligible github comments ---` | non-empty eligible-comment list | Per-cycle; resurfaces while non-empty. |
| `--- standing bells ---` | non-empty bell list | Per-cycle; cleared after emit. |
| `--- pending decisions ---` | a worker/relay wrote a decision record | Structured per-decision channel (issue `#129`), sourced from `monitor/.state/decisions/*.json`. Ack = orchestrator removes the cited file once answered. Also the relay sink for Case W (see [Auto-unstick](#auto-unstick)). |
| `--- idle workers ---` | non-empty idle-transition list | Per-cycle; emitted on transitions only. |
| `--- workspace snapshot ---` | periodic full-state cadence | Cumulative view between transition emits. |
| `--- dashboard ---` | always | Footer; "stale" advisory only at age ≥ 2 h. |

The **idle-workers** section names a state about other tmux windows
and deserves its own classifier vocabulary.

### Idle classifier

`_idle_probe.sh` enumerates worker windows (everything except
`watcher`, `claude`, `orchestrator`, `monitor`) and classifies each
whose **engagement-anchored** idle age has crossed
`monitor.idle_threshold_seconds` (default 60) AND whose
`monitor/pane-state.sh` reports an idle-shaped state
(`idle | autosuggest-only`; `absent | blocked` short-circuit to
`pane-absent`; `over-limit` bypasses the age gate entirely).

The wrap-up-derived core — the first three are mutually exclusive
based on wrap-up state; the fourth overrides all of them at the
hard-close threshold:

| Class | Trigger | Line shape | Orchestrator action |
|---|---|---|---|
| `wrapped` | `wrap-up` action-log entry for this window AND `ng report-check` passes on the cited report | `<window> wrapped up (idle <age>; wrap-up logged)` | Consider close per `nexus.window-cleanup` (retention overrides still apply) |
| `wrapped-but-stub` | wrap-up entry exists but report-check fails | `<window> wrapped-but-stub (<missing-fields>)` | Paste finish-and-expand template; re-check next wake |
| `no-wrap-up` | really idle, no matching wrap-up event | `<window> idle <age> WITHOUT wrap-up — consider follow-up paste` | Paste wrap-up-missing template; re-check next wake |
| `idle-too-long` | age ≥ `monitor.idle_close_hours` (default 24 h) | `<window> idle-too-long <age> (exceeds close threshold; consider close)` | Strong default-to-close; retention overrides still apply |

The `idle-too-long` bucket overrides whatever class the first three
checks would have produced. Detail from a stub finding is preserved
so the orchestrator still has the report-check hint on the
strong-close path.

Beyond the wrap-up core, the classifier also emits `pane-absent`,
`over-limit`, `operator-engaged`, `engaged-close-reminder`,
`paste-unconfirmed`, `idle-orphan-async`, and the `retained` footer.
The full vocabulary with triggers and inviolability rules is
[Worker states](worker-states.md); the authoritative lifecycle
diagram is
[`monitor/docs/agent-state-machine.md`](https://github.com/<your-org>/nexus-code/blob/main/monitor/docs/agent-state-machine.md).

Wrap-up matching has two modes, priority-ordered, in
`_idle_window_wrap_up_report`:

1. **Authoritative** — `window` field on the action-log event
   matches the target window exactly. Recorded by `ng wrap-up` from
   `$TMUX` at runtime; no false positives.
2. **Basename heuristic** — back-compat for pre-#109 entries that
   lack a `window` field. Matches the report basename against
   project-slot (`<window>_<ts>_<slug>.md`) and slug-slot
   (`<project>_<ts>_*<window>*.md`) patterns.

The newest matching entry wins (the scan walks the action log
newest-first via `tac`).

### Transition dedup

`list_idle_transitions` diffs this cycle's `(window, class)` set
against the previous cycle's set (stored at
`monitor/.state/idle-state.tsv`) and emits only NEW transitions:

- `NOT_IDLE → IDLE_*` — emit (worker just went silent)
- `IDLE_NO_WRAP_UP → IDLE_WRAPPED` — emit (worker landed wrap-up)
- `IDLE_* → NOT_IDLE` — no emit (worker is busy again)
- `IDLE_X → IDLE_X` — no emit (stable)

The detail column (e.g. the missing-fields summary on a stub) does
NOT gate the diff — a stub finding whose detail string changed
between cycles is still the same `(window, class)` state and
re-emitting it would be noise.

## Resurface and the baseline asymmetry

The watcher emits on every poll while the GitHub list, the bell
list, or an idle transition is non-empty — not only on the cycle
where the condition first appeared. This is the **resurface
mechanism**: a comment the orchestrator missed on its first emit
(paste-buffer race, inattention, mid-tool-use) reappears next cycle
and keeps reappearing until EYES/ROCKET makes it ineligible.

The corresponding subtlety: the local-state baseline
(`last-snapshot.txt`) is overwritten **only** when there was an
actual local diff to absorb. A comment-only resurface leaves the
baseline alone — overwriting it would silently absorb any fresh
local change that's about to appear at the next poll, masking it.
The symmetry-breaker in main.sh is "did this poll change LOCAL
state", not "did we emit".

## Paste protocol

Each emit ends with a unique trailer:

```
--- nexus-emit-sig <iso-timestamp> <6-char-hex-nonce> ---
```

The trailer is content-level verification: after `paste-buffer` +
`Enter`, `paste_to_target` greps the captured pane for the
`nexus-emit-sig <ts> <nonce>` substring. If absent, the paste
didn't land — `paste_with_retry` triggers a second attempt with a
500 ms delay. Return-code map:

| Code | Meaning | Treatment |
|---|---|---|
| 0 | pasted, submitted, signature verified | clear respawn history |
| 1 | tmux not installed | archive only; can't classify further |
| 2 | target window absent | poll-level respawn path handles it |
| 3 | tmux API call failed | retry once with 500 ms sleep |
| 4 | submitted but signature not visible | retry once (VI-mode hazard) |

### VI-mode hardening

Claude Code uses VI keybindings. A paste arriving in normal mode
is interpreted as commands — content is lost. Before every paste
the watcher sends `i` + BSpace, which leaves the target in insert
mode regardless of starting state:

- From insert mode: `i` inserts a literal `i`, BSpace deletes it.
  Net: no buffer change, still in insert mode.
- From normal mode: `i` enters insert mode, BSpace is a no-op on
  an empty buffer (or deletes one char of pre-existing text, which
  is unlikely on an agent target). Net: now in insert mode.

The alternative `Escape` + `i` was rejected because `Escape` has
real side effects in the Claude Code REPL (cancels menus, can
abort mid-turn generation).

## Auto-unstick

`detect_and_unstick` in `_unstick.sh` runs as the `detect_unstick`
task (10 s cadence, when `monitor.watcher.auto_unstick` is true) and
walks every tmux window, skipping `$WATCHER_WINDOW` (the headless
watcher has no window of its own, so nothing is skipped; a legacy
windowed watcher skips its own host window). Five cases,
fingerprinted independently. Detection ordering matters: Case D
(AskUserQuestion) and the rate-limit fingerprint are both matched
**before** Case A, because Case A's `❯ N.` permission-chevron pattern
would otherwise auto-Enter the first option of the wrong dialog.

### Case A — permission prompt

Even with `--dangerously-skip-permissions`, Claude Code prompts on
certain command shapes (paths outside the project, mount/dev
commands, …). The prompt looks like:

```
Do you want to proceed?
❯ 1. Yes
  2. Yes, and allow access to ...
  3. No
```

Default option is highlighted; Enter accepts. The watcher sends
Enter directly. The per-prompt fingerprint (via
`_unstick_fingerprint`) plus a tries counter back off after one
retry to avoid hammering an unresponsive prompt. Audit trail: a
copy of the pre-action pane capture is saved under
`monitor/.state/unstick/<window>.permission.<fp>.audit`.

### Case B — rate-limit prompt (Claude.ai)

The rate-limit menu has the title `What do you want to do?` and a
`Stop and wait for limit to reset` option. Case B is treated as a
session-wide event rather than a per-window action:

1. **Probe** the Anthropic API (when
   `monitor.watcher.ratelimit_probe` is true AND
   `ANTHROPIC_API_KEY` is set in env) for the unified-reset header
   to learn when the limit will reset. Fallback to a heuristic of
   `monitor.watcher.ratelimit_heuristic_minutes` (default 30 min)
   from now.
2. **Wait.** Detection lines log on first sight per window; the
   waiting log throttles to once per 5 min.
3. **Cascade.** Once the reset epoch passes, walk every stuck
   window EXCEPT the watcher AND the orchestrator: Enter to
   dismiss the menu, then a paste-buffer of "Please continue with
   your task. The API rate limit has reset." + Enter.
4. **Heads-up.** Paste a separate message into the orchestrator
   target naming the unstuck windows and asking it to verify each
   is making progress, then to log `ratelimit-resume-ack` to the
   action log.
5. **Verify.** `_check_orchestrator_ack` runs at the top of every
   subsequent `detect_and_unstick` and looks for the ack in
   `action-log.jsonl`. If `monitor.watcher.ratelimit_ack_timeout_s`
   seconds pass with no ack, the watcher logs
   `case=B action=orchestrator-unresponsive` so the operator can
   intervene.

Asymmetry rationale: case A's permission prompt resolves on a
single keypress, so the watcher acts directly. Case B is a
session-wide event affecting many windows simultaneously and needs
the orchestrator to verify progress, so the watcher fans out then
hands off.

### Case C — transient API error

Claude Code occasionally lands on a per-turn API failure (most
commonly `Internal server error`, type `api_error`) that wedges
the input prompt with the JSON error chip rendered just below the
`⏺` arrow. Pressing Enter on this idle prompt nudges Claude Code
to retry the failed turn.

The watcher fingerprints the chip via `_unstick_fingerprint_api_error`
(hashing the lines containing `API Error`, `"type":"api_error"`,
`Internal server error`, `"request_id"`) and sends Enter. A
per-(window, fingerprint) backoff of
`monitor.watcher.api_error_backoff_minutes` (default 30) prevents
hammering a chronically broken endpoint — same fingerprint within
the window is logged once per cycle as `case=C action=skip-backoff`
and skipped. Distinct fingerprints (different request_ids /
messages) and same-fingerprint reappearances after the backoff
elapses re-fire the Enter.

Enter alone is the chosen action; from this idle state Claude Code
retries the failed turn, so a separate "please continue" follow-up
is unnecessary today.

### Case D — AskUserQuestion overlay on the orchestrator

A blocking `AskUserQuestion` chip-bar modal on the **orchestrator
window** (TARGET) intercepts the watcher's paste-buffer push — it
corrupts dialog state, stalls the channel, or feeds Case A's
auto-Enter into selecting an arbitrary option. `_act_askuq` is the
watcher's safety net (Layer B) for orchestrator sessions whose
`PreToolUse` hook in `monitor/orchestrator-settings.json` (Layer A1,
which blocks the orchestrator from ever dispatching AskUserQuestion)
is missing, stale, or corrupt.

Detection combines a **shape** gate (the chip-bar's two final options,
`Type something.` + `Chat about this`) with a **live-ness** gate (the
navigation footer `Esc to cancel` must appear in the bottom few
non-blank lines, where a live overlay always renders it). The
bottom-anchoring discriminates a genuinely-blocking overlay from a
pane that merely *quotes* the literals (a worker summarising TUI
state) — quoted text and the normal REPL chrome push the footer above
the bottom slice.

Action (scoped to the orchestrator window only): capture the pane
(audit), send **Escape** to dismiss the modal, wait 0.5 s, then
meta-paste a message into the now-clean input box explaining what
happened and pointing at `monitor/agent-prompt.md`. Escape is safe
here even though `paste_to_target` rejects it elsewhere — its only
side effect is cancelling mid-generation, which by construction
can't apply because the dialog itself is already blocking
generation. Behaviour is tunable via `monitor.watcher.on_dialog`
(default `auto-dismiss`; `skip` / `error` log detection only).

### Case W — worker-blocked-question relay

The same AskUserQuestion detection (shape + bottom-anchored
live-ness) firing on a **non-target** window means a worker or
operator-interactive pane is blocked on a question nobody may be
watching. The orchestrator-specific dismiss-and-paste of Case D is
nonsensical there, so `_act_worker_askuq` takes a different action:
it sends **no keys to the pane**. Instead it synthesizes a
pending-decision record
(`monitor/.state/decisions/<window>.<fp>.json`, kind
`blocked_question`) carrying the parsed question, option list, and
captured pane tail. `render_pending_decisions` surfaces it in the
next emit exactly like a hook-written decision (see the
[`--- pending decisions ---`](#emit-classes) section); the
orchestrator answers on the operator's behalf and acks by removing
the record. This deliberately covers **hookless** panes
(operator-launched interactive windows have no per-spawn Notification
hook, so the decisions channel never fires for them otherwise).

The relay fires only after the overlay has been continuously
observed for `MONITOR_WORKER_ASKUQ_GRACE_SECONDS` (default 300;
`0` disables the relay) — a human mid-answer makes the overlay
vanish and nothing fires. Continuity is mtime-tracked on the
first-seen marker; a sighting gap of more than ~90 s re-arms the
episode and restarts the grace clock.

## Rate-limit handling

Two distinct rate-limit conditions, two different mechanisms.

### GitHub GraphQL bucket exhaustion (detect-and-react)

The bot installation's GraphQL bucket can exhaust under load (4–5
active workers + orchestrator + watcher all minting tokens and
issuing GraphQL calls). Previous behaviour swallowed
`graphql_rate_limit` via `2>/dev/null`, leaving the watcher
silently productive while no eligible comments surfaced — the
2026-05-01 incident silenced the watcher for 2 h 17 m before the
operator noticed.

The current shape captures stderr per call and routes failures
through `_watcher_handle_graphql_failure`:

- **Rate-limit signature** (matches `"RATE_LIMIT"`,
  `"graphql_rate_limit"`, or `API rate limit already exceeded` in
  stderr): write a per-surface backoff file
  `monitor/.state/graphql-backoff-<surface>` containing the reset
  epoch (parsed from `extensions.reset_at_epoch` /
  `extensions.reset_at`, or `now + 15 min` fallback); emit a
  `watcher_alert=rate-limit surface=<surface> reset=<epoch>`
  sentinel line on stdout that rides `_dedup_emit_lines` →
  `compose_report` → `paste_to_target`, so the orchestrator sees the
  alert within one cycle. Subsequent polls short-circuit via
  `_graphql_backoff_active` until `now ≥ reset + 30 s`. Sentinel +
  log dedup via a flag file keyed on `(surface, reset-epoch)`: one
  alert per bucket-exhaustion event, not one per poll. The
  deliveries path (App-JWT, separate bucket) is unaffected.
- **Unknown failure** (non-rate-limit JSON, malformed response,
  empty stderr): no sentinel emit (avoid alert-storm on transient
  noise); one log line per surface per 10 min to
  `monitor/.state/watcher-alerts.log`.

To inspect after a suspected silence, `tail
monitor/.state/watcher-alerts.log` for `WARN <surface>
graphql_rate_limit reset=...` (rate-limit fires) or
`graphql_failure ...` (other failure classes).

### Anthropic API rate limit (cascade)

Different mechanism, different actor — described above under
[Case B](#case-b-rate-limit-prompt-claudeai).

## Functional check

The `functional_check` task (`--async`, 600 s cadence;
`_functional_check.sh`) is a deeper-than-pid wedge detector. It is
orthogonal to the orchestrator-liveness probe: that probe watches
pid / pin / paste-receipt, whereas this one watches whether the bot
actually **reacted** (EYES/ROCKET) to comments the watcher recently
surfaced. Each fire makes one `gh api reactions` call per surfaced
comment in the last few emits — bounded above by
`monitor.functional_max_emits` (default 5) × eligible comments per
emit. The 600 s cadence keeps the cumulative REST cost modest
alongside the `github_poll` backstop.

`_functional_check_decide` returns one of three verdicts:

| Verdict | Meaning | Action |
|---|---|---|
| `healthy` | the bot reacted within the SLA | quiet; row to the TSV state file only |
| `bypass` | workspace quiet (no recent emits / no eligible comments) | quiet; the steady state on an idle workspace |
| `stale` | a recently-surfaced comment went unreacted past `monitor.functional_sla_seconds` (default 600) | log loud + `sandbox-notify`; the operator decides whether to bounce the orchestrator |

A `stale` verdict deliberately does **not** call
`spawn-fresh-orchestrator` — that is reserved for the
pid/heartbeat path, which has a much tighter false-positive budget.
The functional check's role is to surface a wedge the existing state
machine can't see. Set `monitor.functional_sla_seconds: 0`
(`MONITOR_FUNCTIONAL_SLA_SECONDS=0`) to disable the check at the
decide layer (no network call).

## Crash-loop guard

`_respawn_loop_check` in `_lib.sh` bounds the orchestrator-respawn
rate. More than `monitor.respawn_loop_limit` respawns within a
`monitor.respawn_loop_window_seconds` sliding window (defaults 3
within 120 s) pins the watcher into a quiet state and fires one
`sandbox-notify` to the operator on the ok→tripped transition. The
history clears on the next successful paste-to-target verification
(`paste_with_retry` returning 0), OR by time as the sliding window
empties.

The asymmetric "record only if allowed" semantics matter: a wedged
orchestrator can't keep adding entries that push earlier entries
out of the window. Once the limit is hit, the count stays pinned
at the limit until reset by either condition above.

## Single-instance lock

Before the main loop the watcher acquires an exclusive **flock** on
`monitor/.state/nexus-instance.lock` and holds it (an open fd) for its
whole lifetime. This is the state-dir-scoped singleton gate: one
cockpit per `NEXUS_ROOT`. A second start that finds a live holder
refuses (launcher exit `4`, fast-failing before spawn; `main.sh` exit
`4` as the authoritative backstop).

flock is the right primitive here because `agent-sandbox` runs each
cockpit under `bwrap --unshare-pid` — separate pid namespaces and
`/proc`, so the pid-based guards (`watcher.lock`, `watcher.pid`,
`_watcher_pid_is_live_watcher`, the tmux cockpit-peer scan) go blind
across two sandboxes sharing one bind-mounted `monitor/.state/` and
would clobber a live peer. flock keys on the inode, not the pid, so it
crosses the pid-namespace boundary; on the NFSv3 state mount
(`local_lock=none`) lock requests are forwarded to the server's NLM, so
it crosses the host boundary too. A same-host flock auto-releases on
holder death (even SIGKILL), so the only stale class is a *cross-host*
NFS lock whose holding client died without the server's lock manager
reclaiming it, or a same-host lock whose machine *rebooted* since
(detected by a `boot_id` mismatch). Because the blessed self-replace
paths (`launcher.sh --replace`, version-restart self-restart,
`bootstrap-recover`) terminate the prior watcher before the successor
starts, the guard blocks coexistence, never succession.

The lock file's body is advisory diagnostics for the refusal message;
liveness is the flock itself, never the text. Recorded at acquire time
(one writer, `_nexus_instance_lock_metadata`): `pid`, `host`, `boot_id`,
`pid_ns`, `sandbox`, `tmux`, `user`, `nexus_root`, `started_at`. From
that metadata the refusal classifies the situation — `live-local`
(same host + boot, a genuine peer), `stale-reboot` (host rebooted →
holder dead, safe to clear), `live-remote` (peer on another host, live
if up), `unknown` (pre-metadata lock) — and prints both the normal
resolution (use / close / `--replace` the other instance) and the
false-positive resolution (`--instance-status` to confirm, then `rm`
the lock, with the caveat that `rm` is only safe when no live peer
holds it). Inspect a holder without starting anything via
`monitor/watcher/launcher.sh --instance-status` or `ng watcher-status`.
Full rationale, the stale-lock case analysis, and topology:
[Operating → Watcher → Single-instance contract](../operating/watcher.md#single-instance-contract).

## Startup sweep

Before entering the main loop, the watcher runs one immediate
snapshot of GitHub + bells + idle workers. If anything is
non-empty it composes a `startup-sweep` report and pastes
unconditionally — no baseline to diff against on launch. The idle
probe's dedup state persists across watcher restarts, so a worker
that was idle pre-restart and is still idle now produces no
transition (no emit) on startup; only a worker whose state changed
between the previous live cycle and now is surfaced.

Three advisory sections ride only the startup sweep, each surfaced
at most once: `--- install failure ---` (the launcher's project-local
Claude Code install failed; flag files consumed on first emit),
`--- claude code update available ---` (a newer release than the
local pin; re-nag-guarded per candidate), and `--- watcher hosting
migration ---` (this watcher started legacy window-hosted instead of
as the headless service; once per watcher start — see
[Operating → Upgrading](../operating/upgrading.md)).

A fourth advisory section, `--- component drift (restart needed)
---`, rides **every** cycle (not just the startup sweep): when a
nexus-code component changed on disk and its restart needs the
orchestrator — a cockpit ask (the TUI is orchestrator-owned, so the
watcher never kills it), a tripped self-restart loop guard, or a
channel whose auto-restart is disabled — the watcher surfaces a
one-shot-per-candidate ask here. Watcher- and service-drift restarts
that the watcher performs *automatically* (detached `launcher.sh
--replace` for itself, `svc.sh restart <name>` for a supervised
service) never surface — only the asks do. Re-nag-guarded per
candidate hash. See
[`monitor/watcher/_version_restart.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/_version_restart.sh)
and [Operating → Upgrading](../operating/upgrading.md).

A fifth section, `--- service health ---`, also rides **every**
cycle: the `service_health` task (cadence
`monitor.service_health.interval_seconds`, default 120 s) runs every
registered infra service's registry healthcheck. On an unhealthy one
it does **not** restart immediately — that would fight the service's
own `*-supervised.sh` wrapper, which already self-heals a crashed
process. It first grants a **self-heal grace window**
(`monitor.service_health.grace_seconds`, default 30): a process-crash
the wrapper relaunches recovers within grace and the watcher never
touches it (breadcrumb only). Surviving the grace window means the
failure is **wedged** (process alive, healthcheck failing) or the
wrapper is dead — and only then does the watcher act, per the
service's **restart policy** (registry 6th column, or
`monitor.service_health.default_policy`, default `auto-restart`):
`auto-restart` does a flap-controlled minimal-downtime restart via
`monitor/svc.sh restart <svc>` (which reuses `recover_service` *and*
stops a wedged supervisor's process group); `emit-only` never
auto-restarts and instead escalates to the orchestrator. Detection
keys on the **registry healthcheck**, never on tmux/worker heuristics
— and registry-listed service windows stay exempt from worker-dead
detection (`_idle_probe.sh`). The section **always reports the full
state** regardless of which path fired — `grace` (informational, no
action) / `recovering` (restart attempted + outcome) / `emit-only` /
`flapping` (escalations) / a one-shot `recovered` breadcrumb, plus the
policy in effect — re-nag-guarded per `status:attempts` so a
persistently-down service does not spam every loop, and clears once
the service is healthy. Grace and a clean self-heal stay quiet;
`emit-only` and `flapping` are the loud escalations that need
judgment, so the orchestrator keeps full intervention capacity
without being nagged for what the watcher already handles. Per-service
incident state (first-unhealthy → restored timestamps, the policy,
whether it self-healed within grace, every restart attempt + outcome)
is recorded under
`monitor/.state/service-health/<name>.{state,events}`; the
orchestrator responds per
[`skills/nexus.service-recovery`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.service-recovery/SKILL.md)
and files an incident issue assembled from that state by `monitor/ng
service-incident <svc>`. The watcher NEVER degrades or falsifies a
service to pass a check. See
[`monitor/watcher/_service_health.sh`](https://github.com/<your-org>/nexus-code/blob/main/monitor/watcher/_service_health.sh).

## Report shape (paste body)

The full body of a typical emit, in section order:

```text
=== nexus state changed at 2026-05-11T13:42:01-07:00 (poll) ===
*If unsure how to proceed: see CLAUDE.md.*

<unified local diff, ≤ 120 lines>      # only when local_diff non-empty

--- eligible github comments ---       # only when non-empty
issue=42 id=4567890 author=user_login
  body: "@worker-3: please skip the heavy preprocessing"
...

--- standing bells ---                  # only when non-empty
  - worker-3 (idx 4)
(silenced after emit; agents will re-ring on the next event)

--- idle workers ---                    # only when non-empty
  - storage-bench wrapped up (idle 1h12m; wrap-up logged)
  - report-init-fixup idle 8m WITHOUT wrap-up — consider follow-up paste
(emitted on transitions only; see skills/nexus.window-cleanup)

--- service health ---                  # only when a registry service is unhealthy
service 'dolimap-serve' DOWN and NOT auto-recovering (FLAPPING): unhealthy since 2026-05-11T13:30:00-07:00; 3 restart attempt(s) did not hold.
  failing healthcheck: curl -fsS -o /dev/null --max-time 3 http://localhost:8765/
  ACTION (skills/nexus.service-recovery): restore first, then dispatch a root-cause worker + open an operator incident issue.
    incident issue: monitor/ng service-incident dolimap-serve

--- dashboard ---
last updated: 2026-05-11T11:10:00-07:00
(> 2h old; refresh via `monitor/ng dashboard put`)

--- nexus-emit-sig 2026-05-11T13:42:01-07:00 a1b2c3 ---
```

The CLAUDE.md cue line sits directly under the header — a
pre-attentional reminder for when an emit isn't self-explanatory.
The dashboard footer's "stale" advisory fires only at age ≥ 2 h, so
fresh dashboards don't generate noise. The trailer signature is
unique per emit and lives near the bottom of the rendered message
so it rarely scrolls out of the capture-pane window even for long
bodies.

## See also

- [Architecture](architecture.md) — the system in one page.
- [Files](files.md) — every state artifact and its retention.
- [Config](config.md) — every `monitor.*` knob mentioned above.
- [`docs/operating/watcher.md`](../operating/watcher.md) — operator
  view: how to read the output, how to debug a silent watcher.
- [`docs/operating/troubleshooting.md`](../operating/troubleshooting.md)
  — recipes for the known failure modes.
