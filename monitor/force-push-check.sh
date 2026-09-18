#!/usr/bin/env bash
# force-push-check.sh — "would this force-push destroy anyone's work?"
# your-org/nexus-code#835.
#
# Usage:
#   bash monitor/force-push-check.sh [--quiet] [<git push arguments…>]
#
#   The arguments are **git push's own**, passed through verbatim:
#       force-push-check.sh                       # what a bare `git push` moves
#       force-push-check.sh origin feature
#       force-push-check.sh other mywork:feature
#       force-push-check.sh origin +dev
#   `--quiet` (verdict line only) must come FIRST; everything after it is git's.
#
# Exit codes, deliberately mirroring monitor/guards-for-diff.sh (#803):
#   0  SAFE — nothing that would move destroys a commit.
#   1  UNSAFE — at least one ref would lose commits (or be deleted). Listed.
#   2  REFUSED — could not determine (remote unreachable, no refspec resolved,
#      push rejected for a reason that is not fast-forward). NOT a clearance.
#   3  NOTHING TO OVERWRITE — everything that would move creates a NEW remote
#      ref. Known, and distinct from 0 because nothing was compared.
#
# ---------------------------------------------------------------------------
# WHY THIS ASKS GIT INSTEAD OF RESOLVING THE PUSH TARGET ITSELF
# ---------------------------------------------------------------------------
#
# This check has produced FOUR false clearances, on four distinct axes, each
# found only by building the failing case:
#
#   1. it compared AUTHORSHIP  — structurally incapable: every agent in this
#      workspace commits with the operator's identity, so it always saw one
#      name and could never detect a sibling.
#   2. it could not distinguish FAILURE from CLEARANCE — "branch absent",
#      "fetch failed" and "stale tracking ref" all printed empty, and empty
#      read as safe.
#   3. it compared the wrong REF — a push moves refs/heads/<dst>, not HEAD.
#   4. it compared the wrong REMOTE — `remote.pushDefault` selects the push
#      remote; the check assumed `origin`, said SAFE, and the push destroyed a
#      commit on the other remote.
#
# The pattern is not carelessness. Each round RE-IMPLEMENTED A PIECE OF GIT'S
# PUSH-TARGET RESOLUTION by hand, and that resolution has more surface than can
# be enumerated: push.default, remote.pushDefault, branch.<n>.remote,
# branch.<n>.merge, branch.<n>.pushRemote, explicit refspecs, `+` force markers,
# `--all`, `--mirror`, `--tags`, per-remote push refspecs, URL rewriting…
# Fixing one axis per round simply relocates the hole.
#
# So this no longer models the resolution — it ASKS FOR IT:
#
#     git push --dry-run --porcelain --force <the user's own arguments>
#
# which reports, straight from git, exactly which refs would move on which
# remote. That is authoritative by construction and cannot drift, because it IS
# the resolution rather than a model of it. `--dry-run` writes nothing;
# `--porcelain` gives a stable machine format; `--force` is what makes git
# report the DESTRUCTIVE form (`+ old...new (forced update)`) instead of
# refusing with `! [rejected]`, and it hands back the remote's current sha in
# the bargain.
#
# Porcelain vocabulary, measured on git 2.17.1 (see test-force-push-check.sh):
#
#     To <url>
#     <flag>\t<src>:<dst>\t<summary>
#     Done
#
#     ' '  fast-forward      old..new                  safe
#     '='  up to date                                  safe
#     '*'  new ref           [new branch]              nothing to overwrite
#     '+'  forced update     old...new (forced update) DESTRUCTIVE
#     '-'  deleted           [deleted]                 DESTRUCTIVE
#     '!'  rejected          [rejected] (…)            could not determine
#
# The remote's objects are then fetched FROM THE URL GIT NAMED, and the lost
# commits are computed against FETCH_HEAD rather than a remote-tracking ref —
# `refs/remotes/<r>/<b>` survives a failed fetch at its old value, is advanced
# by your own push, and does not exist at all under a non-default fetch
# refspec. FETCH_HEAD reflects THIS fetch and nothing else.
#
# ---------------------------------------------------------------------------
# RESIDUAL — what this still cannot tell you, named rather than discovered
# ---------------------------------------------------------------------------
#
# Asking git deletes the resolution-drift class. It does not make the answer
# total, and the remaining gaps are bounded and worth stating:
#
#   * TOCTOU. The verdict describes the remote as of the dry-run. Someone can
#     push between the check and yours. Inherent to any such check; the window
#     is seconds, but it is not zero.
#   * It requires the network and credentials. A remote it cannot reach yields
#     REFUSED (exit 2), never a pass — but that means an offline worker gets no
#     answer rather than a cheap one.
#   * RECEIVE-SIDE POLICY IS INVISIBLE TO THE DRY-RUN — measured, not assumed.
#     `receive.denyNonFastForwards`, `denyCurrentBranch` and pre-receive hooks
#     are enforced when the remote RECEIVES, not during dry-run negotiation, so
#     a push those would reject is still reported here as `+ (forced update)`
#     and classified UNSAFE. That errs CONSERVATIVE for our question — a
#     rejected push destroys nothing — so it is a false ALARM, never a false
#     clearance. Pinned by a test, because "errs safe" is a claim like any
#     other. It is also why the `!` and unknown-flag arms are exercised with a
#     PATH-front stub: a live rig cannot reach them.
#   * It reports what a plain `--force` would do. If you actually push with
#     `--force-with-lease`, the real push may be REFUSED where this said
#     UNSAFE — conservative, never the reverse.
#   * Shallow/partial clones: the fetch that materialises the remote's commits
#     may be truncated, in which case the count of lost commits can be a lower
#     bound. The verdict (UNSAFE) is still correct.

set -u

QUIET=0
if [ "${1:-}" = "--quiet" ]; then QUIET=1; shift; fi
[ "${1:-}" = "--" ] && shift

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

# Redact `<scheme>://<userinfo>@` ANYWHERE in a stream, not just at ^. git's
# own `To` line is already anonymised, but its DIAGNOSTICS are not: measured,
# `fatal: unable to access 'http://alice:<secret>@host/'` prints the credential
# verbatim, and this script passes git's stderr through on the REFUSED path.
# Matches git's own display convention by dropping the WHOLE userinfo.
_redact_userinfo_stream() {
    sed -e 's|\([A-Za-z][A-Za-z0-9+.-]*://\)[^@/[:space:]]*@|\1|g'
}

git rev-parse --git-dir >/dev/null 2>&1 || {
    printf 'REFUSED: not a git repository.\n' >&2; exit 2; }

# ---- ask git what this push would move ------------------------------------
# ONE invocation, streams separated via a temp file. Running it twice (once for
# stdout, once for stderr) doubled remote latency and load — and worse, it
# observed the remote TWICE, so the two runs could disagree and the URL used
# came from the second. A check about a moving target must sample it once.
_errfile=$(mktemp 2>/dev/null) || {
    printf 'REFUSED: cannot create a temp file to capture git stderr.\n' >&2; exit 2; }
_out=$(git push --dry-run --porcelain --force "$@" 2>"$_errfile")
_err=$(cat "$_errfile" 2>/dev/null)
rm -f "$_errfile"

# Ref lines are the answer; their ABSENCE is the failure. rc is not the
# discriminator: a dry-run that reports refs can exit non-zero (a rejection is
# informative), and one that resolves nothing can exit zero.
_refs=$(printf '%s\n' "$_out" | awk -F'\t' 'NF>=2 && $2 ~ /:/ { print }')

if [ -z "$_refs" ]; then
    printf 'REFUSED: git resolved no refs for this push — cannot say what would move.\n' >&2
    [ -n "$_err" ] && printf '%s\n' "$_err" | _redact_userinfo_stream >&2
    exit 2
fi

# ---- where to fetch the remote's objects from ------------------------------
# NEVER the `To` line. Git ANONYMISES it: the SSH userinfo is stripped, so
# `git@github.com:o/r.git` prints as `github.com:o/r.git`, and fetching that
# makes ssh substitute the LOCAL username. Measured on this host, both SSH
# forms — the four independent reports all named only the first:
#
#   configured git@github.com:your-org/nexus-code.git
#   To          github.com:your-org/nexus-code.git          DIFFERENT
#   configured ssh://git@github.com/your-org/nexus-code.git
#   To          ssh://github.com/your-org/nexus-code.git     DIFFERENT
#   configured <abs path> / file://<path> / <rel path>
#   To          <same>                                       SAME
#
# So the defect is invisible on every local-path transport, which is what the
# whole original fixture set used. The fetch then fails, `_remote_sha` is
# empty, and the `+` arm — the ONLY arm a force-push exercises — refuses.
# rc 2 for every forced update on the remotes this workspace actually uses.
#
# Ask git to resolve the destination instead, exactly as it did for the push.
# `git remote get-url --push` applies `insteadOf` AND `pushurl` — measured:
# under an `insteadOf` rewrite it returns the REWRITTEN, fetchable URL, so it
# is never worse than the display line. The `To` line survives only as a last
# resort, for a caller that passed a URL this cannot resolve.
_resolve_remote_arg() {
    # git push [<options>] [<repository> [<refspec>…]] — the repository is the
    # first non-option argument. Values attached with `=` stay attached, so the
    # SEPARATE value of an option (`--receive-pack git-receive-pack origin …`)
    # is the one thing this can mistake for the repository. `_push_url_for`
    # rejects a token that is neither a known remote nor URL-shaped, so such a
    # mistake falls back to the display URL rather than aiming the fetch at an
    # option value. That degradation is now real; it was claimed before it was
    # true (your-org/nexus-code#930, F5).
    for _a in "$@"; do
        case "$_a" in -*) continue ;; esac
        printf '%s' "$_a"; return 0
    done
    return 1
}

_strip_userinfo() {   # display form of a url, as git prints it on `To`
    printf '%s' "$1" | sed -e 's|^\([A-Za-z][A-Za-z0-9+.-]*://\)[^@/]*@|\1|' \
                           -e 's|^[^/@]*@\([^/]*:\)|\1|'
}

_push_url_for() {   # _push_url_for <repository-arg-or-empty> <display-url>
    _r="$1"; _disp="$2"
    if [ -n "$_r" ]; then
        # The caller named the repository. A NAME resolves through git; a URL
        # passed directly does not, and is already authentic.
        if git remote get-url --push "$_r" >/dev/null 2>&1; then
            git remote get-url --push "$_r" 2>/dev/null; return 0
        fi
        # Not a known remote. It is usable AS a URL only if it looks like one;
        # otherwise this is almost certainly the separate VALUE of an option
        # (`--receive-pack git-receive-pack origin …`), and returning it would
        # send the fetch at a token that is not a destination. Fail here so the
        # caller's `|| _url="$_disp_url"` fallback actually fires — an earlier
        # comment claimed that degradation happened and it did not, because
        # this arm returned rc 0 unconditionally.
        case "$_r" in
            *://*|*:*|/*|./*|../*) printf '%s' "$_r"; return 0 ;;
        esac
        [ -d "$_r" ] && { printf '%s' "$_r"; return 0; }
        return 1
    fi
    # NO repository argument, and this deliberately does NOT re-derive git's
    # push-target selection — `push.default` / `pushRemote` / `pushDefault` are
    # exactly the hand-rolled resolution that produced earlier false
    # clearances, and a test in this repo forbids consulting them here.
    #
    # It does not need to. Git has ALREADY chosen the destination and named it
    # on the `To` line; the only thing wrong with that line is the anonymised
    # userinfo. So recover the authentic form of THAT SAME URL from git's own
    # remote list, by matching either exactly or modulo userinfo.
    [ -n "$_disp" ] || return 1
    while IFS= read -r _n; do
        [ -n "$_n" ] || continue
        _u=$(git remote get-url --push "$_n" 2>/dev/null) || continue
        [ -n "$_u" ] || continue
        [ "$_u" = "$_disp" ] && { printf '%s' "$_u"; return 0; }
        [ "$(_strip_userinfo "$_u")" = "$_disp" ] && { printf '%s' "$_u"; return 0; }
    done <<EOF
$(git remote 2>/dev/null)
EOF
    return 1
}

_repo_arg_probe=$(_resolve_remote_arg "$@") || _repo_arg_probe=
# MULTI-URL REMOTES ARE REFUSED, NOT GUESSED AT (your-org/nexus-code#930, F2).
# `git remote set-url --add` is a supported feature (push to mirrors). git then
# emits ONE `To` BLOCK PER URL, and this check has exactly one `_url` and one
# FETCH_HEAD — so it would evaluate every block's ref lines against whichever
# URL came first. Measured on a two-URL remote: a clean fast-forward on url1
# and a DIRTY forced update on url2 returned 0 SAFE, and the push removed the
# sibling's commit from url2. That is "compared the wrong REMOTE", the fourth
# false-clearance axis, on a factor nobody had enumerated.
#
# Pre-existing — `e256d4a` clears the same fixture — but this is the change
# that makes "ask git which URL" its thesis, and `get-url --push` answers for
# one URL without saying so. One destination per verdict, or no verdict.
_to_blocks=$(printf '%s\n' "$_out" "$_err" | grep -c '^To ')
if [ "${_to_blocks:-0}" -gt 1 ]; then
    printf 'REFUSED: this push has %s destinations (a multi-URL remote).\n' "$_to_blocks" >&2
    printf '  One verdict cannot describe several remotes: the refs would be compared\n' >&2
    printf '  against whichever URL was read first, which is how a dirty sibling on the\n' >&2
    printf '  second URL reads as SAFE. Check each URL separately.\n' >&2
    # PERMANENT, and said so (your-org/nexus-code#898 item 2): the other rc 2
    # arms mean "could not look this time" — this one is a property of the
    # remote's configuration and a retry returns it verbatim. Without the
    # word, a worker reads the generic "REFUSED (could not determine)" as
    # transient and retries into it.
    printf '  This refusal is PERMANENT for this remote: retrying does not clear it.\n' >&2
    printf '  Per URL:  git remote get-url --push --all %s\n' "${_repo_arg_probe:-<remote>}" >&2
    printf '            git push --dry-run --porcelain --force <url> <refspec>   # one URL at a time\n' >&2
    exit 2
fi

_repo_arg=$(_resolve_remote_arg "$@") || _repo_arg=
_disp_url=$(printf '%s\n' "$_out" | sed -n 's/^To //p' | head -1)
[ -n "$_disp_url" ] || _disp_url=$(printf '%s\n' "$_err" | sed -n 's/^To //p' | head -1)
_url=$(_push_url_for "$_repo_arg" "$_disp_url") || _url="$_disp_url"
# Last resort only. An empty result is not fatal: the fetch simply fails and
# the ref is REFUSED, which is the honest answer.
[ -n "$_url" ] || _url="$_disp_url"

# `_url` is AUTHENTIC and may carry userinfo — that is the point of resolving
# it (the fetch below needs credentials). It must therefore NEVER be printed.
# `_url_show` is the display form, and every report line uses it. This repo
# configures exactly such a remote: monitor/upload-asset.sh sets origin to
# `https://x-access-token:<TOKEN>@github.com/...`, so printing `_url` emits a
# live installation token into agent context, reports and issue comments.
_url_show=$(_strip_userinfo "$_url")


# ---- what "destroys work" actually means ----------------------------------
# THE PREDICATE IS PATCH-ID, NOT COMMIT IDENTITY (your-org/nexus-code#920 B).
#
# The shipped check asked `git log src..remote` — "is any commit reachable from
# the remote tip but not from mine?" A REBASE makes that true BY CONSTRUCTION:
# replaying a commit gives it a new sha, so the pre-rebase commit is always
# unreachable from the new tip. So the tool reported UNSAFE for the one
# operation the hook it backs calls EXPECTED, and an agent either abandons a
# correct push or learns to ignore the tool — the worse outcome, since this is
# the backstop for genuinely destructive pushes.
#
# The property that actually distinguishes them is whether the CHANGE survives,
# not whether the commit object does:
#
#   destroyed = { c in remote\src : patch-id(c) does not reappear in src\remote }
#
# Empty set => the rewrite preserved every change => safe. That is exactly the
# gate the worker floor and the orchestrator already prescribe by hand
# ("dropped-but-not-reappearing set must be EMPTY"), so the tool now encodes
# the rule the workspace was already running manually.
#
# WHERE THIS IS NOT IDENTITY, stated because a predicate's boundary is part of
# its verdict:
#   * patch-id ignores the commit MESSAGE, author and date. A rebase that keeps
#     every diff but rewrites messages reads as safe. For "did this destroy
#     work" that is the right answer; for "is this the same history" it is not,
#     and this tool only claims the former.
#   * MERGE commits and EMPTY commits have NO patch-id — measured, `git show`
#     of either yields nothing for `git patch-id` to hash. They can never be
#     matched, so they are counted as DESTROYED. Fail-closed: a dropped merge
#     is worth an alarm, and a false alarm is the safe direction here.
#   * Two genuinely different commits could in principle collide on patch-id.
#     Astronomically unlikely. NOT to be confused with DUPLICATION of the same
#     change, which is routine (revert of a revert, a re-landed commit, a
#     cherry-pick round-trip) and is handled by consuming the witness in the
#     match below — see there. Conflating the two is what made an earlier
#     draft of this predicate clear a real loss.
#   * RESIDUAL — "the rebase is cleared" means a CONFLICT-FREE, MERGE-FREE
#     rebase. Patch-id equality survives only a replay that reproduces the diff
#     byte-for-byte after whitespace folding, so all of these are reported
#     UNSAFE even though they destroy nothing: a rebase whose replay needed
#     CONFLICT RESOLUTION (the resolved hunk's context differs), a
#     CONTENT-CHANGING `--amend` (a message-only amend is cleared), and a
#     rebase that FLATTENS A MERGE (merges have no patch-id). The direction is
#     safe — it over-reports, never under-reports — but it is a large slice of
#     real force-pushes, and this tool's whole motivation is that a spurious
#     UNSAFE on an expected operation teaches agents to ignore it. Pinned by a
#     conflicted-rebase row in the suite rather than left as a claim.
#   * A large rewrite is bounded below: beyond _PID_MAX commits per side the
#     comparison degrades to commit identity and SAYS so. That direction is
#     conservative (it can only over-report), never a false clearance.
_PID_MAX=500

_patch_ids_of() {   # _patch_ids_of <range> -> one patch-id per line ("" for none)
    git rev-list "$1" 2>/dev/null | while IFS= read -r _c; do
        git show "$_c" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1
    done
}

# _destroyed_between <src_sha> <remote_sha> -> `git log --oneline` of the
# commits that would really be lost. Empty output means nothing is destroyed.
_destroyed_between() {
    _ds="$1"; _dr="$2"
    _cand=$(git rev-list "${_ds}..${_dr}" 2>/dev/null)
    [ -n "$_cand" ] || return 0
    _ncand=$(printf '%s\n' "$_cand" | grep -c . )
    _nkept=$(git rev-list --count "${_dr}..${_ds}" 2>/dev/null) || _nkept=0
    if [ "$_ncand" -gt "$_PID_MAX" ] || [ "$_nkept" -gt "$_PID_MAX" ]; then
        printf '%s\n' "$_cand" | while IFS= read -r _c; do
            git log --oneline -1 "$_c" 2>/dev/null
        done
        printf '    (ranges over %s commits: compared by identity, not patch-id — this\n' "$_PID_MAX" >&2
        printf '     over-reports a rebase and never under-reports a deletion)\n' >&2
        return 0
    fi
    _kept=$(_patch_ids_of "${_dr}..${_ds}")
    printf '%s\n' "$_cand" | while IFS= read -r _c; do
        _id=$(git show "$_c" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1)
        if [ -n "$_id" ] && grep -qxF -- "$_id" <<<"$_kept"; then
            # CONSUME THE WITNESS. One replayed commit clears exactly ONE
            # dropped commit. Plain set membership lets N remote-only commits
            # sharing a patch-id all be cleared by a SINGLE local commit
            # carrying it — and that is not exotic: a revert-then-re-land on
            # the remote produces pids {P, Q, P} while a rebased copy of the
            # first two carries {…, P, Q}. Measured, the set form said SAFE
            # and the push then rewrote the remote back across the re-land,
            # taking the file's content backwards and orphaning the third
            # commit. The identity predicate this replaced would have caught
            # it, so the set form turned a true alarm into a false CLEARANCE —
            # the only direction that matters (your-org/nexus-code#930, F1).
            #
            # Note the doc's old reassurance addressed the wrong hazard:
            # patch-id COLLISION between different changes is astronomically
            # unlikely; DUPLICATION of the same change is routine.
            _kept=$(printf '%s\n' "$_kept" | awk -v id="$_id" \
                'seen || $0 != id { print } $0 == id && !seen { seen = 1 }')
            continue          # the change was replayed: not destroyed
        fi
        git log --oneline -1 "$_c" 2>/dev/null
    done
}

_unsafe=0; _newonly=1; _refused=0
_report=""

while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _flag=${_line%%	*}
    _rest=${_line#*	}
    _pair=${_rest%%	*}
    _summary=${_rest#*	}
    _src=${_pair%%:*}
    _dst=${_pair#*:}

    case "$_flag" in
        '='|' '|'')   _newonly=0 ;;                       # up-to-date / fast-forward
        '*')          : ;;                                # new ref: nothing to overwrite
        '-')
            _newonly=0; _unsafe=1
            _report="${_report}
  DELETE ${_dst} on ${_url_show}
    the entire ref is removed."
            ;;
        '+')
            _newonly=0
            # Fetch the objects git just told us about, from the URL git named.
            if git fetch --quiet "$_url" "$_dst" 2>/dev/null; then
                _remote_sha=$(git rev-parse --verify --quiet FETCH_HEAD) || _remote_sha=
            else
                _remote_sha=
            fi
            _src_sha=$(git rev-parse --verify --quiet "${_src}^{commit}" 2>/dev/null) || _src_sha=
            if [ -n "$_remote_sha" ] && [ -n "$_src_sha" ]; then
                _lost=$(_destroyed_between "$_src_sha" "$_remote_sha")
                if [ -n "$_lost" ]; then
                    _unsafe=1
                    _report="${_report}
  ${_dst} on ${_url_show}
$(printf '%s\n' "$_lost" | sed 's/^/    /')"
                fi
                # A '+' whose every dropped change reappears by patch-id is a
                # REWRITE that loses nothing. Not unsafe. What counts as
                # "reappears" is narrower than it sounds — see RESIDUAL in
                # _destroyed_between: a CONFLICT-FREE rebase and a MESSAGE-ONLY
                # amend qualify; a rebase needing conflict resolution, a
                # content-changing amend, and a rebase that flattens a merge do
                # NOT, and are reported UNSAFE.
            else
                _refused=1
                _report="${_report}
  ${_dst} on ${_url_show}
    FORCED UPDATE, but its commits could not be fetched — cannot say what is lost."
            fi
            ;;
        '!')
            _newonly=0; _refused=1
            _report="${_report}
  ${_dst} on ${_url_show}
    REJECTED by git (${_summary}) — the push would not happen as given."
            ;;
        *)  # An unknown flag is not a pass. Fail closed on the default arm.
            _newonly=0; _refused=1
            _report="${_report}
  ${_dst} on ${_url_show}
    unrecognised porcelain flag '${_flag}' (${_summary}) — cannot classify."
            ;;
    esac
done <<EOF
$_refs
EOF

if [ "$_unsafe" -eq 1 ]; then
    say "UNSAFE: this push destroys commits."
    say "${_report#
}"
    exit 1
fi
if [ "$_refused" -eq 1 ]; then
    printf 'REFUSED: could not classify every ref this push would move.\n' >&2
    printf '%s\n' "${_report#
}" >&2
    exit 2
fi
if [ "$_newonly" -eq 1 ]; then
    say "NOTHING TO OVERWRITE: every ref this push moves would be created new."
    say "Not a clearance about anyone else's work — there is simply nothing there yet."
    exit 3
fi

say "SAFE: nothing this push moves would destroy a commit."
say "Checked against what git itself says it would push:"
say "$(printf '%s\n' "$_refs" | sed 's/^/  /')"
exit 0
