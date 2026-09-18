#!/usr/bin/env bash
# leak-gate.sh — fail (nonzero) if any denied internal token survives in the
# tracked tree. Patterns are read from the mapping file (`deny`/`keep` lines);
# this script hardcodes NO identifiers, so its own public copy is clean.
#
#   leak-gate.sh <mapping.tsv> [<repo-dir>] [--allow-unstaged]
#
# Exit 0 = clean. Exit 1 = leak (offending lines printed). Exit 2 = usage.
# Exit 5 = REFUSED: the index and the working tree disagree, so this gate cannot
#          say which artifact it is vouching for. See below.
# Exit 6 = REFUSED: the index holds an entry whose PUBLISHED content this gate
#          cannot read, so a PASS would describe a smaller population than the
#          one being shipped. See the index-entry scan below.
set -uo pipefail
export LC_ALL=C
ALLOW_UNSTAGED=0
args=()
for a in "$@"; do
    case "$a" in
        --allow-unstaged) ALLOW_UNSTAGED=1 ;;
        *) args+=("$a") ;;
    esac
done
set -- ${args[@]+"${args[@]}"}
MAP="${1:?usage: leak-gate.sh <mapping.tsv> [repo-dir] [--allow-unstaged]}"
DIR="${2:-.}"
cd "$DIR"

# ---- REFUSE TO VOUCH FOR AN ARTIFACT THAT IS NOT THE ONE BEING SHIPPED ------
#
# This gate reads the WORKING TREE (`git grep`, below). The publish path reads
# the INDEX (`git write-tree` -> `git commit-tree` -> push). `build.sh` scrubs
# the working tree and does not stage. So when the two disagree, a PASS here is
# a statement about a tree nobody is going to push — and it says PASS rather
# than saying it cannot tell.
#
# Measured on a fully-fixed tree (your-org/nexus-code#979 F2): run the recipe,
# omit `git add -A`, and this gate returns 0 while the tree `git write-tree`
# produces carries 512 leaking files. The documented remedy was a README line,
# and a documented step that silently ships 512 unscrubbed files when skipped —
# on a surface whose failure mode is a PERMANENT PUBLIC DISCLOSURE — is not a
# remedy. Nothing here depends on operator judgement, so it is mechanical.
#
# `--allow-unstaged` is for the legitimate other caller: a test or an operator
# deliberately scanning a working copy that is not bound for publication. It
# says so loudly, so the two cases never share a spelling.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # `git diff --quiet` compares the INDEX against the WORKING TREE, which is
    # exactly the disagreement that matters. NOT `--cached`: that compares the
    # index against HEAD, and after a correct `git add -A` of a scrubbed tree
    # those differ by the entire scrub — checking it refuses the right answer.
    if ! git diff --quiet 2>/dev/null; then
        if [ "$ALLOW_UNSTAGED" -eq 1 ]; then
            echo "leak-gate: NOTE — index and working tree differ; this verdict covers the WORKING TREE only, not what \`git write-tree\` would record." >&2
        else
            echo "LEAK GATE: REFUSED — the index and the working tree disagree." >&2
            echo "  This gate reads the working tree; the publish path (git write-tree) reads the index." >&2
            echo "  A PASS here would describe a tree that is not the one you would ship." >&2
            echo "  If you are publishing:      git add -A   (then re-run this gate)" >&2
            echo "  If you are scanning a copy: re-run with --allow-unstaged" >&2
            exit 5
        fi
    fi
fi

DENY=$(awk -F'\t' '$1=="deny"{print $2}' "$MAP" | paste -sd'|')
KEEP=$(awk -F'\t' '$1=="keep"{print $2}' "$MAP" | paste -sd'|')
[ -n "$DENY" ] || { echo "leak-gate: empty denylist in $MAP" >&2; exit 2; }

# Dictionary guard: the `exclude` paths hold the ONE un-scrubbed copy of the
# internal dictionary (it names every source identifier by design). It must
# never appear in a tree bound for publication. build.sh drops it; this is the
# independent second check so the gate catches a leaked dictionary even when run
# on a hand-assembled tree. (your-org/nexus-code#537)
excl_present=0
while IFS= read -r ex; do
    [ -n "$ex" ] || continue
    if [ -e "$ex" ]; then
        echo "LEAK GATE: FAIL — excluded internal-dictionary path present: $ex"
        excl_present=$((excl_present+1))
    fi
done < <(awk -F'\t' '$1=="exclude"{print $2}' "$MAP")
[ "$excl_present" -eq 0 ] || exit 1

# PATH check. `git grep` reads file CONTENTS; a denied identifier sitting in a
# file NAME was invisible to this gate entirely, and the only thing keeping such
# names off the mirror was an operator remembering to rename by hand. Found by a
# mutant: deleting a `rename` row from the build's rename manifest left the
# abbreviation in two basenames and every check stayed green.
# (your-org/nexus-code#979 §2)
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    path_hits=$(git ls-files | grep -inE "$DENY" 2>/dev/null)
else
    path_hits=$(find . -path ./.git -prune -o -type f -print 2>/dev/null | grep -inE "$DENY" 2>/dev/null)
fi
[ -n "$KEEP" ] && path_hits=$(printf '%s\n' "$path_hits" | grep -vE "$KEEP")
path_hits=$(printf '%s\n' "$path_hits" | sed '/^$/d')
if [ -n "$path_hits" ]; then
    echo "LEAK GATE: FAIL — denied token in a file PATH (rename it; contents are not the only surface)"
    printf '%s\n' "$path_hits"
    exit 1
fi

# ---- EVERY PUBLISHED BYTE, NOT EVERY BYTE `git grep` HAPPENS TO READ --------
#
# The content scan below is `git grep`, which reads the working tree's REGULAR
# files. The publish path is `git write-tree`, which records EVERY index entry
# — including entries whose content `git grep` never opens. A tracked SYMLINK
# is the live instance: its blob content IS its target path, `git write-tree`
# publishes that blob verbatim, and BOTH `git grep` and `git grep --cached`
# return nothing for it. Measured on a synthetic dictionary: a link whose
# target carried a denied token passed this gate clean, printed
# "PASS — zero denied tokens", and the published blob still read the denied
# path. Three defensible choices lined up to produce it — build.sh skips
# symlinks (writing through one corrupts its target), this gate's PATH check
# reads only the link's own NAME, and git grep does not read symlink content.
# (your-org/nexus-code#1294)
#
# Keyed on the PROPERTY — *can this gate READ the bytes this entry publishes?*
# — and NOT on a file-type enumeration, so the next object type git learns to
# record is a REFUSAL rather than a silent pass. That makes this an ALLOWLIST
# of modes whose content is demonstrably scanned, with a default-DENY arm. The
# arms are literal equality over disjoint mode values, so no SAFE arm can
# shadow the DENY arm and no reordering changes the verdict
# (your-org/nexus-code#1121).
#
#   100644 / 100755  regular blob   -> read by the `git grep` below. Binary
#                                      files included: without `-I` git grep
#                                      reports "Binary file X matches", which
#                                      lands in $hits. Do NOT add `-I`.
#   120000           symlink        -> git grep reads NOTHING. Scanned here,
#                                      directly against the blob.
#   anything else    (160000 gitlink, or a mode that does not exist yet)
#                                   -> REFUSED. A submodule's content is not in
#                                      this tree at all and cannot be vouched
#                                      for from here.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    sym_hits=""
    unreadable=""
    while IFS= read -r _ent; do
        [ -n "$_ent" ] || continue
        # `git ls-files -s` prints: <mode> SP <sha> SP <stage> TAB <path>
        _mode=${_ent%% *}
        _rest=${_ent#* }
        _sha=${_rest%% *}
        _path=${_ent#*$'\t'}
        case "$_mode" in
            100644|100755) : ;;
            120000)
                # A symlink's blob content IS its target path. Read the blob,
                # not the link: following the link would read the TARGET FILE,
                # which is a different question and is not what gets published.
                if ! _tgt=$(git cat-file blob "$_sha" 2>/dev/null); then
                    unreadable="${unreadable}${_path}	mode=${_mode} blob=${_sha} (unreadable)
"
                elif grep -qiE "$DENY" <<<"$_tgt"; then
                    sym_hits="${sym_hits}${_path} -> ${_tgt}
"
                fi
                ;;
            *)
                unreadable="${unreadable}${_path}	mode=${_mode} (content not scannable by this gate)
"
                ;;
        esac
    done < <(git ls-files -s)

    [ -n "$KEEP" ] && sym_hits=$(printf '%s\n' "$sym_hits" | grep -vE "$KEEP")
    sym_hits=$(printf '%s\n' "$sym_hits" | sed '/^$/d')
    if [ -n "$sym_hits" ]; then
        echo "LEAK GATE: FAIL — denied token in a tracked SYMLINK TARGET"
        echo "  (git write-tree publishes a symlink's blob verbatim, and that blob IS this path)"
        printf '%s\n' "$sym_hits"
        exit 1
    fi

    unreadable=$(printf '%s\n' "$unreadable" | sed '/^$/d')
    if [ -n "$unreadable" ]; then
        echo "LEAK GATE: REFUSED — the index holds entries whose published content this gate cannot read." >&2
        printf '%s\n' "$unreadable" >&2
        echo "  A PASS here would be a claim about a SMALLER population than the one being published." >&2
        echo "  Teach this gate to read the mode, or drop the entry from the tree before publishing." >&2
        exit 6
    fi
else
    # NON-GIT TREE — the fallback the other two checks already have
    # (your-org/nexus-code#1294, reopened). Both the PATH check above and the
    # CONTENT check below fall back to `find`/`grep -r` when there is no index,
    # because a hand-assembled tree is a SUPPORTED mode of this gate and its
    # own comments say so. The symlink check had no such arm, so in exactly
    # that mode it scanned file NAMES and file CONTENTS and silently skipped
    # symlink TARGETS — #1294's hole, surviving inside #1294's own fix.
    #
    # Latent rather than live: no in-tree caller runs this gate outside a git
    # checkout today. Restored rather than declared out of scope, because an
    # asymmetry between three checks in one file is not a scope decision anyone
    # made — and the direction is the bad one, a silently smaller population
    # under a clean verdict.
    #
    # WHAT THIS ARM CANNOT DO, said rather than implied: with no index there
    # are no MODES to partition, so the exit-6 "cannot read this entry"
    # refusal has no analogue here. A non-git tree therefore gets symlink
    # coverage but NOT the unreadable-mode guarantee. That is a real gap in a
    # mode nothing currently uses; it is written down so the next reader does
    # not have to re-derive which half is missing.
    sym_hits=$(find . -path ./.git -prune -o -type l -print 2>/dev/null \
        | while IFS= read -r _l; do
              [ -n "$_l" ] || continue
              printf '%s -> %s\n' "$_l" "$(readlink "$_l" 2>/dev/null)"
          done | grep -inE "$DENY" 2>/dev/null)
    [ -n "$KEEP" ] && sym_hits=$(printf '%s\n' "$sym_hits" | grep -vE "$KEEP")
    sym_hits=$(printf '%s\n' "$sym_hits" | sed '/^$/d')
    if [ -n "$sym_hits" ]; then
        echo "LEAK GATE: FAIL — denied token in a SYMLINK TARGET (non-git tree)"
        echo "  (the link's target path is the byte sequence a publish would carry)"
        printf '%s\n' "$sym_hits"
        exit 1
    fi
fi

hits=$(git grep -inE "$DENY" -- . 2>/dev/null)
# also scan any file present but untracked (a hand-assembled tree may not be a
# git checkout); fall back to a plain recursive grep when git-grep finds nothing
if [ -z "$hits" ] && ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    hits=$(grep -rinE "$DENY" --exclude-dir=.git . 2>/dev/null)
fi
[ -n "$KEEP" ] && hits=$(printf '%s\n' "$hits" | grep -vE "$KEEP")
hits=$(printf '%s\n' "$hits" | sed '/^$/d')

if [ -n "$hits" ]; then
    echo "LEAK GATE: FAIL"
    printf '%s\n' "$hits"
    exit 1
fi
echo "LEAK GATE: PASS — zero denied tokens (keep-list applied)"
exit 0
