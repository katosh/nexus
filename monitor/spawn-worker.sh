#!/bin/bash
# monitor/spawn-worker.sh — launch a tmux worker with the worker floor injected.
#
# Usage: monitor/spawn-worker.sh -n <window-name> -c <workdir> -p <prompt-file>
#                                [-r <prior-report-path>] [--print-prompt]
#        monitor/spawn-worker.sh --resume <window-name | session-id>
#                                [-n <window-name>] [-c <workdir>]
#                                [--replace] [--dry-run]
#
# Reads the "## Worker floor" section from
#     $NEXUS_ROOT/skills/nexus.worker-defaults/SKILL.md
# (NEXUS_ROOT resolved from this script's location, so it works in forks and
# fresh clones), prepends a "## Worker environment" block with absolute paths
# (workdir, nexus root, reports dir) plus the floor body to <prompt-file> with
# "---" separators, generates a self-cleaning launcher in /tmp, and creates a
# detached tmux window using the nexus.tmux-spawn pattern (separate new-window
# + send-keys, -d for non-stealing focus, -c for workdir).
#
# Per-spawn Claude Code settings: every spawn invokes claude with
# `--settings $NEXUS_ROOT/monitor/worker-settings.json`. That file
# carries the hooks block (heartbeat + notification + user-prompt) AND
# `skipDangerousModePermissionPrompt: true` so the bypass-permissions
# startup dialog never renders for workers. Edit the JSON file
# directly; no marker-extraction dance, no per-spawn tmp file. See
# `monitor/worker-settings.json` for the schema and the
# `## Worker settings` pointer in skills/nexus.worker-defaults/SKILL.md.
#
# Window-name pinning: every spawned window has tmux `automatic-rename`
# AND `allow-rename` set to `off`. Without that, dead worker panes
# (kept around by `remain-on-exit on`) get retitled by tmux or by OSC
# escape sequences emitted from inside the pane (Claude Code, shell)
# — most visibly to `•bell`, a transient bullet-prefixed name that
# used to pollute the watcher's tmux snapshot diff with ~13 lines of
# context noise per cycle. The orchestrator window has the same
# pinning via monitor/hooks/orchestrator-session-pin.sh.
#
# -r <prior-report-path> inlines the named report as a "Prior context" section
# between the worker environment block and the worker floor. The orchestrator
# uses this when a new spawn continues a previous worker's thread but cannot
# (or should not) `claude --continue` against the retained worker — fresh
# context window, but with the prior wrap-up's What Was Done / Current State /
# How to Resume already in front of the worker. See
# skills/nexus.window-cleanup/SKILL.md "Continue-vs-spawn" for the decision
# criteria. Path may be relative to $NEXUS_ROOT or absolute.
#
# --print-prompt emits the composed prompt to stdout and exits without
# spawning. Useful for testing the prompt-composition logic without touching
# tmux.
#
# --resume <window-name | session-id> is the canonical RESPAWN mode: it
# re-attaches a wrapped/closed worker's Claude Code session in a tmux
# window with the SAME wiring a fresh spawn gets — exported NEXUS_ROOT +
# NEXUS_WORKER_WINDOW (every hook in worker-settings.json depends on
# both), `--settings $NEXUS_ROOT/monitor/worker-settings.json`,
# `--dangerously-skip-permissions`, the resolved $CLAUDE_BIN, the tmux
# window options (remain-on-exit / automatic-rename / allow-rename), the
# `-c <workdir>` + redundant-cd cwd pin, and the lifecycle anchors
# (engagement-log row + `spawn` action-log event, tagged mode=resume).
# Hand-rolling `tmux new-window … claude --resume <id>` instead loses
# the env exports and every worker hook fails with
# `/bin/sh: /monitor/worker-heartbeat.sh: not found` on each tool use.
#
# Resume resolution (no UUID hunting):
#   session-id, when the target is a window name —
#     1. newest reports/*.md whose frontmatter `window:` matches
#        (its `session-id:` field; "unknown" is skipped);
#     2. newest `window-close` action-log event for the window
#        (the close protocol records `session-id=`);
#     3. the window's heartbeat (`monitor/.state/heartbeat/
#        <window>.json` `session_id` — claude's own hook payload,
#        stamped per tool use by worker-heartbeat.sh);
#     4. newest `spawn` action-log event carrying a `session-id=`
#        extra (resume-mode respawns always record it; fresh spawns
#        stamp a generated `--session-id` since your-nexus#206);
#     5. freshest <uuid>.jsonl under ~/.claude/projects/<workdir-slug>/
#        where <slug> turns EVERY non-alphanumeric char into '-'
#        ('/' AND '_' alike: group → your-lab-m).
#     A target matching the UUID shape is taken as an explicit
#     session-id override (then -n is required).
#
#   Coordinator-exclusion rule (your-org/your-nexus#206): a window
#   that is not the coordinator target (`monitor.target_window`,
#   default `orchestrator`) may NEVER resolve to the pinned
#   orchestrator session-id (`monitor/.state/orchestrator-session-id`)
#   — every source above skips such a candidate loudly, and the
#   freshest-jsonl fallback (5) is refused OUTRIGHT for a
#   non-coordinator window whose workdir shares the coordinator's
#   project slug (a `-c <nexus-root>` worker), because recency in a
#   shared project dir proves nothing — the freshest jsonl there is
#   typically the live orchestrator's, and resuming it spawned a
#   duplicate orchestrator in the 2026-06-11 incident. An explicit
#   session-id override equal to the pinned sid is likewise refused
#   (exit 14) unless -n names the coordinator window.
#   workdir, unless -c is given —
#     1. live tmux pane's #{pane_current_path} (window still exists);
#     2. newest `window-close` / `spawn` action-log event `workdir=`;
#     3. `- Workdir:` line of monitor/.state/spawn-prompts/<window>.txt.
#   Both fail loud (exit 11 / 12) when nothing resolves; the resolved
#   transcript must exist on disk or the resume aborts (exit 11).
#
# Window states: an existing window with a DEAD pane (remain-on-exit
# leftover) is killed and recreated automatically; a LIVE pane is
# refused unless --replace (paste a follow-up into a live worker
# instead of respawning over it). A missing window is recreated.
#
# Continuation nudge: `claude --resume` reloads the transcript but
# does NOT restart an interrupted turn — a worker that was BUSY when
# its session died would come back idle with its task half-done. When
# the window's last heartbeat (`monitor/.state/heartbeat/<window>.json`)
# shows a mid-turn state (`busy` / `user_prompt`) or a pending-tool
# record exists, the resume passes a continuation prompt alongside
# `--resume <sid>` so the worker picks the task back up immediately.
# `--nudge` forces the prompt, `--no-nudge` suppresses it; default is
# the heartbeat-driven auto behaviour above.
#
# --dry-run prints the resolved window/session/workdir (and the nudge
# decision) and exits without touching tmux. For testing and operator
# pre-flight.
#
# Exit codes:
#   2  $FLOOR_FILE missing
#   3  ## Worker floor section empty or missing
#   4  prompt-file unreadable
#   5  required arg missing
#   6  workdir not a directory
#   7  tmux window with that name already exists
#   8  no tmux server running
#   9  -r prior-report path unreadable
#   10 worker-settings.json missing at $NEXUS_ROOT/monitor/
#   11 --resume: session-id unresolvable, or transcript jsonl missing
#   12 --resume: workdir unresolvable
#   13 --resume: window exists with a LIVE pane and no --replace
#   14 --resume: explicit session-id is the pinned ORCHESTRATOR session
#      and -n names a non-coordinator window (duplicate-orchestrator
#      guard, your-org/your-nexus#206)
#   15 fresh spawn: deliverable-write probe failed — the worker's
#      workdir or the reports dir is not writable. The spawn aborts
#      BEFORE the worker starts, with the remedy printed (in-sandbox:
#      the EXTRA_WRITABLE_PATHS grant recipe; out-of-sandbox: a generic
#      not-writable message). A worker that cannot write its workdir or
#      file its mandatory report is dead on arrival, so this fails fast
#      rather than warning. See monitor/write-probe.sh.
#
# This helper does NOT remove $PROMPT_FILE — the orchestrator owns it.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
usage: monitor/spawn-worker.sh -n <window-name> -c <workdir> -p <prompt-file>
                               [-r <prior-report-path>] [--print-prompt]
                               [--kind task|interactive] [--topic <one-line>]
                               [--model <model-id>]
       monitor/spawn-worker.sh --resume <window-name | session-id>
                               [-n <window-name>] [-c <workdir>]
                               [--replace] [--dry-run]

  -n             tmux window name (kebab-case)
  -c             absolute path to the worker's working directory
  -p             path to a prompt file containing ONLY the task-specific
                 instructions. A "## Worker environment" header (absolute
                 paths) and the "## Worker floor" body from
                 skills/nexus.worker-defaults/SKILL.md are prepended
                 automatically.
  -r             optional prior-report path (relative to NEXUS_ROOT or
                 absolute). Inlined as a "Prior context" section between
                 worker environment and worker floor — gives a fresh
                 worker the previous wrap-up's context without
                 re-attaching to the old session.
  --kind         window kind: task (default) or interactive. Interactive
                 windows are operator-engaging conversation windows that
                 auto-retire after a configurable inactivity period and
                 are listed in the overview issue's resumable-sessions
                 registry. The absence of a provenance record marks a
                 window as operator-manual; the default task kind is
                 fully backward-compatible.
  --topic        one-line context summary for the provenance record (and
                 the overview registry). Defaults to the window name.
  --model        pin THIS worker's claude to <model-id> (e.g.
                 claude-fable-5). Opt-in, default-off: when omitted the
                 worker inherits the ambient default model and the
                 generated launcher is byte-identical to prior
                 behaviour. Threaded through to claude-loop.sh / claude,
                 including every \`--continue\` respawn under the loop
                 wrapper. The id is NOT validated here — an invalid id
                 fails at claude launch (existing cause-classify path).
                 NOTE: launch-time model selection, same effect as a
                 \`model\` pin in worker-settings.json — it does NOT
                 override any server-side model auto-switch.
  --skeptic      skeptic mode for this worker: require | auto | deny
                 (default auto). Stamped into the provenance record;
                 \`ng wrap-up\` reads it to enforce/present/skip the
                 skeptic-validation pass. See skills/nexus.skeptic.
                   require — a skeptic MUST validate this result.
                   auto    — the worker decides at wrap-up (heuristic).
                   deny    — no skeptic (trivial / low-impact work).
  --skeptic-depth  recursion depth counter (default 0). A skeptic spawned
                 to review depth-N work is spawned at depth N+1; the
                 protocol caps depth (skills/nexus.skeptic) so skeptic
                 chains terminate.
  --skeptic-role this spawn IS a skeptic reviewing another worker.
                 Requires --skeptic-target <reviewed-window>. Records a
                 \`skeptic-spawn\` linkage event and seeds the comms
                 channel for the reviewed task.
  --skeptic-target <window>  with --skeptic-role: the worker window this
                 skeptic is validating.
  --skeptic-orig <window>  with --skeptic-role: the ORIGINAL worker window
                 at the root of the skeptic chain. A second-or-later skeptic
                 reviews not just its immediate target (the prior skeptic)
                 but the WHOLE chain back to this original deliverable, and
                 may question both. Defaults to --skeptic-target when
                 omitted (the first skeptic's target IS the original).
                 Threaded forward by `ng wrap-up`'s recursive spawn command.
  --print-prompt emit the composed prompt to stdout and exit without
                 spawning a tmux window. For testing.
  --resume       respawn mode: re-attach a prior worker session via
                 \`claude --resume <session-id>\` with full spawn parity
                 (env exports, settings, window options, lifecycle
                 anchors). Target is a window name (session-id and
                 workdir auto-resolve from reports / action-log /
                 ~/.claude/projects) or an explicit session-id UUID
                 (then -n is required). -p is invalid in this mode.
  --replace      with --resume: kill a LIVE same-name window before
                 recreating it (dead panes are replaced automatically).
  --nudge        with --resume: always pass a continuation prompt so
                 the resumed worker re-engages its task immediately.
  --no-nudge     with --resume: never pass the continuation prompt.
                 Default: auto — nudge when the window's last
                 heartbeat shows a mid-turn state (busy/user_prompt)
                 or a pending-tool record exists.
  --dry-run      with --resume: print the resolved window/session/
                 workdir + nudge decision and exit without touching
                 tmux.

NEXUS_ROOT is resolved from this script's location, so the helper works
in forks and fresh clones without any path hardcoding.
USAGE
    exit 5
}

# Pre-parse for the long-form flags (getopts doesn't do longopts).
# --resume/--kind/--topic take values, so the loop is stateful.
PRINT_ONLY=0
RESUME_TARGET=
RESUME_REPLACE=0
RESUME_DRYRUN=0
RESUME_NUDGE=auto
SPAWN_KIND=task
SPAWN_TOPIC=
SKEPTIC_MODE=auto
SKEPTIC_DEPTH=0
SKEPTIC_ROLE=0
SKEPTIC_TARGET=
SKEPTIC_ORIG=
MODEL=
filtered_args=()
expect_resume_val=0
expect_model_val=0
expect_kind_val=0
expect_topic_val=0
expect_skeptic_val=0
expect_skeptic_depth_val=0
expect_skeptic_target_val=0
expect_skeptic_orig_val=0
for arg in "$@"; do
    if [ "$expect_resume_val" -eq 1 ]; then
        RESUME_TARGET="$arg"
        expect_resume_val=0
        continue
    fi
    if [ "$expect_kind_val" -eq 1 ]; then
        SPAWN_KIND="$arg"
        expect_kind_val=0
        continue
    fi
    if [ "$expect_topic_val" -eq 1 ]; then
        SPAWN_TOPIC="$arg"
        expect_topic_val=0
        continue
    fi
    if [ "$expect_skeptic_val" -eq 1 ]; then
        SKEPTIC_MODE="$arg"
        expect_skeptic_val=0
        continue
    fi
    if [ "$expect_skeptic_depth_val" -eq 1 ]; then
        SKEPTIC_DEPTH="$arg"
        expect_skeptic_depth_val=0
        continue
    fi
    if [ "$expect_skeptic_target_val" -eq 1 ]; then
        SKEPTIC_TARGET="$arg"
        expect_skeptic_target_val=0
        continue
    fi
    if [ "$expect_skeptic_orig_val" -eq 1 ]; then
        SKEPTIC_ORIG="$arg"
        expect_skeptic_orig_val=0
        continue
    fi
    if [ "$expect_model_val" -eq 1 ]; then
        MODEL="$arg"
        expect_model_val=0
        continue
    fi
    case "$arg" in
        --print-prompt) PRINT_ONLY=1 ;;
        --resume)       expect_resume_val=1 ;;
        --resume=*)     RESUME_TARGET="${arg#--resume=}" ;;
        --replace)      RESUME_REPLACE=1 ;;
        --dry-run)      RESUME_DRYRUN=1 ;;
        --nudge)        RESUME_NUDGE=force ;;
        --no-nudge)     RESUME_NUDGE=off ;;
        --kind)         expect_kind_val=1 ;;
        --kind=*)       SPAWN_KIND="${arg#--kind=}" ;;
        --topic)        expect_topic_val=1 ;;
        --topic=*)      SPAWN_TOPIC="${arg#--topic=}" ;;
        --skeptic)      expect_skeptic_val=1 ;;
        --skeptic=*)    SKEPTIC_MODE="${arg#--skeptic=}" ;;
        --skeptic-depth)   expect_skeptic_depth_val=1 ;;
        --skeptic-depth=*) SKEPTIC_DEPTH="${arg#--skeptic-depth=}" ;;
        --skeptic-role)    SKEPTIC_ROLE=1 ;;
        --skeptic-target)   expect_skeptic_target_val=1 ;;
        --skeptic-target=*) SKEPTIC_TARGET="${arg#--skeptic-target=}" ;;
        --skeptic-orig)    expect_skeptic_orig_val=1 ;;
        --skeptic-orig=*)  SKEPTIC_ORIG="${arg#--skeptic-orig=}" ;;
        --model)        expect_model_val=1 ;;
        --model=*)      MODEL="${arg#--model=}" ;;
        *) filtered_args+=("$arg") ;;
    esac
done
if [ "$expect_resume_val" -eq 1 ]; then
    echo "spawn-worker: --resume requires a value (<window-name | session-id>)" >&2
    usage
fi
if [ "$expect_kind_val" -eq 1 ]; then
    echo "spawn-worker: --kind requires a value (task|interactive)" >&2
    usage
fi
if [ "$expect_model_val" -eq 1 ]; then
    echo "spawn-worker: --model requires a value (a model id, e.g. claude-fable-5)" >&2
    usage
fi
if [ "$expect_topic_val" -eq 1 ]; then
    echo "spawn-worker: --topic requires a value" >&2
    usage
fi
if [ "$expect_skeptic_val" -eq 1 ]; then
    echo "spawn-worker: --skeptic requires a value (require|auto|deny)" >&2
    usage
fi
if [ "$expect_skeptic_depth_val" -eq 1 ]; then
    echo "spawn-worker: --skeptic-depth requires an integer value" >&2
    usage
fi
if [ "$expect_skeptic_target_val" -eq 1 ]; then
    echo "spawn-worker: --skeptic-target requires a window-name value" >&2
    usage
fi
if [ "$expect_skeptic_orig_val" -eq 1 ]; then
    echo "spawn-worker: --skeptic-orig requires a window-name value" >&2
    usage
fi
case "$SPAWN_KIND" in
    task|interactive) ;;
    *) echo "spawn-worker: --kind must be task or interactive, got: $SPAWN_KIND" >&2; usage ;;
esac
case "$SKEPTIC_MODE" in
    require|auto|deny) ;;
    *) echo "spawn-worker: --skeptic must be require|auto|deny, got: $SKEPTIC_MODE" >&2; usage ;;
esac
case "$SKEPTIC_DEPTH" in
    ''|*[!0-9]*) echo "spawn-worker: --skeptic-depth must be a non-negative integer, got: $SKEPTIC_DEPTH" >&2; usage ;;
esac
if [ "$SKEPTIC_ROLE" -eq 1 ] && [ -z "$SKEPTIC_TARGET" ]; then
    echo "spawn-worker: --skeptic-role requires --skeptic-target <reviewed-window>" >&2
    usage
fi
# The first skeptic's target IS the original deliverable, so --skeptic-orig
# defaults to --skeptic-target. A second-or-later skeptic carries the true
# chain root forward via an explicit --skeptic-orig (emitted by ng's
# recursive spawn command) so it reviews the WHOLE chain (skills/nexus.skeptic).
if [ "$SKEPTIC_ROLE" -eq 1 ] && [ -z "$SKEPTIC_ORIG" ]; then
    SKEPTIC_ORIG="$SKEPTIC_TARGET"
fi
if [ "${#filtered_args[@]}" -gt 0 ]; then
    set -- "${filtered_args[@]}"
else
    set --
fi

WINDOW_NAME=
WORKDIR=
PROMPT_FILE=
PRIOR_REPORT=

while getopts "n:c:p:r:h" opt; do
    case "$opt" in
        n) WINDOW_NAME="$OPTARG" ;;
        c) WORKDIR="$OPTARG" ;;
        p) PROMPT_FILE="$OPTARG" ;;
        r) PRIOR_REPORT="$OPTARG" ;;
        h|*) usage ;;
    esac
done

# Fresh-spawn mode requires -n/-c/-p; resume mode resolves window and
# workdir itself and refuses -p (the resumed session already has its
# conversation — there is no fresh prompt to feed).
if [ -z "$RESUME_TARGET" ]; then
    [ -n "$WINDOW_NAME" ] || { echo "spawn-worker: -n <window-name> required" >&2; usage; }
    [ -n "$WORKDIR" ]     || { echo "spawn-worker: -c <workdir> required"     >&2; usage; }
    [ -n "$PROMPT_FILE" ] || { echo "spawn-worker: -p <prompt-file> required" >&2; usage; }

    [ -d "$WORKDIR" ]      || { echo "spawn-worker: workdir not a directory: $WORKDIR" >&2; exit 6; }
    [ -r "$PROMPT_FILE" ]  || { echo "spawn-worker: prompt-file not readable: $PROMPT_FILE" >&2; exit 4; }
else
    [ -z "$PROMPT_FILE" ] || { echo "spawn-worker: -p is not valid with --resume (the session keeps its own conversation; paste follow-ups into the pane)" >&2; usage; }
fi

NEXUS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLOOR_FILE="$NEXUS_ROOT/skills/nexus.worker-defaults/SKILL.md"

# Resolve $CLAUDE_BIN: env override → project-local install → PATH →
# fail loud. The resolved path is baked into the launcher heredoc
# below, so each worker exec's an absolute path rather than relying on
# the worker shell's PATH.
# shellcheck disable=SC1091
. "$NEXUS_ROOT/monitor/_claude-bin.sh"

# Robust tmux window targeting (issue #323): resolve_window_id /
# resolve_window_index re-resolve a window NAME → its current @id/index
# fresh at each use (the @id is per-server-lifetime, so the NAME is the
# durable key); validate_window_name guards the `-n` charset so a
# dotted/special name can never break a `-t` target or a name→id parse.
# shellcheck disable=SC1091
. "$NEXUS_ROOT/monitor/_tmux-window.sh"

# Shared keyed frontmatter reader (#405 P2): _fm_get reads report
# frontmatter fields (window:, session-id:) through the same parser
# every other frontmatter consumer uses, so the reader here can never
# drift from what ng report-init writes.
# shellcheck disable=SC1091
. "$NEXUS_ROOT/monitor/_fm_lib.sh"

# Validate the window name up front (both spawn and resume paths set
# WINDOW_NAME before any tmux op). Dots stay legal — that's the point
# of #323 — but control chars and parse-hostile punctuation are
# rejected loudly rather than producing a silently dead window.
if [ -n "$WINDOW_NAME" ]; then
    validate_window_name "$WINDOW_NAME" || { echo "spawn-worker: invalid -n window name" >&2; exit 16; }
fi

# Per-spawn Claude Code settings: the canonical file is shipped at
# $NEXUS_ROOT/monitor/worker-settings.json. We pass it to claude via
# `--settings <path>` unconditionally — in BOTH spawn and resume mode.
# No awk extraction, no tmp file, no marker convention — operators
# editing worker hooks edit the JSON file directly. Missing file is a
# spawn-blocker so a misconfigured fork fails fast instead of silently
# dropping heartbeat hooks and re-rendering the bypass-permissions
# startup dialog.
SETTINGS_FILE="$NEXUS_ROOT/monitor/worker-settings.json"
[ -f "$SETTINGS_FILE" ] || { echo "spawn-worker: worker-settings.json missing: $SETTINGS_FILE" >&2; exit 10; }
HOOKS_FLAG="--settings $SETTINGS_FILE"
HOOKS_PATH_ARG="--settings $SETTINGS_FILE"

# Seed the watcher's lifecycle anchors BEFORE the launcher has a chance
# to settle the renderer. This closes two regressions from issue #72:
#
#   - Brand-new windows used to enter the idle-pool gate before the
#     engagement-log row was backfilled, producing 60-70s "wrapped up"
#     false-positives anchored on tmux #{window_activity}. The
#     spawn-time engagement-log stamp guarantees a row exists from
#     birth, with epoch=now so the idle-pool age starts at zero and
#     can't cross the threshold until real idle time has elapsed.
#   - The lifecycle-scoped wrap-up matcher in _idle_probe.sh needs an
#     authoritative "this lifecycle began at ts" anchor to exclude
#     stale wrap-up events from a prior life of the window-name. The
#     `spawn` action-log event provides that anchor with a per-event ts
#     plus a `window=<name>` extra.
#
# Resume mode seeds the same anchors (a resumed window IS a new
# lifecycle of the window-name) with `--extra mode=resume` plus the
# session-id, so the action log distinguishes respawns from births
# while every `"event":"spawn"` consumer (wrap-up-check, idle-probe)
# keeps anchoring correctly.
#
# Both writes are advisory — failures degrade gracefully (the probe
# falls back to its first-observation backfill), so we don't fail the
# spawn on a write error.
_seed_lifecycle_anchors() {
    local nexus_root="$1" window="$2" workdir="$3"
    shift 3
    local ng="$nexus_root/monitor/ng"
    local state_dir="$nexus_root/monitor/.state"
    local elog="$state_dir/engagement-log.tsv"
    local now
    now=$(date +%s)
    mkdir -p "$state_dir" 2>/dev/null || return 0
    # Engagement-log: atomic-rewrite-and-rename to keep at-most-one
    # row per window. Mirrors _engagement_log_stamp's discipline in
    # _idle_probe.sh.
    local tmp
    tmp=$(mktemp "${elog}.XXXXXX" 2>/dev/null) || return 0
    if [ -f "$elog" ]; then
        awk -F'\t' -v w="$window" '$1 != w' "$elog" > "$tmp" 2>/dev/null || true
    fi
    printf '%s\t%s\n' "$window" "$now" >> "$tmp"
    mv "$tmp" "$elog" 2>/dev/null || rm -f "$tmp"
    # Action-log: spawn event with the window name. The classifier
    # consumes this as the lifecycle-birth ts and scopes wrap-up
    # matching to events newer than it. ng log-action handles
    # date/jq composition; we tolerate its failure rather than
    # rolling our own. Any trailing k=v args become extra fields.
    if [ -x "$ng" ]; then
        local -a extra_flags=()
        local kv
        for kv in "$@"; do
            extra_flags+=( --extra "$kv" )
        done
        "$ng" log-action monitor \
            --event spawn \
            --extra "window=$window" \
            --extra "workdir=$workdir" \
            "${extra_flags[@]}" \
            >/dev/null 2>&1 || true
    fi
}

# ---- provenance record --------------------------------------------------
#
# Write monitor/.state/windows/<window>.json on every fresh spawn so
# the orchestrator and the `ng interactive-sessions` registry can
# distinguish orchestrator-spawned windows from manually-opened ones
# (the ABSENCE of this record marks a window as operator-manual) and
# tell task windows from interactive ones.
#
# Fields:
#   window            — tmux window name
#   session_id        — generated --session-id (when available; else "")
#   kind              — "task" | "interactive"
#   spawned_by        — always "orchestrator" (this script)
#   workdir           — absolute workdir path
#   prompt_file       — the task-prompt file path (empty for resume)
#   topic             — one-line context summary (--topic arg or window name)
#   spawned_at        — ISO 8601 timestamp
#   last_activity_ref — path to the heartbeat JSON, the authority for
#                       last-activity timestamps; not duplicated here
#
# Written atomically (tmp + rename). Best-effort: failure is logged to
# stderr but never aborts the spawn.
_write_provenance_record() {
    local nexus_root="$1" window="$2" session_id="$3"
    local kind="$4" workdir="$5" prompt_file="$6" topic="$7"
    # Skeptic fields default-safe: callers predating the skeptic
    # protocol (and the unit harness that eval-extracts this function)
    # pass only the first 7 args, so missing skeptic params fall back to
    # the spawn defaults rather than tripping `set -u`.
    local skeptic_mode="${8:-auto}" skeptic_depth="${9:-0}"
    local skeptic_role="${10:-0}" skeptic_target="${11:-}"
    local skeptic_orig="${12:-}"
    local windows_dir="$nexus_root/monitor/.state/windows"
    mkdir -p "$windows_dir" 2>/dev/null || return 0
    local out="$windows_dir/${window//[^a-zA-Z0-9_-]/_}.json"
    local tmp; tmp=$(mktemp "${out}.XXXXXX" 2>/dev/null) || return 0
    local spawned_at; spawned_at=$(date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    local hb_ref="$nexus_root/monitor/.state/heartbeat/$window.json"
    # Topic defaults to window name when not supplied.
    local effective_topic="${topic:-$window}"
    # skeptic_role is a JSON boolean; normalize the 0/1 flag.
    local skeptic_role_json=false
    [ "$skeptic_role" = "1" ] && skeptic_role_json=true
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg window "$window" \
            --arg session_id "$session_id" \
            --arg kind "$kind" \
            --arg spawned_by "orchestrator" \
            --arg workdir "$workdir" \
            --arg prompt_file "$prompt_file" \
            --arg topic "$effective_topic" \
            --arg spawned_at "$spawned_at" \
            --arg last_activity_ref "$hb_ref" \
            --arg skeptic_mode "$skeptic_mode" \
            --argjson skeptic_depth "${skeptic_depth:-0}" \
            --argjson skeptic_role "$skeptic_role_json" \
            --arg skeptic_target "$skeptic_target" \
            --arg skeptic_orig "$skeptic_orig" \
            '{window: $window, session_id: $session_id, kind: $kind,
              spawned_by: $spawned_by, workdir: $workdir,
              prompt_file: $prompt_file, topic: $topic,
              spawned_at: $spawned_at, last_activity_ref: $last_activity_ref,
              skeptic_mode: $skeptic_mode, skeptic_depth: $skeptic_depth,
              skeptic_role: $skeptic_role, skeptic_target: $skeptic_target,
              skeptic_orig: $skeptic_orig}' \
            > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$out" 2>/dev/null \
        || { rm -f "$tmp" 2>/dev/null; return 0; }
    else
        # jq absent: hand-roll a single-line JSON (no control chars expected
        # in these fields; only backslash and double-quote need escaping).
        local _e_window _e_sid _e_kind _e_wd _e_pf _e_topic _e_at _e_ref _e_sm _e_st
        _e_window=$(printf '%s' "$window"           | sed 's/\\/\\\\/g; s/"/\\"/g')
        _e_sid=$(printf '%s' "$session_id"          | sed 's/\\/\\\\/g; s/"/\\"/g')
        _e_kind=$(printf '%s' "$kind"               | sed 's/\\/\\\\/g; s/"/\\"/g')
        _e_wd=$(printf '%s' "$workdir"              | sed 's/\\/\\\\/g; s/"/\\"/g')
        _e_pf=$(printf '%s' "$prompt_file"          | sed 's/\\/\\\\/g; s/"/\\"/g')
        _e_topic=$(printf '%s' "$effective_topic"   | sed 's/\\/\\\\/g; s/"/\\"/g')
        _e_at=$(printf '%s' "$spawned_at"           | sed 's/\\/\\\\/g; s/"/\\"/g')
        _e_ref=$(printf '%s' "$hb_ref"              | sed 's/\\/\\\\/g; s/"/\\"/g')
        _e_sm=$(printf '%s' "$skeptic_mode"         | sed 's/\\/\\\\/g; s/"/\\"/g')
        _e_st=$(printf '%s' "$skeptic_target"       | sed 's/\\/\\\\/g; s/"/\\"/g')
        local _e_so
        _e_so=$(printf '%s' "$skeptic_orig"         | sed 's/\\/\\\\/g; s/"/\\"/g')
        local _e_depth="${skeptic_depth:-0}"
        [[ "$_e_depth" =~ ^[0-9]+$ ]] || _e_depth=0
        printf '{"window":"%s","session_id":"%s","kind":"%s","spawned_by":"orchestrator","workdir":"%s","prompt_file":"%s","topic":"%s","spawned_at":"%s","last_activity_ref":"%s","skeptic_mode":"%s","skeptic_depth":%s,"skeptic_role":%s,"skeptic_target":"%s","skeptic_orig":"%s"}\n' \
            "$_e_window" "$_e_sid" "$_e_kind" "$_e_wd" "$_e_pf" \
            "$_e_topic" "$_e_at" "$_e_ref" \
            "$_e_sm" "$_e_depth" "$skeptic_role_json" "$_e_st" "$_e_so" \
            > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$out" 2>/dev/null \
        || { rm -f "$tmp" 2>/dev/null; return 0; }
    fi
}

# ---- resume mode (--resume <window-name | session-id>) -----------------
#
# Mirrors a fresh spawn in everything but the claude invocation:
# `claude --resume <session-id>` instead of a composed prompt. See the
# header comment for the resolution chains and exit codes.

_UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# Claude Code's project-dir slug for a path: EVERY non-alphanumeric
# character becomes '-' ('/' AND '_' alike — group → your-lab-m).
# Mirrors ng's _report_session_id layer-2 rule; if Claude Code's slug
# rule ever changes, fix both in the same commit.
_resume_slug() { printf '%s' "$1" | sed 's|[^a-zA-Z0-9]|-|g'; }

# --- coordinator-exclusion guard (your-org/your-nexus#206) --------------
#
# Incident (2026-06-11): a worker spawned with `-c <nexus-root>` shares
# the coordinator's Claude project slug, so the freshest-jsonl fallback
# resolved the worker window to the ORCHESTRATOR's session and the
# post-restart recovery ran `claude --resume <orchestrator-sid>` into a
# worker window — a duplicate orchestrator sharing the live one's
# transcript. The rule enforced here: a non-coordinator window may
# NEVER resolve to the pinned orchestrator session-id, from ANY source
# (a root-cwd worker can leak the orchestrator sid into its report
# frontmatter too — see the cwd-pin comment in the launcher heredoc).

# Coordinator window name: env override, then config, then the
# default — mirrors monitor/watcher/_config.sh's TARGET resolution so
# spawn-worker and the watcher agree on which window is the
# coordinator.
_resume_coordinator_window() {
    if [ -n "${MONITOR_TARGET:-}" ]; then
        printf '%s' "$MONITOR_TARGET"
    elif [ -x "$NEXUS_ROOT/config/load.sh" ]; then
        "$NEXUS_ROOT/config/load.sh" monitor.target_window orchestrator 2>/dev/null \
            || printf 'orchestrator'
    else
        printf 'orchestrator'
    fi
}

# Pinned orchestrator session-id (re-written on every orchestrator
# turn by monitor/hooks/orchestrator-session-pin.sh). Prints nothing
# when the pin is absent or malformed — the gate below then allows
# everything, i.e. pre-#206 behaviour.
_resume_pinned_orch_sid() {
    local pin="$NEXUS_ROOT/monitor/.state/orchestrator-session-id" sid=""
    [ -f "$pin" ] || return 0
    sid=$(tr -d '[:space:]' < "$pin" 2>/dev/null || true)
    if printf '%s' "$sid" | grep -qE "$_UUID_RE"; then
        printf '%s' "$sid"
    fi
    return 0
}

# rc 0 iff <sid> may be resumed into <window>: any sid for the
# coordinator window itself; for every other window, any sid EXCEPT
# the pinned orchestrator session. COORD_WINDOW / ORCH_PINNED_SID are
# populated once at the top of resume mode.
_resume_sid_allowed() {
    local sid="$1" window="$2"
    if [ -z "$ORCH_PINNED_SID" ]; then
        return 0
    fi
    if [ "$window" = "$COORD_WINDOW" ]; then
        return 0
    fi
    [ "$sid" != "$ORCH_PINNED_SID" ]
}

# Newest action-log event of kind $1 for window $2; print jq field $3.
# jq-only — the action log is jq-written; without jq we fall through
# to the plain-text sources (reports, spawn-prompt cache).
_resume_event_field() {
    local event="$1" window="$2" field="$3"
    local log="$NEXUS_ROOT/monitor/.state/action-log.jsonl"
    [ -f "$log" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    grep "\"event\":\"$event\"" "$log" 2>/dev/null \
        | tac \
        | jq -r --arg w "$window" "select(.window == \$w) | $field // empty" 2>/dev/null \
        | grep -v '^unknown$' \
        | head -1
}

# Workdir for a window, newest-evidence-first. Prints the path; fails
# (rc 1) when nothing resolves.
_resume_workdir() {
    local window="$1" wd=""
    # 1. Live pane's current path (window still exists, possibly with
    #    a dead pane — pane_current_path survives process exit).
    if tmux info >/dev/null 2>&1; then
        # Re-resolve name→@id so a dotted name (#323) doesn't dot-parse
        # here and silently skip the live-pane source.
        local _wid; _wid=$(resolve_window_id "$window" 2>/dev/null || true)
        wd=$(tmux display-message -p -t "${_wid:-$window}" '#{pane_current_path}' 2>/dev/null || true)
        if [ -n "$wd" ] && [ -d "$wd" ]; then printf '%s' "$wd"; return 0; fi
    fi
    # 2. window-close event (the close protocol records workdir=).
    wd=$(_resume_event_field window-close "$window" '.workdir')
    if [ -n "$wd" ] && [ -d "$wd" ]; then printf '%s' "$wd"; return 0; fi
    # 3. spawn event (seeded by this script on every spawn).
    wd=$(_resume_event_field spawn "$window" '.workdir')
    if [ -n "$wd" ] && [ -d "$wd" ]; then printf '%s' "$wd"; return 0; fi
    # 4. Spawn-prompt cache's "- Workdir:" line.
    local cache="$NEXUS_ROOT/monitor/.state/spawn-prompts/${window//[^a-zA-Z0-9_-]/_}.txt"
    if [ -f "$cache" ]; then
        wd=$(sed -n 's/^- Workdir: //p' "$cache" | head -1)
        if [ -n "$wd" ] && [ -d "$wd" ]; then printf '%s' "$wd"; return 0; fi
    fi
    return 1
}

# Session-id for a window. Prints the UUID; fails (rc 1) when nothing
# resolves. $2 (workdir) feeds the project-dir fallback. Every source
# is filtered through _resume_sid_allowed (coordinator-exclusion rule,
# your-org/your-nexus#206): a candidate equal to the pinned
# orchestrator sid is skipped LOUDLY for any non-coordinator window —
# falling through to the next source or to the exit-11 failure, never
# silently resuming the coordinator.
_resume_session_id() {
    local window="$1" workdir="$2" sid=""
    # 1. Newest report whose frontmatter `window:` matches. Reports
    #    capture the session-id via CLAUDE_CODE_SESSION_ID, so they
    #    outrank heuristics — but a root-cwd worker whose ng resolvers
    #    keyed off pwd can still carry the ORCHESTRATOR's sid in its
    #    frontmatter (see the cwd-pin rationale in the launcher), so
    #    even this source passes the gate.
    local r fm_window
    while IFS= read -r r; do
        fm_window=$(_fm_get "$r" window)
        [ "$fm_window" = "$window" ] || continue
        sid=$(_fm_get "$r" session-id)
        if printf '%s' "$sid" | grep -qE "$_UUID_RE"; then
            if _resume_sid_allowed "$sid" "$window"; then
                printf '%s' "$sid"; return 0
            fi
            echo "spawn-worker: --resume: report $(basename "$r") names the pinned ORCHESTRATOR session for non-coordinator window '$window' — skipping this source (your-nexus#206)" >&2
        fi
        sid=""
    done < <(ls -t "$NEXUS_ROOT/reports/"*.md 2>/dev/null)
    # 2. window-close event (captured freshest-jsonl at close time).
    sid=$(_resume_event_field window-close "$window" '."session-id"')
    if printf '%s' "$sid" | grep -qE "$_UUID_RE"; then
        if _resume_sid_allowed "$sid" "$window"; then
            printf '%s' "$sid"; return 0
        fi
        echo "spawn-worker: --resume: window-close event names the pinned ORCHESTRATOR session for non-coordinator window '$window' — skipping this source (your-nexus#206)" >&2
    fi
    # 3. Heartbeat session_id — claude's own hook payload, stamped per
    #    tool use by worker-heartbeat.sh under the window's name. The
    #    authoritative live-session record for a window that never
    #    filed a report and never closed cleanly (the #206 incident
    #    class: container restart mid-task).
    local hb="$NEXUS_ROOT/monitor/.state/heartbeat/$window.json"
    if [ -f "$hb" ]; then
        sid=$(sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p' "$hb" | head -1)
        if printf '%s' "$sid" | grep -qE "$_UUID_RE"; then
            if _resume_sid_allowed "$sid" "$window"; then
                printf '%s' "$sid"; return 0
            fi
            echo "spawn-worker: --resume: heartbeat names the pinned ORCHESTRATOR session for non-coordinator window '$window' — skipping this source (your-nexus#206)" >&2
        fi
    fi
    # 4. Newest spawn action-log event carrying a session-id extra:
    #    resume-mode respawns always record it; fresh spawns stamp a
    #    generated `--session-id` since your-nexus#206.
    sid=$(_resume_event_field spawn "$window" '."session-id"')
    if printf '%s' "$sid" | grep -qE "$_UUID_RE"; then
        if _resume_sid_allowed "$sid" "$window"; then
            printf '%s' "$sid"; return 0
        fi
        echo "spawn-worker: --resume: spawn event names the pinned ORCHESTRATOR session for non-coordinator window '$window' — skipping this source (your-nexus#206)" >&2
    fi
    # 5. Freshest session jsonl in the workdir's Claude project dir —
    #    REFUSED for a non-coordinator window whose workdir shares the
    #    coordinator's project slug (a `-c <nexus-root>` worker):
    #    recency proves nothing in a shared directory — the freshest
    #    jsonl there is typically the live orchestrator's, and resuming
    #    it is exactly the #206 duplicate-orchestrator incident.
    #    Elsewhere it stays the last resort, still skipping the pinned
    #    orchestrator sid.
    local slug pdir cand
    slug=$(_resume_slug "$workdir")
    if [ "$slug" = "$(_resume_slug "$NEXUS_ROOT")" ] && [ "$window" != "$COORD_WINDOW" ]; then
        echo "spawn-worker: --resume: window '$window' workdir shares the coordinator's project slug ($slug) — the freshest-jsonl fallback is ambiguous there and is REFUSED (your-org/your-nexus#206). Resolve via report / heartbeat / action-log records, or pass an explicit session-id." >&2
        return 1
    fi
    pdir="$HOME/.claude/projects/$slug"
    if [ -d "$pdir" ]; then
        while IFS= read -r cand; do
            [ -n "$cand" ] || continue
            sid=$(basename -s .jsonl "$cand")
            if _resume_sid_allowed "$sid" "$window"; then
                printf '%s' "$sid"; return 0
            fi
            echo "spawn-worker: --resume: freshest jsonl $(basename "$cand") is the pinned ORCHESTRATOR session — skipping (your-nexus#206)" >&2
        done < <(ls -t "$pdir"/*.jsonl 2>/dev/null)
    fi
    return 1
}

if [ -n "$RESUME_TARGET" ]; then
    # Coordinator-exclusion inputs (your-nexus#206): resolved once,
    # consumed by _resume_sid_allowed at every resolution source and
    # by the explicit-override guard below.
    COORD_WINDOW=$(_resume_coordinator_window)
    ORCH_PINNED_SID=$(_resume_pinned_orch_sid)

    SESSION_ID=
    SOURCE_WINDOW=
    if printf '%s' "$RESUME_TARGET" | grep -qE "$_UUID_RE"; then
        # Explicit session-id override. The window name can't be
        # derived from a bare UUID, so -n is mandatory.
        SESSION_ID="$RESUME_TARGET"
        if [ -z "$WINDOW_NAME" ]; then
            echo "spawn-worker: --resume <session-id> needs -n <window-name> (a bare UUID names no window)" >&2
            exit 5
        fi
        SOURCE_WINDOW="$WINDOW_NAME"
        # Duplicate-orchestrator guard (your-nexus#206): an explicit
        # resume of the pinned orchestrator session into anything but
        # the coordinator window is the incident, not an override.
        if ! _resume_sid_allowed "$SESSION_ID" "$WINDOW_NAME"; then
            cat >&2 <<MSG
spawn-worker: --resume: $SESSION_ID is the pinned ORCHESTRATOR session
  (monitor/.state/orchestrator-session-id) and '$WINDOW_NAME' is not the
  coordinator window ('$COORD_WINDOW'). Resuming it there would create a
  duplicate orchestrator (your-org/your-nexus#206). Refusing.
MSG
            exit 14
        fi
    else
        SOURCE_WINDOW="$RESUME_TARGET"
        [ -n "$WINDOW_NAME" ] || WINDOW_NAME="$RESUME_TARGET"
    fi

    # Workdir: explicit -c wins; otherwise resolve from the window's
    # traces. claude --resume must run from the session's project dir
    # or Claude Code won't find the transcript.
    if [ -n "$WORKDIR" ]; then
        [ -d "$WORKDIR" ] || { echo "spawn-worker: workdir not a directory: $WORKDIR" >&2; exit 6; }
    else
        if ! WORKDIR=$(_resume_workdir "$SOURCE_WINDOW"); then
            cat >&2 <<MSG
spawn-worker: --resume: cannot resolve a workdir for window '$SOURCE_WINDOW'.
  Looked at: live tmux pane path, window-close/spawn action-log events,
  monitor/.state/spawn-prompts/ cache. Pass -c <workdir> explicitly.
MSG
            exit 12
        fi
    fi
    WORKDIR=$(cd "$WORKDIR" && pwd)

    if [ -z "$SESSION_ID" ]; then
        if ! SESSION_ID=$(_resume_session_id "$SOURCE_WINDOW" "$WORKDIR"); then
            cat >&2 <<MSG
spawn-worker: --resume: cannot resolve a session-id for window '$SOURCE_WINDOW'.
  Looked at: reports/*.md frontmatter (window: + session-id:),
  window-close action-log events, ~/.claude/projects/$(_resume_slug "$WORKDIR")/*.jsonl.
  Pass an explicit session-id: --resume <uuid> -n $SOURCE_WINDOW -c $WORKDIR
MSG
            exit 11
        fi
    fi

    # The transcript must exist where claude (running from $WORKDIR)
    # will look for it. Fail loud on a vanished session; warn-but-
    # continue when the jsonl lives under a DIFFERENT project slug
    # (cwd/slug drift — claude gives the authoritative verdict, and
    # remain-on-exit keeps its error readable in the pane).
    RESUME_SLUG=$(_resume_slug "$WORKDIR")
    SESSION_JSONL="$HOME/.claude/projects/$RESUME_SLUG/$SESSION_ID.jsonl"
    if [ ! -f "$SESSION_JSONL" ]; then
        other_jsonl=$(ls "$HOME/.claude/projects/"*/"$SESSION_ID.jsonl" 2>/dev/null | head -1 || true)
        if [ -n "$other_jsonl" ]; then
            echo "spawn-worker: --resume: warn: transcript not under the workdir's slug ($SESSION_JSONL) but found at $other_jsonl — workdir/session mismatch? Continuing; claude will resolve it." >&2
            SESSION_JSONL="$other_jsonl"
        else
            cat >&2 <<MSG
spawn-worker: --resume: session transcript not found on disk.
  session-id: $SESSION_ID
  expected:   $SESSION_JSONL
  (also scanned ~/.claude/projects/*/$SESSION_ID.jsonl)
  The session may have been pruned; spawn a fresh worker with
  -r <prior-report-path> instead.
MSG
            exit 11
        fi
    fi

    # Continuation nudge. `claude --resume` reloads the transcript but
    # does NOT restart an interrupted turn: a worker that was BUSY in
    # its last heartbeat died mid-task and would come back idle at the
    # prompt with the task half-done. Detect the mid-turn signals —
    # heartbeat state busy/user_prompt, or a pending-tool record (the
    # PreToolUse tracker entry that PostToolUse never cleared) — and
    # pass a continuation prompt alongside --resume. permission_prompt
    # is deliberately NOT auto-nudged: that worker was waiting on a
    # human, and "continue" could steamroll the pending question.
    HB_STATE=""
    HB_FILE="$NEXUS_ROOT/monitor/.state/heartbeat/$SOURCE_WINDOW.json"
    if [ -f "$HB_FILE" ]; then
        HB_STATE=$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$HB_FILE" | head -1)
    fi
    PENDING_FILE="$NEXUS_ROOT/monitor/.state/pending-tool/$SOURCE_WINDOW.json"
    DO_NUDGE=0
    NUDGE_REASON="heartbeat-${HB_STATE:-absent}"
    case "$RESUME_NUDGE" in
        force) DO_NUDGE=1; NUDGE_REASON="forced" ;;
        off)   DO_NUDGE=0; NUDGE_REASON="suppressed" ;;
        *)
            if [ "$HB_STATE" = "busy" ] || [ "$HB_STATE" = "user_prompt" ]; then
                DO_NUDGE=1
            elif [ -f "$PENDING_FILE" ]; then
                DO_NUDGE=1
                NUDGE_REASON="pending-tool"
            fi
            ;;
    esac
    NUDGE_TEXT="Your session was interrupted mid-task and has been resumed in a fresh process. The previous turn did not finish. Re-orient: review your most recent steps, re-verify any in-flight state (running jobs, partial edits, tool results may have been lost mid-flight), then continue the task from where it stopped. If the task was in fact complete, make sure your report is filed and wrap up per the worker floor."

    if [ "$RESUME_DRYRUN" -eq 1 ]; then
        printf 'resolved: window=%s session=%s workdir=%s jsonl=%s nudge=%s (%s)\n' \
            "$WINDOW_NAME" "$SESSION_ID" "$WORKDIR" "$SESSION_JSONL" \
            "$([ "$DO_NUDGE" -eq 1 ] && echo on || echo off)" "$NUDGE_REASON"
        exit 0
    fi

    tmux info >/dev/null 2>&1 || { echo "spawn-worker: no tmux server running — cannot resume worker window" >&2; exit 8; }

    # Same-name window handling: a dead pane (remain-on-exit leftover)
    # is replaced automatically; a live pane is refused unless
    # --replace, because pasting a follow-up into the live worker is
    # almost always the right move (see nexus.window-cleanup
    # "Continue-vs-spawn").
    if tmux list-windows -F '#W' 2>/dev/null | grep -Fxq -- "$WINDOW_NAME"; then
        # Re-resolve name→@id and target by id: a dotted name (#323)
        # would otherwise dot-parse in display-message/kill-window -t.
        EXIST_WID=$(resolve_window_id "$WINDOW_NAME" || true)
        pane_dead=$(tmux display-message -p -t "${EXIST_WID:-$WINDOW_NAME}" '#{pane_dead}' 2>/dev/null || echo "")
        if [ "$pane_dead" = "1" ] || [ "$RESUME_REPLACE" -eq 1 ]; then
            tmux kill-window -t "${EXIST_WID:-$WINDOW_NAME}"
        else
            cat >&2 <<MSG
spawn-worker: --resume: window '$WINDOW_NAME' exists with a LIVE pane.
  Paste a follow-up into it instead — monitor/paste-followup.sh
  '$WINDOW_NAME' --file <msg> (see skills/nexus.tmux-spawn/SKILL.md
  "Sending follow-up messages") — or pass --replace to kill + resume.
MSG
            exit 13
        fi
    fi

    SAFE_NAME="${WINDOW_NAME//[^a-zA-Z0-9_-]/_}"
    LAUNCHER_TMP="${TMPDIR:-/tmp}/spawn-launcher-${SAFE_NAME}.$$.sh"

    # Resume launcher: identical env wiring to the fresh-spawn shape
    # (the exports are the whole point — every hook in
    # worker-settings.json dereferences \$NEXUS_ROOT and
    # \$NEXUS_WORKER_WINDOW), but `--resume <sid>` instead of a prompt.
    # The CLAUDE_CODE_RESUME_* pair suppresses the stale-large-session
    # picker exactly as claude-loop.sh does, so the transcript reloads
    # as-is instead of blocking on a dialog. When the nudge fires, the
    # continuation prompt rides as claude's trailing positional arg —
    # `claude --resume <sid> "<prompt>"` resumes AND submits it, no
    # paste-buffer timing games.
    NUDGE_ARG=""
    if [ "$DO_NUDGE" -eq 1 ]; then
        NUDGE_ARG=" \"$NUDGE_TEXT\""
    fi
    cat > "$LAUNCHER_TMP" <<LAUNCHER
#!/bin/bash
export NEXUS_ROOT="$NEXUS_ROOT"
export NEXUS_WORKER_WINDOW="$WINDOW_NAME"
# Join the nexus-wide toolchain (PATH += locals/bin, UV_* -> locals/) so
# \`uv\`/\`python\`/nexus tools resolve by name and nothing writes to \$HOME.
# Guarded: a missing env file is a silent no-op, never a launcher failure.
[ -f "\$NEXUS_ROOT/monitor/locals-env.sh" ] && . "\$NEXUS_ROOT/monitor/locals-env.sh" || true
# Pin worker cwd (issue #95) — claude --resume must also run from the
# session's project dir or Claude Code won't find the transcript.
cd "$WORKDIR" || exit 1
rm -f $LAUNCHER_TMP
CLAUDE_CODE_RESUME_THRESHOLD_MINUTES=999999999 \\
CLAUDE_CODE_RESUME_TOKEN_THRESHOLD=999999999999 \\
    "$CLAUDE_BIN" --dangerously-skip-permissions $HOOKS_FLAG --resume "$SESSION_ID"$NUDGE_ARG
LAUNCHER
    chmod +x "$LAUNCHER_TMP"

    # Capture the new window's @id at creation and target every
    # subsequent op by id (#323). No server restart can interleave
    # within a single spawn, so the id is a valid handle for the whole
    # block; targeting by id sidesteps the `-t name` dot-parse bug.
    WID=$(tmux new-window -P -F '#{window_id}' -d -n "$WINDOW_NAME" -c "$WORKDIR") || true
    [ -n "$WID" ] || { echo "spawn-worker: tmux new-window failed / returned no window id for '$WINDOW_NAME'" >&2; exit 8; }
    # Same window options as a fresh spawn: keep the pane readable
    # after exit, pin the name against tmux- and OSC-driven renames.
    tmux set-window-option -t "$WID" remain-on-exit on 2>/dev/null || true
    tmux set-window-option -t "$WID" automatic-rename off 2>/dev/null || true
    tmux set-window-option -t "$WID" allow-rename off 2>/dev/null || true
    tmux send-keys -t "$WID" "$LAUNCHER_TMP" Enter

    _seed_lifecycle_anchors "$NEXUS_ROOT" "$WINDOW_NAME" "$WORKDIR" \
        "mode=resume" "session-id=$SESSION_ID"

    echo "resumed: window=$WINDOW_NAME session=$SESSION_ID workdir=$WORKDIR settings=$SETTINGS_FILE nudge=$([ "$DO_NUDGE" -eq 1 ] && echo on || echo off) ($NUDGE_REASON)" >&2
    exit 0
fi

# Root-cwd nudge: when -c resolves to the nexus primary clone, warn
# the operator. Workers that edit shared code in the primary clone
# race the watcher (which is sourcing `monitor/watcher/_*.sh` in
# real time) and can leak orchestrator session-id / project=nexus
# into their reports. The check is intentionally narrow — exact
# equality between the resolved `-c` path and NEXUS_ROOT — so it's
# predictable: it fires for `-c $NEXUS_ROOT` but stays silent for
# any worktree or fresh clone underneath. Deeper "is this a
# worktree" heuristics would be brittle.
WORKDIR_REAL=$(cd "$WORKDIR" && pwd)
ROOT_CWD_WARNING=""
if [ "$WORKDIR_REAL" = "$NEXUS_ROOT" ]; then
    cat >&2 <<WARN
spawn-worker.sh: warn: -c resolves to nexus primary clone ($NEXUS_ROOT).
  If this worker will edit shared code, prefer a worktree under work/<project>-<task>/.
  See skills/nexus.tmux-spawn/SKILL.md "secondary clones" for the pattern.
  Continuing anyway.
WARN
    ROOT_CWD_WARNING="Note: your cwd is the nexus primary clone. If you intend to edit shared code, switch to a worktree (\`git worktree add ../<project>-<task> -b <user>/<task>\`) first. Read-only inspection is fine."
fi

# ---- deliverable-write probe (fail-fast before the worker starts) -------
#
# A worker can't do anything useful if it can't write its workdir, and
# it can't even file its MANDATORY report if the reports dir is
# read-only — both are dead-on-arrival conditions. Probe them HERE, at
# dispatch, so a writability problem surfaces with an actionable remedy
# (in-sandbox: the EXTRA_WRITABLE_PATHS grant recipe; out-of-sandbox: a
# generic not-writable message) BEFORE we compose the prompt and burn a
# tmux window — instead of the operator chasing a cryptic mid-task EROFS
# (or a library segfault on a RO mount) manually. The probe is a tiny
# touch+rm on two existing dirs, so it adds no measurable spawn latency;
# a writable target passes silently in both sandbox/non-sandbox modes,
# so a normal run sees zero new friction. Fail-fast (abort the spawn)
# rather than warn-and-continue: launching a worker that's guaranteed to
# fail at its first deliverable write wastes the whole session.
#
# write-probe.sh is itself sandbox-aware (it owns the in/out-of-sandbox
# remedy split). Absence of the script degrades to a silent skip so an
# older fork without it still spawns.
WRITE_PROBE="$NEXUS_ROOT/monitor/write-probe.sh"
if [ -x "$WRITE_PROBE" ]; then
    if ! "$WRITE_PROBE" --quiet "$WORKDIR_REAL" "$NEXUS_ROOT/reports"; then
        echo "spawn-worker: deliverable-write probe failed — aborting spawn before the worker starts (remedy printed above)." >&2
        exit 15
    fi
fi

[ -f "$FLOOR_FILE" ] || { echo "spawn-worker: floor file missing: $FLOOR_FILE" >&2; exit 2; }

# Resolve prior-report path: accept either absolute, or relative to NEXUS_ROOT,
# or relative to cwd. Fail loud if -r given but the file is unreadable — a
# silent skip would defeat the orchestrator's intent to feed prior context.
PRIOR_REPORT_RESOLVED=
if [ -n "$PRIOR_REPORT" ]; then
    if [ -r "$PRIOR_REPORT" ]; then
        PRIOR_REPORT_RESOLVED="$PRIOR_REPORT"
    elif [ -r "$NEXUS_ROOT/$PRIOR_REPORT" ]; then
        PRIOR_REPORT_RESOLVED="$NEXUS_ROOT/$PRIOR_REPORT"
    else
        echo "spawn-worker: prior-report not readable (-r): $PRIOR_REPORT" >&2
        exit 9
    fi
fi

# Extract "## Worker floor" section body up to the next "## " H2 (or EOF).
# H2 boundaries are load-bearing for this extraction; see the orchestrator
# prose in skills/nexus.worker-defaults/SKILL.md.
floor_body=$(awk '
  /^## Worker floor[[:space:]]*$/ { in_floor=1; next }
  in_floor && /^## /              { exit }
  in_floor                        { print }
' "$FLOOR_FILE")

if [ -z "$(printf '%s' "$floor_body" | tr -d '[:space:]')" ]; then
    echo "spawn-worker: '## Worker floor' section empty/missing in $FLOOR_FILE" >&2
    exit 3
fi

# Sanitize window name for filenames. Tempfiles honour TMPDIR (same
# convention as bootstrap-install.sh and _respawn.sh's RESPAWN_TMPDIR):
# production runs with TMPDIR unset land in /tmp as before, while test
# harnesses point TMPDIR at a per-test dir so concurrent suite runs
# can't glob-inspect (or delete) each other's launcher files.
SAFE_NAME="${WINDOW_NAME//[^a-zA-Z0-9_-]/_}"
PROMPT_TMP="${TMPDIR:-/tmp}/spawn-prompt-${SAFE_NAME}.$$.txt"
LAUNCHER_TMP="${TMPDIR:-/tmp}/spawn-launcher-${SAFE_NAME}.$$.sh"

# Loop-wrapper opt-in (issue #75). When `monitor.retain.use_loop_wrapper`
# is truthy in config (env override: MONITOR_RETAIN_USE_LOOP_WRAPPER),
# the generated launcher runs claude through `monitor/claude-loop.sh`
# so a graceful claude exit produces a `claude --continue` against the
# same workdir — keeping retained windows live for paste-buffer
# follow-up. Default false: today's `remain-on-exit on` behaviour stays
# the path of least surprise until the wrapper has shaken out.
USE_LOOP_WRAPPER=${MONITOR_RETAIN_USE_LOOP_WRAPPER:-}
if [ -z "$USE_LOOP_WRAPPER" ] && [ -x "$NEXUS_ROOT/config/load.sh" ]; then
    USE_LOOP_WRAPPER=$("$NEXUS_ROOT/config/load.sh" monitor.retain.use_loop_wrapper false 2>/dev/null || echo false)
fi
case "$USE_LOOP_WRAPPER" in
    1|true|yes|on)  USE_LOOP_WRAPPER=1 ;;
    *)              USE_LOOP_WRAPPER=0 ;;
esac

# Deterministic worker session-id (your-org/your-nexus#206; mirrors
# the orchestrator's issue-#203 `--session-id` pattern). A fresh
# worker's session-id used to be unknowable until its first hook
# fired; a `-c <nexus-root>` worker that died early was then only
# resolvable by freshest-jsonl recency under the project slug it
# SHARES with the orchestrator — the duplicate-orchestrator incident.
# Generating the uuid here, passing `--session-id` to claude, and
# recording it as a `session-id=` extra on the spawn action-log event
# makes every fresh spawn deterministically resumable from birth.
# Generation failure degrades to the pre-#206 behaviour (claude
# assigns its own id; heartbeat/report sources cover resolution). The
# loop-wrapper shape doesn't take the flag (claude-loop.sh rejects
# unknown args and re-invokes `claude --continue` itself), so it must
# not record a stamp claude won't use — its windows stay covered by
# the heartbeat source.
WORKER_SESSION_ID=""
if [ "$USE_LOOP_WRAPPER" -eq 0 ]; then
    if [ -r /proc/sys/kernel/random/uuid ]; then
        WORKER_SESSION_ID=$(< /proc/sys/kernel/random/uuid) || WORKER_SESSION_ID=""
    elif command -v uuidgen >/dev/null 2>&1; then
        WORKER_SESSION_ID=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]') || WORKER_SESSION_ID=""
    fi
    printf '%s' "$WORKER_SESSION_ID" | grep -qE "$_UUID_RE" || WORKER_SESSION_ID=""
fi
SESSION_ID_FLAG=""
if [ -n "$WORKER_SESSION_ID" ]; then
    SESSION_ID_FLAG="--session-id $WORKER_SESSION_ID"
fi

# Compose final prompt: Worker environment header (absolute paths so a worker
# in a secondary clone writes its final report into the primary nexus' reports
# dir, not its own clone's), optional Prior context section (when -r is set),
# then Worker floor body, then task prompt.
{
    printf '## Worker environment\n\n'
    printf -- '- Workdir: %s\n' "$WORKDIR"
    printf -- '- Primary nexus root: %s\n' "$NEXUS_ROOT"
    printf -- '- Reports dir: %s/reports\n' "$NEXUS_ROOT"
    # Skeptic disclosure (skills/nexus.skeptic). An ORDINARY worker is told
    # NOTHING about a possible subsequent skeptic here — it does its work
    # unaware, and learns of the skeptic decision/gate only at wrap-up
    # (`ng wrap-up` reads the mode authoritatively from the provenance
    # record below, never from the worker). This keeps the worker honest:
    # it cannot tailor its narration to a reviewer it does not know exists.
    # A skeptic-ROLE spawn is the sole exception — being a skeptic IS its
    # task, so it must be told. (The rule bars pre-warning the *original*
    # worker of a *future* skeptic; it does not hide a skeptic's own role.)
    if [ "$SKEPTIC_ROLE" -eq 1 ]; then
        printf -- '- Skeptic role: YES — you are the skeptic reviewing window `%s` (depth %s). See skills/nexus.skeptic/SKILL.md.\n' \
            "$SKEPTIC_TARGET" "$SKEPTIC_DEPTH"
    fi
    if [ -n "$ROOT_CWD_WARNING" ]; then
        printf '\n'
        printf '%s\n' "$ROOT_CWD_WARNING"
    fi
    printf '\n---\n\n'
    if [ -n "$PRIOR_REPORT_RESOLVED" ]; then
        printf '## Prior context — previous worker'\''s report\n\n'
        printf 'Path: %s\n\n' "$PRIOR_REPORT_RESOLVED"
        printf 'The previous worker on this thread filed the report below.\n'
        printf 'Read it for context — What Was Done, Current State, and How\n'
        printf 'to Resume in particular. Do NOT redo work already completed;\n'
        printf 'build on it. If the new task contradicts the prior plan,\n'
        printf 'flag the divergence rather than silently re-doing.\n\n'
        printf -- '---\n\n'
        cat -- "$PRIOR_REPORT_RESOLVED"
        printf '\n\n---\n\n'
    fi
    printf '%s\n\n---\n\n' "$floor_body"
    cat -- "$PROMPT_FILE"
} > "$PROMPT_TMP"

# --print-prompt: emit the composed prompt and exit without spawning. Skips
# tmux checks because they aren't relevant to prompt composition.
if [ "$PRINT_ONLY" -eq 1 ]; then
    cat -- "$PROMPT_TMP"
    rm -f "$PROMPT_TMP"
    exit 0
fi

# tmux server check — `tmux new-window` would otherwise start a fresh server
# and create the worker window in a session the orchestrator can't see.
tmux info >/dev/null 2>&1 || { rm -f "$PROMPT_TMP"; echo "spawn-worker: no tmux server running — cannot spawn worker window" >&2; exit 8; }

# Window-name collision check.
if tmux list-windows -F '#W' 2>/dev/null | grep -Fxq -- "$WINDOW_NAME"; then
    rm -f "$PROMPT_TMP"
    echo "spawn-worker: tmux window '$WINDOW_NAME' already exists" >&2
    exit 7
fi

# Spawn-prompt cache. Copy the fully-composed prompt to
# $NEXUS_ROOT/monitor/.state/spawn-prompts/<window>.txt so the
# orchestrator's tier-3/4 subject-issue discovery (see
# `monitor/agent-prompt.md` "Pending decisions" → "Three-tier
# taxonomy") has a fallback when the worker hasn't written a
# report yet. The composed prompt embeds the worker floor + task
# body, which is the richest available context the orchestrator
# can read without paging the running pane.
#
# Best-effort: write failures degrade silently. The cache is a
# convenience, not load-bearing — the tier-3/4 discovery still
# works (just less informatively) when this file is absent.
SPAWN_PROMPT_CACHE_DIR="$NEXUS_ROOT/monitor/.state/spawn-prompts"
mkdir -p "$SPAWN_PROMPT_CACHE_DIR" 2>/dev/null \
    && cp -- "$PROMPT_TMP" "$SPAWN_PROMPT_CACHE_DIR/$SAFE_NAME.txt" 2>/dev/null \
    || true

# Generate the self-cleaning launcher (matches the nexus.tmux-spawn pattern).
# The heredoc is unquoted so $PROMPT_TMP / $LAUNCHER_TMP / $NEXUS_ROOT
# expand here; \$prompt is passed through to the generated script.
#
# NEXUS_ROOT is exported into the worker process so any subprocess that
# resolves nexus state from env (monitor/mint-token.sh's config lookup,
# monitor/ng's STATE_DIR resolver, the reports-dir helper) picks the
# PRIMARY clone — not the worker's worktree which often lacks
# `config/nexus.yml`. Without this, a worker in a fresh worktree runs
# `GH_TOKEN=$(./monitor/mint-token.sh) gh ...`, mint-token can't find
# bot config, fails, GH_TOKEN substitutes "", and gh falls through to
# the user's ambient auth — silently bypassing the bot/user identity
# boundary (PR #25 on your-org/nexus-code shipped under @operator that
# way, before mint-token.sh's example.yml fallback was disabled).
#
# NEXUS_WORKER_WINDOW carries the tmux window name this worker was
# spawned into so per-spawn hooks can name per-window state. Two
# consumers in the default hooks block (see "## Worker hooks" in
# skills/nexus.worker-defaults/SKILL.md):
#   - heartbeat (#74): worker-heartbeat.sh writes
#     \$NEXUS_ROOT/monitor/.state/heartbeat/\$NEXUS_WORKER_WINDOW.json
#     so pane-state.sh has an authoritative busy/idle signal.
#   - notifications-log (#76): the Notification hook stamps the
#     window onto each row so render_idle_prelude can dedupe its
#     awaiting-input count across concurrent workers.
# Without this export, heartbeat files collide on a single path and
# notification rows carry `window:null`. Both launcher shapes below
# must export it before exec'ing claude (or claude-loop.sh).
#
# Two launcher shapes:
#   1. Default (USE_LOOP_WRAPPER=0): single `claude` invocation,
#      identical to the pre-#75 behaviour. tmux `remain-on-exit on`
#      keeps the window scroll-readable; relaunch is manual.
#   2. Loop-wrapped (USE_LOOP_WRAPPER=1, issue #75): `claude-loop.sh`
#      respawns `claude --continue` between exits, bounded by retain
#      TTL + max-restart cap + stop sentinel. Keeps the worker live
#      for paste-buffer follow-up after a wrapped-up `/exit`.
#
# Optional per-worker model pin (--model <id>, issue #433). Empty MODEL
# leaves MODEL_ARG empty, and the `${MODEL_ARG:+ ...}` expansions below
# add NOTHING — the launcher stays byte-identical to the pre-flag
# behaviour. Non-empty MODEL pins this worker's claude to <id>; the id
# is embedded quoted so it survives re-parsing inside the launcher.
MODEL_ARG=""
if [ -n "$MODEL" ]; then
    MODEL_ARG="--model \"$MODEL\""
fi
if [ "$USE_LOOP_WRAPPER" -eq 1 ]; then
cat > "$LAUNCHER_TMP" <<LAUNCHER
#!/bin/bash
export NEXUS_ROOT="$NEXUS_ROOT"
export NEXUS_WORKER_WINDOW="$WINDOW_NAME"
# Join the nexus-wide toolchain (PATH += locals/bin, UV_* -> locals/) so
# \`uv\`/\`python\`/nexus tools resolve by name and nothing writes to \$HOME.
# Guarded: a missing env file is a silent no-op, never a launcher failure.
[ -f "\$NEXUS_ROOT/monitor/locals-env.sh" ] && . "\$NEXUS_ROOT/monitor/locals-env.sh" || true
# Pin worker cwd to the worktree (issue #95). tmux's -c "$WORKDIR"
# on new-window sets the pane's start dir, but a redundant cd here
# survives launcher reuse and any pre-claude wrappers that might
# normalise pwd. Without it, a worker whose ng resolvers key off
# pwd can leak the orchestrator's session-id / project=nexus into
# its report frontmatter.
cd "$WORKDIR" || exit 1
# Loop wrapper reads the prompt file directly (no inline arg) so
# very large prompts don't bump up against argv length limits.
# Tempfiles are cleaned by this launcher's EXIT trap so a crashed
# wrapper still releases /tmp. The --settings file is repo-tracked,
# not a tempfile — nothing to clean up there.
trap 'rm -f $PROMPT_TMP $LAUNCHER_TMP' EXIT
exec "\$NEXUS_ROOT/monitor/claude-loop.sh" \\
    --window "$WINDOW_NAME" \\
    --prompt-file "$PROMPT_TMP" \\
    $HOOKS_PATH_ARG${MODEL_ARG:+ $MODEL_ARG}
LAUNCHER
else
cat > "$LAUNCHER_TMP" <<LAUNCHER
#!/bin/bash
export NEXUS_ROOT="$NEXUS_ROOT"
export NEXUS_WORKER_WINDOW="$WINDOW_NAME"
# Join the nexus-wide toolchain (PATH += locals/bin, UV_* -> locals/) so
# \`uv\`/\`python\`/nexus tools resolve by name and nothing writes to \$HOME.
# Guarded: a missing env file is a silent no-op, never a launcher failure.
[ -f "\$NEXUS_ROOT/monitor/locals-env.sh" ] && . "\$NEXUS_ROOT/monitor/locals-env.sh" || true
# Pin worker cwd to the worktree (issue #95). See the loop-wrapped
# branch above for the full rationale.
cd "$WORKDIR" || exit 1
prompt=\$(<$PROMPT_TMP)
rm -f $PROMPT_TMP $LAUNCHER_TMP
# --settings file is repo-tracked; no tempfile cleanup needed.
"$CLAUDE_BIN" --dangerously-skip-permissions${MODEL_ARG:+ $MODEL_ARG} $HOOKS_FLAG${SESSION_ID_FLAG:+ $SESSION_ID_FLAG} "\$prompt"
LAUNCHER
fi
chmod +x "$LAUNCHER_TMP"

# Capture the new window's @id at creation (`-P -F '#{window_id}'`) and
# target every subsequent op by id (#323). A name with a dot
# (`cc-update-2.1.183`) handed to `-t name` dot-parses as window.pane
# → `can't find pane …` → the launcher is never sent → dead worker.
# The id is valid for this whole spawn (no restart can interleave); the
# NAME remains the durable cross-turn key (re-resolved via
# resolve_window_id at each later targeting op — see #323).
WID=$(tmux new-window -P -F '#{window_id}' -d -n "$WINDOW_NAME" -c "$WORKDIR") || true
if [ -z "$WID" ]; then
    rm -f "$PROMPT_TMP" "$LAUNCHER_TMP"
    echo "spawn-worker: tmux new-window failed / returned no window id for '$WINDOW_NAME'" >&2
    exit 8
fi
# Keep the window alive after `claude` exits so the orchestrator can
# revisit a retained worker's output (and so retain-by-default actually
# delivers what its name promises — see issue #72 regression 5). The
# pane shows a `[exited]` status line once claude returns; the watcher's
# pane-state.sh classifies that as `absent`, which is fine — the
# operator can then close or relaunch.
tmux set-window-option -t "$WID" remain-on-exit on 2>/dev/null || true
# Pin the window name: disable both tmux-side auto-rename (which
# would retitle a dead pane to whatever pane_current_command resolves
# to, or to oddities like `•bell` once the inner Claude Code process
# exits and `remain-on-exit on` leaves the shell-less window in
# tmux) AND OSC-driven rename from inside the pane (Claude Code /
# shell can emit window-title escape sequences). Both knobs are
# needed: automatic-rename governs tmux's own rename loop;
# allow-rename governs whether the inner pane is permitted to set
# the title via OSC. Mirrors the orchestrator-window pin in
# monitor/hooks/orchestrator-session-pin.sh. The watcher's tmux
# snapshot uses window names to track worker lifecycle, so a
# renamed window looks like a phantom appearance/disappearance
# and pollutes the snapshot diff.
tmux set-window-option -t "$WID" automatic-rename off 2>/dev/null || true
tmux set-window-option -t "$WID" allow-rename off 2>/dev/null || true
tmux send-keys -t "$WID" "$LAUNCHER_TMP" Enter

# Seed the watcher's lifecycle anchors BEFORE the launcher has a chance
# to settle the renderer (definition + rationale above, next to the
# resume mode that shares it). The session-id extra (when the
# generated `--session-id` is in play) is what the --resume resolver's
# spawn-event source reads back (your-nexus#206).
if [ -n "$WORKER_SESSION_ID" ]; then
    _seed_lifecycle_anchors "$NEXUS_ROOT" "$WINDOW_NAME" "$WORKDIR" \
        "session-id=$WORKER_SESSION_ID" "kind=$SPAWN_KIND" \
        "skeptic-mode=$SKEPTIC_MODE" "skeptic-depth=$SKEPTIC_DEPTH"
else
    _seed_lifecycle_anchors "$NEXUS_ROOT" "$WINDOW_NAME" "$WORKDIR" \
        "kind=$SPAWN_KIND" \
        "skeptic-mode=$SKEPTIC_MODE" "skeptic-depth=$SKEPTIC_DEPTH"
fi

# Write the durable provenance record. The ABSENCE of this file is what
# marks a window as operator-manual. Written after lifecycle anchors so
# the session-id is available. Best-effort (failures logged, never fatal).
# The skeptic_* fields let `ng wrap-up` read this worker's skeptic mode
# (require|auto|deny) and recursion depth by window name; the skeptic
# protocol (skills/nexus.skeptic) hangs off them.
_write_provenance_record \
    "$NEXUS_ROOT" "$WINDOW_NAME" "${WORKER_SESSION_ID:-}" \
    "$SPAWN_KIND" "$WORKDIR" "$PROMPT_FILE" "$SPAWN_TOPIC" \
    "$SKEPTIC_MODE" "$SKEPTIC_DEPTH" "$SKEPTIC_ROLE" "$SKEPTIC_TARGET" \
    "$SKEPTIC_ORIG"

# Skeptic-spawn linkage (skills/nexus.skeptic). When this spawn IS a
# skeptic reviewing another worker (--skeptic-role --skeptic-target
# <reviewed-window>), record a `skeptic-spawn` action-log event so the
# reviewed task's wrap-up requirement is satisfiable (a skeptic was
# dispatched) and the orchestrator can pair skeptic ↔ original. The
# channel dir for the reviewed task is created here too, so the skeptic
# can `ask` immediately and the worker's nudge target exists. For a
# recursive (second-or-later) skeptic, the ORIGINAL worker's channel is
# seeded as well, because the skeptic reviews the WHOLE chain and may
# question the original worker directly (skills/nexus.skeptic Change 2).
if [ "$SKEPTIC_ROLE" -eq 1 ] && [ -n "$SKEPTIC_TARGET" ]; then
    if [ -x "$NEXUS_ROOT/monitor/ng" ]; then
        "$NEXUS_ROOT/monitor/ng" log-action monitor \
            --event skeptic-spawn \
            --extra "window=$WINDOW_NAME" \
            --extra "target-window=$SKEPTIC_TARGET" \
            --extra "orig-window=$SKEPTIC_ORIG" \
            --extra "depth=$SKEPTIC_DEPTH" \
            >/dev/null 2>&1 || true
    fi
    if [ -x "$NEXUS_ROOT/monitor/skeptic-channel.sh" ]; then
        "$NEXUS_ROOT/monitor/skeptic-channel.sh" init "$SKEPTIC_TARGET" \
            >/dev/null 2>&1 || true
        # Seed the original worker's channel for a recursive skeptic so it
        # can question both the prior skeptic (target) and the original
        # worker (orig). No-op (idempotent) when orig == target.
        if [ -n "$SKEPTIC_ORIG" ] && [ "$SKEPTIC_ORIG" != "$SKEPTIC_TARGET" ]; then
            "$NEXUS_ROOT/monitor/skeptic-channel.sh" init "$SKEPTIC_ORIG" \
                >/dev/null 2>&1 || true
        fi
    fi
    # Establish (or RE-establish) the skeptic-pending markers for the windows
    # this skeptic is reviewing. A live marker (a) makes retire-preflight.sh
    # check 1b refuse to retire a window whose skeptic is still reviewing, and
    # (b) drives the watcher's parked-awaiting-skeptic exemption (the worker's
    # `await` heartbeat only TOUCHES an existing marker — _await_heartbeat —
    # so the marker must already exist for the exemption to refresh).
    #
    # This is the single authoritative point at which the block is tied to an
    # ACTUAL skeptic spawn. For a FIRST-pass skeptic the worker's `require`
    # wrap-up already wrote pending/<target>, so this is an idempotent
    # re-stamp. For a SECOND-or-later pass it is the ONLY thing that restores
    # the block: ng wrap-up's verdict path clears ALL chain markers on the
    # prior verdict (it no longer speculatively re-asserts them — that was the
    # leak), so the marker exists again precisely BECAUSE the next skeptic was
    # really spawned, never on a merely-recommended pass the orchestrator
    # declined. The reviewed worker's marker is therefore never cleared "early"
    # here; it is cleared only at verdict time and reborn only at a real spawn.
    SKEPTIC_PENDING_DIR="$NEXUS_ROOT/monitor/.state/skeptic/pending"
    mkdir -p "$SKEPTIC_PENDING_DIR" 2>/dev/null || true
    _sk_safe() { printf '%s' "${1//[^a-zA-Z0-9_-]/_}"; }
    printf '%s' "$SKEPTIC_DEPTH" \
        > "$SKEPTIC_PENDING_DIR/$(_sk_safe "$SKEPTIC_TARGET")" 2>/dev/null || true
    if [ -n "$SKEPTIC_ORIG" ] && [ "$SKEPTIC_ORIG" != "$SKEPTIC_TARGET" ]; then
        printf '%s' "$SKEPTIC_DEPTH" \
            > "$SKEPTIC_PENDING_DIR/$(_sk_safe "$SKEPTIC_ORIG")" 2>/dev/null || true
    fi
fi

echo "spawned: window=$WINDOW_NAME workdir=$WORKDIR prompt=$PROMPT_FILE kind=$SPAWN_KIND floor=injected${PRIOR_REPORT_RESOLVED:+ prior-report=$PRIOR_REPORT_RESOLVED} settings=$SETTINGS_FILE${WORKER_SESSION_ID:+ session-id=$WORKER_SESSION_ID}$([ "$USE_LOOP_WRAPPER" -eq 1 ] && echo ' loop=on')" >&2
