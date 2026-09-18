#!/usr/bin/env bash
# monitor/watcher/test-registry-unreadable-refusal.sh — your-org/nexus-code#1266.
#
# WHAT IS UNDER TEST, and why it is not "does the parser work".
#
# An I/O failure reading `monitor/services.registry` was INDISTINGUISHABLE from
# "there are no services". `[[ -f "$file" ]]` is TRUE for a file that exists and
# cannot be READ, so the guard did not cover the `done < "$file"` redirection one
# line below; the failed parse produced zero rows, and every consumer read zero
# rows as an answer. `verify-stack.sh` turned that into
#   [verify-stack] stack converged in 0s: watcher fresh, services healthy
# and EXIT 0, while a registered service was genuinely down.
#
# That is MANUFACTURED SUCCESS, not a masked failure. A masked failure is
# recoverable — something downstream eventually disagrees. Here every visible
# artefact says the work was done and the only evidence is an absence.
#
# THE PROPERTY, stated so a reader can check the arms against it:
#
#   A reader of the registry must distinguish THREE states, not two.
#     ABSENT      no registry -> "there are no services" IS the answer (rc 0)
#     READABLE    rc 0; the rows are the answer, ZERO ROWS INCLUDED
#     UNREADABLE  the path exists and could not be read -> rc 79, NEVER 0
#   79 is NOT-CHECKED, on the axis monitor/assert-shims-wrapped.sh draws its
#   own 79 bound on: could the reader examine its subject at all.
#
# TWO DIRECTIONS ARE ASSERTED, AND THE SECOND IS THE ONE THAT MATTERS MORE.
# Every arm that proves a REFUSAL is paired with a NON-DEGRADATION arm proving
# the same code still answers correctly on a readable registry. A guard that
# refuses everything would pass a refusal-only suite.
#
# THE PRECISION ARM. `|| return 0` at a call site is only harmful if ordinary
# registry shapes never produce a non-zero rc. t_shape_* walks 13 of them
# (absent, empty, row-last with and without a trailing newline, comment-last,
# blank-last, trailing whitespace, malformed, 5-field, 6-field policy, CRLF,
# comments-only) and requires rc 0 from every one, so 79 means an I/O fault
# SPECIFICALLY. This is the arm that would go red if the predicate were made
# lazily strict.
#
# THE REWRITE HALF (t_rw_*). `awk … "$REG" > "$tmp"` FAILS OPEN on an
# unreadable registry — rc 2, `$tmp` empty — and the `mv` two lines down
# COMMITS that empty file. Measured at 85458bf8 against an 11-row registry:
# `ensure_registry_row` left 1 row and `remove_registry_row` left 0, both at
# rc 0 printing a success line. That is permanent DATA DESTRUCTION, and it is
# strictly worse than the read half, because afterwards every reader
# legitimately reports "no services" — the manufactured success becomes
# self-consistent and nothing can detect it any more.
#
# MODE 0000 IS THE INSTRUMENT, NOT THE HAZARD. The realistic driver on this
# NFS-backed tree is a transient ESTALE/EIO, where the DIRECTORY stays writable
# while the read fails — exactly the state in which `mv` succeeds. chmod is
# simply the portable way to produce the same open failure inside a test.
#
# ROOT RUNS THIS SUITE INCORRECTLY, so it says so instead of passing: root
# bypasses mode bits, mode 0000 stays readable, and EVERY refusal arm would
# report the pre-fix behaviour while the code is correct. th_skip, not silence.
#
# Run: bash monitor/watcher/test-registry-unreadable-refusal.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
RECOVER="$_repo_root/monitor/bootstrap-recover.sh"
VERIFY="$_repo_root/monitor/watcher/verify-stack.sh"
SVC="$_repo_root/monitor/svc.sh"
SHEALTH="$_repo_root/monitor/watcher/_service_health.sh"
IDLEP="$_repo_root/monitor/watcher/_idle_probe.sh"
for f in "$RECOVER" "$VERIFY" "$SVC" "$SHEALTH" "$IDLEP"; do
    [[ -r "$f" ]] || { echo "not readable: $f" >&2; exit 1; }
done

. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
# Restore any mode-0000 fixture before removal, or the cleanup itself fails.
trap 'chmod -R u+rwX "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# ---- the root guard -------------------------------------------------------
# Establish BY MEASUREMENT that mode 0000 actually denies a read here, rather
# than assuming it from the uid. An unreadable-file suite that cannot make a
# file unreadable must not report green.
_probe="$WORK/.rootprobe"
printf 'x\n' > "$_probe"; chmod 0000 "$_probe"
if { : ; } 2>/dev/null < "$_probe"; then
    UNREADABLE_WORKS=0
else
    UNREADABLE_WORKS=1
fi
chmod 0644 "$_probe"; rm -f "$_probe"

# ---- fixture builders -----------------------------------------------------

# new_reg <path> [rows...] — a registry with N 5-field rows, mode 0644.
new_reg() {
    local p="$1"; shift
    : > "$p"
    local n
    for n in "$@"; do printf '%s\t/tmp\ttrue\ttrue\t/tmp/%s.log\n' "$n" "$n" >> "$p"; done
    chmod 0644 "$p"
}

# parse_rc <registry> <mode> — rc of _recover_parse_registry at that mode.
parse_rc() {
    local reg="$1" mode="$2" rc
    chmod "$mode" "$reg"
    ( set -uo pipefail
      export NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$WORK/state"
      mkdir -p "$WORK/state"
      # shellcheck disable=SC1090
      source "$RECOVER" >/dev/null 2>&1
      _recover_parse_registry "$reg" >/dev/null 2>&1 ) ; rc=$?
    chmod 0644 "$reg" 2>/dev/null || true
    printf '%s' "$rc"
}

# parse_rows <registry> — row count from a READABLE registry.
parse_rows() {
    local reg="$1"
    ( set -uo pipefail
      export NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$WORK/state"
      mkdir -p "$WORK/state"
      # shellcheck disable=SC1090
      source "$RECOVER" >/dev/null 2>&1
      _recover_parse_registry "$reg" 2>/dev/null ) | grep -c .
}

# ===========================================================================
# 1. THE PARSER — three states
# ===========================================================================

REG="$WORK/services.registry"
new_reg "$REG" svcA svcB

assert_eq "parser: READABLE registry -> rc 0"          "$(parse_rc "$REG" 0644)" 0
assert_eq "parser: READABLE registry -> its rows"      "$(parse_rows "$REG")"    2

ABSENT="$WORK/no-such-registry"
rm -f "$ABSENT"
assert_eq "parser: ABSENT registry -> rc 0 (an answer, not a fault)" \
          "$(parse_rc "$ABSENT" 0644 2>/dev/null || printf 0)" 0

if (( UNREADABLE_WORKS )); then
    assert_eq "parser: UNREADABLE registry -> rc 79, NEVER 0" "$(parse_rc "$REG" 0000)" 79
else
    th_skip "parser: UNREADABLE registry -> rc 79 (running as root: mode 0000 still readable)"
fi

# An EMPTY registry is READABLE and its answer is genuinely zero rows. This is
# the arm that stops "refuse whenever there are no rows" from passing.
EMPTY="$WORK/empty.registry"; : > "$EMPTY"; chmod 0644 "$EMPTY"
assert_eq "parser: EMPTY-but-readable registry -> rc 0 (zero rows IS the answer)" \
          "$(parse_rc "$EMPTY" 0644)" 0

# ===========================================================================
# 2. PRECISION — every ordinary shape stays rc 0, so 79 means I/O
# ===========================================================================

t_shape() {
    local label="$1" content="$2" sp="$WORK/shape.registry"
    printf '%s' "$content" > "$sp"; chmod 0644 "$sp"
    assert_eq "shape stays rc 0 (so 79 means an I/O fault): $label" "$(parse_rc "$sp" 0644)" 0
}
t_shape "empty"                    ""
t_shape "row, no trailing newline" $'svcA\t/tmp\ttrue\ttrue'
t_shape "row, trailing newline"    $'svcA\t/tmp\ttrue\ttrue\n'
t_shape "comment last"             $'svcA\t/tmp\ttrue\ttrue\n# c\n'
t_shape "blank last"               $'svcA\t/tmp\ttrue\ttrue\n\n'
t_shape "trailing whitespace line" $'svcA\t/tmp\ttrue\ttrue\n   \n'
t_shape "malformed (2 fields)"     $'bad\tonly\n'
t_shape "5-field row"              $'svcA\t/tmp\ttrue\ttrue\t/tmp/l.log\n'
t_shape "6-field row (policy)"     $'svcA\t/tmp\ttrue\ttrue\t/tmp/l.log\temit-only\n'
t_shape "CRLF line endings"        $'svcA\t/tmp\ttrue\ttrue\r\n'
t_shape "comments only"            $'# a\n# b\n'

# ===========================================================================
# 3. verify-stack.sh — the sharpest consumer. Registry BYTES held constant;
#    the file MODE is the only variable.
# ===========================================================================

vs_run() {                       # vs_run <mode> -> "<rc>|<stderr>"
    local mode="$1" out rc
    local lab="$WORK/vs"; mkdir -p "$lab/state"
    printf 'ts=%s\n' "$(date +%s)" > "$lab/state/watcher-heartbeat"
    printf 'svcA\t%s\ttrue\tfalse\n' "$lab" > "$lab/reg.tsv"   # healthcheck `false` => UNHEALTHY
    chmod "$mode" "$lab/reg.tsv"
    out=$( NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$lab/state" \
           NEXUS_SERVICES_REGISTRY="$lab/reg.tsv" \
           bash "$VERIFY" --no-orchestrator --timeout 0 --poll 1 2>&1 ); rc=$?
    chmod 0644 "$lab/reg.tsv" 2>/dev/null || true
    printf '%s|%s' "$rc" "$out"
}

VS_OK="$(vs_run 0644)"
assert_eq       "verify-stack: readable + UNHEALTHY service -> exit 1" "${VS_OK%%|*}" 1
assert_contains "verify-stack: readable arm names the unhealthy service" "${VS_OK#*|}" "svcA"

if (( UNREADABLE_WORKS )); then
    VS_BAD="$(vs_run 0000)"
    assert_eq "verify-stack: UNREADABLE registry -> exit 79, not 0" "${VS_BAD%%|*}" 79
    assert_contains "verify-stack: unreadable arm says NOT CHECKED" \
                    "${VS_BAD#*|}" "NOT CHECKED"
    # The regression itself, asserted as an ABSENCE of the exact false sentence.
    assert_not_contains "verify-stack: unreadable arm NEVER claims services healthy" \
                        "${VS_BAD#*|}" "services healthy"
    assert_not_contains "verify-stack: unreadable arm NEVER claims convergence" \
                        "${VS_BAD#*|}" "stack converged"
else
    th_skip "verify-stack: UNREADABLE registry -> exit 79 (root)"
    th_skip "verify-stack: unreadable arm says NOT CHECKED (root)"
    th_skip "verify-stack: unreadable arm NEVER claims services healthy (root)"
    th_skip "verify-stack: unreadable arm NEVER claims convergence (root)"
fi

# NON-DEGRADATION, the direction a refusal-only suite cannot see: a HEALTHY
# readable registry must still converge at exit 0.
vs_healthy() {
    local lab="$WORK/vsh"; mkdir -p "$lab/state"
    printf 'ts=%s\n' "$(date +%s)" > "$lab/state/watcher-heartbeat"
    printf 'svcA\t%s\ttrue\ttrue\n' "$lab" > "$lab/reg.tsv"; chmod 0644 "$lab/reg.tsv"
    NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$lab/state" \
      NEXUS_SERVICES_REGISTRY="$lab/reg.tsv" \
      bash "$VERIFY" --no-orchestrator --timeout 0 --poll 1 >/dev/null 2>&1
    printf '%s' "$?"
}
assert_eq "verify-stack NON-DEGRADATION: healthy readable registry still exits 0" \
          "$(vs_healthy)" 0

# ===========================================================================
# 4. THE REWRITE HALF — a failed READ must never commit a truncated registry
# ===========================================================================

# rw_replay <verb> — the shipped rewrite shape, run against an unreadable
# registry, then the registry's surviving row count. Guard present => the
# rewrite is refused and the rows survive.
rw_replay() {
    local verb="$1" reg="$WORK/rw.registry" tmp rc
    new_reg "$reg" a b c d e f g h i j k          # 11 rows, as on this nexus
    chmod 0000 "$reg"
    tmp=$(mktemp "$WORK/rw.registry.XXXXXX")
    if awk -F'\t' -v n=newsvc '$1 != n' "$reg" > "$tmp" 2>/dev/null; then
        rc=committed
        [[ "$verb" == ensure ]] && printf 'newsvc\t/tmp\ttrue\ttrue\n' >> "$tmp"
        chmod 0644 "$reg"; mv "$tmp" "$reg"
    else
        rc=refused; rm -f "$tmp"; chmod 0644 "$reg"
    fi
    printf '%s|%s' "$rc" "$(grep -c . "$reg")"
}

if (( UNREADABLE_WORKS )); then
    RW_E="$(rw_replay ensure)"
    assert_eq "rewrite: awk on an UNREADABLE registry is a detectable failure (ensure)" \
              "${RW_E%%|*}" refused
    assert_eq "rewrite: refusing leaves all 11 rows intact (ensure)" "${RW_E#*|}" 11
    RW_R="$(rw_replay remove)"
    assert_eq "rewrite: awk on an UNREADABLE registry is a detectable failure (remove)" \
              "${RW_R%%|*}" refused
    assert_eq "rewrite: refusing leaves all 11 rows intact (remove)" "${RW_R#*|}" 11
else
    th_skip "rewrite: detectable failure (ensure) (root)"
    th_skip "rewrite: 11 rows intact (ensure) (root)"
    th_skip "rewrite: detectable failure (remove) (root)"
    th_skip "rewrite: 11 rows intact (remove) (root)"
fi

# The SHIPPED code path, end to end, not a replay: remote-up.sh --down against
# an unreadable 11-row registry must leave all 11 rows.
rup_rows() {
    local lab="$WORK/rup"; mkdir -p "$lab/state"
    local reg="$lab/services.registry"
    new_reg "$reg" a b c d e f g h i j k
    chmod 0000 "$reg"
    NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$lab/state" NEXUS_SERVICES_REGISTRY="$reg" \
      bash "$_repo_root/monitor/remote-up.sh" --down >/dev/null 2>&1
    chmod 0644 "$reg"
    grep -c . "$reg"
}
if (( UNREADABLE_WORKS )); then
    assert_eq "remote-up.sh --down: UNREADABLE registry keeps all 11 rows (no truncation)" \
              "$(rup_rows)" 11
else
    th_skip "remote-up.sh --down: 11 rows survive (root)"
fi

# NON-DEGRADATION: a READABLE registry must still be rewritten normally.
rup_readable_rows() {
    local lab="$WORK/rup2"; mkdir -p "$lab/state"
    local reg="$lab/services.registry"
    new_reg "$reg" a b nexus-remote-ssh
    NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$lab/state" NEXUS_SERVICES_REGISTRY="$reg" \
      bash "$_repo_root/monitor/remote-up.sh" --down >/dev/null 2>&1
    grep -c . "$reg"
}
assert_eq "remote-up.sh NON-DEGRADATION: readable registry still loses exactly its own row" \
          "$(rup_readable_rows)" 2

# ===========================================================================
# 4b. A GUARD CAN FIRE AND STILL BE DISCARDED — `die` inside `$( )` exits the
#     SUBSHELL, not the script.
#
#     Every caller of jupyter-up.sh's two registry lookups invokes them in a
#     command substitution (`name=$(_registry_name_for_workdir …) || { … }`),
#     so a `die` inside them terminates only the substitution and the caller's
#     `||` arm runs on. Measured on this branch BEFORE the entry-point gates
#     existed: an unreadable registry made `jupyter-up.sh --down` print
#     "no jupyter-* registry row … stopping any bare labsh server anyway" and
#     exit **0** — the guard fired, wrote its refusal to stderr, and the
#     refusal was thrown away, leaving exactly the #1266 behaviour it was added
#     to prevent.
#
#     This is #1266 one level up: not a missing check, but a check whose
#     verdict no caller can observe. Same family as section 7's defeated `!`.
#     Both arms below assert the OBSERVABLE outcome (rc + the absence of the
#     false sentence), never that a guard "was called".
# ===========================================================================

jup() {                          # jup <mode> <args...> -> "<rc>|<output>"
    local mode="$1"; shift
    local lab="$WORK/jup$mode"; rm -rf "$lab"; mkdir -p "$lab/state" "$lab/proj"
    local reg="$lab/services.registry"
    new_reg "$reg" a b c
    [[ "$mode" == bad ]] && chmod 0000 "$reg"
    local out rc
    out=$( NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$lab/state" \
           NEXUS_SERVICES_REGISTRY="$reg" \
           bash "$_repo_root/monitor/jupyter-up.sh" "$@" 2>&1 ); rc=$?
    chmod 0644 "$reg" 2>/dev/null || true
    printf '%s|%s' "$rc" "$out"
}

if (( UNREADABLE_WORKS )); then
    JD="$(jup bad "$WORK/jupbad/proj" --down)"
    assert_eq "jupyter-up --down: UNREADABLE registry REFUSES (rc != 0)" \
              "$( [[ "${JD%%|*}" != 0 ]] && echo refused || echo "rc0" )" refused
    assert_not_contains "jupyter-up --down: never says 'no jupyter-* registry row' for an unreadable one" \
                        "${JD#*|}" "no jupyter-* registry row"
    JS="$(jup bad "$WORK/jupbad/proj" --status)"
    assert_eq "jupyter-up --status: UNREADABLE registry REFUSES (rc != 0)" \
              "$( [[ "${JS%%|*}" != 0 ]] && echo refused || echo "rc0" )" refused
    assert_not_contains "jupyter-up --status: never reports '(unregistered)' for an unreadable one" \
                        "${JS#*|}" "(unregistered)"
else
    th_skip "jupyter-up --down refuses (root)"
    th_skip "jupyter-up --down says nothing false (root)"
    th_skip "jupyter-up --status refuses (root)"
    th_skip "jupyter-up --status says nothing false (root)"
fi

# NON-DEGRADATION: a READABLE registry with no jupyter row must still take the
# ordinary "not registered" path, which is a legitimate answer there.
JOK="$(jup ok "$WORK/jupok/proj" --status)"
assert_contains "jupyter-up --status NON-DEGRADATION: readable registry still reports unregistered" \
                "${JOK#*|}" "unregistered"

# THE MECHANISM, pinned so the reason survives the fix.
assert_eq "die inside \$( ) exits the SUBSHELL only — the caller's || arm runs on" \
    "$(bash -c 'die(){ exit 1; }; f(){ die; }; n=$(f) || echo SWALLOWED; echo ALIVE' | tr "\n" " ")" \
    "SWALLOWED ALIVE "

# ===========================================================================
# 5. THE OTHER PARSERS — the contract is replicated, so assert it replicated.
#    These three are absent from the issue's consumer table.
# ===========================================================================

# svc.sh: a THIRD parser feeding the cockpit.
svc_parse_rc() {
    local reg="$1" mode="$2" rc
    chmod "$mode" "$reg"
    ( set -uo pipefail
      export NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$WORK/state"
      # shellcheck disable=SC1090
      source "$SVC" >/dev/null 2>&1
      svc_parse_registry "$reg" >/dev/null 2>&1 ); rc=$?
    chmod 0644 "$reg" 2>/dev/null || true
    printf '%s' "$rc"
}
assert_eq "svc.sh parser: READABLE -> rc 0" "$(svc_parse_rc "$REG" 0644)" 0
if (( UNREADABLE_WORKS )); then
    assert_eq "svc.sh parser: UNREADABLE -> rc 79 (cockpit must not render an empty list)" \
              "$(svc_parse_rc "$REG" 0000)" 79
else
    th_skip "svc.sh parser: UNREADABLE -> rc 79 (root)"
fi

# _service_health.sh: the watcher's supervisor. Zero services supervised at
# rc 0 was the silent failure — every registered service stops being watched.
sh_parse_rc() {
    local reg="$1" mode="$2" rc
    chmod "$mode" "$reg"
    ( set -uo pipefail
      export NEXUS_ROOT="$_repo_root" NEXUS_SERVICES_REGISTRY="$reg"
      # shellcheck disable=SC1090
      source "$SHEALTH" >/dev/null 2>&1
      _sh_parse_registry >/dev/null 2>&1 ); rc=$?
    chmod 0644 "$reg" 2>/dev/null || true
    printf '%s' "$rc"
}
assert_eq "_service_health parser: READABLE -> rc 0" "$(sh_parse_rc "$REG" 0644)" 0
if (( UNREADABLE_WORKS )); then
    assert_eq "_service_health parser: UNREADABLE -> rc 79 (not 'zero services to supervise')" \
              "$(sh_parse_rc "$REG" 0000)" 79
else
    th_skip "_service_health parser: UNREADABLE -> rc 79 (root)"
fi

# _idle_probe.sh: DELIBERATELY still produces its (incomplete) exemption list —
# refusing would disable the worker sweep, a real degradation for a fault that
# costs only noise. What it must NOT do is stay SILENT about it.
idle_names_rc() {
    local reg="$1" mode="$2" rc
    chmod "$mode" "$reg"
    ( set -uo pipefail
      export NEXUS_ROOT="$_repo_root" NEXUS_SERVICES_REGISTRY="$reg"
      # shellcheck disable=SC1090
      source "$IDLEP" >/dev/null 2>&1
      _idle_registry_service_names >/dev/null 2>&1 ); rc=$?
    chmod 0644 "$reg" 2>/dev/null || true
    printf '%s' "$rc"
}
assert_eq "_idle_probe: READABLE -> rc 0" "$(idle_names_rc "$REG" 0644)" 0
if (( UNREADABLE_WORKS )); then
    assert_eq "_idle_probe: UNREADABLE -> rc 79 (exemption set INCOMPLETE, stated not hidden)" \
              "$(idle_names_rc "$REG" 0000)" 79
else
    th_skip "_idle_probe: UNREADABLE -> rc 79 (root)"
fi

# ===========================================================================
# 6. bootstrap-recover --list: an empty listing at rc 0 reads as "nothing is
#    registered". It must not be produced from a registry that could not be read.
# ===========================================================================

list_run() {                     # list_run <mode> -> "<rc>|<output>"
    local mode="$1" lab="$WORK/bl" out rc
    mkdir -p "$lab/state"
    local reg="$lab/services.registry"
    new_reg "$reg" a b c
    chmod "$mode" "$reg"
    out=$( NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$lab/state" NEXUS_SERVICES_REGISTRY="$reg" \
           bash "$RECOVER" --list 2>&1 ); rc=$?
    chmod 0644 "$reg" 2>/dev/null || true
    printf '%s|%s' "$rc" "$out"
}
BL_OK="$(list_run 0644)"
assert_eq       "--list NON-DEGRADATION: readable registry still lists at rc 0" "${BL_OK%%|*}" 0
assert_contains "--list NON-DEGRADATION: readable registry still names its rows" "${BL_OK#*|}" "a"
if (( UNREADABLE_WORKS )); then
    BL_BAD="$(list_run 0000)"
    assert_eq "--list: UNREADABLE registry -> rc 79, not an empty list at rc 0" "${BL_BAD%%|*}" 79
    assert_contains "--list: UNREADABLE registry says so" "${BL_BAD#*|}" "could not be READ"
else
    th_skip "--list: UNREADABLE registry -> rc 79 (root)"
    th_skip "--list: UNREADABLE registry says so (root)"
fi

# ===========================================================================
# 6b. THE DIAGNOSTIC IS A SEPARATE PROPERTY FROM THE rc, and a mutation sweep
#     is what proved it. Each parser carries TWO defences: an early readability
#     probe, and `done < "$file" || return 79` on the redirection itself. They
#     are mutually redundant FOR THE rc — delete either and the other still
#     returns 79 — so an rc-only suite cannot see the loss of one. Measured:
#     mutants M1 (early guard -> `if false`), M2 (redirection `|| return 79`
#     removed), M5 and M6 (same guard in svc.sh / _service_health.sh) ALL
#     SURVIVED a 45-assertion rc-only suite, 45 passed / 0 failed each.
#
#     Only the EARLY probe emits the operator-facing "NOT READABLE" line; the
#     redirection fallback returns 79 silently, leaving a bare bash
#     "Permission denied" naming a line inside the parser. So the diagnostic
#     is what distinguishes them, and it is worth asserting in its own right:
#     it is the artefact that tells an operator WHICH of "no services" and
#     "could not read your services" they are looking at.
# ===========================================================================

# stderr of each parser against an UNREADABLE registry.
parser_stderr() {                # parser_stderr <which> -> stderr text
    local which="$1" reg="$WORK/diag.registry" err
    new_reg "$reg" a; chmod 0000 "$reg"
    case "$which" in
      recover) err=$( ( export NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$WORK/state"
                        source "$RECOVER" >/dev/null 2>&1
                        _recover_parse_registry "$reg" ) 2>&1 1>/dev/null ) ;;
      svc)     err=$( ( export NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$WORK/state"
                        source "$SVC" >/dev/null 2>&1
                        svc_parse_registry "$reg" ) 2>&1 1>/dev/null ) ;;
      health)  err=$( ( export NEXUS_ROOT="$_repo_root" NEXUS_SERVICES_REGISTRY="$reg"
                        source "$SHEALTH" >/dev/null 2>&1
                        _sh_parse_registry ) 2>&1 1>/dev/null ) ;;
    esac
    chmod 0644 "$reg" 2>/dev/null || true
    printf '%s' "$err"
}

if (( UNREADABLE_WORKS )); then
    assert_contains "bootstrap-recover parser NAMES the condition, not just rc 79" \
                    "$(parser_stderr recover)" "NOT READABLE"
    assert_contains "svc.sh parser NAMES the condition" \
                    "$(parser_stderr svc)"     "NOT READABLE"
    assert_contains "_service_health parser NAMES the condition" \
                    "$(parser_stderr health)"  "NOT READABLE"
    # NON-DEGRADATION: a readable registry must emit NO such line, or the
    # arms above would pass against a parser that cries wolf every call.
    quiet_stderr() {
        local reg="$WORK/quiet.registry"; new_reg "$reg" a
        ( export NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$WORK/state"
          source "$RECOVER" >/dev/null 2>&1
          _recover_parse_registry "$reg" ) 2>&1 1>/dev/null
    }
    assert_not_contains "readable registry emits NO not-readable diagnostic" \
                        "$(quiet_stderr)" "NOT READABLE"
else
    th_skip "bootstrap-recover parser NAMES the condition (root)"
    th_skip "svc.sh parser NAMES the condition (root)"
    th_skip "_service_health parser NAMES the condition (root)"
    th_skip "readable registry emits no diagnostic (root)"
fi

# ===========================================================================
# 7. THE TRAP THAT ALMOST SHIPPED INSIDE THIS FIX.
#    A readability probe is naturally written `if ! { : ; } < "$f"`. On a
#    COMPOUND command a failed redirection is a redirection ERROR and `!` does
#    NOT invert it, so that guard PARSES, READS CORRECTLY, AND NEVER FIRES —
#    the defect class this whole issue is about, arriving inside its own
#    remedy. Four of the ten files carried it; the _idle_probe arm above is
#    what caught it. Pinned here so it cannot come back.
#
#    zsh DISAGREES with bash on the compound form, so an interactive probe on
#    this zsh-default nexus confirms the BROKEN shape. That is asserted too,
#    because it is the reason the trap is reachable at all.
# ===========================================================================

trap_probe() {                   # trap_probe <shell> <form> -> rc
    local sh="$1" form="$2" f="$WORK/trap.unreadable"
    printf 'x\n' > "$f"; chmod 0000 "$f"
    "$sh" -c "$form" >/dev/null 2>&1
    local rc=$?
    chmod 0644 "$f" 2>/dev/null || true
    printf '%s' "$rc"
}
F_UNREAD="$WORK/trap.unreadable"

if (( UNREADABLE_WORKS )); then
    assert_eq "bash: an unreadable open on a SIMPLE command IS negatable (! : < f -> 0)" \
              "$(trap_probe bash "! : 2>/dev/null < '$F_UNREAD'")" 0
    assert_eq "bash: the same negation on a COMPOUND command is IGNORED (! { :; } < f -> 1)" \
              "$(trap_probe bash "! { : ; } 2>/dev/null < '$F_UNREAD'")" 1
    assert_eq "bash: the || form is NOT affected — it is the one to use" \
              "$(trap_probe bash "{ : ; } 2>/dev/null < '$F_UNREAD' || exit 0; exit 1")" 0
    assert_eq "zsh DISAGREES with bash on the compound form, so an interactive probe misleads" \
              "$(trap_probe zsh "! { : ; } 2>/dev/null < '$F_UNREAD'")" 0
    # And the shipped predicates negate a FUNCTION CALL — a simple command —
    # which is why they fire. Asserted against the real function, not a mock.
    reg_pred_rc() {
        local reg="$WORK/pred.registry"
        new_reg "$reg" a; chmod 0000 "$reg"
        ( set -uo pipefail
          export NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$WORK/state"
          # shellcheck disable=SC1090
          source "$RECOVER" >/dev/null 2>&1
          if ! _recover_registry_readable "$reg"; then exit 0; fi; exit 1 )
        local rc=$?; chmod 0644 "$reg" 2>/dev/null || true; printf '%s' "$rc"
    }
    assert_eq "the SHIPPED predicate does fire when negated (it is a function call)" \
              "$(reg_pred_rc)" 0
else
    th_skip "bash: simple-command negation (root)"
    th_skip "bash: compound-command negation IGNORED (root)"
    th_skip "bash: the || form is unaffected (root)"
    th_skip "zsh disagrees with bash (root)"
    th_skip "the SHIPPED predicate fires when negated (root)"
fi

# ===========================================================================
# 8. THE SWEEP THAT LOOKS FOR THE TRAP CAN ITSELF SILENTLY NOT RUN, and the
#    two failures COMPOSE into a two-layer confident all-clear.
#
#    Section 7's defect makes a GUARD silently not fire. The natural way to
#    confirm a tree is free of it is a corpus grep — and on this zsh-default
#    board the natural way to write THAT is an unquoted file list, which zsh
#    does not word-split: grep receives ONE argument (the whole joined string),
#    says "No such file or directory" on STDERR, and the habitual `2>/dev/null`
#    eats it. The sweep returns "none" and CONFIRMS THE FIX FOR THE WRONG
#    REASON. Both layers return the reassuring answer and they agree with each
#    other.
#
#    So the rule this pins is not "grep for the shape" — it is: A SWEEP MUST
#    DEMONSTRATE IT CAN FIND SOMETHING BEFORE ITS ZERO IS BELIEVED. The
#    positive control runs first, against a planted file, and only then is the
#    real-tree zero allowed to mean anything.
# ===========================================================================

SWEEPDIR="$WORK/sweep"; mkdir -p "$SWEEPDIR"
# Planted POSITIVE control: a file that genuinely carries the defeated form.
printf 'if ! { : ; } 2>/dev/null < "$f"; then :; fi\n' > "$SWEEPDIR/planted_bad.sh"
# Planted NEGATIVE control: the correct predicate shape, must NOT match.
printf 'if ! reg_open_ok "$f"; then :; fi\n'           > "$SWEEPDIR/planted_ok.sh"

# The BROKEN sweep idiom, reproduced verbatim, to pin WHY it must not be used.
sweep_unquoted() {
    zsh -c 'FILES="'"$SWEEPDIR"'/planted_bad.sh '"$SWEEPDIR"'/planted_ok.sh"
            grep -l "! *[{(]" $FILES 2>/dev/null | grep -c . ' 2>/dev/null
}
# The CORRECT sweep idiom: an array, quoted expansion, stderr NOT suppressed.
sweep_array() {
    zsh -c 'F=('"$SWEEPDIR"'/planted_bad.sh '"$SWEEPDIR"'/planted_ok.sh)
            grep -l "! *[{(]" "${F[@]}" | grep -c . '
}
assert_eq "sweep: the UNQUOTED zsh idiom finds NOTHING even with a planted hit" \
          "$(sweep_unquoted)" 0
assert_eq "sweep POSITIVE CONTROL: the array idiom DOES find the planted hit" \
          "$(sweep_array)" 1

# THIS FILE IS ITSELF AN OFFENDER, ON PURPOSE, AND THAT IS THE CONTROL.
# It carries the defeated form twice as a deliberate fixture (the trap_probe
# arms above, and planted_bad.sh) because it exists to demonstrate the shape.
# So the corpus sweep is split in two, and the SELF-MATCH is asserted rather
# than suppressed:
#   (a) THIS suite MUST match  -> the predicate demonstrably fires against a
#       REAL TRACKED FILE in the real population, not only against a temp
#       fixture. That is a stronger positive control than planted_bad.sh.
#   (b) EVERY OTHER shipped file must NOT match.
# An exclusion that is merely asserted to be "the fixtures" is a blind spot;
# an exclusion whose excluded member is REQUIRED to match is not.
#
# HOW THIS ARM WAS ITSELF CAUGHT, because it is this bundle's own class:
# while the suite was UNTRACKED it was absent from `git ls-files`, so the
# sweep returned 0 and passed — a confident green about a tree that did not
# contain the file under test. `git add` alone flipped it to 1 offender. That
# is your-org/nexus-code#1054's trackedness axis, arriving inside the guard
# written to catch silent zeros.
SELF='monitor/watcher/test-registry-unreadable-refusal.sh'
DEFEATED_RE='^[^#]*![[:space:]]*[{(][^)}]*[;)}][^#]*<'

tree_offenders() {                # -> "<count>|<names>" over EVERY file BUT SELF
    local -a F
    while IFS= read -r line; do F+=("$line"); done < <(
        git -C "$_repo_root" ls-files -- ':(glob)monitor/*.sh' ':(glob)monitor/watcher/*.sh' 2>/dev/null)
    (( ${#F[@]} > 0 )) || { printf 'POPULATION-EMPTY|'; return; }
    local f n=0 names=""
    for f in "${F[@]}"; do
        [[ "$f" == "$SELF" ]] && continue
        if grep -hE "$DEFEATED_RE" "$_repo_root/$f" >/dev/null 2>&1; then
            n=$(( n + 1 )); names="$names $f"
        fi
    done
    printf '%s|%s' "$n" "$names"
}

self_matches() {                  # the excluded member MUST match
    grep -cE "$DEFEATED_RE" "$_repo_root/$SELF" 2>/dev/null || true   # grep -c prints its own 0; a fallback print would double it
}

TREE_RAW="$(tree_offenders)"; TREE_N="${TREE_RAW%%|*}"; TREE_NAMES="${TREE_RAW#*|}"
assert_not_contains "sweep: the population is NON-EMPTY before its zero is read" \
                    "$TREE_N" "POPULATION-EMPTY"
# POSITIVE CONTROL on REAL tracked content, not a temp fixture: the one file
# excluded above is required to match, so the exclusion cannot hide a dead
# predicate.
assert_eq "sweep POSITIVE CONTROL: the predicate fires on this suite's own tracked fixtures" \
          "$( [[ "$(self_matches)" -ge 1 ]] && echo yes || echo no )" yes
assert_eq "sweep: no OTHER shipped shell file carries the defeated form (offenders:${TREE_NAMES:-none})" \
          "$TREE_N" 0

# ===========================================================================
# 9. THE REPLICA CENSUS IS ASSERTED, NOT DESCRIBED (round-2 skeptic finding).
#
#    bootstrap-recover.sh's contract block said the predicate was replicated
#    into THREE files. There are SEVEN copies, in TWO FAMILIES with OPPOSITE
#    absent-case behaviour:
#      A  `[[ -e ]] || return 0`  ABSENT is an ANSWER (rc 0) — the documented
#         contract; used by the PARSERS, where "no registry" means "no rows".
#      B  `[[ -f ]] || return 1`  ABSENT reports NOT-READABLE — bare open tests,
#         SAFE only because each call site gates them behind `[[ -e ]]` first.
#
#    Every copy is correct where it stands. The hazard is the NEXT call site:
#    a reader told to "keep in step" who copies the nearest predicate gets the
#    wrong contract half the time, and calling a family-B copy unguarded turns
#    an ABSENT registry into "the machinery failed" — which for
#    `_remote_reg_open_ok` is a fresh clone's documented off-by-default state.
#
#    A hand-maintained census beside a hand-maintained count is two things to
#    keep in sync; this asserts them instead. BOTH directions: every named
#    member must exist AND behave as its family says, and the total must match.
# ===========================================================================

FAMILY_A='_recover_registry_readable _sh_registry_readable svc_registry_readable'
FAMILY_B='_version_registry_readable _idle_registry_readable _remote_reg_open_ok _requests_reg_open_ok'

pred_file() {                    # pred_file <fn> -> path defining it
    grep -rl "^$1() {" "$_repo_root/monitor" 2>/dev/null | head -1
}
pred_absent_rc() {               # pred_absent_rc <fn> -> rc for an ABSENT path
    local fn="$1" f; f="$(pred_file "$fn")"
    [[ -n "$f" ]] || { printf 'NOFILE'; return; }
    ( set -uo pipefail
      export NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$WORK/state" NEXUS_SERVICES_REGISTRY="$WORK/nope"
      # shellcheck disable=SC1090
      source "$f" >/dev/null 2>&1
      "$fn" "$WORK/definitely-not-there" >/dev/null 2>&1 )
    printf '%s' "$?"
}

for _fn in $FAMILY_A; do
    assert_eq "census: family-A member $_fn exists" \
              "$( [[ -n "$(pred_file "$_fn")" ]] && echo yes || echo no )" yes
    assert_eq "census: family-A $_fn treats ABSENT as an ANSWER (rc 0)" \
              "$(pred_absent_rc "$_fn")" 0
done
for _fn in $FAMILY_B; do
    assert_eq "census: family-B member $_fn exists" \
              "$( [[ -n "$(pred_file "$_fn")" ]] && echo yes || echo no )" yes
    assert_eq "census: family-B $_fn reports ABSENT as not-readable (rc 1) — safe ONLY behind [[ -e ]]" \
              "$(pred_absent_rc "$_fn")" 1
done

# THE TOTAL: no EIGHTH copy may appear un-censused. Counted from the tree, not
# from the two lists above, or this would agree with itself.
census_total() {
    grep -rhoE '^[_a-z][_a-z0-9]*(registry_readable|reg_open_ok)\(\) \{' \
         "$_repo_root/monitor" 2>/dev/null | sed 's/() {//' | sort -u | grep -c .
}
assert_eq "census: the tree holds exactly the 7 predicates this block names" \
          "$(census_total)" 7

# THE DEAD CONSTANT must stay dead: it had zero readers while claiming call
# sites used it, and the watcher modules cannot source the file defining it.
# Count matching LINES across the tree, not per-file counts: `grep -rhc` emits
# one number PER FILE, so the substitution was a multi-line string ("0\n0") and
# the comparison could never hold. Count the lines themselves.
dead_const_lines() {
    grep -rhE '^[[:space:]]*NEXUS_REGISTRY_NOT_READABLE=' "$_repo_root/monitor" 2>/dev/null | grep -c . || true
}
assert_eq "no NEXUS_REGISTRY_NOT_READABLE assignment survives (a constant that cannot be shared)" \
          "$(dead_const_lines)" 0

# ===========================================================================
# COUNT GUARD (your-org/nexus-code#821 / #1308). The ledger proves no assertion
# was LOST in a subshell; it cannot prove one was never REACHED. A suite whose
# arms stop running still prints a green summary of whatever did run, so the
# count is declared here and compared EXACTLY. Bump it deliberately when adding
# an arm; a mismatch is a red, not a warning.
# ===========================================================================
EXPECTED_ASSERTIONS=75
_run_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
