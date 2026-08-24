#!/usr/bin/env bash
# spawn-shapes.sh — enumerate every `tmux new-window` call site in this repo and
# record, as a FACT, what each one leaves at the PANE ROOT.
#
# Run: bash monitor/watcher/spawn-shapes.sh [repo-root]
# Output: one TAB-separated row per call site, sorted:
#
#     <repo-relative-path>#<ordinal>\t<bare|command|indirect>\t<shell|agent|unknown>\t<sendkeys|no-sendkeys>\tline=<n>
#       (1) key                       (2) syntactic form      (3) PANE ROOT       (4) pairing     (5) INFO ONLY
#
# COLUMN 1 IS AN ORDINAL, NOT A LINE NUMBER, and that is load-bearing. Keyed on
# `<path>:<line>` — as the first draft was — every row in a file moves when
# anything above it is edited, so an unrelated change reddens the suite and the
# only practical response is to regenerate. A manifest that is regenerated
# reflexively is a rubber stamp, which is the exact failure these manifests
# exist to prevent (`early-exit-readers.manifest` says the same in its own
# header: "keyed on counts, not line numbers, so ordinary edits are silent").
# `#N` is the Nth `new-window` call site WITHIN that file, so it moves only when
# a call site is added or removed in that file — which is precisely when a human
# should look. Column 5 carries the current line for navigation and is
# deliberately NOT compared by the drift test.
#
# your-org/nexus-code#789.
#
# THE AXIS IS COLUMN 3, AND IT IS DELIBERATELY NOT COLUMN 2. Every `absent`
# decision in `monitor/pane-state.sh` reads the same two things: WHAT IS UNDER
# `pane_pid`, AND WHEN. What decides that is whether the pane's ROOT PROCESS is
# the agent itself or a shell that outlives it:
#
#   agent  the pane root IS the launcher/agent. tmux's `#{pane_dead}` flips to 1
#          the instant it exits, and pane-state.sh's ladder settles on that
#          first-party signal. `_respawn.sh:_respawn_spawn_window` is this.
#   shell  the pane root is a SHELL that outlives everything. `#{pane_dead}`
#          stays 0 forever, the agent arrives later as a DESCENDANT once the
#          shell has read the `send-keys` bytes, and every `absent` verdict has
#          to come from the process-tree and boot-grace arms instead.
#          `spawn-worker.sh` is this — every worker on the board.
#
# Column 2 (was a command argument passed?) is a PROPERTY OF THE SEARCH, and
# sorting on it gets the answer wrong in both directions: `new-window "exec sh"`
# passes a command and still leaves a shell at the root, while a bare
# `new-window` whose `default-command` names an agent would not. So column 2 is
# reported as a fact and column 3 is derived from what the command actually is.
#
# Column 4 records whether the same file also calls `send-keys`: a `shell`-root
# window with no send-keys is not a spawn at all (it is an empty window for a
# human), and the pairing is what makes it one.
#
# FACTS, NOT VERDICTS. This script reports the shape each call site creates; it
# does not decide whether that shape is modelled anywhere. The disposition lives
# in `spawn-shapes.manifest` alongside a reason, and
# `test-spawn-shape-manifest.sh` fails when the two disagree — AND fails when a
# production pane-root has no harness counterpart. So a NEW production spawn
# shape lands there unmodelled and RED rather than silently uncovered. That is
# the defect `#789` names: the boot window was not merely untested, it was
# untestable, and nothing anywhere said so.
#
# COVERAGE BOUNDARY: the population is "a non-comment line naming `new-window`,
# in a TRACKED, NON-SYMLINK, NON-MARKDOWN file", with shell line-continuations
# joined so a call split across lines is read whole. Each exclusion is
# load-bearing and each was chosen from an observed noise row, not guessed:
#   - symlinks: `./nexus` and `./watcher` both point at `monitor/watcher/
#     entry.sh`, so following them reports the SAME call site three times and
#     inflates every count taken from this output.
#   - markdown and data files (`*.manifest`, `*.tsv`): they DESCRIBE shapes and
#     cannot create a pane. Observed, not hypothetical — this scan's own
#     manifest names `new-window` in its reason column, and reading it back
#     manufactured three phantom call sites.
#   - continuations: `_harness.sh`'s worker-shape call carries its command five
#     physical lines below the `new-window` token. Read line-at-a-time it
#     classifies `bare`, which is the right SHAPE for the wrong REASON — and the
#     day someone changes that command the misreading stops being harmless.
#
# `indirect`/`unknown` are the honest arms for a call whose command cannot be
# read statically — a variable holding the invocation, a heredoc-generated call,
# a `printf` of a suggested command. They are NOT silently sorted into `bare`,
# which is the reading that would understate production's shape count.
#
# THE SCAN CANNOT TELL CODE FROM A STRING THAT LOOKS LIKE CODE. A diagnostic such
# as `echo "tmux new-window failed / returned no window id"` tokenises as a
# command-form call (`failed` is the first non-flag token), and
# `monitor/spawn-worker.sh:1410` is exactly that. Rather than guess with a
# quote-balance heuristic, such rows are emitted as facts and the manifest
# dispositions them `not-a-spawn`. That is the point of splitting facts from
# verdicts: a mis-parse becomes a reviewed row, never a silent omission.
#
# Explicitly OUTSIDE the boundary and not claimed about: a `new-window` reached
# through a wrapper whose own name does not contain `tmux`, one assembled from
# string fragments across separate statements, a pane root decided by a
# non-default `default-command`, and any call site in an untracked file.

set -uo pipefail

# your-org/nexus-code#803 — `--population` prints the file set this scan reads.
# Consumed BEFORE the positional root, because the root is `$1` here and an
# unshifted flag would silently be taken for a directory.
_ss_pop=0
if [[ "${1:-}" == --population ]]; then _ss_pop=1; shift; fi
REPO_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# The operator's interactive `grep` is a ugrep wrapper honouring .gitignore
# (your-org/nexus-code#618). Bind the real binary so this classifier cannot
# return a confident zero.
GREP=$(type -P grep 2>/dev/null) || GREP=/bin/grep

cd "$REPO_ROOT" || exit 2

# `git ls-files` (glob pathspecs), never `git ls-tree` (path PREFIXES — a glob
# there is a confident zero, your-org/nexus-code#770).
all_files=$(git ls-files -z 2>/dev/null | tr '\0' '\n')
if [[ -z "$all_files" ]]; then
    echo "spawn-shapes.sh: git ls-files returned nothing in $REPO_ROOT" >&2
    exit 2
fi

# `--population` answers HERE, with the WHOLE tracked set and not the
# `new-window`-mentioning subset below (your-org/nexus-code#803). The narrowing
# is a speed optimisation over files this scan reads; a file that greps clean
# today is exactly the file an edit can turn into a call site, so reporting the
# post-narrowing subset would under-select in the one direction that matters.
if (( _ss_pop )); then
    printf '%s\n' "$all_files"
    exit 0
fi

# Narrow to files that mention the token at all BEFORE line-reading any of them.
# Reading all 600 tracked files a line at a time costs 15 s; reading the ~50 that
# can possibly match costs under one. This runs in the per-PR fast band, where a
# 15 s static scan is a tax on every push.
#
# `xargs -0 grep`, NOT `xargs -0 command grep`: xargs execs a PROGRAM and
# `command` is a shell BUILTIN, so that form exits 127 having never run grep — a
# silent zero, i.e. `#618` reproduced inside its own remedy (`#707`). xargs does
# not go through the shell, so the operator's grep FUNCTION is never in play and
# no bypass is needed.
files=$(printf '%s\n' "$all_files" | tr '\n' '\0' \
    | xargs -0 grep -lI 'new-window' 2>/dev/null)
if [[ -z "$files" ]]; then
    # Not "no call sites" — this repo demonstrably has them. An empty result
    # here means the scan is blind, and a blind scan that prints nothing reads
    # downstream as a clean sweep.
    echo "spawn-shapes.sh: no file in $REPO_ROOT mentions new-window — refusing" >&2
    echo "                 to report an emptiness this scan cannot vouch for." >&2
    exit 3
fi

# Classify ONE `new-window` invocation's argument list.
#
# Prints "<form>\t<pane-root>".
#
# Walks the tokens after `new-window`, consuming tmux's option grammar, and
# reports whether a COMMAND argument survives and what it is. Options that take a
# value are enumerated from tmux(1)'s new-window synopsis; an unrecognised `-x`
# is treated as valueless, which is the conservative direction (it can only cause
# a value to be mistaken for a command, i.e. over-report `command`, never
# under-report it — and the manifest reviews every row anyway).
_classify_args() {
    local rest="$1" tok
    # Strip a trailing shell comment, then collapse continuations.
    rest="${rest//\\$'\n'/ }"
    case "$rest" in
        *'$('*|*'`'*) printf 'indirect\tunknown'; return 0 ;;
    esac
    local -a toks=()
    # `read -a` tokenisation: good enough for the option walk, and it must not
    # execute repo text the way `eval` would.
    read -r -a toks <<<"$rest"
    local i=0 n=${#toks[@]}
    while (( i < n )); do
        tok="${toks[$i]}"
        case "$tok" in
            -[tncFeS]|-[tncFeS]*=*)
                # Value-taking. `-t x` consumes the next token; `-t=x` does not.
                [[ "$tok" == *=* ]] || i=$(( i + 1 ))
                ;;
            -[a-zA-Z]*|'')
                : ;;   # valueless flag, a bundle of them, or padding
            ')'*|'||'*|'&&'*|';'*|'|'*|'&'*|'#'*|'>'*|'2>'*)
                # End of the invocation. Without this stop set the shell syntax
                # AFTER the call leaks in as a command: `spawn-worker.sh:1838`'s
                # `WID=$(tmux new-window … -c "$WORKDIR") || true` fed `||` to
                # the arm below and reported the repo's single most important
                # `bare` spawn as `command agent` — the exact inversion this
                # classifier exists to prevent, inside the classifier.
                break ;;
            *)
                # First non-flag token: the command. Strip one layer of quoting
                # and an `exec` prefix, then ask what it actually starts.
                local cmd="$tok"
                cmd="${cmd#[\"\']}"
                [[ "$cmd" == exec ]] && cmd="${toks[$(( i + 1 ))]:-}"
                cmd="${cmd#[\"\']}"
                cmd="${cmd%[\"\']}"
                case "$cmd" in
                    ''|*'$'*)   printf 'command\tunknown' ;;
                    sh|bash|zsh|dash|ksh|*/sh|*/bash|*/zsh|*/dash|*/ksh)
                                # A shell at the root: structurally the WORKER
                                # shape however it was spelled.
                                printf 'command\tshell' ;;
                    *)          printf 'command\tagent' ;;
                esac
                return 0 ;;
        esac
        i=$(( i + 1 ))
    done
    # No command: tmux execs `default-shell`.
    printf 'bare\tshell'
}

{
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        # A symlink resolves to a file already enumerated under its real path;
        # counting both reports one call site two or three times.
        [[ -L "$f" ]] && continue
        # Skip documentation, DATA FILES, binaries, and captured pane fixtures
        # (raw terminal bytes that may merely CONTAIN the words).
        #
        # `*.manifest` / `*.tsv` are excluded for the same reason as markdown and
        # it is not hypothetical: this scan's OWN manifest describes each call
        # site in prose ("Bare new-window, then send-keys the generated
        # launcher"), so once it was tracked the classifier read its reason
        # column back as three new unclassified call sites. A record ABOUT call
        # sites is not a call site.
        case "$f" in
            *.md|*.manifest|*.tsv|*.ansi|*.png|*.jpg|*.pdf) continue ;;
        esac
        sk=no-sendkeys
        "$GREP" -qI 'send-keys' "$f" 2>/dev/null && sk=sendkeys
        ordinal=0

        # Read the whole file once, joining continuations, so a call split
        # across physical lines is classified from its complete argument list
        # while still being REPORTED at the line the `new-window` token sits on.
        lineno=0
        pending=""
        pending_ln=0
        while IFS= read -r body || [[ -n "$body" ]]; do
            lineno=$(( lineno + 1 ))
            if [[ -n "$pending" ]]; then
                pending+=" $body"
            else
                case "${body#"${body%%[![:space:]]*}"}" in
                    '#'*) continue ;;     # comment: prose about a shape
                esac
                case "$body" in
                    *new-window*) pending="$body"; pending_ln=$lineno ;;
                    *) continue ;;
                esac
            fi
            # Still continued? keep accumulating.
            if [[ "$pending" == *'\' ]]; then
                pending="${pending%'\'}"
                continue
            fi
            joined="$pending"
            pending=""
            # Require a tmux-ish callee immediately before `new-window`.
            [[ "$joined" =~ tmux[^[:space:]]*[[:space:]]+new-window ]] || continue
            ordinal=$(( ordinal + 1 ))
            printf '%s#%s\t%s\t%s\tline=%s\n' "$f" "$ordinal" \
                "$(_classify_args "${joined#*new-window}")" "$sk" "$pending_ln"
        done < "$f"
    done <<< "$files"
} | sort
