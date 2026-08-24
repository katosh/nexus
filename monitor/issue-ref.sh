#!/usr/bin/env bash
# issue-ref.sh — resolve a configured issue reference, or REFUSE.
# your-org/nexus-code#866.
#
# Usage:
#   monitor/issue-ref.sh <value> [--field <config.key>]
#
# Prints on success (exit 0), one per line, shell-eval-safe:
#   REPO=<owner>/<name>
#   ISSUE=<n>
#
# Exit codes:
#   0  qualified reference parsed
#   3  EMPTY — the field is not configured. Not an error and not a
#      reference: the caller decides whether "unset" is legitimate (for
#      most of these it is: no standing issue).
#   4  REFUSED — a value is present but is NOT a qualified reference.
#      Loud, and deliberately not a guess.
#
# ---------------------------------------------------------------------------
# WHY A BARE NUMBER IS REFUSED RATHER THAN RESOLVED
# ---------------------------------------------------------------------------
#
# `#N` is repo-relative. The workspace contract already says so for comment
# BODIES, where GitHub renders the link and the ambiguity is at least visible.
# In a CONFIG FIELD nothing renders it, so a bare number is a reference with
# its repo silently supplied by whatever the consuming code happens to pass —
# and the operator who typed it has no way to see which repo that was.
#
# This is not hypothetical. A bare number configured against one repo's issue
# was consumed against another's, and every write landed on an unrelated closed
# PR in the implementation repo for a month. Nothing failed: the number
# resolved, the API accepted it, the comments posted. The operator simply never
# saw them, because the thread they were watching was a different `#N`.
#
# The trap is that this repo is CLONED BY EVERY OPERATOR. A number that is
# correct in your asset repo names something else entirely in the shared
# implementation repo, and the two conventions genuinely differ in-tree today:
#
#   monitor.cc_auto_update.tracking_issue  bare N -> the IMPLEMENTATION repo
#   monitor.remote.endpoint_issue          bare N -> YOUR ASSET repo
#
# Opposite defaults, neither stated where the value is typed. An operator who
# learns the convention from one field is silently wrong about the other, and
# "silently" is the whole problem — a wrong repo does not error, it just
# publishes somewhere nobody is reading.
#
# Correcting the NUMBER would not fix this. A corrected bare number is right
# until the next person reads it in the other repo's context, and is then
# wrong again with no more warning than before. Only a reference that CARRIES
# its repo is stable under being read from anywhere:
#
#     tracking_issue: "your-org/nexus-code#229"      qualified — unambiguous
#     tracking_issue: 229                            REFUSED — which repo?
#
# So: qualify it, or leave it empty. There is no third answer this script is
# willing to invent on your behalf.

set -u

_field=""
_value=""
while [ $# -gt 0 ]; do
    case "$1" in
        --field) _field="${2:-}"; shift 2 || exit 4 ;;
        --field=*) _field="${1#*=}"; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        --) shift; _value="${1:-}"; shift || true ;;
        *) _value="$1"; shift ;;
    esac
done

_where() { [ -n "$_field" ] && printf '%s' "$_field" || printf '%s' "the issue-reference field"; }

# Trim surrounding whitespace; YAML quoting leaves it more often than you think.
_value="${_value#"${_value%%[![:space:]]*}"}"
_value="${_value%"${_value##*[![:space:]]}"}"

[ -n "$_value" ] || exit 3

# `[[ =~ ]]`, not grep — for TWO independent reasons that happen to share a fix.
#
#   1. SIGPIPE. `printf … | grep -q` under `pipefail` reports 141 when grep
#      exits early on a match: a false failure on the input that DID match.
#      test-sigpipe-assertion-lint.sh enforces this repo-wide.
#   2. ANCHORING. `grep -E` anchors `^`/`$` PER LINE; bash `[[ =~ ]]` anchors to
#      the WHOLE STRING. On a multi-line value grep accepts a qualified
#      reference sitting on line 2 and the caller then extracts a repo from
#      line 1 — an ACCEPT yielding a bogus repo, the exact polarity this script
#      exists to invert. `config/load.sh` uses Python `re.match`, which anchors
#      to the string, so the two validators DISAGREED (`#874` F4). They now
#      agree, and a differential test holds them to it.
#
# The one accepted form: owner/repo#N. Owner and repo use GitHub's own
# character set; N is a positive integer with no leading `#` ambiguity left.
# `[1-9][0-9]*` not `[0-9]+`: a leading zero is a typo, and accepting `#0229`
# would hand a differently-spelled number to the API rather than refusing an
# input the operator clearly did not mean.
if [[ $_value =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*$ ]]; then
    printf 'REPO=%s\n'  "${_value%#*}"
    printf 'ISSUE=%s\n' "${_value##*#}"
    exit 0
fi

printf 'issue-ref: REFUSING — %s is not a qualified issue reference.\n' "$(_where)" >&2
printf '    value: %s\n' "$_value" >&2
if [[ $_value =~ ^#?[0-9]+$ ]]; then
    printf '    A bare number does not say WHICH REPO. `#N` is repo-relative, and this\n' >&2
    printf '    repo is cloned by every operator — the same number names different things\n' >&2
    printf '    in your asset repo and in the shared implementation repo. Resolving it\n' >&2
    printf '    against an implied repo is how writes land, succeed, and are never seen.\n' >&2
elif [[ $_value =~ ^https?://[^/]*github[^/]*/[^/]+/[^/]+/issues/[0-9]+ ]]; then
    # A pasted issue URL carries everything needed; say so rather than making
    # the operator reverse-engineer the form from a grammar.
    _u="${_value%%\?*}"; _n="${_u##*/}"; _rest="${_u%/issues/*}"; _r="${_rest#*://}"; _r="${_r#*/}"
    printf '    That is the issue URL. The same reference in config form is:\n' >&2
    printf '        %s#%s\n' "$_r" "$_n" >&2
else
    printf '    Expected the form owner/repo#N.\n' >&2
fi
# Echo back the digits they typed, minus any leading zeros — suggesting
# `owner/repo#0229` would name a form this script also refuses.
_hint_n=$(printf '%s' "$_value" | tr -cd '0-9' | sed 's/^0*//; s/^$/N/')
printf '    Set it as:  %s: "owner/repo#%s"\n' "${_field:-<the field>}" "$_hint_n" >&2
printf '    Or leave it empty if there is no standing issue.\n' >&2
exit 4
