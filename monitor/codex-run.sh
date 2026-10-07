#!/usr/bin/env bash
# monitor/codex-run.sh — run OpenAI Codex as a SUPERVISED CO-WORKER for one
# bounded subtask (your-org/nexus-code#1640, layer 1; alias `ng codex run`).
#
# A Claude Code worker hands Codex a prompt and a git working tree; this
# script runs `codex exec` non-interactively, captures everything needed to
# REVIEW the result, and returns a typed verdict. The calling worker stays
# the owner of the report, the wrap-up and the skeptic contract: Codex's
# output is a proposal to be read, never a result to be forwarded.
#
# usage: codex-run.sh --cd <git-root> (--prompt-file F | --prompt-stdin) [opts]
#
#   --cd DIR            working tree codex operates on. Must be a git
#                       repository ROOT (monitor/repo-root.sh verdict=yes):
#                       the diff capture needs it, and `git -C` on a
#                       non-root walks up into the nexus (CLAUDE.md,
#                       REPO-WALKUP). `--no-git` lifts this and disables the
#                       diff capture instead.
#   --prompt-file F     the task. Delivered to codex on STDIN, never in argv:
#                       argv is world-readable via /proc and sibling agents'
#                       probes ingest it (your-org/nexus-code#1612).
#   --prompt-stdin      read the task from this script's stdin instead.
#   --out DIR           artefact directory (default: a fresh
#                       ${TMPDIR}/codex-run/<utc>-<pid>). Refused if it
#                       exists and is non-empty.
#   --model M           default: config monitor.codex.model (monitor/_codex.sh)
#   --sandbox MODE      codex's OWN sandbox. Default danger-full-access —
#                       see "THE SANDBOX" below before changing it.
#   --timeout S         wall-clock bound, default 1800. Expiry is verdict
#                       `timeout` (exit 4), never a codex verdict.
#   --allow-dirty       run on a tree with uncommitted changes. The diff is
#                       still exactly codex's delta (snapshot-before vs
#                       snapshot-after), so this is safe for attribution;
#                       it is opt-in because codex may EDIT those files.
#   --no-git            --cd need not be a repo; no diff is captured.
#   --resume ID         continue a previous codex thread (`exec resume`).
#   --ephemeral         do not persist the codex session to disk (no resume).
#   --config K=V        passthrough `-c K=V` to codex (repeatable). Used by
#                       the hermetic suites to point codex at the mock
#                       backend; also for per-run codex settings.
#   --also-watch DIR    also list files written under DIR during the run
#                       (repeatable; e.g. the nexus state dir, a sibling
#                       clone). What is not watched is visible only through
#                       commands.txt.
#   --output-schema F   passthrough: JSON Schema for the final message.
#   --background        do not run here: relaunch THIS command under
#                       `ng longjob run` (rc retained, wake armed) and print
#                       the artefact dir + token. For anything that may
#                       outlive the 30-minute Monitor cap.
#   --dry-run           print the resolved codex argv (prompt elided), exit 0.
#
# ARTEFACTS (in --out):
#   prompt.txt          the exact bytes codex received
#   events.jsonl        `codex exec --json` event stream
#   last-message.txt    codex's final message (-o)
#   stderr.log          codex stderr
#   diff.patch          codex's change to the NON-IGNORED part of --cd: a
#                       snapshot of the working tree (tracked + untracked,
#                       .gitignore honoured) before vs after, via a private
#                       index — the caller's index and HEAD are never
#                       touched. It is NOT every write codex made: see the
#                       next three artefacts for what it cannot contain.
#   diffstat.txt        `git diff --stat` of the same
#   writes.txt          every FILE modified or created during the run under
#                       --cd and each --also-watch DIR (`find -newer` a marker
#                       taken just before codex started): gitignored files
#                       included. Deletions of files outside the diff's reach
#                       are NOT visible to it.
#   writes-outside-diff.txt  the subset of writes.txt that diff.patch does NOT
#                       show: gitignored files under --cd, and anything under
#                       an --also-watch DIR. Count in status as
#                       writes_outside_diff, and named in the verdict line.
#   commands.txt        every command codex ran (from events.jsonl) with its
#                       exit code. Under danger-full-access codex can write
#                       anywhere the kernel sandbox allows; a write outside
#                       --cd and every --also-watch DIR is visible ONLY here.
#   status              key=value: verdict, rc_codex, thread_id, model,
#                       codex_version, expected_version, commands,
#                       commands_failed, tree_before, tree_after, …
#
# EXIT CODES (the verdict, one line on stdout begins `codex-run: verdict=`):
#   0  completed       codex emitted turn.completed
#   2  usage           bad arguments; nothing ran
#   3  turn-failed     codex emitted turn.failed / error (quota, auth,
#                      model refusal). The message is in the verdict line.
#   4  timeout         --timeout expired (wrapper status 124/137/143 — the
#                      SET, CLAUDE.md TIMEOUT-STATUS-INJECTION)
#   5  unavailable     no codex binary, or no credential of any kind
#   6  workdir         --cd is not a repo root / is dirty without
#                      --allow-dirty / snapshot failed
#   7  indeterminate   codex exited WITHOUT a terminal event: neither
#                      completed nor failed is established. Read the
#                      artefacts; do not treat as either.
#   8  background-launch-failed   --background could not arm a longjob
#   64 the argument loop made no progress (your-org/nexus-code#924)
#
# THE SANDBOX (measured inside this nexus's kernel sandbox, codex 0.156.1):
#   read-only and workspace-write run commands through bubblewrap, and EVERY
#   command fails: `bwrap: Failed to make / slave: Operation not permitted`.
#   The deprecated landlock path (--enable use_legacy_landlock) did not
#   execute the test command either. Only danger-full-access executes. That
#   removes codex's INNER layer only: the kernel sandbox this nexus runs in
#   still binds every write codex makes, exactly as it does for Claude Code
#   under --dangerously-skip-permissions. We never pass anything that
#   touches the outer sandbox. A read-only/workspace-write run is allowed
#   (a pure-reasoning task needs no shell) but warns that commands will fail.
#
# STDIN: codex exec APPENDS stdin to the prompt when stdin is not a tty
# ("Reading additional input from stdin..." — measured). The prompt is
# therefore fed as stdin from a FILE, so an inherited agent stdin can
# neither block the run nor splice itself into the task.

set -uo pipefail

_sd=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${NEXUS_ROOT:=$(cd "$_sd/.." && pwd)}"
export NEXUS_ROOT
# shellcheck source=monitor/_codex.sh
. "$_sd/_codex.sh"

die_usage() { printf 'codex-run: %s\n' "$1" >&2; exit 2; }
# Argument-loop progress guard (your-org/nexus-code#924): a loop that did not
# consume an argument would spin forever; refuse instead. Exits 64.
_argloop_stuck() {
    printf '%s: option %s requires a value (argument loop made no progress)\n' "${0##*/}" "${1-}" >&2
    exit 64
}

usage() { sed -n '2,/^set -uo pipefail/{/^set -uo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

CD="" PROMPT_FILE="" PROMPT_STDIN=0 OUT="" MODEL="" SANDBOX="danger-full-access"
TIMEOUT_S=1800 ALLOW_DIRTY=0 NO_GIT=0 RESUME="" EPHEMERAL=0 SCHEMA="" BACKGROUND=0 DRY=0
CONFIGS=()
WATCH_DIRS=()
# `ng codex run …` and `ng codex …` are the same call: the facade stays a
# pure pass-through, so the optional verb word is consumed here.
[[ "${1:-}" == run ]] && shift
ORIG_ARGS=("$@")

_argloop_prev_1=-1; while (( $# )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
    case "$1" in
        --cd)            [[ $# -ge 2 ]] || die_usage "--cd needs a value"; CD="$2"; shift 2 ;;
        --cd=*)          CD="${1#*=}"; shift ;;
        --prompt-file)   [[ $# -ge 2 ]] || die_usage "--prompt-file needs a value"; PROMPT_FILE="$2"; shift 2 ;;
        --prompt-file=*) PROMPT_FILE="${1#*=}"; shift ;;
        --prompt-stdin)  PROMPT_STDIN=1; shift ;;
        --out)           [[ $# -ge 2 ]] || die_usage "--out needs a value"; OUT="$2"; shift 2 ;;
        --out=*)         OUT="${1#*=}"; shift ;;
        --model)         [[ $# -ge 2 ]] || die_usage "--model needs a value"; MODEL="$2"; shift 2 ;;
        --model=*)       MODEL="${1#*=}"; shift ;;
        --sandbox)       [[ $# -ge 2 ]] || die_usage "--sandbox needs a value"; SANDBOX="$2"; shift 2 ;;
        --sandbox=*)     SANDBOX="${1#*=}"; shift ;;
        --timeout)       [[ $# -ge 2 ]] || die_usage "--timeout needs a value"; TIMEOUT_S="$2"; shift 2 ;;
        --timeout=*)     TIMEOUT_S="${1#*=}"; shift ;;
        --allow-dirty)   ALLOW_DIRTY=1; shift ;;
        --no-git)        NO_GIT=1; shift ;;
        --resume)        [[ $# -ge 2 ]] || die_usage "--resume needs a thread id"; RESUME="$2"; shift 2 ;;
        --resume=*)      RESUME="${1#*=}"; shift ;;
        --ephemeral)     EPHEMERAL=1; shift ;;
        --config)        [[ $# -ge 2 ]] || die_usage "--config needs K=V"; CONFIGS+=("$2"); shift 2 ;;
        --config=*)      CONFIGS+=("${1#*=}"); shift ;;
        --also-watch)    [[ $# -ge 2 ]] || die_usage "--also-watch needs a directory"; WATCH_DIRS+=("$2"); shift 2 ;;
        --also-watch=*)  WATCH_DIRS+=("${1#*=}"); shift ;;
        --output-schema) [[ $# -ge 2 ]] || die_usage "--output-schema needs a file"; SCHEMA="$2"; shift 2 ;;
        --output-schema=*) SCHEMA="${1#*=}"; shift ;;
        --background)    BACKGROUND=1; shift ;;
        --dry-run)       DRY=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               die_usage "unknown argument: $1 (see --help)" ;;
    esac
done

[[ -n "$CD" ]] || die_usage "--cd <git-root> is required"
[[ -d "$CD" ]] || die_usage "--cd $CD is not a directory"
CD=$(cd "$CD" && pwd -P)
if (( PROMPT_STDIN )) && [[ -n "$PROMPT_FILE" ]]; then die_usage "--prompt-file and --prompt-stdin are exclusive"; fi
(( PROMPT_STDIN )) || [[ -n "$PROMPT_FILE" ]] || die_usage "a task is required: --prompt-file F or --prompt-stdin"
if [[ -n "$PROMPT_FILE" && ! -r "$PROMPT_FILE" ]]; then die_usage "cannot read --prompt-file $PROMPT_FILE"; fi
[[ "$TIMEOUT_S" =~ ^[1-9][0-9]*$ ]] || die_usage "--timeout must be a positive integer (seconds), got: $TIMEOUT_S"
case "$SANDBOX" in read-only|workspace-write|danger-full-access) ;; *) die_usage "--sandbox must be read-only|workspace-write|danger-full-access" ;; esac
[[ -z "$SCHEMA" || -r "$SCHEMA" ]] || die_usage "cannot read --output-schema $SCHEMA"
for _w in "${WATCH_DIRS[@]}"; do [[ -d "$_w" ]] || die_usage "--also-watch $_w is not a directory"; done
if (( BACKGROUND && PROMPT_STDIN )); then die_usage "--background needs --prompt-file (stdin does not survive a relaunch)"; fi

# ---- artefact dir ---------------------------------------------------------
if [[ -z "$OUT" ]]; then
    [[ -n "${TMPDIR:-}" ]] || die_usage "TMPDIR is unset and no --out given — refusing to guess a scratch root (your-org/nexus-code#1628)"
    OUT="${TMPDIR:?}/codex-run/$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
if [[ -e "$OUT" ]] && [[ -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then
    die_usage "--out $OUT exists and is not empty — refusing to mix two runs' artefacts"
fi
mkdir -p "$OUT" || die_usage "cannot create --out $OUT"
OUT=$(cd "$OUT" && pwd -P)

# ---- background: relaunch under ng longjob --------------------------------
if (( BACKGROUND )); then
    fwd=()
    skip_next=0
    for a in "${ORIG_ARGS[@]}"; do
        if (( skip_next )); then skip_next=0; continue; fi
        case "$a" in
            --background) continue ;;
            --out) skip_next=1; continue ;;
            --out=*) continue ;;
        esac
        fwd+=("$a")
    done
    ng="$NEXUS_ROOT/monitor/ng"
    [[ -x "$ng" ]] || { printf 'codex-run: verdict=background-launch-failed — %s is not executable\n' "$ng"; exit 8; }
    # The out dir was created above and is EMPTY; the child re-creates
    # nothing and writes into it, so the caller knows where to look now.
    rmdir "$OUT" 2>/dev/null || true
    printf 'codex-run: background — artefacts will land in %s\n' "$OUT"
    "$ng" longjob run --desc "codex-run → $OUT" -- "$_sd/codex-run.sh" "${fwd[@]}" --out "$OUT"
    rc=$?
    (( rc == 0 )) || { printf 'codex-run: verdict=background-launch-failed (ng longjob run rc=%s)\n' "$rc"; exit 8; }
    exit 0
fi

status_kv() { printf '%s=%s\n' "$1" "$2" >> "$OUT/status"; }
: > "$OUT/status"
status_kv started "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
status_kv cd "$CD"

finish() {  # finish <rc> <verdict> <detail>
    status_kv verdict "$2"
    status_kv exit "$1"
    status_kv ended "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'codex-run: verdict=%s exit=%s out=%s%s\n' "$2" "$1" "$OUT" "${3:+ — $3}"
    exit "$1"
}

# ---- prompt ---------------------------------------------------------------
if (( PROMPT_STDIN )); then
    cat > "$OUT/prompt.txt"
else
    cp -- "$PROMPT_FILE" "$OUT/prompt.txt"
fi
[[ -s "$OUT/prompt.txt" ]] || finish 2 usage "the task prompt is empty"

# ---- binary, version, auth ------------------------------------------------
BIN=$(codex_bin) || finish 5 unavailable "no codex binary (run: npm install in $NEXUS_ROOT, or set CODEX_BIN)"
status_kv codex_bin "$BIN"
installed=$(codex_version_installed "$BIN") || installed="<unreadable>"
if expected=$(codex_version_expected); then erc=0; else erc=$?; fi
case "$erc" in 0) ;; 3) expected="<unreadable-pin>" ;; *) expected="<none>" ;; esac
status_kv codex_version "$installed"
status_kv expected_version "$expected"
if [[ "$installed" != "$expected" ]]; then
    printf 'codex-run: WARNING codex version %s != expected %s (package.json floor / codex-version-local pin)\n' "$installed" "$expected" >&2
fi
auth=$(codex_auth_state)
status_kv auth "$auth"
[[ "$auth" != none ]] || finish 5 unavailable "no OpenAI credential: neither CODEX_API_KEY/OPENAI_API_KEY in the environment nor ${CODEX_HOME:-~/.codex}/auth.json"

[[ -n "$MODEL" ]] || MODEL=$(codex_model_default)
status_kv model "$MODEL"
status_kv sandbox "$SANDBOX"
if [[ "$SANDBOX" != danger-full-access ]]; then
    printf 'codex-run: WARNING --sandbox %s: inside the nexus kernel sandbox codex'"'"'s bubblewrap cannot start, so EVERY shell command codex attempts will fail. Fine for a pure-reasoning task.\n' "$SANDBOX" >&2
fi

# ---- workdir + snapshot ---------------------------------------------------
_snapshot() {  # prints a tree sha of the working tree; never touches the real index
    local idx; idx=$(mktemp "${TMPDIR:-/tmp}/codex-run-idx.XXXXXX") || return 1
    rm -f "$idx"
    if ! GIT_INDEX_FILE="$idx" git -C "$CD" read-tree HEAD 2>/dev/null; then
        # Unborn HEAD: start from an empty index.
        :
    fi
    if ! GIT_INDEX_FILE="$idx" git -C "$CD" add -A . 2>"$OUT/snapshot.err"; then
        rm -f "$idx"; return 1
    fi
    local t; t=$(GIT_INDEX_FILE="$idx" git -C "$CD" write-tree 2>>"$OUT/snapshot.err") || { rm -f "$idx"; return 1; }
    rm -f "$idx"
    [[ "$t" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf '%s\n' "$t"
}

TREE_BEFORE=""
if (( ! NO_GIT )); then
    top=$(git -C "$CD" rev-parse --show-toplevel 2>/dev/null) || top=""
    [[ -n "$top" ]] && top=$(cd "$top" && pwd -P)
    [[ "$top" == "$CD" ]] || finish 6 workdir "--cd $CD is not a git repository ROOT (toplevel: ${top:-none}); pass the repo root, or --no-git"
    if (( ! ALLOW_DIRTY )) && [[ -n "$(git -C "$CD" status --porcelain 2>/dev/null)" ]]; then
        finish 6 workdir "--cd $CD has uncommitted changes; commit/stash them, or pass --allow-dirty (the diff stays exact either way)"
    fi
    TREE_BEFORE=$(_snapshot) || finish 6 workdir "could not snapshot $CD before the run (see $OUT/snapshot.err)"
    status_kv tree_before "$TREE_BEFORE"
    status_kv head_before "$(git -C "$CD" rev-parse HEAD 2>/dev/null || echo unborn)"
fi

# ---- argv -----------------------------------------------------------------
argv=("$BIN" exec)
[[ -n "$RESUME" ]] && argv+=(resume)
argv+=(--json -o "$OUT/last-message.txt" -m "$MODEL" -c check_for_update_on_startup=false)
# `exec resume` does not take -s/-C; the resumed thread keeps its own.
if [[ -z "$RESUME" ]]; then
    argv+=(-s "$SANDBOX" -C "$CD")
    (( NO_GIT )) && argv+=(--skip-git-repo-check)
fi
(( EPHEMERAL )) && argv+=(--ephemeral)
[[ -n "$SCHEMA" ]] && argv+=(--output-schema "$SCHEMA")
for c in "${CONFIGS[@]}"; do argv+=(-c "$c"); done
[[ -n "$RESUME" ]] && argv+=("$RESUME")
argv+=(-)   # the prompt arrives on stdin

printf '%q ' "${argv[@]}" > "$OUT/argv.txt"; printf '\n' >> "$OUT/argv.txt"
if (( DRY )); then
    cat "$OUT/argv.txt"
    rm -f "$OUT/status"
    exit 0
fi

# ---- run --------------------------------------------------------------------
# EXPORT, never `env CODEX_API_KEY=… codex`: env's argv would carry the
# key's value, readable by any process of this uid through /proc.
if [[ "$(codex_auth_env)" == "CODEX_API_KEY<-OPENAI_API_KEY" ]]; then
    export CODEX_API_KEY="$OPENAI_API_KEY"
fi

# The write marker, back-dated one second: `find -newer` is strict and mtime
# granularity can be one second, so a file written in the marker's own second
# would otherwise be missed. The cost is the opposite error — a write by
# someone else in the second before codex started can be listed — which is
# the safe direction for a list a reviewer reads.
MARK="$OUT/.run-marker"
touch -d "@$(( $(date +%s) - 1 ))" "$MARK" 2>/dev/null || : > "$MARK"
status_kv run_started "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
( cd "$CD" && timeout -k 15 "$TIMEOUT_S" "${argv[@]}" \
      < "$OUT/prompt.txt" > "$OUT/events.jsonl" 2> "$OUT/stderr.log" )
rc_codex=$?
status_kv rc_codex "$rc_codex"

# ---- diff -----------------------------------------------------------------
if [[ -n "$TREE_BEFORE" ]]; then
    if TREE_AFTER=$(_snapshot); then
        status_kv tree_after "$TREE_AFTER"
        git -C "$CD" diff --binary "$TREE_BEFORE" "$TREE_AFTER" > "$OUT/diff.patch" 2>/dev/null
        git -C "$CD" diff --stat "$TREE_BEFORE" "$TREE_AFTER" > "$OUT/diffstat.txt" 2>/dev/null
        status_kv files_changed "$(git -C "$CD" diff --name-only "$TREE_BEFORE" "$TREE_AFTER" 2>/dev/null | wc -l | tr -d ' ')"
        status_kv head_after "$(git -C "$CD" rev-parse HEAD 2>/dev/null || echo unborn)"
    else
        status_kv tree_after "<snapshot-failed>"
    fi
fi

# ---- every write under the watched roots, and the part the diff misses -------
: > "$OUT/writes.txt"
for _root in "$CD" "${WATCH_DIRS[@]}"; do
    _root=$(cd "$_root" && pwd -P) || continue
    find "$_root" -xdev -path "$OUT" -prune -o -name .git -prune -o -type f -newer "$MARK" -print 2>/dev/null
done | sort -u > "$OUT/writes.txt"
: > "$OUT/diff-paths.txt"
if [[ -n "$TREE_BEFORE" && -n "${TREE_AFTER:-}" ]]; then
    git -C "$CD" diff --name-only "$TREE_BEFORE" "$TREE_AFTER" 2>/dev/null | sed "s#^#$CD/#" | sort -u > "$OUT/diff-paths.txt"
fi
comm -23 "$OUT/writes.txt" "$OUT/diff-paths.txt" > "$OUT/writes-outside-diff.txt"
status_kv writes_total "$(grep -c . "$OUT/writes.txt" || true)"
WRITES_OUTSIDE=$(grep -c . "$OUT/writes-outside-diff.txt" || true)
status_kv writes_outside_diff "$WRITES_OUTSIDE"
python3 - "$OUT/events.jsonl" > "$OUT/commands.txt" <<'PY'
import json, sys
try:
    lines = open(sys.argv[1]).read().splitlines()
except Exception:
    lines = []
for ln in lines:
    try:
        e = json.loads(ln)
    except Exception:
        continue
    it = e.get("item") or {}
    if e.get("type") == "item.completed" and it.get("type") == "command_execution":
        print("exit=%s\t%s" % (it.get("exit_code"), it.get("command", "")))
PY

# ---- verdict from the EVENT STREAM, not from rc_codex -----------------------
# A clean rc with no terminal event, or a non-zero rc with turn.completed,
# are both possible; the event is the claim codex makes about its turn, the
# rc is a claim about its process. We key on the event and REPORT both.
summary=$(python3 - "$OUT/events.jsonl" <<'PY'
import json, sys
thread = ""; terminal = ""; err = ""; cmds = 0; cmds_failed = 0; files = 0
try:
    fh = open(sys.argv[1])
except Exception:
    fh = []
for line in fh:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    t = e.get("type", "")
    if t == "thread.started":
        thread = e.get("thread_id", "") or thread
    elif t == "turn.completed":
        terminal = "completed"
    elif t == "turn.failed":
        terminal = "failed"
        err = ((e.get("error") or {}).get("message") or err)
    elif t == "error":
        err = e.get("message") or err
    elif t == "item.completed":
        it = e.get("item") or {}
        if it.get("type") == "command_execution":
            cmds += 1
            if it.get("status") == "failed" or (it.get("exit_code") not in (0, None)):
                cmds_failed += 1
        elif it.get("type") == "file_change":
            files += 1
print("\t".join([thread, terminal, err.replace("\t", " ").replace("\n", " ")[:300],
                 str(cmds), str(cmds_failed), str(files)]))
PY
)
prc=$?
(( prc == 0 )) || finish 7 indeterminate "could not parse $OUT/events.jsonl (python rc $prc)"
# Split with awk, NOT `read`: IFS=tab collapses empty fields, and an empty
# thread id is exactly the case that must not shift every later column.
thread=$(printf '%s' "$summary" | awk -F'\t' '{print $1}')
terminal=$(printf '%s' "$summary" | awk -F'\t' '{print $2}')
err=$(printf '%s' "$summary" | awk -F'\t' '{print $3}')
cmds=$(printf '%s' "$summary" | awk -F'\t' '{print $4}')
cmds_failed=$(printf '%s' "$summary" | awk -F'\t' '{print $5}')
status_kv thread_id "${thread:-<none>}"
status_kv commands "$cmds"
status_kv commands_failed "$cmds_failed"

case "$rc_codex" in
    124|137|143)
        finish 4 timeout "codex did not finish within ${TIMEOUT_S}s (wrapper rc $rc_codex); thread=${thread:-<none>}" ;;
esac
if [[ "$terminal" == completed ]]; then
    note="thread=${thread:-<none>} commands=$cmds failed_commands=$cmds_failed"
    [[ -f "$OUT/diffstat.txt" ]] && note="$note files_changed=$(awk -F= '$1=="files_changed"{v=$2} END{print v+0}' "$OUT/status")"
    (( WRITES_OUTSIDE > 0 )) && note="$note writes_outside_diff=$WRITES_OUTSIDE (see writes-outside-diff.txt: gitignored or --also-watch writes the diff does NOT show)"
    (( rc_codex == 0 )) || note="$note (NOTE: codex process rc $rc_codex despite turn.completed)"
    finish 0 completed "$note"
fi
if [[ "$terminal" == failed ]]; then
    finish 3 turn-failed "${err:-turn.failed with no message}; thread=${thread:-<none>}"
fi
finish 7 indeterminate "codex exited rc $rc_codex with no turn.completed/turn.failed event${err:+ (last error: $err)}; see $OUT/stderr.log"
