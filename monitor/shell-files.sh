#!/usr/bin/env bash
# monitor/shell-files.sh — ONE definition of "which files under this repo are
# shell (or, more broadly, script) files", DERIVED from each file rather than
# listed (your-org/nexus-code#792).
#
# ---------------------------------------------------------------------------
# WHY THIS FILE EXISTS
# ---------------------------------------------------------------------------
#
# `monitor/` contains executable shell files with NO `.sh` extension — `ng`
# (the largest shell file in the repo and the most-invoked entry point),
# `ghwrap/gh`, `pipwrap/pip`, `notifywrap/sandbox-notify`, `client/nexus-*`,
# `git-https-setup` — and four zsh startup files whose names begin with a dot
# and end in nothing (`shellenv/.zshenv`, `.zshrc`, `.zprofile`, `.zlogin`).
# Every enumerator that globbed the `*.sh` family was blind to all of them.
#
# Two of those enumerators are the KILL GUARDS (`cc-harness/lint-no-mass-kill.sh`,
# `cc-harness/lint-no-tmux-server-kill.sh`). Ending the tmux server ends the
# session bwrap holds open, so it takes down the watcher, every worker and every
# registered service at once, and the operator cannot restart the nexus
# (`#644`: five tear-downs in 33 minutes). A kill-scanner that cannot read
# `monitor/ng` is a hole in the one guard whose failure is unrecoverable.
#
# ---------------------------------------------------------------------------
# LIST VS DERIVATION — the actual point
# ---------------------------------------------------------------------------
#
# The in-tree "fix" that prompted `#792` was
# `find … \( -name '*.sh' -o -name 'ng' \)`. That is a ONE-ELEMENT ALLOWLIST.
# It closed the single node its author needed and stayed blind to the other
# ten, and it has the property `#770` gap 3 was filed about: **a list rots, a
# derivation does not.** Copying that pattern into the kill guards would have
# written the same defect with a longer list.
#
# The test this file is built to pass is therefore not "does it see `ng` today"
# but: **does a NINTH extensionless executable added tomorrow get covered
# without anybody remembering?** For arms 1 and 2 below the answer is yes,
# automatically, and `test-shell-files.sh` plants exactly that file and proves
# it. Arm 3 is the one honest exception and is argued for on its own terms.
#
# ---------------------------------------------------------------------------
# THE DERIVATION — three arms, and why the third is allowed to be a list
# ---------------------------------------------------------------------------
#
#   1. EXTENSION — `.sh` / `.bash` / `.zsh` / `.ksh`. Not redundant with arm 2:
#      a SOURCED library is not executable and frequently carries no shebang
#      at all (`watcher/_lib.sh`, `cc-harness/_lib.sh`, this file's own callers'
#      helpers). Dropping arm 1 would lose the majority of the corpus.
#
#   2. SHEBANG — the first line is `#!` and the interpreter it names (after
#      resolving `env`, and skipping `env`'s own `-S`/`-i`/`VAR=` arguments) has
#      a basename in the shell vocabulary. This is the arm that makes the
#      enumeration self-maintaining: it is what actually DEFINES "this file is
#      run by a shell", it is a property of the file rather than of a registry,
#      and a new extensionless executable is covered the moment it is written,
#      because a file without a shebang is not an executable script in the
#      first place.
#
#   3. SHELL STARTUP-FILE NAME — `.zshenv`, `.bashrc`, `.profile`, and the rest
#      of that family. These carry no extension AND no shebang, because they are
#      never executed: the shell sources them by NAME. Arms 1 and 2 cannot
#      reach them even in principle.
#
#      This arm IS a list, so it owes an argument. The argument is that its
#      vocabulary is fixed by the SHELLS — bash's and zsh's startup sequences
#      are documented, closed sets that this repo does not get a vote in — not
#      by what files this repo happens to contain. That is a categorically
#      different object from `-o -name 'ng'`, which enumerated one repo's
#      current inventory. The failure mode of a rotting list is "we added a file
#      and forgot"; that cannot happen here, because adding a file cannot add a
#      startup-file NAME. `test-shell-files.sh` pins the vocabulary so growing
#      it is a deliberate, reviewed edit.
#
# ---------------------------------------------------------------------------
# COVERAGE BOUNDARY (on the axis the MECHANISM varies on, stated so it can be
# disagreed with — and pinned as data by `test-shell-files.sh`, not left here
# as prose, because prose cannot be made to fail):
#
#   Membership is decided from a file's NAME and its FIRST LINE. So this
#   correctly classifies a file whose shell-ness is declared. It CANNOT
#   classify shell-ness that is declared somewhere else:
#
#     * a file executed as `bash somefile` with no shebang and no shell name —
#       shell-ness lives in the CALLER, not the file. Errs toward EXCLUDING.
#     * a shebang naming a wrapper that in turn runs a shell
#       (`#!/usr/bin/env my-runner`). Errs toward EXCLUDING.
#     * shell embedded in another language (a heredoc in a `.py`, a `system()`
#       in a `.pl`). Out of scope by construction — `shf_class` reports the
#       HOST language, and the `script` class exists so a text-regex lint can
#       still scan those files.
#     * a file whose first line is not its shebang (there is no such thing —
#       the kernel requires byte 0).
#     * an interpreter outside the declared vocabulary — `#!/usr/bin/env fish`,
#       `nu`, `elvish`. Errs toward EXCLUDING, and deliberately: the consumers
#       that matter PARSE bash/POSIX shell syntax, so classifying a fish script
#       as `shell` would feed a scanner a grammar it does not implement. Zero
#       occurrences on this tree. If one appears, the question to answer is
#       whether the scanner can read it, not whether to widen the list.
#
#   All three reachable gaps err toward excluding, which is the UNSAFE
#   direction for a guard, so they are named here rather than left for the next
#   skeptic. Measured on this tree 2026-08-07: zero occurrences of any of them,
#   and `test-shell-files.sh` RE-MEASURES the first against the live tree on
#   every CI run — a count of executable-but-unclassified files, not a fixture —
#   so this paragraph's number cannot quietly go stale.
#
#   That live count is here because the sentence was false when first written
#   (`#799` skeptic, F-3): it promised a re-measurement and pointed at an
#   assertion that only exercised the CLASSIFIER on a planted fixture, which is
#   the definition of the gap rather than a count of its occurrences. A prose
#   promise about a check that does not exist, in the file arguing prose cannot
#   be made to fail. The claim was true — 0 of 514, verified independently —
#   which is exactly what makes the missing check easy to not notice.
#
# ---------------------------------------------------------------------------
# NON-VACUITY — the property a shared enumerator most needs
#
# An enumerator broken into finding NOTHING makes every consumer report a clean
# sweep. That is the dominant defect class in this repo (silence read as
# absence), and it is why `shf_require_floor` exists and why every consumer
# calls it. A floor is the right shape here precisely because it does NOT rot
# in the direction that matters: adding files never trips it, so nobody is ever
# tempted to bump it reflexively.
#
# ---------------------------------------------------------------------------
# Usage — source it, or run it:
#
#   . monitor/shell-files.sh
#   shf_class <path>                     -> shell|python|perl|awk|"" (rc 1)
#   shf_is_shell <path>                  -> rc 0 if arm 1/2/3 matches
#   shf_is_script <path>                 -> rc 0 if shell, python or perl
#   shf_find0 <root> [shell|script|all]  -> NUL-separated paths
#   shf_count <root> [class]             -> how many
#   shf_require_floor <root> <class> <min> <label>   -> rc 1 + stderr if short
#
#   bash monitor/shell-files.sh [--class shell|script|all] [root]   # list them
#   bash monitor/shell-files.sh --classify <path>                   # one file
#   bash monitor/shell-files.sh --extensionless [root]  # the #792 population

# Sourced by lints and by test suites; must not impose its own shell options on
# a caller (that is your-org/nexus-code#721's leak class, gated by
# watcher/test-ambient-shell-option-scope.sh P2). It therefore sets none.

# Interpreter basenames, by class. Kept as three flat strings rather than
# associative arrays so this file is sourceable from bash 3.2-era callers.
_SHF_SHELL_INTERP=' sh bash zsh ksh ksh93 dash ash mksh '
_SHF_PY_INTERP=' python python2 python3 '
_SHF_PERL_INTERP=' perl '
_SHF_AWK_INTERP=' awk gawk mawk nawk '

# Arm 3. Fixed by the SHELLS' documented startup sequences, not by this repo's
# inventory — see the header. Pinned by test-shell-files.sh.
_SHF_STARTUP_NAMES=' .zshenv .zshrc .zprofile .zlogin .zlogout .bashrc .bash_profile .bash_login .bash_logout .profile .kshrc .shrc .shinit '

# Directories never worth descending into. `.state` is runtime scratch that can
# hold thousands of fetched assets and log files; it does not exist in a CI
# checkout but does locally, and reading a first line from each is the
# difference between a lint that runs and one nobody waits for.
#
# A real ARRAY, not a space-separated string, unlike the vocabularies above
# which are only ever `case`-matched. This one is iterated, and zsh does not
# word-split an unquoted parameter — `for d in $STRING` would run ONCE with the
# whole string as the pattern, prune nothing, and descend into `.state` with no
# error. That is a workspace-wide trap and it costs nothing to be immune to it.
_SHF_PRUNE_DIRS=( .git node_modules .state .venv __pycache__ )

# The interpreter a shebang names, reduced to a basename. Empty (rc 1) when the
# file has no shebang.
#
# `read -n 200` rather than `head -c 200`: this is called once per file over a
# ~500-file tree by several consumers, and a subprocess apiece is what turned a
# sibling classifier into a 26-second run (early-exit-readers.sh:113). `-n`
# stops at the first newline OR 200 chars, so a binary file with no newline
# cannot make this read a gigabyte.
shf_interpreter() {   # <path>
    local first='' word rest
    IFS= read -r -n 200 first < "$1" 2>/dev/null
    case "$first" in '#!'*) ;; *) return 1 ;; esac
    first=${first#'#!'}
    # Strip a leading CR so a CRLF file does not yield an interpreter of
    # `bash<CR>`, which would match nothing and silently exclude the file.
    first=${first%$'\r'}
    # shellcheck disable=SC2086
    set -- $first
    (( $# )) || return 1
    word=${1##*/}
    if [[ "$word" == env ]]; then
        shift
        # `env` may carry its own options and VAR=value assignments before the
        # command. Skip them; `#!/usr/bin/env -S bash -e` is the shape that
        # matters and it is why this is a loop rather than a single shift.
        while (( $# )); do
            case "$1" in
                -*|*=*) shift ;;
                *)      break ;;
            esac
        done
        (( $# )) || return 1
        word=${1##*/}
    fi
    [[ -n "$word" ]] || return 1
    printf '%s' "$word"
}

# The class of one file: shell | python | perl | awk | "" (rc 1 for none).
shf_class() {   # <path>
    local p="$1" base interp
    [[ -f "$p" ]] || return 1
    base=${p##*/}

    # Arm 0 — TRANSIENT JUNK, excluded before anything else.
    #
    # An extension glob got this for free: `foo.sh~` and `.nfs0000000782…` do
    # not match `*.sh`. A shebang derivation does NOT, because these files are
    # byte-copies of real shell files and carry a real shebang. That difference
    # bit immediately: an NFS silly-rename artifact (created when a file is
    # unlinked while another process holds it open) entered the population
    # mid-run and made `aso-unresolved-sources.manifest` disagree with itself
    # between two invocations seconds apart.
    #
    # A manifest keyed on the worktree must not move because of an editor
    # backup or a stale NFS handle. Nobody maintains these files; they are not
    # part of anybody's answer to "what shell code is in this repo".
    case "$base" in
        .nfs????????*|*~|.#*|*.orig|*.rej|*.bak|*.swp|*.tmp) return 1 ;;
    esac

    # Arm 1 — extension.
    case "$base" in
        *.sh|*.bash|*.zsh|*.ksh) printf 'shell'; return 0 ;;
        *.py)                    printf 'python'; return 0 ;;
        *.pl|*.pm)               printf 'perl';   return 0 ;;
        *.awk)                   printf 'awk';    return 0 ;;
    esac

    # Arm 3 — a shell startup file, sourced by NAME and so carrying neither an
    # extension nor a shebang. Checked before arm 2 only because it is a cheap
    # string test; the two cannot both match.
    case "$_SHF_STARTUP_NAMES" in
        *" $base "*) printf 'shell'; return 0 ;;
    esac

    # Arm 2 — shebang. The self-maintaining arm: this is what covers an
    # extensionless executable added tomorrow, with nobody remembering.
    interp=$(shf_interpreter "$p") || return 1
    case "$_SHF_SHELL_INTERP" in *" $interp "*) printf 'shell';  return 0 ;; esac
    case "$_SHF_PY_INTERP"    in *" $interp "*) printf 'python'; return 0 ;; esac
    case "$_SHF_PERL_INTERP"  in *" $interp "*) printf 'perl';   return 0 ;; esac
    case "$_SHF_AWK_INTERP"   in *" $interp "*) printf 'awk';    return 0 ;; esac
    return 1
}

shf_is_shell()  { [[ "$(shf_class "$1")" == shell ]]; }

# Any interpreted script. The broader class exists for text-regex lints
# (`lint-no-mass-kill.sh`) whose ban is language-independent — a `killall` is a
# `killall` in perl too — as distinct from scanners that parse shell syntax.
shf_is_script() {
    case "$(shf_class "$1")" in shell|python|perl) return 0 ;; *) return 1 ;; esac
}

# Whether a class string is wanted under a filter.
_shf_wanted() {   # <class> <filter>
    case "$2" in
        all)    [[ -n "$1" ]] ;;
        script) case "$1" in shell|python|perl) return 0 ;; *) return 1 ;; esac ;;
        *)      [[ "$1" == "$2" ]] ;;
    esac
}

# Every matching file under <root>, NUL-separated.
#
# NUL rather than newline because consumers feed this straight to `xargs -0` and
# `while read -d ''`, and a newline-separated list is a silent-truncation
# hazard the moment a path contains whitespace. Symlinks are excluded by
# `-type f` — `pipwrap/pip3` is a symlink to `pipwrap/pip` and scanning both
# would double-report every hit in it.
shf_find0() {   # <root> [class-filter=shell]
    local root="$1" filter="${2:-shell}" f cls d
    local -a prune=()
    for d in "${_SHF_PRUNE_DIRS[@]}"; do prune+=( -name "$d" -o ); done
    find "$root" \( "${prune[@]}" -false \) -prune -o -type f -print0 2>/dev/null \
      | while IFS= read -r -d '' f; do
            cls=$(shf_class "$f") || continue
            _shf_wanted "$cls" "$filter" && printf '%s\0' "$f"
        done
}

shf_count() {   # <root> [class-filter]
    shf_find0 "$1" "${2:-shell}" | tr -dc '\0' | wc -c | tr -d ' '
}

# NON-VACUITY. Every consumer calls this before trusting a clean result.
#
# The floor is checked against the REAL tree, never against a fixture root — a
# fixture legitimately holds two files. Consumers therefore pass their own root
# and their own minimum, and the minimum is set well below the true count so
# ordinary deletions never trip it: it is a broken-enumerator alarm, not an
# inventory.
shf_require_floor() {   # <root> <class-filter> <min> <label>
    local n; n=$(shf_count "$1" "$2")
    if (( n < $3 )); then
        {
            echo "$4: shell-file enumeration returned $n $2 files under $1,"
            echo "  below the floor of $3. An enumerator broken into finding nothing"
            echo "  makes every consumer report a CLEAN SWEEP — which is the failure"
            echo "  this floor exists to make loud (your-org/nexus-code#792)."
        } >&2
        return 1
    fi
    return 0
}

# --- CLI -------------------------------------------------------------------
# Guarded so sourcing does not run it. `${BASH_SOURCE[0]}` differs from `$0`
# exactly when this file is sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _shf_root=""; _shf_filter="shell"; _shf_mode="list"
    while (( $# )); do
        case "$1" in
            --class)          _shf_filter="$2"; shift 2 ;;
            --classify)       _shf_mode="classify"; _shf_root="$2"; shift 2 ;;
            --extensionless)  _shf_mode="extensionless"; shift ;;
            -h|--help)        sed -n '2,120p' "$0"; exit 0 ;;
            -*)               echo "unknown option: $1" >&2; exit 2 ;;
            *)                _shf_root="$1"; shift ;;
        esac
    done
    case "$_shf_mode" in
        classify)
            shf_class "$_shf_root" || { echo "(not a script)"; exit 1; }
            echo ;;
        extensionless)
            # The #792 population: shell files no `*.sh`-family glob can see.
            _shf_root="${_shf_root:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
            shf_find0 "$_shf_root" shell \
              | while IFS= read -r -d '' f; do
                    case "${f##*/}" in *.sh|*.bash|*.zsh|*.ksh) continue ;; esac
                    printf '%s\n' "$f"
                done | LC_ALL=C sort ;;
        *)
            _shf_root="${_shf_root:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
            shf_find0 "$_shf_root" "$_shf_filter" \
              | while IFS= read -r -d '' f; do printf '%s\n' "$f"; done \
              | LC_ALL=C sort ;;
    esac
fi
