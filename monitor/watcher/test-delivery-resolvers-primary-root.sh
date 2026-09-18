#!/usr/bin/env bash
# test-delivery-resolvers-primary-root.sh — paste-followup.sh and
# harness/generic-tmux.sh resolve the PRIMARY's state dir from a secondary
# clone nested under <primary>/work/, and send.sh's harness lookup reads the
# primary's config (your-org/nexus-code#1428).
# Run: bash monitor/watcher/test-delivery-resolvers-primary-root.sh
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
MON="$_test_dir/.."
WORK=$(mktemp -d -t nxprimroot-XXXXXX); trap 'rm -rf "$WORK"' EXIT
P="$WORK/primary"; C="$P/work/nexus-code-task"
mkdir -p "$P/monitor" "$P/config" "$C/monitor/harness" "$C/config"
printf '#!/usr/bin/env bash\n' > "$P/monitor/ng"; chmod +x "$P/monitor/ng"   # what nexus_primary_root keys on
for f in _nexus-root.sh paste-followup.sh; do cp "$MON/$f" "$C/monitor/$f"; done
cp "$MON/harness/generic-tmux.sh" "$C/monitor/harness/generic-tmux.sh"
_pf() {   # run paste-followup's resolver with _script_dir = the CLONE's monitor
    env -u NEXUS_STATE_DIR "$@" bash -c '_script_dir="$1"; eval "$(sed -n "/^_primary_root_of()/,/^}/p; /^_resolve_state_dir()/,/^}/p" "$1/paste-followup.sh")"; _resolve_state_dir' _ "$C/monitor"
}
_gt() {
    env -u NEXUS_STATE_DIR "$@" bash -c '_mon="$1"; eval "$(sed -n "/^_state_dir()/,/^}/p" "$1/harness/generic-tmux.sh")"; _state_dir' _ "$C/monitor"
}
echo '=== paste-followup.sh ==='
assert_eq "#1428 NEXUS_ROOT=<clone> resolves the PRIMARY's state dir (was the clone's)" "$(_pf NEXUS_ROOT="$C")" "$P/monitor/.state"
assert_eq "#1428 no env at all: script-relative arm also de-nests to the primary"   "$(_pf -u NEXUS_ROOT)" "$P/monitor/.state"
assert_eq "CONTROL: NEXUS_STATE_DIR (the test seam) still wins verbatim" "$(env NEXUS_STATE_DIR=/x/y bash -c '_script_dir="$1"; eval "$(sed -n "/^_primary_root_of()/,/^}/p; /^_resolve_state_dir()/,/^}/p" "$1/paste-followup.sh")"; _resolve_state_dir' _ "$C/monitor")" "/x/y"
assert_eq "CONTROL: run FROM the primary, the primary is the answer" "$(env -u NEXUS_STATE_DIR NEXUS_ROOT="$P" bash -c '_script_dir="$1"; eval "$(sed -n "/^_primary_root_of()/,/^}/p; /^_resolve_state_dir()/,/^}/p" "$1/paste-followup.sh")"; _resolve_state_dir' _ "$C/monitor")" "$P/monitor/.state"
echo '=== harness/generic-tmux.sh ==='
assert_eq "#1428 NEXUS_ROOT=<clone> resolves the PRIMARY's state dir" "$(_gt NEXUS_ROOT="$C")" "$P/monitor/.state"
assert_eq "#1428 no env: script-relative arm de-nests too"          "$(_gt -u NEXUS_ROOT)" "$P/monitor/.state"
rm -f "$C/monitor/_nexus-root.sh"
assert_eq "#1428 a missing resolver is REFUSED (rc 1), never guessed" "$(_gt NEXUS_ROOT="$C" >/dev/null 2>&1; echo $?)" "1"
echo '=== send.sh reads the PRIMARY config ==='
assert_eq "#1428 _harness_for_window consults \${NEXUS_ROOT}/config/load.sh" "$(grep -c 'local _cfg="${NEXUS_ROOT:-$_sd/..}/config/load.sh"' "$MON/send.sh")" "1"
echo
EXPECTED=8
if (( PASS + FAIL != EXPECTED )); then printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$(( PASS + FAIL ))" "$EXPECTED" >&2; _th_fail; fi
th_summary_and_exit
