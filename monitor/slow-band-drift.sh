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
#   ENV-UNPROVEN       an `ENVSKIP` row: a suite that RAN, asserted, and then
#                      declined on MEASURED environment grounds. Never green,
#                      never a regression — reported, and exits 4.
#
# WHY `ENVSKIP` IS A SEPARATE TOKEN AND NOT A TOLERATED `SKIP`
# (your-org/nexus-code#1283). `SKIP` above carries a specific accusation — the
# `SLOW_TESTS=1` gate DID NOT TAKE, so the suite silently left the band — and
# that accusation must stay loud, which is what the `SKIP is not a pass` arm of
# the selftest pins. But it is indistinguishable, on the token alone, from an
# HONEST decline by a suite that did run and found the MACHINE unable to build
# its fixture. Opposite situations, opposite actions, one token; so the ENV/
# PRODUCT distinction was inert in exactly the band that needed it, because the
# tolerated set is empty by design and every `exit 77` was therefore NEW-RED.
#
# The remedy is a token, not a threshold. `ENVSKIP` says "I ran and could not
# conclude", and it is treated as EVIDENCE OF NEITHER SIDE:
#   * it is NOT green — it never counts toward the pass tally;
#   * it never CLEARS a toleration — a tolerated test that ENVSKIPs has not
#     been shown to pass, and deleting its line on that basis would be acting
#     on no evidence at all;
#   * it never MASKS a real deviation — rc 1 outranks rc 4, so a NEW-RED in the
#     same ledger still decides the verdict;
#   * a TOLERATED test that ENVSKIPs is reported too, because a toleration that
#     is never re-confirmed rots exactly as UNACCOUNTED describes.
# Fail-closed is unchanged: the classifier's arms are literal EQUALITY over
# disjoint sets and the terminal arm is RED, so `envskip`, `ENV-SKIP` or any
# other spelling is a red, not a quiet exemption (`#1121` arm-order rule: no
# permissive arm precedes a deny arm that could fire on the same input).
#
# WHERE THE TOKEN COMES FROM. `run-tests.sh` writes it: a suite that exits 69
# (EX_UNAVAILABLE) is tallied `ENVSKIP`, while `exit 77` stays `SKIP`. A
# DECLARED CODE, not an inference — `#1283` suggests separating the two by
# assertion count, and that discriminator is INERT, because the ledger's
# assertion column is forced to `?` for every non-PASS row in two independent
# places. It is also the wrong shape: an inference fails OPEN, a declared code
# fails CLOSED.
#
# EITHER MERGE ORDER IS SAFE, and in both directions the failure is a RED
# rather than a silent pass — which is the property to check, not the mere
# absence of breakage:
#   * this arm WITHOUT the runner half — no ledger ever carries `ENVSKIP`, so
#     the arm is unreachable and nothing changes;
#   * the runner half WITHOUT this arm — `ENVSKIP` is an unknown status and the
#     terminal `*)` reds it, which is the fail-closed default doing its job;
#   * a SUITE adopting `exit 69` before the runner half — the runner's `rc != 0`
#     range arm makes it a FAIL, i.e. loud and attributable.
# This paragraph previously read "nothing writes `ENVSKIP` today"; that was true
# when the consumer arm was written alone and is recorded here as corrected
# rather than deleted, because the inert-arm reasoning above is what makes the
# split safe to land in two pieces.
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
#       4 ENV-UNPROVEN and nothing worse — NOT a clearance. Some row could not
#         be concluded on this machine; read the named rows before treating the
#         band as evidence about the code.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_KNOWN_RED="$HERE/slow-band-known-red.tsv"

# Every ledger status, classified. Fail-closed: `case` ends in a `*)` that
# treats an unknown token as RED, so a new status the runner learns to emit can
# never be silently absorbed as a pass.
#
# ARM ORDER IS NOT LOAD-BEARING HERE, AND THAT IS A PROPERTY WORTH STATING
# (your-org/nexus-code#1121). Every non-terminal arm is literal EQUALITY over a
# one-element set, so no input can match two of them and no reordering can
# change an answer. It would stop being true the day an arm gained a glob — at
# which point a permissive arm above the terminal RED would silently exempt
# whatever it happened to match. Keep the arms literal.
_status_class() {  # -> green | unproven | red
    case "$1" in
        PASS)    printf 'green' ;;
        ENVSKIP) printf 'unproven' ;;
        *)       printf 'red' ;;
    esac
}
# Retained as the narrow predicate the reporting reads. Defined in terms of the
# classifier so there is ONE place that decides what green means.

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
    local -a new_red=() stale=() seen=() unproven=()
    local status klass
    local n_pass=0 n_red=0 n_skip=0 n_env=0 total=0
    while IFS=$'\t' read -r path status _rest || [ -n "${path:-}" ]; do
        [ -n "${path:-}" ] || continue
        total=$((total + 1))
        seen+=("$path")
        local tolerated="" i=0
        while [ "$i" -lt "${#tol_path[@]}" ]; do
            [ "${tol_path[$i]}" = "$path" ] && tolerated="${tol_issue[$i]}"
            i=$((i + 1))
        done
        klass=$(_status_class "$status")
        if [ "$klass" = green ]; then
            n_pass=$((n_pass + 1))
            [ -n "$tolerated" ] && stale+=("$path	$tolerated")
            continue
        fi
        # ENV-UNPROVEN. Deliberately BEFORE the red tally and deliberately not
        # falling through to it: an `ENVSKIP` is not a red the tolerated set can
        # excuse, so it is neither a NEW-RED (which would re-red the band for a
        # machine's shortcoming) nor a silently tolerated one (which would let a
        # test that never concludes hold its toleration open forever). It is
        # reported EITHER WAY — tolerated or not — with which of the two it was.
        if [ "$klass" = unproven ]; then
            n_env=$((n_env + 1))
            unproven+=("$path	$status	${tolerated:-not tolerated}")
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
    echo "ledger        : $ledger ($total test(s): $n_pass pass, $n_red not-pass of which $n_skip skipped, $n_env env-unproven)"
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

    # ENV-UNPROVEN is reported LAST and scored LOWEST. `rc=1` above is never
    # downgraded: a real deviation outranks "could not conclude", so an ENVSKIP
    # sharing a ledger with a NEW-RED cannot launder it.
    if [ "${#unproven[@]}" -gt 0 ]; then
        [ "$rc" -eq 0 ] && rc=4
        echo
        echo "ENV-UNPROVEN — these rows RAN and declined on measured environment grounds."
        echo "This is NOT a pass and NOT a regression: the band has no evidence either way"
        echo "about them, and rc 4 says so rather than pretending to a verdict:"
        printf '    %s\n' "${unproven[@]}"
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

    # ENV-UNPROVEN (your-org/nexus-code#1283). Five arms, because the token is
    # only worth having if it is scored EXACTLY between the two things it sits
    # between — and each of the four ways to get that wrong is a real hole:
    # scoring it green re-opens #737, scoring it red re-creates the inertness
    # #1283 reports, letting it clear a toleration acts on no evidence, and
    # letting it outrank a NEW-RED launders a regression.
    echo "-- ENV-UNPROVEN: an ENVSKIP is evidence of NEITHER side --"
    _case "ENVSKIP is rc 4, not 0"      'a.sh\tFAIL\t1\t0\t2\nb.sh\tENVSKIP\t1\t0\t?\n' 4 ENV-UNPROVEN
    _case "ENVSKIP is NOT a NEW-RED"    'a.sh\tFAIL\t1\t0\t2\nb.sh\tENVSKIP\t1\t0\t?\n' 4 -
    # rc 4 already proves NEW-RED did not fire (it would have forced rc 1), and
    # the grep above cannot express "this string is ABSENT". Assert the absence
    # directly, with a POSITIVE CONTROL beside it so an absence produced by the
    # needle never appearing at all cannot pass for one produced by the fix.
    printf 'b.sh\tENVSKIP\t1\t0\t?\n' > "$tmp/ledger"
    _env_out="$(check "$tmp/ledger" "$tmp/known" 2>&1)"
    if grep -q 'NEW-RED' <<<"$_env_out"; then
        printf '  FAIL %-34s an ENVSKIP was reported as NEW-RED\n' "ENVSKIP absent from NEW-RED"; fail=$((fail + 1))
    elif ! grep -q 'ENV-UNPROVEN' <<<"$_env_out"; then
        printf '  FAIL %-34s CONTROL: the ENV-UNPROVEN heading never printed, so the absence above proves nothing\n' "ENVSKIP absent from NEW-RED"; fail=$((fail + 1))
    else
        printf '  ok   %-34s (and the ENV-UNPROVEN heading DID print)\n' "ENVSKIP absent from NEW-RED"; pass=$((pass + 1))
    fi
    _case "ENVSKIP does not clear a tol" 'a.sh\tENVSKIP\t1\t0\t?\n' 4 ENV-UNPROVEN
    _case "…and is not STALE-TOLERATION" 'a.sh\tENVSKIP\t1\t0\t?\n' 4 -
    _case "a NEW-RED outranks ENVSKIP"    'a.sh\tFAIL\t1\t0\t2\nb.sh\tFAIL\t1\t0\t2\nc.sh\tENVSKIP\t1\t0\t?\n' 1 NEW-RED
    # Fail-CLOSED on spelling: only the exact token is the exemption. A
    # near-miss must be RED, not a quiet pass — this is the arm that stops
    # `#1283`'s remedy from becoming a hole of its own.
    _case "lowercase envskip is RED"      'a.sh\tFAIL\t1\t0\t2\nb.sh\tenvskip\t1\t0\t?\n' 1 NEW-RED
    _case "ENV-SKIP (hyphen) is RED"      'a.sh\tFAIL\t1\t0\t2\nb.sh\tENV-SKIP\t1\t0\t?\n' 1 NEW-RED

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
        # RANGE PINNED BY CONTENT, NOT BY A LITERAL (your-org/nexus-code#1163).
        # This used to be a hard-coded `2,45p`; every line added to the header
        # above silently truncated --help mid-sentence, which is how run-tests.sh's
        # own --help came to omit four options. `/^set -uo/` is the first line
        # AFTER the header, so the range tracks the header instead of dating it.
        sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
        exit 2 ;;
esac

check "$1" "${2:-$DEFAULT_KNOWN_RED}"
