#!/usr/bin/env bash
# test-cc-harness-teardown-remnant.sh — your-org/nexus-code#1670 item 4.
#
# Run: bash monitor/watcher/test-cc-harness-teardown-remnant.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE DEFECT. `cch_teardown` (monitor/cc-harness/_lib.sh) stopped the harness
# tmux server and then MOVED the run dir aside at once. `kill-server` returns
# as soon as it has HUPped the panes; the harness `claude` writes its exit
# bookkeeping (a `<sid>.jsonl` under cfg/projects/) by PATH some time LATER, so
# the write re-created `$CCH_DIR/cfg/projects/…` after the move and left a
# `/tmp/cc-harness-*` remnant. Intermittent by construction: it is a race
# between the move and the exiting process.
#
# HERMETIC. No real claude, no network, no live board: the "claude" booted in
# the pane is a STUB that, on SIGHUP/SIGTERM, waits a moment and then writes a
# file into its CLAUDE_CONFIG_DIR by path — the race made deterministic. The
# harness's own cch_setup/cch_boot_worker/cch_teardown are driven unchanged
# against a private tmux server under a private TMUX_TMPDIR and the local
# mock backend (python3, loopback only).
#
# CASES
#   A  a stub that writes 0.6 s after HUP/TERM: after teardown (and a settle
#      longer than the stub's delay) NO remnant exists — and the bookkeeping
#      DID land, inside the moved dir (the positive control: the stub really
#      wrote, it just wrote before the move).
#   B  a stub that IGNORES HUP and TERM: teardown still returns, within the
#      chosen bound (grace + KILL wait), and still leaves no remnant. The
#      bound is what keeps "await" from becoming "hang"; and the process is
#      GONE when teardown returns (KILL after the grace), not leaked.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
# shellcheck source=/dev/null
. "$_test_dir/_test_helpers.sh"
LIB="$REPO_ROOT/monitor/cc-harness/_lib.sh"

. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$LIB" "$REPO_ROOT/monitor/_trash.sh"; }
gp_handle "$@"

command -v python3 >/dev/null 2>&1 || th_skip "python3 not on PATH (the mock backend needs it)"
_have_tmux=0
for _c in /usr/bin/tmux /usr/local/bin/tmux /bin/tmux; do
    [[ -x "$_c" ]] && { _have_tmux=1; break; }
done
(( _have_tmux )) || th_skip "no real tmux binary"

# A SHORT socket root: the harness derives it from $TMPDIR (mktemp -d -t), and
# an agent's TMPDIR is long enough to overflow sun_path (your-org/nexus-code#991).
# shellcheck source=/dev/null
. "$REPO_ROOT/monitor/_tmux_socket.sh"
SHORT=$(tmux_socket_short_tmpdir "td$$")
mkdir -p "$SHORT" && chmod 700 "$SHORT"
export TMPDIR="$SHORT"
export NEXUS_TRASH_DIR="$SHORT/trash"
trap 'rm -rf "$SHORT" 2>/dev/null || true' EXIT

# stub_claude <path> <mode> — mode `late` writes 0.6 s after HUP/TERM;
# mode `deaf` ignores both (only KILL stops it).
stub_claude() {
    cat > "$1" <<'EOF'
#!/usr/bin/env bash
cfg="$CLAUDE_CONFIG_DIR"
mode=__MODE__
printf '%s\n' "$$" > "$cfg/stub.ready"
_bye() {
    sleep 0.6
    mkdir -p "$cfg/projects/-stub-proj" 2>/dev/null
    printf '{"type":"exit"}\n' > "$cfg/projects/-stub-proj/stub-sid.jsonl"
    exit 0
}
if [[ "$mode" == deaf ]]; then trap '' HUP TERM; else trap _bye HUP TERM; fi
while :; do sleep 0.1; done
EOF
    sed -i "s/__MODE__/$2/" "$1"
    chmod +x "$1"
}

# proc_start <pid> — kernel start time (/proc/<pid>/stat field 22) of a live,
# non-zombie pid; rc 1 otherwise. The test's OWN reader, deliberately not the
# library's `_cch_proc_start`: the base arm has no such function, and a probe
# borrowed from the subject would make this test's identity check vanish in
# exactly the arm it has to discriminate.
proc_start() {
    local stat rest
    [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
    stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    rest=${stat##*) }
    local -a f; read -r -a f <<<"$rest"
    [[ "${f[0]:-}" != Z && "${f[19]:-}" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "${f[19]}"
}
# stub_alive <pid> <start> — the SAME process (pid AND start time) still runs.
# A bare `kill -0` would answer for a recycled pid.
stub_alive() { [[ "$(proc_start "$1")" == "$2" ]]; }
# Reap a stub the code under test left running (the base arm of case B does):
# identity-checked, and only the pid this test's own stub recorded.
reap_stub() { stub_alive "$1" "$2" && kill -KILL "$1" 2>/dev/null; return 0; }

# run_case <mode> — boots the stub in a harness pane, tears down, and sets
# CASE_DIR / CASE_ELAPSED / CASE_READY.
run_case() (
    local mode="$1" bin="$SHORT/claude-$1"
    stub_claude "$bin" "$mode"
    export CLAUDE_BIN="$bin"
    # shellcheck source=/dev/null
    . "$LIB"
    cch_setup >"$SHORT/setup-$mode.log" 2>&1 || { echo "SETUP-FAILED"; exit 0; }
    trap - EXIT
    cch_boot_worker "stub" >/dev/null
    local i
    # CHOSEN: 90 s for the pane to start the stub. The pane runs the launch
    # line under the operator's login shell, and on the loaded shared host that
    # alone was measured at 18 s (2026-09-29); a fast host exits the loop early.
    for (( i = 0; i < 900; i++ )); do
        [[ -s "$CCH_CFG/stub.ready" ]] && break
        sleep 0.1
    done
    local ready=no spid=- sst=-
    if [[ -s "$CCH_CFG/stub.ready" ]]; then
        ready=yes
        spid=$(tr -d '[:space:]' < "$CCH_CFG/stub.ready")
        sst=$(proc_start "$spid") || sst=-
    fi
    local t0 t1
    t0=$(date +%s%N)
    CCH_TEARDOWN_GRACE=2 cch_teardown
    t1=$(date +%s%N)
    printf '%s %s %s %s %s\n' "$CCH_DIR" "$(( (t1 - t0) / 1000000 ))" "$ready" "$spid" "$sst"
)


echo "=== A: a claude that writes its bookkeeping AFTER the HUP ==="
read -r CASE_DIR CASE_MS CASE_READY SPID SST <<<"$(run_case late 2>"$SHORT/case-late.err")"
if [[ "$CASE_DIR" == SETUP-FAILED ]]; then
    sed 's/^/    /' "$SHORT/setup-late.log"
    th_skip "cch_setup could not bring the harness up here (see above)"
fi
assert_eq "A precondition: the stub was running in the pane before teardown" "$CASE_READY" "yes"
sleep 1.5    # > the stub's 0.6 s delay: a late write has had time to land
assert_eq "A no /tmp/cc-harness-* remnant after teardown (the late write did not re-create it)" \
    "$( [[ -e "$CASE_DIR" ]] && echo "REMNANT: $(find "$CASE_DIR" -type f 2>/dev/null | tr '\n' ' ')" || echo none )" "none"
landed=$(find "$NEXUS_TRASH_DIR" -path '*/cfg/projects/-stub-proj/stub-sid.jsonl' 2>/dev/null | wc -l)
assert_eq "A positive control: the bookkeeping DID land — inside the moved-aside dir" "$landed" "1"
reap_stub "$SPID" "$SST"

echo "=== B: a claude that ignores HUP and TERM — the wait is BOUNDED ==="
read -r CASE_DIR CASE_MS CASE_READY SPID SST <<<"$(run_case deaf 2>"$SHORT/case-deaf.err")"
assert_eq "B precondition: the stub was running in the pane before teardown" "$CASE_READY" "yes"
assert_eq "B the HUP/TERM-deaf stub is GONE when teardown returns (KILL after the grace)" \
    "$(stub_alive "$SPID" "$SST" && echo "still running pid $SPID" || echo gone)" "gone"
reap_stub "$SPID" "$SST"
# grace 2 s + KILL wait 2 s + tmux/mock slack. Chosen ceiling: 8 s.
assert_eq "B teardown returned within the bound (grace + KILL wait), took ${CASE_MS} ms" \
    "$( (( CASE_MS < 8000 )) && echo bounded || echo "UNBOUNDED ${CASE_MS}ms" )" "bounded"
assert_eq "B …and still left no remnant" "$( [[ -e "$CASE_DIR" ]] && echo remnant || echo none )" "none"

EXPECTED_ASSERTIONS=7
TOTAL=$(( PASS + FAIL ))
assert_eq "assertion TOTAL matches the expected total" "$TOTAL" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
