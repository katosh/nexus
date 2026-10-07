#!/usr/bin/env bash
# monitor/hooks/async-launch-detect.sh
#
# Claude Code PostToolUse hook for the `Bash` matcher. Inspects the
# command the worker just ran and the stdout it produced; when one
# of the patterns in `monitor/async-launch-patterns.conf` fires,
# adds a (kind, id, desc) entry to the per-window heartbeat's
# `external_waits` array. The watcher's `pane-state.sh` classifier
# uses that array to emit `idle-orphan-async` against workers that
# launched async work but installed no resume mechanism (issue
# #183).
#
# Dismissed-launch escape hatch: if `(kind, id)` is already in the
# worker's `dismissed_waits` (set via `monitor/declare-no-wait.sh`),
# the launch is treated as deliberately fire-and-forget — no
# external_waits entry, no orphan-async signal. This lets a worker
# legitimately submit "set it and forget it" jobs without the
# watcher noising the operator.
#
# Data-driven: `monitor/async-launch-patterns.conf` is the pattern
# source. Adding a new launch class is a data edit, not a code
# change. See the conf file for the row format.
#
# Atomic write: read the heartbeat → mutate `external_waits` →
# write to `<file>.$$.tmp` → rename. The PostToolUse heartbeat
# hook (`monitor/worker-heartbeat.sh`) preserves `external_waits`
# and `dismissed_waits` across its own writes, so the two hooks
# can fire in either order within the same PostToolUse cycle.
#
# Hot-path discipline: every failure path exits 0 silently. A
# wedged hook would block claude's turn — degraded silently is
# better than blocking. The classifier's pane-footer fallback
# still works even without this hook.
#
# Inputs / env:
#   $NEXUS_WORKER_WINDOW   tmux window name (exported by
#                          spawn-worker.sh).
#   $NEXUS_STATE_DIR       override (test escape hatch).
#   $NEXUS_ROOT            fallback root; also the source of
#                          async-launch-patterns.conf.
#   $NEXUS_ASYNC_PATTERNS  optional override for the conf path
#                          (test escape hatch).
#
# Stdin: PostToolUse payload JSON. We read `.tool_input.command`
# and `.tool_response.stdout`. Cap reads at 64 KiB each (claude's
# stdout can be large; we only need the launcher's success line).

set -u

# Guard rails — these don't fire stderr; missing env on a hook
# means we silently no-op. The hook is best-effort.
window="${NEXUS_WORKER_WINDOW:-}"
[[ -n "$window" ]] || exit 0

if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    state_dir="$NEXUS_STATE_DIR"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    state_dir="$NEXUS_ROOT/monitor/.state"
else
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

# Resolve pattern conf path. Prefer the env override; else fall
# back to NEXUS_ROOT or a script-relative location.
if [[ -n "${NEXUS_ASYNC_PATTERNS:-}" ]]; then
    pattern_file="$NEXUS_ASYNC_PATTERNS"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    pattern_file="$NEXUS_ROOT/monitor/async-launch-patterns.conf"
else
    self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || self_dir="."
    pattern_file="$self_dir/../async-launch-patterns.conf"
fi
[[ -f "$pattern_file" ]] || exit 0

# Cap stdin at 64 KiB. claude's payloads are small (<2 KiB
# typical) but Bash tool_response.stdout can be arbitrary.
payload=$(head -c 65536 2>/dev/null || true)
[[ -n "$payload" ]] || exit 0

# Confirm this is a PostToolUse on Bash. The hook is configured
# with matcher="Bash" in worker-settings.json but a misconfigured
# install might funnel other tool calls here — defensively skip.
tool_name=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || tool_name=""
# WHO LAUNCHED IT (your-org/nexus-code#1439). An in-process subagent fires this
# hook under the PARENT's NEXUS_WORKER_WINDOW, so its wait lands on the parent's
# heartbeat, where the parent's own transcript can never explain it — one such
# wait cost a search over 32 transcripts and 16,471 Bash calls. The payload
# carries the launching transcript (a subagent's is its own file) and, on
# harness builds that set them, an agent id; record them on the row so the
# owner can find the command instead of proving a negative.
launcher=$(printf '%s' "$payload" | jq -r '
    [ (.agent_id // .agent_type // empty),
      ((.transcript_path // empty) | tostring | split("/") | last | sub("\\.jsonl$"; "")) ]
    | map(select(length > 0)) | join("/")' 2>/dev/null) || launcher=""
launcher="${launcher:0:120}"
[[ "$tool_name" == "Bash" || "$tool_name" == "Monitor" ]] || exit 0

command_str=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || command_str=""
[[ -n "$command_str" ]] || exit 0

# Cap stdout at 16 KiB. The launcher's "Submitted batch job N"
# line is in the first few hundred bytes; we don't need the tail.
#
# DO NOT ENABLE THE PIPE-STATUS SHELL OPTION IN THIS FILE, and do not "fix"
# the `|| stdout_str=""` arm below by adding it (your-org/nexus-code#1056
# skeptic pass). The arm reads the PIPELINE's status, so today it is dead —
# and its deadness is load-bearing. `head -c` deliberately closes the pipe
# once it has its 16 KiB; past that plus the pipe buffer, `jq`'s next write
# gets SIGPIPE and PIPESTATUS becomes `0 141 0`.
#
# IT IS A RACE, NOT A THRESHOLD, and that is the part worth carrying: whether
# `jq` is still writing when `head` exits depends on scheduling. Measured on
# this host, 20 runs per size, BASH_ENV present:
#
#     payload  70 000 bytes ->  0/20 fire
#     payload  79 000 bytes -> 11/20 fire      <- NON-DETERMINISTIC
#     payload  82 000 bytes -> 20/20 fire
#     payload 200 000 bytes -> 20/20 fire
#
# Certainty arrives around 16384 + 65536 = 81920 (head's 16 KiB plus the 64 KiB
# default pipe buffer), so the boundary moves with F_GETPIPE_SZ. Do not quote a
# single cutoff: two earlier attempts did, one by bisecting — and bisection
# assumes monotonicity, which this does not have, so it can only return an
# artefact. With the option OFF, as here, the truncation succeeds and the
# first 16 KiB is kept — which is exactly what this line wants. Turn the
# option ON and that same successful, deliberate truncation becomes rc 141,
# the arm fires, and `stdout_str` is BLANKED. `stdout_str` gates the job-id
# extraction below (the `[[ -n "$stdout_str" ]]` guard and the read loop), so
# the hook would silently stop recording async launches for every
# large-output Bash call — the precise failure it exists to prevent.
#
# The option is named here by description only, never by its literal token:
# `early-exit-readers.sh`'s axis predicate greps whole files for that string
# with no comment stripping, so writing it would enrol this file onto the
# axis (your-org/nexus-code#1106).
stdout_str=$(printf '%s' "$payload" | jq -r '.tool_response.stdout // empty' 2>/dev/null | head -c 16384) || stdout_str=""

# ---- HEREDOC BODY MASKING (your-org/nexus-code#1312) --------------------
#
# THE DEFECT. Per-line matching (your-org/nexus-code#948) is what recovers a
# launch on line 2 of a multi-line command, and it is also what made a HEREDOC
# BODY a scanning surface. This workspace writes documentation, PR bodies and
# python programs with heredocs constantly, so a body line reading
# `srun --no-block ./job.sh` — prose ABOUT the detector, or a python source
# line — occupies "start of line" exactly as a launch does. Measured in the
# wild: a session that ran no Slurm job at all accumulated five `syn-…` waits
# and was woken by the orphan-async loop 308 s later.
#
# WHY THIS IS NOT "SKIP HEREDOCS". A heredoc body is not uniformly data:
# `bash <<EOF … sbatch job.sh … EOF` GENUINELY EXECUTES its body, and so do
# `sh`, `zsh` and `ssh host <<EOF`. A blanket skip would convert a live
# detection into a SILENT MISS, which is the expensive direction — a missed
# launch lets a worker treat submitted work as finished.
#
# THE RULE IS AN ALLOWLIST WITH A DEFAULT OF **DO NOT MASK**, so every shape
# nobody thought of keeps TODAY's behaviour rather than losing it. A body is
# blanked only when the simple command governing the redirection is a named
# DATA CONSUMER — a program that writes its heredoc somewhere or parses it,
# and does not hand it to a shell. Anything else, including any command this
# list has never heard of, is scanned exactly as before. The denial side is
# therefore not a list that can be incomplete; it is the default arm.
#
# THREE FURTHER CONSERVATIVE ARMS, each failing toward the FALSE POSITIVE:
#   * a `|` ANYWHERE on the opening line refuses the mask, because
#     `cat <<EOF | bash` is a data consumer feeding a shell — measured, it
#     still fires;
#   * a `<<` that our cheap quote-parity check reads as being inside a string,
#     or that sits inside `((…))` (a LEFT SHIFT, not a heredoc — the trap
#     `th_strip_heredocs` documents), is not treated as an opener at all;
#   * an UNTERMINATED heredoc at the end of the command means the parse was
#     wrong, so the ENTIRE mask is discarded and the original command text is
#     scanned. Loud-and-conservative is unavailable in a hook that must never
#     block a turn; conservative alone is what is left.
#
# HOT PATH. The whole pass is skipped unless the command contains `<<` at all
# (one bash pattern test), and within a line it iterates over `<<`
# OCCURRENCES via parameter expansion, never over characters — so a 16 KB
# single-line command with no heredoc costs one comparison. No EXTERNAL
# process is spawned — one subshell fork for the command substitution, and
# that only on a command that contains `<<`; every existing cost in this hook
# is a `jq` exec. Measured against the unpatched hook over 20 fires per shape:
# no separation at a short command, a 16 KB single-line command, or a heredoc
# command. `th_strip_heredocs` in `monitor/watcher/_test_helpers.sh` is the
# in-tree precedent for the state machine; it is a TEST helper that takes a
# FILE and sources a companion awk, so it is reused as a design, not as code.
#
# RESIDUAL FALSE NEGATIVE, declared rather than hidden: a data consumer that
# re-executes its own body as shell — a python heredoc holding a shell script
# in a triple-quoted string it later passes to `subprocess` — is masked and
# missed. `cat` and `tee` cannot do this by construction. The ones that CAN are
# more of this list than first written (your-org/nexus-code#1312 skeptic F4):
# `python`/`python3`, `awk`/`gawk`/`mawk` (`system()`, `| "sh"`), `sed`
# (GNU `e`), and the DATABASE clients — `sqlite3` (`.system` / `.shell`, and it
# IS installed on this host), `psql` (`\!`) and `mysql` (`\!`) — every one of
# which has a documented shell escape and every one of which is on the
# allowlist above. It is admitted knowingly: the reachable shape requires the
# launch to sit at column 0 inside that inner string, and the alternative is
# the measured, recurring false-positive class above. Anyone tightening this
# should REMOVE members from the allowlist rather than add a parser — the
# default arm is DO NOT MASK, so a shorter list is strictly safer.
#
# Space-delimited so the membership test is a substring match on
# " $word ", which cannot partial-match (`bash` never matches `sbatch`).
_HD_DATA_CMDS=' cat tee python python2 python3 jq sed awk gawk mawk grep egrep fgrep sort head tail wc tr nl fold column diff patch cmp base64 md5sum sha1sum sha256sum mail mailx sendmail gh ng git psql sqlite3 mysql curl wget expand pr uniq cut paste '

# Blank the bodies of data-consumer heredocs in $1; print the result.
# Never fails: on any doubt it prints its input unchanged.
_mask_heredoc_bodies() {
    local src="$1"
    # A HEAD INDEX, not an array shift. `arr=("${arr[@]:1}")` on a
    # one-element array expands to nothing, and under `set -u` that is an
    # UNBOUND VARIABLE error on bash before 4.4 — in a hook whose every
    # failure path exits 0 silently, i.e. a portability bug that would
    # present as the detector quietly not working on an older host.
    local -a d_delim=() d_dash=() d_mask=(); local hp=0
    local out="" line t rest pre delim dash cmdword seg qd qs aop acl nopen abort=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( ${#d_delim[@]} > hp )); then
            t="$line"
            if (( d_dash[hp] )); then
                while [[ "$t" == "	"* ]]; do t="${t#	}"; done
            fi
            if [[ "$t" == "${d_delim[hp]}" ]]; then
                hp=$(( hp + 1 ))
                out+=$'\n'
                continue
            fi
            if (( d_mask[hp] )); then out+=$'\n'; else out+="$line"$'\n'; fi
            continue
        fi
        # The OPENING line is always emitted verbatim: `sbatch <<EOF` must
        # still fire from the opener even though its body is a job script.
        out+="$line"$'\n'
        [[ "$line" == *'<<'* ]] || continue
        # LINEAR, NOT QUADRATIC. An earlier form of this loop re-scanned the
        # whole accumulated prefix for quote parity and `((` depth on EVERY
        # `<<`, which is O(occurrences x line length). Measured on this host
        # against a synthetic `echo a<<b a<<b …` line: 200 occurrences took
        # 10.5 s and 600 did not finish inside 100 s, against a flat ~0.16 s
        # for the unpatched hook — a hook that WEDGES blocks claude's turn,
        # which is the exact hot-path objection your-org/nexus-code#1312
        # raised. The counters below are updated from the chunk just consumed,
        # so the whole line costs one pass. The `_hd_cap` arm is belt and
        # braces: past it, masking is abandoned entirely and the ORIGINAL text
        # is scanned, i.e. the hook degrades to its previous behaviour rather
        # than to a miss.
        qd=0; qs=0; aop=0; acl=0; seg=""; rest="$line"; nopen=0
        while [[ "$rest" == *'<<'* ]]; do
            nopen=$(( nopen + 1 ))
            if (( nopen > 64 )); then abort=1; break 2; fi
            pre="${rest%%'<<'*}"
            rest="${rest#*'<<'}"
            t="${pre//[^\"]/}"; qd=$(( qd + ${#t} ))
            t="${pre//[^\']/}"; qs=$(( qs + ${#t} ))
            t="${pre//'(('/}";   aop=$(( aop + (${#pre} - ${#t}) / 2 ))
            t="${pre//'))'/}";   acl=$(( acl + (${#pre} - ${#t}) / 2 ))
            # `seg` is the text since the last command separator — the simple
            # command that governs this redirection.
            if [[ "$pre" == *[\;\&\|\(]* ]]; then seg="${pre##*[;&|(]}"; else seg+="$pre"; fi
            # `<<<` is a herestring, not a heredoc.
            if [[ "$rest" == '<'* ]]; then rest="${rest#<}"; continue; fi
            # Odd quote count before us ⇒ this `<<` is inside a string. Erring
            # here can only FAIL TO MASK, never mask something executable.
            if (( qd % 2 )) || (( qs % 2 )); then continue; fi
            # `$(( a << b ))` is a LEFT SHIFT, not a heredoc.
            if (( aop > acl )); then continue; fi
            dash=0
            if [[ "$rest" == '-'* ]]; then dash=1; rest="${rest#-}"; fi
            while [[ "$rest" == ' '* || "$rest" == "	"* ]]; do rest="${rest#?}"; done
            delim=""
            case "$rest" in
                '"'*) rest="${rest#\"}"; delim="${rest%%\"*}"; rest="${rest#*\"}"; qd=$(( qd + 2 )) ;;
                "'"*) rest="${rest#\'}"; delim="${rest%%\'*}"; rest="${rest#*\'}"; qs=$(( qs + 2 )) ;;
                *)    [[ "$rest" == '\'* ]] && rest="${rest#\\}"
                      if [[ "$rest" =~ ^[A-Za-z0-9_]+ ]]; then
                          delim="${BASH_REMATCH[0]}"; rest="${rest#"$delim"}"
                      fi ;;
            esac
            # A delimiter that is not an identifier is a mis-parse (this is
            # what rejects the numeric delimiter a left shift manufactures).
            [[ "$delim" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            cmdword="${seg#"${seg%%[![:space:]]*}"}"
            cmdword="${cmdword%%[[:space:]]*}"
            if [[ "$line" != *'|'* ]] && [[ "$_HD_DATA_CMDS" == *" $cmdword "* ]]; then
                d_mask+=(1)
            else
                d_mask+=(0)
            fi
            d_delim+=("$delim"); d_dash+=("$dash")
        done
    done <<< "$src"
    # Unterminated at the end ⇒ the parse was wrong ⇒ mask nothing.
    # Same for the pathological-line abort. Both fall back to TODAY's
    # behaviour, never to a miss.
    if (( abort )) || (( ${#d_delim[@]} > hp )); then printf '%s' "$src"; else printf '%s' "$out"; fi
}

# The SCAN VIEW. `command_str` itself is untouched: the synthetic id is
# `sha1(command_str)`, so masking it would change every `syn-` id.
command_scan="$command_str"
case "$command_str" in
    *'<<'*) command_scan=$(_mask_heredoc_bodies "$command_str") || command_scan="$command_str" ;;
esac
[[ -n "$command_scan" ]] || command_scan="$command_str"

hb_dir="$state_dir/heartbeat"
mkdir -p "$hb_dir" 2>/dev/null || exit 0
hb_file="$hb_dir/$window.json"

# Read prior heartbeat for dismissed-waits filtering AND for
# preserving the rest of the fields across our atomic rewrite. A
# missing / corrupt file falls back to an empty skeleton — the
# next worker-heartbeat.sh tick will fill in the missing tick
# fields.
read_existing() {
    if [[ -f "$hb_file" ]] && [[ -r "$hb_file" ]]; then
        local content
        content=$(<"$hb_file") || content=""
        [[ -n "$content" ]] || content='{}'
        if printf '%s' "$content" | jq empty >/dev/null 2>&1; then
            printf '%s' "$content"
        else
            printf '{}'
        fi
    else
        printf '{}'
    fi
}

# Iterate pattern rows. First command_regex that matches the
# worker's command wins (a typical worker command matches at most
# one launch class anyway; deterministic ordering avoids
# surprises). We emit zero or one new external_waits entry per
# hook fire.
matched_kind=""
matched_desc=""
# ONE WAIT PER JOB, NOT ONE PER CALL (your-org/nexus-code#1071).
# A submission LOOP — `for i in 1..15; do sbatch …; done` — is a single Bash
# tool call whose stdout carries fifteen `Submitted batch job <id>` lines. The
# first version of this hook took `BASH_REMATCH[1]` from a whole-string match,
# i.e. the FIRST id, and synthesised `syn-…` for a call it could not id at all.
# Either way the fourteen remaining jobs were invisible, and a `slurm:syn-…`
# token has no job behind it, so nothing can look it up: it is unresolvable by
# construction and the operator's only escape is `declare-no-wait.sh`, which is
# the dangerous direction. A grid is the COMMON shape for this kind of work, so
# per-call tokenisation kept manufacturing exactly the wait the watcher's new
# wake loop (`monitor/watcher/_orphan_async.sh`) cannot resolve.
# Collect EVERY id instead; the ids are what make the waits resolvable.
matched_ids=()
# Ids a Slurm row parsed but the job-id predicate REFUSED (`0`, `007`), and
# whether a bare-number row was distrusted for sitting in `$(…)`. Neither is a
# watch, so both are named in the NOT-ARMED notice (your-org/nexus-code#1727).
_rejected_ids=()
_id_distrust=0
# An `sbatch` inside `$(…)` or backticks. Matched against the WHOLE scan view,
# not per line, so `jid=$(\n  sbatch --parsable …\n)` is caught too: `[^)…]`
# spans a newline in bash's ERE. Over-matching (`$(cat f) sbatch` cannot match:
# the class stops at the first `)`) errs toward distrusting a bare number,
# which costs a NOT-ARMED notice, never a wrong job.
_CMDSUBST_SBATCH_ERE='(\$\(|`)[^)`]*\bsbatch\b'
# ONLY THE ID SBATCH ITSELF PRINTS MAY ARM (your-org/nexus-code#1727 core). A
# `--parsable` row's id field accepts ANY bare-integer stdout line, and the hook
# sees the whole tool call's stdout, not sbatch's. `sbatch --parsable j.sh;
# grep -c x f` prints the id AND a count; proj-overlay2 armed `slurm:1` from two
# `grep -c` lines exactly so. So a bare number is trusted only when EVERY
# command segment of the call (split on ; && || | & and newlines) is an sbatch
# or a command that prints nothing to stdout here: cd, export, module/ml,
# source/., set, umask, true/:, a pure VAR=value assignment, a comment line,
# loop/branch syntax, and `tee` (it re-prints sbatch's own output).
# RESIDUAL, stated: `source`/`.` and `module` are allowed although a sourced
# file CAN print; `source env.sh; sbatch --parsable …` printing `7` would still
# be read as an id. They are allowed because they are how a submission is set
# up, and distrusting them would un-watch most real submissions.
# Any other segment may have printed the integer, so the call is DISTRUSTED:
# a `syn-` wait plus the NOT-ARMED notice, never a guessed id. Quoting and
# heredocs are not parsed; a separator inside quotes only ADDS segments, which
# errs toward distrust (a loud notice), never toward a wrong watch.
_parsable_call_is_sbatch_only() {   # <command text> → 0 when only sbatch can have printed
    local seg w
    while IFS= read -r seg || [[ -n "$seg" ]]; do
        seg="${seg#"${seg%%[![:space:]]*}"}"
        [[ -n "$seg" ]] || continue
        [[ "$seg" == \#* ]] && continue
        while [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+(.*)$ ]]; do
            seg="${BASH_REMATCH[1]}"
        done
        [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*$ ]] && continue
        # Shell CONTROL words and the WRAPPERS the slurm rows already accept
        # (timeout/nice/env/stdbuf/time/nohup) print nothing themselves:
        # strip them, and a wrapper's own option/duration tokens, then judge
        # the command they run. So `if grep -q …; then sbatch …` still judges
        # `grep`, and `for f in a b; do sbatch --parsable "$f"; done` arms.
        w="${seg%%[[:space:]]*}"
        while :; do
            case "$w" in
                do|then|else|if|while|until|'{'|'!'|time|nohup|env|nice|stdbuf|timeout) ;;
                *) break ;;
            esac
            seg="${seg#"$w"}"; seg="${seg#"${seg%%[![:space:]]*}"}"
            while [[ "$seg" =~ ^(-[^[:space:]]*|[0-9]+[smhd]?|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)([[:space:]]+(.*))?$ ]]; do
                seg="${BASH_REMATCH[3]}"
            done
            w="${seg%%[[:space:]]*}"
        done
        case "$w" in
            ''|sbatch|cd|export|module|ml|source|.|set|umask|true|:|tee|done|fi|'}'|esac) ;;
            for) ;;   # the loop HEADER `for x in …` prints nothing; its body is judged per segment
            *) return 1 ;;
        esac
    # FD REDIRECTIONS FIRST (ncbundle17-sk on PR 1745): `2>&1`, `>&2` and
    # `&>`/`&>>` carry an `&` that is not a separator; split on it and
    # `sbatch --parsable j.sh 2>&1`, the commonest idiom there is, left a
    # segment `1` and was distrusted.
    done < <(printf '%s\n' "$1" \
                | sed -E 's/[0-9]*[<>]&[0-9-]+//g; s/&>>?/>/g' \
                | sed -E 's/(&&|\|\||[;|&])/\n/g')
    return 0
}
# _slurm_id_ok <id> — the job-id predicate from the PROBE file, loaded lazily
# (only a Slurm row ever asks) from this hook's own tree, so it holds without
# NEXUS_ROOT. If the file cannot be loaded every id is REFUSED: the failure
# direction is a `syn-` wait plus a loud notice, never an unvalidated watch.
_slurm_pred=""   # "" = not loaded yet, 1 = loaded, 0 = unavailable
_slurm_id_ok() {
    if [[ -z "$_slurm_pred" ]]; then
        _slurm_pred=0
        local _hd
        _hd=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || _hd=""
        # shellcheck disable=SC1090,SC1091
        if [[ -n "$_hd" ]] && . "$_hd/../longjob-probes.d/slurm.sh" >/dev/null 2>&1 \
            && declare -F lj_slurm_jobid_valid >/dev/null 2>&1; then
            _slurm_pred=1
        fi
    fi
    [[ "$_slurm_pred" == 1 ]] && lj_slurm_jobid_valid "$1"
}

# THE FIELD SEPARATOR IS NOT A LIMIT ON THE REGEX LANGUAGE
# (your-org/nexus-code#1269). `|` is this file format's field separator, so a
# row carrying a literal `|` is SHREDDED by the split below: `cmd_re` becomes a
# fragment, the row matches nothing, and a detector row is silently disabled.
# That is a real hazard and the conf's parse assertion still forbids a literal
# `|` — but it was also being read as "this detector cannot express `|`", which
# is a different and false claim. It cost the `after ||` and `after a pipe`
# launch positions, and it forced one row per alternation branch everywhere
# else, which is what kept the row count near the hot-path budget.
#
# `\x7c` is decoded to a literal `|` AFTER the split. POSIX ERE has no `\x`
# escape, so the token cannot collide with anything a row could legitimately
# mean, and the row still carries no literal `|` — the parse assertion is
# unaffected. Both a `|` MATCHED AS A CHARACTER (a pipeline separator) and a
# `|` MEANING ALTERNATION are now expressible.
_ESC_PIPE='\x7c'
while IFS='|' read -r kind cmd_re id_re desc; do
    # Skip blank and comment lines.
    [[ -z "${kind// /}" ]] && continue
    case "$kind" in
        '#'*) continue ;;
    esac
    cmd_re=${cmd_re//"$_ESC_PIPE"/|}
    id_re=${id_re//"$_ESC_PIPE"/|}
    desc=${desc//"$_ESC_PIPE"/|}
    [[ -n "$cmd_re" ]] || continue
    # Match command. Bash =~ uses POSIX ERE.
    #
    # PER LINE, not per string (your-org/nexus-code#948). Bash's `=~`
    # anchors `^` to the whole subject, so a position-anchored row is
    # BLIND to a launch on line 2 of a multi-line command:
    #
    #     cd /tmp\nsrun --no-block ./j.sh   →  [[ =~ ]] no match
    #                                          grep -E   MATCH on line 2
    #
    # Multi-line `Bash` tool calls are a routine agent shape, so that
    # blind spot covers a large share of real launches. Testing each
    # LINE recovers them with no change to any pattern — the defect was
    # never in the regexes. Found because a third matcher (`grep -E`,
    # a different engine with line semantics) DISAGREED with the two
    # that shared bash's; agreement between two matchers that share an
    # engine cannot surface this.
    _line_hit=0
    while IFS= read -r _cmd_line || [[ -n "$_cmd_line" ]]; do
        if [[ "$_cmd_line" =~ $cmd_re ]]; then _line_hit=1; break; fi
    done <<< "$command_scan"
    if (( _line_hit )); then
        matched_kind="$kind"
        matched_desc="$desc"
        # Extract id from stdout if id_regex was provided. The
        # first capture group is the id. Otherwise synthesize a
        # short stable id from sha1(command_str)[0:12] so dismissal
        # by (kind, id) remains feasible.
        # PER LINE here too, and for a second reason beyond the one above:
        # bash's `=~` yields only the FIRST match of a whole-string subject, so
        # even an explicit loop over `BASH_REMATCH` cannot reach ids 2..N. Each
        # `Submitted batch job <id>` is on its own line, so testing lines is
        # what makes them all reachable.
        #
        # A BARE-NUMBER ID ROW INSIDE `$(…)` READS NOTHING
        # (your-org/nexus-code#1727). The `--parsable` rows' id field accepts
        # ANY stdout line that is just an integer. When the matched `sbatch`
        # sits inside a command substitution, its stdout went into the
        # VARIABLE, so every bare integer the tool call printed came from
        # something else — `jid=$(sbatch --parsable j.sh); echo $?` prints `0`,
        # and that `0` became a job id. "Is this row's id field a bare-number
        # shape?" is asked of the row itself (does it match `12345`?), so no
        # row is named here. The cost is declared: `jid=$(sbatch --parsable
        # …); echo $jid` prints the REAL id and it is not read either — that
        # call falls to the `syn-` wait and the NOT-ARMED notice below, which
        # names the one command that arms it. A wrong id is strictly worse:
        # `sacct` answers about ANOTHER job.
        _id_distrust=0
        if [[ -n "$id_re" ]] && [[ "12345" =~ $id_re ]]; then
            if [[ "$command_scan" =~ $_CMDSUBST_SBATCH_ERE ]]; then
                _id_distrust=1
            elif ! _parsable_call_is_sbatch_only "$command_scan"; then
                _id_distrust=2
            fi
        fi
        if [[ -n "$id_re" ]] && [[ -n "$stdout_str" ]] && (( _id_distrust == 0 )); then
            while IFS= read -r _out_line || [[ -n "$_out_line" ]]; do
                if [[ "$_out_line" =~ $id_re ]]; then
                    _cand="${BASH_REMATCH[1]}"
                    # A Slurm row's id must be a Slurm job id — the ONE shape,
                    # shared with the probe and `longjob-watch.sh add`
                    # (your-org/nexus-code#1727). A rejected id is not recorded
                    # as a wait either: the orphan-async resolver would ask
                    # `sacct` about it just as the watch did.
                    case "$kind" in
                        slurm|slurm-srun-async)
                            if ! _slurm_id_ok "$_cand"; then
                                _rejected_ids+=("$_cand"); continue
                            fi ;;
                    esac
                    matched_ids+=("$_cand")
                fi
            done <<< "$stdout_str"
        fi
        if (( ${#matched_ids[@]} == 0 )); then
            # No id in stdout — a `nohup … &`, or a launcher whose success line
            # this row cannot parse. Synthesize a stable id from the command so
            # `declare-no-wait.sh <kind> <id>` still has something to key on.
            # It is deliberately PREFIXED `syn-`, and that prefix is now load
            # bearing rather than cosmetic: the wake loop's resolver checks it
            # FIRST and reports `unresolvable` — "the launcher retained no
            # handle" — instead of rounding an unlookuppable id to "finished".
            local_syn=""
            if command -v sha1sum >/dev/null 2>&1; then
                local_syn=$(printf '%s' "$command_str" \
                    | sha1sum 2>/dev/null | cut -c1-12)
            fi
            [[ -n "$local_syn" ]] || local_syn="$(date +%s)"
            matched_ids=("syn-${local_syn}")
        fi
        break
    fi
done < "$pattern_file"

# No match → no work. Fast path for the common case of a
# non-launching Bash call (cd, ls, grep, …).
[[ -n "$matched_kind" ]] || exit 0
(( ${#matched_ids[@]} > 0 )) || exit 0

# Read existing heartbeat once, then check dismissed_waits BEFORE
# mutating. Saves a write when (kind, id) was already dismissed.
existing=$(read_existing)

if [[ "$existing" == '{}' ]]; then
    now=$(date +%s)
    existing=$(jq -nc \
        --arg window "$window" \
        --argjson now "$now" \
        '{window: $window, last_activity: $now, external_waits: [], dismissed_waits: []}')
fi

# Idempotent insert, one entry PER ID: drop any prior row with the same
# (kind, id), then append. Workers often re-submit the same job during a
# retry; we want the latest desc and a single entry, not a stack of
# duplicates. A (kind, id) already in `dismissed_waits` is skipped — the
# worker declared it fire-and-forget — and skipping is PER ID, so dismissing
# one job of a grid does not dismiss the other fourteen.
ids_json=$(printf '%s\n' "${matched_ids[@]}" | jq -Rc '[., inputs]' 2>/dev/null) \
    || ids_json=$(printf '%s\n' "${matched_ids[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))') \
    || exit 0
[[ -n "$ids_json" ]] || exit 0

updated=$(printf '%s' "$existing" | jq -c \
    --arg k "$matched_kind" \
    --arg d "$matched_desc" \
    --arg l "$launcher" \
    --argjson ids "$ids_json" \
    '. as $hb
     | ($ids | map(select(. as $i | ($hb.dismissed_waits // [])
                                    | map(select(.kind == $k and .id == $i)) | length == 0)))
       as $fresh
     | .external_waits = (
        ((.external_waits // []) | map(select(.kind != $k or (.id as $x | $fresh | index($x) | not))))
        + ($fresh | map({kind: $k, id: ., desc: $d} + (if $l == "" then {} else {launcher: $l} end)))
    )') || exit 0

tmp="$hb_file.$$.tmp"
printf '%s\n' "$updated" > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }
mv -f "$tmp" "$hb_file" 2>/dev/null || rm -f "$tmp"

# ---- auto-arm a longjob-watch for every detected Slurm launch (#1535) -------
# The wake nobody remembers to arm is no wake, so a detected `sbatch` /
# `srun --no-block` gets a watch WITHOUT a second command: the dispatcher
# (monitor/longjob-watch.sh) then delivers ONE task notification when the job
# reaches any terminal state. Gated by monitor.longjob.auto_watch_launches
# (env MONITOR_LONGJOB_AUTO_WATCH, default true) — its own knob. A job the
# worker dismissed via declare-no-wait.sh is not in $fresh and gets no watch.
# `--no-declare`: this hook already declared the `slurm <id>` wait above, and
# the dispatcher removes that entry when the watch retires. `--no-first-probe`:
# this is claude's PostToolUse hot path; no synchronous `sacct` here.
#
# NEVER SILENT WHEN NOTHING WAS ARMED (your-org/nexus-code#1727). This section
# used to discard every failure (`>/dev/null 2>&1 || true`) and say nothing
# when no id was parsed at all, so `jid=$(sbatch --parsable …)` — the most
# common submission idiom there is — left the worker believing the job was
# watched while nothing was. Whenever a Slurm launch matched and a REAL watch
# was not armed for it (no id in the output, an id the predicate refused, a
# bare-number id distrusted inside `$(…)`, or `add` returning non-zero —
# which includes add's own `dispatcher: NOT ARMED` rc 3), the hook prints ONE
# PostToolUse `additionalContext` naming why and the command that arms it — the
# same JSON form bash-footgun-guard.sh uses. It never blocks the call: rc is
# always 0, and the ARMED case prints nothing. A DISMISSED id stays silent: the
# worker said so on purpose.
_lj_auto="${MONITOR_LONGJOB_AUTO_WATCH:-}"
if [[ -z "$_lj_auto" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
    _lj_auto=$("$NEXUS_ROOT/config/load.sh" monitor.longjob.auto_watch_launches true 2>/dev/null) || _lj_auto=true
fi
case "${_lj_auto:-true}" in 1|true|yes|on) ;; *) exit 0 ;; esac
case "$matched_kind" in
    slurm|slurm-srun-async) ;;
    *) exit 0 ;;
esac
_na=()   # one reason per launch that got NO real watch
_grp_why=(); _grp_ids=()
_na_group() {   # <reason> <id> — file <id> under <reason>, one entry per distinct reason
    local i
    for i in "${!_grp_why[@]}"; do
        if [[ "${_grp_why[i]}" == "$1" ]]; then _grp_ids[i]+="$2 "; return 0; fi
    done
    _grp_why+=("$1"); _grp_ids+=("$2 ")
}
_fresh_ids=$(printf '%s' "$updated" | jq -r --arg k "$matched_kind" '.external_waits[] | select(.kind == $k) | .id' 2>/dev/null) || _fresh_ids=""
_lj="${NEXUS_ROOT:-}/monitor/longjob-watch.sh"
_lj_ok=1
[[ -n "${NEXUS_ROOT:-}" && -x "$_lj" ]] || _lj_ok=0
# The SESSION KEY comes from the PAYLOAD's `session_id` — the field claude
# itself supplies to every hook — not from this process's env. A suite that
# exported CLAUDE_CODE_SESSION_ID itself could only prove the key it supplied
# (skeptic, refuting its own attack: the hook env carries it too, via the
# host's child-env builder, but the payload is the documented one).
_lj_sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || _lj_sid=""
if (( ${#_rejected_ids[@]} > 0 )); then
    _na+=("refused job id(s) $(printf '%s ' "${_rejected_ids[@]}")— not a Slurm job id (job id 0 does not exist; 'sacct -j 0' answers about OTHER jobs)")
fi
for _jid in "${matched_ids[@]}"; do
    # Only THIS launch's ids that are still waits: a dismissed one is skipped,
    # silently and on purpose.
    grep -qxF -- "$_jid" <<<"$_fresh_ids" || continue
    if [[ "$_jid" == syn-* ]]; then
        if (( _id_distrust == 1 )); then
            _na+=("the sbatch ran inside \$(…) or backticks, so its stdout went into the variable and no bare number in this output can be trusted as its job id")
        elif (( _id_distrust == 2 )); then
            _na+=("this call ran other commands beside sbatch --parsable, so a bare number in its output may not be the job id (e.g. a grep -c count)")
        elif (( ${#_rejected_ids[@]} > 0 )); then
            :   # the refused id(s) above are the reason; saying "none read" too would contradict it
        else
            _na+=("no job id could be read from this call's output")
        fi
        continue
    fi
    if ! _slurm_id_ok "$_jid"; then
        _na+=("'$_jid' is not a Slurm job id (or the job-id predicate could not be loaded)")
        continue
    fi
    if (( _lj_ok == 0 )); then
        _na_group "monitor/longjob-watch.sh not found (NEXUS_ROOT unset or not executable), so nothing can watch it" "$_jid"
        continue
    fi
    _add_out=$(NEXUS_STATE_DIR="$state_dir" NEXUS_WORKER_WINDOW="$window" NEXUS_LONGJOB_SESSION_ID="$_lj_sid" \
        "$_lj" add "slurm:$_jid" --id "auto-slurm-$_jid" --desc "${matched_desc:-sbatch} (auto-watched by async-launch-detect)" \
        --no-declare --no-first-probe 2>&1 </dev/null)
    _add_rc=$?
    if (( _add_rc != 0 )); then
        # A re-submission of the SAME id (a retry) finds its watch already
        # recorded: that watch exists, so this call armed nothing NEW and
        # lost nothing either. Every other refusal is reported.
        [[ "$_add_out" == *"watch auto-slurm-$_jid already exists"* ]] && continue
        # add's own verdict line, else its last line (a `die` message).
        _why=$(printf '%s\n' "$_add_out" | grep -m1 -E '^dispatcher:|^longjob-watch:' 2>/dev/null) || _why=""
        [[ -n "$_why" ]] || _why=$(printf '%s\n' "$_add_out" | tail -n 1)
        _na_group "'longjob-watch.sh add' rc=$_add_rc: ${_why:0:300}" "$_jid"
    fi
done
# Ids sharing one reason are named ONCE with that reason — a 15-job grid under
# an unarmed dispatcher is one sentence, not fifteen copies of it.
for _gi in "${!_grp_why[@]}"; do
    _na+=("job(s) ${_grp_ids[_gi]% }: ${_grp_why[_gi]}")
done
if (( ${#_na[@]} > 0 )); then
    _msg="longjob NOT ARMED for this Slurm submission (your-org/nexus-code#1727) — no watch will wake you when it ends: $(printf '%s; ' "${_na[@]}")"
    _msg+="for each job, run: ng longjob add slurm:<id> (the REAL id — sbatch's output or squeue --me), and check it says ARMED; if add itself says NOT ARMED, use the fallback it prints."
    jq -nc --arg m "${_msg:0:4000}" \
        '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$m}}' \
        2>/dev/null || true
fi
exit 0
