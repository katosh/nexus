#!/usr/bin/env bash
# Guard: every knob `_over_limit.sh` reads is reachable from `config/nexus.yml`,
# and the value that arrives CHANGES WHAT THE MODULE DOES.
# (your-org/nexus-code#976; the knobs came in with #592 / #593.)
#
# Run: bash monitor/watcher/test-over-limit-config-bridge.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS EXISTS. Three of the eight `MONITOR_OVER_LIMIT_*` knobs shipped
# read-only from the ENVIRONMENT: `_over_limit.sh` consumed
# `observation_staleness` / `suppression_alert` / `suppression_reminder` via
# `${VAR:-N}`, and no line of `_config.sh` resolved them. An operator writing
#
#     monitor:
#       over_limit:
#         suppression_reminder_seconds: 7200
#
# got silence — the YAML parsed, the key was read by nothing, nothing warned,
# and the in-code default stood. A configuration surface that accepts input and
# discards it is this workspace's dominant defect class, and it was sitting on
# the one module whose entire purpose is telling the operator that their
# channel has been muted.
#
# WHY IT ASSERTS BEHAVIOUR AND NOT VARIABLES. The obvious guard — source
# `_config.sh` against a fixture config and check `[[ -n "$MONITOR_… ]]` — would
# REPRODUCE THE DEFECT ONE LAYER UP. A name that resolves and reaches no
# decision is still ignored; the property worth pinning is that the operator's
# number arrives at the branch it governs. So every case below drives the real
# `_over_limit.sh` predicate and asserts the DECISION flips, with the
# in-code-default arm run as the paired control in the same process. Without
# that control a "gate opened" assertion passes for an implementation that
# never closes the gate at all.
#
# THE THREE PROPERTIES, one per knob:
#   observation_staleness — how old an over-limit sighting may be and still
#       keep the orchestrator emit gate CLOSED. Lower it and a sighting that
#       was fresh becomes stale, so the gate OPENS.
#   suppression_alert     — how long a hold must last before the FIRST
#       out-of-band announcement. Lower it and a hold that was too young to
#       announce announces.
#   suppression_reminder  — the cadence of reminders AFTER that first
#       announcement. Lower it and a second call that was too soon reminds.
#
# Plus, for all three: env override still beats YAML (the documented
# precedence, and the reason the bridge is written `${VAR:-$(lookup)}`), and a
# malformed YAML value falls back to the in-code default rather than poisoning
# the arithmetic.
#
# The REAL `config/load.sh` is used throughout, never a stub: the whole bridge
# is that program's answer, and a stub would replay this author's belief about
# it. Same reason `test-config-integration-branch.sh` gives.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
. "$_test_dir/_test_helpers.sh"

HELPER="$_repo_root/monitor/watcher/_over_limit.sh"
CONFIG_SH="$_repo_root/monitor/watcher/_config.sh"
LOAD="$_repo_root/config/load.sh"
for f in "$HELPER" "$CONFIG_SH" "$LOAD"; do
    [[ -f "$f" ]] || th_abort "missing source file: $f"
done

if ! python3 -c 'import yaml' 2>/dev/null; then
    th_skip "python3 + pyyaml unavailable; config/load.sh cannot run"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- fixtures -------------------------------------------------------------

# make_root <name> [<over_limit-key: value> …] — a nexus root carrying the REAL
# config/load.sh and a nexus.yml whose `monitor.over_limit` block holds exactly
# the supplied keys. With none, the block is absent entirely, which is the
# shape of every clone that has never touched these knobs.
make_root() {
    local name="$1"; shift
    local root="$WORK/$name"
    mkdir -p "$root/config"
    cp "$LOAD" "$root/config/load.sh"
    chmod +x "$root/config/load.sh"
    {
        printf 'monitor:\n'
        printf '  interval_seconds: 60\n'
        if (( $# )); then
            printf '  over_limit:\n'
            local kv
            for kv in "$@"; do printf '    %s\n' "$kv"; done
        fi
    } > "$root/config/nexus.yml"
    printf '%s' "$root"
}

# resolve <root> [VAR=VAL …] — source `_config.sh` against <root> in a CLEAN
# subshell and print the three knobs as `staleness|alert|reminder`.
#
# A subshell, not a function call: `_config.sh` is explicitly NOT
# side-effect-free (it sets ~50 globals and runs one export block), so sourcing
# it twice in one process would leak the first fixture's answers into the
# second and every later case would assert against stale state.
resolve() (
    local root="$1"; shift
    unset MONITOR_OVER_LIMIT_OBSERVATION_STALENESS_SECONDS
    unset MONITOR_OVER_LIMIT_SUPPRESSION_ALERT_SECONDS
    unset MONITOR_OVER_LIMIT_SUPPRESSION_REMINDER_SECONDS
    unset NEXUS_CONFIG
    local kv
    for kv in "$@"; do export "${kv?}"; done
    export NEXUS_ROOT="$root"
    _cfg="$root/config/load.sh"
    # shellcheck disable=SC1090
    . "$CONFIG_SH" >/dev/null 2>&1
    printf '%s|%s|%s' \
        "${MONITOR_OVER_LIMIT_OBSERVATION_STALENESS_SECONDS:-}" \
        "${MONITOR_OVER_LIMIT_SUPPRESSION_ALERT_SECONDS:-}" \
        "${MONITOR_OVER_LIMIT_SUPPRESSION_REMINDER_SECONDS:-}"
)

# ---- the behavioural drivers ---------------------------------------------
#
# Each runs the REAL predicate from `_over_limit.sh` in a fresh subshell with a
# fresh STATE_DIR and a pinned clock, and prints what the module DECIDED.

# gate_open <staleness> <observation-age-seconds> — print `open` / `closed`.
# `_over_limit_orchestrator_paused` returning 0 means the hold is corroborated
# and the emit gate stays CLOSED; non-zero means the sighting went stale and
# the gate OPENS (the deliberate fail-open polarity: absent evidence of
# suspension, emit).
gate_open() (
    local staleness="$1" age="$2"
    STATE_DIR="$WORK/gate.$$.$RANDOM"; mkdir -p "$STATE_DIR"; export STATE_DIR
    local _FAKE_NOW=1800000000
    printf '_orchestrator\t%s\n' "$(( _FAKE_NOW - age ))" > "$STATE_DIR/over-limit-observed.tsv"
    printf '_orchestrator\torchestrator\torch\t11pm\t%s\t%s\t0\t0\n' \
        "$(( _FAKE_NOW + 3600 ))" "$(( _FAKE_NOW - age ))" > "$STATE_DIR/over-limit-state.tsv"
    date() { if [[ "$1" == "+%s" && $# -eq 1 ]]; then printf '%s\n' "$_FAKE_NOW"; else command date "$@"; fi; }
    export MONITOR_OVER_LIMIT_OBSERVATION_STALENESS_SECONDS="$staleness"
    # shellcheck disable=SC1090
    . "$HELPER" >/dev/null 2>&1
    if _over_limit_orchestrator_paused; then printf 'closed'; else printf 'open'; fi
)

# announce <alert> <reminder> <hold-age> <prior-announcement-age|-> — print the
# `kind` the alert carried (`began` / `continues`), or `silent`.
# `-` for the fourth argument means no prior announcement stamp exists.
announce() (
    local alert="$1" reminder="$2" hold_age="$3" prior="$4"
    STATE_DIR="$WORK/ann.$$.$RANDOM"; mkdir -p "$STATE_DIR"; export STATE_DIR
    local _FAKE_NOW=1800000000
    printf '_orchestrator\t%s\n' "$_FAKE_NOW" > "$STATE_DIR/over-limit-observed.tsv"
    printf '_orchestrator\torchestrator\torch\t11pm\t%s\t%s\t0\t0\n' \
        "$(( _FAKE_NOW + 3600 ))" "$(( _FAKE_NOW - hold_age ))" > "$STATE_DIR/over-limit-state.tsv"
    [[ "$prior" == "-" ]] || printf '%s' "$(( _FAKE_NOW - prior ))" > "$STATE_DIR/over-limit-alert.stamp"
    date() { if [[ "$1" == "+%s" && $# -eq 1 ]]; then printf '%s\n' "$_FAKE_NOW"; else command date "$@"; fi; }
    export MONITOR_OVER_LIMIT_SUPPRESSION_ALERT_SECONDS="$alert"
    export MONITOR_OVER_LIMIT_SUPPRESSION_REMINDER_SECONDS="$reminder"
    _OVER_LIMIT_ALERT_FN=_probe_alert
    _probe_alert() { printf '%s\n' "$1" > "$STATE_DIR/alert.out"; }
    # shellcheck disable=SC1090
    . "$HELPER" >/dev/null 2>&1
    _OVER_LIMIT_ALERT_FN=_probe_alert
    _over_limit_maybe_alert_suppression
    if [[ -s "$STATE_DIR/alert.out" ]]; then
        # `awk NR==1` rather than `| head -1`: a `head` closes the pipe early,
        # which puts this file on the EPIPE-under-pipefail axis
        # `early-exit-readers.sh` tracks (#622). awk drains, so it does not.
        grep -oE 'over-limit hold (began|continues)' "$STATE_DIR/alert.out" \
            | awk 'NR==1{print $NF}'
    else
        printf 'silent'
    fi
)

# ---- §0 the drivers are potent (controls before claims) -------------------
#
# Every assertion below reads a DIFFERENCE between two driver runs. If either
# driver were inert — always `open`, always `silent` — half the pairs would
# still look right. So pin both arms of both drivers first, on the in-code
# defaults, with no config involved at all.
echo "=== §0 driver potency: both outcomes reachable on the in-code defaults ==="
assert_eq "gate: a 10s-old sighting at staleness 600 keeps the gate CLOSED" \
    "$(gate_open 600 10)" "closed"
assert_eq "gate: a 5000s-old sighting at staleness 600 OPENS it" \
    "$(gate_open 600 5000)" "open"
assert_eq "alert: a 120s hold at alert-delay 900 stays SILENT" \
    "$(announce 900 3600 120 -)" "silent"
assert_eq "alert: a 5000s hold at alert-delay 900 announces (began)" \
    "$(announce 900 3600 5000 -)" "began"
assert_eq "alert: 180s after an announcement, reminder 3600 stays SILENT" \
    "$(announce 900 3600 5000 180)" "silent"
assert_eq "alert: 5000s after an announcement, reminder 3600 REMINDS" \
    "$(announce 900 3600 9000 5000)" "continues"

# ---- §1 the bridge exists and carries the operator's number ---------------
echo "=== §1 the three #976 knobs resolve from config/nexus.yml ==="
DEFAULT_ROOT=$(make_root defaults)
assert_eq "no over_limit block at all -> the in-code defaults" \
    "$(resolve "$DEFAULT_ROOT")" "600|900|3600"

SET_ROOT=$(make_root operator \
    "observation_staleness_seconds: 30" \
    "suppression_alert_seconds: 60" \
    "suppression_reminder_seconds: 7200")
assert_eq "an operator's values reach _config.sh" \
    "$(resolve "$SET_ROOT")" "30|60|7200"

assert_eq "env override still beats YAML (documented precedence)" \
    "$(resolve "$SET_ROOT" \
        MONITOR_OVER_LIMIT_OBSERVATION_STALENESS_SECONDS=31 \
        MONITOR_OVER_LIMIT_SUPPRESSION_ALERT_SECONDS=61 \
        MONITOR_OVER_LIMIT_SUPPRESSION_REMINDER_SECONDS=7201)" \
    "31|61|7201"

# ---- §2 the number CHANGES THE DECISION -----------------------------------
#
# This is the section the issue is actually about. §1 alone would pass for a
# bridge that resolves the key into a variable nothing consults — which is the
# same silent-ignore one layer up.
echo "=== §2 the resolved value flips the real predicate ==="

# The sighting age is held CONSTANT at 300s across the pair; only the
# configured staleness moves. So the difference is attributable to the knob and
# to nothing else.
assert_eq "staleness 600 (default) + a 300s-old sighting -> gate CLOSED" \
    "$(gate_open 600 300)" "closed"
assert_eq "staleness 30 (operator) + the SAME 300s-old sighting -> gate OPENS" \
    "$(gate_open 30 300)" "open"

# Hold age held constant at 120s; only the announcement delay moves.
assert_eq "alert-delay 900 (default) + a 120s hold -> silent" \
    "$(announce 900 3600 120 -)" "silent"
assert_eq "alert-delay 60 (operator) + the SAME 120s hold -> announces" \
    "$(announce 60 3600 120 -)" "began"

# Prior-announcement age held constant at 180s; only the reminder cadence
# moves. This is the lever #593's skeptic named as the one an operator reaches
# for when the shipped cadence is wrong for their site.
assert_eq "reminder 3600 (default) + a 180s-old announcement -> silent" \
    "$(announce 60 3600 5000 180)" "silent"
assert_eq "reminder 120 (operator) + the SAME 180s-old announcement -> reminds" \
    "$(announce 60 120 5000 180)" "continues"

# ---- §2b END-TO-END: the YAML FILE flips the predicate --------------------
#
# §1 and §2 are two links of one chain asserted separately — YAML reaches the
# variable, the variable reaches the decision. Both pass, individually, for a
# build where the two halves are wired to different names. Measured: §2 alone
# is GREEN on the pre-fix tree, because its drivers export the env var by hand
# and never consult a config file. So the load-bearing assertion is this one —
# nothing but `config/nexus.yml` differs between the arms, and the module's
# answer moves.
echo "=== §2b end-to-end: only nexus.yml differs, and the decision changes ==="

# via_yaml <root> <driver> <driver-args…> — source `_config.sh` against <root>
# in a fresh subshell (so its ~50 globals and its export block are real), then
# run the driver with NO env override in play.
via_yaml() (
    local root="$1"; shift
    unset MONITOR_OVER_LIMIT_OBSERVATION_STALENESS_SECONDS
    unset MONITOR_OVER_LIMIT_SUPPRESSION_ALERT_SECONDS
    unset MONITOR_OVER_LIMIT_SUPPRESSION_REMINDER_SECONDS
    unset NEXUS_CONFIG
    export NEXUS_ROOT="$root"
    _cfg="$root/config/load.sh"
    # shellcheck disable=SC1090
    . "$CONFIG_SH" >/dev/null 2>&1
    "$@"
)

# The drivers again, in a form that takes the knobs from the AMBIENT
# environment `_config.sh` just populated rather than from an argument.
gate_open_ambient() (
    local age="$1"
    STATE_DIR="$WORK/gy.$$.$RANDOM"; mkdir -p "$STATE_DIR"; export STATE_DIR
    local _FAKE_NOW=1800000000
    printf '_orchestrator\t%s\n' "$(( _FAKE_NOW - age ))" > "$STATE_DIR/over-limit-observed.tsv"
    printf '_orchestrator\torchestrator\torch\t11pm\t%s\t%s\t0\t0\n' \
        "$(( _FAKE_NOW + 3600 ))" "$(( _FAKE_NOW - age ))" > "$STATE_DIR/over-limit-state.tsv"
    date() { if [[ "$1" == "+%s" && $# -eq 1 ]]; then printf '%s\n' "$_FAKE_NOW"; else command date "$@"; fi; }
    # shellcheck disable=SC1090
    . "$HELPER" >/dev/null 2>&1
    if _over_limit_orchestrator_paused; then printf 'closed'; else printf 'open'; fi
)

announce_ambient() (
    local hold_age="$1" prior="$2"
    STATE_DIR="$WORK/ay.$$.$RANDOM"; mkdir -p "$STATE_DIR"; export STATE_DIR
    local _FAKE_NOW=1800000000
    printf '_orchestrator\t%s\n' "$_FAKE_NOW" > "$STATE_DIR/over-limit-observed.tsv"
    printf '_orchestrator\torchestrator\torch\t11pm\t%s\t%s\t0\t0\n' \
        "$(( _FAKE_NOW + 3600 ))" "$(( _FAKE_NOW - hold_age ))" > "$STATE_DIR/over-limit-state.tsv"
    [[ "$prior" == "-" ]] || printf '%s' "$(( _FAKE_NOW - prior ))" > "$STATE_DIR/over-limit-alert.stamp"
    date() { if [[ "$1" == "+%s" && $# -eq 1 ]]; then printf '%s\n' "$_FAKE_NOW"; else command date "$@"; fi; }
    _OVER_LIMIT_ALERT_FN=_probe_alert
    _probe_alert() { printf '%s\n' "$1" > "$STATE_DIR/alert.out"; }
    # shellcheck disable=SC1090
    . "$HELPER" >/dev/null 2>&1
    _OVER_LIMIT_ALERT_FN=_probe_alert
    _over_limit_maybe_alert_suppression
    if [[ -s "$STATE_DIR/alert.out" ]]; then
        # `awk NR==1` rather than `| head -1`: a `head` closes the pipe early,
        # which puts this file on the EPIPE-under-pipefail axis
        # `early-exit-readers.sh` tracks (#622). awk drains, so it does not.
        grep -oE 'over-limit hold (began|continues)' "$STATE_DIR/alert.out" \
            | awk 'NR==1{print $NF}'
    else
        printf 'silent'
    fi
)

# One fixture pair per knob: identical in every respect but the one YAML line.
STALE_ROOT=$(make_root e2e-stale "observation_staleness_seconds: 30")
assert_eq "gate, no over_limit block: a 300s-old sighting keeps it CLOSED" \
    "$(via_yaml "$DEFAULT_ROOT" gate_open_ambient 300)" "closed"
assert_eq "gate, ONLY nexus.yml changed (staleness: 30): the SAME input OPENS it" \
    "$(via_yaml "$STALE_ROOT" gate_open_ambient 300)" "open"

ALERT_ROOT=$(make_root e2e-alert "suppression_alert_seconds: 60")
assert_eq "alert, no over_limit block: a 120s hold stays silent" \
    "$(via_yaml "$DEFAULT_ROOT" announce_ambient 120 -)" "silent"
assert_eq "alert, ONLY nexus.yml changed (alert: 60): the SAME hold announces" \
    "$(via_yaml "$ALERT_ROOT" announce_ambient 120 -)" "began"

# For the reminder both arms must already be PAST the announcement delay, or
# the difference would be attributable to `suppression_alert_seconds` instead.
# So the control carries `alert: 60` too, and `reminder` is the only line that
# differs between the two files.
REMIND_ROOT=$(make_root e2e-remind \
    "suppression_alert_seconds: 60" "suppression_reminder_seconds: 120")
ALERT_ONLY_ROOT=$(make_root e2e-alert-only "suppression_alert_seconds: 60")
assert_eq "reminder, default 3600: a 180s-old announcement stays silent" \
    "$(via_yaml "$ALERT_ONLY_ROOT" announce_ambient 5000 180)" "silent"
assert_eq "reminder, ONLY nexus.yml changed (reminder: 120): the SAME state reminds" \
    "$(via_yaml "$REMIND_ROOT" announce_ambient 5000 180)" "continues"

# ---- §3 a malformed value degrades to the default, loudly-in-effect -------
#
# `_over_limit.sh` validates each knob with `[[ =~ ^[0-9]+$ ]] || <default>`.
# That arm is only reachable once a bridge can deliver a non-numeric value, so
# it acquires its first real caller with this change and is pinned here.
echo "=== §3 a non-numeric YAML value falls back rather than poisoning ==="
BAD_ROOT=$(make_root malformed \
    "observation_staleness_seconds: soon" \
    "suppression_alert_seconds: later" \
    "suppression_reminder_seconds: never")
bad=$(resolve "$BAD_ROOT")
assert_eq "the loader passes the garbage through verbatim (it is not the validator)" \
    "$bad" "soon|later|never"
assert_eq "the gate ignores a non-numeric staleness and uses 600" \
    "$(gate_open soon 300)" "closed"
assert_eq "…and still opens past 600 with the same garbage value" \
    "$(gate_open soon 5000)" "open"
assert_eq "the alert ignores a non-numeric delay and uses 900" \
    "$(announce later never 120 -)" "silent"

# ---- §4 no MONITOR_OVER_LIMIT_* knob is left unbridged --------------------
#
# The three fixed here were found by hand. The property that would have found
# them — and will find the next one — is set equality between what
# `_over_limit.sh` READS and what `_config.sh` RESOLVES, so it is asserted as a
# set rather than as a count. A count agreeing proves only that two numbers
# agree; naming the members says which one drifted.
echo "=== §4 read-set == bridged-set, as SETS not counts ==="
read_set=$(grep -oE 'MONITOR_OVER_LIMIT_[A-Z_]+' "$HELPER" | sort -u)
bridged_set=$(grep -oE '^MONITOR_OVER_LIMIT_[A-Z_]+=' "$CONFIG_SH" | tr -d '=' | sort -u)
exported_set=$(sed -n '/^export /,/^[^ ]/p' "$CONFIG_SH" \
                 | grep -oE 'MONITOR_OVER_LIMIT_[A-Z_]+' | sort -u)

# NON-VACUITY FIRST: all three extractions are regexes over source text, and an
# empty set compares equal to an empty set. `#976` is itself an instance of a
# probe that returned a confident answer about a population it never read.
assert_eq "extraction is non-vacuous: the read set is non-empty" \
    "$([[ -n "$read_set" ]] && echo yes || echo no)" "yes"
assert_eq "extraction is non-vacuous: 9 knobs are read (sanity-checked total)" \
    "$(printf '%s\n' "$read_set" | grep -c .)" "9"

assert_eq "every knob _over_limit.sh reads is resolved by _config.sh" \
    "$(comm -23 <(printf '%s\n' "$read_set") <(printf '%s\n' "$bridged_set") | tr '\n' ' ')" ""
assert_eq "every knob _config.sh resolves is exported to the scan subshell" \
    "$(comm -23 <(printf '%s\n' "$bridged_set") <(printf '%s\n' "$exported_set") | tr '\n' ' ')" ""

# NEGATIVE CONTROL for §4: the set difference must actually report a member.
# Without this, all three assertions above pass for a `comm` invocation that
# silently prints nothing — which is the shape of the very bug being guarded.
assert_eq "control: a planted unbridged knob IS named by the same comparison" \
    "$(comm -23 <(printf '%s\nMONITOR_OVER_LIMIT_PLANTED\n' "$read_set" | sort -u) \
                <(printf '%s\n' "$bridged_set") | tr '\n' ' ')" \
    "MONITOR_OVER_LIMIT_PLANTED "

# ---- assertion-count guard ------------------------------------------------
# The subject here is a value that is silently unreachable; a version of this
# suite that quietly ran a subset would be the same defect wearing its name.
EXPECTED_ASSERTIONS=30
TOTAL=$(( PASS + FAIL ))
if (( TOTAL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi

th_summary_and_exit
