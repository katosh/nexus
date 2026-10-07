#!/usr/bin/env bash
# Auto-unstick helpers for the nexus watcher.
#
# Loaded by monitor/watcher/main.sh and by monitor/watcher/test-unstick.sh.
# Side-effect-free: only function definitions, no top-level state. The
# caller is responsible for setting these globals before any function
# is invoked:
#
#   AUTO_UNSTICK              "true" / "false" — feature flag
#   UNSTICK_DIR               directory for per-window fingerprint +
#                             retry counters + pre-action pane captures
#                             (audit trail) + cascade-state files
#   UNSTICK_LOG               append-only log of detections / actions /
#                             backoffs / cascades
#   WATCHER_WINDOW            tmux window hosting the watcher (skipped
#                             from scan so we never auto-Enter our own
#                             pane)
#   TARGET                    orchestrator tmux window name (case-B
#                             heads-up paste target). When unset,
#                             defaults to "orchestrator".
#   ACTION_LOG                path to monitor/.state/action-log.jsonl
#                             (used by case B to verify the orchestrator
#                             received the heads-up). Optional — when
#                             unset, the ack check is skipped.
#   RATELIMIT_PROBE           "true" / "false" — whether to call the
#                             Anthropic API to discover the rate-limit
#                             reset time. Default false. Requires
#                             ANTHROPIC_API_KEY.
#   ANTHROPIC_API_KEY         Anthropic API key for the probe. Pulled
#                             from environment only — never read from
#                             config. When empty the probe no-ops.
#   PROBE_MODEL               Model id for the probe. Resolved ONCE by
#                             _config.sh (monitor.watcher.probe_model)
#                             and exported by main.sh — this module
#                             holds no default of its own, so there is
#                             exactly one place the value comes from
#                             (your-org/nexus-code#568 D13). Empty ⇒ the
#                             probe no-ops rather than guessing an id.
#   RATELIMIT_HEURISTIC_MIN   Minutes-from-now to set as the synthetic
#                             reset-epoch when the probe is disabled or
#                             fails. Default 30.
#   RATELIMIT_ACK_TIMEOUT_S   Seconds to wait for an
#                             `ratelimit-resume-ack` action-log line
#                             from the orchestrator after a cascade
#                             before declaring it unresponsive.
#                             Default 60.
#   ON_DIALOG                 Case-D action mode (auto-dismiss / skip
#                             / error). Default `auto-dismiss`. Set
#                             from `monitor.watcher.on_dialog` in the
#                             watcher's caller. See the Case D
#                             narrative below.
#
# The scenarios this defends against (C is a retired letter):
#
#   A) Permission prompt during normal run — DETECTED, NEVER ANSWERED
#      (your-org/nexus-code#1599).
#      Even with `--dangerously-skip-permissions`, Claude Code still
#      prompts on the command shapes the binary refuses to bypass:
#
#         Dangerous rm operation on possibly-empty variable path: "$M/$tag-work"
#
#         Do you want to proceed?
#         ❯ 1. Yes
#           2. No
#
#      This case USED to press Enter, i.e. answer whatever option the
#      binary highlighted — "Yes" — on the theory that the operator had
#      already opted into the bypass. That theory inverts the population:
#      in bypass mode the ordinary prompts never render, so what reaches
#      a worker pane is exactly the class a human was meant to answer.
#      It confirmed "Dangerous rm operation on possibly-empty variable
#      path" in window `rtev` on 2026-09-19.
#
#      THE ALLOWLIST IS EMPTY, AND THAT IS A RULING FROM EVIDENCE, not a
#      placeholder. Every pre-action audit this case ever wrote was read
#      (61 captures under .state/unstick/*.permission.*.audit, 2026-04-28
#      .. 2026-09-22, Claude Code up to 2.1.273; audit mtime = first
#      sighting). 42 of 61 carry a danger marker, and 35 of 35 dated
#      after 2026-06-08 do. The populations:
#        - DANGER-MARKED: the
#          `Dangerous rm|rmdir operation on …` family (possibly-empty
#          variable path / critical path / working directory or its
#          ancestor / statically-unresolvable target), `This command
#          requires approval`, `… which is a sensitive file`.
#        - 2 were not prompts at all: an operator window QUOTING the
#          prompt text while discussing this case — and it got an Enter.
#        - 17 UNMARKED "Bash command" prompts (2026-04-28..06-08): the approval
#          grants the arbitrary command rendered above it — lockfile
#          writes under ~/.claude, but also a credential written to disk.
#          Nothing in the prompt text lets the watcher judge the COMMAND
#          safe, and a pattern over command text is exactly the glob arm
#          #1121 warns about.
#      No benign prompt could be positively identified, so nothing is
#      answered. `_unstick_permission_verdict` still classifies (the
#      verdict names WHY in the log and the decision row), and it is
#      DENY-FIRST: if an allow arm is ever added it must come after the
#      danger arm, never before it (#1121).
#
#      Action: NO KEY. The pre-action capture is kept as the audit, one
#      `case=A action=refused` line is logged per prompt instance, and a
#      pending-decision record (`kind: permission_prompt`, the issue-129
#      channel Case W also writes) surfaces it as an operator decision.
#      The existing Stop hook resolves that record for hooked workers
#      the moment the modal is gone; a hookless pane's record waits for
#      the ack, like Case W's.
#
#   B) Rate-limit prompt (Claude.ai usage limit hit).
#      Claude Code's rate-limit menu has the title "What do you want
#      to do?" with one of the option lines reading "Stop and wait
#      for limit to reset". We treat case B as a session-wide event:
#
#        1. Probe the Anthropic API (or fall back to a heuristic
#           timer) to learn when the rate limit resets.
#        2. Wait. Per-window detection lines log only on first sight.
#           A RESET EVENT ends the wait at once (your-org/nexus-code#1739):
#           a re-login / account switch, or an over-limit pane seen busy
#           again. See "RESET EVENTS" above `_ratelimit_episode_over`.
#        3. Once the reset epoch passes, cascade an unstick across
#           every stuck window EXCEPT the watcher and the
#           orchestrator (TARGET): Enter to dismiss the menu, then
#           paste-buffer "Please continue with your task. The API
#           rate limit has reset. Re-check …" + Enter — but only after a
#           re-read shows the menu LEFT, and never into a window whose
#           input row holds a typed draft (#1739).
#           THAT DISMISS ENTER IS AN EQUALITY (your-org/nexus-code#1598):
#           it is pressed only when a capture taken at that moment, on
#           the exact target, reads a LIVE menu whose HIGHLIGHTED row is
#           the Stop option. Detection itself requires a LIVE menu, so a
#           pane that merely quotes the literals is not case B. See
#           `_unstick_ratelimit_menu_verdict` for the measurement, the
#           bundle citation and the stated fidelity limit. An ELAPSED
#           reset epoch with nobody stuck is closed as a finished
#           episode, so it cannot make the next one fire instantly.
#        4. Inform the orchestrator with a heads-up paste containing
#           the count of windows we just unstuck and a one-liner
#           prompting `monitor/ng log-action ... --event
#           ratelimit-resume-ack`. The watcher polls the action-log
#           on subsequent cycles to confirm the orchestrator is
#           alive; if no ack lands within RATELIMIT_ACK_TIMEOUT_S the
#           watcher logs `orchestrator-unresponsive` so the operator
#           can intervene. The heads-up presses NO blind pre-Enter, and
#           is DEFERRED (parked in `ratelimit.headsup.pending`, retried
#           each cycle) while the orchestrator's box already holds typed
#           text or its menu's default is not the Stop option (#1598).
#
# Asymmetry: case A never sends a key — it surfaces the prompt as a
# pending decision (#1599). Case B fans out across every stuck window then sends a separate
# heads-up to the orchestrator; the watcher already captures every
# pane each cycle, so making it the cascade actor is cheaper and more
# direct than asking the orchestrator to tmux-walk its siblings.
#
#   C) RETIRED (your-org/nexus-code#1670). This letter used to be an
#      API-error arm: on a `API Error: {"type":"error"…"Internal server
#      error"` chip it pressed ONE bare Enter, on the premise that Enter
#      on the idle prompt retries the failed turn. Both halves had gone
#      false. The literals match no current render: 2.1.280–2.1.284
#      print a 500 as
#         ● API Error: 500 Internal server error. This is a server-side issue, usually temporary — try again in a moment.
#      And the remedy is inert: measured on 2.1.284 against the
#      cc-harness mock (500/api_error, then flipped to success), one
#      bare Enter on that empty prompt sent NO request (mock requests
#      1 -> 1, reproduced twice), while typing `continue` + Enter did
#      (1 -> 2, reply rendered). Re-keying would have restored a no-op
#      keystroke — and, with no `input=` check, one that SUBMITS an
#      operator draft sitting in the box. API-error recovery is owned by
#      the StopFailure path: `hooks/turn-failure-emit.sh` writes a typed
#      `turn-failure/<window>.json` marker, `_idle_probe.sh` surfaces the
#      window as `interrupted <category>:<recovery>`, and the
#      ORCHESTRATOR decides the resume. The letter is not reused, so
#      `case=C` in an old `watcher-unstick.log` stays unambiguous.
#
#   D) AskUserQuestion chip-bar dialog (dialog-guard).
#      The orchestrator is paste-driven; any blocking modal that
#      intercepts the watcher's paste-buffer push either corrupts
#      dialog state, or stalls the channel (it once also fed Case A's
#      auto-Enter into selecting option 1; Case A sends no key since
#      your-org/nexus-code#1599). The
#      operator's verbatim constraint: "we cannot risk the orchestrator
#      not being receptive for watcher prompt injections."
#
#      SCOPE — orchestrator window ONLY for the dismiss-and-paste
#      action. The severed-paste-channel hazard is specific to the
#      single paste-driven window (TARGET, default `orchestrator`).
#      Other session-0 windows must never be force-dismissed:
#        - operator-owned interactive windows (the operator may be
#          hand-driving Claude and legitimately answering a dialog —
#          force-dismissing destroys their work), and
#        - worker panes, whose in-process sub-agent ("dynamic
#          workflow") chains can legitimately raise AskUserQuestion;
#          force-dismissing corrupts worker output.
#      The dismiss-and-paste also carries orchestrator-specific wording
#      ("Nexus orchestrators must never call AskUserQuestion…") that is
#      nonsensical in a worker or operator pane. The same detection on
#      a NON-target window therefore routes to Case W below (the
#      blocked-question relay), which never sends keys to the pane.
#      (An AskUQ overlay on a non-orchestrator window also cannot trip
#      Case A: Case A requires the `Do you want to proceed?` permission
#      text, which AskUQ overlays never carry.)
#
#      Layer A1 of the safety net (the `PreToolUse` matcher in
#      `monitor/orchestrator-settings.json`) blocks the orchestrator
#      from ever dispatching `AskUserQuestion`. Case D here is Layer
#      B — the watcher safety net for orchestrator sessions whose
#      settings file is missing, corrupt, or older than the hook
#      landing, and for any future modal whose rendered shape carries
#      the same chip-bar signature. The detection signature combines a
#      shape gate with a live-ness gate. Shape: the chip-bar's two
#      final options (`Type something.` penultimate + `Chat about this`
#      final). Live-ness: the navigation footer (`Esc to cancel`,
#      rendered as `Enter to select · ↑/↓ to navigate · Esc to cancel`)
#      must appear at the BOTTOM of the pane — within the last few
#      non-blank lines, where a live overlay always renders it. The
#      option literals alone are insufficient: a single line of prose
#      enumerating them (a worker summarising the Claude-Code
#      TUI-state-detection surface, say) satisfied both and false-
#      positived the guard in the field, and even a full overlay block
#      quoted into the orchestrator's scrollback is not a live block.
#      Bottom-anchoring the footer is what discriminates a genuinely-
#      blocking overlay from any pane that merely displays the literals:
#      quoted text and the normal REPL chrome (input box + `◉ model`
#      status line) push the footer above the bottom slice. Validated
#      against the field captures: the one true positive had the footer
#      as its last line; every false positive had REPL chrome or a
#      different (workflow) footer at the bottom.
#
#      Action: capture pane (audit), send Escape (cancels the menu —
#      Claude Code's documented behaviour for modal overlays; the
#      `paste_to_target` mode-force in `main.sh` rejected Escape only
#      for its side-effect of cancelling MID-GENERATION, which by
#      construction can't apply here because the dialog itself is
#      already blocking generation), wait 0.5 s, then paste a meta-
#      message into the now-clean input box explaining what happened
#      and pointing at `monitor/agent-prompt.md`. The meta-message is
#      the next thing the orchestrator sees — so the dismissal also
#      restores the watcher's communication channel in the same
#      action.
#
#      Behaviour is tunable via `ON_DIALOG` (set from
#      `monitor.watcher.on_dialog`, default `auto-dismiss`):
#        - `auto-dismiss` — the action above (recommended).
#        - `skip`         — log detection only; the dialog is left
#                           in place. Useful for debugging the
#                           detection regex without acting.
#        - `error`        — log a WARN line; otherwise the same as
#                           `skip`. Surfaces the wedge in unstick
#                           logs without auto-dismissing.
#      Ordering: Case D is matched AFTER Case A in
#      `_handle_unstick_window`. It used to be the other way round,
#      because Case A pressed Enter and its `❯ N.` chevron pattern
#      would have auto-Entered option 1 of an AskUQ overlay. Since
#      #1599 Case A sends no key, and a LIVE permission prompt renders
#      `Esc to cancel · Tab to amend` as its bottom row, which passes
#      D's live-ness gate — so D-first sent Escape + a paste into a
#      live permission prompt whenever the chip-bar literals were
#      quoted above it (skeptic pass on #1626). See the ordering block
#      in `_handle_unstick_window` for the rule and its stated cost.
#
#   W) Worker-blocked-question relay (your-org/your-nexus#180).
#      The same AskUQ detection (shape + bottom-anchored live-ness
#      gate, see Case D) firing on a NON-target window means a worker
#      or operator-interactive pane is blocked on a question nobody
#      may be watching. The operator's mandate: "since I cannot
#      always answer questions like you just asked me, the watcher
#      should have detected and resolved this by having the
#      orchestrator answer."
#
#      Action: NO keys are ever sent to the pane. Instead the relay
#      synthesizes a pending-decision record (the issue-129 channel —
#      `monitor/.state/decisions/<window>.<fp>.json`, kind
#      `blocked_question`) carrying the parsed question, the option
#      list, and the captured pane tail. `render_pending_decisions`
#      surfaces it in the next emit exactly like a hook-written
#      decision; the orchestrator answers on the operator's behalf
#      (Escape + paste a textual answer — see monitor/agent-prompt.md)
#      and acks by removing the record. This deliberately covers
#      HOOKLESS panes (operator-launched interactive windows have no
#      per-spawn Notification hook, so the decisions channel never
#      fires for them — the 2026-06-09 svc-cockpit2 incident).
#
#      Grace: the relay fires only after the overlay has been
#      continuously observed for MONITOR_WORKER_ASKUQ_GRACE_SECONDS
#      (default 300; 0 disables the relay), preserving the Case D
#      rationale — a human mid-answer makes the overlay vanish and
#      nothing fires. Continuity is mtime-tracked on the first-seen
#      marker: a gap of > 90 s between sightings (several missed 10 s
#      scan cycles) means the overlay went away and came back, so the
#      episode re-arms and the grace clock restarts. Single-shot per
#      (window, fp): an existing record or `.handled.json` tombstone
#      suppresses re-writes; a new question (new fp) re-arms, and so
#      does a same-fp question after a > 90 s sighting gap, which also
#      retires the previous instance's tombstone (as Case A does). If the
#      orchestrator acks (rm) while the worker is STILL blocked on the
#      same fp, the next scan re-writes the record — correct, because
#      the question remains unanswered; the emit-level content-hash
#      dedup keeps the re-surface from flooding (issue #152 lesson).

# `_ensure_service_log` (nexus-code#484/#509): the unstick log must
# never be created group-writable by a bare `>>`.
_unstick_module_dir="${BASH_SOURCE[0]%/*}"
[[ "$_unstick_module_dir" == "${BASH_SOURCE[0]}" ]] && _unstick_module_dir=.
# shellcheck source=../_log-mode.sh
source "$_unstick_module_dir/../_log-mode.sh"
# Dead-pane paste guard (#745). Sourced EXPLICITLY rather than relied on
# transitively from main.sh: this module is also sourced standalone by
# test-unstick.sh, and a missing function is rc 127 — which reads as "not
# dead" and silently restores a hazard that kills the tmux SERVER. Fail
# LOUD instead.
# shellcheck source=../_pane-live.sh
[[ -r "$_unstick_module_dir/../_pane-live.sh" ]] && source "$_unstick_module_dir/../_pane-live.sh"
# THE confirmed-delivery primitive (your-org/nexus-code#1591) — holds the tree's
# one `tmux paste-buffer`. Explicit for the same reason as `_pane-live.sh`: this
# module is sourced standalone by suites. Quiet at load, LOUD at use:
# `_paste_line_to_window` refuses to paste when `pd_deliver` is not defined.
# shellcheck source=../_paste-deliver.sh
[[ -r "$_unstick_module_dir/../_paste-deliver.sh" ]] && source "$_unstick_module_dir/../_paste-deliver.sh"
if ! declare -F _tmux_pane_is_dead >/dev/null 2>&1; then
    # FAIL-CLOSED FALLBACK (#745). Without the real predicate we cannot
    # tell a live pane from a corpse, and a paste into a corpse kills the
    # tmux SERVER — so every paste refuses, loudly, at the moment it is
    # attempted.
    #
    # Deliberately NOT an `exit`/`return` at load time. The first cut
    # refused to LOAD, and CI showed why that is wrong: several fixtures
    # build partial trees from ENUMERATED copy lists, so the file is
    # simply absent there, and four unrelated suites died on modules
    # they never paste from. A missing paste guard must stop PASTES, not
    # module loading. Quiet at load, loud at use: the noise belongs where
    # the hazard is.
    _tmux_pane_is_dead() {
        printf '%s: _pane-live.sh unavailable — cannot prove %q is a live pane, refusing to paste (your-org/nexus-code#745: a paste into a dead pane kills the tmux server)\n' \
            "${BASH_SOURCE[1]##*/}" "${1:-?}" >&2
        return 0
    }
fi
unset _unstick_module_dir

unstick_log() {
    local msg
    msg="[$(date -Is)] $*"
    _ensure_service_log "$UNSTICK_LOG"
    printf '%s\n' "$msg" >> "$UNSTICK_LOG" 2>/dev/null || true
}

# Stable fingerprint of the prompt instance: pulls out the lines that
# define the prompt (title + numbered options + highlight arrow) and
# hashes them. Spinner / cursor / status-line characters that change
# every capture are excluded so the same prompt yields the same
# fingerprint across poll cycles.
_unstick_fingerprint() {
    grep -E '(Do you want to proceed\?|What do you want to do\?|❯[[:space:]]+[0-9]+\.|^[[:space:]]*[0-9]+\.[[:space:]]|Stop and wait for limit)' \
        | sha1sum | cut -c1-12
}

# Probe the Anthropic API to discover the rate-limit reset timestamp.
# Output: ISO 8601 timestamp on stdout, empty string on any failure
# (probe disabled, no key, curl missing, header absent, non-2xx, etc.)
# Cost: ~1 token output + a few hundred input tokens per call. Callers
# MUST cache the result for the duration of the rate-limit hit and not
# re-probe each cycle.
_probe_ratelimit_reset() {
    [[ "${RATELIMIT_PROBE,,}" == "true" ]] || return 0
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    # NO second default (your-org/nexus-code#568 D13). `_config.sh:804` already
    # resolves PROBE_MODEL — env → config → default — and main.sh exports it to
    # every module. Repeating the literal id here made this a SECOND source of
    # truth for a value that already had one: a config change would move the
    # watcher's probe model everywhere except the one code path that actually
    # issues the probe. Fail visibly instead of silently probing a different
    # model than the operator configured.
    local model="${PROBE_MODEL:-}"
    if [[ -z "$model" ]]; then
        log "ratelimit-probe: PROBE_MODEL unset (config resolution did not run?); skipping probe" 2>/dev/null || true
        return 0
    fi
    local resp_headers
    resp_headers=$(curl -sS -m 15 -D - -o /dev/null \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        --data "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\".\"}],\"max_tokens\":1}" \
        https://api.anthropic.com/v1/messages 2>/dev/null) || return 0
    # Prefer the unified-reset (covers both input + output token buckets);
    # fall back to the tokens-reset header which older API versions emit.
    local reset
    reset=$(grep -i '^anthropic-ratelimit-unified-reset:' <<<"$resp_headers" \
            | tr -d '\r' | awk '{print $2}' | head -1)
    [[ -z "$reset" ]] && reset=$(grep -i '^anthropic-ratelimit-tokens-reset:' <<<"$resp_headers" \
            | tr -d '\r' | awk '{print $2}' | head -1)
    printf '%s' "$reset"
}

# Record a watcher-side machine input into a worker pane (the Enter
# nudges below) in the machine-input ledger, so the idle-probe's
# operator-attribution rule (issue #201; see the "operator-engaged
# marks" section of _idle_probe.sh) doesn't mistake the resulting
# busy transition for operator input and falsely suppress the
# window's stall-nag. Thin wrapper over `_machine_input_stamp`
# (monitor/watcher/_lib.sh) — the single ledger-write chokepoint
# shared by every watcher-side injector (#293) — preserving the
# historical `unstick` default src for callers that omit it.
_unstick_stamp_machine_input() {
    local window="$1" src="${2:-unstick}"
    _machine_input_stamp "$window" "$src"
}

# THE DANGER VOCABULARY Claude Code renders above a non-bypassable permission
# prompt (your-org/nexus-code#1599). Fixed strings, matched with -F: every one is
# a harness string, so a reword upstream silently moves a prompt from `danger:`
# to `unlisted` — which is still REFUSED (the allowlist is empty), so the drift
# costs wording, never a keypress. That is why this list is on the collision
# list in skills/nexus.cc-update/GUIDE.md rather than load-bearing for safety.
# Measured from the 61 case-A audits described in the file header.
_UNSTICK_PERMISSION_DANGER_MARKERS=(
    'Dangerous '
    'possibly-empty variable path'
    'critical path'
    'statically-unresolvable target'
    'working directory or its ancestor'
    'This command requires approval'
    'which is a sensitive file'
)

# _unstick_permission_verdict  (pane on stdin) → one word on stdout
#
#   danger       a danger marker is on screen — never answered, by anyone but a human
#   unlisted     no marker, and not on the allowlist — refused
#
# DENY-FIRST, and there is NO allow arm (see the Case A narrative for the
# evidence that no benign prompt could be identified). If one is ever added it
# goes BELOW the danger arm: a SAFE arm may not precede a DENY arm that could
# fire on the same input (your-org/nexus-code#1121). The marker itself is
# printed on a second line so the log and the decision row can name it.
_unstick_permission_verdict() {
    local pane m line
    pane=$(cat)
    for m in "${_UNSTICK_PERMISSION_DANGER_MARKERS[@]}"; do
        line=$(grep -F -m1 -e "$m" <<<"$pane") || continue
        printf 'danger\n%s\n' "$(sed 's/^[[:space:]│]*//; s/[[:space:]]*$//' <<<"$line")"
        return 0
    done
    printf 'unlisted\n'
}

# Case A's detection predicate: the permission-prompt title AND a highlighted
# numbered row, anywhere in the capture. PRESENCE, deliberately — see the
# ordering block in `_handle_unstick_window` for why it is not live-gated. One
# function so the one-line arm there can be mutation-gated as a unit.
_unstick_pane_has_permission_prompt() {
    grep -qE 'Do you want to proceed\?' <<<"$1" \
        && grep -qE '❯[[:space:]]+[0-9]+\.' <<<"$1"
}

# Fingerprint of ONE permission prompt instance. `_unstick_fingerprint` keys on
# the title + option rows only, and those are byte-identical across every
# two-option prompt ("Do you want to proceed? ❯ 1. Yes 2. No" — the audits show
# one fp, ca80bcd97f11, for 30+ unrelated prompts). As a decision-record key that
# would make an ack of one prompt mute every later one in the window. So this
# hashes the prompt BODY too: the dozen rows above the title (the command and the
# danger line) through the option rows. The modal suspends the turn, so that
# region is static across polls — EXCEPT for one glyph.
#
# THE BLINKING BULLET (skeptic pass on #1626, item 5). The pending tool call's
# header row (`● Running S=…`) sits inside that dozen-row window for 20 of the 61
# audits, and its leading `●` blinks: the same prompt captured bullet-on and
# bullet-off hashed to 2fdedef677d9 and 2ad2cfce387a (the `ncbundle` audit), so
# one prompt made two decision records and an ack of one left its twin standing.
# The row cannot be DROPPED by a pattern, because its bullet-off rendering
# (`  Running S=…`) carries no marker to recognise it by — so the glyph is
# NORMALISED: a leading `●` (Linux) or `⏺` (macOS) becomes the space it blinks
# to. Only column 0 is touched, so a bullet inside a row still distinguishes.
#
# THE AUTO-DENY COUNTDOWN (your-org/nexus-code#1632). From 2.1.281 the
# dangerous-rm prompt paints `⚠ Claude Code will automatically deny this request
# in 2:00, …` inside the same window, and the clock ticks every second: four
# captures of one prompt 10 s apart hashed to four fps (ffccaff683d5,
# 577372bca532, 018e04f35fdb, 33bd5eda473c), so a ~120 s prompt made 2–3
# records at the live 60 s interval. Only the M:SS token is normalised; the row
# itself stays in the hash, so a countdown prompt still differs from a
# countdown-free one. On a hooked pane the prompt is DECIDED by
# monitor/hooks/dangerous-rm-decide.sh, but the dialog still renders while the
# hook waits (measured), so Case A sees it too and must key one record per
# prompt; on a hookless pane the countdown runs to its own deny.
_unstick_fingerprint_permission() {
    awk '{ sub(/[[:space:]]+$/, ""); row[NR] = $0 }
         { sub(/^(●|⏺)/, " ", row[NR]) }
         { gsub(/deny this request in [0-9]+:[0-9]+/, "deny this request in M:SS", row[NR]) }
         /Do you want to proceed\?/ { t = NR }
         END {
             if (!t) exit
             lo = t - 12; if (lo < 1) lo = 1
             hi = t + 6;  if (hi > NR) hi = NR
             for (i = lo; i <= hi; i++) print row[i]
         }' | sha1sum | cut -c1-12
}

# Case A (your-org/nexus-code#1599): a permission prompt is DETECTED and NEVER
# ANSWERED. No key reaches the pane — not Enter, not Escape, not a digit. See the
# Case A narrative for why the allowlist is empty.
#
# Per prompt instance (window, fp): keep the pre-action capture as the audit, log
# ONE `case=A action=refused` line (a `.refused` marker dedups the per-cycle
# re-detection), and surface it on the pending-decisions channel so it is an
# operator decision rather than a silent skip.
# Retire the ack tombstone of a PREVIOUS instance of a recurring prompt — shared
# by Case A (a `.refused` sighting after a > 90 s gap) and Case W (a re-armed
# first-seen episode). A `.handled.json` sibling makes every reader skip the
# active record, so a tombstone left standing past the episode it acked mutes
# every later instance of the same fingerprint forever (skeptic pass on #1626,
# item 5 and its case-W residual). Callers decide WHEN a sighting is a new
# instance; this only removes the tombstone and says so.
_unstick_retire_tombstone() {  # <window> <fp> <case-letter> <noun>
    local window="$1" fp="$2" case_l="$3" noun="$4"
    local tomb="${STATE_DIR:-$(dirname "$UNSTICK_DIR")}/decisions/${window}.${fp}.handled.json"
    if [[ -f "$tomb" ]] && rm -f "$tomb"; then
        unstick_log "window=$window case=$case_l action=tombstone-retired fp=$fp — the $noun came back after its ack; surfacing it again"
    fi
    return 0
}

_act_permission() {
    local window="$1" pane="$2"
    local fp verdict marker v
    fp=$(printf '%s\n' "$pane" | _unstick_fingerprint_permission)
    v=$(printf '%s\n' "$pane" | _unstick_permission_verdict)
    verdict=$(sed -n 1p <<<"$v")
    marker=$(sed -n 2p <<<"$v")
    local audit="$UNSTICK_DIR/${window}.permission.${fp}.audit"
    [[ -f "$audit" ]] || printf '%s\n' "$pane" > "$audit"
    local refused="$UNSTICK_DIR/${window}.permission.${fp}.refused"
    # EPISODES, not fingerprints (skeptic pass on #1626, item 5). The `.refused`
    # marker used to be written once and never cleared, and an ack-and-mute
    # tombstone was honoured forever — so a prompt that was answered, went away
    # and came BACK with the same fingerprint (a worker re-running the command it
    # was refused) logged nothing and surfaced nothing: on a HOOKLESS pane, whose
    # record no Stop hook ever resolves, that is a live prompt nobody is told
    # about. The marker's mtime is now the last sighting (Case W's first-seen
    # protocol, same 90 s: nine 10 s scan cadences): a sighting after a longer
    # gap is a NEW instance — it is logged again, and a tombstone left by the ack
    # of the PREVIOUS instance is retired, because a tombstone sibling makes every
    # reader skip the active record (`_idle_probe.sh`, `ng decision-ack`).
    # Error direction, stated: a watcher stalled > 90 s beside a prompt that never
    # went away re-surfaces it once — noise, never a silent prompt.
    local now last_seen episode=same
    now=$(date +%s)
    if [[ ! -f "$refused" ]]; then
        episode=first
    else
        last_seen=$(stat -c %Y "$refused" 2>/dev/null || echo 0)
        [[ "$last_seen" =~ ^[0-9]+$ ]] || last_seen=0
        if (( now - last_seen > 90 )); then episode=recurred; fi
    fi
    : > "$refused"
    if [[ "$episode" != same ]]; then
        unstick_log "window=$window case=A action=refused verdict=$verdict fp=$fp audit=$(basename "$audit")${marker:+ marker=\"$marker\"}$([[ "$episode" == recurred ]] && printf ' episode=recurred gap=%ss' "$(( now - last_seen ))") — NO key: a permission prompt is an operator decision (your-org/nexus-code#1599)"
    fi
    [[ "$episode" == recurred ]] && _unstick_retire_tombstone "$window" "$fp" A "prompt"
    _unstick_permission_relay "$window" "$pane" "$fp" "$verdict" "$marker" "$audit"
    return 0
}

# Write the refused prompt to the pending-decisions channel — the SAME channel
# and schema the Notification hook (hooks/decision-emit.sh) and Case W write, so
# `render_pending_decisions` surfaces it with no new reader.
#
# `kind` is `permission_prompt` DELIBERATELY, and it SELECTS (checked, per
# your-org/nexus-code#1050): hooks/decision-mark-unresolved.sh rules on it — Stop
# means the modal is gone, so the row is stamped `resolved` instead of left loud
# — and `render_pending_decisions` exempts only `idle_prompt` from operator-
# engaged suppression, so this kind always surfaces. A new kind would take the
# Stop hook's DEFAULT arm (`unresolved: true`) and nag after the prompt was gone.
# `source` and `verdict` are new, additive fields no reader selects on.
#
# Cost, stated: a HOOKED worker also gets the hook's own row ("Claude needs your
# permission") under a different fingerprint, so it shows two rows; this one is
# the one that says what is being asked. Both resolve on Stop.
#
# Single-shot per (window, fp) while pending; a tombstone mutes it; a RESOLVED
# record is rewritten, because the same prompt on screen again is a new instance
# (decision-emit.sh's re-fire semantics).
_unstick_permission_relay() {
    local window="$1" pane="$2" fp="$3" verdict="$4" marker="$5" audit="$6"
    local decisions_dir="${STATE_DIR:-$(dirname "$UNSTICK_DIR")}/decisions"
    local dest="$decisions_dir/${window}.${fp}.json"
    [[ -f "$decisions_dir/${window}.${fp}.handled.json" ]] && return 0
    if ! command -v jq >/dev/null 2>&1; then
        unstick_log "WARN window=$window case=A action=jq-missing fp=$fp (prompt refused, but NOT surfaced as a decision)"
        return 1
    fi
    if [[ -f "$dest" ]] && ! jq -e '.resolved == true' "$dest" >/dev/null 2>&1; then
        return 0
    fi
    mkdir -p "$decisions_dir" 2>/dev/null || true
    local why options excerpt
    if [[ "$verdict" == danger ]]; then
        why="danger marker: $marker"
    else
        why="no danger marker, and the case-A allowlist is empty"
    fi
    options=$(grep -E '^[[:space:]]*(❯[[:space:]]+)?[0-9]+\.' <<<"$pane")
    # Line 1 is what the emit row shows (first non-empty line, 160 chars): lead
    # with the refusal, so nobody reads the row as "please press Enter".
    excerpt=$(printf 'Watcher REFUSED to answer a permission prompt (%s) — operator decision, see your-org/nexus-code#1599\n%s' "$why" "$options")
    local tmp="$dest.tmp.$$"
    if jq -nc \
        --arg ts             "$(date -Is)" \
        --arg window         "$window" \
        --arg kind           "permission_prompt" \
        --arg prompt_excerpt "$excerpt" \
        --arg tool_context   "$pane" \
        --arg fingerprint    "$fp" \
        --arg source         "watcher-unstick-case-A" \
        --arg verdict        "$verdict" \
        '{ts: $ts, window: $window, session_id: "", kind: $kind,
          prompt_excerpt: $prompt_excerpt, tool_context: $tool_context,
          fingerprint: $fingerprint, source: $source, verdict: $verdict}' \
        > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp"; return 1; }
        unstick_log "window=$window case=A action=surfaced fp=$fp decision=$(basename "$dest") audit=$(basename "$audit")"
    else
        rm -f "$tmp"
        unstick_log "WARN window=$window case=A action=record-write-failed fp=$fp"
        return 1
    fi
    return 0
}

# Stable fingerprint of an AskUserQuestion chip-bar overlay. Pulls
# the lines that carry the chip-bar's distinguishing markers (the
# `Type something.` and `Chat about this` literals, the numbered
# options, and any question line ending in `?`) and hashes them.
# Cosmetic chrome — chip arrows, status-bar bytes — is excluded so
# the same dialog yields the same fingerprint across poll cycles,
# letting `_act_askuq` de-duplicate retries via the per-(window, fp)
# audit file. The `\?$` clause distinguishes dialogs whose options
# are identical but question text differs (load-bearing for the
# "distinct fp re-fires" test — without it, two consecutive dialogs
# with the same options would silently be treated as a single
# already-handled fp).
_unstick_fingerprint_askuq() {
    grep -E '(Type something\.|Chat about this|^[[:space:]]*[0-9]+\.[[:space:]]|❯[[:space:]]+[0-9]+\.|\?[[:space:]]*$)' \
        | sha1sum | cut -c1-12
}

# Dismiss an AskUserQuestion chip-bar overlay on a window and paste a
# meta-message into the now-clean input box. The meta-message is what
# the orchestrator will see next — its content explains what happened
# and points at `monitor/agent-prompt.md` so any future code path that
# slipped past Layer A1 (the `PreToolUse` matcher) is also self-
# documenting from the orchestrator's side. Layered behaviour:
#
#   ON_DIALOG=auto-dismiss (default)  capture + Escape + paste meta
#   ON_DIALOG=skip                    log detection, take no action
#   ON_DIALOG=error                   log WARN, take no action
#
# Single-shot per (window, fingerprint): once we've fired the
# dismissal+meta paste for a fp, repeated detections of the same fp
# are logged as `case=D action=skip-fired fp=<fp>` so the orchestrator
# isn't flooded with duplicate meta-messages on slow render cycles.
# A distinct fp (new dialog) clears the fired marker.
_act_askuq() {
    local window="$1" pane="$2"
    local case_key="askuq"
    local mode="${ON_DIALOG:-auto-dismiss}"
    local fp_file="$UNSTICK_DIR/${window}.${case_key}.fp"
    local fired_file="$UNSTICK_DIR/${window}.${case_key}.fired"
    local fp prev_fp
    fp=$(printf '%s\n' "$pane" | _unstick_fingerprint_askuq)
    prev_fp=""
    [[ -f "$fp_file" ]] && prev_fp=$(<"$fp_file")
    if [[ "$fp" != "$prev_fp" ]]; then
        rm -f "$fired_file"
    fi
    printf '%s' "$fp" > "$fp_file"

    case "$mode" in
        skip)
            unstick_log "window=$window case=D action=skip-detected fp=$fp on_dialog=$mode"
            return 0
            ;;
        error)
            unstick_log "WARN window=$window case=D action=detected-no-act fp=$fp on_dialog=$mode"
            return 0
            ;;
        auto-dismiss|"") ;;
        *)
            unstick_log "WARN window=$window case=D action=unknown-mode fp=$fp on_dialog=$mode (defaulting to skip)"
            return 0
            ;;
    esac

    if [[ -f "$fired_file" ]]; then
        unstick_log "window=$window case=D action=skip-fired fp=$fp"
        return 0
    fi

    local audit="$UNSTICK_DIR/${window}.${case_key}.${fp}.audit"
    [[ -f "$audit" ]] || printf '%s\n' "$pane" > "$audit"

    # Escape dismisses the modal — same key the Claude Code REPL
    # binds to "cancel menu". The `paste_to_target` mode-force in
    # main.sh avoided Escape because Escape mid-generation aborts
    # the in-flight turn; by construction that concern doesn't apply
    # here (the dialog itself blocks generation, so there's no
    # turn to abort).
    # EXACT target (your-org/nexus-code#1524): a bare name resolves by unique
    # PREFIX once the window is gone, and the Escape would abort a sibling's turn.
    if ! tmux send-keys -t "$(_unstick_exact_target "$window")" Escape 2>/dev/null; then
        unstick_log "window=$window case=D action=escape-failed fp=$fp"
        return 1
    fi
    sleep 0.5

    local meta='[nexus watcher] An AskUserQuestion dialog was open and has been dismissed automatically. Nexus orchestrators must never call AskUserQuestion — communicate with the operator via GitHub issue comments. See monitor/agent-prompt.md.'
    if ! _paste_line_to_window "$window" "$meta"; then
        unstick_log "window=$window case=D action=meta-paste-failed fp=$fp"
        return 1
    fi
    printf '1' > "$fired_file"
    unstick_log "window=$window case=D action=dismissed-and-pasted fp=$fp audit=$(basename "$audit")"
    return 0
}

# Case W — worker-blocked-question relay. See the Case W narrative in
# the file header. Called by `_handle_unstick_window` when the AskUQ
# live-overlay detection fires on a NON-target window. Never sends
# keys to the pane; the only outputs are the first-seen/audit state
# files under $UNSTICK_DIR and, once the grace elapses, a synthesized
# pending-decision record on the issue-129 channel.
#
# First-seen marker protocol (`<window>.worker-askuq.<fp>.first-seen`):
#   content = epoch of the episode's first sighting (the grace anchor)
#   mtime   = epoch of the most recent sighting (the continuity probe)
# Every sighting touches the mtime; a sighting whose predecessor is
# > 90 s stale means the overlay vanished and reappeared between scans
# (the human answered, then a new identical question arrived, or the
# capture flickered) — the episode resets and the grace clock restarts.
# 90 s ≈ nine 10 s detect_unstick cadences; generous enough that async
# scheduler starvation can't false-reset, small enough that a same-fp
# question hours later doesn't inherit a long-expired grace anchor.
_act_worker_askuq() {
    local window="$1" pane="$2"
    local grace="${MONITOR_WORKER_ASKUQ_GRACE_SECONDS:-300}"
    [[ "$grace" =~ ^[0-9]+$ ]] || grace=300
    (( grace == 0 )) && return 0   # relay disabled by the operator

    local fp now
    fp=$(printf '%s\n' "$pane" | _unstick_fingerprint_askuq)
    now=$(date +%s)

    local first_file="$UNSTICK_DIR/${window}.worker-askuq.${fp}.first-seen"
    if [[ ! -f "$first_file" ]]; then
        printf '%s' "$now" > "$first_file"
        unstick_log "window=$window case=W action=first-seen fp=$fp grace=${grace}s"
        return 0
    fi

    local last_seen first_seen
    last_seen=$(stat -c %Y "$first_file" 2>/dev/null || echo 0)
    [[ "$last_seen" =~ ^[0-9]+$ ]] || last_seen=0
    if (( now - last_seen > 90 )); then
        printf '%s' "$now" > "$first_file"
        unstick_log "window=$window case=W action=re-armed fp=$fp (sighting gap $(( now - last_seen ))s)"
        # A re-armed episode is a NEW instance of the question, so the ack of
        # the previous one no longer applies (Case A's recurrence rule, skeptic
        # pass on #1626). Without this the grace elapsed into `skip-tombstone`
        # on every later instance: a HOOKLESS worker's recurring AskUQ — whose
        # record no Stop hook resolves — was never surfaced again. Retired HERE,
        # at the gap, not at relay time: a tombstone written during a
        # continuously-observed episode (acked while the overlay stayed up)
        # still mutes it. Error direction as Case A's: a watcher stalled > 90 s
        # beside an overlay that never went away re-surfaces it once.
        _unstick_retire_tombstone "$window" "$fp" W "question"
        return 0
    fi
    touch "$first_file" 2>/dev/null || true

    first_seen=$(<"$first_file")
    [[ "$first_seen" =~ ^[0-9]+$ ]] || { printf '%s' "$now" > "$first_file"; return 0; }
    (( now - first_seen < grace )) && return 0

    # Grace elapsed with the overlay continuously live — relay.
    local decisions_dir="${STATE_DIR:-$(dirname "$UNSTICK_DIR")}/decisions"
    local dest="$decisions_dir/${window}.${fp}.json"
    local tomb="$decisions_dir/${window}.${fp}.handled.json"
    if [[ -f "$tomb" ]]; then
        unstick_log "window=$window case=W action=skip-tombstone fp=$fp"
        return 0
    fi
    # Already relayed and not yet acked — single-shot per (window, fp).
    [[ -f "$dest" ]] && return 0

    if ! command -v jq >/dev/null 2>&1; then
        unstick_log "WARN window=$window case=W action=jq-missing fp=$fp (relay skipped)"
        return 1
    fi
    mkdir -p "$decisions_dir" 2>/dev/null || true

    # Parse the question (the last `?`-terminated line above the
    # options renders as the row excerpt in the pending-decisions
    # section) and the numbered option list. Parse failures degrade to
    # a pointer at the pane tail — the relay must surface even when
    # the overlay shape drifts.
    local question options excerpt
    question=$(grep -E '\?[[:space:]]*$' <<<"$pane" | tail -n 1 \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -n "$question" ]] || question="(question text not parsed — see tool_context pane capture)"
    options=$(grep -E '^[[:space:]]*(❯[[:space:]]+)?[0-9]+\.' <<<"$pane")
    excerpt=$(printf '%s\n%s' "$question" "$options")

    local audit="$UNSTICK_DIR/${window}.worker-askuq.${fp}.audit"
    [[ -f "$audit" ]] || printf '%s\n' "$pane" > "$audit"

    local tmp="$dest.tmp.$$"
    if jq -nc \
        --arg ts             "$(date -Is)" \
        --arg window         "$window" \
        --arg kind           "blocked_question" \
        --arg prompt_excerpt "$excerpt" \
        --arg tool_context   "$pane" \
        --arg fingerprint    "$fp" \
        '{
            ts: $ts,
            window: $window,
            session_id: "",
            kind: $kind,
            prompt_excerpt: $prompt_excerpt,
            tool_context: $tool_context,
            fingerprint: $fingerprint
         }' > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp"; return 1; }
        unstick_log "window=$window case=W action=relayed fp=$fp decision=$(basename "$dest") waited=$(( now - first_seen ))s audit=$(basename "$audit")"
    else
        rm -f "$tmp"
        unstick_log "WARN window=$window case=W action=record-write-failed fp=$fp"
        return 1
    fi
    return 0
}

# Per-window detection logging for the rate-limit prompt. Distinct from
# the action — case B's cascade is a session-wide single-shot kicked
# off by `_act_ratelimit`, not by per-window state.
_record_ratelimit_seen() {
    local window="$1" pane="$2"
    local case_key="ratelimit"
    local fp_file="$UNSTICK_DIR/${window}.${case_key}.fp"
    local tries_file="$UNSTICK_DIR/${window}.${case_key}.tries"
    local fp prev_fp
    fp=$(printf '%s\n' "$pane" | _unstick_fingerprint)
    prev_fp=""
    [[ -f "$fp_file" ]] && prev_fp=$(<"$fp_file")
    if [[ "$fp" != "$prev_fp" ]]; then
        printf '%s' "$fp" > "$fp_file"
        printf '%d' "0" > "$tries_file"
        unstick_log "window=$window case=B action=detected fp=$fp"
    fi
}

# Inspect a single tmux window for a stuck prompt. Acts on case A
# directly; for case B it just records the detection and prints the
# string `ratelimit` so the caller can collect candidates for the
# global cascade. Prints empty string if no prompt matched.
_handle_unstick_window() {
    local window="$1"
    # Never paste into the watcher's own pane.
    [[ "$window" == "${WATCHER_WINDOW:-watcher}" ]] && return 0
    local pane
    # EXACT target (your-org/nexus-code#1524). This READ decides which case
    # fires, and the PATH-front tmux shim refuses mis-aimed ACTS but not reads:
    # a bare name whose window is gone resolves by unique PREFIX, so a live
    # sibling's pane would select the arm acted on under THIS window's name.
    pane=$(tmux capture-pane -t "$(_unstick_exact_target "$window")" -p -S -25 2>/dev/null) || return 0
    [[ -z "$pane" ]] && return 0

    # ORDER IS THE SAFETY PROPERTY HERE, and it is decided by one rule: no arm
    # that SENDS A KEY may precede the arm that REFUSES, when both could fire on
    # the same pane (your-org/nexus-code#1121). Case A sends no key since #1599,
    # so it goes FIRST: before B (the cascade's dismiss Enter), before D (Escape
    # + paste) and before W (a different record kind). Placed
    # first, its error direction is OVER-REFUSAL only — it can never answer.
    #
    # THIS USED TO SAY Case C (the API-error Enter arm, retired since
    # your-org/nexus-code#1670) is "disjoint from all menus, so its position in the
    # chain is incidental". That was FALSE (skeptic pass on #1626, finding 1):
    # the arms test PRESENCE in a 25-line capture, not exclusivity, so an
    # api-error chip anywhere above a LIVE `Do you want to proceed?` made C claim
    # the pane and press Enter — selecting the highlighted `❯ 1. Yes`. Measured
    # on a real danger-audit capture: `case=C action=sent-Enter`, no case-A
    # record. The same shape held for B (a QUOTED rate-limit menu above a live
    # prompt reads LIVE to `_unstick_ratelimit_menu_verdict`: the live prompt
    # replaces the REPL input row, so no input row follows the quoted title, and
    # a quoted `❯ 1. Stop…` row reads stop-highlighted) and for D (a live
    # permission prompt renders `Esc to cancel · Tab to amend` within its last
    # three non-blank rows — 58 of the 61 audits — which satisfies D's
    # bottom-anchored live-ness gate, so quoted chip-bar literals above it got
    # Escape + a paste on the orchestrator, and a blocked_question row instead of
    # a permission_prompt row elsewhere).
    #
    # D used to precede A for the opposite reason: A pressed Enter, and its `❯ N.`
    # pattern would have auto-Entered option 1 of an AskUQ overlay. With A
    # sending no key that reason is gone, and the ordering it forced is now the
    # hazard. What remains is the over-refusal it costs, stated: A needs the
    # literal `Do you want to proceed?` AND a `❯ N.` row anywhere in the capture,
    # so a live AskUQ / rate-limit menu whose capture ALSO
    # carries that title — an AskUQ whose question is literally that sentence,
    # or a pane quoting a permission prompt within 25 rows — is refused and
    # surfaced as a permission_prompt decision instead of being dismissed.
    # On the orchestrator that means an AskUQ stays up until someone
    # answers; that is a liveness cost, never a key into a live prompt.
    #
    # Deliberately NOT narrowed with a live-ness gate of its own: a gate that
    # missed a live prompt (a footer reworded upstream) would hand it to an arm
    # that presses a key, which is the direction this ordering exists to close.
    if _unstick_pane_has_permission_prompt "$pane"; then _act_permission "$window" "$pane"; printf 'permission'; return 0; fi
    # LIVE, not merely present (your-org/nexus-code#1598): the two literals alone
    # matched an agent whose tool call QUOTED them, and the watcher pressed
    # Enter into that pane and into the orchestrator's. A quoted menu falls
    # through to the cases below, exactly as a pane without the literals does.
    # The rate-limit menu precedes D only by history; they are disjoint in
    # what they send a key INTO only because A, above, has already taken every
    # pane that carries a permission prompt.
    case "$(printf '%s\n' "$pane" | _unstick_ratelimit_menu_verdict)" in
        stop-highlighted|other-highlighted)
            _record_ratelimit_seen "$window" "$pane"
            printf 'ratelimit'
            return 0 ;;
    esac
    # AskUserQuestion chip-bar (Cases D + W). The detection is shared;
    # the WINDOW decides the action:
    #
    #   - TARGET (orchestrator) → Case D dismiss-and-paste: the paste
    #     channel must be restored, and Layer A1 says the orchestrator
    #     should never have asked. See the Case D narrative.
    #   - any other window      → Case W blocked-question relay: never
    #     touch the pane; grace-gate, then synthesize a pending-decision
    #     record so the orchestrator answers on the operator's behalf.
    #     See the Case W narrative.
    #
    # LIVE-vs-QUOTED guard (both cases): the overlay's navigation
    # footer (`Esc to cancel`) must sit at the BOTTOM of the pane
    # (within the last few non-blank lines), where a live interactive
    # overlay always renders it. A pane that merely *displays* the
    # chip-bar literals — an agent discussing this feature, quoting a
    # worker's TUI-surface inventory, or echoing a captured overlay —
    # keeps the normal Claude Code REPL chrome (input box + `◉ model`
    # status line) or other output at the bottom, pushing any mention
    # of the footer above the slice. The two option literals
    # (`Type something.` penultimate + `Chat about this` final) gate
    # the chip-bar shape; the bottom-anchored footer gates live-ness.
    if grep -qF 'Type something.' <<<"$pane" \
       && grep -qF 'Chat about this' <<<"$pane" \
       && grep -qF 'Esc to cancel' \
            <<<"$(printf '%s\n' "$pane" | grep -v '^[[:space:]]*$' | tail -n 3)"; then
        if [[ "$window" == "${TARGET:-orchestrator}" ]]; then
            _act_askuq "$window" "$pane"
            printf 'askuq'
        else
            _act_worker_askuq "$window" "$pane"
            printf 'worker-askuq'
        fi
        return 0
    fi
    # No API-error arm: Case C was retired (your-org/nexus-code#1670) — see the
    # Case C tombstone in the header. An API-error pane falls through here and
    # gets NO key; the StopFailure marker -> `interrupted` -> orchestrator path
    # owns its recovery.
    return 0
}

# `unstick_log` dereferences $UNSTICK_LOG, which main.sh always sets — and which
# is UNSET when this module is sourced standalone (suites, entry.sh). Under a
# caller's `set -u` that is a fatal expansion, not a failed command, so
# `|| true` cannot rescue it: the first cut of `_paste_line_to_window`'s logging
# turned a DELIVERED paste into rc 1 by killing the subshell it ran in, caught
# by test-paste-dead-pane-guard.sh's non-vacuity arm. Log only where there is a
# log; the paste's return code never depends on it.
_unstick_paste_note() { [[ -n "${UNSTICK_LOG:-}" ]] && unstick_log "$@"; return 0; }

# Paste a single line of text to a tmux window via the paste-buffer
# (avoids the send-keys per-character escaping pitfall). Mirrors the
# paste_to_target hardening from main.sh: `i BSpace` first to force the
# target into insert mode regardless of starting state.
_paste_line_to_window() {
    local window="$1" text="$2"
    # #745: never paste into a dead pane — it kills the tmux server
    # (20/20 measured), taking the watcher and every worker with it.
    # This site is a live hazard rather than a theoretical one: the
    # unstick cascade pastes into WORKER windows, `spawn-worker.sh`
    # sets `remain-on-exit` on all of them, and a retired worker is a
    # corpse. Returning 1 is the existing "paste failed" contract, so
    # every caller already handles it.
    # THE REFUSAL IS UNCONDITIONAL; ONLY THE WORDING VARIES (#1020).
    # `rc 0` means dead OR could-not-tell, and saying "is a dead pane" for the
    # second is a positive verdict asserted from zero evidence — the same
    # confusion `_bookkeeping.sh` calls an INDETERMINATE reading and refuses to
    # speak as a liveness verdict. Note the `return 1` sits OUTSIDE the inner
    # branch: gating it on `verdict == dead` is the exact mutant that re-opens
    # the #1017 fail-open, and part E of test-paste-dead-pane-guard.sh catches
    # it. Branch the message, never the refusal.
    if _tmux_pane_is_dead "$window"; then
        if [[ "${NEXUS_PANE_LIVE_VERDICT:-}" == "dead" ]]; then
            printf '_unstick: window %q is a DEAD pane — refusing to paste (your-org/nexus-code#745: a paste into a dead pane kills the tmux server). Respawn it; a retry is another attempt to kill the server.\n' \
                "$window" >&2
        else
            printf '_unstick: could NOT establish that window %q is a live pane (verdict=%s) — refusing to paste (your-org/nexus-code#745). This is NOT a corpse diagnosis: nobody looked successfully, the window may be healthy, and the refusal is RETRYABLE.\n' \
                "$window" "${NEXUS_PANE_LIVE_VERDICT:-unset}" >&2
        fi
        return 1
    fi
    local tmpfile
    tmpfile=$(mktemp) || return 1
    printf '%s' "$text" > "$tmpfile"
    # CONFIRMED DELIVERY (your-org/nexus-code#1591). This site used to paste,
    # press Enter ONCE and return 0 — it checked NOTHING, so a line Claude Code
    # held in the input box read as delivered, and the pane then read
    # `user-typing input=typed`, which the watcher treats as an operator draft.
    # The whole sequence (normalise, VI-safe BRACKETED paste from a file, Enter,
    # confirm against the target's transcript, Enter again only on positive
    # `held` evidence) is monitor/_paste-deliver.sh; the `-p` rationale (#1516)
    # lives there with the one paste-buffer call.
    #
    # EXACT target, never the bare name: tmux resolves a bare `-t <name>` by
    # unique PREFIX once the window is gone, and this paste + Enter would land
    # in a live sibling (your-org/nexus-code#1524).
    # INLINE ON PURPOSE, not `_unstick_exact_target`: test-paste-deliver.sh (and any
    # rig like it) extracts THIS FUNCTION ALONE out of the file and evals it, so it
    # must not depend on a sibling helper. Replacing these lines with the helper
    # broke ten of that suite's rows at 6ab73962 (tgt came back empty: rc 1, zero
    # keys sent) while test-unstick.sh, which sources the whole file, stayed green.
    local tgt=""
    if declare -F resolve_window_id >/dev/null 2>&1; then
        tgt=$(resolve_window_id "$window" 2>/dev/null || true)
    fi
    tgt="${tgt:-:=$window}"
    # The orchestrator has no heartbeat/<window>.json — its session-id is the
    # pin. An empty sid degrades to `unverifiable`, never to a wrong answer.
    local sid=""
    if [[ "$window" == "${TARGET:-orchestrator}" ]] && declare -F _respawn_read_pin_sid >/dev/null 2>&1; then
        sid=$(_respawn_read_pin_sid)
    fi
    if [[ -z "$sid" ]] && declare -F se_session_id_for_window >/dev/null 2>&1; then
        sid=$(se_session_id_for_window "$window" "${STATE_DIR:-}" 2>/dev/null) || sid=""
    fi
    local rc=0
    if ! declare -F pd_deliver >/dev/null 2>&1; then
        rm -f "$tmpfile"
        printf '_unstick: monitor/_paste-deliver.sh is not loaded — refusing to paste into %q without the confirmed-delivery primitive (your-org/nexus-code#1591)\n' "$window" >&2
        return 1
    fi
    pd_deliver "$tgt" "$window" "$tmpfile" "$sid"; rc=$?
    rm -f "$tmpfile"
    case "$rc" in
        0)  [[ "$PD_OUTCOME" == submitted ]] \
                || _unstick_paste_note "window=$window action=paste-line outcome=$PD_OUTCOME enter_retries=$PD_ENTER_RETRIES"
            return 0 ;;
        3)  # …EXCEPT `undecidable-box`: typed text is POSITIVELY in the input box
            # and could not be shown to be ours, so no Enter was sent. That is not
            # "could not confirm", it is "not delivered" — the first cut returned
            # 0 for it, caught by test-paste-deliver.sh's U-longline row run
            # against 71ecea4a (rc 0 with the line still held).
            if [[ "$PD_OUTCOME" == undecidable-box ]]; then
                _unstick_paste_note "window=$window action=paste-line outcome=NOT-DELIVERED:undecidable-box"
                return 1
            fi
            # unverifiable / in-flight: nothing could confirm and nothing says
            # the text is stuck. The historical answer, now SAID rather than
            # assumed.
            _unstick_paste_note "window=$window action=paste-line outcome=unconfirmed:$PD_OUTCOME${PD_UNVERIFIABLE_REASON:+ reason=\"$PD_UNVERIFIABLE_REASON\"}"
            return 0 ;;
        4)  _unstick_paste_note "window=$window action=paste-line outcome=NOT-SUBMITTED:$PD_OUTCOME enter_retries=$PD_ENTER_RETRIES"
            return 1 ;;
        *)  return 1 ;;
    esac
}

# ---- case B's Enter is an EQUALITY, not a shape (your-org/nexus-code#1598) ----
#
# An Enter aimed at a select menu SELECTS ITS HIGHLIGHTED ROW, and an Enter aimed
# at an input box SUBMITS WHATEVER IS IN IT. Case B used to press one BLIND, twice
# per cascade: into every window it had classified, and into the orchestrator's
# pane — the pane the operator types into — "to dismiss any menu (no-op if the
# orchestrator wasn't stuck)". That is true of an EMPTY box only.
#
# MEASURED, 2026-09-19 15:36:43 PDT, on the live board (watcher at 17f1f926): a
# worker's tool call QUOTED both menu literals; the two-grep detection classified
# its pane as rate-limited, and because a `ratelimit.reset.epoch` written eleven
# hours earlier for a window that had since gone was still on disk, the cascade
# fired ONE SECOND later: a blind Enter and a paste into a busy worker, then a
# blind Enter and a false heads-up into the orchestrator. The capture is
# monitor/watcher/fixtures/ratelimit-quoted-realpane-273.txt.
#
# AND WHAT THE ENTER SELECTS IS UPSTREAM'S TO DECIDE. Read out of the Claude Code
# 2.1.273 bundle, the menu's option list is
#     Vo ? [...billing, stop, ...rest] : [stop, ...rest, ...billing]
# with `Vo = P("tengu_jade_anvil_4", !1)`, a server-side flag whose client
# default is false. With it on, the highlighted default is `Upgrade your plan` or
# a usage-credits action, and a blind Enter selects THAT — the #1200 hazard (an
# Enter into an overlay committed 325 MB), with a billing action as the default.
#
# So the Enter is pressed only when a capture taken AT THAT MOMENT, on the EXACT
# target, positively reads `stop-highlighted`. Everything else gets no key and a
# log line.
#
# _unstick_ratelimit_menu_verdict   (pane text on stdin) prints ONE of
#   stop-highlighted   a LIVE menu whose highlighted row is the Stop option
#   other-highlighted  a LIVE menu whose highlighted row is anything else
#   quoted             the literals are on the pane, the menu is not live
#   none               the literals are not both there
#
# LIVE means: after the LAST `What do you want to do?` there is a highlighted
# option row (`❯ N. label`) and NO REPL input row. A live dialog REPLACES the
# input box; a pane that merely displays the text keeps its box — `❯` followed by
# a no-break space, bytes read off 2.1.273 and 2.1.278 — beneath it, busy or idle.
#
# FIDELITY, stated. The option ORDER above is a citation into the bundle. The
# RENDERED shape of the live menu is a MODEL: the synthetic fixture plus the real
# permission-prompt captures of the same Select component, because nobody can
# produce a rate-limited account on demand.
#
# ERROR DIRECTION, CORRECTED (skeptic pastefusk F3). This block used to promise
# that a wrong model reads `quoted` or `other-highlighted`, "never a wrong
# Enter". THAT GUARANTEE WAS FALSE as written, and a false guarantee in a header
# is worse than none: the REPL-row arm demanded the glyph at column 1 while the
# option-row arm tolerated indentation, so a quoted menu with a one-space-
# indented input row selected NEITHER arm and came back `stop-highlighted` —
# measured at 3 send-keys into a pane that was only displaying the text. Both
# arms now carry the same tolerance. What the direction claim rests on is
# therefore narrower and stateable: any pane whose rendering still shows an
# input row — at any indentation, with or without a box border — reads `quoted`,
# and a shape that matches no arm at all reads `quoted` too, because `hl` stays
# empty. A model error can still mis-read WHICH option is highlighted, and that
# direction is `other-highlighted`: no Enter.
# KNOWN BLIND SPOT, pre-existing and unchanged: under usage-based billing the
# bundle labels the option `Stop`, without the literal this file keys on, so such
# an account is never classified at all.
_unstick_ratelimit_menu_verdict() {
    LC_ALL=C awk '
        { line[NR] = $0 }
        index($0, "What do you want to do?") > 0 { title = NR }
        index($0, "Stop and wait for limit") > 0 { stop = 1 }
        END {
            if (!title || !stop) { print "none"; exit }
            hl = ""
            for (i = title + 1; i <= NR; i++) {
                if (line[i] ~ /^[ \t]*(\342\224\202)?[ \t]*\342\235\257[ \t]+[0-9]+\./) {
                    if (hl == "") hl = line[i]
                } else if (line[i] ~ /^[ \t]*(\342\224\202)?[ \t]*\342\235\257/) {
                    # SAME leading-whitespace tolerance as the option-row arm
                    # above (skeptic pastefusk F3). It demanded the glyph at
                    # COLUMN 1, so a REPL input row indented by one space matched
                    # NEITHER arm, the scan ran past it, and a QUOTED menu
                    # returned stop-highlighted — a wrong Enter, measured at 3
                    # send-keys into a pane that only displayed the text. A
                    # safe-side arm must never be WIDER than the hazard-side arm
                    # it is paired with (#1121). Order still separates them: the
                    # option row is the more specific pattern and is tested first.
                    print "quoted"; exit
                }
            }
            if (hl == "") { print "quoted"; exit }
            if (index(hl, "Stop and wait for limit") > 0) print "stop-highlighted"
            else print "other-highlighted"
        }'
}

# The EXACT tmux target for <window>: a resolved @id, else `:=<name>`. Never the
# bare name — tmux resolves that by unique PREFIX once the window is gone, and the
# key lands in a live sibling at rc 0 (your-org/nexus-code#1524).
_unstick_exact_target() {
    local window="$1" tgt=""
    if declare -F resolve_window_id >/dev/null 2>&1; then
        tgt=$(resolve_window_id "$window" 2>/dev/null || true)
    fi
    printf '%s' "${tgt:-:=$window}"
}

# Cascade the unstick to a single non-orchestrator window: Enter to
# dismiss the menu, VERIFY the pane left the menu, then a follow-up paste
# prompting the agent to continue. Returns 0 on success.
#
# Optional $2 names the RESET EVENT that expedited this cascade
# (your-org/nexus-code#1739), e.g. `credential-change`; empty for the ordinary
# epoch-elapsed path. It changes only the wording of the continuation brief.
#
# THREE REFUSALS, each a log line and NO paste (#1739 acceptance "a typed draft
# → refused", plus the dismissal check the issue asks for):
#   operator-draft     pane-state reports `input=typed` BEFORE the dismiss
#                      Enter — no key at all (`?` is not believed here; see
#                      the comment at the check).
#   dismiss-unverified the menu is still LIVE after the Enter: the Enter did not
#                      dismiss it, and a paste + Enter would land in the menu.
#   operator-draft     typed text is in the box AFTER the dismissal (a draft the
#                      menu was hiding) — the paste would append to it and the
#                      primitive's Enter would submit both.
_cascade_unstick_to_window() {
    local window="$1" reason="${2:-}"
    local pane tgt verdict pv
    tgt=$(_unstick_exact_target "$window")
    # Re-read HERE, on the exact target: the detection that put this window on
    # the list is up to one pd_deliver per earlier window old (~9 s each).
    pane=$(tmux capture-pane -t "$tgt" -p -S -25 2>/dev/null) || return 1
    local fp
    fp=$(printf '%s\n' "$pane" | _unstick_fingerprint)
    local audit="$UNSTICK_DIR/${window}.ratelimit.${fp}.audit"
    [[ -f "$audit" ]] || printf '%s\n' "$pane" > "$audit"
    # A PERMISSION PROMPT ON THE RE-READ PANE OUTRANKS THE MENU VERDICT (#1626,
    # the residual of your-org/nexus-code#1599): a quoted `❯ 1. Stop…` above a
    # live prompt reads stop-highlighted, and the Enter would answer the prompt.
    _unstick_pane_has_permission_prompt "$pane" && { unstick_log "window=$window case=B action=cascade-refused reason=permission-prompt fp=$fp audit=$(basename "$audit") — NO Enter: a live permission prompt is Case A's, never answered (your-org/nexus-code#1599)"; return 1; }
    verdict=$(printf '%s\n' "$pane" | _unstick_ratelimit_menu_verdict)
    if [[ "$verdict" != stop-highlighted ]]; then
        unstick_log "window=$window case=B action=cascade-refused reason=${verdict:-unreadable} fp=$fp audit=$(basename "$audit") — NO Enter: it would select whatever is highlighted, or submit whatever is in the box (your-org/nexus-code#1598)"
        return 1
    fi
    # BEFORE THE DISMISS: only `input=typed` is believed. `pd_pane_verdict`
    # cannot answer here — it reads `state=` first and a live menu is
    # `blocked` — and `input=?` is uninformative under a menu, which REPLACES
    # the input row, so the row pane-state classifies is a menu line. Refusing
    # on `?` here would refuse every live menu; it is refused AFTER the
    # dismissal instead, where the real input row is back on screen.
    if [[ "$(_unstick_pane_input "$window")" == typed ]]; then
        unstick_log "window=$window case=B action=cascade-refused reason=operator-draft stage=before-dismiss input=typed fp=$fp — NO key: typed text is the operator's (your-org/nexus-code#1739)"
        return 1
    fi
    if ! tmux send-keys -t "$tgt" Enter 2>/dev/null; then
        unstick_log "window=$window case=B action=cascade-send-keys-failed fp=$fp"
        return 1
    fi
    # VERIFY THE DISMISSAL (your-org/nexus-code#1739). The paste used to follow a
    # bare 0.2 s sleep, so an Enter the menu did not act on was followed by a
    # paste + Enter INTO the menu. Poll until the re-read pane no longer shows a
    # LIVE menu (`quoted`/`none` — the menu text may stay in scrollback above the
    # restored input row, which is exactly what `quoted` means). The bound is
    # CHOSEN, not measured: 3 s covers a repaint on a loaded host many times
    # over and costs nothing when the menu goes at once.
    local verify_s="${UNSTICK_DISMISS_VERIFY_S:-3}" waited=0 after=""
    [[ "$verify_s" =~ ^[0-9]+$ ]] || verify_s=3
    sleep 0.2
    while :; do
        after=$(tmux capture-pane -t "$tgt" -p -S -25 2>/dev/null) || after=""
        if [[ -n "$after" ]]; then
            case "$(printf '%s\n' "$after" | _unstick_ratelimit_menu_verdict)" in
                stop-highlighted|other-highlighted) ;;
                *) break ;;
            esac
        fi
        if (( waited >= verify_s * 2 )); then
            unstick_log "window=$window case=B action=cascade-refused reason=dismiss-unverified waited_s=$verify_s fp=$fp — the menu is still live (or the pane unreadable) after the dismiss Enter; NO paste (your-org/nexus-code#1739)"
            return 1
        fi
        sleep 0.5; waited=$(( waited + 1 ))
    done
    if declare -F pd_pane_verdict >/dev/null 2>&1; then
        pv=$(pd_pane_verdict "$window" before-paste)
        case "$pv" in
            held|draft)
                unstick_log "window=$window case=B action=cascade-refused reason=operator-draft stage=after-dismiss verdict=$pv fp=$fp — menu dismissed, but typed text is in the box; NO paste (your-org/nexus-code#1739)"
                return 1 ;;
            blocked)
                unstick_log "window=$window case=B action=cascade-refused reason=dismiss-unverified stage=pane-state verdict=blocked fp=$fp — pane-state still reads blocked; NO paste (your-org/nexus-code#1739)"
                return 1 ;;
        esac
    fi
    # Stamp BEFORE the paste (stamp-before-paste ordering — a paste
    # must never outrun its stamp, else the worker's UserPromptSubmit
    # races ahead of the ledger row and reads as an operator submit).
    # This is a watcher-initiated worker wake → machine attribution is
    # correct by construction (#293, gap row 7).
    _unstick_stamp_machine_input "$window" "unstick-ratelimit"
    local brief
    brief=$(_unstick_resume_brief "$reason")
    if ! _paste_line_to_window "$window" "$brief"; then
        unstick_log "window=$window case=B action=cascade-paste-failed fp=$fp"
        return 1
    fi
    printf '%s' "$fp" > "$UNSTICK_DIR/${window}.ratelimit.fp"
    printf '%d' "1" > "$UNSTICK_DIR/${window}.ratelimit.tries"
    unstick_log "window=$window case=B action=cascade-resumed fp=$fp${reason:+ trigger=$reason} audit=$(basename "$audit")"
    return 0
}

# The `input=` field pane-state reports for <window>, or `unknown`. Same reader
# rule as `pd_pane_verdict`: when `tmux` is a shell FUNCTION (a rig aimed at a
# private server) an external pane-state would read the LIVE board, so only an
# explicitly named PD_PANE_STATE_BIN is consulted then.
_unstick_pane_input() {
    local window="$1" bin="${PD_PANE_STATE_BIN:-}" line
    if [[ -z "$bin" ]]; then
        declare -F tmux >/dev/null 2>&1 && { printf 'unknown'; return 0; }
        bin="${NEXUS_ROOT:-}/monitor/pane-state.sh"
        [[ -x "$bin" ]] || bin="${BASH_SOURCE[0]%/*}/../pane-state.sh"
    fi
    [[ -x "$bin" ]] || { printf 'unknown'; return 0; }
    line=$("$bin" "$window" 2>/dev/null) || line=""
    if [[ " $line " =~ [[:space:]]input=([^[:space:]]+)[[:space:]] ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf 'unknown'
    fi
}

# The continuation brief pasted after a dismissed rate-limit menu. ONE line (the
# paste primitive submits one line). The re-check clause is the operator's ask on
# #1739: a worker stranded at the menu may have had Slurm jobs and watches finish
# unobserved, so "continue" alone resumes it on stale beliefs.
_unstick_resume_brief() {
    local reason="${1:-}"
    if [[ -n "$reason" ]]; then
        printf 'Please continue with your task. The API rate limit has reset (watcher saw a reset event: %s, e.g. a re-login or account switch). Re-check any jobs, watches and messages that may have finished while you were stopped, then continue.' "$reason"
    else
        printf 'Please continue with your task. The API rate limit has reset. Re-check any jobs, watches and messages that may have finished while you were stopped, then continue.'
    fi
}

# Send the orchestrator a heads-up about the cascade we just performed.
# The orchestrator is special: it doesn't need a "please continue"
# instruction — it needs a status update so it can verify each agent
# is making progress. We also ask the orchestrator to record the
# acknowledgement in the action-log so the watcher can confirm it is
# responsive (see _check_orchestrator_ack).
_cascade_heads_up_orchestrator() {
    local n="$1"; shift
    local target="${TARGET:-orchestrator}"
    local windows=("$@")
    if ! grep -qxF "$target" <<<"$(tmux list-windows -F '#{window_name}' 2>/dev/null)"; then
        unstick_log "case=B action=heads-up-skip target=$target reason=window-missing"
        return 1
    fi
    # THE PRE-ENTER IS NO LONGER BLIND (your-org/nexus-code#1598). It used to be
    # pressed unconditionally, "no-op if the orchestrator wasn't stuck" — true of
    # an EMPTY box only, and this is the pane the operator types into. Now: a
    # dismiss Enter only on a live menu whose highlighted row IS the Stop option,
    # read at this moment on the exact target.
    #
    # rc 2 = DEFERRED, distinct from rc 1 = failed: the caller parks the heads-up
    # in `ratelimit.headsup.pending` and `_retry_pending_heads_up` tries again
    # each cycle. Two things defer it, and neither gets a key or a paste:
    #   * a live menu with something ELSE highlighted — a human's decision;
    #   * typed text ALREADY in the input box (`held` / `draft`). It cannot be
    #     ours, we have pasted nothing yet; pasting would append the heads-up to
    #     the operator's draft and the primitive's first Enter would submit both.
    local tgt pane verdict
    tgt=$(_unstick_exact_target "$target")
    pane=$(tmux capture-pane -t "$tgt" -p -S -25 2>/dev/null) || pane=""
    # Same guard as the cascade (#1626, residual of your-org/nexus-code#1599):
    # a permission prompt on the orchestrator gets no pre-Enter and no paste.
    # DEFERRED, not failed — it is a human's decision, and the retry owns it.
    _unstick_pane_has_permission_prompt "$pane" && { [[ -n "${_UNSTICK_HEADSUP_QUIET:-}" ]] || unstick_log "case=B action=heads-up-deferred target=$target reason=permission-prompt n=$n — NO Enter, no paste: a live permission prompt is Case A's (your-org/nexus-code#1599)"; return 2; }
    verdict=$(printf '%s\n' "$pane" | _unstick_ratelimit_menu_verdict)
    case "$verdict" in
        stop-highlighted)
            tmux send-keys -t "$tgt" Enter 2>/dev/null || true
            sleep 0.2 ;;
        other-highlighted)
            [[ -n "${_UNSTICK_HEADSUP_QUIET:-}" ]] \
                || unstick_log "case=B action=heads-up-deferred target=$target reason=menu-other-highlighted n=$n — NO Enter: the menu's default is not the Stop option"
            return 2 ;;
    esac
    if declare -F pd_pane_verdict >/dev/null 2>&1; then
        case "$(pd_pane_verdict "$target" before-paste)" in   # a mid-turn draft too (#1683 F1)
            held|draft)
                [[ -n "${_UNSTICK_HEADSUP_QUIET:-}" ]] \
                    || unstick_log "case=B action=heads-up-deferred target=$target reason=operator-draft n=$n — typed text is already in the input box; no key, no paste"
                return 2 ;;
        esac
    fi
    local headsup
    headsup="Heads-up from watcher: rate limit reset; auto-unstuck ${n} agent window(s) (${windows[*]}). Verify each is making progress and re-dispatch if not. Then run: monitor/ng log-action monitor --event ratelimit-resume-ack --note \"saw heads-up\""
    if ! _paste_line_to_window "$target" "$headsup"; then
        unstick_log "case=B action=heads-up-failed target=$target n=$n"
        return 1
    fi
    unstick_log "case=B action=heads-up target=$target n=$n windows=${windows[*]}"
    return 0
}

# Decide whether to cascade now, wait for the reset, or skip because a
# previous cascade is still pending an ack. State is held in
# $UNSTICK_DIR:
#   ratelimit.reset.epoch   — Unix epoch when we expect the limit to
#                             reset (probed or heuristic). Cleared
#                             after a successful cascade.
#   ratelimit.cascade.epoch — Unix epoch of the most recent cascade.
#                             Cleared by _check_orchestrator_ack once
#                             the ack has landed (or the timeout
#                             fired).
#   ratelimit.last-wait.epoch — Throttle for waiting log-spam.
_act_ratelimit() {
    local windows=("$@")
    local reset_file="$UNSTICK_DIR/ratelimit.reset.epoch"
    local cascade_file="$UNSTICK_DIR/ratelimit.cascade.epoch"
    local wait_file="$UNSTICK_DIR/ratelimit.last-wait.epoch"
    local now
    now=$(date +%s)

    # If a previous cascade is still awaiting ack, don't double-fire.
    # _check_orchestrator_ack runs at the top of each detect_and_unstick
    # cycle and clears the marker.
    # …UNLESS a reset event (#1739) was consumed this cycle: every window on
    # this list is at the menu NOW, after the event, so it is owed a nudge
    # whatever an earlier cascade is still waiting for. The per-window re-read
    # in `_cascade_unstick_to_window` keeps that from double-acting on a pane.
    local event="${_UNSTICK_RESET_EVENT:-}"
    if [[ -f "$cascade_file" && -z "$event" ]]; then
        return 0
    fi

    # Determine reset epoch (cached or freshly probed).
    local reset_epoch=""
    [[ -f "$reset_file" ]] && reset_epoch=$(<"$reset_file")
    if [[ -n "$event" ]]; then
        unstick_log "case=B action=reset-epoch-expedited source=$event stored=${reset_epoch:-<none>} using=now count=${#windows[@]}"
        reset_epoch="$now"
        printf '%s\n' "$reset_epoch" > "$reset_file"
    fi
    if [[ -z "$reset_epoch" ]]; then
        local probed
        probed=$(_probe_ratelimit_reset)
        if [[ -n "$probed" ]]; then
            reset_epoch=$(date -d "$probed" +%s 2>/dev/null || true)
        fi
        if [[ -z "$reset_epoch" ]]; then
            local heur="${RATELIMIT_HEURISTIC_MIN:-30}"
            reset_epoch=$(( now + heur * 60 ))
            unstick_log "case=B action=schedule-cascade source=heuristic-${heur}min reset_epoch=$reset_epoch count=${#windows[@]}"
        else
            unstick_log "case=B action=schedule-cascade source=probe reset_iso=$probed reset_epoch=$reset_epoch count=${#windows[@]}"
        fi
        printf '%s\n' "$reset_epoch" > "$reset_file"
    fi

    # your-org/nexus-code#594 audit — THIRD instance of the class. This
    # gate defers the unstick cascade until a stored instant, and that
    # instant comes either from `_probe_ratelimit_reset` (an API-supplied
    # value nothing range-checks) or from a heuristic. Unlike the two
    # gates in _github.sh it is at least self-limiting — once `now`
    # passes it, the cascade fires — but nothing bounds how far into the
    # future the value may be, so one malformed `reset_at`, a clock
    # skew, or a cached file surviving from a previous epoch defers the
    # cascade arbitrarily. Clamp it: no cascade may be deferred longer
    # than the heuristic window, measured from NOW rather than from the
    # unverified stamp. A non-numeric or past value collapses to `now`,
    # which fires the cascade immediately — the safe direction, since
    # the cascade's own ack path handles a premature nudge but nothing
    # recovers a nudge that never fires.
    local _rl_max="${RATELIMIT_HEURISTIC_MIN:-30}"
    [[ "$_rl_max" =~ ^[0-9]+$ && "$_rl_max" -gt 0 ]] || _rl_max=30
    _rl_max=$(( _rl_max * 60 ))
    if [[ ! "$reset_epoch" =~ ^[0-9]+$ ]]; then
        unstick_log "case=B action=reset-epoch-reconciled reason=malformed stored=${reset_epoch:-<empty>} using=now"
        reset_epoch="$now"
        printf '%s\n' "$reset_epoch" > "$reset_file"
    elif (( reset_epoch > now + _rl_max )); then
        unstick_log "case=B action=reset-epoch-clamped stored=$reset_epoch clamped_to=$(( now + _rl_max )) ceiling_s=$_rl_max"
        reset_epoch=$(( now + _rl_max ))
        printf '%s\n' "$reset_epoch" > "$reset_file"
    fi

    if (( now < reset_epoch )); then
        local last_wait=0
        [[ -f "$wait_file" ]] && last_wait=$(<"$wait_file")
        # Throttle waiting-log lines to once per 5 minutes so a long
        # rate-limit window doesn't fill watcher-unstick.log.
        if (( now - last_wait >= 300 )); then
            unstick_log "case=B action=waiting reset_epoch=$reset_epoch remaining_s=$(( reset_epoch - now )) windows=${#windows[@]}"
            printf '%s' "$now" > "$wait_file"
        fi
        return 0
    fi

    # Reset has passed — perform the cascade.
    local target="${TARGET:-orchestrator}"
    local n=0
    local w
    for w in "${windows[@]}"; do
        # The orchestrator gets the heads-up, not the per-agent
        # "please continue" follow-up.
        [[ "$w" == "$target" ]] && continue
        if _cascade_unstick_to_window "$w" "$event"; then
            n=$(( n + 1 ))
        fi
    done
    local hrc=0
    _cascade_heads_up_orchestrator "$n" "${windows[@]}" || hrc=$?
    if (( hrc == 2 )); then
        # DEFERRED: no ack can be owed for a heads-up nobody has received, so the
        # cascade marker (which starts the ack clock) is NOT written yet.
        printf '%s\t%s\t%s\n' "$now" "$n" "${windows[*]}" > "$UNSTICK_DIR/ratelimit.headsup.pending"
    else
        printf '%s\n' "$now" > "$cascade_file"
    fi
    rm -f "$reset_file" "$wait_file"
    unstick_log "case=B action=cascade-complete unstuck=$n total_windows=${#windows[@]} target=$target"
}

# Retry a heads-up `_cascade_heads_up_orchestrator` deferred (rc 2). Runs at the
# top of every cycle. The give-up age is CHOSEN, not measured: 900 s is long
# enough for an operator to finish a draft and short enough that a stale "I just
# unstuck N windows" is not delivered into a board that has long since moved on.
#
# AN ABANDONED HEADS-UP ENDS THE EPISODE WITH THE ORCHESTRATOR UNINFORMED, and
# `case=B action=heads-up-abandoned` IS that episode's terminal record — not
# `orchestrator-unresponsive` (skeptic pastefusk F2, answered as a scoped
# refusal rather than a code change).
#
# Why not simply write `ratelimit.cascade.epoch` on the abandon branches so the
# ack machinery runs its course, as it did before this file grew a deferral:
# that marker starts an ACK CLOCK, and `_check_orchestrator_ack` would then log
# `orchestrator-unresponsive` for a heads-up NOBODY EVER SENT. That line names
# the orchestrator as the faulty party; emitting it here would be a false
# statement about it, and the operator-facing surface is exactly where a false
# attribution costs the most. No ack can be owed for an undelivered message.
#
# So the reachability change is REAL and deliberate: for an episode whose
# heads-up is abandoned, `orchestrator-unresponsive` is unreachable by
# construction. The replacement signal is strictly more informative — it names
# WHY the orchestrator was never told (`malformed-pending` / `deferred-too-long`,
# with the age and the ceiling) instead of asserting that it failed to answer.
_retry_pending_heads_up() {
    local pending="$UNSTICK_DIR/ratelimit.headsup.pending"
    [[ -f "$pending" ]] || return 0
    local p_epoch="" p_n="" p_windows="" now max rc=0
    IFS=$'\t' read -r p_epoch p_n p_windows < "$pending" || true
    now=$(date +%s)
    max="${RATELIMIT_HEADSUP_DEFER_MAX_S:-900}"
    [[ "$max" =~ ^[0-9]+$ ]] || max=900
    if ! [[ "$p_epoch" =~ ^[0-9]+$ && "$p_n" =~ ^[0-9]+$ ]]; then
        unstick_log "case=B action=heads-up-abandoned reason=malformed-pending — the orchestrator was NEVER told about this cascade; this line is the episode's terminal record, and orchestrator-unresponsive will not fire for it"
        rm -f "$pending"; return 0
    fi
    if (( now - p_epoch >= max )); then
        unstick_log "case=B action=heads-up-abandoned reason=deferred-too-long age_s=$(( now - p_epoch )) max_s=$max n=$p_n windows=$p_windows — the orchestrator was NEVER told about this cascade; this line is the episode's terminal record, and orchestrator-unresponsive will not fire for it"
        rm -f "$pending"; return 0
    fi
    local -a p_list=()
    read -r -a p_list <<<"$p_windows"
    # QUIET: the deferral was logged once, when it was parked.
    local _UNSTICK_HEADSUP_QUIET=1
    _cascade_heads_up_orchestrator "$p_n" "${p_list[@]}" || rc=$?
    (( rc == 2 )) && return 0
    # Delivered (0) or failed outright (1): either way it is no longer pending,
    # and the ack clock starts now — the same marker the undeferred path writes.
    rm -f "$pending"
    printf '%s\n' "$now" > "$UNSTICK_DIR/ratelimit.cascade.epoch"
    return 0
}

# ---- RESET EVENTS: a re-login lifts the limit before the epoch (#1739) ----
#
# Case B waits for a reset EPOCH (probed, else heuristic and clamped to
# RATELIMIT_HEURISTIC_MIN). Nothing invalidated that epoch when the limit was
# lifted some OTHER way. Measured 2026-10-04 (operator nexus, watcher-unstick.log):
# `proj-b7pot`/`proj-subreg` detected 21:37:23/21:37:35, cascade scheduled for
# 22:07:25 (heuristic 30 min); the operator switched account at ~21:45 and the
# orchestrator recovered through the over-limit path at 21:48:06, while both
# workers stayed at the menu until a human pressed Escape. (Bounded by the 30-min
# clamp, not "until Oct 7" — but every one of those minutes was a worker idle
# with its Slurm jobs finishing unobserved, and a stamped 21,835 s over-limit wake
# had no clamp at all.)
#
# A RESET EVENT runs the case-B cascade on the very cycle the event is consumed.
# A `credential-change` event ALSO releases every over-limit row (its stamp is
# moved aside and the row fails open at once if the pane still reads over-limit;
# see `_over_limit_expedite_all`). Other sources leave over-limit rows alone. Two
# sensors, and only two — each chosen for what its FALSE POSITIVE costs. A false
# event pastes a continuation into a still-limited worker, which re-hits the
# menu and starts a new episode: noise, never a lost worker. A MISSED event
# costs the old behaviour, the epoch path, which still runs.
#
#   credential-change  the logged-in IDENTITY changed: account uuid +
#                      organization uuid (`oauthAccount` in Claude Code's global
#                      config), counted only while the credential store shows a
#                      LOGIN — its `claudeAiOauth` object holds an `accessToken`
#                      KEY (jq `has()`: key presence, never the value). No token,
#                      refresh token or expiry is read out, compared or stored;
#                      the stored baseline is a sha1 of the uuids. expiresAt is
#                      deliberately not used: it moves on every routine refresh,
#                      and a re-login to the SAME account lifts no limit anyway.
#                      The store's subscriptionType/rateLimitTier are NOT in the
#                      tuple (#1741 S1 follow-up): they are optional on some login
#                      shapes, and requiring them would read "unknown" forever on
#                      such an account — a dead sensor that never says so.
#                      If EITHER file is unreadable, absent or torn, the account
#                      has no accountUuid, or the store shows no login, the
#                      signature is EMPTY, which is never a change in either
#                      direction (`could not look` is not `changed`; a
#                      half-tuple must not be compared, #1741 S1). Gated on the
#                      two files' mtime+size, so the (multi-MB) config file is
#                      parsed only when it was written.
#   over-limit-resumed a pane stamped over-limit was observed BUSY again — a
#                      fresh turn is running, so this account has quota.
#                      `_over_limit.sh` raises it through
#                      `_unstick_reset_event_signal`. `idle` resumptions are NOT
#                      a signal: a pane can stop reading over-limit by scrolling.
#
# REJECTED as a sensor, stated so nobody adds it back as the obvious one: the
# auth-hold `RELEASED` line. Its `kind=dialog` covers EVERY select dialog
# including this very rate-limit menu, so it fires whenever anyone presses Escape.
#
# THE EVENT IS A FILE (`ratelimit.reset-event`, `<epoch>\t<source>`) so a
# producer in another watcher task (over-limit wakes) and the consumer here
# (detect_unstick, 10 s cadence) need not share a process. Consumed once.

_unstick_cred_paths() {
    local cfg="${CLAUDE_CONFIG_DIR:-}"
    if [[ -n "$cfg" ]]; then
        printf '%s\n%s\n' "${UNSTICK_CRED_ACCOUNT_FILE:-$cfg/.claude.json}" \
            "${UNSTICK_CRED_STORE_FILE:-$cfg/.credentials.json}"
    else
        printf '%s\n%s\n' "${UNSTICK_CRED_ACCOUNT_FILE:-${HOME:-}/.claude.json}" \
            "${UNSTICK_CRED_STORE_FILE:-${HOME:-}/.claude/.credentials.json}"
    fi
}

# Identity signature on stdout (sha1 of the identity tuple), EMPTY when neither
# file yields an identity. Never prints a field value.
_unstick_cred_signature() {
    local acct store a="" c=""
    { IFS= read -r acct; IFS= read -r store; } < <(_unstick_cred_paths)
    command -v jq >/dev/null 2>&1 || return 0
    if [[ -r "$acct" ]]; then
        a=$(jq -r '[(.oauthAccount.accountUuid // ""), (.oauthAccount.organizationUuid // "")] | join("|")' "$acct" 2>/dev/null) || a=""
    fi
    if [[ -r "$store" ]]; then
        c=$(jq -r 'if ((.claudeAiOauth | type) == "object") and (.claudeAiOauth | has("accessToken")) then "login" else "" end' "$store" 2>/dev/null) || c=""
    fi
    # BOTH HALVES OR NOTHING (skeptic S1 on #1741). This used to return empty
    # only when BOTH were empty, so a ONE-SIDED read produced a signature over
    # half the tuple — a different value from the baseline — and raised a
    # credential-change for an identity that never changed. Measured by the
    # skeptic: 5 false events across logout + same-account login, a chmod 000
    # store, and a torn (mid-write) config. A half we could not read is
    # "could not look", which is never "changed": the account half needs its
    # accountUuid, the store half must show a login, and jq must have parsed
    # (a torn file is rc != 0, collapsed to empty above). Only the ACCOUNT half
    # enters the hash; the store half is a gate.
    [[ -n "${a%%|*}" && "$c" == login ]] || return 0
    printf '%s' "$a" | sha1sum | cut -c1-16
    return 0
}

# Raise a reset event. Callable from any watcher module; first writer wins
# until consumed (a second source in the same cycle adds nothing).
_unstick_reset_event_signal() {
    local source="${1:-unknown}" f
    [[ -n "${UNSTICK_DIR:-}" ]] || return 0
    f="$UNSTICK_DIR/ratelimit.reset-event"
    [[ -f "$f" ]] && return 0
    mkdir -p "$UNSTICK_DIR" 2>/dev/null || true
    printf '%s\t%s\n' "$(date +%s)" "${source//[$'\t\n']/_}" > "$f"
}

# The credential sensor: compare the identity signature with the stored
# baseline; raise `credential-change` when a known baseline is replaced by a
# DIFFERENT known one. The first sighting only records the baseline.
_unstick_cred_observe() {
    [[ "${UNSTICK_CRED_SENSOR:-true}" == true ]] || return 0
    local acct store gate_now gate_was="" sig old=""
    { IFS= read -r acct; IFS= read -r store; } < <(_unstick_cred_paths)
    gate_now="$(stat -c '%Y.%s' "$acct" 2>/dev/null)/$(stat -c '%Y.%s' "$store" 2>/dev/null)"
    local gate_f="$UNSTICK_DIR/credential.gate" sig_f="$UNSTICK_DIR/credential.sig"
    [[ -f "$gate_f" ]] && gate_was=$(<"$gate_f")
    [[ "$gate_now" == "$gate_was" && -f "$sig_f" ]] && return 0
    sig=$(_unstick_cred_signature)
    printf '%s' "$gate_now" > "$gate_f"
    [[ -n "$sig" ]] || return 0
    [[ -f "$sig_f" ]] && old=$(<"$sig_f")
    printf '%s' "$sig" > "$sig_f"
    if [[ -n "$old" && "$old" != "$sig" ]]; then
        unstick_log "case=B action=credential-change old_sig=$old new_sig=$sig — logged-in identity changed (re-login / account switch); raising a reset event (your-org/nexus-code#1739)"
        _unstick_reset_event_signal credential-change
    fi
}

# Consume a pending reset event: prints its source and expedites every
# over-limit wake stamp. rc 1 when there is none.
_unstick_reset_event_take() {
    local f="$UNSTICK_DIR/ratelimit.reset-event" ep="" src=""
    [[ -f "$f" ]] || return 1
    IFS=$'\t' read -r ep src < "$f" || true
    rm -f "$f"
    src="${src:-unknown}"
    local n=""
    if declare -F _over_limit_expedite_all >/dev/null 2>&1; then
        n=$(_over_limit_expedite_all "$src")
    fi
    unstick_log "case=B action=reset-event source=$src raised_epoch=${ep:-?} over_limit_expedited=${n:-n/a} — rate-limit menus are cascaded on this cycle (your-org/nexus-code#1739)"
    printf '%s' "$src"
}

# A reset epoch that has ELAPSED while nobody is stuck belongs to a finished
# episode. Left on disk it makes the NEXT episode cascade in the same second it
# is detected — "the limit has reset" pasted into a pane that has just hit it
# (measured 2026-09-19: written 04:08 for a window long gone, fired 15:36:44).
# A FUTURE epoch is kept: one cycle with no stuck window can be a failed capture,
# and an early clear would only push the cascade later.
_ratelimit_episode_over() {
    local reset_file="$UNSTICK_DIR/ratelimit.reset.epoch"
    [[ -f "$reset_file" && ! -f "$UNSTICK_DIR/ratelimit.cascade.epoch" ]] || return 0
    local e now
    e=$(<"$reset_file"); now=$(date +%s)
    if ! [[ "$e" =~ ^[0-9]+$ ]] || (( e <= now )); then
        unstick_log "case=B action=episode-ended reason=no-stuck-window stale_reset_epoch=${e:-<empty>}"
        rm -f "$reset_file" "$UNSTICK_DIR/ratelimit.last-wait.epoch"
    fi
}

# Verify the orchestrator acknowledged the most recent cascade by
# checking action-log.jsonl for a `ratelimit-resume-ack` event with a
# timestamp newer than the cascade. Cleans up the cascade marker once
# the ack lands or the timeout fires.
_check_orchestrator_ack() {
    local cascade_file="$UNSTICK_DIR/ratelimit.cascade.epoch"
    [[ -f "$cascade_file" ]] || return 0
    local cascade_epoch
    cascade_epoch=$(<"$cascade_file")
    if ! [[ "$cascade_epoch" =~ ^[0-9]+$ ]]; then
        rm -f "$cascade_file"
        return 0
    fi
    local now
    now=$(date +%s)
    local age=$(( now - cascade_epoch ))
    local ack_log="${ACTION_LOG:-}"
    if [[ -n "$ack_log" && -f "$ack_log" ]] && command -v jq >/dev/null 2>&1; then
        local newest_ack_ts
        newest_ack_ts=$(jq -r 'select(.event == "ratelimit-resume-ack") | .ts' "$ack_log" 2>/dev/null | tail -1)
        if [[ -n "$newest_ack_ts" ]]; then
            local newest_ack_epoch
            newest_ack_epoch=$(date -d "$newest_ack_ts" +%s 2>/dev/null || echo 0)
            if (( newest_ack_epoch > cascade_epoch )); then
                unstick_log "case=B action=orchestrator-ack ack_ts=$newest_ack_ts latency_s=$age"
                rm -f "$cascade_file"
                return 0
            fi
        fi
    fi
    local timeout="${RATELIMIT_ACK_TIMEOUT_S:-60}"
    if (( age >= timeout )); then
        unstick_log "case=B action=orchestrator-unresponsive cascade_age_s=$age timeout_s=$timeout"
        rm -f "$cascade_file"
        return 0
    fi
}

detect_and_unstick() {
    [[ "${AUTO_UNSTICK,,}" == "true" ]] || return 0
    command -v tmux >/dev/null 2>&1 || return 0
    _check_orchestrator_ack
    _retry_pending_heads_up
    _unstick_cred_observe
    local _UNSTICK_RESET_EVENT=""
    _UNSTICK_RESET_EVENT=$(_unstick_reset_event_take) || _UNSTICK_RESET_EVENT=""
    local windows
    windows=$(tmux list-windows -F '#{window_name}' 2>/dev/null) || return 0
    local -a ratelimit_windows=()
    local case_key
    while IFS= read -r w; do
        [[ -z "$w" ]] && continue
        case_key=$(_handle_unstick_window "$w") || true
        if [[ "$case_key" == "ratelimit" ]]; then
            ratelimit_windows+=("$w")
        fi
    done <<<"$windows"
    if (( ${#ratelimit_windows[@]} > 0 )); then
        _act_ratelimit "${ratelimit_windows[@]}"
    else
        _ratelimit_episode_over
    fi
}
