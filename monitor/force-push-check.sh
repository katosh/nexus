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
    [ -n "$_err" ] && printf '%s\n' "$_err" >&2
    exit 2
fi

_url=$(printf '%s\n' "$_out" | sed -n 's/^To //p' | head -1)
[ -n "$_url" ] || _url=$(printf '%s\n' "$_err" | sed -n 's/^To //p' | head -1)

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
  DELETE ${_dst} on ${_url}
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
                _lost=$(git log --oneline "${_src_sha}..${_remote_sha}" 2>/dev/null)
                if [ -n "$_lost" ]; then
                    _unsafe=1
                    _report="${_report}
  ${_dst} on ${_url}
$(printf '%s\n' "$_lost" | sed 's/^/    /')"
                fi
                # A '+' with nothing reachable-but-unmerged is a rewrite that
                # loses no commit (an amend of your own tip, say): not unsafe.
            else
                _refused=1
                _report="${_report}
  ${_dst} on ${_url}
    FORCED UPDATE, but its commits could not be fetched — cannot say what is lost."
            fi
            ;;
        '!')
            _newonly=0; _refused=1
            _report="${_report}
  ${_dst} on ${_url}
    REJECTED by git (${_summary}) — the push would not happen as given."
            ;;
        *)  # An unknown flag is not a pass. Fail closed on the default arm.
            _newonly=0; _refused=1
            _report="${_report}
  ${_dst} on ${_url}
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
