#!/usr/bin/env bash
# calibrate-pressure-thresholds.sh — recheck the activity-pressure tier
# breakpoints in `skills/nexus.window-cleanup` against the workspace's
# observed `workspace: ...` prelude distribution.
#
# Read every emit archived under `monitor/.state/diffs/*.md`, extract
# the prelude line introduced by PR #73 ("workspace: N busy | N idle |
# N retained | ..."), and print:
#
#   1. A per-axis distribution (min, p10, p25, p50, p75, p90, p95, max,
#      mean).
#   2. The current skill thresholds (hardcoded reference).
#   3. Suggested thresholds derived from observed percentiles
#      (p75 → moderate floor, p90 → high floor).
#   4. A drift verdict per tier-boundary, flagging REVISE when the gap
#      between observed percentile and skill threshold is ≥ DRIFT_DELTA
#      (default 2).
#
# Tracking issue: your-org/nexus-code#79. The calibration analysis is
# only meaningful after ~2 weeks of post-#73 data accumulates — until
# then the script is preposition: invoke it the moment data exists.
#
# Parser shape: each `|`-segment is treated as a `<int> <label>` pair
# and matched into a fixed set of known labels — `busy`, `idle`,
# `retained`, `idle-too-long`, `pane-absent`, `over-limit` (issue #87),
# `awaiting-input` (issue #76). The earlier "exactly-5-segments" gate
# (issue #94) silently dropped every modern prelude because PRs #84
# and #90 widened the prelude to 7 segments. Labelled parsing survives
# future axis additions without recompile.
#
# Usage:
#   monitor/calibrate-pressure-thresholds.sh [--diffs-dir PATH]
#                                            [--since YYYY-MM-DD]
#                                            [--until YYYY-MM-DD]
#                                            [--drift-delta N]
#                                            [--raw]
#                                            [--fail-on-zero-rows]
#
# Flags:
#   --diffs-dir PATH    Override the archive dir. Default:
#                       $NEXUS_ROOT/monitor/.state/diffs or, if NEXUS_ROOT
#                       is unset, the path computed relative to this
#                       script.
#   --since YYYY-MM-DD  Lexicographic filename filter (UTC date prefix).
#   --until YYYY-MM-DD  Same, upper bound (exclusive on the next day at
#                       00:00 UTC — i.e. `--until 2026-06-01` includes
#                       all of 2026-05-31).
#   --drift-delta N     Absolute count gap that triggers a "REVISE"
#                       verdict. Default 2.
#   --raw               Emit per-sample TSV (header:
#                       `busy idle retained idle-too-long pane-absent
#                        over-limit awaiting-input file`) on stdout
#                       instead of the human report. Useful for
#                       downstream pandas / awk inspection.
#   --fail-on-zero-rows Exit 4 if zero prelude rows parse out of the
#                       archive. Self-guard for cron-driven recalibration
#                       jobs: the silent-drop regression in issue #94
#                       went unnoticed because the script returned exit
#                       0 with no rows. Opt-in to preserve backwards
#                       compatibility — interactive runs before data
#                       accumulates should not page.
#
# Exit codes:
#   0  report (or raw TSV) printed; "samples: 0" is still exit 0 so
#      cron-driven recalibration jobs don't false-alarm before data
#      accumulates (unless --fail-on-zero-rows is set).
#   2  bad usage.
#   3  diffs dir does not exist.
#   4  zero rows parsed and --fail-on-zero-rows was set.

set -uo pipefail

usage() {
    sed -n '4,69p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit "${1:-2}"
}

DIFFS_DIR=""
SINCE=""
UNTIL=""
DRIFT_DELTA=2
RAW=0
FAIL_ON_ZERO=0

while (( $# > 0 )); do
    case "$1" in
        --diffs-dir)         DIFFS_DIR="${2:-}"; shift 2 ;;
        --since)             SINCE="${2:-}"; shift 2 ;;
        --until)             UNTIL="${2:-}"; shift 2 ;;
        --drift-delta)       DRIFT_DELTA="${2:-2}"; shift 2 ;;
        --raw)               RAW=1; shift ;;
        --fail-on-zero-rows) FAIL_ON_ZERO=1; shift ;;
        -h|--help)           usage 0 ;;
        *)                   printf 'unknown arg: %q\n' "$1" >&2; usage ;;
    esac
done

# Resolve diffs dir.
if [[ -z "$DIFFS_DIR" ]]; then
    if [[ -n "${NEXUS_ROOT:-}" && -d "$NEXUS_ROOT/monitor/.state/diffs" ]]; then
        DIFFS_DIR="$NEXUS_ROOT/monitor/.state/diffs"
    else
        _self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
        DIFFS_DIR="$_self_dir/.state/diffs"
    fi
fi

if [[ ! -d "$DIFFS_DIR" ]]; then
    printf 'calibrate-pressure-thresholds: diffs dir does not exist: %s\n' "$DIFFS_DIR" >&2
    exit 3
fi

# Validate --drift-delta as a non-negative integer.
if ! [[ "$DRIFT_DELTA" =~ ^[0-9]+$ ]]; then
    printf 'calibrate-pressure-thresholds: --drift-delta must be a non-negative integer, got %q\n' "$DRIFT_DELTA" >&2
    exit 2
fi

# Validate --since / --until shape (only if provided). YYYY-MM-DD.
for v in SINCE UNTIL; do
    val="${!v}"
    [[ -z "$val" ]] && continue
    if ! [[ "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        printf 'calibrate-pressure-thresholds: --%s must be YYYY-MM-DD, got %q\n' "$(tr '[:upper:]' '[:lower:]' <<<"$v")" "$val" >&2
        exit 2
    fi
done

# Build the file list. Filenames are
# `YYYY-MM-DD_HH-MM-SS_<id>[_tag].md` (UTC, sortable lexicographically).
# `--since DATE` keeps files whose basename ≥ DATE; `--until DATE` keeps
# files whose basename < DATE+1day. We compute DATE+1day by adding to
# the day field; simpler than coreutils gymnastics and adequate for
# month-end (lexicographic compare against `2026-06-00` rejects nothing
# legitimately ≤ 2026-05-31_23-59-59).
filter_file() {
    local base="$1"
    if [[ -n "$SINCE" && "$base" < "$SINCE" ]]; then
        return 1
    fi
    if [[ -n "$UNTIL" ]]; then
        # Compute exclusive upper bound: UNTIL_PLUS = UNTIL with day+1.
        # We rely on `date -u -d "$UNTIL + 1 day"` if available; fall
        # back to a naïve string for portability.
        local until_plus
        until_plus=$(date -u -d "$UNTIL + 1 day" +%Y-%m-%d 2>/dev/null) \
            || until_plus="$UNTIL~"  # `~` > any digit lexicographically
        if [[ "$base" > "$until_plus" || "$base" == "$until_plus"* ]]; then
            return 1
        fi
    fi
    return 0
}

# Collect prelude rows. Each row: TSV of (busy, idle, retained,
# idle-too-long, pane-absent, over-limit, awaiting-input, basename).
# Pre-#84 diffs report 5 axes; #84 added awaiting-input; #87 added
# over-limit. Missing axes fill 0. Skip files with no prelude (pre-#73
# diffs have none) or with any required core axis missing.
tmp_rows=$(mktemp)
trap 'rm -f "$tmp_rows"' EXIT

# Required core labels (5-axis lineage). A row missing any of these is
# malformed and silently skipped. The two later additions are optional;
# rows without them get 0 in those columns.
CORE_LABELS=(busy idle retained idle-too-long pane-absent)
OPTIONAL_LABELS=(over-limit awaiting-input)

while IFS= read -r -d '' f; do
    base=$(basename "$f")
    filter_file "$base" || continue
    # First line starting with "workspace: " is the prelude. `grep -m1`
    # bails early — most emits have the prelude in the first 2-3 lines.
    line=$(grep -m1 '^workspace: ' "$f" 2>/dev/null || true)
    [[ -n "$line" ]] || continue
    # Strip leading "workspace: " then split on " | ".
    body="${line#workspace: }"
    # Expected shape: "<n> busy | <n> idle | ..." with `>= 5` segments.
    # Parse each segment as "<int> <label>" so the script is stable
    # across future axis additions (issue #94).
    IFS='|' read -ra parts <<<"$body"
    (( ${#parts[@]} >= 5 )) || continue
    declare -A row_counts=()
    parse_ok=1
    for p in "${parts[@]}"; do
        # Trim leading/trailing whitespace.
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        n="${p%% *}"
        lbl="${p#"$n"}"
        lbl="${lbl#"${lbl%%[![:space:]]*}"}"
        if [[ -z "$lbl" ]] || ! [[ "$n" =~ ^[0-9]+$ ]]; then
            parse_ok=0
            break
        fi
        row_counts[$lbl]="$n"
    done
    (( parse_ok == 1 )) || continue
    # Ensure all core labels are present; missing optional labels → 0.
    have_core=1
    for lbl in "${CORE_LABELS[@]}"; do
        [[ -v row_counts[$lbl] ]] || { have_core=0; break; }
    done
    (( have_core == 1 )) || continue
    for lbl in "${OPTIONAL_LABELS[@]}"; do
        [[ -v row_counts[$lbl] ]] || row_counts[$lbl]=0
    done
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${row_counts[busy]}" "${row_counts[idle]}" "${row_counts[retained]}" \
        "${row_counts[idle-too-long]}" "${row_counts[pane-absent]}" \
        "${row_counts[over-limit]}" "${row_counts[awaiting-input]}" \
        "$base" \
        >> "$tmp_rows"
    unset row_counts
done < <(find "$DIFFS_DIR" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)

n_samples=$(wc -l < "$tmp_rows")
n_samples=${n_samples// /}

if (( RAW == 1 )); then
    if (( n_samples == 0 && FAIL_ON_ZERO == 1 )); then
        printf 'calibrate-pressure-thresholds: zero rows parsed (--fail-on-zero-rows)\n' >&2
        exit 4
    fi
    printf 'busy\tidle\tretained\tidle-too-long\tpane-absent\tover-limit\tawaiting-input\tfile\n'
    cat "$tmp_rows"
    exit 0
fi

# Span: first and last basename (chronological because filenames are
# UTC-sorted). Since `find` doesn't guarantee order, sort here. The
# basename is the LAST column of the TSV (column 8 post-#94 widening).
if (( n_samples > 0 )); then
    sorted=$(sort "$tmp_rows")
    first_file=$(printf '%s\n' "$sorted" | head -1 | awk -F'\t' '{print $NF}')
    last_file=$(printf '%s\n' "$sorted"  | tail -1 | awk -F'\t' '{print $NF}')
    # Basenames are sortable but the YYYY-MM-DD prefix is what we want
    # for the human-readable span.
    span_first="${first_file%%_*}"
    span_last="${last_file%%_*}"
else
    span_first=""
    span_last=""
fi

# Helper: compute the named percentiles for one column (1-indexed)
# of $tmp_rows, plus mean. Echo `min p10 p25 p50 p75 p90 p95 max mean`
# space-separated, integers (round mean to nearest).
column_stats() {
    local col="$1"
    awk -F'\t' -v col="$col" '
        NF >= col { v[NR] = $col + 0; sum += $col + 0; n++ }
        END {
            if (n == 0) { print "0 0 0 0 0 0 0 0 0"; exit }
            # Sort ascending.
            for (i = 1; i <= n; i++) for (j = i+1; j <= n; j++) {
                if (v[i] > v[j]) { t = v[i]; v[i] = v[j]; v[j] = t }
            }
            # R-7 percentile: rank = q * (n-1); interpolate between
            # v[floor(rank)+1] and v[ceil(rank)+1] (awk is 1-indexed).
            split("0.10 0.25 0.50 0.75 0.90 0.95", qs, " ")
            mn = v[1]; mx = v[n]
            out = mn
            for (k = 1; k <= 6; k++) {
                q = qs[k]
                r = q * (n - 1)
                lo = int(r); hi = lo + 1
                if (hi >= n) hi = n - 1
                frac = r - lo
                vq = v[lo+1] + frac * (v[hi+1] - v[lo+1])
                # Round to nearest integer.
                vq_i = int(vq + 0.5)
                out = out " " vq_i
            }
            mean = sum / n
            out = out " " mx " " int(mean + 0.5)
            print out
        }
    ' "$tmp_rows"
}

# Print one stat row aligned. Header columns: min p10 p25 p50 p75 p90 p95 max mean.
print_stat_row() {
    local axis="$1" stats="$2"
    # shellcheck disable=SC2086  # intentional word split on stats
    set -- $stats
    printf '  %-15s  %4s %4s %4s %4s %4s %4s %4s %4s   %4s\n' \
        "$axis" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

# Hardcoded skill thresholds — keep in sync with
# `skills/nexus.window-cleanup` "Activity-aware retention pressure".
SKILL_BUSY_LOW=3        # ≤ this = low
SKILL_BUSY_HIGH=7       # ≥ this = high
SKILL_RETAINED_LOW=5    # ≤ this = low
SKILL_RETAINED_HIGH=10  # ≥ this = high

# Drift verdict for one boundary. Args: label, skill_value, observed_pctile.
# Echoes a single line with PASS / REVISE based on |skill - obs| vs DRIFT_DELTA.
verdict_line() {
    local label="$1" skill="$2" obs="$3"
    local diff=$(( skill - obs ))
    (( diff < 0 )) && diff=$(( -diff ))
    local mark
    if (( diff >= DRIFT_DELTA )); then
        mark="REVISE"
    else
        mark="OK"
    fi
    printf '  %-25s  skill=%-3d  observed=%-3d  diff=%-3d  %s\n' \
        "$label" "$skill" "$obs" "$diff" "$mark"
}

# ---- Human-readable report ----

echo "=== activity-pressure threshold calibration ==="
printf 'source:  %s\n' "$DIFFS_DIR"
if [[ -n "$SINCE$UNTIL" ]]; then
    printf 'window:  %s .. %s\n' "${SINCE:-(start)}" "${UNTIL:-(end)}"
fi
printf 'samples: %d\n' "$n_samples"

if (( n_samples == 0 )); then
    cat <<'NOTE'

No `workspace: ...` prelude lines in the archive yet. The prelude
landed in PR #73; the calibration analysis becomes meaningful after
~2 weeks of post-merge operation. Try again then, or expand --since.
NOTE
    if (( FAIL_ON_ZERO == 1 )); then
        printf 'calibrate-pressure-thresholds: zero rows parsed (--fail-on-zero-rows)\n' >&2
        exit 4
    fi
    exit 0
fi

printf 'span:    %s .. %s\n' "$span_first" "$span_last"
echo

echo 'distribution per axis:'
printf '  %-15s  %4s %4s %4s %4s %4s %4s %4s %4s   %4s\n' \
    'axis' 'min' 'p10' 'p25' 'p50' 'p75' 'p90' 'p95' 'max' 'mean'

busy_stats=$(column_stats 1)
idle_stats=$(column_stats 2)
retained_stats=$(column_stats 3)
itl_stats=$(column_stats 4)
absent_stats=$(column_stats 5)
overlimit_stats=$(column_stats 6)
awaiting_stats=$(column_stats 7)

print_stat_row 'busy'            "$busy_stats"
print_stat_row 'idle'            "$idle_stats"
print_stat_row 'retained'        "$retained_stats"
print_stat_row 'idle-too-long'   "$itl_stats"
print_stat_row 'pane-absent'     "$absent_stats"
print_stat_row 'over-limit'      "$overlimit_stats"
print_stat_row 'awaiting-input'  "$awaiting_stats"

# Pull p75 / p90 for the drift comparison. Column indices in the
# stats string: min(1) p10(2) p25(3) p50(4) p75(5) p90(6) p95(7) max(8) mean(9).
busy_p75=$(awk '{print $5}' <<<"$busy_stats")
busy_p90=$(awk '{print $6}' <<<"$busy_stats")
retained_p75=$(awk '{print $5}' <<<"$retained_stats")
retained_p90=$(awk '{print $6}' <<<"$retained_stats")

cat <<EOF

current skill thresholds (skills/nexus.window-cleanup):
  busy:      low ≤ ${SKILL_BUSY_LOW}    moderate $((SKILL_BUSY_LOW + 1))–$((SKILL_BUSY_HIGH - 1))   high ≥ ${SKILL_BUSY_HIGH}
  retained:  low ≤ ${SKILL_RETAINED_LOW}    moderate $((SKILL_RETAINED_LOW + 1))–${SKILL_RETAINED_HIGH}  high ≥ ${SKILL_RETAINED_HIGH}

drift verdict (REVISE if |skill - observed| ≥ ${DRIFT_DELTA}):
EOF
verdicts=$(
    verdict_line 'busy moderate floor'     "$SKILL_BUSY_LOW"      "$busy_p75"
    verdict_line 'busy high floor'         "$SKILL_BUSY_HIGH"     "$busy_p90"
    verdict_line 'retained moderate floor' "$SKILL_RETAINED_LOW"  "$retained_p75"
    verdict_line 'retained high floor'     "$SKILL_RETAINED_HIGH" "$retained_p90"
)
printf '%s\n' "$verdicts"

# Final hint.
if grep -q 'REVISE' <<<"$verdicts"; then
    cat <<'EOF'

At least one tier-boundary diverged from observed reality. Consider
revising `skills/nexus.window-cleanup` "Activity-aware retention
pressure" so the prose tiers match the workspace's actual operating
regime. The numbers above are the natural floor candidates (p75 for
the moderate boundary, p90 for the high boundary).
EOF
else
    cat <<'EOF'

All tier boundaries match observed reality within the drift tolerance.
No skill revision indicated.
EOF
fi
