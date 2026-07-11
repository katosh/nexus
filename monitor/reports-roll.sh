#!/usr/bin/env bash
# reports-roll.sh — time-partition the flat reports/ dir into monthly
# archive subdirs, keeping recent months FLAT behind a ≥1-month safety
# buffer.
#
# WHY (issue #444, operator constraint on PR #443): the flat reports/
# dir grows unbounded (~300–900 reports/month). Every HOT-PATH consumer
# is recency-oriented and reads only the flat dir with `-maxdepth 1`, so
# it needs no change as long as recent reports stay flat. Only the bulk
# historical consumer (nexus.infra-review) must recurse into the buckets.
#
# THE LOAD-BEARING RULE — a ≥1-month safety buffer. A report is eligible
# to roll ONLY if it was created strictly BEFORE the first day of the
# PREVIOUS month. Equivalently: roll iff the report's YYYY-MM is strictly
# less than the previous month's YYYY-MM. So the CURRENT month AND the
# trailing (previous) month always stay flat in reports/. This guarantees
# an in-flight worker whose report is being read/appended (or resolved by
# `_idle_resolve_report_path` / `ng report-check` / `ng wrap-up`) NEVER
# has its file moved out from under it — those files are days old at most,
# comfortably inside the buffer.
#
#   today            keep flat            roll into reports/YYYY-MM/
#   2026-07-07  →    2026-07, 2026-06  →  2026-05 and older
#
# Each rolled report goes into reports/<YYYY-MM>/ bucketed by the report's
# OWN date (parsed from the filename, frontmatter as fallback). The roller
# is idempotent and safe to re-run: it only ever inspects TOP-LEVEL
# reports/*.md, never descends into buckets, and never overwrites an
# existing destination.
#
# Usage:
#   monitor/reports-roll.sh [options]
#   monitor/ng reports-roll  [options]
#
# Options:
#   --reports-dir <path>   Reports dir to operate on. Default: resolved
#                          like `ng report-init` ($NEXUS_ROOT/reports, else
#                          walk up from cwd for a reports/ sibling, else
#                          ./reports).
#   --dry-run              Print what WOULD move; touch nothing.
#   --now [YYYY-MM-DD]     With a date, treat it as "today" when computing the
#                          cutoff (deterministic tests). BARE `--now` means
#                          "roll for right now" = the wall-clock default (so
#                          `ng reports-roll --now --quiet` works verbatim).
#   --quiet                Suppress the per-file "roll" lines; print only
#                          the summary.
#   -h, --help             This help.
#
# Env:
#   REPORTS_ROLL_MIN_AGE_SECONDS   Opt-in mid-write guard (default 0 = off).
#                          When >0, an eligible file modified within that many
#                          seconds is skipped this run and rolled once it
#                          settles. The ≥1-month buffer already makes eligible
#                          files a full month old; this is defense-in-depth for
#                          the automated watcher path.
#
# Exit: 0 on success (including a clean no-op re-run), non-zero on a usage
# error or an unwritable reports dir.

set -uo pipefail

_prog=$(basename "$0")

die() { printf '%s: %s\n' "$_prog" "$*" >&2; exit 1; }

usage() {
    # Print the leading comment block (line 2 → first blank line), same
    # convention as `ng --help`, so the doc above is the single source.
    awk '/^$/{exit} NR>1' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Resolve the reports dir (mirrors ng's _report_reports_dir).
# ---------------------------------------------------------------------------
_resolve_reports_dir() {
    local explicit="${1:-}"
    if [[ -n "$explicit" ]]; then printf '%s' "$explicit"; return 0; fi
    if [[ -n "${NEXUS_ROOT:-}" && -d "$NEXUS_ROOT/reports" ]]; then
        printf '%s' "$NEXUS_ROOT/reports"; return 0
    fi
    local d; d=$(pwd)
    while [[ "$d" != / && -n "$d" ]]; do
        if [[ -d "$d/reports" ]]; then printf '%s' "$d/reports"; return 0; fi
        d=$(dirname "$d")
    done
    printf '%s/reports' "$(pwd)"
}

# ---------------------------------------------------------------------------
# Parse a report's YYYY-MM-DD.
#   1. First `YYYY-MM-DD` token anywhere in the basename (the canonical
#      report filename `<proj>_<YYYY-MM-DD>_<HHMMSS>_<slug>.md` puts it
#      right after the project; legacy `<proj>_<YYYY-MM-DD>_<slug>.md` and
#      date-only `<slug>_<YYYY-MM-DD>.md` also match).
#   2. Fallback: the frontmatter `date:` field (only read when the
#      filename carries no date token — rare, so no per-file stat cost on
#      the common path).
# Emits `YYYY-MM-DD` on stdout and returns 0 when a plausible date is
# found; returns 1 (no output) when none can be determined.
# ---------------------------------------------------------------------------
_parse_report_date() {
    local file="$1" base y mo d
    base=$(basename "$file")
    if [[ "$base" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2}) ]]; then
        y=${BASH_REMATCH[1]}; mo=${BASH_REMATCH[2]}; d=${BASH_REMATCH[3]}
    else
        # Frontmatter fallback — first `date:` line in the leading block.
        local line
        line=$(grep -m1 -E '^date:[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}' "$file" 2>/dev/null)
        if [[ "$line" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2}) ]]; then
            y=${BASH_REMATCH[1]}; mo=${BASH_REMATCH[2]}; d=${BASH_REMATCH[3]}
        else
            return 1
        fi
    fi
    # Validate: month 01–12, day 01–31. Guards the known `2026-00-…`
    # malformed case and anything else absurd — quarantine (leave flat)
    # rather than roll into a bogus `2026-00/` bucket.
    if (( 10#$mo < 1 || 10#$mo > 12 || 10#$d < 1 || 10#$d > 31 )); then
        return 1
    fi
    printf '%s-%s-%s' "$y" "$mo" "$d"
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
reports_dir_arg="" dry_run=0 now_arg="" quiet=0
while (( $# > 0 )); do
    case "$1" in
        --reports-dir) reports_dir_arg="${2:-}"; shift 2 ;;
        --dry-run)     dry_run=1; shift ;;
        --now)
            # Two forms: `--now YYYY-MM-DD` (deterministic tests) consumes the
            # date; a BARE `--now` (the operator's / watcher's
            # `ng reports-roll --now --quiet`) just means "roll for right now"
            # = the wall-clock default, so we leave the next token unconsumed.
            if [[ "${2:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                now_arg="$2"; shift 2
            else
                shift
            fi
            ;;
        --quiet)       quiet=1; shift ;;
        -h|--help)     usage 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

# Belt-and-suspenders atomicity guard (opt-in via REPORTS_ROLL_MIN_AGE_SECONDS,
# default 0 = disabled). When >0, an eligible candidate whose file was modified
# within that many seconds is SKIPPED this run (treated as possibly mid-write)
# and rolled on a later run once it settles. The ≥1-month buffer already makes
# every eligible file at least a full month old, so this never fires in
# practice — it is defense-in-depth for the automated (watcher) path, which
# sets a small positive value. `mv` itself is an atomic same-filesystem rename,
# and a writer holding an open fd keeps writing to the moved inode, so the move
# is safe even without this guard. Default 0 keeps the manual path's behavior
# (and the existing test fixtures, created at mtime=now) unchanged.
min_age=$(( ${REPORTS_ROLL_MIN_AGE_SECONDS:-0} + 0 )) 2>/dev/null || min_age=0
now_epoch=""
if (( min_age > 0 )); then now_epoch=$(date +%s); fi

reports_dir=$(_resolve_reports_dir "$reports_dir_arg")
[[ -d "$reports_dir" ]] || die "reports dir does not exist: $reports_dir"

# ---------------------------------------------------------------------------
# Compute the cutoff: previous month as an integer YYYYMM. Roll iff a
# report's YYYYMM is strictly less than this. The current month and the
# previous month therefore both stay flat — the ≥1-month buffer.
# ---------------------------------------------------------------------------
if [[ -n "$now_arg" ]]; then
    [[ "$now_arg" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] \
        || die "--now must be YYYY-MM-DD (got: $now_arg)"
    ny=${BASH_REMATCH[1]}; nm=${BASH_REMATCH[2]}
    (( 10#$nm >= 1 && 10#$nm <= 12 )) || die "--now month out of range: $now_arg"
else
    ny=$(date +%Y); nm=$(date +%m)
fi
nm=$((10#$nm)); ny=$((10#$ny))
if (( nm == 1 )); then py=$((ny - 1)); pm=12; else py=$ny; pm=$((nm - 1)); fi
cutoff=$(( py * 100 + pm ))   # e.g. 202606 → roll anything strictly older

moved=0 kept=0 collided=0 quarantined=0 inflight=0

# Only TOP-LEVEL *.md files. nullglob so an empty dir is a clean no-op;
# the loop never descends into existing YYYY-MM/ buckets, which is what
# makes a re-run idempotent.
shopt -s nullglob
for f in "$reports_dir"/*.md; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")

    rdate=$(_parse_report_date "$f") || {
        (( quiet )) || printf 'quarantine (no valid date): %s\n' "$base"
        quarantined=$((quarantined + 1))
        continue
    }
    ry=${rdate%%-*}; rest=${rdate#*-}; rm=${rest%%-*}
    ryyyymm=$(( 10#$ry * 100 + 10#$rm ))

    if (( ryyyymm >= cutoff )); then
        kept=$((kept + 1))
        continue
    fi

    # Opt-in mid-write guard: skip an eligible file still being written.
    # Only stats the (pre-buffer) eligible subset, and only when enabled, so
    # it never reintroduces #443's whole-dir per-file stat cost.
    if (( min_age > 0 )); then
        mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        if (( mtime > 0 && now_epoch - mtime < min_age )); then
            (( quiet )) || printf 'skip (modified %ds ago, < %ds): %s\n' \
                "$(( now_epoch - mtime ))" "$min_age" "$base"
            inflight=$((inflight + 1))
            continue
        fi
    fi

    bucket="$reports_dir/${ry}-${rm}"
    dest="$bucket/$base"

    if [[ -e "$dest" ]]; then
        # Idempotent-re-run / collision guard: never clobber. Basename
        # collision across the same month is essentially impossible given
        # HHMMSS + slug, so this is belt-and-suspenders, not expected.
        printf '%s: destination exists, skipping: %s\n' "$_prog" "$dest" >&2
        collided=$((collided + 1))
        continue
    fi

    if (( dry_run )); then
        (( quiet )) || printf 'would roll: %s -> %s/\n' "$base" "${ry}-${rm}"
        moved=$((moved + 1))
        continue
    fi

    mkdir -p "$bucket" || die "could not create bucket: $bucket"
    if mv -n "$f" "$dest"; then
        (( quiet )) || printf 'rolled: %s -> %s/\n' "$base" "${ry}-${rm}"
        moved=$((moved + 1))
    else
        printf '%s: mv failed (left flat): %s\n' "$_prog" "$base" >&2
        collided=$((collided + 1))
    fi
done

verb="rolled"; (( dry_run )) && verb="would roll"
printf '%s: %s %d, kept-flat %d (buffer: %04d-%02d + %04d-%02d), quarantined %d, in-flight %d, skipped %d  [%s]\n' \
    "$_prog" "$verb" "$moved" "$kept" "$py" "$pm" "$ny" "$nm" "$quarantined" "$inflight" "$collided" "$reports_dir"

exit 0
