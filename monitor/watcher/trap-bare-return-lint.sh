#!/usr/bin/env bash
# trap-bare-return-lint.sh — flag every bare `return` inside a function that
# is STATICALLY REACHABLE from a trap handler (your-org/nexus-code#1513, the
# w234 round-1 SIGF finding).
#
# Usage:  bash monitor/watcher/trap-bare-return-lint.sh [--files|--reachable] [--allowlist F] [<repo-root>]
#   default      one row per site:  <file>:<line>\t<function>\t<chain>
#                plus one `ALLOWED\t…` row per allowlisted site and a final
#                `STAT\t…` line; exit 1 if any UNALLOWED site or STALE allowlist
#                row, 0 if none
#   --files      the POPULATION — one path per line, every file this lint reads.
#                The guard's `gp_population` calls THIS rather than keeping a
#                second copy: a second implementation of a population drifts
#                until the index reports, with total confidence, that a guard
#                does not read a file it does read.
#   --census     every function the parser found: <file>\t<function>\t<start>-<end>\t<bare-return lines|->
#                — the audit surface for the parser itself (reconcile it against
#                an independent enumeration before trusting a zero)
#   --reachable  every function the walk REACHES from a trap, with its chain —
#                the potency surface: a lint whose walk reaches nothing is a
#                lint that can never fire, and this is how a suite asserts it
#                still reaches the function the measured defect lived in
#   --allowlist  an alternative allowlist (fixtures); default
#                monitor/watcher/trap-bare-return.allowlist under <repo-root>
#
# Exit: 0 clean; 1 sites or stale allowlist rows; 2 usage; 3 REFUSED — an
# empty population, a file the stripper could not read, a malformed allowlist
# row, or a missing dependency. 3 is not a verdict about the tree: it is the
# lint declining to certify a corpus it did not fully read.
#
# ---------------------------------------------------------------------------
# THE DEFECT
# ---------------------------------------------------------------------------
#
# bash (builtins/return.def, `get_exitstat`): when `return` is executed with
# NO argument while a trap handler is running — in the handler string itself
# or in ANY function the handler calls, however deep — it returns
# `trap_saved_exit_value`: the status of the last command that ran BEFORE the
# trap fired. Not the status of the `[[ … ]]` on the line above it. The manual
# says the same in one sentence ("If return is executed by a trap handler, the
# last command used to determine the status is the last command executed
# before the trap handler").
#
# Measured on bash 4.4.20 (w234, round 1): `cc-restart-watchdog-loop.sh`'s
# marker-ownership predicate — `{ [[ foreign == ours ]]; return; }` — answered
# "not mine" when called directly and "MINE" when called from the TERM trap
# after an interrupted `sleep` (whose status, 0 from the loop's own successful
# `note`, was what the bare `return` reported). The handler then deleted
# ANOTHER claimant's armed marker and silently reopened a single-flight gate.
# The fix was `return 0` / `return 1`, explicit; the SIGF case in
# test-cc-restart-watchdog-verify.sh drives the predicate THROUGH a real signal
# with a must-say-NO marker at the path.
#
# WHY A LINT AND NOT A LIST. The defect is INVISIBLE to every direct-call unit
# test: the same function returns the right answer whenever no trap is
# running. It is also invisible in review, because `[[ … ]]; return` is an
# ordinary idiom that is correct everywhere else. Only two things see it — a
# signal-driven test with a must-say-NO case, and a static walk from the trap
# sites. This file is the second.
#
# ---------------------------------------------------------------------------
# THE POPULATION is EVERY TRACKED SHELL FILE (`git ls-files` over the whole
# repository, filtered by the shared predicate `monitor/shell-files.sh:
# shf_is_shell`), never a filename glob — a `*.sh` pathspec cannot see
# `monitor/ng`, and a call chain can cross from a trap in one file into a
# function in a sourced one, so the walk needs the whole corpus. Tracked-only
# because the allowlist keys on paths the tree carries; an untracked file is
# outside every ratchet here. Comments and heredoc bodies are stripped with the
# shared `shf_strip_comments` before anything is read, because this very file
# documents the defect in its prose.
#
# THE PREDICATE and the DIRECTION it errs in are stated once, in
# `_trap_bare_return.awk`'s header, next to the code that implements them:
# reachability OVER-counts (a function name mentioned as text on a code line
# is an edge) and UNDER-counts (dynamic dispatch, `trap "$var"`, a sourced
# library's handler naming the sourcing file's function); bare-return
# detection is exact on the code stream the shared quote machine yields.
#
# THE ALLOWLIST records ADJUDICATED-BENIGN sites — a reachable bare return
# whose status no caller consumes. One TAB-separated row per site:
# `<path>\t<function>\t<reason>`, reason REQUIRED. Both directions red: a
# flagged site without a row is a defect candidate, and a row without a
# flagged site is STALE (the function was fixed, renamed, or the walk no longer
# reaches it) and must be removed, or the list stops describing the tree.
set -uo pipefail

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODE=sites
ALLOWLIST=""
ROOT=""
while (( $# )); do
    case "$1" in
        --files)      MODE=files; shift ;;
        --reachable)  MODE=reachable; shift ;;
        --census)     MODE=census; shift ;;
        --allowlist)  ALLOWLIST="${2:-}"; shift 2 ;;
        -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
        -*)           printf 'trap-bare-return-lint: unknown option %s\n' "$1" >&2; exit 2 ;;
        *)            ROOT="$1"; shift ;;
    esac
done
ROOT="${ROOT:-$(cd "$_dir/../.." && pwd)}"
ROOT=$(cd "$ROOT" 2>/dev/null && pwd) || { printf 'trap-bare-return-lint: root is not a directory\n' >&2; exit 2; }
ALLOWLIST="${ALLOWLIST:-$ROOT/monitor/watcher/trap-bare-return.allowlist}"

# shellcheck source=/dev/null
. "$ROOT/monitor/shell-files.sh" 2>/dev/null || {
    printf 'trap-bare-return-lint: cannot source %s/monitor/shell-files.sh — the population predicate is shared, not re-implemented. REFUSING.\n' "$ROOT" >&2
    exit 3
}
declare -F shf_is_shell >/dev/null || { printf 'trap-bare-return-lint: shf_is_shell not defined. REFUSING.\n' >&2; exit 3; }
declare -F shf_strip_comments >/dev/null || { printf 'trap-bare-return-lint: shf_strip_comments not defined. REFUSING.\n' >&2; exit 3; }
QAWK="$ROOT/monitor/watcher/_shell_quotes.awk"
CAWK="$_dir/_trap_bare_return.awk"

# THE POPULATION: tracked files the shared predicate calls shell. Repo-relative.
_population() {
    local f
    while IFS= read -r -d '' f; do
        [[ -f "$ROOT/$f" ]] || continue
        shf_is_shell "$ROOT/$f" || continue
        printf '%s\n' "$f"
    done < <(git -C "$ROOT" ls-files -z 2>/dev/null)
}

if [[ "$MODE" == files ]]; then
    _population | LC_ALL=C sort
    exit 0
fi

# Dependencies the scan cannot run without. Checked BEFORE the population so a
# missing awk program is a refusal about the lint, not a zero about the tree.
for dep in "$QAWK" "$CAWK"; do
    [[ -r "$dep" ]] || { printf 'trap-bare-return-lint: missing %s — REFUSING to scan without the shared quote machine / classifier.\n' "$dep" >&2; exit 3; }
done

_pop=$(_population | LC_ALL=C sort)
# A vacuous population is a REFUSAL, not a green (your-org/nexus-code#1268): an
# empty file list yields zero sites, which reads exactly like a clean tree.
if [[ -z "$_pop" ]]; then
    printf 'trap-bare-return-lint: the tracked shell-file population under %s is EMPTY — refusing to report zero sites from a population I could not build (not a git repository, or nothing tracked).\n' "$ROOT" >&2
    exit 3
fi

_scratch=$(mktemp -d) || { printf 'trap-bare-return-lint: mktemp failed — refusing to report zero.\n' >&2; exit 3; }
trap 'rm -rf "$_scratch"' EXIT

# PRE-FILTER, sound in the one direction that matters. A file whose RAW bytes
# hold neither `return` nor `trap` can carry no site and no trap; it can only be
# a chain INTERMEDIARY, and cross-file it is one only if some file SOURCES it —
# so a file that is also named by no `source`/`.` statement anywhere in the
# corpus changes no verdict and is skipped. Raw bytes, comments included, so the
# filter can only KEEP too much. Measured at 8d0cff30: 64 of 686 files hold
# neither word; 7 of those are sourced by name and KEPT, so 57 are skipped and
# 629 scanned. Runs through `xargs`, never a recursive grep and never the
# shell's `grep` function (CLAUDE.md #618, #707).
_sourced=$(printf '%s\n' "$_pop" | sed "s|^|$ROOT/|" | tr '\n' '\0' \
    | xargs -0 -r grep -hoE '(^|[;&|( 	])(\.|source)[ 	]+[^ 	;&|()]+' 2>/dev/null \
    | sed -E 's/.*[ 	]//; s|.*/||; s/["'"'"']//g' | LC_ALL=C sort -u)
_cands=$(printf '%s\n' "$_pop" | sed "s|^|$ROOT/|" | tr '\n' '\0' \
    | xargs -0 -r grep -lE '\breturn\b|\btrap\b|th_trap_exit' 2>/dev/null | sed "s|^$ROOT/||" | LC_ALL=C sort)
# The membership test is an ASSOCIATIVE-ARRAY lookup, not `printf | grep -q`:
# under this file's `pipefail` an early-exiting `grep -q` hands `printf` a
# SIGPIPE and the pipeline reports 141 on a MATCH — a race, so the same tree
# scanned 626, 628 and 629 files on three consecutive runs before this was
# found (CLAUDE.md, early-exit readers; #1106's own first measurement).
declare -A _is_sourced=()
while IFS= read -r b; do [[ -n "$b" ]] && _is_sourced["$b"]=1; done <<<"$_sourced"
_scan=$(
    { printf '%s\n' "$_cands"
      LC_ALL=C comm -23 <(printf '%s\n' "$_pop") <(printf '%s\n' "$_cands") \
        | while IFS= read -r f; do
              [[ -n "$f" ]] || continue
              b=${f##*/}
              if [[ -n "${_is_sourced[$b]+x}" ]]; then printf '%s\n' "$f"; fi
          done
    } | grep . | LC_ALL=C sort -u
)
if [[ -z "$_scan" ]]; then
    printf 'trap-bare-return-lint: the pre-filter left NOTHING to scan out of %d shell files — a corpus of shell files with no `return` and no `trap` anywhere is not credible; REFUSING.\n' \
        "$(printf '%s\n' "$_pop" | grep -c .)" >&2
    exit 3
fi

# STRIP, and TEST THE PRODUCER'S RC for every file. `shf_strip_comments`
# REFUSES (non-zero, loud) when `_shell_quotes.awk` is missing; a first draft of
# a sibling lint routed that refusal into `2>/dev/null`, took the empty stripped
# text as the file's code, and reported a clean sweep (#1490's own history).
# Stripped in PARALLEL — stripping the whole corpus sequentially is ~50 s on
# this host, and a lint slow enough to be skipped is a lint that does not run.
# Each worker writes `<id>.rc`; any non-zero rc is a refusal of the whole run.
# ONE tab, in a variable: `$'\t'` is ANSI-C quoting, which the shared quote
# machine (and so every sibling lint built on it) states it does not model —
# the subshell-exit scanner refused to certify this file while it carried one.
TAB=$(printf '\t'); export TAB
_map="$_scratch/map.tsv"; : > "$_map"
_i=0
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    _i=$(( _i + 1 ))
    printf '%s\t%s\t%s\n' "$_i" "$f" "$_scratch/$_i" >> "$_map"
done <<<"$_scan"
_jobs=$(nproc 2>/dev/null || echo 2); (( _jobs > 8 )) && _jobs=8; (( _jobs < 1 )) && _jobs=1
export ROOT _scratch
cut -f1,2 "$_map" | tr '\n' '\0' \
  | xargs -0 -r -P "$_jobs" -I{} bash -c '
        IFS=$TAB read -r id f <<<"$1"
        . "$ROOT/monitor/shell-files.sh" || { echo 9 > "$_scratch/$id.rc"; exit 0; }
        shf_strip_comments "$ROOT/$f" > "$_scratch/$id" 2> "$_scratch/$id.err"
        echo $? > "$_scratch/$id.rc"' _ {}
_bad=0
while IFS=$TAB read -r id f path; do
    rc=$(cat "$_scratch/$id.rc" 2>/dev/null || echo 99)
    if [[ "$rc" != 0 ]]; then
        _bad=$(( _bad + 1 ))
        printf 'trap-bare-return-lint: REFUSED — could not strip %s (rc %s):\n' "$f" "$rc" >&2
        sed 's/^/    /' "$_scratch/$id.err" >&2 2>/dev/null
    elif [[ -s "$_scratch/$id.err" ]]; then
        # the heredoc fail-safe: emitted UNSTRIPPED with a diagnostic, rc 0.
        # Pass the diagnostic through; the raw file is scanned (over-count).
        while IFS= read -r l; do printf 'trap-bare-return-lint: note (%s): %s\n' "$f" "$l"; done < "$_scratch/$id.err" >&2
    fi
done < "$_map"
if (( _bad > 0 )); then
    printf 'trap-bare-return-lint: %d file(s) could not be stripped. A file this lint cannot read is NOT a file it can certify clean.\n' "$_bad" >&2
    exit 3
fi

# THE CLASSIFIER. One awk pass over every stripped file, reading the map.
# `-v mode=` carries one of three literals chosen above, never caller-supplied text.
_out=$(awk -v mode="$MODE" -f "$QAWK" -f "$CAWK" "$_map")   # awk-v-escape-lint: literal-only — MODE is one of three literals set in this file
_awk_rc=$?
# Herestring, not `printf | grep -q`: an early-exiting reader under pipefail
# would report 141 on the very match that means REFUSE, and the `if` would
# read the refusal as absent.
if (( _awk_rc != 0 )) || grep -q '^ERR' <<<"$_out"; then
    printf 'trap-bare-return-lint: the classifier REFUSED (rc %d):\n' "$_awk_rc" >&2
    printf '%s\n' "$_out" | grep -E '^(ERR|STAT)' | sed 's/^/    /' >&2
    exit 3
fi
_stat=$(printf '%s\n' "$_out" | grep '^STAT' | tail -1)
# NON-VACUITY OF THE WALK IS NOT DECIDED HERE. A tree whose only traps are
# `trap 'rm -rf "$W"' EXIT` legitimately reaches zero functions, so a refusal
# on reach==0 would be a FALSE refusal on every small fixture. The walk's
# potency on the REAL tree is pinned by test-trap-bare-return-lint.sh instead:
# it asserts the function the measured defect lived in is still reached, with
# its chain, and that the reachable set clears a floor. Read that suite's green
# together with this lint's, never this one alone.
if [[ "$MODE" == reachable || "$MODE" == census ]]; then
    printf '%s\n' "$_out" | grep -E '^(REACH|FN|STAT)' | cut -f2-
    exit 0
fi

# ALLOWLIST: <path>\t<function>\t<reason>. Malformed → refuse.
declare -A _allow=() _allow_seen=()
if [[ -e "$ALLOWLIST" ]]; then
    _ln=0
    while IFS= read -r row || [[ -n "$row" ]]; do
        _ln=$(( _ln + 1 ))
        # Comment / blank rows. Spelled without an unquoted `(#|$)` regex: the
        # shared scanners read a bare `#` after `(` as a comment opener and
        # never see the `)`, so the construct fails their balance check.
        _trim=${row#"${row%%[![:space:]]*}"}
        [[ -z "$_trim" || "$_trim" == '#'* ]] && continue
        IFS=$TAB read -r ap af ar <<<"$row"
        if [[ -z "$ap" || -z "$af" || -z "${ar//[[:space:]]/}" ]]; then
            printf 'trap-bare-return-lint: REFUSED — malformed allowlist row %s:%d (need <path>\\t<function>\\t<reason>, reason non-empty): %s\n' "$ALLOWLIST" "$_ln" "$row" >&2
            exit 3
        fi
        _allow["$ap$TAB$af"]="$ar"
    done < "$ALLOWLIST"
fi

_sites=0; _allowed=0
while IFS=$TAB read -r kind loc fn chain; do
    [[ "$kind" == SITE ]] || continue
    p=${loc%%:*}
    key="$p$TAB$fn"
    if [[ -n "${_allow[$key]+x}" ]]; then
        _allowed=$(( _allowed + 1 )); _allow_seen["$key"]=1
        printf 'ALLOWED\t%s\t%s\t%s\t%s\n' "$loc" "$fn" "$chain" "${_allow[$key]}"
    else
        _sites=$(( _sites + 1 ))
        printf '%s\t%s\t%s\n' "$loc" "$fn" "$chain"
    fi
done <<<"$_out"

_stale=0
for key in "${!_allow[@]}"; do
    [[ -n "${_allow_seen[$key]+x}" ]] && continue
    _stale=$(( _stale + 1 ))
    IFS=$TAB read -r sp sf <<<"$key"
    printf 'STALE-ALLOWLIST\t%s\t%s\t(no reachable bare return at this path/function any more — remove the row)\n' "$sp" "$sf"
done

printf '%s\tallowed=%d\tstale_allowlist=%d\tunallowed_sites=%d\n' "$_stat" "$_allowed" "$_stale" "$_sites"

if (( _sites > 0 )); then
    printf '\ntrap-bare-return-lint: %d bare `return`(s) in function(s) REACHABLE from a trap handler.\n' "$_sites" >&2
    printf '  Executed during a trap, a bare `return` reports the status of the last\n' >&2
    printf '  command BEFORE the trap fired, not of the test above it (bash return.def;\n' >&2
    printf '  measured on 4.4.20 — your-org/nexus-code#1513: a marker-ownership predicate\n' >&2
    printf '  said MINE about a foreign marker and deleted it). Fix: `return 0` / `return 1`\n' >&2
    printf '  explicitly, or `return $?` immediately after the deciding command. If the\n' >&2
    printf '  status is provably consumed by no caller, record the site with a reason in\n' >&2
    printf '  %s.\n' "$ALLOWLIST" >&2
fi
if (( _stale > 0 )); then
    printf '\ntrap-bare-return-lint: %d STALE allowlist row(s) — the tree no longer has that site; remove them so the list keeps describing the tree.\n' "$_stale" >&2
fi
(( _sites > 0 || _stale > 0 )) && exit 1
exit 0
