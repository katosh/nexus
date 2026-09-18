#!/usr/bin/env bash
# monitor/hooks/bash-footgun-guard.sh
#
# Claude Code PreToolUse hook for the `Bash|Monitor` matcher — every tool
# that carries a shell command, not just `Bash` (your-org/nexus-code#927).
# Delivers a JUST-IN-TIME reminder the moment a worker reaches for a known shell
# footgun, so the worker floor doesn't have to front-load every
# footgun into every spawn prompt (where it dilutes the task and is
# forgotten before it's needed). This is the mechanism that lets the
# always-injected floor shrink: the rules that only matter at a
# specific command move OUT of the prompt and INTO this hook, fired at
# the exact tool call that would trip them.
#
# Same proven shape as monitor/hooks/gh-write-guard.sh (PreToolUse,
# Bash matcher, inspects .tool_input.command) and the data-driven
# design of monitor/hooks/async-launch-detect.sh (patterns live in a
# conf file; adding a footgun is a data edit, not a code change).
#
# DELIVERY: on a `warn` match the hook prints
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#    "additionalContext":"<message>"}}
# on stdout and exits 0 — the tool still runs, and the model reads the
# reminder in-context and self-corrects on its next call. On a `block`
# match the hook prints the message to stderr and exits 2, which
# BLOCKS the tool and shows the message to the model (per the Claude
# Code hooks reference: PreToolUse exit 2 = blocking error, stderr
# shown to Claude). `block` is reserved for severe, session-wide
# consequences; the footgun conf ships `warn`-only.
#
# EVERY MATCHING RULE IS DELIVERED, NOT JUST THE FIRST
# (your-org/nexus-code#1057). This used to be first-match-wins: `deliver`
# ended in `exit 0`, so a command tripping two footguns was told about one and
# ARM ORDER WAS A SILENT PRIORITY LIST that nothing declared and nothing
# tested. The sharpest instance was self-referential — the `pipe-status` arm is
# LAST in this file, and the very incident its own message cites
# (`git push … | tail -2` reporting rc 0 for a rejected push) was pre-empted by
# the earlier `git-push` row, so that message could never reach the worker who
# needed it. "The arm matches X" and "the worker is warned about X" had come
# apart, invisibly from either the arm or its tests.
#
# The correlation is what made it worse than a cosmetic gap: the footguns most
# likely to be pre-empted are the ones that CO-OCCUR with a more common
# trigger, so a rare footgun paired with a frequent one was permanently
# invisible. And it was not even stable within a session — once the pre-empting
# tag was marked seen, the NEXT occurrence of the same command shape surfaced a
# different rule.
#
# MEASURED BEFORE CHOSEN, because `#1057` offered two directions and said the
# choice depends on how often commands actually trip multiple arms — which
# nobody had counted. Corpus: 104,113 `Bash`/`Monitor` tool-call command
# strings extracted from 856 Claude Code transcripts under
# `~/.claude/projects/*/*.jsonl`, content dated 2026-05-29 .. 2026-08-28;
# every arm's matcher run against each, using THIS file's own regexes at
# `3458180` rather than re-typed ones. Agreement with the live hook on a
# 150-command sample: 150/150.
#
#   match >=1 arm  10,016 (9.6%)      >=3 arms  73 (0.07%)
#   match >=2 arms    784 (0.75%)     >=4 arms  14 (0.01%)
#
# So 7.8% OF ALL WARNED-ABOUT COMMANDS (784 of 10,016) tripped more than one
# arm and were told about one. Per-arm, matched vs actually delivered:
#
#   pipe-status       5,103 matched, 428 NEVER DELIVERED  (8.4%)
#   git-push            667 matched, 146 never delivered (21.9%)
#   tmux-kill-session    10 matched,   5 never delivered (50.0%)
#   tmux-kill-pane        4 matched,   4 never delivered  (100%)
#
# The last two are the argument. The tmux family is the ONLY one whose
# consequence this conf calls unrecoverable, it was deliberately split into
# four tags (`#951` F2) so one verb could not spend the family's warning — and
# row order re-introduced exactly that WITHIN the family, always via
# `tmux-kill-server` sitting above. Rarity correlates with invisibility, which
# is the wrong way round: a rare footgun co-occurring with a common one was
# permanently unreachable.
#
# THE NOISE BUDGET IS BOUNDED AND THE BOUND IS VISIBLE, which is the half that
# makes multi-delivery safe. A wall of reminders is how a guard gets tuned out,
# so at most $_MAX_DELIVER messages go out per command — but when more matched,
# the payload SAYS SO and NAMES the tags it withheld. A cap inferred from
# absence would reproduce the defect one level up. Withheld tags are
# deliberately NOT marked seen, so they surface on the next matching command
# rather than being spent silently.
#
# THE DEFAULT OF 3 IS FROM THAT CORPUS, not a guess: 3 covers 104,099 of
# 104,113 commands in full (99.987%), and the 14 that exceed it get the named
# withhold notice. The observed maximum was 5 arms, on 3 commands.
#
# DEDUP: each reminder fires at most ONCE per worker session, keyed on
# (window, tag) via a sentinel under monitor/.state/footgun-seen/.
# A worker who has seen the pkill warning doesn't re-read it on every
# later pkill — the reminder has done its job. A seen tag SKIPS ITS ROW
# and the scan continues; it does not end the hook, or one exhausted tag
# would disarm every other rule for that command (your-org/nexus-code#927).
# Only the tags actually DELIVERED are marked seen.
#
# Hot-path discipline: every failure path exits 0 (allow). A wedged or
# erroring PreToolUse hook would block the worker's turn; degrade
# silently instead. O(milliseconds): one conf read, cheap regexes.
#
# Inputs: PreToolUse payload JSON on stdin (.tool_name, .tool_input.command).
# Env: $NEXUS_WORKER_WINDOW (dedup key), $NEXUS_ROOT (state + conf root),
#      $NEXUS_STATE_DIR / $NEXUS_FOOTGUN_PATTERNS (test overrides),
#      $NEXUS_FOOTGUN_MAX_DELIVER (per-command warn cap, default 3).

set -u

command -v jq >/dev/null 2>&1 || exit 0

if [ -n "${NEXUS_STATE_DIR:-}" ]; then
    _state_dir="$NEXUS_STATE_DIR"
elif [ -n "${NEXUS_ROOT:-}" ]; then
    _state_dir="$NEXUS_ROOT/monitor/.state"
else
    exit 0
fi

if [ -n "${NEXUS_FOOTGUN_PATTERNS:-}" ]; then
    _pattern_file="$NEXUS_FOOTGUN_PATTERNS"
elif [ -n "${NEXUS_ROOT:-}" ]; then
    _pattern_file="$NEXUS_ROOT/monitor/bash-footgun-patterns.conf"
else
    _self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || _self_dir="."
    _pattern_file="$_self_dir/../bash-footgun-patterns.conf"
fi

_window="${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-unknown}}"

_payload=$(head -c 65536 2>/dev/null || true)
[ -n "$_payload" ] || exit 0

_tool=$(printf '%s' "$_payload" | jq -r '.tool_name // empty' 2>/dev/null) || _tool=""
# TOOLS THAT CARRY A SHELL COMMAND, not just `Bash` (your-org/nexus-code#927).
# `Monitor` runs its `.tool_input.command` in the same shell environment Bash
# does, so every footgun in this conf is reachable through it — and the WAIT
# shape especially, because Monitor is the workspace's documented tool for
# waiting (the `foreground-sleep` row below sends workers there by name).
# Measured: PreToolUse fires for Monitor with tool_name=Monitor and the command
# at .tool_input.command, so this arm is reachable, not aspirational.
# Registration must match: see monitor/worker-settings.json.
case "$_tool" in
    Bash|Monitor) ;;
    *) exit 0 ;;
esac

_cmd=$(printf '%s' "$_payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || _cmd=""
[ -n "$_cmd" ] || exit 0

_seen_dir="$_state_dir/footgun-seen"

# your-org/nexus-code#941 — the (window, tag) sentinel is keyed with the
# INJECTIVE encoder, like every other window-keyed surface. Two windows whose
# names collided under the old sanitiser shared one de-dup cache, so one of
# them silently lost its warning.
#
# THE FAILURE POLARITY IS INVERTED HERE, DELIBERATELY, and it is the reason
# this file was nearly left unconverted. Every other consumer fails CLOSED on
# a missing encoder, because there the dangerous act is proceeding. This is a
# PreToolUse hook: failing closed would block EVERY Bash command in the
# session, which is far worse than the defect. So an unreachable encoder
# disables the CACHE instead — `already_seen` answers "no" and the guard warns
# every time. Noisy is the safe direction for a warning; silent is not.
#
# What it must NOT do is fall back to the lossy key. A fallback would put two
# spellings of the same surface back in the tree at exactly the moment nobody
# is watching, which is the defect this closes.
#
# Cost, measured rather than assumed (the first draft declared this file
# exempt on a guess): sourcing _bookkeeping.sh costs ~3ms over a bare
# `bash -c ':'` baseline — 13ms vs 10ms, mean of 10. Not prohibitive.
if ! declare -F wk_encode >/dev/null 2>&1; then
    _wk_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_bookkeeping.sh"
    # shellcheck source=monitor/_bookkeeping.sh
    [ -r "$_wk_lib" ] && . "$_wk_lib" 2>/dev/null
fi

# _seen_key <tag> — the sentinel name, or empty when the encoder is
# unavailable (cache disabled; see the polarity note above).
_seen_key() {
    declare -F wk_encode >/dev/null 2>&1 || return 1
    printf '%s.%s' "$(wk_encode "$_window")" "$(wk_encode "$1")"
}

# already_seen <tag> — rc 0 if this (window, tag) reminder has already
# fired this session. Sentinel filename encodes both keys.
already_seen() {
    local key; key=$(_seen_key "$1") || return 1
    [ -f "$_seen_dir/$key" ]
}
mark_seen() {
    local key; key=$(_seen_key "$1") || return 0
    mkdir -p "$_seen_dir" 2>/dev/null || return 0
    : > "$_seen_dir/$key" 2>/dev/null || true
}

# deliver <severity> <tag> <message>: the BLOCK path. Prints to stderr and
# exits 2, which blocks the tool and shows the message to the model. Marks the
# (window, tag) seen.
#
# No arm calls it with `warn` any more — warns are collected and emitted
# together by `deliver_all` — but the warn branch is KEPT rather than removed,
# so an arm written in the old shape forwards into the accumulator instead of
# silently reinstating first-match-wins for itself. A stray `deliver warn`
# would then still deliver everything collected so far, which is the behaviour
# the file now promises.
deliver() {
    local severity="$1" tag="$2" msg="$3"
    mark_seen "$tag"
    if [ "$severity" = "block" ]; then
        printf 'bash-footgun-guard [%s]: %s\n' "$tag" "$msg" >&2
        exit 2
    fi
    collect "$tag" "$msg"
    deliver_all
}

# ---- the warn accumulator (your-org/nexus-code#1057) ----------------------
#
# THE CAP IS A NOISE CEILING, NOT A PRIORITY LIST. The difference is that it is
# ANNOUNCED: a withheld tag is named in the payload and is not marked seen, so
# the worker knows what it did not get and gets it next time. The old
# behaviour was a cap of one, inferred from absence, which is the shape this
# closes.
_MAX_DELIVER="${NEXUS_FOOTGUN_MAX_DELIVER:-3}"
_col_tags=(); _col_msgs=()

# collect <tag> <message> — record a matched, unseen warn. Dedups by TAG, so
# two conf rows sharing a tag (pkill + pgrep, the three force-push rows) still
# spend one slot between them, exactly as they did under first-match-wins.
collect() {
    local t
    if (( ${#_col_tags[@]} > 0 )); then
        for t in "${_col_tags[@]}"; do [ "$t" = "$1" ] && return 0; done
    fi
    _col_tags+=("$1"); _col_msgs+=("$2")
}

# deliver_all — emit every collected warn as ONE additionalContext, capped,
# with the withheld tags named. Exits; a no-op exit 0 when nothing collected.
deliver_all() {
    local n=${#_col_tags[@]} shown i msg="" rest=""
    (( n == 0 )) && exit 0
    shown=$(( n < _MAX_DELIVER ? n : _MAX_DELIVER ))
    for (( i = 0; i < shown; i++ )); do
        msg="${msg}${msg:+$'\n\n'}bash-footgun-guard [${_col_tags[i]}]: ${_col_msgs[i]}"
        mark_seen "${_col_tags[i]}"
    done
    if (( n > shown )); then
        for (( i = shown; i < n; i++ )); do rest="${rest}${rest:+, }${_col_tags[i]}"; done
        # NAMED, not merely counted: a reader who cannot see WHICH rules were
        # withheld is back to inferring a cap from absence.
        msg="${msg}"$'\n\n'"bash-footgun-guard: this command matched ${n} rules; ${shown} shown, ${rest} WITHHELD by the per-command cap (${_MAX_DELIVER}). The withheld tags are NOT marked seen — they will surface on your next command that matches them."
    fi
    # jq -n builds valid JSON and escapes the message safely.
    jq -nc --arg m "$msg" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:$m}}' \
        2>/dev/null || true
    exit 0
}

# ---- cc-update agents never mutate a git tree (your-org/nexus-code#1529) --
#
# THE ONE BLOCK ARM IN THIS FILE, AND WHY IT IS FIRST. The autonomous cc-update
# evaluator and its restart watchdog run in the LIVE primary clone with
# permissions bypassed; every rule that says "never pull, merge, check out,
# clone, worktree or execute another nexus-code tree" governed what those
# agents READ, never what they DID (measured by the w241 skeptic: no hook arm,
# `--dangerously-skip-permissions` at spawn). The operator's directive is that
# the automatic update must never bring in nexus-code from the remote — many
# people can push there — so for these two windows a git verb is refused
# unless it is on the READ-ONLY allowlist below. Deny is the default arm and
# nothing precedes it; the allowlist is keyed on the VERB TOKEN by equality,
# so no later arm can shadow it (CLAUDE.md, arm-order doctrine). A warn would
# be the wrong severity here: the consequence is unattended execution of
# whatever was last pushed, and the tool must not run.
#
# SCOPE is the two cc-update windows by NAME, read from THREE places
# (w241sk D2: the first cut read only this hook's own environment, so a
# custom `CC_AUTO_WINDOW` exported to the watcher but not to the evaluator
# left the evaluator unprotected): the env defaults `CC_AUTO_WINDOW` /
# `CC_AUTO_WATCHDOG_WINDOW` (defaulting as `_cc_auto_update.sh` does), and the
# marker files the two spawn sites write beside the routine's state —
# `<state>/cc-auto-update/evaluator-window` (`_cc_auto_update.sh`, at the
# evaluator spawn) and `<state>/cc-auto-update/watchdog-window` (`apply.sh`,
# at the watchdog spawn). Every other worker keeps its `git checkout -b` in
# its own worktree. Compat fixes are authored by a separate,
# orchestrator-dispatched worker — the evaluator files the issue and blocks.
#
# BOUNDARY, stated because the arm cannot see past it: this hook reads the
# Bash/Monitor COMMAND TEXT. A `git` binary reached through a variable
# (`"$g" pull`), and a script written by the Write tool and then executed
# (`bash /tmp/s.sh`), carry no `git` word here and pass. This arm is defence
# in depth against the ROUTINE drifting into an auto-update, not a sandbox
# against a determined agent: an agent that can call python can call git.
#
# FAIL CLOSED ON AN UNREADABLE IDENTITY (w241sk D2). The spawn path always
# exports `NEXUS_WORKER_WINDOW`; a process with it unset reads as `unknown`.
# When the routine's own marker file exists — the drive has spawned an
# evaluator in this nexus — an `unknown` window is IN scope: a session whose
# provenance nothing can vouch for is refused a git mutation, rather than
# allowed on the strength of a missing variable. DIRECTION OF ERROR: this
# refuses an unidentified Claude session's `git pull`/`checkout` in a nexus
# where the routine has fired (the rule CLAUDE.md states for the primary
# clone anyway); it never allows the evaluator by mistake. Without the
# marker there is nothing to vouch for either way and `unknown` stays out of
# scope, which is the stated residual.
_ccu_in_scope=0
_ccu_marker_seen=0
for _ccu_f in "$_state_dir/cc-auto-update/evaluator-window" "$_state_dir/cc-auto-update/watchdog-window"; do
    [ -e "$_ccu_f" ] && _ccu_marker_seen=1
done
for _ccu_w in "${CC_AUTO_WINDOW:-cc-auto-update}" "${CC_AUTO_WATCHDOG_WINDOW:-cc-restart-watchdog}" \
              "$(head -c 200 "$_state_dir/cc-auto-update/evaluator-window" 2>/dev/null | tr -d '\n')" \
              "$(head -c 200 "$_state_dir/cc-auto-update/watchdog-window" 2>/dev/null | tr -d '\n')"; do
    [ -n "$_ccu_w" ] && [ "$_window" = "$_ccu_w" ] && _ccu_in_scope=1
done
[ "$_ccu_marker_seen" = 1 ] && [ "$_window" = "unknown" ] && _ccu_in_scope=1
if [ "$_ccu_in_scope" = 1 ]; then
    # Every `git … <verb>` in the command: an optional path before `git`
    # (`/usr/bin/git`), any leading options — each may take one argument
    # (-C <dir>, -c <k=v>) or an `=value` — then the verb token. A `.git/`
    # path or `nexus-code.git` is not a `git` word: the char before must not
    # be a path/word char, and whitespace must follow. A verb spelled as a
    # subprocess argv literal (`["git","pull"]`) is read too.
    _ccu_readonly='rev-parse|merge-base|log|diff|diff-tree|show|show-ref|ls-remote|fetch|cat-file|status|rev-list|ls-files|ls-tree|for-each-ref|describe|name-rev|grep|blame|check-ignore|count-objects|version|help'
    _ccu_head='(^|[^A-Za-z0-9_./-])([^[:space:]"'"'"']*/)?git([[:space:]]+-[A-Za-z-]+(=[^[:space:]]*)?([[:space:]]+[^[:space:]-][^[:space:]]*)?)*[[:space:]]+'
    # A quote in the command TEXT may arrive backslash-escaped (`[\"git\",\"pull\"]`
    # inside a double-quoted python -c string), so the quote class admits one.
    _ccu_q='\\?['"'"'"]'
    _ccu_denied=$( { grep -oE "${_ccu_head}[A-Za-z][A-Za-z-]*" <<<"$_cmd" | sed -E 's/.*[[:space:]]//'
                     grep -oE "${_ccu_q}git${_ccu_q}[[:space:]]*,[[:space:]]*${_ccu_q}[A-Za-z][A-Za-z-]*${_ccu_q}" <<<"$_cmd" \
                         | sed -E "s/.*,[[:space:]]*${_ccu_q}//; s/${_ccu_q}\$//"; } \
        | grep -vxE "$_ccu_readonly" | sort -u | tr '\n' ' ')
    # A read-only verb whose OUTPUT is remote code — `show origin/dev:<path> |
    # bash`, `cat-file -p FETCH_HEAD:<path> > f` (w241sk D1, the directive
    # verbatim through two allowlisted verbs): a `<remote-ref>:<path>` blob spec
    # on a git line is refused whatever the verb.
    if grep -qE "${_ccu_head}[A-Za-z]" <<<"$_cmd" \
       && grep -qE '(origin/|FETCH_HEAD|refs/remotes/|@\{u(pstream)?\})[^[:space:]]*:[^[:space:]]' <<<"$_cmd"; then
        _ccu_denied="${_ccu_denied}remote-blob-spec "
    fi
    if [ -n "$_ccu_denied" ]; then
        deliver block "cc-update-git" \
            "REFUSED for window '$_window': git verb(s) [${_ccu_denied% }] are not on the read-only allowlist ($_ccu_readonly), or the line reads a <remote-ref>:<path> blob (remote code as output). The cc-update evaluator and watchdog never mutate ANY git tree and never execute remote nexus-code (your-org/nexus-code#1529, operator directive: the automatic update must never bring in nexus-code from the remote — many people can push there, especially to dev). The gate runs only against the live clone's own checked-out code; a RED blocks on the local classifier and the next daily fire re-gates after the OPERATOR deploys. A compat fix is authored by a separate worker: file the issue, record the block, do not create a worktree or clone here. Read-only verbs on local refs pass unchanged."
    fi
fi

# ---- conf-driven matches (command-name / flag triggers) ----------------
# EVERY matching UNSEEN row is collected; all of them are delivered together at
# the foot of this file (your-org/nexus-code#1057). Rows sharing a tag collapse
# via `collect`'s tag dedup, so pkill and pgrep still spend one slot between
# them.
#
# AN ALREADY-SEEN TAG SKIPS ITS ROW, IT DOES NOT END THE GUARD
# (your-org/nexus-code#927). This arm used to `exit 0` on a seen tag, which
# left the WHOLE hook — so a command whose first match was any tag this window
# had already met was silently unguarded for every LATER rule, including the
# three in-code checks below, which sit after this loop and were therefore the
# most exposed. Measured on the live corpus: 207 of 421 windows carried two or
# more sentinels, i.e. were already in that muted regime.
#
# ROW ORDER IS NOW PRESENTATION ORDER, NOT A PRIORITY LIST
# (your-org/nexus-code#1057). It used to be both, silently: `deliver` exited, so
# the first matching row was the ONLY one a worker ever saw and everything below
# it was pre-empted for that command. Rows are still emitted in file order — the
# WAIT rows lead, and the tmux rows lead the file — but a lower row is no longer
# unreachable merely because a higher one also matched. The order assertions in
# the tests now pin WHICH MESSAGE COMES FIRST, which is a real and checkable
# claim, rather than which message exists at all.
#
# `block` still outranks everything and short-circuits: it exits 2, so the tool
# does not run and the advisory rows are moot.
if [ -f "$_pattern_file" ]; then
    while IFS='|' read -r tag severity cmd_re message; do
        [ -z "${tag// /}" ] && continue
        case "$tag" in '#'*) continue ;; esac
        [ -n "$cmd_re" ] || continue
        # `\p` -> a literal `|` in the regex field (your-org/nexus-code#835).
        # The field separator IS `|`, so a regex could not previously refer to
        # a pipe at all — which left every "still in the same command" exclusion
        # class blind to the one separator that matters most. `git push origin
        # main | grep -f pats` then matched a force-push rule on grep's `-f`,
        # and (first-match-wins) the worker LOST the cwd-pinning reminder it
        # should have had. Substitution happens after field splitting, so the
        # separator semantics are untouched.
        cmd_re=${cmd_re//\\p/|}
        [[ "$_cmd" =~ $cmd_re ]] || continue
        # `unbounded-command-wait` (your-org/nexus-code#1447) keys on the LOOP
        # SHAPE, deliberately not on the predicate, so the population is not
        # "predicates somebody thought of". The four exemptions below are the
        # only ones, and each is a form with a MORE SPECIFIC owner: the two
        # forms this repo blesses (`kill -0 <pid>` in `lint-no-mass-kill.sh`;
        # `proc-exists-authorized`, which owns its own loop) and the two shapes
        # that already have their own row (`[ -f X ]` → unbounded-sentinel-wait,
        # `pgrep` → procmatch-wait), so a worker is not told the same thing
        # twice — plus `while read`, which is consumption, not a wait, and a
        # predicate reading `/proc/<pid>/…`, which is keyed on an IDENTITY. Read as
        # an allowlist of DISARMS with a default of WARN, which is the polarity
        # #1121 requires. The regex lives in a VARIABLE: an inline `[[ =~ ]]`
        # regex with `|`, `(` and `!` is parsed as shell grammar first.
        if [ "$tag" = unbounded-command-wait ]; then
            _ucw_disarm='\b(until|while)[[:space:]]+(!?[[:space:]]*)?(kill[[:space:]]+-0[[:space:]]|[^;]{0,60}proc-exists-authorized|[^;]{0,80}\[[[:space:]]*(![[:space:]]*)?-[fserdxwn]|[^;]{0,60}pgrep|[^;]{0,120}/proc/|read[[:space:]])'
            [[ "$_cmd" =~ $_ucw_disarm ]] && continue
        fi
        # Seen: this row has done its job. Skip the ROW, keep scanning.
        already_seen "$tag" && continue
        # A block short-circuits: it exits 2, so nothing else can matter.
        [ "${severity:-warn}" = "block" ] && deliver block "$tag" "$message"
        collect "$tag" "$message"
    done < "$_pattern_file"
fi

# ---- in-code matches (pipe-triggered; can't live in a |-delimited conf) --
# These footguns trigger on a literal shell pipe, which the conf's field
# separator forbids. Matched here instead. Same dedup + delivery.

# python … | tail/tee block-buffers and reads as a hang.
if grep -Eq 'python[0-9.]*\b[^|]*\|[[:space:]]*(tail|tee)\b' <<<"$_cmd"; then
    already_seen "pipe-buffer" || collect "pipe-buffer" \
        "Pipelines block-buffer: python … | tail/tee emits nothing until the process exits and reads as a hang. Add python -u (or flush=True), or drop the pipe."
fi

# ml/module piped: the env-changing eval is discarded in the subshell.
if grep -Eq '\b(ml|module)[[:space:]][^|]*\|' <<<"$_cmd"; then
    already_seen "ml-pipe" || collect "ml-pipe" \
        "ml/module is a shell function; piping it forks a subshell and the env-changing eval is silently discarded (the module never loads). Run ml … on its own line, unpiped."
fi

_pm_tool='(command[[:space:]]+)?(grep|egrep|fgrep|rg)([[:space:]]|$)'
_pm_wait_hit=0

# A WAIT LOOP whose condition is an ARGV MATCH (your-org/nexus-code#1073).
#
# THIS IS A DIFFERENT FOOTGUN FROM THE ONE BELOW, and it used to be delivered
# the one below's message. `procmatch-wait` in the conf keys on `pgrep … -f`,
# so the `ps … | grep` SPELLING of a wait loop was invisible to the wait arm;
# `procmatch-self` then won by default and told a worker whose loop could not
# terminate to "bracket the pattern" — advice that does not touch the hazard,
# for a construct whose failure is silent non-termination.
#
# WHY IT FAILS IN BOTH DIRECTIONS, which is what makes inverting the loop
# useless:
#
#   until … grep -q <pat>   EXITS IMMEDIATELY on a sibling's prompt match when
#                           the job never started. The caller then proceeds as
#                           though a job completed that never ran — the
#                           MANUFACTURED-SUCCESS direction, where every visible
#                           artefact says the work was done and the only
#                           evidence is an absence.
#   while … grep -q <pat>   WAITS FOREVER while any agent holds the string in
#                           argv. A wait loop of exactly this shape held a
#                           window for 5h20m reading `working-background`,
#                           burning 191 CPU-seconds, with nothing looking at it.
#
# Bracketing is irrelevant in both: it defeats the observer, not the siblings.
# Measured live on this board, 2026-08-27, while writing this: a correctly
# bracketed `[g]uards-for-diff` matched 12 processes, three of them sibling
# `claude`s in foreign sessions. So the loop CANNOT terminate on this host, and
# no spelling of the pattern changes that.
#
# THE REMEDY HANDED OVER IS A TOOL, NOT A PROHIBITION, because the previous
# advice here ("bracket the pattern") is what a prohibition-without-replacement
# degenerates into. `proc-exists-authorized` OWNS THE LOOP — the caller never
# writes `until`/`while` around it, so the polarity cannot be inverted — and it
# refuses `--until-gone --match` outright, because "nothing I own matches" is
# not "the job is gone".
_pm_wait='(^|[[:space:];&|(])(until|while)[[:space:]]'
if grep -Eq "${_pm_wait}[^;]*\bps[[:space:]][^|]*\|[[:space:]]*${_pm_tool}" <<<"$_cmd"; then
    _pm_wait_hit=1
    already_seen "procmatch-wait-ps" || collect "procmatch-wait-ps" \
        "A WAIT LOOP keyed on an argv match CANNOT BE MADE CORRECT BY SPELLING, and it fails in BOTH directions — so inverting it does not help. \`until … grep -q <pat>\` EXITS IMMEDIATELY on a sibling agent's prompt match when your job never started, and you proceed as though it finished; \`while … grep -q <pat>\` WAITS FOREVER while any agent holds that string in argv (a loop of this exact shape held a window for 5h20m reading \`working-background\`). Bracketing defeats only the grep's own hit: measured on this board 2026-08-27, a correctly bracketed \`[g]uards-for-diff\` matched 12 processes, three of them live sibling \`claude\`s whose PROMPTS quote the string. Use \`\$NEXUS_ROOT/monitor/proc-exists-authorized\`, which OWNS THE LOOP so the polarity cannot be written wrong: \`--until-present --token <t>\` / \`--pid <n>\` / \`--match <ere>\` (session-scoped, default-deny), or \`--until-gone --token <t>\` / \`--pid <n>\`. It REFUSES \`--until-gone --match\` on purpose — \`nothing I own matches\` is not \`the job is gone\`, and your own setsid-detached job is invisible to any session-scoped match. Its exit codes separate the three answers a two-valued predicate fuses: 0 present, 1 absent, 3 REFUSED (could not determine), 4 timeout."
fi

# `ps … | grep <pattern>` — the third self-matching process-table shape
# (see the procmatch-wait / pkill-self block in the conf). Its trigger is
# a literal pipe, so it cannot be expressed in the |-delimited conf.
#
# ── THE MESSAGE IS PATTERN-AWARE, THE TRIGGER IS NOT
#    (your-org/nexus-code#1059) ───────────────────────────────────────────
#
# This arm used to prescribe "bracket the pattern (`[p]attern`)" and then fire
# on exactly that. Two agents in two sessions hit it independently, one on its
# first command of the session, both on a correctly bracketed form — and a
# guard that punishes the workaround it teaches trains agents to ignore the
# guard. The noise was ANTICORRELATED with the mistake: the agents most likely
# to trip it were the ones who read the message and complied.
#
# THE FIX IS THE MESSAGE, NOT THE TRIGGER, and that is the opposite of what
# `#1059` proposed ("suppress when the grep pattern is bracketed"). Suppressing
# would have been wrong, and it was measured wrong rather than argued wrong.
# Bracketing defeats exactly ONE of the two matches this arm is about:
#
#   the OBSERVER's own hit   — the grep's argv holds the pattern.
#                              MEASURED: `ps -eo pid=,args= | grep nonce | wc -l`
#                              -> 3;  the bracketed spelling -> 0. Bracketing
#                              genuinely closes this one.
#
#   the SIBLING's hit        — every other agent's `claude` argv holds its
#                              ENTIRE PROMPT, and prompts quote the watched
#                              string verbatim. MEASURED on this board,
#                              2026-08-27: a CORRECTLY BRACKETED
#                              `[g]uards-for-diff` matched 12 processes, three
#                              of them live sibling `claude`s in other
#                              sessions (one carried 15265 bytes of argv).
#                              Bracketing does nothing here, and the population
#                              GROWS WITH EVERY WORKER SPAWNED.
#
# So a bracketed `ps | grep` is still a substantively warranted warning, and
# suppressing it would have closed `#1059` by opening `#1073` wider — a false
# NEGATIVE on precisely the sibling-argv case. What was wrong was telling a
# complying worker to do the thing it had already done. The arm therefore fires
# on both spellings and says something DIFFERENT to each: the bracketed variant
# credits the half that is closed and names the half that is not.
#
# THE BRACKET RECOGNISER PICKS A MESSAGE, NEVER WHETHER TO FIRE, which is why
# it is allowed to be imprecise. `[[:alpha:]]xyz` is classed as bracketed and
# is not a self-match defeat by intent; `[tm]uxwrap` is classed as bracketed
# and IS a working defeat (measured: it matches `tmuxwrap` via the `m` branch
# and does not match its own argv text). A misclassification costs a slightly
# off sentence, not a missed warning — which is the only reason a heuristic
# belongs anywhere near this file.
#
# ── MATCHER WIDTH ──────────────────────────────────────────────────────────
#
# `\bgrep\b` missed `fgrep` and `egrep` outright, because `\b` does not hold
# between `f` and `g`. Measured: `ps -eo args= | {fgrep,egrep,rg} <nonce> | wc -l`
# returns 3, 3, 3 — the IDENTICAL phantom count as `grep` — and all three were
# silent. `rg` is included for the same reason.
#
# `awk '/re/'` and `sed -n '/re/p'` carry the same hazard and are DELIBERATELY
# ABSENT, declared rather than chased: `ps … | awk '{print $1}'` is a column
# extraction, not a match, and it is the shape of the kill-list idiom CLAUDE.md
# blesses (`ps -eo pid=,args= | awk '/run-tests\.sh/ {print $1}' |
# proc-kill-authorized --filter`). Firing there would flag a prescribed remedy —
# the exact defect this block exists to remove.
if grep -Eq "\bps[[:space:]][^|]*\|[[:space:]]*${_pm_tool}" <<<"$_cmd" && [ "$_pm_wait_hit" = 0 ]; then
    # _pm_is_bracketed — is the first non-flag token after the matcher a
    # bracketed character class? Quotes stripped; flags skipped so `grep -e
    # '[t]x'` and `grep -F '[t]x'` classify the same as the bare form.
    #
    # `read -ra`, NOT `set -- $seg`. Word-splitting via `set --` ALSO performs
    # PATHNAME EXPANSION, and `[t]muxwrap` is a valid glob: run from a cwd
    # holding a file of that name it expands to `tmuxwrap`, the brackets
    # vanish, and the recogniser silently misclassifies the exact spelling it
    # exists to detect. MEASURED, not hypothesised, and the trap is live in
    # this repo — `monitor/tmuxwrap/` exists, so the unquoted form
    # `ps aux | grep [t]muxwrap` classified as BRACKETED from `/tmp` and as
    # BARE from `monitor/`. A classification that depends on the caller's cwd
    # is the plausible-wrong-answer class, inside the fix for it. `read` splits
    # on IFS and never globs.
    _pm_is_bracketed() {
        local tok
        local -a _toks=()
        read -ra _toks <<<"$(sed -E "s/.*\|[[:space:]]*(command[[:space:]]+)?(grep|egrep|fgrep|rg)[[:space:]]+//" <<<"$_cmd")"
        for tok in ${_toks[@]+"${_toks[@]}"}; do
            case "$tok" in -*) continue ;; esac
            tok="${tok#\'}"; tok="${tok#\"}"
            case "$tok" in \[*\]*) return 0 ;; *) return 1 ;; esac
        done
        return 1
    }
    if _pm_is_bracketed; then
        already_seen "procmatch-self" || collect "procmatch-self" \
            "You BRACKETED the pattern, and that is the right instinct — it closes the grep's OWN self-match (measured: 3 hits unbracketed, 0 bracketed). IT CLOSES NOTHING ELSE, and the other match is the one that matters here. Under a worker every SIBLING agent's \`claude\` argv holds its entire PROMPT, and prompts quote the watched string verbatim — measured on this board 2026-08-27, a correctly bracketed \`[g]uards-for-diff\` matched 12 processes, three of them live sibling \`claude\`s in other sessions. That population grows with every worker spawned and NO string can exclude it, so a bracketed count is not a trustworthy count and a bracketed WAIT LOOP still cannot terminate. Ask by a handle instead: \`\$NEXUS_ROOT/monitor/proc-exists-authorized --token <async-run-token>\` / \`--pid <recorded-pid>\` / \`--match <ere>\` — it scopes by SESSION ownership (a process can leave your session, never join it), so siblings are excluded structurally rather than textually."
    else
        already_seen "procmatch-self" || collect "procmatch-self" \
            "\`ps … | grep <pattern>\` cannot answer \"is it running\". TWO unintended matches, and they need different fixes. (1) The grep's OWN argv holds the pattern, so there is always a phantom hit — bracketing (\`[p]attern\`) closes THIS ONE AND ONLY THIS ONE. (2) Under a worker, every sibling agent's \`claude\` argv holds its entire PROMPT, and prompts quote the watched string verbatim; measured on this board 2026-08-27, even a correctly bracketed \`[g]uards-for-diff\` matched 12 processes, three of them live sibling \`claude\`s. No string excludes that population and it grows with every worker spawned. Ask by a handle: \`\$NEXUS_ROOT/monitor/proc-exists-authorized --token <async-run-token>\` / \`--pid <recorded-pid>\` / \`--match <ere>\` (session-scoped, reads /proc directly so it has no observer to self-match). \`pgrep -x <exact-name>\` is fine when you truly mean the command NAME. Best of all: record the pid at launch and test THAT."
    fi
fi

# A PIPELINE'S EXIT STATUS IS ITS LAST COMMAND'S — and here the status is
# CONSUMED. your-org/nexus-code#1046. The third member of this family, and the
# one CLAUDE.md documents most prominently; the guard already carried its two
# siblings above, and an UNENROLLED sibling is more dangerous than an
# undocumented one, because the guard's existence is itself read as coverage.
#
# THE PREDICATE IS NARROW ON PURPOSE. A bare `| tail` is extremely common and
# almost always harmless — you are reading output and do not care about the rc.
# Firing on every one would get the hook tuned out, which is worse than no hook
# AND would degrade the two arms above that currently work. So BOTH halves are
# required:
#   1. the LAST stage swallows the status — tail/head/wc/grep -c essentially
#      always succeed; AND
#   2. that status is then READ — `||`, `&&`, `$?`, or an if/while/until test.
#
# `tail -f app.log | grep --line-buffered ERROR` is the shape this must not
# touch: `tail` is the FIRST stage there and the last stage swallows nothing.
# `grep -c` IS DELIBERATELY ABSENT, and #1046's own list was wrong to include it.
# The criterion is "commands that essentially always succeed", and `grep -c` does
# NOT: it prints `0` and exits **1** when nothing matches (measured on this host;
# `tail`/`head`/`wc` all exit 0 on empty input). So `… | grep -c X || true` is the
# standard, CORRECT absorption of grep's own zero-match status, not a symptom of
# this defect. Keying on it would fire at 45 sites — 40 of them that exact idiom
# — while NONE of the five field instances in #1046 used `grep -c` (all five
# terminate in `tail`). That is a pure noise trade with zero coverage gained, and
# noise is what gets a hook tuned out.
#
#   git grep -hE "[|][[:space:]]*grep[[:space:]]+-[A-Za-z]*c[A-Za-z]*[^;|&]*([|][|]|&&)" \
#       1475509 -- '*.sh'          # -> 45
#   …same with "[|][|][[:space:]]*true" in place of the trailing group  # -> 40
#
# A COUNT IS A PROPERTY OF A TREE, so the ref is stated beside it — and this one
# is SELF-REFERENTIAL, which is why re-running it later will not reproduce the
# figure the decision was made on. At `2d32449` and `100cf13` it was 39/34; from
# `00524c0` it is 45/40. The +6 is THIS CHANGE'S OWN TEXT: one line here quoting
# `| grep -c X || true` as an example, five in the new test cases. Writing the
# justification moved the number it cites. Growth on a later tree is therefore
# expected and is not the comment rotting; re-derive at the ref you care about.
# The decision is unaffected — 45/40 argues it more strongly than 39/34 did.
#
# The loop does not stop here, and saying so is cheaper than letting the next
# reader find it: THIS note quotes the idiom once more (line ~264), so at the
# merge of the change that added it the figure becomes 46/41. 45/40 is quoted
# rather than 46/41 because `1475509` is a ref that EXISTS and can be re-run;
# a count of a tree that does not exist yet is not checkable, which is the whole
# rule. Expect +1 per future mention.
#
# `head` FIRST, deliberately. `early-exit-readers.sh` classifies a literal
# `|head` as an early-exit reader site, and an alternation written
# `(tail|head|…)` contains that substring — so it booked a phantom row in a
# CHECKED boundary manifest for a "pipeline" that is a regex, not a pipe.
# Alternation order is semantically irrelevant here (disjoint literals), and
# neither `tail` nor `wc` is an early-exit kind, so leading with `head` keeps the
# manifest honest without recording a site that does not exist.
# TRAILING WORD BOUNDARY, or the swallower names match as SUBSTRINGS and any
# command whose name merely BEGINS with one fires: `| headers.py --check && …`,
# `| tailscale status && …`, `| wcgrep x && …` were all measured firing without
# it. `[[:<:]]`/`\b` are not portable across the greps and awks this file uses,
# so the boundary is spelled as an explicit negated class plus end-of-string.
_sw='(head|tail|wc)([^A-Za-z0-9_.-]|$)'
# `[|]`, not `\|`: awk rejects `\|` as an unknown escape and prints a warning
# to stderr on EVERY invocation — and this hook runs on every Bash call, so a
# per-call warning is noise in the worker's face. `[|]` is a literal pipe in
# both ERE (grep) and awk.
_pipe_sw="[|][[:space:]]*${_sw}"
_consumed=0
# (a) the pipeline is the left operand of `||` or `&&`
grep -Eq "${_pipe_sw}[^;|&]*(\|\||&&)" <<<"$_cmd" && _consumed=1
# (b) it sits in an if / while / until condition
grep -Eq "(^|[[:space:];&|])(if|while|until)[[:space:]][^;]*${_pipe_sw}" <<<"$_cmd" && _consumed=1
# (c) `$?` is read on the same line or the one after — the two spellings that
#     actually occur. A wider window would start matching unrelated rc checks.
#
# THE SAME-LINE ARM IS POSITIONAL (your-org/nexus-code#904 leg G). A `$?` that
# sits to the LEFT of the swallowing pipe cannot be reporting that pipe's
# status — the pipe has not run yet when `$?` is expanded — so firing there
# warns about a status the pipeline never touched. The shape this hits is
# `out=$(cmd 2>&1); echo "rc=$?"; printf '%s' "$out" | tail -2`, which is THE
# CAPTURE IDIOM THIS ARM'S OWN MESSAGE PRESCRIBES. Measured over 136,424 Bash
# tool-call command strings from 1,367 transcripts under
# `~/.claude/projects/**/*.jsonl` (2026-07-31 .. 2026-09-02): 1,338 of 7,829
# matches (17.1%) are this shape. An arm that fires on the remedy it hands out
# is `#1059` in a second place — there the message told a complying worker to
# do what it had already done; here it tells a complying worker it did the
# thing wrong. The NEXT-LINE arm keeps no position test: a `$?` on the
# following line is always after the pipe.
awk -v P="$_pipe_sw" '
    $0 ~ P && match($0, P) && index(substr($0, RSTART), "$?") > 0 { found = 1 }
    prev ~ P  && $0 ~ /\$\?/ { found = 1 }
    { prev = $0 }
    END { exit found ? 0 : 1 }
' <<<"$_cmd" && _consumed=1

# THE AUTHOR ALREADY HANDLED IT — disarm, do not warn (your-org/nexus-code#904
# leg G). `set -o pipefail` makes the pipeline's status the producer's, and a
# `${PIPESTATUS[n]}` / `${pipestatus[n]}` read takes it directly; both are
# remedies this arm's own message names. 1,157 of 7,829 matches (14.8%) carry
# one.
#
# THE PATTERN MATCHES THE CONSTRUCT, NEVER THE BARE WORD, and that is the whole
# care in this line. A first cut keyed on `pipefail|PIPESTATUS` anywhere in the
# command disarmed the arm on FIVE genuine defects in an 80-command sample,
# every one of them merely NAMING a file — `test-early-exit-pipefail-axis.sh`,
# `test-claude-md-pipeline-status.sh`. A disarm keyed on a substring of a
# filename is a silent false negative in a guard, which is strictly worse than
# the noise it was written to remove.
if grep -Eq 'set[[:space:]]+-[A-Za-z]*o[A-Za-z]*[[:space:]]+pipefail|[$][{](PIPESTATUS|pipestatus)\[' <<<"$_cmd"; then
    _consumed=0
fi

# DELIVERY PRECEDENCE, recorded because it bounds what this arm can achieve:
# `deliver` ends in `exit 0`, so a command gets AT MOST ONE warning and the first
# matching row wins. This arm is LAST in the file, so a command that also trips an
# earlier arm never shows this message — including, measured, the very incident
# this message cites: `git push … | tail -2` is pre-empted by the `git-push` row.
# The worker still gets *a* warning, so this is a precedence note rather than a
# hole; but do not read "the arm fires on X" as "the worker is told about X".
if [ "$_consumed" = 1 ]; then
    already_seen "pipe-status" || collect "pipe-status" \
        "A PIPELINE'S EXIT STATUS IS ITS LAST COMMAND'S. You piped into \`tail\`/\`head\`/\`wc\` — which essentially always succeed — and then TESTED that status, so you are reading the pipe-terminator's success, never the real command's. TWO DIRECTIONS, differing in severity: MASKING a failure is recoverable (something downstream eventually disagrees); MANUFACTURING a success is not — every visible artefact says the work was done and the only evidence is an absence. Both were measured in this workspace: \`./window-close.sh 17 | tail -5 || tmux kill-window -t 17 && echo closed\` printed its success line for a script that DOES NOT EXIST (the pipeline returned 0, so the \`||\` arm never ran, and the window resurfaced later); and \`git push … | tail -2\` reported rc=0 for a server-REJECTED push, inside a retry loop written to catch exactly this. Fix: drop the pipe, or capture the status BEFORE piping (\`cmd > out; rc=\$?; tail -5 out\`), or \`set -o pipefail\`. Note also that \`a || b && c\` parses as \`(a || b) && c\`, so a trailing \`&& echo done\` announces the same thing whether the primary or the fallback ran."
fi

# Everything that matched, delivered together (your-org/nexus-code#1057).
deliver_all
exit 0
