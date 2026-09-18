#!/usr/bin/env bash
# _proc_argv.sh — is THIS process a `skeptic-channel.sh await <task>`? Decided
# by argv POSITION, never by substring (your-org/nexus-code#1426, #1183).
#
# A predicate keyed on a STRING cannot tell the THING from the DESCRIPTION of
# the thing: a `claude` process's argv IS its prompt, so a substring match over
# `/proc/<pid>/cmdline` accepts any agent whose brief merely MENTIONS the phrase
# — and `_await_claim_singleton` sends `kill -TERM` to whatever that predicate
# accepts. Here the question is asked of argv positions: after stripping
# leading VAR=value assignments and wrapper words (an interpreter with its
# options, `command`/`exec`/`nohup`/`setsid`/`time`, `timeout [opts] DURATION`),
# word0 must be `skeptic-channel.sh` (basename) and word1 `await`; a
# `<shell> [opts] -c '<list>'` is split at command boundaries and each command
# position is asked the same question. An `echo`/`grep`/prompt carries the
# phrase in an ARGUMENT position and never matches.
#
# ONE definition, shared. The idle probe's `n_await` recognition (W2-19,
# #1183) and the await lock's ownership check (#1426) must agree on what an
# await IS, or a waiter the probe counts is one the lock refuses to reap, and
# vice versa. The logic here is W2-19's, moved into a library both can source;
# `monitor/watcher/_idle_probe.sh` delegates to it.
#
#   proc_argv_skeptic_await_task <nul-separated-argv-file>   -> prints the task, rc 0 | rc 1
#   proc_words_are_skeptic_await <word>...                   -> prints the task, rc 0 | rc 1
#   proc_pid_is_skeptic_await <pid> <task>                   -> rc 0 iff that pid is an await for THAT task
#   proc_pid_is_skeptic_await_identity <pid> <task> <start>   -> …AND the same process that recorded <start>
#   proc_pid_starttime <pid>                                  -> /proc/<pid>/stat field 22 (identity beside the pid)
#   proc_argv_mask_heredocs <list>                            -> the -c list with heredoc BODIES removed

proc_words_are_skeptic_await() {
    local -a w=("$@")
    local guard=0 w0
    while (( ${#w[@]} > 0 && guard < 16 )); do
        guard=$(( guard + 1 ))
        w0="${w[0]}"; w0="${w0#[\'\"]}"; w0="${w0%[\'\"]}"
        case "$w0" in
            [A-Za-z_]*=*)
                w=("${w[@]:1}"); continue ;;
            bash|sh|zsh|dash|ksh|*/bash|*/sh|*/zsh|*/dash|*/ksh)
                # `bash -c '<list>'`: the list is ONE word — not this form.
                # Other interpreter options (`-x`, `-e`, `-o pipefail`) are
                # skipped; `-c` in any bundle (`-lc`, `-ec`) means the -c form.
                w=("${w[@]:1}")
                while (( ${#w[@]} > 0 )) && [[ "${w[0]}" == -* ]]; do
                    [[ "${w[0]}" == -[!-]*c* || "${w[0]}" == -c ]] && return 1
                    if [[ "${w[0]}" == -o ]]; then w=("${w[@]:2}"); else w=("${w[@]:1}"); fi
                done
                continue ;;
            command|exec|nohup|setsid|time|*/nohup|*/setsid)
                w=("${w[@]:1}"); continue ;;
            timeout|*/timeout)
                w=("${w[@]:1}")
                while (( ${#w[@]} > 0 )) && [[ "${w[0]}" == -* ]]; do
                    case "${w[0]}" in
                        -s|-k|--signal|--kill-after) w=("${w[@]:2}") ;;
                        *)                           w=("${w[@]:1}") ;;
                    esac
                done
                (( ${#w[@]} > 0 )) || return 1
                w=("${w[@]:1}")     # the DURATION
                continue ;;
        esac
        break
    done
    (( ${#w[@]} >= 2 )) || return 1
    local a0="${w[0]}" a1="${w[1]}" task="${w[2]:-}"
    a0="${a0#[\'\"]}"; a0="${a0%[\'\"]}"
    a1="${a1#[\'\"]}"; a1="${a1%[\'\"]}"
    [[ "$a0" == skeptic-channel.sh || "$a0" == */skeptic-channel.sh ]] || return 1
    [[ "$a1" == await ]] || return 1
    task="${task#[\'\"]}"; task="${task%[\'\"]}"
    [[ "$task" == -* ]] && task=""
    printf '%s' "$task"
    return 0
}

# proc_argv_mask_heredocs <list> — print <list> with every heredoc BODY removed
# (the `<<WORD` operator line is kept, so the command it belongs to still
# parses as a command position). Delimiter quoting (`<<'EOF'`, `<<"EOF"`,
# `<<-EOF`, `<<\EOF`) is stripped for the terminator match.
proc_argv_mask_heredocs() {
    local src="$1" line delim="" out="" in_body=0 rest d probe
    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( in_body )); then
            d="${line#"${line%%[![:space:]]*}"}"   # <<- allows leading tabs
            [[ "$d" == "$delim" ]] && in_body=0
            continue
        fi
        out+="$line"$'\n'
        # NOT EVERY `<<` OPENS A HEREDOC (your-org/nexus-code#1450). A herestring
        # `<<<"$x"` contains the two characters, and so does an arithmetic left
        # shift `$((a<<b))`; either used to start a "body" that no delimiter
        # ever closed, so every command after it in the list was masked — and a
        # REAL `skeptic-channel.sh await` below one was not recognised (a false
        # negative: nothing was reaped, and the idle probe under-counted). The
        # operator is matched on a COPY with those two spellings removed; the
        # heredoc delimiter is still read from the same copy.
        probe="${line//<<</ }"
        while [[ "$probe" == *'$(('*'))'* ]]; do
            probe="${probe%%\$((*}"" ${probe#*))}"
        done
        if [[ "$probe" == *'<<'* ]]; then
            rest="${probe#*<<}"; rest="${rest#-}"
            rest="${rest#"${rest%%[![:space:]]*}"}"
            rest="${rest#\\}"
            case "$rest" in
                \'*) rest="${rest#\'}"; delim="${rest%%\'*}" ;;
                \"*) rest="${rest#\"}"; delim="${rest%%\"*}" ;;
                *)   delim="${rest%%[[:space:];|&)]*}" ;;
            esac
            [[ -n "$delim" ]] && in_body=1
        fi
    done <<<"$src"
    printf '%s' "$out"
}

# proc_pid_starttime <pid> — the kernel start-time (field 22 of /proc/<pid>/stat,
# clock ticks since boot). With the pid it is the process's IDENTITY: a
# recycled pid carries a different value. Empty + rc 1 when unreadable.
proc_pid_starttime() {
    local pid="${1-}" line rest
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    line=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    [[ -n "$line" ]] || return 1
    rest=${line##*) }
    # $rest begins at field 3 (state), so start-time (22) is field 20 here.
    awk '{print $20}' <<<"$rest"
}

# proc_pid_is_skeptic_await_identity <pid> <task> <starttime> — rc 0 iff the
# pid is an await for THAT task AND is the SAME process that recorded
# <starttime>. An empty <starttime> is a record with no identity and is
# REFUSED: a pid alone is a name, not a thing (your-org/nexus-code#1426).
proc_pid_is_skeptic_await_identity() {
    local pid="${1-}" task="${2-}" want="${3-}" have
    [[ -n "$want" ]] || return 1
    have=$(proc_pid_starttime "$pid") || return 1
    [[ "$have" == "$want" ]] || return 1
    proc_pid_is_skeptic_await "$pid" "$task"
}

proc_argv_skeptic_await_task() {
    local f="$1"
    [[ -r "$f" ]] || return 1
    local -a av=()
    local w
    while IFS= read -r -d '' w; do av+=("$w"); done < "$f"
    (( ${#av[@]} > 0 )) || return 1
    # (a) direct invocation, possibly behind an interpreter/wrapper.
    if proc_words_are_skeptic_await "${av[@]}"; then return 0; fi
    # (b) `<shell> [opts] -c '<list>'`.
    local sh; sh=$(basename -- "${av[0]}")
    case "$sh" in bash|sh|zsh|dash|ksh) ;; *) return 1 ;; esac
    local i=1 have_c=0 opt
    while (( i < ${#av[@]} )); do
        opt="${av[i]}"
        [[ "$opt" == -* ]] || break
        if [[ "$opt" == -o ]]; then i=$(( i + 2 )); continue; fi
        i=$(( i + 1 ))
        if [[ "$opt" == -[!-]*c* || "$opt" == -c ]]; then have_c=1; break; fi
    done
    (( have_c == 1 && i < ${#av[@]} )) || return 1
    local list="${av[i]}"
    # HEREDOC BODIES ARE DATA, NOT COMMANDS (your-org/nexus-code#1426, the
    # W2-20 skeptic's plant): a `zsh -c` list whose heredoc writes a BRIEF
    # carrying "`monitor/skeptic-channel.sh await <task> …`" at line start was
    # split at the newline and the body line read as a command position. Mask
    # every `<<[-]WORD … WORD` body before splitting, so text destined for a
    # file is never asked whether it is an await. Unterminated heredoc ⇒ the
    # rest of the list is body.
    case "$list" in *'<<'*) list=$(proc_argv_mask_heredocs "$list") ;; esac
    # Command boundaries: newline ; & | && || ( ) { }. Every one of these ends
    # a simple command, so what follows is a fresh command position.
    list="${list//$'\n'/;}"
    list="${list//&&/;}"; list="${list//||/;}"; list="${list//|/;}"; list="${list//&/;}"
    list="${list//(/;}"; list="${list//)/;}"; list="${list//\{/;}"; list="${list//\}/;}"
    local -a segs=() ws=()
    IFS=';' read -r -a segs <<<"$list"
    local seg task=""
    for seg in ${segs[@]+"${segs[@]}"}; do
        ws=()
        IFS=$' \t' read -r -a ws <<<"$seg"
        (( ${#ws[@]} > 0 )) || continue
        if task=$(proc_words_are_skeptic_await "${ws[@]}"); then
            printf '%s' "$task"
            return 0
        fi
    done
    return 1
}

proc_pid_is_skeptic_await() {   # <pid> <task>
    local pid="${1-}" task="${2-}" got
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$task" ]] || return 1
    [[ -r "/proc/$pid/cmdline" ]] || return 1
    got=$(proc_argv_skeptic_await_task "/proc/$pid/cmdline") || return 1
    [[ "$got" == "$task" ]]
}
