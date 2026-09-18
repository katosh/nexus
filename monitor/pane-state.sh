#!/usr/bin/env bash
# pane-state.sh — classify a tmux worker pane so the orchestrator can
# tell Claude Code's autosuggest text apart from genuine user input.
#
# Output (single line, key=value, machine-parseable):
#   state=<idle|busy|user-typing|autosuggest-only|empty|blocked|absent|over-limit|
#          working-background|working-self-paced|idle-orphan-async|unknown> \
#     active=<0|1> window=<idx> name=<windowname> [input=<typed|ghost|blank|?>] \
#     [queued=1] [reset_at=<token>] [limit=<flavour>] \
#     [evidence=<token>] [reason=<token> site=<label> [capture=failed]] \
#     [orphan_kinds=<csv>] [bg_shells=<count> bg_reliable=<0|1> bg_cpu=<jiffies> \
#      bg_oldest_start=<epoch> bg_infra=<count> bg_stale=<count> \
#      bg_cmd=<comm:cmd-tail> bg_cpu_bp=<basis-points|-> bg_wedged=<0|1>
#      bg_members=<digest> bg_quiesce=<count> bg_longjob=<0|1>]
#
# A background SHELL is detected from the kernel PROCESS TREE — claude's
# live background-shell child subtrees (your-org/nexus-code#445, made the
# authoritative signal in #455). The status-line `N shell` footer regex is
# only a fallback for when the process tree can't be read (no pane_pid,
# /proc-restricted): it is presentation, so a user-customised/changed
# status bar or a coincidental text match must never be the primary
# detector. A Monitor handle was once assumed to live inside claude's node
# process (not a child), so it is still read from the footer/heartbeat.
# THAT ASSUMPTION IS FALSE on current Claude Code builds for a `command`
# Monitor: its loop runs as a REAL zsh child of claude (measured 2026-09-11 on
# 2.1.268, the orchestrator's watcher-supervisor `until ! …tick.sh; do sleep 15;
# done` as pid 13599, ppid = claude), so the process-tree walk counts it as a
# background shell and the line carries `bg_cpu=`. `bg_quiesce` (below) is
# what lets a consumer tell such a pure wait loop from real work.
#
# `bg_cpu` is appended only when state=working-background AND the driver
# is a background SHELL (a `run_in_background` job / `& disown`), not a
# Monitor handle (your-org/nexus-code#445). It carries the aggregate
# CPU jiffies (utime+stime) of the background-shell subtrees under
# claude. The watcher's `_idle_probe.sh` diffs it across cycles: while
# it advances the worker is genuinely computing (exempt from the
# idle-without-wrap-up nag), but once it freezes past the orphan grace
# the shell is doing nothing and the window falls back to normal idle
# classification. A Monitor-handle working-background carries NO bg_cpu
# (it is self-waking) and is never capped.
#
# `bg_cpu_bp` / `bg_wedged` (your-org/nexus-code#1446) ride the same line:
# the subtree's CPU share over its whole episode in BASIS POINTS
# (jiffies * 100 / elapsed seconds; `-` when the episode start is unknown),
# and a flag that the episode is older than NEXUS_BG_WEDGE_MIN_ELAPSED
# (default 600 s) with a share under NEXUS_BG_WEDGE_CPU_BP (default 100 =
# 1%). A child whose elapsed dwarfs its CPU is BLOCKED — an existence
# query piped into `head`, a wait on a token the producer never writes —
# not long-running; three >5h stalls and a 5h36m waiter all read
# `working-background` here with nothing to tell them from real compute.
#
# `bg_shells` and `bg_reliable` accompany `bg_cpu` on a shell-driven
# working-background line (your-org/nexus-code#455 refine). `bg_shells` is
# the count of live background-shell child subtrees under claude;
# `bg_reliable` is 1 iff the process-tree walk was authoritative (pgrep +
# /proc readable + a claude node found). The idle probe uses `bg_shells>=1`
# with `bg_reliable=1` to key its idle-with-children exponential-backoff
# long timeout and its wrap-up-with-remaining-children inconsistency
# detector; when `bg_reliable=0` it must not make reap decisions on the
# count and keeps the legacy #445 flat-grace behaviour.
#
# `bg_infra` and `bg_cmd` ride along on the same line
# (your-org/nexus-code#590). `bg_infra` is how many of those `bg_shells`
# roots are NEXUS PROTOCOL WAIT loops — the `skeptic-channel await` /
# `request … await` re-check loops `ng wrap-up` itself tells a worker to
# hold — rather than task work. `bg_cmd` is a space-free
# `<comm>:<cmd-tail>` label naming ONE representative root, preferring a
# non-infra one. Both are ADDITIVE: `bg_shells` is unchanged, so the
# `working-background` verdict and the `parked-awaiting-skeptic` exemption
# that keys off it are untouched. The idle probe uses them to stop
# reporting a protocol-prescribed await loop as a
# `wrapped-with-children` inconsistency (it fired on every skeptic-gated
# worker, which trains the operator to dismiss the genuine orphaned-job
# case) and to NAME the child instead of demanding a decision on a bare
# count.
#
# `bg_quiesce` (appended LAST on the same line) counts the `bg_shells` roots
# that hold NO in-flight work at the sampled instant: a root whose WHOLE eval'd
# payload is a nexus protocol wait loop (the strict whole-payload recogniser
# `_pane_payload_is_pure_wait`, NOT `bg_infra`'s substring match) AND whose
# live subtree is nothing but shells and `sleep`, or a #1208-stale waiter. It
# is a NEW COLUMN on purpose: `bg_infra` already SELECTS in the idle probe, so
# widening it would change reap behaviour, and `bg_infra` matches anywhere in a
# subtree, so a compute child under an await loop still counts as infra. Its
# ONE consumer is the cc-update restart gate (`_restart_eligible`), which may
# kill the orchestrator between turns only when `bg_quiesce >= bg_shells`.
# Errs toward 0 (not quiescent) on anything it cannot parse.
#
# COVERAGE BOUNDARY, narrower than a first reading suggests (w234sk F3). Two
# things this count does not see:
#   * The walk counts only SHELL children of claude as roots. A NON-shell
#     direct child of claude is invisible to `bg_shells` and `bg_quiesce`
#     alike. Examples: an `exec <compute>` from a background command, or an
#     MCP server, which looks identical to it.
#   * A descendant whose comm is a shell (bash, sh, zsh, …) is never "alien".
#     So work done by shell SCRIPTS under a recognised wait root passes the
#     descendant check, not only work done in shell builtins.
#
# `reset_at` is appended only when state=over-limit, and carries the
# extracted reset-time string (spaces collapsed to `_`, parens stripped,
# capped at 40 chars). Value is `unknown` when the canonical "resets
# <time>" suffix wasn't extractable.
#
# `limit` is appended alongside it and names WHICH limit the banner says was
# hit — `weekly_Opus`, `weekly_Fable`, … — or `unknown` (your-org/nexus-code
# #1488). The banner regex always captured this and every consumer discarded it
# and said "Opus": a worker's FABLE limit was reported as an Opus one, resumed
# against an Opus reset, and refused again on arrival. The model tier is not a
# constant of this codebase; it is written on the screen the detector already
# matched. A FIELD rather than a state token, for the `throttled=1` reason
# (#1340): consumers of `state=` are unaffected.
#
# `overlay` is appended only when state=blocked, and names WHICH overlay is
# waiting on a human: `rate-limit` | `permission` | `bypass-permissions` |
# `askuq` | `workspace-trust` | `dialog`. The first four are TEXT-KEYED arms;
# the last two come from the STRUCTURAL arm (`_has_menu_dialog_frame`,
# your-org/nexus-code#896) that catches any select-dialog Claude Code renders,
# named or not — `dialog` is the honest generic kind for one nobody has
# enumerated yet, and it is a NAME, not a detection precondition.
# `blocked` alone answers "should I wait?"; the kind answers "what do
# I do about it?", and for `bypass-permissions` those are different actions —
# it is a CONFIGURATION fault (a `settings.json` rewritten between boots
# without `skipDangerousModePermissionPrompt`), not a decision anyone should
# answer at the pane. Before this field that case reached no overlay arm at
# all and fell through to `empty` — "don't know yet" — so a deterministic
# config fault presented as a slow boot (your-org/nexus-code#768).
#
# `orphan_kinds` is appended only when state=idle-orphan-async, and
# carries a comma-separated dedup'd list of `kind:id` pairs from the
# heartbeat's `external_waits` array. Caller renders it verbatim in
# the operator-facing `--- idle workers ---` block so the contract
# violation surfaces with the offending job id (e.g.
# `orphan_kinds=slurm:52527284_4,ci:your-org/runs/26304173692`).
# Capped at 80 chars; longer lists are truncated with `…`.
#
# `content_hash` is appended whenever the pane was actually captured
# (every renderer-path emit, and the heartbeat path's idle-refinement
# capture — all the states where a worker can sit between turns: idle
# / autosuggest-only / user-typing / empty / busy). It is a stable
# digest of the pane's TRANSCRIPT region — everything above the
# `❯<NBSP>` input row — with the most volatile glyphs neutralised (see
# `_content_hash`). The watcher's `_idle_probe.sh` diffs it across
# cycles to tell a genuinely-changing pane (real interaction) from a
# static one, which gates the self-expiring operator-engaged mark
# (your-org/your-nexus#205 follow-up): a fragile one-frame bright-text
# read must NOT be the load-bearing signal for holding a window open,
# so sustained content change carries that weight instead. Absent on
# the heartbeat-authoritative busy/blocked early exits (no capture
# taken there); the probe treats those agent-working states as
# implicit change.
#
# State semantics:
#   absent           - window exists in tmux, no live `claude` process
#                      in its pane's process tree, AND nothing else is
#                      alive under the pane either (the inner REPL has
#                      truly exited; rendered bytes may linger via
#                      tmux's `remain-on-exit on`). The second
#                      conjunct is load-bearing and was added by
#                      your-org/nexus-code#643: without it a window
#                      still running its spawn launcher's preamble —
#                      healthy, seconds old, `exec claude` imminent —
#                      reported `absent`, the one KILL-AUTHORISING
#                      state. That case now reports `unknown`. Read
#                      this state as "nothing is running here", which
#                      is the claim it can actually support.
#                      your-org/nexus-code#777 added two more
#                      conjuncts, both for cases where the old rule
#                      asserted death from a NON-observation:
#                      the process view must have been PROVEN able to
#                      see processes at all (a `ps`/`pgrep` that
#                      cannot find a child we just forked is blind,
#                      and its silence about the pane means nothing),
#                      and the pane must be older than
#                      `NEXUS_PANE_BOOT_GRACE_SECONDS` (default 90)
#                      unless tmux's own `#{pane_dead}` confirms the
#                      exit. Production spawns with `tmux new-window`
#                      carrying NO command, so for the first seconds
#                      the pane shell has no descendants AT ALL and
#                      #643's descendant test cannot separate booting
#                      from dead — elapsed time is the only axis that
#                      differs. Withholding `absent` inside that
#                      window delays a genuine reap by at most the
#                      grace, and only ever in a pane's opening
#                      seconds; emitting it there authorises killing
#                      a live worker. A

#                      `state=absent` row always carries a populated
#                      `name=<window>` because a non-existent window
#                      index is treated as a caller error and exits
#                      3 — see Exit codes below (issue #140).
#                      your-org/nexus-code#788 made this a DECISION
#                      rather than a fall-through. `absent` now has
#                      exactly ONE emitter, `_emit_absent_or_unknown`,
#                      which refuses unless it can NAME positive
#                      evidence — so every `state=absent` row carries
#                      `evidence=<pane_dead|pid-gone|
#                      tree-empty-past-grace|fixture-no-process>` and
#                      every refusal carries `reason=<live-claude|
#                      live-descendant|claude-identity-indeterminate|
#                      proc-view-blind|boot-grace|
#                      no-pane-pid> site=<label>`, plus
#                      `capture=failed` when `tmux capture-pane`
#                      itself failed. Two further sites reached
#                      `absent` by NOT deciding and are now routed
#                      through that door: the renderer's
#                      no-input-row fallback, and `[[ -z "$pane_ansi"
#                      ]]` — the latter measured emitting the
#                      kill-authorising state for a pane whose ROOT
#                      PROCESS was a live `claude` the moment one
#                      `capture-pane` call returned rc≠0.
#   blocked          - an overlay is waiting on a human: permission
#                      prompt, rate-limit menu, AskUserQuestion
#                      chip-bar, the Bypass Permissions warning
#                      modal, or ANY other select-dialog Claude Code
#                      renders — the last of those detected
#                      STRUCTURALLY (a numbered-option menu with a `❯`
#                      cursor and an Enter/Esc footer, and no REPL row
#                      below it), so a dialog nobody enumerated is
#                      still seen (your-org/nexus-code#896; the
#                      motivating instance is the workspace-trust
#                      dialog that 2.1.232 started showing every
#                      nested-repo worker spawn). Mirrors
#                      monitor/watcher/_unstick.sh detection for the
#                      text-keyed arms — but only those: nothing in
#                      `_unstick.sh` auto-answers the structurally
#                      detected ones, which is deliberate for a
#                      security prompt. Always carries
#                      `overlay=<kind>` naming which — see the field
#                      notes above; the `bypass-permissions` kind is a
#                      CONFIGURATION fault, not a question to answer
#                      at the pane (your-org/nexus-code#768).
#   busy             - spinner row shows an active token counter
#                      (`↓ N tokens` / `↑ N tokens`); agent is working.
#                      ALSO emitted, with an extra `queued=1` field,
#                      when the input row has been replaced by Claude
#                      Code's `Press up to edit queued messages`
#                      placeholder. That placeholder is positive
#                      evidence of BOTH facts — input pending AND a
#                      turn in flight — since Claude Code only queues
#                      while a turn is running and flushes the queue
#                      when it ends. It previously rendered as `empty`,
#                      the most ambiguous value available, for the one
#                      situation an orchestrator most needs to read
#                      correctly (#603, #607). Reported as `busy`
#                      rather than a new state token deliberately:
#                      every existing consumer already treats `busy` as
#                      never-kill / never-paste, so the safe behaviour
#                      needed no consumer audit and no permissive
#                      default could be inherited.
#   user-typing      - input row carries the bright-text marker
#                      (`\x1b[38;5;231m`), OR the pane is in vim
#                      INSERT mode (`-- INSERT --` in the status line)
#                      with a non-blank input row. The vim clause is
#                      your-org/nexus-code#603: Claude Code's vim mode
#                      does not reliably emit the bright SGR, so two
#                      panes holding VISIBLE unsubmitted operator text
#                      classified `empty` and became kill candidates.
#                      user has typed real input.
#                      Detected on BOTH the renderer-fallback path
#                      and the heartbeat path (issue #196): a fresh
#                      `idle_prompt` heartbeat proves the agent's
#                      turn ended, but says nothing about the
#                      operator typing into the box afterwards — so
#                      a heartbeat-idle verdict is refined to
#                      `user-typing` when the input row shows the
#                      bright marker. Autosuggest ghost text renders
#                      dim (`\x1b[7m.\x1b[0;2m`, never bright), so it
#                      cannot false-trigger this refinement.
#   autosuggest-only - input row carries an autosuggest GHOST with no
#                      user-typed prefix; cosmetic suggestion only —
#                      orchestrator should ignore. TWO renderings count,
#                      and missing the second was #626: the dim-CURSOR
#                      pattern (`\x1b[7m.\x1b[0;2m`), and a BARE DIM RUN
#                      (`\x1b[2m` + text, no reverse-video cursor at
#                      all). Only the first was matched, so nineteen
#                      ghost panes at once fell through to `empty` and
#                      an orchestrator with no discriminator left read
#                      them as unsubmitted operator drafts.
#
# `input=` field — the GHOST-vs-DRAFT question, answered directly
# (your-org/nexus-code#626). CLAUDE.md is right that autosuggest
# "renders identically to user input in PLAIN text"; the point is that
# it does NOT render identically in SGR. Typed input carries bright
# white (`38;5;231`), a ghost carries faint (SGR 2 as a whole
# parameter — `\x1b[2m`, `\x1b[0;2m`, but never `\x1b[22m`/`\x1b[32m`).
# So `tmux capture-pane -e` separates them mechanically:
#   typed | ghost | blank | ?
# `?` is a non-blank row matching NEITHER marker, reported rather than
# guessed. That residue is the only case that would need an
# input-EVENT channel; everything else is decided from bytes. The field
# is deliberately SEPARATE from `state=` so a consumer can ask "is this
# an operator draft?" without going through a token that also carries
# kill-authorisation meaning.
#   idle             - empty input box, no busy spinner; safe to paste.
#   empty            - the renderer is in an ambiguous state (no input
#                      row matches any of the positive regexes) BUT the
#                      pane's process tree still contains a live
#                      `claude`. Common during paste re-render and
#                      state-swap transitions. Callers should treat
#                      `empty` as "don't know yet, try again next
#                      cycle" — NOT as "claude is gone".
#
#                      THIS CONTRACT IS NOW ENFORCED, not merely
#                      documented (your-org/nexus-code#603). It was
#                      stated here in these exact terms while the
#                      retirement path treated `empty` as evidence a
#                      window was finished and killed on it — a pane
#                      4m38s into a verification pass, mid-`git fetch`,
#                      with a message queued behind it, read `empty`.
#                      `monitor/_bookkeeping.sh:bk_pane_kill_authorized`
#                      is the machine-readable form of the rule: an
#                      ALLOWLIST of states that authorise a kill, with a
#                      default-DENY arm, so `empty` — and any state
#                      added to this file later — refuses rather than
#                      falling through a permissive default.
#   unknown          - the classifier could not look at all (e.g. tmux
#                      is not installed). Distinct from `absent`, which
#                      is a POSITIVE finding about a window we did
#                      inspect. Emitting `absent` for "we did not look"
#                      is the #603 defect in miniature.
#   over-limit       - the canonical "You've hit your <flavor> limit ·
#                      resets <time>" notice (flavor: "weekly",
#                      "5-hour", …, or none) is rendered at the bottom
#                      of the pane, OR a fresh StopFailure-hook stamp
#                      (monitor/hooks/over-limit-emit.sh) exists for
#                      the window; claude is functionally suspended
#                      until the usage limit resets. Orchestrator
#                      should schedule a resume rather than treat the
#                      worker as idle. Text detection is anchored to
#                      the bottom ~15 rows so a transcript mention of
#                      the same phrase doesn't false-trigger; the hook
#                      stamp expires after
#                      MONITOR_OVER_LIMIT_STAMP_TTL_SECONDS (default
#                      27h) so a missed Stop-clear can never latch the
#                      state.
#
# Async-signal refinement (issue #183): the four classifications
# below are NOT new top-level branches — they refine the existing
# `idle` verdict. The path: if the renderer (or heartbeat) would
# have emitted `idle`, we look at three async signals and pick the
# more specific class. The signals, in priority order:
#
#   1. a live Monitor handle (pane FOOTER) OR a live background shell
#      (PROCESS TREE, footer as fallback)
#      → `working-background` (worker has an in-flight async tool
#      handle in claude's own process; they'll be woken when it
#      completes). Neither count is in the heartbeat — see #1374.
#   2. scheduled_wakeup_at > now
#      → `working-self-paced` (worker scheduled a /loop
#      ScheduleWakeup; the harness will resume them then).
#   3. external_waits != [] AND neither (1) nor (2)
#      → `idle-orphan-async` (worker self-declared a slurm job /
#      CI run / etc, OR the PostToolUse auto-detect spotted one,
#      AND they installed no resume mechanism → contract
#      violation, surface to operator).
#   4. None of the above → plain `idle`.
#
# Signal sources, by signal:
#   - the `bg` signal (background shells): the PROCESS TREE is the
#     primary + authoritative source (your-org/nexus-code#455) — claude's
#     live background-shell child subtrees, counted by
#     _pane_background_shells. When that reading is reliable it overrides
#     the footer both up and down. The footer is the ONLY fallback for
#     when the tree can't be read (no pane_pid, /proc-restricted). Footer
#     phrasings matched by the fallback: the status-line `N shell[s]` (the
#     real Claude Code v2.1.204 form, e.g. `· 1 shell, 1 monitor ·`) and
#     the legacy `N background bash[es]` form. This false-idle — a worker
#     idling between turns with a live background shell showing ONLY the
#     status line — was your-org/nexus-code#445; #455 removes the reliance
#     on that presentation regex as primary.
#   - the `mon` signal (Monitor handles): the pane footer, and ONLY the
#     pane footer (`N monitor[s] still running` spinner-row or the
#     `· N monitor ·` status-line form). Monitor handles run inside
#     claude's node process, not as child processes, so the process tree
#     cannot see them; and the heartbeat has NEVER carried a count of them
#     (your-org/nexus-code#1374 — the arm that read one had no writer).
#   - `scheduled_wakeup_at` / `external_waits`: heartbeat only.
#     `external_waits` has NO renderer fallback. A worker that
#     hasn't run the PostToolUse hook AND hasn't called
#     `monitor/declare-wait.sh` is by definition silent about its
#     async work; the watcher can't infer it from pane bytes.
#
# Process-liveness gate: the dead-claude check runs FIRST, before the
# heartbeat substrate and before any renderer-pattern matching. When
# tmux reports a pane_pid AND no `claude` descendant lives in its
# tree, we emit `absent` regardless of what stale rendered bytes the
# pane still shows (tmux's `remain-on-exit on` keeps the last frame
# visible after the inner REPL exits — `❯<NBSP>` and dim-cursor bytes
# linger and would otherwise re-classify forever as
# `idle`/`autosuggest-only`/`busy`). Process liveness is ground
# truth; heartbeat and rendered bytes are hints. The gate is skipped
# when pane_pid is empty (fixture mode, or a brand-new window where
# tmux hasn't bound a pid yet) — those fall through to the existing
# classification paths.
#
# Within the renderer fallback, the `absent` ↔ `empty` distinction is
# also process-anchored: when no input row matches, we re-walk the
# descendants — alive ⇒ `empty`, dead ⇒ `absent`. This closes the
# `state=empty` false-positive that PR 55 left open: a brand-new paste
# (or a mid-spinner-swap) shows no input row for a few hundred ms while
# `claude` is unambiguously alive.
#
# Heartbeat substrate (issue #74): when the per-window heartbeat file
# `$NEXUS_STATE_DIR/heartbeat/<window>.json` exists AND its
# `last_activity` is younger than the staleness window (default 30 s,
# `monitor.heartbeat_staleness_seconds`), the helper uses its `state`
# field as authoritative and skips the renderer detection entirely.
# The file is written by `monitor/worker-heartbeat.sh` from the
# per-spawn `--settings` PostToolUse / Notification / UserPromptSubmit
# hooks. State vocabulary in the file maps to the emit vocab as:
#   busy            → busy
#   permission_prompt → blocked
#   idle_prompt     → idle
#   user_prompt     → busy (a fresh prompt counts as ongoing work)
#   any other       → fall through to renderer detection
# Missing or stale file ⇒ renderer path. Pane liveness gates `absent`
# at the top of the script (process check is ground truth), so a dead
# pane emits `absent` whether the heartbeat is fresh, stale, missing,
# or unmapped — the heartbeat path only runs when claude is alive.
#
# Env knobs:
#   NEXUS_PANE_BOOT_GRACE_SECONDS   default 90; 0 disables. How long
#       after a pane is CREATED `absent` is withheld from a pane with
#       nothing running under it (your-org/nexus-code#777). Only the
#       tests set it: 0 where an assertion is about the process-tree
#       rule and the fixture pid happens to be seconds old.
#
# Inputs:
#   $1   <window-index>  (e.g. `3`)        — assumed session 0
#        <session>:<window>  (e.g. `0:3`)
#        --fixture <path>                    — read pane bytes from a
#                                              file instead of tmux
#                                              (for tests). Pairs with
#                                              --window/--name/--active.
#
# Exit codes:
#   0  classification produced (always — even `state=absent` exits 0)
#   2  bad usage
#   3  the requested tmux window does not exist (issue #140 — a
#      bogus index used to return `state=absent name=` and exit 0,
#      which masked an orchestrator-side index-typo bug). Distinct
#      from exit 2 so callers can tell "argv shape was wrong" from
#      "argv shape was fine but it isn't a live window".
#      BOTH SPELLINGS (your-org/nexus-code#1101). This used to be the
#      INDEX spelling only: a NAME that resolved to nothing printed
#      `usage` and exited 2, so `pane-state.sh 0:9999` and
#      `pane-state.sh gone-window` — the same fact, two spellings —
#      answered "not a live window" and "your argv was wrong". A
#      caller keyed on names could therefore never establish that a
#      window had vanished, only that it could not be looked at.
#      "Could not ask tmux" stays OUT of 3 and keeps exit 2: it is
#      not a claim about the window's existence.
#
# The dim-cursor regex `\x1b\[7m.\x1b\[0;2m` and the bright-text marker
# `\x1b\[38;5;231m` are centralized in this file. If a future Claude
# Code release changes them (e.g. emits `\x1b[2m` alone or 256-colour
# grey instead of `\x1b[0;2m`), update _detect_autosuggest /
# _detect_user_typing here — every caller picks up the fix.
#
# Manual sanity check — when the helper's verdict looks wrong, dump
# the same bytes it parses and inspect the input row by eye:
#
#   tmux capture-pane -t 0:<win> -e -p -S -10 | cat -v
#
# `cat -v` renders ESC as `^[`. On the line containing `❯<NBSP>`
# (the input row) look for:
#
#   ^[[7m<char>^[[0;2m...      autosuggest (dim ghost)  → ignore
#   ^[[38;5;231m...            bright user-typed text   → respect
#   ^[[7m ^[[0m  (just a space) empty input box
#
# Above the input row, `↓ <N> tokens` = busy spinner;
# `✻ <Verb>ed for <dur>` = idle banner.

set -u

# ARGUMENT-LOOP PROGRESS GUARD (your-org/nexus-code#924). Each argument loop
# below asserts that every iteration consumes at least one argument. Without it
# a value-taking flag given LAST spins forever — `shift 2` with `$#` == 1 is
# refused, so the arm re-matches — and a hang here is worse than an error
# because nothing on this board surfaces it. Full rationale: monitor/ng.
_argloop_stuck() {
    printf '%s: option %s requires a value (argument loop made no progress)\n' \
        "${0##*/}" "${1-}" >&2
    exit 64
}

# ---- the declared state vocabulary (your-org/nexus-code#790) -------------
#
# Every value this script can print for `state=`, ONCE, as data. It exists
# because CONSUMERS classify on this axis and there was previously no way
# for one to declare "I have considered every state" and be checked on it.
#
# The consumer that forced the issue is the watcher's pending-decisions
# gate (`bk_decision_row_actionable`, monitor/_bookkeeping.sh): it decides
# whether an operator-facing row is still worth the operator's attention
# by asking what the pane is doing RIGHT NOW. A state added here and not
# considered there silently lands in that gate's default arm. So the gate
# pins its disposition for every member of this array as data
# (`monitor/watcher/decision-gate-states.manifest`) and
# `monitor/watcher/test-decision-gate-states.sh` fails when the two sets
# diverge — adding a state below without ruling on it turns the suite red.
#
# `--states` prints one per line: the machine-readable form that test
# consumes, so the boundary is CHECKED against this array rather than
# re-derived by grepping for `emit` (which cannot see the states
# `_finalize_idle_verdict` / `_refine_idle_with_async_signals` return
# through a variable — `idle`, `working-background`, `working-self-paced`,
# `idle-orphan-async` are all invisible to such a grep, so a grep-derived
# vocabulary is a confident under-count of exactly the states the gate
# most needs to rule on).
#
# Keep in sync with the `state=` line in this file's header block; the
# same test asserts the two agree, so the prose cannot drift from the data.
_PS_STATES=(
    idle busy user-typing autosuggest-only empty blocked absent
    over-limit working-background working-self-paced idle-orphan-async
    unknown
)

usage() {
    cat <<'EOF' >&2
usage: pane-state.sh <window-index|session:window|window-name>
       pane-state.sh --all [<session>]
       pane-state.sh --fixture <path> [--window <idx>] [--name <s>] [--active 0|1]
                     [--heartbeat-file <path>] [--now <epoch>]
                     [--heartbeat-staleness <seconds>]
                     [--heartbeat-turn-end-staleness <seconds>]
                     [--heartbeat-async-staleness <seconds>]
                     [--over-limit-file <path>]
                     [--orchestrator-heartbeat-file <path>]
                     [--orchestrator-window <name>]
                     [--pane-pid <pid>] [--bg-cpu <jiffies>]
                     [--bg-shells <count>] [--bg-oldest-start <epoch>]
                     [--bg-cmd <string>] [--bg-infra <0|1>] [--bg-members <digest>]
                     [--bg-stale <count>] [--bg-quiesce <count>] [--bg-longjob <0|1>]
       pane-state.sh --mcp-shell-risk
       pane-state.sh --states

  --mcp-shell-risk  Diagnostic. Could a configured MCP server be counted as a
                    background task shell? Prints `none`, `shell:<names>`, or
                    `unknown:<reason>` — `unknown` is NOT `none`. Use when a
                    background-shell count has no obvious owner.
  --states          Print the declared `state=` vocabulary, one per line.
                    The machine-readable axis a consumer classifies on; see
                    monitor/watcher/decision-gate-states.manifest for the
                    checked example of a consumer pinning its coverage.
EOF
    exit 2
}

# `--states` is answered before anything else: it reads no pane, needs no
# tmux, and must stay usable from a test harness with no session at all.
if [[ "${1:-}" == "--states" ]]; then
    printf '%s\n' "${_PS_STATES[@]}"
    exit 0
fi

# ---- arg parsing ----------------------------------------------------------
fixture=
fix_window=0
fix_name=fixture
fix_active=0
all_session=
target=
_PS_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mcp_risk_only=0
hb_file_override=
now_override=
staleness_override=
turn_end_staleness_override=
async_staleness_override=
over_limit_file_override=
orch_hb_file_override=
orch_window_override=
pane_pid_override=
# tmux's `#{pane_dead}`; empty on the fixture path, where there is no pane.
pane_dead=
# Did `tmux capture-pane` SUCCEED? Distinct from "was the capture empty"
# (your-org/nexus-code#788). Defaults to 1 because the fixture path reads its
# bytes from a file that was already proved readable; only the tmux path can
# fail to look.
pane_capture_ok=1
# How long after a pane is created `absent` is withheld from a pane with
# nothing running under it, because a spawn in progress looks exactly like a
# dead one until the launcher is forked (your-org/nexus-code#777).
#
# 90 s is ~3x the worst boot ever reported (#643 recorded ~20-30 s in
# production; a fixture with the real guards measured 2.86 s, and this host's
# zsh rc alone runs 1.1-2.2 s under load 48). It bounds a DELAY, not a
# decision, so erring long costs only reap latency in a pane's first seconds.
# 0 disables the grace entirely, which is how the negative-control tests prove
# a genuinely dead pane is still reapable.
PANE_BOOT_GRACE_SECONDS="${NEXUS_PANE_BOOT_GRACE_SECONDS:-90}"
[[ "$PANE_BOOT_GRACE_SECONDS" =~ ^[0-9]+$ ]] || PANE_BOOT_GRACE_SECONDS=90
bg_cpu_override=
bg_shells_override=
bg_oldest_start_override=
bg_infra_override=
bg_stale_override=
bg_cmd_override=
bg_members_override=
bg_longjob_override=
bg_quiesce_override=
_argloop_prev_1=-1; while (( $# > 0 )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
    case "$1" in
        --fixture) fixture="$2"; shift 2;;
        --window)  fix_window="$2"; shift 2;;
        --name)    fix_name="$2"; shift 2;;
        --active)  fix_active="$2"; shift 2;;
        --heartbeat-file)              hb_file_override="$2"; shift 2;;
        --now)                         now_override="$2"; shift 2;;
        --heartbeat-staleness)         staleness_override="$2"; shift 2;;
        --heartbeat-turn-end-staleness) turn_end_staleness_override="$2"; shift 2;;
        --heartbeat-async-staleness)   async_staleness_override="$2"; shift 2;;
        --over-limit-file)             over_limit_file_override="$2"; shift 2;;
        --orchestrator-heartbeat-file) orch_hb_file_override="$2"; shift 2;;
        --orchestrator-window)         orch_window_override="$2"; shift 2;;
        --pane-pid)                    pane_pid_override="$2"; shift 2;;
        --bg-cpu)                      bg_cpu_override="$2"; shift 2;;
        --bg-shells)                   bg_shells_override="$2"; shift 2;;
        --bg-oldest-start)             bg_oldest_start_override="$2"; shift 2;;
        --bg-infra)                    bg_infra_override="$2"; shift 2;;
        --bg-stale)                    bg_stale_override="$2"; shift 2;;
        --bg-cmd)                      bg_cmd_override="$2"; shift 2;;
        --bg-members)                  bg_members_override="$2"; shift 2;;
        --bg-longjob)                  bg_longjob_override="$2"; shift 2;;
        --bg-quiesce)                  bg_quiesce_override="$2"; shift 2;;
        --all)
            shift
            if (( $# > 0 )) && [[ "$1" != -* ]]; then
                all_session="$1"; shift
            else
                all_session=0
            fi
            ;;
        --mcp-shell-risk) mcp_risk_only=1; shift;;
        -h|--help) usage;;
        --) shift; target="${1:-}"; break;;
        -*) usage;;
        *)  target="$1"; shift;;
    esac
done

# --- --all: enumerate every window in the session, classify each. ---------
# One line per window, same key=value format. Lets agent callers replace a
# bash loop with a single tool invocation.
if [[ -n "$all_session" ]]; then
    command -v tmux >/dev/null 2>&1 || { echo "tmux unavailable" >&2; exit 1; }
    self="$(realpath "$0" 2>/dev/null || echo "$0")"
    while IFS=: read -r idx _; do
        [[ -z "$idx" ]] && continue
        "$self" "${all_session}:${idx}"
    done < <(tmux list-windows -t "$all_session" -F '#{window_index}:' 2>/dev/null)
    exit 0
fi

# ---- helpers --------------------------------------------------------------
NBSP=$'\xc2\xa0'

_strip_ansi() {
    # Strip OSC sequences FIRST, then CSI, for plain-text greps.
    #
    # Why OSC matters (cc-update rigor fix). Claude Code's status line can
    # emit OSC 8 hyperlinks — `ESC ] 8 ; ; <url> ESC \ <anchor> ESC ] 8 ; ;
    # ESC \` — e.g. a clickable PR badge. A CSI-only strip leaves those raw
    # bytes inline, immediately adjacent to the footer tokens
    # _footer_handle_counts anchors on (` · N shell[s] · `, ` · N monitor ·`).
    # The URL payload can itself carry digits and separators, so surviving
    # OSC bytes can both HIDE a real handle count (by breaking the ` · `
    # boundary the regex needs) and FAKE one (by contributing digits).
    #
    # Ordering is load-bearing: an OSC payload may legally contain `[`, so
    # running the CSI pass first would chew a hole in the URL and strand the
    # terminator.
    #
    # MEASURED REACHABILITY (record it, don't assume it): on THIS host
    # tmux is 2.6, which predates tmux's hyperlink support (added in 3.2)
    # — it consumes OSC 8 and does NOT re-emit it from `capture-pane -e`,
    # so these bytes do not currently reach the parser via the live-pane
    # path (verified 2026-08-06: painted an OSC 8 anchor into an isolated
    # pane, captured with the same `-p -e` flags used at lines 1153/1394;
    # anchor text survived, escape bytes did not; 0 of the 28
    # PRE-EXISTING committed fixtures and 0 of 5 live panes carried OSC
    # bytes, measured at dc4c76f — the only 2 carrying them at HEAD are
    # the differential pair added alongside this change). That proof is
    # VERSION-SCOPED, not structural: on tmux >= 3.2 capture-pane -e does
    # re-emit hyperlinks, so a host or container upgrade silently makes
    # them reachable. This strip is the cheap, always-correct guard for
    # that day; the fixture
    # monitor/watcher/fixtures/working-background-osc8-prbadge-synthetic.ansi
    # exercises it independently of the local tmux version.
    sed -E -e $'s/\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)//g' \
           -e $'s/\x1b\\\\//g' \
           -e $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g'
}

# Set by `_has_blocked_overlay` to the arm that matched, and emitted as
# `overlay=<kind>` alongside `state=blocked`. `blocked` alone says "a human
# decision is pending"; the kind says WHICH, which is the difference between a
# diagnosis and a shrug — see the bypass-permissions arm below.
BLOCKED_OVERLAY_KIND=""

_has_blocked_overlay() {
    local plain="$1"
    BLOCKED_OVERLAY_KIND=""
    if grep -qE 'What do you want to do\?' <<<"$plain" \
       && grep -qE 'Stop and wait for limit' <<<"$plain"; then
        BLOCKED_OVERLAY_KIND=rate-limit
        return 0
    fi
    if grep -qE 'Do you want to proceed\?' <<<"$plain" \
       && grep -qE $'❯[[:space:]]+[0-9]+\\.' <<<"$plain"; then
        BLOCKED_OVERLAY_KIND=permission
        return 0
    fi
    if _has_bypass_permissions_modal "$plain"; then
        BLOCKED_OVERLAY_KIND=bypass-permissions
        return 0
    fi
    if _has_askuq_overlay "$plain"; then
        BLOCKED_OVERLAY_KIND=askuq
        return 0
    fi
    # LAST arm, deliberately: the four above are TEXT-KEYED and name a specific
    # decision, so they get first refusal and keep their precise kind. This one
    # is STRUCTURAL and catches the residue — any select-dialog Claude Code
    # renders that nobody has enumerated yet (your-org/nexus-code#896).
    if _has_menu_dialog_frame "$plain"; then
        BLOCKED_OVERLAY_KIND=$(_name_menu_dialog_kind "$plain")
        return 0
    fi
    return 1
}

# ---- the structural select-dialog arm (your-org/nexus-code#896) -----------
#
# WHAT THIS IS FOR. Claude Code 2.1.232 stopped letting a nested git repo
# inherit workspace trust from its parent, so every `work/<project>` worker
# spawn now boots into the folder-trust dialog:
#
#   Accessing workspace:
#   /path/to/work/proj
#   Quick safety check: Is this a project you created or one you trust? …
#   ❯ 1. Yes, I trust this folder
#     2. No, exit
#   Enter to confirm · Esc to cancel
#
# That frame matched NO arm above, so it fell through to the input-row logic,
# found no `❯<NBSP>` chevron, and landed on `empty` — which means "don't know
# yet". A worker that will NEVER proceed became indistinguishable from one that
# had merely not started, for as long as it hung: `_unstick.sh` never fired
# (its case_B needs `state=blocked`) and the watcher saw an idle-looking window.
#
# WHY THIS ARM IS NOT KEYED ON "Yes, I trust this folder". The trust dialog is
# ONE INSTANCE. Every full-screen dialog Claude Code has ever added lands in the
# same blind spot, and the next release that adds a modal reopens it — the
# bypass-permissions modal (#768) was the previous instance and was closed the
# narrow way, which is why this one still cost a release cycle. A detector that
# pattern-matches this dialog's WORDING closes the demonstrated repro and leaves
# the class live. So the test below asks what is true of the RENDERED PANE in
# the general case, not what is true of this dialog's subject matter, and the
# `overlay=<kind>` seam carries the naming separately (`_name_menu_dialog_kind`)
# — the kind is a DIAGNOSTIC, never a precondition for detection.
#
# THE THREE CONDITIONS, and what each one is holding off:
#
#   (a) NAVIGATION FOOTER in the bottom slice — `Enter to …` / `Esc to …`, the
#       keyboard-affordance chrome every interactive overlay paints under its
#       options. Case-SENSITIVE, as a cheap hedge rather than against a measured
#       hazard, and the distinction is stated because the first draft of this
#       comment asserted the hazard as fact: a lowercase `(esc to interrupt)`
#       spinner hint appears in `test-integration/stub-claude.sh` and
#       `test-engage-long-exchange.sh`, so some Claude Code rendering paints it —
#       but MEASURED against the real 2.1.224 binary over a 30 s busy window
#       (samples at 5/10/20 s), a live busy pane contains **zero** occurrences of
#       `esc to …` OR `Esc to …`: the row is `✻ Smooshing… (16s · ↓ 3 tokens)`,
#       with no interrupt hint at all. So the lowercase collision is a
#       possibility this guard is cheap insurance against, NOT something
#       currently observed. What actually keeps live busy panes out is (c) — see
#       the measurement recorded there.
#   (b) A CHEVRON-SELECTED OPTION above that footer, plus at least one
#       COLUMN-ALIGNED sibling option row — i.e. a menu with a highlighted
#       choice, which is what makes it a DECISION rather than a notice. The
#       chevron must be followed by an ASCII space; the REPL input row is `❯` +
#       NBSP, so this cannot match a user who typed at the prompt. It used to
#       additionally require `N.` ordinals on both rows; 2.1.248 dropped those
#       from the trust dialog and reopened the whole blind spot, so the sibling
#       test is now the layout invariant a select menu actually has — see the
#       (b2) block in the body (your-org/nexus-code#1112).
#   (c) LIVE, NOT QUOTED: no `❯<NBSP>` REPL input row below the footer. This is
#       the same structural test `_has_bypass_permissions_modal` settled on
#       under #776 adversarial review, and for the same reason — a live dialog
#       REPLACES the REPL, while a pane merely DISCUSSING one is still a running
#       REPL and keeps its input row underneath. It is a property of what the
#       two panes ARE, not of how many rows happen to trail the quote.
#
#       SCOPE, because the first version of this paragraph over-claimed and the
#       #896 skeptic refuted it with this repo's own corpus. What was measured:
#       against the real 2.1.224 binary in a 30 s hang, a live busy pane keeps
#       its `❯<NBSP>` row below the spinner. What that supports: STEADY-STATE
#       busy, with the chevron painted. What it does NOT support, and what the
#       first version asserted, is "every working pane is rejected here" — 5 of
#       the 7 committed `busy-*` fixtures carry no `❯<NBSP>` at all, including
#       `busy-mid-render-no-chevron-synthetic.ansi`, a regime this repo has had
#       a named fixture for since #47. A 30 s steady-state hang samples ONE
#       regime; the chevron-absent ones are exactly the regimes the claim needed
#       to cover. Condition (d) below is what actually covers them.
#
# DIRECTION-2 (can it stay silent?) is the direction that matters here, because
# `empty` is load-bearing: `monitor/_bookkeeping.sh:bk_pane_kill_authorized`
# treats `empty` as INDETERMINATE and already refuses the kill, while `blocked`
# is in `_BK_ACTIVE_STATES` and refuses it too — so widening `blocked` at the
# expense of `empty` removes nothing from the kill allowlist and adds nothing to
# it. The cost of a false positive is therefore NOT a retired live worker; it is
# the orchestrator chasing a decision that is not pending — and, worse, reading
# "a human must decide" over a pane that is MID-TURN, losing `queued=1` with it.
# That is what condition (d) exists for; see the measurement recorded there.
#
# It is NOT, as an earlier version of this comment claimed, `_unstick.sh` Case W
# relaying a phantom `blocked_question`. Case W cannot fire on it: `_unstick.sh`
# contains no reference to pane-state at all — it takes its own `capture-pane`
# and gates every arm on co-occurring literals — so nothing here reaches it.
# Corrected after the #896 skeptic checked the code rather than the story; the
# suite now drives these panes through `_handle_unstick_window` and asserts it
# selects no arm, with a rate-limit control proving that silence is a
# measurement rather than a broken probe.
#
# WHAT THIS ARM DOES NOT AUTO-ANSWER. `_unstick.sh` runs its OWN text-keyed
# detection (`Do you want to proceed?`, `Stop and wait for limit`, the AskUQ
# chip-bar literals); none of them match the trust dialog, so nothing presses
# Enter on it. That is the intended posture for a security prompt: SURFACE it,
# do not silently confirm it. Making the pane visible is this change's whole
# job; answering it stays a human's.
#
# DECLARED COVERAGE BOUNDARY, stated rather than implied. Caught: any dialog
# rendered in Claude Code's select idiom — a `❯` cursor on one option, at least
# one sibling option in the same column, an Enter/Esc footer — whatever it asks
# about, numbered or not. NOT caught: a dialog with a different footer literal,
# one with a single option, one whose options are not column-aligned, one with
# no `❯` cursor at all (a free-text or yes/no-keypress prompt), or one that
# leaves the REPL row painted underneath.
# For those the state stays `empty`, i.e. exactly as blind as before this change
# — no regression, but no coverage either. Closing them needs a new capture from
# the live binary, not a wider regex guessed at from here.
_has_menu_dialog_frame() {
    local plain="$1"
    local footer_re='(Enter|Esc) to [a-z]'

    # (a) navigation footer within the last 3 non-blank rows.
    grep -qE "$footer_re" \
        <<<"$(printf '%s\n' "$plain" | grep -v '^[[:space:]]*$' | tail -n 3)" || return 1

    # Anchor on the LAST footer occurrence, so a pane that quotes a dialog and
    # is ALSO wedged on one resolves to the live one.
    local footer_ln
    footer_ln=$(grep -nE "$footer_re" <<<"$plain" | tail -1 | cut -d: -f1)
    [[ -n "$footer_ln" ]] || return 1

    local above
    above=$(head -n "$(( footer_ln - 1 ))" <<<"$plain")

    # (b1) a CHEVRON-SELECTED option row ABOVE the footer — a highlighted
    # choice, which is what makes the frame a DECISION rather than a notice.
    # `❯` + one-or-more ASCII spaces + a non-space; the REPL input row is
    # `❯` + NBSP, so this cannot match a user who typed at the prompt.
    #
    # LITERAL SPACES, not `[[:space:]]`, and that is load-bearing rather than
    # cosmetic: in a UTF-8 locale `[[:space:]]` can match NBSP, which would let
    # the REPL input row itself satisfy the very condition (c) exists to
    # exclude. It also makes the column arithmetic below exact — a TAB counts
    # one character and displays as several, and only spaces are equal to
    # themselves in both.
    local sel_line
    sel_line=$(grep -E '^ *❯ +[^ ]' <<<"$above" | tail -1)
    [[ -n "$sel_line" ]] || return 1

    # (b2) at least one COLUMN-ALIGNED SIBLING option row.
    #
    # WHY ALIGNMENT RATHER THAN `N.` NUMBERING (your-org/nexus-code#1112).
    # Until 2.1.247 this asked for `❯ 1.` plus a second `N.` row. Claude Code
    # 2.1.248 DROPPED THE ORDINALS from the workspace-trust dialog while
    # changing nothing else about it — measured, one tree, binary the only
    # variable:
    #
    #   2.1.246:  ' ❯ 1. Yes, I trust this folder' / '   2. No, exit'
    #   2.1.248:  ' ❯ No, exit'                     / '   Yes, I trust this folder'
    #
    # Numbering was never the structural fact; it was a rendering detail that
    # happened to be stable. Keying on it classified a LIVE trust dialog as
    # `empty` — "don't know yet" — from 2.1.248 onward, which is the #896 blind
    # spot reopened by a repaint, exactly the failure #896 set out to make
    # impossible. A worker sitting at that dialog is invisible to the unstick
    # machinery and reads to the orchestrator as a slow boot.
    #
    # What IS structural is that a select menu paints its options in a COLUMN:
    # the cursor row's option text and every unselected sibling's text begin at
    # the same character offset, the cursor occupying the gutter. That holds for
    # BOTH renderings above — text at offset 3 in each — and it is a property of
    # the LAYOUT, not of the wording or the list markers, so it survives a
    # re-word, a re-order and an ordinal change alike. Note the deliberate
    # non-answer: the prose rows of the trust dialog sit at offset 1 and the box
    # rule at offset 0, so they are not siblings.
    #
    # The offset is derived from the cursor row rather than guessed: leading
    # spaces + the chevron + the gap after it. `${#lead}` and `${#gap}` count
    # only spaces, so byte- and character-length agree.
    local lead rest gap opt_col sib_re
    lead=${sel_line%%❯*}
    rest=${sel_line#*❯}
    gap=${rest%%[! ]*}
    opt_col=$(( ${#lead} + 1 + ${#gap} ))
    printf -v sib_re '^ {%d}[^ ]' "$opt_col"
    grep -qE "$sib_re" <<<"$above" || return 1

    # (c) no REPL input row below the footer ⇒ the dialog replaced the REPL.
    if grep -qF "❯${NBSP}" <<<"$(tail -n +"$(( footer_ln + 1 ))" <<<"$plain")"; then
        return 1
    fi

    # (d) THE AGENT IS NOT DEMONSTRABLY WORKING. (c) asks whether a REPL row is
    # PRESENT, which is an absence test, and this repo documents TWO regimes in
    # which a live REPL paints no `❯<NBSP>` row at all:
    #
    #   * the queued-message placeholder — `❯` + ASCII space, deliberately not
    #     matched by `_find_input_row` (`_detect_queued_message`, #603/#607);
    #   * the #47 mid-render window, which ships its own fixture
    #     (`busy-mid-render-no-chevron-synthetic.ansi`).
    #
    # In both, (c) is inert, and (a)/(b) are satisfied by any pane QUOTING a
    # dialog — a shape workers here render constantly, since the trust dialog's
    # text lives in the issue, in this comment, in `synthesize.sh` and in the
    # test file. Measured before this condition existed: a busy pane quoting the
    # dialog went `busy` → `blocked`, and a pane with a queued message went
    # `busy queued=1` → `blocked overlay=workspace-trust`, swallowing the
    # do-not-paste signal `#603`/`#607` added. `_has_blocked_overlay` runs FIRST
    # in the chain — ahead of the over-limit stamp, the queued-message check and
    # `_detect_busy` — so the false positive preempted every busy signal
    # downstream. Found by the `#896` skeptic; this is their remedy.
    #
    # So the live-ness question is answered with POSITIVE evidence of work in
    # flight, not only with the absence of a chevron. A real dialog has replaced
    # the REPL: nothing is streaming, so neither test can fire on one. The
    # failure direction is back to `empty` — exactly as blind as before `#896`,
    # never a phantom decision on a working pane.
    if _detect_busy "$plain" "$(wc -l <<<"$plain")" \
       || _detect_queued_message "$plain"; then
        return 1
    fi
    return 0
}

# Name the dialog `_has_menu_dialog_frame` just detected. NAMING ONLY — the
# detection above never consults this, so an unrecognised dialog is still
# `blocked`, just under the honest generic kind `dialog` rather than a
# borrowed one. Add an arm here when a new dialog is worth naming; do NOT add
# one to make a new dialog detectable, because it already is.
_name_menu_dialog_kind() {
    local plain="$1"
    if grep -qF 'trust this folder' <<<"$plain" \
       || grep -qE 'Is this a project you created or one you trust\?' <<<"$plain"; then
        printf 'workspace-trust'; return 0
    fi
    if _dialog_is_login "$plain"; then
        printf 'login'; return 0
    fi
    printf 'dialog'
}

# THE `/login` FLOW (your-org/nexus-code#1518).
#
# Captured from the real binary at 2.1.268 through `monitor/cc-harness` against
# the auth-free mock backend — no real `/login`, no credentials, no egress.
# Step one (`blocked-login-method-realmodel-268.ansi`):
#
#        Login
#
#        Claude Code can be used with your Claude subscription or billed based …
#
#        Select login method:
#
#        ❯ 1. Claude account with subscription · Pro, Max, Team, or Enterprise
#          2. Anthropic Console account · API usage billing
#          3. 3rd-party platform · Amazon Bedrock, Microsoft Foundry, or Vertex AI
#
#        Esc to cancel
#
# and step two (`blocked-login-signin-realmodel-268.ansi`) is the same frame
# with `Anthropic Console account` / `How do you want to sign in?`.
#
# WHY THIS ARM IS A REFINEMENT AND NOT THE GATE — and it is the whole reason
# the string rot here is affordable. Both frames ALREADY classify
# `state=blocked overlay=dialog` at `4f73e0e7`: they are select dialogs, and
# `_has_menu_dialog_frame` keys on the frame, not on the wording. `blocked` is
# in `_BK_ACTIVE_STATES` (never kill-authorised) and `paste-followup.sh:889`
# has refused to paste into it since `#1200`. So what the watcher's emit hold
# rests on is `state=blocked`, a STRUCTURAL property of a select dialog; this
# function only says WHICH dialog, which is what the hold's log line, its
# `sandbox-notify` text and its escape eligibility read.
#
# FAILURE DIRECTION, therefore: a vendor reword drops `overlay=login` back to
# `overlay=dialog` and the hold STILL ENGAGES — the operator's login is still
# not pasted over. What degrades is the diagnosis, not the protection. That is
# the opposite of `_detect_auth_expired` below, whose miss is NOT safe, and the
# two are deliberately documented apart rather than as one "login detector".
#
# THREE DISJUNCTS, each covering a different reword:
#
#   (a) a bare `Login` HEADER row. The frame's title, and it survives any
#       rewording of the question below it. Anchored `^…$` on its own row so a
#       transcript mentioning the word cannot reach it; the caller has already
#       established a dialog frame, so the population here is dialog text.
#   (b) `Select login method:`   — step one's question.
#   (c) `How do you want to sign in?` — step two's.
#
# (b) and (c) carry the case where the title is reworded but the prompt is not.
# Matched case-insensitively for `#1340`'s measured reason: a CAPITALISATION-
# ONLY vendor change silently returned a throttled pane to `idle`, and the two
# characters that remove that axis are free.
_dialog_is_login() {
    # ANCHORED TO THE BOTTOM 20 NON-BLANK ROWS, not the whole pane (skeptic
    # w237sk F7). Disjunct (a) is a bare `Login` row, and over the whole pane
    # that matched a `Login` row anywhere in the TRANSCRIPT — measured: the
    # unnamed-dialog fixture plus one transcript row `Login` produced
    # `overlay=login auth=login`. A dialog occupies the bottom of the pane
    # because it REPLACES the REPL, so the bottom rows are where its own text
    # is; 20 is chosen to clear the longest frame measured (the code-paste step
    # runs ~13 non-blank rows including a four-line wrapped URL).
    #
    # `_bottom_rows` strips blanks BEFORE bounding, for `#568`'s measured reason:
    # under the fullscreen renderer the gap above the dialog is blank padding, so
    # a raw `tail` would count padding as rows.
    #
    # Post-F1 the cost of a false positive here is the LABEL only — the hold
    # keys on `state=blocked`, so a mis-named dialog is still held and the
    # notification says the kind is unknown. That is why this is an anchoring
    # improvement rather than a correctness fix.
    local region
    region=$(_bottom_rows "$1" 20)
    grep -qiE '^[[:space:]]*Login[[:space:]]*$' <<<"$region" && return 0
    grep -qiF 'Select login method:' <<<"$region" && return 0
    grep -qiF 'How do you want to sign in?' <<<"$region" && return 0
    # (d) THE CODE-PASTE / BROWSER-AUTH STEP, added for w237sk F2 and the reason
    # it is its own disjunct rather than folded into (a): it is the screen where
    # a stray paste is WORST — the emit body lands in the auth-code field and the
    # trailing Enter SUBMITS it, failing the login outright — and it is the one
    # the menu-frame gate could never reach. Measured on the LIVE 2.1.268 pane:
    #
    #     Login
    #     Browser didn't open? Use the url below to sign in (c to copy)
    #     https://claude.com/cai/oauth/authorize?...
    #     Hold Shift while selecting to use your terminal's native copy
    #     Paste code here if prompted >
    #     Esc to cancel
    #
    #     state=empty   <- NOT `blocked`: no `❯ ` option rows, so
    #                      `_has_menu_dialog_frame` declines and the whole
    #                      `_has_blocked_overlay` chain never reaches the namer
    #
    # So `state=` does not cover it and `auth=login` must. Two literals, either
    # sufficient, both the harness's.
    grep -qiF 'Paste code here if prompted' <<<"$region" && return 0
    grep -qiF 'Use the url below to sign in' <<<"$region"
}

# THE AUTH FAILURE — the orchestrator is LOGGED OUT and says so
# (your-org/nexus-code#1518, the pane-surface half of `#1517`).
#
# `#1517` measured 45 h of `Login expired · Please run /login` drawing 8
# resubmits and 10 false `recovered` lines, and listed under *What is NOT
# determined*: "Whether `pane-state.sh` or any other surface shows the
# `Login expired` state. Not checked." It does not. Measured at 2.1.268,
# mid-retry and then terminal once retries exhaust:
#
#   ✻ 401 OAuth token has expired. Please obtain a new token or refresh your …
#     existing to… · Retrying in 16s · attempt 6/10
#
#   ● Please run /login · API Error: 401 OAuth token has expired. Please obtain
#     a new token or refresh your existing token.
#   ✻ Cooked for 0s · done 1:49 AM
#
# BOTH classify `state=idle active=0 input=blank`. There is no token counter and
# no `esc to interrupt`, so neither `_detect_busy` nor `_detect_throttled` fires
# — and `idle` is on `_bookkeeping.sh`'s KILL allowlist and is the canonical
# paste-me state. Fixtures: `auth-expired-retrying-realmodel-268.ansi`,
# `auth-expired-terminal-realmodel-268.ansi`.
#
# WHAT THIS FIELD IS FOR, AND WHAT IT IS NOT FOR. It does NOT hold the emit.
# Pasting into a logged-out but idle REPL is harmless — the text lands in the
# input box and at worst errors again — and the operator NEEDS the board state
# waiting for them when they log back in. What `#1517` cost was the RESUBMIT
# STORM and the false `recovered`: remedies that cannot work, reported as
# working. So `auth=expired` gates `orchestrator-liveness` (no resubmit, no
# respawn, and the word `auth` in the log, which `#1517` found absent from all
# 1,648 lines) and fires one `sandbox-notify`. The emit HOLD is `auth=login`'s
# job, on the `blocked` dialog, which is a different surface with a different
# hazard.
#
# That split is what keeps this detector's error costs small, and it is worth
# stating because the obvious design — one "login detector", one hold — makes
# both directions expensive. Here a MISS returns us to `#1517` exactly and an
# OVER-FIRE costs a redundant notification plus a liveness remedy declined for
# one cycle.
#
# FAILURE DIRECTION, STATED PLAINLY AND IT IS NOT SAFE. `state=idle` is what
# this pane reads, so unlike `_dialog_is_login` above there is NO structural
# fallback underneath these strings: if they rot, the detector returns `none`
# and `#1517`'s behaviour comes straight back. No claim is made that it fails
# safe. The mitigation is breadth — three independent disjuncts, one per
# measured render, any ONE sufficient — plus the entry on the collision list
# `skills/nexus.cc-update/GUIDE.md` checks before a pin bump, beside `#1340`'s
# `/low-priority` strings. Both string sets are the HARNESS's, not ours.
#
#   (a) `Please run /login`      — the terminal render, and `#1517`'s own text.
#   (b) `Login expired`          — `#1517`'s transcript wording.
#   (c) `401` + `token has expired` ON ONE ROW — the mid-retry render, whose
#       text is the API's rather than the TUI's, so it rots on a different
#       schedule. Both tokens required on the same row: `401` alone matches a
#       transcript discussing HTTP, and `token has expired` alone matches an
#       agent reading this comment.
#
# BOUNDED TO THE BOTTOM 15 NON-BLANK ROWS, via `_bottom_rows` and for `#568`'s
# measured reason: a raw `tail` conflates the last rows of CONTENT with the last
# rows of the GRID, and under the fullscreen renderer the gap above the input
# box is blank padding — in the terminal fixture the auth row is 29 GRID rows
# above the prompt and 6 CONTENT rows above it. The bound is also what keeps
# this from going STICKY: the error is a transcript row, so without a bound an
# hour-old failure the operator has already fixed would keep asserting
# `auth=expired` out of scrollback. 15 matches `_detect_over_limit`'s window,
# which is the already-exercised number rather than a fresh guess.
_detect_auth_expired() {
    local plain="$1" bottom
    bottom=$(_bottom_rows "$plain" 15)
    grep -qiF 'please run /login' <<<"$bottom" && return 0
    grep -qiF 'login expired' <<<"$bottom" && return 0
    grep -qiE '401.*token has expired|token has expired.*401' <<<"$bottom"
}

# Bypass Permissions warning modal (your-org/nexus-code#768).
#
#   WARNING: Claude Code running in Bypass Permissions mode
#   ❯ 1. No, exit
#     2. Yes, I accept
#   Enter to confirm · Esc to cancel
#
# WHY THIS NEEDS A NAME OF ITS OWN. On its first boot the binary MIGRATES
# `.claude.json`'s `bypassPermissionsModeAccepted` into `settings.json` as
# `skipDangerousModePermissionPrompt: true` and DELETES the original key
# (measured on 2.1.224). After any boot, the only thing suppressing this modal
# lives in `settings.json` — so anything that rewrites that file between boots
# without re-supplying the key wedges the NEXT boot here.
#
# Before this arm the modal matched nothing. It has a `❯ N.` menu but not `Do
# you want to proceed?`, so it fell past every overlay arm to the input-row
# logic, which finds no `❯<NBSP>` chevron and lands on the tail of case 2:
#
#   * production (claude alive, rendering the modal) → `empty`, which means
#     "don't know yet" and reads as a SLOW BOOT. That mis-signposting is the
#     entire cost of #768: it burned a probe run of three cells reported as
#     "VI mode is unreachable", which was nothing of the kind.
# This arm addresses that path, and ONLY that path.
#
# A pane whose pid yields no live claude reports `absent` instead — the ONE
# kill-authorising state. THIS ARM CANNOT REACH THAT CASE and does not claim to:
# the liveness gate near the top of the classification chain `exit 0`s a couple
# of hundred lines before the overlay check below ever runs. Measured (#776
# skeptic): the live-modal fixture with a dead pane-pid still classifies
# `absent`, not `blocked`. In production the distinction is moot — a pane wedged
# on this modal has a live claude rendering it, so the gate is skipped and this
# arm IS reached — but the `absent` side is upstream territory (`#780`), not
# something the naming here covers. An earlier version of this comment implied
# it did.
#
# LIVE-vs-QUOTED, and the reason is sharper here than for the AskUserQuestion
# arm: the modal's text is QUOTED IN THE ISSUE, so any agent reading #768 — or
# this comment — has all of it on screen. Two option literals gate the shape.
# Live-ness is gated by TWO tests, and the second is the load-bearing one.
#
# WHY NOT A BOTTOM-SLICE MARGIN ALONE. The first version gated live-ness only on
# `Enter to confirm` landing in the last 3 non-blank rows. The #776 skeptic
# CONSTRUCTED the pane that defeats it — an idle agent quoting the modal with
# just two chrome rows below the footer classified `blocked` — leaving a 2-row
# margin as the only thing separating a wedged worker from one merely discussing
# the wedge. Their proposed fix was to tighten the window to `tail -n 1`, since
# the live footer is the last non-blank row. That widens the margin but keeps the
# margin as the discriminator, and it trades a SAFE-direction error for an
# UNSAFE one: any trailing chrome on a real wedged pane (a status row, a redraw
# artefact) would push the footer out of a 1-row window and drop the case back to
# `empty` — the exact mis-signposting #768 exists to end. Neither of us has a
# capture of a real wedged pane, so tuning a margin against an unmeasured layout
# is guessing in the direction that fails silently.
#
# So the margin stays generous (3), and a STRUCTURAL test carries the weight: a
# live modal REPLACES the REPL, so no `❯<NBSP>` input row can appear BELOW the
# footer. A pane discussing the modal is still a running REPL and keeps its
# input row underneath. That is a property of what the two panes ARE, not of how
# many rows happen to trail the quote, so it holds at every margin.
#
# RESIDUAL, stated rather than papered over: a pane quoting the modal whose own
# REPL row has scrolled out of the 25-row capture has no input row below the
# footer and would still classify `blocked`. The direction is safe — `blocked`
# is in _BK_ACTIVE_STATES so it is never kill-authorised, and no `_unstick.sh`
# arm fires on this modal — but the orchestrator would chase a configuration
# fault that is not there.
_has_bypass_permissions_modal() {
    local plain="$1"
    grep -qF 'Bypass Permissions mode' <<<"$plain" || return 1
    grep -qF 'Yes, I accept' <<<"$plain" || return 1
    grep -qF 'Enter to confirm' \
        <<<"$(printf '%s\n' "$plain" | grep -v '^[[:space:]]*$' | tail -n 3)" || return 1
    # The structural test. Anchor on the LAST footer occurrence so a pane that
    # quotes the modal and is *also* wedged on it resolves to the live one.
    local footer_ln
    footer_ln=$(grep -nF 'Enter to confirm' <<<"$plain" | tail -1 | cut -d: -f1)
    [[ -n "$footer_ln" ]] || return 1
    if grep -qF "❯${NBSP}" <<<"$(tail -n +"$(( footer_ln + 1 ))" <<<"$plain")"; then
        return 1   # a REPL input row lives below the footer ⇒ the pane is quoting
    fi
    return 0
}

# AskUserQuestion chip-bar overlay (Case D — dialog-guard). Claude
# Code's `AskUserQuestion` tool renders a numbered-options menu whose
# always-present trailing items are the literal strings `Type
# something.` (the free-form input shortcut) and `Chat about this`
# (the return-to-chat escape). Detection requires BOTH so benign
# prose mentioning either phrase doesn't false-trigger.
#
# Layer A1 of the dialog-guard (the `PreToolUse` matcher in
# `monitor/orchestrator-settings.json`) blocks the orchestrator from
# ever dispatching `AskUserQuestion`; this overlay detection is the
# Layer B safety net for orchestrator sessions that started without
# the hook (stale install, corrupt settings) and for any future tool
# whose rendered shape carries the same chip-bar signature.
_has_askuq_overlay() {
    local plain="$1"
    grep -qF 'Type something.' <<<"$plain" \
        && grep -qF 'Chat about this' <<<"$plain"
}

# Anchor the over-limit notice on the bottom 15 rows of the pane. The
# canonical text Claude Code renders is:
#
#     You've hit your limit · resets 3am (America/Los_Angeles)
#     /extra-usage to finish what you're working on.
#
# but the headline VARIES by limit flavor — the 2026-07-14 incident
# (your-org/nexus-code, over-limit emits) rendered
#
#     You've hit your weekly limit · resets 3am (America/Los_Angeles)
#
# and the exact-substring match on "You've hit your limit" silently
# missed it, disabling the whole watcher-side hold. The match is now
# a regex tolerating a flavor word between "your" and "limit"
# ("weekly", "5-hour", "usage", …), a hit/reached verb, and any
# apostrophe glyph (the TUI has rendered both ' and ’ historically —
# the pattern anchors on "ve" and skips the apostrophe entirely).
#
# Detection tests the banner's STRUCTURE, not substring presence
# (your-org/nexus-code#571). Three anchors gate it, all on ONE row:
#
#   1. POSITION — bottom-15 non-blank rows, so a paraphrase or quote
#      up in scrollback stays out of the window (issue #87 edge case).
#   2. CLEAN LEAD-IN — what precedes the headline on its line must be
#      only whitespace (the subscription banner paints at column 0) OR
#      the client's own error decoration `● API Error: Request
#      rejected (<code>) · ` (the retry-exhaustion render, the form
#      cc-harness/test-realmodel-overlimit pins). A relay or paste
#      that REPRODUCES the notice renders it as MESSAGE content —
#      markdown-quoted (`> You've …`), bulleted (`● user pasted:
#      "You've …"`), or embedded mid-sentence — so the headline is NOT
#      at a clean lead-in and is rejected.
#   3. CONTIGUOUS COMPANION — `resets <time>` must follow the headline
#      on the SAME line (the `· resets` shape both genuine renders
#      share). This defends against a half-rendered notice (headline
#      only, mid-redraw) AND against prose that mentions "hit your
#      limit" and "resets" on separate lines — the loose two-grep form
#      this replaced false-parked on exactly that.
#
# Why NOT a bare `^[[:space:]]*` line-start anchor (the reverted
# your-org/nexus-code#591): the retry-exhaustion banner paints the
# headline MID-LINE, prefixed by `● API Error: Request rejected (429)
# · `. `^[[:space:]]*` does not match that row, so it would have
# silently BLINDED the detector to the render the repo's own
# real-binary test treats as a true positive — an invisible miss,
# strictly worse than a noticed false-park. Verified against the exact
# CI-captured row; the negative control (strip the prefix → line-start
# match) isolates the anchor as the cause.
#
# Coverage boundary: this matches the two client-EMITTED render forms
# observed as of 2026-07-30 — the subscription line-start banner and
# the `API Error` retry-exhaustion line — and rejects markdown /
# bulleted / prose reproductions. A verbatim quote that reproduces the
# EXACT client structure at a clean lead-in still matches; that
# residue is bounded by design — this scrape is the FALLBACK for panes
# without the StopFailure hook stamp (1b), which is format-independent
# and the primary signal, and the hold is capped by the parsed reset
# time and fails open with a paste, never latching (_over_limit.sh).
# Last N NON-BLANK rows of a captured pane.
#
# Every bottom-anchored scan in this file wants "the most recent N rows of
# CONTENT". `tail -n N` conflates that with "the last N rows of the grid", and
# the two are the same thing only in the inline renderer, where the transcript
# abuts the input box.
#
# In fullscreen (alternate-screen) rendering the input box is pinned to the
# bottom of a full-height screen and the gap above it is padded with blank
# rows. Measured against the real binary via `monitor/cc-harness` at the moment
# the over-limit notice was painted: 40 rows captured, **10 non-blank**, notice
# at raw row 32 from the bottom but non-blank row **6**. So `tail -n 15` saw
# nothing but padding and `_detect_over_limit` returned "no notice" for a pane
# that was visibly painting one — the renderer fallback silently degrading to
# `idle` on a rate-limited worker.
#
# Stripping blanks keeps both properties the raw form was chosen for: still
# bottom-anchored (a scrollback mention further up stays out of the window) and
# still bounded. It only stops blank padding from consuming the budget.
# your-org/nexus-code#568, TUI-fullscreen item 4.
_bottom_rows() {
    grep -v '^[[:space:]]*$' <<<"$1" | tail -n "${2:-15}"
}

# THE banner pattern. ONE definition, shared by the detector and by
# `_over_limit_after_banner` (your-org/nexus-code#1171 R2-A).
#
# It was briefly two: the positional gate added for #1155 residual 1 carried its
# own near-copy inside an `awk` program. Two patterns for one concept is the
# #1143 defect this PR is about, and it bit immediately — see the AWK note below.
# A second definition does not have to DRIFT to be wrong; it only has to be
# evaluated by a different engine.
_OVER_LIMIT_BANNER_RE='^[[:space:]]*(● API Error: Request rejected \([0-9]+\)[[:space:]]*·[[:space:]]*)?You.{0,3}ve (hit|reached) your ([[:alnum:]-]+ ){0,2}limit[[:space:]]*(·[[:space:]]*)?resets[[:space:]]+[^[:space:]]'

_detect_over_limit() {
    local plain="$1" bottom
    bottom=$(_bottom_rows "$plain" 15)
    # ONE row must carry the whole banner structure: a clean lead-in
    # (line-start OR the client `● API Error: Request rejected (<code>)
    # · ` decoration), the flavor-tolerant headline, and a contiguous
    # `resets <time>` companion. See the block comment above for why a
    # bare line-start anchor (#591) is wrong and why the companion is
    # folded onto the same line. The `·` separators are the literal
    # U+00B7 middot the TUI paints; the class after each keeps spacing
    # lenient without loosening adjacency.
    grep -qE "$_OVER_LIMIT_BANNER_RE" <<<"$bottom" || return 1
    return 0
}

# The bottom rows that come AFTER the over-limit banner.
#
# your-org/nexus-code#1155 residual 1 releases the banner when the same capture
# also shows live activity. WHICH SIDE of the banner that activity sits on is
# the whole discrimination, and getting it wrong is a measured regression rather
# than a theoretical one (`#1171` skeptic finding 3): a STALE `↓ N tokens` line
# left ABOVE the banner by the turn that hit the limit flipped a genuinely
# suspended pane from `over-limit` to `busy`. That pane is then never stamped
# and never enters the resume path — the failure the subsystem exists to
# prevent, arrived at from the other direction.
#
# Text painted BELOW the banner was painted AFTER it, so it is evidence the
# session kept working. Text above it is the turn that hit the limit. Anchored
# on the LAST banner match, so a banner quoted earlier in scrollback cannot
# widen the window. Emits nothing when the banner is the final non-blank row —
# a quiet suspended pane, which must hold.
#
# NOT `awk`, AND THAT IS MEASURED RATHER THAN STYLISTIC (#1171 R2-A). This
# function first carried its own copy of the banner regex inside an awk program,
# and it did not survive `mawk` — the default `awk` on Debian/Ubuntu, which any
# operator cloning this repo may have.
#
# THE BOUNDARY, reproduced on this host (mawk 1.3.4 vs gawk 4.1.4). A counted
# group PRECEDED BY A LITERAL, matching exactly ONE repetition whose token is
# THREE OR MORE characters:
#
#     your ([[:alnum:]-]+ ){0,2}limit
#       "your a limit"       mawk YES   gawk YES
#       "your aa limit"      mawk YES   gawk YES
#       "your aaa limit"     mawk NO    gawk YES     <- diverges
#       "your weekly limit"  mawk NO    gawk YES     <- the production banner
#     control, no preceding literal:
#       ([[:alnum:]-]+ ){0,2}limit  on the same line -> mawk YES
#
# NO ENGINE-INTERNAL CAUSE IS CLAIMED; the reproducer is the finding. Two tidier
# rules were tested and REFUTED: it is not "mawk lacks intervals" (`{1,2}` and
# `{1,1}` behave the same, and 1- and 2-character tokens match fine), and it is
# not the POSIX class or the dash (`[a-z]+` diverges identically).
#
# THAT MATTERS FOR THE FIX. Reading the first, broader explanation one might
# reach for `mawk -W repetitions` or a different character-class spelling; the
# divergence survives both. This remedy does not depend on the mechanism being
# right, because it removes awk from banner recognition entirely.
#
# WHY THE GUARD COULD NOT SEE IT. `hit your limit` needs ZERO repetitions, so
# the PLAIN banner matches under both engines. End to end, the WEEKLY banner with
# a stale counter above it read `over-limit` under gawk and `busy` under mawk — a
# real suspension never stamped and never resumed — while the single fixture then
# exercising this path used the PLAIN form. Green under both awks, correct under
# one. `over-limit-weekly-*` and `busy-overlimit-weekly-*` fixtures now pin both
# arms.
#
# The remedy is not a relaxed second regex, it is NO second regex:
# `_OVER_LIMIT_BANNER_RE` is now matched by the same `grep -E` engine that the
# detector uses, so the two cannot disagree about what a banner is — by
# construction rather than by both being written carefully.
_over_limit_after_banner() {
    local plain="$1" bottom last
    bottom=$(_bottom_rows "$plain" 15)
    # LAST match, so a banner quoted earlier in scrollback cannot widen the
    # window. `grep` exiting 1 (no banner) leaves `last` empty and we emit
    # nothing, which the caller reads as "no post-banner activity".
    last=$(printf '%s\n' "$bottom" | grep -nE "$_OVER_LIMIT_BANNER_RE" | tail -1 | cut -d: -f1)
    [[ "$last" =~ ^[0-9]+$ ]] || return 0
    printf '%s\n' "$bottom" | tail -n +"$(( last + 1 ))"
}

# Extract a single-token reset_at value from the canonical notice.
# Examples (input → output):
#   "resets 3am (America/Los_Angeles)"  → 3am_America/Los_Angeles
#   "resets 11pm"                        → 11pm
#   "resets midnight UTC"                → midnight_UTC
# Strips parens, collapses internal whitespace to `_`, caps at 40 chars.
# Returns empty stdout (rc=1) when the suffix isn't on a recognised
# shape — caller substitutes `unknown`.
_extract_over_limit_reset() {
    local plain="$1" bottom raw
    bottom=$(_bottom_rows "$plain" 15)
    # Grab the suffix on the "resets " line, CUT at the next `·`
    # separator — the renderer appends live decoration after the reset
    # time ("… resets 3am (America/Los_Angeles) · Retrying in 8s"
    # while claude retries a soft 429) which would otherwise pollute
    # the token (observed against the real binary in
    # test-realmodel-overlimit.sh). tr removes parens, then a single
    # trailing-punctuation strip, then squeeze ws to `_`.
    raw=$(grep -oE 'resets[[:space:]]+[^[:cntrl:]]+' <<<"$bottom" \
              | head -1 \
              | sed -E 's/[[:space:]]*·.*$//; s/^resets[[:space:]]+//; s/[[:space:]]+$//')
    [[ -n "$raw" ]] || return 1
    raw=$(printf '%s' "$raw" | tr -d '()' | tr -s '[:space:]' '_' | sed 's/_*$//')
    raw="${raw:0:40}"
    [[ -n "$raw" ]] || return 1
    printf '%s' "$raw"
}

# Extract WHICH LIMIT the banner names — the words the banner itself puts
# between "your" and "limit" (your-org/nexus-code#1488).
#
# THE DEFECT THIS CLOSES. The banner regex has always CAPTURED this
# (`your ([[:alnum:]-]+ ){0,2}limit`) and every consumer then DISCARDED it and
# said "Opus". Measured 2026-09-07: a worker hit its FABLE limit, the watcher
# classified it as "weekly Opus limit hit", scheduled a resume against an Opus
# reset, and pasted a resume brief naming Opus. The worker was refused again on
# arrival — 2 resume pastes, 3 rejections — and nothing in that path read the
# pane message that names the real limit, so it could not learn from the
# refusal.
#
# The model tier is not a constant of this codebase. It is written on the
# screen, in the same row the detector already matched, and the honest thing is
# to read it.
#
# Output: the flavour with whitespace collapsed to `_` (e.g. `weekly_Opus`,
# `weekly_Fable`), or rc 1 and empty stdout when the banner names no flavour
# ("You've hit your limit") — the caller substitutes `unknown`, which renders
# as "usage" rather than as a model name nobody measured.
_extract_over_limit_flavour() {
    local plain="$1" bottom raw
    bottom=$(_bottom_rows "$plain" 15)
    raw=$(grep -oE 'You.{0,3}ve (hit|reached) your ([[:alnum:]-]+ ){0,2}limit' <<<"$bottom" \
              | tail -1 \
              | sed -E 's/^You.{0,3}ve (hit|reached) your[[:space:]]*//; s/[[:space:]]*limit$//')
    [[ -n "$raw" ]] || return 1
    raw=$(printf '%s' "$raw" | tr -s '[:space:]' '_' | sed 's/_*$//')
    raw="${raw:0:40}"
    [[ -n "$raw" ]] || return 1
    printf '%s' "$raw"
}

# Stable digest of the pane's TRANSCRIPT region — every line strictly
# ABOVE the last `❯<NBSP>` input row — emitted as `content_hash=` so
# the watcher can tell a changing pane from a static one across cycles
# (your-org/your-nexus#205 follow-up: self-expiring, change-corroborated
# operator-engaged mark). Three regions are deliberately excluded /
# neutralised because they mutate WITHOUT any interaction and would
# otherwise read as "changing":
#
#   - the input row and everything below it (status bar): the
#     autosuggest ghost text and the reverse-video cursor live there,
#     and those are exactly the bytes a TUI redraw fabricates — the
#     fragile signal #270 over-trusted. Excluding the row means a
#     dim autosuggest animating in place never counts as change.
#   - all digit runs: elapsed-timer ticks (`Brewed for 34m 45s`),
#     token counters (`↓ 5.7k tokens`), and `+N lines` badges advance
#     on their own. Stripping every digit neutralises them in one
#     stroke.
#   - right-aligned composer NUDGES (`● <tip> · /<cmd>`): under
#     `tui: fullscreen` these blink in and out of the padded gap ABOVE
#     the input row on their own timer (your-org/nexus-code#573). They
#     are non-numeric, so the digit-strip missed them; the fix keys on
#     RIGHT-JUSTIFICATION — a `●` pushed to the right edge by a LARGE
#     leading-space run (≥32) is chrome, while a `●` at column 0 or any
#     small indent is a real assistant response and is preserved. See
#     the strip below.
#
# Trade-off (the "simplest robust definition" — cleanly isolating only
# the timer/token spans is brittle against renderer churn): output
# whose ONLY delta is numeric reads as unchanged. That biases toward
# "not changing", hence toward RELEASING the window — the intended
# direction per the self-expiry mandate (a released-but-wanted window
# is recoverable; a window pinned open on a stale mark is the worse
# failure). Genuine interaction grows the transcript with non-numeric
# text (new prompts, tool calls, prose), which still moves the hash.
# A `busy` pane streams such text every cycle, so its hash keeps
# moving; the probe additionally treats agent-working states as
# implicit change when no hash is present (heartbeat fast-path).
_content_hash() {
    local plain="$1" input_ln region
    input_ln=$(grep -nF "❯${NBSP}" <<<"$plain" | tail -1 | cut -d: -f1)
    if [[ "$input_ln" =~ ^[0-9]+$ ]] && (( input_ln > 1 )); then
        region=$(awk -v e="$input_ln" 'NR < e' <<<"$plain")
    elif [[ "$input_ln" =~ ^[0-9]+$ ]]; then
        region=""                      # input row is line 1 — nothing above
    else
        region="$plain"                # no chevron — digest the whole capture
    fi
    # Drop the fullscreen composer NUDGE lines before hashing
    # (your-org/nexus-code#573). Under `tui: fullscreen` the input box is
    # pinned to the bottom of the alternate screen and the gap above it is
    # padded with blank rows; into that gap Claude Code periodically flashes a
    # RIGHT-ALIGNED contextual nudge (`● high · /effort`, `● <tip> · /<cmd>`, …)
    # that appears and vanishes on its own timer. It lands ABOVE the `❯<NBSP>`
    # input row, so it falls INSIDE this transcript region, and its text is
    # non-numeric, so the digit-strip below never neutralised it: an
    # otherwise-idle fullscreen pane's hash churned every time a nudge blinked,
    # which kept the watcher's change-corroborated engagement mark alive
    # forever — a window pinned open on a stale mark, the whole of #573.
    # (Measured against the real binary via monitor/cc-harness on tmux 3.4: over
    # 60 s of a genuinely-idle fullscreen pane the ONLY moving bytes in this
    # region were exactly this nudge blinking in and out.)
    #
    # The discriminator is RIGHT-JUSTIFICATION, not the bare glyph: every
    # genuine transcript bullet (an assistant `● …` response) is LEFT-anchored
    # near column 0, while these nudges are right-justified against the
    # composer's right edge — pushed there by a long leading-space run. So we
    # strip a `●` line ONLY when it carries a LARGE leading-space run
    # (`_NUDGE_MIN_INDENT`, default 32). This is what keeps the strip SAFE on
    # the UNRECOVERABLE axis (eating real content blinds change-detection and
    # authorises a kill): a `●` at ANY small indent — a code-fence line, a
    # pasted TUI capture, `systemctl`-style output, a nested-list bullet — is
    # PRESERVED. Measured separation is decisive and gives wide margin: real
    # content sits at ~2–4 leading spaces (deep markdown nesting rarely > ~16),
    # while the right-justified nudge sits at ~64 spaces on an 80-col pane,
    # ~103 on 120-col, ~170 on the 187-col panes real workers run — so 32
    # cleanly splits [≤16] … 32 … [≥64] (your-org/nexus-code#573, skeptic
    # req-001). An ABSOLUTE space count (not a width-relative midpoint) is
    # deliberate: it is ASCII-only and so locale-safe, whereas measuring the
    # row's display width would have to count the multibyte `─` box border and
    # `●`/`·` glyphs, which awk/`wc` size differently under C vs UTF-8.
    # Residual error is biased to the RECOVERABLE side: on an implausibly
    # narrow pane (< ~48 cols) the nudge could fall under the threshold and
    # leak, merely holding a window open one cycle too long — never a kill.
    # In the inline renderer the same nudges render BELOW the input row (out of
    # region), so this filter is a no-op there: one code path, both renderers.
    local bullet=$'\xe2\x97\x8f'       # ● U+25CF, the nudge's status dot
    local min_indent="${_NUDGE_MIN_INDENT:-32}"
    [[ "$min_indent" =~ ^[0-9]+$ ]] || min_indent=32
    printf '%s' "$region" \
        | grep -vE "^[[:blank:]]{${min_indent},}${bullet}" \
        | tr -d '0-9' \
        | tr -s '[:space:]' ' ' \
        | cksum | cut -d' ' -f1
}

_find_input_row() {
    # Anchor on `❯<NBSP>` — the Claude REPL input chevron. Numbered
    # menu options use `❯ <digit>` (ASCII space), so this distinguishes
    # the input row from overlay rows. Last match wins on the rare
    # off-chance the chevron+NBSP shows up in scrollback.
    local pane_ansi="$1"
    grep -F "❯${NBSP}" <<<"$pane_ansi" | tail -1
}

_detect_autosuggest() {
    # TWO renderings, both real. Either one is an autosuggest ghost.
    local input_row="$1"
    # (a) Dim-CURSOR signature: reverse-video first char of the
    #     suggestion, immediately followed by faint/dim on the rest.
    grep -qP $'\x1b\\[7m.\x1b\\[0;2m' <<<"$input_row" && return 0
    # (b) Bare DIM RUN after the chevron, with no reverse-video cursor at
    #     all (your-org/nexus-code#626). The actual bytes, captured live
    #     on 2026-07-30 from window 0:33:
    #
    #         \x1b[39m❯<NBSP>\x1b[2muse (d)
    #
    #     Signature (a) requires the `\x1b[7m` cursor, so it does not
    #     match this at all — which is why NINETEEN windows rendering
    #     ghost text simultaneously all classified `empty`, the "don't
    #     know" value. The orchestrator was then left with only the
    #     unsound `-- INSERT -- + non-blank row ⇒ operator draft`
    #     heuristic, read the ghosts as unsubmitted drafts, and withheld
    #     messages for ~30 minutes rather than risk pasting over real
    #     input. Both arms of that choice cost something; only a
    #     discriminator resolves it, and SGR 2 is one.
    _detect_dim_run "$input_row"
}

# ---- dim CHROME vs dim TEXT (your-org/nexus-code#801) --------------------
#
# Erase every dim (SGR 2) segment whose entire visible content is BOX
# CHROME — the composer's own border — leaving dim segments that carry
# TEXT untouched. Both dim-keyed readers below run through it first, so
# "faint" means "the model wrote this", never "the renderer drew a box".
#
# WHY. `_detect_dim_run` asks whether a faint run carries a visible
# character, over `${input_row#*❯}` — everything after the chevron TO END
# OF LINE. A right-hand box border is dim and it is visible, so it
# satisfies that test exactly as ghost text does. Measured, not reasoned:
# an EMPTY input box rendered `…❯<NBSP>\x1b[7m \x1b[0m   \x1b[2m│\x1b[0m`
# classified `autosuggest-only input=ghost` for 28 s of deterministic
# polling — `state=idle` was UNREACHABLE for that renderer
# (monitor/watcher/test-integration/stub-claude.sh, fixed in `#798`).
#
# Claude Code does not draw that border TODAY: 9 of 9 idle captures under
# monitor/watcher/fixtures/ carry no dim run after the chevron, and the
# rules it does draw are 256-colour grey (`\x1b[38;5;244m`), which is not
# a whole-parameter 2 and never matched. So this is not a live
# misclassification — it is a guard resting on a cosmetic property of
# somebody else's renderer that nothing checked and nobody owns. One
# border glyph moving inside the captured row flips EVERY idle pane on
# the board at once.
#
# THE SECOND CALLER IS THE DANGEROUS ONE. `_input_row_typed_text` cuts the
# row at its first dim run and judges only the head. A dim LEFT border
# sits BEFORE the chevron, so the cut removes the chevron along with it —
# and a vim-INSERT pane carrying REAL OPERATOR TEXT then reads as empty,
# which is the exact failure `#603` added that refinement to close. Not a
# kill (`empty` is not on `bk_pane_kill_authorized`'s allowlist) but an
# absorbing board-stall, `#657`'s shape. One normaliser, both callers, so
# the two cannot drift.
#
# FAIL DIRECTION IS DELIBERATE. If `sed` is missing or errors, the row is
# returned UNCHANGED — i.e. the pre-`#801` over-detecting behaviour. A
# spurious ghost costs the idle/ghost distinction (both states are
# kill-authorised, and `input=ghost` only ever says "safe to paste", which
# an empty box also is). A LOST ghost costs `input=?`, which the
# orchestrator must treat as an operator draft — that is the thirty-minute
# nineteen-pane stall of `#626`. So the degraded mode is the noisy one.
#
# COVERAGE BOUNDARY, AS DATA. Which glyphs count as chrome is
# monitor/watcher/input-box-chrome.manifest, executed by
# test-input-box-chrome.sh — one row per glyph with its disposition, so
# the boundary is a checked fact rather than a claim in this comment. The
# byte ranges below ARE that boundary: U+2500–U+257F (box drawing) and
# U+2580–U+259F (block elements). ASCII `|`/`+` are deliberately NOT
# chrome — they are ordinary characters a suggestion may open with — and
# the manifest says so, so a renderer that ever draws an ASCII border is a
# known, recorded gap rather than a surprise.
#
# LC_ALL=C is load-bearing: the ranges are BYTE ranges over UTF-8, and the
# same expression in a UTF-8 locale would be read as codepoints.
_ESC=$'\x1b'
# One box-chrome BYTE SEQUENCE. U+2500–U+257F (box drawing) is E2 94 80 …
# E2 95 BF; U+2580–U+259F (block elements) is E2 96 80 … E2 96 9F.
_CHROME_BYTES=$'(\xe2\x94[\x80-\xbf]|\xe2\x95[\x80-\xbf]|\xe2\x96[\x80-\x9f])'
# A whole-parameter SGR 2 introducer — the same anchoring `_detect_dim_run`
# uses, so the two cannot disagree about what "dim" means.
_DIM_SGR="${_ESC}\[([0-9]+;)*2(;[0-9]+)*m"
_strip_dim_box_chrome() {
    local row="$1" out
    # <dim introducer><blanks><AT LEAST ONE chrome glyph><blanks/chrome>
    # <ESC | end-of-row>   →   <ESC | ø>
    #
    # The run must contain a chrome glyph. An EMPTY dim run must survive
    # untouched: `\x1b[7mw\x1b[0;2m\x1b[39m…` — dim introducer immediately
    # followed by another SGR — is the reverse-video ghost CURSOR signature
    # that `_detect_autosuggest` arm (a) and `_input_row_typed_text` both key
    # on. A first draft dropped every content-free dim segment and flipped
    # all three real autosuggest fixtures to `user-typing`; the suite caught
    # it, which is why the `at least one chrome glyph` term is written as a
    # separate mandatory element rather than folded into the `*`.
    #
    # No backreference: branch 1's terminator is always the single ESC byte,
    # so the replacement is that literal byte and the group numbering (which
    # shifts with every alternation added to _CHROME_BYTES) stops mattering.
    #
    # LABEL LOOP, NOT `g` (your-org/nexus-code#801, skeptic F1). Branch 1
    # CONSUMES the terminating ESC and re-emits it, and `g` resumes scanning
    # AFTER the emitted byte — so when a dim run's terminator is the NEXT dim
    # introducer, that next run is never re-examined and ADJACENT runs are
    # stripped alternately. Measured on this host:
    #
    #   \x1b[2m│\x1b[0m               → \x1b[0m           stripped
    #   \x1b[2m│\x1b[2m│\x1b[0m       → \x1b[2m│\x1b[0m    ONE SURVIVES  ← the gap
    #   \x1b[2m│\x1b[2m│\x1b[2m│…     → \x1b[2m│\x1b[0m    ONE SURVIVES
    #
    # A survivor is a dim run carrying a visible character, so BOTH halves of
    # `#801` come straight back on a doubled border: `state=idle` unreachable,
    # and a vim-INSERT pane holding real operator text reading `empty`/`?`.
    # `:a … ;ta` substitutes ONE occurrence and re-runs from the start of the
    # line until nothing more matches, so adjacency cannot hide a run.
    #
    # Not live today — 0 of 36 checked-in captures carry adjacent DIM
    # introducers — but 22 of 36 carry back-to-back SGR sequences generally,
    # so adjacent emission is ordinary in this renderer and only the dimness
    # is accidental. That is the same standing this whole guard rests on.
    out=$(printf '%s' "$row" | LC_ALL=C sed -E \
        -e ":a" \
        -e "s/${_DIM_SGR}[ \t]*${_CHROME_BYTES}([ \t]|${_CHROME_BYTES})*${_ESC}/${_ESC}/;ta" \
        -e "s/${_DIM_SGR}[ \t]*${_CHROME_BYTES}([ \t]|${_CHROME_BYTES})*$//" \
        2>/dev/null) || { printf '%s' "$row"; return 0; }
    printf '%s' "$out"
}

# A faint/dim (SGR 2) run carrying visible TEXT on the input row.
#
# The parameter match is anchored so `2` must be a WHOLE SGR parameter:
# `\x1b[2m` and `\x1b[0;2m` match, while `\x1b[22m` (normal intensity)
# and `\x1b[32m` (green) do not. Getting that wrong would classify
# ordinary coloured text as a ghost.
#
# Requires a visible character AFTER the dim introducer, so a dim run
# with nothing in it — or an empty input box — does not match. Box chrome
# is erased first (`_strip_dim_box_chrome`, your-org/nexus-code#801), so a
# dim closing border is not mistaken for a suggestion.
_detect_dim_run() {
    local input_row="$1"
    local tail_text="${input_row#*❯}"
    [[ "$tail_text" != "$input_row" ]] || return 1
    tail_text=$(_strip_dim_box_chrome "$tail_text")
    grep -qP $'\x1b\\[(?:\\d+;)*2(?:;\\d+)*m[ \t]*[^\x1b \t]' <<<"$tail_text"
}

_detect_user_typing() {
    # Bright-white marker that Claude Code emits for user-typed text.
    # See note at top about future renderer changes.
    local input_row="$1"
    grep -qP $'\x1b\\[38;5;231m' <<<"$input_row"
}

# The 10-row slice immediately preceding the input row — the only region in
# which spinner chrome is evidence about the CURRENT turn. The captured
# scrollback often holds older `Cogitating… ↓ 5.7k tokens` lines from past
# steps that have since finished; they would false-trigger if we scanned the
# whole pane. Shared by every in-flight detector below so they cannot drift
# apart about what "the spinner row" means.
_pane_spinner_window() {
    local plain="$1" input_ln="$2"
    local start=$(( input_ln - 10 ))
    (( start < 1 )) && start=1
    awk -v s="$start" -v e="$input_ln" 'NR>=s && NR<=e' <<<"$plain"
}

# A turn is IN FLIGHT but generating no tokens because the harness has
# THROTTLED it — Claude Code's `/low-priority` mode
# (your-org/nexus-code#1340). Measured on this board, two windows
# independently, 2026-09-02:
#
#     ✻ Working at lower priority · waiting for capacity · next try in 3s · attempt 2 · esc to interrupt
#     pane-state: state=idle active=0 window=5 name=wskl input=blank
#
# The worker is mid-turn with a retry counter visibly incrementing, and it
# read `idle` — which `_bookkeeping.sh:bk_pane_kill_authorized` AUTHORISES a
# kill on. That is the 2026-06-15 live-worker-retirement class arriving
# through a NEW HARNESS CAPABILITY rather than through a hand-copied state
# list: `_detect_busy`'s token counter is a PROXY for "a turn is running",
# and `/low-priority` is the first regime in which the proxy and the
# property come apart — a throttled turn is precisely the one not
# generating.
#
# TWO CONDITIONS, both required, and each is holding off a different error:
#
#   (1) THE INTERRUPT AFFORDANCE, `esc to interrupt`, in the spinner window.
#       This is the harness's own "a turn is running and you may stop it"
#       chrome; it is what makes the row LIVE rather than QUOTED. Note the
#       measurement recorded at `_has_menu_dialog_frame` condition (a): a
#       live BUSY pane at 2.1.224 contains ZERO occurrences of `esc to …`,
#       the row being `✻ Smooshing… (16s · ↓ 3 tokens)`. So this string is
#       not a general busy marker on which the token counter is redundant —
#       it is chrome the throttled render adds, which is why detecting the
#       throttle needs its own arm rather than a widened token regex.
#
#   (2) THE CONDITION PHRASE, `waiting for capacity` or `lower priority`.
#       Without it, (1) alone would fire on any pane quoting a spinner.
#
# NOT REQUIRED, deliberately: the `attempt N` / `next try in Ns` counter.
# It is the most specific thing on the row and the most tempting key, and
# keying on it would MISS the first attempt — the window before any retry
# has happened, which is active and would read `idle`. A detector that
# covers the retries and not the first attempt is the silent-zero shape:
# it would look thoroughly tested and leave the opening case exposed.
#
# FAILURE DIRECTIONS, stated because both are real and they are not
# symmetric:
#
#   * MISS (a throttled pane still reads `idle`)  → a live worker is
#     kill-authorised. This is the hazard the whole entry exists for.
#   * OVER-FIRE (a quiet pane reads `busy`)       → the window-cleanup loop
#     declines to retire it and no follow-up paste is sent. Recoverable,
#     and it clears the moment anything else paints.
#
# The reachable over-fire is a pane whose last 10 rows before the prompt
# QUOTE both conditions — an agent displaying this very issue. Its cost is
# a wedge, not a kill, and `idle-empty-synthetic.ansi` is the standing
# negative control that a quiet pane is untouched.
#
# CC-VERSION-SENSITIVE: both strings are the HARNESS's, not ours. A reword
# upstream returns this pane to `idle`, which is the dangerous direction —
# so this belongs on the collision list `skills/nexus.cc-update/GUIDE.md`
# checks before a pin bump.
#
# BOTH MATCHES ARE CASE-INSENSITIVE, and that is not cosmetic. The first cut
# used `grep -qF` / `grep -qE`, and a CAPITALISATION-ONLY change to the vendor
# render — `Waiting For Capacity`, `Esc to Interrupt`, nothing else altered —
# put the pane back to `idle`, i.e. back to KILL-AUTHORISED. Measured, that one
# variant end-to-end through the real authorizer:
#
#   esc to interrupt … waiting for capacity   -> busy  -> REFUSED
#   Esc to Interrupt … Waiting For Capacity   -> idle  -> KILL AUTHORIZED
#
# A fix that a vendor capitalisation silently undoes has not closed the hazard,
# it has postponed it — and the failure is invisible, because the pane simply
# goes back to reading retirable. `-i` costs two characters and removes the
# whole axis. `throttled-low-priority-capitalised-synthetic.ansi` pins it.
#
# NO COLLISION with `_has_menu_dialog_frame`'s deliberately case-SENSITIVE
# footer test: that arm keys on `(Enter|Esc) to [a-z]` to separate overlay
# chrome from a spinner hint, and this one additionally requires the word
# `interrupt` plus a condition phrase, which no confirm/cancel footer carries.
_detect_throttled() {
    local plain="$1" input_ln="$2"
    local window
    window=$(_pane_spinner_window "$plain" "$input_ln")
    grep -qiF 'esc to interrupt' <<<"$window" || return 1
    grep -qiE 'waiting for capacity|lower priority' <<<"$window"
}

_detect_busy() {
    # POSITIVE EVIDENCE THAT A TURN IS IN FLIGHT. Two forms, and the second
    # exists because the first is a proxy that `/low-priority` broke:
    #
    #   (a) an active token counter (`↓ 15.2k tokens`, `↑ 480 tokens`) on the
    #       spinner row. The idle banner uses a past-tense form
    #       (`✻ Brewed for 34m 45s`) with no token counter, so absence of
    #       this counter used to mean idle;
    #   (b) the THROTTLED-RETRY chrome — a turn that is running and
    #       deliberately not generating (your-org/nexus-code#1340). See
    #       `_detect_throttled` for the measurement and the failure
    #       directions.
    #
    # The disjunction lives HERE, in the shared predicate, rather than at the
    # call sites: `_detect_busy` has four callers — the menu-dialog frame's
    # condition (d), the over-limit contradiction, the no-input-row ladder and
    # the main decision — and every one of them is asking the same question,
    # "is this pane demonstrably working". Adding the arm at one call site
    # would have fixed the reported symptom and left three doors open, which
    # is this repo's recurring shape.
    local plain="$1" input_ln="$2"
    local window
    window=$(_pane_spinner_window "$plain" "$input_ln")
    grep -qE '[↓↑] +[0-9]+(\.[0-9]+)?[kKmM]? +tokens' <<<"$window" && return 0
    _detect_throttled "$plain" "$input_ln"
}

_detect_queued_message() {
    # Claude Code REPLACES the input row with a queued-message
    # placeholder while a turn is in flight and the operator (or
    # orchestrator) has submitted text behind it:
    #
    #     ❯ Press up to edit queued messages
    #
    # Note the ASCII space, NOT the `❯<NBSP>` of the real input row —
    # so `_find_input_row` does not match it and classification used to
    # fall through to `empty`, the most ambiguous value available, for
    # the ONE situation an orchestrator most needs to read correctly:
    # input is pending AND the agent is occupied (your-org/nexus-code
    # #603, #607).
    #
    # A queued message is POSITIVE evidence of both facts, so it is
    # never ambiguous. Callers see it as `busy` (every existing consumer
    # already treats `busy` as never-kill, never-paste — no consumer
    # audit required, and no permissive default can be inherited by a
    # brand-new state token) plus a `queued=1` field carrying the extra
    # bit. `busy` is not a euphemism here: Claude Code only queues while
    # a turn is running, and the queue flushes the moment it ends, so
    # "a message is queued" ENTAILS "a turn is in flight".
    local plain="$1"
    grep -qF 'Press up to edit queued messages' <<<"$(_bottom_rows "$plain" 15)"
}

_detect_vim_insert() {
    # Claude Code's vim input mode renders a `-- INSERT --` indicator in
    # the status line. In that mode the operator's typed text does NOT
    # reliably carry the bright-white SGR (`\x1b[38;5;231m`) that
    # `_detect_user_typing` keys on — which is how two panes sitting in
    # `-- INSERT --` WITH VISIBLE OPERATOR TEXT were classified
    # `empty active=0` on 2026-07-29 and became kill candidates.
    local plain="$1"
    grep -qE -- '--[[:space:]]*INSERT[[:space:]]*--' <<<"$(_bottom_rows "$plain" 15)"
}

_input_row_typed_text() {
    # Does the input row carry text the OPERATOR typed, as opposed to an
    # autosuggest ghost? Takes the RAW (ANSI-bearing) row, because the
    # discriminator is an escape sequence.
    #
    # A first cut of this deliberately did not exclude ghost text, on
    # the reasoning that mistaking a ghost for real input is the
    # recoverable error. That reasoning was WRONG, and the existing
    # pane-state fixtures caught it: the autosuggest fixtures also
    # render `-- INSERT --`, so every ghost became `user-typing`. And
    # `autosuggest-only` is itself a kill-authorising state — so the
    # "safe" direction was not safe, it just moved which well-tested
    # distinction got destroyed.
    #
    # The precise discriminator: the ghost BEGINS at the reverse-video/
    # dim pair (`\x1b[7m.\x1b[0;2m`). Anything before that on the row is
    # what the operator actually typed. So cut the row there and judge
    # only the head — which handles the case a naive test cannot: vim
    # INSERT mode with a typed prefix AND a ghost completion after it.
    local raw="$1" head
    # Box chrome first (your-org/nexus-code#801). Both cuts below truncate
    # the row at a dim run, and a dim LEFT border precedes the chevron — so
    # without this the cut takes the chevron with it and a vim-INSERT pane
    # holding real operator text reads as empty, the very reading `#603`
    # added this function to prevent.
    raw=$(_strip_dim_box_chrome "$raw")
    head=$(printf '%s' "$raw" | sed -E $'s/\x1b\\[7m.\x1b\\[0;2m.*$//') || head="$raw"
    # …and the bare-dim rendering of the same thing (#626): everything
    # from the first whole-parameter SGR 2 onward is ghost. Without this
    # the vim-INSERT refinement promotes a ghost to `user-typing`, which
    # is the SECOND direction of the same root cause — the first being
    # `empty` treated as authorising a kill.
    head=$(printf '%s' "$head" | sed -E $'s/\x1b\\[([0-9]+;)*2(;[0-9]+)*m.*$//')
    head=$(printf '%s' "$head" | _strip_ansi)
    local tail_text="${head#*❯}"
    # The chevron is followed by a NON-BREAKING space (U+00A0), which
    # `[[:space:]]` does NOT match in the C locale this script runs
    # under — leaving it in would make every EMPTY vim-mode input box
    # read as "has text" and pin such panes open forever. Drop it
    # explicitly, then judge on ordinary whitespace.
    tail_text="${tail_text//$NBSP/}"
    [[ -n "${tail_text//[[:space:]]/}" ]]
}

_detect_empty_input() {
    # Empty box: cursor is the first reverse-video cell, contains a
    # space, no autosuggest tail, no bright user text.
    local input_row="$1"
    # Canonical fresh-prompt shape: reverse-video space cursor followed
    # by an inline `\x1b[0m` reset (+ padding) on the same captured row.
    grep -qP $'\x1b\\[7m \x1b\\[0m' <<<"$input_row" && return 0
    # Real Claude Code 2.1.147 renders the *post-turn* idle box with the
    # reverse-video space cursor as the LAST cell of the `❯<NBSP>` row —
    # its `\x1b[0m` reset lands on the following line, so the canonical
    # pattern misses it and the pane mis-classifies as `empty`. Surfaced
    # by the real-binary harness (monitor/cc-harness): in production this
    # is masked because workers carry heartbeat hooks that supply `idle`
    # authoritatively, but the renderer fallback (stale/missing
    # heartbeat, inherited panes) regressed silently. Treat a trailing
    # reverse-video space as an empty box too. The caller's decision
    # order (user-typing > busy > autosuggest > empty) has already ruled
    # out the bright-text and dim-autosuggest cases, so a bare trailing
    # `\x1b[7m ` is unambiguously the empty cursor.
    grep -qP $'\x1b\\[7m $' <<<"$input_row" && return 0
    # NOTHING AFTER THE CHEVRON — your-org/nexus-code#657.
    #
    # Both arms above require a reverse-video cursor cell (`\x1b[7m`).
    # Claude Code 2.1.220 renders the idle input box of a pane nobody is
    # looking at as a BARE CHEVRON — the row simply ends at `❯<NBSP>`,
    # with no cursor cell at all. Captured live, the whole row:
    #
    #     \x1b[39m❯<NBSP>
    #
    # So neither arm matches, and the row equally carries no dim run and
    # no bright-white marker: every detector returns false, `input=`
    # falls through to `?`, and the pane emits `empty`.
    #
    # That is ABSORBING, which is what makes it a board-stopper rather
    # than a blemish. The classification depends on chrome that is
    # always rendered, never on transient content, so no amount of
    # waiting clears it: ten wrapped workers sat in `empty`/`input=?`
    # simultaneously for up to 68 h, every one of them refused by
    # `retire-preflight.sh` (correctly — it was told INDETERMINATE) and
    # therefore unretirable through the sanctioned path.
    #
    # The fix is deliberately in CLASSIFICATION, not authorisation.
    # `empty` still means "don't know yet" and the kill allowlist is
    # untouched; this makes a pane that was never actually ambiguous
    # report what it is. "Nothing follows the chevron" is an
    # OBSERVATION, not an inference — it is the definition of an empty
    # input box, and it is the same predicate `_input_row_typed_text`
    # already trusts in the other direction to decide a vim-mode box is
    # empty.
    #
    # This subsumes both arms above (their reverse-video cursor cell
    # strips to a lone space, which is whitespace). They are kept
    # because they are cheap, they document the renderings that
    # motivated them, and a narrow byte-exact match failing open into a
    # general one is the right layering — not the reverse.
    #
    # NBSP is dropped explicitly: the chevron is followed by U+00A0,
    # which `[[:space:]]` does NOT match in the C locale this script
    # runs under, so leaving it in would make every empty box read as
    # "has content" — the precise trap `_input_row_typed_text` documents
    # at its own tail.
    local after
    after=$(printf '%s' "$input_row" | _strip_ansi)
    after="${after##*❯}"
    after="${after//$NBSP/}"
    [[ -z "${after//[[:space:]]/}" ]]
}

# Walk the pane's process tree for a live `claude` (or `claude-code`)
# process. Returns 0 when one is found, 1 otherwise. Used to disambiguate
# `state=empty` (renderer transient — claude alive) from `state=absent`
# (renderer empty AND no claude in the tree — process is truly gone).
#
# The walk uses `pgrep -P <pid>` recursively because the launcher chain
# inserts intermediate `bash` / `bash -c` layers between the pane's
# top-level pid and the `claude` exec. Limited depth=6 to avoid runaway
# walks on pathological trees.
# _pid_runs_claude <pid> -> 0 = yes | 1 = no | 2 = COULD NOT DETERMINE
#
# IDENTITY, NOT NAME (your-org/nexus-code#908). This used to be a `case` on
# `comm` against exactly `claude|claude-code`. `comm` is the INVOCATION NAME —
# argv[0]'s basename, truncated to 15 chars — so it answers "what was this
# called", never "what is this". The SAME shipped binary answers differently
# depending only on the path that reached it:
#
#     via node_modules/.bin/claude (a symlink) -> comm=claude       MATCHED
#     via .../claude-code/bin/claude.exe       -> comm=claude.exe   MISSED
#
# Measured on this host: 17 `claude`, 2 `claude.exe`, and
# `readlink -f /proc/<pid>/exe` IDENTICAL for both —
# `.../@anthropic-ai/claude-code/bin/claude.exe`. The kernel's answer is
# invocation-independent; `comm` is not. So ask the kernel.
#
# WHY THIS MATTERED MORE THAN A MISSED MATCH. A pane booted by real path has
# the live claude as its ROOT process and therefore no descendants — so the
# name miss at step (3) of `_absent_or_unknown_reason` fell through (4) with an
# empty tree, passed (5) because `ps` genuinely works, and past the boot grace
# resolved to `tree-empty-past-grace` = **absent**, the ONE kill-authorising
# state. The ladder is sound and every conjunct was satisfied; it was fed a
# wrong answer by a name comparison made before the walk began. A default-deny
# gate is only as good as the classifier feeding it.
#
# ADDING `claude.exe` TO THE `case` WOULD BE THE SAME BUG ONE STRING WIDER
# (`#915`), so the name test survives only as a FALLBACK for when the kernel
# will not answer.
#
# WHAT THE FALLBACK RETURNS, AND THE RESIDUE IT LEAVES — stated here because an
# earlier revision of this header promised the OTHER design ("a fallback that
# cannot see returns 2 rather than no"), which is not what the code below does.
# Prose documenting the safer behaviour while the code does something else is
# this board's most common defect, and it is worse than silence because it
# stops the next reader checking. So, precisely:
#
#   (b) returns 1 — "not claude" — for a pid whose exe link is unreadable but
#       whose `comm` IS readable and does not match. That is a real negative
#       observation, not an unanswerable question, and it is DELIBERATE.
#   (c) returns 2 — genuinely unknown — only when NEITHER the exe link NOR
#       `comm` will say anything and the pid still exists.
#
# WHY NOT RETURN 2 AT (b). The ladder DECLINES on 2, so widening 2 to cover
# every unreadable-exe pid would make an ordinary process indeterminate on any
# host where /proc is restricted — and `absent` would then never be reached
# again. That trades `#908`'s false-DEAD for a permanent false-ALIVE that never
# self-clears, which is the same trade the first draft of this function already
# got wrong once with exited pids. A stated, bounded residue beats a live
# regression across every ordinary walk.
#
# THE RESIDUE, NAMED: a LIVE agent whose `/proc/<pid>/exe` is unreadable AND
# whose `comm` is not claude-shaped reads "not claude". Measured unreachable
# here rather than argued: every visible process runs as the same uid, and a
# process in a sibling PID namespace (we run inside bwrap) has no `/proc` entry
# to walk at all — it is structurally unobservable, not merely absent. If this
# ever runs somewhere those hold differently, THIS is the line to revisit.
_pid_runs_claude() {
    local pid="$1" exe comm
    [[ "$pid" =~ ^[0-9]+$ ]] || return 2
    # (a) The kernel's own answer. Resolves the .bin symlink, so both
    #     invocation styles land on the same real path.
    # RAW `readlink`, NOT `readlink -f` (your-org/nexus-code#908 F1). A binary
    # DELETED IN PLACE leaves `/proc/<pid>/exe` reading `<path> (deleted)`, and
    # `readlink -f` cannot resolve that — it returns EMPTY, the identity test
    # silently degrades to the name fallback, and the ladder answers `absent`.
    # MEASURED: a live process whose binary was unlinked answered "not claude"
    # and `_absent_evidence` returned `tree-empty-past-grace`. That is `#908`
    # reopened through a different door, inside the fix for `#908` — and it is
    # not exotic: an in-place upgrade puts EVERY live worker in this state at
    # once (this host runs 2.1.224 with 2.1.232 available).
    #
    # NOT SOLVED BY device:inode, which is the tempting "compare the file, not
    # the string" answer: an unlinked inode matches no on-disk file, so an
    # inode test fails in exactly the upgrade case that makes this reachable.
    # The kernel's suffix is a documented, stable part of the interface; strip
    # it and match the path it decorates.
    raw=$(readlink "/proc/$pid/exe" 2>/dev/null)
    if [[ -n "$raw" ]]; then
        exe="${raw% (deleted)}"
        case "$exe" in
            */@anthropic-ai/claude-code/*) return 0 ;;
        esac
        # A candidate installed outside node_modules — cc-harness stages one
        # into a throwaway prefix (`gate.sh` sets CLAUDE_BIN to it), which is
        # exactly the shape that produced `comm=claude.exe`.
        case "${exe##*/}" in
            claude|claude-code|claude.exe) return 0 ;;
        esac
        # An exe we could read but not classify still gets the NAME as a second
        # chance rather than an immediate "no": on the kill axis a missed
        # identity costs a destroyed worker, a spurious one costs a stranded
        # slot, so the tie breaks toward "alive".
    fi
    # (b) No exe link. A ZOMBIE has none by construction (it has exited; only
    #     the unreaped table entry lingers) and so does a pid whose /proc this
    #     process may not read. Opposite meanings, identical symptom — so fall
    #     back to the name, and let the caller apply the zombie test.
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$comm" ]]; then
        case "$comm" in
            claude|claude-code|claude.exe) return 0 ;;
        esac
        return 1
    fi
    # (c) Neither /proc nor ps would say anything about this pid. TWO CAUSES
    #     WITH OPPOSITE MEANINGS, and conflating them was a defect in the first
    #     draft of this fix: a pid that EXITED between the tree walk and this
    #     lookup is simply GONE (it is not a live claude, and saying so is a
    #     real observation), while a pid that still EXISTS but will not be read
    #     is genuinely indeterminate. Measured: transient children exit mid-walk
    #     constantly, so treating (c) as indeterminate wholesale made an
    #     ordinary `zsh` tree report indeterminate and would have turned every
    #     `absent` into a permanent `unknown` — trading #908's false-dead for a
    #     false-alive that never self-clears.
    kill -0 "$pid" 2>/dev/null || return 1
    return 2
}

# Walk the pane's process tree for a live claude. Returns 0 if one is found.
# Sets `_PHLC_INDETERMINATE=1` when any pid in the tree could not be
# identified, so the caller can decline to assert death rather than reading an
# unanswerable question as a negative observation.
_pane_has_live_claude() {
    local pane_pid="$1"
    _PHLC_INDETERMINATE=0
    [[ "$pane_pid" =~ ^[0-9]+$ ]] || return 1
    command -v pgrep >/dev/null 2>&1 || { _PHLC_INDETERMINATE=1; return 1; }
    local depth queue next pid
    queue="$pane_pid"
    for depth in 0 1 2 3 4 5; do
        [[ -n "$queue" ]] || return 1
        # If any pid in this layer IS itself a claude, we're done — unless it's
        # a zombie. A zombie claude has EXITED (only the unreaped table entry
        # lingers, e.g. while tmux is slow to collect a remain-on-exit pane's
        # child); counting it as live would hold the pane out of `absent` for
        # as long as the reap is delayed, exactly the stale-bytes failure this
        # gate exists to prevent.
        for pid in $queue; do
            local pstate _rc
            _pid_runs_claude "$pid"; _rc=$?
            case "$_rc" in
                0)
                    pstate=$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')
                    [[ "$pstate" == Z* ]] || return 0
                    ;;
                2) _PHLC_INDETERMINATE=1 ;;
            esac
        done
        next=""
        for pid in $queue; do
            local kids
            kids=$(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')
            next+=" $kids"
        done
        queue=$(printf '%s' "$next" | tr -s ' ')
    done
    return 1
}

# Does pane_pid have ANY live (non-zombie) descendant? — your-org/nexus-code#643
#
# This is the discriminator between the two situations `_pane_has_live_claude`
# returning false cannot tell apart:
#
#   * NOT YET BORN — the window was just spawned and the generated
#     /tmp/spawn-launcher-*.sh is still running its preamble (shim precondition,
#     write probe, guard block) and has not reached `exec claude`. Measured at
#     2.86 s in a fixture with the real guards; longer in production, where the
#     reporter observed ~20-30 s.
#   * TRULY DEAD — the inner REPL exited and the pane is back at a bare shell,
#     with tmux's `remain-on-exit on` leaving stale bytes on screen.
#
# Both have no `claude` in the tree. Only the first has anything RUNNING under
# the pane shell, so descendant-liveness separates them — and it separates them
# on the axis the mechanism actually varies on, which a grace period does not.
# A timer would have to guess a duration; this asks the question directly, so it
# is still correct for a launcher slower than any threshold anyone would pick,
# and it needs no tuning when the preamble gains a step.
#
# Deliberately generic ("any descendant") rather than pattern-matching the
# launcher name: a matcher keyed on `spawn-launcher-*` would silently regress to
# the old behaviour the day the launcher is renamed or an intermediate wrapper
# is added — a guard whose coverage boundary is drawn on a name nobody
# re-checks. The cost of being generic is that a pane whose agent died while
# some unrelated background process lingers reports `unknown` instead of
# `absent`. That is the SAFE direction and it is also the HONEST one: something
# is running there, so "positively dead" is not a claim this classifier can
# make.
#
# CORRECTION (your-org/nexus-code#777): this comment used to justify "SAFE" with
# the parenthetical "(both are off the kill allowlist)". That is false, and
# false in the direction that matters — `absent` IS on
# `_bookkeeping.sh:bk_pane_kill_authorized`'s allowlist; it is the whole reason
# the state exists. Only `unknown` is off it. The DIRECTION the sentence argues
# for is right (downgrading toward `unknown` is safe); the reason given was
# backwards, and a reader checking the claim would have concluded the gate was
# harmless in both directions when a wrong `absent` is precisely the one that
# is not.
_pane_has_live_descendant() {
    local pane_pid="$1"
    [[ "$pane_pid" =~ ^[0-9]+$ ]] || return 1
    command -v pgrep >/dev/null 2>&1 || return 1
    local depth queue next pid pstate
    queue="$pane_pid"
    for depth in 0 1 2 3 4 5; do
        next=""
        for pid in $queue; do
            next+=" $(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')"
        done
        queue=$(printf '%s' "$next" | tr -s ' ')
        # A queue of nothing but whitespace means this layer had no children.
        [[ -n "$(printf '%s' "$queue" | tr -d '[:space:]')" ]] || return 1
        for pid in $queue; do
            # Zombies do NOT count as live, for the same reason they do not in
            # _pane_has_live_claude: an unreaped table entry is an exited
            # process, and treating it as running would hold a genuinely dead
            # pane out of `absent` for as long as the reap is delayed.
            pstate=$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')
            [[ -n "$pstate" && "$pstate" != Z* ]] && return 0
        done
    done
    return 1
}

# Can this process even SEE processes? — your-org/nexus-code#777
#
# `_pane_has_live_claude` and `_pane_has_live_descendant` both answer "no" two
# ways that are indistinguishable at their return value: the tree really is
# empty, or `ps`/`pgrep` could not tell us. The second is not a negative
# observation, it is the ABSENCE of one — and the gate below converts it into
# `absent`, the ONE kill-authorising state. That is `#612`'s "exit 79 NOT
# CHECKED, never 0" reproduced inside this file: the tmux-missing arm already
# reasons correctly ("we have not looked ⇒ `unknown`") barely thirty lines
# away, and this is the same reasoning with the opposite conclusion.
#
# Measured, both on this host, against a fixture whose bytes classify alive:
#   pgrep stubbed to `exit 1` → state=absent
#   ps    stubbed to `exit 1` → state=absent
#
# So probe the capability DIRECTLY, on ourselves, where the answer is known in
# advance: `ps` must see this very shell, and `pgrep -P` must find a child we
# just forked. A tool that cannot find a process we KNOW exists is blind, and
# its silence about the pane tells us nothing.
#
# Deliberately a self-probe rather than a probe of pane_pid: "ps cannot see
# pane_pid" is the CORRECT reading when the pane process is genuinely gone
# (the fixture-mode `--pane-pid <dead-pid>` contract depends on it), so
# conflating the two would trade this defect for its mirror image and make a
# dead pane unreapable. One extra fork, only on the path about to assert
# `absent`.
_proc_view_functional() {
    command -v pgrep >/dev/null 2>&1 || return 1
    command -v ps >/dev/null 2>&1 || return 1
    # `ps` must see the process asking the question.
    [[ -n "$(ps -o comm= -p "${BASHPID:-$$}" 2>/dev/null | tr -d '[:space:]')" ]] || return 1
    # `pgrep -P` must find a child we know exists. Reaped immediately; the
    # sleep duration only has to outlive the pgrep.
    local kid=""
    # `$BASHPID`, NOT `$$`. `$$` is the ORIGINAL shell's pid and does not change
    # inside a subshell, so a caller that invokes this from a command
    # substitution forks the probe child under the SUBSHELL while `pgrep -P $$`
    # asks about the top-level script — zero matches, and this function then
    # reports the very blindness it exists to detect. Deterministic, not flaky:
    # measured 5/5 on the first draft of `#788`'s `_absent_evidence`, which
    # called it from `tok=$(…)` and turned a dead-pid fixture from `absent` into
    # `unknown reason=proc-view-blind`. `$BASHPID` is the CURRENT shell's pid and
    # is correct in both positions (bash 4.0+; this file already requires 4.4).
    local me="${BASHPID:-$$}"
    sleep 30 &
    # `$!` is UNSET — not empty — when the background fork FAILED, and this
    # file runs `set -u`, so a bare `kid=$!` aborts pane-state.sh outright and
    # it emits NOTHING. That would happen in precisely the fork-starved
    # condition this probe exists to detect (the worker RLIMIT_NPROC ceiling,
    # your-org/nexus-code#487), turning "we could not look" into a crash
    # instead of the `unknown` this whole function exists to produce.
    # Measured: `bash -c 'set -u; echo $!'` is "unbound variable" on both 4.4
    # and 5.2.
    set +u; kid=$!; set -u
    [[ -n "$kid" ]] || return 1
    local seen
    seen=$(pgrep -P "$me" 2>/dev/null | grep -c "^${kid}\$")
    kill "$kid" 2>/dev/null      # pid-scoped: a child this function just forked
    wait "$kid" 2>/dev/null
    [[ "$seen" == 1 ]]
}

# Age of the pane's own process, in whole seconds. Prints nothing when it
# cannot be determined (no ps, or the pid is gone). your-org/nexus-code#777.
#
# tmux forks the pane process when it CREATES the pane, so this process's
# elapsed time IS the pane's age — no tmux format string exposes it directly,
# and `#{window_activity}` tracks output, not creation.
_pane_age_seconds() {
    local pane_pid="$1" age
    [[ "$pane_pid" =~ ^[0-9]+$ ]] || return 1
    age=$(ps -o etimes= -p "$pane_pid" 2>/dev/null | tr -d '[:space:]')
    [[ "$age" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$age"
}

# Walk the BACKGROUND-SHELL subtrees living under claude in the pane's
# process tree (your-org/nexus-code#445, extended for #455 and #590). ONE
# walk, six space-separated fields on stdout:
#     `<count> <cpu> <reliable> <oldest_epoch> <infra> <descriptor>`
#
#   count    number of top-level background-shell subtrees rooted
#            DIRECTLY under claude — the process-truth analogue of the
#            status-line `N shell` token. This is the #455 reliability
#            win: it is derived from the kernel process tree, so it is
#            immune to a user-customised/version-changed status bar and
#            to a regex coincidentally matching unrelated pane text.
#            On the idle path (turn ended) claude's only remaining shell
#            children are `run_in_background` jobs — foreground Bash-tool
#            shells have exited — so this counts exactly the live
#            background shells. A `sleep`-polling background shell still
#            COUNTS (presence, not CPU, is the detector); the orphan-grace
#            below handles the truly-idle/hung case via `cpu`.
#
#   cpu      sum of utime+stime jiffies over every process INSIDE those
#            background-shell subtrees. Emitted as `bg_cpu=<jiffies>` on
#            the `working-background` line so the watcher's idle probe can
#            tell a background job that is genuinely computing (jiffies
#            advancing across cycles) from a truly-orphaned shell doing
#            nothing (jiffies frozen). CORROBORATION substrate for the
#            orphan-grace cap: a `working-background` exemption whose
#            bg_cpu never advances ages out, so a hung/idle background
#            shell can't exempt a window forever. Absolute jiffies (not a
#            rate) — the probe diffs them across cycles; a constant offset
#            is harmless. Semantics unchanged from #445.
#
#   reliable 1 iff this walk is trustworthy as the AUTHORITATIVE
#            background-shell signal: pgrep is present, pane_pid is a
#            numeric pid whose /proc is readable, AND a claude node was
#            found in the tree. When 0 (fixtures, empty pane_pid,
#            /proc-restricted, no claude found) the caller must fall back
#            to the footer/heartbeat signal rather than trust a possibly
#            blind `0`.
#
#   infra    how many of those `count` roots are NEXUS PROTOCOL WAIT LOOPS
#            rather than task work (your-org/nexus-code#590). See the
#            classification note below. Purely additional information: it
#            does NOT change `count`, `cpu`, `reliable` or the resulting
#            pane state, so the `working-background` verdict and the
#            `parked-awaiting-skeptic` exemption that keys off it are
#            unaffected. Only the wrapped-with-children INCONSISTENCY
#            decision in the watcher's idle probe consumes it.
#
#   descriptor a space-free `<comm>:<cmd-tail>` label for ONE representative
#            root, so an emit can NAME the live child instead of reporting a
#            bare count. A non-infra root is preferred (that is the
#            actionable one); `-` when there are no roots at all.
#
# CLASSIFYING A ROOT AS PROTOCOL INFRASTRUCTURE (#590).
# The wrapped-with-children inconsistency fired routinely on every
# skeptic-gated worker, which trains the operator to dismiss it — and then
# the genuine case (a real orphaned `sbatch`/`nohup`) arrives looking like
# the twenty false ones before it. The cause is NOT the MCP server it was
# blamed on: an `mcpServers` entry whose `command` is a non-shell (`uvx`,
# `npx`, `node`, `python` — every server this nexus configures) is spawned by
# claude directly and so is already excluded by the is-a-shell test. Verified
# on the live tree, where the zotero server appears as comm=`uv` with a
# `python` child and contributes 0 to `count`.
#   SCOPE, precisely — the first version of this comment overclaimed that an
#   MCP server can never reach the count, and a reviewer built the
#   counterexample. The retraction, and the reasoning behind it, live ONCE in
#   the "MCP servers:" note below, next to the is-a-shell allow-list that
#   actually implements the exclusion; do not restate it here. The short of
#   it: `command` is an ARBITRARY executable, so a legal `command: "sh"` entry
#   DOES yield a persistent shell child of claude and is counted, classified
#   non-infra. No such server is configured here, and the process tree cannot
#   distinguish it from a task shell (see the foreground-tool-shell note
#   below), so this is a known residual rather than a closed case, guarded by
#   `_pane_mcp_shell_risk` (`pane-state.sh --mcp-shell-risk`). What is
#   verified is narrower and still sufficient: excluded for every MCP server
#   configured with a non-shell `command`, which is all of them today.
#
#   (Two independent fixes for the same finding landed on this file —
#   your-org/nexus-code#598 here and #612 below — and the merge carried both,
#   so the retraction appeared twice and the refuted phrase read as a claim
#   the file still makes. #612's own test caught it. One retraction, beside
#   the mechanism; this paragraph points at it.)
# The actual
# routine child is the worker's own `skeptic-channel await` re-check loop:
# `ng wrap-up` is what tells the worker to hold it in a background shell,
# and it keeps polling for up to its await timeout AFTER a returned verdict
# has cleared the pending marker — so the `parked-awaiting-skeptic`
# exemption lapses while the prescribed child is still alive.
# The discriminator is therefore what the shell is RUNNING, matched against
# the nexus's OWN protocol commands — a structural property of this
# codebase, not a third-party package name (matching e.g. `zotero` would be
# exactly the brittle, package-specific test #590 rules out). The match runs
# over every process in the subtree, not just the root shell, so it holds
# whether the protocol command sits in the shell's own argv (an eval'd
# `zsh -c` tool shell) or in a descendant process.
#
# What counts, and why the scoping matters: we walk the pane tree and
# tally shell subtrees rooted UNDER claude. This EXCLUDES claude/node
# itself (its idle event loop always ticks, which would defeat a progress
# test). The launcher shell hosting claude (the pane's own pid) is likewise
# excluded because it sits ABOVE claude, not under it.
#
# MCP servers: excluded by the is-a-shell allow-list below, for every MCP
# server whose configured `command` is not a shell. That is a CONFIGURATION
# property, NOT a structural invariant, and the distinction is load-bearing.
# This comment previously read "spawned by claude directly as
# `node`/`python`/`uv`, NEVER through a shell", which is false as written: an
# `mcpServers` entry's `command` is an arbitrary executable, and
# `command: "sh"` (the ordinary idiom for env setup or a pipeline) is legal.
# A skeptic built exactly that entry and observed it enter the count as a
# non-infra background shell — reopening the false positive the exclusion is
# credited with closing. Every server configured HERE today is safe
# (`npx`, `uvx`, and an HTTP entry with no `command` at all, so they surface
# as `node`/`uv` and cannot match), but "has never entered the count" and
# "cannot enter the count" are different claims and only the first is true.
#
# The gap is guarded rather than papered over: `_pane_mcp_shell_risk` reads
# the configured MCP commands and reports `shell:<names>` when one of them
# WOULD be counted. Run it (`pane-state.sh --mcp-shell-risk`) when a
# background-shell count has no obvious owner. It reports `unknown` — never
# `none` — when it cannot read the configuration, because a probe that
# answers "clean" because it failed to look is the same defect one level up.
#
# Verified against the live process tree (your-org/nexus-code#455): an
# idle claude with no background job has zero shell children; a real
# `run_in_background` shell (e.g. a supervisor until-loop) is a direct
# claude child and counts; a `uv`/`python` MCP child does not.
#
# Bounded BFS (depth cap) so a pathological tree can't run away. Prints
# `0 0 0 0 0 -` when there is no live claude, no readable /proc, or pgrep is
# unavailable.
# The is-a-shell allow-list, in ONE place. Both the /proc walk (against
# `comm`) and the MCP-config probe (against a configured `command`'s
# basename) ask through this predicate, so the two cannot drift into
# disagreeing about what a shell is — which is the only way the probe below
# could certify a configuration the walk would then count.
_pane_comm_is_shell() {
    case "${1:-}" in
        bash|sh|zsh|dash|ksh|fish|-bash|-zsh|-sh) return 0 ;;
        *) return 1 ;;
    esac
}

# _pane_mcp_shell_risk
#
# Answer the question the comment above no longer asserts away: could a
# configured MCP server be counted as a background task shell?
#
# Prints exactly one of:
#   none              no configured MCP server has a shell `command`
#   shell:<names>     at least one does — comma-separated server names.
#                     A background-shell count on this host may include it.
#   unknown:<reason>  the question could not be answered
#
# It NEVER prints `none` because it failed to look. `unknown` is a distinct
# outcome from `none` for the same reason `#584`'s skipped case is distinct
# from a pass: a check that did not run must not be reported as a check that
# came back clean.
#
# Config surfaces are enumerated explicitly (Claude Code reads MCP config
# from several), and the enumeration itself is the fragile part — a server
# configured somewhere not listed here is invisible. That is why an
# unreadable-or-unparsable file degrades to `unknown` rather than being
# skipped: the failure is at least visible. NEXUS_MCP_CONFIGS (colon-
# separated) overrides the list, for tests and for an operator whose harness
# stores config elsewhere.
_pane_mcp_shell_risk() {
    local -a files=()
    if [[ -n "${NEXUS_MCP_CONFIGS:-}" ]]; then
        local IFS=:
        read -r -a files <<<"$NEXUS_MCP_CONFIGS"
    else
        files=(
            "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
            "$HOME/.claude/settings.json"
            "$HOME/.claude.json"
            "${NEXUS_ROOT:-.}/.mcp.json"
            "./.mcp.json"
        )
    fi

    local -a present=()
    local f
    for f in "${files[@]}"; do
        [[ -n "$f" && -f "$f" ]] || continue
        if [[ ! -r "$f" ]]; then printf 'unknown:unreadable:%s' "$f"; return 0; fi
        present+=("$f")
    done
    (( ${#present[@]} )) || { printf 'none'; return 0; }

    command -v jq >/dev/null 2>&1 || { printf 'unknown:no-jq'; return 0; }

    local -a hits=()
    local cmds name base line
    for f in "${present[@]}"; do
        # Both the top-level `mcpServers` map and the per-project ones. An
        # entry with no `command` (an HTTP/SSE server) yields nothing and is
        # correctly not a risk — it spawns no local process at all.
        cmds=$(jq -r '
            [ (.mcpServers // {}) ,
              ( (.projects // {}) | to_entries | map(.value.mcpServers // {}) )
            ] | flatten
              | map(to_entries) | flatten
              | map(select(.value.command != null))
              | .[] | "\(.key)\t\(.value.command)"
        ' -- "$f" 2>/dev/null) || { printf 'unknown:unparsable:%s' "$f"; return 0; }
        # jq exiting 0 with empty output is a legitimate "no entries"; jq
        # failing is caught above. A malformed file makes jq fail, so it
        # cannot be mistaken for an empty one.
        while IFS=$'\t' read -r name cmd; do
            [[ -n "${cmd:-}" ]] || continue
            base="${cmd##*/}"
            _pane_comm_is_shell "$base" && hits+=("$name")
        done <<<"$cmds"
    done

    if (( ${#hits[@]} )); then
        local joined; printf -v joined '%s,' "${hits[@]}"
        printf 'shell:%s' "${joined%,}"
    else
        printf 'none'
    fi
}

# Diagnostic dispatch (--mcp-shell-risk). Placed here rather than in the
# option loop because the loop runs before these definitions exist.
if (( ${mcp_risk_only:-0} )); then
    printf '%s\n' "$(_pane_mcp_shell_risk)"
    exit 0
fi

# ---- async-run liveness: ESTABLISH, do not infer (nexus-code#1208) --------
#
# `_pane_background_shells` below counts a shell child of claude as work in
# flight. That is an INFERENCE from a proxy ("a shell exists"), and it is wrong
# for the single most common background-shell shape in this workspace: the wait
# wrapper an agent leaves behind around an `async-run` job.
#
#     T=<state>/async-run/<window>/<token>
#     until [ -s "$T/status" ]; do sleep 60; done
#
# When that job is SIGKILLed it writes no status file BY CONSTRUCTION, so the
# `until` loop waits forever. `pane-state` then reports `working-background`
# and `retire-preflight` — correctly default-deny — refuses to retire the
# window, with NO FUTURE EVENT LEFT TO ARRIVE. Measured 2026-08-30 on window
# `olayingestsk2`, token `ar-abdb92e13667`, killed ~3h earlier.
#
# ── WHY THIS CALLS OUT INSTEAD OF REIMPLEMENTING ────────────────────────
#
# `async-run.sh` ALREADY owns the authoritative three-verdict model —
# `terminal` / `running` / `died` — including the pid-IDENTITY check (pid
# alive AND `/proc` start-time matching) that stops a recycled pid reading as
# a confident `running`. #1208 is precisely the failure of ONE fact having TWO
# answerers, where the second answerer is the one every consumer reads. Growing
# a second `died` detector here would reproduce the defect inside its own fix,
# so this asks the existing authority.
# How many async-run jobs one background-shell root may name before the walk
# stops trying to resolve it. Exceeding this makes the root NOT stale, never
# stale — the cap bounds work, it must never manufacture a retirement.
_PANE_ASYNCRUN_MAX_REFS="${NEXUS_PANE_ASYNCRUN_MAX_REFS:-16}"
[[ "$_PANE_ASYNCRUN_MAX_REFS" =~ ^[0-9]+$ ]] && (( _PANE_ASYNCRUN_MAX_REFS > 0 )) \
    || _PANE_ASYNCRUN_MAX_REFS=16

_pane_asyncrun_refs() {
    local c="${1:-}" rest out="" re
    # Read the cap DEFENSIVELY rather than relying on the file-scope
    # assignment: these helpers are lifted out by name and sourced in
    # isolation by test-pane-state-asyncrun-liveness.sh, and a bare
    # reference would be an unset-variable error there under `set -u` —
    # i.e. the instrument would fail for a reason that has nothing to do
    # with the property under test.
    local cap="${_PANE_ASYNCRUN_MAX_REFS:-16}"
    [[ "$cap" =~ ^[0-9]+$ ]] && (( cap > 0 )) || cap=16
    # Bash-native, no subprocess: this runs inside the /proc walk on the
    # watcher's hot path, and it must not depend on any PATH-resolved `grep`.
    re='(/[^[:space:]"'"'"']*/async-run/[A-Za-z0-9._@:+-]+/ar-[0-9a-f]+)'
    rest="$c"
    # Hard iteration bound. `rest` provably shrinks each pass (the match is
    # non-empty by construction), so this cannot spin — but this runs on the
    # watcher's hot path inside a /proc walk, and a loop whose termination
    # rests on a regex being non-empty is one edit away from not terminating.
    local guard=0
    while [[ "$rest" =~ $re ]]; do
        out+="${BASH_REMATCH[1]}"$'\n'
        rest="${rest#*"${BASH_REMATCH[1]}"}"
        guard=$(( guard + 1 ))
        if (( guard >= cap )); then
            # TRUNCATION MUST DISQUALIFY, and this is not a nicety — it is the
            # #1208 defect class reappearing inside its own fix, and the
            # differential cap case in
            # test-pane-state-asyncrun-liveness.sh caught it.
            #
            # Staleness requires EVERY ref under a root to be `died`. So
            # silently dropping refs can only make a root MORE likely to be
            # called stale: the ref that would have been `running` is the one
            # that never gets looked at. A bound that quietly shortens the
            # evidence therefore fails toward RETIRING LIVE WORK — the exact
            # direction everything else here is built to avoid.
            #
            # Emitting a sentinel keeps the disqualification in the SAME
            # channel as the evidence, so no caller can forget to ask: it is
            # not a valid ref, `_pane_asyncrun_ref_is_died` refuses it like
            # any other unresolvable input, and the root drops out.
            out+='!truncated'$'\n'
            break
        fi
    done
    printf '%s' "$out"
}

# rc 0 ⇒ THE AUTHORITY POSITIVELY SAYS `died`: the pid is gone AND no status
# file was written, so no future event can clear it. EVERY other outcome
# returns rc 1 — `running`, `terminal`, `unknown`, an unparseable line, a
# missing/non-executable `async-run.sh`, a timeout, a ref whose window or
# state dir cannot be derived. rc 1 means "NOT ESTABLISHED DEAD", which leaves
# the caller's pre-#1208 live verdict exactly as it was. Default-DENY: the only
# way to lose the `working-background` exemption is a positive `died`.
_pane_asyncrun_ref_is_died() {
    local ref="${1:-}" tok win sd ar line
    tok="${ref##*/}"
    win="${ref%/*}"; win="${win##*/}"
    sd="${ref%/async-run/*}"
    [[ "$tok" == ar-* ]] || return 1
    [[ -n "$win" && -n "$sd" && "$sd" != "$ref" ]] || return 1
    ar="$_PS_SCRIPT_DIR/async-run.sh"
    [[ -x "$ar" ]] || return 1
    line=$(NEXUS_WORKER_WINDOW="$win" NEXUS_STATE_DIR="$sd" \
             timeout 5 "$ar" --status-line "$tok" 2>/dev/null) || return 1
    # Compare the VERDICT WORD by equality, never a substring: the detail half
    # of a `terminal` or `running` line is free text and could contain the
    # word `died`.
    [[ "${line%%|*}" == "died" ]]
}

# A background-shell root is STALE iff its own argv names at least one
# async-run job, EVERY async-run job named anywhere in its subtree is
# `died`, and the subtree contains nothing but shells and `sleep`.
#
# All three conjuncts are load-bearing, and each fails toward LIVE:
#   * `died` alone is not enough — a root holding one dead and one RUNNING
#     token is still doing work;
#   * a token found only on a DESCENDANT does not make the root a wait
#     wrapper, so the root's own argv must name one;
#   * the comm allowlist (shell | sleep, default-DENY on anything else) is
#     what stops a root that happens to wait on a dead token while a real
#     child computes underneath it from being called finished. `sleep` is
#     admitted because it is exactly what the `until … do sleep 60; done`
#     loop forks, and nothing else.
_pane_background_shells() {
    # $2 (optional): `<pid>:<start-ticks>` of ONE root to leave out of the
    # census entirely — the longjob dispatcher's wrapper, as identified by
    # `_pane_longjob_root` (bundle-2609sk2 F1). Skipped WHOLE: not counted, not
    # a member, no cpu, not the oldest, never named, and its children are never
    # enqueued — so every field below is about the work and nothing downstream
    # subtracts. Keyed on pid AND start ticks, so a recycled pid is never
    # skipped; empty → nothing skipped, the exact pre-existing walk.
    local pane_pid="$1" excl="${2:-}"
    if ! [[ "$pane_pid" =~ ^[0-9]+$ ]] || ! command -v pgrep >/dev/null 2>&1; then
        printf '0 0 0 0 0 0 0 - -'; return 0
    fi
    local total=0 count=0 proc_ok=0 claude_found=0
    # MEMBERSHIP (your-org/nexus-code#1460): every pid this walk visits, keyed
    # `pid:starttime` so a recycled pid is a different member. The watcher
    # compares the digest across ticks — a `#1446` wedge has STATIC
    # membership; a sequential driver blocked in wait() has children coming
    # and going while its own CPU stays at zero, which is exactly the shape
    # that made `bg_wedged` fire on every worker running the prescribed
    # pre-push battery. Selected by ANCESTRY, never by argv: a cwd-relative
    # grandchild carries no clone path, so a string match cannot see it.
    local members=""
    # #590 bookkeeping, keyed on the ROOT pid of each background-shell subtree:
    #   infra_roots  space-delimited " pid " list of roots proven to be nexus
    #                protocol wait loops (matched anywhere in their subtree)
    #   root_descs   newline-delimited "<pid>\t<descriptor>" for every root
    local infra_roots=" " root_descs=""
    # #1208 staleness bookkeeping, also keyed on the bg-shell subtree ROOT:
    #   root_has_token  " pid " list of roots whose OWN argv names an async-run job
    #   subtree_refs    newline "<root-pid>\t<async-run-ref>" for every ref found
    #                   ANYWHERE in that root's subtree
    #   alien_roots     " pid " list of roots with a descendant that is neither
    #                   a shell nor `sleep` — default-DENY, never stale
    local root_has_token=" " subtree_refs="" alien_roots=" "
    # Restart-quiescence bookkeeping (see `bg_quiesce` in the header):
    #   wait_roots   " pid " list of roots whose OWN eval'd payload is, as a
    #                whole, a nexus protocol wait loop (_pane_payload_is_pure_wait)
    #   stale_roots  " pid " list of roots #1208 resolved as waiting on a died job
    local wait_roots=" " stale_roots=" "
    # Oldest background-shell subtree ROOT start time, in clock ticks since
    # boot (`/proc/<pid>/stat` field 22). Converted to an epoch by the caller
    # side of this function. This is what makes the with-children episode age
    # DERIVED rather than stored: it cannot be reset by churn in the child
    # count, by a pane rendering, or by a watcher restart (#455 follow-up, the
    # round-2 skeptic's finding). 0 = no background shell / unknown.
    local oldest_ticks=0
    # Queue entries: "pid:below_claude:parent_in_bgshell:bgshell_root_pid".
    # The 4th field (#590) attributes every node inside a background-shell
    # subtree back to the ROOT that owns it, so a protocol command found on a
    # DESCENDANT (not just in the root shell's own argv) classifies that root.
    local queue="${pane_pid}:0:0:0" depth
    for depth in 0 1 2 3 4 5 6 7 8 9; do
        [[ -n "$queue" ]] || break
        local next="" entry pid below pinbg bgroot
        for entry in $queue; do
            IFS=: read -r pid below pinbg bgroot <<<"$entry"
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            [[ "$bgroot" =~ ^[0-9]+$ ]] || bgroot=0
            # Parse /proc/<pid>/stat: `pid (comm) state ppid ... utime stime`.
            # comm may contain spaces/parens — split on the LAST ') '.
            # Read via `read <` (NOT `$(< file)` — that command-substitution
            # redirect returns EMPTY for non-self pids under the agent
            # sandbox's /proc handling; `read`/`cat` work, which is why
            # _pane_has_live_claude uses ps rather than $(<)). The brace
            # group carries the `2>/dev/null` over the `<` redirection so a
            # pid that exits between pgrep and the read (a stale queue
            # entry) is skipped silently rather than leaking to stderr.
            local stat comm after
            { IFS= read -r stat < "/proc/$pid/stat"; } 2>/dev/null || continue
            [[ -n "$stat" ]] || continue
            proc_ok=1
            after="${stat##*) }"
            comm="${stat%) *}"; comm="${comm#*(}"
            local -a f=($after)
            # after[] is 0-indexed from `state`: utime=idx11, stime=idx12,
            # starttime (stat field 22) = idx19.
            local utime="${f[11]:-}" stime="${f[12]:-}" starttime="${f[19]:-}"
            if [[ -n "$excl" && "$pid:${starttime:-?}" == "$excl" ]]; then
                continue    # the dispatcher's root: neither it nor anything below it is visited
            fi
            members="${members}${pid}:${starttime:-?} "
            local is_shell=0 is_claude=0 in_bg=0
            # Shared predicate — see _pane_comm_is_shell. Kept in one place so
            # the MCP-config probe cannot certify a `command` this walk would
            # then count.
            _pane_comm_is_shell "$comm" && is_shell=1
            case "$comm" in
                claude|claude.exe|claude-code) is_claude=1 ;;
            esac
            (( is_claude == 1 )) && claude_found=1
            # A background-shell subtree ROOT: a shell directly under claude
            # whose parent was NOT already inside a bg-shell subtree (so a
            # nested subshell of the same job doesn't double-count).
            local is_root=0
            if (( below == 1 )) && (( is_shell == 1 )) && (( pinbg == 0 )); then
                is_root=1
                bgroot="$pid"           # this node owns its own subtree (#590)
                count=$(( count + 1 ))
                # Track the OLDEST such root: the episode began when the
                # longest-lived background shell started. Shells coming and
                # going cannot move this so long as the eldest survives.
                if [[ "$starttime" =~ ^[0-9]+$ ]] \
                   && { (( oldest_ticks == 0 )) || (( starttime < oldest_ticks )); }; then
                    oldest_ticks="$starttime"
                fi
            fi
            # #590: read the cmdline for any node inside a background-shell
            # subtree — the root gets a human-readable descriptor, and ANY node
            # matching a nexus protocol wait marks its owning root as
            # infrastructure. Bounded: only inside bg subtrees, so an idle
            # worker with no background children reads no cmdlines at all.
            if (( is_root == 1 )) || { (( below == 1 )) && (( pinbg == 1 )); }; then
                # /proc/<pid>/cmdline is NUL-delimited, so `tr` (not `read`,
                # which would stop at the first argument) is what yields the
                # whole command. A pid that exits mid-walk just yields empty.
                local cmdl=""
                # GROUPED, and the ungrouped form 44 lines above at the
                # `/proc/$pid/stat` read is the one that was already right —
                # same function, same race, same author, opposite outcome
                # (your-org/nexus-code#1305). Redirections are performed left
                # to right, so `< "/proc/$pid/cmdline"` was attempted while
                # stderr was still the terminal and the `2>/dev/null` took
                # effect afterwards, on a command that never ran. Found by
                # RUNNING the merged code on the live board, not by reading
                # it: one ordinary orchestration command printed
                # `line 2391: /proc/27901/cmdline: No such file or directory`.
                cmdl=$( { tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null | head -c 4096)
                if [[ -n "$cmdl" ]] && _pane_cmd_is_protocol_wait "$cmdl"; then
                    case "$infra_roots" in
                        *" $bgroot "*) : ;;
                        *) (( bgroot > 0 )) && infra_roots="${infra_roots}${bgroot} " ;;
                    esac
                fi
                # Restart quiescence: asked of the ROOT'S OWN argv only. A wait
                # command found on a descendant says nothing about what the root
                # runs before or after it.
                if (( is_root == 1 )) && [[ -n "$cmdl" ]]; then
                    local _payload
                    if _payload=$(_pane_root_payload "$cmdl") \
                       && _pane_payload_is_pure_wait "$_payload"; then
                        wait_roots="${wait_roots}${pid} "
                    fi
                fi
                # #1208: harvest every async-run ref this node names, attributed
                # to the root that owns the subtree. A ref on the ROOT's own argv
                # additionally marks the root as a candidate wait wrapper.
                if [[ -n "$cmdl" ]] && (( bgroot > 0 )); then
                    local _ref _refs
                    _refs=$(_pane_asyncrun_refs "$cmdl")
                    if [[ -n "$_refs" ]]; then
                        while IFS= read -r _ref; do
                            [[ -n "$_ref" ]] || continue
                            subtree_refs+="${bgroot}"$'\t'"${_ref}"$'\n'
                        done <<< "$_refs"
                        if (( is_root == 1 )); then
                            case "$root_has_token" in
                                *" $bgroot "*) : ;;
                                *) root_has_token="${root_has_token}${bgroot} " ;;
                            esac
                        fi
                    fi
                fi
                # #1208 default-DENY: any DESCENDANT of a bg root that is
                # neither a shell nor `sleep` is real work, and disqualifies
                # that root from ever being called stale.
                if (( is_root == 0 )); then
                    if (( is_shell == 0 )) && [[ "$comm" != "sleep" ]]; then
                        case "$alien_roots" in
                            *" $bgroot "*) : ;;
                            *) (( bgroot > 0 )) && alien_roots="${alien_roots}${bgroot} " ;;
                        esac
                    fi
                fi
                if (( is_root == 1 )); then
                    root_descs+="${pid}"$'\t'"$(_pane_cmd_descriptor "$comm" "$cmdl")"$'\n'
                fi
            fi
            # This node's CPU counts iff it is under claude AND (it is a
            # shell, or its parent was already inside a bg-shell subtree).
            if (( below == 1 )) && { (( is_shell == 1 )) || (( pinbg == 1 )); }; then
                in_bg=1
                if [[ "$utime" =~ ^[0-9]+$ && "$stime" =~ ^[0-9]+$ ]]; then
                    total=$(( total + utime + stime ))
                fi
            fi
            # Descend. Children are "below claude" once this node is (or
            # is) claude; they inherit this node's bg-shell membership.
            local child_below=$(( below == 1 || is_claude == 1 ? 1 : 0 ))
            local kid kids
            kids=$(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')
            for kid in $kids; do
                [[ "$kid" =~ ^[0-9]+$ ]] || continue
                next+=" ${kid}:${child_below}:${in_bg}:${bgroot}"
            done
        done
        queue=$(printf '%s' "$next" | tr -s ' ')
    done
    local reliable=0
    (( proc_ok == 1 && claude_found == 1 )) && reliable=1
    local oldest_epoch=0
    (( oldest_ticks > 0 )) && oldest_epoch=$(_pane_ticks_to_epoch "$oldest_ticks")
    # #590: infra tally + ONE representative descriptor. A NON-infra root is
    # preferred — that is the child an operator has to make a decision about;
    # naming an await loop while a stray `sbatch` hides behind it would defeat
    # the point of naming anything.
    # #1208: resolve staleness AFTER the walk, so the (bounded, external)
    # async-run calls happen at most once per candidate root and never for a
    # root already disqualified by an alien descendant.
    local stale=0 sr_root sr_ref
    local cand cands="" seen_roots=" "
    while IFS=$'\t' read -r sr_root sr_ref; do
        [[ -n "$sr_root" ]] || continue
        case "$root_has_token" in *" $sr_root "*) : ;; *) continue ;; esac
        case "$alien_roots"    in *" $sr_root "*) continue ;; esac
        case "$seen_roots"     in *" $sr_root "*) : ;;
            *) seen_roots="${seen_roots}${sr_root} "; cands+="${sr_root} " ;;
        esac
    done <<< "$subtree_refs"
    for cand in $cands; do
        [[ "$cand" =~ ^[0-9]+$ ]] || continue
        local all_died=1 resolved=0
        local cap="${_PANE_ASYNCRUN_MAX_REFS:-16}"
        [[ "$cap" =~ ^[0-9]+$ ]] && (( cap > 0 )) || cap=16
        while IFS=$'\t' read -r sr_root sr_ref; do
            [[ "$sr_root" == "$cand" ]] || continue
            [[ -n "$sr_ref" ]] || continue
            # Bound the external calls. Each is a `timeout 5` subprocess and
            # the cmdline this came from can be 4 KB, so an argv naming many
            # jobs could otherwise stall the walk for minutes. Exceeding the
            # cap abandons the root as NOT stale — the same direction as every
            # other thing we could not establish.
            resolved=$(( resolved + 1 ))
            if (( resolved > cap )); then all_died=0; break; fi
            _pane_asyncrun_ref_is_died "$sr_ref" || { all_died=0; break; }
        done <<< "$subtree_refs"
        if (( all_died == 1 )); then
            stale=$(( stale + 1 ))
            stale_roots="${stale_roots}${cand} "
        fi
    done
    local infra=0 desc="-" first_infra_desc="" rp rd
    while IFS=$'\t' read -r rp rd; do
        [[ -n "$rp" ]] || continue
        case "$infra_roots" in
            *" $rp "*)
                infra=$(( infra + 1 ))
                [[ -n "$first_infra_desc" ]] || first_infra_desc="$rd" ;;
            *)
                [[ "$desc" == "-" ]] && desc="$rd" ;;
        esac
    done <<< "$root_descs"
    [[ "$desc" == "-" && -n "$first_infra_desc" ]] && desc="$first_infra_desc"
    [[ -n "$desc" ]] || desc="-"
    # Restart quiescence, one count per ROOT (a union, so a root that is both a
    # pure wait and #1208-stale is counted once). A pure wait with ANY descendant
    # that is neither a shell nor `sleep` is NOT quiescent at this instant: that
    # is a supervisor tick mid-flight at best and real work at worst, and one
    # sample cannot tell them apart, so it errs toward "work in flight".
    local quiesce=0
    while IFS=$'\t' read -r rp rd; do
        [[ -n "$rp" ]] || continue
        case "$stale_roots" in *" $rp "*) quiesce=$(( quiesce + 1 )); continue ;; esac
        case "$alien_roots" in *" $rp "*) continue ;; esac
        case "$wait_roots"  in *" $rp "*) quiesce=$(( quiesce + 1 )) ;; esac
    done <<< "$root_descs"
    local members_digest="-"
    if [[ -n "$members" ]]; then
        members_digest=$(printf '%s\n' $members | sort | cksum | cut -d' ' -f1)
        [[ "$members_digest" =~ ^[0-9]+$ ]] || members_digest="-"
    fi
    # Field 7 (quiesce) sits BEFORE members/desc so `desc`, which a `read` takes
    # as the remainder, stays last.
    printf '%d %d %d %d %d %d %d %s %s' "$count" "$total" "$reliable" "$oldest_epoch" \
        "$infra" "$stale" "$quiesce" "$members_digest" "$desc"
}

# _pane_root_payload <cmdline> — the command a Claude Code tool/Monitor shell
# was asked to run. Such a shell's argv is
#     zsh -c source <snapshot> … && eval '<PAYLOAD>' < /dev/null && pwd …
# with every `'` inside PAYLOAD written as `'\''`. rc 1 (no output) when the
# wrapper shape is absent — including a cmdline truncated before its trailer —
# so an unrecognised shell is never classified by a guess.
_pane_root_payload() {
    local c="${1:-}" p
    # THE READ CAP (w234sk F2). The walk keeps at most 4096 bytes of a cmdline
    # (`head -c 4096`), and a TRUNCATED one can still end in a `' < /dev/null`
    # that belongs to the PAYLOAD. The peel below then yields a clean pure-wait
    # PREFIX of a command that goes on to do work. Measured: a 5262-byte argv
    # cut to 4096 classified quiescent. So a cmdline at or over the cap is
    # refused as unrecognisable. A genuine 4096-byte command is refused too,
    # which errs toward "not quiescent". The length is taken in BYTES under
    # LC_ALL=C, because the cap is in bytes and ${#c} counts characters in a
    # UTF-8 locale.
    local LC_ALL=C
    (( ${#c} < 4096 )) || return 1
    case "$c" in *"eval '"*"' < /dev/null"*) : ;; *) return 1 ;; esac
    p="${c#*eval \'}"
    p="${p%\' < /dev/null*}"
    p="${p//\'\\\'\'/\'}"
    [[ -n "$p" ]] || return 1
    printf '%s' "$p"
}

# _pane_payload_is_pure_wait <payload> — rc 0 iff the payload, AS A WHOLE, is a
# nexus protocol wait loop: nothing in it but recognised waits, `sleep N`, loop
# keywords, `cd`, `echo`/`printf`, `exit`/`return` and plain assignments, with at
# least one recognised wait. It exists for ONE decision — may the cc-update
# restart kill this shell between turns — so it answers "does killing this
# destroy work, or work not yet started", not "does this mention a wait".
#
# WHY WHOLE-PAYLOAD AND NOT `_pane_cmd_is_protocol_wait`. That predicate is a
# substring match, right for its job (naming an await) and wrong for this one:
# `skeptic-channel.sh await x && python post.py` matches it, and killing that
# shell during the await destroys a job that has not started yet.
#
# ERROR DIRECTION, stated because this is a predicate over SOURCE TEXT for a
# RUNTIME property. It errs toward NOT QUIESCENT (keep waiting) on: any
# command it does not know, command substitution, backticks, pipes, redirects,
# backgrounding, subshells and braces, a heredoc, a quoted separator (naive
# splitting leaves fragments that fail to parse), a bare `sleep` timer, and the
# `until [ -s "$T/status" ]` waiter #1208 already handles by resolving the job.
# It can err toward QUIESCENT only if a word that NAMES a recognised wait runs
# something else: a shell function or alias of that name defined in the shell
# snapshot, or a same-named script that is not the nexus's. Both are bounded by
# the caller's second conjunct: every live descendant must be a shell or
# `sleep`. So the residual is work done by SHELLS themselves, builtins or
# shell scripts alike, since a descendant whose comm is a shell is never
# alien. Beyond that, a non-shell direct child of claude is never counted as a
# root at all (w234sk F3; see `bg_quiesce` in the header).
_pane_payload_is_pure_wait() {
    local p="${1:-}"
    [[ -n "$p" ]] || return 1
    p="${p//&&/;}"
    p="${p//||/;}"
    p="${p//$'\n'/;}"
    case "$p" in
        *'$('*|*'`'*|*'|'*|*'&'*|*'>'*|*'<'*|*'('*|*')'*|*'{'*|*'}'*) return 1 ;;
    esac
    local -a frags words
    IFS=';' read -r -a frags <<< "$p"
    local frag w0 base saw_wait=0
    for frag in "${frags[@]}"; do
        read -r -a words <<< "$frag"
        (( ${#words[@]} > 0 )) || continue
        # Loop keywords and `!` prefix a command; they are not one.
        while (( ${#words[@]} > 0 )); do
            case "${words[0]}" in
                until|while|do|'!') words=("${words[@]:1}") ;;
                *) break ;;
            esac
        done
        (( ${#words[@]} > 0 )) || continue
        # Leading NAME=value assignment words (`rc=$?`, `T=/path`).
        while (( ${#words[@]} > 0 )) && [[ "${words[0]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
            words=("${words[@]:1}")
        done
        (( ${#words[@]} > 0 )) || continue
        w0="${words[0]//\"/}"; w0="${w0//\'/}"
        base="${w0##*/}"
        # `cd`, and the loop's own `exit $rc` / `return`, at most one argument.
        # Tested with `[[ == ]]` rather than a `cd|exit|return)` case arm: that
        # spelling reads, to test-subshell-exit-guards.sh (#1339), as an exit
        # site — which it is not; it is a word being compared.
        if [[ "$base" == "cd" || "$base" == "exit" || "$base" == "return" ]]; then
            (( ${#words[@]} <= 2 )) || return 1
            continue
        fi
        case "$base" in
            done|true|:)
                (( ${#words[@]} == 1 )) || return 1 ;;
            sleep)
                (( ${#words[@]} == 2 )) && [[ "${words[1]}" =~ ^[0-9]+(\.[0-9]+)?[smhd]?$ ]] || return 1 ;;
            echo|printf)
                : ;;
            watcher-supervise-tick.sh)
                saw_wait=1 ;;
            proc-exists-authorized)
                case " ${words[*]:1} " in
                    *" --until-gone "*|*" --until-present "*) saw_wait=1 ;;
                    *) return 1 ;;
                esac ;;
            async-run.sh)
                # `[[ == ]]`, not a nested `case` with `--await)` arms: a case
                # arm spelled like a flag reads, to
                # test-ng-usage-flag-coverage.sh (#906 A), as a flag THIS script
                # parses and does not document.
                if [[ "${words[1]:-}" == "--await" ]]; then
                    saw_wait=1
                elif [[ "${words[1]:-}" != "--status" && "${words[1]:-}" != "--status-line" ]]; then
                    return 1
                fi ;;
            skeptic-channel.sh)
                case "${words[1]:-}" in await|poll) saw_wait=1 ;; *) return 1 ;; esac ;;
            request-channel.sh)
                [[ "${words[1]:-}" == await ]] || return 1
                saw_wait=1 ;;
            ng)
                case "${words[1]:-} ${words[2]:-}" in
                    "skeptic await"|"skeptic await-answer"|"request await") saw_wait=1 ;;
                    *) return 1 ;;
                esac ;;
            *)
                return 1 ;;
        esac
    done
    (( saw_wait == 1 ))
}

# Does this command line belong to a NEXUS PROTOCOL WAIT LOOP rather than to
# task work (your-org/nexus-code#590)? These are the background shells the nexus
# ITSELF prescribes: `ng wrap-up` instructs a skeptic-gated worker to hold a
# `skeptic-channel await` re-check loop, and the request/reply channel has the
# symmetric `request … await`. They are the routine "live child after wrap-up"
# and must not be reported as the same kind of finding as an orphaned
# `sbatch`/`nohup`.
#
# Matched on the nexus's own command surface — NOT on third-party package names.
# A `zotero`/`uvx`-style match would be brittle and endless (a new MCP server
# would reopen the bug), and it would be aimed at the wrong thing anyway: no
# MCP server this nexus configures reaches this function's count at all, since
# each is spawned from a non-shell `command` and fails the is-a-shell test.
# (A hypothetical `command: "sh"` entry would be counted — as a task shell, not
# as a protocol wait — which is a residual noted in the scope block above and
# not something a package-name filter here would fix either.)
_pane_cmd_is_protocol_wait() {
    local c="${1:-}"
    case "$c" in
        *skeptic-channel.sh*await*)   return 0 ;;
        *"skeptic await"*)            return 0 ;;   # `ng skeptic await …`
        *request-channel.sh*await*)   return 0 ;;
        *"request await"*)            return 0 ;;   # `ng request await …`
        *skeptic-channel.sh*poll*)    return 0 ;;
    esac
    return 1
}

# A compact, SPACE-FREE `<comm>:<tail>` label for one background-shell root, so
# an emit can name the child. Space-free because the pane-state emit line is
# `key=value` separated by spaces; stable across cycles (no pids, no clocks) so
# it cannot churn the watcher's emit-dedup hash and re-alert every cycle.
#
# The interesting part of a Claude Code tool shell is the END of the argv (the
# eval'd command), not the start (a long shell-snapshot `source`), so the tail
# is what is kept.
_pane_cmd_descriptor() {
    local comm="${1:-?}" cmd="${2:-}" tail=""
    if [[ -n "$cmd" ]]; then
        # Peel Claude Code's Bash-tool wrapper off both ends. A tool shell is
        #   zsh -c source <snapshot> … && eval '<COMMAND>' < /dev/null && pwd -P >| <cwdfile>
        # so the payload sits in the MIDDLE: neither head- nor tail-truncation
        # of the raw argv keeps it (head keeps the snapshot path, tail keeps the
        # `pwd -P` trailer). Strip the preamble at the last `eval `, then the
        # trailer at `< /dev/null`, then the eval quoting, then a leading
        # `cd <abs-path> &&` — what remains is the actual command.
        tail="${cmd##*eval }"
        tail="${tail%%< /dev/null*}"
        tail="${tail#\'}"
        tail="${tail%\'*}"
        # Drop a leading `cd <path>` and the operator joining it to the real
        # command. Done token-wise rather than with a `cd * && ` glob because the
        # joining operator is not reliably `space && space` — a real worker's
        # await loop reads `cd <root> &&\nwhile true; do …`, and a `&& `-anchored
        # pattern silently left the whole `cd`-plus-path prefix in place, which
        # then ate the 60-char budget and truncated away the actual command.
        case "$tail" in
            "cd "*)
                tail="${tail#cd }"
                case "$tail" in
                    *[[:space:]]*) tail="${tail#*[[:space:]]}" ;;   # the path token
                esac
                while :; do
                    case "$tail" in
                        [[:space:]]*) tail="${tail#?}" ;;
                        "&&"*)        tail="${tail#&&}" ;;
                        ";"*)         tail="${tail#;}" ;;
                        *) break ;;
                    esac
                done
                ;;
        esac
        # Collapse whitespace and strip characters that would break a
        # key=value emit field or a downstream awk split.
        tail=$(printf '%s' "$tail" \
                | tr -c 'A-Za-z0-9._/=:+-' '_' \
                | sed -e 's/__*/_/g' -e 's/^_//' -e 's/_$//')
        tail="${tail:0:60}"
    fi
    [[ -n "$tail" ]] || tail="?"
    printf '%s:%s' "$comm" "$tail"
}

# Convert a `/proc/<pid>/stat` starttime (clock ticks since boot) to a unix
# epoch: boot time (`btime` in /proc/stat) + ticks / CLK_TCK. Echoes 0 when
# either input is unavailable, which callers treat as "unknown" (never as
# "just started").
_pane_ticks_to_epoch() {
    local ticks="$1" btime="" hz=""
    [[ "$ticks" =~ ^[0-9]+$ ]] && (( ticks > 0 )) || { printf '0'; return 0; }
    local line
    while IFS= read -r line; do
        if [[ "$line" == btime\ * ]]; then btime="${line#btime }"; break; fi
    done < /proc/stat 2>/dev/null
    [[ "$btime" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    [[ "$hz" =~ ^[0-9]+$ ]] && (( hz > 0 )) || hz=100
    printf '%d' $(( btime + ticks / hz ))
}

# ---- heartbeat helpers (issue #74) ---------------------------------------
# Default staleness window: 30 s. Overridable per-invocation via
# --heartbeat-staleness, and (for the main watcher path) via
# `monitor.heartbeat_staleness_seconds` in config/nexus.yml — read by
# the watcher's caller before invoking us, then plumbed through with
# the same flag. Keep this file free of yaml dependence; loading
# config here would pull python3+pyyaml into the hot watcher loop.
_HEARTBEAT_STALENESS_DEFAULT=30

# Longer staleness window applied to `last_turn_end`-anchored
# heartbeats — i.e. Stop-derived idle stamps (issue #129 item 3).
# Default 1800 s = 30 min: long enough to bridge a normal "agent
# idled, operator stepped away, then sent a new prompt" cadence
# without re-falling-through to the renderer mid-stretch. The
# dead-claude gate runs first, so over-trusting an idle stamp for
# a dead pane is impossible — it emits `absent` regardless of
# heartbeat freshness. Overridable per-invocation via
# --heartbeat-turn-end-staleness and (for the watcher path) via
# `monitor.heartbeat_turn_end_staleness_seconds`.
_HEARTBEAT_TURN_END_STALENESS_DEFAULT=1800

# Async-signal staleness: how long after `last_activity` the
# heartbeat's `scheduled_wakeup_at` / `external_waits` fields are trusted for
# the idle-refinement path (issue #183). Independent of the
# top-level state-classification staleness so the heartbeat can
# remain authoritative for refinement even when the renderer takes
# over for state. Default 60 s — generous enough to bridge a slow
# tool call between PostToolUse fires; short enough that a wedged
# worker doesn't keep its async signals indefinitely.
_HEARTBEAT_ASYNC_STALENESS_DEFAULT=60

# `external_waits` is SPLIT OFF from that 60 s (your-org/nexus-code#1220).
#
# THE ASYMMETRY, which is the whole reason this constant exists separately.
# The 60 s horizon above is written to stop a WEDGED worker keeping its async
# signals -- and so its EXEMPTION -- indefinitely. That rationale is exactly
# right for the other field in the group: `scheduled_wakeup_at` resolves to
# `working-self-paced`, which is in
# `_bookkeeping.sh`'s `_BK_ACTIVE_STATES` -- states that REFUSE a kill. Left
# to run forever they would hold a window open forever, so expiring them is
# the safe direction.
#
# `external_waits` is the one field in that group the rationale does not
# cover. It resolves to `idle-orphan-async`, which is in
# `_BK_KILL_OK_STATES` alongside plain `idle` -- it grants no exemption and
# blocks no retirement. So expiring it does not withdraw a privilege; it
# DELETES A DECLARATION, and the thing declared is precisely that work is
# outstanding.
#
# And the proxy contradicts the thing it stands for. Quiet is read as evidence
# of no outstanding waits, but a worker BLOCKED on an external wait emits no
# activity -- which is why it is quiet. The signal is weakest exactly where it
# is needed. Measured on window `olayingestsk2`: `last_activity` 68071 s old
# (18.9 h) against a 60 s horizon, with 10 `external_waits` entries that were
# invisible for the whole of it.
#
# 48 h, matching the background-children EPISODE CEILING
# (`background_children_grace_ceiling_seconds`, default 172800) -- the repo's
# existing statement of how long a legitimate background episode may run. It
# is a horizon rather than no horizon so an abandoned heartbeat file cannot
# declare a wait forever, but it is sized to the WAIT, not to the gap between
# two PostToolUse fires.
#
# THIS CANNOT CHANGE KILL AUTHORIZATION IN EITHER DIRECTION: both the state it
# withholds (`idle`) and the state it produces (`idle-orphan-async`) are in
# `_BK_KILL_OK_STATES`, so a window is exactly as retirable either way. What
# it changes is whether the declared wait is ever RESOLVED, reaped and
# reported -- `_orphan_async.sh` records a row only for a window reading
# `idle-orphan-async`.
_HEARTBEAT_EXTERNAL_WAITS_STALENESS_DEFAULT=172800

_resolve_heartbeat_dir() {
    # Mirrors monitor/ng's STATE_DIR resolver but lighter — no
    # config/load.sh dependency. The watcher exports NEXUS_ROOT
    # into its process tree so the env-path covers prod.
    if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
        printf '%s/heartbeat' "$NEXUS_STATE_DIR"
        return 0
    fi
    if [[ -n "${NEXUS_ROOT:-}" ]]; then
        printf '%s/monitor/.state/heartbeat' "$NEXUS_ROOT"
        return 0
    fi
    # Script-relative fallback (matches ng's last-ditch).
    local self_dir
    self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || self_dir="."
    printf '%s/.state/heartbeat' "$self_dir"
}

# Try to use the worker-side heartbeat as authoritative state.
# Echoes the resolved emit-vocab token on stdout when the heartbeat
# is fresh AND maps to a known state; returns 0. Empty stdout +
# return 1 when missing, stale, malformed, or unmapped — the caller
# falls through to renderer detection in that case.
#
# Staleness anchor selection (issue #129 item 3):
#   - Default: `last_activity` (per-event stamp) with the supplied
#     `staleness` threshold (default 30 s). Right for `busy` /
#     `user_prompt` — if no further event lands for 30 s, the agent
#     may be hung; renderer is then the safer signal.
#   - When `last_turn_end` is present (Stop-hook turn_end token),
#     we use it as the staleness anchor instead, with the LONGER
#     threshold `turn_end_staleness` (default 1800 s = 30 min).
#     Rationale: a Stop event proves the agent's turn truly ended;
#     30 s of subsequent silence doesn't invalidate "idle" the way
#     it would for a busy stamp. The dead-claude gate already runs
#     ahead of this path, so over-trusting a Stop-derived idle for
#     a dead pane is impossible — a dead pane emits `absent`
#     regardless of heartbeat freshness.
_classify_from_heartbeat() {
    local hb_file="$1" now="$2" staleness="$3" turn_end_staleness="${4:-$_HEARTBEAT_TURN_END_STALENESS_DEFAULT}"
    [[ -n "$hb_file" ]] || return 1
    [[ -f "$hb_file" ]] || return 1
    [[ -r "$hb_file" ]] || return 1

    local last_activity state last_turn_end
    if command -v jq >/dev/null 2>&1; then
        last_activity=$(jq -r '.last_activity // empty' "$hb_file" 2>/dev/null) || return 1
        state=$(jq -r '.state // empty' "$hb_file" 2>/dev/null) || return 1
        last_turn_end=$(jq -r '.last_turn_end // empty' "$hb_file" 2>/dev/null) || last_turn_end=""
    else
        # jq absent: grep-based fallback. Heartbeat JSON is single-line
        # so a regex against the file content is safe enough.
        local content
        content=$(<"$hb_file") || return 1
        last_activity=$(grep -oE '"last_activity"[[:space:]]*:[[:space:]]*[0-9]+' <<<"$content" | grep -oE '[0-9]+' | tail -1)
        state=$(grep -oE '"state"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$content" | sed -E 's/.*"([^"]+)"$/\1/')
        last_turn_end=$(grep -oE '"last_turn_end"[[:space:]]*:[[:space:]]*[0-9]+' <<<"$content" | grep -oE '[0-9]+' | tail -1)
    fi

    [[ -n "$last_activity" ]] || return 1
    [[ "$last_activity" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$state" ]] || return 1

    # Pick the staleness anchor + threshold. last_turn_end (when
    # present and well-formed) wins because Stop is a stronger
    # statement of intent than the per-event stamp.
    local anchor_ts="$last_activity" eff_staleness="$staleness"
    if [[ -n "$last_turn_end" ]] && [[ "$last_turn_end" =~ ^[0-9]+$ ]]; then
        anchor_ts="$last_turn_end"
        eff_staleness="$turn_end_staleness"
    fi

    local age=$(( now - anchor_ts ))
    (( age >= 0 )) || age=0
    (( age <= eff_staleness )) || return 1

    case "$state" in
        busy|user_prompt) printf 'busy';        return 0 ;;
        permission_prompt) printf 'blocked';    return 0 ;;
        idle_prompt)       printf 'idle';       return 0 ;;
        *) return 1 ;;
    esac
}

# ---- async-signal refinement helpers (issue #183) -----------------------
#
# These extract the async signals (the footer's handle counts, the
# heartbeat's scheduled_wakeup_at and external_waits) used
# to refine the `idle` verdict into one of:
#   working-background / working-self-paced / idle-orphan-async / idle.
#
# Conventions:
#   - Each helper writes a single key=value to stdout, or exits
#     non-zero / empty stdout when it has nothing to say.
#   - The signals come from two sources: the heartbeat JSON (when
#     fresh enough) for the two wakeup/wait fields, and the pane-ANSI
#     capture (footer parsing) for the handle counts. No field is read
#     from both (#1374).

# THERE IS NO HEARTBEAT ARM FOR THE HANDLE COUNTS (your-org/nexus-code#1374).
# `_heartbeat_handle_counts` used to read `monitor_handles` and
# `background_bash_count` from the heartbeat JSON and `max()` them with the
# footer parse below. Nothing has ever WRITTEN those fields: the only
# production writer, monitor/worker-heartbeat.sh, emits exactly
# state · last_activity · event · last_tool · session_id · window ·
# external_waits · dismissed_waits (+ last_turn_end, scheduled_wakeup_at), and
# they were present in 0 of 1,882 live heartbeats. A `max()` with a dead
# operand cannot fail, cannot log and cannot go red — so four documents
# asserted a defence in depth that was one mechanism wearing two names. The
# arm is deleted rather than fed: a PostToolUse hook cannot introspect
# claude's internal handle list, so it could never have been the primary.
# The footer regex IS the `mon` signal and the process tree IS the `bg`
# signal (footer as its fallback); their fragility is now visible where it
# lives. monitor/watcher/test-heartbeat-schema-agreement.sh asserts that
# every heartbeat field this file reads is one the writer emits.

# Pane-footer parse. Claude Code surfaces async-handle counts in
# two places: the spinner row above the input (`✻ Cooked for 4s ·
# 1 monitor still running`) and the status line below the input.
# The spinner row carries the canonical phrasing
# `N monitor[s] still running` / `N background bash[es] [still ]running`;
# the status line carries a shorter form that only renders when
# the count is non-zero.
#
# CRITICAL — the status-line phrasing drifted (your-org/nexus-code#445).
# Real Claude Code (verified v2.1.204) renders background shells as a
# `N shell[s]` token, NOT `N background bash[es]`, and combines the two
# counters when both are live:
#
#   -- INSERT -- ⏵⏵ bypass permissions on · gh auth login ·
#      1 shell, 1 monitor · ← for agents
#
# i.e. ` · <cmd> · 1 shell, 1 monitor · ← for agents`. The two
# counters share one ` · … · ` segment, joined by `, `. Standalone
# forms are ` · 2 shells · ` (no monitor) and ` · 1 monitor · ` (no
# shell). This was the paper-benchmark false-idle root cause: a worker
# idling between turns with a live background shell only ever shows
# the status-line form (the spinner "still running" form appears only
# during active tool execution), and the old regex matched neither
# `shell` nor the combined `, N monitor` boundary — so
# background_bash_count stayed 0 and the idle-refinement never emitted
# `working-background`.
#
# Strategy: scan the bottom 15 rows (the spinner sits ~3 rows above
# the input chevron; bigger margin protects against extra status-bar
# rows). Monitor: prefer the spinner "still running" form; else the
# status-line count bounded by ` · `/`, ` on the left and ` · `/`, `
# on the right (accepts both `· 1 monitor ·` and `1 shell, 1 monitor ·`).
# Background shells: the modern `N shell[s]` token bounded by ` · ` on
# the left and `,`/` · ` on the right (`· 2 shells ·`, `· 1 shell,`),
# OR the legacy `N background bash[es] [still ]running` spinner/status
# forms (kept for back-compat + the #183 synthetic fixtures). The
# middle-dot / comma boundaries anchor on the status-line separators,
# which never appear around unrelated transcript prose.
_footer_handle_counts() {
    local plain="$1"
    local bottom mon=0 bg=0
    bottom=$(_bottom_rows "$plain" 15)
    if [[ "$bottom" =~ ([0-9]+)[[:space:]]+monitor[s]?[[:space:]]+still[[:space:]]+running ]]; then
        mon="${BASH_REMATCH[1]}"
    elif [[ "$bottom" =~ [·,][[:space:]]+([0-9]+)[[:space:]]+monitor[s]?[[:space:]]*[·,] ]]; then
        mon="${BASH_REMATCH[1]}"
    fi
    if [[ "$bottom" =~ ·[[:space:]]+([0-9]+)[[:space:]]+shell[s]?[[:space:]]*[·,] ]]; then
        bg="${BASH_REMATCH[1]}"
    elif [[ "$bottom" =~ ([0-9]+)[[:space:]]+background[[:space:]]+(bash|process|bashes|processes)[[:space:]]+(still[[:space:]]+)?running ]]; then
        bg="${BASH_REMATCH[1]}"
    elif [[ "$bottom" =~ ·[[:space:]]+([0-9]+)[[:space:]]+background[[:space:]]+(bash|process|bashes|processes)[[:space:]]+· ]]; then
        bg="${BASH_REMATCH[1]}"
    fi
    printf '%d %d' "$mon" "$bg"
}

# Read `scheduled_wakeup_at` (epoch seconds) from the heartbeat.
# Returns the epoch on stdout when fresh AND > now, empty
# otherwise. The classifier interprets a non-empty stdout as
# "self-paced wakeup pending".
_heartbeat_scheduled_wakeup_at() {
    local hb_file="$1" now="$2" staleness="$3"
    [[ -n "$hb_file" ]] || return 1
    [[ -f "$hb_file" ]] || return 1
    [[ -r "$hb_file" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local last_activity swa
    last_activity=$(jq -r '.last_activity // empty' "$hb_file" 2>/dev/null) || last_activity=""
    [[ "$last_activity" =~ ^[0-9]+$ ]] || return 1
    local age=$(( now - last_activity ))
    (( age >= 0 )) || age=0
    (( age <= staleness )) || return 1

    swa=$(jq -r '.scheduled_wakeup_at // empty' "$hb_file" 2>/dev/null) || swa=""
    [[ "$swa" =~ ^[0-9]+$ ]] || return 1
    (( swa > now )) || return 1
    printf '%s' "$swa"
}

# Read `external_waits` from the heartbeat and emit a
# comma-separated `<kind>:<id>[,<kind>:<id>…]` summary on stdout
# (capped at 80 chars; longer lists are truncated with `…`).
# Returns 1 with empty stdout when the array is missing, empty, or
# the heartbeat is older than the EXTERNAL-WAITS horizon — which is
# deliberately not the async-signal horizon its three sibling fields use.
# See `_HEARTBEAT_EXTERNAL_WAITS_STALENESS_DEFAULT` for why a declaration
# and an exemption cannot share an expiry.
_heartbeat_external_waits_summary() {
    local hb_file="$1" now="$2" staleness="$3"
    [[ -n "$hb_file" ]] || return 1
    [[ -f "$hb_file" ]] || return 1
    [[ -r "$hb_file" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1

    local last_activity
    last_activity=$(jq -r '.last_activity // empty' "$hb_file" 2>/dev/null) || last_activity=""
    [[ "$last_activity" =~ ^[0-9]+$ ]] || return 1
    local age=$(( now - last_activity ))
    (( age >= 0 )) || age=0
    (( age <= staleness )) || return 1

    local summary
    summary=$(jq -r '
        if (.external_waits | type) == "array" then
            (.external_waits | map("\(.kind):\(.id)") | join(","))
        else
            empty
        end
    ' "$hb_file" 2>/dev/null) || return 1
    [[ -n "$summary" ]] || return 1

    # 80-char cap. The `…` is multi-byte; subtract its byte
    # length defensively.
    local cap=80
    if (( ${#summary} > cap )); then
        summary="${summary:0:$(( cap - 1 ))}…"
    fi
    printf '%s' "$summary"
}

# Refine a verdict of `idle` into one of the four async-signal
# states. Emits a single line of the form:
#     <state>[<TAB>orphan_kinds=<csv>]
# on stdout. Caller splits on TAB. The TAB-delimited extra field
# (rather than a separate global) keeps the refinement composable
# with `$(…)` capture — subshells can't write back to the caller's
# variables but they can emit additional structured columns. The
# pattern mirrors `list_idle_transitions` in `_idle_probe.sh`.
#
# Caller passes the pane-plain bytes (for footer parsing), the
# heartbeat path (either may be empty), and the process-tree
# background-shell reading (`pt_bg` count + `pt_reliable`) measured
# once by the caller via _pane_background_shells.
# THE FOOTER DISCOUNT for the longjob dispatcher — applied in the refiner below
# from the ONE verdict `_longjob_dispatcher_verdict` reads (armed AND active==0).
#
# How many of the footer's `N monitor` handles belong to the longjob-watch
# DISPATCHER (your-org/nexus-code#1535) with NOTHING to wait for. Every nexus
# session is launched with that plugin monitor armed, so without this every
# idle worker would read `· 1 monitor ·` → `working-background`, which is
# never aged out and never kill-authorised: window cleanup would stop
# board-wide. Measured on the hermetic control (fixture
# fixtures/idle-longjob-dispatcher-armed-realmodel-272.ansi): an idle REPL
# with the dispatcher armed classifies `working-background`.
#
# THIS IS A KILL-DECISION INPUT, so it demands a POSITIVE liveness verdict
# from the ONE reader that has one — `longjob-watch.sh ledger-verdict`, the
# same function `status` prints — never a freshness proxy re-derived here
# (skeptic F2: a fresh ledger with a DEAD pid used to discount, i.e. read
# `idle`, kill-authorised, while `status` said `dead`). The gates, each
# erring toward KEEPING the handle:
#   - no heartbeat / no ledger / unreadable ledger            → 0
#   - a `win-<name>` ledger whose own `window` field is not
#     this heartbeat's window (a foreign dispatcher's file)  → 0
#   - verdict not `armed` (dead pid, start-time mismatch, stale poll,
#     NOT SERVING — the kill switch — or muted)               → 0
#   - `active` > 0, COUNTED from the spool by the verb (a
#     worker IS parked on a watch; the cached field lags)    → 0
#   - armed and active == 0                                   → 1
# A footer reading of 2 with one discounted is a model-armed Monitor plus the
# dispatcher, and stays `working-background`; the discount is at most 1.
# _longjob_dispatcher_ledger <hb_file> → prints "<state-dir>\t<ledger-path>" for THIS
# session's dispatcher (sid- key first, then a win- key that names this window),
# or nothing. Shared by the footer discount and the process-tree walk below so
# the two channels can never consult two different ledgers.
_longjob_dispatcher_ledger() {
    local hb="$1" sd sid win key ledger=""
    [[ -n "$hb" && -f "$hb" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    sd=$(cd "$(dirname "$hb")/.." 2>/dev/null && pwd) || return 1
    sid=$(jq -r '.session_id // empty' "$hb" 2>/dev/null) || sid=""
    win=$(jq -r '.window // empty' "$hb" 2>/dev/null) || win=""
    for key in "${sid:+sid-$sid}" "${win:+win-$win}"; do
        [[ -n "$key" && -f "$sd/longjob/$key/dispatcher.json" ]] && { ledger="$sd/longjob/$key/dispatcher.json"; break; }
    done
    [[ -n "$ledger" ]] || return 1
    if [[ "$key" == win-* ]]; then
        # A window-keyed ledger must name THIS window, or it is somebody else's.
        [[ "$(jq -r '.window // empty' "$ledger" 2>/dev/null)" == "$win" ]] || return 1
    fi
    # Newline-terminated: a `read` at EOF without one returns 1 with the
    # variables ASSIGNED, and every caller here treats 1 as "no ledger".
    printf '%s\t%s\n' "$sd" "$ledger"
    return 0
}

# _pane_longjob_root <pane_pid> <hb_file> → "<root_pid>:<root_start>" | nothing
#
# WHICH background-shell root of this pane is the longjob dispatcher's own
# wrapper — so `_pane_background_shells` can EXCLUDE that root's whole subtree
# from the census. The host launches the plugin monitor as
# `zsh -c … bash dispatch.sh` (measured live: claude → zsh → bash
# longjob-watch.sh dispatch → sleep), a real shell child of claude, and the
# process tree is AUTHORITATIVE over the footer.
#
# HISTORY, because the first repair was the wrong shape (bundle-2609sk2 F1).
# f755a3e8 answered 0|1 here and the refiner subtracted ONE from the count.
# The root stayed in the census, so every OTHER tree-derived field described
# the dispatcher instead of the work, for every armed session: `bg_shells` +1
# (idle-probe's `task_shells = bg_shells - bg_infra` left case (b0) and
# surfaced `wrapped-with-children` each cycle, naming the dispatcher);
# `bg_quiesce` never reached `bg_shells` (cc-update's `_restart_bg_all_quiescent`
# rc 0 → rc 1, the restart waits to its cap); `bg_members` changed on every
# sample because the dispatcher forks a `sleep` per poll (the #1460 wedge
# detector read a real static wedge as "a sequential driver"); `bg_oldest_start`
# was the SESSION's start (the 48 h ceiling and `bg_cpu_bp` measured session
# age); `bg_cmd` named the dispatcher. All measured by the skeptic's rigs 1–2.
# Excluding the subtree at the source makes every field clean at once and
# leaves the refiner nothing to subtract.
#
# IDENTITY, NEVER ARGV: the dispatcher is the ledger's `pid` whose /proc
# start-time (stat field 22, ticks) equals the ledger's `pid_start` — a
# recycled pid fails here. A string match on `dispatch.sh` would match a
# SIBLING session's dispatcher, whose argv is byte-identical (CLAUDE.md, "a
# predicate keyed on a STRING…").
#
# THE ROOT IS FOUND THE WAY THE CENSUS DEFINES ONE (sk2 F2): walk PARENT pids
# from the dispatcher up to the NEAREST `claude` comm and STOP there; the root
# is the first SHELL strictly BELOW that claude on the chain — exactly the node
# the census would count. f755a3e8 walked on to <pane_pid> and let ANY shell on
# the way satisfy it, so a launcher shell ABOVE claude vouched for a non-shell
# "dispatcher" that was a direct child of claude, and the verdict was `idle`
# over a real background shell (sk2 K4; unreachable in production today,
# reachable the day the host execs monitor commands without a shell). That
# claude must itself sit at or below <pane_pid>, or it is somebody else's.
#
# FAILURE DIRECTION: every doubt (no ledger, no jq, a mismatched start-time, no
# claude within 16 hops, no shell below it, a claude outside this pane) →
# NOTHING printed → nothing excluded → the shell stays counted →
# working-background: the direction that keeps a handle rather than retiring a
# live worker. And an exclusion can only ever remove the ONE root that owns the
# identified dispatcher: a second, real root is untouched (sk2 K2, kept as a
# suite case).
_pane_longjob_root() {
    local pane_pid="$1" hb="$2" sd ledger pid ps cur ppid stat comm after hop start
    local claude_pid="" i ok=0
    local -a chain_pid=() chain_start=() chain_shell=() f=()
    [[ "$pane_pid" =~ ^[0-9]+$ ]] || return 0
    IFS=$'\t' read -r sd ledger < <(_longjob_dispatcher_ledger "$hb") || return 0
    [[ -n "$ledger" ]] || return 0
    pid=$(jq -r '.pid // empty' "$ledger" 2>/dev/null); ps=$(jq -r '.pid_start // empty' "$ledger" 2>/dev/null)
    [[ "$pid" =~ ^[0-9]+$ && "$ps" =~ ^[0-9]+$ ]] || return 0
    cur="$pid"
    for hop in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
        { IFS= read -r stat < "/proc/$cur/stat"; } 2>/dev/null || return 0
        after="${stat##*) }"; comm="${stat%) *}"; comm="${comm#*(}"
        f=($after); ppid="${f[1]:-}"; start="${f[19]:-}"
        if (( hop == 1 )); then [[ "$start" == "$ps" ]] || return 0; fi
        case "$comm" in
            claude|claude.exe|claude-code) claude_pid="$cur"; break ;;
        esac
        if _pane_comm_is_shell "$comm"; then chain_shell+=(1); else chain_shell+=(0); fi
        chain_pid+=("$cur"); chain_start+=("$start")
        [[ "$ppid" =~ ^[0-9]+$ ]] && (( ppid > 1 )) || return 0
        cur="$ppid"
    done
    [[ -n "$claude_pid" ]] || return 0
    cur="$claude_pid"
    for hop in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
        if (( cur == pane_pid )); then ok=1; break; fi
        { IFS= read -r stat < "/proc/$cur/stat"; } 2>/dev/null || return 0
        after="${stat##*) }"; f=($after); ppid="${f[1]:-}"
        [[ "$ppid" =~ ^[0-9]+$ ]] && (( ppid > 1 )) || return 0
        cur="$ppid"
    done
    (( ok == 1 )) || return 0
    for (( i=${#chain_pid[@]}-1; i>=0; i-- )); do
        if (( ${chain_shell[i]} == 1 )) && [[ "${chain_start[i]}" =~ ^[0-9]+$ ]]; then
            printf '%s:%s' "${chain_pid[i]}" "${chain_start[i]}"
            return 0
        fi
    done
    return 0
}

# _longjob_dispatcher_verdict <hb_file> <now> → "armed <active>" | nothing
#
# ONE reading of the ledger verdict per pane-state call, consumed three ways:
# the census excludes the dispatcher's root only when ARMED (a stale, disabled
# or dead dispatcher stays a counted shell — "a stopped dispatcher is not one
# with nothing to say"); the footer's `N monitor` count is discounted by one
# only when armed AND active==0; and armed AND active>0 HOLDS the pane as a
# self-waking Monitor-style wait even when the footer cannot be read (see the
# refiner). Anything else prints nothing: not discounted, not excluded, not held.
_longjob_dispatcher_verdict() {
    local hb="$1" now="$2" sd ledger lj
    lj="$(dirname "${BASH_SOURCE[0]}")/longjob-watch.sh"
    [[ -x "$lj" ]] || return 0
    IFS=$'\t' read -r sd ledger < <(_longjob_dispatcher_ledger "$hb") || return 0
    [[ -n "$ledger" ]] || return 0
    local verdict active
    verdict=$(NEXUS_STATE_DIR="$sd" "$lj" ledger-verdict "$ledger" --now "$now" 2>/dev/null) || return 0
    [[ "${verdict%%|*}" == armed ]] || return 0
    # `active=` as COUNTED from the spool by the verb, never the ledger's
    # cached field: that field is published only by a completed pass, so
    # between an `add` and the next write it read 0 → `idle` → kill-authorised
    # over a worker parked on a 4-hour job (skeptic C2).
    active="${verdict##*|active=}"
    [[ "$active" =~ ^[0-9]+$ ]] || return 0
    printf 'armed %s' "$active"
}

_refine_idle_with_async_signals() {
    local pane_plain="$1" hb_file="$2" now="$3" async_staleness="$4"
    local pt_bg="${5:-0}" pt_reliable="${6:-0}" pt_stale="${7:-0}"
    # 9th arg: the longjob ledger verdict, `armed <active>` or empty, as read
    # ONCE by the caller (_longjob_dispatcher_verdict). An older caller that
    # passes no 9th arg gets it read here instead — never assumed.
    local lj_v="${9-__unread__}"
    [[ "$lj_v" == __unread__ ]] && lj_v=$(_longjob_dispatcher_verdict "$hb_file" "$now")
    local lj_armed=0 lj_active=0
    if [[ "$lj_v" == armed\ * ]]; then
        lj_active="${lj_v#armed }"
        if [[ "$lj_active" =~ ^[0-9]+$ ]]; then lj_armed=1; else lj_active=0; fi
    fi
    # 8th arg: the external-waits horizon (your-org/nexus-code#1220). Defaulted
    # rather than required so an older caller degrades to the CONSTANT, never
    # to 0 — a 0 horizon would make every wait stale and reproduce the defect
    # silently, which is the failure mode this whole change is about.
    local ew_staleness="${8:-$_HEARTBEAT_EXTERNAL_WAITS_STALENESS_DEFAULT}"
    [[ "$ew_staleness" =~ ^[0-9]+$ ]] || ew_staleness=$_HEARTBEAT_EXTERNAL_WAITS_STALENESS_DEFAULT
    [[ "$pt_bg" =~ ^[0-9]+$ ]] || pt_bg=0
    [[ "$pt_stale" =~ ^[0-9]+$ ]] || pt_stale=0

    local foot_mon=0 foot_bg=0
    if [[ -n "$pane_plain" ]]; then
        read -r foot_mon foot_bg < <(_footer_handle_counts "$pane_plain")
    fi
    # Monitor handles run INSIDE claude's node process (async tool
    # handles, not child processes), so the process tree can't see them
    # — the footer is their ONLY source (#1374: the heartbeat never
    # carried them; the arm that pretended otherwise is gone). A harness
    # build that rewords the spinner row, or a pane whose footer is
    # scrolled or truncated, removes this exemption: that fragility is
    # real and it is now stated here rather than hidden behind a max().
    local mon="$foot_mon"
    # Discount the idle longjob-watch dispatcher's own handle (#1535): armed AND
    # active==0, from the ledger verdict (see _longjob_dispatcher_verdict for
    # the gates and their failure direction). The process-tree channel needs
    # nothing here any more — the census excluded the dispatcher's root at the
    # source (bundle-2609sk2 F1), so `pt_bg` is already about the work.
    if (( mon > 0 )) && (( lj_armed == 1 )) && (( lj_active == 0 )); then
        mon=$(( mon - 1 ))
    fi
    # A LIVE watch is a self-waking wait — Monitor-handle semantics: claude is
    # re-invoked the instant it fires, so it must NEVER be aged out. With the
    # dispatcher's root out of the census the FOOTER is the only thing holding
    # such a pane, and the footer is the fragile channel (a reworded spinner
    # row, a scrolled or truncated pane — stated above). The armed ledger with
    # active>0 is the same fact from a source that cannot scroll away, so it
    # holds the pane on its own. Before the exclusion this pane read
    # working-background through the dispatcher's SHELL root — i.e. as a
    # fire-and-forget shell under the bg_cpu orphan-grace, which would
    # eventually age out a worker parked on a four-hour job.
    if (( mon == 0 )) && (( lj_armed == 1 )) && (( lj_active > 0 )); then
        mon=1
    fi
    # Background SHELLS are live child processes of claude, so the
    # process tree is GROUND TRUTH for them (your-org/nexus-code#455).
    # When the tree reading is reliable it is AUTHORITATIVE — it
    # overrides the footer regex both UP (a customised/changed status
    # bar that no longer renders the `N shell` token) and DOWN (a regex
    # coincidentally matching unrelated pane text). The footer/heartbeat
    # is consulted ONLY as a fallback when the tree reading is not
    # trustworthy (fixtures, empty pane_pid, /proc-restricted, no claude
    # found). Any residual footer false-positive on the fallback path is
    # still backstopped by the bg_cpu orphan-grace.
    # #1208: subtract the roots the AUTHORITY (async-run) says are waiting on
    # a job that already `died`. Those are not work in flight — no future event
    # can clear them — so they must not hold the `working-background` exemption
    # open forever. Only applied on the RELIABLE path: on the footer fallback
    # there is no process tree to attribute staleness to, and a stale count
    # measured against a count we did not measure would be a subtraction
    # between two different populations.
    local bg
    if (( pt_reliable == 1 )); then
        bg=$(( pt_bg > pt_stale ? pt_bg - pt_stale : 0 ))
    else
        bg="$foot_bg"
    fi

    if (( mon > 0 )) || (( bg > 0 )); then
        # Signal the DRIVER so the caller can scope the orphan-grace
        # cap (your-org/nexus-code#445). A background SHELL (bg>0) is
        # fire-and-forget — claude is NOT woken when it finishes, so a
        # hung one lingers and must be grace-capped via bg_cpu. A
        # Monitor handle (mon>0, bg==0) is self-waking — claude resumes
        # the instant it fires — so it must NEVER be aged out. The
        # `bg_shell=1` marker is consumed by _finalize_idle_verdict and
        # not propagated to the emit line.
        if (( bg > 0 )); then
            printf 'working-background\tbg_shell=1'
        else
            printf 'working-background'
        fi
        return 0
    fi

    if _heartbeat_scheduled_wakeup_at "$hb_file" "$now" "$async_staleness" >/dev/null; then
        printf 'working-self-paced'
        return 0
    fi

    local waits_summary
    if waits_summary=$(_heartbeat_external_waits_summary "$hb_file" "$now" "$ew_staleness"); then
        if [[ -n "$waits_summary" ]]; then
            printf 'idle-orphan-async\torphan_kinds=%s' "$waits_summary"
            return 0
        fi
    fi

    printf 'idle'
    return 0
}

# ---- gather pane state ----------------------------------------------------
if [[ -n "$fixture" ]]; then
    [[ -f "$fixture" ]] || { echo "fixture not found: $fixture" >&2; exit 2; }
    pane_ansi=$(<"$fixture")
    win_active="$fix_active"
    win_index="$fix_window"
    win_name="$fix_name"
else
    [[ -z "$target" ]] && usage
    # ONE KEY VOCABULARY WITH paste-followup.sh (your-org/nexus-code#905).
    # This used to accept ONLY an index or `session:window`, while the sibling
    # accepted ONLY a name — so `pane-state.sh 9` and `paste-followup.sh 9`,
    # typed in adjacent commands against the same window, disagreed. A NAME is
    # now resolved to its index through the SHARED resolver, so the two tools
    # cannot drift apart; an index and `session:window` keep working exactly as
    # before, which is what every existing caller passes.
    #
    # THE AMBIGUOUS KEY IS REFUSED, NOT ANSWERED. A key that is both a window
    # NAME and a DIFFERENT window's index used to be answered silently on the
    # index side — a confident answer about the wrong window, which is the
    # failure `#905` exists to prevent and is worse here than in the paste
    # tool, because this answer can authorise a kill.
    if [[ -r "$_PS_SCRIPT_DIR/_tmux-window.sh" ]]; then
        # shellcheck disable=SC1091
        . "$_PS_SCRIPT_DIR/_tmux-window.sh"
    fi
    # ------------------------------------------------------------------
    # THE RESOLVER IS A PRECONDITION, NOT AN OPTIONAL ENRICHMENT
    # (your-org/nexus-code#1281)
    # ------------------------------------------------------------------
    #
    # The source above is CONDITIONAL, and both consumers below used to
    # degrade differently when it did not take:
    #
    #   * the NAME arm already failed CLOSED — no `resolve_window_index`
    #     means `_ps_resolve_rc=3`, "we could not look", exit 2;
    #   * the NUMERIC arm failed OPEN — no `resolve_window_key` left
    #     `_ps_key_rc=0`, which is the value that means NOT AMBIGUOUS.
    #
    # So the one arm that can be handed a colliding key read "I could not
    # run the ambiguity check" as "I ran it and there is no ambiguity",
    # and then answered about the INDEX-side window. That is #603's
    # conflation — a definite verdict emitted for a condition the emitter
    # could not distinguish — sitting in front of the state resolver
    # rather than inside it.
    #
    # MEASURED, and the mitigating sentence attached to the original
    # finding ("a wrong-window answer, not a wrong-window kill") is
    # REFUTED. Fixture: two windows, index 0 NAMED `1` with a live
    # descendant, index 1 named `livework` whose pane pid is reaped.
    # Key `1` is ambiguous by construction.
    #
    #   library readable   -> rc 2, empty stdout, 169 B stderr  (refusal)
    #   library UNREADABLE -> rc 0, `state=absent ... name=livework`
    #   positive control (index 0, direct) -> `state=unknown
    #                                          reason=live-descendant`
    #
    # The key names a LIVE window; the fail-open answered `absent` about a
    # DIFFERENT one. `absent` is on `_bookkeeping.sh`'s
    # `_BK_KILL_OK_STATES` — this repo's own "the state that positively
    # asserts a dead agent" — so that is not a wrong-window ANSWER, it is
    # a wrong-window KILL AUTHORISATION. `idle` is reachable the same way
    # by construction, and it is on the allowlist too.
    #
    # THE GATE IS HOISTED ABOVE THE BRANCH ON PURPOSE. Repairing only the
    # numeric arm would leave the next arm to rediscover this, which is
    # exactly how the `session:window` spelling survived the first pass at
    # `#905` (the sk907 F2 residue noted below). One precondition, checked
    # once, before anything dispatches on the key's shape.
    #
    # IT IS ALSO A NARROWING, NEVER A WIDENING: the only new outcome is a
    # REFUSAL (exit 2, nothing on stdout), and the kill gate default-denies
    # every state it is not given. A caller that used to receive a
    # confident wrong answer now receives none.
    if ! declare -F resolve_window_key >/dev/null 2>&1 \
        || ! declare -F resolve_window_index >/dev/null 2>&1; then
        printf 'pane-state.sh: the window-key resolver (%s) is unavailable, so the AMBIGUITY CHECK COULD NOT RUN. This is NOT a claim that %s is unambiguous, and it is NOT a claim about the window. Refusing to classify: a wrong-window answer here can be a kill authorisation. This is a broken install, not a supported configuration.\n' \
            "$_PS_SCRIPT_DIR/_tmux-window.sh" "$target" >&2
        exit 2
    fi
    if [[ "$target" =~ ^[0-9]+$ || "$target" =~ ^[^:]+:[0-9]+$ ]]; then
        # THE AMBIGUITY CHECK COVERS BOTH NUMERIC FORMS (sk907 F2 residue).
        # The first version of this fix guarded only the BARE index and left
        # `session:window` a straight passthrough — so `pane-state.sh 0:1`
        # silently answered about the index-side window while
        # `paste-followup.sh 0:1` refused, i.e. the two helpers still
        # disagreed, on the form CLAUDE.md documents and orchestrators
        # actually type. That closed the demonstrated repro and left the
        # mechanism live one form over. `resolve_window_key` strips the
        # session itself, so ONE call covers both spellings and there is no
        # second code path to forget next time.
        # CALLED DIRECTLY, not behind a `declare -F` guard
        # (your-org/nexus-code#1281). The precondition hoisted above the
        # branch already established the resolver is present, and a second
        # existence guard here would re-create the exact fail-open it
        # removes: `_ps_key_rc=0` is the value that means NOT AMBIGUOUS, so
        # a skipped check and a passed check would once again be spelled
        # identically. There must be ONE place in this file where that
        # question is answered.
        _ps_key_rc=0
        resolve_window_key "$target" >/dev/null 2>&1 || _ps_key_rc=$?
        if (( _ps_key_rc == 4 )); then
            printf 'pane-state: AMBIGUOUS window key %s — its window part is both a window NAME and a different window'"'"'s INDEX. Refusing to answer about either; pass the unambiguous name.\n' \
                "$target" >&2
            exit 2
        fi
        # rc 3 IS NOT "NOT AMBIGUOUS" (your-org/nexus-code#1318).
        #
        # Only rc 4 used to be consulted, and `_ps_key_rc=0` is the value that
        # MEANS not-ambiguous — so an rc 3 ("tmux would not answer, the check
        # did not run") reached the same downstream code as a check that ran
        # and passed. That is the `#1281` mechanism one layer inward, in the
        # runtime rc of the very call `#1281`'s precondition was hoisted to
        # protect: the precondition establishes the resolver EXISTS, and says
        # nothing about whether its answer arrived.
        #
        # It matters more now than it did, because `#1318` gave the check a
        # new way to fail: the collision sweep spans SESSIONS, so it makes a
        # second tmux call, and a server that answers the first and not the
        # second is an ordinary transient. Landing that in the permissive arm
        # would put a fresh fail-open inside the fix for a fail-open.
        if (( _ps_key_rc == 3 )); then
            printf 'pane-state.sh: the AMBIGUITY CHECK for %s COULD NOT RUN — tmux would not answer. This is NOT a claim that %s is unambiguous and NOT a claim about the window. Refusing to classify: a wrong-window answer here can be a kill authorisation.\n' \
                "$target" "$target" >&2
            exit 2
        fi
        if [[ "$target" =~ ^[0-9]+$ ]]; then
            win="0:$target"
            win_index="$target"
        else
            win="$target"
            win_index="${target##*:}"
        fi
    else
        # A NAME. Resolve it through the shared vocabulary.
        #
        # THE RESOLVER'S rc IS KEPT, and that is the whole point of this arm
        # (your-org/nexus-code#1101). It used to be discarded — every failure
        # printed `usage` and exited 2 — so a name that is simply NOT A LIVE
        # WINDOW was reported as "your argv was wrong". That is precisely the
        # distinction this file's own header says exit 3 exists to make: exit 2
        # is "argv shape was wrong", exit 3 is "argv shape was fine but it is
        # not a live window". The INDEX spelling has always honoured it
        # (`0:9999` → exit 3); the NAME spelling did not, so no caller could
        # tell a vanished window from a typo, and a watcher loop holding a row
        # for an unobservable pane had no way to learn the pane was GONE.
        #
        #   resolve_window_index: 0 index | 1 no such window | 2 empty key
        #                         3 tmux would not answer
        #
        # Only rc 1 is a POSITIVE claim that the window is not there, so only
        # rc 1 becomes exit 3. rc 3 is "we could not look", which must never
        # wear the same code as "it is gone" — that conflation is the #603 /
        # #699 class this repo keeps paying for — so it keeps exit 2 with a
        # diagnostic that says which fact it saw, instead of the usage block
        # that used to misdiagnose it.
        _ps_resolved=
        _ps_resolve_rc=0
        if declare -F resolve_window_index >/dev/null 2>&1; then
            _ps_resolved=$(resolve_window_index "$target" 2>/dev/null) || _ps_resolve_rc=$?
        else
            _ps_resolve_rc=3
        fi
        if [[ -n "$_ps_resolved" ]]; then
            win="0:$_ps_resolved"
            win_index="$_ps_resolved"
        elif (( _ps_resolve_rc == 1 )); then
            # Same contract as the bogus-index arm below: stderr, exit 3,
            # NOTHING on stdout, so a grep-style probe cannot false-match.
            echo "pane-state.sh: no such tmux window: ${target}" >&2
            exit 3
        elif (( _ps_resolve_rc == 3 )); then
            echo "pane-state.sh: could not ask tmux to resolve window name '${target}' — this is NOT a claim that the window is absent." >&2
            exit 2
        else
            usage
        fi
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        # `absent` is a DEFINITE claim — "the window exists and no live
        # claude is in its process tree" — and it is the claim that
        # authorises a kill. Without tmux we have not looked at
        # anything, so asserting it is the #603 defect in its purest
        # form: a definite state reported for a condition the emitter
        # cannot distinguish. Report the indeterminacy instead; the
        # kill gate default-denies every state not on its allowlist,
        # so `unknown` is refused without needing to be enumerated.
        echo "state=unknown active=0 window=${win_index} name="
        exit 0
    fi
    # Bogus-index fail-loud (issue #140). We previously emitted
    # `state=absent name=` + exit 0 for a non-existent window index,
    # which is indistinguishable on stdout from a real window whose
    # claude died (`state=absent name=<actual>`). Operators reading
    # `state=absent` for a typo'd index then concluded "the window is
    # gone" and acted on it. The fix: surface the caller error on
    # stderr, exit 3, emit nothing on stdout so a grep-style probe
    # (`pane-state.sh <idx> | grep state=absent`) cannot false-match.
    #
    # Detection: ask tmux what `#{window_index}` it RESOLVED $win to.
    # Older tmux (2.x) errors on a bogus -t target with rc≠0 + empty
    # stdout; newer tmux (3.x on ubuntu-latest CI) gracefully falls
    # back to the session's active window, returning rc=0 + valid
    # data for the WRONG window. Comparing the resolved index to the
    # requested one catches both modes uniformly.
    actual_idx=$(tmux display-message -p -t "$win" '#{window_index}' 2>/dev/null)
    if [[ -z "$actual_idx" ]] || [[ "$actual_idx" != "$win_index" ]]; then
        echo "pane-state.sh: no such tmux window: ${win_index}" >&2
        exit 3
    fi
    win_name=$(tmux display-message -p -t "$win" '#{window_name}' 2>/dev/null) || win_name=
    win_active=$(tmux display-message -p -t "$win" '#{window_active}' 2>/dev/null) || win_active=0
    [[ -z "$win_active" ]] && win_active=0
    # Pane pid drives the live-claude check that distinguishes `empty`
    # from `absent` when no input row matches. `display-message -p -t
    # <win>` targets the window's active pane.
    pane_pid=$(tmux display-message -p -t "$win" '#{pane_pid}' 2>/dev/null) || pane_pid=
    # `#{pane_dead}` is tmux's OWN assertion that the pane process exited
    # (the pane survives only because `remain-on-exit on`). It is the one
    # positive, first-party signal of death available here, so the gate
    # below trusts it ahead of any process-tree inference
    # (your-org/nexus-code#777).
    pane_dead=$(tmux display-message -p -t "$win" '#{pane_dead}' 2>/dev/null) || pane_dead=
    # -J joins wrapped lines so a multi-line autosuggest renders on one
    # logical row, matching the regexes below.
    #
    # your-org/nexus-code#788: "the capture FAILED" and "the pane is genuinely
    # blank" are different facts and must not share a representation. They did —
    # `|| pane_ansi=` discarded the rc — and that conflation is what made the
    # downstream `[[ -z "$pane_ansi" ]] ⇒ absent` arm look reasonable at its call
    # site. Measured on a real private-socket server, same pane, same instant,
    # live `claude` at the pane root and `pane_dead=0`:
    #
    #     healthy tmux         -> state=idle
    #     capture-pane rc=1    -> state=absent      <-- kill-authorising
    #
    # One transient failure of one tmux subcommand flipped a healthy worker into
    # the one state that authorises killing it. The rc is now kept so the verdict
    # can say WHICH fact it saw.
    if pane_ansi=$(tmux capture-pane -t "$win" -p -e -J -S -25 2>/dev/null); then
        pane_capture_ok=1
    else
        pane_ansi=
        pane_capture_ok=0
    fi
fi
# Fixture path: no live process to inspect by default, so the pid check
# is bypassed (callers asserting on `state=empty` against a fixture file
# rely on the renderer-only path). The `--pane-pid` flag is the test-
# surface escape hatch — supply a known-dead pid to exercise the
# liveness gate against a fixture that would otherwise classify alive.
pane_pid="${pane_pid_override:-${pane_pid:-}}"

# Set once the pane is captured (renderer path, or the heartbeat
# idle-refinement capture). Appended to every emit as `content_hash=`
# so the watcher can diff transcript content across cycles. Empty on
# the heartbeat-authoritative busy/blocked fast path (no capture there).
pane_content_hash=""

emit() {
    local state="$1"
    shift
    local extra=""
    if (( $# > 0 )); then
        # Caller passes optional extra fields verbatim (e.g.
        # `reset_at=<token>`). Join with single spaces.
        local IFS=' '
        extra=" $*"
    fi
    # `auth=<login|expired>` — computed HERE, in the emitter, rather than at the
    # arms that happen to care (your-org/nexus-code#1518). Three reasons, and
    # the third is the load-bearing one:
    #
    #   * `auth=expired` rides on whatever verdict the pane produces. Measured,
    #     that is `idle`; but a logged-out orchestrator that is ALSO mid-render,
    #     ALSO holding a background shell, ALSO drawing a ghost suggestion
    #     reaches a different arm each time, and "this session cannot reach the
    #     API" is true of all of them.
    #   * THERE ARE TWO CLASSIFICATION ROUTES, not one. `_classify_from_heartbeat`
    #     emits and `exit 0`s some 50 lines before the renderer path's own
    #     `pane_plain` / `pane_content_hash` assignments are ever reached, so a
    #     field computed only at the renderer site is ABSENT from every
    #     heartbeat-classified pane — and the orchestrator carries hooks, so the
    #     heartbeat route is the one it normally takes.
    #   * a field added at N arms is a field MISSING from arm N+1. `#788`'s
    #     lesson is this shape one axis over: three independent sites
    #     re-deriving one contract, the class regenerating each time, until the
    #     derivation moved to the single door every path goes through.
    #
    # So the only way to emit a state without its `auth=` reading is to bypass
    # `emit` entirely, which nothing does. `${pane_auth+set}` — not `:-` — so a
    # value an arm has DELIBERATELY set, including the empty string, is honoured
    # and not recomputed over; only an entirely unset variable is derived here.
    # Omitted when neither surface is present, exactly as `queued=1` /
    # `throttled=1` / `limit=` are, so no consumer parsing a fixed token set is
    # disturbed.
    if [[ -z "${pane_auth+set}" ]]; then
        pane_auth=""
        if [[ -n "${pane_plain:-}" ]]; then
            # `login` FIRST and INDEPENDENTLY OF THE MENU FRAME (skeptic w237sk
            # F2). `auth=login` used to be set at exactly one place — the
            # `_has_blocked_overlay` arm — which is gated on
            # `_has_menu_dialog_frame` and therefore requires a MULTI-OPTION
            # SELECT MENU. Measured on the live 2.1.268 pane, the browser-auth /
            # code-paste step classifies `state=empty` and carried NO `auth=`:
            # the one login screen where a stray paste is worst was the one
            # screen neither axis covered.
            #
            # THE LIVE-vs-QUOTED DISCRIMINATOR IS STRUCTURAL, not a margin: a
            # live dialog has REPLACED the REPL, so no `❯<NBSP>` input row can
            # appear; a pane merely DISCUSSING a login screen is a running REPL
            # and keeps its row. That is the same test
            # `_has_bypass_permissions_modal` documents, and it is what stops an
            # agent reading #1518 from labelling its own pane. Verified on the
            # live capture: no `❯<NBSP>`, and `state=empty` is precisely the
            # no-input-row branch.
            # AN ACTIVELY-WORKING PANE IS NOT SITTING ON A LOGIN SCREEN
            # (skeptic w237sk D2). The live-vs-quoted discriminator moved from
            # structural (`state=blocked`) to textual when F2 widened the label
            # arm, and its precondition — no `❯<NBSP>` row — COINCIDES with a
            # reading `#603` measured on a pane 4m38s into a verification pass.
            # Measured on this corpus: **11 real `busy` captures lack that row**,
            # including `busy-dialog-quoted-midrender-synthetic.ansi`, which
            # exists specifically as the live-vs-quoted control for the dialog
            # family. Splice one quoted row into it — the literal as an
            # orchestrator reading `GUIDE.md` or `#1518` would render it — and it
            # was labelled `auth=login`, so the watcher HELD on a working pane.
            #
            # DIRECTION, MEASURED RATHER THAN ARGUED, because the cost of getting
            # it wrong is a MISSED login and that is unbounded where a delayed
            # emit is not. The states a real login frame actually reaches are
            # `blocked` (both menus), `empty` (the live code-paste step),
            # `absent` (that capture in fixture mode) and `idle` (the heartbeat
            # route) — every one of them outside this list. And on a heartbeat
            # route reporting `busy`, a login capture already carries NO label at
            # all, because that branch emits before `pane_plain` is populated: so
            # excluding `busy` removes nothing that exists today. Verified on all
            # three login captures plus the heartbeat `busy`/`user_prompt` arms.
            #
            # THE LIST IS THE TWO GENERATING STATES ONLY (w239sk F1, correcting
            # D2's overshoot). D2 first excluded `working-background` and
            # `working-self-paced` too. Both are REFINEMENTS OF AN IDLE BASE
            # VERDICT — the turn has ended and only a pending wake mechanism
            # differs — so the structural discriminator (no `❯<NBSP>` row) is
            # as sound for them as for `idle`: an idle-based pane with no input
            # row and a login frame IS sitting on a login screen. Excluding them
            # made the veto in cc-auto-update-apply.sh's `_restart_eligible`
            # INERT on exactly the route that matters: the orchestrator holds
            # the supervisor Monitor and so reads `working-background` on the
            # heartbeat route, and both states are restart-eligible — a login
            # frame there read eligible, unlabelled, and the restart killed the
            # login (driven on the real emitter by w239sk). `busy` stays out
            # because D2's measurement stands for it — eleven real busy
            # captures lack the row — and `over-limit` stays out because it is
            # never restart-eligible and its paste hazard is already held by
            # `_over_limit_orchestrator_paused`, so excluding it costs nothing
            # and keeps the banner-heavy pane out of the label arm. Cost of the
            # narrowing, stated: a heartbeat-idle pane mid-render that QUOTES a
            # login literal with no row visible gets a bounded emit hold and a
            # bounded restart abort instead of a paste or a kill.
            #
            # Equality over a fixed list, not a glob — `#1121`: a pattern is
            # where "no input matches two arms" quietly stops being true, and
            # this predicate decides whether the operator's pane gets written to.
            local _ps_active=0 _ps_s
            for _ps_s in busy over-limit; do
                [[ "$state" == "$_ps_s" ]] && _ps_active=1
            done
            if (( _ps_active == 0 )) \
               && ! grep -qF "❯${NBSP}" <<<"$pane_plain" \
               && _dialog_is_login "$pane_plain"; then
                pane_auth=login
            elif _detect_auth_expired "$pane_plain"; then
                pane_auth=expired
            fi
        fi
    fi
    [[ -n "$pane_auth" ]] && extra+=" auth=$pane_auth"
    [[ -n "$pane_content_hash" ]] && extra+=" content_hash=$pane_content_hash"
    printf 'state=%s active=%s window=%s name=%s%s\n' \
        "$state" "$win_active" "$win_index" "$win_name" "$extra"
}

# ===========================================================================
# THE ONE DOOR TO `absent` — your-org/nexus-code#788
# ===========================================================================
#
# `absent` is the ONE kill-authorising state (`_bookkeeping.sh:
# bk_pane_kill_authorized` allowlists it; CLAUDE.md calls it "the state that
# positively asserts a dead agent"). Its contract was enforced NOWHERE. Each
# emit site re-derived it, and THREE of them reached it by FALLING THROUGH
# rather than by deciding:
#
#   * the hoisted process gate            — closed by `#780`
#   * the renderer's no-input-row fallback — `#776`'s modal lands here
#   * `[[ -z "$pane_ansi" ]] ⇒ absent`     — closed by NEITHER, and measured on
#     a real private-socket server to emit the kill-authorising state for a pane
#     whose ROOT PROCESS WAS A LIVE `claude` with `pane_dead=0`, the moment one
#     `tmux capture-pane` call returned rc≠0.
#
# Three sites, three independent fixes, and the class kept regenerating — `#777`
# and `#776` landed on it from unrelated directions within the same day. So the
# fix is not a third patch: it is an INVERSION. Today `absent` is what you get by
# NOT deciding. From here it is the only verdict that must NAME ITS EVIDENCE, and
# everything else degrades to `unknown` — already off the kill allowlist, and
# already handled by `retire-preflight.sh` as a deferral.
#
# This is the same default-deny inversion `bk_pane_kill_authorized` applies one
# layer down, and which cannot help while the wrong answer arrives on the ALLOW
# side. Putting it here, at the emitter, is what makes it reachable at all.
#
# THE TRADE, STATED PLAINLY AND IT IS ONE-SIDED: a false `absent` kills a live
# worker; a false `unknown` postpones a cleanup. But a deferral that never lapses
# is an unreapable pane — the mirror-image failure — so every refusal below is
# either self-clearing (the boot grace lapses with the pane's own age) or
# self-diagnosing (the tool blindness and the capture failure name themselves in
# `reason=`). `test-pane-state-boot-absent.sh` asserts the LAPSE, not just the
# refusal, and reddens if the deferral ever becomes permanent.

# _absent_evidence <pane-pid>
#
# Prints an evidence/refusal token. Exit 0 => `absent` is JUSTIFIED and the token
# names the positive evidence. Exit 1 => refuse; the token says why.
#
# It establishes its own evidence from scratch rather than trusting the caller.
# That costs a few extra `ps`/`pgrep` calls on the one path about to authorise a
# kill, and it is the entire point: a door that believes what it is told is not a
# door. Order matters — each arm is tried only after the more definite ones have
# declined.
_absent_evidence() {
    local pid="${1:-}"

    # (0) Fixture mode. `--fixture` is a TEST SURFACE with no `-t` target and no
    #     process to inspect; supplying a fixture and declining `--pane-pid` is
    #     the caller DECLARING there is no process, which is the contract every
    #     renderer-path fixture assertion already rests on. This is a
    #     declaration, not an observation, and it is admitted here for exactly
    #     one reason: `--fixture` is unreachable from production. The watcher
    #     never passes it. Guard it on the flag so it can never widen.
    if [[ -n "$fixture" && -z "$pid" ]]; then
        printf 'fixture-no-process'; return 0
    fi

    # (1) tmux's OWN assertion that the pane process exited (the pane survives
    #     only because `remain-on-exit on`). First-party and definite — and it
    #     must be checked BEFORE any process probe, since a dead pane_pid is
    #     legitimately invisible to `ps`.
    if [[ "$pane_dead" == 1 ]]; then
        printf 'pane_dead'; return 0
    fi

    # (2) No pid at all: a window that resolved but whose pane process tmux would
    #     not name. That is a failure to LOOK, not a negative observation.
    if [[ -z "$pid" ]]; then
        printf 'no-pane-pid'; return 1
    fi

    # (3) A live claude in the tree. The classifier ALREADY KNOWS the agent is
    #     alive — this is the arm that the `-z pane_ansi` site short-circuited
    #     past, which is how a healthy worker got the kill-authorising verdict.
    if _pane_has_live_claude "$pid"; then
        printf 'live-claude'; return 1
    fi

    # (4) Something is still running under the pane — a launcher preamble that
    #     has not reached `exec claude` yet (`#643`). "A launcher is running but
    #     the agent has not started" is not a dead agent.
    if _pane_has_live_descendant "$pid"; then
        printf 'live-descendant'; return 1
    fi

    # (4b) A pid in the tree could not be IDENTIFIED (your-org/nexus-code#908).
    #      `_pid_runs_claude` separates "this is not claude" from "I could not
    #      tell", and only the first is a negative observation. Reading the
    #      second as a negative is how `#908` put a live worker in the one
    #      kill-authorising state — so decline here, on the same reasoning as
    #      (2), (5) and (7). Weighted deliberately: mistaking a live worker for
    #      dead destroys work, mistaking a dead one for live strands a slot.
    if [[ "${_PHLC_INDETERMINATE:-0}" == 1 ]]; then
        printf 'claude-identity-indeterminate'; return 1
    fi

    # (5) Can this process even SEE processes? `ps`/`pgrep` answering "no" and
    #     being BLIND are indistinguishable at their return values (`#777`).
    if ! _proc_view_functional; then
        printf 'proc-view-blind'; return 1
    fi

    # (6) `ps` works (just proved) and does not see pane_pid: the pane process is
    #     genuinely gone. Definite, and the fixture-mode `--pane-pid <dead-pid>`
    #     contract rests on it.
    local age
    if ! age=$(_pane_age_seconds "$pid"); then
        printf 'pid-gone'; return 0
    fi

    # (7) Nothing alive under a pane too young to have booted yet. Indis-
    #     tinguishable from a spawn in progress (`#777`: 3 of 5 production-shaped
    #     spawns reported `absent` 1.37-2.05 s in, on panes with `pane_dead=0`
    #     and perfectly healthy shells). SELF-CLEARING: the same probe returns
    #     `absent` the moment the grace lapses, so the deferral is bounded by the
    #     pane's own age and cannot become permanent.
    if (( age < PANE_BOOT_GRACE_SECONDS )); then
        printf 'boot-grace'; return 1
    fi

    # (8) Everything stronger has declined: a pane old enough to have booted,
    #     whose process view works, with no claude and nothing else alive
    #     underneath it. THIS is a dead agent.
    printf 'tree-empty-past-grace'; return 0
}

# _emit_absent_or_unknown <site-label>
#
# The only permitted way to reach `absent`. Emits it with the evidence named, or
# emits `unknown` with the refusal reason and the SITE that asked — so an
# operator reading a deferral can tell which arm of the classifier deferred, and
# a future reviewer can tell at a glance that no site invents its own verdict.
_emit_absent_or_unknown() {
    local site="$1" tok
    if tok=$(_absent_evidence "$pane_pid"); then
        emit absent "evidence=$tok"
    else
        # Surface the capture rc too: `#788`'s live hazard is a FAILED capture
        # being read as a blank pane, and an operator seeing `capture=failed`
        # knows the classifier was working from nothing.
        local cap=""
        (( pane_capture_ok )) || cap=" capture=failed"
        emit unknown "reason=$tok" "site=$site${cap}"
    fi
}

# 0a. Process-liveness gate (hoisted). Runs before the heartbeat path
#     and before any renderer matching. tmux's `remain-on-exit on`
#     keeps the dead pane visible with stale bytes — the chevron, dim
#     cursor, and bright markers all linger after the inner REPL
#     exits, so any regex-only classifier would forever return
#     `idle`/`autosuggest-only`/`busy` for a pane that's actually
#     gone. Process check is ground truth: when no `claude`
#     descendant lives in pane_pid's tree, emit `absent`.
#
#     Skipped when pane_pid is empty: fixture mode (no real process
#     to check) and the rare "newly-spawned window without a
#     pane_pid yet" path both fall through to the existing
#     classification chain.
if [[ -n "$pane_pid" ]] && ! _pane_has_live_claude "$pane_pid"; then
    # your-org/nexus-code#643. "No claude in the tree" is NOT the same claim as
    # "this agent is dead", and `absent` asserts the second. It is the ONE
    # kill-authorising state — CLAUDE.md calls it "the state that positively
    # asserts a dead agent" and bk_pane_kill_authorized allowlists it — so the
    # whole default-deny design downstream rests on it never being wrong when
    # asserted. Default-deny cannot help when the wrong answer is on the ALLOW
    # side.
    #
    # A freshly spawned window spends its first seconds running the generated
    # launcher's preamble before `exec claude`, with no claude in the tree yet.
    # Emitting `absent` there told an orchestrator to "relaunch or close" a
    # healthy agent — during precisely the interval when it is most likely to
    # ask, right after spawning, to check the spawn took.
    #
    # So downgrade to `unknown` when something is still running under the pane:
    # `unknown` already means "could not answer" and is NOT on the kill
    # allowlist, which is the correct reading of "a launcher is running but the
    # agent has not started yet". `absent` is reserved for a pane with nothing
    # alive underneath it at all — strictly stronger than before, which is what
    # makes it worth trusting.
    # your-org/nexus-code#777. #643 closed the sub-case where the launcher is
    # ALREADY a descendant. It does not close the one before that: production
    # spawns with `tmux new-window -d` carrying NO command (verified: the live
    # server runs default-shell=/usr/bin/zsh, default-command=""), so tmux
    # execs the login shell AS the pane process, and the launcher only becomes
    # a descendant once that shell has finished its rc chain and read the
    # `send-keys` bytes. Until then pane_pid has no descendants AT ALL, and
    # descendant-liveness — the axis #643 chose precisely because it beats a
    # timer — carries no information whatsoever.
    #
    # Measured in a private-socket fixture reproducing that exact shape
    # (`new-window` with no command, `send-keys` fired immediately as
    # spawn-worker.sh does), zsh pane shell, ambient load 47 on 36 cores:
    # 3 of 5 spawns reported `absent` on the FIRST probe, 1.37-2.05 s in, on a
    # pane with `pane_dead=0` and a perfectly healthy shell.
    #
    # So #643's "a timer would have to guess a duration" is right about the
    # case it was written for and wrong here: while nothing is running under
    # the pane, elapsed time since the pane was created is the ONLY axis on
    # which booting and dead differ. The grace is not a substitute for the
    # real discriminator, it IS the real discriminator for this sub-case.
    #
    # your-org/nexus-code#788. The decision ladder that used to live inline here
    # is now `_emit_absent_or_unknown`, the ONE door to `absent` — see its header.
    # Lifting it out is the whole point: three separate sites reached `absent` by
    # falling through, and #780 fixed only this one.
    _emit_absent_or_unknown liveness-gate
    exit 0
fi

# Resolve the over-limit stamp path early so multiple downstream
# checks can re-use it. The check itself fires AFTER the blocked-
# overlay detection (see 1b below) — when the rate-limit menu is
# up, `_unstick.sh:case_B` needs `state=blocked` to fire its
# auto-Enter cascade. Once the menu is dismissed (or never rendered
# because the hook beat the menu's redraw), the over-limit stamp
# takes over for the entire suspension. Issue #129 item 4 + the
# brief's "case-B cascade MUST still fire" constraint.
ol_file=""
if [[ -n "$over_limit_file_override" ]]; then
    ol_file="$over_limit_file_override"
elif [[ -n "${NEXUS_STATE_DIR:-}" ]] && [[ -n "$win_name" ]]; then
    ol_file="$NEXUS_STATE_DIR/over-limit/$win_name.json"
elif [[ -n "${NEXUS_ROOT:-}" ]] && [[ -n "$win_name" ]]; then
    ol_file="$NEXUS_ROOT/monitor/.state/over-limit/$win_name.json"
fi

# The ORCHESTRATOR's activity marker, and whether THIS pane is that window
# (your-org/nexus-code#1155 residual 2). See
# `_over_limit_stamp_superseded_by_activity` for why a marker MTIME is
# admissible evidence here and a per-window heartbeat is not available.
#
# The window name is resolved from the same inputs the orchestrator's own
# settings and the watcher's config use, most authoritative first:
#   --orchestrator-window        an explicit caller. `_idle_probe.sh` passes it
#                                (the caller whose verdict gates the emit path).
#   $MONITOR_TARGET              how every OTHER caller under the watcher gets
#                                it: `_config.sh` EXPORTS the resolved target, so
#                                the whole watcher process tree inherits it.
#
#                                That export exists because per-call-site
#                                threading was the wrong shape and was measured
#                                so (#1171 R2-C): a first pass enumerated the
#                                executors, found ONE, and shipped a comment
#                                naming three non-passing callers. There are SIX
#                                under `monitor/watcher/` at this ref, and the
#                                miss came from a `| head` on the enumeration
#                                itself. Re-derive rather than trust this number:
#                                  git grep -nE 'pane_state_script|pane-state\.sh' -- monitor \
#                                    | grep -vE '/test-|\.md:'
#                                Callers OUTSIDE the watcher tree (`ng`,
#                                `retire-preflight.sh`, `cc-auto-update-apply.sh`,
#                                `skeptic-channel.sh`) inherit the export only if
#                                run under it, and otherwise fall back below.
#   $MONITOR_TARGET              the watcher's env override for that config key
#   $NEXUS_ORCHESTRATOR_WINDOW   what the orchestrator launcher exports
#   orchestrator                 the default `monitor.target_window` resolves to,
#                                and the literal fallback inside
#                                orchestrator-settings.json's own clear
#
# A board that customises `monitor.target_window` WITHOUT setting either env
# var resolves the wrong name here — and the failure is fail-closed rather than
# unsafe. Reasoned on both directions, because only one of them would matter:
# for the REAL orchestrator the fallback simply never fires, which is exactly
# today's behaviour; and for a WORKER that happens to bear the default name the
# fallback is structurally unreachable, because it is consulted ONLY when the
# per-window heartbeat is unusable and every worker writes one
# (`worker-settings.json` registers `worker-heartbeat.sh`). So the dangerous
# direction is closed by the ordering, not by the name being right.
orch_window="${orch_window_override:-${MONITOR_TARGET:-${NEXUS_ORCHESTRATOR_WINDOW:-orchestrator}}}"
orch_hb_file=""
if [[ -n "$orch_hb_file_override" ]]; then
    orch_hb_file="$orch_hb_file_override"
elif [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    orch_hb_file="$NEXUS_STATE_DIR/orchestrator-heartbeat"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    orch_hb_file="$NEXUS_ROOT/monitor/.state/orchestrator-heartbeat"
fi
# Passed to the rule only for the orchestrator's own pane; empty for every
# other window, so no worker's stamp can ever be invalidated by the
# orchestrator's activity.
if [[ -z "$win_name" ]] || [[ "$win_name" != "$orch_window" ]]; then
    orch_hb_file=""
fi

_emit_over_limit_from_stamp() {
    local f="$1" reset_at=unknown flavour=unknown v
    if command -v jq >/dev/null 2>&1; then
        v=$(jq -r '.reset_at // empty' "$f" 2>/dev/null)
        if [[ -n "$v" ]] && [[ "$v" != "null" ]]; then
            # Mirror the renderer's reset_at normalisation: strip
            # parens, collapse whitespace to `_`, cap at 40 chars.
            v=$(printf '%s' "$v" | tr -d '()' | tr -s '[:space:]' '_' | sed 's/_*$//')
            v="${v:0:40}"
            [[ -n "$v" ]] && reset_at="$v"
        fi
        # WHICH limit, read from the hook payload rather than assumed
        # (your-org/nexus-code#1488). The StopFailure hook records the
        # harness's own message; "weekly Opus limit" was being asserted for a
        # worker whose payload said Fable.
        v=$(jq -r '.error_message // empty' "$f" 2>/dev/null)
        if [[ -n "$v" ]] && [[ "$v" != "null" ]]; then
            v=$(grep -oE 'your ([[:alnum:]-]+ ){0,2}limit' <<<"$v" \
                    | tail -1 | sed -E 's/^your[[:space:]]*//; s/[[:space:]]*limit$//')
            v=$(printf '%s' "$v" | tr -s '[:space:]' '_' | sed 's/_*$//')
            [[ -n "$v" ]] && flavour="${v:0:40}"
        fi
    fi
    emit over-limit "reset_at=$reset_at" "limit=$flavour"
}

# Anti-latch TTL on the hook-written stamp. The stamp's cleanup
# contract is "the Stop hook on the next successful turn removes it"
# — but a pane whose settings lost the Stop entry (respawn with stale
# settings, manual launch) would otherwise read over-limit FOREVER,
# and a permanently-suppressed watcher channel is a deadlock worse
# than any wasted paste. A stamp older than the TTL (default 27h:
# the longest "resets <clock-time>" horizon is 24h, plus margin) is
# treated as expired — ignored and best-effort deleted, falling
# through to the renderer detection, which re-detects a GENUINE
# ongoing suspension from the live pane text.
# Returns 0 when the stamp is expired (caller skips it).
_over_limit_stamp_expired() {
    local f="$1" now ts ttl
    ttl="${MONITOR_OVER_LIMIT_STAMP_TTL_SECONDS:-97200}"
    [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=97200
    now="${now_override:-$(date +%s)}"
    ts=""
    if command -v jq >/dev/null 2>&1; then
        ts=$(jq -r '.ts // empty' "$f" 2>/dev/null)
    fi
    # No parseable ts (jq missing / corrupt stamp): fall back to the
    # file's mtime so a corrupt stamp still ages out.
    if ! [[ "$ts" =~ ^[0-9]+$ ]]; then
        ts=$(date +%s -r "$f" 2>/dev/null) || ts=""
    fi
    [[ "$ts" =~ ^[0-9]+$ ]] || return 0  # unreadable ⇒ treat as expired (fail open)
    (( now - ts > ttl ))
}

# POST-STAMP MODEL ACTIVITY INVALIDATES THE STAMP (your-org/nexus-code#1141).
#
# The stamp's documented cleanup contract is "the Stop hook on the next
# successful turn removes it". That contract is INTACT and correctly wired —
# and it is the defect. A `Stop` may be tens of minutes away, because a pane
# can service a single turn for that long; meanwhile 1b below short-circuits
# to `over-limit` and exits BEFORE any liveness inspection, so every consumer
# reads a suspended pane that is demonstrably working.
#
# Measured on the production board, window `devred`, 2026-08-28:
#
#     stamp written (StopFailure, rate_limit)   12:42:52   reset_at 1:40pm
#     watcher observed alive (state=busy)       12:56:05
#     watcher pasted a resume brief             12:56:07
#     heartbeat: event=PostToolUse              13:06:00   (still that turn)
#     pane-state STILL emitting over-limit      13:02+
#
# The Stop hook did not fire once in that window and was not supposed to: the
# turn had not ended. Independently confirmed by a sibling command in the SAME
# Stop block — monitor/.state/decisions/devred.031312e9c5c4.json, written
# 12:43:52, carries neither `unresolved` nor `resolved`, and
# decision-mark-unresolved.sh stamps one at every turn end. Removing the stamp
# by hand at 13:05 returned `state=busy` on the very next read.
#
# THE RULE. If the heartbeat records activity STRICTLY NEWER than the stamp's
# own `ts`, and that activity is of a kind reachable only AFTER the model
# responded, then this session has served a request since the limit was
# recorded — so the limit has lifted, whatever the stamp says. devred:
# last_activity 1787947560 vs stamp ts 1787946172, newer by 1387 s.
#
# WHY NOT THE CLOCK. `_over_limit_stamp_expired` below compares against a TTL,
# and the row's `reset_at` states 1:40pm. The operator lifted this limit an
# hour early by signing into a different account, so the stamp was false in
# fact while unexpired by every wall-clock measure. A stated reset time is a
# claim about a plan, not an observation of the pane. This rule reads no clock
# at all: it compares two RECORDED epochs, so an early reset is visible to it
# and a late one cannot fool it.
#
# WHY STEP 0 DOES NOT ALREADY COVER THIS. Step 0 asks a different question —
# "is the heartbeat fresh enough to CLASSIFY the pane right now" — and answers
# it with a 30 s window, which is correct for classification and useless here:
# a heartbeat twenty minutes stale but twenty minutes NEWER THAN THE STAMP is
# decisive evidence. Guarding a 27-hour stamp with a 30-second liveness horizon
# is the whole gap. So this check has no freshness requirement, by design.
#
# THE EXCLUSIONS, WHICH ARE THE WHOLE RULE. Both were established by COUNTING
# what these events are on this board, not by reasoning about what their names
# suggest. The second one was missed by exactly that reasoning and caught by a
# skeptic who counted the population.
#
# `UserPromptSubmit` writes the heartbeat with `state=user_prompt`, and pasting
# into a still-frozen pane produces exactly that — a record of the OPERATOR
# acting, never of the model responding. Counting it would invalidate a
# genuinely suspended pane's stamp on the watcher's own wake paste.
#
# `Notification` is NOT admissible on its own, and this is the trap: it sounds
# like it follows a model turn and overwhelmingly does not. Measured on this
# board 2026-08-28 — `monitor/.state/notification-raw-captures.jsonl`, 6791
# payloads: **6766 `idle_prompt`, 25 `permission_prompt`**. `idle_prompt` is
# Claude Code's "Claude is waiting for your input", which fires from IDLENESS
# roughly 60 s after the pane goes quiet. A suspended pane is quiet, so it
# emits one WHILE SUSPENDED. Verified on the very episode this fix was built
# from: `devred`'s stamp `ts=1787946172` (12:42:52) is followed at
# `1787946232` — **+60 s** — by `notification_type=idle_prompt`, and the
# watcher did not observe that pane alive until 12:56:05. All four surviving
# `turn-failure/*.json` stamps (windows that by construction never completed
# another turn) are likewise followed by one `idle_prompt` at +60/+60/+59/+46 s.
#
# Admitting it would have DESTROYED the structured stamp ~60 s into every
# genuine suspension and dropped the hold onto the 1c scrape — the path this
# rule's own coverage boundary disclaims. So `Notification` qualifies ONLY as
# `permission_prompt`: a permission modal presupposes a tool call the model
# emitted.
#
# Qualifying, then, and only these: `PostToolUse` (a tool call the model
# emitted actually ran), `PermissionRequest` (same, one step earlier),
# `Notification` gated on `state=permission_prompt`, and `Stop` (a turn that
# ended SUCCESSFULLY — a rate-limited turn ends in `StopFailure`, which is a
# different event and writes no heartbeat).
#
# `PreToolUse` was in this list and has been REMOVED as structurally dead: no
# hook in this repo writes a heartbeat on it (`worker-settings.json` registers
# `worker-heartbeat.sh` on PostToolUse / Notification / UserPromptSubmit /
# PermissionRequest / Stop only), so the arm could never fire and could never
# be reviewed. An unreachable allow-arm is not defence in depth; it is an
# unfalsifiable claim sitting in an allowlist.
#
# WHOSE PANES THIS COVERS. Workers, via the per-window heartbeat — and, since
# your-org/nexus-code#1155 residual 2, the ORCHESTRATOR, via a different file.
#
# `monitor/orchestrator-settings.json` never invokes `worker-heartbeat.sh` at
# all (its hooks touch marker files and notification-record.sh), so there is no
# `heartbeat/orchestrator.json` — measured: 0 of 1842 heartbeat files carry
# `"window":"orchestrator"`. This rule therefore used to fail closed for the
# orchestrator pane in EVERY case, while that pane IS over-limit stamped
# (`StopFailure -> over-limit-emit.sh` is registered there; three rate_limit
# StopFailures on 2026-08-28 alone). For that key the watcher-side post-resume
# gate was not defence in depth, it was the only cover there is — and it is the
# key whose emit gate produced the incident's 63 held emits in an hour.
#
# THE EVIDENCE THAT EXISTS FOR THAT PANE, and why it is admissible. The
# orchestrator's hooks touch `monitor/.state/orchestrator-heartbeat`, and they
# touch it on EXACTLY TWO events: `PostToolUse` and `Stop`. Both are already in
# the qualifying set above. The two events that would have poisoned it are
# routed to DIFFERENT files by the same settings block — `UserPromptSubmit`
# touches `orchestrator-paste-received`, and `Notification` goes to
# `notification-record.sh` — so the `idle_prompt` finding that shaped the
# allowlist cannot reach this marker at all.
#
# That is a property of the settings file rather than of this rule, so it is
# not assumed: `watcher/test-settings-json.sh` already asserts that the Stop
# hook AND the PostToolUse hook touch `orchestrator-heartbeat`, and
# `watcher/test-over-limit-orchestrator-activity.sh` asserts the complement —
# that no OTHER event does. If someone adds a third toucher on an event that is
# not model activity, that suite reddens, which is what makes an mtime usable
# here at all.
#
# WHY AN MTIME IS ACCEPTABLE WHERE IT NORMALLY IS NOT. An mtime carries no
# event name, so it cannot be filtered after the fact — the filtering has to
# have happened at WRITE time, and here it did, by construction. The comparison
# is otherwise identical to the heartbeat path: one recorded epoch against the
# stamp's own `ts`, strictly newer, no clock and no freshness horizon.
#
# WHAT IT STILL DOES NOT COVER. The marker is touched asynchronously
# (`( … & ) >/dev/null 2>&1`), so its mtime can trail the event by a moment;
# that shifts the comparison in the SAFE direction (a stamp is held very
# slightly longer, never released early). And a board whose orchestrator has
# never completed a tool call or a turn since the state dir was created has no
# marker at all — which fails closed, exactly as a missing heartbeat does.
#
# FAIL CLOSED. No stamp `ts`, no heartbeat, unparseable JSON, or a heartbeat
# with no `event` field (the jq-less writer in worker-heartbeat.sh omits it)
# ⇒ return 1, stamp honoured. Absent evidence of recovery is not evidence of
# recovery; the polarity is deliberately the opposite of the emit gate's,
# because here the cheap error is holding a stamp one cycle too long and the
# expensive one is retiring a live suspension.
#
# Returns 0 when the stamp is contradicted by post-stamp model activity.
_over_limit_stamp_superseded_by_activity() {
    local f="$1" hb="$2" orch_hb="${3:-}" stamp_ts hb_activity hb_event hb_state
    command -v jq >/dev/null 2>&1 || return 1

    stamp_ts=$(jq -r '.ts // empty' "$f" 2>/dev/null) || return 1
    [[ "$stamp_ts" =~ ^[0-9]+$ ]] || return 1

    # ORCHESTRATOR FALLBACK (your-org/nexus-code#1155 residual 2). Reached only
    # when the per-window heartbeat is ABSENT — not merely unusable — AND the
    # caller supplied the marker, which it does for the orchestrator's own pane
    # and no other.
    #
    # ABSENT, AND THE WORD IS LOAD-BEARING (#1171 F3b). This comment said
    # "unusable" while the condition below tested `! -f`, which is a claim the
    # code does not implement — the same defect as R2-B's docstring and the
    # `--orchestrator-window` comment, and the third instance of it in this PR.
    # Narrowed to what the code does rather than broadened to what it said,
    # deliberately: widening the trigger restructures the function that decides
    # whether a pane is suspended, and that is not a change to rush.
    #
    # The residual is bounded and currently unreachable: a heartbeat that EXISTS
    # but is malformed (unparseable, or missing `last_activity`/`event`) makes
    # this arm fail closed even though the marker could have answered. For the
    # orchestrator no such file exists at all — measured, 0 of 1842 heartbeat
    # files carry `"window":"orchestrator"` — so the gap needs someone to start
    # writing a malformed one before it can fire. F3b, carried, not fixed here.
    #
    # The
    # marker's mtime is post-model-response activity by construction; see the
    # header. Its own failures all fall through to the heartbeat path below and
    # thence to `return 1`, so this arm can only ever RELEASE a stamp that
    # recorded activity contradicts, never manufacture one.
    if [[ -n "$orch_hb" ]] && [[ ! -f "$hb" ]]; then
        local orch_mtime=""
        if [[ -f "$orch_hb" ]] && [[ -r "$orch_hb" ]]; then
            orch_mtime=$(stat -c %Y "$orch_hb" 2>/dev/null)                 || orch_mtime=$(stat -f %m "$orch_hb" 2>/dev/null)                 || orch_mtime=""
        fi
        if [[ "$orch_mtime" =~ ^[0-9]+$ ]] && (( orch_mtime > stamp_ts )); then
            return 0
        fi
        return 1
    fi

    [[ -n "$hb" ]] || return 1
    [[ -f "$hb" ]] || return 1
    [[ -r "$hb" ]] || return 1

    hb_activity=$(jq -r '.last_activity // empty' "$hb" 2>/dev/null) || return 1
    [[ "$hb_activity" =~ ^[0-9]+$ ]] || return 1
    (( hb_activity > stamp_ts )) || return 1

    # The event that produced this heartbeat, plus its mapped state — the
    # state alone is not enough (it cannot separate an idle_prompt raised by
    # Notification from one raised by Stop's turn_end token, which map to the
    # same value), and the event alone is not enough either, which is the
    # `Notification` finding above. The pair is what the rule needs.
    hb_event=$(jq -r '.event // empty' "$hb" 2>/dev/null) || return 1
    hb_state=$(jq -r '.state // empty' "$hb" 2>/dev/null) || hb_state=""
    case "$hb_event" in
        PostToolUse|PermissionRequest|Stop) return 0 ;;
        Notification)
            # ONLY the permission variant. See the measured counts above.
            [[ "$hb_state" == "permission_prompt" ]] && return 0
            return 1 ;;
        *) return 1 ;;
    esac
}

# 0. Heartbeat substrate (issue #74). When the per-window heartbeat
#    file is fresh, claude's own hook signal is authoritative — it
#    cuts through renderer ambiguity (paste re-render, mid-spinner,
#    scroll). Stale, missing, malformed, or unmapped state ⇒ fall
#    through to the renderer detection below. We resolve the file
#    path AFTER win_name is known so each window gets its own
#    heartbeat keyed on the tmux window name.
if [[ -z "$hb_file_override" ]]; then
    hb_dir=$(_resolve_heartbeat_dir)
    hb_file="$hb_dir/$win_name.json"
else
    hb_file="$hb_file_override"
fi
hb_now="${now_override:-$(date +%s)}"
hb_staleness="${staleness_override:-$_HEARTBEAT_STALENESS_DEFAULT}"
[[ "$hb_staleness" =~ ^[0-9]+$ ]] || hb_staleness=$_HEARTBEAT_STALENESS_DEFAULT
hb_turn_end_staleness="${turn_end_staleness_override:-$_HEARTBEAT_TURN_END_STALENESS_DEFAULT}"
[[ "$hb_turn_end_staleness" =~ ^[0-9]+$ ]] || hb_turn_end_staleness=$_HEARTBEAT_TURN_END_STALENESS_DEFAULT
hb_async_staleness="${async_staleness_override:-$_HEARTBEAT_ASYNC_STALENESS_DEFAULT}"
[[ "$hb_async_staleness" =~ ^[0-9]+$ ]] || hb_async_staleness=$_HEARTBEAT_ASYNC_STALENESS_DEFAULT
# The external-waits horizon rides the same override flag when one is given —
# a caller that deliberately narrows the async window is entitled to narrow
# this too, and the suites depend on being able to — but its DEFAULT is the
# separate, longer constant rather than 60 s (your-org/nexus-code#1220).
hb_ew_staleness="${async_staleness_override:-$_HEARTBEAT_EXTERNAL_WAITS_STALENESS_DEFAULT}"
[[ "$hb_ew_staleness" =~ ^[0-9]+$ ]] || hb_ew_staleness=$_HEARTBEAT_EXTERNAL_WAITS_STALENESS_DEFAULT

# Wrapper that refines `idle` into the four-way async classifier.
# Other states pass through unchanged. The renderer fallback
# branches further down also need this refinement; centralising
# it here keeps the three call sites aligned. Sets the global
# `refined_state` and `refined_extra` so the caller can pass both
# to `emit` without subshell variable-propagation woes.
refined_state=""
refined_extra=""
_finalize_idle_verdict() {
    local raw="$1"
    refined_extra=""
    if [[ "$raw" != "idle" ]]; then
        refined_state="$raw"
        return 0
    fi
    # Measure the background-shell process subtree ONCE
    # (your-org/nexus-code#455): the count+reliability feed the bg
    # detection (authoritative when reliable) and the cpu feeds the
    # orphan-grace. Test overrides short-circuit the /proc walk:
    #   --bg-shells N  → count=N, reliable=1 (exercise the process-tree
    #                    authoritative path in fixtures).
    #   --bg-cpu N     → legacy cpu-only injection; leaves the tree
    #                    reading UNreliable so the footer/heartbeat drives
    #                    bg (preserves pre-#455 fixture semantics).
    #   --bg-oldest-start EPOCH → inject the oldest background-shell start
    #                    epoch (the DERIVED episode start) for fixtures.
    local pt_count=0 pt_cpu=0 pt_reliable=0 pt_oldest=0 pt_infra=0 pt_stale=0 pt_quiesce=0 pt_members="-" pt_desc="-" pt_lj=0
    # The longjob ledger verdict, read ONCE; and, only when ARMED and the tree
    # is really walked, the dispatcher's root for the census to leave out.
    local lj_v="" lj_root=""
    lj_v=$(_longjob_dispatcher_verdict "$hb_file" "$hb_now")
    if [[ "$lj_v" == armed\ * && -z "$bg_shells_override" && -z "$bg_cpu_override" ]]; then
        lj_root=$(_pane_longjob_root "${pane_pid:-}" "$hb_file")
    fi
    if [[ -n "$bg_shells_override" ]]; then
        pt_count="$bg_shells_override"; pt_reliable=1
        pt_cpu="${bg_cpu_override:-0}"
        pt_oldest="${bg_oldest_start_override:-0}"
        pt_infra="${bg_infra_override:-0}"
        pt_stale="${bg_stale_override:-0}"
        pt_quiesce="${bg_quiesce_override:-0}"
        pt_members="${bg_members_override:--}"
        pt_desc="${bg_cmd_override:--}"
    elif [[ -n "$bg_cpu_override" ]]; then
        pt_cpu="$bg_cpu_override"; pt_reliable=0
        pt_oldest="${bg_oldest_start_override:-0}"
        pt_infra="${bg_infra_override:-0}"
        pt_stale="${bg_stale_override:-0}"
        pt_quiesce="${bg_quiesce_override:-0}"
        pt_members="${bg_members_override:--}"
        pt_desc="${bg_cmd_override:--}"
    else
        read -r pt_count pt_cpu pt_reliable pt_oldest pt_infra pt_stale pt_quiesce pt_members pt_desc \
            < <(_pane_background_shells "${pane_pid:-}" "$lj_root")
    fi
    [[ -n "$pt_members" ]] || pt_members="-"
    # `bg_longjob=1` is the RECORD that a root was excluded from every bg_*
    # field on this line (bundle-2609sk2 F1) — nothing reads it to subtract.
    # `--bg-longjob` injects the record for fixtures: there `--bg-shells N` is
    # the census AFTER the exclusion, as it is live.
    if [[ -n "$bg_longjob_override" ]]; then
        pt_lj="$bg_longjob_override"
    elif [[ -n "$lj_root" ]]; then
        pt_lj=1
    fi
    [[ "$pt_lj" =~ ^[0-9]+$ ]] || pt_lj=0
    local out
    out=$(_refine_idle_with_async_signals \
        "${pane_plain:-}" "$hb_file" "$hb_now" "$hb_async_staleness" \
        "$pt_count" "$pt_reliable" "$pt_stale" "$hb_ew_staleness" "$lj_v")
    # Split on the first TAB. Refinement output is either
    # `<state>` or `<state>\t<extra>`.
    local raw_extra=""
    if [[ "$out" == *$'\t'* ]]; then
        refined_state="${out%%$'\t'*}"
        raw_extra="${out#*$'\t'}"
    else
        refined_state="$out"
    fi
    # A `bg_shell=1` marker (your-org/nexus-code#445) is INTERNAL — it
    # flags a SHELL-driven working-background (grace-capped) vs a
    # Monitor-handle one (self-waking, never aged out). Consume it
    # here; only a genuine emit-extra (`orphan_kinds=…`) propagates.
    local bg_shell=0
    if [[ "$raw_extra" == "bg_shell=1" ]]; then
        bg_shell=1
    elif [[ -n "$raw_extra" ]]; then
        refined_extra="$raw_extra"
    fi
    # Attach the background-shell CPU counter to a SHELL-driven
    # `working-background` verdict so the watcher's idle probe can age
    # out an orphaned (non-computing) background shell. Uses the
    # `--bg-cpu` override when supplied (fixtures/tests), else measures
    # the live pane subtree. NOT emitted for a Monitor-handle
    # working-background: absence of `bg_cpu=` tells the probe to leave
    # that exemption uncapped.
    if [[ "$refined_state" == "working-background" ]] && (( bg_shell == 1 )); then
        [[ "$pt_cpu" =~ ^[0-9]+$ ]] || pt_cpu=0
        [[ "$pt_count" =~ ^[0-9]+$ ]] || pt_count=0
        # Emit the live background-shell COUNT and the reliability of the
        # process-tree walk alongside the CPU counter (your-org/nexus-code#455
        # refine). The watcher's idle probe needs `bg_shells` to key its
        # idle-with-children backoff + the wrap-up-with-children inconsistency
        # detector, and `bg_reliable` to know whether the count is
        # authoritative (process-tree ground truth) or a footer-fallback
        # guess it must not make reap decisions on. On the fallback path
        # (pt_reliable=0) the count is 0/unknown and the probe keeps the
        # legacy #445 flat orphan-grace behaviour.
        #
        # `bg_oldest_start` is the start epoch of the OLDEST background-shell
        # root — the with-children EPISODE start, read straight off the
        # process tree. The probe derives the episode age from it instead of
        # storing a clock, so no child-count churn, no pane rendering (an
        # `autosuggest-only` ghost cycle), and no watcher restart can reset
        # the absolute ceiling (#455 follow-up, round-2 skeptic finding).
        [[ "$pt_oldest" =~ ^[0-9]+$ ]] || pt_oldest=0
        # `bg_infra` / `bg_cmd` (your-org/nexus-code#590): how many of the
        # counted roots are nexus PROTOCOL WAIT loops, and a space-free label
        # naming one representative child. Additive only — `bg_shells` is
        # unchanged, so the `working-background` verdict and the
        # `parked-awaiting-skeptic` exemption keyed off it behave exactly as
        # before; the watcher's idle probe consumes these two to stop calling a
        # protocol-prescribed await loop an "inconsistency", and to NAME the
        # child in the emit instead of reporting a bare count.
        [[ "$pt_infra" =~ ^[0-9]+$ ]] || pt_infra=0
        # `bg_stale` (your-org/nexus-code#1208): how many of the counted roots
        # are waiting on an async-run job the AUTHORITY reports `died`. Additive
        # and reported even when 0, so a consumer can tell "asked, none stale"
        # apart from "never asked" — the same distinction #1208 is about. When
        # bg_stale reaches bg_shells the state is no longer working-background,
        # so THIS branch does not run; the `elif` below then emits a reduced
        # `bg_shells=` + `bg_stale=` pair so the demotion still carries its
        # reason. This comment used to end "and this line is not emitted at
        # all", which was true when written and was left FALSE by F1's own fix
        # twenty lines below — the same defect F1 was about, in F1's repair
        # (your-org/nexus-code#1214 D3).
        [[ "$pt_stale" =~ ^[0-9]+$ ]] || pt_stale=0
        [[ -n "$pt_desc" ]] || pt_desc="-"
        # `bg_cpu_bp` / `bg_wedged` (your-org/nexus-code#1446): a child whose
        # ELAPSED greatly exceeds its CPU time is BLOCKED, not computing — that
        # is exactly what separated three >5h `grep -r … | head` stalls and a
        # 5h36m `until grep -q` waiter (428 jiffies of CPU) from a real compute
        # job, and nothing else in this line does: every one of them read
        # `working-background` throughout. `bg_cpu` is jiffies (100 per CPU
        # second on every Linux this runs on), so jiffies / elapsed_seconds IS
        # the percentage; `bg_cpu_bp` carries it in BASIS POINTS (1% = 100) so
        # the 0.02% instance is a 2 rather than a 0 that reads as "not
        # measured". `bg_wedged=1` when the episode is at least
        # NEXUS_BG_WEDGE_MIN_ELAPSED seconds old (default 600) AND below
        # NEXUS_BG_WEDGE_CPU_BP (default 100, i.e. 1%). Not a kill signal — a
        # slow shared-filesystem walk can look like this too — but a signal
        # the watcher can NAME instead of reporting healthy-with-a-job. Both
        # fields are emitted whenever the episode start is known, so
        # "measured, not wedged" is distinguishable from "not measured".
        local bg_cpu_bp="-" bg_wedged=0 _bg_elapsed=0
        if (( pt_oldest > 0 )) && (( hb_now > pt_oldest )); then
            _bg_elapsed=$(( hb_now - pt_oldest ))
            bg_cpu_bp=$(( pt_cpu * 100 / _bg_elapsed ))
            local _wedge_min="${NEXUS_BG_WEDGE_MIN_ELAPSED:-600}" _wedge_bp="${NEXUS_BG_WEDGE_CPU_BP:-100}"
            [[ "$_wedge_min" =~ ^[0-9]+$ ]] || _wedge_min=600
            [[ "$_wedge_bp" =~ ^[0-9]+$ ]] || _wedge_bp=100
            if (( _bg_elapsed >= _wedge_min )) && (( bg_cpu_bp < _wedge_bp )); then
                bg_wedged=1
            fi
        fi
        # `bg_quiesce` (see the header): APPENDED LAST so no existing reader
        # that matches a contiguous run of the fields above is disturbed.
        [[ "$pt_quiesce" =~ ^[0-9]+$ ]] || pt_quiesce=0
        refined_extra="${refined_extra:+$refined_extra }bg_shells=$pt_count bg_reliable=$pt_reliable bg_cpu=$pt_cpu bg_oldest_start=$pt_oldest bg_infra=$pt_infra bg_stale=$pt_stale bg_cmd=$pt_desc bg_cpu_bp=$bg_cpu_bp bg_wedged=$bg_wedged bg_members=$pt_members bg_quiesce=$pt_quiesce bg_longjob=$pt_lj"
    elif (( pt_reliable == 1 )) && [[ "$pt_stale" =~ ^[0-9]+$ ]] && (( pt_stale > 0 )); then
        # THE VERDICT MUST NOT DESTROY THE EVIDENCE THAT PRODUCED IT
        # (your-org/nexus-code#1214 skeptic F1). The block above rides on the
        # `working-background` branch, so when staleness reaches `bg_shells` the
        # state stops being `working-background` and every `bg_*` field
        # disappears — INCLUDING `bg_stale`, whose whole documented purpose is to
        # keep "asked, none stale" distinguishable from "never asked". The field
        # was therefore absent in precisely the one case this fix exists to
        # change, and the two readings became indistinguishable again exactly
        # where the distinction matters. Measured on the live reproducer: the
        # base classifier printed `bg_cmd=zsh:T=…/async-run`; the fixed one
        # printed a bare `state=idle`, with nothing to say why.
        #
        # So a demotion carries its own reason. Only the two fields that carry
        # it — the population and how much of it was resolved dead — because the
        # rest (`bg_cpu`, `bg_oldest_start`) key the orphan-grace machinery,
        # which is scoped to `working-background` and must NOT be handed a
        # reading for a state it does not govern.
        [[ "$pt_count" =~ ^[0-9]+$ ]] || pt_count=0
        refined_extra="${refined_extra:+$refined_extra }bg_shells=$pt_count bg_stale=$pt_stale"
    fi
}

if [[ -n "$win_name" ]] || [[ -n "$hb_file_override" ]]; then
    if hb_state=$(_classify_from_heartbeat "$hb_file" "$hb_now" "$hb_staleness" "$hb_turn_end_staleness"); then
        # When the heartbeat says `idle`, we still want to refine
        # into working-background / working-self-paced /
        # idle-orphan-async if the async signals warrant it. The
        # refinement reads the same heartbeat file (plus the pane
        # footer when present), so we materialise pane_plain
        # eagerly here on the heartbeat path. Heartbeat-path
        # workers haven't read pane_ansi yet; do a small capture
        # ONLY when refinement applies (when raw verdict is idle).
        if [[ "$hb_state" == "idle" ]]; then
            # Lazy footer capture: only when refinement is needed
            # AND we're not in fixture mode (where pane_ansi was
            # supplied). Cost: one tmux call. Skipped on fixture
            # path because the fixture bytes are already in
            # pane_ansi (set later in the file). We re-use any
            # already-loaded pane_ansi instead.
            if [[ -z "${pane_ansi:-}" ]] && [[ -z "$fixture" ]] \
               && command -v tmux >/dev/null 2>&1; then
                pane_ansi=$(tmux capture-pane -t "$win" -p -e -J -S -25 2>/dev/null) || pane_ansi=
            fi
            if [[ -n "${pane_ansi:-}" ]]; then
                pane_plain=$(printf '%s' "$pane_ansi" | _strip_ansi)
                pane_content_hash=$(_content_hash "$pane_plain")
                # Operator-typing refinement (issue #196). The
                # heartbeat's `idle_prompt` only proves the agent's
                # turn ended — the hook cannot see the operator
                # typing into the input box afterwards, and the
                # Stop-anchored staleness window (default 30 min)
                # means the renderer fallback may not run for the
                # whole stretch, leaving genuine typing invisible
                # to every caller. Check the bright-text marker on
                # the input row and emit `user-typing` instead.
                # Autosuggest ghost text is dim-only and cannot
                # false-trigger; the blocked-overlay case never
                # reaches here (its heartbeat state is
                # `permission_prompt` → blocked).
                hb_input_row=$(_find_input_row "$pane_ansi")
                if [[ -n "$hb_input_row" ]] && _detect_user_typing "$hb_input_row"; then
                    emit user-typing
                    exit 0
                fi
            fi
            _finalize_idle_verdict "$hb_state"
            hb_state="$refined_state"
        fi
        emit "$hb_state" ${refined_extra:+"$refined_extra"}
        exit 0
    fi
fi

if [[ -z "$pane_ansi" ]]; then
    # your-org/nexus-code#788, THE THIRD SITE — and the live one. `pane_ansi` is
    # empty for two unrelated reasons: `tmux capture-pane` FAILED (its rc was
    # discarded here until #788), or the pane genuinely rendered nothing. Neither
    # is evidence about the PROCESS, and this arm sits AFTER the liveness gate
    # has already run — so when the gate found a live `claude` and let the pane
    # through, this line then emitted the kill-authorising state anyway.
    #
    # Measured on a real private-socket tmux server, same pane, same instant,
    # `claude` at the pane root, `pane_dead=0`:
    #     healthy tmux       -> state=idle
    #     capture-pane rc=1  -> state=absent
    # The repo had already noticed the empty-capture half from the other end:
    # `test-integration/test-same-name-recycle.sh:344` documents the ~250 ms
    # post-`new-window` window where "capture-pane briefly returns nothing —
    # pane-state emits `state=absent` then because the renderer signal is empty",
    # and works around it with a `wait_for`.
    #
    # Route it through the one door, which re-derives the process facts instead
    # of inheriting an emptiness that says nothing about them.
    _emit_absent_or_unknown empty-capture
    exit 0
fi

pane_plain=$(printf '%s' "$pane_ansi" | _strip_ansi)
# Transcript-region digest for the change-corroboration signal
# (your-org/your-nexus#205 follow-up). Computed once here so every
# renderer-path emit below carries it.
pane_content_hash=$(_content_hash "$pane_plain")

# 1. Blocked overlay first — its prompt rows contain `❯` too and would
#    otherwise be misclassified as the Claude input row. This MUST
#    run before the over-limit-stamp check (1b) so that when the
#    rate-limit interactive menu is up, the watcher's case-B cascade
#    (`monitor/watcher/_unstick.sh`) still sees `state=blocked` and
#    fires the auto-Enter that dismisses it. The hook-driven
#    over-limit stamp (1b) takes over once the menu is gone.
if _has_blocked_overlay "$pane_plain"; then
    # `overlay=<kind>` names WHICH decision is pending. `blocked` is already
    # correct for all four (a human must answer; the state is in
    # _BK_ACTIVE_STATES, so it is never kill-authorised, and no `_unstick.sh`
    # arm fires on the bypass modal — every arm there requires two
    # co-occurring literals the modal does not carry, so nothing auto-answers
    # a security prompt). The kind is what turns "something is blocked" into a
    # diagnosis. Appended as an extra field, so consumers reading `state=`
    # are unaffected (your-org/nexus-code#768).
    # `auth=login` rides ALONGSIDE `overlay=login`, not instead of it
    # (your-org/nexus-code#1518). They answer different questions and are read
    # by different consumers: `overlay=` names which dialog is up, for the
    # unstick cascade and for the operator; `auth=` is the axis the watcher's
    # emit hold keys on, so the hold never has to enumerate overlay kinds — a
    # new login-flow step whose `overlay=` naming has rotted still carries
    # `auth=login` as long as `_dialog_is_login` recognises one of its three
    # disjuncts, and still reads `state=blocked` even if none of them do.
    #
    # Set here rather than left to `emit`'s lazy derivation, and it OVERRIDES an
    # `expired` reading: a `/login` dialog raised in response to an expiry shows
    # both, and `login` is the one that decides whether to paste. The dialog is
    # the LIVE surface; the expiry is the scrollback reason it is up.
    if [[ "${BLOCKED_OVERLAY_KIND}" == "login" ]]; then
        pane_auth=login
    fi
    emit blocked "overlay=${BLOCKED_OVERLAY_KIND}"
    exit 0
fi

# 1b. Over-limit stamp from the StopFailure hook (issue #129 item 4).
#     `monitor/hooks/over-limit-emit.sh` writes
#     `$STATE_DIR/over-limit/<window>.json` exclusively for
#     error_type=rate_limit events. When present (and the rate-limit
#     menu isn't currently up), the worker is functionally suspended
#     until the weekly Opus reset — emit `state=over-limit` from the
#     structured signal. The renderer scrape at 1c remains as a
#     fallback for inherited panes / forks without
#     `worker-settings.json`. Cleared by the Stop hook on the next
#     successful turn.
if [[ -n "$ol_file" ]] && [[ -f "$ol_file" ]]; then
    if _over_limit_stamp_expired "$ol_file"; then
        # Stale stamp (Stop-clear never fired). Drop it and fall
        # through — the renderer scrape below re-detects a genuine
        # ongoing suspension; a recovered pane classifies normally.
        rm -f "$ol_file" 2>/dev/null || true
    elif _over_limit_stamp_superseded_by_activity "$ol_file" "$hb_file" "$orch_hb_file"; then
        # CONTRADICTED, not expired (your-org/nexus-code#1141). The session has
        # run the model since this stamp was written, so the limit it records
        # has lifted. Deleting is safe and not merely an optimisation: the
        # condition is monotone — no future read can make a stamp older than
        # observed activity true again — so leaving it would re-pose the same
        # question every 60 s for as long as the turn lasts, which is the loop
        # this closes. Fall through; the renderer scrape below still catches a
        # genuine ongoing suspension from the live pane text.
        rm -f "$ol_file" 2>/dev/null || true
    else
        _emit_over_limit_from_stamp "$ol_file"
        exit 0
    fi
fi

# 1c. Over-limit text scrape (issue #87 fallback). The canonical
#     "You've hit your limit · resets <time>" text replaces the
#     input row; detected before the input-row search because the
#     chevron is absent in this state. Now serves as a fallback for
#     panes that didn't fire the StopFailure hook under our watch.
#
#     CONTRADICTED BY LIVE ACTIVITY IN THE SAME CAPTURE
#     (your-org/nexus-code#1155 residual 1). `#1147` taught the STRUCTURED
#     stamp at 1b to yield to post-stamp model activity; this scrape had no
#     `ts` to compare against and so kept classifying a working pane from a
#     stale banner sitting in the bottom rows.
#
#     THE ASYMMETRY THAT WAS THE BUG. This branch emitted and EXITED — while
#     the block ~10 lines below, reached only because this one did not fire,
#     asks TWO questions of the very same `$pane_plain` and treats either as
#     decisive proof the pane is alive: a queued-message placeholder (input
#     pending AND a turn in flight) and an active token counter on the spinner
#     row. Its own comment calls the counter "a strong `claude is alive and
#     generating` marker independent of chevron presence". So the same bytes
#     that read `over-limit` here read `busy` six lines later, and which
#     verdict a live-but-stale-bannered pane got was decided purely by
#     evaluation order.
#
#     NOTHING NEW IS RECOGNISED HERE. Both probes are the file's existing
#     detectors, called on the same text with the same bottom anchor the
#     no-input-row branch uses — deliberately, because inventing a third
#     renderer heuristic to adjudicate the other two is how a classifier
#     acquires a rule nobody can falsify. The fall-through lands in exactly
#     that branch (the banner has replaced the input row, so `_find_input_row`
#     finds none) and it re-asks these questions itself, so the pane is
#     classified by one code path rather than two disagreeing ones.
#
#     THE POLARITY IS DELIBERATE AND IT IS THE CONSERVATIVE ONE. A genuinely
#     suspended pane is QUIET — that is the property `#1147`'s `Notification`
#     analysis already rests on (`idle_prompt` fires FROM IDLENESS ~60 s after
#     a pane goes quiet, which is why a suspended pane emits one). It paints no
#     advancing token counter, because a rate-limited turn is precisely the one
#     that is not generating. So the evidence required to release is evidence a
#     real suspension cannot produce, and absence of it holds the verdict —
#     leaving the expensive error (retiring a live suspension) guarded and the
#     cheap one (holding one cycle longer) as the default.
if _detect_over_limit "$pane_plain"; then
    # Only what was painted BELOW the banner counts — see
    # `_over_limit_after_banner`. Scanning the whole capture reads the dying
    # turn's own spinner as proof of life and releases a real suspension.
    _ol_after=$(_over_limit_after_banner "$pane_plain")
    _ol_after_ln=$(wc -l <<<"$_ol_after")
    if [[ -n "${_ol_after//[[:space:]]/}" ]] \
        && { _detect_queued_message "$_ol_after" \
             || _detect_busy "$_ol_after" "$_ol_after_ln"; }; then
        : # contradicted — fall through to the shared live-pane classifier
    else
        reset_at=$(_extract_over_limit_reset "$pane_plain") || reset_at=unknown
        [[ -n "$reset_at" ]] || reset_at=unknown
        # `limit=` is a FIELD, not a new state token, and that is deliberate:
        # every consumer already treats `over-limit` as never-kill, so a field
        # needs no consumer audit while a brand-new state token can be dropped
        # by a permissive default arm (the `throttled=1` argument, #1340).
        # NOT `local` — this branch is in the script BODY, not a function, and
        # `local` there is an error that surfaces only as a mis-shaped emit.
        ol_flavour=$(_extract_over_limit_flavour "$pane_plain") || ol_flavour=unknown
        [[ -n "$ol_flavour" ]] || ol_flavour=unknown
        emit over-limit "reset_at=$reset_at" "limit=$ol_flavour"
        exit 0
    fi
fi

# 2. Locate the Claude input row (line containing `❯<NBSP>`). Use the
#    plain-text variant for the line-number anchor — busy detection
#    needs to scan only the immediate vicinity.
input_row=$(_find_input_row "$pane_ansi")
if [[ -z "$input_row" ]]; then
    # No input chevron found. Three interpretations, ordered:
    #   (a) Claude TUI is mid-render (issue #47): the chevron was
    #       briefly cleared and not yet re-painted, even though the
    #       pane is alive and busy. The token-counter spinner is a
    #       strong "claude is alive and generating" marker
    #       independent of chevron presence; prefer `busy`.
    #   (b) Claude is alive but rendering a non-spinner intermediate
    #       state (paste re-render, status-bar swap). Emit `empty` —
    #       a transient state the orchestrator should re-poll
    #       rather than treat as a dead process.
    #   (c) No live claude in the pane's process tree: the inner
    #       REPL has truly exited (or this pane never hosted one).
    #       Emit `absent`.
    #   (a0) A QUEUED MESSAGE placeholder has replaced the input row
    #        (your-org/nexus-code#603). This is checked FIRST because it
    #        is the strongest and least ambiguous evidence available:
    #        input pending AND a turn in flight. It is also why the
    #        spinner scan below missed a VISIBLE spinner in the
    #        motivating incident — the placeholder plus the status bar
    #        displaced the spinner out of `_detect_busy`'s 10-row window
    #        anchored on the last line, so a pane 4m38s into a
    #        verification pass read `empty`.
    bottom_ln=$(wc -l <<<"$pane_plain")
    if _detect_queued_message "$pane_plain"; then
        emit busy queued=1
        exit 0
    fi
    if _detect_busy "$pane_plain" "$bottom_ln"; then
        # `throttled=1` follows the `queued=1` precedent exactly (#603/#607):
        # a SUB-CONDITION of busy carried as a FIELD, not as a new state
        # token. See the note at the main decision ladder for why.
        if _detect_throttled "$pane_plain" "$bottom_ln"; then
            emit busy throttled=1
        else
            emit busy
        fi
        exit 0
    fi
    if [[ -n "$pane_pid" ]] && _pane_has_live_claude "$pane_pid"; then
        emit empty
        exit 0
    fi
    # your-org/nexus-code#788, THE SECOND SITE. `emit absent` used to be the
    # DEFAULT here — what you got when `_pane_has_live_claude` could not confirm
    # life, which includes "there was no pid to ask about" and "the tools were
    # blind". `#776`'s bypass-permissions modal lands on this arm. Same door.
    _emit_absent_or_unknown renderer-no-input-row
    exit 0
fi
input_ln=$(grep -nF "❯${NBSP}" <<<"$pane_plain" | tail -1 | cut -d: -f1)
[[ -z "$input_ln" ]] && input_ln=$(wc -l <<<"$pane_plain")

# 3. Inspect input-row contents and busy spinner.
busy=0
has_autosuggest=0
has_bright=0
empty_input=0

_detect_busy "$pane_plain" "$input_ln" && busy=1
_detect_user_typing "$input_row" && has_bright=1
_detect_autosuggest "$input_row" && has_autosuggest=1
_detect_empty_input "$input_row" && empty_input=1

# `input=` — the GHOST-vs-DRAFT answer, stated explicitly
# (your-org/nexus-code#626). The orchestrator's question is not "what
# state is this pane in" but "is that text at the prompt something the
# operator typed, which I must never paste over?". That question had no
# mechanical answer: CLAUDE.md says autosuggest "renders identically to
# user input in plain text", which is true, and the sanctioned tool
# answered `empty` for nineteen ghost panes at once. So it is answered
# here, as its own field, rather than left to be inferred from a state
# token that also carries kill-authorisation meaning.
#
#   typed  bright-white SGR — Claude Code's marker for typed input.
#   ghost  a dim (SGR 2) run: model-generated completion.
#   blank  the empty-box cursor, nothing pending.
#   ?      a non-blank row matching NEITHER marker. Reported honestly
#          rather than guessed: this is the residue #626 describes, and
#          it is where an input-event channel would be needed.
input_kind='?'
if   (( has_bright ));      then input_kind=typed
elif (( has_autosuggest )); then input_kind=ghost
elif (( empty_input ));     then input_kind=blank
fi
input_field="input=$input_kind"

# Vim-mode refinement (your-org/nexus-code#603). `_detect_user_typing`
# keys on the bright-white SGR Claude Code emits for typed text; in vim
# INSERT mode that marker is not reliably present, so real operator
# input rendered as `empty` — twice in one night, on panes that were
# then kill candidates. `-- INSERT --` PLUS a non-blank input row is
# operator input, unconditionally: the indicator only appears when the
# pane is accepting keystrokes into the box, and there is no rendering
# in which a non-blank box under it means anything else.
if (( has_bright == 0 )); then
    if _detect_vim_insert "$pane_plain" && _input_row_typed_text "$input_row"; then
        has_bright=1
        # …and say so on the `input=` axis too. These two answers are read by
        # DIFFERENT consumers — `state=` gates retirement, `input=` gates
        # PASTING — so leaving `input=` at whatever the pre-refinement
        # detectors said publishes `state=user-typing input=blank`: "a human
        # is at this keyboard" and "the box is empty, paste away" in the same
        # line. `blank` and `ghost` both mean safe-to-paste; the refinement
        # has just established the opposite. Narrows a permissive answer,
        # never widens one. Surfaced by the `#801` kill-axis fixture
        # (user-typing-vim-dim-box-border-synthetic), which is the first
        # fixture to exercise vim INSERT + real text + NO bright marker.
        input_kind=typed
        input_field="input=$input_kind"
    fi
fi

# A queued message outranks every renderer reading below: it is direct
# evidence that a turn is running and text is waiting behind it.
# Checked after `has_bright` so a pane that ALSO shows fresh operator
# typing still reports `user-typing` (the input the orchestrator must
# never trample), and before the busy/idle ladder so the queued fact
# cannot be lost to an idle-looking box.
if _detect_queued_message "$pane_plain" && (( has_bright == 0 )); then
    if _detect_throttled "$pane_plain" "$input_ln"; then
        emit busy queued=1 throttled=1
    else
        emit busy queued=1
    fi
    exit 0
fi

# 4. Decide. Order matters — bright user text supersedes everything
#    (orchestrator must never trample real user input). Busy comes
#    next so an autosuggest visible during a long-running step is not
#    mistaken for an idle ready-to-paste pane.
#
# The `idle` branch is refined into working-background /
# working-self-paced / idle-orphan-async / idle by
# `_finalize_idle_verdict` per issue #183. Other branches pass
# through. `extra_fields` carries `orphan_kinds=…` when the refine
# picks idle-orphan-async (only emit-extra populated in this file).
if (( has_bright )); then
    emit user-typing "$input_field"
elif (( busy )); then
    # WHY `busy throttled=1` AND NOT A NEW STATE TOKEN (your-org/nexus-code
    # #1340 asked for one, e.g. `working-throttled`; this is the deliberate
    # deviation, and the requirement the issue actually states — the pane
    # must not read `idle`, and `bk_pane_kill_authorized` must refuse it —
    # is met either way).
    #
    # The argument is already written down twelve lines into
    # `_detect_queued_message`, for the identical shape: every existing
    # consumer already treats `busy` as never-kill and never-paste, so a
    # sub-condition carried as a FIELD needs no consumer audit AND "no
    # permissive default can be inherited by a brand-new state token."
    #
    # That last clause is the whole point, and it is this bundle's own
    # subject. A new token is not free: `_idle_probe.sh` counts idle states
    # through an exact-token allowlist, and CLAUDE.md records that a state
    # nobody enumerated is exactly how a live worker got retired on
    # 2026-06-15. Introducing a token to FIX a kill-authorisation defect,
    # by a mechanism whose documented failure mode is kill-authorisation
    # defects, is the wrong trade when a field carries the same
    # information.
    #
    # `throttled` is nevertheless PRE-REGISTERED in `_bookkeeping.sh`'s
    # `_BK_ACTIVE_STATES`, exactly as `queued` is and for the same stated
    # reason: if a future revision promotes the field to a state, the gate
    # already REFUSES instead of inheriting a permit.
    if _detect_throttled "$pane_plain" "$input_ln"; then
        emit busy "$input_field" throttled=1
    else
        emit busy "$input_field"
    fi
elif (( has_autosuggest )); then
    # An autosuggest ghost is a RENDERING of the input row. It says nothing
    # about whether the process tree has live children, and ghost text renders
    # identically to real input — the very signal that must not be trusted.
    # Refine it exactly as the empty-input branch is refined
    # (your-org/nexus-code#455 follow-up, round-2 skeptic): a worker holding a
    # live background shell is `working-background` whether or not its input
    # row happens to be drawing a ghost that poll. Treating the ghost as
    # evidence of "no children" let a single cosmetic cycle silently reset the
    # watcher's absolute ceiling.
    #
    # Fails CLOSED: `_finalize_idle_verdict` only PROMOTES an idle verdict
    # (idle → working-background / working-self-paced / idle-orphan-async).
    # When the tree cannot be walked it falls back to the footer/heartbeat and,
    # failing those too, leaves the verdict unrefined — so an UNKNOWN child set
    # is never mistaken for an EMPTY one. Only when nothing promotes does the
    # pane read `autosuggest-only`, its original meaning: idle, ready to paste.
    _finalize_idle_verdict idle
    if [[ "$refined_state" == "idle" ]]; then
        emit autosuggest-only "$input_field"
    else
        emit "$refined_state" "$input_field" ${refined_extra:+"$refined_extra"}
    fi
elif (( empty_input )); then
    _finalize_idle_verdict idle
    emit "$refined_state" "$input_field" ${refined_extra:+"$refined_extra"}
else
    emit empty "$input_field"
fi
