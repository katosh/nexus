#!/usr/bin/env bash
# slow-band-drift.sh — turn a tolerated-red set from a custom into a check.
#
# THE DEFECT (your-org/nexus-code#737). The SLOW band is deliberately kept out
# of the blocking PR gate — test-jupyter-service.sh boots real supervisors and
# taxing every PR for it is a bad trade, and that call is not in dispute. What
# IS the defect is the pair: NON-BLOCKING *and* KNOWN-RED. Under that pair a
# genuine new red is indistinguishable from the accepted ones, so nothing
# surfaces and #729 sat red for an unknown period.
#
# The remedy is not to block on the band. It is to make the tolerated set
# ENUMERATED — monitor/slow-band-known-red.tsv — and to fail on any deviation
# from it in EITHER direction:
#
#   NEW-RED            a FAIL/TIMEOUT that is not in the tolerated set. The
#                      regression this whole apparatus exists to surface.
#   STALE-TOLERATION   a tolerated test that now PASSES. Only checking the first
#                      direction lets the list grow monotonically into a
#                      permanent excuse; a fixed red must cost one deletion.
#   UNACCOUNTED        a tolerated test the ledger does not mention at all. A
#                      toleration for a test that stopped being RUN is fiction,
#                      and it reads exactly like a toleration that is working.
#
# ONLY `PASS` IS GREEN. `SKIP` is not a pass and is reported as its own state:
# in a band invoked with SLOW_TESTS=1, a self-skip means the gate did not take,
# which is a defect about the harness rather than evidence about the code
# (your-org/nexus-code#568 A6 added SKIP to the ledger for exactly this reason).
# `TIMEOUT` is red, never a pass (#499). An allowlist, not a denylist: a status
# this script has never heard of fails toward RED.
#
# COVERAGE BOUNDARY (on the axis the mechanism varies on — WHICH deviations from
# the tolerated set are caught). This compares a ledger the runner already wrote
# against the pinned set, so it catches every per-test status deviation the
# ledger can express. It says nothing about a test that is in NEITHER the ledger
# nor the tolerated set — a scenario dropped from the selection glob is invisible
# here, and is the job of the runner's own "integration suite is actually
# selected" guard in tests-slow-integration.yml, not of this file.
#
# Usage:
#   monitor/slow-band-drift.sh <ledger.tsv> [known-red.tsv]
#   monitor/slow-band-drift.sh --selftest
#
# Exit: 0 the ledger matches the tolerated set exactly
#       1 at least one NEW-RED / STALE-TOLERATION / UNACCOUNTED
#       2 refusal — unreadable/empty ledger, malformed tolerated set, bad usage
#       3 --selftest failed
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_KNOWN_RED="$HERE/slow-band-known-red.tsv"

# Every ledger status, classified. Fail-closed: `case` ends in a `*)` that
# treats an unknown token as RED, so a new status the runner learns to emit can
# never be silently absorbed as a pass.
_is_green() { [ "$1" = "PASS" ]; }

refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit 2; }

check() {  # check <ledger> <known-red>
    local ledger="$1" known="$2"
    [ -f "$ledger" ] || refuse "ledger not found: $ledger"
    [ -s "$ledger" ] || refuse "ledger is EMPTY: $ledger — a band that recorded no test is not a band that passed"
    [ -f "$known" ] || refuse "tolerated-red set not found: $known"

    # --- parse the tolerated set -------------------------------------------
    local -a tol_path=() tol_issue=() tol_reason=()
    local lineno=0 line path issue reason
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        case "$line" in ''|'#'*) continue ;; esac
        path=${line%%$'\t'*}
        rest=${line#*$'\t'}
        if [ "$rest" = "$line" ]; then
            refuse "$known:$lineno: no TAB — format is <test-path>\\t<issue-ref>\\t<reason>"
        fi
        issue=${rest%%$'\t'*}
        reason=${rest#*$'\t'}
        if [ -z "$issue" ] || [ "$reason" = "$issue" ] || [ -z "$reason" ]; then
            refuse "$known:$lineno: every tolerated entry needs an issue ref AND a reason — an entry with nobody's name on it outlives the reason for it"
        fi
        tol_path+=("$path"); tol_issue+=("$issue"); tol_reason+=("$reason")
    done < "$known"

    # --- walk the ledger ----------------------------------------------------
    local -a new_red=() stale=() seen=()
    local status
    local n_pass=0 n_red=0 n_skip=0 total=0
    while IFS=$'\t' read -r path status _rest || [ -n "${path:-}" ]; do
        [ -n "${path:-}" ] || continue
        total=$((total + 1))
        seen+=("$path")
        local tolerated="" i=0
        while [ "$i" -lt "${#tol_path[@]}" ]; do
            [ "${tol_path[$i]}" = "$path" ] && tolerated="${tol_issue[$i]}"
            i=$((i + 1))
        done
        if _is_green "$status"; then
            n_pass=$((n_pass + 1))
            [ -n "$tolerated" ] && stale+=("$path	$tolerated")
            continue
        fi
        [ "$status" = "SKIP" ] && n_skip=$((n_skip + 1))
        n_red=$((n_red + 1))
        if [ -z "$tolerated" ]; then
            new_red+=("$path	$status")
        fi
    done < "$ledger"

    (( total > 0 )) || refuse "ledger $ledger parsed to ZERO rows — refusing to report a clean drift check over nothing"

    # --- tolerated entries the ledger never mentioned -----------------------
    local -a unaccounted=()
    local i=0 j found
    while [ "$i" -lt "${#tol_path[@]}" ]; do
        found=""; j=0
        while [ "$j" -lt "${#seen[@]}" ]; do
            [ "${seen[$j]}" = "${tol_path[$i]}" ] && found=1
            j=$((j + 1))
        done
        [ -n "$found" ] || unaccounted+=("${tol_path[$i]}	${tol_issue[$i]}")
        i=$((i + 1))
    done

    echo "=== SLOW-band drift check ==="
    echo "ledger        : $ledger ($total test(s): $n_pass pass, $n_red not-pass of which $n_skip skipped)"
    echo "tolerated set : $known (${#tol_path[@]} entry/entries)"

    local rc=0
    if [ "${#new_red[@]}" -gt 0 ]; then
        rc=1
        echo
        echo "NEW-RED — not in the tolerated set. This is the regression the band exists to surface:"
        printf '    %s\n' "${new_red[@]}"
    fi
    if [ "${#stale[@]}" -gt 0 ]; then
        rc=1
        echo
        echo "STALE-TOLERATION — tolerated, but PASSING now. Delete the line (and close the issue):"
        printf '    %s\n' "${stale[@]}"
    fi
    if [ "${#unaccounted[@]}" -gt 0 ]; then
        rc=1
        echo
        echo "UNACCOUNTED — tolerated, but the ledger never mentions it. The toleration is"
        echo "covering a test that is no longer being RUN, which reads identically to one"
        echo "that is working:"
        printf '    %s\n' "${unaccounted[@]}"
    fi

    if [ "$rc" -eq 0 ]; then
        echo
        echo "OK: every not-pass is tolerated by name, every tolerated entry is still red,"
        echo "and every tolerated entry was actually run."
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# --selftest — the negative control. Each deviation is planted on purpose and
# the checker is watched to catch it; each control is watched NOT to fire.
# ---------------------------------------------------------------------------
selftest() {
    local tmp; tmp="$(mktemp -d)"
    local pass=0 fail=0
    trap 'rm -rf "$tmp"' RETURN

    printf 'a.sh\t#1\treason a\n' > "$tmp/known"

    _case() {  # _case <name> <ledger-content> <want-rc> <want-grep|-> [known]
        local name="$1" body="$2" want="$3" needle="$4" known="${5:-$tmp/known}"
        printf '%b' "$body" > "$tmp/ledger"
        local out; out="$(check "$tmp/ledger" "$known" 2>&1)"; local rc=$?
        if [ "$rc" -ne "$want" ]; then
            printf '  FAIL %-34s rc=%d want=%d\n' "$name" "$rc" "$want"; fail=$((fail + 1)); return
        fi
        # Herestring, NOT `printf … | grep -q`. `grep -q` exits on its first
        # match, `printf` then takes SIGPIPE, and `set -o pipefail` (line 49)
        # promotes that to a pipeline failure — intermittently, depending on how
        # much of the output got buffered before grep quit. This selftest failed
        # exactly once in ~50 runs on the case with the largest output, and the
        # failure was unreproducible for 50 more; monitor/watcher/
        # test-sigpipe-assertion-lint.sh names the idiom and is what found it.
        if [ "$needle" != "-" ] && ! grep -q "$needle" <<<"$out"; then
            printf '  FAIL %-34s rc ok but no %s in output\n' "$name" "$needle"
            # Dump the evidence. A selftest that reports a mismatch without
            # showing what it saw sends the next reader back to re-derive it,
            # and an intermittent one becomes folklore instead of a bug.
            printf '       --- ledger fed in ---\n'; sed 's/^/       | /' "$tmp/ledger"
            printf '       --- checker output ---\n'; printf '%s\n' "$out" | sed 's/^/       | /'
            fail=$((fail + 1)); return
        fi
        printf '  ok   %-34s rc=%d %s\n' "$name" "$rc" "$([ "$needle" = - ] && echo "(clean)" || echo "$needle")"
        pass=$((pass + 1))
    }

    echo "-- planted deviations: the checker MUST catch each --"
    _case "new red (FAIL)"        'a.sh\tFAIL\t1\t0\t2\nb.sh\tFAIL\t1\t0\t2\n' 1 NEW-RED
    _case "new red (TIMEOUT)"     'a.sh\tFAIL\t1\t0\t2\nb.sh\tTIMEOUT\t1\t0\t?\n' 1 NEW-RED
    _case "SKIP is not a pass"    'a.sh\tFAIL\t1\t0\t2\nb.sh\tSKIP\t1\t0\t0\n' 1 NEW-RED
    _case "unknown status is RED" 'a.sh\tFAIL\t1\t0\t2\nb.sh\tWOBBLE\t1\t0\t0\n' 1 NEW-RED
    _case "stale toleration"      'a.sh\tPASS\t1\t0\t2\n' 1 STALE-TOLERATION
    _case "unaccounted toleration" 'b.sh\tPASS\t1\t0\t2\n' 1 UNACCOUNTED

    echo "-- controls: the checker MUST NOT fire --"
    _case "exact match"           'a.sh\tFAIL\t1\t0\t2\nb.sh\tPASS\t1\t0\t9\n' 0 -

    echo "-- refusals (fail-closed) --"
    # `refuse` ends in `exit 2` — correct for the CLI, fatal to this function if
    # called directly, so every probe of a refusal runs in a SUBSHELL.
    : > "$tmp/empty"
    ( check "$tmp/empty" "$tmp/known" ) >/dev/null 2>&1
    if [ $? -eq 2 ]; then
        printf '  ok   %-34s rc=2\n' "empty ledger REFUSED"; pass=$((pass + 1))
    else
        printf '  FAIL %-34s empty ledger not refused with rc=2\n' "empty ledger"; fail=$((fail + 1))
    fi
    ( check "$tmp/nonexistent-ledger" "$tmp/known" ) >/dev/null 2>&1
    if [ $? -eq 2 ]; then
        printf '  ok   %-34s rc=2\n' "missing ledger REFUSED"; pass=$((pass + 1))
    else
        printf '  FAIL %-34s missing ledger not refused with rc=2\n' "missing ledger"; fail=$((fail + 1))
    fi
    printf 'a.sh\tno-tabs-here\n' > "$tmp/badknown"
    _case "tolerated entry w/o reason" 'a.sh\tFAIL\t1\t0\t2\n' 2 - "$tmp/badknown"
    printf 'justapath\n' > "$tmp/badknown2"
    _case "tolerated entry w/o TAB"    'a.sh\tFAIL\t1\t0\t2\n' 2 - "$tmp/badknown2"

    echo
    echo "passed: $pass  failed: $fail"
    [ "$fail" -eq 0 ] || { echo "SELFTEST FAILED"; return 3; }
    echo "SELFTEST PASSED"
    return 0
}

case "${1:-}" in
    --selftest) selftest; exit $? ;;
    ""|-h|--help)
        sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
        exit 2 ;;
esac

check "$1" "${2:-$DEFAULT_KNOWN_RED}"
