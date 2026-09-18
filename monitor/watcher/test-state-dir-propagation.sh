#!/usr/bin/env bash
# Lint + behavioural guard for the #1335 class: a script that RESOLVES a state
# dir and spawns `ng log-action` must hand the resolved dir to the child under
# the name the child reads — `NEXUS_STATE_DIR` — or the child re-resolves on
# its own and the audit row lands on the inherited root (the operator's live
# `action-log.jsonl`: 10,275 of 30,530 rows on #1369).
#
# Three instances were fixed at their own site before this existed (#973,
# #1143, #1335/#1369); that is why it recurred. This file closes the CLASS:
#
#   1. LINT over every shell file under monitor/ (population decided by
#      `monitor/shell-files.sh:shf_is_shell`, never a filename glob — #1214),
#      ratcheted by `state-dir-propagation.manifest` in BOTH directions.
#   2. POSITIVE + NEGATIVE CONTROLS for the classifier itself, on planted
#      fixtures: the defect shape is flagged; the export form and the
#      per-site prefix form (including the `( NEXUS_STATE_DIR=… timeout \`
#      continuation shape) are not; prose mentions are not invocations.
#   3. BEHAVIOURAL check of one member that cannot resolve for itself —
#      `watcher/_target_absent.sh`, a sourced library — driven to a
#      `log-action` site through a stand-in `ng` that records what it saw.
#
# Run: bash monitor/watcher/test-state-dir-propagation.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
MANIFEST="$_test_dir/state-dir-propagation.manifest"

. "$_test_dir/_test_helpers.sh"
# shellcheck source=monitor/shell-files.sh
. "$_repo_root/monitor/shell-files.sh" || th_abort "cannot source monitor/shell-files.sh"

[[ -f "$MANIFEST" ]] || th_abort "manifest missing: $MANIFEST"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/sdp-XXXXXX") || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# The classifier. Everything greps a FILE, never a pipe: `printf | grep -q`
# under `pipefail` dies of SIGPIPE (rc 141) on any input longer than grep's
# first match, and the prototype of this very lint read `resolves=0` for
# main.sh for exactly that reason — a silent wrong answer inside the
# instrument built to find silent wrong answers.
# ---------------------------------------------------------------------------
_INV='(^|[[:space:](])("?[^[:space:]"]*/ng"?|"?\$[A-Za-z_{}:-]*(ng|bin|BIN|NG)[}]?"?|ng)[[:space:]]+log-action([[:space:]]|$)'

# sdp_classify <file>  ->  "member=<0|1> compliant=<0|1> invocations=<n> unprefixed=<a,b,…>"
sdp_classify() {
    local f="$1" code="$WORK/code.$$" inv="$WORK/inv.$$"
    shf_strip_comments "$f" > "$code" 2>/dev/null || : > "$code"
    # Invocations: command-position `… log-action`, minus prose — a quoted
    # string assignment, a backticked mention inside a message/heredoc, or an
    # echo/printf of the words.
    grep -nE "$_INV" "$code" 2>/dev/null \
        | grep -vE '[A-Za-z_]+="[^"]*log-action' \
        | grep -vE '`' \
        | grep -vE '(printf|echo)[[:space:]].*log-action' > "$inv" || true
    local n_inv; n_inv=$(grep -c . "$inv" || true); n_inv=${n_inv:-0}
    local resolves=0 exports=0
    grep -qE '(^|[[:space:]])STATE_DIR=|_resolve_state_dir|--state-dir' "$code" && resolves=1
    grep -qE 'export[[:space:]]+NEXUS_STATE_DIR=' "$code" && exports=1
    local member=0; (( n_inv > 0 && resolves )) && member=1
    # Per-site prefix: on the invocation line, or on the immediately preceding
    # line when that line ends in `\` (the `( NEXUS_STATE_DIR=… timeout \` shape).
    local unprefixed="" ln prev
    while IFS=: read -r ln _; do
        [[ -n "$ln" ]] || continue
        if grep -qE 'NEXUS_STATE_DIR=' <<<"$(sed -n "${ln}p" "$code")"; then continue; fi
        prev=$(( ln - 1 ))
        if (( prev >= 1 )) && grep -qE 'NEXUS_STATE_DIR=.*\\$' <<<"$(sed -n "${prev}p" "$code")"; then continue; fi
        unprefixed="${unprefixed:+$unprefixed,}$ln"
    done < "$inv"
    local compliant=0
    if (( exports )) || [[ -z "$unprefixed" ]]; then compliant=1; fi
    printf 'member=%d compliant=%d invocations=%d unprefixed=%s\n' \
        "$member" "$compliant" "$n_inv" "${unprefixed:-none}"
}
_field() { printf '%s\n' "$1" | sed -n "s/.*$2=\([^ ]*\).*/\1/p"; }

# ---------------------------------------------------------------------------
echo "=== classifier controls on planted fixtures ==="
mkf() { local n="$1"; shift; printf '%s\n' '#!/usr/bin/env bash' "$@" > "$WORK/$n"; printf '%s' "$WORK/$n"; }

f_defect=$(mkf defect.sh \
    'STATE_DIR="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"' \
    'export STATE_DIR' \
    '"$self_dir/ng" log-action probe --event x')
v=$(sdp_classify "$f_defect")
assert_eq "POSITIVE CONTROL: the defect shape is a NON-compliant member" \
    "member=$(_field "$v" member) compliant=$(_field "$v" compliant)" "member=1 compliant=0"
assert_eq "…naming the unprefixed line (line 1 is the shebang)" "$(_field "$v" unprefixed)" "4"

f_export=$(mkf export.sh \
    'STATE_DIR="$NEXUS_ROOT/monitor/.state"' \
    'export NEXUS_STATE_DIR="$STATE_DIR"' \
    '"$ng_bin" log-action probe --event x')
v=$(sdp_classify "$f_export")
assert_eq "the per-script export form is compliant" \
    "member=$(_field "$v" member) compliant=$(_field "$v" compliant)" "member=1 compliant=1"

f_prefix=$(mkf prefix.sh \
    'STATE_DIR="$NEXUS_ROOT/monitor/.state"' \
    '( NEXUS_STATE_DIR="$STATE_DIR" timeout 60 \' \
    '    "$_sk_ng_bin" log-action probe --event x ) || true' \
    'NEXUS_STATE_DIR="$STATE_DIR" "$NEXUS_ROOT/monitor/ng" log-action probe --event y')
v=$(sdp_classify "$f_prefix")
assert_eq "the per-site prefix form (same line AND continued line) is compliant" \
    "member=$(_field "$v" member) compliant=$(_field "$v" compliant) invocations=$(_field "$v" invocations)" \
    "member=1 compliant=1 invocations=2"

f_partial=$(mkf partial.sh \
    'STATE_DIR="$NEXUS_ROOT/monitor/.state"' \
    'NEXUS_STATE_DIR="$STATE_DIR" "$ng" log-action probe --event y' \
    '"$ng" log-action probe --event z')
v=$(sdp_classify "$f_partial")
assert_eq "one prefixed site does not excuse an unprefixed sibling" \
    "compliant=$(_field "$v" compliant) unprefixed=$(_field "$v" unprefixed)" "compliant=0 unprefixed=4"

f_prose=$(mkf prose.sh \
    'STATE_DIR="$NEXUS_ROOT/monitor/.state"' \
    'msg="then run monitor/ng log-action monitor --event ack"' \
    'printf "warning: ng log-action append failed\n" >&2' \
    'cat <<EOT' \
    '  `monitor/ng log-action watcher --event respawn-false-positive`' \
    'EOT')
v=$(sdp_classify "$f_prose")
assert_eq "NEGATIVE CONTROL: prose mentions of log-action are not invocations" \
    "member=$(_field "$v" member) invocations=$(_field "$v" invocations)" "member=0 invocations=0"

f_lib=$(mkf lib.sh \
    '"$_monitor_dir/ng" log-action watcher --event e')
v=$(sdp_classify "$f_lib")
assert_eq "a sourced library that resolves nothing is NOT a member (its parent is)" \
    "member=$(_field "$v" member) invocations=$(_field "$v" invocations)" "member=0 invocations=1"

# ---------------------------------------------------------------------------
echo "=== the lint: every shell file under monitor/, ratcheted by the manifest ==="
declare -A KNOWN=()
while IFS=$'\t' read -r path reason; do
    [[ -n "$path" && "$path" != \#* ]] || continue
    KNOWN["$path"]="$reason"
done < "$MANIFEST"

members=0 noncompliant_new="" stale=""
declare -A SEEN=()
while IFS= read -r f; do
    case "$f" in
        monitor/watcher/test-*|monitor/test-*|monitor/ng|*.md|*.manifest) continue ;;
    esac
    shf_is_shell "$_repo_root/$f" || continue
    v=$(sdp_classify "$_repo_root/$f")
    [[ "$(_field "$v" member)" == 1 ]] || continue
    members=$(( members + 1 )); SEEN["$f"]=1
    if [[ "$(_field "$v" compliant)" == 0 ]]; then
        if [[ -z "${KNOWN[$f]:-}" ]]; then
            noncompliant_new="${noncompliant_new}    $f  (unprefixed code lines: $(_field "$v" unprefixed))"$'\n'
        fi
    else
        [[ -n "${KNOWN[$f]:-}" ]] && stale="${stale}    $f  (now compliant — remove it from the manifest)"$'\n'
    fi
done < <(git -C "$_repo_root" ls-files -- monitor)
for k in "${!KNOWN[@]}"; do
    [[ -n "${SEEN[$k]:-}" ]] || stale="${stale}    $k  (no longer a member, or not tracked — remove it from the manifest)"$'\n'
done

# Sanity floor: an enumeration that returns a handful where the class is
# known to hold at least the fixed pair plus the manifest is a broken
# population, not a clean tree (#721, #770).
assert_eq "population sanity: at least 4 members enumerated (got $members)" "$(( members >= 4 ))" "1"
if [[ -n "$noncompliant_new" ]]; then
    printf '  NEW instances of the #1335 class (resolve a state dir, spawn `ng log-action`, propagate nothing):\n%s' "$noncompliant_new" >&2
    printf '  Fix: `export NEXUS_STATE_DIR="$STATE_DIR"` after the script resolves STATE_DIR (see retire-preflight.sh).\n' >&2
fi
assert_eq "no member outside the manifest fails to propagate NEXUS_STATE_DIR" "${noncompliant_new:-none}" "none"
if [[ -n "$stale" ]]; then printf '  STALE manifest entries:\n%s' "$stale" >&2; fi
assert_eq "no manifest entry is stale (ratchet in both directions)" "${stale:-none}" "none"

# The two members this leg fixed must be members AND compliant — pins the
# population predicate against the real tree, not only against fixtures.
for f in monitor/retire-preflight.sh monitor/paste-followup.sh; do
    v=$(sdp_classify "$_repo_root/$f")
    assert_eq "$f is a compliant member" \
        "member=$(_field "$v" member) compliant=$(_field "$v" compliant)" "member=1 compliant=1"
done

# ---------------------------------------------------------------------------
echo "=== behavioural: _target_absent.sh hands STATE_DIR to its ng children ==="
# A sourced library cannot resolve for itself; it must forward what its
# parent (main.sh) resolved. Driven to the re-verify-abort site with the
# same stub shape test-target-absent.sh uses; the stand-in `ng` records the
# NEXUS_STATE_DIR it was handed. Runs in THIS shell, not a subshell: an
# assert_* inside ( … ) loses its counter increment with the child.
STATE_DIR="$WORK/watcher-state"; mkdir -p "$STATE_DIR"
_monitor_dir="$WORK/mon"; mkdir -p "$_monitor_dir"
ENV_LOG="$WORK/ta-env.log"; : > "$ENV_LOG"
cat > "$_monitor_dir/ng" <<'NG'
#!/usr/bin/env bash
printf '%s\t%s\n' "${2:-}" "${NEXUS_STATE_DIR:-<unset>}" >> "${SDP_ENV_LOG:?}"
exit 0
NG
chmod +x "$_monitor_dir/ng"
export SDP_ENV_LOG="$ENV_LOG"
TARGET=orchestrator; AGENT_MISSING_RESPAWN_DELAY=0
RESPAWN_SLOW_GRIND_TRIPPED="$STATE_DIR/sg"; RESPAWN_SLOW_GRIND_COOLDOWN=300
RESPAWN_CONSEC_COUNTER="$STATE_DIR/cc"; RESPAWN_CONSEC_LIMIT=5
RESPAWN_HISTORY="$STATE_DIR/hist"; RESPAWN_LOOP_WINDOW=600; RESPAWN_LOOP_LIMIT=10
RESPAWN_TRIPPED="$STATE_DIR/tripped"
missing_target_polls=0; missing_target_since=0
log() { :; }
_respawn_async_reap() { return 1; }
_respawn_consec_check() { return 1; }
_respawn_consec_reset() { :; }
_respawn_loop_check() { printf 'ok'; return 0; }
_respawn_async_in_flight() { return 1; }
_respawn_verify_target_absent() { printf 'stub: target still live'; return 1; }
_respawn_async_launch() { return 0; }
# shellcheck source=monitor/watcher/_target_absent.sh
. "$_test_dir/_target_absent.sh"
unset NEXUS_STATE_DIR
_watcher_handle_target_absent_observation
assert_eq "the re-verify-abort site logged through ng (agent argv = watcher)" "$(cut -f1 "$ENV_LOG")" "watcher"
assert_eq "…and the child saw NEXUS_STATE_DIR == the watcher's STATE_DIR" "$(cut -f2 "$ENV_LOG")" "$STATE_DIR"
# Polarity: the PARENT's resolution wins over an ambient pin, or the
# watcher reads one dir while its children write another.
: > "$ENV_LOG"; missing_target_polls=0
NEXUS_STATE_DIR="$WORK/ambient-pin" _watcher_handle_target_absent_observation
assert_eq "…and the parent's STATE_DIR wins over an ambient NEXUS_STATE_DIR (no split-brain)" \
    "$(cut -f2 "$ENV_LOG")" "$STATE_DIR"

# ---- assertion-count guard ------------------------------------------------
EXPECTED_ASSERTIONS=15
_ran=$(( ${PASS:-0} + ${FAIL:-0} ))
if (( _ran == EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
