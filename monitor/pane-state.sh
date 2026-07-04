#!/usr/bin/env bash
# pane-state.sh — classify a tmux worker pane so the orchestrator can
# tell Claude Code's autosuggest text apart from genuine user input.
#
# Output (single line, key=value, machine-parseable):
#   state=<idle|busy|user-typing|autosuggest-only|empty|blocked|absent|over-limit|
#          working-background|working-self-paced|idle-orphan-async> \
#     active=<0|1> window=<idx> name=<windowname> [reset_at=<token>] [orphan_kinds=<csv>]
#
# `reset_at` is appended only when state=over-limit, and carries the
# extracted reset-time string (spaces collapsed to `_`, parens stripped,
# capped at 40 chars). Value is `unknown` when the canonical "resets
# <time>" suffix wasn't extractable.
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
#   absent           - window exists in tmux but no live `claude`
#                      process in its pane's process tree (the inner
#                      REPL has truly exited; rendered bytes may
#                      linger via tmux's `remain-on-exit on`). A
#                      `state=absent` row always carries a populated
#                      `name=<window>` because a non-existent window
#                      index is treated as a caller error and exits
#                      3 — see Exit codes below (issue #140).
#   blocked          - permission overlay or rate-limit menu present;
#                      mirrors monitor/watcher/_unstick.sh detection.
#   busy             - spinner row shows an active token counter
#                      (`↓ N tokens` / `↑ N tokens`); agent is working.
#   user-typing      - input row carries the bright-text marker
#                      (`\x1b[38;5;231m`); user has typed real input.
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
#   autosuggest-only - input row matches the dim-cursor pattern
#                      (`\x1b[7m.\x1b[0;2m`) with no user-typed prefix;
#                      cosmetic suggestion only — orchestrator should
#                      ignore.
#   idle             - empty input box, no busy spinner; safe to paste.
#   empty            - the renderer is in an ambiguous state (no input
#                      row matches any of the positive regexes) BUT the
#                      pane's process tree still contains a live
#                      `claude`. Common during paste re-render and
#                      state-swap transitions. Callers should treat
#                      `empty` as "don't know yet, try again next
#                      cycle" — NOT as "claude is gone".
#   over-limit       - the canonical "You've hit your limit · resets
#                      <time>" notice is rendered at the bottom of the
#                      pane; claude is functionally suspended until the
#                      weekly Opus limit resets. Orchestrator should
#                      schedule a resume rather than treat the worker
#                      as idle. Anchored to the bottom ~15 rows so a
#                      transcript mention of the same phrase doesn't
#                      false-trigger.
#
# Async-signal refinement (issue #183): the four classifications
# below are NOT new top-level branches — they refine the existing
# `idle` verdict. The path: if the renderer (or heartbeat) would
# have emitted `idle`, we look at three async signals and pick the
# more specific class. The signals, in priority order:
#
#   1. monitor_handles > 0 OR background_bash_count > 0
#      → `working-background` (worker has an in-flight async tool
#      handle in claude's own process; they'll be woken when it
#      completes).
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
# Signal sources, in fallback order:
#   - Heartbeat fields (`monitor_handles`, `background_bash_count`,
#     `scheduled_wakeup_at`, `external_waits`) when the heartbeat is
#     fresh. Authoritative.
#   - Pane-footer parse (`N monitor[s] still running`,
#     `N background bash …`) for monitor_handles /
#     background_bash_count when the heartbeat is stale or missing.
#     The footer reflects claude's most-recent tool-call state so
#     it's a load-bearing fallback.
#   - `external_waits` has NO renderer fallback. A worker that
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
#   3  requested tmux window index does not exist (issue #140 — a
#      bogus index used to return `state=absent name=` and exit 0,
#      which masked an orchestrator-side index-typo bug). Distinct
#      from exit 2 so callers can tell "argv shape was wrong" from
#      "argv shape was fine but the index isn't a live window".
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

usage() {
    cat <<'EOF' >&2
usage: pane-state.sh <window-index|session:window>
       pane-state.sh --all [<session>]
       pane-state.sh --fixture <path> [--window <idx>] [--name <s>] [--active 0|1]
                     [--heartbeat-file <path>] [--now <epoch>]
                     [--heartbeat-staleness <seconds>]
                     [--heartbeat-turn-end-staleness <seconds>]
                     [--heartbeat-async-staleness <seconds>]
                     [--over-limit-file <path>]
                     [--pane-pid <pid>]
EOF
    exit 2
}

# ---- arg parsing ----------------------------------------------------------
fixture=
fix_window=0
fix_name=fixture
fix_active=0
all_session=
target=
hb_file_override=
now_override=
staleness_override=
turn_end_staleness_override=
async_staleness_override=
over_limit_file_override=
pane_pid_override=
while (( $# > 0 )); do
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
        --pane-pid)                    pane_pid_override="$2"; shift 2;;
        --all)
            shift
            if (( $# > 0 )) && [[ "$1" != -* ]]; then
                all_session="$1"; shift
            else
                all_session=0
            fi
            ;;
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
    # Strip CSI escape sequences for plain-text greps.
    sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g'
}

_has_blocked_overlay() {
    local plain="$1"
    if grep -qE 'What do you want to do\?' <<<"$plain" \
       && grep -qE 'Stop and wait for limit' <<<"$plain"; then
        return 0
    fi
    if grep -qE 'Do you want to proceed\?' <<<"$plain" \
       && grep -qE $'❯[[:space:]]+[0-9]+\\.' <<<"$plain"; then
        return 0
    fi
    if _has_askuq_overlay "$plain"; then
        return 0
    fi
    return 1
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
# canonical text Claude Code renders in place of the input box is:
#
#     You've hit your limit · resets 3am (America/Los_Angeles)
#     /extra-usage to finish what you're working on.
#
# Detection requires BOTH the "You've hit your limit" substring AND a
# "resets <time>" companion within those 15 rows. The position anchor
# is load-bearing: a transcript scrollback that paraphrases or quotes
# the notice elsewhere in the pane would otherwise false-trigger
# (issue #87 edge case). The companion-line requirement defends
# against a half-rendered notice (e.g. only the headline visible
# mid-redraw) and matches the canonical two-line shape.
_detect_over_limit() {
    local plain="$1" bottom
    bottom=$(tail -n 15 <<<"$plain")
    grep -qF "You've hit your limit" <<<"$bottom" || return 1
    grep -qE 'resets[[:space:]]+[^[:space:]]' <<<"$bottom" || return 1
    return 0
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
    bottom=$(tail -n 15 <<<"$plain")
    # Grab the entire suffix on the "resets " line. tr removes parens,
    # then a single trailing-punctuation strip, then squeeze ws to `_`.
    raw=$(grep -oE 'resets[[:space:]]+[^[:cntrl:]]+' <<<"$bottom" \
              | head -1 \
              | sed -E 's/^resets[[:space:]]+//; s/[[:space:]]+$//')
    [[ -n "$raw" ]] || return 1
    raw=$(printf '%s' "$raw" | tr -d '()' | tr -s '[:space:]' '_' | sed 's/_*$//')
    raw="${raw:0:40}"
    [[ -n "$raw" ]] || return 1
    printf '%s' "$raw"
}

# Stable digest of the pane's TRANSCRIPT region — every line strictly
# ABOVE the last `❯<NBSP>` input row — emitted as `content_hash=` so
# the watcher can tell a changing pane from a static one across cycles
# (your-org/your-nexus#205 follow-up: self-expiring, change-corroborated
# operator-engaged mark). Two regions are deliberately excluded /
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
    printf '%s' "$region" \
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
    # Dim-cursor signature on the input row: reverse-video first char of
    # the suggestion, immediately followed by faint/dim on the rest.
    local input_row="$1"
    grep -qP $'\x1b\\[7m.\x1b\\[0;2m' <<<"$input_row"
}

_detect_user_typing() {
    # Bright-white marker that Claude Code emits for user-typed text.
    # See note at top about future renderer changes.
    local input_row="$1"
    grep -qP $'\x1b\\[38;5;231m' <<<"$input_row"
}

_detect_busy() {
    # Active token counter (`↓ 15.2k tokens`, `↑ 480 tokens`) on the
    # spinner row indicates the agent is mid-step. The idle banner
    # uses a past-tense form (`✻ Brewed for 34m 45s`) with no token
    # counter, so absence of this counter = idle.
    #
    # Constraint: scan only the 10 lines immediately preceding the
    # input row. The captured scrollback often holds older
    # `Cogitating… ↓ 5.7k tokens` lines from past steps that have
    # since finished — they would false-trigger if we scanned the
    # whole pane.
    local plain="$1" input_ln="$2"
    local start=$(( input_ln - 10 ))
    (( start < 1 )) && start=1
    local window
    window=$(awk -v s="$start" -v e="$input_ln" 'NR>=s && NR<=e' <<<"$plain")
    grep -qE '[↓↑] +[0-9]+(\.[0-9]+)?[kKmM]? +tokens' <<<"$window"
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
    grep -qP $'\x1b\\[7m $' <<<"$input_row"
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
_pane_has_live_claude() {
    local pane_pid="$1"
    [[ "$pane_pid" =~ ^[0-9]+$ ]] || return 1
    command -v pgrep >/dev/null 2>&1 || return 1
    local depth queue next pid
    queue="$pane_pid"
    for depth in 0 1 2 3 4 5; do
        [[ -n "$queue" ]] || return 1
        # If any pid in this layer IS itself a claude, we're done —
        # unless it's a zombie. A zombie claude has EXITED (only the
        # unreaped table entry lingers, e.g. while tmux is slow to
        # collect a remain-on-exit pane's child); counting it as live
        # would hold the pane out of `absent` for as long as the reap
        # is delayed, exactly the stale-bytes failure this gate exists
        # to prevent.
        for pid in $queue; do
            local comm pstate
            comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')
            case "$comm" in
                claude|claude-code)
                    pstate=$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')
                    [[ "$pstate" == Z* ]] || return 0
                    ;;
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
# heartbeat's `monitor_handles` / `background_bash_count` /
# `scheduled_wakeup_at` / `external_waits` fields are trusted for
# the idle-refinement path (issue #183). Independent of the
# top-level state-classification staleness so the heartbeat can
# remain authoritative for refinement even when the renderer takes
# over for state. Default 60 s — generous enough to bridge a slow
# tool call between PostToolUse fires; short enough that a wedged
# worker doesn't keep its async signals indefinitely.
_HEARTBEAT_ASYNC_STALENESS_DEFAULT=60

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
# These extract the four async signals (monitor_handles,
# background_bash_count, scheduled_wakeup_at, external_waits) used
# to refine the `idle` verdict into one of:
#   working-background / working-self-paced / idle-orphan-async / idle.
#
# Conventions:
#   - Each helper writes a single key=value to stdout, or exits
#     non-zero / empty stdout when it has nothing to say.
#   - The signals come from two sources: the heartbeat JSON (when
#     fresh enough) and the pane-ANSI capture (footer parsing).
#     Heartbeat is authoritative when both have a value; footer
#     fills in only when heartbeat is missing the field.

# Read `monitor_handles` and `background_bash_count` directly from
# the heartbeat JSON. Returns space-separated `<monitor> <bg>` on
# stdout; missing / corrupt / stale heartbeat ⇒ "0 0".
_heartbeat_handle_counts() {
    local hb_file="$1" now="$2" staleness="$3"
    local result="0 0"
    [[ -n "$hb_file" ]] || { printf '%s' "$result"; return; }
    [[ -f "$hb_file" ]] || { printf '%s' "$result"; return; }
    [[ -r "$hb_file" ]] || { printf '%s' "$result"; return; }
    command -v jq >/dev/null 2>&1 || { printf '%s' "$result"; return; }

    local last_activity mon bg
    last_activity=$(jq -r '.last_activity // empty' "$hb_file" 2>/dev/null) || last_activity=""
    [[ "$last_activity" =~ ^[0-9]+$ ]] || { printf '%s' "$result"; return; }
    local age=$(( now - last_activity ))
    (( age >= 0 )) || age=0
    (( age <= staleness )) || { printf '%s' "$result"; return; }

    mon=$(jq -r '.monitor_handles // 0' "$hb_file" 2>/dev/null) || mon=0
    bg=$(jq -r '.background_bash_count // 0' "$hb_file" 2>/dev/null) || bg=0
    [[ "$mon" =~ ^[0-9]+$ ]] || mon=0
    [[ "$bg" =~ ^[0-9]+$ ]] || bg=0
    printf '%d %d' "$mon" "$bg"
}

# Pane-footer parse. Claude Code surfaces async-handle counts in
# two places: the spinner row above the input (`✻ Cooked for 4s ·
# 1 monitor still running`) and the status line below the input
# (`-- INSERT -- ⏵⏵ bypass permissions on · 1 monitor · ← for
# agents`). The spinner row carries the canonical phrasing
# `N monitor[s] still running` / `N background bash[es] [still ]running`;
# the status line carries a shorter form that only renders when
# the count is non-zero.
#
# Strategy: scan the bottom 15 rows (the spinner sits ~3 rows
# above the input chevron in the standard 7-row claude TUI; bigger
# margin protects against extra status-bar rows) for the canonical
# "still running" phrase. We anchor on "still running" because it's
# unique to the spinner row and never appears in unrelated text.
# False-positive risk: a transcript paragraph that quotes the
# phrase verbatim would false-trigger — empirically never seen.
#
# When the spinner phrase isn't present (e.g. mid-render, post-
# Monitor close), we fall back to the status-line shape `· N
# monitor[s]? ·` / `· N background bash[es]? ·` — both have a
# middle-dot anchor that excludes the spinner row (which uses a
# different separator and the "still running" suffix).
_footer_handle_counts() {
    local plain="$1"
    local bottom mon=0 bg=0
    bottom=$(tail -n 15 <<<"$plain")
    if [[ "$bottom" =~ ([0-9]+)[[:space:]]+monitor[s]?[[:space:]]+still[[:space:]]+running ]]; then
        mon="${BASH_REMATCH[1]}"
    elif [[ "$bottom" =~ ·[[:space:]]+([0-9]+)[[:space:]]+monitor[s]?[[:space:]]+· ]]; then
        mon="${BASH_REMATCH[1]}"
    fi
    if [[ "$bottom" =~ ([0-9]+)[[:space:]]+background[[:space:]]+(bash|process|bashes|processes)[[:space:]]+(still[[:space:]]+)?running ]]; then
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
# the heartbeat is stale — i.e. there's no orphan-async signal.
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
# Caller passes the pane-plain bytes (for footer parsing) and the
# heartbeat path; either may be empty.
_refine_idle_with_async_signals() {
    local pane_plain="$1" hb_file="$2" now="$3" async_staleness="$4"

    local hb_mon=0 hb_bg=0
    if [[ -n "$hb_file" ]] && [[ -f "$hb_file" ]]; then
        read -r hb_mon hb_bg < <(_heartbeat_handle_counts \
            "$hb_file" "$now" "$async_staleness")
    fi
    local foot_mon=0 foot_bg=0
    if [[ -n "$pane_plain" ]]; then
        read -r foot_mon foot_bg < <(_footer_handle_counts "$pane_plain")
    fi
    # Heartbeat takes precedence when it reports a positive count;
    # else fall back to footer. A heartbeat that reports 0 is a
    # "no signal" not "definitely zero" — it's normal for the hook
    # to leave the field 0 because it can't introspect claude's
    # internal handle list. So we OR the two sources.
    local mon=$(( hb_mon > foot_mon ? hb_mon : foot_mon ))
    local bg=$(( hb_bg > foot_bg ? hb_bg : foot_bg ))

    if (( mon > 0 )) || (( bg > 0 )); then
        printf 'working-background'
        return 0
    fi

    if _heartbeat_scheduled_wakeup_at "$hb_file" "$now" "$async_staleness" >/dev/null; then
        printf 'working-self-paced'
        return 0
    fi

    local waits_summary
    if waits_summary=$(_heartbeat_external_waits_summary "$hb_file" "$now" "$async_staleness"); then
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
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        win="0:$target"
        win_index="$target"
    elif [[ "$target" =~ ^[^:]+:[0-9]+$ ]]; then
        win="$target"
        win_index="${target##*:}"
    else
        usage
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        echo "state=absent active=0 window=${win_index} name="
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
    # -J joins wrapped lines so a multi-line autosuggest renders on one
    # logical row, matching the regexes below.
    pane_ansi=$(tmux capture-pane -t "$win" -p -e -J -S -25 2>/dev/null) || pane_ansi=
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
    [[ -n "$pane_content_hash" ]] && extra+=" content_hash=$pane_content_hash"
    printf 'state=%s active=%s window=%s name=%s%s\n' \
        "$state" "$win_active" "$win_index" "$win_name" "$extra"
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
    emit absent
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

_emit_over_limit_from_stamp() {
    local f="$1" reset_at=unknown v
    if command -v jq >/dev/null 2>&1; then
        v=$(jq -r '.reset_at // empty' "$f" 2>/dev/null)
        if [[ -n "$v" ]] && [[ "$v" != "null" ]]; then
            # Mirror the renderer's reset_at normalisation: strip
            # parens, collapse whitespace to `_`, cap at 40 chars.
            v=$(printf '%s' "$v" | tr -d '()' | tr -s '[:space:]' '_' | sed 's/_*$//')
            v="${v:0:40}"
            [[ -n "$v" ]] && reset_at="$v"
        fi
    fi
    emit over-limit "reset_at=$reset_at"
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
    local out
    out=$(_refine_idle_with_async_signals \
        "${pane_plain:-}" "$hb_file" "$hb_now" "$hb_async_staleness")
    # Split on the first TAB. Refinement output is either
    # `<state>` or `<state>\t<extra>`.
    if [[ "$out" == *$'\t'* ]]; then
        refined_state="${out%%$'\t'*}"
        refined_extra="${out#*$'\t'}"
    else
        refined_state="$out"
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
    emit absent
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
    emit blocked
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
    _emit_over_limit_from_stamp "$ol_file"
    exit 0
fi

# 1c. Over-limit text scrape (issue #87 fallback). The canonical
#     "You've hit your limit · resets <time>" text replaces the
#     input row; detected before the input-row search because the
#     chevron is absent in this state. Now serves as a fallback for
#     panes that didn't fire the StopFailure hook under our watch.
if _detect_over_limit "$pane_plain"; then
    reset_at=$(_extract_over_limit_reset "$pane_plain") || reset_at=unknown
    [[ -n "$reset_at" ]] || reset_at=unknown
    emit over-limit "reset_at=$reset_at"
    exit 0
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
    bottom_ln=$(wc -l <<<"$pane_plain")
    if _detect_busy "$pane_plain" "$bottom_ln"; then
        emit busy
        exit 0
    fi
    if [[ -n "$pane_pid" ]] && _pane_has_live_claude "$pane_pid"; then
        emit empty
        exit 0
    fi
    emit absent
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
    emit user-typing
elif (( busy )); then
    emit busy
elif (( has_autosuggest )); then
    emit autosuggest-only
elif (( empty_input )); then
    _finalize_idle_verdict idle
    emit "$refined_state" ${refined_extra:+"$refined_extra"}
else
    emit empty
fi
