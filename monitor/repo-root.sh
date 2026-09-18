#!/usr/bin/env bash
# monitor/repo-root.sh — "is <dir> the ROOT of its own git repository?"
#
# THE QUESTION THIS ANSWERS, AND WHY IT NEEDS A TOOL
# ==================================================
# `git -C <dir>` on a directory that is NOT itself a repository does not fail.
# Git walks UP and answers about the nearest enclosing repository — at rc 0,
# with nothing on stderr. In a nexus the nearest enclosing repository is always
# the nexus itself, because every analysis tree lives under `work/`. So a
# provenance probe over `work/` returns the NEXUS's HEAD for every un-versioned
# tree, identically, and reads as consistency (your-org/nexus-code#1196).
#
# The guard a careful author reaches for CERTIFIES THE WRONG THING:
#
#     git -C work/liver-coembed-cohort rev-parse --is-inside-work-tree  -> true
#
# truthfully, because it IS inside the nexus's work tree. Measured on `dev` @
# `50c36ef`: 57 of 881 directories under `work/` report the nexus's own HEAD as
# theirs, and `--is-inside-work-tree` says `true` for all 57.
#
# The same walk-up is a WRITE hazard one script over: `monitor/git-https-setup`
# wrote bot identity and the bot credential helper into the ENCLOSING
# repository's `.git/config` for a `$target` that was never a repository
# (your-org/nexus-code#1080).
#
#
# THE TWO PUBLISHED DISCRIMINATORS BOTH HAVE HOLES — MEASURED, git 2.17.1
# ======================================================================
# `#1196` names two forms and presents them as interchangeable:
#
#     [ "$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$d" && pwd -P)" ]
#     [ -z "$(git -C "$d" rev-parse --show-prefix 2>/dev/null)" ]
#
# They are not interchangeable, and neither is sufficient:
#
#   HOLE 1 — A LINKED WORKTREE PASSES BOTH, AND ITS `--local` CONFIG LANDS
#            SOMEWHERE ELSE. `git worktree add ../wt` gives `--show-toplevel` =
#            `<…>/wt` (self-rooted) and `--show-prefix` = empty, so both forms
#            say YES. But `--absolute-git-dir` is `<main>/.git/worktrees/wt`,
#            and `git -C wt config --local <k> <v>` was measured writing into
#            `<main>/.git/config` — 1 hit there, 0 in the worktree's own
#            config. For `#1080`'s hazard that is the defect surviving the fix.
#
#   HOLE 2 — THE TWO FORMS DISAGREE ON A BARE REPOSITORY, AND `--show-toplevel`
#            DISAGREES WITH ITSELF ACROSS GIT VERSIONS. For `bare.git`,
#            `--show-prefix` prints empty at rc 0, so the prefix form says YES.
#            The toplevel form says NO — but it says it in two different ways,
#            and that split is your-org/nexus-code#1257:
#
#                git <= 2.23.0   rc 0, output EMPTY
#                git >= 2.28.0   rc 128, "fatal: this operation must be run
#                                in a work tree"
#
#            Measured on all ten gits installed here (2.17.1, 2.23.0, 2.28.0,
#            2.32.0, 2.33.0, 2.36.0, 2.38.1, 2.41.0, 2.42.0, 2.45.1), fixture
#            and subject held constant. A bare repo IS its own repository, so
#            the toplevel form is wrong on every version; what changes is
#            whether its wrongness is a value or an error. Anything keying on
#            "the toplevel came back empty" is therefore DEAD on modern git,
#            which is what this file did until `#1257` — and this host's
#            default git is 2.17.1 while CI runs 2.55.0, so it was correct
#            exactly where it was authored and reviewed. `--absolute-git-dir`
#            plus `--is-inside-work-tree` are the version-stable pair; see the
#            gate probe in rr_classify.
#
#   HOLE 3 — AN INHERITED `GIT_DIR` FOOLS BOTH. With `GIT_DIR` and
#            `GIT_WORK_TREE` set in the environment, a plain non-repo directory
#            reports `--show-toplevel` EQUAL TO ITSELF and `--show-prefix`
#            EMPTY. Both forms say YES for a directory that is not a repository
#            at all. This is not exotic: **git sets `GIT_DIR` for every hook it
#            runs**, so anything invoked from a git hook inherits it.
#
# And `#1080`'s own suggested predicate (`gitdir == "$real/.git"`) survives
# hole 3 but acquires a FALSE NEGATIVE: it rejects a repository created with
# `git init --separate-git-dir`, whose git dir is legitimately elsewhere and
# whose `--local` config correctly lands in it. `monitor/upload-asset.sh`'s
# `_asset_tree_is_self_rooted` — the `#1077` precedent, and the reason that
# script is correct today — carries the same false negative.
#
# THE FORM THAT HAS NONE OF THE FOUR is toplevel-equality PLUS
# `--git-common-dir == --absolute-git-dir`. Measured: the two are EQUAL for a
# plain repo, for `--separate-git-dir`, and for a bare repo, and DIFFER only
# for a linked worktree — which is exactly the set we mean by "this git dir
# belongs to this work tree alone".
#
#
# THREE-VALUED ON PURPOSE
# =======================
# A two-valued predicate here is the bug again: a shell `until` loops on
# non-zero and a `while` on zero, so any caller reads one of them backwards,
# and "I could not tell" collapses into "no". That collapse is load-bearing —
# a newer git refusing a repo for DUBIOUS OWNERSHIP (`safe.directory`, git
# 2.35.2+) exits 128 on a directory that IS a repository root, and a
# two-valued caller records that as "not a repo" and proceeds. Measured
# stand-in for the class on this host's git 2.17.1: an unreadable directory
# gives rc 128 `fatal: cannot change to '<dir>': Permission denied`; an absent
# `git` gives rc 127. Neither is an answer.
#
#     exit 0  YES          — <dir> is the root of its own repository
#     exit 1  NO           — positively established (walk-up, subdir, linked
#                            worktree, nothing there at all)
#     exit 3  UNDETERMINED — could not look; NEITHER yes nor no
#     exit 2  usage
#
# In-process callers should read the globals `RR_VERDICT`, `RR_KIND`, `RR_TOP`,
# `RR_GITDIR`, `RR_REASON`, `RR_LINE`, which rr_classify sets on every call. Do NOT parse
# the line to recover them, and do not call rr_classify in a command
# substitution when you need them (a subshell discards them).
#
# stdout is one `key=value` line, always, on every code. Path-valued fields are
# `%q`-QUOTED so a path containing a space survives the round trip:
#
#     verdict=<yes|no|undetermined> kind=<…> top=<…> gitdir=<…> reason=<…>
#
# KINDS, and they are what a caller should branch on rather than re-deriving:
#
#     root              toplevel is <dir>, git dir belongs to it alone   -> yes
#     bare              <dir> IS a bare repository's root                -> yes
#     linked-worktree   self-rooted, but its git dir is the MAIN repo's  -> no
#     subdir            inside a repo, below its root                    -> no
#     gitdir-stub       inside a repo, below its root, AND <dir>/.git
#                       exists — the INTERRUPTED-CLONE signature that
#                       `[[ -d "$dir/.git" ]]` passes                    -> no
#     gitdir-itself     <dir> IS a git dir, not a work-tree root          -> no
#     inside-gitdir     <dir> is somewhere inside a git dir                -> no
#     none              no repository anywhere above <dir>               -> no
#     absent            <dir> does not exist                             -> no
#     unreadable        <dir> exists but cannot be entered               -> undetermined
#     git-unavailable   no usable `git`                                  -> undetermined
#     error             git failed for a reason that is not "not a repo" -> undetermined
#
# USAGE
#     monitor/repo-root.sh <dir>              # line on stdout, verdict as rc
#     monitor/repo-root.sh --quiet <dir>      # rc only
#     monitor/repo-root.sh --kind <dir>       # just the kind, on stdout
#     monitor/repo-root.sh --history <dir>    # READ-side question (see rr_has_own_history)
#     . monitor/repo-root.sh                  # sourced: rr_classify, rr_is_own_root
#
# rr_is_own_root <dir> is the boolean shorthand and it is SAFE ONLY where
# "undetermined" may be treated as "no" — i.e. for a READ that will be
# discarded. Never use it to gate a WRITE; branch on rr_classify's rc.

# ── the classifier ─────────────────────────────────────────────────────────
#
# ARM ORDER IS NOT LOAD-BEARING HERE, DELIBERATELY (your-org/nexus-code#1121).
# The facts are gathered first and the verdict is then decided by EQUALITY
# against two disjoint literal lists with a default-DENY (never `yes`) arm. No
# glob, no substring, no `index()` — so no input can match two arms and the
# "does a SAFE arm shadow a later DENY arm" question cannot arise. It would
# stop being true the day either list gained a pattern.

_RR_YES_KINDS='root bare'
_RR_NO_KINDS='linked-worktree subdir gitdir-stub inside-gitdir gitdir-itself none absent'

# rr_classify <dir> -> prints the key=value line; returns 0/1/3.
rr_classify() {
    local d="${1-}" real top gd common bare inwt kind reason out rc

    kind=''; reason=''; top=''; gd=''

    if [ -z "$d" ]; then
        printf 'verdict=undetermined kind=error top= gitdir= reason=no_directory_given\n'
        return 3
    fi

    # EXISTS-BUT-CANNOT-BE-ENTERED AND DOES-NOT-EXIST ARE DIFFERENT ANSWERS,
    # and the order of these tests is what tells them apart. The first draft
    # asked the PARENT whether it was searchable before asking whether `$d` was
    # a directory at all — so a mode-000 directory whose parent is perfectly
    # searchable answered `kind=absent verdict=no`, byte-identical to a path
    # that does not exist. A confident NO where the honest answer is "could not
    # look", and it made `_clone_drift_probe`'s `repo_root_undetermined` arm
    # UNREACHABLE for that input (your-org/nexus-code#1243 round 2).
    #
    # The discriminating question is `-d`, so it goes first. `stat` succeeding
    # on `$d` while `cd` fails is exactly "it is there and I cannot look
    # inside"; `stat` failing sends us to the parent, and only then is the
    # parent's searchability the thing that separates absent from unreadable.
    if [ -d "$d" ]; then
        if ! real=$(cd "$d" 2>/dev/null && pwd -P); then
            kind='unreadable'; reason='cannot_enter_directory'
        fi
    elif [ -e "$d" ]; then
        kind='absent'; reason='not_a_directory'
    elif _rr_parent_searchable "$d"; then
        kind='absent'; reason='no_such_path'
    else
        kind='unreadable'; reason='parent_not_searchable_cannot_stat'
    fi

    if [ -n "$kind" ]; then
        :
    elif ! _rr_git --version >/dev/null 2>&1; then
        kind='git-unavailable'; reason='git_not_on_path'
    else
        # ONE probe FIRST, only to separate "not a repository" from every
        # other git failure — that separation is the whole of the undetermined
        # arm, and `2>/dev/null` is what destroys it.
        #
        # THE GATE PROBE IS `--absolute-git-dir`, NOT `--show-toplevel`, AND
        # THAT IS THE WHOLE OF your-org/nexus-code#1257. `--show-toplevel`
        # conflates "there is no repository" with "there is no WORK TREE", and
        # it changed which way it expresses the second one:
        #
        #   git <= 2.23.0   bare repo / a `.git` dir -> rc 0, output EMPTY
        #   git >= 2.28.0   bare repo / a `.git` dir -> rc 128,
        #                   "fatal: this operation must be run in a work tree"
        #
        # That message does not contain `not a git repository`, so at >= 2.28.0
        # every no-work-tree subject fell into the `error` arm and the entire
        # top-EMPTY trichotomy below — `bare`, `gitdir-itself`, `inside-gitdir`
        # — was DEAD CODE. `bare` is a YES verdict, so `rr_require_own_root`
        # refused a legitimate bare repository (this nexus has a live one,
        # `work/lab-wiki.git`); the NO arms degraded to UNDETERMINED. This host
        # defaults to git 2.17.1 and CI runs 2.55.0, so the predicate was
        # correct exactly where it was developed and wrong everywhere it ran.
        #
        # Measured across every git installed here — 2.17.1, 2.23.0, 2.28.0,
        # 2.32.0, 2.33.0, 2.36.0, 2.38.1, 2.41.0, 2.42.0, 2.45.1 — fixture and
        # subject held constant:
        #
        #   --absolute-git-dir    rc 0 in EVERY repository context (work-tree
        #                         root, subdir, bare root, at any depth inside
        #                         a git dir); rc 128 only when there is truly
        #                         no repository, and then with the
        #                         `not a git repository` text BYTE-IDENTICAL
        #                         on all ten. It is the stable gate.
        #   --is-inside-work-tree rc 0 on all ten, `true`/`false` correct on
        #                         every subject. It is the stable replacement
        #                         for "is the toplevel empty".
        #
        # PROSE IS NOT AN API, and the one match left is the one git gives no
        # other signal for: every failure above is rc 128, so "no repository"
        # cannot be told from "dubious ownership" or "permission denied" by
        # status alone. Confining it to the gate — where "not a repository" is
        # the EXPECTED failure and was measured invariant across the range —
        # is what makes it defensible. Do not add a second prose match below.
        out=$(_rr_git -C "$d" rev-parse --absolute-git-dir 2>&1); rc=$?
        if [ "$rc" -ne 0 ]; then
            case "$out" in
                *'not a git repository'*|*'Not a git repository'*)
                    kind='none'; reason='no_repository_above' ;;
                *)  kind='error'
                    reason="git_rc${rc}:$(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-160)" ;;
            esac
        else
            # FIELDS ARE QUERIED ONE AT A TIME, NOT AS ONE MULTI-ARG rev-parse.
            # `git rev-parse --show-toplevel --absolute-git-dir …` on a BARE
            # repository EMITS NO LINE AT ALL for the toplevel rather than an
            # empty one, so every later field shifts up by one and positional
            # `sed -n Np` reads the wrong value. Measured: an early draft of
            # this file classified a bare repo `kind=root` for exactly that
            # reason. Separate calls cost a few forks and cannot mis-align.
            #
            # `gd` is RE-QUERIED rather than taken from `$out`: the gate
            # captured `2>&1`, so any warning git chose to emit (a stale-index
            # notice, a hint) would be concatenated into the value. The gate's
            # combined capture exists to CLASSIFY a failure, never to carry a
            # value.
            gd=$(_rr_git -C "$d" rev-parse --absolute-git-dir 2>/dev/null)   || gd=''
            common=$(_rr_git -C "$d" rev-parse --git-common-dir 2>/dev/null) || common=''
            bare=$(_rr_git -C "$d" rev-parse --is-bare-repository 2>/dev/null) || bare=''
            inwt=$(_rr_git -C "$d" rev-parse --is-inside-work-tree 2>/dev/null) || inwt=''

            # `--show-toplevel` IS NOW ASKED ONLY WHERE IT HAS AN ANSWER, so
            # its cross-version disagreement can no longer reach the ladder:
            # inside a work tree it is rc 0 with a path on every git in the
            # range; outside one we never call it and `top` is empty, which is
            # exactly what <= 2.23.0 used to hand back on its own.
            case "$inwt" in
                true)  top=$(_rr_git -C "$d" rev-parse --show-toplevel 2>/dev/null) || top='' ;;
                false) top='' ;;
                # NEITHER — the probe that decides the trichotomy did not
                # answer, so nothing below is entitled to decide. This is the
                # third value doing its job rather than a permissive default.
                *)     kind='error'
                       reason='is_inside_work_tree_unanswered' ;;
            esac
        fi

        # The ladder runs only if nothing above already decided — the gate's
        # `none`/`error`, or an unanswered `--is-inside-work-tree`.
        if [ -z "$kind" ]; then

            # --git-common-dir may be RELATIVE (`.git`); resolve it against
            # <dir> before comparing, or a plain repo compares unequal to
            # itself and every caller gets a false NO.
            common=$(_rr_abs "$d" "$common")
            gd=$(_rr_abs "$d" "$gd")

            # THE BARE ARM USED TO COME FIRST, AND THAT WAS #1121 IN THE FILE
            # THAT CITES #1121 TO CLAIM IMMUNITY. `--is-bare-repository` is
            # TRUE for every directory at any depth inside a bare repository,
            # so `bare.git/hooks/deeper/still` answered `verdict=yes kind=bare`
            # — a permissive SAFE arm returning before the DENY arm that would
            # have caught it, and a WRITE hole in the class this file exists to
            # close: `git-https-setup --repo bare.git/hooks/deep` was measured
            # NOT REFUSED. `work/lab-wiki.git` on this host is a real bare
            # repo, so it was live rather than theoretical.
            #
            # WHY THE IMMUNITY CLAIM WAS WRONG, because that is the reusable
            # part: the claim was true of `_rr_verdict`/`_rr_rc`, which map
            # KIND to verdict by equality over disjoint literal lists. It said
            # nothing about the ladder BELOW, which determines the kind and is
            # an if/elif chain of PREDICATES. Satisfying the doctrine in the
            # mapping is not satisfying it in the classifier that feeds the
            # mapping. Both holes fixed in round 2 are the same mistake — a
            # permissive arm decided before the discriminating one.
            #
            # The repair is a TRICHOTOMY on `$top` whose arms are mutually
            # exclusive by construction, with the discriminating equality
            # (`real == gitdir`) inside the branch that needs it:
            #
            #   top EMPTY      -> no work tree is in play. `$d` is the root of
            #                     its own repository ONLY if it IS the git dir
            #                     AND that git dir is bare. Measured, git
            #                     2.17.1: `real/.git` reports is-bare=FALSE
            #                     with an EMPTY toplevel, so `real == gitdir`
            #                     alone would have called it bare; and
            #                     `real/.git/hooks` reports an empty toplevel
            #                     too, which the old `no_toplevel_and_not_bare`
            #                     arm turned into UNDETERMINED when it is a
            #                     perfectly determinable NO.
            #   top != real    -> below a work-tree root (subdir / stub).
            #   top == real    -> at a work-tree root; `common == gitdir`
            #                     then separates a repo from a linked worktree.
            if [ -z "$top" ]; then
                if [ "$real" = "$gd" ] && [ "$bare" = 'true' ]; then
                    kind='bare';           reason='bare_repository_root'
                elif [ "$real" = "$gd" ]; then
                    kind='gitdir-itself';  reason='this_is_a_git_dir_not_a_work_tree_root'
                else
                    kind='inside-gitdir';  reason='inside_a_git_dir_at_depth'
                fi
            elif [ "$top" != "$real" ]; then
                if [ -e "$d/.git" ]; then
                    kind='gitdir-stub'
                    reason='dot_git_present_but_repository_root_is_elsewhere'
                else
                    kind='subdir'; reason='repository_root_is_an_ancestor'
                fi
            elif [ -n "$common" ] && [ -n "$gd" ] && [ "$common" != "$gd" ]; then
                kind='linked-worktree'
                reason='git_dir_belongs_to_the_main_repository'
            else
                kind='root'; reason='toplevel_is_self_and_git_dir_is_its_own'
            fi
        fi
    fi

    # THE FIELDS ARE ALSO PUBLISHED AS GLOBALS, and every in-process caller
    # reads THOSE rather than re-parsing the line. `rr_require_own_root` used
    # to recover them with `top=${line#*top=}; top=${top%% *}`, which splits on
    # whitespace — so for a repository under a path containing a SPACE the
    # diagnostic named `…/has` instead of `…/has space/enc`, a path that does
    # not exist. "Naming the repository git would have acted on" is this
    # change's headline improvement over `#1080`, and it was the part that
    # broke (your-org/nexus-code#1243 round 2). A value that has already been
    # computed should never be recovered by parsing a rendering of itself.
    RR_VERDICT=$(_rr_verdict "$kind"); RR_KIND="$kind"
    RR_TOP="${top:-}"; RR_GITDIR="${gd:-}"; RR_REASON="$reason"

    # The LINE is the machine-readable interface, so its values are quoted:
    # unquoted, a path with a space is not parseable by the field-splitting
    # any reader would reach for — the same input that broke the human
    # surface breaks the machine surface, in the same way. `%q` output is
    # `eval`-safe and leaves ordinary values untouched.
    printf -v RR_LINE 'verdict=%s kind=%s top=%q gitdir=%q reason=%s' \
        "$RR_VERDICT" "$kind" "${top:-}" "${gd:-}" "$reason"
    printf '%s\n' "$RR_LINE"
    _rr_rc "$kind"
}

# EVERY git call goes through here. `env -u` is the mechanism, and it is NOT
# interchangeable with `local GIT_DIR; unset GIT_DIR` — that form was written
# first and MEASURED NOT TO WORK: in bash, `unset` on a name declared `local`
# removes the local binding and UNSHADOWS the global, so the inherited
# GIT_DIR came straight back and a plain non-repo directory classified
# `verdict=yes kind=root`. Hole 3 reproduced inside its own remedy. `env -u`
# edits the child's environment directly and has no scope to be wrong about.
_rr_git() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
        -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
        -u GIT_CEILING_DIRECTORIES -u GIT_NAMESPACE -u GIT_PREFIX \
        git "$@"
}

# Can we actually enter <dir>?
_rr_readable() { [ -d "$1" ] && ( cd "$1" ) >/dev/null 2>&1; }

# Is <dir>'s parent searchable? Distinguishes "not there" from "cannot look".
_rr_parent_searchable() {
    local parent
    parent=$(dirname -- "$1")
    [ -d "$parent" ] && [ -x "$parent" ]
}

# Resolve a possibly-relative git path against <dir>.
_rr_abs() {
    local base="$1" p="$2"
    [ -n "$p" ] || { printf ''; return 0; }
    case "$p" in
        /*) printf '%s' "$p" ;;
        *)  ( cd "$base" 2>/dev/null && cd "$p" 2>/dev/null && pwd -P ) || printf '%s' "$p" ;;
    esac
}

# EQUALITY over disjoint literal lists, default-DENY. `case` with globs is
# exactly what #1121 warns about; word-membership with spaces is not a glob.
_rr_verdict() {
    case " $_RR_YES_KINDS " in *" $1 "*) printf 'yes';   return 0 ;; esac
    case " $_RR_NO_KINDS "  in *" $1 "*) printf 'no';    return 0 ;; esac
    printf 'undetermined'
}
_rr_rc() {
    case " $_RR_YES_KINDS " in *" $1 "*) return 0 ;; esac
    case " $_RR_NO_KINDS "  in *" $1 "*) return 1 ;; esac
    return 3
}

# rr_is_own_root <dir> — boolean shorthand. UNDETERMINED counts as NOT a root.
# Read the contract note above before using this to gate anything.
rr_is_own_root() { rr_classify "$1" >/dev/null; [ "$?" -eq 0 ]; }

# rr_has_own_history <dir> — the READ-side question, and it is NOT the same
# question as rr_is_own_root.
#
# A LINKED WORKTREE has its own HEAD and its own branch, so `git -C <wt>
# rev-parse HEAD` is honest provenance — but `git -C <wt> config --local`
# writes into the MAIN repository's config (measured). So the read hazard and
# the write hazard have DIFFERENT correct answers for the same directory, and
# collapsing them into one boolean gets one of the two wrong.
#
# The size of the gap is not hypothetical. Measured on this nexus at `dev` @
# `50c36ef`, over 881 directories under `work/`: 692 `root`, 131
# `linked-worktree`, 56 `subdir`, 1 `gitdir-stub`, 1 `bare`. So a provenance
# reader using the WRITE predicate would refuse 131 trees whose history is
# genuinely their own, and a config writer using the READ predicate would
# reconfigure the main repository for those same 131.
#
# Use this one for provenance, freshness, drift and any other READ. Use
# rr_is_own_root / rr_require_own_root for anything that WRITES.
rr_has_own_history() {
    local rc
    rr_classify "$1" >/dev/null; rc=$?
    [ "$rc" -eq 3 ] && return 3
    case " root bare linked-worktree " in *" $RR_KIND "*) return 0 ;; esac
    return 1
}

# rr_require_own_root <dir> <tool-name> — the WRITE-side entry point. Prints a
# diagnostic naming BOTH the directory asked about and the repository git would
# actually have acted on, then returns non-zero. That second half is the whole
# point: `#1080`'s output never said which repo it wrote to.
rr_require_own_root() {
    local d="$1" who="${2:-repo-root}" rc
    # NOT a command substitution: a subshell would discard the globals
    # rr_classify sets, sending us straight back to parsing the line.
    rr_classify "$d" >/dev/null; rc=$?
    [ "$rc" -eq 0 ] && return 0
    local kind="$RR_KIND" top="$RR_TOP" gd="$RR_GITDIR" reason="$RR_REASON"
    {
        printf '%s: %s is not a git repository rooted at itself (%s)\n' "$who" "$d" "$kind"
        case "$rc" in
            # A LINKED WORKTREE NEEDS A DIFFERENT SENTENCE, because its
            # toplevel IS itself — naming the toplevel would print the
            # directory back at the caller and say nothing. What is wrong
            # there is not the root but the DESTINATION: `git -C <wt> config
            # --local` lands in the MAIN repository's config (measured), so
            # the main repo is the thing that would have been modified.
            1) if [ "$kind" = 'linked-worktree' ]; then
                   printf '%s: it is a LINKED WORKTREE — `git -C … config --local` writes into the MAIN repository (%s), not here. Refusing.\n' \
                       "$who" "${gd%/worktrees/*}"
               elif [ -n "$top" ]; then
                   printf '%s: git would have acted on %s instead. Refusing.\n' "$who" "$top"
               elif [ -n "$gd" ]; then
                   # NO WORK TREE, BUT THERE IS CERTAINLY A REPOSITORY — this
                   # is `gitdir-itself` and `inside-gitdir`, where `$top` is
                   # empty by construction. Falling through to "there is no
                   # repository here" would print the one sentence that is
                   # FALSE for these kinds, and would throw away the git dir
                   # we are holding: naming the repository git would have
                   # acted on is this file's whole improvement over `#1080`.
                   # Unreachable on git >= 2.28.0 until `#1257` — these kinds
                   # could not be produced there at all — so the wrong
                   # sentence had never been seen.
                   printf '%s: git would have acted on the repository at %s instead. Refusing.\n' "$who" "$gd"
               else
                   printf '%s: there is no repository here. Refusing.\n' "$who"
               fi ;;
            *) printf '%s: could NOT determine (%s) — this is not "no". Refusing.\n' \
                   "$who" "$reason" ;;
        esac
    } >&2
    return "$rc"
}

# ── CLI ────────────────────────────────────────────────────────────────────
# Only when executed, never when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    _rr_mode=line
    case "${1-}" in
        --quiet) _rr_mode=quiet; shift ;;
        --kind)  _rr_mode=kind;  shift ;;
        --history) _rr_mode=history; shift ;;
        -h|--help)
            sed -n '2,/^# USAGE/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 2 ;;
    esac
    if [ "$#" -ne 1 ]; then
        echo "usage: repo-root.sh [--quiet|--kind] <dir>" >&2
        exit 2
    fi
    if [ "$_rr_mode" = history ]; then
        rr_has_own_history "$1"; exit $?
    fi
    # NOT `$(rr_classify …)`: a command substitution is a subshell and would
    # discard every RR_* global, which is the trap this file's own header
    # warns about. It bit here first — `--kind` printed an EMPTY string and
    # twenty assertions in the guard suite failed at once.
    rr_classify "$1" >/dev/null; _rr_rc_val=$?
    case "$_rr_mode" in
        quiet) : ;;
        kind)  printf '%s\n' "$RR_KIND" ;;
        *)     printf '%s\n' "$RR_LINE" ;;
    esac
    exit "$_rr_rc_val"
fi
