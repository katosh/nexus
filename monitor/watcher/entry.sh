#!/usr/bin/env bash
# Nexus — user-facing entry point for the whole stack.
#
# Invoked by the user as the foreground command of a fresh inner-tmux
# session created by agent-sandbox:
#
#   cd /path/to/nexus && agent-sandbox tmux new-session ./watcher [--continue]
#
# The top-level `./watcher` symlink (and its alias `./nexus`) point
# here; all forms are equivalent. Since the headless-services cutover
# (your-org/nexus-code#238) the watcher no longer lives in a tmux
# window — it runs as a setsid-detached service supervised via a
# pidfile + heartbeat, and it (not this script) owns the
# orchestrator's spawn and revival. This script does four things, in
# order:
#
#   1. Self-checks: verify the script is running inside tmux AND
#      inside the agent-sandbox. Either failure prints a clear fix
#      hint and exits non-zero. tmux is needed because the watcher
#      pastes into the orchestrator window and spawns it there;
#      agent-sandbox confines the Claude Code sessions' writes.
#
#   2. Resume-intent reconciliation: decide whether the WORKSPACE the
#      watcher is about to bring up should be FRESH (default) or should
#      RESUME the prior work (`--continue`). Two state files carry that
#      one decision to the two independent things that act on it — the
#      orchestrator session pin, and the boot-intent file that governs
#      the worker walk (see "boot-intent handoff" below,
#      your-org/nexus-code#651). For the orchestrator the mechanism
#      is the orchestrator session-id pin
#      (`monitor/.state/orchestrator-session-id`) — the exact state
#      file the watcher's spawn path reads (`_respawn_choose_resume_
#      mode` in `_respawn.sh`: valid pin -> `claude --resume <sid>`,
#      missing/stale pin -> deterministic cold spawn). The pin is a
#      plain state file, so the intent survives watcher restarts.
#        - default: a fresh boot is requested, so an existing pin is
#          archived to `orchestrator-session-id.archived.<epoch>`
#          (recoverable, never deleted) and the watcher cold-boots a
#          fresh orchestrator.
#        - `--continue`: the pin is left in place; the watcher
#          resumes the EXACT pinned session via `claude --resume`.
#          If the pin is missing or stale, the watcher spawns fresh —
#          it never falls back to `claude --continue`, because
#          resuming the arbitrary freshest jsonl resurrected a
#          transient recovery session in the 2026-05-29 incident
#          (issue 200). This narrows the historical `--continue`
#          contract from "most recent jsonl" to "pinned orchestrator
#          session", which is strictly safer and deterministic.
#      Skipped entirely when the orchestrator window is already
#      alive — the flag is moot, the live session's pin must not be
#      touched, and a live board must not be torn down by what is an
#      idempotent bring-up.
#      The WORKER half is the boot-intent file
#      (`monitor/.state/boot-intent`, `mode=fresh|continue`), consumed
#      once by `monitor/bootstrap-recover.sh`. Without it a cold boot
#      resurrected every worker that was alive before — on 2026-07-30
#      that turned one sandbox-killing worker into a self-sustaining
#      outage loop, since each ~3-minute death faithfully brought its
#      own killer back.
#
#   3. Stack bring-up: delegate to `monitor/svc.sh up` (which
#      delegates to `monitor/bootstrap-recover.sh`) — the same
#      idempotent whole-stack path used for recovery. It launches the
#      headless watcher (via `watcher/launcher.sh`) iff it isn't
#      already healthy, plus every service registered in
#      `monitor/services.registry`. The watcher then spawns the
#      orchestrator via its own target-absent machinery (within a few
#      probe cycles, ~10 s) — nothing here spawns claude directly.
#      Re-running this script against a healthy stack is a no-op
#      bring-up plus the cockpit; the one-watcher guard lives in
#      `launcher.sh` (pidfile identity check), not here.
#
#   4. Become the cockpit: rename the invoking window to `services`
#      and exec the read-only `monitor/svc.sh` dashboard in it, so
#      the operator lands on the live stack view (watcher +
#      orchestrator + registry services, single-key log tails)
#      instead of a dead shell.
#
# Day-to-day surface after boot: `monitor/svc.sh status|up|logs`,
# `monitor/ng watcher-status`. Watcher log:
# `monitor/.state/watcher.log` (cockpit key `0`).
#
# Crash-loop guard: orchestrator respawns are owned by the watcher;
# if the window dies faster than `monitor.respawn_loop_window_seconds`
# more than `monitor.respawn_loop_limit` times, the watcher stops
# respawning, logs a wedge, and notifies the operator. See
# main.sh / _target_absent.sh.
#
# Flags:
#   --continue            resume the prior workspace: keep the
#                         orchestrator session-id pin so the watcher
#                         resumes the pinned session (`claude --resume
#                         <sid>`; without a valid pin it spawns fresh),
#                         AND record `mode=continue` in the boot-intent
#                         file so bootstrap-recover resumes the prior
#                         worker agents. Omitting it is a genuinely COLD
#                         boot of the WHOLE workspace: no orchestrator
#                         resume, no worker resurrection, and a
#                         dropped-worker manifest handed to the
#                         orchestrator on its first turn.
#   --i-accept-no-sandbox start even when NOT inside the agent-sandbox,
#                         accepting the loss of kernel-enforced
#                         isolation (a runaway agent can then write
#                         anywhere your user can). Default is to REFUSE
#                         outside the sandbox. Acceptance is recorded in
#                         monitor/.state/no-sandbox-accepted so self-heal
#                         relaunches inherit it. Irrelevant in-sandbox.
#   -h / --help           print this header.

set -uo pipefail

_script_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
_monitor_dir=$(cd "$_script_dir/.." && pwd)
_nexus_root=$(cd "$_monitor_dir/.." && pwd)
_cfg="$_nexus_root/config/load.sh"

# Public-template disable switch — refuse to start unless the operator
# has flipped NEXUS_PUBLIC_ENABLED=1. Earliest common start path; must
# come before any bring-up work. See monitor/_public-guard.sh.
# shellcheck source=../_public-guard.sh
source "$_monitor_dir/_public-guard.sh"
nexus_public_guard

# Wrong-launch guard helpers (cockpit peer scan + window probes) —
# side-effect-free, safe under set -uo pipefail.
# shellcheck source=_lib.sh
source "$_script_dir/_lib.sh"

CONTINUE=0
IACCEPT_NO_SANDBOX=0
while (( $# > 0 )); do
    case "$1" in
        --continue) CONTINUE=1; shift ;;
        --i-accept-no-sandbox) IACCEPT_NO_SANDBOX=1; shift ;;
        -h|--help)  sed -n '2,108p' "$0"; exit 0 ;;
        *) echo "watcher: unknown flag: $1" >&2; exit 1 ;;
    esac
done

# --- self-checks ----------------------------------------------------------

if [[ -z "${TMUX:-}" ]]; then
    cat >&2 <<'ERR'
watcher: not running inside a tmux session.

Fix:
  cd /path/to/nexus
  agent-sandbox tmux new-session ./watcher

The watcher needs tmux to spawn the orchestrator window and to
receive state-change pastes from the user side.
ERR
    exit 2
fi

# Agent-sandbox gate (your-org/nexus-code#350). In-sandbox: start
# normally (the markers SANDBOX_ACTIVE=1 / SANDBOX_PROJECT_DIR are set
# by the sandbox at session creation). Out-of-sandbox: REFUSE unless the
# operator passed --i-accept-no-sandbox (or a prior acceptance marker
# exists), accepting the loss of kernel-enforced isolation. The decision
# + messaging + marker persistence live in `_nexus_sandbox_gate`
# (_lib.sh, already sourced above) so entry.sh and the watcher launcher
# enforce identical semantics. The marker the gate writes is what the
# launcher (re-run by svc.sh up / self-heal without the flag) reads.
if ! _nexus_sandbox_gate "$_nexus_root/monitor/.state" "$IACCEPT_NO_SANDBOX" "watcher"; then
    exit 2
fi

# --- capture own window id ------------------------------------------------

# Resolve the calling pane's window id NOW, before anything else can
# change the session's active window. Un-targeted `tmux rename-window`
# defaults to the session's ACTIVE window (not the calling pane's), so
# the final cockpit rename below must target this id explicitly —
# otherwise any focus flip in between (operator keystroke, the
# watcher's own spawn activity) shifts the rename onto the wrong
# window. Same hardening the pre-cutover entry.sh carried (PR #117).
own_pane="${TMUX_PANE:-}"
if [[ -z "$own_pane" ]]; then
    echo "watcher: TMUX_PANE not set inside tmux — refusing to guess own window" >&2
    exit 2
fi
OWN_WINDOW_ID=$(tmux display -p -t "$own_pane" '#{window_id}' 2>/dev/null)
if [[ -z "$OWN_WINDOW_ID" ]]; then
    echo "watcher: failed to resolve own window id via TMUX_PANE=$own_pane" >&2
    exit 2
fi

# --- resume-intent reconciliation -----------------------------------------

TARGET="$("$_cfg" monitor.target_window orchestrator)"; _target_rc=$?
# CONSULT THE rc, AND REFUSE AN EMPTY VALUE (your-org/nexus-code#1093).
# `$TARGET` is the needle of the boot-detection test at the `grep -qxF` below,
# and an empty needle there fails OPEN in a way `-x` normally prevents:
# `grep -qxF ""` does NOT match `orchestrator\nemptyneedle`, but a HERE-STRING
# on an EMPTY command substitution supplies ONE EMPTY LINE — so when tmux fails
# or the server is absent, the empty needle matches that manufactured line and
# `orch_present=1`. "Is the orchestrator here?" is then answered PRESENT on no
# evidence, and a broken environment is exactly when entry.sh runs.
#
# Both routes to an empty TARGET are MEASURED, not hypothesised, and the first
# is the one an unconsulted rc cannot even see:
#   * `monitor: {target_window: ""}` in config/nexus.yml -> rc 0, empty stdout.
#     A key present-but-empty is a config typo, and load.sh's default only
#     covers a MISSING key, so nothing downstream is loud.
#   * no config found at all -> rc 1, empty stdout, diagnostic on stderr.
# Before this, `$?` was discarded on the same line it was produced — CLAUDE.md's
# `fromisoformat` mode 2: the error is not lost, it is merely off the path that
# produces the answer.
#
# REFUSING (rather than falling back to `orchestrator`) is this repo's settled
# policy for this exact value: launcher.sh:113 already exits 2 on `--target ""`
# rather than substituting its default, and test-launcher-empty-target.sh pins
# that. A watcher that guesses its own cockpit's name is worse than one that
# stops.
if (( _target_rc != 0 )) || [[ -z "$TARGET" ]]; then
    echo "watcher: monitor.target_window resolved EMPTY (config read rc=$_target_rc) —" \
         "refusing to boot rather than guess. An empty window name makes the" \
         "orchestrator-present test below match a here-string's manufactured empty" \
         "line and report PRESENT on no evidence (your-org/nexus-code#1093)." >&2
    exit 2
fi
# Cockpit window name — config-resolved so the rename here, the idle-probe
# exemption, svc.sh, and bootstrap-recover all track one value
# (your-org/your-nexus#204). Env override: MONITOR_SERVICES_WINDOW.
SERVICES_WINDOW="${MONITOR_SERVICES_WINDOW:-$("$_cfg" monitor.services_window services)}"
PIN_FILE="$_nexus_root/monitor/.state/orchestrator-session-id"
BOOT_INTENT_FILE="$_nexus_root/monitor/.state/boot-intent"

# Hand the fresh-vs-continue intent to the WORKER walk (your-org/
# nexus-code#651). The pin reconciliation below covers the orchestrator
# and nothing else; every worker agent that was alive before is
# resurrected independently, by `monitor/bootstrap-recover.sh`'s worker
# step (issue #197), which runs long after this script has exited —
# `svc.sh up` -> `bootstrap-recover.sh` -> `spawn-worker.sh --resume`.
# A shell variable cannot cross that hop, so the intent is handed over as
# a plain STATE FILE next to the pin, in the same spirit and under the
# same archive-never-delete convention.
#
#   mode=fresh     cold boot — bootstrap-recover must resurrect NOTHING,
#                  archive the prior worker state, and leave the incoming
#                  orchestrator a manifest of what it dropped.
#   mode=continue  `--continue` — today's resume behaviour, unchanged.
#
# The file is ONE-SHOT: bootstrap-recover archives it to
# `boot-intent.archived.<epoch>` the moment it acts on it. That matters
# because bootstrap-recover is ALSO the ordinary crash-recovery path (the
# SessionStart hook, `bootstrap.sh`'s per-turn refresh, `svc.sh up`); an
# intent left lying around would turn every later mid-life recovery into
# a worker massacre. It carries a timestamp for the same reason from the
# other side — an intent whose boot never reached the worker walk expires
# instead of firing days later.
_write_boot_intent() {
    local mode="$1"
    mkdir -p "$(dirname "$BOOT_INTENT_FILE")" 2>/dev/null || true
    if printf 'mode=%s\nts=%s\nsource=entry.sh\npid=%s\n' \
            "$mode" "$(date +%s)" "$$" > "$BOOT_INTENT_FILE" 2>/dev/null; then
        return 0
    fi
    echo "watcher: WARNING: could not write the boot-intent file at $BOOT_INTENT_FILE — the stack bring-up will fall back to its default (resume prior workers)" >&2
    return 1
}

# Wrong-window guard (issue #203 follow-up, 2026-06-11 incident class).
# This script ends by RENAMING its own window to '$SERVICES_WINDOW' and
# exec'ing the cockpit. Invoked from a pane inside the orchestrator's
# window — an operator typing ./watcher into a recovered pane, or the
# orchestrator's own Bash tool (which inherits TMUX_PANE from claude) —
# that rename would vaporise the '$TARGET' name (watcher: absent →
# kill-then-spawn) and plant a cockpit where the agent lived. Refuse
# up front, before the resume-intent logic can archive the session pin.
OWN_WINDOW_NAME=$(tmux display -p -t "$own_pane" '#{window_name}' 2>/dev/null)
if [[ "$OWN_WINDOW_NAME" == "$TARGET" ]]; then
    cat >&2 <<ERR
watcher: REFUSING to run from inside the '$TARGET' window.

This script would rename this window to '$SERVICES_WINDOW' and replace it
with the service cockpit — destroying the orchestrator's window name and
triggering a watcher kill-then-respawn of whatever lives here.

Fix: switch to (or create) another window and run it there:
  tmux new-window -c $_nexus_root
  ./watcher
ERR
    exit 2
fi

# Boot-vs-bring-up is decided by AGENT LIVENESS, not by a window name
# (your-org/nexus-code#651 skeptic, finding 1). `_respawn.sh` sets
# `remain-on-exit on`, so a claude that segfaults, OOMs, is `/exit`ed, or
# wedges-then-dies leaves its window LISTED with a dead pane — and reading that
# corpse as a running supervisor is what made `./watcher` skip this whole
# reconciliation and resurrect the entire worker board, in the COMMONEST crash
# shape and the one the operator actually hit. Same class as `#643`.
#
# The predicate lives in `_lib.sh` as `_nexus_window_has_live_agent` (sourced
# at the top of this script) because `bootstrap-recover.sh` needs the identical
# judgement when it partitions the cold-boot manifest into dropped-vs-still-
# running. One definition, so the two can never disagree about "alive".
# Its fail-safe direction is LIVE and its contract is "only ask about a window
# you know exists" — hence the `&&` composition below.

orch_present=0
if grep -qxF "$TARGET" <<<"$(tmux list-windows -F '#{window_name}' 2>/dev/null)"; then
    orch_present=1
fi

# "Is this a boot?" is ONE question, and it is answered by liveness, not by a
# window name. Conflating the two is what produced finding 1 — and answering it
# differently for the pin and for the worker intent would re-introduce exactly
# the two-decisions-from-one-flag confusion this whole change exists to remove.
# So a `remain-on-exit` corpse counts as ABSENT for both halves: on a default
# boot its pin is archived (the operator asked for a fresh orchestrator) and the
# fresh boot-intent is written (they asked for no resurrection).
orch_live=0
if (( orch_present == 1 )) && _nexus_window_has_live_agent "$TARGET"; then
    orch_live=1
fi
if (( orch_present == 1 && orch_live == 0 )); then
    echo "watcher: a window named '$TARGET' exists but holds NO live agent (dead pane / no claude in its process tree) — treating this as a genuine boot, not an idempotent bring-up. \`remain-on-exit\` leaves a crashed orchestrator's window listed; its presence is not evidence of life (your-org/nexus-code#651)" >&2
fi

if (( orch_live == 1 )); then
    # A LIVE orchestrator means no cold spawn will happen; the flag (either
    # way) must not touch the pin, which names the LIVE session and is what
    # makes the watcher's next respawn deterministic.
    # The boot-intent file is left untouched for the same reason: this is not
    # a boot. Re-running `./watcher` against a live orchestrator is an
    # idempotent bring-up, and writing `mode=fresh` would drop the worker
    # board out from under a running supervisor — a destructive reading of
    # what is meant to be a no-op. Note the gate is `orch_live`, NOT
    # `orch_present`: see `_nexus_window_has_live_agent` (_lib.sh) for why a window
    # name cannot answer this.
    if (( CONTINUE == 1 )); then
        echo "watcher: orchestrator window '$TARGET' already alive — --continue has no effect" >&2
    else
        echo "watcher: orchestrator window '$TARGET' already alive — no spawn, pin untouched, worker resume behaviour unchanged (re-running ./watcher on a live stack is an idempotent bring-up, not a boot)" >&2
    fi
else
    # The watcher's cold-boot spawn reads the pin via
    # `_respawn_choose_resume_mode` (_respawn.sh). Sourced here only
    # to REPORT what the watcher will decide — the decision itself is
    # the watcher's. Guarded: a partial deploy missing _respawn.sh
    # degrades to pin-existence messaging.
    _have_resolver=0
    if [[ -f "$_script_dir/_respawn.sh" ]]; then
        # shellcheck disable=SC1091
        . "$_script_dir/_respawn.sh"
        _have_resolver=1
    fi
    # Worker-side intent, written for BOTH modes so the worker walk never
    # has to infer it from the pin's absence (a missing pin is also what a
    # never-yet-run nexus looks like).
    if (( CONTINUE == 1 )); then
        if _write_boot_intent continue; then
            echo "watcher: --continue — worker agents alive in the last snapshot will be resumed by the stack bring-up" >&2
        fi
    else
        if _write_boot_intent fresh; then
            echo "watcher: fresh boot (default) — NO worker agent will be resumed; the prior worker state is archived and the incoming orchestrator is handed a manifest of what was dropped. Pass --continue to resume instead" >&2
        fi
    fi
    if (( CONTINUE == 1 )); then
        if (( _have_resolver == 1 )); then
            _choice=$(_respawn_choose_resume_mode "$_nexus_root")
            _mode="${_choice%%$'\t'*}"
            _sid="${_choice#*$'\t'}"
            if [[ "$_mode" == "resume" ]]; then
                echo "watcher: --continue — pin valid; the watcher will resume the pinned session (claude --resume $_sid)" >&2
            else
                echo "watcher: --continue requested but the session pin at $PIN_FILE is missing or stale — the watcher will spawn a FRESH orchestrator (it never resumes an unpinned session; issue 200)" >&2
            fi
        else
            echo "watcher: --continue — pin left in place at $PIN_FILE (resolver _respawn.sh missing; the watcher decides resume-vs-fresh from it)" >&2
        fi
    else
        # Fresh boot requested (the default, matching the historical
        # contract). Archive — never delete — an existing pin so the
        # watcher's spawn degrades to a deterministic cold start. If
        # an orchestrator process is actually alive behind a renamed
        # window, the watcher's pre-spawn re-verification heals the
        # rename and aborts the spawn, and the session-pin hook
        # re-writes the pin on its next turn — archiving here is safe.
        if [[ -f "$PIN_FILE" ]]; then
            archived="$PIN_FILE.archived.$(date +%s)"
            if mv -f "$PIN_FILE" "$archived" 2>/dev/null; then
                echo "watcher: fresh boot (default) — archived prior session pin to $(basename "$archived"); pass --continue to resume instead" >&2
            else
                echo "watcher: warning: failed to archive $PIN_FILE — the watcher may resume the pinned session instead of spawning fresh" >&2
            fi
        else
            echo "watcher: fresh boot (default) — no prior session pin; the watcher will spawn a fresh orchestrator" >&2
        fi
    fi
fi

# --- stack bring-up (delegated) -------------------------------------------

# `svc.sh up` -> `bootstrap-recover.sh`: idempotent watcher + services
# recovery. svc.sh defaults NEXUS_ROOT to the operator's live tree, so
# export THIS tree explicitly — entry.sh must bring up the checkout it
# lives in. The watcher spawns the orchestrator window itself within a
# few target-absent probe cycles (~10 s); `up` never spawns it directly.
export NEXUS_ROOT="$_nexus_root"

# Single-nexus-instance gate — BEFORE we bring up anything. `svc.sh up`
# spawns the watcher, orchestrator, AND services; the watcher's own flock
# refuses a same-host peer, but bootstrap-recover would still spawn a second
# orchestrator + services alongside it (the flock guards only the watcher).
# And flock over NFSv3 does not reliably arbitrate cross-CLIENT, so a peer on
# ANOTHER host sharing this state dir would not be caught by the flock at all.
# Gate the whole bring-up here on the combined guard (same-host flock +
# cross-host heartbeat), with a self-exemption (same host + pid namespace) so
# re-entering our OWN cockpit still recovers. A different cockpit — co-located
# sandbox or another host — refuses loudly and points at the live instance.
if ! _nexus_instance_preflight "$_nexus_root/monitor/.state" "$_nexus_root"; then
    echo "watcher: not starting a second nexus in this directory — see the refusal above." >&2
    exit 3
fi

echo "watcher: bringing up the stack via monitor/svc.sh up (headless watcher + registry services)" >&2
if ! "$_monitor_dir/svc.sh" up; then
    echo "watcher: WARNING: 'svc.sh up' exited non-zero — landing in the cockpit so you can inspect (key 0 tails the watcher log)" >&2
fi

# Observe convergence before declaring the stack up. `svc.sh up` returns
# as soon as it has LAUNCHED the watcher + services; the orchestrator
# window appears a few probe cycles later (~10s). Poll the three
# components (watcher heartbeat fresh, orchestrator window present,
# registry services healthy) so the operator lands in the cockpit on an
# already-running stack rather than guessing whether it came up
# (your-org/nexus-code#313 item 4). Non-fatal: a timeout still drops into
# the cockpit, which shows the live state and the verify diagnostics.
echo "watcher: waiting for the stack to converge (watcher + orchestrator + services)..." >&2
if "$_script_dir/verify-stack.sh"; then
    echo "watcher: stack is up — opening the cockpit." >&2
else
    echo "watcher: stack not fully converged yet — landing in the cockpit to inspect (key 0 tails the watcher log; the orchestrator may still be spawning)." >&2
fi

# --- become the cockpit -----------------------------------------------------

# A live cockpit elsewhere means becoming a second one would just be
# refused by svc.sh's own peer guard AFTER we renamed this window to
# '$SERVICES_WINDOW' — leaving a confusingly-named dead window behind.
# Check first: point the operator at the existing cockpit and exit
# cleanly (the stack bring-up above already did its job).
if _peer=$(_nexus_find_live_cockpit_pane "$own_pane"); then
    IFS=$'\t' read -r _peer_pid _peer_win _peer_name <<<"$_peer"
    echo "watcher: stack is up; a service cockpit is already running in tmux window '$_peer_name' ($_peer_win) — not starting a second one. Switch there for the live view." >&2
    exit 0
fi

# Land the operator on the live stack view. Rename targets the window
# id captured at the top of the script (see comment there), then exec
# replaces this shell with the read-only dashboard — quitting it (q)
# leaves a plain shell-less window; the stack itself is unaffected
# (the watcher and services are setsid-detached).
tmux rename-window -t "$OWN_WINDOW_ID" "$SERVICES_WINDOW" 2>/dev/null || true
echo "watcher: opening the service cockpit (q quits the view; the stack keeps running)" >&2
exec "$_monitor_dir/svc.sh"
