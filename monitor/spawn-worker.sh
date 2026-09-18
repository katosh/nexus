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
#        ('/' AND '_' alike: your-lab-m → your-lab-m).
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
#   16 --reply-to: the request id is malformed, does not resolve to a
#      request in the inbox, or is already terminal (done/failed) so a
#      reply could never land. Fails at DISPATCH rather than letting the
#      worker discover at wrap-up that its answer has nowhere to go.
#   17 --issue passed without --reply-to (the flag only shapes the
#      channel-mode wrap-up instruction; the default floor already
#      carries the issue form).
#   18 ## Reply-to wrap-up override section empty or missing in
#      $FLOOR_FILE (only checked in --reply-to mode).
#   19 $NEXUS_STATE_DIR is set but names a directory this script cannot
#      create or write. Refused rather than falling back to
#      $NEXUS_ROOT/monitor/.state: a caller that pinned the state dir has
#      already concluded it is isolated, and the silent fall-through is
#      exactly what leaked a fixture's skeptic marker into the operator's
#      live state (your-org/nexus-code#973).
##   20 --skeptic-role where the SPAWNING agent is one of the REVIEWED
#      windows — `--skeptic-target`, or `--skeptic-orig` when it differs
#      (a depth-2 spawn obligates a verdict on the chain root too, so the
#      root is a reviewed party in the ledger's own terms). A worker may
#      not spawn its own skeptic, because the reviewed party would be
#      writing its own reviewer's mandate (your-org/nexus-code#1098). File `ng request file --kind spawn-skeptic` instead, or
#      override loudly with NEXUS_SKEPTIC_SELF_SPAWN=1 plus
#      NEXUS_SKEPTIC_SELF_SPAWN_REASON='<why>' (both required; audited to
#      $STATE_DIR/skeptic-self-spawn.log).
#   22 --dry-run without --resume (your-org/nexus-code#1471): the flag is
#      consumed only by the resume branch; outside it the script used to
#      fall through to a REAL spawn. Refused before anything is composed.
#      --print-prompt is the no-side-effect seam for a fresh spawn.
#   23 an unrecognised `--`-prefixed option (your-org/nexus-code#1471): the
#      parser's default arm used to pass it through, so a typo became an
#      ordinary spawn with the intended behaviour absent.
#   21 post-spawn trust verification (your-org/nexus-code#1334): the worker
#      sat on the workspace-trust dialog and recovery is exhausted
#      (NEXUS_SPAWN_TRUST_MAX_RECOVER, default 2) or REFUSED (a transcript
#      exists or moved, so something ran and the pane must not be killed).
#      The window is left in place with the dialog readable. Clear of the
#      `timeout` injection set (124/125/126/127/137/143).
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
  --reply-to <request-id>
                 this worker ANSWERS a request-channel request; its
                 wrap-up delivers over the channel instead of opening a
                 GitHub issue thread. The "## Reply-to wrap-up override"
                 section of skills/nexus.worker-defaults/SKILL.md is
                 injected after the floor (with <REQUEST_ID> substituted),
                 replacing the floor's \`ng wrap-up <issue> <report>\`
                 instruction with \`ng wrap-up --reply-to <id> <report>\`.
                 The id is validated against the inbox AT DISPATCH.
                 This is the ORCHESTRATOR's choice of delivery surface —
                 never inferred from a (remote, untrusted) client's prose.
  --issue <n>    with --reply-to ONLY: a GitHub write-up is ALSO wanted,
                 so the injected wrap-up carries \`--issue <n>\` and the
                 worker does both (channel reply + upload/link comment).
                 Without --reply-to this is an error (exit 17) — the
                 default floor already names the issue form.
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
                 skeptic is validating. REFUSED (exit 20) when the spawning
                 agent IS that window OR is --skeptic-orig (the chain root,
                 which a depth-2 spawn also obligates a verdict on) — a worker
                 may not spawn its own skeptic; file \`ng request file --origin <w> --kind spawn-skeptic\`
                 instead (#1098).
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
REPLY_TO=
ISSUE_NUM=
filtered_args=()
expect_reply_to_val=0
expect_issue_val=0
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
    if [ "$expect_reply_to_val" -eq 1 ]; then
        REPLY_TO="$arg"
        expect_reply_to_val=0
        continue
    fi
    if [ "$expect_issue_val" -eq 1 ]; then
        ISSUE_NUM="$arg"
        expect_issue_val=0
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
        --reply-to)     expect_reply_to_val=1 ;;
        --reply-to=*)   REPLY_TO="${arg#--reply-to=}" ;;
        --issue)        expect_issue_val=1 ;;
        --issue=*)      ISSUE_NUM="${arg#--issue=}" ;;
        --)             filtered_args+=("$arg") ;;
        --*)
            # AN UNRECOGNISED LONG OPTION IS REFUSED, NOT PASSED THROUGH
            # (your-org/nexus-code#1471). This arm used to be the permissive
            # default below, so `--dryrun`, `--skpetic-role` and every other
            # typo became an ordinary spawn with the intended behaviour absent —
            # the allowlist-with-default-deny doctrine inverted, in the one
            # script whose side effect is a live agent. Bare positionals and
            # short options still flow to getopts below; only `--`-prefixed
            # words nobody declared are refused.
            echo "spawn-worker: unknown option '$arg' — refusing rather than spawning with it ignored (your-org/nexus-code#1471). See --help." >&2
            exit 23
            ;;
        *) filtered_args+=("$arg") ;;
    esac
done
# --dry-run OUTSIDE --resume IS AN ERROR, NOT A NO-OP (your-org/nexus-code#1471).
# The flag's only consumer is the resume branch; without --resume it was set,
# never read, and the script fell through to a REAL spawn — the one flag whose
# universal meaning is "take no action" performed the action. A caller who
# read the header ("--dry-run  with --resume: …") can still reasonably expect
# the universal meaning; the honest answer is to refuse, loudly, before
# anything is composed. Exit 22 is its own code so a caller can tell it from
# a usage error.
if [ "$RESUME_DRYRUN" -eq 1 ] && [ -z "$RESUME_TARGET" ] && [ "$expect_resume_val" -eq 0 ]; then
    echo "spawn-worker: --dry-run is only meaningful with --resume (it prints the resolved resume plan); without --resume it used to be silently IGNORED and a REAL worker was spawned (your-org/nexus-code#1471). Refusing. To compose a prompt without spawning, use --print-prompt." >&2
    exit 22
fi
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
if [ "$expect_reply_to_val" -eq 1 ]; then
    echo "spawn-worker: --reply-to requires a request-id value" >&2
    usage
fi
if [ "$expect_issue_val" -eq 1 ]; then
    echo "spawn-worker: --issue requires an issue-number value" >&2
    usage
fi
# --issue only shapes the CHANNEL-mode wrap-up instruction. Alone it would
# silently do nothing (the default floor already names the issue form), so
# refuse it rather than let the orchestrator think it took effect.
if [ -n "$ISSUE_NUM" ] && [ -z "$REPLY_TO" ]; then
    echo "spawn-worker: --issue <n> is only valid together with --reply-to <request-id>" >&2
    echo "  (without --reply-to the injected floor already carries 'ng wrap-up <issue> <report>')" >&2
    exit 17
fi
if [ -n "$ISSUE_NUM" ]; then
    case "$ISSUE_NUM" in
        ''|*[!0-9]*) echo "spawn-worker: --issue must be a positive integer, got: $ISSUE_NUM" >&2; exit 17 ;;
    esac
fi
# Request-id charset mirrors request-channel.sh's _validate_id: a filename
# stem of [A-Za-z0-9_-] only. Rejecting anything else here makes `..`, `/`
# and absolute paths un-representable BEFORE the id is interpolated into
# the prompt or handed to the channel.
if [ -n "$REPLY_TO" ]; then
    case "$REPLY_TO" in
        *[!A-Za-z0-9_-]*|'')
            echo "spawn-worker: --reply-to must be a request id matching [A-Za-z0-9_-]+, got: $REPLY_TO" >&2
            exit 16 ;;
    esac
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

# your-org/nexus-code#1153 (second, cheap improvement at the SOURCE): a window
# NAMED like a skeptic but spawned without --skeptic-role writes no linkage
# record, so its target's idle probe reads "skeptic-pending marker but NO live
# skeptic" and walks a live pairing toward retirement. Four spawns in one day
# used a bare -n/-c/-p. A WARNING, never a refusal — the suffix is a
# convention, not a contract, and a false refusal would block a legitimate
# spawn; the linkage record is what matters and this names the flag that
# writes it.
if [ "$SKEPTIC_ROLE" -eq 0 ]; then
    case "$WINDOW_NAME" in
        *-sk|*-sk[0-9]|*-sk[0-9][0-9]|*sk|*sk[0-9]|*sk[0-9][0-9]|*-skeptic|*skeptic|*skeptic[0-9])
            echo "spawn-worker: WARNING: window '$WINDOW_NAME' is named like a skeptic but is spawned WITHOUT --skeptic-role — no skeptic linkage record will be written, so its target will read as having NO live skeptic (your-org/nexus-code#1153; check with ng skeptic-evidence <reviewed-window>). If this window reviews another worker, add --skeptic-role --skeptic-target <reviewed-window>." >&2 ;;
    esac
fi

# Fresh-spawn mode requires -n/-c/-p; resume mode resolves window and
# workdir itself and refuses -p (the resumed session already has its
# conversation — there is no fresh prompt to feed).
if [ -z "$RESUME_TARGET" ]; then
    [ -n "$WINDOW_NAME" ] || { echo "spawn-worker: -n <window-name> required" >&2; usage; }
    [ -n "$WORKDIR" ]     || { echo "spawn-worker: -c <workdir> required"     >&2; usage; }
    [ -n "$PROMPT_FILE" ] || { echo "spawn-worker: -p <prompt-file> required" >&2; usage; }

    # Existence check AND canonicalisation in ONE step (your-org/nexus-code#642).
    # The old form was `[ -d "$WORKDIR" ]`, which resolved a RELATIVE -c against
    # THIS process's cwd — and then $WORKDIR was written verbatim into the
    # generated /tmp/spawn-launcher-*.sh, which runs with a DIFFERENT cwd. So a
    # relative -c could pass the guard here and still die on `cd` in the
    # launcher, in a window nobody was looking at, while the parent had already
    # printed `spawned:` and exited 0. Validated in one frame of reference, used
    # in another. `cd && pwd -P` cannot disagree with itself: whatever it
    # accepts, it also converts to the absolute path the launcher receives.
    #
    # `CDPATH=` is load-bearing, not decoration — it is the same defect one
    # level down. A CDPATH set in the operator's environment makes `cd
    # <relative>` resolve against a search path that `[ -d ]` never consulted,
    # so check and use would once again be answering about different
    # directories. `_sw_realpath` (defined below, after NEXUS_ROOT resolution)
    # takes the same precaution; this site cannot call it yet, hence the
    # open-coded form.
    #
    # `pwd -P` (physical) rather than `pwd` (logical) matches how an inherited
    # NEXUS_ROOT is resolved via `_sw_realpath`, so the root-cwd equality test
    # further down compares two paths normalised the same way.
    _sw_workdir_arg="$WORKDIR"
    WORKDIR=$(CDPATH= cd "$_sw_workdir_arg" 2>/dev/null && pwd -P) \
        || { echo "spawn-worker: workdir not a directory: $_sw_workdir_arg" >&2; exit 6; }
    [ -r "$PROMPT_FILE" ]  || { echo "spawn-worker: prompt-file not readable: $PROMPT_FILE" >&2; exit 4; }
else
    [ -z "$PROMPT_FILE" ] || { echo "spawn-worker: -p is not valid with --resume (the session keeps its own conversation; paste follow-ups into the pane)" >&2; usage; }
fi

# ---------------------------------------------------------------------------
# Resolve NEXUS_ROOT — the PRIMARY clone, not merely this script's own tree.
# ---------------------------------------------------------------------------
# your-org/nexus-code#577. This used to be an unconditional
# `NEXUS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"`, which silently FORKED the
# whole nexus state whenever the launcher was invoked from a secondary clone —
# and invoking it from a secondary clone is a PRESCRIBED workflow (CLAUDE.md
# requires watcher-touching work to run in its own clone under `work/`).
#
# Confirmed forensics for the #577 incident. The orchestrator ran
# `work/nexus-code-570fix/monitor/spawn-worker.sh` for a skeptic. Every piece of
# state then resolved inside that clone:
#   * `work/nexus-code-570fix/monitor/.state/action-log.jsonl` holds the ONLY
#     record of the spawn + skeptic-spawn events — the primary log has none, so
#     nothing in the primary could see the skeptic existed;
#   * the require-gate marker was seeded at
#     `work/nexus-code-570fix/monitor/.state/skeptic/pending/nexuscode-570fix`;
#   * the skeptic inherited NEXUS_ROOT=<clone>, so `ng report-init` wrote its
#     verdict to `work/nexus-code-570fix/reports/` — the symptom the operator
#     first noticed, and invisible to the corpus;
#   * meanwhile the LIVE marker blocking retirement sat in the PRIMARY state dir
#     (written by the worker's own wrap-up, which ran under the primary root),
#     where no verdict could ever clear it.
# Result: `retire-preflight` reported `safe=0 … required skeptic has not
# returned a verdict` for a window whose verdict existed, forever — leaving only
# a hand-`rm` of the very marker that exists to prevent hand-clearing.
#
# Resolution order, and why:
#   1. An inherited, VALID $NEXUS_ROOT wins. This mirrors the convention every
#      other nexus helper already follows (`monitor/locals-env.sh`:
#      `${NEXUS_ROOT:-<script-relative>}`, and `ng`'s _resolve_state_dir), and
#      it alone fixes the incident: the orchestrator's env carried
#      NEXUS_ROOT=<primary> and this script overrode it. Honouring the caller
#      also keeps test harnesses (which export NEXUS_ROOT into a tmpdir) exact.
#   2. Otherwise the script-relative root — UNLESS that root is structurally a
#      SECONDARY CLONE: it sits at `<A>/work/…` for some ancestor A that is
#      itself a plausible nexus root. Then re-root to A, loudly. The nesting
#      relation IS the definition of a secondary clone here, it needs no
#      configuration, and it cannot fire for a legitimately separate install or
#      fork (which is not nested under another nexus's `work/`). Deliberately
#      NOT config `nexus.root`: with NEXUS_ROOT unset, config/load.sh resolves
#      relative to its own script dir, so from a clone with no config/nexus.yml
#      it returns the example template's `/path/to/nexus` placeholder — measured,
#      and an oracle that answers with a placeholder exactly when the env is
#      missing is no oracle at all.
# WHAT RE-ROOTING ACTUALLY MOVES — read this before relying on it.
# The WORKDIR is untouched: the worker still WORKS in the clone. But it is NOT
# true that "only state lands in the primary", and that distinction is
# load-bearing enough to spell out (the first version of this comment claimed
# it, and a reviewer demonstrated otherwise). Everything this script resolves
# through $NEXUS_ROOT now comes from the PRIMARY's checkout, while the body of
# spawn-worker.sh executing it is the CLONE's:
#   * FLOOR_FILE — the worker floor injected into every prompt   (policy)
#   * worker-settings.json — the MODEL PIN and hook wiring       (config)
#   * `.`-sourced helpers: _claude-bin.sh, _tmux-window.sh, _fm_lib.sh (code)
#   * claude-loop.sh (exec'd), ng, request-channel.sh, skeptic-channel.sh,
#     write-probe.sh, config/load.sh, and the #589 assert helper      (code)
#   * action log, spawn-prompts, heartbeat, pending-tool, requests and the
#     skeptic markers                                          (state — the point)
# Two consequences follow, both currently LATENT rather than live:
#   1. Sourced-helper version skew. The clone's spawn-worker.sh body calls the
#      primary's _fm_lib.sh / _tmux-window.sh / _claude-bin.sh. A branch that
#      changes one of those signatures breaks a clone-invoked spawn quietly —
#      the same "functions in memory call functions on disk with mismatched
#      arity" class CLAUDE.md documents for the watcher. This branch changes
#      none of the three.
#   2. Testability. A worker in a clone can no longer exercise a MODIFIED
#      floor, worker-settings.json or claude-loop.sh by spawning from its own
#      tree — it reads those from the tree it was isolated from. Use
#      NEXUS_ALLOW_SECONDARY_ROOT=1 when that is what you are testing.
# The trade is still worth it: a forked action log and a require-marker no
# verdict can clear are worse failures than either consequence above.
# NEXUS_ALLOW_SECONDARY_ROOT=1 forces the old script-relative behaviour.
NEXUS_ROOT_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)"
# Capture the INHERITED value before anything overwrites it. `env -u NEXUS_ROOT`
# (what the test suites use) correctly leaves this empty.
NEXUS_ROOT_INHERITED="${NEXUS_ROOT:-}"

_sw_root_is_nexus() {   # is $1 a plausible nexus root?
    [ -n "${1:-}" ] && [ -d "$1" ] && [ -x "$1/monitor/spawn-worker.sh" ] && [ -d "$1/config" ]
}
_sw_realpath() { (CDPATH= cd "${1:-/nonexistent}" 2>/dev/null && pwd -P); }

NEXUS_ROOT="$NEXUS_ROOT_SCRIPT"
NEXUS_ROOT_REROOTED=0
_sw_script_rp=$(_sw_realpath "$NEXUS_ROOT_SCRIPT")

if [ "${NEXUS_ALLOW_SECONDARY_ROOT:-}" = 1 ]; then
    : # explicit opt-out: keep the script-relative root, fork the state knowingly
elif _sw_root_is_nexus "$NEXUS_ROOT_INHERITED" \
     && [ "$(_sw_realpath "$NEXUS_ROOT_INHERITED")" != "$_sw_script_rp" ]; then
    NEXUS_ROOT=$(_sw_realpath "$NEXUS_ROOT_INHERITED")
    NEXUS_ROOT_REROOTED=1
    echo "spawn-worker: note: launcher lives in $NEXUS_ROOT_SCRIPT but NEXUS_ROOT=$NEXUS_ROOT was inherited — spawning against the inherited (primary) root so state does not fork (your-org/nexus-code#577)." >&2
else
    # No usable inherited root. Decide STRUCTURALLY whether this script's own
    # tree is a SECONDARY CLONE: walk up from it looking for an ancestor A such
    # that the tree sits at `A/work/…` AND A is itself a plausible nexus root.
    # That relation IS the definition of a secondary clone in this workspace
    # (CLAUDE.md: `git clone … work/<project>-<task>/`), it needs no
    # configuration, and it cannot fire for a genuinely separate install or fork
    # (which is not nested under another nexus's `work/`).
    #
    # NOT config `nexus.root`, deliberately: with NEXUS_ROOT unset,
    # `config/load.sh` resolves its own candidate list relative to the SCRIPT
    # dir, so from inside a clone that has no `config/nexus.yml` of its own it
    # falls through to the repo-tracked `config/nexus.example.yml` and returns
    # the literal placeholder `/path/to/nexus`. Measured, not assumed — an
    # oracle that answers with a placeholder exactly when the inherited env is
    # missing is no oracle at all.
    _sw_cand="$_sw_script_rp"
    while :; do
        case "$_sw_cand" in
            */work/*) : ;;
            *) break ;;
        esac
        _sw_cand="${_sw_cand%/work/*}"        # strip to the innermost `/work/`
        [ -n "$_sw_cand" ] || break
        if _sw_root_is_nexus "$_sw_cand" && [ "$_sw_cand" != "$_sw_script_rp" ]; then
            NEXUS_ROOT="$_sw_cand"
            NEXUS_ROOT_REROOTED=1
            echo "spawn-worker: note: this launcher is a SECONDARY CLONE under $NEXUS_ROOT/work — spawning against the primary root so the action log, skeptic markers and reports do not fork (your-org/nexus-code#577). Set NEXUS_ALLOW_SECONDARY_ROOT=1 to override." >&2
            break
        fi
    done
fi

# The tree THIS script ships in — captured from NEXUS_ROOT_SCRIPT, i.e. before
# the resolution above can re-root NEXUS_ROOT onto the primary. The shim
# precondition guard below is searched HERE as well as under NEXUS_ROOT, so
# re-rooting can never relocate a guard away from the code that requires it
# (your-org/nexus-code#577 + #589). It must never be derived from NEXUS_ROOT:
# that is the variable re-rooting moves.
NEXUS_SPAWN_CODE_ROOT="$NEXUS_ROOT_SCRIPT"
FLOOR_FILE="$NEXUS_ROOT/skills/nexus.worker-defaults/SKILL.md"

# ---- STATE_DIR — honour $NEXUS_STATE_DIR (your-org/nexus-code#973) ---------
#
# Every other component that writes under `monitor/.state/` resolves it
# through $NEXUS_STATE_DIR first — `ng` (_resolve_state_dir, documented there
# as "env override — direct path; TEST ESCAPE HATCH"), request-channel.sh,
# skeptic-channel.sh, retire-preflight.sh, worker-heartbeat.sh, and 30 more.
# This script honoured it NOWHERE: at e256d4a it contained ZERO references to
# the variable, and pinned all ten of its state paths to
# `$NEXUS_ROOT/monitor/.state` directly. So the repo's own isolation knob —
# the one `setup_fake_nexus` EXPORTS specifically so that "the wrong thing has
# to be impossible, not discouraged" (#833) — bought a fixture nothing here.
#
# The consequence is not hypothetical, and the action log records it in a
# shape that names the mechanism. The #545 case in test-spawn-worker.sh pins
# NEXUS_STATE_DIR at the fixture for its spawn. On 2026-08-04 12:17, with an
# ambient NEXUS_ROOT still inherited (pre-#706 scrub), that spawn split in
# two: the action-log row went through `ng`, which HONOURS the pin, and
# landed in the fixture — the operator's primary log has no `ackme` spawn row
# to this day — while the skeptic-pending marker, written directly off
# NEXUS_ROOT, landed in the operator's LIVE `skeptic/pending/ackme-worker`,
# where it sat as an orphaned retire-block for 19 days. One spawn, two state
# roots, because two writers disagreed about which variable is authoritative.
#
# A pending marker is a HARD retire gate (retire-preflight.sh check 1b), so
# the failure is not cosmetic: a fixture name that a future window happens to
# reuse boots already blocked, with no task and no verdict able to clear it.
#
# In production NEXUS_STATE_DIR is UNSET — no non-test caller in the repo sets
# it — so the fallback below is byte-identical to the previous behaviour and
# this change is inert outside fixtures. That is the point: it removes an
# entire leak axis without moving any real state.
#
# FAIL CLOSED. A pin we cannot honour is worse than no pin, because the caller
# has already concluded it is isolated. If NEXUS_STATE_DIR names something we
# cannot create or write, refuse the spawn rather than silently falling
# through to the live root — which is precisely the fall-through that wrote
# `ackme-worker`.
if [ -n "${NEXUS_STATE_DIR:-}" ]; then
    STATE_DIR="$NEXUS_STATE_DIR"
    if ! mkdir -p "$STATE_DIR" 2>/dev/null || [ ! -w "$STATE_DIR" ]; then
        echo "spawn-worker: NEXUS_STATE_DIR=$STATE_DIR is not creatable/writable — REFUSING to spawn rather than falling back to $NEXUS_ROOT/monitor/.state (your-org/nexus-code#973). A caller that pinned the state dir has already concluded it is isolated; honouring that pin or failing is the only safe pair." >&2
        exit 19
    fi
else
    STATE_DIR="$NEXUS_ROOT/monitor/.state"
fi
# HANDED DOWN (your-org/nexus-code#1335): the two `ng log-action` calls below
# read NEXUS_STATE_DIR; the resolved STATE_DIR must reach them.
export NEXUS_STATE_DIR="$STATE_DIR"

# --- fail-CLOSED shim precondition, emitted into every launcher ------------
#
# Read from monitor/guard-block.sh.in — the SINGLE SOURCE shared with
# monitor/watcher/_respawn.sh. `cat`, never sourced: it is a template, and
# reading it as data avoids the sourced-helper skew hazard CLAUDE.md documents
# for the watcher. Rationale, the two-name/two-root search and the refusal
# contract all live in that file's header.
#
# Fail LOUD if the template is missing: this is a guard whose whole subject is
# guards that vanish quietly, so it must not itself degrade to an empty block.
GUARD_BLOCK_TEMPLATE="$NEXUS_SPAWN_CODE_ROOT/monitor/guard-block.sh.in"
if [ ! -r "$GUARD_BLOCK_TEMPLATE" ]; then
    echo "spawn-worker: REFUSING TO SPAWN — shim guard template missing: $GUARD_BLOCK_TEMPLATE" >&2
    echo "spawn-worker: an empty guard block is a guard that does not run (your-org/nexus-code#589)." >&2
    exit 78
fi
SHIM_GUARD_BLOCK=$(sed -e 's/@@WHO@@/spawn-worker/g' -e 's/@@ACTION@@/SPAWN/g' \
                       -- "$GUARD_BLOCK_TEMPLATE")

# THE SPAWNER'S OWN SNAPSHOT, carried into the launcher (your-org/nexus-code
# #1477, D2). The guard's frozen-snapshot leg cannot read the CHILD's snapshot
# (it does not exist until claude starts) and the launcher has no `claude`
# ancestor (it is tmux's child), so inside the launcher the guard's ancestry
# walk always misses and it used to fall through to "newest file in the CC
# home by mtime" — a proxy that on 2026-09-06 selected a snapshot written by a
# `claude` launched OUTSIDE the nexus and refused every spawn for 18 h.
#
# THIS process normally runs inside the spawning agent's Bash tool, whose
# frame is `zsh -c source <cc-home>/shell-snapshots/snapshot-<id>.sh …`, so
# the walk succeeds HERE. What it finds is the spawning agent's own tool-shell
# recording: a nexus-launched shell on the same rc chain as the child — the
# subject the guard's header always said it examined. The guard ranks it after
# its own ancestry and before the mtime proxies, and REPORTS which route it
# used, so a reader can tell a measurement from an inference. Found nothing
# (headless caller such as the watcher's cc-auto-update spawn): the export is
# omitted and the guard says so via its "selected via:" line.
_spawner_snapshot() {
    local pid=$$ hop=0 line ppid cand
    while (( hop < 8 )); do
        # One pid, header suppressed: `ps` prints exactly one line, so no
        # `| head -1` — an early-exit reader whose status this `||` would
        # consume (the #622 shape the early-exit-readers manifest tracks).
        line=$(ps -o ppid=,args= -p "$pid" 2>/dev/null) || return 1
        [[ -n "$line" ]] || return 1
        line=${line#"${line%%[![:space:]]*}"}     # ps right-pads ppid: strip leading blanks
        ppid=${line%% *}
        [[ "$ppid" =~ ^[0-9]+$ ]] || return 1
        cand=$(printf '%s' "$line" | tr ' ' '\n' | grep -E '/shell-snapshots/snapshot-[^/]*\.sh$' | tail -1)
        if [[ -n "$cand" && -r "$cand" ]]; then printf '%s' "$cand"; return 0; fi
        pid=$ppid; hop=$(( hop + 1 ))
    done
    return 1
}
SPAWNER_SNAPSHOT_EXPORT='# (no spawner snapshot: this spawn-worker run had no claude tool-shell ancestor — the guard falls back to the mtime proxy and says so; #1477)'
if _sw_snap=$(_spawner_snapshot); then
    printf -v SPAWNER_SNAPSHOT_EXPORT 'export NEXUS_SPAWNER_SNAPSHOT=%q' "$_sw_snap"
fi

# --reply-to: resolve the id against the request inbox AT DISPATCH. A typo'd
# or already-terminal id means the worker's answer has nowhere to land — and
# it would only discover that at wrap-up, an hour of work later. Fail here.
# The inbox is keyed off THIS script's NEXUS_ROOT (the same root exported to
# the worker), so the check and the eventual `ng wrap-up --reply-to` agree on
# which state dir they mean. A fork without request-channel.sh degrades to a
# skip rather than a hard block.
REPLY_TO_STATE=
if [ -n "$REPLY_TO" ]; then
    _reqchan="$NEXUS_ROOT/monitor/request-channel.sh"
    if [ -x "$_reqchan" ]; then
        _reqfile=$(NEXUS_ROOT="$NEXUS_ROOT" "$_reqchan" reqfile "$REPLY_TO" 2>/dev/null) || _reqfile=
        if [ -z "$_reqfile" ]; then
            echo "spawn-worker: --reply-to $REPLY_TO does not resolve to any request in the inbox" >&2
            echo "  inbox: $STATE_DIR/requests  (list it with: monitor/ng request list)" >&2
            exit 16
        fi
        # <stem>.<state>.md → the state word.
        REPLY_TO_STATE=$(basename -- "$_reqfile"); REPLY_TO_STATE="${REPLY_TO_STATE%.md}"
        REPLY_TO_STATE="${REPLY_TO_STATE##*.}"
        case "$REPLY_TO_STATE" in
            done|failed|replied)
                echo "spawn-worker: --reply-to $REPLY_TO is already terminal (state=$REPLY_TO_STATE) — a reply can never land on it" >&2
                exit 16 ;;
        esac
    fi
fi

# Resolve $CLAUDE_BIN: env override → project-local install → PATH →
# fail loud. The resolved path is baked into the launcher heredoc
# below, so each worker exec's an absolute path rather than relying on
# the worker shell's PATH.
# shellcheck disable=SC1091
. "$NEXUS_ROOT/monitor/_claude-bin.sh"

# Session MESSAGING name = this worker's tmux window name (#1047), so an
# orchestrator can address a live worker by the window it can already see
# instead of guessing the derived basename($PWD)-<hex> form. Gated on a
# capability probe: an unsupported --name is FATAL (rc 1, "unknown option"),
# so an unconditional flag would kill every spawn on an older Claude Code pin.
# _spawn_name_arg echoes the flag (%q-quoted — a tmux window name is
# operator-supplied text) or nothing, and is called at each launcher-compose
# site rather than once here: on the --resume path $WINDOW_NAME is not final
# until it falls back to $RESUME_TARGET further down, so computing it here
# would bake an EMPTY name into exactly the resume launcher. The probe itself
# caches, so repeated calls cost nothing.
#
# SCOPE: addresses a LIVE agent; NOT a task key — windows get reused and
# renamed, and the session name does NOT follow a later `tmux rename-window`.
# _spawn_plugin_arg <window> → `--plugin-dir <dir>` or nothing
# (your-org/nexus-code#1535). Arms the longjob-watch dispatcher — the ONE
# host-armed plugin monitor per session that wakes a worker when a long job
# ends or fails. FAIL-OPEN by construction: every reason not to arm (kill
# switch, missing/invalid manifest, a binary without --plugin-dir, a validator
# that times out) prints NOTHING here and one line on stderr, and is recorded
# in monitor/.state/longjob/arming.log — the spawn itself is never blocked,
# because a launch path that can refuse to launch is a board that cannot
# revive itself. Same two-root helper search as _spawn_name_arg below.
_spawn_plugin_arg() {
    local w="${1:-}" out='' r
    if ! declare -F longjob_plugin_flag >/dev/null 2>&1; then
        for r in "$NEXUS_ROOT" "$NEXUS_SPAWN_CODE_ROOT"; do
            if [[ -r "$r/monitor/_longjob-plugin.sh" ]]; then
                # shellcheck disable=SC1090
                . "$r/monitor/_longjob-plugin.sh" >/dev/null 2>&1 || true
            fi
            declare -F longjob_plugin_flag >/dev/null 2>&1 && break
        done
    fi
    if ! declare -F longjob_plugin_flag >/dev/null 2>&1; then
        echo "spawn-worker: note: no monitor/_longjob-plugin.sh in either root (older primary?) — NOT passing --plugin-dir; this worker will have no longjob-watch dispatcher and cannot be woken by a long job (your-org/nexus-code#1535)." >&2
        return 0
    fi
    # STATE_DIR is resolved (and exported as NEXUS_STATE_DIR) above; passed
    # explicitly so the helper's own fallback chain is never what decides
    # where a spawn's arming row lands.
    out=$(longjob_plugin_flag "$w" "$STATE_DIR") || return 0
    printf '%s' "$out"
}

_spawn_name_arg() {
    local n="${1:-}" out=''
    [[ -n "$n" ]] || return 0
    # The probe may be ABSENT, not merely negative. spawn-worker sources
    # _claude-bin.sh from $NEXUS_ROOT — the PRIMARY root (#577 state routing) —
    # so a clone running its own newer spawn-worker.sh against an older
    # primary gets the primary's helper, which has no such function. Measured
    # on a live spawn: "claude_supports_name_flag: command not found", and
    # without this guard `set -u`/rc handling turns a naming nicety into noise
    # on every spawn. Degrade to the derived name, loudly and once.
    if ! declare -F claude_supports_name_flag >/dev/null 2>&1 \
       && [[ -r "$NEXUS_SPAWN_CODE_ROOT/monitor/_claude-bin.sh" ]]; then
        # Two-root search, the same shape the shim guard block already uses:
        # $NEXUS_ROOT is the PRIMARY (state), $NEXUS_SPAWN_CODE_ROOT is the tree
        # this script actually ships in. Falling back to our own tree is what
        # makes a clone's spawn-worker.sh work against an older primary,
        # instead of silently dropping the flag it was updated to pass.
        # shellcheck disable=SC1091
        . "$NEXUS_SPAWN_CODE_ROOT/monitor/_claude-bin.sh" >/dev/null 2>&1 || true
    fi
    if ! declare -F claude_supports_name_flag >/dev/null 2>&1; then
        if [[ -z "${_SPAWN_NAME_PROBE_WARNED:-}" ]]; then
            _SPAWN_NAME_PROBE_WARNED=1
            echo "spawn-worker: note: ${NEXUS_ROOT}/monitor/_claude-bin.sh has no claude_supports_name_flag (older primary?) — NOT passing --name; this worker self-names from its cwd basename and will not be addressable as '$n' (your-org/nexus-code#1047)." >&2
        fi
        return 0
    fi
    claude_supports_name_flag || return 0
    # No trailing space: call sites add the separator with ${NAME_ARG:+ ...}
    # so an EMPTY name leaves the surrounding tokens byte-identical to the
    # pre-#1047 launcher. A stray double space here is not cosmetic — it broke
    # test-spawn-worker's `--dangerously-skip-permissions --model "<id>"`
    # adjacency assertion, which is the guard on --model quoting.
    printf -v out -- '--name %q' "$n"
    printf '%s' "$out"
}

# --- worker RLIMIT_NPROC ceiling (fork-storm class, your-org/nexus-code#487)
# Two node-downs in two days (2026-07-08 Lmod command_not_found_handle,
# #457; 2026-07-09 the sandbox /app/bin/pip wrapper) came from unbounded
# self-re-exec loops inside ONE worker exhausting the node's pid_max
# (36864). Every generated launcher below therefore lowers the worker's
# SOFT RLIMIT_NPROC so a runaway chain hits fork:EAGAIN at the ceiling and
# degrades that worker, not the box. The limit is checked against the real
# uid's TOTAL **task (thread)** count — NOT its process count (#506; a
# single node/claude process holds up to ~1000 threads, ~7-9x the process
# figure, so any ceiling reasoned in processes under-budgets). It must
# clear every legitimate concurrent burst: probed fork floors on the
# shared node — an empirical measure of exactly the quantity the kernel
# compares, since the probe IS a fork attempt — ranged ~500-1700 TASKS
# under a full parallel test campaign with twelve live workers, with
# transient node-thread spikes above that; the suite's own peak
# concurrency adds "low hundreds" (run-tests.sh nproc guard). 8192 is
# ~4x the worst legitimate observation and 22% of pid_max (which also
# counts tasks, so the two bounds are in the same currency). SOFT only —
# the hard limit stays untouched, so the watcher/service launchers (which
# a worker may legitimately restart) can raise soft back to hard at their
# own entry and never inherit the ceiling. Override or disable (0) via
# NEXUS_WORKER_NPROC_LIMIT.
WORKER_NPROC_LIMIT="${NEXUS_WORKER_NPROC_LIMIT:-8192}"
NPROC_ULIMIT_LINE=""
if [ "$WORKER_NPROC_LIMIT" -gt 0 ] 2>/dev/null; then
    NPROC_ULIMIT_LINE="ulimit -Su $WORKER_NPROC_LIMIT 2>/dev/null || true"
fi

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

# your-org/nexus-code#1245 / #1196 — the three-valued "is this directory the
# root of its OWN history?" predicate. `git -C <dir>` WALKS UP: on a directory
# under work/ that is not itself a repository, the nearest enclosing repository
# is the nexus, so every `git -C "$dir" …` answers about the NEXUS at rc 0 with
# nothing on stderr. The freshness banner then prints the nexus's branch and
# HEAD as the clone's own. rr_has_own_history is the READ-side question
# (a linked worktree's HEAD *is* its own, so the 131 worktrees under work/
# keep reporting honestly); rr_is_own_root is the WRITE-side one and is the
# wrong predicate here.
#
# ITS ABSENCE IS `undetermined`, NOT `is a repo`. A bare `.` here dies under
# `set -e` with no diagnostic — fail-closed in the sense that nothing wrong is
# printed, but it refuses the whole spawn over a BANNER, and it does so
# silently. The three-valued contract is the right answer applied to the tool's
# own absence: without the predicate we cannot honestly say whether the workdir
# is its own repository, so the block says exactly that and the spawn proceeds.
# What must never happen is falling back to the walk-up, which is the defect.
_SW_RR_OK=1
if [ -r "$NEXUS_ROOT/monitor/repo-root.sh" ]; then
    # shellcheck disable=SC1091
    . "$NEXUS_ROOT/monitor/repo-root.sh" || _SW_RR_OK=0
else
    _SW_RR_OK=0
fi
if [ "$_SW_RR_OK" -eq 1 ] && ! declare -F rr_has_own_history >/dev/null 2>&1; then
    _SW_RR_OK=0
fi

# THE FALLBACK, and why it is not "a second resolver" (#1077 forbids those).
# Degrading to UNDETERMINED whenever repo-root.sh is missing was too blunt: this
# script is VENDORED into fake-nexus fixtures that copy an explicit helper list,
# so the degraded arm fired for every such caller and the freshness block went
# silent — measured, `test-spawn-worker.sh` 145/0 -> 136/9.
#
# This runs ONLY when the canonical predicate is absent, so the two can never
# disagree at runtime; it is a degraded MODE, not a competing answer. It is
# deliberately narrower than rr_has_own_history and it is correct about the one
# thing that matters here: it NEVER WALKS UP. `--show-toplevel` returns the
# ENCLOSING repository's root for a non-repo directory, so comparing it against
# the directory itself is a sound not-my-repo test.
#
# `env -u GIT_DIR -u GIT_WORK_TREE` closes the one hole that would otherwise
# make it say YES for a directory that is not a repository at all (repo-root.sh
# HOLE 3): with those inherited — and GIT EXPORTS THEM FOR EVERY HOOK IT RUNS —
# a plain directory reports `--show-toplevel` equal to itself. Measured here.
#
# Still NOT covered, stated rather than papered over: a BARE repository, where
# `--show-toplevel` disagrees with itself across git versions (#1257). A bare
# repo is not a plausible `-c` workdir, and the arm answers NO there, which is
# the conservative direction.
_sw_has_own_history_fallback() {
    local d="$1" top real
    top=$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$d" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ -n "$top" ] || return 1
    real=$(CDPATH= cd "$d" 2>/dev/null && pwd -P) || return 1
    [ "$top" = "$real" ]
}
if [ "$_SW_RR_OK" -ne 1 ]; then
    echo "spawn-worker: note: monitor/repo-root.sh unavailable under $NEXUS_ROOT — the clone-freshness block falls back to a narrower self-rooted check that still never walks up (your-org/nexus-code#1245)" >&2
fi

# your-org/nexus-code#941 — the window-key encoder lives in ONE place
# (monitor/_bookkeeping.sh). spawn-worker is the WRITER for `windows/<key>.json`,
# the spawn-prompt cache and the skeptic markers; a writer and a reader
# disagreeing about the key ORPHANS state exactly as a collision MERGES it, so
# there is no fallback to the lossy form. Absence refuses the spawn rather than
# writing under a key the readers will never look at.
#
# `$NEXUS_ROOT` here, not the script's own dir: this file already resolves its
# helpers from the PRIMARY root (see the header note above about a branch's
# helpers), and the key must match what the primary's readers compute.
if ! declare -F wk_encode >/dev/null 2>&1; then
    if [ -r "$NEXUS_ROOT/monitor/_bookkeeping.sh" ]; then
        # shellcheck source=monitor/_bookkeeping.sh
        . "$NEXUS_ROOT/monitor/_bookkeeping.sh"
    else
        echo "spawn-worker: cannot load the window-key encoder from $NEXUS_ROOT/monitor/_bookkeeping.sh — refusing" >&2
        exit 2
    fi
fi

# ---- A WORKER MAY NOT SPAWN ITS OWN SKEPTIC (your-org/nexus-code#1098) ----
#
# `skills/nexus.skeptic/SKILL.md` says at :147 and :181 that the ORCHESTRATOR
# composes the skeptic brief and spawns. Nothing enforced it. Measured on this
# nexus on 2026-08-27: worker `harness` filed a skeptic request at 23:43:53 and
# spawned its OWN reviewer at 23:44:35 — 39 s before the orchestrator acted on
# that same request. Two agents reviewed one target, and one of them read a
# mandate written by the party under review.
#
# The obligation ledger resolved the duplicate correctly on its own
# (`void-superseded` vs `live`), so this is NOT a bookkeeping defect. It is a
# control that existed only in prose, which is why a CAREFUL worker walked
# straight through it: the brief that worker wrote was good — it named the PR,
# the branch and the base sha, and told its skeptic to clone out rather than
# work in the primary. The hazard a self-written brief carries is not a wrong
# answer, it is an UNEXAMINED REGION, and an omission is invisible from inside
# the brief that omits it.
#
# TWO KEYS, EITHER OF WHICH REFUSES. They answer the same question through
# different evidence, and each covers the other's blind spot:
#
#   1. SESSION IDENTITY — `$CLAUDE_SESSION_ID` (the spawning agent's own
#      session, exported by the harness) against `.session_id` in the TARGET's
#      provenance record. A UUID on both sides, so a match is identity and not
#      a coincidence of names. This is the key `#1098` names.
#   2. WINDOW IDENTITY — `$NEXUS_WORKER_WINDOW` (exported to every worker by
#      this very script, line ~1594) against `--skeptic-target`. Both are tmux
#      window names in ONE namespace — the same nexus's session — so a match
#      means "I am the window under review", not "two unrelated things share a
#      string". It covers the target whose record predates provenance, carries
#      an empty `session_id`, or cannot be read because `jq` is absent and the
#      record is pretty-printed.
#
# WHICH KEY ACTUALLY FIRES IN PRODUCTION — MEASURED, and it is not the one the
# issue proposes. `$CLAUDE_SESSION_ID` is NOT reliably present in the
# environment a worker's shell tool hands to this launcher: measured in one
# session on 2026-08-28, populated at 00:0x and ABSENT half an hour later, with
# nothing in monitor/shellenv unsetting it. So key 1 is real but intermittent,
# and the live end-to-end refusal was carried by key 2:
#
#     $ ./monitor/spawn-worker.sh -n delivery-selftest … \
#           --skeptic-role --skeptic-target delivery --print-prompt
#     rc=20
#     evidence: $NEXUS_WORKER_WINDOW is 'delivery', which IS --skeptic-target
#
# Had this been built to `#1098`'s proposal alone — the session id, which is the
# better key and the one the issue names — the guard would have been INERT in
# exactly the configuration just tested, while a source-text reading of it
# looked complete. That is `your-org/nexus-code#1085`'s shape (a field spelled
# only in the branch never taken) reappearing inside a fix for the same class.
# Both keys stay: key 1 because it is the one that cannot be confused by names
# and does fire when the harness exports it, key 2 because it is the one that
# fires here.
#
# POSITIVE IDENTIFICATION ONLY — this does NOT default-deny. A spawn whose
# identity cannot be established proceeds. That polarity is deliberate and is
# the opposite of this repo's usual fail-closed default, so it is stated rather
# than left to be inferred: the orchestrator is the overwhelmingly common
# caller, it has no relationship to the target at all, and a guard that refused
# whenever it could not read a descriptor would take the whole fleet down the
# first time `jq` went missing. The failure being prevented is a specific
# ACCIDENT — an agent reaching for the launcher instead of `ng skeptic
# request` — and an accident is caught by positive identification. Neither key
# resists a determined agent that overwrites its own environment; nothing here
# is a security boundary, and it does not need to be.
#
# THE LEGITIMATE PATH ALREADY EXISTS AND ALREADY WORKED: a worker wanting
# review files `ng request file --kind spawn-skeptic`, which the orchestrator adjudicates. It
# worked twice in the hour this defect was measured. The refusal points there.
if [ "$SKEPTIC_ROLE" -eq 1 ] && [ -n "$SKEPTIC_TARGET" ]; then
    # Read one JSON string field without jq and without a pipe. A pipe here
    # would be an early-exit reader (`| head -1`) under this script's
    # `pipefail`, which is monitor/watcher/early-exit-readers.sh's population;
    # the loop runs in THIS shell, so `return` leaves the function directly.
    # The record is jq PRETTY-printed, so the key sits on its own line with a
    # space after the colon — both spellings are handled.
    _ss_json_string() {   # <file> <key> -> value on stdout, empty when absent
        local _f="$1" _k="$2" _line _v
        [ -r "$_f" ] || return 0
        while IFS= read -r _line || [ -n "$_line" ]; do
            case "$_line" in
                *"\"$_k\""*) ;;
                *) continue ;;
            esac
            _v="${_line#*\"$_k\"}"
            _v="${_v#*:}"
            _v="${_v# }"
            case "$_v" in
                '"'*) ;;
                *) continue ;;
            esac
            _v="${_v#\"}"
            _v="${_v%%\"*}"
            printf '%s' "$_v"
            return 0
        done < "$_f"
        return 0
    }

    # BOTH REVIEWED WINDOWS ARE CHECKED, NOT JUST `--skeptic-target`
    # (skeptic F1 on the PR that introduced this guard — CONFIRMED, reproduced).
    #
    # The first version compared only against `$SKEPTIC_TARGET`, and a depth-2
    # spawn names TWO reviewed parties. `--skeptic-orig` is not decorative: when
    # it differs from the target, :2445 opens a SECOND `skeptic-verdict`
    # obligation with the ORIG as creditor, :2495 inits a comms channel to the
    # orig, and :2522 writes a pending marker under the ORIG's key. So the orig
    # is a reviewed party in the ledger's own terms. Measured on the fixture:
    #
    #   I  --skeptic-target rootworker,          I am rootworker  -> 20 REFUSED
    #   J  --skeptic-target rootworker-sk
    #        --skeptic-orig rootworker,          I am rootworker  ->  0 ALLOWED
    #   K  as J, identified by the session key                    ->  0 ALLOWED
    #
    # J and K are `#1098` exactly, one level removed: a root worker spawning a
    # depth-2 skeptic FORMALLY OBLIGATED to review its own work, with a brief it
    # wrote. **A guard complete in the branch it was written against and absent
    # on the neighbouring one** — which is the same shape as the
    # `$CLAUDE_SESSION_ID` correction two paragraphs down, and the same shape as
    # `#1085`. Writing the general form of the lesson here rather than only the
    # instance, because the instance is not what recurs.
    #
    # `[ "$SKEPTIC_ORIG" != "$SKEPTIC_TARGET" ]` mirrors the three call sites
    # above: orig DEFAULTS to target (line ~474), so without that clause the
    # orig arm would fire on every first-pass spawn and duplicate the target
    # arm's diagnostic with a misleading noun.
    _ss_self_session="${CLAUDE_SESSION_ID:-}"
    _ss_self_window="${NEXUS_WORKER_WINDOW:-}"
    _ss_target_record="$STATE_DIR/windows/$(wk_encode "$SKEPTIC_TARGET").json"
    _ss_target_session=$(_ss_json_string "$_ss_target_record" session_id)
    _ss_orig_session=""
    if [ -n "$SKEPTIC_ORIG" ] && [ "$SKEPTIC_ORIG" != "$SKEPTIC_TARGET" ]; then
        _ss_orig_record="$STATE_DIR/windows/$(wk_encode "$SKEPTIC_ORIG").json"
        _ss_orig_session=$(_ss_json_string "$_ss_orig_record" session_id)
    fi

    _ss_evidence=""
    if [ -n "$_ss_self_session" ] && [ -n "$_ss_target_session" ] \
       && [ "$_ss_self_session" = "$_ss_target_session" ]; then
        _ss_evidence="session id $_ss_self_session is the session recorded for --skeptic-target '$SKEPTIC_TARGET' in $_ss_target_record"
    elif [ -n "$_ss_self_session" ] && [ -n "$_ss_orig_session" ] \
         && [ "$_ss_self_session" = "$_ss_orig_session" ]; then
        _ss_evidence="session id $_ss_self_session is the session recorded for --skeptic-orig '$SKEPTIC_ORIG' in $_ss_orig_record — the CHAIN ROOT, which this spawn also obligates a verdict on"
    elif [ -n "$_ss_self_window" ] && [ "$_ss_self_window" = "$SKEPTIC_TARGET" ]; then
        _ss_evidence="\$NEXUS_WORKER_WINDOW is '$_ss_self_window', which IS --skeptic-target"
    elif [ -n "$_ss_self_window" ] && [ -n "$SKEPTIC_ORIG" ] \
         && [ "$SKEPTIC_ORIG" != "$SKEPTIC_TARGET" ] \
         && [ "$_ss_self_window" = "$SKEPTIC_ORIG" ]; then
        _ss_evidence="\$NEXUS_WORKER_WINDOW is '$_ss_self_window', which IS --skeptic-orig — the CHAIN ROOT, which this spawn also obligates a verdict on"
    fi

    if [ -n "$_ss_evidence" ]; then
        # AUDITED OVERRIDE, deliberately shaped like GH_IMPERSONATE rather than
        # invented: a hard refusal with no escape is how a legitimate future
        # case gets worked around by editing this script, which is strictly
        # worse than one that leaves a record. A reason is REQUIRED — the flag
        # alone is not an override — and the call is logged.
        if [ "${NEXUS_SKEPTIC_SELF_SPAWN:-}" = "1" ] \
           && [ -n "${NEXUS_SKEPTIC_SELF_SPAWN_REASON:-}" ]; then
            mkdir -p "$STATE_DIR" 2>/dev/null || true
            printf '%s\t%s\t%s\t%s\n' \
                "$(date -Is 2>/dev/null || date)" "$SKEPTIC_TARGET" \
                "${WINDOW_NAME:-<unnamed>}" "$NEXUS_SKEPTIC_SELF_SPAWN_REASON" \
                >> "$STATE_DIR/skeptic-self-spawn.log" 2>/dev/null || true
            echo "spawn-worker: SELF-SPAWNED SKEPTIC, audited — the spawning agent IS the reviewed party ($_ss_evidence)." >&2
            echo "spawn-worker:   reason: $NEXUS_SKEPTIC_SELF_SPAWN_REASON" >&2
            echo "spawn-worker:   recorded in $STATE_DIR/skeptic-self-spawn.log (your-org/nexus-code#1098)." >&2
        else
            echo "spawn-worker: REFUSING — a worker may not spawn its own skeptic (your-org/nexus-code#1098)." >&2
            echo "spawn-worker:   evidence: $_ss_evidence" >&2
            echo "spawn-worker:   The reviewed party would be writing its own reviewer's mandate. skills/nexus.skeptic" >&2
            echo "spawn-worker:   assigns brief-composition to the ORCHESTRATOR, which has the spawn context you do not." >&2
            echo "spawn-worker:   Do this instead:  monitor/ng request file --origin ${NEXUS_WORKER_WINDOW:-<your-window>} --kind spawn-skeptic --slug review-$SKEPTIC_TARGET --message '<what to review and why>'" >&2
            echo "spawn-worker:   (your-org/nexus-code#1124: the remedy used to name \`ng skeptic request\`, a verb that does not exist)" >&2
            echo "spawn-worker:   Intentional self-spawn (rare): set NEXUS_SKEPTIC_SELF_SPAWN=1 and" >&2
            echo "spawn-worker:   NEXUS_SKEPTIC_SELF_SPAWN_REASON='<why>'; both are required and the call is audited." >&2
            exit 20
        fi
    fi
    unset -f _ss_json_string
fi


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
# Operator-local overlay (your-org/nexus-code#614). If
# `worker-settings.local.json` (UNTRACKED) sits next to the tracked
# file, its keys win and the merged result is what claude receives.
# This is what keeps an operator's `model` pin out of a tracked file:
# before it, resolving a pull conflict the obvious way (take upstream)
# silently downgraded every worker off the operator's chosen model with
# no error anywhere. The resolver is a pure pass-through when no
# overlay exists. It FAILS LOUD rather than falling back to the tracked
# defaults — a spawn that silently drops the overlay is the very bug.
if [ -x "$NEXUS_ROOT/monitor/resolve-settings.sh" ]; then
    _resolved=$("$NEXUS_ROOT/monitor/resolve-settings.sh" "$SETTINGS_FILE") || {
        echo "spawn-worker: settings overlay resolution failed (see above); refusing to spawn with operator settings silently dropped" >&2
        exit 10
    }
    SETTINGS_FILE="$_resolved"
fi
# ONE variable, not two (your-org/nexus-code#568 D4). A second, byte-identical
# `HOOKS_PATH_ARG` used to sit here, and its sole consumer was the
# less-exercised loop-wrapper path — so the two could drift apart with only the
# rarely-taken branch changing behaviour, which is the worst way for a
# duplicate to be found.
HOOKS_FLAG="--settings $SETTINGS_FILE"

# Pre-seed Claude Code's workspace-trust entry for the worker's workdir
# (cc 2.1.232: "nested git repositories [no longer inherit] trust from a
# parent directory"). work/<project> checkouts are separate git repos nested
# inside the nexus repo, so without this an interactive spawn stops on the
# trust dialog and never reaches a REPL. (This used to add "and pane-state
# reads that frame as `state=empty active=0`, NOT `blocked`, so the watcher
# never sees a pane to unstick" — FALSE since #896 added the
# `workspace-trust` overlay arm; the frame now measures
# `state=blocked active=0 overlay=workspace-trust`. Corrected, not deleted:
# your-org/nexus-code#1015 finding 4.) Neither --dangerously-skip-permissions nor
# skipDangerousModePermissionPrompt suppresses it; seeding .claude.json is
# the only mechanism. Idempotent: a no-op (no write at all) once trusted.
# Blocking on failure is deliberate — spawning anyway yields exactly the
# silent hang this prevents. See monitor/ensure-workdir-trusted.sh.
#
# Defined here but CALLED at each `tmux new-window` site, because that is the
# first point where $WORKDIR is final on BOTH paths: fresh-spawn canonicalises
# it early, but --resume only resolves it (from the window's traces) much
# later. Seeding at this line would have silently no-op'd on an empty WORKDIR
# for every resume — the rarely-taken-branch drift of #568 D4.
_seed_workspace_trust() {
    [ -x "$NEXUS_ROOT/monitor/ensure-workdir-trusted.sh" ] || return 0
    [ -n "${WORKDIR:-}" ] || {
        echo "spawn-worker: internal: workspace-trust seed reached with an empty WORKDIR" >&2
        exit 10
    }
    "$NEXUS_ROOT/monitor/ensure-workdir-trusted.sh" "$WORKDIR" || {
        echo "spawn-worker: could not pre-seed workspace trust for $WORKDIR (see above); refusing to spawn a worker that would hang on the trust dialog" >&2
        exit 10
    }
}

# ---- post-spawn workspace-trust verification (your-org/nexus-code#1334) -----
#
# The seed above is NECESSARY and was measured INSUFFICIENT: one of five
# clones seeded by the same code path in one session still booted into the
# trust dialog, with the seed reporting success and the key present on disk
# afterwards. Nothing at the write site can close that, because the other
# writer of .claude.json is the harness. So after the launcher is sent, this
# block CONFIRMS the worker did not land on the dialog, and if it did, it
# recovers — bounded, loud, and without depending on the cause.
#
# WHAT THE CAUSE IS AND IS NOT (measured on the real 2.1.261 binary in the
# cc-harness, 2026-09-05). The "claude rewrites .claude.json wholesale from
# stale in-memory state" hypothesis is NOT supported: with a claude at the
# dialog (config loaded), keys seeded externally for other dirs SURVIVED the
# binary's dialog-accept write, its graceful-exit write and a fresh-startup
# write, and the file's inode changed on every write (temp+rename, never
# truncate-in-place). The residual that cannot be excluded that way is a
# narrow read-modify-write interleave — claude reads, we seed, claude writes —
# against which claude takes no lock. The recovery below is correct under
# either, which is why it is a loop and not a lock.
#
# THE REMEDY IS A RESPAWN, NOT A KEYSTROKE. On >=2.1.248 the dialog's DEFAULT
# highlight is `❯ No, exit` (measured: the cursor row read `No, exit` first),
# so a bare Enter EXITS the worker, and any keystroke driver would have to
# navigate the harness's own UI — cc-version-sensitive by construction.
# Killing the window and re-creating it under the same name loses nothing:
# lifecycle anchors and the provenance record are keyed by NAME, and a fresh
# `--session-id` can be REUSED after a kill at the dialog (measured: zero
# transcript files exist while the dialog is up; a respawn with the same id
# boots to idle). Reuse of an id that HAS a transcript kills the new pane,
# which is why "no transcript" is a hard precondition below and not a hope.
#
# THE KILL IS AN EXEMPTION FROM `bk_pane_kill_authorized`, STATED HERE SO
# NOBODY COPIES OR DELETES IT BLIND. `blocked` is in `_BK_ACTIVE_STATES`
# (monitor/_bookkeeping.sh) and NOT on the kill allowlist, so the guard this
# repo prescribes for every kill decision answers NO for a pane on this
# dialog — correctly, for the rule it enforces (2026-06-15: live workers
# retired from a hand-enumerated state list). This block does NOT weaken
# that guard: no allowlist gains `blocked`, no state token is added. It is
# exempt on a NARROWER, CHECKABLE claim than "blocked panes are dead":
#   (1) the kill fires ONLY on `state=blocked` AND `overlay=workspace-trust`
#       — the one dialog that precedes session start — never on `blocked`
#       alone, never on any other overlay;
#   (2) "no work is lost" is ASSERTED immediately before the kill, not
#       argued: fresh spawn -> zero transcript files for this session id;
#       --resume -> the resumed transcript is byte-for-byte the size and
#       mtime it had before the launcher was sent; loop-wrapper (no id) ->
#       no transcript ANYWHERE under projects/*/ newer than a stamp taken
#       before the launcher was sent (coarse, so it can only over-refuse).
#       Every probe is `find -H`: the projects dir is a symlink on this
#       host and a bare start point is a confident zero. A transcript that exists or
#       moved means something RAN, which means the detection is wrong, and
#       that is exactly when this must not kill: it REFUSES and exits 21.
# A future change that lets this kill fire on any other state or overlay
# must go back to `bk_pane_kill_authorized`, not extend this exemption.
#
# NORMAL-PATH COST. Polling stops at the first POSITIVE classification
# (anything that is not `empty`/`unknown`/boot-grace `absent`), i.e. the
# time to first paint, ~1-3 s. `empty` means "don't know yet" (#603), so the
# wait tolerates it up to NEXUS_SPAWN_TRUST_VERIFY_SECONDS (default 20) and
# then prints UNVERIFIED and exits 0 — a slow box must never manufacture a
# spawn failure. A `blocked` pane on any OTHER overlay is noted and left
# alone; it is not this block's to recover. The state names in the positive
# arm are a STOP-WAITING list, not a kill list: an unenumerated token falls
# to "keep polling", the safe direction, and the only destructive arm is the
# exact pair in (1).
#
# BOUNDED AND LOUD. At most NEXUS_SPAWN_TRUST_MAX_RECOVER recoveries (default
# 2); then exit 21 with a diagnostic and the window LEFT IN PLACE so the
# dialog can be read. Every detection reads the key from disk BEFORE acting
# and prints + action-logs `trust-key-at-detection=true|false|ABSENT` — the
# discriminating measurement #1334 prescribes (seed, launch, read BEFORE
# anyone answers), taken automatically on every field occurrence. `ABSENT`
# at detection is a lost seed; `true` at every detection means a re-seed
# cannot help (the seeder's fast path is a no-op) and the suspect moves to a
# key-path mismatch or a second gate — the final diagnostic then lists the
# .projects keys that share this workdir's basename.
#
# THE PRIMARY FIX SITS IN THE LAUNCHER TEMPLATES BELOW, AND THIS BLOCK IS
# THE FALLBACK. Every launcher sets `CLAUDE_CODE_SANDBOXED=1` on the claude
# invocation. The binary (2.1.261) reads it at the head of its trust gate and
# returns "trusted" BEFORE the config key is consulted, so the dialog cannot
# appear whatever happened to the seed. It is a claim about the environment,
# and here it is TRUE: workers run under a kernel-enforced sandbox, so setting
# it INFORMS the tool rather than defeating a check (the operator's point,
# and the reason it is set at all).
#
# Measured before adoption, one variable, real worker configuration
# (`--dangerously-skip-permissions` + worker-settings.json), 2026-09-05:
#   * trust gate: key ABSENT + env -> idle, no dialog (key ABSENT -> dialog
#     without it). The only behaviour the flag changed anywhere.
#   * project-permission-rule gating (the flag's second site in the binary):
#     print-mode with a project `permissions.allow` rule and NO bypass, key
#     ABSENT: rules IGNORED ("this workspace has not been trusted") with the
#     env unset AND set — the "Ignoring … allow entry" path keys on the config
#     key itself, not on the flag. Potency of the probe: key PRESENT -> the
#     rule is honoured and the tool runs. With bypass on, the tool runs in
#     every arm, env or not.
#   * directory-move note (the third site): `/cd` into an untrusted dir that
#     declares rules paints the SAME move dialog with and without the flag,
#     and the post-move pane is byte-identical after accepting.
#   * normal boot (key present, bypass, worker settings): boot frames
#     byte-identical with and without the flag.
# So in this configuration the marginal effect is the trust gate and nothing
# else observable. The flag is INHERITED by the worker's children, so a nested
# `claude -p` the worker itself runs inherits it — bounded by the same sandbox
# and by the worker already holding every permission.
#
# IT IS UNDOCUMENTED AND cc-VERSION-SENSITIVE (an env read at 3 sites in a
# binary re-pinned weekly), which is why (a) this recovery loop stays as the
# fallback — it depends on neither the cause nor the flag — and (b) a CANARY
# pins the flag's semantics against the real binary:
# monitor/watcher/test-integration/test-realmodel-trust-sandboxed-env.sh
# (key ABSENT + env -> idle; key ABSENT alone -> the dialog). An upstream
# change is then a red on the next cc bump, not an intermittent field
# mystery. Belongs on skills/nexus.cc-update/GUIDE.md's collision list.
_SW_TRUST_KEEP_L=""; _SW_TRUST_KEEP_P=""; _SW_TRUST_MODE=""; _SW_TRUST_STAMP=""
_SW_TRUST_XSCRIPT=""; _SW_TRUST_XSCRIPT_SIG=""

_sw_trust_cfg_file() { printf '%s/.claude.json' "${CLAUDE_CONFIG_DIR:-$HOME}"; }
# Transcripts live under <config-dir>/projects; the config dir is
# $CLAUDE_CONFIG_DIR when set (production and the cc-harness), else ~/.claude.
_sw_trust_projects_dir() { printf '%s/projects' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; }
_sw_trust_abs_workdir() { ( CDPATH= cd "$WORKDIR" 2>/dev/null && pwd -P ); }
# The key claude reads: .projects[<physical workdir>].hasTrustDialogAccepted.
_sw_trust_key_on_disk() {
    local cfg abs
    cfg=$(_sw_trust_cfg_file); abs=$(_sw_trust_abs_workdir) || abs="$WORKDIR"
    [ -f "$cfg" ] || { printf 'ABSENT'; return 0; }
    jq -r --arg d "$abs" '.projects[$d].hasTrustDialogAccepted // "ABSENT"' "$cfg" 2>/dev/null \
        || printf 'UNREADABLE'
}
_sw_trust_transcript_sig() { stat -c '%s:%Y' "$1" 2>/dev/null || printf 'nostat'; }

# Called immediately BEFORE the launcher is sent (both sites). Keeps copies of
# the launcher (and prompt) — the launcher deletes the originals as its first
# act, so a respawn needs its own — records the mode, and takes the baseline
# the no-work-lost precondition is measured against.
_sw_trust_keep_launcher() {
    _SW_TRUST_MODE="$1"
    _SW_TRUST_KEEP_L=""; _SW_TRUST_KEEP_P=""; _SW_TRUST_XSCRIPT=""; _SW_TRUST_XSCRIPT_SIG=""
    if [ -f "$LAUNCHER_TMP" ] && cp -p "$LAUNCHER_TMP" "$LAUNCHER_TMP.keep" 2>/dev/null; then
        _SW_TRUST_KEEP_L="$LAUNCHER_TMP.keep"
    fi
    if [ -n "${PROMPT_TMP:-}" ] && [ -f "$PROMPT_TMP" ] \
        && cp -p "$PROMPT_TMP" "$PROMPT_TMP.keep" 2>/dev/null; then
        _SW_TRUST_KEEP_P="$PROMPT_TMP.keep"
    fi
    _SW_TRUST_STAMP="$LAUNCHER_TMP.stamp"
    : > "$_SW_TRUST_STAMP" 2>/dev/null || _SW_TRUST_STAMP=""
    if [ "$_SW_TRUST_MODE" = resume ] && [ -n "${SESSION_ID:-}" ]; then
        # `-H`: the projects dir is a SYMLINK on at least one host
        # (sandbox-config/projects -> ~/.claude/projects) and GNU find does
        # not descend a symlinked STARTING POINT without -H/-L — a bare start
        # returned 0 for a 2.6 MB transcript that exists (sp1334sk, #1334).
        # `-print -quit`, not `| head -1`: no early-exit reader (#682).
        _SW_TRUST_XSCRIPT=$(find -H "$(_sw_trust_projects_dir)" -maxdepth 2 -name "$SESSION_ID.jsonl" -print -quit 2>/dev/null) || _SW_TRUST_XSCRIPT=""
        [ -n "$_SW_TRUST_XSCRIPT" ] && _SW_TRUST_XSCRIPT_SIG=$(_sw_trust_transcript_sig "$_SW_TRUST_XSCRIPT")
    fi
    return 0
}
_sw_trust_drop_keep() {
    [ -n "$_SW_TRUST_KEEP_L" ] && rm -f "$_SW_TRUST_KEEP_L"
    [ -n "$_SW_TRUST_KEEP_P" ] && rm -f "$_SW_TRUST_KEEP_P"
    [ -n "$_SW_TRUST_STAMP" ]  && rm -f "$_SW_TRUST_STAMP"
    _SW_TRUST_KEEP_L=""; _SW_TRUST_KEEP_P=""; _SW_TRUST_STAMP=""
    return 0
}

# THE NO-WORK-LOST PRECONDITION. rc 0 = provably nothing ran in this pane;
# rc 1 = a transcript exists or moved (or the question could not be asked),
# with the reason on stdout. Fail-CLOSED: "could not look" is rc 1.
_sw_trust_no_work_ran() {
    local pdir n sig
    pdir=$(_sw_trust_projects_dir)
    if [ ! -d "$pdir" ]; then
        # No projects dir at all: no transcript can exist anywhere under it.
        printf 'no-projects-dir'; return 0
    fi
    case "$_SW_TRUST_MODE" in
        resume)
            if [ -z "$_SW_TRUST_XSCRIPT" ]; then
                printf 'resume-transcript-not-located-before-send'; return 1
            fi
            sig=$(_sw_trust_transcript_sig "$_SW_TRUST_XSCRIPT")
            if [ "$sig" != "$_SW_TRUST_XSCRIPT_SIG" ]; then
                printf 'resume-transcript-changed(%s->%s)' "$_SW_TRUST_XSCRIPT_SIG" "$sig"; return 1
            fi
            printf 'resume-transcript-unchanged'; return 0 ;;
        *)
            # `find -H`, NOT a bare start: see _sw_trust_keep_launcher. The bare
            # form was a CONFIDENT ZERO on the host that has the symlink, which
            # made this precondition pass for a transcript that existed — the
            # exact class it exists to police, inside the check itself.
            if [ -n "${WORKER_SESSION_ID:-}" ]; then
                n=$(find -H "$pdir" -maxdepth 2 -name "$WORKER_SESSION_ID.jsonl" 2>/dev/null | wc -l) || n=""
                case "$n" in ''|*[!0-9]*) printf 'transcript-probe-failed'; return 1 ;; esac
                if [ "$n" -ne 0 ]; then printf 'transcript-exists(%s)' "$n"; return 1; fi
                printf 'zero-transcripts-for-session-id'; return 0
            fi
            # Loop wrapper: no id claude will honour. COARSE ON PURPOSE: refuse on
            # ANY transcript under projects/*/ newer than the stamp taken before
            # the launcher was sent. A previous cut keyed on the workdir's
            # project slug, re-implementing the binary's undocumented path
            # encoding — and a wrong slug failed OPEN (no dir -> return 0 ->
            # kill). This is a KILL precondition, so it must err toward
            # REFUSING: on a busy board another worker's transcript will often
            # be newer than the stamp and this arm will refuse a recovery that
            # would have been fine. That costs one spawn; the other direction
            # costs a worker's session. (sp1334sk on #1334.)
            [ -n "$_SW_TRUST_STAMP" ] && [ -f "$_SW_TRUST_STAMP" ] || { printf 'no-stamp'; return 1; }
            n=$(find -H "$pdir" -mindepth 2 -maxdepth 2 -name '*.jsonl' -newer "$_SW_TRUST_STAMP" 2>/dev/null | wc -l) || n=""
            case "$n" in ''|*[!0-9]*) printf 'transcript-probe-failed'; return 1 ;; esac
            if [ "$n" -ne 0 ]; then printf 'transcript-newer-than-spawn-anywhere(%s)' "$n"; return 1; fi
            printf 'no-transcript-newer-than-spawn'; return 0 ;;
    esac
}

_sw_trust_log() {  # <event> <k=v>...
    local ev="$1"; shift
    [ -x "$NEXUS_ROOT/monitor/ng" ] || return 0
    local -a extra=(); local kv
    for kv in "$@"; do extra+=( --extra "$kv" ); done
    "$NEXUS_ROOT/monitor/ng" log-action monitor --event "$ev" \
        --extra "window=$WINDOW_NAME" --extra "workdir=$WORKDIR" \
        "${extra[@]}" >/dev/null 2>&1 || true
}

# One pane-state reading for a window @id. pane-state.sh keys on
# index / session:window / NAME, not @id, so resolve the index form first
# (unambiguous unless a window is NAMED as that digit; pane-state then
# refuses with rc 2, which reads here as "could not look" — keep polling).
# rc 3 = the window key could not be resolved (distinct from pane-state's own
# rc, and carried in the RETURN CODE because this runs inside a command
# substitution — a variable set here dies with the subshell).
_sw_trust_pane_state() {
    local wid="$1" key
    key=$(tmux display-message -p -t "$wid" '#{session_name}:#{window_index}' 2>/dev/null) || key=""
    [ -n "$key" ] || return 3
    "$NEXUS_ROOT/monitor/pane-state.sh" "$key" 2>/dev/null
}

# Kill + re-seed + re-create under the same name. rc 0 with WID updated; rc 1
# (reason on stderr) when the precondition or any step refuses.
_sw_trust_respawn() {
    local old_wid="$1" why key
    if ! why=$(_sw_trust_no_work_ran); then
        printf 'spawn-worker: REFUSING to recover %s: the no-work-lost precondition failed (%s).\n' "$WINDOW_NAME" "$why" >&2
        printf '  A transcript exists or changed, so something RAN in that pane and the trust-overlay\n' >&2
        printf '  detection is not to be trusted. The window is left in place; inspect it.\n' >&2
        return 1
    fi
    if [ -z "$_SW_TRUST_KEEP_L" ] || [ ! -f "$_SW_TRUST_KEEP_L" ]; then
        printf 'spawn-worker: cannot recover %s: no kept launcher copy (%s).\n' "$WINDOW_NAME" "${_SW_TRUST_KEEP_L:-unset}" >&2
        return 1
    fi
    # See the exemption paragraph above before touching this line: it fires
    # only on state=blocked + overlay=workspace-trust, after the precondition
    # just asserted (`$why`) that nothing ran in the pane.
    tmux kill-window -t "$old_wid" 2>/dev/null || true
    cp -p "$_SW_TRUST_KEEP_L" "$LAUNCHER_TMP" || return 1
    chmod +x "$LAUNCHER_TMP" 2>/dev/null || true
    if [ -n "$_SW_TRUST_KEEP_P" ]; then cp -p "$_SW_TRUST_KEEP_P" "$PROMPT_TMP" || return 1; fi
    # Re-seed (the same call every window-creation site makes; exits 10 if the
    # seeder itself fails) and READ IT BACK — a seed that reports success is
    # what failed in the field, so the readback is the check, not the rc.
    _seed_workspace_trust
    key=$(_sw_trust_key_on_disk)
    [ "$key" = true ] || { printf 'spawn-worker: re-seed for %s did not stick: key reads %s immediately after the seed.\n' "$WORKDIR" "$key" >&2; return 1; }
    WID=$(tmux new-window -P -F '#{window_id}' -d -n "$WINDOW_NAME" -c "$WORKDIR") || WID=""
    if [ -z "$WID" ]; then
        printf 'spawn-worker: recovery: tmux new-window failed / returned no window id for %s\n' "$WINDOW_NAME" >&2
        return 1
    fi
    tmux set-window-option -t "$WID" remain-on-exit on 2>/dev/null || true
    tmux set-window-option -t "$WID" automatic-rename off 2>/dev/null || true
    tmux set-window-option -t "$WID" allow-rename off 2>/dev/null || true
    # Re-take the baseline: the new pane's stamp is now.
    if [ -n "$_SW_TRUST_STAMP" ]; then : > "$_SW_TRUST_STAMP" 2>/dev/null || true; fi
    tmux send-keys -t "$WID" "$LAUNCHER_TMP" Enter
    return 0
}

# Entry point, called after `tmux send-keys` at BOTH window-creation sites.
# Exits 21 on bounded failure; returns 0 otherwise (verified, unverified, or
# not ours to recover — each said on stderr).
_sw_trust_verify() {
    local wid="$1"
    local budget="${NEXUS_SPAWN_TRUST_VERIFY_SECONDS-20}" max_recover="${NEXUS_SPAWN_TRUST_MAX_RECOVER-2}"
    case "$budget" in ''|*[!0-9]*)
        printf 'spawn-worker: NEXUS_SPAWN_TRUST_VERIFY_SECONDS=%q is not a non-negative integer; using 20\n' "$budget" >&2
        budget=20 ;; esac
    case "$max_recover" in ''|*[!0-9]*)
        printf 'spawn-worker: NEXUS_SPAWN_TRUST_MAX_RECOVER=%q is not a non-negative integer; using 2\n' "$max_recover" >&2
        max_recover=2 ;; esac
    if [ "$budget" -eq 0 ]; then _sw_trust_drop_keep; return 0; fi
    if [ ! -x "$NEXUS_ROOT/monitor/pane-state.sh" ]; then
        printf 'spawn-worker: NOTE — %s/monitor/pane-state.sh is not executable; post-spawn trust verification SKIPPED (worker %s is UNVERIFIED).\n' "$NEXUS_ROOT" "$WINDOW_NAME" >&2
        _sw_trust_drop_keep; return 0
    fi
    local recoveries=0 detections=0 history="" line state overlay evidence tok key deadline psrc nokey
    while :; do
        deadline=$(( $(date +%s) + budget ))
        nokey=0
        while :; do
            psrc=0; line=$(_sw_trust_pane_state "$wid") || psrc=$?
            [ "$psrc" -eq 0 ] || line=""
            if [ "$psrc" -eq 3 ]; then
                # The window's session:index could not be resolved — a tmux that
                # cannot answer about a window it just created. Tolerate a short
                # hiccup, then say UNVERIFIED rather than wait out the budget on
                # a question nothing can answer.
                nokey=$((nokey + 1))
                if [ "$nokey" -ge 3 ]; then
                    printf 'spawn-worker: NOTE — worker %s UNVERIFIED: tmux could not resolve window %s to a pane-state key (%d consecutive failures). Not a failure; the trust dialog was not observed.\n' \
                        "$WINDOW_NAME" "$wid" "$nokey" >&2
                    _sw_trust_log spawn-trust-unverified "reason=window-key-unresolvable"
                    _sw_trust_drop_keep; return 0
                fi
            else
                nokey=0
            fi
            state=""; overlay=""; evidence=""
            for tok in $line; do
                case "$tok" in
                    state=*)    state=${tok#state=} ;;
                    overlay=*)  overlay=${tok#overlay=} ;;
                    evidence=*) evidence=${tok#evidence=} ;;
                esac
            done
            case "$state" in
                blocked)
                    if [ "$overlay" = workspace-trust ]; then break; fi
                    printf 'spawn-worker: NOTE — worker %s is blocked on overlay=%s; not the trust dialog, so nothing here recovers it (pane-state: %s)\n' \
                        "$WINDOW_NAME" "${overlay:-?}" "$line" >&2
                    _sw_trust_drop_keep; return 0 ;;
                idle|busy|user-typing|autosuggest-only|working-background|working-self-paced|over-limit|idle-orphan-async)
                    printf 'spawn-worker: post-spawn check: worker %s reached state=%s (trust dialog not shown%s)\n' \
                        "$WINDOW_NAME" "$state" "$([ "$recoveries" -gt 0 ] && printf ' after %d recover(y|ies)' "$recoveries")" >&2
                    _sw_trust_drop_keep; return 0 ;;
                absent)
                    case "$evidence" in
                        boot-grace|'') : ;;   # too young to have booted — keep polling
                        *)  printf 'spawn-worker: NOTE — worker %s pane reads absent (evidence=%s) during post-spawn check; not the trust dialog, nothing here recovers it (pane-state: %s)\n' \
                                "$WINDOW_NAME" "$evidence" "$line" >&2
                            _sw_trust_drop_keep; return 0 ;;
                    esac ;;
                *) : ;;   # empty | unknown | anything unenumerated: keep polling
            esac
            if [ "$(date +%s)" -ge "$deadline" ]; then
                printf 'spawn-worker: NOTE — worker %s UNVERIFIED: no positive pane state within %ss (last pane-state: %s). Not a failure; the trust dialog was not observed.\n' \
                    "$WINDOW_NAME" "$budget" "${line:-<none>}" >&2
                _sw_trust_log spawn-trust-unverified "budget=$budget" "last=${line:-none}"
                _sw_trust_drop_keep; return 0
            fi
            sleep 0.5
        done
        # ---- detected: the pane sits on the workspace-trust dialog ----------
        detections=$((detections + 1))
        key=$(_sw_trust_key_on_disk)
        history="${history:+$history,}$key"
        printf 'spawn-worker: worker %s landed on the WORKSPACE-TRUST dialog (detection %d; trust-key-at-detection=%s; recoveries so far=%d) — your-org/nexus-code#1334\n' \
            "$WINDOW_NAME" "$detections" "$key" "$recoveries" >&2
        _sw_trust_log spawn-trust-overlay "detection=$detections" "trust-key-at-detection=$key" \
            "recoveries=$recoveries" "mode=${_SW_TRUST_MODE:-?}" "session-id=${WORKER_SESSION_ID:-${SESSION_ID:-}}"
        if [ "$recoveries" -ge "$max_recover" ]; then
            printf 'spawn-worker: FAILED — worker %s is still on the workspace-trust dialog after %d recover(y|ies) (max %d). The window is left in place.\n' \
                "$WINDOW_NAME" "$recoveries" "$max_recover" >&2
            printf '  trust-key-at-detection history: %s\n' "$history" >&2
            case "$history" in
                *ABSENT*|*false*)
                    printf '  The key was MISSING at a detection: the seed was LOST between seed and boot (a competing writer of %s).\n' "$(_sw_trust_cfg_file)" >&2 ;;
                *)
                    printf '  The key read TRUE at EVERY detection, so a re-seed cannot help (the seeder is a no-op on a present key).\n' >&2
                    printf '  Suspect a KEY-PATH MISMATCH (claude keys on its own canonical form of the cwd) or a second gate.\n' >&2
                    printf '  .projects keys sharing this workdir basename (%s):\n' "$(basename "$WORKDIR")" >&2
                    jq -r '.projects | keys[]' "$(_sw_trust_cfg_file)" 2>/dev/null | grep -F -- "/$(basename "$WORKDIR")" | sed 's/^/    /' >&2 || true ;;
            esac
            _sw_trust_log spawn-trust-failed "detections=$detections" "recoveries=$recoveries" "history=$history"
            _sw_trust_drop_keep
            exit 21
        fi
        recoveries=$((recoveries + 1))
        if ! _sw_trust_respawn "$wid"; then
            _sw_trust_log spawn-trust-failed "detections=$detections" "recoveries=$recoveries" "history=$history" "reason=respawn-refused"
            _sw_trust_drop_keep
            exit 21
        fi
        _sw_trust_log spawn-trust-recover "recovery=$recoveries" "new-window-id=$WID"
        printf 'spawn-worker: recovered worker %s: re-seeded trust (read back true) and re-created the window (recovery %d of %d)\n' \
            "$WINDOW_NAME" "$recoveries" "$max_recover" >&2
        wid="$WID"
    done
}

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
    # CODE comes from $nexus_root; STATE comes from $STATE_DIR. Keeping the
    # two derived from one variable is what let a pinned NEXUS_STATE_DIR be
    # honoured by `ng` and ignored here in the same spawn (#973).
    local state_dir="${STATE_DIR:-$nexus_root/monitor/.state}"
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
        # Record a re-rooted spawn (your-org/nexus-code#577): the launcher lived
        # in a secondary clone and its state was redirected to the primary. This
        # lands in the PRIMARY action log — which is the point — so the event
        # trail shows both that the spawn happened and that it nearly didn't land
        # here at all.
        if [ "${NEXUS_ROOT_REROOTED:-0}" = 1 ]; then
            extra_flags+=( --extra "rerooted-from=$NEXUS_ROOT_SCRIPT" )
        fi
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
    # reply_to: the request-channel id this worker owes an answer to
    # (empty on a normal spawn). Observability only — `ng wrap-up` takes
    # its delivery surface from the EXPLICIT --reply-to flag, never from
    # here, so a worker that omits the flag fails loudly instead of
    # silently routing somewhere the orchestrator can't predict.
    local reply_to="${13:-}"
    # STATE, not code — see the $STATE_DIR block near the NEXUS_ROOT
    # resolution (#973). The `:-` fallback is load-bearing: two suites
    # eval-EXTRACT this function and call it without sourcing the script, so
    # the global does not exist in their shell and a bare $STATE_DIR would
    # trip `set -u`.
    local windows_dir="${STATE_DIR:-$nexus_root/monitor/.state}/windows"
    mkdir -p "$windows_dir" 2>/dev/null || return 0
    local out="$windows_dir/$(wk_encode "$window").json"
    local tmp; tmp=$(mktemp "${out}.XXXXXX" 2>/dev/null) || return 0
    local spawned_at; spawned_at=$(date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    # Same STATE_DIR rule as windows_dir above. This one is a POINTER rather
    # than a write, which is exactly why the first pass missed it — and why it
    # still had to move: the heartbeat it names is written at
    # $STATE_DIR/heartbeat (see _stamp_heartbeat), so leaving this keyed off
    # $nexus_root made the provenance record's `last_activity_ref` name a path
    # where no heartbeat exists whenever the state dir is pinned. A dangling
    # pointer is a quieter failure than a misplaced file, not a smaller one.
    local hb_ref="${STATE_DIR:-$nexus_root/monitor/.state}/heartbeat/$window.json"
    # Topic defaults to window name when not supplied.
    local effective_topic="${topic:-$window}"
    # skeptic_role is a JSON boolean; normalize the 0/1 flag.
    local skeptic_role_json=false
    [ "$skeptic_role" = "1" ] && skeptic_role_json=true
    # `harness` — skills/nexus.agent-delivery §6. THE registration point for a
    # mixed-harness nexus: it is what lets `ng send` pick an adapter without
    # reading any harness's private registry (reading ~/.claude to decide WHICH
    # harness is running is circular). This launcher spawns Claude Code, so it
    # records that; a launcher for another harness records its own, and an
    # absent field degrades to `generic-tmux`, which assumes nothing about the
    # software in the pane.
    #
    # ONE binding, consumed by BOTH writers below. It is a variable rather than
    # two literals because two literals is exactly how this broke: the field
    # was spelled only in the `printf` arm — the one taken when `jq` is
    # ABSENT, i.e. never on this host — so every record the launcher actually
    # wrote omitted it, while a source-text grep for the literal found it and
    # reported the producer conformant (your-org/nexus-code#1085). A single
    # binding cannot diverge per branch.
    local harness="claude-code"
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg window "$window" \
            --arg session_id "$session_id" \
            --arg kind "$kind" \
            --arg spawned_by "orchestrator" \
            --arg harness "$harness" \
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
            --arg reply_to "$reply_to" \
            '{window: $window, session_id: $session_id, kind: $kind,
              spawned_by: $spawned_by, harness: $harness, workdir: $workdir,
              prompt_file: $prompt_file, topic: $topic,
              spawned_at: $spawned_at, last_activity_ref: $last_activity_ref,
              skeptic_mode: $skeptic_mode, skeptic_depth: $skeptic_depth,
              skeptic_role: $skeptic_role, skeptic_target: $skeptic_target,
              skeptic_orig: $skeptic_orig, reply_to: $reply_to}' \
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
        local _e_so _e_rt
        _e_so=$(printf '%s' "$skeptic_orig"         | sed 's/\\/\\\\/g; s/"/\\"/g')
        _e_rt=$(printf '%s' "$reply_to"             | sed 's/\\/\\\\/g; s/"/\\"/g')
        local _e_depth="${skeptic_depth:-0}"
        [[ "$_e_depth" =~ ^[0-9]+$ ]] || _e_depth=0
        local _e_harness
        _e_harness=$(printf '%s' "$harness"         | sed 's/\\/\\\\/g; s/"/\\"/g')
        printf '{"window":"%s","session_id":"%s","kind":"%s","spawned_by":"orchestrator","harness":"%s","workdir":"%s","prompt_file":"%s","topic":"%s","spawned_at":"%s","last_activity_ref":"%s","skeptic_mode":"%s","skeptic_depth":%s,"skeptic_role":%s,"skeptic_target":"%s","skeptic_orig":"%s","reply_to":"%s"}\n' \
            "$_e_window" "$_e_sid" "$_e_kind" "$_e_harness" "$_e_wd" "$_e_pf" \
            "$_e_topic" "$_e_at" "$_e_ref" \
            "$_e_sm" "$_e_depth" "$skeptic_role_json" "$_e_st" "$_e_so" "$_e_rt" \
            > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$out" 2>/dev/null \
        || { rm -f "$tmp" 2>/dev/null; return 0; }
    fi
}

# Add the `harness` key to an EXISTING descriptor that lacks it, touching
# nothing else. The resume path needs this and a fresh spawn does not:
# `_write_provenance_record` is reached only on the fresh path (the resume
# branch exits at its own `exit 0`), so a window that is only ever RESUMED —
# the watcher's crash-recovery path, `--replace`, the orchestrator respawn —
# keeps whatever descriptor it was born with forever. Before
# your-org/nexus-code#1085 that is a descriptor with no `harness`, and
# `ng send` degrades it to `generic-tmux` for the rest of its life. Short-lived
# workers heal on their next fresh spawn; the long-lived windows do not, and the
# orchestrator is precisely the window a worker is told to message.
#
# TWO INVARIANTS, both deliberate:
#   * NEVER CREATE a descriptor here. Its ABSENCE is what marks a window as
#     operator-manual; manufacturing one would silently reclassify a hand-made
#     window as orchestrator-spawned.
#   * NEVER OVERWRITE an existing `harness`. A foreign launcher's value is its
#     business, and this one has no standing to correct it.
# Best-effort throughout, like the writer it complements: no failure here may
# abort a resume.
_ensure_harness_field() {
    local nexus_root="$1" window="$2" harness="${3:-claude-code}"
    local windows_dir="${STATE_DIR:-$nexus_root/monitor/.state}/windows"
    local out="$windows_dir/$(wk_encode "$window").json"
    [ -f "$out" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -e 'has("harness")' "$out" >/dev/null 2>&1 && return 0
    local tmp; tmp=$(mktemp "${out}.XXXXXX" 2>/dev/null) || return 0
    jq --arg harness "$harness" '. + {harness: $harness}' "$out" > "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$out" 2>/dev/null \
        || { rm -f "$tmp" 2>/dev/null; return 0; }
    return 0
}

# ---- resume mode (--resume <window-name | session-id>) -----------------
#
# Mirrors a fresh spawn in everything but the claude invocation:
# `claude --resume <session-id>` instead of a composed prompt. See the
# header comment for the resolution chains and exit codes.

_UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# Claude Code's project-dir slug for a path: EVERY non-alphanumeric
# character becomes '-' ('/' AND '_' alike — your-lab-m → your-lab-m).
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
    local pin="$STATE_DIR/orchestrator-session-id" sid=""
    [ -f "$pin" ] || return 0
    sid=$(tr -d '[:space:]' < "$pin" 2>/dev/null || true)
    if grep -qE "$_UUID_RE" <<<"$sid"; then
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
    local log="$STATE_DIR/action-log.jsonl"
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
    # DIRECTORY from #973's $STATE_DIR, NAME from #941's wk_encode — the two
    # PRs change orthogonal halves of this one path and both halves are needed.
    local cache="$STATE_DIR/spawn-prompts/$(wk_encode "$window").txt"
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
        if grep -qE "$_UUID_RE" <<<"$sid"; then
            if _resume_sid_allowed "$sid" "$window"; then
                printf '%s' "$sid"; return 0
            fi
            echo "spawn-worker: --resume: report $(basename "$r") names the pinned ORCHESTRATOR session for non-coordinator window '$window' — skipping this source (your-nexus#206)" >&2
        fi
        sid=""
    done < <(ls -t "$NEXUS_ROOT/reports/"*.md 2>/dev/null)
    # 2. window-close event (captured freshest-jsonl at close time).
    sid=$(_resume_event_field window-close "$window" '."session-id"')
    if grep -qE "$_UUID_RE" <<<"$sid"; then
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
    local hb="$STATE_DIR/heartbeat/$window.json"
    if [ -f "$hb" ]; then
        sid=$(sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p' "$hb" | head -1)
        if grep -qE "$_UUID_RE" <<<"$sid"; then
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
    if grep -qE "$_UUID_RE" <<<"$sid"; then
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
    if grep -qE "$_UUID_RE" <<<"$RESUME_TARGET"; then
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
    # Same canonicalise-so-the-launcher-gets-an-absolute-path purpose as the
    # fresh-spawn guard above (your-org/nexus-code#642), with two deliberate
    # differences. (1) The `||` arm is NEW: a bare `WORKDIR=$(cd … && pwd)`
    # sets WORKDIR to the EMPTY STRING when the cd fails (the assignment
    # swallows the status), so a workdir deleted between the `-d` test above
    # and this line would spawn against "" rather than refusing — the silent
    # branch of the same class. (2) It stays `pwd`, NOT `pwd -P`: RESUME_SLUG
    # below is derived from this exact string and must match the
    # ~/.claude/projects/<slug> directory Claude Code created from the path the
    # session originally ran in. Resolving symlinks here would silently
    # relocate the transcript lookup and break --resume on any symlinked
    # checkout.
    # The original argument is saved BEFORE the assignment, and the `||` arm
    # reports THAT — not `$WORKDIR`. A failed command substitution assigns the
    # EMPTY STRING to the variable and only then runs the `||` arm, so reading
    # `$WORKDIR` there prints `workdir not a directory: ` with nothing after the
    # colon: a refusal that does not say what it refused.
    #
    # This was a fresh instance of the very class this change closes — the PR's
    # subject is that a bad workdir must be reported legibly, and the fresh-spawn
    # arm above already saved `_sw_workdir_arg` for exactly this reason while
    # this one did not. Caught by the skeptic, not by me, and not by the suite:
    # the only control covered the fresh-spawn arm, so the guard added here had
    # no coverage at all (your-org/nexus-code#648 review, F1/F2).
    _sw_resume_workdir_arg="$WORKDIR"
    WORKDIR=$(CDPATH= cd "$_sw_resume_workdir_arg" && pwd) \
        || { echo "spawn-worker: workdir not a directory: $_sw_resume_workdir_arg" >&2; exit 6; }

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
    HB_FILE="$STATE_DIR/heartbeat/$SOURCE_WINDOW.json"
    if [ -f "$HB_FILE" ]; then
        HB_STATE=$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$HB_FILE" | head -1)
    fi
    PENDING_FILE="$STATE_DIR/pending-tool/$SOURCE_WINDOW.json"
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
    if grep -Fxq -- "$WINDOW_NAME" <<<"$(tmux list-windows -F '#W' 2>/dev/null)"; then
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

    SAFE_NAME=$(wk_encode "$WINDOW_NAME")
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
    NAME_ARG=$(_spawn_name_arg "$WINDOW_NAME")
    PLUGIN_ARG=$(_spawn_plugin_arg "$WINDOW_NAME")
    cat > "$LAUNCHER_TMP" <<LAUNCHER
#!/bin/bash
export NEXUS_ROOT="$NEXUS_ROOT"
export NEXUS_SPAWN_CODE_ROOT="$NEXUS_SPAWN_CODE_ROOT"
export NEXUS_WORKER_WINDOW="$WINDOW_NAME"
# The spawning agent's own tool-shell snapshot, for the guard's frozen-snapshot
# leg (your-org/nexus-code#1477 — see _spawner_snapshot in spawn-worker.sh).
$SPAWNER_SNAPSHOT_EXPORT
# Join the nexus-wide toolchain (PATH += locals/bin, UV_* -> locals/) so
# \`uv\`/\`python\`/nexus tools resolve by name and nothing writes to \$HOME.
# Guarded: a missing env file is a silent no-op, never a launcher failure.
[ -f "\$NEXUS_ROOT/monitor/locals-env.sh" ] && . "\$NEXUS_ROOT/monitor/locals-env.sh" || true
# Soft nproc ceiling: a fork storm degrades this worker, not the node
# (fork-storm class, your-org/nexus-code#487 — rationale in spawn-worker.sh).
# It is applied BEFORE the precondition check below, deliberately: that check
# OBSERVES the ceiling in this process, a child and a grandchild rather than
# trusting that this line worked — note its failure is swallowed by \`|| true\`
# (your-org/nexus-code#589).
$NPROC_ULIMIT_LINE
# Fail-CLOSED PATH-front-shim + nproc precondition (your-org/nexus-code#578,
# generalised in #589). Confirm EVERY shim under monitor/*wrap (gh, pip, pip3,
# sandbox-notify, ...) is reachable in the shell this worker's Bash tool will
# actually run — the launcher's OWN PATH is not enough (the tool shell sources a
# snapshot that can bury the shim dirs) — and that the nproc ceiling above
# reaches a child and a grandchild. The ceiling is DECLARED to the guard here so
# the guard can OBSERVE whether it actually applied. The block itself is emitted
# from the single source monitor/guard-block.sh.in, whose header carries the
# two-name/two-root search and the refusal contract: a MISSING guard is a
# REFUSAL (78), not a warning, and a guard that ran but could not adjudicate
# exits 79 and is recorded as NOT CHECKED rather than folded into a pass.
export NEXUS_ASSERT_NPROC_EXPECT="$WORKER_NPROC_LIMIT"
$SHIM_GUARD_BLOCK
# Pin worker cwd (issue #95) — claude --resume must also run from the
# session's project dir or Claude Code won't find the transcript.
cd "$WORKDIR" || exit 1
rm -f $LAUNCHER_TMP
# CLAUDE_CODE_SANDBOXED=1: see the fresh launcher (#1334).
CLAUDE_CODE_SANDBOXED=1 \\
CLAUDE_CODE_RESUME_THRESHOLD_MINUTES=999999999 \\
CLAUDE_CODE_RESUME_TOKEN_THRESHOLD=999999999999 \\
    "$CLAUDE_BIN" --dangerously-skip-permissions${NAME_ARG:+ $NAME_ARG}${PLUGIN_ARG:+ $PLUGIN_ARG} $HOOKS_FLAG --resume "$SESSION_ID"$NUDGE_ARG
LAUNCHER
    chmod +x "$LAUNCHER_TMP"

    # WORKDIR is final on the resume path only from here (it is resolved from
    # the window's traces well after the fresh-spawn canonicalisation).
    _seed_workspace_trust

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
    # your-org/nexus-code#1051 — NO DEAD-PANE GUARD HERE, AND THE REASON IS THE
    # PRIMITIVE, NOT THE ADJACENCY.
    #
    # `#745` is a **`paste-buffer`** defect. `send-keys` was its measured-SAFE
    # CONTROL, and monitor/_pane-live.sh records both: `paste-buffer` into a dead
    # pane killed the server 20/20, `send-keys` into the same dead pane survived
    # 10/10 — "`send-keys` into the same dead pane is harmless". paste-followup.sh
    # says the same thing from the other side, offering `tmux send-keys` as the way
    # to "poke a corpse". This file contains no executable `paste-buffer` at all.
    #
    # So the server-death hazard is NOT reachable from this line, whatever the pane's
    # state. An earlier revision of this comment asserted that `#745` was a
    # `send-keys` defect and instructed a successor to add `_tmux_pane_is_dead` if
    # the send were ever separated from its window creation. That premise was FALSE,
    # and the instruction would have made someone pay a real cost — see below — for a
    # hazard that does not exist on this path.
    #
    # The adjacency (`$WID` is assigned by the nearest `tmux new-window` above, in
    # this execution, no branch and no reassignment) is real and worth knowing, but it
    # is not what makes this safe. If a future edit separates the send from the
    # creation, the send is STILL safe; what you would lose is only the guarantee that
    # the window exists at all, whose failure mode is a `send-keys` that does nothing.
    #
    # AND THE GUARD WOULD COST MORE THAN IT BUYS. `_tmux_pane_is_dead` is
    # deliberately fail-CLOSED: it returns "dead" — REFUSE — whenever it cannot tell,
    # and one of those arms is `tmux list-panes` failing, which its own comment
    # attributes to "a fork failure under the worker RLIMIT_NPROC ceiling, or a busy
    # socket". This nexus runs workers under exactly that ceiling. On the PASTE path
    # that trade is right, because there the primitive really is lethal. Here it would
    # convert a transient tmux hiccup into a FAILED SPAWN to prevent nothing.
    #
    # NO DISTANCE IS QUOTED ON PURPOSE. "N lines up" is a line number wearing a
    # disguise: an earlier draft said 7, and adding the comment itself moved it to 29.
    _sw_trust_keep_launcher resume
    tmux send-keys -t "$WID" "$LAUNCHER_TMP" Enter

    _seed_lifecycle_anchors "$NEXUS_ROOT" "$WINDOW_NAME" "$WORKDIR" \
        "mode=resume" "session-id=$SESSION_ID"

    # Heal a pre-#1085 descriptor in place. See _ensure_harness_field: this is
    # the ONLY path on which a long-lived window's descriptor is ever revisited.
    _ensure_harness_field "$NEXUS_ROOT" "$WINDOW_NAME"

    # Post-spawn trust verification (your-org/nexus-code#1334) — same block as
    # the fresh path; a resumed worker meets the same dialog.
    _sw_trust_verify "$WID"

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
#
# KNOWN MEMBER OF THE SILENT-NO-OP CLASS, DELIBERATELY UNFIXED (#589).
# This is the same shape the shim precondition above used to have —
# `if [ -x <helper> ]` with no else, so an absent helper is indistinguishable
# from a passing check — and it is on the SPAWN path, where refusing WOULD be
# safe. It is left alone here only because closing it needs its own test and
# negative control; shipping it unverified alongside a change about guards
# that silently do not run would be the same defect wearing a fix's clothes.
#
# It is pinned as still-present by the manifest in
# monitor/watcher/test-guard-closure-boundary.sh, so fixing it reddens that
# suite and forces the manifest to be updated with it. Note the boundary
# sentence there is drawn on guard KIND (shim-precondition), NOT on execution
# path — precisely because a path-drawn bound would claim this site is closed
# when it is not.
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

# ---- clone freshness (your-org/nexus-code#814) ----------------------------
# Emit, into the prompt, how old THIS clone's knowledge of its remote is.
#
# WHY. A worker pinned into a stale clone draws a repo-wide NEGATIVE from an
# object store that is missing the very commits that would refute it, and every
# check it runs agrees with the wrong answer. Measured 2026-08-08 in
# `work/kompot_revisions-272refine`: `origin/main` at `d501f4f` (2026-07-27)
# against a real `main` of `a3ee52d` (2026-08-08), with six commits that
# redesigned the work simply ABSENT from the object store. The worker asked
# "is there a newer design anywhere in the repo?", ran `git branch -a` and
# `git log --all --not HEAD`, got clean answers, and was wrong by nine days —
# it published a figure with inverted labels. `git branch -a` / `git log --all`
# enumerate the LOCAL store; they cannot see what was never fetched.
#
# ⚠️  NOT `FETCH_HEAD` mtime, and this is load-bearing. #814 proposed that
# probe and then DISPROVED its own suggestion: a FAILED fetch truncates
# `.git/FETCH_HEAD` to zero bytes AND updates its mtime, so it reads FRESHER
# than the tree is in exactly the case that matters most — a clone that cannot
# fetch at all. Re-measured here on git 2.17.1 before writing this:
#
#     baseline (successful fetch) : FETCH_HEAD size=197  mtime=03:30:35
#     after an auth-FAILED fetch  : FETCH_HEAD size=0    mtime=03:30:37
#     origin/main                 : unchanged, still the pre-failure commit
#
# The mtime moved forward two seconds while the clone learned nothing. Do not
# reintroduce it.
#
# What IS emitted is a remote-tracking ref's commit date: no network call, and
# unfalsifiable by a failed fetch (a fetch that fails does not move the ref).
#
# WHICH ref, and why not a hardcoded `origin/main` as #814 suggested: a clone
# whose default branch is not `main` has no `origin/main`, so that form emits
# NOTHING — a silent absence in the freshness signal, which is the same defect
# class one level up. Resolve in order of relevance and NAME the winner, and
# when none resolves say so loudly rather than emitting a blank.
_clone_freshness_block() {
    local dir="$1" _rr=0
    if [ "${_SW_RR_OK:-0}" -ne 1 ]; then
        # Degraded mode: narrower predicate, same never-walk-up property. Two
        # valued, so there is no UNDETERMINED arm to reach here.
        if _sw_has_own_history_fallback "$dir"; then
            _rr=0
        else
            printf -- '- Clone freshness: NOT A GIT REPOSITORY (%s) — no remote-tracking state to report.\n' "$dir"
            return 0
        fi
    else
    # your-org/nexus-code#1245. NOT `git -C "$dir" rev-parse --git-dir`: that
    # walks UP and answers about the nearest ENCLOSING repository, so for a
    # non-repo workdir under work/ it returns rc 0 and every line below reports
    # the NEXUS's branch and HEAD as this clone's. Measured on `dev` @ 989b888:
    # a plain directory under work/ printed `dev` / `989b888` as its own
    # freshness. This block's entire purpose is to make a worker's negative
    # claims datable; dating them against a different repository is the defect
    # it exists to prevent, one level up.
    rr_has_own_history "$dir" || _rr=$?
    fi
    if [ "$_rr" -eq 1 ]; then
        # BYTE-IDENTICAL to the pre-#1245 wording, deliberately. What #1245
        # changes is WHICH directories reach this arm (a non-repo under a repo
        # now does, instead of silently inheriting the enclosing branch/HEAD) —
        # not what it says. `test-spawn-worker-reply-to.sh` composes this exact
        # line into an independent byte-for-byte reference, and richer wording
        # bought a diagnostic nobody asked for at the cost of that contract.
        printf -- '- Clone freshness: NOT A GIT REPOSITORY (%s) — no remote-tracking state to report.\n' "$dir"
        return 0
    fi
    if [ "$_rr" -ne 0 ]; then
        # rc 3 — UNDETERMINED. Deliberately NOT phrased as "not a git
        # repository": that is a confident negative, and the whole point of
        # this block is that a negative claim be trustworthy (#1245).
        printf -- '- Clone freshness: COULD NOT DETERMINE whether %s is a repository of its\n' "$dir"
        printf -- '  own (kind=%s, reason=%s). This is NEITHER "fresh" NOR "not a repo" —\n' \
            "${RR_KIND:-unknown}" "${RR_REASON:-unknown}"
        printf -- '  treat this clone'"'"'s remote knowledge as UNKNOWN and fetch before any\n'
        printf -- '  negative claim about the repository.\n'
        return 0
    fi
    local head_line branch
    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
    # NB: `git branch --show-current` does not exist on git 2.17.1 and dies
    # silently mid-chain; `rev-parse --abbrev-ref HEAD` is the portable form.
    head_line=$(git -C "$dir" log -1 --format='%h %ci (%cr)' HEAD 2>/dev/null) || head_line=""
    # ORDER IS LOAD-BEARING (your-org/nexus-code#814 skeptic F2). `@{upstream}`
    # used to be FIRST, which handed every worker past its first push its OWN
    # push as the primary freshness line — `git push` writes
    # refs/remotes/origin/<branch> LOCALLY without fetching anything, so the
    # line reads "0 seconds ago" while the clone has learned nothing. Measured
    # on a clone blind to three upstream commits, after a `push -u`:
    #
    #     origin/operator/mytask c3849fb … (0 seconds ago)  [resolved via @{upstream}]
    #     clone origin/main = bb595ec     real main = f8d7c07  (all 3 commits ABSENT)
    #
    # The remote's DEFAULT branch is the ref a "is there something newer in
    # this repo?" question is actually about, and it is the one a worker's own
    # push cannot touch. `@{upstream}` survives only as a last resort, labelled.
    local ref="" chosen=""
    for cand in 'origin/HEAD' 'origin/main' 'origin/master' 'origin/dev' '@{upstream}'; do
        if git -C "$dir" rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
            ref=$(git -C "$dir" rev-parse --abbrev-ref "$cand" 2>/dev/null) || ref="$cand"
            chosen="$cand"
            break
        fi
    done
    printf -- '- Clone freshness (your-org/nexus-code#814) — how old this clone'"'"'s knowledge\n'
    printf -- '  of its remote is, measured with NO network call:\n'
    printf -- '    HEAD           : %s%s\n' "${head_line:-<unreadable>}" \
        "${branch:+  [branch $branch]}"
    if [ -n "$ref" ]; then
        local ref_line
        ref_line=$(git -C "$dir" log -1 --format='%h %ci (%cr)' "$ref" 2>/dev/null) || ref_line=""
        printf -- '    %-15s: %s  [resolved via %s]\n' "$ref" "${ref_line:-<unreadable>}" "$chosen"
        if [ "$chosen" = '@{upstream}' ]; then
            printf -- '      ^ NOTE: no default-branch ref resolved, so this is YOUR OWN branch'"'"'s\n'
            printf -- '        tracking ref — `git push` advances it locally without fetching\n'
            printf -- '        anything, so a recent date here may be your own push and NOT\n'
            printf -- '        evidence that this clone knows the remote. Fetch before any\n'
            printf -- '        negative claim.\n'
        fi
    else
        printf -- '    remote-tracking: NONE RESOLVED (no @{upstream}, origin/HEAD, origin/main,\n'
        printf -- '                     origin/master or origin/dev) — this clone'"'"'s knowledge of\n'
        printf -- '                     the remote is UNKNOWN, not fresh. Fetch before any negative\n'
        printf -- '                     claim about the repository.\n'
    fi
    # NO "newest remote-tracking ref anywhere in this clone" line. The first
    # version emitted one, calling it "the BOUND on your knowledge". It is not:
    # `git push` writes refs/remotes/origin/<branch> locally, so the bound
    # advances to NOW on the worker's own push while the clone learns nothing —
    # the exact same shape as the FETCH_HEAD mtime probe this block rejects (a
    # LOCAL operation advancing a REMOTE-knowledge indicator), and falsified in
    # the OPTIMISTIC direction.
    #
    # It was added to suppress a false alarm: a clone made minutes ago on `dev`
    # reports `origin/main` as weeks old because `main` genuinely has not moved.
    # That trade runs the wrong way. A false alarm costs one `git fetch`; a
    # false reassurance costs your-org/nexus-code#814 — a published figure with
    # inverted labels. Every other guard in this batch takes the conservative
    # side of exactly this trade, and so does this one now: an unmoved default
    # branch reads old, and that is the correct bias.
    printf -- '  A NEGATIVE CLAIM ABOUT THIS REPOSITORY IS ONLY AS OLD AS THAT DATE.\n'
    printf -- '  `git branch -a` and `git log --all` read the LOCAL object store: commits\n'
    printf -- '  pushed since are ABSENT, and every check you run will agree with the wrong\n'
    printf -- '  answer. `git fetch` first, or scope the claim to a sha and a date.\n'
    printf -- '  Do NOT reach for `.git/FETCH_HEAD` mtime as a freshness check — a FAILED\n'
    printf -- '  fetch truncates it to zero bytes and updates its mtime, so it reads fresher\n'
    printf -- '  than the tree is in precisely the case that matters (measured: size 197 -> 0,\n'
    printf -- '  mtime +2s, `origin/main` unmoved).\n'
}

# ── your-org/nexus-code#1260 — reconcile the PROSE against the TREE ────────
#
# A spawn prompt's prose names a clone and a ref ("Clone `work/X`, fresh at
# `dev` @ `<sha>`"). That claim is hand-authored by the orchestrator and is the
# line a worker reads as ground truth. Nothing compared it against the tree
# that was actually delivered. Measured three times in one day on this board:
# a clone delivered on `main` 4 days stale, one on a feature branch 3 behind,
# and one on `dev` 42 commits behind — each announced as fresh at a `dev` sha.
#
# The failure direction is the bad one. Every measurement a worker then makes
# SUCCEEDS and agrees with itself, on a tree nobody named. Two of the three
# briefs named this very issue by number and instructed the agent to verify its
# own ref, which is why a note is not enough: the agent cannot verify what it
# was told before it starts, and by then it has already been told.
#
# WARN, NEVER REFUSE (the issue is explicit). A prompt may legitimately name a
# ref the worker is expected to fetch and check out itself. The obligation is
# that the worker be TOLD, not left to notice.
#
# WHY IT ANCHORS ON CANDIDATE LINES rather than scanning the whole body: a
# brief quotes shas about other repositories all the time. Anchoring on the
# workdir's own name, or on the recurring "this is your clone" phrasings, is
# what keeps a warning channel from becoming noise. A missed claim costs the
# status quo; a false one costs a line the worker must adjudicate.
_prompt_tree_reconcile() {
    local dir="$1" pf="$2"
    [ "${_SW_RR_OK:-0}" -eq 1 ] || return 0
    [ -n "$pf" ] && [ -r "$pf" ] || return 0

    local _rr=0
    rr_has_own_history "$dir" || _rr=$?
    # No own history, or undetermined: the freshness block above has already
    # said so. "That sha is not present" would be a confident negative about a
    # tree we cannot read — the #1245 arm owns this case.
    [ "$_rr" -eq 0 ] || return 0

    local head_sha branch base
    head_sha=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || return 0
    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
    base=$(basename -- "$dir")

    # `$base` is a REGEX here, not a literal — a metacharacter in the basename
    # silently loses the anchor. Escape it (your-org/nexus-code#1260 skeptic).
    local base_re; base_re=$(printf '%s' "$base" | sed 's/[][^$.*+?(){}|\\/]/\\&/g')
    local lines
    lines=$(grep -aEi -e "$base_re" -e 'fresh at|freshly cloned|checked out on|already on|now on|on branch|your clone|clone is|is checked out|^[[:space:]]*Clone:' \
                -- "$pf" 2>/dev/null | sed -n '1,60p') || lines=''
    [ -n "$lines" ] || return 0

    # SINGLE-quoted patterns throughout: a backtick inside a double-quoted
    # shell word is command substitution, and these patterns are dense with
    # backticks by construction (your-org/nexus-code#1157).
    local claimed_shas claimed_branches out='' sha br
    # BOTH spellings. Measured over the 1,874 real prompts in
    # monitor/.state/spawn-prompts: `` at `sha` `` occurs 293 times and
    # `` @ `sha` `` only 174 — the ORIGINAL pattern matched the LESS common
    # form. The suite missed this because its fixtures were written from the
    # phrasings the code already supported rather than drawn from the corpus.
    claimed_shas=$(printf '%s\n' "$lines" \
        | grep -oE '(@|[[:space:]]at)[[:space:]]*`?[0-9a-f]{7,40}`?' 2>/dev/null \
        | grep -oE '[0-9a-f]{7,40}' | sort -u) || claimed_shas=''
    # TWO CLASSES, because they carry different evidence.
    #
    # EXPLICIT forms ("checked out on", "fresh at", "already on", "now on",
    # "on branch") SAY the token is a branch. They are ungated.
    #
    # The BARE `, on `X`` form does not. Measured over the 1,874 real prompts in
    # monitor/.state/spawn-prompts/, it appears 60 times and is used for a
    # branch (`, on `dev``), a REPO (`, on `your-org/nexus-code``, 8 prompts)
    # and a FILE (`, on `test-erofs-escalation.sh``). Adding it ungated would
    # manufacture confident warnings about claims the prompt never made.
    #
    # `%` is in the class so a branch named `100%-coverage` is captured whole
    # rather than truncated to `100` and reported as a mismatch it invented.
    # BACKTICKED explicit claims are UNGATED; UNBACKTICKED ones are gated
    # exactly like the bare `, on X` form. The gating rationale below applies
    # verbatim to this arm and it did not have it, which made the arm extract
    # ENGLISH from prose. Measured over all 1,875 real prompts, the ungated arm
    # produced a claim in 123 of them and its commonest tokens included `the`
    # (15), `disk` (9), `branch` (6), `a` (5) and `is` (4) — beside real
    # branches like `operator/autolink-removal` (22) and `dev` (15). A warning
    # that fires on prose is a confident FALSE POSITIVE in a diagnostic, and a
    # diagnostic that cries wolf on the common path is worse than none: once a
    # reader has seen ``names branch `the``, they stop reading the real ones.
    #
    # A backtick is the AUTHOR'S OWN MARK that a token is an identifier, so it
    # is evidence and it is honoured. Absent that mark, require the token to
    # resolve as a ref. Measured, that pair drops 18 prose tokens and readmits
    # zero, while recovering the ONE real branch a plain backtick requirement
    # would have lost (`operator/post-recovery-fixes`, written unbackticked in
    # one prompt and backticked elsewhere).
    claimed_branches=$(printf '%s\n' "$lines" \
        | grep -oEi '(checked out on|fresh at|already on|now on|on branch)[[:space:]]+`[A-Za-z0-9._/%-]+`' 2>/dev/null \
        | sed -E 's/.*`([A-Za-z0-9._/%-]+)`$/\1/' | sort -u) || claimed_branches=''
    local loose_branches
    loose_branches=$(printf '%s\n' "$lines" \
        | grep -oEi '(checked out on|fresh at|already on|now on|on branch)[[:space:]]+[A-Za-z0-9._/%-]+' 2>/dev/null \
        | sed -E 's/.*[[:space:]]([A-Za-z0-9._/%-]+)$/\1/' | sort -u) || loose_branches=''
    local weak_branches
    weak_branches=$(printf '%s\n' "$lines" \
        | grep -oEi ',[[:space:]]*on[[:space:]]+`?[A-Za-z0-9._/%-]+`?' 2>/dev/null \
        | sed -E 's/.*[[:space:]]`?([A-Za-z0-9._/%-]+)`?$/\1/' | tr -d '`' | sort -u) || weak_branches=''

    for sha in $claimed_shas; do
        if ! git -C "$dir" cat-file -e "${sha}^{commit}" 2>/dev/null; then
            out="${out}    - the prompt names @ ${sha}, which is NOT PRESENT in this clone.\n"
        elif ! git -C "$dir" merge-base --is-ancestor "$sha" "$head_sha" 2>/dev/null; then
            out="${out}    - the prompt names @ ${sha}, which is present but is NOT AN ANCESTOR of HEAD.\n"
        fi
    done

    # A token that resolves to no ref here is not evidence — but that is only a
    # reason for SILENCE on the ambiguous form. Applying it to the explicit
    # forms too would silence the ORIGINATING INCIDENT: a clone delivered on
    # `main` whose prompt names a `dev` that was never fetched has no local
    # `dev` ref, and that is exactly the case #1260 exists for.
    _sw_ref_exists() {
        git -C "$1" rev-parse --verify --quiet "refs/heads/$2" >/dev/null 2>&1 && return 0
        git -C "$1" rev-parse --verify --quiet "refs/remotes/origin/$2" >/dev/null 2>&1
    }
    _sw_branch_mismatch() {   # <token> <gated:0|1>
        local br="$1" gated="$2"
        [ -n "$branch" ] || return 1
        [ "$br" != "$branch" ] || return 1
        # A hex token here is a sha that landed in the branch bucket; the sha
        # loop already adjudicated it.
        [[ "$br" =~ ^[0-9a-f]{7,40}$ ]] && return 1
        [ "$gated" -eq 1 ] && { _sw_ref_exists "$dir" "$br" || return 1; }
        return 0
    }
    for br in $claimed_branches; do
        if _sw_branch_mismatch "$br" 0; then
            out="${out}    - the prompt names branch \`${br}\`; this clone is on \`${branch}\`.\n"
        fi
    done
    for br in $loose_branches; do
        case $'\n'"$claimed_branches"$'\n' in *$'\n'"$br"$'\n'*) continue ;; esac
        if _sw_branch_mismatch "$br" 1; then
            out="${out}    - the prompt names branch \`${br}\`; this clone is on \`${branch}\`.\n"
        fi
    done
    for br in $weak_branches; do
        case $'\n'"$loose_branches"$'\n' in *$'\n'"$br"$'\n'*) continue ;; esac
        # NOT `printf … | grep -q … && continue`. Under `pipefail`, `grep -q`
        # exits on the FIRST match, `printf` takes SIGPIPE and the pipeline
        # reports rc 141 — a false failure on exactly the inputs that match.
        # I fixed this idiom once already in this same function and then
        # reintroduced it here while fixing something else, which is the
        # argument for the lint existing rather than for remembering the rule.
        # `case` over a newline-delimited list needs no pipe.
        case $'\n'"$claimed_branches"$'\n' in *$'\n'"$br"$'\n'*) continue ;; esac
        if _sw_branch_mismatch "$br" 1; then
            out="${out}    - the prompt names branch \`${br}\`; this clone is on \`${branch}\`.\n"
        fi
    done

    [ -n "$out" ] || return 0
    printf -- '\n'
    printf -- '  ⚠️  PROMPT/TREE MISMATCH (your-org/nexus-code#1260) — the prompt'"'"'s prose\n'
    printf -- '      disagrees with the tree you were actually given:\n'
    # `printf "%b"`, never `printf -- "$out"`: a `%` in a branch name would be
    # read as a CONVERSION and silently eat the text (measured: "branch
    # %s-feature" printed as "branch -feature"). The data is never the format.
    printf '%b' "$out"
    printf -- '      MEASURED: HEAD is %s on branch %s.\n' \
        "$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)" "${branch:-<detached>}"
    printf -- '      The BANNER above is measured; the prompt'"'"'s ref claim is asserted.\n'
    printf -- '      Trust the banner. Fetch and check out explicitly if the prompt'"'"'s ref\n'
    printf -- '      is the one you are meant to work against, and say which you used.\n'
}

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

# Reply-to override body. Extracted the SAME awk way as the floor, from a
# SEPARATE H2 so the floor extraction above is untouched (its `/^## /` stop
# already terminates on any following H2 — this section adds no new
# boundary). Read ONLY in --reply-to mode; a normal spawn never touches it,
# which is what makes the default composed prompt byte-identical.
# `<REQUEST_ID>` is substituted with the id validated above (charset
# [A-Za-z0-9_-], so it is inert as sed replacement text).
reply_to_body=
if [ -n "$REPLY_TO" ]; then
    reply_to_body=$(awk '
      /^## Reply-to wrap-up override[[:space:]]*$/ { in_sec=1; next }
      in_sec && /^## /                             { exit }
      in_sec                                       { print }
    ' "$FLOOR_FILE")
    if [ -z "$(printf '%s' "$reply_to_body" | tr -d '[:space:]')" ]; then
        echo "spawn-worker: '## Reply-to wrap-up override' section empty/missing in $FLOOR_FILE" >&2
        exit 18
    fi
    reply_to_body=$(printf '%s\n' "$reply_to_body" | sed "s|<REQUEST_ID>|$REPLY_TO|g")
    # --issue <n>: the worker wraps up to BOTH surfaces. Append the concrete
    # command rather than leaving the generic "add --issue <n>" prose, so the
    # worker has one copy-pasteable line.
    if [ -n "$ISSUE_NUM" ]; then
        reply_to_body="$reply_to_body

**This spawn wants BOTH surfaces.** Your issue is \`#$ISSUE_NUM\`, so the
exact hand-off command is:

    monitor/ng wrap-up --reply-to $REPLY_TO --issue $ISSUE_NUM <report-path>

That posts the normal upload + link comment on the issue AND delivers the
channel reply."
    fi
fi

# Sanitize window name for filenames. Tempfiles honour TMPDIR (same
# convention as bootstrap-install.sh and _respawn.sh's RESPAWN_TMPDIR):
# production runs with TMPDIR unset land in /tmp as before, while test
# harnesses point TMPDIR at a per-test dir so concurrent suite runs
# can't glob-inspect (or delete) each other's launcher files.
SAFE_NAME=$(wk_encode "$WINDOW_NAME")
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
    grep -qE "$_UUID_RE" <<<"$WORKER_SESSION_ID" || WORKER_SESSION_ID=""
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
    _clone_freshness_block "$WORKDIR"
    _prompt_tree_reconcile "$WORKDIR" "$PROMPT_FILE"
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
    # Conditional fourth block: the reply-to wrap-up override. Placed AFTER
    # the floor (so it visibly supersedes the floor's issue-form wrap-up
    # bullet by recency and by its own explicit wording) and BEFORE the task
    # prompt (so per-spawn task instructions still have the last word).
    # Empty on every non---reply-to spawn ⇒ zero bytes emitted.
    if [ -n "$reply_to_body" ]; then
        printf '%s\n\n---\n\n' "$reply_to_body"
    fi
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
if grep -Fxq -- "$WINDOW_NAME" <<<"$(tmux list-windows -F '#W' 2>/dev/null)"; then
    rm -f "$PROMPT_TMP"
    echo "spawn-worker: tmux window '$WINDOW_NAME' already exists" >&2
    exit 7
fi

# ── your-org/nexus-code#1081 — THE ADDRESS SPACE IS WIDER THAN tmux ──────
#
# The delivery contract pins identity to the tmux WINDOW NAME
# (skills/nexus.agent-delivery/SKILL.md §1) and takes on responsibility for that
# address being unambiguous. The refusal above discharges it against the LIVE
# tmux window list — a population strictly SMALLER than the one the property
# must hold over. The preferred transport resolves a name against the harness's
# peer set, which has included RETIRED nexus window names surfaced as the
# operator's sessions on other machines. Measured on 2026-08-27: 13 addressable
# peers against 8 live windows, one of them `fig4e-skeptic` — a retired nexus
# name that `-n fig4e-skeptic` would have re-issued, making the name denote two
# entries at once.
#
# WHY THIS WARNS AND DOES NOT REFUSE. Name reuse after retirement is a
# SUPPORTED workflow, not an accident: `#73` D2 built structural support for it
# (the spawn event's ts becomes the lifecycle birth so a stale wrap-up from the
# prior life is rejected), and test-integration/test-same-name-recycle.sh exists
# to hold it. Refusing every name this nexus has ever used would break a
# designed behaviour to close a narrower hazard — the fix costing more than the
# defect. So the LIVE collision stays a hard refusal and a RECYCLE is surfaced.
#
# WHY THE SCRIPT CANNOT CLOSE THIS ITSELF. The harness's peer list is available
# to an AGENT, never to a shell script — there is no command this file could
# run to enumerate it. So the residual check is an ORCHESTRATOR obligation and
# is written down as one in the contract, next to the identity rule it
# qualifies. An undocumented boundary is a false promise; a documented one is a
# boundary.
# KEYED ON THE ACTION LOG FIRST, and that is a correction rather than a
# refinement (your-org/nexus-code#1081 skeptic). The first version read ONLY
# `windows/<key>.json` — and `"file:windows/{s}.json"` is a member of
# `BK_RETIRE_SURFACES`, so `ng retire-window`, the verb the skill tells the
# orchestrator to PREFER, DELETES the evidence this check reads. Coverage would
# have shrunk precisely as operators adopted the preferred verb: a name retired
# properly becomes indistinguishable from a name never used, which is the
# silent-zero shape wearing a bookkeeping costume.
#
# `monitor/.state/action-log.jsonl` is NOT in BK_RETIRE_SURFACES and is
# append-only, so a spawn recorded there survives retirement. Verified: the
# retired name `fig4e-skeptic` has 6 action-log entries and would be caught.
# The `windows/` record is kept as a second, cheaper witness — either is enough.
#
# ONE grep, no pipe: `grep -aF … | grep -q …` is the SIGPIPE idiom this file was
# already caught reintroducing once tonight.
_sw_name_seen_before() {
    local name="$1" n
    if [ -r "$STATE_DIR/action-log.jsonl" ]; then
        n=$(grep -acF "\"window\":\"${name}\"" "$STATE_DIR/action-log.jsonl" 2>/dev/null)
        [ "${n:-0}" -gt 0 ] && return 0
    fi
    [ -e "$STATE_DIR/windows/$(wk_encode "$name").json" ]
}
_sw_prior_record="$STATE_DIR/windows/$(wk_encode "$WINDOW_NAME").json"
if _sw_name_seen_before "$WINDOW_NAME"; then
    echo "spawn-worker: NOTE — the window name '$WINDOW_NAME' has been used in this nexus before (action log, and/or $_sw_prior_record)." >&2
    echo "spawn-worker:        tmux freed the name, so this spawn is legitimate; but the delivery transport's address space is WIDER than the live window list and may still hold the earlier bearer (your-org/nexus-code#1081)." >&2
    echo "spawn-worker:        Before relying on '$WINDOW_NAME' as a delivery address, enumerate peers with ListAgents and confirm exactly ONE row bears it. READ-ONLY: never message a peer that is one of the operator's other sessions." >&2
fi

# Spawn-prompt cache. Copy the fully-composed prompt to
# $STATE_DIR/spawn-prompts/<window>.txt so the
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
SPAWN_PROMPT_CACHE_DIR="$STATE_DIR/spawn-prompts"
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
# longjob-watch dispatcher arming (your-org/nexus-code#1535): `--plugin-dir
# <dir>` or EMPTY, decided once here for both launcher shapes. Empty leaves
# the launchers byte-identical to the pre-#1535 form; the reason is on
# stderr and in monitor/.state/longjob/arming.log.
PLUGIN_ARG=$(_spawn_plugin_arg "$WINDOW_NAME")
if [ "$USE_LOOP_WRAPPER" -eq 1 ]; then
cat > "$LAUNCHER_TMP" <<LAUNCHER
#!/bin/bash
export NEXUS_ROOT="$NEXUS_ROOT"
export NEXUS_SPAWN_CODE_ROOT="$NEXUS_SPAWN_CODE_ROOT"
export NEXUS_WORKER_WINDOW="$WINDOW_NAME"
# The spawning agent's own tool-shell snapshot, for the guard's frozen-snapshot
# leg (your-org/nexus-code#1477 — see _spawner_snapshot in spawn-worker.sh).
$SPAWNER_SNAPSHOT_EXPORT
# Join the nexus-wide toolchain (PATH += locals/bin, UV_* -> locals/) so
# \`uv\`/\`python\`/nexus tools resolve by name and nothing writes to \$HOME.
# Guarded: a missing env file is a silent no-op, never a launcher failure.
[ -f "\$NEXUS_ROOT/monitor/locals-env.sh" ] && . "\$NEXUS_ROOT/monitor/locals-env.sh" || true
# Soft nproc ceiling: a fork storm degrades this worker, not the node
# (fork-storm class, your-org/nexus-code#487 — rationale in spawn-worker.sh).
# It is applied BEFORE the precondition check below, deliberately: that check
# OBSERVES the ceiling in this process, a child and a grandchild rather than
# trusting that this line worked — note its failure is swallowed by \`|| true\`
# (your-org/nexus-code#589).
$NPROC_ULIMIT_LINE
# Fail-CLOSED PATH-front-shim + nproc precondition (your-org/nexus-code#578,
# generalised in #589). Confirm EVERY shim under monitor/*wrap (gh, pip, pip3,
# sandbox-notify, ...) is reachable in the shell this worker's Bash tool will
# actually run — the launcher's OWN PATH is not enough (the tool shell sources a
# snapshot that can bury the shim dirs) — and that the nproc ceiling above
# reaches a child and a grandchild. The ceiling is DECLARED to the guard here so
# the guard can OBSERVE whether it actually applied. The block itself is emitted
# from the single source monitor/guard-block.sh.in, whose header carries the
# two-name/two-root search and the refusal contract: a MISSING guard is a
# REFUSAL (78), not a warning, and a guard that ran but could not adjudicate
# exits 79 and is recorded as NOT CHECKED rather than folded into a pass.
export NEXUS_ASSERT_NPROC_EXPECT="$WORKER_NPROC_LIMIT"
$SHIM_GUARD_BLOCK
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
# CLAUDE_CODE_SANDBOXED=1: exported (not prefixed) so claude-loop.sh's own
# \`claude --continue\` re-invocations carry it too. See the fresh direct
# launcher and spawn-worker.sh's "PRIMARY FIX" paragraph (#1334).
export CLAUDE_CODE_SANDBOXED=1
exec "\$NEXUS_ROOT/monitor/claude-loop.sh" \\
    --window "$WINDOW_NAME" \\
    --prompt-file "$PROMPT_TMP" \\
    $HOOKS_FLAG${MODEL_ARG:+ $MODEL_ARG}${PLUGIN_ARG:+ $PLUGIN_ARG}
LAUNCHER
else
NAME_ARG=$(_spawn_name_arg "$WINDOW_NAME")
cat > "$LAUNCHER_TMP" <<LAUNCHER
#!/bin/bash
export NEXUS_ROOT="$NEXUS_ROOT"
export NEXUS_SPAWN_CODE_ROOT="$NEXUS_SPAWN_CODE_ROOT"
export NEXUS_WORKER_WINDOW="$WINDOW_NAME"
# The spawning agent's own tool-shell snapshot, for the guard's frozen-snapshot
# leg (your-org/nexus-code#1477 — see _spawner_snapshot in spawn-worker.sh).
$SPAWNER_SNAPSHOT_EXPORT
# Join the nexus-wide toolchain (PATH += locals/bin, UV_* -> locals/) so
# \`uv\`/\`python\`/nexus tools resolve by name and nothing writes to \$HOME.
# Guarded: a missing env file is a silent no-op, never a launcher failure.
[ -f "\$NEXUS_ROOT/monitor/locals-env.sh" ] && . "\$NEXUS_ROOT/monitor/locals-env.sh" || true
# Soft nproc ceiling: a fork storm degrades this worker, not the node
# (fork-storm class, your-org/nexus-code#487 — rationale in spawn-worker.sh).
# It is applied BEFORE the precondition check below, deliberately: that check
# OBSERVES the ceiling in this process, a child and a grandchild rather than
# trusting that this line worked — note its failure is swallowed by \`|| true\`
# (your-org/nexus-code#589).
$NPROC_ULIMIT_LINE
# Fail-CLOSED PATH-front-shim + nproc precondition (your-org/nexus-code#578,
# generalised in #589). Confirm EVERY shim under monitor/*wrap (gh, pip, pip3,
# sandbox-notify, ...) is reachable in the shell this worker's Bash tool will
# actually run — the launcher's OWN PATH is not enough (the tool shell sources a
# snapshot that can bury the shim dirs) — and that the nproc ceiling above
# reaches a child and a grandchild. The ceiling is DECLARED to the guard here so
# the guard can OBSERVE whether it actually applied. The block itself is emitted
# from the single source monitor/guard-block.sh.in, whose header carries the
# two-name/two-root search and the refusal contract: a MISSING guard is a
# REFUSAL (78), not a warning, and a guard that ran but could not adjudicate
# exits 79 and is recorded as NOT CHECKED rather than folded into a pass.
export NEXUS_ASSERT_NPROC_EXPECT="$WORKER_NPROC_LIMIT"
$SHIM_GUARD_BLOCK
# Pin worker cwd to the worktree (issue #95). See the loop-wrapped
# branch above for the full rationale.
cd "$WORKDIR" || exit 1
prompt=\$(<$PROMPT_TMP)
rm -f $PROMPT_TMP $LAUNCHER_TMP
# --settings file is repo-tracked; no tempfile cleanup needed.
# CLAUDE_CODE_SANDBOXED=1: tells Claude Code it runs inside a sandbox (it
# does — kernel-enforced), which makes its workspace-trust gate return
# "trusted" before the config key is consulted. Rationale, measurement and
# the canary that guards the undocumented flag: spawn-worker.sh, "PRIMARY
# FIX" paragraph above the post-spawn verification block (#1334).
CLAUDE_CODE_SANDBOXED=1 "$CLAUDE_BIN" --dangerously-skip-permissions${MODEL_ARG:+ $MODEL_ARG}${NAME_ARG:+ $NAME_ARG}${PLUGIN_ARG:+ $PLUGIN_ARG} $HOOKS_FLAG${SESSION_ID_FLAG:+ $SESSION_ID_FLAG} "\$prompt"
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
_seed_workspace_trust
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
# your-org/nexus-code#1051 — NO DEAD-PANE GUARD HERE, AND THE REASON IS THE
# PRIMITIVE, NOT THE ADJACENCY.
#
# `#745` is a **`paste-buffer`** defect. `send-keys` was its measured-SAFE
# CONTROL, and monitor/_pane-live.sh records both: `paste-buffer` into a dead
# pane killed the server 20/20, `send-keys` into the same dead pane survived
# 10/10 — "`send-keys` into the same dead pane is harmless". paste-followup.sh
# says the same thing from the other side, offering `tmux send-keys` as the way
# to "poke a corpse". This file contains no executable `paste-buffer` at all.
#
# So the server-death hazard is NOT reachable from this line, whatever the pane's
# state. An earlier revision of this comment asserted that `#745` was a
# `send-keys` defect and instructed a successor to add `_tmux_pane_is_dead` if
# the send were ever separated from its window creation. That premise was FALSE,
# and the instruction would have made someone pay a real cost — see below — for a
# hazard that does not exist on this path.
#
# The adjacency (`$WID` is assigned by the nearest `tmux new-window` above, in
# this execution, no branch and no reassignment) is real and worth knowing, but it
# is not what makes this safe. If a future edit separates the send from the
# creation, the send is STILL safe; what you would lose is only the guarantee that
# the window exists at all, whose failure mode is a `send-keys` that does nothing.
#
# AND THE GUARD WOULD COST MORE THAN IT BUYS. `_tmux_pane_is_dead` is
# deliberately fail-CLOSED: it returns "dead" — REFUSE — whenever it cannot tell,
# and one of those arms is `tmux list-panes` failing, which its own comment
# attributes to "a fork failure under the worker RLIMIT_NPROC ceiling, or a busy
# socket". This nexus runs workers under exactly that ceiling. On the PASTE path
# that trade is right, because there the primitive really is lethal. Here it would
# convert a transient tmux hiccup into a FAILED SPAWN to prevent nothing.
#
# NO DISTANCE IS QUOTED ON PURPOSE. "N lines up" is a line number wearing a
# disguise: an earlier draft said 7, and adding the comment itself moved it to 29.
_sw_trust_keep_launcher fresh
tmux send-keys -t "$WID" "$LAUNCHER_TMP" Enter

# Seed the watcher's lifecycle anchors BEFORE the launcher has a chance
# to settle the renderer (definition + rationale above, next to the
# resume mode that shares it). The session-id extra (when the
# generated `--session-id` is in play) is what the --resume resolver's
# spawn-event source reads back (your-nexus#206).
# reply-to rides the spawn event only when set, so a normal spawn's
# action-log row is byte-identical to the pre-flag shape.
_anchor_extra_replyto=()
[ -n "$REPLY_TO" ] && _anchor_extra_replyto=("reply-to=$REPLY_TO")
if [ -n "$WORKER_SESSION_ID" ]; then
    _seed_lifecycle_anchors "$NEXUS_ROOT" "$WINDOW_NAME" "$WORKDIR" \
        "session-id=$WORKER_SESSION_ID" "kind=$SPAWN_KIND" \
        "skeptic-mode=$SKEPTIC_MODE" "skeptic-depth=$SKEPTIC_DEPTH" \
        ${_anchor_extra_replyto[@]+"${_anchor_extra_replyto[@]}"}
else
    _seed_lifecycle_anchors "$NEXUS_ROOT" "$WINDOW_NAME" "$WORKDIR" \
        "kind=$SPAWN_KIND" \
        "skeptic-mode=$SKEPTIC_MODE" "skeptic-depth=$SKEPTIC_DEPTH" \
        ${_anchor_extra_replyto[@]+"${_anchor_extra_replyto[@]}"}
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
    "$SKEPTIC_ORIG" "$REPLY_TO"

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
    # OBLIGATION EDGE (your-org/nexus-code#845). The `skeptic-spawn` event
    # above records that a pairing HAPPENED; it is an append-only log line
    # and nothing queries it as current state. The edge below records that
    # the pairing is OUTSTANDING — this window OWES $SKEPTIC_TARGET a
    # verdict — and `retire-preflight` check 1d reads it before any kill.
    #
    # This is the moment the dependency becomes true, and it is the ONLY
    # moment at which it is known without anyone having to remember it. The
    # alternative on the board was for the orchestrator to hold the pairing
    # in its head, which is what it was already doing when it retired
    # `sk911` mid-obligation and left `papercuts` pushing a fix to a
    # reviewer that no longer existed.
    #
    # The ORIGINAL worker gets an edge too when the chain is recursive: a
    # second-or-later skeptic reviews the WHOLE chain (skills/nexus.skeptic
    # Change 2), so the original is equally owed and equally strandable.
    # obl_open refuses a self-edge, so the orig == target case is a no-op
    # rather than a duplicate.
    if [ -x "$NEXUS_ROOT/monitor/obligations.sh" ]; then
        "$NEXUS_ROOT/monitor/obligations.sh" open \
            --debtor "$WINDOW_NAME" --creditor "$SKEPTIC_TARGET" \
            --kind skeptic-verdict --round "$SKEPTIC_DEPTH" \
            --by "spawn-worker.sh --skeptic-role" \
            --detail "skeptic spawned to review $SKEPTIC_TARGET at depth $SKEPTIC_DEPTH" \
            >/dev/null 2>&1 || true
        if [ -n "$SKEPTIC_ORIG" ] && [ "$SKEPTIC_ORIG" != "$SKEPTIC_TARGET" ]; then
            "$NEXUS_ROOT/monitor/obligations.sh" open \
                --debtor "$WINDOW_NAME" --creditor "$SKEPTIC_ORIG" \
                --kind skeptic-verdict --round "$SKEPTIC_DEPTH" \
                --by "spawn-worker.sh --skeptic-role (chain root)" \
                --detail "recursive skeptic at depth $SKEPTIC_DEPTH reviews the whole chain rooted at $SKEPTIC_ORIG" \
                >/dev/null 2>&1 || true
        fi
    fi
    # Auto-ack the pending spawn-skeptic request (your-org/nexus-code#545).
    # `ng wrap-up` files a `kind=spawn-skeptic` request into the request
    # inbox to PUSH the orchestrator to spawn this skeptic; spawning it IS
    # the acknowledgement, so close the loop here rather than relying on the
    # orchestrator to remember `ng request ack`. The JOIN KEY is
    # request.origin == skeptic-spawn.target-window: the request's origin is
    # the reviewed window (ng files it with --origin <target>), which is
    # exactly $SKEPTIC_TARGET here. Ack every non-terminal spawn-skeptic
    # request whose `origin` frontmatter equals the sanitized target (a
    # second-pass files a fresh request at a higher depth; a wrap-up retry
    # may have filed a duplicate — ack them all, `ack` is idempotent). The
    # skeptic/pending/<target> marker still independently guards double
    # SPAWN; this just stops the request re-emitting. Best-effort — a miss
    # degrades to the request re-emitting until the orchestrator acks by
    # hand, never to a broken spawn.
    _sk_req_dir="$STATE_DIR/requests"
    _sk_chan="$NEXUS_ROOT/monitor/request-channel.sh"
    if [ -d "$_sk_req_dir" ] && [ -x "$_sk_chan" ]; then
        _sk_target_safe=$(printf '%s' "$SKEPTIC_TARGET" | tr -c 'a-zA-Z0-9_-' '_')
        for _sk_rf in "$_sk_req_dir"/*.new.md "$_sk_req_dir"/*.claimed.md; do
            [ -e "$_sk_rf" ] || continue
            # Match on the frontmatter fields, not the filename, so this is
            # robust to the request slug convention: kind must be
            # spawn-skeptic AND origin must equal the reviewed window. The
            # `|| _v=""` fallbacks keep a file racing away mid-read (the
            # watcher claims/renames concurrently) from tripping errexit —
            # this whole block is best-effort.
            _sk_kind=$(sed -n 's/^kind:[[:space:]]*//p'   "$_sk_rf" 2>/dev/null | head -1) || _sk_kind=""
            [ "$_sk_kind" = "spawn-skeptic" ] || continue
            _sk_origin=$(sed -n 's/^origin:[[:space:]]*//p' "$_sk_rf" 2>/dev/null | head -1) || _sk_origin=""
            [ "$_sk_origin" = "$_sk_target_safe" ] || continue
            _sk_id=$(basename "$_sk_rf"); _sk_id=${_sk_id%.md}; _sk_id=${_sk_id%.*}
            # A REFUSED ACK MUST BE VISIBLE (your-org/nexus-code#1358). This was
            # `>/dev/null 2>&1 || true`, which reported success, refusal and
            # error IDENTICALLY — the silent-failure class in the one place that
            # decides whether a filed request stays open. Still best-effort: no
            # ack outcome fails the spawn, because the marker is the gate and it
            # is already in place. What changes is that the outcome is SAID.
            #
            # rc 6 is `cmd_ack`'s reply-required refusal. It does not fire for a
            # spawn-skeptic request today — `ng` files those without `--reply`,
            # deliberately, so the ordinary spawn->done path is unchanged — and
            # the arm exists because a refusal that nothing prints is
            # indistinguishable from an ack that happened. If a request kind
            # reaching here ever does demand a reply, this says so and names the
            # verb that satisfies it rather than leaving the request open with
            # no explanation.
            # `_sk_ack_rc=0; … || _sk_ack_rc=$?` AND NOT `out=$(…); rc=$?`.
            # This script is `set -euo pipefail` (line ~170, no `set +e`
            # anywhere) and this block is the body of a top-level `if`,
            # which does NOT suppress errexit. A BARE assignment whose
            # command substitution exits non-zero therefore TERMINATES THE
            # SCRIPT: `_sk_ack_rc=$?` never runs and the `case` below is
            # unreachable for every rc it was written to report. Measured
            # on the bare form with the real binaries: a `reply: required`
            # ack (rc 6) and a concurrent-rename ack (rc 1) both exited the
            # launcher with EMPTY stderr, skipping `skeptic-channel init`
            # below, the `skeptic/pending` marker at ~:2979 and
            # `ng skeptic-arm` — while the tmux window created at ~:2742
            # already exists. So the skeptic runs on with no comms channel
            # and NO marker for `retire-preflight.sh` check 1b to read,
            # which is the live-worker-retirement class. The `|| true` form
            # this replaced could not do that: the change meant to end a
            # silent failure had converted a survivable silence into a
            # SILENT ABORT — silent precisely because the printing is what
            # became unreachable.
            _sk_ack_rc=0; _sk_ack_out=$("$_sk_chan" ack "$_sk_id" 2>&1) || _sk_ack_rc=$?
            case "$_sk_ack_rc" in
                0) : ;;
                6) printf 'spawn-worker: spawn-skeptic request %s demands a REPLY and was not auto-acked.\n' "$_sk_id" >&2
                   printf '  It stays open until it is answered. `reply` both records the decision and\n' >&2
                   printf '  closes the loop:\n' >&2
                   printf '      ng request reply %s --status spawned --worker %s --file <rationale>\n' "$_sk_id" "$WINDOW_NAME" >&2 ;;
                *) printf 'spawn-worker: could not ack spawn-skeptic request %s (rc %s) — the spawn is\n' "$_sk_id" "$_sk_ack_rc" >&2
                   printf '  unaffected; the request will keep re-emitting until it is answered.\n' >&2
                   printf '%s\n' "$_sk_ack_out" | sed 's/^/  /' >&2 ;;
            esac
        done
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
    SKEPTIC_PENDING_DIR="$STATE_DIR/skeptic/pending"
    mkdir -p "$SKEPTIC_PENDING_DIR" 2>/dev/null || true
    _sk_safe() { wk_encode "${1-}"; }
    printf '%s' "$SKEPTIC_DEPTH" \
        > "$SKEPTIC_PENDING_DIR/$(_sk_safe "$SKEPTIC_TARGET")" 2>/dev/null || true
    if [ -n "$SKEPTIC_ORIG" ] && [ "$SKEPTIC_ORIG" != "$SKEPTIC_TARGET" ]; then
        printf '%s' "$SKEPTIC_DEPTH" \
            > "$SKEPTIC_PENDING_DIR/$(_sk_safe "$SKEPTIC_ORIG")" 2>/dev/null || true
    fi
    # ── AND RECORD WHAT THE ARM IS ABOUT (your-org/nexus-code#1207) ─────────
    #
    # The block above establishes the ARMED STATE. Until this, it recorded no
    # SUBJECT — the marker holds a depth integer and nothing else — so nothing
    # downstream could say which artefact this reviewer was pinned to, and
    # `_skeptic_record_discharge` could attribute no verdict against it.
    #
    # Read the comment above this one for why that is not an edge case: for a
    # first-pass skeptic the marker write is an idempotent re-stamp, but for a
    # SECOND-or-later pass this is *the only thing that restores the block*. So
    # every re-validation round — the rounds that exist because something was
    # already found wrong — armed without a subject. Measured: `annz36` logged
    # `subject-armed-sha:"-"` at verdict time, and `ncpanestate` carries ONE
    # `armed` row against four rounds, so all six of its delivered verdicts read
    # `asserted-not-armed`.
    #
    # `PRIOR_REPORT_RESOLVED` is the right subject and is why this is a repair
    # rather than a workaround: it is the report this skeptic is being POINTED
    # AT (resolved against NEXUS_ROOT at line ~1919), so arming against it names,
    # per round, exactly what the reviewer was told to read.
    #
    # `ng skeptic-arm` owns the row format and the idempotence rule — it appends
    # nothing when this artefact is already outstanding, because a second arm for
    # one artefact IS `ambiguous-N-arms-outstanding`, and a fix for one pole of
    # `#1156` that manufactures another is not a fix.
    #
    # BEST-EFFORT, LOUD: a state dir that cannot be written must not fail a
    # spawn — the marker is the gate and it is already in place. But it says so
    # on stderr rather than swallowing it, because "armed with no subject" is
    # exactly the silent state this issue is about. rc 3 (already outstanding) is
    # the normal first-pass outcome and is not reported as a problem.
    # No `--issue`: this script has no issue number in scope (there is no such
    # variable), so the row records `-` rather than a value invented here. That
    # costs nothing the supersession relation needs — it is keyed on the issue of
    # the DISCHARGE rows, not of the arm.
    #
    # ── THE SHAPE MIRRORS THE MARKER BLOCK ABOVE, DELIBERATELY ────────────
    #
    # An earlier version looped over `"$SKEPTIC_TARGET" "$SKEPTIC_ORIG"` with a
    # dedup guard meant to skip the SECOND iteration when ORIG == TARGET. It
    # skipped BOTH: on iteration 1 the window IS the target, so when
    # ORIG == TARGET the guard's first test is also true and `continue` fired for
    # the target as well. Nothing was armed.
    #
    # ORIG == TARGET is the DEFAULT, not an edge case — the block at the top of
    # this file sets `SKEPTIC_ORIG="$SKEPTIC_TARGET"` whenever `--skeptic-orig` is
    # omitted, and the first-pass spawn command deliberately omits it. Measured
    # over `action-log.jsonl`: 818 spawns with ORIG == TARGET against 9 without
    # (excluding a test fixture), and 83 against 1 since the ledger feature
    # landed. So the fix was inoperative for essentially every spawn it existed
    # for — including `annz36`, the witness this whole change was derived from.
    #
    # And it failed SILENTLY: `-r` WAS supplied, so the no-report warning below
    # could not fire and stderr stayed empty. A fix for silent record loss that
    # itself loses records silently is the defect class re-instantiated inside its
    # own remedy.
    #
    # The marker block three lines up had the correct shape all along —
    # unconditional for TARGET, guarded for ORIG. Mirroring it removes the chance
    # to get the dedup wrong, because there is no dedup: there are two call sites
    # with the same guard the markers use.
    _sk_record_arm() {
        [ -n "${1-}" ] || return 0
        # `|| _sk_arm_rc=$?`, NEVER a bare `_sk_arm_rc=$?` on the next line.
        # `set -euo pipefail` is on (top of this file), so a command
        # SUBSTITUTION that exits non-zero terminates the shell AT THE
        # ASSIGNMENT — the next line never runs and the `case` below is
        # UNREACHABLE for every rc it was written to handle.
        #
        # That is not a corner case, it is THE COMMON PATH: `ng skeptic-arm`
        # exits 3 for ALREADY CURRENT, which its own docs call "Not a failure",
        # and which is exactly what the target window has already produced by
        # arming its own report at `require` wrap-up before the orchestrator
        # spawns the reviewer with the `-r` that #1251 made mandatory.
        # Measured at 0b82ffb2: the tmux window IS created and the launcher IS
        # sent — the worker is LIVE — and spawn-worker then exits 3 having never
        # printed its `spawned:` line. A success reported as a failure, after
        # the irreversible half already happened.
        _sk_arm_rc=0
        _sk_arm_out=$("$NEXUS_ROOT/monitor/ng" skeptic-arm "$1" \
            --report "$PRIOR_REPORT_RESOLVED" --state-dir "$STATE_DIR" 2>&1) \
            || _sk_arm_rc=$?
        case "$_sk_arm_rc" in
            0|3) : ;;
            *) printf 'spawn-worker: WARNING — could not record the skeptic ARM for %s (ng skeptic-arm rc=%s).\n' \
                   "$1" "$_sk_arm_rc" >&2
               printf '%s\n' "$_sk_arm_out" | sed 's/^/  /' >&2
               printf '  The marker IS in place, so the gate is shut; the ledger just cannot\n' >&2
               printf '  attribute a verdict to an artefact. See your-org/nexus-code#1207.\n' >&2 ;;
        esac
    }
    if [ -n "$PRIOR_REPORT_RESOLVED" ] && [ -x "$NEXUS_ROOT/monitor/ng" ]; then
        _sk_record_arm "$SKEPTIC_TARGET"
        if [ -n "$SKEPTIC_ORIG" ] && [ "$SKEPTIC_ORIG" != "$SKEPTIC_TARGET" ]; then
            _sk_record_arm "$SKEPTIC_ORIG"
        fi
    elif [ -z "$PRIOR_REPORT_RESOLVED" ]; then
        # ── ASK THE LEDGER BEFORE CLAIMING WHAT IT HOLDS (your-org/nexus-code#1302)
        #
        # The predicate available in this arm is "did THIS invocation receive
        # -r?". The claim the warning used to make is "the arm records NO
        # SUBJECT" — a property of the LEDGER, which this arm never consulted.
        # On the protocol's NORMAL path the two disagree: a worker that wrapped
        # up with `--skeptic-decision require` has ALREADY armed its own key
        # with its own report's sha (`_skeptic_record_arm`, from the wrap-up
        # skeptic step in `monitor/ng`) before the orchestrator ever spawns. So
        # the unconditional warning fired on the COMMON case — and because its
        # text was identical either way, an orchestrator had no way to
        # recognise the genuine case it exists for. Habituation then hides it.
        #
        # `ng skeptic-obligations` is the ledger's own THREE-VALUED answer, and
        # the third value is the point: a diagnostic that cannot tell "no
        # subject" from "could not look" will eventually assert the first while
        # meaning the second.
        #   rc 1  outstanding > 0  -> a subject IS on record; say so, alarm nothing
        #   rc 0  outstanding = 0  -> no subject: the original warning, now TRUE
        #   rc 3  REFUSED          -> ledger present but unreadable/unparseable
        # Any other rc (2 usage, 127 no `ng`, ...) is also "could not look" and
        # falls to the same arm — default-DENY on the CLAIM, never on the spawn.
        #
        # `|| _sk_ob_rc=$?` is not style, it is the same `set -e` trap fixed
        # above: a bare `out=$(cmd)` at non-zero rc terminates the script before
        # the next line can read `$?`.
        _sk_ob_out=""
        _sk_ob_rc=0
        if [ -x "$NEXUS_ROOT/monitor/ng" ]; then
            _sk_ob_out=$("$NEXUS_ROOT/monitor/ng" skeptic-obligations "$SKEPTIC_TARGET" \
                --state-dir "$STATE_DIR" 2>/dev/null) || _sk_ob_rc=$?
        else
            _sk_ob_rc=127
        fi
        case "$_sk_ob_rc" in
            1)  printf 'spawn-worker: no prior report (-r) given for this --skeptic-role spawn, but the\n' >&2
                printf '  ledger ALREADY HOLDS an outstanding arm for %s, so a verdict CAN be\n' "$SKEPTIC_TARGET" >&2
                printf '  attributed. Nothing to repair here. Confirm the arm names the artefact this\n' >&2
                printf '  reviewer will actually read; if it does not, respawn with -r.\n' >&2
                printf '%s\n' "$_sk_ob_out" | sed 's/^/    /' >&2 ;;
            0)  printf 'spawn-worker: NOTE — no prior report (-r) given for this --skeptic-role spawn and\n' >&2
                printf '  the ledger holds NO outstanding arm, so the ARM for %s records NO SUBJECT\n' "$SKEPTIC_TARGET" >&2
                printf '  and a verdict against it cannot be attributed (it will still be RECORDED:\n' >&2
                printf '  evidence class `verdict-without-arm`).\n' >&2
                printf '  Pass -r <report-the-skeptic-should-read>. See your-org/nexus-code#1207.\n' >&2 ;;
            *)  printf 'spawn-worker: NOTE — no prior report (-r) given for this --skeptic-role spawn, and\n' >&2
                printf '  the ledger for %s COULD NOT BE READ (ng skeptic-obligations rc=%s). Whether a\n' "$SKEPTIC_TARGET" "$_sk_ob_rc" >&2
                printf '  subject is on record is UNKNOWN — this is NOT a claim that none is.\n' >&2
                printf '  Pass -r <report-the-skeptic-should-read>. See your-org/nexus-code#1302.\n' >&2 ;;
        esac
    fi
fi

# Post-spawn trust verification (your-org/nexus-code#1334): after the anchors,
# provenance and skeptic bookkeeping above (all keyed by NAME, so a recovery
# that re-creates the window under the same name leaves them valid), and
# before the `spawned:` line, so a bounded failure never prints a success.
_sw_trust_verify "$WID"

echo "spawned: window=$WINDOW_NAME workdir=$WORKDIR prompt=$PROMPT_FILE kind=$SPAWN_KIND floor=injected${PRIOR_REPORT_RESOLVED:+ prior-report=$PRIOR_REPORT_RESOLVED} settings=$SETTINGS_FILE${WORKER_SESSION_ID:+ session-id=$WORKER_SESSION_ID}$([ "$USE_LOOP_WRAPPER" -eq 1 ] && echo ' loop=on')" >&2
