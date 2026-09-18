#!/usr/bin/env bash
# monitor/cc-surface-dedup.sh — "is this verdict NEWS?" for the cc-update
# evaluator's issue comments (your-org/nexus-code#1529).
#
# THE DEFECT. One operator's evaluator posted 24 comments on one tracking
# issue, the last ~100 lines of arm tables, to say the same thing it had said
# the day before: the clone is behind, pull it. A daily repeat of an unchanged
# verdict is noise, and noise is where the one comment that matters goes
# unread. The prompt now says: if the verdict, the candidate and the rendered
# comment are unchanged since the last comment, do not post. This script is what makes
# "unchanged" a measurement instead of a recollection — an agent's memory of
# what it posted yesterday does not survive its own respawn.
#
# Usage:
#   cc-surface-dedup.sh check  --state-dir D --candidate C --verdict V \
#                              --body-file F [--nexus-root R]
#       (F = the RENDERED comment body the evaluator is about to post)
#       rc 0   NEW — post the comment (and then `record` it)
#       rc 12  UNCHANGED — the same fingerprint was recorded; prints when and
#              where it was posted. Do not post; say so in the report.
#       rc 2   usage
#       rc 3   COULD NOT FINGERPRINT (body file missing/empty, live HEAD
#              unreadable). POST — a failed dedup never silences a finding.
#   cc-surface-dedup.sh record --state-dir D --candidate C --verdict V \
#                              --body-file F [--posted URL] [--nexus-root R]
#       rc 0   the record was written (and is printed); rc 3 write failed
#   cc-surface-dedup.sh show   --state-dir D
#       prints the record, rc 0; rc 1 when there is none
#
# WHAT IS FINGERPRINTED, so the reader knows what "unchanged" means:
#   verdict, candidate, the live clone's HEAD (read here, `git rev-parse` —
#   the classifier that produced the verdict IS that tree, so a pulled clone
#   is a new input by construction), and the bytes of --body-file — the
#   RENDERED comment body the evaluator is about to post — with trailing
#   whitespace and blank lines removed. So "unchanged" means the reader
#   would see nothing new: a different block reason, a different changelog
#   disposition, a different scenario table is a new comment by
#   construction (w241sk F4: a first cut fingerprinted only the gate lines
#   and silenced a block whose reason had changed). The prompt keeps dates,
#   run ids and log paths OUT of the body, or nothing ever dedups. The
#   behind-count ("N commits behind", `behind_integration=N`) is normalised
#   before hashing: the margin moving is not news (w241sk D5).
#
# READ-ONLY on the repository: `git rev-parse HEAD` is the only git call.
# The record lives beside the routine's other state:
#   <state-dir>/cc-auto-update/last-surface
#     candidate=… verdict=… fingerprint=… date=… posted=… live_head=…

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() { sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

verb="${1:-}"; [[ -n "$verb" ]] || usage; shift
state_dir="" candidate="" verdict="" body="" posted="-" nexus_root="${NEXUS_ROOT:-}"
while (( $# > 0 )); do
    case "$1" in
        --state-dir)   state_dir="${2:-}"; shift 2 ;;
        --candidate)   candidate="${2:-}"; shift 2 ;;
        --verdict)     verdict="${2:-}"; shift 2 ;;
        --body-file) body="${2:-}"; shift 2 ;;
        --posted)      posted="${2:-}"; shift 2 ;;
        --nexus-root)  nexus_root="${2:-}"; shift 2 ;;
        -h|--help)     usage ;;
        *) printf 'cc-surface-dedup: unknown argument %s\n' "$1" >&2; usage ;;
    esac
done
[[ -n "$state_dir" ]] || { printf 'cc-surface-dedup: --state-dir required\n' >&2; usage; }
[[ -n "$nexus_root" ]] || nexus_root=$(cd "$_self_dir/.." && pwd)
record="$state_dir/cc-auto-update/last-surface"

_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }

case "$verb" in
    show)
        [[ -r "$record" ]] || { printf 'cc-surface-dedup: no record at %s\n' "$record" >&2; exit 1; }
        cat "$record"; exit 0 ;;
    check|record) ;;
    *) printf 'cc-surface-dedup: unknown verb %s\n' "$verb" >&2; usage ;;
esac

[[ -n "$candidate" && -n "$verdict" && -n "$body" ]] \
    || { printf 'cc-surface-dedup: %s needs --candidate, --verdict and --body-file\n' "$verb" >&2; usage; }

# ---- fingerprint: refuse rather than guess ---------------------------------
if [[ ! -r "$body" ]]; then
    printf 'cc-surface-dedup: COULD NOT FINGERPRINT — body file %s is missing or unreadable; post, and say so\n' "$body" >&2
    exit 3
fi
# The MARGIN is not news (w241sk D5): "N commits behind" grows most days as
# the integration branch advances, and a fingerprint that moves with it
# re-posts the exact case the dedup exists for (24 comments saying "behind,
# pull it"). The count is normalised to N before hashing; the verdict, the
# scenario set, the reason and the ref are what make a comment new. Only the
# margin's spellings are normalised — a scenario tally like "7/8" is not.
norm=$(sed -E -e 's/[[:space:]]*$//' -e '/^$/d' \
              -e 's/[0-9]+ commit(s)? behind/N commits behind/g' \
              -e 's/behind_integration=[0-9]+/behind_integration=N/g' "$body")
if [[ -z "$norm" ]]; then
    printf 'cc-surface-dedup: COULD NOT FINGERPRINT — body file %s is empty; write the comment body first, or post without dedup\n' "$body" >&2
    exit 3
fi
live_head=$(git -C "$nexus_root" rev-parse HEAD 2>/dev/null) || live_head=""
if [[ ! "$live_head" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'cc-surface-dedup: COULD NOT FINGERPRINT — live HEAD of %s unreadable; post, and say so\n' "$nexus_root" >&2
    exit 3
fi
fp=$(printf 'verdict=%s\ncandidate=%s\nlive_head=%s\n%s\n' "$verdict" "$candidate" "$live_head" "$norm" \
     | sha256sum | awk '{print $1}')
[[ "$fp" =~ ^[0-9a-f]{64}$ ]] || { printf 'cc-surface-dedup: COULD NOT FINGERPRINT — sha256sum failed\n' >&2; exit 3; }

case "$verb" in
    check)
        if [[ -r "$record" ]] && [[ "$(_field "$record" fingerprint)" == "$fp" ]]; then
            printf 'UNCHANGED since %s (posted %s): verdict=%s candidate=%s live_head=%.12s — do not re-post\n' \
                "$(_field "$record" date)" "$(_field "$record" posted)" "$verdict" "$candidate" "$live_head"
            exit 12
        fi
        if [[ -r "$record" ]]; then
            printf 'NEW (last record: verdict=%s candidate=%s live_head=%.12s on %s): post, then record\n' \
                "$(_field "$record" verdict)" "$(_field "$record" candidate)" "$(_field "$record" live_head)" "$(_field "$record" date)"
        else
            printf 'NEW (no prior record): post, then record\n'
        fi
        exit 0 ;;
    record)
        mkdir -p "$(dirname "$record")" 2>/dev/null || true
        tmp="$record.tmp.$$"
        if {
            printf 'candidate=%s\n'   "$candidate"
            printf 'verdict=%s\n'     "$verdict"
            printf 'fingerprint=%s\n' "$fp"
            printf 'live_head=%s\n'   "$live_head"
            printf 'date=%s\n'        "$(date -Is 2>/dev/null || echo unknown)"
            printf 'posted=%s\n'      "$posted"
        } > "$tmp" 2>/dev/null && mv -f "$tmp" "$record" 2>/dev/null; then
            cat "$record"; exit 0
        fi
        rm -f "$tmp" 2>/dev/null || true
        printf 'cc-surface-dedup: record: write to %s did NOT land\n' "$record" >&2
        exit 3 ;;
esac
